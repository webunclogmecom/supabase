// Svix signature check for Resend webhooks (2026-10-14). Pure Web Crypto, no imports, so
// scripts/checks/svix_verify_check.mjs can run it under Node against Svix's published test vector.
//
// Signed content = `${svix-id}.${svix-timestamp}.${raw body}`, HMAC-SHA256 with the base64 key after "whsec_".
// The svix-signature header holds space-separated "v1,<base64>" entries; any one matching is enough.
// A timestamp more than toleranceSec away from now is refused (replay protection).

export type SvixResult = { ok: true } | { ok: false; reason: string }

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64)
  const out = new Uint8Array(bin.length)
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i)
  return out
}

function bytesToB64(bytes: Uint8Array): string {
  let s = ''
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s)
}

// Constant time over equal lengths; unequal lengths are simply unequal.
function same(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let d = 0
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return d === 0
}

export async function verifySvix(
  secret: string, id: string | null, timestamp: string | null, signature: string | null,
  rawBody: string, nowSec: number, toleranceSec = 300,
): Promise<SvixResult> {
  if (!secret) return { ok: false, reason: 'no_secret' }
  if (!id || !timestamp || !signature) return { ok: false, reason: 'missing_headers' }
  const ts = Number(timestamp)
  if (!Number.isFinite(ts)) return { ok: false, reason: 'bad_timestamp' }
  if (Math.abs(nowSec - ts) > toleranceSec) return { ok: false, reason: 'stale_timestamp' }
  let keyBytes: Uint8Array
  try {
    keyBytes = b64ToBytes(secret.startsWith('whsec_') ? secret.slice(6) : secret)
  } catch {
    return { ok: false, reason: 'bad_secret' }
  }
  const key = await crypto.subtle.importKey('raw', keyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(`${id}.${timestamp}.${rawBody}`)))
  const expected = bytesToB64(mac)
  for (const part of signature.split(' ')) {
    const [version, sig] = part.split(',', 2)
    if (version === 'v1' && sig && same(sig, expected)) return { ok: true }
  }
  return { ok: false, reason: 'bad_signature' }
}
