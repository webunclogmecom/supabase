// Asserts the shared detector module reproduces, byte for byte, the output the pre-extraction
// script (scripts/probes/rev/detect_node.js, now deleted) produced on a known scan. The expected
// file was frozen from that script BEFORE the extraction; regenerating it from the new module
// would make this test compare the module with itself.
// USE: node scripts/probes/generated_finisher/detect_core_test.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { detectFile } from '../rev/detect_node.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const expected = JSON.parse(fs.readFileSync(path.join(here, 'detect_core_expected.json'), 'utf8'));
const img = path.join(here, expected.image);
if (!fs.existsSync(img)) { console.error(`control scan missing: ${img} (Task 1 step 1 of the finisher plan fetches it)`); process.exit(2); }

const got = detectFile(img);
const problems = [];
if (got.W !== expected.W || got.H !== expected.H) problems.push(`size ${got.W}x${got.H} vs ${expected.W}x${expected.H}`);
if (got.skew !== expected.skew) problems.push(`skew ${got.skew} vs ${expected.skew}`);
if (got.rules.length !== expected.rules.length) problems.push(`rule count ${got.rules.length} vs ${expected.rules.length}`);
for (let i = 0; i < Math.min(got.rules.length, expected.rules.length); i++) {
  const a = got.rules[i], b = expected.rules[i];
  if (a.pct !== b.pct || a.run !== b.run || a.kind !== b.kind) problems.push(`rule ${i}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
}
// the control must be a page with the known generated-sheet shape, or a passing test proves little
const bounds = got.rules.filter(r => r.kind === 'boundary').map(r => r.pct);
if (!bounds.includes(26.125) || !bounds.includes(63.754)) problems.push(`control page lost its known boundaries: ${bounds.join(' ')}`);
if (problems.length) { console.error('DETECTOR DRIFT:\n  ' + problems.join('\n  ')); process.exit(1); }
console.log(`OK: ${got.rules.length} rules identical to the frozen output (${expected.W}x${expected.H}, skew ${got.skew})`);
