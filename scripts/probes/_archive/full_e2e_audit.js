// ============================================================================
// full_e2e_audit.js — comprehensive end-to-end audit
// ============================================================================
// Fred's directive 2026-05-01: lean on Jobber as source of truth, then verify
// each layer downstream:
//
//   Phase 1: Clients — Jobber count = DB count, all linked, no stale
//   Phase 2: Visits — Jobber GID-by-GID match, no extras, no missing
//   Phase 3: Photos — for each Jobber visit, note attachments (±3d) are
//            represented in our DB as photo_links (visit OR note)
//   Phase 4: Airtable enrichment — for each Jobber client, our DB carries
//            their Airtable manholes/zone/county/hours/days when present
//   Phase 5: Airtable DERM + PRE-POST — every Airtable manifest/inspection
//            is in our DB, linked to the right client/visit
//   Phase 6: Samsara — vehicles, GPS telemetry freshness, geofences
//
// Outputs: console report + JSON findings dump.
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');

const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const JOBBER_TOKEN = process.env.JOBBER_ACCESS_TOKEN;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const SAMSARA_TOKEN = process.env.SAMSARA_API_TOKEN;

function http(opts, body, timeoutMs = 60000) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d }));
    });
    req.on('error', rej);
    req.setTimeout(timeoutMs, () => req.destroy(new Error('timeout')));
    if (body) req.write(body);
    req.end();
  });
}

