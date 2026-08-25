#!/usr/bin/env node
// ============================================================================
// orphaned-prose.mjs — find sentences an edit severed from their own meaning
// ----------------------------------------------------------------------------
//   node scripts/checks/orphaned-prose.mjs [path ...]
//
// 🛑 WHY THIS EXISTS. On 2026-08-25 the SAME defect shipped THREE TIMES in one
//    day, twice inside the very commit written to repair it:
//
//      1. A grain warning inserted BETWEEN a subject and its predicate left the
//         CLAUDE.md ticket-number paragraph on a dangling comma, and welded
//         "which is what makes white => Miami-Dade offload a fact" onto a
//         sentence about grain-staleness. The file asserted that stale grain is
//         what makes the endpoint's load-bearing scope rule true.
//      2. Replacing the FIRST of three concatenated string lines in a Postman
//         failure message left the third welded on, so it read "...the STATE
//         MAPPING itself has failed -- filing. That is a broken property join,
//         not a normalisation problem." It asserted and denied the same thing.
//      3. Deleting the SECOND line of a two-line comment left the head stranded
//         directly above its own refutation: "A non-Florida property would carry
//         a non-Florida county," followed by "⚠ ... is NOT true of our data".
//
//    Every one was invisible to grep, because grep finds the NEW text and says
//    nothing about the wreckage beside it. Every one was found by a human
//    reading the paragraph afterwards. This makes that reading targeted.
//
// 🛑 IT IS A SCREEN, NOT A VERDICT, and it is deliberately noisy. It flags a
//    prose line ending mid-sentence (comma or conjunction) whose next line
//    starts a NEW thought (a warning marker, a bullet, a new sentence). Most
//    hits are ordinary wrapped prose. The output is a list of places to READ,
//    not a list of defects. Expect to dismiss most of them.
//
// ⚠ THE COLLECTION IS JSON. Its comments live inside `event[].script.exec`
//   string arrays, so a plain file read misses them entirely — and the orphan
//   that made an audit non-green was in exactly that file. The first version of
//   this script walked straight past it. Any successor must keep that path.
//
// 🛑 KNOWN BLIND SPOTS. State them, because a screen whose limits are undocumented
//    is the exact failure mode this screen was built to prevent, and a clean run
//    otherwise reads as more coverage than it has:
//
//    1. PIPE-BEARING LINES ARE SKIPPED ENTIRELY (`pa.includes('|')`, to drop
//       markdown tables). That also drops every SQL `||`-concatenated RAISE
//       message — 132 such lines across the four in-scope migrations — which is
//       the same concatenation family as defect 2. If an orphan lands in a
//       `format(... || ...)` message, this will not see it.
//    2. ONLY ADJACENT NON-BLANK LINES ARE COMPARED. A blank line between the two
//       halves, a deleted middle line of a three-line sentence, or a lowercase
//       continuation welded on with no ENDS_MID marker all pass silently.
//    3. IT IS SYNTACTIC, NOT SEMANTIC. It cannot see a sentence that is
//       grammatically whole and factually self-contradicting — which is what
//       iteration 18 found by hand, a comment denying the code eight lines below
//       it. No regex finds that; only reading does.
//
//    ⇒ Treat a clean run as "no severed SEAMS of the two known shapes", never as
//      "the prose is sound".
//
// ✅ Self-test: run with --self-test. It plants each of the three real orphans,
//    confirms the screen catches all three, removes them, and confirms it goes
//    quiet. A screen that has never caught its own motivating defect is a
//    decoration.
// ============================================================================

import fs from 'node:fs'
import path from 'node:path'

