-- ============================================================================
-- 2026-07-31_1119 — DATA FIX (executed): delete the 8 raw-numeric jobber GID
--                   rows from entity_source_links (2 job + 6 invoice)
-- ============================================================================
-- ⚠ EXECUTED 2026-07-31 ~15:15 UTC via the Management API. Recorded here as the
-- canonical account; re-running the DELETE below is a harmless no-op (0 rows).
--
-- WHY NOT THE ORIGINALLY-PLANNED UPDATE. The task began as "normalise 2 numeric
-- job source_ids to base64" (found when a bare decode() in the 2026-07-31_1035
-- view scan raised 22023). Investigation (3-agent sweep, workflow
-- wf_d725c732-1c7) showed an UPDATE is WRONG twice over:
--   1. It COLLIDES: unique index idx_esl_source_id (entity_type, source_system,
--      source_id) — the canonical base64 values ALREADY EXIST as twin rows
--      (jobs: ESL 24793/24795 → jobs 520/521; invoices: 6 twins likewise).
--   2. Even forced, it would repoint the canonical GID at the WRONG entity:
--      every numeric-linked entity is a 0-dependent DUPLICATE row minted when
--      the pre-2026-04-29 numeric convention made the base64 lookup miss
--      (webhook re-synced the same Jobber object into a NEW entity). Already
--      diagnosed for the jobs in 2026-06-24_jobs_job_number_unique.sql.
--
-- MEASURED before deleting (probe4, 2026-07-31):
--   jobs    517/518  (numeric-linked): 0 invoices, 0 visits, 0 line_items, 0 notes
--   jobs    520/521  (base64 twins):   3 invoices + 2 visits each   ← the real rows
--   invoices 1663,1664,1665,1666,1669,1670 (numeric-linked): 0 line_items,
--            0 visits, job_id NULL — frozen Apr-29/30 snapshots
--   invoices 1691,1692,1660,1617,1690,1671 (base64 twins): all line_items/visit/
--            job_id references live here
--   Jobber API: both job GIDs verified live — base64('gid://Jobber/Job/<n>')
--   returns the job byte-identically; the RAW numeric fails EncodedId coercion
--   outright ("'143219084' is not a valid EncodedId"), confirming the
--   push-would-fail risk that motivated the cleanup.
--
-- WHAT WAS DELETED (rule 6 explicitly permits legacy entity_source_links
-- archival; NO business rows touched). Full pre-delete snapshot incl. twins and
-- business rows: ..\..\..\backups\2026-07-31_esl_numeric_gids_pre_cleanup.json
-- (workspace backups folder, outside the public repos). entity_source_links has
-- NO audit trigger, so that backup is the only restore path (plain re-INSERT).
--
delete from public.entity_source_links
 where source_system = 'jobber'
   and ( (id = 4135  and entity_type = 'job'     and source_id = '143219084')
      or (id = 4136  and entity_type = 'job'     and source_id = '143219293')
      or (id = 4143  and entity_type = 'invoice' and source_id = '154229698')
      or (id = 4144  and entity_type = 'invoice' and source_id = '154228246')
      or (id = 4145  and entity_type = 'invoice' and source_id = '151826054')
      or (id = 15713 and entity_type = 'invoice' and source_id = '153894341')
      or (id = 18678 and entity_type = 'invoice' and source_id = '154354531')
      or (id = 20923 and entity_type = 'invoice' and source_id = '154374055') );
--
-- VERIFIED after: malformed-source_id census = 0 for EVERY jobber entity_type
-- (the 419 property rows matching '<gid>_billing' are the deliberate synthetic
-- billing-twin pattern, not corruption — do not "fix" them); all 8 canonical
-- twins intact; full client.jobs scan clean, 1794/1796 rows carry jobber_url
-- (the 2 NULLs are orphan jobs 517/518, correctly unlinked now).
--
-- SUPERSEDED CLAIM: 2026-06-24_jobs_job_number_unique.sql's header said the
-- archived duplicates are "never looked up by their raw GID" — true then; now
-- there is no raw GID at all. Its decision to KEEP jobs 517/518 (rule 6) stands.
--
-- STILL OPEN (Fred decisions, not taken here):
--   * Orphan duplicate BUSINESS rows remain: jobs 517/518 (archived, harmless)
--     and invoices 1663–1666, 1669, 1670 — the invoices are the live hazard:
--     a naive SUM over public.invoices double-counts $3,913.71, and three pairs
--     carry CONTRADICTORY frozen statuses (orphan 1666 "paid" vs live twin 1617
--     "awaiting_payment"; orphans 1669/1670 "awaiting" vs twins 1690/1671
--     "paid"). Options: soft-mark (e.g. a status value or subject prefix) or
--     hard-delete with sign-off. Billing truth = Jobber invoices; the twins are
--     the synced rows.
--   * scripts/sync/dedup_jobber_links.js encodes the OBSOLETE pre-2026-04-29
--     numeric convention (its --execute converts base64 GIDs BACK to numerics
--     fleet-wide). Warning header added same cycle; candidate for _archive.
-- ============================================================================
