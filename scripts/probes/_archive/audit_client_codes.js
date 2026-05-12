// Audit all clients without a client_code and check whether we can recover the
// code from name parsing or from Airtable enrichment.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROJECT_ID = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,400)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log('=== 1. Total clients with vs without client_code (by status) ===');
  console.table(await q(`
    SELECT status,
           COUNT(*) FILTER (WHERE client_code IS NOT NULL) AS with_code,
           COUNT(*) FILTER (WHERE client_code IS NULL) AS without_code,
           COUNT(*) AS total
    FROM clients GROUP BY status ORDER BY status;
  `));

  console.log('\n=== 2. Clients without client_code — full list ===');
  const rows = await q(`
    SELECT c.id, c.name, c.status,
           (SELECT string_agg(source_system, ',') FROM entity_source_links
              WHERE entity_type='client' AND entity_id=c.id) AS sources
    FROM clients c
    WHERE c.client_code IS NULL
    ORDER BY c.status, c.name;
  `);
  console.table(rows);
  console.log(`Total: ${rows.length}`);

  console.log('\n=== 3. How many of those have a name like "<NNN>-<XX> ..." that we could parse a code out of? ===');
  console.table(await q(`
    SELECT
      COUNT(*) FILTER (WHERE name ~ '^\\s*\\d{3}-[A-Z0-9]+') AS parsable_code_in_name,
      COUNT(*) FILTER (WHERE name !~ '^\\s*\\d{3}-[A-Z0-9]+') AS unparsable
    FROM clients WHERE client_code IS NULL;
  `));

  console.log('\n=== 4. Of the unparsable ones, are they Airtable-linked (could pull from AT)? ===');
  console.table(await q(`
    SELECT c.id, c.name, c.status,
           (SELECT source_id FROM entity_source_links
              WHERE entity_type='client' AND source_system='airtable' AND entity_id=c.id LIMIT 1) AS airtable_id,
           (SELECT source_id FROM entity_source_links
              WHERE entity_type='client' AND source_system='jobber'   AND entity_id=c.id LIMIT 1) AS jobber_gid
    FROM clients c
    WHERE c.client_code IS NULL AND c.name !~ '^\\s*\\d{3}-[A-Z0-9]+'
    ORDER BY c.name;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
