// ops-portal-client-names.mjs - no real client name or code in the Ops Portal repo (unclogme/ops-portal), read-only.
// Rule: the portal repo, its docs and its commits carry no client data; only the test client 112-YA may appear
// (Ops Portal app CLAUDE.md). On 2026-11-16 this found 14 files (test titles, fixtures, comments, three screen
// placeholders) and they were replaced with made-up ones (Fred: "yes, replace the client names").
//   node --env-file=.env scripts/checks/ops-portal-client-names.mjs ["<path to the portal checkout>"]   (from Supabase/)
//   CONTROL=1 ... same, plus one in-memory line holding a real client code: it must be reported, which proves the
//                 search bites. Nothing is written anywhere.
// Reads every client code and name from Prod (Management API), then every file the portal repo tracks. A name is
// searched only when it is 6 characters or more, as a whole phrase. Prints file:line and the term (local console only;
// never paste the output into a repo). Exit 0 clean, 1 a hit, 2 UNKNOWN (the instrument could not run).
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { execFileSync } from 'node:child_process'

const repo = process.argv[2] || join(process.cwd(), '..', 'Building Apps', 'Ops Portal', 'app')
const control = process.env.CONTROL === '1'
// Client names that are also plain words in the app's own text (a name, not a client, decides nothing here).
const COMMON = new Set(['parking'])

const q = async (query) => {
  const r = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID || 'wbasvhvvismukaqdnouk'}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'content-type': 'application/json' }, body: JSON.stringify({ query }),
  })
  if (!r.ok) { console.log(`UNKNOWN: the database answered ${r.status}`); process.exit(2) }
  return r.json()
}
// A test client's NAME may appear (112-YA and 777-YA are both "Yan's Restaurant"); only 112-YA's CODE may.
const clients = await q(`select client_code, name, public.fn_is_non_customer(id) as test from public.clients`)
if (clients.length < 100) { console.log(`UNKNOWN: only ${clients.length} clients read`); process.exit(2) }

const terms = new Map()
for (const c of clients) {
  if (c.client_code && c.client_code !== '112-YA') terms.set(c.client_code.toLowerCase(), 'a client code')
  if (c.test) continue
  const n = (c.name || '').trim()
  const bare = n.replace(/\s*[-(]?\s*\d{2,3}-[A-Z0-9]{1,5}\)?\s*$/i, '').trim()
  for (const t of [n, bare]) if (t.length >= 6 && !COMMON.has(t.toLowerCase())) terms.set(t.toLowerCase(), 'a client name')
}
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const matchers = [...terms].map(([t, kind]) => [new RegExp(`(^|[^a-z0-9])${esc(t)}($|[^a-z0-9])`, 'i'), t, kind])

let files
try { files = execFileSync('git', ['-C', repo, 'ls-files'], { encoding: 'utf8' }).split('\n').filter((f) => /\.(ts|tsx|js|mjs|cjs|css|md|html|json)$/.test(f) && !/(^|\/)(bun\.lock|package-lock\.json)$/.test(f)) }
catch { console.log(`UNKNOWN: ${repo} is not a git checkout`); process.exit(2) }
if (files.length < 100) { console.log(`UNKNOWN: only ${files.length} files tracked in ${repo}`); process.exit(2) }

const texts = files.map((f) => [f, readFileSync(join(repo, f), 'utf8')])
if (control) {
  const real = clients.find((c) => c.client_code && c.client_code !== '112-YA').client_code
  texts.push(['(control line)', `const fixture = '${real}'`])
}
const hits = []
for (const [f, text] of texts) text.split('\n').forEach((line, i) => {
  for (const [re, t, kind] of matchers) if (re.test(line)) hits.push(`${f}:${i + 1} ${kind}: ${t}`)
})
console.log(`${clients.length} clients, ${terms.size} terms, ${texts.length} files${control ? ' (with the control line)' : ''}`)
if (control) {
  const ok = hits.some((h) => h.startsWith('(control line)'))
  console.log(ok ? 'CONTROL OK: the planted real code was reported' : 'CONTROL FAILED: the planted real code was NOT reported')
  process.exit(ok ? 0 : 1)
}
if (hits.length) { console.log(hits.join('\n')); console.log(`FAIL: ${hits.length} line(s) name a real client`); process.exit(1) }
console.log('PASS: no real client name or code')
