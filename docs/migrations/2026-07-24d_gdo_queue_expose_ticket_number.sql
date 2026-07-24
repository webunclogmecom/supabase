-- ============================================================================
-- 2026-07-24d — GDO reporting queue: expose unified ticket_number + jurisdiction
-- ============================================================================
-- WHY (Fred + Diego, 2026-07-24): John's GDO Online Reporting bot reads the
-- rpa-derm-queue endpoint and needs THE DUMP-TICKET NUMBER to file the report —
-- "white or yellow, doesn't matter." Today the queue exposes only
-- white_manifest_number, so Broward-disposed loads (which carry a
-- yellow_ticket_number and legitimately have NO white number) came back with the
-- number NULL. This bit the bot's first real live item: manifest 1637 / visit
-- 6298 / 111-YC, dumped at the Broward facility (yellow 309944, white NULL).
-- Root-cause audit: NOT a SQL/select bug — v_derm_portal_queue and
-- v_derm_portal_dryrun already select white identically; the number simply lives
-- in a different column for Broward. Memory:
-- project_gdo_queue_white_number_jurisdiction_gap.
--
-- FIX (additive, non-breaking): append two columns to the queue chain —
--   * ticket_number = the dump-ticket number regardless of jurisdiction
--   * jurisdiction  = 'dade' | 'broward' | 'unknown'
-- reusing the EXACT logic derm.manifests uses for display_number/jurisdiction, so
-- the bot's ticket_number equals what the DERM Tracker app shows. Verified in
-- data (563 live manifests): white <=> Miami-Dade facility (446/446), yellow <=>
-- Broward facility (117/117), 0 both, 0 neither — so COALESCE(white,yellow) is
-- always the one real number. white_manifest_number is KEPT as-is for anything
-- already reading it.
--
-- This is the READ-LAYER unification only. The base-table collapse of
-- white/yellow -> a single Ticket # column is a SEPARATE, staged migration
-- (scheduled tomorrow/Mon per Fred); this queue is one of the ~19 readers it will
-- eventually repoint, so wiring it now is a strict subset, not throwaway.
--
-- CREATE OR REPLACE is append-only safe: the new columns go at the END of each
-- view's column list; the first N columns are reproduced byte-for-byte, so
-- dependents (queue/dryrun read fields; the edge fn reads queue/dryrun via
-- SELECT *) keep working.
--
-- AUDIT (ADR 010): views only — no audit trigger applies. The underlying
-- derm_manifests table is already audited; no new business table introduced.
-- ============================================================================

begin;

