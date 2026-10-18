-- ============================================================================
-- 2026-10-18_0230_no_stamp_on_a_page_without_a_scan
-- A stamp is never placed on a page that has no scan, and a completed sheet with an unpublished copy is named in
-- the health email.
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-18, "go ahead", on: "Sheet 836361 was completed Oct 1, but one client's blacked-out copy was
--   never made. A check exists for exactly this, but nothing reads it."
-- WHY (measured)
--   ticket-836361 (generated sheet, 6 clients over 2 printed pages) has ONE scan. On 2026-09-22 09:05 ET
--   trg_autoplace_generated placed 288-PER (card 3001, printed row 6 = page 2) at stamp_page 2: with no sheet-number
--   read, derm.fn_sheet_image_position fell back to identity and answered 2, a page the ticket has no image of
--   (stamp_image_url NULL; v_stamp_placement_health STAMP_PAGE_PAST_END). The publish gate skips cards on a missing
--   page, a person marked the sheet complete on 2026-10-01, 5 copies were made in 20 minutes and 288-PER's never.
--   derm.v_blackout_completed_unpublished saw it; nothing reads that view. blackout-health counted it only inside
--   customer_impact ("work orders without a file"), so the health email never named the sheet.
-- WHAT CHANGES
--   derm.fn_sheet_image_position: the identity fallback returns NULL past the end of the ticket's image list
--     (derm.ticket_page_images). Every caller already refuses on NULL (the placement trigger, the resolver, Step A,
--     the finisher, fn_ensure_permit_cards), so such a card stays unplaced, shows in the Studio as waiting and keeps
--     the sheet from completing until the page is uploaded. Unchanged for every page that has a scan (VERIFY).
--   public.log_blackout_health: each folder of v_blackout_completed_unpublished becomes a health item (blocker
--     completed_not_published) with the clients and what to do; it sets attention.
-- NOT DONE: 288-PER's copy needs page 2 of the paper. The office uploads it in the DERM Tracker; the photo arrival
--   reopens the sheet for a check (trg_zx_generated_sheet_return_review) and the Studio takes it from there.
-- Rule 8: no table. ROLLBACK: 2026-10-18_rollback_no_stamp_on_a_page_without_a_scan.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_functiondef('derm.fn_sheet_image_position(text,integer)'::regprocedure)) IS DISTINCT FROM 'c965bd26a19c15fa6080e5830951d71d'
     OR md5(pg_get_functiondef('public.log_blackout_health()'::regprocedure)) IS DISTINCT FROM 'd26d366652807e7150421992ddd128e2' THEN
    RAISE EXCEPTION 'a function changed since this file was written: splice again';
  END IF;
END $g$;
-- every (folder, page) the system can ask about: pages 1 .. max(stamp_page, image count) + 1, per folder
CREATE TEMP TABLE sip_before ON COMMIT DROP AS
  SELECT f.dump_folder, g.p, derm.fn_sheet_image_position(f.dump_folder, g.p) AS pos,
         coalesce(array_length(derm.ticket_page_images(f.ticket), 1), 0) AS n_img
    FROM (SELECT r.dump_folder, max(r.white_manifest_number) AS ticket, max(coalesce(r.stamp_page, r.page)) AS mx
            FROM derm.address_row_map r GROUP BY 1) f
   CROSS JOIN LATERAL generate_series(1, greatest(f.mx, coalesce(array_length(derm.ticket_page_images(f.ticket), 1), 0)) + 1) g(p);
CREATE TEMP TABLE views_before ON COMMIT DROP AS
  SELECT 'band' AS v, to_jsonb(b) AS j FROM derm.v_band_edge_check b
  UNION ALL SELECT 'await', to_jsonb(a) FROM derm.v_cards_awaiting_page_map a
  UNION ALL SELECT 'health', to_jsonb(h) FROM derm.v_stamp_placement_health h;
CREATE TEMP TABLE acl_before ON COMMIT DROP AS SELECT p.oid, p.proacl::text AS acl, p.prosecdef FROM pg_proc p
 WHERE p.oid IN ('derm.fn_sheet_image_position(text,integer)'::regprocedure, 'public.log_blackout_health()'::regprocedure);

CREATE OR REPLACE FUNCTION derm.fn_sheet_image_position(p_dump_folder text, p_logical_page integer)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
declare
  v_pos      int;
  v_has_map  boolean;
  v_ticket   text;
