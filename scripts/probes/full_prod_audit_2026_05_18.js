// full_prod_audit_2026_05_18.js — Full Prod DB audit.
// Read-only. Outputs sectioned JSON to docs/audits/prod_full_audit_2026-05-18_raw.json.

const https = require('https');
const fs = require('fs');
const path = require('path');
require('dotenv').config({ path: '.env' });

const PAT = process.env.SUPABASE_PAT;
const URL = process.env.SUPABASE_URL;
const ref = URL.match(/https?:\/\/([^.]+)\./)[1];

function pg(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com', path: '/v1/projects/' + ref + '/database/query',
      method: 'POST',
      headers: { Authorization: 'Bearer ' + PAT, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>{ if(r.statusCode>=300) return rej(new Error(r.statusCode+': '+d.slice(0,400))); res(JSON.parse(d)); }); });
    req.on('error', rej); req.write(body); req.end();
  });
}

function api(method, p) {
  return new Promise((res, rej) => {
    const req = https.request({ hostname: 'api.supabase.com', path: p, method, headers: { Authorization: 'Bearer ' + PAT } }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>res({s:r.statusCode,b:d})); });
    req.on('error', rej); req.end();
  });
}

const out = {};

async function section(name, runner) {
  process.stdout.write(`[${name}] ... `);
  try {
    const start = Date.now();
    out[name] = await runner();
    console.log('OK (' + (Date.now()-start) + 'ms)');
  } catch (e) {
    out[name] = { error: e.message };
    console.log('FAIL: ' + e.message);
  }
}

