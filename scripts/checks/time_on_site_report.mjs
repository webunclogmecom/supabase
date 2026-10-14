// time_on_site_report.mjs - the "Visits Missing Time on Site" HTML report, built from the daily alert itself.
//   node scripts/checks/time_on_site_report.mjs <out.html> [from YYYY-MM-DD, default 2026-01-01]
// Every reason is the line the 11 AM alert (edge fn time-on-site-reminder) would post for that visit: the report
// calls its dry run once per date ({dry_run:true, date}), which neither posts nor logs, and takes `lines` (the
// reasons) and `gaps` (public.fn_time_on_site_gaps) from it. So the report and the alert cannot disagree, which is
// what went wrong with the 2026-10-12 report (its own 150 m rule called visit 6509's 34-minute stop a drive-by).
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
  const ar = await fetch(`${BASE}/rest/v1/visits?select=id,client_id,property_id,properties(address,city)&id=in.(${ids.slice(i, i + 100).join(',')})`, { headers: H });
  if (!ar.ok) throw new Error(`addresses: HTTP ${ar.status}`);
  for (const a of await ar.json()) addr.set(a.id, a);
}
// a visit with no property set (5078, 5043, 3921): show the client's live property as plain text when it has exactly one
const noProp = [...addr.values()].filter((a) => !a.property_id && a.client_id);
const clientProps = new Map();
if (noProp.length) {
  const pr = await fetch(`${BASE}/rest/v1/properties?select=client_id,address,city&deleted_at=is.null&client_id=in.(${[...new Set(noProp.map((a) => a.client_id))].join(',')})`, { headers: H });
  if (!pr.ok) throw new Error(`client properties: HTTP ${pr.status}`);
  for (const p of await pr.json()) clientProps.set(p.client_id, [...(clientProps.get(p.client_id) ?? []), p]);
}

