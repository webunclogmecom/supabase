// stamp_sheets_reminder.mjs - runs the REAL supabase/functions/stamp-sheets-reminder/index.ts (types
// stripped by Node 22) against a stubbed database and a stubbed Slack, and asserts what is posted.
//   node scripts/checks/stamp_sheets_reminder.mjs
// The rules under test (Fred, 2026-10-05): post the not-completed Stamp Studio sheets to
// #apps-notifications; post NOTHING when every sheet is completed; a dry run never posts; on the shared bot the
// post shows as "Stamp Studio" ONLY when the bot holds chat:write.customize; every post starts with the header block
// (Option A) and its sections rebuild the message under Slack's limits (the real _shared/slack-notify.ts is inlined,
// so its scope gate, header and section split are what is tested).
// Since 2026-10-12 (audit): every run that is not a dry run or check_bot writes ONE public.sync_log row (stubbed here),
// also when every sheet is completed and when the function throws; a [TEST] run logs as stamp_sheets_reminder_test; a
// failed insert never fails the post. Leaving out test-client sheets happens in SQL (derm.fn_stamp_open_sheets,
// migration 2026-10-12_1315, whose VERIFY tests it); a stub cannot test what the database returns.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';
import { stripTypeScriptTypes } from 'node:module';

const src = fs.readFileSync(new URL('../../supabase/functions/stamp-sheets-reminder/index.ts', import.meta.url), 'utf8');
const helper = fs.readFileSync(new URL('../../supabase/functions/_shared/slack-notify.ts', import.meta.url), 'utf8');
const IMPORT = 'import { slackHeader, slackIdentity, slackScopes, slackSections } from "../_shared/slack-notify.ts";';
assert.ok(src.includes(IMPORT), 'the function imports the shared identity helper');
const js = [stripTypeScriptTypes(helper).replace(/^export /gm, ''), stripTypeScriptTypes(src.replace(IMPORT, ''))].join('\n');
const jwt = (role) => 'h.' + Buffer.from(JSON.stringify({ role })).toString('base64') + '.s';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// sheets: 'THROW' (network error), 'NOTJSON' (a body that is not JSON), or what the RPC returns; slack: 'THROW' or the reply
async function run(sheets, { body = {}, role = 'service_role', slack = { ok: true, ts: '1.2' }, env = { SLACK_BOT_TOKEN: 'xoxb' }, scopes = 'chat:write,incoming-webhook', syncLog = 'ok', rpcStatus = 200, delay = 0, rawBody } = {}) {
  const posts = [], auths = [], logs = [];
  let handler, rpcHeaders;
  const ctx = {
    Deno: { env: { get: (k) => ({ SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'svc', ...env })[k] },
            serve: (h) => { handler = h; } },
    fetch: async (url, opts = {}) => {
      url = String(url);
      if (url.endsWith('/rest/v1/rpc/fn_stamp_open_sheets')) {
        rpcHeaders = opts.headers;
        if (delay) await sleep(delay);
        if (sheets === 'THROW') throw new Error('rpc network down');
        if (sheets === 'NOTJSON') return new Response('<html>gateway</html>', { status: 200 });
        return Response.json(sheets, { status: rpcStatus });
      }
      if (url === 'https://x.supabase.co/rest/v1/sync_log') {
        logs.push({ method: opts.method, headers: opts.headers, row: JSON.parse(opts.body) });
        if (syncLog === 'THROW') throw new Error('network down');
        if (syncLog === 'HTTP500') return new Response('{"message":"boom"}', { status: 500 });
        return new Response(null, { status: 201 });
      }
      if (url === 'https://slack.com/api/chat.postMessage') {
        if (slack === 'THROW') throw new Error('slack network down');
        posts.push(JSON.parse(opts.body)); auths.push(opts.headers.Authorization); return Response.json(slack);
      }
      if (url === 'https://slack.com/api/auth.test') {
        auths.push(opts.headers.Authorization);
        if (scopes === 'THROW') throw new Error('network down');
        return Response.json({ ok: true, user: 'unclogme_apps', team: 'UnclogMe' }, { headers: scopes == null ? {} : { 'x-oauth-scopes': scopes } });
      }
      throw new Error('unexpected fetch ' + url);
    },
    Response, JSON, String, Number, Math, Date, Array, Error, atob, btoa, console, encodeURIComponent,
  };
  vm.runInNewContext(js, ctx);
  const res = await handler(new Request('https://fn', { method: 'POST', headers: { authorization: 'Bearer ' + jwt(role) }, body: rawBody ?? JSON.stringify(body) }));
  return { status: res.status, body: await res.json(), posts, auths, rpcHeaders, logs };
}

