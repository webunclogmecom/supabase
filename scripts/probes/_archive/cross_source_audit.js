// 3-source audit: AT vs Jobber vs Samsara vs Supabase.
// For each dimension (clients, service-type subscriptions, visits, vehicles,
// properties), reports records that exist in one source but are missing or
// stale in another. Read-only — no writes.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:'/v1/projects/'+PROD+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error('PG '+r.status+': '+r.body.slice(0,300)); return JSON.parse(r.body); }
async function listAT(table, fields, filter) {
  const out=[]; let offset; const enc=encodeURIComponent;
  do {
    const fp = (fields||[]).map(f => 'fields%5B%5D='+enc(f)).join('&');
    const ff = filter ? '&filterByFormula='+enc(filter) : '';
    const path = '/v0/'+AT_BASE+'/'+enc(table)+'?'+fp+'&pageSize=100'+ff+(offset?'&offset='+enc(offset):'');
    const r = await http({hostname:'api.airtable.com',path,method:'GET',headers:{Authorization:'Bearer '+AT_KEY}});
    if (r.status>=300) throw new Error('AT '+r.status+': '+r.body.slice(0,200));
    const j = JSON.parse(r.body);
    for (const rec of (j.records||[])) out.push({id:rec.id, ...rec.fields});
    offset = j.offset;
  } while (offset);
  return out;
}

const findings = []; // {section, severity, summary, detail}
const log = (section, severity, summary, detail) => findings.push({section, severity, summary, detail});

