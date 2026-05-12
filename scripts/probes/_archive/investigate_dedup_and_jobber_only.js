// Two-part investigation:
//   A. Pull the 79 duplicate-address groups (from weekly dedup audit) and show
//      whether they're real duplicates (same client, multiple property rows)
//      or false positives (different clients legitimately at the same address —
//      shared building, chain stores, etc).
//   B. Pull the Jobber-completed visits with no matching AT row, filter to
//      post-2026, classify by visit.title pattern to separate emergency/service
//      calls (expected Jobber-only) from real misses.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const AT_KEY  = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  for (let i = 0; i < 3; i++) {
    const r = await http({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, JSON.stringify({ query: sql }));
    if (r.status < 300) return JSON.parse(r.body);
    if (r.status >= 500 || r.status === 429) { await new Promise(rs => setTimeout(rs, 4000 * (i+1))); continue; }
    throw new Error(`PG ${r.status}: ${r.body.slice(0, 200)}`);
  }
  throw new Error('5xx');
}
async function listAirtable(table, fields, filter) {
  const out = []; let offset; const enc = encodeURIComponent;
  do {
    const fp = (fields || []).map(f => `fields%5B%5D=${enc(f)}`).join('&');
    const ff = filter ? `&filterByFormula=${enc(filter)}` : '';
    const path = `/v0/${AT_BASE}/${enc(table)}?${fp}&pageSize=100${ff}${offset ? `&offset=${enc(offset)}` : ''}`;
    const r = await http({ hostname: 'api.airtable.com', path, method: 'GET',
      headers: { Authorization: `Bearer ${AT_KEY}` } });
    if (r.status >= 300) throw new Error(`Airtable ${table} ${r.status}: ${r.body.slice(0, 200)}`);
    const j = JSON.parse(r.body);
    for (const rec of (j.records || [])) out.push({ id: rec.id, ...rec.fields });
    offset = j.offset;
  } while (offset);
  return out;
}

