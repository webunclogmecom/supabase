// set-secrets.js — copy named values from Supabase/.env into one Railway timed-job service, printing NO value.
//   node services/timed-jobs/set-secrets.js <service> KEY [KEY...]      (Windows PowerShell, macOS, Linux)
//   KEY=ENVNAME sets Railway's KEY from a differently named .env line. Railway's SUPABASE_SERVICE_ROLE_KEY must be
//   SUPABASE_SERVICE_ROLE_KEY=SUPABASE_RAILWAY_SECRET_KEY (Railway-only secret key since 2026-10-22, not the legacy JWT).
// Run by a person (the Claude sessions do not enter secrets). Each value goes to the Railway CLI on stdin,
// never on the command line, so it does not land in shell history or the process list.
const fs = require('fs'), path = require('path'), { spawnSync } = require('child_process');
const cfg = require('./services.json');
const [svc, ...keys] = process.argv.slice(2);
if (!svc || !keys.length) { console.error('usage: node services/timed-jobs/set-secrets.js <service> KEY [KEY...]'); process.exit(2); }
const lines = fs.readFileSync(path.join(__dirname, '..', '..', '.env'), 'utf8').split(/\r?\n/);
for (const arg of keys) {
  const [k, src = k] = arg.split('=');
  if (k === 'SUPABASE_SERVICE_ROLE_KEY' && src === k) {   // the .env line of that name is the LEGACY JWT, leaked 2026-10-21
    console.log('SUPABASE_SERVICE_ROLE_KEY: refused; use SUPABASE_SERVICE_ROLE_KEY=SUPABASE_RAILWAY_SECRET_KEY'); continue;
  }
  const line = lines.find(l => l.startsWith(src + '='));
  const v = line && line.slice(src.length + 1).trim();
  if (!v) { console.log(`${src}: not found in .env, skipped`); continue; }
  const r = spawnSync('railway', ['variable', 'set', k, '--stdin', '--service', svc, '--environment', cfg.environment,
    '--project', cfg.projectId, '--skip-deploys'], { input: v, encoding: 'utf8', shell: process.platform === 'win32' });
  console.log(r.status === 0 ? `${k}: set on ${svc}` : `${k}: FAILED (${(r.stderr || '').trim().slice(0, 200)})`);
}
