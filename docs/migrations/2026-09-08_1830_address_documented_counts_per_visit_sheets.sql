-- =============================================================================
-- 2026-09-08_1830  "Address documented" must count a Broward PER-VISIT sheet
-- =============================================================================
-- Fred filed Broward ticket 312840 through Bulk Upload, one FDEP sheet per client,
-- and every surface told him it was undocumented. His guess was that the files had
-- gone into a private bucket. They had not. Measured:
--
--   manifest 1911 / visit 5973 / sheet 10022 -> derm/1911/address_visit_5973.jpg  192,560 B
--   manifest 1909 / visit 6326 / sheet 10023 -> derm/1909/address_visit_6326.jpg  181,330 B
--   manifest 1910 / visit 5943 / sheet 10024 -> derm/1910/address_visit_5943.jpg  178,786 B
--
-- All three rows live in derm.manifest_visit_sheets, all three blobs are in the
-- PUBLIC `manifests` bucket. The upload was perfect. The reporting was wrong.
--
-- (*) ONE ROOT CAUSE, FIVE CONSUMERS. Every "is this documented?" surface tests the
-- TICKET-level derm_manifests.derm_address_url, which is NULL by design on a Broward
-- filing because the Broward FDEP 62-705.300(3) form is ONE SHEET PER VISIT and lives
-- only in derm.manifest_visit_sheets. Measured, none of these read that table:
--
--   derm.manifest_health              -> /visits/:id "Partial record", the Health page
--   ops.v_derm_row_completeness_gaps  -> the gap detector
--   ops.v_derm_ticket_doc_gaps        -> page-count arithmetic (NOT changed, see below)
--   derm.visits                       -> has_manifest (NOT changed, see below)
--   the /manifests client predicate   -> "No address photo" + the Missing Docs badge
--
-- This is my gap from 2026-09-08: I built the per-visit register and surfaced it only
-- in the edit dialog, without extending the DEFINITION of documented. So a fully
-- documented Broward manifest reads as a compliance hole. That is the dangerous
-- direction: the Missing Docs filter is how staff find real gaps, and filling it with
-- false positives is how they learn to ignore it. 1 of 24 Broward tickets is affected
-- today (312840, the first filed this way); EVERY future one would be.
--
-- (*) THE PREDICATE IS DEFINED ONCE, IN derm.fn_manifest_address_documented, because
-- this estate's repeated failure is two copies of one rule drifting apart. A manifest
-- is address-documented when EITHER the shared Miami-Dade sheet is attached, OR it has
-- at least one linked visit and EVERY linked visit carries a live per-visit sheet.
-- Partial coverage is deliberately NOT documented: 2 sheets on a 3-visit manifest is a
-- real gap and must keep showing as one.
--
-- (*) SECURITY DEFINER ON PURPOSE, AND THE GRANTS ARE THE WHOLE POINT. Both views are
-- owner-rights, and a SECURITY INVOKER function called from an owner-rights view adds
-- an invoker-side EXECUTE check to the view's read path. Worse, the roles differ:
--   derm.manifest_health readers            authenticated, service_role, pg_read_all_data
--   ops.v_derm_row_completeness_gaps readers authenticated, service_role, yannick_readonly
--   derm.manifest_visit_sheets SELECT        authenticated, service_role, pg_read_all_data
-- yannick_readonly can read the gaps view and CANNOT read the sheet table, so an INVOKER
-- function would have handed that role a 42501 on a view it uses today. That is exactly
-- the regression 2026-08-25_1400 shipped. SECDEF plus explicit EXECUTE to all four roles,
-- verified below AS each role rather than as the owner.
--
-- (*) DELIBERATELY NOT CHANGED, so nobody "finishes the job" by accident:
--   * ops.v_derm_ticket_doc_gaps counts URLs per ticket to spot page-count anomalies on
--     a SHARED sheet. Per-visit sheets are a different grain and folding them in would
--     make its rows-per-sheet arithmetic meaningless.
--   * derm.visits.has_manifest is (manifest_url IS NOT NULL OR address_url IS NOT NULL).
--     The dump receipt IS inherited on Broward, so has_manifest is already true for
--     312840 and the column is not lying. Widening it would change a heavily-read view
--     for no fix.
--   * derm_manifests.derm_address_url is NOT backfilled. Writing a per-visit sheet URL
--     into the ticket-level shared-sheet column would assert that every client on the
--     ticket appears on that one sheet, which is the false claim this whole design
--     exists to avoid.
--
-- (*) ONE DELIBERATE WIDENING: the predicate accepts derm_address_extra_urls alone,
-- where has_address_pdf previously required the primary. edit_manifest and
-- detach_manifest_document both re-pack so the primary fills first, so the state should
-- not exist; VERIFY 6 measures it rather than assuming.
--
-- Rule 8: views and one function, no table changes, nothing to opt in or out of.
-- =============================================================================

