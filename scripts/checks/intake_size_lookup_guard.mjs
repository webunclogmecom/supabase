// intake_size_lookup_guard.mjs - runs the REAL supabase/functions/intake-size-lookup/index.ts (types stripped by
// Node 22) against a stubbed backlog and stubbed Anthropic replies, and asserts what is written.
//   node scripts/checks/intake_size_lookup_guard.mjs
// The rules under test (2026-10-22, Trello 6t3RDVkE): a model's gallons are kept only with a source page the search or
// fetch actually returned; the measurement gallons are worked out here, never by the model; a reply that does not call
// the result tool (cut off, refused, plain text) is an ERROR, never a "not found"; pause_turn is resumed.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';
import { edgeVmSource } from './edge_vm_source.mjs';

const src = fs.readFileSync(process.env.GUARD_SRC || new URL('../../supabase/functions/intake-size-lookup/index.ts', import.meta.url), 'utf8');  // GUARD_SRC: a broken copy, as a control
const js = edgeVmSource(src);
const jwt = (role) => 'h.' + Buffer.from(JSON.stringify({ role })).toString('base64') + '.s';

async function run(replies, { backlog, body = {}, role = 'service_role' } = {}) {
  const writes = [], calls = [];
  let handler;
  const queue = [...replies];
  const ctx = {
    Deno: { env: { get: (k) => ({ SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'svc', ANTHROPIC_API_KEY: 'ak' })[k] },
            serve: (h) => { handler = h; } },
    fetch: async (url, opts = {}) => {
      url = String(url);
      if (url.includes('/rest/v1/v_size_lookup_backlog')) return Response.json(backlog ?? []);
      if (url.includes('api.anthropic.com')) { calls.push({ body: JSON.parse(opts.body), headers: opts.headers }); return Response.json(queue.shift()); }
      if (url.includes('/rest/v1/grease_trap_size_lookups')) { writes.push({ url, body: JSON.parse(opts.body), headers: opts.headers }); return new Response(null, { status: 201 }); }
      throw new Error('unexpected fetch ' + url);
    },
    Response, Request, JSON, String, Number, Math, Date, Array, Set, Error, Object, atob, btoa, console, isFinite,
  };
  vm.runInNewContext(js, ctx);
  const res = await handler(new Request('https://fn', { method: 'POST', headers: { authorization: 'Bearer ' + jwt(role) }, body: JSON.stringify(body) }));
  return { status: res.status, body: await res.json(), writes, calls };
}

const MODEL_ITEM = [{ kind: 'model', input_key: 'zurn gt2700-100', input_text: 'Zurn GT2700-100', intake_id: 9, attempts: 0 }];
const MEAS_ITEM = [{ kind: 'measurements', input_key: 'long 180" deep 84" ancho 48"', input_text: 'Long 180" deep 84" ancho 48"', intake_id: 1047, attempts: 1 }];
const search = (urls) => ({ type: 'web_search_tool_result', tool_use_id: 's1', content: urls.map((url) => ({ type: 'web_search_result', url, title: 't' })) });
const result = (input, name = 'report_result') => ({ type: 'tool_use', id: 't1', name, input });
const found = { status: 'found', brand: 'Zurn', model: 'GT2700-100', units: 1, gallons_each: 92.4, dimensions: '46 x 25 x 21 in', source_url: 'https://zurn.com/gt2700.pdf', summary: 'Zurn GT2700-100: 92 gallons.' };

