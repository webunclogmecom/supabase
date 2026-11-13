// PROBE: what Jobber does with a bare contactsToAdd on 112-YA, then deletes what it added.
// Answers decision 2 of Building Apps/Client App/docs/specs/2026-11-13-add-contact-in-jobber-plan.md (Jobber's default
// automatic messages for a new contact) and proves add + delete work.
// Run: cd Slack && JT=$(./jobber-token.sh) && cd ../Supabase && JT=$JT node scripts/probes/add_jobber_contact_probe.mjs
const JT = (process.env.JT || '').trim();
if (!JT) { console.log('FATAL: set JT=$(./jobber-token.sh)'); process.exit(1); }
const CLIENT_GID = 'Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ='; // 112-YA, the test client
const jobber = async (query, variables) => {
  const r = await fetch('https://api.getjobber.com/api/graphql', { method: 'POST',
    headers: { Authorization: `Bearer ${JT}`, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Type': 'application/json' },
    body: JSON.stringify({ query, variables }) });
  const ct = r.headers.get('content-type') || '';
  if (!ct.includes('json')) throw new Error(`Jobber returned ${ct} at HTTP ${r.status}`);
  const j = await r.json();
  if (!('data' in j)) throw new Error(JSON.stringify(j).slice(0, 300));
  return j;
};
const FIELDS = `id firstName lastName role isBillingContact receivesReminders receivesFollowUps receivesQuoteFollowUps
  receivesInvoiceFollowUps canAccessClientHub emails(first:3){nodes{address primary}} phones(first:3){nodes{number primary smsAllowed}}
  properties(first:5){nodes{id}}`;
// Client.properties is a plain LIST (no first/nodes); a contact's properties is a connection.
const READ = `query($id: EncodedId!){ client(id:$id){ properties { id } contacts(first:25){ totalCount nodes{ ${FIELDS} } } } }`;
const EDIT = `mutation($id: EncodedId!, $input: ClientEditInput!){ clientEdit(clientId:$id, input:$input){ userErrors{ message path } } }`;

const before = (await jobber(READ, { id: CLIENT_GID })).data.client;
const ids0 = new Set(before.contacts.nodes.map((n) => n.id));
const prop = before.properties[0].id;
const tag = `Probe${Date.now()}`;
try {
  const add = await jobber(EDIT, { id: CLIENT_GID, input: { contactsToAdd: [{ firstName: 'Test', lastName: tag, role: 'Accounting',
    emails: [{ address: 'fred@ayache.com', description: 'MAIN', primary: true }], propertyIds: [prop] }] } });
  console.log('userErrors', JSON.stringify(add.data.clientEdit.userErrors));
  const born = (await jobber(READ, { id: CLIENT_GID })).data.client.contacts.nodes.filter((n) => !ids0.has(n.id));
  console.log('new contacts:', born.length);
  console.log(JSON.stringify(born, null, 1));
} finally {
  const mine = (await jobber(READ, { id: CLIENT_GID })).data.client.contacts.nodes.filter((n) => n.lastName === tag);
  for (const n of mine) {
    const d = await jobber(EDIT, { id: CLIENT_GID, input: { contactsToDelete: [n.id] } });
    console.log('deleted', n.id, JSON.stringify(d.data.clientEdit.userErrors));
  }
  const left = (await jobber(READ, { id: CLIENT_GID })).data.client.contacts.nodes.filter((n) => n.lastName === tag).length;
  console.log('left behind:', left, '(must be 0)');
}
