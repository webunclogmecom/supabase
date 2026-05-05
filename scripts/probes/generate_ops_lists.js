// Regenerate OPS_LIST_DIEGO.md and OPS_LIST_YAN.md from current DB state.
// Run after replays and visit-status fixes to ensure the lists reflect reality.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const fs = require('fs');
const path = require('path');

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      const c = []; r.on('data', x => c.push(x));
      r.on('end', () => res({ status: r.statusCode, body: Buffer.concat(c).toString() }));
    });
    req.on('error', rej); if (body) req.write(body); req.end();
  });
}
async function pg(sql) {
  const r = await http({
    hostname: 'api.supabase.com',
    path: `/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`,
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' }
  }, JSON.stringify({ query: sql }));
  return JSON.parse(r.body);
}

(async () => {
  const overdue = await pg(`
    WITH ch AS (
      SELECT c.id, c.client_code, c.name, MIN(sc.frequency_days) AS shortest_freq
      FROM clients c JOIN service_configs sc ON sc.client_id=c.id
      WHERE c.status IN ('ACTIVE','Recuring') AND sc.frequency_days BETWEEN 10 AND 180
      GROUP BY c.id
    ),
    last_visit AS (
      SELECT client_id, MAX(visit_date) AS last_done
      FROM visits WHERE visit_status='completed'
      GROUP BY client_id
    )
    SELECT ch.client_code, ch.name, ch.shortest_freq,
      lv.last_done::text AS last_done,
      (CURRENT_DATE - lv.last_done) AS days_since
    FROM ch
    LEFT JOIN last_visit lv ON lv.client_id = ch.id
    WHERE NOT EXISTS (SELECT 1 FROM visits v WHERE v.client_id=ch.id AND v.visit_date >= CURRENT_DATE)
      AND lv.last_done IS NOT NULL
      AND (CURRENT_DATE - lv.last_done)::numeric / ch.shortest_freq BETWEEN 1.0 AND 2.0
    ORDER BY (CURRENT_DATE - lv.last_done)::numeric / ch.shortest_freq DESC;
  `);

  const abandoned = await pg(`
    WITH ch AS (
      SELECT c.id, c.client_code, c.name, MIN(sc.frequency_days) AS shortest_freq,
        STRING_AGG(sc.service_type || ':' || sc.frequency_days::text, ', ' ORDER BY sc.service_type) AS configs
      FROM clients c JOIN service_configs sc ON sc.client_id=c.id
      WHERE c.status IN ('ACTIVE','Recuring') AND sc.frequency_days BETWEEN 10 AND 180
      GROUP BY c.id
    ),
    last_visit AS (
      SELECT client_id, MAX(visit_date) AS last_done
      FROM visits WHERE visit_status='completed'
      GROUP BY client_id
    )
    SELECT ch.client_code, ch.name, ch.configs,
      lv.last_done::text AS last_done,
      (CURRENT_DATE - lv.last_done) AS days_since
    FROM ch
    LEFT JOIN last_visit lv ON lv.client_id = ch.id
    WHERE NOT EXISTS (SELECT 1 FROM visits v WHERE v.client_id=ch.id AND v.visit_date >= CURRENT_DATE)
      AND (lv.last_done IS NULL
           OR (CURRENT_DATE - lv.last_done)::numeric / ch.shortest_freq > 2.0)
    ORDER BY ch.client_code;
  `);

  const broken = await pg(`
    SELECT c.client_code, c.name,
      STRING_AGG(sc.service_type || '=' || sc.frequency_days::text, ', ' ORDER BY sc.service_type) AS broken_configs
    FROM clients c JOIN service_configs sc ON sc.client_id=c.id
    WHERE c.status IN ('ACTIVE','Recuring')
      AND (sc.frequency_days = 0 OR sc.frequency_days > 180)
    GROUP BY c.client_code, c.name
    ORDER BY c.client_code;
  `);

  // ---- Diego doc ----
  let diego = `# Overdue clients — schedule next visit\n\n`;
  diego += `_Generated 2026-05-04 from Supabase audit. ${overdue.length} clients past their normal service frequency with no upcoming visit on the calendar._\n\n`;
  diego += `Sorted by how overdue they are. Top of list = most urgent.\n\n`;
  diego += `| # | Client code | Client name | Service every | Last visit | Days since | Past due |\n`;
  diego += `|---|---|---|---|---|---|---|\n`;
  let i = 1;
  for (const r of overdue) {
    const ratio = (Number(r.days_since) / Number(r.shortest_freq)).toFixed(1);
    diego += `| ${i++} | ${r.client_code} | ${(r.name||'').replace(/\|/g,'\\|').slice(0,45)} | ${r.shortest_freq}d | ${r.last_done} | ${r.days_since} | ${ratio}x |\n`;
  }
  diego += `\n## What to do\n\nFor each row, schedule a visit in Jobber. The frequency column is what the client should be getting — match it.\n`;
  fs.writeFileSync(path.resolve(__dirname, '../../OPS_LIST_DIEGO.md'), diego);

  // ---- Yan doc ----
  let yan = `# Yan to-do list — service config + abandoned client review\n\n`;
  yan += `_Generated 2026-05-04 from Supabase audit (after fixing 58 visits stuck in 'scheduled' status due to a polling-cron bug)._\n\n`;
  yan += `## Part 1: Fix ${broken.length} service-config frequencies in Airtable\n\n`;
  yan += `These have invalid frequencies (0 days = invalid, >180 days = once a year or worse). Fix in Airtable — the webhook syncs to our DB automatically.\n\n`;
  yan += `| Client code | Client name | Broken configs | Issue |\n|---|---|---|---|\n`;
  for (const r of broken) {
    const issue = r.broken_configs.includes('=0') ? 'zero — never service' : 'way too long (>180 days)';
    yan += `| ${r.client_code} | ${(r.name||'').slice(0,40)} | ${r.broken_configs} | ${issue} |\n`;
  }
  yan += `\n## Part 2: Review ${abandoned.length} abandoned clients — activate or mark INACTIVE/PAUSED\n\n`;
  yan += `These are ACTIVE/Recuring clients with EITHER no completed visit ever OR last visit was more than 2x their service frequency ago. Decide each: schedule a first/next visit OR change status to INACTIVE/PAUSED.\n\n`;
  yan += `| # | Client code | Client name | Configs | Last visit | Days since |\n|---|---|---|---|---|---|\n`;
  i = 1;
  for (const r of abandoned) {
    yan += `| ${i++} | ${r.client_code || '?'} | ${(r.name||'').replace(/\|/g,'\\|').slice(0,40)} | ${(r.configs||'').slice(0,25)} | ${r.last_done || 'never'} | ${r.days_since ?? '∞'} |\n`;
  }
  yan += `\n## Part 3: Other items needing review\n\n`;
  yan += `- **140-TYO typo**: in our DB the client_code is \`140-TYO\` but the Jobber/Airtable name is \`140-TCY Tacos yoyo\`. Pick one canonical spelling.\n`;
  yan += `- **26 TCE chain locations on CL=120 days** — if 4 months between cleanings is the agreed chain standard, no action.\n`;
  yan += `- **43 DERM manifests with NULL service_date** — sync gap from Airtable. Either Airtable rows are missing the date and need backfill, or accept the legacy gap.\n`;
  yan += `- **8 commercial visits with no photos** — drivers should be taking photos. Visit IDs: 1241(174-VIN), 1279(170-PV), 1289(182-PAL), 1320(043-MIL), 1396(025-GRO), 1468(112-YA), 1716(195-MYK), 1730(191-TEN).\n`;
  yan += `- **201-ALA Aladdin** — residential site, removed from list (had a meeting visit Apr 22 not tracked as service).\n`;
  fs.writeFileSync(path.resolve(__dirname, '../../OPS_LIST_YAN.md'), yan);

  console.log(`Diego: ${overdue.length} overdue clients`);
  console.log(`Yan: ${broken.length} broken configs + ${abandoned.length} abandoned`);
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
