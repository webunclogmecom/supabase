-- 2026-06-02 — manifest_pickable_visits: drop the service_type=GT restriction so /upload can file DERM manifests for non-GT pump-out visits (e.g. grey-water). Fred-approved (all non-GT pickable; ops files where needed). Applied via Mgmt API from Building Apps session. Backup: docs/backups/manifest_pickable_visits_backup_2026-06-02.json
-- IMPORTANT: this view is security_invoker=true (runs as the anon caller, respects RLS) — the WITH clause below MUST stay, or CREATE OR REPLACE silently resets it to owner-run (RLS-bypassing). (Bit me once; restored via ALTER VIEW ... SET (security_invoker=true).)

CREATE OR REPLACE VIEW public.manifest_pickable_visits WITH (security_invoker = true) AS  SELECT v.id AS visit_id,
    v.visit_date,
    v.start_at,
    v.completed_at,
    v.service_type,
    v.title,
    c.id AS client_id,
    c.client_code,
    c.name AS client_name,
    COALESCE(p.address, primary_p.address) AS address,
    COALESCE(p.city, primary_p.city) AS city,
    COALESCE(p.county, primary_p.county) AS county
   FROM visits v
     JOIN clients c ON c.id = v.client_id
     LEFT JOIN properties p ON p.id = v.property_id
     LEFT JOIN properties primary_p ON primary_p.client_id = v.client_id AND primary_p.is_primary = true
  WHERE v.visit_status = 'completed'::text AND (v.derm_required IS NULL OR v.derm_required = true) AND v.deleted_at IS NULL AND NOT (EXISTS ( SELECT 1
           FROM manifest_visits mv
             JOIN derm_manifests dm ON dm.id = mv.manifest_id
          WHERE mv.visit_id = v.id AND dm.deleted_at IS NULL));
