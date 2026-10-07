// admin_review_reminder.mjs - runs the REAL supabase/functions/admin-review-reminder/index.ts (types stripped by
// Node 22) against a stubbed database and a stubbed Slack, and asserts what is posted.
//   node scripts/checks/admin_review_reminder.mjs
// The rules (Fred, 2026-10-07): one post a day in #apps-notifications listing the visits that still need a city
// email (grouped by city, each with its photo state and a link to the visit in Admin Review) and how many visits have
// photos not sorted; nothing when nothing is waiting; header first; one-line phone text; names escaped; no em dash.
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

async function run(pending, { body = {}, role = 'service_role', slack = { ok: true, ts: '1.2' }, scopes = 'chat:write,chat:write.customize' } = {}) {
  const posts = [];
  let handler;
  const ctx = {
    Deno: { env: { get: (k) => ({ SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'svc', SLACK_BOT_TOKEN: 'xoxb' })[k] },
            serve: (h) => { handler = h; } },
    fetch: async (url, opts = {}) => {
      url = String(url);
      if (url.endsWith('/rest/v1/rpc/fn_admin_review_pending')) return Response.json(pending);
      if (url === 'https://slack.com/api/chat.postMessage') { posts.push(JSON.parse(opts.body)); return Response.json(slack); }
      if (url === 'https://slack.com/api/auth.test') return Response.json({ ok: true }, { headers: { 'x-oauth-scopes': scopes } });
      throw new Error('unexpected fetch ' + url);
    },
    Response, JSON, String, Number, Math, Date, Array, Error, atob, btoa, console, encodeURIComponent,
  };
  vm.runInNewContext(js, ctx);
  const res = await handler(new Request('https://fn', { method: 'POST', headers: { authorization: 'Bearer ' + jwt(role) }, body: JSON.stringify(body) }));
  return { status: res.status, body: await res.json(), posts };
}
const body = (p) => p.blocks.filter((b) => b.type === 'section').map((b) => b.text.text).join('\n');
const v = (id, city, o = {}) => ({ visit_id: id, client_code: '103-BWC', client_name: 'Barrel Wine & Cheese', city, visit_date: '2026-09-15', driver: 'Michael Escobar', photos_total: 13, photos_sorted: 13, ...o });
const photos = (count, last, oldest) => ({ count, last_7_days: last, oldest });

// nothing waiting: no post
const none = await run({ city: [], photos: photos(0, 0, null) });
assert.strictEqual(none.posts.length, 0, 'nothing waiting must post nothing');
assert.strictEqual(none.body.posted, false);

// the real shape of 2026-10-07
const real = await run({ city: [
  v(6275, 'Hallandale Beach'),
  v(8575, 'Hallandale Beach', { client_code: '283-PIK', client_name: 'Plug in Karaoke', visit_date: '2026-09-26', driver: 'Grecia', photos_total: 4, photos_sorted: 0 }),
  v(8133, 'Surfside', { client_code: '306-16', client_name: '16 Handles', visit_date: '2026-09-18' }),
  v(9001, 'Surfside', { client_code: '999-NP', client_name: 'No Photos', photos_total: 0, photos_sorted: 0, driver: null }),
], photos: photos(138, 18, '2026-07-01') });
assert.strictEqual(real.posts.length, 1);
const p0 = real.posts[0];
assert.strictEqual(p0.channel, 'C0BJYHQKZM1', '#apps-notifications');
assert.deepStrictEqual(p0.blocks[0], { type: 'header', text: { type: 'plain_text', text: '📸 Photos and city emails', emoji: true } });
assert.ok(p0.text.startsWith('📸 Admin Review: 4 visits still need a city email, 138 visits have photos not sorted\n'), p0.text);
assert.ok(p0.text.endsWith(body(p0)), 'text carries the whole list (Viktor reads only text)');
const b = body(p0);
assert.ok(b.startsWith('📸 *4 visits still need a city email · 138 visits have photos not sorted*'), b);
assert.ok(b.includes('🏙 *City email not sent (4):*\n*Hallandale Beach (2)*\n• <https://admin.unclogme.app/review/6275|103-BWC Barrel Wine &amp; Cheese> · Sep 15 · Michael Escobar · ✅ photos sorted'), b);
assert.ok(b.includes('• <https://admin.unclogme.app/review/8575|283-PIK Plug in Karaoke> · Sep 26 · Grecia · ❌ photos not sorted'), b);
assert.ok(b.includes('*Surfside (2)*\n• <https://admin.unclogme.app/review/8133|306-16 16 Handles> · Sep 18'), b);
assert.ok(b.includes('999-NP No Photos> · Sep 15 · driver not recorded · no photos'), b);
assert.ok(b.includes('🖼 *Photos not sorted: 138 visits* · 18 from the last 7 days · oldest Jul 1'), b);
assert.ok(!/—/.test(b + p0.text), 'no em dash');
assert.ok(!/<@/.test(b), 'no @-mention');
assert.strictEqual(p0.blocks.at(-1).type, 'context');
assert.ok(p0.blocks.at(-1).elements[0].text.includes('<https://admin.unclogme.app|Open Admin Review>'));
assert.strictEqual(p0.username, 'Admin Review');
assert.ok(p0.icon_url.endsWith('/_brand/favicons/admin-review/icon-512.png'), p0.icon_url);
assert.strictEqual(p0.unfurl_links, false);

// only one list waiting: the other is said out loud, and its section is left out
const onlyPhotos = await run({ city: [], photos: photos(1, 1, '2026-10-06') });
assert.ok(onlyPhotos.posts[0].text.startsWith('📸 Admin Review: every city email is sent, 1 visit has photos not sorted\n'));
assert.ok(!body(onlyPhotos.posts[0]).includes('City email not sent'));
const onlyCity = await run({ city: [v(1, 'Surfside')], photos: photos(0, 0, null) });
assert.ok(onlyCity.posts[0].text.startsWith('📸 Admin Review: 1 visit still needs a city email, every photo is sorted\n'));
assert.ok(!body(onlyCity.posts[0]).includes('Photos not sorted'));

// a long list is capped, split under Slack's limits, nothing lost before the cap
const many = await run({ city: Array.from({ length: 45 }, (_, i) => v(1000 + i, i < 20 ? 'Hallandale Beach' : 'Surfside')), photos: photos(5, 1, '2026-09-01') });
const mb = body(many.posts[0]);
assert.strictEqual((mb.match(/^• /gm) || []).length, 40);
assert.ok(mb.includes('…and 5 more in <https://admin.unclogme.app|Admin Review>.'));
assert.ok(mb.includes('*Surfside (25)*'), 'the city count is the whole city, not the shown lines');
for (const blk of many.posts[0].blocks) if (blk.type === 'section') assert.ok(blk.text.text.length <= 3000);

// dry run: the text, no post; test: [TEST] on both lines
const dry = await run({ city: [v(1, 'Surfside')], photos: photos(0, 0, null) }, { body: { dry_run: true } });
assert.strictEqual(dry.posts.length, 0);
assert.ok(dry.body.message.includes('review/1|'));
const tst = await run({ city: [v(1, 'Surfside')], photos: photos(0, 0, null) }, { body: { test: true } });
assert.ok(tst.posts[0].text.startsWith('📸 [TEST] Admin Review:'), tst.posts[0].text);
assert.ok(body(tst.posts[0]).startsWith('📸 [TEST] *'), body(tst.posts[0]));
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

console.log('admin_review_reminder: all checks passed');
