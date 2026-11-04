// Proves that scripts/checks/bsi_routing.sql can fail: for each case, inside ONE sub-transaction that is always undone,
// put back a defect (or set up a shape), run the check file as it is on disk, and read which rows fail. Every named row
// must FAIL and every other row stay ok; a control case must fail nothing. At the end, every row of the check must have
// failed in at least one case, or the suite fails. Nothing is kept: every write sits in a PL/pgSQL block that raises
// 'undo' at its end, and a swapped view or function is a temp object of that block. No public.visits row is written.
// The fixtures are real clients as of 2026-11-04. The two "rule INVERTED" cases and "the rule REMOVED from the DERM
// fields" assume no routed client has line 27 on a visit with a live manifest: the day one does, they go red and their
// expected rows need updating, which does not mean the rule broke. A fixture that drifts raises its own error.
// Run from Supabase/: node --env-file=.env scripts/checks/bsi_routing_mutations.mjs
import fs from 'node:fs'
const CHECK = new URL('./bsi_routing.sql', import.meta.url)
const ROWS = 18   // the check's row count; a dropped row must not pass quietly
const api = `https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`
if (!process.env.SUPABASE_PROJECT_ID || !process.env.SUPABASE_PAT) throw new Error('needs SUPABASE_PROJECT_ID and SUPABASE_PAT (Supabase/.env)')

const run = async (mutations, swaps = []) => {
  let check = fs.readFileSync(CHECK, 'utf8').replace(/;\s*$/, '')
  for (const [from, to] of swaps) {
    if (!check.includes(from)) throw new Error('swap target not in the check: ' + from)
    check = check.split(from).join(to)
  }
  if (check.includes('$chk$') || mutations.includes('$chk$')) throw new Error('tag collision')
  const sql = `set local search_path = public, extensions;
do $m$
declare r record; v_out jsonb := '[]'::jsonb;
begin
  begin
    ${mutations}
    for r in execute $chk$${check}$chk$ loop
      v_out := v_out || jsonb_build_object('row', r.check_name, 'status', r.status);
    end loop;
    raise exception 'undo';
  exception when others then
    if sqlerrm <> 'undo' then raise; end if;
  end;
  perform set_config('m.out', v_out::text, false);
end $m$;
select current_setting('m.out')::jsonb as r;`
  const res = await fetch(api, { method: 'POST', headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }) })
  const j = JSON.parse(await res.text())
  if (!Array.isArray(j)) throw new Error(String(j.message).split('\n')[0])
  return j[j.length - 1].r
}

