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
    jobberClientId: "102873636", // gid://Jobber/Client/102873636 -> secure.getjobber.com/clients/102873636
  },
  DP: {
    label: "Pompano", client_id: 76, job_id: 1662, property_id: 155,
    address: "2401 N Powerline Road, Pompano Beach", lat: 26.2632563, lng: -80.1552085, county: "Broward",
    jobberClientId: "104148029", // gid://Jobber/Client/104148029 -> secure.getjobber.com/clients/104148029
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

const SERVICE_LINE_ITEM_DUMP = 28; // "28 - Disposal - Dump Offload" (service_line_items code 28 = row id 28).
                                   // requires_derm=false, service_type NULL, so a dump visit never becomes
                                   // DERM-required and never classifies as GT. Changed from 22 "Service Call
                                   // - Labor" on 2026-07-22 (Fred): a dump is not a client service, it is us
                                   // disposing of collected grease. The 22 historical dump visits were
                                   // backfilled onto code 28 the same day (Jobber for source='jobber' visits,
                                   // direct DB update for the 3 source='visit-calendar' ones handleVisit does
                                   // not resync). Verified: create_calendar_visit does NOT require the line
                                   // item to be schedulable, only active (code 28 is active), and it names the
                                   // line item from service_line_items.title, so this yields exactly
                                   // "28 - Disposal - Dump Offload".
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
// The truck verdict from public.dump_resolve_truck. `vehicle_id` is NULL unless we are CONFIDENT:
// 'gps' / 'gps+calendar' / 'calendar' carry a truck; 'conflict' and 'none' deliberately carry none.
type TruckResolution = {
  vehicle_id: number | null;
  vehicle_name: string | null;
  confidence: string;
  candidates: Record<string, unknown> | null;
};

// Which truck is this driver in, right now? Accurate-or-silent by design (Fred 2026-07-27): it returns NO
// truck rather than a guess, because a wrong truck in #dump-visits is worse than no truck, and vehicle_id
// is an AUDITED business column. Full tier model + the measured hit rates live in the migration header
// docs/migrations/2026-07-27_dump_truck_resolution.sql. Never throws — a resolver failure must not stop a
// driver logging his dump.
async function resolveTruck(driverId: number, lat: unknown, lng: unknown): Promise<TruckResolution | null> {
  try {
    const useCoords = validCoord(lat, lng);
    const { data, error } = await db.rpc("dump_resolve_truck", {
      p_driver_id: driverId,
      p_lat: useCoords ? Number(lat) : null,
      p_lng: useCoords ? Number(lng) : null,
    });
    if (error) { console.error("[dump] truck resolve failed:", error.message); return null; }
    const r = Array.isArray(data) ? data[0] : data;
    if (!r) return null;
    return {
      vehicle_id: (r.vehicle_id as number) ?? null,
      vehicle_name: (r.vehicle_name as string) ?? null,
      confidence: (r.confidence as string) ?? "none",
      candidates: (r.candidates as Record<string, unknown>) ?? null,
    };
  } catch (e) {
    console.error("[dump] truck resolve threw:", e instanceof Error ? e.message : String(e));
    return null;
  }
}

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

// The dump client's page in Jobber (office opens it to attach the manifest). Repo-standard pattern:
// secure.getjobber.com/clients/<numericClientId> (numeric decodes from the entity_source_links GID).
const jobberClientUrl = (d: { jobberClientId: string }) =>
  `https://secure.getjobber.com/clients/${d.jobberClientId}`;

// A small "context" block carrying the Google-Maps directions as a labeled "Route Link" (Fred 2026-07-24:
// the title links to Jobber; the maps link stays but as a separate, clearly-labeled route link). Empty
// array when there is no known dump site, so the caller can spread it unconditionally.
const routeContext = (routeLink: string | null) =>
  routeLink ? [{ type: "context", elements: [{ type: "mrkdwn", text: `🧭 <${routeLink}|Route Link>` }] }] : [];

// ---------------------------------------------------------------------------
// Slack alerts to #dump-visits (Fred 2026-07-22; split + enriched 2026-07-23). Three kinds:
//   1. postDumpCreatedAlert  — fires on `create` (GO): the dump EVENT, so a dump ALWAYS notifies.
//   2. postDumpAlert         — fires on `manifest_confirm`: the ticked load + what's still MISSING
//      (this driver's DERM-required load visits this shift that he did NOT tick).
//   3. postManifestLinkAlert — fires on `link`: OLDER VISITS catch-up-linked to a chosen dump.
// The dump title links to the dump CLIENT in Jobber (000-DH/000-DP), where the office attaches the
// manifest; the Google-Maps directions ride along as a separate labeled "Route Link" context line.
// Best-effort: a Slack failure NEVER fails the driver's action. No-op (logs) when the webhook is unset.
// ---------------------------------------------------------------------------
async function dumpMeta(dumpVisitId: number) {
  const { data: v } = await db.from("visits")
    .select("start_at, client_id, vehicle_id, assigned_driver_id, notes").eq("id", dumpVisitId).maybeSingle();
  // A dump created in the app's TESTING MODE carries a [TEST] marker in its notes; every alert for it is
  // prefixed [TEST] so it's obvious in #dump-visits (Fred 2026-07-24).
  const isTest = ((v?.notes as string) || "").includes("[TEST]");
  const isDH = v?.client_id === DUMPS.DH.client_id;
  const isDP = v?.client_id === DUMPS.DP.client_id;
  const site = isDH ? DUMPS.DH.label : isDP ? DUMPS.DP.label : "Dump";
  const county = isDH ? DUMPS.DH.county : isDP ? DUMPS.DP.county : "";
  const routeLink = isDH ? mapsUrl(DUMPS.DH) : isDP ? mapsUrl(DUMPS.DP) : null;         // Google Maps -> "Route Link"
  const jobberUrl = isDH ? jobberClientUrl(DUMPS.DH) : isDP ? jobberClientUrl(DUMPS.DP) : null; // dump client in Jobber
  const title = `Dump at ${site}${county ? ` (${county})` : ""}`;
  const titleMd = jobberUrl ? `<${jobberUrl}|${title}>` : title;   // Slack mrkdwn link -> the dump client in Jobber
  const whenET = v?.start_at
    ? new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", weekday: "short",
        month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }).format(new Date(v.start_at as string)) + " ET"
    : "—";
  let truck = "";
  if (v?.vehicle_id) {
    const { data: veh } = await db.from("vehicles").select("name").eq("id", v.vehicle_id).maybeSingle();
    truck = (veh?.name as string) ?? "";
  }
  const { data: teamRows } = await db.from("visit_team").select("employee_id").eq("visit_id", dumpVisitId);
  const empIds = (teamRows ?? []).map((r: Record<string, unknown>) => r.employee_id as number);
  let teamNames: string[] = [];
  if (empIds.length) {
    const { data: emps } = await db.from("employees").select("full_name").in("id", empIds);
    teamNames = (emps ?? []).map((e: Record<string, unknown>) => e.full_name as string).filter(Boolean);
  }
  return { site, county, routeLink, jobberUrl, title, titleMd, whenET, truck, teamNames, isTest, dumpDriverId: (v?.assigned_driver_id as number) ?? null };
}

