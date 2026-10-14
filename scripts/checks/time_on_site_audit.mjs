// time_on_site_audit.mjs - audit the saved time on site (time on site plan step 5). Read-only, re-runnable.
//   node scripts/checks/time_on_site_audit.mjs <out.html> <out.json> [from YYYY-MM-DD, default 2026-08-20] [to YYYY-MM-DD]
// Dates before 2026-08-20 (no stop table yet) are read day by day from public.fn_time_on_site_audit_gps, the same audit
// with the reference rebuilt from the raw GPS (time on site plan step 6); later dates from fn_time_on_site_audit.
// For every saved time on site of a completed client visit since `from` it puts three things side by side:
//   the saved value, our reference (public.fn_time_on_site_audit: the truck's stop holding the completion, with the
//   step 3 chain and split rules), and Samsara's own stop (the gap between the trip that ends before and the trip that
//   starts after, /v1/fleet/trips).
// A visit is AUTO (safe to correct to the reference) only when all hold: the reference exists and is not a shared or
// unsplittable stop; no other visit of that truck was completed inside it; no truck question; not stale; Samsara agrees
// within 5 min at BOTH ends; the saved value is flagged (wrong stay, too short, too long, closed before arrival, window
// cut); it is not a reviewed value; it is not a wrong stay onto a stop under 15 min. Visits that saved the same window on the same truck (neighbours) are AUTO only as
// a whole set. Everything else is review. The outputs name clients: write them OUTSIDE the repos.
import fs from 'node:fs';

