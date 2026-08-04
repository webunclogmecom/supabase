#!/usr/bin/env node
/**
 * DRY RUN for enabling the Jobber property poll. WRITES NOTHING.
 *
 * WHY THIS EXISTS
 *   `PROPERTY_UPDATE` has produced zero events ever. cron_jobber.js pulls properties only on a
 *   `--full` run (they have no time-filterable cursor), and `--full` is never passed by any
 *   workflow, so a Jobber-side edit to a SERVICE property address never reaches us. That is what
 *   left the DUMP Pompano address stale for two months.
 *
 *   Turning the poll on would replay every property through webhook-jobber's handleProperty at
 *   once. This script computes EXACTLY the row handleProperty would write, for every Jobber
 *   property, and diffs it against what we store, so the blast radius is known before anything is
 *   scheduled.
 *
 * FIDELITY TO handleProperty (webhook-jobber/index.ts ~1245) - kept deliberately identical:
 *   name      p.name ?? null
 *   address   p.address?.street ?? null
 *   city      p.address?.city ?? null
 *   state     p.address?.province ?? 'FL'
 *   zip       p.address?.postalCode ?? null
 *   latitude  ONLY when Jobber returns non-null (never overwrite a geocode with NULL)
 *   longitude same
 *   county    NOT touched on update (the handler preserves it; it only infers on INSERT)
 *
 * Usage:  node scripts/sync/dryrun_property_poll.js [--limit N] [--json out.json]
 */
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const env = Object.fromEntries(
  fs.readFileSync(path.join(ROOT, '.env'), 'utf8')
    .split(/\r?\n/).filter((l) => l.includes('=') && !l.trim().startsWith('#'))
    .map((l) => { const i = l.indexOf('='); return [l.slice(0, i).trim(), l.slice(i + 1).trim()]; })
);
const LIMIT = (() => { const i = process.argv.indexOf('--limit'); return i > -1 ? Number(process.argv[i + 1]) : Infinity; })();
const JSON_OUT = (() => { const i = process.argv.indexOf('--json'); return i > -1 ? process.argv[i + 1] : null; })();

async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(t.slice(0, 400));
  return JSON.parse(t);
}

