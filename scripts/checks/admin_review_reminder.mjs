// admin_review_reminder.mjs - runs the REAL supabase/functions/admin-review-reminder/index.ts (types stripped by
// Node 22) against a stubbed database and a stubbed Slack, and asserts what is posted.
//   node scripts/checks/admin_review_reminder.mjs
// The rules (Fred, 2026-10-07, shortened 2026-10-12): one post a day in #apps-notifications tagging Diego and Serena,
// listing the visits whose photos are sorted but whose city email is not sent (one "Broward" group, a link to each
// visit in Admin Review) and how many visits have photos not sorted; nothing when nothing is waiting; header first;
// one-line phone text; names escaped; no em dash; a [TEST] post tags nobody.
// Since 2026-10-12 (audit): every run that is not a dry run writes ONE public.sync_log row (stubbed here), also when
// nothing is waiting and when the function throws; a [TEST] run logs as admin_review_reminder_test; a failed insert
// never fails the post. The post itself is unchanged.
// The fixture rows are fictional (9001, 9002, ...) or real visits that are valid city rows; the 2026-10-12 audit
// replaced 283-PIK visit 8575, an unclog visit that is not a city email, which this file used to list as input.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';
import { stripTypeScriptTypes } from 'node:module';

const src = fs.readFileSync(new URL('../../supabase/functions/admin-review-reminder/index.ts', import.meta.url), 'utf8');
const helper = fs.readFileSync(new URL('../../supabase/functions/_shared/slack-notify.ts', import.meta.url), 'utf8');
const IMPORT = 'import { slackHeader, slackIdentity, slackSections } from "../_shared/slack-notify.ts";';
assert.ok(src.includes(IMPORT), 'the function imports the shared helpers');
const js = [stripTypeScriptTypes(helper).replace(/^export /gm, ''), stripTypeScriptTypes(src.replace(IMPORT, ''))].join('\n');
const jwt = (role) => 'h.' + Buffer.from(JSON.stringify({ role })).toString('base64') + '.s';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// rpc: 'THROW' (network error), 'NOTJSON' (a body that is not JSON), or the object returned; slack: 'THROW' or the reply
async function run(pending, { body = {}, rawBody, role = 'service_role', slack = { ok: true, ts: '1.2' }, scopes = 'chat:write,chat:write.customize', syncLog = 'ok', delay = 0, env = { SLACK_BOT_TOKEN: 'xoxb' } } = {}) {
  const posts = [], logs = [];
  let handler;
  const ctx = {
    Deno: { env: { get: (k) => ({ SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'svc', ...env })[k] },
            serve: (h) => { handler = h; } },
    fetch: async (url, opts = {}) => {
      url = String(url);
      if (url.endsWith('/rest/v1/rpc/fn_admin_review_pending')) {
        if (delay) await sleep(delay);
        if (pending === 'THROW') throw new Error('rpc network down');
        if (pending === 'NOTJSON') return new Response('<html>gateway</html>', { status: 200 });
        return Response.json(pending);
      }
      if (url === 'https://slack.com/api/chat.postMessage') {
        if (slack === 'THROW') throw new Error('slack network down');
        posts.push(JSON.parse(opts.body)); return Response.json(slack);
      }
      if (url === 'https://slack.com/api/auth.test') return Response.json({ ok: true }, { headers: { 'x-oauth-scopes': scopes } });
      if (url === 'https://x.supabase.co/rest/v1/sync_log') {
        logs.push({ method: opts.method, headers: opts.headers, row: JSON.parse(opts.body) });
        if (syncLog === 'THROW') throw new Error('network down');
        if (syncLog === 'HTTP500') return new Response('{"message":"boom"}', { status: 500 });
        return new Response(null, { status: 201 });
      }
      throw new Error('unexpected fetch ' + url);
    },
    Response, JSON, String, Number, Math, Date, Array, Error, atob, btoa, console, encodeURIComponent,
  };
  vm.runInNewContext(js, ctx);
  const res = await handler(new Request('https://fn', { method: 'POST', headers: { authorization: 'Bearer ' + jwt(role) }, body: rawBody ?? JSON.stringify(body) }));
  return { status: res.status, body: await res.json(), posts, logs };
}
const body = (p) => p.blocks.filter((b) => b.type === 'section').map((b) => b.text.text).join('\n');
const v = (id, city, o = {}) => ({ visit_id: id, client_code: '103-BWC', client_name: 'Barrel Wine & Cheese', city, visit_date: '2026-09-15', driver: 'Michael Escobar', photos_total: 13, photos_sorted: 13, ...o });
const photos = (count, last, oldest) => ({ count, last_7_days: last, oldest });

