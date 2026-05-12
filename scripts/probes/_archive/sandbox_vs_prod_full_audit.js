// Full Sandbox-vs-Prod architectural audit.
//
// Purpose: surface every divergence between Sandbox and Prod so we can decide
//   - which Sandbox additions are Lovable-built and need porting to Prod
//   - which app_* tables have data in Sandbox we'd want preserved/standardized
//   - whether the schemas are quietly drifting in ways the refresh doesn't catch
//
// Categories checked:
//   A. Tables present in one DB but not the other
//   B. Columns added/dropped on shared tables
//   C. Views present in one but not the other (or with different definitions)
//   D. Functions / triggers / sequences delta
//   E. Indexes delta (Lovable often adds these silently)
//   F. CHECK / FK / UNIQUE constraints delta
//   G. RLS policies delta
//   H. Row counts on app_* tables in both DBs (where's the actual app data?)
//   I. Anything labeled "app_" or that smells Lovable-ish (lovable_, photo_class*)

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
    }, x => { let b=''; x.on('data', d => b+=d); x.on('end', () => res(JSON.parse(b))); });
    req.on('error', rej); req.write(JSON.stringify({query: sql})); req.end();
  });
}

const banner = (s) => console.log('\n' + '═'.repeat(70) + '\n  ' + s + '\n' + '═'.repeat(70));

