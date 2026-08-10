-- ============================================================================
-- 2026-08-10_1212: pad the 20 unpadded legacy access-hours values
-- ============================================================================
-- Step 2a of finishing the access-hours migration (Fred: "Do an audit for the access
-- hours migration, and finish it"). Step 1 was the backfill, 2026-08-07_1649.
--
-- WHY THIS EXISTS, AND IT IS NOT COSMETIC.
-- The end state is that the four `ops` views stop reading
-- public.properties.access_hours_start/_end/access_days directly and DERIVE them from
-- access_schedule instead, so the three base columns can be dropped without any app
-- changing. That switch is only safe if the derived value equals the stored value
-- everywhere, otherwise it silently moves what a live screen shows.
--
-- Measured across the 198 properties that carry a schedule:
--     access_hours_start : 191 of 198 already match the derivation
--     access_hours_end   : 179 of 198 already match
-- and **every single mismatch is the same thing**: an unpadded hour. `1:00` stored
-- against `01:00` derived, `6:00` against `06:00`. Those are the 20 rows the backfill
-- padded on the way INTO access_schedule, because the legacy columns are plain `text`
-- and were never validated while access_schedule IS validated as HH:MM by
-- client.update_property_operational.
--
-- ⇒ Padding the stored side makes stored == derived for hours on all 198, which turns
--   the later view switch into a provable no-op instead of a hopeful one.
--
-- 🛑 TWO PROPERTIES WILL STILL DIFFER AFTER THIS, ON DAYS, AND THAT IS DELIBERATE.
-- Property 6 (178-LG, 3 live visits) and 493 (112-YA, the test account) hold hours with
-- access_days NULL. The backfill wrote all seven days into their schedule, on the rule
-- that hours with no recorded day restriction mean "these hours, any day". So deriving
-- access_days from the schedule would give them 7 days where NULL is stored, and the
-- Visit Calendar omits its day strip entirely when access_days is NULL. That is a
-- VISIBLE change on 3 real visits and it is NOT made here. It is called out in the
-- migration that performs the switch, so it is a decision rather than a side effect.
--
-- SAFETY
-- - Formatting only. `01:00` and `1:00` are the same time. No window moves.
-- - Independently correct regardless of the migration: the column is meant to hold HH:MM,
--   and 23 of 201 populated rows failed a strict check before the backfill.
-- - public.properties is audited, so all 20 writes carry old_row and are revertible.
-- - The hourly Jobber property poll writes address/city/state/zip/name/client_id/lat/lng
--   and touches no access column, so it cannot undo this.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table added or renamed, no trigger changed.
-- ============================================================================

update public.properties
   set access_hours_start = case when access_hours_start ~ '^[0-9]:[0-5][0-9]$'
                                 then '0' || access_hours_start else access_hours_start end,
       access_hours_end   = case when access_hours_end   ~ '^[0-9]:[0-5][0-9]$'
                                 then '0' || access_hours_end   else access_hours_end   end
 where access_hours_start ~ '^[0-9]:[0-5][0-9]$'
    or access_hours_end   ~ '^[0-9]:[0-5][0-9]$';

do $$
declare
  v_unpadded int;
  v_bad_fmt  int;
  v_start_mismatch int;
  v_end_mismatch   int;
  v_control  int;
begin
  select count(*) into v_unpadded from public.properties
   where access_hours_start ~ '^[0-9]:' or access_hours_end ~ '^[0-9]:';
  if v_unpadded <> 0 then raise exception '% rows still unpadded', v_unpadded; end if;

  -- everything populated must now be a strict HH:MM
  select count(*) into v_bad_fmt from public.properties
   where (access_hours_start is not null and access_hours_start !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$')
      or (access_hours_end   is not null and access_hours_end   !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$');
  if v_bad_fmt <> 0 then
    raise exception '% rows still hold a non HH:MM value', v_bad_fmt;
  end if;

  -- THE POINT OF THE EXERCISE: stored must now equal derived, for hours, on every row
  -- that carries a schedule. This is the precondition the view switch depends on.
  select count(*) into v_start_mismatch from public.properties p
   where p.access_schedule is not null
     and p.access_hours_start is distinct from
         (select s.k from (select e.value->>'open' k, count(*) n from jsonb_each(p.access_schedule) e
                            group by 1 order by n desc, 1 limit 1) s);
  select count(*) into v_end_mismatch from public.properties p
   where p.access_schedule is not null
     and p.access_hours_end is distinct from
         (select s.k from (select e.value->>'close' k, count(*) n from jsonb_each(p.access_schedule) e
                            group by 1 order by n desc, 1 limit 1) s);
  if v_start_mismatch <> 0 or v_end_mismatch <> 0 then
    raise exception 'stored still differs from derived: % start, % end', v_start_mismatch, v_end_mismatch;
  end if;

  -- CONTROL: the 198 rows must still BE there. A migration that emptied the column
  -- would satisfy every check above, since NULL is not unpadded and not badly formatted.
  select count(*) into v_control from public.properties where access_hours_start is not null;
  if v_control <> 198 then
    raise exception 'expected 198 populated rows, found % -- data was lost', v_control;
  end if;

  raise notice 'padded; stored now equals derived for hours on all 198 rows, 198 still populated';
end
$$;
