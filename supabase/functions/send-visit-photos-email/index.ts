// ============================================================================
// send-visit-photos-email — the Admin Review "Send email to City" button
// ============================================================================
// Fred, 2026-08-15: the gate is classification, "because the model for the email
// it's gonna be a text i give you + the classified photos attached to it."
//
// 🛑 THIS IS NOT send-derm-email. That one mails manifest PDFs to municipal FOG
// inboxes resolved from public.municipality_regulators. This one mails a body plus
// the visit's CLASSIFIED PHOTOS. Different payload, different gate, different log
// table (public.visit_photo_email_sends, NOT derm_email_sends).
//
// 🛑 CITY SENDING IS DISABLED (Fred, 2026-08-10: "the emailing functionality to the
// city is disabled for now, until i explicitly say otherwise"). Fred's instruction
// for THIS button on 2026-08-15 was "Build it, but test-send only to me", so the
// recipient is the hard-wired constant below and every row logs is_test = true.
// 🛑 THE RECIPIENT IS NOT READABLE FROM THE REQUEST BODY, DELIBERATELY. send-derm-email
// accepts `test_recipient` as any string containing '@' with no allowlist, which means
// a caller chooses who receives a client's documents. That mistake is not repeated
// here: to change the recipient you edit this file and redeploy.
//
// 🛑 AND UNLIKE send-derm-email, THIS FUNCTION ACTUALLY CHECKS WHO IS CALLING.
// send-derm-email is deployed verify_jwt=true but asserts no role, and the public
// anon key is a valid JWT, so its effective gate is "holds a key that ships in every
// browser bundle". Here the bearer token is validated with auth.getUser() and a
// request with no real user is refused. verify_jwt is half a gate; this is the
// other half.
// ============================================================================

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { encodeBase64 } from 'https://deno.land/std@0.224.0/encoding/base64.ts'
import { decode, Image } from 'https://deno.land/x/imagescript@1.3.0/mod.ts'

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')
const RESEND_FROM = Deno.env.get('RESEND_FROM') ?? 'Unclogme <onboarding@resend.dev>'
const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? ''
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? ''

// 🛑 Hard-wired while city sending is off. Fred: "test-send only to me".
const TEST_RECIPIENT = 'fred@ayache.com'
const IS_TEST = true

const BUCKET = 'GT - Visits Images'

// Attachment budget. Measured 2026-08-15 over the 57 visits that have classified
// photos: avg 9.9MB of source, p90 24.8MB, max 36.9MB, and one SINGLE source photo
// is 28.9MB. Raw attachment would exceed Resend's 40MB ceiling and would bounce off
// most municipal mail servers long before that (many .gov gateways cap at 10-25MB).
// So every image is re-encoded down before it is attached.
const MAX_EDGE_PX = 1280      // longest side
const JPEG_QUALITY = 72
const MAX_TOTAL_BYTES = 18 * 1024 * 1024   // hard ceiling on the encoded payload
const MAX_PHOTOS = 20                       // also a CPU guard: decode is not free
const MAX_SOURCE_BYTES = 30 * 1024 * 1024   // refuse to decode a pathological source

const ALLOWED_ORIGINS = new Set([
  'https://admin.unclogme.app',
  'https://audit.unclogme.app',
])

function corsHeadersFor(origin: string | null): Record<string, string> {
  const allowed = origin && ALLOWED_ORIGINS.has(origin) ? origin : 'https://admin.unclogme.app'
  return {
    'Access-Control-Allow-Origin': allowed,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'authorization, content-type, x-client-info, apikey, x-app-source',
    'Access-Control-Max-Age': '86400',
    'Vary': 'Origin',
  }
}

function json(body: Record<string, unknown>, status: number, cors: Record<string, string>): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
}

const PHASE_LABEL: Record<string, string> = {
  before: 'Before', after: 'After', internal: 'Internal', extra: 'Extra',
}

// ---------------------------------------------------------------------------
// 🛑 PLACEHOLDER BODY. Fred is supplying the real copy ("a text i give you").
// Until he does, this states plainly that it is a test so that a stray send can
// never be mistaken for a real municipal notice. Replace COPY, redeploy; do not
// accept body text from the request, or the caller controls what a regulator reads.
// ---------------------------------------------------------------------------
const COPY = {
  subjectPrefix: '[TEST] Service photos',
  intro:
    'Please find attached the service photographs for the visit detailed below. ' +
    'This message is a TEST and is not a submission.',
}

