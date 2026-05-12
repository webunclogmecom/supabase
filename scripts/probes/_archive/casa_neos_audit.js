// One-shot audit: verify Casa Neos visits post-repop (2026-04-29)
// Confirms cross-source dedup worked + measures remaining same-day collisions.

require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const { newQuery } = require('../populate/lib/db');

(async () => {
  console.log('=== CASA NEOS POST-REPOP AUDIT ===\n');

  const clients = await newQuery(`SELECT id, name, status FROM clients WHERE name ILIKE '%casa%neos%' ORDER BY id;`);
  console.log(`Casa Neos client rows: ${clients.length}`);
  for (const c of clients) console.log(`  id=${c.id} name="${c.name}" status=${c.status}`);
  if (!clients.length) { console.log('No Casa Neos client found.'); process.exit(0); }

  const clientId = clients[0].id;

  const visits = await newQuery(`
    SELECT v.id, v.visit_date, v.start_at, v.end_at, v.visit_status, v.service_type, v.truck, v.completed_by, v.invoice_id,
           (SELECT COUNT(*) FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='jobber')::int AS jobber_links,
           (SELECT COUNT(*) FROM entity_source_links WHERE entity_type='visit' AND entity_id=v.id AND source_system='airtable')::int AS airtable_links
    FROM visits v WHERE v.client_id=${clientId} ORDER BY v.visit_date DESC, v.id;
  `);

  console.log(`\nTotal visits for Casa Neos: ${visits.length}`);
  if (visits.length) {
    const dates = visits.map(v => (v.visit_date.toISOString ? v.visit_date.toISOString().slice(0,10) : String(v.visit_date).slice(0,10)));
    console.log(`Date range: ${dates[dates.length-1]} → ${dates[0]}`);
  }

  const byDate = new Map();
  for (const v of visits) {
    const k = v.visit_date.toISOString ? v.visit_date.toISOString().slice(0,10) : String(v.visit_date).slice(0,10);
    if (!byDate.has(k)) byDate.set(k, []);
    byDate.get(k).push(v);
  }

  const sameDayDups = [...byDate.entries()].filter(([d, vs]) => vs.length > 1);
  console.log(`\nSame-day duplicate dates: ${sameDayDups.length}`);
  for (const [d, vs] of sameDayDups.slice(0, 10)) {
    console.log(`  ${d}: ${vs.length} visits — IDs: ${vs.map(v => v.id).join(', ')}, jobber_links=${vs.map(v => v.jobber_links).join('/')}, airtable_links=${vs.map(v => v.airtable_links).join('/')}`);
  }

  const merged = visits.filter(v => v.jobber_links > 0 && v.airtable_links > 0);
  const jobberOnly = visits.filter(v => v.jobber_links > 0 && v.airtable_links === 0).length;
  const airtableOnly = visits.filter(v => v.jobber_links === 0 && v.airtable_links > 0).length;

  console.log(`\nSource breakdown:`);
  console.log(`  Jobber-only (no AT match): ${jobberOnly}`);
  console.log(`  AT-only (pre-Jobber historical): ${airtableOnly}`);
  console.log(`  Merged (Jobber + AT same row): ${merged.length}`);

  const derm = await newQuery(`
    SELECT v.visit_date, COUNT(DISTINCT mv.manifest_id)::int AS manifest_count
    FROM visits v LEFT JOIN manifest_visits mv ON mv.visit_id=v.id
    WHERE v.client_id=${clientId} GROUP BY v.visit_date HAVING COUNT(DISTINCT mv.manifest_id) > 0
    ORDER BY v.visit_date DESC LIMIT 10;
  `);
  console.log(`\nDERM-linked visit dates (top 10):`);
  for (const r of derm) {
    const d = r.visit_date.toISOString ? r.visit_date.toISOString().slice(0,10) : r.visit_date;
    console.log(`  ${d}: ${r.manifest_count} manifest(s)`);
  }

  const va = await newQuery(`
    SELECT COUNT(*)::int AS cnt FROM visit_assignments va JOIN visits v ON v.id=va.visit_id WHERE v.client_id=${clientId};
  `);
  console.log(`\nvisit_assignments rows for Casa Neos: ${va[0].cnt}`);

  process.exit(0);
})().catch(e => { console.error(e); process.exit(1); });
