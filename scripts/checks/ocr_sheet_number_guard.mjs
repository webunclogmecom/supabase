// ocr_sheet_number_guard.mjs - runs the REAL supabase/functions/ocr-address-sheet-number/index.ts
// (types stripped by Node 22) against stubbed targets and stubbed Anthropic replies, and asserts
// which replies are allowed to write a derm.address_sheet_scan_reads row.
//   node scripts/checks/ocr_sheet_number_guard.mjs
// The rule under test (2026-10-05): only a reply that stopped with end_turn may be classified. A
// cut-off (max_tokens) or refused reply must write NOTHING, because a written row names the image
// and drains the page from the backlog for good.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';
import { stripTypeScriptTypes } from 'node:module';

const src = fs.readFileSync(new URL('../../supabase/functions/ocr-address-sheet-number/index.ts', import.meta.url), 'utf8');
const js = stripTypeScriptTypes(src);

async function run(reply) {
  const writes = [], calls = [];
  let handler;
  const ctx = {
    Deno: { env: { get: (k) => ({ SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'svc', ANTHROPIC_API_KEY: 'ak' })[k] },
            serve: (h) => { handler = h; } },
    fetch: async (url, opts = {}) => {
      url = String(url);
      if (url.includes('/rpc/fn_sheet_number_ocr_targets')) return Response.json([{ dump_folder: 'ticket-1', ticket: '1', page: 1, image_url: 'https://img/a.jpg' }]);
      if (url === 'https://img/a.jpg') return new Response(new Uint8Array([1, 2, 3]), { headers: { 'content-type': 'image/jpeg' } });
      if (url.includes('api.anthropic.com')) { calls.push(JSON.parse(opts.body)); return Response.json(reply); }
      if (url.includes('/address_sheet_scan_reads')) { writes.push(JSON.parse(opts.body)); return new Response(null, { status: 201 }); }
      throw new Error('unexpected fetch ' + url);
    },
    Response, Uint8Array, JSON, String, Number, Math, Date, Array, Error, atob, btoa, console,
  };
  vm.runInNewContext(js, ctx);
  const jwt = 'h.' + Buffer.from(JSON.stringify({ role: 'service_role' })).toString('base64') + '.s';
  const res = await handler(new Request('https://fn', { method: 'POST', headers: { authorization: 'Bearer ' + jwt }, body: '{}' }));
  return { body: await res.json(), writes, calls };
}

const ok = await run({ stop_reason: 'end_turn', content: [{ type: 'text', text: '1128-1' }] });
assert.strictEqual(ok.writes.length, 1, 'end_turn must write');
assert.strictEqual(ok.writes[0].sheet_no_read, '1128-1');
assert.strictEqual(ok.writes[0].confidence, 'high');
assert.ok(ok.calls[0].max_tokens >= 1024, 'max_tokens must leave room for thinking, got ' + ok.calls[0].max_tokens);

const thinkingFirst = await run({ stop_reason: 'end_turn', content: [{ type: 'thinking', thinking: '' }, { type: 'text', text: '1072-2' }] });
assert.strictEqual(thinkingFirst.writes[0].sheet_no_read, '1072-2', 'text is selected by type, not content[0]');

const unreadable = await run({ stop_reason: 'end_turn', content: [{ type: 'text', text: 'UNREADABLE' }] });
assert.strictEqual(unreadable.writes.length, 1, 'a real UNREADABLE answer is still recorded');
assert.strictEqual(unreadable.writes[0].confidence, 'unreadable');

for (const stop of ['max_tokens', 'refusal', undefined]) {
  const r = await run({ stop_reason: stop, content: stop === 'max_tokens' ? [{ type: 'thinking', thinking: '' }] : [] });
  assert.strictEqual(r.writes.length, 0, `stop_reason ${stop} must write nothing`);
  assert.match(r.body.results[0].error, /stop_reason/, `stop_reason ${stop} must surface as an error`);
}
console.log('ocr_sheet_number_guard: all checks passed');
