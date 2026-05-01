// ============================================================================
// weekly_dedup_audit.js — periodic duplicate-detection sweep
// ============================================================================
// Runs every Sunday at 14:00 UTC via GitHub Actions. Catches duplicates
// before they grow roots:
//
//   1. Multiple clients with the same client_code
//   2. Multiple clients with the same primary property address (normalized)
//   3. Clients in our DB pointing at Jobber GIDs that no longer exist in
//      Jobber (stale GIDs — Yan deleted/re-created the client manually)
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

async function pg(sql) {
  const body = JSON.stringify({ query: sql });
  const r = await http({
    hostname: 'api.supabase.com', path: `/v1/projects/${projectRef}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) throw new Error(`SQL ${r.status}: ${r.body.slice(0, 200)}`);
  return JSON.parse(r.body || '[]');
}

async function postSlack(text) {
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
  await pg(`
    INSERT INTO webhook_events_log (source_system, event_type, status, error_message, payload)
    VALUES ('internal', '${eventType}', 'warning', $$${summary.replace(/\$/g, '\\$')}$$, $$${JSON.stringify(payload).replace(/\$/g, '\\$')}$$);
  `);
}

(async () => {
  console.log(`[dedup-audit] start ${new Date().toISOString()}`);
  const findings = [];

  // 1. Duplicate client_code
  console.log('[dedup-audit] checking duplicate client_code...');
  const dupCodes = await pg(`
    SELECT client_code, ARRAY_AGG(id ORDER BY id) AS ids,
           ARRAY_AGG(name ORDER BY id) AS names
    FROM clients WHERE client_code IS NOT NULL AND client_code != ''
    GROUP BY client_code HAVING COUNT(*) > 1;
  `);
  console.log(`  ${dupCodes.length} duplicate client_code groups`);
  if (dupCodes.length) {
    findings.push(`*${dupCodes.length} duplicate client_code(s):*`);
    for (const d of dupCodes.slice(0, 10)) {
      findings.push(`  • \`${d.client_code}\` → ids ${d.ids.join(', ')}`);
    }
    if (dupCodes.length > 10) findings.push(`  ...and ${dupCodes.length - 10} more`);
    await logEvent('dedup_audit_duplicate_codes', `${dupCodes.length} duplicate client_codes`, dupCodes);
  }

  // 2. Duplicate primary-property address (normalized)
  console.log('[dedup-audit] checking duplicate addresses...');
  const dupAddresses = await pg(`
    WITH norm AS (
      SELECT p.client_id, c.name AS client_name,
        regexp_replace(LOWER(TRIM(p.address)), '[^a-z0-9]+', ' ', 'g') AS norm_addr
      FROM properties p JOIN clients c ON c.id = p.client_id
      WHERE p.is_primary = TRUE AND p.address IS NOT NULL AND p.address <> ''
    )
    SELECT norm_addr, ARRAY_AGG(client_id ORDER BY client_id) AS client_ids,
           ARRAY_AGG(client_name ORDER BY client_id) AS names
    FROM norm GROUP BY norm_addr HAVING COUNT(*) > 1;
  `);
  console.log(`  ${dupAddresses.length} duplicate address groups`);
  if (dupAddresses.length) {
    findings.push(`\n*${dupAddresses.length} duplicate primary-property address(es):*`);
    for (const d of dupAddresses.slice(0, 10)) {
      findings.push(`  • \`${d.norm_addr.slice(0, 50)}\` → clients ${d.client_ids.join(', ')}`);
    }
    if (dupAddresses.length > 10) findings.push(`  ...and ${dupAddresses.length - 10} more`);
    await logEvent('dedup_audit_duplicate_addresses', `${dupAddresses.length} duplicate addresses`, dupAddresses);
  }

  // 3. Stale Jobber GIDs — clients whose Jobber GID isn't in Jobber's
  //    current client list. Pull all current Jobber GIDs and diff.
  console.log('[dedup-audit] checking stale Jobber GIDs...');
  let staleGids = [];
  try {
    const jobberToken = await getJobberToken();
    const allJobberGids = await pullAllJobberClientGids(jobberToken);
    console.log(`  ${allJobberGids.size} live Jobber GIDs`);

    const ourGids = await pg(`
      SELECT esl.source_id AS gid, esl.entity_id, c.client_code, c.name, c.status
      FROM entity_source_links esl
      JOIN clients c ON c.id = esl.entity_id
      WHERE esl.entity_type='client' AND esl.source_system='jobber';
    `);
    staleGids = ourGids.filter(r => !allJobberGids.has(r.gid));
    console.log(`  ${staleGids.length} clients with stale Jobber GIDs`);
    if (staleGids.length) {
      findings.push(`\n*${staleGids.length} client(s) with stale Jobber GID(s) (Jobber no longer has them):*`);
      for (const s of staleGids.slice(0, 10)) {
        findings.push(`  • id=${s.entity_id} \`${s.client_code || '?'}\` "${s.name?.slice(0, 35) || '?'}" (status=${s.status})`);
      }
      if (staleGids.length > 10) findings.push(`  ...and ${staleGids.length - 10} more`);
      await logEvent('dedup_audit_stale_gids', `${staleGids.length} stale Jobber GIDs`, staleGids);
    }
  } catch (e) {
    console.log(`  ⚠ Jobber stale-GID check skipped: ${e.message.slice(0, 100)}`);
  }

  // Final summary
  console.log('\n[dedup-audit] summary:');
  console.log(`  duplicate_codes:     ${dupCodes.length}`);
  console.log(`  duplicate_addresses: ${dupAddresses.length}`);
  console.log(`  stale_jobber_gids:   ${staleGids.length}`);

  if (findings.length === 0) {
    console.log('  ✓ no findings — DB is clean');
  } else {
    const slackMsg = `:mag: *Weekly dedup audit — ${new Date().toISOString().slice(0, 10)}*\n\n${findings.join('\n')}\n\n_Run from \`scripts/sync/weekly_dedup_audit.js\` — review and decide on merges._`;
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
