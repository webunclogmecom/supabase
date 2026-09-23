// ============================================================================
// inbound-file-drain — fetch queued inbound files into Storage, then card them
// ============================================================================
//
// Drains sync.inbound_file_queue: for each claimed row, fetch the source URL, put the bytes in a
// Supabase Storage bucket, and create the photos + photo_links rows that make it visible to every
// consumer. Today the only producer is fillout-inspection (pre/post shift inspections).
//
// 🛑 WHY THIS IS A SEPARATE FUNCTION AND NOT PART OF THE WEBHOOK. A shift inspection carries up to
// 17 attachments. Fetching them inside the webhook would hold Fillout's request open across 17
// sequential round trips, and Fillout retries a request it thinks timed out, which creates a second
// inspection. It would also be the third time this estate ran an edge function out of memory.
//
// SMALL BATCHES ON PURPOSE. Each row is a download plus an upload inside one invocation. BATCH
// stays in single digits for the same reason redact-manifest-sweep runs at limit 1.
//
// ⚠ THE CLAIM IS THE SAFETY PROPERTY. public.fn_claim_inbound_files moves a row to 'claimed' with a
// lease. Do not "optimise" this into a plain SELECT of pending rows: two overlapping runs would then
// fetch the same file twice and card it twice, and a customer gallery would show the image twice.

import { supabase } from '../_shared/supabase-client.ts'
import { ok, serverError } from '../_shared/responses.ts'

const BATCH = 3

// Beyond this a single file is not worth risking the whole invocation for. An inspection photo off
// a phone is ~1 to 5 MB; anything far larger is a video or a mistake, and it is SKIPPED with a
// reason rather than retried three times into an OOM.
const MAX_BYTES = 15 * 1024 * 1024

// 🛑 IMAGES ONLY, DECIDED BY THE RESPONSE CONTENT-TYPE, NOT THE URL. A URL ending .jpg proves
// nothing: this repo has already been bitten by a host returning an HTML error page at HTTP 200,
// which a naive reader stores as a "photo" that renders as a broken tile forever.
const ALLOWED = ['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif']

function extFor(contentType: string, url: string): string {
  const fromType: Record<string, string> = {
    'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp',
    'image/heic': 'heic', 'image/heif': 'heif',
  }
  if (fromType[contentType]) return fromType[contentType]
  const m = url.split('?')[0].match(/\.([a-z0-9]{2,5})$/i)
  return m ? m[1].toLowerCase() : 'jpg'
}

type Claimed = {
  id: number
  entity_type: string
  entity_id: number
  source_system: string
  role: string
  source_url: string
  target_bucket: string
  attempts: number
}

async function settle(id: number, status: string, photoId: number | null, error: string | null) {
  const { error: e } = await supabase.rpc('fn_settle_inbound_file', {
    p_id: id, p_status: status, p_photo_id: photoId, p_error: error,
  })
  if (e) console.error(`settle ${id} -> ${status} failed: ${e.message}`)
}

