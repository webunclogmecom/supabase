-- 2026-11-02_1800 · Permits for every county and city, step 1 of 3: the permit type
--
-- THE ASK. Fred, 2026-11-02 (Client App, Grove Kosher 022-GRO, Boca Raton): the property's permit section asks for a
-- GDO number and a PDF, but a Boca Raton client has no Miami-Dade GDO. *"One table for every permit now ... make sure
-- the DERM sheets, the filing bot and the portal still see only GDO ... keep in mind on what services, api, bots, cron
-- jobs, etc fetches data from that"*. *"The PDF is optional for every type."* *"CCN for now is just a number, we don't
-- hold any permit."* Plan: docs/specs/2026-11-02-permits-one-table-plan.md (section 2).
--
-- WHAT CHANGES
--  1. NEW public.permit_types (code PK, name, issuing_authority, number_pattern, reads_pdf, status), seeded with
--     GDO (Miami-Dade DERM, '^GDO-[0-9]+$', its PDF is read), CCN (City of Boca Raton, "just a number") and
--     PSO (Private Sanitary Sewer operating permit, Miami-Dade DERM; read off row 141's own PDF).
--     Audit: OPTED IN (a hand-kept lookup; rule 8). RLS: on (event trigger). Grants: NONE to anon or authenticated;
--     the Client App reads it through client.permit_types (step 2), a view owned by postgres.
--  2. public.gdos:
--     - permit_type text NOT NULL DEFAULT 'GDO' REFERENCES permit_types(code) ON UPDATE CASCADE, indexed.
--       The default keeps every existing writer correct until it learns the column: they all write GDO numbers.
--     - permit_effective date NULL (the form's Effective date; the DERM PDF already parses it, nothing stored it).
--     - row 141 (057-BAY 'PSO-00025') becomes type PSO; every other row (191) stays GDO, including the 3 INACTIVE
--       malformed GDO rows 29, 157 and 164.
--     - DROP CONSTRAINT gdos_real_number_requires_document_chk (Fred: the PDF is optional for every type; replaces
--       the 2026-09-22 "no GDO number without its file" rule).
--     - NEW trigger trg_aa_permit_number_matches_type (BEFORE INSERT OR UPDATE OF gdo_number, permit_type, status):
--       for a row that is not INACTIVE, (a) a number starting "GDO" must be type GDO, (b) the number must match its
--       type's number_pattern when there is one. Rule (a) is what keeps the ~20 DERM readers that test
--       gdo_number ~ '^GDO-[0-9]+$' (filing bot views, Stamp Studio, derm.visits, ops.v_calendar_visit, the DUMP app,
--       the pdf-service) GDO-only without rebuilding them. INACTIVE rows are exempt (rows 29, 157, 164).
--       Messages are plain sentences the Client App shows as they are (22023, DETAIL blocker=...).
--
-- WHAT DOES NOT CHANGE
--  - Table and column names (gdos, gdo_number): client.get_client_activity keys permit history on table_name 'gdos',
--    and the names are literal in the Client App, the Slack GDO bot, the pdf-service, 6 edge functions and the bot
--    contract. Views bind to the table, so a rename would not have protected any reader.
--  - No view or function is changed here (steps 2 and 3). client.upsert_gdo_permit returns to_jsonb(gdos row), so the
--    Client App starts receiving two extra keys (permit_type, permit_effective); it ignores unknown keys.
--  - Existing row values other than row 141's type.
--
-- GUARDS: lock_timeout 3s; the columns do not exist yet; the CHECK exists; row 141 is 'PSO-00025'.
-- VERIFY (inside): 191 GDO + 1 PSO; permit_types relacl has no anon/authenticated entry; the trigger refuses a CCN
--  numbered GDO-1 and a GDO numbered 12345, accepts a CCN numbered 12345 and an INACTIVE malformed GDO row; all
--  probe writes are rolled back inside the block.
-- ROLLBACK: 2026-11-02_rollback_permits_one_table.sql (all three steps, newest first).

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.gdos'::regclass AND attname IN ('permit_type', 'permit_effective') AND NOT attisdropped) THEN
    RAISE EXCEPTION 'permits step 1: public.gdos already has permit_type or permit_effective';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.gdos'::regclass AND conname = 'gdos_real_number_requires_document_chk') THEN
    RAISE EXCEPTION 'permits step 1: gdos_real_number_requires_document_chk is not there';
  END IF;
  IF (SELECT gdo_number FROM public.gdos WHERE id = 141) IS DISTINCT FROM 'PSO-00025' THEN
    RAISE EXCEPTION 'permits step 1: gdos row 141 is no longer PSO-00025';
  END IF;
END $pin$;

-- 1. The lookup
CREATE TABLE public.permit_types (
  code              text PRIMARY KEY CHECK (code ~ '^[A-Z0-9]{2,10}$'),
  name              text NOT NULL,
  issuing_authority text NOT NULL,
  number_pattern    text,
  reads_pdf         boolean NOT NULL DEFAULT false,
  status            text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE', 'INACTIVE')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.permit_types IS
  'Kinds of permit a property can hold (GDO = Miami-Dade DERM grease permit, CCN = City of Boca Raton, PSO = Miami-Dade private sanitary sewer). public.gdos.permit_type references code. 2026-11-02, Fred.';
COMMENT ON COLUMN public.permit_types.reads_pdf IS
  'true when we read this type''s PDF automatically (parse-gdo-permit, the gdo-permit-label reader). Other types store the PDF as it is.';
CREATE TRIGGER trg_permit_types_updated_at BEFORE UPDATE ON public.permit_types
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();
CREATE TRIGGER audit_permit_types AFTER INSERT OR UPDATE OR DELETE ON public.permit_types
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();
REVOKE ALL ON public.permit_types FROM PUBLIC, anon, authenticated;

INSERT INTO public.permit_types (code, name, issuing_authority, number_pattern, reads_pdf) VALUES
  ('GDO', 'Grease Disposal Operating permit', 'Miami-Dade DERM', '^GDO-[0-9]+$', true),
  ('CCN', 'Boca Raton CCN', 'City of Boca Raton', NULL, false),
  ('PSO', 'Private Sanitary Sewer operating permit', 'Miami-Dade DERM', NULL, false);

-- 2. The permit's type and effective date
ALTER TABLE public.gdos
  ADD COLUMN permit_type text NOT NULL DEFAULT 'GDO' REFERENCES public.permit_types(code) ON UPDATE CASCADE,
  ADD COLUMN permit_effective date;
COMMENT ON COLUMN public.gdos.permit_type IS
  'The kind of permit (public.permit_types.code). DERM readers keep to GDO: by permit_type = ''GDO'', or by gdo_number ~ ''^GDO-[0-9]+$'', which trg_aa_permit_number_matches_type keeps equivalent for live rows. 2026-11-02.';
COMMENT ON COLUMN public.gdos.permit_effective IS 'The date the permit takes effect, as printed on it. 2026-11-02.';
CREATE INDEX gdos_permit_type_idx ON public.gdos (permit_type);

UPDATE public.gdos SET permit_type = 'PSO' WHERE id = 141 AND gdo_number = 'PSO-00025';

ALTER TABLE public.gdos DROP CONSTRAINT gdos_real_number_requires_document_chk;

-- 3. The number must agree with the type
CREATE FUNCTION public.fn_permit_number_matches_type()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_pattern text;
  v_name    text;
begin
  -- 2026-11-02 (permits one table). An INACTIVE row is history and keeps whatever it holds (rows 29, 157, 164).
  if new.status = 'INACTIVE' then
    return new;
  end if;
  -- The DERM readers that test gdo_number ~ '^GDO-[0-9]+$' rely on this: only a GDO permit may carry a GDO number.
  if new.permit_type <> 'GDO' and new.gdo_number ~* '^[[:space:]]*GDO' then
    raise exception 'A number starting with GDO is a Miami-Dade GDO permit. Choose the GDO type, or change the number.'
      using errcode = '22023', detail = 'blocker=gdo_number_needs_gdo_type in public.fn_permit_number_matches_type';
  end if;
  select t.number_pattern, t.name into v_pattern, v_name from public.permit_types t where t.code = new.permit_type;
  if v_pattern is not null and new.gdo_number !~ v_pattern then
    if new.permit_type = 'GDO' then
      raise exception 'A GDO permit number looks like GDO-12345: GDO, a dash, then digits.'
        using errcode = '22023', detail = 'blocker=number_pattern in public.fn_permit_number_matches_type';
    end if;
    raise exception 'The number % is not in the % format.', new.gdo_number, v_name
      using errcode = '22023', detail = 'blocker=number_pattern in public.fn_permit_number_matches_type';
  end if;
  return new;
end;
$function$;
REVOKE ALL ON FUNCTION public.fn_permit_number_matches_type() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER trg_aa_permit_number_matches_type
  BEFORE INSERT OR UPDATE OF gdo_number, permit_type, status ON public.gdos
  FOR EACH ROW EXECUTE FUNCTION public.fn_permit_number_matches_type();

-- VERIFY
DO $verify$
DECLARE
  v_err text;
  v_client bigint;
  v_prop bigint;
BEGIN
  IF (SELECT count(*) FROM public.gdos WHERE permit_type = 'GDO') <> 191
     OR (SELECT count(*) FROM public.gdos WHERE permit_type = 'PSO') <> 1
     OR (SELECT count(*) FROM public.gdos) <> 192 THEN
    RAISE EXCEPTION 'permits step 1 VERIFY: types are not 191 GDO + 1 PSO';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_class c, aclexplode(c.relacl) a
              WHERE c.oid = 'public.permit_types'::regclass
                AND a.grantee IN (0, 'anon'::regrole::oid, 'authenticated'::regrole::oid)) THEN
    RAISE EXCEPTION 'permits step 1 VERIFY: anon, authenticated or PUBLIC holds a privilege on public.permit_types';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.permit_types'::regclass) THEN
    RAISE EXCEPTION 'permits step 1 VERIFY: RLS is off on public.permit_types';
  END IF;

  -- 112-YA, the sanctioned test client, and one of its properties
  SELECT c.id, p.id INTO v_client, v_prop FROM public.clients c JOIN public.properties p ON p.client_id = c.id
   WHERE c.client_code = '112-YA' AND p.deleted_at IS NULL ORDER BY p.id LIMIT 1;
  IF v_prop IS NULL THEN RAISE EXCEPTION 'permits step 1 VERIFY: no 112-YA property to probe with'; END IF;

  -- (a) a CCN numbered GDO-1 is refused
  v_err := NULL;
  BEGIN
    INSERT INTO public.gdos (client_id, property_id, gdo_number, permit_type, status) VALUES (v_client, v_prop, 'GDO-1', 'CCN', 'ACTIVE');
  EXCEPTION WHEN others THEN v_err := SQLERRM; END;
  IF v_err IS NULL OR position('starting with GDO' in v_err) = 0 THEN RAISE EXCEPTION 'permits step 1 VERIFY: CCN GDO-1 not refused (%)', v_err; END IF;

  -- (b) a GDO numbered 12345 is refused
  v_err := NULL;
  BEGIN
    INSERT INTO public.gdos (client_id, property_id, gdo_number, permit_type, status) VALUES (v_client, v_prop, '12345', 'GDO', 'ACTIVE');
  EXCEPTION WHEN others THEN v_err := SQLERRM; END;
  IF v_err IS NULL OR position('GDO, a dash' in v_err) = 0 THEN RAISE EXCEPTION 'permits step 1 VERIFY: GDO 12345 not refused (%)', v_err; END IF;

  -- (c) a CCN numbered 12345 with no PDF is accepted, and (d) INACTIVE row 29 still takes a number write; both undone
  v_err := NULL;
  BEGIN
    INSERT INTO public.gdos (client_id, property_id, gdo_number, permit_type, status) VALUES (v_client, v_prop, 'PROBE-12345', 'CCN', 'ACTIVE');
    UPDATE public.gdos SET gdo_number = gdo_number WHERE id = 29;
    RAISE EXCEPTION 'permits_probe_ok';
  EXCEPTION WHEN others THEN v_err := SQLERRM; END;
  IF v_err IS DISTINCT FROM 'permits_probe_ok' THEN RAISE EXCEPTION 'permits step 1 VERIFY: CCN without a PDF or INACTIVE row 29 refused (%)', v_err; END IF;
  IF EXISTS (SELECT 1 FROM public.gdos WHERE gdo_number = 'PROBE-12345') THEN RAISE EXCEPTION 'permits step 1 VERIFY: probe row survived'; END IF;
END $verify$;

COMMIT;
