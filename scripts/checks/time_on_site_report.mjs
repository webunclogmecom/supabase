// time_on_site_report.mjs - the "Visits Missing Time on Site" HTML report, built from the daily alert itself.
//   node scripts/checks/time_on_site_report.mjs <out.html> [from YYYY-MM-DD, default 2026-01-01]
// WHICH visits are listed comes from the 11 AM alert (edge fn time-on-site-reminder, its dry run per date: the gaps of
// public.fn_time_on_site_gaps). Since 2026-10-15 the ISSUE of each visit is read from Samsara itself (trips + GPS over
// the visit's date window), because the alert's reasons hid trucks Samsara shows at the place; see the block below.
// Client visits only (the function leaves out dump sites and test clients). The output names clients: write it
// OUTSIDE the repos (the workspace's samsara-checks/ folder), never here.
import fs from 'node:fs';

const env = Object.fromEntries(fs.readFileSync(new URL('../../.env', import.meta.url), 'utf8').split(/\r?\n/)
  .filter((l) => l.includes('=') && !l.startsWith('#'))
  .map((l) => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim().replace(/^["']|["']$/g, '')]; }));
const [, , outFile, from = '2026-01-01'] = process.argv;
if (!outFile) { console.error('usage: node scripts/checks/time_on_site_report.mjs <out.html> [from]'); process.exit(1); }
const BASE = `https://${env.SUPABASE_PROJECT_ID}.supabase.co`;
const H = { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: `Bearer ${env.SUPABASE_SERVICE_ROLE_KEY}` };
const ORG = '6009037';

// the dates that have a completed visit with no time on site (the function narrows each to client visits)
const vr = await fetch(`${BASE}/rest/v1/visits?select=visit_date&visit_status=eq.completed&deleted_at=is.null` +
  `&duration_minutes=is.null&visit_date=gte.${from}`, { headers: H });
if (!vr.ok) throw new Error(`visits: HTTP ${vr.status}`);
const dates = [...new Set((await vr.json()).map((r) => r.visit_date))].sort();

const rows = [];
let placesUnread = 0;
for (const date of dates) {
  const r = await fetch(`${BASE}/functions/v1/time-on-site-reminder`, {
    method: 'POST', headers: { ...H, 'Content-Type': 'application/json' }, body: JSON.stringify({ dry_run: true, date }) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`${date}: HTTP ${r.status} ${JSON.stringify(j).slice(0, 200)}`);
  if (!j.count) continue;
  if (j.places_read === false) placesUnread++;
  const byId = new Map((j.lines ?? []).map((l) => [l.visit_id, l.line]));
  for (const g of j.gaps ?? []) rows.push({ g, line: byId.get(g.visit_id) ?? '' });
}

// addresses and the property's other measured visits (display only)
const ids = rows.map((x) => x.g.visit_id);
const addr = new Map();
for (let i = 0; i < ids.length; i += 100) {
  const ar = await fetch(`${BASE}/rest/v1/visits?select=id,client_id,property_id,properties(address,city),jobs(title),line_items(name)&id=in.(${ids.slice(i, i + 100).join(',')})`, { headers: H });
  if (!ar.ok) throw new Error(`addresses: HTTP ${ar.status}`);
  for (const a of await ar.json()) addr.set(a.id, a);
}
// a visit with no property set (5078, 5043, 3921): show the client's live property as plain text when it has exactly one
const noProp = [...addr.values()].filter((a) => !a.property_id && a.client_id);
const clientProps = new Map();
if (noProp.length) {
  const pr = await fetch(`${BASE}/rest/v1/properties?select=client_id,address,city,latitude,longitude&deleted_at=is.null&client_id=in.(${[...new Set(noProp.map((a) => a.client_id))].join(',')})`, { headers: H });
  if (!pr.ok) throw new Error(`client properties: HTTP ${pr.status}`);
  for (const p of await pr.json()) clientProps.set(p.client_id, [...(clientProps.get(p.client_id) ?? []), p]);
}

// visits an audit could not settle (public.visit_audit_flags, Fred 2026-10-15: "flag them"), listed at the top
const fr = await fetch(`${BASE}/rest/v1/visit_audit_flags?select=visit_id,reason,visits(visit_date,clients(client_code,name))&resolved_at=is.null&order=visit_id`, { headers: H });
if (!fr.ok) throw new Error(`flags: HTTP ${fr.status}`);
const flags = await fr.json();
const flagged = new Map(flags.map((f) => [f.visit_id, f.reason]));
const hesc = (v) => String(v ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

const et = (t) => t ? new Date(t).toLocaleString('en-US', { timeZone: 'America/New_York', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '';
// 2026-10-15 (Fred: "check the html list to make sure the data is correct, i can't see in samsara the trucks routes
// to be as you say ... at the Datetime of the visit ... the links of the truck routes should be in accordance to the
// date of the visit not the date of completion"). The alert's reasons looked only at our map point and at the moment
// the job was marked complete, so they hid trucks Samsara shows at the place that day (5084: Cloggy inside the place
// 35 min, listed as "no truck within 150 m"). Every issue below is read from SAMSARA for the visit's date window
// (visit date -4 h to 10 AM next day, ET): its trips give each stop and the place it ended at, exactly what Samsara
// shows; its GPS history gives the closest approach when no truck stopped. The alert's line is only a fallback.
const SAM = { Authorization: `Bearer ${env.SAMSARA_API_TOKEN}`, Accept: 'application/json' };
const TRUCKS = { '281474998706262': 'Moises', '281474998706263': 'Cloggy', '281474998706264': 'David' };
const NEAR = 250, PLACE_NEAR = 150, MIN_STAY = 3 * 60e3, STILL_MPH = 3;
// 2026-10-15 (Samsara audit, Fred: "Go ahead ... 10"), same rules as samsara_visit_audit.mjs: no re-park join (it
// merged a neighbour's job into one stop), a trip within 150 m of a client place centre counts, and GPS idling counts
// only while the truck is stationary (Samsara GPS speed <= 3 mph), so a drive-through is not a stop.
const R = 6371000, rad = (x) => x * Math.PI / 180;
const meters = (a, b, c, d) => { const x = rad(c - a), y = rad(d - b); const h = Math.sin(x / 2) ** 2 + Math.cos(rad(a)) * Math.cos(rad(c)) * Math.sin(y / 2) ** 2; return 2 * R * Math.asin(Math.sqrt(h)); };
const dist = (m) => m >= 1000 ? `${(m / 1000).toFixed(1)} km` : `${Math.round(m)} m`;
const clock = (t) => new Date(t).toLocaleTimeString('en-US', { timeZone: 'America/New_York', hour: 'numeric', minute: '2-digit' });
const etDay = (t) => new Date(t).toLocaleDateString('en-CA', { timeZone: 'America/New_York' });
const at = (t, day) => etDay(t) === day ? clock(t) : `${new Date(t).toLocaleDateString('en-US', { timeZone: 'America/New_York', month: 'short', day: 'numeric' })}, ${clock(t)}`;
const etMidnight = (d) => { const noon = Date.parse(d + 'T12:00:00Z'); const off = new Date(noon).toLocaleString('en-US', { timeZone: 'America/New_York', timeZoneName: 'shortOffset' }).match(/GMT([+-]\d+)/)[1]; return Date.parse(`${d}T00:00:00${off.startsWith('-') ? '-' : '+'}${String(Math.abs(off)).padStart(2, '0')}:00`); };
const sleep = (ms) => new Promise((s) => setTimeout(s, ms));

const tripCache = new Map();
async function trips(truck, a, b) {
  const k = `${truck}|${a}|${b}`;
  if (!tripCache.has(k)) {
    const r = await fetch(`https://api.samsara.com/v1/fleet/trips?vehicleId=${truck}&startMs=${a}&endMs=${b}`, { headers: SAM });
    if (!r.ok) throw new Error(`samsara trips ${r.status}`);
    tripCache.set(k, ((await r.json()).trips ?? []).sort((x, y) => x.startMs - y.startMs));
    await sleep(150);
  }
  return tripCache.get(k);
}
const placeCache = new Map();
async function place(id) {
  if (!placeCache.has(id)) {
    const r = await fetch(`https://api.samsara.com/addresses/${id}`, { headers: SAM });
    const a = r.ok ? (await r.json()).data : null;
    placeCache.set(id, a ? { id: String(a.id), name: a.name, lat: a.geofence?.circle?.latitude ?? a.latitude, lng: a.geofence?.circle?.longitude ?? a.longitude } : null);
    await sleep(150);
  }
  return placeCache.get(id);
}
// When Samsara's trips show no stop there, the GPS points still can: a truck idling with the engine on never ends a
// trip (7741: Cloggy 11 min within 48 m). Targets are our map point AND each Samsara place (8009: Moises 41 m from the
// place, 816 m from our map point). A dwell = consecutive STATIONARY points near a target with no gap over 5 min.
async function gpsLook(w0, w1, targets) {
  let after = '', best = null;
  const near = {};
  do {
    const r = await fetch(`https://api.samsara.com/fleet/vehicles/stats/history?types=gps&vehicleIds=${Object.keys(TRUCKS).join(',')}` +
      `&startTime=${new Date(w0).toISOString()}&endTime=${new Date(w1).toISOString()}${after ? '&after=' + after : ''}`, { headers: SAM });
    if (!r.ok) throw new Error(`samsara gps ${r.status}`);
    const j = await r.json();
    for (const v of j.data ?? []) for (const q of v.gps ?? []) {
      let hit = null;
      for (const tg of targets) {
        const m = meters(tg.lat, tg.lng, q.latitude, q.longitude);
        if (!best || m < best.m) best = { m, t: q.time, truck: TRUCKS[v.id], id: v.id, target: tg };
        if (m <= NEAR) { hit = { tg, m }; break; }
      }
      (near[v.id] ??= []).push({ t: Date.parse(q.time), ...hit, hit: !!hit, still: q.speedMilesPerHour == null || q.speedMilesPerHour <= STILL_MPH });
    }
    after = j.pagination?.hasNextPage ? j.pagination.endCursor : '';
    await sleep(150);
  } while (after);
  const dwells = [];
  for (const [id, pts] of Object.entries(near)) {
    pts.sort((x, y) => x.t - y.t);
    let cur = null;
    for (const p of pts) {
      if (!p.hit || !p.still) { if (cur) dwells.push(cur); cur = null; continue; }
      if (cur && p.t - cur.s1 <= 5 * 60e3) { cur.s1 = p.t; continue; }
      if (cur) dwells.push(cur);
      cur = { id, truck: TRUCKS[id], s0: p.t, s1: p.t, gps: true, viaPlace: p.tg.kind === 'place', placeName: p.tg.name, fromMap: p.tg.kind === 'map' ? p.m : null, parts: 1 };
    }
    if (cur) dwells.push(cur);
  }
  return { best, dwells: dwells.filter((d) => d.s1 - d.s0 >= MIN_STAY).sort((x, y) => x.s0 - y.s0) };
}

const KINDS = [
  ['atdone', 'Parked there when marked complete'],
  ['once', 'Parked there once, marked complete at another time'],
  ['several', 'Parked there more than once'],
  ['passed', 'Only drove past'],
  ['never', 'No truck at the address'],
  ['nowhere', 'No map point and no Samsara place'],
];
const svcFallback = (a) => [...new Set((a?.line_items ?? []).map((l) => String(l.name ?? '').replace(/^\s*\d+\s*-\s*/, '').trim()).filter(Boolean))].join(', ')
  || String(a?.jobs?.title ?? '').replace(/\s*\[OLD\]\s*$/i, '').trim();

const data = [];
for (const { g } of rows) {
  const a = addr.get(g.visit_id);
  g.noProperty = !!a && !a.property_id;
  const only = a && !a.property_id ? (clientProps.get(a.client_id) ?? []) : [];
  const fallback = only.length === 1 ? only[0] : null;
  const lat = g.lat ?? fallback?.latitude ?? null, lng = g.lng ?? fallback?.longitude ?? null;
  const placeIds = [...new Set([g.property_place_id, ...(g.client_place_ids ?? [])].filter(Boolean).map(String))];
  const places = (await Promise.all(placeIds.map(place))).filter(Boolean);
  const w0 = etMidnight(g.visit_date) - 4 * 3600e3;
  const next = new Date(Date.parse(g.visit_date + 'T12:00:00Z') + 86400e3).toISOString().slice(0, 10);
  const w1 = etMidnight(next) + 10 * 3600e3;
  const done = g.completed_at ? Date.parse(g.completed_at) : null;
  const issues = [], fix = [];

  // every truck's stops at the address in the window: the gap after a trip that ended at the client's Samsara place,
  // or within 150 m of one of its place centres, or within 250 m of our map point; every stay is its own stop
  const visits = [];
  if (lat != null || places.length) {
    for (const [id, name] of Object.entries(TRUCKS)) {
      const ts = await trips(id, w0 - 12 * 3600e3, w1 + 12 * 3600e3);
      const here = [];
      for (let i = 0; i < ts.length - 1; i++) {
        const s0 = ts[i].endMs, s1 = ts[i + 1].startMs;
        if (s1 - s0 < MIN_STAY || s1 <= w0 || s0 >= w1) continue;
        const c = ts[i].endCoordinates ?? {};
        const placeHit = places.find((p) => String(ts[i].endAddress?.id ?? '') === p.id)
          ?? (c.latitude != null ? places.find((p) => meters(p.lat, p.lng, c.latitude, c.longitude) <= PLACE_NEAR) : undefined);
        const fromMap = lat != null && c.latitude != null ? meters(lat, lng, c.latitude, c.longitude) : null;
        if (placeHit || (fromMap != null && fromMap <= NEAR)) here.push({ s0, s1, fromMap, placeName: placeHit?.name ?? ts[i].endAddress?.name ?? null, viaPlace: !!placeHit });
      }
      for (const h of here) visits.push({ id, truck: name, parts: 1, ...h });
    }
  }
  visits.sort((x, y) => x.s0 - y.s0);
  const targets = [...(lat != null ? [{ kind: 'map', lat, lng }] : []), ...places.map((p) => ({ kind: 'place', lat: p.lat, lng: p.lng, name: p.name }))];
  let look = null;
  if (!visits.length && targets.length) { look = await gpsLook(w0, w1, targets); visits.push(...look.dwells); }
  const holds = done != null ? visits.filter((v) => done >= v.s0 - 5 * 60e3 && done <= v.s1 + 15 * 60e3) : [];
  const old = g.visit_date < '2026-08-19';
  const span = (v) => `${at(v.s0, g.visit_date)} to ${at(v.s1, g.visit_date)} (${Math.round((v.s1 - v.s0) / 60e3)} min)`;
  const where = (v) => (v.viaPlace && (v.fromMap == null || v.fromMap > 150)
    ? `at the address (Samsara place "${v.placeName}"${v.fromMap != null ? `, ${dist(v.fromMap)} from our map point` : ''})` : 'at the address')
    + (v.gps ? ' with the engine running (Samsara GPS, no trip stop)' : '');
  const doneTxt = done != null ? `the job was marked complete ${etDay(done) === g.visit_date ? 'at ' + clock(done) : 'on ' + at(done, '')}` : 'the job has no completion time';
  let kind;
  if (lat == null && !places.length) {
    kind = 'nowhere';
    issues.push(g.noProperty ? 'The visit has no property set, so we cannot tell whether a truck was there.' : 'The property has no map point and the client has no Samsara place, so we cannot tell whether a truck was there.');
    fix.push(g.noProperty ? 'Set the property on the visit.' : 'Check the address in Jobber so the property gets a map point.');
  } else if (holds.length) {
    kind = 'atdone';
    const v = holds[0];
    const rel = done > v.s1 ? `, ${Math.round((done - v.s1) / 60e3)} min after the truck left` : done < v.s0 ? `, ${Math.round((v.s0 - done) / 60e3)} min before the truck arrived` : `, during that stop`;
    issues.push(`${v.truck} was parked ${where(v)} ${span(v)}, and ${doneTxt}${rel}.`);
    if (v.truck !== g.truck) {
      issues.push(g.truck ? `The visit is set to ${g.truck}, but ${v.truck} was the truck parked there.` : `The visit has no truck set; ${v.truck} was the truck parked there.`);
      fix.push(`Set the truck on the visit to ${v.truck} (Viktor can do it).`);
    }
    fix.push(old ? "Save Samsara's stay as the time on site: the visit is older than our truck stop records (Aug 20), so it does not fill by itself."
                 : 'The time then fills overnight.');
  } else if (visits.length === 1) {
    kind = 'once';
    const v = visits[0];
    issues.push(`${v.truck} was parked ${where(v)} ${span(v)}, the only time a truck stopped there that day, but ${doneTxt}.`);
    if (v.truck !== g.truck) {
      issues.push(g.truck ? `The visit is set to ${g.truck}, but ${v.truck} was the truck parked there.` : `The visit has no truck set; ${v.truck} was the truck parked there.`);
      fix.push(`Set the truck on the visit to ${v.truck} (Viktor can do it).`);
    }
    fix.push(old ? "Save Samsara's stay as the time on site (one visit there that day)." : v.truck !== g.truck ? "The nightly check then saves Samsara's stay for it." : "The nightly check saves Samsara's stay for it.");
  } else if (visits.length > 1) {
    kind = 'several';
    issues.push(`Trucks stopped at the address ${visits.length} times that day: ${visits.map((v) => `${v.truck} ${span(v)}`).join('; ')}. ${doneTxt[0].toUpperCase() + doneTxt.slice(1)}, not during any of them.`);
    // Fred (decision 7): when the truck moved, the stay most likely to be the service is the longest one on its truck
    const mine = visits.filter((v) => v.truck === g.truck);
    const likely = (mine.length ? mine : visits).reduce((a, b) => (b.s1 - b.s0 > a.s1 - a.s0 ? b : a));
    fix.push(`Most likely the service: ${likely.truck} ${span(likely)}, the longest stop${mine.length ? ' of the truck on the visit' : ''}. Check with the driver if unsure, then save it as the time on site.`);
  } else {
    const c = look?.best ?? null;
    if (c && c.m <= NEAR) {
      kind = 'passed';
      issues.push(`${c.truck} only drove past the address (closest ${dist(c.m)} from ${c.target.kind === 'map' ? 'our map point' : 'the Samsara place'} at ${at(c.t, g.visit_date)}) and was not near it for 3 minutes.`);
      fix.push('Check with the driver whether the service was done that day. If it was, enter the time on site in Admin Review.');
    } else {
      kind = 'never';
      issues.push(c ? `No truck stopped at the address that day (closest: ${c.truck}, ${dist(c.m)} from ${c.target.kind === 'map' ? 'our map point' : 'the Samsara place'} at ${at(c.t, g.visit_date)}).` : 'No truck stopped at the address that day.');
      fix.push('Check the visit date and the truck with the office. If the service was done, enter the time on site in Admin Review.');
    }
    if (c) g.closestTruck = c;
  }
  // the two places we compare against
  if (g.noProperty && kind !== 'nowhere') {
    issues.push(`The visit has no property set${fallback ? `; the client's only property was used (${[fallback.address, fallback.city].filter(Boolean).join(', ')})` : ''}.`);
    fix.push('Set the property on the visit.');
  }
  if (!places.length) { issues.push('The client has no place in Samsara.'); fix.push('Create a Samsara place for the client at its address.'); }
  else if (lat != null) {
    const far = places.map((p) => ({ p, m: meters(lat, lng, p.lat, p.lng) })).sort((x, y) => x.m - y.m)[0];
    if (far.m > NEAR) {
      const viaPlace = visits.some((v) => v.viaPlace && (v.fromMap ?? 0) > NEAR), viaMap = visits.some((v) => !v.viaPlace);
      issues.push(`The client's Samsara place "${far.p.name}" is ${dist(far.m)} from our map point` +
        (viaPlace ? ', and the truck stopped at the Samsara place, so our map point (in Jobber) is in the wrong spot.'
                  : viaMap ? ', and the truck stopped at our map point, so the Samsara place is in the wrong spot.' : ', so one of the two is in the wrong spot.'));
      fix.push(viaPlace ? 'Move the map point in Jobber to the Samsara place.' : viaMap ? 'Move the Samsara place to the address.' : 'Check which one is right and move the other.');
    }
  }
  if (flagged.has(g.visit_id)) {   // a flag is a question for a person: the suggestion waits for the answer
    issues.unshift(`Flagged for review: ${flagged.get(g.visit_id)}`);
    fix.length = 0;
    fix.push('Answer the flagged question first (with the driver or the office); the truck and the time follow from the answer.');
  }
  const link = visits.length ? { truck: visits[0].truck, id: visits[0].id } : g.truck ? { truck: g.truck, id: g.truck_samsara_id }
    : g.closestTruck ? { truck: g.closestTruck.truck, id: g.closestTruck.id } : null;
  data.push({
    id: g.visit_id, date: g.visit_date, client: g.client_code ?? '', name: g.client_name ?? '',
    address: [a?.properties?.address, a?.properties?.city].filter(Boolean).join(', ') || (fallback ? [fallback.address, fallback.city].filter(Boolean).join(', ') : ''),
    service: g.service ?? svcFallback(a), truck: g.truck ?? '', completed: et(g.completed_at),
    rk: kind, rl: KINDS.find(([k]) => k === kind)[1], issues, reason: issues.join(' '), suggestion: [...new Set(fix)].join(' '),
    placeId: g.property_place_id || (g.client_place_ids ?? [])[0] || '',
    placeEndMs: w1, month: g.visit_date.slice(0, 7),
    truckAny: link?.truck ?? '', samsaraVehicle: link?.id ?? '',
    // the truck's route over the VISIT's date window (Fred, 2026-10-15), not around the completion time
    endMs: w1, durSec: Math.round((w1 - w0) / 1000),
  });
  process.stdout.write('.');
}

const counts = data.reduce((m, d) => (m[d.rk] = (m[d.rk] || 0) + 1, m), {});
const today = new Date().toLocaleDateString('en-US', { timeZone: 'America/New_York', month: 'long', day: 'numeric', year: 'numeric' });
const chips = KINDS.filter(([k]) => counts[k]).map(([k, l]) => `<span class="chip">${l} <b>${counts[k]}</b></span>`).join('\n');

const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Visits Missing Time on Site</title>
<style>
:root{--bg:#fff;--fg:#1d2330;--muted:#5d6675;--line:#e4e7ec;--head:#f6f7f9;--accent:#e2552d;--chip:#f1f3f6}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#14171c;--fg:#e8eaee;--muted:#9aa3b2;--line:#2a3039;--head:#1b1f26;--accent:#ff7a52;--chip:#232831}}
body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
.wrap{max-width:1500px;margin:0 auto;padding:20px 16px 48px}
h1{font-size:22px;margin:0 0 4px}.sub{color:var(--muted);margin:0 0 16px}
.bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:0 0 12px}
input,select{font:inherit;padding:7px 10px;border:1px solid var(--line);border-radius:8px;background:var(--bg);color:var(--fg)}
input[type=search]{min-width:240px;flex:1}
.chips{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 12px}.chip{background:var(--chip);border-radius:999px;padding:3px 10px;color:var(--muted)}
.chip b{color:var(--fg)}
.tw{overflow-x:auto;border:1px solid var(--line);border-radius:10px}
table{border-collapse:collapse;width:100%;min-width:1150px}
th,td{padding:8px 10px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}
th{background:var(--head);position:sticky;top:0;font-weight:600;cursor:pointer;white-space:nowrap}
td.n{white-space:nowrap}.muted{color:var(--muted)}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
.k-atdone,.k-once{color:#2471a3}.k-several{color:#7d3c98}.k-never{color:#c0392b}.k-passed{color:#b9770e}.k-nowhere{color:#7d3c98}
.note{color:var(--muted);font-size:13px;margin-top:14px}
button{font:inherit;padding:7px 12px;border:1px solid var(--line);border-radius:8px;background:var(--head);color:var(--fg);cursor:pointer}
tr.g td{background:var(--head);font-weight:600;cursor:pointer}
ul.iss{margin:0;padding-left:18px}ul.iss li+li{margin-top:4px}
tr.g .gc{color:var(--muted);font-weight:400;margin-left:8px}
details.flags{border:1px solid var(--line);border-left:4px solid var(--accent);border-radius:10px;padding:10px 14px;margin:0 0 14px}
details.flags summary{cursor:pointer}details.flags ul{margin:8px 0 0;padding-left:18px}details.flags li+li{margin-top:6px}
</style></head><body><div class="wrap">
<h1>Visits Missing Time on Site</h1>
<p class="sub">Completed client visits since ${from} with no time on site, as of ${today} (Eastern time). Every issue is read from Samsara (its trips and GPS) for the visit's date, 4 hours before it to 10 AM the next day, with a suggested fix. "At the address" means Samsara says the truck stopped at the client's Samsara place, or within 250 m of our map point.${placesUnread ? ` Samsara places could not be read for ${placesUnread} of the dates, so their place reasons are left out.` : ''}</p>
<div class="chips"><span class="chip"><b>${data.length}</b> visits</span>
${chips}</div>
${flags.length ? `<details class="flags" open><summary><b>Flagged for review</b>: ${flags.length} visits the audit could not settle, waiting for a person</summary><ul>${flags.map((f) =>
  `<li><b>#${f.visit_id}</b> ${hesc(f.visits?.visit_date)} <b>${hesc(f.visits?.clients?.client_code)}</b> ${hesc(f.visits?.clients?.name)}: ${hesc(f.reason)}</li>`).join('')}</ul></details>` : ''}
<div class="bar">
<input type="search" id="q" placeholder="Search client, address, truck, visit #">
<select id="group"><option value="">No grouping</option><option value="client" selected>Group by client</option><option value="rl">Group by issue</option><option value="truckAny">Group by truck</option><option value="month">Group by month</option></select>
<select id="reason"><option value="">All issues</option>${KINDS.filter(([k]) => counts[k]).map(([k, l]) => `<option value="${k}">${l}</option>`).join('')}</select>
<select id="truck"><option value="">Any truck</option></select>
<select id="month"><option value="">Any month</option></select>
<button id="clear" type="button">Clear filters</button>
<button id="csv" type="button">Download CSV</button>
<span class="muted" id="shown"></span>
</div>
<div class="tw"><table><thead><tr>
<th data-k="date">Date</th><th data-k="client">Client</th><th data-k="address">Property</th><th data-k="service">Service</th>
<th data-k="truck">Assigned truck</th><th data-k="completed">Completed</th><th data-k="reason">Issue</th><th data-k="suggestion">Suggestion</th>
<th>Truck in Samsara</th>
</tr></thead><tbody id="tb"></tbody></table></div>
<p class="note">The property opens the client's Place in Samsara. The truck link opens the truck that stopped there (else the truck on the visit) in Samsara over the visit's date, the same window (Samsara shows times in your computer's time zone).</p>
</div>
<script>
const ORG = '${ORG}';
const vehicleUrl = (d) => d.samsaraVehicle ? 'https://cloud.samsara.com/o/' + ORG + '/devices/' + d.samsaraVehicle + '/vehicle?end_ms=' + d.endMs + '&duration=' + d.durSec : '';
// a Place opens only WITH its duration/end_ms params; without them Samsara shows the list of all places
const placeUrl = (d) => d.placeId ? 'https://cloud.samsara.com/o/' + ORG + '/fleet/places/' + d.placeId + '?duration=2678399.999&end_ms=' + d.placeEndMs : '';
const DATA = ${JSON.stringify(data)};
const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
let sortK = 'date', sortDir = -1, current = [];
const $ = (id) => document.getElementById(id);
const fill = (id, vals, label) => { const s = $(id); [...new Set(vals)].filter(Boolean).sort().forEach((v) => { const o = document.createElement('option'); o.value = v; o.textContent = label ? label(v) : v; s.appendChild(o); }); };
const monthName = (m) => new Date(m + '-15').toLocaleDateString('en-US', { month: 'long', year: 'numeric' });
fill('truck', DATA.map((d) => d.truckAny)); fill('month', DATA.map((d) => d.month), monthName);
const groupLabel = (k, d) => k === 'client' ? (d.client || '(no code)') + ' ' + d.name : k === 'month' ? monthName(d.month) : k === 'truckAny' ? (d.truckAny || 'No truck') : d[k];
const collapsed = new Set();
function filtered() {
  const q = $('q').value.toLowerCase(), f = { rk: $('reason').value, truckAny: $('truck').value, month: $('month').value };
  return DATA.filter((d) => Object.entries(f).every(([k, v]) => !v || d[k] === v) &&
    (!q || [d.id, d.client, d.name, d.address, d.truck, d.truckAny, d.reason].join(' ').toLowerCase().includes(q)))
    .sort((a, b) => (a[sortK] > b[sortK] ? 1 : a[sortK] < b[sortK] ? -1 : 0) * sortDir);
}
function row(d) {
  return '<tr><td class="n">' + esc(d.date) + '<div class="muted">#' + d.id + '</div></td>' +
    '<td><b>' + esc(d.client) + '</b><div class="muted">' + esc(d.name) + '</div></td>' +
    '<td>' + (placeUrl(d) ? '<a href="' + placeUrl(d) + '" target="_blank" rel="noopener">' + esc(d.address || 'Samsara place') + '</a>' : esc(d.address)) + '</td>' +
    '<td>' + esc(d.service) + '</td><td>' + (esc(d.truck) || '<span class="muted">None</span>') + '</td>' +
    '<td class="n">' + esc(d.completed) + '</td><td class="k-' + d.rk + '"><ul class="iss">' + d.issues.map((i) => '<li>' + esc(i) + '</li>').join('') + '</ul></td>' +
    '<td>' + esc(d.suggestion) + '</td>' +
    '<td>' + (vehicleUrl(d) ? '<a href="' + vehicleUrl(d) + '" target="_blank" rel="noopener">' + esc(d.truckAny) + ' location history</a>' : '<span class="muted">No truck</span>') + '</td></tr>';
}
function render() {
  const list = current = filtered(), g = $('group').value;
  $('shown').textContent = list.length + ' visits shown';
  if (!g) { $('tb').innerHTML = list.map(row).join(''); return; }
  const groups = new Map();
  for (const d of list) { const k = groupLabel(g, d); if (!groups.has(k)) groups.set(k, []); groups.get(k).push(d); }
  $('tb').innerHTML = [...groups.entries()].sort((a, b) => b[1].length - a[1].length || String(a[0]).localeCompare(String(b[0]))).map(([k, rs]) =>
    '<tr class="g" data-g="' + esc(k) + '"><td colspan="9">' + (collapsed.has(k) ? '▸ ' : '▾ ') + esc(k) + '<span class="gc">' + rs.length + ' visit' + (rs.length === 1 ? '' : 's') + '</span></td></tr>' +
    (collapsed.has(k) ? '' : rs.map(row).join(''))).join('');
  document.querySelectorAll('tr.g').forEach((tr) => tr.onclick = () => { const k = tr.dataset.g; collapsed.has(k) ? collapsed.delete(k) : collapsed.add(k); render(); });
}
document.querySelectorAll('th[data-k]').forEach((th) => th.onclick = () => { const k = th.dataset.k; sortDir = sortK === k ? -sortDir : 1; sortK = k; render(); });
['q', 'reason', 'truck', 'month', 'group'].forEach((id) => $(id).addEventListener('input', () => { collapsed.clear(); render(); }));
$('clear').onclick = () => { ['q', 'reason', 'truck', 'month'].forEach((id) => $(id).value = ''); collapsed.clear(); render(); };
$('csv').onclick = () => {
  const cols = [['Visit #', 'id'], ['Date', 'date'], ['Client code', 'client'], ['Client', 'name'], ['Property', 'address'], ['Service', 'service'],
    ['Assigned truck', 'truck'], ['Completed (ET)', 'completed'], ['Issue', 'reason'], ['Suggestion', 'suggestion']];
  const q = (v) => '"' + String(v ?? '').replace(/"/g, '""') + '"';
  const lines = [cols.map((c) => q(c[0])).concat(q('Samsara place link'), q('Truck history link')).join(',')]
    .concat(current.map((d) => cols.map((c) => q(d[c[1]])).concat(q(placeUrl(d)), q(vehicleUrl(d))).join(',')));
  const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([lines.join('\\n')], { type: 'text/csv' }));
  a.download = 'visits_missing_time_on_site.csv'; a.click();
};
render();
</script></body></html>`;
fs.writeFileSync(outFile, html);
console.log('wrote', outFile, data.length, 'visits over', dates.length, 'dates', counts);