const env = Object.fromEntries(fs.readFileSync(new URL('../../.env', import.meta.url), 'utf8').split(/\r?\n/)
  .filter((l) => l.includes('=') && !l.startsWith('#'))
  .map((l) => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
const [, , outHtml, outJson, from = '2026-08-20', to = '9999-12-31'] = process.argv;
const STOPS_FROM = '2026-08-20';
if (!outHtml || !outJson) { console.error('usage: node scripts/checks/time_on_site_audit.mjs <out.html> <out.json> [from]'); process.exit(1); }
const BASE = `https://${env.SUPABASE_PROJECT_ID}.supabase.co`;
const H = { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}`, 'Content-Type': 'application/json' };
const get = async (path) => { const r = await fetch(`${BASE}/rest/v1/${path}`, { headers: H }); if (!r.ok) throw new Error(`${path}: HTTP ${r.status}`); return r.json(); };

const rpc = async (fn, body) => { const r = await fetch(`${BASE}/rest/v1/rpc/${fn}`, { method: 'POST', headers: H, body: JSON.stringify(body) });
  if (!r.ok) throw new Error(`${fn}: HTTP ${r.status} ${await r.text()}`); return r.json(); };
let rows = [];
if (from < STOPS_FROM) {
  const last = to < STOPS_FROM ? to : '2026-08-19';
  for (let d = new Date(from + 'T12:00:00Z'); d.toISOString().slice(0, 10) <= last; d.setUTCDate(d.getUTCDate() + 1)) {
    for (const r of await rpc('fn_time_on_site_audit_gps', { p_date: d.toISOString().slice(0, 10) })) rows.push({ ...r, reference: 'gps' });
  }
}
if (to >= STOPS_FROM) {
  for (const r of await rpc('fn_time_on_site_audit', { p_from: from > STOPS_FROM ? from : STOPS_FROM })) if (r.visit_date <= to) rows.push({ ...r, reference: 'stops' });
}
if (!rows.length) throw new Error('the audit returned no rows: refusing to report a clean result from an empty instrument');

const links = await get('entity_source_links?select=entity_id,source_id&entity_type=eq.vehicle&source_system=eq.samsara');
const samsaraId = new Map(links.map((l) => [l.entity_id, l.source_id]));
const ids = rows.map((r) => r.visit_id);
const info = new Map();
for (let i = 0; i < ids.length; i += 150) {
  for (const v of await get(`visits?select=id,clients(client_code,name),vehicles(name),visit_reviews(bonus_status)&id=in.(${ids.slice(i, i + 150).join(',')})`)) info.set(v.id, v);
}

// Samsara trips, one call per truck per visit date (with the overnight tail)
const tripCache = new Map();
async function trips(vehicleId, date) {
  const key = `${vehicleId}/${date}`;
  if (tripCache.has(key)) return tripCache.get(key);
  const sid = samsaraId.get(vehicleId);
  let out = null;
  if (sid) {
    const t0 = Date.parse(`${date}T00:00:00-04:00`) - 6 * 3600e3, t1 = t0 + 48 * 3600e3;
    const r = await fetch(`https://api.samsara.com/v1/fleet/trips?vehicleId=${sid}&startMs=${t0}&endMs=${t1}`,
      { headers: { Authorization: `Bearer ${env.SAMSARA_API_TOKEN}` } });
    out = r.ok ? ((await r.json()).trips ?? []) : null;
  }
  tripCache.set(key, out);
  return out;
}
const MIN = 60e3;
const FLAGS = ['wrong_stay', 'too_short', 'too_long', 'closed_before_arrival', 'window_cut'];
const out = [];
for (const r of rows) {
  const t = r.vehicle_id ? await trips(r.vehicle_id, r.visit_date) : null;
  let gap = null;
  if (t) {
    const a = Date.parse(r.ref_arrival ?? r.completed_at), d = Date.parse(r.ref_departure ?? r.completed_at);
    const before = t.filter((x) => x.endMs <= a + 5 * MIN).sort((x, y) => y.endMs - x.endMs)[0];
    const after = t.filter((x) => x.startMs >= d - 5 * MIN).sort((x, y) => x.startMs - y.startMs)[0];
    if (before && after && after.startMs > before.endMs) gap = { arrival: new Date(before.endMs).toISOString(), departure: new Date(after.startMs).toISOString(),
      minutes: Math.round((after.startMs - before.endMs) / MIN) };
  }
  let agree = null, disagree = null;
  if (gap && r.ref_arrival) {
    const da = Math.abs(Date.parse(gap.arrival) - Date.parse(r.ref_arrival)), dd = Math.abs(Date.parse(gap.departure) - Date.parse(r.ref_departure));
    agree = da <= 5 * MIN && dd <= 5 * MIN; disagree = da > 10 * MIN || dd > 10 * MIN;
  }
  const flagged = r.verdicts.some((v) => FLAGS.includes(v));
  const auto = !!(r.ref_arrival && r.ref_split_ok && r.ref_sharing === 1 && !r.other_completion_inside && !r.truck_question
    && !r.stale && agree && flagged && !['review', 'reviewed_blank'].includes(r.saved_source)
    // a long saved stay replaced by a short stop at the completion is the truck dropping by to close the job (step 6)
    && !(r.verdicts.includes('wrong_stay') && r.ref_minutes < 15));
  const v = info.get(r.visit_id);
  out.push({ ...r, samsara: gap, samsara_agrees: agree, samsara_disagrees: disagree, samsara_read: t !== null, auto,
    client_code: v?.clients?.client_code ?? '', client_name: v?.clients?.name ?? '', truck: v?.vehicles?.name ?? '',
    bonus_pending: (v?.visit_reviews?.bonus_status ?? v?.visit_reviews?.[0]?.bonus_status) === 'pending' });
}
// neighbours: the same saved window on the same truck is one measurement shared by several visits; all or none
const sets = new Map();
for (const o of out) { const k = `${o.vehicle_id}|${o.saved_arrival}|${o.saved_departure}`; if (!sets.has(k)) sets.set(k, []); sets.get(k).push(o); }
for (const s of sets.values()) if (s.length > 1) {
  const all = s.every((o) => o.auto);
  for (const o of s) { o.neighbours = s.map((x) => x.visit_id).filter((id) => id !== o.visit_id); if (!all) o.auto = false; }
}

