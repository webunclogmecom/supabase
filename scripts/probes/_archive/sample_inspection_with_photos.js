// Pick one real inspection and show every photo with full context.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROJECT_ID = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,400)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log('=== One real inspection with the most photos ===\n');
  const insp = await q(`
    SELECT i.id, i.shift_date, i.inspection_type, e.full_name AS driver,
           v.name AS truck, COUNT(pl.id) AS n_photos
    FROM inspections i
    LEFT JOIN employees e ON e.id = i.employee_id
    LEFT JOIN vehicles v ON v.id = i.vehicle_id
    LEFT JOIN photo_links pl ON pl.entity_type='inspection' AND pl.entity_id=i.id
    GROUP BY i.id, e.full_name, v.name
    HAVING COUNT(pl.id) > 0
    ORDER BY n_photos DESC, i.id DESC LIMIT 1;
  `);
  console.table(insp);

  if (!insp.length) return;
  const inspId = insp[0].id;

  console.log(`\n=== Every photo linked to inspection ${inspId} ===\n`);
  console.table(await q(`
    SELECT pl.role,
           p.id AS photo_id,
           p.storage_path,
           p.size_bytes,
           p.content_type
    FROM photo_links pl
    JOIN photos p ON p.id = pl.photo_id
    WHERE pl.entity_type='inspection' AND pl.entity_id=${inspId}
    ORDER BY pl.role;
  `));

  console.log('\n=== As a Lovable app would render: a photo URL per role ===\n');
  const rows = await q(`
    SELECT pl.role, p.storage_path
    FROM photo_links pl JOIN photos p ON p.id=pl.photo_id
    WHERE pl.entity_type='inspection' AND pl.entity_id=${inspId}
    ORDER BY pl.role;
  `);
  for (const r of rows) {
    const enc = r.storage_path.split('/').map(encodeURIComponent).join('/');
    console.log(`  [${r.role.padEnd(15)}]  https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/${enc}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
