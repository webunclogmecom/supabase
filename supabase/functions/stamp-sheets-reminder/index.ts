// stamp-sheets-reminder: once a day at 10 AM Eastern, tells #apps-notifications which DERM address
// sheets are not completed in the Stamp Studio.
//
// Fred, 2026-10-05: "we need to create a functionality of sending notifications once per day at
// 10 AM EST through slack about any Manifest not completed at the Stamp Studio App", channel
// #apps-notifications (C0BJYHQKZM1), and "post nothing" on a day when every sheet is completed.
//
// AUTH: verify_jwt=true (pinned in config.toml) PLUS an in-handler service_role gate. Invoked by
// public.fn_request_stamp_sheets_reminder() from pg_cron `stamp-sheets-reminder` (14:00 and 15:00
// UTC; the wrapper lets through only the run that is 10 AM in New York, so the hour is right in
// summer and in winter, and it makes no call at all when nothing is open).
// Reads derm.fn_stamp_open_sheets() (the Studio's own list, derm.v_stamp_sheets, not completed).
// Posts with chat.postMessage on the ONE shared notification bot (SLACK_BOT_TOKEN, the Slack app renamed from
// "Dump Visits" to "UnclogMe Apps"; Fred, 2026-10-05: one bot for every app, each message labelled with its
// app), shown as "Stamp Studio" with the Stamp icon once the bot holds chat:write.customize
// (_shared/slack-notify.ts; without that scope the post is plain). Like every app notification it starts with a
// header block (Fred, 2026-10-05, Option A): docs/reference/slack-notifications.md.
// Body: { dry_run?: boolean, test?: boolean, check_bot?: boolean }  dry_run returns the message without
// posting it; test posts it with a "[TEST]" prefix; check_bot asks Slack who the bot is and which scopes it
// holds (auth.test), and posts nothing.
// Check: node scripts/checks/stamp_sheets_reminder.mjs (runs this file against stubs).

import { slackHeader, slackIdentity, slackScopes, slackSections } from "../_shared/slack-notify.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CHANNEL = Deno.env.get("STAMP_REMINDER_CHANNEL_ID") ?? "C0BJYHQKZM1"; // #apps-notifications
const STUDIO = "https://stamp.unclogme.app";
const MAX_LINES = 40;

type Sheet = {
  manifest: string; service_date: string | null; dump_date: string | null;
  placed: number; total: number; pages: number; status: string; days_waiting: number | null;
};

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

function buildMessage(sheets: Sheet[], test = false): string {
  const n = sheets.length;
  const head = (test ? "[TEST] " : "") + `:memo: *Stamp Studio: ${n} ${n === 1 ? "sheet is" : "sheets are"} not completed*`;
  const lines = sheets.slice(0, MAX_LINES).map((s) => {
    const date = s.dump_date ?? s.service_date;
    const parts = [
      `<${STUDIO}/${encodeURIComponent(s.manifest)}|Manifest ${s.manifest}>`,
      date ? `dumped ${day(date)}` : null,
      `${s.placed} of ${s.total} stamped`,
      s.status,
      s.days_waiting != null && s.days_waiting > 0 ? `waiting ${s.days_waiting} day${s.days_waiting === 1 ? "" : "s"}` : null,
    ].filter(Boolean);
    return "• " + parts.join(" · ");
  });
  if (n > MAX_LINES) lines.push(`…and ${n - MAX_LINES} more in the <${STUDIO}|Stamp Studio>.`);
  return [head, ...lines].join("\n");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (bearerRole(req) !== "service_role") return json({ error: "service_role only" }, 403);
  const body = await req.json().catch(() => ({}));
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

  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_stamp_open_sheets`, {
    method: "POST",
    headers: {
      apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json", "Content-Profile": "derm", "Accept-Profile": "derm",
      "x-app-source": "stamp-sheets-reminder",
    },
    body: "{}",
  });
  if (!r.ok) return json({ error: `open sheets: HTTP ${r.status} ${(await r.text()).slice(0, 200)}` }, 500);
  const sheets = ((await r.json()) ?? []) as Sheet[];
  if (!Array.isArray(sheets)) return json({ error: "open sheets: not a list" }, 500);
  if (!sheets.length) return json({ posted: false, reason: "every sheet is completed" });

  const text = buildMessage(sheets, test);
  if (dryRun) return json({ posted: false, dry_run: true, count: sheets.length, channel: CHANNEL, text });

  if (!token) return json({ error: "SLACK_BOT_TOKEN is not set" }, 500);
  const as = await slackIdentity(token, "Stamp Studio", "stamp-studio");
  const res = await fetch("https://slack.com/api/chat.postMessage", {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ channel: CHANNEL, text, blocks: [slackHeader("📝 Stamp Studio sheets"), ...slackSections(text)],
      unfurl_links: false, unfurl_media: false, ...as }),
  });
  const out = await res.json().catch(() => ({}));
  if (!out.ok) return json({ posted: false, error: `slack: ${out.error ?? res.status}` }, 502);
  return json({ posted: true, count: sheets.length, channel: CHANNEL, as_app: "username" in as, ts: out.ts });
});
