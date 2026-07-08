// ============================================================================
// refresh_client_mirror.js
// ============================================================================
// Keeps the "Client App Mirror" Supabase project (CLIENT_MIRROR_REF) in sync
// with Prod's client-domain tables. Yannick builds the Client App Lovable app
// against the mirror; Prod stays untouched (ALL Prod access is read-only).
//
// Modes:
//   node scripts/sync/refresh_client_mirror.js --setup   # one-time: DDL + seed + sequences + meta
//   node scripts/sync/refresh_client_mirror.js           # refresh: drift-heal + snapshot upsert + scoped delete + parity
//
// Design (audited 2026-07-08, two-agent adversarial review — see
// docs/reference/client-app-mirror.md):
// - Mirror DDL carries PK constraints ONLY. No secondary/partial UNIQUEs (a
//   Prod value-swap, e.g. a client-code renumber, would 23505 mid-chunk), no
//   FKs (refresh-pattern sandbox rule), no triggers (updated_at arrives as
//   data; no jobber-push can ever fire from the mirror).
// - Identity columns become plain bigint + local sequence DEFAULT (GENERATED
//   BY DEFAULT semantics) so explicit-id upserts from Prod always work.
// - Defaults whose function isn't in the whitelist are stripped (logged);
//   visits.public_id gets a local substitute so test inserts still get one.
// - Sequences are set ONCE (at --setup) to prod_max + 1,000,000. Yannick's
//   test rows live above that threshold and are NEVER touched by the refresh.
// - Refresh = full-snapshot upsert (self-healing) + SCOPED delete-missing:
//   only rows with PK below the per-table threshold (i.e. Prod-origin rows)
//   that vanished from the Prod snapshot are deleted. Circuit breakers: any
//   Prod read error, or snapshot < 80% of the mirror's below-threshold count,
//   skips the delete phase and exits nonzero.
// - Column drift: Prod-new columns are ADDed to the mirror as NULLABLE
//   (never NOT NULL) + NOTIFY pgrst reload; mirror-extra columns (Yannick's)
//   are never touched; Prod-dropped columns are flagged via mirror_meta.
// - employees.email / employees.phone are deliberately NOT mirrored (PII kept
//   off the permissive-anon sandbox).
// ============================================================================

const path = require('path');
try { require('dotenv').config({ path: path.resolve(__dirname, '../../.env') }); } catch (_) {}

const PAT = process.env.SUPABASE_PAT;
const PROD_URL = process.env.SUPABASE_URL;
const PROD_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROD_REF = process.env.SUPABASE_PROJECT_ID || 'wbasvhvvismukaqdnouk';
const MIR_URL = process.env.CLIENT_MIRROR_URL;
const MIR_KEY = process.env.CLIENT_MIRROR_SECRET_KEY;
const MIR_REF = process.env.CLIENT_MIRROR_REF || (MIR_URL ? new URL(MIR_URL).hostname.split('.')[0] : null);
if (!PAT || !PROD_URL || !PROD_KEY || !MIR_URL || !MIR_KEY) { console.error('Missing env: SUPABASE_PAT / SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY / CLIENT_MIRROR_URL / CLIENT_MIRROR_SECRET_KEY'); process.exit(1); }

const SETUP = process.argv.includes('--setup');
const SEQ_OFFSET = 1_000_000;
const PAGE = 1000, UPSERT_CHUNK = 500, DELETE_CHUNK = 150;

