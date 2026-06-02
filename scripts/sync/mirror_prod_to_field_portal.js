// Mirror Prod → Field Portal Sandbox for the two dual-write tables:
//   - visit_assignments (no dual-write at all — Lovable writes nothing here;
//                        webhook writes to Prod only; we must mirror)
//   - photo_classifications (Lovable dual-writes to Sandbox #1 + Prod, but
//                            Field Portal is a separate project)
//
// Scope: only rows where the parent (visit / photo_link) ALREADY exists in
// Field Portal (its 44-client subset). Doesn't enlarge the subset.
//
// Semantics:
//   - visit_assignments: INSERT ON CONFLICT DO NOTHING (immutable join row)
//   - photo_classifications: UPSERT on photo_link_id (Prod is source of truth
//                            for service_phase; overwrite FP)
//
// Usage:
//   node scripts/sync/mirror_prod_to_field_portal.js              # do it
//   node scripts/sync/mirror_prod_to_field_portal.js --dry-run    # show counts only

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const FP = process.env.FIELD_PORTAL_SUPABASE_PROJECT_ID;
const DRY = process.argv.includes('--dry-run');

function pg(sql, project) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${project}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({s: x.statusCode, b})); });
    req.on('error', rej);
    req.write(JSON.stringify({query: sql}));
    req.end();
  });
}
const j = x => { try { return JSON.parse(x); } catch { return x; } };

(async () => {
  console.log(`Mode: ${DRY ? 'DRY RUN' : 'EXECUTE'}\n`);

  // === visit_assignments ===
  console.log('Visit assignments —');

  const fpVisitIds = j((await pg(`SELECT id FROM visits;`, FP)).b).map(r => r.id);
  console.log(`  Field Portal has ${fpVisitIds.length} visits in its subset`);

  if (fpVisitIds.length === 0) { console.log('  no visits in FP; skipping'); }
  else {
    const prodRows = j((await pg(`
      SELECT visit_id, employee_id FROM visit_assignments
      WHERE visit_id IN (${fpVisitIds.join(',')});
    `, PROD)).b);
    console.log(`  Prod has ${prodRows.length} assignment rows for those visits`);

    const fpRows = j((await pg(`SELECT visit_id, employee_id FROM visit_assignments;`, FP)).b);
    const fpKey = new Set(fpRows.map(r => `${r.visit_id}:${r.employee_id}`));
    const missing = prodRows.filter(r => !fpKey.has(`${r.visit_id}:${r.employee_id}`));
    console.log(`  Field Portal is missing ${missing.length} rows`);

    if (missing.length && !DRY) {
      const values = missing.map(r => `(${r.visit_id}, ${r.employee_id})`).join(',');
      const r = await pg(`INSERT INTO visit_assignments (visit_id, employee_id) VALUES ${values} ON CONFLICT (visit_id, employee_id) DO NOTHING;`, FP);
      console.log(`  inserted: ${r.s === 201 ? '✓' : '✗ ' + r.b.slice(0,200)}`);
    }
  }

  // === photo_classifications ===
  console.log('\nPhoto classifications —');
  const fpPhotoLinkIds = j((await pg(`SELECT id FROM photo_links;`, FP)).b).map(r => r.id);
  console.log(`  Field Portal has ${fpPhotoLinkIds.length} photo_links in its subset`);

  if (fpPhotoLinkIds.length === 0) { console.log('  no photo_links in FP; skipping'); }
  else {
    const prodRows = j((await pg(`
      SELECT photo_link_id, service_phase, classified_by_user_id, quality_flag, notes, created_at, updated_at
      FROM photo_classifications
      WHERE photo_link_id IN (${fpPhotoLinkIds.join(',')});
    `, PROD)).b);
    console.log(`  Prod has ${prodRows.length} classification rows for those photo_links`);

    if (prodRows.length && !DRY) {
      const values = prodRows.map(r => {
        const sp = "'" + r.service_phase.replace(/'/g, "''") + "'";
        const cb = r.classified_by_user_id ? `'${r.classified_by_user_id}'` : 'NULL';
        const qf = r.quality_flag ? `'${r.quality_flag.replace(/'/g, "''")}'` : 'NULL';
        const nt = r.notes ? `'${r.notes.replace(/'/g, "''")}'` : 'NULL';
        const ca = `'${r.created_at}'`;
        const ua = `'${r.updated_at}'`;
        return `(${r.photo_link_id}, ${sp}, ${cb}, ${qf}, ${nt}, ${ca}, ${ua})`;
      }).join(',');
      // UPSERT: Prod is source of truth — overwrite FP rows where they exist
      const sql = `
        INSERT INTO photo_classifications (photo_link_id, service_phase, classified_by_user_id, quality_flag, notes, created_at, updated_at)
        VALUES ${values}
        ON CONFLICT (photo_link_id) DO UPDATE SET
          service_phase = EXCLUDED.service_phase,
          classified_by_user_id = EXCLUDED.classified_by_user_id,
          quality_flag = EXCLUDED.quality_flag,
          notes = EXCLUDED.notes,
          updated_at = EXCLUDED.updated_at;
      `;
      const r = await pg(sql, FP);
      console.log(`  upserted: ${r.s === 201 ? '✓' : '✗ ' + r.b.slice(0,200)}`);
    }
  }

  // === verify ===
  console.log('\n=== After mirror — verify ===');
  console.log('Visit 3915 (092-TCE May 4) driver in Field Portal:');
  console.log(j((await pg(`SELECT v.id, (SELECT string_agg(e.full_name, ', ') FROM visit_assignments va JOIN employees e ON e.id=va.employee_id WHERE va.visit_id=v.id) AS drivers FROM visits v WHERE v.id=3915;`, FP)).b));
  console.log('\nField Portal counts:');
  console.log('  visit_assignments:', j((await pg(`SELECT COUNT(*)::int AS n FROM visit_assignments;`, FP)).b));
  console.log('  photo_classifications:', j((await pg(`SELECT COUNT(*)::int AS n, MAX(updated_at) AS latest FROM photo_classifications;`, FP)).b));
})().catch(e => { console.error('FATAL:', e); process.exit(2); });
