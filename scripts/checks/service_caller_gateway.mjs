// service_caller_gateway.mjs - the standing check behind supabase/functions/_shared/service-caller.ts
// (legacy-keys plan step 1, 2026-10-23, docs/specs/2026-10-22-legacy-keys-switch-off-plan.md).
//
// isSecretKeyCaller() trusts any bearer that starts with sb_secret_, which is safe ONLY behind the gateway's key
// check (verify_jwt = true). This fails when:
//   1. a function that imports the helper is not pinned verify_jwt = true in config.toml, or runs live without it;
//   2. the gateway stops refusing a made-up secret key, or a bearer that differs from the apikey header;
//   3. the positive control fails: a real secret key must reach the function (dry run, nothing is posted).
// Run: node --env-file=.env scripts/checks/service_caller_gateway.mjs      (exit 1 on any failure)
import fs from 'node:fs';
import path from 'node:path';

const ref = 'wbasvhvvismukaqdnouk', PAT = process.env.SUPABASE_PAT, secret = process.env.SUPABASE_RAILWAY_SECRET_KEY;
const root = path.resolve(import.meta.dirname, '../../supabase');
const fail = [];

// 1. every importer is pinned and live with verify_jwt = true
const config = fs.readFileSync(path.join(root, 'config.toml'), 'utf8');
const pinned = (fn) => new RegExp(`\\[functions\\.${fn}\\][^\\[]*verify_jwt\\s*=\\s*true`).test(config);
const importers = fs.readdirSync(path.join(root, 'functions')).filter((d) => {
  const f = path.join(root, 'functions', d, 'index.ts');
  return fs.existsSync(f) && fs.readFileSync(f, 'utf8').includes('_shared/service-caller.ts');
});
if (importers.length === 0) fail.push('no function imports the helper: the check is pointed at nothing');
for (const fn of importers) {
  if (!pinned(fn)) fail.push(`${fn}: not pinned verify_jwt = true in config.toml`);
  const meta = await (await fetch(`https://api.supabase.com/v1/projects/${ref}/functions/${fn}`, { headers: { Authorization: `Bearer ${PAT}` } })).json();
  if (meta.verify_jwt !== true) fail.push(`${fn}: live verify_jwt is ${meta.verify_jwt}`);
}

// 2 + 3. the gateway, probed on a function whose dry run posts nothing
const url = `https://${ref}.supabase.co/functions/v1/stamp-sheets-reminder`;
const call = async (h) => (await fetch(url, { method: 'POST', headers: { ...h, 'Content-Type': 'application/json' }, body: '{"dry_run":true}' })).status;
const fake = 'sb_secret_' + 'x'.repeat(31);
const cases = [
  ['made-up secret key as bearer', { Authorization: `Bearer ${fake}` }, 401],
  ['made-up secret key in both headers', { Authorization: `Bearer ${fake}`, apikey: fake }, 401],
  ['bearer differs from apikey', { Authorization: `Bearer ${fake}`, apikey: secret }, 401],
  ['real secret key (positive control)', { Authorization: `Bearer ${secret}`, apikey: secret }, 200],
];
for (const [label, h, want] of cases) {
  const got = await call(h);
  if (got !== want) fail.push(`gateway: ${label} answered ${got}, expected ${want}`);
}

console.log(`${importers.length} functions use the helper; ${cases.length} gateway cases probed`);
if (fail.length) { console.log('FAIL\n  ' + fail.join('\n  ')); process.exit(1); }
console.log('ok');
