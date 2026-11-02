-- 2026-11-02_1810 · Permits for every county and city, step 2 of 3: the GDO-only readers say so
--
-- THE ASK. Fred, 2026-11-02: one table for every permit, and *"the DERM sheets, the filing bot and the portal still see
-- only GDO"*. Route and service-due list: *"GDO first, else other"*. Plan: docs/specs/2026-11-02-permits-one-table-plan.md
-- (section 3). Trello sWPaXFZO.
--
-- WHY. Step 1 (2026-11-02_1800) gave every permit a type. Most DERM readers already keep to GDO through the number
-- format (^GDO-[0-9]+$), which step 1's trigger now ties to the type. These nine had NO filter, and already showed
-- 057-BAY's sewer permit PSO-00025 (gdos 141) as if it were its GDO:
--
-- WHAT CHANGES (each an anchored edit of the live body, md5-pinned; nothing else in the body moves)
--  1. derm.gdos (DERM Tracker permit list): WHERE g.permit_type = 'GDO'.
--  2. ops.v_derm_compliance (permit_number, permit_expiration): + permit_type = 'GDO' in both sub-selects.
--  3. customer.clients.gdo_permit_url ("the GDO permit link", reached by anon through customer.get_client_portal):
--     + permit_type = 'GDO'.
--  4. ops.v_route_today, ops.v_service_due (permit_number): ORDER BY (permit_type = 'GDO') DESC, id, so the GDO
--     number shows first and another type only when the place / client has no GDO (Fred).
--  5. derm.audit_pack (the fallback when a manifest has no permit, twice) and derm.audit_pack_client (twice):
--     + permit_type = 'GDO'.
--  6. public.fn_check_gdo_on_visit (trigger on visits: "Dade pumping visit with no GDO"): a PSO or CCN no longer counts
--     as the GDO.
--  7. public.fn_gdo_permit_label_targets (the gdo-permit-label reader, cron gdo-permit-label-sweep + storage trigger):
--     only types whose PDF we read (permit_types.reads_pdf, GDO). A CCN or PSO PDF is never sent to the DERM prompt
--     and can no longer overwrite location_label.
--
-- WHAT DOES NOT CHANGE
--  - Columns, owners, grants and options of every view (CREATE OR REPLACE keeps them; VERIFY reads relacl back).
--  - The ~20 readers that already test ^GDO-[0-9]+$ (filing bot views, Stamp Studio, derm.visits,
--    ops.v_calendar_visit, customer.gdo_reports, the DUMP app): step 1's trigger keeps that test equal to the type.
--  - Every GDO row in every reader: VERIFY compares a full before/after snapshot of each view (each reads in < 25 ms).
--
-- PREDICTED EFFECT (VERIFY asserts it): derm.gdos loses exactly row 141; ops.v_derm_compliance and customer.clients
--  change exactly one row each (057-BAY: PSO-00025 gone); ops.v_route_today and ops.v_service_due do not change today
--  (no client holds both a GDO and another type); derm.audit_pack_client(057-BAY) no longer names PSO-00025; the label
--  reader no longer offers row 141 and offers every GDO row it offered before.
--
-- GUARDS: lock_timeout 3s; md5 of each live body = the 2026-11-02 read; each anchor matches its expected count;
--  functions re-read equal the edited text. Requires step 1 (permit_type exists).
-- ROLLBACK: 2026-11-02_rollback_permits_one_table.sql

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $pin$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.gdos'::regclass AND attname = 'permit_type' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'permits step 2: step 1 (2026-11-02_1800) is not applied';
  END IF;
END $pin$;

-- Snapshots for the VERIFY (row text, so json columns compare too)
CREATE TEMP TABLE p2_dg ON COMMIT DROP AS SELECT t::text r FROM derm.gdos t;
CREATE TEMP TABLE p2_dc ON COMMIT DROP AS SELECT t::text r FROM ops.v_derm_compliance t;
CREATE TEMP TABLE p2_cc ON COMMIT DROP AS SELECT t::text r FROM customer.clients t;
CREATE TEMP TABLE p2_rt ON COMMIT DROP AS SELECT t::text r FROM ops.v_route_today t;
CREATE TEMP TABLE p2_sd ON COMMIT DROP AS SELECT t::text r FROM ops.v_service_due t;
CREATE TEMP TABLE p2_acl ON COMMIT DROP AS
  SELECT oid, relacl::text acl, reloptions::text opts FROM pg_class
   WHERE oid IN ('derm.gdos'::regclass, 'ops.v_derm_compliance'::regclass, 'customer.clients'::regclass,
                 'ops.v_route_today'::regclass, 'ops.v_service_due'::regclass);
