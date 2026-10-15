// samsara_visit_audit.mjs - READ-ONLY. For every completed customer visit in [from, to), take ONLY its date and its
// client/address from our database, then read SAMSARA for the visit's date window (visit date -4 h to 10 AM next day,
// ET) and record what Samsara shows: which trucks stopped at the address (trips ending at the client's Samsara place or
// within 250 m of our map point; re-parks under 15 min joined), idling there with the engine on (GPS points, no trip
// stop), and the closest approach. Beside it, what our database holds for the visit (truck, time on site, source).
// Fred, 2026-10-15: "we use the Visits data to get the date and the client, with that we cross reference in Samsara
// and check the GPS time and location". Nothing is written anywhere except the output file, which names clients:
// write it OUTSIDE the repos.
//   node scripts/checks/samsara_visit_audit.mjs <out.json> <from YYYY-MM-DD> <to YYYY-MM-DD>
import fs from 'node:fs';

const [, , outFile, from, to] = process.argv;
if (!outFile || !from || !to) { console.error('usage: <out.json> <from> <to>'); process.exit(1); }
const env = Object.fromEntries(fs.readFileSync(new URL('../../.env', import.meta.url), 'utf8').split(/\r?\n/)
  .filter((l) => /^[A-Z_]+=/.test(l)).map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).trim().replace(/^["']|["']$/g, '')]));
const SAM = { Authorization: `Bearer ${env.SAMSARA_API_TOKEN}`, Accept: 'application/json' };
const TRUCKS = { '281474998706262': 'Moises', '281474998706263': 'Cloggy', '281474998706264': 'David' };
const NEAR = 250, PLACE_NEAR = 150, MIN_STAY = 3 * 60e3, GPS_GAP = 5 * 60e3, STILL_MPH = 3;
// 2026-10-15 (audit critic, Fred: "Go ahead ... 10"): no re-park join (it merged neighbours' jobs into one stop; each
// Samsara stay is now its own stop and the caller picks the most likely one); a trip also counts when it ends within
// 150 m of a client place centre (Samsara may label it with an overlapping place); engine-on idling counts only while
// the truck is stationary (Samsara GPS speed <= 3 mph), so a drive-through is not a stop.
const sleep = (ms) => new Promise((s) => setTimeout(s, ms));
const R = 6371000, rad = (x) => x * Math.PI / 180;
const meters = (a, b, c, d) => { const x = rad(c - a), y = rad(d - b); const h = Math.sin(x / 2) ** 2 + Math.cos(rad(a)) * Math.cos(rad(c)) * Math.sin(y / 2) ** 2; return 2 * R * Math.asin(Math.sqrt(h)); };
const etMidnight = (d) => { const off = Number(new Date(Date.parse(d + 'T12:00:00Z')).toLocaleString('en-US', { timeZone: 'America/New_York', timeZoneName: 'shortOffset' }).match(/GMT([+-]\d+)/)[1]); return Date.parse(`${d}T00:00:00Z`) - off * 3600e3; };

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`,
    { method: 'POST', headers: { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ query: q }) });
  const j = await r.json();
  if (!Array.isArray(j)) throw new Error('sql: ' + JSON.stringify(j).slice(0, 300));
  return j;
}
async function sam(path) {
  for (let i = 0; ; i++) {
    const r = await fetch('https://api.samsara.com' + path, { headers: SAM });
    if (r.status === 429 && i < 5) { await sleep(2000 * (i + 1)); continue; }
    if (!r.ok) throw new Error(`samsara ${r.status} ${path.split('?')[0]}`);
    await sleep(120);
    return r.json();
  }
}

const visits = await sql(`
  select v.id, v.visit_date::text as date, c.client_code, c.name as client_name, v.client_id, v.property_id,
         v.completed_at, v.service_type, v.duration_minutes, v.actual_arrival_at, v.actual_departure_at, v.time_on_site_source,
         ve.name as truck, (select e.source_id from public.entity_source_links e where e.entity_type = 'vehicle' and e.source_system = 'samsara' and e.entity_id = v.vehicle_id limit 1) as truck_samsara_id,
         coalesce(p.latitude, cp.latitude) as lat, coalesce(p.longitude, cp.longitude) as lng, (p.id is null and cp.latitude is not null) as map_from_client,
         (select coalesce(jsonb_agg(distinct regexp_replace(e.source_id, '^addr_', '')), '[]') from public.entity_source_links e
           where e.source_system = 'samsara' and ((e.entity_type = 'property' and e.entity_id in (select id from public.properties x where x.client_id = v.client_id))
                                               or (e.entity_type = 'client' and e.entity_id = v.client_id))) as place_ids,
         exists (select 1 from public.manifest_visits mv join public.derm_manifests dm on dm.id = mv.manifest_id where mv.visit_id = v.id and dm.deleted_at is null) as derm_filed
    from public.visits v join public.clients c on c.id = v.client_id
    left join public.properties p on p.id = v.property_id
    left join public.vehicles ve on ve.id = v.vehicle_id
    left join lateral (select latitude, longitude from public.properties x where x.client_id = v.client_id and x.deleted_at is null
                        and (select count(*) from public.properties y where y.client_id = v.client_id and y.deleted_at is null) = 1 limit 1) cp on v.property_id is null
   where v.visit_status = 'completed' and v.deleted_at is null and v.visit_date >= '${from}' and v.visit_date < '${to}'
     and not public.fn_is_non_customer(v.client_id)
   order by v.visit_date, v.id`);

const places = new Map();
async function place(id) {
  if (!places.has(id)) {
    let p = null;
    try { const a = (await sam(`/addresses/${id}`)).data; p = { id: String(a.id), name: a.name, lat: a.geofence?.circle?.latitude ?? a.latitude, lng: a.geofence?.circle?.longitude ?? a.longitude }; } catch { p = null; }
    places.set(id, p);
  }
  return places.get(id);
}
const tripCache = new Map(), gpsCache = new Map();
async function trips(truck, date, w0, w1) {
  const k = truck + date;
  if (!tripCache.has(k)) tripCache.set(k, ((await sam(`/v1/fleet/trips?vehicleId=${truck}&startMs=${w0 - 12 * 3600e3}&endMs=${w1 + 12 * 3600e3}`)).trips ?? []).sort((a, b) => a.startMs - b.startMs));
  return tripCache.get(k);
}
async function gps(date, w0, w1) {
  if (!gpsCache.has(date)) {
    const out = {};
    let after = '';
    do {
      const j = await sam(`/fleet/vehicles/stats/history?types=gps&vehicleIds=${Object.keys(TRUCKS).join(',')}&startTime=${new Date(w0).toISOString()}&endTime=${new Date(w1).toISOString()}${after ? '&after=' + after : ''}`);
      for (const v of j.data ?? []) (out[v.id] ??= []).push(...(v.gps ?? []).map((q) => ({ t: Date.parse(q.time), lat: q.latitude, lng: q.longitude, mph: q.speedMilesPerHour ?? null })));
      after = j.pagination?.hasNextPage ? j.pagination.endCursor : '';
    } while (after);
    gpsCache.set(date, out);
  }
  return gpsCache.get(date);
}

const out = [];
let n = 0;
for (const v of visits) {
  const w0 = etMidnight(v.date) - 4 * 3600e3;
  const next = new Date(Date.parse(v.date + 'T12:00:00Z') + 86400e3).toISOString().slice(0, 10);
  const w1 = etMidnight(next) + 10 * 3600e3;
  const pls = (await Promise.all((v.place_ids ?? []).map(place))).filter(Boolean);
  const targets = [...(v.lat != null ? [{ kind: 'map', lat: v.lat, lng: v.lng }] : []), ...pls.map((p) => ({ kind: 'place', lat: p.lat, lng: p.lng, name: p.name, id: p.id }))];
  const stays = [];
  if (targets.length) {
    for (const [id, name] of Object.entries(TRUCKS)) {
      const ts = await trips(id, v.date, w0, w1);
      const here = [];
      for (let i = 0; i < ts.length - 1; i++) {
        const s0 = ts[i].endMs, s1 = ts[i + 1].startMs;
        if (s1 - s0 < MIN_STAY || s1 <= w0 || s0 >= w1) continue;
        const c = ts[i].endCoordinates ?? {};
        const placeHit = pls.find((p) => String(ts[i].endAddress?.id ?? '') === p.id)
          ?? (c.latitude != null ? pls.find((p) => meters(p.lat, p.lng, c.latitude, c.longitude) <= PLACE_NEAR) : undefined);
        const fromMap = v.lat != null && c.latitude != null ? meters(v.lat, v.lng, c.latitude, c.longitude) : null;
        if (placeHit || (fromMap != null && fromMap <= NEAR)) here.push({ s0, s1, fromMap: fromMap && Math.round(fromMap), samsaraPlace: ts[i].endAddress?.name ?? null, viaPlace: !!placeHit });
      }
      for (const h of here) stays.push({ truck: name, truck_samsara_id: id, parts: 1, source: 'trip', ...h });
    }
  }
  // GPS: idling there with the engine on (no trip stop), and the closest approach to our map point / the place
  let closest = null;
  const idles = [];
  if (targets.length) {
    const g = await gps(v.date, w0, w1);
    for (const [id, pts] of Object.entries(g)) {
      let cur = null;
      for (const q of pts.sort((a, b) => a.t - b.t)) {
        let nearT = null;
        for (const tg of targets) {
          const m = meters(tg.lat, tg.lng, q.lat, q.lng);
          if (!closest || m < closest.m) closest = { m: Math.round(m), t: new Date(q.t).toISOString(), truck: TRUCKS[id], to: tg.kind };
          if (m <= NEAR && !nearT) nearT = tg;
        }
        const still = q.mph == null || q.mph <= STILL_MPH;
        if (nearT && still) { if (cur && q.t - cur.s1 <= GPS_GAP) cur.s1 = q.t; else { if (cur) idles.push(cur); cur = { truck: TRUCKS[id], truck_samsara_id: id, s0: q.t, s1: q.t }; } }
        else if (cur && (!nearT || !still)) { idles.push(cur); cur = null; }
      }
      if (cur) idles.push(cur);
    }
  }
  const gpsDwells = idles.filter((d) => d.s1 - d.s0 >= MIN_STAY)
    .filter((d) => !stays.some((s) => s.truck_samsara_id === d.truck_samsara_id && d.s0 < s.s1 + 5 * 60e3 && d.s1 > s.s0 - 5 * 60e3))
    .map((d) => ({ ...d, source: 'gps_idle', parts: 1 }));
  const all = [...stays, ...gpsDwells].sort((a, b) => a.s0 - b.s0);
  const done = v.completed_at ? Date.parse(v.completed_at) : null;
  const iso = (t) => new Date(t).toISOString();
  out.push({
    visit_id: v.id, date: v.date, client_code: v.client_code, client_name: v.client_name, service: v.service_type,
    derm_filed: v.derm_filed, completed_at: v.completed_at,
    db: { truck: v.truck, truck_samsara_id: v.truck_samsara_id, duration_minutes: v.duration_minutes, arrival: v.actual_arrival_at,
          departure: v.actual_departure_at, source: v.time_on_site_source, property_id: v.property_id, map_from_client: v.map_from_client,
          has_map_point: v.lat != null, samsara_places: pls.map((p) => ({ id: p.id, name: p.name, from_map_m: v.lat != null ? Math.round(meters(v.lat, v.lng, p.lat, p.lng)) : null })) },
    samsara: {
      window: [iso(w0), iso(w1)],
      stops: all.map((s) => ({ truck: s.truck, source: s.source, arrived: iso(s.s0), departed: iso(s.s1), minutes: Math.round((s.s1 - s.s0) / 60e3),
                               parts: s.parts, via_place: !!s.viaPlace, from_map_m: s.fromMap ?? null, samsara_place: s.samsaraPlace ?? null,
                               holds_completion: done != null && done >= s.s0 - 5 * 60e3 && done <= s.s1 + 15 * 60e3 })),
      closest,
    },
  });
  if (++n % 25 === 0) process.stdout.write(`${n} `);
}
fs.writeFileSync(outFile, JSON.stringify({ from, to, generated_at: new Date().toISOString(), visits: out }, null, 1));
console.log(`\nwrote ${out.length} visits to ${outFile}`);
