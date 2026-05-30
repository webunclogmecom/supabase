// ============================================================================
// cron_generate_recurring_visits.js
// ============================================================================
// Supabase-native recurring visit schedule generator. Replaces the Airtable
// button-triggered visit-generation flow that's being sunset May 2026.
//
// What it does
//   For every client with status IN ('ACTIVE','RECURRING') and a service_configs
//   row with frequency_days > 0:
//     - Compute the chain anchor (Option D precedence below)
//     - Generate visit dates forward until BOTH:
//         (a) end of the WINDOW_MONTHS_AHEAD'th calendar month is reached
//             (rolling window — e.g. with WINDOW_MONTHS_AHEAD=3 on 2026-05-12,
//             window covers rest of May + Jun + Jul + Aug → 2026-08-31), AND
//         (b) at least 1 future visit exists for this client+service
//     - For each candidate date, check idempotency: a visit with the same
//       client_id + service_type + visit_date within ±7d already exists?
//       If yes → skip. If no → INSERT with source='supabase_cron',
//       visit_status='scheduled'.
//
// Anchor precedence (simplified 2026-05-13 — dropped first_visit per Fred)
//   1. MAX(visit_date) among visits with status='scheduled' AND visit_date >= today
//      → if found, anchor = that + frequency  (extend existing chain)
//   2. else MAX(visit_date) among visits with status='completed'
//      → if found, anchor = that + frequency  (resume cadence from last real service)
//   3. else today + frequency  (cold start — never had a visit, kick off the cadence)
//
// What changed and why:
//   Earlier versions used service_configs.first_visit as a fallback anchor
//   before "today + freq". That came from AT's `GT First Visit Date` field,
//   which AT uses as a one-shot "start generating next N visits from this
//   date" trigger — NOT a cadence anchor. Worst case: 175-PV Pura Vida
//   Brickell had first_visit=2028-11-29 in AT (typo), which made our cron
//   try to anchor visits 2.5 years in the future. Dropping this rule makes
//   the logic depend only on real visit history (scheduled or completed).
//   first_visit stays as a column on service_configs (still useful info)
//   but is no longer consulted by the generator.
//
// Idempotency
//   ±7 day tolerance window when checking for existing matching visits across
//   ALL sources (supabase_cron, jobber, airtable). This catches both:
//     - Re-runs of this cron (won't duplicate its own previous output)
//     - Visits already created elsewhere (Jobber, legacy Airtable mirror)
//
// Interaction with cron_jobber and webhook-jobber
//   Visits we create here have source='supabase_cron' and visit_status='scheduled'.
//   When the office later creates a matching visit in Jobber (manually mirroring
//   the schedule), cron_jobber → webhook-jobber.handleVisit will MERGE: find
//   the matching supabase_cron row and PROMOTE it (UPDATE in place with the
//   Jobber GID + source='jobber'), instead of inserting a duplicate.
//   (Merge logic lives in webhook-jobber, not here.)
//
// INACTIVE clients
//   Filtered out at SELECT time (status IN 'ACTIVE','RECURRING' only).
//   Additionally, the trg_clients_wipe_upcoming_on_inactive Postgres trigger
//   auto-deletes a client's scheduled visits if they flip to INACTIVE/PAUSED
//   in mid-day; the cron won't re-create them next morning because the filter
//   excludes them.
//
// LS service type
//   Recognized as a valid service category. If a client has a service_configs
//   row with service_type='LS' and frequency_days > 0, LS visits get generated
//   just like GT/CL/WD.
//
// CLI
//   node scripts/sync/cron_generate_recurring_visits.js               # full run
//   node scripts/sync/cron_generate_recurring_visits.js --dry-run     # no writes
//   node scripts/sync/cron_generate_recurring_visits.js --client=NNN-XXX  # one client
//   node scripts/sync/cron_generate_recurring_visits.js --service=GT  # one service type
// ============================================================================

const https = require('https');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') }); } catch (_) {}

const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;

if (!SUPABASE_URL || !SVC) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY required');

const DRY_RUN = process.argv.includes('--dry-run');
const clientArg = process.argv.find(a => a.startsWith('--client='));
const FILTER_CLIENT = clientArg ? clientArg.split('=')[1] : null;
const serviceArg = process.argv.find(a => a.startsWith('--service='));
const FILTER_SERVICE = serviceArg ? serviceArg.split('=')[1].toUpperCase() : null;

