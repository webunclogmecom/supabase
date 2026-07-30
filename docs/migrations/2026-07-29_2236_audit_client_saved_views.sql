-- ============================================================================
-- 2026-07-29_2236 — ADR 010 OPT-IN: audit client.saved_views
-- ============================================================================
-- AUDIT (ADR 010): **OPT-IN**, explicit decision, approved by Fred 2026-07-29.
--
-- WHY THIS IS AN OPT-IN AND NOT A DEFAULT
-- ---------------------------------------------------------------------------
-- `client.saved_views` is the ONE documented exception to "all Client App writes go
-- through a SECDEF RPC": the app reads and writes this table DIRECTLY. That exception was
-- justified on two properties (Client App CLAUDE.md rule #2):
--   (a) it is a real table with RLS ENABLED + FORCED and owner-scoped policies, not an
--       RLS-bypassing view, and
--   (b) it holds only the user's own UI preferences, never canonical business data.
--
-- Property (b) has stopped being true in practice. `is_shared` makes a saved view
-- CROSS-USER state: a shared view drives what a *different* staff member sees when they
-- click it. Measured today, view id 12 ("No Zone Clients", `is_shared = true`) is already
-- shared. Once one person's row changes another person's screen, "UI preference" no longer
-- describes it, and an unattributed rename/reshare/delete is a real "who changed my view?"
-- question with no answer.
--
-- THE CONCRETE GAP THIS CLOSES
-- ---------------------------------------------------------------------------
-- Before this migration `audit.logs` held **0** rows for saved_views, and the table's only
-- trigger was `saved_views_touch` (an `updated_at` toucher). That zero is a **FALSE
-- ALL-CLEAR of exactly the §5.5(b) kind**: it does not mean nobody wrote the table, it means
-- nothing was watching. Provenance had to be recovered from `owner_user_id` instead, which
-- is how we established that Fred (not either session) created view 12 — workable for
-- "who owns it", useless for "who changed or deleted it".
--
-- ⚠ AND NOTE WHAT AN AUDIT TRIGGER STILL CANNOT TELL YOU (learned the hard way 2026-07-29
-- on the Visit Calendar zone rename): `audit.logs` records SUCCESSES. A failing write aborts
-- its transaction and writes NO row at all. So this trigger will answer "is this table used,
-- and who changed this row" and it will NEVER answer "does the saved-views feature work".
-- For that, exercise the path. See root CLAUDE.md §5.5(b).
--
-- SCOPE / SAFETY
-- ---------------------------------------------------------------------------
--  * Trigger only. No schema change, no data change, no grant change, no policy change.
--  * 1 row exists today, so there is no backfill question and no volume concern.
--  * `config` is opaque JSONB holding grid state (tab/sort/filters/columns/group/pageSize).
--    It carries no PII, so nothing is added to `audit.redacted_columns`.
--  * The table is in the `client` schema, not `public`. `audit.log_change` handles that
--    fine: it early-returns only for `TG_TABLE_SCHEMA = 'audit'` and records
--    `table_schema` on every row. Verified by probe before shipping.
--  * Attribution will land as `app_source = 'client-app'` because the app sets the
--    `X-App-Source` header, which OVERRIDES the Origin CASE. (The header shipped as
--    `client-view-pro` and was corrected 2026-07-30; the Origin pin from `2026-07-29c` is
--    effectively dead code for this app.)
-- ============================================================================

begin;

drop trigger if exists audit_saved_views on client.saved_views;

create trigger audit_saved_views
  after insert or update or delete on client.saved_views
  for each row execute function audit.log_change();

commit;

-- ============================================================================
-- Rollback
-- ============================================================================
-- Disabling audit on an existing table requires explicit Fred sign-off (ADR 010).
-- drop trigger if exists audit_saved_views on client.saved_views;
