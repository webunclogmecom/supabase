-- 2026-08-21_1830_clear_out_of_area_county.sql
--
-- WHAT: clears the literal string 'None' from public.properties.county on 3 rows, leaving NULL.
--
-- WHY:  the county field is becoming a DROPDOWN in the Client App and the Visit Calendar (Fred,
--       2026-08-21: "we need to make it a dropdown of the list we have of the counties, not a text
--       field, that is for the client app and the calendar app too"). The options are the three
--       counties we actually serve: Dade, Broward, Palm Beach.
--       'None' is NOT junk. It marks a property outside the service area, and two of the three are
--       SERVICE properties, not billing addresses:
--           234  Levis, Quebec        is_billing = false
--           377  Manhattan Beach, CA  is_billing = false
--           392  Cedarhurst, NY       is_billing = true
--       Fred's call (asked explicitly, 2026-08-21): three counties plus blank, and clear these three
--       so nothing is left holding a value the dropdown cannot display. The accepted cost, stated so
--       nobody is surprised later: we LOSE the distinction between "outside our service area" and
--       "nobody has filled this in yet". Both now read blank. 20 rows were already blank.
--
-- ⚠ IT IS 'Dade', NOT 'Miami-Dade'. public.properties.county uses `Dade` (748 rows) and so does
--    public.municipality_regulators and webhook-jobber's inferCountyFromCity. `Miami-Dade` is a
--    DIFFERENT vocabulary living in public.disposal_facilities. A dropdown built from the wrong one
--    would stop matching 748 rows. Same two-vocabulary trap as service_type / service_kind.
--
-- ⚠ inferCountyFromCity can only ever return 'Dade' or 'Broward'. Palm Beach is NEVER auto-filled,
--    which is why several blank rows are Delray Beach, Jupiter and West Palm Beach. The dropdown is
--    the only way those get set.
--
-- AUDIT (rule 8): public.properties carries the audit_properties trigger, so each UPDATE is captured
--    with old_row, and 'None' is recoverable from audit.logs without a separate backup file.
--    Confirmed present in the VERIFY below rather than assumed.

begin;

-- pinned to the primary keys AND re-asserting the predicate that made them eligible, so this cannot
-- fire if the world changed between the read and this write.
update public.properties
   set county = null
 where id in (234, 377, 392)
   and county = 'None';

-- ---- VERIFY -------------------------------------------------------------------------------------
do $verify$
declare v_none int; v_target int; v_audited int; v_dade int;
begin
  select count(*) into v_audited from pg_trigger
   where tgrelid = 'public.properties'::regclass and tgname = 'audit_properties' and not tgisinternal;
  if v_audited <> 1 then raise exception 'VERIFY: audit_properties trigger missing, the old value would be unrecoverable'; end if;

  select count(*) into v_none from public.properties where county = 'None';
  if v_none <> 0 then raise exception 'VERIFY: % rows still read None', v_none; end if;

  select count(*) into v_target from public.properties where id in (234, 377, 392) and county is null;
  if v_target <> 3 then raise exception 'VERIFY: expected 3 cleared rows, got %', v_target; end if;

  -- 🛑 CONTROL. A statement that cleared EVERY county would satisfy both checks above. Assert the
  --    fleet is untouched: Dade must still be 748.
  select count(*) into v_dade from public.properties where county = 'Dade' and deleted_at is null;
  if v_dade <> 748 then raise exception 'VERIFY: Dade count moved to % (expected 748) - this migration must touch only 3 rows', v_dade; end if;

  raise notice 'VERIFY ok: 3 out-of-area rows cleared, Dade still 748, audit trigger intact';
end $verify$;

commit;