// The mirrored set. Composite-PK link tables carry no sequence; their delete
// scoping keys off the parent visits threshold.
const TABLES = [
  'clients', 'properties', 'client_contacts', 'client_locations', 'client_groups',
  'service_configs', 'gdos', 'zones', 'visits', 'jobs', 'invoices', 'line_items',
  'employees', 'vehicles', 'visit_team', 'visit_assignments', 'visit_locations',
  'entity_source_links', 'service_line_items',
];
// PII kept off the mirror on purpose:
const EXCLUDED_COLUMNS = { employees: ['email', 'phone', 'phone_number'] };
// Default-expression whitelist (anything else is stripped + logged):
const DEFAULT_OK = /^(now\(\)|CURRENT_TIMESTAMP|CURRENT_DATE|gen_random_uuid\(\)|true|false|'[^']*'::[a-z_ ]+|\(?-?[0-9.]+\)?(::[a-z_ ]+)?|ARRAY\[\]::[a-z_ \[\]]+|'\{\}'::[a-z_ \[\]]+)$/i;
const DEFAULT_SUBSTITUTE = { 'visits.public_id': "substr(md5(random()::text), 1, 10)" };

let prodReadErrors = 0;

// ---- HTTP helpers -----------------------------------------------------------
async function mgmt(ref, query, readOnly) {
  for (let attempt = 0; attempt < 5; attempt++) {
    const r = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, {
      method: 'POST', headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(readOnly ? { query, read_only: true } : { query }),
    });
    if (r.status === 429) { const reset = Number(r.headers.get('x-ratelimit-reset')) || 30; await sleep(reset * 1000); continue; }
    const t = await r.text();
    if (r.status >= 300) throw new Error(`mgmt ${ref} ${r.status}: ${t.slice(0, 300)}`);
    try { return JSON.parse(t); } catch { return t; }
  }
  throw new Error('mgmt: rate-limited 5x');
}
const prodSQL = (q) => mgmt(PROD_REF, q, true);      // Prod: platform-enforced read-only
const mirSQL = (q) => mgmt(MIR_REF, q, false);
function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

async function rest(base, key, pathq, opts = {}) {
  const r = await fetch(base + '/rest/v1' + pathq, {
    ...opts, headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', ...(opts.headers || {}) },
  });
  const t = await r.text();
  if (r.status >= 300) throw new Error(`REST ${pathq.slice(0, 80)} -> ${r.status}: ${t.slice(0, 300)}`);
  return t ? JSON.parse(t) : null;
}
async function restCount(base, key, table, filter) {
  const r = await fetch(`${base}/rest/v1/${table}?select=*${filter ? '&' + filter : ''}`, {
    method: 'HEAD', headers: { apikey: key, Authorization: `Bearer ${key}`, Prefer: 'count=exact', Range: '0-0' },
  });
  const cr = r.headers.get('content-range');
  if (!cr) throw new Error(`count ${table}: no content-range (${r.status})`);
  return Number(cr.split('/')[1]);
}

// ---- catalog ----------------------------------------------------------------
async function prodCatalog() {
  const list = TABLES.map((t) => `'${t}'`).join(',');
  const cols = await prodSQL(`
    SELECT c.relname AS tbl, a.attname AS col, format_type(a.atttypid, a.atttypmod) AS typ,
           a.attnotnull AS notnull, a.attidentity AS ident, pg_get_expr(d.adbin, d.adrelid) AS def
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    LEFT JOIN pg_attrdef d ON d.adrelid = c.oid AND d.adnum = a.attnum
    WHERE c.relname IN (${list}) AND c.relkind = 'r' ORDER BY c.relname, a.attnum;`);
  const pks = await prodSQL(`
    SELECT c.relname AS tbl, a.attname AS col
    FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
    WHERE i.indisprimary AND c.relname IN (${list});`);
  const byTable = {};
  for (const t of TABLES) byTable[t] = { cols: [], pk: [] };
  for (const r of cols) if (byTable[r.tbl]) byTable[r.tbl].cols.push(r);
  for (const r of pks) if (byTable[r.tbl]) byTable[r.tbl].pk.push(r.col);
  for (const t of TABLES) {
    const excl = EXCLUDED_COLUMNS[t] || [];
    byTable[t].cols = byTable[t].cols.filter((c) => !excl.includes(c.col));
    if (!byTable[t].cols.length) { console.log(`  ⚠ table ${t} not found on Prod — skipping`); delete byTable[t]; }
    else if (!byTable[t].pk.length) throw new Error(`table ${t} has NO primary key — upsert unsafe, aborting`);
  }
  return byTable;
}
async function mirrorColumns() {
  const rows = await mirSQL(`
    SELECT c.relname AS tbl, a.attname AS col FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    WHERE c.relkind = 'r';`);
  const m = {};
  for (const r of rows) { (m[r.tbl] = m[r.tbl] || new Set()).add(r.col); }
  return m;
}

