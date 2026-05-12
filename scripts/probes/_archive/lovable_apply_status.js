require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
function pg(sql) { return new Promise((res, rej) => {
  const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${SBX}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res({status:x.statusCode,body:b}));});
  req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
});}
async function q(sql) { const r = await pg(sql); if (r.status >= 300) { console.error(`PG ${r.status}: ${r.body}`); return []; } return JSON.parse(r.body); }

(async () => {
  console.log('=== Any table starting with "app_" in Sandbox right now? ===');
  const tables = await q(`SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_name LIKE 'app_%' ORDER BY 1;`);
  console.log(JSON.stringify(tables, null, 2));

  console.log('\n=== Anything created in public schema in the last hour? ===');
  const recent = await q(`
    SELECT n.nspname AS schema, c.relname AS name, c.relkind,
      to_char(c.relfilenode::regclass::oid::int::bigint::text::numeric, 'FM999999999') AS oid_str,
      pg_catalog.obj_description(c.oid, 'pg_class') AS comment
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND c.relkind IN ('r','v','m')
    ORDER BY c.oid DESC LIMIT 10;`);
  console.log(JSON.stringify(recent, null, 2));

  console.log('\n=== Migration tracking — does supabase_migrations schema exist? ===');
  const migSchema = await q(`SELECT schema_name FROM information_schema.schemata WHERE schema_name='supabase_migrations';`);
  console.log('  supabase_migrations schema:', migSchema.length ? 'exists' : 'not found');

  if (migSchema.length) {
    const migTables = await q(`SELECT table_name FROM information_schema.tables WHERE table_schema='supabase_migrations';`);
    console.log('  migration tables:', migTables.map(t => t.table_name));
    if (migTables.find(t => t.table_name === 'schema_migrations')) {
      const recent = await q(`SELECT version, name, executed_statements FROM supabase_migrations.schema_migrations ORDER BY version DESC LIMIT 15;`);
      console.log('  Last 15 migrations:');
      for (const m of recent) console.log(`    ${m.version}  ${m.name || '(no name)'}`);
    }
  }

  console.log('\n=== Current Sandbox public-schema table count ===');
  const cnt = await q(`SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';`);
  console.log(`  ${cnt[0].n} tables`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
