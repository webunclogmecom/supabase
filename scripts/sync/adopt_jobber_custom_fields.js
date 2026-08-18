#!/usr/bin/env node
/**
 * ADOPT Jobber custom-field edits into our warehouse. DRY RUN BY DEFAULT.
 * NOT WIRED TO CRON. Fred has not approved changing the live sync.
 *
 * ============================================================================
 * THE RULE THIS IMPLEMENTS, AND WHY IT IS NOT "COPY JOBBER'S VALUE"
 * ============================================================================
 * Jobber's numeric custom field has defaultValue 0, is materialised on every
 * property, and has NO updatedAt. A property nobody ever touched reads exactly like
 * one where a human typed 0. Measured over the 105 linked properties carrying a
 * size, a straight copy would zero 69 of them (47,732 gallons), overwrite 10 more
 * (9 downward) and correct 3: 79 of 105 damaged, silently, because
 * public.properties_grease_trap_size_chk permits 0.
 *
 * So adoption compares Jobber's CURRENT value against sync.source_field_shadow,
 * what we LAST SAW, and fires only on a difference:
 *
 *     jobber now | last seen | decision
 *     0          | 0         | IGNORE     <- the 69. Not an edit.
 *     190        | 0         | ADOPT      <- a human typed it
 *     0          | 190       | ADOPT      <- a human cleared it (needs --allow-clear)
 *     500        | 500       | IGNORE     <- stale, not a decision
 *     (no row)   | -         | SEED       <- record, adopt nothing
 *     both moved              CONFLICT    <- record, touch neither side
 *
 * 🛑 THE DECISION IS NOT REIMPLEMENTED HERE. It is computed by
 * sync.fn_shadow_decision in the database, whose truth table is asserted in
 * docs/migrations/2026-08-17_1636_jobber_custom_field_shadow.sql. A second copy of
 * this logic in JS is a second thing to get wrong, and only one of the two would
 * ever be tested.
 *
 * 🛑 NEVER REPLACE THE SHADOW COMPARE WITH A TRUTHINESS TEST. `if (value)`,
 * `value ?? fallback` and `value || 0` all drop a legitimate 0. The compare is an
 * identity compare (IS DISTINCT FROM), done in SQL, against the stored last-seen.
 *
 * ============================================================================
 * WHAT THIS SCRIPT WILL NOT DO
 * ============================================================================
 *  - it will not write to Jobber. This is the INBOUND half only. The outbound
 *    mutation (propertyEdit with a customFields-only input) exists and is
 *    reachable, but shipping both halves at once means neither can be observed.
 *  - it will not clear a recorded capacity without --allow-clear. An adopt whose
 *    new value is null or 0 is a legitimate outcome of a human clearing the field,
 *    and it is also the single most damaging write this sync can make.
 *  - it will not resolve a conflict. Both sides moved => record it, touch neither.
 *    Fred's standing ruling: the existing disagreements are a human question.
 *  - it will not write outside public.properties_grease_trap_size_chk (0..20000).
 *
 * ============================================================================
 * ATTRIBUTION. Adoption writes set request.headers.x-app-source so audit.logs
 * records them as 'jobber-custom-field-sync' rather than the 'sql' catch-all that
 * every Management API and psql write lands in. Without it an adoption would be
 * indistinguishable from a human's manual edit, which is precisely the signal the
 * conflict rule depends on being able to read later.
 *
 * ============================================================================
 * USAGE
 *   node scripts/sync/adopt_jobber_custom_fields.js                 # dry run
 *   node scripts/sync/adopt_jobber_custom_fields.js --apply         # writes
 *   optional: --field grease_trap_size  --page 25  --allow-clear
 *             --limit N (cap the number of adoptions in one run)  --json out.json
 *             --only 217,218 (act on named properties only; the fleet-wide controls are
 *                             still measured over all 458 rows before this narrows)
 * ============================================================================
 */
const fs = require('fs');
const {
  fieldById, sql, lit, jlit, fetchJobberProperties, loadOurProperties,
} = require('./jobber_custom_fields');

