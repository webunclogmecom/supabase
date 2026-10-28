// call_first_reminder.mjs - runs the REAL supabase/functions/call-first-reminder/index.ts (types stripped by Node 22)
// against a stubbed database and a stubbed Slack, and asserts what is posted.
//   node scripts/checks/call_first_reminder.mjs
// The rules under test (Fred, 2026-10-18, design 2026-08-17): post the clients to call for approval before scheduling,
// once each (the SQL marks them announced); post NOTHING when there is nothing to announce; a dry run and a test change
// nothing (they call the run with p_dry_run=true); Diego is tagged, never on a test; every post starts with the header;
// a filer error reaches the post in plain words; every non-dry run writes one sync_log row. What the SQL lists is tested
// by the migration's VERIFY (2026-10-18_0245); a stub cannot test what the database returns.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';
import { edgeVmSource } from './edge_vm_source.mjs';

const src = fs.readFileSync(new URL('../../supabase/functions/call-first-reminder/index.ts', import.meta.url), 'utf8');
const IMPORT = 'import { slackHeader, slackIdentity, slackSections } from "../_shared/slack-notify.ts";';
assert.ok(src.includes(IMPORT), 'the function imports the shared Slack helper');
const js = edgeVmSource(src);
const jwt = (role) => 'h.' + Buffer.from(JSON.stringify({ role })).toString('base64') + '.s';

async function run(result, { body = {}, role = 'service_role', slack = { ok: true, ts: '1.2' } } = {}) {
  const posts = [], logs = [], rpcBodies = [];
  let handler;
  const ctx = {
    Deno: { env: { get: (k) => ({ SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'svc', SLACK_BOT_TOKEN: 'xoxb' })[k] },
            serve: (h) => { handler = h; } },
    fetch: async (url, opts = {}) => {
      url = String(url);
      if (url.endsWith('/rest/v1/rpc/fn_call_first_run')) {
        rpcBodies.push({ body: JSON.parse(opts.body), profile: opts.headers['Content-Profile'] });
        return Response.json(result);
      }
      if (url === 'https://x.supabase.co/rest/v1/sync_log') { logs.push(JSON.parse(opts.body)); return new Response(null, { status: 201 }); }
      if (url === 'https://slack.com/api/chat.postMessage') { posts.push(JSON.parse(opts.body)); return Response.json(slack); }
      if (url === 'https://slack.com/api/auth.test') return Response.json({ ok: true }, { headers: { 'x-oauth-scopes': 'chat:write' } });
      throw new Error('unexpected fetch ' + url);
    },
    Response, JSON, String, Number, Math, Date, Array, Error, atob, btoa, console, encodeURIComponent,
  };
  vm.runInNewContext(js, ctx);
  const res = await handler(new Request('https://fn', { method: 'POST', headers: { authorization: 'Bearer ' + jwt(role) }, body: JSON.stringify(body) }));
  return { status: res.status, body: await res.json(), posts, logs, rpcBodies };
}
const text = (p) => p.blocks.slice(1).map((b) => b.text.text).join('\n');
const item = (o = {}) => ({ request_id: 67, client_code: '226-JER', client_name: 'Jerusalem Pizza', call_due_at: '2026-10-16',
  last_completed_date: '2026-08-17', cadence_days: 60, gdo_number: 'GDO-03256', permit_max_days: 60,
  cadence_exceeds_permit: false, new: true, filed_at: '2026-10-18T07:00:00Z', ...o });
const res = (items, o = {}) => ({ dry_run: false, weekly: false, items, filer: { errors: [] }, ...o });

// nothing to announce: no post, a run record
const none = await run(res([]));
assert.strictEqual(none.posts.length, 0);
assert.strictEqual(none.logs.length, 1);
assert.strictEqual(none.logs[0].details.reason, 'nothing to announce');
assert.strictEqual(none.rpcBodies[0].profile, 'ops');
assert.deepStrictEqual(none.rpcBodies[0].body, { p_dry_run: false }, 'a real run files and marks announced');

// one client: header, Diego tagged, the line, the how-to line, phone text
const one = await run(res([item()]));
assert.strictEqual(one.posts.length, 1);
const p = one.posts[0];
assert.strictEqual(p.channel, 'C0BJYHQKZM1');
assert.deepStrictEqual(p.blocks[0], { type: 'header', text: { type: 'plain_text', text: '📞 Calls before scheduling', emoji: true } });
assert.strictEqual(p.text, ':telephone_receiver: Visit Calendar: 1 client to call for approval before scheduling');
const t = text(p);
assert.match(t, /^:telephone_receiver: <@U0AL9JZ4V7C> \*1 client to call for approval before scheduling\*\n/);
assert.ok(t.includes('• <https://calendar.unclogme.app/|226-JER Jerusalem Pizza> · call due Oct 16 · last service Aug 17 · its permit allows 60 days'), t);
assert.ok(t.includes("*Schedule* it when they agree, or *Not now* with the date they gave"), t);
assert.ok(!/—/.test(t + p.text), 'no em dash');
assert.strictEqual(one.logs[0].details.posted, true);

// weekly digest line, cadence over the permit, escaping, two clients
const two = await run(res([item({ new: false, cadence_days: 90, cadence_exceeds_permit: true }), item({ client_code: '9<9', client_name: 'A & B' })], { weekly: true }));
const t2 = text(two.posts[0]);
assert.match(t2, /\*2 clients to call/);
assert.ok(t2.includes(':warning: called every 90 days, longer than the permit allows · waiting since Oct 18'), t2);
assert.ok(t2.includes('9&lt;9 A &amp; B'), t2);

// a filer error alone still posts, in plain words, and never shows the raw error
const err = await run(res([], { filer: { errors: [{ client: '226-JER', client_name: 'Jerusalem Pizza', error: 'create_visit_request: job 1623 is not an active job for client 463' }] } }));
assert.strictEqual(err.posts.length, 1);
assert.ok(text(err.posts[0]).includes(':warning: *226-JER Jerusalem Pizza*: its Service Call job is closed in Jobber'), text(err.posts[0]));
assert.ok(!text(err.posts[0]).includes('create_visit_request'), 'no technical words');

// dry run: changes nothing, posts nothing, writes no run record
const dry = await run(res([item()]), { body: { dry_run: true } });
assert.strictEqual(dry.posts.length, 0);
assert.strictEqual(dry.logs.length, 0);
assert.deepStrictEqual(dry.rpcBodies[0].body, { p_dry_run: true });
assert.ok(dry.body.message.includes('226-JER'));

// test: posts with [TEST], tags nobody, changes nothing, logs as _test
const tst = await run(res([item()]), { body: { test: true } });
assert.deepStrictEqual(tst.rpcBodies[0].body, { p_dry_run: true }, 'a test must not use up the real announcement');
assert.ok(text(tst.posts[0]).startsWith(':telephone_receiver: [TEST] *1 client'), text(tst.posts[0]));
assert.ok(!/<@/.test(text(tst.posts[0]) + tst.posts[0].text), 'a test tags nobody');
assert.strictEqual(tst.logs[0].sync_source, 'call_first_reminder_test');

// Slack refuses: reported; only service_role may call
const refused = await run(res([item()]), { slack: { ok: false, error: 'not_in_channel' } });
assert.strictEqual(refused.status, 502);
assert.strictEqual(refused.logs[0].status, 'error');
const anon = await run(res([item()]), { role: 'authenticated' });
assert.strictEqual(anon.status, 403);
assert.strictEqual(anon.posts.length + anon.logs.length, 0);

console.log('call_first_reminder: all checks passed');
