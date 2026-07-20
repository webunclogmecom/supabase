// dump-visit-create — public QR endpoint for drivers to self-schedule a dump visit.
//
// FLOW: driver scans the QR on the truck -> Lovable "DUMP Schedule" page (holds NO secret)
//       -> POST here with {k, driver_id, dump} -> we create the visit as service_role
//       -> trg_push_visit_insert pushes it to Jobber automatically (we never call jobber-push-visit)
//       -> driver attaches the dump manifest photo to the Jobber visit note, as he already does.
//
// SECURITY MODEL (mirrors get-derm-doc): anon-callable, so THIS FUNCTION does its own authorization.
//   - verify_jwt = false  (the driver's phone has no JWT)
//   - the service_role key lives ONLY here, server-side; the page never sees it
//
// NO SHARED SECRET, ON PURPOSE (Fred 2026-07-16: "the idea is to be able to get there with the QR or
// without it"). The page must work from a bare URL — a bookmark, the crew chat, a typed address — not
// only from the QR. A secret that must live in a static public bundle to satisfy that is not a secret:
// it ships in the JS, anyone can read it, and it would buy a false sense of protection. So we don't
// pretend. What actually bounds this endpoint is STRUCTURAL, and it is much stronger than a leaked key:
//   1. the client is NEVER caller-supplied — `dump` is a key into a 2-entry server-side whitelist,
//      so the only rows creatable are on the two disposal sites (never a customer);
//   2. driver_id must match the server-side roster;
//   3. idempotency is (site + driver) over 90 min => the ENTIRE endpoint's ceiling is
//      4 drivers x 2 dumps = 8 visits per 90 minutes, no matter who calls it or how often;
//   4. every line item is $0, so nothing is billable;
//   5. anything junk is soft-deletable and the delete propagates back out to Jobber.
// A `k` in the body/URL is still ACCEPTED and IGNORED so existing QR links keep working unchanged.
//
// WHY NOT grant anon EXECUTE on create_calendar_visit: anon is WRITE-NONE by design, established
// twice (2026-07-11 phase3 visit-lifecycle lock revoked it from PUBLIC+anon in BOTH public.* and
// ops.*; 2026-07-12 anon_surface_harden closed the rest). create_calendar_visit already grants
// service_role, so this ships without touching the anon grant surface at all.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Server-side whitelist. Verified against Prod 2026-07-16. The caller sends only the KEY ('DH'|'DP').
// property_id is deliberately the is_primary row: both dumps carry a billing-address duplicate, and
// Pompano's billing dup (Oakland Park) is a genuinely different address ~4mi from the facility.
const DUMPS = {
  DH: {
    label: "Homestead", client_id: 365, job_id: 1720, property_id: 98,
    address: "8950 SW 232nd Street, Cutler Bay", lat: 25.5517444, lng: -80.3368324, county: "Miami-Dade",
  },
  DP: {
    label: "Pompano", client_id: 76, job_id: 1662, property_id: 155,
    address: "2401 N Powerline Road, Pompano Beach", lat: 26.2632563, lng: -80.1552085, county: "Broward",
  },
} as const;

// ⚠⚠ TEST MODE — THE ONE SWITCH. Fred 2026-07-16: "we're building this from the ground up, so every
// visit created is only for testing purposes and should be deleted until this is done for production.
// So do not put the visits on jobber yet."
//
//   false = the visit is created in the DB and SHOWS IN THE VISIT CALENDAR, but is kept OFF Jobber.
//   true  = production: the visit pushes to Jobber exactly as a Calendar-created visit does.
//
// Flipping this to `true` is the ENTIRE go-live step for the Jobber side. Do not flip it until Fred
// says the app is done — the crew works off the real Jobber schedule and test rows land on it.
// The suppression itself lives in public.create_dump_visit (see
// docs/migrations/2026-07-16_create_dump_visit_no_push.sql): it must close TWO paths, the AFTER
// INSERT trigger AND the */3 'resolve-stale-visit-sync-pending' cron, which would otherwise re-drive
// any 'pending' row to Jobber ~3 minutes later, silently.
const PUSH_TO_JOBBER = false;

const SERVICE_LINE_ITEM_DUMP = 22; // "22 - Service Call - Labor" — requires_derm=false (explicit false,
                                   // unlike a free-text 'DUMP' item which classifies to NULL/unknown).
