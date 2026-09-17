// ============================================================================
// plan-drive-fill - buys the missing legs of the Calendar's "Hours driven" chains (2026-09-17)
// ============================================================================
// Fred: "use the Google API to have a time it takes coming out of the YARD, up to the 1st visit,
// from the 1st visit to the 2nd visit, and so on and so forth, up to the last visit then to YARD
// back again, all on the same day at the calendar." The chains themselves are built live in SQL
// (ops.fn_drive_chain); this function only fills ops.route_leg_cache with the legs those chains
// need and Google has not yet been asked for. It never computes a day's number.
//
// CALLERS: pg_cron (public.fn_request_plan_drive_fill, 09:15 UTC, today -7 .. +21 ET, limit 240)
// and the Calendar's kick (ops.request_drive_fill, throttled, limit 60), both through pg_net with
// the vault service key. The browser NEVER calls this function.
//
// AUTH: verify_jwt = true in config.toml, and the handler ALSO asserts role = service_role, because
// the public anon key is a validly signed JWT and would pass the gateway on its own (the
// poll-calendar-tasks pattern). Never deploy --no-verify-jwt.
//
// BUDGET: ops.plan_routing_take_tokens against ops.plan_routing_usage (cap ops.plan_routing_cap(),
// 300 attempts per ET day), granted in CHUNKS before any fetch, fail closed: 0 tokens = stop.
// A third bucket by rule: never the day markers' dispatch bucket, never the DUMP app's.
//
// SINGLE FLIGHT: ops.plan_fill_begin() / plan_fill_end(). A second concurrent invocation returns
// {ok:true, skipped:'busy'} and writes no sync_log row.
//
// CLASSIFICATION (from _shared/google-routes.ts): key_rejected / quota / outage stop the RUN and
// ledger nothing (the pairs are retried next run); no_route / bad_request ledger the PAIR in
// ops.route_leg_fail (blocked after 3 failures for 7 days / 24 hours), but only once the run has
// seen at least one success, so a wholesale outage misread as pair failures cannot poison the ledger.
//
// OBSERVABILITY: one public.sync_log row per invocation (sync_source 'plan-drive-fill'), because
// pg_cron "succeeded" is structurally blind. status ok | attention | error; details carries the
// counters and the run-level flags the reader (ops.calendar_drive_days) turns into sentences.
// ============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { computeRoutesLeg } from "../_shared/google-routes.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ops = createClient(SUPABASE_URL, SERVICE_KEY, { db: { schema: "ops" }, auth: { persistSession: false } });
const pub = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

const CHUNK = 5;                       // parallel Google calls per chunk; wall clock is the constraint, not quota
const LEG_TIMEOUT_MS = 6_000;
const REQUEST_BUDGET_MS = 100_000;     // inside the callers' 120 s pg_net timeout
const MAX_SPAN_DAYS = 45;
const MAX_TRANSIENT_IN_A_ROW = 3;

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

const isoDate = (s: unknown) => typeof s === "string" && /^\d{4}-\d{2}-\d{2}$/.test(s);

