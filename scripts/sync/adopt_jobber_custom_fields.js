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
const ONLY = String(flag('--only', '')).split(',').map((s) => Number(s.trim())).filter(Number.isFinite);
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
  for (const r of rows) {
    r.refusal = r.decision === 'ADOPT' ? adoptionRefusal(FIELD, r.source_now) : null;
    if (r.refusal) r.effective = 'REFUSED'; else r.effective = r.decision;
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
    r.effective !== 'REFUSED' && r.effective !== 'UNKNOWN' &&
    !(r.effective === 'ADOPT' && !adoptIds.has(r.property_id)));

  console.log('\n=== decisions ===');
  for (const d of ['SEED', 'IN_SYNC', 'IGNORE', 'ADOPT', 'CONFLICT', 'REFUSED', 'UNKNOWN']) {
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
  let done = 0, applied = { SEED: 0, IN_SYNC: 0, IGNORE: 0, ADOPT: 0, CONFLICT: 0 };
  for (const r of actionable) {
    const willAdopt = r.effective === 'ADOPT' && adoptIds.has(r.property_id);
    const adoptedTo = willAdopt ? jlit(r.source_now) : 'null::jsonb';
    const out = await sql(`
      do $adopt$
      declare v_decision text;
      begin
        perform set_config('request.headers', ${lit(JSON.stringify({ 'x-app-source': APP_SOURCE }))}, true);
        ${willAdopt ? `update ${FIELD.ourTable}
             set ${FIELD.ourColumn} = ${r.source_now === null ? 'null' : Number(r.source_now)}
           where id = ${r.property_id};` : ''}
        v_decision := sync.fn_record_shadow(
          ${lit(FIELD.entityType)}, ${r.property_id}::bigint, ${lit(FIELD.sourceSystem)},
          ${lit(FIELD.fieldKey)}, ${lit(FIELD.label)},
          ${jlit(r.source_now)}, ${jlit(r.our_now)}, ${adoptedTo});
        if v_decision <> ${lit(r.effective)} then
          raise exception 'decision drifted between the dry run and the write for property %: planned %, got %',
            ${r.property_id}, ${lit(r.effective)}, v_decision;
        end if;
      end
      $adopt$;`);
    applied[r.effective] = (applied[r.effective] || 0) + 1;
    done += 1;
    if (done % 25 === 0) process.stdout.write(`\r  written ${done}/${actionable.length}`);
  }
  process.stdout.write(`\r  written ${done}/${actionable.length}\n`);

  console.log('\n=== applied ===');
  for (const [k, v] of Object.entries(applied)) if (v) console.log(`  ${k.padEnd(9)} ${v}`);

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
