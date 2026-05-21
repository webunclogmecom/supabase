// Audit client addresses + geo coverage.
// Phase 1: 208-HUB specifically + DB-side coverage stats.
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
  // ============================================================
  // 1) 208-HUB spot check
  // ============================================================
  console.log('=== 1) 208-HUB ===');
  const { rows: clients } = await rest('clients?client_code=eq.208-HUB&select=id,client_code,name,status');
  if (clients.length === 0) {
    console.log('  ❌ No client row with client_code=208-HUB');
    // Try LIKE
    const { rows: like } = await rest('clients?client_code=like.*208-HUB*&select=id,client_code,name,status&limit=5');
    console.log('  LIKE *208-HUB* matches:', like);
    // Try name search
    const { rows: nameLike } = await rest('clients?name=ilike.*hub*&select=id,client_code,name,status&limit=10');
    console.log('  name ilike *hub* matches:', nameLike);
    return;
  }
  console.table(clients);

  for (const c of clients) {
    const { rows: props } = await rest(`properties?client_id=eq.${c.id}&select=id,name,is_primary,is_billing,address,city,state,zip,latitude,longitude,geofence_radius_meters,geofence_type,zone,county&order=is_primary.desc,id`);
    console.log(`\n  → ${c.client_code} ${c.name} (id=${c.id}) — ${props.length} properties`);
    console.table(props);

    // Cross-system identifiers
    const { rows: esl } = await rest(`entity_source_links?entity_type=eq.client&entity_id=eq.${c.id}&select=source_system,source_id,source_name,match_method`);
    console.log(`     entity_source_links (client level):`);
    console.table(esl);

    // Property-level cross-refs (sometimes Samsara geofences attach here)
    if (props.length > 0) {
      const propIds = props.map(p => p.id);
      const { rows: pEsl } = await rest(`entity_source_links?entity_type=eq.property&entity_id=in.(${propIds.join(',')})&select=entity_id,source_system,source_id,source_name`);
      if (pEsl.length > 0) {
        console.log(`     entity_source_links (property level):`);
        console.table(pEsl);
      } else {
        console.log(`     (no property-level entity_source_links)`);
      }
    }
  }

  // ============================================================
  // 2) DB-side coverage stats across ACTIVE/RECURRING clients
  // ============================================================
  console.log('\n=== 2) Coverage stats — ACTIVE + RECURRING clients only ===');

  const { count: activeClients } = await rest('clients?status=in.(ACTIVE,RECURRING)&select=id', {
    headers: { Prefer: 'count=exact', Range: '0-0' },
  });

  // Properties for active/recurring clients
  // Use a join via the view if available; otherwise pull active client ids first.
  const { rows: activeIds } = await rest('clients?status=in.(ACTIVE,RECURRING)&select=id&limit=10000');
  const ids = activeIds.map(r => r.id);
  console.log(`  ${ids.length} active/recurring clients`);

  // Properties for those clients
  const chunkSize = 200;
  const allProps = [];
  for (let i = 0; i < ids.length; i += chunkSize) {
    const chunk = ids.slice(i, i + chunkSize);
    const filter = `client_id=in.(${chunk.join(',')})`;
    const { rows } = await rest(`properties?${filter}&select=id,client_id,is_primary,address,city,state,zip,latitude,longitude,geofence_radius_meters,geofence_type&limit=10000`);
    allProps.push(...rows);
  }
  console.log(`  ${allProps.length} property rows total for active/recurring clients`);

  // Clients with NO property row at all
  const clientsWithProps = new Set(allProps.map(p => p.client_id));
  const clientsWithoutProps = ids.filter(id => !clientsWithProps.has(id));
  console.log(`  Clients with NO property row: ${clientsWithoutProps.length}`);
  if (clientsWithoutProps.length > 0 && clientsWithoutProps.length <= 30) {
    const { rows } = await rest(`clients?id=in.(${clientsWithoutProps.join(',')})&select=id,client_code,name,status&order=client_code`);
    console.table(rows);
  } else if (clientsWithoutProps.length > 30) {
    const { rows } = await rest(`clients?id=in.(${clientsWithoutProps.slice(0, 30).join(',')})&select=id,client_code,name,status&order=client_code`);
    console.log('  first 30:');
    console.table(rows);
  }

  // Primary property per client
  const primaryByClient = {};
  for (const p of allProps) {
    if (p.is_primary || !primaryByClient[p.client_id]) primaryByClient[p.client_id] = p;
  }
  const primaries = Object.values(primaryByClient);

  const missingAddress = primaries.filter(p => !p.address || p.address.trim() === '');
  const missingCity = primaries.filter(p => !p.city);
  const missingZip = primaries.filter(p => !p.zip);
  const missingLatLng = primaries.filter(p => p.latitude == null || p.longitude == null);
  const missingGeofence = primaries.filter(p => p.geofence_radius_meters == null);

  console.log(`\n  Coverage on primary property per active/recurring client (n=${primaries.length}):`);
  console.table([
    { field: 'address',                  missing: missingAddress.length, pct: ((1 - missingAddress.length / primaries.length) * 100).toFixed(1) + '%' },
    { field: 'city',                     missing: missingCity.length,    pct: ((1 - missingCity.length    / primaries.length) * 100).toFixed(1) + '%' },
    { field: 'zip',                      missing: missingZip.length,     pct: ((1 - missingZip.length     / primaries.length) * 100).toFixed(1) + '%' },
    { field: 'latitude+longitude',       missing: missingLatLng.length,  pct: ((1 - missingLatLng.length  / primaries.length) * 100).toFixed(1) + '%' },
    { field: 'geofence_radius_meters',   missing: missingGeofence.length, pct: ((1 - missingGeofence.length / primaries.length) * 100).toFixed(1) + '%' },
  ]);

  // List the address-missing clients (those usually indicate worse problems)
  if (missingAddress.length > 0) {
    const missIds = missingAddress.map(p => p.client_id);
    const { rows } = await rest(`clients?id=in.(${missIds.slice(0, 30).join(',')})&select=id,client_code,name,status&order=client_code`);
    console.log(`\n  Active/recurring clients whose primary property has NO street address (first 30 of ${missingAddress.length}):`);
    console.table(rows);
  }

  // List clients missing lat/lng entirely
  if (missingLatLng.length > 0) {
    const missIds = missingLatLng.map(p => p.client_id);
    const { rows } = await rest(`clients?id=in.(${missIds.slice(0, 30).join(',')})&select=id,client_code,name,status&order=client_code`);
    console.log(`\n  Active/recurring clients with NO lat/lng on primary property (first 30 of ${missingLatLng.length}):`);
    console.table(rows.map(r => ({
      ...r,
      addr: primaryByClient[r.id]?.address?.slice(0, 50),
      city: primaryByClient[r.id]?.city,
    })));
  }
})().catch(err => { console.error(err); process.exit(1); });
