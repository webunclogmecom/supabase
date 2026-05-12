// Last-4-weeks coverage check: do completed visits have any photo evidence?
// Two paths a visit can have a "picture":
//   1. Direct: photo_links.entity_type='visit' AND entity_id=visit.id
//   2. Via Jobber notes: notes attached to the visit, where the note has photos
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,400)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log('=== notes table — does it have visit_id FK? ===');
  console.table(await q(`SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='notes' ORDER BY ordinal_position;`));

  console.log('\n=== Last 4 weeks: visits by status + photo coverage ===');
  console.table(await q(`
    WITH recent AS (
      SELECT v.id, v.visit_date, v.visit_status, v.client_id
      FROM visits v
      WHERE v.visit_date >= current_date - INTERVAL '4 weeks'
        AND v.visit_date <= current_date
    ),
    visit_pics AS (
      SELECT entity_id AS visit_id FROM photo_links WHERE entity_type='visit'
    ),
    note_pics AS (
      SELECT n.visit_id
      FROM notes n
      WHERE n.visit_id IS NOT NULL
        AND EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='note' AND pl.entity_id=n.id)
    )
    SELECT
      r.visit_status,
      COUNT(*) AS total,
      COUNT(*) FILTER (WHERE r.id IN (SELECT visit_id FROM visit_pics)) AS with_visit_photo,
      COUNT(*) FILTER (WHERE r.id IN (SELECT visit_id FROM note_pics))  AS with_note_photo,
      COUNT(*) FILTER (WHERE r.id IN (SELECT visit_id FROM visit_pics)
                          OR r.id IN (SELECT visit_id FROM note_pics))  AS with_any_photo,
      COUNT(*) FILTER (WHERE r.id NOT IN (SELECT visit_id FROM visit_pics)
                         AND r.id NOT IN (SELECT visit_id FROM note_pics)) AS no_photos
    FROM recent r
    GROUP BY r.visit_status
    ORDER BY total DESC;
  `));

  console.log('\n=== Sample 10 recent COMPLETED visits without ANY photo ===');
  console.table(await q(`
    SELECT v.id, v.visit_date, c.client_code, c.name AS client_name, v.title,
           (SELECT COUNT(*) FROM notes n WHERE n.visit_id=v.id) AS notes_count
    FROM visits v
    JOIN clients c ON c.id = v.client_id
    WHERE v.visit_date >= current_date - INTERVAL '4 weeks'
      AND v.visit_date <= current_date
      AND v.visit_status = 'completed'
      AND NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)
      AND NOT EXISTS (SELECT 1 FROM notes n WHERE n.visit_id=v.id
                       AND EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='note' AND pl.entity_id=n.id))
    ORDER BY v.visit_date DESC LIMIT 10;
  `));

  console.log('\n=== Sample 5 recent visits WITH photos (positive control) ===');
  console.table(await q(`
    SELECT v.id, v.visit_date, c.client_code,
           (SELECT COUNT(*) FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id) AS direct_visit_photos,
           (SELECT COUNT(*) FROM notes n JOIN photo_links pl ON pl.entity_type='note' AND pl.entity_id=n.id WHERE n.visit_id=v.id) AS note_photos
    FROM visits v JOIN clients c ON c.id = v.client_id
    WHERE v.visit_date >= current_date - INTERVAL '4 weeks'
      AND v.visit_date <= current_date
      AND v.visit_status = 'completed'
      AND (EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)
        OR EXISTS (SELECT 1 FROM notes n WHERE n.visit_id=v.id AND EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='note' AND pl.entity_id=n.id)))
    ORDER BY v.visit_date DESC LIMIT 5;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
