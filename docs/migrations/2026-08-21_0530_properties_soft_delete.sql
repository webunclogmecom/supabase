-- 2026-08-21_0530_properties_soft_delete.sql
--
-- WHAT: public.properties gains deleted_at, so a property removed in Jobber can be retired here
--       instead of hard-deleted.
--
-- WHY:  handlePropertyDestroy hard-deletes, and that CANNOT SUCCEED. Proven in production 2026-08-21
--       05:24:57, on the first real PROPERTY_DESTROY webhook this integration has ever received:
--           PROPERTY_DESTROY failed: update or delete on table "properties" violates foreign key
--           constraint "jobs_property_id_fkey" on table "jobs"
--       It is not a race. handleJobDestroy SOFT-deletes (job 1848 survives with
--       job_status='destroyed' still holding property_id=1090), so the parent hard-delete is blocked
--       by its own soft-deleted child. Every property that has ever had a job is unreachable this way.
--
-- 🛑 AND IT IS BROADER THAN JOBS. Nine FKs point at public.properties, and five are NO ACTION:
--       jobs.property_id (a) · visits.property_id (a) · quotes.property_id (a) · notes.property_id (a)
--       ops.visit_requests.property_id (a) · gdos.property_id (n) · client_locations.property_id (n)
--       service_configs.property_id (r) · client_contacts.property_id (c)
--    So a hard delete is blocked by visits and quotes too. Soft-delete sidesteps all nine at once,
--    and it is what Fred's standing never-hard-delete-business-data rule requires anyway.
--
-- CONVENTION FOLLOWED, not invented: derm_manifests, photo_links and visits already use
--    `deleted_at timestamptz`. Same name, same type.
--
-- ⚠ SCOPE, DELIBERATELY NARROW, AND THE REST IS NOT FORGOTTEN. This migration adds the column and an
--    index. It does NOT add `deleted_at IS NULL` to the 30 views that read public.properties. Those
--    were enumerated first and split by exposure:
--       CUSTOMER/APP-FACING (6): client.clients, client.properties, customer.client_access_photos,
--                                customer.clients, customer.permits, customer.work_orders
--       derm (5) · ops (10) · public/internal (9)
--    Filtering all thirty blind is how live data gets hidden by accident, and each needs its own
--    judgement: an operational view should hide a retired property, while an audit or history view
--    should almost certainly still show it. That pass is a separate, reviewed change.
--    ⇒ UNTIL IT LANDS, a soft-deleted property still APPEARS everywhere. That is not a regression -
--      it is exactly today's behaviour, since the hard delete never worked. The only thing changing
--      here is that PROPERTY_DESTROY can now succeed and leave a durable marker.
--
-- ⚠ THE COLUMN ALONE CHANGES NOTHING until webhook-jobber's handlePropertyDestroy is changed to set
--    it. Both ship together; the handler is in the same commit.
--
-- AUDIT (rule 8): public.properties IS audited (trigger audit_properties), so every soft-delete is
--    recorded with old_row/new_row and an actor. No audit change needed.

begin;

alter table public.properties
  add column if not exists deleted_at timestamptz;

comment on column public.properties.deleted_at is
  'Set when the property was removed in Jobber (PROPERTY_DESTROY). The row is RETAINED because nine FKs reference it, five of them NO ACTION, and because jobs/visits keep their history. NULL means live. Readers that must hide retired properties have to filter this explicitly - most views do not yet, see 2026-08-21_0530.';

-- Partial index: every live-data reader asks the same question, and it keeps the common path off the
-- retired rows without indexing them.
create index if not exists properties_live_idx
  on public.properties (client_id)
  where deleted_at is null;

-- ---- VERIFY ------------------------------------------------------------------------------------
do $verify$
declare
  v_col int; v_idx int; v_live int; v_audited int;
begin
  select count(*) into v_col from information_schema.columns
   where table_schema='public' and table_name='properties' and column_name='deleted_at'
     and data_type='timestamp with time zone';
  if v_col <> 1 then raise exception 'VERIFY: deleted_at missing or wrong type'; end if;

  select count(*) into v_idx from pg_indexes
   where schemaname='public' and tablename='properties' and indexname='properties_live_idx';
  if v_idx <> 1 then raise exception 'VERIFY: partial index not created'; end if;

  -- 🛑 NOTHING MAY HAVE BEEN RETIRED BY THIS MIGRATION. Adding a nullable column must leave every
  --    existing row live; a non-zero count here would mean a default crept in.
  select count(*) into v_live from public.properties where deleted_at is not null;
  if v_live <> 0 then
    raise exception 'VERIFY: % properties are already marked deleted - this migration must retire nothing', v_live;
  end if;

  -- the audit trigger must still be attached, or soft-deletes would be unrecorded
  select count(*) into v_audited from pg_trigger
   where tgrelid='public.properties'::regclass and tgname='audit_properties' and not tgisinternal;
  if v_audited <> 1 then raise exception 'VERIFY: audit_properties trigger is missing'; end if;

  raise notice 'VERIFY ok: deleted_at added, index created, 0 rows retired, audit trigger intact';
end $verify$;

commit;