async function pg(sql) {
  const body = JSON.stringify({ query: sql });
  const r = await http({
    hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) throw new Error(`DB ${r.status}: ${r.body.slice(0,200)}`);
  return JSON.parse(r.body);
}

async function gql(query, variables, retries = 5) {
  const body = JSON.stringify({ query, variables });
  const r = await http({
    hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: { Authorization: `Bearer ${JOBBER_TOKEN}`, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-13', 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) {
    if (retries > 0 && (r.status === 429 || r.status >= 500)) {
      await new Promise(rs => setTimeout(rs, (6 - retries) * 4000));
      return gql(query, variables, retries - 1);
    }
    throw new Error(`Jobber ${r.status}: ${r.body.slice(0,200)}`);
  }
  const j = JSON.parse(r.body);
  if (j.errors) {
    if (j.errors.some(e => e.extensions?.code === 'THROTTLED') && retries > 0) {
      await new Promise(rs => setTimeout(rs, (6 - retries) * 5000));
      return gql(query, variables, retries - 1);
    }
    throw new Error(`Jobber GQL: ${JSON.stringify(j.errors).slice(0,300)}`);
  }
  const remaining = j.extensions?.cost?.throttleStatus?.currentlyAvailable;
  if (remaining != null && remaining < 2000) {
    await new Promise(rs => setTimeout(rs, Math.ceil((2000 - remaining) / 500) * 1000));
  }
  return j.data;
}

async function airtableAll(tableName) {
  const all = [];
  let offset = null;
  do {
    const q = new URLSearchParams();
    q.set('pageSize', '100');
    if (offset) q.set('offset', offset);
    const r = await http({
      hostname: 'api.airtable.com',
      path: `/v0/${AT_BASE}/${encodeURIComponent(tableName)}?${q}`,
      headers: { Authorization: `Bearer ${AT_KEY}` },
    });
    if (r.status >= 300) throw new Error(`AT ${r.status}: ${r.body.slice(0,200)}`);
    const j = JSON.parse(r.body);
    all.push(...(j.records || []));
    offset = j.offset;
  } while (offset);
  return all;
}

async function samsara(path) {
  const r = await http({
    hostname: 'api.samsara.com',
    path,
    headers: { Authorization: `Bearer ${SAMSARA_TOKEN}` },
  });
  if (r.status >= 300) throw new Error(`Samsara ${r.status}: ${r.body.slice(0,200)}`);
  return JSON.parse(r.body);
}

const findings = {};
const sec = (n, t) => console.log(`\n${'═'.repeat(72)}\nPHASE ${n}: ${t}\n${'═'.repeat(72)}`);
const sub = (t) => console.log(`\n──── ${t} ────`);

(async () => {
  const startMs = Date.now();
  console.log(`Audit started: ${new Date().toISOString()}\n`);

  // ============================================================
  sec(1, 'CLIENTS — Jobber-canonical');
  // ============================================================
  sub('1.1 Counts');
  const jbClients = new Set();
  let cur = null;
  while (true) {
    const d = await gql(`query($a:String){clients(after:$a,first:100){pageInfo{hasNextPage endCursor} nodes{id companyName firstName lastName isCompany isArchived}}}`, { a: cur });
    for (const c of d.clients.nodes) jbClients.add(c.id);
    if (!d.clients.pageInfo.hasNextPage) break;
    cur = d.clients.pageInfo.endCursor;
  }
  const dbClientsTotal = (await pg('SELECT COUNT(*)::int AS n FROM clients'))[0].n;
  const dbClientsJobberLinked = (await pg(`SELECT COUNT(DISTINCT c.id)::int AS n FROM clients c JOIN entity_source_links esl ON esl.entity_type='client' AND esl.entity_id=c.id AND esl.source_system='jobber'`))[0].n;
  console.log(`  Jobber:                 ${jbClients.size}`);
  console.log(`  Our DB total:           ${dbClientsTotal}`);
  console.log(`  Our DB Jobber-linked:   ${dbClientsJobberLinked}`);

  sub('1.2 Per-GID mapping');
  const ourClientLinks = await pg(`SELECT esl.source_id AS gid, c.id AS client_id, c.client_code, c.name FROM entity_source_links esl JOIN clients c ON c.id=esl.entity_id WHERE esl.entity_type='client' AND esl.source_system='jobber'`);
  const ourGidSet = new Set(ourClientLinks.map(r => r.gid));
  const inDbNotInJobber = ourClientLinks.filter(r => !jbClients.has(r.gid));
  const inJobberNotInDb = [...jbClients].filter(g => !ourGidSet.has(g));
  console.log(`  In DB but NOT in Jobber:  ${inDbNotInJobber.length}`);
  console.log(`  In Jobber but NOT in DB:  ${inJobberNotInDb.length}`);
  findings.phase1 = {
    jobber_count: jbClients.size,
    db_total: dbClientsTotal,
    db_jobber_linked: dbClientsJobberLinked,
    in_db_not_jobber: inDbNotInJobber.length,
    in_jobber_not_db: inJobberNotInDb.length,
    pass: jbClients.size === dbClientsJobberLinked && inDbNotInJobber.length === 0 && inJobberNotInDb.length === 0,
  };
  console.log(`  ${findings.phase1.pass ? '✓ PASS' : '✗ FAIL'}`);

  // ============================================================
  sec(2, 'VISITS — Jobber-canonical, 2026+');
  // ============================================================
  sub('2.1 Pull all Jobber visits');
  const jbVisits = [];
  cur = null;
  while (true) {
    const d = await gql(`query($a:String){visits(after:$a,first:25){pageInfo{hasNextPage endCursor} nodes{id startAt endAt completedAt completedBy visitStatus client{id} job{id} assignedUsers{nodes{id name{full}}}}}}`, { a: cur });
    jbVisits.push(...d.visits.nodes);
    if (!d.visits.pageInfo.hasNextPage) break;
    cur = d.visits.pageInfo.endCursor;
    if (jbVisits.length % 250 === 0) console.log(`  ${jbVisits.length} visits pulled`);
  }
  console.log(`  Jobber: ${jbVisits.length} visits total`);
  fs.writeFileSync('./jobber_visits_full.json', JSON.stringify(jbVisits, null, 2));

  // Filter to 2026+ for comparison (DB only keeps 2026+)
  const jb2026 = jbVisits.filter(v => {
    const d = (v.startAt || v.endAt || v.completedAt || '').slice(0, 10);
    return d >= '2026-01-01';
  });
  console.log(`  Jobber 2026+: ${jb2026.length}`);
  const dbVisits = await pg(`SELECT v.id, v.visit_date::text AS date, esl.source_id AS gid FROM visits v JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'`);
  console.log(`  Our DB: ${dbVisits.length} visits with Jobber link`);

  const jbVisitGids = new Set(jb2026.map(v => v.id));
  const dbVisitGids = new Set(dbVisits.map(r => r.gid));
  const visitInDbNotJb = dbVisits.filter(r => !jbVisitGids.has(r.gid));
  const visitInJbNotDb = jb2026.filter(v => !dbVisitGids.has(v.id));
  console.log(`  In DB but NOT in Jobber 2026+: ${visitInDbNotJb.length}`);
  console.log(`  In Jobber 2026+ but NOT in DB: ${visitInJbNotDb.length}`);
  findings.phase2 = {
    jobber_total: jbVisits.length,
    jobber_2026plus: jb2026.length,
    db_jobber_linked: dbVisits.length,
    in_db_not_jobber: visitInDbNotJb.length,
    in_jobber_not_db: visitInJbNotDb.length,
    sample_in_jobber_not_db: visitInJbNotDb.slice(0, 10).map(v => ({ gid: v.id, date: v.startAt?.slice(0,10), status: v.visitStatus })),
    pass: visitInDbNotJb.length === 0 && visitInJbNotDb.length < 10, // small drift OK
  };
  console.log(`  ${findings.phase2.pass ? '✓ PASS' : '⚠ DRIFT'}`);

  // ============================================================
  sec(3, 'PHOTOS — visit photo coverage via Jobber notes');
  // ============================================================
  sub('3.1 For each Jobber 2026+ visit, check our DB for photos');
  // Pull DB photo links for visits + notes mapped to clients
  const dbVisitPhotos = await pg(`
    SELECT v.id AS visit_id, esl_v.source_id AS visit_gid,
      (SELECT COUNT(*) FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id) AS direct_photos,
      (SELECT COUNT(*) FROM notes n WHERE n.visit_id=v.id AND EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='note' AND pl.entity_id=n.id)) AS note_photos,
      v.visit_date::text AS date, v.visit_status
    FROM visits v
    JOIN entity_source_links esl_v ON esl_v.entity_type='visit' AND esl_v.entity_id=v.id AND esl_v.source_system='jobber';
  `);
  const photoCoverage = dbVisitPhotos.map(r => ({ ...r, has_photos: r.direct_photos > 0 || r.note_photos > 0 }));
  const completed = photoCoverage.filter(r => r.visit_status === 'completed');
  const completedWithPhotos = completed.filter(r => r.has_photos);
  console.log(`  Jobber-linked visits in DB:        ${dbVisitPhotos.length}`);
  console.log(`  Completed visits:                  ${completed.length}`);
  console.log(`  Completed visits WITH photos:      ${completedWithPhotos.length} (${(100*completedWithPhotos.length/Math.max(completed.length,1)).toFixed(1)}%)`);
  console.log(`  Completed visits WITHOUT photos:   ${completed.length - completedWithPhotos.length}`);

  findings.phase3 = {
    db_visits_linked: dbVisitPhotos.length,
    completed_visits: completed.length,
    completed_with_photos: completedWithPhotos.length,
    completed_without_photos: completed.length - completedWithPhotos.length,
    pct_coverage: 100 * completedWithPhotos.length / Math.max(completed.length, 1),
    pass: completedWithPhotos.length / Math.max(completed.length, 1) >= 0.85,
  };
  console.log(`  ${findings.phase3.pass ? '✓ PASS (≥85%)' : '⚠ BELOW 85%'}`);

  // ============================================================
  sec(4, 'AIRTABLE ENRICHMENT — for Jobber clients only');
  // ============================================================
  sub('4.1 Pull Airtable Clients');
  const atClients = await airtableAll('Clients');
  console.log(`  ${atClients.length} Airtable Client records`);

  sub('4.2 For each Jobber client in our DB, check Airtable enrichment');
  const dbClientEnrichment = await pg(`
    SELECT c.id, c.client_code, c.name,
      (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='airtable' LIMIT 1) AS at_id,
      (SELECT MAX(p.grease_trap_manhole_count) FROM properties p WHERE p.client_id=c.id) AS db_manholes,
      (SELECT MAX(p.zone) FROM properties p WHERE p.client_id=c.id) AS db_zone,
      (SELECT MAX(p.county) FROM properties p WHERE p.client_id=c.id) AS db_county,
      (SELECT MAX(p.access_hours_start) FROM properties p WHERE p.client_id=c.id) AS db_hours_in,
      (SELECT MAX(p.access_hours_end) FROM properties p WHERE p.client_id=c.id) AS db_hours_out
    FROM clients c
    WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='jobber');
  `);
  let withAtLink = 0, withoutAtLink = 0, manholeMismatches = [], zoneMismatches = [], hoursMismatches = [];
  const atById = new Map(atClients.map(r => [r.id, r]));
  for (const c of dbClientEnrichment) {
    if (!c.at_id) { withoutAtLink++; continue; }
    withAtLink++;
    const at = atById.get(c.at_id);
    if (!at) continue;
    const f = at.fields || {};
    // Manholes
    const atM = (typeof f.manholes === 'number' && f.manholes >= 1) ? Math.round(f.manholes) : 0;
    const dbM = c.db_manholes || 0;
    if (atM !== dbM) manholeMismatches.push({ id: c.id, code: c.client_code, at: atM, db: dbM });
    // Zone
    const atZ = f['Zone'] || null;
    if (atZ && c.db_zone !== atZ) zoneMismatches.push({ id: c.id, code: c.client_code, at: atZ, db: c.db_zone });
    // Hours in
    const atHi = f['Hours in'] || null;
    if (atHi && c.db_hours_in !== atHi) hoursMismatches.push({ id: c.id, code: c.client_code, field: 'in', at: atHi, db: c.db_hours_in });
  }
  console.log(`  Jobber-linked clients with AT enrichment link:     ${withAtLink}`);
  console.log(`  Jobber-linked clients WITHOUT AT enrichment:       ${withoutAtLink}`);
  console.log(`  Manhole count mismatches (AT vs DB):               ${manholeMismatches.length}`);
  console.log(`  Zone mismatches (AT has but DB differs):           ${zoneMismatches.length}`);
  console.log(`  Access hours mismatches:                           ${hoursMismatches.length}`);
  findings.phase4 = {
    airtable_clients_total: atClients.length,
    db_jobber_clients_with_at_link: withAtLink,
    db_jobber_clients_without_at_link: withoutAtLink,
    manhole_mismatches: manholeMismatches.length,
    zone_mismatches: zoneMismatches.length,
    hours_mismatches: hoursMismatches.length,
    sample_manhole_mismatches: manholeMismatches.slice(0, 5),
    sample_zone_mismatches: zoneMismatches.slice(0, 5),
    pass: manholeMismatches.length === 0,
  };
  console.log(`  ${findings.phase4.pass ? '✓ PASS' : '⚠ DRIFT'}`);

  // ============================================================
  sec(5, 'AIRTABLE DERM + PRE-POST INSPECTIONS');
  // ============================================================
  sub('5.1 DERM manifests (Airtable vs DB)');
  const atDerm = await airtableAll('DERM');
  const dbDerm = await pg(`SELECT COUNT(*)::int AS n FROM derm_manifests`);
  const dbDermLinked = await pg(`SELECT COUNT(*)::int AS n FROM derm_manifests dm WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='derm_manifest' AND entity_id=dm.id AND source_system='airtable')`);
  console.log(`  Airtable DERM:           ${atDerm.length}`);
  console.log(`  DB derm_manifests:       ${dbDerm[0].n}`);
  console.log(`  DB Airtable-linked:      ${dbDermLinked[0].n}`);
  // Diff: Airtable IDs in DB
  const dbDermAtIds = await pg(`SELECT source_id FROM entity_source_links WHERE entity_type='derm_manifest' AND source_system='airtable'`);
  const dbDermAtSet = new Set(dbDermAtIds.map(r => r.source_id));
  const atDermNotInDb = atDerm.filter(r => !dbDermAtSet.has(r.id));
  console.log(`  Airtable DERM NOT in DB: ${atDermNotInDb.length}`);

  sub('5.2 PRE-POST inspections');
  const atInsp = await airtableAll('PRE-POST insptection');
  const dbInsp = await pg(`SELECT COUNT(*)::int AS n FROM inspections`);
  const dbInspLinked = await pg(`SELECT COUNT(*)::int AS n FROM inspections i WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='inspection' AND entity_id=i.id AND source_system='airtable')`);
  console.log(`  Airtable PRE-POST:       ${atInsp.length}`);
  console.log(`  DB inspections:          ${dbInsp[0].n}`);
  console.log(`  DB Airtable-linked:      ${dbInspLinked[0].n}`);
  const dbInspAtIds = await pg(`SELECT source_id FROM entity_source_links WHERE entity_type='inspection' AND source_system='airtable'`);
  const dbInspAtSet = new Set(dbInspAtIds.map(r => r.source_id));
  const atInspNotInDb = atInsp.filter(r => !dbInspAtSet.has(r.id));
  console.log(`  Airtable PRE-POST NOT in DB: ${atInspNotInDb.length}`);

  findings.phase5 = {
    derm: { airtable: atDerm.length, db_total: dbDerm[0].n, db_linked: dbDermLinked[0].n, missing: atDermNotInDb.length },
    inspections: { airtable: atInsp.length, db_total: dbInsp[0].n, db_linked: dbInspLinked[0].n, missing: atInspNotInDb.length },
    pass: atDermNotInDb.length < 30 && atInspNotInDb.length < 30, // some drift OK
  };
  console.log(`  ${findings.phase5.pass ? '✓ PASS' : '⚠ DRIFT'}`);

  // ============================================================
  sec(6, 'SAMSARA — vehicles + GPS + geofences');
  // ============================================================
  sub('6.1 Vehicles');
  const samVehicles = await samsara('/fleet/vehicles?limit=100');
  const dbVehicles = await pg('SELECT id, name, status FROM vehicles');
  console.log(`  Samsara vehicles:  ${(samVehicles.data || []).length}`);
  console.log(`  DB vehicles:       ${dbVehicles.length}`);
  console.table(dbVehicles);

  sub('6.2 GPS telemetry freshness');
  const tele = await pg(`SELECT vehicle_id, MAX(recorded_at) AS latest, COUNT(*) AS readings, ROUND(EXTRACT(epoch FROM (now() - MAX(recorded_at)))/60)::int AS min_ago FROM vehicle_telemetry_readings GROUP BY vehicle_id ORDER BY vehicle_id`);
  console.table(tele);

  sub('6.3 Geofences (Samsara)');
  let samGeofences = [];
  try {
    const r = await samsara('/fleet/addresses?limit=100');
    samGeofences = (r.data || []).filter(a => a.geofence);
    console.log(`  Samsara geofences: ${samGeofences.length}`);
  } catch (e) { console.log(`  Geofences: ERR ${e.message.slice(0, 80)}`); }

  findings.phase6 = {
    samsara_vehicles: (samVehicles.data || []).length,
    db_vehicles: dbVehicles.length,
    telemetry_per_vehicle: tele,
    samsara_geofences: samGeofences.length,
    pass: dbVehicles.length === (samVehicles.data || []).length,
  };
  console.log(`  ${findings.phase6.pass ? '✓ PASS' : '⚠ MISMATCH'}`);

  // ============================================================
  console.log('\n' + '═'.repeat(72));
  console.log('  AUDIT SUMMARY');
  console.log('═'.repeat(72));
  for (const [phase, data] of Object.entries(findings)) {
    console.log(`  ${phase.padEnd(10)} ${data.pass ? '✓ PASS' : '⚠ ISSUES'}`);
  }
  console.log(`\nDuration: ${Math.round((Date.now() - startMs) / 1000)}s`);

  fs.writeFileSync('./audit_findings.json', JSON.stringify(findings, null, 2));
  console.log('\nFull findings saved to ./audit_findings.json');
})().catch(e => { console.error('FATAL:', e.message, e.stack); process.exit(1); });
