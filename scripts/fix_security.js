#!/usr/bin/env node
// fix_security.js — comprehensive security hardening for Unclogme Supabase
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

(async () => {
  // ================================================================
  // FIX 1: Set all views to SECURITY INVOKER
  // ================================================================
  console.log('=== FIX 1: Views -> security_invoker=true ===');
  const views = ['client_services_flat', 'clients_due_service', 'driver_inspection_status', 'manifest_detail', 'visits_recent'];
  for (const v of views) {
    await q('ALTER VIEW public.' + v + ' SET (security_invoker = true)');
    console.log('  OK ' + v);
  }

  // ================================================================
  // FIX 2: Revoke ALL from anon on all tables, grant SELECT only
  // ================================================================
  console.log('\n=== FIX 2: Revoke anon write access ===');
  const allTables = [
    'clients', 'employees', 'vehicles', 'properties', 'service_configs',
    'quotes', 'jobs', 'invoices', 'line_items', 'visits', 'visit_assignments',
    'inspections', 'expenses', 'derm_manifests', 'manifest_visits', 'routes',
    'receivables', 'leads', 'source_map', 'sync_log', 'sync_cursors',
  ];

  for (const t of allTables) {
    await q('REVOKE ALL ON public.' + t + ' FROM anon');
  }
  console.log('  OK Revoked ALL from anon on ' + allTables.length + ' tables');

  // anon can SELECT business tables (for Lovable frontend)
  const anonReadable = [
    'clients', 'employees', 'vehicles', 'properties', 'service_configs',
    'jobs', 'visits', 'invoices', 'quotes', 'line_items',
    'inspections', 'expenses', 'derm_manifests', 'manifest_visits', 'routes',
    'receivables', 'leads', 'visit_assignments',
  ];
  for (const t of anonReadable) {
    await q('GRANT SELECT ON public.' + t + ' TO anon');
  }
  console.log('  OK Granted SELECT to anon on ' + anonReadable.length + ' tables');
  console.log('  OK source_map, sync_log, sync_cursors: NO anon access');

  // Views: anon SELECT only
  for (const v of views) {
    await q('REVOKE ALL ON public.' + v + ' FROM anon');
    await q('GRANT SELECT ON public.' + v + ' TO anon');
  }
  console.log('  OK Views: anon SELECT only');

  // ================================================================
  // FIX 3: Restrict authenticated to SELECT only
  // ================================================================
  console.log('\n=== FIX 3: Restrict authenticated to SELECT ===');
  for (const t of allTables) {
    await q('REVOKE ALL ON public.' + t + ' FROM authenticated');
  }
  // Grant SELECT on business tables
  for (const t of anonReadable) {
    await q('GRANT SELECT ON public.' + t + ' TO authenticated');
  }
  // No access to sync/operational tables for authenticated
  console.log('  OK authenticated: SELECT on business tables, nothing on sync tables');

  for (const v of views) {
    await q('REVOKE ALL ON public.' + v + ' FROM authenticated');
    await q('GRANT SELECT ON public.' + v + ' TO authenticated');
  }
  console.log('  OK Views: authenticated SELECT only');

  // ================================================================
  // FIX 4: Add RLS policies to tables that are missing them
  // ================================================================
  console.log('\n=== FIX 4: Add missing RLS policies ===');

  // Tables that already have policies: clients, employees, inspections, vehicles, visits
  const needPolicies = [
    'properties', 'service_configs', 'quotes', 'jobs', 'invoices', 'line_items',
    'visit_assignments', 'expenses', 'derm_manifests', 'manifest_visits', 'routes',
    'receivables', 'leads', 'source_map', 'sync_log', 'sync_cursors',
  ];

  for (const t of needPolicies) {
    // Authenticated read policy
    const authPolicy = 'Allow authenticated read on ' + t;
    try { await q('DROP POLICY IF EXISTS "' + authPolicy + '" ON public.' + t); } catch (e) { /* ignore */ }
    await q('CREATE POLICY "' + authPolicy + '" ON public.' + t + ' FOR SELECT TO authenticated USING (true)');
    console.log('  OK authenticated SELECT: ' + t);
  }

  // Anon read policies for business tables only (not sync tables)
  const anonPolicyTables = [
    'properties', 'service_configs', 'quotes', 'jobs', 'invoices', 'line_items',
    'visit_assignments', 'expenses', 'derm_manifests', 'manifest_visits', 'routes',
    'receivables', 'leads',
  ];
  for (const t of anonPolicyTables) {
    const anonPolicy = 'Allow anon read on ' + t;
    try { await q('DROP POLICY IF EXISTS "' + anonPolicy + '" ON public.' + t); } catch (e) { /* ignore */ }
    await q('CREATE POLICY "' + anonPolicy + '" ON public.' + t + ' FOR SELECT TO anon USING (true)');
    console.log('  OK anon SELECT: ' + t);
  }

  // service_role write policies on all tables (for populate/sync scripts)
  for (const t of allTables) {
    const srPolicy = 'Allow service_role full access on ' + t;
    try { await q('DROP POLICY IF EXISTS "' + srPolicy + '" ON public.' + t); } catch (e) { /* ignore */ }
    await q('CREATE POLICY "' + srPolicy + '" ON public.' + t + ' FOR ALL TO service_role USING (true) WITH CHECK (true)');
    console.log('  OK service_role ALL: ' + t);
  }

  // ================================================================
  // FIX 5: Enable RLS on sync_cursors (was disabled)
  // ================================================================
  console.log('\n=== FIX 5: Enable RLS on sync_cursors ===');
  await q('ALTER TABLE public.sync_cursors ENABLE ROW LEVEL SECURITY');
  await q('ALTER TABLE public.sync_cursors FORCE ROW LEVEL SECURITY');
  console.log('  OK sync_cursors RLS enabled + forced');

  // ================================================================
  // FIX 6: Lock down raw schema
  // ================================================================
  console.log('\n=== FIX 6: Lock raw schema ===');
  await q('REVOKE ALL ON SCHEMA raw FROM anon');
  await q('REVOKE ALL ON SCHEMA raw FROM authenticated');
  await q('REVOKE ALL ON ALL TABLES IN SCHEMA raw FROM anon');
  await q('REVOKE ALL ON ALL TABLES IN SCHEMA raw FROM authenticated');
  console.log('  OK raw schema: no anon/authenticated access');

  // ================================================================
  // FIX 7: Ensure service_role keeps full access
  // ================================================================
  console.log('\n=== FIX 7: Verify service_role access ===');
  await q('GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role');
  await q('GRANT ALL ON ALL TABLES IN SCHEMA raw TO service_role');
  await q('GRANT USAGE ON SCHEMA raw TO service_role');
  console.log('  OK service_role: full access preserved');

  console.log('\n=== ALL SECURITY FIXES APPLIED ===');
})();
