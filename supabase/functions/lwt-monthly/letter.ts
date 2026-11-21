// lwt-monthly/letter.ts: the email that carries the Monthly Report to the county (Trello #238, 2026-11-21).
//
// Fred, 2026-11-21: "now we're missing is the email, and the template for the email. Also when sending the email depending
// on the selected file format that's how's gonna be attached to the email (pdf or excel)".
//
// The SAME shell as the city letter (_shared/city-letter.ts): its logo, font, contact line and licensed-hauler footer are
// imported from there, so a change to the company's phone or licences reaches both letters. Only the body differs: a
// report to the county, not a visit.
// shortcut: the outer table markup is copied from city-letter.ts's buildLetterHtml, not shared; make that function take a
// details list if a third letter ever needs the same shell.
//
// EVERYTHING HERE IS FIXED COPY TO A REGULATOR AND IS NOT A REQUEST PARAMETER, as in the city letter: the caller passes
// facts (the month, the counts, the file), never words.

import { CONTACT_EMAIL, CONTACT_PHONE, FONT_STACK, HAULER_LICENSES, HAULER_LICENSES_TEXT, LOGO_URL, detailRow, escapeHtml } from '../_shared/city-letter.ts'

export interface CountyLetter {
  month: string            // "October 2026"
  tickets: number
  gallons: string          // as the filing history shows it, "21,737"
  invoice: string | null   // the county's invoice number, when the report has one
  fileName: string         // "LWT_report_2026-10.pdf"
  format: 'pdf' | 'xlsx'
  testTo: string | null    // a test copy to an internal address: a strip above the letter says so
}

const GREETING = 'Dear Environmental Compliance Team,'
const kindOf = (f: 'pdf' | 'xlsx') => (f === 'pdf' ? 'PDF' : 'Excel spreadsheet')

export const countySubject = (o: CountyLetter) =>
  `${o.testTo ? '[TEST] ' : ''}UnclogMe, Liquid Waste Transporter report, ${o.month}`

function intro(o: CountyLetter) {
  return `Please find attached UnclogMe's Liquid Waste Transporter monthly report for ${o.month}.`
}

function rows(o: CountyLetter): Array<[string, string]> {
  return [
    ['Hauler', 'Unclogme LLC, license LW-1133'],
    ['Report Period', o.month],
    ...(o.invoice ? [['County Invoice', o.invoice] as [string, string]] : []),
    ['Tickets', String(o.tickets)],
    ['Gallons', o.gallons],
  ]
}

