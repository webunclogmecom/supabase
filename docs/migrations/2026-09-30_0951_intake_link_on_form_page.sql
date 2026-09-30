-- ============================================================================
-- intake_link_on_form_page: the reveal log and client.get_intake_link say what a row means now (comments only)
-- 2026-09-30 · Picture Planner /forms/$id shows a WAITING form's collector link as soon as the form is opened
-- ============================================================================
-- Fred, 2026-09-30: "When opening a form https://planner.unclogme.app/forms/1041 like that one, we need to show there the
-- link we shared to the collector, so we can open it again, and have it in case the collector needs it again. I know it's
-- also available with the "share" menu button, but display it also at the view of the form on the top."
-- He picked V1 ("Yes, show it on open (V1)"), accepting what follows.
-- The Picture Planner form page now calls client.get_intake_link ONCE per view of a waiting form (Picture Planner rule 23),
-- not only on a "Share form" click (rule 9). Each successful call still writes one public.property_intake_link_reveals row,
-- so a row now means "this staff login was shown this form's link at this time", from either place, and the log can no
-- longer tell a form-page open from a Share form click. This SUPERSEDES the premise of 2026-09-25_1600_intake_link_share
-- ("NOT throttled: every row is a deliberate staff click"): rows are still never throttled, and opening a waiting form
-- (it has no answers yet) is itself a deliberate look at its link. No source column (rejected in the study: a migration
-- for a table with 2 rows). The 1600 file is history and is not edited.
-- WHAT: COMMENT ON the table and the function, nothing else. The function body (md5 pinned), the table, its RLS (on, no
-- policy, no trigger) and every grant (table, sequence, function) stay exactly as they are; the VERIFY reads them back.
-- Rule 8 (audit): no table change. ATOMIC: no BEGIN/COMMIT; the VERIFY's role switch runs only inside its sentinel block.
-- ============================================================================

do $pin$
begin
  if md5(pg_get_functiondef('client.get_intake_link(bigint)'::regprocedure)) <> 'dc1055b106672049878f836616d65255' then
    raise exception 'PIN: client.get_intake_link changed since this migration was written';
  end if;
  if obj_description('public.property_intake_link_reveals'::regclass, 'pg_class') is distinct from
     $c$Who revealed which intake's collector link, and when (client.get_intake_link, Picture Planner "Share form"). No token, no URL. Written only by client.get_intake_link; no app role can read it. Not audited: it is the trail.$c$ then
    raise exception 'PIN: the comment on public.property_intake_link_reveals changed since this migration was written';
  end if;
  if obj_description('client.get_intake_link(bigint)'::regprocedure, 'pg_proc') is distinct from
     $c$Picture Planner "Share form": the collector link (https://planner.unclogme.app/intake#code=<token>, a 308 to /intake.html) of ONE awaiting intake, for a staff JWT; logs each reveal in public.property_intake_link_reveals. Refuses cancelled, submitted, expired and removed-property intakes. The only re-display of an intake token (REF rule 10).$c$ then
    raise exception 'PIN: the comment on client.get_intake_link changed since this migration was written';
  end if;
end $pin$;

comment on table public.property_intake_link_reveals is
  'Who was shown which intake''s collector link, and when, by client.get_intake_link: Picture Planner "Share form" on /forms, and the Collector link block that loads when a WAITING form is opened on /forms/$id. A row does not say which of the two. No token, no URL. Written only by client.get_intake_link; no app role can read it. Not audited: it is the trail.';

comment on function client.get_intake_link(bigint) is
  'Picture Planner: the collector link (https://planner.unclogme.app/intake#code=<token>, a 308 to /intake.html) of ONE awaiting intake, for a staff JWT; called by "Share form" on /forms and when a waiting form is opened on /forms/$id. Logs each reveal in public.property_intake_link_reveals. Refuses cancelled, submitted, expired and removed-property intakes. The only re-display of an intake token (REF rule 10).';

-- VERIFY: the two comments read back exactly; the body, RLS and every grant unchanged; a staff login still cannot read
-- the log (the comment says so). Any failure raises and rolls the whole migration back.
do $verify$
declare
  v_t text := obj_description('public.property_intake_link_reveals'::regclass, 'pg_class');
  v_f text := obj_description('client.get_intake_link(bigint)'::regprocedure, 'pg_proc');
begin
  -- V1: both comments exactly as written above
  if v_t is distinct from $c$Who was shown which intake's collector link, and when, by client.get_intake_link: Picture Planner "Share form" on /forms, and the Collector link block that loads when a WAITING form is opened on /forms/$id. A row does not say which of the two. No token, no URL. Written only by client.get_intake_link; no app role can read it. Not audited: it is the trail.$c$ then
    raise exception 'VERIFY 1: the table comment reads %', v_t;
  end if;
  if v_f is distinct from $c$Picture Planner: the collector link (https://planner.unclogme.app/intake#code=<token>, a 308 to /intake.html) of ONE awaiting intake, for a staff JWT; called by "Share form" on /forms and when a waiting form is opened on /forms/$id. Logs each reveal in public.property_intake_link_reveals. Refuses cancelled, submitted, expired and removed-property intakes. The only re-display of an intake token (REF rule 10).$c$ then
    raise exception 'VERIFY 1: the function comment reads %', v_f;
  end if;
  -- V2: the function body is the pinned one (a comment is not part of it)
  if md5(pg_get_functiondef('client.get_intake_link(bigint)'::regprocedure)) <> 'dc1055b106672049878f836616d65255' then
    raise exception 'VERIFY 2: client.get_intake_link body changed';
  end if;
  -- V3: every grant exactly as before (function, table, sequence)
  if (select p.proacl::text from pg_proc p where p.oid = 'client.get_intake_link(bigint)'::regprocedure)
       is distinct from '{postgres=X/postgres,authenticated=X/postgres}' then
    raise exception 'VERIFY 3: client.get_intake_link proacl changed';
  end if;
  if (select c.relacl::text from pg_class c where c.oid = 'public.property_intake_link_reveals'::regclass)
       is distinct from '{postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}' then
    raise exception 'VERIFY 3: public.property_intake_link_reveals relacl changed';
  end if;
  if (select c.relacl::text from pg_class c where c.oid = 'public.property_intake_link_reveals_id_seq'::regclass)
       is distinct from '{postgres=rwU/postgres,service_role=rwU/postgres}' then
    raise exception 'VERIFY 3: public.property_intake_link_reveals_id_seq relacl changed';
  end if;
  -- V4: RLS on, no policy, no trigger (not audited: it is the trail)
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.property_intake_link_reveals'::regclass)
     or (select count(*) from pg_policies where schemaname = 'public' and tablename = 'property_intake_link_reveals') <> 0
     or exists (select 1 from pg_trigger t where t.tgrelid = 'public.property_intake_link_reveals'::regclass and not t.tgisinternal) then
    raise exception 'VERIFY 4: RLS, policies or triggers on public.property_intake_link_reveals changed';
  end if;
  -- V5 (sentinel block, rolled back): as authenticated, reading the log is refused
  begin
    set local role authenticated;
    begin
      perform count(*) from public.property_intake_link_reveals;
      raise exception 'VERIFY 5: authenticated can read public.property_intake_link_reveals';
    exception when insufficient_privilege then null;
    end;
    raise exception 'VERIFY_SENTINEL';
  exception when others then
    if sqlerrm <> 'VERIFY_SENTINEL' then raise; end if;
  end;
  if current_user = 'authenticated' then
    raise exception 'VERIFY 5: the role switch outlived its sentinel block';
  end if;
end $verify$;

notify pgrst, 'reload schema';