const IDEMPOTENCY_TOLERANCE_DAYS = 7;
const ALLOWED_CLIENT_STATUSES = ['ACTIVE', 'RECURRING'];
const ALLOWED_SERVICE_TYPES = ['GT', 'CL', 'WD', 'LS'];
// Test / non-serviced accounts that must NEVER auto-generate visits, even
// though they're kept ACTIVE for app-testing purposes. (112-YA "Yan's
// Restaurant" is Yan's test account — confirmed by Fred 2026-05-30.)
const EXCLUDED_CLIENT_CODES = ['112-YA'];
// Visit-generation window: rest of current month + next N calendar months.
// 2026-05-12: bumped from 2 → 3 months per Fred's request — gives ops a
// rolling quarter of upcoming visibility once Yannick's view ships.
const WINDOW_MONTHS_AHEAD = 3;

// Self-maintenance cleanup (added 2026-05-30). Soft-delete our OWN
// supabase_cron scheduled placeholders that are > STALE_AGE_DAYS past and were
// never completed/promoted. Jobber-sourced stale/orphan visits are NOT touched
// here — cron_jobber_reconcile_anomalies.js owns those. STALE_CLEANUP_MAX is a
// circuit-breaker: if a single run would soft-delete more than this, it ABORTS
// (deletes nothing) and logs a warning, so a logic bug can't silently wipe the
// schedule. In steady state (daily run) only a handful go stale per day.
const STALE_AGE_DAYS = 14;
const STALE_CLEANUP_MAX = 50;

// ---- tiny HTTP helpers ------------------------------------------------------

function http(opts, body) {
  return new Promise((res, rej) => {
    const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
    const req = https.request({
      ...opts,
      headers: { ...opts.headers, ...(payload ? { 'Content-Length': Buffer.byteLength(payload) } : {}) },
    }, (r) => {
      const chunks = []; r.on('data', c => chunks.push(c));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(chunks).toString() }));
    });
    req.on('error', rej);
    req.setTimeout(60000, () => req.destroy(new Error('timeout')));
    if (payload) req.write(payload);
    req.end();
  });
}

