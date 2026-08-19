-- ============================================================================
-- 2026-08-19  line_items: bring the ONE stale code-27 name back in line with Jobber
-- ============================================================================
-- Fred: "all line item 27 should have the same name which is the one we also have in
-- jobber, if not then rename all the ones that doesn't comply to match it, the real
-- line item 27 is `27 - GDO Online Reporting`."
--
-- Five rows did not carry the canonical name. EACH WAS CHECKED AGAINST JOBBER LIVE
-- BEFORE ANY WRITE, because line_items are Jobber-mastered and a DB-only edit reverts
-- (the documented jobs.frequency_days failure mode). Result:
--
--   our id | document              | ours                  | JOBBER                     | verdict
--   -------|-----------------------|-----------------------|----------------------------|--------
--      93  | job 11101 (111-YC)    | GDO Report            | 27 - GDO Online Reporting  | WE ARE STALE
--    2553  | invoice 2175 PAID     | GDO Report            | GDO Report                 | matches Jobber
--    4616  | invoice 2278 PAID     | GDO Report            | GDO Report                 | matches Jobber
--    5515  | invoice 2438 PAID     | GDO Report (online)   | GDO Report (online)        | matches Jobber
--    5519  | invoice 2439 PAID     | GDO Report (Online)   | GDO Report (Online)        | matches Jobber
--
-- 🛑 SO ONLY id 93 IS RENAMED, AND THE OTHER FOUR ARE DELIBERATELY LEFT ALONE.
-- The instruction is "match the name we have in Jobber". Those four already DO. Renaming
-- them would move us AWAY from Jobber, i.e. break the very rule being asked for, and it
-- would restate four invoices that were already SENT AND PAID - the client received a
-- document reading "GDO Report". If the catalogue name should change on those, the change
-- belongs in JOBBER first, and restating paid invoices is Fred's business call, not a
-- data-hygiene edit. Flagged to him; deliberately not done here.
--
-- WHY id 93 WILL NOT SELF-HEAL, AND WHY THIS EDIT IS THEREFORE SAFE:
-- job 11101 is `archived`, and sync-jobber-job-drift excludes archived/closed/destroyed
-- jobs by design (Fred, 2026-08-03: "leave it, don't extend the reconciler to archived
-- jobs"). So the reconciler will neither fix this row nor fight this edit. On a LIVE job
-- this write would be pointless - the reconciler would own it.
--
-- ⚠ Not a dedupe. The standing rule "never dedupe public.line_items DB-side" is about
-- removing rows the reconciler re-inserts. This changes one text value on a row the
-- reconciler does not touch, to the value Jobber already holds.
--
-- RULE 8 (audit): asserted below rather than assumed.
-- ============================================================================

BEGIN;
SET LOCAL search_path = public, pg_catalog;

-- Pinned to the id AND re-asserting the predicate that made it eligible, so it cannot
-- fire if the world changed between the Jobber read and this write.
UPDATE public.line_items li
   SET name = '27 - GDO Online Reporting'
 WHERE li.id = 93
   AND li.name = 'GDO Report'
   AND li.job_id = 88
   AND EXISTS (SELECT 1 FROM public.jobs j WHERE j.id = li.job_id AND j.job_status = 'archived');

DO $verify$
DECLARE n_renamed int; n_canonical int; n_variants int; n_audit int; v_name text;
BEGIN
  SELECT name INTO v_name FROM public.line_items WHERE id = 93;
  IF v_name <> '27 - GDO Online Reporting' THEN
    RAISE EXCEPTION 'ABORT: id 93 reads %, expected the canonical name', v_name; END IF;

  -- the four Jobber-matching rows must be UNTOUCHED
  SELECT count(*) INTO n_variants FROM public.line_items
   WHERE id IN (2553,4616,5515,5519)
     AND name IN ('GDO Report','GDO Report (online)','GDO Report (Online)');
  IF n_variants <> 4 THEN
    RAISE EXCEPTION 'ABORT: % of the 4 Jobber-matching rows survived unchanged, expected 4', n_variants; END IF;

  -- exactly one row moved into the canonical name
  SELECT count(*) INTO n_canonical FROM public.line_items WHERE name = '27 - GDO Online Reporting';
  IF n_canonical <> 57 THEN
    RAISE EXCEPTION 'ABORT: % canonical rows, expected 57 (56 before + 1)', n_canonical; END IF;

  -- rule 8: is line_items audited? Assert, do not assume.
  SELECT count(*) INTO n_audit
    FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    JOIN pg_proc p ON p.oid=t.tgfoid JOIN pg_namespace pn ON pn.oid=p.pronamespace
   WHERE n.nspname='public' AND c.relname='line_items'
     AND pn.nspname='audit' AND p.proname='log_change' AND NOT t.tgisinternal;
  RAISE NOTICE 'line_items audit triggers: % (0 means this edit is NOT recoverable from audit.logs)', n_audit;

  RAISE NOTICE 'VERIFIED: id 93 renamed, 4 Jobber-matching rows untouched, 57 canonical';
END $verify$;

COMMIT;
