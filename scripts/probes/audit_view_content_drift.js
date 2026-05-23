// Compares the deployed column list of each view against the column list
// declared in the LATEST migration file that defines it. Surfaces columns
// added/removed without a matching migration.
//
// This is the most useful drift heuristic — column-list diff catches the
// kind of drift that broke derm.manifest_health (yellow_ticket_number,
// has_broward_ticket_number, has_dade_white_number added ad-hoc).
//
// Read-only.
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  if (!r.ok) throw new Error(`SQL ${r.status} ${await r.text()}`);
  return r.json();
}

// Heuristic: extract column names from a CREATE VIEW block's SELECT.
// Looks for "name" / "expr AS name" / "func(...) AS name". Strip everything
// after FROM. Conservative — better to under-extract and fail gracefully.
function extractFileColumns(content, schema, view) {
  const re = new RegExp(
    `CREATE\\s+(?:OR\\s+REPLACE\\s+)?VIEW\\s+${schema}\\.${view}\\b[\\s\\S]*?AS\\s+([\\s\\S]*?)\\bFROM\\b`,
    'i'
  );
  const m = content.match(re);
  if (!m) return null;
  const selectBody = m[1];

  // Strip parenthesized subexpressions so we can split on commas at top level
  const stripped = stripParens(selectBody);
  // Strip line comments
  const cleaned = stripped.replace(/--[^\n]*/g, '');
  const parts = splitTopLevelCommas(cleaned);

  const cols = [];
  for (const raw of parts) {
    const part = raw.trim();
    if (!part) continue;
    // "X AS name" or last identifier
    const asMatch = part.match(/\bAS\s+([a-zA-Z_][\w]*)\s*$/i);
    if (asMatch) {
      cols.push(asMatch[1].toLowerCase());
      continue;
    }
    // "schema.col" or "col" — take last identifier
    const lastIdent = part.match(/([a-zA-Z_][\w]*)\s*$/);
    if (lastIdent) cols.push(lastIdent[1].toLowerCase());
  }
  return cols;
}

function stripParens(s) {
  // Replace balanced parens with placeholder so we can split commas safely.
  let depth = 0, out = '';
  for (const ch of s) {
    if (ch === '(') { depth++; out += '_'; continue; }
    if (ch === ')') { depth--; out += '_'; continue; }
    out += depth > 0 ? '_' : ch;
  }
  return out;
}

function splitTopLevelCommas(s) {
  // After stripParens, all commas are top-level
  return s.split(',');
}

(async () => {
  // Build view → latest migration file map
  const views = await sql(`
    SELECT schemaname AS schema, viewname AS name
    FROM pg_catalog.pg_views
    WHERE schemaname IN ('derm', 'customer', 'ops')
    ORDER BY schemaname, viewname;
  `);

  const dirs = [
    path.resolve(__dirname, '../../docs/migrations'),
    path.resolve(__dirname, '../../scripts/ops_views'),
    path.resolve(__dirname, '../../scripts/migrations'),
  ];
  const fileMap = {};
  for (const dir of dirs) {
    if (!fs.existsSync(dir)) continue;
    for (const f of fs.readdirSync(dir).filter(x => x.endsWith('.sql')).sort()) {
      const full = path.join(dir, f);
      const content = fs.readFileSync(full, 'utf8');
      for (const v of views) {
        const re = new RegExp(`CREATE\\s+(?:OR\\s+REPLACE\\s+)?VIEW\\s+${v.schema}\\.${v.name}\\b`, 'i');
        if (re.test(content)) {
          const key = `${v.schema}.${v.name}`;
          (fileMap[key] = fileMap[key] || []).push({ file: f, dir: path.basename(dir), full });
        }
      }
    }
  }

  console.log('=== Column-list drift audit ===\n');
  let drifted = 0, ok = 0, missing = 0;

  for (const v of views) {
    const key = `${v.schema}.${v.name}`;
    const list = fileMap[key];
    if (!list || !list.length) {
      console.log(`⚠️  ${key.padEnd(38)} NO migration file found`);
      missing++;
      continue;
    }
    const latest = list[list.length - 1];
    const content = fs.readFileSync(latest.full, 'utf8');
    const fileCols = extractFileColumns(content, v.schema, v.name);
    if (!fileCols) {
      console.log(`⚠️  ${key.padEnd(38)} couldn't parse columns from ${latest.file}`);
      missing++;
      continue;
    }

    // Get deployed columns
    const dbCols = (await sql(`
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = '${v.schema}' AND table_name = '${v.name}'
      ORDER BY ordinal_position;
    `)).map(r => r.column_name.toLowerCase());

    const fileSet = new Set(fileCols);
    const dbSet = new Set(dbCols);
    const onlyInFile = fileCols.filter(c => !dbSet.has(c));
    const onlyInDb = dbCols.filter(c => !fileSet.has(c));

    if (onlyInFile.length === 0 && onlyInDb.length === 0) {
      ok++;
      // Don't log OK rows by default
    } else {
      drifted++;
      console.log(`\n❌ ${key}`);
      console.log(`   latest file: ${latest.dir}/${latest.file}`);
      console.log(`   deployed columns: ${dbCols.length}`);
      console.log(`   file columns:     ${fileCols.length}`);
      if (onlyInFile.length) console.log(`   In file, not deployed: ${onlyInFile.join(', ')}`);
      if (onlyInDb.length)   console.log(`   In deployed, not file: ${onlyInDb.join(', ')}`);
    }
  }

  console.log('\n' + '='.repeat(80));
  console.log(`Summary: ${ok} clean / ${drifted} drifted / ${missing} unparseable`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