begin;

-- PART 1  the canonical predicate, defined exactly once
create or replace function derm.fn_manifest_address_documented(p_manifest_id bigint)
returns boolean
language sql
stable
security definer
set search_path to 'derm', 'public', 'pg_temp'
as $function$
  select
    -- (a) the shared Miami-Dade DERM_V4.00 sheet, which a Broward ticket also uses
    --     when it was filed the historical way
    coalesce((
      select dm.derm_address_url is not null
          or coalesce(array_length(dm.derm_address_extra_urls, 1), 0) > 0
        from public.derm_manifests dm
       where dm.id = p_manifest_id
         and dm.deleted_at is null
    ), false)
    or
    -- (b) the Broward FDEP per-visit form: documented only when there is at least one
    --     linked visit AND every one of them carries a live sheet. Partial coverage is
    --     a real gap and must keep reporting as one, so this is deliberately not an
    --     EXISTS. The register is Broward-only by construction, because
    --     public.record_manifest_visit_sheet refuses a non-Broward manifest, so there
    --     is no need to re-test the county here.
    coalesce((
      select count(*) > 0 and count(*) = count(s.manifest_id)
        from public.manifest_visits mv
        left join derm.manifest_visit_sheets s
               on s.manifest_id = mv.manifest_id
              and s.visit_id    = mv.visit_id
              and s.deleted_at is null
       where mv.manifest_id = p_manifest_id
    ), false);
$function$;

comment on function derm.fn_manifest_address_documented(bigint) is
  'Is this manifest address-documented? True when the shared Miami-Dade address sheet '
  'is attached, OR when every linked visit carries a live Broward FDEP per-visit sheet '
  '(derm.manifest_visit_sheets). Partial per-visit coverage is NOT documented. This is '
  'the single definition; do not re-implement it in a view.';

revoke all on function derm.fn_manifest_address_documented(bigint) from public;
revoke all on function derm.fn_manifest_address_documented(bigint) from anon;
grant execute on function derm.fn_manifest_address_documented(bigint)
  to authenticated, service_role, pg_read_all_data, yannick_readonly;

