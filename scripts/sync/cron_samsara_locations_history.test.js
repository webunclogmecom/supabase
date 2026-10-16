// cron_samsara_locations_history.test.js: main() of the GPS collector end to end on a stub fetch (no network, no
// DB: every Samsara and PostgREST call is answered by the stub below).
//   node scripts/sync/cron_samsara_locations_history.test.js
const assert = require('assert');
const { chunkWindow, main } = require('./cron_samsara_locations_history.js');

let n = 0;
const ok = (c, m) => { assert.ok(c, m); n++; };
const eq = (a, b, m) => { assert.deepStrictEqual(a, b, m); n++; };
const HOUR = 3600e3, NOW = Date.parse('2026-10-16T12:00:00Z'), iso = ms => new Date(ms).toISOString();

eq([...chunkWindow(0, 30 * HOUR)].map(c => [c.start, c.end]),
   [[iso(0), iso(24 * HOUR)], [iso(24 * HOUR), iso(30 * HOUR)]], 'chunks of 24 h, the last one cut at the end');

// sc: last (newest GPS ms or null), recentDeep, lookupFail, links ([] = none), samsara504Once, samsaraDown,
//     insertFailBatch (1-based), points (per vehicle, per chunk)
function stub(sc = {}) {
  const calls = [];
  const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  let samsaraCalls = 0, batch = 0;
  const f = async (url, o = {}) => {
    const u = new URL(url), method = o.method || 'GET';
    const call = { method, host: u.host, path: u.pathname, search: decodeURIComponent(u.search), body: o.body && JSON.parse(o.body) };
    calls.push(call);
    if (u.host === 'api.samsara.com') {
      samsaraCalls++;
      if (sc.samsaraDown) return json(503, { message: 'down' });
      if (sc.samsara504Once && samsaraCalls === 1) return json(504, { message: 'Gateway Timeout' });
      const s = Date.parse(u.searchParams.get('startTime')), e = Date.parse(u.searchParams.get('endTime'));
      const pts = sc.points ?? 3, data = [];
      for (const id of u.searchParams.get('vehicleIds').split(',')) {
        const locations = [];
        for (let k = 0; k < pts; k++) locations.push({ time: iso(s + ((e - s) * (k + 1)) / (pts + 1) + (id === '222' ? 1000 : 0)),
          latitude: 25.7, longitude: -80.2, speedMilesPerHour: 10, headingDegrees: 90 });
        data.push({ id, locations });
      }
      return json(200, { data, pagination: { hasNextPage: false } });
    }
    const p = u.pathname.replace('/rest/v1', '');
    if (p === '/vehicle_telemetry_readings' && method === 'GET') {
      if (sc.lookupFail) return json(503, { message: 'upstream' });
      return json(200, sc.last ? [{ recorded_at: iso(sc.last) }] : []);
    }
    if (p === '/vehicle_telemetry_readings' && method === 'POST') {
      batch++;
      if (sc.insertFailBatch === batch) return json(500, { message: 'boom' });
      return json(201, call.body.map(r => ({ recorded_at: r.recorded_at })));
    }
    if (p === '/sync_log') return json(200, sc.recentDeep ? [{ id: 1 }] : []);
    if (p === '/entity_source_links') return json(200, sc.links ?? [{ entity_id: 1, source_id: '111' }, { entity_id: 2, source_id: '222' }]);
    return json(599, { message: 'unexpected ' + url });
  };
  return { f, calls };
}
async function run(sc, env = {}) {
  for (const k of ['START_TIME', 'END_TIME', 'AUTO_LOOKBACK_H']) delete process.env[k];
  Object.assign(process.env, { SUPABASE_URL: 'http://stub.local', SUPABASE_SERVICE_ROLE_KEY: 'k', SAMSARA_API_TOKEN: 't' }, env);
  const st = stub(sc), out = [], err = [], sleeps = [];
  let code, thrown = null;
  try { code = await main({ fetch: st.f, sleep: async ms => { sleeps.push(ms); }, now: NOW, log: l => out.push(l), error: l => err.push(l) }); }
  catch (e) { thrown = e; }
  const line = out.find(l => l.startsWith('RUN_SUMMARY '));
  const posts = st.calls.filter(c => c.method === 'POST');
  return { code, thrown, err, sleeps, calls: st.calls, s: line ? JSON.parse(line.slice(12)) : null, posts,
           sam: st.calls.filter(c => c.host === 'api.samsara.com'),
           lookup: st.calls.find(c => c.path === '/rest/v1/vehicle_telemetry_readings' && c.method === 'GET') };
}

