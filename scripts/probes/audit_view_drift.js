// Audit drift between deployed views (schema: derm, customer, ops) and
// the migration files that define them. Cross-references each view with
// the most recent migration that contains a CREATE [OR REPLACE] VIEW for it.
//
// Read-only.
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const SUPA_URL = process.env.SUPABASE_URL;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  if (!r.ok) throw new Error(`SQL ${r.status} ${await r.text()}`);
  return r.json();
}

(async () => {
  // 1. List all views in target schemas
  const views = await sql(`
    SELECT schemaname AS schema, viewname AS name
    FROM pg_catalog.pg_views
    WHERE schemaname IN ('derm', 'customer', 'ops')
    ORDER BY schemaname, viewname;
  `);

  // 2. Walk all migration files
  const dir = path.resolve(__dirname, '../../docs/migrations');
  const files = fs.readdirSync(dir).filter(f => f.endsWith('.sql')).sort();

  const map = {}; // "schema.view" -> [files]
  for (const f of files) {
    const content = fs.readFileSync(path.join(dir, f), 'utf8');
    for (const v of views) {
      const key = `${v.schema}.${v.name}`;
      // Match CREATE [OR REPLACE] VIEW <schema>.<name>
      const pattern = new RegExp(`CREATE\\s+(?:OR\\s+REPLACE\\s+)?VIEW\\s+${v.schema}\\.${v.name}\\b`, 'i');
      if (pattern.test(content)) {
        (map[key] = map[key] || []).push(f);
      }
    }
  }

  console.log('View → migration files (latest is canonical)');
  console.log('='.repeat(80));
  const noFile = [];
  for (const v of views) {
    const key = `${v.schema}.${v.name}`;
    const list = map[key] || [];
    if (!list.length) { noFile.push(key); continue; }
    const latest = list[list.length - 1];
    const earlier = list.length > 1 ? ` (+${list.length - 1} earlier)` : '';
    console.log(`  ${key.padEnd(38)} ${latest}${earlier}`);
  }
  if (noFile.length) {
    console.log('\nViews with NO matching migration file (potentially drifted):');
    console.log('='.repeat(80));
    for (const v of noFile) console.log(`  ${v}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
