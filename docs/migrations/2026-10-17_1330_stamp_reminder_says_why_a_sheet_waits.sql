-- ============================================================================
-- 2026-10-17_1330_stamp_reminder_says_why_a_sheet_waits
-- The 11 AM Stamp Studio Slack post says, for each open sheet, what it is waiting for.
-- ============================================================================
-- THE ASK
--   Fred, 2026-10-17, "go ahead with all of them", on: "The system should say when it gives up. I'd add each stuck
--   sheet and its plain reason to the 11 AM Stamp Studio Slack post, for example '838681 page 1: a client is
--   printed on several rows'. Then a stuck sheet gets seen the next morning, not when you happen to open it."
--   ticket-838681 had been refused by the finisher since 2026-10-14 and the post listed it with no reason.
-- WHAT CHANGES
--   NEW derm.fn_stamp_sheet_wait_reason(folder): one short sentence. It READS the Studio's answers (Slack guide rule
--     3b): the finisher's last refusal on each page that derm.fn_sheet_publishable_detail says still needs its bands
--     or Limit (the same ledger rows and filter as the "Cannot complete yet" banner), else the first sentence of
--     derm.fn_publishable_hint for the blocker, prefixed with its pages; "ready: press Mark completed" when nothing
--     blocks; NULL when only stamps are missing (the line already says "N of M stamped").
--   derm.fn_stamp_open_sheets: each sheet gains 'reason'; nothing else moves (VERIFY). The edge function
--     stamp-sheets-reminder adds it at the end of the sheet's line, escaped.
--   Measured over the 155 sheets of derm.v_stamp_sheets (as if all were open): 150 "ready", 1 "page 1: some stamps
--   on this page are not in a client row", 2 stamps never placed or confirmed, 1 only stamps missing, and the
--   838681 state of this morning (rebuilt in a rolled-back run) reads "page 1: a client on this page is printed on
--   several rows".
-- Rule 8: no table. ROLLBACK: 2026-10-17_rollback_stamp_reminder_says_why_a_sheet_waits.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_functiondef('derm.fn_stamp_open_sheets()'::regprocedure)) IS DISTINCT FROM '8e1d35966330e2ace60303a088f74d96' THEN
    RAISE EXCEPTION 'derm.fn_stamp_open_sheets changed since this file was written: splice again';
  END IF;
  IF to_regprocedure('derm.fn_stamp_sheet_wait_reason(text)') IS NOT NULL THEN RAISE EXCEPTION 'already exists'; END IF;
END $g$;
CREATE TEMP TABLE open_before ON COMMIT DROP AS SELECT derm.fn_stamp_open_sheets() AS j,
  (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'derm.fn_stamp_open_sheets()'::regprocedure) AS acl;

