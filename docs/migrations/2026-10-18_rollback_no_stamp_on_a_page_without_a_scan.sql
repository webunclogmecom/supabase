-- ROLLBACK of 2026-10-18_0230_no_stamp_on_a_page_without_a_scan: both bodies back to before that migration.
BEGIN;
SET LOCAL lock_timeout = '3s';
CREATE OR REPLACE FUNCTION derm.fn_sheet_image_position(p_dump_folder text, p_logical_page integer)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
declare
  v_pos      int;
  v_has_map  boolean;
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

  insert into public.sync_log (sync_source, started_at, finished_at, rows_errored, status, details)
  values ('blackout-health', now(), now(), greatest(v_sheets, v_impact),
          case when v_attn then 'attention' else 'ok' end,
          jsonb_build_object(
            'blocked_sheets',    v_sheets,
            'clients_blocked',   v_clients,
            'manifests_blocked', v_manifests,
            'oldest_blocked_for', v_oldest::text,
            'sheets',            v_detail,
            'customer_impact',   jsonb_build_object(
                                   'work_orders_without_file', v_impact,
                                   'by_ticket',                v_impact_by),
            'what_it_means',     case when v_attn
              then 'TWO DIFFERENT NUMBERS, do not conflate them. customer_impact.work_orders_without_file is how many customer work orders show a DERM number with no viewable file - the customer-facing truth, independent of stamping. blocked_sheets counts sheets that are STAMPED BUT UNMEASURED, which is the Stamp Studio work queue and is BLIND to unstamped sheets. On 2026-08-24 they were 22 and 2. Read the per-sheet blocker and what_to_do for the remedy: it is NOT always a measurement pass. blocker=held_by_constraint means DELIBERATELY frozen and measuring it would re-open a cross-client leak; blocker=no_stamp_timestamp needs a re-stamp in the Studio. NOTE the customer card is not blank - it renders "On file, not available for online viewing", per Field Portal rule 8.'
              else 'Every stamped address-sheet page has a measured extent, and every customer work order with a DERM number has a viewable file.' end));

  return greatest(v_sheets, v_impact);
end $function$;

DO $v$ BEGIN
  IF md5(pg_get_functiondef('derm.fn_sheet_image_position(text,integer)'::regprocedure)) <> 'c965bd26a19c15fa6080e5830951d71d'
     OR md5(pg_get_functiondef('public.log_blackout_health()'::regprocedure)) <> 'd26d366652807e7150421992ddd128e2' THEN
    RAISE EXCEPTION 'rollback VERIFY: bodies differ';
  END IF;
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
