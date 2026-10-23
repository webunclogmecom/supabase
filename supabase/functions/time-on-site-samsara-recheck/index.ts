import { isSecretKeyCaller } from "../_shared/service-caller.ts";
// time-on-site-samsara-recheck: rechecks saved time on site against Samsara's own stay (2026-10-14_1630).
//
// Fred, 2026-10-14: "yes do both" (recheck old times; Samsara is the reference). For each customer visit with a
// completion stop (public.fn_time_on_site_samsara_candidates), read the truck's Samsara trips and take the gap between
// two trips that overlaps that stop the most: the stay Samsara shows. Save it (public.fn_save_samsara_stay, source
// samsara_stay) when the visit is blank or its saved time differs by 2 min or more. Left alone: no gap over the stop;
// a saved time on a late-tap anchor (the save refuses). Fred, 2026-10-15 (2026-10-15_0140): one stop serving several
// visits gives each the WHOLE stay ("that should be get the whole stop"), and when Samsara shows the truck MOVING during
// the job (two or more stays over the job window) the longest stay is saved ("the stay that most likely is the service").
//
// AUTH: verify_jwt=true (pinned in config.toml) plus a service_role gate. Called nightly by pg_cron
// (fn_request_time_on_site_samsara_recheck, 03:50 ET) with the vault service_role key.
// Body: { from?: "YYYY-MM-DD" (default today-10 ET), to?: "YYYY-MM-DD" (default tomorrow), dry_run?: boolean }.
// Every run that is not a dry run writes ONE public.sync_log row (time_on_site_samsara_recheck).

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SOURCE = "time_on_site_samsara_recheck";
const MIN_DIFF = 2;   // minutes: under this the saved time already matches Samsara (rounding)

type Cand = { visit_id: number; truck_samsara_id: string; arrived: string; departed: string; ref_arrived: string; ref_departed: string;
              completed_at: string | null;
              holds_tap: boolean; duration_minutes: number | null; source: string | null };
type Trip = { startMs: number; endMs: number };

const json = (p: unknown, status = 200) =>
  new Response(JSON.stringify(p), { status, headers: { "Content-Type": "application/json" } });
const H = { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json",
            "x-app-source": "time-on-site-samsara" };
const etDate = (ms: number) => new Date(ms).toLocaleDateString("en-CA", { timeZone: "America/New_York" });

function bearerRole(req: Request): string | null {
  if (isSecretKeyCaller(req)) return "service_role"; // a secret key (2026-10-23, legacy-keys plan)
  try {
    const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(tok.split(".")[1] ?? ""))?.role ?? null;
  } catch { return null; }
}

async function rpc(fn: string, body: unknown) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: "POST", headers: H, body: JSON.stringify(body) });
  const t = await r.text();
  if (!r.ok) throw new Error(`${fn}: HTTP ${r.status} ${t.slice(0, 200)}`);
  return JSON.parse(t);
}

// one Samsara read per truck and ET day (with 12 h either side, so a night stay is whole)
const tripCache = new Map<string, Promise<Trip[]>>();
function trips(truck: string, day: string, token: string): Promise<Trip[]> {
  const key = `${truck}|${day}`;
  if (!tripCache.has(key)) {
    tripCache.set(key, (async () => {
      const d0 = Date.parse(`${day}T00:00:00-05:00`);
      const r = await fetch(`https://api.samsara.com/v1/fleet/trips?vehicleId=${encodeURIComponent(truck)}` +
        `&startMs=${d0 - 12 * 3600e3}&endMs=${d0 + 36 * 3600e3}`, { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } });
      if (!r.ok || !(r.headers.get("content-type") ?? "").includes("json")) throw new Error(`samsara trips ${truck} ${day}: HTTP ${r.status}`);
      return ((await r.json()).trips ?? [])
        .filter((t: Trip) => Number.isFinite(t.startMs) && Number.isFinite(t.endMs))
        .sort((x: Trip, y: Trip) => x.startMs - y.startMs);
    })());
  }
  return tripCache.get(key)!;
}

