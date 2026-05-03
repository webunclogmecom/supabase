// Export an audit CSV of every visit + photo combination linked in our DB
// so Yan/Fred can review whether the photo belongs to that visit.
//
// One row per visit↔photo link (a single photo can link to multiple visits
// via photo_links, but in practice each visit maps to its own photos).
//
// Output: visit_photo_audit_<UTC_date>.csv at project root.
//
// Columns:
//   visit_id, client_code, client_name, visit_date, completed_at,
//   note_id, note_created_at, note_pinned, days_off (note vs completed_at),
//   photo_id, file_name, content_type, file_size_bytes,
//   storage_path, public_url, jobber_attachment_gid, jobber_note_gid,
//   jobber_visit_url
//
// CSV format chosen over .xlsx so it opens in Excel without a Node lib install.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
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
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.toString().slice(0, 200)}`);
  return JSON.parse(r.body.toString());
}

const csvField = v => {
  if (v == null) return '';
  const s = String(v).replace(/"/g, '""');
  return /[",\n]/.test(s) ? `"${s}"` : s;
};

(async () => {
  // Filter to 2026+ visits where any visit photo_link exists. Pull every
  // photo linked to each visit, plus its note metadata when reachable.
  const rows = await pg(`
    SELECT
      v.id                           AS visit_id,
      c.client_code                  AS client_code,
      c.name                         AS client_name,
      v.visit_date::text             AS visit_date,
      v.completed_at::text           AS completed_at,
      n.id                           AS note_id,
      n.created_at::text             AS note_created_at,
      CASE
        WHEN n.created_at IS NOT NULL AND v.completed_at IS NOT NULL
          THEN ROUND(EXTRACT(EPOCH FROM (n.created_at - v.completed_at)) / 86400.0, 1)
        ELSE NULL
      END                            AS days_off,
      p.id                           AS photo_id,
      p.file_name                    AS file_name,
      p.content_type                 AS content_type,
      p.size_bytes                   AS file_size_bytes,
      p.storage_path                 AS storage_path,
      'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/'
        || REPLACE(p.storage_path, ' ', '%20')
                                     AS public_url,
      esl_p.source_id                AS jobber_attachment_gid,
      esl_n.source_id                AS jobber_note_gid,
      'https://secure.getjobber.com/visits/' || split_part(esl_v.source_id, '/', 4)
                                     AS jobber_visit_url_guess
    FROM photo_links pl_v
    JOIN photos p           ON p.id = pl_v.photo_id
    JOIN visits v           ON v.id = pl_v.entity_id AND pl_v.entity_type = 'visit'
    LEFT JOIN clients c     ON c.id = v.client_id
    LEFT JOIN photo_links pl_n ON pl_n.photo_id = p.id AND pl_n.entity_type = 'note'
    LEFT JOIN notes n       ON n.id = pl_n.entity_id
    LEFT JOIN entity_source_links esl_p ON esl_p.entity_type='photo' AND esl_p.entity_id=p.id AND esl_p.source_system='jobber'
    LEFT JOIN entity_source_links esl_n ON esl_n.entity_type='note'  AND esl_n.entity_id=n.id  AND esl_n.source_system='jobber'
    LEFT JOIN entity_source_links esl_v ON esl_v.entity_type='visit' AND esl_v.entity_id=v.id  AND esl_v.source_system='jobber'
    WHERE v.visit_date >= '2026-01-01'
    ORDER BY v.visit_date, c.client_code, v.id, p.id;
  `);

  const headers = [
    'visit_id', 'client_code', 'client_name', 'visit_date', 'completed_at',
    'note_id', 'note_created_at', 'days_off',
    'photo_id', 'file_name', 'content_type', 'file_size_bytes',
    'storage_path', 'public_url',
    'jobber_attachment_gid', 'jobber_note_gid', 'jobber_visit_url_guess'
  ];

  const lines = [headers.join(',')];
  for (const r of rows) {
    lines.push(headers.map(h => csvField(r[h])).join(','));
  }

  const stamp = new Date().toISOString().slice(0, 10);
  const outPath = path.resolve(__dirname, `../../visit_photo_audit_${stamp}.csv`);
  fs.writeFileSync(outPath, lines.join('\n'), 'utf8');

  console.log(`wrote ${rows.length} rows → ${outPath}`);

  // Quick stats
  const visitsCovered = new Set(rows.map(r => r.visit_id)).size;
  const photosCovered = new Set(rows.map(r => r.photo_id)).size;
  console.log(`  distinct visits:  ${visitsCovered}`);
  console.log(`  distinct photos:  ${photosCovered}`);
})();
