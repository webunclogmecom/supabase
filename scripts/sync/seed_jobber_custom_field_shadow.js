#!/usr/bin/env node
/**
 * SEED sync.source_field_shadow from Jobber. DRY RUN BY DEFAULT.
 *
 * ============================================================================
 * WHAT IT DOES, AND THE ONE THING IT MUST NEVER DO
 * ============================================================================
 * It records what Jobber currently holds for one custom field, per linked
 * property, and what WE hold at the same instant. It ADOPTS NOTHING. It does not
 * touch public.properties. It does not touch a shadow row that already exists.
 *
 * 🛑 FIRST RUN MUST SEED SILENTLY. Fred chose this explicitly on 2026-08-17. With
 * no shadow row yet we record Jobber's current value and change nothing on our
 * side; adoption begins from the NEXT edit. That is what makes the rollout
 * non-destructive, and it is not optional.
 *
 * 🛑 WHY THE WRITE IS A BARE `INSERT ... ON CONFLICT DO NOTHING` AND NOT
 * sync.fn_record_shadow(). fn_record_shadow is the general writer: on an existing
 * row it re-baselines, and on a changed Jobber value it would report ADOPT. Seeding
 * must be incapable of either. A plain guarded INSERT can only ever create a row
 * that was not there, which is a property of the STATEMENT rather than of the
 * caller remembering to pass the right arguments. Do not "unify" the two.
 *
 * ============================================================================
 * THE INSTRUMENT CONTROLS, AND WHY THIS SCRIPT REFUSES TO WRITE WITHOUT THEM
 * ============================================================================
 * Seeding a WRONG baseline is worse than not seeding. If Jobber's answer went
 * missing (waiting room, a renamed field, a dropped selection) every property would
 * look like "no value", we would seed JSON null fleet-wide, and the next real read
 * of 190 would then look like a human edit and ADOPT over our data. So:
 *   - a non-JSON response is a waiting room, never an empty answer (lib gql)
 *   - the target configuration GID must be MATERIALISED on at least --min-coverage
 *     of matched properties (default 90%), or the run aborts before writing
 *   - counts of jobber rows / our rows / matched are printed, and a zero in any of
 *     them is called BROKEN rather than reported as a clean result
 * A sweep returning 0 with no positive control is an untested instrument.
 *
 * ============================================================================
 * USAGE
 *   node scripts/sync/seed_jobber_custom_field_shadow.js               # dry run
 *   node scripts/sync/seed_jobber_custom_field_shadow.js --apply       # writes
 *   optional: --field grease_trap_size  --page 25  --min-coverage 0.9  --json out.json
 * ============================================================================
 */
const fs = require('fs');
const {
  fieldById, sql, lit, jlit, fetchJobberProperties, loadOurProperties,
} = require('./jobber_custom_fields');

const argv = process.argv.slice(2);
const flag = (name, dflt) => { const i = argv.indexOf(name); return i > -1 ? argv[i + 1] : dflt; };
const APPLY = argv.includes('--apply');
const FIELD = fieldById(flag('--field', 'grease_trap_size'));
const PAGE = Number(flag('--page', 25));
const MIN_COVERAGE = Number(flag('--min-coverage', 0.9));
const JSON_OUT = flag('--json', null);

