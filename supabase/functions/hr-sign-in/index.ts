// hr-sign-in: an admin's sign-in actions from the HR App person page (Fred, 2026-10-19: "manage things like the
// username and password on the user view"; "go ahead with all recommended"). Plan: Building Apps/HR App/docs/specs/
// 2026-10-19-access-privileges-plan.md, Part 2. Migration 2026-10-19_2300_hr_sign_in_row.
//
// POST { employee_id, action: "reset_email" | "turn_off" | "turn_on" }  ->  { ok, message }
//
// AUTH: verify_jwt = true (pinned in config.toml). Every rule is in the database: this function first calls
// hr.request_sign_in_action AS THE CALLER (their own token), which checks the caller is an admin, never their own sign-in,
// never an admin's turn-off, no reset on a Google-only or turned-off sign-in, one reset per person per 15 minutes, and
// records the request (refusals too). Only then does it use the server key for the sign-in change itself, and it records
// the result with hr.finish_sign_in_action.
//   reset_email: Supabase Auth's own recover endpoint emails the reset link to the account's own address; the link never
//                comes back here (never /auth/v1/admin/generate_link, which would hand the link to the caller).
//                It opens the Apps Hub reset page (hard-coded, never taken from the request).
//   turn_off / turn_on: a long block on the sign-in (ban_duration) or its removal. Never a delete. The access check
//                treats a turned-off sign-in as no sign-in at once; an open session ends when its token expires (an
//                hour at most). Then a post in #apps-notifications and an email to the person and the other admins.
// Nothing here ever reads, logs or returns a password, a link or a token.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { slackHeader, slackIdentity, slackSections } from "../_shared/slack-notify.ts";

const URL = Deno.env.get("SUPABASE_URL")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const RESEND_FROM = Deno.env.get("RESEND_FROM") ?? "";
const SLACK = Deno.env.get("SLACK_BOT_TOKEN") ?? "";
const CHANNEL = "C0BJYHQKZM1"; // #apps-notifications
const RESET_PAGE = "https://hub.unclogme.app/reset-password";
const ORIGINS = new Set(["https://hr.unclogme.app"]);
const BLOCK = "876000h"; // about 100 years: "turned off" until an admin turns it back on

const cors = (origin: string | null) => ({
  "Access-Control-Allow-Origin": origin && ORIGINS.has(origin) ? origin : "https://hr.unclogme.app",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-api-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
});

async function notify(kind: "turn_off" | "turn_on", who: { name: string; email: string }, by: string, admins: string[]) {
  const first = who.name.split(" ")[0];
  const line = kind === "turn_off"
    ? `🔐 ${by} turned off ${first}'s sign-in. ${first} cannot sign in to any staff app until an admin turns it back on in the HR App.`
    : `🔐 ${by} turned ${first}'s sign-in back on. ${first} can sign in again.`;
  const out: Record<string, unknown> = {};
  if (SLACK) {
    try {
      const identity = await slackIdentity(SLACK, "HR App", "hr-app");
      const r = await fetch("https://slack.com/api/chat.postMessage", {
        method: "POST",
        headers: { Authorization: `Bearer ${SLACK}`, "Content-Type": "application/json; charset=utf-8" },
        body: JSON.stringify({ channel: CHANNEL, text: line, blocks: [slackHeader("🔐 HR App sign-ins"), ...slackSections(line)], ...identity }),
      });
      const j = await r.json().catch(() => ({}));
      out.slack = j.ok ? "posted" : `refused: ${j.error ?? r.status}`;
    } catch (e) { out.slack = `failed: ${(e as Error).message}`; }
  }
  if (RESEND_KEY && RESEND_FROM) {
    const subject = kind === "turn_off" ? `${first}'s UnclogMe sign-in was turned off` : `${first}'s UnclogMe sign-in is on again`;
    const text = kind === "turn_off"
      ? `${by} turned off ${who.name}'s sign-in in the HR App. ${first} cannot sign in to any UnclogMe staff app until an admin turns it back on.`
      : `${by} turned ${who.name}'s sign-in back on in the HR App. ${first} can sign in again.`;
    const to = [...new Set([who.email, ...admins].filter((x) => x && x.includes("@")))];
    try {
      const r = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from: RESEND_FROM, to, subject, text }),
      });
      out.email = r.ok ? `sent to ${to.length}` : `refused: ${r.status}`;
    } catch (e) { out.email = `failed: ${(e as Error).message}`; }
  }
  return out;
}