const group = (o) => o.auto ? 'A. Safe to correct automatically'
  : !o.verdicts.length && !o.samsara_disagrees ? 'Z. Agrees'
  : o.verdicts.includes('truck_question') ? 'B. Truck question'
  : o.verdicts.includes('no_reference') ? 'C. No stop holds the completion'
  : o.verdicts.includes('shared_stop') || o.neighbours ? 'D. Shared stop or neighbours'
  : o.verdicts.some((v) => FLAGS.includes(v)) ? 'E. Flagged, Samsara does not confirm the stop'
  : 'F. Other (extreme, stale, Samsara disagrees)';
for (const o of out) o.group = group(o);
fs.writeFileSync(outJson, JSON.stringify(out, null, 1));

const et = (x) => x ? new Date(x).toLocaleString('en-US', { timeZone: 'America/New_York', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '';
const tm = (x) => x ? new Date(x).toLocaleTimeString('en-US', { timeZone: 'America/New_York', hour: 'numeric', minute: '2-digit' }) : '';
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);
const groups = [...new Set(out.map((o) => o.group))].sort();
let body = '';
for (const g of groups) {
  const list = out.filter((o) => o.group === g);
  if (g.startsWith('Z')) { body += `<h2>${esc(g)} (${list.length})</h2><p>Saved value matches the stop; nothing to do.</p>`; continue; }
  body += `<h2>${esc(g)} (${list.length})</h2><table><tr><th>Visit</th><th>Date</th><th>Client</th><th>Truck</th><th>Saved</th><th>Our stop</th><th>Samsara</th><th>Checks</th></tr>`;
  for (const o of list) body += `<tr><td><a href="https://admin.unclogme.app/review/${o.visit_id}">${o.visit_id}</a></td><td>${o.visit_date}</td>`
    + `<td>${esc(o.client_code)} ${esc(o.client_name)}</td><td>${esc(o.truck)}</td>`
    + `<td>${o.saved_minutes} min<br><small>${tm(o.saved_arrival)} to ${tm(o.saved_departure)}</small></td>`
    + `<td>${o.ref_minutes ?? '-'}${o.ref_minutes != null ? ' min' : ''}<br><small>${tm(o.ref_arrival)} ${o.ref_arrival ? 'to' : ''} ${tm(o.ref_departure)}</small></td>`
    + `<td>${o.samsara ? o.samsara.minutes + ' min<br><small>' + tm(o.samsara.arrival) + ' to ' + tm(o.samsara.departure) + '</small>' : (o.samsara_read ? 'no gap' : 'not read')}</td>`
    + `<td>${esc(o.verdicts.join(', '))}${o.truck_question ? '<br><small>' + esc(o.truck_question) + '</small>' : ''}${o.neighbours ? '<br><small>same window as ' + o.neighbours.join(', ') + '</small>' : ''}${o.bonus_pending ? '<br><b>bonus pending</b>' : ''}<br><small>completed ${et(o.completed_at)}</small></td></tr>`;
  body += '</table>';
}
fs.writeFileSync(outHtml, `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Time on site audit</title>
<style>:root{color-scheme:light dark}body{font:14px system-ui;margin:16px;background:Canvas;color:CanvasText}table{border-collapse:collapse;width:100%;margin-bottom:24px}
td,th{border:1px solid #8884;padding:6px;text-align:left;vertical-align:top}small{opacity:.75}a{color:#f14714}</style></head><body>
<h1>Time on site audit, saved values since ${esc(from)}</h1><p>${out.length} visits. Saved value vs the truck's stop at the completion vs Samsara's trip gap. Generated ${new Date().toISOString().slice(0, 16)} UTC by scripts/checks/time_on_site_audit.mjs.</p>${body}</body></html>`);
const count = {}; for (const o of out) count[o.group] = (count[o.group] ?? 0) + 1;
console.log(out.length, 'visits', count, 'samsara unread', out.filter((o) => !o.samsara_read).length);
