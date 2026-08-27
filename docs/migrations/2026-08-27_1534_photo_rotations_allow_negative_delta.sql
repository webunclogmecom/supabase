-- 2026-08-27_1534_photo_rotations_allow_negative_delta.sql
--
-- FIX: rotating a photo LEFT in Admin Review failed with "Could not save the rotation", while
-- rotating right worked. Fred: "The rotation to the left is not working, it only works for
-- rotating to the right."
--
-- 🛑 A SELF-INFLICTED REGRESSION, introduced a few hours earlier the SAME DAY.
-- `requested_delta_cw` had always been fed `body.rotation_deg`, the ABSOLUTE angle, so it only ever
-- received 0/90/180/270 and this CHECK was never once exercised against a real delta. Earlier today
-- the service, the edge function and the app were changed so the column finally receives what its
-- NAME always promised: the reviewer's signed clockwise delta. A single rotate-left sends -90, the
-- CHECK rejected it, the failed INSERT aborted the whole transaction, and the RPC raised. The photo
-- never moved and the reviewer got a save error.
--
-- ⚠ WHY ONLY THE LEFT BUTTON, AND ONLY ON ONE CLICK. The client normalises the accumulated delta
-- with `se > 180 ? se - 360 : se`, so:
--     1 left click  -> 270 -> -90    REJECTED, the reported bug
--     2 left clicks -> 180 ->  180   accepted
--     3 left clicks ->  90 ->   90   accepted
-- One left click was the only broken case, which is exactly how it presented.
--
-- ⚠ THE REUSABLE LESSON. Two mistakes, and the second is the one that let it ship:
--   1. I widened what a column RECEIVES without reading what that column ACCEPTS.
--   2. I then "verified" the change with a single rotate-RIGHT click, which sends +90. A positive
--      delta can never exercise the newly-reachable negative range, so the test could not have
--      failed. A test that cannot fail is not evidence. The verify block below therefore asserts
--      the case that WAS broken, and carries a control that must still be rejected.
--
-- `absolute_rotation_deg` and `pixel_rotation_cw` are deliberately NOT widened. Those are absolute
-- angles, and 0/90/180/270 is the correct domain for them. Only the delta column is signed.

begin;

alter table public.photo_rotations
  drop constraint if exists photo_rotations_requested_delta_cw_check;

alter table public.photo_rotations
  add constraint photo_rotations_requested_delta_cw_check
  check (requested_delta_cw = any (array[-270, -180, -90, 0, 90, 180, 270]));

-- ─── VERIFY ───────────────────────────────────────────────────────────────────────────────────
do $$
declare
  bad text := '';
  n_before int;
  n_after int;
begin
  select count(*) into n_before from public.photo_rotations;

  -- 1. THE BUG ITSELF: the single-rotate-left delta must now be accepted.
  begin
    insert into public.photo_rotations (
      photo_id, from_storage_path, to_storage_path,
      requested_delta_cw, absolute_rotation_deg, pixel_rotation_cw, engine)
    values (23212, '__probe_from__', '__probe_to__', -90, 270, 270, 'verify');
    raise exception '__probe_rollback__';
  exception
    when check_violation then
      bad := bad || 'a -90 delta is STILL rejected; ';
    when others then
      if sqlerrm <> '__probe_rollback__' then
        bad := bad || 'unexpected error on the -90 probe: ' || sqlerrm || '; ';
      end if;
  end;

  -- 2. and the other two negatives the service and edge function accept
  begin
    insert into public.photo_rotations (
      photo_id, from_storage_path, to_storage_path,
      requested_delta_cw, absolute_rotation_deg, pixel_rotation_cw, engine)
    values (23212, '__probe_from__', '__probe_to2__', -180, 180, 180, 'verify');
    raise exception '__probe_rollback__';
  exception
    when check_violation then
      bad := bad || 'a -180 delta is rejected; ';
    when others then
      if sqlerrm <> '__probe_rollback__' then
        bad := bad || 'unexpected error on the -180 probe: ' || sqlerrm || '; ';
      end if;
  end;

  -- 3. 🛑 CONTROL. The check must still REJECT a value outside the domain, otherwise "it accepts
  --    -90 now" would be indistinguishable from "the constraint stopped enforcing anything".
  begin
    insert into public.photo_rotations (
      photo_id, from_storage_path, to_storage_path,
      requested_delta_cw, absolute_rotation_deg, pixel_rotation_cw, engine)
    values (23212, '__probe_from__', '__probe_to3__', 45, 90, 90, 'verify');
    bad := bad || 'CONTROL FAILED: 45 was accepted, so the check is no longer enforcing anything; ';
    raise exception '__probe_rollback__';
  exception
    when check_violation then
      null;  -- correct: 45 is not a quarter turn
    when others then
      if sqlerrm <> '__probe_rollback__' then
        bad := bad || 'unexpected error on the control probe: ' || sqlerrm || '; ';
      end if;
  end;

  -- 4. none of the probes actually wrote a row
  select count(*) into n_after from public.photo_rotations;
  if n_after <> n_before then
    bad := bad || 'the probes wrote ' || (n_after - n_before) || ' row(s); ';
  end if;

  if bad <> '' then
    raise exception 'negative-delta verification FAILED: %', bad;
  end if;
  raise notice 'verified: -90 and -180 accepted, 45 still rejected, nothing written';
end $$;

commit;
