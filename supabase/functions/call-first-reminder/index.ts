// call-first-reminder: once a day at 11 AM Eastern, tells #apps-notifications which clients must be phoned for
// approval before we schedule them (Fred, 2026-10-18, "go ahead", building the approved design
// docs/superpowers/specs/2026-08-17-call-before-scheduling-clients-design.md).
//
// 🛑 A POINTER, NOT A TASK LIST. The queue (ops.visit_requests where call_required, shown in the Calendar's To Be
// Scheduled) is the only truth. ops.fn_call_first_run files what is due (3 days before the call date), then returns
// the open call requests not announced yet (every open one on Mondays) and marks them announced, so a client is named
// once, not every day.
//
// AUTH: verify_jwt=true (config.toml) PLUS an in-handler service_role gate. Invoked by
// public.fn_request_call_first_reminder() from pg_cron `call-first-reminder` (15:00 and 16:00 UTC; the wrapper lets
// through only the run that is 11 AM in New York). Every run writes ONE public.sync_log row (source
// call_first_reminder, call_first_reminder_test for a test); a dry run and a caller that is not service_role write none.
// Posts on the ONE shared notification bot (SLACK_BOT_TOKEN) as "Visit Calendar", with the header block every app
// notification starts with (docs/reference/slack-notifications.md). Tags Diego (the queue is his); never on a test.
// Body: { dry_run?: boolean, test?: boolean }. dry_run returns the message and changes nothing; test posts it with a
// "[TEST]" prefix and also changes nothing (a test must not use up the real announcement).
// Check: node scripts/checks/call_first_reminder.mjs (runs this file against stubs).

import { slackHeader, slackIdentity, slackSections } from "../_shared/slack-notify.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CHANNEL = Deno.env.get("CALL_FIRST_CHANNEL_ID") ?? "C0BJYHQKZM1"; // #apps-notifications
const CALENDAR = "https://calendar.unclogme.app/";
const DIEGO = "<@U0AL9JZ4V7C>";
const SOURCE = "call_first_reminder";

type Item = {
  request_id: number; client_code: string; client_name: string; call_due_at: string;
  last_completed_date: string | null; cadence_days: number; gdo_number: string | null;
  permit_max_days: number | null; cadence_exceeds_permit: boolean; new: boolean; filed_at: string;
};
type Run = { dry_run: boolean; weekly: boolean; items: Item[]; filer: { errors?: { client: string; client_name?: string; error: string }[] } | null };
type Outcome = { code: number; reply: Record<string, unknown>; log: Record<string, unknown> };

const json = (p: unknown, status = 200) =>
  new Response(JSON.stringify(p), { status, headers: { "Content-Type": "application/json" } });

function bearerRole(req: Request): string | null {
  try {
    const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(tok.split(".")[1] ?? ""))?.role ?? null;
  } catch { return null; }
}

// the guide's rule 9: text from records goes into Slack with &, < and > escaped
const esc = (t: string) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const day = (d: string) =>
  new Date(d.slice(0, 10) + "T12:00:00Z").toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });

function buildSummary(n: number, test = false): string {
  return `:telephone_receiver: ${test ? "[TEST] " : ""}Visit Calendar: ${n} ${n === 1 ? "client" : "clients"} to call for approval before scheduling`;
}

// a filer error in the operator's words (the raw error stays in the run record)
function plainError(e: string): string {
  if (/is not an active job/.test(e)) return "its Service Call job is closed in Jobber, so the reminder could not be added. Open a Service Call job for it, or tell the Supabase session.";
  return "the reminder could not be added to To Be Scheduled. Tell the Supabase session.";
}

