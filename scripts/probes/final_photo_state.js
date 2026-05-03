require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c) }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  return JSON.parse(r.body.toString());
}

(async () => {
  // Photo-less completed Jobber visits remaining
  const remaining = await pg(`
    SELECT COUNT(*) AS n FROM visits v
    JOIN entity_source_links esl_v ON esl_v.entity_type='visit' AND esl_v.entity_id=v.id AND esl_v.source_system='jobber'
    WHERE v.visit_status='completed' AND v.visit_date >= '2026-01-01'
      AND NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)
  `);
  console.log('Remaining photo-less completed visits (≥2026-01-01):', remaining[0].n);

  // Total photo_links created in the last 4h
  const recent = await pg(`
    SELECT COUNT(*) AS n FROM photo_links pl
    WHERE pl.created_at >= now() - interval '4 hours' AND pl.entity_type='visit'
  `);
  console.log('photo_links (entity_type=visit) created last 4h:', recent[0].n);

  // Total photos uploaded in last 4h
  const photos = await pg(`SELECT COUNT(*) AS n FROM photos WHERE created_at >= now() - interval '4 hours'`);
  console.log('photos rows created last 4h:', photos[0].n);

  // Distinct visits that got at least one new photo_link in last 4h
  const visitsCovered = await pg(`
    SELECT COUNT(DISTINCT pl.entity_id) AS n FROM photo_links pl
    WHERE pl.created_at >= now() - interval '4 hours' AND pl.entity_type='visit'
  `);
  console.log('Distinct visits newly photo-linked last 4h:', visitsCovered[0].n);
})();
