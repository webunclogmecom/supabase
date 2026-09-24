// ============================================================================
// heal-day-starts - recomputes a truck's Start of day when its first visit changed (2026-09-24)
// ============================================================================
// Fred: "if it's changed by Jobber and our App adopts ... then we don't need any warning or whatsoever
// just remove the Start Point if there are no more visits (or they're anytime) or recalculate if there
// are any other visit with scheduled time ... and we need to actually check if there are errors
// because of it."
// Removal and a driver swap need no drive time and happen in SQL (ops.fn_judge_starts). This function
// does the one heal that does: a DERIVED Start flagged 'first visit changed' gets
// minute = the first visit's ET minute - ETA from Doral Yard - 30, and that visit's driver, exactly as
// the Calendar's Recompute derives it (Visit Calendar rule 13p). The minute is computed in SQL by
// ops.apply_start_heal; this function only fetches the ETA.
// Migration: docs/migrations/2026-09-24_0845_start_freshness_phase2.sql.
//
// CALLERS: public.fn_request_start_heal, through pg_net with the vault key edge_invoke_service_key,
// only when ops.start_heal_candidates() has a row, at most once a minute. It is kicked by
// ops.refresh_start_flags (the 2-minute drain, and the Calendar right after its own writes).
// The browser NEVER calls this function.
//
// AUTH: verify_jwt = true in config.toml, and the handler ALSO asserts role = service_role, because the
// public anon key is a validly signed JWT and would pass the gateway on its own. Never deploy
// --no-verify-jwt.
//
// ETA: calculate-driving-time, called with THIS request's own Authorization header (a service_role JWT
// that just passed the check above), traffic:false, one depot leg per Start. That function owns the
// cache, the 24 h TTL, the rounding and the dispatch budget (300 a day); nothing is copied here. A
// null leg means UNKNOWN and is never replaced by a guess: the Start stays flagged, apply records
// 'eta_unknown', and the next try is an hour later (each try can spend a routing token).
//
// A Start whose first visit has no driver is refused BEFORE any ETA is asked for, so a refusal never
// spends a routing token.
//
// OBSERVABILITY: one public.sync_log row per invocation (sync_source 'start-flags-heal'), status
// ok | attention (something was refused) | error (something failed). The daily health check
// (public.log_start_flags_health) reads the errors, and any Start still out of date after 30 minutes.
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ops = createClient(SUPABASE_URL, SERVICE_KEY, { db: { schema: "ops" }, auth: { persistSession: false } });
const pub = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

const ETA_TIMEOUT_MS = 90_000;   // 10 legs at most, 6 s each inside calculate-driving-time; inside pg_net's 120 s

type Candidate = {
  marker_id: number; marker_date: string; vehicle_id: number; employee_id: number; minutes: number;
  eta_minutes: number; first_visit_id: number; first_start_at: string;
  latitude: number | string; longitude: number | string; driver_id: number | null;
  driver_name: string | null; client_code: string | null;
};

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

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
}

