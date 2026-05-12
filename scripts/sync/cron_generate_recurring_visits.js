// ============================================================================
// cron_generate_recurring_visits.js
// ============================================================================
// Supabase-native recurring visit schedule generator. Replaces the Airtable
// button-triggered visit-generation flow that's being sunset May 2026.
//
// What it does
//   For every client with status IN ('ACTIVE','Recuring') and a service_configs
//   row with frequency_days > 0:
//     - Compute the chain anchor (Option D precedence below)
//     - Generate visit dates forward until BOTH:
//         (a) end of next calendar month is reached, AND
//         (b) at least 1 future visit exists for this client+service
//     - For each candidate date, check idempotency: a visit with the same
//       client_id + service_type + visit_date within ±7d already exists?
//       If yes → skip. If no → INSERT with source='supabase_cron',
//       visit_status='scheduled'.
//
// Anchor precedence (Option D, confirmed with Fred 2026-05-12)
//   1. MAX(visit_date) among visits with status='scheduled' AND visit_date >= today
//      → if found, anchor = that + frequency  (extend existing chain)
//   2. else MAX(visit_date) among visits with status='completed'
//      → if found, anchor = that + frequency  (anchor from history)
//   3. else service_configs.first_visit
//      → if found, anchor = that  (initial anchor for new clients)
//   4. else today + frequency  (last resort; defer first visit by one cycle)
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
//   Filtered out at SELECT time (status IN 'ACTIVE','Recuring' only).
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
const ALLOWED_CLIENT_STATUSES = ['ACTIVE', 'Recuring'];
const ALLOWED_SERVICE_TYPES = ['GT', 'CL', 'WD', 'LS'];

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
function endOfNextMonth(isoToday) {
  const [y, m] = isoToday.split('-').map(Number);
  // Day 0 of month+2 = last day of month+1
  const date = new Date(Date.UTC(y, m + 1, 0)); // m is already 1-indexed; +1 = next month; 0 = last day of prior
  // (e.g., today m=5 → new Date(Date.UTC(y, 6, 0)) = last day of June = correct)
  return date.toISOString().slice(0, 10);
}

// ---- main -------------------------------------------------------------------

(async () => {
  const startedAt = new Date();
  const today = todayET();
  const windowEnd = endOfNextMonth(today);

  console.log(`\n╔══════════════════════════════════════════════════════════════╗`);
  console.log(`║  cron_generate_recurring_visits — ${DRY_RUN ? 'DRY-RUN' : 'EXECUTE'.padEnd(7)}                  ║`);
  console.log(`║  Today (ET):    ${today.padEnd(46)} ║`);
  console.log(`║  Window end:    ${windowEnd.padEnd(46)} ║`);
  console.log(`║  Min visits:    1 per (client × service) even past window     ║`);
  console.log(`║  Tolerance:     ±${IDEMPOTENCY_TOLERANCE_DAYS} days                                       ║`);
  if (FILTER_CLIENT) console.log(`║  Client filter: ${FILTER_CLIENT.padEnd(46)} ║`);
  if (FILTER_SERVICE) console.log(`║  Service filter:${FILTER_SERVICE.padEnd(46)} ║`);
  console.log(`╚══════════════════════════════════════════════════════════════╝\n`);

  // 1. Pull all candidate (client, service_config) pairs in one query.
  console.log('[1/4] Loading candidate client × service rows...');
  const filterClient = FILTER_CLIENT ? `AND c.client_code = '${FILTER_CLIENT.replace(/'/g, "''")}'` : '';
  const filterService = FILTER_SERVICE ? `AND sc.service_type = '${FILTER_SERVICE}'` : '';
  const candidates = await pg(`
    SELECT
      c.id AS client_id,
      c.client_code,
      c.name AS client_name,
      c.status AS client_status,
      sc.service_type,
      sc.frequency_days,
      sc.first_visit::text AS first_visit
    FROM clients c
    JOIN service_configs sc ON sc.client_id = c.id
    WHERE c.status IN (${ALLOWED_CLIENT_STATUSES.map(s => `'${s}'`).join(',')})
      AND sc.service_type IN (${ALLOWED_SERVICE_TYPES.map(s => `'${s}'`).join(',')})
      AND sc.frequency_days > 0
      ${filterClient}
      ${filterService}
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
    const existing = await pg(`
      SELECT visit_date::text AS visit_date, visit_status, source
      FROM visits
      WHERE client_id = ${c.client_id}
        AND service_type = '${c.service_type}'
        AND visit_status IN ('completed','scheduled','late','today')
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
    } else if (c.first_visit) {
      anchor = c.first_visit;
      anchorSource = 'first_visit';
    } else {
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
      status: 'success',
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
  console.log(`  Done. ${DRY_RUN ? 'Would insert' : 'Inserted'} ${DRY_RUN ? toInsert.length : inserted} visits in ${Math.round((Date.now() - startedAt) / 1000)}s.`);
  console.log(`${'═'.repeat(64)}\n`);
})().catch(e => { console.error('FATAL:', e.message, e.stack); process.exit(1); });