const clientBullets = (rows: { client_code?: string; client_name?: string }[]) =>
  rows.map((c) => `• ${(c.client_code ?? "").trim()} ${(c.client_name ?? "").trim()}`.trim()).join("\n");

// Posts to #dump-visits and RETURNS the message ts when it can (null otherwise).
//
// TWO TRANSPORTS, on purpose (Fred 2026-07-27 — "build it token-ready"):
//   * chat.postMessage (preferred) — used when SLACK_BOT_TOKEN + SLACK_DUMP_CHANNEL_ID are set. This is the
//     ONLY transport that returns a message `ts` and accepts `thread_ts`, which is what lets the follow-up
//     alerts (load reported / manifest add) render as REPLIES under the dump they belong to instead of as
//     four unrelated top-level posts.
//   * Incoming Webhook (fallback) — the original transport. A webhook responds with the literal body "ok",
//     never a ts, and ignores thread_ts, so threading is IMPOSSIBLE on this path. It stays as the fallback
//     so that if the bot token is missing, or the bot has not been invited to the PRIVATE #dump-visits yet,
//     alerts keep firing exactly as they do today rather than going silent.
// Returns null on every failure. Callers treat a null ts as "post top-level", never as an error.
async function slackPost(text: string, blocks: unknown[], threadTs?: string | null, broadcast = false): Promise<string | null> {
  const token = Deno.env.get("SLACK_BOT_TOKEN");
  const channel = Deno.env.get("SLACK_DUMP_CHANNEL_ID");
  // unfurl_links/media false: keep Slack from expanding the maps/Jobber URLs into a raw-URL preview box.
  const common = { text, blocks, unfurl_links: false, unfurl_media: false };

  if (token && channel) {
    try {
      const res = await fetch("https://slack.com/api/chat.postMessage", {
        method: "POST",
        headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${token}` },
        body: JSON.stringify({
          channel, ...common,
          ...(threadTs ? { thread_ts: threadTs } : {}),
          // reply_broadcast is opt-in per alert, NOT blanket: broadcasting every reply would push them all
          // back into the channel and defeat the point of threading. Meaningless without thread_ts, so it
          // is gated on both.
          // ⚠ As of 2026-08-04 NO caller passes broadcast=true. The CONFIRM alert used to, and Fred asked
          // for it to stop ("only gets send as a thread message and not on the channel also"). The
          // parameter is kept so a future alert can opt in deliberately, but adding it back to the confirm
          // alert re-creates the "Also sent to the channel" duplicate he asked to remove.
          ...(threadTs && broadcast ? { reply_broadcast: true } : {}),
        }),
      });
      const j = await res.json().catch(() => null);
      if (j?.ok) return (j.ts as string) ?? null;
      // ⚠ ONLY fall through to the webhook when Slack DEFINITIVELY refused (a parsed body saying ok:false —
      // not_in_channel / channel_not_found, i.e. the bot was never invited to the private channel, and
      // nothing was posted). If the body could not be parsed we do NOT know whether Slack committed the
      // message, and re-sending it on the other transport would DOUBLE-POST — worst of all on the parent
      // create alert, where the copy that actually got a ts is the one we failed to read, so every
      // follow-up for that dump would then be orphaned. Losing one alert to a rare transport fault beats
      // duplicating it; this is the same "silence over a wrong answer" rule the ETA path already follows.
      if (j === null) {
        console.error(`[dump] chat.postMessage response unreadable (http ${res.status}) — NOT retrying on the webhook (may already have posted)`);
        return null;
      }
      console.error(`[dump] chat.postMessage refused (${j.error ?? "unknown"}) — falling back to webhook`);
    } catch (e) {
      // The request may have been fully transmitted and committed before the connection died. Same rule:
      // do not risk a duplicate.
      console.error("[dump] chat.postMessage threw — NOT retrying on the webhook (may already have posted):", e instanceof Error ? e.message : String(e));
      return null;
    }
  }

  const url = Deno.env.get("SLACK_DUMP_WEBHOOK_URL");
  if (!url) { console.log("[dump] no SLACK_BOT_TOKEN and no SLACK_DUMP_WEBHOOK_URL — skipping #dump-visits alert"); return null; }
  const res = await fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(common) });
  if (!res.ok) console.error(`[dump] slack webhook ${res.status}: ${(await res.text()).slice(0, 200)}`);
  return null; // an Incoming Webhook never returns a usable message id
}

// The parent "dump created" message, so follow-ups can thread under it. Stored as an append row in the
// existing jsonb dump_activity.detail — NO DDL, and public.dump_test_cleanup() already deletes
// dump_activity by dump_visit_id, so a [TEST] dump still leaves 0 residue.
async function saveParentTs(dumpVisitId: number, ts: string, channel: string) {
  try {
    await db.from("dump_activity").insert({
      action: "slack_parent", dump_visit_id: dumpVisitId, detail: { slack_ts: ts, slack_channel: channel },
    });
  } catch (e) { console.error("[dump] could not store slack parent ts:", e instanceof Error ? e.message : String(e)); }
}

async function getParentTs(dumpVisitId: number): Promise<string | null> {
  try {
    const { data } = await db.from("dump_activity")
      .select("detail").eq("dump_visit_id", dumpVisitId).eq("action", "slack_parent")
      .order("at", { ascending: false }).limit(1).maybeSingle();
    const ts = (data?.detail as Record<string, unknown> | null)?.slack_ts;
    return typeof ts === "string" ? ts : null;
  } catch (_e) { return null; }  // no parent = post top-level, never an error
}

// A compact "this is an update to that dump" header for the FOLLOW-UP alerts. The parent message carries
// the big title + Time/Truck/Team block; repeating all of that on every follow-up is exactly what made four
// posts read as four unrelated events. Inside a thread this is the right density; outside one (no bot
// token, or a parent that failed to post) it is the graceful degradation.
const updateContext = (m: { titleMd: string; whenET: string }, driverName: string) =>
  [{ type: "context", elements: [{ type: "mrkdwn", text: `↳ Update to *${m.titleMd}* · ${driverName} · ${m.whenET}` }] }];

// 1. DUMP CREATED — fires on GO. The dump event; always notifies. Carries two extra signals
// (Fred 2026-07-24):
//   * the driver's LOAD count this shift — an EMPTY load reads as an explicit "no completed DERM pickups
//     to report" line instead of a silently-missing Reported/Missing (which had looked like a bug).
//   * for an after-hours (Homestead post-intake) dump, whether the driver tapped CALL before going.
async function postDumpCreatedAlert(
  dumpVisitId: number,
  driverName: string,
  driverId: number | null,
  opts?: { afterHours?: boolean; calledAhead?: boolean; truck?: TruckResolution | null },
) {
  const m = await dumpMeta(dumpVisitId);
  const tag = m.isTest ? "[TEST] " : "";
  const team = (m.teamNames.length ? m.teamNames : [driverName]).join(", ");

  // TRUCK (Fred 2026-07-27). Always render a Truck line now, because a SILENTLY MISSING field reads as a
  // broken alert while an explicit "not identified" reads as a known gap (same reasoning as the empty-load
  // line below). m.truck is the truck actually stamped on the visit; the resolver's verdict explains why
  // there isn't one. A 'conflict' deliberately stamps nothing and shows BOTH candidates so a human can
  // resolve what is usually a real operational signal (an unrecorded shift-swap, or a wrong Calendar truck).
  let truckLine: string;
  if (m.truck) {
    truckLine = `*Truck:* ${m.truck}`;
  } else if (opts?.truck?.confidence === "conflict") {
    const g = opts.truck.candidates?.gps_vehicle_name ?? "?";
    const c = opts.truck.candidates?.cal_vehicle_name ?? "?";
    truckLine = `*Truck:* ⚠️ unconfirmed — GPS says ${g}, Calendar says ${c}`;
  } else {
    truckLine = `*Truck:* not identified`;
  }
  const fields = [`*Time:* ${m.whenET}`, truckLine, team ? `*Team:* ${team}` : null].filter(Boolean).join("\n");

  // Load = this driver's completed, DERM-required, still-undocumented visits this shift (bucket='load').
  // dump_manifest_handout_list is STABLE (read-only), so counting here records nothing. -1 = couldn't tell.
  let loadCount = -1;
  if (driverId) {
    try {
      const { data } = await db.rpc("dump_manifest_handout_list", { p_driver_id: driverId, p_dump_visit_id: dumpVisitId });
      loadCount = (Array.isArray(data) ? data : []).filter((r: Record<string, unknown>) => r.bucket === "load").length;
    } catch (_e) { /* leave -1 — omit the line rather than guess */ }
  }
  const extra: string[] = [];
  if (opts?.afterHours) extra.push(`📞 *Called ahead:* ${opts.calledAhead ? "✅ yes" : "❌ no (went without calling)"}`);
  if (loadCount === 0) extra.push(`🫙 *No completed DERM pickups to report on this load* — no visits for this driver this shift.`);
  else if (loadCount > 0) extra.push(`📋 *${loadCount}* completed DERM pickup${loadCount === 1 ? "" : "s"} to report on this load.`);

  const blocks: unknown[] = [
    { type: "section", text: { type: "mrkdwn", text: `🚛 ${tag}*${m.titleMd}* — ${driverName} is dumping` } },
    { type: "section", text: { type: "mrkdwn", text: fields } },
  ];
  if (extra.length) blocks.push({ type: "section", text: { type: "mrkdwn", text: extra.join("\n") } });
  blocks.push(...routeContext(m.routeLink));
  // This is the PARENT message of the dump run. Keep its ts so the follow-ups can thread under it.
  const ts = await slackPost(`🚛 ${tag}${m.title} — ${driverName} (dumping)`, blocks);
  const channel = Deno.env.get("SLACK_DUMP_CHANNEL_ID");
  if (ts && channel) await saveParentTs(dumpVisitId, ts, channel);
}

// 2. LOAD REPORTED — fires on CONFIRM. The ticked load + what's still missing.
async function postDumpAlert(
  dumpVisitId: number,
  driverName: string,
  confirmed: { visit_id: number; client_code: string; client_name: string }[],
  driverId: number,
) {
  const m = await dumpMeta(dumpVisitId);
  const tag = m.isTest ? "[TEST] " : "";
  const clientLines = confirmed.length ? clientBullets(confirmed) : "_(no clients marked on this load)_";

  // MISSING = this driver's DERM-required load visits this shift he did NOT tick (bucket='load',
  // confirmed=false). dump_outstanding_visits is DERM-filtered, so non-DERM (unclog) never appears here.
  let missing: { client_code?: string; client_name?: string }[] = [];
  try {
    const { data: list } = await db.rpc("dump_manifest_handout_list", { p_driver_id: driverId, p_dump_visit_id: dumpVisitId });
    missing = (Array.isArray(list) ? list : []).filter((r: Record<string, unknown>) => r.bucket === "load" && r.confirmed === false) as { client_code?: string; client_name?: string }[];
  } catch (_e) { /* best-effort — no missing line rather than a failed alert */ }

  // FOLLOW-UP FORMAT (Fred 2026-07-27): no repeated big title, no repeated Time/Truck/Team block, no
  // repeated Route Link — the parent message already carries all of that. Just a one-line "update to that
  // dump" context + the payload. Threads under the parent when a bot token is configured.
  const blocks: unknown[] = [
    ...updateContext(m, driverName),
    { type: "section", text: { type: "mrkdwn", text: `📋 ${tag}*Reported on this load (${confirmed.length}):*\n${clientLines}` } },
  ];
  if (missing.length) blocks.push({ type: "section", text: { type: "mrkdwn", text: `⚠️ *Missing — scheduled today, not added (${missing.length}):*\n${clientBullets(missing)}` } });
  // THREAD-ONLY (Fred 2026-08-04): "can we change it so the updates only gets send as a thread message
  // and not on the channel also?". This used to pass broadcast=true, which added reply_broadcast and made
  // Slack render the "Also sent to the channel" copy on top of the threaded reply. The load report now
  // lives ONLY under its parent dump. Do not re-add the 4th argument here.
  await slackPost(`📋 ${tag}${m.title} — ${driverName} reported ${confirmed.length} on this load`, blocks, await getParentTs(dumpVisitId));
}

// 3. MANIFEST LINK — fires on `link`. OLDER VISITS catch-up-linked to a chosen dump.
async function postManifestLinkAlert(driverName: string, dumpVisitId: number, linked: { client_code?: string; client_name?: string }[]) {
  if (!linked.length) return;
  const m = await dumpMeta(dumpVisitId);
  let dumpDriver = "";
  if (m.dumpDriverId) {
    const { data: e } = await db.from("employees").select("full_name").eq("id", m.dumpDriverId).maybeSingle();
    dumpDriver = (e?.full_name as string) ?? "";
  }
  const tag = m.isTest ? "[TEST] " : "";
  // Threads under the dump it was filed against — which matters MOST here, because the pick-a-dump list
  // spans 7 days, so this follow-up routinely belongs to a dump from days ago. Time-proximity correlation
  // would be flat wrong; a thread reply is exactly right.
  await slackPost(`📝 ${tag}${driverName} added ${linked.length} to the ${m.site} dump`, [
    ...updateContext(m, dumpDriver || driverName),
    { type: "section", text: { type: "mrkdwn", text: `📝 ${tag}*${driverName} added ${linked.length} to the manifest*` } },
    { type: "section", text: { type: "mrkdwn", text: clientBullets(linked) } },
  ], await getParentTs(dumpVisitId));
}

// 4. MANIFEST UNLINK — fires on `unmark` (Fred 2026-07-24). The mirror of #3: a driver UNSELECTED visits
// from the shared "on a manifest" list in VIEW ADDRESSES. Removals were silent before, which read as the
// app dropping the change. `count` is the number of marks actually cleared; `rows` names them when known.
// Not dump-specific (the shared mark carries no dump), so no Route Link.
async function postManifestUnlinkAlert(driverName: string, count: number, rows: { client_code?: string; client_name?: string }[], isTest: boolean) {
  if (count <= 0) return;
  const tag = isTest ? "[TEST] " : "";
  const bullets = rows.length ? clientBullets(rows) : "_(marks cleared)_";
  await slackPost(`🗑 ${tag}${driverName} removed ${count} from the manifest`, [
    { type: "section", text: { type: "mrkdwn", text: `🗑 ${tag}*${driverName} removed ${count} from the manifest*` } },
    { type: "section", text: { type: "mrkdwn", text: bullets } },
  ]);
}

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

  // Passive device fingerprint (Fred 2026-07-22): identify the phone without a login and feed the
  // dump_activity trail. device_token is the localStorage id the app sends; IP + user-agent are read
  // SERVER-SIDE from the request; screen/timezone/platform are client-reported. All best-effort/nullable.
  const xff = req.headers.get("x-forwarded-for") ?? "";
  const sig = {
    token: typeof body.device_token === "string" ? body.device_token : null,
    ip: (xff.split(",")[0]?.trim() || req.headers.get("cf-connecting-ip") || null),
    ua: req.headers.get("user-agent"),
    screen: typeof body.screen === "string" ? body.screen : null,
    tz: typeof body.timezone === "string" ? body.timezone : null,
    platform: typeof body.platform === "string" ? body.platform : null,
  };
  // Append-only trail write. Best-effort: a logging failure must NEVER fail the driver's action.
  const logActivity = async (act: string, driverId: number | null, dumpVisitId: number | null, detail?: unknown) => {
    try {
      await db.from("dump_activity").insert({
        action: act, driver_id: driverId, device_token: sig.token, dump_visit_id: dumpVisitId,
        ip: sig.ip, user_agent: sig.ua, screen: sig.screen, timezone: sig.tz, platform: sig.platform,
        detail: detail ?? null,
      });
    } catch (e) { console.error("[dump] activity log failed:", e instanceof Error ? e.message : String(e)); }
  };

  try {
    // Who is this phone? (Fred 2026-07-22) Read-only device->driver lookup for zero-login identify.
    if (action === "identify") {
      if (!sig.token) return json({ ok: true, driver: null });
      const { data, error } = await db.rpc("dump_device_identify", { p_device_token: sig.token });
      if (error) { console.error("[dump] identify failed:", error.message); return json({ ok: true, driver: null }); }
      const row = (Array.isArray(data) && data[0]) ? data[0] as Record<string, unknown> : null;
      await logActivity("identify", (row?.driver_id as number) ?? null, null);
      return json({ ok: true, driver: row ? { id: row.driver_id, full_name: row.full_name, switch_count: row.switch_count } : null });
    }

    // Bind / switch this phone to a driver (Fred 2026-07-22). First pick binds; picking a DIFFERENT name
    // is a switch, recorded old->new in the trail so a wrong first pick is always visible + reattributable.
    if (action === "bind") {
      const bDriverId = Number(body.driver_id);
      if (!sig.token) return json({ ok: false, error: "missing device" }, 400);
      if (!bDriverId) return json({ ok: false, error: "pick who you are" }, 400);
      if (!(await drivers()).find((d) => d.id === bDriverId)) return json({ ok: false, error: "unknown driver" }, 400);
      const { data, error } = await db.rpc("dump_device_bind", {
        p_device_token: sig.token, p_driver_id: bDriverId,
        p_ip: sig.ip, p_user_agent: sig.ua, p_screen: sig.screen, p_timezone: sig.tz, p_platform: sig.platform,
      });
      if (error) { console.error("[dump] bind failed:", error.message); return json({ ok: false, error: "could not register this phone" }, 500); }
      const row = (Array.isArray(data) && data[0]) ? data[0] as Record<string, unknown> : null;
      return json({ ok: true, driver: row ? { id: row.driver_id, full_name: row.full_name } : null, switched: (row?.was_switch as boolean) ?? false });
    }

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
          // Manifest selectability (Fred 2026-07-24): only a COMPLETED, DERM, undocumented stop is
          // pickable (same gate as {mark}/{link}); scheduled stops render read-only. on_sheet/marked_by
          // carry the shared dump_manifest_handout mark so TODAY'S VISITS and OLDER VISITS agree.
          visit_id: r.visit_id, pickable: r.pickable === true,
          on_sheet: r.on_sheet === true, marked_by: r.marked_by ?? null,
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

    // OLDER VISITS: the read-only browse list behind VIEW ADDRESSES (Fred 2026-07-20). Deliberately does
    // NOT call dump_manifest_handout_list, because that RECORDS a hand-out: merely looking at the list
    // from the menu would burn a visit's single hand-out with no dump attached, hiding it from the driver
    // who actually dumps it. Browsing must never consume the hand-out.
    if (action === "outstanding") {
      const { data, error } = await db
        .from("dump_outstanding_visits")
        .select("visit_id, client_code, client_name, address, city, visit_date, completed_at, age_days, truck, gdo_number, needs_office, on_sheet, marked_by, marked_at, county, county_bucket, confirmed_hidden")
        .order("completed_at", { ascending: false, nullsFirst: false });
      if (error) {
        // Loud, never an empty list: "nothing outstanding" and "the request broke" must not look alike.
        console.error("[dump] outstanding list failed:", error.message);
        return json({ ok: false, error: "could not load the older visits" }, 500);
      }
      const all = Array.isArray(data) ? data : [];
      // 6h CONFIRMED-HIDE (Fred 2026-07-28): a row that has been marked for more than 6 hours drops out of
      // the default browse list. `include_confirmed` brings them back — that toggle is NOT optional
      // polish: un-ticking is reachable ONLY from this screen (dump_manifest_mark(on:false)), and
      // dump_manifest_handout_release can never clear an addresses-sourced mark because those rows carry
      // dump_visit_id = NULL. Without a way back, one wrong tap would be permanently unfixable in-app, for
      // every driver at once (the ledger PK is visit_id alone).
      const includeConfirmed = body.include_confirmed === true;
      const rows = includeConfirmed ? all : all.filter((r: Record<string, unknown>) => r.confirmed_hidden !== true);
      const hiddenConfirmed = all.length - rows.length;
      return json({ ok: true, stops: rows, count: rows.length, hidden_confirmed: hiddenConfirmed, total: all.length });
    }

    // VIEW ADDRESSES per-visit toggle (Fred 2026-07-23): the shared "on a manifest" mark. The driver
    // ticks a visit while browsing; it saves immediately and shows on the dump checklist too. This is the
    // per-visit MASTER toggle (can unmark any mark). Explicit tap only — browsing records nothing. NO
    // Slack alert (that belongs to the dump CONFIRM). driver_id is the remembered driver from the app.
    if (action === "mark") {
      const mkDriverId = Number(body.driver_id);
      const mkVisitId = Number(body.visit_id);
      const mkOn = body.on === true || body.on === "true" || body.on === 1;
      if (!mkDriverId) return json({ ok: false, error: "pick who you are" }, 400);
      if (!mkVisitId) return json({ ok: false, error: "missing visit" }, 400);
      if (!(await drivers()).find((d) => d.id === mkDriverId)) return json({ ok: false, error: "unknown driver" }, 400);

      const { data, error } = await db.rpc("dump_manifest_mark", {
        p_driver_id: mkDriverId, p_visit_id: mkVisitId, p_on: mkOn,
      });
      if (error) {
        console.error("[dump] mark failed:", error.message);
        return json({ ok: false, error: "could not update the mark" }, 500);
      }
      await logActivity("mark", mkDriverId, null, { visit_id: mkVisitId, on: mkOn });
      return json({ ok: true, on_sheet: data === true });
    }

    // VIEW ADDRESSES batch UNSELECT (Fred 2026-07-24): the driver unchecked visits and committed. Clears
    // the shared "on a manifest" mark for each AND posts ONE "removed from the manifest" Slack alert — the
    // mirror of `link`, which was the only side that notified. Per-visit `mark` on:false still exists for a
    // single toggle, but a batch removal routes here so Slack gets one alert, not one per card.
    if (action === "unmark") {
      const uDriverId = Number(body.driver_id);
      if (!uDriverId) return json({ ok: false, error: "pick who you are" }, 400);
      const uVisitIds = Array.isArray(body.visit_ids)
        ? (body.visit_ids as unknown[]).map(Number).filter((n) => Number.isFinite(n) && n > 0)
        : [];
      if (!uVisitIds.length) return json({ ok: false, error: "no visits to remove" }, 400);
      const uDriverName = (await drivers()).find((d) => d.id === uDriverId)?.full_name;
      if (!uDriverName) return json({ ok: false, error: "unknown driver" }, 400);

      // Names first — read BEFORE the delete so the alert can name each removed client. (Unmarking keeps
      // the visit outstanding, so it usually still lists, but reading first is the safe order.)
      const { data: infoRows } = await db
        .from("dump_outstanding_visits")
        .select("visit_id, client_code, client_name")
        .in("visit_id", uVisitIds);
      const removedInfo = (Array.isArray(infoRows) ? infoRows : []) as { client_code?: string; client_name?: string }[];

      let removed = 0;
      for (const vid of uVisitIds) {
        const { error } = await db.rpc("dump_manifest_mark", { p_driver_id: uDriverId, p_visit_id: vid, p_on: false });
        if (error) { console.error(`[dump] unmark ${vid} failed:`, error.message); continue; }
        removed++;
      }
      if (!removed) return json({ ok: false, error: "could not remove the marks" }, 500);

      await logActivity("unmark", uDriverId, null, { visit_ids: uVisitIds, removed });
      const uIsTest = body.test_mode === true;
      try { await postManifestUnlinkAlert(uDriverName, removed, removedInfo, uIsTest); }
      catch (e) { console.error("[dump] slack unlink alert failed:", e instanceof Error ? e.message : String(e)); }
      return json({ ok: true, removed });
    }

    // The manifest crib sheet (Yan, Slack 2026-07-17: "ask the app for the list", "ONLY give the visits
    // to add to manifest ONCE"). READ-ONLY as of 2026-07-22 (Fred): viewing records NOTHING — the driver
    // ticks a checklist and calls `manifest_confirm` to record only the chosen visits. Each row carries a
    // `confirmed` flag so the UI can pre-check what was already confirmed on this dump.
    // ⚠ Writes NO DERM table. The driver fills the paper sheet at the dump.
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

      // COUNTY GATE REPORTING (Fred 2026-07-28). The RPC has already removed the out-of-county rows for
      // this dump SITE (Homestead may only be handed Miami-Dade work; Pompano takes both). Fred's call was
      // to HIDE them, not grey them out — but a shortfall must still be STATED, because this app's own
      // rule is that a blank list and a broken request must never look alike, and the grease is physically
      // on the truck either way. So we count what the gate removed and let the UI say
      // "N hidden — file at Pompano" instead of silently showing a shorter list.
      let hiddenCounty = 0;
      let hiddenLabel: string | null = null;
      try {
        const { data: siteRow } = await db.from("visits").select("client_id").eq("id", mDumpVisitId).maybeSingle();
        const siteClient = (siteRow?.client_id as number) ?? null;
        if (siteClient === DUMPS.DH.client_id) {          // only Homestead can hide anything today
          const { data: allRows } = await db.from("dump_outstanding_visits").select("county_bucket");
          hiddenCounty = (Array.isArray(allRows) ? allRows : [])
            .filter((r: Record<string, unknown>) => r.county_bucket === "BROWARD").length;
          if (hiddenCounty > 0) hiddenLabel = `${hiddenCounty} Broward visit${hiddenCounty === 1 ? "" : "s"} hidden — file at ${DUMPS.DP.label}`;
        }
      } catch (_e) { /* best-effort: a missing count must never fail the crib sheet */ }

      return json({
        ok: true,
        hidden_county: hiddenCounty,
        hidden_county_label: hiddenLabel,
        load: rows.filter((r) => r.bucket === "load"),
        outstanding: rows.filter((r) => r.bucket === "outstanding"),
        count: rows.length,
      });
    }

    // Driver CONFIRMS the crib-sheet checklist (Fred 2026-07-22): records ONLY the ticked visits as
    // handed out for this dump, then posts the #dump-visits Slack alert with the real load. The confirm
    // RPC is set-semantics — re-confirming with a changed selection both adds and removes.
    if (action === "manifest_confirm") {
      const cDriverId = Number(body.driver_id);
      const cDumpVisitId = Number(body.dump_visit_id);
      if (!cDriverId) return json({ ok: false, error: "pick who you are" }, 400);
      if (!cDumpVisitId) return json({ ok: false, error: "missing dump visit" }, 400);
      const visitIds = Array.isArray(body.visit_ids)
        ? (body.visit_ids as unknown[]).map(Number).filter((n) => Number.isFinite(n) && n > 0)
        : [];

      const { data: confirmed, error } = await db.rpc("dump_manifest_handout_confirm", {
        p_driver_id: cDriverId, p_dump_visit_id: cDumpVisitId, p_visit_ids: visitIds,
      });
      if (error) {
        console.error("[dump] manifest confirm failed:", error.message);
        return json({ ok: false, error: "could not confirm the manifest list" }, 500);
      }
      const rows = (Array.isArray(confirmed) ? confirmed : []) as { visit_id: number; client_code: string; client_name: string }[];

      const driverName = (await drivers()).find((d) => d.id === cDriverId)?.full_name ?? "Driver";
      await logActivity("confirm", cDriverId, cDumpVisitId, { count: rows.length });
      try { await postDumpAlert(cDumpVisitId, driverName, rows, cDriverId); }
      catch (e) { console.error("[dump] slack alert failed:", e instanceof Error ? e.message : String(e)); }

      return json({ ok: true, confirmed: rows, count: rows.length });
    }

    // Driver (or office) UNDOES a wrong tick (Fred 2026-07-22): removes the given visits' hand-outs on
    // this dump. Omitting visit_ids releases ALL of this dump's hand-outs.
    if (action === "manifest_release") {
      const rDumpVisitId = Number(body.dump_visit_id);
      if (!rDumpVisitId) return json({ ok: false, error: "missing dump visit" }, 400);
      const relIds = Array.isArray(body.visit_ids)
        ? (body.visit_ids as unknown[]).map(Number).filter((n) => Number.isFinite(n) && n > 0)
        : null;
      const { data: released, error } = await db.rpc("dump_manifest_handout_release", {
        p_dump_visit_id: rDumpVisitId, p_visit_ids: relIds,
      });
      if (error) {
        console.error("[dump] manifest release failed:", error.message);
        return json({ ok: false, error: "could not release the manifest hand-out" }, 500);
      }
      await logActivity("release", null, rDumpVisitId, { released: released ?? 0 });
      return json({ ok: true, released: released ?? 0 });
    }

    // Pick-a-dump list (Fred 2026-07-23): when the driver documents OLDER VISITS he picks WHICH recent
    // dump they were dumped on. Returns the live dumps (000-DH / 000-DP) of the last 7 days, HIS OWN
    // pinned first (is_yours), each with site/county/when/driver + how many clients are already on it.
    // READ-ONLY. driver_id is optional (only used to pin the driver's own dumps first).
    if (action === "recent_dumps") {
      const rdDriverId = Number(body.driver_id) || null;
      const sinceIso = new Date(Date.now() - 7 * 24 * 3600_000).toISOString();
      const { data: vs, error } = await db
        .from("visits")
        .select("id, client_id, assigned_driver_id, start_at, created_at")
        .in("client_id", [365, 76])
        .is("deleted_at", null)
        .gte("start_at", sinceIso)
        .order("start_at", { ascending: false })
        .limit(30);
      if (error) {
        console.error("[dump] recent_dumps failed:", error.message);
        return json({ ok: false, error: "could not load the recent dumps" }, 500);
      }
      const dumps = (Array.isArray(vs) ? vs : []) as Record<string, unknown>[];
      const dumpIds = dumps.map((d) => d.id as number);
      const driverIds = [...new Set(dumps.map((d) => d.assigned_driver_id as number).filter(Boolean))];

      // one round-trip each for the driver names and the on-manifest counts
      const nameById = new Map<number, string>();
      if (driverIds.length) {
        const { data: emps } = await db.from("employees").select("id, full_name").in("id", driverIds);
        for (const e of emps ?? []) nameById.set(e.id as number, (e.full_name as string) ?? "");
      }
      const countByDump = new Map<number, number>();
      if (dumpIds.length) {
        const { data: hs } = await db.from("dump_manifest_handout").select("dump_visit_id").in("dump_visit_id", dumpIds);
        for (const h of hs ?? []) {
          const k = h.dump_visit_id as number;
          countByDump.set(k, (countByDump.get(k) ?? 0) + 1);
        }
      }

      const fmt = (iso: string | null) => iso
        ? new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", weekday: "short",
            month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }).format(new Date(iso)) + " ET"
        : "—";
      const out = dumps.map((d) => {
        const isDH = d.client_id === DUMPS.DH.client_id;
        const drvId = (d.assigned_driver_id as number) ?? null;
        return {
          dump_visit_id: d.id as number,
          dump_key: isDH ? "DH" : "DP",
          site: isDH ? DUMPS.DH.label : DUMPS.DP.label,
          county: isDH ? DUMPS.DH.county : DUMPS.DP.county,
          driver_id: drvId,
          driver_name: drvId ? (nameById.get(drvId) ?? "") : "",
          start_at: d.start_at as string | null,
          when: fmt(d.start_at as string | null),
          clients_on_it: countByDump.get(d.id as number) ?? 0,
          is_yours: !!rdDriverId && drvId === rdDriverId,
        };
      });
      // driver's own dumps first, then most recent
      out.sort((a, b) => (Number(b.is_yours) - Number(a.is_yours)) ||
        (new Date(b.start_at ?? 0).getTime() - new Date(a.start_at ?? 0).getTime()));
      return json({ ok: true, dumps: out, count: out.length });
    }

    // Link OLDER VISITS to a chosen dump (Fred 2026-07-23): the driver ticked older visits in VIEW
    // ADDRESSES, picked which dump they rode on, and confirms. Writes the ledger with that dump's
    // visit_id (provenance), then posts the "added to the [dump] manifest" #dump-visits alert.
    if (action === "link") {
      const lDriverId = Number(body.driver_id);
      const lDumpVisitId = Number(body.dump_visit_id);
      const lVisitIds = Array.isArray(body.visit_ids)
        ? (body.visit_ids as unknown[]).map(Number).filter((n) => Number.isFinite(n) && n > 0)
        : [];
      if (!lDriverId) return json({ ok: false, error: "pick who you are" }, 400);
      if (!lDumpVisitId) return json({ ok: false, error: "pick a dump" }, 400);
      if (!lVisitIds.length) return json({ ok: false, error: "no visits to link" }, 400);
      const driverName = (await drivers()).find((d) => d.id === lDriverId)?.full_name;
      if (!driverName) return json({ ok: false, error: "unknown driver" }, 400);

      const { data: linked, error } = await db.rpc("dump_manifest_link", {
        p_driver_id: lDriverId, p_dump_visit_id: lDumpVisitId, p_visit_ids: lVisitIds,
      });
      if (error) {
        console.error("[dump] manifest link failed:", error.message);
        return json({ ok: false, error: "could not link the visits to that dump" }, 500);
      }
      const rows = (Array.isArray(linked) ? linked : []) as { visit_id: number; client_code: string; client_name: string }[];
      if (!rows.length) return json({ ok: false, error: "that dump is no longer available" }, 400);

      await logActivity("link", lDriverId, lDumpVisitId, { count: rows.length });
      try { await postManifestLinkAlert(driverName, lDumpVisitId, rows); }
      catch (e) { console.error("[dump] slack link alert failed:", e instanceof Error ? e.message : String(e)); }
      return json({ ok: true, linked: rows, count: rows.length });
    }

    // TESTING MODE cleanup (Fred 2026-07-24): the Testing screen's "Remove all test visits" button.
    // Soft-deletes every [TEST]-flagged app dump (source='manual', 000-DH/000-DP) + its ledger/trail
    // children. dump_test_cleanup can ONLY touch [TEST]-marked manual dumps, so real Jobber dumps are
    // never at risk. Returns how many were removed.
    if (action === "test_cleanup") {
      const { data, error } = await db.rpc("dump_test_cleanup");
      if (error) {
        console.error("[dump] test_cleanup failed:", error.message);
        return json({ ok: false, error: "could not remove the test visits" }, 500);
      }
      const removed = typeof data === "number" ? data : 0;
      await logActivity("test_cleanup", null, null, { removed });
      return json({ ok: true, removed });
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

    // TESTING MODE (Fred 2026-07-24): the app's Testing screen sends test_mode:true. The visit gets a
    // [TEST] marker in its notes so it's obviously test data, its Slack alerts are prefixed [TEST], and
    // it is removable in one tap via the `test_cleanup` action. Real and test dumps never share an
    // idempotency hit (the marker scopes the dupe check).
    const testMode = body.test_mode === true;

    // NO-GO BLOCK (Fred 2026-07-24): a fully-closed dump does not receive drivers, so refuse to create a
    // phantom visit — the app shows a "closed" message instead. CLOSED is Pompano outside its receiving
    // hours (no after-hours drop-off); Homestead is AFTER_HOURS (callable), never CLOSED, so it is never
    // blocked here. Uses the arrival the phone computed when known (the driver is ~40 min out), else now.
    // Testing mode is exempt: a preview must reach the closed dialog without landing a real visit. This is
    // the server backstop — the app already refuses to offer "Go to DUMP" for a CLOSED dump.
    if (!testMode) {
      const arrivalIso = (typeof body.arrival_at === "string" && !Number.isNaN(Date.parse(body.arrival_at as string)))
        ? (body.arrival_at as string) : new Date().toISOString();
      const gate = await siteStatus(dumpKey, arrivalIso);
      if (gate?.status === "CLOSED") {
        console.log(`[dump] no-go block: ${dumpKey} CLOSED at ${arrivalIso} — refusing create for ${driver.full_name}`);
        return json({
          ok: false, closed: true, dump: dump.label, dump_key: dumpKey,
          error: `${dump.label} is closed right now and has no after-hours drop-off — you can't dump here until it reopens.`,
        }, 409);
      }
    }

    // IDEMPOTENCY — THIS driver double-tapping must not create a second Jobber visit. Scoped to
    // (site + driver): a different driver heading to the same dump gets his own visit (see above).
    const since = new Date(Date.now() - IDEMPOTENCY_MINUTES * 60_000).toISOString();
    let dupeQuery = db
      .from("visits")
      .select("id, public_id, start_at, assigned_driver_id")
      .eq("client_id", dump.client_id)
      .eq("assigned_driver_id", driverId)
      .eq("visit_status", "scheduled")
      .is("deleted_at", null)
      .gte("start_at", since);
    dupeQuery = testMode ? dupeQuery.ilike("notes", "%[TEST]%") : dupeQuery.not("notes", "ilike", "%[TEST]%");
    const { data: dupes, error: dupeErr } = await dupeQuery.order("start_at", { ascending: false }).limit(1);
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
    // ⚠ Strip any caller-injected [TEST] token: on this anon endpoint the free-text ETA/hours notes are
    // caller-controlled, and [TEST] in visits.notes is the ONLY test-vs-real discriminator test_cleanup
    // trusts (review finding 2026-07-24). Only the app's own test_mode prefix may add the marker.
    const stripTestTag = (s: string) => s.replace(/\[\s*test\s*\]/gi, "");
    const etaRaw = typeof body.eta_snapshot === "string" ? body.eta_snapshot : "";
    const etaNote = stripTestTag(etaRaw).replace(/[\r\n]+/g, " ").trim().slice(0, 160);

    // Fred 2026-07-20: the hours warning WARNS, never blocks, but the outcome is recorded so the office
    // can see he arrived outside receiving hours. Display text only, flattened and clamped like the ETA.
    const hoursRaw = typeof body.site_status_note === "string" ? body.site_status_note : "";
    const hoursNote = stripTestTag(hoursRaw).replace(/[\r\n]+/g, " ").trim().slice(0, 80);

    // After-hours call-ahead (Fred 2026-07-24): Homestead can take a driver after last intake ONLY if he
    // calls up front. The app tells us whether he tapped CALL first. Recorded on the note for the office
    // and surfaced on the created alert. Only meaningful for an after-hours dump (hoursNote says so).
    const calledAhead = body.called_ahead === true;
    const isAfterHours = /AFTER HOURS/i.test(hoursNote);
    const callNote = isAfterHours ? ` Called ahead: ${calledAhead ? "yes" : "NO"}.` : "";

    // WHICH TRUCK is he in? Resolved BEFORE the insert so the truck lands on the visit in the same write
    // the Slack alert reads from (the hourly derive cron lands a median 21.9h later — far too late to be
    // the answer). Accurate-or-silent: `truck.vehicle_id` is NULL unless GPS and/or the Calendar are
    // confident, and a GPS-vs-Calendar disagreement stamps nothing and is surfaced in the alert instead.
    // The phone's cached ETA fix is reused, so there is no new location prompt.
    const truck = await resolveTruck(driverId, body.client_lat, body.client_lng);

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
      p_notes: (testMode ? "[TEST] " : "") +
               `Dump run — ${driver.full_name} (via truck QR). Attach the dump manifest photo here.` +
               (etaNote ? ` ${etaNote}` : "") +
               (hoursNote ? ` ${hoursNote}` : "") +
               callNote,
      p_driver_id: driverId,
      p_team_ids: [driverId],
      // TRUCK (Fred 2026-07-27): NULL unless the resolver is confident. See resolveTruck + the migration
      // header. Passing NULL is the normal, correct outcome for an unresolvable dump — the hourly
      // derive-visit-vehicle-id cron only ever touches vehicle_id IS NULL, so it stays the safety net and
      // can never fight this write.
      p_vehicle_id: truck?.vehicle_id ?? null,
      // A TEST dump must NEVER reach Jobber and must ALWAYS stay source='manual' so test_cleanup can find
      // it — even after go-live flips PUSH_TO_JOBBER=true (Fred 2026-07-24, review finding). test_mode is
      // decoupled from the go-live global on purpose: a preview must never land on the real crew schedule.
      p_push_to_jobber: testMode ? false : PUSH_TO_JOBBER,
    });

    if (error) {
      // e.g. job archived => "create_calendar_visit: job X is not an active job for client Y".
      console.error(`[dump] create failed for ${dumpKey}:`, error.message);
      return json({ ok: false, error: "could not create the visit", detail: error.message }, 500);
    }

    const v = Array.isArray(visit) ? visit[0] : visit;
    // Provenance for the truck decision rides in the existing jsonb detail — NOT in a source-prefixed
    // column (Rule 1). This is what lets us audit "why did it say Moises" after the fact.
    await logActivity("create", driverId, (v?.id as number) ?? null, {
      dump_key: dumpKey,
      truck: truck ? { vehicle_id: truck.vehicle_id, name: truck.vehicle_name, confidence: truck.confidence, candidates: truck.candidates } : null,
    });
    console.log(`[dump] created visit ${v?.id} ${dumpKey} driver=${driver.full_name} — trigger will push to Jobber`);

    // SPLIT dump alert #1 (Fred 2026-07-23): "dump created" fires HERE on GO, so a dump ALWAYS notifies
    // #dump-visits even if the driver never opens the crib sheet. (#2 "load reported" fires on confirm.)
    // Only on a genuine create — the idempotent-hit path above returns early and never reaches here.
    if (v?.id) {
      try { await postDumpCreatedAlert(v.id as number, driver.full_name, driverId, { afterHours: isAfterHours, calledAhead, truck }); }
      catch (e) { console.error("[dump] slack created alert failed:", e instanceof Error ? e.message : String(e)); }
    }

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