// create_calendar_visit has NO dedupe; a double-tap would create two DB visits AND two Jobber visits.
// SCOPE IS (site + DRIVER), never site alone: two drivers legitimately hit the same dump within 90
// minutes on a normal night, and each needs HIS OWN visit to attach HIS OWN manifest photo to. Keying
// on the site alone would silently absorb the second driver into the first driver's visit and leave
// him nowhere to put his manifest — which is the entire reason this app exists.
const IDEMPOTENCY_MINUTES = 90;

// Drivers: ops.v_calendar_driver is NOT a driver list (it returns all 7 active employees incl.
// Fred/Yannick). Active Technicians auto-appear; DRIVER_EXTRA_IDS covers non-Technician roles who
// actually drive: Grecia=1, Aaron=26, Diego=28 (added 2026-07-17, Fred). Jeffrey was requested but
// there is no active employee by that name (only inactive "Jeffry" id 25) — skipped per Fred.
const DRIVER_EXTRA_IDS = [1, 26, 28];

// ---------------------------------------------------------------------------
// ETA to the dump (docs/09-eta-design.md, Fred 2026-07-18).
//
// The driver is never asked where he is: we resolve the truck he is on today (public.dump_driver_origin)
// and use its Samsara fix. Samsara reports every ~6 seconds while a truck is in use and falls back to
// hourly heartbeats when it is parked, so a fix is only trustworthy if it is RECENT - hence FRESH_MIN.
// When the fix is stale we tell the page to ask the phone ONCE (the browser remembers the grant) rather
// than route from a position we do not believe. A wrong ETA is worse than no ETA: it sends a driver
// somewhere on a number he trusted.
const FRESH_MIN = 10;              // minutes; a truck fix older than this is not usable as an origin
const ROUTES_TIMEOUT_MS = 2500;    // Google Routes budget; on timeout we degrade to no-ETA
const ETA_THROTTLE_MS = 20_000;    // per (driver, dump, source); best-effort only, see ETA_CACHE_TTL_MS

// The REAL repeat-tap guard. Measured 2026-07-18: the in-memory etaCache below is effectively dead in
// production (edge instances do not share or persist memory), so tapping one dump 6 times cost 6 Routes
// calls instead of 1. These TTLs drive a Postgres-backed cache keyed by (dump, origin cell, routing
// mode), which survives instances AND is shared between drivers sitting at the same yard. A hit costs
// neither money nor a daily-cap token. See docs/migrations/2026-07-18b_dump_eta_cache_traffic_mode.sql.
//
// Origin is rounded to 2dp (~1.1 km). On a 40-minute haul that is worth about a minute of error, and it
// buys a large hit-rate increase: a whole crew leaving the same yard shares one answer, and a moving
// truck still re-routes every cell it crosses.
const ETA_CACHE_TTL_TRAFFIC_MS = 5 * 60_000;   // traffic-aware answers go stale faster
const ETA_CACHE_TTL_FREE_MS = 15 * 60_000;     // overnight free-flow barely moves

// COST LEVER (Fred 2026-07-18: "is there a way to minimize the costs knowing what we need to do?").
// TRAFFIC_AWARE is what bills at Google's Pro SKU ($10/1k, 5,000 free/month); TRAFFIC_UNAWARE bills at
// Essentials ($5/1k, 10,000 free/month). Half the price and double the free tier.
//
// The dump runs are OVERNIGHT commercial routes (~8 PM to ~6 AM ET), and at those hours traffic-aware
// routing tells us nothing free-flow routing does not. So we pay for traffic only when traffic exists:
// congested hours get TRAFFIC_AWARE, the overnight window gets TRAFFIC_UNAWARE. Daytime accuracy is
// preserved for the daytime truck (Cloggy) without paying Pro rates all night for identical answers.
const TRAFFIC_HOURS_START_ET = 6;   // inclusive
const TRAFFIC_HOURS_END_ET = 20;    // exclusive
function trafficMattersNow(): boolean {
  const h = Number(new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York", hour: "numeric", hour12: false,
  }).format(new Date()));
  return h >= TRAFFIC_HOURS_START_ET && h < TRAFFIC_HOURS_END_ET;
}

