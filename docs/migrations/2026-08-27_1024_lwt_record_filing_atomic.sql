-- 2026-08-27_1024_lwt_record_filing_atomic.sql
--
-- Make recording a filing ATOMIC. Fixes the `ticket_insert_failed` hole documented in
-- docs/audits/2026-08-26_lwt_post_ship_audit.md §14.
--
-- THE DEFECT. `rpa-derm-monthly-filed` wrote a filing with TWO PostgREST calls: the header into
-- public.lwt_filings, then the rows into public.lwt_filing_tickets. Two calls are two
-- transactions. The header insert is also what CLAIMS the run_id (idempotency is a unique index
-- plus a 23505 branch), so when the second call failed:
--   * the header existed and the run_id was already burned;
--   * a retry with the same run_id hit 23505, took the REPLAY path, and returned
--     already_recorded: true with tickets_recorded: 0 WITHOUT inserting anything;
--   * the filing stayed permanently empty and those tickets stayed unreported, on a record of
--     what we told Miami-Dade.
-- It has never fired. That is luck, not design: nothing about the shape prevents it.
--
-- THE FIX. Both inserts move into one function. PostgREST runs a function call in a single
-- transaction, so the ticket insert failing now rolls the header back with it and the run_id is
-- never claimed. A retry is then genuinely clean rather than a replay of an empty filing.
--
-- 🛑 SECURITY INVOKER, DELIBERATELY, AND DO NOT "FIX" IT TO DEFINER.
-- Supabase/CLAUDE.md: "A SECDEF function BYPASSES RLS, so wrapping a write in one can silently
-- WIDEN it." Both tables had their grants narrowed to SELECT + INSERT for service_role yesterday
-- (2026-08-26_1815), RLS enabled, and that grant is the entire basis of the append-only claim we
-- put in writing to an external developer. A SECURITY DEFINER wrapper owned by postgres would
-- launder exactly that control away.
-- Measured before choosing: service_role already holds SELECT on derm_manifests and SELECT +
-- INSERT on both target tables, and holds NO DELETE. So an invoker-rights function can do
-- everything this needs and nothing more, and the grant stays the thing that stops a rewrite.
--
-- ⚠ Validation stays in the edge function. It produces NAMED 400s (invalid_run_id,
-- tickets_required, ...) that the bot builds against, and a constraint violation surfacing as a
-- raw SQLSTATE would be a contract regression. This function is the WRITE, not the gate.

begin;

create or replace function public.fn_record_lwt_filing(
  p_run_id            text,
  p_tickets           text[],
  p_period_start      date,
  p_period_end        date,
  p_filed_at          timestamptz,
  p_invoice_id        text default null,
  p_confirmation_ref  text default null,
  p_filed_by_email    text default null,
  p_dry_run           boolean default false
) returns jsonb
language plpgsql
volatile
security invoker
set search_path = public, pg_catalog
as $function$
declare
  v_tickets text[];
  v_filing  public.lwt_filings;
  v_unknown text[];
  v_count   int;
begin
  -- De-duplicate. A caller sending the same ticket twice in one payload means it once.
  select array_agg(distinct t) into v_tickets from unnest(p_tickets) as t;

  -- Backstop only: the edge function rejects this with a named 400 long before here. A filing
  -- with no tickets is the empty-filing shape this whole migration exists to prevent.
  if v_tickets is null or cardinality(v_tickets) = 0 then
    raise exception 'tickets_required' using errcode = '22023';
  end if;

  begin
    insert into public.lwt_filings (
      run_id, invoice_id, period_start, period_end, filed_at,
      confirmation_ref, filed_by_email, dry_run
    ) values (
      p_run_id, p_invoice_id, p_period_start, p_period_end, p_filed_at,
      p_confirmation_ref, p_filed_by_email, coalesce(p_dry_run, false)
    )
    returning * into v_filing;
  exception when unique_violation then
    -- REPLAY. The normal answer to a retry, never an error. Changes nothing.
    -- Enforced by the unique index rather than a look-then-write, so two concurrent replays
    -- cannot both insert: one wins and the other lands here.
    select * into v_filing from public.lwt_filings where run_id = p_run_id;
    select count(*) into v_count from public.lwt_filing_tickets where filing_id = v_filing.id;
    return jsonb_build_object(
      'recorded', false,
      'already_recorded', true,
      'filing_id', v_filing.id,
      'tickets_recorded', v_count,
      'filing', jsonb_build_object(
        'id', v_filing.id,
        'invoice_id', v_filing.invoice_id,
        'period_start', v_filing.period_start,
        'period_end', v_filing.period_end,
        'filed_at', v_filing.filed_at,
        'confirmation_ref', v_filing.confirmation_ref,
        'dry_run', v_filing.dry_run
      ),
      'dry_run', v_filing.dry_run
    );
  end;

  -- Resolve the manifest per ticket. Best effort BY DESIGN: a ticket we cannot resolve is still
  -- RECORDED with manifest_id null and echoed back, because refusing it would destroy the
  -- discrepancy the caller asked to be able to see. Jonathan: "any difference against the
  -- invoice becomes a finding in either direction."
  insert into public.lwt_filing_tickets (filing_id, ticket_number, manifest_id)
  select v_filing.id,
         t.ticket,
         (select m.id
            from public.derm_manifests m
           where m.deleted_at is null
             and (m.white_manifest_number = t.ticket or m.yellow_ticket_number = t.ticket)
           order by m.id
           limit 1)
    from unnest(v_tickets) as t(ticket);

  get diagnostics v_count = row_count;

  select coalesce(array_agg(ft.ticket_number order by ft.ticket_number), '{}'::text[])
    into v_unknown
    from public.lwt_filing_tickets ft
   where ft.filing_id = v_filing.id
     and ft.manifest_id is null;

  return jsonb_build_object(
    'recorded', true,
    'already_recorded', false,
    'filing_id', v_filing.id,
    'tickets_recorded', v_count,
    'unknown_tickets', to_jsonb(v_unknown),
    'dry_run', v_filing.dry_run
  );
