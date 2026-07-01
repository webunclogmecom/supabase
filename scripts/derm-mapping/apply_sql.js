// Apply a .sql file to Prod via the Management API. Usage: node apply_sql.js <path-to-sql>
const fs = require('fs');
const { q } = require('./lib/db');
(async () => {
  const file = process.argv[2];
  if (!file) { console.error('usage: node apply_sql.js <file.sql>'); process.exit(1); }
  const sql = fs.readFileSync(file, 'utf8');
  await q(sql);
  console.log('applied OK:', file);
})().catch(e => { console.error('ERR', e.message); process.exit(1); });
