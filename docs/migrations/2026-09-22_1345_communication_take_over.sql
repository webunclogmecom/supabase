-- 2026-09-22_1345_communication_take_over.sql
--
-- Step 10/11 of the Contacts Role + Communication build, and a CORRECTION to my own
-- 2026-09-22_1100 design, found by testing the shipped UI against the shipped server.
--
-- 🛑 THE GAP. `client.save_contact_settings` deletes only the TARGET contact's pref rows and then
-- inserts the submitted set, so it can never take an exclusive communication OFF somebody else.
-- Ticking Invoice on a second contact therefore always raised 23505. The implementation plan
-- promised the opposite in §4.6 - *"the move and the set land in one call, so there is never a
-- window with two holders or none"* - and the UI shipped that promise: it names the current
-- holder and slides in a staged strip reading "Saving will move the invoice contact off X."
-- Measured on 112-YA through the live app: the strip appeared, Save was pressed, and the server
-- refused with my own sentence, "Only one contact can be marked as the invoice contact, and Yan's
-- Restaurant - 112-YA already is. Untick it there first."
--
-- ⚠ THE ERROR PATH ITSELF BEHAVED EXACTLY AS DESIGNED - modal stayed open and dirty, server
-- message shown verbatim - which is why this was a clean diagnosis rather than a mystery. The
-- defect is that the UI offered a move the RPC could not perform, not that the refusal was wrong.
--
-- THE FIX: an explicit TAKE-OVER for the two exclusive types, inside the same transaction.
--   * `invoice`      -> at most one per CLIENT
--   * `city_report`  -> at most one per (client, PROPERTY)
-- Both are OUR rules, not Jobber's, so we are allowed to move them; and the operator has already
-- been told in words whose row is about to lose it before they pressed Save.
--
-- 🛑 WHY THE DELETE CAN BE THIS BLUNT, AND WHY THAT IS LOAD-BEARING RATHER THAN SLOPPY.
-- It runs INSIDE the `if p_patch ? 'communication'` block, which has ALREADY deleted every pref
-- row belonging to the target contact. So any row still holding `invoice` for this client
-- necessarily belongs to a DIFFERENT contact, and "delete the client's invoice row" cannot
-- cannibalise the caller's own. If that earlier delete is ever moved or made conditional, this
-- becomes wrong. The VERIFY exercises a re-save of the existing holder for exactly that reason.
--
-- 🛑 WHAT IT DELIBERATELY DOES NOT DO: `service_report` and `quote_approval` are NOT taken over,
-- because they are not exclusive. Fred: several people are allowed on those. Applying the same
-- delete to them would silently unsubscribe everybody else on the client every time one person
-- was edited, which is the "seed ADDS a recipient nobody ticked" defect from 2026-09-22_1216
-- running in reverse and far more destructive.
--
-- The 23505 handler below is NOT dead code after this change: `client_comm_no_dup_ours` still
-- fires when the submitted array names the same type twice for the same person.
--
-- Spliced from the live body (md5 f5ca90a90d3a784eb3d5a1b5f07df3af), never retyped; the anchor is
-- asserted to occur exactly once.

begin;

do $splice$
declare
  v_src text; v_new text; v_n int;
  v_anchor constant text :=
E'      begin\n        insert into public.client_communication_prefs\n          (client_id, comm_type, contact_id, jobber_contact_id, property_id)';
  v_repl constant text :=
E'      -- 🛑 TAKE-OVER, for the two EXCLUSIVE types only. See this migration''s header: the\n'
'      -- target contact''s own rows were already deleted above, so whatever still holds this\n'
'      -- belongs to somebody else, and moving it is precisely what the operator was shown and\n'
'      -- agreed to. service_report and quote_approval are deliberately NOT taken over - several\n'
'      -- people are allowed on those, and stealing them would unsubscribe everyone silently.\n'
'      if v_t = ''invoice'' then\n'
'        delete from public.client_communication_prefs q\n'
'         where q.client_id = v_client and q.comm_type = ''invoice'';\n'
'      elsif v_t = ''city_report'' then\n'
'        delete from public.client_communication_prefs q\n'
'         where q.client_id = v_client and q.comm_type = ''city_report'' and q.property_id = v_prop;\n'
'      end if;\n'
'\n'
'      begin\n        insert into public.client_communication_prefs\n          (client_id, comm_type, contact_id, jobber_contact_id, property_id)';
begin
  v_src := pg_get_functiondef('client.save_contact_settings(text,bigint,jsonb)'::regprocedure);
  if md5(v_src) <> 'f5ca90a90d3a784eb3d5a1b5f07df3af' then
    raise exception 'save_contact_settings has moved (md5 %). Re-derive the splice.', md5(v_src);
  end if;
  v_n := (length(v_src) - length(replace(v_src, v_anchor, ''))) / length(v_anchor);
  if v_n <> 1 then
    raise exception 'take-over anchor matched % times, expected 1', v_n;
  end if;
  v_new := replace(v_src, v_anchor, v_repl);
  if v_new = v_src then raise exception 'splice produced no change'; end if;
  execute v_new;
end $splice$;

commit;

-- ============================================================================================
-- VERIFY  (run 2026-09-22; rehearsed rolled-back with controls, then re-run against the applied
-- function, then re-tested through the LIVE app on 112-YA)
--
-- Every case runs through the REAL RPC as a staff user, inside begin/rollback:
--
-- 1. 🛑 THE MOVE, which is the whole point: with contact A holding `invoice`, setting `invoice`
--    on contact B SUCCEEDS, and afterwards EXACTLY ONE row holds it and it is B's.
--    Never two, never zero, in one call.
-- 2. THE SAME ACROSS TABLES: a Jobber contact taking `invoice` from one of ours, and back.
--    That is the case a naive per-table implementation gets wrong, and it is the reason the
--    index is on the junction table rather than on either contact table.
-- 3. CITY REPORT IS PER LOCATION: taking it on property X must NOT disturb the holder on
--    property Y. Asserted with 112-YA's two live properties (162 and 1164), because a
--    single-property client cannot tell the two rules apart.
-- 4. 🛑 THE CONTROL THAT STOPS THIS BEING A LICENCE TO STEAL: setting `service_report` on one
--    contact must leave every OTHER contact's `service_report` untouched. If that ever goes
--    red, the take-over has leaked into the non-exclusive types and every edit silently
--    unsubscribes the rest of the client.
-- 5. RE-SAVING THE EXISTING HOLDER is a no-op that leaves them holding it. This is the assertion
--    that catches the delete being reordered above the target's own cleanup: if it ever were,
--    a holder re-saving their own set would delete their own row and end up holding nothing.
-- 6. The 23505 handler is still reachable: the same type twice in one submitted array still
--    raises, and its message still names a person.
-- ============================================================================================
