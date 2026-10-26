// invite-email.ts: the invite email we send ourselves (2026-10-26, new hires, Trello zRTbWvXn). Design B ("Three
// steps"), picked by Fred on https://claude.ai/artifact/JEjBA6vekyjEmzZzUMLsxA ("B, send it ourselves, keep 1 hour").
// Pure and import-free so invite-email.test.mjs runs it under plain Node. Email-safe: tables, inline styles, bgcolor.
// The link is Supabase's own one-use invite link (generate_link, type invite); it is never logged or returned.

export type InviteEmailInput = { firstName: string; inviterName: string; link: string; expiresAt: Date };
export type InviteEmail = { subject: string; html: string; text: string; expiresLabel: string };

const esc = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");

// "3:42 PM ET", plus the day when the link expires on a later ET day than it was sent ("12:15 AM ET on Oct 27")
export function expiresLabel(expiresAt: Date): string {
  const tz = "America/New_York";
  const time = new Intl.DateTimeFormat("en-US", { timeZone: tz, hour: "numeric", minute: "2-digit" }).format(expiresAt);
  const day = (d: Date) => new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
  const sent = new Date(expiresAt.getTime() - 3600_000);
  if (day(sent) === day(expiresAt)) return `${time} ET`;
  return `${time} ET on ${new Intl.DateTimeFormat("en-US", { timeZone: tz, month: "short", day: "numeric" }).format(expiresAt)}`;
}

const FONT = "'Manrope',-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";
// An explicit link: left as plain text, Gmail auto-links the domain in its own blue (seen in the 2026-10-26 live test).
const HUB = `<a href="https://hub.unclogme.app" style="color:#c93a0f;text-decoration:none;">hub.unclogme.app</a>`;

function step(n: number, active: boolean, title: string, body: string, extra = "", last = false): string {
  const badge = active
    ? `<td width="34" height="34" align="center" valign="middle" bgcolor="#f14714" style="width:34px;height:34px;border-radius:17px;background-color:#f14714;color:#ffffff;font-family:${FONT};font-size:16px;font-weight:800;">${n}</td>`
    : `<td width="30" height="30" align="center" valign="middle" style="width:30px;height:30px;border-radius:17px;border:2px solid #f14714;color:#c93a0f;font-family:${FONT};font-size:16px;font-weight:800;">${n}</td>`;
  return `<tr><td style="padding:0 0 ${last ? 0 : 24}px 0;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
<td width="50" valign="top" style="width:50px;"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>${badge}</tr></table></td>
<td valign="top" style="font-family:${FONT};">
<p style="margin:4px 0 6px 0;font-size:18px;line-height:1.3;font-weight:800;color:#18181b;">${title}</p>
<p style="margin:0;font-size:15px;line-height:1.55;color:#3f3f46;">${body}</p>${extra}
</td></tr></table></td></tr>`;
}

export function inviteEmail(p: InviteEmailInput): InviteEmail {
  const first = esc(p.firstName || "there");
  const inviter = esc(p.inviterName || "An admin");
  const link = esc(p.link);
  const until = expiresLabel(p.expiresAt);
  const subject = "Set up your UnclogMe account";
  const button = `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:14px;"><tr>
<td align="center" bgcolor="#f14714" style="border-radius:10px;background-color:#f14714;"><a href="${link}" style="display:inline-block;padding:15px 28px;font-family:${FONT};font-size:19px;font-weight:700;color:#ffffff;text-decoration:none;border-radius:10px;">Choose your password</a></td>
</tr></table>`;
  const html = `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>${subject}</title></head>
<body style="margin:0;padding:0;background-color:#e4e4e7;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;font-size:1px;color:#e4e4e7;">Three steps, about a minute. The link works until ${until}.</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#e4e4e7" style="background-color:#e4e4e7;"><tr><td align="center" style="padding:28px 12px;">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:600px;background-color:#ffffff;border:1px solid #e4e4e7;border-radius:16px;">
<tr><td style="padding:22px 32px;border-bottom:1px solid #f0f0f2;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
<td valign="middle"><img src="https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/_brand/unclogme-logo.jpg" alt="UnclogMe" width="132" height="44" style="display:block;border:0;width:132px;height:44px;"></td>
<td valign="middle" align="right"><span style="display:inline-block;background-color:#f4f4f5;border:1px solid #e4e4e7;border-radius:999px;padding:6px 12px;font-family:${FONT};font-size:13px;font-weight:600;color:#3f3f46;">Link works until ${until}</span></td>
</tr></table></td></tr>
<tr><td style="padding:32px 32px 8px 32px;font-family:${FONT};">
<p style="margin:0 0 10px 0;font-size:28px;line-height:1.15;font-weight:800;color:#18181b;">Your staff account is ready</p>
<p style="margin:0 0 26px 0;font-size:16px;line-height:1.6;color:#3f3f46;">Hi ${first}, ${inviter} invited you to UnclogMe. Here is how to get in.</p>
</td></tr>
<tr><td style="padding:0 32px 8px 32px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
${step(1, true, "Choose your password", `The button opens a page on ${HUB}. The link works once.`, button)}
${step(2, false, `Sign in at ${HUB}`, "Use this email address and your new password. On your own phone, leave Remember me ticked.")}
${step(3, false, "Open your apps", `The apps you can use are on the Hub. If one you need is missing, ask ${inviter}.`, "", true)}
</table></td></tr>
<tr><td style="padding:22px 32px 28px 32px;font-family:${FONT};">
<p style="margin:0;font-size:13px;line-height:1.6;color:#52525b;word-break:break-all;">Button not working? Paste this link into your browser:<br><a href="${link}" style="color:#c93a0f;">${link}</a></p>
</td></tr>
<tr><td style="padding:18px 32px 22px 32px;background-color:#fafafa;border-top:1px solid #e4e4e7;border-radius:0 0 16px 16px;font-family:${FONT};">
<p style="margin:0 0 6px 0;font-size:13px;line-height:1.6;color:#52525b;">Link expired? Ask ${inviter} to send a new invite. Not expecting this email? You can ignore it.</p>
<p style="margin:0;font-size:12px;line-height:1.5;color:#52525b;"><strong style="color:#3f3f46;">Unclogme LLC</strong> · 333 West 41st Street, Suite 606, Miami Beach, FL 33140</p>
</td></tr>
</table></td></tr></table></body></html>`;
  const text = [
    "Your staff account is ready",
    "",
    `Hi ${p.firstName || "there"}, ${p.inviterName || "An admin"} invited you to UnclogMe. Here is how to get in.`,
    "",
    "1. Choose your password (the link works once, until " + until + "):",
    p.link,
    "",
    "2. Sign in at hub.unclogme.app with this email address and your new password.",
    "3. Open your apps from the Hub.",
    "",
    `Link expired? Ask ${p.inviterName || "an admin"} to send a new invite. Not expecting this email? You can ignore it.`,
    "",
    "Unclogme LLC · 333 West 41st Street, Suite 606, Miami Beach, FL 33140",
  ].join("\n");
  return { subject, html, text, expiresLabel: until };
}
