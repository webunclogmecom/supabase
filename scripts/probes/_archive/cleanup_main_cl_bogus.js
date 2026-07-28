// Cleanup bogus CL data created by the old "MAIN CL → CL" classification
// (pre-fix code, audit 2026-05-14).
//
// For each AT client whose Service Type contains "MAIN CL" but NOT "AUX Cleaning":
//   1. DELETE future cron-generated CL visits (phantoms — never performed)
//   2. UPDATE all past CL visits → service_type='GT' (real GT work, mislabeled)
//      Includes the 4 same-day-as-GT cases — they become "2 GT same day" rows,
//      a minor data-noise but better than FK violations from deleting past
//      visits that have Jobber notes/photos attached.
//   3. DELETE the bogus CL service_configs (now orphaned)
//
// Usage:
//   node cleanup_main_cl_bogus.js                       # dry-run on Prod
//   node cleanup_main_cl_bogus.js --execute             # write on Prod
//   node cleanup_main_cl_bogus.js --db=sandbox          # dry-run on Sandbox
//   node cleanup_main_cl_bogus.js --db=sandbox --execute
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const args = process.argv.slice(2);
const EXECUTE = args.includes('--execute');
const DB = (args.find(a => a.startsWith('--db=')) || '--db=prod').split('=')[1];
const isProd = DB === 'prod';

const PROJECT = isProd ? process.env.SUPABASE_PROJECT_ID : process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

if (!PROJECT || !PAT) { console.error(`Missing project id or PAT for db=${DB}`); process.exit(1); }
console.log(`==== TARGET DB: ${DB.toUpperCase()} (${PROJECT}) — mode: ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'} ====\n`);

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) {
  const r = await http({hostname:'api.supabase.com',path:'/v1/projects/'+PROJECT+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}}, JSON.stringify({query:sql}));
  if(r.status>=300) throw new Error('PG '+r.status+': '+r.body.slice(0,300));
  return JSON.parse(r.body);
}
async function listAT(table, fields) {
  const out=[]; let offset; const enc=encodeURIComponent;
  do {
    const fp = (fields||[]).map(f => 'fields%5B%5D='+enc(f)).join('&');
    const path = '/v0/'+AT_BASE+'/'+enc(table)+'?'+fp+'&pageSize=100'+(offset?'&offset='+enc(offset):'');
    const r = await http({hostname:'api.airtable.com',path,method:'GET',headers:{Authorization:'Bearer '+AT_KEY}});
    if (r.status>=300) throw new Error('AT '+r.status+': '+r.body.slice(0,200));
    const j = JSON.parse(r.body);
    for (const rec of (j.records||[])) out.push({id:rec.id, ...rec.fields});
    offset = j.offset;
  } while (offset);
  return out;
}

(async () => {
  // 1. Find AT clients with MAIN CL but NOT AUX Cleaning
  const at = await listAT('Clients', ['Client Name','Client Code #3','Service Type']);
  const targetCodes = at.filter(c => {
    const st = c['Service Type']; if (!Array.isArray(st)) return false;
    const hasMain = st.some(v => ((v && v.name) || v || '').toString().toLowerCase().includes('main cl'));
    const hasAux  = st.some(v => ((v && v.name) || v || '').toString().toLowerCase().includes('aux cleaning'));
    return hasMain && !hasAux;
  }).map(c => c['Client Code #3']).filter(Boolean);
  console.log(`AT clients targeted (MAIN CL, no AUX Cleaning): ${targetCodes.length}`);

  if (!targetCodes.length) { console.log('Nothing to clean. Bye.'); return; }
  const codeList = targetCodes.map(c => `'${c.replace(/'/g, "''")}'`).join(',');

  // 2. Pre-counts (dry-run inspection)
  const pre = await pg(`
    WITH t AS (SELECT id FROM clients WHERE client_code IN (${codeList}))
    SELECT
      (SELECT COUNT(*)::int FROM visits WHERE service_type='CL' AND source='supabase_cron' AND visit_date >= CURRENT_DATE AND client_id IN (SELECT id FROM t)) AS will_delete_future_cron_cl,
      (SELECT COUNT(*)::int FROM visits WHERE service_type='CL' AND client_id IN (SELECT id FROM t)
         AND NOT (source='supabase_cron' AND visit_date >= CURRENT_DATE)) AS will_relabel_to_gt,
      (SELECT COUNT(*)::int FROM service_configs WHERE service_type='CL' AND client_id IN (SELECT id FROM t)) AS will_delete_cl_configs;
  `);
  console.log('\nPre-cleanup counts:');
  console.table(pre);

  if (!EXECUTE) {
    console.log('\n[DRY-RUN] No writes. Re-run with --execute to apply.');
    return;
  }

  // 3. Execute cleanup as a single transaction
  console.log('\nExecuting cleanup (single transaction)...');
  const cleanupSql = `
    BEGIN;
    -- Step 1: delete future cron-generated CL visits (phantoms, no FK risk)
    WITH t AS (SELECT id FROM clients WHERE client_code IN (${codeList}))
    DELETE FROM visits
    WHERE service_type='CL' AND source='supabase_cron'
      AND visit_date >= CURRENT_DATE
      AND client_id IN (SELECT id FROM t);
    -- Step 2: relabel all remaining (past) CL visits to GT.
    --   Includes the same-day-as-GT cases — they become "2 GT same day".
    --   UPDATE has no FK issues, so this works even when visits have notes.
    WITH t AS (SELECT id FROM clients WHERE client_code IN (${codeList}))
    UPDATE visits SET service_type='GT'
    WHERE service_type='CL'
      AND client_id IN (SELECT id FROM t);
    -- Step 3: delete the bogus CL service_configs (now orphaned)
    WITH t AS (SELECT id FROM clients WHERE client_code IN (${codeList}))
    DELETE FROM service_configs
    WHERE service_type='CL'
      AND client_id IN (SELECT id FROM t);
    COMMIT;
  `;
  await pg(cleanupSql);

  // 4. Post-counts to verify
  const post = await pg(`
    WITH t AS (SELECT id FROM clients WHERE client_code IN (${codeList}))
    SELECT
      (SELECT COUNT(*)::int FROM visits WHERE service_type='CL' AND client_id IN (SELECT id FROM t)) AS remaining_cl_visits_for_targets,
      (SELECT COUNT(*)::int FROM service_configs WHERE service_type='CL' AND client_id IN (SELECT id FROM t)) AS remaining_cl_configs_for_targets,
      -- Sanity: total upcoming visits in DB
      (SELECT COUNT(*)::int FROM visits WHERE visit_date >= CURRENT_DATE) AS total_upcoming_now;
  `);
  console.log('\nPost-cleanup counts (should be 0 / 0 for the first two):');
  console.table(post);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
