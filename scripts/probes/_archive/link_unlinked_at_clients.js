// Link AT clients that exist in Airtable but have no entity_source_link in Sbx.
// Two paths per client:
//   (a) Name fuzzy-matches an existing Sbx client → add the AT link to that client
//   (b) No fuzzy match → log for manual review (don't create new Sbx clients
//       here — that's the AT-throws-wrong-data trust-hierarchy rule)
//
// Dry-run by default. Pass --execute to write links.
require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');

const PROD = process.env.SUPABASE_PROJECT_ID;
const PAT = process.env.SUPABASE_PAT;
const SVC = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SUPABASE_URL = process.env.SUPABASE_URL;
const AT_KEY = process.env.AIRTABLE_API_KEY;
const AT_BASE = process.env.AIRTABLE_BASE_ID;
const EXECUTE = process.argv.includes('--execute');

function http(opts, body) { return new Promise((res, rej) => {
  const payload = body == null ? null : (typeof body === 'string' ? body : JSON.stringify(body));
  const req = https.request({...opts, headers:{...(opts.headers||{}), ...(payload?{'Content-Length':Buffer.byteLength(payload)}:{})}}, r => {
    const c=[]; r.on('data',x=>c.push(x)); r.on('end',()=>res({status:r.statusCode,body:Buffer.concat(c).toString()}));
  });
  req.on('error',rej); if(payload) req.write(payload); req.end();
});}
async function pg(sql) { const r = await http({hostname:'api.supabase.com',path:'/v1/projects/'+PROD+'/database/query',method:'POST',headers:{Authorization:'Bearer '+PAT,'Content-Type':'application/json'}}, JSON.stringify({query:sql})); if(r.status>=300) throw new Error('PG '+r.status+': '+r.body.slice(0,300)); return JSON.parse(r.body); }
async function rest(path, opts = {}) { const u = new URL(SUPABASE_URL + '/rest/v1' + path); const r = await http({hostname:u.hostname,path:u.pathname+u.search,method:opts.method||'GET',headers:{apikey:SVC,Authorization:'Bearer '+SVC,'Content-Type':'application/json',...(opts.headers||{})}}, opts.body); if (r.status>=300) throw new Error('REST '+r.status+': '+r.body.slice(0,300)); return r.body ? JSON.parse(r.body) : null; }
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