-- 1) Base fields view — append ticket_number + jurisdiction (from m = derm_manifests).
create or replace view public.v_derm_portal_fields as
 SELECT v.id AS visit_id,
    v.visit_date,
    v.client_id,
    c.client_code,
    c.name AS client_name,
    ce.email AS client_email,
    pp.address,
    pp.city,
    pp.zip,
    pp.county,
    gd.gdo_number,
    m.id AS manifest_id,
    m.white_manifest_number,
    m.dump_ticket_date,
    df.name AS disposal_facility,
    m.derm_address_url,
    m.derm_address_extra_urls,
    m.derm_manifest_url,
    m.derm_manifest_extra_urls,
    GREATEST(v.updated_at, mv_link.linked_at) AS updated_at,
    mv_link.linked_at,
    -- 24d: the dump-ticket number regardless of jurisdiction (same rule as
    -- derm.manifests.display_number). Post white/yellow cleanup exactly one of
    -- white/yellow is set per row, so this is always the one real number.
    CASE
        WHEN m.yellow_ticket_number IS NOT NULL THEN m.yellow_ticket_number
        WHEN m.white_manifest_number IS NOT NULL AND length(m.white_manifest_number) >= 5 THEN m.white_manifest_number
        ELSE NULL::text
    END AS ticket_number,
    CASE
        WHEN m.yellow_ticket_number IS NOT NULL THEN 'broward'::text
        WHEN m.white_manifest_number IS NOT NULL AND length(m.white_manifest_number) >= 5 THEN 'dade'::text
        ELSE 'unknown'::text
    END AS jurisdiction
   FROM visits v
     JOIN clients c ON c.id = v.client_id
     JOIN LATERAL ( SELECT mv.manifest_id,
            GREATEST(m2.updated_at, m2.created_at) AS linked_at
           FROM manifest_visits mv
             JOIN derm_manifests m2 ON m2.id = mv.manifest_id AND m2.deleted_at IS NULL
          WHERE mv.visit_id = v.id
          ORDER BY m2.created_at DESC
         LIMIT 1) mv_link ON true
     JOIN derm_manifests m ON m.id = mv_link.manifest_id
     LEFT JOIN LATERAL ( SELECT cc.email
           FROM client_contacts cc
          WHERE cc.client_id = c.id AND cc.email IS NOT NULL AND cc.email <> ''::text
          ORDER BY cc.id
         LIMIT 1) ce ON true
     LEFT JOIN LATERAL ( SELECT p.address,
            p.city,
            p.zip,
            p.county
           FROM properties p
          WHERE p.client_id = c.id AND p.is_primary
          ORDER BY p.id
         LIMIT 1) pp ON true
     LEFT JOIN LATERAL ( SELECT g.gdo_number
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text AND g.gdo_number ~ '^GDO-[0-9]+$'::text
          ORDER BY g.id
         LIMIT 1) gd ON true
     LEFT JOIN disposal_facilities df ON df.id = m.disposal_facility_id
  WHERE v.deleted_at IS NULL AND fn_visit_is_gdo_reporting(v.id);

-- 2) Live queue — append ticket_number + jurisdiction (resolve from f).
create or replace view public.v_derm_portal_queue as
 SELECT DISTINCT ON (manifest_id) visit_id,
    visit_date,
    client_id,
    client_code,
    client_name,
    client_email,
    address,
    city,
    zip,
    county,
    gdo_number,
    manifest_id,
    white_manifest_number,
    dump_ticket_date,
    disposal_facility,
    derm_address_url,
    derm_address_extra_urls,
    derm_manifest_url,
    derm_manifest_extra_urls,
    updated_at,
    linked_at,
    ticket_number,
    jurisdiction
   FROM v_derm_portal_fields f
  WHERE visit_date >= rpa_launch_cutoff() AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND (s.status = 'SUCCESS'::text OR s.portal_confirmation IS NOT NULL))) AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND s.created_at > (now() - '20:00:00'::interval))) AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_submissions s
             JOIN manifest_visits smv ON smv.visit_id = s.visit_id
          WHERE smv.manifest_id = f.manifest_id AND NOT s.dry_run AND NOT s.retryable AND s.status <> 'SUCCESS'::text AND s.created_at > f.updated_at)) AND NOT (EXISTS ( SELECT 1
           FROM derm_portal_leases l
             JOIN manifest_visits lmv ON lmv.visit_id = l.visit_id
          WHERE lmv.manifest_id = f.manifest_id AND l.leased_at > (now() - '20:00:00'::interval)))
  ORDER BY manifest_id, (abs(visit_date - dump_ticket_date)), visit_id;

-- 3) Dryrun (historical sample) — append the same two columns.
create or replace view public.v_derm_portal_dryrun as
 SELECT DISTINCT ON (manifest_id) visit_id,
    visit_date,
    client_id,
    client_code,
    client_name,
    client_email,
    address,
    city,
    zip,
    county,
    gdo_number,
    manifest_id,
    white_manifest_number,
    dump_ticket_date,
    disposal_facility,
    derm_address_url,
    derm_address_extra_urls,
    derm_manifest_url,
    derm_manifest_extra_urls,
    updated_at,
    linked_at,
    ticket_number,
    jurisdiction
   FROM v_derm_portal_fields f
  WHERE visit_date < rpa_launch_cutoff()
  ORDER BY manifest_id, (abs(visit_date - dump_ticket_date)), visit_id;

commit;