begin
  if p_dump_folder is null or p_logical_page is null or p_logical_page < 1 then
    return null;
  end if;

  -- an exact, high-confidence match: this printed page IS at this image position
  select sr.page into v_pos
    from derm.address_sheet_scan_reads sr
   where sr.dump_folder = p_dump_folder
     and sr.confidence  = 'high'
     and sr.sheet_no_read ~ '-[0-9]+$'
     and split_part(sr.sheet_no_read, '-', 2)::int = p_logical_page
   order by sr.page
   limit 1;

  if v_pos is not null then
    return v_pos;
  end if;

  -- No match. Does this folder have a page map AT ALL? If it does, the map is CLOSED and this page
  -- is genuinely unknown: refuse rather than fall back to a coincidence.
  select exists (
    select 1 from derm.address_sheet_scan_reads sr
     where sr.dump_folder = p_dump_folder
       and sr.confidence  = 'high'
       and sr.sheet_no_read ~ '-[0-9]+$'
  ) into v_has_map;

  if v_has_map then
    return null;     -- caller MUST refuse
  end if;

  -- No evidence either way: identity. This is the pre-2026-08-06 behaviour and the majority case,
  -- and it MUST stay a no-op.
  --
  -- ⚠ A page-count bound was written here and REMOVED, because it was wrong and the control caught it.
  -- It derived the folder's image count from `count(distinct address_row_map.page)`, on the assumption
  -- that `page` enumerates the images. It does not: ticket-831938's cards all carry `page = 1` while
  -- its stamps legitimately span stamp_page 1 and 2, so the bound returned NULL for page 2 of a
  -- two-page sheet and put 3 of 29 already-correct AI rows into disagreement with the map.
  -- `address_row_map.image_url` is separately known to be STALE, so it is not a substitute source.
  -- There is no cheap, trustworthy per-folder page count here, and an unreliable bound is worse than
  -- none: the closed-world rule above is what actually prevents a wrong page, and it needs no count.
  -- 2026-10-18: ...but never a page the ticket has NO SCAN of. ticket-836361 (2026-09-22): the generated sheet
  -- printed 288-PER on page 2, only page 1 was ever uploaded, identity answered 2, the stamp was placed on a page
  -- that does not exist, the sheet was completed without it, and 288-PER never got its blacked-out copy. The bound
  -- is the ticket's own image list (derm.ticket_page_images, the list stamp_page indexes), NOT
  -- count(distinct address_row_map.page), the wrong source that made the earlier bound above fail. The ticket comes
  -- from the folder's cards, or from the folder name when the first card is still being inserted (the BEFORE
  -- INSERT placement trigger calls this before its row exists).
  select max(r.white_manifest_number) into v_ticket from derm.address_row_map r where r.dump_folder = p_dump_folder;
  v_ticket := coalesce(v_ticket, substring(p_dump_folder from '^ticket-(.+)$'));
  if p_logical_page > coalesce(array_length(derm.ticket_page_images(v_ticket), 1), 0) then
    return null;     -- no scan of this page yet: the caller refuses and the card waits
  end if;
  return p_logical_page;
end;
$function$;

CREATE OR REPLACE FUNCTION public.log_blackout_health()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'derm', 'pg_temp'
AS $function$
declare
  v_sheets    int := 0;
  v_clients   int := 0;
  v_manifests int := 0;
  v_oldest    interval;
  v_detail    jsonb;
  v_impact    int := 0;
  v_impact_by jsonb;
  v_attn      boolean := false;
  v_unpub     jsonb;