// One call for every Start that has a driver. Returns marker_id -> whole minutes, or an error string
// when the reply cannot be trusted as a whole (then every ETA is unknown).
async function fetchEtas(rows: Candidate[], auth: string): Promise<{ etas: Map<number, number>; error: string | null }> {
  const etas = new Map<number, number>();
  if (rows.length === 0) return { etas, error: null };
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/calculate-driving-time`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: auth },
      body: JSON.stringify({
        legs: rows.map((r) => ({ from: { kind: "depot" }, to: { lat: Number(r.latitude), lng: Number(r.longitude) } })),
        traffic: false,
      }),
      signal: AbortSignal.timeout(ETA_TIMEOUT_MS),
    });
    const ctype = res.headers.get("content-type") ?? "";
    if (!ctype.includes("json")) return { etas, error: `calculate-driving-time returned ${ctype || "no content-type"} at HTTP ${res.status}` };
    const j = await res.json();
    // The Calendar never checks traffic_aware; the healer does, because the minute becomes a Jobber Task.
    if (!res.ok || j?.ok !== true || j?.traffic_aware !== false || !Array.isArray(j?.legs) || j.legs.length !== rows.length) {
      return { etas, error: `calculate-driving-time HTTP ${res.status}: ${String(j?.error ?? "unexpected reply").slice(0, 200)}` };
    }
    rows.forEach((r, i) => {
      const leg = j.legs[i];
      if (leg && typeof leg.minutes === "number" && Number.isFinite(leg.minutes)) etas.set(r.marker_id, Math.round(leg.minutes));
    });
    return { etas, error: null };
  } catch (e) {
    return { etas, error: `calculate-driving-time failed: ${e instanceof Error ? e.message : String(e)}` };
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "method" }, 405);
  if (bearerRole(req) !== "service_role") return json({ ok: false, error: "forbidden" }, 403);
  const auth = req.headers.get("authorization")!;

  let body: any = {};
  try { body = await req.json(); } catch { body = {}; }
  const trigger: string = body?.trigger === "cron" ? "cron" : "kick";

  const startedAt = new Date().toISOString();
  const t0 = Date.now();
  const out: Record<string, unknown> = { trigger, candidates: 0, healed: 0, refused: 0, skipped: 0, errors: 0 };
  const results: unknown[] = [];
  let status = "ok";
  let fatal: string | null = null;

  try {
    const { data, error } = await ops.rpc("start_heal_candidates");
    if (error) throw new Error(`start_heal_candidates: ${error.message}`);
    const rows = (data ?? []) as Candidate[];
    out.candidates = rows.length;

    const { etas, error: etaError } = await fetchEtas(rows.filter((r) => r.driver_id != null), auth);
    if (etaError) { out.eta_error = etaError; console.error("[heal-day-starts]", etaError); }

    for (const r of rows) {
      // first_start_at is passed back exactly as received, so apply's equality check compares like with like.
      const { data: res, error: applyErr } = await ops.rpc("apply_start_heal", {
        p_marker_id: r.marker_id,
        p_first_visit_id: r.first_visit_id,
        p_first_start_at: r.first_start_at,
        p_driver_id: r.driver_id,
        p_eta_minutes: etas.get(r.marker_id) ?? null,
      });
      if (applyErr) {
        out.errors = (out.errors as number) + 1;
        results.push({ marker_id: r.marker_id, error: applyErr.message });
        console.error("[heal-day-starts] apply failed", r.marker_id, applyErr.message);
        continue;
      }
      results.push(res);
      const outcome = (res as { outcome?: string })?.outcome;
      if (outcome === "healed") out.healed = (out.healed as number) + 1;
      else if (outcome === "gone" || outcome === "changed" || outcome === "off" || outcome === "not_derived" || outcome === "not_flagged" || outcome === "frozen") out.skipped = (out.skipped as number) + 1;
      else out.refused = (out.refused as number) + 1;
    }

    status = (out.errors as number) > 0 ? "error" : ((out.refused as number) > 0 || etaError) ? "attention" : "ok";
  } catch (e) {
    fatal = e instanceof Error ? e.message : String(e);
    status = "error";
    console.error("[heal-day-starts] run failed:", fatal);
  } finally {
    out.ms = Date.now() - t0;
    const firstError = fatal ?? (results.find((x: any) => x?.error) as any)?.error ?? null;
    const { error: logErr } = await pub.from("sync_log").insert({
      sync_source: "start-flags-heal",
      started_at: startedAt,
      finished_at: new Date().toISOString(),
      rows_updated: out.healed,
      rows_errored: (out.errors as number) + (fatal ? 1 : 0),
      duration_seconds: (out.ms as number) / 1000,
      status,
      error_details: firstError ? { message: `The automatic Start of day recompute failed: ${firstError}` } : null,
      details: { action: "recompute_run", ...out, results, ...(fatal ? { error: fatal } : {}) },
    });
    if (logErr) console.error("[heal-day-starts] sync_log insert failed:", logErr.message);
  }

  if (fatal) return json({ ok: false, error: fatal, ...out }, 500);
  return json({ ok: true, ...out, results });
});
