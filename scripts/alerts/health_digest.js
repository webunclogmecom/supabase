// ============================================================================
// health_digest.js — post a health verdict to Slack, ONLY when something changed
// ============================================================================
// Reads ops.v_health_status (one row per health check, with the delta against
// that check's previous run) and posts to a Slack incoming webhook.
//
// WHY THIS EXISTS. The four log_*_health() crons write their verdict into
// public.sync_log, and NOTHING READS public.sync_log. Measured 2026-08-24: health
// verdicts are 138 of 34,849 rows there (0.40%), buried under 21,863 Jobber poll
// records. Three checks had been in 'attention' for days with nobody told, and one
// of them was a Miami-Dade DERM report that never filed.
//
// 🛑 WHY IT POSTS ONLY ON CHANGE (Fred's decision, 2026-08-24). The raw signal has
// no dedup: every check re-announces the same unresolved item on every run.
// jobber_visit_drift was 161 of the last 180 'attention' rows, re-reporting ONE
// visit with healable=0 every 30 minutes; across its history 4,408 item-reports
// describe 105 distinct problems. A daily "here is the same list again" post is how
// a channel becomes wallpaper. Silence here means nothing changed, and that is the
// whole contract. If you want a standing summary of what is still open, query
// ops.v_health_status directly rather than making this noisier.
//
// ⚠ STILL-OPEN ITEMS ARE SHOWN, BUT ONLY WHEN A POST IS ALREADY HAPPENING. That is
// deliberate: it costs nothing when we are already speaking, and it stops a
// long-running problem from quietly becoming permanent just because it stopped
// being new. It never causes a post on its own.
//
// Required env (GH Action secrets, or .env locally):
//   SUPABASE_URL, SUPABASE_PAT, SLACK_HEALTH_WEBHOOK_URL
// 🛑 SLACK_HEALTH_WEBHOOK_URL IS A SECRET AND THIS REPO IS PUBLIC. It lives in .env
//    (gitignored) locally and in a GitHub Actions secret in CI. Never inline it.
//
// Local:         node scripts/alerts/health_digest.js
// Local dry run: DRY_RUN=1 node scripts/alerts/health_digest.js   (prints, no post)
// Force a post:  FORCE=1 node scripts/alerts/health_digest.js     (ignores "changed")
// ============================================================================

const https = require('https');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') }); } catch (_) {}

const SUPABASE_URL = process.env.SUPABASE_URL;
const PAT = process.env.SUPABASE_PAT;
const WEBHOOK = process.env.SLACK_HEALTH_WEBHOOK_URL;
const DRY_RUN = process.env.DRY_RUN === '1';
const FORCE = process.env.FORCE === '1';
if (!SUPABASE_URL || !PAT) throw new Error('SUPABASE_URL and SUPABASE_PAT required');

const projectRef = SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d }));
    });
    req.on('error', rej);
    if (body) req.write(body);
    req.end();
  });
}

