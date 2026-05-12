// Cross-check Airtable Visits table against Jobber-canonical visits in our DB.
// Surfaces:
//   1. Status mismatch: AT says upcoming but Jobber says completed (AT not updated)
//   2. Status mismatch: AT says completed but Jobber says scheduled (AT premature)
//   3. Date mismatch: same Jobber Visit ID, different visit_date
//   4. Visits in Jobber but missing in AT (AT missing the visit)
//   5. Visits in AT but no Jobber link (orphan AT visit)
//   6. Duplicate AT visits (same client + same date + same service_type)
//
// Window: last 90 days + future. CLI: --since YYYY-MM-DD overrides.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const AT_KEY  = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

const sinceArg = process.argv.indexOf('--since');
const SINCE = sinceArg >= 0
  ? process.argv[sinceArg + 1]
  : new Date(Date.now() - 90 * 86400000).toISOString().slice(0, 10);

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  for (let i = 0; i < 3; i++) {
    const r = await http({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, JSON.stringify({ query: sql }));
    if (r.status < 300) return JSON.parse(r.body);
    if (r.status >= 500 || r.status === 429) { await new Promise(rs => setTimeout(rs, 4000 * (i+1))); continue; }
    throw new Error(`PG ${r.status}: ${r.body.slice(0, 200)}`);
  }
  throw new Error('5xx');
}

async function listAirtable(table, fields, filter) {
  const out = []; let offset; const enc = encodeURIComponent;
  do {
    const fp = (fields || []).map(f => `fields%5B%5D=${enc(f)}`).join('&');
    const ff = filter ? `&filterByFormula=${enc(filter)}` : '';
    const path = `/v0/${AT_BASE}/${enc(table)}?${fp}&pageSize=100${ff}${offset ? `&offset=${enc(offset)}` : ''}`;
    const r = await http({ hostname: 'api.airtable.com', path, method: 'GET',
      headers: { Authorization: `Bearer ${AT_KEY}` } });
    if (r.status >= 300) throw new Error(`Airtable ${table} ${r.status}: ${r.body.slice(0, 200)}`);
    const j = JSON.parse(r.body);
    for (const rec of (j.records || [])) out.push({ id: rec.id, ...rec.fields });
    offset = j.offset;
  } while (offset);
  return out;
}

