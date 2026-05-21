// Verify final state of DERM PDF URL backfill (task #8).
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}` };

async function rest(qs, opts = {}) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, { ...opts, headers: { ...H, ...(opts.headers || {}) } });
  if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
  const ct = r.headers.get('content-range');
  return { rows: await r.json(), count: ct ? Number(ct.split('/')[1]) : null };
}

(async () => {
  // 1) WM#824949 spot check
  const { rows } = await rest('derm_manifests?white_manifest_number=eq.824949&select=id,white_manifest_number,derm_manifest_url,derm_address_url&order=id');
  console.log('=== WM#824949 ===');
  console.table(rows.map(r => ({
    id: r.id,
    wm: r.white_manifest_number,
    has_manif: !!r.derm_manifest_url,
    has_addr: !!r.derm_address_url,
  })));

  // 2) Total rows + rows missing both URLs
  const { count: total } = await rest('derm_manifests?select=id', {
    headers: { Prefer: 'count=exact', Range: '0-0' },
  });
  const { count: missingBoth } = await rest('derm_manifests?derm_manifest_url=is.null&derm_address_url=is.null&select=id', {
    headers: { Prefer: 'count=exact', Range: '0-0' },
  });

  console.log('\n=== Coverage ===');
  console.table([{ total, missing_both_urls: missingBoth, coverage_pct: ((1 - missingBoth / total) * 100).toFixed(2) + '%' }]);
})().catch(err => { console.error(err); process.exit(1); });
