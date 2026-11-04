// Proves that scripts/checks/bsi_routing.sql can fail: for each case, inside ONE sub-transaction that is always undone,
// put back a defect (or set up a shape), run the check file as it is on disk, and read which rows fail. Every named row
// must FAIL and every other row stay ok; a control case must fail nothing. Nothing is kept: every write sits in a
// PL/pgSQL block that raises 'undo' at its end, and a swapped view or function is a temp object of that block.
// No public.visits row is written. Run from Supabase/: node --env-file=.env scripts/checks/bsi_routing_mutations.mjs
import fs from 'node:fs'
const CHECK = new URL('./bsi_routing.sql', import.meta.url)
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

// a view of the DERM side with the rule replaced (the check is pointed at it)
const viewSwap = (view, temp, to) => `execute 'create temp view ${temp} as ' || replace(pg_get_viewdef('${view}'::regclass, false),
      '(NOT fn_client_files_with_bsi(v.client_id))', '${to}');
    if position('NOT fn_client_files_with_bsi' in pg_get_viewdef('pg_temp.${temp}'::regclass, false)) > 0 then raise exception 'mutation did not land'; end if;`
// the health logger with one call replaced (the check reads its code)
const loggerSwap = (from, to) => `execute replace(replace(pg_get_functiondef('public.log_rpa_derm_health()'::regprocedure),
      'FUNCTION public.log_rpa_derm_health(', 'FUNCTION pg_temp.log_mut('), '${from}', '${to}');
    if position('${from}' in (select prosrc from pg_proc where oid = 'pg_temp.log_mut()'::regprocedure)) > 0 then raise exception 'mutation did not land'; end if;`
const l27job = (job) => `insert into public.line_items (job_id, name, quantity, unit_price, total_price) values (${job}, '27 - GDO Online Reporting', 1, 0, 0);`
const l27visit = (visit) => `insert into public.line_items (visit_id, name, quantity, unit_price, total_price) values (${visit}, '27 - GDO Online Reporting', 1, 0, 0);`
const idle = `(select p.id from public.properties p
       where p.deleted_at is null and p.city = 'Miami'
         and not exists (select 1 from public.gdos g where g.client_id = p.client_id and g.status in ('ACTIVE', 'EXPIRED'))
         and not exists (select 1 from public.jobs j join public.line_items li on li.job_id = j.id and li.visit_id is null
                          where j.client_id = p.client_id and public.fn_line_item_is_gdo_reporting(li.name))
         and not exists (select 1 from public.visits v where v.client_id = p.client_id and v.deleted_at is null
                          and v.visit_date >= public.rpa_launch_cutoff() and public.fn_visit_is_gdo_reporting(v.id))
       order by p.id limit 1)`
const newestRun = `(select s.id from public.sync_log s where s.sync_source = 'rpa-derm-health' order by s.started_at desc, s.id desc limit 1)`
const fields = (to) => [viewSwap('public.v_derm_portal_fields', 'v_fields_mut', to), [['public.v_derm_portal_fields', 'pg_temp.v_fields_mut']]]
// (two row names say derm.gdo_report_status, so only its uses as a relation are swapped)
const status = (to) => [viewSwap('derm.gdo_report_status', 'v_status_mut', to),
  [['from derm.gdo_report_status', 'from pg_temp.v_status_mut'], [`'derm.gdo_report_status'::regclass`, `'pg_temp.v_status_mut'::regclass`]]]
const logger = (from, to) => [loggerSwap(from, to), [[`'public.log_rpa_derm_health()'::regprocedure`, `'pg_temp.log_mut()'::regprocedure`]]]

