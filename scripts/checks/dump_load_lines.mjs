// dump_load_lines.mjs - runs the REAL loadLines() from supabase/functions/dump-visit-create/index.ts (types
// stripped by Node 22) and asserts the load lines of the "Dumping" Slack message.
//   node scripts/checks/dump_load_lines.mjs
// The rule (Fred, 2026-10-05, "go ahead"): the message counts this shift's completed DERM pickups AND the older
// ones still waiting for a sheet, so a dump never says "no pickups" and then reports 2 in its thread
// (dump 8738, 2026-10-05 4:13 PM ET). A count of -1 (could not be read) leaves its line out.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';
import { stripTypeScriptTypes } from 'node:module';

const src = fs.readFileSync(new URL('../../supabase/functions/dump-visit-create/index.ts', import.meta.url), 'utf8');
const m = src.match(/const loadLines = [\s\S]*?\n};\n/);
assert.ok(m, 'loadLines() was found in the function source');
const real = vm.runInNewContext(stripTypeScriptTypes(m[0]) + 'loadLines;', {});
const loadLines = (a, b) => [...real(a, b)];   // copy out of the vm context (its own Array prototype)
assert.ok(src.includes('extra.push(...loadLines(loadCount, olderCount))'), 'the parent message uses loadLines()');

const cases = [
  // [load, older, expected lines]
  [0, 0, ['🫙 *No completed DERM pickups to report on this load.* No visits for this driver this shift.']],
  [0, 2, ['🫙 *No completed DERM pickups from this shift.*', '🗂 *2* older completed DERM pickups are still waiting to be reported.']],
  [0, 1, ['🫙 *No completed DERM pickups from this shift.*', '🗂 *1* older completed DERM pickup is still waiting to be reported.']],
  [3, 0, ['📋 *3* completed DERM pickups from this shift to report on this load.']],
  [1, 4, ['📋 *1* completed DERM pickup from this shift to report on this load.', '🗂 *4* older completed DERM pickups are still waiting to be reported.']],
  [-1, -1, []],
];
for (const [load, older, want] of cases) {
  assert.deepStrictEqual(loadLines(load, older), want, `loadLines(${load}, ${older})`);
}

// Control: the pre-2026-10-05 rule (this shift only) must FAIL the case that started this, or the test proves nothing.
const old = (load) => (load === 0 ? ['🫙 *No completed DERM pickups to report on this load.* No visits for this driver this shift.'] : []);
assert.notDeepStrictEqual(old(0), loadLines(0, 2), 'control: the old rule reads differently on dump 8738');
assert.ok(loadLines(0, 2).join(' ').includes('2'), 'dump 8738 now mentions the 2 waiting pickups');

console.log(`ok: ${cases.length} cases + control`);
