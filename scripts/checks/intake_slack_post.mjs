// Runs the REAL intake-slack-post function against a stubbed database and a stubbed Slack. Posts nothing.
//   node scripts/checks/intake_slack_post.mjs [path to index.ts]
// What the SQL returns is tested by the migration's VERIFY; a stub cannot test what the database returns.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';
import { edgeVmSource } from './edge_vm_source.mjs';

const path = process.argv[2] ?? new URL('../../supabase/functions/intake-slack-post/index.ts', import.meta.url);
const src = fs.readFileSync(path, 'utf8');
const js = edgeVmSource(src);
const jwt = (role) => 'h.' + Buffer.from(JSON.stringify({ role })).toString('base64') + '.s';

async function run(result, { body = { kind: 'form_back', id: 1125 }, role = 'service_role', slack = { ok: true, ts: '1.2' }, slackThrows = false, token = 'xoxb', claimFails = false } = {}) {
  const posts = [], patches = [], rpcs = [];
  let handler;
  const ctx = {
    Deno: { env: { get: (k) => ({ SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'svc', SLACK_BOT_TOKEN: token })[k] },
            serve: (h) => { handler = h; } },
    fetch: async (url, opts = {}) => {
      url = String(url);
      if (url.endsWith('/rest/v1/rpc/fn_slack_event_claim')) { rpcs.push(JSON.parse(opts.body)); return claimFails ? new Response('{}', { status: 500 }) : Response.json(result); }
      if (url.includes('/rest/v1/slack_event_posts?')) { patches.push({ url, body: JSON.parse(opts.body) }); return new Response(null, { status: 204 }); }
      if (url === 'https://slack.com/api/chat.postMessage') {
        if (slackThrows) throw new Error('connection dropped');
        posts.push(JSON.parse(opts.body)); return Response.json(slack);
      }
      if (url === 'https://slack.com/api/auth.test') return Response.json({ ok: true }, { headers: { 'x-oauth-scopes': 'chat:write,chat:write.customize' } });
      throw new Error('unexpected fetch ' + url);
    },
    Response, JSON, String, Number, Math, Date, Array, Error, atob, btoa, console, encodeURIComponent, Intl, AbortSignal,
  };
  vm.runInNewContext(js, ctx);
  const res = await handler(new Request('https://fn', { method: 'POST', headers: { authorization: 'Bearer ' + jwt(role) }, body: JSON.stringify(body) }));
  return { status: res.status, body: await res.json(), posts, patches, rpcs };
}
const allText = (p) => [p.text, ...p.blocks.map((b) => b.text.text)].join('\n');

const form = (o = {}) => ({ kind: 'form_back', ref_id: 1125, test: false, client_code: '901-MSB', client_name: 'Main Street Burger',
  address: '100 Sample Street', city: 'Miami', who: 'Michael Escobar', status: 'Incomplete',
  answered: 22, of: 23, photos: 5, ...o });
const version = (o = {}) => ({ kind: 'version_waiting', ref_id: 842, test: false, client_code: '901-MSB', client_name: 'Main Street Burger',
  address: '100 Sample Street', city: 'Miami', who: 'Dana', property_id: 162, version: 1,
  restored_from: null, live_version: null, ...o });

