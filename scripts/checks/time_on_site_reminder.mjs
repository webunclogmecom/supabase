// time_on_site_reminder.mjs - runs the REAL supabase/functions/time-on-site-reminder/index.ts (types stripped by
// Node 22) against a stubbed database, Samsara and Slack, and asserts what is posted.
//   node scripts/checks/time_on_site_reminder.mjs [path/to/index.ts]   (default: the repo's function; add --mutate to
//   prove the checks can fail)
// Rules under test (Fred, 2026-10-12, Option A, "tag Diego"): one line per visit with its reason; the client name
// opens its Samsara Place (WITH the duration/end_ms params); Diego tagged on the first line, never on a [TEST], never
// in `text`; nothing posted when the list is empty; a dry run never posts or logs; every other run writes ONE
// public.sync_log row; a failed Samsara read leaves the place reasons out instead of guessing. What the database
// lists (which visits) is tested by the migration's VERIFY, not here: a stub cannot see a wrong query.
// S8 (2026-11-11, case 10): the last real nightly run (rules 2, under 20 hours old) gives a "still there" reason and a
// "Which truck went?" block, which posts even on a day with nothing else to list; a failed read leaves both out.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';
import { edgeVmSource } from './edge_vm_source.mjs';

// the source under test: an optional path (a draft outside the repo), default the repo file
const src = fs.readFileSync(process.argv.slice(2).find((a) => !a.startsWith('--')) ?? new URL('../../supabase/functions/time-on-site-reminder/index.ts', import.meta.url), 'utf8');
const IMPORT = 'import { slackHeader, slackIdentity, slackScopes, slackSections } from "../_shared/slack-notify.ts";';
assert.ok(src.includes(IMPORT), 'the function imports the shared Slack helpers');
const MUTATE = process.argv.includes('--mutate');
const jwt = (role) => 'h.' + Buffer.from(JSON.stringify({ role })).toString('base64') + '.s';

// real data, 2026-10-09 (fn_time_on_site_gaps output, trimmed)
const casaNeos = { visit_id: 8765, visit_date: '2026-10-09', client_code: '009-CN', client_name: 'Casa Neos', service: 'Unclogging',
  completed_at: '2026-10-09T15:25:26+00:00', lat: 25.773616, lng: -80.2005081, truck: null, truck_samsara_id: null,
  property_place_id: '322485280', client_place_ids: ['322485280'],
  closest: { truck: 'David', truck_samsara_id: '281474998706264', meters: 16, at: '2026-10-09T18:38:23+00:00' },
  stays: [{ truck: 'David', truck_samsara_id: '281474998706264', first: '2026-10-09T18:38:13+00:00', last: '2026-10-09T18:38:34+00:00', minutes: 0 },
          { truck: 'David', truck_samsara_id: '281474998706264', first: '2026-10-09T17:53:22+00:00', last: '2026-10-09T17:53:43+00:00', minutes: 0 }] };
const granada = { visit_id: 8752, visit_date: '2026-10-09', client_code: '021-GRA', client_name: 'Granada Condo', service: 'Labor BUS',
  completed_at: '2026-10-09T19:43:22+00:00', lat: 25.8842689, lng: -80.1285415, truck: 'David', truck_samsara_id: '281474998706264',
  property_place_id: null, client_place_ids: ['322485277'],
  closest: { truck: 'David', truck_samsara_id: '281474998706264', meters: 291, at: '2026-10-09T16:37:26+00:00' }, stays: [] };
const PLACES = [
  { id: '322485280', name: '009-CN Casa Neos', latitude: 25.7737, longitude: -80.2006 },
  { id: '322485277', name: '021-GRA Granada Condo', latitude: 25.8842, longitude: -80.1285 },
  { id: '4000001014044', name: '119-ME Mosche Elghrissi', latitude: 25.84, longitude: -80.12 },
];

