// Pick 50 GDOs for Phase 2b batch.
//   15 ACTIVE with permit_expiration IS NULL (priority — known gap)
//   32 ACTIVE with max_frequency_days IS NULL (random sample, excluding Phase 2a)
//   3 ACTIVE with location_label IS NOT NULL (audit spot-check per Viktor)
// Excludes Phase 2a's 10 sample IDs (already done).

const https = require('https');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });

const PAT = process.env.SUPABASE_PAT;
const PROD = 'wbasvhvvismukaqdnouk';

function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${PROD}/database/query`,
      method: 'POST',
      headers: {
        Authorization: `Bearer ${PAT}`,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
      },
    }, r => {
      let d = '';
      r.on('data', c => (d += c));
      r.on('end', () => { try { res(JSON.parse(d)); } catch (_) { res(d); } });
    });
    req.on('error', rej);
    req.write(body);
    req.end();
  });
}

// Phase 2a IDs to exclude (Casa Neos 63/64/65 + 7 samples)
const PHASE_2A_GDO_NUMBERS = [
  'GDO-10877', 'GDO-15062', 'GDO-16389',          // Casa Neos
  'GDO-01179', 'GDO-15328', 'GDO-00376',          // Soho, La Plaza, Granada
  'GDO-14336', 'GDO-01759', 'GDO-10822',          // Safar, BMN, TCE
  'GDO-11532',                                     // La Granja 36th
];

(async () => {
  const excludeList = PHASE_2A_GDO_NUMBERS.map(n => `'${n}'`).join(',');

  console.log('=== Phase 2b — 50-GDO pick ===\n');

  console.log('--- Group A: 15 ACTIVE rows with permit_expiration IS NULL (priority) ---');
  const groupA = await pg(`
    SELECT g.id, g.gdo_number, c.client_code, c.name AS client_name,
           p.address, p.zip, g.max_frequency_days, g.location_label
    FROM public.gdos g
    JOIN public.clients c ON c.id = g.client_id
    JOIN public.properties p ON p.id = g.property_id
    WHERE g.status = 'ACTIVE'
      AND g.permit_expiration IS NULL
      AND g.gdo_number NOT IN (${excludeList})
    ORDER BY g.gdo_number;
  `);
  console.log(`Count: ${groupA.length || 0}`);
  console.log(JSON.stringify(groupA, null, 2));

  console.log('\n--- Group B: 32 random ACTIVE rows with max_frequency_days IS NULL (excluding Group A) ---');
  const groupB = await pg(`
    SELECT g.id, g.gdo_number, c.client_code, c.name AS client_name,
           p.address, p.zip, g.permit_expiration::text
    FROM public.gdos g
    JOIN public.clients c ON c.id = g.client_id
    JOIN public.properties p ON p.id = g.property_id
    WHERE g.status = 'ACTIVE'
      AND g.max_frequency_days IS NULL
      AND g.permit_expiration IS NOT NULL  -- exclude Group A
      AND g.gdo_number NOT IN (${excludeList})
      AND p.address IS NOT NULL
    ORDER BY random()
    LIMIT 32;
  `);
  console.log(`Count: ${groupB.length || 0}`);
  console.log(JSON.stringify(groupB, null, 2));

  console.log('\n--- Group C: 3 ACTIVE rows with location_label IS NOT NULL (audit per Viktor) ---');
  const groupC = await pg(`
    SELECT g.id, g.gdo_number, c.client_code, c.name AS client_name,
           p.address, p.zip, g.location_label, g.max_frequency_days, g.permit_expiration::text
    FROM public.gdos g
    JOIN public.clients c ON c.id = g.client_id
    JOIN public.properties p ON p.id = g.property_id
    WHERE g.status = 'ACTIVE'
      AND g.location_label IS NOT NULL
      AND g.id NOT IN (63, 64, 65)  -- exclude Casa Neos (just done in 2a)
      AND p.address IS NOT NULL
    ORDER BY random()
    LIMIT 3;
  `);
  console.log(`Count: ${groupC.length || 0}`);
  console.log(JSON.stringify(groupC, null, 2));

  console.log('\n--- TOTAL ---');
  console.log(`A: ${groupA.length || 0} + B: ${groupB.length || 0} + C: ${groupC.length || 0} = ${(groupA.length || 0) + (groupB.length || 0) + (groupC.length || 0)}`);
})().catch(e => console.error('FATAL', e));
