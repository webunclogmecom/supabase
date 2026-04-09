/**
 * build_ops_clients.js — Builds the canonical ops.clients table
 *
 * Strategy: Pure SQL merge executed via Supabase Management API
 *   Phase 1: Deploy schema (drop + recreate ops.clients)
 *   Phase 2: Fix entity_map duplicates (9 duplicate jobber_client_ids)
 *   Phase 3: Insert all entity_map rows (deduped) with full data from all sources
 *   Phase 4: Insert remaining Jobber clients (code-match to Samsara/Airtable where possible)
 *   Phase 5: Verify counts and report
 *
 * Merge priority: Airtable > Jobber > Samsara for overlapping fields
 * Safe to re-run: drops and recreates each time.
 *
 * Usage: npx @dotenvx/dotenvx run -- node scripts/build_ops_clients.js
 */

'use strict';
const https = require('https');
const fs = require('fs');
const path = require('path');

const PAT = process.env.SUPABASE_PAT;
const PROJECT_ID = 'infbofuilnqqviyjlwul';

if (!PAT) {
  console.error('Missing SUPABASE_PAT in environment');
  process.exit(1);
}

function runSQL(sql) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${PROJECT_ID}/database/query`,
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${PAT}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body)
      }
    }, res => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          if (parsed.error || parsed.message) {
            reject(new Error(JSON.stringify(parsed)));
          } else {
            resolve(parsed);
          }
        } catch (e) {
          reject(new Error(`Parse error: ${data.slice(0, 500)}`));
        }
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

(async () => {
  console.log('=== BUILDING ops.clients — THE ONE SOURCE OF TRUTH ===\n');

  // ── Phase 1: Deploy schema ──
  console.log('Phase 1: Deploying ops.clients schema...');
  const schemaSql = fs.readFileSync(
    path.join(__dirname, 'ops_clients_schema.sql'), 'utf8'
  );
  await runSQL(schemaSql);
  console.log('  ✓ Schema deployed\n');

  // ── Phase 2: Fix entity_map duplicate jobber_client_ids ──
  // Keep only the row with the highest match_confidence (or latest created_at)
  console.log('Phase 2: Fixing entity_map duplicate jobber_client_ids...');
  const fixDups = await runSQL(`
    WITH dups AS (
      SELECT jobber_client_id,
             array_agg(id ORDER BY match_confidence DESC NULLS LAST, id) as ids
      FROM ops.entity_map
      WHERE jobber_client_id IS NOT NULL
      GROUP BY jobber_client_id
      HAVING COUNT(*) > 1
    )
    UPDATE ops.entity_map em
    SET jobber_client_id = NULL,
        jobber_client_name = NULL,
        notes = COALESCE(notes, '') || ' [jobber_id removed: duplicate, kept on row ' ||
                (SELECT ids[1] FROM dups d WHERE d.jobber_client_id = em.jobber_client_id) || ']'
    WHERE em.jobber_client_id IN (SELECT jobber_client_id FROM dups)
      AND em.id NOT IN (SELECT ids[1] FROM dups)
    RETURNING id, canonical_name, jobber_client_id
  `);
  console.log(`  ✓ Fixed ${fixDups.length} duplicate rows\n`);

  // ── Phase 3: Insert entity_map rows with merged data ──
  console.log('Phase 3: Inserting entity_map rows with merged source data...');

  const phase3sql = `
    -- Helper function to extract 3-digit code from name
    CREATE OR REPLACE FUNCTION ops.extract_code(name TEXT)
    RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
      SELECT CASE
        WHEN name ~ '^[0-9]{3}\\s*-' THEN substring(name from '^([0-9]{3})')
        ELSE NULL
      END
    $$;

    -- Helper function to extract clean name (after code prefix)
    CREATE OR REPLACE FUNCTION ops.extract_clean_name(name TEXT)
    RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
      SELECT CASE
        WHEN name ~ '^[0-9]{3}\\s*-\\s*[A-Z]{0,4}\\s+'
          THEN trim(regexp_replace(name, '^[0-9]{3}\\s*-\\s*[A-Z]{0,4}\\s+', ''))
        WHEN name ~ '^[0-9]{3}\\s*-\\s*'
          THEN trim(regexp_replace(name, '^[0-9]{3}\\s*-\\s*', ''))
        ELSE trim(name)
      END
    $$;

    INSERT INTO ops.clients (
      client_code, canonical_name, display_name,
      status, overall_status,
      address_line1, city, state, zip_code, county, zone,
      latitude, longitude,
      email, phone, accounting_email, operation_email,
      service_type, truck,
      gt_frequency_days, cl_frequency_days,
      gt_price_per_visit, cl_price_per_visit, gt_size_gallons,
      gt_status, cl_status,
      gt_last_visit, gt_next_visit, cl_last_visit, cl_next_visit,
      gt_total_per_year,
      gdo_number, gdo_expiration_date, contract_warranty,
      days_of_week, hours_in_out,
      balance,
      airtable_record_id, jobber_client_id, samsara_address_id, qb_customer_id,
      geofence_radius_meters, geofence_type,
      data_sources, match_method, match_confidence, notes
    )
    SELECT
      -- Identity
      COALESCE(
        ops.extract_code(at.client_code),
        ops.extract_code(at.client_name),
        ops.extract_code(sa.name),
        ops.extract_code(jb.name)
      ) as client_code,

      COALESCE(
        NULLIF(at.client_name, ''),
        ops.extract_clean_name(sa.name),
        ops.extract_clean_name(jb.name),
        NULLIF(em.canonical_name, ''),
        COALESCE(at.client_code, sa.name, jb.name, 'Unknown-' || em.id::text)
      ) as canonical_name,

      COALESCE(
        CASE WHEN at.client_code IS NOT NULL
          THEN at.client_code || '-' || at.client_name
          ELSE NULL END,
        sa.name,
        jb.name,
        em.canonical_name
      ) as display_name,

      -- Status
      CASE
        WHEN UPPER(at.active_inactive) IN ('RECURING','RECURRING') THEN 'RECURRING'
        WHEN UPPER(at.active_inactive) = 'ACTIVE' THEN 'ACTIVE'
        WHEN UPPER(at.active_inactive) = 'PAUSED' THEN 'PAUSED'
        WHEN UPPER(at.active_inactive) = 'INACTIVE' THEN 'INACTIVE'
        ELSE NULL
      END as status,
      at.overall_status,

      -- Address (Airtable > Jobber property > Samsara)
      COALESCE(at.address, jp.street, sa.formatted_address) as address_line1,
      COALESCE(at.city, jp.city) as city,
      COALESCE(at.state, jp.province) as state,
      COALESCE(at.zip_code, jp.postal_code) as zip_code,
      at.county,
      at.zone,

      -- GPS from Samsara
      sa.latitude::numeric(10,7),
      sa.longitude::numeric(10,7),

      -- Contact (Jobber primary)
      jb.email,
      jb.phone,
      at.accounting_email,
      at.operation_email,

      -- Service details from Airtable
      at.service_type::text[],
      at.truck::text[],
      at.gt_frequency::integer,
      at.cl_frequency::integer,
      at.gt_price_per_visit::numeric(10,2),
      at.cl_price_per_visit::numeric(10,2),
      at.size_gt_gallons::numeric,
      at.gt_status,
      at.cl_status,
      at.gt_last_visit::date,
      at.gt_next_visit::date,
      at.cl_last_visit::date,
      at.cl_next_visit_calculated::date,
      at.gt_total_per_year::numeric(10,2),

      -- Compliance
      at.gdo_number,
      at.gdo_expiration_date::date,
      at.contract_warranty,

      -- Scheduling
      at.days_of_week,
      CONCAT_WS(' - ', at.hours_in, at.hours_out),

      -- Financial
      jb.balance::numeric(10,2),

      -- Foreign keys
      em.airtable_record_id,
      em.jobber_client_id,
      em.samsara_address_id,
      em.qb_customer_id,

      -- Geofence
      sa.geofence_radius_meters,
      sa.geofence_type,

      -- Meta
      ARRAY_REMOVE(ARRAY[
        CASE WHEN em.airtable_record_id IS NOT NULL THEN 'airtable' END,
        CASE WHEN em.jobber_client_id IS NOT NULL THEN 'jobber' END,
        CASE WHEN em.samsara_address_id IS NOT NULL THEN 'samsara' END
      ], NULL) as data_sources,
      em.match_method,
      em.match_confidence,
      em.notes

    FROM ops.entity_map em
    LEFT JOIN public.airtable_clients at ON at.record_id = em.airtable_record_id
    LEFT JOIN public.jobber_clients jb ON jb.id = em.jobber_client_id
    LEFT JOIN samsara.addresses sa ON sa.id = em.samsara_address_id
    LEFT JOIN LATERAL (
      SELECT jp2.street, jp2.city, jp2.province, jp2.postal_code
      FROM public.jobber_properties jp2
      WHERE jp2.client_id = em.jobber_client_id
      ORDER BY jp2.is_billing_address ASC  -- prefer service address
      LIMIT 1
    ) jp ON em.jobber_client_id IS NOT NULL
  `;

  const phase3result = await runSQL(phase3sql);
  const phase3count = await runSQL(`SELECT COUNT(*) as cnt FROM ops.clients`);
  console.log(`  ✓ Inserted ${phase3count[0].cnt} rows from entity_map\n`);

  // ── Phase 4: Insert remaining Jobber clients ──
  console.log('Phase 4: Adding remaining Jobber clients (not in entity_map)...');

  const phase4sql = `
    WITH used_jobber AS (
      SELECT jobber_client_id FROM ops.clients WHERE jobber_client_id IS NOT NULL
    ),
    used_samsara AS (
      SELECT samsara_address_id FROM ops.clients WHERE samsara_address_id IS NOT NULL
    ),
    used_airtable AS (
      SELECT airtable_record_id FROM ops.clients WHERE airtable_record_id IS NOT NULL
    ),
    remaining_jobber AS (
      SELECT jb.*,
             ops.extract_code(jb.name) as jb_code,
             ops.extract_clean_name(jb.name) as jb_clean_name
      FROM public.jobber_clients jb
      WHERE jb.id NOT IN (SELECT jobber_client_id FROM used_jobber)
    ),
    -- Try to match remaining Jobber to unlinked Samsara addresses by code
    samsara_match AS (
      SELECT rj.id as jb_id,
             sa.id as sa_id, sa.name as sa_name,
             sa.formatted_address as sa_address,
             sa.latitude, sa.longitude,
             sa.geofence_radius_meters, sa.geofence_type,
             ROW_NUMBER() OVER (PARTITION BY rj.id ORDER BY sa.id) as rn
      FROM remaining_jobber rj
      JOIN samsara.addresses sa ON ops.extract_code(sa.name) = rj.jb_code
      WHERE rj.jb_code IS NOT NULL
        AND sa.id NOT IN (SELECT samsara_address_id FROM used_samsara)
    ),
    -- Try to match remaining Jobber to unlinked Airtable by code
    airtable_match AS (
      SELECT rj.id as jb_id,
             at.record_id as at_id,
             at.client_name, at.active_inactive, at.overall_status,
             at.address, at.city as at_city, at.state as at_state,
             at.zip_code as at_zip, at.county, at.zone,
             at.accounting_email, at.operation_email,
             at.service_type, at.truck,
             at.gt_frequency, at.cl_frequency,
             at.gt_price_per_visit, at.cl_price_per_visit,
             at.size_gt_gallons, at.gt_status, at.cl_status,
             at.gt_last_visit, at.gt_next_visit, at.cl_last_visit, at.cl_next_visit_calculated,
             at.gt_total_per_year,
             at.gdo_number, at.gdo_expiration_date, at.contract_warranty,
             at.days_of_week, at.hours_in, at.hours_out,
             ROW_NUMBER() OVER (PARTITION BY rj.id ORDER BY at.record_id) as rn
      FROM remaining_jobber rj
      JOIN public.airtable_clients at
        ON ops.extract_code(COALESCE(at.client_code, at.client_name)) = rj.jb_code
      WHERE rj.jb_code IS NOT NULL
        AND at.record_id NOT IN (SELECT airtable_record_id FROM used_airtable)
    )
    INSERT INTO ops.clients (
      client_code, canonical_name, display_name,
      status, overall_status,
      address_line1, city, state, zip_code, county, zone,
      latitude, longitude,
      email, phone, accounting_email, operation_email,
      service_type, truck,
      gt_frequency_days, cl_frequency_days,
      gt_price_per_visit, cl_price_per_visit, gt_size_gallons,
      gt_status, cl_status,
      gt_last_visit, gt_next_visit, cl_last_visit, cl_next_visit,
      gt_total_per_year,
      gdo_number, gdo_expiration_date, contract_warranty,
      days_of_week, hours_in_out,
      balance,
      airtable_record_id, jobber_client_id, samsara_address_id,
      geofence_radius_meters, geofence_type,
      data_sources, match_method, match_confidence
    )
    SELECT
      rj.jb_code,
      COALESCE(am.client_name, rj.jb_clean_name, rj.name) as canonical_name,
      rj.name as display_name,

      CASE
        WHEN UPPER(am.active_inactive) IN ('RECURING','RECURRING') THEN 'RECURRING'
        WHEN UPPER(am.active_inactive) = 'ACTIVE' THEN 'ACTIVE'
        WHEN UPPER(am.active_inactive) = 'PAUSED' THEN 'PAUSED'
        WHEN UPPER(am.active_inactive) = 'INACTIVE' THEN 'INACTIVE'
        ELSE NULL
      END,
      am.overall_status,

      COALESCE(am.address, jp.street, sm.sa_address),
      COALESCE(am.at_city, jp.city),
      COALESCE(am.at_state, jp.province),
      COALESCE(am.at_zip, jp.postal_code),
      am.county,
      am.zone,
      sm.latitude::numeric(10,7),
      sm.longitude::numeric(10,7),

      rj.email,
      rj.phone,
      am.accounting_email,
      am.operation_email,

      am.service_type::text[],
      am.truck::text[],
      am.gt_frequency::integer,
      am.cl_frequency::integer,
      am.gt_price_per_visit::numeric(10,2),
      am.cl_price_per_visit::numeric(10,2),
      am.size_gt_gallons::numeric,
      am.gt_status,
      am.cl_status,
      am.gt_last_visit::date,
      am.gt_next_visit::date,
      am.cl_last_visit::date,
      am.cl_next_visit_calculated::date,
      am.gt_total_per_year::numeric(10,2),

      am.gdo_number,
      am.gdo_expiration_date::date,
      am.contract_warranty,
      am.days_of_week,
      CONCAT_WS(' - ', am.hours_in, am.hours_out),

      rj.balance::numeric(10,2),

      am.at_id,
      rj.id,
      sm.sa_id,
      sm.geofence_radius_meters,
      sm.geofence_type,

      ARRAY_REMOVE(ARRAY[
        CASE WHEN am.at_id IS NOT NULL THEN 'airtable' END,
        'jobber',
        CASE WHEN sm.sa_id IS NOT NULL THEN 'samsara' END
      ], NULL),
      CASE
        WHEN am.at_id IS NOT NULL AND sm.sa_id IS NOT NULL THEN 'code_phase2_3way'
        WHEN am.at_id IS NOT NULL THEN 'code_phase2_at'
        WHEN sm.sa_id IS NOT NULL THEN 'code_phase2_sa'
        ELSE 'jobber_only'
      END,
      CASE
        WHEN am.at_id IS NOT NULL OR sm.sa_id IS NOT NULL THEN 0.85
        ELSE NULL
      END

    FROM remaining_jobber rj
    LEFT JOIN LATERAL (
      SELECT * FROM samsara_match sm2 WHERE sm2.jb_id = rj.id AND sm2.rn = 1
    ) sm ON true
    LEFT JOIN LATERAL (
      SELECT * FROM airtable_match am2 WHERE am2.jb_id = rj.id AND am2.rn = 1
    ) am ON true
    LEFT JOIN LATERAL (
      SELECT jp2.street, jp2.city, jp2.province, jp2.postal_code
      FROM public.jobber_properties jp2
      WHERE jp2.client_id = rj.id
      ORDER BY jp2.is_billing_address ASC
      LIMIT 1
    ) jp ON true
  `;

  const phase4result = await runSQL(phase4sql);
  const phase4count = await runSQL(`SELECT COUNT(*) as cnt FROM ops.clients`);
  console.log(`  ✓ Total rows after Phase 4: ${phase4count[0].cnt}\n`);

  // ── Phase 5: Verification ──
  console.log('Phase 5: Verification...\n');

  const results = await Promise.all([
    runSQL(`SELECT COUNT(*) as total FROM ops.clients`),
    runSQL(`SELECT status, COUNT(*) as cnt FROM ops.clients GROUP BY status ORDER BY cnt DESC`),
    runSQL(`
      SELECT array_to_string(data_sources, '+') as combo, COUNT(*) as cnt
      FROM ops.clients GROUP BY 1 ORDER BY cnt DESC
    `),
    runSQL(`SELECT match_method, COUNT(*) as cnt FROM ops.clients GROUP BY match_method ORDER BY cnt DESC`),
    runSQL(`
      SELECT
        COUNT(*) as total,
        COUNT(airtable_record_id) as has_airtable,
        COUNT(jobber_client_id) as has_jobber,
        COUNT(samsara_address_id) as has_samsara,
        COUNT(qb_customer_id) as has_qb,
        COUNT(address_line1) as has_address,
        COUNT(email) as has_email,
        COUNT(phone) as has_phone,
        COUNT(latitude) as has_gps,
        COUNT(gt_frequency_days) as has_gt_freq,
        COUNT(gdo_number) as has_gdo
      FROM ops.clients
    `),
    // Integrity checks
    runSQL(`
      SELECT 'dup_airtable' as check_name, COUNT(*) as cnt FROM (
        SELECT airtable_record_id FROM ops.clients
        WHERE airtable_record_id IS NOT NULL
        GROUP BY airtable_record_id HAVING COUNT(*) > 1
      ) x
      UNION ALL
      SELECT 'dup_jobber', COUNT(*) FROM (
        SELECT jobber_client_id FROM ops.clients
        WHERE jobber_client_id IS NOT NULL
        GROUP BY jobber_client_id HAVING COUNT(*) > 1
      ) x
      UNION ALL
      SELECT 'dup_samsara', COUNT(*) FROM (
        SELECT samsara_address_id FROM ops.clients
        WHERE samsara_address_id IS NOT NULL
        GROUP BY samsara_address_id HAVING COUNT(*) > 1
      ) x
    `)
  ]);

  const [totalR, statusR, comboR, methodR, coverageR, integrityR] = results;

  console.log(`Total ops.clients: ${totalR[0].total}`);

  console.log('\nBy status:');
  statusR.forEach(r => console.log(`  ${r.status || '(null)'}: ${r.cnt}`));

  console.log('\nBy source combination:');
  comboR.forEach(r => console.log(`  ${r.combo}: ${r.cnt}`));

  console.log('\nBy match method:');
  methodR.forEach(r => console.log(`  ${r.match_method}: ${r.cnt}`));

  const cov = coverageR[0];
  console.log('\nField coverage:');
  console.log(`  Airtable link:  ${cov.has_airtable}/${cov.total}`);
  console.log(`  Jobber link:    ${cov.has_jobber}/${cov.total}`);
  console.log(`  Samsara link:   ${cov.has_samsara}/${cov.total}`);
  console.log(`  QuickBooks link:${cov.has_qb}/${cov.total}`);
  console.log(`  Address:        ${cov.has_address}/${cov.total}`);
  console.log(`  Email:          ${cov.has_email}/${cov.total}`);
  console.log(`  Phone:          ${cov.has_phone}/${cov.total}`);
  console.log(`  GPS coords:     ${cov.has_gps}/${cov.total}`);
  console.log(`  GT frequency:   ${cov.has_gt_freq}/${cov.total}`);
  console.log(`  GDO number:     ${cov.has_gdo}/${cov.total}`);

  console.log('\nIntegrity checks (should all be 0):');
  integrityR.forEach(r => {
    const icon = r.cnt === '0' || r.cnt === 0 ? '✓' : '✗';
    console.log(`  ${icon} ${r.check_name}: ${r.cnt} duplicates`);
  });

  // Sample 3-way matches
  console.log('\n=== SAMPLE: 3-way matched clients (AT+JB+SA) ===');
  const sample3 = await runSQL(`
    SELECT client_code, canonical_name, status, zone, city,
           email, gt_frequency_days, gt_price_per_visit, gt_size_gallons
    FROM ops.clients
    WHERE airtable_record_id IS NOT NULL
      AND jobber_client_id IS NOT NULL
      AND samsara_address_id IS NOT NULL
    ORDER BY client_code
    LIMIT 15
  `);
  sample3.forEach(r => {
    console.log(`  ${r.client_code || '---'} | ${r.canonical_name} | ${r.status || '-'} | ${r.zone || '-'} | ${r.city || '-'} | GT:${r.gt_frequency_days || '-'}d/$${r.gt_price_per_visit || '-'}/${r.gt_size_gallons || '-'}gal`);
  });

  console.log('\n✅ ops.clients build complete!');
})().catch(err => {
  console.error('FATAL:', err);
  process.exit(1);
});
