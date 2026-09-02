-- 2026-09-02_1200_repair_lock_box_shadow_our_value.sql
--
-- WHY. Fred asked for the junk value "test" to be cleared on property 100 in Jobber. Doing
-- that fired a CONFLICT on the very first property whose Jobber value moved, and the
-- conflict was not caused by the edit: it was armed by MY import an hour earlier.
--
-- sync.source_field_shadow.our_value is "what we last saw on OUR side".
-- scripts/sync/import_jobber_lock_box_key.js called sync.fn_record_shadow with our_now =
-- JSON null, copying the shape the sync function uses, where that argument is the PRE-adopt
-- value and the substitution to the post-adopt value happens inside. For this call shape it
-- did not substitute, so 27 of the 28 rows record "we hold nothing" while the column holds a
-- real code.
--
-- WHY THAT IS A LATENT FREEZE, not cosmetic. fn_shadow_decision reads our_live vs our_seen
-- to decide whether OUR side moved. With our_seen = null and our_live = '5713' it concludes a
-- human just typed it; combine that with any Jobber-side change and the verdict is CONFLICT,
-- which sets conflict_at and FREEZES the row for ever ("frozen rows are a human's business").
-- So all 27 would have frozen on the first Jobber edit - precisely the event this field exists
-- to carry. Measured on property 100 the moment Jobber went "test" -> "": conflict_count 1,
-- conflict_our_value "test", conflict_source_value "", and the next decision returns FROZEN.
--
-- THE CONTROL THAT MAKES THIS A DEFECT AND NOT A STYLE CHOICE, two ways:
--   * property 32 went through a REAL adopt (the poll replay at 09:54) and its our_value is
--     correctly '5713'. Same table, same field, right answer - so the machinery is fine and
--     the import was the outlier. It is the 1 of 28 that agrees with its column.
--   * the grease trap field has 370 of 475 rows at JSON null and those are CORRECT: 353 of 458
--     properties genuinely hold no capacity. A blanket "null is wrong" sweep would have been
--     wrong. The test is our_value DISAGREEING WITH THE COLUMN, never null on its own.
--
-- PART 1 repairs the 27. PART 2 finishes Fred's actual request on property 100.
--
-- Rule 8: no schema change. sync.source_field_shadow is deliberately unaudited (it IS the
-- provenance record); public.properties is audited and PART 2's write is captured there.

-- PART 1. Tell the truth about what we hold. Pinned to the exact defect (column has a value,
-- shadow says we hold nothing) so a legitimately-null row is never touched.
update sync.source_field_shadow s
   set our_value = to_jsonb(p.lock_box_key)
  from public.properties p
 where p.id = s.entity_id
   and s.field_key = 'gid://Jobber/CustomFieldConfigurationText/3061112'
   and s.our_value = 'null'::jsonb
   and p.lock_box_key is not null;

-- PART 2. Property 100 (040-MV Maison Valentine). Jobber's value was the string "test" and
-- Fred asked for it gone; it was cleared in Jobber at 14:00 and the read-back confirms "".
-- Our column still held "test", and the poll will NEVER clear it on its own: p_allow_clear is
-- false from the poll by design, because a clearing adopt is the most destructive write this
-- sync can make. So the clear on our side is a deliberate act, here, and the shadow is set to
-- the state both sides now agree on.
update public.properties set lock_box_key = null where id = 100 and lock_box_key = 'test';

update sync.source_field_shadow
   set source_value = to_jsonb(''::text),
       our_value    = 'null'::jsonb,
       conflict_at  = null,
       conflict_source_value = null,
       conflict_our_value    = null
 where entity_id = 100
   and field_key = 'gid://Jobber/CustomFieldConfigurationText/3061112';

DO $verify$
DECLARE fails text := ''; r text; n integer;
BEGIN
  -- 1. no row claims we hold nothing while the column holds something
  SELECT count(*) INTO n
    FROM sync.source_field_shadow s JOIN public.properties p ON p.id = s.entity_id
   WHERE s.field_key='gid://Jobber/CustomFieldConfigurationText/3061112'
     AND p.lock_box_key IS NOT NULL
     AND s.our_value #>> '{}' IS DISTINCT FROM p.lock_box_key;
  IF n <> 0 THEN fails := fails || format('1: %s shadow rows still disagree with their column; ', n); END IF;

  -- 2. CONTROL: the grease trap field was NOT touched. 370 of its rows are legitimately
  --    JSON null and a sweep that "fixed" those would be the real damage.
  SELECT count(*) INTO n FROM sync.source_field_shadow
   WHERE field_key='gid://Jobber/CustomFieldConfigurationNumeric/3061111' AND our_value = 'null'::jsonb;
  IF n <> 370 THEN fails := fails || format('2: CONTROL moved, grease-trap json-null rows are %s, expected 370; ', n); END IF;

  -- 3. property 100 is clear on our side
  IF (SELECT lock_box_key FROM public.properties WHERE id=100) IS NOT NULL THEN
    fails := fails || '3: property 100 still holds a lock box value; ';
  END IF;

  -- 4. and is no longer frozen: the next poll must return a benign verdict, not FROZEN.
  --    Exercised against the real function rather than reasoned about.
  BEGIN
    r := public.fn_sync_property_custom_field(
           100, 'gid://Jobber/CustomFieldConfigurationText/3061112', 'Lock Box/Key',
           to_jsonb(''::text), true);
    IF r IN ('FROZEN','CONFLICT') THEN
      fails := fails || format('4: property 100 still decides %s; ', r);
    END IF;
  EXCEPTION WHEN others THEN
    fails := fails || format('4: the decision probe raised %s; ', SQLERRM);
  END;

  -- 5. the 28th value is gone and the rest survive
  SELECT count(*) INTO n FROM public.properties WHERE lock_box_key IS NOT NULL;
  IF n <> 27 THEN fails := fails || format('5: %s properties hold a lock box, expected 27; ', n); END IF;

  IF fails <> '' THEN RAISE EXCEPTION 'VERIFY FAILED >>> %', fails; END IF;
  RAISE NOTICE 'VERIFY OK';
END $verify$;
