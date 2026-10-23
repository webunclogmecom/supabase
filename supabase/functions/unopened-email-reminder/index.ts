// unopened-email-reminder: Monday, Wednesday and Friday at 11 AM Eastern, tells #apps-notifications which city and
// client emails were delivered but nobody is confirmed to have opened them, and which were not delivered.
//
// Yan (Slack #new-app-issues, 2026-10-20): "I want a notification 3 times a week if emails have been delivered and not
// opened (if they have been opened I dont want a notification)". Trello xMtqH9Xw: the office (Diego) calls the city
// before a deadline slips. Fred picked on the mockup (2026-10-20): build D5 first (a city open can be counted since
// 2026-10-20_1900 and the senders' D5 deploy), keep an email listed up to 7 days, Layout 1 (grouped by city), tag
// Diego. Format: docs/reference/slack-notifications.md (header first, plain words, no em dash, [TEST] never tags).
//
// AUTH: verify_jwt=true (pinned in config.toml) PLUS an in-handler service_role gate. Invoked by
// public.fn_request_unopened_email_reminder() from pg_cron `unopened-email-reminder` (15:00 and 16:00 UTC; the wrapper
// lets through only the run that is 11 AM in New York), every day. THIS function decides the posting days (Mon, Wed,
// Fri in New York) so it writes a run record every day and the health check (reminder_not_run, 26 hours) works.
// Reads public.fn_unopened_emails(p_as_of): the ONE rule of what is listed (migration 2026-10-20_1930). Posts on the
// shared bot (SLACK_BOT_TOKEN, "UnclogMe Apps"), shown as "DERM Tracker".
// RUN RECORD: one public.sync_log row per run that is not a dry run: posted / nothing to report / not a posting day
// ('success'), or 'error' (list unreadable, no token, Slack refused, thrown). Source 'unopened_email_reminder';
// a [TEST] run logs as 'unopened_email_reminder_test'.
// Body: { dry_run?: boolean, test?: boolean, as_of?: ISO string }. dry_run returns the message without posting; test
// posts it with "[TEST]" and no tag. Both ignore the posting days. as_of replays another instant (both the list and
// the day). Check: node scripts/checks/unopened_email_reminder.mjs (runs this file against stubs).

import { slackHeader, slackIdentity, slackSections } from "../_shared/slack-notify.ts";
import { isSecretKeyCaller } from "../_shared/service-caller.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CHANNEL = Deno.env.get("UNOPENED_EMAIL_REMINDER_CHANNEL_ID") ?? "C0BJYHQKZM1"; // #apps-notifications
const ADMIN = "https://admin.unclogme.app";
const DERM = "https://derm.unclogme.app";
const MAX_LINES = 40;
const SOURCE = "unopened_email_reminder";
const TAG = "<@U0AL9JZ4V7C>"; // Diego (Fred, 2026-10-20: the card names Diego)
const POST_DAYS = new Set(["Mon", "Wed", "Fri"]); // Yan: "3 times a week"

type Email = {
  section: "not_delivered" | "not_opened"; target: "city" | "client"; source_table: string; send_id: number;
  resend_email_id: string; client_code: string | null; client_name: string | null; city: string | null;
  visit_id: number | null; visit_date: string | null; app: "admin_review" | "derm_tracker"; kind: string;
  via: string | null; sent_by_name: string | null; sent_at: string; delivery_status: string;
  open_gap_seconds: number | null; open_unknown_reason: string | null; to_count: number; delivered_count: number;
  refused_count: number; bounce_reason: string | null;
};
type Outcome = { code: number; reply: Record<string, unknown>; log: Record<string, unknown> };

const json = (p: unknown, status = 200) =>
  new Response(JSON.stringify(p), { status, headers: { "Content-Type": "application/json" } });

function bearerRole(req: Request): string | null {
  if (isSecretKeyCaller(req)) return "service_role"; // a secret key (2026-10-23, legacy-keys plan)
  try {
    const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(tok.split(".")[1] ?? ""))?.role ?? null;
  } catch { return null; }
}

const etWeekday = (d: Date) => new Intl.DateTimeFormat("en-US", { timeZone: "America/New_York", weekday: "short" }).format(d);
const sentDay = (iso: string) => new Intl.DateTimeFormat("en-US", {
  timeZone: "America/New_York", weekday: "short", month: "short", day: "numeric",
}).format(new Date(iso));
const visitDay = (d: string) =>
  new Date(d + "T12:00:00Z").toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
// Client names and sender names can carry &, < or >, which Slack reads as formatting.
const esc = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