// nothing waiting: no post
const none = await run({ city: [], photos: photos(0, 0, null) });
assert.strictEqual(none.posts.length, 0, 'nothing waiting must post nothing');
assert.strictEqual(none.body.posted, false);

// the real shape: only visits whose photos are all sorted are listed, one "Broward" group (Fred, 2026-10-12)
const real = await run({ city: [
  v(6275, 'Hallandale Beach'),
  v(9002, 'Hallandale Beach', { client_code: '998-UNS', client_name: 'Unsorted Fixture', visit_date: '2026-09-26', driver: 'Fixture Driver', photos_total: 4, photos_sorted: 0 }),
  v(8133, 'Surfside', { client_code: '306-16', client_name: '16 Handles', visit_date: '2026-09-18' }),
  v(9001, 'Surfside', { client_code: '999-NP', client_name: 'No Photos', photos_total: 0, photos_sorted: 0, driver: null }),
], photos: photos(138, 18, '2026-07-01') });
assert.strictEqual(real.posts.length, 1);
const p0 = real.posts[0];
assert.strictEqual(p0.channel, 'C0BJYHQKZM1', '#apps-notifications');
assert.deepStrictEqual(p0.blocks[0], { type: 'header', text: { type: 'plain_text', text: '📸 Photos and city emails', emoji: true } });
assert.ok(p0.text.startsWith('📸 Admin Review: 2 visits with photos sorted still need a city email, 138 visits have photos not sorted\n\n'), p0.text);
assert.ok(p0.text.endsWith(body(p0)), 'text carries the whole list (Viktor reads only text)');
const b = body(p0);
assert.strictEqual(b, [
  '🏙 <@U0AL9JZ4V7C> <@U0BKM57UPSS> *Broward: city email not sent yet (2):*',
  '• <https://admin.unclogme.app/review/6275|103-BWC Barrel Wine &amp; Cheese> · Sep 15 · Michael Escobar',
  '• <https://admin.unclogme.app/review/8133|306-16 16 Handles> · Sep 18 · Michael Escobar',
  '',
  '🖼 *Photos not sorted: 138 visits* · 18 from the last 7 days · oldest Jul 1',
].join('\n'), b);
assert.ok(!/9002|9001|Hallandale|Surfside|✅|❌/.test(b + p0.text), 'unsorted and photo-less visits, city names and marks are gone');
assert.ok(!/⏳|manifest/i.test(b + p0.text), 'no line about manifests: the post is unchanged by the 2026-10-12 audit');
assert.ok(!/\u2014/.test(b + p0.text), 'no em dash');
assert.strictEqual((b.match(/<@/g) || []).length, 2, 'Diego and Serena tagged once');
assert.strictEqual(p0.blocks.at(-1).type, 'context');
assert.ok(p0.blocks.at(-1).elements[0].text.includes('<https://admin.unclogme.app|Open Admin Review>'));
assert.strictEqual(p0.username, 'Admin Review');
assert.ok(p0.icon_url.endsWith('/_brand/favicons/admin-review/icon-512.png'), p0.icon_url);
assert.strictEqual(p0.unfurl_links, false);
assert.strictEqual(real.body.city, 2);
assert.ok(!('stale_no_manifest' in real.body), 'the reply has no stale_no_manifest field');

// an extra key in the RPC reply (an older or newer list) changes nothing in the post
const extra = await run({ city: [v(6275, 'Hallandale Beach')], photos: photos(1, 0, '2026-09-01'), stale_no_manifest: [{ visit_id: 1 }] });
assert.strictEqual(body(extra.posts[0]), body((await run({ city: [v(6275, 'Hallandale Beach')], photos: photos(1, 0, '2026-09-01') })).posts[0]));

