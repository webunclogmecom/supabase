// samsara_client.test.js: retries, give-up and paging of the shared Samsara GET (no network).
//   node scripts/lib/samsara_client.test.js
const assert = require('assert');
const { samsaraClient } = require('./samsara_client');

const json = (status, body, headers = {}) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...headers } });
function make(answers) {               // answers: one per call, a Response factory or an Error to throw
  const calls = [], sleeps = [];
  const fetch = async (url, o) => {
    calls.push({ url, auth: o.headers.Authorization, hasSignal: !!o.signal });
    const a = answers[Math.min(calls.length - 1, answers.length - 1)];
    if (a instanceof Error) throw a;
    return a();
  };
  return { c: samsaraClient({ fetch, sleep: async ms => { sleeps.push(ms); }, token: () => 'tok' }), calls, sleeps };
}
let n = 0;
const eq = (a, b, m) => { assert.deepStrictEqual(a, b, m); n++; };
const rejects = async (p, re, m) => { await assert.rejects(p, re, m); n++; };

(async () => {
  let t = make([() => json(200, { ok: 1 })]);
  eq(await t.c.get('/x?a=1'), { ok: 1 }, 'a 200 is returned as JSON');
  eq([t.calls.length, t.calls[0].url, t.calls[0].auth, t.calls[0].hasSignal], [1, 'https://api.samsara.com/x?a=1', 'Bearer tok', true], 'one call, token and timeout attached');

  t = make([() => json(504, { m: 'Gateway Timeout' }), () => json(200, { ok: 2 })]);
  eq([await t.c.get('/x'), t.calls.length, t.sleeps], [{ ok: 2 }, 2, [5000]], '504 then 200: retried after 5 s');

  t = make([new TypeError('fetch failed'), () => json(200, { ok: 3 })]);
  eq([await t.c.get('/x'), t.calls.length], [{ ok: 3 }, 2], 'network error then 200: retried');

  const broken = () => new Response(new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode('{"data":[')); c.error(new TypeError('terminated')); } }),
    { status: 200, headers: { 'content-type': 'application/json' } });
  t = make([broken, () => json(200, { ok: 5 })]);
  eq([await t.c.get('/x'), t.calls.length, t.sleeps], [{ ok: 5 }, 2, [5000]], 'a body that breaks off after the headers: retried');

  t = make([() => json(429, {}, { 'retry-after': '7' }), () => json(200, { ok: 4 })]);
  eq([await t.c.get('/x'), t.sleeps], [{ ok: 4 }, [7000]], '429 honours Retry-After');

  t = make([() => json(503, {}), () => json(502, {}), () => json(500, { m: 'still down' })]);
  await rejects(t.c.get('/x?secret=1'), /Samsara HTTP 500 on \/x: /, 'a 5xx on every attempt throws after 3 attempts');
  eq([t.calls.length, t.sleeps], [3, [5000, 10000]], 'back-off 5 s then 10 s');

  t = make([new Error('timeout'), new Error('timeout'), new Error('timeout')]);
  await rejects(t.c.get('/x'), /timeout/, 'a network error on every attempt throws');
  eq(t.calls.length, 3, 'three attempts');

  t = make([() => json(404, { m: 'nope' })]);
  await rejects(t.c.get('/x'), /Samsara HTTP 404/, 'a 4xx (not 429) is not retried');
  eq(t.calls.length, 1, 'one attempt on a 4xx');

  t = make([() => json(200, { data: [1, 2], pagination: { hasNextPage: true, endCursor: 'c/1' } }),
            () => json(200, { data: [3], pagination: { hasNextPage: false } })]);
  eq(await t.c.paged('/p?x=1', { pauseMs: 50 }), [1, 2, 3], 'paged joins every page');
  eq([t.calls[1].url, t.sleeps], ['https://api.samsara.com/p?x=1&after=c%2F1', [50, 50]], 'cursor encoded, pause before each page');

  t = make([() => json(200, { data: [1], pagination: { hasNextPage: true, endCursor: 'again' } })]);
  await rejects(t.c.paged('/p?x=1', { pageCap: 3 }), /page cap hit on \/p/, 'the page cap throws, never a partial window');

  console.log(`samsara_client: ${n} checks passed`);
})().catch(e => { console.error(e); process.exit(1); });
