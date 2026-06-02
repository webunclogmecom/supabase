const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });
const PAT = process.env.SUPABASE_PAT;
function pg(sql) {
  return new Promise((res, rej) => {
    const b = JSON.stringify({ query: sql });
    const r = https.request({
      hostname: 'api.supabase.com', path: '/v1/projects/wbasvhvvismukaqdnouk/database/query',
      method: 'POST', headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(b) }
    }, rr => {
      let d = '';
      rr.on('data', c => (d += c));
      rr.on('end', () => { try { res(JSON.parse(d)); } catch (_) { res(d); } });
    });
    r.on('error', rej); r.write(b); r.end();
  });
}
(async () => {
  console.log('--- All UNIQUE indexes on FK tables that include client_id or entity_id ---');
  console.log(JSON.stringify(await pg(`
    SELECT t.relname AS table_name, i.relname AS index_name, pg_get_indexdef(i.oid) AS indexdef
    FROM pg_class t
    JOIN pg_index ix ON ix.indrelid = t.oid
    JOIN pg_class i ON i.oid = ix.indexrelid
    WHERE t.relname IN (
      'visits','service_configs','gdos','derm_manifests','properties',
      'client_contacts','notes','invoices','quotes','jobs',
      'jobber_oversized_attachments','entity_source_links'
    )
    AND ix.indisunique = true
    AND EXISTS (
      SELECT 1 FROM pg_attribute a
      WHERE a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
        AND a.attname IN ('client_id','entity_id')
    )
    ORDER BY t.relname, i.relname;
  `), null, 2));

  console.log('\n--- Pair 4: duplicate derm_manifests between 5 and 147 ---');
  console.log(JSON.stringify(await pg(`
    SELECT white_manifest_number,
      array_agg(client_id ORDER BY client_id) AS clients,
      array_agg(id ORDER BY client_id) AS ids
    FROM public.derm_manifests
    WHERE client_id IN (5, 147)
      AND white_manifest_number IN (
        SELECT white_manifest_number FROM public.derm_manifests WHERE client_id = 147
        INTERSECT
        SELECT white_manifest_number FROM public.derm_manifests WHERE client_id = 5
      )
    GROUP BY white_manifest_number
    ORDER BY white_manifest_number;
  `), null, 2));

  console.log('\n--- For all 4 pairs: dup manifest counts per pair ---');
  for (const [survivor, loser] of [[384, 336], [371, 224], [343, 41], [5, 147]]) {
    const r = await pg(`
      SELECT COUNT(*)::int AS dup_count
      FROM public.derm_manifests
      WHERE client_id IN (${survivor}, ${loser})
        AND white_manifest_number IN (
          SELECT white_manifest_number FROM public.derm_manifests WHERE client_id = ${loser}
          INTERSECT
          SELECT white_manifest_number FROM public.derm_manifests WHERE client_id = ${survivor}
        );
    `);
    console.log(`Pair survivor=${survivor} loser=${loser}: dup_count=${JSON.stringify(r)}`);
  }
})().catch(e => console.error(e));