const JT = execSync('./jobber-token.sh', { cwd: path.join(ROOT, '..', 'Slack'), shell: 'bash' }).toString().trim();
async function gql(query, variables) {
  for (let a = 0; a < 4; a++) {
    const r = await fetch('https://api.getjobber.com/api/graphql', {
      method: 'POST',
      headers: { Authorization: `Bearer ${JT}`, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Type': 'application/json' },
      body: JSON.stringify({ query, variables }),
    });
    if (r.status === 429) { await new Promise((x) => setTimeout(x, 3000)); continue; }
    const j = JSON.parse(await r.text());
    if (j.errors) throw new Error(JSON.stringify(j.errors).slice(0, 300));
    return j;
  }
  throw new Error('rate limited');
}

(async () => {
  // 1. our side, keyed by the Jobber GID
  const ours = await sql(`
    select l.source_id gid, p.id, p.name, p.address, p.city, p.state, p.zip, p.county,
           p.latitude::text lat, p.longitude::text lng
      from public.entity_source_links l
      join public.properties p on p.id = l.entity_id
     where l.entity_type='property' and l.source_system='jobber'`);
  const byGid = new Map(ours.map((r) => [r.gid, r]));
  console.log(`our side: ${ours.length} Jobber-linked properties`);

  // 2. Jobber side, paginated
  const Q = `query($after:String){ properties(first:100, after:$after){
    totalCount pageInfo{ hasNextPage endCursor }
    nodes{ id name address{ street city province postalCode coordinates{ latitude longitude } } } } }`;
  let after = null, jobber = [], total = 0;
  do {
    const r = await gql(Q, { after });
    const c = r.data.properties;
    total = c.totalCount;
    jobber.push(...c.nodes);
    after = c.pageInfo.hasNextPage ? c.pageInfo.endCursor : null;
    process.stdout.write(`\rjobber: ${jobber.length}/${total}`);
  } while (after && jobber.length < LIMIT);
  console.log(`\njobber side: ${jobber.length} of ${total}`);

  // 3. diff, computing the row handleProperty would write
  const changes = [], unlinked = [], colCount = {};
  for (const p of jobber) {
    const cur = byGid.get(p.id);
    if (!cur) { unlinked.push(p.id); continue; }
    // mirrors handleProperty: a BLANK name from Jobber is not written at all, so it can never
    // overwrite a name we already hold (that guard was added because this dry run found it).
    const jobberName = typeof p.name === 'string' ? p.name.trim() : null;
    const want = {
      address: p.address?.street ?? null,
      city: p.address?.city ?? null,
      state: p.address?.province ?? 'FL',
      zip: p.address?.postalCode ?? null,
    };
    if (jobberName) want.name = jobberName;
    if (p.address?.coordinates?.latitude != null) want.latitude = String(p.address.coordinates.latitude);
    if (p.address?.coordinates?.longitude != null) want.longitude = String(p.address.coordinates.longitude);

    const have = { name: cur.name, address: cur.address, city: cur.city, state: cur.state, zip: cur.zip,
                   latitude: cur.lat, longitude: cur.lng };
    const diffs = [];
    for (const k of Object.keys(want)) {
      const a = want[k] == null ? null : String(want[k]);
      let b = have[k] == null ? null : String(have[k]);
      // coordinates: compare numerically, a float round-trip is not a change
      if ((k === 'latitude' || k === 'longitude') && a != null && b != null) {
        if (Math.abs(Number(a) - Number(b)) < 1e-6) continue;
      }
      if (a !== b) { diffs.push({ col: k, from: b, to: a }); colCount[k] = (colCount[k] || 0) + 1; }
    }
    if (diffs.length) changes.push({ id: cur.id, gid: p.id, diffs });
  }

  console.log(`\n=== WOULD CHANGE: ${changes.length} of ${jobber.length} properties ===`);
  console.log('columns affected:');
  for (const [k, n] of Object.entries(colCount).sort((a, b) => b[1] - a[1])) console.log(`  ${String(k).padEnd(10)} ${n}`);
  console.log(`\nJobber properties with no link on our side (would INSERT): ${unlinked.length}`);

  // the shapes that matter, so a reviewer sees the KIND of change not just a count
  const byShape = {};
  for (const c of changes) {
    const k = c.diffs.map((d) => d.col).sort().join('+');
    (byShape[k] = byShape[k] || []).push(c);
  }
  console.log('\n=== change shapes ===');
  for (const [shape, list] of Object.entries(byShape).sort((a, b) => b[1].length - a[1].length)) {
    console.log(`\n  ${String(list.length).padStart(4)}x  [${shape}]`);
    for (const c of list.slice(0, 3)) {
      console.log(`        property ${c.id}`);
      for (const d of c.diffs) console.log(`          ${d.col}: ${JSON.stringify(d.from)}  ->  ${JSON.stringify(d.to)}`);
    }
    if (list.length > 3) console.log(`        ... +${list.length - 3} more`);
  }

  // controls: a dry run that finds nothing is indistinguishable from a broken one
  console.log('\n=== controls ===');
  console.log(`  jobber rows fetched          : ${jobber.length} ${jobber.length > 0 ? '(fetch works)' : '<-- BROKEN'}`);
  console.log(`  our rows loaded              : ${ours.length} ${ours.length > 0 ? '(db read works)' : '<-- BROKEN'}`);
  const matched = jobber.length - unlinked.length;
  console.log(`  matched by GID               : ${matched} ${matched > 0 ? '(the join works)' : '<-- BROKEN, every row would look like an INSERT'}`);
  const pompano = changes.find((c) => c.id === 155);
  console.log(`  property 155 (Pompano) clean : ${pompano ? 'NO - still differs: ' + JSON.stringify(pompano.diffs) : 'yes (we just synced it, so a clean result here is expected)'}`);

  if (JSON_OUT) { fs.writeFileSync(JSON_OUT, JSON.stringify({ changes, unlinked, colCount }, null, 1)); console.log(`\nfull detail -> ${JSON_OUT}`); }
})().catch((e) => { console.error('FAILED: ' + e.message); process.exit(1); });
