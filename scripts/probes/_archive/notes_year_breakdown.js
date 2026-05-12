require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const r = (sql) => new Promise((res, rej) => {
  const req = https.request({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(JSON.parse(b))); });
  req.on('error', rej); req.write(JSON.stringify({query: sql})); req.end();
});
(async () => {
  console.log('=== notes by year ===');
  const notes = await r(`SELECT EXTRACT(YEAR FROM note_date)::int AS yr, COUNT(*) AS n FROM notes GROUP BY yr ORDER BY yr`);
  for (const n of notes) console.log(`  ${n.yr || '(null)'}: ${n.n}`);

  console.log('\n=== photos by year (via photo_links→notes) ===');
  const ph = await r(`
    SELECT EXTRACT(YEAR FROM n.note_date)::int AS yr, COUNT(*) AS n
    FROM photos p
    JOIN photo_links pl ON pl.photo_id = p.id AND pl.entity_type='note'
    JOIN notes n ON n.id = pl.entity_id
    GROUP BY yr ORDER BY yr
  `);
  for (const x of ph) console.log(`  ${x.yr || '(null)'}: ${x.n}`);

  console.log('\n=== photos created during today\'s catchup (today) ===');
  const today = await r(`
    SELECT EXTRACT(YEAR FROM n.note_date)::int AS yr, COUNT(*) AS n
    FROM photos p
    JOIN photo_links pl ON pl.photo_id = p.id AND pl.entity_type='note'
    JOIN notes n ON n.id = pl.entity_id
    WHERE p.created_at >= CURRENT_DATE
    GROUP BY yr ORDER BY yr
  `);
  for (const x of today) console.log(`  ${x.yr || '(null)'}: ${x.n}`);
})().catch(e => { console.error(e.message); process.exit(2); });