Deno.serve(async (req) => {
  const h = cors(req.headers.get("origin"));
  const reply = (status: number, body: Record<string, unknown>) =>
    new Response(JSON.stringify(body), { status, headers: { ...h, "Content-Type": "application/json" } });
  if (req.method === "OPTIONS") return new Response(null, { headers: h });
  if (req.method !== "POST") return reply(405, { ok: false, message: "Use POST." });

  const auth = req.headers.get("authorization") ?? "";
  if (!/^Bearer\s+\S+/i.test(auth)) return reply(401, { ok: false, message: "Please sign in again." });
  let body: { employee_id?: unknown; action?: unknown };
  try { body = await req.json(); } catch { return reply(400, { ok: false, message: "Nothing to do." }); }
  const employeeId = Number(body.employee_id);
  const action = String(body.action ?? "");
  if (!Number.isInteger(employeeId) || employeeId <= 0 || !["reset_email", "turn_off", "turn_on"].includes(action)) {
    return reply(400, { ok: false, message: "Nothing to do." });
  }

  // 1. the rules, as the caller
  const asCaller = createClient(URL, ANON, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
  const { data: req1, error: e1 } = await asCaller.schema("hr").rpc("request_sign_in_action", { p_employee_id: employeeId, p_action: action });
  if (e1) {
    const code = (e1 as { code?: string }).code;
    return reply(code === "42501" || code === "28000" ? 403 : 400, { ok: false, message: e1.message });
  }
  if (!req1?.ok) return reply(409, { ok: false, message: req1?.message ?? "That could not be done." });

  // 2. the sign-in change, with the server key
  const service = createClient(URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });
  let ok = false, reason = "", message = "";
  const first = String(req1.first_name ?? "this person");
  try {
    if (action === "reset_email") {
      const anon = createClient(URL, ANON, { auth: { persistSession: false } });
      const { error } = await anon.auth.resetPasswordForEmail(String(req1.email), { redirectTo: RESET_PAGE });
      ok = !error;
      reason = error ? error.message : "";
      message = ok ? `Reset email sent to ${req1.email}.`
        : /rate limit/i.test(error!.message) ? "Too many emails this hour. Try again later." : "The email could not be sent. Nothing changed.";
    } else {
      const { error } = await service.auth.admin.updateUserById(String(req1.auth_user_id), { ban_duration: action === "turn_off" ? BLOCK : "none" });
      ok = !error;
      reason = error ? error.message : "";
      message = ok ? (action === "turn_off" ? `${first}'s sign-in is turned off.` : `${first}'s sign-in is on again.`)
        : `Could not turn ${action === "turn_off" ? "off" : "on"}. Nothing changed.`;
    }
  } catch (e) {
    ok = false; reason = (e as Error).message; message = "That could not be done. Nothing changed.";
  }

  // 3. the result, recorded; then tell people about a turn-off or turn-on
  const { data: fin, error: e3 } = await service.schema("hr").rpc("finish_sign_in_action", { p_log_id: req1.log_id, p_ok: ok, p_reason: reason });
  if (e3) console.error(`[hr-sign-in] finish failed for log ${req1.log_id}: ${e3.message}`);
  let told: Record<string, unknown> = {};
  if (ok && action !== "reset_email" && fin) {
    told = await notify(action as "turn_off" | "turn_on", fin.person, String(fin.by ?? "An admin"), (fin.other_admins ?? []) as string[]);
  }
  return reply(ok ? 200 : 502, { ok, message, ...(ok ? { told } : {}) });
});