function buildMessage(run: Run, test = false): string {
  const items = run.items;
  const errors = run.filer?.errors ?? [];
  const n = items.length;
  const head = `:telephone_receiver: ${test ? "[TEST] " : `${DIEGO} `}*${n} ${n === 1 ? "client" : "clients"} to call for approval before scheduling*`;
  const lines = items.map((i) => {
    const parts = [
      `<${CALENDAR}|${esc(i.client_code)} ${esc(i.client_name)}>`,
      `call due ${day(i.call_due_at)}`,
      i.last_completed_date ? `last service ${day(i.last_completed_date)}` : "no service on record",
      i.permit_max_days ? `its permit allows ${i.permit_max_days} days` : null,
      i.cadence_exceeds_permit ? `:warning: called every ${i.cadence_days} days, longer than the permit allows` : null,
      i.new ? null : `waiting since ${day(i.filed_at)}`,
    ].filter(Boolean);
    return "• " + parts.join(" · ");
  });
  const errLines = errors.map((e) => `:warning: *${esc(e.client)}${e.client_name ? " " + esc(e.client_name) : ""}*: ${plainError(e.error)}`);
  const how = n
    ? "Call each client, then in the Calendar's *To Be Scheduled*: *Schedule* it when they agree, or *Not now* with the date they gave."
    : null;
  return [head, ...lines, ...errLines, how].filter((x) => x !== null).join("\n");
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
        error_details: ok ? null : { message: `The call-first Slack reminder did not post: ${details.reason} (${details.error})` },
        details,
      }),
    });
    if (r.ok) return null;
    const e = `HTTP ${r.status} ${(await r.text()).slice(0, 200)}`;
    console.error(`[call-first-reminder] sync_log insert failed: ${e}`);
    return e;
  } catch (e) {
    console.error(`[call-first-reminder] sync_log insert failed: ${e}`);
    return String(e);
  }
}

async function run(dryRun: boolean, test: boolean, token: string | null): Promise<Outcome> {
  const fail = (code: number, reason: string, error: string, more: Record<string, unknown> = {}): Outcome =>
    ({ code, reply: { posted: false, error }, log: { posted: false, reason, error, ...more } });

  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_call_first_run`, {
    method: "POST",
    headers: {
      apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json", "Content-Profile": "ops", "Accept-Profile": "ops",
      "x-app-source": "call-first-reminder",
    },
    // a dry run and a test change nothing: nothing is filed or marked announced
    body: JSON.stringify({ p_dry_run: dryRun || test }),
  });
  if (!r.ok) return fail(500, "the list could not be read", `call run: HTTP ${r.status} ${(await r.text()).slice(0, 200)}`);
  const res = (await r.json()) as Run;
  if (!res || !Array.isArray(res.items)) return fail(500, "the list could not be read", "call run: no items list");
  const errors = res.filer?.errors ?? [];
  const listed = { clients: res.items.map((i) => i.client_code), filer: res.filer, weekly: res.weekly };
  if (!res.items.length && !errors.length) {
    return { code: 200, reply: { posted: false, reason: "nothing to announce" }, log: { posted: false, reason: "nothing to announce", ...listed } };
  }

  const message = buildMessage(res, test);
  const text = buildSummary(res.items.length, test);
  if (dryRun) return { code: 200, reply: { posted: false, dry_run: true, channel: CHANNEL, text, message, run: res }, log: {} };

  if (!token) return fail(500, "no Slack token", "SLACK_BOT_TOKEN is not set", listed);
  const as = await slackIdentity(token, "Visit Calendar", "visit-calendar");
  const post = await fetch("https://slack.com/api/chat.postMessage", {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ channel: CHANNEL, text, blocks: [slackHeader("📞 Calls before scheduling"), ...slackSections(message)],
      unfurl_links: false, unfurl_media: false, ...as }),
  });
  const out = await post.json().catch(() => ({}));
  if (!out.ok) return fail(502, "Slack refused the post", `slack: ${out.error ?? post.status}`, listed);
  return { code: 200, reply: { posted: true, count: res.items.length, channel: CHANNEL, ts: out.ts },
           log: { posted: true, reason: "posted", slack_ts: out.ts ?? null, ...listed } };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (bearerRole(req) !== "service_role") return json({ error: "service_role only" }, 403);
  const body = (await req.json().catch(() => null)) ?? {};
  const dryRun = body.dry_run === true;
  const test = body.test === true;
  const token = Deno.env.get("SLACK_BOT_TOKEN") ?? null;

  const startedAt = new Date().toISOString();
  let o: Outcome;
  try {
    o = await run(dryRun, test, token);
  } catch (e) {
    o = { code: 500, reply: { posted: false, error: String(e) },
          log: { posted: false, reason: "the reminder stopped with an error", error: String(e) } };
  }
  if (dryRun) return json(o.reply, o.code);
  const sync_log_error = await logRun(test ? `${SOURCE}_test` : SOURCE, startedAt, o.code < 400, { ...o.log, test });
  return json({ ...o.reply, sync_log_error }, o.code);
});
