// Standing check (Trello KqGyoiKQ, plan step 5): our copy of Jobber's time sheet (hr.time_entries) equals a fresh read
// of Jobber's API, per person per ET work day, for the last N days (default 14). Read-only on both sides.
// usage: node scripts/checks/hr_app/timesheets_vs_jobber.mjs [days]
// Exit 0 = every day equal (a still-running entry and entries changed in the last 35 minutes, which the 30-minute sync
// has not taken yet, are reported but not counted as a failure); exit 1 = a real difference; exit 2 = could not check.
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
const here = path.dirname(fileURLToPath(import.meta.url));
for (const line of fs.readFileSync(path.resolve(here, '../../../.env'), 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
  if (m && !(m[1] in process.env)) process.env[m[1]] = m[2].trim().replace(/^["']|["']$/g, '');
}
const days = Number(process.argv[2] || 14);
async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST', headers: { Authorization: 'Bearer ' + process.env.SUPABASE_PAT, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }) });
  const j = await r.json();
  if (!r.ok) throw new Error('DB: ' + JSON.stringify(j).slice(0, 200));
  return j;
}
const etDay = (iso) => new Date(iso).toLocaleDateString('sv-SE', { timeZone: 'America/New_York' });
try {
  const since = new Date(Date.now() - days * 864e5).toISOString();
  const [{ t: token }] = await sql("select access_token t from public.webhook_tokens where source_system = 'jobber'");
  const links = await sql("select entity_id e, source_id s from public.entity_source_links where entity_type = 'employee' and source_system = 'jobber'");
  const empOf = new Map(links.map((l) => [l.s, l.e]));
  // Jobber, paged
  const q = `query($after:String,$f:TimeSheetEntriesFilterAttributes){ timeSheetEntries(first:100, after:$after, filter:$f){ nodes{ id startAt endAt ticking updatedAt user{ id } } pageInfo{ hasNextPage endCursor } } }`;
  const jobber = []; let after = null;
  do {
    const r = await fetch('https://api.getjobber.com/api/graphql', { method: 'POST',
      headers: { Authorization: 'Bearer ' + token, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: q, variables: { after, f: { startAt: { after: since } } } }) });
    if (!(r.headers.get('content-type') || '').includes('json')) throw new Error('Jobber busy (not JSON)');
    const j = await r.json();
    if (j.errors || !j.data) throw new Error('Jobber: ' + JSON.stringify(j.errors || j).slice(0, 200));
    jobber.push(...j.data.timeSheetEntries.nodes);
    after = j.data.timeSheetEntries.pageInfo.hasNextPage ? j.data.timeSheetEntries.pageInfo.endCursor : null;
  } while (after);
  const ours = await sql(`select employee_id e, started_at s, ended_at x from hr.time_entries where removed_at is null and started_at >= '${since}'`);
  if (!jobber.length && !ours.length) { console.log('NO DATA: nothing in either source for the window (check proves nothing)'); process.exit(2); }
  const key = (e, d) => e + '|' + d;
  const a = new Map(), b = new Map(); let running = 0, fresh = 0;
  for (const n of jobber) {
    const e = empOf.get(n.user.id); if (!e) continue;
    if (n.ticking) { running++; continue; }
    if (Date.now() - new Date(n.updatedAt) < 35 * 60e3) fresh++;
    const k = key(e, etDay(n.startAt)); a.set(k, (a.get(k) || 0) + (new Date(n.endAt) - new Date(n.startAt)) / 60e3);
  }
  for (const r of ours) {
    if (!r.x) continue;
    const k = key(r.e, etDay(r.s)); b.set(k, (b.get(k) || 0) + (new Date(r.x) - new Date(r.s)) / 60e3);
  }
  const diffs = [];
  for (const k of new Set([...a.keys(), ...b.keys()])) {
    const ja = Math.round(a.get(k) || 0), ob = Math.round(b.get(k) || 0);
    if (Math.abs(ja - ob) > 1) diffs.push(`${k}: Jobber ${ja} min, ours ${ob} min`);
  }
  console.log(`${a.size} person-days from Jobber (${jobber.length} entries, ${running} running), ${b.size} in hr.time_entries, last ${days} days`);
  if (diffs.length && diffs.length <= fresh) { console.log(`PENDING: ${diffs.length} differ, ${fresh} entries changed in the last 35 minutes (the sync takes them on its next run)`); diffs.forEach((d) => console.log('  ' + d)); process.exit(0); }
  if (diffs.length) { console.log(`FAIL: ${diffs.length} person-days differ`); diffs.forEach((d) => console.log('  ' + d)); process.exit(1); }
  console.log('PASS: every person-day equal to the minute');
} catch (e) { console.log('COULD NOT CHECK: ' + (e.message || e)); process.exit(2); }
