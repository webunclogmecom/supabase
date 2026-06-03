// ============================================================================
// reconcile_jobber_visits.js  —  ONE-TIME Jobber->DB visit reconciliation
// ----------------------------------------------------------------------------
// Visits are DECOUPLED from Jobber (Calendar app = source of truth; Jobber
// VISIT_* inbound is no-op'd via handleVisitInboundDisabled). The office still
// sometimes creates visits directly in Jobber, which then never reach our DB.
// This is a MANUAL, one-off reconciliation: fetch Jobber visits for a window,
// diff against our DB by Jobber visit GID, and (with --execute) insert the
// missing ones as source='jobber' + link the GID.
//
// It does NOT re-enable inbound and does NOT route through the no-op'd webhook.
// Inserted rows are source='jobber', so the Calendar->Jobber push trigger
// (fires only for visit-calendar / supabase_cron) skips them — no echo back.
// Idempotent: GID already linked => skipped.
//
// Field construction mirrors webhook-jobber handleVisit() (the canonical
// ingester) EXACTLY, verified 2026-06-04:
//   visit_date  = (startAt ?? endAt ?? completedAt).slice(0,10)   [UTC date]
//   title       = raw Jobber visit title
//   service_type= inferServiceType(title)
//   visit_status= statusMap[visitStatus] ?? 'scheduled'
//   start_at/end_at/completed_at/completed_by stored as-is
//   client/job/property resolved via job.client / job.id / job.property
//   112-YA (test client) EXCLUDED, same as the webhook
//
// CLI:
//   node scripts/sync/reconcile_jobber_visits.js                 # DRY-RUN, this week
//   node scripts/sync/reconcile_jobber_visits.js --execute       # insert missing
//   node scripts/sync/reconcile_jobber_visits.js --window-start=2026-06-01 --window-end=2026-06-08
// ============================================================================

const https = require('https');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') }); } catch (_) {}
const { gql } = require('./lib/jobber');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
if (!SUPABASE_URL || !SVC || !PROJECT || !PAT) throw new Error('SUPABASE_URL/SERVICE_ROLE_KEY/PROJECT_ID/PAT required');

const EXECUTE = process.argv.includes('--execute');
const arg = (k, d) => { const a = process.argv.find(x => x.startsWith(`--${k}=`)); return a ? a.split('=')[1] : d; };
const WINDOW_START = arg('window-start', '2026-06-01');
const WINDOW_END   = arg('window-end', '2026-06-08');
const FETCH_SINCE  = `${WINDOW_START}T00:00:00Z`;
const FETCH_UNTIL  = arg('until', null) ||
  new Date(Date.UTC(+WINDOW_END.slice(0,4), +WINDOW_END.slice(5,7)-1, +WINDOW_END.slice(8,10)) + 2*86400000).toISOString();

// 112-YA Yan's Restaurant — test client, excluded from Jobber inbound (matches webhook-jobber)
const EXCLUDED_CLIENT_GIDS = new Set(['Z2lkOi8vSm9iYmVyL0NsaWVudC8xMDY1Njc0MDQ=']);

// ---- status + service_type derivation (copied verbatim from webhook-jobber) -
const statusMap = { completed: 'completed', requires_invoicing: 'completed', upcoming: 'scheduled',
  today: 'scheduled', late: 'scheduled', unscheduled: 'scheduled', approved: 'scheduled', unvisited: 'scheduled' };
