// ============================================================================
// weekly_dedup_audit.js: periodic duplicate-detection sweep
// ============================================================================
// Runs every Sunday at 14:00 UTC via GitHub Actions. Catches duplicates
// before they grow roots. All three checks ignore INACTIVE clients (Fred, 2026-10-06):
//
//   1. Multiple active clients with the same client_code
//   2. Multiple active clients with the same primary property address (normalized). Most of these are
//      legitimate (a building and its tenants, an old and a new tenant, two units of one business), so the
//      Slack post lists only groups NOT in last week's logged list (splitNew) and counts the rest.
//   3. Active clients whose Jobber client no longer exists (deleted and re-created in Jobber)
//
// The post uses client codes and names, says "(no code)" when a client has none, and has no em dash.
// It keeps its own bot ("Supabase - Notifications"); Fred, 2026-10-06: do not move it to the shared bot.
// Test without posting or writing:  DRY_RUN=1 node scripts/sync/weekly_dedup_audit.js
// Logic check:                       node scripts/sync/weekly_dedup_audit.js --selftest
//
// Findings are:
//   - written to webhook_events_log with event_type='dedup_audit_*' and
//     status='warning' (so daily cleanup retains them under standard
//     retention)
//   - posted to Slack #viktor-supabase if SLACK_BOT_TOKEN is set
//
// Required env (GH Actions secrets):
//   SUPABASE_URL, SUPABASE_PAT
//   JOBBER_CLIENT_ID, JOBBER_CLIENT_SECRET (for stale-GID detector)
//   SLACK_BOT_TOKEN (optional — if set, posts to channel)
//   SLACK_CHANNEL_ID (default: C0B08S21HHD = #viktor-supabase)
// ============================================================================

const https = require('https');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') }); } catch (_) {}

const SUPABASE_URL = process.env.SUPABASE_URL;
const PAT = process.env.SUPABASE_PAT;
const SLACK_BOT_TOKEN = process.env.SLACK_BOT_TOKEN;
const SLACK_CHANNEL_ID = process.env.SLACK_CHANNEL_ID || 'C0B08S21HHD';
const DRY = process.env.DRY_RUN === '1';   // no Slack post, no log rows, no Jobber token refresh
if (!SUPABASE_URL || !PAT) throw new Error('SUPABASE_URL and SUPABASE_PAT required');

const projectRef = SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d }));
    });
    req.on('error', rej);
    req.setTimeout(60_000, () => req.destroy(new Error('timeout')));
    if (body) req.write(body);
    req.end();
  });
}

