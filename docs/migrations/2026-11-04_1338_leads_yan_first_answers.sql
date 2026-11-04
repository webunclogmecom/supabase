-- 2026-11-04_1338: record Yan's first answers on the BSI review queue (plan S3, Trello IWJkqTq1).
--
-- Asked by Fred in #office-team, 2026-11-04 11:32 ET, under Diego's "We need make the report for grove kosher Boca":
--   1. Are these the same places as our clients? (Grove Kosher, Carrot Express Boca, Pura Vida, El Turco)
--   2. Are Bagel Boss, Capas Burger, Carrot Express West Boca or South Florida Golf Carts in the City of Boca Raton program?
-- Yan answered at 13:29 ET: "1yes / 2 south Florida Golf Carts is not required for compliance, (rain water) / the other
-- ones im not sure why we can find them". Fred: "yannick answered".
--
-- What this records, through leads.decide_client only (decided_by = Yan, employee 27, the person who answered):
--   same:   022-GRO, 064-TCE, 225-PV, 240-TUR. Each links the BSI record to the property.
--   absent: 361-SFG (rain water, not a grease client). It leaves the queue. Its client stays routed by city, and
--           scripts/checks/bsi_routing.sql still fails if line-27 work ever lands on it, which is correct.
-- What this leaves in the queue on purpose (11 rows):
--   135-BB, 319-CAP, 081-TCE: Yan does not know why they are missing from BSI. Not an answer, so nothing is recorded.
--   Alta and Olympus: not asked (Fred, 2026-11-04: only clients that are active or recurring).
--   5 other restaurants in Grove's plaza and BENTO BOCA on Pura Vida's street: nobody has decided them yet.
--
-- Effect: only leads.match_decisions and leads.establishments change, in the private schema. Nothing an app reads moves.
-- No CCN is typed by this: the office does that in the Client App (S3). Line 27 stays off these jobs until then.
--
-- Audit (rule 8): leads.establishments carries its audit trigger; leads.match_decisions is insert-only and is its own record.
-- Undo: leads.decide_client(<property>, 'different', '<why>', <staff email>, <record>) unlinks a same (the table is
-- insert-only, so the history stays). An absent has no undo verdict and needs none: it only hides the row from the queue,
-- and a BSI record that appears later still shows as a candidate.
begin;
set local lock_timeout = '3s';

-- guard: the world this was written against
do $guard$
declare v_bad bigint;
begin
  if (select count(*) from leads.match_decisions) <> 0 then raise exception 'guard: decisions already exist'; end if;
  if (select count(*) from public.v_lead_review) <> 16 then raise exception 'guard: the queue is not the 16 rows'; end if;
  select count(*) into v_bad from (values (822::bigint, '957372', 4::bigint, '022-GRO'), (581, '430537', 62, '064-TCE'),
                                          (772, '957315', 191, '225-PV'), (767, '957307', 1012, '240-TUR')) t(rec, src, prop, code)
   where not exists (select 1 from leads.v_src_bsi s where s.source_record_id = t.rec and s.source_id = t.src)
      or not exists (select 1 from public.properties p join public.clients c on c.id = p.client_id
                      where p.id = t.prop and p.deleted_at is null and c.client_code = t.code);
  if v_bad <> 0 then raise exception 'guard: % record or property does not match', v_bad; end if;
  if not exists (select 1 from public.properties p join public.clients c on c.id = p.client_id
                  where p.id = 1222 and c.client_code = '361-SFG') then raise exception 'guard: property 1222 is not 361-SFG'; end if;
  if (select public.fn_is_staff_email(e.email) from public.employees e where e.id = 27 and e.status = 'ACTIVE') is not true then
    raise exception 'guard: employee 27 is not active staff';
  end if;
end $guard$;

do $decide$
declare
  v_by text := (select lower(e.email) from public.employees e where e.id = 27);
  v_q text := 'Yan in #office-team, 2026-11-04 13:29 ET: "1yes" to "are these the same places as our clients?": ';
begin
  perform leads.decide_client(4,    'same', v_q || 'Grove Kosher = GROVE KOSHER MARKET, 22191 Powerline Rd A6-A9', v_by, 822);
  perform leads.decide_client(62,   'same', v_q || 'Carrot Express Boca = CARROT LOVE PALMETTO PARK LLC, 10 E Palmetto Park Rd', v_by, 581);
  perform leads.decide_client(191,  'same', v_q || 'Pura Vida = PURA VIDA, 5570 N Military Trail #402', v_by, 772);
  perform leads.decide_client(1012, 'same', v_q || 'El Turco = EL TURCO EXPRESS, 980 N Federal Hwy #115', v_by, 767);
  perform leads.decide_client(1222, 'absent',
    'Yan in #office-team, 2026-11-04 13:29 ET: "south Florida Golf Carts is not required for compliance, (rain water)". No BSI record in the scrape.',
    v_by, null, 'bsi');
end $decide$;

-- VERIFY
do $verify$
declare v_routed bigint[]; v_left text;
begin
  if (select count(*) from leads.match_decisions) <> 5 then raise exception 'verify: not 5 decisions'; end if;
  if (select count(*) from leads.match_decisions where verdict = 'same') <> 4 then raise exception 'verify: not 4 same'; end if;
  if (select array_agg(e.property_id order by e.property_id) from leads.establishments e where e.property_id is not null and e.status = 'ACTIVE')
     is distinct from array[4, 62, 191, 1012]::bigint[] then raise exception 'verify: the linked properties are wrong'; end if;
  if exists (select 1 from (values (822::bigint, 4::bigint), (581, 62), (772, 191), (767, 1012)) t(rec, prop)
              where not exists (select 1 from leads.source_records r join leads.establishments e on e.id = r.establishment_id
                                 where r.id = t.rec and e.property_id = t.prop)) then
    raise exception 'verify: a record is not on its property';
  end if;

  -- the queue: 16 less the 4 matches and the 1 absent, and exactly these rows
  select string_agg(coalesce(r.source_id, 'p' || r.property_id), ',' order by coalesce(r.source_id, 'p' || r.property_id)) into v_left from public.v_lead_review r;
  if v_left is distinct from '505742,94542,94544,95552,957247,957364,957365,p1117,p291,p53,p68' then raise exception 'verify: the queue holds %', v_left; end if;

  -- each match now reads as a client on the view the bot will use: Grove 2 interceptors, the others 1
  if (select count(*) from public.v_lead_interceptors i where i.property_id = 4) <> 2 then raise exception 'verify: Grove is not 2 interceptors'; end if;
  if (select count(*) from public.v_lead_interceptors i where i.property_id in (62, 191, 1012)) <> 3 then raise exception 'verify: the others are not 3 interceptors'; end if;

  -- nothing else moved
  if (select count(*) from public.v_frozen_leads) <> 420 then raise exception 'verify: the frozen leads moved'; end if;
  select array_agg(c.id order by c.id) into v_routed from public.clients c where public.fn_client_files_with_bsi(c.id);
  if v_routed is distinct from array[164,245,255,280,285,301,357,381,482,578,643]::bigint[] then raise exception 'verify: the routed set moved'; end if;
  if (select count(*) from public.gdos where permit_type = 'CCN' and coalesce(status, '') <> 'INACTIVE') <> 1 then raise exception 'verify: the CCN count moved'; end if;
end $verify$;

commit;