// a city visit whose photos are not sorted (or missing) is not listed; with nothing else waiting, no post
const unsortedOnly = await run({ city: [v(1, 'Surfside', { photos_sorted: 5 }), v(2, 'Surfside', { photos_total: 0, photos_sorted: 0 })], photos: photos(0, 0, null) });
assert.strictEqual(unsortedOnly.posts.length, 0, 'only unsorted city visits must post nothing');

// only one part waiting: the other is left out, and the tags move to the first line
const onlyPhotos = await run({ city: [], photos: photos(1, 1, '2026-10-06') });
assert.ok(onlyPhotos.posts[0].text.startsWith('📸 Admin Review: 1 visit has photos not sorted\n'), onlyPhotos.posts[0].text);
assert.ok(body(onlyPhotos.posts[0]).startsWith('🖼 <@U0AL9JZ4V7C> <@U0BKM57UPSS> *Photos not sorted: 1 visit*'), body(onlyPhotos.posts[0]));
assert.ok(!body(onlyPhotos.posts[0]).includes('Broward'));
const onlyCity = await run({ city: [v(1, 'Surfside')], photos: photos(0, 0, null) });
assert.ok(onlyCity.posts[0].text.startsWith('📸 Admin Review: 1 visit with photos sorted still needs a city email\n'), onlyCity.posts[0].text);
assert.ok(!body(onlyCity.posts[0]).includes('Photos not sorted'));

// a long list is capped, split under Slack's limits, nothing lost before the cap; the count is the whole list
const many = await run({ city: Array.from({ length: 45 }, (_, i) => v(1000 + i, i < 20 ? 'Hallandale Beach' : 'Surfside')), photos: photos(5, 1, '2026-09-01') });
const mb = body(many.posts[0]);
assert.strictEqual((mb.match(/^• /gm) || []).length, 40);
assert.ok(mb.includes('…and 5 more in <https://admin.unclogme.app|Admin Review>.'));
assert.ok(mb.includes('*Broward: city email not sent yet (45):*'));
for (const blk of many.posts[0].blocks) if (blk.type === 'section') assert.ok(blk.text.text.length <= 3000);

// dry run: the text, no post; test: [TEST] on both lines and nobody tagged
const dry = await run({ city: [v(1, 'Surfside')], photos: photos(0, 0, null) }, { body: { dry_run: true } });
assert.strictEqual(dry.posts.length, 0);
assert.ok(dry.body.message.includes('review/1|'));
const tst = await run({ city: [v(1, 'Surfside')], photos: photos(3, 0, '2026-09-01') }, { body: { test: true } });
assert.ok(tst.posts[0].text.startsWith('📸 [TEST] Admin Review:'), tst.posts[0].text);
assert.ok(body(tst.posts[0]).startsWith('🏙 [TEST] *Broward'), body(tst.posts[0]));
assert.ok(!/<@/.test(tst.posts[0].text + body(tst.posts[0])), 'a [TEST] post tags nobody');
const tstPhotos = await run({ city: [], photos: photos(3, 0, '2026-09-01') }, { body: { test: true } });
assert.ok(body(tstPhotos.posts[0]).startsWith('🖼 [TEST] *Photos'), body(tstPhotos.posts[0]));
assert.ok(!/TEST/.test(p0.text + b), 'a normal post carries no TEST mark');

// refusals: Slack says no -> 502; not service_role -> 403, nothing posted; a broken read -> 500, nothing posted
const refused = await run({ city: [v(1, 'Surfside')], photos: photos(0, 0, null) }, { slack: { ok: false, error: 'not_in_channel' } });
assert.strictEqual(refused.status, 502); assert.match(refused.body.error, /not_in_channel/);
const anon = await run({ city: [v(1, 'Surfside')], photos: photos(0, 0, null) }, { role: 'authenticated' });
assert.strictEqual(anon.status, 403); assert.strictEqual(anon.posts.length, 0);
const broken = await run({ message: 'boom' });
assert.strictEqual(broken.status, 500); assert.strictEqual(broken.posts.length, 0);
const plain = await run({ city: [v(1, 'Surfside')], photos: photos(0, 0, null) }, { scopes: 'chat:write' });
assert.ok(!('username' in plain.posts[0]), 'no custom name without chat:write.customize');

