// Link Sbx properties to their Samsara geofence/address entity_source_link.
// Audit 2026-05-12 found 0/455 properties linked — the explicit link was
// never populated even though autopilot uses Samsara via raw GPS coords.
//
// Algorithm:
//   1. Pull all Samsara fleet/addresses (id, name, latitude, longitude, geofence).
//   2. Pull Sbx properties with GPS.
//   3. For each property, find the closest Samsara address. If within 100m
//      OR if names normalize to the same string → link.
//   4. Insert entity_source_link row (idempotent on PK).
//
// Dry-run by default. Pass --execute to write.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SUPABASE_URL = process.env.SUPABASE_URL;
const SAMSARA_TOKEN = process.env.SAMSARA_API_TOKEN;
const EXECUTE = process.argv.includes('--execute');

function http(opts, body) { return new Promise((res, rej) => {
  const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
  const req = https.request({...opts, headers:{...(opts.headers||{}), ...(payload?{'Content-Length':Buffer.byteLength(payload)}:{})}}, r => {
    const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()}));
  });
  req.on('error',rej); if(payload) req.write(payload); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:'/v1/projects/'+PROD+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error('PG '+r.status+': '+r.body.slice(0,300)); return JSON.parse(r.body); }
async function rest(path, opts = {}) { const u = new URL(SUPABASE_URL + '/rest/v1' + path); const r = await http({hostname:u.hostname,path:u.pathname+u.search,method:opts.method||'GET',headers:{apikey:SVC,Authorization:'Bearer '+SVC,'Content-Type':'application/json',...(opts.headers||{})}}, opts.body); if (r.status>=300) throw new Error('REST '+r.status+': '+r.body.slice(0,300)); return r.body ? JSON.parse(r.body) : null; }

async function samsaraAddresses() {
  // Pagination support via afterId cursor
  const out = []; let cursor;
  do {
    const path = '/addresses?limit=512' + (cursor ? '&after=' + encodeURIComponent(cursor) : '');
    const r = await http({hostname:'api.samsara.com',path,method:'GET',headers:{Authorization:'Bearer '+SAMSARA_TOKEN}});
    if (r.status>=300) throw new Error('Samsara '+r.status+': '+r.body.slice(0,200));
    const j = JSON.parse(r.body);
    for (const a of (j.data||[])) out.push(a);
    cursor = j.pagination?.endCursor;
    if (!j.pagination?.hasNextPage) break;
  } while (cursor);
  return out;
}

function haversineM(lat1,lng1,lat2,lng2) {
  const R=6371000, toRad=d=>d*Math.PI/180;
  const dLat=toRad(lat2-lat1), dLng=toRad(lng2-lng1);
  const a=Math.sin(dLat/2)**2 + Math.cos(toRad(lat1))*Math.cos(toRad(lat2))*Math.sin(dLng/2)**2;
  return 2*R*Math.asin(Math.sqrt(a));
}
function normName(s) {
  return (s||'').toString().toLowerCase().replace(/[^a-z0-9]/g,'').trim();
}

(async () => {
  console.log(`Mode: ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}\n`);
  console.log('Fetching Samsara addresses...');
  const samsara = await samsaraAddresses();
  console.log('  Samsara addresses:', samsara.length);

  console.log('Fetching Sbx properties...');
  const props = await pg(`
    SELECT p.id, p.name, p.address, p.latitude::float AS lat, p.longitude::float AS lng,
      c.client_code, c.name AS client_name,
      (SELECT source_id FROM entity_source_links WHERE entity_type='property' AND entity_id=p.id AND source_system='samsara' LIMIT 1) AS existing_link
    FROM properties p JOIN clients c ON c.id = p.client_id
    WHERE p.latitude IS NOT NULL AND p.longitude IS NOT NULL;`);
  console.log('  Sbx properties w/ GPS:', props.length);

  // Build name index for Samsara
  const samsaraByName = new Map();
  for (const sa of samsara) {
    const n = normName(sa.name);
    if (n && !samsaraByName.has(n)) samsaraByName.set(n, sa);
  }

  const writes = [];
  const unmatched = [];

  for (const p of props) {
    if (p.existing_link) continue;
    // Try name match (client name OR property name)
    const candidates = [normName(p.client_name), normName(p.name)].filter(Boolean);
    let matched = null;
    for (const n of candidates) {
      if (samsaraByName.has(n)) { matched = { sa: samsaraByName.get(n), method: 'name', dist: null }; break; }
    }
    // Try GPS proximity
    if (!matched) {
      let best = null;
      for (const sa of samsara) {
        if (typeof sa.latitude !== 'number' || typeof sa.longitude !== 'number') continue;
        const d = haversineM(p.lat, p.lng, sa.latitude, sa.longitude);
        if (!best || d < best.dist) best = { sa, dist: d };
      }
      if (best && best.dist <= 100) matched = { sa: best.sa, method: 'gps_100m', dist: Math.round(best.dist) };
    }

    if (matched) {
      writes.push({
        property_id: p.id, samsara_id: String(matched.sa.id), samsara_name: matched.sa.name,
        method: matched.method, dist_m: matched.dist,
        client_code: p.client_code, sbx_name: p.client_name,
      });
    } else {
      unmatched.push({ property_id: p.id, client_code: p.client_code, sbx_name: p.client_name });
    }
  }

  console.log(`\nMatched: ${writes.length}`);
  const byMethod = {};
  for (const w of writes) byMethod[w.method] = (byMethod[w.method]||0)+1;
  console.log('  by method:', JSON.stringify(byMethod));
  console.log(`Unmatched: ${unmatched.length}`);

  if (writes.length) {
    console.log('\nSample writes (first 10):');
    for (const w of writes.slice(0,10)) console.log('  ✓ prop '+w.property_id+'  '+(w.client_code||'-').padEnd(10)+'"'+w.sbx_name+'"  → Samsara '+w.samsara_id+' "'+w.samsara_name+'" ['+w.method+(w.dist_m?', '+w.dist_m+'m':'')+']');
  }

  if (!EXECUTE) { console.log('\n[DRY-RUN] pass --execute to write links.'); return; }

  console.log('\nWriting entity_source_links...');
  let ok = 0;
  for (const w of writes) {
    try {
      await rest('/entity_source_links', { method: 'POST', headers: { Prefer: 'resolution=merge-duplicates' }, body: JSON.stringify({
        entity_type: 'property', entity_id: w.property_id, source_system: 'samsara', source_id: w.samsara_id, source_name: w.samsara_name,
        match_method: w.method, match_confidence: w.method === 'name' ? 1.0 : Math.max(0.5, 1.0 - (w.dist_m || 0) / 100),
      }) });
      ok++;
    } catch (e) {
      console.error(`  ! prop ${w.property_id} write failed: ${e.message}`);
    }
  }
  console.log('  ✓ '+ok+'/'+writes.length+' links written');
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