const cases = [
  ['as is (control: nothing fails)', '', [], []],
  ['the rule INVERTED in the DERM fields', ...fields('fn_client_files_with_bsi(v.client_id)'),
   ['the DERM fields hold exactly', 'CONTROL: the DERM side is not empty']],
  ['the rule REMOVED from the DERM fields', ...fields('true'), ['CONTROL: the rule is in the four bodies']],
  ['the rule INVERTED in derm.gdo_report_status', ...status('fn_client_files_with_bsi(v.client_id)'),
   ['derm.gdo_report_status holds exactly', 'CONTROL: the DERM side is not empty']],
  ['the logger\'s no-permit exclusion REMOVED (its comment kept)', ...logger('not public.fn_client_files_with_bsi(c.id)', 'true'),
   ['CONTROL: the rule is in the four bodies']],
  ['the logger\'s routed column REMOVED (its comment kept)', ...logger('public.fn_client_files_with_bsi(w.client_id) as routed', 'false as routed'),
   ['CONTROL: the rule is in the four bodies']],
  ['041-MB (GDO): the property with its line-27 work in Boca Raton',
   `update public.properties set city = 'Boca Raton' where id = 138 and client_id = 10;`, [],
   ['no line-27 work at a Boca Raton property of a client with a live GDO']],
  ['110-CLA (GDO): its billing address, no work, in Boca Raton (control: nothing fails)',
   `update public.properties set city = 'Boca Raton' where id = 501 and client_id = 372;`, [], []],
  ['client 245: line 27 on its Boca Raton job',
   `update public.jobs set job_status = 'upcoming' where id = 962 and client_id = 245; ${l27job(962)}`, [],
   ['no line 27 on a routed client not matched']],
  ['client 245: line 27 on its job, moved to the Beverly Hills billing address',
   `update public.jobs set job_status = 'upcoming', property_id = 396 where id = 962 and client_id = 245; ${l27job(962)}`, [],
   ['no line 27 on a routed client not matched', 'no line-27 work at a property elsewhere of a client that files with BSI']],
  ['client 512 in Boca Raton, line 27 on its CANCELLED visit 8181 only (control: not work, nothing fails)',
   `update public.properties set city = 'Boca Raton' where id = 1047 and client_id = 512; ${l27visit(8181)}`, [], []],
  ['client 512 in Boca Raton, line 27 on its SCHEDULED visit 8121',
   `update public.properties set city = 'Boca Raton' where id = 1047 and client_id = 512; ${l27visit(8121)}`, [],
   ['no line 27 on a routed client not matched']],
  ['an accented "Bóca Raton" on an idle Miami property',
   `update public.properties set city = 'Bóca Raton' where id = ${idle};`, [], ['no live property whose city is near Boca Raton']],
  ['"Boca Raton West" (read as Boca Raton by its prefix) on an idle Miami property',
   `update public.properties set city = 'Boca Raton West' where id = ${idle};`, [], ['no live property whose city is near Boca Raton']],
  ['"Boca Raton, FL 33431" on an idle Miami property (control: plain, nothing fails)',
   `update public.properties set city = 'Boca Raton, FL 33431' where id = ${idle};`, [], []],
  ['the newest logger run lists a client that files with BSI (357) as a no-permit client',
   `update public.sync_log set details = jsonb_set(jsonb_set(details, '{reasons}', (details -> 'reasons')
        || jsonb_build_array(jsonb_build_object('client_code', (select client_code from public.clients where id = 357), 'jobs', '[1]'::jsonb))),
        '{line27_no_permit_clients}', to_jsonb((details ->> 'line27_no_permit_clients')::int + 1))
     where id = ${newestRun};
    if (select client_code from public.clients where id = 357) is null then raise exception 'fixture 357 has no code'; end if;`, [],
   ['the newest health-logger run names no client that files with BSI']],
  ['the newest logger run counts a no-permit item it does not list',
   `update public.sync_log set details = jsonb_set(details, '{line27_no_permit_clients}', to_jsonb((details ->> 'line27_no_permit_clients')::int + 1))
     where id = ${newestRun};`, [], ['CONTROL: the newest run\'s no-permit client items']],
]

let rowsAsIs = null, allPass = true
for (const [label, mutations, swaps, mustFail] of cases) {
  let rows
  try { rows = await run(mutations, swaps) } catch (e) { console.log(JSON.stringify({ label, ERROR: e.message })); allPass = false; continue }
  rowsAsIs ??= rows.length
  const failed = rows.filter((x) => x.status !== 'ok').map((x) => `${x.row} [${x.status}]`)
  const missing = mustFail.filter((m) => !failed.some((f) => f.startsWith(m)))
  const extra = failed.filter((f) => !mustFail.some((m) => f.startsWith(m)))
  const pass = missing.length === 0 && extra.length === 0 && rows.length === rowsAsIs
  allPass &&= pass
  console.log(JSON.stringify({ label, pass, rows: rows.length, failed, missing, extra }))
}
console.log(JSON.stringify({ pass: allPass, cases: cases.length, rows: rowsAsIs }))
process.exit(allPass ? 0 : 1)
