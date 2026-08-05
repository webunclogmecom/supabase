-- 2026-08-05_1806_service_line_item_default_rate_pct.sql
--
-- Client App fee lines, step 1 of 4: give the fee catalogue a REAL rate column.
-- ADDITIVE ONLY. No behaviour changes; nothing reads this column yet.
--
-- WHY
-- ---
-- Fred wants catalogue codes 25/26/27 selectable in the Client App job editor, with a
-- per-line toggle between "a percentage" and "a precise amount", because Jobber accepts
-- only a number while our app can hold the intent.
--
-- THE RATE IS CURRENTLY STORED NOWHERE. `service_line_items.unit_price` is NULL for all
-- three fee rows. The only place "3.53%" or "1%" exists is inside the TITLE TEXT:
--     25 - Credit card fee (3.53%)      26 - ACH Fee (1%)      27 - GDO Online Reporting
-- 🛑 Parsing the rate out of the title would be a money bug waiting to happen. The title
-- is load-bearing for the taxonomy join (`sli.code = lpad(substring(name from '^([0-9]+)'))`)
-- and for `save-client-job`'s prefix assertion, so it is edited for unrelated reasons — and
-- a rename like "(3.53%)" -> "(3.6%)" would silently change what customers are billed with
-- no migration, no audit row naming the rate, and no review. Hence a real column.
--
-- THE RULE IS EMPIRICAL, NOT ASSUMED (measured on Prod 2026-08-05, job-scoped lines only,
-- base = the sum of that job's `reason='Service Agreement'` line totals):
--
--     code 26 (ACH 1%)          90 rows   implied pct min = max = EXACTLY 1.000   90/90 match
--     code 25 (Credit card)     68 rows   avg 3.481   61/68 within 0.05pp of 3.53
--
-- So the fee IS a percentage of the job's service subtotal, and it is a property of the FEE
-- TYPE, not of the job — which is why the rate belongs on the catalogue and not per-job.
--
-- ⚠ THE 7 CODE-25 "OUTLIERS" ARE NOT SLOPPINESS, AND TWO OF THEM ARE NOT OUTLIERS AT ALL:
--   * job 1369 appears TWICE at $16.41 on a $930 subtotal (1.765% each). Summed, 32.82/930
--     = 3.529% — exactly right. It is a DUPLICATE LINE, not a wrong rate; a per-line query
--     halves it. (Duplicate job lines exist: 14 rows across 12 live SA jobs.)
--   * the remaining 4 are STALE. Working each fee back at 3.53% recovers the subtotal it was
--     correct for, and in every case the services changed afterwards and nobody recomputed:
--         job 1777  $19.06 -> implies ~$540   actual now $650
--         job 1377  $17.30 -> implies ~$490   actual now $475
--         job 1521  $16.06 -> implies ~$455   actual now $420
--         job 1472  $11.83 -> implies ~$335   actual now $300
--     ⇒ FOUR LIVE JOBS ARE BILLING THE WRONG CREDIT-CARD FEE TODAY. Recomputing percent-mode
--     fees on save is the point of the feature, not a side effect.
--
-- ⚠ CODE 27 IS NOT A PERCENTAGE and deliberately gets NULL. Measured amounts: $0.00 (27
-- rows), $35.00 (8), $15.00 (5). `default_rate_pct IS NULL` is what the UI keys on to show an
-- amount-only line with no toggle. Do not "fill it in".
--
-- HOW THE MODE IS DECIDED (Fred, 2026-08-05: "derive it, go ahead")
-- ----------------------------------------------------------------
-- The percent/amount mode is **NOT stored**. It is derived on read: if the line's amount
-- equals rate x service-subtotal, the line IS in percent mode; otherwise someone set a custom
-- amount and it shows as dollars. Rejected the alternative (a `job_fee_lines` table recording
-- mode per job) because it would be a second "last confirmed by us" store that can drift out
-- of sync with Jobber — the exact trap already documented on `jobs.billing_type`.
--
-- AUDIT (rule 8): `public.service_line_items` ALREADY carries `audit_service_line_items`
-- (generated, not trusted to a list). Adding a column to an audited table is captured
-- automatically in the full-row JSONB — no trigger work required.
--
-- VIEW SAFETY: `client.service_line_items` (what the app reads) selects columns EXPLICITLY, so
-- a new base-table column does NOT appear automatically. It is re-created below with the new
-- column APPENDED LAST. Its 14 existing columns and their order were re-read from
-- information_schema immediately before writing this file and are reproduced verbatim —
-- `CREATE OR REPLACE VIEW` rejects a dropped/renamed column but SILENTLY ACCEPTS A REORDER.
-- The other 7 views that reference this table are deliberately NOT touched; none needs the rate.
--
-- ROLLBACK:
--   (restore the 14-column view body, then)
--   ALTER TABLE public.service_line_items DROP COLUMN default_rate_pct;

ALTER TABLE public.service_line_items
  ADD COLUMN IF NOT EXISTS default_rate_pct numeric(6,4);

ALTER TABLE public.service_line_items
  DROP CONSTRAINT IF EXISTS service_line_items_default_rate_pct_chk;
ALTER TABLE public.service_line_items
  ADD CONSTRAINT service_line_items_default_rate_pct_chk
  CHECK (default_rate_pct IS NULL OR (default_rate_pct > 0 AND default_rate_pct <= 100));

COMMENT ON COLUMN public.service_line_items.default_rate_pct IS
  'Percent-of-job-service-subtotal rate for a fee line, in PERCENT UNITS (3.53 means 3.53%). '
  'NULL = this line is a flat amount and the UI shows no percent toggle (e.g. 27 - GDO Online '
  'Reporting). Measured 2026-08-05: code 26 is exactly 1.000% on 90/90 job lines and code 25 is '
  '3.53% on 61/68. The percent/amount MODE is derived, never stored — see '
  '2026-08-05_1806_service_line_item_default_rate_pct.sql.';

UPDATE public.service_line_items SET default_rate_pct = 3.53 WHERE code = '25';
UPDATE public.service_line_items SET default_rate_pct = 1.00 WHERE code = '26';
-- code 27 intentionally left NULL (flat amount, see header).

-- client.service_line_items: 14 existing columns verbatim, new column APPENDED LAST.
CREATE OR REPLACE VIEW client.service_line_items AS
SELECT id,
       code,
       title,
       requires_derm,
       reason,
       location_target,
       method,
       service_type,
       schedulable,
       active,
       created_at,
       updated_at,
       unit_price,
       default_vehicle_id,
       default_rate_pct
  FROM service_line_items;
