#!/usr/bin/env node
/**
 * ONE-OFF IMPORT of Jobber's "Lock Box/Key" into public.properties.lock_box_key.
 * DRY RUN BY DEFAULT. Pass --apply to write. NOT WIRED TO CRON.
 *
 * ============================================================================
 * WHY A SEPARATE SCRIPT, AND NOT public.fn_sync_property_custom_field
 * ============================================================================
 * That function CANNOT perform a first import, by design, and this is the single
 * most important thing to understand before touching this file.
 *
 * It decides by comparing Jobber's current value against sync.source_field_shadow,
 * i.e. what we LAST SAW. For a field we have never carried there is no shadow row,
 * so the first call returns SEED: it records what Jobber holds and writes nothing.
 * The second call then compares the same value against the same stored value, gets
 * "unchanged", and returns IN_SYNC. There is no sequence of calls that imports an
 * existing value, because "unchanged at the source" correctly means "not an edit".
 *
 * That is right for the grease trap size, which was ALREADY ours before the shadow
 * was built around it. Lock Box/Key is genuinely new: the column is empty and
 * Jobber holds the only copy. Importing it is a different operation from adopting
 * an edit, so it gets its own explicitly-named script rather than a flag that makes
 * the adopt path do something it should never do.
 *
 * ============================================================================
 * WHAT IT WILL NOT DO
 * ============================================================================
 *  - it will not write to Jobber. Inbound only, like everything else here.
 *  - it will not overwrite a value we already hold. The UPDATE is pinned to
 *    lock_box_key IS NULL, so a code somebody typed in the Client App survives a
 *    re-run. Re-running this script is therefore safe and idempotent.
 *  - it will not import the "N/A" placeholder. Measured 2026-09-02: 18 of the 46
 *    populated Jobber values are literally that. It is the text sentinel for "no
 *    lock box", exactly as 0 is the numeric one, and storing it would put N/A in
 *    front of a driver looking for a code.
 *  - it will not touch a BILLING property row. Those store the CLIENT gid with a
 *    _billing suffix in entity_source_links, so a Property gid simply does not
 *    match one. See the trap documented in Supabase/CLAUDE.md.
 *
 * ============================================================================
 * PROVENANCE
 * ============================================================================
 * Every imported value also records a sync.source_field_shadow row through
 * sync.fn_record_shadow, shaped exactly as a real adoption is: source_value = the
 * Jobber value, our_value = the pre-import NULL, adopted_to = the Jobber value.
 * Without that, the very next poll would see a field with no shadow, call it a
 * SEED, and we would have a value in the column that the sync believes it has
 * never seen. The audit row is attributed with x-app-source so the write is not
 * anonymous.
 *
 * USAGE
 *   node scripts/sync/import_jobber_lock_box_key.js            # dry run
 *   node scripts/sync/import_jobber_lock_box_key.js --apply    # write
 */
const fs = require('fs');
const path = require('path');

const APPLY = process.argv.includes('--apply');
const FIELD_KEY = 'gid://Jobber/CustomFieldConfigurationText/3061112';
const FIELD_LABEL = 'Lock Box/Key';
const PLACEHOLDER = /^n\/?a$/i;

const repoRoot = path.resolve(__dirname, '..', '..');
const env = Object.fromEntries(
  fs.readFileSync(path.join(repoRoot, '.env'), 'utf8')
    .split(/\r?\n/).filter(l => l.includes('='))
    .map(l => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()])
);