end;
$function$;

comment on function public.fn_record_lwt_filing(text, text[], date, date, timestamptz, text, text, text, boolean) is
  'Records one LWT filing and its tickets ATOMICALLY. Replaces the two-PostgREST-call write in '
  'rpa-derm-monthly-filed, where a failed ticket insert left the run_id claimed and the filing '
  'permanently empty (audit 2026-08-26 section 14). Idempotent on run_id via unique_violation, '
  'never look-then-write. SECURITY INVOKER on purpose: service_role holds SELECT + INSERT and no '
  'DELETE, and that grant is what makes the append-only claim true, so a DEFINER wrapper would '
  'launder it away. Validation stays in the edge function, which returns named 400s.';

-- 🛑 Supabase ALTER DEFAULT PRIVILEGES makes a new public function EXECUTE-able by
-- `authenticated` before any GRANT here runs, and a GRANT cannot remove what it did not create.
-- Revoke by NAME. This is the same trap that left both tables wide open on 2026-08-26.
revoke all on function public.fn_record_lwt_filing(text, text[], date, date, timestamptz, text, text, text, boolean) from public;
revoke all on function public.fn_record_lwt_filing(text, text[], date, date, timestamptz, text, text, text, boolean) from anon;
revoke all on function public.fn_record_lwt_filing(text, text[], date, date, timestamptz, text, text, text, boolean) from authenticated;
grant execute on function public.fn_record_lwt_filing(text, text[], date, date, timestamptz, text, text, text, boolean) to service_role;

-- ---------------------------------------------------------------------------------------------
-- VERIFY. Everything below runs inside this transaction and every probe undoes itself.
-- The atomicity check is the point: it is not enough that the function is one statement, it has
-- to be shown that a failing ticket insert takes the header with it.
-- ---------------------------------------------------------------------------------------------
do $$
declare
  bad     text := '';
  v_res   jsonb;
  v_id    bigint;
  v_ran   boolean := false;