// HARD DAILY SPEND CAP (Fred 2026-07-19: raised from $2 to "$5 cap per day").
//
// Sized against the EXPENSIVE rate on purpose. A call costs $0.01 at the Pro SKU (traffic-aware, 06:00
// to 20:00 ET) and $0.005 at Essentials (traffic-free overnight), so the same call count can be worth
// two different amounts. Sizing on Pro is the only way the dollar ceiling holds no matter when the calls
// land: 500 x $0.01 = $5.00 worst case, and $2.50 if the day happens to be all overnight.
//
// Measured real usage is ~8 calls on a full night (the Postgres cache collapses a crew's tapping into
// roughly one call per dump per location per TTL), so this sits ~60x above normal traffic. It bounds a
// runaway bug; it does not ration drivers.
// Enforced in Postgres (public.dump_eta_take_token), NOT in memory: edge instances do not share state,
// so an in-process counter would bound each instance rather than the total. See
// docs/migrations/2026-07-18_dump_eta_daily_cap.sql.
const ROUTES_DAILY_CAP = 500;

// Best-effort, per edge instance. At ~8 dumps/day this is a runaway guard, not a correctness mechanism,
// so a cold start losing the map is harmless.
const etaCache = new Map<string, { at: number; payload: Record<string, unknown> }>();

type Origin = {
  lat: number;
  lng: number;
  source: "truck" | "phone";
  gps_age_min: number | null;
  truck: string | null;
};

// Resolves the driver's current truck fix, or null when there is nothing fresh enough to trust.
async function truckOrigin(driverId: number): Promise<Origin | null> {
  const { data, error } = await db.rpc("dump_driver_origin", { p_driver_id: driverId });
  if (error) { console.error("[dump] origin rpc failed:", error.message); return null; }
  const r = Array.isArray(data) ? data[0] : data;
  if (!r || r.latitude == null || r.longitude == null) return null;
  const age = Number(r.minutes_ago);
  if (!Number.isFinite(age) || age > FRESH_MIN) {
    console.log(`[dump] truck fix too stale for driver ${driverId} (${age} min) - phone fallback`);
    return null;
  }
  return {
    lat: Number(r.latitude),
    lng: Number(r.longitude),
    source: "truck",
    gps_age_min: Math.round(age),
    truck: r.vehicle_name ?? null,
  };
}

// Receiving-hours verdict for an arrival instant (public.dump_site_status, Slack 2026-07-17).
// Returns null only if the lookup itself fails, in which case the page shows NO banner rather than a
// wrong one: telling a driver a site is open when it is shut sends him on a 40-mile round trip.
async function siteStatus(dumpKey: string, arrivalIso: string): Promise<
  { status: string; arrival_et: string | null; last_intake_at: string | null; after_hours_phone: string | null } | null
> {
  const { data, error } = await db.rpc("dump_site_status", { p_dump_key: dumpKey, p_arrival: arrivalIso });
  if (error) { console.error("[dump] site status failed:", error.message); return null; }
  const r = Array.isArray(data) ? data[0] : data;
  if (!r?.status) return null;
  return {
    status: r.status,
    arrival_et: r.arrival_et ?? null,
    last_intake_at: r.last_intake_at ?? null,
    after_hours_phone: r.after_hours_phone ?? null,
  };
}

// A caller-supplied coordinate is the ONLY caller-controlled input to the routing call, so bound it.
function validCoord(lat: unknown, lng: unknown): boolean {
  const a = Number(lat), b = Number(lng);
  return Number.isFinite(a) && Number.isFinite(b) &&
         Math.abs(a) <= 90 && Math.abs(b) <= 180 && !(a === 0 && b === 0);
}

