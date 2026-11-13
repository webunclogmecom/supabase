// save-client-contact: a landline Jobber refuses is sent once more with texting off (Trello #189, Fred's pick T1, 2026-11-12).
// Checks the helper that builds that second call, read from the function's own source: texting off goes on every phone the
// edit writes (the client's own phones and a contact person's), nothing else changes, an edit with no phone gives no retry,
// and the original input is left alone. The live proof (112-YA, a real landline, Jobber's edit form) is in the Client App
// changelog, 2026-11-12.
//   node scripts/checks/save_client_contact_texting_off.mjs        exit 0 = pass
import fs from 'node:fs'
import assert from 'node:assert'
const src = fs.readFileSync(new URL('../../supabase/functions/save-client-contact/index.ts', import.meta.url), 'utf8')
const a = src.indexOf('function withTextingOff'), b = src.indexOf('// One clientEdit;')
if (a < 0 || b < a) { console.log('FAIL withTextingOff not found in save-client-contact: update this check'); process.exit(1) }
const js = src.slice(a, b).replace(': Record<string, any> | null', '').replace('(input: Record<string, any>)', '(input)').replace('(list: unknown)', '(list)').replaceAll('(o: Record<string, any>)', '(o)')
const withTextingOff = new Function(js + '; return withTextingOff')()
if (!/LANDLINE_REFUSAL\.test\(uerr\)/.test(src) || (src.match(/editWithLandlineRetry\(token,/g) || []).length < 2) { console.log('FAIL both Jobber phone writes must go through editWithLandlineRetry'); process.exit(1) }
let n = 0; const t = (name, fn) => { fn(); n++; console.log('PASS', name) }
t('the client\'s own phone gets texting off, the email is untouched', () => { const c = withTextingOff({ phonesToEdit: [{ id: 'P', number: '305-800-5775', primary: true }], emailsToEdit: [{ id: 'E', address: 'a@b.co' }] }); assert.deepStrictEqual(c.phonesToEdit, [{ id: 'P', number: '305-800-5775', primary: true, smsAllowed: false }]); assert.deepStrictEqual(c.emailsToEdit, [{ id: 'E', address: 'a@b.co' }]) })
t('a contact person\'s added phone gets texting off, its name is untouched', () => { const c = withTextingOff({ contactsToEdit: [{ id: 'C', firstName: 'X', phonesToAdd: [{ number: '1', description: 'MAIN', primary: true }] }] }); assert.strictEqual(c.contactsToEdit[0].phonesToAdd[0].smsAllowed, false); assert.strictEqual(c.contactsToEdit[0].firstName, 'X') })
t('an edit with no phone gives no retry', () => { assert.strictEqual(withTextingOff({ emailsToEdit: [{ id: 'E', address: 'x@y.co' }] }), null); assert.strictEqual(withTextingOff({ contactsToEdit: [{ id: 'C', role: 'Boss' }] }), null) })
t('the first call\'s input is not changed', () => { const o = { phonesToEdit: [{ id: 'P', number: '1' }] }; withTextingOff(o); assert.strictEqual(o.phonesToEdit[0].smsAllowed, undefined) })
// a NEW contact (Add contact in Jobber, 2026-11-13) carries its phones as `phones`, not phonesToAdd
t('a new contact\'s phone gets texting off, its email is untouched', () => { const c = withTextingOff({ contactsToAdd: [{ firstName: 'X', emails: [{ address: 'a@b.co' }], phones: [{ number: '1', description: 'MAIN', primary: true }] }] }); assert.strictEqual(c.contactsToAdd[0].phones[0].smsAllowed, false); assert.deepStrictEqual(c.contactsToAdd[0].emails, [{ address: 'a@b.co' }]) })
t('a new contact with no phone gives no retry', () => { assert.strictEqual(withTextingOff({ contactsToAdd: [{ firstName: 'X', emails: [{ address: 'a@b.co' }] }] }), null) })
console.log(`${n} of 6 pass`)
