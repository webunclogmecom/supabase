-- ============================================================================
-- 2026-08-19_2340 - Classify the 7 WWTP receipts that were hiding 52 FP cards
-- ============================================================================
-- Fred, 2026-08-19, on https://fp.unclogme.app/087-bb/visit/V5TW5UqaMh:
--   "why when i click on the button `Download report` it doesn't show the WWTP
--    Disposal Receipt ? some times it doesn't shows up the DERM FOG eManifest on
--    some other clients/reports, so sometimes one or the two are missing"
--
-- Two DIFFERENT documents behind one symptom, and they fail for two different
-- reasons. This migration closes the WWTP half. The FOG half is a separate,
-- larger job and is recorded at the bottom so it is not lost.
--
-- THE WWTP GATE. customer.work_orders.wwtp_receipt_url is
--     CASE WHEN rc.class = 'receipt' THEN dm.derm_manifest_url ELSE NULL END
-- joined LEFT JOIN derm.receipt_doc_class rc ON rc.url = dm.derm_manifest_url.
-- So a document with NO ROW in receipt_doc_class is hidden - fail-closed, which is
-- the correct default for a customer-facing document that might carry another
-- client's data. Nothing was broken. The document had simply never been reviewed.
--
-- 🛑 THE REAL DEFECT IS THAT NOTHING EVER REVIEWS THEM. There is no edge function
-- and no cron for receipt_doc_class - grep the functions directory and cron.job and
-- you find redact-manifest-sweep and sheet-number-ocr-sweep, and nothing for this.
-- The "97/97 verified" pass recorded in CLAUDE.md was a ONE-TIME run. Every receipt
-- uploaded since has sat unclassified, so the backlog regrows on its own: 7 documents
-- had accumulated between 2026-08-04 and today, and those 7 were hiding the card on
-- 52 visits. It will regrow again. This migration is the second manual pass, not a fix.
--
-- WHAT WAS DONE. All 7 documents were downloaded and looked at, one by one:
--   5 x Miami-Dade South District WWTP disposal receipts
--   2 x Broward County septage disposal receipts
-- Every one names "Unclogme LLC" as the customer and none shows another client's
-- name, address or manifest data - which is the ONLY question this table answers.
-- They were classified 'receipt' with a note recording the review.
--
-- MEASURED, before -> after:
--   classified documents   118 -> 125
--   FP visits showing WWTP  601 -> 653      (wwtp_missing 67 -> 15)
--   087-BB V5TW5UqaMh                       WWTP now renders (Fred's report)
--
-- The 15 that remain are NOT this problem: 14 visits have no manifest linked at all
-- and 1 has a manifest carrying no document. Those are DERM data gaps for a person
-- (CLAUDE.md "DERM 2-week rule"), not a classification gap.
--
-- IDEMPOTENT: ON CONFLICT DO NOTHING, so re-applying cannot overwrite a later
-- reclassification. Re-running this file is safe and writes nothing.
--
-- AUDIT (rule 8): derm.receipt_doc_class carries no audit trigger and is deliberately
-- NOT opted in - it holds no customer or business data, only a per-URL verdict, and
-- the note column records who decided and why. Consistent with the four audited
-- derm.* tables, which are the ones holding sheet and manifest state.
-- ============================================================================

insert into derm.receipt_doc_class (url, class, note, classified_at)
select v.url, v.class,
       'manual vision review 2026-08-19: verified WWTP/Broward disposal receipt, '
       'customer = Unclogme LLC, no other client data on the document',
       now()
  from (values
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1680/manifest_1.JPG', 'receipt'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1691/manifest_1.JPG', 'receipt'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1698/manifest_1.jpeg', 'receipt'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1700/manifest_1.jpg', 'receipt'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1710/manifest_1.jpg', 'receipt'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1720/manifest_1.jpg', 'receipt'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1725/manifest_1.jpg', 'receipt')
       ) as v(url, class)
on conflict (url) do nothing;

-- ============================================================================
-- VERIFY
-- ============================================================================
do $verify$
declare
  fail text := '';
  v_classified int; v_shown int; v_missing int; v_bagel boolean;
begin
  select count(*) into v_classified from derm.receipt_doc_class where class = 'receipt';

  select count(*) filter (where wwtp_receipt_url is not null),
         count(*) filter (where wwtp_receipt_url is null)
    into v_shown, v_missing
    from customer.work_orders;

  -- 1. the seven URLs this file names must all be classified, or the insert did nothing
  if exists (
    select 1 from derm.receipt_doc_class
     where note like 'manual vision review 2026-08-19%'
    having count(*) <> 7
  ) or not exists (
    select 1 from derm.receipt_doc_class where note like 'manual vision review 2026-08-19%'
  ) then
    fail := fail || 'the 7 reviewed documents are not all present; ';
  end if;

  -- 2. POSITIVE CONTROL, and it is the one that matters: Fred's own visit must now
  --    render the receipt. A count going up proves the insert ran; this proves the
  --    GATE actually opened, which is a different claim.
  select wwtp_receipt_url is not null into v_bagel
    from customer.work_orders where id = 'V5TW5UqaMh';
  if v_bagel is not true then
    fail := fail || 'V5TW5UqaMh (087-BB) still does not show a WWTP receipt; ';
  end if;

  -- 3. NEGATIVE CONTROL: the gate must still HIDE anything unclassified. If every
  --    work order shows a receipt, the CASE has stopped filtering and this file
  --    would have "passed" by breaking the thing it is checking.
  if v_missing = 0 then
    fail := fail || 'no work order is missing a receipt - the fail-closed gate is dead; ';
  end if;

  -- 4. nothing was reclassified away from 'receipt' by this run
  if exists (select 1 from derm.receipt_doc_class
              where note like 'manual vision review 2026-08-19%' and class <> 'receipt') then
    fail := fail || 'a reviewed document is not classified receipt; ';
  end if;

  if fail <> '' then raise exception 'VERIFY FAILED: %', fail; end if;
  raise notice 'receipt_doc_class: % classified; work_orders showing a receipt: %, still hidden: %',
    v_classified, v_shown, v_missing;
end
$verify$;

-- ============================================================================
-- STILL OPEN - the FOG half of Fred's question, measured but NOT fixed here
-- ============================================================================
-- 49 FP visits do not show the DERM FOG eManifest. 14 of them have no manifest
-- linked (same DERM data gap as above). The other 35 have a manifest WITH a
-- document, and are blocked one layer deeper:
--
--   FOG url comes from derm.redacted_manifest_docs, filled by the redact-manifest-sweep
--   cron (*/5, active and healthy). Its queue is EMPTY, because derm.fn_blackout_targets
--   hard-gates on a measured page extent, and these sheets have none.
--
-- Measured, and CONTROLLED against the sheets that do work:
--
--   group            sheets  rows  manual_band  sheets_with_extent
--   WORKING             121   622          534                 119
--   BLOCKED               4    35            0                   0
--
-- The four are ticket-311780, ticket-832487, ticket-833049 (10 visits each, all rows
-- stamped) and ticket-832996 (5 visits, ZERO rows stamped). Not one has a row in
-- derm.page_block_extents or derm.page_row_rules. This is exactly the documented rule
-- in CLAUDE.md: "NEW stamped pages generate NOTHING until a measurement pass adds
-- their extent" - working as designed, and fail-closed again.
--
-- ⇒ THE FIX IS A MEASUREMENT PASS, AND IT IS THE SAME MISSING-AUTOMATION SHAPE AS THE
--   WWTP HALF. Extents are added by hand-written migrations in batches - the last was
--   2026-08-10_1500_blackout_extents_ten_folders.sql, nine days ago. Four sheets have
--   arrived since. 119 of 128 sheets are measured; the 9 that are not are simply the
--   ones that arrived after the last batch.
--
-- 🛑 DO NOT SHORTCUT IT. Three rules from docs/audits/2026-07-10_ocr_band_refinement.md
--   and the 2026-08-03 tightening, all of which cost something to learn:
--     - NEVER derive an extent from derm.v_stamp_row_bands. That view is built
--       WHERE stamp_y_pct IS NOT NULL, so it is blind to a printed-but-UNSTAMPED slot
--       and stops short, serving the rows below it to the customer.
--     - The extent must span every PRINTED slot, empty ones included.
--     - Narrowing is the leak direction; widening only adds black. When unsure, widen.
--   ticket-832996 cannot be measured usefully yet regardless - nothing on it is stamped,
--   so it is a Stamp Studio task first.
-- ============================================================================