CREATE TEMP TABLE p2_lt ON COMMIT DROP AS
  SELECT gdo_id FROM public.fn_gdo_permit_label_targets(1000, (SELECT array_agg(id) FROM public.gdos));
CREATE TEMP TABLE p2_ap ON COMMIT DROP AS
  SELECT derm.audit_pack_client((SELECT client_id FROM public.gdos WHERE id = 141), '2026-01-01', '2026-12-31')->'gdo' AS gdo;

-- derm.gdos
DO $estep2_0$
DECLARE
  d text := pg_get_viewdef('derm.gdos'::regclass, true);
  n text;
BEGIN
  IF md5(d) <> 'f822c3e8d8df714423e20e9e179418d2' THEN RAISE EXCEPTION 'permits: derm.gdos changed since 2026-11-02 (md5 %)', md5(d); END IF;
  n := d;
  IF (length(n) - length(replace(n, $a0$   FROM gdos g
     JOIN clients c ON c.id = g.client_id;$a0$, ''))) / length($a0$   FROM gdos g
     JOIN clients c ON c.id = g.client_id;$a0$) <> 1 THEN RAISE EXCEPTION 'permits: derm.gdos anchor 0 not found 1 time(s)'; END IF;
  n := replace(n, $a0$   FROM gdos g
     JOIN clients c ON c.id = g.client_id;$a0$, $b0$   FROM gdos g
     JOIN clients c ON c.id = g.client_id
  WHERE g.permit_type = 'GDO'::text;$b0$);
  EXECUTE 'CREATE OR REPLACE VIEW derm.gdos AS ' || n;
END $estep2_0$;

-- ops.v_derm_compliance
DO $estep2_1$
DECLARE
  d text := pg_get_viewdef('ops.v_derm_compliance'::regclass, true);
  n text;
BEGIN
  IF md5(d) <> 'ad5c40c7ed0abcdc9635f1b7a7acb64a' THEN RAISE EXCEPTION 'permits: ops.v_derm_compliance changed since 2026-11-02 (md5 %)', md5(d); END IF;
  n := d;
  IF (length(n) - length(replace(n, $a0$WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id$a0$, ''))) / length($a0$WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id$a0$) <> 2 THEN RAISE EXCEPTION 'permits: ops.v_derm_compliance anchor 0 not found 2 time(s)'; END IF;
  n := replace(n, $a0$WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id$a0$, $b0$WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text AND g.permit_type = 'GDO'::text
          ORDER BY g.id$b0$);
  EXECUTE 'CREATE OR REPLACE VIEW ops.v_derm_compliance AS ' || n;
END $estep2_1$;

-- customer.clients
DO $estep2_2$
DECLARE
  d text := pg_get_viewdef('customer.clients'::regclass, true);
  n text;
