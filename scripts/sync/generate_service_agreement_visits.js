// ============================================================================
// generate_service_agreement_visits.js
// ============================================================================
// GENERATE step (DB -> visits) of the Service Agreement visit-generation pipeline.
// Spec: Supabase/docs/service-agreement-visit-generation.md (§9).
//
// Reads Service Agreement jobs from OUR DB (jobs.frequency_days > 0 and
// title ILIKE 'Service Agreement%') -- populated by fetch_service_agreement_jobs.js --
// and generates scheduled visits every frequency_days days. The Calendar app is the
// source of truth for visits; each generated visit carries job_id, so its line items,
// frequency and Jobber link all resolve through the job (3NF, nothing copied onto the
// visit except the title, service_type and DERM flag — both derived from the job's
// line items via the canonical service_line_items taxonomy / fn_line_item_requires_derm).
//
// Anchor precedence (per job):
//   1. max scheduled FUTURE visit for THIS job   -> +freq   (extend the chain)
//   2. else max completed visit for the CLIENT   -> +freq   (resume cadence from last real service)
//   3. else today + freq                          (cold start)
// Idempotency: skip any candidate date within +/-7d of an existing visit for the same job.
//
// CLI:
//   node scripts/sync/generate_service_agreement_visits.js              # DRY-RUN, client 112-YA
//   node scripts/sync/generate_service_agreement_visits.js --execute    # write to DB
//   node scripts/sync/generate_service_agreement_visits.js --client=112-YA
//   node scripts/sync/generate_service_agreement_visits.js --all        # every fetched SA job
// ============================================================================

const https = require('https');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') }); } catch (_) {}

const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
if (!SUPABASE_URL || !SVC) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY required');

const EXECUTE = process.argv.includes('--execute');
const ALL = process.argv.includes('--all');
const clientArg = process.argv.find(a => a.startsWith('--client='));
// Default to 112-YA during the test phase so a stray run can never touch other clients.
const FILTER_CLIENT = clientArg ? clientArg.split('=')[1] : (ALL ? null : '112-YA');

const IDEMPOTENCY_TOLERANCE_DAYS = 7;
const horizonArg = process.argv.find(a => a.startsWith('--horizon-months='));
const HORIZON_MONTHS = horizonArg ? Math.max(1, parseInt(horizonArg.split('=')[1], 10) || 12) : 12;
const MAX_PER_JOB = 24;
const MAX_CLEANUP = 40;   // safety cap: never auto-soft-delete more than this many stale visits in one run

// Test / non-serviceable accounts that must NEVER auto-generate visits (Fred 2026-06-24):
//   112-YA + 777-YA = Yan's test restaurants; 000-DH = Homestead Dump (a disposal site).
// Null client_code (residential / junk / not-imported, e.g. "DUMP Pompano") is also excluded —
// real recurring SA clients always carry an Airtable client_code. The exclusion applies even
// when a code is passed via --client, so a stray manual run can't touch these either.
const EXCLUDED_CLIENT_CODES = ['112-YA', '777-YA', '000-DH'];
const EXCL_SQL = EXCLUDED_CLIENT_CODES.map(c => `'${c.replace(/'/g, "''")}'`).join(', ');

// Shared SA-generating predicate (jobs aliased `j`, clients `c`) — used by BOTH the generation
// query AND the stale-cleanup sweep so the two can never drift. A job generates visits IFF it is
// an active, frequency-set, non-[OLD] Service Agreement for a real ACTIVE/RECURRING coded client.
const JOB_PREDICATE = `j.frequency_days > 0
      AND j.title ILIKE 'Service Agreement%'
      AND j.title NOT ILIKE '%[OLD]%'
      AND COALESCE(j.job_status,'') <> 'archived'
      AND c.status IN ('ACTIVE','RECURRING')
      AND c.client_code IS NOT NULL
      AND c.client_code NOT IN (${EXCL_SQL})`;

