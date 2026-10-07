// dump_load_lines.mjs - runs the REAL loadLines() from supabase/functions/dump-visit-create/index.ts (types
// stripped by Node 22) and asserts the load lines of the "Dumping" Slack message.
//   node scripts/checks/dump_load_lines.mjs
// The rules:
// - Fred, 2026-10-05, "go ahead": the message counts the driver's completed DERM pickups AND the other ones still
//   waiting for a sheet, so a dump never says "no pickups" and then reports 2 in its thread (dump 8738).
// - Fred, 2026-10-07, "All, as in the preview": "since this driver's last dump" (not "from this shift"), no
//   "No visits for this driver this shift" (nothing measures visits), "other ... (any truck)" (not "older"), and a
//   Broward line when Homestead hides the driver's own Broward pickups (dump 8726, Oct 3, said "No completed DERM
//   pickups" while 318-CAP sat on the truck).
// A count of -1 (or a null Broward list) could not be read and leaves its line out: never a guessed 0.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';
import { stripTypeScriptTypes } from 'node:module';

const src = fs.readFileSync(new URL('../../supabase/functions/dump-visit-create/index.ts', import.meta.url), 'utf8');
const m = src.match(/const loadLines = [\s\S]*?\n};\n/);
assert.ok(m, 'loadLines() was found in the function source');
const real = vm.runInNewContext(stripTypeScriptTypes(m[0]) + 'loadLines;', {});
const loadLines = (a, b, c) => [...real(a, b, c)];   // copy out of the vm context (its own Array prototype)
assert.ok(src.includes('extra.push(...loadLines(loadCount, olderCount, broward))'), 'the parent message uses loadLines()');

const NONE = '🫙 *No completed DERM pickups to report on this load.*';
const cases = [
  // [load, older, broward, expected lines]
  [0, 0, [], [NONE]],
  [0, 2, [], ["🫙 *No completed DERM pickups since this driver's last dump.*", '🗂 *2* other completed DERM pickups are still waiting to be reported (any truck).']],
  [0, 1, [], ["🫙 *No completed DERM pickups since this driver's last dump.*", '🗂 *1* other completed DERM pickup is still waiting to be reported (any truck).']],
  [3, 0, [], ["📋 *3* completed DERM pickups since this driver's last dump to report on this load."]],
  [1, 4, [], ["📋 *1* completed DERM pickup since this driver's last dump to report on this load.", '🗂 *4* other completed DERM pickups are still waiting to be reported (any truck).']],
  // dump 8726 (Oct 3): no Miami-Dade load, one Broward pickup on the truck
  [0, 0, ['318-CAP'], ['🫙 *No Miami-Dade DERM pickups to report on this load.*', "⚠️ *1* of this driver's pickups is in Broward (318-CAP): file it at Pompano."]],
  [2, 0, ['318-CAP', '093-KC'], ["📋 *2* completed DERM pickups since this driver's last dump to report on this load.", "⚠️ *2* of this driver's pickups are in Broward (318-CAP, 093-KC): file them at Pompano."]],
  [-1, -1, null, []],
  [0, -1, null, ["🫙 *No completed DERM pickups since this driver's last dump.*"]],
];
for (const [load, older, broward, want] of cases) {
  assert.deepStrictEqual(loadLines(load, older, broward), want, `loadLines(${load}, ${older}, ${JSON.stringify(broward)})`);
}
for (const line of cases.flatMap((c) => c[3])) {
  assert.ok(!/—/.test(line), `no em dash: ${line}`);
  assert.ok(!/this shift|No visits/.test(line), `no unmeasured shift claim: ${line}`);
}

// Controls: the earlier rules must FAIL the cases that started each change, or the test proves nothing.
const v1005 = (load, older) => (load === 0 && older === 0 ? ['🫙 *No completed DERM pickups to report on this load.* No visits for this driver this shift.'] : []);
assert.notDeepStrictEqual(v1005(0, 0), loadLines(0, 0, []), 'control: the old empty line claimed "No visits"');
assert.notDeepStrictEqual(v1005(0, 0), loadLines(0, 0, ['318-CAP']), 'control: dump 8726 now names the Broward pickup');
assert.ok(loadLines(0, 2, []).join(' ').includes('2'), 'dump 8738 still mentions the 2 waiting pickups');

console.log(`ok: ${cases.length} cases + controls`);
