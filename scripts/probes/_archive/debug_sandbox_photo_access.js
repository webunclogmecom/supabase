// Debug: why can't Yannick see photos in the Lovable Sandbox app?
// Tests:
//   1. Bucket public flag still true?
//   2. storage.objects RLS policies — does anon have SELECT?
//   3. Sample photo path actually fetchable via public URL?
//   4. photo_links/photos table has data Lovable can read?
//   5. Any storage objects missing for 2026 photos that should exist?
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PAT = process.env.SUPABASE_PAT;
const SB = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const SB_URL = `https://${SB}.supabase.co`;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString(), headers: r.headers }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${SB}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  return JSON.parse(r.body);
}

(async () => {
  // 1. Bucket public flag
  console.log('=== 1. Bucket flag ===');
  const b = await pg(`SELECT id, name, public FROM storage.buckets WHERE name = 'GT - Visits Images'`);
  console.log(`  ${b[0].name}: public=${b[0].public}`);

  // 2. Storage policies
  console.log('\n=== 2. storage.objects policies in Sandbox ===');
  const pols = await pg(`
    SELECT polname, polcmd, polroles::regrole[]::text[] AS roles,
           pg_get_expr(polqual, polrelid) AS using_expr
    FROM pg_policy
    WHERE polrelid = 'storage.objects'::regclass
    ORDER BY polname;
  `);
  for (const p of pols) {
    const cmd = ({r:'SELECT',a:'INSERT',w:'UPDATE',d:'DELETE','*':'ALL'})[p.polcmd] || p.polcmd;
    console.log(`  ${p.polname.padEnd(50)} ${cmd.padEnd(7)} roles=${p.roles.join(',').padEnd(30)} using=${(p.using_expr || '').slice(0, 80)}`);
  }

  // 3. Sample photo path from DB
  console.log('\n=== 3. Sample 2026 photo paths ===');
  const samples = await pg(`
    SELECT p.id, p.storage_path, p.file_name, p.created_at::text
    FROM photos p
    JOIN photo_links pl ON pl.photo_id = p.id AND pl.entity_type='note'
    JOIN notes n ON n.id = pl.entity_id
    WHERE n.note_date >= '2026-01-01'
    ORDER BY p.created_at DESC
    LIMIT 3;
  `);
  for (const s of samples) console.log(`  ${s.storage_path}`);

  // 4. Try to fetch via public URL (no auth)
  if (samples.length) {
    const path = samples[0].storage_path;
    const encoded = path.split('/').map(encodeURIComponent).join('/');
    const url = `/storage/v1/object/public/${encodeURIComponent('GT - Visits Images')}/${encoded}`;
    console.log(`\n=== 4. Public fetch test ===`);
    console.log(`  URL: ${SB_URL}${url}`);
    const r = await http({ hostname: `${SB}.supabase.co`, path: url, method: 'GET', headers: {} });
    console.log(`  Public fetch status: ${r.status}  content-type=${r.headers['content-type']}  bytes=${r.body.length}`);
    if (r.status >= 300) console.log(`    body: ${r.body.slice(0, 200)}`);
  }

  // 5. photo_links + photos counts
  console.log('\n=== 5. Sandbox row counts ===');
  const counts = await pg(`
    SELECT 'photos total' AS t, COUNT(*) AS n FROM photos UNION ALL
    SELECT 'photos with storage_path', COUNT(*) FROM photos WHERE storage_path IS NOT NULL UNION ALL
    SELECT 'photo_links', COUNT(*) FROM photo_links UNION ALL
    SELECT 'photo_links to visits', COUNT(*) FROM photo_links WHERE entity_type='visit' UNION ALL
    SELECT 'photo_links to notes', COUNT(*) FROM photo_links WHERE entity_type='note' UNION ALL
    SELECT 'visits with linked photos', COUNT(DISTINCT entity_id) FROM photo_links WHERE entity_type='visit' UNION ALL
    SELECT 'notes with linked photos', COUNT(DISTINCT entity_id) FROM photo_links WHERE entity_type='note';
  `);
  for (const c of counts) console.log(`  ${c.t.padEnd(28)} ${c.n}`);

  // 6. Test a photo via authenticated path too (would require Lovable session JWT — we don't have it,
  //    but we can confirm whether authenticated read works using the service-role token as a strong proxy)
  // Skipped — the public URL test in (4) is the relevant one for Lovable's current behavior.
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