// Traffic-aware ETA from the Google Routes API v2. Server-side only: the key never reaches the phone, so
// it can be locked to the Routes API in Google Cloud and cannot be scraped out of the page bundle.
//
// Returns null on ANY failure (missing key, HTTP error, timeout, unparseable duration). That is
// deliberate and load-bearing: the page renders NO ETA line when this is null. A driver acts on this
// number, so the only acceptable failure mode is silence, never a guess.
async function computeEta(
  o: Origin,
  d: typeof DUMPS[keyof typeof DUMPS],
): Promise<{ eta_minutes: number; arrival_at: string; distance_mi: number | null } | null> {
  const key = Deno.env.get("GOOGLE_MAPS_API_KEY") ?? "";
  if (!key) { console.warn("[dump] GOOGLE_MAPS_API_KEY missing - ETA disabled"); return null; }

  // Shared cache first: a hit costs neither money nor a daily-cap token, which is what makes idle
  // browsing free. Rounding to 3dp (~110m) lets repeat taps AND different drivers at the same yard reuse
  // one answer, while a truck that has actually driven off lands in a new cell and gets a fresh ETA.
  const trafficAware = trafficMattersNow();
  const latR = Number(o.lat.toFixed(2));
  const lngR = Number(o.lng.toFixed(2));
  const ttlMs = trafficAware ? ETA_CACHE_TTL_TRAFFIC_MS : ETA_CACHE_TTL_FREE_MS;
  const freshSince = new Date(Date.now() - ttlMs).toISOString();
  const { data: hit, error: cacheErr } = await db
    .from("dump_eta_cache")
    .select("eta_minutes, distance_mi, computed_at")
    .eq("dump_key", d.label)
    .eq("lat_r", latR)
    .eq("lng_r", lngR)
    .eq("traffic_aware", trafficAware)
    .gte("computed_at", freshSince)
    .maybeSingle();
  if (cacheErr) console.error("[dump] eta cache read failed (continuing):", cacheErr.message);
  if (hit) {
    // Re-derive arrival from NOW, not from when it was computed: the drive still takes eta_minutes from
    // this moment, and showing a stale arrival clock would be quietly wrong.
    const mins = Number(hit.eta_minutes);
    console.log(`[dump] eta cache hit for ${d.label} @${latR},${lngR} - no Routes call`);
    return {
      eta_minutes: mins,
      arrival_at: new Date(Date.now() + mins * 60_000).toISOString(),
      distance_mi: hit.distance_mi === null ? null : Number(hit.distance_mi),
    };
  }

  // Take a token from the shared daily budget BEFORE spending money. Counting attempts rather than
  // successes is the deliberate direction for a spend guard. Cache hits never get here, so a
  // re-render costs neither a call nor a token.
  //
  // FAIL CLOSED: if the counter itself errors we do NOT route. The whole point of this is that the cap
  // cannot be bypassed, and the failure mode is benign - the page simply shows no ETA line.
  const { data: token, error: capErr } = await db.rpc("dump_eta_take_token", { p_cap: ROUTES_DAILY_CAP });
  if (capErr) {
    console.error("[dump] daily-cap check failed, refusing to route:", capErr.message);
    return null;
  }
  if (token === null || token === undefined) {
    console.warn(`[dump] daily Routes cap of ${ROUTES_DAILY_CAP} reached - serving no ETA until ET midnight`);
    return null;
  }

  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), ROUTES_TIMEOUT_MS);
  try {
    const res = await fetch("https://routes.googleapis.com/directions/v2:computeRoutes", {
      method: "POST",
      signal: ctl.signal,
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": key,
        // The field mask is what keeps this in the cheap tier. Do not widen it casually.
        "X-Goog-FieldMask": "routes.duration,routes.distanceMeters",
      },
      body: JSON.stringify({
        origin: { location: { latLng: { latitude: o.lat, longitude: o.lng } } },
        destination: { location: { latLng: { latitude: d.lat, longitude: d.lng } } },
        travelMode: "DRIVE",
        routingPreference: trafficAware ? "TRAFFIC_AWARE" : "TRAFFIC_UNAWARE",
        // departureTime is deliberately OMITTED. Routes defaults it to request time, which is exactly
        // what we want, and sending our own "now" fails: by the time Google evaluates the request the
        // timestamp is already in the past and it rejects with
        // 400 INVALID_ARGUMENT "Timestamp must be set to a future time." (hit 2026-07-18).
        // Do not "helpfully" add it back.
      }),
    });
    if (!res.ok) {
      console.error(`[dump] routes http ${res.status}:`, (await res.text()).slice(0, 200));
      return null;
    }
    const j = await res.json();
    const route = j?.routes?.[0];
    if (!route?.duration) return null;
    const secs = Number(String(route.duration).replace(/s$/, ""));
    if (!Number.isFinite(secs) || secs <= 0) return null;
    const meters = Number(route.distanceMeters ?? 0);
    const result = {
      eta_minutes: Math.max(1, Math.round(secs / 60)),
      arrival_at: new Date(Date.now() + secs * 1000).toISOString(),
      distance_mi: meters > 0 ? Math.round((meters / 1609.34) * 10) / 10 : null,
    };

    // Populate the shared cache so the next tap of this dump from this spot is free. Upsert on the
    // (dump, cell) key: a newer answer simply replaces the older one. A write failure is logged and
    // ignored - it only means the next tap pays again, never that the driver loses his ETA.
    const { error: putErr } = await db.from("dump_eta_cache").upsert({
      dump_key: d.label,
      lat_r: latR,
      lng_r: lngR,
      traffic_aware: trafficAware,
      eta_minutes: result.eta_minutes,
      distance_mi: result.distance_mi,
      computed_at: new Date().toISOString(),
    }, { onConflict: "dump_key,lat_r,lng_r,traffic_aware" });
    if (putErr) console.error("[dump] eta cache write failed (non-fatal):", putErr.message);

    return result;
  } catch (e) {
    console.error("[dump] routes failed:", e instanceof Error ? e.message : String(e));
    return null;
  } finally {
    clearTimeout(timer);
  }
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// x-app-source is what the audit trail attributes the write to. audit.log_change() reads
// `request.headers ->> 'x-app-source'` (ADR 016) and falls back to 'sql' when it is absent — which is
// why every DUMP-created visit showed as "System created this visit" in the Calendar's Activity tab
// (Fred, 2026-07-16). Every other app already stamps itself: 'visit-calendar', 'derm-tracker',
// 'admin-review'. Ours is 'dump-schedule'. Set it on the client so EVERY PostgREST call from this
// function carries it — the RPC and the dedupe read alike.
const db = createClient(SUPABASE_URL, SERVICE_KEY, {
  global: { headers: { "x-app-source": "dump-schedule" } },
});

