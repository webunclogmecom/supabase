-- ============================================================================
-- 2026-08-18_0120 — make an open CONFLICT actually freeze the row
-- ============================================================================
-- Follow-up to 2026-08-17_1636, which introduced sync.source_field_shadow and the
-- two-way custom-field decision. Found by an adversarial sweep of that migration,
-- confirmed by an independent verifier, and NOT by anything the original file checked.
--
-- 🛑 THE DEFECT. fn_record_shadow freezes on the DECISION being CONFLICT. It never
-- looks at whether the row is ALREADY carrying conflict_at. So the freeze lasted only
-- as long as the decision kept coming back CONFLICT, which is not what "frozen" means:
--
--   1. both sides move          -> CONFLICT, conflict_at set, row frozen, nobody asked yet
--   2. Jobber's value returns to what we last saw
--                               -> decision IGNORE, and the upsert RE-BASELINES our_value
--   3. Jobber then moves again  -> decision ADOPT, and the human's value in
--                                  public.properties is overwritten, while conflict_at
--                                  still says nobody has looked at it
--
-- Step 2 needs no human at all, and for 418 of the 458 live rows the value it returns to
-- is 0, i.e. "somebody typed a number in Jobber and then cleared it" is enough. The
-- migration's own column comment promises the opposite: that a conflicting row is held
-- for a person. The comment was aspirational; the code did not implement it.
--
-- Worse, the release path made the evidence disappear: once a decision came back IN_SYNC
-- the upsert set conflict_at = null, so a conflict could be recorded and then silently
-- self-clear with no human involvement and nothing left in the row to show it happened.
-- conflict_count survives, which is the only reason the history is recoverable at all.
--
-- 🛑 WHY THIS RAISES RATHER THAN RETURNING A VALUE. The caller runs the business-column
-- UPDATE and this function in ONE statement. A return value has to be checked to matter,
-- and the whole class of defect being fixed here is "a check that does not fire". An
-- exception rolls the UPDATE back whether or not the caller remembers to look, so the
-- frozen row cannot be written even by a caller that ignores the result. Fail-closed is
-- the right default for the one branch whose entire purpose is to stop and ask a person.
--
-- The distinctive token CONFLICT_FROZEN is matched by adopt_jobber_custom_fields.js,
-- which reports those rows and moves on instead of aborting the sweep.
--
-- ⚠ IN_SYNC IS STILL THE RELEASE. If the two systems genuinely hold the same value the
-- disagreement is over, so conflict_at clears. That is the only automatic release, and it
-- is deliberately the one case where no judgement is required.
--
-- ⚠ KNOWN GAP, NOT FIXED HERE, DELIBERATELY. A human who resolves a conflict by deciding
-- one side is authoritative WITHOUT making the two numbers equal never trips IN_SYNC, so
-- the row stays frozen forever and now (correctly) refuses to sync. That needs a resolve
-- action with an explicit "keep ours" / "keep theirs" intent, which is new surface and a
-- question for Fred, not something to invent inside a bug-fix migration. Until then the
-- release is a manual UPDATE of the shadow row. Recorded so the next reader does not
-- mistake the freeze for a hang.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): sync.source_field_shadow remains audit opt-OUT, as
-- set in 2026-08-17_1636. It is sync bookkeeping, not human-editable business data, and
-- every adoption it authorises is already captured on public.properties, which IS audited.
-- No trigger is added and none is removed.
--
-- 🛑 THE BODY BELOW IS COPIED FROM pg_get_functiondef, NOT RETYPED. Only the block marked
-- "NEW" is added and the SELECT gains conflict_at. Everything else is byte-identical to
-- what was running. See the 2026-08-06_1316 entry in CLAUDE.md for what retyping costs.
-- ============================================================================

do $do$
begin
  if to_regprocedure('sync.fn_record_shadow(text,bigint,text,text,text,jsonb,jsonb,jsonb)') is null then
    raise exception 'sync.fn_record_shadow is not present; apply 2026-08-17_1636 first';
  end if;
end
$do$;

