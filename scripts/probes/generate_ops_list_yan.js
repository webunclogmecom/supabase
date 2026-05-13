// Generate OPS_LIST_YAN.md from the live Supabase audit.
// Re-runnable anytime — overwrites OPS_LIST_YAN.md at repo root.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');

function http(o, b) { return new Promise((res, rej) => {
  const r = https.request(o, x => { const c=[]; x.on('data',d=>c.push(d)); x.on('end',()=>res({status:x.statusCode,body:Buffer.concat(c).toString()})); });
  r.on('error',rej); if(b) r.write(b); r.end();
}); }
async function pg(s) {
  const r = await http({ hostname: 'api.supabase.com', path: '/v1/projects/'+process.env.SUPABASE_PROJECT_ID+'/database/query', method: 'POST', headers: { Authorization: 'Bearer '+process.env.SUPABASE_PAT, 'Content-Type': 'application/json' } }, JSON.stringify({ query: s }));
  if (r.status >= 300) throw new Error('PG '+r.status+': '+r.body.slice(0,400));
  return JSON.parse(r.body);
}

(async () => {
  const rows = await pg(`
    SELECT c.client_code, c.name, sc.service_type, sc.frequency_days, sc.price_per_visit, c.status,
      CASE WHEN sc.price_per_visit IS NULL AND sc.frequency_days IS NULL THEN 'NEEDS_BOTH'
           WHEN sc.price_per_visit IS NULL THEN 'NEEDS_PRICE'
           WHEN sc.frequency_days IS NULL THEN 'NEEDS_FREQ' END AS need
    FROM service_configs sc JOIN clients c ON c.id=sc.client_id
    WHERE (sc.price_per_visit IS NULL OR sc.frequency_days IS NULL)
      AND c.status IN ('ACTIVE','RECURRING')
    ORDER BY (CASE WHEN sc.price_per_visit IS NULL AND sc.frequency_days IS NULL THEN 3
                   WHEN sc.price_per_visit IS NULL THEN 2 ELSE 1 END), c.client_code, sc.service_type;
  `);

  const buckets = { NEEDS_FREQ: [], NEEDS_PRICE: [], NEEDS_BOTH: [] };
  for (const r of rows) buckets[r.need].push(r);
  const stripCode = n => (n || '').replace(/^[0-9-]+/, '').trim();

  let md = '# Yan — service config fix list\n\n';
  md += '_Generated '+new Date().toISOString().slice(0,10)+' from live Supabase audit. '+rows.length+' total rows across 3 priority buckets._\n\n';
  md += 'Fix everything in Airtable. Our DB syncs on the next `populate.js --step=5` run.\n\n';

  md += '## Part 1 — NEEDS_FREQ ('+buckets.NEEDS_FREQ.length+' rows) — HIGH PRIORITY\n\n';
  md += "These have a price set but no cadence, so the daily cron **won't schedule any upcoming visits for them**. Set the freq in AT (`GT/CL/WD Frequency` in days).\n\n";
  md += '| Client | Service | Price | Set freq to… |\n|---|---|---|---|\n';
  for (const r of buckets.NEEDS_FREQ) md += '| '+r.client_code+' '+stripCode(r.name)+' | '+r.service_type+' | $'+r.price_per_visit+' | ? days |\n';

  md += '\n## Part 2 — NEEDS_PRICE ('+buckets.NEEDS_PRICE.length+' rows) — MEDIUM PRIORITY\n\n';
  md += 'These have a cadence so the cron schedules them, but they have no `$ per Visit` in AT, so any invoice will land at $0.\n\n';
  md += '| Client | Service | Freq (days) | Set price to… |\n|---|---|---|---|\n';
  for (const r of buckets.NEEDS_PRICE) md += '| '+r.client_code+' '+stripCode(r.name)+' | '+r.service_type+' | '+r.frequency_days+' | $? |\n';

  md += '\n## Part 3 — NEEDS_BOTH ('+buckets.NEEDS_BOTH.length+' rows) — LOW PRIORITY (decide: real or noise)\n\n';
  md += "These came from AT clients where the `Service Type` multi-select has a service ticked (GT/CL/WD) but **neither cadence nor price is filled in**. Either:\n\n";
  md += '- **The client really gets this service** → fill freq + price in AT\n';
  md += '- **The service-type checkbox was aspirational / left over** → uncheck it in AT\n\n';
  md += 'Most of these are WD (Water Discharge) — that program may not have fully rolled out yet. Either way, deciding will clear the noise from the data model.\n\n';
  md += '| Client | Service | Decision |\n|---|---|---|\n';
  for (const r of buckets.NEEDS_BOTH) md += '| '+r.client_code+' '+stripCode(r.name)+' | '+r.service_type+' | fill in or uncheck |\n';

  md += '\n## Part 4 — Other anomalies spotted during audit\n\n';
  md += '- **175-PV Pura Vida Brickell** — `GT First Visit Date = 2028-11-29` in AT. Typo, 2.5 years in the future. Skews our anchor calculation. Fix to the real first-visit date.\n';
  md += '- **140-TYO Tacos Yoyo** — AT has `Client Code #3 = 140-TCY`. Jobber and our DB say `140-TYO`. Fix AT to match.\n';
  md += '- **"Casa Neos BAR" record in AT** — exists with no Jobber link. Either onboard it as a real second location of 009-CN Casa Neos, or delete from AT.\n';
  md += '- **AT "Recuring" single-select option** — typo with one r. We normalize to "RECURRING" on read. Renaming the AT option to "Recurring" would clean it at the source.\n';

  md += '\n## When done\n\n';
  md += 'Ping Fred — we re-run `node scripts/populate/populate.js --step=5 --execute --confirm` to pull the updated configs into Supabase. ~30s.\n';

  const out = path.resolve(__dirname, '../../OPS_LIST_YAN.md');
  fs.writeFileSync(out, md);
  console.log('Wrote', out, '—', md.length, 'chars');
  console.log('Buckets:', buckets.NEEDS_FREQ.length, 'freq /', buckets.NEEDS_PRICE.length, 'price /', buckets.NEEDS_BOTH.length, 'both');
})().catch(e => { console.error('FATAL', e.message); process.exit(2); });