// S8: the last nightly run's sync_log row (rules 2) and the visits it held for a truck question. Invented visits on the
// test client 112-YA; the candidate shapes are the real ones (sync_log 139308, 2026-11-11).
const nightRun = (cands, hoursAgo = 8) => ({
  runs: [{ id: 139308, started_at: new Date(Date.now() - hoursAgo * 3600e3).toISOString(), candidates: cands }],
  visits: [{ id: 9901, visit_date: '2026-11-03', client: { client_code: '112-YA', name: 'Test Client A' }, truck: { name: 'Moises' } },
           { id: 9902, visit_date: '2026-11-04', client: { client_code: '112-YA', name: 'Test Client B' }, truck: null }] });
const CANDS = [{ visit_id: 9902, decision: 'hold', hold_reason: 'no_truck', rule: { status: 'no_truck' } },
               { visit_id: 9901, decision: 'hold', hold_reason: 'another_truck', rule: { status: 'stay' } },
               { visit_id: 9903, decision: 'hold', hold_reason: 'another_truck', rule: { status: 'stay' } },   // deleted since: no row
               { visit_id: 9046, decision: 'hold', hold_reason: 'other_day', rule: { status: 'no_stay' } },
               { visit_id: 8752, decision: 'pending', hold_reason: null, rule: { status: 'open' } },
               { visit_id: 5926, decision: 'keep', hold_reason: null, keep_reason: 'within_2', rule: {} }];

async function run(list, { body = {}, role = 'service_role', samsara = PLACES, trips = null, slack = { ok: true, ts: '1.2' }, code = src, env = {},
                           nightly = { runs: [] } } = {}) {
  const posts = [], logs = [], gets = [];
  let handler;
  const ctx = {
    Deno: { env: { get: (k) => ({ SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'svc', SLACK_BOT_TOKEN: 'xoxb', SAMSARA_API_TOKEN: 'sam', ...env })[k] },
            serve: (h) => { handler = h; } },
    fetch: async (url, opts = {}) => {
      url = String(url);
      if (url.endsWith('/rest/v1/rpc/fn_time_on_site_gaps')) return Response.json(list);
      if (url.startsWith('https://api.samsara.com/addresses')) {
        if (samsara === 'FAIL') return new Response('nope', { status: 500 });
        return Response.json({ data: samsara, pagination: { hasNextPage: false } });
      }
      if (url.startsWith('https://api.samsara.com/v1/fleet/trips') && trips) {
        if (trips === 'FAIL') return new Response('nope', { status: 500 });
        return Response.json({ trips });
      }
      if (url === 'https://x.supabase.co/rest/v1/sync_log') { logs.push(JSON.parse(opts.body)); return new Response(null, { status: 201 }); }
      if (url.startsWith('https://x.supabase.co/rest/v1/sync_log?')) {
        gets.push(url);
        return nightly === 'FAIL' ? new Response('nope', { status: 500 }) : Response.json(nightly.runs);
      }
      if (url.startsWith('https://x.supabase.co/rest/v1/visits?')) { gets.push(url); return Response.json(nightly.visits ?? []); }
      if (url === 'https://slack.com/api/chat.postMessage') { posts.push(JSON.parse(opts.body)); return Response.json(slack); }
      if (url === 'https://slack.com/api/auth.test') return Response.json({ ok: true }, { headers: { 'x-oauth-scopes': 'chat:write,chat:write.customize' } });
      throw new Error('unexpected fetch ' + url);
    },
    Response, JSON, String, Number, Math, Date, Array, Map, Error, atob, console, encodeURIComponent,
  };
  vm.runInNewContext(edgeVmSource(code), ctx);
  const res = await handler(new Request('https://fn', { method: 'POST', headers: { authorization: 'Bearer ' + jwt(role) }, body: JSON.stringify(body) }));
  return { status: res.status, body: await res.json(), posts, logs, gets };
}
const bodyText = (p) => p.blocks.slice(1).map((b) => b.text.text).join('\n');
const day = (visits, older = 7) => ({ date: '2026-10-09', older_count: older, visits });

