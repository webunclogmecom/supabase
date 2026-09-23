-- =============================================================================
-- 2026-09-23_0948_client_clients_intake_status.sql
-- Step 5.1 of Building Apps/docs/2026-09-23_client-intake-build-plan.md
--
-- WHAT. Two columns appended to client.clients so the Clients list can show an
-- Intake status column: the status itself and how many service properties it rolls
-- up. Yan's mock shows this column; nothing in the schema could feed it until now.
--
-- WHY A ROLLUP AT ALL. Fred's decision 1 is that the intake is per PROPERTY, but this
-- table is per CLIENT, so the same question the Grease trap size column faced on
-- 2026-08-19 applies: which property's value does a client row show? Measured today:
--   463 clients have exactly ONE live service property
--     8 clients have more than one, the largest has SIX
-- So for 463 of 471 the rollup is just "that property's status" and the interesting
-- case is the 8.
--
-- THE RULE: show the WORST status across the client's live service properties, and
-- expose the count so the UI can say "1 of 3" when it matters. Worst rather than best
-- because this column exists to tell the office where work is still owed; a client
-- with one Complete property and two untouched ones is not Complete.
-- ⚠ Rank is Nothing < Incomplete < Complete. 'Verified' is deliberately absent: it
--   describes the PUBLISHED page, which does not exist yet. When it ships it becomes
--   rank 3 and this expression gains one arm.
--
-- ⚠ intake_status is NULL, not 'Nothing', for a client with NO live service property
--   (billing-only clients). "We have nothing to survey" and "we have a property we
--   have never surveyed" are different facts and the column must not merge them.
--
-- WHY CREATE OR REPLACE AND NOT DROP. A DROP discards the grants, and this view is
-- read by the Client App as `authenticated`. Replace preserves them. Columns may only
-- be APPENDED by a replace, which is what this does: the existing 15 keep their names,
-- types and order, and the VERIFY block asserts that rather than trusting it.
--
-- RULE 8, AUDIT: a view, nothing to opt in.
-- ATOMIC: no COMMIT, so a failed assertion rolls the whole migration back.
-- =============================================================================

create or replace view client.clients as
 SELECT c.id,
    c.client_code,
    c.name,
    c.status,
    c.balance,
    c.notes,
    c.created_at,
    c.updated_at,
    c.group_id,
    c.client_class,
    c.client_class_source,
    ( SELECT
                CASE
                    WHEN l.source_id ~ '^[0-9]+$'::text THEN 'https://secure.getjobber.com/clients/'::text || l.source_id
                    WHEN (length(l.source_id) % 4) = 0 AND l.source_id ~ '^[A-Za-z0-9+/]+={0,2}$'::text THEN 'https://secure.getjobber.com/clients/'::text || split_part(convert_from(decode(l.source_id, 'base64'::text), 'UTF8'::name), '/'::text, '-1'::integer)
                    ELSE NULL::text
                END AS "case"
           FROM entity_source_links l
          WHERE l.entity_type = 'client'::text AND l.source_system = 'jobber'::text AND l.entity_id = c.id
         LIMIT 1) AS jobber_url,
    dz.zone_id,
    dz.zone_code,
    gt.grease_trap_size_gallons,
    ik.intake_status,
    ik.intake_property_count
   FROM clients c
     LEFT JOIN LATERAL ( SELECT
                CASE
                    WHEN count(DISTINCT p.zone_id) = 1 THEN min(p.zone_id)
                    ELSE NULL::bigint
                END AS zone_id,
                CASE
                    WHEN count(DISTINCT p.zone_id) = 1 THEN min(z.code)
                    WHEN count(DISTINCT p.zone_id) > 1 THEN 'MIXED'::text
                    ELSE NULL::text
                END AS zone_code
           FROM properties p
             JOIN zones z ON z.id = p.zone_id
          WHERE p.client_id = c.id AND p.zone_id IS NOT NULL AND p.deleted_at IS NULL) dz ON true
     LEFT JOIN LATERAL ( SELECT COALESCE(max(p.grease_trap_size_gallons) FILTER (WHERE p.is_billing IS DISTINCT FROM true), max(p.grease_trap_size_gallons) FILTER (WHERE p.is_billing IS TRUE)) AS grease_trap_size_gallons
           FROM properties p
          WHERE p.client_id = c.id AND p.grease_trap_size_gallons IS NOT NULL AND p.deleted_at IS NULL) gt ON true
     LEFT JOIN LATERAL ( SELECT
                count(*)::integer AS intake_property_count,
                CASE min(
                        CASE v.intake_status
                            WHEN 'Nothing'::text    THEN 0
                            WHEN 'Incomplete'::text THEN 1
                            WHEN 'Complete'::text   THEN 2
                            ELSE 9
                        END)
                    WHEN 0 THEN 'Nothing'::text
                    WHEN 1 THEN 'Incomplete'::text
                    WHEN 2 THEN 'Complete'::text
                    ELSE NULL::text
                END AS intake_status
           FROM client.v_property_intake v
          WHERE v.client_id = c.id) ik ON true;