function buildHtml(v: VisitRow, photos: Prepared[]): string {
  const rows = (['before', 'after', 'internal', 'extra'] as const)
    .map((p) => [p, photos.filter((x) => x.phase === p).length] as const)
    .filter(([, n]) => n > 0)
    .map(([p, n]) => `<li>${PHASE_LABEL[p]}: ${n}</li>`)
    .join('')
  const esc = (s: string | null) => (s ?? '').replace(/[<>&]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' }[c]!))
  return `<!doctype html><html><body style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;color:#111;line-height:1.5">
<p style="background:#fff4e5;border:1px solid #f0b37e;padding:10px 12px;border-radius:6px;margin:0 0 16px">
<strong>TEST MESSAGE.</strong> City sending is disabled. This was sent to the internal test address only.</p>
<p>${esc(COPY.intro)}</p>
<table style="border-collapse:collapse;margin:16px 0">
<tr><td style="padding:2px 12px 2px 0;color:#555">Client</td><td><strong>${esc(v.client_name)}</strong>${v.client_code ? ` (${esc(v.client_code)})` : ''}</td></tr>
<tr><td style="padding:2px 12px 2px 0;color:#555">Address</td><td>${esc(v.address)}</td></tr>
<tr><td style="padding:2px 12px 2px 0;color:#555">Service date</td><td>${esc(v.visit_date)}</td></tr>
<tr><td style="padding:2px 12px 2px 0;color:#555">Visit</td><td>#${v.visit_id}</td></tr>
</table>
<p style="margin:0 0 4px"><strong>${photos.length} photograph${photos.length === 1 ? '' : 's'} attached:</strong></p>
<ul style="margin:4px 0 16px">${rows}</ul>
<p style="color:#777;font-size:12px">Unclogme LLC</p>
</body></html>`
}

interface VisitRow {
  visit_id: number; client_name: string; client_code: string | null
  address: string; visit_date: string
}
interface Prepared {
  filename: string; content: string; content_type: string; phase: string; bytes: number
}

Deno.serve(async (req: Request) => {
  const cors = corsHeadersFor(req.headers.get('origin'))
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405, cors)
  if (!RESEND_API_KEY) return json({ error: 'email_not_configured', detail: 'RESEND_API_KEY not set' }, 503, cors)

  // -- AUTH. A real signed-in user, not merely a valid-looking JWT. -----------
  const bearer = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '')
  if (!bearer) return json({ error: 'unauthorized', detail: 'no bearer token' }, 401, cors)
  const authClient = createClient(SUPABASE_URL, ANON_KEY || SERVICE_KEY)
  const { data: userData, error: userErr } = await authClient.auth.getUser(bearer)
  const user = userData?.user
  if (userErr || !user?.id) {
    // This is the branch the anon key lands in: it is a valid JWT with no user.
    return json({ error: 'unauthorized', detail: 'a signed-in staff user is required' }, 401, cors)
  }
  const actorEmail = user.email ?? null
  const actorUserId = user.id

  let body: Record<string, unknown>
  try { body = await req.json() } catch { return json({ error: 'bad_json' }, 400, cors) }
  const visitId = Number(body?.visit_id)
  if (!Number.isFinite(visitId) || visitId <= 0) return json({ error: 'visit_id_required' }, 400, cors)
  const confirmResend = body?.confirm_resend === true

  const sb = createClient(SUPABASE_URL, SERVICE_KEY, {
    global: { headers: { 'x-app-source': 'send-visit-photos-email' } },
  })

  const logSend = async (
    status: string, reason: string | null, photoCount: number, bytes: number,
    resendId: string | null, subject: string | null,
  ) => {
    try {
      const { error } = await sb.from('visit_photo_email_sends').insert({
        visit_id: visitId, recipient_email: TEST_RECIPIENT, status, reason,
        is_test: IS_TEST, photo_count: photoCount, bytes_sent: bytes,
        resend_email_id: resendId, subject,
        sent_by_email: actorEmail, sent_by_user_id: actorUserId,
      })
      if (error) console.error(`[send-visit-photos-email] log insert failed: ${error.message}`)
    } catch (e) {
      console.error(`[send-visit-photos-email] log insert threw: ${String((e as Error)?.message ?? e)}`)
    }
  }

  try {
    // -- visit + client + address -------------------------------------------
    const { data: v, error: vErr } = await sb
      .from('visits')
      // ⚠ properties columns are address / city / state / zip. NOT address_line1 or
      // postal_code: those were a guess, and PostgREST reported them only at runtime
      // (the deploy succeeded regardless, so nothing caught it until the first call).
      .select('id, visit_date, deleted_at, client_id, property_id, clients(name, client_code), properties(address, city, state, zip)')
      .eq('id', visitId)
      .maybeSingle()
    if (vErr) throw new Error(`visit lookup failed: ${vErr.message}`)
    if (!v) { await logSend('skipped', 'visit_not_found', 0, 0, null, null); return json({ error: 'visit_not_found' }, 404, cors) }
    if (v.deleted_at) { await logSend('skipped', 'visit_deleted', 0, 0, null, null); return json({ error: 'visit_deleted' }, 409, cors) }

    const cl = (v as Record<string, any>).clients ?? {}
    const pr = (v as Record<string, any>).properties ?? {}
    const visitRow: VisitRow = {
      visit_id: visitId,
      client_name: cl?.name ?? 'Unknown client',
      client_code: cl?.client_code ?? null,
      address: [pr?.address, pr?.city, pr?.state, pr?.zip].filter(Boolean).join(', ') || 'Address not on file',
      visit_date: String(v.visit_date ?? '').slice(0, 10),
    }

    // -- the gate: EVERY image on this visit must be classified --------------
    const { data: links, error: lErr } = await sb
      .from('photo_links')
      .select('id, photos!inner(storage_path, file_name, content_type, size_bytes)')
      .eq('entity_type', 'visit').eq('entity_id', visitId).is('deleted_at', null)
    if (lErr) throw new Error(`photo lookup failed: ${lErr.message}`)

    const images = (links ?? []).filter((l: any) => String(l.photos?.content_type ?? '').startsWith('image/'))
    if (images.length === 0) { await logSend('skipped', 'no_photos', 0, 0, null, null); return json({ error: 'no_photos' }, 409, cors) }

    const { data: cls, error: cErr } = await sb
      .from('photo_classifications')
      .select('photo_link_id, service_phase')
      .in('photo_link_id', images.map((l: any) => l.id))
    if (cErr) throw new Error(`classification lookup failed: ${cErr.message}`)
    const phaseBy = new Map<number, string>((cls ?? []).map((c: any) => [c.photo_link_id, c.service_phase]))

    const unclassified = images.length - phaseBy.size
    if (unclassified > 0) {
      await logSend('skipped', `not_classified:${unclassified}`, 0, 0, null, null)
      return json({ error: 'not_classified', unclassified, total: images.length }, 409, cors)
    }

    // -- idempotency: send-derm-email has none, and it double-sent 9 times ----
    const { data: prior, error: pErr } = await sb
      .from('visit_photo_email_sends')
      .select('id, sent_at, sent_by_email, photo_count')
      .eq('visit_id', visitId).eq('status', 'sent')
      .order('sent_at', { ascending: false }).limit(1)
    if (pErr) throw new Error(`send-log lookup failed: ${pErr.message}`)
    if (prior && prior.length > 0 && !confirmResend) {
      return json({
        error: 'already_sent',
        detail: 'This visit was already emailed. Re-send with confirm_resend to override.',
        previous: prior[0],
      }, 409, cors)
    }

    // -- fetch, downscale, attach -------------------------------------------
    const ordered = [...images].sort((a: any, b: any) => {
      const rank = (id: number) => ({ before: 0, after: 1, internal: 2, extra: 3 }[phaseBy.get(id) ?? 'extra'] ?? 3)
      return rank(a.id) - rank(b.id)
    })

    const prepared: Prepared[] = []
    const skipped: { file: string; reason: string }[] = []
    let total = 0

    for (const l of ordered) {
      if (prepared.length >= MAX_PHOTOS) { skipped.push({ file: l.photos.file_name ?? String(l.id), reason: 'photo_cap' }); continue }
      if (total >= MAX_TOTAL_BYTES) { skipped.push({ file: l.photos.file_name ?? String(l.id), reason: 'size_cap' }); continue }
      const srcBytes = Number(l.photos.size_bytes ?? 0)
      if (srcBytes > MAX_SOURCE_BYTES) { skipped.push({ file: l.photos.file_name ?? String(l.id), reason: 'source_too_large' }); continue }

      try {
        const { data: blob, error: dErr } = await sb.storage.from(BUCKET).download(l.photos.storage_path)
        if (dErr || !blob) { skipped.push({ file: l.photos.file_name ?? String(l.id), reason: 'download_failed' }); continue }
        const raw = new Uint8Array(await blob.arrayBuffer())

        let out: Uint8Array
        try {
          const img = await decode(raw)
          if (!(img instanceof Image)) throw new Error('not a raster image')
          if (Math.max(img.width, img.height) > MAX_EDGE_PX) {
            if (img.width >= img.height) img.resize(MAX_EDGE_PX, Image.RESIZE_AUTO)
            else img.resize(Image.RESIZE_AUTO, MAX_EDGE_PX)
          }
          out = await img.encodeJPEG(JPEG_QUALITY)
        } catch {
          // Undecodable (HEIC, corrupt, animated). Attach the original only if it is
          // small enough to be worth it; never blow the budget on it.
          if (raw.byteLength > 4 * 1024 * 1024) { skipped.push({ file: l.photos.file_name ?? String(l.id), reason: 'undecodable_and_large' }); continue }
          out = raw
        }

        if (total + out.byteLength > MAX_TOTAL_BYTES) { skipped.push({ file: l.photos.file_name ?? String(l.id), reason: 'size_cap' }); continue }
        total += out.byteLength

        const phase = phaseBy.get(l.id) ?? 'extra'
        const n = prepared.filter((p) => p.phase === phase).length + 1
        prepared.push({
          filename: `${PHASE_LABEL[phase] ?? 'Photo'}-${n}.jpg`,
          content: encodeBase64(out),
          content_type: 'image/jpeg',
          phase, bytes: out.byteLength,
        })
      } catch (e) {
        skipped.push({ file: l.photos.file_name ?? String(l.id), reason: String((e as Error)?.message ?? e).slice(0, 80) })
      }
    }

    if (prepared.length === 0) {
      await logSend('error', 'no_attachable_photos', 0, 0, null, null)
      return json({ error: 'no_attachable_photos', skipped }, 502, cors)
    }

    const subject = `${COPY.subjectPrefix} — ${visitRow.client_name}${visitRow.client_code ? ` (${visitRow.client_code})` : ''} — ${visitRow.visit_date}`
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { Authorization: `Bearer ${RESEND_API_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        from: RESEND_FROM,
        to: [TEST_RECIPIENT],
        subject,
        html: buildHtml(visitRow, prepared),
        attachments: prepared.map((p) => ({ filename: p.filename, content: p.content, content_type: p.content_type })),
      }),
    })
    const er = await res.json().catch(() => ({}))
    if (!res.ok) {
      await logSend('error', 'resend_failed', prepared.length, total, null, subject)
      return json({ error: 'resend_failed', detail: er }, 502, cors)
    }

    const resendId = (er as { id?: string })?.id ?? null
    await logSend('sent', null, prepared.length, total, resendId, subject)
    return json({
      ok: true, is_test: IS_TEST, sent_to: TEST_RECIPIENT, visit_id: visitId,
      attached: prepared.length, bytes: total,
      by_phase: prepared.reduce((a, p) => { a[p.phase] = (a[p.phase] ?? 0) + 1; return a }, {} as Record<string, number>),
      skipped, resend_email_id: resendId, subject,
    }, 200, cors)
  } catch (e) {
    const msg = String((e as Error)?.message ?? e)
    await logSend('error', msg.slice(0, 200), 0, 0, null, null)
    return json({ error: 'unexpected', detail: msg }, 500, cors)
  }
})
