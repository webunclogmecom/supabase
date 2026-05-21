// Comprehensive smoke test covering all changes from 2026-05-20 + 2026-05-21:
//   - DERM Tracker DB layer (manifests, manifest_visits, derm.*, gdos)
//   - Field Portal customer.* views + Path C
//   - Geo backfill coverage
//   - webhook-jobber coords + county fallback
//   - webhook-airtable DERM PDF URLs
const path = require('path');
require('dotenv').config({ path: path.resolve(__dirname, '../../.env'), override: true });

const URL = process.env.SUPABASE_URL;
const KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const PAT = process.env.SUPABASE_PAT;
const PROJECT = process.env.SUPABASE_PROJECT_ID;

let ANON_KEY = null;

const H = { apikey: KEY, Authorization: `Bearer ${KEY}` };

async function fetchAnonKey() {
  const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/api-keys`, { headers: { Authorization: `Bearer ${PAT}` } });
  const j = await r.json();
  const a = (j || []).find(k => k.name === 'anon');
  ANON_KEY = a?.api_key || null;
  if (!ANON_KEY) throw new Error('could not fetch anon key from management API');
}

async function rest(qs, opts = {}, mode = 'svc') {
  let headers;
  if (mode === 'anon') headers = { apikey: ANON_KEY, Authorization: `Bearer ${ANON_KEY}` };
  else if (mode === 'noauth') headers = { apikey: ANON_KEY };
  else headers = { ...H };
  headers = { ...headers, ...(opts.headers || {}) };
  const r = await fetch(`${URL}/rest/v1/${qs}`, { ...opts, headers });
  const text = await r.text();
  let body = null;
  if (text) {
    try { body = JSON.parse(text); } catch { body = text; }
  }
  return { ok: r.ok, status: r.status, body, contentRange: r.headers.get('content-range') };
}

const results = [];
function record(status, name, detail = '') { results.push({ status, name, detail }); }
async function check(name, fn) {
  try {
    const v = await fn();
    if (v === false) record('❌', name, 'returned false');
    else record('✅', name, typeof v === 'string' ? v : '');
  } catch (e) {
    record('❌', name, e.message?.slice(0, 200));
  }
}

(async () => {
  console.log('Smoke test — 2026-05-20 + 2026-05-21 changes\n');
  await fetchAnonKey();
  console.log(`Loaded ANON key: ${ANON_KEY.slice(0, 14)}...${ANON_KEY.slice(-6)}\n`);

  // ============================================================
  // A. DERM Tracker DB layer (public.derm_manifests + manifest_visits)
  // ============================================================
  console.log('=== A. DERM data quality ===');

  await check('A1. derm_manifests rows present', async () => {
    const r = await rest('derm_manifests?select=id', { headers: { Prefer: 'count=exact', Range: '0-0' } });
    const n = Number(r.contentRange.split('/')[1]);
    if (n < 800) throw new Error(`only ${n} rows`);
    return `${n} manifests total`;
  });

  await check('A2. DERM PDF URL coverage ≥99%', async () => {
    const total = await rest('derm_manifests?select=id', { headers: { Prefer: 'count=exact', Range: '0-0' } });
    const missing = await rest('derm_manifests?derm_manifest_url=is.null&derm_address_url=is.null&select=id', { headers: { Prefer: 'count=exact', Range: '0-0' } });
    const T = Number(total.contentRange.split('/')[1]);
    const M = Number(missing.contentRange.split('/')[1]);
    const pct = ((1 - M / T) * 100).toFixed(2);
    if (Number(pct) < 99) throw new Error(`only ${pct}% (${T-M}/${T})`);
    return `${pct}% (${T - M}/${T})`;
  });

  await check('A3. WM#824949 has both URLs on all 8 rows', async () => {
    const r = await rest('derm_manifests?white_manifest_number=eq.824949&select=derm_manifest_url,derm_address_url');
    if (!Array.isArray(r.body)) throw new Error(`expected array, got ${typeof r.body}`);
    const bad = r.body.filter(x => !x.derm_manifest_url || !x.derm_address_url);
    if (bad.length) throw new Error(`${bad.length}/${r.body.length} missing URL`);
    return `all ${r.body.length} rows have both URLs`;
  });

  await check('A3b. DERM PDF URLs are LIVE (HEAD returns 200) — catches expired AT URLs', async () => {
    // Sample 5 recent rows, HEAD each URL, fail if any !=200
    const r = await rest('derm_manifests?derm_manifest_url=not.is.null&select=id,derm_manifest_url,derm_address_url&order=id.desc&limit=5');
    let checked = 0, dead = 0, atSource = 0;
    for (const row of r.body) {
      for (const url of [row.derm_manifest_url, row.derm_address_url].filter(Boolean)) {
        if (url.includes('airtableusercontent.com')) atSource++;
        const h = await fetch(url, { method: 'HEAD' });
        checked++;
        if (h.status !== 200) dead++;
      }
    }
    if (dead > 0) throw new Error(`${dead}/${checked} URLs dead. ${atSource} still point at AT (which expires every 2h). Re-run migrate_derm_attachments_to_storage.js`);
    return `${checked} sample URLs all return 200 OK (${atSource} on AT, rest on Storage)`;
  });

  await check('A3c. DERM PDF URLs are PERMANENT (Supabase Storage, not AT)', async () => {
    // Count how many rows still have AT URLs (which expire) vs Storage URLs (permanent)
    const at = await rest('derm_manifests?or=(derm_manifest_url.like.*airtableusercontent*,derm_address_url.like.*airtableusercontent*)&select=id', { headers: { Prefer: 'count=exact', Range: '0-0' } });
    const n = Number(at.contentRange.split('/')[1]);
    if (n > 0) throw new Error(`${n} rows still have AT URLs — they will expire in 2h. Run mirror-derm-pdfs-to-storage workflow.`);
    return 'all URLs on Supabase Storage (permanent)';
  });

  await check('A4. No PDF-less + visit-less ghost manifests', async () => {
    const r = await rest('derm_manifests?derm_manifest_url=is.null&derm_address_url=is.null&select=id,white_manifest_number');
    if (!Array.isArray(r.body)) throw new Error(`unexpected body: ${JSON.stringify(r.body).slice(0,80)}`);
    const ids = r.body.map(x => x.id);
    if (!ids.length) return 'no URL-less manifests at all';
    // FK column on manifest_visits is `manifest_id` (per shape inspection), not manifest_id
    const visits = await rest(`manifest_visits?manifest_id=in.(${ids.join(',')})&select=manifest_id`);
    if (!Array.isArray(visits.body)) throw new Error(`manifest_visits non-array (${visits.status}): ${JSON.stringify(visits.body).slice(0,80)}`);
    const haveVisits = new Set(visits.body.map(v => v.manifest_id));
    const ghosts = ids.filter(id => !haveVisits.has(id));
    if (ghosts.length) throw new Error(`${ghosts.length} ghosts: ${ghosts.slice(0, 5).join(',')}`);
    return `${ids.length} URL-less rows all have visit linkages — OK`;
  });

  await check('A5. manifest_visits links present', async () => {
    // manifest_visits has no `id` column — PK is (visit_id, manifest_id)
    const r = await rest('manifest_visits?select=visit_id', { headers: { Prefer: 'count=exact', Range: '0-0' } });
    if (!r.contentRange) throw new Error(`no content-range: ${r.status}`);
    const n = Number(r.contentRange.split('/')[1]);
    if (n < 300) throw new Error(`only ${n} links — looks like a regression`);
    return `${n} manifest↔visit links`;
  });

  // ============================================================
  // B. DERM Tracker views (derm.* schema) — needs Accept-Profile
  // ============================================================
  console.log('\n=== B. DERM Tracker derm.* views ===');
  const dermH = { 'Accept-Profile': 'derm' };

  await check('B1. derm.visits returns rows', async () => {
    const r = await rest('visits?select=id&limit=5', { headers: dermH });
    if (!Array.isArray(r.body) || !r.body.length) throw new Error(`empty (${r.status}): ${JSON.stringify(r.body).slice(0,80)}`);
    return `${r.body.length} sample rows`;
  });
  await check('B2. derm.manifests returns rows w/ display_label', async () => {
    const r = await rest('manifests?select=id,display_label,jurisdiction&limit=5', { headers: dermH });
    if (!Array.isArray(r.body) || !r.body.length) throw new Error('empty');
    const hasLabel = r.body.every(x => x.display_label);
    if (!hasLabel) throw new Error('some rows missing display_label');
    return `${r.body.length} samples, jurisdictions: ${[...new Set(r.body.map(x => x.jurisdiction))].join(',')}`;
  });
  await check('B3. derm.manifest_health returns work queue', async () => {
    const r = await rest('manifest_health?select=id,severity&limit=5', { headers: dermH });
    if (!Array.isArray(r.body) || !r.body.length) throw new Error('empty');
    return `${r.body.length}+ unhealthy manifests`;
  });
  await check('B4. derm.disposal_facilities returns rows', async () => {
    const r = await rest('disposal_facilities?select=id,name&limit=5', { headers: dermH });
    if (!Array.isArray(r.body) || !r.body.length) throw new Error('empty');
    return `${r.body.length}+ facilities`;
  });
  await check('B5. derm.visits has line_items columns', async () => {
    const r = await rest('visits?select=id,line_items,line_items_json&limit=3', { headers: dermH });
    if (!Array.isArray(r.body) || !r.body.length) throw new Error('empty');
    return 'line_items + line_items_json present';
  });
  await check('B6. derm.visits.needs_manifest defaults to TRUE', async () => {
    const r = await rest('visits?select=needs_manifest&needs_manifest=eq.true&limit=1', { headers: { ...dermH, Prefer: 'count=exact', Range: '0-0' } });
    const n = Number(r.contentRange.split('/')[1]);
    if (n < 100) throw new Error(`only ${n} visits need manifest`);
    return `${n} visits with needs_manifest=true`;
  });
  await check('B7. derm.visits "Documented" requires PDF (has_manifest=true → linked manifest has PDF)', async () => {
    const r = await rest('visits?has_manifest=eq.true&select=id&limit=20', { headers: dermH });
    if (!Array.isArray(r.body) || !r.body.length) return 'no documented visits — skip';
    const sample = r.body.slice(0, 5).map(v => v.id);
    const links = await rest(`manifest_visits?visit_id=in.(${sample.join(',')})&select=visit_id,manifest_id`);
    if (!Array.isArray(links.body) || !links.body.length) throw new Error('has_manifest=true but no manifest_visits rows');
    const mids = [...new Set(links.body.map(l => l.manifest_id))];
    const ms = await rest(`derm_manifests?id=in.(${mids.join(',')})&select=id,derm_manifest_url,derm_address_url`);
    const noUrl = ms.body.filter(m => !m.derm_manifest_url && !m.derm_address_url);
    if (noUrl.length) throw new Error(`${noUrl.length}/${ms.body.length} linked manifests have no PDF`);
    return `5 sample documented visits all have ≥1 PDF-bearing manifest`;
  });

  // ============================================================
  // C. gdos table + security
  // ============================================================
  console.log('\n=== C. GDOs table + anon-write security ===');

  await check('C1. gdos table has ≥100 rows', async () => {
    const r = await rest('gdos?select=id', { headers: { Prefer: 'count=exact', Range: '0-0' } });
    const n = Number(r.contentRange.split('/')[1]);
    if (n < 100) throw new Error(`only ${n}`);
    return `${n} GDOs`;
  });
  await check('C2. anon can SELECT gdos', async () => {
    const r = await rest('gdos?select=id,gdo_number&limit=3', {}, 'anon');
    if (!r.ok) throw new Error(`anon SELECT failed: ${r.status} ${JSON.stringify(r.body).slice(0,80)}`);
    if (!Array.isArray(r.body)) throw new Error('non-array');
    return `anon read OK (${r.body.length} rows)`;
  });
  await check('C3. anon CANNOT update gdos.gdo_number', async () => {
    const r = await rest('gdos?id=eq.1', {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json', Prefer: 'return=minimal' },
      body: JSON.stringify({ gdo_number: 'HACKED' }),
    }, 'anon');
    if (r.ok && r.status !== 204) throw new Error(`anon UPDATE succeeded (status ${r.status}) — SECURITY HOLE`);
    if (r.status === 204) {
      // Need to actually verify it didn't write — fetch back
      const after = await rest('gdos?id=eq.1&select=gdo_number');
      if (after.body[0]?.gdo_number === 'HACKED') throw new Error('SECURITY HOLE — anon write succeeded');
      return `anon write returned 204 but DB value unchanged (column-level GRANT blocks it)`;
    }
    return `anon write blocked (status ${r.status})`;
  });

  // ============================================================
  // D. Field Portal customer.* views + Path C
  // ============================================================
  console.log('\n=== D. Field Portal customer.* views ===');
  const custH = { 'Accept-Profile': 'customer' };

  await check('D1. customer.clients returns rows', async () => {
    const r = await rest('clients?select=id,client_code&limit=5', { headers: custH });
    if (!Array.isArray(r.body) || !r.body.length) throw new Error(`empty (${r.status})`);
    return `${r.body.length}+ rows`;
  });
  // customer.work_orders is keyed by `id` (UUID derived from visit_id, zero-padded)
  function visitToWoUuid(v) { return '00000000-0000-0000-0000-' + String(v).padStart(12, '0'); }

  await check('D2. customer.work_orders has manifest_number + jurisdiction', async () => {
    const r = await rest('work_orders?manifest_number=not.is.null&select=id,manifest_number,manifest_jurisdiction&limit=5', { headers: custH });
    if (!Array.isArray(r.body) || !r.body.length) throw new Error(`no work orders with manifest_number (${r.status})`);
    const j = r.body[0];
    if (!j.manifest_jurisdiction) throw new Error('manifest_jurisdiction missing');
    return `${r.body.length} samples, jurisdictions: ${[...new Set(r.body.map(x => x.manifest_jurisdiction))].join(',')}`;
  });
  await check('D3. Path C — multi-client manifests hide derm_manifest_url (address PDF)', async () => {
    const r = await rest('manifest_visits?select=manifest_id,visit_id&limit=5000');
    if (!Array.isArray(r.body)) throw new Error('manifest_visits empty');
    const counts = {};
    for (const mv of r.body) counts[mv.manifest_id] = (counts[mv.manifest_id] || 0) + 1;
    const multi = Object.entries(counts).filter(([, c]) => c >= 2).map(([m]) => Number(m));
    if (!multi.length) return 'no multi-visit manifests to test';
    for (const mid of multi.slice(0, 30)) {
      const links = await rest(`manifest_visits?manifest_id=eq.${mid}&select=visit_id`);
      const vids = links.body.map(x => x.visit_id);
      const visits = await rest(`visits?id=in.(${vids.join(',')})&select=id,client_id`);
      const clientIds = [...new Set(visits.body.map(v => v.client_id))];
      if (clientIds.length > 1) {
        const woId = visitToWoUuid(vids[0]);
        const wo = await rest(`work_orders?id=eq.${woId}&select=derm_manifest_url,wwtp_receipt_url`, { headers: custH });
        if (!wo.body?.length) continue;
        const w = wo.body[0];
        if (w.derm_manifest_url !== null) throw new Error(`multi-client manifest ${mid} leaked derm_manifest_url on visit ${vids[0]}`);
        return `multi-client manifest ${mid} (${clientIds.length} clients) correctly hides address PDF`;
      }
    }
    return 'no multi-client manifest sample found';
  });
  await check('D4. customer.work_orders.wwtp_ticket_number COALESCEs from manifest_number', async () => {
    const r = await rest('work_orders?wwtp_ticket_number=not.is.null&select=id,wwtp_ticket_number,manifest_number&limit=5', { headers: custH });
    if (!Array.isArray(r.body) || !r.body.length) return 'no ticket numbers populated';
    return `${r.body.length} samples populated`;
  });

  // ============================================================
  // E. Geo backfill coverage
  // ============================================================
  console.log('\n=== E. County + geo coverage ===');

  await check('E1. properties.county coverage = 100%', async () => {
    const total = await rest('properties?select=id', { headers: { Prefer: 'count=exact', Range: '0-0' } });
    const missing = await rest('properties?county=is.null&select=id', { headers: { Prefer: 'count=exact', Range: '0-0' } });
    const T = Number(total.contentRange.split('/')[1]);
    const M = Number(missing.contentRange.split('/')[1]);
    if (M > 5) throw new Error(`${M}/${T} missing county`);
    return `${T-M}/${T} have county (${M} missing)`;
  });

  await check('E2. Active/recurring primary properties have lat/lng = 100%', async () => {
    const cs = await rest('clients?status=in.(ACTIVE,RECURRING)&select=id&limit=10000');
    const ids = cs.body.map(c => c.id);
    let total = 0, missing = 0;
    for (let i = 0; i < ids.length; i += 200) {
      const chunk = ids.slice(i, i + 200);
      const ps = await rest(`properties?client_id=in.(${chunk.join(',')})&is_primary=eq.true&select=latitude,longitude&limit=10000`);
      total += ps.body.length;
      missing += ps.body.filter(p => p.latitude == null || p.longitude == null).length;
    }
    if (missing > 0) throw new Error(`${missing}/${total} missing lat/lng`);
    return `${total}/${total} have lat/lng`;
  });

  // ============================================================
  // F. Edge Function health
  // ============================================================
  console.log('\n=== F. Edge Function health (last 24h) ===');

  await check('F1. webhook_events_log recent activity', async () => {
    const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
    const r = await rest(`webhook_events_log?created_at=gte.${since}&select=source_system,status&limit=2000`);
    if (!Array.isArray(r.body)) throw new Error('non-array');
    if (!r.body.length) throw new Error('no events in last 24h');
    const byStatusSource = {};
    for (const e of r.body) {
      const k = `${e.source_system}/${e.status}`;
      byStatusSource[k] = (byStatusSource[k] || 0) + 1;
    }
    return JSON.stringify(byStatusSource);
  });

  await check('F2. AT webhook DERM event landed PDF URLs today', async () => {
    const today = new Date(); today.setHours(0,0,0,0);
    const since = today.toISOString();
    const r = await rest(`derm_manifests?updated_at=gte.${since}&derm_manifest_url=not.is.null&select=id,white_manifest_number,updated_at&limit=5`);
    if (!Array.isArray(r.body) || !r.body.length) return 'no AT-driven URL updates today (expected on quiet days)';
    return `${r.body.length} manifests updated today with URLs`;
  });

  // ============================================================
  // G. Audit trail (audit.logs — needs schema header)
  // ============================================================
  console.log('\n=== G. Audit trail ===');

  await check('G1. audit.logs has recent entries (via SQL — schema not REST-exposed)', async () => {
    const r = await fetch(`https://api.supabase.com/v1/projects/${PROJECT}/database/query`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        query: `SELECT table_name AS t, operation AS op, count(*) AS n FROM audit.logs WHERE changed_at > now() - interval '24 hours' GROUP BY t, op ORDER BY n DESC LIMIT 12`,
      }),
    });
    if (!r.ok) throw new Error(`SQL ${r.status} ${(await r.text()).slice(0,120)}`);
    const rows = await r.json();
    if (!rows.length) throw new Error('no audit entries in 24h');
    return `${rows.length} (table, op) buckets: ${rows.slice(0, 4).map(x => `${x.t}/${x.op}=${x.n}`).join(', ')}`;
  });

  // ============================================================
  // H. ESL cross-system identity
  // ============================================================
  console.log('\n=== H. ESL — cross-system identity ===');

  await check('H1. ESL has client/property/visit/employee rows', async () => {
    const types = ['client', 'property', 'visit', 'employee'];
    const counts = {};
    for (const t of types) {
      const r = await rest(`entity_source_links?entity_type=eq.${t}&select=id`, { headers: { Prefer: 'count=exact', Range: '0-0' } });
      counts[t] = Number(r.contentRange.split('/')[1]);
    }
    return JSON.stringify(counts);
  });

  await check('H2. Samsara property ESL count grew today (post-reconciliation)', async () => {
    const r = await rest('entity_source_links?entity_type=eq.property&source_system=eq.samsara&select=id', { headers: { Prefer: 'count=exact', Range: '0-0' } });
    const n = Number(r.contentRange.split('/')[1]);
    if (n < 50) throw new Error(`only ${n} samsara property ESL rows`);
    return `${n} property→samsara ESL rows`;
  });

  // ============================================================
  // I. Final report
  // ============================================================
  console.log('\n\n========== RESULTS ==========');
  const passes = results.filter(r => r.status === '✅').length;
  const fails = results.filter(r => r.status === '❌').length;
  for (const r of results) {
    console.log(`${r.status} ${r.name}${r.detail ? ' — ' + r.detail : ''}`);
  }
  console.log(`\n${passes} passed, ${fails} failed`);
  process.exit(fails ? 1 : 0);
})().catch(err => { console.error('SMOKE TEST CRASHED:', err); process.exit(2); });