// ---- the run record: ONE public.sync_log row per run (audit 2026-10-12, P3) ----
const one = (r) => { assert.strictEqual(r.logs.length, 1, 'exactly one sync_log row'); return r.logs[0]; };
const l0 = one(real);
assert.strictEqual(l0.method, 'POST');
assert.strictEqual(l0.headers.apikey, 'svc'); assert.strictEqual(l0.headers.Authorization, 'Bearer svc');
assert.strictEqual(l0.headers['Content-Type'], 'application/json', 'PostgREST refuses a POST without it');
assert.strictEqual(l0.headers.Prefer, 'return=minimal');
assert.strictEqual(l0.row.sync_source, 'admin_review_reminder');
assert.strictEqual(l0.row.status, 'success');
assert.strictEqual(l0.row.rows_errored, 0); assert.strictEqual(l0.row.error_details, null);
assert.ok(Date.parse(l0.row.started_at) <= Date.parse(l0.row.finished_at), 'started before finished');
assert.ok(typeof l0.row.duration_seconds === 'number' && l0.row.duration_seconds >= 0);
assert.deepStrictEqual(l0.row.details, { posted: true, reason: 'posted', slack_ts: '1.2', visit_ids: [6275, 8133],
  counts: { city: 2, photos: 138 }, test: false });
assert.strictEqual(real.body.sync_log_error, null);

// the duration is measured, not a constant
const slow = await run({ city: [v(1, 'Surfside')], photos: photos(0, 0, null) }, { delay: 60 });
const ls = one(slow).row;
assert.ok(ls.duration_seconds >= 0.05, `duration ${ls.duration_seconds}s covers a 60 ms read`);
assert.ok(Math.abs((Date.parse(ls.finished_at) - Date.parse(ls.started_at)) / 1000 - ls.duration_seconds) < 0.05, 'duration matches started/finished');

// every waiting visit is recorded, in the post's order, not only the 40 shown
assert.strictEqual(one(many).row.details.visit_ids.length, 45, 'all 45 ids, not the 40 shown');
assert.deepStrictEqual(one(many).row.details.visit_ids, Array.from({ length: 45 }, (_, i) => 1000 + i));
const order = await run({ city: [v(5, 'Surfside', { visit_date: '2026-09-20' }), v(9, 'Surfside', { visit_date: '2026-09-16' })], photos: photos(0, 0, null) });
assert.deepStrictEqual(one(order).row.details.visit_ids, [9, 5], 'ids follow the post (oldest first), not the id order');

const ln = one(none);
assert.strictEqual(ln.row.status, 'success', 'nothing to post is a successful run');
assert.deepStrictEqual(ln.row.details, { posted: false, reason: 'nothing is waiting', visit_ids: [],
  counts: { city: 0, photos: 0 }, test: false });
assert.strictEqual(one(unsortedOnly).row.details.reason, 'nothing is waiting');

const lr = one(refused);
assert.strictEqual(lr.row.status, 'error'); assert.strictEqual(lr.row.rows_errored, 1);
assert.strictEqual(lr.row.details.posted, false); assert.match(lr.row.details.error, /not_in_channel/);
assert.deepStrictEqual(lr.row.details.visit_ids, [1], 'a refused post still records what it tried to list');
assert.match(lr.row.error_details.message, /^The Admin Review Slack reminder did not post: Slack refused the post \(slack: not_in_channel\)$/);
const noTok = await run({ city: [v(1, 'Surfside')], photos: photos(0, 0, null) }, { env: {} });
assert.strictEqual(noTok.status, 500); assert.strictEqual(noTok.posts.length, 0);
assert.strictEqual(one(noTok).row.status, 'error'); assert.match(one(noTok).row.details.error, /SLACK_BOT_TOKEN/);
assert.deepStrictEqual(one(noTok).row.details.visit_ids, [1]);
const lb = one(broken);
assert.strictEqual(lb.row.status, 'error'); assert.match(lb.row.details.error, /unexpected shape/);

