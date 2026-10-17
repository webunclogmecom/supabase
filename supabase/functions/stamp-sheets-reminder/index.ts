// stamp-sheets-reminder: once a day at 11 AM Eastern (10 AM until 2026-10-07), tells #apps-notifications which DERM
// address sheets are not completed in the Stamp Studio.
//
// Fred, 2026-10-05: "we need to create a functionality of sending notifications once per day at
// 10 AM EST through slack about any Manifest not completed at the Stamp Studio App", channel
// #apps-notifications (C0BJYHQKZM1), and "post nothing" on a day when every sheet is completed.
// Fred, 2026-10-07: every scheduled notification at 11 AM ET.
//
// AUTH: verify_jwt=true (pinned in config.toml) PLUS an in-handler service_role gate. Invoked by
// public.fn_request_stamp_sheets_reminder() from pg_cron `stamp-sheets-reminder` (15:00 and 16:00
// UTC; the wrapper lets through only the run that is 11 AM in New York, so the hour is right in
// summer and in winter).
// Reads derm.fn_stamp_open_sheets() (the Studio's own list, derm.v_stamp_sheets, not completed, minus a sheet whose
// clients are all test or fixture clients by public.fn_is_non_customer: migration 2026-10-12_1315, so a test sheet
// never pings Diego and Serena; the Studio app itself still lists it).
// RUN RECORD (audit 2026-10-12, migration 2026-10-12_1310): the wrapper keeps the 11 AM New York gate and calls this
// function once a day whether or not a sheet is open; this function decides, and posts nothing when every sheet is
// completed. Every run writes ONE public.sync_log row: posted (status 'success', reason 'posted'), nothing to post
// ('success', 'every sheet is completed') or error ('error': the list could not be read, no Slack token, Slack refused
// the post, or the function threw). The run is wrapped, so a thrown error still writes its row, and a failed sync_log
// insert never fails the post (it is logged and returned as `sync_log_error`). Real runs use sync_source
// 'stamp_sheets_reminder'; [TEST] runs use 'stamp_sheets_reminder_test'. When the vault key is missing the wrapper
// writes the 'error' row itself (the function is never called). A dry run, check_bot, a caller that is not
// service_role and a method other than POST write no row.
// Posts with chat.postMessage on the ONE shared notification bot (SLACK_BOT_TOKEN, the Slack app renamed from
// "Dump Visits" to "UnclogMe Apps"; Fred, 2026-10-05: one bot for every app, each message labelled with its
// app), shown as "Stamp Studio" with the Stamp icon once the bot holds chat:write.customize
// (_shared/slack-notify.ts; without that scope the post is plain). Like every app notification it starts with a
// header block (Fred, 2026-10-05, Option A): docs/reference/slack-notifications.md.
// Body: { dry_run?: boolean, test?: boolean, check_bot?: boolean }  dry_run returns the message without
// posting it; test posts it with a "[TEST]" prefix; check_bot asks Slack who the bot is and which scopes it
// holds (auth.test), and posts nothing.
// Each sheet line ends with what it waits for (`reason`, since 2026-10-17, migration 2026-10-17_1330).
// Check: node scripts/checks/stamp_sheets_reminder.mjs (runs this file against stubs).

import { slackHeader, slackIdentity, slackScopes, slackSections } from "../_shared/slack-notify.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CHANNEL = Deno.env.get("STAMP_REMINDER_CHANNEL_ID") ?? "C0BJYHQKZM1"; // #apps-notifications
const STUDIO = "https://stamp.unclogme.app";
const MAX_LINES = 40;
const SOURCE = "stamp_sheets_reminder";

// reason (since 2026-10-17, Fred: "the system should say when it gives up"): what the sheet waits for, one short plain
// sentence from derm.fn_stamp_sheet_wait_reason (the Studio's own "Cannot complete yet" answer, first sentence), e.g.
// "page 1: a client on this page is printed on several rows". NULL when only stamps are missing (the count says it).
type Sheet = {
  manifest: string; service_date: string | null; dump_date: string | null;
  placed: number; total: number; pages: number; status: string; days_waiting: number | null;
  reason?: string | null;
};

// the guide's rule 9: text from records goes into Slack with &, < and > escaped
const esc = (t: string) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
type Outcome = { code: number; reply: Record<string, unknown>; log: Record<string, unknown> };

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

// The one-line `text` Slack shows in a phone notification and the sidebar (the guide: one line that makes sense
// alone). The body's first line drops "Stamp Studio": the header and the post's name already say it.
function buildSummary(n: number, test = false): string {
  return `:memo: ${test ? "[TEST] " : ""}Stamp Studio: ${n} ${n === 1 ? "sheet is" : "sheets are"} not completed`;
}

