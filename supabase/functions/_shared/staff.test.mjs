// The check for staff.ts. Run: node supabase/functions/_shared/staff.test.mjs (Node 22.13+).
// Same loader as hr-sign-in/invite-email.test.mjs: strip the types, import from a data: URL; Deno.env and fetch are faked.
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { stripTypeScriptTypes } from 'node:module'

const calls = []
let reply = { ok: true, status: 200, body: true }
globalThis.Deno = { env: { get: (k) => ({ SUPABASE_URL: 'https://x.supabase.co', SUPABASE_ANON_KEY: 'anon' })[k] } }
globalThis.fetch = async (url, init) => {
  calls.push({ url, init })
  if (reply.throws) throw new Error('network down')
  return { ok: reply.ok, status: reply.status, json: async () => reply.body }
}
const src = stripTypeScriptTypes(readFileSync(new URL('./staff.ts', import.meta.url), 'utf8'))
const { isStaffEmail, isCompanyEmail } = await import('data:text/javascript;base64,' + Buffer.from(src).toString('base64'))

// company domains: answered here, no call
assert.equal(await isStaffEmail('tok', 'Fred@Ayache.com'), true)
assert.equal(await isStaffEmail('tok', ' diego@unclogme.com '), true)
assert.equal(calls.length, 0)
assert.equal(isCompanyEmail('x@evil-ayache.com'), false)

// empty: no call, false
assert.equal(await isStaffEmail('tok', ''), false)
assert.equal(await isStaffEmail('tok', null), false)
assert.equal(calls.length, 0)

// a personal address: asks the database AS THE CALLER, lower-cased
reply = { ok: true, status: 200, body: true }
assert.equal(await isStaffEmail('user-token', 'MichaelEscobar1606@Gmail.com'), true)
assert.equal(calls.length, 1)
assert.equal(calls[0].url, 'https://x.supabase.co/rest/v1/rpc/fn_is_staff_email')
assert.equal(calls[0].init.headers.Authorization, 'Bearer user-token')
assert.deepEqual(JSON.parse(calls[0].init.body), { p_email: 'michaelescobar1606@gmail.com' })

// fails closed: false answer, null answer, HTTP error (the read gate's 403), network error
for (const r of [{ ok: true, status: 200, body: false }, { ok: true, status: 200, body: null },
                 { ok: false, status: 403, body: { code: '42501' } }, { throws: true }]) {
  reply = r
  assert.equal(await isStaffEmail('t', 'someone@gmail.com'), false, JSON.stringify(r))
}
console.log('staff.ts: all checks passed')
