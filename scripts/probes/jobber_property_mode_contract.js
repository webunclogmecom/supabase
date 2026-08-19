// Answers the one design assumption the SC-job spec could not settle by reading:
// what property rows does Jobber mint for each of our three property_mode shapes?
//
// 🛑 THE NAMES START WITH "TEST" ON PURPOSE. webhook-jobber's junk-name filter refuses any client
//    matching /^\s*test\b/i (index.ts:290), returning entity_id -1. So these probe clients can never
//    reach public.clients even though the */5 poll will pull them. Renaming them without that prefix
//    pollutes the real client book.
// ⚠ Creates up to 3 real Jobber clients and ARCHIVES them again. clientArchive exists; clientDelete
//    does not. Run once, then confirm all three read archived in the Jobber UI.
const { execSync } = require('child_process');
const fs = require('fs');
// ⚠ WINDOWS: Node's execSync spawns cmd.exe, which cannot run a .sh file ("'.' is not recognized").
// Prefer a token passed in the environment; otherwise invoke the script through bash explicitly.
const token = (process.env.JOBBER_TOKEN || '').trim() ||
  execSync('bash ./jobber-token.sh', { cwd: 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Slack' }).toString().trim();
if (!token) { console.error('No Jobber token. Set JOBBER_TOKEN or fix Slack/jobber-token.sh.'); process.exit(1); }

async function gql(query, variables) {
  const r = await fetch('https://api.getjobber.com/api/graphql', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' },
    body: JSON.stringify({ query, variables }),
  });
  const ctype = r.headers.get('content-type') ?? '';
  if (!ctype.includes('json')) throw new Error(`Jobber waiting room: ${ctype} at HTTP ${r.status}`);
  return r.json();
}

const CLIENT_ADDR = { street1: '1 Client Street', city: 'Miami', province: 'FL', postalCode: '33139', country: 'USA' };
const PROP_ADDR   = { street1: '2 Property Way', city: 'Miami Beach', province: 'FL', postalCode: '33141', country: 'USA' };

const CASES = [
  { mode: 'client_address', input: { isCompany: true, companyName: 'TEST Probe client_address',
      properties: [{ address: CLIENT_ADDR }] } },
  { mode: 'separate',       input: { isCompany: true, companyName: 'TEST Probe separate',
      properties: [{ address: PROP_ADDR }], billingAddress: CLIENT_ADDR } },
  { mode: 'none',           input: { isCompany: true, companyName: 'TEST Probe none',
      billingAddress: CLIENT_ADDR } },
];

(async () => {
  const out = [];
  for (const c of CASES) {
    let res;
    try {
      res = await gql(`mutation($input: ClientCreateInput!){ clientCreate(input:$input){ client { id } userErrors { message } } }`, { input: c.input });
    } catch (e) { out.push({ mode: c.mode, error: String(e.message) }); continue; }

    const errs = res.data?.clientCreate?.userErrors ?? [];
    const id = res.data?.clientCreate?.client?.id ?? null;
    if (!id) {
      out.push({ mode: c.mode, accepted: false, userErrors: errs.map(e => e.message),
                 graphqlErrors: (res.errors ?? []).map(e => e.message) });
      continue;
    }

    const read = await gql(`query($id: EncodedId!){ client(id:$id){ id name
        billingAddress { street1 city }
        properties(first:10){ nodes { id address { street1 city } } } } }`, { id });
    const cl = read.data?.client;
    out.push({
      mode: c.mode, accepted: true, client_gid: id,
      billing_street: cl?.billingAddress?.street1 ?? null,
      property_count: cl?.properties?.nodes?.length ?? 0,
      properties: (cl?.properties?.nodes ?? []).map(n => ({ gid: n.id, street: n.address?.street1 })),
    });

    const arch = await gql(`mutation($id: EncodedId!){ clientArchive(clientId:$id){ client { id isArchived } userErrors { message } } }`, { id });
    const last = out[out.length - 1];
    last.archived = arch.data?.clientArchive?.client?.isArchived ?? false;
    last.archive_errors = (arch.data?.clientArchive?.userErrors ?? []).map(e => e.message)
      .concat((arch.errors ?? []).map(e => e.message));
  }
  fs.writeFileSync(__dirname + '/jobber_property_mode_contract.out.json', JSON.stringify(out, null, 1));
  console.log(JSON.stringify(out, null, 1));
})();
