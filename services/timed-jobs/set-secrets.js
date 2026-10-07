// set-secrets.js — copy named values from Supabase/.env into one Railway timed-job service, printing NO value.
//   node services/timed-jobs/set-secrets.js <service> KEY [KEY...]      (Windows PowerShell, macOS, Linux)
// Run by a person (the Claude sessions do not enter secrets). Each value goes to the Railway CLI on stdin,
// never on the command line, so it does not land in shell history or the process list.
const fs = require('fs'), path = require('path'), { spawnSync } = require('child_process');
const cfg = require('./services.json');
const [svc, ...keys] = process.argv.slice(2);
if (!svc || !keys.length) { console.error('usage: node services/timed-jobs/set-secrets.js <service> KEY [KEY...]'); process.exit(2); }
const lines = fs.readFileSync(path.join(__dirname, '..', '..', '.env'), 'utf8').split(/\r?\n/);
for (const k of keys) {
  const line = lines.find(l => l.startsWith(k + '='));
  const v = line && line.slice(k.length + 1).trim();
  if (!v) { console.log(`${k}: not found in .env, skipped`); continue; }
  const r = spawnSync('railway', ['variable', 'set', k, '--stdin', '--service', svc, '--environment', cfg.environment,
    '--project', cfg.projectId, '--skip-deploys'], { input: v, encoding: 'utf8', shell: process.platform === 'win32' });
  console.log(r.status === 0 ? `${k}: set on ${svc}` : `${k}: FAILED (${(r.stderr || '').trim().slice(0, 200)})`);
}
