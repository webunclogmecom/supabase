// stamp_sheets_reminder.mjs - runs the REAL supabase/functions/stamp-sheets-reminder/index.ts (types
// stripped by Node 22) against a stubbed database and a stubbed Slack, and asserts what is posted.
//   node scripts/checks/stamp_sheets_reminder.mjs
// The rules under test (Fred, 2026-10-05): post the not-completed Stamp Studio sheets to
// #apps-notifications; post NOTHING when every sheet is completed; a dry run never posts.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';
import { stripTypeScriptTypes } from 'node:module';

const src = fs.readFileSync(new URL('../../supabase/functions/stamp-sheets-reminder/index.ts', import.meta.url), 'utf8');
const js = stripTypeScriptTypes(src);
const jwt = (role) => 'h.' + Buffer.from(JSON.stringify({ role })).toString('base64') + '.s';

async function run(sheets, { body = {}, role = 'service_role', slack = { ok: true, ts: '1.2' }, env = { SLACK_BOT_TOKEN: 'xoxb' } } = {}) {
  const posts = [], auths = [];
  let handler, rpcHeaders;
  const ctx = {
    Deno: { env: { get: (k) => ({ SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'svc', ...env })[k] },
            serve: (h) => { handler = h; } },
    fetch: async (url, opts = {}) => {
      url = String(url);
      if (url.endsWith('/rest/v1/rpc/fn_stamp_open_sheets')) { rpcHeaders = opts.headers; return Response.json(sheets); }
      if (url === 'https://slack.com/api/chat.postMessage') { posts.push(JSON.parse(opts.body)); auths.push(opts.headers.Authorization); return Response.json(slack); }
      if (url === 'https://slack.com/api/auth.test') { auths.push(opts.headers.Authorization); return Response.json({ ok: true, user: 'unclogme_apps', team: 'UnclogMe' }); }
      throw new Error('unexpected fetch ' + url);
    },
    Response, JSON, String, Number, Math, Date, Array, Error, atob, btoa, console, encodeURIComponent,
  };
  vm.runInNewContext(js, ctx);
  const res = await handler(new Request('https://fn', { method: 'POST', headers: { authorization: 'Bearer ' + jwt(role) }, body: JSON.stringify(body) }));
  return { status: res.status, body: await res.json(), posts, auths, rpcHeaders };
}

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
assert.match(one.posts[0].text, /^:memo: \*Stamp Studio: 1 sheet is not completed\*\n/);
assert.ok(one.posts[0].text.includes('• <https://stamp.unclogme.app/836624|Manifest 836624> · dumped Sep 21 · 4 of 9 stamped · In progress · waiting 14 days'), one.posts[0].text);
assert.strictEqual(one.body.posted, true);

// plural, no dump date (falls back to the service date), 1 day, 0 days (no "waiting"), not started
const two = await run([sheet('1', { dump_date: null, days_waiting: 1, placed: 0, status: 'Not started' }), sheet('2', { days_waiting: 0 })]);
assert.match(two.posts[0].text, /2 sheets are not completed/);
assert.ok(two.posts[0].text.includes('Manifest 1> · dumped Sep 20 · 0 of 9 stamped · Not started · waiting 1 day'), two.posts[0].text);
assert.ok(two.posts[0].text.split('\n')[2].endsWith('In progress'), 'no "waiting" on the day of the dump');
assert.ok(!/—/.test(two.posts[0].text), 'no em dash in the message');

// more than 40: capped with a pointer to the Studio
const many = await run(Array.from({ length: 45 }, (_, i) => sheet(String(900000 + i))));
const lines = many.posts[0].text.split('\n');
assert.strictEqual(lines.length, 1 + 40 + 1);
assert.ok(lines.at(-1).includes('and 5 more'), lines.at(-1));

// dry run: the text, no post
const dry = await run([sheet('836624')], { body: { dry_run: true } });
assert.strictEqual(dry.posts.length, 0, 'dry run must not post');
assert.ok(dry.body.text.includes('Manifest 836624'));

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
assert.ok(tst.posts[0].text.startsWith('[TEST] :memo: '), tst.posts[0].text);
assert.ok(!/TEST/.test(one.posts[0].text), 'a normal post carries no TEST mark');

// the bot: the app's own token when APPS_SLACK_BOT_TOKEN is set, else the shared Dump Visits one; always named
assert.strictEqual(one.body.bot_secret, 'SLACK_BOT_TOKEN');
const own = await run([sheet('836624')], { env: { SLACK_BOT_TOKEN: 'xoxb-dump', APPS_SLACK_BOT_TOKEN: 'xoxb-apps' } });
assert.deepStrictEqual(own.auths, ['Bearer xoxb-apps'], 'the app bot wins when its secret is set');
assert.strictEqual(own.body.bot_secret, 'APPS_SLACK_BOT_TOKEN');
const noTok = await run([sheet('836624')], { env: {} });
assert.strictEqual(noTok.status, 500); assert.strictEqual(noTok.posts.length, 0);

// check_bot: asks Slack who the bot is, posts nothing, needs no open sheet
const who = await run([], { body: { check_bot: true }, env: { SLACK_BOT_TOKEN: 'xoxb-dump', APPS_SLACK_BOT_TOKEN: 'xoxb-apps' } });
assert.strictEqual(who.posts.length, 0, 'check_bot must not post');
assert.deepStrictEqual(who.auths, ['Bearer xoxb-apps']);
assert.strictEqual(who.body.bot_secret, 'APPS_SLACK_BOT_TOKEN'); assert.strictEqual(who.body.bot, 'unclogme_apps');

console.log('stamp_sheets_reminder: all checks passed');
