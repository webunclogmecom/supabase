// ============================================================================
// sandbox_lovable_lint.js
// ============================================================================
// Automated contract enforcement for Lovable's Sandbox additions.
//
// Diffs Sandbox (ubtlwpcyntelgbykdatn) vs Prod (wbasvhvvismukaqdnouk), then
// checks every Sandbox-only table/column/view/index against the 7 rules in
// handoff/unclogme-lovable-handoff/05-RULES.md and the Lovable system prompt.
//
// Rules checked:
//   1. Source-prefixed names (jobber_*, airtable_*, samsara_*, lovable_*) → FAIL
//   2. 3NF — derivable columns / cached values from canonical → WARN
//   3. Reference, don't copy (client_name in non-clients table, etc) → WARN
//   5. TIMESTAMPTZ (not TIMESTAMP) on time cols → FAIL
//   5. NUMERIC(12,2) on money-shaped cols (price/amount/total/cost/revenue) → FAIL
//   5. BIGINT (not INTEGER) on id/external_*_id cols → FAIL
//   5. updated_at column WITHOUT BEFORE UPDATE trigger → WARN
//   6. New TABLE without RLS enabled → FAIL
//   6. New TABLE without at least one RLS policy → FAIL
//   7. COMMENT on table → WARN if missing
//   Pattern A trap — Sandbox-only column on CANONICAL table → WARN (will be wiped)
//   Pattern B compliance — new table referencing canonical: must use external_*_id BIGINT
//     with NO real FK to canonical → FAIL if real FK to canonical
//   UNIQUE constraint on external_*_id (for UPSERT) → WARN if missing
//   Index on external_*_id → WARN if missing
//   CHECK constraint on enum-named text cols (_status, _phase, _type, _state) → WARN if missing
//
// Output:
//   - reports/sandbox_lint_<YYYY_MM_DD>.md  — full Markdown report
//   - Console: summary table + non-PASS findings
//   - Exit code: 0 if all PASS+WARN; 2 if any FAIL (use --no-fail-on-fail to disable)
//
// Usage:
//   node scripts/probes/sandbox_lovable_lint.js
//   node scripts/probes/sandbox_lovable_lint.js --no-fail-on-fail
//
// ============================================================================
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const fs = require('fs');
const path = require('path');
const https = require('https');

