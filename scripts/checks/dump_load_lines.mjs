// dump_load_lines.mjs - runs the REAL loadLines() and loadCounts() from supabase/functions/dump-visit-create/index.ts
// (types stripped by Node 22) and asserts the load lines of the "Dumping" Slack message and the counts behind them.
//   node scripts/checks/dump_load_lines.mjs
//   DUMP_FN_SRC=<path to a copy of index.ts> node scripts/checks/dump_load_lines.mjs   (to test a copy or a mutant)
// The rules:
// - Fred, 2026-10-05, "go ahead": the message counts the driver's completed DERM pickups AND the other ones still
//   waiting for a sheet, so a dump never says "no pickups" and then reports 2 in its thread (dump 8738).
// - Fred, 2026-10-07, "All, as in the preview": "since this driver's last dump" (not "from this shift"), no
//   "No visits for this driver this shift" (nothing measures visits), "other ... (any truck)" (not "older"), and a
//   Broward line when Homestead hides the driver's own Broward pickups (dump 8726, Oct 3, said "No completed DERM
//   pickups" while 318-CAP sat on the truck).
// - 2026-10-12 (notification audit): the parent counted pickups already reported on ANOTHER manifest, so dump 8740
//   said 9 and its thread "Reported on this load (7)" with no Missing line. loadCounts() now counts the rows once
//   for both messages: held pickups leave the count and are NAMED on their own line, in the parent and the thread,
//   never silently subtracted (a wrong hold must stay visible).
// A count of -1 (or a null Broward / held list) could not be read and leaves its line out: never a guessed 0.
// ⚠ Ships in the same commit as dump-visit-create: the call sites it asserts change with the function.
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert';
import { stripTypeScriptTypes } from 'node:module';

const src = fs.readFileSync(process.env.DUMP_FN_SRC ?? new URL('../../supabase/functions/dump-visit-create/index.ts', import.meta.url), 'utf8');
const m = src.match(/const loadLines = [\s\S]*?\n};\n/);
assert.ok(m, 'loadLines() was found in the function source');
const real = vm.runInNewContext(stripTypeScriptTypes(m[0]) + 'loadLines;', {});
const loadLines = (a, b, c, d) => [...real(a, b, c, d)];   // copy out of the vm context (its own Array prototype)
assert.ok(src.includes('extra.push(...loadLines(loadCount, olderCount, broward, held))'), 'the parent message uses loadLines()');

const NONE = '🫙 *No completed DERM pickups to report on this load.*';
const cases = [
  // [load, older, broward, (held,) expected lines]
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
  // 2026-10-12, dump 8740 (Oct 5): 9 since his last dump, 2 of them already marked by Diego's dump 8738
  [7, 0, [], ['191-TEN (Diego)', '056-STM (Diego)'], ["📋 *7* completed DERM pickups since this driver's last dump to report on this load.", "↪️ *2* of this driver's pickups were already reported elsewhere (191-TEN (Diego), 056-STM (Diego))."]],
  [0, 3, [], ['040-MV (Diego)'], [NONE, "↪️ *1* of this driver's pickups was already reported elsewhere (040-MV (Diego)).", '🗂 *3* other completed DERM pickups are still waiting to be reported (any truck).']],
  [-1, -1, null, null, []],
];
for (const c of cases) {
  const [load, older, broward] = c, held = c.length === 5 ? c[3] : undefined, want = c[c.length - 1];
  assert.deepStrictEqual(loadLines(load, older, broward, held), want, `loadLines(${load}, ${older}, ${JSON.stringify(broward)}, ${JSON.stringify(held)})`);
}
for (const line of cases.flatMap((c) => c[c.length - 1])) {
  assert.ok(!/\u2014/.test(line), `no em dash: ${line}`);
  assert.ok(!/this shift|No visits/.test(line), `no unmeasured shift claim: ${line}`);
}

// Controls: the earlier rules must FAIL the cases that started each change, or the test proves nothing.
const v1005 = (load, older) => (load === 0 && older === 0 ? ['🫙 *No completed DERM pickups to report on this load.* No visits for this driver this shift.'] : []);
assert.notDeepStrictEqual(v1005(0, 0), loadLines(0, 0, []), 'control: the old empty line claimed "No visits"');
assert.notDeepStrictEqual(v1005(0, 0), loadLines(0, 0, ['318-CAP']), 'control: dump 8726 now names the Broward pickup');
assert.ok(loadLines(0, 2, []).join(' ').includes('2'), 'dump 8738 still mentions the 2 waiting pickups');

