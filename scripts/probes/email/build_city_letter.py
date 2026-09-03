import io, re
NL = chr(10)
BT = chr(96)  # backtick
SRC = 'supabase/functions/send-visit-photos-email/index.ts'
s = io.open(SRC, encoding='utf-8').read()

# ---- extract the HTML literal from buildHtml, verbatim -----------------------
start_anchor = '  return ' + BT + '<!DOCTYPE html>'
i = s.index(start_anchor)
j = s.index('</body></html>' + BT, i)
html = s[i + len('  return ' + BT): j + len('</body></html>')]
assert html.startswith('<!DOCTYPE html>'), html[:40]
assert 'Dear Environmental Compliance Team' in html
assert 'Service Details' in html
assert 'Job Completion Report' in html

# ---- parameterise, each replacement asserted -------------------------------
def rep(old, new, label, count=1):
    global html
    assert html.count(old) == count, '%s matched %d (expected %d)' % (label, html.count(old), count)
    html = html.replace(old, new)

# preheader
rep('Grease trap service completed for ${name} at ${addr} on ${vdate}. Job Completion Report attached.',
    '${preheader}', 'preheader')

# service type row
rep("${detailRow('Service Type', SERVICE_TYPE_LABEL)}",
    "${detailRow('Service Type', svc)}", 'service type')

# attachment card title + subtitle
rep('<div style="font-size:14px;font-weight:600;color:#111827;line-height:1.3;">Job Completion Report</div>',
    '<div style="font-size:14px;font-weight:600;color:#111827;line-height:1.3;">${cardTitle}</div>',
    'card title')
rep('<div style="font-size:13px;color:#6b7280;line-height:1.3;padding-top:2px;">Service details only</div>',
    '<div style="font-size:13px;color:#6b7280;line-height:1.3;padding-top:2px;">${cardSub}</div>',
    'card subtitle')

# the "manifests to follow" note: invert the flag so the shared name says what it does
rep('${hasDermDocs ? ' + "''" + ' : ' + BT, '${manifestsToFollow ? ' + BT, 'note open')
rep(BT + '}' + NL + NL + '<tr><td style="padding:0 36px 24px 36px;">' + NL +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#fff7f4;',
    BT + ' : ' + "''" + '}' + NL + NL + '<tr><td style="padding:0 36px 24px 36px;">' + NL +
    '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#fff7f4;',
    'note close')

# 2026-09-03: the greeting / intro / closing / signoff become parameters so the CLIENT letter can
# share this exact shell. The city wrapper below still hard-codes its own regulator copy, so a
# caller cannot choose what a municipality reads; only the two wrappers in this file can.
rep('<p style="margin:0 0 16px 0;font-size:16px;line-height:1.5;font-weight:700;color:#111827;">Dear Environmental Compliance Team,</p>',
    '<p style="margin:0 0 16px 0;font-size:16px;line-height:1.5;font-weight:700;color:#111827;">${greeting}</p>',
    'greeting')
rep('<p style="margin:0 0 20px 0;font-size:15px;line-height:1.65;color:#374151;">We are writing to confirm that the scheduled grease trap service for the location below has been successfully completed.</p>',
    '<p style="margin:0 0 20px 0;font-size:15px;line-height:1.65;color:#374151;">${intro}</p>',
    'intro')
rep('<p style="margin:0 0 22px 0;font-size:15px;line-height:1.65;color:#374151;">Thank you for your continued partnership in keeping our community compliant and clean.</p>',
    '<p style="margin:0 0 22px 0;font-size:15px;line-height:1.65;color:#374151;">${closing}</p>',
    'closing')

# the attachment card must be OMISSIBLE: send-derm-email has a branch where the letter goes out
# with no attachment at all (Fred chose that a visit with no Service Report still gets the letter),
# and a card promising a document that is not there is exactly the dishonesty CITY_ATTACH_COPY's
# `none` branch existed to avoid.
CARD_OPEN = ('<tr><td style="padding:0 36px 24px 36px;">' + NL +
  '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" '
  'style="background-color:#f8fafc;')
assert html.count(CARD_OPEN) == 1, 'card open anchor'
html = html.replace(CARD_OPEN, '${card ? `' + NL + CARD_OPEN)

CARD_CLOSE = ('</td></tr></table>' + NL + '</td></tr>' + NL + NL +
  '<tr><td style="padding:0 36px 8px 36px;font-family:${FONT_STACK};">')
assert html.count(CARD_CLOSE) == 1, 'card close anchor'
html = html.replace(CARD_CLOSE,
  '</td></tr></table>' + NL + '</td></tr>' + NL + '`' + ' : ' + "''" + '}' + NL + NL +
  '<tr><td style="padding:0 36px 8px 36px;font-family:${FONT_STACK};">')