async function handleOne(row: Claimed): Promise<string> {
  // --- fetch ---------------------------------------------------------------
  let res: Response
  try {
    res = await fetch(row.source_url, { redirect: 'follow' })
  } catch (e) {
    // Network-level failure is transient by default: report pending so the attempt budget decides.
    await settle(row.id, 'pending', null, `fetch failed: ${e instanceof Error ? e.message : e}`)
    return 'retry'
  }

  if (!res.ok) {
    // 🛑 404/403/410 on a file host usually means the link EXPIRED, and retrying cannot bring it
    // back. Skip it so it stops consuming budget, and leave the reason: a run of these is the signal
    // that the queue is being drained too slowly, which is a scheduling problem, not a file problem.
    //
    // ⚠ MEASURED 2026-09-23: Supabase Storage answers a MISSING public object with **HTTP 400**,
    // not 404. So a missing object is deliberately NOT treated as terminal here: it burns its three
    // attempts and then sticks at 'error', where the health view shows it. That is the conservative
    // choice, because 400 is also what a genuinely malformed request returns, and making 400
    // terminal would make a fixable request unretryable. Do not "tidy" 400 into the terminal list
    // without checking which of the two you are looking at.
    const terminal = res.status === 404 || res.status === 403 || res.status === 410
    await settle(row.id, terminal ? 'skipped' : 'pending', null, `HTTP ${res.status}`)
    return terminal ? 'gone' : 'retry'
  }

  const ctype = (res.headers.get('content-type') ?? '').split(';')[0].trim().toLowerCase()
  if (!ALLOWED.includes(ctype)) {
    await settle(row.id, 'skipped', null, `not an image: content-type ${ctype || '(none)'}`)
    return 'not_image'
  }

  const buf = new Uint8Array(await res.arrayBuffer())
  if (buf.byteLength === 0) {
    await settle(row.id, 'skipped', null, 'empty body')
    return 'empty'
  }
  if (buf.byteLength > MAX_BYTES) {
    await settle(row.id, 'skipped', null, `too large: ${buf.byteLength} bytes`)
    return 'too_large'
  }

  // --- store ---------------------------------------------------------------
  // Path mirrors the existing Airtable convention (airtable/inspection/<id>/<role>_<ext id>.jpg) so
  // the bucket stays readable by eye. The queue id makes it unique without trusting the source name.
  const ext = extFor(ctype, row.source_url)
  const path = `${row.source_system}/${row.entity_type}/${row.entity_id}/${row.role}_${row.id}.${ext}`

  const { error: upErr } = await supabase.storage
    .from(row.target_bucket)
    .upload(path, buf, { contentType: ctype, upsert: true })
  if (upErr) {
    await settle(row.id, 'pending', null, `upload: ${upErr.message}`)
    return 'retry'
  }

  // --- card it -------------------------------------------------------------
  // 🛑 ORDER MATTERS. photos first, then photo_links, then settle done. If we settled first and then
  // failed, the queue would read drained with nothing in it - the exact "empty worklist, missing
  // data" shape fn_settle_inbound_file refuses by requiring the photo id.
  const { data: photo, error: pErr } = await supabase
    .from('photos')
    .insert({
      storage_path: path,
      file_name: path.split('/').pop(),
      content_type: ctype,
      size_bytes: buf.byteLength,
      source: `${row.source_system}_webhook`,
      uploaded_at: new Date().toISOString(),
    })
    .select('id')
    .single()
  if (pErr || !photo) {
    await settle(row.id, 'pending', null, `photos insert: ${pErr?.message ?? 'no row'}`)
    return 'retry'
  }

  const { error: lErr } = await supabase.from('photo_links').insert({
    photo_id: photo.id,
    entity_type: row.entity_type,
    entity_id: row.entity_id,
    role: row.role,
  })
  if (lErr) {
    // The photo exists but is attached to nothing, which is invisible to every consumer. Report it
    // and keep the photo id on the queue row so the orphan is findable rather than silently lost.
    await settle(row.id, 'pending', photo.id, `photo_links insert: ${lErr.message}`)
    return 'retry'
  }

  await settle(row.id, 'done', photo.id, null)
  return 'done'
}

Deno.serve(async () => {
  const startedAt = Date.now()
  try {
    const { data: rows, error } = await supabase.rpc('fn_claim_inbound_files', { p_limit: BATCH })
    if (error) return serverError(`claim failed: ${error.message}`)

    const claimed = (rows ?? []) as Claimed[]
    if (!claimed.length) {
      // An empty queue is the normal, healthy state. Say so explicitly: this repo has been bitten by
      // reading "a successful run" as "work happened".
      return ok({ ok: true, claimed: 0, note: 'queue empty' })
    }

    const outcomes: Record<string, number> = {}
    for (const row of claimed) {
      const r = await handleOne(row)
      outcomes[r] = (outcomes[r] ?? 0) + 1
    }

    return ok({ ok: true, claimed: claimed.length, outcomes, ms: Date.now() - startedAt })
  } catch (e) {
    return serverError(e instanceof Error ? e.message : String(e))
  }
})
