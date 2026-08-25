// b64_chunked_test.js - prove encodeBase64Chunked() is byte-identical to a known-good base64.
//
// Written 2026-08-25 with the fix for the send-visit-photos-email memory kill.
// The function is EXTRACTED FROM THE REAL SOURCE FILE, never retyped: retyping is how this
// repo has lost clauses before, and a base64 bug here produces a CORRUPT PDF that still
// looks like valid base64 and still sends, i.e. a broken document in a regulator's inbox
// with no error anywhere.
//
// It also MUTATION-TESTS the guard: with B64_CHUNK set to a non-multiple of 3 the encoder
// must produce wrong output AND the 4*ceil(n/3) length check must catch it. A test suite
// that only shows the correct version passing is an untested instrument.
const fs = require('fs');
const path = require('path');

const SRC = path.resolve(__dirname, '../../supabase/functions/send-visit-photos-email/index.ts');
const src = fs.readFileSync(SRC, 'utf8');

// Pull the three declarations out of the real file by anchor.
function extract(re, label) {
  const m = src.match(re);
  if (!m) throw new Error(`could not extract ${label} from ${SRC} - the anchor moved, fix this probe`);
  return m[0];
}
const chunkDecl = extract(/^const B64_CHUNK = .*$/m, 'B64_CHUNK');
const maxDecl = extract(/^const FROM_CHARCODE_MAX = .*$/m, 'FROM_CHARCODE_MAX');
const fnDecl = extract(/function encodeBase64Chunked\(bytes: Uint8Array\): string \{[\s\S]*?\n\}/, 'encodeBase64Chunked');

// Strip the TS annotations so plain node can run the identical body.
const asJs = fnDecl
  .replace('function encodeBase64Chunked(bytes: Uint8Array): string', 'function encodeBase64Chunked(bytes)')
  .replace('const parts: string[] = []', 'const parts = []');

function build(chunkOverride) {
  const chunkLine = chunkOverride == null ? chunkDecl : `const B64_CHUNK = ${chunkOverride};`;
  // btoa exists in node >= 16
  return new Function(`${chunkLine.replace(/\/\/.*$/, '')}\n${maxDecl.replace(/\/\/.*$/, '')}\n${asJs}\nreturn encodeBase64Chunked;`)();
}

const good = build(null);
const expectedLen = (n) => 4 * Math.ceil(n / 3);

const SIZES = [
  0, 1, 2, 3, 4, 5, 6, 7, 8191, 8192, 8193,
  49151, 49152, 49153,            // B64_CHUNK boundary
  49152 * 2, 49152 * 2 + 1,
  100000, 1000003, 5 * 1024 * 1024,
];

let fails = 0, checked = 0;
for (const n of SIZES) {
  const buf = Buffer.alloc(n);
  for (let i = 0; i < n; i++) buf[i] = (i * 31 + (i >> 8) * 7) & 0xff; // deterministic, not all-zero
  const bytes = new Uint8Array(buf);
  const mine = good(bytes);
  const ref = buf.toString('base64');
  const lenOk = mine.length === expectedLen(n);
  const same = mine === ref;
  checked++;
  if (!same || !lenOk) {
    fails++;
    console.log(`FAIL n=${n} same=${same} lenOk=${lenOk} mine=${mine.length} ref=${ref.length}`);
  }
}
console.log(`correctness: ${checked - fails}/${checked} sizes byte-identical to Buffer.toString('base64')`);

// ---- MUTATION TEST: the control must FAIL on a broken chunk size --------------------
// 49150 is NOT a multiple of 3. This is the exact bug the comment warns about.
const broken = build(49150);
const n = 200000;
const buf = Buffer.alloc(n);
for (let i = 0; i < n; i++) buf[i] = (i * 31) & 0xff;
const bytes = new Uint8Array(buf);
const bad = broken(bytes);
const ref = buf.toString('base64');
const corrupt = bad !== ref;
const caughtByLengthCheck = bad.length !== expectedLen(n);
console.log(`mutation (chunk=49150, not a multiple of 3):`);
console.log(`  produces corrupt output   : ${corrupt}   ${corrupt ? '(as expected)' : '<-- MUTATION DID NOT BITE, test is worthless'}`);
console.log(`  caught by 4*ceil(n/3) len : ${caughtByLengthCheck}  mine=${bad.length} expected=${expectedLen(n)}`);
console.log(`  mid-stream padding present: ${bad.slice(0, -2).includes('=')}`);

const ok = fails === 0 && corrupt && caughtByLengthCheck;
console.log(ok ? '\nRESULT: PASS - encoder correct AND the length guard detects the classic bug'
               : '\nRESULT: FAIL');
process.exit(ok ? 0 : 1);
