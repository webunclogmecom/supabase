// ============================================================================
// heal-day-starts - heals a truck's Start of day: removes it, gives it the new driver, or recomputes it
// (2026-09-24; Jobber first since 2026-09-24_2100)
// ============================================================================
// Fred: "if it's changed by Jobber and our App adopts ... then we don't need any warning or whatsoever
// just remove the Start Point if there are no more visits (or they're anytime) or recalculate if there
// are any other visit with scheduled time ... and we need to actually check if there are errors
// because of it."
// ops.start_heal_candidates() names each Start and its KIND:
//   remove     flagged 'no timed visit': the Start and its Jobber Task go.
//   driver     flagged 'driver changed': employee_id becomes the first visit's driver.
//   recompute  a DERIVED Start flagged 'first visit changed': minute = the first visit's ET minute - ETA
//              from Doral Yard - 30, and that visit's driver, exactly as the Calendar's Recompute (13p).
//              The minute is planned in SQL (ops.apply_start_heal with p_dry_run); this function only
//              fetches the ETA.
// 🛑 JOBBER FIRST (2026-09-24_2100, Fred: "that it first confirms the data was changed in jobber being
// reflected in the app/db"). Every heal goes through saveMarker() in ../_shared/day-marker-task.ts, the
// same saga as a person's save: claim the marker, change the Task, read it back, then commit through
// ops.save_day_marker, which re-checks the heal under the row lock. Until that migration removal and the
// driver swap happened in SQL inside ops.fn_judge_starts and the trigger pushed afterwards.
// A Jobber refusal is recorded (ops.note_start_heal_attempt, outcome jobber_failed) and retried after 10
// minutes, so an outage does not make every kick hit Jobber again.
// Migrations: docs/migrations/2026-09-24_0845_start_freshness_phase2.sql, 2026-09-24_2100_jobber_first_day_markers.sql.
//
// CALLERS: public.fn_request_start_heal, through pg_net with the vault key edge_invoke_service_key,
// only when ops.start_heal_candidates() has a row, at most once every 15 seconds (2026-09-24_2100). Runs can
// overlap; the per-marker claim keeps two of them from changing the same Start. It is kicked by
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
// spends a routing token. Only recompute candidates ask for an ETA.
//
// OBSERVABILITY: one public.sync_log row per invocation (sync_source 'start-flags-heal'), status
// ok | attention (something was refused) | error (something failed). The daily health check
// (public.log_start_flags_health) reads the errors, and any Start still out of date after 30 minutes.
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { saveMarker } from "../_shared/day-marker-task.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ops = createClient(SUPABASE_URL, SERVICE_KEY, { db: { schema: "ops" }, auth: { persistSession: false } });
const pub = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

const ETA_TIMEOUT_MS = 90_000;   // 10 legs at most, 6 s each inside calculate-driving-time; inside pg_net's 120 s