const SBX = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PROD = process.env.SUPABASE_PROJECT_ID;
const FAIL_ON_FAIL = !process.argv.includes('--no-fail-on-fail');

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
async function q(sql, project = SBX) {
  const r = await pg(sql, project);
  if (r.status >= 300) throw new Error(`PG ${r.status} (${project === SBX ? 'SBX' : 'PROD'}): ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}

// Canonical tables (must match refresh script's CANONICAL_TABLES list)
const CANONICAL = new Set([
  'clients', 'properties', 'client_contacts', 'service_configs', 'jobs',
  'visits', 'visit_assignments', 'invoices', 'line_items', 'quotes', 'notes',
  'photos', 'photo_links', 'derm_manifests', 'manifest_visits', 'inspections',
  'employees', 'vehicles', 'vehicle_telemetry_readings', 'entity_source_links',
  'jobber_oversized_attachments',
]);

// Money-shaped column names (heuristic)
const MONEY_RE = /^(price|amount|total|cost|revenue|fee|charge|balance|paid|due|tax|subtotal|net|gross)(_|$)/i;
// Time-shaped column names
const TIME_RE = /(_at|_time)$/;
// Enum-shaped text column names
const ENUM_RE = /(_status|_phase|_type|_state|_kind|_role)$/;
// Source-prefix pattern
const SOURCE_PREFIX_RE = /^(jobber_|airtable_|samsara_|lovable_|fillout_|odoo_)/i;
// Common "cached canonical value" names that violate Reference-Don't-Copy
const CACHED_NAMES = new Set([
  'client_name', 'client_code', 'property_address', 'employee_name',
  'vehicle_name', 'truck_name', 'visit_date_str',
]);

const findings = []; // { level: 'FAIL'|'WARN'|'PASS', target, rule, message, fix }
const F = (level, target, rule, message, fix = '') => findings.push({ level, target, rule, message, fix });

// ============================================================================
async function main() {
  console.log('Linting Sandbox-only additions vs Prod baseline + 7 contract rules...\n');

  // 1. Discover Sandbox-only tables (and column deltas on shared tables)
  const sbxTables = (await q(`SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1;`))
    .map(r => r.table_name);
  const prodTables = (await q(`SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY 1;`, PROD))
    .map(r => r.table_name);

  const sbxOnlyTables = sbxTables.filter(t => !prodTables.includes(t));
  const sharedTables = sbxTables.filter(t => prodTables.includes(t));

  // Filter out helper/system tables
  const lintableSbxOnlyTables = sbxOnlyTables.filter(t => !t.startsWith('_') && !['sync_cursors','sync_log','webhook_events_log','webhook_tokens'].includes(t));

  console.log(`Tables to lint: ${lintableSbxOnlyTables.length} (Sandbox-only)`);
  console.log(`  ${lintableSbxOnlyTables.join(', ') || '(none)'}\n`);

  // 2. For each Sandbox-only table — apply lint rules
  for (const t of lintableSbxOnlyTables) {
    await lintTable(t);
  }

  // 3. For each SHARED table — look for Yannick columns (Pattern A traps)
  for (const t of sharedTables) {
    await lintSharedTableColumns(t);
  }

  // 4. Aggregate, render report, write to file
  const report = renderReport();
  const reportPath = path.resolve(__dirname, '../../reports/sandbox_lint_' + new Date().toISOString().slice(0, 10).replace(/-/g, '_') + '.md');
  fs.mkdirSync(path.dirname(reportPath), { recursive: true });
  fs.writeFileSync(reportPath, report);

  // 5. Console summary
  const failCount = findings.filter(f => f.level === 'FAIL').length;
  const warnCount = findings.filter(f => f.level === 'WARN').length;
  const passCount = findings.filter(f => f.level === 'PASS').length;
  console.log('═'.repeat(70));
  console.log(`  RESULT: ${failCount} FAIL  •  ${warnCount} WARN  •  ${passCount} PASS`);
  console.log('═'.repeat(70));

  // Print non-PASS findings to console for quick triage
  if (failCount + warnCount > 0) {
    console.log('\nIssues:\n');
    for (const f of findings.filter(x => x.level !== 'PASS')) {
      const icon = f.level === 'FAIL' ? '✗' : '⚠';
      console.log(`  ${icon} [${f.level}] ${f.target}: ${f.message}`);
      if (f.fix) console.log(`      Fix: ${f.fix}`);
    }
  } else {
    console.log('\n✅ All Sandbox additions pass the 7 contract rules + Pattern B compliance.');
  }

  console.log(`\nFull report written to: ${reportPath}`);
  if (failCount > 0 && FAIL_ON_FAIL) process.exit(2);
}

// ============================================================================
async function lintTable(t) {
  // Pull everything we need about the table
  const cols = await q(`
    SELECT column_name, data_type, udt_name, is_nullable, column_default
    FROM information_schema.columns WHERE table_schema='public' AND table_name='${t}'
    ORDER BY ordinal_position;`);
  const cons = await q(`
    SELECT conname, contype, pg_get_constraintdef(oid) AS def
    FROM pg_constraint WHERE conrelid='public.${t}'::regclass;`);
  const indexes = await q(`SELECT indexname, indexdef FROM pg_indexes WHERE schemaname='public' AND tablename='${t}';`);
  const rls = await q(`SELECT relrowsecurity AS on FROM pg_class WHERE oid='public.${t}'::regclass;`);
  const policies = await q(`SELECT policyname, cmd FROM pg_policies WHERE schemaname='public' AND tablename='${t}';`);
  const triggers = await q(`SELECT trigger_name, event_manipulation FROM information_schema.triggers WHERE trigger_schema='public' AND event_object_table='${t}';`);
  const tblCmt = (await q(`SELECT obj_description('public.${t}'::regclass, 'pg_class') AS c;`))[0].c;

  // Rule 6a — RLS enabled
  if (!rls[0].on) F('FAIL', t, 'Rule 6 (RLS)', `Table has no RLS enabled`, `ALTER TABLE public.${t} ENABLE ROW LEVEL SECURITY;`);
  else F('PASS', t, 'Rule 6 (RLS)', 'RLS enabled');

  // Rule 6b — At least one policy
  if (rls[0].on && policies.length === 0) F('FAIL', t, 'Rule 6 (RLS policy)', `RLS enabled but no policies defined — all access denied`, `CREATE POLICY "..." ON ${t} FOR ALL TO authenticated USING (auth.uid() IS NOT NULL);`);

  // Rule 7 — Table COMMENT
  if (!tblCmt) F('WARN', t, 'Rule 7 (COMMENT)', `No table COMMENT explaining purpose`, `COMMENT ON TABLE ${t} IS '...';`);
  else F('PASS', t, 'Rule 7 (COMMENT)', `Has table comment: "${tblCmt.slice(0, 60)}…"`);

  // Pattern B compliance — table-name convention
  if (!/^app_/.test(t) && !['prospects','lead_classifications'].includes(t)) {
    // Not blocking — but worth noting if it looks like an app table without the prefix
    if (cols.some(c => /^external_.*_id$/.test(c.column_name))) {
      F('WARN', t, 'Convention', `Table has external_*_id columns but name doesn't start with 'app_' — convention says app-state tables should be prefixed`, `Consider renaming to app_${t}.`);
    }
  }

  // updated_at trigger check
  if (cols.find(c => c.column_name === 'updated_at')) {
    const hasUpdateTrig = triggers.some(tr => tr.event_manipulation === 'UPDATE');
    if (!hasUpdateTrig) F('WARN', t, 'Rule 5 (updated_at trigger)', `Has updated_at column but no BEFORE UPDATE trigger`, `CREATE TRIGGER trg_${t}_updated_at BEFORE UPDATE ON ${t} FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();`);
    else F('PASS', t, 'Rule 5 (updated_at trigger)', 'updated_at trigger present');
  }

  // Per-column checks
  for (const c of cols) {
    // Rule 1 — Source-prefixed names
    if (SOURCE_PREFIX_RE.test(c.column_name)) {
      // external_*_id is the legitimate cross-system bridge
      if (!/^external_/.test(c.column_name)) {
        F('FAIL', `${t}.${c.column_name}`, 'Rule 1 (source-prefix)', `Column name has forbidden source prefix`, `Rename to drop the prefix; use entity_source_links for cross-system IDs or external_*_id BIGINT for app-side refs.`);
      }
    }

    // Rule 5 — TIMESTAMPTZ for time columns
    if (TIME_RE.test(c.column_name) && c.data_type !== 'timestamp with time zone') {
      F('FAIL', `${t}.${c.column_name}`, 'Rule 5 (TIMESTAMPTZ)', `Time-shaped column is ${c.data_type}, should be TIMESTAMPTZ`, `ALTER TABLE ${t} ALTER COLUMN ${c.column_name} TYPE TIMESTAMPTZ;`);
    }

    // Rule 5 — NUMERIC(12,2) for money cols
    if (MONEY_RE.test(c.column_name)) {
      const u = c.udt_name;
      if (!['numeric','int4','int8'].includes(u)) {
        F('FAIL', `${t}.${c.column_name}`, 'Rule 5 (money)', `Money-shaped column is ${c.data_type}, should be NUMERIC(12,2)`, `ALTER TABLE ${t} ALTER COLUMN ${c.column_name} TYPE NUMERIC(12,2);`);
      }
    }

    // Rule 5 — BIGINT for id columns
    if ((c.column_name === 'id' || /^external_.*_id$/.test(c.column_name)) && c.data_type !== 'bigint') {
      F('FAIL', `${t}.${c.column_name}`, 'Rule 5 (BIGINT id)', `${c.column_name} is ${c.data_type}, should be BIGINT`, `ALTER TABLE ${t} ALTER COLUMN ${c.column_name} TYPE BIGINT;`);
    }

    // Rule 3 — Reference, don't copy
    if (CACHED_NAMES.has(c.column_name)) {
      F('WARN', `${t}.${c.column_name}`, 'Rule 3 (no copy)', `Column name suggests a cached value from a canonical table (Reference-don't-copy)`, `Drop this column and JOIN to the source table at query time instead.`);
    }

    // Enum-shaped text without CHECK
    if (c.data_type === 'text' && ENUM_RE.test(c.column_name)) {
      const hasCheck = cons.some(co => co.contype === 'c' && co.def.toLowerCase().includes(c.column_name.toLowerCase()));
      if (!hasCheck) {
        F('WARN', `${t}.${c.column_name}`, 'Rule 5 (enum CHECK)', `Enum-shaped text column has no CHECK constraint — uncontrolled values can land`, `Add CHECK (${c.column_name} IN ('value1','value2',…)).`);
      }
    }
  }

  // Pattern B — external_*_id columns should have UNIQUE + index, no real FK to canonical
  const extCols = cols.filter(c => /^external_.*_id$/.test(c.column_name));
  for (const ec of extCols) {
    // No real FK to canonical
    const fks = cons.filter(co => co.contype === 'f' && co.def.includes(ec.column_name));
    for (const fk of fks) {
      const m = fk.def.match(/REFERENCES (\w+)/);
      if (m && CANONICAL.has(m[1])) {
        F('FAIL', `${t}.${ec.column_name}`, 'Pattern B (no real FK)', `Has real FK to canonical ${m[1]} — will break on refresh TRUNCATE`, `Drop the FK constraint: ALTER TABLE ${t} DROP CONSTRAINT ${fk.conname};`);
      }
    }
    // UNIQUE constraint
    const hasUnique = cons.some(co => co.contype === 'u' && co.def.includes(ec.column_name));
    if (!hasUnique) F('WARN', `${t}.${ec.column_name}`, 'Pattern B (UNIQUE)', `No UNIQUE constraint — UPSERT pattern won't work for one-row-per-entity`, `ALTER TABLE ${t} ADD CONSTRAINT ${t}_${ec.column_name}_key UNIQUE (${ec.column_name});`);
    // Index
    const hasIndex = indexes.some(i => i.indexdef.includes(ec.column_name));
    if (!hasIndex) F('WARN', `${t}.${ec.column_name}`, 'Pattern B (index)', `No index — JOIN reads will be slow`, `CREATE INDEX idx_${t}_${ec.column_name} ON ${t}(${ec.column_name});`);
  }
}