async function pg(sql, _attempt = 1) {
  const body = JSON.stringify({ query: sql });
  // TRANSPORT RETRY 2026-08-14. The status-code retry below is not enough alone:
  // this request helper REJECTS on a socket error and on its own timeout, so
  // ECONNRESET / ENOTFOUND / a hung connection bypassed it and still aborted the run.
  // Found by @Building Apps in the reconciler copy of this same block.
  let r;
  try {
    r = await http({
    hostname: 'api.supabase.com', path: `/v1/projects/${projectRef}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  } catch (_e) {
    if (_attempt < 5) { await new Promise(res => setTimeout(res, 2000 * _attempt)); return pg(sql, _attempt + 1); }
    throw _e;
  }
  // RETRY ADDED 2026-08-14. A bare throw here aborted the whole scheduled run on a
  // transient blip: daily-jobber-anomaly-reconcile died 2026-08-11 on "PG 502".
  // 5xx/429 only; a 4xx is a real bug and retrying hides it. See lib/pg_retry.js.
  if (r.status >= 300) {
    const _retryable = r.status === 429 || r.status >= 500;
    if (_retryable && _attempt < 5) {
      await new Promise(res => setTimeout(res, 2000 * _attempt));
      return pg(sql, _attempt + 1);
    }
    throw new Error(`SQL ${r.status}: ${r.body.slice(0, 200)}`);
  }
  return JSON.parse(r.body || '[]');
}

async function postSlack(text) {
  if (DRY) { console.log('  (dry run, would post:)\n' + text); return; }
  if (!SLACK_BOT_TOKEN) { console.log('  (no SLACK_BOT_TOKEN — skip post)'); return; }
  const body = JSON.stringify({ channel: SLACK_CHANNEL_ID, text });
  const r = await http({
    hostname: 'slack.com', path: '/api/chat.postMessage', method: 'POST',
    headers: { Authorization: `Bearer ${SLACK_BOT_TOKEN}`, 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  const j = JSON.parse(r.body);
  if (!j.ok) console.log(`  Slack post failed: ${j.error}`);
}

async function logEvent(eventType, summary, payload) {
  if (DRY) { console.log(`  (dry run, would log ${eventType}: ${summary})`); return; }
  await pg(`
    INSERT INTO webhook_events_log (source_system, event_type, status, error_message, payload)
    VALUES ('internal', '${eventType}', 'warning', $$${summary.replace(/\$/g, '\\$')}$$, $$${JSON.stringify(payload).replace(/\$/g, '\\$')}$$);
  `);
}

// Shared addresses only become news once: a group already reported is "known" when last week's logged group at the
// same normalized address held every client it holds now (so a group that only lost clients stays known).
function splitNew(current, previous) {
  const prev = new Map((previous || []).map((g) => [g.norm_addr, new Set((g.client_ids || []).map(Number))]));
  const fresh = [], known = [];
  for (const g of current) {
    const was = prev.get(g.norm_addr);
    (was && g.client_ids.every((id) => was.has(Number(id))) ? known : fresh).push(g);
  }
  return { fresh, known };
}

if (process.argv.includes('--selftest')) {
  const assert = require('assert');
  const prev = [{ norm_addr: 'a', client_ids: [1, 2, 3] }, { norm_addr: 'b', client_ids: [4, 5] }];
  const r = splitNew([
    { norm_addr: 'a', client_ids: [1, 2] },      // lost a client: known
    { norm_addr: 'b', client_ids: [4, 5, 6] },   // gained a client: new
    { norm_addr: 'c', client_ids: [7, 8] },      // new address: new
  ], prev);
  assert.deepStrictEqual(r.known.map((g) => g.norm_addr), ['a']);
  assert.deepStrictEqual(r.fresh.map((g) => g.norm_addr), ['b', 'c']);
  assert.strictEqual(splitNew([{ norm_addr: 'a', client_ids: [1] }], null).fresh.length, 1, 'no history: everything is new');
  console.log('weekly_dedup_audit selftest: ok');
  process.exit(0);
}

// Slack reads &, < and > as formatting: text from records is escaped before it goes into the message
const esc = (t) => String(t ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
// "085-XYZ Name", or "Name (no code)"
const who = (c) => esc(`${c.client_code ? `${c.client_code} ` : ''}${(c.name || '').trim().slice(0, 60)}${c.client_code ? '' : ' (no code)'}`);
const etDate = new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', month: 'short', day: 'numeric', year: 'numeric' }).format(new Date());

(async () => {
  console.log(`[dedup-audit] start ${new Date().toISOString()}${DRY ? ' (dry run: no Slack, no log rows, no token refresh)' : ''}`);
  const findings = [];

  // 1. Duplicate client_code among clients that are not INACTIVE (an archived client's code is free for a new one)
  console.log('[dedup-audit] checking duplicate client_code...');
  const dupCodes = await pg(`
    SELECT client_code, ARRAY_AGG(id ORDER BY id) AS ids,
           ARRAY_AGG(name ORDER BY id) AS names
    FROM clients WHERE client_code IS NOT NULL AND client_code != '' AND status <> 'INACTIVE'
    GROUP BY client_code HAVING COUNT(*) > 1;
  `);
  console.log(`  ${dupCodes.length} duplicate client_code groups`);
  if (dupCodes.length) {
    findings.push(`*${dupCodes.length} client code${dupCodes.length === 1 ? ' is' : 's are'} used by more than one active client:*`);
    for (const d of dupCodes.slice(0, 10)) findings.push(`  • ${esc(d.client_code)}: ${d.names.map((n) => esc((n || '').trim())).join(', ')}`);
    if (dupCodes.length > 10) findings.push(`  ...and ${dupCodes.length - 10} more`);
    await logEvent('dedup_audit_duplicate_codes', `${dupCodes.length} duplicate client_codes`, dupCodes);
  }

  // 2. Primary-property addresses shared by more than one client that is not INACTIVE. Most are legitimate (a
  //    building and its tenants, an old and a new tenant, two units of one business), so only groups NOT reported
  //    last week are posted; the full list is still logged for the next comparison.
  console.log('[dedup-audit] checking shared addresses...');
  const dupAddresses = await pg(`
    WITH norm AS (
      SELECT p.client_id, c.client_code, c.name, p.address,
        regexp_replace(LOWER(TRIM(p.address)), '[^a-z0-9]+', ' ', 'g') AS norm_addr
      FROM properties p JOIN clients c ON c.id = p.client_id
      WHERE p.is_primary = TRUE AND p.deleted_at IS NULL AND p.address IS NOT NULL AND p.address <> ''
        AND c.status <> 'INACTIVE'
    )
    SELECT norm_addr, (ARRAY_AGG(address ORDER BY client_id))[1] AS address,
           ARRAY_AGG(client_id ORDER BY client_id) AS client_ids,
           ARRAY_AGG(name ORDER BY client_id) AS names,
           JSONB_AGG(JSONB_BUILD_OBJECT('client_code', client_code, 'name', name) ORDER BY client_id) AS members
    FROM norm GROUP BY norm_addr HAVING COUNT(*) > 1 ORDER BY norm_addr;
  `);
  const prevRow = await pg(`SELECT payload FROM webhook_events_log WHERE event_type = 'dedup_audit_duplicate_addresses' ORDER BY id DESC LIMIT 1;`);
  const { fresh, known } = splitNew(dupAddresses, prevRow[0]?.payload);
  console.log(`  ${dupAddresses.length} shared-address groups (${fresh.length} new, ${known.length} reported before)`);
  if (fresh.length) {
    findings.push(`\n*${fresh.length} new address${fresh.length === 1 ? '' : 'es'} shared by more than one active client:*`);
    for (const d of fresh.slice(0, 10)) findings.push(`  • ${esc(d.address.trim().slice(0, 60))}: ${d.members.map(who).join(', ')}`);
    if (fresh.length > 10) findings.push(`  ...and ${fresh.length - 10} more`);
    if (known.length) findings.push(`  _${known.length} shared address${known.length === 1 ? '' : 'es'} from earlier weeks ${known.length === 1 ? 'is' : 'are'} not repeated._`);
  }
  if (dupAddresses.length) await logEvent('dedup_audit_duplicate_addresses', `${dupAddresses.length} duplicate addresses (${fresh.length} new)`, dupAddresses);

  // 3. Active clients whose Jobber client no longer exists. An INACTIVE client deleted in Jobber is expected
  //    (archived, then removed there) and is not reported.
  console.log('[dedup-audit] checking clients Jobber no longer has...');
  let staleGids = [];
  try {
    const jobberToken = await getJobberToken();
    const allJobberGids = await pullAllJobberClientGids(jobberToken);
    console.log(`  ${allJobberGids.size} live Jobber GIDs`);

    const ourGids = await pg(`
      SELECT esl.source_id AS gid, esl.entity_id, c.client_code, c.name, c.status
      FROM entity_source_links esl
      JOIN clients c ON c.id = esl.entity_id
      WHERE esl.entity_type='client' AND esl.source_system='jobber' AND c.status <> 'INACTIVE';
    `);
    staleGids = ourGids.filter(r => !allJobberGids.has(r.gid));
    console.log(`  ${staleGids.length} active clients Jobber no longer has`);
    if (staleGids.length) {
      findings.push(`\n*${staleGids.length} active client${staleGids.length === 1 ? '' : 's'} Jobber no longer has:*`);
      for (const s of staleGids.slice(0, 10)) findings.push(`  • ${who(s)}`);
      if (staleGids.length > 10) findings.push(`  ...and ${staleGids.length - 10} more`);
      await logEvent('dedup_audit_stale_gids', `${staleGids.length} stale Jobber GIDs`, staleGids);
    }
  } catch (e) {
    console.log(`  ⚠ Jobber check skipped: ${e.message.slice(0, 100)}`);
  }

  // Final summary
  console.log('\n[dedup-audit] summary:');
  console.log(`  duplicate_codes:     ${dupCodes.length}`);
  console.log(`  shared_addresses:    ${dupAddresses.length} (${fresh.length} new)`);
  console.log(`  stale_jobber_gids:   ${staleGids.length}`);

  if (findings.length === 0) {
    console.log('  ✓ nothing new to report');
  } else {
    const slackMsg = `:mag: *Weekly duplicate check · ${etDate}*\n\n${findings.join('\n').replace(/^\n+/, '')}\n\n_Review these and decide whether any should be merged or archived._`;
    await postSlack(slackMsg);
  }

  console.log(`[dedup-audit] done ${new Date().toISOString()}`);
})().catch(e => { console.error('[dedup-audit] FATAL:', e.message); process.exit(1); });

// ============================================================================
// Jobber helpers (minimal — read token from webhook_tokens, paginate clients)
// ============================================================================

async function getJobberToken() {
  // Read access_token from webhook_tokens; refresh if within 60s of expiry.
  const r = await pg(`SELECT access_token, refresh_token, expires_at FROM webhook_tokens WHERE source_system='jobber';`);
  if (!r.length) throw new Error('No jobber token in webhook_tokens');
  const tok = r[0];
  const expSoon = new Date(tok.expires_at).getTime() - Date.now() < 60_000;
  if (!expSoon) return tok.access_token;
  if (DRY) throw new Error('the Jobber token is about to expire and a dry run does not refresh it');
  // Refresh
  const ci = process.env.JOBBER_CLIENT_ID;
  const cs = process.env.JOBBER_CLIENT_SECRET;
  if (!ci || !cs) throw new Error('JOBBER_CLIENT_ID/SECRET needed for refresh');
  const body = `grant_type=refresh_token&client_id=${ci}&client_secret=${cs}&refresh_token=${tok.refresh_token}`;
  const rr = await http({
    hostname: 'api.getjobber.com', path: '/api/oauth/token', method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (rr.status >= 300) throw new Error(`Refresh ${rr.status}`);
  const j = JSON.parse(rr.body);
  await pg(`
    UPDATE webhook_tokens SET access_token=$$${j.access_token}$$,
      refresh_token=$$${j.refresh_token}$$,
      expires_at=now() + interval '${j.expires_in || 3600} seconds'
    WHERE source_system='jobber';
  `);
  return j.access_token;
}

async function pullAllJobberClientGids(token) {
  const all = new Set();
  let cursor = null;
  while (true) {
    const body = JSON.stringify({
      query: `query($a:String){clients(after:$a,first:100){pageInfo{hasNextPage endCursor} nodes{id}}}`,
      variables: { a: cursor },
    });
    const r = await http({
      hostname: 'api.getjobber.com', path: '/api/graphql', method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-13', 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, body);
    if (r.status >= 300) throw new Error(`Jobber ${r.status}`);
    const j = JSON.parse(r.body);
    if (j.errors) {
      if (j.errors.some(e => e.extensions?.code === 'THROTTLED')) {
        await new Promise(rs => setTimeout(rs, 5000));
        continue;
      }
      throw new Error(JSON.stringify(j.errors));
    }
    for (const n of j.data.clients.nodes) all.add(n.id);
    if (!j.data.clients.pageInfo.hasNextPage) break;
    cursor = j.data.clients.pageInfo.endCursor;
  }
  return all;
}
