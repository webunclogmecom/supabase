// Phase 2: Investigate WHY the gaps exist.
// - For unmatched Samsara geofences: are the clients INACTIVE/PAUSED, or truly missing?
// - For DB-missing lat/lng: does Samsara have them (cheap backfill)?
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SAM = process.env.SAMSARA_API_TOKEN;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}` };

async function rest(qs, opts = {}) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, { ...opts, headers: { ...H, ...(opts.headers || {}) } });
  if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
  return r.json();
}
async function samsara(p) {
  const r = await fetch(`https://api.samsara.com${p}`, { headers: { Authorization: `Bearer ${SAM}`, Accept: 'application/json' } });
  if (!r.ok) throw new Error(`Samsara ${r.status}`);
  return r.json();
}
function distM(la1, lo1, la2, lo2) {
  const R = 6371000, rad = d => d * Math.PI / 180;
  const dLa = rad(la2 - la1), dLo = rad(lo2 - lo1);
  const a = Math.sin(dLa/2) ** 2 + Math.cos(rad(la1)) * Math.cos(rad(la2)) * Math.sin(dLo/2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

(async () => {
  // Pull Samsara geofences
  const gfs = [];
  let nxt = '';
  while (true) {
    const qs = nxt ? `&after=${encodeURIComponent(nxt)}` : '';
    const r = await samsara(`/addresses?limit=512${qs}`);
    for (const g of r.data || []) gfs.push(g);
    if (!r.pagination?.hasNextPage) break;
    nxt = r.pagination.endCursor;
  }
  console.log(`Pulled ${gfs.length} Samsara geofences`);

  // Pull ALL clients (not just active) for orphan check
  const allClients = await rest('clients?select=id,client_code,name,status&limit=10000');
  const codeToClient = {};
  for (const c of allClients) {
    if (c.client_code) codeToClient[c.client_code.toUpperCase()] = c;
  }

  // ============================================================
  // Q1: For unmatched-active Samsara geofences, what's the status?
  // ============================================================
  console.log('\n=== Q1) Unmatched Samsara geofences — what client_code state? ===');
  const results = [];
  for (const gf of gfs) {
    const upper = (gf.name || '').toUpperCase();
    // Try to extract code prefix like "138-ASW"
    const m = upper.match(/^(\d{3}-[A-Z0-9]+)/);
    const code = m ? m[1] : null;
    if (!code) continue;
    const c = codeToClient[code];
    if (!c || c.status === 'ACTIVE' || c.status === 'RECURRING') {
      // active/missing both flagged
      results.push({
        gf_name: (gf.name || '').slice(0, 40),
        code,
        client_status: c?.status || 'NO_CLIENT_ROW',
        client_id: c?.id || null,
      });
    }
  }
  // Group by status
  const byStatus = {};
  for (const r of results) {
    byStatus[r.client_status] = (byStatus[r.client_status] || 0) + 1;
  }
  console.log('  Status of clients behind code-prefixed Samsara geofences:');
  console.table(Object.entries(byStatus).map(([s, n]) => ({ status: s, count: n })));

  // Show inactive/paused ones first (Samsara still has geofence but we marked them dead)
  const dead = results.filter(r => !['ACTIVE', 'RECURRING'].includes(r.client_status));
  if (dead.length > 0) {
    console.log(`\n  Samsara geofences for clients that are NOT active/recurring (n=${dead.length}, first 30):`);
    console.table(dead.slice(0, 30));
  }

  // ============================================================
  // Q2: 16 DB-missing-lat/lng — does Samsara have them?
  // ============================================================
  console.log('\n=== Q2) Active/recurring clients missing DB lat/lng — does Samsara have coords? ===');
  const missingClients = await rest('clients?status=in.(ACTIVE,RECURRING)&select=id,client_code,name&limit=10000');
  const ids = missingClients.map(c => c.id);
  const props = [];
  for (let i = 0; i < ids.length; i += 200) {
    const chunk = ids.slice(i, i + 200);
    const rows = await rest(`properties?client_id=in.(${chunk.join(',')})&is_primary=eq.true&latitude=is.null&select=id,client_id,address,city`);
    props.push(...rows);
  }
  console.log(`  ${props.length} active/recurring clients have a primary property with NULL lat/lng`);

  const missClientById = {};
  for (const c of missingClients) missClientById[c.id] = c;

  const backfillable = [];
  const notInSamsara = [];
  for (const p of props) {
    const c = missClientById[p.client_id];
    const code = c?.client_code?.toUpperCase();
    let foundGf = null;
    for (const gf of gfs) {
      const upper = (gf.name || '').toUpperCase();
      if (code && upper.includes(code)) { foundGf = gf; break; }
    }
    if (foundGf && foundGf.latitude && foundGf.longitude) {
      backfillable.push({
        client_code: c?.client_code,
        client_name: c?.name,
        db_address: p.address?.slice(0, 50),
        samsara_lat: foundGf.latitude,
        samsara_lng: foundGf.longitude,
        samsara_addr: (foundGf.formattedAddress || '').slice(0, 50),
      });
    } else {
      notInSamsara.push({
        client_code: c?.client_code,
        client_name: c?.name,
        db_address: p.address?.slice(0, 50),
        city: p.city,
      });
    }
  }
  console.log(`  Of those, ${backfillable.length} have a matching Samsara geofence (backfillable for free)`);
  if (backfillable.length > 0) {
    console.table(backfillable);
  }
  console.log(`  ${notInSamsara.length} have NO matching Samsara geofence — would need Google geocoder`);
  if (notInSamsara.length > 0) {
    console.table(notInSamsara);
  }

  // ============================================================
  // Q3: 3 mismatches > 200m — explain each
  // ============================================================
  console.log('\n=== Q3) Existing mismatches — context ===');
  // 151-OAS
  const c151 = codeToClient['151-OAS'];
  if (c151) {
    const props151 = await rest(`properties?client_id=eq.${c151.id}&select=id,name,is_primary,address,city,latitude,longitude&order=is_primary.desc`);
    console.log('  151-OAS all properties:');
    console.table(props151);
  }

  // BHRE Property Management
  const bhre = allClients.find(c => /BHRE/i.test(c.name || ''));
  if (bhre) {
    const propsB = await rest(`properties?client_id=eq.${bhre.id}&select=id,name,is_primary,address,city,latitude,longitude&order=is_primary.desc`);
    console.log('  BHRE all properties:');
    console.table(propsB);
  }
})().catch(err => { console.error(err); process.exit(1); });
