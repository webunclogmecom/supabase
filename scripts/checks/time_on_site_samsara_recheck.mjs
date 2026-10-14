// time_on_site_samsara_recheck.mjs - runs the REAL supabase/functions/time-on-site-samsara-recheck/index.ts (types
// stripped by Node 22) against stubbed candidates, Samsara trips and saves, and asserts what it saves.
//   node scripts/checks/time_on_site_samsara_recheck.mjs
// Rules under test (2026-10-14_1630): save Samsara's stay (the trip gap that overlaps the completion stop most) when the
// visit is blank or differs by 2 min or more; leave it when it agrees, when no gap covers the stop, when one Samsara
// stay covers two visits' stops, and when a saved time sits on a late-tap stop; a dry run saves nothing and logs nothing.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';
import { stripTypeScriptTypes } from 'node:module';

const src = fs.readFileSync(new URL('../../supabase/functions/time-on-site-samsara-recheck/index.ts', import.meta.url), 'utf8');
const jwt = (role) => 'h.' + Buffer.from(JSON.stringify({ role })).toString('base64') + '.s';
const T = (s) => `2026-10-01T${s}:00Z`, ms = (s) => Date.parse(T(s));
const MOI = '281474998706262';
// Samsara: parked 10:00-10:34, 11:00-11:40, 12:00-12:30 (UTC)
const TRIPS = [[9, 10], [10.57, 11], [11.67, 12], [12.5, 13]].map(([a, b]) => ({ startMs: ms(`${String(Math.floor(a)).padStart(2, '0')}:${String(Math.round((a % 1) * 60)).padStart(2, '0')}`), endMs: ms(`${String(Math.floor(b)).padStart(2, '0')}:00`) }));
TRIPS[0].endMs = ms('10:00'); TRIPS[1] = { startMs: ms('10:34'), endMs: ms('11:00') }; TRIPS[2] = { startMs: ms('11:40'), endMs: ms('12:00') };
TRIPS[3] = { startMs: ms('12:30'), endMs: ms('13:00') };
const cand = (o) => ({ truck_samsara_id: MOI, holds_tap: true, duration_minutes: null, source: null, completed_at: T('10:20'), ...o,
                       ref_arrived: o.ref_arrived ?? o.arrived, ref_departed: o.ref_departed ?? o.departed });
const CANDS = [
  cand({ visit_id: 1, arrived: T('10:02'), departed: T('10:33') }),                                  // blank -> 34
  cand({ visit_id: 2, arrived: T('11:01'), departed: T('11:39'), duration_minutes: 39, source: null }), // agrees (40 vs 39)
  cand({ visit_id: 3, arrived: T('11:01'), departed: T('11:39'), duration_minutes: 28, source: 'stop_at_completion' }), // shares 11:00 stay with 2
  cand({ visit_id: 4, arrived: T('12:01'), departed: T('12:29'), duration_minutes: 50, source: null }), // 50 -> 30
  cand({ visit_id: 5, arrived: T('12:01'), departed: T('12:29'), duration_minutes: 90, source: null, holds_tap: false, truck_samsara_id: 'X' }), // late tap kept
  cand({ visit_id: 6, arrived: T('15:00'), departed: T('15:20'), truck_samsara_id: 'Y' }),            // no gap over the stop
  cand({ visit_id: 7, arrived: T('12:01'), departed: T('12:29'), ref_arrived: T('11:05'), duration_minutes: 80, truck_samsara_id: 'Z' }), // moved during the job
];

// second pass, went once (2026-10-14_1800): 21 blank -> 30 (shares the 12:00 stay with 22: allowed), 22 agrees,
// 23 moved during the job, 1 already changed by the first pass (left to it)
const ONCE = [
  cand({ visit_id: 21, arrived: T('12:01'), departed: T('12:29') }),
  cand({ visit_id: 22, arrived: T('12:01'), departed: T('12:29'), duration_minutes: 30, source: null }),
  cand({ visit_id: 23, arrived: T('11:05'), departed: T('12:29'), duration_minutes: 80 }),
  cand({ visit_id: 1, arrived: T('10:02'), departed: T('10:33') }),
];