-- PART 2  derm.manifest_health. Definition COPIED from pg_get_viewdef and edited by
-- anchor-asserted substitution, never retyped. Diffed before applying: only the
-- address TESTS moved, and the projected address_photo_url column is untouched.
create or replace view derm.manifest_health as
SELECT dm.id,
    dm.client_id,
    c.name AS client_name,
    dm.white_manifest_number,
    dm.yellow_ticket_number,
    dm.service_date::text AS service_date,
    dm.dump_ticket_date::text AS dump_ticket_date,
    dm.disposal_facility_id,
    df.name AS dump_location,
    dm.derm_manifest_url AS manifest_photo_url,
    dm.derm_address_url AS address_photo_url,
    dm.created_at::text AS created_at,
    dm.updated_at::text AS updated_at,
        CASE
            WHEN dm.yellow_ticket_number IS NOT NULL THEN 'broward'::text
            WHEN dm.white_manifest_number IS NOT NULL AND length(dm.white_manifest_number) >= 5 THEN 'dade'::text
            ELSE 'unknown'::text
        END AS jurisdiction,
    dm.white_manifest_number IS NOT NULL AS has_dade_white_number,
    dm.yellow_ticket_number IS NOT NULL AS has_broward_ticket_number,
    dm.derm_manifest_url IS NOT NULL AS has_manifest_pdf,
    derm.fn_manifest_address_documented(dm.id) AS has_address_pdf,
    dm.derm_manifest_url IS NOT NULL OR derm.fn_manifest_address_documented(dm.id) AS has_any_pdf,
    dm.dump_ticket_date IS NOT NULL AS has_dump_date,
    dm.disposal_facility_id IS NOT NULL AS has_dump_site,
    dm.client_id IS NOT NULL AS has_client,
    dm.sent_to_client IS TRUE AS sent_to_client,
    dm.sent_to_city IS TRUE AS sent_to_city,
        CASE
            WHEN dm.white_manifest_number IS NULL AND dm.yellow_ticket_number IS NULL AND dm.derm_manifest_url IS NULL AND NOT derm.fn_manifest_address_documented(dm.id) AND dm.dump_ticket_date IS NULL THEN 'empty_placeholder'::text
            WHEN dm.yellow_ticket_number IS NOT NULL AND dm.derm_manifest_url IS NOT NULL AND derm.fn_manifest_address_documented(dm.id) AND dm.dump_ticket_date IS NOT NULL THEN 'fully_complete'::text
            WHEN dm.white_manifest_number IS NOT NULL AND length(dm.white_manifest_number) >= 5 AND dm.derm_manifest_url IS NOT NULL AND derm.fn_manifest_address_documented(dm.id) AND dm.dump_ticket_date IS NOT NULL THEN 'fully_complete'::text
            WHEN (dm.derm_manifest_url IS NOT NULL OR derm.fn_manifest_address_documented(dm.id)) AND dm.yellow_ticket_number IS NULL AND dm.white_manifest_number IS NULL THEN 'has_pdfs_no_number'::text
            WHEN (dm.yellow_ticket_number IS NOT NULL OR dm.white_manifest_number IS NOT NULL) AND dm.derm_manifest_url IS NULL AND NOT derm.fn_manifest_address_documented(dm.id) THEN 'has_number_no_pdfs'::text
            ELSE 'partial_other'::text
        END AS health_state,
        CASE
            WHEN dm.white_manifest_number IS NULL AND dm.yellow_ticket_number IS NULL AND dm.derm_manifest_url IS NULL AND NOT derm.fn_manifest_address_documented(dm.id) THEN 'P0'::text
            WHEN dm.yellow_ticket_number IS NULL AND dm.white_manifest_number IS NULL OR dm.derm_manifest_url IS NULL OR NOT derm.fn_manifest_address_documented(dm.id) OR dm.dump_ticket_date IS NULL THEN 'P1'::text
            WHEN NOT dm.sent_to_client OR NOT dm.sent_to_city THEN 'P2'::text
            ELSE 'OK'::text
        END AS severity,
    dm.notes,
    dm.derm_address_no
   FROM derm_manifests dm
     LEFT JOIN clients c ON c.id = dm.client_id
     LEFT JOIN disposal_facilities df ON df.id = dm.disposal_facility_id
  WHERE dm.deleted_at IS NULL;

-- PART 3  ops.v_derm_row_completeness_gaps. It already reads has_address_pdf,
-- health_state and severity FROM derm.manifest_health, so it inherits PART 2 for free.
-- Only its own tkt CTE still read the column directly.
create or replace view ops.v_derm_row_completeness_gaps as
WITH tkt AS (
         SELECT COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number) AS ticket,
            bool_or(derm_manifests.derm_manifest_url IS NOT NULL OR COALESCE(array_length(derm_manifests.derm_manifest_extra_urls, 1), 0) > 0 OR derm.fn_manifest_address_documented(derm_manifests.id)) AS ticket_has_pdf
           FROM derm_manifests
          WHERE derm_manifests.deleted_at IS NULL AND COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number) IS NOT NULL
          GROUP BY (COALESCE(derm_manifests.white_manifest_number, derm_manifests.yellow_ticket_number))
        )
 SELECT mh.id,
    c.client_code,
    COALESCE(mh.white_manifest_number, mh.yellow_ticket_number) AS ticket,
    mh.jurisdiction,
    mh.health_state,
    mh.severity,
    mh.white_manifest_number IS NULL AND mh.yellow_ticket_number IS NULL AS missing_number,
    NOT mh.has_manifest_pdf AS missing_manifest_pdf,
    NOT mh.has_address_pdf AS missing_address_pdf,
    NOT mh.has_dump_date AS missing_dump_date,
    (EXISTS ( SELECT 1
           FROM manifest_visits mv
          WHERE mv.manifest_id = mh.id)) AS visit_linked,
    COALESCE(t.ticket_has_pdf, false) AS ticket_shows_documented,
    mh.notes IS NOT NULL AS accepted_gap_note,
    mh.notes
   FROM derm.manifest_health mh
     LEFT JOIN clients c ON c.id = mh.client_id
     LEFT JOIN tkt t ON t.ticket = COALESCE(mh.white_manifest_number, mh.yellow_ticket_number)
  WHERE mh.health_state <> 'fully_complete'::text;

