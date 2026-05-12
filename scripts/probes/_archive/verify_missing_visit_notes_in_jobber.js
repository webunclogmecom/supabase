// For each "completed but no photo in DB" visit from the last 4 weeks, query
// Jobber directly to see whether Jobber has notes/photos that we missed.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const JOBBER_TOKEN = process.env.JOBBER_ACCESS_TOKEN;
const JOBBER_API_VERSION = '2026-04-13';

function httpReq(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d }));
    });
    req.on('error', rej);
    req.setTimeout(30000, () => req.destroy(new Error('timeout')));
    if (body) req.write(body);
    req.end();
  });
}

async function pg(sql) {
  const body = JSON.stringify({ query: sql });
  const r = await httpReq({
    hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) throw new Error(`DB ${r.status}: ${r.body.slice(0,200)}`);
  return JSON.parse(r.body);
}

async function jobberGQL(query, variables) {
  const body = JSON.stringify({ query, variables });
  const r = await httpReq({
    hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
    headers: {
      Authorization: `Bearer ${JOBBER_TOKEN}`,
      'X-JOBBER-GRAPHQL-VERSION': JOBBER_API_VERSION,
      'Content-Type': 'application/json',
      'Content-Length': Buffer.byteLength(body),
    },
  }, body);
  if (r.status >= 300) throw new Error(`Jobber ${r.status}: ${r.body.slice(0,200)}`);
  const json = JSON.parse(r.body);
  if (json.errors) throw new Error(`Jobber GQL: ${JSON.stringify(json.errors).slice(0,200)}`);
  return json.data;
}

const Q_JOB_NOTES = `
  query JobNotes($id: EncodedId!) {
    job(id: $id) {
      notes(first: 30) {
        nodes {
          ... on ClientNote { id createdAt message
            fileAttachments { nodes { id fileName contentType fileSize } }
          }
          ... on JobNote { id createdAt message
            fileAttachments { nodes { id fileName contentType fileSize } }
          }
        }
      }
    }
  }
`;

const Q_VISIT = `
  query Visit($id: EncodedId!) {
    visit(id: $id) {
      id startAt endAt
      job { id }
      notes(first: 30) {
        nodes {
          ... on ClientNote { id createdAt message
            fileAttachments { nodes { id fileName contentType fileSize } }
          }
          ... on JobNote { id createdAt message
            fileAttachments { nodes { id fileName contentType fileSize } }
          }
        }
      }
    }
  }
`;

(async () => {
  console.log('Fetching last 4 weeks of completed-but-no-photo visits...\n');

  const missing = await pg(`
    SELECT v.id, v.visit_date, v.job_id, v.client_id, c.client_code, c.name AS client_name,
      (SELECT source_id FROM entity_source_links WHERE entity_type='visit' AND source_system='jobber' AND entity_id=v.id LIMIT 1) AS visit_gid,
      (SELECT source_id FROM entity_source_links WHERE entity_type='job'   AND source_system='jobber' AND entity_id=v.job_id LIMIT 1) AS job_gid
    FROM visits v
    JOIN clients c ON c.id = v.client_id
    WHERE v.visit_date >= current_date - INTERVAL '4 weeks'
      AND v.visit_date <= current_date
      AND v.visit_status = 'completed'
      AND NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)
      AND NOT EXISTS (SELECT 1 FROM notes n WHERE n.visit_id=v.id
                       AND EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='note' AND pl.entity_id=n.id))
      AND EXISTS (SELECT 1 FROM entity_source_links esl WHERE esl.entity_type='visit' AND esl.source_system='jobber' AND esl.entity_id=v.id)
    ORDER BY v.visit_date DESC LIMIT 20;
  `);

  console.log(`Checking ${missing.length} visits against Jobber...\n`);

  const results = [];
  for (const v of missing) {
    const result = { id: v.id, date: v.visit_date, code: v.client_code,
                     visit_gid: v.visit_gid?.slice(0, 16) + '…',
                     jobber_notes: 0, with_attachments: 0, attachment_files: '' };

    // Try via visit GID first (more direct)
    if (v.visit_gid) {
      try {
        const data = await jobberGQL(Q_VISIT, { id: v.visit_gid });
        const visit = data.visit;
        if (visit) {
          const notes = visit.notes?.nodes || [];
          result.jobber_notes = notes.length;
          let totalAtts = 0;
          const fileNames = [];
          for (const n of notes) {
            const atts = n.fileAttachments?.nodes || [];
            if (atts.length) {
              result.with_attachments++;
              totalAtts += atts.length;
              for (const a of atts) fileNames.push(a.fileName);
            }
          }
          result.attachment_files = fileNames.slice(0, 3).join(', ').slice(0, 60) + (fileNames.length > 3 ? `…(+${fileNames.length-3})` : '');
        } else {
          result.attachment_files = '(visit not found in Jobber)';
        }
      } catch (e) {
        result.attachment_files = `ERR: ${e.message.slice(0, 50)}`;
      }
    } else if (v.job_gid) {
      try {
        const data = await jobberGQL(Q_JOB_NOTES, { id: v.job_gid });
        const notes = data.job?.notes?.nodes || [];
        result.jobber_notes = notes.length;
        for (const n of notes) {
          const atts = n.fileAttachments?.nodes || [];
          if (atts.length) result.with_attachments++;
        }
        result.attachment_files = '(via job, ±1d filter NOT applied)';
      } catch (e) {
        result.attachment_files = `ERR: ${e.message.slice(0, 50)}`;
      }
    } else {
      result.attachment_files = '(no Jobber GID linked)';
    }

    results.push(result);
    await new Promise(r => setTimeout(r, 250));  // gentle on Jobber rate limit
  }

  console.table(results);

  const realGap = results.filter(r => r.with_attachments === 0 && !r.attachment_files.includes('ERR') && !r.attachment_files.includes('not found')).length;
  const recoverable = results.filter(r => r.with_attachments > 0).length;
  console.log(`\nSummary of ${results.length} sampled visits:`);
  console.log(`  ✓ Truly empty in Jobber (driver didn't take photos): ${realGap}`);
  console.log(`  ⚠ Has photos in Jobber but missing in our DB: ${recoverable}`);
  if (recoverable > 0) console.log('  → Photo migration / live sync gap. Worth investigating.');
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
