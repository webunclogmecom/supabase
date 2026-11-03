-- 2026-11-02_2020_void_smoke_preview_sheets_1153_1154.sql
-- Cleanup of my own test artefacts from the permits smoke test (Fred, 11-02: "can you smoke test to make sure everything
-- is correct"). Same shape as 2026-10-22_1915 (sheet 1149), whose lesson I repeated.
--
-- HAND REPAIR, and it says so (root CLAUDE.md section 7): it removes two rows a test created; it closes no design.
--
-- At 2026-11-03 01:10:27Z and 01:10:47Z (20:10 ET, 11-02) I called the pdf-service /generate/derm-address/preview with
-- visit 6740 (165-LPB) and visit 5944 (022-GRO) to check that a real Miami-Dade sheet prints only GDO permits. Without
-- disposal_facility_id that path allocates the next DERM Address number and records the sheet: sheets 1153 and 1154,
-- derm.address_sheets ids 191 and 192 (pdf_bucket 'preview', one client each). Nobody printed them, no manifest carries
-- either number, no ticket links them, no scan read names them.
-- Why it matters: a one-client generated sheet can be bound by derm.fn_resolve_generated_sheet_for_ticket to a future
-- ticket for that client alone. The resolver skips soft-deleted sheets.
-- Why it happened: the edge function's header said "No storage upload, no DB write" (corrected the same day); the
-- 1149 migration's advice (use a visit id that does not exist) was the right one and I did not read it first.
--
-- Change: soft-delete rows 191 and 192 (deleted_at). Never a hard delete (rule 6). derm.address_sheets is audited.
-- Numbers 1153 and 1154 stay used: sequence gaps from previews are expected.
-- Rollback: update derm.address_sheets set deleted_at = null where id in (191, 192);
begin;
set local lock_timeout = '3s';

do $guard$
begin
  if (select count(*) from derm.address_sheets s
       where (s.id, s.sheet_no) in ((191, 1153), (192, 1154)) and s.pdf_bucket = 'preview' and s.deleted_at is null
         and s.created_at between '2026-11-03 01:10:00+00' and '2026-11-03 01:11:00+00') <> 2
     or (select count(*) from derm.address_sheet_clients c where c.sheet_id in (191, 192)) <> 2
     or not exists (select 1 from derm.address_sheet_clients c where c.sheet_id = 191 and c.visit_id = 6740 and c.client_id = 209)
     or not exists (select 1 from derm.address_sheet_clients c where c.sheet_id = 192 and c.visit_id = 5944 and c.client_id = 357)
     or exists (select 1 from derm.address_sheet_manifests x where x.sheet_id in (191, 192))
     or exists (select 1 from public.derm_manifests m where m.derm_address_no in (1153, 1154))
     or exists (select 1 from derm.address_sheet_scan_reads r where r.sheet_no_read ~ '^(1153|1154)(-|$)') then
    raise exception 'sheets 191/192 are not the untouched test previews any more; stop and look';
  end if;
end
$guard$;

update derm.address_sheets set deleted_at = now() where id in (191, 192) and deleted_at is null;

do $verify$
begin
  if (select count(*) from derm.address_sheets where id in (191, 192) and deleted_at is not null) <> 2 then
    raise exception 'VERIFY: sheets 191/192 not both soft-deleted';
  end if;
end
$verify$;

commit;
