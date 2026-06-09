// 28_apply_grants_via_mgmt_api.mjs
// Apply the HR sandbox recovery migration (grants + schema reload) via
// the Supabase Management API SQL endpoint. Idempotent.

import 'dotenv/config';
import { readFile } from 'node:fs/promises';

const PAT = process.env.SUPABASE_PAT;
const FP = process.env.FIELD_PORTAL_SUPABASE_PROJECT_ID;

const sql = await readFile(
  'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase/docs/migrations/2026-05-26_hr_sandbox_recovery.sql',
  'utf8'
);

console.log(`Applying ${sql.length} chars of SQL to ${FP}...`);

const r = await fetch(`https://api.supabase.com/v1/projects/${FP}/database/query`, {
  method: 'POST',
  headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
  body: JSON.stringify({ query: sql }),
});

const body = await r.text();
console.log(`HTTP ${r.status}`);
console.log(body.slice(0, 600));
