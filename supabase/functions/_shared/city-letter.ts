// _shared/city-letter.ts
//
// ONE city letter, used by BOTH senders.
//
// WHY THIS FILE EXISTS. Fred, 2026-09-02: *"the email template we send on the DERM App is different
// than the one we send from the Admin Review App, so that is important to fix, make it so all the
// emails to the city follow how it looks at the Admin Review App."*
//
// Before this, a municipality received two visibly different letters from the same company for the
// same job: send-visit-photos-email sent the structured one (a boxed SERVICE DETAILS panel, an
// attachment card, the phone number, the licensed-hauler footer), and send-derm-email sent a plain
// prose note with none of that and a different sign-off. The DERM one also closed with
// "Thanks again for your hard work - and feel free to recommend us to the restaurants in your city
// ;-)", which is not what the structured letter says to a regulator.
//
// THE MARKUP HERE WAS EXTRACTED MECHANICALLY FROM send-visit-photos-email's buildHtml, NOT RETYPED.
// scripts/probes/email/build_city_letter.py does the extraction and asserts every substitution it
// makes. Re-run it if the source template changes.
//
// WHAT IS PARAMETERISED, AND ONLY THIS:
//   - client name / address / service date        the facts of the visit
//   - serviceType                                 defaults to the fixed label below
//   - card { title, subtitle }                    the two senders attach different documents
//   - manifestsToFollow                           the blue "a second email is coming" note
//   - isTest                                      the internal test strip above the letter
//
// EVERYTHING ELSE IS FIXED COPY TO A REGULATOR AND IS NOT A REQUEST PARAMETER. If the caller could
// pass body text, the caller would choose what a regulator reads.

const LOGO_URL = 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/_brand/unclogme-logo.jpg'
const FONT_STACK = "'Manrope', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"
const SERVICE_TYPE_LABEL = 'Grease Trap Cleaning'
const CONTACT_EMAIL = 'contact@unclogme.com'
const CONTACT_PHONE = '(305) 339-5638'
const CONTACT_TEL = '+13053395638'
// Fred, 2026-08-27: footer is exactly two lines - "Licensed Grease Trap Hauler" then this.
// 🛑 It renders TWICE, once in the HTML footer and once in the plain-text alternative. Change both
// or the text part of the email silently keeps the old wording.
//
// 🛑 CORRECTED 2026-09-04. This block used to say these were company DECAL numbers and
// explicitly "NOT the hauler licence number". That was WRONG, and it is worth knowing why the wrong
// version was believable: the label was written in one editing pass on 2026-08-27 and then copied,
// so it read as an established fact while resting on nothing upstream.
//
// Fred, 2026-09-04, giving the canonical table for the first time:
//     Dade    - Hauler license LW-1133     · Decals: Moises C1184, David C0976
//     Broward - Hauler license WT-26-0104  · Decals: Moises 07675, David 07058
//
// ⇒ These two ARE the company HAULER LICENSES, one per county, which is exactly what the
//   "Licensed Grease Trap Hauler" heading above them claims. The DECALS are the per-truck numbers,
//   they live in public.vehicle_decals, and they are NOT printed here.
//
// ⚠ The canonical copy is now public.company_hauler_licenses (migration 2026-09-04_1738). These
// stay hard-coded because an edge function rendering a footer should not take a DB dependency on a
// value that only changes on a legal filing. If they ever diverge, the table wins.
// Reference: docs/reference/company-credentials.md
//
// 🛑 Do NOT put `LC-0607` here or anywhere else. Fred, 2026-08-27: *"that number LC-0607 is not
//    really from us"*. It was printed on customer-facing surfaces for months and is being purged.
// 🛑 The Dade number carries a HYPHEN. Fred, 2026-09-04: *"Keep the Hyphen over a white-space."*
//    It shipped with a space until then. Do not "normalise" it back.
const HAULER_LICENSES = 'Miami-DADE: LW-1133 &middot; Broward: WT-26-0104'
const HAULER_LICENSES_TEXT = 'Miami-DADE: LW-1133 - Broward: WT-26-0104'


