// Pull Samsara geofences + cross-check vs DB property lat/lng.
// Flags mismatches beyond a distance threshold.
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
  if (!r.ok) throw new Error(`Samsara ${r.status} ${await r.text()}`);
  return r.json();
}

// Haversine distance (meters)
function distMeters(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const toRad = d => d * Math.PI / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat/2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon/2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

function normalize(s) {
  return (s || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
}

(async () => {
  // ============================================================
  // Pull Samsara geofences (paginated)
  // ============================================================
  console.log('=== Pulling Samsara geofences ===');
  const geofences = [];
  let nextAfter = '';
  while (true) {
    const qs = nextAfter ? `&after=${encodeURIComponent(nextAfter)}` : '';
    const resp = await samsara(`/addresses?limit=512${qs}`);
    for (const g of resp.data || []) geofences.push(g);
    if (!resp.pagination?.hasNextPage) break;
    nextAfter = resp.pagination.endCursor;
  }
  console.log(`  ${geofences.length} Samsara geofences pulled`);

  // Show shape of first
  if (geofences[0]) {
    console.log('  Sample geofence shape:', JSON.stringify({
      id: geofences[0].id,
      name: geofences[0].name,
      latitude: geofences[0].latitude,
      longitude: geofences[0].longitude,
      formattedAddress: geofences[0].formattedAddress,
      geofence: geofences[0].geofence,
      addressTypes: geofences[0].addressTypes,
    }, null, 2));
  }

  // ============================================================
  // Pull all DB clients + their primary property
  // ============================================================
  console.log('\n=== Pulling DB clients + primary properties ===');
  const clients = await rest('clients?status=in.(ACTIVE,RECURRING)&select=id,client_code,name&limit=10000');
  const ids = clients.map(c => c.id);
  const props = [];
  for (let i = 0; i < ids.length; i += 200) {
    const chunk = ids.slice(i, i + 200);
    const rows = await rest(`properties?client_id=in.(${chunk.join(',')})&is_primary=eq.true&select=id,client_id,address,city,latitude,longitude,geofence_radius_meters&limit=10000`);
    props.push(...rows);
  }
  const propByClient = {};
  for (const p of props) propByClient[p.client_id] = p;
  console.log(`  ${clients.length} active/recurring clients, ${props.length} primary properties`);

  // ============================================================
  // Match Samsara geofence to client.
  // Priority: (a) explicit ESL on a property → trust it.
  //           (b) client_code prefix in geofence name.
  //           (c) fuzzy name substring fallback.
  // ============================================================
  console.log('\n=== Matching Samsara geofences to clients ===');
  // Pull ESL property→samsara map once
  const eslRows = await rest('entity_source_links?entity_type=eq.property&source_system=eq.samsara&select=entity_id,source_id&limit=10000');
  // ESL source_id may be bare numeric OR "addr_<id>" — normalize both
  const samsaraIdToPropId = {};
  for (const e of eslRows) {
    const raw = String(e.source_id || '');
    const numeric = raw.startsWith('addr_') ? raw.slice(5) : raw;
    samsaraIdToPropId[numeric] = e.entity_id;
  }
  const propToClient = {};
  for (const p of props) propToClient[p.id] = p.client_id;
  const clientById = {};
  for (const c of clients) clientById[c.id] = c;

  const matches = [];
  const unmatchedGf = [];
  const codeIndex = {};
  for (const c of clients) {
    if (c.client_code) codeIndex[c.client_code.toUpperCase()] = c;
  }
  const nameIndex = {};
  for (const c of clients) {
    const key = normalize(c.name);
    if (key) nameIndex[key] = c;
  }

  for (const gf of geofences) {
    let matched = null;

    // (a) ESL → property → client
    const propId = samsaraIdToPropId[String(gf.id)];
    if (propId) {
      const cId = propToClient[propId];
      if (cId && clientById[cId]) matched = clientById[cId];
    }

    if (!matched) {
      const gname = gf.name || '';
      const upper = gname.toUpperCase();
      // (b) client_code prefix
      for (const code of Object.keys(codeIndex)) {
        if (upper.includes(code)) { matched = codeIndex[code]; break; }
      }
      // (c) fuzzy name substring — both sides must be ≥8 chars to avoid
      // accidental matches like "yard" ⊂ "courtyard".
      if (!matched) {
        const ngn = normalize(gname);
        if (ngn.length >= 8) {
          for (const nm of Object.keys(nameIndex)) {
            if (nm.length >= 8 && (ngn.includes(nm) || nm.includes(ngn))) {
              matched = nameIndex[nm];
              break;
            }
          }
        }
      }
    }

    if (matched) {
      matches.push({ gf, client: matched });
    } else {
      unmatchedGf.push(gf);
    }
  }
  console.log(`  ${matches.length} geofences matched to a client, ${unmatchedGf.length} unmatched`);

  // ============================================================
  // Compute distance mismatch for matched pairs that have both coordinates.
  // Skip when an ESL already proves a different Samsara geofence is the
  // authoritative one (avoids false positives from stale Samsara duplicates).
  // ============================================================
  const mismatches = [];
  let bothMissing = 0;
  let dbMissingLatLng = 0;
  let goodMatch = 0;
  let suppressedByEsl = 0;

  for (const { gf, client } of matches) {
    const prop = propByClient[client.id];
    if (!prop) { dbMissingLatLng++; continue; }
    if (prop.latitude == null || prop.longitude == null) { dbMissingLatLng++; continue; }
    if (gf.latitude == null || gf.longitude == null) { bothMissing++; continue; }

    const d = distMeters(prop.latitude, prop.longitude, gf.latitude, gf.longitude);
    if (d > 200) {
      // Suppress if this client has an ESL pointing to a different Samsara
      // geofence — meaning Samsara has multiple/duplicate geofences and the
      // ESL has already picked the right one.
      const eslGfId = Object.entries(samsaraIdToPropId).find(([, pid]) => pid === prop.id)?.[0];
      if (eslGfId && String(gf.id) !== String(eslGfId)) {
        suppressedByEsl++;
        continue;
      }
      mismatches.push({
        client_code: client.client_code,
        client_name: client.name,
        gf_name: gf.name,
        db_address: prop.address?.slice(0, 50),
        db_lat: prop.latitude,
        db_lng: prop.longitude,
        sam_lat: gf.latitude,
        sam_lng: gf.longitude,
        dist_m: Math.round(d),
      });
    } else {
      goodMatch++;
    }
  }

  console.log(`\n=== Comparison results ===`);
  console.table([
    { metric: 'matched & DB has lat/lng & ≤200m apart',  count: goodMatch },
    { metric: 'matched & DB MISSING lat/lng',            count: dbMissingLatLng },
    { metric: 'matched & Samsara missing coords',        count: bothMissing },
    { metric: 'mismatch suppressed by ESL (other GF wins)', count: suppressedByEsl },
    { metric: 'matched & MISMATCH >200m apart',          count: mismatches.length },
    { metric: 'Samsara geofence NOT matched to any client', count: unmatchedGf.length },
  ]);

  if (mismatches.length > 0) {
    console.log('\n=== Mismatches (DB lat/lng diverges from Samsara geofence by >200m) ===');
    mismatches.sort((a, b) => b.dist_m - a.dist_m);
    console.table(mismatches.slice(0, 50));
  }

  // Unmatched Samsara geofences — likely renamed or non-client geofences
  if (unmatchedGf.length > 0) {
    console.log(`\n=== Unmatched Samsara geofences (first 30 of ${unmatchedGf.length}) ===`);
    console.table(unmatchedGf.slice(0, 30).map(g => ({
      id: g.id,
      name: (g.name || '').slice(0, 60),
      lat: g.latitude,
      lng: g.longitude,
      addr: (g.formattedAddress || '').slice(0, 50),
    })));
  }
})().catch(err => { console.error(err); process.exit(1); });
