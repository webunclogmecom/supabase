// resync_from_live.js [--execute]
// Regenerate every scripts/ops_views/*.sql source file from the LIVE ops.* view
// definition (pg_get_viewdef) so the folder mirrors the live database. DRY-RUN by
// default (prints the plan); pass --execute to rewrite the files. Idempotent.
// Reads SUPABASE_PAT from Supabase/.env. SELECT-only against the Management API.
const https = require('https');
const fs = require('fs');
const path = require('path');
const PROD = 'wbasvhvvismukaqdnouk';
const DIR = __dirname;
function readEnv(k) { const p = path.resolve(__dirname, '../../.env'); const l = fs.readFileSync(p, 'utf8').split(/\r?\n/).find(x => x.startsWith(k + '=')); return l ? l.slice(k.length + 1).trim() : null; }
const PAT = readEnv('SUPABASE_PAT');
function mgmt(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const r = https.request({ hostname: 'api.supabase.com', path: '/v1/projects/' + PROD + '/database/query', method: 'POST',
      headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } },
      x => { let d = ''; x.on('data', c => d += c); x.on('end', () => { if (x.statusCode >= 300) return rej(new Error('HTTP ' + x.statusCode + ' ' + d.slice(0, 200))); res(JSON.parse(d)); }); });
    r.on('error', rej); r.write(body); r.end();
  });
}
const header = (view) =>
`-- ============================================================================
-- ops.${view} — AUTO-GENERATED from the live view definition.
-- Do NOT hand-edit the body. To change this view: apply a migration to the LIVE
-- view (docs/migrations/), then run:
--   node scripts/ops_views/resync_from_live.js --execute
-- ============================================================================

`;

(async () => {
  const exec = process.argv.includes('--execute');
  const liveViews = (await mgmt("SELECT viewname FROM pg_views WHERE schemaname='ops' ORDER BY viewname;")).map(r => r.viewname);
  const liveSet = new Set(liveViews);
  const files = fs.readdirSync(DIR).filter(f => f.endsWith('.sql')).sort();
  const out = { mode: exec ? 'EXECUTE' : 'DRY-RUN', resynced: [], unchanged: [], orphan_file_view_not_live: [], skipped_non_view: [] };
  const handled = new Set();
  for (const f of files) {
    const fp = path.join(DIR, f);
    const cur = fs.readFileSync(fp, 'utf8');
    const m = cur.match(/CREATE\s+(?:OR\s+REPLACE\s+)?VIEW\s+ops\.([a-z0-9_]+)/i);
    if (!m) { out.skipped_non_view.push(f); continue; }
    const view = m[1]; handled.add(view);
    if (!liveSet.has(view)) { out.orphan_file_view_not_live.push(`${f} -> ops.${view}`); continue; }
    const def = (await mgmt(`SELECT pg_get_viewdef('ops.${view}'::regclass, true) AS def;`))[0].def.trim();
    const content = header(view) + `CREATE OR REPLACE VIEW ops.${view} AS\n${def}\n`;
    if (content === cur) { out.unchanged.push(f); }
    else { out.resynced.push(`${f} -> ops.${view}`); if (exec) fs.writeFileSync(fp, content); }
  }
  out.live_views_without_source_file = liveViews.filter(v => !handled.has(v));
  console.log(JSON.stringify(out, null, 2));
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
