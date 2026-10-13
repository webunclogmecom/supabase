// time_on_site_reminder.mjs - runs the REAL supabase/functions/time-on-site-reminder/index.ts (types stripped by
// Node 22) against a stubbed database, Samsara and Slack, and asserts what is posted.
//   node scripts/checks/time_on_site_reminder.mjs          (add --mutate to prove the checks can fail)
// Rules under test (Fred, 2026-10-12, Option A, "tag Diego"): one line per visit with its reason; the client name
// opens its Samsara Place (WITH the duration/end_ms params); Diego tagged on the first line, never on a [TEST], never
// in `text`; nothing posted when the list is empty; a dry run never posts or logs; every other run writes ONE
// public.sync_log row; a failed Samsara read leaves the place reasons out instead of guessing. What the database
// lists (which visits) is tested by the migration's VERIFY, not here: a stub cannot see a wrong query.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';
import { stripTypeScriptTypes } from 'node:module';

const src = fs.readFileSync(new URL('../../supabase/functions/time-on-site-reminder/index.ts', import.meta.url), 'utf8');
const helper = fs.readFileSync(new URL('../../supabase/functions/_shared/slack-notify.ts', import.meta.url), 'utf8');
const IMPORT = 'import { slackHeader, slackIdentity, slackScopes, slackSections } from "../_shared/slack-notify.ts";';
assert.ok(src.includes(IMPORT), 'the function imports the shared Slack helpers');
const MUTATE = process.argv.includes('--mutate');
const build = (code) => [stripTypeScriptTypes(helper).replace(/^export /gm, ''), stripTypeScriptTypes(code.replace(IMPORT, ''))].join('\n');
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

async function run(list, { body = {}, role = 'service_role', samsara = PLACES, slack = { ok: true, ts: '1.2' }, code = src, env = {} } = {}) {
  const posts = [], logs = [];
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
      if (url === 'https://x.supabase.co/rest/v1/sync_log') { logs.push(JSON.parse(opts.body)); return new Response(null, { status: 201 }); }
      if (url === 'https://slack.com/api/chat.postMessage') { posts.push(JSON.parse(opts.body)); return Response.json(slack); }
      if (url === 'https://slack.com/api/auth.test') return Response.json({ ok: true }, { headers: { 'x-oauth-scopes': 'chat:write,chat:write.customize' } });
      throw new Error('unexpected fetch ' + url);
    },
    Response, JSON, String, Number, Math, Date, Array, Map, Error, atob, console, encodeURIComponent,
  };
  vm.runInNewContext(build(code), ctx);
  const res = await handler(new Request('https://fn', { method: 'POST', headers: { authorization: 'Bearer ' + jwt(role) }, body: JSON.stringify(body) }));
  return { status: res.status, body: await res.json(), posts, logs };
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
}

await checks(src);
console.log('time_on_site_reminder: all checks passed');

if (MUTATE) {
  const mutants = [
    ['tag on a test', src.replace('test ? "[TEST] " : DIEGO + " "', 'test ? "[TEST] " + DIEGO + " " : DIEGO + " "')],
    ['no place params', src.replace('?duration=2678399.999&end_ms=', '?end_ms=')],
    ['guess when Samsara is down', src.replace('else if (checked && !place)', 'else if (!place)')],
    ['print 0 older', src.replace('if (older != null && older > 0)', 'if (true)')],
    ['post when empty', src.replace('if (!gaps.length) {', 'if (false) {')],
  ];
  for (const [name, code] of mutants) {
    assert.notStrictEqual(code, src, `mutant "${name}" did not change the source`);
    let caught = false;
    try { await checks(code); } catch { caught = true; }
    assert.ok(caught, `mutant "${name}" survived: the checks cannot see it`);
    console.log(`mutant caught: ${name}`);
  }
}