function escapeHtml(s: string | null): string {
  return (s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c] ?? c))
}

function detailRow(label: string, value: string): string {
  return `<tr>
<td valign="top" style="padding:4px 14px 4px 0;font-family:${FONT_STACK};font-size:14px;line-height:1.6;color:#6b7280;white-space:nowrap;">${label}</td>
<td valign="top" style="padding:4px 0;font-family:${FONT_STACK};font-size:14px;line-height:1.6;color:#111827;font-weight:600;">${value}</td>
</tr>`
}


export interface LetterOpts {
  clientName: string
  address: string
  visitDate: string
  serviceType?: string
  card: { title: string; subtitle: string } | null
  manifestsToFollow: boolean
  isTest: boolean
  preheader?: string
}

// The copy that separates a regulator letter from a customer letter. NOT reachable from a caller:
// only the two wrappers at the bottom of this file supply it.
interface LetterCopy { greeting: string; intro: string; closing: string; testNote: string }

function buildLetterHtml(o: LetterOpts, copy: LetterCopy): string {
  const name = escapeHtml(o.clientName)
  const addr = escapeHtml(o.address || '')
  const vdate = escapeHtml(o.visitDate || '')
  const svc = escapeHtml(o.serviceType || SERVICE_TYPE_LABEL)
  const card = o.card
  const cardTitle = escapeHtml(o.card?.title || '')
  const cardSub = escapeHtml(o.card?.subtitle || '')
  const manifestsToFollow = o.manifestsToFollow
  const greeting = escapeHtml(copy.greeting)
  const intro = escapeHtml(copy.intro)
  const closing = escapeHtml(copy.closing)
  const testNote = escapeHtml(copy.testNote)
  const preheader = escapeHtml(
    o.preheader || `Grease trap service completed for ${o.clientName} at ${o.address} on ${o.visitDate}.`)

  // The test strip sits ABOVE the letter card, never inside it, so what Fred reviews below the
  // line is byte-for-byte what a municipality would receive.
  const testStrip = o.isTest
    ? `<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;"><tr><td style="padding:0 0 14px 0;font-family:${FONT_STACK};font-size:12px;line-height:1.5;color:#92400e;background:#fffbeb;border:1px solid #fcd34d;border-radius:8px;padding:10px 14px;"><strong>INTERNAL TEST.</strong> ${testNote}</td></tr></table>`
    : ''

  return `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><meta http-equiv="X-UA-Compatible" content="IE=edge"><title>Grease Trap Service Completed</title></head>
<body style="margin:0;padding:0;background-color:#f4f5f7;-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;font-size:1px;line-height:1px;color:#f4f5f7;">${preheader}</div>
<!-- ⚠ The photo-state clause was removed here on 2026-08-24 TOO, and not because Fred asked about
     the preheader -- he asked about the card. This is the hidden inbox-PREVIEW line, and leaving it
     conditional would have made the same email say "with before &amp; after photos" in the inbox
     and "Service details only" on the card. That contradiction would have been introduced BY the
     card change, so removing it is part of that change, not scope added to it. -->
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f4f5f7;"><tr><td align="center" style="padding:32px 16px;">
${testStrip}
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;background-color:#ffffff;border-radius:12px;border:1px solid #e6e8eb;">
<tr><td style="padding:26px 36px 18px 36px;border-bottom:2px solid #f14714;"><img src="${LOGO_URL}" alt="UnclogMe" width="144" height="48" style="display:block;border:0;outline:none;text-decoration:none;height:48px;width:144px;"></td></tr>

<tr><td style="padding:30px 36px 0 36px;font-family:${FONT_STACK};">
<p style="margin:0 0 16px 0;font-size:16px;line-height:1.5;font-weight:700;color:#111827;">${greeting}</p>
<p style="margin:0 0 20px 0;font-size:15px;line-height:1.65;color:#374151;">${intro}</p>
</td></tr>

${manifestsToFollow ? `
<tr><td style="padding:0 36px 20px 36px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#eff5ff;border:1px solid #bfdbfe;border-radius:10px;"><tr>
<td width="52" valign="top" style="width:52px;padding:16px 0 16px 16px;"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr><td align="center" valign="middle" width="26" height="26" style="width:26px;height:26px;line-height:26px;background-color:#2563eb;border-radius:13px;font-family:${FONT_STACK};font-size:15px;font-weight:700;color:#ffffff;">i</td></tr></table></td>
<td valign="top" style="padding:16px 18px 16px 4px;font-family:${FONT_STACK};font-size:14px;line-height:1.6;color:#1e3a8a;"><strong style="font-weight:700;">Please note:</strong> The DERM Manifest and Transporter Manifest will be sent in a separate email once the collected material has been delivered to the approved disposal facility. You will receive that confirmation shortly.</td>
</tr></table>
</td></tr>
` : ''}

<tr><td style="padding:0 36px 24px 36px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#fff7f4;border:1px solid #ffd9c9;border-radius:10px;"><tr><td style="padding:16px 18px;">
<p style="margin:0 0 10px 0;font-family:${FONT_STACK};font-size:12px;font-weight:700;letter-spacing:0.6px;text-transform:uppercase;color:#d63d12;">Service Details</p>
<table role="presentation" cellpadding="0" cellspacing="0" border="0">
${detailRow('Client', name)}
${detailRow('Location', addr)}
${detailRow('Service Date', vdate)}
${detailRow('Service Type', svc)}
</table>
</td></tr></table>
</td></tr>

${card ? `
<tr><td style="padding:0 36px 24px 36px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f8fafc;border:1px solid #e6e8eb;border-radius:10px;"><tr><td style="padding:16px 18px;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
<td valign="middle" width="40" style="width:40px;"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr><td align="center" valign="middle" height="40" style="width:40px;height:40px;background-color:#f14714;border-radius:8px;font-family:Arial,Helvetica,sans-serif;font-size:11px;font-weight:bold;color:#ffffff;letter-spacing:0.5px;">PDF</td></tr></table></td>
<td valign="middle" style="padding-left:14px;font-family:${FONT_STACK};">
<!-- The card copy is supplied by the CALLER, because the two senders attach different documents:
     the completion notice attaches the Job Completion Report, the DERM submission attaches the
     manifest documents. Everything else on this letter is identical for both, which is the whole
     point of this module.
     WARNING: this comment sits INSIDE a JS template literal. A backtick here terminates the
     string and the deploy fails to parse. Never use backticks in an HTML comment in this file. -->
<div style="font-size:14px;font-weight:600;color:#111827;line-height:1.3;">${cardTitle}</div>
<div style="font-size:13px;color:#6b7280;line-height:1.3;padding-top:2px;">${cardSub}</div>
</td></tr></table>
</td></tr></table>
</td></tr>
` : ''}

<tr><td style="padding:0 36px 8px 36px;font-family:${FONT_STACK};">
<p style="margin:0 0 16px 0;font-size:15px;line-height:1.65;color:#374151;">If you have any questions or need additional information regarding this service, please don't hesitate to reach out to us at <a href="mailto:${CONTACT_EMAIL}" style="color:#d63d12;text-decoration:underline;font-weight:600;">${CONTACT_EMAIL}</a> or call us directly at <a href="tel:${CONTACT_TEL}" style="color:#d63d12;text-decoration:underline;font-weight:600;">${CONTACT_PHONE}</a>.</p>
<p style="margin:0 0 22px 0;font-size:15px;line-height:1.65;color:#374151;">${closing}</p>
<p style="margin:0 0 4px 0;font-size:15px;line-height:1.65;font-weight:700;color:#111827;">The UnclogMe Team</p>
</td></tr>

<tr><td style="padding:18px 36px 26px 36px;background-color:#fafbfc;border-top:1px solid #eef0f2;font-family:${FONT_STACK};">
<p style="margin:0 0 4px 0;font-size:13px;font-weight:700;color:#374151;">Licensed Grease Trap Hauler</p>
<p style="margin:0 0 6px 0;font-size:12px;line-height:1.5;color:#6b7280;">${HAULER_LICENSES}</p>
<p style="margin:0;font-size:12px;line-height:1.5;color:#9ca3af;"><a href="mailto:${CONTACT_EMAIL}" style="color:#9ca3af;text-decoration:underline;">${CONTACT_EMAIL}</a> &middot; ${CONTACT_PHONE} &middot; <a href="https://unclogme.com" style="color:#9ca3af;text-decoration:underline;">unclogme.com</a></p>
</td></tr>
</table>
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;"><tr><td style="padding:16px 36px;text-align:center;font-family:${FONT_STACK};font-size:11px;color:#b6bcc4;line-height:1.5;">Sent by Unclogme LLC for FOG / grease-trap compliance notification.</td></tr></table>
</td></tr></table>
</body></html>`
}

