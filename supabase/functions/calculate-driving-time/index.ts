// ============================================================================
// calculate-driving-time — generalized dispatch-side drive time (Fred, 2026-08-05)
// ============================================================================
// Fred: "go with the marker phase, and the drive-time behavior too."
//
// Yannick's reference dispatch board computes depot->first-job and last-job->depot legs to place its
// Start/End markers, and drive-in/drive-out legs around a dump stop. We already had a real
// traffic-aware Routes v2 client, but it was WELDED to one shape: dump-visit-create's computeEta
// routes from a live truck GPS position to one of exactly TWO hardcoded dump sites. This function is
// that engine generalized to arbitrary origin -> destination, for the office side.
//
// 🛑 WHY THIS IS A SEPARATE FUNCTION WITH A SEPARATE BUDGET, AND MUST STAY THAT WAY.
// dump-visit-create's cap (public.dump_eta_take_token, 500/day) FAILS CLOSED and protects a DRIVER
// standing at a truck waiting for an ETA. Dispatch recompute volume is unbounded — a dispatcher can
// drag twenty visits in a minute. Sharing one bucket would let office browsing starve the driver.
// This uses ops.dispatch_routing_take_token against its own counter. Do not merge them.
//
// 🛑 IT RETURNS null, NEVER AN ESTIMATE. This is the house rule from computeEta and it is the single
// most important thing to preserve if anyone ports more of Yannick's prototype. HIS version falls
// back to a hardcoded 15 minutes on ANY failure — missing key, HTTP error, rate limit — with only a
// console.warn, no toast, no "estimated" flag. So a number that reads as measured may be a default,
// and the UI cannot tell. Ours renders nothing when it does not know. Silence, never a guess.
//
// AUTH: verify_jwt = true in config.toml, but that is only HALF a gate — the anon key is itself a
// validly signed JWT, so the handler must also assert the ROLE. authenticated (the Visit Calendar,
// which carries a real staff session) and service_role (cron/server callers) are allowed; anon is not.
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// ops-schema client: the depot view, the dump-site view, the cache and the counter all live in ops.
const db = createClient(SUPABASE_URL, SERVICE_KEY, { db: { schema: "ops" } });

const ROUTES_DAILY_CAP = 300;      // dispatch budget, independent of the dump app's 500
const ROUTES_TIMEOUT_MS = 6_000;
const MAX_LEGS = 24;               // one day's worth of stops; refuses a runaway batch
// Cache TTLs mirror dump-visit-create: a traffic-aware answer goes stale fast, a free-flow one does not.
const TTL_TRAFFIC_MS = 10 * 60_000;
const TTL_FREE_MS = 24 * 60 * 60_000;

const ALLOW_FALLBACK = "authorization, x-client-info, apikey, content-type, x-app-source";
function cors(req: Request) {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": req.headers.get("access-control-request-headers") ?? ALLOW_FALLBACK,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
  };
}
function json(req: Request, body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors(req), "Content-Type": "application/json" },
  });
}

// Read the role out of the presented JWT without verifying the signature — the platform already did
// that (verify_jwt = true). We only need to know WHICH key was used.
function bearerRole(req: Request): string | null {
  const raw = req.headers.get("authorization") ?? "";
  const tok = raw.replace(/^Bearer\s+/i, "").trim();
  const parts = tok.split(".");
  if (parts.length !== 3) return null;
  try {
    const pad = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    return JSON.parse(atob(pad + "=".repeat((4 - (pad.length % 4)) % 4)))?.role ?? null;
  } catch { return null; }
}

// Traffic matters during the working day in ET. Outside it, ask for the cheaper free-flow answer and
// cache it far longer. Same rule as dump-visit-create so the two agree about what "now" means.
function trafficMattersNow(): boolean {
  const h = Number(
    new Intl.DateTimeFormat("en-US", {
      timeZone: "America/New_York", hour: "2-digit", hour12: false,
    }).format(new Date()),
  );
  return h >= 6 && h < 20;
}

type Point = { lat: number; lng: number };
type Endpoint = { lat?: unknown; lng?: unknown; kind?: string; key?: string };

function validCoord(lat: unknown, lng: unknown): boolean {
  const a = Number(lat), b = Number(lng);
  return Number.isFinite(a) && Number.isFinite(b) && Math.abs(a) <= 90 && Math.abs(b) <= 180 && !(a === 0 && b === 0);
}

// Named endpoints are resolved SERVER-SIDE from the views, never accepted as coordinates from the
// browser. That is what stops the app re-hardcoding dump coordinates and drifting from
// dump-visit-create's DUMPS constant — there is one source, public.properties, behind both.
async function resolveEndpoint(e: Endpoint, cache: { depot?: Point | null; dumps?: Record<string, Point> }): Promise<Point | null> {
  if (validCoord(e?.lat, e?.lng)) return { lat: Number(e.lat), lng: Number(e.lng) };

  if (e?.kind === "depot") {
    if (cache.depot === undefined) {
      const { data } = await db.from("v_depot").select("latitude, longitude").maybeSingle();
      cache.depot = data && data.latitude != null && data.longitude != null
        ? { lat: Number(data.latitude), lng: Number(data.longitude) }
        : null;
    }
    return cache.depot;                    // null when no depot is configured — a legitimate state
  }

  if (e?.kind === "dump") {
    if (!cache.dumps) {
      const { data } = await db.from("v_dump_sites").select("dump_key, latitude, longitude");
      cache.dumps = {};
      for (const r of data ?? []) {
        if (r.latitude != null && r.longitude != null) {
          cache.dumps[String(r.dump_key)] = { lat: Number(r.latitude), lng: Number(r.longitude) };
        }
      }
    }
    return cache.dumps[String(e.key ?? "").toUpperCase()] ?? null;
  }

  return null;
}

