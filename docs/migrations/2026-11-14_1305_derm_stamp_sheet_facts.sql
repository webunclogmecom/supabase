-- 2026-11-14_1305_derm_stamp_sheet_facts.sql
--
-- WHAT
-- ----
-- New derm.stamp_sheet_facts(p_dump_folder text) RETURNS jsonb, STABLE SECURITY DEFINER, empty search_path: one read for
-- what the stamping screen says after Mark completed and on a reopened sheet. Returns
--   {completed, completed_at, completed_by, reopened_at, reopened_by, copies}
-- where copies is the Manifests row's OWN copies fact for the sheet, taken from derm.fn_manifest_row_states_core() (the
-- row whose sheets list the folder), so the row and the screen cannot disagree: JSON null when no copy is missing,
-- "Copies being made" with "N of M" for 20 minutes after completion, else the words of a missing copy. NULL for a folder
-- that is neither a status row nor a sheet of any row.
-- Gate: hr.fn_require_app('stamp_studio', 'view'), then the staff check of derm.manifest_row_states(), word for word.
-- Grants by name: authenticated + service_role, never PUBLIC or anon. Read only.
--
-- WHY
-- ---
-- derm.stamp_sheet_status holds completed_by, reopened_at and reopened_by but has RLS on and no policy, so a signed-in
-- read returns 0 rows, and derm.v_stamp_sheets carries completed_at only (spec M4); derm.redacted_manifest_docs is not
-- readable by authenticated at all. The new screen (Fred, 2026-11-12, pick C "really good, exactly what wanted", and
-- 2026-11-14 "Yes" to building it) asks this every 3 seconds after Mark completed until every stamped client has a copy
-- or 2 minutes pass, and shows on a reopened sheet "This sheet was completed before. The copies already made keep being
-- served until you complete it again." Plan row S4 of `Building Apps/Ops Portal/docs/specs/2026-11-14-stamping-screen-
-- build-plan.md`.
--
-- REACH
-- -----
-- Old Stamp host: none. Nothing existing changes.
--
-- APPLIED 2026-11-14 about 13:00 ET. REHEARSED (rolled back, ~12:58 ET): on all 169 completed sheets the function's
-- copies equals the core's row for that sheet and its completed / completed_by / completed_at / reopened_by equal the
-- status row (169 equal, 0 differ; 21.7 s for 169 calls, about 130 ms each). A signed-in Stamp editor reads #111111; a
-- field person (Stamp Studio none) is refused with the access sentence; CONTROL: with the gate line removed inside the
-- transaction, the same field person gets the facts. An unknown folder answers NULL; anon cannot execute it. Rollback
-- (DROP FUNCTION) rehearsed in the same transaction.
-- Rollback: 2026-11-14_rollback_derm_stamp_sheet_facts.sql.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $g$
BEGIN
  IF to_regprocedure('derm.stamp_sheet_facts(text)') IS NOT NULL THEN RAISE EXCEPTION 'GUARD: derm.stamp_sheet_facts already exists'; END IF;
  IF md5(replace(pg_get_functiondef('derm.manifest_row_states()'::regprocedure), chr(13), '')) <> 'ff7778cd3fb4ec915a6dd56ce2629a1c'
    THEN RAISE EXCEPTION 'GUARD: derm.manifest_row_states (the gate copied here) changed since it was read'; END IF;
  IF md5(replace(pg_get_functiondef('derm.fn_manifest_row_states_core()'::regprocedure), chr(13), '')) <> 'a0b27ae6ce7a2d19d2322b4ef3ce1df1'
    THEN RAISE EXCEPTION 'GUARD: derm.fn_manifest_row_states_core changed since it was read'; END IF;
END $g$;

CREATE FUNCTION derm.stamp_sheet_facts(p_dump_folder text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
-- 2026-11-14 (Ops Portal Stage D, S4): what the stamping screen says after Mark completed and on a reopened sheet.
-- derm.stamp_sheet_status has RLS on and no policy, so a signed-in read of it returns 0 rows; this is its one read.
-- copies = the Manifests row's OWN copies fact for the sheet (derm.fn_manifest_row_states_core(), the row's rule), so the
-- row and the screen never disagree: absent when no copy is missing, "being made" for 20 minutes after completion,
-- else the words of a missing copy. Never re-derive it here. NULL for a folder that is neither a sheet nor a row.
declare
  v_s    record;
  v_row  jsonb;
begin
  -- the gate: View on Stamp Studio, then the staff check of derm.manifest_row_states(), word for word
  perform hr.fn_require_app('stamp_studio', 'view');
  if nullif(current_setting('request.jwt.claims', true), '') is not null
     and coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    if auth.uid() is null then
      raise exception 'authentication required' using errcode = '28000';
    end if;
    if not public.fn_is_staff_email(lower(coalesce(auth.jwt() ->> 'email', ''))) then
      raise exception 'not a staff account' using errcode = '42501';
    end if;
  end if;

  select s.completed, s.completed_at, s.completed_by, s.reopened_at, s.reopened_by into v_s
    from derm.stamp_sheet_status s where s.dump_folder = p_dump_folder;

  -- the row whose sheets list this folder (one row per folder on 2026-11-14: 171 of 171)
  select e.value into v_row
    from jsonb_each(derm.fn_manifest_row_states_core()) e
   where exists (select 1 from jsonb_array_elements(e.value -> 'sheets') x where x ->> 'folder' = p_dump_folder)
   order by e.key
   limit 1;

  if v_s is null and v_row is null then
    return null;
  end if;
  return jsonb_build_object(
    'completed',    coalesce(v_s.completed, false),
    'completed_at', v_s.completed_at,
    'completed_by', v_s.completed_by,
    'reopened_at',  v_s.reopened_at,
    'reopened_by',  v_s.reopened_by,
    'copies',       v_row -> 'copies');
end
$function$;

REVOKE ALL ON FUNCTION derm.stamp_sheet_facts(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION derm.stamp_sheet_facts(text) TO authenticated, service_role;
COMMENT ON FUNCTION derm.stamp_sheet_facts(text) IS 'Stamping screen facts for one sheet (2026-11-14, Stage D S4): completed / reopened who and when, and the Manifests row''s own copies fact from derm.fn_manifest_row_states_core(). Stamp Studio View + staff.';

DO $v$
BEGIN
  IF (SELECT array_agg(x ORDER BY x) FROM (SELECT coalesce(nullif(a.grantee, 0)::regrole::text, 'PUBLIC') || ':' || a.privilege_type AS x
        FROM pg_proc p CROSS JOIN LATERAL aclexplode(p.proacl) a WHERE p.oid = 'derm.stamp_sheet_facts(text)'::regprocedure) acl)
     IS DISTINCT FROM ARRAY['authenticated:EXECUTE','postgres:EXECUTE','service_role:EXECUTE']
    THEN RAISE EXCEPTION 'VERIFY: derm.stamp_sheet_facts grants are not authenticated + service_role'; END IF;
  IF NOT (SELECT prosecdef AND provolatile = 's' AND proconfig = array['search_path=""'] FROM pg_proc WHERE oid = 'derm.stamp_sheet_facts(text)'::regprocedure)
    THEN RAISE EXCEPTION 'VERIFY: not SECURITY DEFINER, STABLE, with an empty search_path'; END IF;
END $v$;

COMMIT;