function inferServiceType(title) {
  if (!title) return null;
  const t = title.toLowerCase();
  if (/lyft\s*station/.test(t)) return 'LS';
  if (/grease trap|grease pump|grey water|gray water|\bgt\b/.test(t)) return 'GT';
  if (/service call|\bclog|emergency|hydrojet|\bdrain|\briser|fire pump|warranty|\brepair/.test(t)) return 'CL';
  if (/\bservice\b/.test(t) && !/dump/.test(t)) return 'CL';
  return null;
}

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
async function pg(sql) {
  const r = await http({ hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT}/database/query`, method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' } }, JSON.stringify({ query: sql }));
  if (r.status >= 300) throw new Error(`PG ${r.status}: ${r.body.slice(0, 300)}`);
  return JSON.parse(r.body);
}
async function rest(path, opts = {}) {
  const u = new URL(SUPABASE_URL + '/rest/v1' + path);
  const r = await http({ hostname: u.hostname, path: u.pathname + u.search, method: opts.method || 'GET',
    headers: { apikey: SVC, Authorization: `Bearer ${SVC}`, 'Content-Type': 'application/json', 'X-App-Source': 'jobber-reconcile', ...(opts.headers || {}) } }, opts.body);
  if (r.status >= 300) throw new Error(`REST ${path} -> ${r.status}: ${r.body.slice(0, 300)}`);
  return r.body ? JSON.parse(r.body) : null;
}
const utcDate = iso => (iso ? iso.slice(0, 10) : null);

// ---- Jobber fetch -----------------------------------------------------------
const Q = `query V($after:String,$first:Int!,$filter:VisitFilterAttributes){
  visits(after:$after, first:$first, filter:$filter){
    pageInfo{ hasNextPage endCursor }
    nodes{ id title startAt endAt completedAt completedBy visitStatus
           client{ id } job{ id client{ id } property{ id } } }
  }
}`;
async function fetchJobberVisits() {
  const filter = { startAt: { after: FETCH_SINCE, before: FETCH_UNTIL } };
  const out = []; let cursor = null, page = 0;
  while (page < 80) {
    page++;
    const d = await gql(Q, { after: cursor, first: 50, filter });
    const conn = d.visits; if (!conn) break;
    out.push(...conn.nodes);
    if (!conn.pageInfo.hasNextPage) break;
    cursor = conn.pageInfo.endCursor;
  }
  return out;
}

// ---- main -------------------------------------------------------------------
(async () => {
  console.log(`reconcile_jobber_visits — ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}`);
  console.log(`window (visit_date, UTC): ${WINDOW_START} .. ${WINDOW_END}`);
  console.log(`Jobber fetch (UTC startAt): ${FETCH_SINCE} .. ${FETCH_UNTIL}\n`);

  // 1. DB lookup maps (bounded entity types only)
  const linkRows = await pg(`SELECT entity_type, source_id, entity_id FROM entity_source_links WHERE source_system='jobber' AND entity_type IN ('visit','client','job','property')`);
  const visitGid = new Set(), clientByGid = new Map(), jobByGid = new Map(), propByGid = new Map();
  for (const r of linkRows) {
    if (r.entity_type === 'visit') visitGid.add(r.source_id);
    else if (r.entity_type === 'client') clientByGid.set(r.source_id, r.entity_id);
    else if (r.entity_type === 'job') jobByGid.set(r.source_id, r.entity_id);
    else if (r.entity_type === 'property') propByGid.set(r.source_id, r.entity_id);
  }
  const clients = await pg(`SELECT id, client_code, name FROM clients`);
  const clientMeta = new Map(clients.map(c => [c.id, c]));
  const existing = await pg(`SELECT esl.source_id AS gid, v.id AS visit_id, v.client_id, v.visit_date::text AS vdate, v.source
    FROM visits v JOIN entity_source_links esl ON esl.entity_type='visit' AND esl.source_system='jobber' AND esl.entity_id=v.id
    WHERE v.visit_date BETWEEN '${WINDOW_START}' AND '${WINDOW_END}' AND v.deleted_at IS NULL`);
  const existingByGid = new Map(existing.map(r => [r.gid, r]));
  const existingByClientDate = new Set(existing.map(r => `${r.client_id}|${r.vdate}`));
  console.log(`DB: ${visitGid.size} jobber-linked visits · ${clientByGid.size} clients · ${jobByGid.size} jobs · ${propByGid.size} properties linked.`);

  // 2. Fetch Jobber visits
  const jv = await fetchJobberVisits();
  console.log(`Jobber: pulled ${jv.length} visits in fetch window.\n`);

  // 3. Classify
  const missing = [], unlinkedClient = [], excluded = [], drift = [];
  let known = 0, outOfWindow = 0, preYear = 0;
  for (const v of jv) {
    const vdate = utcDate(v.startAt ?? v.endAt ?? v.completedAt);
    if (!vdate) continue;
    if (vdate < '2026-01-01') { preYear++; continue; }
    if (vdate < WINDOW_START || vdate > WINDOW_END) { outOfWindow++; continue; }
    const clientGid = v.job?.client?.id ?? v.client?.id ?? null;
    if (clientGid && EXCLUDED_CLIENT_GIDS.has(clientGid)) { excluded.push(v); continue; }
    if (visitGid.has(v.id)) {
      known++;
      const ex = existingByGid.get(v.id);
      if (ex && ex.vdate !== vdate) drift.push({ gid: v.id, visit_id: ex.visit_id, stored: ex.vdate, jobber: vdate, start_at: v.startAt || null, end_at: v.endAt || null, source: ex.source });
      continue;
    }
    const client_id = clientGid ? clientByGid.get(clientGid) : null;
    if (!client_id) { unlinkedClient.push(v); continue; }
    const meta = clientMeta.get(client_id) || {};
    missing.push({
      gid: v.id, client_id,
      job_id: v.job?.id ? (jobByGid.get(v.job.id) ?? null) : null,
      property_id: v.job?.property?.id ? (propByGid.get(v.job.property.id) ?? null) : null,
      visit_date: vdate, start_at: v.startAt || null, end_at: v.endAt || null,
      completed_at: v.completedAt || null, completed_by: v.completedBy || null,
      title: v.title ?? null, service_type: inferServiceType(v.title ?? null),
      visit_status: statusMap[v.visitStatus?.toLowerCase()] ?? 'scheduled',
      collision: existingByClientDate.has(`${client_id}|${vdate}`),
      _code: meta.client_code, _name: meta.name,
    });
  }

  // 4. Report
  console.log(`Known (already in DB): ${known}  ·  pre-2026 skipped: ${preYear}  ·  out-of-window: ${outOfWindow}  ·  112-YA excluded: ${excluded.length}`);
  if (drift.length) {
    console.log(`\n⚠️  Reschedule drift — ${drift.length} existing visit(s) whose Jobber startAt moved since sync${EXECUTE ? ' — re-dating below:' : ' (run --execute to re-date):'}`);
    drift.slice(0, 15).forEach(d => console.log(`     ${d.gid.slice(-10)}  stored=${d.stored}  jobber=${d.jobber}  source=${d.source}`));
  }
  if (unlinkedClient.length) {
    console.log(`\n⚠️  Unlinked client — ${unlinkedClient.length} visit(s) whose client isn't synced (cannot backfill):`);
    unlinkedClient.slice(0, 10).forEach(v => console.log(`     ${v.id.slice(-10)}  clientGID=${(v.job?.client?.id ?? v.client?.id ?? 'none').slice(-12)}  ${utcDate(v.startAt)}  "${v.title || ''}"`));
  }
  console.log(`\n>>> MISSING (in Jobber, not in our DB): ${missing.length}`);
  missing.sort((a, b) => a.visit_date.localeCompare(b.visit_date) || (a._code || '').localeCompare(b._code || ''));
  for (const m of missing) {
    console.log(`   ${m.visit_date}  ${(m._code || '?').padEnd(8)} ${(m._name || '').slice(0, 24).padEnd(24)} ${m.visit_status.padEnd(9)} st=${(m.service_type || '—').padEnd(3)} job=${m.job_id ?? '—'} "${(m.title || '').slice(0, 30)}"${m.collision ? '  COLLISION(client+date)' : ''}`);
  }

  // 5. Execute
  const toSync = drift.filter(d => d.source === 'jobber');           // re-date these
  const masteredDrift = drift.filter(d => d.source !== 'jobber');    // never pull Jobber's date onto Calendar-mastered rows
  if (!EXECUTE) {
    console.log(`\nDRY-RUN — would insert ${missing.length} visit(s) and re-date ${toSync.length} rescheduled visit(s). Re-run with --execute to write.`);
    if (masteredDrift.length) console.log(`(would skip ${masteredDrift.length} calendar-mastered drift — Calendar stays source of truth)`);
    return;
  }

  if (missing.length) {
    console.log(`\nInserting ${missing.length} visit(s)...`);
    let ok = 0;
    for (const m of missing) {
      const row = { client_id: m.client_id, visit_date: m.visit_date, start_at: m.start_at, end_at: m.end_at,
        completed_at: m.completed_at, completed_by: m.completed_by, title: m.title, service_type: m.service_type,
        visit_status: m.visit_status, source: 'jobber' };
      if (m.job_id) row.job_id = m.job_id;
      if (m.property_id) row.property_id = m.property_id;
      const [ins] = await rest('/visits', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify(row) });
      await rest('/entity_source_links?on_conflict=entity_type,source_system,source_id',
        { method: 'POST', headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
          body: JSON.stringify({ entity_type: 'visit', entity_id: ins.id, source_system: 'jobber', source_id: m.gid }) });
      ok++;
    }
    console.log(`✓ inserted ${ok} visit(s), each linked to its Jobber GID (source='jobber', no push-back).`);
  } else console.log('\nNo missing visits to insert.');

  // Re-date visits the office RESCHEDULED in Jobber so our DB matches Jobber.
  // Guarded to source='jobber' — Calendar-mastered rows (visit-calendar / supabase_cron)
  // keep the Calendar as source of truth and are never overwritten from Jobber.
  if (toSync.length) {
    console.log(`\nRe-dating ${toSync.length} rescheduled visit(s) to current Jobber dates...`);
    let sok = 0;
    for (const d of toSync) {
      await rest(`/visits?id=eq.${d.visit_id}`, { method: 'PATCH', headers: { Prefer: 'return=minimal' },
        body: JSON.stringify({ visit_date: d.jobber, start_at: d.start_at, end_at: d.end_at }) });
      console.log(`   ${d.visit_id}: ${d.stored} -> ${d.jobber}`);
      sok++;
    }
    console.log(`✓ re-dated ${sok} visit(s) (visit_date + start_at/end_at = Jobber).`);
  }
  if (masteredDrift.length) console.log(`(skipped ${masteredDrift.length} calendar-mastered drift — Calendar stays source of truth)`);
})().catch(e => { console.error('FATAL', e.message, e.stack); process.exit(1); });
