// cron_samsara_tank_readings.test.js: self-check of the collector: the pure parts, then main() end to end on a stub
// fetch (no network, no DB: every Samsara and PostgREST call is answered by the stub below).
//   node scripts/sync/cron_samsara_tank_readings.test.js
const assert = require('assert');
const { STREAMS, normalizeDefinition, unitsGuard, transform, rowKey, chunks, parseArgs, main } = require('./cron_samsara_tank_readings.js');

const S = Object.fromEntries(STREAMS.map(s => [s.key, s]));
const now = Date.parse('2026-10-12T19:00:00Z');
const siteMap = new Map([['322485232', 98]]);
const ctx = { now, siteMap };
const at = m => new Date(now - m * 60e3).toISOString();
let n = 0; const ok = (c, m) => { assert.ok(c, m); n++; }; const eq = (a, b, m) => { assert.deepStrictEqual(a, b, m); n++; };

// 1. address events: the payload carries addressEntries[]; a payload shaped like the definition (addressIds) is skipped
let t = transform(S.address_entry, [
  { happenedAtTime: at(10), value: { addressEntries: [{ id: 322485232, name: 'a geofence' }, { id: 4000000737885 }] } },
  { happenedAtTime: at(9), value: { addressIds: ['322485232'] } },
], 1, ctx);
eq(t.rows, [{ vehicle_id: 1, property_id: 98, recorded_at: at(10), event_kind: 'entry' }], 'one row per resolved addressEntries element');
eq([t.unresolved, t.skipped], [1, 1], 'the yard is unresolved; the addressIds-shaped payload is skipped');
ok(!JSON.stringify(t.rows).includes('geofence'), 'no geofence name reaches a row');

// 2. addr_ prefix stripped (string or number id), exit maps to event_kind exit
t = transform(S.address_exit, [{ happenedAtTime: at(5), value: { addressEntries: [{ id: 'addr_322485232' }] } }], 3, ctx);
eq(t.rows, [{ vehicle_id: 3, property_id: 98, recorded_at: at(5), event_kind: 'exit' }], 'addr_ stripped');

// 3. PTO map: on -> true, off -> false, anything else skipped (incl. a prototype key and the enum number)
t = transform(S.pto, ['on', 'off', 'unknown', 'toString', 1, null].map((value, i) => ({ happenedAtTime: at(30 - i), value })), 3, ctx);
eq(t.rows.map(r => r.pto_engaged), [true, false], 'PTO map');
eq(t.skipped, 4, 'non-symbol PTO values skipped');

// 4. poison values and future stamps skipped and counted; rounding
t = transform(S.distance, [
  { happenedAtTime: at(1), value: 2.12345 }, { happenedAtTime: at(2), value: 0 }, { happenedAtTime: at(3), value: -0.1 },
  { happenedAtTime: at(4), value: 10 }, { happenedAtTime: at(5), value: 'x' }, { happenedAtTime: 'nope', value: 1 },
  { happenedAtTime: at(-6), value: 1 }, { happenedAtTime: at(-4), value: 1 },
], 2, ctx);
eq(t.rows.map(r => r.distance_meters), [2.123, 0, 1], 'distance rounded to 3 places; 0 m kept (dropped later, in derivation); 4 min ahead kept');
eq(t.skipped, 5, 'negative, >= 10 m, non-number, bad stamp, more than 5 min ahead');
t = transform(S.percent, [{ happenedAtTime: at(1), value: 99.3954 }, { happenedAtTime: at(2), value: 100.01 }, { happenedAtTime: at(3), value: -1 }], 2, ctx);
eq([t.rows.map(r => r.fill_percent), t.skipped], [[99.395], 2], 'percent 0..100, 3 places');
t = transform(S.rpm, [{ happenedAtTime: at(1), value: 1496.6 }, { happenedAtTime: at(2), value: 6001 }, { happenedAtTime: at(3), value: -5 }], 1, ctx);
eq([t.rows.map(r => r.engine_rpm), t.skipped], [[1497], 2], 'rpm integer 0..6000');

