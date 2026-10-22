// unopened_email_reminder.mjs - runs the REAL supabase/functions/unopened-email-reminder/index.ts (types stripped by
// Node 22) against a stubbed database and a stubbed Slack, and asserts what is posted.
//   node scripts/checks/unopened_email_reminder.mjs
// The rules (Yan + Fred, 2026-10-20, Trello xMtqH9Xw): Monday, Wednesday and Friday in #apps-notifications; header
// "📭 Emails not opened"; Diego tagged on the first body line (never on a [TEST]); a "Not delivered" section first when
// any bounced; then the unopened ones grouped by city (Layout 1), client emails last, oldest first; each line links the
// visit in the app that sent the email; a fast open is named; one-line phone text then the whole message (Viktor);
// names escaped; no em dash; nothing posted when nothing is listed; one sync_log row per run that is not a dry run,
// also on a day it does not post.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';
import { stripTypeScriptTypes } from 'node:module';

const src = fs.readFileSync(new URL('../../supabase/functions/unopened-email-reminder/index.ts', import.meta.url), 'utf8');
const helper = fs.readFileSync(new URL('../../supabase/functions/_shared/slack-notify.ts', import.meta.url), 'utf8');
const IMPORT = 'import { slackHeader, slackIdentity, slackSections } from "../_shared/slack-notify.ts";';
assert.ok(src.includes(IMPORT), 'the function imports the shared helpers');
const js = [stripTypeScriptTypes(helper).replace(/^export /gm, ''), stripTypeScriptTypes(src.replace(IMPORT, ''))].join('\n');
const jwt = (role) => 'h.' + Buffer.from(JSON.stringify({ role })).toString('base64') + '.s';

// Wed Oct 21 2026, 11:00 ET = 15:00Z; Tue Oct 20 = not a posting day
const WED = '2026-10-21T15:00:00Z', TUE = '2026-10-20T15:00:00Z';

async function run(list, { body = { as_of: WED }, role = 'service_role', slack = { ok: true, ts: '1.2' }, scopes = 'chat:write,chat:write.customize', env = { SLACK_BOT_TOKEN: 'xoxb' } } = {}) {
  const posts = [], logs = [], rpc = [];
  let handler;
  const ctx = {
    Deno: { env: { get: (k) => ({ SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'svc', ...env })[k] },
            serve: (h) => { handler = h; } },
    fetch: async (url, opts = {}) => {
      url = String(url);
      if (url.endsWith('/rest/v1/rpc/fn_unopened_emails')) {
        rpc.push(JSON.parse(opts.body));
        if (list === 'THROW') throw new Error('rpc network down');
        if (list === 'HTTP500') return new Response('{"message":"boom"}', { status: 500 });
        return Response.json(list);
      }
      if (url === 'https://slack.com/api/chat.postMessage') { posts.push(JSON.parse(opts.body)); return Response.json(slack); }
      if (url === 'https://slack.com/api/auth.test') return Response.json({ ok: true }, { headers: { 'x-oauth-scopes': scopes } });
      if (url === 'https://x.supabase.co/rest/v1/sync_log') { logs.push(JSON.parse(opts.body)); return new Response(null, { status: 201 }); }
      throw new Error('unexpected fetch ' + url);
    },
    Response, Request, JSON, String, Number, Math, Date, Array, Map, Set, Error, Intl, atob, btoa, console, encodeURIComponent,
  };
  vm.runInNewContext(js, ctx);
  const res = await handler(new Request('https://fn', { method: 'POST', headers: { authorization: 'Bearer ' + jwt(role) }, body: JSON.stringify(body) }));
  return { status: res.status, body: await res.json(), posts, logs, rpc };
}
const body = (p) => p.blocks.filter((b) => b.type === 'section').map((b) => b.text.text).join('\n');
const e = (o) => ({
  section: 'not_opened', target: 'city', source_table: 'visit_photo_email_sends', send_id: 1, resend_email_id: 'r',
  client_code: '067-TCE', client_name: 'The carrot express Central kitchen', city: 'Hallandale Beach', visit_id: 6139,
  visit_date: '2026-10-19', app: 'admin_review', kind: 'job report', via: 'admin_review', sent_by_name: 'Diego',
  sent_at: '2026-10-20T13:34:00Z', delivery_status: 'delivered', open_gap_seconds: null, open_unknown_reason: null,
  to_count: 2, delivered_count: 2, refused_count: 0, bounce_reason: null, ...o,
});
let n = 0; const ok = (m) => { n++; console.log('  ok  ' + m); };

