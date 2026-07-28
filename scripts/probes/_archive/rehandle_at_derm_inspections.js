// One-shot: re-handle every AT DERM + PRE-POST inspection record with the
// patched handler logic, going DIRECT to Sbx (bypassing the webhook gateway's
// JWT enforcement which only AT automations satisfy). Same field mapping as
// the deployed webhook-airtable handlers.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const SUPABASE_URL = process.env.SUPABASE_URL;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;

function http(opts, body) { return new Promise((res, rej) => {
  const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
  const req = https.request({...opts, headers:{...(opts.headers||{}), ...(payload?{'Content-Length':Buffer.byteLength(payload)}:{})}}, r => {
    const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()}));
  });
  req.on('error',rej); if(payload) req.write(payload); req.end();
});}
async function rest(path, opts = {}) {
  const u = new URL(SUPABASE_URL + '/rest/v1' + path);
  const r = await http({hostname:u.hostname,path:u.pathname+u.search,method:opts.method||'GET',headers:{apikey:SVC,Authorization:'Bearer '+SVC,'Content-Type':'application/json',...(opts.headers||{})}}, opts.body);
  if (r.status>=300) throw new Error('REST '+r.status+': '+r.body.slice(0,200));
  return r.body ? JSON.parse(r.body) : null;
}
async function listAT(tableId) {
  const out=[]; let offset; const enc=encodeURIComponent;
  do {
    const path = '/v0/'+AT_BASE+'/'+enc(tableId)+'?pageSize=100'+(offset?'&offset='+enc(offset):'');
    const r = await http({hostname:'api.airtable.com',path,method:'GET',headers:{Authorization:'Bearer '+AT_KEY}});
    if (r.status>=300) throw new Error('AT '+r.status+': '+r.body.slice(0,200));
    const j = JSON.parse(r.body);
    for (const rec of (j.records||[])) out.push(rec);
    offset = j.offset;
  } while (offset);
  return out;
}

// Field helpers — mirror the deployed handler
function strVal(fields, name) {
  const v = fields[name];
  if (v == null) return null;
  if (typeof v === 'string') return v.trim() || null;
  if (Array.isArray(v) && v.length) {
    const first = v[0];
    return (first && typeof first === 'object' && first.name) ? String(first.name).trim() : String(first).trim() || null;
  }
  if (typeof v === 'object' && v.name) return String(v.name).trim() || null;
  return String(v).trim() || null;
}
function numVal(fields, name) {
  const v = fields[name];
  if (v == null || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}
function dateVal(fields, name) {
  const v = fields[name];
  if (!v) return null;
  return String(v).slice(0, 10);
}

async function findEsl(entity_type, source_id) {
  const r = await rest(`/entity_source_links?entity_type=eq.${entity_type}&source_system=eq.airtable&source_id=eq.${encodeURIComponent(source_id)}&select=entity_id&limit=1`);
  return r?.[0]?.entity_id ?? null;
}
async function upsertEsl(entity_type, entity_id, source_id) {
  await rest('/entity_source_links', {
    method: 'POST',
    headers: { Prefer: 'resolution=merge-duplicates' },
    body: JSON.stringify({ entity_type, entity_id, source_system: 'airtable', source_id, match_method: 'webhook' }),
  });
}

async function handleDerm(recordId, fields) {
  const clientName = strVal(fields, 'Client Name (from Client)') ?? strVal(fields, 'Client Name');
  const row = {
    service_date: dateVal(fields, 'Date Dump Ticket') ?? dateVal(fields, 'GT Last Visit'),
    dump_ticket_date: dateVal(fields, 'Date Dump Ticket'),
    white_manifest_number: strVal(fields, 'White Manifest #'),
    yellow_ticket_number: strVal(fields, 'Yellow Ticket #'),
    sent_to_client: fields['Send To Client'] === true,
    sent_to_city: fields['Send To City'] === true,
  };
  if (clientName) {
    const r = await rest(`/clients?name=ilike.${encodeURIComponent('%'+clientName+'%')}&select=id&limit=1`);
    if (r?.length) row.client_id = r[0].id;
  }
  const existingId = await findEsl('derm_manifest', recordId);
  let entityId;
  if (existingId) {
    await rest(`/derm_manifests?id=eq.${existingId}`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify(row) });
    entityId = existingId;
  } else {
    const r = await rest('/derm_manifests', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify(row) });
    entityId = r[0].id;
    await upsertEsl('derm_manifest', entityId, recordId);
  }
  return entityId;
}

async function handleInspection(recordId, fields) {
  const dateRaw = fields['Date'];
  const shift_date = typeof dateRaw === 'string' ? dateRaw.slice(0,10) : null;
  if (!shift_date) return null;
  const rawType = strVal(fields, 'Pre/Post')?.toUpperCase();
  const inspection_type = rawType?.startsWith('PRE') ? 'PRE' : rawType?.startsWith('POST') ? 'POST' : null;
  if (!inspection_type) return null;

  let vehicle_id = null;
  const truckRaw = strVal(fields, 'Truck');
  const truckName = truckRaw ? truckRaw.split(/[\s,]/)[0] : null;
  if (truckName) {
    const r = await rest(`/vehicles?name=ilike.${encodeURIComponent(truckName)}&select=id&limit=1`);
    if (r?.length) vehicle_id = r[0].id;
  }
  let employee_id = null;
  const driverName = strVal(fields, 'Driver');
  if (driverName) {
    const r = await rest(`/employees?full_name=ilike.${encodeURIComponent('%'+driverName+'%')}&select=id&limit=1`);
    if (r?.length) employee_id = r[0].id;
  }

  const row = {
    shift_date, inspection_type,
    submitted_at: typeof dateRaw === 'string' ? dateRaw : null,
    sludge_gallons: Math.round(numVal(fields, 'SLUDGE Tank level') ?? 0) || null,
    water_gallons:  Math.round(numVal(fields, 'WATER Tank level')  ?? 0) || null,
    gas_level: strVal(fields, 'Gas Level'),
  };
  if (vehicle_id) row.vehicle_id = vehicle_id;
  if (employee_id) row.employee_id = employee_id;

  const existingId = await findEsl('inspection', recordId);
  let entityId;
  if (existingId) {
    await rest(`/inspections?id=eq.${existingId}`, { method: 'PATCH', headers: { Prefer: 'return=minimal' }, body: JSON.stringify(row) });
    entityId = existingId;
  } else {
    const r = await rest('/inspections', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify(row) });
    entityId = r[0].id;
    await upsertEsl('inspection', entityId, recordId);
  }
  return entityId;
}

(async () => {
  const TABLES = [
    { id: 'tblz0CnWim7ViFjcw', name: 'DERM',     handler: handleDerm },
    { id: 'tblDklRdntb6kdjvE', name: 'PRE-POST', handler: handleInspection },
  ];

  for (const t of TABLES) {
    console.log('\n=== '+t.name+' ===');
    const records = await listAT(t.id);
    console.log('  '+records.length+' records');
    let ok = 0, fail = 0;
    for (const rec of records) {
      try {
        await t.handler(rec.id, rec.fields || {});
        ok++;
        if (ok % 100 === 0) console.log('    '+ok+'/'+records.length);
      } catch (e) {
        fail++;
        if (fail <= 5) console.log('    FAIL '+rec.id+': '+e.message);
      }
    }
    console.log('  Done: '+ok+' ok, '+fail+' failed');
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