BEGIN
  IF md5(d) <> 'f4ee12e3066b18398f16ccb0bca65a2f' THEN RAISE EXCEPTION 'permits: customer.clients changed since 2026-11-02 (md5 %)', md5(d); END IF;
  n := d;
  IF (length(n) - length(replace(n, $a0$( SELECT g.permit_document_path
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text$a0$, ''))) / length($a0$( SELECT g.permit_document_path
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text$a0$) <> 1 THEN RAISE EXCEPTION 'permits: customer.clients anchor 0 not found 1 time(s)'; END IF;
  n := replace(n, $a0$( SELECT g.permit_document_path
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text$a0$, $b0$( SELECT g.permit_document_path
           FROM gdos g
          WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text AND g.permit_type = 'GDO'::text$b0$);
  EXECUTE 'CREATE OR REPLACE VIEW customer.clients AS ' || n;
END $estep2_2$;

-- ops.v_route_today
DO $estep2_3$
DECLARE
  d text := pg_get_viewdef('ops.v_route_today'::regclass, true);
  n text;
BEGIN
  IF md5(d) <> '085778cc7214585e15d77277ad2a79d3' THEN RAISE EXCEPTION 'permits: ops.v_route_today changed since 2026-11-02 (md5 %)', md5(d); END IF;
  n := d;
  IF (length(n) - length(replace(n, $a0$WHERE g.property_id = v.property_id AND g.status = 'ACTIVE'::text
          ORDER BY g.id$a0$, ''))) / length($a0$WHERE g.property_id = v.property_id AND g.status = 'ACTIVE'::text
          ORDER BY g.id$a0$) <> 1 THEN RAISE EXCEPTION 'permits: ops.v_route_today anchor 0 not found 1 time(s)'; END IF;
  n := replace(n, $a0$WHERE g.property_id = v.property_id AND g.status = 'ACTIVE'::text
          ORDER BY g.id$a0$, $b0$WHERE g.property_id = v.property_id AND g.status = 'ACTIVE'::text
          ORDER BY (g.permit_type = 'GDO'::text) DESC, g.id$b0$);
  IF (length(n) - length(replace(n, $a1$WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id$a1$, ''))) / length($a1$WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id$a1$) <> 1 THEN RAISE EXCEPTION 'permits: ops.v_route_today anchor 1 not found 1 time(s)'; END IF;
  n := replace(n, $a1$WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id$a1$, $b1$WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY (g.permit_type = 'GDO'::text) DESC, g.id$b1$);
  EXECUTE 'CREATE OR REPLACE VIEW ops.v_route_today AS ' || n;
END $estep2_3$;

-- ops.v_service_due
DO $estep2_4$
DECLARE
  d text := pg_get_viewdef('ops.v_service_due'::regclass, true);
  n text;
BEGIN
  IF md5(d) <> '1b2ed2386d1f4f0022a941cf5de2904b' THEN RAISE EXCEPTION 'permits: ops.v_service_due changed since 2026-11-02 (md5 %)', md5(d); END IF;
  n := d;
  IF (length(n) - length(replace(n, $a0$WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id$a0$, ''))) / length($a0$WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id$a0$) <> 1 THEN RAISE EXCEPTION 'permits: ops.v_service_due anchor 0 not found 1 time(s)'; END IF;
  n := replace(n, $a0$WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY g.id$a0$, $b0$WHERE g.client_id = c.id AND g.status = 'ACTIVE'::text
          ORDER BY (g.permit_type = 'GDO'::text) DESC, g.id$b0$);
  EXECUTE 'CREATE OR REPLACE VIEW ops.v_service_due AS ' || n;
END $estep2_4$;

-- derm.audit_pack
DO $estep2_5$
DECLARE
  d text := pg_get_functiondef('derm.audit_pack(bigint)'::regprocedure);
  n text;
BEGIN
  IF md5(d) <> '163264a736437fcd7230d8f6338de795' THEN RAISE EXCEPTION 'permits: derm.audit_pack changed since 2026-11-02 (md5 %)', md5(d); END IF;
  n := d;
  IF (length(n) - length(replace(n, $a0$WHERE g2.client_id = v_m.client_id AND g2.status = 'ACTIVE'$a0$, ''))) / length($a0$WHERE g2.client_id = v_m.client_id AND g2.status = 'ACTIVE'$a0$) <> 2 THEN RAISE EXCEPTION 'permits: derm.audit_pack anchor 0 not found 2 time(s)'; END IF;
  n := replace(n, $a0$WHERE g2.client_id = v_m.client_id AND g2.status = 'ACTIVE'$a0$, $b0$WHERE g2.client_id = v_m.client_id AND g2.status = 'ACTIVE' AND g2.permit_type = 'GDO'$b0$);
  EXECUTE n;
  IF pg_get_functiondef('derm.audit_pack(bigint)'::regprocedure) <> n THEN RAISE EXCEPTION 'permits: derm.audit_pack re-read differs from the edited text'; END IF;
END $estep2_5$;

-- derm.audit_pack_client
DO $estep2_6$
DECLARE
  d text := pg_get_functiondef('derm.audit_pack_client(bigint,date,date)'::regprocedure);
  n text;
BEGIN
  IF md5(d) <> 'fa4f8ce503cfcfa658ccc41e39d8727d' THEN RAISE EXCEPTION 'permits: derm.audit_pack_client changed since 2026-11-02 (md5 %)', md5(d); END IF;
  n := d;
  IF (length(n) - length(replace(n, $a0$g.client_id = p_client_id AND g.status = 'ACTIVE'$a0$, ''))) / length($a0$g.client_id = p_client_id AND g.status = 'ACTIVE'$a0$) <> 2 THEN RAISE EXCEPTION 'permits: derm.audit_pack_client anchor 0 not found 2 time(s)'; END IF;
  n := replace(n, $a0$g.client_id = p_client_id AND g.status = 'ACTIVE'$a0$, $b0$g.client_id = p_client_id AND g.status = 'ACTIVE' AND g.permit_type = 'GDO'$b0$);
  EXECUTE n;
  IF pg_get_functiondef('derm.audit_pack_client(bigint,date,date)'::regprocedure) <> n THEN RAISE EXCEPTION 'permits: derm.audit_pack_client re-read differs from the edited text'; END IF;
END $estep2_6$;

-- public.fn_check_gdo_on_visit
DO $estep2_7$
DECLARE
  d text := pg_get_functiondef('public.fn_check_gdo_on_visit()'::regprocedure);
  n text;
BEGIN
  IF md5(d) <> '68ad97e23f63e40e08b0c0cd842c9da3' THEN RAISE EXCEPTION 'permits: public.fn_check_gdo_on_visit changed since 2026-11-02 (md5 %)', md5(d); END IF;
  n := d;
  IF (length(n) - length(replace(n, $a0$      AND g.status IN ('ACTIVE', 'EXPIRED')$a0$, ''))) / length($a0$      AND g.status IN ('ACTIVE', 'EXPIRED')$a0$) <> 1 THEN RAISE EXCEPTION 'permits: public.fn_check_gdo_on_visit anchor 0 not found 1 time(s)'; END IF;
  n := replace(n, $a0$      AND g.status IN ('ACTIVE', 'EXPIRED')$a0$, $b0$      AND g.status IN ('ACTIVE', 'EXPIRED')
      AND g.permit_type = 'GDO'  -- 2026-11-02: a PSO or CCN is not a GDO$b0$);
  EXECUTE n;
  IF pg_get_functiondef('public.fn_check_gdo_on_visit()'::regprocedure) <> n THEN RAISE EXCEPTION 'permits: public.fn_check_gdo_on_visit re-read differs from the edited text'; END IF;
END $estep2_7$;

-- public.fn_gdo_permit_label_targets
DO $estep2_8$
DECLARE
  d text := pg_get_functiondef('public.fn_gdo_permit_label_targets(integer,bigint[])'::regprocedure);
  n text;
BEGIN
  IF md5(d) <> 'f3bd261bf17d7f1929caca4c59a63762' THEN RAISE EXCEPTION 'permits: public.fn_gdo_permit_label_targets changed since 2026-11-02 (md5 %)', md5(d); END IF;
  n := d;
  IF (length(n) - length(replace(n, $a0$   where o.metadata->>'eTag' is not null$a0$, ''))) / length($a0$   where o.metadata->>'eTag' is not null$a0$) <> 1 THEN RAISE EXCEPTION 'permits: public.fn_gdo_permit_label_targets anchor 0 not found 1 time(s)'; END IF;
  n := replace(n, $a0$   where o.metadata->>'eTag' is not null$a0$, $b0$   where o.metadata->>'eTag' is not null
     -- 2026-11-02: only types whose PDF we read (GDO); a CCN or PSO PDF is never sent to the DERM prompt
     and exists (select 1 from public.permit_types t where t.code = g.permit_type and t.reads_pdf)$b0$);
  EXECUTE n;
  IF pg_get_functiondef('public.fn_gdo_permit_label_targets(integer,bigint[])'::regprocedure) <> n THEN RAISE EXCEPTION 'permits: public.fn_gdo_permit_label_targets re-read differs from the edited text'; END IF;
END $estep2_8$;

-- VERIFY
DO $verify$
DECLARE
  v_c bigint := (SELECT client_id FROM public.gdos WHERE id = 141);
  g int; n int;
BEGIN
  -- derm.gdos: exactly row 141 leaves, nothing else moves
  SELECT count(*) INTO g FROM (SELECT r FROM p2_dg EXCEPT ALL SELECT t::text FROM derm.gdos t) x;
  SELECT count(*) INTO n FROM (SELECT t::text r FROM derm.gdos t EXCEPT ALL SELECT r FROM p2_dg) x;
  IF g <> 1 OR n <> 0 OR NOT EXISTS (SELECT 1 FROM (SELECT r FROM p2_dg EXCEPT SELECT t::text FROM derm.gdos t) x WHERE r LIKE '%PSO-00025%') THEN
    RAISE EXCEPTION 'permits step 2 VERIFY: derm.gdos gone %, new % (predicted 1 / 0, the PSO row)', g, n;
  END IF;
  -- ops.v_derm_compliance and customer.clients: exactly one row each changes, and PSO-00025 is gone from it
  SELECT count(*) INTO g FROM (SELECT r FROM p2_dc EXCEPT ALL SELECT t::text FROM ops.v_derm_compliance t) x;
  SELECT count(*) INTO n FROM (SELECT t::text r FROM ops.v_derm_compliance t EXCEPT ALL SELECT r FROM p2_dc) x;
  IF g <> 1 OR n <> 1 OR EXISTS (SELECT 1 FROM ops.v_derm_compliance t WHERE t::text LIKE '%PSO-00025%') THEN
    RAISE EXCEPTION 'permits step 2 VERIFY: ops.v_derm_compliance gone %, new % (predicted 1 / 1)', g, n;
  END IF;
  SELECT count(*) INTO g FROM (SELECT r FROM p2_cc EXCEPT ALL SELECT t::text FROM customer.clients t) x;
  SELECT count(*) INTO n FROM (SELECT t::text r FROM customer.clients t EXCEPT ALL SELECT r FROM p2_cc) x;
  IF g <> 1 OR n <> 1 OR EXISTS (SELECT 1 FROM customer.clients t WHERE t::text LIKE '%PSO-00025%') THEN
    RAISE EXCEPTION 'permits step 2 VERIFY: customer.clients gone %, new % (predicted 1 / 1)', g, n;
  END IF;
  -- route and service-due: no change today
  SELECT count(*) INTO g FROM (SELECT r FROM p2_rt EXCEPT ALL SELECT t::text FROM ops.v_route_today t) x;
  SELECT count(*) INTO n FROM (SELECT t::text r FROM ops.v_route_today t EXCEPT ALL SELECT r FROM p2_rt) x;
  IF g <> 0 OR n <> 0 THEN RAISE EXCEPTION 'permits step 2 VERIFY: ops.v_route_today moved (% / %)', g, n; END IF;
  SELECT count(*) INTO g FROM (SELECT r FROM p2_sd EXCEPT ALL SELECT t::text FROM ops.v_service_due t) x;
  SELECT count(*) INTO n FROM (SELECT t::text r FROM ops.v_service_due t EXCEPT ALL SELECT r FROM p2_sd) x;
  IF g <> 0 OR n <> 0 THEN RAISE EXCEPTION 'permits step 2 VERIFY: ops.v_service_due moved (% / %)', g, n; END IF;
  -- grants and options unchanged
  IF EXISTS (SELECT 1 FROM p2_acl a JOIN pg_class c ON c.oid = a.oid
              WHERE c.relacl::text IS DISTINCT FROM a.acl OR c.reloptions::text IS DISTINCT FROM a.opts) THEN
    RAISE EXCEPTION 'permits step 2 VERIFY: a view''s grants or options changed';
  END IF;
  -- audit pack: 057-BAY no longer reports PSO-00025 as its GDO (the before value is the control)
  IF (SELECT gdo->>'gdo_number' FROM p2_ap) IS DISTINCT FROM 'PSO-00025' THEN
    RAISE EXCEPTION 'permits step 2 VERIFY: control failed, audit_pack_client did not name PSO-00025 before';
  END IF;
  IF (derm.audit_pack_client(v_c, '2026-01-01', '2026-12-31')->>'gdo') IS NOT NULL THEN   -- ->> : a JSON null reads as SQL NULL
    RAISE EXCEPTION 'permits step 2 VERIFY: audit_pack_client still names a non-GDO permit for 057-BAY';
  END IF;
  -- label reader: row 141 no longer offered (it was before: the control), every other row offered before still is
  IF NOT EXISTS (SELECT 1 FROM p2_lt WHERE gdo_id = 141) THEN
    RAISE EXCEPTION 'permits step 2 VERIFY: control failed, the label reader did not offer row 141 before';
  END IF;
  IF EXISTS (SELECT 1 FROM public.fn_gdo_permit_label_targets(1000, ARRAY[141::bigint])) THEN
    RAISE EXCEPTION 'permits step 2 VERIFY: the label reader still offers row 141';
  END IF;
  SELECT count(*) INTO g FROM (SELECT gdo_id FROM p2_lt WHERE gdo_id <> 141
         EXCEPT SELECT gdo_id FROM public.fn_gdo_permit_label_targets(1000, (SELECT array_agg(id) FROM public.gdos))) x;
  IF g <> 0 THEN RAISE EXCEPTION 'permits step 2 VERIFY: the label reader lost % GDO row(s)', g; END IF;
END $verify$;

COMMIT;