async function checks(code) {
  // 1. nothing to list: no post, one success row
  const none = await run(day([]), { code });
  assert.strictEqual(none.posts.length, 0, 'an empty list must post nothing');
  assert.strictEqual(none.logs.length, 1, 'an empty day still writes its run record');
  assert.strictEqual(none.logs[0].status, 'success');
  assert.strictEqual(none.logs[0].sync_source, 'time_on_site_reminder');

  // 2. the real Oct 9 day
  const r = await run(day([casaNeos, granada]), { code });
  assert.strictEqual(r.posts.length, 1);
  const p = r.posts[0], b = bodyText(p);
  assert.strictEqual(p.channel, 'C0BJYHQKZM1', '#apps-notifications');
  assert.strictEqual(p.blocks[0].type, 'header', 'the header comes first');
  assert.strictEqual(p.blocks[0].text.text, '⏱️ Visits with no time on site');
  assert.strictEqual(p.username, 'Visit Calendar', 'posts as Visit Calendar when the bot may');
  assert.ok(b.startsWith(':stopwatch: <@U0AL9JZ4V7C> *2 visits on Fri, Oct 9 have no time on site*'), 'first line tags Diego: ' + b.split('\n')[0]);
  assert.ok(!p.text.includes('<@'), 'the phone line never tags');
  assert.strictEqual(p.text.split('\n')[0], ':stopwatch: 2 visits on Fri, Oct 9 have no time on site', 'the phone line is the summary');
  assert.ok(p.text.includes('\n• visit 8765 · 009-CN Casa Neos · no truck assigned: David only drove past (under 3 min, 2 times)'), 'Viktor reads the visit numbers in text: ' + p.text);
  assert.ok(!/<https?:/.test(p.text), 'no Slack link markup in text');
  const lines = b.split('\n');
  const cn = lines.find((l) => l.includes('009-CN'));
  assert.ok(cn.includes('<https://cloud.samsara.com/o/6009037/fleet/places/322485280?duration=2678399.999&end_ms='), 'the name opens the Samsara Place WITH its params');
  assert.ok(cn.includes('· no truck assigned: <https://cloud.samsara.com/o/6009037/devices/281474998706264/vehicle?end_ms='), 'no truck assigned, David linked');
  assert.ok(cn.endsWith('|David> only drove past (under 3 min, 2 times)'), 'two drive-bys are two passes, never one stay: ' + cn);
  const gr = lines.find((l) => l.includes('021-GRA'));
  assert.ok(/· <https:\/\/cloud\.samsara\.com\/o\/6009037\/devices\/281474998706264\/vehicle\?end_ms=\d+&duration=21600\|David>: no truck came within 150 m \(closest 291 m\)$/.test(gr), gr);
  assert.ok(gr.includes('fleet/places/322485277'), 'falls back to the client-level place');
  assert.ok(b.endsWith(':card_index_dividers: *7* older visits from the last 30 days still have no time on site.'));
  assert.ok(!b.includes('—'), 'no em dash');
  assert.strictEqual(r.logs.length, 1);
  assert.strictEqual(r.logs[0].details.posted, true);
  assert.deepStrictEqual(r.logs[0].details.visits, [8765, 8752]);

  // 3. a [TEST] run: marked, never tags, logs apart
  const t = await run(day([granada]), { body: { test: true }, code });
  assert.ok(bodyText(t.posts[0]).startsWith(':stopwatch: [TEST] *1 visit on Fri, Oct 9 has no time on site*'), bodyText(t.posts[0]).split('\n')[0]);
  assert.ok(!JSON.stringify(t.posts[0]).includes('<@'), 'a test never tags anyone');
  assert.strictEqual(t.posts[0].text.split('\n')[0], ':stopwatch: [TEST] 1 visit on Fri, Oct 9 has no time on site');
  assert.strictEqual(t.logs[0].sync_source, 'time_on_site_reminder_test');

  // 4. place reasons: no place, far place
  const nop = await run(day([{ ...granada, client_code: '322-IRO', client_name: 'Ironside Pizzeria', client_place_ids: [] }]), { code });
  assert.ok(bodyText(nop.posts[0]).includes('• 322-IRO Ironside Pizzeria · '), 'no place: the name is not a link');
  assert.ok(bodyText(nop.posts[0]).includes(': this client has no Samsara place'));
  const far = await run(day([{ ...granada, client_code: '119-ME', client_name: 'Mosche Elghrissi', client_place_ids: [] , lat: 25.77, lng: -80.15 }]), { code });
  assert.ok(/: the Samsara place is \d+\.\d km from our address$/.test(bodyText(far.posts[0]).split('\n')[1]), bodyText(far.posts[0]));

  // 5. Samsara unreadable: never claim "no Samsara place", fall back to the GPS reason
  const down = await run(day([{ ...granada, client_place_ids: [] }]), { samsara: 'FAIL', code });
  const dl = bodyText(down.posts[0]).split('\n')[1];
  assert.ok(!dl.includes('Samsara place') && dl.endsWith('no truck came within 150 m (closest 291 m)'), dl);
  assert.strictEqual(down.body.places_read, false);

  // 6. a real stay that does not hold the completion time; an unreadable older count is left out
  const stay = { ...granada, stays: [{ truck: 'Cloggy', truck_samsara_id: '281474998706263', first: '2026-10-09T12:20:33+00:00', last: '2026-10-09T13:08:26+00:00', minutes: 48 }] };
  const s = await run(day([stay], null), { code });
  const sl = bodyText(s.posts[0]).split('\n');
  assert.ok(sl[1].endsWith('|Cloggy> was there 8:20 AM to 9:08 AM, but it was marked complete at 3:43 PM'), sl[1]);
  assert.strictEqual(sl.length, 2, 'an unreadable older count prints no line, never 0');
  // a stay the next morning says its date
  const next = { ...granada, stays: [{ truck: 'Moises', truck_samsara_id: '281474998706262', first: '2026-10-10T08:01:00+00:00', last: '2026-10-10T09:26:00+00:00', minutes: 85 }] };
  const nx = bodyText((await run(day([next]), { code })).posts[0]).split('\n')[1];
  assert.ok(nx.includes('|Moises> was there on Oct 10, 4:01 AM to 5:26 AM, but'), nx);

  // 6b. a truck parked near our map point when the job was marked complete (visit 6509, real data 2026-09-25):
  // never "only drove past" (Fred, 2026-10-13). The Place is the real 214-MYK circle (100 m, 95 m from our point).
  const myka = { visit_id: 6509, visit_date: '2026-09-25', client_code: '214-MYK', client_name: 'Myka Greek Frozen Yogurt (Food Truck Brickell)',
    service: 'Pumping', completed_at: '2026-09-25T14:54:13+00:00', lat: 25.7662211, lng: -80.1889717, truck: 'David', truck_samsara_id: '281474998706264',
    property_place_id: '4000001823124', client_place_ids: ['4000001823124'],
    closest: { truck: 'David', truck_samsara_id: '281474998706264', meters: 47, at: '2026-09-25T14:29:28+00:00' },
    stays: [{ truck: 'David', truck_samsara_id: '281474998706264', first: '2026-09-25T14:29:17+00:00', last: '2026-09-25T14:30:10+00:00', minutes: 1 }],
    stop_at_completion: { truck: 'David', truck_samsara_id: '281474998706264', assigned: true, arrived: '2026-09-25T14:29:11+00:00',
      departed: '2026-09-25T15:02:59+00:00', minutes: 34, meters: 164, lat: 25.766279, lng: -80.190609 } };
  const MYK = { id: '4000001823124', name: '214-MYK MYKA Brickell', latitude: 25.7664344, longitude: -80.1898861,
    geofence: { circle: { latitude: 25.7664344, longitude: -80.1898861, radiusMeters: 100 } } };
  const myDay = (v) => ({ date: '2026-09-25', older_count: 0, visits: [v] });
  const mk = await run(myDay(myka), { samsara: [MYK], code });
  const ml = bodyText(mk.posts[0]).split('\n')[1];
  assert.ok(ml.endsWith('|David> was parked 164 m from our map point, 10:29 AM to 11:02 AM (34 min), when it was marked complete: it was inside its Samsara place, so our map point is probably off'), ml);
  assert.ok(!ml.includes('drove past'), 'a 34-minute stop is never a drive-by: ' + ml);
  assert.ok(mk.posts[0].text.includes('\n• visit 6509 · 214-MYK Myka Greek Frozen Yogurt (Food Truck Brickell) · David: David was parked 164 m'), 'Viktor still reads the visit line: ' + mk.posts[0].text);
  // the same stop outside a Place drawn elsewhere (a square 1 km east): both are probably off
  const east = { ...MYK, geofence: { polygon: { vertices: [{ latitude: 25.765, longitude: -80.180 }, { latitude: 25.765, longitude: -80.170 },
    { latitude: 25.775, longitude: -80.170 }, { latitude: 25.775, longitude: -80.180 }] } } };
  const out = bodyText((await run(myDay(myka), { samsara: [east], code })).posts[0]).split('\n')[1];
  assert.ok(out.endsWith('when it was marked complete: it was outside its Samsara place too, so both are probably off'), out);
  // inside a polygon that does hold the stop
  const lot = { ...MYK, geofence: { polygon: { vertices: [{ latitude: 25.7655, longitude: -80.1915 }, { latitude: 25.7655, longitude: -80.1895 },
    { latitude: 25.7670, longitude: -80.1895 }, { latitude: 25.7670, longitude: -80.1915 }] } } };
  assert.ok(bodyText((await run(myDay(myka), { samsara: [lot], code })).posts[0]).includes('it was inside its Samsara place'), 'polygon containment');
  // no Place at all, and Samsara unreadable: never guessed
  const nopl = bodyText((await run(myDay({ ...myka, client_code: '999-ZZZ', property_place_id: null, client_place_ids: [] }), { samsara: [MYK], code })).posts[0]).split('\n')[1];
  assert.ok(nopl.endsWith('our map point is probably off, and this client has no Samsara place'), nopl);
  const dn = bodyText((await run(myDay(myka), { samsara: 'FAIL', code })).posts[0]).split('\n')[1];
  assert.ok(dn.endsWith('when it was marked complete: our map point is probably off'), dn);
  // a stop inside 150 m that holds the completion: the time was simply not saved
  const near = { ...myka, stop_at_completion: { ...myka.stop_at_completion, meters: 120 } };
  const nl = bodyText((await run(myDay(near), { samsara: [MYK], code })).posts[0]).split('\n')[1];
  assert.ok(nl.endsWith('|David> was parked here 10:29 AM to 11:02 AM (34 min) when it was marked complete, but the time was not saved'), nl);
  // another truck parked there than the one on the visit (6194: Cloggy there, David on the visit)
  const wrong = { ...myka, stop_at_completion: { ...myka.stop_at_completion, truck: 'Cloggy', truck_samsara_id: '281474998706263', assigned: false } };
  const wl = bodyText((await run(myDay(wrong), { samsara: [MYK], code })).posts[0]).split('\n')[1];
  assert.ok(wl.endsWith('so our map point is probably off; the visit is set to David'), wl);
  const wn = bodyText((await run(myDay({ ...wrong, stop_at_completion: { ...wrong.stop_at_completion, meters: 87 } }), { samsara: [MYK], code })).posts[0]).split('\n')[1];
  assert.ok(wn.endsWith('|Cloggy> was parked here 10:29 AM to 11:02 AM (34 min) when it was marked complete, but the visit is set to David'), wn);
  // 6c. Samsara's own stay replaces our GPS times (visit 6498: ours 3:47 to 4:15, 28 min; Samsara 3:40 to 4:14, 34):
  // trips ending 10:20 and starting 11:00 around the 10:29 to 11:02 stop give 10:20 AM to 11:00 AM (40 min)
  const TRIPS = [{ startMs: Date.parse('2026-09-25T13:50:00Z'), endMs: Date.parse('2026-09-25T14:20:00Z') },
                 { startMs: Date.parse('2026-09-25T15:00:00Z'), endMs: Date.parse('2026-09-25T15:20:00Z') }];
  const sm = bodyText((await run(myDay(near), { samsara: [MYK], trips: TRIPS, code })).posts[0]).split('\n')[1];
  assert.ok(sm.endsWith('|David> was parked here 10:20 AM to 11:00 AM (40 min) when it was marked complete, but the time was not saved'), sm);
  const sd = await run(myDay(near), { body: { dry_run: true }, samsara: [MYK], trips: TRIPS, code });
  assert.strictEqual(sd.body.gaps[0].samsara_stay.minutes, 40, "the dry run hands the report Samsara's stay");
  // trips unreadable, or no gap overlapping the stop: our GPS stop, never a guess
  const sf = bodyText((await run(myDay(near), { samsara: [MYK], trips: 'FAIL', code })).posts[0]).split('\n')[1];
  assert.ok(sf.includes('parked here 10:29 AM to 11:02 AM (34 min)'), sf);
  const away = [{ startMs: Date.parse('2026-09-25T10:00:00Z'), endMs: Date.parse('2026-09-25T10:10:00Z') },
                { startMs: Date.parse('2026-09-25T11:00:00Z'), endMs: Date.parse('2026-09-25T11:10:00Z') }];
  const sa = bodyText((await run(myDay(near), { samsara: [MYK], trips: away, code })).posts[0]).split('\n')[1];
  assert.ok(sa.includes('parked here 10:29 AM to 11:02 AM (34 min)'), sa);

  // the dry run hands the report the same lines
  const dl6 = await run(myDay(myka), { body: { dry_run: true }, samsara: [MYK], code });
  assert.strictEqual(dl6.body.lines[0].visit_id, 6509);
  assert.ok(dl6.body.lines[0].line.startsWith('214-MYK Myka Greek Frozen Yogurt (Food Truck Brickell) · David: David was parked 164 m'), dl6.body.lines[0].line);
  assert.ok(Array.isArray(dl6.body.gaps) && dl6.body.gaps[0].stop_at_completion.minutes === 34);

  // 7. dry run: no post, no log; 8. not service_role: refused
  const dry = await run(day([granada]), { body: { dry_run: true }, code });
  assert.strictEqual(dry.posts.length + dry.logs.length, 0, 'a dry run neither posts nor logs');
  assert.ok(dry.body.message.includes('021-GRA'));
  const anon = await run(day([granada]), { role: 'anon', code });
  assert.strictEqual(anon.status, 403);
  assert.strictEqual(anon.posts.length + anon.logs.length, 0);

  // 9. Slack refuses: an error row, never a false success
  const no = await run(day([granada]), { slack: { ok: false, error: 'channel_not_found' }, code });
  assert.strictEqual(no.status, 502);
  assert.strictEqual(no.logs[0].status, 'error');

  // 10. S8 (plan RC7). The nightly read asks for the last REAL rules-2 run, never a dry run or a failed one.
  const s8 = await run(day([granada]), { nightly: nightRun(CANDS), code });
  const nightUrl = s8.gets.find((u) => u.includes('/sync_log?'));
  assert.ok(nightUrl, 'the last nightly run is read');
  for (const f of ['sync_source=eq.time_on_site_samsara_recheck', 'status=eq.success', 'details->>rules=eq.2', 'details->>dry_run=eq.false', 'order=started_at.desc', 'limit=1']) {
    assert.ok(nightUrl.includes(f), `the nightly read filters ${f}: ${nightUrl}`);
  }
  assert.ok(s8.gets.some((u) => u.includes('/visits?') && u.includes('id=in.(9902,9901,9903)') && u.includes('deleted_at=is.null')),
    'only the truck-question visits are read, live ones only: ' + s8.gets.join(' '));
  // 10a. a listed visit the nightly could not measure yet says so (8752 was "pending" in that run)
  const b8 = bodyText(s8.posts[0]).split('\n');
  assert.ok(b8[1].endsWith('|David>: the truck was still there at the nightly check; it will be measured tonight'), b8[1]);
  assert.ok(s8.posts[0].text.includes('\n• visit 8752 · 021-GRA Granada Condo · David: the truck was still there at the nightly check; it will be measured tonight'), s8.posts[0].text);
  // 10b. the "Which truck went?" block after the list: another truck and no truck only, dated, oldest first, a visit
  // deleted since left out, other hold reasons (other_day) left out
  assert.strictEqual(s8.posts[0].blocks[0].text.text, '⏱️ Visits with no time on site', 'the header is unchanged when visits are listed');
  const at = b8.indexOf('*Which truck went?* If you know, tell Viktor the visit number and the truck:');
  assert.ok(at > 1, 'the block follows the list: ' + b8.join(' | '));
  assert.deepStrictEqual(b8.slice(at + 1), ['• visit 9901 · 112-YA Test Client A · Tue, Nov 3 · set to Moises, but another truck was there too',
                                           '• visit 9902 · 112-YA Test Client B · Wed, Nov 4 · no truck is set on the visit']);
  assert.ok(s8.posts[0].text.endsWith('\nWhich truck went? If you know, tell Viktor the visit number and the truck:\n• visit 9901 · 112-YA Test Client A · Tue, Nov 3 · set to Moises, but another truck was there too\n• visit 9902 · 112-YA Test Client B · Wed, Nov 4 · no truck is set on the visit'),
    'Viktor reads the held visit numbers in text: ' + s8.posts[0].text);
  assert.ok(!b8.some((l) => l.includes('9046')), 'other hold reasons are not truck questions');
  assert.deepStrictEqual(s8.logs[0].details.held, [9901, 9902]);
  assert.strictEqual(s8.logs[0].details.nightly_run, 139308);
  assert.strictEqual(s8.logs[0].details.counts.held, 2);
  // 10c. a day with nothing to list still posts the block (before S8 it posted nothing), tagged, its own header
  const only = await run(day([]), { nightly: nightRun(CANDS), code });
  assert.strictEqual(only.posts.length, 1, 'the block alone is a post');
  assert.strictEqual(only.posts[0].blocks[0].text.text, '⏱️ Which truck went?');
  const ob = bodyText(only.posts[0]).split('\n');
  assert.strictEqual(ob[0], ':stopwatch: <@U0AL9JZ4V7C> *Which truck went?* If you know, tell Viktor the visit number and the truck:');
  assert.strictEqual(ob.length, 3, 'no older line and no list on a block-only post: ' + ob.join(' | '));
  assert.strictEqual(only.posts[0].text.split('\n')[0], ':stopwatch: Which truck went? 2 visits need an answer');
  assert.ok(only.posts[0].text.includes('\nIf you know, tell Viktor the visit number and the truck:\n• visit 9901 '), only.posts[0].text);
  assert.ok(!only.posts[0].text.includes('<@'), 'the phone line never tags');
  assert.strictEqual(only.logs[0].details.reason, 'posted');
  assert.deepStrictEqual(only.logs[0].details.visits, []);
  // 10d. a [TEST] block-only post never tags
  const ot = await run(day([]), { body: { test: true }, nightly: nightRun(CANDS), code });
  assert.ok(!JSON.stringify(ot.posts[0]).includes('<@'), 'a test never tags anyone');
  assert.ok(bodyText(ot.posts[0]).startsWith(':stopwatch: [TEST] *Which truck went?*'), bodyText(ot.posts[0]));
  // 10e. a run over 20 hours old (tonight's failed): no block, no reason from it, nothing posted on an empty day
  const stale = await run(day([]), { nightly: nightRun(CANDS, 21), code });
  assert.strictEqual(stale.posts.length, 0, 'an old run is never shown as tonight\'s');
  assert.strictEqual(stale.logs[0].details.reason, 'no visit without time on site');
  assert.strictEqual(stale.logs[0].details.nightly_run, null);
  const staleG = bodyText((await run(day([granada]), { nightly: nightRun(CANDS, 21), code })).posts[0]);
  assert.ok(!staleG.includes('Which truck') && !staleG.includes('still there'), staleG);
  // 10f. the nightly read fails: the post goes out as before, the failure is in the run's row
  const nf = await run(day([granada]), { nightly: 'FAIL', code });
  assert.strictEqual(nf.posts.length, 1);
  assert.ok(bodyText(nf.posts[0]).split('\n')[1].endsWith('no truck came within 150 m (closest 291 m)'), bodyText(nf.posts[0]));
  assert.ok(String(nf.logs[0].details.nightly_read_error).includes('HTTP 500'), JSON.stringify(nf.logs[0].details));
  assert.strictEqual(nf.logs[0].status, 'success');
  // 10g. no truck question in the run: the day posts exactly as before S8
  const quiet = await run(day([]), { nightly: nightRun(CANDS.filter((c) => !['another_truck', 'no_truck'].includes(c.hold_reason))), code });
  assert.strictEqual(quiet.posts.length, 0);
  assert.ok(!quiet.gets.some((u) => u.includes('/visits?')), 'no visit read when nothing is held for a truck');
  // 10h. the dry run shows the block and posts nothing
  const d8 = await run(day([]), { body: { dry_run: true }, nightly: nightRun(CANDS), code });
  assert.strictEqual(d8.posts.length + d8.logs.length, 0);
  assert.deepStrictEqual(d8.body.held.map((h) => h.visit_id), [9901, 9902]);
  assert.ok(d8.body.message.includes('*Which truck went?*'));
}

