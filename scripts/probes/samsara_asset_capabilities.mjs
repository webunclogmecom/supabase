// samsara_asset_capabilities.mjs - what does a Samsara ASSET actually report?
//
// WHY: Fred, 2026-09-03, on a new device fitted to truck Moises: "which helps us to measure better
// things like: Grease, Water, etc. So we need to check with API to see what information we can
// gather." The answer for the tag fitted on 2026-08-20 is "location only", and this probe is the
// re-runnable version of that measurement so nobody has to take it on trust.
//
// 🛑 IT CARRIES ITS OWN POSITIVE CONTROL, AND THAT IS THE POINT. A probe that reports "this device
//    exposes no sensor data" is indistinguishable from a probe pointed at the wrong endpoint or
//    running on a scope-limited token. So it also reads the POWERED vehicles, which must come back
//    with engineState / fuelPercent / obdOdometerMeters. If that control is empty the run says so
//    and exits 2 rather than printing a clean-looking zero.
//
// ⚠ GET /v1/sensors/list returns 200 {"sensors":[]} while POST on the same path returns 401
//    "requires Sensors write permissions". Do NOT read that GET as proof there are no sensors: it
//    is a documented POST route. The org-wide sensor census here comes from /tags instead, which is
//    a genuine read.
//
// Usage: node scripts/probes/samsara_asset_capabilities.mjs [assetId]
import https from 'node:https'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
for (const line of fs.readFileSync(path.join(ROOT, '.env'), 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/)
  if (!m) continue
  let v = m[2].trim()
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1)
  if (!(m[1] in process.env)) process.env[m[1]] = v
}
const TOKEN = process.env.SAMSARA_API_TOKEN
if (!TOKEN) { console.error('SAMSARA_API_TOKEN missing from Supabase/.env'); process.exit(2) }

const get = p => new Promise(res => {
  https.get({ hostname: 'api.samsara.com', path: p, headers: { Authorization: `Bearer ${TOKEN}`, Accept: 'application/json' } },
    r => { let b = ''; r.on('data', d => b += d); r.on('end', () => { let j = null; try { j = JSON.parse(b) } catch {} ; res({ status: r.statusCode, json: j, raw: b }) }) })
    .on('error', e => res({ status: 0, json: null, raw: String(e) }))
})

const ASSET = (process.argv[2] || '281475005688801').trim()
const DAYS = 14
const end = Date.now(), start = end - DAYS * 864e5
let failures = 0

console.log(`\n=== Samsara asset ${ASSET} - what can we actually read? ===\n`)

// 1. the asset record
const assets = await get('/assets?limit=100')
const a = (assets.json?.data || []).find(x => x.id === ASSET)
if (!a) { console.error(`asset ${ASSET} not found in /assets`); process.exit(2) }
console.log(`asset      : ${a.name}  (type=${a.type}, readingsIngestionEnabled=${a.readingsIngestionEnabled})`)

// 2. the hardware behind it
const gws = await get('/gateways?limit=100')
const gw = (gws.json?.data || []).find(g => g.asset?.id === ASSET)
console.log(`gateway    : ${gw ? `${gw.serial}  model=${gw.model}  lastConnected=${gw.connectionStatus?.lastConnected}` : 'NONE'}`)

// 3. THE ANSWER: every distinct field the asset emits over the window
const loc = await get(`/v1/fleet/assets/${ASSET}/locations?startMs=${start}&endMs=${end}`)
const pts = loc.json?.locations || []
const fields = new Set()
for (const p of pts) for (const k of Object.keys(p)) fields.add(k)
console.log(`\nlocation history: ${pts.length} points over ${DAYS}d`)
console.log(`FIELDS EMITTED  : ${[...fields].sort().join(', ') || '(none)'}`)
const constant = [...fields].filter(f => f !== 'time' && new Set(pts.map(p => p[f])).size === 1)
if (constant.length) console.log(`constant (placeholder, not a reading): ${constant.join(', ')}`)

// 4. org-wide sensor census, via a route that is a real GET
const tags = await get('/tags?limit=200')
const sensors = (tags.json?.data || []).reduce((n, t) => n + (t.sensors?.length || 0), 0)
const ind = await get('/v1/industrial/data')
console.log(`\norg sensors (via /tags)      : ${sensors}`)
console.log(`industrial data inputs       : ${(ind.json?.dataInputs || []).length}`)

// 5. POSITIVE CONTROL - the same token, the same API, hardware that DOES produce telemetry
const vs = await get('/fleet/vehicles/stats?types=gps,engineStates,fuelPercents,obdOdometerMeters')
const ctl = (vs.json?.data || []).filter(v => v.engineState && v.fuelPercent !== undefined && v.obdOdometerMeters)
console.log(`\nCONTROL: powered vehicles returning engineState+fuelPercent+odometer: ${ctl.length}`)
if (ctl.length === 0) {
  console.error('CONTROL FAILED: the token or the endpoint is not returning telemetry it should.')
  console.error('The asset result above proves NOTHING. Do not report it as a clean zero.')
  failures++
} else {
  console.log(`  ${ctl.map(v => v.name).join(', ')}  <- non-GPS telemetry does come through when the hardware makes it`)
}

// The verdict prints ONLY when the control held. Printing it under a failed control is exactly
// the false all-clear this header warns about, and the first version of this file did it.
if (failures) {
  console.error('\nNO VERDICT: the control failed, so this run measured nothing.')
  process.exit(2)
}
console.log(`\nVERDICT: this asset emits ${[...fields].sort().join(', ')} and nothing else.`)
process.exit(0)
