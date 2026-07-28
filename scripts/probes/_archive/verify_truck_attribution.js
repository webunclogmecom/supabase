require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROD = process.env.SUPABASE_PROJECT_ID;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:`/v1/projects/${PROD}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error(`PG ${r.status}: ${r.body.slice(0,200)}`); return JSON.parse(r.body); }
async function listAT(table, fields, filter) {
  const out=[]; let offset; const enc=encodeURIComponent;
  do {
    const fp = (fields||[]).map(f => `fields%5B%5D=${enc(f)}`).join('&');
    const ff = filter ? `&filterByFormula=${enc(filter)}` : '';
    const path = `/v0/${AT_BASE}/${enc(table)}?${fp}&pageSize=100${ff}${offset?`&offset=${enc(offset)}`:''}`;
    const r = await http({hostname:'api.airtable.com',path,method:'GET',headers:{Authorization:`Bearer ${AT_KEY}`}});
    if (r.status>=300) throw new Error(`AT ${r.status}: ${r.body.slice(0,200)}`);
    const j = JSON.parse(r.body); for (const rec of (j.records||[])) out.push({id:rec.id, ...rec.fields}); offset = j.offset;
  } while (offset);
  return out;
}
function haversineM(lat1, lng1, lat2, lng2) {
  const R = 6371000, toRad = d => d * Math.PI / 180;
  const dLat = toRad(lat2 - lat1), dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat/2)**2 + Math.cos(toRad(lat1))*Math.cos(toRad(lat2))*Math.sin(dLng/2)**2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

(async () => {
  // 1. Check Airtable Visits — does it have a "Truck" field that ever says Goliath?
  console.log('=== PART 1: Did Airtable EVER label a 2026 visit as Goliath? ===');
  console.log('(This would explain the original concern — if AT had Goliath labels we don\'t.)\n');
  const atVisits = await listAT('Visits', ['Truck','Visit Date','Service Type','Client Code'],
    `AND(IS_AFTER({Visit Date},'2025-12-31'),OR(FIND('Goliath',ARRAYJOIN({Truck}))>0,{Truck}='Goliath'))`);
  console.log(`  ${atVisits.length} Airtable 2026 visits with "Goliath" in Truck field`);
  if (atVisits.length > 0) {
    for (const v of atVisits.slice(0,15)) console.log(`    ${v['Visit Date']}  ${v['Client Code']||'-'}  Truck=${JSON.stringify(v['Truck'])}  svc=${v['Service Type']||'-'}`);
  }

  // Also pull the Truck-field distribution across all AT 2026 visits to know its shape
  console.log('\n=== Truck-field distribution across all AT 2026 visits ===');
  const allAt = await listAT('Visits', ['Truck'], `IS_AFTER({Visit Date},'2025-12-31')`);
  const dist = {};
  for (const v of allAt) {
    const t = Array.isArray(v.Truck) ? v.Truck.join(',') : (v.Truck || '(null)');
    dist[t] = (dist[t] || 0) + 1;
  }
  for (const [t, n] of Object.entries(dist).sort((a,b)=>b[1]-a[1])) console.log(`  ${t.padEnd(20)} ${n}`);

  // 2. Validate methodology: pick 5 real 2026 visits with vehicle_id set, show GPS evidence
  console.log('\n=== PART 2: Validate 5 random 2026 visits by their GPS evidence ===\n');
  const sample = await pg(`
    SELECT v.id AS visit_id, v.visit_date::text, v.visit_status,
      c.client_code, c.name AS client_name,
      v.start_at AT TIME ZONE 'America/New_York' AS start_et,
      v.completed_at AT TIME ZONE 'America/New_York' AS completed_et,
      v.start_at::text AS start_utc, v.completed_at::text AS completed_utc,
      vh.name AS assigned_truck, vh.id AS vehicle_id,
      p.latitude::float AS lat, p.longitude::float AS lng, p.address
    FROM visits v
    JOIN vehicles vh ON vh.id = v.vehicle_id
    LEFT JOIN clients c ON c.id = v.client_id
    LEFT JOIN properties p ON p.id = v.property_id
    WHERE v.visit_date >= '2026-04-01'
      AND v.visit_status='completed'
      AND v.start_at IS NOT NULL
      AND p.latitude IS NOT NULL
    ORDER BY random()
    LIMIT 5;`);

  for (const v of sample) {
    console.log(`Visit ${v.visit_id} — ${v.client_code || '?'} ${(v.client_name||'').slice(0,40)}`);
    console.log(`  Date: ${v.visit_date}  Status: ${v.visit_status}`);
    console.log(`  Start: ${v.start_et} ET  Complete: ${v.completed_et || '(running)'} ET`);
    console.log(`  Property: ${v.address || '(no address)'} @ ${v.lat},${v.lng}`);
    console.log(`  ASSIGNED TRUCK: ${v.assigned_truck}`);

    // Pull all GPS pings within 250m of property during visit window for ALL trucks
    const startMs = new Date(v.start_utc).getTime();
    const endMs = v.completed_utc ? new Date(v.completed_utc).getTime() : startMs + 60*60*1000;
    const winStart = new Date(startMs - 5*60*1000).toISOString();
    const winEnd = new Date(endMs + 5*60*1000).toISOString();
    const dLat = 0.003;
    const dLng = 0.003 / Math.cos(v.lat * Math.PI / 180);

    const tel = await pg(`
      SELECT vt.recorded_at::text AS recorded_at,
        vt.latitude::float AS tel_lat, vt.longitude::float AS tel_lng,
        veh.name AS truck
      FROM vehicle_telemetry_readings vt JOIN vehicles veh ON veh.id = vt.vehicle_id
      WHERE vt.recorded_at >= '${winStart}' AND vt.recorded_at <= '${winEnd}'
        AND vt.latitude BETWEEN ${v.lat-dLat} AND ${v.lat+dLat}
        AND vt.longitude BETWEEN ${v.lng-dLng} AND ${v.lng+dLng}
      ORDER BY recorded_at;`);

    const pingsByTruck = {};
    for (const p of tel) {
      const dist = haversineM(v.lat, v.lng, p.tel_lat, p.tel_lng);
      if (!pingsByTruck[p.truck]) pingsByTruck[p.truck] = [];
      pingsByTruck[p.truck].push({ time: p.recorded_at, dist_m: Math.round(dist) });
    }
    if (Object.keys(pingsByTruck).length === 0) {
      console.log(`  GPS evidence: NONE (within 333m bounding box, ${winStart} → ${winEnd})`);
    } else {
      for (const [truck, pings] of Object.entries(pingsByTruck)) {
        const minDist = Math.min(...pings.map(p => p.dist_m));
        const within150 = pings.filter(p => p.dist_m <= 150);
        const tag = truck === v.assigned_truck ? '★' : ' ';
        console.log(`  ${tag} ${truck.padEnd(10)} ${pings.length} pings in box (${within150.length} within 150m), min dist ${minDist}m`);
      }
    }
    console.log('');
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