export function countyLetterHtml(o: CountyLetter): string {
  const testStrip = o.testTo
    ? `<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;"><tr><td style="padding:10px 14px;font-family:${FONT_STACK};font-size:12px;line-height:1.5;color:#92400e;background:#fffbeb;border:1px solid #fde68a;border-radius:8px;"><strong>INTERNAL TEST.</strong> This copy went only to ${escapeHtml(o.testTo)}; the county did not receive it, and nothing was recorded as filed. Everything below the line is exactly what the county would receive.</td></tr></table><div style="height:14px;line-height:14px;">&nbsp;</div>`
    : ''
  return `<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><meta http-equiv="X-UA-Compatible" content="IE=edge"><title>Liquid Waste Transporter Report</title></head>
<body style="margin:0;padding:0;background-color:#f4f5f7;-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;font-size:1px;line-height:1px;color:#f4f5f7;">${escapeHtml(intro(o))}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f4f5f7;"><tr><td align="center" style="padding:32px 16px;">
${testStrip}
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;background-color:#ffffff;border-radius:12px;border:1px solid #e6e8eb;">
<tr><td style="padding:26px 36px 18px 36px;border-bottom:2px solid #f14714;"><img src="${LOGO_URL}" alt="UnclogMe" width="144" height="48" style="display:block;border:0;outline:none;text-decoration:none;height:48px;width:144px;"></td></tr>

<tr><td style="padding:30px 36px 0 36px;font-family:${FONT_STACK};">
<p style="margin:0 0 16px 0;font-size:16px;line-height:1.5;font-weight:700;color:#111827;">${escapeHtml(GREETING)}</p>
<p style="margin:0 0 20px 0;font-size:15px;line-height:1.65;color:#374151;">${escapeHtml(intro(o))}</p>
</td></tr>

<tr><td style="padding:0 36px 24px 36px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#fff7f4;border:1px solid #ffd9c9;border-radius:10px;"><tr><td style="padding:16px 18px;">
<p style="margin:0 0 10px 0;font-family:${FONT_STACK};font-size:12px;font-weight:700;letter-spacing:0.6px;text-transform:uppercase;color:#d63d12;">Report Details</p>
<table role="presentation" cellpadding="0" cellspacing="0" border="0">
${rows(o).map(([k, v]) => detailRow(escapeHtml(k), escapeHtml(v))).join('\n')}
</table>
</td></tr></table>
</td></tr>

<tr><td style="padding:0 36px 24px 36px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f8fafc;border:1px solid #e6e8eb;border-radius:10px;"><tr><td style="padding:16px 18px;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
<td valign="middle" width="40" style="width:40px;"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr><td align="center" valign="middle" height="40" style="width:40px;height:40px;background-color:#f14714;border-radius:8px;font-family:Arial,Helvetica,sans-serif;font-size:11px;font-weight:700;color:#ffffff;">${o.format === 'pdf' ? 'PDF' : 'XLSX'}</td></tr></table></td>
<td valign="middle" style="padding-left:14px;font-family:${FONT_STACK};">
<div style="font-size:14px;font-weight:600;color:#111827;line-height:1.3;">${escapeHtml(o.fileName)}</div>
<div style="font-size:13px;color:#6b7280;line-height:1.3;padding-top:2px;">Monthly report, ${kindOf(o.format)}, attached</div>
</td></tr></table>
</td></tr></table>
</td></tr>

<tr><td style="padding:0 36px 8px 36px;font-family:${FONT_STACK};">
<p style="margin:0 0 16px 0;font-size:15px;line-height:1.65;color:#374151;">If you have any questions or need additional information regarding this report, please don't hesitate to reach out to us at <a href="mailto:${CONTACT_EMAIL}" style="color:#d63d12;text-decoration:underline;">${CONTACT_EMAIL}</a> or call us directly at ${CONTACT_PHONE}.</p>
<p style="margin:0 0 22px 0;font-size:15px;line-height:1.65;color:#374151;">Thank you.</p>
<p style="margin:0 0 4px 0;font-size:15px;line-height:1.65;font-weight:700;color:#111827;">The UnclogMe Team</p>
</td></tr>

<tr><td style="padding:18px 36px 26px 36px;background-color:#fafbfc;border-top:1px solid #eef0f2;font-family:${FONT_STACK};">
<p style="margin:0 0 4px 0;font-size:13px;font-weight:700;color:#374151;">Licensed Grease Trap Hauler</p>
<p style="margin:0 0 6px 0;font-size:12px;line-height:1.5;color:#6b7280;">${HAULER_LICENSES}</p>
<p style="margin:0;font-size:12px;line-height:1.5;color:#9ca3af;"><a href="mailto:${CONTACT_EMAIL}" style="color:#9ca3af;text-decoration:underline;">${CONTACT_EMAIL}</a> &middot; ${CONTACT_PHONE} &middot; <a href="https://unclogme.com" style="color:#9ca3af;text-decoration:underline;">unclogme.com</a></p>
</td></tr>
</table>
<table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px;max-width:600px;"><tr><td style="padding:16px 36px;text-align:center;font-family:${FONT_STACK};font-size:11px;color:#b6bcc4;line-height:1.5;">Sent by Unclogme LLC, Liquid Waste Transporter monthly report.</td></tr></table>
</td></tr></table>
</body></html>`
}

export function countyLetterText(o: CountyLetter): string {
  return [
    ...(o.testTo ? [`INTERNAL TEST. This copy went only to ${o.testTo}; the county did not receive it, and nothing was recorded as filed.`, ''] : []),
    GREETING, '',
    intro(o), '',
    'Report Details:',
    ...rows(o).map(([k, v]) => `  - ${k}: ${v}`), '',
    `Attached: ${o.fileName} (monthly report, ${kindOf(o.format)})`, '',
    `If you have any questions or need additional information regarding this report, please don't hesitate to reach out to us at ${CONTACT_EMAIL} or call us directly at ${CONTACT_PHONE}.`, '',
    'Thank you.', '',
    'The UnclogMe Team',
    'Licensed Grease Trap Hauler',
    HAULER_LICENSES_TEXT,
    `${CONTACT_EMAIL} - ${CONTACT_PHONE} - unclogme.com`,
  ].join('\n')
}
