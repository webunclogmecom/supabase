-- 2026-09-08_0330  edit_manifest: a save may ADD or REPLACE, never REDUCE the set of documents
--                  a ticket holds.
--
-- Fred: "fix the destructive edit first."
--
-- ============================================================================
-- THE DEFECT
-- ============================================================================
-- The /manifests edit modal loads its "freshest photos" with
-- `.eq("manifest_number", ...)` against derm.manifests. That column is aliased
-- from dm.white_manifest_number and NOTHING else, so it is NULL on 167 of 167
-- Broward rows (control: 0 of 545 Dade rows). The query matches nothing, the
-- population effect short-circuits on `(!P.data && !P.isError)`, and both photo
-- slots render "No address photo" while the sheets exist.
--
-- The SAVE then reads a DIFFERENT expression and sends an array built from the
-- seed row alone. edit_manifest applies that array to EVERY LIVE ROW of the
-- ticket, so the ticket's other sheets are detached.
--
-- 🛑 WHO ACTUALLY LOST SHEETS, MEASURED PER TRANSACTION OVER ALL OF audit.logs.
-- This corrects the first framing of this bug, which blamed Broward:
--
--     county        app edits   SHRINKS   same   grew
--     BROWARD          87          0        0     87
--     MIAMI-DADE      177          5        1    171
--
-- Every sheet ever lost through this modal was MIAMI-DADE:
--     2026-06-30 14:34  ticket 306859  41 rows  union 3 -> 2
--     2026-06-30 15:29  ticket 306859  41 rows  union 2 -> 1
--     2026-07-06 17:51  ticket 826477  16 rows  union 2 -> 1
--     2026-07-06 18:05  ticket 826114   4 rows  union 2 -> 1
--     2026-08-24 10:56  ticket 833395   6 rows  union 2 -> 1
--
-- Broward is 87 for 87 with no loss. Its exposure is REAL but LATENT: tickets
-- 300373 (12 rows) and 298064 (10 rows) each hold two distinct primaries with
-- empty extras, so their second sheet exists only as another row's primary.
--
-- ============================================================================
-- 🛑 WHY THIS IS A CONTAINMENT TEST AND NOT A COUNT
-- ============================================================================
-- The first design of this guard compared count(DISTINCT). An adversarial pass
-- refused it, correctly: a COUNT permits every EQUAL-SIZE SWAP, and that is
-- precisely the loss shape. On a 2-sheet ticket, "Replace" with two files sends
-- 2 distinct urls, `2 < 2` is false, the guard allows it, and BOTH original
-- sheets are detached. Same arithmetic for remove-one-plus-add-one in one save.
--
-- So the rule is SET CONTAINMENT: every url the ticket holds now must still be
-- present after. Adding is free, reordering is free, replacing a page is free
-- only if the replaced page is still somewhere in the array.
--
-- ⚠ AND THE BEFORE-SET MUST BE BUILT NULL-FREE. `array_remove(arr, NULL)` does
-- NOT remove NULLs, because array_remove drops elements EQUAL to its argument
-- and nothing is equal to NULL. A NULL left in the before-array makes
-- `before <@ after` evaluate to NULL, so `NOT (...)` is NULL, the IF never
-- fires, and the guard FAILS OPEN on exactly the rows that motivated it.
-- Built here with array_agg(DISTINCT u) FILTER (WHERE u IS NOT NULL).
--
-- ============================================================================
-- 🛑 THE SINGULAR PATH IS GUARDED TOO
-- ============================================================================
-- A guard written as `IF p_derm_address_urls IS NOT NULL AND ...` is skipped
-- entirely by any caller passing only the legacy scalar p_derm_address_url.
-- That path sets derm_address_url on EVERY live row while leaving extras
-- untouched, which collapses 300373 / 298064 from two sheets to one in a single
-- statement. edit_manifest is PostgREST-reachable with EXECUTE granted to
-- `authenticated`, so that is reachable from a browser. Both paths compute an
-- AFTER set and both are tested.
--
-- ============================================================================
-- 🛑 THE LOCK IS PART OF THE GUARD, NOT A NICETY
-- ============================================================================
-- Without it the before-set SELECT and the UPDATE are separate statements at
-- READ COMMITTED. Two operators saving the same ticket both evaluate their
-- guard against a snapshot predating the other's commit, both pass, and the
-- later UPDATE re-evaluates its WHERE against the new row versions and
-- overwrites the earlier one's added page. Group sizes make this realistic:
-- 306859 is 14 rows, 827989 is 19. The lock is taken FIRST, over exactly the
-- rows the UPDATE will touch.
--
-- ============================================================================
-- WHAT THIS DELIBERATELY DOES NOT DO
-- ============================================================================
-- It does not let anyone REMOVE a document. Removal is a real operation that has
-- been used on purpose (2026-06-30 14:34 on 306859 went 3 -> 2 while uploading
-- one NEW url and changing the dump date, i.e. an operator replacing sheets), so
-- it gets its OWN control in the next migration rather than being inferred from
-- a shrinking array. That is the whole point: today one verb does two jobs and
-- no guard can separate intent it was never told. Until that control ships,
-- removal is refused and the message says so.
--
-- SIGNATURE IS BYTE-IDENTICAL. Ten arguments, same names, same types, same
-- defaults, same RETURNS SETOF derm_manifests. No DROP, no re-GRANT, no
-- PGRST203 overload, no cached tab broken.
--
-- Body captured from the live database with pg_get_functiondef
-- (md5 800eeb4c41348d127d39cbdc82dd97b3) and edited in place. Everything outside
-- the DECLARE additions and the guard block below is unchanged.
-- ============================================================================

