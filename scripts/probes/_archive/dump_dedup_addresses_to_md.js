// Dump all 82 duplicate-address groups to a markdown file, categorized.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const https = require('https');

async function pg(sql) {
  for (let i = 0; i < 3; i++) {
    const r = await new Promise((res, rej) => {
      const req = https.request({
        hostname: 'api.supabase.com',
        path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
        method: 'POST',
        headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
      }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({status: x.statusCode, body: b})); });
      req.on('error', rej); req.write(JSON.stringify({query: sql})); req.end();
    });
    if (r.status < 300) return JSON.parse(r.body);
    if (r.status >= 500 || r.status === 429) { await new Promise(rs => setTimeout(rs, 4000 * (i+1))); continue; }
    throw new Error(`PG ${r.status}: ${r.body.slice(0, 200)}`);
  }
  throw new Error('5xx');
}

(async () => {
  const dups = await pg(`
    WITH norm AS (
      SELECT p.id AS property_id, p.client_id, p.address AS raw_address,
        c.name AS client_name, c.client_code, c.status AS client_status,
        regexp_replace(LOWER(TRIM(p.address)), '[^a-z0-9]+', ' ', 'g') AS norm_addr
      FROM properties p JOIN clients c ON c.id = p.client_id
      WHERE p.is_primary = TRUE AND p.address IS NOT NULL AND p.address <> ''
    )
    SELECT
      norm_addr,
      ARRAY_AGG(property_id ORDER BY client_id, property_id) AS property_ids,
      ARRAY_AGG(client_id ORDER BY client_id, property_id) AS client_ids,
      ARRAY_AGG(COALESCE(client_code, '-') ORDER BY client_id, property_id) AS codes,
      ARRAY_AGG(client_name ORDER BY client_id, property_id) AS names,
      ARRAY_AGG(client_status ORDER BY client_id, property_id) AS statuses,
      ARRAY_AGG(raw_address ORDER BY client_id, property_id) AS raw_addrs,
      COUNT(*) AS n_rows
    FROM norm GROUP BY norm_addr HAVING COUNT(*) > 1
    ORDER BY n_rows DESC, norm_addr;
  `);

  // Classify
  const a1 = []; // same client_id repeated (truly the same client w/ multiple property rows)
  const a2 = []; // mix of INACTIVE + ACTIVE
  const a3 = []; // same chain prefix
  const a4 = []; // different clients, same address (co-tenants)
  for (const d of dups) {
    const uniqClientIds = [...new Set(d.client_ids)];
    const sameClient = uniqClientIds.length === 1;
    const anyInactive = d.statuses.some(s => /inactive/i.test(s));
    const anyActive   = d.statuses.some(s => /active|recur/i.test(s));
    const codes = d.codes.filter(c => c && c !== '-');
    const sameChainPrefix = codes.length > 1 && codes.every(c => c.slice(0,4) === codes[0].slice(0,4));
    if (sameClient) a1.push(d);
    else if (anyInactive && anyActive) a2.push(d);
    else if (sameChainPrefix) a3.push(d);
    else a4.push(d);
  }

  const renderGroup = (d) => {
    let out = `### \`${d.raw_addrs[0]}\`\n`;
    out += `Normalized: \`${d.norm_addr}\`  •  ${d.n_rows} property rows\n\n`;
    out += `| property_id | client_id | client_code | status | name |\n|---|---|---|---|---|\n`;
    for (let i = 0; i < d.client_ids.length; i++) {
      out += `| ${d.property_ids[i]} | ${d.client_ids[i]} | ${d.codes[i]} | ${d.statuses[i]} | ${d.names[i].replace(/\|/g, '\\|')} |\n`;
    }
    return out + '\n';
  };

  const md = [];
  const now = new Date().toISOString().slice(0, 19).replace('T', ' ');
  md.push(`# Duplicate primary-property addresses — Prod Supabase`);
  md.push(`Generated ${now} UTC.  Total groups: ${dups.length}.\n`);
  md.push(`Source: weekly dedup audit's "duplicate addresses" check. Normalization: lowercase, non-alphanumeric → single space.\n`);
  md.push(`## Categories\n`);
  md.push(`| Category | Count | Action |`);
  md.push(`|---|---|---|`);
  md.push(`| **A1.** Real duplicates — same client, multiple property rows | **${a1.length}** | **Merge** the duplicate property rows in our DB |`);
  md.push(`| A2. INACTIVE + ACTIVE shadow — old "NOT USE" rows alongside live | ${a2.length} | Archive/delete the inactive shadow |`);
  md.push(`| A3. Same chain prefix — sister stores at same address | ${a3.length} | Confirm with Yannick (usually legit) |`);
  md.push(`| A4. Different clients sharing address — co-tenants | ${a4.length} | Usually legit (condo buildings, plazas), confirm |`);
  md.push(``);

  md.push(`---\n\n## A1. Real duplicates (${a1.length}) — same client_id with multiple property rows\n`);
  md.push(`These are the priority. Each entry is a single client whose \`properties\` table has 2+ rows pointing at the same address. Safe to merge — pick the earliest property_id, delete the others, repoint any FKs.\n`);
  for (const d of a1) md.push(renderGroup(d));

  md.push(`---\n\n## A2. INACTIVE + ACTIVE shadow (${a2.length})\n`);
  md.push(`Old client rows ("NOT USE...") sitting at the same address as the live client. Archive or delete the INACTIVE rows.\n`);
  for (const d of a2) md.push(renderGroup(d));

  if (a3.length) {
    md.push(`---\n\n## A3. Same chain prefix (${a3.length})\n`);
    for (const d of a3) md.push(renderGroup(d));
  }

  md.push(`---\n\n## A4. Different clients, same address — likely co-tenants (${a4.length})\n`);
  md.push(`Condo buildings, mixed-use plazas, food halls. Usually legitimate — multiple businesses operating at the same street address. Worth a glance to confirm but no action expected unless one looks wrong.\n`);
  for (const d of a4) md.push(renderGroup(d));

  const outPath = path.resolve(__dirname, '../../reports/duplicate_addresses_2026_05_11.md');
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, md.join('\n'));
  console.log(`Wrote ${outPath}`);
  console.log(`  ${dups.length} groups total`);
  console.log(`    A1 (real dupes):       ${a1.length}`);
  console.log(`    A2 (active+inactive):  ${a2.length}`);
  console.log(`    A3 (chain prefix):     ${a3.length}`);
  console.log(`    A4 (co-tenants):       ${a4.length}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