function bestGap(ts: Trip[], a: number, b: number): { g0: number; g1: number } | null {
  let best: { g0: number; g1: number; ov: number } | null = null;
  for (let i = 0; i < ts.length - 1; i++) {
    const g0 = ts[i].endMs, g1 = ts[i + 1].startMs, ov = Math.min(g1, b) - Math.max(g0, a);
    if (g1 > g0 && ov > 0 && (!best || ov > best.ov)) best = { g0, g1, ov };
  }
  return best ? { g0: best.g0, g1: best.g1 } : null;
}

// Samsara's stays (gaps between two trips) that are part of the job [a, b]: at least a minute AND at least half of the
// stay inside it. A stay that only touches the job's edge is the truck parked elsewhere before or after (visit 6087:
// a 77 min park ending 1.5 min into our stop), not a part of the job. And the longest of them.
function stays(ts: Trip[], a: number, b: number): { g0: number; g1: number }[] {
  return ts.slice(0, -1).map((t, i) => ({ g0: t.endMs, g1: ts[i + 1].startMs }))
    .filter((p) => { const ov = Math.min(p.g1, b) - Math.max(p.g0, a); return p.g1 > p.g0 && ov >= 60e3 && ov >= 0.5 * (p.g1 - p.g0); });
}
const longest = (ps: { g0: number; g1: number }[]) => ps.reduce((x, y) => (y.g1 - y.g0 > x.g1 - x.g0 ? y : x));

async function recheck(from: string, to: string, dryRun: boolean, token: string) {
  const cands = await rpc("fn_time_on_site_samsara_candidates", { p_from: from, p_to: to }) as Cand[];
  const found: { c: Cand; g0: number; g1: number }[] = [];
  const counts = { candidates: cands.length, moved_during_job: 0, no_gap: 0, read_failed: 0, agree: 0, late_tap_kept: 0,
                   saved: 0, refused: 0 };
  for (const c of cands) {
    const a = Date.parse(c.arrived), b = Date.parse(c.departed);
    let ts: Trip[];
    try { ts = await trips(c.truck_samsara_id, etDate(a), token); } catch { counts.read_failed++; continue; }
    const ra = Date.parse(c.ref_arrived), rb = Date.parse(c.ref_departed);
    const parts = stays(ts, ra, rb);
    let g: { g0: number; g1: number } | null;
    if (parts.length > 1) { counts.moved_during_job++; g = longest(parts); }   // the truck moved: the longest stay
    else g = bestGap(ts, a, b);
    if (!g) { counts.no_gap++; continue; }
    found.push({ c, ...g });
  }
  const changes: Record<string, unknown>[] = [];
  for (const f of found) {
    const mins = Math.round((f.g1 - f.g0) / 60e3);
    if (f.c.duration_minutes != null && Math.abs(f.c.duration_minutes - mins) < MIN_DIFF) { counts.agree++; continue; }
    if (f.c.duration_minutes != null && !f.c.holds_tap) { counts.late_tap_kept++; continue; }
    const change = { visit_id: f.c.visit_id, from: f.c.duration_minutes, from_source: f.c.source, to: mins,
                     arrived: new Date(f.g0).toISOString(), departed: new Date(f.g1).toISOString() };
    if (!dryRun) {
      const ok = await rpc("fn_save_samsara_stay", { p_visit_id: f.c.visit_id, p_arrival: change.arrived, p_departure: change.departed,
                                                     p_expected_minutes: f.c.duration_minutes, p_expected_source: f.c.source });
      if (ok !== true) { counts.refused++; continue; }
      counts.saved++;
    }
    changes.push(change);
  }

  // second pass (2026-10-14_1800, Fred: "add the went-once rule to the nightly recheck"): the truck was not parked
  // there when the job was marked complete, but went to the address once that date (8017, 3942). Read AFTER the
  // first pass so its saves are seen; a visit the first pass changed (or would, on a dry run) is left to it. Two
  // visits of one client may share the stay (two services, one stop), so there is no shared-stay skip here.
  const once = await rpc("fn_time_on_site_went_once", { p_from: from, p_to: to }) as Cand[];
  const went_once = { candidates: once.length, moved_during_job: 0, no_gap: 0, read_failed: 0, agree: 0, saved: 0, refused: 0 };
  const done = new Set(changes.map((c) => c.visit_id));
  for (const c of once) {
    if (done.has(c.visit_id)) continue;
    const a = Date.parse(c.arrived), b = Date.parse(c.departed);
    let ts: Trip[];
    try { ts = await trips(c.truck_samsara_id, etDate(a), token); } catch { went_once.read_failed++; continue; }
    const parts = stays(ts, a, b);
    let g: { g0: number; g1: number } | null;
    if (parts.length > 1) { went_once.moved_during_job++; g = longest(parts); }
    else g = bestGap(ts, a, b);
    if (!g) { went_once.no_gap++; continue; }
    const mins = Math.round((g.g1 - g.g0) / 60e3);
    if (c.duration_minutes != null && Math.abs(c.duration_minutes - mins) < MIN_DIFF) { went_once.agree++; continue; }
    const change = { visit_id: c.visit_id, rule: "went_once", from: c.duration_minutes, from_source: c.source, to: mins,
                     arrived: new Date(g.g0).toISOString(), departed: new Date(g.g1).toISOString() };
    if (!dryRun) {
      const ok = await rpc("fn_save_samsara_stay_went_once", { p_visit_id: c.visit_id, p_arrival: change.arrived, p_departure: change.departed,
                                                               p_expected_minutes: c.duration_minutes, p_expected_source: c.source });
      if (ok !== true) { went_once.refused++; continue; }
      went_once.saved++;
    }
    changes.push(change);
  }
  return { from, to, dry_run: dryRun, counts: { ...counts, went_once }, changes };
}

