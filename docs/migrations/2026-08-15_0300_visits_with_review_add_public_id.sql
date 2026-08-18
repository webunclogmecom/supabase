-- ============================================================================
-- 2026-08-15_0300: expose visits.public_id on public.visits_with_review
-- ============================================================================
-- 🛑 THIS IS A PRODUCTION FIX FOR A REGRESSION I CAUSED MINUTES AGO.
-- The Admin Review "Open report" button (shipped 2026-08-15) links the Field Portal
-- record, which needs visits.public_id. I told the app to add public_id to its detail
-- select from `visits_with_review` WITHOUT checking that the view exposes it. It does
-- not. PostgREST rejects the whole select, the detail query returns nothing, and every
-- visit review screen rendered "Visit #<id> not found."
--
-- Confirmed before writing this: visit 7757 IS in the view (1 row) and IS in
-- public.visits (1 row), so nothing was missing except the column.
--
-- ⚠ THE LESSON: I verified the URL could be CONSTRUCTED (1043/1043 visits have a
-- public_id) but never checked that the column was reachable through the VIEW the app
-- actually reads. Data existing and data being reachable by the caller are different
-- questions, and only the second one matters to the app.
--
-- APPEND ONLY. CREATE OR REPLACE VIEW cannot reorder or insert a column mid-list
-- (42P16); appending at the end is the one safe edit, so public_id goes last.
-- Body otherwise copied verbatim from pg_get_viewdef, not retyped.
--
-- AUDIT (rule #8): a view, so no table changed and there is nothing to opt in or out of.
-- `public.visits` keeps its own audit trigger. Added 2026-08-18 after a documentation sweep
-- found this header was the one migration that quarter missing its rule-8 line.
-- ============================================================================

create or replace view public.visits_with_review as
 SELECT v.id,
    v.client_id,
    v.property_id,
    v.job_id,
    v.vehicle_id,
    v.visit_date,
    v.start_at,
    v.end_at,
    v.completed_at,
    v.duration_minutes,
    v.title,
    v.service_type,
    v.visit_status,
    v.actual_arrival_at,
    v.actual_departure_at,
    v.is_gps_confirmed,
    v.created_at,
    v.updated_at,
    v.invoice_id,
    v.completed_by,
    COALESCE(vr.review_status, 'pending'::text) AS review_status,
    vr.reviewed_at,
    vr.reviewed_by,
    COALESCE(vr.bonus_status, 'pending'::text) AS bonus_status,
    vr.bonus_decided_at,
    vr.bonus_decided_by,
    vr.bonus_denial_note,
    vr.quality_flag_note,
    v.public_id
   FROM visits v
     LEFT JOIN visit_reviews vr ON vr.visit_id = v.id;

do $do$
declare v_col int; v_row int; v_pid text; v_cols int;
begin
  select count(*) into v_col from information_schema.columns
   where table_schema='public' and table_name='visits_with_review' and column_name='public_id';
  if v_col <> 1 then raise exception 'public_id not exposed on the view'; end if;

  -- the exact row the app failed on
  select count(*), max(public_id) into v_row, v_pid from public.visits_with_review where id = 7757;
  if v_row <> 1 or v_pid is null then
    raise exception 'visit 7757 returns % row(s), public_id=%', v_row, coalesce(v_pid,'NULL');
  end if;

  -- POSITIVE CONTROL: nothing else moved. The view had 28 columns; it must now have 29,
  -- not fewer (a retyped body silently dropping a column is the documented failure mode).
  select count(*) into v_cols from information_schema.columns
   where table_schema='public' and table_name='visits_with_review';
  if v_cols <> 29 then raise exception 'view now has % columns, expected 29', v_cols; end if;

  raise notice 'public_id exposed; visit 7757 resolves; 29 columns intact';
end
$do$;