const r2 = (n: number) => Number(n.toFixed(2));   // ~1.1km cells; matches dump_eta_cache's ACTUAL rounding

async function leg(o: Point, d: Point): Promise<{ minutes: number; distance_mi: number | null; source: string } | null> {
  const key = Deno.env.get("GOOGLE_MAPS_API_KEY") ?? "";
  if (!key) { console.warn("[drive] GOOGLE_MAPS_API_KEY missing - drive time disabled"); return null; }

  const trafficAware = trafficMattersNow();
  const oLat = r2(o.lat), oLng = r2(o.lng), dLat = r2(d.lat), dLng = r2(d.lng);

  // Same cell for origin and destination: a real leg of under ~1km. Routing it would spend a token to
  // learn "about a minute". Answer locally and say so.
  if (oLat === dLat && oLng === dLng) return { minutes: 1, distance_mi: 0, source: "same-cell" };

  const freshSince = new Date(Date.now() - (trafficAware ? TTL_TRAFFIC_MS : TTL_FREE_MS)).toISOString();
  const { data: hit, error: cacheErr } = await db
    .from("route_leg_cache")
    .select("duration_minutes, distance_mi")
    .eq("origin_lat_r", oLat).eq("origin_lng_r", oLng)
    .eq("dest_lat_r", dLat).eq("dest_lng_r", dLng)
    .eq("traffic_aware", trafficAware)
    .gte("computed_at", freshSince)
    .maybeSingle();
  if (cacheErr) console.error("[drive] cache read failed (continuing):", cacheErr.message);
  if (hit) {
    return {
      minutes: Number(hit.duration_minutes),
      distance_mi: hit.distance_mi === null ? null : Number(hit.distance_mi),
      source: "cache",
    };
  }

  // Spend guard BEFORE spending. Counts attempts, not successes — a failed call still consumes quota
  // upstream. FAIL CLOSED: an error here means do not route, because a cap that can be bypassed by
  // breaking it is not a cap.
  const { data: token, error: capErr } = await db.rpc("dispatch_routing_take_token", { p_cap: ROUTES_DAILY_CAP });
  if (capErr) { console.error("[drive] cap check failed, refusing to route:", capErr.message); return null; }
  if (token === null || token === undefined) {
    console.warn(`[drive] daily dispatch cap of ${ROUTES_DAILY_CAP} reached - no drive times until ET midnight`);
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
        // departureTime deliberately OMITTED — Routes defaults it to request time. Sending our own
        // "now" fails: by evaluation it is already in the past and Google rejects with
        // 400 INVALID_ARGUMENT "Timestamp must be set to a future time" (hit 2026-07-18 on the dump
        // function). Do not "helpfully" add it back.
      }),
    });
    if (!res.ok) { console.error(`[drive] routes http ${res.status}:`, (await res.text()).slice(0, 200)); return null; }
    const j = await res.json();
    const route = j?.routes?.[0];
    if (!route?.duration) return null;
    const secs = Number(String(route.duration).replace(/s$/, ""));
    if (!Number.isFinite(secs) || secs <= 0) return null;
    const meters = Number(route.distanceMeters ?? 0);
    const out = {
      minutes: Math.max(1, Math.round(secs / 60)),
      distance_mi: meters > 0 ? Math.round((meters / 1609.34) * 10) / 10 : null,
      source: "routes",
    };

    const { error: putErr } = await db.from("route_leg_cache").upsert({
      origin_lat_r: oLat, origin_lng_r: oLng, dest_lat_r: dLat, dest_lng_r: dLng,
      traffic_aware: trafficAware,
      duration_minutes: out.minutes, distance_mi: out.distance_mi,
      computed_at: new Date().toISOString(),
    }, { onConflict: "origin_lat_r,origin_lng_r,dest_lat_r,dest_lng_r,traffic_aware" });
    if (putErr) console.error("[drive] cache write failed (non-fatal):", putErr.message);

    return out;
  } catch (e) {
    console.error("[drive] routes failed:", e instanceof Error ? e.message : String(e));
    return null;
  } finally {
    clearTimeout(timer);
  }
}

Deno.serve(async (req) => {
  // Answer the preflight BEFORE any auth work, or the browser never gets to send the real request.
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return json(req, { ok: false, error: "POST only" }, 405);

  const role = bearerRole(req);
  if (role !== "authenticated" && role !== "service_role") {
    return json(req, { ok: false, error: "forbidden" }, 403);
  }

  let body: { legs?: Array<{ from?: Endpoint; to?: Endpoint }> };
  try { body = await req.json(); } catch { return json(req, { ok: false, error: "invalid json" }, 400); }

  const legs = Array.isArray(body?.legs) ? body.legs : [];
  if (legs.length === 0) return json(req, { ok: false, error: "no legs" }, 400);
  if (legs.length > MAX_LEGS) return json(req, { ok: false, error: `too many legs (max ${MAX_LEGS})` }, 400);

  const cache: { depot?: Point | null; dumps?: Record<string, Point> } = {};
  const results: Array<Record<string, unknown> | null> = [];

  // Sequential on purpose: the cap token is taken per leg, and firing them in parallel would let a
  // single batch overshoot the daily budget by the width of the batch before any counter caught up.
  for (const l of legs) {
    const o = await resolveEndpoint(l?.from ?? {}, cache);
    const d = await resolveEndpoint(l?.to ?? {}, cache);
    if (!o || !d) { results.push(null); continue; }   // unresolvable endpoint (e.g. no depot set) = unknown
    results.push(await leg(o, d));
  }

  return json(req, {
    ok: true,
    traffic_aware: trafficMattersNow(),
    legs: results,     // null entries mean UNKNOWN. They must render as nothing, never as a number.
  });
});
