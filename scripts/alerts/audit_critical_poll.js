// ============================================================================
// audit_critical_poll.js — Tier 1 audit-trail critical alerts
// ============================================================================
// Polls audit.logs every 5 min for the four conditions that warrant immediate
// human attention. Posts to #viktor-supabase. See ADR 010 (Audit Trail).
//
// Critical conditions (Tier 1 only; Tier 2/3/4 explicitly rejected by Fred):
//   1. webhook_tokens modified by anything other than service_role
//   2. Hard DELETE on clients / derm_manifests / service_configs
//   3. Mass-change spike: >200 audit events in a 60s window
//   4. Anon write outside the allow-list (photo_classifications, visits,
//      properties)
//
// State: sync_cursors row with entity = 'audit_alerts'. last_synced_at is
// the max(changed_at) we've processed. On first run, seeds to now()-5min.
//
// Why timestamp-based and not id-based: sync_cursors only has TIMESTAMPTZ
// fields and audit.logs.id is BIGINT — sticking to the existing cursor
// pattern keeps the table schema clean. changed_at is monotonic enough at
// our write volume (~150-200 audited rows/day) that ordering risk is nil.
//
// Required GH Action secrets:
//   SUPABASE_URL, SUPABASE_PAT, SLACK_BOT_TOKEN
//
// Local: `node scripts/alerts/audit_critical_poll.js` (uses .env)
// Local dry run: `DRY_RUN=1 node scripts/alerts/audit_critical_poll.js`
// ============================================================================

const https = require('https');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') }); } catch (_) {}

const SUPABASE_URL = process.env.SUPABASE_URL;
const PAT = process.env.SUPABASE_PAT;
const SLACK_BOT_TOKEN = process.env.SLACK_BOT_TOKEN;
const SLACK_CHANNEL_ID = process.env.SLACK_CHANNEL_ID || 'C0B08S21HHD';
const DRY_RUN = process.env.DRY_RUN === '1';
if (!SUPABASE_URL || !PAT) throw new Error('SUPABASE_URL and SUPABASE_PAT required');

const projectRef = SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

// ---------------------------------------------------------------------------
// Allow-list of (table, operation) that anon is permitted to perform.
// Anything else from db_role='anon' is a critical alert.
// Sources:
//   - Field Portal app (anon): photo_classifications UPDATE, visits UPDATE
//     (manhole_count), properties UPDATE (notes/manhole defaults)
//   - Field Portal also INSERTs into photo_classifications when a photo is
//     first classified, so include INSERT too.
// Update this if you grant anon write access to a new surface.
// ---------------------------------------------------------------------------
const ANON_ALLOWED = new Set([
  'photo_classifications:INSERT',
  'photo_classifications:UPDATE',
  'visits:UPDATE',
  'properties:UPDATE',
]);

// ---------------------------------------------------------------------------
// Allow-list of (source_system, db_role, app_source) tuples permitted to
// modify webhook_tokens without alerting. The Jobber polling cron refreshes
// its access_token every ~hour via the Supabase Management API, which runs
// as 'postgres' role with app_source='sql' — known-good cron heartbeat, not
// a security event. Anything else on webhook_tokens still alerts.
// Add a tuple here if a new sync source needs cron-driven token refresh.
// Format: <source_system>:<db_role>:<app_source>
// ---------------------------------------------------------------------------
const WEBHOOK_TOKENS_ALLOWED = new Set([
  'jobber:postgres:sql',  // hourly Jobber access_token refresh via mgmt API
]);

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

