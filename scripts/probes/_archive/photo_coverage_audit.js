// Comprehensive photo coverage audit across the 3 photo-bearing domains:
//   1. Jobber visit-notes (visits + notes + photo_links)
//   2. DERM manifests (manifest_images + address_images columns)
//   3. Airtable PRE-POST inspections (photos linked via photo_links)
//
// Reports: total entities, % with photos, total photo count, gaps,
// coverage trends per month.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); req.setTimeout(60000, () => req.destroy(new Error('timeout')));
    if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}

const SECTION = (t) => console.log(`\n${'='.repeat(72)}\n${t}\n${'='.repeat(72)}`);
const SUB = (t) => console.log(`\n  ${t}`);

(async () => {
  // ==========================================================================
  // 1. JOBBER VISIT-NOTES PHOTOS
  // ==========================================================================
  SECTION('1. JOBBER VISIT-NOTES PHOTO COVERAGE');

  const visitTotals = await pg(`
    SELECT
      COUNT(*) AS total,
      COUNT(*) FILTER (WHERE visit_status='completed') AS completed,
      COUNT(*) FILTER (WHERE visit_status='completed' AND visit_date >= '2026-01-01') AS completed_2026
    FROM visits;
  `);
  console.log(`  Visits in DB:           ${visitTotals[0].total} total, ${visitTotals[0].completed} completed, ${visitTotals[0].completed_2026} completed in 2026+`);

  const visitWithPhotos = await pg(`
    SELECT COUNT(DISTINCT v.id) AS n
    FROM visits v WHERE v.visit_status='completed' AND v.visit_date >= '2026-01-01'
      AND EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id);
  `);
  const completed2026 = Number(visitTotals[0].completed_2026);
  const withPhotos = Number(visitWithPhotos[0].n);
  console.log(`  With photos linked:     ${withPhotos} (${(withPhotos*100/completed2026).toFixed(1)}%)`);
  console.log(`  Without photos:         ${completed2026 - withPhotos}`);

  SUB('Coverage by month (2026, completed visits)');
  const byMonth = await pg(`
    SELECT date_trunc('month', visit_date)::date AS month,
      COUNT(*) AS visits,
      COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)) AS with_photos
    FROM visits v
    WHERE visit_status='completed' AND visit_date BETWEEN '2026-01-01' AND CURRENT_DATE
    GROUP BY 1 ORDER BY 1;
  `);
  for (const r of byMonth) {
    const pct = (Number(r.with_photos) * 100 / Number(r.visits)).toFixed(1);
    console.log(`    ${r.month}: ${r.with_photos}/${r.visits} (${pct}%)`);
  }

  SUB('Total Jobber-source photos in DB');
  const jobPhotos = await pg(`SELECT COUNT(*) AS n FROM photos WHERE source IN ('jobber', 'recovered')`);
  const allPhotos = await pg(`SELECT source, COUNT(*) AS n FROM photos GROUP BY source ORDER BY n DESC`);
  console.log(`    by source:`);
  for (const r of allPhotos) console.log(`      ${(r.source || '(null)').padEnd(15)} ${r.n}`);

  SUB('Notes vs photos linkage');
  const notesStats = await pg(`
    SELECT
      COUNT(*) AS total_notes,
      COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='note' AND pl.entity_id=n.id)) AS notes_with_photos
    FROM notes n;
  `);
  console.log(`    Total notes:        ${notesStats[0].total_notes}`);
  console.log(`    Notes with photos:  ${notesStats[0].notes_with_photos}`);

  // ==========================================================================
  // 2. DERM MANIFEST PHOTOS
  // ==========================================================================
  SECTION('2. DERM MANIFEST PHOTO COVERAGE');

  const dermTotals = await pg(`
    SELECT
      COUNT(*) AS total,
      COUNT(*) FILTER (WHERE manifest_images IS NOT NULL AND jsonb_typeof(manifest_images) = 'array' AND jsonb_array_length(manifest_images) > 0) AS with_manifest_imgs,
      COUNT(*) FILTER (WHERE address_images IS NOT NULL AND jsonb_typeof(address_images) = 'array' AND jsonb_array_length(address_images) > 0) AS with_address_imgs
    FROM derm_manifests;
  `);
  console.log(`  DERM manifests:         ${dermTotals[0].total} total`);
  console.log(`  With manifest_images:   ${dermTotals[0].with_manifest_imgs}`);
  console.log(`  With address_images:    ${dermTotals[0].with_address_imgs}`);

  // Are DERM photos linked via photo_links polymorphic?
  const dermViaPL = await pg(`
    SELECT COUNT(DISTINCT entity_id) AS manifests_with_pl_photos,
           COUNT(*) AS total_pl_rows
    FROM photo_links WHERE entity_type='derm_manifest';
  `);
  console.log(`  Linked via photo_links: ${dermViaPL[0].manifests_with_pl_photos} manifests, ${dermViaPL[0].total_pl_rows} photo links`);

  SUB('Sample manifest_images structure');
  const dermSample = await pg(`SELECT id, white_manifest_number, jsonb_array_length(manifest_images) AS img_count, manifest_images->0 AS first_img FROM derm_manifests WHERE manifest_images IS NOT NULL AND jsonb_typeof(manifest_images)='array' AND jsonb_array_length(manifest_images) > 0 LIMIT 3`);
  for (const r of dermSample) console.log(`    manifest ${r.id} (${r.white_manifest_number}): ${r.img_count} images, sample: ${JSON.stringify(r.first_img).slice(0, 120)}`);

  SUB('DERM monthly coverage (service_date)');
  const dermByMonth = await pg(`
    SELECT date_trunc('month', service_date)::date AS month,
      COUNT(*) AS manifests,
      COUNT(*) FILTER (WHERE manifest_images IS NOT NULL AND jsonb_typeof(manifest_images)='array' AND jsonb_array_length(manifest_images) > 0) AS with_imgs
    FROM derm_manifests
    WHERE service_date >= '2026-01-01'
    GROUP BY 1 ORDER BY 1;
  `);
  for (const r of dermByMonth) {
    const pct = (Number(r.with_imgs) * 100 / Number(r.manifests)).toFixed(1);
    console.log(`    ${r.month}: ${r.with_imgs}/${r.manifests} (${pct}%)`);
  }

  // ==========================================================================
  // 3. PRE-POST INSPECTION PHOTOS
  // ==========================================================================
  SECTION('3. PRE-POST INSPECTION PHOTO COVERAGE');

  // First check the inspections table schema for image columns
  const insCols = await pg(`SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='inspections' ORDER BY ordinal_position`);
  console.log(`  inspections columns:    ${insCols.map(c => c.column_name).join(', ')}`);
  const hasImgCol = insCols.some(c => c.column_name.match(/image|photo/i));
  console.log(`  Has image/photo col:    ${hasImgCol}`);

  // Linked via photo_links?
  const insViaPL = await pg(`
    SELECT COUNT(DISTINCT entity_id) AS inspections_with_pl_photos,
           COUNT(*) AS total_pl_rows
    FROM photo_links WHERE entity_type='inspection';
  `);
  console.log(`  Linked via photo_links: ${insViaPL[0].inspections_with_pl_photos} inspections, ${insViaPL[0].total_pl_rows} photo links`);

  const insTotals = await pg(`
    SELECT
      COUNT(*) AS total,
      COUNT(*) FILTER (WHERE inspection_type='PRE') AS pre,
      COUNT(*) FILTER (WHERE inspection_type='POST') AS post,
      COUNT(*) FILTER (WHERE submitted_at >= '2026-01-01') AS in_2026
    FROM inspections;
  `);
  console.log(`  Inspections:            ${insTotals[0].total} total (${insTotals[0].pre} PRE, ${insTotals[0].post} POST), ${insTotals[0].in_2026} in 2026`);

  SUB('Inspections with photos via polymorphic photo_links');
  const insWithPhotos = await pg(`
    SELECT COUNT(DISTINCT i.id) AS n FROM inspections i
    WHERE EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='inspection' AND pl.entity_id=i.id);
  `);
  console.log(`    ${insWithPhotos[0].n} of ${insTotals[0].total} inspections have photos linked`);
  if (Number(insWithPhotos[0].n) === 0) {
    console.log(`    ⚠️  ZERO inspection photos in our DB — Airtable PRE-POST photo sync likely not implemented`);
  }

  SUB('photo_links entity_type distribution overall');
  const plDist = await pg(`SELECT entity_type, COUNT(*) AS n FROM photo_links GROUP BY entity_type ORDER BY n DESC`);
  for (const r of plDist) console.log(`    ${(r.entity_type || '(null)').padEnd(15)} ${r.n}`);

  // ==========================================================================
  // SUMMARY VERDICT
  // ==========================================================================
  SECTION('SUMMARY (using photo_links — the real source of truth)');
  const dermTotal = Number(dermTotals[0].total);
  const dermWithPL = Number(dermViaPL[0].manifests_with_pl_photos);
  const insTotal = Number(insTotals[0].total);
  const insWithPL = Number(insWithPhotos[0].n);
  const verdict = (n, t) => {
    const pct = n*100/t;
    if (pct >= 90) return '✅ GOOD';
    if (pct >= 70) return '🟡 OK';
    return '❌ GAP';
  };
  console.log(`
  Domain                     | Coverage           | Verdict
  ---------------------------|--------------------|----------
  Jobber visit-notes (2026)  | ${String(withPhotos).padStart(3)}/${String(completed2026).padEnd(3)} (${(withPhotos*100/completed2026).toFixed(0).padStart(3)}%) | ${verdict(withPhotos, completed2026)}
  DERM manifests             | ${String(dermWithPL).padStart(3)}/${String(dermTotal).padEnd(3)} (${(dermWithPL*100/dermTotal).toFixed(0).padStart(3)}%) | ${verdict(dermWithPL, dermTotal)}
  PRE-POST inspections       | ${String(insWithPL).padStart(3)}/${String(insTotal).padEnd(3)} (${(insWithPL*100/insTotal).toFixed(0).padStart(3)}%) | ${verdict(insWithPL, insTotal)}

  Note: derm_manifests has dead JSON columns 'manifest_images' /
  'address_images' — both 0/972 populated. All real DERM photo links go
  through the photo_links polymorphic table (entity_type='derm_manifest').
  Those JSON columns are vestigial; safe to drop pre-sunset if Yannick's
  app doesn't read them.
  `);

  // Gap details
  SECTION('GAP DETAILS');

  SUB('Visits without photos (20) — already known from earlier audit');
  const noVisitPhotos = await pg(`
    SELECT v.id, v.visit_date::text, c.client_code, c.name
    FROM visits v JOIN clients c ON c.id=v.client_id
    WHERE v.visit_status='completed' AND v.visit_date >= '2026-01-01'
      AND NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)
    ORDER BY v.visit_date DESC LIMIT 5;
  `);
  for (const r of noVisitPhotos) console.log(`    v${r.id} ${r.visit_date} ${r.client_code || '?'} — ${(r.name || '').slice(0,40)}`);
  console.log(`    (5 of ${completed2026 - withPhotos} shown)`);

  SUB(`DERM manifests without photos (${dermTotal - dermWithPL})`);
  const noDerm = await pg(`
    SELECT m.id, m.white_manifest_number, m.service_date::text, c.client_code, c.name
    FROM derm_manifests m LEFT JOIN clients c ON c.id=m.client_id
    WHERE NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='derm_manifest' AND pl.entity_id=m.id)
    ORDER BY m.service_date DESC LIMIT 5;
  `);
  for (const r of noDerm) console.log(`    m${r.id} ${r.service_date || '(no date)'} ${r.white_manifest_number || '(no #)'} — ${r.client_code || '?'} ${(r.name || '').slice(0,30)}`);
  console.log(`    (5 of ${dermTotal - dermWithPL} shown)`);

  SUB(`PRE-POST inspections without photos (${insTotal - insWithPL})`);
  const noIns = await pg(`
    SELECT i.id, i.shift_date::text, i.inspection_type, e.full_name AS inspector
    FROM inspections i LEFT JOIN employees e ON e.id=i.employee_id
    WHERE NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='inspection' AND pl.entity_id=i.id)
    ORDER BY i.shift_date DESC LIMIT 5;
  `);
  for (const r of noIns) console.log(`    i${r.id} ${r.shift_date} ${r.inspection_type} — ${r.inspector || '(no inspector)'}`);
  console.log(`    (5 of ${insTotal - insWithPL} shown)`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