await checks(src);
console.log('time_on_site_reminder: all checks passed');

if (MUTATE) {
  const mutants = [
    ['tag on a test', src.replace('test ? "[TEST] " : DIEGO + " "', 'test ? "[TEST] " + DIEGO + " " : DIEGO + " "')],
    ['no place params', src.replace('?duration=2678399.999&end_ms=', '?end_ms=')],
    ['guess when Samsara is down', src.replace('else if (checked && !place)', 'else if (!place)')],
    ['print 0 older', src.replace('if (older != null && older > 0)', 'if (true)')],
    ['post when empty', src.replace('if (!gaps.length && !held.length) {', 'if (false) {')],
    ['ignore the stop at completion', src.replace('else if (s) {', 'else if (false) {')],
    ['circle containment inverted', src.replace('<= p.geo.circle.r', '> p.geo.circle.r')],
    ['polygon containment dropped', src.replace('inside = !inside;', 'inside = false;')],
    ['near and far stops swapped', src.replace('if (s.meters > NEAR_M) {', 'if (s.meters <= NEAR_M) {')],
    ['other truck not named', src.replace('const other = !s.assigned && g.truck ?', 'const other = false ?')],
    // S8
    ['block skipped on a day with no visit', src.replace('if (!gaps.length && !held.length) {', 'if (!gaps.length) {')],
    ['an old nightly run used', src.replace('Date.now() - Date.parse(run.started_at) > NIGHTLY_MAX_AGE_H * 3600e3', 'false')],
    ['still there ignored', src.replace('if (g.still_there) reason = STILL_THERE;', 'if (false) reason = STILL_THERE;')],
    ['held visits not in text', src.replace('...held.map(heldLine)] : [])', '] : [])')],
    ['dry runs counted', src.replace('&details->>dry_run=eq.false', '')],
    ['every hold listed', src.replace('c?.decision === "hold" && WHICH_TRUCK.has(c.hold_reason)', 'c?.decision === "hold"')],
    ['deleted visits listed', src.replace('&deleted_at=is.null', '')],
  ];
  for (const [name, code] of mutants) {
    assert.notStrictEqual(code, src, `mutant "${name}" did not change the source`);
    let caught = false;
    // only a failed assertion counts as caught: a harness error (vm, a stub) must never pass as a caught mutant
    try { await checks(code); } catch (e) { if (!(e instanceof assert.AssertionError)) throw e; caught = true; }
    assert.ok(caught, `mutant "${name}" survived: the checks cannot see it`);
    console.log(`mutant caught: ${name}`);
  }
}