async function run({ body = {}, role = 'service_role', code = src } = {}) {
  const saves = [], onceSaves = [], logs = [];
  let handler;
  const ctx = {
    Deno: { env: { get: (k) => ({ SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'svc', SAMSARA_API_TOKEN: 'sam' })[k] },
            serve: (h) => { handler = h; } },
    fetch: async (url, opts = {}) => {
      url = String(url);
      if (url.endsWith('/rpc/fn_time_on_site_samsara_candidates')) return Response.json(CANDS);
      if (url.endsWith('/rpc/fn_time_on_site_went_once')) return Response.json(ONCE);
      if (url.endsWith('/rpc/fn_save_samsara_stay_went_once')) { onceSaves.push(JSON.parse(opts.body)); return Response.json(true); }
      if (url.endsWith('/rpc/fn_save_samsara_stay')) { saves.push(JSON.parse(opts.body)); return Response.json(true); }
      if (url.startsWith('https://api.samsara.com/v1/fleet/trips')) {
        const id = new URL(url).searchParams.get('vehicleId');
        return Response.json({ trips: id === 'Y' ? [] : TRIPS });   // 'Z' gets the same trips: its job spans two stays
      }
      if (url === 'https://x.supabase.co/rest/v1/sync_log') { logs.push(JSON.parse(opts.body)); return new Response(null, { status: 201 }); }
      throw new Error('unexpected fetch ' + url);
    },
    Response, Request, URL, JSON, Math, Date, Number, String, Array, Map, Promise, console, atob, encodeURIComponent,
  };
  vm.runInNewContext(stripTypeScriptTypes(code), ctx);
  const res = await handler(new Request('https://f', { method: 'POST', headers: { authorization: `Bearer ${jwt(role)}` }, body: JSON.stringify(body) }));
  return { status: res.status, body: await res.json(), saves, onceSaves, logs };
}

const r = await run({ body: { from: '2026-10-01', to: '2026-10-02' } });
assert.strictEqual(r.status, 200, JSON.stringify(r.body));
const byId = Object.fromEntries(r.saves.map((s) => [s.p_visit_id, s]));
assert.deepStrictEqual(Object.keys(byId).map(Number).sort(), [1, 4], 'saves exactly the blank and the 20-min-off visit: ' + JSON.stringify(r.body.counts));
assert.strictEqual(byId[1].p_arrival, T('10:00') .replace(':00Z', ':00.000Z'));
assert.strictEqual(byId[1].p_departure, T('10:34').replace(':00Z', ':00.000Z'));
assert.strictEqual(byId[4].p_expected_minutes, 50, 'passes the value it read (no clobber)');
const c = r.body.counts;
assert.deepStrictEqual([c.candidates, c.saved, c.agree, c.shared_stay, c.late_tap_kept, c.no_gap, c.moved_during_job], [7, 2, 0, 2, 1, 1, 1], JSON.stringify(c));
assert.strictEqual(r.logs.length, 1); assert.strictEqual(r.logs[0].sync_source, 'time_on_site_samsara_recheck'); assert.strictEqual(r.logs[0].rows_updated, 3);
const o = c.went_once;
assert.deepStrictEqual([o.candidates, o.saved, o.agree, o.moved_during_job], [4, 1, 1, 1], JSON.stringify(o));
assert.deepStrictEqual(r.onceSaves.map((x) => x.p_visit_id), [21], 'went-once saves only 21');
assert.strictEqual(r.onceSaves[0].p_arrival, T('12:00').replace(':00Z', ':00.000Z'));
assert.strictEqual(r.onceSaves[0].p_departure, T('12:30').replace(':00Z', ':00.000Z'));

const d = await run({ body: { from: '2026-10-01', dry_run: true } });
assert.strictEqual(d.saves.length, 0); assert.strictEqual(d.logs.length, 0); assert.strictEqual(d.body.changes.length, 3); assert.strictEqual(d.onceSaves.length, 0);

assert.strictEqual((await run({ role: 'authenticated' })).status, 403);

// mutation control: ignoring the late-tap rule must be caught
const m = await run({ body: { from: '2026-10-01' }, code: src.replace('!f.c.holds_tap', 'false') });
assert.ok(m.saves.some((s) => s.p_visit_id === 5), 'the mutation should save the late-tap visit');
const m2 = await run({ body: { from: '2026-10-01' }, code: src.replace('if (stays > 1)', 'if (false)') });
assert.ok(m2.saves.some((s) => s.p_visit_id === 7), 'the mutation should save the moved-during-job visit');
const m3 = await run({ body: { from: '2026-10-01' }, code: src.replace('if (done.has(c.visit_id)) continue;', '') });
assert.ok(m3.onceSaves.some((s) => s.p_visit_id === 1), 'the mutation should let the second pass redo a first-pass visit');
console.log('time_on_site_samsara_recheck: all checks passed (three mutations caught)');
