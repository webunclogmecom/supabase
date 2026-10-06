// run_tests.js [mutation-name | --live] : the smoke tests of client.get_client_activity (all rolled back).
// A mutation edits the function text first; the named cases must then FAIL (that is the control).
const fs = require('fs'), path = require('path');
const { query } = require('./query.js');
const B = __dirname;
const MUTATIONS = {
  // each: [from, to, cases that must fail]
  merge5s:   ["interval '5 seconds'", "interval '0 seconds'", ['C2 ']],
  chain2m:   ["c.at - lag(c.at) over w > interval '2 minutes'", "c.at - lag(c.at) over w > interval '0 seconds'", ['C5 ']],
  status10s: ["c.client_id = p_client_id and c.changed_at between m.at - interval '10 seconds' and m.at + interval '10 seconds'", "false", ['C4 ']],
  licross:   ["b.at between a.at - interval '2 minutes' and a.at + interval '2 minutes'", "false", ['C7 ']],
  burst20:   [") >= 20", ") >= 2000", ['C13 ']],
  zonefan:   ["le.same_n > 1\n", "le.same_n > 1000\n", ['C1 ']],
  cancel:    ["join di_rank b on b.tbl = a.tbl and b.tx = a.tx and b.body = a.body and b.op <> a.op and b.rn = a.rn", "join di_rank b on false", ['C6 ']],
  atguard:   ["when public.fn_page_staff_name(en.person) like '%@%' then 'Staff (no name on file)'", "when false then ''", ['C17 ']],
  person:    ["when m.person is not null then false\n             -- never background", "when false then false\n             -- never background", ['C12 ']],
  invshell:  ["when m.is_inv_created then 'Invoice created'", "when false then 'Invoice created'", ['C11 ']],
  cardline:  ["and mr.tbl not in ('client_status_changes','job_frequency_changes')\n  ),", "\n  ),", ['C4 ']],
  intake:    ["when m.tbl = 'properties' and pa.intake_id is not null then", "when false then", ['C9 ']],
};
let fn = fs.readFileSync(path.join(B, 'function.sql'), 'utf8');
const mut = process.argv[2] && !process.argv[2].startsWith('--') ? process.argv[2] : null;
if (mut) {
  const [from, to] = MUTATIONS[mut];
  const n = fn.split(from).length - 1;
  if (n < 1) { console.log('MUTATION ANCHOR NOT FOUND', mut); process.exit(2); }
  fn = fn.split(from).join(to);
}
const sub = (s) => s.replace(/__CFG__/g, 'pg_temp.activity_cfg').replace(/__S__/g, 'pg_temp').replace(/__FN__/g, 'pg_temp.get_client_activity');
const live = process.argv.includes('--live');
const subLive = (s) => s.replace(/__FN__/g, 'client.get_client_activity');
const sql = live ? `
select set_config('request.jwt.claims', '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","email":"fred@ayache.com","role":"authenticated"}', false);
${subLive(fs.readFileSync(path.join(B, 'tests.sql'), 'utf8'))}` : `
create temp table activity_cfg as
  select table_name, column_name, label, render_type, fk_table, fk_label_col, sort_order, false as is_system from audit.entity_render_config
   where table_name not in ('properties','jobs','line_items','gdos','client_contacts','client_jobber_contacts','client_locations','invoices');   -- config_rows.sql adds these
${sub(fs.readFileSync(path.join(B, 'config_rows.sql'), 'utf8'))}
${sub(fs.readFileSync(path.join(B, 'helpers.sql'), 'utf8'))}
${sub(fn)}
select set_config('request.jwt.claims', '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","email":"fred@ayache.com","role":"authenticated"}', false);
${sub(fs.readFileSync(path.join(B, 'tests.sql'), 'utf8'))}`;
(async () => {
  const r = await query(sql);
  // the API wraps the raised message: HTTP 400: {"message":"Failed to run sql query: ERROR: P0001: TEST_RESULTS:{...} CONTEXT: ..."}
  let msg = String(r.error || '');
  try { msg = JSON.parse(msg.replace(/^HTTP \d+: /, '')).message; } catch {}
  const m = msg.match(/TEST_RESULTS:(\{.*\})\s*CONTEXT:/s) || msg.match(/TEST_RESULTS:(\{.*\})/s);
  if (!m) { console.log('NO RESULTS', msg.slice(0, 2000)); process.exit(2); }
  const res = JSON.parse(m[1]);
  fs.writeFileSync(path.join(require('os').tmpdir(), `client_activity_tests${mut ? '_' + mut : ''}.json`), JSON.stringify(res, null, 1));   // never in the repo: it carries 112-YA rows
  for (const c of res.cases) console.log(c.ok ? 'PASS' : 'FAIL', c.case);
  console.log(`${res.passed}/${res.total}`, r.ms + 'ms');
  if (mut) {
    const must = MUTATIONS[mut][2];
    const failedAsExpected = must.every((p) => res.cases.some((c) => c.case.startsWith(p) && !c.ok));
    console.log(failedAsExpected ? `CONTROL OK: ${mut} broke ${must}` : `CONTROL FAILED: ${mut} did not break ${must}`);
    process.exit(failedAsExpected ? 0 : 1);
  }
  process.exit(res.passed === res.total ? 0 : 1);
})();
