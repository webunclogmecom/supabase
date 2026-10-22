-- 2026-10-22_1915_void_test_preview_sheet_1149.sql
-- Trello 8IBiZL5Z (Railway breach), a cleanup of my own test artefact, found by the post-rotation verification.
--
-- HAND REPAIR, and it says so (root CLAUDE.md section 7): it removes one row a test created; it closes no design.
--
-- At 2026-10-22 18:08:54Z the rotation session proved the new PDF_SERVICE_API_KEY end to end by calling
-- generate-derm-address-preview for visit 8860 (089-COW). Without disposal_facility_id that call takes the
-- Miami-Dade path, which allocates the next DERM Address number and records the sheet: Miami-Dade sheet 1149,
-- derm.address_sheets id 187 (pdf_bucket 'preview', one client, visit 8860). The rotation record wrongly said
-- the call "used no sheet number" (it checked derm.generated_visit_sheets, the Broward table). Nobody printed it,
-- no manifest carries number 1149, no ticket links it, no scan read names it.
-- Why it matters: it is the only unlinked generated sheet whose client set is exactly {089-COW}, so
-- derm.fn_resolve_generated_sheet_for_ticket could bind a future 089-COW-only ticket to it before that ticket's
-- sheet-number read lands. The resolver skips soft-deleted sheets (10 "deleted_at is null" filters in its body).
--
-- Change: soft-delete row 187 (deleted_at). Never a hard delete (rule 6). derm.address_sheets is audited, so the
-- UPDATE is recorded with the old row. Number 1149 stays used: sequence gaps from previews are expected
-- (pdf-service CLAUDE.md rule 5). Rollback: update derm.address_sheets set deleted_at = null where id = 187;
-- Future smoke tests of the preview path: use a visit id that does not exist (the pdf-service answers 404 before
-- any number is allocated), never a real visit.
begin;
set local lock_timeout = '3s';

do $guard$
begin
  if not exists (select 1 from derm.address_sheets s
                  where s.id = 187 and s.sheet_no = 1149 and s.pdf_bucket = 'preview' and s.deleted_at is null
                    and s.created_at between '2026-10-22 18:08:00+00' and '2026-10-22 18:10:00+00')
     or (select count(*) from derm.address_sheet_clients c where c.sheet_id = 187) <> 1
     or not exists (select 1 from derm.address_sheet_clients c where c.sheet_id = 187 and c.visit_id = 8860 and c.client_id = 57)
     or exists (select 1 from derm.address_sheet_manifests x where x.sheet_id = 187)
     or exists (select 1 from public.derm_manifests m where m.derm_address_no = 1149)
     or exists (select 1 from derm.address_sheet_scan_reads r where r.sheet_no_read ~ '^1149(-|$)') then
    raise exception 'sheet 187 is not the untouched test preview any more; stop and look';
  end if;
end
$guard$;

update derm.address_sheets set deleted_at = now() where id = 187 and deleted_at is null;

do $verify$
begin
  if not exists (select 1 from derm.address_sheets where id = 187 and deleted_at is not null) then
    raise exception 'VERIFY: sheet 187 not soft-deleted';
  end if;
  if (select count(*) from derm.address_sheets where deleted_at is null and pdf_bucket = 'preview' and id = 187) <> 0 then
    raise exception 'VERIFY: sheet 187 still live';
  end if;
end
$verify$;

commit;