// 1. the real shape: two cities, a client email, a bounce, a fast open, a pre-D5 email, an automatic send
const list = { emails: [
  e({ send_id: 403, open_unknown_reason: 'archive_copy', delivery_status: 'delivered_open_unknown' }),
  e({ send_id: 2, source_table: 'derm_email_sends', app: 'derm_tracker', kind: 'manifest', client_code: '106-ALC',
      client_name: 'A la Carte', visit_id: 6284, visit_date: '2026-10-07', sent_at: '2026-10-20T15:24:00Z', via: 'automatic', sent_by_name: null }),
  e({ send_id: 3, city: 'Surfside', client_code: '103-BWC', client_name: 'Barrel Wine & Cheese', visit_id: 6275,
      visit_date: '2026-10-16', delivery_status: 'opened', open_gap_seconds: 8, sent_at: '2026-10-19T14:00:00Z' }),
  e({ send_id: 4, target: 'client', city: null, source_table: 'derm_email_sends', app: 'derm_tracker', kind: 'report to the client',
      client_code: '059-SK', client_name: 'Street Kitchen', visit_id: 6087, visit_date: '2026-10-06', sent_by_name: null, via: 'derm_tracker' }),
  e({ send_id: 5, section: 'not_delivered', city: 'Surfside', source_table: 'derm_email_sends', app: 'derm_tracker', kind: 'manifest',
      client_code: '091-SB', client_name: 'Street Bar', visit_id: 6253, visit_date: '2026-10-15', delivery_status: 'not_delivered',
      bounce_reason: 'mailbox full', refused_count: 2, delivered_count: 0 }),
] };
const real = await run(list);
assert.strictEqual(real.status, 200);
assert.deepStrictEqual(real.rpc[0], { p_as_of: '2026-10-21T15:00:00.000Z' }, 'the list is read as of the run');
assert.strictEqual(real.posts.length, 1);
const p = real.posts[0];
assert.strictEqual(p.channel, 'C0BJYHQKZM1');
assert.deepStrictEqual(p.blocks[0], { type: 'header', text: { type: 'plain_text', text: '📭 Emails not opened', emoji: true } });
const b = body(p);
assert.strictEqual(b, [
  '⚠️ <@U0AL9JZ4V7C> *Not delivered (1):*',
  '• <https://derm.unclogme.app/visits/6253|091-SB Street Bar> · Surfside · manifest, visit Oct 15 · sent Tue, Oct 20 by Diego: the city\'s email system refused it (mailbox full)',
  'Check the city email on the property in the Client App, then send it again.',
  '',
  '📭 *4 emails were delivered and nobody is confirmed to have opened them*',
  'ℹ️ No open recorded is not proof it was unread (many email systems block the picture that records an open), so call to confirm they have it.',
  '',
  '🏙 *Hallandale Beach (2):*',
  '• <https://admin.unclogme.app/review/6139|067-TCE The carrot express Central kitchen> · job report, visit Oct 19 · sent Tue, Oct 20 by Diego · opens cannot be seen on this one',
  '• <https://derm.unclogme.app/visits/6284|106-ALC A la Carte> · manifest, visit Oct 7 · sent automatically Tue, Oct 20',
  '',
  '🏙 *Surfside (1):*',
  '• <https://admin.unclogme.app/review/6275|103-BWC Barrel Wine &amp; Cheese> · job report, visit Oct 16 · sent Mon, Oct 19 by Diego · opened 8 s after it arrived, most likely by their email system',
  '',
  '👤 *Client emails (1):*',
  '• <https://derm.unclogme.app/visits/6087|059-SK Street Kitchen> · report to the client, visit Oct 6 · sent Tue, Oct 20, sender not recorded',
].join('\n'), b);
assert.ok(p.text.startsWith('📭 DERM Tracker: 4 emails delivered but not confirmed opened, 1 email not delivered\n\n'), p.text);
assert.ok(p.text.endsWith(b), 'text carries the whole message (Viktor reads only text)');
assert.ok(!/—/.test(b + p.text), 'no em dash');
assert.strictEqual((b.match(/<@/g) || []).length, 1, 'Diego tagged once');
assert.strictEqual(p.username, 'DERM Tracker');
assert.ok(p.icon_url.endsWith('/_brand/favicons/derm-tracker/icon-512.png'));
assert.ok(p.blocks.at(-1).elements[0].text.includes('<https://admin.unclogme.app|Open Admin Review>'));
assert.strictEqual(p.unfurl_links, false);
ok('the post: header, bounce first, cities then clients, links, fast open and pre-D5 notes, phone text, Diego once');
assert.strictEqual(real.logs.length, 1);
assert.strictEqual(real.logs[0].sync_source, 'unopened_email_reminder');
assert.strictEqual(real.logs[0].status, 'success');
assert.deepStrictEqual(real.logs[0].details.counts, { not_opened: 4, not_delivered: 1 });
assert.strictEqual(real.logs[0].details.emails.length, 5);
assert.strictEqual(real.logs[0].details.day, 'Wed');
ok('one success run record with every listed email');

