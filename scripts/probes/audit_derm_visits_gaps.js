// Investigate the 3 DERM Tracker Visits-list gaps Fred flagged:
//   1) line_items: many visits show service_type code ("GT"/"CL") instead of
//      real Jobber line item name (e.g. "Grey water pumping")
//   2) GDO number: should appear on every visit row, sourced from
//      gdos table joined via property
//   3) Address: some visits show no address
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PAT = process.env.SUPABASE_PAT;
const PROJECT = process.env.SUPABASE_PROJECT_ID;

async function sql(q) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query: q }),
  });
  if (!r.ok) throw new Error(`SQL ${r.status} ${await r.text()}`);
  return r.json();
}

(async () => {
  console.log('═══ DERM Visits view — gap audit ═══\n');

  // ============================================================
  // 1) LINE ITEMS — what does derm.visits return today?
  // ============================================================
  console.log('1) LINE ITEMS coverage in derm.visits');
  const li = await sql(`
    SELECT
      COUNT(*) AS total_visits,
      COUNT(line_items) FILTER (WHERE line_items IS NOT NULL AND line_items <> '') AS has_line_items,
      COUNT(*) FILTER (WHERE line_items IS NULL OR line_items = '') AS missing_line_items
    FROM derm.visits;
  `);
  console.table(li);

  // Sample: visits WITH line_items
  const sample = await sql(`SELECT id, service_type, line_items FROM derm.visits WHERE line_items IS NOT NULL AND line_items <> '' ORDER BY id DESC LIMIT 5;`);
  console.log('  Samples WITH line_items:');
  console.table(sample);

  // Sample: visits WITHOUT line_items
  const missing = await sql(`SELECT id, service_type, line_items, client_name FROM derm.visits WHERE (line_items IS NULL OR line_items = '') ORDER BY id DESC LIMIT 5;`);
  console.log('  Samples WITHOUT line_items:');
  console.table(missing);

  // Fred's specific example: 209-TRUE True Barista Truck 5/21/2026
  console.log('\n  Fred\'s example — 209-TRUE True Barista Truck 5/21/2026:');
  const trueBarista = await sql(`
    SELECT v.id, v.visit_date, v.service_type, v.title,
           dv.line_items, dv.line_items_json
    FROM derm.visits dv
    JOIN public.visits v ON v.id = dv.id
    WHERE v.client_id IN (SELECT id FROM clients WHERE client_code = '209-TRUE')
    ORDER BY v.visit_date DESC LIMIT 3;
  `);
  console.table(trueBarista);

  // Is there a separate visit_line_items / invoice_line_items table?
  const tables = await sql(`SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND (table_name LIKE '%line%' OR table_name LIKE '%item%') ORDER BY table_name;`);
  console.log('  Tables matching %line% or %item%:');
  console.table(tables);

  // ============================================================
  // 2) GDO NUMBERS — gdos table structure + coverage
  // ============================================================
  console.log('\n2) GDOs coverage');
  const gdoStats = await sql(`
    SELECT
      COUNT(*) AS total_gdos,
      COUNT(client_id) AS with_client_id,
      COUNT(property_id) AS with_property_id,
      COUNT(*) FILTER (WHERE status = 'ACTIVE') AS active
    FROM public.gdos;
  `);
  console.table(gdoStats);

  const gdoSample = await sql(`SELECT id, client_id, property_id, gdo_number, location_label, status FROM public.gdos ORDER BY id LIMIT 5;`);
  console.log('  Sample GDOs:');
  console.table(gdoSample);

  // How many clients have a GDO? How many have multiple?
  const gdosPerClient = await sql(`
    SELECT
      COUNT(DISTINCT client_id) AS distinct_clients_with_gdo,
      MAX(g_per_client) AS max_gdos_per_client,
      AVG(g_per_client)::numeric(4,2) AS avg_gdos_per_client
    FROM (SELECT client_id, COUNT(*) AS g_per_client FROM gdos GROUP BY client_id) sub;
  `);
  console.table(gdosPerClient);

  // How many properties have a GDO linked?
  const propsWithGdo = await sql(`
    SELECT
      (SELECT COUNT(*) FROM properties WHERE id IN (SELECT property_id FROM gdos WHERE property_id IS NOT NULL)) AS props_with_gdo,
      (SELECT COUNT(*) FROM properties) AS total_props;
  `);
  console.table(propsWithGdo);

  // For active/recurring clients with multiple GDOs, what does the link look like?
  const multiGdo = await sql(`
    SELECT c.client_code, c.name, COUNT(g.id) AS gdo_count,
           array_agg(g.gdo_number ORDER BY g.gdo_number) AS gdos
    FROM clients c JOIN gdos g ON g.client_id = c.id
    WHERE c.status IN ('ACTIVE','RECURRING')
    GROUP BY c.id, c.client_code, c.name
    HAVING COUNT(g.id) > 1
    ORDER BY gdo_count DESC LIMIT 10;
  `);
  console.log('  Clients with multiple GDOs:');
  console.table(multiGdo);

  // ============================================================
  // 3) ADDRESS GAPS in derm.visits
  // ============================================================
  console.log('\n3) ADDRESS coverage in derm.visits');
  const addrStats = await sql(`
    SELECT
      COUNT(*) AS total_visits,
      COUNT(address) FILTER (WHERE address IS NOT NULL AND address <> '') AS has_address,
      COUNT(*) FILTER (WHERE address IS NULL OR address = '') AS missing_address
    FROM derm.visits;
  `);
  console.table(addrStats);

  // Missing-address samples
  const missingAddr = await sql(`
    SELECT dv.id, dv.client_name, dv.address, dv.visit_date,
           v.property_id, p.address AS prop_addr, p.city AS prop_city
    FROM derm.visits dv
    JOIN public.visits v ON v.id = dv.id
    LEFT JOIN public.properties p ON p.id = v.property_id
    WHERE (dv.address IS NULL OR dv.address = '')
    ORDER BY dv.id DESC LIMIT 10;
  `);
  console.log('  Samples missing address:');
  console.table(missingAddr);
})().catch(err => { console.error(err); process.exit(1); });
