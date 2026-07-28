// ============================================================================
// geocode_missing_properties.js — fill latitude/longitude on properties that
// have a street address but no coords.
//
// Tiered source resolution (cheaper / more authoritative first):
//   1. Jobber GraphQL — client.billingAddress sometimes has geocoded coords
//   2. Samsara geofences — customer geofences have center coordinates
//   3. Google Maps Geocoding API — fallback for anything else
//   (the old Airtable tier was removed 2026-07-28; Airtable was retired 2026-07-24)
//
// Idempotent: only operates on properties WHERE latitude IS NULL. Safe to re-run.
//
// Logs the source ('jobber' | 'samsara' | 'google') per write
// so we can audit later.
//
// Usage:
//   node scripts/sync/geocode_missing_properties.js [--dry-run]
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const DRY_RUN = process.argv.includes('--dry-run');

// ⚠ FAIL-LOUD GUARD 1/2 (added 2026-07-28). Do not soften this to a warning.
// This job ran GREEN every Sunday for weeks while geocoding ZERO properties. `GOOGLE_API_KEY` was
// never added to the repo secrets, so Tier 3 (Google) returned null on its `if (!GOOGLE_API_KEY)`
// check, Tier 2 (Samsara) is an unconditional-null stub, Tier 1 (Jobber) resolves few — every
// property fell through to "no source resolved" and the script still exited 0. A green badge on a
// job that did nothing is worse than a red one, because nobody investigates a pass.
// Google is the only tier that resolves at scale (285/285 on the 2026-07-28 backfill), so running
// without the key is not a degraded run, it is a no-op wearing a success badge.
if (!process.env.GOOGLE_API_KEY) {
  console.error('FATAL: GOOGLE_API_KEY is not set. Google is the only tier that resolves at scale ' +
    '(Samsara is a stub, Jobber resolves few), so this run would report success while geocoding ' +
    'nothing — exactly the failure this guard exists to stop. Set the secret/env var and re-run.');
  process.exit(2);
}

function http(opts, body) {
  return new Promise((res, rej) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({
      ...opts,
      headers: { ...opts.headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) },
    }, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej);
    req.setTimeout(30000, () => req.destroy(new Error('timeout')));
    if (payload) req.write(payload);
    req.end();
  });
}

async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}

