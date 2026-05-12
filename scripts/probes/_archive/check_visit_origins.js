// Where did these "missing photo" visits come from? Check entity_source_links.
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
  console.log('=== Origin breakdown of last-4-weeks completed-but-no-photo visits ===');
  console.table(await q(`
    WITH missing AS (
      SELECT v.id, v.visit_date, c.client_code
      FROM visits v JOIN clients c ON c.id=v.client_id
      WHERE v.visit_date >= current_date - INTERVAL '4 weeks'
        AND v.visit_date <= current_date
        AND v.visit_status = 'completed'
        AND NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)
    )
    SELECT
      COALESCE(STRING_AGG(DISTINCT esl.source_system, ',' ORDER BY esl.source_system),
               '(no source links)') AS sources,
      COUNT(DISTINCT m.id) AS n_visits
    FROM missing m
    LEFT JOIN entity_source_links esl
      ON esl.entity_type='visit' AND esl.entity_id=m.id
    GROUP BY esl.source_system IS NULL OR esl.source_system = ''
    ORDER BY n_visits DESC;
  `));

  console.log('\n=== Same query but show every (visit_id, source_system) link ===');
  console.table(await q(`
    SELECT
      esl.source_system,
      COUNT(DISTINCT esl.entity_id) AS visits_linked
    FROM visits v
    JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id
    WHERE v.visit_date >= current_date - INTERVAL '4 weeks'
      AND v.visit_date <= current_date
      AND v.visit_status = 'completed'
      AND NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)
    GROUP BY esl.source_system;
  `));

  console.log('\n=== Are ANY of those visits linked to Jobber at all? ===');
  console.table(await q(`
    SELECT
      COUNT(*) AS total_no_photo_visits,
      COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM entity_source_links esl WHERE esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber')) AS jobber_linked,
      COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM entity_source_links esl WHERE esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='airtable')) AS airtable_linked,
      COUNT(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM entity_source_links esl WHERE esl.entity_type='visit' AND esl.entity_id=v.id)) AS unlinked
    FROM visits v
    WHERE v.visit_date >= current_date - INTERVAL '4 weeks'
      AND v.visit_date <= current_date
      AND v.visit_status = 'completed'
      AND NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id);
  `));

  console.log('\n=== Pick 5 sample missing visits — show ALL their source links and job linkage ===');
  console.table(await q(`
    SELECT v.id, v.visit_date, c.client_code,
      v.job_id,
      (SELECT STRING_AGG(source_system||'='||source_id, ' | ') FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id) AS visit_links,
      (SELECT STRING_AGG(source_system||'='||source_id, ' | ') FROM entity_source_links WHERE entity_type='job' AND entity_id=v.job_id) AS job_links
    FROM visits v JOIN clients c ON c.id=v.client_id
    WHERE v.visit_date >= current_date - INTERVAL '4 weeks'
      AND v.visit_date <= current_date
      AND v.visit_status = 'completed'
      AND NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)
    ORDER BY v.visit_date DESC LIMIT 5;
  `));

  console.log('\n=== For comparison: 5 WITH photos — what links do they have? ===');
  console.table(await q(`
    SELECT v.id, v.visit_date, c.client_code,
      v.job_id,
      (SELECT STRING_AGG(source_system||'='||source_id, ' | ') FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id) AS visit_links
    FROM visits v JOIN clients c ON c.id=v.client_id
    WHERE v.visit_date >= current_date - INTERVAL '4 weeks'
      AND v.visit_status = 'completed'
      AND EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)
    ORDER BY v.visit_date DESC LIMIT 5;
  `));
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