type Candidate = {
  kind: "remove" | "driver" | "recompute";
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

// Outcomes that are not a failure and need nobody: the Start changed, was fixed or removed by someone
// else, or another writer was changing it (the next run sees it again if it still needs a fix).
const SKIPPED = new Set(["gone", "changed", "off", "not_derived", "not_flagged", "frozen", "busy",
                         "changed_elsewhere", "not_found"]);

// One Start: plan (recompute only), then the Jobber-first save. Returns what happened, for the run row.
async function healOne(r: Candidate, eta: number | null): Promise<Record<string, unknown>> {
  const base = { marker_id: r.marker_id, kind: r.kind, marker_date: r.marker_date, vehicle_id: r.vehicle_id };
  let save;
  if (r.kind === "recompute") {
    // first_start_at is passed back exactly as received, so apply's equality check compares like with like.
    const { data: plan, error } = await ops.rpc("apply_start_heal", {
      p_marker_id: r.marker_id, p_first_visit_id: r.first_visit_id, p_first_start_at: r.first_start_at,
      p_driver_id: r.driver_id, p_eta_minutes: eta, p_dry_run: true,
    });
    if (error) return { ...base, error: "apply_start_heal: " + error.message };
    const pl = plan as Record<string, unknown>;
    if (pl?.outcome !== "ready") return { ...base, ...pl };          // a refusal, recorded by apply itself
    save = await saveMarker({
      op: "update", markerId: r.marker_id, holder: "heal-day-starts",
      patch: { minutes: pl.to_minutes, employee_id: pl.to_employee_id, source_visit_id: r.first_visit_id,
               eta_minutes: eta, eta_computed_at: new Date().toISOString() },
      heal: { kind: "recompute", first_visit_id: r.first_visit_id, first_start_at: r.first_start_at,
              driver_id: r.driver_id, eta_minutes: eta },
    });
  } else if (r.kind === "driver") {
    save = await saveMarker({
      op: "update", markerId: r.marker_id, holder: "heal-day-starts",
      patch: { employee_id: r.driver_id },
      heal: { kind: "driver", first_visit_id: r.first_visit_id },
    });
  } else {
    save = await saveMarker({ op: "delete", markerId: r.marker_id, holder: "heal-day-starts", heal: { kind: "remove" } });
  }
  if (save.ok) {
    const mk = save.marker as Record<string, unknown> | null;
    return { ...base, outcome: save.outcome === "gone" ? "gone" : "healed", from_minutes: r.minutes,
             to_minutes: mk?.minutes ?? null, from_employee_id: r.employee_id, to_employee_id: mk?.employee_id ?? null,
             jobber_task: save.jobber_task, jobber_changed: save.jobber_changed };
  }
  // A failure that may have left Jobber different from the row is an error for the run, whatever its code
  // (the claim stays for start-push-retry, which repairs it).
  if (save.dirty) {
    await noteFailure(r, "failed");
    return { ...base, error: save.code + ": " + save.message, claim_left: true };
  }
  if (save.code === "refused") return { ...base, outcome: save.outcome, jobber_restored: save.jobber_restored ?? null };
  if (SKIPPED.has(save.code)) return { ...base, outcome: save.code };
  if (save.code.startsWith("jobber_")) {
    // Jobber refused or did not answer: back off 10 minutes (the Start stays flagged; the health check
    // reports it after 30). Recorded as refused in the run row, not as an error.
    await noteFailure(r, "jobber_failed");
    return { ...base, outcome: "jobber_failed", code: save.code, message: save.message };
  }
  // Anything else (a database error, a refused value): an error for the run, and a 10-minute back-off so
  // the Start is not tried again on every kick.
  await noteFailure(r, "failed");
  return { ...base, error: save.code + ": " + save.message, claim_left: false };
}

async function noteFailure(r: Candidate, outcome: "jobber_failed" | "failed") {
  const { error } = await ops.rpc("note_start_heal_attempt", {
    p_marker_id: r.marker_id, p_first_visit_id: r.first_visit_id, p_first_start_at: r.first_start_at, p_outcome: outcome,
  });
  if (error) console.error("[heal-day-starts] note_start_heal_attempt failed:", error.message);
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

    const { etas, error: etaError } = await fetchEtas(rows.filter((r) => r.kind === "recompute" && r.driver_id != null), auth);
    if (etaError) { out.eta_error = etaError; console.error("[heal-day-starts]", etaError); }

    for (const r of rows) {
      const res = await healOne(r, etas.get(r.marker_id) ?? null);
      results.push(res);
      if (res.error) {
        out.errors = (out.errors as number) + 1;
        console.error("[heal-day-starts] heal failed", r.marker_id, r.kind, res.error);
      } else if (res.outcome === "healed") out.healed = (out.healed as number) + 1;
      else if (SKIPPED.has(String(res.outcome))) out.skipped = (out.skipped as number) + 1;
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
