// time-on-site-reminder: once a day at 11 AM Eastern, tells #apps-notifications which of yesterday's client visits
// have no time on site, and why, so the place or the truck can be fixed in Samsara.
//
// Yannick, huddle 2026-10-12: daily alerts of visits without a recorded duration "so adjustments can be made in
// Samsara". Fred, 2026-10-12: "build the daily alert for visits without duration ... make it look and good simple";
// he picked Option A of the mockups (one line per visit with its reason) and "tag Diego". Format:
// docs/reference/slack-notifications.md. Migration: docs/migrations/2026-10-13_0130_time_on_site_reminder.sql.
//
// AUTH: verify_jwt=true (pinned in config.toml) PLUS an in-handler service_role gate. Invoked by
// public.fn_request_time_on_site_reminder() from pg_cron `time-on-site-reminder` (15:00 and 16:00 UTC; the wrapper
// lets through only the run that is 11 AM in New York, and re-runs the time-on-site fills first).
// Reads public.fn_time_on_site_gaps(date): the visits (completed, live, customers, duration_minutes NULL) and the GPS
// facts behind each. Samsara Place geometry is not in our database, so it is read here from Samsara (/addresses);
// if that read fails, the place-based reasons are left out, never guessed (guide rule 5).
// Posts NOTHING when yesterday has no such visit. Every run (not a dry run, not check_bot) writes ONE public.sync_log
// row: sync_source 'time_on_site_reminder' ('time_on_site_reminder_test' for a [TEST] run), status 'success' (posted,
// or nothing to post) or 'error'. Diego is tagged on the first body line, never on a [TEST] post, never in `text`.
// Body: { dry_run?: boolean, test?: boolean, check_bot?: boolean, date?: "YYYY-MM-DD" }  date defaults to yesterday ET.
// Check: node scripts/checks/time_on_site_reminder.mjs (runs this file against stubs).

import { slackHeader, slackIdentity, slackScopes, slackSections } from "../_shared/slack-notify.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CHANNEL = Deno.env.get("TIME_ON_SITE_REMINDER_CHANNEL_ID") ?? "C0BJYHQKZM1"; // #apps-notifications
const ORG = "6009037";
const DIEGO = "<@U0AL9JZ4V7C>";
const MAX_LINES = 40;
const NEAR_M = 150;
const SOURCE = "time_on_site_reminder";
const ET = "America/New_York";

type Stay = { truck: string; truck_samsara_id: string | null; first: string; last: string; minutes: number };
type Gap = {
  visit_id: number; visit_date: string; client_code: string | null; client_name: string | null; service: string | null;
  completed_at: string | null; lat: number | null; lng: number | null;
  truck: string | null; truck_samsara_id: string | null;
  property_place_id: string | null; client_place_ids: string[];
  closest: { truck: string; truck_samsara_id: string | null; meters: number; at: string } | null;
  stays: Stay[];
};
type Place = { id: string; name: string; lat: number; lng: number };
type Outcome = { code: number; reply: Record<string, unknown>; log: Record<string, unknown> };

const json = (p: unknown, status = 200) =>
  new Response(JSON.stringify(p), { status, headers: { "Content-Type": "application/json" } });

function bearerRole(req: Request): string | null {
  try {
    const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(tok.split(".")[1] ?? ""))?.role ?? null;
  } catch { return null; }
}

// Slack treats & < > as formatting: escape text that comes from records (guide rule 9)
const esc = (s: unknown) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const metersApart = (a: number, b: number, c: number, d: number) => {
  const t = (x: number) => x * Math.PI / 180;
  const h = Math.sin(t(c - a) / 2) ** 2 + Math.cos(t(a)) * Math.cos(t(c)) * Math.sin(t(d - b) / 2) ** 2;
  return 2 * 6371e3 * Math.asin(Math.sqrt(h));
};
const dist = (m: number) => m < 1000 ? `${Math.round(m)} m` : `${(m / 1000).toFixed(1)} km`;
const etDay = (iso: string) => new Date(iso).toLocaleDateString("en-CA", { timeZone: ET });   // YYYY-MM-DD
const clock = (iso: string) => new Date(iso).toLocaleTimeString("en-US", { timeZone: ET, hour: "numeric", minute: "2-digit" });
const longDay = (ymd: string) => new Date(ymd + "T12:00:00Z").toLocaleDateString("en-US", { timeZone: "UTC", weekday: "short", month: "short", day: "numeric" });
const shortDay = (iso: string) => new Date(iso).toLocaleDateString("en-US", { timeZone: ET, month: "short", day: "numeric" });

