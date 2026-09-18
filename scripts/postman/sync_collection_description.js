#!/usr/bin/env node
/**
 * sync_collection_description.js — the Postman collection's description IS postman/README.md.
 *
 *   node scripts/postman/sync_collection_description.js           # rewrite the collection's description
 *   node scripts/postman/sync_collection_description.js --check   # exit 1 if it is stale, change nothing
 *
 * WHY THIS EXISTS. The collection's `info.description` is what a person sees on the collection's
 * Overview tab in Postman. From 2026-07-23 to 2026-09-18 it was a hand-pasted copy of the README that
 * nobody re-pasted, so it opened with a banner saying it was a FROZEN SNAPSHOT and OUT OF DATE while
 * the README beside it moved eleven times. Fred, 2026-09-18: "everytime we do an update on the docs
 * it should also update as well, we can't have something like THIS DESCRIPTION IS A FROZEN SNAPSHOT."
 *
 * So the description is GENERATED from the README, never edited by hand:
 *   - this script writes it (byte-targeted: only the one `"description"` line inside `info` changes,
 *     the rest of the file keeps its exact bytes, escapes included);
 *   - `--check` refuses a stale copy, and is run by the pre-commit hook (.githooks/pre-commit) and by
 *     the postman-doc-drift workflow, so a README edit cannot be committed or merged without it.
 *
 * ⚠ The Postman WORKSPACE copy is pushed by the postman-doc-drift workflow on every push to main
 *   (scripts/postman/publish_collection.js, repository secret POSTMAN_API_KEY). Locally this script
 *   only rewrites the file. The banner it prepends carries the README's "Last updated" stamp so a
 *   reader can tell which version they are looking at.
 * ⚠ Relative links in the README (docs/..., ../Building Apps/...) do not resolve inside Postman.
 *   That is accepted: the text is what matters, and the GitHub copy is one click away.
 */
const fs = require('fs')
const path = require('path')
const { execSync } = require('child_process')

const ROOT = path.resolve(__dirname, '../..')
const README = path.join(ROOT, 'postman/README.md')
const COLLECTION = path.join(ROOT, 'postman/gdo-reporting-bot.postman_collection.json')
const check = process.argv.includes('--check')

const readme = fs.readFileSync(README, 'utf8').replace(/\r\n/g, '\n')
const raw = fs.readFileSync(COLLECTION, 'utf8')

// The README's own "Last updated" line is the version stamp a reader can compare against GitHub.
const lastUpdated = (readme.match(/^\*\*Last updated:\*\*\s*([^\n]{0,80})/m) || [])[1] || 'unknown'
const stamp = lastUpdated.replace(/[*_`]/g, '').split(' (')[0].trim()

const BANNER =
  '> _This description is generated from `postman/README.md` (README last updated ' + stamp + ') by ' +
  '`scripts/postman/sync_collection_description.js`. Edit the README, run the script, re-import the ' +
  'collection. A stale copy fails the pre-commit hook and the postman-doc-drift workflow._\n\n'

const expected = BANNER + readme

// Locate the ONE description line inside the `info` block. It is a single JSON string on its own line.
const infoStart = raw.indexOf('"info": {')
if (infoStart < 0) { console.error('BROKEN: no "info" block'); process.exit(2) }
const infoEnd = raw.indexOf('\n  },', infoStart)
if (infoEnd < 0) { console.error('BROKEN: info block does not close'); process.exit(2) }
const info = raw.slice(infoStart, infoEnd)
// The description is the LAST key of `info` (no trailing comma, followed directly by the block's
// closing brace), so anchor on end-of-line, not on a following newline.
const m = info.match(/\n(\s*)"description": (".*"),?$/m)
if (!m) { console.error('BROKEN: no description line inside info'); process.exit(2) }
const current = JSON.parse(m[2])

if (current === expected) {
  console.log('OK: the collection description matches postman/README.md (' + expected.length + ' chars)')
  process.exit(0)
}
if (check) {
  console.error('STALE: postman/gdo-reporting-bot.postman_collection.json info.description does not match postman/README.md.')
  console.error('       Run: node scripts/postman/sync_collection_description.js   and commit the collection with the README.')
  process.exit(1)
}

// Rewrite only that line. Keep any non-ASCII as literal characters (JSON.stringify does not escape
// them), which is what the file already does for the request bodies; the old hand-pasted copy used
// \u escapes and that difference is exactly the byte change this rewrite is for.
const newLine = m[0].replace(m[2], () => JSON.stringify(expected))
const out = raw.slice(0, infoStart) + info.replace(m[0], () => newLine) + raw.slice(infoEnd)
JSON.parse(out) // must still parse
fs.writeFileSync(COLLECTION, out)
let sha = 'uncommitted'
try { sha = execSync('git log -1 --format=%h -- postman/README.md', { cwd: ROOT, encoding: 'utf8' }).trim() } catch { /* no git */ }
console.log('WRITTEN: info.description <- postman/README.md (' + expected.length + ' chars; README last committed at ' + sha + ').')
console.log('         Commit it with the README; the postman-doc-drift workflow pushes it to the Postman workspace from main.')
