// archive_copy.mjs - runs the REAL supabase/functions/_shared/archive-copy.ts (types stripped by Node 22) against a
// stubbed Resend and asserts the D5 rules (2026-10-20, migration 2026-10-20_1900):
//   one archive email to the hidden copies, same subject / attachments, a visible first line naming the city's To and
//   Cc in ET, the Idempotency-Key "archive:<city id>" and the X-Unclogme-Archive-Of header; one retry on 429 / 5xx /
//   network error with the SAME key; no retry on a clear refusal; nothing sent when there is nobody to copy; and it
//   NEVER throws. Also that both senders use it and put no Bcc on the city email.
//   node scripts/checks/archive_copy.mjs
import fs from 'node:fs';
import assert from 'node:assert';
import { stripTypeScriptTypes } from 'node:module';

const root = new URL('../../supabase/functions/', import.meta.url);
const src = fs.readFileSync(new URL('_shared/archive-copy.ts', root), 'utf8');
const mod = await import('data:text/javascript;base64,' + Buffer.from(stripTypeScriptTypes(src)).toString('base64'));
const { sendArchiveCopy, hiddenCopies, archiveLine, ARCHIVE_INBOX } = mod;

function stub(replies) {
  const calls = [];
  const f = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    const r = replies[Math.min(calls.length - 1, replies.length - 1)];
    if (r === 'THROW') throw new Error('network down');
    return new Response(JSON.stringify(r.body ?? {}), { status: r.status });
  };
  return { f, calls };
}
const base = {
  apiKey: 'k', cityEmailId: 'city-123', from: 'Unclogme <x@unclogme.com>', to: ['derm@ayache.com', 'ops@unclogme.com'],
  cityTo: ['a@city.gov', 'b@city.gov'], cityCc: [], sentAt: new Date('2026-10-20T13:34:00Z'), subject: 'DERM Manifest for X',
  html: '<!doctype html><html><body style="m"><p>Letter</p></body></html>', text: 'Letter',
  attachments: [{ filename: 'r.pdf', content: 'QUJD', content_type: 'application/pdf' }],
};
let n = 0; const ok = (m) => { n++; console.log('  ok  ' + m); };

