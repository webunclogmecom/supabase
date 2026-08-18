-- 2026-08-18_1900_unlink_misplaced_august_photos.sql
--
-- WHY -----------------------------------------------------------------------------------------
-- Fred, 2026-08-18, after the August photo placement audit
-- (`docs/audits/2026-08-18_august_photo_placement_audit.md`): "yes unlink the 17".
--
-- That audit checked all 820 image links on August 2026 visits against two signals stronger than
-- the one the pipeline uses, both compared against each visit's [start_at, completed_at] WINDOW
-- rather than its visit_date. 745 were correct, 41 misplaced, 34 undecidable. Of the 41, three
-- clusters were high-confidence and one (043-MIL Mila, 24 links) was not and is excluded.
--
-- 🛑 ONLY 16 OF THE 17 ARE UNLINKED HERE. Link 42263 is DELIBERATELY LEFT ALONE.
-- Photo 22954 (155-PV) has exactly ONE alive visit link, so unlinking it would DELETE a client's
-- photo rather than move it. Correcting that one needs a MOVE (insert on 7802, then unlink from
-- 7770), which is a different operation from the one approved. Flagged to Fred, not performed.
--
-- WHAT IS BEING CHANGED ------------------------------------------------------------------------
-- 16 `photo_links` rows soft-deleted via `public.soft_delete_photo_link`, which records
-- `deleted_at`, `deleted_by` and `deleted_reason` and is reversible.
--
--   155-PV Pura Vida Flamingo  (8) 42253 42255 42257 42259 42261 42265 42267  -> belong to 7802
--                              (1) 42303                                      -> belongs to 7770
--   000-DH Homestead Dump      (2) 39589 39591                                -> belong to 7469
--                              (3) 40598 40600 40602                          -> belong to 7682
--   235-LOU Skinny Louie WPB   (3) 41000 41002 41004                          -> belong to 7735
--
-- ⚠ NOTHING IS LOST. Verified per row before writing: each of the 16 photos is ALREADY alive on the
-- visit it belongs to (`alive_links_total = 2`, one of which is the target). Only the wrong link goes.
--
-- ⚠ NO CLIENT SEES A CHANGE. All 16 are UNCLASSIFIED, so none appears in `customer.wo_photos`.
-- Measured: classified = 0 on all 16, against a fleet-wide control of 700 classified links. The value
-- of doing this now is preventing someone classifying them later, which is the only way a misplaced
-- photo becomes a disclosure.
--
-- WHY THESE THREE CLUSTERS AND NOT MILA --------------------------------------------------------
-- 155-PV, 000-DH and 235-LOU all show the same clean signature: the Jobber note `createdAt` lands
-- essentially exactly on one visit's `completed_at` while the link points at a different visit.
--     7770 completed 08-17 10:06 ET, note stamp 08-17 10:06
--     7802 completed 08-18 07:01 ET, note stamp 08-18 07:01
--     7469 completed 08-02 22:06 ET, note stamp 08-02 22:06
--     7682 completed 08-04 21:38 ET, note stamp 08-04 21:38
-- One of the 235-LOU rows is additionally confirmed by real camera EXIF, the only one of the 41 that is.
--
-- 🛑 Mila (043-MIL) is excluded because **visit 7757 has physically impossible timestamps**:
-- `start_at` 08-14 19:45 ET, `completed_at` 08-14 15:17 ET, i.e. completed 4.5 h before it started.
-- A containment test can never be true for that visit, so 12 of its 24 flags rest on nearest-distance
-- with no window to confirm them, and the other 12 inherit the doubt. It needs the timestamps resolved
-- first, and see the note below: they are wrong in JOBBER, not here.
--
-- AUDIT (rule #8): `public.photo_links` carries an audit trigger since
-- `2026-08-14_0500_photo_links_soft_delete_and_audit.sql`, so all 16 UPDATEs land in `audit.logs`
-- with `old_row` intact and are individually revertible.
-- ============================================================================================

begin;

do $fix$
declare
  ids bigint[] := array[42253,42255,42257,42259,42261,42265,42267,42303,
                        39589,39591,40598,40600,40602,
                        41000,41002,41004];
  n_before int; n_after int; n_classified int; n_orphaned int;
begin
  -- pre-state: all 16 must be alive right now
  select count(*) into n_before from public.photo_links
   where id = any(ids) and deleted_at is null;
  if n_before <> 16 then
    raise exception 'ABORT: expected 16 alive links, found %. Someone else changed this; re-audit.', n_before;
  end if;

  -- 🛑 CONTROL: none may be classified. A classified link is published, and unlinking it would
  -- change what a client sees, which is not what was approved.
  select count(*) into n_classified
    from public.photo_links l join public.photo_classifications pc on pc.photo_link_id = l.id
   where l.id = any(ids);
  if n_classified <> 0 then
    raise exception 'ABORT: % of these links are classified, so they are published. Stop and re-check.', n_classified;
  end if;

  -- 🛑 CONTROL: every photo must survive on another visit. This is the check that makes the
  -- difference between MOVING a photo and DESTROYING it.
  select count(*) into n_orphaned
    from public.photo_links l
   where l.id = any(ids)
     and (select count(*) from public.photo_links l2
           where l2.photo_id = l.photo_id and l2.entity_type='visit'
             and l2.deleted_at is null and l2.id <> l.id) = 0;
  if n_orphaned <> 0 then
    raise exception 'ABORT: % photos would be left with no alive visit link. Refusing to delete a photo.', n_orphaned;
  end if;

  perform public.soft_delete_photo_link(
            id,
            'wrong visit: August 2026 placement audit, note createdAt matches another visit of the same job')
    from unnest(ids) as id;

  select count(*) into n_after from public.photo_links where id = any(ids) and deleted_at is null;
  if n_after <> 0 then
    raise exception 'ABORT: % links still alive after the soft delete', n_after;
  end if;

  raise notice 'unlinked % misplaced August photo links, 0 classified, 0 orphaned', n_before;
end $fix$;

commit;
