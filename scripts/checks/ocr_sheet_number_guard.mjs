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

async function run(reply, writeStatus = 201) {
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
      if (url.includes('/address_sheet_scan_reads')) { writes.push(JSON.parse(opts.body)); return writeStatus === 201 ? new Response(null, { status: 201 }) : new Response('db down', { status: writeStatus }); }
      throw new Error('unexpected fetch ' + url);
    },
    Response, Uint8Array, JSON, String, Number, Math, Date, Array, Error, atob, btoa, console,
  };
  vm.runInNewContext(js, ctx);
  const jwt = 'h.' + Buffer.from(JSON.stringify({ role: 'service_role' })).toString('base64') + '.s';
  const res = await handler(new Request('https://fn', { method: 'POST', headers: { authorization: 'Bearer ' + jwt }, body: '{}' }));
  return { body: await res.json(), writes, calls };
}

const ok = await run({ stop_reason: 'end_turn', content: [{ type: 'text', text: '1128-1' }], usage: { input_tokens: 5011, output_tokens: 6 } });
assert.strictEqual(ok.writes.length, 1, 'end_turn must write');
assert.strictEqual(ok.writes[0].sheet_no_read, '1128-1');
assert.strictEqual(ok.writes[0].confidence, 'high');
assert.ok(ok.calls[0].max_tokens >= 1024, 'max_tokens must leave room for thinking, got ' + ok.calls[0].max_tokens);
// G-09 (2026-10-05): explicit low effort, measured identical to the default on 8 known sheets.
assert.deepStrictEqual(ok.calls[0].output_config, { effort: 'low' }, 'request must carry output_config.effort low');
// G-08: the call's usage is passed through to the JSON reply, and never written to the DB.
assert.deepStrictEqual(ok.body.results[0].usage, { input_tokens: 5011, output_tokens: 6 }, 'usage must be passed through');
assert.ok(!('usage' in ok.writes[0]), 'usage must not be written to the scan read');
const noUsage = await run({ stop_reason: 'end_turn', content: [{ type: 'text', text: '1106' }] });
assert.deepStrictEqual(noUsage.body.results[0].usage, { input_tokens: null, output_tokens: null }, 'missing usage reads as null, not a crash');

const thinkingFirst = await run({ stop_reason: 'end_turn', content: [{ type: 'thinking', thinking: '' }, { type: 'text', text: '1072-2' }] });
assert.strictEqual(thinkingFirst.writes[0].sheet_no_read, '1072-2', 'text is selected by type, not content[0]');

const unreadable = await run({ stop_reason: 'end_turn', content: [{ type: 'text', text: 'UNREADABLE' }] });
assert.strictEqual(unreadable.writes.length, 1, 'a real UNREADABLE answer is still recorded');
assert.strictEqual(unreadable.writes[0].confidence, 'unreadable');

for (const stop of ['max_tokens', 'refusal', undefined]) {
  const r = await run({ stop_reason: stop, content: stop === 'max_tokens' ? [{ type: 'thinking', thinking: '' }] : [], usage: { input_tokens: 1233, output_tokens: 2048 } });
  assert.strictEqual(r.writes.length, 0, `stop_reason ${stop} must write nothing`);
  assert.match(r.body.results[0].error, /stop_reason/, `stop_reason ${stop} must surface as an error`);
  assert.deepStrictEqual(r.body.results[0].usage, { input_tokens: 1233, output_tokens: 2048 }, `stop_reason ${stop} must still report usage`);
}
// A failed DB write still reports the call's usage (the tokens were spent).
const writeFail = await run({ stop_reason: 'end_turn', content: [{ type: 'text', text: '1106' }], usage: { input_tokens: 9, output_tokens: 4 } }, 500);
assert.match(writeFail.body.results[0].error, /^write 500/);
assert.deepStrictEqual(writeFail.body.results[0].usage, { input_tokens: 9, output_tokens: 4 }, 'write failure must still report usage');
console.log('ocr_sheet_number_guard: all checks passed');
