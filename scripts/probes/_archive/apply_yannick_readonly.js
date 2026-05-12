// Generates a strong random password, applies create_yannick_readonly_role.sql
// with the password substituted in, then verifies + prints connection strings
// for Fred to forward to Yannick.
//
// Idempotent for the role grants (CREATE ROLE wrapped in IF NOT EXISTS), but
// re-running this script generates a NEW password each time — only run once
// unless rotating.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs'); const path = require('path');
const crypto = require('crypto'); const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT  = process.env.SUPABASE_PAT;

// 32-char URL-safe random password
function generatePassword() {
  return crypto.randomBytes(24).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '')
    .slice(0, 32);
}

async function pg(query) {
  for (let i = 0; i < 3; i++) {
    const r = await new Promise((res, rej) => {
      const req = https.request({
        hostname: 'api.supabase.com',
        path: `/v1/projects/${PROD}/database/query`,
        method: 'POST',
        headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
      }, x => { let b = ''; x.on('data', d => b += d); x.on('end', () => res({ status: x.statusCode, body: b })); });
      req.on('error', rej); req.write(JSON.stringify({ query })); req.end();
    });
    if (r.status < 300) return JSON.parse(r.body);
    if (r.status >= 500 || r.status === 429) { await new Promise(rs => setTimeout(rs, 4000 * (i+1))); continue; }
    throw new Error(`PG ${r.status}: ${r.body.slice(0, 400)}`);
  }
  throw new Error('5xx exhausted');
}

(async () => {
  const sqlTemplate = fs.readFileSync(path.resolve(__dirname, '../migrations/create_yannick_readonly_role.sql'), 'utf8');

  // Check if role exists; if it does, ALTER PASSWORD instead of CREATE
  const existing = await pg(`SELECT 1 FROM pg_roles WHERE rolname='yannick_readonly'`);
  const exists = existing.length > 0;

  const password = generatePassword();

  // Substitute the literal password
  const sql = sqlTemplate.replace('REPLACE_WITH_REAL_PASSWORD_AT_APPLY_TIME', password);

  console.log(`Applying yannick_readonly role to PROD (${PROD})...`);
  await pg(sql);
  console.log('  ✓ migration applied');

  // If the role already existed, the IF-NOT-EXISTS guard skipped CREATE — set the password explicitly
  if (exists) {
    console.log('  role already existed — rotating password via ALTER ROLE');
    await pg(`ALTER ROLE yannick_readonly WITH PASSWORD '${password.replace(/'/g, "''")}'`);
  }

  // Verify
  const role = await pg(`SELECT rolname, rolcanlogin, rolsuper, rolcreaterole, rolcreatedb, rolconnlimit
    FROM pg_roles WHERE rolname='yannick_readonly'`);
  console.log('\nRole:');
  for (const r of role) console.log(`  ${JSON.stringify(r)}`);

  const grants = await pg(`SELECT table_schema, COUNT(*) AS tables_with_select
    FROM information_schema.role_table_grants
    WHERE grantee='yannick_readonly' AND privilege_type='SELECT'
    GROUP BY table_schema ORDER BY 1`);
  console.log('\nSELECT grants:');
  for (const g of grants) console.log(`  ${g.table_schema}: ${g.tables_with_select} tables`);

  const writes = await pg(`SELECT COUNT(*)::int AS n FROM information_schema.role_table_grants
    WHERE grantee='yannick_readonly' AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE')`);
  console.log(`\nWrite privileges (must be 0): ${writes[0].n}`);

  console.log('\n' + '='.repeat(72));
  console.log('CREDENTIALS — forward to Yannick via secure channel');
  console.log('='.repeat(72));
  console.log(`username: yannick_readonly`);
  console.log(`password: ${password}`);
  console.log(``);
  console.log(`Direct PG (recommended for ad-hoc psql):`);
  console.log(`  postgresql://yannick_readonly:${password}@db.${PROD}.supabase.co:5432/postgres`);
  console.log(``);
  console.log(`Pooler (recommended for Claude Code MCP / transient connections):`);
  console.log(`  postgresql://yannick_readonly.${PROD}:${password}@aws-1-us-east-1.pooler.supabase.com:6543/postgres`);
  console.log(``);
  console.log(`Settings → Database → Connection string in the Supabase dashboard shows`);
  console.log(`the same hostnames if needed.`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