const body = (p) => p.blocks.slice(1).map((b) => b.text.text).join('\n');
const sheet = (m, o = {}) => ({ manifest: m, service_date: '2026-09-20', dump_date: '2026-09-21', placed: 4, total: 9, pages: 2, status: 'In progress', days_waiting: 14, ...o });

// nothing open: no post at all
const none = await run([]);
assert.strictEqual(none.posts.length, 0, 'every sheet completed must post nothing');
assert.strictEqual(none.body.posted, false);
assert.strictEqual(none.rpcHeaders['Content-Profile'], 'derm', 'the list is read from the derm schema');

// one open sheet: singular title, link, dates, counts, status, waiting days, the right channel
const one = await run([sheet('836624')]);
assert.strictEqual(one.posts.length, 1);
assert.strictEqual(one.posts[0].channel, 'C0BJYHQKZM1', '#apps-notifications');
// the phone line (text) is ONE line naming the app; the body's first line does not repeat it (2026-10-07)
assert.strictEqual(one.posts[0].text, ':memo: Stamp Studio: 1 sheet is not completed');
assert.match(body(one.posts[0]), /^:memo: <@U0AL9JZ4V7C> <@U0BKM57UPSS> \*1 sheet is not completed\*\n/);  // Diego + Serena (2026-10-12)
assert.ok(body(one.posts[0]).includes('• <https://stamp.unclogme.app/836624|Manifest 836624> · dumped Sep 21 · 4 of 9 stamped · In progress · waiting 14 days'), body(one.posts[0]));
assert.strictEqual(one.body.posted, true);

// plural, no dump date (falls back to the service date), 1 day, 0 days (no "waiting"), not started
const two = await run([sheet('1', { dump_date: null, days_waiting: 1, placed: 0, status: 'Not started' }), sheet('2', { days_waiting: 0 })]);
assert.match(two.posts[0].text, /2 sheets are not completed/);
assert.ok(body(two.posts[0]).includes('Manifest 1> · dumped Sep 20 · 0 of 9 stamped · Not started · waiting 1 day'), body(two.posts[0]));
assert.ok(body(two.posts[0]).split('\n')[2].endsWith('In progress'), 'no "waiting" on the day of the dump');
assert.ok(!/\u2014/.test(body(two.posts[0]) + two.posts[0].text), 'no em dash in the message');

// the header (Option A) comes first, and the sections rebuild the exact message
const blocksOf = (p) => p.blocks;
const sectionsText = (p) => p.blocks.slice(1).map((b) => { assert.strictEqual(b.type, 'section'); assert.strictEqual(b.text.type, 'mrkdwn'); return b.text.text; }).join('\n');
assert.deepStrictEqual(blocksOf(one.posts[0])[0], { type: 'header', text: { type: 'plain_text', text: '📝 Stamp Studio sheets', emoji: true } });
assert.ok(!one.posts[0].text.includes('\n'), 'the fallback text is one line');

// more than 40: capped with a pointer to the Studio
const many = await run(Array.from({ length: 45 }, (_, i) => sheet(String(900000 + i))));
const lines = body(many.posts[0]).split('\n');
assert.strictEqual(lines.length, 1 + 40 + 1);
assert.ok(lines.at(-1).includes('and 5 more'), lines.at(-1));
const manyDry = await run(Array.from({ length: 45 }, (_, i) => sheet(String(900000 + i))), { body: { dry_run: true } });
assert.strictEqual(sectionsText(many.posts[0]), manyDry.body.message, 'a long list is split without losing a line');
assert.ok(many.posts[0].blocks.length <= 50, 'Slack allows 50 blocks');
for (const b of many.posts[0].blocks.slice(1)) assert.ok(b.text.text.length <= 3000, `section of ${b.text.text.length} chars`);
assert.ok(many.posts[0].blocks.length > 2, 'the 41-line list needs more than one section, so the split is exercised');

// dry run: the text, no post
const dry = await run([sheet('836624')], { body: { dry_run: true } });
assert.strictEqual(dry.posts.length, 0, 'dry run must not post');
assert.ok(dry.body.message.includes('Manifest 836624'));
assert.strictEqual(dry.body.text, ':memo: Stamp Studio: 1 sheet is not completed');

// Slack refuses: reported, not swallowed
const refused = await run([sheet('836624')], { slack: { ok: false, error: 'not_in_channel' } });
assert.strictEqual(refused.status, 502);
assert.match(refused.body.error, /not_in_channel/);

// only service_role may call it
const anon = await run([sheet('836624')], { role: 'authenticated' });
assert.strictEqual(anon.status, 403);
assert.strictEqual(anon.posts.length, 0);

