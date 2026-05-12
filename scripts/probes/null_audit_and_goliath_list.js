// Two-part audit:
//   PART A — NULL values across canonical tables, with cause hypotheses
//   PART B — Goliath reattribution list (128 Airtable 2026 visits w/ Truck=Goliath 5,000)
//
// Output: markdown report at reports/null_audit_and_goliath_2026_05_12.md
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error(`PG ${r.status}: ${r.body.slice(0,300)}`); return JSON.parse(r.body); }
async function listAT(table, fields, filter) {
  const out=[]; let offset; const enc=encodeURIComponent;
  do {
    const fp = (fields||[]).map(f => `fields%5B%5D=${enc(f)}`).join('&');
    const ff = filter ? `&filterByFormula=${enc(filter)}` : '';
    const path = `/v0/${AT_BASE}/${enc(table)}?${fp}&pageSize=100${ff}${offset?`&offset=${enc(offset)}`:''}`;
    const r = await http({hostname:'api.airtable.com',path,method:'GET',headers:{Authorization:`Bearer ${AT_KEY}`}});
    if (r.status>=300) throw new Error(`AT ${r.status}: ${r.body.slice(0,200)}`);
    const j = JSON.parse(r.body);
    for (const rec of (j.records||[])) out.push({id:rec.id, ...rec.fields});
    offset = j.offset;
  } while (offset);
  return out;
}

const md = [];
const log = (s) => { console.log(s); md.push(s); };

