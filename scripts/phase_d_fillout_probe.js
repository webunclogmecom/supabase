// ============================================================================
// Phase D — Fillout Probe (READ-ONLY)
// ============================================================================
// Discovers pre/post shift form structure, question IDs, submission counts.
// ============================================================================

require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');

const KEY = process.env.FILLOUT_API_KEY;
const PRE = process.env.FILLOUT_PRESHIFT_FORM_ID;
const POST = process.env.FILLOUT_POSTSHIFT_FORM_ID;
if (!KEY || !PRE || !POST) { console.error('Missing Fillout env vars'); process.exit(1); }

function get(p) {
  return new Promise((res, rej) => {
    https.request({
      hostname: 'api.fillout.com',
      path: p,
      headers: { Authorization: `Bearer ${KEY}` },
    }, r => {
      let d = '';
      r.on('data', c => d += c);
      r.on('end', () => {
        if (r.statusCode >= 200 && r.statusCode < 300) {
          try { res(JSON.parse(d)); } catch (e) { rej(new Error('bad json: ' + d.slice(0, 200))); }
        } else rej(new Error(`HTTP ${r.statusCode}: ${d.slice(0, 300)}`));
      });
    }).on('error', rej).end();
  });
}

async function probeForm(id, label) {
  console.log(`\n[${label}] form id: ${id}`);

  // Metadata (questions, fields)
  const meta = await get(`/v1/api/forms/${id}`);
  console.log(`  name: "${meta.name}"`);
  console.log(`  questions: ${(meta.questions || []).length}`);
  (meta.questions || []).forEach(q => {
    console.log(`    - [${q.type}] ${q.name} (id=${q.id})`);
  });

  // Submissions — just totalResponses + 1 sample
  const subs = await get(`/v1/api/forms/${id}/submissions?limit=1`);
  const total = subs.totalResponses != null ? subs.totalResponses : (subs.responses || []).length;
  console.log(`  total submissions: ${total}`);
  if ((subs.responses || []).length) {
    const s = subs.responses[0];
    console.log(`  sample submission id: ${s.submissionId}`);
    console.log(`  sample fieldKeys:`, Object.keys(s));
    console.log(`  sample questions answered: ${(s.questions || []).length}`);
    if (s.questions) {
      s.questions.slice(0, 10).forEach(q => {
        const v = typeof q.value === 'string' ? q.value.slice(0, 60) : JSON.stringify(q.value || '').slice(0, 60);
        console.log(`    * ${q.name}: ${v}`);
      });
    }
  }
  return { meta, total, sample: (subs.responses || [])[0] };
}

(async () => {
  console.log('Phase D — Fillout Probe');
  const report = { generated_at: new Date().toISOString() };
  try {
    report.pre = await probeForm(PRE, 'PRE-SHIFT');
  } catch (e) { console.log(`  ERROR: ${e.message}`); report.pre = { error: e.message }; }
  try {
    report.post = await probeForm(POST, 'POST-SHIFT');
  } catch (e) { console.log(`  ERROR: ${e.message}`); report.post = { error: e.message }; }

  const out = path.resolve(__dirname, 'phase_d_fillout_report.json');
  fs.writeFileSync(out, JSON.stringify(report, null, 2));
  console.log(`\nReport: ${out}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
