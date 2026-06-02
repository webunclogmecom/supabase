// ============================================================================
// verify_xappsource_rollout.js — confirm ADR-016 X-App-Source header is live
// ============================================================================
// Two checks:
//   1. audit.logs: SELECT app_source, COUNT, plus the count of rows where
//      request_context->>'app_source_hint' IS NOT NULL (those are the rows
//      where the explicit X-App-Source header actually arrived).
//   2. Bundle scan: HEAD/GET the deployed JS bundles for each app and grep
//      for the literal "X-App-Source" or "x-app-source" string. If the
//      header isn't in the bundle, the Publish didn't actually deploy.
// ============================================================================

const https = require('https');
try { require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') }); } catch (_) {}

const SUPABASE_URL = process.env.SUPABASE_URL;
const PAT = process.env.SUPABASE_PAT;
if (!SUPABASE_URL || !PAT) throw new Error('SUPABASE_URL and SUPABASE_PAT required');
const projectRef = SUPABASE_URL.match(/https?:\/\/([^.]+)\./)[1];

function http(opts, body) {
  return new Promise((res, rej) => {
    const req = https.request(opts, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d, headers: r.headers }));
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
  if (r.status >= 300) throw new Error(`SQL ${r.status}: ${r.body.slice(0, 300)}`);
  return JSON.parse(r.body);
}

async function fetchUrl(url, depth = 0) {
  return new Promise((res, rej) => {
    https.get(url, { headers: { 'User-Agent': 'Mozilla/5.0 verify-probe' } }, r => {
      // Follow up to 3 redirects (Lovable apps sometimes redirect once)
      if ([301, 302, 307, 308].includes(r.statusCode) && r.headers.location && depth < 3) {
        const next = r.headers.location.startsWith('http')
          ? r.headers.location
          : new URL(r.headers.location, url).toString();
        r.resume();
        return fetchUrl(next, depth + 1).then(res, rej);
      }
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => res({ status: r.statusCode, body: d, headers: r.headers, finalUrl: url }));
    }).on('error', rej);
  });
}

async function scanApp(name, host) {
  console.log(`\n[${name}] scanning ${host} ...`);
  let index;
  try {
    index = await fetchUrl(`https://${host}/`);
  } catch (e) {
    console.log(`  ✗ fetch index failed: ${e.message}`);
    return { app: name, host, ok: false, error: e.message };
  }
  if (index.status !== 200) {
    console.log(`  ✗ index status ${index.status}`);
    return { app: name, host, ok: false, error: `index status ${index.status}` };
  }
  // Extract JS asset URLs (Vite-style: /assets/*.js)
  const bundleRefs = [...new Set([...index.body.matchAll(/\/assets\/[A-Za-z0-9_\-.]+\.js/g)].map(m => m[0]))];
  console.log(`  bundles found in index.html: ${bundleRefs.length}`);
  let hits = 0;
  let scanned = 0;
  let hitFiles = [];
  for (const ref of bundleRefs) {
    const url = `https://${host}${ref}`;
    try {
      const b = await fetchUrl(url);
      if (b.status !== 200) continue;
      scanned++;
      // Look for the header name in any case
      if (/x-app-source/i.test(b.body)) {
        hits++;
        hitFiles.push(ref);
      }
    } catch (_) { /* ignore individual fetch errors */ }
  }
  console.log(`  scanned: ${scanned}/${bundleRefs.length} bundles`);
  console.log(`  contains X-App-Source: ${hits} ${hits > 0 ? '✓' : '✗'}`);
  if (hitFiles.length) console.log(`  matches: ${hitFiles.join(', ')}`);
  return { app: name, host, bundles: bundleRefs.length, scanned, hits, hitFiles };
}

(async () => {
  console.log('================================================================');
  console.log('  X-App-Source rollout verification — ADR-016');
  console.log('================================================================');

  // ----- 1. audit.logs check -----
  console.log('\n--- audit.logs in the last 24h, grouped by app_source ---');
  const byApp = await pg(`
    SELECT COALESCE(app_source, '(null)') AS app_source, COUNT(*)::int AS cnt
    FROM audit.logs
    WHERE changed_at > now() - INTERVAL '24 hours'
    GROUP BY 1
    ORDER BY cnt DESC;
  `);
  if (!byApp.length) {
    console.log('  (no audit rows in the last 24h)');
  } else {
    for (const r of byApp) console.log(`  ${r.app_source.padEnd(22)} ${r.cnt}`);
  }

  console.log('\n--- rows where request_context->>"app_source_hint" IS NOT NULL (last 24h) ---');
  console.log('(this means X-App-Source HEADER actually arrived — not just Origin-inferred)');
  const explicit = await pg(`
    SELECT COALESCE(app_source, '(null)') AS app_source,
           request_context->>'app_source_hint' AS hint,
           COUNT(*)::int AS cnt,
           MAX(changed_at)::text AS most_recent
    FROM audit.logs
    WHERE changed_at > now() - INTERVAL '24 hours'
      AND request_context->>'app_source_hint' IS NOT NULL
    GROUP BY 1, 2
    ORDER BY cnt DESC;
  `);
  if (!explicit.length) {
    console.log('  (none — explicit X-App-Source header has not arrived from ANY app in the last 24h)');
  } else {
    for (const r of explicit) console.log(`  app=${r.app_source.padEnd(20)} hint=${(r.hint ?? '').padEnd(20)} cnt=${r.cnt} last=${r.most_recent}`);
  }

  console.log('\n--- latest 5 audit rows (any table, last 4h) for sanity check ---');
  const recent = await pg(`
    SELECT changed_at::text AS changed_at,
           table_name,
           operation,
           COALESCE(app_source, '(null)') AS app_source,
           COALESCE(request_context->>'app_source_hint', '(null)') AS hint,
           COALESCE(request_context->>'origin', '(null)') AS origin
    FROM audit.logs
    WHERE changed_at > now() - INTERVAL '4 hours'
    ORDER BY changed_at DESC
    LIMIT 5;
  `);
  for (const r of recent) {
    console.log(`  ${r.changed_at}  ${r.table_name}/${r.operation}  app=${r.app_source}  hint=${r.hint}  origin=${r.origin}`);
  }

  // ----- 2. bundle scan -----
  console.log('\n--- bundle scan ---');
  const apps = [
    { name: 'DERM Tracker',  host: 'derm.unclogme.app' },
    { name: 'Field Portal',  host: 'fp.unclogme.app' },
    { name: 'Admin Review',  host: 'grease-buddy-dash.lovable.app' },
  ];
  const results = [];
  for (const a of apps) results.push(await scanApp(a.name, a.host));

  console.log('\n================================================================');
  console.log('  SUMMARY');
  console.log('================================================================');
  for (const r of results) {
    const tag = r.hits > 0 ? '✓ DEPLOYED' : '✗ NOT DEPLOYED';
    console.log(`  ${r.app.padEnd(18)} ${r.host.padEnd(40)} ${tag} (${r.hits}/${r.scanned} bundles)`);
  }
})().catch(e => { console.error('FATAL:', e.message); process.exit(1); });