CREATE OR REPLACE FUNCTION sync.fn_record_shadow(p_entity_type text, p_entity_id bigint, p_source_system text, p_field_key text, p_field_label text, p_source_now jsonb, p_our_now jsonb, p_adopted_to jsonb DEFAULT NULL::jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_exists      boolean;
  v_source_seen jsonb;
  v_our_seen    jsonb;
  v_conflict_at timestamptz;
  v_decision    text;
begin
  select true, s.source_value, s.our_value, s.conflict_at
    into v_exists, v_source_seen, v_our_seen, v_conflict_at
    from sync.source_field_shadow s
   where s.entity_type   = p_entity_type
     and s.entity_id     = p_entity_id
     and s.source_system = p_source_system
     and s.field_key     = p_field_key;

  v_decision := sync.fn_shadow_decision(
    coalesce(v_exists, false), p_source_now, v_source_seen, p_our_now, v_our_seen);

  -- NEW (2026-08-18_0120). A row already flagged for a human is FROZEN, and stays frozen
  -- for every decision except the one that proves the disagreement is over. Without this,
  -- the freeze lasted only while the decision kept returning CONFLICT, and an ordinary
  -- IGNORE was enough to re-baseline the row and re-arm it for a later silent ADOPT.
  if v_conflict_at is not null and v_decision <> 'IN_SYNC' then
    raise exception 'CONFLICT_FROZEN %.% [%]: recorded % and awaiting a person; refusing to % over it',
      p_entity_type, p_entity_id, p_field_key, v_conflict_at, lower(v_decision)
      using errcode = 'P0001';
  end if;

  if v_decision = 'CONFLICT' then
    -- FREEZE. Record the disagreement, re-baseline NOTHING. If this re-baselined,
    -- the conflict would resolve itself on the next pass and no human would ever
    -- be asked about it, which is the failure this whole table exists to avoid.
    update sync.source_field_shadow s
       set conflict_at           = now(),
           conflict_source_value = p_source_now,
           conflict_our_value    = p_our_now,
           conflict_count        = s.conflict_count + 1,
           last_seen_at          = now()
     where s.entity_type   = p_entity_type
       and s.entity_id     = p_entity_id
       and s.source_system = p_source_system
       and s.field_key     = p_field_key;
    return v_decision;
  end if;

  insert into sync.source_field_shadow as s (
    entity_type, entity_id, source_system, field_key, field_label,
    source_value, our_value, first_seen_at, last_seen_at,
    adopted_at, adopted_from, adopted_to)
  values (
    p_entity_type, p_entity_id, p_source_system, p_field_key, p_field_label,
    p_source_now, p_our_now, now(), now(),
    case when p_adopted_to is not null then now() end,
    case when p_adopted_to is not null then p_our_now end,
    p_adopted_to)
  on conflict (entity_type, entity_id, source_system, field_key) do update
     set field_label  = coalesce(excluded.field_label, s.field_label),
         source_value = excluded.source_value,
         -- After an adopt, OUR value is now the adopted one, not what we held a
         -- moment ago. Recording our pre-adopt value here would make the very next
         -- pass see "we changed" and report a phantom conflict.
         our_value    = coalesce(p_adopted_to, excluded.our_value),
         last_seen_at = now(),
         adopted_at   = case when p_adopted_to is not null then now()        else s.adopted_at   end,
         adopted_from = case when p_adopted_to is not null then p_our_now    else s.adopted_from end,
         adopted_to   = case when p_adopted_to is not null then p_adopted_to else s.adopted_to   end,
         -- Sides agree again => release a recorded conflict. conflict_count is kept
         -- as history; only the open flag clears.
         conflict_at  = case when v_decision = 'IN_SYNC' then null else s.conflict_at end;

  return v_decision;
end
$function$;

-- ============================================================================
-- VERIFY — exercise the guard on a sentinel, with the OLD behaviour as the control.
-- Everything below runs on a sentinel key that matches no real property and is deleted
-- before the block ends. It asserts by RAISE, so a failure aborts the whole migration.
-- ============================================================================
do $verify$
declare
  -- entity_type is CHECK-constrained to the real entity vocabulary, so the sentinel cannot
  -- invent its own. Isolation comes from the rest of the PK instead: a NEGATIVE entity_id
  -- (real ids are positive) plus a source_system and field_key nothing else uses.
  k_type text := 'property';
  k_id   bigint := -9721;
  k_sys  text := 'probe_source';
  k_key  text := 'probe://conflict-freeze';
  v_dec  text;
  v_raised boolean;
  v_src jsonb; v_our jsonb; v_cat timestamptz; v_cnt int;
begin
  delete from sync.source_field_shadow
   where entity_type = k_type and entity_id = k_id and source_system = k_sys and field_key = k_key;

  -- 1. seed
  v_dec := sync.fn_record_shadow(k_type, k_id, k_sys, k_key, 'probe', '0'::jsonb, '190'::jsonb);
  if v_dec <> 'SEED' then raise exception 'expected SEED, got %', v_dec; end if;

  -- 2. both sides move => CONFLICT, and the row freezes
  v_dec := sync.fn_record_shadow(k_type, k_id, k_sys, k_key, 'probe', '300'::jsonb, '500'::jsonb);
  if v_dec <> 'CONFLICT' then raise exception 'expected CONFLICT, got %', v_dec; end if;
  select source_value, our_value, conflict_at, conflict_count
    into v_src, v_our, v_cat, v_cnt
    from sync.source_field_shadow
   where entity_type = k_type and entity_id = k_id and source_system = k_sys and field_key = k_key;
  if v_cat is null then raise exception 'conflict_at was not set'; end if;
  if v_src <> '0'::jsonb or v_our <> '190'::jsonb then
    raise exception 'CONFLICT re-baselined the row: source=% our=%', v_src, v_our;
  end if;

  -- 3. THE DEFECT. Jobber returns to what we last saw => IGNORE. On the old body this
  --    re-baselined our_value and re-armed the row. It must now refuse.
  v_raised := false;
  begin
    v_dec := sync.fn_record_shadow(k_type, k_id, k_sys, k_key, 'probe', '0'::jsonb, '500'::jsonb);
  exception when others then
    v_raised := (sqlerrm like 'CONFLICT_FROZEN%');
    if not v_raised then raise exception 'wrong error on a frozen IGNORE: %', sqlerrm; end if;
  end;
  if not v_raised then
    raise exception 'a frozen row accepted an IGNORE and returned % — the freeze does not hold', v_dec;
  end if;

  -- 4. and it must refuse an ADOPT, which is the branch that overwrites a person's value
  v_raised := false;
  begin
    v_dec := sync.fn_record_shadow(k_type, k_id, k_sys, k_key, 'probe', '900'::jsonb, '500'::jsonb, '900'::jsonb);
  exception when others then v_raised := (sqlerrm like 'CONFLICT_FROZEN%');
  end;
  if not v_raised then
    raise exception 'a frozen row accepted an ADOPT and returned % — this is the overwrite', v_dec;
  end if;

  -- 5. nothing in 3 or 4 moved the row
  select source_value, our_value, conflict_count into v_src, v_our, v_cnt
    from sync.source_field_shadow
   where entity_type = k_type and entity_id = k_id and source_system = k_sys and field_key = k_key;
  if v_src <> '0'::jsonb or v_our <> '190'::jsonb then
    raise exception 'the frozen row moved anyway: source=% our=%', v_src, v_our;
  end if;
  if v_cnt <> 1 then raise exception 'conflict_count is %, expected 1 (refusals must not re-count)', v_cnt; end if;

  -- 6. POSITIVE CONTROL: the release still works. Both sides genuinely agree => IN_SYNC,
  --    which is the ONE decision allowed through, and it clears the flag.
  v_dec := sync.fn_record_shadow(k_type, k_id, k_sys, k_key, 'probe', '777'::jsonb, '777'::jsonb);
  if v_dec <> 'IN_SYNC' then raise exception 'expected IN_SYNC to release, got %', v_dec; end if;
  select conflict_at, conflict_count into v_cat, v_cnt
    from sync.source_field_shadow
   where entity_type = k_type and entity_id = k_id and source_system = k_sys and field_key = k_key;
  if v_cat is not null then raise exception 'IN_SYNC did not release the freeze'; end if;
  if v_cnt <> 1 then raise exception 'conflict_count was lost on release: %', v_cnt; end if;

  -- 7. CONTROL THAT THE GUARD IS NOT SIMPLY REFUSING EVERYTHING: an unfrozen row still
  --    adopts normally. Without this, steps 3 and 4 would also pass on a function that
  --    raised unconditionally.
  v_dec := sync.fn_record_shadow(k_type, k_id, k_sys, k_key, 'probe', '800'::jsonb, '777'::jsonb, '800'::jsonb);
  if v_dec <> 'ADOPT' then raise exception 'an unfrozen row failed to ADOPT, got %', v_dec; end if;
  select source_value, our_value into v_src, v_our from sync.source_field_shadow
   where entity_type = k_type and entity_id = k_id and source_system = k_sys and field_key = k_key;
  if v_src <> '800'::jsonb or v_our <> '800'::jsonb then
    raise exception 'ADOPT did not re-baseline: source=% our=%', v_src, v_our;
  end if;

  delete from sync.source_field_shadow
   where entity_type = k_type and entity_id = k_id and source_system = k_sys and field_key = k_key;

  raise notice 'conflict freeze holds against IGNORE and ADOPT, releases on IN_SYNC, and an unfrozen row still adopts';
end
$verify$;

-- The sentinel must be gone, and no live row may have been touched.
select (select count(*) from sync.source_field_shadow where entity_type = 'probe_entity') as sentinel_rows_must_be_0,
       (select count(*) from sync.source_field_shadow)                                    as live_shadow_rows,
       (select count(*) from sync.source_field_shadow where conflict_at is not null)      as open_conflicts,
       (select count(*) from public.properties where grease_trap_size_gallons is not null) as sized_properties,
       (select coalesce(sum(grease_trap_size_gallons),0) from public.properties)          as total_gallons;
