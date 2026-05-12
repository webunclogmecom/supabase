// Same as goliath_list_by_date_match.js but includes the Airtable record ID
// (rec...) on every row, plus emits a ready-to-PATCH JSON payload for an AI
// assistant (or curl loop) to bulk-update the Truck field.
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

// Map our DB's truck name → Airtable Truck single-select value
// (confirmed by earlier audit of distinct AT Truck values 2026)
const TRUCK_TO_AT_VALUE = {
  'Moises':  'Moises 9,000',
  'David':   'David 2,000',
  'Cloggy':  'Cloggy 120',
  'Goliath': 'Goliath 5,000', // for completeness — won't be used by this script
};

(async () => {
  console.log('[1/4] Pull Airtable visits with Goliath truck (2026)...');
  const atVisits = await listAT('Visits',
    ['Truck','Visit Date','Service Type','Client Code','Status','Jobber Visit ID'],
    `AND(IS_AFTER({Visit Date},'2025-12-31'),OR(FIND('Goliath',ARRAYJOIN({Truck}))>0,{Truck}='Goliath'))`);
  console.log(`  ${atVisits.length} AT visits to reattribute`);

  console.log('\n[2/4] Pull 2026 Supabase visits + truck attribution...');
  const sbxVisits = await pg(`
    SELECT v.id AS visit_id, c.client_code, v.visit_date::text AS visit_date,
      v.visit_status, vh.name AS db_truck, v.title
    FROM visits v
    LEFT JOIN clients c ON c.id = v.client_id
    LEFT JOIN vehicles vh ON vh.id = v.vehicle_id
    WHERE v.visit_date >= '2026-01-01';`);
  console.log(`  ${sbxVisits.length} Supabase visits indexed`);

  const sbxIndex = new Map();
  for (const v of sbxVisits) {
    if (!v.client_code) continue;
    const key = `${v.client_code}|${v.visit_date}`;
    if (!sbxIndex.has(key)) sbxIndex.set(key, []);
    sbxIndex.get(key).push(v);
  }
  function findMatches(client_code, target_date, tolerance_days = 1) {
    const matches = [];
    for (let off = -tolerance_days; off <= tolerance_days; off++) {
      const [y, m, d] = target_date.split('-').map(Number);
      const dt = new Date(Date.UTC(y, m - 1, d));
      dt.setUTCDate(dt.getUTCDate() + off);
      const altDate = dt.toISOString().slice(0, 10);
      const key = `${client_code}|${altDate}`;
      if (sbxIndex.has(key)) matches.push(...sbxIndex.get(key));
    }
    return matches;
  }

  console.log('\n[3/4] Match AT → Supabase by (client_code + visit_date ±1)...');
  const results = [];
  for (const av of atVisits) {
    const clientCode = Array.isArray(av['Client Code']) ? av['Client Code'][0] : av['Client Code'];
    const visitDate = av['Visit Date'];
    if (!clientCode || !visitDate) {
      results.push({...av, at_record_id: av.id, db_truck: 'NO_CLIENT_OR_DATE'});
      continue;
    }
    const matches = findMatches(clientCode, visitDate, 1);
    if (matches.length === 0) {
      results.push({...av, at_record_id: av.id, db_truck: 'NO_MATCH'});
    } else {
      const withTruck = matches.find(m => m.db_truck) || matches[0];
      results.push({
        ...av,
        at_record_id: av.id,
        db_truck: withTruck.db_truck || 'NULL',
        db_visit_id: withTruck.visit_id,
        db_visit_date: withTruck.visit_date,
        db_title: withTruck.title,
        ambiguous: matches.length > 1 ? matches.length : null,
      });
    }
  }

  // Group + summarize
  const byTruck = {};
  for (const r of results) {
    if (!byTruck[r.db_truck]) byTruck[r.db_truck] = [];
    byTruck[r.db_truck].push(r);
  }
  console.log('\nSummary:');
  for (const [t, list] of Object.entries(byTruck).sort((a,b) => b[1].length - a[1].length)) {
    console.log(`  ${t.padEnd(20)} ${list.length}`);
  }

  // Build markdown report
  const md = [];
  md.push(`# Goliath reattribution list with Airtable Record IDs — ${new Date().toISOString().slice(0,10)}\n`);
  md.push(`## Summary\n`);
  md.push(`| Correct truck (per Supabase GPS) | Count | AT field update | AI/script can apply? |`);
  md.push(`|---|---|---|---|`);
  for (const [truck, list] of Object.entries(byTruck).sort((a,b) => b[1].length - a[1].length)) {
    const atValue = TRUCK_TO_AT_VALUE[truck] || null;
    const action = atValue ? `Set \`Truck = "${atValue}"\`` : (truck === 'NULL' ? 'No GPS — defer to operator' : truck === 'NO_MATCH' ? 'No DB match — defer' : 'Manual review');
    const automatable = atValue ? '✅ yes' : '⚠ no (manual)';
    md.push(`| ${truck} | ${list.length} | ${action} | ${automatable} |`);
  }

  md.push(`\n## How to apply automatically\n`);
  md.push(`A ready-to-execute JSON payload is at \`reports/goliath_at_patch_payload_${new Date().toISOString().slice(0,10).replace(/-/g,'_')}.json\`. Format is Airtable's batch-update spec (up to 10 records per PATCH request). Hand it to any AI assistant with Airtable API access, or curl it directly:\n`);
  md.push('```bash');
  md.push(`# For each batch of 10 in the JSON file:`);
  md.push(`curl -X PATCH "https://api.airtable.com/v0/${AT_BASE}/Visits" \\\\`);
  md.push(`  -H "Authorization: Bearer $AIRTABLE_API_KEY" \\\\`);
  md.push(`  -H "Content-Type: application/json" \\\\`);
  md.push(`  -d @batch_N.json`);
  md.push('```');
  md.push(`\nOr if you have an MCP-connected Airtable AI assistant: just paste the JSON and ask it to apply each record as a Visits-table update with the given \`Truck\` field value.\n`);

  // Per-group full list (now includes AT record ID first column)
  for (const groupTruck of ['Moises', 'David', 'Cloggy', 'NULL', 'NO_MATCH', 'NO_CLIENT_OR_DATE']) {
    const group = (byTruck[groupTruck] || []).sort((a,b) => (b['Visit Date']||'').localeCompare(a['Visit Date']||''));
    if (group.length === 0) continue;
    const atValue = TRUCK_TO_AT_VALUE[groupTruck];
    md.push(`\n## ${groupTruck} (${group.length})${atValue ? ` — set \`Truck = "${atValue}"\`` : ''}\n`);
    md.push(`| AT Record ID | AT Visit Date | Client Code | Service | AT Status | DB visit_id | DB date (if mismatch) |`);
    md.push(`|---|---|---|---|---|---|---|`);
    for (const r of group) {
      const clientCode = Array.isArray(r['Client Code']) ? r['Client Code'][0] : r['Client Code'];
      const dateMismatch = r.db_visit_date && r.db_visit_date !== r['Visit Date'] ? r.db_visit_date : '';
      md.push(`| \`${r.at_record_id}\` | ${r['Visit Date']||'-'} | ${clientCode||'-'} | ${r['Service Type']||'-'} | ${r['Status']||'-'} | ${r.db_visit_id || '-'} | ${dateMismatch} |`);
    }
  }

  // Build PATCH payload — only for trucks we can automate
  const automatable = results.filter(r => TRUCK_TO_AT_VALUE[r.db_truck]);
  const batches = [];
  for (let i = 0; i < automatable.length; i += 10) {
    batches.push({
      records: automatable.slice(i, i + 10).map(r => ({
        id: r.at_record_id,
        fields: { Truck: TRUCK_TO_AT_VALUE[r.db_truck] }
      }))
    });
  }

  // Write outputs
  const dateStamp = new Date().toISOString().slice(0,10).replace(/-/g,'_');
  const reportPath = path.resolve(__dirname, `../../reports/goliath_reattribution_with_recids_${dateStamp}.md`);
  const payloadPath = path.resolve(__dirname, `../../reports/goliath_at_patch_payload_${dateStamp}.json`);
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  fs.writeFileSync(reportPath, md.join('\n'));
  fs.writeFileSync(payloadPath, JSON.stringify({
    table_id: 'Visits',
    base_id: AT_BASE,
    total_records_to_update: automatable.length,
    n_batches: batches.length,
    batches,
  }, null, 2));

  console.log(`\n[4/4] Written:`);
  console.log(`  📄 ${reportPath}`);
  console.log(`  📄 ${payloadPath}`);
  console.log(`     ${batches.length} batches × ≤10 records = ${automatable.length} total auto-updates`);
  console.log(`     (${results.length - automatable.length} non-automatable: defer to manual review)`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
