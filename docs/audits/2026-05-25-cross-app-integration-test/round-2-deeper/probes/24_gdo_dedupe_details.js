// Surface every ambiguous gdos row before asking Fred to pick a winner.
const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../../.env') });
const PAT = process.env.SUPABASE_PAT;
const PROD = 'wbasvhvvismukaqdnouk';
function pg(sql) { return new Promise((res, rej) => { const body = JSON.stringify({ query: sql }); const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)}},r=>{let d='';r.on('data',c=>d+=c);r.on('end',()=>{try{res(JSON.parse(d))}catch(_){res(d)}})});req.on('error',rej);req.write(body);req.end();}); }
(async () => {
  console.log('=== A. The 3 duplicate gdo_number pairs ===');
  console.log(await pg(`
    WITH dupes AS (
      SELECT gdo_number FROM gdos WHERE status='ACTIVE' GROUP BY gdo_number HAVING COUNT(*) > 1
    )
    SELECT g.id, g.gdo_number, g.client_id, c.client_code, c.name AS client_name,
           g.property_id, p.address AS property_addr,
           g.permit_expiration::text, g.permit_document_path,
           g.created_at::text AS created_at, g.updated_at::text AS updated_at,
           g.notes,
           (SELECT COUNT(*)::int FROM derm_manifests dm WHERE dm.gdo_id = g.id) AS manifests_using_this_gdo
    FROM gdos g
    JOIN dupes d USING (gdo_number)
    LEFT JOIN clients c ON c.id = g.client_id
    LEFT JOIN properties p ON p.id = g.property_id
    ORDER BY g.gdo_number, g.id;
  `));

  console.log('\n=== B. Property 42 — 3 active GDOs ===');
  console.log(await pg(`
    SELECT g.id, g.gdo_number, g.client_id, c.client_code, c.name AS client_name,
           p.address AS property_addr,
           g.permit_expiration::text, g.created_at::text, g.updated_at::text,
           g.notes,
           (SELECT COUNT(*)::int FROM derm_manifests dm WHERE dm.gdo_id = g.id) AS manifests_using_this_gdo
    FROM gdos g
    LEFT JOIN clients c ON c.id = g.client_id
    LEFT JOIN properties p ON p.id = g.property_id
    WHERE g.property_id = 42 AND g.status='ACTIVE'
    ORDER BY g.id;
  `));

  console.log('\n=== C. Client 369 — 3 active GDOs ===');
  console.log(await pg(`
    SELECT g.id, g.gdo_number, g.client_id, g.property_id,
           c.client_code, c.name AS client_name,
           p.address AS property_addr,
           g.permit_expiration::text, g.created_at::text, g.updated_at::text,
           (SELECT COUNT(*)::int FROM derm_manifests dm WHERE dm.gdo_id = g.id) AS manifests_using_this_gdo
    FROM gdos g
    LEFT JOIN clients c ON c.id = g.client_id
    LEFT JOIN properties p ON p.id = g.property_id
    WHERE g.client_id = 369 AND g.status='ACTIVE'
    ORDER BY g.id;
  `));

  console.log('\n=== D. Final count summary ===');
  console.log(await pg(`
    SELECT
      COUNT(*)::int AS total,
      COUNT(DISTINCT gdo_number) FILTER (WHERE status='ACTIVE')::int AS distinct_numbers_active,
      COUNT(*) FILTER (WHERE status='ACTIVE')::int AS active_rows
    FROM gdos;
  `));
})().catch(e => console.error('FATAL', e));