// 1. success first time
{
  const { f, calls } = stub([{ status: 200, body: { id: 'arch-1' } }]);
  const r = await sendArchiveCopy({ ...base, fetchImpl: f });
  assert.deepEqual(r, { id: 'arch-1', error: null });
  assert.equal(calls.length, 1);
  const c = calls[0];
  assert.equal(c.url, 'https://api.resend.com/emails');
  assert.equal(c.init.headers['Idempotency-Key'], 'archive:city-123');
  assert.deepEqual(c.body.to, base.to);
  assert.equal(c.body.bcc, undefined, 'the archive email carries no Bcc either');
  assert.equal(c.body.subject, base.subject);
  assert.deepEqual(c.body.attachments, base.attachments);
  assert.equal(c.body.headers['X-Unclogme-Archive-Of'], 'city-123');
  assert.match(c.body.html, /^<!doctype html><html><body style="m"><div [^>]*>Archive copy of the email sent to the city \(a@city\.gov, b@city\.gov\) on Tue, Oct 20, 9:34 AM ET\.<\/div><p>Letter/);
  assert.equal(c.body.text, 'Archive copy of the email sent to the city (a@city.gov, b@city.gov) on Tue, Oct 20, 9:34 AM ET.\n\nLetter');
  assert.ok(!/—/.test(c.body.text + c.body.html), 'no em dash');
  ok('sends one archive email, same subject and attachments, line after <body>, key and header set');
}
// 2. a 500 then success: one retry, same key
{
  const { f, calls } = stub([{ status: 500, body: { message: 'boom' } }, { status: 200, body: { id: 'arch-2' } }]);
  const r = await sendArchiveCopy({ ...base, fetchImpl: f });
  assert.deepEqual(r, { id: 'arch-2', error: null });
  assert.equal(calls.length, 2);
  assert.equal(calls[1].init.headers['Idempotency-Key'], 'archive:city-123');
  ok('retries once on 500 with the same idempotency key');
}
// 3. 429 twice: error after 2 attempts
{
  const { f, calls } = stub([{ status: 429, body: { message: 'slow down' } }]);
  const r = await sendArchiveCopy({ ...base, fetchImpl: f });
  assert.equal(r.id, null); assert.match(r.error, /resend 429: slow down/); assert.equal(calls.length, 2);
  ok('gives up after two 429s and says why');
}
// 4. a clear refusal: no retry
{
  const { f, calls } = stub([{ status: 422, body: { message: 'invalid to' } }]);
  const r = await sendArchiveCopy({ ...base, fetchImpl: f });
  assert.equal(r.id, null); assert.match(r.error, /resend 422: invalid to/); assert.equal(calls.length, 1);
  ok('does not retry a 422');
}
// 5. network errors: two attempts, never throws
{
  const { f, calls } = stub(['THROW']);
  const r = await sendArchiveCopy({ ...base, fetchImpl: f });
  assert.equal(r.id, null); assert.match(r.error, /network down/); assert.equal(calls.length, 2);
  ok('network error twice: error returned, nothing thrown');
}
// 6. 200 without an id is not a success
{
  const { f } = stub([{ status: 200, body: {} }]);
  const r = await sendArchiveCopy({ ...base, fetchImpl: f });
  assert.equal(r.id, null); assert.match(r.error, /no id/);
  ok('a 200 with no id is reported, not trusted');
}
// 7. nobody to copy: nothing sent
{
  const { f, calls } = stub([{ status: 200, body: { id: 'x' } }]);
  const r = await sendArchiveCopy({ ...base, to: [], fetchImpl: f });
  assert.deepEqual(r, { id: null, error: null }); assert.equal(calls.length, 0);
  ok('no hidden copies: no email, no error');
}
// 8. a fetch that throws synchronously, and garbage input: still never throws
{
  const r = await sendArchiveCopy({ ...base, fetchImpl: () => { throw new Error('sync'); } });
  assert.equal(r.id, null); assert.match(r.error, /sync/);
  const r2 = await sendArchiveCopy({ ...base, cityTo: null, fetchImpl: stub([{ status: 200, body: { id: 'y' } }]).f });
  assert.equal(r2.id, null); assert.ok(r2.error);
  ok('never throws, even on a synchronous throw or bad input');
}
// 9. the line names the Cc; html without <body> gets the line first
{
  assert.equal(archiveLine(['a@x.gov'], ['m@client.com'], base.sentAt),
    'Archive copy of the email sent to the city (a@x.gov) on Tue, Oct 20, 9:34 AM ET. Cc: m@client.com.');
  const { f, calls } = stub([{ status: 200, body: { id: 'z' } }]);
  await sendArchiveCopy({ ...base, html: '<p>x</p>', text: undefined, fetchImpl: f });
  assert.match(calls[0].body.html, /^<div [^>]*>Archive copy/); assert.equal(calls[0].body.text, undefined);
  ok('Cc named; a fragment gets the line first; no text part when the city email had none');
}
// 10. hiddenCopies: archive first, deduped, lower-cased, junk dropped; no archive on a test send
{
  assert.deepEqual(hiddenCopies(['Ops@Unclogme.com', 'derm@ayache.com', ' ', 'x'], true), [ARCHIVE_INBOX, 'ops@unclogme.com']);
  assert.deepEqual(hiddenCopies(['fred@ayache.com'], false), ['fred@ayache.com']);
  assert.deepEqual(hiddenCopies([], false), []);
  ok('hiddenCopies');
}
// 11. both senders: the city email carries no Bcc, the archive helper is called, hidden_copies_separate is written
for (const fn of ['send-visit-photos-email', 'send-derm-email']) {
  const s = fs.readFileSync(new URL(`${fn}/index.ts`, root), 'utf8');
  assert.ok(s.includes("from '../_shared/archive-copy.ts'"), `${fn} imports the helper`);
  assert.ok(/sendArchiveCopy\(\{/.test(s), `${fn} calls sendArchiveCopy`);
  assert.ok(s.includes('hidden_copies_separate: true'), `${fn} marks the row`);
  assert.ok(!/payload\.bcc\s*=|\bbcc:\s*bccAll|\bbcc:\s*cityBcc/.test(s), `${fn} still puts a Bcc on the city email`);
  assert.ok(s.includes('archive_resend_email_id: archive.id'), `${fn} saves the archive id on the row`);
  ok(`${fn}: no Bcc on the city email, archive sent and recorded`);
}
console.log(`archive_copy: ${n} checks passed`);
