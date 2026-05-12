// Quick connection test for PROD_DB_URL and SANDBOX_DB_URL.
// Verifies: TCP connectivity, auth, and that we can run queries.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const { Client } = require('C:/Users/FRED/AppData/Local/Temp/pgtest/node_modules/pg');

async function test(label, url) {
  if (!url) { console.log(`[${label}] SKIP — env var not set`); return false; }
  if (url.includes('<') && url.includes('>')) {
    console.log(`[${label}] SKIP — placeholder still present (replace <PASSWORD>)`);
    return false;
  }
  const client = new Client({ connectionString: url });
  const t0 = Date.now();
  try {
    await client.connect();
    const r = await client.query(`
      SELECT
        current_database() AS db,
        current_user AS user,
        inet_server_addr() AS server,
        version() AS version,
        (SELECT COUNT(*) FROM clients) AS clients_count;
    `);
    const elapsed = Date.now() - t0;
    const row = r.rows[0];
    console.log(`[${label}] ✓ connected in ${elapsed}ms`);
    console.log(`         db=${row.db} user=${row.user}`);
    console.log(`         clients_count=${row.clients_count}`);
    console.log(`         pg_version=${row.version.slice(0, 50)}...`);
    await client.end();
    return true;
  } catch (e) {
    console.log(`[${label}] ✗ FAILED: ${e.message}`);
    try { await client.end(); } catch (_) {}
    return false;
  }
}

(async () => {
  const a = await test('PROD_DB_URL', process.env.PROD_DB_URL);
  const b = await test('SANDBOX_DB_URL', process.env.SANDBOX_DB_URL);
  console.log('\nResult: ' + (a && b ? '✓ both URLs work — daily refresh cron will fire correctly'
                                     : '✗ at least one URL failed — fix before the cron runs'));
  process.exit(a && b ? 0 : 1);
})();
