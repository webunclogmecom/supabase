// admin-review-reminder: once a day at 11 AM Eastern, tells #apps-notifications which completed visits still need a
// city email and how many have photos not sorted in Admin Review.
//
// Serena (Slack, 2026-10-07): Diego forgot "send city email" for Hallandale and Surfside; remind when photos are not
// sorted, or sorted but the city email was not sent. Fred: "send the notifications like we usually do at slack, and
// then later on i can make Viktor to read those notifications and act depending on them"; from a mockup he picked
// ONE post a day at 11 AM ET, the city list covering every visit since the city email went live (2026-09-15).
//
// AUTH: verify_jwt=true (pinned in config.toml) PLUS an in-handler service_role gate. Invoked by
// public.fn_request_admin_review_reminder() from pg_cron `admin-review-reminder` (15:00 and 16:00 UTC; the wrapper
// lets through only the run that is 11 AM in New York and makes no call when nothing is waiting).
// Reads public.fn_admin_review_pending(). Posts on the ONE shared notification bot (SLACK_BOT_TOKEN, "UnclogMe Apps"),
// shown as "Admin Review" with its icon, in the format of docs/reference/slack-notifications.md.
// Body: { dry_run?: boolean, test?: boolean }  dry_run returns the message without posting; test posts it with
// "[TEST]". Check: node scripts/checks/admin_review_reminder.mjs (runs this file against stubs).

import { slackHeader, slackIdentity, slackSections } from "../_shared/slack-notify.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CHANNEL = Deno.env.get("ADMIN_REVIEW_REMINDER_CHANNEL_ID") ?? "C0BJYHQKZM1"; // #apps-notifications
const ADMIN = "https://admin.unclogme.app";
const MAX_LINES = 40;

type CityVisit = {
  visit_id: number; client_code: string | null; client_name: string | null; city: string | null;
  visit_date: string; driver: string | null; photos_total: number; photos_sorted: number;
};
type Pending = { city: CityVisit[]; photos: { count: number; last_7_days: number; oldest: string | null } };

const json = (p: unknown, status = 200) =>
  new Response(JSON.stringify(p), { status, headers: { "Content-Type": "application/json" } });

function bearerRole(req: Request): string | null {
  try {
    const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(tok.split(".")[1] ?? ""))?.role ?? null;
  } catch { return null; }
}

const day = (d: string) =>
  new Date(d + "T12:00:00Z").toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
// Client and driver names can carry &, < or >, which Slack reads as formatting.
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

// Fred, 2026-10-12 (voice note): tag Diego and Serena; "shorten it": list ONLY the visits whose photos are sorted and
// whose city email is not sent, Hallandale Beach and Surfside together "and just call it Broward"; drop the summary
// line (the photos line at the bottom already says it). Visits with photos not sorted (or none) stay out of the list:
// the photos line counts them. No @-mention on a [TEST] post (it would ping them).
const TAGS = "<@U0AL9JZ4V7C> <@U0BKM57UPSS>"; // Diego, Serena
const GROUP = "Broward";
const sorted = (v: CityVisit) => v.photos_total > 0 && v.photos_sorted >= v.photos_total;

// `text` = this line, then the whole message: Viktor reads only `text`. The first line is the phone notification.
function buildSummary(ready: number, photos: number, test = false): string {
  const parts = [];
  if (ready) parts.push(`${plural(ready, "visit", "visits")} with photos sorted still ${ready === 1 ? "needs" : "need"} a city email`);
  if (photos) parts.push(`${plural(photos, "visit has", "visits have")} photos not sorted`);
  return `📸 ${test ? "[TEST] " : ""}Admin Review: ${parts.join(", ")}`;
}

function buildMessage(ready: CityVisit[], p: Pending, test = false): string {
  const lead = test ? "[TEST] " : `${TAGS} `;
  const out: string[] = [];
  if (ready.length) {
    out.push(`🏙 ${lead}*${GROUP}: photos sorted, city email not sent yet (${ready.length}):*`);
    for (const v of ready.slice(0, MAX_LINES)) {
      const who = `${(v.client_code ?? "").trim()} ${(v.client_name ?? "").trim()}`.trim();
      out.push(`• <${ADMIN}/review/${v.visit_id}|${esc(who)}> · ${day(v.visit_date)} · ${esc(v.driver ?? "driver not recorded")}`);
    }
    if (ready.length > MAX_LINES) out.push(`…and ${ready.length - MAX_LINES} more in <${ADMIN}|Admin Review>.`);
  }
  if (p.photos.count) {
    if (out.length) out.push("");
    out.push(`🖼 ${out.length ? "" : lead}*Photos not sorted: ${plural(p.photos.count, "visit", "visits")}* · ${p.photos.last_7_days} from the last 7 days` +
      (p.photos.oldest ? ` · oldest ${day(p.photos.oldest)}` : ""));
  }
  return out.join("\n");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (bearerRole(req) !== "service_role") return json({ error: "service_role only" }, 403);
  const body = await req.json().catch(() => ({}));
  const dryRun = body.dry_run === true;
  const test = body.test === true;

  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_admin_review_pending`, {
    method: "POST",
    headers: {
      apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json",
      "x-app-source": "admin-review-reminder",
    },
    body: "{}",
  });
  if (!r.ok) return json({ error: `pending: HTTP ${r.status} ${(await r.text()).slice(0, 200)}` }, 500);
  const p = (await r.json()) as Pending;
  if (!p || !Array.isArray(p.city) || typeof p.photos?.count !== "number") return json({ error: "pending: unexpected shape" }, 500);
  const ready = p.city.filter(sorted).sort((a, b) => a.visit_date.localeCompare(b.visit_date) || (a.client_code ?? "").localeCompare(b.client_code ?? ""));
  if (!ready.length && !p.photos.count) return json({ posted: false, reason: "nothing is waiting" });

  const message = buildMessage(ready, p, test);
  // `text` carries the WHOLE list after the summary line: Viktor (Fred, 2026-10-07: he reads these posts and reminds
  // Diego) sees only `text`, never the blocks. The first line is still what a phone notification shows.
  const text = `${buildSummary(ready.length, p.photos.count, test)}\n\n${message}`;
  if (dryRun) return json({ posted: false, dry_run: true, channel: CHANNEL, text, message });

  const token = Deno.env.get("SLACK_BOT_TOKEN") ?? null;
  if (!token) return json({ error: "SLACK_BOT_TOKEN is not set" }, 500);
  const as = await slackIdentity(token, "Admin Review", "admin-review");
  const blocks = [
    slackHeader("📸 Photos and city emails"),
    ...slackSections(message),
    { type: "context", elements: [{ type: "mrkdwn", text: `🔗 <${ADMIN}|Open Admin Review>` }] },
  ];
  const res = await fetch("https://slack.com/api/chat.postMessage", {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ channel: CHANNEL, text, blocks, unfurl_links: false, unfurl_media: false, ...as }),
  });
  const out = await res.json().catch(() => ({}));
  if (!out.ok) return json({ posted: false, error: `slack: ${out.error ?? res.status}` }, 502);
  return json({ posted: true, city: ready.length, photos: p.photos.count, channel: CHANNEL, as_app: "username" in as, ts: out.ts });
});
