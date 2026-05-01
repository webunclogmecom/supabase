// ============================================================================
// daily_no_photo_visits_alert.js — daily ops alert
// ============================================================================
// Runs every morning. Posts to #viktor-supabase a list of yesterday's
// completed visits that have NO photos (direct visit photos AND no
// attached-note photos). Driver/office can chase same-day.
//
// Per Fred 2026-05-01: testing phase — no @ tags. Channel: #viktor-supabase
// (C0B08S21HHD).
//
// Required GH Action secrets:
//   SUPABASE_URL, SUPABASE_PAT, SLACK_BOT_TOKEN
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
  return JSON.parse(r.body);
}

async function postSlack(text) {
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

(async () => {
  console.log(`[daily-no-photo-alert] start ${new Date().toISOString()}`);

  // Yesterday in ET (operations time zone)
  // Convert "today UTC" minus 1 day to ET via SQL.
  const visits = await pg(`
    WITH yesterday_et AS (
      SELECT (now() AT TIME ZONE 'America/New_York')::date - 1 AS d
    )
    SELECT v.id, v.visit_date::text AS date, c.client_code, c.name AS client_name, v.title,
           v.completed_at::text AS completed_at,
           STRING_AGG(DISTINCT e.full_name, ', ') AS drivers,
           v.truck
    FROM visits v
    JOIN clients c ON c.id = v.client_id
    LEFT JOIN visit_assignments va ON va.visit_id = v.id
    LEFT JOIN employees e ON e.id = va.employee_id
    , yesterday_et y
    WHERE v.visit_status = 'completed'
      AND v.visit_date = y.d
      AND NOT EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='visit' AND pl.entity_id=v.id)
      AND NOT EXISTS (SELECT 1 FROM notes n WHERE n.visit_id=v.id AND EXISTS (SELECT 1 FROM photo_links pl WHERE pl.entity_type='note' AND pl.entity_id=n.id))
      AND EXISTS (SELECT 1 FROM entity_source_links esl WHERE esl.entity_type='visit' AND esl.entity_id=v.id AND esl.source_system='jobber')
    GROUP BY v.id, v.visit_date, c.client_code, c.name, v.title, v.completed_at, v.truck
    ORDER BY v.visit_date, c.client_code;
  `);

  const date = (await pg(`SELECT (now() AT TIME ZONE 'America/New_York')::date - 1 AS d`))[0].d;

  console.log(`  Yesterday (ET): ${date}`);
  console.log(`  Photo-less completed visits: ${visits.length}`);

  if (visits.length === 0) {
    const text = `:white_check_mark: *Photo audit ${date}*: all completed visits have photos. :tada:`;
    await postSlack(text);
    return;
  }

  const lines = visits.slice(0, 20).map(v => {
    const driver = v.drivers || '_(unassigned)_';
    const truck = v.truck ? ` · 🚚 ${v.truck}` : '';
    const title = (v.title || '').slice(0, 60);
    return `• \`${v.client_code || '?'}\` ${title}${truck} · 👤 ${driver}`;
  });

  let text = `:camera_with_flash: *No-photo completed visits — ${date}*\n`;
  text += `${visits.length} visit${visits.length === 1 ? '' : 's'} need${visits.length === 1 ? 's' : ''} photos chased:\n\n`;
  text += lines.join('\n');
  if (visits.length > 20) text += `\n_…and ${visits.length - 20} more (full list in DB: \`SELECT … FROM visits WHERE visit_date='${date}'…\`)_`;
  text += `\n\n_Daily check from \`scripts/sync/daily_no_photo_visits_alert.js\`._`;

  console.log('\n--- Slack message preview ---');
  console.log(text);
  console.log('--- end preview ---\n');

  await postSlack(text);
  console.log(`[daily-no-photo-alert] done ${new Date().toISOString()}`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
