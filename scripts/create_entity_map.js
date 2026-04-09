#!/usr/bin/env node
/**
 * create_entity_map.js
 * Creates ops.entity_map table and populates it by cross-referencing:
 *   - samsara.addresses (192 rows, naming convention "009-CN Casa Neos")
 *   - airtable_clients (client_code like "009-CN", plus jobber_client_id, samsara_address_id)
 *   - jobber_clients (id, name, company_name)
 *
 * Match strategies:
 *   1. airtable_clients already has samsara_address_id -> direct link
 *   2. Extract code prefix from samsara address name, match to airtable_clients.client_code
 *   3. Fuzzy name match: name portion of samsara address vs jobber_clients.name/company_name
 *   4. Airtable's jobber_client_id field for Airtable->Jobber links
 *
 * Usage: node scripts/create_entity_map.js
 */

require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });
const https = require('https');

const SUPABASE_PAT = process.env.SUPABASE_PAT;
const PROJECT_ID   = 'infbofuilnqqviyjlwul';

if (!SUPABASE_PAT) {
  console.error('Missing SUPABASE_PAT in .env');
  process.exit(1);
}

function esc(s) {
  if (s === null || s === undefined) return 'NULL';
  return "'" + String(s).replace(/'/g, "''") + "'";
}

function httpsRequest(options, body = null) {
  return new Promise((resolve, reject) => {
    const req = https.request(options, res => {
      let data = '';
      res.on('data', d => data += d);
      res.on('end', () => {
        try { resolve({ status: res.statusCode, body: JSON.parse(data) }); }
        catch (e) { reject(new Error(`JSON parse (${res.statusCode}): ${data.slice(0, 500)}`)); }
      });
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

async function runSQL(query) {
  const bodyStr = JSON.stringify({ query });
  const { status, body } = await httpsRequest({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${PROJECT_ID}/database/query`,
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${SUPABASE_PAT}`,
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(bodyStr),
    },
  }, bodyStr);
  if (body && body.message) throw new Error(`SQL error: ${body.message}`);
  return body;
}

const sleep = ms => new Promise(r => setTimeout(r, ms));

/**
 * Parse samsara address name into code prefix and name portion.
 * "009-CN Casa Neos" -> { num: "009", abbr: "CN", code: "009-CN", namePart: "Casa Neos" }
 * "000-DH Homestead Dump" -> { num: "000", abbr: "DH", code: "000-DH", namePart: "Homestead Dump" }
 */
function parseSamsaraName(name) {
  const match = name.match(/^(\d{3})-([A-Z0-9]+)\s+(.+)$/);
  if (!match) return null;
  return {
    num: match[1],
    abbr: match[2],
    code: `${match[1]}-${match[2]}`,
    namePart: match[3].trim(),
  };
}

/**
 * Normalize a name for fuzzy comparison: lowercase, strip punctuation, collapse whitespace.
 */
function normalize(s) {
  return s.toLowerCase().replace(/[^a-z0-9\s]/g, '').replace(/\s+/g, ' ').trim();
}

/**
 * Simple fuzzy match: check if significant words from the query appear in the target.
 * Returns a confidence score 0-1.
 */
function fuzzyScore(samsaraNamePart, jobberName) {
  const sNorm = normalize(samsaraNamePart);
  const jNorm = normalize(jobberName);

  // Exact normalized match
  if (sNorm === jNorm) return 1.0;

  // Check if one contains the other
  if (jNorm.includes(sNorm) || sNorm.includes(jNorm)) return 0.90;

  // Word overlap
  const sWords = sNorm.split(' ').filter(w => w.length > 2); // skip tiny words
  const jWords = jNorm.split(' ').filter(w => w.length > 2);
  if (sWords.length === 0 || jWords.length === 0) return 0;

  let matches = 0;
  for (const sw of sWords) {
    if (jWords.some(jw => jw.includes(sw) || sw.includes(jw))) matches++;
  }
  const score = matches / Math.max(sWords.length, 1);
  return Math.round(score * 100) / 100;
}

async function main() {
  const startTime = Date.now();
  console.log('=== ops.entity_map Creation & Population ===');
  console.log(`Started: ${new Date().toISOString()}\n`);

  // Step 1: Create ops schema and entity_map table
  console.log('[1/5] Creating ops schema and entity_map table...');
  await runSQL('CREATE SCHEMA IF NOT EXISTS ops');
  await sleep(200);

  await runSQL(`
    CREATE TABLE IF NOT EXISTS ops.entity_map (
      id BIGSERIAL PRIMARY KEY,
      entity_type TEXT NOT NULL DEFAULT 'client',
      canonical_name TEXT,
      samsara_address_id TEXT,
      samsara_address_name TEXT,
      jobber_client_id TEXT,
      jobber_client_name TEXT,
      airtable_record_id TEXT,
      airtable_client_code TEXT,
      qb_customer_id TEXT,
      qb_customer_name TEXT,
      match_method TEXT,
      match_confidence NUMERIC(3,2),
      notes TEXT,
      created_at TIMESTAMPTZ DEFAULT NOW(),
      updated_at TIMESTAMPTZ DEFAULT NOW()
    )
  `);
  await sleep(200);

  await runSQL('CREATE INDEX IF NOT EXISTS idx_entity_map_samsara ON ops.entity_map(samsara_address_id)');
  await runSQL('CREATE INDEX IF NOT EXISTS idx_entity_map_jobber ON ops.entity_map(jobber_client_id)');
  await runSQL('CREATE INDEX IF NOT EXISTS idx_entity_map_airtable ON ops.entity_map(airtable_record_id)');
  await runSQL('CREATE INDEX IF NOT EXISTS idx_entity_map_qb ON ops.entity_map(qb_customer_id)');
  console.log('  Table and indexes created.\n');

  // Step 2: Fetch all source data
  console.log('[2/5] Fetching source data...');

  const samsaraAddresses = await runSQL('SELECT id, name FROM samsara.addresses ORDER BY name');
  await sleep(100);
  const jobberClients = await runSQL('SELECT id, name, company_name FROM jobber_clients');
  await sleep(100);
  const airtableClients = await runSQL(`
    SELECT record_id, client_code, client_name, client_xx,
           jobber_client_id, samsara_address_id, quickbooks_customer_id
    FROM airtable_clients
  `);

  console.log(`  samsara.addresses:  ${samsaraAddresses.length} rows`);
  console.log(`  jobber_clients:     ${jobberClients.length} rows`);
  console.log(`  airtable_clients:   ${airtableClients.length} rows\n`);

  // Build lookup maps
  const airtableByCode = {};
  const airtableBySamsaraId = {};
  for (const ac of airtableClients) {
    if (ac.client_code) airtableByCode[ac.client_code.toUpperCase()] = ac;
    if (ac.samsara_address_id) airtableBySamsaraId[ac.samsara_address_id] = ac;
  }

  const jobberById = {};
  for (const jc of jobberClients) {
    jobberById[jc.id] = jc;
  }

  // Step 3: Match each Samsara address
  console.log('[3/5] Matching Samsara addresses to Airtable & Jobber...');

  const results = [];
  let stats = { code_exact: 0, samsara_id_link: 0, name_fuzzy: 0, unmatched: 0, total: 0 };

  for (const addr of samsaraAddresses) {
    stats.total++;
    const parsed = parseSamsaraName(addr.name);

    let airtableMatch = null;
    let jobberMatch = null;
    let matchMethod = 'unmatched';
    let confidence = 0;
    let notes = null;

    // Strategy 1: Airtable already has samsara_address_id pointing to this address
    if (airtableBySamsaraId[addr.id]) {
      airtableMatch = airtableBySamsaraId[addr.id];
      matchMethod = 'samsara_id_link';
      confidence = 1.0;
      notes = 'Airtable samsara_address_id field';
    }

    // Strategy 2: Match by client code prefix
    if (!airtableMatch && parsed) {
      const codeKey = parsed.code.toUpperCase();
      if (airtableByCode[codeKey]) {
        airtableMatch = airtableByCode[codeKey];
        matchMethod = 'code_exact';
        confidence = 0.95;
      }
    }

    // If we found an airtable match, check if it has a jobber_client_id
    if (airtableMatch && airtableMatch.jobber_client_id) {
      jobberMatch = jobberById[airtableMatch.jobber_client_id] || null;
    }

    // Strategy 3: Fuzzy name match against Jobber clients (if no jobber link yet)
    if (!jobberMatch && parsed) {
      let bestScore = 0;
      let bestJobber = null;
      for (const jc of jobberClients) {
        // Try matching against company_name and name
        const nameToCheck = jc.company_name || jc.name || '';
        const score = fuzzyScore(parsed.namePart, nameToCheck);
        if (score > bestScore && score >= 0.70) {
          bestScore = score;
          bestJobber = jc;
        }
        // Also try the display name
        if (jc.name && jc.name !== nameToCheck) {
          const score2 = fuzzyScore(parsed.namePart, jc.name);
          if (score2 > bestScore && score2 >= 0.70) {
            bestScore = score2;
            bestJobber = jc;
          }
        }
      }
      if (bestJobber) {
        jobberMatch = bestJobber;
        if (matchMethod === 'unmatched') {
          matchMethod = 'name_fuzzy';
          confidence = bestScore;
        } else {
          // We already had airtable match, just adding jobber via fuzzy
          notes = (notes || '') + '; jobber matched via name_fuzzy';
        }
      }
    }

    if (matchMethod === 'unmatched') {
      stats.unmatched++;
    } else {
      stats[matchMethod] = (stats[matchMethod] || 0) + 1;
    }

    const canonicalName = airtableMatch?.client_name || parsed?.namePart || addr.name;

    results.push({
      entity_type: 'client',
      canonical_name: canonicalName,
      samsara_address_id: addr.id,
      samsara_address_name: addr.name,
      jobber_client_id: jobberMatch?.id || null,
      jobber_client_name: jobberMatch?.name || jobberMatch?.company_name || null,
      airtable_record_id: airtableMatch?.record_id || null,
      airtable_client_code: airtableMatch?.client_code || (parsed ? parsed.code : null),
      qb_customer_id: airtableMatch?.quickbooks_customer_id || null,
      qb_customer_name: null,
      match_method: matchMethod,
      match_confidence: confidence,
      notes: notes,
    });
  }

  // Step 4: Also add Airtable clients that have NO samsara address (airtable-only entries)
  console.log('[4/5] Adding Airtable-only entries (no Samsara match)...');
  const matchedAirtableIds = new Set(results.map(r => r.airtable_record_id).filter(Boolean));
  let airtableOnlyCount = 0;

  for (const ac of airtableClients) {
    if (matchedAirtableIds.has(ac.record_id)) continue;
    airtableOnlyCount++;

    let jobberMatch = null;
    if (ac.jobber_client_id && jobberById[ac.jobber_client_id]) {
      jobberMatch = jobberById[ac.jobber_client_id];
    }

    results.push({
      entity_type: 'client',
      canonical_name: ac.client_name,
      samsara_address_id: null,
      samsara_address_name: null,
      jobber_client_id: jobberMatch?.id || ac.jobber_client_id || null,
      jobber_client_name: jobberMatch?.name || jobberMatch?.company_name || null,
      airtable_record_id: ac.record_id,
      airtable_client_code: ac.client_code,
      qb_customer_id: ac.quickbooks_customer_id || null,
      qb_customer_name: null,
      match_method: ac.jobber_client_id ? 'airtable_link' : 'unmatched',
      match_confidence: ac.jobber_client_id ? 0.95 : 0,
      notes: 'airtable-only (no samsara address)',
    });
  }
  console.log(`  ${airtableOnlyCount} Airtable-only entries added.\n`);

  // Step 5: Insert all results into ops.entity_map
  console.log('[5/5] Inserting into ops.entity_map...');

  // Clear existing data first (idempotent re-run)
  await runSQL('TRUNCATE ops.entity_map RESTART IDENTITY');
  await sleep(200);

  const BATCH = 50;
  let inserted = 0;
  for (let i = 0; i < results.length; i += BATCH) {
    const batch = results.slice(i, i + BATCH);
    const values = batch.map(r => `(
      ${esc(r.entity_type)},
      ${esc(r.canonical_name)},
      ${esc(r.samsara_address_id)},
      ${esc(r.samsara_address_name)},
      ${esc(r.jobber_client_id)},
      ${esc(r.jobber_client_name)},
      ${esc(r.airtable_record_id)},
      ${esc(r.airtable_client_code)},
      ${esc(r.qb_customer_id)},
      ${esc(r.qb_customer_name)},
      ${esc(r.match_method)},
      ${r.match_confidence},
      ${esc(r.notes)},
      NOW(), NOW()
    )`).join(',\n');

    await runSQL(`
      INSERT INTO ops.entity_map (
        entity_type, canonical_name,
        samsara_address_id, samsara_address_name,
        jobber_client_id, jobber_client_name,
        airtable_record_id, airtable_client_code,
        qb_customer_id, qb_customer_name,
        match_method, match_confidence, notes,
        created_at, updated_at
      ) VALUES ${values}
    `);
    inserted += batch.length;
    await sleep(100);
  }

  console.log(`  Inserted ${inserted} rows into ops.entity_map.\n`);

  // Report
  console.log('=== Match Statistics ===');
  console.log(`  Total Samsara addresses:     ${stats.total}`);
  console.log(`  Matched via samsara_id_link: ${stats.samsara_id_link || 0}`);
  console.log(`  Matched via code_exact:      ${stats.code_exact || 0}`);
  console.log(`  Matched via name_fuzzy:      ${stats.name_fuzzy || 0}`);
  console.log(`  Unmatched:                   ${stats.unmatched}`);
  console.log(`  Airtable-only entries:       ${airtableOnlyCount}`);
  console.log(`  Total entity_map rows:       ${inserted}`);

  // Verify with a count query
  const countResult = await runSQL('SELECT match_method, COUNT(*) as cnt FROM ops.entity_map GROUP BY match_method ORDER BY cnt DESC');
  console.log('\n=== DB Verification (match_method counts) ===');
  for (const row of countResult) {
    console.log(`  ${row.match_method}: ${row.cnt}`);
  }

  // Show some sample matches
  const samples = await runSQL(`
    SELECT canonical_name, samsara_address_name, jobber_client_name, airtable_client_code, match_method, match_confidence
    FROM ops.entity_map
    WHERE match_method != 'unmatched' AND samsara_address_id IS NOT NULL
    ORDER BY match_confidence DESC
    LIMIT 10
  `);
  console.log('\n=== Top 10 Matched Samples ===');
  for (const s of samples) {
    console.log(`  [${s.match_method} ${s.match_confidence}] ${s.samsara_address_name} -> Airtable: ${s.airtable_client_code || '-'}, Jobber: ${s.jobber_client_name || '-'}`);
  }

  const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
  console.log(`\nDone in ${elapsed}s.`);
}

main().catch(err => {
  console.error('Fatal:', err.message);
  process.exit(1);
});
