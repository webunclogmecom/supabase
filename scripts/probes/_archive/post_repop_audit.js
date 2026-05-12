// Post-repop audit (2026-04-29) — runs four probes in parallel:
//  1. Airtable Visits field names (resolve completed_by=0 anomaly)
//  2. 501 Jobber visits with no invoice_id — recency breakdown
//  3. Two Casa Neos clients — verify both have Jobber links
//  4. service_configs distribution — sanity check

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const { newQuery } = require('../populate/lib/db');

function httpsGet(host, path, headers) {
  return new Promise((res, rej) => {
    https.request({ hostname: host, path, headers }, r => {
      let d = '';
      r.on('data', c => d += c);
      r.on('end', () => {
        if (r.statusCode >= 200 && r.statusCode < 300) {
          try { res(JSON.parse(d)); } catch (e) { rej(new Error('bad json: ' + d.slice(0, 300))); }
        } else rej(new Error(`HTTP ${r.statusCode}: ${d.slice(0, 300)}`));
      });
    }).on('error', rej).end();
  });
}

async function probeAirtableVisitsFields() {
  const AT_KEY = process.env.AIRTABLE_API_KEY;
  const AT_BASE = process.env.AIRTABLE_BASE_ID;
  const r = await httpsGet('api.airtable.com', `/v0/${AT_BASE}/Visits?maxRecords=3`, { Authorization: `Bearer ${AT_KEY}` });
  if (!r.records || !r.records.length) return { err: 'no records' };
  const fieldKeys = new Set();
  for (const rec of r.records) for (const k of Object.keys(rec.fields || {})) fieldKeys.add(k);
  return { fields: [...fieldKeys].sort() };
}

async function probeMissingInvoices() {
  return await newQuery(`
    SELECT
      COUNT(*)::int AS total,
      COUNT(*) FILTER (WHERE v.visit_status = 'COMPLETED')::int AS completed,
      COUNT(*) FILTER (WHERE v.visit_status != 'COMPLETED' OR v.visit_status IS NULL)::int AS not_complete,
      COUNT(*) FILTER (WHERE v.start_at > now() - interval '30 days')::int AS last_30d,
      COUNT(*) FILTER (WHERE v.start_at <= now() - interval '30 days' AND v.start_at > now() - interval '6 months')::int AS m30_to_6m,
      COUNT(*) FILTER (WHERE v.start_at <= now() - interval '6 months')::int AS older_6m,
      COUNT(*) FILTER (WHERE v.start_at IS NULL)::int AS no_start_at
    FROM visits v
    WHERE v.invoice_id IS NULL
      AND EXISTS (
        SELECT 1 FROM entity_source_links esl
        WHERE esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
      );
  `);
}

async function probeCasaNeosClients() {
  return await newQuery(`
    SELECT
      c.id,
      c.name,
      c.client_code,
      c.status,
      (SELECT string_agg(esl.source_system || ':' || left(esl.source_id, 40), ', ')
       FROM entity_source_links esl
       WHERE esl.entity_type='client' AND esl.entity_id=c.id) AS sources,
      (SELECT COUNT(*)::int FROM visits v WHERE v.client_id=c.id) AS visit_count
    FROM clients c
    WHERE c.name ILIKE '%casa%neos%'
    ORDER BY c.id;
  `);
}

async function probeServiceConfigsDistribution() {
  const top = await newQuery(`
    SELECT
      c.name,
      array_agg(sc.service_type ORDER BY sc.service_type) AS services,
      COUNT(*)::int AS service_count,
      array_agg(sc.frequency_days ORDER BY sc.service_type) AS frequencies
    FROM service_configs sc
    JOIN clients c ON c.id = sc.client_id
    GROUP BY c.id, c.name
    ORDER BY COUNT(*) DESC, c.name
    LIMIT 10;
  `);
  const summary = await newQuery(`
    SELECT
      COUNT(*)::int AS total_configs,
      COUNT(DISTINCT client_id)::int AS clients_with_configs,
      service_type,
      COUNT(*)::int AS service_count
    FROM service_configs
    GROUP BY service_type
    ORDER BY service_count DESC;
  `);
  return { top, summary };
}

(async () => {
  console.log('=== POST-REPOP AUDIT (2026-04-29) ===\n');
  const [airFields, missingInv, casaNeos, scDist] = await Promise.allSettled([
    probeAirtableVisitsFields(),
    probeMissingInvoices(),
    probeCasaNeosClients(),
    probeServiceConfigsDistribution(),
  ]);

  console.log('--- 1. AIRTABLE VISITS FIELDS ---');
  if (airFields.status === 'fulfilled') {
    console.log(`Found ${airFields.value.fields?.length || 0} fields:`);
    for (const f of airFields.value.fields || []) console.log(`  • ${f}`);
  } else console.log('  ERROR:', airFields.reason?.message);

  console.log('\n--- 2. JOBBER VISITS WITHOUT invoice_id ---');
  if (missingInv.status === 'fulfilled') {
    const r = missingInv.value[0];
    console.log(`Total: ${r.total}`);
    console.log(`  By status: completed=${r.completed}, not_complete=${r.not_complete}`);
    console.log(`  By age: last_30d=${r.last_30d}, 30d-6m=${r.m30_to_6m}, >6m=${r.older_6m}, no_start_at=${r.no_start_at}`);
  } else console.log('  ERROR:', missingInv.reason?.message);

  console.log('\n--- 3. CASA NEOS CLIENTS ---');
  if (casaNeos.status === 'fulfilled') {
    for (const c of casaNeos.value) {
      console.log(`  id=${c.id} code=${c.client_code} name="${c.name}" status=${c.status}`);
      console.log(`    visits: ${c.visit_count}`);
      console.log(`    sources: ${c.sources || '(none)'}`);
    }
  } else console.log('  ERROR:', casaNeos.reason?.message);

  console.log('\n--- 4. SERVICE_CONFIGS DISTRIBUTION ---');
  if (scDist.status === 'fulfilled') {
    console.log('  By service_type:');
    for (const r of scDist.value.summary) console.log(`    ${r.service_type}: ${r.service_count} configs`);
    console.log('\n  Top 10 clients by service count:');
    for (const r of scDist.value.top) console.log(`    [${r.service_count}] "${r.name}": ${(r.services || []).join(', ')} (freq_days: ${(r.frequencies || []).join('/')})`);
  } else console.log('  ERROR:', scDist.reason?.message);

  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
