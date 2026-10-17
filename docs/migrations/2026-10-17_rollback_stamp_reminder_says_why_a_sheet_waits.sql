-- ROLLBACK of 2026-10-17_1330_stamp_reminder_says_why_a_sheet_waits: derm.fn_stamp_open_sheets back to its body before that migration (no 'reason'), then drop
-- derm.fn_stamp_sheet_wait_reason. The edge function ignores a missing 'reason', so it may stay deployed.
BEGIN;
SET LOCAL lock_timeout = '3s';
CREATE OR REPLACE FUNCTION derm.fn_stamp_open_sheets()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  select coalesce(jsonb_agg(jsonb_build_object(
           'manifest', s.white_manifest_number,
           'service_date', s.service_date,
           'dump_date', s.dump_date,
           'placed', s.placed_rows,
           'total', s.total_rows,
           'pages', s.page_count,
           'status', case when s.placed_rows > 0 then 'In progress' else 'Not started' end,
           'days_waiting', (now() at time zone 'America/New_York')::date - coalesce(s.dump_date, s.service_date))
         order by coalesce(s.dump_date, s.service_date) nulls last, s.white_manifest_number), '[]'::jsonb)
    from derm.v_stamp_sheets s
    -- 2026-10-12: the clients the sheet names (its live manifests and its cards) and how many of them are test or
    -- fixture clients (public.fn_is_non_customer, the shared registry). A manifest with no client, or a card known only
    -- by its manual code, counts as a real client, so this can never hide a real sheet.
    cross join lateral (
      select count(*) as named,
             count(*) filter (where public.fn_is_non_customer(c.client_id, array['test', 'fixture'])) as test
        from (select m.client_id from public.derm_manifests m
               where coalesce(m.white_manifest_number, m.yellow_ticket_number) = s.white_manifest_number
                 and m.deleted_at is null
              union all
              select r.matched_client_id from derm.address_row_map r
               where r.white_manifest_number = s.white_manifest_number
                 and (r.matched_client_id is not null or r.manual_code is not null)) c) k
   where not s.completed
     -- a sheet whose clients are ALL test or fixture clients is not posted: the real post tags Diego and Serena
     and not (k.named > 0 and k.test = k.named);
$function$;

DROP FUNCTION derm.fn_stamp_sheet_wait_reason(text);
DO $v$ BEGIN
  IF md5(pg_get_functiondef('derm.fn_stamp_open_sheets()'::regprocedure)) <> '8e1d35966330e2ace60303a088f74d96' THEN
    RAISE EXCEPTION 'rollback VERIFY: body differs from the pre-migration one';
  END IF;
END $v$;
NOTIFY pgrst, 'reload schema';
COMMIT;
