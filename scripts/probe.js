// ============================================================================
// probe.js — Full system health check
// ============================================================================
require('dotenv').config({ path: require('path').resolve(__dirname, '../.env') });
const https = require('https');

function query(sql) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com',
      path: '/v1/projects/' + process.env.SUPABASE_PROJECT_ID + '/database/query',
      method: 'POST',
      headers: { 'Authorization': 'Bearer ' + process.env.SUPABASE_PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }
    }, res => { let d = ''; res.on('data', c => d += c); res.on('end', () => {
      if (res.statusCode >= 300) reject(new Error('HTTP ' + res.statusCode + ': ' + d.slice(0, 300)));
      else { try { resolve(JSON.parse(d)); } catch(e) { reject(new Error('Bad JSON: ' + d.slice(0,200))); } }
    }); });
    req.on('error', reject); req.write(body); req.end();
  });
}

(async () => {
  // 1. SYNC CURSORS
  console.log('=== 1. SYNC CURSORS STATE ===');
  const cursors = await query("SELECT entity, last_synced_at, last_run_status, rows_pulled, last_error FROM sync_cursors ORDER BY entity");
  cursors.forEach(c => {
    const status = c.last_run_status === 'success' ? '✅' : '❌';
    const err = c.last_error ? ' | ERR: ' + c.last_error.substring(0, 60) : '';
    console.log('  ' + status + ' ' + c.entity.padEnd(14) + ' | pulled: ' + String(c.rows_pulled).padStart(5) + ' | cursor: ' + (c.last_synced_at || 'null').substring(0, 20) + err);
  });

  // 2. RAW TABLE COUNTS
  console.log('\n=== 2. RAW TABLE ROW COUNTS + PENDING POPULATE ===');
  const raw = await query(`
    SELECT 'clients' as entity, count(*) as total, count(*) filter (where needs_populate) as pending FROM raw.jobber_pull_clients
    UNION ALL SELECT 'properties', count(*), count(*) filter (where needs_populate) FROM raw.jobber_pull_properties
    UNION ALL SELECT 'jobs', count(*), count(*) filter (where needs_populate) FROM raw.jobber_pull_jobs
    UNION ALL SELECT 'visits', count(*), count(*) filter (where needs_populate) FROM raw.jobber_pull_visits
    UNION ALL SELECT 'invoices', count(*), count(*) filter (where needs_populate) FROM raw.jobber_pull_invoices
    UNION ALL SELECT 'quotes', count(*), count(*) filter (where needs_populate) FROM raw.jobber_pull_quotes
    UNION ALL SELECT 'users', count(*), count(*) filter (where needs_populate) FROM raw.jobber_pull_users
    UNION ALL SELECT 'line_items', count(*), count(*) filter (where needs_populate) FROM raw.jobber_pull_line_items
    ORDER BY entity
  `);
  raw.forEach(r => console.log('  raw.' + r.entity.padEnd(14) + ' | total: ' + String(r.total).padStart(5) + ' | pending: ' + String(r.pending).padStart(5)));

  // 3. PUBLIC TABLE COUNTS
  console.log('\n=== 3. PUBLIC TABLE ROW COUNTS ===');
  const pub = await query(`
    SELECT 'clients' as t, count(*) as n FROM clients
    UNION ALL SELECT 'properties', count(*) FROM properties
    UNION ALL SELECT 'jobs', count(*) FROM jobs
    UNION ALL SELECT 'visits', count(*) FROM visits
    UNION ALL SELECT 'invoices', count(*) FROM invoices
    UNION ALL SELECT 'quotes', count(*) FROM quotes
    UNION ALL SELECT 'employees', count(*) FROM employees
    UNION ALL SELECT 'vehicles', count(*) FROM vehicles
    UNION ALL SELECT 'service_configs', count(*) FROM service_configs
    UNION ALL SELECT 'derm_manifests', count(*) FROM derm_manifests
    UNION ALL SELECT 'manifest_visits', count(*) FROM manifest_visits
    UNION ALL SELECT 'visit_assignments', count(*) FROM visit_assignments
    UNION ALL SELECT 'inspections', count(*) FROM inspections
    UNION ALL SELECT 'expenses', count(*) FROM expenses
    UNION ALL SELECT 'line_items', count(*) FROM line_items
    UNION ALL SELECT 'routes', count(*) FROM routes
    UNION ALL SELECT 'receivables', count(*) FROM receivables
    UNION ALL SELECT 'leads', count(*) FROM leads
    UNION ALL SELECT 'source_map', count(*) FROM source_map
    UNION ALL SELECT 'sync_log', count(*) FROM sync_log
    ORDER BY t
  `);
  pub.forEach(r => console.log('  public.' + r.t.padEnd(20) + String(r.n).padStart(5) + ' rows'));

  // 4. JOBBER TOKEN STATUS
  console.log('\n=== 4. JOBBER TOKEN STATUS ===');
  const expires = process.env.JOBBER_TOKEN_EXPIRES_AT;
  const hasAccess = !!process.env.JOBBER_ACCESS_TOKEN;
  const hasRefresh = !!process.env.JOBBER_REFRESH_TOKEN;
  const expiresDate = expires ? new Date(expires) : null;
  const hoursLeft = expiresDate ? ((expiresDate - Date.now()) / 3600000).toFixed(1) : '?';
  console.log('  Access token: ' + (hasAccess ? '✅ present' : '❌ missing'));
  console.log('  Refresh token: ' + (hasRefresh ? '✅ present' : '❌ missing'));
  console.log('  Expires: ' + (expires || 'unknown') + ' (' + hoursLeft + 'h remaining)');

  // 5. SAMSARA API CHECK
  console.log('\n=== 5. SAMSARA API CHECK ===');
  console.log('  Token: ' + (process.env.SAMSARA_API_TOKEN ? '✅ present' : '❌ missing'));

  // 6. RAW vs PUBLIC COMPARISON
  console.log('\n=== 6. RAW vs PUBLIC COMPARISON ===');
  const entities = ['clients', 'properties', 'jobs', 'visits', 'invoices', 'quotes'];
  entities.forEach(e => {
    const rawCount = parseInt(raw.find(r => r.entity === e)?.total || 0);
    const pubCount = parseInt(pub.find(r => r.t === e)?.n || 0);
    const delta = rawCount - pubCount;
    let flag;
    if (delta > 0) flag = '🔄 raw has +' + delta + ' new';
    else if (delta === 0) flag = '✅ in sync';
    else flag = '⚠️ public has +' + Math.abs(delta) + ' more (AT historical?)';
    console.log('  ' + e.padEnd(14) + ' raw=' + String(rawCount).padStart(5) + '  public=' + String(pubCount).padStart(5) + '  ' + flag);
  });

  // 7. VIEW HEALTH CHECK
  console.log('\n=== 7. VIEW HEALTH CHECK ===');
  const views = ['client_services_flat', 'clients_due_service', 'visits_recent', 'manifest_detail', 'driver_inspection_status'];
  for (const v of views) {
    try {
      const r = await query('SELECT count(*) as n FROM ' + v);
      console.log('  ✅ ' + v.padEnd(28) + r[0].n + ' rows');
    } catch (e) {
      console.log('  ❌ ' + v.padEnd(28) + e.message.substring(0, 80));
    }
  }

  // 8. FK INTEGRITY SPOT CHECK
  console.log('\n=== 8. FK INTEGRITY SPOT CHECK ===');
  const fkChecks = await query(`
    SELECT 'visits->clients' as fk, count(*) as orphans FROM visits v WHERE v.client_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM clients c WHERE c.id = v.client_id)
    UNION ALL SELECT 'visits->jobs', count(*) FROM visits v WHERE v.job_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.id = v.job_id)
    UNION ALL SELECT 'invoices->clients', count(*) FROM invoices i WHERE i.client_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM clients c WHERE c.id = i.client_id)
    UNION ALL SELECT 'jobs->clients', count(*) FROM jobs j WHERE j.client_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM clients c WHERE c.id = j.client_id)
    UNION ALL SELECT 'properties->clients', count(*) FROM properties p WHERE p.client_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM clients c WHERE c.id = p.client_id)
    UNION ALL SELECT 'derm->clients', count(*) FROM derm_manifests d WHERE d.client_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM clients c WHERE c.id = d.client_id)
    ORDER BY fk
  `);
  fkChecks.forEach(f => {
    const status = parseInt(f.orphans) === 0 ? '✅' : '⚠️';
    console.log('  ' + status + ' ' + f.fk.padEnd(22) + f.orphans + ' orphans');
  });

  // 9. GPS ENRICHMENT STATUS
  console.log('\n=== 9. GPS ENRICHMENT STATUS ===');
  const gps = await query(`
    SELECT
      count(*) as total_visits,
      count(*) filter (where gps_confirmed = true) as gps_matched,
      count(*) filter (where vehicle_id is not null) as has_vehicle,
      count(*) filter (where actual_arrival_at is not null) as has_arrival
    FROM visits
  `);
  const g = gps[0];
  const pct = parseInt(g.total_visits) > 0 ? (parseInt(g.gps_matched) / parseInt(g.total_visits) * 100).toFixed(1) : 0;
  console.log('  Total visits: ' + g.total_visits);
  console.log('  GPS confirmed: ' + g.gps_matched + ' (' + pct + '%)');
  console.log('  Has vehicle_id: ' + g.has_vehicle);
  console.log('  Has actual_arrival: ' + g.has_arrival);

  // 10. SUPABASE PROJECT HEALTH
  console.log('\n=== 10. SUPABASE PROJECT HEALTH ===');
  console.log('  Project: wbasvhvvismukaqdnouk');
  console.log('  URL: ' + process.env.SUPABASE_URL);
  console.log('  PAT: ' + (process.env.SUPABASE_PAT ? '✅ present' : '❌ missing'));
  console.log('  Service Role Key: ' + (process.env.SUPABASE_SERVICE_ROLE_KEY ? '✅ present' : '❌ missing'));

  console.log('\n=== PROBE COMPLETE ===');
})().catch(e => console.error('PROBE ERROR:', e.message));