async function logRun(startedAt: string, ok: boolean, details: Record<string, unknown>) {
  try {
    await fetch(`${SUPABASE_URL}/rest/v1/sync_log`, {
      method: "POST", headers: { ...H, Prefer: "return=minimal" },
      body: JSON.stringify({
        sync_source: SOURCE, started_at: startedAt, finished_at: new Date().toISOString(),
        duration_seconds: (Date.now() - Date.parse(startedAt)) / 1000,
        status: ok ? "success" : "error", rows_updated: ok ? ((details.counts as { saved: number; went_once?: { saved: number } }).saved + ((details.counts as { went_once?: { saved: number } }).went_once?.saved ?? 0)) : 0, rows_errored: ok ? 0 : 1,
        error_details: ok ? null : { message: `The nightly time on site check against Samsara failed: ${details.error}` },
        details,
      }),
    });
  } catch (e) { console.error(`[${SOURCE}] sync_log insert failed: ${e}`); }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (bearerRole(req) !== "service_role") return json({ error: "service_role only" }, 403);
  const body = await req.json().catch(() => ({}));
  const today = etDate(Date.now());
  const from = /^\d{4}-\d{2}-\d{2}$/.test(body?.from ?? "") ? body.from : etDate(Date.parse(`${today}T12:00:00Z`) - 10 * 86400e3);
  const to = /^\d{4}-\d{2}-\d{2}$/.test(body?.to ?? "") ? body.to : etDate(Date.parse(`${today}T12:00:00Z`) + 86400e3);
  const dryRun = body?.dry_run === true;
  const startedAt = new Date().toISOString();
  const token = Deno.env.get("SAMSARA_API_TOKEN");
  if (!token) {
    if (!dryRun) await logRun(startedAt, false, { error: "no Samsara token", counts: { saved: 0 } });
    return json({ error: "no Samsara token" }, 500);
  }
  try {
    const out = await recheck(from, to, dryRun, token);
    if (!dryRun) await logRun(startedAt, true, { ...out, changes: out.changes.slice(0, 200) });
    return json(out);
  } catch (e) {
    if (!dryRun) await logRun(startedAt, false, { error: String(e), counts: { saved: 0 } });
    return json({ error: String(e) }, 500);
  }
});