// Samsara pages for the visit time. The vehicle page takes end_ms + duration (seconds); a Place opens only WITH its
// duration/end_ms params (without them Samsara shows the list of all places), checked by Fred 2026-10-12.
const truckUrl = (id: string, fromMs: number, toMs: number) =>
  `https://cloud.samsara.com/o/${ORG}/devices/${id}/vehicle?end_ms=${toMs}&duration=${Math.min(86400, Math.round((toMs - fromMs) / 1000))}`;
const placeUrl = (id: string, ymd: string) =>
  `https://cloud.samsara.com/o/${ORG}/fleet/places/${id}?duration=2678399.999&end_ms=${Date.parse(ymd + "T23:59:59.999-04:00")}`;

async function samsaraPlaces(): Promise<Place[] | null> {
  const token = Deno.env.get("SAMSARA_API_TOKEN");
  if (!token) return null;
  try {
    const out: Place[] = [];
    let after = "";
    for (let page = 0; page < 20; page++) {
      const r = await fetch(`https://api.samsara.com/addresses?limit=512${after ? `&after=${encodeURIComponent(after)}` : ""}`,
        { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } });
      if (!r.ok || !(r.headers.get("content-type") ?? "").includes("json")) return null;
      const j = await r.json();
      for (const a of j.data ?? []) {
        if (a?.id && Number.isFinite(a.latitude) && Number.isFinite(a.longitude)) out.push({ id: String(a.id), name: String(a.name ?? ""), lat: a.latitude, lng: a.longitude });
      }
      if (!j.pagination?.hasNextPage) return out;
      after = j.pagination.endCursor;
    }
    return out;
  } catch { return null; }
}

// The client's Samsara Place: the property's own link, else the client's links, else a place named after the client
// code; among several, the nearest to the property point. null when places could not be read (unknown, not "none").
function findPlace(g: Gap, places: Place[] | null): { checked: boolean; place: Place | null; meters: number | null } {
  if (!places) return { checked: false, place: null, meters: null };
  const near = (cands: Place[]) => {
    if (!cands.length) return null;
    if (g.lat == null || g.lng == null) return cands[0];
    return cands.slice().sort((a, b) => metersApart(g.lat!, g.lng!, a.lat, a.lng) - metersApart(g.lat!, g.lng!, b.lat, b.lng))[0];
  };
  const byId = new Map(places.map((p) => [p.id, p]));
  const place = (g.property_place_id && byId.get(g.property_place_id))
    || near(g.client_place_ids.map((id) => byId.get(id)).filter(Boolean) as Place[])
    || (g.client_code ? near(places.filter((p) => p.name.startsWith(g.client_code + " "))) : null)
    || null;
  const meters = place && g.lat != null && g.lng != null ? metersApart(g.lat, g.lng, place.lat, place.lng) : null;
  return { checked: true, place, meters };
}

