// Export every public + storage policy from Sandbox so we can mirror them
// on Production. Yannick added these via Lovable; this captures them.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const SBX_PROJECT_ID = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${SBX_PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,400)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log('=== Sandbox: public-schema policies on tables RLS-affected ===\n');
  const targets = ['notes','photos','photo_links','vehicle_telemetry_readings',
                   'jobber_oversized_attachments','webhook_events_log','webhook_tokens','employees'];
  console.table(await q(`
    SELECT tablename, policyname, cmd,
           array_to_string(roles, ',') AS roles,
           qual AS using_clause,
           with_check
    FROM pg_policies
    WHERE schemaname='public' AND tablename = ANY(ARRAY[${targets.map(t=>`'${t}'`).join(',')}])
    ORDER BY tablename, policyname;
  `));

  console.log('\n=== Sandbox: storage.objects policies on GT - Visits Images ===\n');
  console.table(await q(`
    SELECT policyname, cmd,
           array_to_string(roles, ',') AS roles,
           qual AS using_clause,
           with_check
    FROM pg_policies
    WHERE schemaname='storage' AND tablename='objects'
    ORDER BY policyname;
  `));

  console.log('\n=== Sandbox: storage.buckets policies ===\n');
  console.table(await q(`
    SELECT policyname, cmd,
           array_to_string(roles, ',') AS roles,
           qual AS using_clause,
           with_check
    FROM pg_policies
    WHERE schemaname='storage' AND tablename='buckets'
    ORDER BY policyname;
  `));

  console.log('\n=== Sandbox: bucket configs ===\n');
  console.table(await q(`
    SELECT id, name, public, file_size_limit, allowed_mime_types
    FROM storage.buckets ORDER BY id;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
