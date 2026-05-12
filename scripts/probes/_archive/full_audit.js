// Full end-of-day audit covering local environment + web (GitHub + Supabase
// Production + Supabase Sandbox + Edge Functions + cron health). Runs every
// check in one shot.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const PROD = process.env.SUPABASE_PROJECT_ID;
const SBX  = process.env.SANDBOX_SUPABASE_PROJECT_ID;
const PAT  = process.env.SUPABASE_PAT;

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d, headers: r.headers }));
    });
    req.on('error', rej);
    req.setTimeout(15000, () => req.destroy(new Error('timeout')));
    if (body) req.write(body);
    req.end();
  });
}

async function pg(projectId, sql) {
  const body = JSON.stringify({ query: sql });
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${projectId}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) throw new Error(`DB ${projectId} ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body);
}

async function mgmtGet(path) {
  const r = await http({
    hostname: 'api.supabase.com',
    path,
    method: 'GET',
    headers: { Authorization: `Bearer ${PAT}` },
  });
  return r.status === 200 ? JSON.parse(r.body) : null;
}

const section = (title) => console.log(`\n${'═'.repeat(70)}\n  ${title}\n${'═'.repeat(70)}`);
const sub = (title) => console.log(`\n──── ${title} ────`);

(async () => {
  const startMs = Date.now();
  console.log(`Audit started: ${new Date().toISOString()}\n`);

  // ============================================================
  section('1. LOCAL ENVIRONMENT');
  // ============================================================
  sub('1.1 .env file');
  const envText = fs.readFileSync(path.resolve(__dirname, '../../.env'), 'utf8');
  const envVars = envText.split('\n').filter(l => l.match(/^[A-Z]/)).map(l => l.split('=')[0]);
  const expected = [
    'SAMSARA_API_TOKEN','SUPABASE_URL','SUPABASE_PROJECT_ID','SUPABASE_SERVICE_ROLE_KEY',
    'SUPABASE_PAT','JOBBER_CLIENT_ID','JOBBER_CLIENT_SECRET','JOBBER_REDIRECT_URI',
    'JOBBER_ACCESS_TOKEN','JOBBER_REFRESH_TOKEN','JOBBER_TOKEN_EXPIRES_AT',
    'AIRTABLE_API_KEY','AIRTABLE_BASE_ID','SAMSARA_WEBHOOK_SECRETS','AIRTABLE_WEBHOOK_TOKEN',
    'SANDBOX_SUPABASE_URL','SANDBOX_SUPABASE_PROJECT_ID','SANDBOX_SUPABASE_ANON_KEY',
    'SANDBOX_SUPABASE_SERVICE_ROLE_KEY','PROD_DB_URL','SANDBOX_DB_URL'
  ];
  const missing = expected.filter(v => !envVars.includes(v));
  const extra = envVars.filter(v => !expected.includes(v));
  console.log(`  ${envVars.length} keys present`);
  console.log(`  Missing: ${missing.length === 0 ? '✓ none' : missing.join(', ')}`);
  console.log(`  Unexpected: ${extra.length === 0 ? '✓ none' : extra.join(', ')}`);
  console.log(`  PROD_DB_URL has placeholder? ${process.env.PROD_DB_URL?.includes('<') ? '✗ YES' : '✓ no'}`);
  console.log(`  SANDBOX_DB_URL has placeholder? ${process.env.SANDBOX_DB_URL?.includes('<') ? '✗ YES' : '✓ no'}`);

  sub('1.2 Git state');
  const gitStatus = execSync('git status --porcelain', { cwd: path.resolve(__dirname, '../..') }).toString().trim();
  console.log(`  Working tree: ${gitStatus === '' ? '✓ clean' : '✗ ' + gitStatus.split('\n').length + ' uncommitted file(s)'}`);
  const headSha = execSync('git rev-parse --short HEAD', { cwd: path.resolve(__dirname, '../..') }).toString().trim();
  const remoteSha = execSync('git rev-parse --short origin/main', { cwd: path.resolve(__dirname, '../..') }).toString().trim();
  console.log(`  HEAD vs origin/main: ${headSha === remoteSha ? `✓ both at ${headSha}` : `✗ HEAD=${headSha} remote=${remoteSha}`}`);
  const lastCommit = execSync('git log -1 --pretty="%h %s"', { cwd: path.resolve(__dirname, '../..') }).toString().trim();
  console.log(`  Last commit: ${lastCommit}`);

  sub('1.3 Critical files present + tracked');
  const criticalFiles = [
    '.github/workflows/sandbox-refresh.yml',
    '.github/workflows/jobber-poll.yml',
    '.github/workflows/samsara-poll.yml',
    '.github/workflows/daily-cleanup.yml',
    'scripts/sync/sandbox_refresh.sh',
    'scripts/migrate/airtable_inspection_attachments.js',
    'scripts/migrations/client_cleanup_2026_04_30.sql',
    'scripts/migrations/rls_parity_with_sandbox_2026_04_30.sql',
    'supabase/functions/webhook-jobber/index.ts',
    'supabase/functions/webhook-airtable/index.ts',
  ];
  const tracked = execSync('git ls-files', { cwd: path.resolve(__dirname, '../..') }).toString();
  for (const f of criticalFiles) {
    const onDisk = fs.existsSync(path.resolve(__dirname, '../..', f));
    const inGit = tracked.includes(f);
    console.log(`  ${onDisk && inGit ? '✓' : '✗'} ${f}`);
  }

  sub('1.4 Edge function source has today\'s fixes');
  const wjSrc = fs.readFileSync(path.resolve(__dirname, '../../supabase/functions/webhook-jobber/index.ts'), 'utf8');
  const waSrc = fs.readFileSync(path.resolve(__dirname, '../../supabase/functions/webhook-airtable/index.ts'), 'utf8');
  console.log(`  webhook-jobber: visit_status canonicalization → ${wjSrc.includes("'completed'") && wjSrc.includes("'canceled'") && wjSrc.includes("'scheduled'") ? '✓' : '✗'}`);
  console.log(`  webhook-jobber: NNN-XX prefix parsing       → ${wjSrc.includes('parsedCode') ? '✓' : '✗'}`);
  console.log(`  webhook-jobber: handleVisitDestroy uses canceled → ${wjSrc.includes("'canceled'") ? '✓' : '✗'}`);
  console.log(`  webhook-airtable: manholes sync             → ${waSrc.includes('manhole') ? '✓' : '✗'}`);

  // ============================================================
  section('2. GITHUB STATE');
  // ============================================================
  sub('2.1 Workflows on GitHub');
  try {
    const workflows = execSync('gh workflow list --limit 20', { cwd: path.resolve(__dirname, '../..') }).toString().trim();
    const lines = workflows.split('\n');
    for (const line of lines) {
      const [name, state] = line.split('\t');
      console.log(`  ${state === 'active' ? '✓' : '✗'} ${name} (${state})`);
    }
  } catch (e) { console.log(`  ✗ gh CLI failed: ${e.message.slice(0, 80)}`); }

  sub('2.2 Last run of each workflow');
  try {
    const runs = JSON.parse(execSync('gh run list --limit 8 --json databaseId,name,conclusion,status,createdAt,workflowName',
      { cwd: path.resolve(__dirname, '../..') }).toString());
    const seen = new Set();
    for (const r of runs) {
      if (seen.has(r.workflowName)) continue;
      seen.add(r.workflowName);
      const ok = r.conclusion === 'success' ? '✓' : (r.status === 'in_progress' ? '⋯' : '✗');
      console.log(`  ${ok} ${r.workflowName.padEnd(50)} ${r.conclusion || r.status} (${r.createdAt})`);
    }
  } catch (e) { console.log(`  ✗ ${e.message.slice(0, 100)}`); }

  // ============================================================
  section('3. PRODUCTION SUPABASE');
  // ============================================================
  sub('3.1 Edge function deployment');
  const edgeFns = await mgmtGet(`/v1/projects/${PROD}/functions`);
  if (edgeFns) {
    for (const fn of edgeFns) {
      const ago = Math.round((Date.now() - new Date(fn.updated_at).getTime()) / 60000);
      const recent = ago < 60 * 6 ? '✓' : '⚠';
      console.log(`  ${recent} ${fn.slug.padEnd(20)} v${fn.version} updated ${ago} min ago`);
    }
    console.log('  → ⚠ means not redeployed in >6h (today\'s webhook fixes may not be live)');
  } else {
    console.log('  ✗ could not list functions');
  }

  sub('3.2 Schema fingerprint');
  const schema = await pg(PROD, `
    SELECT 'manhole_count_col' AS check, EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='properties' AND column_name='grease_trap_manhole_count') AS ok
    UNION ALL SELECT 'gps_columns', EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='vehicle_telemetry_readings' AND column_name='latitude')
    UNION ALL SELECT 'no_dormant_routes', NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='routes')
    UNION ALL SELECT 'no_dormant_expenses', NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='expenses')
    UNION ALL SELECT 'no_dormant_leads', NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='leads');
  `);
  for (const s of schema) console.log(`  ${s.ok ? '✓' : '✗'} ${s.check}`);

  sub('3.3 RLS policies on once-empty tables');
  const policies = await pg(PROD, `
    SELECT c.relname AS tbl, COUNT(p.policyname) AS n
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    LEFT JOIN pg_policies p ON p.schemaname='public' AND p.tablename=c.relname
    WHERE n.nspname='public' AND c.relname IN ('photos','photo_links','notes','vehicle_telemetry_readings','jobber_oversized_attachments','webhook_events_log','webhook_tokens','employees')
    GROUP BY c.relname ORDER BY c.relname;
  `);
  for (const p of policies) console.log(`  ${p.n > 0 ? '✓' : '✗'} ${p.tbl.padEnd(30)} ${p.n} polic${p.n === 1 ? 'y' : 'ies'}`);

  sub('3.4 Data row counts');
  const prodCounts = await pg(PROD, `
    SELECT 'clients' AS t, COUNT(*)::bigint AS n FROM clients
    UNION ALL SELECT 'visits', COUNT(*) FROM visits
    UNION ALL SELECT 'photos', COUNT(*) FROM photos
    UNION ALL SELECT 'photo_links', COUNT(*) FROM photo_links
    UNION ALL SELECT 'inspections', COUNT(*) FROM inspections
    UNION ALL SELECT 'derm_manifests', COUNT(*) FROM derm_manifests
    UNION ALL SELECT 'invoices', COUNT(*) FROM invoices;
  `);
  for (const r of prodCounts) console.log(`  ${r.t.padEnd(20)} ${r.n}`);

  sub('3.5 Photo coverage by entity_type');
  const photoBreakdown = await pg(PROD, `
    SELECT entity_type, COUNT(*) AS n FROM photo_links GROUP BY entity_type ORDER BY entity_type;
  `);
  for (const r of photoBreakdown) console.log(`  ${r.entity_type.padEnd(20)} ${r.n}`);

  sub('3.6 visit_status distribution');
  const visitStatus = await pg(PROD, `SELECT visit_status, COUNT(*) AS n FROM visits GROUP BY visit_status ORDER BY n DESC;`);
  const expectedStatuses = new Set(['scheduled','completed','canceled']);
  for (const r of visitStatus) {
    const ok = expectedStatuses.has(r.visit_status) ? '✓' : '⚠';
    console.log(`  ${ok} ${(r.visit_status||'(NULL)').padEnd(20)} ${r.n}`);
  }

  sub('3.7 Storage bucket');
  const buckets = await mgmtGet(`/v1/projects/${PROD}/storage/buckets`);
  if (buckets) {
    for (const b of buckets) console.log(`  ${b.name.padEnd(25)} public=${b.public}`);
  }
  // Spot-check one URL
  const sampleHead = await new Promise(res => {
    https.request({
      hostname: 'wbasvhvvismukaqdnouk.supabase.co',
      path: '/storage/v1/object/public/GT%20-%20Visits%20Images/airtable/inspection/161/back_attPYs8ULcipdMRwf.jpg',
      method: 'HEAD',
    }, r => res(r.statusCode)).on('error', () => res(0)).end();
  });
  console.log(`  ${sampleHead === 200 ? '✓' : '✗'} sample inspection photo HEAD: HTTP ${sampleHead}`);

  sub('3.8 Cron sync_cursors freshness');
  const cursors = await pg(PROD, `
    SELECT entity, last_run_finished, last_run_status,
           ROUND(EXTRACT(epoch FROM (now() - last_run_finished))/60)::int AS min_ago
    FROM sync_cursors ORDER BY entity;
  `);
  for (const c of cursors) {
    const recent = c.min_ago != null && c.min_ago < 30 ? '✓' : '⚠';
    console.log(`  ${recent} ${c.entity.padEnd(20)} ${(c.last_run_status||'').padEnd(10)} ${c.min_ago} min ago`);
  }

  // ============================================================
  section('4. SANDBOX SUPABASE');
  // ============================================================
  sub('4.1 Schema parity with Production');
  const sbxSchema = await pg(SBX, `
    SELECT 'manhole_count_col' AS check, EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='properties' AND column_name='grease_trap_manhole_count') AS ok
    UNION ALL SELECT 'gps_columns', EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='vehicle_telemetry_readings' AND column_name='latitude')
    UNION ALL SELECT 'no_dormant_routes', NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='routes')
    UNION ALL SELECT 'no_dormant_expenses', NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='expenses');
  `);
  for (const s of sbxSchema) console.log(`  ${s.ok ? '✓' : '✗'} ${s.check}`);

  sub('4.2 Yannick\'s RLS policies still in place');
  const sbxPolicies = await pg(SBX, `
    SELECT tablename, COUNT(*) AS n FROM pg_policies
    WHERE schemaname='public' AND tablename IN ('photos','photo_links','notes','employees')
    GROUP BY tablename ORDER BY tablename;
  `);
  for (const p of sbxPolicies) console.log(`  ${p.n > 0 ? '✓' : '✗'} ${p.tablename.padEnd(20)} ${p.n} policies`);

  sub('4.3 Row counts vs Production');
  const sbxCounts = await pg(SBX, `
    SELECT 'clients' AS t, COUNT(*)::bigint AS n FROM clients
    UNION ALL SELECT 'visits', COUNT(*) FROM visits
    UNION ALL SELECT 'photos', COUNT(*) FROM photos
    UNION ALL SELECT 'photo_links', COUNT(*) FROM photo_links
    UNION ALL SELECT 'inspections', COUNT(*) FROM inspections
    UNION ALL SELECT 'derm_manifests', COUNT(*) FROM derm_manifests;
  `);
  const prodMap = Object.fromEntries(prodCounts.map(r => [r.t, Number(r.n)]));
  for (const r of sbxCounts) {
    const p = prodMap[r.t];
    const match = Number(r.n) === p ? '✓' : `✗ Δ=${Number(r.n)-p}`;
    console.log(`  ${match} ${r.t.padEnd(20)} sandbox=${r.n} production=${p}`);
  }

  // ============================================================
  section('5. WEBHOOK / SYNC HEALTH');
  // ============================================================
  sub('5.1 Recent webhook_events_log activity');
  const recentEvents = await pg(PROD, `
    SELECT source_system, status, COUNT(*) AS n
    FROM webhook_events_log
    WHERE created_at > now() - INTERVAL '24 hours'
    GROUP BY source_system, status
    ORDER BY source_system, status;
  `);
  if (recentEvents.length === 0) console.log('  ⚠ no events in last 24h');
  for (const r of recentEvents) {
    const icon = r.status === 'processed' ? '✓' : (r.status === 'skipped' ? '⚠' : '✗');
    console.log(`  ${icon} ${r.source_system.padEnd(15)} ${r.status.padEnd(15)} ${r.n}`);
  }

  sub('5.2 Failed webhook events in last 24h');
  const failed = await pg(PROD, `
    SELECT source_system, event_type, error_message, created_at
    FROM webhook_events_log
    WHERE status='failed' AND created_at > now() - INTERVAL '24 hours'
    ORDER BY created_at DESC LIMIT 5;
  `);
  if (failed.length === 0) console.log('  ✓ no failures');
  for (const f of failed) console.log(`  ✗ ${f.source_system}/${f.event_type}: ${(f.error_message||'').slice(0,80)}`);

  // ============================================================
  section('6. PENDING ITEMS');
  // ============================================================
  const allFnsRecent = edgeFns?.every(fn => (Date.now() - new Date(fn.updated_at).getTime()) / 3600000 < 6);
  console.log(`  ${allFnsRecent ? '✓' : '✗'} Edge functions deployed in last 6h`);
  if (!allFnsRecent && edgeFns) {
    for (const fn of edgeFns) {
      const ageH = ((Date.now() - new Date(fn.updated_at).getTime()) / 3600000).toFixed(1);
      if (ageH > 6) console.log(`        ${fn.slug}: ${ageH}h since last deploy — REDEPLOY needed`);
    }
  }

  console.log(`\nAudit completed in ${Math.round((Date.now() - startMs)/1000)}s`);
})().catch(e => { console.error('FATAL:', e.message, e.stack); process.exit(1); });
