// client-app-contacts-contract.mjs - step 15 of the Contacts Role + Communication build.
//
// Asserts that the PUBLISHED Client App bundle still carries the Contacts contract: the strings
// the section is built from, and - just as importantly - the strings it must NOT contain, because
// those are the sentences that would be FALSE.
//
//   node scripts/checks/client-app-contacts-contract.mjs
//   node scripts/checks/client-app-contacts-contract.mjs --mutate   point it at another app; every
//                                                                  needle must go ABSENT while the
//                                                                  controls still PASS
//
// 🛑 WHY THE ABSENT LIST IS THE HALF THAT MATTERS. Checking that copy is PRESENT only proves
// somebody wrote it. The absent list is the only thing testing whether the copy is TRUE:
//   * "receives the invoice" / "nobody receives the invoice" - measured on 112-YA, NOTHING we can
//     write through the Jobber API changes who Jobber sends the next invoice to. Not the star, not
//     isBillingContact. `Client.defaultEmails` is rewritten only by a real send. Our tick is a
//     RECORD of who should get it, so any copy saying a contact "receives" it is a promise Jobber
//     cannot keep.
//   * "only one person can" - the one-per-client rule is OURS, not Jobber's. Wording it as Jobber's
//     sends ops staff into Jobber to fix something that is ours to move.
//   * "In step with Jobber" - we cannot know that; the API has no readable record of who a message
//     went to.
//   * "It does not change who receives what" - promote DOES move a real recipient (it copies the
//     email onto the client record, webhook-jobber derives the mirror row from it, and
//     fn_derm_recipient reads that row).
//
// 🛑 SEEDS FROM REAL ROUTES. The contacts code lives in a lazily-loaded `clients._id-*` chunk that
// the root document never references, so a walk seeded from '/' alone reaches a fraction of the app
// and returns a confident zero.
//
// 🛑 DELIMITER CAPTURE. The literal counter captures the opening quote and BACK-REFERENCES it.
// A ["'`] class on BOTH ends matches "name` as a pair, and a ["']-only matcher already scored a
// whole backtick-quoted app at zero in this estate.
const BASE = process.argv.includes('--mutate')
  ? 'https://admin.unclogme.app'          // a different staff app: everything must go absent
  : 'https://clients.unclogme.app';
const SEEDS = ['/', '/clients/381'];

const PRESENT = [
  // the model
  'communication', 'person_role', 'save_contact_settings',
  // the four communications
  'Service report', 'Quote approval', 'City report', 'Invoice',
  // the role vocabulary
  'Store Manager', 'Pick a role (optional)',
  // who sends what - the distinction the whole section rests on
  'Sent by UnclogMe.', 'Sent from Jobber. This is our record of who should get it.',
  // the states a person must be able to see
  'Receives nothing',
  // the scope disclaimer, without which the section claims to cover Jobber's other mail
  'Not set here: booking confirmations',
  // already shipped and must not regress
  'contact_role', 'is_primary', 'jobber_contacts', 'edit_jobber_contact', 'promote', 'stale_view',
  'In Jobber', 'Not in Jobber',
  // the drift banner INSTRUCTS rather than explains (2026-09-23). The star is deliberately never
  // written to Jobber, so this sentence is the only thing that actually fixes a wrong prefill:
  // a person types the address over it once and Jobber remembers. See
  // Building Apps/Client App/docs/2026-09-22_jobber-star-decision.md.
  'To fix it for good:', 'over the prefilled address before sending',
  'Jobber remembers it from then on.',
  // 🛑 the branch the instruction edit was told NOT to touch. It is here as a REGRESSION guard:
  // the copy change altered the holder branch of that same ternary, and this is what proves the
  // no-holder branch was not collateral damage.
  'Tick Invoice and Quote approval on the right contact so we both agree.',
];

