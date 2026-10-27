// auth_password_settings.mjs: the Auth password settings Fred decided on 2026-10-27 (Trello JlxV47sS, plan
// Building Apps/HR App/docs/specs/2026-10-27-change-password-plan.md) are still in place.
// Run: node scripts/checks/auth_password_settings.mjs   (reads SUPABASE_PAT from .env, never prints it)
// Auth settings live outside the database, so the health email cannot see them; this is the check.
import { readFileSync } from "node:fs";

const env = Object.fromEntries(readFileSync(new URL("../../.env", import.meta.url), "utf8").split(/\r?\n/)
  .filter(l => /^[A-Z_]+=/.test(l)).map(l => [l.slice(0, l.indexOf("=")), l.slice(l.indexOf("=") + 1).replace(/^"|"$/g, "")]));
const r = await fetch("https://api.supabase.com/v1/projects/wbasvhvvismukaqdnouk/config/auth",
  { headers: { Authorization: `Bearer ${env.SUPABASE_PAT}` } });
if (!r.ok) { console.error(`could not read the Auth settings: HTTP ${r.status}`); process.exit(2); }
const c = await r.json();

const rules = [
  ["current password required to change a password", c.security_update_password_require_current_password === true],
  ["minimum password length is at least 8", Number(c.password_min_length) >= 8],
  ["'password set or changed' email is on", c.mailer_notifications_password_changed_enabled === true],
  ["that email is our template (not Supabase's default)", /Your password was updated/.test(c.mailer_templates_password_changed_notification_content ?? "")],
  ["emailed-code re-authentication stays off (decision 22, replaced)", c.security_update_password_require_reauthentication === false],
  // positive control: a setting we know is on; if this fails the read itself is wrong
  ["control: self sign-up is off (D16)", c.disable_signup === true],
];
let bad = 0;
for (const [name, ok] of rules) { console.log(`${ok ? "ok  " : "FAIL"}  ${name}`); if (!ok) bad++; }
process.exit(bad ? 1 : 0);
