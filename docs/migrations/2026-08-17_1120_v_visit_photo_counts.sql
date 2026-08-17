-- ============================================================================
-- 2026-08-17_1120 — per-visit photo counts, so the queue stops hitting the
-- PostgREST 1000-row cap and silently under-reporting
-- ============================================================================
-- 🛑 THE BUG THIS EXISTS TO KILL. The Admin Review queue builds its "Photos n/m"
-- chip by fetching EVERY photo_links row for the 28-day window and counting them
-- client-side. Measured 2026-08-17: that window holds 1,428 rows and PostgREST
-- caps a response at 1,000 by default, silently, with no error and no truncation
-- signal. So 428 rows never arrive.
--   56 visits displayed "Photos 0/N"   (every one of their links was past the cap)
--    1 visit  displayed a partial count
--   = 57 of 191 queue visits, 30%, showing a wrong count.
-- It hits the NEWEST visits, because the cap cuts by id order, which is exactly
-- the set a reviewer is working on. Visit 7751 has 17 classified images and read
-- "Photos 0/8"; its first link sits at position 1,197.
--
-- ⚠ A HIGHER .limit() IS NOT THE FIX. The window grows, so a bump only moves the
-- cliff. The fix is to stop shipping per-photo rows to a browser that only wants
-- two integers per visit.
--
-- 3NF: nothing stored, both counts derived on read.
-- Audit (rule 8): a view holds no data; the underlying photo_links carries its own
-- audit trigger (2026-08-14_0500) and is untouched here.
-- Grants: authenticated only, mirroring how the app reads photo_links today. NOT
-- anon: the queue is staff-only and `anon` reads nothing on this surface.
-- ============================================================================

create or replace view public.v_visit_photo_counts as
select l.entity_id                                   as visit_id,
       count(*) filter (where p.content_type like 'image/%')                        as total_images,
       count(*) filter (where p.content_type like 'image/%' and c.photo_link_id is not null) as classified_images
from public.photo_links l
join public.photos p on p.id = l.photo_id
left join public.photo_classifications c on c.photo_link_id = l.id
where l.entity_type = 'visit'
  and l.deleted_at is null
group by l.entity_id;

comment on view public.v_visit_photo_counts is
  'Per-visit image counts for the Admin Review queue chip. Exists because fetching raw photo_links hit the PostgREST 1000-row cap and silently under-reported 57 of 191 visits. Counts IMAGES only, matching the classifier and the emailed report.';

revoke all on public.v_visit_photo_counts from anon;
grant select on public.v_visit_photo_counts to authenticated;

do $do$
declare v_7751 record; v_rows int; v_anon boolean; v_authn boolean;
begin
  select * into v_7751 from public.v_visit_photo_counts where visit_id = 7751;
  if v_7751.total_images <> 17 then
    raise exception 'control failed: visit 7751 should have 17 images, view says %', v_7751.total_images;
  end if;
  if v_7751.classified_images <> 17 then
    raise exception 'control failed: visit 7751 should have 17 classified, view says %', v_7751.classified_images;
  end if;

  select count(*) into v_rows from public.v_visit_photo_counts;
  if v_rows < 100 then raise exception 'only % rows; the view looks broken', v_rows; end if;

  v_anon  := has_table_privilege('anon','public.v_visit_photo_counts','SELECT');
  v_authn := has_table_privilege('authenticated','public.v_visit_photo_counts','SELECT');
  if v_anon then raise exception 'anon can read the queue photo counts'; end if;
  if not v_authn then raise exception 'authenticated cannot read the view'; end if;

  raise notice '7751 = %/% images, % visit rows, anon=% authenticated=%',
    v_7751.classified_images, v_7751.total_images, v_rows, v_anon, v_authn;
end
$do$;