// Normalize a name for fuzzy comparison: lowercase, strip non-alnum,
// drop common words ("the", "llc", "inc", "&", "and", "of", "miami", "fl").
function normName(s) {
  return (s || '').toString().toLowerCase()
    .replace(/[^a-z0-9\s]/g, ' ')
    .replace(/\b(the|llc|inc|corp|and|of|miami|fl|fort|lauderdale|south|north|east|west|st|street|ave|avenue|blvd)\b/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}
function jaccard(a, b) {
  const A = new Set(a.split(' ').filter(x => x.length >= 2));
  const B = new Set(b.split(' ').filter(x => x.length >= 2));
  if (!A.size || !B.size) return 0;
  let inter = 0; for (const x of A) if (B.has(x)) inter++;
  return inter / (A.size + B.size - inter);
}

(async () => {
  console.log(`Mode: ${EXECUTE ? 'EXECUTE' : 'DRY-RUN'}\n`);
  // All AT clients
  const atClients = await listAT('Clients', ['Client Name','ACTIVE/INACTIVE','Jobber Client ID']);

  // All Sbx clients with their AT-link status
  const sbxClients = await pg(`
    SELECT c.id, c.name, c.client_code,
      (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='airtable' LIMIT 1) AS at_id,
      (SELECT source_id FROM entity_source_links WHERE entity_type='client' AND entity_id=c.id AND source_system='jobber' LIMIT 1) AS jobber_id
    FROM clients c;`);
  const linkedATIds = new Set(sbxClients.map(c => c.at_id).filter(Boolean));

  // AT clients not in Sbx
  const unlinkedAT = atClients.filter(ac => !linkedATIds.has(ac.id));
  console.log(`AT clients without Sbx link: ${unlinkedAT.length}\n`);

  // For each, attempt fuzzy match against Sbx clients (preferring those without AT link)
  const candidates = sbxClients.filter(c => !c.at_id);
  const writes = [];
  const unresolved = [];

  for (const ac of unlinkedAT) {
    const atName = ac['Client Name'] || '';
    const atJobberId = ac['Jobber Client ID'];
    const normAT = normName(atName);

    // First try: exact Jobber GID match (most reliable)
    if (atJobberId) {
      const targetGid = atJobberId.startsWith('Z2lk') ? atJobberId : Buffer.from(`gid://Jobber/Client/${atJobberId}`).toString('base64').replace(/=+$/, '');
      const byGid = sbxClients.find(c => c.jobber_id === targetGid);
      if (byGid && !byGid.at_id) {
        writes.push({ at_id: ac.id, at_name: atName, sbx_id: byGid.id, sbx_name: byGid.name, method: 'jobber_gid_match', confidence: 1.0 });
        continue;
      }
    }

    // Skip AT test/junk records
    if (!atName || /^aziz\s+test\b|^test\b|^zzz_/i.test(atName)) {
      unresolved.push({ at_id: ac.id, at_name: atName, reason: 'AT-side junk/test/archived' });
      continue;
    }

    // Second: name fuzzy match (Jaccard >= 0.7) — strong match
    let best = null;
    for (const sc of candidates) {
      const score = jaccard(normAT, normName(sc.name));
      if (score > (best?.score || 0)) best = { sc, score };
    }
    if (best && best.score >= 0.7) {
      writes.push({ at_id: ac.id, at_name: atName, sbx_id: best.sc.id, sbx_name: best.sc.name, method: 'name_fuzzy', confidence: best.score.toFixed(2) });
      continue;
    }

    // Third: substring containment — handles cases where Sbx name has
    // a "NNN-XXX" client_code prefix (e.g. "208-HUB Hubble Bubble Lounge")
    // that the AT name doesn't carry. Accept if AT name is fully inside Sbx
    // name (or vice versa) on the normalized form, with length ≥ 6 chars.
    if (normAT.length >= 6) {
      const containment = sbxClients.find(sc => {
        const normSC = normName(sc.name);
        return normSC && (normSC.includes(normAT) || normAT.includes(normSC));
      });
      if (containment) {
        writes.push({ at_id: ac.id, at_name: atName, sbx_id: containment.id, sbx_name: containment.name, method: 'name_contained', confidence: '0.85' });
        continue;
      }
    }

    unresolved.push({ at_id: ac.id, at_name: atName, best_score: best?.score?.toFixed(2) || '0', best_sbx_name: best?.sc?.name || null });
  }

  console.log(`Will link: ${writes.length}`);
  for (const w of writes) console.log('  ✓ AT '+w.at_id+' "'+w.at_name+'" → Sbx '+w.sbx_id+' "'+w.sbx_name+'" ['+w.method+' conf='+w.confidence+']');

  console.log(`\nUnresolved (no Sbx match): ${unresolved.length}`);
  for (const u of unresolved) console.log('  ? AT '+u.at_id+' "'+u.at_name+'"  best Sbx match: "'+u.best_sbx_name+'" ('+u.best_score+')');

  if (!EXECUTE) { console.log('\n[DRY-RUN] pass --execute to write links.'); return; }

  console.log('\nWriting links...');
  for (const w of writes) {
    await rest('/entity_source_links', { method: 'POST', headers: { Prefer: 'resolution=merge-duplicates' }, body: JSON.stringify({
      entity_type: 'client', entity_id: w.sbx_id, source_system: 'airtable', source_id: w.at_id, source_name: w.at_name, match_method: w.method, match_confidence: w.confidence,
    }) });
  }
  console.log('  ✓ '+writes.length+' links written');
})().catch(e => { console.error('FATAL:', e.message); process.exit(2); });
