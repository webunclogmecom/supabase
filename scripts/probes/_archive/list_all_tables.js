// One-shot: list all tables in public schema with row counts.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROJECT_ID = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,400)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  const tables = await q(`
    SELECT table_name FROM information_schema.tables
    WHERE table_schema='public' AND table_type='BASE TABLE'
    ORDER BY table_name;
  `);
  const counts = [];
  for (const t of tables) {
    try {
      const r = await q(`SELECT COUNT(*)::bigint AS n FROM "${t.table_name}";`);
      counts.push({ table: t.table_name, rows: Number(r[0].n) });
    } catch (e) {
      counts.push({ table: t.table_name, rows: `ERR: ${e.message.slice(0,40)}` });
    }
  }
  console.table(counts);
  console.log(`\nTotal tables: ${counts.length}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
