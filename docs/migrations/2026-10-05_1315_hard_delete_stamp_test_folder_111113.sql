-- HARD DELETE of the Stamp Studio test folder ticket-111113
--
-- Fred, 2026-10-05, after 111111 and 111112 went (2026-10-05_1250): "delete 111113". An explicit,
-- named exception to rule 6: 112-YA test data (client 381). It was used the same day for the
-- end-to-end test of the required Draw-the-bands flow and for the [TEST] post of the daily Slack
-- reminder (13:06 ET), then deleted.
--
-- WHAT GOES (32 rows, found by a catalogue sweep of every table with a dump_folder,
-- white_manifest_number, manifest_id, ticket or row_id column, plus FKs to derm_manifests and
-- address_row_map; every DELETE pinned to keys with an exact row-count assertion, all or nothing):
--   derm.address_row_map 1 (card 2980) · derm.page_slots 5 · derm.page_row_rules 12 ·
--   derm.page_rule_scans 2 · derm.page_block_extents 1 · derm.stamp_sheet_status 1 ·
--   derm.redacted_manifest_docs 1 · derm.receipt_doc_class 1 · public.manifest_visits 1 ·
--   public.derm_email_sends 6 (sends 176-179, 181, 182, all to the test client's own inbox
--   fred@ayache.com; their NOT NULL FK would block the manifest delete) · public.derm_manifests 1 (1941).
-- Plus 4 storage files (derm/1941/address_1.jpg, manifest_1.jpg, redacted/m1941p1-c85f5a1922.jpg,
-- GT - Visits Images derm/1941/fog.pdf, 1,447,186 bytes) through the Storage API after commit.
-- BACKUP first: backups/2026-10-05_stamp_test_folder_111113_hard_delete.json and
-- backups/2026-10-05_stamp_test_folder_111113_files/ (workspace root, not committed: test emails).
-- Unaudited tables (page_row_rules, page_rule_scans, redacted_manifest_docs, receipt_doc_class): the
-- backup is their only restore path.
-- KEPT: visit 8113 (a test visit, not part of the folder) and the generated-sheet number ledger.

begin;

do $$
declare n int;
begin
  if (select count(*) from public.derm_manifests where id = 1941 and white_manifest_number = '111113' and client_id = 381) <> 1
  then raise exception 'preflight: manifest 1941 is not the 112-YA test manifest 111113'; end if;
  if (select count(*) from derm.address_row_map where id = 2980 and dump_folder = 'ticket-111113') <> 1
  then raise exception 'preflight: card 2980 not as inventoried'; end if;
  if exists (select 1 from derm.address_row_map where dump_folder = 'ticket-111113' and id <> 2980)
  or exists (select 1 from derm.address_row_map where matched_manifest_id = 1941 and id <> 2980)
  or exists (select 1 from derm.band_review where row_id = 2980)
  or exists (select 1 from derm.address_sheet_manifests where manifest_id = 1941)
  or exists (select 1 from derm.manifest_visit_sheets where manifest_id = 1941)
  or exists (select 1 from public.derm_portal_submissions where manifest_id = 1941)
  or exists (select 1 from public.derm_portal_requeue where manifest_id = 1941)
  or exists (select 1 from public.lwt_filing_tickets where manifest_id = 1941)
  or exists (select 1 from public.derm_manifest_number_proposals where manifest_id = 1941)
  then raise exception 'preflight: a dependent row appeared since the inventory; re-inventory first'; end if;

  delete from derm.address_row_map where id = 2980 and dump_folder = 'ticket-111113';
  get diagnostics n = row_count; if n <> 1 then raise exception 'address_row_map: %', n; end if;
  delete from derm.page_slots where dump_folder = 'ticket-111113';
  get diagnostics n = row_count; if n <> 5 then raise exception 'page_slots: %', n; end if;
  delete from derm.page_row_rules where dump_folder = 'ticket-111113';
  get diagnostics n = row_count; if n <> 12 then raise exception 'page_row_rules: %', n; end if;
  delete from derm.page_rule_scans where dump_folder = 'ticket-111113';
  get diagnostics n = row_count; if n <> 2 then raise exception 'page_rule_scans: %', n; end if;
  delete from derm.page_block_extents where dump_folder = 'ticket-111113';
  get diagnostics n = row_count; if n <> 1 then raise exception 'page_block_extents: %', n; end if;
  delete from derm.stamp_sheet_status where dump_folder = 'ticket-111113';
  get diagnostics n = row_count; if n <> 1 then raise exception 'stamp_sheet_status: %', n; end if;
  delete from derm.redacted_manifest_docs where manifest_id = 1941;
  get diagnostics n = row_count; if n <> 1 then raise exception 'redacted_manifest_docs: %', n; end if;
  delete from derm.receipt_doc_class where url like '%/derm/1941/%';
  get diagnostics n = row_count; if n <> 1 then raise exception 'receipt_doc_class: %', n; end if;
  delete from public.manifest_visits where manifest_id = 1941 and visit_id = 8113;
  get diagnostics n = row_count; if n <> 1 then raise exception 'manifest_visits: %', n; end if;
  delete from public.derm_email_sends where manifest_id = 1941 and id in (176, 177, 178, 179, 181, 182);
  get diagnostics n = row_count; if n <> 6 then raise exception 'derm_email_sends: %', n; end if;
  delete from public.derm_manifests where id = 1941 and white_manifest_number = '111113' and client_id = 381;
  get diagnostics n = row_count; if n <> 1 then raise exception 'derm_manifests: %', n; end if;
end $$;

commit;