(async () => {
  // ============================================================================
  // PART A — Duplicate addresses
  // ============================================================================
  console.log('============================================================');
  console.log('PART A — Duplicate primary-property addresses (post-2026 active clients only)');
  console.log('============================================================\n');

  const dups = await pg(`
    WITH norm AS (
      SELECT p.client_id, p.address AS raw_address, c.name AS client_name,
        c.client_code, c.status AS client_status,
        regexp_replace(LOWER(TRIM(p.address)), '[^a-z0-9]+', ' ', 'g') AS norm_addr
      FROM properties p JOIN clients c ON c.id = p.client_id
      WHERE p.is_primary = TRUE AND p.address IS NOT NULL AND p.address <> ''
    )
    SELECT
      norm_addr,
      ARRAY_AGG(client_id ORDER BY client_id) AS client_ids,
      ARRAY_AGG(client_code ORDER BY client_id) AS codes,
      ARRAY_AGG(client_name ORDER BY client_id) AS names,
      ARRAY_AGG(client_status ORDER BY client_id) AS statuses,
      ARRAY_AGG(raw_address ORDER BY client_id) AS raw_addrs
    FROM norm GROUP BY norm_addr HAVING COUNT(*) > 1
    ORDER BY norm_addr;
  `);

  console.log(`Total duplicate address groups: ${dups.length}\n`);

  // Classify
  const trueDupes = [];     // same client_name (or close) → real duplicate
  const chainSiblings = []; // different client names + same chain prefix (TCE, La Granja, Pura Vida, etc.)
  const sharedBuilding = []; // different clients, different names — legitimately at same address
  const inactiveMix = [];    // one of them is INACTIVE

  for (const d of dups) {
    const names = d.names;
    const statuses = d.statuses;
    const codes = d.codes;
    const firstName = names[0].toLowerCase().replace(/[^a-z]/g, '').slice(0, 12);
    const allSameName = names.every(n => n.toLowerCase().replace(/[^a-z]/g, '').slice(0, 12) === firstName);
    const anyInactive = statuses.some(s => /inactive/i.test(s));
    const sameChainPrefix = codes.every(c => c && codes[0] && c.slice(0, 4) === codes[0].slice(0, 4));

    if (allSameName) trueDupes.push(d);
    else if (anyInactive) inactiveMix.push(d);
    else if (sameChainPrefix) chainSiblings.push(d);
    else sharedBuilding.push(d);
  }

  console.log(`A1. REAL DUPLICATES — same client, multiple property rows (${trueDupes.length}):`);
  for (const d of trueDupes.slice(0, 20)) {
    console.log(`  "${d.raw_addrs[0].slice(0,55)}"`);
    for (let i = 0; i < d.client_ids.length; i++) {
      console.log(`    client_id=${d.client_ids[i]}  ${d.codes[i] || '-'}  ${d.statuses[i]}  ${d.names[i].slice(0, 40)}`);
    }
  }
  if (trueDupes.length > 20) console.log(`  ...and ${trueDupes.length - 20} more\n`);

  console.log(`\nA2. Possibly INACTIVE + ACTIVE both at same address — old + new (${inactiveMix.length}):`);
  for (const d of inactiveMix.slice(0, 15)) {
    console.log(`  "${d.raw_addrs[0].slice(0,55)}"  ${d.codes.join(',')}  ${d.statuses.join(',')}  →  ${d.names.map(n => n.slice(0,25)).join(' | ')}`);
  }
  if (inactiveMix.length > 15) console.log(`  ...and ${inactiveMix.length - 15} more`);

  console.log(`\nA3. Same chain (codes share 4-char prefix) — likely real shared address (${chainSiblings.length}):`);
  for (const d of chainSiblings.slice(0, 10)) {
    console.log(`  "${d.raw_addrs[0].slice(0,55)}"  codes=${d.codes.join(',')}  names=${d.names.map(n => n.slice(0,20)).join(' | ')}`);
  }
  if (chainSiblings.length > 10) console.log(`  ...and ${chainSiblings.length - 10} more`);

  console.log(`\nA4. Different clients sharing an address — could be co-tenants OR data error (${sharedBuilding.length}):`);
  for (const d of sharedBuilding.slice(0, 15)) {
    console.log(`  "${d.raw_addrs[0].slice(0,55)}"  ${d.codes.join(',')}  names=${d.names.map(n => n.slice(0,25)).join(' | ')}`);
  }
  if (sharedBuilding.length > 15) console.log(`  ...and ${sharedBuilding.length - 15} more`);

  // ============================================================================
  // PART B — Jobber-completed visits not in AT (post-2026 only)
  // ============================================================================
  console.log('\n\n============================================================');
  console.log('PART B — Jobber-completed visits with no AT match (post-2026)');
  console.log('============================================================\n');

  // Pull AT visits with their Jobber Visit IDs (just GIDs)
  console.log('[B1] Indexing AT visits by Jobber GID...');
  const atVisits = await listAirtable('Visits',
    ['Jobber Visit ID'],
    `IS_AFTER({Visit Date}, '2026-01-01')`);
  const atGids = new Set(atVisits.map(v => v['Jobber Visit ID']).filter(Boolean));
  console.log(`  ${atGids.size} unique Jobber GIDs linked from AT\n`);

  // Pull our Jobber-completed visits post-2026
  console.log('[B2] Pulling Jobber-completed visits post-2026...');
  const dbVisits = await pg(`
    SELECT
      v.id, v.visit_date::text AS visit_date, v.title, v.service_type,
      c.client_code, c.name AS client_name,
      esl.source_id AS jobber_gid
    FROM visits v
    LEFT JOIN clients c ON c.id = v.client_id
    LEFT JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
    WHERE v.visit_status='completed'
      AND v.visit_date >= '2026-01-01'
      AND esl.source_id IS NOT NULL
    ORDER BY v.visit_date;
  `);
  console.log(`  ${dbVisits.length} Jobber-completed post-2026 visits\n`);

  // Find Jobber-only (no AT match)
  const jobberOnly = dbVisits.filter(v => !atGids.has(v.jobber_gid));
  console.log(`  ${jobberOnly.length} are NOT in AT (Jobber-only)\n`);

  // Classify by title
  const isEmergencyOrService = (t) =>
    t && /emergency|service\s*call|service\s*\b|clog|hydrojet|drain|repair|riser|fire pump|warranty/i.test(t);

  const expectedJobberOnly = jobberOnly.filter(v => isEmergencyOrService(v.title));
  const unexplained        = jobberOnly.filter(v => !isEmergencyOrService(v.title));

  console.log(`B1. EXPECTED Jobber-only (title says emergency/service/clog/etc) — ${expectedJobberOnly.length}`);
  const expectedSample = expectedJobberOnly.slice(-10);
  for (const v of expectedSample) console.log(`  ${v.visit_date}  ${(v.client_code || '-').padEnd(10)}  "${(v.title || '').slice(0, 70)}"`);
  if (expectedJobberOnly.length > 10) console.log(`  (showing last 10 of ${expectedJobberOnly.length})`);

  console.log(`\nB2. UNEXPLAINED Jobber-only (title doesn't match emergency/service patterns) — ${unexplained.length} ← real action items`);
  const unexplainedRecent = unexplained.slice(-20);
  for (const v of unexplainedRecent) console.log(`  ${v.visit_date}  ${(v.client_code || '-').padEnd(10)}  "${(v.title || '').slice(0, 70)}"`);
  if (unexplained.length > 20) console.log(`  (showing last 20 of ${unexplained.length})`);

  console.log('\nSummary:');
  console.log(`  Total Jobber-only completed visits post-2026: ${jobberOnly.length}`);
  console.log(`    Expected (emergency/service-call titles):    ${expectedJobberOnly.length}`);
  console.log(`    Unexplained (no service-call title pattern): ${unexplained.length}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