begin
  select count(*),
         coalesce(sum(clients_blocked), 0),
         coalesce(sum(manifests_blocked), 0),
         max(blocked_for)
    into v_sheets, v_clients, v_manifests, v_oldest
    from derm.v_blackout_blocked_sheets;

  -- THE CUSTOMER-FACING NUMBER. Independent of stamping, so it sees the sheets the
  -- blocked-sheets view is blind to.
  select count(*) into v_impact
    from customer.work_orders w
   where w.derm_manifest_number is not null
     and w.derm_manifest_url is null;

  select coalesce(jsonb_agg(jsonb_build_object('ticket', t, 'work_orders', n) order by n desc), '[]'::jsonb)
    into v_impact_by
    from (select w.derm_manifest_number t, count(*) n
            from customer.work_orders w
           where w.derm_manifest_number is not null and w.derm_manifest_url is null
           group by 1) s;

  -- attention if EITHER measure is non-zero. A customer without a viewable document
  -- matters whether or not the sheet behind it happens to be stamped.
  v_attn := (v_sheets > 0) or (v_impact > 0);

  select coalesce(jsonb_agg(jsonb_build_object(
           'dump_folder',       b.dump_folder,
           'blocker',           b.blocker,
           'what_to_do',        b.what_to_do,
           'stamped_rows',      b.stamped_rows,
           'stamped_pages',     b.stamped_pages,
           'rows_ready',        b.rows_ready,
           'rows_no_stamp_ts',  b.rows_no_stamp_ts,
           'clients_blocked',   b.clients_blocked,
           'manifests_blocked', b.manifests_blocked,
           'blocked_for',       b.blocked_for::text) order by b.last_stamp_at), '[]'::jsonb)
    into v_detail
    from derm.v_blackout_blocked_sheets b;

  -- 2026-10-18: a COMPLETED sheet with a client whose blacked-out copy was never made is an item of its own, named,
  -- with what to do. ticket-836361 sat 16 days counted only inside customer_impact ("1 work order without a file"),
  -- never as an item, because derm.v_blackout_blocked_sheets lists only sheets that are not completed. The folders
  -- come from derm.v_blackout_completed_unpublished (its own rule); the sentence names the clients and says when the
  -- cause is a page that was never uploaded (derm.fn_card_page_missing).
  select coalesce(jsonb_agg(jsonb_build_object(
           'dump_folder',     u.dump_folder,
           'blocker',         'completed_not_published',
           'clients_blocked', u.clients_affected,
           'blocked_for',     u.completed_for::text,
           'what_to_do',      x.what_to_do) order by u.completed_at), '[]'::jsonb)
    into v_unpub
    from derm.v_blackout_completed_unpublished u
    cross join lateral (
      select case
               when bool_or(p.missing) then
                 'Page ' || string_agg(distinct p.pg::text, ', ') filter (where p.missing)
                 || ' of this sheet was never uploaded, so ' || string_agg(distinct p.code, ', ') filter (where p.missing)
                 || ' has no blacked-out copy. Upload that page in the DERM Tracker; the sheet then comes back to the Stamp Studio to be checked.'
               else string_agg(distinct p.code, ', ')
                 || ' has no blacked-out copy although the sheet is completed. Tell the Supabase session: the blackout sweep did not produce it.'
             end as what_to_do
        from (select coalesce(r.stamp_page, r.page) as pg, coalesce(c.client_code, r.manual_code, '?') as code,
                     derm.fn_card_page_missing(r.white_manifest_number, coalesce(r.stamp_page, r.page)) as missing
                from derm.address_row_map r
                left join public.clients c on c.id = r.matched_client_id
               where r.dump_folder = u.dump_folder
                 and r.matched_manifest_id is not null and r.matched_client_id is not null and r.stamp_placed_at is not null
                 and exists (select 1 from manifest_visits mv join visits v on v.id = mv.visit_id and v.deleted_at is null
                              where mv.manifest_id = r.matched_manifest_id)
                 and not exists (select 1 from derm.redacted_manifest_docs d
                                  where d.manifest_id = r.matched_manifest_id and d.effective_page = coalesce(r.stamp_page, r.page))) p
    ) x;
  v_detail := v_detail || v_unpub;
  v_attn := v_attn or jsonb_array_length(v_unpub) > 0;

  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('blackout-health', now(), now(), greatest(v_sheets, v_impact),
          case when v_attn then 'attention' else 'ok' end,
          jsonb_build_object(
            'blocked_sheets',    v_sheets,
            'clients_blocked',   v_clients,
            'manifests_blocked', v_manifests,
            'oldest_blocked_for', v_oldest::text,
            'completed_unpublished', jsonb_array_length(v_unpub),
            'sheets',            v_detail,
            'customer_impact',   jsonb_build_object(
                                   'work_orders_without_file', v_impact,
                                   'by_ticket',                v_impact_by),
            'what_it_means',     case when v_attn
              then 'TWO DIFFERENT NUMBERS, do not conflate them. customer_impact.work_orders_without_file is how many customer work orders show a DERM number with no viewable file - the customer-facing truth, independent of stamping. blocked_sheets counts sheets that are STAMPED BUT UNMEASURED, which is the Stamp Studio work queue and is BLIND to unstamped sheets. On 2026-08-24 they were 22 and 2. Read the per-sheet blocker and what_to_do for the remedy: it is NOT always a measurement pass. blocker=held_by_constraint means DELIBERATELY frozen and measuring it would re-open a cross-client leak; blocker=no_stamp_timestamp needs a re-stamp in the Studio. NOTE the customer card is not blank - it renders "On file, not available for online viewing", per Field Portal rule 8.'
              else 'Every stamped address-sheet page has a measured extent, and every customer work order with a DERM number has a viewable file.' end));

  return greatest(v_sheets, v_impact);
end $function$;