function buildLetterText(o: LetterOpts, copy: LetterCopy): string {
  return [
    copy.greeting, '',
    copy.intro, '',
    'Service Details:',
    `  - Client: ${o.clientName}.`,
    `  - Location: ${o.address}.`,
    `  - Service Date: ${o.visitDate}.`,
    `  - Service Type: ${o.serviceType || SERVICE_TYPE_LABEL}.`, '',
    // Mirrors the HTML card. The two must move together: send-visit-photos-email shipped a bug
    // where a plain-text reader saw wording the HTML reader did not.
    ...(o.card ? [`Attached: ${o.card.title} (${o.card.subtitle})`, ''] : []),
    ...(o.manifestsToFollow
      ? ['Please note: The DERM Manifest and Transporter Manifest will be sent in a separate email once the collected material has been delivered to the approved disposal facility. You will receive that confirmation shortly.', '']
      : []),
    `If you have any questions or need additional information regarding this service, please don't hesitate to reach out to us at ${CONTACT_EMAIL} or call us directly at ${CONTACT_PHONE}.`, '',
    copy.closing, '',
    'The UnclogMe Team',
    'Licensed Grease Trap Hauler',
    HAULER_LICENSES_TEXT,
    `${CONTACT_EMAIL} - ${CONTACT_PHONE} - unclogme.com`,
  ].join('\n')
}