// test: posted, with the [TEST] prefix
const tst = await run([sheet('836624')], { body: { test: true } });
assert.strictEqual(tst.posts.length, 1);
assert.strictEqual(tst.posts[0].text, ':memo: [TEST] Stamp Studio: 1 sheet is not completed');
assert.ok(body(tst.posts[0]).startsWith(':memo: [TEST] *1 sheet'), body(tst.posts[0]));
assert.ok(!/TEST/.test(one.posts[0].text + body(one.posts[0])), 'a normal post carries no TEST mark');
assert.ok(!/<@/.test(body(tst.posts[0]) + tst.posts[0].text), 'a [TEST] post tags nobody');

// identity: plain without chat:write.customize (today's bot), "Stamp Studio" + icon with it, plain if Slack cannot say
assert.ok(!('username' in one.posts[0]) && !('icon_url' in one.posts[0]), 'no custom name without the scope');
assert.strictEqual(one.body.as_app, false);
const asApp = await run([sheet('836624')], { scopes: 'chat:write, chat:write.customize,incoming-webhook' });
assert.strictEqual(asApp.posts[0].username, 'Stamp Studio');
assert.ok(asApp.posts[0].icon_url.endsWith('/_brand/favicons/stamp-studio/icon-512.png'), asApp.posts[0].icon_url);
assert.strictEqual(asApp.body.as_app, true);
for (const sc of [null, 'THROW']) {
  const plain = await run([sheet('836624')], { scopes: sc });
  assert.strictEqual(plain.posts.length, 1, 'an unreadable scope list still posts');
  assert.ok(!('username' in plain.posts[0]), `no custom name when the scopes are unknown (${sc})`);
}
const noTok = await run([sheet('836624')], { env: {} });
assert.strictEqual(noTok.status, 500); assert.strictEqual(noTok.posts.length, 0);

// check_bot: who the bot is and what it may do, posts nothing, needs no open sheet
const who = await run([], { body: { check_bot: true }, scopes: 'chat:write,chat:write.customize' });
assert.strictEqual(who.posts.length, 0, 'check_bot must not post');
assert.strictEqual(who.body.bot, 'unclogme_apps');
assert.deepStrictEqual(who.body.scopes, ['chat:write', 'chat:write.customize']);
assert.strictEqual(who.body.posts_as_app, true);

// ---- the run record: ONE public.sync_log row per real run (audit 2026-10-12, P3) ----
const oneLog = (r) => { assert.strictEqual(r.logs.length, 1, 'exactly one sync_log row'); return r.logs[0]; };
const l1 = oneLog(one);
assert.strictEqual(l1.method, 'POST');
assert.strictEqual(l1.headers.apikey, 'svc'); assert.strictEqual(l1.headers.Authorization, 'Bearer svc');
assert.strictEqual(l1.headers['Content-Type'], 'application/json', 'PostgREST refuses a POST without it');
assert.strictEqual(l1.headers.Prefer, 'return=minimal');
assert.strictEqual(l1.row.sync_source, 'stamp_sheets_reminder');
assert.strictEqual(l1.row.status, 'success'); assert.strictEqual(l1.row.rows_errored, 0); assert.strictEqual(l1.row.error_details, null);
assert.ok(Date.parse(l1.row.started_at) <= Date.parse(l1.row.finished_at), 'started before finished');
assert.deepStrictEqual(l1.row.details, { posted: true, reason: 'posted', slack_ts: '1.2', manifests: ['836624'], counts: { sheets: 1 }, test: false });
assert.strictEqual(one.body.sync_log_error, null);
assert.deepStrictEqual(oneLog(many).row.details.manifests.length, 45, 'every open sheet is recorded, not only the 40 shown');

const lNone = oneLog(none);
assert.strictEqual(lNone.row.status, 'success', 'every sheet completed is a successful run');
assert.deepStrictEqual(lNone.row.details, { posted: false, reason: 'every sheet is completed', manifests: [], counts: { sheets: 0 }, test: false });

const lRef = oneLog(refused);
assert.strictEqual(lRef.row.status, 'error'); assert.strictEqual(lRef.row.rows_errored, 1);
assert.match(lRef.row.details.error, /not_in_channel/); assert.deepStrictEqual(lRef.row.details.manifests, ['836624']);
assert.match(lRef.row.error_details.message, /^The Stamp Studio Slack reminder did not post: Slack refused the post \(slack: not_in_channel\)$/);
const lTok = oneLog(noTok);
assert.strictEqual(lTok.row.status, 'error'); assert.match(lTok.row.details.error, /SLACK_BOT_TOKEN/);
const readFail = await run({ message: 'boom' }, { rpcStatus: 500 });
assert.strictEqual(readFail.status, 500); assert.strictEqual(readFail.posts.length, 0);
assert.strictEqual(oneLog(readFail).row.status, 'error'); assert.match(oneLog(readFail).row.details.error, /HTTP 500/);
const notList = await run({ message: 'boom' });
assert.strictEqual(notList.status, 500); assert.strictEqual(oneLog(notList).row.details.error, 'open sheets: not a list');
assert.strictEqual(oneLog(tst).row.details.test, true, 'a [TEST] run is marked test');
assert.strictEqual(oneLog(tst).row.sync_source, 'stamp_sheets_reminder_test', 'a [TEST] run logs under its own source');
assert.strictEqual(oneLog(one).row.details.test, false);
assert.strictEqual(dry.logs.length, 0, 'a dry run writes no row');
assert.strictEqual(manyDry.logs.length, 0);
assert.strictEqual(anon.logs.length, 0, 'a refused caller writes no row');
assert.strictEqual(who.logs.length, 0, 'check_bot writes no row');

