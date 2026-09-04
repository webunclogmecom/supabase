// samsara_level_sensors.mjs - enumerate EVERY Samsara level sensor and what it currently reads.
//
// WHY: Fred, 2026-09-04: "For now the sensor only covers Grease, they haven't installed the one for
// water yet. Document it so later on we can work with this info." So this deliberately does NOT
// hardcode the grease sensor's asset id. It discovers level sensors by asking which assets return
// levelMonitoring readings, so the day the WATER unit is fitted it shows up here with no code change.
//
// Run it when a new sensor is installed, or to check what the fleet is reporting right now:
//   cd Supabase && node scripts/probes/samsara_level_sensors.mjs
//
// 🛑 THE SCOPE TRAP THIS EXISTS TO PREVENT. On 2026-09-03 a probe concluded this hardware reports
//    "location only". It was wrong. Every /readings/* call was returning
//    401 "Token requires Readings read permissions", and /readings/* is the ONLY surface carrying
//    fill level. That probe HAD a positive control, and the control passed, because it exercised
//    VEHICLE STATS - a different permission on a different endpoint family from the question.
//    ⇒ A positive control only licenses a zero if it traverses the SAME scope, endpoint family and
//      entity type as the claim. This file therefore checks the Readings scope explicitly FIRST and
//      refuses to report anything if it is missing, rather than printing a clean-looking zero.
//
// ⚠ READINGS ARE IN LITRES (and metres). Multiply by 0.264172 for US gallons. The dashboard shows
//   gallons, so a raw API number will look ~3.8x too big if you forget.
import https from 'node:https'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
for (const line of fs.readFileSync(path.join(ROOT, '.env'), 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/); if (!m) continue
  let v = m[2].trim()
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1)
  if (!(m[1] in process.env)) process.env[m[1]] = v
}
const T = process.env.SAMSARA_API_TOKEN
if (!T) { console.error('SAMSARA_API_TOKEN missing from Supabase/.env'); process.exit(2) }

const get = p => new Promise(res => {
  https.get({ hostname: 'api.samsara.com', path: p, headers: { Authorization: 'Bearer ' + T, Accept: 'application/json' } },
    r => { let b = ''; r.on('data', d => b += d); r.on('end', () => { let j = null; try { j = JSON.parse(b) } catch {}; res({ status: r.statusCode, json: j, raw: b }) }) })
    .on('error', e => res({ status: 0, json: null, raw: String(e) }))
})
const L2G = 0.264172052
const gal = l => (l * L2G)

// --- 0. SCOPE GATE. Same endpoint family and entity type as every claim below.
const gate = await get('/readings/definitions?limit=1')
if (gate.status === 401) {
  console.error('\n🛑 TOKEN LACKS THE READINGS SCOPE. This run measured NOTHING.')
  console.error('   ' + (gate.json?.message || gate.raw.slice(0, 160)))
  console.error('   A 401 is returned BEFORE any data lookup, so it cannot tell you whether level')
  console.error('   data exists. The honest state is UNKNOWN, never "no sensor data".')
  console.error('   Fix: Samsara dashboard > Settings > API Tokens > grant Read Readings.')
  process.exit(2)
}
if (gate.status !== 200) { console.error(`/readings/definitions -> HTTP ${gate.status}: ${gate.raw.slice(0, 160)}`); process.exit(2) }

// --- 1. the level-monitoring reading catalogue (paged)
let defs = [], cursor = '', pages = 0
do {
  const r = await get(`/readings/definitions?limit=100${cursor ? `&after=${encodeURIComponent(cursor)}` : ''}`)
  defs.push(...(r.json?.data || []))
  cursor = r.json?.pagination?.hasNextPage ? r.json.pagination.endCursor : ''
  pages++
} while (cursor && pages < 40)
const level = defs.filter(d => d.category === 'levelMonitoring' && d.entityType === 'asset')
if (level.length === 0) { console.error('CONTROL FAILED: 0 levelMonitoring definitions in a catalogue of ' + defs.length); process.exit(2) }

// --- 2. every asset, then ask each one for a fill reading
const assets = (await get('/assets?limit=200')).json?.data || []
const gateways = (await get('/gateways?limit=200')).json?.data || []
const gwFor = id => gateways.find(g => g.asset?.id === id)

const PROBE = ['fillVolume', 'fillPercent', 'totalCapacityVolume', 'remoteSensingDistance', 'fillCriticality']
const found = []
for (const a of assets) {
  const r = await get(`/readings/latest?readingIds=${PROBE.join(',')}&entityType=asset&entityIds=${a.id}`)
  const vals = {}
  for (const row of r.json?.data || []) if ('value' in row) vals[row.readingId] = { v: row.value, at: row.happenedAtTime }
  if (vals.fillVolume === undefined && vals.totalCapacityVolume === undefined) continue
  found.push({ asset: a, gw: gwFor(a.id), vals })
}

console.log(`\n=== Samsara LEVEL SENSORS (${found.length} found across ${assets.length} assets) ===\n`)
for (const f of found) {
  const cap = f.vals.totalCapacityVolume?.v, vol = f.vals.fillVolume?.v
  console.log(`${f.asset.name}`)
  console.log(`  asset ${f.asset.id}   type=${f.asset.type}   gateway=${f.gw ? f.gw.model + ' ' + f.gw.serial : 'NONE'}`)
  console.log(`  created ${f.asset.createdAtTime}`)
  if (cap !== undefined) console.log(`  capacity      ${cap.toFixed(1)} L  =  ${gal(cap).toFixed(0)} gal`)
  if (vol !== undefined) console.log(`  current fill  ${vol.toFixed(1)} L  =  ${gal(vol).toFixed(0)} gal   (${f.vals.fillPercent?.v ?? '?'}%)  @${f.vals.fillVolume.at}`)
  if (f.vals.remoteSensingDistance) console.log(`  radar distance ${f.vals.remoteSensingDistance.v} m`)
  if (f.vals.fillCriticality) console.log(`  criticality   ${f.vals.fillCriticality.v}`)
  console.log('')
}

// --- 3. POSITIVE CONTROL, same scope/family/entity as the claim above.
// The grease sensor is known to exist and to report. If the sweep cannot see IT, the sweep is
// broken and its count means nothing - do not read a low number as "no new sensor yet".
const GREASE = '281475005688801'   // "Moises Sludge Sensor", LM11 GZ8K-E8N-PVX, grease tank, fitted 2026-08-20
if (!found.some(f => f.asset.id === GREASE)) {
  console.error('🛑 CONTROL FAILED: the known grease sensor ' + GREASE + ' did not appear.')
  console.error('   The discovery sweep is broken. Its count is NOT evidence about any other sensor.')
  process.exit(2)
}
console.log(`control OK: the known grease sensor ${GREASE} was discovered by the same sweep.`)

// --- 4. what is still missing, stated as a fact rather than left implicit
console.log(`\nEXPECTED BUT NOT YET INSTALLED: a second unit for the WATER tank on Moises.`)
console.log(`Fred, 2026-09-04: "they haven't installed the one for water yet."`)
if (found.length >= 2) {
  console.log(`\n⚠ ${found.length} level sensors now report. If the water unit has been fitted:`)
  console.log(`  - map its asset id to a vehicle AND a compartment (see docs/reference/samsara-lm11-level-monitor.md)`)
  console.log(`  - do NOT identify it by NAME; names are free text and get edited`)
  console.log(`  - vehicles has no water_tank_capacity_gallons column yet; one is needed`)
}