// 2. only unopened city emails (Fred, 2026-10-22, Trello 5RpYsa98: 12 real city deliveries, 0 opens ever recorded, so
//    the list is a call list and says so): Diego moves to the unopened line; singular and plural wording
const one = await run({ emails: [e({})] });
assert.ok(body(one.posts[0]).startsWith('📭 <@U0AL9JZ4V7C> *1 city email delivered, the city\'s email system does not report when it is read*\nℹ️ Call to confirm they have it.\n'), body(one.posts[0]));
assert.ok(one.posts[0].text.startsWith('📭 DERM Tracker: 1 city email delivered, call to confirm\n'), one.posts[0].text);
const two = await run({ emails: [e({}), e({ send_id: 9, city: 'Surfside' })] });
assert.ok(body(two.posts[0]).startsWith('📭 <@U0AL9JZ4V7C> *2 city emails delivered, the cities\' email systems do not report when they are read*\nℹ️ Call to confirm they have them.\n'), body(two.posts[0]));
assert.ok(two.posts[0].text.startsWith('📭 DERM Tracker: 2 city emails delivered, call to confirm\n'), two.posts[0].text);
ok('only city emails: a call list, tag on the first line, singular and plural wording');

// 3. nothing listed: no post, a success record
const none = await run({ emails: [] });
assert.strictEqual(none.posts.length, 0); assert.strictEqual(none.logs[0].status, 'success');
assert.strictEqual(none.logs[0].details.reason, 'nothing to report');
ok('nothing listed: no post, run recorded');

