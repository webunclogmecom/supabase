-- 2026-07-28m  Normalize-on-ingest: `public.line_items.name` is btrim'd on every write
--
-- ASK (Fred, 2026-07-28): "add the normalize trigger." Closes the one part of 2026-07-28l that was NOT
-- durable.
--
-- ============================================================================
-- WHY THIS EXISTS — 2026-07-28l cleaned the data but could not keep it clean
-- ============================================================================
-- 2026-07-28l fixed the whole whitespace class at source: 7 of 63 Jobber Products & Services catalog
-- entries carried a trailing space and were re-infecting every line item created from them. Catalog fixed,
-- 206 job/visit line items fixed in Jobber, 1122 mirror rows trimmed. Two holes remained, and only a
-- write-side normalizer closes either:
--
--   1. INVOICES — 760 of those 1122 rows (68%) are invoice-scoped and are UNFIXABLE AT SOURCE. Jobber
--      freezes a copy of the name onto each invoice line at issue time, so the catalog rename never
--      reaches them (verified live on invoice #2233: still 'Grease Trap Pumping ', 20 chars, after the
--      catalog was clean). And there is **no `invoiceEditLineItems` mutation** — `InvoiceEditInput` has no
--      `lineItems` field at all (introspected). So Jobber will serve those dirty names forever, and
--      `webhook-jobber.handleInvoice` re-inserts `name` straight from Jobber after deleting the old rows.
--      Any of those 691 invoices that re-syncs would have put its trailing space straight back.
--
--   2. FREE TEXT — the catalog fix can only ever cover catalog-derived names. Of the 98 distinct dirty
--      names, 6 were catalog names (962 rows, 86%) but 92 were hand-typed one-offs (160 rows, 14%):
--      'Hydrojet Cleaning AREA ', 'DYE test ', 'Sump pump cleaning ', ' Warranty of Drainage ' (LEADING
--      space). Nothing stops staff typing a trailing space into a new line item tomorrow.
--
-- This trigger makes the mirror self-cleaning for both, regardless of what Jobber sends or what anyone
-- types. It is the boundary normalizer the sync layer should always have had.
--
-- ============================================================================
-- WHY IT IS SAFE — the same three proofs from 2026-07-28l, which measured the ACTUAL fleet
-- ============================================================================
-- This trigger applies exactly the transformation that 2026-07-28l already proved behaviour-neutral
-- against every affected row in Prod. Restating, because a trigger applies it to all FUTURE rows too:
--   * name-derived logic is btrim-safe: `fn_line_item_requires_derm` and `fn_line_item_is_gdo_reporting`
--     btrim() on every branch — tested across all 99 distinct dirty names, dirty vs trimmed: 0 flips.
--     These are what drive ripple #4 (`service_type`) and #5 (`derm_required`).
--   * no exact-string catalog join is affected: rows matching a `service_line_items.title` exactly were
--     0 before the trim and 0 after.
--   * a full `BEGIN … ROLLBACK` simulation of the same UPDATE diffed 9 fingerprints (work_orders rows +
--     empty-services, v_calendar_visit rows + SUM(amount), derm_required stored AND recomputed,
--     client_service_options, derm.visits, GDO item count) — ALL 9 IDENTICAL.
--   * amounts cannot move: they come from unit_price/total_price, never from `name`.
--
-- No key risk: `public.line_items` has NO unique constraint or natural key involving `name` (PK is `id`;
-- otherwise 4 FKs + `line_items_at_least_one_scope_chk`). So normalizing `name` cannot change any
-- ON CONFLICT target, and the webhook's delete-then-insert pattern is unaffected.
--
-- ⚠ SCOPE IS DELIBERATELY LEADING/TRAILING ONLY. `btrim`, not a whitespace collapse. Exactly 1 row in
-- 5883 has an internal double space; collapsing internal runs would be a semantic edit to a human-entered
-- string, which is a different (and riskier) decision than stripping invisible edge padding. Left alone.
--
-- ⚠ THIS IS A DELIBERATE, DOCUMENTED DIVERGENCE FROM JOBBER (Rule 4: Jobber = 100% trusted). The mirror
-- will now differ from Jobber by exactly the edge whitespace on those frozen invoice lines. That is the
-- point: it is a normalization at the ingest boundary, not a data disagreement — no value, code, price or
-- classification differs, only invisible padding. Anyone diffing mirror-vs-Jobber on `name` must compare
-- `btrim(jobber_name)`, or they will "find" 760 false discrepancies.
--
-- RULE 8 (ADR 010) — AUDIT STANDING CHECK: **OPT-OUT, unchanged.** No new table and no new business
-- column; `public.line_items` is a Jobber-sync mirror and has always been a documented sync-only opt-out
-- (its only other trigger is `trg_line_items_updated_at`). This trigger writes no business value — it
-- strips padding from a value the sync layer already supplies — so it introduces nothing an audit trail
-- would need to attribute. `updated_at` stays trigger-managed (Rule 7) and is NOT touched here.
-- RULE 1: no source-prefixed columns. RULE 6: no deletes.
--
-- NAMING: `trg_aa_` prefix so it sorts first and runs before any future BEFORE trigger — downstream
-- triggers should see the normalized value, never the raw one. (Postgres fires BEFORE triggers in name
-- order.) Matches the existing house convention: `trg_aa_link_same_client`, `trg_aa_reconcile_operating_date`.
--
-- NO GRANT BLOCK, ON PURPOSE. A `RETURNS trigger` function cannot be invoked directly — PostgREST will not
-- expose it and a direct SQL call raises "trigger functions can only be called as triggers" — so the usual
-- default-privileges hardening (repo memory: reference_supabase_function_default_privileges) has nothing
-- to close here. Revoking EXECUTE would add risk, not remove it.
--
-- ROLLBACK: `DROP TRIGGER trg_aa_line_items_normalize_name ON public.line_items;`
--           (and optionally `DROP FUNCTION public.fn_line_items_normalize_name();`)
-- Dropping it does not dirty any existing row; it only stops future writes from being normalized.

CREATE OR REPLACE FUNCTION public.fn_line_items_normalize_name()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'pg_temp'
AS $function$
BEGIN
  -- btrim(NULL) is NULL, so a NULL name passes through untouched (the column is nullable and the
  -- invoice/job handlers can legitimately send `name: null`).
  NEW.name := btrim(NEW.name);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_aa_line_items_normalize_name ON public.line_items;

CREATE TRIGGER trg_aa_line_items_normalize_name
  BEFORE INSERT OR UPDATE OF name ON public.line_items
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_line_items_normalize_name();

-- Post-condition (verified in a BEGIN/ROLLBACK harness before commit):
--   INSERT with '  Padded Name  '            -> stored 'Padded Name'
--   UPDATE an existing row to name || '   '  -> stored without the padding
--   INSERT with NULL name                    -> stays NULL, no error
--   steady state: SELECT count(*) FROM public.line_items WHERE name <> btrim(name);  -> 0
