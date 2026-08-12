-- ============================================================================
-- 2026-08-12_1330: backfill gdos.max_frequency_days from the live DERM permit PDFs
-- ============================================================================
-- Fred, 2026-08-12: "you have read the PDF to check the data is correct, then you can
-- do a backfill on the clients in our DB for the GDO's files."
--
-- SOURCE OF EVERY VALUE BELOW: the permit PDF itself, pulled from Miami-Dade DERM
-- (api-ecmrer.miamidade.gov/derm/documents) for each case number and parsed with the
-- GDO bot's own parser (gdo_bot/derm_lookup._parse_frequency), so the audit and the
-- bot cannot disagree about what a PDF says. 130 of our 136 ACTIVE permits were read.
--
-- 🛑 THE PERMIT NUMBER IS STABLE ACROSS RENEWALS, WHICH IS WHY THIS IS SAFE.
-- Fred, 2026-08-12: "a GDO doesn't change their number when renewal, it's just when the
-- address of a place changes." Confirmed against DERM: one case number accumulates one
-- document per renewal year (GDO-06762 has 25 documents, GDO-00951 has 16), all under
-- the same number. The query sorts date_desc and reads document [0], so every value here
-- comes from the MOST RECENT issuance, not a historical one. Verified by listing all
-- documents for six cases and checking the parsed expiry ascends with the document date.
--
-- WHAT IS BEING CHANGED, AND WHAT IS DELIBERATELY NOT
--   13 rows  max_frequency_days IS NULL and the PDF states one -> filled
--    1 row   172-NU GDO-07733: we hold 30, the PDF says 60 -> corrected to 60
--    0 rows  expiration: all 130 readable PDFs AGREE with permit_expiration already
--    0 rows  status: NOT touched. 17 ACTIVE permits are genuinely expired (oldest
--            2018-12-31) and that is a business decision, not a data fix. Leaving them
--            ACTIVE keeps them visible; silently flipping them to INACTIVE would hide a
--            compliance gap behind a tidy-looking table.
--
-- ⚠ 172-NU IS THE ONE TO READ TWICE. We were scheduling every 30 days against a permit
-- that requires every 60. That is OVER-servicing, so no compliance exposure, but the
-- stored number was wrong and the correction makes us pump that client half as often.
-- If 30 days is a deliberate commercial choice rather than a copy of the permit, revert
-- this single row: the permit only sets the MINIMUM frequency, not the maximum.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): public.gdos carries its audit trigger, so all 14
-- writes land in audit.logs with old_row intact and are individually revertible.
-- ============================================================================

do $do$
declare v_active int; v_null_freq int;
begin
  -- pre-state: refuse to run if the population moved under us
  select count(*) into v_active from public.gdos where status='ACTIVE';
  if v_active <> 136 then
    raise exception 'expected 136 ACTIVE permits, found % -- re-run the PDF audit first', v_active;
  end if;
  select count(*) into v_null_freq from public.gdos where status='ACTIVE' and max_frequency_days is null;
  if v_null_freq <> 18 then
    raise exception 'expected 18 ACTIVE permits with no frequency, found %', v_null_freq;
  end if;
end
$do$;

update public.gdos g
   set max_frequency_days = v.freq
  from (values
    (223, 90), (228, 60), (182, 90), (73, 30), (147, 90), (94, 30), (225, 90),
    (200, 60), (28, 30), (27, 90), (104, 90), (224, 90), (226, 90), (227, 90)
  ) as v(id, freq)
 where g.id = v.id
   and g.max_frequency_days is distinct from v.freq;

do $do$
declare
  v_changed int; v_null_after int; v_172 int; v_control int; v_audit int;
begin
  -- (a) all 14 landed
  select count(*) into v_changed from public.gdos g
    join (values (223,90),(228,60),(182,90),(73,30),(147,90),(94,30),(225,90),
                 (200,60),(28,30),(27,90),(104,90),(224,90),(226,90),(227,90)) v(id,freq)
      on v.id = g.id and g.max_frequency_days = v.freq;
  if v_changed <> 14 then raise exception 'only % of 14 rows carry the PDF frequency', v_changed; end if;

  -- (b) the 13 nulls are gone, leaving only the 5 whose PDF was unreadable
  select count(*) into v_null_after from public.gdos where status='ACTIVE' and max_frequency_days is null;
  if v_null_after <> 5 then
    raise exception '% ACTIVE permits still have no frequency, expected 5 (the unreadable PDFs)', v_null_after;
  end if;

  -- (c) the one real correction, named explicitly so a silent no-op cannot pass
  select max_frequency_days into v_172 from public.gdos where id = 200;
  if v_172 <> 60 then raise exception '172-NU GDO-07733 reads % days, expected 60', v_172; end if;

  -- (d) POSITIVE CONTROL. Every check above is satisfied by a table where every row got
  -- set to something. Assert an untouched row still holds its ORIGINAL value: id 2 is
  -- GDO-12517 (110-CLA Claudie), 90 days, confirmed by its PDF and not in the update list.
  select max_frequency_days into v_control from public.gdos where id = 2;
  if v_control <> 90 then
    raise exception 'control row GDO-12517 now reads % -- the update hit rows it should not have', v_control;
  end if;

  -- (e) recoverable
  select count(*) into v_audit from audit.logs
   where table_name='gdos' and operation='UPDATE' and changed_at > now() - interval '5 minutes';
  if v_audit < 14 then raise exception 'only % audit rows captured for 14 updates', v_audit; end if;

  raise notice '14 frequencies set from the live PDFs; 5 remain null (unreadable PDFs); control intact';
end
$do$;