async function gqlJobber(query, variables) {
  const r = await http({
    hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: { Authorization: `Bearer ${process.env.JOBBER_ACCESS_TOKEN}`, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-13', 'Content-Type': 'application/json' }
  }, JSON.stringify({ query, variables }));
  return JSON.parse(r.body);
}

// ---- Tier 1: Jobber -----
async function tryJobber(prop, jobberClientGid) {
  if (!jobberClientGid) return null;
  const j = await gqlJobber(`
    query Q($id: EncodedId!) {
      client(id: $id) {
        billingAddress { street city province postalCode coordinates { latitude longitude } }
        properties(first: 5) { nodes { address { street city province postalCode coordinates { latitude longitude } } } }
      }
    }
  `, { id: jobberClientGid });
  if (j.errors) return null;
  const cands = [];
  if (j.data?.client?.billingAddress?.coordinates) cands.push({ ...j.data.client.billingAddress, src: 'billing' });
  for (const p of j.data?.client?.properties?.nodes || []) {
    if (p.address?.coordinates) cands.push({ ...p.address, src: 'property' });
  }
  // Pick the candidate whose street matches our DB address best
  const target = (prop.address || '').toLowerCase();
  const match = cands.find(c => target && c.street && target.includes(c.street.toLowerCase().split(' ').slice(0, 2).join(' ')));
  const winner = match || cands[0];
  if (!winner?.coordinates?.latitude) return null;
  return { lat: winner.coordinates.latitude, lng: winner.coordinates.longitude, source: 'jobber' };
}

// ---- Tier 2: Airtable Clients table — REMOVED 2026-07-28 -----
// Airtable was fully retired 2026-07-24 (CLAUDE.md rule 4: never read it). This tier queried
// api.airtable.com for a Yan-curated lat/lng and, on any failure, did `if (r.status !== 200) return null`
// — i.e. it degraded to "this property has no Airtable coordinates" rather than "Airtable is gone."
// That is indistinguishable from a real miss, so the tier silently contributed nothing while still
// appearing in the tier chain and in the per-write `source` log. Deleted rather than left to fail
// quietly: a tier that can never succeed is worse than no tier, because it reads as "checked."
//
// Nothing else changes. The chain is now Jobber -> Samsara -> Google (tiers 1, 3, 4). Properties that
// used to resolve from Airtable now fall through to Samsara/Google, which is where they would have
// landed anyway since the retirement. ADR 013 (tiered-property-geocoding) describes the 4-tier design;
// the Airtable tier there is now historical.
// Do NOT re-add an Airtable tier.

// ---- Tier 3: Samsara geofences -----
async function trySamsara(prop) {
  // Samsara geofences are queried by name; we'd match against the property
  // address. Since geofence names are arbitrary, this rarely works without
  // pre-mapping. Skip in this pass — flag for future work.
  return null;
}

// ---- Tier 4: Google Maps Geocoding API -----
async function tryGoogle(prop) {
  if (!process.env.GOOGLE_API_KEY) return null;
  const fullAddress = [prop.address, prop.city, prop.state, prop.zip, 'USA']
    .filter(Boolean).join(', ');
  if (!fullAddress) return null;
  const url = `/maps/api/geocode/json?address=${encodeURIComponent(fullAddress)}&key=${process.env.GOOGLE_API_KEY}`;
  const r = await http({ hostname: 'maps.googleapis.com', path: url, method: 'GET' });
  if (r.status !== 200) return null;
  const j = JSON.parse(r.body);
  if (j.status !== 'OK' || !j.results?.length) return null;
  const loc = j.results[0].geometry?.location;
  if (!loc) return null;
  return { lat: loc.lat, lng: loc.lng, source: 'google' };
}

// ---- main -----
(async () => {
  console.log('='.repeat(60));
  console.log(`geocode_missing_properties.js  Mode: ${DRY_RUN ? 'DRY-RUN' : 'EXECUTE'}`);
  console.log('='.repeat(60));

  const targets = await pg(`
    SELECT p.id, p.address, p.city, p.state, p.zip, p.client_id,
      esl_c_jobber.source_id  AS jobber_client_gid
    FROM properties p
    LEFT JOIN entity_source_links esl_c_jobber
      ON esl_c_jobber.entity_type='client' AND esl_c_jobber.entity_id=p.client_id AND esl_c_jobber.source_system='jobber'
    WHERE p.latitude IS NULL
      AND p.address IS NOT NULL
    ORDER BY p.id;
  `);
  console.log(`\n${targets.length} properties need geocoding\n`);

  let stats = { jobber: 0, samsara: 0, google: 0, none: 0 };

  for (const prop of targets) {
    let result = null;
    if (!result) result = await tryJobber(prop, prop.jobber_client_gid).catch(() => null);
    // Tier 2 (Airtable) removed 2026-07-28 — see the note above the former tryAirtable().
    if (!result) result = await trySamsara(prop).catch(() => null);
    if (!result) result = await tryGoogle(prop).catch(() => null);

    if (result) {
      stats[result.source]++;
      console.log(`  ✓ ${prop.id} ${(prop.address || '').slice(0,30).padEnd(32)} → ${result.lat.toFixed(5)}, ${result.lng.toFixed(5)} [${result.source}]`);
      if (!DRY_RUN) {
        await pg(`UPDATE properties SET latitude=${result.lat}, longitude=${result.lng}, updated_at=now() WHERE id=${prop.id}`);
      }
    } else {
      stats.none++;
      console.log(`  ✗ ${prop.id} ${(prop.address || '').slice(0,30).padEnd(32)} — no source resolved`);
    }
    // Polite pacing
    await new Promise(r => setTimeout(r, 200));
  }

  console.log(`\n=== Summary ===`);
  console.log(`  Jobber:    ${stats.jobber}`);
  console.log(`  Samsara:   ${stats.samsara}`);
  console.log(`  Google:    ${stats.google}`);
  console.log(`  Unresolved: ${stats.none}`);
  console.log(`  Total:     ${targets.length}`);

  // ⚠ FAIL-LOUD GUARD 2/2 (added 2026-07-28). Catches the same false-pass from the other direction:
  // the key can be PRESENT but dead (revoked, quota exhausted, or IP/referrer-restricted so it works
  // locally and fails from GitHub's runners). In that case every tier returns null and we would again
  // exit 0 on a total no-op. Zero resolutions out of a non-empty worklist is never a legitimate
  // outcome — individual bad addresses fail, but not ALL of them — so it is an error, not a result.
  // Deliberately NOT a ratio/threshold: partial failures are normal (junk addresses exist) and a
  // threshold would need tuning and would drift. Total failure is unambiguous.
  if (targets.length > 0 && stats.none === targets.length) {
    console.error(`\nFATAL: resolved 0 of ${targets.length} properties. Every tier returned nothing, ` +
      'which means the geocoding path is broken (dead/restricted GOOGLE_API_KEY, quota, or network) ' +
      'rather than the addresses being bad. Failing instead of reporting a green no-op.');
    process.exit(2);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
