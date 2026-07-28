// scripts/probes/audit_client_code_drift.js
//
// Reports disagreement between `public.clients.client_code` and the NNN-XX prefix
// Yan types into the Jobber company name. REPORT ONLY — it heals nothing, ever.
//
// ── WHY THIS EXISTS, AND WHY IT NO LONGER HEALS ────────────────────────────
// It replaces the client_code step of .github/workflows/weekly-drift-audit.yml,
// deleted 2026-07-28. That step self-healed the DB when TWO independent upstreams
// AGREED against it (Jobber company-name prefix == Airtable Client Code #3, both
// != the stale DB value) — the unambiguous renumber case behind the 2026-06-17
// 221-MP -> 224-MP incident.
//
// Airtable was sunsetted 2026-07-24, so the second opinion is gone. With one
// upstream there is no way to tell "Jobber is right and the DB drifted" from
// "someone fat-fingered the Jobber company name", and the original author already
// wrote that Jobber alone is unsafe to auto-heal. So: report, never write. A human
// decides. Do NOT add a --heal flag back without a genuine second source.
//
// ── ⚠ THE FAILURE MODE THIS IS BUILT TO AVOID ──────────────────────────────
// The deleted workflow's real defect was NOT its Airtable dependency. It was that
// airtableCodes() returned an empty Set on ANY error instead of throwing, so a
// completely broken check printed "0 drifts" and exited 0 — indistinguishable
// from a clean result. It also sat RED for six consecutive Sundays on an unrelated
// `column p.zone does not exist`, and nobody noticed, because a weekly green tick
// is not something anyone reads.
//
// Therefore, three hard rules here:
//   1. NEVER exit 0 on a degraded run. Any failure to reach a source is exit 2.
//   2. ZERO PARSED PREFIXES IS AN ERROR, not a clean result. If we pull N Jobber
//      clients and parse 0 NNN-XX prefixes out of them, the parser or the source
//      changed shape — that is exactly the old bug wearing new clothes.
//   3. Speak only when there is something to say. Slack fires on FINDINGS or on
//      FAILURE, never on a clean run, so silence is meaningful and noise doesn't
//      train people to ignore it.
//
// Usage:  node scripts/probes/audit_client_code_drift.js
// Exit:   0 = checked, no drift · 1 = drift found · 2 = could not check (degraded)
//
// Env: SUPABASE_PAT, SUPABASE_PROJECT_ID, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
//      SLACK_BOT_TOKEN (optional), SLACK_CHANNEL_ID (default #viktor-supabase)

const path = require('path');
// ⚠ override:false ON PURPOSE (the other probes in this folder use override:true).
// override:true makes .env BEAT the real environment, which (a) is wrong in CI,
// where there is no .env and every secret arrives as an env var, and (b) makes the
// failure paths untestable — the first attempt to test the tripwires below passed
// bogus creds on the command line, dotenv silently discarded them, and all three
// "degraded" tests reported a clean run with exit 0. A guard you cannot make fail
// on demand is not a guard.
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: false });

const PAT = process.env.SUPABASE_PAT;
const PROJECT = process.env.SUPABASE_PROJECT_ID;
const SB_URL = process.env.SUPABASE_URL;
const SB_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SLACK_BOT_TOKEN = process.env.SLACK_BOT_TOKEN;
const SLACK_CHANNEL_ID = process.env.SLACK_CHANNEL_ID || 'C0B08S21HHD'; // #viktor-supabase

// Minimum Jobber clients we expect to see. Well below the real count (~440) but
// high enough that a truncated/empty page is caught rather than reported clean.
const MIN_JOBBER_CLIENTS = 50;

function die(msg) {
  console.error(`DEGRADED: ${msg}`);
  console.log(`--- audit complete --- ${JSON.stringify({ probe: 'client_code_drift', status: 'degraded', reason: msg })}`);
  return 2;
}

async function pg(sql) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: sql }),
  });
  const j = await r.json();
  if (!Array.isArray(j)) throw new Error(`DB query failed: ${(j.message || JSON.stringify(j)).slice(0, 200)}`);
  return j;
}

