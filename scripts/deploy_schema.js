/**
 * Deploy schema.sql to new Supabase project via Management API
 * Splits SQL into individual statements and executes sequentially
 */

require('dotenv').config({ path: require('path').join(__dirname, '..', '.env') });

const PAT = process.env.SUPABASE_PAT;
const PROJECT_ID = process.env.SUPABASE_PROJECT_ID || 'wbasvhvvismukaqdnouk';
const API_URL = `https://api.supabase.com/v1/projects/${PROJECT_ID}/database/query`;

const fs = require('fs');
const path = require('path');

async function runSQL(sql, label) {
  const resp = await fetch(API_URL, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${PAT}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ query: sql })
  });

  const text = await resp.text();
  if (!resp.ok) {
    console.error(`FAIL [${label}]: ${resp.status} ${text}`);
    return false;
  }

  // Check for SQL errors in response
  try {
    const data = JSON.parse(text);
    if (data.message && data.message.includes('ERROR')) {
      console.error(`SQL ERROR [${label}]: ${data.message}`);
      return false;
    }
  } catch (e) {
    // Response might not be JSON for DDL
  }

  console.log(`OK [${label}]`);
  return true;
}

async function deploy() {
  const schemaPath = path.join(__dirname, 'schema.sql');
  const rawSQL = fs.readFileSync(schemaPath, 'utf8');

  // Split into logical blocks by the section headers
  // Each section starts with "-- ====..."
  const sections = [];
  let current = '';
  let currentLabel = 'preamble';

  for (const line of rawSQL.split('\n')) {
    if (line.startsWith('-- =====') && current.trim()) {
      sections.push({ label: currentLabel, sql: current.trim() });
      current = '';
    }

    // Extract label from comment lines like "-- 1. clients — WHO WE SERVE"
    const labelMatch = line.match(/^-- \d+\.\s+(.+)/);
    if (labelMatch) {
      currentLabel = labelMatch[1].split('—')[0].trim();
    }

    current += line + '\n';
  }
  if (current.trim()) {
    sections.push({ label: currentLabel, sql: current.trim() });
  }

  // Further split each section into individual statements
  // This handles CREATE TABLE, CREATE INDEX, COMMENT ON, DO $$ blocks
  const statements = [];

  for (const section of sections) {
    const sql = section.sql;

    // Skip pure comment sections
    const withoutComments = sql.replace(/--[^\n]*/g, '').trim();
    if (!withoutComments) continue;

    // Split on semicolons, but respect $$ blocks
    let inDollarBlock = false;
    let stmt = '';
    let stmtIdx = 0;

    for (let i = 0; i < sql.length; i++) {
      // Track $$ blocks
      if (sql[i] === '$' && sql[i + 1] === '$') {
        inDollarBlock = !inDollarBlock;
        stmt += '$$';
        i++; // skip second $
        continue;
      }

      if (sql[i] === ';' && !inDollarBlock) {
        stmt += ';';
        const clean = stmt.replace(/--[^\n]*/g, '').trim();
        if (clean && clean !== ';') {
          statements.push({
            label: `${section.label} [${stmtIdx}]`,
            sql: stmt.trim()
          });
          stmtIdx++;
        }
        stmt = '';
      } else {
        stmt += sql[i];
      }
    }
  }

  console.log(`Deploying ${statements.length} statements to project ${PROJECT_ID}...\n`);

  let success = 0;
  let fail = 0;

  for (const { label, sql } of statements) {
    // Skip pure comments
    const clean = sql.replace(/--[^\n]*/g, '').trim();
    if (!clean || clean === ';') continue;

    const ok = await runSQL(sql, label);
    if (ok) success++;
    else fail++;

    // Small delay to avoid rate limiting
    await new Promise(r => setTimeout(r, 200));
  }

  console.log(`\nDone: ${success} succeeded, ${fail} failed out of ${success + fail} statements.`);
}

deploy().catch(err => {
  console.error('Deploy failed:', err);
  process.exit(1);
});
