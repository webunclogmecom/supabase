#!/usr/bin/env node
// fix_security_resume.js — resume from where fix_security.js stopped (line_items onwards)
require('dotenv').config({ path: require('path').resolve(__dirname, '..', '.env') });
const https = require('https');

function q(sql) {
  return new Promise((res, rej) => {
    const b = JSON.stringify({ query: sql });
    const r = https.request({
      hostname: 'api.supabase.com',
      path: '/v1/projects/' + process.env.SUPABASE_PROJECT_ID + '/database/query',
      method: 'POST',
      headers: {
        'Authorization': 'Bearer ' + process.env.SUPABASE_PAT,
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(b),
      },
    }, resp => {
      let d = '';
      resp.on('data', c => d += c);
      resp.on('end', () => {
        if (resp.statusCode >= 300) rej(new Error('HTTP ' + resp.statusCode + ': ' + d.slice(0, 500)));
        else res(JSON.parse(d));
      });
    });
    r.on('error', rej);
    r.write(b);
    r.end();
  });
}

async function retry(sql, label, attempts = 3) {
  for (let i = 0; i < attempts; i++) {
    try {
      await q(sql);
      console.log('  OK ' + label);
      return;
    } catch (e) {
      if (i < attempts - 1) {
        console.log('  RETRY ' + label + ' (' + e.message.slice(0, 60) + ')');
        await new Promise(r => setTimeout(r, 2000));
      } else {
        console.log('  FAIL ' + label + ': ' + e.message.slice(0, 100));
      }
    }
  }
}

(async () => {
  // Remaining authenticated read policies
  const authPolicyTables = [
    'line_items', 'visit_assignments', 'expenses', 'derm_manifests',
    'manifest_visits', 'routes', 'receivables', 'leads',
    'source_map', 'sync_log', 'sync_cursors',
  ];

  console.log('=== FIX 4 (resume): Missing authenticated RLS policies ===');
  for (const t of authPolicyTables) {
    const p = 'Allow authenticated read on ' + t;
    await retry('DROP POLICY IF EXISTS "' + p + '" ON public.' + t, 'drop policy ' + t);
    await retry('CREATE POLICY "' + p + '" ON public.' + t + ' FOR SELECT TO authenticated USING (true)', 'authenticated SELECT: ' + t);
  }

  // Anon read policies for remaining business tables
  const anonPolicyTables = [
    'line_items', 'visit_assignments', 'expenses', 'derm_manifests',
    'manifest_visits', 'routes', 'receivables', 'leads',
  ];
  console.log('\n=== FIX 4 (resume): Missing anon RLS policies ===');
  for (const t of anonPolicyTables) {
    const p = 'Allow anon read on ' + t;
    await retry('DROP POLICY IF EXISTS "' + p + '" ON public.' + t, 'drop policy ' + t);
    await retry('CREATE POLICY "' + p + '" ON public.' + t + ' FOR SELECT TO anon USING (true)', 'anon SELECT: ' + t);
  }

  // service_role write policies on ALL tables
  const allTables = [
    'clients', 'employees', 'vehicles', 'properties', 'service_configs',
    'quotes', 'jobs', 'invoices', 'line_items', 'visits', 'visit_assignments',
    'inspections', 'expenses', 'derm_manifests', 'manifest_visits', 'routes',
    'receivables', 'leads', 'source_map', 'sync_log', 'sync_cursors',
  ];
  console.log('\n=== FIX 4 (resume): service_role full access policies ===');
  for (const t of allTables) {
    const p = 'Allow service_role full access on ' + t;
    await retry('DROP POLICY IF EXISTS "' + p + '" ON public.' + t, 'drop sr policy ' + t);
    await retry('CREATE POLICY "' + p + '" ON public.' + t + ' FOR ALL TO service_role USING (true) WITH CHECK (true)', 'service_role ALL: ' + t);
  }

  // FIX 5: sync_cursors RLS
  console.log('\n=== FIX 5: Enable RLS on sync_cursors ===');
  await retry('ALTER TABLE public.sync_cursors ENABLE ROW LEVEL SECURITY', 'enable RLS');
  await retry('ALTER TABLE public.sync_cursors FORCE ROW LEVEL SECURITY', 'force RLS');

  // FIX 6: Lock raw schema
  console.log('\n=== FIX 6: Lock raw schema ===');
  await retry('REVOKE ALL ON SCHEMA raw FROM anon', 'revoke anon schema');
  await retry('REVOKE ALL ON SCHEMA raw FROM authenticated', 'revoke auth schema');
  await retry('REVOKE ALL ON ALL TABLES IN SCHEMA raw FROM anon', 'revoke anon tables');
  await retry('REVOKE ALL ON ALL TABLES IN SCHEMA raw FROM authenticated', 'revoke auth tables');

  // FIX 7: service_role full access
  console.log('\n=== FIX 7: service_role full access ===');
  await retry('GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role', 'public grant');
  await retry('GRANT ALL ON ALL TABLES IN SCHEMA raw TO service_role', 'raw grant');
  await retry('GRANT USAGE ON SCHEMA raw TO service_role', 'raw usage');

  console.log('\n=== ALL REMAINING FIXES APPLIED ===');
})();