// 1. found with a source page that the search returned: written as found, rounded gallons
let r = await run([{ stop_reason: 'tool_use', model: 'claude-opus-5-5', content: [search(['https://zurn.com/gt2700.pdf/']), result(found)] }], { backlog: MODEL_ITEM });
assert.strictEqual(r.writes.length, 1);
assert.strictEqual(r.writes[0].body.status, 'found');
assert.strictEqual(r.writes[0].body.gallons, 92);
assert.strictEqual(r.writes[0].body.attempts, 1);
assert.strictEqual(r.writes[0].body.source_url, 'https://zurn.com/gt2700.pdf');
assert.strictEqual(r.writes[0].body.input_key, 'zurn gt2700-100', 'the key comes from the backlog, never rebuilt here');
assert.ok(r.writes[0].url.includes('on_conflict=kind,input_key'));
assert.ok(!Array.isArray(r.writes[0].body), 'one object per write, never an array upsert');
assert.strictEqual(r.writes[0].headers['x-app-source'], 'intake-size-lookup');
// the request: Opus 5.5, medium effort, the refusal fallback, web search + fetch + the strict result tool, auto choice
const req = r.calls[0].body;
assert.strictEqual(req.model, 'claude-opus-5-5');
assert.deepStrictEqual(req.output_config, { effort: 'medium' });
assert.strictEqual(req.fallbacks, 'default');
assert.strictEqual(r.calls[0].headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
assert.deepStrictEqual(req.tools.map((t) => t.type ?? t.name), ['web_search_20260209', 'web_fetch_20260209', 'report_result']);
assert.strictEqual(req.tools[2].strict, true);
assert.deepStrictEqual(req.tool_choice, { type: 'auto' }, 'forced tool choice is refused on Opus 5.5');
assert.ok(!('thinking' in req) && !('temperature' in req));
assert.ok(req.max_tokens >= 16000, 'room for thinking');
assert.strictEqual(req.messages[0].content, '<typed>Zurn GT2700-100</typed>');

// 2. units multiply
r = await run([{ stop_reason: 'tool_use', content: [search(['https://zurn.com/gt2700.pdf']), result({ ...found, units: 2 })] }], { backlog: MODEL_ITEM });
assert.strictEqual(r.writes[0].body.gallons, 185);

// 3. a source page it never opened is not kept: an error, retried later
r = await run([{ stop_reason: 'tool_use', content: [search(['https://other.com/x']), result(found)] }], { backlog: MODEL_ITEM });
assert.strictEqual(r.writes[0].body.status, 'error');
assert.match(r.writes[0].body.last_error, /source page not among/);
assert.strictEqual(r.writes[0].body.gallons, null);

// 4. a page fetched with web fetch counts as opened
r = await run([{ stop_reason: 'tool_use', content: [{ type: 'web_fetch_tool_result', content: { type: 'web_fetch_result', url: 'https://zurn.com/gt2700.pdf' } }, result(found)] }], { backlog: MODEL_ITEM });
assert.strictEqual(r.writes[0].body.status, 'found');

// 5. pause_turn is resumed with the assistant turn appended (no extra user message)
r = await run([
  { stop_reason: 'pause_turn', content: [search(['https://zurn.com/gt2700.pdf'])] },
  { stop_reason: 'tool_use', content: [result(found)] },
], { backlog: MODEL_ITEM });
assert.strictEqual(r.calls.length, 2);
assert.strictEqual(r.calls[1].body.messages.length, 2);
assert.strictEqual(r.calls[1].body.messages[1].role, 'assistant');
assert.strictEqual(r.writes[0].body.status, 'found', 'a URL from the paused turn still counts');

// 6. no result tool: cut off, refused, plain text, all errors (never not_found)
for (const stop of ['max_tokens', 'refusal', 'end_turn']) {
  r = await run([{ stop_reason: stop, content: [{ type: 'text', text: 'about 100 gallons' }] }], { backlog: MODEL_ITEM });
  assert.strictEqual(r.writes[0].body.status, 'error', stop);
  assert.strictEqual(r.writes[0].body.gallons, null, stop);
}
// endless pause_turn stops after the continuations, as an error
r = await run(Array(8).fill({ stop_reason: 'pause_turn', content: [] }), { backlog: MODEL_ITEM });
assert.strictEqual(r.writes[0].body.status, 'error');
assert.strictEqual(r.calls.length, 6);

// 7. not_found is kept with its reason, no gallons, no source
r = await run([{ stop_reason: 'tool_use', content: [result({ ...found, status: 'not_found', gallons_each: null, source_url: null, summary: 'Only 50 GPM and 100 lbs published.' })] }], { backlog: MODEL_ITEM });
assert.strictEqual(r.writes[0].body.status, 'not_found');
assert.strictEqual(r.writes[0].body.gallons, null);
assert.strictEqual(r.writes[0].body.source_url, null);
assert.strictEqual(r.writes[0].body.summary, 'Only 50 GPM and 100 lbs published.');

// 8. an out-of-range found answer is an error
r = await run([{ stop_reason: 'tool_use', content: [search(['https://zurn.com/gt2700.pdf']), result({ ...found, gallons_each: 0.2 })] }], { backlog: MODEL_ITEM });
assert.strictEqual(r.writes[0].body.status, 'error');

// 9. measurements: the numbers are read, the gallons worked out here; no web tools, low effort
r = await run([{ stop_reason: 'tool_use', content: [result({ status: 'found', tanks: [{ length_in: 180, width_in: 48, depth_in: 84 }], summary: 'L 180, W 48, D 84 in' }, 'report_measurements')] }], { backlog: MEAS_ITEM });
assert.strictEqual(r.writes[0].body.status, 'found');
assert.strictEqual(r.writes[0].body.gallons, 3142, '180 x 48 x 84 / 231');
assert.strictEqual(r.writes[0].body.attempts, 2);
assert.strictEqual(r.writes[0].body.summary, '180 x 48 x 84 in: 3,142 gallons (length x width x depth / 231).');
assert.deepStrictEqual(r.calls[0].body.tools.map((t) => t.name), ['report_measurements']);
assert.deepStrictEqual(r.calls[0].body.output_config, { effort: 'low' });
// a reported gallons figure from the model is ignored: the schema has none and the sum is ours
r = await run([{ stop_reason: 'tool_use', content: [result({ status: 'found', tanks: [{ length_in: 36, width_in: 24, depth_in: 30 }, { length_in: 36, width_in: 24, depth_in: 30 }], summary: 'two tanks', gallons: 9999 }, 'report_measurements')] }], { backlog: MEAS_ITEM });
assert.strictEqual(r.writes[0].body.gallons, 224, '2 x 36 x 24 x 30 / 231');
// a zero or absurd dimension is an error
r = await run([{ stop_reason: 'tool_use', content: [result({ status: 'found', tanks: [{ length_in: 0, width_in: 48, depth_in: 84 }], summary: '' }, 'report_measurements')] }], { backlog: MEAS_ITEM });
assert.strictEqual(r.writes[0].body.status, 'error');

// 10. dry run with text writes nothing and needs no backlog; text without dry_run is refused
r = await run([{ stop_reason: 'tool_use', content: [search(['https://zurn.com/gt2700.pdf']), result(found)] }], { body: { dry_run: true, kind: 'model', text: 'Zurn GT2700-100' } });
assert.strictEqual(r.writes.length, 0);
assert.strictEqual(r.body.result.gallons, 92);
r = await run([], { body: { kind: 'model', text: 'x' } });
assert.strictEqual(r.status, 400);
// dry run over the backlog writes nothing
r = await run([{ stop_reason: 'tool_use', content: [search(['https://zurn.com/gt2700.pdf']), result(found)] }], { backlog: MODEL_ITEM, body: { dry_run: true } });
assert.strictEqual(r.writes.length, 0);
assert.strictEqual(r.body.results[0].gallons, 92);

// 11. only service_role
r = await run([], { role: 'authenticated', backlog: MODEL_ITEM });
assert.strictEqual(r.status, 403);
assert.strictEqual(r.calls.length, 0);

console.log('intake_size_lookup_guard: all checks passed');