// 5. units normalisation against the definitions as Samsara returned them on 2026-10-12
const defs = [
  { readingId: 'remoteSensingDistance', entityType: 'asset', type: { dataType: 'Float', unit: { baseUnit: 'Meter', measurementType: 'distance' } } },
  { readingId: 'fillPercent', entityType: 'asset', type: { dataType: 'Float', unit: { baseUnit: 'percent', measurementType: 'ratio' } } },
  { readingId: 'engineRpm', entityType: 'asset', type: { dataType: 'Integer', unit: { baseUnit: 'rpm' } } },
  { readingId: 'ecuPowerTakeoff', entityType: 'asset', type: { dataType: 'Integer', enumValues: [{ symbol: 'on', number: 1 }, { symbol: 'off', number: 0 }] }, enumValues: [{ symbol: 'off' }, { symbol: 'on' }] },
  { readingId: 'addressEntry', entityType: 'asset', type: { dataType: 'Object', fields: [{ name: 'addressIds', type: { dataType: 'Array' } }] } },
  { readingId: 'addressExit', entityType: 'asset', type: { dataType: 'Object', fields: [{ name: 'addressIds', type: { dataType: 'Array' } }] } },
];
eq(normalizeDefinition(defs[3]), 'enum:off=0,on=1', 'enum normalised from type.enumValues, order-free');
eq(unitsGuard(defs), [], 'the 2026-10-12 definitions pass (baseUnit case ignored)');
const changed = defs.map(d => d.readingId === 'remoteSensingDistance' ? { ...d, type: { dataType: 'Float', unit: { baseUnit: 'centimeter' } } } : d)
  .filter(d => d.readingId !== 'addressExit');
eq(unitsGuard(changed).map(s => [s.stream, s.got]), [['distance', 'unit:centimeter'], ['address_exit', 'missing']], 'a changed or missing definition skips only its stream');

// 6. chunks of 1,000 with identical key sets per table
for (const s of STREAMS) {
  const value = { distance: 1, percent: 50, rpm: 800, pto: 'on', address_entry: { addressEntries: [{ id: 322485232 }] }, address_exit: { addressEntries: [{ id: 322485232 }] } }[s.key];
  const rows = transform(s, Array.from({ length: 2345 }, (_, i) => ({ happenedAtTime: new Date(now - i * 1000).toISOString(), value })), 1, ctx).rows;
  const parts = chunks(rows, 1000);
  eq(parts.map(p => p.length), [1000, 1000, 345], `${s.key}: chunk sizes`);
  const keys = new Set(rows.map(r => Object.keys(r).sort().join(',')));
  eq(keys.size, 1, `${s.key}: identical key set in every element`);
  ok(s.conflict.split(',').every(c => [...keys][0].split(',').includes(c)), `${s.key}: on_conflict columns present`);
  eq(new Set(rows.map(r => rowKey(s, r))).size, rows.length, `${s.key}: natural keys distinct`);
}

// 7. arguments: --assets is dry-run only
eq(parseArgs(['--dry-run', '--assets=sensor:281475005688801=1,truck:281474998706262=1']).assets.sensor.get('281475005688801'), 1, '--assets parsed');
assert.throws(() => parseArgs(['--assets=sensor:1=1']), /dry-run only/); n++;
assert.throws(() => parseArgs(['--from=yesterday']), /not a date/); n++;
assert.throws(() => parseArgs(['--fro=2026-01-01']), /unknown option/); n++;
eq(parseArgs(['--from=2026-08-20T14:00:00Z', '--window-hours=24']).windowHours, 24, '--window-hours');
assert.throws(() => parseArgs(['-dry-run']), /unknown argument/); n++;   // would otherwise be a REAL write run
assert.throws(() => parseArgs(['dry-run']), /unknown argument/); n++;

