-- 2026-11-19_1740 · 148-MOR: merge two duplicate GDO permits (Trello #227 `CfXqPkZH`, reopened 2026-11-19)
--
-- WHAT
--   Two permits of client 148-MOR exist twice, once with the extra leading zero DERM prints:
--     row 182 GDO-11226  (since 2026-06-11, PDF)          and row 307 GDO-011226 (renamed from GDO-014768 today)
--     row  59 GDO-14769  (since 2026-05-19, PDF, DERM rows) and row 311 GDO-014769 (typed today, no PDF)
--   `gdos_client_gdo_unique` and `client.upsert_gdo_permit` compare the exact text, so the zero got past both.
--   Measured: these are the only two in-client duplicates of 194 GDO numbers (audit + logs in the #227 card comment).
--
-- WHY / WHO DECIDED
--   Fred, 2026-11-19, on the question "How should I repair them?": "Merge by your rule (Recommended): Mark 311 and 307
--   Inactive (kept on record, PDFs kept); set 182 to 60 days". His rule of 2026-11-18: one permit per number, the
--   stricter cleaning frequency applies (the two restaurants' PDFs that carry GDO-011226 say 90 and 60 days).
--
-- THIS IS A ONE-TIME REPAIR, NOT THE RULE. The rule that stops a third copy (every GDO number stored as GDO- plus
--   6 digits, Fred the same day) is its own migration. 307 and 311 get "DEDUP" in their notes, so
--   `fn_gdos_guard_demoted` keeps them INACTIVE unless a later UPDATE changes the notes on purpose.
--
-- REACH CHECKED BEFORE: nothing points at 307 or 311 except one `gdo_permit_label_reads` row on 307 (0 manifests,
--   0 sheet rows, 0 leases, 0 submissions, 0 bot requests); 148-MOR has 0 items in the filing queue.
--   Backup (workspace, git-ignored): backups/2026-11-19_gdos_148MOR_merge_227.json
--   Audit: public.gdos is audited (audit_gdos), so every change below has its old row in audit.logs too.
--   Rollback: 2026-11-19_1740_gdos_148mor_merge_duplicate_permits_rollback.sql

do $merge$
declare
  v_n int;
begin
  -- Guards: each row must still be exactly what was read at 17:38 ET, or nothing changes.
  perform 1 from public.gdos where id = 182 and gdo_number = 'GDO-11226' and status = 'ACTIVE' and max_frequency_days = 90
    and client_id = (select id from public.clients where client_code = '148-MOR');
  if not found then raise exception 'guard: row 182 is not GDO-11226 ACTIVE 90 days of 148-MOR'; end if;
  perform 1 from public.gdos where id = 307 and gdo_number = 'GDO-011226' and status = 'ACTIVE'
    and client_id = (select id from public.clients where client_code = '148-MOR');
  if not found then raise exception 'guard: row 307 is not GDO-011226 ACTIVE of 148-MOR'; end if;
  perform 1 from public.gdos where id = 311 and gdo_number = 'GDO-014769' and status = 'EXPIRED'
    and client_id = (select id from public.clients where client_code = '148-MOR');
  if not found then raise exception 'guard: row 311 is not GDO-014769 EXPIRED of 148-MOR'; end if;

  update public.gdos
     set status = 'INACTIVE',
         notes = concat_ws(E'\n', nullif(notes, ''),
           'DEDUP 2026-11-19 (Trello #227): the same permit as row 182 (GDO-11226), typed with DERM''s extra leading zero. Merged by Fred''s rule: one permit per number.')
   where id = 307;
  get diagnostics v_n = row_count; if v_n <> 1 then raise exception 'row 307: % rows', v_n; end if;

  update public.gdos
     set status = 'INACTIVE',
         notes = concat_ws(E'\n', nullif(notes, ''),
           'DEDUP 2026-11-19 (Trello #227): the same permit as row 59 (GDO-14769), typed with DERM''s extra leading zero. Merged by Fred''s rule: one permit per number.')
   where id = 311;
  get diagnostics v_n = row_count; if v_n <> 1 then raise exception 'row 311: % rows', v_n; end if;

  update public.gdos
     set max_frequency_days = 60,
         notes = concat_ws(E'\n', nullif(notes, ''),
           '2026-11-19 (Trello #227): 60 days, the stricter of the two PDFs that carry this number (90 and 60). Merged with row 307.')
   where id = 182;
  get diagnostics v_n = row_count; if v_n <> 1 then raise exception 'row 182: % rows', v_n; end if;

  -- VERIFY: the merge landed, the guard holds, and 148-MOR keeps exactly one live permit per number.
  perform 1 from public.gdos where id in (307, 311) and status = 'INACTIVE' and notes ~ 'DEDUP' having count(*) = 2;
  if not found then raise exception 'verify: 307 and 311 are not both INACTIVE with DEDUP'; end if;
  perform 1 from public.gdos where id = 182 and status = 'ACTIVE' and max_frequency_days = 60;
  if not found then raise exception 'verify: 182 is not ACTIVE at 60 days'; end if;
  perform 1 from public.gdos where id = 59 and status = 'ACTIVE' and gdo_number = 'GDO-14769';
  if not found then raise exception 'verify: 59 changed'; end if;
  select count(*) into v_n from (
    select (regexp_match(gdo_number, '^GDO-([0-9]+)$'))[1]::bigint as num
      from public.gdos
     where client_id = (select id from public.clients where client_code = '148-MOR') and status <> 'INACTIVE'
     group by 1 having count(*) > 1) d;
  if v_n <> 0 then raise exception 'verify: 148-MOR still has % live numbers twice', v_n; end if;
end
$merge$;