begin;

CREATE OR REPLACE FUNCTION public.edit_manifest(p_old_number text, p_old_jurisdiction text, p_new_number text, p_new_jurisdiction text, p_dump_date date, p_disposal_facility_id bigint, p_derm_manifest_url text DEFAULT NULL::text, p_derm_address_url text DEFAULT NULL::text, p_derm_manifest_urls text[] DEFAULT NULL::text[], p_derm_address_urls text[] DEFAULT NULL::text[])
 RETURNS SETOF derm_manifests
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_old_dade boolean := position('dade' in lower(coalesce(p_old_jurisdiction, ''))) > 0;
  v_new_dade boolean := position('dade' in lower(coalesce(p_new_jurisdiction, ''))) > 0;
  -- Normalize provided arrays: drop NULL/blank entries, preserve order (element 1 = primary).
  v_man_arr  text[] := CASE WHEN p_derm_manifest_urls IS NULL THEN NULL
                            ELSE COALESCE((SELECT array_agg(u ORDER BY ord)
                                             FROM unnest(p_derm_manifest_urls) WITH ORDINALITY AS t(u, ord)
                                            WHERE nullif(btrim(u), '') IS NOT NULL), ARRAY[]::text[]) END;
  v_addr_arr text[] := CASE WHEN p_derm_address_urls IS NULL THEN NULL
                            ELSE COALESCE((SELECT array_agg(u ORDER BY ord)
                                             FROM unnest(p_derm_address_urls) WITH ORDINALITY AS t(u, ord)
                                            WHERE nullif(btrim(u), '') IS NOT NULL), ARRAY[]::text[]) END;
  -- === 2026-09-08_0330: the no-shrink guard ===============================
  v_man_before  text[];
  v_man_after   text[];
  v_addr_before text[];
  v_addr_after  text[];
  v_lost        text[];