function line(g: Gap, places: Place[] | null): string {
  const { checked, place, meters } = findPlace(g, places);
  const name = esc(g.client_name ?? "Unnamed client");
  const who = place ? `<${placeUrl(place.id, g.visit_date)}|${name}>` : name;
  const done = g.completed_at ? Date.parse(g.completed_at) : Date.parse(g.visit_date + "T12:00:00-04:00");
  const link = (truck: string, id: string | null, from: number, to: number) =>
    id ? `<${truckUrl(id, from, to)}|${esc(truck)}>` : esc(truck);
  const completedWhen = g.completed_at
    ? (etDay(g.completed_at) === g.visit_date ? `at ${clock(g.completed_at)}` : `on ${shortDay(g.completed_at)}, ${clock(g.completed_at)}`)
    : null;

  const prefix = g.truck ? link(g.truck, g.truck_samsara_id, done - 3 * 3600e3, done + 3 * 3600e3) : "no truck assigned";
  let reason: string;
  const longest = g.stays[0];
  if (g.lat == null || g.lng == null) reason = "the property has no map point";
  else if (checked && !place) reason = "this client has no Samsara place";
  else if (place && meters != null && meters > NEAR_M) reason = `the Samsara place is ${dist(meters)} from our address`;
  else if (longest && longest.minutes >= 3) {
    const a = Date.parse(longest.first), b = Date.parse(longest.last);
    const t = link(longest.truck, longest.truck_samsara_id, Math.min(a, done) - 3600e3, Math.max(b, done) + 3600e3);
    // a stay on another day than the visit (an overnight route into the next morning) says its date
    const on = etDay(longest.first) === g.visit_date ? "" : `on ${shortDay(longest.first)}, `;
    reason = `${t} was there ${on}${clock(longest.first)} to ${clock(longest.last)}, but ` +
      (completedWhen ? `it was marked complete ${completedWhen}` : "it has no completion time");
  } else if (longest) {
    const a = Date.parse(longest.first);
    const passes = g.stays.filter((s) => s.truck === longest.truck).length;
    reason = `${link(longest.truck, longest.truck_samsara_id, a - 3 * 3600e3, a + 3 * 3600e3)} only drove past (under 3 min${passes > 1 ? `, ${passes} times` : ""})`;
  } else if (g.closest) reason = `no truck came within ${NEAR_M} m (closest ${dist(g.closest.meters)})`;
  else reason = "no truck GPS was found near it that day";
  return `• ${esc(g.client_code ?? "")} ${who} · ${prefix}: ${reason}`;
}

function buildSummary(n: number, ymd: string, test = false): string {
  return `:stopwatch: ${test ? "[TEST] " : ""}${n} ${n === 1 ? "visit" : "visits"} on ${longDay(ymd)} ${n === 1 ? "has" : "have"} no time on site`;
}

function buildMessage(gaps: Gap[], ymd: string, older: number | null, places: Place[] | null, test = false): string {
  const n = gaps.length;
  const head = `:stopwatch: ${test ? "[TEST] " : DIEGO + " "}*${n} ${n === 1 ? "visit" : "visits"} on ${longDay(ymd)} ${n === 1 ? "has" : "have"} no time on site*`;
  const lines = gaps.slice(0, MAX_LINES).map((g) => line(g, places));
  if (n > MAX_LINES) lines.push(`…and ${n - MAX_LINES} more.`);
  // an unreadable count is left out, never printed as 0 (guide rule 5); none older needs no line
  if (older != null && older > 0) {
    lines.push(`:card_index_dividers: *${older}* older ${older === 1 ? "visit" : "visits"} from the last 30 days still ${older === 1 ? "has" : "have"} no time on site.`);
  }
  return [head, ...lines].join("\n");
}

