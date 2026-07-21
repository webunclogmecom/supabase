-- ============================================================================
-- 2026-07-21j — Per-consumer API keys for the GDO Online Reporting bot
-- ============================================================================
-- WHY (Fred 2026-07-21, answering "does he need his own env key?"): until now
-- there was exactly ONE inbound bot key in the RPA_BOT_KEYS secret, shared by
-- whoever called the endpoints (Fred's Postman harness today, John's Railway
-- bot tomorrow). Two problems with sharing it:
--   1. Revocation blast radius — if John's key leaks (Railway env, a log line,
--      a laptop) we cannot drop it without simultaneously breaking Fred's
--      Postman harness, mid-rollout, on a compliance-critical pipeline.
--   2. No attribution — the auth check was `KEYS.includes(presented)`, which
--      validates membership but never records WHICH key called. Once the bot
--      files real reports to Miami-Dade we could not tell, from the submission
--      log, whether a given filing came from John's production bot or from a
--      Postman test. For a county-facing compliance trail that is a real gap.
--
-- HOW: the RPA_BOT_KEYS secret becomes a comma-separated list of LABELLED
-- entries, `label:secret` (e.g. `john-bot:<hex>,fred-postman:<hex>`). The edge
-- functions parse the label, match the presented `x-rpa-key` against the
-- secrets, and rpa-derm-result stamps the matching LABEL onto the submission
-- row. Backward compatible on purpose: an entry with no `label:` prefix (or a
-- prefix that does not look like a label) is still accepted and recorded as
-- 'unlabelled', so the new code is safe to deploy BEFORE the secret is
-- reformatted. Deploy order is load-bearing: functions first, secret second.
-- Reversing it would make every entry fail to match and 401 both consumers.
--
-- 3NF NOTE: `consumer` is the API-key LABEL as matched at submission time, not
-- an FK. Keys are deployment configuration (an edge-function secret), not a
-- table, so there is nothing to reference — this is a point-in-time credential
-- snapshot, the same intentional denormalization as sent_by_email in 21h.
-- Existing rows stay NULL: they were written before labelling and we do not
-- back-fill an actor we cannot actually prove.
--
-- SAFETY: additive only. Nullable column, no default, no backfill, no rewrite
-- of existing submissions. Nothing in the queue-gating logic reads `consumer`,
-- so this cannot affect which visits are dispensed or the double-file guards.
-- ============================================================================

alter table public.derm_portal_submissions
  add column if not exists consumer text;

comment on column public.derm_portal_submissions.consumer is
  'Label of the RPA_BOT_KEYS entry whose key authenticated this submission '
  '(e.g. john-bot, fred-postman). Stamped server-side by rpa-derm-result from '
  'the matched credential — never accepted from the request body. '
  'NULL = written before per-consumer labelling (2026-07-21j). '
  '''unlabelled'' = matched a legacy entry that carried no label: prefix.';

-- Reporting/filtering by consumer is low-volume (a handful of clients on Line
-- Item 27), so no index: the table is small and every existing read is keyed by
-- (visit_id, run_id) or dry_run, which are already covered.
