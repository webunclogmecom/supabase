// ============================================================================
// Phase B — Samsara Probe (READ-ONLY)
// ============================================================================
// Discovers vehicles, addresses (geofences), drivers.
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');

const TOKEN = process.env.SAMSARA_API_TOKEN;
if (!TOKEN) { console.error('Missing SAMSARA_API_TOKEN'); process.exit(1); }

function get(p) {
  return new Promise((res, rej) => {
    https.request({
      hostname: 'api.samsara.com',
      path: p,
      headers: { Authorization: `Bearer ${TOKEN}` },
    }, r => {
      let d = '';
      r.on('data', c => d += c);
      r.on('end', () => {
        if (r.statusCode >= 200 && r.statusCode < 300) {
          try { res(JSON.parse(d)); } catch (e) { rej(new Error('bad json: ' + d.slice(0, 200))); }
        } else rej(new Error(`HTTP ${r.statusCode}: ${d.slice(0, 300)}`));
      });
    }).on('error', rej).end();
  });
}

async function fetchAll(basePath, label) {
  let all = [], after = null, pages = 0;
  do {
    const sep = basePath.includes('?') ? '&' : '?';
    const p = basePath + (after ? `${sep}after=${encodeURIComponent(after)}` : '');
    const r = await get(p);
    all = all.concat(r.data || []);
    after = r.pagination && r.pagination.endCursor && r.pagination.hasNextPage ? r.pagination.endCursor : null;
    pages++;
    if (pages > 50) { console.log(`  [warn] ${label}: page cap hit`); break; }
  } while (after);
  return all;
}

(async () => {
  console.log('Phase B — Samsara Probe\n');
  const report = { generated_at: new Date().toISOString(), sources: {} };

  // Vehicles
  console.log('[1/3] Vehicles...');
  const vehicles = await fetchAll('/fleet/vehicles?limit=100', 'vehicles');
  console.log(`    ${vehicles.length} vehicles`);
  vehicles.forEach(v => console.log(`      - ${v.name} (${v.make} ${v.model} ${v.year}) id=${v.id}`));
  report.sources.vehicles = {
    count: vehicles.length,
    records: vehicles.map(v => ({
      id: v.id, name: v.name, make: v.make, model: v.model, year: v.year,
      vin: v.externalIds && v.externalIds['samsara.vin'], licensePlate: v.licensePlate,
      gateway_serial: v.gateway && v.gateway.serial,
      fieldKeys: Object.keys(v),
    })),
  };

  // Addresses (geofences)
  console.log('\n[2/3] Addresses (geofences)...');
  const addresses = await fetchAll('/addresses?limit=512', 'addresses');
  console.log(`    ${addresses.length} addresses`);
  const geoTypes = {};
  addresses.forEach(a => {
    const t = a.geofence ? (a.geofence.circle ? 'circle' : (a.geofence.polygon ? 'polygon' : 'other')) : 'none';
    geoTypes[t] = (geoTypes[t] || 0) + 1;
  });
  console.log(`    Geofence types:`, geoTypes);
  report.sources.addresses = {
    count: addresses.length,
    geo_types: geoTypes,
    sample_fieldKeys: addresses[0] ? Object.keys(addresses[0]) : [],
    samples: addresses.slice(0, 3).map(a => ({
      id: a.id, name: a.name, formattedAddress: a.formattedAddress,
      lat: a.latitude, lon: a.longitude,
      notes: a.notes, tags: a.tags,
    })),
  };

  // Drivers
  console.log('\n[3/3] Drivers...');
  const drivers = await fetchAll('/fleet/drivers?limit=100', 'drivers');
  console.log(`    ${drivers.length} drivers`);
  drivers.forEach(d => console.log(`      - ${d.name} (status=${d.driverActivationStatus || 'n/a'})`));
  report.sources.drivers = {
    count: drivers.length,
    records: drivers.map(d => ({
      id: d.id, name: d.name, status: d.driverActivationStatus,
      username: d.username, licenseNumber: d.licenseNumber ? '(present)' : null,
      fieldKeys: Object.keys(d),
    })),
  };

  const out = path.resolve(__dirname, 'phase_b_samsara_report.json');
  fs.writeFileSync(out, JSON.stringify(report, null, 2));
  console.log(`\nReport: ${out}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
