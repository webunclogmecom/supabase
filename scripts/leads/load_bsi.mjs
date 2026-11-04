// Load a BSI Online scrape into the frozen-leads schema (Trello #165 / #166, plan section 8.2).
//
//   node --env-file=.env scripts/leads/load_bsi.mjs <raw.json> [--dry-run]
//
// <raw.json> is the output of scripts/leads/bsi_boca_scrape.mjs (kept in the workspace backups/ folder, never a repo).
// It refuses a file that is not complete, has fewer than 400 properties, or lacks the control (Grove Kosher, BSI 957372,
// with interceptors 9818 and 9819). It keeps organization 135 (City of Boca Raton Utility Services) and an allow-list of
// fields, sorts each property's interceptors by id, and calls leads.ingest_quiet('bsi', <run start>, records, <file>,
// <dry run>) once. CCNs and BSI's contact stay in the private payload (Fred 2026-11-03); no API role can read them.
// The payload travels as a literal, and Postgres writes the full text of a FAILING statement to its server log, so the
// statement must not fail (migrations 2026-11-03_1848 and _2039):
//   - ingest_quiet takes the run start and the records as TEXT and casts them inside its handler; the statement below
//     carries no cast, so a bad character in BSI's data comes back as {ok:false, sqlstate} instead of failing it;
//   - it runs with lock_timeout 500 ms, so a busy lock comes back as 55P03 before log_lock_waits (1 s) would log it;
//   - this script first checks the function exists (a missing function would fail the statement and log it);
//   - it prints only the first line of the API's error message, cut before any LINE n: quote of the statement.
// Still logged with its text: a statement that runs 10 s or more (auto_explain); a full load takes under 1 s. Never
// go back to a DO block that raises, and never run an older copy of this file (fd2eab18's --dry-run is that DO block).
// --dry-run makes ingest_quiet undo the load inside the database and print what it would produce (states, review
// items, view counts); nothing is kept.
import fs from 'node:fs'
import path from 'node:path'

const [file, flag] = process.argv.slice(2)
if (!file) { console.error('usage: load_bsi.mjs <raw.json> [--dry-run]'); process.exit(1) }
const DRY = flag === '--dry-run'
const raw = JSON.parse(fs.readFileSync(file, 'utf8'))
const props = Object.values(raw.properties ?? {})
const fail = (m) => { console.error('REFUSED: ' + m); process.exit(2) }
if (raw.done !== true) fail('the scrape is not complete (done !== true)')
if (props.length < 400) fail(`only ${props.length} properties`)
const g = raw.properties['957372']
const gIds = (g?.detail?.interceptors ?? []).map((i) => String(i.id)).sort()
if (gIds.join(',') !== '9818,9819') fail('control: Grove Kosher (957372) without interceptors 9818 and 9819')
if (!raw.fetched_at || Number.isNaN(Date.parse(raw.fetched_at))) fail('no run start (fetched_at) in the file')
const runStart = new Date(raw.fetched_at)
if (runStart.getUTCFullYear() < 2026 || runStart.getUTCFullYear() > 2100) fail(`run start ${raw.fetched_at} is not a plausible date`)

const pick = (o, keys) => Object.fromEntries(keys.filter((k) => o && o[k] !== undefined).map((k) => [k, o[k]]))
const ADDR = ['name', 'address', 'address2', 'city', 'zip_code', 'state_code']
const TYPE = ['identifier', 'value']
const records = props
  .filter((p) => p.search_item?.organization_id === 135 && p.detail)
  .map((p) => {
    const s = p.search_item, d = p.detail
    const search_item = {
      ...pick(s, ['id', 'status', 'type', 'organization_id', 'active', 'label', 'created_at', 'interceptor_count', 'ccn']),
      contact: s.contact ? pick(s.contact, ['id', 'name', 'email', 'phone']) : null,
      physical_address: pick(s.physical_address, ADDR),
      mailing_address: pick(s.mailing_address, ADDR),
    }
    const interceptors = (d.interceptors ?? [])
      .map((i) => ({
        ...pick(i, ['id', 'location', 'next_pump_date', 'last_pump_date', 'last_maintenance_report_id', 'pump_frequency',
          'fog_location_id', 'needs_repair', 'active', 'deleted', 'deleted_at']),
        type: pick(i.type, TYPE), size: pick(i.size, TYPE),
      }))
      .sort((a, b) => Number(a.id) - Number(b.id))
    const detail = {
      ...pick(d, ['organization_name', 'ccn', 'filing_fee', 'is_in_audit', 'is_pending', 'is_expired', 'fog_license_required',
        'media_required_for_fog_maintenance_report', 'city_owned']),
      interceptors,
    }
    return { source_id: String(s.id), payload: { search_item, detail } }
  })
if (records.length < 400) fail(`only ${records.length} organization-135 properties`)

const json = JSON.stringify(records)
const TAG = '$leadsjson$'
if (json.includes(TAG)) fail('the data contains the quoting tag')
const fname = path.basename(file).replace(/[^A-Za-z0-9._-]/g, '')
const sql = `select leads.ingest_quiet('bsi', '${runStart.toISOString()}', ${TAG}${json}${TAG}, '${fname}', ${DRY}) as result;`

const query = (q) => fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: q }),
})
// the API's error text can quote the statement (LINE 1: ...): print its first line only, cut before any quote of it
const safe = (t) => { try { return String(JSON.parse(t)?.message ?? '').split('\n')[0].replace(/LINE \d+:.*$/, '').slice(0, 200) } catch { return '(unreadable reply)' } }

// never send the payload to a database that cannot take it: a missing function fails the statement, and is logged
const pre = await query(`select to_regprocedure('leads.ingest_quiet(text,text,text,text,boolean)') is not null as ok;`)
const preText = await pre.text()
let preOk = false
try { preOk = JSON.parse(preText)?.[0]?.ok === true } catch { /* refused below */ }
if (!pre.ok || !preOk) fail(`leads.ingest_quiet(text,text,text,text,boolean) is not there (HTTP ${pre.status}: ${safe(preText)})`)

console.log(`${DRY ? 'DRY RUN' : 'LIVE LOAD'}: ${records.length} records, run start ${raw.fetched_at}, ` +
  `${records.filter((r) => r.payload.search_item.ccn).length} with a CCN, ` +
  `${records.filter((r) => r.payload.search_item.contact && (r.payload.search_item.contact.name || r.payload.search_item.contact.phone || r.payload.search_item.contact.email)).length} with a contact, ` +
  `${(json.length / 1024).toFixed(0)} KB`)
const t0 = Date.now()
const r = await query(sql)
const text = await r.text()
let res = null
try { res = JSON.parse(text)?.[0]?.result ?? null } catch { /* reported below */ }
if (!r.ok || !res) { console.error(`no answer (HTTP ${r.status}): ${safe(text)}`); process.exit(3) }
console.log(JSON.stringify(res, null, 1))
console.log(`${Date.now() - t0} ms`)
if (res.ok !== true) process.exit(3)
