-- customer.permits: the frequency is the AGREEMENT (Jobber job), never service_configs
--
-- Fred, 2026-10-02: "yes we actually are working with the agreement (job) these
-- 'service configs' should be removed then". Raised by Yan in Slack (#C0BD3VDPB9S):
-- 192-FRK's Field Portal permit card read "Pump frequency: Every 30 days" while the
-- agreement is every 60.
--
-- Cause: our_frequency_days was COALESCE(service_configs, job, permit max).
-- service_configs.frequency_days has no writer (last frequency change 2026-07-14,
-- app_source sql); the Client App edits jobs.frequency_days. So every app frequency
-- change went stale on the card. Six permits disagreed (032-LG, 099-PV, 192-FRK,
-- 195-MYK, 208-HUB, 227-PER), job right in all six (audit history + visit spacing).
--
-- Change (view only, column list identical, grants kept by CREATE OR REPLACE):
--   our_frequency_days = COALESCE(job, permit max)    (permit max = display fallback)
--   compliant          = from the job only, NULL without one (never from the fallback)
--   frequency_source   = 'job' | 'gdo_permit' | NULL   ('service_config' retired)
--   job lateral        = now also skips archived/destroyed jobs (terminal rule 2026-09-15)
--
-- Dry run (rolled back) 133 -> 133 rows. Value changes: the six above, plus 12
-- permits with no live pumping agreement (Service Call only, or 214-MYK's grey water
-- agreement) that now show the permit interval with no verdict: 018-FUE 037-LB 105-CU
-- 134-SC 145-NON 176-SOU 201-ALA 209-TRUE 212-TRUE 213-TRUE 214-MYK.
-- Customer-visible: 192-FRK (60 vs max 30) and 099-PV (90 vs max 60) now non-compliant.
--
-- Rule 8: a view, no audit trigger applies. service_configs itself is NOT dropped here;
-- 13 other views + client.update_property_capacity still read it (separate change).

begin;

create or replace view customer.permits as
SELECT customer.uuid_from_bigint(g.id) AS id,
    customer.uuid_from_bigint(g.client_id) AS client_id,
    g.gdo_number AS permit_number,
    'Grease Trap'::text AS area,
        CASE
            WHEN (g.max_frequency_days IS NULL) THEN NULL::text
            WHEN (g.max_frequency_days <= 35) THEN 'Monthly'::text
            WHEN (g.max_frequency_days <= 95) THEN 'Quarterly'::text
            WHEN (g.max_frequency_days <= 185) THEN 'Semi-annually'::text
            WHEN (g.max_frequency_days <= 380) THEN 'Annually'::text
            ELSE (('Every '::text || g.max_frequency_days) || ' days'::text)
        END AS frequency,
    g.permit_document_path AS permit_url,
    ((row_number() OVER (PARTITION BY g.client_id ORDER BY g.property_id, g.gdo_number) - 1))::integer AS "position",
    customer.uuid_from_bigint(g.property_id) AS property_id,
    g.location_label,
    g.permit_expiration,
    g.max_frequency_days,
        CASE
            WHEN (g.max_frequency_days IS NULL) THEN NULL::boolean
            ELSE COALESCE(((CURRENT_DATE - ( SELECT max(v.visit_date) AS max
               FROM (visits v
                 JOIN properties vp ON ((vp.id = v.property_id)))
              WHERE ((v.client_id = g.client_id) AND (v.visit_status = 'completed'::text) AND (v.deleted_at IS NULL) AND ((v.property_id = g.property_id) OR (lower(btrim(vp.address)) = lower(btrim(gp.address))))))) > g.max_frequency_days), true)
        END AS over_gdo_max,
    COALESCE(jf.freq, g.max_frequency_days) AS our_frequency_days,
        CASE
            WHEN ((jf.freq IS NULL) OR (g.max_frequency_days IS NULL)) THEN NULL::boolean
            ELSE (jf.freq <= g.max_frequency_days)
        END AS compliant,
        CASE
            WHEN (jf.freq IS NOT NULL) THEN 'job'::text
            WHEN (g.max_frequency_days IS NOT NULL) THEN 'gdo_permit'::text
            ELSE NULL::text
        END AS frequency_source
   FROM (((gdos g
     JOIN clients c ON ((c.id = g.client_id)))
     LEFT JOIN properties gp ON ((gp.id = g.property_id)))
     LEFT JOIN LATERAL ( SELECT j.frequency_days AS freq
           FROM jobs j
          WHERE ((j.client_id = g.client_id) AND (j.frequency_days > 0) AND (j.job_status <> ALL (ARRAY['archived'::text, 'destroyed'::text])) AND (EXISTS ( SELECT 1
                   FROM line_items li
                  WHERE ((li.job_id = j.id) AND (li.name IS NOT NULL) AND (fn_line_item_requires_derm(li.name) IS TRUE)))))
          ORDER BY (j.property_id = g.property_id) DESC NULLS LAST, j.id DESC
         LIMIT 1) jf ON (true))
  WHERE ((g.status = 'ACTIVE'::text) AND (c.status = ANY (ARRAY['ACTIVE'::text, 'RECURRING'::text])));

do $verify$
declare n int; f int; s text; a text;
begin
  select count(*) into n from customer.permits;
  if n < 120 then raise exception 'VERIFY row count %', n; end if;
  select count(*) into n from customer.permits where frequency_source = 'service_config';
  if n <> 0 then raise exception 'VERIFY service_config source remains: %', n; end if;
  select our_frequency_days, frequency_source into f, s from customer.permits
   where permit_number = 'GDO-08341';
  if f is distinct from 60 or s is distinct from 'job' then raise exception 'VERIFY 192-FRK % %', f, s; end if;
  select count(*) into n from customer.permits where frequency_source = 'gdo_permit' and compliant is not null;
  if n <> 0 then raise exception 'VERIFY fallback carries a verdict: %', n; end if;
  select relacl::text into a from pg_class where oid = 'customer.permits'::regclass;
  if a <> '{postgres=arwdDxtm/postgres,authenticated=r/postgres,service_role=r/postgres}' then
    raise exception 'VERIFY acl changed: %', a; end if;
  if pg_get_viewdef('customer.permits'::regclass) ~ 'service_configs' then
    raise exception 'VERIFY view still reads service_configs'; end if;
end $verify$;

commit;