async function sql(query) {
  const r = await fetch(
    `https://api.supabase.com/v1/projects/${env.SUPABASE_PROJECT_ID}/database/query`,
    { method: 'POST',
      headers: { Authorization: `Bearer ${env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query }) });
  const text = await r.text();
  let j; try { j = JSON.parse(text); } catch { throw new Error('non-JSON from Management API: ' + text.slice(0, 200)); }
  if (j && j.message) throw new Error('SQL failed: ' + j.message);
  return j;
}

async function jobber() {
  // Windows: the default shell is cmd.exe, which cannot run a .sh. Invoke bash explicitly.
  const tokenCmd = require('child_process').execSync('bash ./jobber-token.sh',
    { cwd: path.resolve(repoRoot, '..', 'Slack') }).toString().trim();
  const Q = `query($after:String){ properties(first:100, after:$after){ pageInfo{hasNextPage endCursor} nodes{ id customFields{ __typename ... on CustomFieldText{ label valueText } } } } }`;
  let after = null, out = [], scanned = 0;
  for (let page = 0; page < 20; page++) {
    const r = await fetch('https://api.getjobber.com/api/graphql', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + tokenCmd, 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16', 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: Q, variables: { after } })
    });
    // Jobber sheds load with an HTML waiting room at HTTP 200. The status code lies;
    // the content-type does not. See Supabase/CLAUDE.md.
    const ctype = r.headers.get('content-type') || '';
    if (!ctype.includes('json')) throw new Error(`Jobber returned ${ctype} at HTTP ${r.status} (waiting room?)`);
    const j = await r.json();
    if (!j.data) throw new Error('Jobber replied without a data key: ' + JSON.stringify(j).slice(0, 200));
    const p = j.data.properties;
    scanned += p.nodes.length;
    for (const n of p.nodes) {
      const f = (n.customFields || []).find(c => c.label === FIELD_LABEL);
      const v = f && f.valueText != null ? String(f.valueText).trim() : '';
      if (v !== '') out.push({ gid: n.id, value: v });
    }
    if (!p.pageInfo.hasNextPage) break;
    after = p.pageInfo.endCursor;
  }
  return { scanned, values: out };
}

(async () => {
  const { scanned, values } = await jobber();
  // Control characters, tested by CODE POINT rather than by a regex class. Two earlier
  // drafts of this line were mangled in transit: one wrote a raw control byte into this
  // file, the next collapsed to /[-]/, which matches a literal hyphen and would have
  // rejected a real code like "A-14". There is nothing left here for a shell, an editor
  // or an escape layer to eat.
  const hasControl = (str) => [...str].some(ch => ch.charCodeAt(0) < 32 || ch.charCodeAt(0) === 127);
  const usable = values.filter(v => !PLACEHOLDER.test(v.value) && v.value.length <= 100 && !hasControl(v.value));
  const skipped = values.filter(v => !usable.includes(v));

  const payload = JSON.stringify(usable).replace(/'/g, "''");

  // Resolve, filter and report in ONE statement, so the dry run and the apply see
  // exactly the same candidate set rather than two queries that can disagree.
  const plan = await sql(`
    with incoming as (
      select (x->>'gid') as gid, (x->>'value') as value
        from jsonb_array_elements('${payload}'::jsonb) x
    )
    select i.gid, i.value, l.entity_id as property_id, p.lock_box_key as current_value,
           (p.id is not null and p.lock_box_key is null) as would_write
      from incoming i
      left join public.entity_source_links l
        on l.entity_type='property' and l.source_system='jobber' and l.source_id = i.gid
      left join public.properties p on p.id = l.entity_id and p.deleted_at is null
     order by would_write desc, i.gid;`);

  const rows = Array.isArray(plan) ? plan : [];
  const write = rows.filter(r => r.would_write);
  const unlinked = rows.filter(r => r.property_id === null);
  const held = rows.filter(r => r.property_id !== null && r.current_value !== null);

  console.log(JSON.stringify({
    mode: APPLY ? 'APPLY' : 'DRY RUN',
    jobber_properties_scanned: scanned,
    jobber_values_found: values.length,
    skipped_placeholder_or_bad: skipped.length,
    skipped_examples: skipped.slice(0, 5).map(s => s.value),
    resolvable_to_our_properties: rows.filter(r => r.property_id !== null).length,
    unlinked_in_jobber_only: unlinked.length,
    already_hold_a_value: held.length,
    would_write: write.length,
    sample: write.slice(0, 8).map(r => ({ property: r.property_id, value: r.value }))
  }, null, 1));

  if (!APPLY) { console.log('\nDry run. Nothing written. Re-run with --apply.'); return; }
  if (!write.length) { console.log('\nNothing to write.'); return; }

  const applyPayload = JSON.stringify(write.map(r => ({ id: r.property_id, value: r.value }))).replace(/'/g, "''");
  const res = await sql(`
    do $import$
    declare rec record; n integer := 0;
    begin
      perform set_config('request.headers', '{"x-app-source":"jobber-lock-box-import"}', true);
      for rec in select (x->>'id')::bigint as id, (x->>'value') as value
                   from jsonb_array_elements('${applyPayload}'::jsonb) x
      loop
        -- pinned to IS NULL: never overwrite a value somebody typed in the app,
        -- which also makes a re-run of this script a no-op rather than a clobber.
        update public.properties set lock_box_key = rec.value
         where id = rec.id and lock_box_key is null;
        if found then
          n := n + 1;
          -- shaped exactly like a real adoption: our_value is the PRE-import NULL.
          perform sync.fn_record_shadow('property', rec.id, 'jobber',
                    '${FIELD_KEY}', '${FIELD_LABEL}',
                    to_jsonb(rec.value), 'null'::jsonb, to_jsonb(rec.value));
        end if;
      end loop;
      raise notice 'imported %', n;
    end $import$;
    select count(*) filter (where lock_box_key is not null) as with_value,
           count(*) as total
      from public.properties where deleted_at is null;`);
  console.log('\nAFTER:', JSON.stringify(res));
})().catch(e => { console.error('FAILED:', e.message); process.exit(1); });
