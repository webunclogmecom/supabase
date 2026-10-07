// stamp_sheets_reminder.mjs - runs the REAL supabase/functions/stamp-sheets-reminder/index.ts (types
// stripped by Node 22) against a stubbed database and a stubbed Slack, and asserts what is posted.
//   node scripts/checks/stamp_sheets_reminder.mjs
// The rules under test (Fred, 2026-10-05): post the not-completed Stamp Studio sheets to
// #apps-notifications; post NOTHING when every sheet is completed; a dry run never posts; on the shared bot the
// post shows as "Stamp Studio" ONLY when the bot holds chat:write.customize; every post starts with the header block
// (Option A) and its sections rebuild the message under Slack's limits (the real _shared/slack-notify.ts is inlined,
// so its scope gate, header and section split are what is tested).
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

async function run(sheets, { body = {}, role = 'service_role', slack = { ok: true, ts: '1.2' }, env = { SLACK_BOT_TOKEN: 'xoxb' }, scopes = 'chat:write,incoming-webhook' } = {}) {
  const posts = [], auths = [];
  let handler, rpcHeaders;
  const ctx = {
    Deno: { env: { get: (k) => ({ SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'svc', ...env })[k] },
            serve: (h) => { handler = h; } },
    fetch: async (url, opts = {}) => {
      url = String(url);
      if (url.endsWith('/rest/v1/rpc/fn_stamp_open_sheets')) { rpcHeaders = opts.headers; return Response.json(sheets); }
      if (url === 'https://slack.com/api/chat.postMessage') { posts.push(JSON.parse(opts.body)); auths.push(opts.headers.Authorization); return Response.json(slack); }
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
  const res = await handler(new Request('https://fn', { method: 'POST', headers: { authorization: 'Bearer ' + jwt(role) }, body: JSON.stringify(body) }));
  return { status: res.status, body: await res.json(), posts, auths, rpcHeaders };
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
assert.match(body(one.posts[0]), /^:memo: \*1 sheet is not completed\*\n/);
assert.ok(body(one.posts[0]).includes('• <https://stamp.unclogme.app/836624|Manifest 836624> · dumped Sep 21 · 4 of 9 stamped · In progress · waiting 14 days'), body(one.posts[0]));
assert.strictEqual(one.body.posted, true);

// plural, no dump date (falls back to the service date), 1 day, 0 days (no "waiting"), not started
const two = await run([sheet('1', { dump_date: null, days_waiting: 1, placed: 0, status: 'Not started' }), sheet('2', { days_waiting: 0 })]);
assert.match(two.posts[0].text, /2 sheets are not completed/);
assert.ok(body(two.posts[0]).includes('Manifest 1> · dumped Sep 20 · 0 of 9 stamped · Not started · waiting 1 day'), body(two.posts[0]));
assert.ok(body(two.posts[0]).split('\n')[2].endsWith('In progress'), 'no "waiting" on the day of the dump');
assert.ok(!/—/.test(body(two.posts[0]) + two.posts[0].text), 'no em dash in the message');

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

console.log('stamp_sheets_reminder: all checks passed');
