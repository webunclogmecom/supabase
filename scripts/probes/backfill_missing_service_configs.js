// Create service_configs rows for AT clients whose Service Type field
// indicates a subscription (GT/CL/WD/LS) but no Sbx config exists yet.
// Idempotent: ON CONFLICT (client_id, service_type) DO NOTHING.
//
// Why this is needed: populate.js step 5 skips a row when price AND freq are
// both NULL. So clients with Service Type ticked but unfilled freq/price get
// silently dropped. 2026-05-12 cross-source audit found 82 such cases
// (7 GT + 31 CL + 44 WD). Creating placeholder rows surfaces them on Yan's
// fix list and makes the data model honest about what the client is signed
// up for.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:'/v1/projects/'+PROD+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error('PG '+r.status+': '+r.body.slice(0,300)); return JSON.parse(r.body); }
async function listAT(table, fields, filter) {
  const out=[]; let offset; const enc=encodeURIComponent;
  do {
    const fp = (fields||[]).map(f => 'fields%5B%5D='+enc(f)).join('&');
    const ff = filter ? '&filterByFormula='+enc(filter) : '';
    const path = '/v0/'+AT_BASE+'/'+enc(table)+'?'+fp+'&pageSize=100'+ff+(offset?'&offset='+enc(offset):'');
    const r = await http({hostname:'api.airtable.com',path,method:'GET',headers:{Authorization:'Bearer '+AT_KEY}});
    if (r.status>=300) throw new Error('AT '+r.status+': '+r.body.slice(0,200));
    const j = JSON.parse(r.body);
    for (const rec of (j.records||[])) out.push({id:rec.id, ...rec.fields});
    offset = j.offset;
  } while (offset);
  return out;
}