// the duration is measured, not a constant
const slow = await run([sheet('836624')], { delay: 60 });
assert.ok(oneLog(slow).row.duration_seconds >= 0.05, `duration ${oneLog(slow).row.duration_seconds}s covers a 60 ms read`);
assert.deepStrictEqual(oneLog(two).row.details.manifests, ['1', '2'], 'manifests in the order of the post');
const nullBody = await run([], { rawBody: 'null' });
assert.strictEqual(nullBody.status, 200, 'a JSON null body is treated as {}');
assert.strictEqual(oneLog(nullBody).row.sync_source, 'stamp_sheets_reminder');

// a thrown error still writes ONE 'error' row: Slack network error, RPC network error, a body that is not JSON,
// a null sheet; nothing is posted and the reply is a 500 that names the error
for (const [name, sheets, opts, msg] of [
  ['slack throws', [sheet('836624')], { slack: 'THROW' }, /slack network down/],
  ['rpc throws', 'THROW', {}, /rpc network down/],
  ['rpc not json', 'NOTJSON', {}, /JSON|Unexpected token/],
  ['null sheet', [null], {}, /TypeError|null/],
]) {
  const r = await run(sheets, opts);
  assert.strictEqual(r.status, 500, `${name}: 500`);
  assert.strictEqual(r.posts.length, 0, `${name}: nothing posted`);
  assert.strictEqual(r.body.posted, false);
  const row = oneLog(r).row;
  assert.strictEqual(row.status, 'error', `${name}: an error row`);
  assert.strictEqual(row.details.reason, 'the reminder stopped with an error');
  assert.match(row.details.error, msg, `${name}: ${row.details.error}`);
  assert.match(row.error_details.message, /^The Stamp Studio Slack reminder did not post: the reminder stopped with an error \(/);
}
assert.strictEqual(oneLog(await run('THROW', { body: { test: true } })).row.sync_source, 'stamp_sheets_reminder_test', 'a thrown [TEST] run logs as test');
const thrownDry = await run('THROW', { body: { dry_run: true } });
assert.strictEqual(thrownDry.status, 500); assert.strictEqual(thrownDry.logs.length, 0, 'a thrown dry run writes no row');

// a failed sync_log insert never fails the post
for (const mode of ['HTTP500', 'THROW']) {
  const r = await run([sheet('836624')], { syncLog: mode });
  assert.strictEqual(r.posts.length, 1, `posted although sync_log failed (${mode})`);
  assert.strictEqual(r.status, 200); assert.strictEqual(r.body.posted, true);
  assert.match(r.body.sync_log_error, mode === 'HTTP500' ? /^HTTP 500 / : /network down/);
  const n = await run([], { syncLog: mode });
  assert.strictEqual(n.status, 200); assert.strictEqual(n.body.reason, 'every sheet is completed');
  const th = await run('THROW', { syncLog: mode });
  assert.strictEqual(th.status, 500, 'a thrown run with a failing log is still a clean 500'); assert.ok(th.body.sync_log_error);
}

// the header comment states today's schedule (11 AM, 15:00 and 16:00 UTC), not the old 10 AM one
assert.ok(/once a day at 11 AM Eastern/.test(src) && /15:00 and 16:00[\s/]*UTC/.test(src), 'header says 11 AM, 15:00 and 16:00 UTC');
assert.ok(!/14:00 and 15:00/.test(src) && !/run that is 10 AM/.test(src), 'no stale 10 AM schedule in the header');
// ... and the run-record contract the health check relies on
for (const s of [/once a day whether or not a sheet is open/, /sync_source\s*\n?\/\/\s*'stamp_sheets_reminder'; \[TEST\] runs use 'stamp_sheets_reminder_test'/,
  /a thrown error still writes its row/, /test or fixture clients by public\.fn_is_non_customer/]) assert.match(src, s);
assert.ok(!/makes no call at all when nothing is open/.test(src), 'the old wrapper rule is gone from the header');

console.log('stamp_sheets_reminder: all checks passed');