const ROOT = path.resolve(new URL('../..', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'))

const DEFAULTS = [
  'CLAUDE.md',
  'docs/specs/2026-08-24-lwt-monthly-endpoint-design.md',
  'postman/README.md',
  'docs/migrations/2026-08-25_0400_lwt_state_and_punctuation_normalisation.sql',
  'docs/migrations/2026-08-25_1200_lwt_state_whitespace_and_collation_hardening.sql',
  'docs/migrations/2026-08-25_1400_lwt_state_normalizer_function.sql',
  'docs/migrations/2026-08-25_1500_lwt_normalizer_grant_and_category_close.sql',
  'supabase/functions/rpa-derm-monthly/index.ts',
]
const COLLECTION = 'postman/gdo-reporting-bot.postman_collection.json'

const STARTS_NEW = /^\s*(?:--\s*|\/\/\s*|#+\s*)?(?:🛑|⚠|✅|\*\*|-\s|\d+\.\s|[A-Z][a-z]+\s)/u
const ENDS_MID = /(,|\band\b|\bor\b|\bbut\b|\bso\b|\bwhich\b|\bthat\b|\bbecause\b)\s*$/i

function collectionLines(file) {
  const col = JSON.parse(fs.readFileSync(file, 'utf8'))
  const out = []
  const walk = (items) => (items || []).forEach((it) => {
    ;(it.event || []).forEach((e) => { if (e.script?.exec) out.push(...e.script.exec) })
    if (it.item) walk(it.item)
  })
  walk(col.item)
  return out
}

// 🛑 A SECOND SIGNATURE, added only because the self-test FAILED without it.
//    Defect 2 was a JS string concatenation, and its severed line ends `-- " +` rather than a
//    comma, so the prose rule above never matched. The tell there is a piece ending on a
//    dangling connective (a dash-pause or an opening conjunction) whose NEXT piece opens with a
//    lowercase fragment that then terminates — i.e. the two halves do not compose into one
//    sentence. Narrow on purpose: it is the shape that actually shipped, not a guess at the
//    shape family.
//    ⚠ Worth keeping in mind: the first version of this screen reported CLEAN while defect 2 sat
//      in the repo. A screen that has not been shown to catch its own motivating defects is a
//      decoration, which is why --self-test exists and why it exits non-zero.
const CONCAT_DANGLES = /(--|\+\s*$|\b(and|or|but|so|because|which|that)\b)\s*"?\s*\+?\s*$/i
const CONCAT_FRAGMENT = /^\s*"\s*[a-z][^"]{0,40}\./

function scan(lines) {
  const hits = []
  for (let i = 0; i < lines.length - 1; i++) {
    const a = lines[i], b = lines[i + 1]
    const pa = String(a).replace(/^\s*(--|\/\/)\s?/, '').trimEnd()
    const pb = String(b).replace(/^\s*(--|\/\/)\s?/, '')
    if (!pa || !pb.trim()) continue
    if (/^\s*```/.test(a) || /^\s*```/.test(b)) continue
    if (pa.includes('|')) continue

    // signature 1: prose ends mid-sentence, next line starts a new thought
    if (ENDS_MID.test(pa) && STARTS_NEW.test(pb)) {
      hits.push([i + 1, pa.slice(-76), pb.trim().slice(0, 76)])
      continue
    }
    // signature 2: a string concatenation whose halves do not compose
    if (CONCAT_DANGLES.test(pa) && CONCAT_FRAGMENT.test(pb)) {
      hits.push([i + 1, pa.slice(-76), pb.trim().slice(0, 76)])
    }
  }
  return hits
}

function run(targets) {
  let flagged = 0
  for (const rel of targets) {
    const file = path.join(ROOT, rel)
    if (!fs.existsSync(file)) { console.log('  skip (missing): ' + rel); continue }
    const lines = rel === COLLECTION
      ? collectionLines(file)
      : fs.readFileSync(file, 'utf8').replace(/\r/g, '').split('\n')
    const hits = scan(lines)
    if (!hits.length) continue
    console.log('\n=== ' + rel + (rel === COLLECTION ? '  (script lines)' : '') + ' ===')
    for (const [n, a, b] of hits) {
      console.log('  line ' + n + ' ends: ...' + a)
      console.log('       next line: ' + b + '\n')
    }
    flagged += hits.length
  }
  return flagged
}

if (process.argv.includes('--self-test')) {
  // 🛑 PROVE THE SCREEN CATCHES ITS OWN MOTIVATING DEFECTS before trusting a clean run.
  const cases = [
    ['severed subject/predicate',
     ['-- split matches the disposal-facility split EXACTLY,',
      '-- 🛑 GRAIN MATTERS HERE. An earlier stamp read 546 / 154, which is the view census.']],
    ['welded contradictory tail',
     ['//        "the STATE MAPPING itself has failed -- " +',
      '//        "filing. That is a broken property join, not a normalisation problem").to.eql(true);']],
    ['head stranded above its refutation',
     ['//    plus 14 no-property rows). A non-Florida property would carry a non-Florida county,',
      '//    ⚠ The obvious justification -- is NOT true of our data, and the real reason is stronger.']],
  ]
  let ok = 0
  for (const [name, lines] of cases) {
    const caught = scan(lines).length > 0
    console.log('  ' + (caught ? 'OK  ' : 'FAIL') + '  catches: ' + name)
    if (caught) ok++
  }
  // and it must go quiet on the repaired forms
  const repaired = scan(['-- split matches the disposal-facility split EXACTLY, which is what makes',
                         '-- `white => Miami-Dade offload` a fact rather than a convention.'])
  console.log('  ' + (repaired.length === 0 ? 'OK  ' : 'FAIL') + '  quiet on a repaired sentence')
  const pass = ok === cases.length && repaired.length === 0
  console.log('\n' + (pass ? 'SELF-TEST PASSED' : 'SELF-TEST FAILED — do not trust a clean run'))
  process.exit(pass ? 0 : 2)
}

const args = process.argv.slice(2).filter((a) => !a.startsWith('--'))
const targets = args.length ? args : DEFAULTS.concat([COLLECTION])
const n = run(targets)
console.log(n
  ? '\n' + n + ' spot(s) to READ AS PROSE. Most will be ordinary wrapped text — read them anyway,'
    + '\nbecause every orphan this exists for looked exactly like ordinary wrapped text to grep.'
  : '\nno mid-sentence/new-thought seams found')