// ---- HTTP helpers -----------------------------------------------------------
function http(opts, body) {
  return new Promise((res, rej) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({ ...opts, headers: { ...opts.headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) } },
      r => { const ch = []; r.on('data', c => ch.push(c)); r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(ch).toString() })); });
    req.on('error', rej); req.setTimeout(60000, () => req.destroy(new Error('timeout')));
    if (payload) req.write(payload); req.end();
  });
}
async function pg(sql, _retry = 0) {
  if (!PAT || !PROJECT) throw new Error('SUPABASE_PAT and SUPABASE_PROJECT_ID required');
  const r = await http({ hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`, method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' } }, JSON.stringify({ query: sql }));
  if ((r.status === 429 || (r.status >= 500 && r.status < 600)) && _retry < 5) {
    await new Promise(rs => setTimeout(rs, Math.min(60000, 2000 * Math.pow(2, _retry)))); return pg(sql, _retry + 1);
  }
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 300)}`);
  return JSON.parse(r.body);
}
async function rest(path, opts = {}) {
  const u = new URL(SUPABASE_URL + '/rest/v1' + path);
  const r = await http({ hostname: u.hostname, path: u.pathname + u.search, method: opts.method || 'GET',
    headers: { apikey: SVC, Authorization: `Bearer ${SVC}`, 'Content-Type': 'application/json', ...(opts.headers || {}) } }, opts.body);
  if (r.status >= 300) throw new Error(`REST ${path} -> ${r.status}: ${r.body.slice(0, 300)}`);
  return r.body ? JSON.parse(r.body) : null;
}

// ---- date math (ISO 'YYYY-MM-DD' strings, ET calendar) ----------------------
function addDays(iso, days) { const [y, m, d] = iso.split('-').map(Number); const dt = new Date(Date.UTC(y, m - 1, d)); dt.setUTCDate(dt.getUTCDate() + days); return dt.toISOString().slice(0, 10); }
function diffDays(a, b) { const [ya, ma, da] = a.split('-').map(Number); const [yb, mb, db] = b.split('-').map(Number); return Math.round((Date.UTC(ya, ma - 1, da) - Date.UTC(yb, mb - 1, db)) / 86400000); }
function todayET() { return new Intl.DateTimeFormat('en-CA', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date()); }
function endOfHorizon(iso) { const [y, m] = iso.split('-').map(Number); return new Date(Date.UTC(y, m + HORIZON_MONTHS, 0)).toISOString().slice(0, 10); }

// ---- main -------------------------------------------------------------------
(async () => {
  const today = todayET();
  const horizonEnd = endOfHorizon(today);
  console.log(`generate_service_agreement_visits — ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}`);
  console.log(`today=${today}  horizon=${horizonEnd}  client=${FILTER_CLIENT || 'ALL'}\n`);

  const clientFilter = FILTER_CLIENT ? `AND c.client_code = '${FILTER_CLIENT.replace(/'/g, "''")}'` : '';
  const jobs = await pg(`
    SELECT j.id AS job_id, j.job_number, j.title, j.frequency_days,
           c.id AS client_id, c.client_code, c.name AS client_name,
           -- derm_required: canonical taxonomy classifier (ADR-018), NOT a crude name match.
           -- Keying off service_line_items.requires_derm via fn_line_item_requires_derm avoids
           -- false positives (e.g. a non-pump item whose name contains "pumping"); those would
           -- be PERMANENT because the nightly rederive is monotonic (never demotes a TRUE).
           -- NULL (no classifiable line item) is allowed = unknown = surfaced/safe.
           bool_or(public.fn_line_item_requires_derm(li.name)) AS derm_required,
           -- service_type derived from the job's line items (GT > CL > WD priority, default GT),
           -- mirroring webhook-jobber.handleVisit so a bounced-back visit promotes (matches on
           -- service_type) instead of inserting a duplicate. Never leave it NULL.
           COALESCE((
             SELECT sli.service_type
             FROM line_items l2
             JOIN service_line_items sli ON sli.code = lpad(substring(btrim(l2.name) from '^([0-9]+)'), 2, '0')
             WHERE l2.job_id = j.id AND l2.invoice_id IS NULL AND sli.service_type IS NOT NULL
             ORDER BY CASE sli.service_type WHEN 'GT' THEN 1 WHEN 'CL' THEN 2 WHEN 'WD' THEN 3 ELSE 4 END
             LIMIT 1), 'GT') AS service_type
    FROM jobs j
    JOIN clients c ON c.id = j.client_id
    LEFT JOIN line_items li ON li.job_id = j.id AND li.invoice_id IS NULL
    WHERE ${JOB_PREDICATE}
      ${clientFilter}
    GROUP BY j.id, j.job_number, j.title, j.frequency_days, c.id, c.client_code, c.name
    ORDER BY c.client_code, j.job_number;`);
  console.log(`${jobs.length} Service Agreement job(s) with a frequency:\n`);

  const toInsert = [];
  for (const job of jobs) {
    const existing = await pg(`SELECT visit_date::text AS visit_date, visit_status FROM visits
      WHERE job_id = ${job.job_id} AND deleted_at IS NULL ORDER BY visit_date;`);
    const lastCompleted = (await pg(`SELECT max(visit_date)::text AS d FROM visits
      WHERE client_id = ${job.client_id} AND visit_status = 'completed' AND deleted_at IS NULL;`))[0].d;

    const maxScheduledFuture = existing
      .filter(v => v.visit_status === 'scheduled' && v.visit_date >= today)
      .reduce((mx, v) => v.visit_date > mx ? v.visit_date : mx, '');

    let anchor, anchorSrc;
    if (maxScheduledFuture) { anchor = addDays(maxScheduledFuture, job.frequency_days); anchorSrc = 'job_scheduled+freq'; }
    else if (lastCompleted) { anchor = addDays(lastCompleted, job.frequency_days); anchorSrc = 'client_completed+freq'; }
    else { anchor = addDays(today, job.frequency_days); anchorSrc = 'today+freq'; }

    const dates = [];
    let cur = anchor, safety = 0;
    while (safety++ < 2000 && cur <= horizonEnd && dates.length < MAX_PER_JOB) {
      if (cur < today) { cur = addDays(cur, job.frequency_days); continue; }
      dates.push(cur);
      cur = addDays(cur, job.frequency_days);
    }
    const fresh = dates.filter(d => !existing.some(v => Math.abs(diffDays(v.visit_date, d)) <= IDEMPOTENCY_TOLERANCE_DAYS));

    console.log(`#${job.job_number} "${job.title}" (db job ${job.job_id}) freq=${job.frequency_days}d type=${job.service_type} derm=${job.derm_required}`);
    console.log(`   anchor=${anchor} (${anchorSrc}) | lastCompleted=${lastCompleted || 'none'} | existing=${existing.length} | generate=${fresh.length}`);
    fresh.forEach(d => console.log(`     + ${d}`));

    for (const d of fresh) {
      toInsert.push({ client_id: job.client_id, job_id: job.job_id, visit_date: d,
        visit_status: 'scheduled', source: 'supabase_cron', title: job.title,
        service_type: job.service_type, derm_required: job.derm_required });
    }
  }

  console.log(`\n${EXECUTE ? 'Inserting' : 'DRY-RUN — would insert'} ${toInsert.length} visit(s).`);
  if (EXECUTE && toInsert.length) {
    for (let i = 0; i < toInsert.length; i += 500) {
      await rest('/visits', { method: 'POST', headers: { Prefer: 'return=minimal', 'X-App-Source': 'service-agreement-cron' }, body: JSON.stringify(toInsert.slice(i, i + 500)) });
    }
    console.log(`✓ inserted ${toInsert.length}`);
  }

  // ---- CLEANUP: soft-delete future cron visits whose SA job no longer qualifies --------------
  // Catches SAs that were archived/deleted, had their Frequency removed, were retitled/[OLD]-tagged,
  // or whose client was set inactive. Soft-delete (deleted_at) fires trg_push_visit_update ->
  // jobber-push-visit -> visitDelete, so the visit is removed from Jobber too. Only future,
  // source='supabase_cron' visits are ever touched — never a manual/Jobber visit or a past one.
  // Runs only on the full daily run (--all), never a single --client run. Guardrail: if it would
  // remove more than MAX_CLEANUP, ABORT and alert — a large count signals a data issue (e.g. a sync
  // wrongly flipping many clients inactive), and mass-deleting visits is worse than leaving them.
  if (ALL) {
    const stale = await pg(`SELECT v.id FROM visits v
      WHERE v.source = 'supabase_cron' AND v.deleted_at IS NULL AND v.visit_date >= '${today}'
        AND NOT EXISTS (SELECT 1 FROM jobs j JOIN clients c ON c.id = j.client_id
                        WHERE j.id = v.job_id AND ${JOB_PREDICATE})`);
    const staleIds = stale.map(r => r.id);
    console.log(`\nCleanup: ${staleIds.length} stale cron future visit(s) (SA archived/deleted/freq-removed/[OLD]/inactive).`);
    if (EXECUTE && staleIds.length) {
      if (staleIds.length > MAX_CLEANUP) {
        console.error(`⚠ CLEANUP ABORTED: ${staleIds.length} stale > MAX_CLEANUP=${MAX_CLEANUP} — likely a bulk data issue. Not deleting; investigate.`);
        process.exitCode = 1;
      } else {
        for (let i = 0; i < staleIds.length; i += 200) {
          const chunk = staleIds.slice(i, i + 200);
          await rest(`/visits?id=in.(${chunk.join(',')})`, { method: 'PATCH', headers: { Prefer: 'return=minimal', 'X-App-Source': 'service-agreement-cron' }, body: JSON.stringify({ deleted_at: new Date().toISOString() }) });
        }
        console.log(`✓ soft-deleted ${staleIds.length} stale visit(s) — visitDelete pushed to Jobber`);
      }
    }
  }
})().catch(e => { console.error('FATAL', e.message, e.stack); process.exit(1); });
