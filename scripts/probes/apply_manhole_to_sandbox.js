// Apply add_manhole_count_2026_04_30.sql to the Sandbox project.
// (The standard apply_manhole_migration.js is hardcoded to Production via
//  lib/db.js — this version targets Sandbox via Management API directly.)

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');

const SANDBOX_PROJECT_ID = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
if (!SANDBOX_PROJECT_ID) { console.error('SANDBOX_SUPABASE_PROJECT_ID missing'); process.exit(1); }
if (!PAT) { console.error('SUPABASE_PAT missing'); process.exit(1); }

function rawQuery(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${SANDBOX_PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => {
        if (r.statusCode >= 200 && r.statusCode < 300) {
          try { res(JSON.parse(d)); } catch (e) { rej(new Error('Bad JSON: ' + d.slice(0, 300))); }
        } else rej(new Error(`HTTP ${r.statusCode}: ${d.slice(0, 600)}`));
      });
    });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  const sqlText = fs.readFileSync(path.resolve(__dirname, '../migrations/add_manhole_count_2026_04_30.sql'), 'utf8');
  // Strip SQL comments and split on `;` at end of line
  const stmts = sqlText
    .split(/;\s*$/m)
    .map(s => s.replace(/--.*$/gm, '').trim())
    .filter(s => s && !/^\s*BEGIN\s*$/i.test(s) && !/^\s*COMMIT\s*$/i.test(s));

  console.log(`Applying manhole migration to Sandbox (${SANDBOX_PROJECT_ID})...\n`);
  for (const s of stmts) {
    if (!s) continue;
    const head = s.slice(0, 70).replace(/\s+/g, ' ');
    console.log(`  Running: ${head}...`);
    try {
      await rawQuery(s + ';');
    } catch (e) {
      if (/already exists/i.test(e.message)) {
        console.log(`    (already in place — skipping)`);
        continue;
      }
      throw e;
    }
  }

  console.log('\nVerification:');
  const cols = await rawQuery(`
    SELECT column_name, data_type, column_default, is_nullable
    FROM information_schema.columns
    WHERE table_schema='public' AND table_name='properties' AND column_name='grease_trap_manhole_count';
  `);
  for (const c of cols) console.log(`  ${c.column_name} ${c.data_type} default=${c.column_default} null=${c.is_nullable}`);

  if (!cols.length) {
    console.error('❌ Column NOT present after migration');
    process.exit(1);
  }
  process.exit(0);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