(async () => {
  console.log(`Cross-check Airtable Visits vs Jobber-canonical (window: ${SINCE} → future)\n`);

  // 1. Pull Airtable visits
  console.log('[1/2] Pulling Airtable Visits...');
  const atVisits = await listAirtable('Visits',
    ['Visit Date', 'Service Type', 'Status', 'REAL STATUS', 'Client Code', 'Client', 'Jobber Visit ID'],
    `IS_AFTER({Visit Date}, '${SINCE}')`);
  console.log(`  ${atVisits.length} Airtable visits in window\n`);

  // 2. Pull our DB visits (canonical from Jobber)
  console.log('[2/2] Pulling our DB visits...');
  const dbVisits = await pg(`
    SELECT
      v.id, v.visit_date::text AS visit_date, v.visit_status, v.service_type,
      c.client_code,
      esl.source_id AS jobber_gid
    FROM visits v
    LEFT JOIN clients c ON c.id = v.client_id
    LEFT JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber'
    WHERE v.visit_date >= '${SINCE}'
  `);
  console.log(`  ${dbVisits.length} DB visits in window\n`);

  // Index DB visits by Jobber GID
  const dbByGid = {};
  for (const v of dbVisits) if (v.jobber_gid) dbByGid[v.jobber_gid] = v;

  // Buckets
  const statusMismatch = [];   // AT upcoming, DB completed → AT stale
  const statusEarly    = [];   // AT completed, DB scheduled → AT premature
  const dateMismatch   = [];   // matched, different visit_date
  const missingInAt    = [];   // in DB, no AT match
  const orphanInAt     = [];   // in AT, no Jobber GID
  const dupeInAt       = [];   // duplicates

  // Walk AT visits, matched/unmatched
  const atByGid = {};
  for (const a of atVisits) {
    const gid = a['Jobber Visit ID'];
    if (gid) atByGid[gid] = (atByGid[gid] || []).concat(a);
  }

  // Detect duplicates in AT (same Jobber Visit ID seen twice)
  for (const [gid, recs] of Object.entries(atByGid)) {
    if (recs.length > 1) {
      dupeInAt.push({ gid, atRecords: recs.map(r => ({ at_id: r.id, date: r['Visit Date'], svc: r['Service Type'], real_status: r['REAL STATUS'] })) });
    }
  }

  // For each AT visit, compare to DB
  for (const a of atVisits) {
    const gid = a['Jobber Visit ID'];
    const atStatus = String(a['REAL STATUS'] || a.Status || '').toLowerCase();
    const atDate = a['Visit Date'];
    const code = Array.isArray(a['Client Code']) ? a['Client Code'][0] : a['Client Code'];

    if (!gid) {
      // Pre-Jobber historical or never-linked
      orphanInAt.push({ at_id: a.id, date: atDate, code, real_status: atStatus, svc: a['Service Type'] });
      continue;
    }
    const db = dbByGid[gid];
    if (!db) continue; // No match — but the visit exists in AT with a Jobber GID. Jobber may have it under a different date filter.

    // Status mismatch checks (only meaningful if status fields populated)
    const dbDone = db.visit_status === 'completed';
    const atDone = /complete/i.test(atStatus);
    const atFuture = /upcoming|scheduled|late|today/i.test(atStatus);

    if (dbDone && atFuture) statusMismatch.push({ code, gid: gid.slice(0,30), db_date: db.visit_date, at_date: atDate, db_status: db.visit_status, at_status: atStatus });
    if (atDone && !dbDone)  statusEarly.push({   code, gid: gid.slice(0,30), db_date: db.visit_date, at_date: atDate, db_status: db.visit_status, at_status: atStatus });

    // Date mismatch (same visit, different date)
    if (atDate && db.visit_date && atDate !== db.visit_date) {
      dateMismatch.push({ code, gid: gid.slice(0,30), at_date: atDate, db_date: db.visit_date, at_status: atStatus, db_status: db.visit_status });
    }
  }

  // Visits in DB but no matching AT row (only flag completed visits — scheduled ones may not be in AT yet)
  for (const d of dbVisits) {
    if (!d.jobber_gid) continue;
    if (d.visit_status !== 'completed') continue;
    if (!atByGid[d.jobber_gid]) {
      missingInAt.push({ code: d.client_code, gid: d.jobber_gid.slice(0,30), db_date: d.visit_date, db_status: d.visit_status });
    }
  }

  // ============================================================================
  // REPORT
  // ============================================================================
  console.log(`============================================================`);
  console.log(`SUMMARY`);
  console.log(`============================================================`);
  console.log(`  Status mismatch (AT upcoming, Jobber completed):  ${statusMismatch.length}`);
  console.log(`  Status premature (AT completed, Jobber scheduled): ${statusEarly.length}`);
  console.log(`  Date mismatch (same visit, different dates):       ${dateMismatch.length}`);
  console.log(`  Missing in AT (completed in Jobber, no AT row):    ${missingInAt.length}`);
  console.log(`  Orphan in AT (AT row, no Jobber GID):              ${orphanInAt.length}`);
  console.log(`  Duplicate in AT (multi rows same Jobber GID):      ${dupeInAt.length}`);

  const printRows = (rows, limit = 15) => {
    for (const r of rows.slice(0, limit)) console.log('  ' + JSON.stringify(r));
    if (rows.length > limit) console.log(`  ...and ${rows.length - limit} more`);
  };

  if (statusMismatch.length) {
    console.log(`\n=== Status MISMATCH: AT upcoming / Jobber completed (${statusMismatch.length}) ===`);
    printRows(statusMismatch);
  }
  if (statusEarly.length) {
    console.log(`\n=== Status PREMATURE: AT completed / Jobber scheduled (${statusEarly.length}) ===`);
    printRows(statusEarly);
  }
  if (dateMismatch.length) {
    console.log(`\n=== DATE MISMATCH (${dateMismatch.length}) ===`);
    printRows(dateMismatch);
  }
  if (missingInAt.length) {
    console.log(`\n=== Completed in Jobber, MISSING in AT (${missingInAt.length}) ===`);
    printRows(missingInAt);
  }
  if (orphanInAt.length) {
    console.log(`\n=== ORPHAN in AT — no Jobber GID (${orphanInAt.length}) ===`);
    console.log(`  (These are usually pre-Jobber historical or test rows. Confirm if any are recent.)`);
    printRows(orphanInAt.filter(o => o.date >= SINCE), 10);
  }
  if (dupeInAt.length) {
    console.log(`\n=== DUPLICATE AT ROWS — same Jobber GID (${dupeInAt.length}) ===`);
    for (const d of dupeInAt.slice(0, 10)) console.log('  GID=' + d.gid.slice(0, 28) + '... × ' + d.atRecords.length + ' rows:  ' + d.atRecords.map(r => r.date + '/' + r.svc).join('  vs  '));
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