function who(e: Email): string {
  const name = `${(e.client_code ?? "").trim()} ${(e.client_name ?? "").trim()}`.trim() || "client not recorded";
  if (!e.visit_id) return esc(name);
  const url = e.app === "admin_review" ? `${ADMIN}/review/${e.visit_id}` : `${DERM}/visits/${e.visit_id}`;
  return `<${url}|${esc(name)}>`;
}
function sent(e: Email): string {
  if (e.via === "automatic") return `sent automatically ${sentDay(e.sent_at)}`;
  return e.sent_by_name ? `sent ${sentDay(e.sent_at)} by ${esc(e.sent_by_name)}` : `sent ${sentDay(e.sent_at)}, sender not recorded`;
}
function what(e: Email): string {
  return e.visit_date ? `${e.kind}, visit ${visitDay(e.visit_date)}` : e.kind;
}
function openNote(e: Email): string {
  if (e.delivery_status === "opened" && e.open_gap_seconds != null && e.open_gap_seconds < 60)
    return ` · opened ${e.open_gap_seconds} s after it arrived, most likely by their email system`;
  if (e.open_unknown_reason) return " · opens cannot be seen on this one";
  return "";
}
function refusal(e: Email): string {
  const theirs = e.target === "city" ? "the city's email system" : "the client's email system";
  const why = e.bounce_reason ? ` (${esc(e.bounce_reason)})` : "";
  switch (e.delivery_status) {
    case "partly_bounced": return `refused by ${e.refused_count} of ${e.to_count} inboxes${why}`;
    case "spam": return `${theirs} reported it as spam`;
    case "partly_delivered": return `reached ${e.delivered_count} of ${e.to_count} inboxes so far`;
    case "delayed": return `${theirs} is holding it`;
    default: return `${theirs} refused it${why}`;
  }
}

// `text` = this line, then the whole message: Viktor reads only `text`. The first line is the phone notification.
function buildSummary(notOpened: number, notDelivered: number, test = false, cityOnly = false): string {
  const parts: string[] = [];
  if (notOpened) parts.push(cityOnly
    ? `${plural(notOpened, "city email", "city emails")} delivered, call to confirm`
    : `${plural(notOpened, "email", "emails")} delivered but not confirmed opened`);
  if (notDelivered) parts.push(`${plural(notDelivered, "email", "emails")} not delivered`);
  return `📭 ${test ? "[TEST] " : ""}DERM Tracker: ${parts.join(", ")}`;
}

function buildMessage(list: Email[], test = false): string {
  const lead = test ? "[TEST] " : `${TAG} `;
  const out: string[] = [];
  let shown = 0;
  const line = (s: string) => { if (shown < MAX_LINES) out.push(s); shown++; };
  const failed = list.filter((e) => e.section === "not_delivered");
  const unopened = list.filter((e) => e.section === "not_opened");

  if (failed.length) {
    out.push(`⚠️ ${lead}*Not delivered (${failed.length}):*`);
    for (const e of failed) line(`• ${who(e)} · ${e.city ? esc(e.city) + " · " : ""}${what(e)} · ${sent(e)}: ${refusal(e)}`);
    out.push(failed.some((e) => e.target === "city")
      ? "Check the city email on the property in the Client App, then send it again."
      : "Check the client's email in the Client App, then send it again.");
  }
  if (unopened.length) {
    if (out.length) out.push("");
    // Fred, 2026-10-22 (Trello 5RpYsa98): no city email has ever recorded an open (12 deliveries to the Microsoft 365
    // inboxes of Hallandale Beach and Surfside since Oct 14), so a list of only city emails is a call list and says so.
    const cityOnly = unopened.every((x) => x.target !== "client");
    const one = unopened.length === 1;
    const manyCities = new Set(unopened.map((x) => x.city)).size > 1;
    out.push(`📭 ${failed.length ? (test ? "[TEST] " : "") : lead}*${cityOnly
      ? `${plural(unopened.length, "city email", "city emails")} delivered, ${manyCities ? "the cities' email systems do" : "the city's email system does"} not report when ${one ? "it is" : "they are"} read`
      : `${plural(unopened.length, "email was", "emails were")} delivered and nobody is confirmed to have opened ${one ? "it" : "them"}`}*`);
    out.push(cityOnly
      ? `ℹ️ Call to confirm they have ${one ? "it" : "them"}.`
      : "ℹ️ No open recorded is not proof it was unread (many email systems block the picture that records an open), so call to confirm they have it.");
    // Layout 1 (Fred's pick): one group per city, so one call covers a group; client emails last. Oldest first.
    const cities = new Map<string, Email[]>();
    for (const e of unopened.filter((x) => x.target !== "client")) {
      const k = e.city ?? "No city on file";
      cities.set(k, [...(cities.get(k) ?? []), e]);
    }
    const groups: [string, Email[]][] = [...cities.entries()].sort((a, b) => a[0].localeCompare(b[0]))
      .map(([k, g]) => [`🏙 *${esc(k)} (${g.length}):*`, g]);
    const clients = unopened.filter((x) => x.target === "client");
    if (clients.length) groups.push([`👤 *Client emails (${clients.length}):*`, clients]);
    for (const [title, g] of groups) {
      out.push("");
      out.push(title);
      for (const e of g) line(`• ${who(e)} · ${what(e)} · ${sent(e)}${openNote(e)}`);
    }
  }
  if (shown > MAX_LINES) out.push(`…and ${shown - MAX_LINES} more in the apps.`);
  return out.join("\n");
}