(async () => {
  console.log('Pulling data from all sources...');

  // 1. AT clients
  const atClients = await listAT('Clients',
    ['Client Name','ACTIVE/INACTIVE','Service Type','GT Frequency','CL Frequency','WD Frequency','Jobber Client ID','Samsara Address ID']);
  console.log('  AT clients:', atClients.length);

  // 2. AT visits 2026
  const atVisits2026 = await listAT('Visits',
    ['Visit Date','Service Type','Status','Truck','Client Code','Jobber Visit ID'],
    "IS_AFTER({Visit Date},'2025-12-31')");
  console.log('  AT 2026 visits:', atVisits2026.length);

  // 3. Sbx clients
  const sbxClients = await pg(`
    SELECT c.id, c.name, c.client_code, c.status,
      (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='airtable' LIMIT 1) AS at_id,
      (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='jobber'   LIMIT 1) AS jobber_id
    FROM clients c;`);
  console.log('  Sbx clients:', sbxClients.length);

  // 4. Sbx service_configs
  const sbxConfigs = await pg(`
    SELECT c.client_code, c.name, sc.service_type, sc.frequency_days, sc.price_per_visit, c.status
    FROM service_configs sc JOIN clients c ON c.id = sc.client_id;`);
  console.log('  Sbx service_configs:', sbxConfigs.length);

  // 5. Sbx 2026 visits
  const sbxVisits2026 = await pg(`
    SELECT v.id, v.visit_date::text AS vd, v.visit_status, v.service_type,
      c.client_code,
      (SELECT source_id FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable' LIMIT 1) AS at_id,
      (SELECT source_id FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber'   LIMIT 1) AS jobber_id
    FROM visits v LEFT JOIN clients c ON c.id=v.client_id
    WHERE v.visit_date >= '2026-01-01';`);
  console.log('  Sbx 2026 visits:', sbxVisits2026.length);

  // 6. Sbx vehicles + Samsara source links
  const sbxVehicles = await pg(`
    SELECT v.id, v.name,
      (SELECT source_id FROM entity_source_links WHERE entity_type='vehicle' AND entity_id=v.id AND source_system='samsara' LIMIT 1) AS samsara_id
    FROM vehicles v;`);
  console.log('  Sbx vehicles:', sbxVehicles.length);

  // 7. Sbx properties + Samsara geofence link
  const sbxProps = await pg(`
    SELECT p.id, p.latitude, p.longitude, c.client_code, c.name AS client_name,
      (SELECT source_id FROM entity_source_links WHERE entity_type='property' AND entity_id=p.id AND source_system='samsara' LIMIT 1) AS samsara_id
    FROM properties p JOIN clients c ON c.id = p.client_id
    WHERE p.is_primary = true OR p.is_primary IS NULL;`);
  console.log('  Sbx (primary) properties:', sbxProps.length);

  // ============================================================
  // SECTION 1: AT clients that aren't in Sbx (missing Jobber link)
  // ============================================================
  console.log('\n[1/5] AT clients without Sbx entry...');
  const sbxByATId = new Map(sbxClients.filter(c => c.at_id).map(c => [c.at_id, c]));
  const atClientNotInSbx = atClients.filter(ac => !sbxByATId.has(ac.id));
  if (atClientNotInSbx.length) {
    log('clients', 'WARN',
      `${atClientNotInSbx.length} AT clients not linked to any Sbx client`,
      atClientNotInSbx.slice(0, 10).map(c => ({ at_id: c.id, name: c['Client Name'], status: (c['ACTIVE/INACTIVE']?.name) || c['ACTIVE/INACTIVE'] })));
  }

  // ============================================================
  // SECTION 2: Service-type coverage gaps
  // AT Clients with Service Type='LS' → do we have an LS service_config?
  // AT Clients with GT/CL/WD → do we have matching service_configs?
  // ============================================================
  console.log('[2/5] Service-type coverage AT vs Sbx...');
  const sbxConfigsByCC = new Map();
  for (const sc of sbxConfigs) {
    if (!sc.client_code) continue;
    const key = sc.client_code + '|' + sc.service_type;
    sbxConfigsByCC.set(key, sc);
  }

  // Build map AT_client_id → client_code via cross-join: AT id → Sbx client → client_code
  const atIdToCC = new Map();
  for (const c of sbxClients) if (c.at_id && c.client_code) atIdToCC.set(c.at_id, c.client_code);

  const missingByType = { GT: [], CL: [], WD: [], LS: [] };
  const surplusByType = { GT: [], CL: [], WD: [], LS: [] };
  // Walk AT clients
  for (const ac of atClients) {
    const cc = atIdToCC.get(ac.id);
    if (!cc) continue; // already reported in section 1
    const status = (ac['ACTIVE/INACTIVE']?.name) || ac['ACTIVE/INACTIVE'];
    if (status === 'INACTIVE') continue;
    const serviceTypes = Array.isArray(ac['Service Type']) ? ac['Service Type'].map(s => (s?.name)||s) : [];
    // Map AT's service type labels to our codes:
    //   "Grease Trap" → GT, "Main CL" → CL, "WD" → WD, "Lyft Station" → LS, "Sump Pump"/"Grey Water"/"Warranty" → ignore
    const wantedTypes = new Set();
    for (const st of serviceTypes) {
      const sl = (st || '').toLowerCase();
      if (sl.includes('grease trap') || sl === 'gt') wantedTypes.add('GT');
      else if (sl.includes('main cl') || sl.includes('cleaning') || sl === 'cl') wantedTypes.add('CL');
      else if (sl === 'wd' || sl.includes('warranty')) wantedTypes.add('WD');
      else if (sl.includes('lyft')) wantedTypes.add('LS');
    }
    // Also infer wanted types from frequency fields (some clients don't set Service Type but have a freq)
    if (ac['GT Frequency']) wantedTypes.add('GT');
    if (ac['CL Frequency']) wantedTypes.add('CL');
    if (ac['WD Frequency']) wantedTypes.add('WD');

    for (const t of wantedTypes) {
      const key = cc + '|' + t;
      if (!sbxConfigsByCC.has(key)) missingByType[t].push({ client_code: cc, name: ac['Client Name'], status });
    }

    // Surplus: Sbx has type but AT didn't say so
    for (const t of ['GT','CL','WD','LS']) {
      const key = cc + '|' + t;
      if (sbxConfigsByCC.has(key) && !wantedTypes.has(t)) {
        // Allow Sbx to have configs AT didn't mark — many clients have just a freq, no Service Type ticked.
        // Skip CL+GT noise; only flag LS which is the new service type
        if (t === 'LS') surplusByType[t].push({ client_code: cc, name: ac['Client Name'] });
      }
    }
  }
  for (const t of ['GT','CL','WD','LS']) {
    if (missingByType[t].length) log('service_coverage', 'WARN',
      `${missingByType[t].length} AT clients marked for ${t} but no Sbx service_config`,
      missingByType[t].slice(0, 10));
    if (surplusByType[t].length) log('service_coverage', 'INFO',
      `${surplusByType[t].length} Sbx clients have ${t} config but AT doesn't mark it`,
      surplusByType[t].slice(0, 10));
  }

  // ============================================================
  // SECTION 3: Visit volume sanity AT vs Sbx 2026
  // ============================================================
  console.log('[3/5] Visit-volume reconciliation...');
  const monthOf = d => (d || '').slice(0, 7);
  const atByMonth = {};
  for (const av of atVisits2026) {
    const m = monthOf(av['Visit Date']);
    if (!m) continue;
    atByMonth[m] = (atByMonth[m] || 0) + 1;
  }
  const sbxByMonth = {};
  for (const sv of sbxVisits2026) {
    const m = monthOf(sv.vd);
    if (!m) continue;
    sbxByMonth[m] = (sbxByMonth[m] || 0) + 1;
  }
  const months = [...new Set([...Object.keys(atByMonth), ...Object.keys(sbxByMonth)])].sort();
  const monthDetail = months.map(m => ({ month: m, AT: atByMonth[m] || 0, Sbx: sbxByMonth[m] || 0, delta: (sbxByMonth[m] || 0) - (atByMonth[m] || 0) }));
  log('visit_volume', 'INFO', `2026 visit counts per month (AT vs Sbx)`, monthDetail);

  // AT-only visits (linked to a Sbx client, but no Sbx visit on same date)
  const sbxKeysByCCDate = new Set(sbxVisits2026.filter(v => v.client_code && v.vd).map(v => v.client_code + '|' + v.vd));
  const atOnly = [];
  for (const av of atVisits2026) {
    const cc = Array.isArray(av['Client Code']) ? av['Client Code'][0] : av['Client Code'];
    if (!cc || !av['Visit Date']) continue;
    if (!sbxKeysByCCDate.has(cc + '|' + av['Visit Date'])) atOnly.push({ at_id: av.id, cc, date: av['Visit Date'], status: av['Status'], service: av['Service Type'] });
  }
  if (atOnly.length) log('visit_volume', 'WARN',
    `${atOnly.length} AT 2026 visits with no Sbx counterpart at same (client_code, date)`,
    atOnly.slice(0, 10));

  // Sbx-only visits (have client_code, no AT record on that date)
  const atKeysByCCDate = new Set(atVisits2026.map(av => {
    const cc = Array.isArray(av['Client Code']) ? av['Client Code'][0] : av['Client Code'];
    return cc && av['Visit Date'] ? (cc + '|' + av['Visit Date']) : null;
  }).filter(Boolean));
  const sbxOnly = [];
  for (const sv of sbxVisits2026) {
    if (!sv.client_code || !sv.vd) continue;
    if (!atKeysByCCDate.has(sv.client_code + '|' + sv.vd)) sbxOnly.push({ sbx_id: sv.id, cc: sv.client_code, date: sv.vd, status: sv.visit_status, service: sv.service_type });
  }
  if (sbxOnly.length) log('visit_volume', 'WARN',
    `${sbxOnly.length} Sbx 2026 visits with no AT counterpart at same (client_code, date)`,
    sbxOnly.slice(0, 10));

  // ============================================================
  // SECTION 4: Vehicles
  // ============================================================
  console.log('[4/5] Vehicles vs Samsara...');
  const unlinkedVehicles = sbxVehicles.filter(v => !v.samsara_id && v.name !== 'Goliath');
  if (unlinkedVehicles.length) log('vehicles', 'WARN',
    `${unlinkedVehicles.length} active vehicles without Samsara link (excluding Goliath)`,
    unlinkedVehicles);

  // ============================================================
  // SECTION 5: Property → Samsara geofence coverage
  // ============================================================
  console.log('[5/5] Property → Samsara geofence coverage...');
  const propsWithSamsara = sbxProps.filter(p => p.samsara_id).length;
  const propsTotal = sbxProps.length;
  log('properties', 'INFO',
    `${propsWithSamsara} of ${propsTotal} (primary) properties have a Samsara geofence link`,
    { coverage_pct: Math.round(propsWithSamsara / propsTotal * 100) });

  // AT clients with Samsara Address ID set vs Sbx property samsara_id
  const atWithSamsara = atClients.filter(ac => ac['Samsara Address ID']).length;
  const atSamsaraOrphans = atClients.filter(ac => {
    if (!ac['Samsara Address ID']) return false;
    const cc = atIdToCC.get(ac.id);
    if (!cc) return false;
    const matchingProp = sbxProps.find(p => p.client_code === cc);
    return matchingProp && !matchingProp.samsara_id;
  });
  if (atSamsaraOrphans.length) log('properties', 'WARN',
    `${atSamsaraOrphans.length} AT clients have a Samsara Address ID but our Sbx property doesn't carry the link`,
    atSamsaraOrphans.slice(0, 10).map(ac => ({ name: ac['Client Name'], samsara_id: ac['Samsara Address ID'] })));

  // ============================================================
  // OUTPUT
  // ============================================================
  console.log('\n' + '='.repeat(70));
  console.log('  CROSS-SOURCE AUDIT — findings');
  console.log('='.repeat(70));
  for (const f of findings) {
    console.log('\n[' + f.section + '] ' + f.severity + '  ' + f.summary);
    if (Array.isArray(f.detail)) {
      for (const d of f.detail) console.log('  · ' + JSON.stringify(d));
      if (f.detail.length === 10) console.log('  · (showing first 10)');
    } else {
      console.log('  · ' + JSON.stringify(f.detail));
    }
  }

  // Save JSON report
  const fs = require('fs'), path = require('path');
  const out = path.resolve(__dirname, '../../reports/cross_source_audit_' + new Date().toISOString().slice(0,10).replace(/-/g,'_') + '.json');
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, JSON.stringify({ generated_at: new Date().toISOString(), findings }, null, 2));
  console.log('\n📄 ' + out);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
