// Full AT-canonical field audit for every linked client.
//
// What AT owns (per CLAUDE.md trust hierarchy):
//   - clients.client_code           ← AT 'Client Code #3'
//   - clients.status                ← AT 'ACTIVE/INACTIVE'  (already audited)
//   - properties.access_hours_start ← AT 'Hours in'
//   - properties.access_hours_end   ← AT 'Hours out'
//   - properties.access_days        ← AT 'Days of the week'
//   - properties.zone               ← AT 'Zone' (singleSelect)
//   - properties.county             ← AT 'County' (singleSelect)
//   - properties.grease_trap_manhole_count ← AT 'manholes'
//   - service_configs.frequency_days       ← AT '{type} Frequency'
//   - service_configs.price_per_visit      ← AT '{type} $ per Visit'
//   - service_configs.equipment_size_gallons ← AT 'Size GT in Gallon' (GT only)
//   - service_configs.permit_number        ← AT 'GDO Number'   (GT only)
//   - service_configs.permit_expiration    ← AT 'GDO expiration date' (GT only)
//
// What's NOT in scope (Jobber owns):
//   - clients.name, clients.balance
//   - properties.address, city, state, zip
//   - visits.start_at, completed_at, etc.
//
// Run with no flag = audit only.  Pass --execute to UPDATE Sbx to match AT.
// Use --section=client|property|config|status to limit scope.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const EXECUTE = process.argv.includes('--execute');
const SECTION = (process.argv.find(a => a.startsWith('--section=')) || '').split('=')[1] || null;

function http(opts, body) { return new Promise((res, rej) => {
  const req = https.request(opts, r => { const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()})); });
  req.on('error',rej); if(body) req.write(body); req.end();
});}
async function pg(s) { const r = await http({hostname:'api.supabase.com',path:'/v1/projects/'+PROD+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}}, JSON.stringify({query:s})); if(r.status>=300) throw new Error('PG '+r.status+': '+r.body.slice(0,300)); return JSON.parse(r.body); }
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

