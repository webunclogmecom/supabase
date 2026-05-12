// Verify Lovable's new sidecar tables (app_photo_classifications + app_property_overrides)
// against the 7 contract rules + Pattern B requirements.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
function pg(sql) { return new Promise((res, rej) => {
  const req = https.request({hostname:'api.supabase.com',path:`/v1/projects/${SBX}/database/query`,method:'POST',headers:{Authorization:`Bearer ${process.env.SUPABASE_PAT}`,'Content-Type':'application/json'}}, x => {let b='';x.on('data',d=>b+=d);x.on('end',()=>res({status:x.statusCode,body:b}));});
  req.on('error',rej); req.write(JSON.stringify({query:sql})); req.end();
});}
async function q(sql) { const r = await pg(sql); if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0,200)}`); return JSON.parse(r.body); }

const banner = s => console.log('\n' + '─'.repeat(70) + '\n  ' + s + '\n' + '─'.repeat(70));

const TABLES = ['app_photo_classifications', 'app_property_overrides'];

(async () => {
  banner('1. TABLE EXISTENCE');
  for (const t of TABLES) {
    const r = await q(`SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='${t}') AS exists;`);
    console.log(`  ${t}: ${r[0].exists ? '✅ exists' : '❌ NOT FOUND'}`);
  }

  banner('2. COLUMN STRUCTURE — types, nullability, defaults');
  for (const t of TABLES) {
    const cols = await q(`
      SELECT column_name, data_type, udt_name, is_nullable, column_default
      FROM information_schema.columns
      WHERE table_schema='public' AND table_name='${t}'
      ORDER BY ordinal_position;`);
    console.log(`\n  ${t}:`);
    for (const c of cols) {
      const t2 = c.data_type === 'USER-DEFINED' ? c.udt_name : c.data_type;
      const def = c.column_default ? ` DEFAULT ${c.column_default.slice(0,40)}` : '';
      console.log(`    ${c.column_name.padEnd(28)} ${t2.padEnd(28)} ${c.is_nullable==='NO'?'NOT NULL':'nullable'}${def}`);
    }
  }

  banner('3. CONSTRAINTS — CHECK, UNIQUE, PK, FK');
  for (const t of TABLES) {
    const cons = await q(`
      SELECT conname, contype, pg_get_constraintdef(oid) AS def
      FROM pg_constraint
      WHERE conrelid = 'public.${t}'::regclass
      ORDER BY contype, conname;`);
    console.log(`\n  ${t}:`);
    for (const c of cons) {
      const type = {p:'PK',u:'UNIQUE',f:'FK',c:'CHECK',x:'EXCLUDE'}[c.contype] || c.contype;
      console.log(`    [${type}] ${c.conname}: ${c.def}`);
    }
  }

  banner('4. INDEXES');
  for (const t of TABLES) {
    const idx = await q(`SELECT indexname, indexdef FROM pg_indexes WHERE schemaname='public' AND tablename='${t}' ORDER BY indexname;`);
    console.log(`\n  ${t}:`);
    for (const i of idx) console.log(`    ${i.indexname}: ${i.indexdef}`);
  }

  banner('5. RLS state + policies');
  for (const t of TABLES) {
    const rls = await q(`SELECT relrowsecurity AS rls FROM pg_class WHERE oid='public.${t}'::regclass;`);
    const pols = await q(`SELECT policyname, cmd, roles::text, qual, with_check FROM pg_policies WHERE schemaname='public' AND tablename='${t}' ORDER BY policyname;`);
    console.log(`\n  ${t}: RLS=${rls[0].rls ? 'ENABLED' : '⚠ DISABLED'}`);
    for (const p of pols) {
      console.log(`    ${p.policyname} | cmd=${p.cmd} | roles=${p.roles}`);
      if (p.qual) console.log(`      USING: ${p.qual}`);
      if (p.with_check) console.log(`      WITH CHECK: ${p.with_check}`);
    }
  }

  banner('6. TRIGGERS');
  for (const t of TABLES) {
    const trigs = await q(`SELECT trigger_name, action_timing, event_manipulation, action_statement FROM information_schema.triggers WHERE trigger_schema='public' AND event_object_table='${t}' ORDER BY trigger_name;`);
    console.log(`\n  ${t}:`);
    for (const tr of trigs) console.log(`    ${tr.trigger_name} ${tr.action_timing} ${tr.event_manipulation}: ${tr.action_statement.slice(0,80)}`);
  }

  banner('7. COMMENTS on table + columns');
  for (const t of TABLES) {
    const tblCmt = await q(`SELECT obj_description('public.${t}'::regclass, 'pg_class') AS cmt;`);
    console.log(`\n  ${t}: table COMMENT = ${tblCmt[0].cmt ? '"' + tblCmt[0].cmt.slice(0,100) + '"' : '❌ NONE'}`);
    const colCmts = await q(`
      SELECT a.attname AS col, col_description(a.attrelid, a.attnum) AS cmt
      FROM pg_attribute a
      WHERE a.attrelid='public.${t}'::regclass AND a.attnum > 0 AND NOT a.attisdropped
      ORDER BY a.attnum;`);
    const withCmt = colCmts.filter(c => c.cmt).length;
    console.log(`    column COMMENTs: ${withCmt}/${colCmts.length} populated`);
    for (const c of colCmts.filter(c => c.cmt)) console.log(`      ${c.col}: "${c.cmt.slice(0,80)}"`);
  }

  banner('8. TABLE-LEVEL GRANTS');
  for (const t of TABLES) {
    const g = await q(`
      SELECT grantee, string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privs
      FROM information_schema.role_table_grants
      WHERE table_schema='public' AND table_name='${t}' AND grantee IN ('anon','authenticated','service_role')
      GROUP BY grantee ORDER BY grantee;`);
    console.log(`\n  ${t}:`);
    for (const row of g) console.log(`    ${row.grantee.padEnd(15)} ${row.privs}`);
  }

  banner('9. PROPERTIES grants — check the OLD column-level grant on grease_trap_manhole_count was removed');
  const propsGrants = await q(`
    SELECT grantee, column_name, privilege_type
    FROM information_schema.column_privileges
    WHERE table_schema='public' AND table_name='properties'
      AND grantee IN ('anon','authenticated')
      AND privilege_type IN ('UPDATE','INSERT','DELETE')
    ORDER BY column_name, grantee, privilege_type;`);
  if (!propsGrants.length) {
    console.log('  ✓ No anon/auth write grants on any properties column (clean)');
  } else {
    console.log('  ⚠ Lingering write grants on properties columns:');
    for (const r of propsGrants) console.log(`    ${r.column_name}.${r.grantee}.${r.privilege_type}`);
  }

  banner('10. CONTRACT LINT RESULTS');
  const lint = [];
  for (const t of TABLES) {
    const cols = await q(`
      SELECT column_name, data_type, udt_name, is_nullable, column_default
      FROM information_schema.columns WHERE table_schema='public' AND table_name='${t}'
      ORDER BY ordinal_position;`);
    const tblCmt = await q(`SELECT obj_description('public.${t}'::regclass, 'pg_class') AS cmt;`);
    const cons = await q(`SELECT contype, pg_get_constraintdef(oid) AS def FROM pg_constraint WHERE conrelid='public.${t}'::regclass;`);
    const rls = await q(`SELECT relrowsecurity AS rls FROM pg_class WHERE oid='public.${t}'::regclass;`);

    // Rule 1: Source-prefixed columns
    for (const c of cols) {
      if (/^(jobber_|airtable_|samsara_|lovable_)/.test(c.column_name) && !/^external_/.test(c.column_name)) {
        lint.push(`${t}: source-prefixed column "${c.column_name}" — Rule 1 violation`);
      }
    }
    // Rule 5: TIMESTAMPTZ for time cols
    for (const c of cols) {
      if (/_at$|_date$/.test(c.column_name) && c.data_type !== 'timestamp with time zone' && c.data_type !== 'date') {
        lint.push(`${t}.${c.column_name}: time-shaped column is ${c.data_type}, should be TIMESTAMPTZ`);
      }
    }
    // Rule 5: BIGINT id
    const idCol = cols.find(c => c.column_name === 'id');
    if (idCol && idCol.data_type !== 'bigint') {
      lint.push(`${t}.id: ${idCol.data_type}, should be BIGINT (BIGSERIAL)`);
    }
    // Rule 5: external_*_id BIGINT
    for (const c of cols) {
      if (/^external_.*_id$/.test(c.column_name) && c.data_type !== 'bigint') {
        lint.push(`${t}.${c.column_name}: ${c.data_type}, should be BIGINT`);
      }
    }
    // No real FK to canonical
    const fks = cons.filter(c => c.contype === 'f');
    for (const fk of fks) {
      const m = fk.def.match(/REFERENCES (\w+)/);
      if (m) {
        const canonical = ['clients','properties','client_contacts','service_configs','jobs','visits','visit_assignments','invoices','line_items','quotes','notes','photos','photo_links','derm_manifests','manifest_visits','inspections','employees','vehicles','vehicle_telemetry_readings','entity_source_links','jobber_oversized_attachments'];
        if (canonical.includes(m[1])) {
          lint.push(`${t}: real FK to canonical "${m[1]}" — Rule for "no real FK" violated; should be loose external_*_id`);
        }
      }
    }
    // Rule 6: RLS on
    if (!rls[0].rls) lint.push(`${t}: RLS NOT enabled — Rule 6 violation`);
    // Rule 7: table COMMENT
    if (!tblCmt[0].cmt) lint.push(`${t}: missing table COMMENT — Rule 7 violation`);
    // Should have updated_at trigger
    const trigs = await q(`SELECT trigger_name FROM information_schema.triggers WHERE trigger_schema='public' AND event_object_table='${t}' AND event_manipulation='UPDATE';`);
    if (!trigs.length && cols.find(c => c.column_name === 'updated_at')) {
      lint.push(`${t}: has updated_at column but no BEFORE UPDATE trigger — convention violation`);
    }
    // Should have unique constraint on external_*_id (or composite)
    const uniques = cons.filter(c => c.contype === 'u');
    if (!uniques.length) {
      lint.push(`${t}: no UNIQUE constraint — likely missing dedup-on-conflict for UPSERT pattern`);
    }
    // Should have CHECK constraint on enum text cols
    for (const c of cols) {
      if (c.data_type === 'text' && /(_status|_phase|_type|_state)$/.test(c.column_name)) {
        const checks = cons.filter(co => co.contype === 'c' && co.def.includes(c.column_name));
        if (!checks.length) {
          lint.push(`${t}.${c.column_name}: text column with enum-like name has no CHECK constraint`);
        }
      }
    }
  }
  if (lint.length === 0) {
    console.log('  ✅ ALL CONTRACT CHECKS PASS');
  } else {
    console.log(`  ⚠ ${lint.length} issue(s):`);
    for (const issue of lint) console.log(`    • ${issue}`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
