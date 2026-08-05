-- 2026-08-05_0122  automate the sheet-number OCR: targets RPC + Vault invoker + pg_cron
-- ============================================================================
-- WHY
-- ----------------------------------------------------------------------------
-- The sheet-number gate (2026-08-05_0023) is only as timely as its reader, and
-- the reader was a local Node script. A brand-new ticket was therefore covered
-- only by the causality guard until someone ran it by hand. Fred added
-- ANTHROPIC_API_KEY to the Supabase secrets so the reader can run as an edge
-- function on a schedule.
--
-- 🛑 Still reads only the number DERM already prints. Nothing is added to the
--    form (compliance document, Fred 2026-08-04). No QR, ever.
--
-- WHAT THIS ADDS
--   1. derm.fn_sheet_number_ocr_targets(p_limit) -- which scanned pages to read.
--      The selection logic lives in SQL so it can be tested in a transaction,
--      not inside a Deno handler.
--   2. public.fn_request_sheet_number_ocr() -- Vault-backed pg_cron invoker,
--      cloned from fn_request_blackout_sweep.
--   3. pg_cron job `sheet-number-ocr-sweep`, */10, limit 2.
--
-- TWO TRAPS ENCODED IN THE TARGETS FUNCTION (both cost a wrong result already)
--   * Page images MUST come from derm.ticket_page_images(), NOT
--     address_row_map.image_url. That column is stale: ticket 310429's page-2
--     rows point at address_1.jpeg (a naive read OCR'd page 1 twice and
--     reported 1072-1 for BOTH pages), and 831710's is the literal 'pending'
--     (so the one sheet that mattered was skipped entirely).
--   * Scope to tickets with at least one UNPLACED row. A fully-placed sheet can
--     never be auto-placed again, so reading it costs a vision call and changes
--     no decision. Measured at write time: 9 tickets / 14 unread pages, versus
--     ~114 scanned sheets if unscoped.
--
-- AUTH: the edge fn is verify_jwt=true AND asserts role=service_role in-handler.
--   verify_jwt alone is half a gate -- the anon key is a validly signed JWT.
--   The invoker sends a service_role bearer read from Vault
--   (`edge_invoke_service_key`), the pattern that replaced the fail-open
--   x-sync-key on 2026-07-29. No new shared secret is introduced.
--
-- ⚠ VERIFYING THIS: cron.job_run_details.status='succeeded' PROVES NOTHING.
--   pg_net is fire-and-forget and reports success once the queue insert commits,
--   so a 401/500 from the far end still records 'succeeded'. Read
--   net._http_response, and better, watch derm.address_sheet_scan_reads grow.
--
-- 3NF: no new columns. Audit: derm tables are not audited; the reads table
-- carries its own provenance (model, confidence, read_at).
-- ============================================================================

-- ⚠ FIX to 2026-08-05_0023: that migration did `revoke all ... from public, anon` and granted only
-- SELECT to `authenticated`, so it never granted the WRITER. service_role bypasses RLS but still
-- needs table privileges, and the edge function's first real run failed 42501 on the insert.
-- Supabase's ALTER DEFAULT PRIVILEGES did not cover it because the revoke stripped the PUBLIC grant.
-- Loud failure, correctly caught before the cron ever ran.
grant select, insert, update on derm.address_sheet_scan_reads to service_role;

create or replace function derm.fn_sheet_number_ocr_targets(p_limit int default 3)
returns table (dump_folder text, ticket text, page int, image_url text)
language sql
stable
security definer
set search_path to 'derm', 'public'
as $$
  with placeable as (
    -- A fully-placed sheet can never be auto-placed again: reading it changes no decision.
    select distinct r.dump_folder, r.white_manifest_number as ticket
      from derm.address_row_map r
     where r.white_manifest_number is not null
       and r.stamp_placed_at is null
       -- ⚠ ONLY `ticket-*` folders. The other shape is the historical 2026-07 batch-mapping set
       -- (`window<N>-sheet<M>`): 94 folders / 488 rows, and MEASURED: **zero** of them have a
       -- generated-sheet link, so none can ever auto-place and a read of one can never be used.
       -- Without this filter the sweep burns ~94 vision calls for nothing and writes noise -- the
       -- first run read `window12-sheet9` as "224", a 3-digit value no real sheet number has.
       -- It also makes the two gate branches agree: the candidate branch keys on
       -- 'ticket-' || p_ticket, which cannot match any other folder shape anyway.
       and r.dump_folder like 'ticket-%'
  )
  select p.dump_folder, p.ticket, g.ord::int as page, g.url as image_url
    from placeable p
    cross join lateral (
      -- ⚠ ticket_page_images(), never address_row_map.image_url -- see header.
      select ord, url
        from unnest(derm.ticket_page_images(p.ticket)) with ordinality as u(url, ord)
    ) g
   where g.url is not null
     and g.url <> 'pending'
     and not exists (select 1
                       from derm.address_sheet_scan_reads sr
                      where sr.dump_folder = p.dump_folder and sr.page = g.ord)
   order by p.dump_folder, g.ord
   limit greatest(1, least(coalesce(p_limit, 3), 10));
$$;

revoke all on function derm.fn_sheet_number_ocr_targets(int) from public, anon;
grant execute on function derm.fn_sheet_number_ocr_targets(int) to service_role;

comment on function derm.fn_sheet_number_ocr_targets(int) is
  'Scanned address-sheet pages still needing a sheet-number read, scoped to tickets that can still be '
  'auto-placed. Page images resolve via ticket_page_images() because address_row_map.image_url is stale.';

-- ============================================================================

create or replace function public.fn_request_sheet_number_ocr()
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare v_key text;
begin
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'edge_invoke_service_key';
  if v_key is null then
    raise warning 'edge_invoke_service_key vault secret missing; skipping sheet-number OCR sweep';
    return;
  end if;
  perform net.http_post(
    url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/ocr-address-sheet-number',
    headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||v_key),
    body := jsonb_build_object('limit', 2),
    timeout_milliseconds := 120000);
end; $$;

revoke all on function public.fn_request_sheet_number_ocr() from public, anon, authenticated;

comment on function public.fn_request_sheet_number_ocr() is
  'pg_cron invoker for ocr-address-sheet-number. Vault-backed service_role bearer, same pattern as '
  'fn_request_blackout_sweep. Deliberately NOT a bespoke shared secret (that pattern was fail-open).';

-- ============================================================================
-- */10 with limit 2: the edge CPU cap is why redact-manifest-sweep runs limit 1.
-- A vision call is ~2-4s, so 2 per run stays well inside the budget, and the
-- backlog (14 pages at write time) drains in about an hour.

select cron.schedule('sheet-number-ocr-sweep', '*/10 * * * *',
                     'SELECT public.fn_request_sheet_number_ocr()');
