// access-watch.mjs - the 24-hour watch after an app's access goes on (plan A8,
// Building Apps/HR App/docs/specs/2026-10-21-access-switch-on-and-invite-plan.md).
//
// Usage: node scripts/checks/access-watch.mjs [hours=6]
// Reads only. Reports, for the last N hours (or since the earliest on_since, whichever is later):
//   1. gateway 403s on /rest/v1 by JWT subject, named (staff = trouble; jon.v / unclogme@ / test.agent = decision 9);
//   2. hr.check_app_action calls that did not return 200, by subject (8 edge functions refuse with HTTP 200, so this is
//      where their refusals show), plus a control count of all check_app_action calls;
//   3. hr.access_refusals since each app's on_since (only shared actions whose partner is not on should appear);
//   4. audit.logs writes per app label since its on_since (a busy app going silent is trouble; this log records
//      successes only, so it cannot show that something works);
//   5. the read gate setting.
// Exit 1 when a staff person was refused anywhere.
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { execFileSync } from 'child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
for (const l of fs.readFileSync(path.resolve(here, '../../.env'), 'utf8').split(/\r?\n/)) {
  const m = l.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
  if (m && !(m[1] in process.env)) process.env[m[1]] = m[2].trim().replace(/^["']|["']$/g, '');
}
const REF = process.env.SUPABASE_PROJECT_ID, PAT = process.env.SUPABASE_PAT;
const hours = Number(process.argv[2] || 6);
const STAFF = {
  '5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b': 'Fred', 'cb6ae560-ebd5-4b6e-b654-f3d9bb3662e8': 'Diego (contact@)',
  '5c5df96c-1924-410a-a996-e3e58c44e3c2': 'Serena', '77d4c343-1e21-44eb-98ce-c221028d028a': 'Aaron',
  '71e294b9-9898-4c21-a48d-d970e32d829c': 'Yannick',
};
const NOACCESS = { '8bdb9ba7-e917-466d-bdb1-c525dbf90194': 'jon.v', 'ebd7aebe-d77d-4e18-a33d-00e1dc55be9f': 'unclogme@',
  '46ff7904-faef-45c2-8aa2-a5a185c042ec': 'test.agent' };
const who = s => STAFF[s] || NOACCESS[s] || (s ? s.slice(0, 8) : '(no subject)');
let staffRefused = 0;

async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${REF}/database/query`, {
    method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json' }, body: JSON.stringify({ query }) });
  const j = await r.json(); if (r.status > 299) throw new Error(JSON.stringify(j).slice(0, 300)); return j;
}
// whole minutes, Z, at most 24 h per call (edge_logs.js splits longer ranges itself)
const iso = d => new Date(Math.floor(d.getTime() / 60000) * 60000).toISOString().replace(/\.\d{3}Z$/, 'Z');
function logs(query, start, end) {
  const out = path.join(process.env.TEMP || '/tmp', `access-watch-${process.pid}-${Math.random().toString(36).slice(2)}.json`);
  execFileSync('node', [path.resolve(here, '../probes/edge_logs.js'), query, out, iso(start), iso(end)], { stdio: ['ignore', 'ignore', 'inherit'] });
  const files = fs.existsSync(out) ? [out] : fs.readdirSync(path.dirname(out)).filter(f => f.startsWith(path.basename(out, '.json') + '.')).map(f => path.join(path.dirname(out), f));
  const rows = files.flatMap(f => { const j = JSON.parse(fs.readFileSync(f, 'utf8')); fs.unlinkSync(f); if (j.error) throw new Error(JSON.stringify(j.error)); return j.result || []; });
  return rows;
}

(async () => {
  const apps = await sql(`select app, mode, on_since from hr.access_apps where parent is null order by app`);
  const onApps = apps.filter(a => a.mode === 'on' && a.app !== 'hr');
  const end = new Date(); const start = new Date(end.getTime() - hours * 3600e3);
  console.log(`== access watch, last ${hours} h. On: ${onApps.map(a => a.app).join(', ') || 'none'}`);

  // 1. gateway 403s by subject
  const sub = "log_attributes['request.sb.jwt.authorization.payload.subject']";
  const r403 = logs(`select ${sub} as s, count() as n, countIf(log_attributes['request.path'] like '/auth/v1/%') as auth from logs where source = 'edge_logs' and log_attributes['response.status_code'] = '403' and log_attributes['request.path'] like '/rest/v1/%' group by s`, start, end);
  const agg = {}; for (const r of r403) agg[r.s] = (agg[r.s] || 0) + Number(r.n);
  console.log('\n1. REST 403s by person:', Object.keys(agg).length ? '' : 'none');
  for (const [s, n] of Object.entries(agg)) { const staff = !!STAFF[s]; if (staff) staffRefused += n; console.log(`   ${staff ? 'STAFF ' : '      '}${who(s)}: ${n}`); }

  // 2. check_app_action not 200
  const rca = logs(`select ${sub} as s, log_attributes['response.status_code'] as st, count() as n from logs where source = 'edge_logs' and log_attributes['request.path'] like '%/rpc/check_app_action%' group by s, st`, start, end);
  const total = rca.reduce((a, r) => a + Number(r.n), 0);
  const bad = rca.filter(r => r.st !== '200');
  console.log(`\n2. edge access checks: ${total} calls (control), not 200: ${bad.reduce((a, r) => a + Number(r.n), 0)}`);
  for (const r of bad) { const staff = !!STAFF[r.s]; if (staff) staffRefused += Number(r.n); console.log(`   ${staff ? 'STAFF ' : '      '}${who(r.s)} HTTP ${r.st}: ${r.n}`); }

  // 3. watch log rows after on_since
  const ref = await sql(`select r.app, r.what, r.email, r.needs, r.has, count(*) n, max(r.at) last from hr.access_refusals r join hr.access_apps a on a.app = r.app
    where a.mode = 'on' and r.at >= a.on_since group by 1,2,3,4,5 order by n desc limit 30`);
  console.log(`\n3. watch-log rows after each app's switch-on: ${ref.length ? '' : 'none'}`);
  for (const r of ref) console.log(`   ${r.app} "${r.what}" ${r.email} needs ${r.needs} has ${r.has}: ${r.n}`);

  // 4. writes per app label since on_since
  const labels = { stamp_studio: 'derm-stamp-studio', picture_planner: 'picture-planner', admin_review: 'admin-review',
    derm_tracker: 'derm-tracker', client_app: 'client-app', visit_calendar: 'visit-calendar' };
  console.log('\n4. writes since switch-on (audit.logs, successes only):');
  for (const a of onApps) {
    const w = await sql(`select coalesce(jwt_claims->>'email','(server)') e, count(*) n, max(changed_at at time zone 'America/New_York') last
      from audit.logs where app_source = '${labels[a.app]}' and changed_at >= '${a.on_since}' group by 1 order by n desc`);
    console.log(`   ${a.app} (on since ${new Date(a.on_since).toISOString()}): ${w.map(x => `${x.e} ${x.n}`).join(', ') || 'no writes yet'}`);
  }

  // 5. read gate
  const g = await sql(`select coalesce((select array_to_string(setconfig, ' ') from pg_db_role_setting s join pg_roles r on r.oid = s.setrole where r.rolname = 'authenticator'), '') ~ 'pgrst.db_pre_request=public.fn_request_gate' as gate_on`);
  console.log(`\n5. read gate setting: ${g[0].gate_on ? 'set' : 'NOT SET'}; it refuses only once every app is on (${apps.every(a => a.mode === 'on') ? 'all on' : 'not all on yet'})`);

  console.log(`\n${staffRefused ? `TROUBLE: ${staffRefused} staff refusals` : 'No staff refusals.'}`);
  process.exit(staffRefused ? 1 : 0);
})().catch(e => { console.error(e.message); process.exit(2); });