// 4. not a posting day: no list read, no post, a success record (the health check needs one a day)
const tue = await run(list, { body: { as_of: TUE } });
assert.strictEqual(tue.posts.length, 0); assert.strictEqual(tue.rpc.length, 0);
assert.strictEqual(tue.logs[0].status, 'success'); assert.strictEqual(tue.logs[0].details.reason, 'not a posting day');
assert.strictEqual(tue.logs[0].details.day, 'Tue');
for (const [iso, d] of [['2026-10-23T15:00:00Z', 'Fri'], ['2026-10-26T15:00:00Z', 'Mon']]) {
  const r = await run(list, { body: { as_of: iso } });
  assert.strictEqual(r.posts.length, 1, d + ' posts'); assert.strictEqual(r.logs[0].details.day, d);
}
for (const iso of ['2026-10-24T15:00:00Z', '2026-10-25T15:00:00Z', '2026-10-22T15:00:00Z']) {
  assert.strictEqual((await run(list, { body: { as_of: iso } })).posts.length, 0, iso + ' must not post');
}
// 11 AM ET on a Wednesday is still Wednesday in New York even when UTC has moved on (a late-evening check)
assert.strictEqual((await run(list, { body: { as_of: '2026-10-22T03:30:00Z' } })).logs[0].details.day, 'Wed');
ok('posts Mon, Wed, Fri (New York days) only; other days record "not a posting day"');

// 5. dry run: the text, no post, no record; test: [TEST], nobody tagged, own source, any day
const dry = await run(list, { body: { dry_run: true, as_of: TUE } });
assert.strictEqual(dry.posts.length, 0); assert.strictEqual(dry.logs.length, 0);
assert.ok(dry.body.text.startsWith('📭 DERM Tracker:'));
const tst = await run(list, { body: { test: true, as_of: TUE } });
assert.strictEqual(tst.posts.length, 1);
assert.ok(tst.posts[0].text.startsWith('📭 [TEST] DERM Tracker:'), tst.posts[0].text);
const tb = body(tst.posts[0]);
assert.ok(tb.startsWith('⚠️ [TEST] *Not delivered (1):*'), tb);
assert.ok(tb.includes('📭 [TEST] *4 emails were delivered'), tb);
assert.ok(!/<@/.test(tb + tst.posts[0].text), 'a [TEST] post tags nobody');
assert.strictEqual(tst.logs[0].sync_source, 'unopened_email_reminder_test');
assert.ok(!/TEST/.test(p.text + b), 'a normal post carries no TEST mark');
ok('dry run and [TEST] behave');

// 6. a long list is capped at 40 lines and split under Slack's limits
const many = await run({ emails: Array.from({ length: 45 }, (_, i) => e({ send_id: 100 + i, city: i < 20 ? 'Hallandale Beach' : 'Surfside' })) });
const mb = body(many.posts[0]);
assert.strictEqual((mb.match(/^• /gm) || []).length, 40);
assert.ok(mb.includes('…and 5 more in the apps.'));
for (const blk of many.posts[0].blocks) if (blk.type === 'section') assert.ok(blk.text.text.length <= 3000);
assert.strictEqual(many.logs[0].details.emails.length, 45, 'all 45 recorded, not the 40 shown');
ok('long list capped and split, every email recorded');

// 7. refusals: Slack says no -> 502 + error record; not service_role -> 403; broken list -> 500; no token -> 500
const refused = await run(list, { slack: { ok: false, error: 'not_in_channel' } });
assert.strictEqual(refused.status, 502); assert.strictEqual(refused.logs[0].status, 'error');
assert.match(refused.logs[0].error_details.message, /Slack refused the post \(slack: not_in_channel\)/);
assert.strictEqual((await run(list, { role: 'authenticated' })).status, 403);
const broken = await run({ message: 'boom' });
assert.strictEqual(broken.status, 500); assert.strictEqual(broken.posts.length, 0); assert.match(broken.logs[0].details.error, /unexpected shape/);
assert.strictEqual((await run('HTTP500')).status, 500);
const thrown = await run('THROW');
assert.strictEqual(thrown.status, 500); assert.strictEqual(thrown.logs[0].status, 'error');
const noTok = await run(list, { env: {} });
assert.strictEqual(noTok.status, 500); assert.match(noTok.logs[0].details.error, /SLACK_BOT_TOKEN/);
const plain = await run(list, { scopes: 'chat:write' });
assert.ok(!('username' in plain.posts[0]), 'no custom name without chat:write.customize');
ok('refusals and errors are recorded, nothing posted');

console.log(`unopened_email_reminder: ${n} checks passed`);