const ABSENT = [
  'receives the invoice',
  'only one person can',
  'nobody receives the invoice',
  'In step with Jobber',
  'It does not change who receives what',
  // the contact role retired on 2026-09-22; the server refuses it
  'value:"city"', "value:'city'",
  // superseded by the instruction above. It explained and then stopped, which left the operator
  // knowing the prefill was wrong and not knowing what to do about it.
  'It will only change once someone in Jobber types a different address over the prefill on a send.',
  // 🛑 stated a mechanism nobody here has observed. Jobber's memory is written by a send, but
  // "the FIRST send decides it" is a finality we have never measured, and 0 of 461 clients are
  // even in the empty-history state it describes.
  'The first send from Jobber decides it.',
];

const walk = async () => {
  const chunks = new Set();
  for (const s of SEEDS) {
    const r = await fetch(BASE + s, { redirect: 'follow' });
    const h = await r.text();
    for (const m of h.matchAll(/\/assets\/[A-Za-z0-9._-]+\.js/g)) chunks.add(m[0]);
  }
  const bodies = new Map();
  let added = true;
  while (added) {
    added = false;
    for (const c of [...chunks]) {
      if (bodies.has(c)) continue;
      const r = await fetch(BASE + c);
      bodies.set(c, r.ok ? await r.text() : '');
      for (const m of bodies.get(c).matchAll(/["'`](?:\.\.)?(\/?assets\/[A-Za-z0-9._-]+\.js)["'`]/g)) {
        const p = m[1].startsWith('/') ? m[1] : '/' + m[1];
        if (!chunks.has(p)) { chunks.add(p); added = true; }
      }
    }
  }
  return bodies;
};

const bodies = await walk();
let all = '';
for (const [, b] of bodies) all += b;

// capture-and-backreference, so a backtick-quoted bundle is not silently scored at zero
const litRe = new RegExp('(["\'`])(?:\\\\.|(?!\\1)[^\\\\])*?\\1', 'g');
const literals = (all.match(litRe) || []).length;

const mutating = BASE.includes('admin.');
const missing = PRESENT.filter((n) => !all.includes(n));
const leaked = ABSENT.filter((n) => all.includes(n));

console.log(`${BASE}  chunks=${bodies.size}  bytes=${all.length}  string_literals=${literals}`);

const fails = [];
// 🛑 THE CONTROLS. Without them an all-absent result is indistinguishable from a broken crawl.
// The literal count is the control that travels: it proves the reader parsed real code whatever
// app it was pointed at. The CHUNK count is only a valid control for THIS app, which is
// code-split across six chunks - Admin Review is a single-chunk SPA, so demanding two there would
// fail the mutation run for a reason that has nothing to do with the contract. Measured:
// clients 6 chunks / 6,351 literals, admin 1 chunk / 1,151 literals.
if (literals < 900) fails.push(`only ${literals} string literals - the reader is broken, conclude nothing`);
if (!mutating && bodies.size < 2) {
  fails.push(`only ${bodies.size} chunk(s) fetched from ${BASE} - the contacts route lives in a lazy chunk, so the crawl is broken; conclude nothing`);
}

if (mutating) {
  // Every contract needle must vanish on a DIFFERENT app, while the controls above still pass.
  const stillHere = PRESENT.filter((n) => all.includes(n) && !['Invoice', 'promote', 'communication'].includes(n));
  if (stillHere.length) fails.push(`MUTATION: needles still present on another app: ${stillHere.join(', ')}`);
  console.log(`MUTATION MODE: ${PRESENT.length - stillHere.length}/${PRESENT.length} needles correctly absent`);
} else {
  for (const n of missing) fails.push(`MISSING: ${JSON.stringify(n)}`);
  for (const n of leaked) fails.push(`PRESENT BUT MUST NOT BE (the copy would be false): ${JSON.stringify(n)}`);
}

if (fails.length) { fails.forEach((f) => console.log('  FAIL  ' + f)); process.exit(1); }
console.log(`PASS  ${PRESENT.length} present, ${ABSENT.length} absent, controls ok`);
