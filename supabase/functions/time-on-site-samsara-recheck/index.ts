// @ts-nocheck (v15: the rule and its helpers are plain JS inlined from samsara-checks/.../v15, untyped on purpose)
import { isSecretKeyCaller } from "../_shared/service-caller.ts";
// time-on-site-samsara-recheck: rechecks saved time on site against Samsara's own stay (2026-10-14_1630).
// v15 (2026-11-05, duration re-check S3b, Trello vpF5PLQj): body { rules: 1 | 2 } switches the rule. rules 1 (the
// default until Fred's flip on 11-11) is the v14 code below, unchanged. rules 2 is the new rule, which starts from the visit
// (recheck2, near the end): docs/specs/2026-11-02-time-on-site-nightly-rule.md. include_ledger and place_shapes: dry runs only.
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

// ==== BEGIN rule.mjs (sha256 8987c53ed877310453eb7e19ff19bf08b432341e0a3c3270699b2c4565af5c28; inlined by v15/build_index.mjs, do not edit here) ====
const V15 = (() => {
// v15 rule.mjs: D, the candidate nightly time-on-site rule (RR/D/d_sim3.mjs, round 5, sha256 21eee65b...), as a PURE core
// for the edge function. No imports, no file / network / env / clock access: the caller reads Samsara and the DB, then
// calls runRule() until needFixes is empty. Every ruling is D's, unchanged; "d_sim3.mjs:N" points at the original line.
// The rules in words: RR/D/RULES.md. Proof that the port is exact: RR/v15/equiv_test.mjs.
//
// runRule(inputs, knobs = {}) -> { rows, needFixes }
//   inputs.visits    [{ id, band, visit_date 'YYYY-MM-DD', property_id, client_id|null, vehicle_id|null,
//                       completed_at ISO, window: { from ISO, to ISO },
//                       site: { point: { lat, lng, from } | null, place_ids: [id, ...] } }]      (visits_judge.json rows)
//   inputs.saved     [{ id, duration_minutes|null, time_on_site_source|null, ledger: [{ id, method }] }]   one per visit
//   inputs.places    { [place id]: Samsara geofence { circle: { latitude, longitude, radiusMeters } }
//                                                   | { polygon: { vertices: [{ latitude, longitude }] } } }
//   inputs.trips     { [vehicle id]: [{ s ms, e ms, sc: { latitude, longitude }|null, ec: same }] }  one key per truck WITH a
//                    Samsara device (an empty list is fine); a vehicle id not listed = no device (decision no_data)
//   inputs.firstWrite [{ id, old_min, old_src }]  the earliest time-on-site-samsara audit row per non-A visit
//   inputs.timers    [{ visit_id, t ms }]          visit timers (start)
//   inputs.fixes     { 'truck|t0|t1': [[ms, lat, lng], ...] }   answers to earlier needFixes ({} on the first call)
//   rows = null while needFixes is non-empty; needFixes = [{ key, truck, t0, t1 }] sorted by key.

const BASE_KNOBS = Object.freeze({ radius: 250, margin: 30, pre: 5, post: 15, buffer: 40, sep: 15, load_h: 4, silence: 15, move: 30 });
const FIX_R = 250, FIX_BUF = 40;   // stored-fix tests stay in the rule, not knobs (I18)
const FALLBACK = new Set(['stop_at_completion', 'gps_150m_cluster', 'gps_150m_any_truck']);
const LOCK_SRC = new Set(['review', 'reviewed_blank', 'dump_site_dwell']);   // PLAN 5.5 (a), the source part of the lock

// ---- D's lib.mjs helpers, copied (hav, ET, addDay)
const rad = (x) => (x * Math.PI) / 180;
const hav = (a, b, c, d) => { const h = Math.sin(rad(c - a) / 2) ** 2 + Math.cos(rad(a)) * Math.cos(rad(c)) * Math.sin(rad(d - b) / 2) ** 2; return 2 * 6371008.8 * Math.asin(Math.sqrt(h)); };
const fmt = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' });
const ET = (ms) => { if (ms == null) return null; const p = Object.fromEntries(fmt.formatToParts(new Date(ms)).map((x) => [x.type, x.value])); return `${p.year}-${p.month}-${p.day} ${p.hour}:${p.minute}:${p.second}`; };
const addDay = (d, n = 1) => new Date(Date.parse(d + 'T12:00:00Z') + n * 86400e3).toISOString().slice(0, 10);
// lib.mjs allTrips + stays: trips de-duplicated by start (the last given wins), sorted; a stay = the gap between two
// consecutive trips (g0 = arriving trip end, g1 = leaving trip start), kept when g1 > g0
const normTrips = (list) => { const by = new Map(); for (const t of list) by.set(t.s, t); return [...by.values()].sort((a, b) => a.s - b.s); };
const tripsToStays = (vid, ts) => { const out = []; for (let i = 0; i < ts.length - 1; i++) { const g0 = ts[i].e, g1 = ts[i + 1].s; if (g1 > g0) out.push({ vid, g0, g1, ec: ts[i].ec, sc: ts[i + 1].sc }); } return out; };

function runRule(inputs, knobs = {}) {
  for (const [k, v] of Object.entries(knobs)) if (!(k in BASE_KNOBS) || !Number.isFinite(v)) throw new Error(`knobs: unknown key or non-number ${k}=${JSON.stringify(v)}; allowed: ${Object.keys(BASE_KNOBS).join(' ')}`);
  const K = { ...BASE_KNOBS, ...knobs };
  const R = K.radius, MARGIN = K.margin, PRE = K.pre * 60e3, POST = K.post * 60e3, BUF = K.buffer, SEP = K.sep * 60e3, LOAD = K.load_h * 3600e3;
  const SILENCE = K.silence * 60e3, MOVE = K.move;

  // ---- inputs (d_sim3.mjs:61-91)
  const SAVED = new Map(inputs.saved.map((r) => [r.id, r]));
  const shapes = new Map();
  for (const [id, g0] of Object.entries(inputs.places ?? {})) {   // geofence only
    const g = g0 ?? {};
    if (g.circle) shapes.set(String(id), { c: [g.circle.latitude, g.circle.longitude, g.circle.radiusMeters] });
    else if (g.polygon) shapes.set(String(id), { v: g.polygon.vertices.map((x) => [x.latitude, x.longitude]) });
  }
  const V = inputs.visits.map((r) => ({
    id: r.id, band: r.band, date: r.visit_date, prop: r.property_id, client: r.client_id ?? null, truck: r.vehicle_id, tap: Date.parse(r.completed_at),
    w: [Date.parse(r.window.from), Date.parse(r.window.to)], q8: r.site.point?.from === 'q8_override',
    site: r.site.point || r.site.place_ids.length ? { pt: r.site.point ? [r.site.point.lat, r.site.point.lng] : null, pl: r.site.place_ids.map(String) } : null,
  })).sort((a, b) => a.id - b.id);
  const firstWrite = new Map((inputs.firstWrite ?? []).map((r) => [Number(r.id), r]));
  const timers = new Map();
  for (const r of inputs.timers ?? []) {
    if (!timers.has(Number(r.visit_id))) timers.set(Number(r.visit_id), []);
    timers.get(Number(r.visit_id)).push(Number(r.t));
  }
  const TRIPS = new Map(), STAYS = new Map();
  for (const [k, list] of Object.entries(inputs.trips)) { const t = Number(k), ts = normTrips(list); TRIPS.set(t, ts); STAYS.set(t, tripsToStays(t, ts)); }
  const TRUCKS = [...TRIPS.keys()].sort((a, b) => a - b);   // D: [1, 2, 3], the trucks with a Samsara device (lib.mjs SID)
  const allTrips = (t) => TRIPS.get(t);
  const stays = (t, from, to) => STAYS.get(t).filter((g) => g.g1 > from && g.g0 < to);
  // stored GPS fixes of a truck strictly inside (t0, t1): null until the caller has answered (d_sim3.mjs:92-103)
  const FX = inputs.fixes ?? {};
  const need = new Map();
  function fixes(truck, t0, t1) {
    const k = truck + '|' + t0 + '|' + t1;
    if (k in FX) return FX[k];
    need.set(k, [truck, t0, t1]);
    return null;
  }

  // ---- geometry: the 5.2 site (point within R, or a Place plus BUF) (d_sim3.mjs:119-148)
  function placeDist(id, lat, lng) {
    const s = shapes.get(id); if (!s) return Infinity;
    if (s.c) return Math.max(0, hav(lat, lng, s.c[0], s.c[1]) - s.c[2]);
    const kx = 6371008.8 * rad(1) * Math.cos(rad(lat)), ky = 6371008.8 * rad(1);   // local flat metres, origin = the point
    const P = s.v.map(([a, b]) => [(b - lng) * kx, (a - lat) * ky]);
    let inside = false, best = Infinity;
    for (let i = 0, j = P.length - 1; i < P.length; j = i++) {
      const [xi, yi] = P[i], [xj, yj] = P[j];
      if ((yi > 0) !== (yj > 0) && xi - (yi * (xj - xi)) / (yj - yi) > 0) inside = !inside;
      const dx = xj - xi, dy = yj - yi, L = dx * dx + dy * dy, u = L ? Math.max(0, Math.min(1, -(xi * dx + yi * dy) / L)) : 0;
      best = Math.min(best, Math.hypot(xi + u * dx, yi + u * dy));
    }
    return inside ? 0 : best;
  }
  const dPt = (s, lat, lng) => (s.pt ? hav(lat, lng, s.pt[0], s.pt[1]) : Infinity);
  const dPl = (s, lat, lng) => Math.min(Infinity, ...s.pl.map((id) => placeDist(id, lat, lng)));
  const at = (s, lat, lng, r = R, b = BUF) => dPt(s, lat, lng) <= r || dPl(s, lat, lng) <= b;
  const atC = (s, c) => !!c && at(s, c.latitude, c.longitude);
  const atF = (s, f) => at(s, f[1], f[2], FIX_R, FIX_BUF);
  const byPlace = (s, c) => !!c && dPt(s, c.latitude, c.longitude) > R && dPl(s, c.latitude, c.longitude) <= BUF;
  const dist = (s, c) => Math.min(dPt(s, c.latitude, c.longitude), dPl(s, c.latitude, c.longitude));
  const ends = (p) => [p.ec, p.sc].filter(Boolean);
  const nearer = (p, s) => Math.min(Infinity, ...ends(p).map((c) => dist(s, c)));                       // guard 3
  const meanD = (p, s) => (ends(p).length ? ends(p).reduce((t, c) => t + dist(s, c), 0) / ends(p).length : Infinity);   // guard 2
  const twoParks = (p) => !!(p.ec && p.sc) && hav(p.ec.latitude, p.ec.longitude, p.sc.latitude, p.sc.longitude) >= MOVE;

  // ---- visits whose window holds a time; guards 2 and 3 (d_sim3.mjs:150-167)
  const byDate = new Map();
  for (const v of V) if (v.site) { if (!byDate.has(v.date)) byDate.set(v.date, []); byDate.get(v.date).push(v); }
  const dayMemo = new Map();
  const dayOf = (t) => { if (!dayMemo.has(t)) dayMemo.set(t, ET(t).slice(0, 10)); return dayMemo.get(t); };
  const winHolds = (t) => [-1, 0, 1].flatMap((n) => byDate.get(addDay(dayOf(t), n)) ?? []).filter((x) => t >= x.w[0] && t < x.w[1]);
  const atOther = (p, v, t = p.a) => { const d = meanD(p, v.site); return winHolds(t).some((x) => x.prop !== v.prop && meanD(p, x.site) + MARGIN <= d); };
  const nearAt = (c, t, v) => { const d = dist(v.site, c); return winHolds(t).some((x) => x.prop !== v.prop && dist(x.site, c) + MARGIN <= d); };
  const clear = (p, v, t = p.a) => {
    if (twoParks(p) && ends(p).some((c) => nearAt(c, t, v))) return false;
    const d = nearer(p, v.site); return !winHolds(t).some((x) => x.prop !== v.prop && nearer(p, x.site) < d + MARGIN);
  };

  // ---- parts (d_sim3.mjs:169-198)
  function split(g, s, ea, sa, truck) {
    const held = { g0: g.g0, a: g.g0, d: g.g1, ec: g.ec, sc: g.sc, kind: 'held' };
    const fx = fixes(truck, g.g0, g.g1); if (fx === null) return held;
    const ok = fx.map((f, i) => atF(s, f) && (f[0] - (i ? fx[i - 1][0] : g.g0) < SILENCE || (fx[i + 1] ? atF(s, fx[i + 1]) : sa)));
    if (ea) {
      let last = -1, run = -1; for (let i = 0; i < fx.length && atF(s, fx[i]); i++) { run = i; if (ok[i]) last = i; }
      if (last < 0) return held;
      const f = fx[last];
      return { g0: g.g0, a: g.g0, d: f[0], ec: g.ec, sc: { latitude: f[1], longitude: f[2] }, kind: last < run ? 'split_end_stale_skipped' : 'split_end' };
    }
    let first = -1; for (let i = fx.length - 1; i >= 0 && atF(s, fx[i]); i--) if (ok[i]) first = i;
    if (first < 0) return held;
    const f = fx[first]; return { g0: g.g0, a: f[0], d: g.g1, ec: { latitude: f[1], longitude: f[2] }, sc: g.sc, kind: 'split_start' };
  }
  function partsFor(v, truck, past = false) {
    const out = [];
    for (const g of stays(truck, v.w[0] - 12 * 3600e3, v.w[1] + 12 * 3600e3)) {
      const ea = atC(v.site, g.ec), sa = atC(v.site, g.sc);
      if (!ea && !sa) continue;
      const p = ea && sa ? { g0: g.g0, a: g.g0, d: g.g1, ec: g.ec, sc: g.sc, kind: 'whole' } : split(g, v.site, ea, sa, truck);
      if (p.a >= v.w[0] && p.a < v.w[1]) out.push(p); else if (past && p.a >= v.w[1]) out.push({ ...p, past: true });
    }
    return out.sort((x, y) => x.a - y.a);
  }

  const blankLike = (b) => b.minutes == null || FALLBACK.has(b.source);
  // steps 6 to 8 on one "before" value (d_sim3.mjs:378-404)
  function decide(v, m, before, seen) {
    const o = { decision: null, hold_reason: null, hold_also: [], step7_big: false };
    const hold = (why) => (o.decision ? o.hold_also.push(why) : ((o.decision = 'hold'), (o.hold_reason = why)));
    if (blankLike(before) && seen.length) o.other_trucks = seen;
    if (v.tap < v.w[0] || v.tap >= v.w[1]) hold('other_day');
    if (m.status === 'held_both_ends') hold('both_ends');
    if (['several', 'no_free_stay', 'two_parkings', 'same_client_two_dates', 'contested_part'].includes(m.status)) hold(m.status);
    if (o.other_trucks) hold('another_truck');
    if (m.status === 'stay') {
      if (m.shared) hold('shared_stay');
      if (m.loads) hold('loads');
      o.diff = before.minutes == null ? null : m.min - before.minutes;
      if (o.diff != null && Math.abs(o.diff) >= 2 && !FALLBACK.has(before.source)) {
        o.step7_big = Math.abs(o.diff) > 15 || Math.abs(o.diff) > 0.5 * before.minutes;
        o.timer = (timers.get(v.id) ?? []).some((t) => Math.abs(t - m.a) <= 5 * 60e3);
        if (o.step7_big && !o.timer) hold('big_change');
      }
      o.same_as_before = o.diff != null && Math.abs(o.diff) < 2;
      if (!o.decision) o.decision = o.same_as_before ? 'keep' : 'write';
      if (o.decision === 'keep') o.keep_reason = 'within_2';
    }
    if (!o.decision) { o.decision = 'keep'; o.keep_reason = 'no_stay'; }
    return o;
  }

  // ---- one pass of the rule over every visit (d_sim3.mjs:200-376)
  function pass() {
    const claims = new Map(), tapHow = new Map(), parts1 = new Map(), tapsIn = new Map();
    const inside = (o, p) => o.tap >= p.a && o.tap <= p.d;
    for (const o of V) {
      if (!o.site || !TRIPS.has(o.truck)) continue;
      const all = partsFor(o, o.truck), ok = all.filter((p) => !atOther(p, o));
      parts1.set(o.id, { all, ok });
      for (const p of ok) if (inside(o, p)) { const k = o.truck + '|' + p.g0; if (!tapsIn.has(k)) tapsIn.set(k, []); tapsIn.get(k).push(o); }
    }
    const claim = (o, c) => { const k = o.truck + '|' + c.g0; if (!claims.has(k)) claims.set(k, []); claims.get(k).push(o.id); };
    const stepped = [];
    for (const o of V) {
      if (!parts1.has(o.id)) continue;
      const { all, ok } = parts1.get(o.id);
      const twoTaps = (p) => twoParks(p) && (tapsIn.get(o.truck + '|' + p.g0) ?? []).some((x) => x.prop !== o.prop);
      const P = ok.filter((p) => !twoTaps(p));
      const own = all.find((p) => inside(o, p));
      if (own && !P.includes(own)) { tapHow.set(o.id, ok.includes(own) ? 'refused_two_parkings' : 'refused_nearer'); continue; }
      const near = (p) => Math.min(Math.abs(p.a - o.tap), Math.abs(p.d - o.tap));
      const byNear = (L) => L.filter((p) => o.tap >= p.a - PRE && o.tap <= p.d + POST).sort((x, y) => near(x) - near(y) || x.a - y.a);
      const c = P.find((p) => inside(o, p)) ?? byNear(P)[0];
      const g7 = !own && byNear(ok)[0];
      if (g7 && twoTaps(g7)) { if (c) stepped.push([o, c]); else tapHow.set(o.id, 'refused_two_parkings'); continue; }
      tapHow.set(o.id, c ? (inside(o, c) ? 'inside' : 'near') : 'none');
      if (c) claim(o, c);
    }
    const propOf = new Map(V.map((v) => [v.id, v.prop]));
    const steppedOK = stepped.map(([o, c]) => [o, c, !(claims.get(o.truck + '|' + c.g0) ?? []).some((id) => propOf.get(id) !== o.prop)]);
    for (const [o, c, free] of steppedOK) { tapHow.set(o.id, free ? 'near' : 'refused_two_parkings'); if (free) claim(o, c); }
    const claimers = (truck, p) => claims.get(truck + '|' + p.g0) ?? [];
    const spans = new Map(), onceSpans = new Map();
    const addSpan = (S, v, g0s) => { for (const g of g0s) { const k = v.truck + '|' + g; if (!S.has(k)) S.set(k, []); S.get(k).push(v.id); } };
    const inSpan = (S, v, p, ok = () => true) => (S.get(v.truck + '|' + p.g0) ?? []).some((id) => id !== v.id && ok(id));
    const claimed = new Set([...claims.values()].flat());

    function measure(v, taken = () => false) {
      const A = partsFor(v, v.truck, true), nIn = A.filter((p) => !p.past).length;
      if (!nIn) return { status: 'no_stay' };
      const G = stays(v.truck, v.w[0] - 12 * 3600e3, v.w[1] + 12 * 3600e3);
      const stopAway = (x0, x1) => G.some((g) => g.g0 >= x0 && g.g1 <= x1 && !atC(v.site, g.ec) && !atC(v.site, g.sc));
      const other = (p) => claimers(v.truck, p).some((id) => id !== v.id);
      const free = (i, t = A[i].a) => !other(A[i]) && clear(A[i], v, t);
      const leftOK = (x, y) => { const f = fixes(v.truck, x.d, y.a); return f === null || f.every((q) => atF(v.site, q)); };
      const link = (i, j) => A[j].a - A[i].d <= SEP && leftOK(A[i], A[j]);
      let basis = 'tap', lo, hi;
      const own = A.findIndex((p) => claimers(v.truck, p).includes(v.id));
      if (own >= 0) {
        lo = own; hi = own;
        const after = (t) => { for (let j = lo; j <= hi; j++) if (j === own ? atOther(A[j], v, t) : !free(j, t)) return false; return true; };
        if (A[own].kind !== 'held') {
          while (lo > 0 && free(lo - 1) && link(lo - 1, lo) && after(A[lo - 1].a)) { lo--; if (A[lo].kind === 'held') break; }
          while (A[lo].kind !== 'held' && hi < A.length - 1 && free(hi + 1, A[lo].a) && link(hi, hi + 1)) { hi++; if (A[hi].kind === 'held') break; }
        }
      } else {
        if (tapHow.get(v.id) === 'refused_two_parkings') return { status: 'two_parkings', n: nIn };
        basis = 'went_once';
        const groups = []; let cur = null;
        for (let i = 0; i < A.length; i++) {
          if (taken(A[i])) { cur = null; continue; }
          const adj = !!cur && cur.hi === i - 1, fFirst = adj && free(i, A[cur.lo].a), fOwn = free(i);
          const later = adj && (fFirst || fOwn) && link(i - 1, i);
          if (!(later ? fFirst : fOwn)) { cur = null; continue; }
          if (later) cur.hi = i; else if (A[i].past) cur = null; else groups.push((cur = { lo: i, hi: i }));
        }
        if (!groups.length) return { status: 'no_free_stay', n: nIn };
        if (groups.length > 1) return { status: 'several', n: groups.length };
        ({ lo, hi } = groups[0]);
      }
      const P = A.slice(lo, hi + 1), a = A[lo].a, d = A[hi].d;
      const r = { basis, parts: P.length, kinds: [...new Set(P.map((p) => p.kind))].sort(), a, d, g0s: P.map((p) => p.g0),
        site_by: v.q8 ? 'q8_point' : P.some((p) => byPlace(v.site, p.ec) || byPlace(v.site, p.sc)) ? 'place' : 'point' };
      if (P.some((p) => p.kind === 'held')) return { status: 'held_both_ends', ...r };
      r.shared = P.some(other);
      r.loads = A.some((p, i) => {
        if (i >= lo && i <= hi || p.past || !free(i) || p.kind === 'held') return false;
        const [x0, x1] = p.a > d ? [d, p.a] : [p.d, a];
        return x1 - x0 <= LOAD && stopAway(x0, x1);
      });
      return { status: 'stay', min: Math.round((d - a) / 60e3), ...r };
    }

    const rows = [], todo = [];
    for (const v of V) {
      const sv = SAVED.get(v.id);
      const fw = v.band !== 'A' ? firstWrite.get(v.id) : null;
      const before = fw ? { minutes: fw.old_min == null ? null : Number(fw.old_min), source: fw.old_src ?? null, from: 'audit_first_recheck' }
        : { minutes: sv.duration_minutes, source: sv.time_on_site_source, from: 'live' };
      const led = [...(sv.ledger ?? [])].sort((x, y) => x.id - y.id).pop() ?? null;
      const row = { id: v.id, band: v.band, before, live: { minutes: sv.duration_minutes, source: sv.time_on_site_source }, ledger_method: led?.method ?? null,
        tap: tapHow.get(v.id) ?? null, rule: { status: null }, decision: null, hold_reason: null, hold_also: [], step7_big: false };
      const hold = (why) => (row.decision ? row.hold_also.push(why) : ((row.decision = 'hold'), (row.hold_reason = why)));
      rows.push(row);
      if (!v.site) { row.rule.status = 'no_site'; hold('no_site'); continue; }
      if (v.truck == null) { row.rule.status = 'no_truck'; hold('no_truck'); continue; }
      if (!TRIPS.has(v.truck)) { row.rule.status = 'no_samsara_device'; row.decision = 'no_data'; continue; }
      const ts = allTrips(v.truck), last = ts[ts.length - 1];
      if (!ts.some((t) => t.e > v.w[0] && t.s < v.w[1])) {
        const f = fixes(v.truck, v.w[0], v.w[1]);
        if (f !== null && !f.length) { row.rule.status = 'no_data'; row.decision = 'no_data'; continue; }
      }
      if (!last || (last.e >= v.w[0] && last.e < v.w[1] && atC(v.site, last.ec)) || v.tap > last.e) { row.rule.status = 'open'; row.decision = 'pending'; continue; }
      todo.push([v, row, sv, before, fw]);
    }
    // steps 4 and 5 in three looks, then ruling 45 (d_sim3.mjs:328-359)
    const VB = new Map(V.map((x) => [x.id, x])), M = new Map(), first = new Map();
    const sameClient = (x, v) => x.client != null && x.client === v.client;
    for (const [v] of todo) if (claimed.has(v.id)) { const m = measure(v); M.set(v.id, m); if (m.basis === 'tap') addSpan(spans, v, m.g0s); }
    for (const [v] of todo) if (!claimed.has(v.id)) {
      const m = measure(v, (p) => inSpan(spans, v, p));
      first.set(v.id, m); if (m.basis === 'went_once') addSpan(onceSpans, v, m.g0s);
    }
    for (const [v] of todo) if (!claimed.has(v.id)) {
      const sameDay = (id) => first.get(v.id).basis === 'went_once' && sameClient(VB.get(id), v) && VB.get(id).date === v.date;
      M.set(v.id, measure(v, (p) => inSpan(spans, v, p) || inSpan(onceSpans, v, p, (id) => !sameDay(id))));
    }
    const want = new Map();
    for (const [v] of todo) for (const m of [M.get(v.id), first.get(v.id)]) if (m?.g0s) addSpan(want, v, m.g0s);
    const whole = (x, y, k) => x.date === y.date && (sameClient(x, y) || [x.id, y.id].every((id) => (claims.get(k) ?? []).includes(id)));
    const rivals = new Map();
    for (const [k, L] of want) for (const a of new Set(L)) for (const b of new Set(L))
      if (a !== b && !whole(VB.get(a), VB.get(b), k)) { if (!rivals.has(a)) rivals.set(a, new Set()); rivals.get(a).add(b); }
    for (const [id, others] of rivals) {
      const w = [...others].sort((a, b) => a - b), v = VB.get(id);
      M.set(id, { status: w.every((o) => sameClient(VB.get(o), v)) ? 'same_client_two_dates' : 'contested_part', with: w });
    }
    for (const [v, row, sv, before, fw] of todo) {
      const m = M.get(v.id);
      row.rule = { status: m.status };
      // arrival_ms / departure_ms: the only addition to D's row, so the caller writes the instants without parsing ET text
      if (m.a != null) Object.assign(row.rule, { arrival_et: ET(m.a), departure_et: ET(m.d), minutes: m.min ?? null, basis: m.basis, parts: m.parts, kinds: m.kinds, site_by: m.site_by, arrival_ms: m.a, departure_ms: m.d });
      if (m.n) row.rule.n = m.n;
      if (m.with) row.rule.with = m.with;
      const live = { minutes: sv.duration_minutes, source: sv.time_on_site_source };
      const seen = [];
      if (blankLike(before) || blankLike(live))
        for (const t2 of TRUCKS) if (t2 !== v.truck) for (const p of partsFor(v, t2)) if (!claimers(t2, p).length && clear(p, v)) { seen.push(t2); break; }
      Object.assign(row, decide(v, m, before, seen));
      if (fw) { const x = decide(v, m, live, seen); row.on_live = { decision: x.decision, hold_reason: x.hold_reason }; }
    }
    return rows.sort((x, y) => x.id - y.id);
  }

  const rows = pass();
  const needFixes = [...need.keys()].sort().map((key) => { const [truck, t0, t1] = need.get(key); return { key, truck, t0, t1 }; });
  if (needFixes.length) return { rows: null, needFixes };   // D discards a pass that raised questions (d_sim3.mjs:409-415)
  // PLAN 5.5 (a): a band B / C visit whose live source is locked is never a candidate (d_sim3.mjs:416-421)
  for (const r of rows) if (r.band !== 'A' && LOCK_SRC.has(r.live.source)) {
    r.unlocked = { decision: r.decision, hold_reason: r.hold_reason };
    Object.assign(r, { decision: 'locked', hold_reason: null, hold_also: [], lock: 'source:' + r.live.source });
  }
  return { rows, needFixes };
}

return { runRule, normTrips, tripsToStays, BASE_KNOBS };
})();
// ==== END rule.mjs ====
// ==== BEGIN site.mjs (sha256 e48d43d996221021701dcac77cc21ab6950c6bcd5faba2621d715d3ffdc86944; inlined by v15/build_index.mjs, do not edit here) ====
const V15SITE = (() => {
// v15 site builder: a port of build_phase0.mjs site() (Phase 0, the sites the judges and D were fed), taking the live
// inputs instead of the frozen files: the read RPC's JSON (public.fn_time_on_site_recheck_visits) and the Samsara Places
// (/addresses, {id, latitude, longitude, geofence: {circle | polygon}}). Pure: no I/O. Output rows have the
// visits_judge.json shape (id, visit_date, client_id, property_id, other_live_properties, site, vehicle_id, completed_at,
// window {from, to}), plus the live fields the nightly needs (truck_samsara_id, saved, locked, in_range).
// Overrides come from public.time_on_site_site_overrides (Fred's Q8): spot replaces the map point; place_id swaps the
// linked Places (and names it); place_unlink drops them; extra_place_id adds one.
const R = 6371000, rad = (x) => (x * Math.PI) / 180;
function metres(a, b) {
  const dLat = rad(b.lat - a.lat), dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}
function insideShape(pt, place) {
  const gf = place.geofence || {};
  if (gf.circle) return metres(pt, { lat: gf.circle.latitude, lng: gf.circle.longitude }) <= gf.circle.radiusMeters;
  const vs = (gf.polygon && gf.polygon.vertices) || []; let inside = false;
  for (let i = 0, j = vs.length - 1; i < vs.length; j = i++) {
    const xi = vs[i].longitude, yi = vs[i].latitude, xj = vs[j].longitude, yj = vs[j].latitude;
    if ((yi > pt.lat) !== (yj > pt.lat) && pt.lng < (xj - xi) * (pt.lat - yi) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}
const iso = (ms) => (ms == null ? null : new Date(ms).toISOString().replace('Z', '+00:00'));

function buildRows(read, places) {
  const placeById = new Map(places.map((p) => [String(p.id), p]));
  const latestVerdict = new Map(read.place_verdicts.map((r) => [String(r.place_id), r]));
  const norm = (id) => String(id).replace(/^addr_/, '');   // 33 links are stored as 'addr_<id>'
  const propLinks = new Map(), clientLinks = new Map();
  for (const l of read.place_links) {
    const m = l.entity_type === 'property' ? propLinks : clientLinks;
    if (!m.has(l.entity_id)) m.set(l.entity_id, new Set());
    m.get(l.entity_id).add(norm(l.place_id));
  }
  const props = new Map(read.properties.map((p) => [p.id, p]));
  const ovr = new Map(read.overrides.map((o) => [o.property_id, o]));
  function site(propertyId, clientId) {
    const p = propertyId != null ? props.get(propertyId) : null;
    if (propertyId != null && !p) return null;
    const o = propertyId != null ? ovr.get(propertyId) : null;
    const point = o && o.spot ? { lat: o.spot.lat, lng: o.spot.lng, from: 'q8_override' } : (p && p.lat != null ? { lat: p.lat, lng: p.lng, from: 'map_point' } : null);
    let linked = [...new Set([...(propertyId != null ? (propLinks.get(propertyId) || []) : []), ...(clientLinks.get(clientId ?? (p && p.client_id)) || [])])];
    const dropped = [];
    if (o && o.place_unlink) linked = [];
    else if (o && o.place_id) linked = [String(o.place_id)];
    const named = new Set([o && o.place_id, o && o.extra_place_id].filter(Boolean).map(String));
    const keep = [];
    for (const id of linked) {
      const v = latestVerdict.get(id);
      if (v && v.verdict === 'moved' && !named.has(id)) { dropped.push({ place_id: id, reason: 'moved', distance_m: v.distance_m }); continue; }
      const g = placeById.get(id);
      if (point && g && !named.has(id) && !insideShape(point, g) && metres(point, { lat: g.latitude, lng: g.longitude }) > 150) {
        dropped.push({ place_id: id, reason: 'far_from_this_property', distance_m: Math.round(metres(point, { lat: g.latitude, lng: g.longitude })) }); continue;
      }
      keep.push(id);
    }
    if (o && o.extra_place_id) keep.push(String(o.extra_place_id));
    return { point, place_ids: keep.filter((id) => placeById.has(id)), dropped_moved: dropped,
             place_ids_not_in_snapshot: keep.filter((id) => !placeById.has(id)), q8: o ? (o.decision_ref ?? 'q8') : null };
  }
  const others = (cid) => read.properties.filter((p) => p.client_id === cid);
  return read.visits.map((v) => ({
    id: v.id, visit_date: v.visit_date, client_id: v.client_id, property_id: v.property_id,
    other_live_properties: others(v.client_id).filter((x) => x.id !== v.property_id).map((x) => ({ property_id: x.id, is_billing: !!x.is_billing, site: site(x.id, v.client_id) })),
    site: v.property_id == null ? { no_site: 'no_property', point: null, place_ids: [], dropped_moved: [], place_ids_not_in_snapshot: [], q8: null } : site(v.property_id, v.client_id),
    vehicle_id: v.vehicle_id, completed_at: iso(v.completed_ms), window: { from: iso(v.window[0]), to: iso(v.window[1]) },
    truck_samsara_id: v.truck_samsara_id, saved: v.saved, locked: v.locked, in_range: v.in_range,
  }));
}

return { buildRows, metres, insideShape };
})();
// ==== END site.mjs ====
// ==== BEGIN closeout.mjs (sha256 46d3f575cdd1b0e8ea2b235c528163c2c62d2d5887f7ee57ba42b25eda8e2097; inlined by v15/build_index.mjs, do not edit here) ====
const V15CLOSE = (() => {
const { metres, insideShape } = V15SITE;
// v15 close-out classifier (plan 5.5 b): at a visit's last look (day 10), what ledger row it gets. Pure: no I/O.
// classifyCloseout(v, r, ctx) -> null (no row: the visit is locked) or { status, action, method, confidence, evidence }
//   v   the visit row (v15/site.mjs buildRows): site, other_live_properties, vehicle_id, window, completed_at, saved, stops_500m
//   r   its rule row (v15/rule.mjs runRule): decision, hold_reason, keep_reason, rule {arrival_ms, departure_ms, minutes}
//   ctx { save: {ok, reason} | undefined (this run's save of this visit), placesOk, trips: {vid: [{s, e, sc, ec}] sorted},
//         stays: {vid: [{g0, g1, ec, sc}]}, taps: [{id, vehicle_id, ms}] (the night's completed visits), places: {id: geofence} }
// Applied rows are only: keep_verified / nightly_self (the rule agrees, or this run saved its value) and
// blank / no_samsara_presence (all six data tests pass). Everything else is proposed, for a person.
const DAY = 86400e3;
// ponytail: the "a truck stayed at the site" tests use a site wider than the rule's (point 300 m; a Place's enclosing
// circle + 80 m), so a decided blank errs to "proposed". Upgrade path: export the rule's own at() if blanks pile up.
function near(site, c, places) {
  if (!c || !site) return false;
  const p = { lat: c.latitude, lng: c.longitude };
  if (site.point && metres(p, site.point) <= 300) return true;
  for (const id of site.place_ids ?? []) {
    const g = places[id]; if (!g) continue;
    if (g.circle && metres(p, { lat: g.circle.latitude, lng: g.circle.longitude }) <= g.circle.radiusMeters + 80) return true;
    const vs = g.polygon?.vertices;
    if (vs?.length) {
      if (insideShape(p, { geofence: g })) return true;
      const cen = { lat: vs.reduce((t, x) => t + x.latitude, 0) / vs.length, lng: vs.reduce((t, x) => t + x.longitude, 0) / vs.length };
      const rad = Math.max(...vs.map((x) => metres(cen, { lat: x.latitude, lng: x.longitude })));
      if (metres(p, cen) <= rad + 80) return true;
    }
  }
  return false;
}
const stayAt = (site, ss, t0, t1, places) => (ss ?? []).some((g) => g.g1 > t0 && g.g0 < t1 && (near(site, g.ec, places) || near(site, g.sc, places)));
const ev = (r, extra = {}) => ({ decision: r.decision, hold_reason: r.hold_reason ?? null, keep_reason: r.keep_reason ?? null,
  rule: r.rule && r.rule.arrival_ms != null ? { arrival_ms: r.rule.arrival_ms, departure_ms: r.rule.departure_ms, minutes: r.rule.minutes, basis: r.rule.basis, site_by: r.rule.site_by } : null, ...extra });
const proposed = (method, r, extra) => ({ status: 'proposed', action: 'keep_verified', method, confidence: 'person', evidence: ev(r, extra) });

function classifyCloseout(v, r, ctx) {
  if (v.locked || r.decision === 'locked') return null;
  const w0 = Date.parse(v.window.from), w1 = Date.parse(v.window.to);
  if (r.decision === 'write') {
    if (ctx.save && ctx.save.ok) return { status: 'applied', action: 'keep_verified', method: 'nightly_self', confidence: 'medium', evidence: ev(r, { saved_this_run: true }) };
    return proposed('save_refused', r, { save_reason: ctx.save ? ctx.save.reason : 'not_saved' });
  }
  if (r.decision === 'keep' && r.keep_reason === 'within_2') {
    // no other completed visit's tap inside the same stay (D's shared_stay only sees another visit's claim)
    const a = r.rule?.arrival_ms, d = r.rule?.departure_ms;
    const other = (ctx.taps ?? []).find((t) => t.id !== v.id && t.vehicle_id === v.vehicle_id && a != null && t.ms >= a && t.ms <= d);
    if (other) return proposed('shared_tap', r, { other_visit: other.id });
    return { status: 'applied', action: 'keep_verified', method: 'nightly_self', confidence: 'medium', evidence: ev(r) };
  }
  if (r.decision === 'keep' && r.keep_reason === 'no_stay' && v.saved?.minutes != null) return proposed('no_stay', r);
  if (r.decision === 'keep' && r.keep_reason === 'no_stay') {
    // the six data tests for a decided blank (plan 5.5 b)
    if (!v.site || (!v.site.point && !(v.site.place_ids ?? []).length)) return { ...proposed('no_site', r), action: 'blank' };
    const ts = ctx.trips?.[v.vehicle_id] ?? [];
    const before = ts.some((t) => t.e <= w0), after = ts.some((t) => t.s >= w1), inside = ts.some((t) => t.s < w1 && t.e > w0);
    if (ctx.tripsOk === false) return { ...proposed('no_data', r, { trip_read_failed: true }), action: 'blank' };   // a truck's trips unread: fail closed
    if (!(inside || (before && after))) return { ...proposed('no_data', r), action: 'blank' };                                   // 1
    if (stayAt(v.site, ctx.stays?.[v.vehicle_id], w0 - 3 * DAY, w1 + 3 * DAY, ctx.places)) return { ...proposed('other_day', r), action: 'blank' }; // 2
    for (const [vid, ss] of Object.entries(ctx.stays ?? {}))                                                                       // 3
      if (Number(vid) !== v.vehicle_id && stayAt(v.site, ss, w0, w1, ctx.places)) return { ...proposed('another_truck', r, { truck: Number(vid) }), action: 'blank' };
    if ((v.stops_500m ?? []).length) return { ...proposed('far_park', r, { stops_500m: v.stops_500m }), action: 'blank' };         // 4
    if (!ctx.placesOk || (v.site.dropped_moved ?? []).some((x) => x.reason === 'moved')) return { ...proposed('site_unsure', r), action: 'blank' }; // 5
    for (const o of v.other_live_properties ?? [])                                                                                   // 6
      for (const ss of Object.values(ctx.stays ?? {})) if (stayAt(o.site, ss, w0, w1, ctx.places)) return { ...proposed('wrong_property', r, { property: o.property_id }), action: 'blank' };
    return { status: 'applied', action: 'blank', method: 'no_samsara_presence', confidence: 'medium', evidence: ev(r) };
  }
  if (r.decision === 'hold') return proposed(r.hold_reason || 'held', r);
  return proposed(r.decision === 'pending' ? 'pending' : r.decision === 'no_data' ? 'no_data' : 'unsettled', r);
}

return { classifyCloseout };
})();
// ==== END closeout.mjs ====
// ===================================================================================================================
// v15, rules: 2 (plan 5.2, spec docs/specs/2026-11-02-time-on-site-nightly-rule.md section 7). Starts from the VISIT:
// every completed client visit of the window that is not locked; its truck's Samsara trips; the reviewed site (point
// within 250 m or a linked Place + 40 m, Fred's Q8 overrides, a "moved" Place dropped); the rule V15.runRule, which is
// v15/rule.mjs inlined and equal to the re-check's judge D on all 1,452 visits of 2026 (v15/equiv_test.mjs). Saves go
// through public.fn_save_time_on_site_stay (server re-checks: not locked, unchanged, in the window, our own GPS at both
// ends inside the same site). At day 10 the close-out writes one ledger row per visit (public.fn_close_time_on_site).
// Only with rules: 2; rules: 1 (the default, until Fred's flip) is the v14 code above, unchanged.
// ===================================================================================================================
const HOUR = 3600e3;
const iso = (ms) => (ms == null ? null : new Date(ms).toISOString());
async function samsaraGet(path, token) {
  for (let a = 1; a <= 6; a++) {
    let r = null;
    try { r = await fetch(`https://api.samsara.com${path}`, { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } }); } catch { r = null; }
    if (r && r.ok && (r.headers.get("content-type") ?? "").includes("json")) return await r.json();
    if (r && r.status !== 429 && r.status < 500) throw new Error(`samsara ${path.split("?")[0]}: HTTP ${r.status}`);
    const ra = r && r.status === 429 ? Number(r.headers.get("retry-after")) : NaN;
    await new Promise((res) => setTimeout(res, Number.isFinite(ra) && ra > 0 ? ra * 1000 : Math.min(20e3, 1000 * 2 ** (a - 1))));
  }
  throw new Error(`samsara ${path.split("?")[0]}: gave up after 6 tries`);
}
// the Places (geofences), one live read per run; null = the read failed (fail closed: no Place-only stay, no decided blank)
async function placesLive(token) {
  try {
    const out = []; let after = "";
    for (let page = 0; page < 20; page++) {
      const j = await samsaraGet(`/addresses?limit=512${after ? `&after=${encodeURIComponent(after)}` : ""}`, token);
      for (const a of j.data ?? []) if (a?.id && a.geofence) out.push({ id: String(a.id), latitude: a.latitude, longitude: a.longitude, geofence: a.geofence });
      if (!j.pagination?.hasNextPage) return out;
      after = j.pagination.endCursor;
    }
    return null;   // more than 20 pages: not a complete read
  } catch { return null; }
}
async function tripsLive(samsaraId, startMs, endMs, token) {
  const j = await samsaraGet(`/v1/fleet/trips?vehicleId=${encodeURIComponent(samsaraId)}&startMs=${startMs}&endMs=${endMs}`, token);
  return (j.trips ?? []).filter((t) => Number.isFinite(t.startMs) && Number.isFinite(t.endMs))
    .map((t) => ({ s: t.startMs, e: t.endMs, sc: t.startCoordinates ?? null, ec: t.endCoordinates ?? null }));
}
// the site a save is checked against (the save caps a Place at 600 m and a point at 250 m)
function saveSites(v, r, places) {
  const s = v.site;
  if (r.rule.site_by !== "place") return s.point ? [{ lat: s.point.lat, lng: s.point.lng, r_m: 250, kind: "point" }] : [];
  const out = [];
  for (const id of s.place_ids ?? []) {
    const g = places[id]; if (!g) continue;
    if (g.circle) out.push({ lat: g.circle.latitude, lng: g.circle.longitude, r_m: g.circle.radiusMeters + 40, kind: "place" });
    else if (g.polygon?.vertices?.length) {
      const vs = g.polygon.vertices, cen = { lat: vs.reduce((t, x) => t + x.latitude, 0) / vs.length, lng: vs.reduce((t, x) => t + x.longitude, 0) / vs.length };
      out.push({ lat: cen.lat, lng: cen.lng, r_m: Math.max(...vs.map((x) => V15SITE.metres(cen, { lat: x.latitude, lng: x.longitude }))) + 40, kind: "place" });
    }
  }
  return out.filter((x) => x.r_m <= 600);
}

async function recheck2(from, to, dryRun, token, opts) {
  const read = await rpc("fn_time_on_site_recheck_visits", { p_from: from, p_to: to });
  let placesRaw = opts.place_shapes, placesOk = true;
  if (!placesRaw) { placesRaw = await placesLive(token); if (!placesRaw) { placesOk = false; placesRaw = []; } }
  const rows = V15SITE.buildRows(read, placesRaw);
  const places = Object.fromEntries(placesRaw.map((p) => [String(p.id), p.geofence]));
  const counts = { visits: rows.length, candidates: 0, write: 0, keep: 0, hold: 0, no_data: 0, pending: 0, locked: 0, saved: 0, refused: 0,
                   places_ok: placesOk, trip_reads_failed: 0, rule_passes: 0, fixes_asked: 0 };
  if (!rows.length) return { from, to, dry_run: dryRun, rules: 2, counts, candidates: [], closeout: null };
  const w0 = Math.min(...rows.map((r) => Date.parse(r.window.from))), w1 = Math.max(...rows.map((r) => Date.parse(r.window.to)));
  const trips = {};
  for (const t of read.trucks) {
    try { trips[t.vehicle_id] = V15.normTrips(await tripsLive(t.samsara_id, w0 - 72 * HOUR, Math.min(Date.now(), w1 + 36 * HOUR), token)); }
    catch { counts.trip_reads_failed++; }   // a missing truck reads as no data: never "no stay"
  }
  const inputs = {
    visits: rows.map((r) => ({ ...r, band: "N" })),
    saved: rows.map((r) => ({ id: r.id, duration_minutes: r.saved.minutes, time_on_site_source: r.saved.source, ledger: [] })),
    places, trips, firstWrite: [], timers: read.timers.map((t) => ({ visit_id: t.visit_id, t: t.started_ms })), fixes: {},
  };
  let out = null;
  for (let pass = 1; ; pass++) {
    if (pass > 7) throw new Error("the rule's stored-GPS questions did not settle in 7 passes");
    out = V15.runRule(inputs, {}); counts.rule_passes = pass;
    if (!out.needFixes?.length) break;
    for (let i = 0; i < out.needFixes.length; i += 300) {
      const chunk = out.needFixes.slice(i, i + 300);
      const ans = await rpc("fn_time_on_site_recheck_fixes", { p_requests: chunk.map((n) => ({ vehicle_id: n.truck, from_ms: n.t0, to_ms: n.t1 })) });
      chunk.forEach((n, k) => { inputs.fixes[n.key] = ans[k]; });
      counts.fixes_asked += chunk.length;
    }
  }
  const byId = new Map(out.rows.map((x) => [x.id, x]));
  const candidates = [], saves = new Map();
  for (const v of rows.filter((x) => x.in_range)) {
    const r = byId.get(v.id);
    const decision = v.locked && !opts.include_ledger ? "locked" : r.decision;   // the ledger lock (plan 5.5 a, Fred's Q-E)
    counts.candidates++; counts[decision] = (counts[decision] ?? 0) + 1;
    const item = { visit_id: v.id, saved: v.saved, decision, hold_reason: r.hold_reason ?? null, keep_reason: r.keep_reason ?? null,
      rule: r.rule?.arrival_ms != null ? { arrival: iso(r.rule.arrival_ms), departure: iso(r.rule.departure_ms), minutes: r.rule.minutes,
        basis: r.rule.basis, parts: r.rule.parts, site_by: r.rule.site_by } : { status: r.rule?.status ?? null } };
    if (decision === "write" && !dryRun) {
      let res = { ok: false, reason: "no_site_to_check" };
      for (const site of saveSites(v, r, places)) {
        res = await rpc("fn_save_time_on_site_stay", { p_visit_id: v.id, p_arrival: iso(r.rule.arrival_ms), p_departure: iso(r.rule.departure_ms),
          p_expected_minutes: v.saved.minutes, p_expected_source: v.saved.source, p_basis: r.rule.parts > 1 ? `${r.rule.basis}_span` : r.rule.basis, p_site: site });
        if (res.ok || res.reason !== "stored_fix_outside_site") break;
      }
      saves.set(v.id, res); item.save = res; res.ok ? counts.saved++ : counts.refused++;
    }
    candidates.push(item);
  }
  // the close-out (plan 5.5 b): only a real run of rules 2, for the visits dated `from` (their last look), not locked
  let closeout = null;
  if (!dryRun) {
    const stays = Object.fromEntries(Object.entries(trips).map(([vid, ts]) => [vid, V15.tripsToStays(Number(vid), ts)]));
    const taps = rows.map((x) => ({ id: x.id, vehicle_id: x.vehicle_id, ms: Date.parse(x.completed_at) }));
    const ctx0 = { placesOk, tripsOk: counts.trip_reads_failed === 0, trips, stays, taps, places };
    const payload = [];
    for (const v of rows.filter((x) => x.in_range && x.visit_date === from && !x.locked)) {
      const c = V15CLOSE.classifyCloseout(v, byId.get(v.id), { ...ctx0, save: saves.get(v.id) });
      if (!c) continue;
      payload.push({ visit_id: v.id, status: c.status, action: c.action, method: c.method, confidence: c.confidence, evidence: c.evidence,
        old: { minutes: v.saved.minutes, arrival_ms: v.saved.arrival_ms, departure_ms: v.saved.departure_ms, source: v.saved.source } });
    }
    closeout = payload.length ? await rpc("fn_close_time_on_site", { p_rows: payload, p_run_date: from }) : { inserted: 0, already_closed: 0, refused: [] };
    closeout.rows = payload.map((p) => ({ visit_id: p.visit_id, status: p.status, action: p.action, method: p.method }));
  }
  return { from, to, dry_run: dryRun, rules: 2, include_ledger: !!opts.include_ledger, counts, candidates, closeout };
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
  // v15 switch (plan 5.2): rules 1 = the v14 rule, the default; rules 2 = the new rule
  if (body?.rules !== undefined && body.rules !== 1 && body.rules !== 2) return json({ error: "rules must be 1 or 2" }, 400);
  const rules = body?.rules === 2 ? 2 : 1;
  const includeLedger = body?.include_ledger === true;
  const placeShapes = Array.isArray(body?.place_shapes) ? body.place_shapes : null;
  if ((includeLedger || placeShapes) && (!dryRun || rules !== 2)) return json({ error: "include_ledger and place_shapes need dry_run: true and rules: 2" }, 400);
  const startedAt = new Date().toISOString();
  const token = Deno.env.get("SAMSARA_API_TOKEN");
  if (!token) {
    if (!dryRun) await logRun(startedAt, false, { error: "no Samsara token", counts: { saved: 0 } });
    return json({ error: "no Samsara token" }, 500);
  }
  try {
    const out = rules === 2 ? await recheck2(from, to, dryRun, token, { include_ledger: includeLedger, place_shapes: placeShapes })
                            : await recheck(from, to, dryRun, token);
    if (!dryRun) await logRun(startedAt, true, rules === 2 ? { ...out, candidates: out.candidates.slice(0, 400) } : { ...out, changes: out.changes.slice(0, 200) });
    return json(out);
  } catch (e) {
    if (!dryRun) await logRun(startedAt, false, { error: String(e), counts: { saved: 0 } });
    return json({ error: String(e) }, 500);
  }
});
