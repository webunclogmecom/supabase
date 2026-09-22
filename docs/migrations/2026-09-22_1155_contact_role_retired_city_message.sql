-- 2026-09-22_1155_contact_role_retired_city_message.sql
--
-- Corrective follow-up to 2026-09-22_1100, applied minutes later, same session.
--
-- 🛑 WHAT I GOT WRONG, recorded because the rule it breaks is written down in this estate and I
-- broke it anyway. `Building Apps/Client App/CLAUDE.md` rule 2d says a TIGHTENING ships UI FIRST,
-- server second (a server that accepts more than the UI sends is always safe; the reverse makes
-- every save from the published bundle fail - that is known issue 0g, which broke every client
-- status change for hours). `_1100` narrowed `v_roles` to {primary, accounting} on the SERVER
-- while the published Client App bundle still offers City in its contact-role dropdown.
--
-- Measured, not assumed: a walk of the live bundle seeded from BOTH `/` and `/clients/381`
-- (6 chunks, 1,197,604 bytes, 9,865 string literals as the control) finds
-- `{value:"city",label:"City"}` in `clients._id-ygXv-fRQ.js`. So the option is on screen today.
-- 🛑 Seeding from `/` alone reaches 3 of the 6 chunks and would have returned a confident zero:
-- the contacts route is not reachable from the root document.
--
-- WHY THIS IS NOT A REVERT. Reverting the narrowing would let somebody create a NEW `city`
-- contact hours after step 1 deleted the last 21, and that row would be silent debris nothing
-- is looking for. Fred's decision stands - *"we need to delete the 21 old city email from the
-- contacts, we use now the city email field from the property"* - so the retirement takes effect
-- now and the person who picks the stale option is TOLD WHY, in words, at the moment they would
-- otherwise see a broken save.
--
-- IT ALSO FIXES A MESSAGE THAT BREAKS THE 2026-09-14 OPERATOR-MESSAGE RULE. Both functions
-- raised `contact_role must be one of %` with a raw Postgres array interpolated into it -
-- a column name and a `{primary,accounting}` literal in front of a person. Fred, on the Stamp
-- Studio banner: *"they're not semantic, we need to save in the docs that any error message
-- should be semantic with no tech words."* MESSAGE is now a plain sentence; the code, the
-- column and the offending value go to DETAIL, which the apps never display and the logs keep.
--
-- STILL OPEN, and it is an APP change, not a DB one: the dropdown must lose its City option.
-- That rides with the contact modal rework (plan steps 7-9), which is where the app-side role
-- concept changes anyway. Until then, picking City is a refusal with an explanation.

begin;

do $splice$
declare
  v_src text; v_new text; v_n int; r record;
  v_anchor constant text :=
    '    raise exception ''contact_role must be one of %'', v_roles using errcode = ''22023'';';
  v_repl constant text :=
    '    if v_role = ''city'' then' || E'\n' ||
    '      raise exception ''The City role has been retired. City email addresses now live on the location itself, under City email.''' || E'\n' ||
    '        using errcode = ''22023'',' || E'\n' ||
    '              detail  = ''blocker=contact_role_city_retired value=city'';' || E'\n' ||
    '    end if;' || E'\n' ||
    '    raise exception ''Pick a role for this contact: Main contact, or Accounting.''' || E'\n' ||
    '      using errcode = ''22023'',' || E'\n' ||
    '            detail  = ''blocker=contact_role_unknown value='' || coalesce(v_role, ''(null)'');';
begin
  for r in
    select oid, proname from pg_proc
     where pronamespace = 'client'::regnamespace
       and proname in ('create_client_contact','update_client_contact')
  loop
    v_src := pg_get_functiondef(r.oid);

    -- 🛑 SPLICED FROM THE LIVE DEFINITION, NEVER RETYPED, anchor asserted to occur exactly once.
    v_n := (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor);
    if v_n <> 1 then
      raise exception 'message anchor matched % times in client.%, expected 1', v_n, r.proname;
    end if;

    v_new := replace(v_src, v_anchor, v_repl);
    if v_new = v_src then
      raise exception 'splice produced no change for client.%', r.proname;
    end if;
    execute v_new;
  end loop;
end $splice$;

commit;

-- ============================================================================================
-- VERIFY  (run 2026-09-22, rehearsed rolled-back first, then re-run against the applied state)
--
-- Each case is exercised through the REAL RPC as a staff user, inside begin/rollback, and every
-- refusal is paired with a control that must SUCCEED - a function that refuses everything would
-- satisfy the refusals on its own.
--
--   create_client_contact / update_client_contact with contact_role 'city'
--     -> 22023, MESSAGE = 'The City role has been retired. City email addresses now live on
--                          the location itself, under City email.'
--        DETAIL  = 'blocker=contact_role_city_retired value=city'
--   ... with contact_role 'zzz'
--     -> 22023, MESSAGE = 'Pick a role for this contact: Main contact, or Accounting.'
--        DETAIL  = 'blocker=contact_role_unknown value=zzz'
--   ... with contact_role 'accounting'                       -> SUCCEEDS   <- the control
--
--   🛑 No MESSAGE may contain 'contact_role', '{' or 'v_roles'. That assertion is the rule,
--   mirrored: it tests the OUTCOME a person sees, not that the function was edited.
-- ============================================================================================
