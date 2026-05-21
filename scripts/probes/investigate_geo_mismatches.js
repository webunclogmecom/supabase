// Investigate 3 geo mismatches >200m. For each, pull the actual Samsara
// geofence that was matched, the DB property full record, and decide whether
// Samsara's address is the right one (overwrite candidate) or the matcher was
// wrong (false positive — leave DB alone).
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SAM = process.env.SAMSARA_API_TOKEN;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}` };

async function rest(qs, opts = {}) {
  const r = await fetch(`${URL}/rest/v1/${qs}`, { ...opts, headers: { ...H, ...(opts.headers || {}) } });
  if (!r.ok) throw new Error(`REST ${r.status} ${await r.text()}`);
  return r.json();
}
async function samsara(p) {
  const r = await fetch(`https://api.samsara.com${p}`, { headers: { Authorization: `Bearer ${SAM}` } });
  if (!r.ok) throw new Error(`Samsara ${r.status}`);
  return r.json();
}

function dist(la1, lo1, la2, lo2) {
  const R = 6371000, rad = d => d * Math.PI / 180;
  const dLa = rad(la2 - la1), dLo = rad(lo2 - lo1);
  const a = Math.sin(dLa/2)**2 + Math.cos(rad(la1))*Math.cos(rad(la2))*Math.sin(dLo/2)**2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

const TARGETS = [
  { name: 'Courtyard by Marriott SOBE',  samsara_needle: 'yard',                       db_addr_match: 'Washington' },
  { name: 'BHRE Property Management',    samsara_needle: 'BHRE',                       db_addr_match: '1870' },
  { name: '151-OAS Oasis Hallandale',    samsara_needle: '151-OAS Oasis',              db_addr_match: '1000 East Hallandale' },
];

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
  console.log(`Pulled ${gfs.length} Samsara geofences\n`);

  for (const t of TARGETS) {
    console.log(`\n========== ${t.name} ==========`);
    // Pull all candidate Samsara geofences by needle
    const candidates = gfs.filter(g => (g.name || '').toLowerCase().includes(t.samsara_needle.toLowerCase()));
    console.log(`Samsara candidates matching "${t.samsara_needle}" (${candidates.length}):`);
    for (const c of candidates) {
      console.log(`  - id=${c.id} name="${c.name}" lat=${c.latitude} lng=${c.longitude} addr="${c.formattedAddress}"`);
    }

    // Pull DB client + all properties
    const clients = await rest(`clients?name=ilike.*${encodeURIComponent(t.name.split(' ')[0])}*&select=id,client_code,name,status`);
    console.log(`\nDB clients matching first word "${t.name.split(' ')[0]}":`);
    for (const c of clients) {
      console.log(`  - id=${c.id} code=${c.client_code} name="${c.name}" status=${c.status}`);
      const props = await rest(`properties?client_id=eq.${c.id}&select=id,is_primary,is_billing,address,city,zip,latitude,longitude&order=is_primary.desc,id`);
      for (const p of props) {
        console.log(`      prop ${p.id} ${p.is_primary?'★primary':''} ${p.is_billing?'$billing':''} "${p.address}" ${p.city} ${p.zip} (${p.latitude}, ${p.longitude})`);
      }

      // Check ESL for this client + props
      const propIds = props.map(p => p.id).join(',');
      if (propIds) {
        const esls = await rest(`entity_source_links?entity_type=eq.property&entity_id=in.(${propIds})&select=id,entity_id,source_system,source_id,source_name,match_method`);
        if (esls.length) {
          console.log(`      ESL on these properties:`);
          for (const e of esls) {
            console.log(`        prop=${e.entity_id} ${e.source_system}:${e.source_id} name="${e.source_name}" method=${e.match_method}`);
          }
        }
      }
    }

    // Distance check for each (client property, samsara candidate) pair
    if (clients.length && candidates.length) {
      console.log(`\n  Pairwise distances:`);
      for (const c of clients) {
        const props = await rest(`properties?client_id=eq.${c.id}&select=id,address,latitude,longitude`);
        for (const p of props) {
          if (p.latitude == null) continue;
          for (const g of candidates) {
            if (g.latitude == null) continue;
            const d = dist(p.latitude, p.longitude, g.latitude, g.longitude);
            console.log(`    prop ${p.id} "${p.address?.slice(0,40)}" ↔ samsara ${g.id} "${g.name}" → ${Math.round(d)}m`);
          }
        }
      }
    }
  }
})().catch(err => { console.error(err); process.exit(1); });
