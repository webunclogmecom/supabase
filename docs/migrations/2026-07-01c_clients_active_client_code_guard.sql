-- 2026-07-01c_clients_active_client_code_guard.sql
-- ============================================================================
-- Health-check finding (DB Integrity): client_code '239-COM' was held by TWO
-- ACTIVE 'Courtyard by Marriott SOBE' rows — id 247 (the real client, Jobber
-- gid 128045918, 7 visits) and id 493 (created 2026-06-30 via an Airtable sync,
-- Jobber gid 144935164). Jobber lookup: 128045918 is a live client; 144935164
-- returns NULL (does not exist). So 493 is a PHANTOM duplicate: empty (0 visits,
-- 0 manifests, 0 service_configs, 0 gdos; one stray dup property left in place),
-- pointing at a non-existent Jobber client. No Jobber client behind it → the
-- poll won't resurrect it.
--
-- Actions (run via Management API; recorded here):
--   1. Retire the phantom dup:  UPDATE clients SET status='INACTIVE' WHERE id=493.
--      (clients soft-delete = status, no deleted_at. Audit trigger fired.)
--   2. Guardrail so two LIVE clients can never share a client_code again — a new
--      active-dup INSERT now errors (23505) instead of silently duplicating,
--      surfacing the offending sync loudly. Verified in a rolled-back tx.
--
-- NULL client_code is excluded (196/416 clients are legitimately NULL today).
-- INACTIVE excluded so a retired row can coexist with its live successor
-- (e.g. 050-PV: INACTIVE id 41 + ACTIVE id 469 — allowed).
--
-- OPEN (flagged to Fred / the client_code session): (a) how an Airtable-sourced
-- client got minted 2026-06-30 despite Airtable being retired for client creation;
-- (b) the 2 ACTIVE clients with NULL client_code (93 Panino Kosher, 480 Bay
-- Harborview) — backfill needs the 3-source renumber check, not a blind write.
--
-- Audit (ADR 010): clients already audited. updated_at trigger-managed.
-- ============================================================================

UPDATE public.clients SET status = 'INACTIVE'
 WHERE id = 493 AND client_code = '239-COM' AND status = 'ACTIVE';

CREATE UNIQUE INDEX IF NOT EXISTS clients_active_client_code_uniq
  ON public.clients (client_code)
  WHERE status <> 'INACTIVE' AND client_code IS NOT NULL;
