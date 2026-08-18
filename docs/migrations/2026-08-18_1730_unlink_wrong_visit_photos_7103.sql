-- 2026-08-18_1730_unlink_wrong_visit_photos_7103.sql
--
-- WHY -----------------------------------------------------------------------------------------
-- Fred, 2026-08-18, after the photo attribution audit: "Do step 1."
--
-- Visit 7103 (152-DAV, 2026-07-14) publishes SEVEN photos that are not its own. Every one of them
-- is also linked to visit 7083 (152-DAV, 2026-07-13), which is where they were taken. 7103 has NO
-- photos of its own, so 100% of what the client sees on its 07-14 page is the 07-13 service event.
--
-- Measured before the write, straight off the client-facing view (`customer.wo_photos`, keyed on
-- `work_order_id = visits.public_id`):
--     7083  vqQ4UExiN4  2026-07-13   6 photos visible
--     7103  rz1Rr3OoXT  2026-07-14   6 photos visible   <- the SAME six
-- The client is shown one day's work twice, under two dates.
--
-- 🛑 THIS IS NOT A CROSS-CLIENT LEAK. The full audit
-- (`docs/audits/2026-08-18_photo_attribution_audit.md`) measured ZERO photos spanning two clients,
-- ever, including soft-deleted links, and proved the detector fires by injecting a deliberate
-- cross-client link inside a rolled-back transaction. 152-DAV is seeing its OWN photos on the wrong
-- day. The harm is narrower than a leak and still real: 7103 is DERM-required with a manifest, so a
-- compliance record for 07-14 is illustrated with 07-13's work.
--
-- WHAT IS BEING CHANGED ------------------------------------------------------------------------
-- Seven `photo_links` rows on visit 7103 are SOFT-DELETED via `public.soft_delete_photo_link`,
-- which records `deleted_at`, `deleted_by` and `deleted_reason` and is reversible.
--
--     36117 21341 TC_00064.jpeg  before     36123 21344 TC_00068.jpeg  after
--     36119 21342 TC_00065.jpeg  before     36125 21345 TC_00069.jpeg  after
--     36121 21343 TC_00067.jpeg  before     36127 21346 TC_00070.jpeg  after
--     36129 21347 TC_00071.jpeg  internal
--
-- Six carry a publishing phase and are what the client sees; the seventh is `internal` and already
-- hidden. All seven are removed, because all seven are equally foreign to 7103. Removing only the
-- visible ones would leave the same defect in a state that no longer shows up in an audit of the
-- published surface, which is how this class of problem goes quiet without being fixed.
--
-- ⚠ NOTHING IS LOST. Every one of the seven photos remains alive on visit 7083, its real visit.
-- The `photos` rows and the storage objects are untouched; only the link to the wrong visit goes.
--
-- ⚠ EXPECTED VISIBLE EFFECT: 7103's Field Portal gallery goes from 6 photos to EMPTY. That is a
-- visible change for the client and it is the correct state: that visit genuinely has no photos.
-- Do not "restore" it by relinking.
--
-- AUDIT (rule #8): `public.photo_links` gained an audit trigger on 2026-08-14
-- (`2026-08-14_0500_photo_links_soft_delete_and_audit.sql`), so all seven UPDATEs land in
-- `audit.logs` with `old_row` intact and are individually revertible.
--
-- REHEARSED FIRST, rolled back, with the controls that had to fire:
--   CONTROL  7103 must currently show > 0 photos, or the probe proves nothing   -> fired at 6
--            7103 ends at 0                                                     -> pass
--   🛑 CONTROL  7083 must be COMPLETELY UNCHANGED (these are its own photos)     -> 6 -> 6, pass
--            exactly 6 rows leave `customer.wo_photos` fleet-wide               -> pass
--
-- NOT DONE HERE, deliberately:
--   * The other 22 wrong-visit classified links stay. They sit on visits where `derm_required` is
--     false while `fn_visit_requires_derm` returns TRUE, so they are hidden by a value that a
--     person can flip in DERM Tracker in one click. Cleaning them is a separate, larger decision.
--   * 98 of the 405 surplus links CANNOT be confidently assigned to a visit. A wrong unlink deletes
--     a client's real photo, so those are left alone.
--   * No ownership rule is applied fleet-wide. Fred already ruled on 2026-08-14: "yes keep the ones
--     inside the 2 day window", and a nearest-note-wins sweep would delete 214 links he kept.
-- ============================================================================================

begin;

do $fix$
declare n_before int; n_after int; n_7083 int;
begin
  select count(*) into n_before from customer.wo_photos where work_order_id = 'rz1Rr3OoXT';
  if n_before = 0 then
    raise exception 'ABORT: 7103 already shows 0 photos. Someone else changed this; re-audit first.';
  end if;

  perform public.soft_delete_photo_link(id, 'wrong visit: belongs to visit 7083 (2026-07-13), attribution audit 2026-08-18')
    from unnest(array[36117,36119,36121,36123,36125,36127,36129]::bigint[]) as id;

  select count(*) into n_after from customer.wo_photos where work_order_id = 'rz1Rr3OoXT';
  select count(*) into n_7083  from customer.wo_photos where work_order_id = 'vqQ4UExiN4';

  if n_after <> 0 then
    raise exception 'ABORT: expected 7103 to end at 0 photos, got %', n_after;
  end if;
  if n_7083 <> 6 then
    raise exception 'ABORT: 7083 must still show its own 6 photos, got %', n_7083;
  end if;

  raise notice '7103 % -> %, 7083 holds % (unchanged)', n_before, n_after, n_7083;
end $fix$;

commit;