// ---- setup ------------------------------------------------------------------
function buildDDL(t, info) {
  const seq = `${t}_id_seq`;
  const hasIdentity = info.cols.some((c) => c.ident === 'a' || c.ident === 'd');
  const lines = info.cols.map((c) => {
    let def = '';
    const sub = DEFAULT_SUBSTITUTE[`${t}.${c.col}`];
    if (c.ident === 'a' || c.ident === 'd') def = ` DEFAULT nextval('${seq}')`;
    else if (sub) def = ` DEFAULT ${sub}`;
    else if (c.def && !/nextval\(/.test(c.def)) {
      if (DEFAULT_OK.test(c.def.trim())) def = ` DEFAULT ${c.def}`;
      else console.log(`  · stripped default on ${t}.${c.col}: ${c.def}`);
    }
    return `"${c.col}" ${c.typ}${c.notnull ? ' NOT NULL' : ''}${def}`;
  });
  const pk = `, PRIMARY KEY (${info.pk.map((c) => `"${c}"`).join(', ')})`;
  const seqDDL = hasIdentity ? `CREATE SEQUENCE IF NOT EXISTS ${seq};\n` : '';
  return `${seqDDL}CREATE TABLE IF NOT EXISTS public.${t} (${lines.join(', ')}${pk});\n` +
    `ALTER TABLE public.${t} ENABLE ROW LEVEL SECURITY;\n` +
    `DROP POLICY IF EXISTS mirror_all ON public.${t};\n` +
    `CREATE POLICY mirror_all ON public.${t} FOR ALL TO anon, authenticated USING (true) WITH CHECK (true);\n`;
}

async function setup(cat) {
  console.log('SETUP: creating schema on mirror…');
  for (const t of Object.keys(cat)) await mirSQL(buildDDL(t, cat[t]));
  await mirSQL(`
    CREATE TABLE IF NOT EXISTS public.mirror_meta (
      table_name text PRIMARY KEY, id_threshold bigint, prod_columns text[],
      last_refresh_at timestamptz, last_counts jsonb);
    ALTER TABLE public.mirror_meta ENABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS mirror_meta_read ON public.mirror_meta;
    CREATE POLICY mirror_meta_read ON public.mirror_meta FOR SELECT TO anon, authenticated USING (true);
    CREATE OR REPLACE VIEW public.v_visits_live AS SELECT * FROM public.visits WHERE deleted_at IS NULL;
    GRANT USAGE ON SCHEMA public TO anon, authenticated;
    GRANT ALL ON ALL TABLES IN SCHEMA public TO anon, authenticated;
    GRANT SELECT ON public.v_visits_live TO anon, authenticated;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO anon, authenticated;
    ALTER ROLE anon SET statement_timeout = '15s';
    ALTER ROLE authenticated SET statement_timeout = '15s';
    NOTIFY pgrst, 'reload schema';`);
  console.log('SETUP: schema done.');
}

// ---- data movement ----------------------------------------------------------
async function prodSnapshot(t, pkCols) {
  const order = pkCols.map((c) => `${c}.asc`).join(',');
  const rows = [];
  for (let off = 0; ; off += PAGE) {
    try {
      const page = await rest(PROD_URL, PROD_KEY, `/${t}?select=*&order=${order}&limit=${PAGE}&offset=${off}`);
      rows.push(...page);
      if (page.length < PAGE) break;
    } catch (e) { prodReadErrors++; throw e; }
  }
  return rows;
}
async function upsert(t, pkCols, rows, mirrorCols) {
  const onc = pkCols.join(',');
  for (let i = 0; i < rows.length; i += UPSERT_CHUNK) {
    const chunk = rows.slice(i, i + UPSERT_CHUNK).map((r) => {
      const o = {};
      for (const k of Object.keys(r)) if (mirrorCols.has(k)) o[k] = r[k];
      return o;
    });
    await rest(MIR_URL, MIR_KEY, `/${t}?on_conflict=${onc}`, {
      method: 'POST', headers: { Prefer: 'resolution=merge-duplicates,return=minimal' }, body: JSON.stringify(chunk),
    });
  }
}
async function scopedDelete(t, pkCols, prodRows, thresholds) {
  const thr = pkCols.includes('id') ? thresholds[t] : thresholds['visits'];
  if (!thr) { console.log(`  · ${t}: no threshold — skipping delete phase`); return 0; }
  const scopeCol = pkCols.includes('id') ? 'id' : 'visit_id';
  const mirrorPks = [];
  for (let off = 0; ; off += PAGE) {
    const page = await rest(MIR_URL, MIR_KEY, `/${t}?select=${pkCols.join(',')}&${scopeCol}=lt.${thr}&order=${pkCols.map((c) => c + '.asc').join(',')}&limit=${PAGE}&offset=${off}`);
    mirrorPks.push(...page);
    if (page.length < PAGE) break;
  }
  const key = (r) => pkCols.map((c) => r[c]).join('|');
  const prodSet = new Set(prodRows.map(key));
  const missing = mirrorPks.filter((r) => !prodSet.has(key(r)));
  // circuit breaker: a Prod snapshot wildly smaller than the mirror's prod-space rows = bad read, not mass delete
  if (mirrorPks.length > 20 && prodRows.length < 0.8 * mirrorPks.length) {
    console.error(`  ⚠ ${t}: snapshot ${prodRows.length} < 80% of mirror ${mirrorPks.length} — SKIPPING deletes (circuit breaker)`);
    process.exitCode = 1; return 0;
  }
  if (!missing.length) return 0;
  if (pkCols.length === 1) {
    for (let i = 0; i < missing.length; i += DELETE_CHUNK) {
      const ids = missing.slice(i, i + DELETE_CHUNK).map((r) => r[pkCols[0]]).join(',');
      await rest(MIR_URL, MIR_KEY, `/${t}?${pkCols[0]}=in.(${ids})`, { method: 'DELETE', headers: { Prefer: 'return=minimal' } });
    }
  } else {
    for (let i = 0; i < missing.length; i += DELETE_CHUNK) {
      const vals = missing.slice(i, i + DELETE_CHUNK).map((r) => `(${pkCols.map((c) => r[c]).join(',')})`).join(',');
      await mirSQL(`DELETE FROM public.${t} WHERE (${pkCols.join(',')}) IN (VALUES ${vals});`);
    }
  }
  return missing.length;
}

// ---- drift healing ------------------------------------------------------------
async function healDrift(cat, mirCols, meta) {
  let altered = false;
  for (const t of Object.keys(cat)) {
    const mine = mirCols[t] || new Set();
    for (const c of cat[t].cols) {
      if (!mine.has(c.col)) {
        console.log(`  + drift: adding ${t}.${c.col} (${c.typ}) as NULLABLE`);
        await mirSQL(`ALTER TABLE public.${t} ADD COLUMN IF NOT EXISTS "${c.col}" ${c.typ};`);
        mine.add(c.col); altered = true;
      }
    }
    const prodNow = new Set(cat[t].cols.map((c) => c.col));
    const prodOrigin = meta[t]?.prod_columns || [];
    for (const c of prodOrigin) if (!prodNow.has(c) && mine.has(c)) console.log(`  ⚠ drift: Prod DROPPED column ${t}.${c} (left on mirror — manual cleanup)`);
  }
  if (altered) { await mirSQL(`NOTIFY pgrst, 'reload schema';`); await sleep(3000); }
}

// ---- main ---------------------------------------------------------------------
(async () => {
  const started = new Date().toISOString();
  console.log(`refresh_client_mirror — ${SETUP ? 'SETUP' : 'REFRESH'} — ${started}`);
  const cat = await prodCatalog();
  if (SETUP) await setup(cat);

  const metaRows = SETUP ? [] : await mirSQL(`SELECT table_name, id_threshold, prod_columns FROM public.mirror_meta;`);
  const meta = {}; for (const m of metaRows) meta[m.table_name] = m;
  const mirCols = await mirrorColumns();
  if (!SETUP) await healDrift(cat, mirCols, meta);
  const mirCols2 = await mirrorColumns();

  const thresholds = {}; for (const m of metaRows) thresholds[m.table_name] = Number(m.id_threshold);
  const summary = [];
  for (const t of Object.keys(cat)) {
    const pkCols = cat[t].pk;
    const rows = await prodSnapshot(t, pkCols);
    await upsert(t, pkCols, rows, mirCols2[t] || new Set());
    let deleted = 0;
    if (!SETUP && prodReadErrors === 0) deleted = await scopedDelete(t, pkCols, rows, thresholds);
    if (SETUP && pkCols.includes('id')) {
      const maxId = rows.length ? Math.max(...rows.map((r) => Number(r.id))) : 0;
      const thr = maxId + SEQ_OFFSET;
      thresholds[t] = thr;
      const hasSeq = cat[t].cols.some((c) => c.ident === 'a' || c.ident === 'd');
      if (hasSeq) await mirSQL(`SELECT setval('${t}_id_seq', ${thr});`);
    }
    summary.push({ t, rows: rows.length, deleted });
    console.log(`  ${t}: ${rows.length} rows upserted${deleted ? `, ${deleted} deleted` : ''}`);
  }
  // link tables scope off visits' threshold at setup
  if (SETUP) { for (const t of ['visit_team', 'visit_assignments', 'visit_locations']) thresholds[t] = null; }

  // persist meta
  for (const t of Object.keys(cat)) {
    const colsArr = cat[t].cols.map((c) => `'${c.col}'`).join(',');
    await mirSQL(`
      INSERT INTO public.mirror_meta (table_name, id_threshold, prod_columns, last_refresh_at, last_counts)
      VALUES ('${t}', ${thresholds[t] ?? 'NULL'}, ARRAY[${colsArr}]::text[], now(), '${JSON.stringify(summary.find((s) => s.t === t))}'::jsonb)
      ON CONFLICT (table_name) DO UPDATE SET
        ${SETUP ? 'id_threshold = EXCLUDED.id_threshold,' : ''}
        prod_columns = EXCLUDED.prod_columns, last_refresh_at = now(), last_counts = EXCLUDED.last_counts;`);
  }

  // parity check (scoped to Prod id-space)
  let parityFail = 0;
  for (const t of Object.keys(cat)) {
    const pkCols = cat[t].pk;
    const scopeCol = pkCols.includes('id') ? 'id' : 'visit_id';
    const thr = pkCols.includes('id') ? thresholds[t] : thresholds['visits'];
    const filter = thr ? `${scopeCol}=lt.${thr}` : '';
    const [p, m] = await Promise.all([restCount(PROD_URL, PROD_KEY, t, ''), restCount(MIR_URL, MIR_KEY, t, filter)]);
    if (p !== m) { parityFail++; console.error(`  ✗ parity ${t}: prod=${p} mirror=${m}`); }
  }
  const totalDeleted = summary.reduce((a, s) => a + s.deleted, 0);
  console.log(`\nDONE. tables=${summary.length} rows=${summary.reduce((a, s) => a + s.rows, 0)} deleted=${totalDeleted} parityFail=${parityFail} prodReadErrors=${prodReadErrors}`);
  if (parityFail || prodReadErrors) process.exitCode = 1;
})().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
