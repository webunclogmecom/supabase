// Cross-reference every Sbx service_configs row against AT's canonical
// `Service Type` multi-select. Flag rows where:
//   - the client's AT `Service Type` does NOT include the corresponding service
//   - (these are likely false-positive configs created from junk freq values)
//
// Run with no flag = audit only.  Pass --execute to DELETE the false rows.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const EXECUTE = process.argv.includes('--execute');

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

// Parse AT's Service Type multi-select into a Set of our codes
function parseATServiceTypes(serviceType) {
  const codes = new Set();
  if (!Array.isArray(serviceType)) return codes;
  for (const v of serviceType) {
    const name = (v && v.name) || v || '';
    const sl = String(name).toLowerCase();
    if (sl.includes('grease trap') || sl === 'gt') codes.add('GT');
    else if (sl.includes('main cl') || sl.includes('cleaning') || sl === 'cl') codes.add('CL');
    else if (sl === 'wd' || sl.includes('warranty') || sl.includes('water dis')) codes.add('WD');
    else if (sl.includes('lyft')) codes.add('LS');
  }
  return codes;
}

(async () => {
  console.log(`Mode: ${EXECUTE ? 'EXECUTE (will DELETE false rows)' : 'AUDIT ONLY'}\n`);

  // Pull every Sbx service_config + its AT link
  const sbxConfigs = await pg(`
    SELECT sc.id, sc.service_type, sc.frequency_days, sc.price_per_visit,
      c.id AS client_id, c.client_code, c.name, c.status,
      esl.source_id AS at_id
    FROM service_configs sc
    JOIN clients c ON c.id = sc.client_id
    LEFT JOIN entity_source_links esl
      ON esl.entity_type='client' AND esl.entity_id=c.id AND esl.source_system='airtable'
    WHERE c.status IN ('ACTIVE','RECURRING');
  `);
  console.log('Sbx service_configs (ACTIVE/RECURRING clients):', sbxConfigs.length);

  // Pull AT clients with Service Type
  const atClients = await listAT('Clients', ['Client Name','ACTIVE/INACTIVE','Service Type','GT Frequency','CL Frequency','WD Frequency']);
  console.log('AT clients pulled:', atClients.length);
  const atById = new Map(atClients.map(c => [c.id, c]));

  const offending = [];
  let unlinked = 0;

  for (const sc of sbxConfigs) {
    if (!sc.at_id) { unlinked++; continue; }
    const ac = atById.get(sc.at_id);
    if (!ac) continue;
    const declared = parseATServiceTypes(ac['Service Type']);
    if (!declared.has(sc.service_type)) {
      offending.push({
        sc_id: sc.id,
        client_code: sc.client_code,
        name: sc.name,
        service: sc.service_type,
        freq: sc.frequency_days,
        price: sc.price_per_visit,
        at_service_types: [...declared].join(',') || '(none)',
        at_has_freq_field: !!ac[sc.service_type + ' Frequency'],
      });
    }
  }

  console.log('\nClients without AT link (skipped):', unlinked);
  console.log('\n=== Sbx configs WITHOUT matching Service Type in AT ===');
  console.log('('+offending.length+' rows — these should be deleted from service_configs)');

  // Group by reason for clarity
  const byClient = {};
  for (const o of offending) {
    if (!byClient[o.client_code]) byClient[o.client_code] = [];
    byClient[o.client_code].push(o);
  }
  for (const [cc, list] of Object.entries(byClient).sort()) {
    const name = list[0].name;
    const declared = list[0].at_service_types;
    const bogus = list.map(o => o.service+'(freq='+(o.freq||'-')+',$'+(o.price||'-')+')').join(', ');
    console.log('  '+cc.padEnd(11)+' AT says: ['+declared+']  Sbx has bogus: '+bogus+'  // '+(name||''));
  }

  if (!EXECUTE) {
    console.log('\n[AUDIT MODE] No changes made. Re-run with --execute to DELETE the '+offending.length+' false rows.');
    return;
  }

  console.log('\nDeleting '+offending.length+' false service_configs rows...');
  const ids = offending.map(o => o.sc_id);
  const d = await pg('DELETE FROM service_configs WHERE id IN ('+ids.join(',')+') RETURNING id;');
  console.log('Deleted '+d.length+' rows.');
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
