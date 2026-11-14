-- ROLLBACK of 2026-11-14_0148_client_get_client_emails.sql (B3 of the Client App move).
--
-- Drops exactly the one function it created; nothing else existed to undo (no table, view, trigger or other grant).
-- Nothing on the old Client App host reads it. A portal build that already reads it shows the emails' To, Cc, Bcc and
-- copies as "could not be read" until it is back.

BEGIN;
SET LOCAL lock_timeout = '3s';

drop function client.get_client_emails(bigint, text);

notify pgrst, 'reload schema';

do $verify$
begin
  if to_regprocedure('client.get_client_emails(bigint,text)') is not null then
    raise exception 'verify_fail: client.get_client_emails still exists';
  end if;
  raise notice 'verify ok: client.get_client_emails is gone';
end $verify$;

COMMIT;