function buildMessage(sheets: Sheet[], test = false): string {
  const n = sheets.length;
  // Fred, 2026-10-12: tag Diego and Serena. Never on a [TEST] post (it would ping them).
  const head = `:memo: ${test ? "[TEST] " : "<@U0AL9JZ4V7C> <@U0BKM57UPSS> "}*${n} ${n === 1 ? "sheet is" : "sheets are"} not completed*`;
  const lines = sheets.slice(0, MAX_LINES).map((s) => {
    const date = s.dump_date ?? s.service_date;
    const parts = [
      `<${STUDIO}/${encodeURIComponent(s.manifest)}|Manifest ${s.manifest}>`,
      date ? `dumped ${day(date)}` : null,
      `${s.placed} of ${s.total} stamped`,
      s.status,
      s.days_waiting != null && s.days_waiting > 0 ? `waiting ${s.days_waiting} day${s.days_waiting === 1 ? "" : "s"}` : null,
      s.reason ? esc(s.reason) : null,
    ].filter(Boolean);
    return "• " + parts.join(" · ");
  });
  if (n > MAX_LINES) lines.push(`…and ${n - MAX_LINES} more in the <${STUDIO}|Stamp Studio>.`);
  return [head, ...lines].join("\n");
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
        error_details: ok ? null : { message: `The Stamp Studio Slack reminder did not post: ${details.reason} (${details.error})` },
        details,
      }),
    });
    if (r.ok) return null;
    const e = `HTTP ${r.status} ${(await r.text()).slice(0, 200)}`;
    console.error(`[stamp-sheets-reminder] sync_log insert failed: ${e}`);
    return e;
  } catch (e) {
    console.error(`[stamp-sheets-reminder] sync_log insert failed: ${e}`);
    return String(e);
  }
}

async function run(dryRun: boolean, test: boolean, token: string | null): Promise<Outcome> {
  const fail = (code: number, reason: string, error: string, more: Record<string, unknown> = {}): Outcome =>
    ({ code, reply: { posted: false, error }, log: { posted: false, reason, error, ...more } });

  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_stamp_open_sheets`, {
    method: "POST",
    headers: {
      apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json", "Content-Profile": "derm", "Accept-Profile": "derm",
      "x-app-source": "stamp-sheets-reminder",
    },
    body: "{}",
  });
  if (!r.ok) return fail(500, "the list could not be read", `open sheets: HTTP ${r.status} ${(await r.text()).slice(0, 200)}`);
  const sheets = ((await r.json()) ?? []) as Sheet[];
  if (!Array.isArray(sheets)) return fail(500, "the list could not be read", "open sheets: not a list");
  // every open sheet is recorded, not only the 40 the post shows
  const listed = { manifests: sheets.map((s) => s.manifest), counts: { sheets: sheets.length } };
  if (!sheets.length) {
    return { code: 200, reply: { posted: false, reason: "every sheet is completed" }, log: { posted: false, reason: "every sheet is completed", ...listed } };
  }

  const message = buildMessage(sheets, test);
  const text = buildSummary(sheets.length, test);
  if (dryRun) return { code: 200, reply: { posted: false, dry_run: true, count: sheets.length, channel: CHANNEL, text, message }, log: {} };

  if (!token) return fail(500, "no Slack token", "SLACK_BOT_TOKEN is not set", listed);
  const as = await slackIdentity(token, "Stamp Studio", "stamp-studio");
  const res = await fetch("https://slack.com/api/chat.postMessage", {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ channel: CHANNEL, text, blocks: [slackHeader("📝 Stamp Studio sheets"), ...slackSections(message)],
      unfurl_links: false, unfurl_media: false, ...as }),
  });
  const out = await res.json().catch(() => ({}));
  if (!out.ok) return fail(502, "Slack refused the post", `slack: ${out.error ?? res.status}`, listed);
  return {
    code: 200,
    reply: { posted: true, count: sheets.length, channel: CHANNEL, as_app: "username" in as, ts: out.ts },
    log: { posted: true, reason: "posted", slack_ts: out.ts ?? null, ...listed },
  };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (bearerRole(req) !== "service_role") return json({ error: "service_role only" }, 403);
  const body = (await req.json().catch(() => null)) ?? {};
  const dryRun = body.dry_run === true;
  const test = body.test === true;
  const token = Deno.env.get("SLACK_BOT_TOKEN") ?? null;

  if (body.check_bot === true) {
    if (!token) return json({ error: "SLACK_BOT_TOKEN is not set" }, 500);
    const who = await fetch("https://slack.com/api/auth.test", { method: "POST", headers: { Authorization: `Bearer ${token}` } });
    const w = await who.json().catch(() => ({}));
    const scopes = await slackScopes(token);
    return json({ ok: w.ok === true, bot: w.user ?? null, team: w.team ?? null, error: w.error ?? null,
      scopes, posts_as_app: scopes.includes("chat:write.customize") });
  }

  const startedAt = new Date().toISOString();
  let o: Outcome;
  try {
    o = await run(dryRun, test, token);
  } catch (e) {
    // a network error, a reply that is not JSON or a malformed sheet: still a run, so it still gets its row
    o = { code: 500, reply: { posted: false, error: String(e) },
          log: { posted: false, reason: "the reminder stopped with an error", error: String(e) } };
  }
  if (dryRun) return json(o.reply, o.code);
  const sync_log_error = await logRun(test ? `${SOURCE}_test` : SOURCE, startedAt, o.code < 400, { ...o.log, test });
  return json({ ...o.reply, sync_log_error }, o.code);
});