// The run record: ONE public.sync_log row per run. Returns null, or why the row could not be written (never throws).
async function logRun(source: string, startedAt: string, ok: boolean, details: Record<string, unknown>): Promise<string | null> {
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/sync_log`, {
      method: "POST",
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json", Prefer: "return=minimal" },
      body: JSON.stringify({
        sync_source: source, started_at: startedAt, finished_at: new Date().toISOString(),
        duration_seconds: (Date.now() - Date.parse(startedAt)) / 1000,
        status: ok ? "success" : "error", rows_errored: ok ? 0 : 1,
        error_details: ok ? null : { message: `The unopened email Slack reminder did not post: ${details.reason} (${details.error})` },
        details,
      }),
    });
    if (r.ok) return null;
    const e = `HTTP ${r.status} ${(await r.text()).slice(0, 200)}`;
    console.error(`[unopened-email-reminder] sync_log insert failed: ${e}`);
    return e;
  } catch (e) {
    console.error(`[unopened-email-reminder] sync_log insert failed: ${e}`);
    return String(e);
  }
}

async function run(dryRun: boolean, test: boolean, asOf: Date): Promise<Outcome> {
  const fail = (code: number, reason: string, error: string, more: Record<string, unknown> = {}): Outcome =>
    ({ code, reply: { posted: false, error }, log: { posted: false, reason, error, ...more } });

  const day = etWeekday(asOf);
  if (!dryRun && !test && !POST_DAYS.has(day)) {
    return { code: 200, reply: { posted: false, reason: "not a posting day", day }, log: { posted: false, reason: "not a posting day", day } };
  }

  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_unopened_emails`, {
    method: "POST",
    headers: {
      apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json",
      "x-app-source": "unopened-email-reminder",
    },
    body: JSON.stringify({ p_as_of: asOf.toISOString() }),
  });
  if (!r.ok) return fail(500, "the list could not be read", `list: HTTP ${r.status} ${(await r.text()).slice(0, 200)}`);
  const res = (await r.json()) as { emails?: Email[] };
  if (!res || !Array.isArray(res.emails)) return fail(500, "the list could not be read", "list: unexpected shape");
  const list = res.emails.filter((e) => e && (e.section === "not_delivered" || e.section === "not_opened"));
  const notOpened = list.filter((e) => e.section === "not_opened").length;
  const notDelivered = list.length - notOpened;
  // every listed email is recorded, not only the 40 the post shows
  const listed = { emails: list.map((e) => `${e.source_table}:${e.send_id}`), counts: { not_opened: notOpened, not_delivered: notDelivered }, day };
  if (!list.length) {
    return { code: 200, reply: { posted: false, reason: "nothing to report" }, log: { posted: false, reason: "nothing to report", ...listed } };
  }

  const message = buildMessage(list, test);
  const cityOnly = list.every((e) => e.section !== "not_opened" || e.target !== "client");
  const text = `${buildSummary(notOpened, notDelivered, test, cityOnly)}\n\n${message}`;
  if (dryRun) return { code: 200, reply: { posted: false, dry_run: true, channel: CHANNEL, text, message }, log: {} };

  const token = Deno.env.get("SLACK_BOT_TOKEN") ?? null;
  if (!token) return fail(500, "no Slack token", "SLACK_BOT_TOKEN is not set", listed);
  const as = await slackIdentity(token, "DERM Tracker", "derm-tracker");
  const blocks = [
    slackHeader("📭 Emails not opened"),
    ...slackSections(message),
    { type: "context", elements: [{ type: "mrkdwn", text: `🔗 <${ADMIN}|Open Admin Review> · <${DERM}|Open DERM Tracker>` }] },
  ];
  const post = await fetch("https://slack.com/api/chat.postMessage", {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ channel: CHANNEL, text, blocks, unfurl_links: false, unfurl_media: false, ...as }),
  });
  const out = await post.json().catch(() => ({}));
  if (!out.ok) return fail(502, "Slack refused the post", `slack: ${out.error ?? post.status}`, listed);
  return {
    code: 200,
    reply: { posted: true, not_opened: notOpened, not_delivered: notDelivered, channel: CHANNEL, as_app: "username" in as, ts: out.ts },
    log: { posted: true, reason: "posted", slack_ts: out.ts ?? null, ...listed },
  };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (bearerRole(req) !== "service_role") return json({ error: "service_role only" }, 403);
  const body = (await req.json().catch(() => null)) ?? {};
  const dryRun = body.dry_run === true;
  const test = body.test === true;
  const asOf = typeof body.as_of === "string" && !Number.isNaN(Date.parse(body.as_of)) ? new Date(body.as_of) : new Date();
  const startedAt = new Date().toISOString();

  let o: Outcome;
  try {
    o = await run(dryRun, test, asOf);
  } catch (e) {
    // a network error, a reply that is not JSON or a malformed item: still a run, so it still gets its row
    o = { code: 500, reply: { posted: false, error: String(e) },
          log: { posted: false, reason: "the reminder stopped with an error", error: String(e) } };
  }
  if (dryRun) return json(o.reply, o.code);
  const sync_log_error = await logRun(test ? `${SOURCE}_test` : SOURCE, startedAt, o.code < 400, { ...o.log, test });
  return json({ ...o.reply, sync_log_error }, o.code);
});
