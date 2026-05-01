// Apply all 6 fixes from the full e2e audit (A-F).
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');
const crypto = require('crypto');

const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
const JOBBER_TOKEN = process.env.JOBBER_ACCESS_TOKEN;
const JOBBER_SECRET = process.env.JOBBER_CLIENT_SECRET;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const AT_WEBHOOK_TOKEN = process.env.AIRTABLE_WEBHOOK_TOKEN;
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
  if (r.status >= 300) throw new Error(`DB ${r.status}: ${r.body.slice(0,400)}`);
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

const sec = (n, t) => console.log(`\n${'═'.repeat(72)}\nFIX ${n}: ${t}\n${'═'.repeat(72)}`);

(async () => {
  // ============================================================
  sec('A', 'Replay 19 missing Jobber visits + investigate 38 stale');
  // ============================================================
  const findings = JSON.parse(fs.readFileSync('audit_findings.json','utf8'));

  // Pull all Jobber visits (fresh)
  console.log('  Fetching all Jobber visits...');
  const jbVisits = [];
  let cur = null;
  while (true) {
    const d = await gql(`query($a:String){visits(after:$a,first:25){pageInfo{hasNextPage endCursor} nodes{id startAt endAt completedAt completedBy visitStatus client{id} job{id} assignedUsers{nodes{id name{full}}}}}}`, { a: cur });
    jbVisits.push(...d.visits.nodes);
    if (!d.visits.pageInfo.hasNextPage) break;
    cur = d.visits.pageInfo.endCursor;
  }
  console.log(`  ${jbVisits.length} Jobber visits pulled`);
  const jbGids = new Set(jbVisits.map(v => v.id));
  const jb2026Gids = new Set(jbVisits.filter(v => (v.startAt || v.endAt || v.completedAt || '').slice(0,10) >= '2026-01-01').map(v => v.id));

  // === A. Replay 19 missing 2026+ visits ===
  const dbVisits = await pg(`SELECT esl.source_id AS gid FROM entity_source_links esl WHERE esl.entity_type='visit' AND esl.source_system='jobber'`);
  const dbGidSet = new Set(dbVisits.map(r => r.gid));
  const missing = [...jb2026Gids].filter(g => !dbGidSet.has(g));
  console.log(`  19-missing-2026 list: ${missing.length} visits`);
  let replayed = 0, replayErrors = 0;
  for (const gid of missing) {
    const numericId = Buffer.from(gid, 'base64').toString().split('/').pop();
    const payload = JSON.stringify({ topic: 'VISIT_UPDATE', webHookEvent: { itemId: gid, occurredAt: new Date().toISOString() } });
    const sig = crypto.createHmac('sha256', JOBBER_SECRET).update(payload).digest('base64');
    const r = await http({
      hostname: SUPABASE_URL.replace(/^https?:\/\//, '').replace(/\/$/, ''),
      path: '/functions/v1/webhook-jobber', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${SVC}`, 'x-jobber-hmac-sha256': sig, 'Content-Length': Buffer.byteLength(payload) },
    }, payload);
    if (r.status >= 300) { replayErrors++; if (replayErrors < 3) console.log(`    ✗ ${gid.slice(0,18)}…: ${r.body.slice(0,120)}`); }
    else replayed++;
  }
  console.log(`  ✓ Replayed ${replayed}/${missing.length} (errors: ${replayErrors})`);

  // === B. Investigate 38 stale-in-DB visits ===
  const stale = dbVisits.filter(r => !jbGids.has(r.gid));
  console.log(`\n  38-stale-in-DB list: ${stale.length} visits`);
  // For each, check if it's in Jobber via individual query (in case visits pagination missed it)
  let confirmedStale = [];
  for (const r of stale.slice(0, 50)) {
    try {
      const d = await gql(`query($id:EncodedId!){visit(id:$id){id startAt visitStatus}}`, { id: r.gid });
      if (!d.visit) confirmedStale.push(r.gid);
    } catch (e) {
      if (e.message.includes('not found')) confirmedStale.push(r.gid);
      else console.log(`    err ${r.gid.slice(0,18)}: ${e.message.slice(0,80)}`);
    }
    await new Promise(rs => setTimeout(rs, 200));
  }
  console.log(`  Confirmed-stale (not in Jobber even by direct query): ${confirmedStale.length}`);
  console.log(`  Hypothesis: stale GIDs from before today's deletes — need cleanup`);

  // ============================================================
  sec('C', 'Re-verify zone/access_hours mismatches (extract object.name)');
  // ============================================================
  const atClients = await airtableAll('Clients');
  const atById = new Map(atClients.map(r => [r.id, r]));
  const props = await pg(`
    SELECT c.id AS client_id, c.client_code,
      (SELECT esl.source_id FROM entity_source_links esl WHERE esl.entity_type='client' AND esl.entity_id=c.id AND esl.source_system='airtable' LIMIT 1) AS at_id,
      p.id AS property_id, p.zone, p.access_hours_start AS hours_in, p.access_hours_end AS hours_out, p.county
    FROM clients c JOIN properties p ON p.client_id=c.id AND p.is_primary=TRUE
    WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='jobber');
  `);

  let updates = [];
  for (const row of props) {
    if (!row.at_id) continue;
    const at = atById.get(row.at_id); if (!at) continue;
    const f = at.fields || {};
    const atZone = (typeof f['Zone'] === 'object' && f['Zone']?.name) ? f['Zone'].name : (typeof f['Zone'] === 'string' ? f['Zone'] : null);
    const atCounty = (typeof f['County'] === 'object' && f['County']?.name) ? f['County'].name : (typeof f['County'] === 'string' ? f['County'] : null);
    const atHi = f['Hours in'] || null;
    const atHo = f['Hours out'] || null;
    const upd = {};
    if (atZone && row.zone !== atZone) upd.zone = atZone;
    if (atCounty && row.county !== atCounty) upd.county = atCounty;
    if (atHi && row.hours_in !== atHi) upd.access_hours_start = atHi;
    if (atHo && row.hours_out !== atHo) upd.access_hours_end = atHo;
    if (Object.keys(upd).length) updates.push({ property_id: row.property_id, code: row.client_code, ...upd });
  }
  console.log(`  ${updates.length} property updates needed (zone/county/hours)`);
  for (const u of updates.slice(0, 5)) console.log(`    ${u.code} prop=${u.property_id} → ${JSON.stringify({zone:u.zone, county:u.county, hi:u.access_hours_start, ho:u.access_hours_end})}`);
  if (updates.length) {
    let n = 0;
    for (const u of updates) {
      const sets = [];
      if (u.zone !== undefined) sets.push(`zone=${u.zone===null?'NULL':"'"+u.zone.replace(/'/g, "''")+"'"}`);
      if (u.county !== undefined) sets.push(`county=${u.county===null?'NULL':"'"+u.county.replace(/'/g, "''")+"'"}`);
      if (u.access_hours_start !== undefined) sets.push(`access_hours_start=${u.access_hours_start===null?'NULL':"'"+u.access_hours_start.replace(/'/g, "''")+"'"}`);
      if (u.access_hours_end !== undefined) sets.push(`access_hours_end=${u.access_hours_end===null?'NULL':"'"+u.access_hours_end.replace(/'/g, "''")+"'"}`);
      await pg(`UPDATE properties SET ${sets.join(', ')} WHERE id=${u.property_id}`);
      n++;
      if (n % 30 === 0) console.log(`    updated ${n}/${updates.length}`);
    }
    console.log(`  ✓ ${n} properties updated`);
  }

  // ============================================================
  sec('D', 'Replay 32 missing Airtable PRE-POST inspections');
  // ============================================================
  const atInsp = await airtableAll('PRE-POST insptection');
  const dbInspIds = new Set((await pg(`SELECT source_id FROM entity_source_links WHERE entity_type='inspection' AND source_system='airtable'`)).map(r => r.source_id));
  const missingInsp = atInsp.filter(r => !dbInspIds.has(r.id));
  console.log(`  ${missingInsp.length} missing PRE-POST records to replay`);
  let inspReplayed = 0, inspErrors = 0;
  for (const rec of missingInsp) {
    const payload = JSON.stringify({ entity: 'inspection', recordId: rec.id, fields: rec.fields, changeType: 'created' });
    const r = await http({
      hostname: SUPABASE_URL.replace(/^https?:\/\//, '').replace(/\/$/, ''),
      path: '/functions/v1/webhook-airtable', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${AT_WEBHOOK_TOKEN}`, 'Content-Length': Buffer.byteLength(payload) },
    }, payload);
    if (r.status >= 300) { inspErrors++; if (inspErrors < 3) console.log(`    ✗ ${rec.id}: ${r.body.slice(0,120)}`); }
    else inspReplayed++;
  }
  console.log(`  ✓ ${inspReplayed}/${missingInsp.length} (errors: ${inspErrors})`);

  // ============================================================
  sec('E', 'Verify Goliath in Samsara');
  // ============================================================
  // Try with includeArchived parameter
  for (const path of ['/fleet/vehicles?limit=100', '/fleet/vehicles?limit=100&includeDecommissioned=true']) {
    const r = await http({ hostname: 'api.samsara.com', path, headers: { Authorization: `Bearer ${SAMSARA_TOKEN}` } });
    if (r.status < 300) {
      const j = JSON.parse(r.body);
      const goliath = (j.data || []).find(v => /goliath/i.test(v.name || ''));
      console.log(`  ${path}: ${(j.data||[]).length} vehicles, Goliath ${goliath ? 'FOUND' : 'NOT FOUND'}`);
      if (goliath) console.log(`    ${JSON.stringify(goliath).slice(0,200)}`);
    } else {
      console.log(`  ${path}: HTTP ${r.status} ${r.body.slice(0,80)}`);
    }
  }

  // ============================================================
  sec('F', 'Find correct Samsara geofences endpoint');
  // ============================================================
  for (const path of ['/fleet/addresses', '/addresses', '/fleet/geofences', '/geofences', '/fleet/locations']) {
    const r = await http({ hostname: 'api.samsara.com', path: path + '?limit=20', headers: { Authorization: `Bearer ${SAMSARA_TOKEN}` } });
    console.log(`  ${path}: HTTP ${r.status} ${r.status<300 ? '✓' : r.body.slice(0,80)}`);
    if (r.status < 300) {
      const j = JSON.parse(r.body);
      console.log(`    Found ${(j.data||[]).length} entries; sample: ${JSON.stringify(j.data?.[0]||{}).slice(0,150)}`);
    }
  }

  console.log('\n' + '═'.repeat(72));
  console.log('  All fixes attempted. Re-run full_e2e_audit.js to verify.');
  console.log('═'.repeat(72));
})().catch(e => { console.error('FATAL:', e.message, e.stack); process.exit(1); });