BEGIN
  IF coalesce(p_old_number, '') = '' OR coalesce(p_new_number, '') = '' THEN
    RAISE EXCEPTION 'edit_manifest: manifest number is required' USING ERRCODE = '22023';
  END IF;

  -- ===================== NO-SHRINK GUARD (2026-09-08_0330) ================
  -- 1. LOCK the exact rows the UPDATE will touch, BEFORE reading them. Without
  --    this, two concurrent saves both pass their guards and the later wins.
  PERFORM 1
    FROM public.derm_manifests dm
   WHERE dm.deleted_at IS NULL
     AND ( (v_old_dade     AND dm.white_manifest_number = p_old_number)
        OR (NOT v_old_dade AND dm.yellow_ticket_number  = p_old_number) )
     FOR UPDATE;

  -- 2. The BEFORE set: every distinct non-null url the ticket holds, across
  --    primary AND extras, across every live row. NULL-free by construction.
  SELECT coalesce(array_agg(DISTINCT s.u) FILTER (WHERE s.u IS NOT NULL), ARRAY[]::text[]),
         coalesce(array_agg(DISTINCT t.u) FILTER (WHERE t.u IS NOT NULL), ARRAY[]::text[])
    INTO v_man_before, v_addr_before
    FROM public.derm_manifests dm
    LEFT JOIN LATERAL (SELECT dm.derm_manifest_url AS u
                       UNION ALL SELECT unnest(coalesce(dm.derm_manifest_extra_urls, ARRAY[]::text[]))) s ON true
    LEFT JOIN LATERAL (SELECT dm.derm_address_url AS u
                       UNION ALL SELECT unnest(coalesce(dm.derm_address_extra_urls, ARRAY[]::text[]))) t ON true
   WHERE dm.deleted_at IS NULL
     AND ( (v_old_dade     AND dm.white_manifest_number = p_old_number)
        OR (NOT v_old_dade AND dm.yellow_ticket_number  = p_old_number) );

  -- 3. The AFTER set, per slot, matching exactly what the UPDATE below will do.
  --    Array path  -> the array replaces primary+extras on every row.
  --    Scalar path -> the scalar becomes every row's primary; extras untouched.
  --    Neither     -> nothing moves.
  IF p_derm_manifest_urls IS NOT NULL THEN
    v_man_after := coalesce((SELECT array_agg(DISTINCT u) FILTER (WHERE u IS NOT NULL) FROM unnest(v_man_arr) u), ARRAY[]::text[]);
  ELSIF p_derm_manifest_url IS NOT NULL THEN
    v_man_after := coalesce((SELECT array_agg(DISTINCT u) FILTER (WHERE u IS NOT NULL) FROM (
                       SELECT p_derm_manifest_url AS u
                       UNION ALL
                       SELECT unnest(coalesce(dm.derm_manifest_extra_urls, ARRAY[]::text[]))
                         FROM public.derm_manifests dm
                        WHERE dm.deleted_at IS NULL
                          AND ( (v_old_dade     AND dm.white_manifest_number = p_old_number)
                             OR (NOT v_old_dade AND dm.yellow_ticket_number  = p_old_number) )) z), ARRAY[]::text[]);
  ELSE
    v_man_after := v_man_before;
  END IF;

  IF p_derm_address_urls IS NOT NULL THEN
    v_addr_after := coalesce((SELECT array_agg(DISTINCT u) FILTER (WHERE u IS NOT NULL) FROM unnest(v_addr_arr) u), ARRAY[]::text[]);
  ELSIF p_derm_address_url IS NOT NULL THEN
    v_addr_after := coalesce((SELECT array_agg(DISTINCT u) FILTER (WHERE u IS NOT NULL) FROM (
                       SELECT p_derm_address_url AS u
                       UNION ALL
                       SELECT unnest(coalesce(dm.derm_address_extra_urls, ARRAY[]::text[]))
                         FROM public.derm_manifests dm
                        WHERE dm.deleted_at IS NULL
                          AND ( (v_old_dade     AND dm.white_manifest_number = p_old_number)
                             OR (NOT v_old_dade AND dm.yellow_ticket_number  = p_old_number) )) z), ARRAY[]::text[]);
  ELSE
    v_addr_after := v_addr_before;
  END IF;

  -- 4. CONTAINMENT, not cardinality. An equal-size swap must be refused.
  IF NOT (v_addr_before <@ v_addr_after) THEN
    SELECT array_agg(u) INTO v_lost FROM unnest(v_addr_before) u WHERE NOT (u = ANY(v_addr_after));
    RAISE EXCEPTION 'This save would drop % address sheet(s) this ticket already has. Saving can only add or replace a sheet, never take one off. To remove a sheet, use Remove on that sheet.', cardinality(v_lost)
      USING ERRCODE = '23514', DETAIL = array_to_string(v_lost, ' | ');
  END IF;

  IF NOT (v_man_before <@ v_man_after) THEN
    SELECT array_agg(u) INTO v_lost FROM unnest(v_man_before) u WHERE NOT (u = ANY(v_man_after));
    RAISE EXCEPTION 'This save would drop % disposal receipt page(s) this ticket already has. Saving can only add or replace a page, never take one off. To remove a page, use Remove on that page.', cardinality(v_lost)
      USING ERRCODE = '23514', DETAIL = array_to_string(v_lost, ' | ');
  END IF;
  -- ===================== end guard ========================================

  -- Update every live row in the OLD (number, jurisdiction) group, in one atomic statement.
  RETURN QUERY
  UPDATE public.derm_manifests dm SET
    white_manifest_number = CASE WHEN v_new_dade THEN p_new_number ELSE NULL END,
    yellow_ticket_number  = CASE WHEN v_new_dade THEN NULL ELSE p_new_number END,
    -- ⚠ COALESCE, not a bare assignment: this UPDATE spans the whole ticket group (up to 19 rows), so an
    -- empty form field here would wipe the dump date / facility across every manifest on the ticket.
    -- NULL means "leave as is", exactly like the URL slots below. Do NOT "simplify" these back.
    dump_ticket_date      = COALESCE(p_dump_date, dm.dump_ticket_date),
    disposal_facility_id  = COALESCE(p_disposal_facility_id, dm.disposal_facility_id),
    -- MANIFEST slot: authoritative array wins; else legacy single-url COALESCE, extras untouched.
    derm_manifest_url = CASE
        WHEN p_derm_manifest_urls IS NOT NULL THEN v_man_arr[1]
        ELSE COALESCE(p_derm_manifest_url, dm.derm_manifest_url) END,
    derm_manifest_extra_urls = CASE
        WHEN p_derm_manifest_urls IS NOT NULL THEN v_man_arr[2:cardinality(v_man_arr)]
        ELSE dm.derm_manifest_extra_urls END,
    -- ADDRESS slot
    derm_address_url = CASE
        WHEN p_derm_address_urls IS NOT NULL THEN v_addr_arr[1]
        ELSE COALESCE(p_derm_address_url, dm.derm_address_url) END,
    derm_address_extra_urls = CASE
        WHEN p_derm_address_urls IS NOT NULL THEN v_addr_arr[2:cardinality(v_addr_arr)]
        ELSE dm.derm_address_extra_urls END
  WHERE dm.deleted_at IS NULL
    AND ( (v_old_dade     AND dm.white_manifest_number = p_old_number)
       OR (NOT v_old_dade AND dm.yellow_ticket_number  = p_old_number) )
  RETURNING dm.*;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'edit_manifest: no live manifest found for % #%', p_old_jurisdiction, p_old_number
      USING ERRCODE = 'P0002';
  END IF;

EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'edit_manifest: a manifest numbered % is already filed for one of these clients', p_new_number
      USING ERRCODE = '23505';
END;
$function$;

commit;

-- ============================================================================
-- VERIFY. Every probe writes inside a savepoint that ALWAYS rolls back.
-- ============================================================================
do $verify$
declare
  v_tk       text;
  v_urls     text[];
  v_raised   text;
  v_before_n int;
  v_dump     date;
  n          int;
  card_would_refuse boolean;
  cont_would_refuse boolean;
begin
  -- Pick a REAL at-risk ticket and read its REAL urls. Never type a url into a
  -- probe: an earlier draft of this migration invented a path that does not
  -- exist in storage, which would have made the negative control meaningless.
  v_tk := '300373';
  select coalesce(array_agg(distinct s.u) filter (where s.u is not null), '{}')
    into v_urls
    from public.derm_manifests dm
    left join lateral (select dm.derm_address_url u
                       union all select unnest(coalesce(dm.derm_address_extra_urls,'{}'))) s on true
   where dm.deleted_at is null and dm.yellow_ticket_number = v_tk;
  v_before_n := cardinality(v_urls);
  -- Use the ticket's OWN dump date. An invented date trips
  -- trg_ac_link_visit_not_after_dump (a link may not have visit_date > dump + 1 day),
  -- which is a DIFFERENT guard and would make A5 fail for the wrong reason.
  select max(dm.dump_ticket_date) into v_dump
    from public.derm_manifests dm
   where dm.deleted_at is null and dm.yellow_ticket_number = v_tk;
  if v_before_n <> 2 then
    raise exception 'SETUP FAILED: ticket % has % distinct address urls, expected 2', v_tk, v_before_n;
  end if;

  -- A1. A STRICT SHRINK is refused (1 of the 2 urls).
  begin
    begin
      perform public.edit_manifest(v_tk, 'Broward', v_tk, 'Broward', null, null, null, null, null, ARRAY[v_urls[1]]);
      v_raised := 'NONE';
    exception when others then v_raised := sqlstate; end;
    if v_raised <> '23514' then raise exception 'A1 FAILED: strict shrink gave %, expected 23514', v_raised; end if;

    -- A2. THE PROBE THAT SEPARATES THE TWO GUARD DESIGNS. An EQUAL-SIZE SWAP:
    --     2 urls in, 2 urls out, but one of them is new. A cardinality guard
    --     ALLOWS this and loses a sheet. Containment must refuse it.
    begin
      perform public.edit_manifest(v_tk, 'Broward', v_tk, 'Broward', null, null, null, null, null,
                                   ARRAY[v_urls[1], 'https://example.invalid/replacement.jpg']);
      v_raised := 'NONE';
    exception when others then v_raised := sqlstate; end;
    if v_raised <> '23514' then
      raise exception 'A2 FAILED: equal-size swap gave %, expected 23514. This is THE case a count-based guard misses', v_raised;
    end if;

    -- A2b. MUTATION CONTROL, as arithmetic on the same operands: the rejected
    --      cardinality design would NOT have refused A2. If both predicates
    --      agree here, A2 proves nothing about which guard shipped.
    card_would_refuse := cardinality(ARRAY[v_urls[1], 'https://example.invalid/replacement.jpg']) < v_before_n;
    cont_would_refuse := NOT (v_urls <@ ARRAY[v_urls[1], 'https://example.invalid/replacement.jpg']);
    if card_would_refuse then raise exception 'A2b FAILED: the count guard would also have refused; A2 does not discriminate'; end if;
    if not cont_would_refuse then raise exception 'A2b FAILED: containment did not refuse the swap'; end if;

    -- A3. THE SINGULAR PATH is guarded. Passing only the scalar would set every
    --     row's primary and, with empty extras on this ticket, collapse 2 -> 1.
    begin
      perform public.edit_manifest(v_tk, 'Broward', v_tk, 'Broward', null, null, null, v_urls[1], null, null);
      v_raised := 'NONE';
    exception when others then v_raised := sqlstate; end;
    if v_raised <> '23514' then raise exception 'A3 FAILED: singular path gave %, expected 23514', v_raised; end if;

    -- A4. A LEGITIMATE ADD is allowed: both existing urls plus a new one.
    begin
      perform public.edit_manifest(v_tk, 'Broward', v_tk, 'Broward', null, null, null, null, null,
                                   v_urls || 'https://example.invalid/added.jpg'::text);
      v_raised := 'NONE';
    exception when others then v_raised := sqlstate; end;
    if v_raised <> 'NONE' then raise exception 'A4 FAILED: a pure ADD was refused with %', v_raised; end if;

    -- A5. A NO-OP save (both URL slots null) is allowed and changes no urls.
    --     This is how the modal behaves once its `?? ot(...)` fallback is gone:
    --     an operator who edits only a non-document field sends both slots NULL.
    begin
      perform public.edit_manifest(v_tk, 'Broward', v_tk, 'Broward', v_dump, null, null, null, null, null);
      v_raised := 'NONE';
    exception when others then v_raised := sqlstate; end;
    if v_raised <> 'NONE' then raise exception 'A5 FAILED: a no-op save was refused with %', v_raised; end if;

    -- A6. P0002 still fires for a number that matches nothing. The guard's
    --     SELECT ... INTO is now the first FOUND-setting statement in the
    --     function, so this is not theoretical.
    begin
      perform public.edit_manifest('__no_such_ticket__', 'Broward', '__no_such_ticket__', 'Broward', null, null, null, null, null, null);
      v_raised := 'NONE';
    exception when others then v_raised := sqlstate; end;
    if v_raised <> 'P0002' then raise exception 'A6 FAILED: unknown ticket gave %, expected P0002', v_raised; end if;

    raise exception 'ROLLBACK_PROBE';
  exception
    when others then
      if sqlerrm <> 'ROLLBACK_PROBE' then raise; end if;
  end;

  -- The probe left nothing behind.
  select count(distinct s.u) into n
    from public.derm_manifests dm
    left join lateral (select dm.derm_address_url u
                       union all select unnest(coalesce(dm.derm_address_extra_urls,'{}'))) s on true
   where dm.deleted_at is null and dm.yellow_ticket_number = v_tk and s.u is not null;
  if n <> v_before_n then raise exception 'A7 FAILED: probe changed ticket % from % to % urls', v_tk, v_before_n, n; end if;

  -- The signature is unchanged: exactly one edit_manifest, 10 arguments.
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'edit_manifest';
  if n <> 1 then raise exception 'A8 FAILED: % overloads of edit_manifest exist (PGRST203 risk)', n; end if;

  select pronargs into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.proname = 'edit_manifest';
  if n <> 10 then raise exception 'A9 FAILED: edit_manifest has % args, expected 10', n; end if;

  if not has_function_privilege('authenticated',
       'public.edit_manifest(text,text,text,text,date,bigint,text,text,text[],text[])', 'execute') then
    raise exception 'A10 FAILED: authenticated lost EXECUTE on edit_manifest';
  end if;

  raise notice 'ALL PROBES PASSED (A1 shrink refused, A2 equal-size swap refused, A2b control, A3 singular path, A4 add allowed, A5 no-op allowed, A6 P0002, A7 clean rollback, A8-A10 signature intact)';
end;
$verify$;
