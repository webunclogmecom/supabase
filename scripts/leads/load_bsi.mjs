// Load a BSI Online scrape into the frozen-leads schema (Trello #165 / #166, plan section 8.2).
//
//   node --env-file=.env scripts/leads/load_bsi.mjs <raw.json> [--dry-run]
//
// <raw.json> is the output of scripts/leads/bsi_boca_scrape.mjs (kept in the workspace backups/ folder, never a repo).
// It refuses a file that is not complete, has fewer than 400 properties, or lacks the control (Grove Kosher, BSI 957372,
// with interceptors 9818 and 9819). It keeps organization 135 (City of Boca Raton Utility Services) and an allow-list of
// fields, sorts each property's interceptors by id, and calls leads.ingest('bsi', <run start>, records, <file>) once.
// CCNs and BSI's contact stay in the private payload (Fred 2026-11-03); no granted view shows them.
// --dry-run runs the same call inside a DO block that always fails at the end, so nothing is kept, and prints what the
// load would produce (states, review items, view counts).
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
    return { source_id: String(s.id), source_name: s.label ?? null, payload: { search_item, detail } }
  })
if (records.length < 400) fail(`only ${records.length} organization-135 properties`)

const json = JSON.stringify(records)
const TAG = '$leadsjson$'
if (json.includes(TAG)) fail('the data contains the quoting tag')
const fname = path.basename(file).replace(/'/g, '')
const call = `leads.ingest('bsi', '${new Date(raw.fetched_at).toISOString()}'::timestamptz, ${TAG}${json}${TAG}::jsonb, '${fname}')`
const sql = DRY
  ? `do $dry$ declare r jsonb; begin
       r := ${call};
       raise exception 'dryrun_result:%', jsonb_build_object(
         'ingest', r,
         'states', (select jsonb_object_agg(lead_state, n) from (select lead_state, count(*) n from leads.v_establishment_state group by 1) s),
         'frozen_rows', (select count(*) from public.v_frozen_leads),
         'interceptor_rows', (select count(*) from public.v_lead_interceptors),
         'review', (select jsonb_agg(jsonb_build_object('kind', kind, 'bsi', source_id, 'name', source_name, 'client', client_code,
                      'property', property_id, 'on', matched_on, 'score', name_score) order by kind, client_code, source_id)
                      from public.v_lead_review));
     end $dry$;`
  : `select ${call} as result;`

console.log(`${DRY ? 'DRY RUN' : 'LIVE LOAD'}: ${records.length} records, run start ${raw.fetched_at}, ` +
  `${records.filter((r) => r.payload.search_item.ccn).length} with a CCN, ` +
  `${records.filter((r) => r.payload.search_item.contact && (r.payload.search_item.contact.name || r.payload.search_item.contact.phone || r.payload.search_item.contact.email)).length} with a contact, ` +
  `${(json.length / 1024).toFixed(0)} KB`)
const r = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: sql }),
})
const text = await r.text()
if (DRY) {
  let msg = ''
  try { msg = JSON.parse(text).message ?? '' } catch { msg = text }
  const at = msg.indexOf('dryrun_result:')
  if (at < 0) { console.error(`dry run did not report (HTTP ${r.status}): ${text.slice(0, 600)}`); process.exit(3) }
  const rest = msg.slice(at + 'dryrun_result:'.length)
  const res = JSON.parse(rest.includes('\n') ? rest.slice(0, rest.indexOf('\n')) : rest)
  console.log(JSON.stringify(res, null, 1))
} else {
  console.log(`HTTP ${r.status}: ${text.slice(0, 600)}`)
  if (!r.ok) process.exit(3)
}
