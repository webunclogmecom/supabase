// Backfill properties.latitude/longitude/geofence_radius_meters/geofence_type
// from Samsara /addresses for active/recurring clients where values are NULL.
//
// Matching:
//   1) Strict client_code prefix in Samsara geofence name (e.g. "208-HUB ...")
//   2) Fallback: normalized client.name substring match (helps with renamed
//      Samsara geofences like "014-FEN Fendi Château" vs our 167-FEN row)
//
// Only writes a field if it is currently NULL — never overwrites existing data.
// Idempotent. Dry-run by default; pass --execute to write.
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SAM = process.env.SAMSARA_API_TOKEN;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}`, 'Content-Type': 'application/json' };
const EXECUTE = process.argv.includes('--execute');

async function rest(qs, opts = {}) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, { ...opts, headers: { ...H, ...(opts.headers || {}) } });
  if (!r.ok) throw new Error(`REST ${r.status} ${await r.text()}`);
  const text = await r.text();
  if (!text) return null;
  try { return JSON.parse(text); } catch { return text; }
}
async function samsara(p) {
  const r = await fetch(`https://api.samsara.com${p}`, { headers: { Authorization: `Bearer ${SAM}`, Accept: 'application/json' } });
  if (!r.ok) throw new Error(`Samsara ${r.status}`);
  return r.json();
}
function normalize(s) {
  return (s || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

(async () => {
  console.log(`Mode: ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}\n`);

  // 1) Pull all Samsara geofences
  const gfs = [];
  let nxt = '';
  while (true) {
    const qs = nxt ? `&after=${encodeURIComponent(nxt)}` : '';
    const r = await samsara(`/addresses?limit=512${qs}`);
    for (const g of r.data || []) gfs.push(g);
    if (!r.pagination?.hasNextPage) break;
    nxt = r.pagination.endCursor;
  }
  console.log(`Pulled ${gfs.length} Samsara geofences\n`);

  // 2) Pull active/recurring clients + primary properties that need any geo data
  const clients = await rest('clients?status=in.(ACTIVE,RECURRING)&select=id,client_code,name&limit=10000');
  const cById = {};
  for (const c of clients) cById[c.id] = c;
  const ids = clients.map(c => c.id);

  const props = [];
  for (let i = 0; i < ids.length; i += 200) {
    const chunk = ids.slice(i, i + 200);
    const rows = await rest(`properties?client_id=in.(${chunk.join(',')})&is_primary=eq.true&or=(latitude.is.null,geofence_radius_meters.is.null,geofence_type.is.null)&select=id,client_id,address,city,latitude,longitude,geofence_radius_meters,geofence_type&limit=10000`);
    props.push(...rows);
  }
  console.log(`${props.length} primary properties with at least one NULL geo field\n`);

  // 3) For each property, find best Samsara geofence
  let writes = 0, skipped = 0, noMatch = 0;
  const examples = [];

  for (const p of props) {
    const c = cById[p.client_id];
    if (!c) continue;
    const code = c.client_code?.toUpperCase();
    const ncname = normalize(c.name);

    let match = null;
    // Strict: code prefix in Samsara name
    if (code) {
      match = gfs.find(g => (g.name || '').toUpperCase().includes(code)) || null;
    }
    // Fallback: normalized name substring (>=6 chars to avoid false positives)
    if (!match && ncname && ncname.length >= 6) {
      match = gfs.find(g => {
        const ng = normalize(g.name);
        return ng.length >= 6 && (ng.includes(ncname) || ncname.includes(ng));
      }) || null;
    }

    if (!match) { noMatch++; continue; }

    // Pull lat/lng from the address record (fall back to circle geofence center)
    const lat = match.latitude ?? match.geofence?.circle?.latitude ?? null;
    const lng = match.longitude ?? match.geofence?.circle?.longitude ?? null;
    const radius = match.geofence?.circle?.radiusMeters ?? null;
    const geoType = match.geofence?.polygon ? 'polygon' : match.geofence?.circle ? 'circle' : null;

    const patch = {};
    if (p.latitude == null && lat != null) patch.latitude = lat;
    if (p.longitude == null && lng != null) patch.longitude = lng;
    if (p.geofence_radius_meters == null && radius != null) patch.geofence_radius_meters = radius;
    if (p.geofence_type == null && geoType != null) patch.geofence_type = geoType;

    if (Object.keys(patch).length === 0) { skipped++; continue; }

    if (examples.length < 25) {
      examples.push({
        client_code: c.client_code,
        client_name: c.name?.slice(0, 30),
        samsara_gf: match.name?.slice(0, 30),
        patch_keys: Object.keys(patch).join(','),
        lat: patch.latitude,
        lng: patch.longitude,
        radius: patch.geofence_radius_meters,
        type: patch.geofence_type,
      });
    }

    if (EXECUTE) {
      await rest(`properties?id=eq.${p.id}`, {
        method: 'PATCH',
        headers: { Prefer: 'return=minimal' },
        body: JSON.stringify(patch),
      });
    }

    // Link to Samsara if no existing samsara link for this property
    if (EXECUTE) {
      const existing = await rest(`entity_source_links?entity_type=eq.property&entity_id=eq.${p.id}&source_system=eq.samsara&select=id&limit=1`);
      if (!existing || existing.length === 0) {
        await rest('entity_source_links', {
          method: 'POST',
          headers: { Prefer: 'return=minimal' },
          body: JSON.stringify({
            entity_type: 'property',
            entity_id: p.id,
            source_system: 'samsara',
            source_id: `addr_${match.id}`,
            source_name: match.name,
            match_method: 'backfill_geo',
          }),
        });
      }
    }

    writes++;
  }

  console.log('=== Sample patches ===');
  console.table(examples);

  console.log(`\n=== Summary ===`);
  console.table([
    { metric: 'properties patched',         count: writes },
    { metric: 'matched but already filled', count: skipped },
    { metric: 'no Samsara match',           count: noMatch },
    { metric: 'mode',                       count: EXECUTE ? 'EXECUTE' : 'DRY-RUN' },
  ]);
})().catch(err => { console.error(err); process.exit(1); });
