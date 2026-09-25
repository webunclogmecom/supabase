// node prepare.mjs [old-git-ref]   (default: HEAD, i.e. the collector page as last committed)
//
// Writes the three inputs parity.mjs compares, next to it (all gitignored):
//   old.html   the collector page at <old-git-ref> (git show <ref>:scripts/intake-collector/intake.html)
//   new.html   the page as built now (../../intake.html; run build.mjs first)
//   load.json  a {op:'load'} reply built from the LIVE question tree (public.fn_intake_form_current()), every
//              top-level and follow-up key requested, a fake property. Read-only query; no intake is created.
// Then: node parity.mjs S1 ... S5   (each prints submitEqual / draftEqual; "ALL EQUAL" is the pass).
// Positive control: NEWFILE=<a deliberately broken copy> node parity.mjs S1 must report submitEqual:false.
// parity.mjs serves both pages at the planner URL and answers intake-submit from load.json; it never
// reaches a real server (every other request is aborted).
import fs from 'node:fs'
import { execSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
const here = (p) => fileURLToPath(new URL(p, import.meta.url))
const ref = process.argv[2] || 'HEAD'
const repo = here('../../../../')
fs.writeFileSync(here('./old.html'), execSync(`git show ${ref}:scripts/intake-collector/intake.html`, { cwd: repo }))
fs.copyFileSync(here('../../intake.html'), here('./new.html'))
const env = Object.fromEntries(fs.readFileSync(here('../../../../.env'), 'utf8').split(/\r?\n/).filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^['"]|['"]$/g, '')]))
const r = await fetch('https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/database/query', {
  method: 'POST', headers: { Authorization: 'Bearer ' + env.SUPABASE_PAT, 'content-type': 'application/json' },
  body: JSON.stringify({ query: 'select public.fn_intake_form_current() f, (select array_agg(question_key) from client.v_intake_questions) keys' }),
})
const [row] = await r.json()
if (!row || !row.f || !row.keys) throw new Error('could not read the question tree')
const load = { ok: true, intake_id: 999, already_submitted: false, submitted_at: null, expires_at: '2099-12-31T00:00:00Z', requested: row.keys, form: row.f, property: { name: 'Test Kitchen', address: '650 Northwest 33rd Street', city: 'Miami' }, photo_cap: 60 }
fs.writeFileSync(here('./load.json'), JSON.stringify(load))
console.log(`old.html from ${ref}, new.html from the build, load.json with ${row.keys.length} questions`)
