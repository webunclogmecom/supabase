// node --experimental-strip-types scripts/checks/svix_verify_check.mjs
// Checks supabase/functions/webhook-resend/svix.ts against Svix's published test vector, plus the refusals.
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

// Node reads a .ts file in this repo as CommonJS (no "type": "module"), so load a .mts copy of the exact source.
const src = join(dirname(fileURLToPath(import.meta.url)), '../../supabase/functions/webhook-resend/svix.ts')
const copy = join(mkdtempSync(join(tmpdir(), 'svix-')), 'svix.mts')
writeFileSync(copy, readFileSync(src, 'utf8'))
const { verifySvix } = await import(pathToFileURL(copy).href)

const secret = 'whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw'
const id = 'msg_p5jXN8AQM9LWM0D4loKWxJek'
const ts = '1614265330'
const body = '{"test": 2432232314}'
const sig = 'v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE='
const now = Number(ts) + 10

assert.deepEqual(await verifySvix(secret, id, ts, sig, body, now), { ok: true }, 'published vector must verify')
assert.deepEqual(await verifySvix(secret, id, ts, `v1,bad v2,x ${sig}`, body, now), { ok: true }, 'any matching v1 entry is enough')
assert.equal((await verifySvix(secret, id, ts, sig, body + ' ', now)).reason, 'bad_signature', 'changed body must fail')
assert.equal((await verifySvix(secret, id + 'x', ts, sig, body, now)).reason, 'bad_signature', 'changed id must fail')
assert.equal((await verifySvix(secret, id, ts, sig, body, Number(ts) + 301)).reason, 'stale_timestamp', 'old timestamp must fail')
assert.equal((await verifySvix(secret, id, ts, null, body, now)).reason, 'missing_headers')
assert.equal((await verifySvix('', id, ts, sig, body, now)).reason, 'no_secret')
assert.equal((await verifySvix('whsec_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA', id, ts, sig, body, now)).reason, 'bad_signature', 'wrong secret must fail')
console.log('svix_verify_check: 8 of 8 pass')