const etDate = () =>
  new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/New_York", year: "numeric", month: "2-digit", day: "2-digit",
  }).format(new Date()); // YYYY-MM-DD in ET — matches what trg_aa_reconcile_operating_date will derive.

const mapsUrl = (d: { lat: number; lng: number }) =>
  `https://www.google.com/maps/dir/?api=1&destination=${d.lat},${d.lng}`;

async function drivers() {
  const { data, error } = await db
    .from("employees")
    .select("id, full_name, role, color_hex") // color_hex = canonical per-driver identity colour (employees.color_hex)
    .eq("status", "ACTIVE")
    .or(`role.eq.Technician,id.in.(${DRIVER_EXTRA_IDS.join(",")})`)
    .order("full_name");
  if (error) throw new Error(`drivers: ${error.message}`);
  return data ?? [];
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ ok: false, error: "bad json" }, 400); }

  // `k` is accepted and ignored (see the security note at the top): the page must work from a bare
  // URL, so there is deliberately no shared secret. The endpoint is bounded structurally instead.
  const action = String(body.action ?? "create");

  try {
    // The page calls this on load to render its pickers (anon can't read employees itself).
    if (action === "bootstrap") {
      return json({
        ok: true,
        drivers: await drivers(),
        // maps_url added 2026-07-17 for the redesign's "View Addresses" screen (drive to a dump
        // without creating a visit). Same server-side lat/lng the create receipt uses — the page
        // never composes a maps link from a caller-supplied address.
        dumps: Object.entries(DUMPS).map(([k, d]) => ({
          key: k, label: d.label, address: d.address, county: d.county, maps_url: mapsUrl(d),
        })),
      });
    }

    // "route" — TODAY'S CLIENT STOPS for the DUMP app's "View Addresses" screen (Fred 2026-07-17:
    // "the Addresses of the Clients for that day/shift ... excluding the Dump Places (000 clients)").
    // Reads the SECURITY DEFINER public.dump_route_today() (service_role-only), which selects today's
    // ET-dated, non-000, soft-delete-safe visits from ops.v_calendar_visit. The DRIVE THERE link is
    // composed SERVER-SIDE from lat/lng (byte-identical to the happy path) — falling back to the full
    // address only when geo is missing. The address string is display-only; ", USA" geocoder cruft is
    // trimmed for legibility.
    if (action === "route") {
      const { data, error } = await db.rpc("dump_route_today");
      if (error) throw new Error(`route: ${error.message}`);
      const stops = ((data ?? []) as Array<Record<string, unknown>>).map((r) => {
        const lat = r.latitude as number | null, lng = r.longitude as number | null;
        const dest = (lat != null && lng != null)
          ? `${lat},${lng}`
          : encodeURIComponent([r.address, r.city, r.state, r.zip].filter(Boolean).join(", "));
        const street = String(r.address ?? "").split(/,\s*USA/i)[0].trim();
        // GDO permit # for the DERM address manifest. Only a real Miami-Dade permit (GDO-#### ) is
        // surfaced — Broward stops are null, and the literal "Not available" data quirk is dropped —
        // so the app shows the line only when there is a genuine permit to copy onto the manifest.
        const gdoRaw = String(r.gdo_number ?? "").trim();
        const gdo = /^GDO-\d+$/.test(gdoRaw) ? gdoRaw : null;
        return {
          code: r.client_code, name: r.client_name, status: r.visit_status,
          start_at: r.start_at, is_all_day: r.is_all_day,
          address: street, city: r.city, county: r.county, gdo,
          truck: r.truck_name, driver: r.driver_name, service: r.service_label,
          maps_url: `https://www.google.com/maps/dir/?api=1&destination=${dest}`,
        };
      });
      return json({ ok: true, date: etDate(), count: stops.length, stops });
    }

    // ETA to a dump. Returns one of:
    //   { ok, eta_minutes, arrival_at, distance_mi, source, gps_age_min, truck, dump, dump_key }
    //   { ok, need_client_location: true }   -> page asks the phone ONCE, then re-calls with coords
    // eta_minutes is null (never fabricated) whenever routing is unavailable.
    if (action === "eta") {
      const etaDumpKey = String(body.dump ?? "") as keyof typeof DUMPS;
      const etaDump = DUMPS[etaDumpKey];
      if (!etaDump) return json({ ok: false, error: "pick a dump" }, 400);

      const etaDriverId = Number(body.driver_id);
      if (!etaDriverId) return json({ ok: false, error: "pick who you are" }, 400);

      let origin: Origin | null;
      if (body.client_lat != null || body.client_lng != null) {
        if (!validCoord(body.client_lat, body.client_lng)) {
          return json({ ok: false, error: "bad coords" }, 400);
        }
        origin = {
          lat: Number(body.client_lat), lng: Number(body.client_lng),
          source: "phone", gps_age_min: null, truck: null,
        };
      } else {
        origin = await truckOrigin(etaDriverId);
        if (!origin) return json({ ok: true, need_client_location: true });
      }

      const throttleKey = `${etaDriverId}:${etaDumpKey}:${origin.source}`;
      const cached = etaCache.get(throttleKey);
      if (cached && Date.now() - cached.at < ETA_THROTTLE_MS) {
        return json({ ...cached.payload, cached: true });
      }

      const routed = await computeEta(origin, etaDump);
      const payload = {
        ok: true,
        eta_minutes: routed?.eta_minutes ?? null,
        arrival_at: routed?.arrival_at ?? null,
        distance_mi: routed?.distance_mi ?? null,
        source: origin.source,
        gps_age_min: origin.gps_age_min,
        truck: origin.truck,
        dump: etaDump.label,
        dump_key: etaDumpKey,
      };
      etaCache.set(throttleKey, { at: Date.now(), payload });
      return json(payload);
    }

    // Both dumps in ONE request. The page needs both to let the driver compare, and doing it as two
    // requests meant resolving the same origin twice and paying two round trips on a phone network.
    // Origin is resolved once here, then the two routes run in parallel (each still cache-checked and
    // cap-gated individually, so cost behaviour is identical to two separate calls).
    if (action === "etas") {
      const etaDriverId = Number(body.driver_id);
      if (!etaDriverId) return json({ ok: false, error: "pick who you are" }, 400);

      let origin: Origin | null;
      if (body.client_lat != null || body.client_lng != null) {
        if (!validCoord(body.client_lat, body.client_lng)) {
          return json({ ok: false, error: "bad coords" }, 400);
        }
        origin = {
          lat: Number(body.client_lat), lng: Number(body.client_lng),
          source: "phone", gps_age_min: null, truck: null,
        };
      } else {
        origin = await truckOrigin(etaDriverId);
        if (!origin) return json({ ok: true, need_client_location: true });
      }

      const keys = Object.keys(DUMPS) as (keyof typeof DUMPS)[];
      const routed = await Promise.all(keys.map((k) => computeEta(origin!, DUMPS[k])));
      // Hours verdict for the ARRIVAL time, not now. When there is no ETA we still answer for now, so a
      // driver on a closed Saturday is told Pompano is shut even if routing failed.
      const statuses = await Promise.all(keys.map((k, i) => {
        const mins = routed[i]?.eta_minutes;
        const arrival = new Date(Date.now() + (typeof mins === "number" ? mins : 0) * 60_000).toISOString();
        return siteStatus(k, arrival);
      }));
      const etas: Record<string, unknown> = {};
      keys.forEach((k, i) => {
        etas[k] = {
          eta_minutes: routed[i]?.eta_minutes ?? null,
          arrival_at: routed[i]?.arrival_at ?? null,
          distance_mi: routed[i]?.distance_mi ?? null,
          dump: DUMPS[k].label,
          site_status: statuses[i]?.status ?? null,
          after_hours_phone: statuses[i]?.after_hours_phone ?? null,
          last_intake_at: statuses[i]?.last_intake_at ?? null,
        };
      });
      return json({
        ok: true, etas,
        source: origin.source, gps_age_min: origin.gps_age_min, truck: origin.truck,
      });
    }

    // The manifest crib sheet (Yan, Slack 2026-07-17: "ask the app for the list", "ONLY give the visits
    // to add to manifest ONCE"). Returns the two buckets and records the hand-out.
    // ⚠ This writes NO DERM table. The driver fills the paper sheet at the dump; see
    // docs/migrations/2026-07-20_dump_manifest_handout.sql for why that is structural, not stylistic.
    if (action === "manifest") {
      const mDriverId = Number(body.driver_id);
      if (!mDriverId) return json({ ok: false, error: "pick who you are" }, 400);
      const mDumpVisitId = Number(body.dump_visit_id);
      if (!mDumpVisitId) return json({ ok: false, error: "missing dump visit" }, 400);

      const { data, error } = await db.rpc("dump_manifest_handout_list", {
        p_driver_id: mDriverId,
        p_dump_visit_id: mDumpVisitId,
      });
      if (error) {
        // Fail LOUD, never as an empty list. A blank crib sheet and a broken request look identical to a
        // driver at 2 AM, and he would skip real DERM paperwork believing there was nothing to report.
        console.error("[dump] manifest list failed:", error.message);
        return json({ ok: false, error: "could not load the manifest list" }, 500);
      }
      const rows = (Array.isArray(data) ? data : []) as Record<string, unknown>[];
      return json({
        ok: true,
        load: rows.filter((r) => r.bucket === "load"),
        outstanding: rows.filter((r) => r.bucket === "outstanding"),
        count: rows.length,
      });
    }

    if (action !== "create") return json({ ok: false, error: "unknown action" }, 400);

    const dumpKey = String(body.dump ?? "") as keyof typeof DUMPS;
    const dump = DUMPS[dumpKey];
    if (!dump) return json({ ok: false, error: "pick a dump" }, 400);

    const driverId = Number(body.driver_id);
    if (!driverId) return json({ ok: false, error: "pick who you are" }, 400);

    const allowed = await drivers();
    const driver = allowed.find((d) => d.id === driverId);
    if (!driver) return json({ ok: false, error: "unknown driver" }, 400);

    // IDEMPOTENCY — THIS driver double-tapping must not create a second Jobber visit. Scoped to
    // (site + driver): a different driver heading to the same dump gets his own visit (see above).
    const since = new Date(Date.now() - IDEMPOTENCY_MINUTES * 60_000).toISOString();
    const { data: dupes, error: dupeErr } = await db
      .from("visits")
      .select("id, public_id, start_at, assigned_driver_id")
      .eq("client_id", dump.client_id)
      .eq("assigned_driver_id", driverId)
      .eq("visit_status", "scheduled")
      .is("deleted_at", null)
      .gte("start_at", since)
      .order("start_at", { ascending: false })
      .limit(1);
    if (dupeErr) throw new Error(`dupe check: ${dupeErr.message}`);

    if (dupes?.length) {
      const v = dupes[0];
      console.log(`[dump] idempotent hit — returning ${driver.full_name}'s existing visit ${v.id} for ${dumpKey}`);
      return json({
        ok: true, already: true, visit_id: v.id, public_id: v.public_id, driver: driver.full_name,
        dump_key: dumpKey, dump: dump.label, county: dump.county,
        address: dump.address, start_at: v.start_at, maps_url: mapsUrl(dump),
      });
    }

    // What the driver actually saw, recorded verbatim on the visit so the office can see the expected
    // arrival (docs/09-eta-design.md section 9). Display text ONLY: it is never parsed or trusted, so it
    // is flattened and clamped before it goes anywhere near the note. This is a snapshot at log time,
    // deliberately not a live field.
    const etaRaw = typeof body.eta_snapshot === "string" ? body.eta_snapshot : "";
    const etaNote = etaRaw.replace(/[\r\n]+/g, " ").trim().slice(0, 160);

    // Fred 2026-07-20: the hours warning WARNS, never blocks, but the outcome is recorded so the office
    // can see he arrived outside receiving hours. Display text only, flattened and clamped like the ETA.
    const hoursRaw = typeof body.site_status_note === "string" ? body.site_status_note : "";
    const hoursNote = hoursRaw.replace(/[\r\n]+/g, " ").trim().slice(0, 80);

    const startAt = new Date();
    const endAt = new Date(startAt.getTime() + 60 * 60_000);

    // create_dump_visit wraps the ONE sanctioned visit-creating path (create_calendar_visit) and adds
    // the Jobber kill-switch. It keeps all of that RPC's validation and its line_items/visit_team/
    // visit_locations children; when PUSH_TO_JOBBER is false it additionally suppresses the insert
    // push and flips the row to source='manual' + sync_state='confirmed' so neither the trigger nor
    // the */3 retry cron can send it to Jobber. The visit still shows in the Visit Calendar.
    const { data: visit, error } = await db.rpc("create_dump_visit", {
      p_client_id: dump.client_id,
      p_job_id: dump.job_id,
      p_service_line_item_ids: [SERVICE_LINE_ITEM_DUMP],
      p_visit_date: etDate(),           // advisory — the BEFORE trigger re-derives it from start_at in ET
      p_property_id: dump.property_id,
      p_start_at: startAt.toISOString(),
      p_end_at: endAt.toISOString(),
      p_title: "Dump",                  // trg_prefix_visit_title prepends "000-DH Homestead Dump - "
      p_notes: `Dump run — ${driver.full_name} (via truck QR). Attach the dump manifest photo here.` +
               (etaNote ? ` ${etaNote}` : "") +
               (hoursNote ? ` ${hoursNote}` : ""),
      p_driver_id: driverId,
      p_team_ids: [driverId],
      p_push_to_jobber: PUSH_TO_JOBBER,
    });

    if (error) {
      // e.g. job archived => "create_calendar_visit: job X is not an active job for client Y".
      console.error(`[dump] create failed for ${dumpKey}:`, error.message);
      return json({ ok: false, error: "could not create the visit", detail: error.message }, 500);
    }

    const v = Array.isArray(visit) ? visit[0] : visit;
    console.log(`[dump] created visit ${v?.id} ${dumpKey} driver=${driver.full_name} — trigger will push to Jobber`);

    // Every field the receipt renders is echoed here ON PURPOSE — dump_key (drives the wrong-dump
    // identity colour), county, label, address, driver, time. The page must render the receipt from
    // THIS body, never from what the thumb tapped: if the server disagrees with his tap, he has to
    // SEE it rather than drive 45mi to the wrong county behind a confidently-wrong link.
    return json({
      ok: true, already: false, visit_id: v?.id, public_id: v?.public_id, driver: driver.full_name,
      dump_key: dumpKey, dump: dump.label, county: dump.county,
      address: dump.address, start_at: v?.start_at, maps_url: mapsUrl(dump),
    });
  } catch (e) {
    console.error("[dump] FATAL:", e instanceof Error ? e.message : String(e));
    return json({ ok: false, error: "server error" }, 500);
  }
});
