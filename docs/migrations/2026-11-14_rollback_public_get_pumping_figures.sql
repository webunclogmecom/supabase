-- ROLLBACK of 2026-11-14_0140_public_get_pumping_figures.sql (B1 of the Client App move).
--
-- Drops exactly the one function it created; nothing else existed to undo (no table, view, trigger or other grant).
-- Nothing on the old Client App host reads it. A portal build that already reads it shows the gallons and the pumping
-- figures as "could not be read" until it is back.

BEGIN;
SET LOCAL lock_timeout = '3s';

drop function public.get_pumping_figures(bigint, bigint[]);

notify pgrst, 'reload schema';

do $verify$
begin
  if to_regprocedure('public.get_pumping_figures(bigint,bigint[])') is not null then
    raise exception 'verify_fail: public.get_pumping_figures still exists';
  end if;
  raise notice 'verify ok: public.get_pumping_figures is gone';
end $verify$;

COMMIT;