// 8. main() end to end on a stub fetch
const HOUR = 3600e3, NOW = Date.parse('2026-10-12T19:00:00Z');
function stub(sc = {}) {
  const calls = [];
  const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  const defsOf = () => [
    { readingId: 'remoteSensingDistance', entityType: 'asset', type: { dataType: 'Float', unit: { baseUnit: sc.distUnit || 'Meter' } } },
    { readingId: 'fillPercent', entityType: 'asset', type: { dataType: 'Float', unit: { baseUnit: 'percent' } } },
    { readingId: 'engineRpm', entityType: 'asset', type: { dataType: 'Integer', unit: { baseUnit: 'rpm' } } },
    { readingId: 'ecuPowerTakeoff', entityType: 'asset', type: { dataType: 'Integer', enumValues: [{ symbol: 'on', number: 1 }, { symbol: 'off', number: 0 }] } },
    { readingId: 'addressEntry', entityType: 'asset', type: { dataType: 'Object', fields: [{ name: 'addressIds' }] } },
    { readingId: 'addressExit', entityType: 'asset', type: { dataType: 'Object', fields: [{ name: 'addressIds' }] } }];
  const f = async (url, o = {}) => {
    const u = new URL(url), method = o.method || 'GET';
    calls.push({ method, host: u.host, path: u.pathname, search: decodeURIComponent(u.search), rid: u.searchParams.get('readingId'),
                 startTime: u.searchParams.get('startTime') });
    if (u.host === 'api.samsara.com') {
      if (u.pathname === '/readings/definitions') return json(200, { data: defsOf(), pagination: { hasNextPage: false } });
      if (u.pathname === '/readings/latest') return sc.latestFail ? json(500, { message: 'boom' })
        : json(200, { data: [{ entityId: 'S1' }, { entityId: 'S9' }], pagination: { hasNextPage: false } });
      if (u.pathname === '/readings/history') {
        const rid = u.searchParams.get('readingId');
        if (sc.histFail === rid) return json(500, { message: 'x' });
        const seen = calls.filter(c => c.rid === rid).length;   // this call included
        if (sc.hist504Once === rid && seen === 1) return json(504, { message: 'Gateway Timeout' });
        if (sc.netFailOnce === rid && seen === 1) throw new TypeError('fetch failed');
        const t = new Date(Date.parse(u.searchParams.get('endTime')) - 60e3).toISOString();
        const v = { remoteSensingDistance: 1.5, fillPercent: 40, engineRpm: 800, ecuPowerTakeoff: 'on',
          addressEntry: { addressEntries: [{ id: 322485232 }] }, addressExit: { addressEntries: [{ id: 4000000737885 }] } }[rid];
        return json(200, { data: [{ happenedAtTime: t, value: v }], pagination: { hasNextPage: false } });
      }
    } else if (u.host === 'stub.local') {
      const p = u.pathname.replace('/rest/v1', '');
      if (method === 'POST') { const b = JSON.parse(o.body); return sc.insertFail ? json(409, { message: 'fk' }) : json(201, b.map(r => ({ recorded_at: r.recorded_at }))); }
      if (p === '/entity_source_links') {
        const et = u.searchParams.get('entity_type');
        if (et === 'eq.tank_sensor') return json(200, sc.noSensors ? [] : [{ entity_id: 1, source_id: 'S1' }]);
        if (et === 'eq.vehicle') return json(200, [{ entity_id: 1, source_id: 'T1' }]);
        if (et === 'eq.property') return json(200, [{ entity_id: 98, source_id: '322485232' }]);
      }
      if (p === '/v_vehicle_site_addresses') return json(404, { code: 'PGRST205' });
      if (p === '/v_dump_sites') return json(200, [{ property_id: 98 }]);
      if (p === '/sync_log') {
        if (u.search.includes('deep_pass')) return json(200, sc.recentDeep ? [{ id: 1 }] : []);
        return json(200, sc.last ? [{ started_at: sc.last }] : []);
      }
    }
    return json(599, { message: 'unexpected ' + url });
  };
  return { f, calls };
}
async function run(args, sc) {
  Object.assign(process.env, { SUPABASE_URL: 'http://stub.local', SUPABASE_SERVICE_ROLE_KEY: 'k', SAMSARA_API_TOKEN: 't' });
  const st = stub(sc), out = [], err = [], sleeps = [];
  let code, thrown = null;
  try { code = await main(args, { fetch: st.f, sleep: async ms => { sleeps.push(ms); }, now: NOW, log: l => out.push(l), error: l => err.push(l) }); } catch (e) { thrown = e; }
  const line = pre => out.find(l => l.startsWith(pre + ' '));
  const summary = (line('RUN_SUMMARY') || line('DRY_RUN_SUMMARY') || '').replace(/^\w+ /, '');
  return { code, thrown, out, err, sleeps, calls: st.calls, s: summary ? JSON.parse(summary) : null,
           posts: st.calls.filter(c => c.method === 'POST').length,
           hist: st.calls.filter(c => c.path === '/readings/history'), has: pre => !!line(pre) };
}
(async () => {
  const last = new Date(NOW - HOUR).toISOString();
  let r = await run([], { last, recentDeep: true });
  eq([r.code, r.has('RUN_SUMMARY'), r.s.deep_pass, r.s.resume_point], [0, true, false, true], 'normal run: exit 0, summary, not deep, a resume point');
  eq(r.s.window_start, new Date(NOW - HOUR - 30 * 60e3).toISOString(), 'normal window starts at last run - 30 min');
  eq(r.s.unlinked_level_assets, null, 'a run that did not check for unlinked sensors says null, never []');
  ok(r.posts > 0 && r.s.rows_inserted > 0, 'a normal run writes');
  ok(r.calls.some(c => c.path === '/rest/v1/sync_log' && c.search.includes('details->summary->>resume_point=eq.true')), 'the cursor reads only resume points');
  ok(r.hist.length === 6 && r.hist.every(c => c.startTime === r.s.window_start), 'every stream is pulled from the window start');

  r = await run(['--dry-run'], { last, recentDeep: true });
  eq([r.code, r.posts, r.has('RUN_SUMMARY'), r.has('DRY_RUN_SUMMARY'), r.s.resume_point], [0, 0, false, true, false], 'dry run: 0 POSTs, DRY_RUN_SUMMARY only, never a resume point');

  r = await run([], { last });
  eq([r.s.deep_pass, r.s.window_start, r.s.unlinked_level_assets], [true, new Date(NOW - HOUR - 48 * HOUR).toISOString(), ['S9']], 'deep pass: 48 h overlap, unlinked sensors listed');

  r = await run([], { last, latestFail: true });
  eq([r.code, r.s.unlinked_level_assets, r.s.errors], [1, null, 1], 'failed discovery: exit 1, unlinked null, one error');
  ok(r.hist.length === 6 && r.posts > 0, 'failed discovery does not stop ingestion');

  r = await run([], { last, recentDeep: true, distUnit: 'centimeter' });
  eq([r.code, r.s.skipped_streams.map(x => x.stream), r.s.resume_point], [0, ['distance'], false], 'units mismatch: exit 0, stream skipped, NOT a resume point');
  ok(!r.hist.some(c => c.rid === 'remoteSensingDistance'), 'a skipped stream is not pulled');

  r = await run([], { last, recentDeep: true, histFail: 'engineRpm' });
  eq([r.code, r.hist.filter(c => c.rid === 'engineRpm').length], [1, 3], 'a 5xx on every attempt: 3 attempts, then exit 1');
  r = await run([], { last, recentDeep: true, hist504Once: 'remoteSensingDistance' });
  eq([r.code, r.s.errors, r.hist.length, r.sleeps.includes(5000)], [0, 0, 7, true], 'one 504 then 200: retried after 5 s, exit 0, no error');
  r = await run([], { last, recentDeep: true, netFailOnce: 'fillPercent' });
  eq([r.code, r.s.errors, r.hist.length], [0, 0, 7], 'one network error then 200: retried, exit 0');
  r = await run([], { last, recentDeep: true, insertFail: true });
  eq(r.code, 1, 'failed insert: exit 1');

  r = await run([], { last, recentDeep: true, noSensors: true });
  ok(r.thrown && /refusing to run/.test(r.thrown.message) && r.hist.length === 0, 'no tank_sensor links: a real run refuses before pulling');
  r = await run(['--dry-run'], { last, recentDeep: true, noSensors: true });
  eq(r.code, 0, 'no tank_sensor links: a dry run still works');

  r = await run(['--from=' + new Date(NOW - HOUR / 4).toISOString()], { last, recentDeep: true });
  eq([r.code, r.s.resume_point], [0, false], '--from after the cursor: not a resume point (would hide the gap before it)');
  r = await run(['--from=' + new Date(NOW - 2 * HOUR).toISOString()], { last, recentDeep: true });
  eq(r.s.resume_point, true, '--from at or before the cursor: a resume point');

  r = await run([], { recentDeep: false });
  eq(r.s.window_start, '2026-08-20T14:00:00.000Z', 'no resume point yet: start at the backfill start');

  console.log(`cron_samsara_tank_readings: ${n} checks passed`);
})().catch(e => { console.error(e); process.exit(1); });
