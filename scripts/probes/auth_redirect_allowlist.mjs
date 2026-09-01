// Read (and optionally extend) the project's OAuth redirect allow-list via the Management API.
//
// 🛑 uri_allow_list is a COMMA-SEPARATED LIST that EVERY staff app's sign-in depends on. This script
// NEVER replaces it blind: --add <origin> reads the current value, appends "<origin>" and
// "<origin>/**" only if absent, and refuses to write if any existing entry would be lost.
// site_url is calendar.unclogme.app, so an app missing from this list does not error on sign-in:
// it silently BOUNCES the user to the Calendar.
//
// Usage:
//   node scripts/probes/auth_redirect_allowlist.mjs
//   node scripts/probes/auth_redirect_allowlist.mjs --add https://hr.unclogme.app
import { readFileSync } from 'node:fs';

const env = Object.fromEntries(
  readFileSync('.env', 'utf8').split(/\r?\n/).filter(l => /^[A-Z_]+=/.test(l))
    .map(l => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '').trim()]));

const REF = env.SUPABASE_PROJECT_ID;
const H = { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' };
const URL_ = `https://api.supabase.com/v1/projects/${REF}/config/auth`;

const get = async () => {
  const r = await fetch(URL_, { headers: H });
  if (!r.ok) throw new Error(`GET ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return r.json();
};

const before = await get();
const list = String(before.uri_allow_list || '').split(',').map(s => s.trim()).filter(Boolean);
console.log('site_url:', before.site_url);
console.log('entries :', list.length);

const i = process.argv.indexOf('--add');
if (i === -1) { list.forEach(u => console.log('  ', u)); console.log('\n(read-only; pass --add <origin>)'); process.exit(0); }

const origin = process.argv[i + 1];
if (!/^https:\/\/[a-z0-9.-]+$/.test(origin)) throw new Error(`bad origin: ${origin}`);

const want = [origin, `${origin}/**`].filter(u => !list.includes(u));
if (!want.length) { console.log(`\n${origin} already allowed. Nothing to do.`); process.exit(0); }

const next = [...list, ...want];
// controls: every existing entry survives, and we add exactly what we intended
for (const u of list) if (!next.includes(u)) throw new Error(`refusing: would drop ${u}`);
if (next.length !== list.length + want.length) throw new Error('refusing: unexpected entry count');

console.log('\nADDING:', want.join('  '));
const r = await fetch(URL_, { method: 'PATCH', headers: H, body: JSON.stringify({ uri_allow_list: next.join(',') }) });
console.log('PATCH', r.status);
if (!r.ok) { console.log((await r.text()).slice(0, 400)); process.exit(1); }

const after = await get();
const afterList = String(after.uri_allow_list || '').split(',').map(s => s.trim()).filter(Boolean);
let ok = true;
for (const u of list) if (!afterList.includes(u)) { console.log('LOST:', u); ok = false; }
for (const u of want) if (!afterList.includes(u)) { console.log('NOT ADDED:', u); ok = false; }
console.log(ok ? `OK: ${afterList.length} entries, every prior entry survived.` : 'FAILED');
process.exit(ok ? 0 : 1);