-- What an open sheet is waiting for, in one short plain sentence, for the 11 AM Slack post (Fred, 2026-10-17:
-- "838681 page 1: a client is printed on several rows"). It READS the Studio's own answers and never re-derives
-- them (slack guide rule 3b): the finisher's last refusal per page in derm.generated_measure_attempts, on the pages
-- derm.fn_sheet_publishable_detail says still need their bands or Limit (the same rows and the same filter its
-- "Cannot complete yet" banner shows), else the blocker's own sentence from derm.fn_publishable_hint. Only the
-- FIRST sentence is kept: the full instructions are in the Studio. NULL when the only thing missing is stamps
-- (the post already says "N of M stamped").
CREATE OR REPLACE FUNCTION derm.fn_stamp_sheet_wait_reason(p_dump_folder text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'derm', 'public'
AS $function$
  WITH d AS (
    SELECT derm.fn_sheet_publishable_detail(p_dump_folder) AS j
  ), pg AS (
    SELECT DISTINCT e::int AS p
      FROM d CROSS JOIN LATERAL jsonb_array_elements_text(
             coalesce(d.j->'pages_needing_bands', '[]'::jsonb) || coalesce(d.j->'pages_needing_extent', '[]'::jsonb)) e
  ), fin AS (
    SELECT string_agg('page ' || a.page || ': ' || lower(left(f.s, 1)) || substr(f.s, 2), '; ' ORDER BY a.page) AS r
      FROM derm.generated_measure_attempts a
      CROSS JOIN LATERAL (SELECT rtrim(split_part(btrim(a.last_reason), '. ', 1), '.') AS s) f
     WHERE a.dump_folder = p_dump_folder
       AND a.last_outcome IN ('refused', 'error')
       AND a.last_reason IS NOT NULL
       AND a.page IN (SELECT p FROM pg)
  ), h AS (
    SELECT rtrim(split_part(btrim(derm.fn_publishable_hint(d.j->>'blocker')), '. ', 1), '.') AS s FROM d
  )
  SELECT CASE
           WHEN (SELECT r FROM fin) IS NOT NULL THEN (SELECT r FROM fin)
           WHEN d.j->>'blocker' IS NULL THEN 'ready: press Mark completed'
           WHEN d.j->>'blocker' IN ('no_stamps', 'frozen_closed_world') THEN NULL
           WHEN d.j->>'blocker' IN ('needs_extent', 'needs_snap_then_extent') AND EXISTS (SELECT 1 FROM pg) THEN
             (SELECT CASE WHEN count(*) = 1 THEN 'page ' ELSE 'pages ' END || string_agg(p::text, ', ' ORDER BY p) FROM pg)
             || ': ' || (SELECT lower(left(s, 1)) || substr(s, 2) FROM h)
           ELSE (SELECT lower(left(s, 1)) || substr(s, 2) FROM h)
         END
    FROM d;
$function$;

REVOKE ALL ON FUNCTION derm.fn_stamp_sheet_wait_reason(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_stamp_sheet_wait_reason(text) TO service_role;
COMMENT ON FUNCTION derm.fn_stamp_sheet_wait_reason(text) IS 'What an open Stamp Studio sheet waits for, one short plain sentence for the 11 AM Slack post (Fred, 2026-10-17). Reads the finisher''s last refusal per page and derm.fn_sheet_publishable_detail / fn_publishable_hint (first sentence); NULL when only stamps are missing. Migration 2026-10-17_1330.';

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
           'days_waiting', (now() at time zone 'America/New_York')::date - coalesce(s.dump_date, s.service_date),
           -- 2026-10-17: what the sheet waits for, from the Studio's own answer (derm.fn_stamp_sheet_wait_reason)
           'reason', derm.fn_stamp_sheet_wait_reason(s.dump_folder))
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

DO $v$
DECLARE v_after jsonb; v_r text; v_ctl text;
BEGIN
  v_after := derm.fn_stamp_open_sheets();
  -- the same sheets with the same fields as before, plus 'reason'
  IF (SELECT coalesce(jsonb_agg(e - 'reason'), '[]'::jsonb) FROM jsonb_array_elements(v_after) e)
     IS DISTINCT FROM (SELECT j FROM open_before)
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_after) e WHERE NOT e ? 'reason') THEN
    RAISE EXCEPTION 'VERIFY 1: the list changed: before % after %', (SELECT j FROM open_before), v_after;
  END IF;
  -- positive control: this morning's 838681 (one Wynd 28 card, page 1 refused, not completed), rebuilt and undone
  <<ctl>>
  BEGIN
    DELETE FROM derm.address_row_map WHERE dump_folder = 'ticket-838681' AND matched_client_id = 233 AND gdo_id IN (231, 228);
    UPDATE derm.address_row_map SET band_y0_pct = NULL, band_y1_pct = NULL, band_source = NULL
     WHERE dump_folder = 'ticket-838681' AND stamp_page = 1;
    DELETE FROM derm.page_block_extents WHERE dump_folder = 'ticket-838681' AND effective_page = 1;
    UPDATE derm.generated_measure_attempts SET last_outcome = 'refused',
           last_reason = 'A client on this page is printed on several rows. Give it one card per permit and place each stamp on its own row, then measure the page with Draw the bands.'
     WHERE dump_folder = 'ticket-838681' AND page = 1;
    v_ctl := (SELECT e->>'reason' FROM jsonb_array_elements(derm.fn_stamp_open_sheets()) e WHERE e->>'manifest' = '838681');
    RAISE EXCEPTION USING ERRCODE = 'P0099', MESSAGE = coalesce(v_ctl, '(none)');
  EXCEPTION WHEN SQLSTATE 'P0099' THEN v_r := SQLERRM;
  END ctl;
  IF v_r IS DISTINCT FROM 'page 1: a client on this page is printed on several rows' THEN
    RAISE EXCEPTION 'VERIFY 2: the 838681 control reads %', v_r;
  END IF;
  IF (SELECT stamp_page FROM derm.address_row_map WHERE id = 3116) IS DISTINCT FROM 1
     OR (SELECT completed FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-838681') IS NOT TRUE THEN
    RAISE EXCEPTION 'VERIFY 3: the control was not undone';
  END IF;
  IF has_function_privilege('authenticated', 'derm.fn_stamp_sheet_wait_reason(text)', 'EXECUTE')
     OR has_function_privilege('anon', 'derm.fn_stamp_sheet_wait_reason(text)', 'EXECUTE')
     OR (SELECT p.proacl::text FROM pg_proc p WHERE p.oid = 'derm.fn_stamp_open_sheets()'::regprocedure) IS DISTINCT FROM (SELECT acl FROM open_before) THEN
    RAISE EXCEPTION 'VERIFY 4: privileges';
  END IF;
  RAISE NOTICE 'VERIFY passed (control: %)', v_r;
END $v$;

NOTIFY pgrst, 'reload schema';
COMMIT;