const et = (t) => t ? new Date(t).toLocaleString('en-US', { timeZone: 'America/New_York', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : '';
// the reason as the alert words it, after "<client> · <truck>: "; its kind only groups and filters the table
const KINDS = [
  ['othertruck', /was parked .*the visit is set to /, 'Another truck was there'],
  ['offpoint', /was parked [\d.,]+ (m|km) from our map point/, 'Parked near, map point off'],
  ['notsaved', /was parked here .* but the time was not saved/, 'Parked here, time not saved'],
  ['nopoint', /the property has no map point/, 'No map point'],
  ['noplace', /this client has no Samsara place$/, 'No Samsara place'],
  ['placefar', /the Samsara place is .* from our address/, 'Samsara place far from our address'],
  ['stay', / was there .* but /, 'Truck there, not at completion'],
  ['passed', /only drove past/, 'Only drove past'],
  ['never', /no truck came within/, 'No truck within 150 m'],
  ['nogps', /no truck GPS was found/, 'No truck GPS that day'],
];
// Fred, 2026-10-14: "Issue" instead of "Why it's blank", one bullet per problem, wording that says what is wrong, and
// a "Suggestion" column with the fix. The alert's reason stays the source; this only splits and rewords it.
const MAP_POINT = 'the map point we have for this address (in Jobber) is probably in the wrong spot: we only count a truck parked within 150 m of it';
function explain(kind, reason, g) {
  const issues = [], fix = [];
  let other = null;
  const r = reason.replace(/;? the visit is set to (.+)$/, (_, t) => { other = t; return ''; })
                  .replace(/, but the visit is set to (.+)$/, (_, t) => { other = t; return ''; });
  const parkedBy = (r.match(/^(\S+) was parked/) ?? [])[1];
  const old = g.visit_date < '2026-08-19';
  if (/ from our map point/.test(r)) {
    const head = r.slice(0, r.indexOf(': ')) + '.';
    if (/inside its Samsara place/.test(r)) {
      issues.push(head + " The truck was inside the client's Samsara place, so " + MAP_POINT + '.');
      fix.push('Move the map point in Jobber to where the truck parks (inside the Samsara place).');
    } else if (/outside its Samsara place too/.test(r)) {
      issues.push(head + " The truck was outside the client's Samsara place too, so both our map point (in Jobber) and the Samsara place are probably in the wrong spot.");
      fix.push('Check the address, then move the map point in Jobber and the Samsara place to where the truck parks.');
    } else if (/no Samsara place/.test(r)) {
      issues.push(head + ' The client has no Samsara place, and ' + MAP_POINT + '.');
      fix.push('Move the map point in Jobber to where the truck parks, and create a Samsara place for the client.');
    } else {
      issues.push(head + ' ' + MAP_POINT[0].toUpperCase() + MAP_POINT.slice(1) + '.');
      fix.push('Move the map point in Jobber to where the truck parks.');
    }
  } else if (/ was parked here /.test(r)) {
    issues.push(r.replace(/ when it was marked complete.*$/, ' when the job was marked complete') + (/time was not saved/.test(r) ? ', but no time on site was saved.' : '.'));
    if (!other) fix.push(old ? "Save Samsara's stay for this visit: it is older than our truck stop records (Aug 20), so it does not fill by itself."
                             : 'Nothing to do by hand: the time fills automatically overnight.');
  } else if (kind === 'nopoint' && g.noProperty) {
    issues.push('The visit has no property set, so we cannot tell whether a truck was there.');
    fix.push(g.clientAddress ? 'Set the property on the visit (the client has one: ' + g.clientAddress + ').' : 'Set the property on the visit.');
  } else if (kind === 'nopoint') {
    issues.push('The property has no map point, so we cannot tell whether a truck was there.');
    fix.push('Check the address in Jobber so the property gets a map point.');
  } else if (kind === 'noplace') {
    issues.push('The client has no place in Samsara, and no truck was parked at our map point when the job was marked complete.');
    fix.push('Create a Samsara place for the client at its address, then check the truck on the visit and the completion time.');
  } else if (kind === 'placefar') {
    issues.push(r[0].toUpperCase() + r.slice(1).replace('our address', 'our map point for the address') + ', so one of the two is in the wrong spot.');
    fix.push('Check which one is right, then move the Samsara place or the map point in Jobber.');
  } else if (kind === 'stay') {
    issues.push(r.replace(/, but it was marked complete (.*)$/, ', but the job was marked complete $1, so that stay does not match the job.')
                 .replace(/, but it has no completion time$/, ', but the job has no completion time.'));
    fix.push('The job was marked complete away from the site. If that stay was the service, enter the time on site in Admin Review, and ask the driver to mark jobs complete on site.');
  } else if (kind === 'passed') {
    issues.push(r.replace('only drove past', 'only drove past the address') + ': no stop long enough to be the service.');
    fix.push('Check with the driver whether the service was done. If it was, the truck parked out of range: check the map point and the truck on the visit.');
  } else if (kind === 'never') {
    issues.push(r.replace('no truck came within', 'No truck came within').replace(/\)$/, ') of our map point.'));
    fix.push('Check the truck on the visit and the address. If the service was done, enter the time on site in Admin Review.');
  } else if (kind === 'nogps') {
    issues.push('No truck GPS was found near the address that day.');
    fix.push('Check the visit date. If the service was done, enter the time on site in Admin Review.');
  } else issues.push(r);
  if (other) {
    issues.push('The visit is set to ' + other + (parkedBy ? ', but ' + parkedBy + ' was the truck parked there.' : '.'));
    fix.unshift('Change the truck on the visit to ' + (parkedBy ?? 'the truck that was there') + ' (Viktor can do it).' +
      (old ? " The visit is older than our truck stop records (Aug 20), so also save Samsara's stay for it." : ' The time then fills overnight.'));
  }
  return { issues, suggestion: fix.join(' ') };
}
const data = rows.map(({ g: g0, line }) => {
  const a0 = addr.get(g0.visit_id);
  const only = a0 && !a0.property_id ? (clientProps.get(a0.client_id) ?? []) : [];
  const clientAddress = only.length === 1 ? [only[0].address, only[0].city].filter(Boolean).join(', ') : '';
  const g = { ...g0, noProperty: !!a0 && !a0.property_id, clientAddress };
  const reason = line.includes(': ') ? line.slice(line.indexOf(': ') + 2) : line;
  const kind = KINDS.find(([, re]) => re.test(reason)) ?? ['other', null, 'Other'];
  const s = g.stop_at_completion;
  const truckFor = s ?? (g.truck ? { truck: g.truck, truck_samsara_id: g.truck_samsara_id } : g.closest) ?? null;
  const anchor = g.completed_at ? Date.parse(g.completed_at) : Date.parse(g.visit_date + 'T12:00:00-04:00');
  const a = addr.get(g.visit_id);
  return {
    id: g.visit_id, date: g.visit_date, client: g.client_code ?? '', name: g.client_name ?? '',
    address: [a?.properties?.address, a?.properties?.city].filter(Boolean).join(', ') || g.clientAddress, service: g.service ?? '',
    truck: g.truck ?? '', completed: et(g.completed_at), rk: kind[0], rl: kind[2],
    ...(({ issues, suggestion }) => ({ issues, reason: issues.join(' '), suggestion }))(explain(kind[0], reason, g)),
    // Samsara's stay when the alert could read it (the times Samsara shows), else our GPS stop (2026-10-14)
    placeId: g.property_place_id || (g.client_place_ids ?? [])[0] || '',
    placeEndMs: Date.parse(g.visit_date + 'T23:59:59.999-04:00'), month: g.visit_date.slice(0, 7),
    truckAny: truckFor?.truck ?? '', samsaraVehicle: truckFor?.truck_samsara_id ?? '',
    endMs: anchor + 3 * 3600e3, durSec: 6 * 3600,
  };
});
const counts = data.reduce((m, d) => (m[d.rk] = (m[d.rk] || 0) + 1, m), {});
const today = new Date().toLocaleDateString('en-US', { timeZone: 'America/New_York', month: 'long', day: 'numeric', year: 'numeric' });
const chips = KINDS.filter(([k]) => counts[k]).map(([k, , l]) => `<span class="chip">${l} <b>${counts[k]}</b></span>`).join('\n');

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
.k-offpoint,.k-notsaved,.k-othertruck{color:#2471a3}.k-never,.k-nogps{color:#c0392b}.k-passed{color:#b9770e}.k-nopoint,.k-noplace,.k-placefar{color:#7d3c98}
.note{color:var(--muted);font-size:13px;margin-top:14px}
button{font:inherit;padding:7px 12px;border:1px solid var(--line);border-radius:8px;background:var(--head);color:var(--fg);cursor:pointer}
tr.g td{background:var(--head);font-weight:600;cursor:pointer}
ul.iss{margin:0;padding-left:18px}ul.iss li+li{margin-top:4px}
tr.g .gc{color:var(--muted);font-weight:400;margin-left:8px}
</style></head><body><div class="wrap">
<h1>Visits Missing Time on Site</h1>
<p class="sub">Completed client visits since ${from} with no time on site, as of ${today} (Eastern time). Each issue comes from the 11 AM Slack alert for that visit, with a suggested fix.${placesUnread ? ` Samsara places could not be read for ${placesUnread} of the dates, so their place reasons are left out.` : ''}</p>
<div class="chips"><span class="chip"><b>${data.length}</b> visits</span>
${chips}</div>
<div class="bar">
<input type="search" id="q" placeholder="Search client, address, truck, visit #">
<select id="group"><option value="">No grouping</option><option value="client" selected>Group by client</option><option value="rl">Group by issue</option><option value="truckAny">Group by truck</option><option value="month">Group by month</option></select>
<select id="reason"><option value="">All issues</option>${KINDS.filter(([k]) => counts[k]).map(([k, , l]) => `<option value="${k}">${l}</option>`).join('')}</select>
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
<p class="note">The property opens the client's Place in Samsara. The truck link opens that truck in Samsara for the 6 hours around the completion time (Samsara shows times in your computer's time zone).</p>
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
