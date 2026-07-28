// scripts/probes/propose_client_code.js
//
// Propose the next valid client_code for a new client, per docs/reference/client_code_scheme.md:
//   1. brand tag  -> reuse an existing brand's tag if the name matches a known chain, else coin one
//   2. number     -> next sequential (highest NORMAL number < 700, +1)
//   3. verify     -> confirm the number is free across DB + Airtable + Jobber
//                    (delegates to check_client_code_available.js; bumps the number on any collision)
//
// CLI:
//   node scripts/probes/propose_client_code.js "Pura Vida Coconut Grove"
//   node scripts/probes/propose_client_code.js "Joe's Bagels" --new      # force a brand-new tag
//   node scripts/probes/propose_client_code.js "X" --tag ABC             # force a specific tag
//
// Output is a PROPOSAL. The number + 3-source check are deterministic; the coined tag for a NEW
// brand is a suggestion (abbreviation is judgment — adjust if a better mnemonic exists).

const path = require('path');
const { execFileSync } = require('child_process');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const RESERVED_FLOOR = 700; // 700+ is the vanity/reserved band (e.g. 777-YA = Yan's Restaurant)

const args = process.argv.slice(2);
const name = args.find(a => !a.startsWith('--'));
const forceNew = args.includes('--new');
const forcedTag = (() => { const i = args.indexOf('--tag'); return i >= 0 ? args[i + 1] : null; })();
if (!name) { console.error('Usage: node propose_client_code.js "<Client Name>" [--new] [--tag ABC]'); process.exit(2); }

const NOISE_LEAD = new Set(['the']);
const NOISE_WORD = new Set(['llc', 'inc', 'inc.', 'corp', 'corp.', 'co', 'co.', 'of', 'and', 'miami', 'restaurant', 'cafe', 'dba']);
const words = s => s.toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/).filter(Boolean);
const stripLead = w => { const a = [...w]; while (a.length && NOISE_LEAD.has(a[0])) a.shift(); return a; };
const brandKey = s => stripLead(words(s)).slice(0, 2).join(' '); // first 2 significant words

function coinTag(s) {
  const w = stripLead(words(s)).filter(x => !NOISE_WORD.has(x)).filter(x => x.length >= 2 || /^\d+$/.test(x)); // drop possessive "s" / stray single letters
  if (!w.length) return 'XX';
  if (/^\d+$/.test(w[0])) return w[0];                       // leading number -> use it (e.g. "41")
  if (w.length === 1) return w[0].slice(0, 3).toUpperCase(); // single word -> first 3 letters
  return w.slice(0, 3).map(x => x[0]).join('').toUpperCase(); // multi-word -> initials (up to 3)
}

async function q(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  return r.json();
}

function checkFree(num) {
  try { execFileSync('node', [path.join(__dirname, 'check_client_code_available.js'), String(num)], { stdio: 'ignore' }); return true; }
  catch { return false; } // exit 1 => collision
}

(async () => {
  const rows = await q(`SELECT client_code, name FROM public.clients WHERE client_code ~ '^[0-9]+-' ORDER BY client_code`);
  const parsed = rows.map(r => { const m = String(r.client_code).match(/^(\d+)-(.+)$/); return m ? { num: +m[1], tag: m[2].trim(), name: r.name } : null; }).filter(Boolean);

  // brand tag
  let tag, basis;
  if (forcedTag) { tag = forcedTag.toUpperCase(); basis = 'forced via --tag'; }
  else if (forceNew) { tag = coinTag(name); basis = 'coined (--new forced)'; }
  else {
    const inKey = brandKey(name);
    const brandMap = {}; // brandKey -> {tag, count}
    for (const p of parsed) { const k = brandKey(p.name); if (!k) continue; brandMap[k] = brandMap[k] || {}; brandMap[k][p.tag] = (brandMap[k][p.tag] || 0) + 1; }
    const match = brandMap[inKey];
    if (match) { tag = Object.entries(match).sort((a, b) => b[1] - a[1])[0][0]; basis = `reused existing brand "${inKey}" (${Object.values(match).reduce((a, b) => a + b, 0)} locations)`; }
    else { tag = coinTag(name); basis = 'coined (no existing brand match)'; }
  }

  // next number = highest NORMAL (< RESERVED_FLOOR) + 1, then verify free across 3 systems
  const maxNormal = Math.max(0, ...parsed.filter(p => p.num < RESERVED_FLOOR).map(p => p.num));
  let num = maxNormal + 1, bumped = 0;
  while (!checkFree(num)) { num++; bumped++; if (bumped > 50) { console.error('Could not find a free number in 50 tries'); process.exit(2); } }
  const code = `${String(num).padStart(3, '0')}-${tag}`;

  console.log(`Client:   ${name}`);
  console.log(`Tag:      ${tag}   (${basis})`);
  console.log(`Number:   ${num}   (max normal = ${maxNormal}${bumped ? `, bumped +${bumped} past collisions` : ''}; verified free in DB+Airtable+Jobber)`);
  console.log(`\nPROPOSED CODE:  ${code}`);
})().catch(e => { console.error(e); process.exit(2); });
