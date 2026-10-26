// plan.ts: the pure half of hr-sign-in (Send invite, 2026-10-26, phase 6 of
// Building Apps/HR App/docs/specs/2026-10-26-send-invite-implementation-plan.md). No Deno APIs, no imports, so
// plan.test.mjs runs it under plain Node.
//
// planAction: what each allowed action does to the sign-in and who hears about it. Every action has its own branch;
// an unknown action throws (before 2026-10-26 anything that was not a reset fell into an `else` that UNBANNED).
// inviteMessage: the sentence the admin sees when Supabase refuses an invite, chosen by status and code, never by
// the message text. The raw status, code and message go to hr.sign_in_changes.reason, not to the screen.

export type Plan =
  | { auth: "recover"; notify: "none" }
  | { auth: "invite"; notify: "slack" }
  | { auth: "ban"; ban: "876000h"; notify: "slack+email" }
  | { auth: "unban"; ban: "none"; notify: "slack+email" };

export function planAction(action: string): Plan {
  switch (action) {
    case "reset_email": return { auth: "recover", notify: "none" };
    case "invite": return { auth: "invite", notify: "slack" };          // Slack only, no email (D10)
    case "turn_off": return { auth: "ban", ban: "876000h", notify: "slack+email" };
    case "turn_on": return { auth: "unban", ban: "none", notify: "slack+email" };
    default: throw new Error(`hr-sign-in: no plan for action "${action}"`);
  }
}

type AuthErrorLike = { name?: string; status?: number; code?: string } | null | undefined;

export function inviteMessage(error: AuthErrorLike, first: string): string {
  const status = error?.status;
  const code = error?.code;
  if (status === 422 || code === "email_exists") {
    return `${first} already has a sign-in. If they never chose a password, use Send password reset.`;
  }
  if (status === 429 || code === "over_email_send_rate_limit") return "Too many emails this hour. Try again later.";
  // timeout or server error: the email may have gone out, so never "Nothing changed"
  if (error?.name === "AuthRetryableFetchError" || status === 0 || (typeof status === "number" && status >= 500)) {
    return "The invite may not have gone out. Wait a minute and reload before sending again.";
  }
  return "The invite could not be sent. Nothing changed.";
}
