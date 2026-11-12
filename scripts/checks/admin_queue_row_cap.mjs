// Admin Review queue: does every list read get ALL its rows past the 1,000-row cap? (Trello #186, 2026-11-12)
//
// The project answers at most 1,000 rows per request (PostgREST max_rows) and drops the rest with no error
// (HTTP 206). The queue read every queue visit's drivers in one request, so at 1,084 rows 74 cards said
// "Driver: Unassigned". Spec: Building Apps/Admin Review/docs/specs/2026-11-12-queue-reads-past-1000-rows.md
//
// For each read the queue makes, this replays it PAGED (as the fixed app does) and compares the row count with
// the total PostgREST reports (content-range), then replays it UNPAGED (as the old app did) as the control:
// an unpaged read whose total is over 1,000 must come back short, or the instrument is not seeing the cap.
//
// Read-only. Run from Supabase/:  node scripts/checks/admin_queue_row_cap.mjs
// Exit 0 = every paged read is complete; 1 = a paged read is short; 2 = a control did not behave.
import fs from 'fs'

const env = Object.fromEntries(fs.readFileSync('.env', 'utf8').split(/\r?\n/).filter(l => l.includes('=') && !l.startsWith('#'))
  .map(l => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim().replace(/^["']|["']$/g, '')]))
const BASE = 'https://wbasvhvvismukaqdnouk.supabase.co/rest/v1/'
const H = { apikey: env.SUPABASE_SERVICE_ROLE_KEY, Authorization: 'Bearer ' + env.SUPABASE_SERVICE_ROLE_KEY, 'X-App-Source': 'check-admin-queue-row-cap' }
const SIZE = 1000

async function get(path, range) {
  const headers = { ...H, Prefer: 'count=exact' }
  if (range) headers.Range = `${range[0]}-${range[1]}`
  const r = await fetch(BASE + path, { headers })
  if (!r.ok) throw new Error(`${path.split('?')[0]} HTTP ${r.status}: ${(await r.text()).slice(0, 200)}`)
  const total = Number((r.headers.get('content-range') || '').split('/')[1])
  return { rows: await r.json(), total: Number.isFinite(total) ? total : null }
}
async function paged(path) {
  const rows = []; let total = null
  for (let from = 0; ; from += SIZE) {
    const res = await get(path, [from, from + SIZE - 1])
    if (from === 0) total = res.total
    rows.push(...res.rows)
    if (res.rows.length < SIZE) return { rows, total }
  }
}

const today = new Date().toLocaleDateString('en-CA', { timeZone: 'America/New_York' })
const visitsPath = `visits_with_review?select=id,job_id&visit_status=eq.completed&in_review_scope=eq.true&visit_date=lte.${today}` +
  `&order=review_status.asc,visit_date.desc,id.asc`
const visits = await paged(visitsPath)
const ids = visits.rows.map(v => v.id)
const jobIds = [...new Set(visits.rows.map(v => v.job_id).filter(Boolean))]

const reads = [
  ['queue visits', visitsPath],
  ['visit_assignments', `visit_assignments?select=visit_id,employee_id&visit_id=in.(${ids.join(',')})&order=visit_id.asc,employee_id.asc`],
  ['v_visit_photo_counts', `v_visit_photo_counts?select=visit_id&visit_id=in.(${ids.join(',')})&order=visit_id.asc`],
  ['jobs', `jobs?select=id&id=in.(${jobIds.join(',')})&order=id.asc`],
  ['line_items', `line_items?select=id&job_id=in.(${jobIds.join(',')})&order=id.asc`],
]

let short = 0, badControl = 0, assignRows = []
for (const [name, path] of reads) {
  const p = name === 'queue visits' ? visits : await paged(path)
  const u = await get(path)                            // the old single request: the control
  const ok = p.total !== null && p.rows.length === p.total
  const capSeen = p.total > SIZE ? u.rows.length === SIZE : null
  if (!ok) short++
  if (capSeen === false) badControl++
  if (name === 'visit_assignments') assignRows = p.rows
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name.padEnd(21)} paged ${String(p.rows.length).padStart(5)} of ${p.total}` +
    `  | unpaged ${String(u.rows.length).padStart(5)}${capSeen === null ? ' (under the cap: control not exercised)' : capSeen ? ' (cut at 1,000: control OK)' : ' (CONTROL FAILED: the cap did not show)'}` +
    `  | ${Math.round(100 * p.total / SIZE)}% of one request`)
}
const withDriver = new Set(assignRows.map(a => a.visit_id))
console.log(`queue visits with no driver row after paging: ${ids.filter(i => !withDriver.has(i)).length} of ${ids.length}`)
process.exit(short ? 1 : badControl ? 2 : 0)