(async () => {
  banner('A. TABLE DELTA (public schema)');
  const sbxT = (await pg(`SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1;`, SBX)).map(r => r.table_name);
  const prodT = (await pg(`SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1;`, PROD)).map(r => r.table_name);
  const onlyS = sbxT.filter(t => !prodT.includes(t));
  const onlyP = prodT.filter(t => !sbxT.includes(t));
  console.log(`  Sandbox total: ${sbxT.length}    Prod total: ${prodT.length}`);
  console.log(`  Sandbox-only (${onlyS.length}):`, onlyS);
  console.log(`  Prod-only (${onlyP.length}):`, onlyP);

  banner('B. COLUMN DELTA ON SHARED TABLES');
  const shared = sbxT.filter(t => prodT.includes(t));
  let totalAdded = 0, totalDropped = 0;
  for (const t of shared) {
    const sCols = (await pg(`SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema='public' AND table_name='${t}' ORDER BY ordinal_position;`, SBX));
    const pCols = (await pg(`SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema='public' AND table_name='${t}' ORDER BY ordinal_position;`, PROD));
    const sNames = sCols.map(c => c.column_name);
    const pNames = pCols.map(c => c.column_name);
    const added = sCols.filter(c => !pNames.includes(c.column_name));
    const dropped = pCols.filter(c => !sNames.includes(c.column_name));
    // Also catch type/nullable changes on shared columns
    const typeDiffs = [];
    for (const sc of sCols) {
      const pc = pCols.find(p => p.column_name === sc.column_name);
      if (!pc) continue;
      if (pc.data_type !== sc.data_type || pc.is_nullable !== sc.is_nullable) {
        typeDiffs.push({ col: sc.column_name, prod: `${pc.data_type}/${pc.is_nullable}`, sandbox: `${sc.data_type}/${sc.is_nullable}` });
      }
    }
    if (added.length || dropped.length || typeDiffs.length) {
      console.log(`\n  ${t}:`);
      if (added.length) {
        console.log(`    ★ Sandbox-added cols:`, added.map(c => `${c.column_name} (${c.data_type}, ${c.is_nullable==='YES'?'null':'not null'}${c.column_default?', default '+c.column_default:''})`));
        totalAdded += added.length;
      }
      if (dropped.length) {
        console.log(`    ✗ Sandbox-missing cols (in Prod, not in Sandbox):`, dropped.map(c => c.column_name));
        totalDropped += dropped.length;
      }
      if (typeDiffs.length) console.log(`    ⚠ Type/nullable mismatch:`, typeDiffs);
    }
  }
  console.log(`\n  Total Sandbox-added columns: ${totalAdded}    Sandbox-missing: ${totalDropped}`);

  banner('C. VIEW DELTA');
  const sbxV = (await pg(`SELECT viewname FROM pg_views WHERE schemaname='public' ORDER BY 1;`, SBX)).map(r => r.viewname);
  const prodV = (await pg(`SELECT viewname FROM pg_views WHERE schemaname='public' ORDER BY 1;`, PROD)).map(r => r.viewname);
  const onlyVS = sbxV.filter(v => !prodV.includes(v));
  const onlyVP = prodV.filter(v => !sbxV.includes(v));
  console.log(`  Sandbox views: ${sbxV.length}    Prod views: ${prodV.length}`);
  console.log(`  Sandbox-only views (${onlyVS.length}):`, onlyVS);
  console.log(`  Prod-only views (${onlyVP.length}):`, onlyVP);

  // For views in both, check definition equality
  const sharedV = sbxV.filter(v => prodV.includes(v));
  const defDiffs = [];
  for (const v of sharedV) {
    const sd = (await pg(`SELECT pg_get_viewdef('public.${v}'::regclass) AS def;`, SBX))[0].def;
    const pd = (await pg(`SELECT pg_get_viewdef('public.${v}'::regclass) AS def;`, PROD))[0].def;
    if (sd.replace(/\s+/g,' ').trim() !== pd.replace(/\s+/g,' ').trim()) defDiffs.push(v);
  }
  if (defDiffs.length) console.log(`  ⚠ Views with DIFFERENT definitions Sandbox vs Prod:`, defDiffs);
  else console.log(`  ✓ All shared views have matching definitions`);

  banner('D. FUNCTION / TRIGGER DELTA');
  const sbxF = (await pg(`SELECT proname, pg_get_function_identity_arguments(p.oid) AS args FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' ORDER BY proname;`, SBX));
  const prodF = (await pg(`SELECT proname, pg_get_function_identity_arguments(p.oid) AS args FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' ORDER BY proname;`, PROD));
  const sigS = new Set(sbxF.map(f => f.proname+'('+f.args+')'));
  const sigP = new Set(prodF.map(f => f.proname+'('+f.args+')'));
  const sOnlyF = [...sigS].filter(s => !sigP.has(s));
  const pOnlyF = [...sigP].filter(s => !sigS.has(s));
  console.log(`  Sandbox-only functions (${sOnlyF.length}):`, sOnlyF);
  console.log(`  Prod-only functions (${pOnlyF.length}):`, pOnlyF);

  const sbxTrig = (await pg(`SELECT trigger_name, event_object_table, action_timing, event_manipulation FROM information_schema.triggers WHERE trigger_schema='public' ORDER BY 1;`, SBX));
  const prodTrig = (await pg(`SELECT trigger_name, event_object_table, action_timing, event_manipulation FROM information_schema.triggers WHERE trigger_schema='public' ORDER BY 1;`, PROD));
  const tSet = (rs) => new Set(rs.map(t => `${t.trigger_name}@${t.event_object_table}`));
  const sT = tSet(sbxTrig); const pT = tSet(prodTrig);
  const sOnlyT = [...sT].filter(s => !pT.has(s));
  const pOnlyT = [...pT].filter(s => !sT.has(s));
  console.log(`  Sandbox-only triggers (${sOnlyT.length}):`, sOnlyT);
  console.log(`  Prod-only triggers (${pOnlyT.length}):`, pOnlyT);

  banner('E. INDEX DELTA (per shared table)');
  let indexDeltaTotal = 0;
  for (const t of shared) {
    const sI = (await pg(`SELECT indexname FROM pg_indexes WHERE schemaname='public' AND tablename='${t}' ORDER BY 1;`, SBX)).map(r => r.indexname);
    const pI = (await pg(`SELECT indexname FROM pg_indexes WHERE schemaname='public' AND tablename='${t}' ORDER BY 1;`, PROD)).map(r => r.indexname);
    const sOnly = sI.filter(i => !pI.includes(i));
    const pOnly = pI.filter(i => !sI.includes(i));
    if (sOnly.length || pOnly.length) {
      console.log(`  ${t}:`);
      if (sOnly.length) { console.log(`    ★ Sandbox-only indexes:`, sOnly); indexDeltaTotal += sOnly.length; }
      if (pOnly.length) console.log(`    ✗ Sandbox-missing indexes:`, pOnly);
    }
  }
  console.log(`\n  Total Sandbox-only indexes: ${indexDeltaTotal}`);

  banner('F. CONSTRAINT DELTA (CHECK / UNIQUE / FK)');
  let consDeltaTotal = 0;
  for (const t of shared) {
    const sC = (await pg(`SELECT conname, contype, pg_get_constraintdef(oid) AS def FROM pg_constraint WHERE conrelid='public.${t}'::regclass ORDER BY 1;`, SBX));
    const pC = (await pg(`SELECT conname, contype, pg_get_constraintdef(oid) AS def FROM pg_constraint WHERE conrelid='public.${t}'::regclass ORDER BY 1;`, PROD));
    const sNames = new Set(sC.map(c => c.conname));
    const pNames = new Set(pC.map(c => c.conname));
    const sOnly = sC.filter(c => !pNames.has(c.conname));
    const pOnly = pC.filter(c => !sNames.has(c.conname));
    if (sOnly.length || pOnly.length) {
      console.log(`  ${t}:`);
      if (sOnly.length) { console.log(`    ★ Sandbox-only constraints:`, sOnly.map(c => `${c.conname}: ${c.def}`)); consDeltaTotal += sOnly.length; }
      if (pOnly.length) console.log(`    ✗ Sandbox-missing constraints:`, pOnly.map(c => `${c.conname}: ${c.def}`));
    }
  }
  console.log(`\n  Total Sandbox-only constraints: ${consDeltaTotal}`);

  banner('G. RLS POLICY DELTA');
  for (const t of shared) {
    const sP = (await pg(`SELECT policyname, cmd, roles, qual, with_check FROM pg_policies WHERE schemaname='public' AND tablename='${t}' ORDER BY 1;`, SBX));
    const pP = (await pg(`SELECT policyname, cmd, roles, qual, with_check FROM pg_policies WHERE schemaname='public' AND tablename='${t}' ORDER BY 1;`, PROD));
    if (sP.length !== pP.length) {
      console.log(`  ${t}: Sandbox=${sP.length} policies, Prod=${pP.length} policies`);
      console.log(`    Sandbox:`, sP.map(p => `${p.policyname}/${p.cmd}`));
      console.log(`    Prod:`, pP.map(p => `${p.policyname}/${p.cmd}`));
    }
  }

  banner('H. ROW COUNTS — app_* and any Sandbox-only tables');
  const appLikeS = [...sbxT, ...onlyS].filter(t => /^(app_|lovable_)/i.test(t)).sort();
  console.log(`  app_/lovable_ tables in Sandbox (${appLikeS.length}):`);
  for (const t of [...new Set(appLikeS)]) {
    try {
      const sCount = (await pg(`SELECT COUNT(*) AS n FROM public.${t};`, SBX))[0].n;
      let pCount = '(N/A — table not in Prod)';
      if (prodT.includes(t)) pCount = (await pg(`SELECT COUNT(*) AS n FROM public.${t};`, PROD))[0].n;
      console.log(`    ${t}: Sandbox=${sCount}  Prod=${pCount}`);
    } catch (e) { console.log(`    ${t}: (count failed: ${e.message})`); }
  }

  banner('I. ANYTHING SMELLING LOVABLE-ISH ANYWHERE');
  const smell = (await pg(`
    SELECT table_name, column_name, data_type
    FROM information_schema.columns
    WHERE table_schema='public'
      AND (table_name ILIKE 'app_%' OR table_name ILIKE 'lovable%'
           OR column_name ILIKE '%lovable%' OR column_name ILIKE '%review_status%'
           OR column_name ILIKE '%bonus_%' OR column_name ILIKE '%classified%')
    ORDER BY table_name, ordinal_position;`, SBX));
  console.log(`  ${smell.length} columns in Sandbox under app_/lovable/review/bonus/classified patterns`);
  for (const r of smell) console.log(`    ${r.table_name}.${r.column_name}  (${r.data_type})`);

  banner('SUMMARY');
  console.log(`  Tables Sandbox-only: ${onlyS.length}`);
  console.log(`  Tables Prod-only:    ${onlyP.length}`);
  console.log(`  Columns added in Sandbox:    ${totalAdded}`);
  console.log(`  Columns missing in Sandbox:  ${totalDropped}`);
  console.log(`  Sandbox-only indexes:        ${indexDeltaTotal}`);
  console.log(`  Sandbox-only constraints:    ${consDeltaTotal}`);
})().catch(e => { console.error('FATAL:', e.message, e.stack); process.exit(2); });