comment on view client.clients is
  'Client rows for the Client App list. intake_status is the WORST intake status across '
  'the client''s live service properties (Nothing < Incomplete < Complete), because the '
  'column exists to show where work is still owed; intake_property_count is how many '
  'properties it rolls up, so the UI can qualify it when a client has several. NULL '
  'status means the client has no live service property at all, which is not the same '
  'as never having been surveyed.';

-- ------------------------------------------------------------------- VERIFY
do $verify$
declare
  v_cols text[];
  v_prop bigint; v_client bigint; v_id bigint;
  v_status text; v_count int;
  v_n int;
begin
  -- V1. THE EXISTING 15 COLUMNS ARE UNTOUCHED, IN ORDER. A replace cannot change them,
  -- but asserting it is what proves the replace did what was intended rather than
  -- something that merely compiled.
  select array_agg(column_name order by ordinal_position) into v_cols
    from information_schema.columns where table_schema='client' and table_name='clients';
  if v_cols[1:15] <> array['id','client_code','name','status','balance','notes','created_at',
                           'updated_at','group_id','client_class','client_class_source','jobber_url',
                           'zone_id','zone_code','grease_trap_size_gallons'] then
    raise exception 'VERIFY V1: the first 15 columns changed: %', v_cols[1:15];
  end if;
  if array_length(v_cols,1) <> 17 then
    raise exception 'VERIFY V1b: expected 17 columns, got %', array_length(v_cols,1);
  end if;

  -- V2. grants survived the replace
  if not has_table_privilege('authenticated','client.clients','SELECT') then
    raise exception 'VERIFY V2: authenticated lost SELECT on client.clients';
  end if;

  -- V3. with no intakes anywhere, every client holding a service property reads Nothing
  select count(*) into v_n from client.clients where intake_status is not null and intake_status <> 'Nothing';
  if v_n <> 0 then raise exception 'VERIFY V3: % clients are not Nothing before any intake exists', v_n; end if;

  select count(*) into v_n from client.clients where intake_status = 'Nothing';
  if v_n < 400 then raise exception 'VERIFY V3b: only % clients read Nothing, expected the vast majority', v_n; end if;

  -- V4. a billing-only client (no live service property) must be NULL, not Nothing
  select count(*) into v_n from client.clients where intake_status is null;
  raise notice 'clients with no live service property (NULL status): %', v_n;

  -- V5. THE WORST RULE, which is the whole point of this column and is why this
  -- assertion is written against the client's ACTUAL property count rather than
  -- against an assumed one. The first draft of this block assumed the test client had
  -- a single property, expected Incomplete, and failed: 112-YA has more than one, so
  -- surveying ONE of them correctly leaves the client at Nothing. That failure is the
  -- rule working, and it is exactly what a client with three buildings will look like.
  select p.client_id into v_client
    from public.properties p
   where p.client_id = (select id from public.clients where client_code='112-YA')
     and p.deleted_at is null and coalesce(p.is_billing,false)=false
   order by p.id limit 1;

  select count(*) into v_n from public.properties
   where client_id = v_client and deleted_at is null and coalesce(is_billing,false)=false;
  raise notice 'test client has % live service properties', v_n;

  select p.id into v_prop from public.properties p
   where p.client_id = v_client and p.deleted_at is null and coalesce(p.is_billing,false)=false
   order by p.id limit 1;

  insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
  values (v_prop, public.fn_intake_form_current(),
          '["access_entry.gate","grease_trap.sample_ports"]'::jsonb,
          '[TEST] rollup verify', '{"access_entry.gate":{"value":"yes"}}'::jsonb, now())
  returning id into v_id;

  select intake_status, intake_property_count into v_status, v_count
    from client.clients where id = v_client;
  if v_count <> v_n then
    raise exception 'VERIFY V5: intake_property_count is % but the client has % service properties', v_count, v_n;
  end if;
  if v_n = 1 then
    if v_status <> 'Incomplete' then
      raise exception 'VERIFY V5b: a single-property client with a partial intake must read Incomplete, got %', v_status;
    end if;
  else
    if v_status <> 'Nothing' then
      raise exception 'VERIFY V5c: % properties with only one surveyed must still read Nothing (worst wins), got %', v_n, v_status;
    end if;
  end if;

  -- V6. survey EVERY service property of that client, then the worst becomes Incomplete
  insert into public.property_intakes (property_id, form_snapshot, requested, collector, answers, submitted_at)
  select p.id, public.fn_intake_form_current(),
         '["access_entry.gate","grease_trap.sample_ports"]'::jsonb,
         '[TEST] rollup verify', '{"access_entry.gate":{"value":"yes"}}'::jsonb, now()
    from public.properties p
   where p.client_id = v_client and p.deleted_at is null and coalesce(p.is_billing,false)=false
     and p.id <> v_prop;

  select intake_status into v_status from client.clients where id = v_client;
  if v_status <> 'Incomplete' then
    raise exception 'VERIFY V6: with every property partially surveyed the client must read Incomplete, got %', v_status;
  end if;

  delete from public.property_intakes where collector = '[TEST] rollup verify';

  select intake_status into v_status from client.clients where id = v_client;
  if v_status <> 'Nothing' then
    raise exception 'VERIFY V7: after cleanup the client should be back to Nothing, got %', v_status;
  end if;

  raise notice 'VERIFY: intake rollup assertions passed';
end $verify$;

notify pgrst, 'reload schema';
