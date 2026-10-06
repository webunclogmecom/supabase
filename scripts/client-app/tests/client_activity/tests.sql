-- tests.sql: the smoke tests of client.get_client_activity (spec section 5). __FN__ is the function under test.
-- Everything runs in ONE DO block that always ends by raising, so every write here is rolled back
-- (synthetic audit.logs rows, the one client_status_changes row, the one client_create_attempts row).
-- The raised message carries the results as JSON: TEST_RESULTS:{...}
-- Client 112-YA (381) is the sanctioned test client. Each case writes into its own 10-minute window after now().
do $tests$
declare
  t0  timestamptz := now();
  res jsonb := '[]'::jsonb;
  v   jsonb;
  w   jsonb;
  p1  bigint; p2 bigint; j1 bigint; jn text; c1 bigint; z1 bigint := 1; z2 bigint := 2;
  tx  bigint := 9000000000000;
  st  text;
  fred  constant jsonb := '{"sub":"5ca25eb1-4abe-4aa0-b0d6-b7ca4a47562b","email":"fred@ayache.com","role":"authenticated"}';
  -- one case = one window
  function_win int;
begin
  select id into p1 from public.properties where client_id = 381 and deleted_at is null order by id limit 1;
  select id into p2 from public.properties where client_id = 381 and deleted_at is null and id <> p1 order by id limit 1;
  select id, job_number into j1, jn from public.jobs where client_id = 381 order by id desc limit 1;
  select id into c1 from public.client_contacts where client_id = 381 order by id limit 1;

  create temp table _log (n int) on commit drop;   -- placeholder so the helper below has a stable search_path

  -- helper: write one audit row
  create or replace function pg_temp.t_log(p_tbl text, p_op text, p_old jsonb, p_new jsonb, p_at timestamptz, p_tx bigint,
                                           p_app text, p_path text, p_email text, p_role text default null) returns void
  language sql as $f$
    insert into audit.logs (table_schema, table_name, record_pk, operation, old_row, new_row, db_role, jwt_claims, changed_at, app_source, request_context, txid)
    values ('public', p_tbl, jsonb_build_object('id', coalesce(p_new, p_old) -> 'id'), p_op, p_old, p_new, 'postgres',
            case when p_email is null and p_role is null then null
                 else jsonb_strip_nulls(jsonb_build_object('email', p_email, 'role', coalesce(p_role, 'authenticated'))) end,
            p_at, p_app, case when p_path is null then null else jsonb_build_object('path', p_path, 'method', 'PATCH') end, p_tx)
  $f$;

  -- helper: the entries of one window
  create or replace function pg_temp.t_win(p_client bigint, p_inc boolean, p_from timestamptz) returns jsonb
  language sql as $f$
    select coalesce(jsonb_agg(to_jsonb(x) order by x.at, x.key), '[]'::jsonb)
      from __FN__(p_client, p_inc, null, null) x
     where x.at >= p_from - interval '1 second' and x.at < p_from + interval '10 minutes'
  $f$;

  -- C4 first: the status card's own audit row is written by the real trigger at now(), so its window is t0
  insert into public.client_status_changes (client_id, old_status, new_status, reason, changed_by_email, changed_at, event)
  values (381, 'ACTIVE', 'PAUSED', '[TEST] reason', 'fred@ayache.com', t0, 'status_change');
  perform pg_temp.t_log('clients', 'UPDATE', '{"id":381,"status":"ACTIVE"}', '{"id":381,"status":"PAUSED"}',
                        t0 + interval '6 seconds', tx + 40, 'client-app', '/rpc/update_client_status', 'fred@ayache.com');
  v := pg_temp.t_win(381, true, t0);
  res := res || jsonb_build_object('case', 'C4 status card, its clients diff 6 s later in another txid is not shown twice',
    'ok', jsonb_array_length(v) = 1 and v -> 0 -> 'status_card' ->> 'reason' = '[TEST] reason'
          and v -> 0 -> 'status_card' ->> 'changed_by_label' = 'Fred'
          and not exists (select 1 from jsonb_array_elements(v) e, jsonb_array_elements(e -> 'changes') c where c ->> 'label' = 'Status'),
    'got', v);

  -- C1 a zone change on 2 properties in one save
  perform pg_temp.t_log('properties', 'UPDATE', jsonb_build_object('id', p1, 'client_id', 381, 'zone_id', z1, 'address', '[TEST] A'),
                        jsonb_build_object('id', p1, 'client_id', 381, 'zone_id', z2, 'address', '[TEST] A'),
                        t0 + interval '10 minutes', tx + 10, 'client-app', '/rpc/update_client_zone', 'fred@ayache.com');
  perform pg_temp.t_log('properties', 'UPDATE', jsonb_build_object('id', p2, 'client_id', 381, 'zone_id', z1, 'address', '[TEST] B'),
                        jsonb_build_object('id', p2, 'client_id', 381, 'zone_id', z2, 'address', '[TEST] B'),
                        t0 + interval '10 minutes', tx + 10, 'client-app', '/rpc/update_client_zone', 'fred@ayache.com');
  v := pg_temp.t_win(381, false, t0 + interval '10 minutes');
  res := res || jsonb_build_object('case', 'C1 zone on 2 sites is one entry, one Zone line "on 2 sites", by Fred',
    'ok', jsonb_array_length(v) = 1 and v -> 0 ->> 'actor_label' = 'Fred' and jsonb_array_length(v -> 0 -> 'changes') = 1
          and v -> 0 -> 'changes' -> 0 ->> 'new' like '% on 2 sites',
    'got', v);

  -- C2 one save split across two calls 3 s apart (same app, the second leg names nobody); and 8 s apart
  perform pg_temp.t_log('properties', 'UPDATE', jsonb_build_object('id', p1, 'client_id', 381, 'notes', 'a'),
                        jsonb_build_object('id', p1, 'client_id', 381, 'notes', '[TEST] b'),
                        t0 + interval '20 minutes', tx + 20, 'client-app', '/rpc/update_property_operational', 'fred@ayache.com');
  perform pg_temp.t_log('properties', 'UPDATE', jsonb_build_object('id', p1, 'client_id', 381, 'access_notes', 'a'),
                        jsonb_build_object('id', p1, 'client_id', 381, 'access_notes', '[TEST] b'),
                        t0 + interval '20 minutes 3 seconds', tx + 21, 'client-app', '/rpc/update_property_city_email', null);
  v := pg_temp.t_win(381, false, t0 + interval '20 minutes');
  res := res || jsonb_build_object('case', 'C2 a save split into two calls 3 s apart is one entry by Fred',
    'ok', jsonb_array_length(v) = 1 and jsonb_array_length(v -> 0 -> 'changes') = 2 and v -> 0 ->> 'actor_label' = 'Fred', 'got', v);
  perform pg_temp.t_log('properties', 'UPDATE', jsonb_build_object('id', p1, 'client_id', 381, 'notes', 'a'),
                        jsonb_build_object('id', p1, 'client_id', 381, 'notes', '[TEST] c'),
                        t0 + interval '30 minutes', tx + 30, 'client-app', '/rpc/update_property_operational', 'fred@ayache.com');
  perform pg_temp.t_log('properties', 'UPDATE', jsonb_build_object('id', p1, 'client_id', 381, 'access_notes', 'a'),
                        jsonb_build_object('id', p1, 'client_id', 381, 'access_notes', '[TEST] c'),
                        t0 + interval '30 minutes 8 seconds', tx + 31, 'client-app', '/rpc/update_property_city_email', null);
  v := pg_temp.t_win(381, true, t0 + interval '30 minutes');
  res := res || jsonb_build_object('case', 'C2n the same two calls 8 s apart are two entries',
    'ok', jsonb_array_length(v) = 2, 'got', v);

  -- C3 a Jobber balance-only change is background; a synced_at-only refresh is not there at all
  perform pg_temp.t_log('clients', 'UPDATE', '{"id":381,"balance":1}', '{"id":381,"balance":2}',
                        t0 + interval '40 minutes', tx + 50, 'jobber', '/clients', null, 'service_role');
  perform pg_temp.t_log('client_jobber_contacts', 'UPDATE', '{"id":999001,"client_id":381,"synced_at":"2026-01-01"}',
                        '{"id":999001,"client_id":381,"synced_at":"2026-01-02"}',
                        t0 + interval '40 minutes 30 seconds', tx + 51, 'client-app', '/client_jobber_contacts', null, 'service_role');
  v := pg_temp.t_win(381, true, t0 + interval '40 minutes');
  w := pg_temp.t_win(381, false, t0 + interval '40 minutes');
  res := res || jsonb_build_object('case', 'C3 balance-only is background (gone with the switch off); synced_at-only never shows',
    'ok', jsonb_array_length(v) = 1 and (v -> 0 ->> 'is_system')::boolean and v -> 0 ->> 'actor_label' = 'Jobber'
          and jsonb_array_length(w) = 0, 'got', v);

  -- C5 job status action_required -> closed -> archived, 60 s apart, no person: one "Archived"; 3 minutes apart: two
  perform pg_temp.t_log('jobs', 'UPDATE', jsonb_build_object('id', j1, 'client_id', 381, 'job_number', jn, 'job_status', 'action_required'),
                        jsonb_build_object('id', j1, 'client_id', 381, 'job_number', jn, 'job_status', 'closed'),
                        t0 + interval '50 minutes', tx + 60, 'jobber', '/jobs', null, 'service_role');
  perform pg_temp.t_log('jobs', 'UPDATE', jsonb_build_object('id', j1, 'client_id', 381, 'job_number', jn, 'job_status', 'closed'),
                        jsonb_build_object('id', j1, 'client_id', 381, 'job_number', jn, 'job_status', 'archived'),
                        t0 + interval '51 minutes', tx + 61, 'sql', '/jobs', null, 'service_role');
  v := pg_temp.t_win(381, true, t0 + interval '50 minutes');
  res := res || jsonb_build_object('case', 'C5 a 60 s Jobber close chain is one "Archived" entry, Action required -> Archived',
    'ok', jsonb_array_length(v) = 1 and v -> 0 ->> 'title' = 'Archived'
          and v -> 0 -> 'changes' -> 0 ->> 'old' = 'Action required' and v -> 0 -> 'changes' -> 0 ->> 'new' = 'Archived'
          and not (v -> 0 ->> 'is_system')::boolean, 'got', v);
  perform pg_temp.t_log('jobs', 'UPDATE', jsonb_build_object('id', j1, 'client_id', 381, 'job_number', jn, 'job_status', 'action_required'),
                        jsonb_build_object('id', j1, 'client_id', 381, 'job_number', jn, 'job_status', 'closed'),
                        t0 + interval '60 minutes', tx + 62, 'jobber', '/jobs', null, 'service_role');
  perform pg_temp.t_log('jobs', 'UPDATE', jsonb_build_object('id', j1, 'client_id', 381, 'job_number', jn, 'job_status', 'closed'),
                        jsonb_build_object('id', j1, 'client_id', 381, 'job_number', jn, 'job_status', 'archived'),
                        t0 + interval '63 minutes', tx + 63, 'sql', '/jobs', null, 'service_role');
  v := pg_temp.t_win(381, true, t0 + interval '60 minutes');
  res := res || jsonb_build_object('case', 'C5n the same legs 3 minutes apart are two entries', 'ok', jsonb_array_length(v) = 2, 'got', v);

  -- C6 a communication-preference replace of the same set shows nothing; moving Invoice to another contact is one entry
  perform pg_temp.t_log('client_communication_prefs', 'DELETE', jsonb_build_object('id', 999101, 'client_id', 381, 'comm_type', 'invoice', 'contact_id', c1), null,
                        t0 + interval '70 minutes', tx + 70, 'client-app', '/rpc/save_contact_settings', 'fred@ayache.com');
  perform pg_temp.t_log('client_communication_prefs', 'INSERT', null, jsonb_build_object('id', 999102, 'client_id', 381, 'comm_type', 'invoice', 'contact_id', c1),
                        t0 + interval '70 minutes', tx + 70, 'client-app', '/rpc/save_contact_settings', 'fred@ayache.com');
  v := pg_temp.t_win(381, true, t0 + interval '70 minutes');
  res := res || jsonb_build_object('case', 'C6 re-saving the same preferences shows nothing', 'ok', jsonb_array_length(v) = 0, 'got', v);
  perform pg_temp.t_log('client_communication_prefs', 'DELETE', jsonb_build_object('id', 999103, 'client_id', 381, 'comm_type', 'invoice', 'contact_id', c1), null,
                        t0 + interval '80 minutes', tx + 80, 'client-app', '/rpc/save_contact_settings', 'fred@ayache.com');
  perform pg_temp.t_log('client_communication_prefs', 'INSERT', null, jsonb_build_object('id', 999104, 'client_id', 381, 'comm_type', 'invoice', 'contact_id', c1 + 1),
                        t0 + interval '80 minutes', tx + 80, 'client-app', '/rpc/save_contact_settings', 'fred@ayache.com');
  v := pg_temp.t_win(381, true, t0 + interval '80 minutes');
  res := res || jsonb_build_object('case', 'C6s moving Invoice to another contact is one entry (No longer receives / Now receives)',
    'ok', jsonb_array_length(v) = 1 and jsonb_array_length(v -> 0 -> 'changes') = 2, 'got', v);

  -- C7 a line item deleted and re-inserted unchanged in two transactions 1 s apart (the Jobber sync) shows nothing
  perform pg_temp.t_log('line_items', 'DELETE', jsonb_build_object('id', 999201, 'job_id', j1, 'name', '[TEST] Pumping', 'quantity', 1, 'unit_price', 200), null,
                        t0 + interval '90 minutes', tx + 90, 'sql', '/line_items', null, 'service_role');
  perform pg_temp.t_log('line_items', 'INSERT', null, jsonb_build_object('id', 999202, 'job_id', j1, 'name', '[TEST] Pumping', 'quantity', 1, 'unit_price', 200),
                        t0 + interval '90 minutes 1 second', tx + 91, 'sql', '/line_items', null, 'service_role');
  v := pg_temp.t_win(381, true, t0 + interval '90 minutes');
  res := res || jsonb_build_object('case', 'C7 a line item rewritten unchanged across two transactions shows nothing', 'ok', jsonb_array_length(v) = 0, 'got', v);

  -- C8 a hard-deleted contact is listed; a property moved to another client shows on both clients
  perform pg_temp.t_log('client_contacts', 'DELETE', jsonb_build_object('id', 999301, 'client_id', 381, 'name', '[TEST] Gone'), null,
                        t0 + interval '100 minutes', tx + 100, 'client-app', '/rpc/delete_client_contact', 'fred@ayache.com');
  perform pg_temp.t_log('properties', 'UPDATE', jsonb_build_object('id', 999302, 'client_id', 381, 'address', '[TEST] Moved'),
                        jsonb_build_object('id', 999302, 'client_id', 247, 'address', '[TEST] Moved'),
                        t0 + interval '100 minutes 30 seconds', tx + 101, 'jobber', '/properties', null, 'service_role');
  v := pg_temp.t_win(381, true, t0 + interval '100 minutes');
  w := pg_temp.t_win(247, true, t0 + interval '100 minutes');
  res := res || jsonb_build_object('case', 'C8 a deleted contact is listed; a moved property shows on the old and the new client',
    'ok', exists (select 1 from jsonb_array_elements(v) e where e ->> 'title' = 'Contact removed' and not (e ->> 'is_system')::boolean)
          and exists (select 1 from jsonb_array_elements(v) e where e ->> 'subject' like '[TEST] Moved%')
          and exists (select 1 from jsonb_array_elements(w) e where e ->> 'subject' like '[TEST] Moved%'),
    'got', v || w);

  -- C9 an intake accept and its property diff are one entry with the lock box old and new (synthetic [TEST] values)
  perform pg_temp.t_log('property_intake_accepts', 'INSERT', null,
                        jsonb_build_object('id', 999401, 'intake_id', 999, 'property_id', p1, 'question_key', 'access_entry.lock_box_code', 'actor', 'fred@ayache.com'),
                        t0 + interval '110 minutes', tx + 110, 'picture-planner', '/rpc/accept_intake_answers', 'fred@ayache.com');
  perform pg_temp.t_log('properties', 'UPDATE', jsonb_build_object('id', p1, 'client_id', 381, 'lock_box_key', '[TEST] A'),
                        jsonb_build_object('id', p1, 'client_id', 381, 'lock_box_key', '[TEST] B'),
                        t0 + interval '110 minutes', tx + 110, 'picture-planner', '/rpc/accept_intake_answers', 'fred@ayache.com');
  perform pg_temp.t_log('property_intake_accepts', 'INSERT', null,
                        jsonb_build_object('id', 999402, 'intake_id', 998, 'property_id', p1, 'question_key', 'grease_trap.sample_ports', 'actor', 'fred@ayache.com'),
                        t0 + interval '115 minutes', tx + 115, 'picture-planner', '/rpc/accept_intake_answers', 'fred@ayache.com');
  perform pg_temp.t_log('properties', 'UPDATE', jsonb_build_object('id', p1, 'client_id', 381, 'sample_port_count', 1),
                        jsonb_build_object('id', p1, 'client_id', 381, 'sample_port_count', 2),
                        t0 + interval '115 minutes', tx + 115, 'picture-planner', '/rpc/accept_intake_answers', 'fred@ayache.com');
  v := pg_temp.t_win(381, false, t0 + interval '110 minutes');
  res := res || jsonb_build_object('case', 'C9 intake accepts: one entry each, "Accepted from Site survey form #N", Lock box [TEST] A -> [TEST] B, Sample ports 1 -> 2',
    'ok', jsonb_array_length(v) = 2 and v -> 0 ->> 'title' = 'Accepted from Site survey form #999'
          and v -> 0 -> 'changes' -> 0 ->> 'old' = '[TEST] A' and v -> 0 -> 'changes' -> 0 ->> 'new' = '[TEST] B'
          and v -> 1 ->> 'title' = 'Accepted from Site survey form #998' and v -> 1 -> 'changes' -> 0 ->> 'label' = 'Sample ports',
    'got', v);

  -- C10 a Client App creation is one "Client created" entry with the requester's name
  insert into public.client_create_attempts (idempotency_key, requested_by, payload, status, client_id, created_at)
  values (gen_random_uuid(), 'fred@ayache.com', '{}'::jsonb, 'created', 381, '2000-01-01');
  perform pg_temp.t_log('clients', 'INSERT', null, '{"id":381,"name":"[TEST] Yan","client_code":"112-YA"}',
                        t0 + interval '120 minutes', tx + 120, 'jobber', '/rpc/fn_jobber_resolve_client', null, 'service_role');
  v := pg_temp.t_win(381, false, t0 + interval '120 minutes');
  res := res || jsonb_build_object('case', 'C10 a creation is one "Client created" entry by the requester',
    'ok', jsonb_array_length(v) = 1 and v -> 0 ->> 'title' = 'Client created' and v -> 0 ->> 'actor_label' = 'Fred', 'got', v);

  -- C11 invoices: the shell fill is "Invoice created", then paid; a move to past due is background
  perform pg_temp.t_log('invoices', 'UPDATE', '{"id":999501,"client_id":null,"invoice_status":null}',
                        '{"id":999501,"client_id":381,"invoice_number":"T1","invoice_status":"awaiting_payment","total":100}',
                        t0 + interval '130 minutes', tx + 130, 'sql', '/invoices', null, 'service_role');
  perform pg_temp.t_log('invoices', 'UPDATE', '{"id":999501,"client_id":381,"invoice_number":"T1","invoice_status":"awaiting_payment","total":100}',
                        '{"id":999501,"client_id":381,"invoice_number":"T1","invoice_status":"paid","total":100}',
                        t0 + interval '131 minutes', tx + 131, 'sql', '/invoices', null, 'service_role');
  perform pg_temp.t_log('invoices', 'UPDATE', '{"id":999502,"client_id":381,"invoice_number":"T2","invoice_status":"awaiting_payment"}',
                        '{"id":999502,"client_id":381,"invoice_number":"T2","invoice_status":"past_due"}',
                        t0 + interval '132 minutes', tx + 132, 'sql', '/invoices', null, 'service_role');
  v := pg_temp.t_win(381, false, t0 + interval '130 minutes');
  w := pg_temp.t_win(381, true, t0 + interval '130 minutes');
  res := res || jsonb_build_object('case', 'C11 Invoice created (Awaiting payment, $100.00) and Invoice paid shown; past due only with the switch on',
    'ok', jsonb_array_length(v) = 2 and v -> 0 ->> 'title' = 'Invoice created' and v -> 1 ->> 'title' = 'Invoice paid'
          and jsonb_array_length(w) = 3, 'got', w);

  -- C12 a person's map pin move and county edit are visible with the switch off
  perform pg_temp.t_log('properties', 'UPDATE', jsonb_build_object('id', p1, 'client_id', 381, 'latitude', 25.1, 'longitude', -80.1, 'county', 'Dade'),
                        jsonb_build_object('id', p1, 'client_id', 381, 'latitude', 25.2, 'longitude', -80.2, 'county', 'Broward'),
                        t0 + interval '140 minutes', tx + 140, 'client-app', '/rpc/update_property_operational', 'fred@ayache.com');
  v := pg_temp.t_win(381, false, t0 + interval '140 minutes');
  res := res || jsonb_build_object('case', 'C12 a person''s pin move and county edit are visible with the switch off',
    'ok', jsonb_array_length(v) = 1 and jsonb_array_length(v -> 0 -> 'changes') = 2, 'got', v);

  -- C13 a person-less writer touching 21 clients in 10 minutes is background; a DELETE inside it stays visible
  for i in 0..20 loop
    perform pg_temp.t_log('properties', 'UPDATE', jsonb_build_object('id', 999600 + i, 'client_id', case when i = 0 then 381 else 900000000 + i end, 'name', 'a'),
                          jsonb_build_object('id', 999600 + i, 'client_id', case when i = 0 then 381 else 900000000 + i end, 'name', '[TEST] burst'),
                          t0 + interval '150 minutes' + i * interval '20 seconds', tx + 150 + i, 'sql', '/properties', null, 'service_role');
  end loop;
  perform pg_temp.t_log('properties', 'DELETE', jsonb_build_object('id', 999699, 'client_id', 381, 'address', '[TEST] burst gone'), null,
                        t0 + interval '155 minutes', tx + 199, 'sql', '/properties', null, 'service_role');
  v := pg_temp.t_win(381, false, t0 + interval '150 minutes');
  w := pg_temp.t_win(381, true, t0 + interval '150 minutes');
  res := res || jsonb_build_object('case', 'C13 a 21-client burst is background; the DELETE inside it stays visible',
    'ok', jsonb_array_length(v) = 1 and v -> 0 ->> 'title' = 'Property removed' and jsonb_array_length(w) = 2, 'got', w);

  -- C14 a person-less 'sql' REST job close is visible
  perform pg_temp.t_log('jobs', 'UPDATE', jsonb_build_object('id', j1, 'client_id', 381, 'job_number', jn, 'job_status', 'active'),
                        jsonb_build_object('id', j1, 'client_id', 381, 'job_number', jn, 'job_status', 'closed'),
                        t0 + interval '160 minutes', tx + 160, 'sql', '/jobs', null, 'service_role');
  v := pg_temp.t_win(381, false, t0 + interval '160 minutes');
  res := res || jsonb_build_object('case', 'C14 a person-less job close is visible ("Closed")',
    'ok', jsonb_array_length(v) = 1 and v -> 0 ->> 'title' = 'Closed', 'got', v);

  -- C17 a staff email with no employees row never reaches the output
  perform pg_temp.t_log('properties', 'UPDATE', jsonb_build_object('id', p1, 'client_id', 381, 'notes', 'a'),
                        jsonb_build_object('id', p1, 'client_id', 381, 'notes', '[TEST] by an unknown login'),
                        t0 + interval '170 minutes', tx + 170, 'client-app', '/rpc/update_property_operational', 'nobody-test@ayache.com');
  v := pg_temp.t_win(381, false, t0 + interval '170 minutes');
  res := res || jsonb_build_object('case', 'C17 an unmapped staff email reads "Staff (no name on file)"',
    'ok', jsonb_array_length(v) = 1 and v -> 0 ->> 'actor_label' = 'Staff (no name on file)'
          and position('nobody-test' in v::text) = 0, 'got', v);

  -- C18 no cap: every entry comes back when p_limit is null
  select count(*) into function_win from __FN__(381, true, null, null);
  res := res || jsonb_build_object('case', 'C18 p_limit null returns more than 50 entries', 'ok', function_win > 50, 'got', function_win);

  -- C19 a signed-in non-staff user is refused (42501); nobody signed in is refused (28000)
  perform set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-000000000001","email":"someone@gmail.com","role":"authenticated"}', true);
  begin
    perform 1 from __FN__(381, false, null, null);
    st := 'no error';
  exception when others then st := sqlstate;
  end;
  perform set_config('request.jwt.claims', '{}', true);
  declare st2 text;
  begin
    begin
      perform 1 from __FN__(381, false, null, null);
      st2 := 'no error';
    exception when others then st2 := sqlstate;
    end;
    res := res || jsonb_build_object('case', 'C19 non-staff gets 42501, no login gets 28000', 'ok', st = '42501' and st2 = '28000', 'got', st || ' / ' || st2);
  end;
  perform set_config('request.jwt.claims', fred::text, true);

  raise exception 'TEST_RESULTS:%', jsonb_build_object('passed', (select count(*) from jsonb_array_elements(res) e where (e ->> 'ok')::boolean),
                                                       'total', jsonb_array_length(res), 'cases', res)::text;
end $tests$;
