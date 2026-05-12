// Verify whether `photo_links.role` and `properties.grease_trap_manhole_count`
// already exist in Prod (and therefore aren't Yannick-Sandbox additions at all).
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const SB = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej);
    if (body) req.write(body); req.end();
  });
}
async function pg(project, sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${project}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  return JSON.parse(r.body);
}
(async () => {
  for (const [name, proj] of [['PROD', PROD], ['SANDBOX', SB]]) {
    console.log(`\n=== ${name} ===`);
    const ph = await pg(proj, `
      SELECT column_name, data_type, column_default
      FROM information_schema.columns
      WHERE table_schema='public' AND table_name='photo_links' ORDER BY ordinal_position;
    `);
    console.log(`  photo_links columns:`, ph.map(c => `${c.column_name}:${c.data_type}`).join(', '));

    const pr = await pg(proj, `
      SELECT column_name, data_type, column_default
      FROM information_schema.columns
      WHERE table_schema='public' AND table_name='properties'
        AND column_name LIKE '%manhole%' ORDER BY ordinal_position;
    `);
    console.log(`  properties manhole-cols:`, pr.length ? pr.map(c => `${c.column_name}:${c.data_type}`).join(', ') : '(none)');

    // Sample data — are these populated anywhere?
    const ph2 = await pg(proj, `
      SELECT role, COUNT(*) AS n FROM photo_links
      WHERE role IS NOT NULL GROUP BY role ORDER BY 2 DESC LIMIT 10;
    `).catch(e => `err: ${e.message.slice(0,80)}`);
    console.log(`  photo_links.role distribution:`, ph2);

    const pr2 = await pg(proj, `
      SELECT grease_trap_manhole_count, COUNT(*) AS n FROM properties
      GROUP BY grease_trap_manhole_count ORDER BY 1;
    `).catch(e => `err: ${e.message.slice(0,80)}`);
    console.log(`  properties.grease_trap_manhole_count distribution:`, pr2);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
