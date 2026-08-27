#!/usr/bin/env node
/**
 * api-doc-drift.js — does postman/README.md still describe what the bot-facing endpoints
 * actually do?
 *
 *   node scripts/checks/api-doc-drift.js
 *
 * Exit 0 = no drift. Exit 1 = a documentation gap. Exit 2 = the CHECK ITSELF is broken.
 *
 * WHY THIS EXISTS. `postman/README.md` is not internal notes: it is the contract an EXTERNAL
 * developer builds against, and the only copy of it he has. On 2026-08-26 the endpoint gained a
 * new 500 (`reported_lookup_truncated`) and changed another's payload, and neither reached the
 * document. Nobody noticed because nothing compares the two. This does.
 *
 * 🛑 THE DESIGN RULE, learned by getting it wrong twice in the first ten minutes:
 *
 *   1. A CHECK THAT FINDS NOTHING MUST PROVE IT COULD HAVE. The first version located the row
 *      object with a pattern that matched a COMMENT, extracted zero fields, and printed
 *      "all documented". A confident zero from a broken instrument is worse than no check, so
 *      every extraction here carries a plausibility floor and fails LOUD (exit 2) below it.
 *   2. A MISS IS USUALLY THE PATTERN, NOT THE DOC. The same run reported `unreported` as
 *      undocumented because the check demanded backticks while the README writes `?unreported=1`,
 *      and reported `invalid_` as a missing code when it is a dynamic prefix (`'invalid_' + f`).
 *      Both were instrument bugs. Suspect the instrument first.
 *
 * ⚠ It checks DOCUMENTED vs EMITTED. It cannot check that the prose is TRUE. The
 *   `ticket_insert_failed` entry in the README was written from a guess, and reading the source
 *   showed the opposite of the guess: the run_id is already burned, so a retry cannot repair it.
 *   This check would have passed either way. Read the code before you write the sentence.
 */
const fs = require('fs')
const path = require('path')

const ROOT = path.resolve(__dirname, '../..')
const README = path.join(ROOT, 'postman/README.md')
const readme = fs.readFileSync(README, 'utf8')

const FNS = [
  ['rpa-derm-monthly', 'supabase/functions/rpa-derm-monthly/index.ts'],
  ['rpa-derm-monthly-filed', 'supabase/functions/rpa-derm-monthly-filed/index.ts'],
]

let gaps = 0
let broken = 0
const fail = (msg) => { gaps++; console.log('  ERROR  ' + msg) }
const instrument = (msg) => { broken++; console.log('  BROKEN ' + msg) }

// ---- 1. every error code an endpoint can emit must appear in the reference -----------------
for (const [name, rel] of FNS) {
  const src = fs.readFileSync(path.join(ROOT, rel), 'utf8')
  console.log('\n' + name)
  const codes = [...new Set([...src.matchAll(/error:\s*'([a-z0-9_]+)'/g)].map((m) => m[1]))]
    // `'invalid_' + f` is a dynamic prefix, not a literal code. Its real values
    // (invalid_period_start / invalid_period_end) are emitted and documented separately.
    .filter((c) => !c.endsWith('_'))
    .sort()
  if (codes.length < 5) instrument(name + ': only ' + codes.length + ' error codes found, implausible')
  const missing = codes.filter((c) => !readme.includes(c))
  console.log('  ' + codes.length + ' error codes emitted')
  if (missing.length) fail(name + ': not in README: ' + missing.join(', '))
  else console.log('  all documented')
}

// ---- 2. every query param the monthly endpoint reads ---------------------------------------
const msrc = fs.readFileSync(path.join(ROOT, FNS[0][1]), 'utf8')
console.log('\nquery params')
const params = [...new Set([...msrc.matchAll(/searchParams\.get\('([a-z_]+)'\)/g)].map((m) => m[1]))].sort()
if (!params.length) instrument('no query params found, implausible')
console.log('  ' + params.join(', '))
const missingParams = params.filter((p) => !readme.includes(p))
if (missingParams.length) fail('params not in README: ' + missingParams.join(', '))
else console.log('  all documented')

// ---- 3. every field served on a row --------------------------------------------------------
console.log('\nrow fields')
const rowBlock = msrc.match(/rows: [a-zA-Z]+\.map\([\s\S]*?\n {6}\}\)\)/)
if (!rowBlock) instrument('could not locate the row object, so this check proves NOTHING')
const rowKeys = rowBlock
  ? [...new Set([...rowBlock[0].matchAll(/^\s+([a-z_][a-z0-9_]*):/gm)].map((m) => m[1]))].sort()
  : []
if (rowBlock && rowKeys.length < 10) instrument('only ' + rowKeys.length + ' row fields, implausible')
console.log('  ' + rowKeys.length + ' fields')
const missingRow = rowKeys.filter((k) => !readme.includes(k))
if (missingRow.length) fail('row fields not in README: ' + missingRow.join(', '))
else console.log('  all documented')

// ---- 4. positive control: the matcher must be able to report something MISSING --------------
console.log('\ncontrol')
if (readme.includes('zzz_not_a_real_field')) instrument('the control string exists in the README; the check cannot fail')
else console.log('  ok, a known-absent string is correctly reported as absent')

// ---- verdict -------------------------------------------------------------------------------
console.log('')
if (broken) {
  console.log('BROKEN: ' + broken + ' part(s) of this check are not measuring anything. Its clean')
  console.log('        results prove nothing. Fix the check before trusting it.')
  process.exit(2)
}
if (gaps) {
  console.log('DRIFT: ' + gaps + ' documentation gap(s). postman/README.md is what an external')
  console.log('       developer builds against, so close them before he pulls it.')
  process.exit(1)
}
console.log('OK: postman/README.md documents every error code, query param and row field the')
console.log('    two bot-facing endpoints emit.')