// a form comes back: one post, header first, the shared helper's shape, the right link, tags on the body line only
{
  const r = await run(form());
  assert.strictEqual(r.status, 200); assert.strictEqual(r.posts.length, 1);
  const p = r.posts[0];
  assert.strictEqual(p.channel, 'C0BJYHQKZM1');
  assert.strictEqual(p.blocks[0].type, 'header'); assert.strictEqual(p.blocks[0].text.text, '📨 Intake form back');
  assert.strictEqual(p.username, 'Picture Planner'); assert.match(p.icon_url, /picture-planner\/icon-512\.png$/);
  assert.strictEqual(p.unfurl_links, false); assert.strictEqual(p.unfurl_media, false);
  const body = p.blocks[1].text.text;
  assert.ok(body.includes('<https://planner.unclogme.app/forms/1125|901-MSB Main Street Burger>'));
  // Fred's pick, Option B, word for word: two lines
  assert.strictEqual(body, '📨 <@U0AL9JZ4V7C> <@U0BKM57UPSS> *<https://planner.unclogme.app/forms/1125|901-MSB Main Street Burger>*, 100 Sample Street, Miami\nMichael Escobar · Incomplete · 22 of 23 answered · 5 photos');
  assert.strictEqual(p.text, '📨 Intake form back: 901-MSB Main Street Burger, from Michael Escobar');
  assert.strictEqual(p.blocks[1].text.verbatim, true);
  assert.ok(!p.text.includes('<@'), 'the phone line carries no tag');
  assert.deepStrictEqual(r.patches[0].body.message_ts, '1.2'); assert.ok(r.patches[0].body.posted_at); assert.strictEqual(r.patches[0].body.error, null);
  assert.ok(r.patches[0].url.includes('event_kind=eq.form_back&ref_id=eq.1125'));
}
// a version waits: the Page Builder link, the form link, the maker is not tagged
{
  const r = await run(version({ who: 'Diego' }), { body: { kind: 'version_waiting', id: 842 } });
  const p = r.posts[0], body = p.blocks[1].text.text;
  assert.strictEqual(p.blocks[0].text.text, '📄 Site file waiting for approval');
  assert.strictEqual(body, '📄 <@U0BKM57UPSS> *<https://planner.unclogme.app/property/162|901-MSB Main Street Burger>*, 100 Sample Street, Miami\nDiego · version 1 · nothing live yet');
  assert.strictEqual(p.text, '📄 Site file waiting for approval: 901-MSB Main Street Burger, version 1, from Diego');
  assert.ok(!body.includes('U0AL9JZ4V7C'), 'the maker is not tagged');
  const r2 = await run(version({ live_version: 1, version: 2, restored_from: 1 }), { body: { kind: 'version_waiting', id: 842 } });
  assert.ok(r2.posts[0].blocks[1].text.text.endsWith('Dana · version 2 · version 1 is live · restored from version 1'));
  const r3 = await run(version({ who: 'Serena Natali' }), { body: { kind: 'version_waiting', id: 842 } });
  assert.ok(r3.posts[0].blocks[1].text.text.includes('U0AL9JZ4V7C') && !r3.posts[0].blocks[1].text.text.includes('U0BKM57UPSS'), 'Serena made it: only Diego is tagged');
}
// a second delivery, a test client without post_test, a form not found: no post and no row written
for (const skip of ['already_claimed', 'test_client', 'not_found']) {
  const r = await run({ skip });
  assert.strictEqual(r.status, 200); assert.strictEqual(r.posts.length, 0); assert.strictEqual(r.patches.length, 0); assert.strictEqual(r.body.reason, skip);
}
// Slack refuses, Slack is unreachable, no token: 200, no retry, the reason on the row, posted_at empty
{
  const a = await run(form(), { slack: { ok: false, error: 'channel_not_found' } });
  assert.strictEqual(a.status, 200); assert.strictEqual(a.posts.length, 1); assert.strictEqual(a.patches[0].body.posted_at, null);
  assert.strictEqual(a.patches[0].body.error, 'Slack: channel_not_found');
  const b = await run(form(), { slackThrows: true });
  assert.strictEqual(b.status, 200); assert.strictEqual(b.patches[0].body.posted_at, null); assert.ok(b.patches[0].body.error.includes('connection dropped'));
  const c = await run(form(), { token: '' });
  assert.strictEqual(c.status, 200); assert.strictEqual(c.patches[0].body.posted_at, null);
}
// a claim the database refuses: 200, nothing posted (the health item lists it)
{
  const r = await run(form(), { claimFails: true });
  assert.strictEqual(r.status, 200); assert.strictEqual(r.posts.length, 0); assert.strictEqual(r.body.reason, 'claim failed');
}
// [TEST] on the main line and the phone line, never in the header, no tags
{
  const r = await run(form({ test: true }), { body: { kind: 'form_back', id: 1125, post_test: true } });
  const p = r.posts[0];
  assert.ok(p.blocks[1].text.text.includes('[TEST] ')); assert.ok(p.text.includes('[TEST] ')); assert.ok(!p.blocks[0].text.text.includes('TEST'));
  assert.ok(!allText(p).includes('<@'));
  assert.strictEqual(r.rpcs[0].p_post_test, true);
}
// a dry run returns the message and writes nothing
{
  const r = await run(form(), { body: { kind: 'form_back', id: 1125, dry_run: true } });
  assert.strictEqual(r.posts.length, 0); assert.strictEqual(r.patches.length, 0); assert.strictEqual(r.rpcs[0].p_dry_run, true); assert.ok(r.body.message.includes('Michael Escobar'));
}
// only the server key; a bad body
{
  const r = await run(form(), { role: 'authenticated' });
  assert.strictEqual(r.status, 403); assert.strictEqual(r.posts.length, 0); assert.strictEqual(r.rpcs.length, 0);
  for (const body of [{ kind: 'nope', id: 1 }, { kind: 'form_back' }, { kind: 'form_back', id: -1 }]) assert.strictEqual((await run(form(), { body })).status, 400);
}
// 🛑 what a person types or a record holds stays text: a typed name cannot ping the channel
{
  const r = await run(form({ who: '<!channel> Pat & <http://evil|click>', client_name: 'Burger & Co' }));
  const t = allText(r.posts[0]);
  assert.ok(!t.includes('<!channel>')); assert.ok(!t.includes('<http://evil')); assert.ok(t.includes('&lt;!channel&gt; Pat &amp;')); assert.ok(t.includes('Burger &amp; Co'));
  // a line break cannot forge a line, and sections are verbatim so a bare @here or URL is not parsed
  const n = await run(form({ who: 'Pat\nComplete · 23 of 23 answered', address: '1 Main\nSt' }));
  const b = n.posts[0].blocks[1].text;
  assert.strictEqual(b.text.split('\n').length, 2); assert.ok(b.text.includes('1 Main St')); assert.ok(b.text.includes('Pat Complete · 23 of 23 answered · Incomplete'));
  assert.strictEqual(b.verbatim, true);
  assert.ok(!n.posts[0].blocks[0].text.verbatim, 'a header is plain_text and has no verbatim');
}
// 🛑 a post never carries a code: even if the row brought extra keys, the message is built from named keys only
{
  const planted = 'PLANTED-7391';
  const r = await run(form({ token: planted, answers: { lock_box: planted }, content: { gate_code: planted }, source: { lock_box_key: planted }, lock_box_key: planted }));
  assert.ok(!JSON.stringify(r.posts[0]).includes(planted));
  const v = await run(version({ content: { gate_code: planted }, source: { lock_box_key: planted } }), { body: { kind: 'version_waiting', id: 842 } });
  assert.ok(!JSON.stringify(v.posts[0]).includes(planted));
  assert.ok(!/\/intake|#code=|\/driver/.test(JSON.stringify(r.posts[0])), 'no intake or Site file link code in a link');
}
// never silently missing; no em dash, no en dash, nothing over Slack's limits
{
  const r = await run(form({ address: null, city: null, status: null, who: null, photos: 1 }));
  const t = allText(r.posts[0]);
  assert.ok(t.includes('Main Street Burger>*\nsomeone · not read · 22 of 23 answered · 1 photo')); assert.ok(!t.includes('1 photos'));
  // a count that could not be read is left out, never printed as 0 (the guide's rule 5)
  const u = await run(form({ answered: null }));
  assert.ok(u.posts[0].blocks[1].text.text.endsWith('Michael Escobar · Incomplete'));
  for (const f of [form(), version()]) {
    const p = (await run(f, { body: { kind: f.kind, id: 1 } })).posts[0];
    assert.ok(!/[\u2013\u2014]/.test(allText(p)));
    assert.ok(p.blocks[0].text.text.length <= 150); assert.ok(p.blocks.length <= 50);
    for (const b of p.blocks.slice(1)) assert.ok(b.text.text.length <= 3000);
  }
}
console.log('intake_slack_post: all checks passed');