type Pair = {
  o_lat_r: number; o_lng_r: number; d_lat_r: number; d_lng_r: number;
  from_lat: number; from_lng: number; to_lat: number; to_lng: number; nearest_date: string;
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "method" }, 405);
  if (bearerRole(req) !== "service_role") return json({ ok: false, error: "forbidden" }, 403);

  let body: any = {};
  try { body = await req.json(); } catch { body = {}; }
  const from = body?.from, to = body?.to;
  const trigger: string = body?.trigger === "cron" ? "cron" : "kick";
  const limit = Math.max(1, Math.min(300, Number(body?.limit ?? 60) || 60));
  if (!isoDate(from) || !isoDate(to)) return json({ ok: false, error: "from and to must be YYYY-MM-DD" }, 400);
  const span = (Date.parse(to) - Date.parse(from)) / 86_400_000;
  if (!(span >= 0 && span <= MAX_SPAN_DAYS)) return json({ ok: false, error: `range must be 0..${MAX_SPAN_DAYS} days` }, 400);

  // single flight
  const { data: began, error: beginErr } = await ops.rpc("plan_fill_begin");
  if (beginErr) return json({ ok: false, error: "latch: " + beginErr.message }, 500);
  if (began !== true) return json({ ok: true, skipped: "busy", from, to, trigger });

  const t0 = Date.now();
  const startedAt = new Date().toISOString();
  const out: Record<string, unknown> = {
    ok: true, from, to, trigger, pairs_needed: 0, routed: 0, failed: 0, skipped_fresh: 0, same_cell: 0,
    cap_hit: false, key_missing: false, key_rejected: false, quota: false, outage: false, sku_mismatch: 0,
    remaining: 0, ms: 0,
  };
  let status: "ok" | "attention" | "error" = "ok";
  let fatal: string | null = null;

  try {
    const key = Deno.env.get("GOOGLE_MAPS_API_KEY") ?? "";
    const { data: capData, error: capErr } = await ops.rpc("plan_routing_cap");
    if (capErr) throw new Error("rpc plan_routing_cap: " + capErr.message);
    const cap = Number(capData);

    const { data: pairsData, error: pairsErr } = await ops.rpc("fn_drive_missing_pairs", { p_from: from, p_to: to });
    if (pairsErr) throw new Error("rpc fn_drive_missing_pairs: " + pairsErr.message);   // a renamed view column lands here as status error, never as ok/routed 0
    const pairs = (pairsData ?? []) as Pair[];
    out.pairs_needed = pairs.length;

    if (!key) {
      console.warn("[plan-drive-fill] GOOGLE_MAPS_API_KEY missing - nothing routed");
      out.key_missing = true; status = "error";
    } else if (pairs.length > 0) {
      const todo = pairs.slice(0, limit);
      out.remaining = pairs.length - todo.length;
      let transientRun = 0;
      let sawSuccess = false;
      const ledgerLater: { p: Pair; kind: "no_route" | "bad_request"; msg: string }[] = [];

      outer:
      for (let i = 0; i < todo.length; i += CHUNK) {
        if (Date.now() - t0 > REQUEST_BUDGET_MS) { out.remaining = (out.remaining as number) + (todo.length - i); break; }
        let chunk = todo.slice(i, i + CHUNK);

        // the cheap guard for the residual race: skip pairs that gained a fresh row since the run began
        const orFilter = chunk.map((p) =>
          `and(origin_lat_r.eq.${p.o_lat_r},origin_lng_r.eq.${p.o_lng_r},dest_lat_r.eq.${p.d_lat_r},dest_lng_r.eq.${p.d_lng_r})`).join(",");
        const { data: fresh } = await ops.from("route_leg_cache")
          .select("origin_lat_r, origin_lng_r, dest_lat_r, dest_lng_r")
          .eq("traffic_aware", false)
          .gte("computed_at", new Date(Date.now() - 30 * 86_400_000).toISOString())
          .or(orFilter);
        const freshKeys = new Set((fresh ?? []).map((r: any) => `${r.origin_lat_r}|${r.origin_lng_r}|${r.dest_lat_r}|${r.dest_lng_r}`));
        const before = chunk.length;
        chunk = chunk.filter((p) => !freshKeys.has(`${p.o_lat_r}|${p.o_lng_r}|${p.d_lat_r}|${p.d_lng_r}`));
        out.skipped_fresh = (out.skipped_fresh as number) + (before - chunk.length);
        if (chunk.length === 0) continue;

        // tokens BEFORE any fetch, fail closed
        const { data: grantedData, error: tokErr } = await ops.rpc("plan_routing_take_tokens", { p_cap: cap, p_n: chunk.length });
        const granted = tokErr ? 0 : Number(grantedData ?? 0);
        if (tokErr) console.error("[plan-drive-fill] take_tokens failed, refusing to route:", tokErr.message);
        if (granted < chunk.length) {
          out.cap_hit = true;
          out.remaining = (out.remaining as number) + (chunk.length - granted) + (todo.length - i - chunk.length);
          chunk = chunk.slice(0, granted);
          if (chunk.length === 0) break;
        }

        const results = await Promise.all(chunk.map((p) =>
          computeRoutesLeg({ lat: p.from_lat, lng: p.from_lng }, { lat: p.to_lat, lng: p.to_lng }, { key, trafficAware: false, timeoutMs: LEG_TIMEOUT_MS })));

        for (let k = 0; k < chunk.length; k++) {
          const p = chunk[k], r = results[k];
          if (r.ok) {
            sawSuccess = true; transientRun = 0;
            if (r.seconds !== r.static_seconds) out.sku_mismatch = (out.sku_mismatch as number) + 1;
            const { error: putErr } = await ops.from("route_leg_cache").upsert({
              origin_lat_r: p.o_lat_r, origin_lng_r: p.o_lng_r, dest_lat_r: p.d_lat_r, dest_lng_r: p.d_lng_r,   // the cells EXACTLY as SQL computed them
              traffic_aware: false,
              duration_minutes: Math.max(1, Math.round(r.seconds / 60)),
              duration_seconds: r.seconds,
              distance_mi: r.metres > 0 ? Math.round((r.metres / 1609.34) * 10) / 10 : null,
              computed_at: new Date().toISOString(),
            }, { onConflict: "origin_lat_r,origin_lng_r,dest_lat_r,dest_lng_r,traffic_aware" });
            if (putErr) { console.error("[plan-drive-fill] cache write failed:", putErr.message); out.failed = (out.failed as number) + 1; continue; }
            await ops.from("route_leg_fail").delete()
              .eq("origin_lat_r", p.o_lat_r).eq("origin_lng_r", p.o_lng_r).eq("dest_lat_r", p.d_lat_r).eq("dest_lng_r", p.d_lng_r);
            out.routed = (out.routed as number) + 1;
            continue;
          }
          // failures
          if (r.kind === "key_rejected") { out.key_rejected = true; status = "error"; console.error("[plan-drive-fill] key rejected:", r.message); break outer; }
          if (r.kind === "quota") { out.quota = true; console.warn("[plan-drive-fill] Google quota:", r.message); break outer; }
          if (r.kind === "transient") {
            transientRun++;
            console.warn(`[plan-drive-fill] transient (${transientRun}/${MAX_TRANSIENT_IN_A_ROW}):`, r.http_status, r.message);
            if (transientRun >= MAX_TRANSIENT_IN_A_ROW) { out.outage = true; break outer; }
            continue;
          }
          // no_route / bad_request: ledger the pair, but only if this run also saw a success
          transientRun = 0;
          out.failed = (out.failed as number) + 1;
          ledgerLater.push({ p, kind: r.kind, msg: `${r.google_status ?? r.http_status ?? "?"}: ${r.message}`.slice(0, 160) });
        }
      }

      if (sawSuccess) {
        for (const f of ledgerLater) {
          const { data: existing } = await ops.from("route_leg_fail").select("failures")
            .eq("origin_lat_r", f.p.o_lat_r).eq("origin_lng_r", f.p.o_lng_r).eq("dest_lat_r", f.p.d_lat_r).eq("dest_lng_r", f.p.d_lng_r).maybeSingle();
          const { error: ledErr } = await ops.from("route_leg_fail").upsert({
            origin_lat_r: f.p.o_lat_r, origin_lng_r: f.p.o_lng_r, dest_lat_r: f.p.d_lat_r, dest_lng_r: f.p.d_lng_r,
            kind: f.kind, failures: Number(existing?.failures ?? 0) + 1, last_error: f.msg, last_failed_at: new Date().toISOString(),
          }, { onConflict: "origin_lat_r,origin_lng_r,dest_lat_r,dest_lng_r" });
          if (ledErr) console.error("[plan-drive-fill] ledger write failed:", ledErr.message);
        }
      } else if (ledgerLater.length) {
        console.warn(`[plan-drive-fill] ${ledgerLater.length} pair failures NOT ledgered: no success in this run`);
        out.outage = true;
      }
    }

    if (status !== "error") {
      const attention = (out.failed as number) > 0 || out.cap_hit === true || out.quota === true || out.outage === true || (out.sku_mismatch as number) > 0;
      status = attention ? "attention" : "ok";
    }
  } catch (e) {
    fatal = e instanceof Error ? e.message : String(e);
    status = "error";
    console.error("[plan-drive-fill] run failed:", fatal);
  } finally {
    out.ms = Date.now() - t0;
    await ops.rpc("plan_fill_end");
    const { error: logErr } = await pub.from("sync_log").insert({
      sync_source: "plan-drive-fill",
      started_at: startedAt,
      finished_at: new Date().toISOString(),
      rows_inserted: out.routed,
      rows_errored: out.failed,
      duration_seconds: (out.ms as number) / 1000,
      status,
      details: { ...out, ...(fatal ? { error: fatal } : {}) },
    });
    if (logErr) console.error("[plan-drive-fill] sync_log insert failed:", logErr.message);
  }

  if (fatal) return json({ ok: false, error: fatal, ...out }, 500);
  return json(out);
});
