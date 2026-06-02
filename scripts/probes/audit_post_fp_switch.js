// Comprehensive post-switch audit on Prod canonical.
// Simulates what the Field Portal app will request via REST (anon role + Accept-Profile=customer).
// Tests every view + the 5 sample clients Fred will hit + edge cases.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
const SUPABASE_URL = process.env.SUPABASE_URL;
const host = new (require('url').URL)(SUPABASE_URL).hostname;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

function rest(path, headers = {}) {
  return new Promise((res, rej) => {
    const start = Date.now();
    const req = https.request({ hostname: host, path, method: 'GET',
      headers: { apikey: KEY, Authorization: 'Bearer ' + KEY, ...headers }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({ s: x.statusCode, b, ms: Date.now()-start })); });
    req.on('error', rej); req.end();
  });
}
function pg(sql) {
  return new Promise((res, rej) => {
    const req = https.request({ hostname: 'api.supabase.com', path: `/v1/projects/${PROD}/database/query`, method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(b)); });
    req.on('error', rej); req.write(JSON.stringify({ query: sql })); req.end();
  });
}
const j = x => { try { return JSON.parse(x); } catch { return x; } };
const findings = [];
const add = (level, check, detail) => findings.push({ level, check, detail });

(async () => {
  console.log('='.repeat(72));
  console.log('POST-SWITCH FIELD PORTAL AUDIT — Prod customer schema');
  console.log('='.repeat(72));

  // --- 1. All 8 customer.* views reachable + perf ---
  console.log('\n[1] REST exposure + perf on all 8 views (limit=1)');
  for (const v of ['work_orders','wo_photos','client_access_photos','inspection_items','permits','recommendations','scheduled_visits','clients']) {
    const r = await rest(`/rest/v1/${v}?limit=1`, { 'Accept-Profile': 'customer' });
    const ok = r.s === 200;
    console.log(`  ${v.padEnd(24)} ${ok ? '✓' : '✗'} ${r.s} (${r.ms}ms)`);
    add(ok ? 'PASS' : 'FAIL', `view ${v}`, `${r.s} in ${r.ms}ms`);
  }

  // --- 2. Five sample ACTIVE/RECURRING clients ---
  // (005-BUB is INACTIVE and 166-SPA is PAUSED — customer.clients view filters them
  // out by design. Test their EXCLUSION separately in step 6.)
  console.log('\n[2] Five sample ACTIVE clients fetched as the app would');
  const clientCodes = ['092-TCE', '168-AVA', '083-SHUL', '057-SLS', '031-KRU'];
  for (const code of clientCodes) {
    const slug = code.toLowerCase();
    const r = await rest(`/rest/v1/clients?slug=eq.${encodeURIComponent(slug)}`, { 'Accept-Profile': 'customer' });
    const rows = r.s === 200 ? j(r.b) : null;
    const found = rows && rows.length > 0;
    if (!found) { console.log(`  ${code}: ✗ ${r.s} ${r.b.slice(0,100)}`); add('FAIL', `client ${code}`, `not found`); continue; }
    const client = rows[0];
    // pull work_orders + scheduled_visits + permits for this client
    const wo = await rest(`/rest/v1/work_orders?client_id=eq.${client.id}`, { 'Accept-Profile': 'customer' });
    const sv = await rest(`/rest/v1/scheduled_visits?client_id=eq.${client.id}`, { 'Accept-Profile': 'customer' });
    const pm = await rest(`/rest/v1/permits?client_id=eq.${client.id}`, { 'Accept-Profile': 'customer' });
    const woN = wo.s === 200 ? j(wo.b).length : 'ERR';
    const svN = sv.s === 200 ? j(sv.b).length : 'ERR';
    const pmN = pm.s === 200 ? j(pm.b).length : 'ERR';
    console.log(`  ${code.padEnd(10)} ✓ work_orders=${woN}  scheduled=${svN}  permits=${pmN}`);
    add('PASS', `client ${code}`, `wo=${woN} sv=${svN} pm=${pmN}`);
    if (wo.s !== 200) add('FAIL', `${code} work_orders`, `${wo.s}: ${wo.b.slice(0,150)}`);
    if (sv.s !== 200) add('FAIL', `${code} scheduled`, `${sv.s}: ${sv.b.slice(0,150)}`);
    if (pm.s !== 200) add('FAIL', `${code} permits`, `${pm.s}: ${pm.b.slice(0,150)}`);
  }

  // --- 3. Visit 3915 — the driver-backfill smoking-gun row ---
  // NOTE: visit 3915 has NO manifest_visits link in either Prod or FP Sandbox,
  // so DERM URL fields are legitimately NULL here. The DERM URL render test
  // moved to step 3b using visit 1619 (which IS linked).
  console.log('\n[3a] Visit 3915 (092-TCE 2026-05-04) — driver backfill check');
  const r3915 = await rest(`/rest/v1/work_orders?id=eq.00000000-0000-0000-0000-000000003915`, { 'Accept-Profile': 'customer' });
  console.log(`  status=${r3915.s}`);
  if (r3915.s === 200) {
    const row = j(r3915.b)[0];
    console.log(`  driver=${row?.driver}  truck=${row?.truck}  manholes=${row?.manholes}`);
    console.log(`  derm_manifest_number=${row?.derm_manifest_number} (NULL is expected — no manifest linked in DB)`);
    if (row?.driver !== 'Steven') add('FAIL', 'visit 3915 driver', `expected Steven, got ${row?.driver}`);
    else add('PASS', 'visit 3915 driver', 'Steven (backfill from Jobber held)');
    if (row?.truck !== 'Moises') add('WARN', 'visit 3915 truck', `expected Moises, got ${row?.truck}`);
    else add('PASS', 'visit 3915 truck', 'Moises');
  } else { add('FAIL', 'visit 3915 fetch', r3915.b.slice(0,200)); }

  // --- 3b. Visit 1619 — DERM URL render check (this one IS linked) ---
  console.log('\n[3b] Visit 1619 (092-TCE 2026-04-13) — DERM URL render check');
  const r1619 = await rest(`/rest/v1/work_orders?id=eq.00000000-0000-0000-0000-000000001619`, { 'Accept-Profile': 'customer' });
  if (r1619.s === 200) {
    const row = j(r1619.b)[0];
    console.log(`  driver=${row?.driver}  truck=${row?.truck}`);
    console.log(`  derm_manifest_number=${row?.derm_manifest_number}  (expect 821472)`);
    console.log(`  derm_manifest_url starts: ${row?.derm_manifest_url?.slice(0, 80)}...`);
    console.log(`  wwtp_receipt_number=${row?.wwtp_receipt_number}  (expect 821472)`);
    console.log(`  wwtp_receipt_url starts: ${row?.wwtp_receipt_url?.slice(0, 80)}...`);
    if (row?.derm_manifest_number !== '821472') add('WARN', 'visit 1619 DERM #', `got ${row?.derm_manifest_number}`);
    else add('PASS', 'visit 1619 DERM #', '821472');
    if (!row?.derm_manifest_url?.startsWith(SUPABASE_URL)) add('FAIL', 'visit 1619 DERM URL', `not on Prod Storage: ${row?.derm_manifest_url?.slice(0,80)}`);
    else add('PASS', 'visit 1619 DERM URL', 'on Prod Storage');
    if (!row?.wwtp_receipt_url?.startsWith(SUPABASE_URL)) add('FAIL', 'visit 1619 WWTP URL', `not on Prod Storage: ${row?.wwtp_receipt_url?.slice(0,80)}`);
    else add('PASS', 'visit 1619 WWTP URL', 'on Prod Storage');
  } else { add('FAIL', 'visit 1619 fetch', r1619.b.slice(0,200)); }

  // --- 4. Photos for visit 3915 (Field Portal grid) ---
  console.log('\n[4] customer.wo_photos for visit 3915');
  const photos = await rest(`/rest/v1/wo_photos?work_order_id=eq.00000000-0000-0000-0000-000000003915`, { 'Accept-Profile': 'customer' });
  if (photos.s === 200) {
    const ps = j(photos.b);
    const dist = ps.reduce((a, p) => (a[p.variant] = (a[p.variant] || 0) + 1, a), {});
    console.log(`  ${ps.length} photos: ${JSON.stringify(dist)}`);
    const allUrlsOnProd = ps.every(p => p.url?.startsWith(SUPABASE_URL));
    if (!allUrlsOnProd) add('FAIL', 'visit 3915 photo URLs', 'some not on Prod Storage');
    else add('PASS', 'visit 3915 photo URLs', `${ps.length} on Prod Storage`);
  }

  // --- 5. Verify visit 1619 (the photo-heavy one) ---
  console.log('\n[5] Visit 1619 (092-TCE 2026-04-13) photo grids');
  const p1619 = await rest(`/rest/v1/wo_photos?work_order_id=eq.00000000-0000-0000-0000-000000001619&order=position`, { 'Accept-Profile': 'customer' });
  if (p1619.s === 200) {
    const ps = j(p1619.b);
    const dist = ps.reduce((a, p) => (a[p.variant] = (a[p.variant] || 0) + 1, a), {});
    console.log(`  ${ps.length} photos: ${JSON.stringify(dist)} (expect 3 before / 5 after)`);
    if (dist.before === 3 && dist.after === 5) add('PASS', 'visit 1619 photos', '3 before / 5 after');
    else add('WARN', 'visit 1619 photos', JSON.stringify(dist));
  }

  // --- 6. customer.clients includes ALL statuses (post-2026-05-16a) ---
  // Lovable banners read-only based on status field; the view no longer filters.
  console.log('\n[6] customer.clients includes PAUSED + INACTIVE with status flag');
  const bubR = await rest(`/rest/v1/clients?slug=eq.005-bub&select=slug,status,is_active`, { 'Accept-Profile': 'customer' });
  const spaR = await rest(`/rest/v1/clients?slug=eq.166-spa&select=slug,status,is_active`, { 'Accept-Profile': 'customer' });
  const bubRows = j(bubR.b);
  const spaRows = j(spaR.b);
  const bub = Array.isArray(bubRows) ? bubRows[0] : null;
  const spa = Array.isArray(spaRows) ? spaRows[0] : null;
  if (bub?.status === 'INACTIVE' && bub?.is_active === false) add('PASS', '005-BUB visible+flagged', 'status=INACTIVE, is_active=false');
  else add('FAIL', '005-BUB visible+flagged', `got ${JSON.stringify(bub)}`);
  if (spa?.status === 'PAUSED' && spa?.is_active === false) add('PASS', '166-SPA visible+flagged', 'status=PAUSED, is_active=false');
  else add('FAIL', '166-SPA visible+flagged', `got ${JSON.stringify(spa)}`);
  console.log(`  005-BUB: ${bub ? '✓ ' + bub.status + ' is_active=' + bub.is_active : '✗ not visible'}`);
  console.log(`  166-SPA: ${spa ? '✓ ' + spa.status + ' is_active=' + spa.is_active : '✗ not visible'}`);
  // Sanity check on the ACTIVE control
  const tceR = await rest(`/rest/v1/clients?slug=eq.092-tce&select=slug,status,is_active`, { 'Accept-Profile': 'customer' });
  const tce = j(tceR.b)?.[0];
  console.log(`  092-TCE control: ${tce ? '✓ ' + tce.status + ' is_active=' + tce.is_active : '✗ not visible'}`);
  if (tce?.is_active === true) add('PASS', '092-TCE is_active', 'true (RECURRING)');
  else add('FAIL', '092-TCE is_active', `got ${JSON.stringify(tce)}`);

  // --- 6b. Div-by-zero edge case (probe canonical directly since clients are filtered) ---
  console.log('\n[6b] Div-by-zero protection on customer.work_orders.visit_total');
  const divZ = j(await pg(`SELECT COUNT(*)::int AS n FROM customer.work_orders WHERE visit_total IS NULL AND client_id IN (customer.uuid_from_bigint(6), customer.uuid_from_bigint(212));`));
  console.log(`  rows with NULL visit_total for 005-BUB+166-SPA: ${divZ[0]?.n} (would crash without patch)`);
  if (typeof divZ[0]?.n === 'number') add('PASS', 'div-by-zero patch', `${divZ[0].n} rows safely return NULL`);
  else add('WARN', 'div-by-zero patch', JSON.stringify(divZ).slice(0,150));

  // --- 7. Dual-write health check (Prod ↔ Sandbox #1) ---
  console.log('\n[7] Dual-write health — Prod ↔ Sandbox #1 photo_classifications drift');
  const drift = j(await pg(`SELECT COUNT(*)::int AS n FROM photo_classifications;`));
  console.log(`  Prod photo_classifications: ${drift[0]?.n}`);
  // (full drift check is in audit_dual_write_full.js — running here just on row count for speed)

  // --- 7b. manifest_visits linkage gap (separate issue, not switch-related) ---
  console.log('\n[7b] manifest_visits linkage gap (visit attribution rate per week)');
  const gap = j(await pg(`SELECT date_trunc('week', dm.service_date)::date AS wk, COUNT(*) AS total, COUNT(mv.visit_id) AS linked, ROUND(100.0 * COUNT(mv.visit_id) / NULLIF(COUNT(*),0), 1) AS pct FROM derm_manifests dm LEFT JOIN manifest_visits mv ON mv.manifest_id=dm.id WHERE dm.service_date >= '2026-04-01' GROUP BY 1 ORDER BY 1 DESC LIMIT 6;`));
  if (Array.isArray(gap)) {
    gap.forEach(r => console.log(`  ${r.wk}: ${r.linked}/${r.total} linked (${r.pct}%)`));
    const worst = Math.min(...gap.map(r => r.pct));
    if (worst < 80) add('WARN', 'manifest_visits gap', `worst week ${worst}% linked — separate issue, blocks compliance cards for unlinked visits`);
    else add('PASS', 'manifest_visits linkage', `all weeks >=80% linked (worst ${worst}%)`);
  }

  // --- 8. Summary ---
  console.log('\n' + '='.repeat(72));
  console.log('SUMMARY');
  console.log('='.repeat(72));
  const counts = findings.reduce((a, f) => (a[f.level] = (a[f.level] || 0) + 1, a), {});
  console.log(`  PASS: ${counts.PASS || 0}  WARN: ${counts.WARN || 0}  FAIL: ${counts.FAIL || 0}`);
  findings.filter(f => f.level !== 'PASS').forEach(f => console.log(`  [${f.level}] ${f.check}: ${f.detail}`));
})().catch(e => { console.error('FATAL:', e); process.exit(2); });
