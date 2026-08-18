-- 2026-08-17_2130_visit_photo_counts_reopened.sql
--
-- WHY -----------------------------------------------------------------------------------------
-- Defect D2: someone classifies every photo on a visit, the "Send email to City" button appears,
-- then one more photo arrives and the visit silently reverts to un-sendable. No notification. The
-- only symptom is a button that is no longer there.
--
-- Fred, 2026-08-17, chose the fix: a 48 hour settling window on the send (in
-- `send-visit-photos-email`), plus Option A, an in-app treatment in the Admin Review queue so a
-- visit that WAS finished and came undone looks different from one that was never started.
-- Those two states are currently indistinguishable and they need different actions from a person.
--
-- This migration is the data half of Option A. The app cannot compute "reopened" itself: it would
-- need every photo's arrival time AND every classification's write time, which is exactly what this
-- view already joins.
--
-- 🛑 WHAT "REOPENED" MEANS, AND WHAT IT DOES NOT ------------------------------------------------
-- Reopened = an alive, UNCLASSIFIED image whose `created_at` is LATER than the visit's most recent
-- classification. The arrival-time comparison is the whole point.
--
-- It is NOT the same as "partially classified". A visit where someone tagged 5 of 10 photos and
-- stopped is an abandoned half-done job, not a reopened one, and it needs a different response.
-- Today the two sets happen to coincide (of 914 visits with alive images, 851 have zero
-- classifications, 61 are fully classified, and exactly 2 sit in between, which are the 2 reopened
-- ones), so a lazy "0 < classified < total" test would look correct right now and drift the moment
-- anyone leaves a visit half-tagged.
--
-- MEASURED BEFORE WRITING THIS (and re-measured by an independent pass told to refute it):
--   3 visits fleet-wide have ever been reopened: 6086 (self-healed), 6587, 6835.
--   ⚠ The "only 2" figure everyone quoted is what you get by searching for visits that are
--     CURRENTLY broken; 6086 was fixed two days later and is invisible to that search.
--   ⚠ 3 is bounded by classification adoption (57 of 642 eligible visits have ever been fully
--     classified), NOT by the defect's frequency. Measured with an instrument that ignores
--     classification entirely, 21 to 48 visits show the same arrival pattern.
--
-- WHAT CHANGES ---------------------------------------------------------------------------------
-- `public.v_visit_photo_counts` gains FOUR columns, appended after the existing three:
--     last_classified_at        timestamptz  when the most recent image classification was written
--     last_image_at             timestamptz  when the most recent image arrived
--     late_unclassified_images  bigint       images that arrived after last_classified_at, untagged
--     is_reopened               boolean      late_unclassified_images > 0
--
-- The existing three columns (visit_id, total_images, classified_images) keep their names, types,
-- order and VALUES. The image predicate is unchanged (`content_type like 'image/%'`,
-- `deleted_at is null`, `entity_type = 'visit'`), which matters because
-- `send-visit-photos-email` gates on the SAME predicate; a chip computed from a different rule is
-- exactly how the green "Photos 4/4" on a blocked visit arose last week.
--
-- 🛑 CREATE OR REPLACE, NOT DROP + CREATE. `DROP VIEW` discards grants, and this view carries
-- `authenticated:SELECT` (the Admin Review app) and `yannick_readonly:SELECT`. REPLACE preserves
-- them. It also means columns can only be APPENDED, never inserted mid-list, which is why the four
-- new ones are last.
--
-- The view is owner-rights (no `security_invoker` in reloptions), owner `postgres`. Unchanged.
--
-- AUDIT (rule #8): a view. No table changed, so there is nothing to opt in or out of.
--
-- ⚠ PRE-EXISTING ODDITY, DELIBERATELY NOT TOUCHED: `authenticated` holds INSERT / UPDATE / DELETE /
-- TRUNCATE on this view as well as SELECT. It is a grouped view over a join and therefore not
-- updatable, so those grants are inert, but they are wider than they should be. Out of scope here;
-- flagged for a separate permissions pass rather than bundled into a D2 fix.

begin;

create or replace view public.v_visit_photo_counts as
with links as (
  select l.entity_id                     as visit_id,
         l.created_at                    as arrived_at,
         c.created_at                    as classified_at,
         (p.content_type like 'image/%') as is_image,
         (c.photo_link_id is not null)   as is_classified
  from public.photo_links l
    join public.photos p on p.id = l.photo_id
    left join public.photo_classifications c on c.photo_link_id = l.id
  where l.entity_type = 'visit'
    and l.deleted_at is null
),
agg as (
  select visit_id,
         count(*) filter (where is_image)                   as total_images,
         count(*) filter (where is_image and is_classified) as classified_images,
         max(classified_at) filter (where is_image)         as last_classified_at,
         max(arrived_at)    filter (where is_image)         as last_image_at
  from links
  group by visit_id
),
late as (
  select l.visit_id,
         count(*) as late_unclassified_images
  from links l
    join agg a on a.visit_id = l.visit_id
  where l.is_image
    and not l.is_classified
    and a.last_classified_at is not null
    and l.arrived_at > a.last_classified_at
  group by l.visit_id
)
select a.visit_id,
       a.total_images,
       a.classified_images,
       a.last_classified_at,
       a.last_image_at,
       coalesce(lt.late_unclassified_images, 0)     as late_unclassified_images,
       coalesce(lt.late_unclassified_images, 0) > 0 as is_reopened
from agg a
  left join late lt on lt.visit_id = a.visit_id;

comment on view public.v_visit_photo_counts is
  'Per-visit image counts using the SAME predicate as send-visit-photos-email. '
  'is_reopened = an unclassified image arrived AFTER the most recent classification (defect D2). '
  'Not the same as partially classified, which is an abandoned half-done job.';

commit;
