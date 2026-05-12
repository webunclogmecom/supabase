require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
function pg(sql) { return new Promise((res, rej) => {
  const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${SBX}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res({status:x.statusCode,body:b}));});
  req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
});}
async function q(sql) { const r = await pg(sql); if (r.status >= 300) { console.error(`PG ${r.status}: ${r.body.slice(0,300)}`); return []; } return JSON.parse(r.body); }
(async () => {
  // Look at the actual columns of schema_migrations
  const cols = await q(`SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='supabase_migrations' AND table_name='schema_migrations' ORDER BY ordinal_position;`);
  console.log('=== schema_migrations columns ===');
  console.log(JSON.stringify(cols, null, 2));

  // Pull recent rows with whatever columns exist
  const recent = await q(`SELECT * FROM supabase_migrations.schema_migrations ORDER BY version DESC LIMIT 20;`);
  console.log(`\n=== Last 20 applied migrations ===`);
  for (const m of recent) {
    const stmts = m.statements ? `${m.statements.length} stmts` : '';
    console.log(`  ${m.version}  ${m.name || ''}  ${stmts}`);
  }

  // Specifically look for app_photo_classifications, app_property_overrides mentions
  console.log(`\n=== Any migration mentioning app_photo_classifications or app_property_overrides ===`);
  const mentions = await q(`
    SELECT version, name
    FROM supabase_migrations.schema_migrations
    WHERE
      name ILIKE '%photo_classif%' OR name ILIKE '%property_override%'
      OR EXISTS (
        SELECT 1 FROM unnest(statements) AS s
        WHERE s ILIKE '%app_photo_classif%' OR s ILIKE '%app_property_override%'
      )
    ORDER BY version DESC;`);
  if (mentions.length) {
    for (const m of mentions) console.log(`  ${m.version}  ${m.name}`);
  } else {
    console.log('  (none — confirms Pattern B tables NOT applied)');
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