async function pg(sql, _retry = 0) {
  if (!PAT || !PROJECT) throw new Error('SUPABASE_PAT and SUPABASE_PROJECT_ID required');
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${PROJECT}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  if ((r.status === 429 || (r.status >= 500 && r.status < 600)) && _retry < 5) {
    const waitMs = Math.min(60_000, 2_000 * Math.pow(2, _retry));
    await new Promise(rs => setTimeout(rs, waitMs));
    return pg(sql, _retry + 1);
  }
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 300)}`);
  return JSON.parse(r.body);
}

async function rest(path, opts = {}) {
  const u = new URL(SUPABASE_URL + '/rest/v1' + path);
  const r = await http({
    hostname: u.hostname,
    path: u.pathname + u.search,
    method: opts.method || 'GET',
    headers: { apikey: SVC, Authorization: `Bearer ${SVC}`, 'Content-Type': 'application/json', ...(opts.headers || {}) },
  }, opts.body);
  if (r.status >= 300) throw new Error(`REST ${path} → ${r.status}: ${r.body.slice(0, 300)}`);
  return r.body ? JSON.parse(r.body) : null;
}

// ---- date math --------------------------------------------------------------

// All dates are ISO 'YYYY-MM-DD' strings, no time component. We treat them as
// calendar dates in ET, which is what visit_date is conceptually.
function toISODate(d) {
  if (typeof d === 'string') return d.slice(0, 10);
  return d.toISOString().slice(0, 10);
}
function addDays(isoDate, days) {
  const [y, m, d] = isoDate.split('-').map(Number);
  const date = new Date(Date.UTC(y, m - 1, d));
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}
function diffDays(isoA, isoB) {
  const [ya, ma, da] = isoA.split('-').map(Number);
  const [yb, mb, db] = isoB.split('-').map(Number);
  const a = Date.UTC(ya, ma - 1, da);
  const b = Date.UTC(yb, mb - 1, db);
  return Math.round((a - b) / (1000 * 60 * 60 * 24));
}
function todayET() {
  // ET is UTC-4 in EDT (May–Oct) and UTC-5 in EST (Nov–Mar). For visit_date
  // purposes we want "today on the calendar in Miami". Use Intl to format.
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/New_York',
    year: 'numeric', month: '2-digit', day: '2-digit',
  });
  return fmt.format(new Date()); // returns 'YYYY-MM-DD'
}
function endOfWindowMonth(isoToday) {
  // WINDOW_MONTHS_AHEAD: number of full calendar months past the current one
  // that should be covered. e.g. WINDOW_MONTHS_AHEAD=3, today=2026-05-12 →
  // window includes May (rest of) + Jun + Jul + Aug → end = 2026-08-31.
  // Day 0 of month+WINDOW+1 = last day of month+WINDOW.
  const [y, m] = isoToday.split('-').map(Number);
  const date = new Date(Date.UTC(y, m + WINDOW_MONTHS_AHEAD, 0));
  return date.toISOString().slice(0, 10);
}

// ---- main -------------------------------------------------------------------

(async () => {
  const startedAt = new Date();
  const today = todayET();
  const windowEnd = endOfWindowMonth(today);

  console.log(`\n╔══════════════════════════════════════════════════════════════╗`);
  console.log(`║  cron_generate_recurring_visits — ${DRY_RUN ? 'DRY-RUN' : 'EXECUTE'.padEnd(7)}                  ║`);
  console.log(`║  Today (ET):    ${today.padEnd(46)} ║`);
  console.log(`║  Window end:    ${windowEnd.padEnd(46)} ║`);
  console.log(`║  Min visits:    1 per (client × service) even past window     ║`);
  console.log(`║  Tolerance:     ±${IDEMPOTENCY_TOLERANCE_DAYS} days                                       ║`);
  if (FILTER_CLIENT) console.log(`║  Client filter: ${FILTER_CLIENT.padEnd(46)} ║`);
  if (FILTER_SERVICE) console.log(`║  Service filter:${FILTER_SERVICE.padEnd(46)} ║`);
  console.log(`╚══════════════════════════════════════════════════════════════╝\n`);

  // 0. Stale-placeholder cleanup (self-maintenance). Runs BEFORE generation so
  //    the same run re-anchors affected clients forward off their last completed
  //    visit. Scoped to source='supabase_cron' only (Jobber-side handled by
  //    cron_jobber_reconcile_anomalies.js). Guarded by STALE_CLEANUP_MAX.
  console.log('[0/5] Stale supabase_cron placeholder cleanup...');
  const staleCutoff = addDays(today, -STALE_AGE_DAYS);
  const staleRows = await pg(`
    SELECT id FROM visits
    WHERE source = 'supabase_cron'
      AND visit_status = 'scheduled'
      AND deleted_at IS NULL
      AND visit_date < '${staleCutoff}';
  `);
  let staleSoftDeleted = 0;
  let staleAborted = false;
  if (staleRows.length === 0) {
    console.log(`  none older than ${STALE_AGE_DAYS}d to clean`);
  } else if (staleRows.length > STALE_CLEANUP_MAX) {
    staleAborted = true;
    console.warn(`  ⚠ ABORT: ${staleRows.length} stale placeholders exceeds cap ${STALE_CLEANUP_MAX}. Deleting NONE — investigate before next run.`);
  } else if (DRY_RUN) {
    console.log(`  (DRY-RUN — would soft-delete ${staleRows.length} placeholder(s) dated < ${staleCutoff})`);
  } else {
    const ids = staleRows.map(r => r.id);
    await rest(`/visits?id=in.(${ids.join(',')})`, {
      method: 'PATCH',
      headers: { Prefer: 'return=minimal', 'X-App-Source': 'recurring-visits-cron' },
      body: JSON.stringify({ deleted_at: new Date().toISOString() }),
    });
    staleSoftDeleted = ids.length;
    console.log(`  ✓ soft-deleted ${staleSoftDeleted} stale placeholder(s) dated < ${staleCutoff}`);
  }

  // 1. Pull all candidate (client, service_config) pairs in one query.
  console.log('\n[1/5] Loading candidate client × service rows...');
  const filterClient = FILTER_CLIENT ? `AND c.client_code = '${FILTER_CLIENT.replace(/'/g, "''")}'` : '';
  const filterService = FILTER_SERVICE ? `AND sc.service_type = '${FILTER_SERVICE}'` : '';
  const filterExcluded = EXCLUDED_CLIENT_CODES.length
    ? `AND (c.client_code IS NULL OR c.client_code NOT IN (${EXCLUDED_CLIENT_CODES.map(s => `'${s.replace(/'/g, "''")}'`).join(',')}))`
    : '';
  const candidates = await pg(`
    SELECT
      c.id AS client_id,
      c.client_code,
      c.name AS client_name,
      c.status AS client_status,
      sc.service_type,
      sc.frequency_days
    FROM clients c
    JOIN service_configs sc ON sc.client_id = c.id
    WHERE c.status IN (${ALLOWED_CLIENT_STATUSES.map(s => `'${s}'`).join(',')})
      AND sc.service_type IN (${ALLOWED_SERVICE_TYPES.map(s => `'${s}'`).join(',')})
      AND sc.frequency_days > 0
      ${filterClient}
      ${filterService}
      ${filterExcluded}
    ORDER BY c.client_code, sc.service_type;
  `);
  console.log(`  ${candidates.length} (client × service) rows`);

  // 2. For each candidate, compute the chain and figure out what's missing.
  console.log('\n[2/4] Computing schedule + idempotency check per (client × service)...');
  const toInsert = [];
  const summary = {
    skipped_no_anchor: 0,
    skipped_window_met: 0,
    generated_in_window: 0,
    generated_min_count_only: 0,
  };
  for (const c of candidates) {
    // Read existing visits for this (client, service)
    // deleted_at IS NULL added 2026-05-30: the soft-delete column (2026-05-29)
    // postdates this script. Without the filter, a visit Jobber reported as
    // "not found" (soft-deleted by cron_jobber_reconcile_anomalies) would still
    // skew both the anchor (line ~245) and the ±7d idempotency check (line ~288),
    // suppressing a legitimately-needed regeneration. We only anchor/dedup
    // against live visits.
    const existing = await pg(`
      SELECT visit_date::text AS visit_date, visit_status, source
      FROM visits
      WHERE client_id = ${c.client_id}
        AND service_type = '${c.service_type}'
        AND visit_status IN ('completed','scheduled','late','today')
        AND deleted_at IS NULL
      ORDER BY visit_date;
    `);

    // Compute anchor candidates
    const maxScheduledFuture = existing
      .filter(v => (v.visit_status === 'scheduled' || v.visit_status === 'late' || v.visit_status === 'today') && v.visit_date >= today)
      .reduce((mx, v) => v.visit_date > mx ? v.visit_date : mx, '');
    const maxCompleted = existing
      .filter(v => v.visit_status === 'completed')
      .reduce((mx, v) => v.visit_date > mx ? v.visit_date : mx, '');

    let anchor = null;
    let anchorSource = null;
    if (maxScheduledFuture) {
      anchor = addDays(maxScheduledFuture, c.frequency_days);
      anchorSource = 'max_scheduled+freq';
    } else if (maxCompleted) {
      anchor = addDays(maxCompleted, c.frequency_days);
      anchorSource = 'max_completed+freq';
    } else {
      // Cold start — no scheduled OR completed visits for this (client, service).
      // first_visit was dropped from this chain 2026-05-13 (AT field semantics
      // didn't match cadence-anchor semantics; one client had a 2028 typo).
      anchor = addDays(today, c.frequency_days);
      anchorSource = 'today+freq';
    }

    // Generate dates forward
    const datesToGenerate = [];
    let cur = anchor;
    let safety = 0; // hard cap to prevent runaway loops
    while (safety++ < 1000) {
      const inWindow = cur <= windowEnd;
      const haveMinCount = datesToGenerate.length + existing.filter(v => v.visit_date >= today).length >= 1;
      if (!inWindow && haveMinCount) break;
      if (cur < today) { cur = addDays(cur, c.frequency_days); continue; }
      datesToGenerate.push(cur);
      if (datesToGenerate.length >= 24) break; // hard cap: max 24 visits per (client × service) per run
      cur = addDays(cur, c.frequency_days);
    }
    if (safety >= 1000) console.warn(`  ⚠ ${c.client_code} ${c.service_type}: safety cap hit`);

    if (datesToGenerate.length === 0) { summary.skipped_window_met++; continue; }

    // Idempotency: skip any date that already has a visit within ±7d
    const matched = [];
    for (const d of datesToGenerate) {
      const conflict = existing.find(v =>
        Math.abs(diffDays(v.visit_date, d)) <= IDEMPOTENCY_TOLERANCE_DAYS
      );
      if (!conflict) matched.push(d);
    }
    if (matched.length === 0) { summary.skipped_window_met++; continue; }

    for (const d of matched) {
      toInsert.push({
        client_id: c.client_id,
        service_type: c.service_type,
        visit_date: d,
        visit_status: 'scheduled',
        source: 'supabase_cron',
        title: `${c.client_code || c.client_name || 'Client'} - Scheduled ${c.service_type}`,
      });
    }
    if (matched.some(d => d <= windowEnd)) summary.generated_in_window += matched.filter(d => d <= windowEnd).length;
    if (matched.some(d => d > windowEnd)) summary.generated_min_count_only += matched.filter(d => d > windowEnd).length;
  }

  console.log(`  Pairs processed:                ${candidates.length}`);
  console.log(`  Pairs skipped (window already met): ${summary.skipped_window_met}`);
  console.log(`  Visits to insert:               ${toInsert.length}`);
  console.log(`    within window (this+next month): ${summary.generated_in_window}`);
  console.log(`    min-count beyond window:         ${summary.generated_min_count_only}`);

  // 3. Insert (or dry-run preview)
  console.log(`\n[3/4] ${DRY_RUN ? 'DRY-RUN — would insert' : 'Inserting'} ${toInsert.length} visits...`);
  if (toInsert.length > 0 && toInsert.length <= 20) {
    console.log('  Sample:');
    for (const v of toInsert.slice(0, 10)) {
      console.log(`    ${v.visit_date}  ${v.service_type}  ${v.title}`);
    }
    if (toInsert.length > 10) console.log(`    ... +${toInsert.length - 10} more`);
  } else if (toInsert.length > 20) {
    console.log('  First 5:');
    for (const v of toInsert.slice(0, 5)) console.log(`    ${v.visit_date}  ${v.service_type}  ${v.title}`);
    console.log('  Last 5:');
    for (const v of toInsert.slice(-5)) console.log(`    ${v.visit_date}  ${v.service_type}  ${v.title}`);
  }

  let inserted = 0;
  if (!DRY_RUN && toInsert.length > 0) {
    // Batch in chunks of 500 to stay safe on REST payload
    for (let i = 0; i < toInsert.length; i += 500) {
      const chunk = toInsert.slice(i, i + 500);
      await rest(`/visits`, { method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify(chunk) });
      inserted += chunk.length;
    }
    console.log(`  ✓ ${inserted} rows inserted`);
  }

  // 4. Write sync_log entry
  console.log(`\n[4/4] Writing sync_log entry...`);
  if (!DRY_RUN) {
    const finishedAt = new Date();
    const durationMs = finishedAt - startedAt;
    const logRow = {
      job_name: 'generate_recurring_visits',
      source_system: 'supabase',
      status: staleAborted ? 'warning' : 'success',
      started_at: startedAt.toISOString(),
      finished_at: finishedAt.toISOString(),
      records_processed: candidates.length,
      records_succeeded: inserted,
      details: {
        today, window_end: windowEnd,
        visits_inserted: inserted,
        within_window: summary.generated_in_window,
        min_count_beyond_window: summary.generated_min_count_only,
        pairs_skipped_window_met: summary.skipped_window_met,
        stale_soft_deleted: staleSoftDeleted,
        stale_cleanup_aborted: staleAborted,
        stale_cleanup_cap: STALE_CLEANUP_MAX,
        duration_ms: durationMs,
      },
    };
    try {
      await rest(`/sync_log`, { method: 'POST', headers: { Prefer: 'return=minimal' }, body: JSON.stringify(logRow) });
      console.log('  ✓ sync_log row written');
    } catch (e) {
      console.warn(`  ⚠ sync_log write failed (non-fatal): ${e.message.slice(0, 150)}`);
    }
  } else {
    console.log('  (DRY-RUN — skipping sync_log)');
  }

  console.log(`\n${'═'.repeat(64)}`);
  console.log(`  Done. ${DRY_RUN ? 'Would insert' : 'Inserted'} ${DRY_RUN ? toInsert.length : inserted} visits` +
    `; cleanup ${staleAborted ? 'ABORTED (over cap)' : (DRY_RUN ? `would remove ${staleRows.length}` : `removed ${staleSoftDeleted}`)}` +
    ` in ${Math.round((Date.now() - startedAt) / 1000)}s.`);
  console.log(`${'═'.repeat(64)}\n`);
})().catch(e => { console.error('FATAL:', e.message, e.stack); process.exit(1); });
