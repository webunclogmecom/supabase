-- 2026-08-26_1710_classify_four_wwtp_receipts.sql
--
-- WHY
-- ---
-- Fred, 2026-08-26: "fix the lag now." One of the things making the FP Service Report
-- incomplete right after a dump is the WWTP receipt gate: customer.work_orders.wwtp_receipt_url
-- serves the disposal receipt ONLY when its URL is classified 'receipt' in
-- derm.receipt_doc_class (2026-07-10_wwtp_receipt_class_gate.sql). New uploads stay hidden
-- until a classification pass adds them, and nothing runs that pass on a schedule.
--
-- This clears the ENTIRE current backlog: 4 distinct URLs covering 25 live manifests.
--
-- 🛑 WHY THIS IS A HAND-AUTHORED MIGRATION AND NOT A CRON, DELIBERATELY.
-- The gate exists so a ROSTER form, which lists co-clients, can never be served to a client.
-- Since 2026-08-26 the blast radius is larger than it was when the gate was written: both DERM
-- emails now attach the FP Service Report and nothing else (33aa3c3), so a document wrongly
-- marked 'receipt' is composited into a PDF and mailed to the client and, on the city path, to
-- Miami-Dade plus CITY_BCC. Deleting the row afterwards cannot recall the email.
-- Against that: the whole backlog is FOUR images and arrivals run about one URL per day. A
-- vision cron to save one human glance per dump ticket is the wrong trade. If this ever stops
-- being four, revisit -- but revisit the trade, not this reasoning.
--
-- HOW EACH WAS VERIFIED (I opened all four and looked at them, 2026-08-26)
-- ----------------------------------------------------------------------
-- Every one is a per-load disposal receipt: the only party named is UnclogMe itself, and there
-- is no customer roster anywhere on the page. The discriminator that matters is not "does it
-- look like a receipt" but "does it name anyone other than us", and none of them does.
--
-- ⚠ CORROBORATION THAT EACH IMAGE BELONGS TO THE MANIFEST IT IS ATTACHED TO: the ticket number
-- printed on the paper matches the manifest's own ticket in all four cases. That is what rules
-- out an upload swap, which is the other failure this gate was built after.
--
--   derm/1750  SDWWTP        NO. 833813 = ticket 833813  3800 gal $357.20 8/24/26  10 manifests
--   derm/1741  Broward       Ticket 312024 = ticket 312024  1700 gal 8/21/26        9 manifests
--   derm/1735  SDWWTP        NO. 833395 = ticket 833395  3800 gal $357.20 8/20/26   3 manifests
--   derm/1738  SDWWTP        NO. 833530 = ticket 833530  3800 gal $357.20 8/20/26   3 manifests
--
-- ⚠ MANIFEST 512 IS NOT IN SCOPE AND NEVER CAN BE. It has derm_manifest_url IS NULL (ticket
-- 296623, dumped 2026-01-26), so there is no URL to classify. Any future backlog query must be
-- `derm_manifest_url IS NOT NULL AND rc.url IS NULL`, or it counts 512 forever and, if it is
-- ever automated, spends a vision call on it every cycle.
--
-- RULE 8 (audit trail): OPT-OUT, unchanged. derm.receipt_doc_class is machine/ops
-- classification metadata carrying no business data; the base migration made that call and
-- this one adds rows under it.

BEGIN;

INSERT INTO derm.receipt_doc_class (url, class, note) VALUES
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1750/manifest_1.jpg',
   'receipt', 'SDWWTP ticket 833813, 3800 gal, $357.20, 8/24/26, decal C1184 cust 62368 - read 2026-08-26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1741/manifest_1.jpg',
   'receipt', 'Broward septage receipt ticket 312024, 1700 gal, 8/21/26, EPD decal 07058 - read 2026-08-26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1735/manifest_1.jpg',
   'receipt', 'SDWWTP ticket 833395, 3800 gal, $357.20, 8/20/26, driver Michael Escobar - read 2026-08-26'),
  ('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1738/manifest_1.jpg',
   'receipt', 'SDWWTP ticket 833530, 3800 gal, $357.20, 8/20/26, driver Anthony Clark - read 2026-08-26')
ON CONFLICT (url) DO NOTHING;

-- ---------------------------------------------------------------------------
-- VERIFY
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_backlog   integer;
  v_control   integer;
  v_now_served integer;
BEGIN
  -- The real backlog predicate: NULL urls can never be classified and must not be counted.
  SELECT count(*) INTO v_backlog
    FROM public.derm_manifests m
   WHERE m.deleted_at IS NULL
     AND m.derm_manifest_url IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM derm.receipt_doc_class rc WHERE rc.url = m.derm_manifest_url);
  IF v_backlog <> 0 THEN
    RAISE EXCEPTION 'VERIFY failed: % manifests still unclassified (expected 0)', v_backlog;
  END IF;

  -- CONTROL. A migration that asserts "0 remaining" proves nothing on its own: an empty or
  -- broken source table also reports 0. This asserts the instrument still finds the row that
  -- CANNOT be classified, so the 0 above is a real result rather than a silent no-op.
  SELECT count(*) INTO v_control
    FROM public.derm_manifests m
   WHERE m.deleted_at IS NULL AND m.derm_manifest_url IS NULL;
  IF v_control < 1 THEN
    RAISE EXCEPTION 'VERIFY control failed: expected at least one NULL-url manifest (512), found %', v_control;
  END IF;

  -- The point of the change: these URLs now reach the client through the report.
  SELECT count(*) INTO v_now_served
    FROM customer.work_orders w
   WHERE w.wwtp_receipt_url IS NOT NULL;

  RAISE NOTICE 'VERIFY ok: receipt backlog 0 (control: % NULL-url manifest(s) still correctly excluded); % work orders now serve a receipt',
    v_control, v_now_served;
END $$;

COMMIT;