async function logRun(source: string, startedAt: string, ok: boolean, details: Record<string, unknown>): Promise<string | null> {
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/sync_log`, {
      method: "POST",
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json", Prefer: "return=minimal" },
      body: JSON.stringify({
        sync_source: source, started_at: startedAt, finished_at: new Date().toISOString(),
        duration_seconds: (Date.now() - Date.parse(startedAt)) / 1000,
        status: ok ? "success" : "error", rows_errored: ok ? 0 : 1,
        error_details: ok ? null : { message: `The time on site Slack reminder did not post: ${details.reason} (${details.error})` },
        details,
      }),
    });
    if (r.ok) return null;
    const e = `HTTP ${r.status} ${(await r.text()).slice(0, 200)}`;
    console.error(`[time-on-site-reminder] sync_log insert failed: ${e}`);
    return e;
  } catch (e) {
    console.error(`[time-on-site-reminder] sync_log insert failed: ${e}`);
    return String(e);
  }
}

async function run(dryRun: boolean, test: boolean, date: string | null, token: string | null): Promise<Outcome> {
  const fail = (code: number, reason: string, error: string, more: Record<string, unknown> = {}): Outcome =>
    ({ code, reply: { posted: false, error }, log: { posted: false, reason, error, ...more } });

  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_time_on_site_gaps`, {
    method: "POST",
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json",
               "x-app-source": "time-on-site-reminder" },
    body: JSON.stringify(date ? { p_date: date } : {}),
  });
  if (!r.ok) return fail(500, "the list could not be read", `gaps: HTTP ${r.status} ${(await r.text()).slice(0, 200)}`);
  const res = await r.json();
  const gaps = res?.visits as Gap[];
  const ymd = String(res?.date ?? "");
  if (!Array.isArray(gaps) || !/^\d{4}-\d{2}-\d{2}$/.test(ymd)) return fail(500, "the list could not be read", "gaps: not a list");
  const older = Number.isFinite(res?.older_count) ? Number(res.older_count) : null;
  const listed = { date: ymd, visits: gaps.map((g) => g.visit_id), counts: { visits: gaps.length, older } };
  if (!gaps.length) {
    return { code: 200, reply: { posted: false, reason: "no visit without time on site", date: ymd }, log: { posted: false, reason: "no visit without time on site", ...listed } };
  }

  const places = await samsaraPlaces();
  const message = buildMessage(gaps, ymd, older, places, test);
  const text = buildSummary(gaps.length, ymd, test);
  if (dryRun) return { code: 200, reply: { posted: false, dry_run: true, count: gaps.length, date: ymd, places_read: places != null, channel: CHANNEL, text, message }, log: {} };

  if (!token) return fail(500, "no Slack token", "SLACK_BOT_TOKEN is not set", listed);
  const as = await slackIdentity(token, "Visit Calendar", "visit-calendar");
  const post = await fetch("https://slack.com/api/chat.postMessage", {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ channel: CHANNEL, text, blocks: [slackHeader("⏱️ Visits with no time on site"), ...slackSections(message)],
      unfurl_links: false, unfurl_media: false, ...as }),
  });
  const out = await post.json().catch(() => ({}));
  if (!out.ok) return fail(502, "Slack refused the post", `slack: ${out.error ?? post.status}`, listed);
  return {
    code: 200,
    reply: { posted: true, count: gaps.length, date: ymd, places_read: places != null, channel: CHANNEL, ts: out.ts },
    log: { posted: true, reason: "posted", slack_ts: out.ts ?? null, places_read: places != null, ...listed },
  };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (bearerRole(req) !== "service_role") return json({ error: "service_role only" }, 403);
  const body = (await req.json().catch(() => null)) ?? {};
  const dryRun = body.dry_run === true;
  const test = body.test === true;
  const date = typeof body.date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(body.date) ? body.date : null;
  const token = Deno.env.get("SLACK_BOT_TOKEN") ?? null;

  if (body.check_bot === true) {
    if (!token) return json({ error: "SLACK_BOT_TOKEN is not set" }, 500);
    const who = await fetch("https://slack.com/api/auth.test", { method: "POST", headers: { Authorization: `Bearer ${token}` } });
    const w = await who.json().catch(() => ({}));
    const scopes = await slackScopes(token);
    return json({ ok: w.ok === true, bot: w.user ?? null, error: w.error ?? null, scopes, posts_as_app: scopes.includes("chat:write.customize") });
  }

  const startedAt = new Date().toISOString();
  let o: Outcome;
  try {
    o = await run(dryRun, test, date, token);
  } catch (e) {
    o = { code: 500, reply: { posted: false, error: String(e) },
          log: { posted: false, reason: "the reminder stopped with an error", error: String(e) } };
  }
  if (dryRun) return json(o.reply, o.code);
  const sync_log_error = await logRun(test ? `${SOURCE}_test` : SOURCE, startedAt, o.code < 400, { ...o.log, test });
  return json({ ...o.reply, sync_log_error }, o.code);
});