// Same transport+status retry shape as audit_critical_poll.js: a socket blip must
// not abort a scheduled run, but a 4xx is a real bug and retrying would hide it.
async function pg(sql, _attempt = 1) {
  const body = JSON.stringify({ query: sql });
  let r;
  try {
    r = await http({
      hostname: 'api.supabase.com', path: `/v1/projects/${projectRef}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, body);
  } catch (e) {
    if (_attempt < 5) { await new Promise(s => setTimeout(s, 2000 * _attempt)); return pg(sql, _attempt + 1); }
    throw e;
  }
  if (r.status >= 300) {
    if ((r.status >= 500 || r.status === 429) && _attempt < 5) {
      await new Promise(s => setTimeout(s, 2000 * _attempt)); return pg(sql, _attempt + 1);
    }
    throw new Error(`PG ${r.status}: ${r.body.slice(0, 300)}`);
  }
  return JSON.parse(r.body);
}

async function postSlack(text) {
  if (DRY_RUN) { console.log('--- DRY RUN, would post ---\n' + text); return; }
  if (!WEBHOOK) { console.log('  (no SLACK_HEALTH_WEBHOOK_URL - skipping post)'); return; }
  const body = JSON.stringify({ text, mrkdwn: true });
  const u = new URL(WEBHOOK);
  const r = await http({
    hostname: u.hostname, path: u.pathname, method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  // An incoming webhook answers 200 "ok" on success and 4xx with a plain-text
  // reason. Do NOT treat a 2xx as delivered without checking the body.
  if (r.status !== 200 || r.body.trim() !== 'ok') {
    throw new Error(`Slack webhook ${r.status}: ${r.body.slice(0, 200)}`);
  }
  console.log('  posted to Slack');
}

const plural = (n, s) => `${n} ${s}${n === 1 ? '' : 's'}`;

// Slack mrkdwn: *single asterisks* for bold, no markdown tables, no ## headers.
function render(rows) {
  const changed = rows.filter(r => !r.unchanged_since_last_run);
  const openNow = rows.filter(r => r.status === 'attention');

  const nNew = changed.reduce((n, r) => n + (r.new_items || []).length, 0);
  const nRes = changed.reduce((n, r) => n + (r.resolved_items || []).length, 0);

  const L = [];
  // "new" and "resolved" are adjectives here, not nouns. plural() would render
  // "0 news, 0 resolveds".
  L.push(`*Health* ${nNew} new, ${nRes} resolved`);

  for (const r of changed) {
    const nw = r.new_items || [], rs = r.resolved_items || [];
    if (!nw.length && !rs.length) continue;
    L.push('');
    L.push(`*${r.check_name}* ${r.status}`);
    if (nw.length) L.push(`  new: ${nw.join(', ')}`);
    if (rs.length) L.push(`  resolved: ${rs.join(', ')}`);
    // blackout carries the number that actually describes customer impact; the
    // item count is the Stamp Studio queue and is a different question entirely.
    const ci = r.details && r.details.customer_impact;
    if (ci && Number(ci.work_orders_without_file) > 0) {
      L.push(`  ${plural(Number(ci.work_orders_without_file), 'customer work order')} showing a DERM number with no viewable file`);
    }
  }

  // Shown only because we are already posting. Never triggers a post by itself.
  const stillOpen = openNow.filter(r => r.unchanged_since_last_run);
  if (stillOpen.length) {
    L.push('');
    L.push('*still open, unchanged*');
    for (const r of stillOpen) {
      L.push(`  ${r.check_name}: ${plural(Number(r.item_count), 'item')}, ${plural(Number(r.consecutive_runs_same_status), 'run')}`);
    }
  }
  return L.join('\n');
}

(async () => {
  const rows = await pg(`
    select check_name, status, item_count, new_items, resolved_items,
           unchanged_since_last_run, consecutive_runs_same_status, details
      from ops.v_health_status
     order by check_name`);

  // 🛑 An empty result is NOT an all-clear. If the view returned nothing the query
  //    is broken or the checks stopped running, and staying silent would be the
  //    exact failure this script exists to fix. Say so, loudly.
  if (!Array.isArray(rows) || rows.length === 0) {
    const msg = '*Health* ops.v_health_status returned NO ROWS. Either the health crons stopped writing or the view is broken. This is not an all-clear.';
    console.log(msg);
    await postSlack(msg);
    process.exit(0);
  }

  const changed = rows.some(r => !r.unchanged_since_last_run);
  console.log(`${rows.length} checks, ${changed ? 'something changed' : 'nothing changed'}`);
  for (const r of rows) {
    console.log(`  ${String(r.check_name).padEnd(22)} ${String(r.status).padEnd(10)} items=${r.item_count} changed=${!r.unchanged_since_last_run}`);
  }

  if (!changed && !FORCE) { console.log('nothing changed - not posting (this is the contract)'); process.exit(0); }
  await postSlack(render(rows));
})().catch(e => { console.error(e.message); process.exit(1); });