// a [TEST] run logs under its own source, so it can never stand in for a real run
assert.strictEqual(one(tst).row.sync_source, 'admin_review_reminder_test');
assert.strictEqual(one(tst).row.details.test, true);
assert.strictEqual(one(tst).row.status, 'success');
assert.strictEqual(one(real).row.details.test, false);
assert.strictEqual(dry.logs.length, 0, 'a dry run writes no row');
assert.strictEqual(anon.logs.length, 0, 'a refused caller writes no row');
const dryNone = await run({ city: [], photos: photos(0, 0, null) }, { body: { dry_run: true } });
assert.strictEqual(dryNone.logs.length, 0, 'a dry run with nothing waiting writes no row either');
const nullBody = await run({ city: [], photos: photos(0, 0, null) }, { rawBody: 'null' });
assert.strictEqual(nullBody.status, 200, 'a JSON null body is treated as {}'); assert.strictEqual(one(nullBody).row.sync_source, 'admin_review_reminder');

// a thrown error still writes ONE 'error' row: Slack network error, RPC network error, a body that is not JSON,
// a null item in the list; nothing is posted and the reply is a 500 that names the error
for (const [name, pending, opts, msg] of [
  ['slack throws', { city: [v(1, 'Surfside')], photos: photos(0, 0, null) }, { slack: 'THROW' }, /slack network down/],
  ['rpc throws', 'THROW', {}, /rpc network down/],
  ['rpc not json', 'NOTJSON', {}, /JSON|Unexpected token/],
  ['null item', { city: [null], photos: photos(0, 0, null) }, {}, /TypeError|null/],
]) {
  const r = await run(pending, opts);
  assert.strictEqual(r.status, 500, `${name}: 500`);
  assert.strictEqual(r.posts.length, 0, `${name}: nothing posted`);
  assert.strictEqual(r.body.posted, false);
  const row = one(r).row;
  assert.strictEqual(row.status, 'error', `${name}: an error row`);
  assert.strictEqual(row.details.reason, 'the reminder stopped with an error');
  assert.match(row.details.error, msg, `${name}: ${row.details.error}`);
  assert.match(row.error_details.message, /^The Admin Review Slack reminder did not post: the reminder stopped with an error \(/);
}
const thrownTest = await run('THROW', { body: { test: true } });
assert.strictEqual(one(thrownTest).row.sync_source, 'admin_review_reminder_test', 'a thrown [TEST] run logs as test');
const thrownDry = await run('THROW', { body: { dry_run: true } });
assert.strictEqual(thrownDry.status, 500); assert.strictEqual(thrownDry.logs.length, 0, 'a thrown dry run writes no row');

// a failed sync_log insert never fails the post: still posted, still 200, the reason in sync_log_error
for (const mode of ['HTTP500', 'THROW']) {
  const r = await run({ city: [v(1, 'Surfside')], photos: photos(0, 0, null) }, { syncLog: mode });
  assert.strictEqual(r.posts.length, 1, `posted although sync_log failed (${mode})`);
  assert.strictEqual(r.status, 200); assert.strictEqual(r.body.posted, true);
  assert.match(r.body.sync_log_error, mode === 'HTTP500' ? /^HTTP 500 / : /network down/);
  const n = await run({ city: [], photos: photos(0, 0, null) }, { syncLog: mode });
  assert.strictEqual(n.status, 200); assert.strictEqual(n.body.reason, 'nothing is waiting');
  const rf = await run({ city: [v(1, 'Surfside')], photos: photos(0, 0, null) }, { syncLog: mode, slack: { ok: false, error: 'not_in_channel' } });
  assert.strictEqual(rf.status, 502, 'a Slack refusal stays a 502 when the log fails too');
  const th = await run('THROW', { syncLog: mode });
  assert.strictEqual(th.status, 500, 'a thrown run with a failing log is still a clean 500'); assert.ok(th.body.sync_log_error);
}

// the header comment states the run-record contract the health check relies on
for (const s of [/once a day whether or not anything is waiting/, /sync_source\s*\n?\/\/\s*'admin_review_reminder'; \[TEST\] runs use 'admin_review_reminder_test'/,
  /a thrown error still writes its row/, /failed sync_log insert\s*\n?\/\/\s*never fails the post/]) assert.match(src, s);
assert.ok(!/makes no call when nothing is waiting/.test(src), 'the old wrapper rule is gone from the header');

console.log('admin_review_reminder: all checks passed');