(async () => {
  console.log(`SEED sync.source_field_shadow  [${APPLY ? 'APPLY' : 'DRY RUN (default)'}]`);
  console.log(`  field     : ${FIELD.label}  (${FIELD.kind})`);
  console.log(`  field_key : ${FIELD.fieldKey}`);
  console.log(`  our column: ${FIELD.ourTable}.${FIELD.ourColumn}\n`);

  const ours = await loadOurProperties(FIELD);
  console.log(`  our side  : ${ours.length} properties with a real Jobber Property link`);
  const alreadySeeded = ours.filter((r) => r.shadow_exists).length;
  console.log(`  already shadowed: ${alreadySeeded}`);

  const { properties: jobber, total } = await fetchJobberProperties({ pageSize: PAGE });

  // ------------------------------------------------------------------ classify
  // 🛑 MEASURE THE INSTRUMENT ON EVERY ROW, THEN SKIP THE WORK. The already-seeded rows used
  // to be `continue`d BEFORE the GID join was attempted and were then subtracted out of
  // `matched`, which made the control a WORK-QUEUE SIZE wearing the label of an instrument
  // check. The healthier the system, the more broken it claimed to be: at steady state
  // (458 of 459 shadowed) it printed "matched by GID: 0 <-- BROKEN" and `--apply` threw
  // "a control came back zero, so the instrument is untested" on a system with nothing wrong
  // with it. A control must answer "does the join work", never "how much is left to do".
  const toSeed = [], unresolved = [], notMaterialised = [], skipped = [];
  let matchedAll = 0, materialisedAll = 0;
  for (const r of ours) {
    const j = jobber.get(r.gid);
    if (!j) { unresolved.push({ property_id: r.property_id, name: r.property_name, gid: r.gid }); continue; }
    matchedAll += 1;
    const cf = j.byConfig.get(FIELD.fieldKey);
    if (cf) materialisedAll += 1;
    if (r.shadow_exists) { skipped.push(r.property_id); continue; }
    if (!cf) notMaterialised.push(r.property_id);
    const sourceNow = cf ? cf.value : null;
    const ourNow = r.our_value === null || r.our_value === undefined ? null : Number(r.our_value);
    toSeed.push({
      property_id: r.property_id,
      name: r.property_name,
      source_now: sourceNow,
      our_now: ourNow,
      materialised: !!cf,
    });
  }

  // -------------------------------------------------------------- the controls
  // Fleet-wide, so they mean the same thing on run 1 and on run 100.
  const matched = matchedAll;
  const consideredForCoverage = matchedAll;
  const materialised = materialisedAll;
  const coverage = consideredForCoverage ? materialised / consideredForCoverage : 0;
  // Kept separate and reported, because "how much is left" is still worth seeing; it is
  // just not evidence about the instrument.
  const pending = toSeed.length;

  console.log('\n=== controls ===');
  console.log(`  jobber properties fetched : ${jobber.size} of ${total} ${jobber.size > 0 ? '(fetch works)' : '<-- BROKEN'}`);
  console.log(`  our rows loaded           : ${ours.length} ${ours.length > 0 ? '(db read works)' : '<-- BROKEN'}`);
  console.log(`  matched by GID            : ${matched} ${matched > 0 ? '(the join works)' : '<-- BROKEN, every row would look unresolved'}`);
  console.log(`  field materialised on     : ${materialised}/${consideredForCoverage} = ${(coverage * 100).toFixed(1)}%  (threshold ${(MIN_COVERAGE * 100).toFixed(0)}%)`);
  console.log(`  still to seed             : ${pending}  (work remaining, NOT a control)`);
  if (notMaterialised.length) {
    console.log(`  ⚠ ${notMaterialised.length} matched properties returned NO row for this configuration GID`);
  }

  // --------------------------------------------------------------- the numbers
  const zeros = toSeed.filter((r) => r.source_now === 0).length;
  const nulls = toSeed.filter((r) => r.source_now === null).length;
  const nonZero = toSeed.filter((r) => typeof r.source_now === 'number' && r.source_now !== 0).length;
  const weHold = toSeed.filter((r) => r.our_now !== null).length;
  const latentDivergence = toSeed.filter((r) => (r.source_now ?? null) !== (r.our_now ?? null));
  const wouldHaveBeenZeroed = toSeed.filter((r) => r.source_now === 0 && r.our_now !== null && r.our_now !== 0);
  const gallonsAtRisk = wouldHaveBeenZeroed.reduce((a, r) => a + (r.our_now || 0), 0);
  // A naive copy also overwrites where Jobber holds a non-zero that differs from ours.
  const wouldOverwrite = toSeed.filter((r) => typeof r.source_now === 'number' && r.source_now !== 0
    && r.our_now !== null && r.our_now !== r.source_now);
  const wouldGain = toSeed.filter((r) => typeof r.source_now === 'number' && r.source_now !== 0 && r.our_now === null);
  // Locale-independent: toLocaleString() renders 47732 as "47.732" under some system
  // locales, which reads as a decimal and makes the number look 1000x smaller.
  const grp = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',');

  console.log('\n=== what it would WRITE (shadow rows only, nothing adopted) ===');
  console.log(`  shadow rows to CREATE     : ${toSeed.length}`);
  console.log(`  properties unresolved     : ${unresolved.length}  (no matching Jobber property)`);
  console.log(`  skipped, already shadowed : ${skipped.length}`);
  console.log('\n  jobber value distribution among the rows to create:');
  console.log(`    reads 0                 : ${zeros}`);
  console.log(`    reads a non-zero number : ${nonZero}`);
  console.log(`    no value at all         : ${nulls}`);
  console.log(`    we hold a value         : ${weHold}`);

  console.log('\n=== the thing seeding deliberately does NOT fix ===');
  console.log(`  sides already disagree    : ${latentDivergence.length}`);
  console.log('  These stay as they are. Seeding records the disagreement as the baseline, so');
  console.log('  nothing is adopted until someone edits one side. That is the point.');
  console.log('\n=== what a NAIVE straight copy would have done instead (do not build it) ===');
  console.log(`  properties ZEROED (jobber 0, we hold a capacity) : ${wouldHaveBeenZeroed.length}`);
  console.log(`  gallons destroyed                               : ${grp(gallonsAtRisk)}`);
  console.log(`  properties OVERWRITTEN (both non-zero, differ)   : ${wouldOverwrite.length}` +
    `  (${wouldOverwrite.filter((r) => r.source_now < r.our_now).length} downward)`);
  console.log(`  properties GAINED a value (we hold none)         : ${wouldGain.length}`);
  for (const r of wouldHaveBeenZeroed.slice(0, 8)) {
    console.log(`     property ${String(r.property_id).padStart(5)}  jobber 0  vs  ours ${r.our_now}   ${r.name ?? ''}`);
  }
  if (wouldHaveBeenZeroed.length > 8) console.log(`     ... +${wouldHaveBeenZeroed.length - 8} more`);

  if (unresolved.length) {
    console.log('\n  unresolved (first 8):');
    for (const u of unresolved.slice(0, 8)) console.log(`     property ${u.property_id}  ${u.gid}  ${u.name ?? ''}`);
    if (unresolved.length > 8) console.log(`     ... +${unresolved.length - 8} more`);
  }

  if (JSON_OUT) {
    fs.writeFileSync(JSON_OUT, JSON.stringify({
      field: FIELD, toSeed, unresolved, notMaterialised, skipped,
      controls: { jobberFetched: jobber.size, jobberTotal: total, ourRows: ours.length, matched, materialised, coverage },
    }, null, 1));
    console.log(`\nfull detail -> ${JSON_OUT}`);
  }

  // ------------------------------------------------------------------- gating
  if (!APPLY) {
    console.log('\nDRY RUN. Nothing was written. Re-run with --apply to create the shadow rows.');
    return;
  }
  if (jobber.size === 0 || ours.length === 0 || matched === 0) {
    throw new Error('refusing to write: a control came back zero, so the instrument is untested');
  }
  if (consideredForCoverage > 0 && coverage < MIN_COVERAGE) {
    throw new Error(
      `refusing to write: the target configuration GID is materialised on only ${(coverage * 100).toFixed(1)}% ` +
      `of matched properties (threshold ${(MIN_COVERAGE * 100).toFixed(0)}%). Seeding a fleet of empty baselines ` +
      'would make the next real read look like a human edit and adopt over our data. Check the field GID and ' +
      'the customFields selection before forcing this.');
  }
  if (toSeed.length === 0) {
    console.log('\nNothing to seed. Every linked property already carries a shadow row.');
    return;
  }


  // -------------------------------------------------------------------- write
  // Guarded INSERT only. It is structurally incapable of adopting or of altering an
  // existing baseline: ON CONFLICT DO NOTHING, and no write to public.properties.
  const BATCH = 200;
  let created = 0;
  for (let i = 0; i < toSeed.length; i += BATCH) {
    const chunk = toSeed.slice(i, i + BATCH);
    const values = chunk.map((r) =>
      `(${lit(FIELD.entityType)}, ${r.property_id}::bigint, ${lit(FIELD.sourceSystem)}, ` +
      `${lit(FIELD.fieldKey)}, ${lit(FIELD.label)}, ${jlit(r.source_now)}, ${jlit(r.our_now)})`).join(',\n      ');
    const rows = await sql(`
      with ins as (
        insert into sync.source_field_shadow
          (entity_type, entity_id, source_system, field_key, field_label, source_value, our_value)
        values
      ${values}
        on conflict (entity_type, entity_id, source_system, field_key) do nothing
        returning 1)
      select count(*)::int as created from ins;`);
    created += rows[0].created;
    process.stdout.write(`\r  seeded ${created}/${toSeed.length}`);
  }
  process.stdout.write('\n');

  // Verify from the far side rather than trusting the return count.
  const after = await sql(`
    select count(*)::int                                as shadow_rows,
           count(*) filter (where adopted_at is not null)::int  as adopted,
           count(*) filter (where conflict_at is not null)::int as conflicts
      from sync.source_field_shadow
     where source_system = ${lit(FIELD.sourceSystem)} and field_key = ${lit(FIELD.fieldKey)};`);
  console.log(`\n=== after ===`);
  console.log(`  shadow rows for this field : ${after[0].shadow_rows}`);
  console.log(`  adopted_at set             : ${after[0].adopted} ${after[0].adopted === 0 ? '(correct: seeding adopts nothing)' : '<-- WRONG, seeding must adopt nothing'}`);
  console.log(`  conflicts recorded         : ${after[0].conflicts}`);
  if (after[0].adopted !== 0) throw new Error('seeding set adopted_at; that is a bug, investigate before running adoption');
})().catch((e) => { console.error('\nFAILED: ' + e.message); process.exit(1); });
