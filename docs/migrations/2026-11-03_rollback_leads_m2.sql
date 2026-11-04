-- ROLLBACK of 2026-11-03_1730_leads_m2_functions_views. Drops the views and functions only; the tables and their
-- rows stay (M1's rollback is separate and needs Fred's OK once data exists).
-- ORDER: run after 2026-11-03_rollback_leads_m3.sql (which comes after the label-mask and privacy-fixes rollbacks) and
-- before 2026-11-03_rollback_leads_schema_m1.sql. Run early, it is refused: a later object still depends on what it
-- drops (2BP01, measured 2026-11-03 ~22:57 ET), so the whole file rolls back and nothing is changed.
begin;
set local lock_timeout = '3s';
drop view if exists public.v_lead_review, public.v_lead_interceptors, public.v_frozen_leads;
drop view if exists leads.v_establishment_state, leads.v_client_candidates, leads.v_src_bsi;
drop function if exists leads.decide_client(bigint, text, text, text, bigint, text);
drop function if exists leads.ingest(text, timestamptz, jsonb, text);
drop function if exists leads.fn_bsi_date(text), leads.fn_name_key(text), leads.fn_street_key(text);
revoke usage on schema leads from service_role;
do $verify$
begin
  if exists (select 1 from pg_class where relname in ('v_frozen_leads', 'v_lead_interceptors', 'v_lead_review')
              and relnamespace = 'public'::regnamespace) then raise exception 'a public leads view remains'; end if;
  if exists (select 1 from pg_proc where pronamespace = 'leads'::regnamespace) then raise exception 'a leads function remains'; end if;
end $verify$;
notify pgrst, 'reload schema';
commit;
