-- 2026-09-02_1700_repair_lock_box_cleared_shadow_encoding.sql
--
-- Repair the 18 lock-box shadow rows written by the N/A clear, which recorded JSON null where
-- Jobber actually reports the empty string.
--
-- Fred asked to push the 18 "N/A" placeholders to Jobber as blank. The clear itself worked and was
-- verified by read-back on all 18. The BOOKKEEPING was wrong, in a way that writes no bad data but
-- would never settle.
--
-- ============================================================================
-- THE DEFECT: NORMALISING IS CORRECT FOR COMPARING AND WRONG FOR RECORDING
-- ============================================================================
-- A cleared Jobber TEXT custom field reports `valueText: ""`, NOT null. Two different readers of
-- the same bytes disagreed about that, and both were "right" for their own purpose:
--
--   push_custom_field_to_jobber.js   read() maps '' -> null   (fine for comparison)
--   custom_field_freeze_audit.js     read() keeps ''          (fine for reporting)
--   webhook-jobber handleProperty    read: (n) => n.valueText (RAW - this is the one that matters)
--
-- The push recorded the shadow from its own NORMALISED read, so source_value became JSON null while
-- the inbound handler will pass JSON "". Those are distinct jsonb values, so fn_shadow_decision sees
-- the source as having moved on every single poll:
--
--   fn_shadow_decision(true, '""', 'null', 'null', 'null')  ->  ADOPT
--
-- It then hits the clear guard and returns 'REFUSED:would clear (empty)', which writes nothing and
-- deliberately records no shadow - so the row is re-offered forever. No data is harmed and nothing
-- is frozen; the cost is 18 rows that are re-offered on every poll and 18 permanent entries in the
-- freeze audit's drift list, which is exactly the kind of standing noise that trains people to
-- ignore a real signal later.
--
-- ⇒ THE SHADOW MUST HOLD WHAT THE SOURCE ACTUALLY REPORTS, byte for byte, because its entire job is
-- an identity comparison against the next reading. Store the RAW value; normalise only when
-- comparing. Same family as "a normalising DECODE hides the difference".
--
-- After this migration: source_value = '""' matches what Jobber reports, our_value stays JSON null
-- matching our NULL column, and the decision becomes IGNORE - "the source did not move, so this is
-- not an edit". NOT IN_SYNC: that branch requires the two sides to hold the SAME value, and '""'
-- is not NULL. See the long note in the VERIFY block; asserting IN_SYNC here failed 0-of-18.
--
-- Scope is exactly the 18 properties cleared at ~16:00 ET on 2026-09-02, pinned to rows that still
-- hold the wrong encoding AND whose column is still NULL, so a re-run is a no-op and a property
-- where somebody has since typed a real code is left alone.

begin;

update sync.source_field_shadow s
   set source_value = '""'::jsonb,
       our_value    = 'null'::jsonb,
       -- the table has no updated_at; last_seen_at is its "when did we look" column
       last_seen_at = now()
  from public.properties p
 where p.id = s.entity_id
   and s.entity_type = 'property'
   and s.source_system = 'jobber'
   and s.field_key = 'gid://Jobber/CustomFieldConfigurationText/3061112'
   and s.entity_id in (4,24,25,29,40,42,51,60,90,107,121,122,137,143,161,165,168,181)
   and jsonb_typeof(s.source_value) = 'null'   -- only the mis-encoded ones
   and p.lock_box_key is null                  -- and only while we still hold nothing
   and s.conflict_at is null;

do $verify$
declare
  v_wrong integer;
  v_sync  integer;
  v_ctrl  text;
begin
  -- every targeted row now encodes empty the way Jobber reports it
  select count(*) into v_wrong
    from sync.source_field_shadow
   where field_key = 'gid://Jobber/CustomFieldConfigurationText/3061112'
     and entity_id in (4,24,25,29,40,42,51,60,90,107,121,122,137,143,161,165,168,181)
     and source_value <> '""'::jsonb;
  if v_wrong <> 0 then
    raise exception 'VERIFY FAILED: % of the 18 rows are still not encoded as the empty string', v_wrong;
  end if;

  -- The decision the LIVE inbound path will make is now IGNORE for all 18.
  -- '""' is what webhook-jobber's raw read passes for a cleared field; that is the whole point.
  --
  -- ⚠ IGNORE, NOT IN_SYNC, and the difference is the whole shape of this function. Reading it
  -- rather than guessing at it is what settled this - the first version of this assertion demanded
  -- IN_SYNC, failed 0-of-18, and rolled the migration back:
  --     IN_SYNC  <=  p_source_now IS NOT DISTINCT FROM p_our_now   (both hold the SAME value)
  --     IGNORE   <=  p_source_now IS NOT DISTINCT FROM p_source_seen (the SOURCE did not move)
  -- Jobber holds '""' and our column holds NULL, so the two sides do NOT hold the same value and
  -- IN_SYNC is unreachable here by construction. IGNORE is the correct resting state, and it is
  -- the same branch the function's own comment says "protects the 69 never-touched zeros":
  -- nothing moved, so nothing is an edit. That is exactly what we want - permanently quiet.
  select count(*) into v_sync
    from sync.source_field_shadow s
    join public.properties p on p.id = s.entity_id
   where s.field_key = 'gid://Jobber/CustomFieldConfigurationText/3061112'
     and s.entity_id in (4,24,25,29,40,42,51,60,90,107,121,122,137,143,161,165,168,181)
     and sync.fn_shadow_decision(true, '""'::jsonb, s.source_value,
           coalesce(to_jsonb(p.lock_box_key), 'null'::jsonb), s.our_value) = 'IGNORE';
  if v_sync <> 18 then
    raise exception 'VERIFY FAILED: only % of 18 rows decide IGNORE against a cleared Jobber field', v_sync;
  end if;

  -- POSITIVE CONTROL. The assertion above must be capable of FAILING, or it proves nothing: a
  -- decision function that returned IGNORE unconditionally would satisfy it. Feed a value that IS
  -- genuinely a Jobber-side edit and require ADOPT - i.e. prove the instrument can still see a real
  -- change on a row we just quietened.
  select sync.fn_shadow_decision(true, to_jsonb('ZZ-NEW'::text), '""'::jsonb, 'null'::jsonb, 'null'::jsonb)
    into v_ctrl;
  if v_ctrl <> 'ADOPT' then
    raise exception 'POSITIVE CONTROL FAILED: a real Jobber-side edit on a cleared row scored %, not '
                    'ADOPT, so the IGNORE count above is vacuous', v_ctrl;
  end if;

  raise notice 'VERIFY OK: 18 rows encode empty as the empty string, all 18 decide IGNORE, and a real edit still ADOPTs (%)', v_ctrl;
end
$verify$;

commit;