// MUST stay identical to webhook-jobber/index.ts (~line 274), or this probe will
// disagree with the thing that actually writes client_code and report phantoms.
function parsePrefix(name) {
  const m = String(name || '').match(/^\s*(\d{3})-\s*([A-Z0-9]*)\s+/);
  if (!m || !m[2]) return null;
  return `${m[1]}-${m[2]}`;
}

async function getJobberToken() {
  const r = await fetch(`${SB_URL}/rest/v1/webhook_tokens?source_system=eq.jobber&select=access_token`, {
    headers: { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}` },
  });
  if (!r.ok) throw new Error(`token fetch HTTP ${r.status}`);
  const j = await r.json();
  const t = j[0]?.access_token;
  if (!t) throw new Error('no Jobber access_token in webhook_tokens');
  return t;
}

async function jobberClients(token) {
  const all = [];
  let after = null;
  for (let page = 0; page < 30; page++) {
    const query = `query($after: String) { clients(first: 100, after: $after) {
      nodes { id companyName name }
      pageInfo { hasNextPage endCursor }
    } }`;
    const r = await fetch('https://api.getjobber.com/api/graphql', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
        'X-JOBBER-GRAPHQL-VERSION': '2026-04-16',
      },
      body: JSON.stringify({ query, variables: { after } }),
    });
    const j = await r.json();
    // Do NOT swallow this into an empty list — that is the old bug exactly.
    if (j.errors || !j.data?.clients) {
      throw new Error(`Jobber unreachable: ${JSON.stringify(j.errors || j).slice(0, 180)}`);
    }
    all.push(...(j.data.clients.nodes || []));
    if (!j.data.clients.pageInfo?.hasNextPage) break;
    after = j.data.clients.pageInfo.endCursor;
  }
  return all;
}

async function postSlack(text) {
  if (!SLACK_BOT_TOKEN) { console.log('  (no SLACK_BOT_TOKEN — not posting)'); return; }
  try {
    const r = await fetch('https://slack.com/api/chat.postMessage', {
      method: 'POST',
      headers: { Authorization: `Bearer ${SLACK_BOT_TOKEN}`, 'Content-Type': 'application/json; charset=utf-8' },
      body: JSON.stringify({ channel: SLACK_CHANNEL_ID, text }),
    });
    const j = await r.json();
    if (!j.ok) console.error(`  Slack post failed: ${j.error}`);
  } catch (e) {
    console.error(`  Slack post threw: ${e.message}`);
  }
}

(async () => {
  if (!PAT || !PROJECT || !SB_URL || !SB_KEY) {
    process.exit(die('missing required env (SUPABASE_PAT / PROJECT_ID / URL / SERVICE_ROLE_KEY)'));
  }

  // ---- source 1: the DB, keyed on the stable Jobber GID -------------------
  let dbRows;
  try {
    dbRows = await pg(`
      select c.id, c.name, c.client_code, c.status,
             (select esl.source_id from public.entity_source_links esl
               where esl.entity_type = 'client' and esl.entity_id = c.id
                 and esl.source_system = 'jobber' limit 1) as jobber_gid
        from public.clients c
       order by c.id`);
  } catch (e) { process.exit(die(e.message)); }
  if (!dbRows.length) process.exit(die('public.clients returned 0 rows'));

  // ---- source 2: Jobber ---------------------------------------------------
  let jbClients;
  try {
    const token = await getJobberToken();
    jbClients = await jobberClients(token);
  } catch (e) { process.exit(die(e.message)); }

  if (jbClients.length < MIN_JOBBER_CLIENTS) {
    process.exit(die(`only ${jbClients.length} Jobber clients returned (expected >= ${MIN_JOBBER_CLIENTS}) — truncated or filtered response`));
  }

  const jbByGid = new Map();
  let parsed = 0;
  for (const n of jbClients) {
    const pre = parsePrefix(n.companyName || n.name || '');
    if (pre) parsed++;
    jbByGid.set(n.id, { gid: n.id, companyName: n.companyName || n.name || '', prefix: pre });
  }

  // ⚠ TRIPWIRE: the exact shape of the bug that made the old audit useless.
  if (parsed === 0) {
    process.exit(die(`parsed 0 NNN-XX prefixes from ${jbClients.length} Jobber clients — the parser or the source changed shape; refusing to report "no drift"`));
  }

  // ---- compare ------------------------------------------------------------
  const drifts = [], jobberOnly = [], dbOnly = [], collisions = [];
  const dbCodeOwner = new Map();
  for (const r of dbRows) if (r.client_code) dbCodeOwner.set(r.client_code, r);

  let compared = 0;
  for (const r of dbRows) {
    if (!r.jobber_gid) continue;
    const jb = jbByGid.get(r.jobber_gid);
    if (!jb) continue;
    compared++;
    const dbCode = r.client_code || null;
    const jbCode = jb.prefix || null;
    if (dbCode && jbCode && dbCode !== jbCode) {
      const holder = dbCodeOwner.get(jbCode);
      const row = { id: r.id, name: r.name, status: r.status, db: dbCode, jobber: jbCode,
                    held_by: holder && holder.id !== r.id ? `${holder.client_code} (client ${holder.id} ${holder.name})` : null };
      (row.held_by ? collisions : drifts).push(row);
    } else if (!dbCode && jbCode) {
      jobberOnly.push({ id: r.id, name: r.name, status: r.status, jobber: jbCode });
    } else if (dbCode && !jbCode) {
      dbOnly.push({ id: r.id, name: r.name, status: r.status, db: dbCode });
    }
  }

  if (compared === 0) {
    process.exit(die(`0 clients could be matched to Jobber by GID (of ${dbRows.length} DB rows) — entity_source_links may be empty`));
  }

  // ---- report -------------------------------------------------------------
  console.log(`Compared ${compared} clients (DB ${dbRows.length}, Jobber ${jbClients.length}, ${parsed} carrying an NNN-XX prefix)\n`);

  console.log(`DRIFT — DB and Jobber disagree (${drifts.length}):`);
  if (!drifts.length) console.log('  (none)');
  for (const d of drifts) console.log(`  client ${d.id} "${d.name}" [${d.status}]  DB=${d.db}  Jobber=${d.jobber}`);

  console.log(`\nCOLLISION — Jobber's code is already held by ANOTHER client (${collisions.length}):`);
  if (!collisions.length) console.log('  (none)');
  for (const d of collisions) console.log(`  client ${d.id} "${d.name}"  DB=${d.db}  Jobber=${d.jobber}  -> already ${d.held_by}`);

  console.log(`\nINFO — Jobber has a code, DB has none (${jobberOnly.length}):`);
  for (const d of jobberOnly.slice(0, 15)) console.log(`  client ${d.id} "${d.name}" [${d.status}]  Jobber=${d.jobber}`);
  if (jobberOnly.length > 15) console.log(`  ... and ${jobberOnly.length - 15} more`);

  console.log(`\nINFO — DB has a code, Jobber name has none (${dbOnly.length}) — normal, Yan does not always type it.`);

  const findings = drifts.length + collisions.length;

  if (findings) {
    const lines = [
      `:rotating_light: *client_code drift* — ${drifts.length} disagreement(s), ${collisions.length} collision(s)`,
      ...drifts.slice(0, 10).map(d => `• client ${d.id} *${d.name}* — DB \`${d.db}\` vs Jobber \`${d.jobber}\``),
      ...collisions.slice(0, 10).map(d => `• :warning: client ${d.id} *${d.name}* — Jobber \`${d.jobber}\` already held by ${d.held_by}`),
      '',
      '_Report only — nothing was changed. Airtable is gone, so there is no second source to break the tie; a human decides which side is right._',
    ];
    await postSlack(lines.join('\n'));
  }

  console.log(`\n--- audit complete --- ${JSON.stringify({
    probe: 'client_code_drift', status: 'ok', compared,
    drifts: drifts.length, collisions: collisions.length,
    jobber_only: jobberOnly.length, db_only: dbOnly.length, healed: 0,
  })}`);

  process.exit(findings ? 1 : 0);
})().catch(async (e) => {
  console.error('FATAL', e.stack || e.message);
  await postSlack(`:x: *client_code drift probe FAILED* — \`${String(e.message).slice(0, 300)}\`\n_The check did not run. This is not "no drift"._`);
  console.log(`--- audit complete --- ${JSON.stringify({ probe: 'client_code_drift', status: 'error', error: String(e.message).slice(0, 200) })}`);
  process.exit(2);
});