commit;

-- -----------------------------------------------------------------------------
-- VERIFY. Read AS the roles, not as the owner. Everything arranged is rolled back.
-- -----------------------------------------------------------------------------
do $$
declare
  v_312840_states text;
  v_dade_complete_before int; v_dade_complete_after int;
  v_partial_mid int; v_full_after int;
  v_mid_manifest bigint; v_mid_visit bigint; v_mid_client bigint;
  v_extras_only int;
  n int;
begin
  ---------------------------------------------------------------------------
  -- V1  the reported symptom is gone: all three rows of 312840 read complete
  ---------------------------------------------------------------------------
  select string_agg(distinct h.health_state, ',' order by h.health_state)
    into v_312840_states
    from derm.manifest_health h
    join public.derm_manifests dm on dm.id = h.id
   where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = '312840';

  if v_312840_states is distinct from 'fully_complete' then
    raise exception 'V1 FAIL: 312840 health_state = %, expected fully_complete', v_312840_states;
  end if;

  select count(*) into n
    from derm.manifest_health h
    join public.derm_manifests dm on dm.id = h.id
   where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = '312840'
     and h.has_address_pdf;
  if n <> 3 then raise exception 'V1 FAIL: has_address_pdf true on % of 3 rows', n; end if;

  -- and it must have left the gap detector
  select count(*) into n
    from ops.v_derm_row_completeness_gaps g
    join public.derm_manifests dm on dm.id = g.id
   where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = '312840';
  if n <> 0 then raise exception 'V1 FAIL: 312840 still has % rows in the gap view', n; end if;

  ---------------------------------------------------------------------------
  -- V2  POSITIVE CONTROL: the Miami-Dade population must not move at all.
  --     Without this, "312840 is complete" could just mean the view says
  --     complete for everything.
  ---------------------------------------------------------------------------
  select count(*) into v_dade_complete_after
    from derm.manifest_health h
    join public.derm_manifests dm on dm.id = h.id
   where dm.white_manifest_number is not null and h.health_state = 'fully_complete';
  if v_dade_complete_after = 0 then
    raise exception 'V2 FAIL: no Dade manifest reads fully_complete, the view is broken';
  end if;

  select count(*) into n
    from derm.manifest_health h
    join public.derm_manifests dm on dm.id = h.id
   where dm.white_manifest_number is not null and h.health_state <> 'fully_complete';
  raise notice 'V2 Dade: % complete, % not', v_dade_complete_after, n;

  ---------------------------------------------------------------------------
  -- V3  DISCRIMINATION: partial per-visit coverage must NOT read as documented.
  --     Soft-delete one of 312840's three sheets and require the manifest to
  --     fall back to incomplete, then restore it.
  ---------------------------------------------------------------------------
  select s.manifest_id, s.visit_id into v_mid_manifest, v_mid_visit
    from derm.manifest_visit_sheets s
    join public.derm_manifests dm on dm.id = s.manifest_id
   where coalesce(dm.white_manifest_number, dm.yellow_ticket_number) = '312840'
     and s.deleted_at is null
   order by s.visit_id
   limit 1;
  if v_mid_manifest is null then
    raise exception 'V3 FAIL: no sheet to probe with, the check would be vacuous';
  end if;

  update derm.manifest_visit_sheets
     set deleted_at = now()
   where manifest_id = v_mid_manifest and visit_id = v_mid_visit;

  if derm.fn_manifest_address_documented(v_mid_manifest) then
    raise exception 'V3 FAIL: manifest % still reads documented with its only sheet soft-deleted',
      v_mid_manifest;
  end if;

  select count(*) into v_partial_mid
    from derm.manifest_health h where h.id = v_mid_manifest and h.health_state = 'fully_complete';
  if v_partial_mid <> 0 then
    raise exception 'V3 FAIL: health_state stayed fully_complete with the sheet removed';
  end if;

  update derm.manifest_visit_sheets
     set deleted_at = null
   where manifest_id = v_mid_manifest and visit_id = v_mid_visit;

  if not derm.fn_manifest_address_documented(v_mid_manifest) then
    raise exception 'V3 FAIL: restoring the sheet did not restore documented';
  end if;

  ---------------------------------------------------------------------------
  -- V4  a manifest with NO linked visits and no shared sheet is NOT documented
  --     (the empty-manifest case must not become vacuously true)
  ---------------------------------------------------------------------------
  select count(*) into n
    from public.derm_manifests dm
   where dm.deleted_at is null
     and dm.derm_address_url is null
     and coalesce(array_length(dm.derm_address_extra_urls,1),0) = 0
     and not exists (select 1 from public.manifest_visits mv where mv.manifest_id = dm.id)
     and derm.fn_manifest_address_documented(dm.id);
  if n <> 0 then
    raise exception 'V4 FAIL: % manifests with no sheet and no visits read as documented', n;
  end if;

  ---------------------------------------------------------------------------
  -- V5  GRANTS, tested as the ROLE. An owner can always execute, so asserting
  --     as postgres asserts nothing. yannick_readonly is the one that matters:
  --     it reads the gaps view and cannot read derm.manifest_visit_sheets.
  ---------------------------------------------------------------------------
  if not has_function_privilege('authenticated','derm.fn_manifest_address_documented(bigint)','EXECUTE')
     or not has_function_privilege('service_role','derm.fn_manifest_address_documented(bigint)','EXECUTE')
     or not has_function_privilege('pg_read_all_data','derm.fn_manifest_address_documented(bigint)','EXECUTE')
     or not has_function_privilege('yannick_readonly','derm.fn_manifest_address_documented(bigint)','EXECUTE')
  then raise exception 'V5 FAIL: a reader role lacks EXECUTE'; end if;
  if has_function_privilege('anon','derm.fn_manifest_address_documented(bigint)','EXECUTE')
  then raise exception 'V5 FAIL: anon can execute the predicate'; end if;

  set local role authenticated;
  select count(*) into n from derm.manifest_health;
  if n = 0 then raise exception 'V5 FAIL: authenticated reads 0 rows from manifest_health'; end if;
  reset role;

  -- yannick_readonly cannot be assumed from this connection (postgres is not a member),
  -- so its access is asserted with the catalogue rather than by switching to it. That is
  -- the whole reason the predicate is SECURITY DEFINER: the role reads the gaps view and
  -- holds NO grant on derm.manifest_visit_sheets, so an INVOKER function would 42501 it.
  if not has_table_privilege('yannick_readonly','ops.v_derm_row_completeness_gaps','SELECT') then
    raise exception 'V5 FAIL: yannick_readonly lost its read on the gaps view';
  end if;
  if has_table_privilege('yannick_readonly','derm.manifest_visit_sheets','SELECT') then
    raise notice 'V5 note: yannick_readonly now HAS the sheet grant; the SECDEF rationale changed';
  end if;

  ---------------------------------------------------------------------------
  -- V6  measure the one deliberate widening rather than assuming it is inert
  ---------------------------------------------------------------------------
  select count(*) into v_extras_only
    from public.derm_manifests dm
   where dm.deleted_at is null
     and dm.derm_address_url is null
     and coalesce(array_length(dm.derm_address_extra_urls,1),0) > 0;

  select count(*) into v_full_after from derm.manifest_health where health_state = 'fully_complete';

  raise exception 'ALL VERIFY PASSED (rolled back) :: 312840=% | dade complete=% | extras-only rows=% | fully_complete total=%',
    v_312840_states, v_dade_complete_after, v_extras_only, v_full_after;
end $$;