# the card comment block refers to variables that do not exist here; replace it with one that
# describes the shared module honestly. Everything else in the markup is untouched.
m = re.search(r'<!-- \xf0\x9f\x9b\x91 2026-08-24, Fred: this card is FIXED COPY\..*?-->', html, re.S)
if m is None:
    m = re.search(r'<!--[^>]{0,40}2026-08-24, Fred: this card is FIXED COPY\..*?-->', html, re.S)
assert m, 'card comment not found'
html = html[:m.start()] + (
 '<!-- The card copy is supplied by the CALLER, because the two senders attach different documents:\n'
 '     the completion notice attaches the Job Completion Report, the DERM submission attaches the\n'
 '     manifest documents. Everything else on this letter is identical for both, which is the whole\n'
 '     point of this module.\n'
 '     WARNING: this comment sits INSIDE a JS template literal. A backtick here terminates the\n'
 '     string and the deploy fails to parse. Never use backticks in an HTML comment in this file. -->'
) + html[m.end():]

# ---- extract the constants + helpers verbatim ------------------------------
def grab(anchor, end_anchor):
    a = s.index(anchor); b = s.index(end_anchor, a)
    return s[a:b]

consts = grab("const LOGO_URL =", "function escapeHtml")
assert 'DERM_DECALS_TEXT' in consts

esc = grab('function escapeHtml(s: string | null): string {', NL + '}' + NL) + NL + '}' + NL
detail = grab('function detailRow(label: string, value: string): string {', NL + '}' + NL) + NL + '}' + NL

HEADER = '''// _shared/city-letter.ts
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

'''

BODY = '''
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

  return `HTML_LITERAL`
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
    DERM_DECALS_TEXT,
    `${CONTACT_EMAIL} - ${CONTACT_PHONE} - unclogme.com`,
  ].join('\\n')
}
'''

BODY = BODY + '\n\n// ---------------------------------------------------------------------------\n// THE TWO LETTERS. Their copy is fixed here and is NOT a caller parameter: a caller who could pass\n// body text would be choosing what a regulator, or a paying customer, reads.\n// ---------------------------------------------------------------------------\n\nconst CITY_COPY: LetterCopy = {\n  greeting: \'Dear Environmental Compliance Team,\',\n  intro: \'We are writing to confirm that the scheduled grease trap service for the location below has been successfully completed.\',\n  closing: \'Thank you for your continued partnership in keeping our community compliant and clean.\',\n  testNote: \'City sending is disabled; this went only to the internal test address. Everything below the line is exactly what the municipality would receive.\',\n}\n\n// The customer letter keeps the wording Unclogme has always used with clients. Only the SHELL is\n// shared: the same service-details panel, attachment card, phone number and licensed-hauler footer\n// the city letter has. Before 2026-09-03 the client letter had none of those.\nfunction clientCopy(clientName: string): LetterCopy {\n  return {\n    greeting: `Hi ${clientName},`,\n    intro: \'Thank you for choosing Unclogme! Your Service Report for this service is attached, including your Manifest Form and the corresponding disposal receipt.\',\n    closing: \'Please review it carefully and keep it for your compliance records.\',\n    // NOT the city wording. Sharing the shell nearly told a paying customer that this is\n    // "exactly what the municipality would receive", which is both wrong and confusing.\n    testNote: \'This went only to the internal test address, not to the client. Everything below the line is exactly what the customer would receive.\',\n  }\n}\n\nexport function buildCityLetterHtml(o: LetterOpts): string { return buildLetterHtml(o, CITY_COPY) }\nexport function buildCityLetterText(o: LetterOpts): string { return buildLetterText(o, CITY_COPY) }\nexport function buildClientLetterHtml(o: LetterOpts): string { return buildLetterHtml(o, clientCopy(o.clientName)) }\nexport function buildClientLetterText(o: LetterOpts): string { return buildLetterText(o, clientCopy(o.clientName)) }\n'
BODY = BODY.replace('HTML_LITERAL', html)
out = HEADER + consts + NL + esc + NL + detail + NL + BODY

assert chr(8212) not in out, 'em-dash in module'
assert 'testNote:' in out, 'testNote missing from the copy objects'
# count the VALUES, not the interface declaration: `testNote: string` also matches a bare
# `testNote:` and made the first version of this guard fail on a correct file.
assert out.count("testNote: '") == 2, 'expected exactly two testNote VALUES, got %d' % out.count("testNote: '")
for fld in ('greeting:', 'intro:', 'closing:'):
    assert out.count(fld) >= 2, 'copy field %s is not defined for both letters' % fld

# a backtick inside an HTML comment would terminate the literal at deploy time
for m2 in re.finditer(r'<!--.*?-->', out, re.S):
    assert BT not in m2.group(0), 'backtick inside an HTML comment: ' + m2.group(0)[:80]

io.open('supabase/functions/_shared/city-letter.ts', 'w', encoding='utf-8', newline=NL).write(out)
print('wrote _shared/city-letter.ts', len(out), 'chars; html literal', len(html))