DO $v$
DECLARE n int; n_ctl int; v_list text; v_items jsonb;
BEGIN
  -- 1. every answer is unchanged, except an answer pointing past the last image, which is now NULL. (A printed
  --    page number may exceed the image count legitimately: ticket-831220's only scan reads "1063-2", so printed
  --    page 2 IS image 1. The rule is about the image position answered.)
  SELECT count(*) FILTER (WHERE (b.pos IS NULL OR b.pos <= b.n_img) AND derm.fn_sheet_image_position(b.dump_folder, b.p) IS DISTINCT FROM b.pos),
         count(*) FILTER (WHERE b.pos > b.n_img)
    INTO n, n_ctl FROM sip_before b;
  IF n <> 0 THEN RAISE EXCEPTION 'VERIFY 1: % answers moved that pointed at a real image', n; END IF;
  IF n_ctl = 0 THEN RAISE EXCEPTION 'VERIFY 1b: no past-the-end answer existed: the check proves nothing'; END IF;
  IF EXISTS (SELECT 1 FROM sip_before b WHERE derm.fn_sheet_image_position(b.dump_folder, b.p) > b.n_img) THEN
    RAISE EXCEPTION 'VERIFY 1c: an answer still points past the last image';
  END IF;
  IF derm.fn_sheet_image_position('ticket-836361', 2) IS NOT NULL OR derm.fn_sheet_image_position('ticket-836361', 1) IS DISTINCT FROM 1
     OR derm.fn_sheet_image_position('ticket-838681', 2) IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'VERIFY 1d: controls';
  END IF;
  -- 2. the first card of a folder (no card yet) still gets page 1: the ticket comes from the folder name
  <<first>>
  BEGIN
    DELETE FROM derm.address_row_map WHERE dump_folder = 'ticket-836361';
    RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = coalesce(derm.fn_sheet_image_position('ticket-836361', 1)::text, 'null')
      || '|' || coalesce(derm.fn_sheet_image_position('ticket-836361', 2)::text, 'null');
  EXCEPTION WHEN SQLSTATE 'P0099' THEN
    IF SQLERRM <> '1|null' THEN RAISE EXCEPTION 'VERIFY 2: first-card answers %', SQLERRM; END IF;
  END first;
  -- 3. the three views that call it: only the past-the-end folders may differ
  SELECT string_agg(DISTINCT coalesce(x.j->>'dump_folder', '?'), ', ') INTO v_list FROM (
    (SELECT v, j FROM views_before EXCEPT ALL
       (SELECT 'band', to_jsonb(b) FROM derm.v_band_edge_check b UNION ALL SELECT 'await', to_jsonb(a) FROM derm.v_cards_awaiting_page_map a
        UNION ALL SELECT 'health', to_jsonb(h) FROM derm.v_stamp_placement_health h))
    UNION ALL
    ((SELECT 'band', to_jsonb(b) FROM derm.v_band_edge_check b UNION ALL SELECT 'await', to_jsonb(a) FROM derm.v_cards_awaiting_page_map a
      UNION ALL SELECT 'health', to_jsonb(h) FROM derm.v_stamp_placement_health h) EXCEPT ALL SELECT v, j FROM views_before)) x;
  IF v_list IS NOT NULL AND v_list NOT IN ('ticket-315808', 'ticket-836361', 'ticket-315808, ticket-836361') THEN
    RAISE EXCEPTION 'VERIFY 3: dependent views changed for %', v_list;
  END IF;
  -- 4. the health item: run the logger, read its row, undo it
  <<hl>>
  BEGIN
    PERFORM public.log_blackout_health();
    SELECT details->'sheets' INTO v_items FROM public.sync_log WHERE sync_source = 'blackout-health' ORDER BY id DESC LIMIT 1;
    RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = v_items::text;
  EXCEPTION WHEN SQLSTATE 'P0099' THEN v_items := SQLERRM::jsonb;
  END hl;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) e
                  WHERE e->>'dump_folder' = 'ticket-836361' AND e->>'blocker' = 'completed_not_published'
                    AND e->>'what_to_do' LIKE 'Page 2 of this sheet was never uploaded, so 288-PER has no blacked-out copy.%') THEN
    RAISE EXCEPTION 'VERIFY 4: the 836361 item is missing: %', v_items;
  END IF;
  IF EXISTS (SELECT 1 FROM acl_before b JOIN pg_proc p ON p.oid = b.oid WHERE p.proacl::text IS DISTINCT FROM b.acl OR p.prosecdef IS DISTINCT FROM b.prosecdef) THEN
    RAISE EXCEPTION 'VERIFY 5: privileges or security mode moved';
  END IF;
  RAISE NOTICE 'VERIFY passed (views changed for: %)', coalesce(v_list, 'none');
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
