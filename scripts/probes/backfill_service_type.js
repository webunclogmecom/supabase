// Backfill visits.service_type for NULL-typed visits using:
//   1. Title regex (same patterns as inferServiceType in webhook-jobber)
//   2. Invoice line-items fallback (mines li.name / li.description when title
//      doesn't carry a recognizable token but an invoice does)
//
// Idempotent — only writes where service_type IS NULL.
//
// 2026-05-12: Updated regex to add LS (lyft station) and standalone GT
// ("gt & cleaning" pattern). Added invoice line-items fallback.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

async function pg(sql) {
  for (let i = 0; i < 3; i++) {
    const out = await new Promise((res, rej) => {
      const req = https.request({
        hostname: 'api.supabase.com',
        path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
        method: 'POST',
        headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
      }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({ status: x.statusCode, body: b })); });
      req.on('error', rej); req.write(JSON.stringify({ query: sql })); req.end();
    });
    if (out.status < 300) return JSON.parse(out.body);
    await new Promise(rs => setTimeout(rs, 4000));
  }
  throw new Error('5xx exhausted');
}

// Use POSIX character classes ([[:space:]], [^[:alnum:]]) — verified working
// via the Supabase Management API in 2026-05-12 regex test. PG's ~* `\b`
// does NOT behave as a word boundary on this path (empirically returns false
// for "gt & cleaning" ~* '\bgt\b'); POSIX classes do.
const WORD_BOUNDARY_PRE = '(^|[^[:alnum:]])';
const WORD_BOUNDARY_POST = '([^[:alnum:]]|$)';

const TITLE_BACKFILL_SQL = `
  UPDATE visits SET service_type = inferred FROM (
    SELECT id,
      CASE
        WHEN title ~* 'lyft[[:space:]]*station' THEN 'LS'
        WHEN title ~* 'grease trap|grease pump|grey water|gray water|${WORD_BOUNDARY_PRE}gt${WORD_BOUNDARY_POST}' THEN 'GT'
        WHEN title ~* 'service call|${WORD_BOUNDARY_PRE}clog|emergency|hydrojet|${WORD_BOUNDARY_PRE}drain|${WORD_BOUNDARY_PRE}riser|fire pump|warranty|${WORD_BOUNDARY_PRE}repair' THEN 'CL'
        WHEN title ~* '${WORD_BOUNDARY_PRE}service${WORD_BOUNDARY_POST}' AND title !~* 'dump' THEN 'CL'
        ELSE NULL
      END AS inferred
    FROM visits
    WHERE service_type IS NULL AND title IS NOT NULL
  ) sub
  WHERE visits.id = sub.id AND sub.inferred IS NOT NULL AND visits.service_type IS NULL
  RETURNING visits.id, visits.service_type;
`;

// Conservative line-item fallback: only LS and GT (zero-ambiguity tokens).
// Skip CL because line items like "hydrojet"/"service call" often mean
// one-off emergency work, not a recurring CL subscription.
const LINEITEM_BACKFILL_SQL = `
  UPDATE visits v SET service_type = inferred FROM (
    SELECT v.id,
      CASE
        WHEN bool_or(COALESCE(li.name,'')||' '||COALESCE(li.description,'') ~* 'lyft[[:space:]]*station') THEN 'LS'
        WHEN bool_or(COALESCE(li.name,'')||' '||COALESCE(li.description,'') ~* 'grease trap|${WORD_BOUNDARY_PRE}gt${WORD_BOUNDARY_POST}') THEN 'GT'
        ELSE NULL
      END AS inferred
    FROM visits v
    JOIN line_items li ON li.invoice_id = v.invoice_id
    WHERE v.service_type IS NULL AND v.invoice_id IS NOT NULL
    GROUP BY v.id
  ) sub
  WHERE v.id = sub.id AND sub.inferred IS NOT NULL AND v.service_type IS NULL
  RETURNING v.id, v.service_type;
`;

(async () => {
  console.log('Before — NULL count:');
  const before = await pg(`SELECT COUNT(*)::int AS n FROM visits WHERE service_type IS NULL;`);
  console.log('  ' + before[0].n);

  console.log('\n[1/2] Title-pattern backfill (new regex: LS + standalone GT)...');
  const t = await pg(TITLE_BACKFILL_SQL);
  const titleByType = {};
  for (const r of t) titleByType[r.service_type] = (titleByType[r.service_type] || 0) + 1;
  console.log(`  +${t.length} rows: ${JSON.stringify(titleByType)}`);

  console.log('\n[2/2] Invoice line-item fallback (LS / GT only — conservative)...');
  const l = await pg(LINEITEM_BACKFILL_SQL);
  const liByType = {};
  for (const r of l) liByType[r.service_type] = (liByType[r.service_type] || 0) + 1;
  console.log(`  +${l.length} rows: ${JSON.stringify(liByType)}`);

  console.log('\nAfter — NULL count:');
  const after = await pg(`SELECT COUNT(*)::int AS n FROM visits WHERE service_type IS NULL;`);
  console.log('  ' + after[0].n);

  const dist = await pg(`SELECT COALESCE(service_type,'(NULL)') AS service_type, COUNT(*)::int AS n FROM visits GROUP BY 1 ORDER BY 2 DESC;`);
  console.log('\nFinal visits.service_type distribution:');
  for (const r of dist) console.log('  ' + r.service_type.padEnd(10) + r.n);

  // What's left as NULL — show top patterns so we can decide if they're legit
  const remaining = await pg(`
    SELECT lower(coalesce(title,'')) AS title_lc, COUNT(*)::int AS n
    FROM visits WHERE service_type IS NULL AND visit_date >= '2026-01-01'
    GROUP BY 1 ORDER BY n DESC LIMIT 25;
  `);
  console.log('\nRemaining NULL service_type (2026, top 25 titles):');
  for (const r of remaining) console.log('  ' + String(r.n).padStart(3) + '  ' + (r.title_lc || '(empty)'));
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