async function pg(sql) {
  const body = JSON.stringify({ query: sql });
  const r = await http({
    hostname: 'api.supabase.com', path: `/v1/projects/${projectRef}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  if (r.status >= 300) throw new Error(`SQL ${r.status}: ${r.body.slice(0, 300)}`);
  return JSON.parse(r.body);
}

async function postSlack(text) {
  if (DRY_RUN) { console.log('  (DRY_RUN — skipping post)'); return; }
  if (!SLACK_BOT_TOKEN) { console.log('  (no SLACK_BOT_TOKEN — skipping post)'); return; }
  const body = JSON.stringify({ channel: SLACK_CHANNEL_ID, text, mrkdwn: true });
  const r = await http({
    hostname: 'slack.com', path: '/api/chat.postMessage', method: 'POST',
    headers: { Authorization: `Bearer ${SLACK_BOT_TOKEN}`, 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) },
  }, body);
  const j = JSON.parse(r.body);
  if (!j.ok) throw new Error(`Slack: ${j.error}`);
  console.log(`  ✓ posted to ${SLACK_CHANNEL_ID}, ts=${j.ts}`);
}

// Compact a record_pk JSONB to a single string like "id=42" or "(a=1, b=2)"
function pkStr(pk) {
  if (!pk || typeof pk !== 'object') return '?';
  const keys = Object.keys(pk);
  if (keys.length === 0) return '?';
  if (keys.length === 1) return `${keys[0]}=${pk[keys[0]]}`;
  return '(' + keys.map(k => `${k}=${pk[k]}`).join(', ') + ')';
}

(async () => {
  console.log(`[audit-critical-poll] start ${new Date().toISOString()}`);

  // 1. Ensure cursor row exists; seed to now()-5min if first run
  await pg(`
    INSERT INTO public.sync_cursors (entity, last_synced_at, last_run_status)
    VALUES ('audit_alerts', now() - INTERVAL '5 minutes', 'success')
    ON CONFLICT (entity) DO NOTHING;
  `);

  // 2. Read cursor + the window upper bound (now() - 15s buffer for late writes)
  const cursorRows = await pg(`
    SELECT last_synced_at::text AS since,
           (now() - INTERVAL '15 seconds')::text AS until
    FROM public.sync_cursors WHERE entity = 'audit_alerts';
  `);
  const { since, until } = cursorRows[0];
  console.log(`  Window: ${since} → ${until}`);

  // 3. Pull every audit row in [since, until], classify in JS to keep SQL simple
  const newRows = await pg(`
    SELECT id, table_schema, table_name, record_pk, operation,
           db_role, changed_by, changed_at::text AS changed_at,
           app_source, request_context,
           old_row, new_row
    FROM audit.logs
    WHERE changed_at >  '${since}'::timestamptz
      AND changed_at <= '${until}'::timestamptz
    ORDER BY changed_at, id;
  `);
  console.log(`  audit.logs new rows: ${newRows.length}`);

  // 4. Classify into critical buckets
  const flagged = {
    webhook_tokens_non_service_role: [],
    critical_table_delete: [],
    anon_write_outside_surface: [],
  };

  for (const r of newRows) {
    // Rule 1: webhook_tokens modified by anything but service_role,
    // unless the (source_system, db_role, app_source) tuple is in the
    // known-good cron allow-list (e.g., Jobber hourly token refresh).
    if (r.table_name === 'webhook_tokens' && r.db_role !== 'service_role') {
      const tokenKey = `${r.record_pk?.source_system ?? '?'}:${r.db_role}:${r.app_source ?? '?'}`;
      if (!WEBHOOK_TOKENS_ALLOWED.has(tokenKey)) {
        flagged.webhook_tokens_non_service_role.push(r);
      }
    }
    // Rule 2: hard DELETE on critical business tables
    if (r.operation === 'DELETE' &&
        ['clients', 'derm_manifests', 'service_configs'].includes(r.table_name)) {
      flagged.critical_table_delete.push(r);
    }
    // Rule 4: anon write outside allow-list
    if (r.db_role === 'anon' &&
        !ANON_ALLOWED.has(`${r.table_name}:${r.operation}`)) {
      flagged.anon_write_outside_surface.push(r);
    }
  }

  // Rule 3: mass-change spike. Bucket by minute.
  const spikes = [];
  const byMinute = new Map();
  for (const r of newRows) {
    const minute = r.changed_at.slice(0, 16); // 'YYYY-MM-DD HH:MM'
    byMinute.set(minute, (byMinute.get(minute) || 0) + 1);
  }
  for (const [minute, cnt] of byMinute) {
    if (cnt > 200) spikes.push({ minute, cnt });
  }

  const totalFlagged =
    flagged.webhook_tokens_non_service_role.length +
    flagged.critical_table_delete.length +
    flagged.anon_write_outside_surface.length +
    spikes.length;

  console.log(`  Flagged:`);
  console.log(`    webhook_tokens non-service-role: ${flagged.webhook_tokens_non_service_role.length}`);
  console.log(`    critical_table_delete:           ${flagged.critical_table_delete.length}`);
  console.log(`    anon_write_outside_surface:      ${flagged.anon_write_outside_surface.length}`);
  console.log(`    mass_change_spikes:              ${spikes.length}`);

  // 5. Post to Slack if anything flagged
  if (totalFlagged > 0) {
    let text = `:rotating_light: *Prod audit alert — ${totalFlagged} critical event${totalFlagged === 1 ? '' : 's'}*\n`;
    text += `_Window: ${since} → ${until}_\n`;

    if (flagged.webhook_tokens_non_service_role.length) {
      text += `\n*:key: webhook_tokens modified by non-service_role* (${flagged.webhook_tokens_non_service_role.length})\n`;
      for (const r of flagged.webhook_tokens_non_service_role.slice(0, 5)) {
        text += `• \`${r.operation}\` ${pkStr(r.record_pk)} · role=\`${r.db_role}\` · app=\`${r.app_source ?? '?'}\` · ${r.changed_at}\n`;
      }
      if (flagged.webhook_tokens_non_service_role.length > 5) {
        text += `_…and ${flagged.webhook_tokens_non_service_role.length - 5} more_\n`;
      }
    }

    if (flagged.critical_table_delete.length) {
      text += `\n*:wastebasket: Hard DELETE on critical business table* (${flagged.critical_table_delete.length})\n`;
      for (const r of flagged.critical_table_delete.slice(0, 5)) {
        text += `• \`${r.table_name}\` ${pkStr(r.record_pk)} · role=\`${r.db_role}\` · app=\`${r.app_source ?? '?'}\` · ${r.changed_at}\n`;
      }
      if (flagged.critical_table_delete.length > 5) {
        text += `_…and ${flagged.critical_table_delete.length - 5} more_\n`;
      }
    }

    if (flagged.anon_write_outside_surface.length) {
      text += `\n*:no_entry: Anon write outside allow-list* (${flagged.anon_write_outside_surface.length})\n`;
      for (const r of flagged.anon_write_outside_surface.slice(0, 5)) {
        text += `• \`${r.operation}\` \`${r.table_schema}.${r.table_name}\` ${pkStr(r.record_pk)} · app=\`${r.app_source ?? '?'}\` · ${r.changed_at}\n`;
      }
      if (flagged.anon_write_outside_surface.length > 5) {
        text += `_…and ${flagged.anon_write_outside_surface.length - 5} more_\n`;
      }
    }

    if (spikes.length) {
      text += `\n*:zap: Mass-change spike (>200/min)*\n`;
      for (const s of spikes) {
        text += `• ${s.minute} — ${s.cnt} audit events\n`;
      }
    }

    text += `\n_From \`scripts/alerts/audit_critical_poll.js\` · ADR 010._`;

    console.log('\n--- Slack preview ---');
    console.log(text);
    console.log('--- end preview ---\n');

    await postSlack(text);
  } else {
    console.log('  No critical events — no Slack post.');
  }

  // 6. Advance cursor. If we got rows, set to max(changed_at); otherwise to
  // the window upper bound so we don't re-scan the same empty range.
  const cursorTarget = newRows.length
    ? newRows[newRows.length - 1].changed_at
    : until;
  await pg(`
    UPDATE public.sync_cursors
       SET last_synced_at   = '${cursorTarget}'::timestamptz,
           last_run_started = now(),
           last_run_finished = now(),
           last_run_status  = 'success',
           rows_pulled      = ${newRows.length},
           rows_populated   = ${totalFlagged},
           updated_at       = now()
     WHERE entity = 'audit_alerts';
  `);
  console.log(`  Cursor advanced to ${cursorTarget}`);
  console.log(`[audit-critical-poll] done ${new Date().toISOString()}`);
})().catch(async e => {
  console.error('FATAL:', e.message);
  // Try to record the error in sync_cursors so we can see it in the dashboard
  try {
    await pg(`
      UPDATE public.sync_cursors
         SET last_run_finished = now(),
             last_run_status   = 'error',
             last_error        = '${e.message.replace(/'/g, "''").slice(0, 500)}',
             updated_at        = now()
       WHERE entity = 'audit_alerts';
    `);
  } catch (_) { /* swallow */ }
  process.exit(1);
});