// ---------------------------------------------------------------------------
// THE TWO LETTERS. Their copy is fixed here and is NOT a caller parameter: a caller who could pass
// body text would be choosing what a regulator, or a paying customer, reads.
// ---------------------------------------------------------------------------

const CITY_COPY: LetterCopy = {
  greeting: 'Dear Environmental Compliance Team,',
  intro: 'We are writing to confirm that the scheduled grease trap service for the location below has been successfully completed.',
  closing: 'Thank you for your continued partnership in keeping our community compliant and clean.',
  testNote: 'City sending is disabled; this went only to the internal test address. Everything below the line is exactly what the municipality would receive.',
}

// The customer letter keeps the wording Unclogme has always used with clients. Only the SHELL is
// shared: the same service-details panel, attachment card, phone number and licensed-hauler footer
// the city letter has. Before 2026-09-03 the client letter had none of those.
function clientCopy(clientName: string): LetterCopy {
  return {
    greeting: `Hi ${clientName},`,
    intro: 'Thank you for choosing Unclogme! Your Service Report for this service is attached, including your Manifest Form and the corresponding disposal receipt.',
    closing: 'Please review it carefully and keep it for your compliance records.',
    // NOT the city wording. Sharing the shell nearly told a paying customer that this is
    // "exactly what the municipality would receive", which is both wrong and confusing.
    testNote: 'This went only to the internal test address, not to the client. Everything below the line is exactly what the customer would receive.',
  }
}

export function buildCityLetterHtml(o: LetterOpts): string { return buildLetterHtml(o, CITY_COPY) }
export function buildCityLetterText(o: LetterOpts): string { return buildLetterText(o, CITY_COPY) }
export function buildClientLetterHtml(o: LetterOpts): string { return buildLetterHtml(o, clientCopy(o.clientName)) }
export function buildClientLetterText(o: LetterOpts): string { return buildLetterText(o, clientCopy(o.clientName)) }
