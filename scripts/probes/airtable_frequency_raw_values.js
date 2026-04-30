// Verify what Airtable Clients table actually stores in GT/CL/WD Frequency.
// Per Fred (2026-04-30): normal range is 10-180 days. If raw values fall in that
// range, populate.js step 5's `freqMul: 30` is wrong — Airtable stores DAYS,
// not months.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

function httpsGet(host, path, headers) {
  return new Promise((res, rej) => {
    https.request({ hostname: host, path, headers }, r => {
      let d = '';
      r.on('data', c => d += c);
      r.on('end', () => {
        if (r.statusCode >= 200 && r.statusCode < 300) {
          try { res(JSON.parse(d)); } catch (e) { rej(new Error('bad json: ' + d.slice(0, 300))); }
        } else rej(new Error(`HTTP ${r.statusCode}: ${d.slice(0, 300)}`));
      });
    }).on('error', rej).end();
  });
}

(async () => {
  console.log('=== AIRTABLE FREQUENCY RAW VALUES ===\n');
  const AT_KEY = process.env.AIRTABLE_API_KEY;
  const AT_BASE = process.env.AIRTABLE_BASE_ID;
  const HDR = { Authorization: `Bearer ${AT_KEY}` };

  const all = [];
  let offset = null, pages = 0;
  do {
    const q = new URLSearchParams();
    q.set('pageSize', '100');
    if (offset) q.set('offset', offset);
    const r = await httpsGet('api.airtable.com', `/v0/${AT_BASE}/Clients?${q}`, HDR);
    all.push(...(r.records || []));
    offset = r.offset;
    pages++;
    if (pages > 50) break;
  } while (offset);

  console.log(`Total Airtable Clients pulled: ${all.length}\n`);

  // Histograms
  const histos = { GT: new Map(), CL: new Map(), WD: new Map() };
  const samples = { GT: [], CL: [], WD: [] };

  for (const rec of all) {
    const f = rec.fields || {};
    for (const t of ['GT', 'CL', 'WD']) {
      const val = f[`${t} Frequency`];
      if (val == null) continue;
      const n = typeof val === 'number' ? val : (typeof val === 'string' ? parseFloat(val) : null);
      if (n == null || isNaN(n)) continue;
      histos[t].set(n, (histos[t].get(n) || 0) + 1);
      if (samples[t].length < 5) {
        const name = f['Client Name'] || f['CLIENT XX'] || 'unnamed';
        samples[t].push(`${name} = ${n}`);
      }
    }
  }

  for (const t of ['GT', 'CL', 'WD']) {
    const total = [...histos[t].values()].reduce((a, b) => a + b, 0);
    console.log(`--- ${t} Frequency (${total} clients with this field set) ---`);
    const sorted = [...histos[t].entries()].sort((a, b) => a[0] - b[0]);
    for (const [val, count] of sorted) {
      const bar = '█'.repeat(Math.min(count, 60));
      const interp_days = `(if days: ${val}d = ${(val/30).toFixed(1)}mo)`;
      const interp_months = `(if months: ${val}mo = ${val*30}d)`;
      console.log(`  ${String(val).padStart(6)}  ${String(count).padStart(3)}× ${bar}  ${val >= 10 && val <= 180 ? interp_days : interp_months}`);
    }
    console.log(`  Sample values: ${samples[t].slice(0, 3).join(', ')}\n`);
  }

  // Verdict
  console.log('--- VERDICT ---');
  const gtVals = [...histos.GT.keys()];
  const clVals = [...histos.CL.keys()];
  const inRangeGT = gtVals.filter(v => v >= 10 && v <= 180).length;
  const inRangeCL = clVals.filter(v => v >= 10 && v <= 180).length;
  const totalGT = gtVals.length;
  const totalCL = clVals.length;

  console.log(`GT distinct values in range [10,180]: ${inRangeGT}/${totalGT}`);
  console.log(`CL distinct values in range [10,180]: ${inRangeCL}/${totalCL}`);

  if (inRangeGT === totalGT && inRangeCL === totalCL) {
    console.log('\n✅ ALL values fall in the 10-180 range. Airtable stores DAYS.');
    console.log('   FIX: change populate.js step 5 freqMul: 30 → freqMul: 1 for GT/CL.');
  } else if (inRangeGT < totalGT * 0.2 && inRangeCL < totalCL * 0.2) {
    console.log('\n⚠️  Most values are < 10 or > 180. Airtable might still store MONTHS.');
    console.log('   Investigate before changing the multiplier.');
  } else {
    console.log('\n⚠️  MIXED. Yannick may be inconsistent. Need conditional handling.');
  }

  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