(async () => {
  // normal run: 30 min overlap, not deep, a resume point, every row stored
  let r = await run({ last: NOW - 10 * 60e3, recentDeep: true });
  eq([r.code, r.s.window_start, r.s.deep_pass, r.s.resume_point], [0, iso(NOW - 40 * 60e3), false, true], 'normal run: starts 30 min before the newest GPS row');
  ok(r.lookup.search.includes('latitude=not.is.null') && r.lookup.search.includes(`recorded_at=lte.${iso(NOW)}`), 'the cursor needs a position and ignores future rows');
  eq([r.s.points, r.s.rows_inserted, r.s.vehicles], [6, 6, 2], 'rows_inserted counts what the DB took');
  ok(r.posts.every(c => c.search.includes('select=recorded_at')), 'inserts ask for the inserted rows back');

  // retry through the shared client
  r = await run({ last: NOW - 10 * 60e3, recentDeep: true, samsara504Once: true });
  eq([r.code, r.sam.length, r.sleeps], [0, 2, [5000]], 'one Samsara 504 then 200: retried after 5 s, exit 0');
  r = await run({ last: NOW - 10 * 60e3, recentDeep: true, samsaraDown: true });
  ok(r.thrown && /Samsara HTTP 503/.test(r.thrown.message) && r.sam.length === 3 && r.posts.length === 0, 'Samsara down: 3 attempts, then FATAL before any insert');

  // the cursor lookup failing is fatal (it used to fall back to a 90 min window)
  r = await run({ lookupFail: true });
  ok(r.thrown && /PostgREST HTTP 503/.test(r.thrown.message) && r.sam.length === 0, 'cursor lookup failure: FATAL, nothing pulled');

  // deep pass once a day
  r = await run({ last: NOW - 10 * 60e3 });
  eq([r.s.deep_pass, r.s.window_start, r.s.dropped_span, r.code], [true, iso(NOW - 48 * HOUR), null, 0], 'deep pass: 48 h overlap, never counted as dropped');
  eq(r.sam.length, 2, 'a 48 h window is two 24 h chunks');

  // a long outage: 7 days kept, the rest reported and exit 1
  r = await run({ last: NOW - 200 * HOUR, recentDeep: true });
  eq([r.s.window_start, r.s.dropped_span, r.s.resume_point, r.code], [iso(NOW - 168 * HOUR),
     { from: iso(NOW - 200 * HOUR - 30 * 60e3), to: iso(NOW - 168 * HOUR) }, false, 1], 'outage over 7 days: last 7 days pulled, the rest reported, exit 1');
  ok(r.posts.length > 0 && r.err.some(l => /re-pull with START_TIME/.test(l)), 'the kept window is still stored, and the loss is logged');
  r = await run({ last: NOW - 100 * HOUR, recentDeep: true }, { AUTO_LOOKBACK_H: '168' });
  eq([r.s.window_start, r.s.dropped_span, r.code], [iso(NOW - 100 * HOUR - 30 * 60e3), null, 0], 'a 100 h outage heals in one run');

  // a failed batch stops the insert (rows are time ordered, so the cursor cannot pass them)
  r = await run({ last: NOW - 10 * 60e3, recentDeep: true, points: 400, insertFailBatch: 1 });
  eq([r.code, r.s.failed_batches, r.posts.length, r.s.rows_inserted, r.s.resume_point], [1, 1, 1, 0, false], 'first batch fails: stop, exit 1, not a resume point');
  r = await run({ last: NOW - 10 * 60e3, recentDeep: true, points: 400, insertFailBatch: 2 });
  eq([r.code, r.posts.length, r.s.rows_inserted], [1, 2, 500], 'second batch fails: the first stays, nothing after it is sent');
  const firstBatch = r.posts[0].body.map(x => Date.parse(x.recorded_at)), secondBatch = r.posts[1].body.map(x => Date.parse(x.recorded_at));
  ok(firstBatch.every((t, i) => i === 0 || t >= firstBatch[i - 1]) && Math.max(...firstBatch) <= Math.min(...secondBatch), 'batches are in time order');

  // nothing mapped: refuse (a green run that stores nothing)
  r = await run({ last: NOW - 10 * 60e3, recentDeep: true, links: [] });
  ok(r.thrown && /refusing to run/.test(r.thrown.message) && r.sam.length === 0, 'no samsara vehicle link: FATAL');

  // manual backfill: exact window, never a resume point, no cursor lookup
  r = await run({ last: NOW - 10 * 60e3 }, { START_TIME: iso(NOW - 30 * HOUR), END_TIME: iso(NOW - 2 * HOUR) });
  eq([r.code, r.s.manual, r.s.window_start, r.s.window_end, r.s.resume_point, !!r.lookup], [0, true, iso(NOW - 30 * HOUR), iso(NOW - 2 * HOUR), false, false], 'manual backfill window');

  // END_TIME alone would be an automatic run that stops early and still counts as complete: refused
  r = await run({ last: NOW - 10 * 60e3, recentDeep: true }, { END_TIME: iso(NOW - 2 * HOUR) });
  ok(r.thrown && /END_TIME needs START_TIME/.test(r.thrown.message) && r.sam.length === 0, 'END_TIME without START_TIME: FATAL');

  // empty table (no GPS row ever)
  r = await run({ last: null, recentDeep: true });
  eq([r.code, r.s.window_start], [0, iso(NOW - 90 * 60e3)], 'no GPS row at all: last 90 min');

  console.log(`cron_samsara_locations_history: ${n} checks passed`);
})().catch(e => { console.error(e); process.exit(1); });