(async () => {
  console.log('Pulling AT Clients + Sbx client links + existing configs...');
  const atClients = await listAT('Clients',
    ['Client Name','ACTIVE/INACTIVE','Service Type',
     'GT Frequency','CL Frequency','WD Frequency',
     'GT $ per Visit','CL$ Price per Visit','WD$ Price per Visit',
     'Size GT in Gallon','GDO Number','GDO expiration date',
     'GT First Visit Date','CL First Visit Date','WD Contract Date']);

  // Sbx client + service_configs state
  const sbxClients = await pg(`
    SELECT c.id, c.client_code,
      (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='airtable' LIMIT 1) AS at_id
    FROM clients c
    WHERE EXISTS (SELECT 1 FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='airtable');`);
  const atToSbx = new Map(sbxClients.filter(c => c.at_id).map(c => [c.at_id, c.id]));

  const existing = await pg(`SELECT client_id, service_type FROM service_configs;`);
  const existingKeys = new Set(existing.map(c => c.client_id + '|' + c.service_type));

  // CANONICAL: Service Type multi-select is the only authoritative signal for
  // whether a client subscribes to a service. Frequency fields can hold junk
  // values (021-GRA had GT Frequency=360 even though AT only marks them as
  // CL+WD; audit 2026-05-13 caught 16 bogus configs created from freq alone).
  // Per CLAUDE.md trust hierarchy + memory rule:
  //   "Airtable Service Type is canonical for subscriptions —
  //    GT/CL Frequency fields can carry junk values for clients who don't
  //    subscribe; use the Service Type multiselect as source of truth."
  function inferTypes(ac) {
    // Canonical AT Service Type → our code (audit 2026-05-14, confirmed by Fred):
    //   "Grease Trap"          → GT
    //   "Gray Water pumping"   → GT  (GT-alternative service)
    //   "AUX Cleaning"         → CL  (NOT "Main CL")
    //   "Warranty of drainage" → WD
    //   "Lift Station"         → LS  (NOT 'lyft')
    //   "Main CL", "Catch Bassin", "Floor Drain Cleaning",
    //   "Requires Phone Call"  → no mapping (org-labels / services we don't perform)
    const types = new Set();
    const st = ac['Service Type'];
    if (!Array.isArray(st)) return types;
    for (const v of st) {
      const sl = ((v && v.name) || v || '').toString().toLowerCase();
      if (sl.includes('grease trap') || sl === 'gt' || sl.includes('gray water pumping')) types.add('GT');
      else if (sl.includes('aux cleaning') || sl === 'cl') types.add('CL');
      else if (sl === 'wd' || sl.includes('warranty') || sl.includes('water dis')) types.add('WD');
      else if (sl.includes('lift station') || sl === 'ls') types.add('LS');
    }
    return types;
  }

  // AT field name per service type
  const FIELDS = {
    GT: { freq: 'GT Frequency', price: 'GT $ per Visit',         first: 'GT First Visit Date', size: 'Size GT in Gallon', gdoNum: 'GDO Number', gdoExp: 'GDO expiration date' },
    CL: { freq: 'CL Frequency', price: 'CL$ Price per Visit',    first: 'CL First Visit Date' },
    WD: { freq: 'WD Frequency', price: 'WD$ Price per Visit',    first: 'WD Contract Date' },
    LS: { /* AT has no LS-specific fields */ },
  };

  function dateOnly(v) { if (!v) return null; const s = String(v); return s.slice(0,10); }
  function numOrNull(v) { if (v === null || v === undefined || v === '') return null; const n = Number(v); return Number.isFinite(n) ? n : null; }

  const toInsert = [];
  for (const ac of atClients) {
    const cid = atToSbx.get(ac.id);
    if (!cid) continue;
    const status = (ac['ACTIVE/INACTIVE']?.name) || ac['ACTIVE/INACTIVE'];
    if (status === 'INACTIVE') continue;
    const types = inferTypes(ac);
    for (const t of types) {
      if (existingKeys.has(cid + '|' + t)) continue;
      const F = FIELDS[t] || {};
      toInsert.push({
        client_id: cid,
        service_type: t,
        frequency_days: F.freq ? numOrNull(ac[F.freq]) : null,
        price_per_visit: F.price ? numOrNull(ac[F.price]) : null,
        first_visit: F.first ? dateOnly(ac[F.first]) : null,
        equipment_size_gallons: F.size ? numOrNull(ac[F.size]) : null,
        permit_number: F.gdoNum ? (ac[F.gdoNum] || null) : null,
        permit_expiration: F.gdoExp ? dateOnly(ac[F.gdoExp]) : null,
      });
    }
  }

  console.log('\nRows to insert:', toInsert.length);
  const byType = {};
  for (const r of toInsert) byType[r.service_type] = (byType[r.service_type] || 0) + 1;
  console.log('  by type:', JSON.stringify(byType));

  if (!toInsert.length) { console.log('Nothing to do.'); return; }

  // Bulk insert via SQL
  const values = toInsert.map(r => {
    const v = (x) => x === null ? 'NULL' : (typeof x === 'number' ? x : `'${String(x).replace(/'/g, "''")}'`);
    return `(${v(r.client_id)}, ${v(r.service_type)}, ${v(r.frequency_days)}, ${v(r.price_per_visit)}, ${v(r.first_visit)}, ${v(r.equipment_size_gallons)}, ${v(r.permit_number)}, ${v(r.permit_expiration)})`;
  }).join(',\n');
  const sql = `
    INSERT INTO service_configs
      (client_id, service_type, frequency_days, price_per_visit, first_visit, equipment_size_gallons, permit_number, permit_expiration)
    VALUES ${values}
    ON CONFLICT (client_id, service_type) DO NOTHING
    RETURNING client_id, service_type;
  `;
  const inserted = await pg(sql);
  console.log('\nInserted:', inserted.length);

  // Final state
  const final = await pg(`
    SELECT service_type, COUNT(*)::int AS total,
      COUNT(*) FILTER (WHERE price_per_visit IS NULL)::int AS null_price,
      COUNT(*) FILTER (WHERE frequency_days IS NULL)::int AS null_freq
    FROM service_configs
    JOIN clients c ON c.id = service_configs.client_id
    WHERE c.status IN ('ACTIVE','Recuring')
    GROUP BY service_type ORDER BY service_type;
  `);
  console.log('\nFinal state (ACTIVE + Recurring only):');
  console.log(' type total null_price null_freq');
  for (const r of final) console.log(' '+r.service_type.padEnd(5)+String(r.total).padStart(4)+'    '+String(r.null_price).padStart(4)+'      '+String(r.null_freq).padStart(4));
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
