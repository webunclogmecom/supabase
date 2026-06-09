// 74_verify_webhook_bw_guard.mjs
// Verify the deployed webhook-airtable BW/Broward guard actually blocks
// re-insertion of placeholder GDOs.
//
// Test 1: Mrs. Pasta (clientId 11, gdo 137 currently INACTIVE) — simulate
//         an AT webhook update with gdo_number='BW'. Expect: GDO 137 stays
//         INACTIVE, no new ACTIVE row created.
//
// Test 2: Same client but with a fake real-looking gdo_number='GDO-99999'
//         and primary property in Broward. Expect: county guard blocks
//         insert, no new row.

import 'dotenv/config';
const PAT = process.env.SUPABASE_PAT;
const PROD = process.env.SUPABASE_PROJECT_ID;
const SB_URL = process.env.SUPABASE_URL;
const TOKEN = process.env.AIRTABLE_WEBHOOK_TOKEN;
if (!TOKEN) throw new Error('AIRTABLE_WEBHOOK_TOKEN missing');
if (!SB_URL) throw new Error('SUPABASE_URL missing');

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROD}/database/query`, {
    method:'POST', headers:{Authorization:`Bearer ${PAT}`,'Content-Type':'application/json'},
    body:JSON.stringify({query:sql}),
  });
  const body = await r.text();
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${body.slice(0, 600)}`);
  return JSON.parse(body);
}

async function callWebhook(payload) {
  const r = await fetch(`${SB_URL}/functions/v1/webhook-airtable`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${TOKEN}`,
    },
    body: JSON.stringify(payload),
  });
  return { status: r.status, body: (await r.text()).slice(0, 300) };
}

// We need Mrs. Pasta's AT record id. Look it up.
console.log('=== A. Find Mrs. Pasta AT record id ===');
const links = await pg(`
  SELECT source_id FROM public.entity_source_links
  WHERE entity_type='client' AND entity_id=11 AND source_system='airtable'
  LIMIT 1;
`);
console.log(links);
const mrsPastaAtId = links[0]?.source_id;
if (!mrsPastaAtId) throw new Error('Mrs. Pasta AT record id not found');

console.log('\n=== B. State before tests ===');
console.log(await pg(`
  SELECT id, gdo_number, status FROM public.gdos
  WHERE client_id = 11 ORDER BY id;
`));

console.log('\n=== TEST 1: webhook with gdo_number="BW" — guard 1 should block ===');
const test1 = await callWebhook({
  entity: 'client',
  recordId: mrsPastaAtId,
  changeType: 'updated',
  fields: {
    'Client Code #3': '044-MP',
    'GDO Number': 'BW',
  },
});
console.log('Webhook response:', test1);

console.log('\n=== TEST 1 verification — Mrs. Pasta gdos rows ===');
console.log(await pg(`
  SELECT id, gdo_number, status, notes
  FROM public.gdos
  WHERE client_id = 11
  ORDER BY id;
`));

console.log('\n=== TEST 2: webhook with gdo_number="GDO-99999" — guard 2 (Broward county) should block ===');
const test2 = await callWebhook({
  entity: 'client',
  recordId: mrsPastaAtId,
  changeType: 'updated',
  fields: {
    'Client Code #3': '044-MP',
    'GDO Number': 'GDO-99999',
  },
});
console.log('Webhook response:', test2);

console.log('\n=== TEST 2 verification — Mrs. Pasta gdos rows should still only contain the INACTIVE row ===');
console.log(await pg(`
  SELECT id, gdo_number, status
  FROM public.gdos
  WHERE client_id = 11
  ORDER BY id;
`));

console.log('\n=== TEST 2 cleanup: if a GDO-99999 row leaked, deactivate it ===');
console.log(await pg(`
  DELETE FROM public.gdos
  WHERE client_id = 11 AND gdo_number = 'GDO-99999';
`));

console.log('\n=== Final state — should match initial state (only the INACTIVE BW row) ===');
console.log(await pg(`
  SELECT id, gdo_number, status FROM public.gdos
  WHERE client_id = 11 ORDER BY id;
`));
