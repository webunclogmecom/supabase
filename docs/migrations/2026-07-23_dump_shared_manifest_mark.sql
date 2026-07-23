-- 2026-07-23  DUMP: one shared "on a manifest" mark per visit (dump checklist + VIEW ADDRESSES)
--
-- ============================================================================
-- WHY (Fred 2026-07-23)
-- ============================================================================
-- The manifest checklist ticks were stored per-dump (PK visit_id + dump_visit_id) and were invisible to
-- the VIEW ADDRESSES browse list. Fred wants ONE shared mark per visit, set from either surface,
-- reflected on both, and SHOWN DIMMED (not hidden) so a driver can see what's already on a sheet.
-- Full design + decisions:
--   Building Apps/DUMP Schedule/docs/specs/2026-07-23-shared-manifest-mark-and-nav-restyle.md
--
-- MODEL: public.dump_manifest_handout goes from PK(visit_id, dump_visit_id) to PK(visit_id) — one row =
-- "this visit is on a manifest". dump_visit_id becomes NULLABLE provenance (the dump it was ticked on;
-- NULL when ticked from VIEW ADDRESSES). `source` records where it was ticked. The ledger is EMPTY today
-- (verified 0 rows), so this is a clean remodel with nothing to migrate.
--
-- WHO WRITES: browsing still records NOTHING. Only an explicit CONFIRM (dump checklist) or an explicit
-- tap (VIEW ADDRESSES -> dump_manifest_mark) writes.
--   * dump_manifest_handout_confirm — set-semantics over THIS dump; its DELETE stays scoped to
--     dump_visit_id = p_dump_visit_id, so a partial-load confirm can NEVER wipe a mark another dump or
--     VIEW ADDRESSES created. Ticked visits are upsert-repointed to this dump.
--   * dump_manifest_mark — the per-visit master toggle from VIEW ADDRESSES: marks (source 'addresses',
--     dump NULL) any genuinely-outstanding visit, or unmarks ANY visit by id. No Slack.
-- The old "hide a visit handed out on another dump" rule is REPLACED by "show it dimmed + checked"
-- (dump_manifest_handout_list no longer hides; `confirmed` now means the shared mark, any provenance).
--
-- AUDIT (ADR 010 / Rule 8): dump_manifest_handout OPTS IN to audit here — it now carries driver-
-- attributed, DERM-adjacent marks written from two surfaces. It had no audit trigger before.
--
-- SAFETY (verified pre-migration): no inbound FKs, no existing triggers, nothing depends on the view
-- except the list function (runtime ref). anon stays read-only; every function is service_role-only.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Remodel the ledger: one row per visit + nullable provenance + source
-- ---------------------------------------------------------------------------
DO $$
DECLARE c text;
BEGIN
  SELECT conname INTO c FROM pg_constraint
   WHERE conrelid = 'public.dump_manifest_handout'::regclass AND contype = 'p';
  IF c IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.dump_manifest_handout DROP CONSTRAINT %I', c);
  END IF;
END $$;

ALTER TABLE public.dump_manifest_handout ADD CONSTRAINT dump_manifest_handout_pkey PRIMARY KEY (visit_id);
ALTER TABLE public.dump_manifest_handout ALTER COLUMN dump_visit_id DROP NOT NULL;
ALTER TABLE public.dump_manifest_handout ADD COLUMN IF NOT EXISTS source text DEFAULT 'dump';

-- audit opt-in (Rule 8)
DROP TRIGGER IF EXISTS audit_dump_manifest_handout ON public.dump_manifest_handout;
CREATE TRIGGER audit_dump_manifest_handout
  AFTER INSERT OR UPDATE OR DELETE ON public.dump_manifest_handout
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- ---------------------------------------------------------------------------
-- 2. Browse view gains the shared-mark columns (append-only; existing cols unchanged)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW public.dump_outstanding_visits AS
SELECT
  p.visit_id,
  p.client_code,
  p.client_name,
  regexp_replace(p.address, ',\s*USA.*$'::text, ''::text, 'i'::text) AS address,
  CASE
    WHEN p.city IS NOT NULL
     AND regexp_replace(p.address, ',\s*USA.*$'::text, ''::text, 'i'::text) ~* ((',\s*'::text || p.city) || '(\s*,|\s*$)'::text)
    THEN NULL::text ELSE p.city
  END AS city,
  p.visit_date,
  p.completed_at,
  vis.vehicle_id,
  veh.name AS truck,
  gd.gdo_number,
  GREATEST(0, (now() AT TIME ZONE 'America/New_York'::text)::date - p.visit_date) AS age_days,
  GREATEST(0, (now() AT TIME ZONE 'America/New_York'::text)::date - p.visit_date) > 14 AS needs_office,
  (h.visit_id IS NOT NULL) AS on_sheet,
  emp.full_name AS marked_by,
  h.handed_at AS marked_at
FROM public.manifest_pickable_visits p
JOIN public.visits vis ON vis.id = p.visit_id
LEFT JOIN public.vehicles veh ON veh.id = vis.vehicle_id
LEFT JOIN LATERAL (
  SELECT g.gdo_number FROM public.gdos g
  WHERE g.client_id = p.client_id AND g.status = 'ACTIVE'::text AND g.gdo_number ~ '^GDO-[0-9]+$'::text
  ORDER BY g.gdo_number LIMIT 1
) gd ON true
LEFT JOIN public.dump_manifest_handout h ON h.visit_id = p.visit_id
LEFT JOIN public.employees emp ON emp.id = h.driver_id;

