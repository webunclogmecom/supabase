// 116_storage_buckets_audit.mjs
// Inventory Supabase Storage buckets + their policies. DERM Tracker upload
// is throwing "Bucket not found". Find what's there + which bucket the
// app expects.
import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${(await r.text()).slice(0, 600)}`);
  return JSON.parse(await r.text());
}
const banner = (s) => console.log(`\n${'='.repeat(70)}\n${s}\n${'='.repeat(70)}`);

banner('1. All storage buckets');
console.log(await pg(`
  SELECT id, name, public, file_size_limit, allowed_mime_types, created_at, updated_at
  FROM storage.buckets ORDER BY created_at;
`));

banner('2. Storage policies — what can be uploaded where');
console.log(await pg(`
  SELECT pol.policyname, pol.cmd, pol.permissive, pol.roles,
         pol.qual::text AS qual, pol.with_check::text AS with_check
  FROM pg_policies pol
  WHERE pol.schemaname='storage' AND pol.tablename='objects'
  ORDER BY pol.policyname;
`));

banner('3. Sample objects in each bucket (count + recent uploads)');
console.log(await pg(`
  SELECT bucket_id, COUNT(*)::int AS objects,
         MAX(created_at) AS last_upload
  FROM storage.objects
  GROUP BY bucket_id
  ORDER BY objects DESC;
`));

banner('4. Where do derm_manifest_url + derm_address_url paths point?');
console.log(await pg(`
  SELECT
    COUNT(*) FILTER (WHERE derm_manifest_url ILIKE '%storage/v1/object%')::int AS mfst_supabase_storage,
    COUNT(*) FILTER (WHERE derm_manifest_url ILIKE '%airtable%' OR derm_manifest_url ILIKE '%v5.airtableusercontent%')::int AS mfst_airtable,
    COUNT(*) FILTER (WHERE derm_manifest_url IS NULL)::int AS mfst_null,
    COUNT(*) FILTER (WHERE derm_address_url ILIKE '%storage/v1/object%')::int AS addr_supabase_storage,
    COUNT(*) FILTER (WHERE derm_address_url ILIKE '%airtable%')::int AS addr_airtable,
    COUNT(*) FILTER (WHERE derm_address_url IS NULL)::int AS addr_null
  FROM public.derm_manifests;
`));

banner('5. Sample paths from existing DERM manifests');
console.log(await pg(`
  SELECT id, white_manifest_number,
         LEFT(derm_manifest_url, 120) AS manifest_url_prefix,
         LEFT(derm_address_url, 120) AS address_url_prefix
  FROM public.derm_manifests
  WHERE derm_manifest_url IS NOT NULL
  ORDER BY id DESC LIMIT 5;
`));