const argv = process.argv.slice(2);
const flag = (name, dflt) => { const i = argv.indexOf(name); return i > -1 ? argv[i + 1] : dflt; };
const APPLY = argv.includes('--apply');
const ALLOW_CLEAR = argv.includes('--allow-clear');
const FIELD = fieldById(flag('--field', 'grease_trap_size'));
const PAGE = Number(flag('--page', 25));
const MIN_COVERAGE = Number(flag('--min-coverage', 0.9));
const LIMIT = Number(flag('--limit', Infinity));
const JSON_OUT = flag('--json', null);
// 🛑 SPLIT THE EMPTY STRING AND YOU GET [''], NOT []. Number('') is 0, and 0 is finite, so
// the obvious one-liner made ONLY default to [0] on every run WITHOUT the flag: the fleet-wide
// path then narrowed to a property id that cannot exist and aborted before deciding anything.
// Shipped in 1f169fa and invisible for an hour because the only run made after it was --only 217.
// The filter must reject non-numeric TEXT before Number() is allowed to coerce it.
const ONLY = String(flag('--only', '')).split(',')
  .map((s) => s.trim()).filter((s) => s !== '')
  .map(Number).filter((n) => Number.isFinite(n) && n > 0);
// Self-test, at module load, because the defect above was a DEFAULT-path defect: it could only
// ever be caught by exercising the absent-flag case, which no --only run does by construction.
for (const [input, expect] of [['', []], ['217', [217]], [' 217 , 218 ', [217, 218]], ['217,,', [217]]]) {
  const got = String(input).split(',').map((s) => s.trim()).filter((s) => s !== '')
    .map(Number).filter((n) => Number.isFinite(n) && n > 0);
  if (JSON.stringify(got) !== JSON.stringify(expect)) {
    throw new Error(`--only parser drift: ${JSON.stringify(input)} -> ${JSON.stringify(got)}, expected ${JSON.stringify(expect)}`);
  }
}
const APP_SOURCE = 'jobber-custom-field-sync';

/** Only used for range/clearing checks. NOT for deciding whether to adopt. */
function adoptionRefusal(field, value) {
  if (value === null) return field.clearingIsDangerous && !ALLOW_CLEAR ? 'would CLEAR (null)' : null;
  if (field.kind === 'numeric') {
    if (typeof value !== 'number' || !Number.isFinite(value)) return `not a finite number: ${JSON.stringify(value)}`;
    if (value < field.ourMin || value > field.ourMax) return `outside ${field.ourMin}..${field.ourMax}: ${value}`;
    if (!Number.isInteger(value)) return `not an integer (our column is integer): ${value}`;
    if (value === 0 && field.clearingIsDangerous && !ALLOW_CLEAR) return 'would CLEAR (0)';
  }
  return null;
}