(async () => {
  const today = new Date().toISOString().slice(0,10);
  md.push(`# NULL audit + Goliath reattribution list — ${today}\n`);

  // ============================================================================
  // PART A — NULL audit on visits + service_configs
  // ============================================================================
  log('\n# PART A — NULL audit across canonical fields\n');

  // A1. visits — by service_type + status, what fields are NULL?
  log('## A1. visits — NULL count per key field, by service_type + status\n');
  const a1 = await pg(`
    SELECT
      COALESCE(service_type, 'NULL') AS service_type,
      visit_status,
      COUNT(*) AS total,
      COUNT(*) FILTER (WHERE client_id IS NULL) AS null_client_id,
      COUNT(*) FILTER (WHERE property_id IS NULL) AS null_property_id,
      COUNT(*) FILTER (WHERE job_id IS NULL) AS null_job_id,
      COUNT(*) FILTER (WHERE vehicle_id IS NULL) AS null_vehicle_id,
      COUNT(*) FILTER (WHERE invoice_id IS NULL) AS null_invoice_id,
      COUNT(*) FILTER (WHERE start_at IS NULL) AS null_start_at,
      COUNT(*) FILTER (WHERE completed_at IS NULL) AS null_completed_at,
      COUNT(*) FILTER (WHERE title IS NULL) AS null_title
    FROM visits
    WHERE visit_date >= '2026-01-01'
    GROUP BY 1, 2 ORDER BY service_type, visit_status;`);
  log('| service_type | status | total | null client | null property | null job | null vehicle | null invoice | null start | null completed | null title |');
  log('|---|---|---|---|---|---|---|---|---|---|---|');
  for (const r of a1) {
    log(`| ${r.service_type} | ${r.visit_status} | ${r.total} | ${r.null_client_id} | ${r.null_property_id} | ${r.null_job_id} | ${r.null_vehicle_id} | ${r.null_invoice_id} | ${r.null_start_at} | ${r.null_completed_at} | ${r.null_title} |`);
  }

  // A2. Specifically: why is service_type NULL for some visits?
  log('\n## A2. Visits with NULL service_type — what are their titles?\n');
  const a2 = await pg(`
    SELECT title, COUNT(*) AS n
    FROM visits
    WHERE service_type IS NULL AND visit_date >= '2026-01-01'
    GROUP BY title ORDER BY n DESC LIMIT 30;`);
  log(`Total visits 2026+ with NULL service_type: **${a2.reduce((s,r)=>s+Number(r.n),0)}**\n`);
  if (a2.length > 0) {
    log('| Count | Title (Jobber-sourced job title — inferServiceType regex didn\'t match) |');
    log('|---|---|');
    for (const r of a2) log(`| ${r.n} | ${(r.title||'(null)').replace(/\|/g,'\\|')} |`);
  }

  // A3. Visits with NULL vehicle_id (truck attribution gap)
  log('\n## A3. Completed 2026 visits with NULL vehicle_id (truck attribution gap)\n');
  const a3 = await pg(`
    SELECT
      to_char(visit_date, 'YYYY-MM') AS month,
      COUNT(*) AS completed_visits,
      COUNT(*) FILTER (WHERE vehicle_id IS NULL) AS null_vehicle,
      ROUND(100.0 * COUNT(*) FILTER (WHERE vehicle_id IS NULL) / NULLIF(COUNT(*),0), 1) AS pct_null
    FROM visits
    WHERE visit_date >= '2026-01-01' AND visit_status='completed'
    GROUP BY 1 ORDER BY 1;`);
  log('| month | completed | null_vehicle | % null |');
  log('|---|---|---|---|');
  for (const r of a3) log(`| ${r.month} | ${r.completed_visits} | ${r.null_vehicle} | ${r.pct_null}% |`);
  log('\nNULL vehicle_id means the truck-attribution autopilot (ADR 012) couldn\'t find Samsara GPS pings within 150m of the property during the visit window. Causes: telemetry gap, off-site work (catering at a different venue), parking-behind-building beyond 150m, or property GPS error.\n');

  // A4. service_configs — NULL count per field
  log('## A4. service_configs — NULL count per field (active recurring clients)\n');
  const a4 = await pg(`
    SELECT
      sc.service_type,
      COUNT(*) AS total,
      COUNT(*) FILTER (WHERE sc.frequency_days IS NULL OR sc.frequency_days = 0) AS null_or_zero_freq,
      COUNT(*) FILTER (WHERE sc.first_visit IS NULL) AS null_first_visit,
      COUNT(*) FILTER (WHERE sc.last_visit IS NULL) AS null_last_visit,
      COUNT(*) FILTER (WHERE sc.price_per_visit IS NULL OR sc.price_per_visit = 0) AS null_or_zero_price,
      COUNT(*) FILTER (WHERE sc.equipment_size_gallons IS NULL) AS null_equipment_size
    FROM service_configs sc
    JOIN clients c ON c.id = sc.client_id
    WHERE c.status IN ('ACTIVE','Recuring')
    GROUP BY sc.service_type ORDER BY sc.service_type;`);
  log('| service_type | total | null/zero freq | null first_visit | null last_visit | null/zero price | null equipment size |');
  log('|---|---|---|---|---|---|---|');
  for (const r of a4) log(`| ${r.service_type} | ${r.total} | ${r.null_or_zero_freq} | ${r.null_first_visit} | ${r.null_last_visit} | ${r.null_or_zero_price} | ${r.null_equipment_size} |`);

  // A5. service_configs with NULL price — list specific clients (so Yan can fix)
  log('\n## A5. Active recurring clients with NULL or $0 service_configs.price_per_visit\n');
  const a5 = await pg(`
    SELECT c.client_code, c.name, sc.service_type, sc.frequency_days, sc.price_per_visit
    FROM service_configs sc JOIN clients c ON c.id = sc.client_id
    WHERE c.status IN ('ACTIVE','Recuring') AND (sc.price_per_visit IS NULL OR sc.price_per_visit = 0)
    ORDER BY c.client_code, sc.service_type LIMIT 30;`);
  log(`${a5.length} client × service rows with NULL/zero price (showing first 30 by client_code):\n`);
  log('| client_code | client_name | service | freq | price |');
  log('|---|---|---|---|---|');
  for (const r of a5) log(`| ${r.client_code||'-'} | ${(r.name||'').slice(0,40)} | ${r.service_type} | ${r.frequency_days}d | ${r.price_per_visit||'null'} |`);

  // ============================================================================
  // PART B — Goliath reattribution list
  // ============================================================================
  log('\n\n# PART B — Goliath reattribution list (Airtable Truck="Goliath 5,000" 2026 visits)\n');
  log('## What this is\n');
  log('Airtable\'s `Truck` field on the Visits table has 128 visits in 2026 incorrectly labeled `Goliath 5,000`. Goliath was decommissioned 2026-05-01 and never had Samsara telemetry, so those labels can\'t be right. Our Supabase DB derives `visits.vehicle_id` from Samsara GPS cross-reference (ADR 012), so it has the correct truck. This table cross-references the two.\n');
  log('Use this list to manually update the Airtable Truck field. For visits where our DB has `NULL` truck (Samsara had no GPS overlap with the property during the visit), the truck can\'t be determined automatically — flag those for ops to recall or to defer.\n');

  // B1. Pull AT visits with Goliath truck
  log('### Pulling Airtable visits with Truck="Goliath 5,000"...\n');
  const atVisits = await listAT('Visits',
    ['Truck','Visit Date','Service Type','Client Code','Status','Jobber Visit ID'],
    `AND(IS_AFTER({Visit Date},'2025-12-31'),OR(FIND('Goliath',ARRAYJOIN({Truck}))>0,{Truck}='Goliath'))`);
  log(`Found **${atVisits.length}** Airtable 2026 visits with Goliath label.\n`);

  // B2. For each, look up our DB's vehicle attribution
  log('### Cross-referencing with our DB (Supabase GPS-derived truck)...\n');
  const results = [];
  for (const av of atVisits) {
    const gid = av['Jobber Visit ID'];
    if (!gid) { results.push({...av, db_truck: 'NO_JOBBER_ID', db_date: null, db_visit_id: null}); continue; }
    try {
      const r = await pg(`
        SELECT v.id AS visit_id, v.visit_date::text AS visit_date, v.visit_status,
          vh.name AS db_truck
        FROM visits v
        JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
        LEFT JOIN vehicles vh ON vh.id = v.vehicle_id
        WHERE esl.source_id = '${gid.replace(/'/g, "''")}'
        LIMIT 1;`);
      if (r.length === 0) {
        results.push({...av, db_truck: 'NOT_IN_SUPABASE', db_date: null, db_visit_id: null});
      } else {
        results.push({...av, db_truck: r[0].db_truck || 'NULL', db_date: r[0].visit_date, db_visit_id: r[0].visit_id});
      }
    } catch (e) {
      results.push({...av, db_truck: 'ERROR', db_date: null, db_visit_id: null, error: e.message.slice(0,80)});
    }
  }

  // B3. Categorize + present
  const byTruck = {};
  for (const r of results) {
    const k = r.db_truck;
    if (!byTruck[k]) byTruck[k] = [];
    byTruck[k].push(r);
  }

  log('### Summary of correct attribution per our DB\n');
  log('| Our DB says truck = | Count | Action for ops |');
  log('|---|---|---|');
  for (const [truck, list] of Object.entries(byTruck).sort((a,b) => b[1].length - a[1].length)) {
    let action = '';
    if (truck === 'David') action = 'Update Airtable Truck → David 2,000';
    else if (truck === 'Moises') action = 'Update Airtable Truck → Moises 9,000';
    else if (truck === 'Cloggy') action = 'Update Airtable Truck → Cloggy 120';
    else if (truck === 'NULL') action = 'GPS had no overlap — defer to ops memory';
    else if (truck === 'NOT_IN_SUPABASE') action = 'Visit missing from our DB (AT-only); check separately';
    else if (truck === 'NO_JOBBER_ID') action = 'AT visit has no Jobber link; check separately';
    else action = `Manual review (${truck})`;
    log(`| ${truck} | ${list.length} | ${action} |`);
  }

  log('\n### Full reattribution list (CSV-friendly)\n');
  log('| Airtable Visit Date | Client Code | Service | AT Status | AT Truck (wrong) | Our DB truck (correct) | Our visit_id | Notes |');
  log('|---|---|---|---|---|---|---|---|');
  for (const r of results.sort((a,b) => (b['Visit Date']||'').localeCompare(a['Visit Date']||''))) {
    const note = r.error ? `error: ${r.error}` : (r.db_date && r.db_date !== r['Visit Date'] ? `date mismatch (DB: ${r.db_date})` : '');
    log(`| ${r['Visit Date']||'-'} | ${r['Client Code']||'-'} | ${r['Service Type']||'-'} | ${r['Status']||'-'} | ${r['Truck']||'-'} | ${r.db_truck} | ${r.db_visit_id || '-'} | ${note} |`);
  }

  // Write report
  const outPath = path.resolve(__dirname, `../../reports/null_audit_and_goliath_${today.replace(/-/g,'_')}.md`);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, md.join('\n'));
  console.log(`\n\n✓ Report written: ${outPath}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
