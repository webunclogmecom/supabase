// Compare canonical-table row counts between Production and Sandbox.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const SBX  = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PAT  = process.env.SUPABASE_PAT;

const TABLES = [
  'clients','properties','client_contacts','service_configs','jobs','visits',
  'visit_assignments','invoices','line_items','quotes','notes','photos',
  'photo_links','derm_manifests','manifest_visits','inspections','employees',
  'vehicles','vehicle_telemetry_readings','entity_source_links',
  'jobber_oversized_attachments',
];

function q(projectId, sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${projectId}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,400)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  const sql = TABLES.map(t => `SELECT '${t}' AS t, COUNT(*)::bigint AS n FROM ${t}`).join(' UNION ALL ');
  const [prod, sbx] = await Promise.all([q(PROD, sql), q(SBX, sql)]);
  const map = (rows) => Object.fromEntries(rows.map(r => [r.t, Number(r.n)]));
  const p = map(prod), s = map(sbx);

  const out = TABLES.map(t => ({
    table: t,
    production: p[t],
    sandbox: s[t],
    match: p[t] === s[t] ? '✓' : `✗ Δ=${s[t] - p[t]}`,
  }));
  console.table(out);

  const mismatches = out.filter(r => r.match !== '✓');
  console.log(`\n${mismatches.length === 0 ? '✓ Full parity' : '✗ ' + mismatches.length + ' mismatches'}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
