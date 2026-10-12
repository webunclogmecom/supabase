-- 2026-10-12_1645_313_fre_is_a_test_client.sql
--
-- Fred, 2026-10-12: "313-FRE is a test". Client 563 "Fred Own Restaurant" (0 invoices, 0 visits,
-- 1 live job) has a property at the company yard address and was missing from the non-customer list,
-- so every consumer of public.v_non_customer_clients / fn_is_non_customer treated it as a customer.
-- Same shape as 112-YA and 777-YA (kind 'test').
-- Rule 8: non_customer_clients is already audited (audit_non_customer_clients).

begin;
set local lock_timeout = '3s';

insert into public.non_customer_clients (client_id, client_code, kind, reason, added_by)
select 563, '313-FRE', 'test',
       'Test account "Fred Own Restaurant" (Fred, 2026-10-12: "313-FRE is a test").',
       'claude/2026-10-12'
 where not exists (select 1 from public.non_customer_clients where client_id = 563);

do $$
begin
  if not public.fn_is_non_customer(563, array['test']) then raise exception 'VERIFY 1: 313-FRE not a test client'; end if;
  if not public.fn_is_non_customer(381, array['test']) then raise exception 'VERIFY 2: control 112-YA lost its test kind'; end if;
  if (select count(*) from public.non_customer_clients where client_id = 563) <> 1 then raise exception 'VERIFY 3: duplicate row'; end if;
end $$;

commit;