// Normalize a single AT singleSelect / multipleSelects value to a string
function selName(v) {
  if (v == null) return null;
  if (typeof v === 'string') return v;
  if (Array.isArray(v)) return v.map(x => (x && typeof x === 'object' ? x.name : x)).filter(Boolean).join(',') || null;
  if (typeof v === 'object') return v.name || null;
  return String(v);
}
function normStatus(s) {
  const v = selName(s);
  if (!v) return null;
  const u = v.toUpperCase().trim();
  return u === 'RECURING' ? 'RECURRING' : u;
}
function pgEsc(s) { return s == null ? 'NULL' : "'" + String(s).replace(/'/g, "''") + "'"; }
function pgNum(n) { return n == null ? 'NULL' : String(Number(n)); }
function pgInt(n) { return n == null ? 'NULL' : String(Math.round(Number(n))); }
function pgDate(d) { return d ? "'" + String(d).slice(0,10) + "'" : 'NULL'; }

// AT field name per service type
const FIELDS = {
  GT: { freq: 'GT Frequency', price: 'GT $ per Visit',         size: 'Size GT in Gallon', gdoNum: 'GDO Number', gdoExp: 'GDO expiration date' },
  CL: { freq: 'CL Frequency', price: 'CL$ Price per Visit' },
  WD: { freq: 'WD Frequency', price: 'WD$ Price per Visit' },
};

(async () => {
  console.log(`Mode: ${EXECUTE ? 'EXECUTE (will UPDATE Sbx to AT)' : 'AUDIT ONLY'}` + (SECTION ? `   Section: ${SECTION}` : '') + '\n');

  // Pull AT clients with everything
  const atFields = ['Client Name','Client Code #3','ACTIVE/INACTIVE','Service Type',
    'Hours in','Hours out','Days of the week','Zone','County','manholes',
    'GT Frequency','CL Frequency','WD Frequency',
    'GT $ per Visit','CL$ Price per Visit','WD$ Price per Visit',
    'Size GT in Gallon','GDO Number','GDO expiration date'];
  const at = await listAT('Clients', atFields);
  const atById = new Map(at.map(c => [c.id, c]));
  console.log('AT clients:', at.length);

  // Pull Sbx clients + primary properties + service_configs
  const sbxClients = await pg(`
    SELECT c.id, c.client_code, c.name, c.status,
      (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='airtable' LIMIT 1) AS at_id
    FROM clients c;
  `);
  const sbxProps = await pg(`
    SELECT p.id, p.client_id, p.access_hours_start::text AS hin, p.access_hours_end::text AS hout,
      p.access_days, p.zone, p.county, p.grease_trap_manhole_count AS mh
    FROM properties p WHERE p.is_primary = true OR p.is_primary IS NULL;
  `);
  const propByClient = new Map();
  for (const p of sbxProps) if (!propByClient.has(p.client_id)) propByClient.set(p.client_id, p);

  const sbxConfigs = await pg(`
    SELECT sc.id, sc.client_id, sc.service_type, sc.frequency_days, sc.price_per_visit,
      sc.equipment_size_gallons, sc.permit_number, sc.permit_expiration::text AS perm_exp
    FROM service_configs sc;
  `);
  const configsByClient = new Map();
  for (const sc of sbxConfigs) {
    if (!configsByClient.has(sc.client_id)) configsByClient.set(sc.client_id, []);
    configsByClient.get(sc.client_id).push(sc);
  }

  const drift = { client: [], property: [], config: [] };
  const updates = []; // {sql: '...', label: 'client_code:140-TYO'}

  for (const c of sbxClients) {
    if (!c.at_id) continue;
    const ac = atById.get(c.at_id);
    if (!ac) continue;

    // === CLIENT-LEVEL ===
    const atCode = selName(ac['Client Code #3']);
    if (atCode && atCode !== c.client_code) {
      drift.client.push({ cc: c.client_code, name: c.name, field: 'client_code', sbx: c.client_code, at: atCode });
      updates.push({ sql: `UPDATE clients SET client_code=${pgEsc(atCode)} WHERE id=${c.id};`, label: 'client.client_code:'+(c.client_code||'?') });
    }
    const atStatus = normStatus(ac['ACTIVE/INACTIVE']);
    if (atStatus && atStatus !== c.status) {
      drift.client.push({ cc: c.client_code, name: c.name, field: 'status', sbx: c.status, at: atStatus });
      updates.push({ sql: `UPDATE clients SET status=${pgEsc(atStatus)} WHERE id=${c.id};`, label: 'client.status:'+(c.client_code||'?') });
    }

    // === PROPERTY-LEVEL ===
    const p = propByClient.get(c.id);
    if (p) {
      const compare = [
        ['access_hours_start', p.hin, selName(ac['Hours in'])],
        ['access_hours_end',   p.hout, selName(ac['Hours out'])],
        ['zone',               p.zone, selName(ac['Zone'])],
        ['county',             p.county, selName(ac['County'])],
        ['grease_trap_manhole_count', p.mh, ac['manholes'] != null ? Number(ac['manholes']) : null],
      ];
      for (const [field, sbxv, atv] of compare) {
        const sNorm = sbxv == null ? null : String(sbxv);
        const aNorm = atv == null ? null : String(atv);
        if (atv != null && sNorm !== aNorm) {
          drift.property.push({ cc: c.client_code, name: c.name, field, sbx: sNorm, at: aNorm });
          const col = field;
          const val = field === 'grease_trap_manhole_count' ? pgInt(atv) : pgEsc(atv);
          updates.push({ sql: `UPDATE properties SET ${col}=${val} WHERE id=${p.id};`, label: 'prop.'+field+':'+(c.client_code||'?') });
        }
      }
      // access_days (multipleSelects in AT, array in Sbx)
      const sbxDays = Array.isArray(p.access_days) ? p.access_days.slice().sort().join(',') : null;
      const atDaysRaw = ac['Days of the week'];
      const atDays = Array.isArray(atDaysRaw) ? atDaysRaw.map(d => (d && d.name) || d).filter(Boolean).map(s => s.toLowerCase().slice(0,3)).sort().join(',') : null;
      if (atDays && sbxDays !== atDays) {
        drift.property.push({ cc: c.client_code, name: c.name, field: 'access_days', sbx: sbxDays, at: atDays });
        const arr = atDays.split(',').map(d => "'" + d + "'").join(',');
        updates.push({ sql: `UPDATE properties SET access_days=ARRAY[${arr}]::text[] WHERE id=${p.id};`, label: 'prop.access_days:'+(c.client_code||'?') });
      }
    }

    // === SERVICE_CONFIGS LEVEL ===
    const configs = configsByClient.get(c.id) || [];
    for (const sc of configs) {
      const F = FIELDS[sc.service_type];
      if (!F) continue;
      const atFreq = F.freq && typeof ac[F.freq] === 'number' ? ac[F.freq] : null;
      const atPrice = F.price && typeof ac[F.price] === 'number' ? ac[F.price] : null;
      if (atFreq != null && Number(sc.frequency_days) !== atFreq) {
        drift.config.push({ cc: c.client_code, name: c.name, svc: sc.service_type, field: 'frequency_days', sbx: sc.frequency_days, at: atFreq });
        updates.push({ sql: `UPDATE service_configs SET frequency_days=${atFreq} WHERE id=${sc.id};`, label: 'cfg.freq:'+(c.client_code||'?')+'/'+sc.service_type });
      }
      if (atPrice != null && Number(sc.price_per_visit) !== atPrice) {
        drift.config.push({ cc: c.client_code, name: c.name, svc: sc.service_type, field: 'price_per_visit', sbx: sc.price_per_visit, at: atPrice });
        updates.push({ sql: `UPDATE service_configs SET price_per_visit=${atPrice} WHERE id=${sc.id};`, label: 'cfg.price:'+(c.client_code||'?')+'/'+sc.service_type });
      }
      if (sc.service_type === 'GT') {
        if (F.size && typeof ac[F.size] === 'number' && Number(sc.equipment_size_gallons) !== ac[F.size]) {
          drift.config.push({ cc: c.client_code, name: c.name, svc: sc.service_type, field: 'equipment_size_gallons', sbx: sc.equipment_size_gallons, at: ac[F.size] });
          updates.push({ sql: `UPDATE service_configs SET equipment_size_gallons=${ac[F.size]} WHERE id=${sc.id};`, label: 'cfg.size:'+(c.client_code||'?') });
        }
        const atGdoNum = ac[F.gdoNum] || null;
        if (atGdoNum && sc.permit_number !== atGdoNum) {
          drift.config.push({ cc: c.client_code, name: c.name, svc: sc.service_type, field: 'permit_number', sbx: sc.permit_number, at: atGdoNum });
          updates.push({ sql: `UPDATE service_configs SET permit_number=${pgEsc(atGdoNum)} WHERE id=${sc.id};`, label: 'cfg.gdo_num:'+(c.client_code||'?') });
        }
        const atGdoExp = ac[F.gdoExp] ? String(ac[F.gdoExp]).slice(0,10) : null;
        if (atGdoExp && sc.perm_exp !== atGdoExp) {
          drift.config.push({ cc: c.client_code, name: c.name, svc: sc.service_type, field: 'permit_expiration', sbx: sc.perm_exp, at: atGdoExp });
          updates.push({ sql: `UPDATE service_configs SET permit_expiration=${pgDate(atGdoExp)} WHERE id=${sc.id};`, label: 'cfg.gdo_exp:'+(c.client_code||'?') });
        }
      }
    }
  }

  // === Output ===
  const sections = SECTION ? [SECTION] : ['client','property','config'];
  let total = 0;
  for (const s of sections) {
    const list = drift[s];
    if (!list || !list.length) continue;
    total += list.length;
    console.log('\n=== '+s.toUpperCase()+'-level drift ('+list.length+' rows) ===');
    for (const d of list) {
      const svc = d.svc ? '/'+d.svc : '';
      console.log('  '+(d.cc || '(no code)').padEnd(11)+(d.field+svc).padEnd(34)+' Sbx='+String(d.sbx).padEnd(22)+' AT='+d.at);
    }
  }
  console.log('\n=== TOTAL drift: '+total+' rows ===');

  if (!EXECUTE || total === 0) {
    if (total && !EXECUTE) console.log('\n[AUDIT] Re-run with --execute to sync Sbx to AT.');
    return;
  }

  console.log('\nApplying '+updates.length+' updates...');
  // Apply in a single transaction
  const sql = 'BEGIN; ' + updates.map(u => u.sql).join(' ') + ' COMMIT;';
  await pg(sql);
  console.log('Done.');
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
