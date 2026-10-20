// archive-copy.ts: D5 (2026-10-20, migration 2026-10-20_1900). The hidden copies of a city email (our archive inbox
// derm@ayache.com and any Bcc a person typed) go as their OWN email, sent right after the city email.
//
// Why: Resend puts one tracking image in an email and counts an open for EVERY recipient on it, so while the archive
// rode as a Bcc, anyone opening our copy made the city read as opened, and a city open could never be counted. Yan
// asked for an alert on delivered but unopened emails (Trello xMtqH9Xw); Fred picked "Build D5 first" (2026-10-20).
// Design: docs/superpowers/specs/2026-10-14-email-delivery-status-audit.md section 5.8.
//
// Rules the callers rely on:
// - It NEVER throws. The city email has already gone when this runs, so a failure here must never turn a delivered
//   city email into an error (the audit's main risk). It returns { id, error }; the caller writes both on the SAME
//   send-log row (archive_resend_email_id / archive_error) and nothing else.
// - Same subject, html, text and attachments as the city email, no second render. A visible first line says what it
//   is, who the city email went to and when, because the archive copy no longer carries the city's To header.
// - Idempotency-Key "archive:<city resend id>", a 30-second timeout and ONE retry on 429, 5xx or a network error. The
//   retry reuses the key, so a first request that actually landed is not sent twice (Resend keeps keys 24 hours).

export const ARCHIVE_INBOX = 'derm@ayache.com'
const TIMEOUT_MS = 30_000

export type Attachment = { filename: string; content: string; content_type?: string }
export type ArchiveResult = { id: string | null; error: string | null }

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

const etTime = (d: Date) => new Intl.DateTimeFormat('en-US', {
  timeZone: 'America/New_York', weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
}).format(d) + ' ET'

/** The hidden-copy list: the archive inbox (unless a test send) plus every Bcc, lower-cased, deduped. */
export function hiddenCopies(bccs: string[], withArchive: boolean): string[] {
  return [...new Set([...(withArchive ? [ARCHIVE_INBOX] : []), ...bccs]
    .map((e) => String(e ?? '').trim().toLowerCase()).filter((e) => e.includes('@')))]
}

/** The line the archive copy starts with. */
export function archiveLine(cityTo: string[], cityCc: string[], sentAt: Date): string {
  return `Archive copy of the email sent to the city (${cityTo.join(', ')}) on ${etTime(sentAt)}.` +
    (cityCc.length ? ` Cc: ${cityCc.join(', ')}.` : '')
}

function withLineHtml(html: string, line: string): string {
  const block = `<div style="margin:0 0 12px;padding:8px 12px;border:1px solid #e5e7eb;border-radius:6px;background:#f8fafc;` +
    `color:#475569;font-family:Arial,Helvetica,sans-serif;font-size:12px;line-height:1.5;">${esc(line)}</div>`
  const m = /<body[^>]*>/i.exec(html)
  return m ? html.slice(0, m.index + m[0].length) + block + html.slice(m.index + m[0].length) : block + html
}

export async function sendArchiveCopy(o: {
  apiKey: string
  cityEmailId: string
  from: string
  to: string[]
  cityTo: string[]
  cityCc?: string[]
  sentAt: Date
  subject: string
  html: string
  text?: string
  attachments: Attachment[]
  replyTo?: string
  fetchImpl?: typeof fetch
}): Promise<ArchiveResult> {
  const f = o.fetchImpl ?? fetch
  try {
    if (!o.to.length) return { id: null, error: null } // nothing hidden to send (a test send with no copies)
    const line = archiveLine(o.cityTo, o.cityCc ?? [], o.sentAt)
    const body = JSON.stringify({
      from: o.from,
      to: o.to,
      ...(o.replyTo ? { reply_to: o.replyTo } : {}),
      subject: o.subject,
      html: withLineHtml(o.html, line),
      ...(o.text !== undefined ? { text: `${line}\n\n${o.text}` } : {}),
      attachments: o.attachments,
      headers: { 'X-Unclogme-Archive-Of': o.cityEmailId },
    })
    let last = ''
    for (let attempt = 1; attempt <= 2; attempt++) {
      const ctrl = new AbortController()
      const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS)
      try {
        const r = await f('https://api.resend.com/emails', {
          method: 'POST', signal: ctrl.signal,
          headers: {
            Authorization: `Bearer ${o.apiKey}`, 'Content-Type': 'application/json',
            'Idempotency-Key': `archive:${o.cityEmailId}`,
          },
          body,
        })
        const j = await r.json().catch(() => ({})) as { id?: string; message?: string; name?: string }
        if (r.ok && j?.id) return { id: j.id, error: null }
        last = `resend ${r.status}: ${String(j?.message ?? j?.name ?? 'no id in the answer').slice(0, 200)}`
        if (!(r.status === 429 || r.status >= 500)) break // a clear refusal: retrying would not help
      } catch (e) {
        last = ctrl.signal.aborted ? `timeout after ${TIMEOUT_MS / 1000}s` : String((e as Error)?.message ?? e).slice(0, 200)
      } finally {
        clearTimeout(timer)
      }
    }
    return { id: null, error: last || 'unknown error' }
  } catch (e) {
    return { id: null, error: String((e as Error)?.message ?? e).slice(0, 200) }
  }
}