REVOKE ALL ON public.dump_outstanding_visits FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.dump_outstanding_visits TO service_role;

-- ---------------------------------------------------------------------------
-- 3. List (dump checklist source): stop hiding cross-dump marks; `confirmed` = the shared mark
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dump_manifest_handout_list(p_driver_id bigint, p_dump_visit_id bigint, p_ttl_days integer DEFAULT 7)
 RETURNS TABLE(bucket text, visit_id bigint, client_code text, client_name text, address text, city text, visit_date date, completed_at timestamp with time zone, age_days integer, truck text, gdo_number text, needs_office boolean, confirmed boolean)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_truck_id bigint;
  v_since    timestamptz;
BEGIN
  SELECT o.vehicle_id INTO v_truck_id FROM public.dump_driver_origin(p_driver_id) o;

  SELECT max(v.start_at) INTO v_since
  FROM public.visits v
  WHERE v.assigned_driver_id = p_driver_id
    AND v.client_id IN (76, 365)
    AND v.deleted_at IS NULL
    AND v.id <> p_dump_visit_id;
  v_since := COALESCE(v_since, now() - interval '7 days');

  RETURN QUERY
  WITH bucketed AS (
    SELECT o.*,
      CASE
        WHEN v_truck_id IS NOT NULL AND o.vehicle_id = v_truck_id
         AND o.completed_at IS NOT NULL AND o.completed_at > v_since
        THEN 'load' ELSE 'outstanding'
      END AS bucket
    FROM public.dump_outstanding_visits o
  )
  SELECT b.bucket, b.visit_id, b.client_code, b.client_name, b.address, b.city, b.visit_date,
         b.completed_at, b.age_days, b.truck, b.gdo_number, b.needs_office,
         b.on_sheet AS confirmed
  FROM bucketed b
  ORDER BY (b.bucket = 'load') DESC,
           CASE WHEN b.bucket = 'load' THEN b.completed_at END ASC,
           CASE WHEN b.bucket <> 'load' THEN b.completed_at END DESC NULLS LAST;
END;
$function$;

REVOKE ALL ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dump_manifest_handout_list(bigint, bigint, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Confirm (dump checklist): set THIS dump's marks; delete stays scoped so it never wipes foreign marks
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dump_manifest_handout_confirm(p_driver_id bigint, p_dump_visit_id bigint, p_visit_ids bigint[])
 RETURNS TABLE(visit_id bigint, client_code text, client_name text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
DECLARE
  v_ids bigint[] := COALESCE(p_visit_ids, ARRAY[]::bigint[]);
BEGIN
  -- remove THIS dump's own previously-recorded marks that are no longer ticked. Scoped to this dump's
  -- provenance, so a partial-load confirm can never delete a VIEW ADDRESSES or other-dump mark.
  DELETE FROM public.dump_manifest_handout h
   WHERE h.dump_visit_id = p_dump_visit_id
     AND NOT (h.visit_id = ANY (v_ids));

  -- upsert the ticked ones (only genuinely-outstanding visits); re-point provenance to this dump.
  INSERT INTO public.dump_manifest_handout (visit_id, dump_visit_id, driver_id, source, handed_at)
  SELECT o.visit_id, p_dump_visit_id, p_driver_id, 'dump', now()
  FROM public.dump_outstanding_visits o
  WHERE o.visit_id = ANY (v_ids)
  ON CONFLICT (visit_id) DO UPDATE
    SET dump_visit_id = p_dump_visit_id, driver_id = p_driver_id, source = 'dump', handed_at = now();

  RETURN QUERY
  SELECT o.visit_id, o.client_code, o.client_name
  FROM public.dump_outstanding_visits o
  JOIN public.dump_manifest_handout h ON h.visit_id = o.visit_id AND h.dump_visit_id = p_dump_visit_id
  ORDER BY o.completed_at DESC NULLS LAST;
END;
$function$;

REVOKE ALL ON FUNCTION public.dump_manifest_handout_confirm(bigint, bigint, bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dump_manifest_handout_confirm(bigint, bigint, bigint[]) TO service_role;

-- ---------------------------------------------------------------------------
-- 5. NEW: dump_manifest_mark — the per-visit master toggle from VIEW ADDRESSES (no Slack)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dump_manifest_mark(p_driver_id bigint, p_visit_id bigint, p_on boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  IF p_on THEN
    -- only a genuinely-outstanding visit can be marked (already DERM-linked / unknown -> no-op)
    IF NOT EXISTS (SELECT 1 FROM public.dump_outstanding_visits o WHERE o.visit_id = p_visit_id) THEN
      RETURN false;
    END IF;
    INSERT INTO public.dump_manifest_handout (visit_id, dump_visit_id, driver_id, source, handed_at)
    VALUES (p_visit_id, NULL, p_driver_id, 'addresses', now())
    ON CONFLICT (visit_id) DO NOTHING;
    RETURN true;
  ELSE
    DELETE FROM public.dump_manifest_handout WHERE visit_id = p_visit_id;
    RETURN false;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.dump_manifest_mark(bigint, bigint, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dump_manifest_mark(bigint, bigint, boolean) TO service_role;

COMMIT;
