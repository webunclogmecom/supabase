// ============================================================================
// _shared/google-routes.ts - one Google Routes v2 leg, classified (2026-09-17)
// ============================================================================
// Used by plan-drive-fill (the Calendar "Hours driven" planner). The REQUEST block (headers, body
// shape, the departureTime rule) is copied from calculate-driving-time/index.ts, which is NOT ported
// onto this module yet: its error path collapses every failure into `return null`, and porting it is
// a behaviour change of its own (see the Supabase CLAUDE.md note under Hours driven).
//
// What is new here is the CLASSIFICATION. A planner that buys hundreds of legs a month must tell
// apart "this pair has no road" (ledger it, stop retrying) from "Google is down" (stop the run,
// ledger nothing) from "the key is wrong" (stop the run, say so loudly). The sibling cannot, and does
// not need to: it serves one leg to one person and a null is an honest answer there.
//
// TRAFFIC_UNAWARE is what the Calendar planner sends: Google's time-independent average, the same
// number at 3 AM and 9 AM, Essentials tier. Under TRAFFIC_UNAWARE `duration` equals `staticDuration`,
// so asking for both and comparing them is a free detector for a request that silently became
// traffic-aware (a wider field mask or a changed routingPreference).
// ============================================================================

export type LegPoint = { lat: number; lng: number };

export type LegOk = { ok: true; seconds: number; static_seconds: number; metres: number };
export type LegErr = {
  ok: false;
  kind: "key_rejected" | "quota" | "transient" | "no_route" | "bad_request";
  http_status: number | null;
  google_status: string | null;
  message: string;
};
export type LegResult = LegOk | LegErr;

export async function computeRoutesLeg(
  origin: LegPoint,
  destination: LegPoint,
  opts: { key: string; trafficAware: boolean; timeoutMs: number; fetchImpl?: typeof fetch },
): Promise<LegResult> {
  const fetchImpl = opts.fetchImpl ?? globalThis.fetch;
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), opts.timeoutMs);
  try {
    let res: Response;
    try {
      res = await fetchImpl("https://routes.googleapis.com/directions/v2:computeRoutes", {
        method: "POST",
        signal: ctl.signal,
        headers: {
          "Content-Type": "application/json",
          "X-Goog-Api-Key": opts.key,
          // routes.duration + routes.staticDuration + routes.distanceMeters. The mask keeps the payload
          // small; the SKU is decided by routingPreference (TRAFFIC_UNAWARE = Essentials), not by it.
          "X-Goog-FieldMask": "routes.duration,routes.staticDuration,routes.distanceMeters",
        },
        body: JSON.stringify({
          origin: { location: { latLng: { latitude: origin.lat, longitude: origin.lng } } },
          destination: { location: { latLng: { latitude: destination.lat, longitude: destination.lng } } },
          travelMode: "DRIVE",
          routingPreference: opts.trafficAware ? "TRAFFIC_AWARE" : "TRAFFIC_UNAWARE",
          // departureTime deliberately OMITTED - Routes defaults it to request time. Sending our own
          // "now" fails: by evaluation it is already in the past and Google rejects with
          // 400 INVALID_ARGUMENT "Timestamp must be set to a future time" (hit 2026-07-18 on the dump
          // function). TRAFFIC_UNAWARE ignores it anyway. Do not "helpfully" add it back.
        }),
      });
    } catch (e) {
      // network failure or our own AbortController: nothing to ledger, the run decides what to do
      return { ok: false, kind: "transient", http_status: null, google_status: null, message: e instanceof Error ? e.message : String(e) };
    }

    const ctype = res.headers.get("content-type") ?? "";
    const text = await res.text();
    let j: any = null;
    if (ctype.includes("json")) { try { j = JSON.parse(text); } catch { j = null; } }

    if (!res.ok) {
      const gStatus: string | null = j?.error?.status ?? null;
      const gMsg: string = String(j?.error?.message ?? text).slice(0, 200);
      if (res.status === 401 || res.status === 403 || (res.status === 400 && /api key/i.test(gMsg))) {
        return { ok: false, kind: "key_rejected", http_status: res.status, google_status: gStatus, message: gMsg };
      }
      if (res.status === 429) {
        return { ok: false, kind: "quota", http_status: res.status, google_status: gStatus, message: gMsg };
      }
      if (res.status === 400 && gStatus === "INVALID_ARGUMENT" && /location|latitude|longitude|coordinate|waypoint|origin|destination/i.test(gMsg)) {
        return { ok: false, kind: "bad_request", http_status: res.status, google_status: gStatus, message: gMsg };
      }
      // 5xx, a non-JSON body at any status, an unrecognised 4xx: not this pair's fault
      return { ok: false, kind: "transient", http_status: res.status, google_status: gStatus, message: gMsg };
    }

    if (!ctype.includes("json") || j === null) {
      return { ok: false, kind: "transient", http_status: res.status, google_status: null, message: `non-JSON ${ctype} at HTTP ${res.status}` };
    }
    // Google's "no route" is HTTP 200 with an EMPTY body ({}), not an error
    const route = j?.routes?.[0];
    if (!route?.duration) {
      return { ok: false, kind: "no_route", http_status: res.status, google_status: null, message: "no route in response" };
    }
    const secs = Number(String(route.duration).replace(/s$/, ""));
    const sSecs = route.staticDuration != null ? Number(String(route.staticDuration).replace(/s$/, "")) : secs;
    if (!Number.isFinite(secs) || secs <= 0) {
      return { ok: false, kind: "no_route", http_status: res.status, google_status: null, message: `unusable duration ${String(route.duration)}` };
    }
    const metres = Number(route.distanceMeters ?? 0);
    return { ok: true, seconds: Math.round(secs), static_seconds: Number.isFinite(sSecs) ? Math.round(sSecs) : Math.round(secs), metres: Number.isFinite(metres) ? metres : 0 };
  } finally {
    clearTimeout(timer);
  }
}