(async () => {
  console.log('# Prod DB Full Audit — ' + new Date().toISOString() + '\n');

  await section('1_schema_inventory', async () => ({
    tables_public: (await pg(`SELECT COUNT(*)::int AS n FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'`))[0].n,
    views_public: (await pg(`SELECT COUNT(*)::int AS n FROM information_schema.views WHERE table_schema='public'`))[0].n,
    views_customer: (await pg(`SELECT COUNT(*)::int AS n FROM information_schema.views WHERE table_schema='customer'`))[0].n,
    views_derm: (await pg(`SELECT COUNT(*)::int AS n FROM information_schema.views WHERE table_schema='derm'`))[0].n,
    views_ops: (await pg(`SELECT COUNT(*)::int AS n FROM information_schema.views WHERE table_schema='ops'`))[0].n,
    schemas: await pg(`SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT LIKE 'pg_%' AND schema_name NOT IN ('information_schema') ORDER BY schema_name`),
    extensions: await pg(`SELECT extname, extversion FROM pg_extension ORDER BY extname`),
    functions_public: (await pg(`SELECT COUNT(*)::int AS n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public'`))[0].n,
    triggers_user: (await pg(`SELECT COUNT(*)::int AS n FROM pg_trigger WHERE NOT tgisinternal`))[0].n,
  }));

  await section('2_source_agnostic_compliance', async () =>
    await pg(`
      SELECT table_name, column_name
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND (column_name ~ '^(jobber|airtable|samsara|fillout|odoo)_'
             OR column_name ~ '_(jobber|airtable|samsara|fillout|odoo)_'
             OR column_name ~ '_(jobber|airtable|samsara|fillout|odoo)$')
        AND table_name NOT IN ('webhook_events_log','entity_source_links','webhook_tokens','sync_cursors','sync_log')
      ORDER BY table_name, column_name`)
  );

  await section('3_three_nf_smells', async () => {
    // Heuristic: look for columns ending in _name, _code, _email on tables that also have a FK
    // to a table with that column. This isn't exhaustive — just catches obvious snapshots.
    const cols = await pg(`
      SELECT c.table_name, c.column_name
      FROM information_schema.columns c
      WHERE c.table_schema = 'public'
        AND c.column_name ~ '_(name|code|email|address)$'
        AND c.table_name NOT IN ('webhook_events_log','entity_source_links','raw_jobber_pull_clients','raw_jobber_pull_visits','raw_jobber_pull_jobs')
      ORDER BY c.table_name, c.column_name`);
    return cols;
  });

  await section('4_fk_integrity_orphans', async () => {
    const fks = await pg(`
      SELECT
        con.conname,
        cl.relname     AS child_table,
        a.attname      AS child_col,
        cl_ref.relname AS parent_table,
        a_ref.attname  AS parent_col
      FROM pg_constraint con
      JOIN pg_class cl       ON cl.oid = con.conrelid
      JOIN pg_class cl_ref   ON cl_ref.oid = con.confrelid
      JOIN pg_namespace n    ON n.oid = cl.relnamespace
      JOIN pg_attribute a    ON a.attrelid = cl.oid     AND a.attnum     = con.conkey[1]
      JOIN pg_attribute a_ref ON a_ref.attrelid = cl_ref.oid AND a_ref.attnum = con.confkey[1]
      WHERE con.contype = 'f'
        AND n.nspname = 'public'
      ORDER BY child_table`);
    const orphans = [];
    for (const fk of fks) {
      const q = `SELECT COUNT(*)::int AS n FROM public.${fk.child_table} c LEFT JOIN public.${fk.parent_table} p ON p.${fk.parent_col} = c.${fk.child_col} WHERE c.${fk.child_col} IS NOT NULL AND p.${fk.parent_col} IS NULL`;
      try {
        const r = await pg(q);
        if (r[0].n > 0) orphans.push({ ...fk, orphan_count: r[0].n });
      } catch (e) {
        orphans.push({ ...fk, error: e.message.slice(0, 100) });
      }
    }
    return { total_fks_checked: fks.length, orphans };
  });

  await section('5_rls_posture', async () =>
    await pg(`
      SELECT
        c.relname AS table_name,
        c.relrowsecurity AS rls_enabled,
        (SELECT COUNT(*)::int FROM pg_policy WHERE polrelid = c.oid) AS policy_count,
        (SELECT BOOL_OR('anon' = ANY(polroles::regrole[]::text[])) FROM pg_policy WHERE polrelid = c.oid AND polcmd = 'r') AS has_anon_select,
        (SELECT BOOL_OR('anon' = ANY(polroles::regrole[]::text[])) FROM pg_policy WHERE polrelid = c.oid AND polcmd IN ('a','w','d','*')) AS has_anon_write,
        (SELECT BOOL_OR('authenticated' = ANY(polroles::regrole[]::text[])) FROM pg_policy WHERE polrelid = c.oid) AS has_authenticated_policy
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'public' AND c.relkind = 'r'
      ORDER BY c.relname`)
  );

  await section('6_index_health_seq_scan_heavy', async () =>
    await pg(`
      SELECT relname AS table_name, seq_scan, idx_scan, n_live_tup, seq_tup_read
      FROM pg_stat_user_tables
      WHERE schemaname = 'public'
        AND seq_scan > 5000
        AND seq_scan > COALESCE(idx_scan, 0)
      ORDER BY seq_scan DESC
      LIMIT 30`)
  );

  await section('6b_fk_columns_missing_index', async () =>
    await pg(`
      SELECT cl.relname AS table_name, a.attname AS fk_column
      FROM pg_constraint con
      JOIN pg_class cl    ON cl.oid = con.conrelid
      JOIN pg_namespace n ON n.oid = cl.relnamespace
      JOIN pg_attribute a ON a.attrelid = cl.oid AND a.attnum = con.conkey[1]
      WHERE con.contype = 'f' AND n.nspname = 'public'
        AND NOT EXISTS (
          SELECT 1 FROM pg_index i
          WHERE i.indrelid = cl.oid AND a.attnum = ANY(i.indkey)
        )
      ORDER BY cl.relname, a.attname`)
  );

  await section('7_data_quality_null_rates', async () => {
    const ret = {};
    const checks = [
      { t: 'clients',         cols: ['status','name','slug'] },
      { t: 'visits',          cols: ['client_id','visit_date','visit_status','vehicle_id'] },
      { t: 'properties',      cols: ['client_id','address','county','is_billing'] },
      { t: 'derm_manifests',  cols: ['client_id','white_manifest_number','service_date','disposal_facility_id'] },
      { t: 'manifest_visits', cols: ['manifest_id','visit_id'] },
      { t: 'employees',       cols: ['full_name','status'] },
      { t: 'vehicles',        cols: ['name','status'] },
      { t: 'service_configs', cols: ['client_id','service_type'] },
      { t: 'photo_classifications', cols: ['photo_id','service_phase'] },
    ];
    for (const c of checks) {
      try {
        const parts = c.cols.map(col => `COUNT(*) FILTER (WHERE ${col} IS NULL)::int AS null_${col}`);
        const sql = `SELECT COUNT(*)::int AS total, ${parts.join(', ')} FROM public.${c.t}`;
        ret[c.t] = (await pg(sql))[0];
      } catch (e) {
        ret[c.t] = { error: e.message.slice(0, 200) };
      }
    }
    // Completed-visits-only checks
    try {
      ret.visits_completed_only = (await pg(`SELECT COUNT(*)::int AS total_completed, COUNT(*) FILTER (WHERE completed_at IS NULL)::int AS null_completed_at, COUNT(*) FILTER (WHERE vehicle_id IS NULL)::int AS null_vehicle_id FROM public.visits WHERE visit_status='completed'`))[0];
    } catch (e) { ret.visits_completed_only = { error: e.message }; }
    return ret;
  });

  await section('8_audit_trail_coverage', async () => {
    const tables = await pg(`SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname='public' AND c.relkind='r' ORDER BY relname`);
    const expected = ['clients','service_configs','properties','visits','photo_classifications','derm_manifests','manifest_visits','disposal_facilities','vehicles','employees','webhook_tokens'];
    const triggers = await pg(`SELECT cl.relname AS table_name, t.tgname FROM pg_trigger t JOIN pg_class cl ON cl.oid = t.tgrelid JOIN pg_namespace n ON n.oid = cl.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal AND t.tgname LIKE 'audit_%' ORDER BY cl.relname`);
    const audited = new Set(triggers.map(r => r.table_name));
    return {
      expected_audited: expected,
      currently_audited: [...audited],
      missing_from_audited: expected.filter(t => !audited.has(t)),
      unexpected_audited: [...audited].filter(t => !expected.includes(t)),
      triggers: triggers,
      all_public_tables: tables.map(r => r.relname),
    };
  });

  await section('9_updated_at_hygiene', async () => {
    const cols = await pg(`SELECT table_name FROM information_schema.columns WHERE table_schema='public' AND column_name='updated_at' ORDER BY table_name`);
    const triggers = await pg(`SELECT cl.relname AS table_name FROM pg_trigger t JOIN pg_class cl ON cl.oid = t.tgrelid JOIN pg_namespace n ON n.oid = cl.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal AND (t.tgname ILIKE '%updated_at%' OR t.tgname ILIKE '%touch%' OR t.tgname ILIKE '%set_updated%') ORDER BY cl.relname`);
    const hasCol = new Set(cols.map(r => r.table_name));
    const hasTrg = new Set(triggers.map(r => r.table_name));
    const all = await pg(`SELECT relname AS table_name FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname='public' AND c.relkind='r' ORDER BY relname`);
    return {
      tables_with_updated_at_col: [...hasCol],
      tables_with_updated_at_trigger: [...hasTrg],
      missing_trigger_but_has_col: [...hasCol].filter(t => !hasTrg.has(t)),
      total_public_tables: all.length,
    };
  });

  await section('10_sync_cursors_health', async () =>
    await pg(`
      SELECT entity, last_synced_at::text, last_run_finished::text, last_run_status, last_error,
             rows_pulled, rows_populated,
             EXTRACT(EPOCH FROM (now() - last_run_finished))::int / 3600 AS hours_since_last_run
      FROM public.sync_cursors
      ORDER BY last_run_finished DESC NULLS LAST`)
  );

  await section('11_storage_top_tables', async () => ({
    top_tables: await pg(`
      SELECT n.nspname AS schema, c.relname AS table_name,
        pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
        pg_total_relation_size(c.oid) AS total_bytes
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind IN ('r','p')
        AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
      ORDER BY total_bytes DESC
      LIMIT 15`),
    top_indexes: await pg(`
      SELECT n.nspname AS schema, c.relname AS index_name,
        pg_size_pretty(pg_relation_size(c.oid)) AS index_size,
        pg_relation_size(c.oid) AS bytes
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind = 'i'
        AND n.nspname NOT IN ('pg_catalog','information_schema','pg_toast')
      ORDER BY bytes DESC
      LIMIT 10`),
  }));

  await section('12_webhook_events_last_7d', async () =>
    await pg(`
      SELECT source_system, COUNT(*)::int AS total,
        COUNT(*) FILTER (WHERE status = 'success')::int AS success,
        COUNT(*) FILTER (WHERE status = 'error')::int   AS errors,
        MAX(received_at)::text AS last_event
      FROM public.webhook_events_log
      WHERE received_at > now() - INTERVAL '7 days'
      GROUP BY source_system
      ORDER BY total DESC`)
  );

  await section('13_postgrest_exposed_schemas', async () => {
    const r = await api('GET', '/v1/projects/' + ref + '/postgrest');
    return JSON.parse(r.b);
  });

  await section('14_audit_logs_partitions', async () => ({
    partitions: await pg(`SELECT child.relname AS partition_name, pg_size_pretty(pg_total_relation_size(child.oid)) AS size FROM pg_inherits i JOIN pg_class parent ON parent.oid = i.inhparent JOIN pg_class child ON child.oid = i.inhrelid JOIN pg_namespace n ON n.oid = parent.relnamespace WHERE n.nspname='audit' AND parent.relname='logs' ORDER BY child.relname`),
    total_audit_log_size: (await pg(`SELECT pg_size_pretty(pg_total_relation_size('audit.logs')) AS size`))[0].size,
    row_count: (await pg(`SELECT COUNT(*)::int AS n FROM audit.logs`))[0].n,
  }));

  await section('15_connections_snapshot', async () =>
    await pg(`
      SELECT application_name, state, COUNT(*)::int AS n
      FROM pg_stat_activity
      WHERE datname = current_database()
      GROUP BY application_name, state
      ORDER BY n DESC
      LIMIT 20`)
  );

  await section('16_function_trigger_counts', async () => ({
    functions_by_schema: await pg(`SELECT n.nspname AS schema, COUNT(*)::int AS n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname NOT IN ('pg_catalog','information_schema') GROUP BY n.nspname ORDER BY n DESC`),
    triggers_by_schema: await pg(`SELECT n.nspname AS schema, COUNT(*)::int AS n FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace WHERE NOT t.tgisinternal GROUP BY n.nspname ORDER BY n DESC`),
  }));

  await section('17_views_using_select_star', async () =>
    // Views that reference public.* tables without explicit column list are a maintenance hazard
    await pg(`SELECT viewname FROM pg_views WHERE schemaname IN ('customer','derm','ops') AND definition ILIKE '%SELECT *%'`)
  );

  await section('18_money_columns_audit', async () =>
    await pg(`SELECT table_name, column_name, data_type, numeric_precision, numeric_scale
              FROM information_schema.columns
              WHERE table_schema='public'
                AND (column_name ILIKE '%price%' OR column_name ILIKE '%amount%' OR column_name ILIKE '%cost%' OR column_name ILIKE '%total%' OR column_name ILIKE '%balance%')
              ORDER BY table_name, column_name`)
  );

  await section('19_timestamp_columns_audit', async () => ({
    non_tz_timestamps: await pg(`SELECT table_name, column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND data_type='timestamp without time zone'`),
  }));

  fs.mkdirSync('docs/audits', { recursive: true });
  fs.writeFileSync('docs/audits/prod_full_audit_2026-05-18_raw.json', JSON.stringify(out, null, 2));
  console.log('\nRaw JSON written → docs/audits/prod_full_audit_2026-05-18_raw.json');
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