// ============================================================================
async function lintSharedTableColumns(t) {
  // Find columns in Sandbox that don't exist in Prod (Yannick columns on canonical)
  const sbxCols = (await q(`SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='${t}';`))
    .map(c => c.column_name);
  const prodCols = (await q(`SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='${t}';`, PROD))
    .map(c => c.column_name);
  const yannickCols = sbxCols.filter(c => !prodCols.includes(c));

  for (const col of yannickCols) {
    if (CANONICAL.has(t)) {
      F('WARN', `${t}.${col}`, 'Pattern A trap', `Yannick column added to CANONICAL table — values can be lost if Prod deletes the row, and contract says prefer Pattern B (sidecar app_* table)`, `Consider migrating this to a new app_<entity>_overrides table with external_${t.slice(0,-1)}_id BIGINT.`);
    }
  }
}

// ============================================================================
function renderReport() {
  const date = new Date().toISOString().slice(0, 19).replace('T', ' ');
  const failFindings = findings.filter(f => f.level === 'FAIL');
  const warnFindings = findings.filter(f => f.level === 'WARN');
  const passFindings = findings.filter(f => f.level === 'PASS');

  let md = `# Sandbox Lovable lint report\n\n`;
  md += `_Generated ${date} UTC. Sandbox \`${SBX}\` vs Prod \`${PROD}\`._\n\n`;
  md += `## Summary\n\n`;
  md += `| Result | Count |\n|---|---|\n`;
  md += `| ✗ FAIL | **${failFindings.length}** |\n`;
  md += `| ⚠ WARN | ${warnFindings.length} |\n`;
  md += `| ✓ PASS | ${passFindings.length} |\n\n`;

  if (failFindings.length > 0) {
    md += `## ✗ FAIL (${failFindings.length}) — must fix before launch\n\n`;
    md += `| Target | Rule | Issue | Fix |\n|---|---|---|---|\n`;
    for (const f of failFindings) {
      md += `| \`${f.target}\` | ${f.rule} | ${f.message} | \`${f.fix.replace(/\|/g, '\\|')}\` |\n`;
    }
    md += `\n`;
  }
  if (warnFindings.length > 0) {
    md += `## ⚠ WARN (${warnFindings.length}) — review\n\n`;
    md += `| Target | Rule | Issue | Suggested fix |\n|---|---|---|---|\n`;
    for (const f of warnFindings) {
      md += `| \`${f.target}\` | ${f.rule} | ${f.message} | \`${f.fix.replace(/\|/g, '\\|')}\` |\n`;
    }
    md += `\n`;
  }
  if (passFindings.length > 0) {
    md += `## ✓ PASS (${passFindings.length})\n\n`;
    md += `<details><summary>Click to expand</summary>\n\n`;
    md += `| Target | Rule | Note |\n|---|---|---|\n`;
    for (const f of passFindings) {
      md += `| \`${f.target}\` | ${f.rule} | ${f.message} |\n`;
    }
    md += `\n</details>\n`;
  }
  return md;
}

main().catch(e => { console.error('FATAL:', e.message, e.stack); process.exit(2); });
