// Check Sandbox Supabase for any before/after-service photo classification work
// added by Lovable (Admin Review App). Looks at:
//   - photos table columns (new ones since Prod baseline?)
//   - photo_links table columns
//   - any new app_* tables
//   - any column with name containing 'phase', 'before', 'after', 'pre', 'post', 'service_stage'
//   - sample rows showing populated classifications
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PROD = process.env.SUPABASE_PROJECT_ID;

function pg(sql, projectId) {
  return new Promise((res, rej) => {
    const req = https.request({
      hostname: 'api.supabase.com',
      path: `/v1/projects/${projectId}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res({status: x.statusCode, body: b})); });
    req.on('error', rej); req.write(JSON.stringify({query: sql})); req.end();
  });
}

(async () => {
  console.log(`Sandbox project: ${SBX}`);
  console.log(`Prod project:    ${PROD}\n`);

  // 1. Confirm access
  const ping = await pg(`SELECT current_database() AS db, now() AS now;`, SBX);
  if (ping.status >= 300) {
    console.error('Sandbox access failed:', ping.status, ping.body.slice(0, 300));
    process.exit(2);
  }
  console.log('Sandbox reachable:', JSON.parse(ping.body));
  console.log('');

  // 2. Diff schemas: tables in Sandbox not in Prod (or vice versa)
  const sbxTables = JSON.parse((await pg(`
    SELECT table_name FROM information_schema.tables
    WHERE table_schema='public' ORDER BY table_name;`, SBX)).body).map(r => r.table_name);
  const prodTables = JSON.parse((await pg(`
    SELECT table_name FROM information_schema.tables
    WHERE table_schema='public' ORDER BY table_name;`, PROD)).body).map(r => r.table_name);

  const onlyInSbx = sbxTables.filter(t => !prodTables.includes(t));
  const onlyInProd = prodTables.filter(t => !sbxTables.includes(t));
  console.log(`Tables only in Sandbox (${onlyInSbx.length}):`, onlyInSbx);
  console.log(`Tables only in Prod (${onlyInProd.length}):`, onlyInProd);
  console.log('');

  // 3. Diff columns for photos + photo_links (the obvious places before/after would live)
  for (const tbl of ['photos', 'photo_links']) {
    const sbxCols = JSON.parse((await pg(`
      SELECT column_name, data_type FROM information_schema.columns
      WHERE table_schema='public' AND table_name='${tbl}'
      ORDER BY ordinal_position;`, SBX)).body);
    const prodCols = JSON.parse((await pg(`
      SELECT column_name, data_type FROM information_schema.columns
      WHERE table_schema='public' AND table_name='${tbl}'
      ORDER BY ordinal_position;`, PROD)).body);
    const sbxNames = sbxCols.map(c => c.column_name);
    const prodNames = prodCols.map(c => c.column_name);
    const newCols = sbxCols.filter(c => !prodNames.includes(c.column_name));
    const removedCols = prodCols.filter(c => !sbxNames.includes(c.column_name));
    console.log(`=== ${tbl} ===`);
    console.log(`  Sandbox cols (${sbxNames.length}):`, sbxNames.join(', '));
    if (newCols.length) console.log(`  ★ NEW in Sandbox:`, newCols.map(c => `${c.column_name} (${c.data_type})`));
    if (removedCols.length) console.log(`  ✗ Missing in Sandbox:`, removedCols.map(c => c.column_name));
    if (!newCols.length && !removedCols.length) console.log('  (no schema delta vs Prod)');
    console.log('');
  }

  // 4. Hunt for ANY column anywhere in Sandbox that hints at before/after classification
  console.log('=== Columns matching before/after/phase/pre/post/stage anywhere in Sandbox ===');
  const hits = JSON.parse((await pg(`
    SELECT table_name, column_name, data_type
    FROM information_schema.columns
    WHERE table_schema='public'
      AND (
        column_name ILIKE '%before%' OR
        column_name ILIKE '%after%' OR
        column_name ILIKE '%phase%' OR
        column_name ILIKE '%pre_service%' OR
        column_name ILIKE '%post_service%' OR
        column_name ILIKE '%service_stage%' OR
        column_name ILIKE '%photo_type%' OR
        column_name ILIKE '%photo_category%' OR
        column_name ILIKE '%classification%' OR
        column_name ILIKE '%category%'
      )
    ORDER BY table_name, column_name;`, SBX)).body);
  if (hits.length === 0) {
    console.log('  (no matching columns found anywhere in public schema)');
  } else {
    for (const h of hits) console.log(`  ${h.table_name}.${h.column_name}  (${h.data_type})`);
  }
  console.log('');

  // 5. If photo_links has anything new, sample its rows
  const phLinkSbxCols = JSON.parse((await pg(`
    SELECT column_name FROM information_schema.columns
    WHERE table_schema='public' AND table_name='photo_links'
    ORDER BY ordinal_position;`, SBX)).body).map(c => c.column_name);
  const interesting = phLinkSbxCols.filter(c =>
    /before|after|phase|service_stage|photo_type|category|classification/i.test(c));
  if (interesting.length) {
    console.log(`=== Sample photo_links rows showing classification columns: ${interesting.join(', ')} ===`);
    const sample = JSON.parse((await pg(`
      SELECT id, entity_type, ${interesting.join(', ')}
      FROM photo_links
      WHERE ${interesting.map(c => `${c} IS NOT NULL`).join(' OR ')}
      LIMIT 10;`, SBX)).body);
    console.log(JSON.stringify(sample, null, 2));
  }

  // 6. Same for photos
  const photosSbxCols = JSON.parse((await pg(`
    SELECT column_name FROM information_schema.columns
    WHERE table_schema='public' AND table_name='photos'
    ORDER BY ordinal_position;`, SBX)).body).map(c => c.column_name);
  const photosInteresting = photosSbxCols.filter(c =>
    /before|after|phase|service_stage|photo_type|category|classification/i.test(c));
  if (photosInteresting.length) {
    console.log(`\n=== Sample photos rows showing classification columns: ${photosInteresting.join(', ')} ===`);
    const sample = JSON.parse((await pg(`
      SELECT id, ${photosInteresting.join(', ')}
      FROM photos
      WHERE ${photosInteresting.map(c => `${c} IS NOT NULL`).join(' OR ')}
      LIMIT 10;`, SBX)).body);
    console.log(JSON.stringify(sample, null, 2));
  }

  // 7. Also check app_visit_reviews for any classification-adjacent fields
  console.log('\n=== app_visit_reviews columns (Sandbox) ===');
  const avrCols = JSON.parse((await pg(`
    SELECT column_name, data_type FROM information_schema.columns
    WHERE table_schema='public' AND table_name='app_visit_reviews'
    ORDER BY ordinal_position;`, SBX)).body);
  if (!avrCols.length) {
    console.log('  (table does not exist in Sandbox)');
  } else {
    for (const c of avrCols) console.log(`  ${c.column_name}  (${c.data_type})`);
  }

  // 8. Row counts for any photo-classification table that might exist
  const photoLikeTables = sbxTables.filter(t =>
    /photo|image|review/i.test(t));
  console.log(`\n=== Row counts for photo/image/review tables in Sandbox ===`);
  for (const t of photoLikeTables) {
    try {
      const r = JSON.parse((await pg(`SELECT COUNT(*) AS n FROM "${t}";`, SBX)).body);
      console.log(`  ${t}: ${r[0].n}`);
    } catch (e) { console.log(`  ${t}: (count failed)`); }
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
