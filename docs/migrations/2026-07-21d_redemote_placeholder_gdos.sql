-- ============================================================================
-- 2026-07-21d — Re-demote the placeholder gdos rows the 2026-06-29 AT burst
--               re-promoted (restores the 2026-06-28 cleanup state)
-- ============================================================================
-- WHY (triggered by the GDO Bot session's 2026-07-21 finding of ~20 ACTIVE
-- placeholder rows; full provenance workflow run this session):
--
-- These rows hold placeholder strings ('Not available' x16, 'Needs review' x3)
-- instead of permits. The 2026-06-28 00:26 cleanup ALREADY adjudicated them:
-- all were demoted to INACTIVE with the note "[2026-06-28 cleanup] Placeholder
-- value (not a real GDO number) — demoted from active." Then the 2026-06-29
-- 17:01-17:05 Airtable re-ingest burst flipped them back to ACTIVE (and
-- inserted 4 fresh ones; webhook-airtable added 2 more on 07-05 and 07-14).
-- The 2026-07-17 GDO audit re-demoted only the wrong-VALID-number class (40
-- rows); the placeholder class stayed regressed, with self-contradicting rows
-- (status ACTIVE, notes saying "demoted from active").
--
-- This is therefore a REGRESSION RESTORE, not a new business decision.
--
-- Customer-visible impact before this migration: customer.permits (Field
-- Portal) returned 19 literal "Not available"/"Needs review" permit rows
-- across 18 clients; ops.v_calendar_visit exposed placeholder gdo_number on
-- 138 visit rows (56 future); derm.visits, ops.service_configs,
-- ops.v_derm_compliance, ops.v_gdo_expiry, ops.v_route_today,
-- ops.v_service_due, public.visit_manhole_options all surfaced them (only
-- public.dump_outstanding_visits format-filters). The GDO Slack bot already
-- filters them out client-side.
--
-- DELIBERATE EXCEPTION — id 141 (057-BAY, 'PSO-00025') is NOT touched: a real
-- Private Sanitary Sewer permit (lift-station client, document
-- gdo/PSO-00025.pdf), value written per Fred 2026-07-08. It stays ACTIVE.
-- (Flagged to Fred separately: FP shows it with its 2019-09-30 expiration.)
--
-- RECURRENCE CLOSED in the same cycle: webhook-airtable GUARD 1b (deployed
-- 2026-07-21) now skips any gdos write whose value is not canonical
-- ^GDO-\d+$ — the INSERT hole that produced rows 211/222 post-audit-patch.
-- NO CHECK CONSTRAINT added on purpose: PSO-00025 is a legitimate ACTIVE
-- non-GDO value, so a format CHECK would either block it or need a
-- policy-inventing allowlist; the single writer with the hole is now guarded.
--
-- Notes are APPENDED, never replaced (adjudication history preserved;
-- trg_aa_gdos_guard_demoted requires a notes amendment for any future
-- reactivation, which this append satisfies structurally).
--
-- 3NF: n/a (data-only). AUDIT: gdos is audited (audit_gdos); this runs as
-- app_source='sql'. Soft status change only — no rows deleted.
-- ============================================================================

UPDATE public.gdos
   SET status = 'INACTIVE',
       notes  = COALESCE(notes, '')
                || ' | [2026-07-21 re-demote] Placeholder value regressed to ACTIVE by the 2026-06-29 AT re-ingest burst (or inserted by the webhook INSERT hole since); restoring the 2026-06-28 cleanup adjudication. Recurrence closed by webhook-airtable GUARD 1b. Do not reactivate without a real GDO number.'
 WHERE status = 'ACTIVE'
   AND gdo_number !~ '^GDO-[0-9]+$'
   AND gdo_number <> 'PSO-00025';   -- id 141, deliberate per Fred 2026-07-08

-- ============================================================================
-- VERIFICATION RECORD — 2026-07-21 (appended after deploy)
-- ============================================================================
-- Pre-state backup: ..\backups\2026-07-21_placeholder_gdos_predemote.json
-- (20 ACTIVE non-conforming rows with full notes/timestamps).
-- - UPDATE hit 19 rows (16 'Not available' + 3 'Needs review'); id 141
--   PSO-00025 untouched (still ACTIVE).
-- - ACTIVE non-conforming rows after: 1 (PSO-00025 only).
-- - customer.permits placeholder permit rows: 19 -> 1 (the PSO row).
-- - ops.v_calendar_visit rows exposing a placeholder gdo_number: 138 -> 21,
--   and all 21 are 057-BAY/PSO-00025 (the deliberate exception).
-- - 223-CHA now shows only its real permit GDO-08165 (the 'Needs review'
--   sibling row demoted).
-- - GDO bot behavior unchanged (it already format-filtered; these clients
--   correctly read "no permit on file" both before and after).
-- ============================================================================