const q = (s) => s.replace(/'/g, "''")   // the text of a SQL literal
const RULE = '(NOT fn_client_files_with_bsi(v.client_id))'
// a view of the DERM side with the rule replaced (the check is pointed at it)
const viewSwap = (view, temp, to) => `execute 'create temp view ${temp} as ' || replace(pg_get_viewdef('${view}'::regclass, false), '${RULE}', '${to}');
    if position('NOT fn_client_files_with_bsi' in pg_get_viewdef('pg_temp.${temp}'::regclass, false)) > 0 then raise exception 'mutation did not land'; end if;`
const heldOnMut = `execute 'create temp view v_held_mut as ' || replace(pg_get_viewdef('public.v_derm_portal_queue_held'::regclass, false), 'FROM v_derm_portal_fields f', 'FROM pg_temp.v_fields_mut f');
    if position('v_fields_mut' in pg_get_viewdef('pg_temp.v_held_mut'::regclass, false)) = 0 then raise exception 'mutation did not land'; end if;`
// the health logger with one piece replaced (the check reads its code)
const loggerSwap = (from, to) => `execute replace(replace(pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure),
      'FUNCTION public.log_rpa_derm_health(', 'FUNCTION pg_temp.log_mut('), '${q(from)}', '${q(to)}');
    if (select prosrc from pg_proc where oid = 'pg_temp.log_mut()'::regprocedure) = (select prosrc from pg_proc where oid = 'public.log_rpa_derm_health()'::regprocedure)
      then raise exception 'mutation did not land'; end if;`
const l27job = (job) => `insert into public.line_items (job_id, name, quantity, unit_price, total_price) values (${job}, '27 - GDO Online Reporting', 1, 0, 0);`
const l27visit = (visit) => `insert into public.line_items (visit_id, name, quantity, unit_price, total_price) values (${visit}, '27 - GDO Online Reporting', 1, 0, 0);`
const boca = (property, client) => `update public.properties set city = 'Boca Raton' where id = ${property} and client_id = ${client};`
const idle = `(select p.id from public.properties p
       where p.deleted_at is null and p.city = 'Miami'
         and not exists (select 1 from public.gdos g where g.client_id = p.client_id and g.status in ('ACTIVE', 'EXPIRED'))
         and not exists (select 1 from public.jobs j join public.line_items li on li.job_id = j.id and li.visit_id is null
                          where j.client_id = p.client_id and public.fn_line_item_is_gdo_reporting(li.name))
         and not exists (select 1 from public.visits v where v.client_id = p.client_id and v.deleted_at is null
                          and v.visit_date >= public.rpa_launch_cutoff() and public.fn_visit_is_gdo_reporting(v.id))
       order by p.id limit 1)`
const newestRun = `(select s.id from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.started_at desc, s.id desc limit 1)`
// F: client 275 (no permit) routed, line 27 on its completed visit 5891, which has a live manifest.
// G: client 323 (no permit) routed, line 27 on its completed visit 6575, which does not require DERM.
const F = `${boca(72, 275)} ${l27visit(5891)}
    if not public.fn_client_files_with_bsi(275) then raise exception 'fixture F does not file with BSI'; end if;`
const G = `${boca(44, 323)} ${l27visit(6575)}
    if not public.fn_client_files_with_bsi(323) then raise exception 'fixture G does not file with BSI'; end if;`
const LOGGER = [`'public.log_rpa_derm_health()'::regprocedure`, `'pg_temp.log_mut()'::regprocedure`]
const fieldsAll = ['public.v_derm_portal_fields', 'pg_temp.v_fields_mut']
// (two row names say derm.gdo_report_status, so only its uses as a relation are swapped)
const statusAll = [['from derm.gdo_report_status', 'from pg_temp.v_status_mut'], [`'derm.gdo_report_status'::regclass`, `'pg_temp.v_status_mut'::regclass`]]
const UNMATCHED = 'no line 27 on a routed client not matched'
const CTL_RULE = 'CONTROL: the rule is in the three views'
const CTL_BLOCK = "CONTROL: the logger's routing block"
const NOT_EMPTY = 'CONTROL: the DERM side is not empty'

const cases = [
  ['as is (control: nothing fails)', '', [], []],

  // the rule in each object: an inversion or a removal, read by the row that should catch it
  ['the rule INVERTED in the DERM fields', viewSwap('public.v_derm_portal_fields', 'v_fields_mut', 'fn_client_files_with_bsi(v.client_id)'), [fieldsAll],
   ['the DERM fields hold exactly', NOT_EMPTY]],
  ['the rule REMOVED from the DERM fields', viewSwap('public.v_derm_portal_fields', 'v_fields_mut', 'true'), [fieldsAll], [CTL_RULE]],
  ['the rule INVERTED in derm.gdo_report_status', viewSwap('derm.gdo_report_status', 'v_status_mut', 'fn_client_files_with_bsi(v.client_id)'), statusAll,
   ['derm.gdo_report_status holds exactly', NOT_EMPTY]],
  ['fixture F, the rule intact (control: only "not matched")', F, [], [UNMATCHED]],
  ['fixture G, the rule intact (control: only "not matched")', G, [], [UNMATCHED]],
  ['fixture F, the rule out of the DERM fields that one row reads',
   `${F} ${viewSwap('public.v_derm_portal_fields', 'v_fields_mut', 'true')}`, [['public.v_derm_portal_fields f where', 'pg_temp.v_fields_mut f where']],
   ['no routed client in the DERM fields', UNMATCHED]],
  ['fixture F, the rule out of the held view that one row reads',
   `${F} ${viewSwap('public.v_derm_portal_fields', 'v_fields_mut', 'true')} ${heldOnMut}`, [['from public.v_derm_portal_queue_held h join', 'from pg_temp.v_held_mut h join']],
   ['no routed client held in the DERM queue', UNMATCHED]],
  ['fixture G, the rule out of the mismatch view that one row reads',
   `${G} ${viewSwap('public.v_gdo_reporting_derm_mismatch', 'v_mis_mut', 'true')}`, [['from public.v_gdo_reporting_derm_mismatch m where', 'from pg_temp.v_mis_mut m where']],
   ['no routed client in the line-27 / DERM-required mismatch view', UNMATCHED]],
  ['fixture F, the rule out of derm.gdo_report_status that one row reads',
   `${F} ${viewSwap('derm.gdo_report_status', 'v_status_mut', 'true')}`, [['from derm.gdo_report_status s where s.client_id', 'from pg_temp.v_status_mut s where s.client_id']],
   ['no routed client in derm.gdo_report_status', UNMATCHED]],

  // the logger's code
  ['the logger: its no-permit exclusion moved into a -- comment', loggerSwap('not public.fn_client_files_with_bsi(c.id)', 'true -- not public.fn_client_files_with_bsi(c.id)'), [LOGGER], [CTL_RULE]],
  ['the logger: its no-permit exclusion moved into a /* */ comment', loggerSwap('not public.fn_client_files_with_bsi(c.id)', '/* not public.fn_client_files_with_bsi(c.id) */ true'), [LOGGER], [CTL_RULE]],
  ['the logger: its routed column moved into a /* */ comment', loggerSwap('public.fn_client_files_with_bsi(w.client_id) as routed', '/* public.fn_client_files_with_bsi(w.client_id) as routed */ false as routed'), [LOGGER], [CTL_BLOCK]],
  ['the logger: skipped and cancelled visits count again', loggerSwap(`               and coalesce(v.visit_status, '') not in ('skipped', 'cancelled')\n`, ''), [LOGGER], [CTL_BLOCK]],
  ['the logger: the key back to the highest visit id', loggerSwap(
     `coalesce(left(md5(string_agg(distinct k.done_id::text, ',' order by k.done_id::text)), 8), '0') as visits_fp`, `coalesce(max(k.done_id)::text, '0') as visits_fp`), [LOGGER], [CTL_BLOCK]],
  ['the logger: the routing alerts dead', loggerSwap('from k group by k.kind, k.client_id', 'from k where false group by k.kind, k.client_id'), [LOGGER], [CTL_BLOCK]],
  ['the logger: a comment added in the routing block (control: nothing fails)', loggerSwap('c.id = g.client_id) x;', 'c.id = g.client_id) x;-- a comment'), [LOGGER], []],

  // shapes of work
  ['041-MB (GDO): the property with its line-27 work in Boca Raton', boca(138, 10), [], ['no line-27 work at a Boca Raton property of a client with a live GDO']],
  ['110-CLA (GDO): its billing address, no work, in Boca Raton (control: nothing fails)', boca(501, 372), [], []],
  ['client 245: line 27 on its Boca Raton job',
   `update public.jobs set job_status = 'upcoming' where id = 962 and client_id = 245; ${l27job(962)}`, [], [UNMATCHED]],
  ['client 245: line 27 on its job, moved to the Beverly Hills billing address',
   `update public.jobs set job_status = 'upcoming', property_id = 396 where id = 962 and client_id = 245; ${l27job(962)}`, [],
   [UNMATCHED, 'no line-27 work at a property elsewhere of a client that files with BSI']],
  ['client 512 in Boca Raton, line 27 on its CANCELLED visit 8181 only (control: not work, nothing fails)', `${boca(1047, 512)} ${l27visit(8181)}`, [], []],
  ['client 300 (GDO) in Boca Raton, line 27 on its SKIPPED visit 6310 only (control: not work, nothing fails)', `${boca(82, 300)} ${l27visit(6310)}`, [], []],
  ['client 512 in Boca Raton, line 27 on its SCHEDULED visit 8121', `${boca(1047, 512)} ${l27visit(8121)}`, [], [UNMATCHED]],
  ['client 245: line 27 on its ARCHIVED job 962 (control: not work, nothing fails)', l27job(962), [], []],
  ['client 275 in Boca Raton, line 27 on visit 1258 before the cutoff (control: not work, nothing fails)', `${boca(72, 275)} ${l27visit(1258)}`, [], []],
  ['test client 381: line 27 on its open job 766 (control: never a test client, nothing fails)', l27job(766), [], []],
  ['Grove (matched by Yan, 2026-11-04_1338): line 27 on its open job 1325 (control: a matched client does not fail, nothing fails)',
   `if (select client_id from public.jobs where id = 1325) <> 357 then raise exception 'fixture job 1325 is not Grove'; end if; ${l27job(1325)}`, [], []],

  // cities
  ['an accented "Bóca Raton" on an idle Miami property', `update public.properties set city = 'Bóca Raton' where id = ${idle};`, [], ['no live property whose city is near Boca Raton']],
  ['"Boca Raton West" (read as Boca Raton by its prefix) on an idle Miami property', `update public.properties set city = 'Boca Raton West' where id = ${idle};`, [], ['no live property whose city is near Boca Raton']],
  ['"Boca Raton, FL 33431" on an idle Miami property (control: plain, nothing fails)', `update public.properties set city = 'Boca Raton, FL 33431' where id = ${idle};`, [], []],

  // permits (the number is made up, and undone)
  ['a made-up CCN on client 275, which files with DERM', `insert into public.gdos (client_id, property_id, permit_type, gdo_number, status) values (275, 72, 'CCN', 'MUT-FAKE-NUMBER', 'ACTIVE');`, [],
   ['no live CCN on a client that files with DERM']],

  // the logger's last run
  ['the newest logger run lists a client that files with BSI (357) as a no-permit client',
   `update public.sync_log set details = jsonb_set(jsonb_set(details, '{reasons}', (details -> 'reasons')
        || jsonb_build_array(jsonb_build_object('client_code', (select client_code from public.clients where id = 357), 'jobs', '[1]'::jsonb))),
        '{line27_no_permit_clients}', to_jsonb((details ->> 'line27_no_permit_clients')::int + 1))
     where id = ${newestRun};
    if (select client_code from public.clients where id = 357) is null then raise exception 'fixture 357 has no code'; end if;`, [],
   ['the newest health-logger run names no client that files with BSI']],
  ['the newest logger run counts a no-permit item it does not list',
   `update public.sync_log set details = jsonb_set(details, '{line27_no_permit_clients}', to_jsonb((details ->> 'line27_no_permit_clients')::int + 1))
     where id = ${newestRun};`, [], ['CONTROL: the newest logger run']],
  ['the logger has not run for 30 days',
   `update public.sync_log set started_at = started_at - interval '30 days' where sync_source = 'rpa-derm-health' and started_at > now() - interval '30 days';`, [], ['CONTROL: the newest logger run']],

  // the controls' own premises
  ['Grove Kosher (357) out of Boca Raton', `update public.properties set city = 'Miami' where id = 4 and client_id = 357;`, [], ['CONTROL: Grove Kosher']],
  ['a looser Boca Raton test (any position) in the spellings row',
   `create function pg_temp.fn_city_loose(p_city text) returns boolean language sql as $f$ select regexp_replace(lower(coalesce(p_city, '')), '[^a-z]+', '', 'g') like '%bocaraton%' $f$;`,
   [["public.fn_city_is_boca_raton('", "pg_temp.fn_city_loose('"]], ['CONTROL: the Boca Raton test reads']],
]

let allPass = true
const everFailed = new Set(), rowNames = new Set()
for (const [label, mutations, swaps, mustFail] of cases) {
  let rows
  try { rows = await run(mutations, swaps) } catch (e) { console.log(JSON.stringify({ label, ERROR: e.message })); allPass = false; continue }
  const failedRows = rows.filter((x) => x.status !== 'ok')
  // a row's name can hold a swapped text only by accident: names are compared as they came back
  for (const x of rows) rowNames.add(x.row)
  for (const x of failedRows) everFailed.add(x.row)
  const failed = failedRows.map((x) => `${x.row} [${x.status}]`)
  const missing = mustFail.filter((m) => !failed.some((f) => f.startsWith(m)))
  const extra = failed.filter((f) => !mustFail.some((m) => f.startsWith(m)))
  const pass = missing.length === 0 && extra.length === 0 && rows.length === ROWS
  allPass &&= pass
  console.log(JSON.stringify({ label, pass, rows: rows.length, failed: failed.map((f) => f.slice(0, 70)), missing, extra }))
}
const neverFailed = [...rowNames].filter((r) => !everFailed.has(r))
if (neverFailed.length || rowNames.size !== ROWS) allPass = false
console.log(JSON.stringify({ pass: allPass, cases: cases.length, rows: rowNames.size, rows_that_failed_at_least_once: everFailed.size, never_failed: neverFailed }))
process.exit(allPass ? 0 : 1)
