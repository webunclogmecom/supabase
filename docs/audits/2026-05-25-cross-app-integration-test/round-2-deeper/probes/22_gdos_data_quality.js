// Check gdos data quality to decide if hardening constraints are safe to add
const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../../.env') });
const PAT = process.env.SUPABASE_PAT;
const PROD = 'wbasvhvvismukaqdnouk';
function pg(sql) { return new Promise((res, rej) => { const body = JSON.stringify({ query: sql }); const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json','Content-Length':Buffer.byteLength(body)}},r=>{let d='';r.on('data',c=>d+=c);r.on('end',()=>{try{res(JSON.parse(d))}catch(_){res(d)}})});req.on('error',rej);req.write(body);req.end();}); }
(async () => {
  console.log('=== 1. NULL counts in gdos ===');
  console.log(await pg(`
    SELECT
      COUNT(*)::int AS total,
      COUNT(*) FILTER (WHERE property_id IS NULL)::int AS null_property_id,
      COUNT(*) FILTER (WHERE client_id IS NULL)::int AS null_client_id,
      COUNT(*) FILTER (WHERE gdo_number IS NULL OR gdo_number = '')::int AS empty_gdo_number,
      COUNT(*) FILTER (WHERE permit_expiration IS NULL)::int AS null_expiration,
      COUNT(*) FILTER (WHERE permit_document_path IS NULL)::int AS null_pdf,
      COUNT(*) FILTER (WHERE status = 'ACTIVE')::int AS status_active,
      COUNT(*) FILTER (WHERE status != 'ACTIVE')::int AS status_not_active
    FROM gdos;
  `));

  console.log('\n=== 2. Duplicate gdo_number? ===');
  console.log(await pg(`
    SELECT gdo_number, COUNT(*)::int AS n
    FROM gdos
    GROUP BY gdo_number
    HAVING COUNT(*) > 1
    ORDER BY n DESC;
  `));

  console.log('\n=== 3. Multiple ACTIVE gdos per property? ===');
  console.log(await pg(`
    SELECT property_id, COUNT(*)::int AS n,
           ARRAY_AGG(gdo_number) AS gdo_numbers,
           ARRAY_AGG(id) AS gdo_ids
    FROM gdos
    WHERE status='ACTIVE' AND property_id IS NOT NULL
    GROUP BY property_id
    HAVING COUNT(*) > 1
    ORDER BY n DESC LIMIT 10;
  `));

  console.log('\n=== 4. Multiple ACTIVE gdos per client (no property_id set)? ===');
  console.log(await pg(`
    SELECT client_id, COUNT(*)::int AS n
    FROM gdos
    WHERE status='ACTIVE'
    GROUP BY client_id
    HAVING COUNT(*) > 1
    ORDER BY n DESC LIMIT 5;
  `));

  console.log('\n=== 5. Status value distribution (sanity check) ===');
  console.log(await pg(`SELECT status, COUNT(*)::int AS n FROM gdos GROUP BY status ORDER BY n DESC;`));

  console.log('\n=== 6. gdo_number format check ===');
  console.log(await pg(`
    SELECT
      COUNT(*) FILTER (WHERE gdo_number ~ '^GDO-[0-9]+$')::int AS matches_gdo_pattern,
      COUNT(*) FILTER (WHERE gdo_number !~ '^GDO-[0-9]+$')::int AS other_format,
      ARRAY_AGG(DISTINCT gdo_number) FILTER (WHERE gdo_number !~ '^GDO-[0-9]+$') AS oddities
    FROM gdos;
  `));
})().catch(e => console.error('FATAL', e));
