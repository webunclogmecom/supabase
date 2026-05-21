-- 2026-05-19b_clean_client_name_prefix.sql
--
-- Two-part fix to keep `public.clients.name` clean of duplicated client_code
-- prefixes (Fred 2026-05-19 spec — code lives in `client_code` field only,
-- not duplicated inside `name`).
--
-- Part 1: one-shot UPDATE on 52 existing rows where ops typed the code
-- prefix into Jobber's Company Name field (so the sync stored it as e.g.
-- "125-EI Esther Isaacov" instead of just "Esther Isaacov").
--
-- Part 2: webhook-jobber Edge Function patched in the same cycle so future
-- syncs strip the prefix at ingest. See supabase/functions/webhook-jobber/index.ts
-- around line 200 — the `nameNormalized` const. Deployed to Prod 2026-05-19.
-- cron_jobber.js replays through the same Edge Function, so it's covered too.
--
-- Audit: every UPDATE captured via the audit_clients trigger (52 rows in audit.logs).

UPDATE public.clients
   SET name = TRIM(SUBSTRING(name FROM LENGTH(client_code) + 1))
 WHERE client_code IS NOT NULL
   AND name LIKE (client_code || ' %');

-- Verification:
-- SELECT COUNT(*) FROM public.clients
--   WHERE client_code IS NOT NULL AND name LIKE (client_code || '%');
-- Expected: 0
