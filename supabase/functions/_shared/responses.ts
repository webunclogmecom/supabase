// ============================================================================
// _shared/responses.ts — HTTP response helpers for Edge Functions
// ============================================================================

const JSON_HEADERS = { 'Content-Type': 'application/json' }

export function ok(data: Record<string, unknown> = { ok: true }): Response {
  return new Response(JSON.stringify(data), { status: 200, headers: JSON_HEADERS })
}

export function accepted(data: Record<string, unknown> = { accepted: true }): Response {
  return new Response(JSON.stringify(data), { status: 202, headers: JSON_HEADERS })
}

export function badRequest(message: string): Response {
  return new Response(JSON.stringify({ error: message }), { status: 400, headers: JSON_HEADERS })
}

export function unauthorized(message = 'Invalid signature'): Response {
  return new Response(JSON.stringify({ error: message }), { status: 401, headers: JSON_HEADERS })
}

export function serverError(message: string): Response {
  return new Response(JSON.stringify({ error: message }), { status: 500, headers: JSON_HEADERS })
}

/**
 * Log a webhook event to webhook_events_log for audit/debug.
 */
export async function logWebhookEvent(
  supabase: ReturnType<typeof import('./supabase-client.ts')['supabase']>,
  source_system: string,
  event_type: string,
  payload: unknown,
  opts: {
    event_id?: string
    entity_type?: string
    entity_id?: number
    status?: string
    error_message?: string
    processing_ms?: number
  } = {}
): Promise<void> {
  try {
    // Truncate payload to 64KB to avoid bloat
    const payloadStr = JSON.stringify(payload)
    const truncated = payloadStr.length > 65536
      ? JSON.parse(payloadStr.slice(0, 65536))
      : payload

    await supabase.from('webhook_events_log').insert({
      source_system,
      event_type,
      event_id: opts.event_id ?? null,
      payload: truncated,
      entity_type: opts.entity_type ?? null,
      entity_id: opts.entity_id ?? null,
      status: opts.status ?? 'received',
      error_message: opts.error_message ?? null,
      processing_ms: opts.processing_ms ?? null,
      processed_at: opts.status === 'processed' ? new Date().toISOString() : null,
    })
  } catch (_e) {
    // Never let logging failures break webhook processing
    console.error('Failed to log webhook event:', _e)
  }
}