begin
  ---- 1. privileges -------------------------------------------------------------------------
  if has_function_privilege('anon', 'public.fn_record_lwt_filing(text,text[],date,date,timestamptz,text,text,text,boolean)', 'EXECUTE')
    then bad := bad || 'anon can EXECUTE; '; end if;
  if has_function_privilege('authenticated', 'public.fn_record_lwt_filing(text,text[],date,date,timestamptz,text,text,text,boolean)', 'EXECUTE')
    then bad := bad || 'authenticated can EXECUTE; '; end if;
  if not has_function_privilege('service_role', 'public.fn_record_lwt_filing(text,text[],date,date,timestamptz,text,text,text,boolean)', 'EXECUTE')
    then bad := bad || 'service_role CANNOT execute; '; end if;
  if (select p.prosecdef from pg_proc p
       where p.oid = 'public.fn_record_lwt_filing(text,text[],date,date,timestamptz,text,text,text,boolean)'::regprocedure)
    then bad := bad || 'function is SECURITY DEFINER, which launders the append-only grant; '; end if;

  ---- 2. a normal record writes BOTH, and reports honestly -----------------------------------
  v_res := public.fn_record_lwt_filing(
    'verify-atomic-happy', array['830673', 'ZZZ-NO-SUCH-TICKET'],
    '2026-06-28', '2026-07-25', now(), 'VERIFY', null, null, true);
  v_id := (v_res->>'filing_id')::bigint;
  if (v_res->>'recorded') <> 'true' then bad := bad || 'a fresh run_id did not record; '; end if;
  if (v_res->>'tickets_recorded') <> '2' then bad := bad || 'tickets_recorded is not 2; '; end if;
  if not (v_res->'unknown_tickets' ? 'ZZZ-NO-SUCH-TICKET')
    then bad := bad || 'an unresolvable ticket was not echoed back; '; end if;
  if (v_res->'unknown_tickets' ? '830673')
    then bad := bad || 'a REAL ticket was reported as unknown, so resolution is broken; '; end if;
  if (select count(*) from public.lwt_filing_tickets where filing_id = v_id) <> 2
    then bad := bad || 'the ticket rows are not on the table; '; end if;

  ---- 3. replay changes nothing --------------------------------------------------------------
  v_res := public.fn_record_lwt_filing(
    'verify-atomic-happy', array['830673'],
    '1999-01-01', '1999-12-31', now(), 'DIFFERENT', null, null, true);
  if (v_res->>'already_recorded') <> 'true' then bad := bad || 'a replay was not recognised; '; end if;
  if (v_res->>'recorded') <> 'false' then bad := bad || 'a replay reported a fresh write; '; end if;
  if (v_res->>'tickets_recorded') <> '2' then bad := bad || 'a replay lost the ticket count; '; end if;
  if (select count(*) from public.lwt_filings where run_id = 'verify-atomic-happy') <> 1
    then bad := bad || 'a replay inserted a second filing; '; end if;
  if (select count(*) from public.lwt_filing_tickets where filing_id = v_id) <> 2
    then bad := bad || 'a replay changed the ticket rows; '; end if;
  if (select period_start from public.lwt_filings where run_id = 'verify-atomic-happy') <> '2026-06-28'::date
    then bad := bad || 'a replay OVERWROTE the original filing; '; end if;

  ---- 4. 🛑 ATOMICITY, the whole point -------------------------------------------------------
  -- Force the ticket insert to fail and assert the header does NOT survive. Under the old
  -- two-call design the header would remain and burn the run_id for ever.
  create or replace function pg_temp.fail_ticket_insert() returns trigger
    language plpgsql as $t$ begin raise exception 'forced failure for the atomicity probe'; end $t$;

  -- A deliberately NON-atomic implementation, used below as the control. It swallows the ticket
  -- failure in an inner block, so the header survives: this is precisely the shape of the defect
  -- being fixed, expressed in one function instead of two HTTP calls.
  create or replace function pg_temp.nonatomic_write() returns void
    language plpgsql as $n$
    declare v_id bigint;
    begin
      insert into public.lwt_filings (run_id, period_start, period_end, filed_at, dry_run)
      values ('verify-atomic-control', '2026-06-28', '2026-07-25', now(), true)
      returning id into v_id;
      begin
        insert into public.lwt_filing_tickets (filing_id, ticket_number) values (v_id, '830673');
      exception when others then null;   -- swallowed, so the header is left behind
      end;
    end $n$;

  create trigger zz_atomicity_probe before insert on public.lwt_filing_tickets
    for each row execute function pg_temp.fail_ticket_insert();

  -- 4a. the real function: the header must NOT survive
  begin
    v_res := public.fn_record_lwt_filing(
      'verify-atomic-rollback', array['830673'],
      '2026-06-28', '2026-07-25', now(), null, null, null, true);
    v_ran := true;   -- must NOT be reached
  exception when others then
    null;            -- expected: the forced failure propagates
  end;

  -- 4b. 🛑 THE CONTROL. Run the same probe against a knowingly non-atomic write. If this does
  -- NOT leave a header behind, the probe is blind and 4a passing means nothing.
  begin
    perform pg_temp.nonatomic_write();
  exception when others then
    null;
  end;

  drop trigger zz_atomicity_probe on public.lwt_filing_tickets;

  if v_ran then
    bad := bad || 'the function RETURNED even though the ticket insert failed; ';
  end if;
  if exists (select 1 from public.lwt_filings where run_id = 'verify-atomic-rollback') then
    bad := bad || 'ATOMICITY BROKEN: the header survived a failed ticket insert, so the run_id is burned; ';
  end if;
  if not exists (select 1 from public.lwt_filings where run_id = 'verify-atomic-control') then
    bad := bad || 'CONTROL FAILED: the probe did not catch a deliberately non-atomic write, so the atomicity check proves nothing; ';
  end if;

  ---- 5. second control: the probe can see a filing that IS there ----------------------------
  if not exists (select 1 from public.lwt_filings where run_id = 'verify-atomic-happy') then
    bad := bad || 'control failed: the probe cannot see a filing that IS there; ';
  end if;

  if bad <> '' then
    raise exception 'fn_record_lwt_filing verification FAILED: %', bad;
  end if;
  raise notice 'fn_record_lwt_filing verified: atomic, idempotent, invoker-rights, service_role only';
end $$;

-- Undo the two verification filings. They only ever existed inside this transaction, but delete
-- explicitly rather than relying on that, so re-running the file cannot accumulate them.
delete from public.lwt_filings where run_id in ('verify-atomic-happy', 'verify-atomic-rollback', 'verify-atomic-control');

notify pgrst, 'reload schema';

commit;