// 2026-10-12: the COUNTS. loadCounts() splits the dump_manifest_handout_list rows once for the parent and the thread.
// Fixture = dump 8740 (Michael, Oct 5): 9 load rows, 191-TEN and 056-STM held by Diego's dump 8738; the parent said 9
// and the thread "Reported on this load (7)" with no Missing line.
const mc = src.match(/const loadCounts = [\s\S]*?\n};\n/);
assert.ok(mc, 'loadCounts() was found in the function source');
const loadCounts = vm.runInNewContext(stripTypeScriptTypes(mc[0]) + 'loadCounts;', {});
assert.ok(src.includes('loadCounts(data as Record<string, unknown>[])') && src.includes('loadCounts(list as Record<string, unknown>[])'),
  'the parent message and the load report both count through loadCounts()');
// ... and both NAME the held pickups: the parent through loadLines' 4th argument, the thread in its own section
assert.ok(/held = c\.held\.map\(\(r\) => slackEsc\(`\$\{String\(r\.client_code \?\? ""\)\.trim\(\)\}\$\{heldBy\(r\)\}`\)\);/.test(src),
  'the parent passes the held pickups, escaped, as "CODE (who)"');
assert.ok(/if \(held\.length\) blocks\.push\(\{ type: "section", text: \{ type: "mrkdwn", text: `↪️ \*Already reported elsewhere \(\$\{held\.length\}\):\*\\n\$\{clientBullets\(held\.map\(/.test(src),
  'the load report lists the held pickups in their own section');
assert.ok(/held = c\.held;/.test(src), 'the load report takes its held list from loadCounts()');
const row = (code, o = {}) => ({ bucket: 'load', client_code: code, confirmed: false, on_this_dump: false, held_by: null, ...o });
const r8740 = ['244-URI', '042-MT', '058-SOH', '181-PV', '062-TCE', '137-BB', '003-BC'].map((c) => row(c))
  .concat(['191-TEN', '056-STM'].map((c) => row(c, { confirmed: true, held_by: 'Diego' })))
  .concat([row('305-HE', { bucket: 'outstanding' }), row('009-CN', { bucket: 'outstanding', confirmed: true, held_by: 'Mark' })]);
const k = loadCounts(r8740);
assert.strictEqual(k.load, 7, '8740: the parent counts the 7 not reported anywhere');
assert.deepStrictEqual([...k.held].map((r) => `${r.client_code} (${r.held_by})`), ['191-TEN (Diego)', '056-STM (Diego)'], '8740: the 2 held by Diego are the held rows');
assert.strictEqual(k.missing.length, 7, '8740: Missing before the confirm = the same 7');
assert.strictEqual(k.older, 1, 'older counts only unreported outstanding rows');
// after the confirm the 7 sit on THIS dump: they stay in the load count and leave Missing
const after = r8740.map((r) => (r.held_by === null && r.bucket === 'load' ? { ...r, confirmed: true, on_this_dump: true } : r));
const ka = loadCounts(after);
assert.strictEqual(ka.load, 7, 'rows on this dump stay in the load');
assert.strictEqual(ka.missing.length, 0, 'nothing missing once the 7 are reported here');
assert.strictEqual(ka.held.length, 2, 'the 2 held elsewhere are still named after the confirm');
// Control: the v71 rule counted every load row, so it said 9 while the thread could only ever account for 7.
const v71load = (rows) => rows.filter((r) => r.bucket === 'load').length;
assert.strictEqual(v71load(r8740), 9, 'control: the old count reproduces the 9 that was posted');
assert.notStrictEqual(v71load(r8740), k.load, 'control: the new count differs from the old one on 8740');
assert.strictEqual(k.load + k.held.length, v71load(r8740), 'nothing is dropped: load + named = every load row');

console.log(`ok: ${cases.length} cases + controls; loadCounts: dump 8740 fixture + controls; held named in both messages`);
