-- 2026-09-21_1515_derm_recipient_fn.sql
--
-- ONE definition of "who receives this client's DERM manifest", replacing two copies of the
-- same rule that were each held up by the ALPHABET.
--
-- WHY. Both `send-derm-email` (index.ts ~1164-1182) and `derm.visits.client_email` order by
--   property_id NULLS FIRST, contact_role DESC, id
-- and rely on DESC over {accounting, city, primary} yielding primary first. Both carry a
-- comment saying to re-derive it if a fourth role ever appears. That is a heuristic standing
-- in for an invariant, in front of a client-facing compliance email. This replaces it with an
-- explicit rank, which is an impossibility rather than a coincidence.
--
-- ⚠ IT IS DELIBERATELY IDENTICAL TODAY. The role vocabulary is exactly three values (measured
-- 2026-09-21: primary 431, accounting 155, city 21, and there is NO CHECK constraint holding
-- that - the list lives only inside client.create_client_contact / update_client_contact), so
-- rank and DESC agree on every existing row. The three-way verification below asserts that.
-- What changes is the behaviour on a FOURTH role: DESC would sort e.g. 'zulu' ABOVE 'primary'
-- and redirect the manifest; rank sorts anything unknown LAST.
--
-- THE OVERRIDE ARGUMENT exists for the promote confirmation dialog (Fred, 2026-09-21: promoting
-- may move the DERM recipient, but the dialog must say so first). Passing the candidate address
-- as p_override_primary_email answers "and who would receive it afterwards", computed by the
-- SAME function that picks the recipient when the mail is actually sent - so the dialog cannot
-- claim one thing while the sender does another.
--
-- Nothing else changes. No table, no column, no grant on client_contacts.

begin;

create or replace function client.fn_derm_recipient(
  p_client_id              bigint,
  p_override_primary_email text default null
) returns jsonb
language sql
stable
security invoker
set search_path = public, pg_catalog
as $$
  select to_jsonb(t) from (
    select cc.id            as contact_id,
           cc.contact_role,
           cc.property_id,
           case
             when p_override_primary_email is not null
              and cc.property_id is null
              and cc.contact_role = 'primary'
             then p_override_primary_email
             else cc.email
           end              as email
      from public.client_contacts cc
     where cc.client_id = p_client_id
       and coalesce(
             case
               when p_override_primary_email is not null
                and cc.property_id is null
                and cc.contact_role = 'primary'
               then p_override_primary_email
               else cc.email
             end, '') <> ''
     order by cc.property_id nulls first,
              case cc.contact_role
                when 'primary'    then 0
                when 'city'       then 1
                when 'accounting' then 2
                else 3                     -- an unknown role NEVER outranks primary
              end,
              cc.id
     limit 1
  ) t;
$$;

comment on function client.fn_derm_recipient(bigint, text) is
  'The single definition of which client_contacts row receives a client DERM manifest. '
  'Replaces the contact_role DESC alphabetical ordering duplicated in send-derm-email and '
  'derm.visits. Identical to that ordering for the three roles in use; an unknown fourth role '
  'sorts LAST instead of potentially above primary. p_override_primary_email answers "who would '
  'receive it if the client-level primary held this address instead", for the promote dialog. '
  'Returns jsonb {contact_id, contact_role, property_id, email} or NULL when the client has no '
  'emailable contact.';

revoke all on function client.fn_derm_recipient(bigint, text) from public;
revoke all on function client.fn_derm_recipient(bigint, text) from anon;
grant execute on function client.fn_derm_recipient(bigint, text) to authenticated, service_role;

commit;

-- ============================================================================================
-- VERIFY (run separately; this file only creates the function)
--
-- 1. THREE-WAY EQUIVALENCE over every client, which is the check that matters. The new
--    function must agree with BOTH existing implementations on today's data:
--
--    select count(*) as clients,
--           count(*) filter (where old_email is not distinct from new_email) as agree,
--           count(*) filter (where old_email is distinct from new_email)     as differ
--      from (
--        select cl.id,
--               (select cc.email from public.client_contacts cc
--                 where cc.client_id = cl.id and cc.email is not null and cc.email <> ''
--                 order by cc.property_id nulls first, cc.contact_role desc, cc.id
--                 limit 1)                                          as old_email,
--               client.fn_derm_recipient(cl.id) ->> 'email'         as new_email
--          from public.clients cl) s;
--    EXPECT differ = 0.
--
-- 2. POSITIVE CONTROL - the instrument must be able to see a difference. Without it, "0 differ"
--    is an untested comparison. Re-run clause 1 with the rank deliberately inverted
--    (primary => 3, accounting => 0) and confirm differ > 0. If that also returns 0, the
--    comparison is broken, not the data.
--
-- 3. A NON-PRIMARY ANSWER MUST BE REACHABLE. 44 clients have no client-level primary; on those
--    the function must return the accounting or city address, NOT null:
--    select count(*) from public.clients cl
--     where client.fn_derm_recipient(cl.id) ->> 'contact_role' in ('accounting','city');
--    EXPECT > 0. (An all-primary answer would mean the ordering never exercises the tail.)
--
-- 4. THE OVERRIDE must change the answer only for the mirror row, and only when the mirror row
--    is the one that wins:
--    select client.fn_derm_recipient(381)                      as today,
--           client.fn_derm_recipient(381, 'yan@ayache.com')    as after_promote;
--    EXPECT today.email = the client-level primary's address, after_promote.email = yan@ayache.com,
--    and contact_id identical in both.
--
-- 5. PRIVILEGES: anon must hold nothing.
--    select has_function_privilege('anon', 'client.fn_derm_recipient(bigint,text)', 'execute');
--    EXPECT false.
-- ============================================================================================