(async () => {
  console.log(`ADOPT jobber custom fields  [${APPLY ? 'APPLY' : 'DRY RUN (default)'}]${ALLOW_CLEAR ? '  --allow-clear' : ''}`);
  console.log(`  field     : ${FIELD.label}  (${FIELD.kind})`);
  console.log(`  field_key : ${FIELD.fieldKey}`);
  console.log(`  our column: ${FIELD.ourTable}.${FIELD.ourColumn}\n`);

  const ours = await loadOurProperties(FIELD);
  console.log(`  our side  : ${ours.length} properties with a real Jobber Property link`);
  console.log(`  shadowed  : ${ours.filter((r) => r.shadow_exists).length}`);

  const { properties: jobber, total } = await fetchJobberProperties({ pageSize: PAGE });

  // -------------------------------------------------------------- assemble
  const rows = [], unresolved = [];
  let materialised = 0;
  for (const r of ours) {
    const j = jobber.get(r.gid);
    if (!j) { unresolved.push({ property_id: r.property_id, name: r.property_name, gid: r.gid }); continue; }
    const cf = j.byConfig.get(FIELD.fieldKey);
    if (cf) materialised += 1;
    rows.push({
      property_id: r.property_id,
      name: r.property_name,
      shadow_exists: !!r.shadow_exists,
      source_now: cf ? cf.value : null,
      // 🛑 KEEP "JOBBER DID NOT ANSWER" SEPARATE FROM "JOBBER SAYS EMPTY". `cf ? cf.value : null`
      // collapses them, and the two mean opposite things: the first is a broken read, the second
      // is a fact about the property. The seed script keeps the distinction per row and refuses
      // to record a fleet of nulls; this script used to check it only in AGGREGATE (the coverage
      // threshold), and an aggregate tolerates up to 10% of the fleet failing to answer. Under
      // --allow-clear each of those non-answers becomes an UPDATE to NULL: at the gate's own
      // limit that is 45 properties and 58,351 gallons erased by a read failure. Same shape as
      // every other defect here, a value that is inert in one script and destructive in another.
      materialised: !!cf,
      our_now: r.our_value === null || r.our_value === undefined ? null : Number(r.our_value),
      source_seen: r.shadow_source_value === null || r.shadow_source_value === undefined ? null : JSON.parse(r.shadow_source_value),
      our_seen: r.shadow_our_value === null || r.shadow_our_value === undefined ? null : JSON.parse(r.shadow_our_value),
      already_in_conflict: !!r.shadow_in_conflict,
    });
  }

  // 🛑 THE CONTROLS ARE COMPUTED OVER THE WHOLE FLEET, BEFORE --only NARROWS ANYTHING.
  // The coverage threshold exists to catch "Jobber stopped answering for this field", and
  // a threshold measured over a single hand-picked property would pass on 1/1 = 100% while
  // the field had vanished everywhere else. Narrowing must never be able to satisfy a
  // control that the full sweep would have failed.
  const matched = rows.length;
  const coverage = matched ? materialised / matched : 0;
  console.log('\n=== controls ===');
  console.log(`  jobber properties fetched : ${jobber.size} of ${total} ${jobber.size > 0 ? '(fetch works)' : '<-- BROKEN'}`);
  console.log(`  our rows loaded           : ${ours.length} ${ours.length > 0 ? '(db read works)' : '<-- BROKEN'}`);
  console.log(`  matched by GID            : ${matched} ${matched > 0 ? '(the join works)' : '<-- BROKEN'}`);
  console.log(`  field materialised on     : ${materialised}/${matched} = ${(coverage * 100).toFixed(1)}%  (threshold ${(MIN_COVERAGE * 100).toFixed(0)}%)`);

  // --only <id,id,...>: act on named properties only. For targeted verification (edit one
  // value in Jobber, watch exactly that one land) without a 458-row sweep, which is both
  // slow and a needless exposure to a transient Management API 502 mid-loop.
  if (ONLY.length) {
    const before = rows.length;
    rows.splice(0, rows.length, ...rows.filter((r) => ONLY.includes(r.property_id)));
    console.log(`  --only                    : ${rows.length} of ${before} rows kept (${ONLY.join(', ')})`);
    if (!rows.length) throw new Error(`--only matched no linked property: ${ONLY.join(', ')}`);
  }

  // ---------------------------------------------------- decide, IN THE DATABASE
  // One round trip. sync.fn_shadow_decision is the single implementation and its
  // truth table is asserted in the migration.
  const decisions = new Map();
  const CHUNK = 300;
  for (let i = 0; i < rows.length; i += CHUNK) {
    const chunk = rows.slice(i, i + CHUNK);
    const values = chunk.map((r) =>
      `(${r.property_id}::bigint, ${r.shadow_exists}::boolean, ${jlit(r.source_now)}, ` +
      `${r.source_seen === null && !r.shadow_exists ? 'null::jsonb' : jlit(r.source_seen)}, ` +
      `${jlit(r.our_now)}, ` +
      `${r.our_seen === null && !r.shadow_exists ? 'null::jsonb' : jlit(r.our_seen)})`).join(',\n        ');
    const got = await sql(`
      select t.property_id,
             sync.fn_shadow_decision(t.shadow_exists, t.source_now, t.source_seen, t.our_now, t.our_seen) as decision
        from (values
        ${values}
      ) as t(property_id, shadow_exists, source_now, source_seen, our_now, our_seen);`);
    for (const g of got) decisions.set(Number(g.property_id), g.decision);
  }
  for (const r of rows) r.decision = decisions.get(r.property_id) ?? 'UNKNOWN';

  // --------------------------------------------------------------- refusals
  // 🛑 A ROW ALREADY CARRYING conflict_at IS FROZEN AND IS NOT ELIGIBLE FOR ANYTHING BUT
  // IN_SYNC. already_in_conflict was loaded here from the start and then never read, so a
  // row explicitly held for a person was fully eligible for a later ADOPT: their value in
  // public.properties would be overwritten while the flag still said nobody had looked.
  // fn_record_shadow now refuses this outright (2026-08-18_0120) and that refusal is the
  // real guarantee; classifying it here just turns an exception into a readable report.
  for (const r of rows) {
    // A non-answer is never an edit. Refused per row, unconditionally, and NOT behind
    // --allow-clear: that flag exists to authorise a human's deliberate clear, and it must
    // not double as permission to act on a read that failed.
    r.refusal = r.decision === 'ADOPT'
      ? (r.materialised ? adoptionRefusal(FIELD, r.source_now)
        : 'jobber returned no value for this configuration (a failed read, not an empty field)')
      : null;
    if (r.already_in_conflict && r.decision !== 'IN_SYNC') r.effective = 'FROZEN';
    else if (r.refusal) r.effective = 'REFUSED';
    else r.effective = r.decision;
  }

  const by = (d) => rows.filter((r) => r.effective === d);
  const adopts = by('ADOPT').slice(0, LIMIT === Infinity ? undefined : LIMIT);
  const adoptIds = new Set(adopts.map((r) => r.property_id));

  // 🛑 AN ADOPT ROW HELD BACK BY --limit MUST BE DEFERRED, NOT RECORDED. It used to fall
  // through to fn_record_shadow with p_adopted_to = null, which re-baselines source_value
  // to the CURRENT Jobber value while writing nothing to properties. The next run then
  // reads source_now = source_seen and decides IGNORE, so the human's Jobber edit is
  // discarded and NO future run re-detects it. Proven with a sentinel:
  //     jobber 0 -> 190, caller adopts nothing  ->  ADOPT, source_value re-baselined to 190
  //     next run, same state                    ->  IGNORE   <- the edit is gone
  // It fails toward not writing, so no wrong value ever reaches properties, which is why it
  // survived the first safety review. REFUSED was already excluded for the same reason; this
  // is the one case that slipped through. Skipping the row leaves the shadow untouched, so
  // the next run sees the same ADOPT and picks it up.
  //
  // ⚠ Computed HERE, above the dry-run gate, on purpose: the dry run prints the size of the
  // exact array the write loop iterates, so `--limit` is observable without --apply.
  const actionable = rows.filter((r) =>
    r.effective !== 'REFUSED' && r.effective !== 'UNKNOWN' && r.effective !== 'FROZEN' &&
    !(r.effective === 'ADOPT' && !adoptIds.has(r.property_id)));

  console.log('\n=== decisions ===');
  for (const d of ['SEED', 'IN_SYNC', 'IGNORE', 'ADOPT', 'CONFLICT', 'FROZEN', 'REFUSED', 'UNKNOWN']) {
    const n = by(d).length;
    if (n) console.log(`  ${d.padEnd(9)} ${String(n).padStart(4)}`);
  }
  if (LIMIT !== Infinity && by('ADOPT').length > LIMIT) {
    console.log(`  (--limit ${LIMIT}: ${by('ADOPT').length - LIMIT} adoptions DEFERRED to a later run;`);
    console.log('   their shadow is left untouched, so the next run re-detects them)');
  }
  console.log(`  ${'writeset'.padEnd(9)} ${String(actionable.length).padStart(4)}  <- rows this run would touch`);

  if (adopts.length) {
    console.log('\n=== would ADOPT ===');
    for (const r of adopts.slice(0, 25)) {
      console.log(`  property ${String(r.property_id).padStart(5)}  ${FIELD.ourColumn}: ${JSON.stringify(r.our_now)} -> ${JSON.stringify(r.source_now)}` +
        `   (jobber last seen ${JSON.stringify(r.source_seen)})   ${r.name ?? ''}`);
    }
    if (adopts.length > 25) console.log(`  ... +${adopts.length - 25} more`);
  }
  const refused = by('REFUSED');
  if (refused.length) {
    console.log('\n=== REFUSED (a real jobber edit this script will not write) ===');
    for (const r of refused.slice(0, 25)) {
      console.log(`  property ${String(r.property_id).padStart(5)}  ${JSON.stringify(r.our_now)} -> ${JSON.stringify(r.source_now)}   ${r.refusal}   ${r.name ?? ''}`);
    }
    if (refused.length > 25) console.log(`  ... +${refused.length - 25} more`);
    if (!ALLOW_CLEAR && refused.some((r) => String(r.refusal).startsWith('would CLEAR'))) {
      console.log('\n  A clearing adopt means a human emptied the field in Jobber. That is legitimate,');
      console.log('  and it is also how a recorded capacity gets destroyed. Look at the list, then');
      console.log('  re-run with --allow-clear if the clears are real.');
    }
  }
  const conflicts = by('CONFLICT');
  if (conflicts.length) {
    console.log('\n=== CONFLICT (both sides moved; nothing is adopted and nothing re-baselines) ===');
    for (const r of conflicts.slice(0, 25)) {
      console.log(`  property ${String(r.property_id).padStart(5)}  jobber ${JSON.stringify(r.source_seen)} -> ${JSON.stringify(r.source_now)}` +
        `   |   ours ${JSON.stringify(r.our_seen)} -> ${JSON.stringify(r.our_now)}   ${r.name ?? ''}`);
    }
    if (conflicts.length > 25) console.log(`  ... +${conflicts.length - 25} more`);
    console.log('  Fred 2026-08-17: these are a human question, not a data question.');
  }
  const frozen = by('FROZEN');
  if (frozen.length) {
    console.log(`\n=== FROZEN (${frozen.length}) — an open conflict is still waiting on a person ===`);
    console.log('  These are skipped entirely, in either direction, until someone resolves them.');
    console.log('  They release automatically only when both systems hold the SAME value.');
    for (const r of frozen.slice(0, 25)) {
      console.log(`  property ${String(r.property_id).padStart(5)}  jobber ${JSON.stringify(r.source_now)}` +
        `  |  ours ${JSON.stringify(r.our_now)}  (would otherwise be ${r.decision})   ${r.name ?? ''}`);
    }
    if (frozen.length > 25) console.log(`  ... +${frozen.length - 25} more`);
  }
  if (unresolved.length) console.log(`\n  unresolved (no matching Jobber property): ${unresolved.length}`);

  if (JSON_OUT) {
    fs.writeFileSync(JSON_OUT, JSON.stringify({ field: FIELD, rows, unresolved,
      controls: { jobberFetched: jobber.size, jobberTotal: total, ourRows: ours.length, matched, materialised, coverage } }, null, 1));
    console.log(`\nfull detail -> ${JSON_OUT}`);
  }

  // ------------------------------------------------------------------ gating
  if (!APPLY) {
    console.log('\nDRY RUN. Nothing was written, in the database or in Jobber.');
    console.log('Re-run with --apply to adopt. This script is NOT wired to cron.');
    return;
  }
  if (jobber.size === 0 || ours.length === 0 || matched === 0) {
    throw new Error('refusing to write: a control came back zero, so the instrument is untested');
  }
  if (matched > 0 && coverage < MIN_COVERAGE) {
    throw new Error(
      `refusing to write: the target configuration GID is materialised on only ${(coverage * 100).toFixed(1)}% ` +
      `of matched properties (threshold ${(MIN_COVERAGE * 100).toFixed(0)}%). A missing answer read as "empty" would ` +
      'adopt a fleet of clears. Check the field GID and the customFields selection.');
  }

  // -------------------------------------------------------------------- write
  // Per property, in ONE statement: set the app-source header locally, write the
  // business column when adopting, then record the shadow through
  // sync.fn_record_shadow, which owns the freeze-on-conflict behaviour. Passing
  // p_adopted_to is what makes the shadow re-baseline to the ADOPTED value, so the
  // next pass sees IN_SYNC rather than a phantom conflict.
  //
  // 🛑 p_our_now IS OUR **PRE-ADOPT** VALUE, ALWAYS. Do not "helpfully" pass the value
  // being adopted just because the UPDATE above has already run. fn_record_shadow does
  // the post-adopt substitution ITSELF (`our_value = coalesce(p_adopted_to, excluded.
  // our_value)`) and stores `adopted_from = p_our_now` as the record of what we
  // overwrote. This used to pass source_now on an adopt, which broke two things:
  //   * fn_shadow_decision then saw source_now = our_now, took the IN_SYNC branch
  //     (it sits ABOVE ADOPT), and the drift guard below aborted the whole run with
  //     "planned ADOPT, got IN_SYNC". THE ADOPT PATH COULD NEVER COMPLETE.
  //   * adopted_from came out equal to adopted_to, so the provenance of the
  //     overwritten value was destroyed on the way past.
  // Caught by the first real smoke test (2026-08-17, property 217 Wynd 28). It was
  // invisible to every earlier check because those exercised fn_shadow_decision and
  // fn_record_shadow directly with hand-built arguments; nothing had ever run the
  // COMPOSED statement this loop emits. Same class as a migration that verifies its
  // own GRANT statements and never asks what CREATE TABLE already handed out.
  //
  // 🛑 AND OUR SIDE IS RE-READ **INSIDE** THIS STATEMENT, NOT TAKEN FROM THE PLAN.
  // r.our_now is read once by loadOurProperties at the top of the run, minutes before this
  // loop reaches a given property (a ~19-page Jobber walk at 3s/page, then one sequential
  // round trip per property). It was the ONLY our-side input the guard had, and nothing in
  // the emitted block re-read the column, so:
  //   * a staff edit landing in that window was overwritten with no error,
  //   * the state was a real CONFLICT by this design's own rule (both sides moved since the
  //     last sync) and was executed as a plain ADOPT, so nobody was ever asked about it,
  //   * adopted_from recorded a value we never held, making the row's provenance a fiction,
  //   * and the next pass reads IN_SYNC, so the overwrite is unrecoverable through this path.
  // The column is live: audit.logs holds 120 capacity changes by 3 distinct app_sources, and
  // client.update_property_capacity is EXECUTE-able by authenticated from the Client App.
  // ⇒ Decide from the LIVE value, and pin the UPDATE to it. Two independent stoppers, because
  // the gap between the re-read and the UPDATE is itself a (much smaller) window.
  let done = 0, stale = 0;
  const staleRows = [];
  let applied = { SEED: 0, IN_SYNC: 0, IGNORE: 0, ADOPT: 0, CONFLICT: 0 };
  for (const r of actionable) {
    const willAdopt = r.effective === 'ADOPT' && adoptIds.has(r.property_id);
    const adoptedTo = willAdopt ? jlit(r.source_now) : 'null::jsonb';
    let out;
    try {
      // 🛑 THE RPC IS THE SINGLE WRITER. This script used to compose its own DO block: read
      // our column, re-decide, UPDATE, record the shadow, assert. The live poll now needs the
      // same sequence, and a second assembly of one rule is precisely how yesterday's defects
      // were born (pieces correct, composition never exercised). So the whole sequence lives in
      // public.fn_sync_property_custom_field and BOTH callers go through it. Do not reinstate a
      // local UPDATE here, however small the change seems.
      //
      // p_source_present carries the distinction the RPC cannot recover on its own: a
      // configuration missing from Jobber's payload is a FAILED READ, not an empty field.
      out = await sql(`
      select public.fn_sync_property_custom_field(
        ${r.property_id}::bigint,
        ${lit(FIELD.fieldKey)},
        ${lit(FIELD.label)},
        ${jlit(r.source_now)},
        ${r.materialised ? 'true' : 'false'}::boolean,
        ${ALLOW_CLEAR ? 'true' : 'false'}::boolean) as decision;`);
      const decision = out && out[0] ? out[0].decision : null;
      // The RPC re-decides against the LIVE column, so a mismatch here means the world moved
      // between the plan and the write. That is the guard doing its job, not a run failure:
      // report the row and carry on, and the next run re-decides it against current values.
      if (decision !== r.effective) {
        stale += 1;
        staleRows.push({ property_id: r.property_id, name: r.name, planned: r.effective,
          detail: `rpc returned ${decision}` });
        continue;
      }
    } catch (e) {
      // A stale plan is the guard working, not a run failure. The property is left exactly
      // as it was (the whole DO block rolls back) and the next run re-reads and re-decides
      // it. Aborting the sweep here would let one concurrently-edited property stop the
      // other 457. Anything else -- a transport 502, a permission error -- still aborts,
      // because those mean the instrument is untrustworthy rather than the data being live.
      // The RPC RETURNS its refusals, so a throw here is a genuine fault (transport, permission)
      // and must still abort. The message match is kept only as a backstop for the raise
      // fn_record_shadow can still emit if a row freezes between the RPC's check and its write.
      if (!/PLAN_STALE|CONFLICT_FROZEN/.test(String(e && e.message))) throw e;
      stale += 1;
      staleRows.push({ property_id: r.property_id, name: r.name, planned: r.effective,
        detail: String(e.message).replace(/\s+/g, ' ').slice(0, 200) });
      continue;
    }
    applied[r.effective] = (applied[r.effective] || 0) + 1;
    done += 1;
    if (done % 25 === 0) process.stdout.write(`\r  written ${done}/${actionable.length}`);
  }
  process.stdout.write(`\r  written ${done}/${actionable.length}\n`);

  console.log('\n=== applied ===');
  for (const [k, v] of Object.entries(applied)) if (v) console.log(`  ${k.padEnd(9)} ${v}`);
  if (stale) {
    console.log(`\n=== REFUSED, plan went stale under us (${stale}) ===`);
    console.log('  Someone wrote our column while this run was in flight. Nothing was written');
    console.log('  for these; re-run and they will be re-decided against the current values.');
    for (const s of staleRows.slice(0, 25)) {
      console.log(`  property ${String(s.property_id).padStart(5)}  planned ${s.planned}  ${s.name ?? ''}`);
      console.log(`     ${s.detail}`);
    }
    if (staleRows.length > 25) console.log(`  ... +${staleRows.length - 25} more`);
  }

  const after = await sql(`
    select count(*)::int                                          as shadow_rows,
           count(*) filter (where adopted_at is not null)::int     as adopted_ever,
           count(*) filter (where conflict_at is not null)::int    as open_conflicts
      from sync.source_field_shadow
     where source_system = ${lit(FIELD.sourceSystem)} and field_key = ${lit(FIELD.fieldKey)};`);
  console.log(`\n  shadow rows for this field : ${after[0].shadow_rows}`);
  console.log(`  rows ever adopted          : ${after[0].adopted_ever}`);
  console.log(`  open conflicts             : ${after[0].open_conflicts}`);
  console.log(`\n  audit: select * from audit.logs where app_source = '${APP_SOURCE}' order by changed_at desc;`);
})().catch((e) => { console.error('\nFAILED: ' + e.message); process.exit(1); });
