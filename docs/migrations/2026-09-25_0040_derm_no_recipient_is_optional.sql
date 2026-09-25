-- 2026-09-25 00:40 ET
-- client.v_derm_no_recipient is a LIST, not a health check. Relabel its comment.
--
-- WHY (Fred, 2026-09-25): "So a client doesn't MUST have a contact for everything it can be
-- optional". A client may have no contact for a communication, including the DERM service report,
-- and that is a valid choice, not a defect. The view's comment (from 2026-09-23_1425) opened with
-- "EMPTY IS HEALTHY" and "so the report cannot be sent", which reads as a defect list and invites
-- wiring it into the health escalation chain. It was never wired (measured today: no dependent view,
-- no function references it) and it must not be.
--
-- The view itself is unchanged: it still lists live DERM-active clients whose service report
-- resolves to zero recipients (19 rows today), which answers "who gets no service report" when a
-- person asks. Only the comment changes. The 2026-09-23_1425 file is left as the record of what was
-- believed then.
--
-- Rule 8: no table and no column changes; nothing to audit.

begin;

comment on view client.v_derm_no_recipient is
  'INFORMATIONAL, NOT A DEFECT (Fred, 2026-09-25: a client does not have to have a contact for '
  'every communication; it can be optional). Live DERM-active clients whose service report resolves '
  'to zero recipients (client.fn_derm_recipients returns an empty array), so no service report is '
  'emailed to the client. Do not wire this into health alerts. Keyed on the outcome, not on whether a '
  'communication preference exists.';

-- VERIFY
do $$
declare v_cmt text := obj_description('client.v_derm_no_recipient'::regclass); n int;
begin
  if v_cmt is null or position('NOT A DEFECT' in v_cmt) = 0 then
    raise exception 'VERIFY: comment not applied: %', v_cmt;
  end if;
  if position('EMPTY IS HEALTHY' in v_cmt) > 0 then
    raise exception 'VERIFY: the old health framing is still in the comment';
  end if;
  select count(*) into n from client.v_derm_no_recipient;   -- the view still reads (control)
  raise notice 'v_derm_no_recipient rows=% (unchanged view, comment only)', n;
end $$;

commit;
