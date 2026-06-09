-- Full schema snapshot regenerated from Prod (wbasvhvvismukaqdnouk) on 2026-06-09 via 'supabase db dump'.
-- Canonical from-zero baseline; incremental changes since are tracked in docs/migrations/.
--



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "audit";


ALTER SCHEMA "audit" OWNER TO "postgres";


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE SCHEMA IF NOT EXISTS "customer";


ALTER SCHEMA "customer" OWNER TO "postgres";


COMMENT ON SCHEMA "customer" IS 'Customer-facing portal access layer. All views read from canonical (public). App-layer tenant isolation via encrypted cookie + slug guard. Anon role can SELECT views, not canonical.';



CREATE SCHEMA IF NOT EXISTS "derm";


ALTER SCHEMA "derm" OWNER TO "postgres";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";






CREATE SCHEMA IF NOT EXISTS "ops";


ALTER SCHEMA "ops" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "partman";


ALTER SCHEMA "partman" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "raw";


ALTER SCHEMA "raw" OWNER TO "postgres";


CREATE EXTENSION IF NOT EXISTS "pg_partman" WITH SCHEMA "partman";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgaudit" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "audit"."log_change"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  v_pk_cols          TEXT[];
  v_pk               JSONB;
  v_old_clean        JSONB;
  v_new_clean        JSONB;
  v_headers          JSONB;
  v_origin           TEXT;
  v_referer          TEXT;
  v_method           TEXT;
  v_path             TEXT;
  v_x_app_source     TEXT;
  v_app_source       TEXT;
  v_request_context  JSONB;
BEGIN
  -- Recursion guard
  IF TG_TABLE_SCHEMA = 'audit' THEN
    RETURN COALESCE(NEW, OLD);
  END IF;

  -- PK extraction
  SELECT pg_catalog.array_agg(a.attname::TEXT)
    INTO v_pk_cols
    FROM pg_catalog.pg_index i
    JOIN pg_catalog.pg_attribute a
      ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
   WHERE i.indrelid = TG_RELID AND i.indisprimary;

  IF v_pk_cols IS NULL THEN
    v_pk := '{}'::jsonb;
  ELSE
    SELECT pg_catalog.jsonb_object_agg(col, pg_catalog.to_jsonb(COALESCE(NEW, OLD))->col)
      INTO v_pk
      FROM pg_catalog.unnest(v_pk_cols) AS col;
  END IF;

  -- Old/new diff
  v_old_clean := CASE WHEN TG_OP IN ('UPDATE','DELETE')
                      THEN pg_catalog.to_jsonb(OLD) - 'updated_at'
                 END;
  v_new_clean := CASE WHEN TG_OP IN ('INSERT','UPDATE')
                      THEN pg_catalog.to_jsonb(NEW) - 'updated_at'
                 END;

  IF TG_OP = 'UPDATE' AND v_old_clean IS NOT DISTINCT FROM v_new_clean THEN
    RETURN NEW;
  END IF;

  -- Capture request context defensively (NULLIF as plain SQL expr, not
  -- pg_catalog.nullif which doesn't exist).
  BEGIN
    v_headers := NULLIF(pg_catalog.current_setting('request.headers', true), '')::jsonb;
  EXCEPTION WHEN OTHERS THEN
    v_headers := NULL;
  END;

  v_origin       := COALESCE(v_headers->>'origin', '');
  v_referer      := COALESCE(v_headers->>'referer', '');
  v_method       := NULLIF(pg_catalog.current_setting('request.method', true), '');
  v_path         := NULLIF(pg_catalog.current_setting('request.path', true), '');
  v_x_app_source := NULLIF(v_headers->>'x-app-source', '');

  v_app_source := COALESCE(
    v_x_app_source,
    CASE
      WHEN v_origin = '' THEN 'sql'
      WHEN v_origin LIKE '%derm.unclogme.app%'    THEN 'derm-tracker'
      WHEN v_origin LIKE '%fp.unclogme.app%'      THEN 'field-portal'
      WHEN v_origin LIKE '%grease-buddy-dash%'    THEN 'admin-review'
      WHEN v_origin LIKE '%6533c3ee%'             THEN 'visit-calendar'
      WHEN v_origin LIKE '%lovable.app%'          THEN 'lovable-preview'
      ELSE 'other:' || COALESCE(pg_catalog.substring(v_origin, 'https?://([^/]+)'), v_origin)
    END
  );

  v_request_context := pg_catalog.jsonb_strip_nulls(
    pg_catalog.jsonb_build_object(
      'origin',          NULLIF(v_origin, ''),
      'referer',         NULLIF(v_referer, ''),
      'method',          v_method,
      'path',            v_path,
      'app_source_hint', v_x_app_source
    )
  );

  INSERT INTO audit.logs (
    table_schema, table_name, record_pk, operation,
    old_row, new_row,
    changed_by, db_role, jwt_claims,
    app_source, request_context
  ) VALUES (
    TG_TABLE_SCHEMA,
    TG_TABLE_NAME,
    v_pk,
    TG_OP,
    v_old_clean,
    v_new_clean,
    NULLIF(pg_catalog.current_setting('request.jwt.claim.sub', true), '')::uuid,
    CURRENT_USER::text,
    NULLIF(pg_catalog.current_setting('request.jwt.claims', true), '')::jsonb,
    v_app_source,
    CASE WHEN v_request_context = '{}'::jsonb THEN NULL ELSE v_request_context END
  );

  RETURN COALESCE(NEW, OLD);
END;
$$;


ALTER FUNCTION "audit"."log_change"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "customer"."bigint_from_uuid"("u" "uuid") RETURNS bigint
    LANGUAGE "sql" IMMUTABLE STRICT
    AS $$
  SELECT NULLIF(right(replace(u::text, '-', ''), 12), '')::bigint
$$;


ALTER FUNCTION "customer"."bigint_from_uuid"("u" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "customer"."bigint_from_uuid"("u" "uuid") IS 'Reverse of customer.uuid_from_bigint. ONLY safe on UUIDs that came from customer.uuid_from_bigint.';



CREATE OR REPLACE FUNCTION "customer"."uuid_from_bigint"("b" bigint) RETURNS "uuid"
    LANGUAGE "sql" IMMUTABLE STRICT
    AS $$
  SELECT ('00000000-0000-0000-0000-' || lpad(b::text, 12, '0'))::uuid
$$;


ALTER FUNCTION "customer"."uuid_from_bigint"("b" bigint) OWNER TO "postgres";


COMMENT ON FUNCTION "customer"."uuid_from_bigint"("b" bigint) IS 'Deterministic synthetic UUID from canonical BIGINT id. Frontend uses UUIDs; canonical uses BIGINTs. Reversible via customer.bigint_from_uuid.';



CREATE OR REPLACE FUNCTION "public"."gen_short_id"("n_chars" integer DEFAULT 10) RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
DECLARE
  alphabet CONSTANT TEXT :=
    '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  bytes BYTEA;
  result TEXT := '';
  i INT;
BEGIN
  -- gen_random_bytes lives in the extensions schema (pgcrypto).
  bytes := extensions.gen_random_bytes(n_chars);
  FOR i IN 0..(n_chars - 1) LOOP
    -- Modulo 62 introduces a slight bias (256 % 62 = 8), but for
    -- 60-bit-equivalent unguessability that's irrelevant. We're not
    -- using this as a cryptographic primitive — just a URL token.
    result := result || pg_catalog.substr(alphabet, (pg_catalog.get_byte(bytes, i) % 62) + 1, 1);
  END LOOP;
  RETURN result;
END;
$$;


ALTER FUNCTION "public"."gen_short_id"("n_chars" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."gen_short_id"("n_chars" integer) IS 'Generate a short, cryptographically-random base62 token (default 10 chars). Used for URL-facing public IDs (e.g. visits.public_id) to prevent IDOR enumeration.';


SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."derm_manifests" (
    "id" bigint NOT NULL,
    "client_id" bigint NOT NULL,
    "service_date" "date",
    "dump_ticket_date" "date",
    "white_manifest_number" "text",
    "yellow_ticket_number" "text",
    "sent_to_client" boolean DEFAULT false,
    "sent_to_city" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "wwtp_receipt_number" "text",
    "wwtp_receipt_document_path" "text",
    "wwtp_ticket_number" "text",
    "disposal_facility_id" bigint,
    "derm_manifest_url" "text",
    "derm_address_url" "text",
    "gdo_id" bigint,
    "derm_manifest_extra_urls" "text"[] DEFAULT '{}'::"text"[],
    "derm_address_extra_urls" "text"[] DEFAULT '{}'::"text"[],
    "deleted_at" timestamp with time zone,
    "notes" "text",
    "derm_address_no" bigint,
    "fog_manifest_url" "text"
);

ALTER TABLE ONLY "public"."derm_manifests" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."derm_manifests" OWNER TO "postgres";


COMMENT ON TABLE "public"."derm_manifests" IS 'DERM compliance manifests (868). County-required. Fines: $500-$3,000. DADE=481xxx, BROWARD=294xxx.';



COMMENT ON COLUMN "public"."derm_manifests"."wwtp_receipt_number" IS 'WWTP-side disposal receipt number, complementary to white_manifest_number (which is the DERM document) and yellow_ticket_number (the dump-side ticket).';



COMMENT ON COLUMN "public"."derm_manifests"."wwtp_receipt_document_path" IS 'Supabase Storage path to the WWTP receipt PDF.';



COMMENT ON COLUMN "public"."derm_manifests"."disposal_facility_id" IS 'FK to disposal_facilities. Which dump site was used for this specific manifest.';



COMMENT ON COLUMN "public"."derm_manifests"."derm_manifest_url" IS 'URL of the DERM-issued manifest PDF (sourced from AT "DERM Manifest" attachment). Surfaced to customers as the "WWTP Disposal Receipt" document in the Field Portal. STOP-GAP: stores AT-signed URL (expires in hours). Migrate to Supabase Storage path in a follow-up.';



COMMENT ON COLUMN "public"."derm_manifests"."derm_address_url" IS 'URL of the DERM address-proof PDF (sourced from AT "DERM Address" attachment). Surfaced to customers as the "DERM FOG eManifest" document in the Field Portal. STOP-GAP: stores AT-signed URL (expires in hours). Migrate to Supabase Storage path in a follow-up.';



COMMENT ON COLUMN "public"."derm_manifests"."notes" IS 'Free-text ops annotation (e.g. damaged/lost paper manifest, known accepted doc gaps). Not synced from Airtable; safe from webhook overwrite.';



COMMENT ON COLUMN "public"."derm_manifests"."derm_address_no" IS 'Sequential DERM Address sheet number (from next_derm_address_id(), starts 1000) printed top-right on the generated DERM Address PDF. Per SHEET (one dump ticket): on FINAL generation written to ALL derm_manifests rows sharing that dump ticket, alongside derm_address_url. Searchable. Sequence has gaps (previews burn numbers). NULL until a sheet is filed.';



CREATE TABLE IF NOT EXISTS "public"."employees" (
    "id" bigint NOT NULL,
    "full_name" "text" NOT NULL,
    "role" "text",
    "status" "text" DEFAULT 'ACTIVE'::"text",
    "shift" "text",
    "email" "text",
    "phone" "text",
    "hire_date" "date",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "access_level" "text"
);

ALTER TABLE ONLY "public"."employees" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."employees" OWNER TO "postgres";


COMMENT ON TABLE "public"."employees" IS 'All team members: 10 active. Access levels: dev > office > field. Field staff CANNOT access financial data.';



COMMENT ON COLUMN "public"."employees"."access_level" IS 'Operational access tier: dev (full), office (scheduling/billing), field (job updates only)';



CREATE TABLE IF NOT EXISTS "public"."manifest_visits" (
    "manifest_id" bigint NOT NULL,
    "visit_id" bigint NOT NULL
);

ALTER TABLE ONLY "public"."manifest_visits" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."manifest_visits" OWNER TO "postgres";


COMMENT ON TABLE "public"."manifest_visits" IS 'M:N junction: DERM manifests <-> visits. Multi-trap clients generate multiple manifests per visit.';



CREATE TABLE IF NOT EXISTS "public"."properties" (
    "id" bigint NOT NULL,
    "client_id" bigint NOT NULL,
    "name" "text",
    "address" "text",
    "city" "text",
    "state" "text" DEFAULT 'FL'::"text",
    "zip" "text",
    "country" "text" DEFAULT 'US'::"text",
    "is_billing" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "zone" "text",
    "latitude" numeric,
    "longitude" numeric,
    "geofence_radius_meters" numeric,
    "geofence_type" "text",
    "access_hours_start" "text",
    "access_hours_end" "text",
    "access_days" "text"[],
    "is_primary" boolean DEFAULT true,
    "notes" "text",
    "county" "text",
    "grease_trap_manhole_count" integer DEFAULT 0 NOT NULL,
    "access_notes" "text",
    "default_disposal_facility_id" bigint,
    "zone_id" bigint,
    CONSTRAINT "chk_grease_trap_manhole_count_range" CHECK ((("grease_trap_manhole_count" >= 0) AND ("grease_trap_manhole_count" <= 50)))
);

ALTER TABLE ONLY "public"."properties" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."properties" OWNER TO "postgres";


COMMENT ON TABLE "public"."properties" IS 'Service locations per client. 367 rows from Jobber. 1 client -> many properties (chains like La Granja have 5+).';



COMMENT ON COLUMN "public"."properties"."grease_trap_manhole_count" IS 'Number of grease trap manholes (covers) at this property. Default 1. Set explicitly when a property has multiple traps. Manually maintained by Diego/Yannick.';



COMMENT ON COLUMN "public"."properties"."access_notes" IS 'Free-form access instructions beyond the structured access_hours_* / access_days fields.';



COMMENT ON COLUMN "public"."properties"."default_disposal_facility_id" IS 'FK to disposal_facilities. Default dump site for this property''s waste. Per-manifest override lives in derm_manifests.disposal_facility_id.';



CREATE TABLE IF NOT EXISTS "public"."service_configs" (
    "id" bigint NOT NULL,
    "client_id" bigint NOT NULL,
    "service_type" "text" NOT NULL,
    "frequency_days" integer,
    "first_visit" "date",
    "last_visit" "date",
    "stop_date" "date",
    "price_per_visit" numeric(12,2),
    "schedule_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "equipment_size_gallons" numeric,
    "material_type" "text",
    "property_id" bigint,
    CONSTRAINT "service_configs_service_type_chk" CHECK (("service_type" = ANY (ARRAY['GT'::"text", 'CL'::"text", 'WD'::"text", 'LS'::"text"])))
);

ALTER TABLE ONLY "public"."service_configs" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."service_configs" OWNER TO "postgres";


COMMENT ON TABLE "public"."service_configs" IS '3NF: one row per client per service type. Eliminates gt_*/cl_*/wd_* repeating groups. DERM max 90 days. EMERGENCY is visit-level only, not a service config.';



COMMENT ON COLUMN "public"."service_configs"."material_type" IS 'Type of waste the GT/CL/LS service handles, e.g. "FOG", "wastewater", "gray water". Free-form for now; promote to CHECK constraint when values stabilize.';



COMMENT ON COLUMN "public"."service_configs"."property_id" IS 'FK to properties.id. Nullable: existing rows backfilled with the client''s primary property in this migration (2026-05-23a). For Casa Neos-style multi-property clients, each (client_id, property_id, service_type) combination is a distinct service_config row. ON DELETE RESTRICT to prevent orphaning service schedules.';



CREATE TABLE IF NOT EXISTS "public"."vehicles" (
    "id" bigint NOT NULL,
    "name" "text" NOT NULL,
    "make" "text",
    "model" "text",
    "year" integer,
    "vin" "text",
    "license_plate" "text",
    "grease_tank_capacity_gallons" numeric NOT NULL,
    "status" "text" DEFAULT 'ACTIVE'::"text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "fuel_tank_capacity_gallons" numeric,
    "decal_number" "text"
);

ALTER TABLE ONLY "public"."vehicles" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."vehicles" OWNER TO "postgres";


COMMENT ON TABLE "public"."vehicles" IS '4 trucks at 17% capacity. Names are people names (Moise, David = TRUCKS not drivers). Goliath has no Samsara data.';



COMMENT ON COLUMN "public"."vehicles"."grease_tank_capacity_gallons" IS 'Grease/waste vacuum tank capacity in gallons. Drives route planning and dump scheduling. Unrelated to fuel_tank_capacity_gallons.';



COMMENT ON COLUMN "public"."vehicles"."fuel_tank_capacity_gallons" IS 'Diesel/gas fuel tank capacity in gallons. Used with Samsara fuelPercent to compute fuel_gallons on read. NULL for inactive vehicles.';



COMMENT ON COLUMN "public"."vehicles"."decal_number" IS 'DERM/permit sticker number affixed to the truck. Displayed to customers on the work-order detail.';



CREATE TABLE IF NOT EXISTS "public"."visit_assignments" (
    "visit_id" bigint NOT NULL,
    "employee_id" bigint NOT NULL
);

ALTER TABLE ONLY "public"."visit_assignments" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."visit_assignments" OWNER TO "postgres";


COMMENT ON TABLE "public"."visit_assignments" IS 'M:N junction. 2+ techs on large truck visits (David/Goliath/Moise). 1,589 assignments from Jobber.';



CREATE TABLE IF NOT EXISTS "public"."visits" (
    "id" bigint NOT NULL,
    "client_id" bigint,
    "property_id" bigint,
    "job_id" bigint,
    "vehicle_id" bigint,
    "visit_date" "date" NOT NULL,
    "start_at" timestamp with time zone,
    "end_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "duration_minutes" integer,
    "title" "text",
    "service_type" "text",
    "visit_status" "text",
    "actual_arrival_at" timestamp with time zone,
    "actual_departure_at" timestamp with time zone,
    "is_gps_confirmed" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "invoice_id" bigint,
    "completed_by" "text",
    "source" "text" DEFAULT 'jobber'::"text" NOT NULL,
    "manhole_count" integer,
    "manhole_breakdown" "text",
    "ticket_number" "text",
    "trap_condition_notes" "text",
    "derm_required" boolean,
    "public_id" "text" DEFAULT "public"."gen_short_id"() NOT NULL,
    "deleted_at" timestamp with time zone,
    "service_line_item_id" bigint,
    "notes" "text",
    CONSTRAINT "chk_manhole_count_range" CHECK ((("manhole_count" >= 0) AND ("manhole_count" <= 50))),
    CONSTRAINT "visits_service_type_chk" CHECK ((("service_type" IS NULL) OR ("service_type" = ANY (ARRAY['GT'::"text", 'CL'::"text", 'WD'::"text", 'LS'::"text"])))),
    CONSTRAINT "visits_source_chk" CHECK (("source" = ANY (ARRAY['jobber'::"text", 'supabase_cron'::"text", 'airtable'::"text", 'manual'::"text", 'odoo'::"text", 'visit-calendar'::"text"])))
);

ALTER TABLE ONLY "public"."visits" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."visits" OWNER TO "postgres";


COMMENT ON TABLE "public"."visits" IS 'CORE TABLE. Every service event. ~3,100 rows merged from Airtable (3,016) + Jobber (1,636). Overnight ops: +/-12h query windows.';



COMMENT ON COLUMN "public"."visits"."completed_by" IS 'AT-legacy: original driver attribution for ~1400 historical Airtable visits. Resolved to visit_assignments via fixup pass.';



COMMENT ON COLUMN "public"."visits"."source" IS 'Who created this row in our DB: jobber (cron_jobber pulled from Jobber API), supabase_cron (cron_generate_recurring_visits scheduled placeholder), airtable (legacy Airtable mirror sync — pre-2026-05 only), manual (hand-inserted via console), odoo (post-Odoo-cutover writes). When a supabase_cron row gets matched by an incoming Jobber visit, webhook-jobber PROMOTES it: UPDATE in place, source becomes ''jobber'', Jobber GID + entity_source_link attached. This avoids duplicates during the May-June 2026 Airtable+Jobber sunset transition.';



COMMENT ON COLUMN "public"."visits"."manhole_count" IS 'Per-visit count of manholes serviced. Differs from properties.grease_trap_manhole_count (the total at the property) — a visit may service only some manholes.';



COMMENT ON COLUMN "public"."visits"."manhole_breakdown" IS 'Per-visit free-form notes on which manholes were serviced and observations.';



COMMENT ON COLUMN "public"."visits"."ticket_number" IS 'Internal job-side ticket number; complementary to job_id / invoice_id which are FK references.';



COMMENT ON COLUMN "public"."visits"."trap_condition_notes" IS 'Driver assessment of trap state for this visit (e.g. "heavy grease, baffle damaged").';



COMMENT ON COLUMN "public"."visits"."derm_required" IS 'NULL = use default (TRUE if service_type=GT, FALSE otherwise). Explicit TRUE/FALSE = ops override via DERM Tracker.';



COMMENT ON COLUMN "public"."visits"."public_id" IS 'Short cryptographically-random token (10-char base62) exposed in customer-facing URLs. Replaces the predictable customer.uuid_from_bigint(id) pattern that allowed IDOR enumeration. Set automatically on INSERT via gen_short_id() default.';



COMMENT ON COLUMN "public"."visits"."deleted_at" IS 'Soft-delete marker. NOT NULL when Jobber reports the linked Visit GID as not found (deleted or converted in Jobber). Apps MUST filter `deleted_at IS NULL`. Set by scripts/sync/cron_jobber_reconcile_anomalies.js.';



CREATE OR REPLACE VIEW "customer"."work_orders" AS
 SELECT "v"."public_id" AS "id",
    "customer"."uuid_from_bigint"("v"."client_id") AS "client_id",
    "v"."visit_date",
        CASE
            WHEN ("v"."start_at" IS NOT NULL) THEN "to_char"(("v"."start_at" AT TIME ZONE 'America/New_York'::"text"), 'FMHH12:MI AM'::"text")
            ELSE NULL::"text"
        END AS "visit_time",
    ( SELECT "string_agg"("e"."full_name", ', '::"text" ORDER BY "e"."full_name") AS "string_agg"
           FROM ("public"."visit_assignments" "va"
             JOIN "public"."employees" "e" ON (("e"."id" = "va"."employee_id")))
          WHERE ("va"."visit_id" = "v"."id")) AS "driver",
    "veh"."name" AS "truck",
    "veh"."decal_number" AS "decal",
    COALESCE("v"."manhole_count", NULLIF("prop"."grease_trap_manhole_count", 0), NULLIF(( SELECT "prim"."grease_trap_manhole_count"
           FROM "public"."properties" "prim"
          WHERE (("prim"."client_id" = "v"."client_id") AND ("prim"."is_primary" = true))
         LIMIT 1), 0)) AS "manholes",
    "v"."manhole_breakdown",
    "v"."ticket_number",
    "v"."trap_condition_notes" AS "trap_condition",
    ("row_number"() OVER (PARTITION BY "v"."client_id", (EXTRACT(year FROM "v"."visit_date")) ORDER BY "v"."visit_date"))::integer AS "visit_num",
    ( SELECT
                CASE
                    WHEN (("sc"."frequency_days" IS NULL) OR ("sc"."frequency_days" <= 0)) THEN NULL::integer
                    ELSE (GREATEST((1)::numeric, "round"((365.0 / ("sc"."frequency_days")::numeric))))::integer
                END AS "greatest"
           FROM "public"."service_configs" "sc"
          WHERE (("sc"."client_id" = "v"."client_id") AND ("sc"."service_type" = "v"."service_type"))
         LIMIT 1) AS "visit_total",
    "v"."title" AS "notes",
    "dm"."white_manifest_number" AS "derm_manifest_number",
    "dm"."fog_manifest_url" AS "derm_manifest_url",
    COALESCE("dm"."wwtp_receipt_number", "dm"."white_manifest_number", "dm"."yellow_ticket_number") AS "wwtp_receipt_number",
    "dm"."derm_manifest_url" AS "wwtp_receipt_url",
    "dm"."wwtp_ticket_number",
    "v"."created_at",
    COALESCE("v"."completed_at", "v"."created_at") AS "updated_at",
    COALESCE("dm"."white_manifest_number", "dm"."yellow_ticket_number") AS "manifest_number",
        CASE
            WHEN ("dm"."white_manifest_number" IS NOT NULL) THEN 'dade'::"text"
            WHEN ("dm"."yellow_ticket_number" IS NOT NULL) THEN 'broward'::"text"
            ELSE NULL::"text"
        END AS "manifest_jurisdiction"
   FROM ((("public"."visits" "v"
     LEFT JOIN "public"."vehicles" "veh" ON (("veh"."id" = "v"."vehicle_id")))
     LEFT JOIN "public"."properties" "prop" ON (("prop"."id" = "v"."property_id")))
     LEFT JOIN LATERAL ( SELECT "dm_inner"."id",
            "dm_inner"."client_id",
            "dm_inner"."service_date",
            "dm_inner"."dump_ticket_date",
            "dm_inner"."white_manifest_number",
            "dm_inner"."yellow_ticket_number",
            "dm_inner"."sent_to_client",
            "dm_inner"."sent_to_city",
            "dm_inner"."created_at",
            "dm_inner"."updated_at",
            "dm_inner"."wwtp_receipt_number",
            "dm_inner"."wwtp_receipt_document_path",
            "dm_inner"."wwtp_ticket_number",
            "dm_inner"."disposal_facility_id",
            "dm_inner"."derm_manifest_url",
            "dm_inner"."derm_address_url",
            "dm_inner"."fog_manifest_url",
            "dm_inner"."gdo_id"
           FROM ("public"."derm_manifests" "dm_inner"
             JOIN "public"."manifest_visits" "mv" ON (("mv"."manifest_id" = "dm_inner"."id")))
          WHERE (("mv"."visit_id" = "v"."id") AND ("dm_inner"."deleted_at" IS NULL))
          ORDER BY "dm_inner"."service_date" DESC NULLS LAST
         LIMIT 1) "dm" ON (true))
  WHERE (("v"."visit_status" = 'completed'::"text") AND ("v"."client_id" IS NOT NULL) AND (COALESCE("v"."derm_required", true) = true));


ALTER VIEW "customer"."work_orders" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "customer"."get_visit_by_slug_and_token"("p_slug" "text", "p_token" "text") RETURNS SETOF "customer"."work_orders"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  SELECT wo.*
  FROM customer.work_orders wo
  JOIN public.clients c ON customer.uuid_from_bigint(c.id) = wo.client_id
  WHERE lower(c.client_code) = lower(p_slug)
    AND wo.id = p_token;
$$;


ALTER FUNCTION "customer"."get_visit_by_slug_and_token"("p_slug" "text", "p_token" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "customer"."get_visit_by_slug_and_token"("p_slug" "text", "p_token" "text") IS 'Server-enforced visit lookup: returns the work_order row ONLY if the visit''s client matches the slug. Used by Field Portal''s visit detail page to prevent IDOR (cross-client visit access via guessed/leaked tokens).';



CREATE OR REPLACE FUNCTION "customer"."public_url"("storage_path" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  SELECT CASE
    WHEN storage_path IS NULL OR storage_path = '' THEN NULL
    ELSE 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/' || storage_path
  END
$$;


ALTER FUNCTION "customer"."public_url"("storage_path" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "customer"."public_url"("storage_path" "text") IS 'Prepends the Prod Supabase Storage public URL + bucket prefix to a relative storage_path. NULL-safe.';



CREATE OR REPLACE FUNCTION "customer"."thumbnail_url"("storage_path" "text", "width" integer DEFAULT 400, "height" integer DEFAULT NULL::integer, "quality" integer DEFAULT 80) RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  SELECT CASE
    WHEN storage_path IS NULL OR storage_path = '' THEN NULL
    ELSE 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/render/image/public/GT%20-%20Visits%20Images/'
         || storage_path
         || '?width=' || width::text
         || '&quality=' || quality::text
         || '&resize=cover'
         || CASE WHEN height IS NOT NULL THEN '&height=' || height::text ELSE '' END
  END
$$;


ALTER FUNCTION "customer"."thumbnail_url"("storage_path" "text", "width" integer, "height" integer, "quality" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ensure_client_has_location"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  INSERT INTO public.client_locations (client_id, name, status)
  VALUES (NEW.id, 'Main', 'active')
  ON CONFLICT (client_id, name) DO NOTHING;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."ensure_client_has_location"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."file_manifest"("p_client_id" bigint, "p_jurisdiction" "text", "p_number" "text", "p_disposal_facility_id" bigint, "p_dump_date" "date", "p_visit_ids" bigint[]) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_id bigint;
BEGIN
  INSERT INTO public.derm_manifests (white_manifest_number, yellow_ticket_number, dump_ticket_date, service_date, disposal_facility_id, client_id)
  VALUES (CASE WHEN p_jurisdiction='Miami-Dade' THEN p_number ELSE NULL END, CASE WHEN p_jurisdiction='Broward' THEN p_number ELSE NULL END, p_dump_date, p_dump_date, p_disposal_facility_id, p_client_id)
  RETURNING id INTO v_id;
  IF p_visit_ids IS NOT NULL AND array_length(p_visit_ids,1) > 0 THEN
    INSERT INTO public.manifest_visits (manifest_id, visit_id)
    SELECT DISTINCT v_id, vid FROM unnest(p_visit_ids) AS vid
    ON CONFLICT (manifest_id, visit_id) DO NOTHING;
  END IF;
  RETURN v_id;
END; $$;


ALTER FUNCTION "public"."file_manifest"("p_client_id" bigint, "p_jurisdiction" "text", "p_number" "text", "p_disposal_facility_id" bigint, "p_dump_date" "date", "p_visit_ids" bigint[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_check_gdo_on_visit"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  v_county  TEXT;
  v_has_gdo BOOLEAN;
BEGIN
  -- Only care about GT visits
  IF NEW.service_type != 'GT' THEN
    RETURN NEW;
  END IF;

  -- Per-visit opt-out (visits.derm_required, 3-state:
  --   NULL  = default-true for GT
  --   TRUE  = explicit opt-in
  --   FALSE = ops marked "not required" via DERM Tracker)
  IF NEW.derm_required IS FALSE THEN
    RETURN NEW;
  END IF;

  -- Check county (Dade only for v1)
  SELECT p.county INTO v_county
  FROM properties p
  WHERE p.client_id = NEW.client_id
    AND p.is_primary = true
  LIMIT 1;

  IF v_county IS DISTINCT FROM 'Dade' THEN
    RETURN NEW;
  END IF;

  -- Check gdos table (ACTIVE + EXPIRED both count as "has a permit",
  -- since EXPIRED still ties to the physical trap, just needs renewal)
  SELECT EXISTS(
    SELECT 1 FROM gdos g
    WHERE g.client_id = NEW.client_id
      AND g.status IN ('ACTIVE', 'EXPIRED')
  ) INTO v_has_gdo;

  -- Fire alert if no GDO on file
  IF NOT v_has_gdo THEN
    PERFORM pg_notify(
      'gdo_compliance_alert',
      json_build_object(
        'client_id',      NEW.client_id,
        'visit_id',       NEW.id,
        'visit_date',     NEW.visit_date,
        'derm_required',  NEW.derm_required,
        'event',          'gt_visit_no_gdo'
      )::text
    );
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_check_gdo_on_visit"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."fn_check_gdo_on_visit"() IS 'Fires pg_notify(gdo_compliance_alert) on GT visits in Dade where the client has no ACTIVE/EXPIRED GDO. Honors visits.derm_required=false opt-out. v3 (2026-05-22). See docs/migrations/2026-05-22d header.';



CREATE OR REPLACE FUNCTION "public"."fn_push_visit_to_jobber"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_op  text;
  v_key text;
BEGIN
  v_op := CASE WHEN NEW.deleted_at IS NOT NULL THEN 'delete' ELSE 'upsert' END;
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'jobber_push_service_key';
  IF v_key IS NULL THEN
    RAISE WARNING 'jobber_push_service_key vault secret missing; skipping push for visit %', NEW.id;
    RETURN NEW;
  END IF;
  PERFORM net.http_post(
    url     := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/jobber-push-visit',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
    body    := jsonb_build_object('op', v_op, 'visit_id', NEW.id)
  );
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."fn_push_visit_to_jobber"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_derm_address_id"() RETURNS bigint
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$ SELECT nextval('public.derm_address_seq') $$;


ALTER FUNCTION "public"."next_derm_address_id"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."next_derm_address_id"() IS 'Atomic next DERM Address sheet number (sequence derm_address_seq, starts 1000). Called by the PDF service per generation (previews burn numbers -> gaps). PostgREST: .rpc(''next_derm_address_id'').';



CREATE OR REPLACE FUNCTION "public"."properties_sync_zone_columns"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.zone IS NOT NULL AND NEW.zone_id IS NULL THEN
      SELECT id INTO NEW.zone_id FROM public.zones WHERE code = NEW.zone;
    ELSIF NEW.zone_id IS NOT NULL AND NEW.zone IS NULL THEN
      SELECT code INTO NEW.zone FROM public.zones WHERE id = NEW.zone_id;
    END IF;
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.zone IS DISTINCT FROM OLD.zone
       AND NEW.zone_id IS NOT DISTINCT FROM OLD.zone_id THEN
      IF NEW.zone IS NULL THEN
        NEW.zone_id := NULL;
      ELSE
        SELECT id INTO NEW.zone_id FROM public.zones WHERE code = NEW.zone;
      END IF;
    ELSIF NEW.zone_id IS DISTINCT FROM OLD.zone_id
          AND NEW.zone IS NOT DISTINCT FROM OLD.zone THEN
      IF NEW.zone_id IS NULL THEN
        NEW.zone := NULL;
      ELSE
        SELECT code INTO NEW.zone FROM public.zones WHERE id = NEW.zone_id;
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END $$;


ALTER FUNCTION "public"."properties_sync_zone_columns"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."seed_visit_locations"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE loc_count int;
BEGIN
  IF NEW.client_id IS NULL THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM public.visit_locations WHERE visit_id = NEW.id) THEN RETURN NEW; END IF;
  SELECT count(*) INTO loc_count FROM public.client_locations WHERE client_id = NEW.client_id;
  IF loc_count = 1 THEN
    INSERT INTO public.visit_locations (visit_id, client_location_id)
    SELECT NEW.id, cl.id FROM public.client_locations cl WHERE cl.client_id = NEW.client_id
    ON CONFLICT DO NOTHING;
  ELSIF loc_count > 1 THEN
    INSERT INTO public.visit_locations (visit_id, client_location_id)
    SELECT NEW.id, cl.id FROM public.client_locations cl
    WHERE cl.client_id = NEW.client_id
      AND EXISTS (SELECT 1 FROM public.gdos g WHERE g.client_location_id = cl.id AND g.status = 'ACTIVE')
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."seed_visit_locations"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_visit_manholes"("p_visit_id" bigint, "p_location_ids" bigint[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE v_client bigint;
BEGIN
  SELECT client_id INTO v_client FROM public.visits WHERE id = p_visit_id AND deleted_at IS NULL;
  IF v_client IS NULL THEN
    RAISE EXCEPTION 'set_visit_manholes: visit % not found (or deleted)', p_visit_id;
  END IF;
  -- remove manholes no longer selected
  DELETE FROM public.visit_locations vl
  WHERE vl.visit_id = p_visit_id
    AND NOT (vl.client_location_id = ANY (COALESCE(p_location_ids, ARRAY[]::bigint[])));
  -- add newly selected manholes, but ONLY locations that belong to this visit's client
  INSERT INTO public.visit_locations (visit_id, client_location_id)
  SELECT p_visit_id, cl.id
  FROM public.client_locations cl
  WHERE cl.client_id = v_client
    AND cl.id = ANY (COALESCE(p_location_ids, ARRAY[]::bigint[]))
  ON CONFLICT (visit_id, client_location_id) DO NOTHING;
END;
$$;


ALTER FUNCTION "public"."set_visit_manholes"("p_visit_id" bigint, "p_location_ids" bigint[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."tg_set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."touch_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."touch_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'pg_catalog', 'public', 'pg_temp'
    AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;


ALTER FUNCTION "public"."trg_set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trg_wipe_upcoming_on_inactive"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Only fire on a transition INTO INACTIVE/PAUSED (not status updates within
  -- the same state, not transitions TO Recurring/ACTIVE).
  IF NEW.status IN ('INACTIVE','PAUSED')
     AND OLD.status NOT IN ('INACTIVE','PAUSED') THEN
    DELETE FROM public.visits
    WHERE client_id = NEW.id
      AND visit_status = 'scheduled'
      AND visit_date >= CURRENT_DATE;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."trg_wipe_upcoming_on_inactive"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."trg_wipe_upcoming_on_inactive"() IS 'When a client flips to INACTIVE or PAUSED, atomically delete all their scheduled future visits. Completed/skipped visits are NOT touched (historical record). Replaces the legacy Airtable automation that did the same thing button-by-button.';



CREATE OR REPLACE FUNCTION "public"."zones_cascade_code_rename"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NEW.code IS DISTINCT FROM OLD.code THEN
    UPDATE public.properties
    SET zone = NEW.code
    WHERE zone_id = NEW.id;
  END IF;
  RETURN NEW;
END $$;


ALTER FUNCTION "public"."zones_cascade_code_rename"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."zones_hard_delete"("_code" "text") RETURNS TABLE("deleted_zone_code" "text", "unlinked_properties" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  _zone_id BIGINT;
  _unlinked INT;
BEGIN
  SELECT id INTO _zone_id FROM public.zones WHERE code = _code;
  IF _zone_id IS NULL THEN
    RAISE EXCEPTION 'Zone with code % not found', _code USING ERRCODE = 'no_data_found';
  END IF;

  -- Unlink properties. Both zone_id AND zone (TEXT) get NULLed via sync trigger.
  UPDATE public.properties SET zone_id = NULL WHERE zone_id = _zone_id;
  GET DIAGNOSTICS _unlinked = ROW_COUNT;

  -- Hard delete the zone row. Audit captures the DELETE.
  DELETE FROM public.zones WHERE id = _zone_id;

  RETURN QUERY SELECT _code, _unlinked;
END $$;


ALTER FUNCTION "public"."zones_hard_delete"("_code" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."zones_hard_delete"("_code" "text") IS 'Hard-delete a zone after unlinking its properties. SECURITY DEFINER to bypass RLS DELETE block. Audit triggers fire under the caller''s role context so app_source attribution is preserved (ADR 016).';



CREATE TABLE IF NOT EXISTS "audit"."logs" (
    "id" bigint NOT NULL,
    "table_schema" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "record_pk" "jsonb" NOT NULL,
    "operation" "text" NOT NULL,
    "old_row" "jsonb",
    "new_row" "jsonb",
    "changed_by" "uuid",
    "db_role" "text" NOT NULL,
    "jwt_claims" "jsonb",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "app_source" "text",
    "request_context" "jsonb",
    CONSTRAINT "logs_operation_check" CHECK (("operation" = ANY (ARRAY['INSERT'::"text", 'UPDATE'::"text", 'DELETE'::"text"])))
)
PARTITION BY RANGE ("changed_at");


ALTER TABLE "audit"."logs" OWNER TO "postgres";


COMMENT ON COLUMN "audit"."logs"."app_source" IS 'Normalized app identifier (per ADR-016). Derived in audit.log_change from X-App-Source header (explicit) or Origin header (derived), else ''sql'' for direct SQL, else ''other:<host>'' for unmapped origins.';



COMMENT ON COLUMN "audit"."logs"."request_context" IS 'Curated subset of PostgREST request metadata (origin, referer, method, path, app_source_hint). Does NOT include Authorization / Cookie / User-Agent — those are PII/token-leak risks inside this table. NULL for direct SQL.';



CREATE TABLE IF NOT EXISTS "audit"."logs_default" (
    "id" bigint NOT NULL,
    "table_schema" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "record_pk" "jsonb" NOT NULL,
    "operation" "text" NOT NULL,
    "old_row" "jsonb",
    "new_row" "jsonb",
    "changed_by" "uuid",
    "db_role" "text" NOT NULL,
    "jwt_claims" "jsonb",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "app_source" "text",
    "request_context" "jsonb",
    CONSTRAINT "logs_operation_check" CHECK (("operation" = ANY (ARRAY['INSERT'::"text", 'UPDATE'::"text", 'DELETE'::"text"])))
);


ALTER TABLE "audit"."logs_default" OWNER TO "postgres";


ALTER TABLE "audit"."logs" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "audit"."logs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "audit"."logs_p20260201" (
    "id" bigint NOT NULL,
    "table_schema" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "record_pk" "jsonb" NOT NULL,
    "operation" "text" NOT NULL,
    "old_row" "jsonb",
    "new_row" "jsonb",
    "changed_by" "uuid",
    "db_role" "text" NOT NULL,
    "jwt_claims" "jsonb",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "app_source" "text",
    "request_context" "jsonb",
    CONSTRAINT "logs_operation_check" CHECK (("operation" = ANY (ARRAY['INSERT'::"text", 'UPDATE'::"text", 'DELETE'::"text"])))
);


ALTER TABLE "audit"."logs_p20260201" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "audit"."logs_p20260301" (
    "id" bigint NOT NULL,
    "table_schema" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "record_pk" "jsonb" NOT NULL,
    "operation" "text" NOT NULL,
    "old_row" "jsonb",
    "new_row" "jsonb",
    "changed_by" "uuid",
    "db_role" "text" NOT NULL,
    "jwt_claims" "jsonb",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "app_source" "text",
    "request_context" "jsonb",
    CONSTRAINT "logs_operation_check" CHECK (("operation" = ANY (ARRAY['INSERT'::"text", 'UPDATE'::"text", 'DELETE'::"text"])))
);


ALTER TABLE "audit"."logs_p20260301" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "audit"."logs_p20260401" (
    "id" bigint NOT NULL,
    "table_schema" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "record_pk" "jsonb" NOT NULL,
    "operation" "text" NOT NULL,
    "old_row" "jsonb",
    "new_row" "jsonb",
    "changed_by" "uuid",
    "db_role" "text" NOT NULL,
    "jwt_claims" "jsonb",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "app_source" "text",
    "request_context" "jsonb",
    CONSTRAINT "logs_operation_check" CHECK (("operation" = ANY (ARRAY['INSERT'::"text", 'UPDATE'::"text", 'DELETE'::"text"])))
);


ALTER TABLE "audit"."logs_p20260401" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "audit"."logs_p20260501" (
    "id" bigint NOT NULL,
    "table_schema" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "record_pk" "jsonb" NOT NULL,
    "operation" "text" NOT NULL,
    "old_row" "jsonb",
    "new_row" "jsonb",
    "changed_by" "uuid",
    "db_role" "text" NOT NULL,
    "jwt_claims" "jsonb",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "app_source" "text",
    "request_context" "jsonb",
    CONSTRAINT "logs_operation_check" CHECK (("operation" = ANY (ARRAY['INSERT'::"text", 'UPDATE'::"text", 'DELETE'::"text"])))
);


ALTER TABLE "audit"."logs_p20260501" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "audit"."logs_p20260601" (
    "id" bigint NOT NULL,
    "table_schema" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "record_pk" "jsonb" NOT NULL,
    "operation" "text" NOT NULL,
    "old_row" "jsonb",
    "new_row" "jsonb",
    "changed_by" "uuid",
    "db_role" "text" NOT NULL,
    "jwt_claims" "jsonb",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "app_source" "text",
    "request_context" "jsonb",
    CONSTRAINT "logs_operation_check" CHECK (("operation" = ANY (ARRAY['INSERT'::"text", 'UPDATE'::"text", 'DELETE'::"text"])))
);


ALTER TABLE "audit"."logs_p20260601" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "audit"."logs_p20260701" (
    "id" bigint NOT NULL,
    "table_schema" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "record_pk" "jsonb" NOT NULL,
    "operation" "text" NOT NULL,
    "old_row" "jsonb",
    "new_row" "jsonb",
    "changed_by" "uuid",
    "db_role" "text" NOT NULL,
    "jwt_claims" "jsonb",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "app_source" "text",
    "request_context" "jsonb",
    CONSTRAINT "logs_operation_check" CHECK (("operation" = ANY (ARRAY['INSERT'::"text", 'UPDATE'::"text", 'DELETE'::"text"])))
);


ALTER TABLE "audit"."logs_p20260701" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "audit"."logs_p20260801" (
    "id" bigint NOT NULL,
    "table_schema" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "record_pk" "jsonb" NOT NULL,
    "operation" "text" NOT NULL,
    "old_row" "jsonb",
    "new_row" "jsonb",
    "changed_by" "uuid",
    "db_role" "text" NOT NULL,
    "jwt_claims" "jsonb",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "app_source" "text",
    "request_context" "jsonb",
    CONSTRAINT "logs_operation_check" CHECK (("operation" = ANY (ARRAY['INSERT'::"text", 'UPDATE'::"text", 'DELETE'::"text"])))
);


ALTER TABLE "audit"."logs_p20260801" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "audit"."logs_p20260901" (
    "id" bigint NOT NULL,
    "table_schema" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "record_pk" "jsonb" NOT NULL,
    "operation" "text" NOT NULL,
    "old_row" "jsonb",
    "new_row" "jsonb",
    "changed_by" "uuid",
    "db_role" "text" NOT NULL,
    "jwt_claims" "jsonb",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "app_source" "text",
    "request_context" "jsonb",
    CONSTRAINT "logs_operation_check" CHECK (("operation" = ANY (ARRAY['INSERT'::"text", 'UPDATE'::"text", 'DELETE'::"text"])))
);


ALTER TABLE "audit"."logs_p20260901" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."photo_links" (
    "id" bigint NOT NULL,
    "photo_id" bigint NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" bigint NOT NULL,
    "role" "text" NOT NULL,
    "caption" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."photo_links" OWNER TO "postgres";


COMMENT ON TABLE "public"."photo_links" IS 'Polymorphic bridge. One photo can link to many entities with different roles. Mirrors entity_source_links pattern. Enforced by convention: entity_id references an id in the table named by entity_type.';



COMMENT ON COLUMN "public"."photo_links"."entity_type" IS 'visit | property | inspection | note | vehicle | expense (future). Controlled vocabulary, documented in docs/schema.md.';



COMMENT ON COLUMN "public"."photo_links"."role" IS 'Per entity_type: visit → before|after|grease_pit|damage|derm_manifest|address|remote|other. property → overview|access|grease_trap_location|manhole|other. inspection → dashboard|cabin|front|back|tires|other. note → attachment. vehicle → general.';



CREATE TABLE IF NOT EXISTS "public"."photos" (
    "id" bigint NOT NULL,
    "storage_path" "text" NOT NULL,
    "thumbnail_path" "text",
    "file_name" "text",
    "content_type" "text",
    "size_bytes" bigint,
    "width_px" integer,
    "height_px" integer,
    "exif_taken_at" timestamp with time zone,
    "exif_latitude" numeric,
    "exif_longitude" numeric,
    "exif_device" "text",
    "uploaded_by_employee_id" bigint,
    "uploaded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "source" "text" DEFAULT 'app'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."photos" OWNER TO "postgres";


COMMENT ON TABLE "public"."photos" IS 'Intrinsic photo record. One row per file in Supabase Storage. 3NF — all columns are direct attributes of the photo PK. Relational attributes (before/after, parent entity) live in photo_links.';



COMMENT ON COLUMN "public"."photos"."exif_taken_at" IS 'Timestamp from photo EXIF data if available — may differ from uploaded_at (e.g. bulk upload days later).';



COMMENT ON COLUMN "public"."photos"."source" IS 'Provenance: app | jobber_migration | fillout_migration | admin. Direct observation at insert time.';



CREATE OR REPLACE VIEW "customer"."client_access_photos" AS
 WITH "resolved" AS (
         SELECT "pl"."id" AS "link_id",
            "pl"."caption",
            "ph"."storage_path",
            "ph"."created_at",
            COALESCE(
                CASE
                    WHEN ("pl"."entity_type" = 'client'::"text") THEN "pl"."entity_id"
                    ELSE NULL::bigint
                END, "p"."client_id") AS "client_id_resolved"
           FROM (("public"."photo_links" "pl"
             JOIN "public"."photos" "ph" ON (("ph"."id" = "pl"."photo_id")))
             LEFT JOIN "public"."properties" "p" ON ((("p"."id" = "pl"."entity_id") AND ("pl"."entity_type" = 'property'::"text"))))
          WHERE ("pl"."entity_type" = ANY (ARRAY['client'::"text", 'property'::"text"]))
        )
 SELECT "customer"."uuid_from_bigint"("link_id") AS "id",
    "customer"."uuid_from_bigint"("client_id_resolved") AS "client_id",
    "customer"."public_url"("storage_path") AS "url",
    "caption",
    (("row_number"() OVER (PARTITION BY "client_id_resolved" ORDER BY "created_at") - 1))::integer AS "position",
    "created_at",
    "customer"."thumbnail_url"("storage_path", 400) AS "thumbnail_url"
   FROM "resolved"
  WHERE ("client_id_resolved" IS NOT NULL);


ALTER VIEW "customer"."client_access_photos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_groups" (
    "id" bigint NOT NULL,
    "name" "text" NOT NULL,
    "notes" "text",
    "status" "text" DEFAULT 'ACTIVE'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "client_groups_status_check" CHECK (("status" = ANY (ARRAY['ACTIVE'::"text", 'INACTIVE'::"text"])))
);


ALTER TABLE "public"."client_groups" OWNER TO "postgres";


COMMENT ON TABLE "public"."client_groups" IS 'Currently unused (0 rows as of 2026-05-18). RLS enabled with zero policies = full lockdown to non-service_role; intentional until a UI surfaces this.';



CREATE TABLE IF NOT EXISTS "public"."clients" (
    "id" bigint NOT NULL,
    "client_code" "text",
    "name" "text" NOT NULL,
    "status" "text",
    "balance" numeric(12,2),
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "group_id" bigint,
    "client_class" "text",
    CONSTRAINT "clients_client_class_check" CHECK ((("client_class" IS NULL) OR ("client_class" = ANY (ARRAY['commercial'::"text", 'residential'::"text"]))))
);

ALTER TABLE ONLY "public"."clients" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."clients" OWNER TO "postgres";


COMMENT ON TABLE "public"."clients" IS 'Canonical client table. ~491 rows merged from Airtable (CRM) + Jobber (billing) + Samsara (geofence). Jobber is source of truth for contact data.';



COMMENT ON COLUMN "public"."clients"."group_id" IS 'Optional FK to client_groups for brand/parent grouping. NULL when the client has no group.';



COMMENT ON COLUMN "public"."clients"."client_class" IS 'Commercial vs Residential. Source of truth: Jobber Client.isCompany (true=commercial, false=residential). Maintained by webhook-jobber + scripts/sync/backfill_clients_class.js. Per project_residential_clients.md rule (2026-05-29 nuance): persist the fact, but ops dashboards default to all-clients views unless explicitly filtering.';



CREATE TABLE IF NOT EXISTS "public"."disposal_facilities" (
    "id" bigint NOT NULL,
    "name" "text" NOT NULL,
    "facility_type" "text" NOT NULL,
    "address" "text",
    "city" "text",
    "state" "text",
    "zip" "text",
    "latitude" numeric,
    "longitude" numeric,
    "status" "text" DEFAULT 'ACTIVE'::"text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "county" "text",
    CONSTRAINT "disposal_facilities_county_check" CHECK ((("county" IS NULL) OR ("county" = ANY (ARRAY['Miami-Dade'::"text", 'Broward'::"text"])))),
    CONSTRAINT "disposal_facilities_facility_type_check" CHECK (("facility_type" = ANY (ARRAY['DERM'::"text", 'WWTP'::"text", 'DUMP'::"text", 'OTHER'::"text"]))),
    CONSTRAINT "disposal_facilities_status_check" CHECK (("status" = ANY (ARRAY['ACTIVE'::"text", 'INACTIVE'::"text"])))
);


ALTER TABLE "public"."disposal_facilities" OWNER TO "postgres";


COMMENT ON TABLE "public"."disposal_facilities" IS 'Canonical lookup for waste disposal facilities (DUMP sites, WWTP plants, etc.). FKd from properties.default_disposal_facility_id and derm_manifests.disposal_facility_id.';



COMMENT ON COLUMN "public"."disposal_facilities"."county" IS 'DERM jurisdiction of the facility: Miami-Dade or Broward (Broward covers Palm Beach). NULL for non-DERM-WWTP facilities (e.g. dump sites). Drives DERM Tracker /upload facility auto-match. Exactly these two string values.';



CREATE TABLE IF NOT EXISTS "public"."gdos" (
    "id" bigint NOT NULL,
    "client_id" bigint NOT NULL,
    "gdo_number" "text" NOT NULL,
    "location_label" "text",
    "property_id" bigint NOT NULL,
    "permit_expiration" "date",
    "permit_document_path" "text",
    "status" "text" DEFAULT 'ACTIVE'::"text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "max_frequency_days" integer,
    "client_location_id" bigint,
    CONSTRAINT "gdos_max_frequency_days_positive" CHECK ((("max_frequency_days" IS NULL) OR ("max_frequency_days" > 0))),
    CONSTRAINT "gdos_status_check" CHECK (("status" = ANY (ARRAY['ACTIVE'::"text", 'EXPIRED'::"text", 'INACTIVE'::"text"])))
);


ALTER TABLE "public"."gdos" OWNER TO "postgres";


COMMENT ON COLUMN "public"."gdos"."max_frequency_days" IS 'City-mandated maximum days between Grease Trap cleanings for this GDO. The negotiated service_configs.frequency_days for the same client must be <= this value or it is a compliance risk. Sourced from AT Clients."GT Frequency" via Phase 2 backfill (GDO Bot + Viktor cross-check). NULL = max not yet captured.';



COMMENT ON COLUMN "public"."gdos"."client_location_id" IS 'The client_location (tenant / service area) this GDO permits. FK -> client_locations(id) ON DELETE SET NULL. NULL until the location is created/matched. Usually 1 GDO : 1 location; a location MAY have >1 GDO (multiple devices).';



CREATE OR REPLACE VIEW "customer"."clients" AS
 SELECT "customer"."uuid_from_bigint"("c"."id") AS "id",
    "lower"("c"."client_code") AS "slug",
    "c"."name",
    "c"."client_code",
    "cg"."name" AS "group_name",
    "p"."address" AS "address1",
    NULLIF(TRIM(BOTH ' ,'::"text" FROM "concat_ws"(', '::"text", NULLIF("p"."city", ''::"text"), NULLIF("concat_ws"(' '::"text", NULLIF("p"."state", ''::"text"), NULLIF("p"."zip", ''::"text")), ''::"text"))), ''::"text") AS "address2",
        CASE
            WHEN ("sc_gt"."equipment_size_gallons" IS NOT NULL) THEN (("sc_gt"."equipment_size_gallons")::"text" || ' gal grease trap'::"text")
            ELSE NULL::"text"
        END AS "container_type",
        CASE
            WHEN ("sc_gt"."equipment_size_gallons" IS NOT NULL) THEN (("sc_gt"."equipment_size_gallons")::"text" || ' gal'::"text")
            ELSE NULL::"text"
        END AS "trap_capacity",
    "sc_gt"."material_type" AS "material",
    "df"."name" AS "disposal_facility",
    ( SELECT "g"."permit_document_path"
           FROM "public"."gdos" "g"
          WHERE (("g"."client_id" = "c"."id") AND ("g"."status" = 'ACTIVE'::"text"))
          ORDER BY "g"."id"
         LIMIT 1) AS "gdo_permit_url",
    "p"."access_notes",
    "c"."created_at",
    "c"."status",
    ("c"."status" = ANY (ARRAY['ACTIVE'::"text", 'RECURRING'::"text"])) AS "is_active"
   FROM (((("public"."clients" "c"
     LEFT JOIN "public"."client_groups" "cg" ON (("cg"."id" = "c"."group_id")))
     LEFT JOIN "public"."properties" "p" ON ((("p"."client_id" = "c"."id") AND ("p"."is_primary" = true))))
     LEFT JOIN "public"."service_configs" "sc_gt" ON ((("sc_gt"."client_id" = "c"."id") AND ("sc_gt"."service_type" = 'GT'::"text"))))
     LEFT JOIN "public"."disposal_facilities" "df" ON (("df"."id" = "p"."default_disposal_facility_id")));


ALTER VIEW "customer"."clients" OWNER TO "postgres";


COMMENT ON VIEW "customer"."clients" IS 'Customer-portal-shaped client row. One row per active client. Slug = lower(client_code) for routing.';



CREATE TABLE IF NOT EXISTS "public"."inspections" (
    "id" bigint NOT NULL,
    "vehicle_id" bigint,
    "employee_id" bigint,
    "shift_date" "date" NOT NULL,
    "inspection_type" "text" NOT NULL,
    "submitted_at" timestamp with time zone,
    "sludge_gallons" integer,
    "water_gallons" integer,
    "gas_level" "text",
    "is_valve_closed" boolean,
    "has_issue" boolean DEFAULT false,
    "issue_note" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);

ALTER TABLE ONLY "public"."inspections" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."inspections" OWNER TO "postgres";


COMMENT ON TABLE "public"."inspections" IS 'Pre/post shift truck inspections. ~480 records. Sludge delta = POST.sludge - PRE.sludge = waste collected.';



CREATE OR REPLACE VIEW "customer"."inspection_items" AS
 WITH "iv" AS (
         SELECT "i"."id",
            "i"."is_valve_closed",
            "i"."has_issue",
            "i"."issue_note",
            ( SELECT "v"."id"
                   FROM "public"."visits" "v"
                  WHERE (("v"."vehicle_id" = "i"."vehicle_id") AND ("v"."visit_date" = "i"."shift_date"))
                  ORDER BY ("v"."visit_status" = 'completed'::"text") DESC, "v"."id"
                 LIMIT 1) AS "visit_id"
           FROM "public"."inspections" "i"
          WHERE ("i"."inspection_type" = 'POST'::"text")
        )
 SELECT "id",
    "work_order_id",
    "label",
    "value",
    "is_positive",
    "position"
   FROM ( SELECT ("md5"(('insp-valve-'::"text" || ("iv"."id")::"text")))::"uuid" AS "id",
            ( SELECT "v"."public_id"
                   FROM "public"."visits" "v"
                  WHERE ("v"."id" = "iv"."visit_id")) AS "work_order_id",
            'Valve closed'::"text" AS "label",
            COALESCE("iv"."is_valve_closed", false) AS "value",
            true AS "is_positive",
            0 AS "position"
           FROM "iv"
          WHERE (("iv"."visit_id" IS NOT NULL) AND ("iv"."is_valve_closed" IS NOT NULL))
        UNION ALL
         SELECT ("md5"(('insp-issue-'::"text" || ("iv"."id")::"text")))::"uuid" AS "md5",
            ( SELECT "v"."public_id"
                   FROM "public"."visits" "v"
                  WHERE ("v"."id" = "iv"."visit_id")) AS "work_order_id",
                CASE
                    WHEN "iv"."has_issue" THEN COALESCE("iv"."issue_note", 'Issue reported'::"text")
                    ELSE 'No issues'::"text"
                END AS "case",
            (NOT COALESCE("iv"."has_issue", false)),
            true,
            1
           FROM "iv"
          WHERE (("iv"."visit_id" IS NOT NULL) AND ("iv"."has_issue" IS NOT NULL))) "sub";


ALTER VIEW "customer"."inspection_items" OWNER TO "postgres";


CREATE OR REPLACE VIEW "customer"."permits" AS
 SELECT "customer"."uuid_from_bigint"("g"."id") AS "id",
    "customer"."uuid_from_bigint"("g"."client_id") AS "client_id",
    "g"."gdo_number" AS "permit_number",
    'Grease Trap'::"text" AS "area",
        CASE
            WHEN ("g"."max_frequency_days" IS NULL) THEN NULL::"text"
            WHEN ("g"."max_frequency_days" <= 35) THEN 'Monthly'::"text"
            WHEN ("g"."max_frequency_days" <= 95) THEN 'Quarterly'::"text"
            WHEN ("g"."max_frequency_days" <= 185) THEN 'Semi-annually'::"text"
            WHEN ("g"."max_frequency_days" <= 380) THEN 'Annually'::"text"
            ELSE (('Every '::"text" || "g"."max_frequency_days") || ' days'::"text")
        END AS "frequency",
    "g"."permit_document_path" AS "permit_url",
    (("row_number"() OVER (PARTITION BY "g"."client_id" ORDER BY "g"."property_id", "g"."gdo_number") - 1))::integer AS "position",
    "customer"."uuid_from_bigint"("g"."property_id") AS "property_id",
    "g"."location_label",
    "g"."permit_expiration",
    "g"."max_frequency_days",
        CASE
            WHEN ("g"."max_frequency_days" IS NULL) THEN NULL::boolean
            ELSE COALESCE(((CURRENT_DATE - ( SELECT "max"("v"."visit_date") AS "max"
               FROM "public"."visits" "v"
              WHERE (("v"."property_id" = "g"."property_id") AND ("v"."visit_status" = 'completed'::"text")))) > "g"."max_frequency_days"), true)
        END AS "over_gdo_max",
    "sc"."frequency_days" AS "our_frequency_days",
        CASE
            WHEN (("sc"."frequency_days" IS NULL) OR ("g"."max_frequency_days" IS NULL)) THEN NULL::boolean
            ELSE ("sc"."frequency_days" <= "g"."max_frequency_days")
        END AS "compliant"
   FROM (("public"."gdos" "g"
     JOIN "public"."clients" "c" ON (("c"."id" = "g"."client_id")))
     LEFT JOIN LATERAL ( SELECT "s"."frequency_days"
           FROM "public"."service_configs" "s"
          WHERE (("s"."property_id" = "g"."property_id") AND ("s"."service_type" = 'GT'::"text") AND ("s"."frequency_days" IS NOT NULL))
          ORDER BY "s"."id"
         LIMIT 1) "sc" ON (true))
  WHERE (("g"."status" = 'ACTIVE'::"text") AND ("c"."status" = ANY (ARRAY['ACTIVE'::"text", 'RECURRING'::"text"])));


ALTER VIEW "customer"."permits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."visit_recommendations" (
    "id" bigint NOT NULL,
    "visit_id" bigint NOT NULL,
    "label" "text" NOT NULL,
    "is_needed" boolean DEFAULT false NOT NULL,
    "position" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."visit_recommendations" OWNER TO "postgres";


COMMENT ON TABLE "public"."visit_recommendations" IS 'Currently unused (0 rows as of 2026-05-18). RLS enabled with zero policies = full lockdown to non-service_role; intentional until a UI surfaces this.';



CREATE OR REPLACE VIEW "customer"."recommendations" AS
 SELECT "customer"."uuid_from_bigint"("vr"."id") AS "id",
    "v"."public_id" AS "work_order_id",
    "vr"."label",
    "vr"."is_needed" AS "needed",
    "vr"."position"
   FROM ("public"."visit_recommendations" "vr"
     JOIN "public"."visits" "v" ON (("v"."id" = "vr"."visit_id")));


ALTER VIEW "customer"."recommendations" OWNER TO "postgres";


CREATE OR REPLACE VIEW "customer"."scheduled_visits" AS
 SELECT "public_id" AS "id",
    "customer"."uuid_from_bigint"("client_id") AS "client_id",
    "visit_date" AS "scheduled_date",
    NULL::"text" AS "scheduled_window",
    "service_type",
    "title" AS "notes",
    "visit_status" AS "status",
    "created_at"
   FROM "public"."visits" "v"
  WHERE (("visit_status" = 'scheduled'::"text") AND ("client_id" IS NOT NULL) AND ("deleted_at" IS NULL));


ALTER VIEW "customer"."scheduled_visits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."photo_classifications" (
    "photo_link_id" bigint NOT NULL,
    "service_phase" "text" NOT NULL,
    "classified_by_user_id" "uuid",
    "quality_flag" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "id" bigint NOT NULL,
    CONSTRAINT "photo_classifications_service_phase_check" CHECK (("service_phase" = ANY (ARRAY['before'::"text", 'after'::"text", 'internal'::"text", 'extra'::"text", 'unknown'::"text"])))
);


ALTER TABLE "public"."photo_classifications" OWNER TO "postgres";


COMMENT ON TABLE "public"."photo_classifications" IS 'Human-classified service phase per photo_links row (1:1 with photo_links.id). Source: Yannick''s Admin Review App via dual-write to Prod + Sandbox #1. See migration 2026-05-14d and docs/audits/2026-05-14_photo_classifications_audit.md.';



COMMENT ON COLUMN "public"."photo_classifications"."photo_link_id" IS 'Identifies the canonical photo_link this classification applies to. PK + FK to photo_links(id) ON DELETE CASCADE.';



COMMENT ON COLUMN "public"."photo_classifications"."service_phase" IS 'Enum: before | after | internal | extra | unknown. Renamed 2026-05-15 (was completion -> internal; added extra). The Admin Review App''s 4 user-facing buttons map to before/after/internal/extra; ''unknown'' is the fallback when an explicit phase isn''t selected. CHECK constraint mirrors the TS PhotoClassification union.';



COMMENT ON COLUMN "public"."photo_classifications"."classified_by_user_id" IS 'auth.users id of the human who classified this photo. NULL when written by the anon role (current state — Admin Review App has no login flow yet). Will populate once auth ships.';



COMMENT ON COLUMN "public"."photo_classifications"."quality_flag" IS 'Free-text quality marker (forward-compat — e.g. ''blurry'', ''dark'', ''reshoot needed''). Zero values written today; reserved for Yannick''s future flag-photo UI. Add a CHECK constraint when the value set stabilizes.';



COMMENT ON COLUMN "public"."photo_classifications"."notes" IS 'Free-text classifier notes (forward-compat). Zero values written today.';



COMMENT ON COLUMN "public"."photo_classifications"."created_at" IS 'Timestamp of the first classification of this photo_link (UTC).';



COMMENT ON COLUMN "public"."photo_classifications"."updated_at" IS 'Auto-bumped to now() on every UPDATE by the photo_classifications_set_updated_at trigger. Never set manually.';



COMMENT ON COLUMN "public"."photo_classifications"."id" IS 'Surrogate identity column added 2026-05-15 because Lovable''s auto-generated supabase-js types reference .id on every row. NOT the primary key — photo_link_id is. Don''t write SQL keyed on this column; use photo_link_id for joins/lookups. Indexed UNIQUE for completeness.';



CREATE OR REPLACE VIEW "customer"."wo_photos" AS
 SELECT "customer"."uuid_from_bigint"("pl"."id") AS "id",
    "v"."public_id" AS "work_order_id",
    "pc"."service_phase" AS "variant",
    "customer"."public_url"("ph"."storage_path") AS "url",
    "pl"."caption",
    (("row_number"() OVER (PARTITION BY "pl"."entity_id" ORDER BY "ph"."created_at") - 1))::integer AS "position",
    "customer"."thumbnail_url"("ph"."storage_path", 400) AS "thumbnail_url"
   FROM ((("public"."photo_links" "pl"
     JOIN "public"."photos" "ph" ON (("ph"."id" = "pl"."photo_id")))
     JOIN "public"."photo_classifications" "pc" ON (("pc"."photo_link_id" = "pl"."id")))
     JOIN "public"."visits" "v" ON (("v"."id" = "pl"."entity_id")))
  WHERE (("pl"."entity_type" = 'visit'::"text") AND ("pc"."service_phase" = ANY (ARRAY['before'::"text", 'after'::"text", 'extra'::"text"])));


ALTER VIEW "customer"."wo_photos" OWNER TO "postgres";


CREATE OR REPLACE VIEW "derm"."disposal_facilities" AS
 SELECT "id",
    "name",
    "facility_type",
    "latitude",
    "longitude",
    "county"
   FROM "public"."disposal_facilities"
  WHERE ("status" = 'ACTIVE'::"text");


ALTER VIEW "derm"."disposal_facilities" OWNER TO "postgres";


CREATE OR REPLACE VIEW "derm"."gdos" AS
 SELECT "g"."id",
    "g"."client_id",
        CASE
            WHEN (("c"."client_code" IS NOT NULL) AND ("c"."name" !~~ ("c"."client_code" || '%'::"text"))) THEN (("c"."client_code" || ' '::"text") || "c"."name")
            ELSE "c"."name"
        END AS "client_name",
    "g"."gdo_number",
    "g"."location_label",
    "g"."property_id",
    ("g"."permit_expiration")::"text" AS "permit_expiration",
    "g"."permit_document_path",
    "g"."status",
    "g"."notes",
    ("g"."created_at")::"text" AS "created_at",
    ("g"."updated_at")::"text" AS "updated_at",
    ( SELECT "count"(*) AS "count"
           FROM "public"."derm_manifests" "dm"
          WHERE ("dm"."gdo_id" = "g"."id")) AS "manifest_count"
   FROM ("public"."gdos" "g"
     JOIN "public"."clients" "c" ON (("c"."id" = "g"."client_id")));


ALTER VIEW "derm"."gdos" OWNER TO "postgres";


CREATE OR REPLACE VIEW "derm"."manifest_health" AS
 SELECT "dm"."id",
    "dm"."client_id",
    "c"."name" AS "client_name",
    "dm"."white_manifest_number",
    "dm"."yellow_ticket_number",
    ("dm"."service_date")::"text" AS "service_date",
    ("dm"."dump_ticket_date")::"text" AS "dump_ticket_date",
    "dm"."disposal_facility_id",
    "df"."name" AS "dump_location",
    "dm"."derm_manifest_url" AS "manifest_photo_url",
    "dm"."derm_address_url" AS "address_photo_url",
    ("dm"."created_at")::"text" AS "created_at",
    ("dm"."updated_at")::"text" AS "updated_at",
        CASE
            WHEN ("dm"."yellow_ticket_number" IS NOT NULL) THEN 'broward'::"text"
            WHEN (("dm"."white_manifest_number" IS NOT NULL) AND ("length"("dm"."white_manifest_number") >= 5)) THEN 'dade'::"text"
            ELSE 'unknown'::"text"
        END AS "jurisdiction",
    ("dm"."white_manifest_number" IS NOT NULL) AS "has_dade_white_number",
    ("dm"."yellow_ticket_number" IS NOT NULL) AS "has_broward_ticket_number",
    ("dm"."derm_manifest_url" IS NOT NULL) AS "has_manifest_pdf",
    ("dm"."derm_address_url" IS NOT NULL) AS "has_address_pdf",
    (("dm"."derm_manifest_url" IS NOT NULL) OR ("dm"."derm_address_url" IS NOT NULL)) AS "has_any_pdf",
    ("dm"."dump_ticket_date" IS NOT NULL) AS "has_dump_date",
    ("dm"."disposal_facility_id" IS NOT NULL) AS "has_dump_site",
    ("dm"."client_id" IS NOT NULL) AS "has_client",
    ("dm"."sent_to_client" IS TRUE) AS "sent_to_client",
    ("dm"."sent_to_city" IS TRUE) AS "sent_to_city",
        CASE
            WHEN (("dm"."white_manifest_number" IS NULL) AND ("dm"."yellow_ticket_number" IS NULL) AND ("dm"."derm_manifest_url" IS NULL) AND ("dm"."derm_address_url" IS NULL) AND ("dm"."dump_ticket_date" IS NULL)) THEN 'empty_placeholder'::"text"
            WHEN (("dm"."yellow_ticket_number" IS NOT NULL) AND ("dm"."derm_manifest_url" IS NOT NULL) AND ("dm"."derm_address_url" IS NOT NULL) AND ("dm"."dump_ticket_date" IS NOT NULL)) THEN 'fully_complete'::"text"
            WHEN (("dm"."white_manifest_number" IS NOT NULL) AND ("length"("dm"."white_manifest_number") >= 5) AND ("dm"."derm_manifest_url" IS NOT NULL) AND ("dm"."derm_address_url" IS NOT NULL) AND ("dm"."dump_ticket_date" IS NOT NULL)) THEN 'fully_complete'::"text"
            WHEN ((("dm"."derm_manifest_url" IS NOT NULL) OR ("dm"."derm_address_url" IS NOT NULL)) AND ("dm"."yellow_ticket_number" IS NULL) AND ("dm"."white_manifest_number" IS NULL)) THEN 'has_pdfs_no_number'::"text"
            WHEN ((("dm"."yellow_ticket_number" IS NOT NULL) OR ("dm"."white_manifest_number" IS NOT NULL)) AND ("dm"."derm_manifest_url" IS NULL) AND ("dm"."derm_address_url" IS NULL)) THEN 'has_number_no_pdfs'::"text"
            ELSE 'partial_other'::"text"
        END AS "health_state",
        CASE
            WHEN (("dm"."white_manifest_number" IS NULL) AND ("dm"."yellow_ticket_number" IS NULL) AND ("dm"."derm_manifest_url" IS NULL) AND ("dm"."derm_address_url" IS NULL)) THEN 'P0'::"text"
            WHEN ((("dm"."yellow_ticket_number" IS NULL) AND ("dm"."white_manifest_number" IS NULL)) OR ("dm"."derm_manifest_url" IS NULL) OR ("dm"."derm_address_url" IS NULL) OR ("dm"."dump_ticket_date" IS NULL)) THEN 'P1'::"text"
            WHEN ((NOT "dm"."sent_to_client") OR (NOT "dm"."sent_to_city")) THEN 'P2'::"text"
            ELSE 'OK'::"text"
        END AS "severity",
    "dm"."notes",
    "dm"."derm_address_no"
   FROM (("public"."derm_manifests" "dm"
     LEFT JOIN "public"."clients" "c" ON (("c"."id" = "dm"."client_id")))
     LEFT JOIN "public"."disposal_facilities" "df" ON (("df"."id" = "dm"."disposal_facility_id")))
  WHERE ("dm"."deleted_at" IS NULL);


ALTER VIEW "derm"."manifest_health" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."derm_manifest_number_proposals" (
    "id" bigint NOT NULL,
    "manifest_id" bigint NOT NULL,
    "proposed_number" "text",
    "confidence" "text",
    "source" "text" DEFAULT 'claude_vision'::"text" NOT NULL,
    "source_image_url" "text",
    "raw_response" "text",
    "review_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "derm_manifest_number_proposals_confidence_check" CHECK (("confidence" = ANY (ARRAY['high'::"text", 'medium'::"text", 'low'::"text", 'unknown'::"text"]))),
    CONSTRAINT "derm_manifest_number_proposals_review_status_check" CHECK (("review_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'superseded'::"text"])))
);


ALTER TABLE "public"."derm_manifest_number_proposals" OWNER TO "postgres";


CREATE OR REPLACE VIEW "derm"."manifest_number_proposals" AS
 SELECT "p"."id",
    "p"."manifest_id",
    "p"."proposed_number",
    "p"."confidence",
    "p"."source",
    "p"."source_image_url",
    "p"."review_status",
    "p"."notes",
    ("p"."created_at")::"text" AS "created_at",
    ("p"."updated_at")::"text" AS "updated_at",
    "dm"."white_manifest_number" AS "current_value",
    "dm"."derm_manifest_url" AS "manifest_photo_url",
    "c"."name" AS "client_name",
    ("dm"."service_date")::"text" AS "service_date"
   FROM (("public"."derm_manifest_number_proposals" "p"
     JOIN "public"."derm_manifests" "dm" ON (("dm"."id" = "p"."manifest_id")))
     LEFT JOIN "public"."clients" "c" ON (("c"."id" = "dm"."client_id")));


ALTER VIEW "derm"."manifest_number_proposals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."derm_email_sends" (
    "id" bigint NOT NULL,
    "manifest_id" bigint NOT NULL,
    "client_id" bigint NOT NULL,
    "recipient_email" "text",
    "resend_email_id" "text",
    "status" "text" NOT NULL,
    "reason" "text",
    "is_test" boolean DEFAULT false NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "recipient_type" "text" DEFAULT 'client'::"text" NOT NULL,
    CONSTRAINT "derm_email_sends_recipient_type_check" CHECK (("recipient_type" = ANY (ARRAY['client'::"text", 'city'::"text"]))),
    CONSTRAINT "derm_email_sends_status_check" CHECK (("status" = ANY (ARRAY['sent'::"text", 'skipped'::"text", 'error'::"text"])))
);


ALTER TABLE "public"."derm_email_sends" OWNER TO "postgres";


COMMENT ON TABLE "public"."derm_email_sends" IS 'Append-only log of "Send DERM to client" email attempts (one row per (manifest,client) attempt), written by the send-derm-email Edge Function. "Emailed" = latest row with status=sent AND is_test=false.';



CREATE TABLE IF NOT EXISTS "public"."municipality_regulators" (
    "id" bigint NOT NULL,
    "municipality" "text" NOT NULL,
    "state" "text" DEFAULT 'FL'::"text" NOT NULL,
    "county" "text",
    "emails" "text"[] NOT NULL,
    "status" "text" DEFAULT 'ACTIVE'::"text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."municipality_regulators" OWNER TO "postgres";


COMMENT ON TABLE "public"."municipality_regulators" IS 'One row per municipality with a FOG/grease manifest-submission program; holds the regulator email(s). Matched to a manifest via the served location''s property.city. Recipient source for the "Send DERM to City" send.';



CREATE OR REPLACE VIEW "derm"."manifests" AS
 SELECT "id",
    "manifest_number",
    "manifest_type",
    "manifest_photo_url",
    "address_photo_url",
    "dump_date",
    "dump_location",
    "driver_name",
    "gallons",
    "created_at",
    "client_id",
    "client_name",
    "service_date",
    "yellow_ticket_number",
    "wwtp_receipt_number",
    "wwtp_receipt_document_path",
    "wwtp_ticket_number",
    "disposal_facility_id",
    "sent_to_client",
    "sent_to_city",
    "updated_at",
    "jurisdiction",
    "display_number",
    "display_label",
    "notes",
    "derm_address_no",
    "emailed_client_count",
    "total_client_count",
    ( SELECT "count"(DISTINCT "es"."client_id") AS "count"
           FROM "public"."derm_email_sends" "es"
          WHERE (("es"."manifest_id" = "w"."id") AND ("es"."recipient_type" = 'city'::"text") AND ("es"."status" = 'sent'::"text") AND ("es"."is_test" = false))) AS "city_emailed_count",
    ( SELECT "count"(DISTINCT "vv"."client_id") AS "count"
           FROM ("public"."manifest_visits" "mv"
             JOIN "public"."visits" "vv" ON ((("vv"."id" = "mv"."visit_id") AND ("vv"."deleted_at" IS NULL))))
          WHERE (("mv"."manifest_id" = "w"."id") AND (EXISTS ( SELECT 1
                   FROM ("public"."properties" "p"
                     JOIN "public"."municipality_regulators" "mr" ON ((("lower"("btrim"("mr"."municipality")) = "lower"("btrim"("p"."city"))) AND ("mr"."status" = 'ACTIVE'::"text"))))
                  WHERE ("p"."client_id" = "vv"."client_id"))))) AS "city_total_count"
   FROM ( SELECT "sub"."id",
            "sub"."manifest_number",
            "sub"."manifest_type",
            "sub"."manifest_photo_url",
            "sub"."address_photo_url",
            "sub"."dump_date",
            "sub"."dump_location",
            "sub"."driver_name",
            "sub"."gallons",
            "sub"."created_at",
            "sub"."client_id",
            "sub"."client_name",
            "sub"."service_date",
            "sub"."yellow_ticket_number",
            "sub"."wwtp_receipt_number",
            "sub"."wwtp_receipt_document_path",
            "sub"."wwtp_ticket_number",
            "sub"."disposal_facility_id",
            "sub"."sent_to_client",
            "sub"."sent_to_city",
            "sub"."updated_at",
            "sub"."jurisdiction",
            "sub"."display_number",
            "sub"."display_label",
            "sub"."notes",
            "sub"."derm_address_no",
            ( SELECT "count"(DISTINCT "es"."client_id") AS "count"
                   FROM "public"."derm_email_sends" "es"
                  WHERE (("es"."manifest_id" = "sub"."id") AND ("es"."status" = 'sent'::"text") AND ("es"."is_test" = false))) AS "emailed_client_count",
            ( SELECT "count"(DISTINCT "v"."client_id") AS "count"
                   FROM ("public"."manifest_visits" "mv"
                     JOIN "public"."visits" "v" ON (("v"."id" = "mv"."visit_id")))
                  WHERE (("mv"."manifest_id" = "sub"."id") AND ("v"."deleted_at" IS NULL) AND ("v"."client_id" IS NOT NULL))) AS "total_client_count"
           FROM ( SELECT "dm"."id",
                    "dm"."white_manifest_number" AS "manifest_number",
                    'WHITE'::"text" AS "manifest_type",
                    "dm"."derm_manifest_url" AS "manifest_photo_url",
                    "dm"."derm_address_url" AS "address_photo_url",
                    ("dm"."dump_ticket_date")::"text" AS "dump_date",
                    "df"."name" AS "dump_location",
                    NULL::"text" AS "driver_name",
                    NULL::numeric AS "gallons",
                    ("dm"."created_at")::"text" AS "created_at",
                    "dm"."client_id",
                        CASE
                            WHEN (("c"."client_code" IS NOT NULL) AND ("c"."name" !~~ ("c"."client_code" || '%'::"text"))) THEN (("c"."client_code" || ' '::"text") || "c"."name")
                            ELSE "c"."name"
                        END AS "client_name",
                    ("dm"."service_date")::"text" AS "service_date",
                    "dm"."yellow_ticket_number",
                    "dm"."wwtp_receipt_number",
                    "dm"."wwtp_receipt_document_path",
                    "dm"."wwtp_ticket_number",
                    "dm"."disposal_facility_id",
                    "dm"."sent_to_client",
                    "dm"."sent_to_city",
                    ("dm"."updated_at")::"text" AS "updated_at",
                        CASE
                            WHEN ("dm"."yellow_ticket_number" IS NOT NULL) THEN 'broward'::"text"
                            WHEN (("dm"."white_manifest_number" IS NOT NULL) AND ("length"("dm"."white_manifest_number") >= 5)) THEN 'dade'::"text"
                            ELSE 'unknown'::"text"
                        END AS "jurisdiction",
                    COALESCE(
                        CASE
                            WHEN ("dm"."yellow_ticket_number" IS NOT NULL) THEN "dm"."yellow_ticket_number"
                            ELSE NULL::"text"
                        END,
                        CASE
                            WHEN (("dm"."white_manifest_number" IS NOT NULL) AND ("length"("dm"."white_manifest_number") >= 5)) THEN "dm"."white_manifest_number"
                            ELSE NULL::"text"
                        END) AS "display_number",
                        CASE
                            WHEN ("dm"."yellow_ticket_number" IS NOT NULL) THEN ('Broward #'::"text" || "dm"."yellow_ticket_number")
                            WHEN (("dm"."white_manifest_number" IS NOT NULL) AND ("length"("dm"."white_manifest_number") >= 5)) THEN ('Miami-Dade #'::"text" || "dm"."white_manifest_number")
                            ELSE 'Pending paperwork'::"text"
                        END AS "display_label",
                    "dm"."notes",
                    "dm"."derm_address_no"
                   FROM (("public"."derm_manifests" "dm"
                     LEFT JOIN "public"."clients" "c" ON (("c"."id" = "dm"."client_id")))
                     LEFT JOIN "public"."disposal_facilities" "df" ON (("df"."id" = "dm"."disposal_facility_id")))
                  WHERE ("dm"."deleted_at" IS NULL)) "sub") "w";


ALTER VIEW "derm"."manifests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_contacts" (
    "id" bigint NOT NULL,
    "client_id" bigint NOT NULL,
    "contact_role" "text" NOT NULL,
    "name" "text",
    "email" "text",
    "phone" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);

ALTER TABLE ONLY "public"."client_contacts" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_contacts" OWNER TO "postgres";


CREATE OR REPLACE VIEW "derm"."manifest_recipients" AS
 SELECT "manifest_id",
    "display_number",
    "display_label",
    "jurisdiction",
    "client_id",
    "client_name",
    "has_pdf",
    "has_email",
    "visit_date",
    "last_emailed_at",
    (EXISTS ( SELECT 1
           FROM ("public"."properties" "p"
             JOIN "public"."municipality_regulators" "mr" ON ((("lower"("btrim"("mr"."municipality")) = "lower"("btrim"("p"."city"))) AND ("mr"."status" = 'ACTIVE'::"text"))))
          WHERE ("p"."client_id" = "w"."client_id"))) AS "has_city_email",
    ( SELECT "string_agg"(DISTINCT "mr"."municipality", ', '::"text") AS "string_agg"
           FROM ("public"."properties" "p"
             JOIN "public"."municipality_regulators" "mr" ON ((("lower"("btrim"("mr"."municipality")) = "lower"("btrim"("p"."city"))) AND ("mr"."status" = 'ACTIVE'::"text"))))
          WHERE ("p"."client_id" = "w"."client_id")) AS "municipality",
    ( SELECT "max"("es"."sent_at") AS "max"
           FROM "public"."derm_email_sends" "es"
          WHERE (("es"."manifest_id" = "w"."manifest_id") AND ("es"."client_id" = "w"."client_id") AND ("es"."recipient_type" = 'city'::"text") AND ("es"."status" = 'sent'::"text") AND ("es"."is_test" = false))) AS "city_last_emailed_at"
   FROM ( SELECT "sub"."manifest_id",
            "sub"."display_number",
            "sub"."display_label",
            "sub"."jurisdiction",
            "sub"."client_id",
            "sub"."client_name",
            "sub"."has_pdf",
            "sub"."has_email",
            "sub"."visit_date",
            ( SELECT "max"("es"."sent_at") AS "max"
                   FROM "public"."derm_email_sends" "es"
                  WHERE (("es"."manifest_id" = "sub"."manifest_id") AND ("es"."client_id" = "sub"."client_id") AND ("es"."status" = 'sent'::"text") AND ("es"."is_test" = false))) AS "last_emailed_at"
           FROM ( SELECT "m"."id" AS "manifest_id",
                    "m"."display_number",
                    "m"."display_label",
                    "m"."jurisdiction",
                    "r"."client_id",
                        CASE
                            WHEN (("cl"."client_code" IS NOT NULL) AND ("cl"."client_code" <> ''::"text")) THEN (("cl"."client_code" || ' '::"text") || "cl"."name")
                            ELSE "cl"."name"
                        END AS "client_name",
                    ("m"."manifest_photo_url" IS NOT NULL) AS "has_pdf",
                    (EXISTS ( SELECT 1
                           FROM "public"."client_contacts" "cc"
                          WHERE (("cc"."client_id" = "r"."client_id") AND ("cc"."email" IS NOT NULL) AND ("cc"."email" <> ''::"text")))) AS "has_email",
                    ( SELECT "max"("v"."visit_date") AS "max"
                           FROM ("public"."manifest_visits" "mv"
                             JOIN "public"."visits" "v" ON (("v"."id" = "mv"."visit_id")))
                          WHERE (("mv"."manifest_id" = "m"."id") AND ("v"."client_id" = "r"."client_id") AND ("v"."deleted_at" IS NULL))) AS "visit_date"
                   FROM (("derm"."manifests" "m"
                     JOIN LATERAL ( SELECT DISTINCT "v"."client_id"
                           FROM ("public"."manifest_visits" "mv"
                             JOIN "public"."visits" "v" ON (("v"."id" = "mv"."visit_id")))
                          WHERE (("mv"."manifest_id" = "m"."id") AND ("v"."deleted_at" IS NULL) AND ("v"."client_id" IS NOT NULL))) "r" ON (true))
                     JOIN "public"."clients" "cl" ON (("cl"."id" = "r"."client_id")))) "sub") "w";


ALTER VIEW "derm"."manifest_recipients" OWNER TO "postgres";


CREATE OR REPLACE VIEW "derm"."manifest_visits" AS
 SELECT "mv"."manifest_id",
    "mv"."visit_id",
    ("v"."visit_date")::"text" AS "visit_date",
    "v"."client_id",
        CASE
            WHEN (("c"."client_code" IS NOT NULL) AND ("c"."name" !~~ ("c"."client_code" || '%'::"text"))) THEN (("c"."client_code" || ' '::"text") || "c"."name")
            ELSE "c"."name"
        END AS "client_name",
    COALESCE("p"."address", ''::"text") AS "address",
    COALESCE("p"."county", ''::"text") AS "county"
   FROM ((("public"."manifest_visits" "mv"
     JOIN "public"."visits" "v" ON (("v"."id" = "mv"."visit_id")))
     JOIN "public"."clients" "c" ON (("c"."id" = "v"."client_id")))
     LEFT JOIN LATERAL ( SELECT "p2"."address",
            "p2"."county"
           FROM "public"."properties" "p2"
          WHERE (("p2"."client_id" = "c"."id") AND ("p2"."is_billing" = false))
          ORDER BY "p2"."id"
         LIMIT 1) "p" ON (true))
  WHERE (EXISTS ( SELECT 1
           FROM "public"."derm_manifests" "dm"
          WHERE (("dm"."id" = "mv"."manifest_id") AND ("dm"."deleted_at" IS NULL))));


ALTER VIEW "derm"."manifest_visits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."jobs" (
    "id" bigint NOT NULL,
    "client_id" bigint,
    "property_id" bigint,
    "job_number" "text",
    "title" "text",
    "job_status" "text",
    "start_at" timestamp with time zone,
    "end_at" timestamp with time zone,
    "total" numeric(12,2),
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "quote_id" bigint,
    "notes" "text",
    "frequency_days" integer
);

ALTER TABLE ONLY "public"."jobs" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."jobs" OWNER TO "postgres";


COMMENT ON TABLE "public"."jobs" IS 'Work orders from Jobber (507). Recurring GT/CL services + one-off emergency/hydrojet calls.';



COMMENT ON COLUMN "public"."jobs"."frequency_days" IS 'Recurring service interval in days, synced from the Jobber job''s "Frequency" numeric custom field. NULL or 0 = not a generating service agreement. Drives Calendar-app visit generation; the Calendar app is the source of truth for visits (Jobber decoupled).';



CREATE TABLE IF NOT EXISTS "public"."line_items" (
    "id" bigint NOT NULL,
    "job_id" bigint,
    "quote_id" bigint,
    "name" "text",
    "description" "text",
    "quantity" numeric(10,2),
    "unit_price" numeric(12,2),
    "total_price" numeric(12,2),
    "taxable" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "invoice_id" bigint,
    "visit_id" bigint,
    CONSTRAINT "line_items_at_least_one_scope_chk" CHECK ((("job_id" IS NOT NULL) OR ("invoice_id" IS NOT NULL) OR ("quote_id" IS NOT NULL) OR ("visit_id" IS NOT NULL)))
);

ALTER TABLE ONLY "public"."line_items" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."line_items" OWNER TO "postgres";


COMMENT ON TABLE "public"."line_items" IS 'Line items from Jobber across three scopes: job (planning), invoice (billed), quote (proposed). Exactly one of (job_id, invoice_id, quote_id) is set per row. To compare planned-vs-billed for the same work, query both sides separately and join at read time.';



COMMENT ON COLUMN "public"."line_items"."job_id" IS 'Set when this row represents a JOB line item (planning/template on the job). For the same physical service, the job line items and the invoice line items can diverge — billing can be edited independently after the job is created.';



COMMENT ON COLUMN "public"."line_items"."quote_id" IS 'Set when this row represents a QUOTE line item (a proposed bill that may or may not become an invoice).';



COMMENT ON COLUMN "public"."line_items"."invoice_id" IS 'Set when this row represents an INVOICE line item (what was actually billed to the customer). Jobber distinguishes invoice line items from job line items — billing can be edited independently of the job plan, so the two often diverge. For a single invoice, query SELECT * FROM line_items WHERE invoice_id = X.';



CREATE OR REPLACE VIEW "derm"."visits" AS
 SELECT "id",
    "client_name",
    "address",
    "county",
    "visit_date",
    "technician",
    "notes",
    "created_at",
    "client_id",
    "service_type",
    "has_manifest",
    "derm_required",
    "needs_manifest",
    "line_items",
    "line_items_json",
    "gdo_number",
    "job_number",
    "last_emailed_at",
    ( SELECT "max"("es"."sent_at") AS "max"
           FROM ("public"."manifest_visits" "mv"
             JOIN "public"."derm_email_sends" "es" ON (("es"."manifest_id" = "mv"."manifest_id")))
          WHERE (("mv"."visit_id" = "w"."id") AND ("es"."client_id" = "w"."client_id") AND ("es"."recipient_type" = 'city'::"text") AND ("es"."status" = 'sent'::"text") AND ("es"."is_test" = false))) AS "city_last_emailed_at"
   FROM ( SELECT "sub"."id",
            "sub"."client_name",
            "sub"."address",
            "sub"."county",
            "sub"."visit_date",
            "sub"."technician",
            "sub"."notes",
            "sub"."created_at",
            "sub"."client_id",
            "sub"."service_type",
            "sub"."has_manifest",
            "sub"."derm_required",
            "sub"."needs_manifest",
            "sub"."line_items",
            "sub"."line_items_json",
            "sub"."gdo_number",
            "sub"."job_number",
            ( SELECT "max"("es"."sent_at") AS "max"
                   FROM ("public"."manifest_visits" "mv"
                     JOIN "public"."derm_email_sends" "es" ON (("es"."manifest_id" = "mv"."manifest_id")))
                  WHERE (("mv"."visit_id" = "sub"."id") AND ("es"."client_id" = "sub"."client_id") AND ("es"."status" = 'sent'::"text") AND ("es"."is_test" = false))) AS "last_emailed_at"
           FROM ( SELECT "v"."id",
                        CASE
                            WHEN (("c"."client_code" IS NOT NULL) AND ("c"."name" !~~ ("c"."client_code" || '%'::"text"))) THEN (("c"."client_code" || ' '::"text") || "c"."name")
                            ELSE "c"."name"
                        END AS "client_name",
                    COALESCE("p"."address", ''::"text") AS "address",
                    COALESCE("p"."county", ''::"text") AS "county",
                    ("v"."visit_date")::"text" AS "visit_date",
                    NULL::"text" AS "technician",
                    NULL::"text" AS "notes",
                    ("v"."created_at")::"text" AS "created_at",
                    "v"."client_id",
                    "v"."service_type",
                    (EXISTS ( SELECT 1
                           FROM ("public"."manifest_visits" "mv"
                             JOIN "public"."derm_manifests" "dm" ON (("dm"."id" = "mv"."manifest_id")))
                          WHERE (("mv"."visit_id" = "v"."id") AND ("dm"."deleted_at" IS NULL) AND (("dm"."derm_manifest_url" IS NOT NULL) OR ("dm"."derm_address_url" IS NOT NULL))))) AS "has_manifest",
                    "v"."derm_required",
                    COALESCE("v"."derm_required", true) AS "needs_manifest",
                    COALESCE(( SELECT ((NULLIF(TRIM(BOTH FROM "j"."title"), ''::"text") || ' - '::"text") || ( SELECT "string_agg"("li"."name", ', '::"text" ORDER BY "li"."id") AS "string_agg"
                                   FROM "public"."line_items" "li"
                                  WHERE (("li"."invoice_id" = "v"."invoice_id") AND ("li"."name" IS NOT NULL) AND (NOT (("li"."name" ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::"text") AND ("li"."name" ~* '(fee|fees|%)'::"text"))) AND ("li"."name" !~* '^\s*tax\s*$'::"text"))))
                           FROM "public"."jobs" "j"
                          WHERE (("j"."id" = "v"."job_id") AND ("j"."title" IS NOT NULL) AND (TRIM(BOTH FROM "j"."title") <> ''::"text") AND (EXISTS ( SELECT 1
                                   FROM "public"."line_items" "li"
                                  WHERE (("li"."invoice_id" = "v"."invoice_id") AND ("li"."name" IS NOT NULL) AND (NOT (("li"."name" ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::"text") AND ("li"."name" ~* '(fee|fees|%)'::"text"))) AND ("li"."name" !~* '^\s*tax\s*$'::"text")))))), ( SELECT "string_agg"("li"."name", ', '::"text" ORDER BY "li"."id") AS "string_agg"
                           FROM "public"."line_items" "li"
                          WHERE (("li"."invoice_id" = "v"."invoice_id") AND ("li"."name" IS NOT NULL) AND (NOT (("li"."name" ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::"text") AND ("li"."name" ~* '(fee|fees|%)'::"text"))) AND ("li"."name" !~* '^\s*tax\s*$'::"text"))), ( SELECT ((NULLIF(TRIM(BOTH FROM "j"."title"), ''::"text") || ' - '::"text") || ( SELECT "string_agg"("li"."name", ', '::"text" ORDER BY "li"."id") AS "string_agg"
                                   FROM "public"."line_items" "li"
                                  WHERE (("li"."job_id" = "v"."job_id") AND ("li"."invoice_id" IS NULL) AND ("li"."name" IS NOT NULL) AND (NOT (("li"."name" ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::"text") AND ("li"."name" ~* '(fee|fees|%)'::"text"))) AND ("li"."name" !~* '^\s*tax\s*$'::"text"))))
                           FROM "public"."jobs" "j"
                          WHERE (("j"."id" = "v"."job_id") AND ("j"."title" IS NOT NULL) AND (TRIM(BOTH FROM "j"."title") <> ''::"text") AND (EXISTS ( SELECT 1
                                   FROM "public"."line_items" "li"
                                  WHERE (("li"."job_id" = "v"."job_id") AND ("li"."invoice_id" IS NULL) AND ("li"."name" IS NOT NULL) AND (NOT (("li"."name" ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::"text") AND ("li"."name" ~* '(fee|fees|%)'::"text"))) AND ("li"."name" !~* '^\s*tax\s*$'::"text")))))), ( SELECT "string_agg"("li"."name", ', '::"text" ORDER BY "li"."id") AS "string_agg"
                           FROM "public"."line_items" "li"
                          WHERE (("li"."job_id" = "v"."job_id") AND ("li"."invoice_id" IS NULL) AND ("li"."name" IS NOT NULL) AND (NOT (("li"."name" ~* '\y(ach|cc|credit\s*cards?|transaction)\y'::"text") AND ("li"."name" ~* '(fee|fees|%)'::"text"))) AND ("li"."name" !~* '^\s*tax\s*$'::"text"))), NULLIF(TRIM(BOTH FROM "split_part"("v"."title", ' - '::"text", 2)), ''::"text"), ( SELECT NULLIF(TRIM(BOTH FROM "j"."title"), ''::"text") AS "nullif"
                           FROM "public"."jobs" "j"
                          WHERE ("j"."id" = "v"."job_id"))) AS "line_items",
                    COALESCE(( SELECT NULLIF("jsonb_agg"("jsonb_build_object"('name', "li"."name", 'quantity', "li"."quantity", 'unit_price', "li"."unit_price", 'total_price', "li"."total_price") ORDER BY "li"."id"), '[]'::"jsonb") AS "nullif"
                           FROM "public"."line_items" "li"
                          WHERE ("li"."invoice_id" = "v"."invoice_id")), ( SELECT NULLIF("jsonb_agg"("jsonb_build_object"('name', "li"."name", 'quantity', "li"."quantity", 'unit_price', "li"."unit_price", 'total_price', "li"."total_price") ORDER BY "li"."id"), '[]'::"jsonb") AS "nullif"
                           FROM "public"."line_items" "li"
                          WHERE (("li"."job_id" = "v"."job_id") AND ("li"."invoice_id" IS NULL))), '[]'::"jsonb") AS "line_items_json",
                    ( SELECT "g"."gdo_number"
                           FROM "public"."gdos" "g"
                          WHERE (("g"."client_id" = "c"."id") AND ("g"."status" = 'ACTIVE'::"text"))
                          ORDER BY "g"."id"
                         LIMIT 1) AS "gdo_number",
                    ( SELECT "j"."job_number"
                           FROM "public"."jobs" "j"
                          WHERE ("j"."id" = "v"."job_id")) AS "job_number"
                   FROM (("public"."visits" "v"
                     JOIN "public"."clients" "c" ON (("c"."id" = "v"."client_id")))
                     LEFT JOIN LATERAL ( SELECT "p2"."address",
                            "p2"."county"
                           FROM "public"."properties" "p2"
                          WHERE ("p2"."client_id" = "c"."id")
                          ORDER BY "p2"."is_primary" DESC NULLS LAST, ("p2"."is_billing" IS NOT TRUE) DESC, "p2"."id"
                         LIMIT 1) "p" ON (true))
                  WHERE ("v"."visit_status" = 'completed'::"text")) "sub") "w";


ALTER VIEW "derm"."visits" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."client_jobs" AS
 SELECT "id" AS "job_id",
    "client_id",
    "title",
    "job_number",
    "job_status",
        CASE
            WHEN ("lower"("btrim"("title")) ~~ 'service agreement%'::"text") THEN 'Service Agreement'::"text"
            WHEN ("lower"("btrim"("title")) ~~ 'service call%'::"text") THEN 'Service Call'::"text"
            WHEN ("lower"("btrim"("title")) = 'credit card fee (3.53%)'::"text") THEN 'Credit card fee (3.53%)'::"text"
            WHEN ("lower"("btrim"("title")) = 'ach fee (1%)'::"text") THEN 'ACH Fee (1%)'::"text"
            WHEN ("lower"("btrim"("title")) = 'gdo online reporting'::"text") THEN 'GDO Online Reporting'::"text"
            ELSE NULL::"text"
        END AS "category"
   FROM "public"."jobs" "j"
  WHERE (("job_status" <> 'archived'::"text") AND (("lower"("btrim"("title")) ~~ 'service agreement%'::"text") OR ("lower"("btrim"("title")) ~~ 'service call%'::"text") OR ("lower"("btrim"("title")) = ANY (ARRAY['credit card fee (3.53%)'::"text", 'ach fee (1%)'::"text", 'gdo online reporting'::"text"]))));


ALTER VIEW "ops"."client_jobs" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."clients" AS
 SELECT "id",
    "client_code",
    "name",
    "status",
    "balance",
    "notes",
    "created_at",
    "updated_at",
    "group_id"
   FROM "public"."clients";


ALTER VIEW "ops"."clients" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_locations" (
    "id" bigint NOT NULL,
    "client_id" bigint NOT NULL,
    "name" "text" NOT NULL,
    "property_id" bigint,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "contact_name" "text",
    "contact_phone" "text",
    "contact_email" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "client_locations_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'closed'::"text"])))
);


ALTER TABLE "public"."client_locations" OWNER TO "postgres";


COMMENT ON TABLE "public"."client_locations" IS 'Named service locations within a single client (1 client -> N locations). A location is a tenant (food-hall restaurant, e.g. Wynd 28) OR a service area (e.g. Casa Neos Kitchens/Bars/Lounge); each has its own DERM GDO. Identity layer only: visits, frequency, price, billing, trap stay shared on their own tables and are referenced, NEVER duplicated here. Each location links to its permit via gdos.client_location_id. Created 2026-06-01, see migration 2026-06-01_client_locations.sql.';



COMMENT ON COLUMN "public"."client_locations"."client_id" IS 'Owning client. FK -> clients(id) ON DELETE CASCADE.';



COMMENT ON COLUMN "public"."client_locations"."name" IS 'Location display name (e.g. "Pasta", "Kitchens"). The per-location identity ops + DERM need.';



COMMENT ON COLUMN "public"."client_locations"."property_id" IS 'Shared building/property this location occupies. FK -> properties(id) ON DELETE SET NULL. A reference for grouping, NOT a copy of any property attribute. Nullable: a location may be recorded before its property row exists.';



COMMENT ON COLUMN "public"."client_locations"."status" IS 'active | closed. Per-location lifecycle, independent of the parent client.status.';



COMMENT ON COLUMN "public"."client_locations"."updated_at" IS 'Auto-bumped to now() on UPDATE by set_updated_at_client_locations (Rule 7). Never set manually.';



CREATE TABLE IF NOT EXISTS "public"."invoices" (
    "id" bigint NOT NULL,
    "client_id" bigint,
    "job_id" bigint,
    "invoice_number" "text",
    "subject" "text",
    "subtotal" numeric(12,2),
    "tax_amount" numeric(12,2),
    "total" numeric(12,2),
    "outstanding_amount" numeric(12,2),
    "deposit_amount" numeric(12,2),
    "invoice_status" "text",
    "due_date" "date",
    "sent_at" timestamp with time zone,
    "paid_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);

ALTER TABLE ONLY "public"."invoices" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."invoices" OWNER TO "postgres";


COMMENT ON TABLE "public"."invoices" IS 'Invoices from Jobber (1,583). Payment via paid_at. Outstanding A/R: ~$132K. No QuickBooks needed.';



CREATE TABLE IF NOT EXISTS "public"."visit_locations" (
    "visit_id" bigint NOT NULL,
    "client_location_id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."visit_locations" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."invoice_locations" AS
 WITH "inv_locs" AS (
         SELECT "i_1"."id" AS "invoice_id",
            "cl_1"."id" AS "client_location_id"
           FROM ("public"."invoices" "i_1"
             JOIN "public"."client_locations" "cl_1" ON (("cl_1"."client_id" = "i_1"."client_id")))
          WHERE (( SELECT "count"(*) AS "count"
                   FROM "public"."client_locations" "x"
                  WHERE ("x"."client_id" = "i_1"."client_id")) = 1)
        UNION
         SELECT DISTINCT "i_1"."id",
            "vl"."client_location_id"
           FROM (("public"."invoices" "i_1"
             JOIN "public"."visits" "v" ON ((("v"."invoice_id" = "i_1"."id") AND ("v"."deleted_at" IS NULL))))
             JOIN "public"."visit_locations" "vl" ON (("vl"."visit_id" = "v"."id")))
          WHERE (( SELECT "count"(*) AS "count"
                   FROM "public"."client_locations" "x"
                  WHERE ("x"."client_id" = "i_1"."client_id")) > 1)
        UNION
         SELECT "i_1"."id",
            "cl_1"."id"
           FROM ("public"."invoices" "i_1"
             JOIN "public"."client_locations" "cl_1" ON (("cl_1"."client_id" = "i_1"."client_id")))
          WHERE ((( SELECT "count"(*) AS "count"
                   FROM "public"."client_locations" "x"
                  WHERE ("x"."client_id" = "i_1"."client_id")) > 1) AND (NOT (EXISTS ( SELECT 1
                   FROM ("public"."visits" "v"
                     JOIN "public"."visit_locations" "vl" ON (("vl"."visit_id" = "v"."id")))
                  WHERE (("v"."invoice_id" = "i_1"."id") AND ("v"."deleted_at" IS NULL))))))
        ), "counts" AS (
         SELECT "inv_locs"."invoice_id",
            "count"(*) AS "location_count"
           FROM "inv_locs"
          GROUP BY "inv_locs"."invoice_id"
        )
 SELECT "il"."invoice_id",
    "i"."invoice_number",
    "il"."client_location_id",
    "cl"."name" AS "location_name",
    "i"."client_id",
    "c"."client_code",
    "c"."name" AS "client_name",
    "cnt"."location_count",
    "i"."total" AS "invoice_total",
    "round"(("i"."total" / ("cnt"."location_count")::numeric), 2) AS "amount_share",
    "round"((COALESCE("i"."outstanding_amount", (0)::numeric) / ("cnt"."location_count")::numeric), 2) AS "outstanding_share",
    "i"."invoice_status",
    "i"."due_date",
    "i"."sent_at",
    "i"."paid_at"
   FROM (((("inv_locs" "il"
     JOIN "counts" "cnt" ON (("cnt"."invoice_id" = "il"."invoice_id")))
     JOIN "public"."invoices" "i" ON (("i"."id" = "il"."invoice_id")))
     JOIN "public"."client_locations" "cl" ON (("cl"."id" = "il"."client_location_id")))
     JOIN "public"."clients" "c" ON (("c"."id" = "i"."client_id")));


ALTER VIEW "ops"."invoice_locations" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."properties" AS
 SELECT "id",
    "client_id",
    "name",
    "address",
    "city",
    "state",
    "zip",
    "country",
    "is_billing",
    "created_at",
    "updated_at",
    "zone",
    "latitude",
    "longitude",
    "geofence_radius_meters",
    "geofence_type",
    "access_hours_start",
    "access_hours_end",
    "access_days",
    "is_primary",
    "notes",
    "county",
    "grease_trap_manhole_count",
    "access_notes",
    "default_disposal_facility_id"
   FROM "public"."properties";


ALTER VIEW "ops"."properties" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."service_configs" AS
 SELECT "id",
    "client_id",
    "service_type",
    "frequency_days",
    "first_visit",
    "last_visit",
    "stop_date",
    "price_per_visit",
    "schedule_notes",
    "created_at",
    "updated_at",
    "equipment_size_gallons",
    ( SELECT "g"."gdo_number"
           FROM "public"."gdos" "g"
          WHERE (("g"."client_id" = "sc"."client_id") AND ("g"."status" = 'ACTIVE'::"text"))
          ORDER BY "g"."id"
         LIMIT 1) AS "permit_number",
    ( SELECT "g"."permit_expiration"
           FROM "public"."gdos" "g"
          WHERE (("g"."client_id" = "sc"."client_id") AND ("g"."status" = 'ACTIVE'::"text"))
          ORDER BY "g"."id"
         LIMIT 1) AS "permit_expiration",
    "material_type",
    ( SELECT "g"."permit_document_path"
           FROM "public"."gdos" "g"
          WHERE (("g"."client_id" = "sc"."client_id") AND ("g"."status" = 'ACTIVE'::"text"))
          ORDER BY "g"."id"
         LIMIT 1) AS "permit_document_path",
    "property_id"
   FROM "public"."service_configs" "sc";


ALTER VIEW "ops"."service_configs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."service_line_items" (
    "id" bigint NOT NULL,
    "code" "text" NOT NULL,
    "title" "text" NOT NULL,
    "requires_derm" boolean DEFAULT false NOT NULL,
    "reason" "text",
    "service_kind" "text",
    "location_target" "text",
    "method" "text",
    "service_type" "text",
    "schedulable" boolean DEFAULT true NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."service_line_items" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."service_options" AS
 SELECT "id",
    "code",
    "title",
    "requires_derm",
    "service_type",
        CASE
            WHEN ("reason" = ANY (ARRAY['Service Agreement'::"text", 'Service Call'::"text"])) THEN "reason"
            ELSE "regexp_replace"("title", '^[0-9]+ - '::"text", ''::"text")
        END AS "level1",
        CASE
            WHEN ("reason" = ANY (ARRAY['Service Agreement'::"text", 'Service Call'::"text"])) THEN "service_kind"
            ELSE NULL::"text"
        END AS "level2",
        CASE
            WHEN ("location_target" IS NOT NULL) THEN ("location_target" || COALESCE((' - '::"text" || "method"), ''::"text"))
            ELSE NULL::"text"
        END AS "level3"
   FROM "public"."service_line_items"
  WHERE ("active" = true);


ALTER VIEW "ops"."service_options" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."v_ar_aging" WITH ("security_invoker"='true') AS
 SELECT "c"."id" AS "client_id",
    "c"."client_code",
    "c"."name" AS "client_name",
    "c"."status" AS "client_status",
    "p"."zone",
    "p"."address",
    "p"."city",
    "p"."county",
    "cc"."name" AS "contact_name",
    "cc"."email" AS "primary_email",
    "cc"."phone" AS "primary_phone",
    "i"."id" AS "invoice_id",
    "i"."invoice_number",
    "i"."due_date",
    "i"."total",
    "i"."outstanding_amount" AS "balance_due",
    "i"."invoice_status",
    (CURRENT_DATE - "i"."due_date") AS "days_overdue",
        CASE
            WHEN ("i"."outstanding_amount" <= (0)::numeric) THEN 'paid'::"text"
            WHEN ("i"."due_date" >= CURRENT_DATE) THEN 'current'::"text"
            WHEN (((CURRENT_DATE - "i"."due_date") >= 1) AND ((CURRENT_DATE - "i"."due_date") <= 30)) THEN '1-30_days'::"text"
            WHEN (((CURRENT_DATE - "i"."due_date") >= 31) AND ((CURRENT_DATE - "i"."due_date") <= 60)) THEN '31-60_days'::"text"
            WHEN (((CURRENT_DATE - "i"."due_date") >= 61) AND ((CURRENT_DATE - "i"."due_date") <= 90)) THEN '61-90_days'::"text"
            ELSE '90+_days'::"text"
        END AS "aging_bucket"
   FROM ((("public"."invoices" "i"
     JOIN "public"."clients" "c" ON (("c"."id" = "i"."client_id")))
     LEFT JOIN "public"."client_contacts" "cc" ON ((("cc"."client_id" = "c"."id") AND ("cc"."contact_role" = 'primary'::"text"))))
     LEFT JOIN "public"."properties" "p" ON ((("p"."client_id" = "c"."id") AND ("p"."is_primary" = true))))
  WHERE ("i"."outstanding_amount" > (0)::numeric)
  ORDER BY "p"."zone", (CURRENT_DATE - "i"."due_date") DESC NULLS LAST;


ALTER VIEW "ops"."v_ar_aging" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."v_billing_by_location" AS
 SELECT "client_location_id",
    "location_name",
    "client_id",
    "client_code",
    "client_name",
    "count"(*) AS "invoice_count",
    "sum"("amount_share") AS "billed_total",
    "sum"("outstanding_share") AS "outstanding_total",
    "max"("sent_at") AS "last_invoiced_at"
   FROM "ops"."invoice_locations" "il"
  GROUP BY "client_location_id", "location_name", "client_id", "client_code", "client_name";


ALTER VIEW "ops"."v_billing_by_location" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."v_calendar_driver" AS
 SELECT "id",
    "full_name",
    "role",
    "status",
    "shift",
    "phone",
    "email"
   FROM "public"."employees"
  WHERE ("status" = 'ACTIVE'::"text")
  ORDER BY "full_name";


ALTER VIEW "ops"."v_calendar_driver" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."v_calendar_truck" AS
 SELECT "id",
    "name",
    "status",
    "make",
    "model",
    "year",
    "grease_tank_capacity_gallons",
    "fuel_tank_capacity_gallons",
    "license_plate",
    "decal_number",
    "notes",
    "created_at",
    "updated_at"
   FROM "public"."vehicles"
  ORDER BY
        CASE "status"
            WHEN 'ACTIVE'::"text" THEN 0
            ELSE 1
        END, "name";


ALTER VIEW "ops"."v_calendar_truck" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."v_calendar_visit" AS
 WITH "last_completed" AS (
         SELECT "v_1"."id" AS "visit_id",
            ( SELECT "max"("prev"."visit_date") AS "max"
                   FROM "public"."visits" "prev"
                  WHERE (("prev"."client_id" = "v_1"."client_id") AND ("prev"."service_type" = "v_1"."service_type") AND ("prev"."visit_status" = 'completed'::"text") AND ("prev"."visit_date" < "v_1"."visit_date"))) AS "last_completed_date"
           FROM "public"."visits" "v_1"
        ), "first_assignment" AS (
         SELECT DISTINCT ON ("va"."visit_id") "va"."visit_id",
            "va"."employee_id"
           FROM "public"."visit_assignments" "va"
          ORDER BY "va"."visit_id", "va"."employee_id"
        ), "observed_cadence" AS (
         SELECT "gaps"."client_id",
            "gaps"."service_type",
            ("percentile_cont"((0.5)::double precision) WITHIN GROUP (ORDER BY (("gaps"."days_since_prev")::double precision)))::integer AS "median_gap_days"
           FROM ( SELECT "visits"."client_id",
                    "visits"."service_type",
                    ("visits"."visit_date" - "lag"("visits"."visit_date") OVER (PARTITION BY "visits"."client_id", "visits"."service_type" ORDER BY "visits"."visit_date")) AS "days_since_prev"
                   FROM "public"."visits"
                  WHERE (("visits"."visit_status" = 'completed'::"text") AND ("visits"."service_type" = ANY (ARRAY['GT'::"text", 'CL'::"text", 'WD'::"text"])))) "gaps"
          WHERE (("gaps"."days_since_prev" >= 5) AND ("gaps"."days_since_prev" <= 200))
          GROUP BY "gaps"."client_id", "gaps"."service_type"
        ), "observed_price" AS (
         SELECT "v_1"."client_id",
            "v_1"."service_type",
            ("percentile_cont"((0.5)::double precision) WITHIN GROUP (ORDER BY (("li"."total_price")::double precision)))::numeric(12,2) AS "median_line_price"
           FROM ("public"."visits" "v_1"
             JOIN "public"."line_items" "li" ON (("li"."invoice_id" = "v_1"."invoice_id")))
          WHERE (("v_1"."invoice_id" IS NOT NULL) AND ("v_1"."visit_status" = 'completed'::"text") AND ("v_1"."service_type" = ANY (ARRAY['GT'::"text", 'CL'::"text", 'WD'::"text"])) AND ("li"."total_price" > (0)::numeric))
          GROUP BY "v_1"."client_id", "v_1"."service_type"
        )
 SELECT "v"."id",
    "v"."public_id",
    "v"."client_id",
    "v"."property_id",
    "v"."vehicle_id",
    "v"."job_id",
    "v"."visit_date",
    "v"."visit_status",
    "v"."service_type",
    "v"."start_at",
    "v"."end_at",
    "v"."completed_at",
    "v"."duration_minutes",
    "v"."title",
    "v"."derm_required",
    "v"."is_gps_confirmed",
    "v"."manhole_count",
    "v"."ticket_number",
    "v"."created_at" AS "visit_created_at",
    "v"."updated_at" AS "visit_updated_at",
    COALESCE("sc"."price_per_visit", "op"."median_line_price") AS "amount",
    "c"."client_code",
    "c"."name" AS "client_name",
    "c"."status" AS "client_status",
    "c"."group_id" AS "client_group_id",
    COALESCE("prop"."zone", "primary_prop"."zone") AS "zone",
    COALESCE("prop"."address", "primary_prop"."address") AS "address",
    COALESCE("prop"."city", "primary_prop"."city") AS "city",
    COALESCE("prop"."state", "primary_prop"."state") AS "state",
    COALESCE("prop"."zip", "primary_prop"."zip") AS "zip",
    COALESCE("prop"."county", "primary_prop"."county") AS "county",
    COALESCE("prop"."access_hours_start", "primary_prop"."access_hours_start") AS "access_hours_start",
    COALESCE("prop"."access_hours_end", "primary_prop"."access_hours_end") AS "access_hours_end",
    COALESCE("prop"."access_days", "primary_prop"."access_days") AS "access_days",
    COALESCE("prop"."latitude", "primary_prop"."latitude") AS "latitude",
    COALESCE("prop"."longitude", "primary_prop"."longitude") AS "longitude",
    COALESCE("prop"."grease_trap_manhole_count", "primary_prop"."grease_trap_manhole_count") AS "manholes",
    COALESCE("sc"."frequency_days", "oc"."median_gap_days") AS "frequency_days",
    "sc"."equipment_size_gallons",
    "sc"."first_visit" AS "sc_first_visit",
    "sc"."last_visit" AS "sc_last_visit",
    "sc"."stop_date" AS "sc_stop_date",
    "sc"."material_type",
    "g"."gdo_number",
    "g"."permit_expiration" AS "gdo_expiration",
    "g"."max_frequency_days" AS "gdo_max_frequency_days",
    "g"."permit_document_path" AS "gdo_document_path",
    "g"."status" AS "gdo_status",
    "veh"."name" AS "truck_name",
    "veh"."status" AS "vehicle_status",
    "veh"."grease_tank_capacity_gallons",
    "veh"."fuel_tank_capacity_gallons",
    "emp"."id" AS "driver_id",
    "emp"."full_name" AS "driver_name",
    "emp"."role" AS "driver_role",
        CASE
            WHEN ("v"."visit_status" = 'completed'::"text") THEN NULL::"text"
            WHEN ("lc"."last_completed_date" IS NULL) THEN NULL::"text"
            WHEN (COALESCE("sc"."frequency_days", "oc"."median_gap_days") IS NULL) THEN NULL::"text"
            WHEN ((("lc"."last_completed_date" + ((COALESCE("sc"."frequency_days", "oc"."median_gap_days"))::double precision * '1 day'::interval)))::"date" < CURRENT_DATE) THEN 'late'::"text"
            WHEN ((("lc"."last_completed_date" + ((COALESCE("sc"."frequency_days", "oc"."median_gap_days"))::double precision * '1 day'::interval)))::"date" < "v"."visit_date") THEN 'will_be_late'::"text"
            ELSE 'on_time'::"text"
        END AS "late_status",
    "lc"."last_completed_date"
   FROM ((((((((((("public"."visits" "v"
     JOIN "public"."clients" "c" ON (("c"."id" = "v"."client_id")))
     LEFT JOIN "public"."properties" "prop" ON (("prop"."id" = "v"."property_id")))
     LEFT JOIN "public"."properties" "primary_prop" ON ((("primary_prop"."client_id" = "v"."client_id") AND ("primary_prop"."is_primary" = true))))
     LEFT JOIN "public"."service_configs" "sc" ON ((("sc"."client_id" = "v"."client_id") AND ("sc"."service_type" = "v"."service_type"))))
     LEFT JOIN LATERAL ( SELECT "g0"."gdo_number",
            "g0"."permit_expiration",
            "g0"."max_frequency_days",
            "g0"."permit_document_path",
            "g0"."status"
           FROM "public"."gdos" "g0"
          WHERE (("g0"."status" = 'ACTIVE'::"text") AND ((("v"."property_id" IS NOT NULL) AND ("g0"."property_id" = "v"."property_id")) OR (("v"."property_id" IS NULL) AND ("g0"."client_id" = "v"."client_id"))))
          ORDER BY "g0"."id"
         LIMIT 1) "g" ON (true))
     LEFT JOIN "public"."vehicles" "veh" ON (("veh"."id" = "v"."vehicle_id")))
     LEFT JOIN "first_assignment" "fa" ON (("fa"."visit_id" = "v"."id")))
     LEFT JOIN "public"."employees" "emp" ON (("emp"."id" = "fa"."employee_id")))
     LEFT JOIN "last_completed" "lc" ON (("lc"."visit_id" = "v"."id")))
     LEFT JOIN "observed_cadence" "oc" ON ((("oc"."client_id" = "v"."client_id") AND ("oc"."service_type" = "v"."service_type"))))
     LEFT JOIN "observed_price" "op" ON ((("op"."client_id" = "v"."client_id") AND ("op"."service_type" = "v"."service_type"))))
  WHERE ("v"."deleted_at" IS NULL);


ALTER VIEW "ops"."v_calendar_visit" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."entity_source_links" (
    "id" bigint NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" bigint NOT NULL,
    "source_system" "text" NOT NULL,
    "source_id" "text" NOT NULL,
    "source_name" "text",
    "match_method" "text",
    "match_confidence" numeric,
    "synced_at" timestamp with time zone DEFAULT "now"(),
    "created_at" timestamp with time zone DEFAULT "now"()
);

ALTER TABLE ONLY "public"."entity_source_links" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."entity_source_links" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."v_calendar_visit_detail" AS
 SELECT "v"."id" AS "visit_id",
    "v"."job_id",
    "v"."client_id",
    "v"."title",
    "v"."visit_date",
    "v"."visit_status",
    "v"."derm_required",
        CASE
            WHEN ("j"."title" ~~* 'Service Agreement%'::"text") THEN 'service_agreement'::"text"
            WHEN ("j"."title" ~~* 'Service Call%'::"text") THEN 'service_call'::"text"
            ELSE NULL::"text"
        END AS "service_kind",
    "j"."frequency_days" AS "agreement_frequency_days",
        CASE
            WHEN ("esl"."source_id" IS NOT NULL) THEN ('https://secure.getjobber.com/work_orders/'::"text" || "split_part"("convert_from"("decode"("esl"."source_id", 'base64'::"text"), 'UTF8'::"name"), '/'::"text", '-1'::integer))
            ELSE NULL::"text"
        END AS "jobber_job_url",
    COALESCE("jli"."items", '[]'::json) AS "line_items",
    "j"."job_number" AS "jobber_job_number"
   FROM ((("public"."visits" "v"
     LEFT JOIN "public"."jobs" "j" ON (("j"."id" = "v"."job_id")))
     LEFT JOIN "public"."entity_source_links" "esl" ON ((("esl"."entity_type" = 'job'::"text") AND ("esl"."source_system" = 'jobber'::"text") AND ("esl"."entity_id" = "v"."job_id"))))
     LEFT JOIN LATERAL ( SELECT "json_agg"("json_build_object"('name', "li"."name", 'description', "li"."description", 'quantity', "li"."quantity") ORDER BY "li"."name") AS "items"
           FROM "public"."line_items" "li"
          WHERE (("li"."job_id" = "v"."job_id") AND ("li"."invoice_id" IS NULL))) "jli" ON (true))
  WHERE ("v"."deleted_at" IS NULL);


ALTER VIEW "ops"."v_calendar_visit_detail" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."v_derm_compliance" AS
 WITH "last_manifest" AS (
         SELECT "derm_manifests"."client_id",
            "max"("derm_manifests"."service_date") AS "last_manifest_date",
            "count"(*) AS "total_manifests"
           FROM "public"."derm_manifests"
          GROUP BY "derm_manifests"."client_id"
        ), "unmatched_visits" AS (
         SELECT "v"."client_id",
            "count"(*) AS "missing_manifests"
           FROM "public"."visits" "v"
          WHERE (("v"."service_type" = 'GT'::"text") AND ("v"."visit_status" = 'completed'::"text") AND ("v"."visit_date" >= (CURRENT_DATE - '120 days'::interval)) AND (NOT (EXISTS ( SELECT 1
                   FROM "public"."derm_manifests" "dm"
                  WHERE (("dm"."client_id" = "v"."client_id") AND ("dm"."service_date" = "v"."visit_date"))))))
          GROUP BY "v"."client_id"
        )
 SELECT "c"."id",
    "c"."client_code",
    "c"."name" AS "client_name",
    "c"."status" AS "client_status",
    "p"."zone",
    "p"."address",
    "p"."city",
    "p"."county",
    "cc"."name" AS "contact_name",
    "cc"."email",
    "cc"."phone",
    ( SELECT "g"."gdo_number"
           FROM "public"."gdos" "g"
          WHERE (("g"."client_id" = "c"."id") AND ("g"."status" = 'ACTIVE'::"text"))
          ORDER BY "g"."id"
         LIMIT 1) AS "permit_number",
    ( SELECT "g"."permit_expiration"
           FROM "public"."gdos" "g"
          WHERE (("g"."client_id" = "c"."id") AND ("g"."status" = 'ACTIVE'::"text"))
          ORDER BY "g"."id"
         LIMIT 1) AS "permit_expiration",
    "sc"."equipment_size_gallons",
    "sc"."frequency_days",
    "lm"."last_manifest_date",
    "lm"."total_manifests",
    COALESCE("uv"."missing_manifests", (0)::bigint) AS "missing_manifest_count",
        CASE
            WHEN (COALESCE("uv"."missing_manifests", (0)::bigint) > 0) THEN true
            ELSE false
        END AS "has_missing_manifests",
    (CURRENT_DATE - "lm"."last_manifest_date") AS "days_since_last_manifest",
        CASE
            WHEN ("lm"."last_manifest_date" IS NULL) THEN 'no_service_record'::"text"
            WHEN ((CURRENT_DATE - "lm"."last_manifest_date") > 90) THEN 'derm_violation'::"text"
            WHEN ((CURRENT_DATE - "lm"."last_manifest_date") > COALESCE("sc"."frequency_days", 90)) THEN 'overdue'::"text"
            WHEN ((CURRENT_DATE - "lm"."last_manifest_date") > (COALESCE("sc"."frequency_days", 90) - 14)) THEN 'due_soon'::"text"
            ELSE 'compliant'::"text"
        END AS "compliance_status"
   FROM ((((("public"."clients" "c"
     JOIN "public"."service_configs" "sc" ON ((("sc"."client_id" = "c"."id") AND ("sc"."service_type" = 'GT'::"text"))))
     LEFT JOIN "public"."client_contacts" "cc" ON ((("cc"."client_id" = "c"."id") AND ("cc"."contact_role" = 'primary'::"text"))))
     LEFT JOIN "public"."properties" "p" ON ((("p"."client_id" = "c"."id") AND ("p"."is_primary" = true))))
     LEFT JOIN "last_manifest" "lm" ON (("lm"."client_id" = "c"."id")))
     LEFT JOIN "unmatched_visits" "uv" ON (("uv"."client_id" = "c"."id")))
  WHERE ("c"."status" = ANY (ARRAY['ACTIVE'::"text", 'RECURRING'::"text"]))
  ORDER BY
        CASE
            WHEN ((CURRENT_DATE - "lm"."last_manifest_date") > 90) THEN 1
            WHEN ("lm"."last_manifest_date" IS NULL) THEN 2
            WHEN ((CURRENT_DATE - "lm"."last_manifest_date") > COALESCE("sc"."frequency_days", 90)) THEN 3
            WHEN ((CURRENT_DATE - "lm"."last_manifest_date") > (COALESCE("sc"."frequency_days", 90) - 14)) THEN 4
            ELSE 5
        END, COALESCE("uv"."missing_manifests", (0)::bigint) DESC, (CURRENT_DATE - "lm"."last_manifest_date") DESC NULLS LAST;


ALTER VIEW "ops"."v_derm_compliance" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."v_driver_kpi" AS
 WITH "driver_visits" AS (
         SELECT "va"."employee_id",
            "count"(DISTINCT "v"."id") AS "visits_completed",
            "count"(DISTINCT "v"."client_id") AS "unique_clients",
            "count"(DISTINCT "v"."visit_date") AS "active_days",
            "sum"("i"."total") AS "attributed_revenue"
           FROM (("public"."visit_assignments" "va"
             JOIN "public"."visits" "v" ON (("v"."id" = "va"."visit_id")))
             LEFT JOIN "public"."invoices" "i" ON (("i"."id" = "v"."invoice_id")))
          WHERE (("v"."visit_status" = 'completed'::"text") AND ("v"."visit_date" >= (CURRENT_DATE - '30 days'::interval)))
          GROUP BY "va"."employee_id"
        ), "inspection_stats" AS (
         SELECT "inspections"."employee_id",
            "count"(*) FILTER (WHERE ("inspections"."inspection_type" = 'PRE'::"text")) AS "pre_count",
            "count"(*) FILTER (WHERE ("inspections"."inspection_type" = 'POST'::"text")) AS "post_count",
            "count"(DISTINCT "inspections"."shift_date") AS "shifts_with_any",
            "count"(*) FILTER (WHERE ("inspections"."has_issue" = true)) AS "shifts_with_issues"
           FROM "public"."inspections"
          WHERE ("inspections"."shift_date" >= (CURRENT_DATE - '30 days'::interval))
          GROUP BY "inspections"."employee_id"
        )
 SELECT "e"."id",
    "e"."full_name" AS "driver_name",
    "e"."role",
    "e"."shift",
    "e"."status" AS "employee_status",
    COALESCE("dv"."visits_completed", (0)::bigint) AS "visits_30d",
    COALESCE("dv"."unique_clients", (0)::bigint) AS "clients_served_30d",
    COALESCE("dv"."active_days", (0)::bigint) AS "active_days_30d",
    COALESCE("dv"."attributed_revenue", (0)::numeric) AS "revenue_30d",
    COALESCE("ins"."pre_count", (0)::bigint) AS "pre_inspections_30d",
    COALESCE("ins"."post_count", (0)::bigint) AS "post_inspections_30d",
    COALESCE("ins"."shifts_with_any", (0)::bigint) AS "inspection_shifts_30d",
    COALESCE("ins"."shifts_with_issues", (0)::bigint) AS "shifts_with_issues_30d",
    "round"(((100.0 * (LEAST(COALESCE("ins"."pre_count", (0)::bigint), COALESCE("ins"."post_count", (0)::bigint)))::numeric) / (NULLIF(COALESCE("dv"."active_days", "ins"."shifts_with_any", (0)::bigint), 0))::numeric), 0) AS "inspection_compliance_pct"
   FROM (("public"."employees" "e"
     LEFT JOIN "driver_visits" "dv" ON (("dv"."employee_id" = "e"."id")))
     LEFT JOIN "inspection_stats" "ins" ON (("ins"."employee_id" = "e"."id")))
  WHERE ("e"."status" = 'ACTIVE'::"text")
  ORDER BY COALESCE("dv"."visits_completed", (0)::bigint) DESC;


ALTER VIEW "ops"."v_driver_kpi" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."v_gdo_expiry" AS
 SELECT "c"."id",
    "c"."client_code",
    "c"."name" AS "client_name",
    "c"."status" AS "client_status",
    "p"."zone",
    "p"."address",
    "p"."city",
    "p"."county",
    "cc"."name" AS "contact_name",
    "cc"."email",
    "cc"."phone",
    'GT'::"text" AS "service_type",
    "g"."gdo_number" AS "permit_number",
    "g"."permit_expiration",
    "sc"."equipment_size_gallons",
    "sc"."frequency_days",
    ("g"."permit_expiration" - CURRENT_DATE) AS "days_until_expiry",
        CASE
            WHEN ("g"."permit_expiration" IS NULL) THEN 'no_permit'::"text"
            WHEN ("g"."permit_expiration" < CURRENT_DATE) THEN 'expired'::"text"
            WHEN (("g"."permit_expiration" - CURRENT_DATE) <= 30) THEN 'expiring_30d'::"text"
            WHEN (("g"."permit_expiration" - CURRENT_DATE) <= 60) THEN 'expiring_60d'::"text"
            WHEN (("g"."permit_expiration" - CURRENT_DATE) <= 90) THEN 'expiring_90d'::"text"
            ELSE 'valid'::"text"
        END AS "permit_status"
   FROM (((("public"."gdos" "g"
     JOIN "public"."clients" "c" ON (("c"."id" = "g"."client_id")))
     LEFT JOIN "public"."properties" "p" ON (("p"."id" = "g"."property_id")))
     LEFT JOIN "public"."client_contacts" "cc" ON ((("cc"."client_id" = "c"."id") AND ("cc"."contact_role" = 'primary'::"text"))))
     LEFT JOIN "public"."service_configs" "sc" ON ((("sc"."client_id" = "c"."id") AND ("sc"."service_type" = 'GT'::"text"))))
  WHERE (("g"."status" = 'ACTIVE'::"text") AND ("c"."status" = ANY (ARRAY['ACTIVE'::"text", 'RECURRING'::"text"])))
  ORDER BY
        CASE
            WHEN ("g"."permit_expiration" IS NULL) THEN 2
            WHEN ("g"."permit_expiration" < CURRENT_DATE) THEN 1
            WHEN (("g"."permit_expiration" - CURRENT_DATE) <= 30) THEN 3
            WHEN (("g"."permit_expiration" - CURRENT_DATE) <= 60) THEN 4
            WHEN (("g"."permit_expiration" - CURRENT_DATE) <= 90) THEN 5
            ELSE 6
        END, ("g"."permit_expiration" - CURRENT_DATE);


ALTER VIEW "ops"."v_gdo_expiry" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."v_revenue_summary" AS
 SELECT ("date_trunc"('month'::"text", ("v"."visit_date")::timestamp with time zone))::"date" AS "month",
    "v"."service_type",
    "p"."zone",
    "veh"."name" AS "truck",
    "count"(DISTINCT "v"."id") AS "visit_count",
    "count"(DISTINCT "v"."client_id") AS "client_count",
    "sum"("i"."total") AS "gross_revenue",
    "sum"("i"."outstanding_amount") AS "outstanding_ar",
    "sum"(("i"."total" - "i"."outstanding_amount")) AS "collected_revenue",
    "round"(((100.0 * "sum"(("i"."total" - "i"."outstanding_amount"))) / NULLIF("sum"("i"."total"), (0)::numeric)), 1) AS "collection_rate_pct"
   FROM ((("public"."visits" "v"
     JOIN "public"."invoices" "i" ON (("i"."id" = "v"."invoice_id")))
     LEFT JOIN "public"."properties" "p" ON (("p"."id" = "v"."property_id")))
     LEFT JOIN "public"."vehicles" "veh" ON (("veh"."id" = "v"."vehicle_id")))
  WHERE (("v"."visit_status" = 'completed'::"text") AND ("v"."visit_date" >= (CURRENT_DATE - '1 year'::interval)))
  GROUP BY ("date_trunc"('month'::"text", ("v"."visit_date")::timestamp with time zone)), "v"."service_type", "p"."zone", "veh"."name"
  ORDER BY (("date_trunc"('month'::"text", ("v"."visit_date")::timestamp with time zone))::"date") DESC, ("sum"("i"."total")) DESC;


ALTER VIEW "ops"."v_revenue_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."v_route_today" AS
 SELECT "v"."id" AS "visit_id",
    "v"."visit_date",
    "v"."start_at",
    "v"."end_at",
    "v"."visit_status",
    "v"."service_type",
    ("v"."visit_status" = 'completed'::"text") AS "is_complete",
    "v"."is_gps_confirmed",
    "c"."id" AS "client_id",
    "c"."client_code",
    "c"."name" AS "client_name",
    COALESCE("vp"."zone", "pp"."zone") AS "zone",
    COALESCE("vp"."address", "pp"."address") AS "address",
    COALESCE("vp"."city", "pp"."city") AS "city",
    COALESCE("vp"."county", "pp"."county") AS "county",
    COALESCE("vp"."latitude", "pp"."latitude") AS "latitude",
    COALESCE("vp"."longitude", "pp"."longitude") AS "longitude",
    COALESCE("vp"."access_hours_start", "pp"."access_hours_start") AS "access_hours_start",
    COALESCE("vp"."access_hours_end", "pp"."access_hours_end") AS "access_hours_end",
    "cc"."name" AS "contact_name",
    "cc"."phone" AS "contact_phone",
    "sc"."equipment_size_gallons",
    COALESCE(( SELECT "g"."gdo_number"
           FROM "public"."gdos" "g"
          WHERE (("g"."property_id" = "v"."property_id") AND ("g"."status" = 'ACTIVE'::"text"))
          ORDER BY "g"."id"
         LIMIT 1), ( SELECT "g"."gdo_number"
           FROM "public"."gdos" "g"
          WHERE (("g"."client_id" = "c"."id") AND ("g"."status" = 'ACTIVE'::"text"))
          ORDER BY "g"."id"
         LIMIT 1)) AS "permit_number",
    "veh"."name" AS "truck",
    "veh"."grease_tank_capacity_gallons",
    "string_agg"("e"."full_name", ', '::"text" ORDER BY "e"."full_name") AS "crew",
    "v"."duration_minutes"
   FROM (((((((("public"."visits" "v"
     JOIN "public"."clients" "c" ON (("c"."id" = "v"."client_id")))
     LEFT JOIN "public"."properties" "vp" ON (("vp"."id" = "v"."property_id")))
     LEFT JOIN "public"."properties" "pp" ON ((("pp"."client_id" = "c"."id") AND ("pp"."is_primary" = true))))
     LEFT JOIN "public"."client_contacts" "cc" ON ((("cc"."client_id" = "c"."id") AND ("cc"."contact_role" = 'primary'::"text"))))
     LEFT JOIN "public"."service_configs" "sc" ON ((("sc"."client_id" = "c"."id") AND ("sc"."service_type" = "v"."service_type"))))
     LEFT JOIN "public"."vehicles" "veh" ON (("veh"."id" = "v"."vehicle_id")))
     LEFT JOIN "public"."visit_assignments" "va" ON (("va"."visit_id" = "v"."id")))
     LEFT JOIN "public"."employees" "e" ON (("e"."id" = "va"."employee_id")))
  WHERE (("v"."visit_date" = CURRENT_DATE) AND ("v"."visit_status" = ANY (ARRAY['UPCOMING'::"text", 'LATE'::"text", 'completed'::"text"])))
  GROUP BY "v"."id", "v"."visit_date", "v"."start_at", "v"."end_at", "v"."visit_status", "v"."service_type", "v"."is_gps_confirmed", "c"."id", "c"."client_code", "c"."name", "vp"."zone", "vp"."address", "vp"."city", "vp"."county", "vp"."latitude", "vp"."longitude", "vp"."access_hours_start", "vp"."access_hours_end", "pp"."zone", "pp"."address", "pp"."city", "pp"."county", "pp"."latitude", "pp"."longitude", "pp"."access_hours_start", "pp"."access_hours_end", "cc"."name", "cc"."phone", "sc"."equipment_size_gallons", "v"."property_id", "veh"."name", "veh"."grease_tank_capacity_gallons", "v"."duration_minutes"
  ORDER BY "v"."start_at", COALESCE("vp"."zone", "pp"."zone"), "c"."name";


ALTER VIEW "ops"."v_route_today" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."v_service_due" AS
 WITH "actual_last_visit" AS (
         SELECT "visits"."client_id",
            "max"("visits"."visit_date") AS "last_visit_actual"
           FROM "public"."visits"
          WHERE ("visits"."visit_status" = 'completed'::"text")
          GROUP BY "visits"."client_id"
        )
 SELECT "c"."id",
    "c"."client_code",
    "c"."name" AS "client_name",
    "c"."status" AS "client_status",
    "p"."zone",
    "p"."address",
    "p"."city",
    "p"."county",
    "p"."access_hours_start",
    "p"."access_hours_end",
    "cc"."name" AS "contact_name",
    "cc"."email",
    "cc"."phone",
    "sc"."service_type",
    "sc"."frequency_days",
    "sc"."equipment_size_gallons",
    ( SELECT "g"."gdo_number"
           FROM "public"."gdos" "g"
          WHERE (("g"."client_id" = "c"."id") AND ("g"."status" = 'ACTIVE'::"text"))
          ORDER BY "g"."id"
         LIMIT 1) AS "permit_number",
    "sc"."price_per_visit",
    COALESCE("sc"."last_visit", "alv"."last_visit_actual") AS "last_service_date",
    ((COALESCE("sc"."last_visit", "alv"."last_visit_actual") + (("sc"."frequency_days" || ' days'::"text"))::interval))::"date" AS "scheduled_next_visit",
    (CURRENT_DATE - COALESCE("sc"."last_visit", "alv"."last_visit_actual")) AS "days_since_service",
        CASE
            WHEN (COALESCE("sc"."last_visit", "alv"."last_visit_actual") IS NULL) THEN 'never_serviced'::"text"
            WHEN ((CURRENT_DATE - COALESCE("sc"."last_visit", "alv"."last_visit_actual")) > 90) THEN 'derm_violation'::"text"
            WHEN ((CURRENT_DATE - COALESCE("sc"."last_visit", "alv"."last_visit_actual")) >= "sc"."frequency_days") THEN 'overdue'::"text"
            WHEN (((COALESCE("sc"."last_visit", "alv"."last_visit_actual") + "sc"."frequency_days") - CURRENT_DATE) <= 14) THEN 'due_soon'::"text"
            ELSE 'on_schedule'::"text"
        END AS "service_status"
   FROM (((("public"."clients" "c"
     JOIN "public"."service_configs" "sc" ON ((("sc"."client_id" = "c"."id") AND ("sc"."service_type" = ANY (ARRAY['GT'::"text", 'CL'::"text"])))))
     LEFT JOIN "public"."client_contacts" "cc" ON ((("cc"."client_id" = "c"."id") AND ("cc"."contact_role" = 'primary'::"text"))))
     LEFT JOIN "public"."properties" "p" ON ((("p"."client_id" = "c"."id") AND ("p"."is_primary" = true))))
     LEFT JOIN "actual_last_visit" "alv" ON (("alv"."client_id" = "c"."id")))
  WHERE (("c"."status" = ANY (ARRAY['ACTIVE'::"text", 'RECURRING'::"text"])) AND ((COALESCE("sc"."last_visit", "alv"."last_visit_actual") IS NULL) OR ((CURRENT_DATE - COALESCE("sc"."last_visit", "alv"."last_visit_actual")) >= (COALESCE("sc"."frequency_days", 90) - 14))))
  ORDER BY
        CASE
            WHEN ((CURRENT_DATE - COALESCE("sc"."last_visit", "alv"."last_visit_actual")) > 90) THEN 1
            ELSE 2
        END, "p"."zone",
        CASE
            WHEN (COALESCE("sc"."last_visit", "alv"."last_visit_actual") IS NULL) THEN 1
            WHEN ((CURRENT_DATE - COALESCE("sc"."last_visit", "alv"."last_visit_actual")) >= "sc"."frequency_days") THEN 2
            ELSE 3
        END, (CURRENT_DATE - COALESCE("sc"."last_visit", "alv"."last_visit_actual")) DESC NULLS LAST;


ALTER VIEW "ops"."v_service_due" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."v_truck_utilization" AS
 WITH "truck_stats" AS (
         SELECT "v"."vehicle_id",
            "count"(DISTINCT "v"."id") AS "visits_completed",
            "count"(DISTINCT "v"."client_id") AS "unique_clients",
            "count"(DISTINCT "v"."visit_date") AS "active_days",
            "sum"("i"."total") AS "attributed_revenue",
            "round"(("sum"(EXTRACT(epoch FROM ("v"."end_at" - "v"."start_at"))) FILTER (WHERE (("v"."start_at" IS NOT NULL) AND ("v"."end_at" IS NOT NULL))) / 3600.0), 1) AS "total_hours_onsite"
           FROM ("public"."visits" "v"
             LEFT JOIN "public"."invoices" "i" ON (("i"."id" = "v"."invoice_id")))
          WHERE (("v"."visit_status" = 'completed'::"text") AND ("v"."visit_date" >= (CURRENT_DATE - '30 days'::interval)))
          GROUP BY "v"."vehicle_id"
        )
 SELECT "veh"."id" AS "vehicle_id",
    "veh"."name" AS "truck",
    "veh"."make",
    "veh"."model",
    "veh"."year",
    "veh"."grease_tank_capacity_gallons",
    "veh"."fuel_tank_capacity_gallons",
    "veh"."status" AS "truck_status",
    COALESCE("ts"."visits_completed", (0)::bigint) AS "visits_30d",
    COALESCE("ts"."unique_clients", (0)::bigint) AS "clients_served_30d",
    COALESCE("ts"."active_days", (0)::bigint) AS "active_days_30d",
    COALESCE("ts"."total_hours_onsite", (0)::numeric) AS "hours_onsite_30d",
    COALESCE("ts"."attributed_revenue", (0)::numeric) AS "revenue_30d",
    "round"(((COALESCE("ts"."visits_completed", (0)::bigint))::numeric / (NULLIF("ts"."active_days", 0))::numeric), 1) AS "visits_per_active_day",
    "round"((COALESCE("ts"."attributed_revenue", (0)::numeric) / (NULLIF("ts"."active_days", 0))::numeric), 2) AS "revenue_per_active_day"
   FROM ("public"."vehicles" "veh"
     LEFT JOIN "truck_stats" "ts" ON (("ts"."vehicle_id" = "veh"."id")))
  ORDER BY COALESCE("ts"."visits_completed", (0)::bigint) DESC;


ALTER VIEW "ops"."v_truck_utilization" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."vehicles" AS
 SELECT "id",
    "name",
    "make",
    "model",
    "year",
    "vin",
    "license_plate",
    "grease_tank_capacity_gallons",
    "status",
    "notes",
    "created_at",
    "updated_at",
    "fuel_tank_capacity_gallons",
    "decal_number"
   FROM "public"."vehicles";


ALTER VIEW "ops"."vehicles" OWNER TO "postgres";


CREATE OR REPLACE VIEW "ops"."visits" AS
 SELECT "id",
    "client_id",
    "property_id",
    "job_id",
    "vehicle_id",
    "visit_date",
    "start_at",
    "end_at",
    "completed_at",
    "duration_minutes",
    "title",
    "service_type",
    "visit_status",
    "actual_arrival_at",
    "actual_departure_at",
    "is_gps_confirmed",
    "created_at",
    "updated_at",
    "invoice_id",
    "completed_by",
    "source",
    "manhole_count",
    "manhole_breakdown",
    "ticket_number",
    "trap_condition_notes",
    "derm_required",
    "service_line_item_id"
   FROM "public"."visits";


ALTER VIEW "ops"."visits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "partman"."template_audit_logs" (
    "id" bigint NOT NULL,
    "table_schema" "text" NOT NULL,
    "table_name" "text" NOT NULL,
    "record_pk" "jsonb" NOT NULL,
    "operation" "text" NOT NULL,
    "old_row" "jsonb",
    "new_row" "jsonb",
    "changed_by" "uuid",
    "db_role" "text" NOT NULL,
    "jwt_claims" "jsonb",
    "changed_at" timestamp with time zone NOT NULL
);


ALTER TABLE "partman"."template_audit_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_shift_reviews" (
    "external_employee_id" bigint NOT NULL,
    "shift_date" "date" NOT NULL,
    "review_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "reviewed_at" timestamp with time zone,
    "reviewed_by" bigint,
    "bonus_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "bonus_decided_at" timestamp with time zone,
    "bonus_decided_by" bigint,
    "bonus_denial_note" "text",
    "shift_quality_note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "app_shift_reviews_bonus_status_check" CHECK (("bonus_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'denied'::"text"]))),
    CONSTRAINT "app_shift_reviews_review_status_check" CHECK (("review_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'flagged'::"text"])))
);


ALTER TABLE "public"."app_shift_reviews" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_visit_reviews" (
    "external_visit_id" bigint NOT NULL,
    "review_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "reviewed_at" timestamp with time zone,
    "reviewed_by" bigint,
    "bonus_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "bonus_decided_at" timestamp with time zone,
    "bonus_decided_by" bigint,
    "bonus_denial_note" "text",
    "quality_flag_note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "app_visit_reviews_bonus_status_check" CHECK (("bonus_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'denied'::"text"]))),
    CONSTRAINT "app_visit_reviews_review_status_check" CHECK (("review_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'flagged'::"text"])))
);


ALTER TABLE "public"."app_visit_reviews" OWNER TO "postgres";


ALTER TABLE "public"."client_contacts" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."client_contacts_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."client_groups" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."client_groups_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."client_locations" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."client_locations_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE OR REPLACE VIEW "public"."client_services_flat" AS
SELECT
    NULL::bigint AS "id",
    NULL::"text" AS "name",
    NULL::"text" AS "client_code",
    NULL::"text" AS "address",
    NULL::"text" AS "city",
    NULL::"text" AS "zone",
    NULL::"text" AS "status",
    NULL::numeric AS "gt_size_gallons",
    NULL::integer AS "gt_frequency_days",
    NULL::numeric AS "gt_price_per_visit",
    NULL::"date" AS "gt_last_visit",
    NULL::"date" AS "gt_next_visit",
    NULL::"text" AS "gt_status",
    NULL::integer AS "cl_frequency_days",
    NULL::numeric AS "cl_price_per_visit",
    NULL::"date" AS "cl_last_visit",
    NULL::"date" AS "cl_next_visit",
    NULL::"text" AS "cl_status",
    NULL::integer AS "wd_frequency_days",
    NULL::numeric AS "wd_price_per_visit",
    NULL::"date" AS "wd_last_visit",
    NULL::"date" AS "wd_next_visit",
    NULL::"text" AS "wd_status";


ALTER VIEW "public"."client_services_flat" OWNER TO "postgres";


COMMENT ON VIEW "public"."client_services_flat" IS 'Pivoted service config for operator lookup. 3NF: *_next_visit and *_status computed on read.';



CREATE OR REPLACE VIEW "public"."clients_due_service" WITH ("security_invoker"='true') AS
 SELECT "c"."id",
    "c"."name",
    "c"."client_code",
    "p"."address",
    "p"."city",
    "p"."zone",
    "s"."service_type",
    "s"."last_visit",
    (("s"."last_visit" + (("s"."frequency_days" || ' days'::"text"))::interval))::"date" AS "next_visit",
    "s"."frequency_days",
    ((("s"."last_visit" + (("s"."frequency_days" || ' days'::"text"))::interval))::"date" - CURRENT_DATE) AS "days_until_due",
        CASE
            WHEN (("s"."last_visit" IS NULL) OR ("s"."frequency_days" IS NULL)) THEN 'UNKNOWN'::"text"
            WHEN ((("s"."last_visit" + (("s"."frequency_days" || ' days'::"text"))::interval))::"date" < CURRENT_DATE) THEN 'OVERDUE'::"text"
            WHEN ((("s"."last_visit" + (("s"."frequency_days" || ' days'::"text"))::interval))::"date" <= (CURRENT_DATE + 14)) THEN 'DUE_SOON'::"text"
            ELSE 'OK'::"text"
        END AS "due_status"
   FROM (("public"."clients" "c"
     JOIN "public"."service_configs" "s" ON (("s"."client_id" = "c"."id")))
     LEFT JOIN "public"."properties" "p" ON ((("p"."client_id" = "c"."id") AND ("p"."is_primary" = true))))
  WHERE (("c"."status" = ANY (ARRAY['ACTIVE'::"text", 'RECURRING'::"text"])) AND (("s"."stop_date" IS NULL) OR ("s"."stop_date" > CURRENT_DATE)) AND ("s"."last_visit" IS NOT NULL) AND ("s"."frequency_days" IS NOT NULL))
  ORDER BY ((("s"."last_visit" + (("s"."frequency_days" || ' days'::"text"))::interval))::"date");


ALTER VIEW "public"."clients_due_service" OWNER TO "postgres";


COMMENT ON VIEW "public"."clients_due_service" IS 'Overdue and due-soon clients. 3NF: next_visit and due_status computed on read. Replaces service_configs.{next_visit,status} column reads.';



CREATE SEQUENCE IF NOT EXISTS "public"."clients_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."clients_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."clients_id_seq" OWNED BY "public"."clients"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."derm_address_seq"
    START WITH 1000
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."derm_address_seq" OWNER TO "postgres";


ALTER TABLE "public"."derm_email_sends" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."derm_email_sends_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."derm_manifest_number_proposals" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."derm_manifest_number_proposals_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE SEQUENCE IF NOT EXISTS "public"."derm_manifests_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."derm_manifests_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."derm_manifests_id_seq" OWNED BY "public"."derm_manifests"."id";



ALTER TABLE "public"."disposal_facilities" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."disposal_facilities_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE OR REPLACE VIEW "public"."driver_inspection_status" WITH ("security_invoker"='true') AS
 SELECT "e"."id",
    "e"."full_name",
    "max"(
        CASE
            WHEN (("i"."inspection_type" = 'PRE'::"text") AND ("i"."shift_date" = CURRENT_DATE)) THEN "i"."submitted_at"
            ELSE NULL::timestamp with time zone
        END) AS "pre_submitted_at",
    "max"(
        CASE
            WHEN ("i"."inspection_type" = 'POST'::"text") THEN "i"."submitted_at"
            ELSE NULL::timestamp with time zone
        END) AS "post_submitted_at",
    "count"(
        CASE
            WHEN ("i"."shift_date" = CURRENT_DATE) THEN 1
            ELSE NULL::integer
        END) AS "inspections_today",
    "bool_or"(
        CASE
            WHEN "i"."has_issue" THEN true
            ELSE NULL::boolean
        END) AS "has_open_issue"
   FROM ("public"."employees" "e"
     LEFT JOIN "public"."inspections" "i" ON ((("i"."employee_id" = "e"."id") AND (("i"."shift_date" = CURRENT_DATE) OR (("i"."shift_date" = (CURRENT_DATE - 1)) AND ("i"."inspection_type" = 'POST'::"text") AND ("i"."submitted_at" >= (CURRENT_DATE)::timestamp with time zone))))))
  WHERE ("e"."status" = 'ACTIVE'::"text")
  GROUP BY "e"."id", "e"."full_name";


ALTER VIEW "public"."driver_inspection_status" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."employees_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."employees_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."employees_id_seq" OWNED BY "public"."employees"."id";



ALTER TABLE "public"."entity_source_links" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."entity_source_links_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE SEQUENCE IF NOT EXISTS "public"."gdos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."gdos_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."gdos_id_seq" OWNED BY "public"."gdos"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."inspections_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."inspections_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."inspections_id_seq" OWNED BY "public"."inspections"."id";



CREATE OR REPLACE VIEW "public"."inspections_with_review" WITH ("security_invoker"='true') AS
 SELECT "i"."id",
    "i"."vehicle_id",
    "i"."employee_id",
    "i"."shift_date",
    "i"."inspection_type",
    "i"."submitted_at",
    "i"."sludge_gallons",
    "i"."water_gallons",
    "i"."gas_level",
    "i"."is_valve_closed",
    "i"."has_issue",
    "i"."issue_note",
    "i"."created_at",
    "i"."updated_at",
    COALESCE("asr"."review_status", 'pending'::"text") AS "shift_review_status",
    "asr"."reviewed_at" AS "shift_reviewed_at",
    "asr"."reviewed_by" AS "shift_reviewed_by",
    COALESCE("asr"."bonus_status", 'pending'::"text") AS "shift_bonus_status",
    "asr"."bonus_decided_at" AS "shift_bonus_decided_at",
    "asr"."bonus_decided_by" AS "shift_bonus_decided_by",
    "asr"."bonus_denial_note" AS "shift_bonus_denial_note",
    "asr"."shift_quality_note"
   FROM ("public"."inspections" "i"
     LEFT JOIN "public"."app_shift_reviews" "asr" ON ((("asr"."external_employee_id" = "i"."employee_id") AND ("asr"."shift_date" = "i"."shift_date"))));


ALTER VIEW "public"."inspections_with_review" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."invoices_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."invoices_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."invoices_id_seq" OWNED BY "public"."invoices"."id";



CREATE TABLE IF NOT EXISTS "public"."jobber_oversized_attachments" (
    "id" bigint NOT NULL,
    "client_id" bigint,
    "note_jobber_id" "text",
    "attachment_jobber_id" "text" NOT NULL,
    "file_name" "text",
    "content_type" "text",
    "size_bytes" bigint,
    "jobber_url_signed" "text",
    "classification_kind" "text",
    "visit_id" bigint,
    "logged_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."jobber_oversized_attachments" OWNER TO "postgres";


COMMENT ON TABLE "public"."jobber_oversized_attachments" IS 'Tracking table: Jobber attachments > 50 MB that the migration script skipped because of Supabase Pro bucket size cap. Recovery requires either plan upgrade or external storage.';



CREATE SEQUENCE IF NOT EXISTS "public"."jobber_oversized_attachments_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."jobber_oversized_attachments_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."jobber_oversized_attachments_id_seq" OWNED BY "public"."jobber_oversized_attachments"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."jobs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."jobs_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."jobs_id_seq" OWNED BY "public"."jobs"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."line_items_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."line_items_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."line_items_id_seq" OWNED BY "public"."line_items"."id";



CREATE OR REPLACE VIEW "public"."manifest_detail" WITH ("security_invoker"='true') AS
 SELECT "m"."id",
    "m"."white_manifest_number",
    "m"."service_date",
    "c"."name" AS "client_name",
    "p"."address",
    "p"."county" AS "service_county",
    "m"."sent_to_client",
    "m"."sent_to_city",
    "count"("mv"."visit_id") AS "visit_count"
   FROM ((("public"."derm_manifests" "m"
     LEFT JOIN "public"."clients" "c" ON (("c"."id" = "m"."client_id")))
     LEFT JOIN "public"."properties" "p" ON ((("p"."client_id" = "c"."id") AND ("p"."is_primary" = true))))
     LEFT JOIN "public"."manifest_visits" "mv" ON (("mv"."manifest_id" = "m"."id")))
  GROUP BY "m"."id", "m"."white_manifest_number", "m"."service_date", "c"."name", "p"."address", "p"."county", "m"."sent_to_client", "m"."sent_to_city"
  ORDER BY "m"."service_date" DESC;


ALTER VIEW "public"."manifest_detail" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."manifest_pickable_visits" WITH ("security_invoker"='true') AS
 SELECT "v"."id" AS "visit_id",
    "v"."visit_date",
    "v"."start_at",
    "v"."completed_at",
    "v"."service_type",
    "v"."title",
    "c"."id" AS "client_id",
    "c"."client_code",
    "c"."name" AS "client_name",
    COALESCE("p"."address", "primary_p"."address") AS "address",
    COALESCE("p"."city", "primary_p"."city") AS "city",
    COALESCE("p"."county", "primary_p"."county") AS "county"
   FROM ((("public"."visits" "v"
     JOIN "public"."clients" "c" ON (("c"."id" = "v"."client_id")))
     LEFT JOIN "public"."properties" "p" ON (("p"."id" = "v"."property_id")))
     LEFT JOIN "public"."properties" "primary_p" ON ((("primary_p"."client_id" = "v"."client_id") AND ("primary_p"."is_primary" = true))))
  WHERE (("v"."visit_status" = 'completed'::"text") AND (("v"."derm_required" IS NULL) OR ("v"."derm_required" = true)) AND ("v"."deleted_at" IS NULL) AND (NOT (EXISTS ( SELECT 1
           FROM ("public"."manifest_visits" "mv"
             JOIN "public"."derm_manifests" "dm" ON (("dm"."id" = "mv"."manifest_id")))
          WHERE (("mv"."visit_id" = "v"."id") AND ("dm"."deleted_at" IS NULL))))));


ALTER VIEW "public"."manifest_pickable_visits" OWNER TO "postgres";


ALTER TABLE "public"."municipality_regulators" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."municipality_regulators_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."notes" (
    "id" bigint NOT NULL,
    "client_id" bigint NOT NULL,
    "visit_id" bigint,
    "property_id" bigint,
    "job_id" bigint,
    "body" "text" NOT NULL,
    "author_employee_id" bigint,
    "author_name" "text",
    "note_date" timestamp with time zone NOT NULL,
    "source" "text" DEFAULT 'user'::"text" NOT NULL,
    "tags" "text"[],
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."notes" OWNER TO "postgres";


COMMENT ON TABLE "public"."notes" IS 'Free-form text notes attached to a client and optionally scoped to a visit/property/job. Attachments (photos) live in photo_links with entity_type=''note'' or routed to their classified parent (visit/property) by the migration classifier.';



COMMENT ON COLUMN "public"."notes"."author_name" IS 'Intentional denorm fallback (see ADR 004). Used for historical Jobber notes whose Jobber user can''t be mapped to our employees table. New notes should populate author_employee_id instead.';



COMMENT ON COLUMN "public"."notes"."note_date" IS 'Original note timestamp. Load-bearing: used by the Jobber photo migration to triangulate notes to visits (±1 day match window on visits.visit_date).';



COMMENT ON COLUMN "public"."notes"."source" IS 'Provenance: user | jobber_migration | fillout_migration | ai | system. Direct observation at insert time.';



CREATE SEQUENCE IF NOT EXISTS "public"."notes_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."notes_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."notes_id_seq" OWNED BY "public"."notes"."id";



ALTER TABLE "public"."photo_classifications" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."photo_classifications_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE SEQUENCE IF NOT EXISTS "public"."photo_links_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."photo_links_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."photo_links_id_seq" OWNED BY "public"."photo_links"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."photos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."photos_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."photos_id_seq" OWNED BY "public"."photos"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."properties_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."properties_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."properties_id_seq" OWNED BY "public"."properties"."id";



CREATE TABLE IF NOT EXISTS "public"."quotes" (
    "id" bigint NOT NULL,
    "client_id" bigint,
    "property_id" bigint,
    "quote_number" "text",
    "title" "text",
    "subtotal" numeric(12,2),
    "tax_amount" numeric(12,2),
    "total" numeric(12,2),
    "deposit_amount" numeric(12,2),
    "quote_status" "text",
    "sent_at" timestamp with time zone,
    "approved_at" timestamp with time zone,
    "converted_to_job_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);

ALTER TABLE ONLY "public"."quotes" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."quotes" OWNER TO "postgres";


COMMENT ON TABLE "public"."quotes" IS 'Sales quotes from Jobber (171). Pipeline: 5 high-value unsigned contracts.';



CREATE SEQUENCE IF NOT EXISTS "public"."quotes_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."quotes_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."quotes_id_seq" OWNED BY "public"."quotes"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."service_configs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."service_configs_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."service_configs_id_seq" OWNED BY "public"."service_configs"."id";



ALTER TABLE "public"."service_line_items" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."service_line_items_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."shift_reviews" (
    "employee_id" bigint NOT NULL,
    "shift_date" "date" NOT NULL,
    "review_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "reviewed_at" timestamp with time zone,
    "reviewed_by" bigint,
    "bonus_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "bonus_decided_at" timestamp with time zone,
    "bonus_decided_by" bigint,
    "bonus_denial_note" "text",
    "shift_quality_note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "shift_reviews_bonus_status_check" CHECK (("bonus_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'denied'::"text"]))),
    CONSTRAINT "shift_reviews_review_status_check" CHECK (("review_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'flagged'::"text"])))
);


ALTER TABLE "public"."shift_reviews" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sync_cursors" (
    "entity" "text" NOT NULL,
    "last_synced_at" timestamp with time zone,
    "last_run_started" timestamp with time zone,
    "last_run_finished" timestamp with time zone,
    "last_run_status" "text",
    "last_error" "text",
    "rows_pulled" integer DEFAULT 0,
    "rows_populated" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "sync_cursors_last_run_status_check" CHECK (("last_run_status" = ANY (ARRAY['running'::"text", 'success'::"text", 'failed'::"text"])))
);

ALTER TABLE ONLY "public"."sync_cursors" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."sync_cursors" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sync_log" (
    "id" bigint NOT NULL,
    "sync_source" "text" NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "finished_at" timestamp with time zone,
    "rows_inserted" integer DEFAULT 0,
    "rows_updated" integer DEFAULT 0,
    "rows_errored" integer DEFAULT 0,
    "error_details" "jsonb",
    "duration_seconds" numeric(8,2),
    "status" "text" DEFAULT 'running'::"text",
    "details" "jsonb"
);

ALTER TABLE ONLY "public"."sync_log" FORCE ROW LEVEL SECURITY;


ALTER TABLE "public"."sync_log" OWNER TO "postgres";


COMMENT ON TABLE "public"."sync_log" IS 'Sync run audit log. Tracks each nightly sync: source, row counts, errors, duration. No FK to business tables — system/ops table.';



CREATE SEQUENCE IF NOT EXISTS "public"."sync_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."sync_log_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."sync_log_id_seq" OWNED BY "public"."sync_log"."id";



CREATE TABLE IF NOT EXISTS "public"."vehicle_telemetry_readings" (
    "id" bigint NOT NULL,
    "vehicle_id" bigint NOT NULL,
    "fuel_percent" numeric(5,2),
    "odometer_meters" bigint,
    "engine_state" "text",
    "recorded_at" timestamp with time zone NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "engine_hours_seconds" bigint,
    "latitude" numeric(9,6),
    "longitude" numeric(9,6),
    "speed_meters_per_sec" numeric(7,3),
    "heading_degrees" numeric(6,2)
);


ALTER TABLE "public"."vehicle_telemetry_readings" OWNER TO "postgres";


COMMENT ON TABLE "public"."vehicle_telemetry_readings" IS 'Append-only Samsara vehicle telemetry snapshots. 3NF: each row is one observation of vehicle_id at recorded_at. No derived columns — fuel_gallons is computed in v_vehicle_telemetry_latest.';



COMMENT ON COLUMN "public"."vehicle_telemetry_readings"."odometer_meters" IS 'Samsara reports odometer in meters.  Divide by 1609.34 for miles.';



COMMENT ON COLUMN "public"."vehicle_telemetry_readings"."engine_hours_seconds" IS 'Lifetime engine hours at observation time (seconds). Samsara reports in seconds; divide by 3600 for hours.';



COMMENT ON COLUMN "public"."vehicle_telemetry_readings"."latitude" IS 'GPS latitude at sample time (degrees, 6dp ≈ 10cm precision).';



COMMENT ON COLUMN "public"."vehicle_telemetry_readings"."longitude" IS 'GPS longitude at sample time.';



COMMENT ON COLUMN "public"."vehicle_telemetry_readings"."speed_meters_per_sec" IS 'Vehicle speed at sample time. Multiply by 2.237 for mph.';



COMMENT ON COLUMN "public"."vehicle_telemetry_readings"."heading_degrees" IS 'Direction of travel in degrees clockwise from true north (0–359).';



CREATE OR REPLACE VIEW "public"."v_vehicle_telemetry_latest" WITH ("security_invoker"='true') AS
 SELECT DISTINCT ON ("vtr"."vehicle_id") "vtr"."vehicle_id",
    "v"."name" AS "vehicle_name",
    "vtr"."fuel_percent",
        CASE
            WHEN (("vtr"."fuel_percent" IS NOT NULL) AND ("v"."fuel_tank_capacity_gallons" IS NOT NULL)) THEN "round"((("vtr"."fuel_percent" * "v"."fuel_tank_capacity_gallons") / (100)::numeric), 2)
            ELSE NULL::numeric
        END AS "fuel_gallons_computed",
    "v"."fuel_tank_capacity_gallons",
    "vtr"."odometer_meters",
    "round"((("vtr"."odometer_meters")::numeric / 1609.34)) AS "odometer_miles",
    "vtr"."engine_state",
    "vtr"."engine_hours_seconds",
    "round"((("vtr"."engine_hours_seconds")::numeric / 3600.0), 1) AS "engine_hours",
    "vtr"."latitude",
    "vtr"."longitude",
    "vtr"."speed_meters_per_sec",
    "round"(("vtr"."speed_meters_per_sec" * 2.237), 1) AS "speed_mph",
    "vtr"."heading_degrees",
    "vtr"."recorded_at",
    "round"((EXTRACT(epoch FROM ("now"() - "vtr"."recorded_at")) / (60)::numeric)) AS "minutes_ago"
   FROM ("public"."vehicle_telemetry_readings" "vtr"
     JOIN "public"."vehicles" "v" ON (("v"."id" = "vtr"."vehicle_id")))
  ORDER BY "vtr"."vehicle_id", "vtr"."recorded_at" DESC;


ALTER VIEW "public"."v_vehicle_telemetry_latest" OWNER TO "postgres";


COMMENT ON VIEW "public"."v_vehicle_telemetry_latest" IS 'Latest telemetry snapshot per vehicle. fuel_gallons + speed_mph computed on read (3NF). GPS columns added 2026-04-30.';



ALTER TABLE "public"."vehicle_telemetry_readings" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."vehicle_fuel_readings_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE SEQUENCE IF NOT EXISTS "public"."vehicles_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."vehicles_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."vehicles_id_seq" OWNED BY "public"."vehicles"."id";



CREATE OR REPLACE VIEW "public"."visit_manhole_options" WITH ("security_invoker"='true') AS
 SELECT "v"."id" AS "visit_id",
    "cl"."id" AS "client_location_id",
    "cl"."name" AS "location_name",
    "g"."gdo_number",
    (EXISTS ( SELECT 1
           FROM "public"."visit_locations" "vl"
          WHERE (("vl"."visit_id" = "v"."id") AND ("vl"."client_location_id" = "cl"."id")))) AS "is_assigned"
   FROM (("public"."visits" "v"
     JOIN "public"."client_locations" "cl" ON (("cl"."client_id" = "v"."client_id")))
     LEFT JOIN "public"."gdos" "g" ON ((("g"."client_location_id" = "cl"."id") AND ("g"."status" = 'ACTIVE'::"text"))))
  WHERE ("v"."deleted_at" IS NULL);


ALTER VIEW "public"."visit_manhole_options" OWNER TO "postgres";


ALTER TABLE "public"."visit_recommendations" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."visit_recommendations_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."visit_reviews" (
    "visit_id" bigint NOT NULL,
    "review_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "reviewed_at" timestamp with time zone,
    "reviewed_by" bigint,
    "bonus_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "bonus_decided_at" timestamp with time zone,
    "bonus_decided_by" bigint,
    "bonus_denial_note" "text",
    "quality_flag_note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "visit_reviews_bonus_status_check" CHECK (("bonus_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'denied'::"text"]))),
    CONSTRAINT "visit_reviews_review_status_check" CHECK (("review_status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'flagged'::"text"])))
);


ALTER TABLE "public"."visit_reviews" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."visit_sync_flags" (
    "visit_id" bigint NOT NULL,
    "reason" "text" NOT NULL,
    "detail" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone
);


ALTER TABLE "public"."visit_sync_flags" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."visits_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."visits_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."visits_id_seq" OWNED BY "public"."visits"."id";



CREATE OR REPLACE VIEW "public"."visits_recent" AS
SELECT
    NULL::bigint AS "id",
    NULL::"date" AS "visit_date",
    NULL::"text" AS "service_type",
    NULL::"text" AS "client_name",
    NULL::"text" AS "address",
    NULL::"text" AS "zone",
    NULL::"text" AS "visit_status",
    NULL::boolean AS "is_gps_confirmed",
    NULL::timestamp with time zone AS "actual_arrival_at",
    NULL::timestamp with time zone AS "actual_departure_at",
    NULL::"text" AS "vehicle_name",
    NULL::"text" AS "assigned_to";


ALTER VIEW "public"."visits_recent" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."visits_with_review" WITH ("security_invoker"='true') AS
 SELECT "v"."id",
    "v"."client_id",
    "v"."property_id",
    "v"."job_id",
    "v"."vehicle_id",
    "v"."visit_date",
    "v"."start_at",
    "v"."end_at",
    "v"."completed_at",
    "v"."duration_minutes",
    "v"."title",
    "v"."service_type",
    "v"."visit_status",
    "v"."actual_arrival_at",
    "v"."actual_departure_at",
    "v"."is_gps_confirmed",
    "v"."created_at",
    "v"."updated_at",
    "v"."invoice_id",
    "v"."completed_by",
    COALESCE("vr"."review_status", 'pending'::"text") AS "review_status",
    "vr"."reviewed_at",
    "vr"."reviewed_by",
    COALESCE("vr"."bonus_status", 'pending'::"text") AS "bonus_status",
    "vr"."bonus_decided_at",
    "vr"."bonus_decided_by",
    "vr"."bonus_denial_note",
    "vr"."quality_flag_note"
   FROM ("public"."visits" "v"
     LEFT JOIN "public"."visit_reviews" "vr" ON (("vr"."visit_id" = "v"."id")));


ALTER VIEW "public"."visits_with_review" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."visits_with_status" WITH ("security_invoker"='true') AS
 SELECT "v"."id",
    "v"."client_id",
    "v"."property_id",
    "v"."job_id",
    "v"."vehicle_id",
    "v"."visit_date",
    "v"."start_at",
    "v"."end_at",
    "v"."completed_at",
    "v"."duration_minutes",
    "v"."title",
    "v"."service_type",
    "v"."visit_status",
    ("v"."visit_status" = 'completed'::"text") AS "is_complete",
    "v"."actual_arrival_at",
    "v"."actual_departure_at",
    "v"."is_gps_confirmed",
    "v"."created_at",
    "v"."updated_at",
    "v"."invoice_id",
    "v"."completed_by",
    "c"."name" AS "client_name",
    "p"."zone",
    "veh"."name" AS "vehicle_name",
    "sc"."frequency_days",
        CASE
            WHEN ("v"."visit_status" = 'completed'::"text") THEN 'completed'::"text"
            WHEN (("v"."visit_date" < CURRENT_DATE) AND ("v"."visit_status" <> 'completed'::"text")) THEN 'late'::"text"
            WHEN ("v"."visit_date" = CURRENT_DATE) THEN 'today'::"text"
            ELSE 'upcoming'::"text"
        END AS "computed_late_status"
   FROM (((("public"."visits" "v"
     LEFT JOIN "public"."clients" "c" ON (("c"."id" = "v"."client_id")))
     LEFT JOIN "public"."properties" "p" ON ((("p"."client_id" = "c"."id") AND ("p"."is_primary" = true))))
     LEFT JOIN "public"."vehicles" "veh" ON (("veh"."id" = "v"."vehicle_id")))
     LEFT JOIN "public"."service_configs" "sc" ON ((("sc"."client_id" = "v"."client_id") AND ("sc"."service_type" = "v"."service_type"))))
  WHERE ("v"."deleted_at" IS NULL);


ALTER VIEW "public"."visits_with_status" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."webhook_events_log" (
    "id" bigint NOT NULL,
    "source_system" "text" NOT NULL,
    "event_type" "text" NOT NULL,
    "event_id" "text",
    "payload" "jsonb",
    "entity_type" "text",
    "entity_id" bigint,
    "status" "text" DEFAULT 'received'::"text",
    "error_message" "text",
    "processing_ms" integer,
    "processed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."webhook_events_log" OWNER TO "postgres";


COMMENT ON TABLE "public"."webhook_events_log" IS 'Webhook audit trail. 30-day retention. Not a business table.';



ALTER TABLE "public"."webhook_events_log" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."webhook_events_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."webhook_tokens" (
    "source_system" "text" NOT NULL,
    "access_token" "text" NOT NULL,
    "refresh_token" "text",
    "client_id" "text",
    "client_secret" "text",
    "expires_at" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."webhook_tokens" OWNER TO "postgres";


COMMENT ON TABLE "public"."webhook_tokens" IS 'OAuth token cache for webhook handlers. Jobber tokens expire every 2h; refreshed in-place by Edge Functions.';



CREATE TABLE IF NOT EXISTS "public"."zones" (
    "code" "text" NOT NULL,
    "label" "text" NOT NULL,
    "color_hex" "text" NOT NULL,
    "color_token" "text",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "id" bigint NOT NULL,
    CONSTRAINT "zones_color_hex_check" CHECK (("color_hex" ~ '^#[0-9A-Fa-f]{6}$'::"text"))
);


ALTER TABLE "public"."zones" OWNER TO "postgres";


COMMENT ON TABLE "public"."zones" IS 'Operational zone reference data — codes used by public.properties.zone, plus display label + hex color for app rendering. Seeded 2026-05-27. Edits go through ops/Fred; audit trigger captures changes.';



COMMENT ON COLUMN "public"."zones"."code" IS 'Zone code matching public.properties.zone values (SOUTH, NMB, etc.). No FK because legacy properties.zone may carry strings not yet in this table.';



COMMENT ON COLUMN "public"."zones"."color_hex" IS '#RRGGBB display color used by Calendar + other zone-aware UIs.';



COMMENT ON COLUMN "public"."zones"."color_token" IS 'Original Airtable color token name (blueBright, tealLight2, etc.). Kept for AT round-trip; harmless after AT sunset.';



ALTER TABLE "public"."zones" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."zones_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE OR REPLACE VIEW "public"."zones_with_usage" WITH ("security_invoker"='true') AS
 SELECT "z"."id",
    "z"."code",
    "z"."label",
    "z"."color_hex",
    "z"."color_token",
    "z"."sort_order",
    "z"."is_active",
    "z"."created_at",
    "z"."updated_at",
    COALESCE("p"."n_properties", 0) AS "n_properties"
   FROM ("public"."zones" "z"
     LEFT JOIN ( SELECT "properties"."zone_id",
            ("count"(*))::integer AS "n_properties"
           FROM "public"."properties"
          WHERE ("properties"."zone_id" IS NOT NULL)
          GROUP BY "properties"."zone_id") "p" ON (("p"."zone_id" = "z"."id")));


ALTER VIEW "public"."zones_with_usage" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "raw"."jobber_pull_clients" (
    "id" bigint NOT NULL,
    "data" "jsonb" NOT NULL,
    "pulled_at" timestamp with time zone DEFAULT "now"(),
    "ingested_at" timestamp with time zone DEFAULT "now"(),
    "needs_populate" boolean DEFAULT false
);


ALTER TABLE "raw"."jobber_pull_clients" OWNER TO "postgres";


ALTER TABLE "raw"."jobber_pull_clients" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "raw"."jobber_pull_clients_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "raw"."jobber_pull_invoices" (
    "id" bigint NOT NULL,
    "data" "jsonb" NOT NULL,
    "pulled_at" timestamp with time zone DEFAULT "now"(),
    "ingested_at" timestamp with time zone DEFAULT "now"(),
    "needs_populate" boolean DEFAULT false
);


ALTER TABLE "raw"."jobber_pull_invoices" OWNER TO "postgres";


ALTER TABLE "raw"."jobber_pull_invoices" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "raw"."jobber_pull_invoices_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "raw"."jobber_pull_jobs" (
    "id" bigint NOT NULL,
    "data" "jsonb" NOT NULL,
    "pulled_at" timestamp with time zone DEFAULT "now"(),
    "ingested_at" timestamp with time zone DEFAULT "now"(),
    "needs_populate" boolean DEFAULT false
);


ALTER TABLE "raw"."jobber_pull_jobs" OWNER TO "postgres";


ALTER TABLE "raw"."jobber_pull_jobs" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "raw"."jobber_pull_jobs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "raw"."jobber_pull_line_items" (
    "id" bigint NOT NULL,
    "data" "jsonb" NOT NULL,
    "pulled_at" timestamp with time zone DEFAULT "now"(),
    "ingested_at" timestamp with time zone DEFAULT "now"(),
    "needs_populate" boolean DEFAULT false
);


ALTER TABLE "raw"."jobber_pull_line_items" OWNER TO "postgres";


ALTER TABLE "raw"."jobber_pull_line_items" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "raw"."jobber_pull_line_items_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "raw"."jobber_pull_properties" (
    "id" bigint NOT NULL,
    "data" "jsonb" NOT NULL,
    "pulled_at" timestamp with time zone DEFAULT "now"(),
    "ingested_at" timestamp with time zone DEFAULT "now"(),
    "needs_populate" boolean DEFAULT false
);


ALTER TABLE "raw"."jobber_pull_properties" OWNER TO "postgres";


ALTER TABLE "raw"."jobber_pull_properties" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "raw"."jobber_pull_properties_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "raw"."jobber_pull_quotes" (
    "id" bigint NOT NULL,
    "data" "jsonb" NOT NULL,
    "pulled_at" timestamp with time zone DEFAULT "now"(),
    "ingested_at" timestamp with time zone DEFAULT "now"(),
    "needs_populate" boolean DEFAULT false
);


ALTER TABLE "raw"."jobber_pull_quotes" OWNER TO "postgres";


ALTER TABLE "raw"."jobber_pull_quotes" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "raw"."jobber_pull_quotes_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "raw"."jobber_pull_users" (
    "id" bigint NOT NULL,
    "data" "jsonb" NOT NULL,
    "pulled_at" timestamp with time zone DEFAULT "now"(),
    "ingested_at" timestamp with time zone DEFAULT "now"(),
    "needs_populate" boolean DEFAULT false
);


ALTER TABLE "raw"."jobber_pull_users" OWNER TO "postgres";


ALTER TABLE "raw"."jobber_pull_users" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "raw"."jobber_pull_users_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "raw"."jobber_pull_visits" (
    "id" bigint NOT NULL,
    "data" "jsonb" NOT NULL,
    "pulled_at" timestamp with time zone DEFAULT "now"(),
    "ingested_at" timestamp with time zone DEFAULT "now"(),
    "needs_populate" boolean DEFAULT false
);


ALTER TABLE "raw"."jobber_pull_visits" OWNER TO "postgres";


ALTER TABLE "raw"."jobber_pull_visits" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "raw"."jobber_pull_visits_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "audit"."logs" ATTACH PARTITION "audit"."logs_default" DEFAULT;



ALTER TABLE ONLY "audit"."logs" ATTACH PARTITION "audit"."logs_p20260201" FOR VALUES FROM ('2026-02-01 00:00:00+00') TO ('2026-03-01 00:00:00+00');



ALTER TABLE ONLY "audit"."logs" ATTACH PARTITION "audit"."logs_p20260301" FOR VALUES FROM ('2026-03-01 00:00:00+00') TO ('2026-04-01 00:00:00+00');



ALTER TABLE ONLY "audit"."logs" ATTACH PARTITION "audit"."logs_p20260401" FOR VALUES FROM ('2026-04-01 00:00:00+00') TO ('2026-05-01 00:00:00+00');



ALTER TABLE ONLY "audit"."logs" ATTACH PARTITION "audit"."logs_p20260501" FOR VALUES FROM ('2026-05-01 00:00:00+00') TO ('2026-06-01 00:00:00+00');



ALTER TABLE ONLY "audit"."logs" ATTACH PARTITION "audit"."logs_p20260601" FOR VALUES FROM ('2026-06-01 00:00:00+00') TO ('2026-07-01 00:00:00+00');



ALTER TABLE ONLY "audit"."logs" ATTACH PARTITION "audit"."logs_p20260701" FOR VALUES FROM ('2026-07-01 00:00:00+00') TO ('2026-08-01 00:00:00+00');



ALTER TABLE ONLY "audit"."logs" ATTACH PARTITION "audit"."logs_p20260801" FOR VALUES FROM ('2026-08-01 00:00:00+00') TO ('2026-09-01 00:00:00+00');



ALTER TABLE ONLY "audit"."logs" ATTACH PARTITION "audit"."logs_p20260901" FOR VALUES FROM ('2026-09-01 00:00:00+00') TO ('2026-10-01 00:00:00+00');



ALTER TABLE ONLY "public"."clients" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."clients_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."derm_manifests" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."derm_manifests_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."employees" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."employees_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."gdos" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."gdos_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."inspections" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."inspections_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."invoices" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."invoices_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."jobber_oversized_attachments" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."jobber_oversized_attachments_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."jobs" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."jobs_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."line_items" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."line_items_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."notes" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."notes_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."photo_links" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."photo_links_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."photos" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."photos_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."properties" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."properties_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."quotes" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."quotes_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."service_configs" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."service_configs_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."sync_log" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."sync_log_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."vehicles" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."vehicles_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."visits" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."visits_id_seq"'::"regclass");



ALTER TABLE ONLY "audit"."logs"
    ADD CONSTRAINT "logs_pkey" PRIMARY KEY ("id", "changed_at");



ALTER TABLE ONLY "audit"."logs_default"
    ADD CONSTRAINT "logs_default_pkey" PRIMARY KEY ("id", "changed_at");



ALTER TABLE ONLY "audit"."logs_p20260201"
    ADD CONSTRAINT "logs_p20260201_pkey" PRIMARY KEY ("id", "changed_at");



ALTER TABLE ONLY "audit"."logs_p20260301"
    ADD CONSTRAINT "logs_p20260301_pkey" PRIMARY KEY ("id", "changed_at");



ALTER TABLE ONLY "audit"."logs_p20260401"
    ADD CONSTRAINT "logs_p20260401_pkey" PRIMARY KEY ("id", "changed_at");



ALTER TABLE ONLY "audit"."logs_p20260501"
    ADD CONSTRAINT "logs_p20260501_pkey" PRIMARY KEY ("id", "changed_at");



ALTER TABLE ONLY "audit"."logs_p20260601"
    ADD CONSTRAINT "logs_p20260601_pkey" PRIMARY KEY ("id", "changed_at");



ALTER TABLE ONLY "audit"."logs_p20260701"
    ADD CONSTRAINT "logs_p20260701_pkey" PRIMARY KEY ("id", "changed_at");



ALTER TABLE ONLY "audit"."logs_p20260801"
    ADD CONSTRAINT "logs_p20260801_pkey" PRIMARY KEY ("id", "changed_at");



ALTER TABLE ONLY "audit"."logs_p20260901"
    ADD CONSTRAINT "logs_p20260901_pkey" PRIMARY KEY ("id", "changed_at");



ALTER TABLE ONLY "public"."app_shift_reviews"
    ADD CONSTRAINT "app_shift_reviews_pkey" PRIMARY KEY ("external_employee_id", "shift_date");



ALTER TABLE ONLY "public"."app_visit_reviews"
    ADD CONSTRAINT "app_visit_reviews_pkey" PRIMARY KEY ("external_visit_id");



ALTER TABLE ONLY "public"."client_contacts"
    ADD CONSTRAINT "client_contacts_client_id_contact_role_key" UNIQUE ("client_id", "contact_role");



ALTER TABLE ONLY "public"."client_contacts"
    ADD CONSTRAINT "client_contacts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_groups"
    ADD CONSTRAINT "client_groups_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."client_groups"
    ADD CONSTRAINT "client_groups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_locations"
    ADD CONSTRAINT "client_locations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clients"
    ADD CONSTRAINT "clients_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."derm_email_sends"
    ADD CONSTRAINT "derm_email_sends_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."derm_manifest_number_proposals"
    ADD CONSTRAINT "derm_manifest_number_proposal_manifest_id_proposed_number_s_key" UNIQUE ("manifest_id", "proposed_number", "source");



ALTER TABLE ONLY "public"."derm_manifest_number_proposals"
    ADD CONSTRAINT "derm_manifest_number_proposals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."derm_manifests"
    ADD CONSTRAINT "derm_manifests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."disposal_facilities"
    ADD CONSTRAINT "disposal_facilities_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."disposal_facilities"
    ADD CONSTRAINT "disposal_facilities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_full_name_key" UNIQUE ("full_name");



ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."entity_source_links"
    ADD CONSTRAINT "entity_source_links_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gdos"
    ADD CONSTRAINT "gdos_client_gdo_unique" UNIQUE ("client_id", "gdo_number");



ALTER TABLE ONLY "public"."gdos"
    ADD CONSTRAINT "gdos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."inspections"
    ADD CONSTRAINT "inspections_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."jobber_oversized_attachments"
    ADD CONSTRAINT "jobber_oversized_attachments_attachment_jobber_id_key" UNIQUE ("attachment_jobber_id");



ALTER TABLE ONLY "public"."jobber_oversized_attachments"
    ADD CONSTRAINT "jobber_oversized_attachments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."line_items"
    ADD CONSTRAINT "line_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."manifest_visits"
    ADD CONSTRAINT "manifest_visits_pkey" PRIMARY KEY ("manifest_id", "visit_id");



ALTER TABLE ONLY "public"."municipality_regulators"
    ADD CONSTRAINT "municipality_regulators_municipality_key" UNIQUE ("municipality");



ALTER TABLE ONLY "public"."municipality_regulators"
    ADD CONSTRAINT "municipality_regulators_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notes"
    ADD CONSTRAINT "notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."photo_classifications"
    ADD CONSTRAINT "photo_classifications_pkey" PRIMARY KEY ("photo_link_id");



ALTER TABLE ONLY "public"."photo_links"
    ADD CONSTRAINT "photo_links_photo_id_entity_type_entity_id_role_key" UNIQUE ("photo_id", "entity_type", "entity_id", "role");



ALTER TABLE ONLY "public"."photo_links"
    ADD CONSTRAINT "photo_links_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."photos"
    ADD CONSTRAINT "photos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."photos"
    ADD CONSTRAINT "photos_storage_path_key" UNIQUE ("storage_path");



ALTER TABLE ONLY "public"."properties"
    ADD CONSTRAINT "properties_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."quotes"
    ADD CONSTRAINT "quotes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."service_configs"
    ADD CONSTRAINT "service_configs_client_id_service_type_key" UNIQUE ("client_id", "service_type");



ALTER TABLE ONLY "public"."service_configs"
    ADD CONSTRAINT "service_configs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."service_line_items"
    ADD CONSTRAINT "service_line_items_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."service_line_items"
    ADD CONSTRAINT "service_line_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."shift_reviews"
    ADD CONSTRAINT "shift_reviews_pkey" PRIMARY KEY ("employee_id", "shift_date");



ALTER TABLE ONLY "public"."sync_cursors"
    ADD CONSTRAINT "sync_cursors_pkey" PRIMARY KEY ("entity");



ALTER TABLE ONLY "public"."sync_log"
    ADD CONSTRAINT "sync_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vehicle_telemetry_readings"
    ADD CONSTRAINT "vehicle_fuel_readings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vehicle_telemetry_readings"
    ADD CONSTRAINT "vehicle_telemetry_readings_vehicle_time_uniq" UNIQUE ("vehicle_id", "recorded_at");



ALTER TABLE ONLY "public"."vehicles"
    ADD CONSTRAINT "vehicles_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."vehicles"
    ADD CONSTRAINT "vehicles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vehicles"
    ADD CONSTRAINT "vehicles_vin_key" UNIQUE ("vin");



ALTER TABLE ONLY "public"."visit_assignments"
    ADD CONSTRAINT "visit_assignments_pkey" PRIMARY KEY ("visit_id", "employee_id");



ALTER TABLE ONLY "public"."visit_locations"
    ADD CONSTRAINT "visit_locations_pkey" PRIMARY KEY ("visit_id", "client_location_id");



ALTER TABLE ONLY "public"."visit_recommendations"
    ADD CONSTRAINT "visit_recommendations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."visit_recommendations"
    ADD CONSTRAINT "visit_recommendations_visit_id_label_key" UNIQUE ("visit_id", "label");



ALTER TABLE ONLY "public"."visit_reviews"
    ADD CONSTRAINT "visit_reviews_pkey" PRIMARY KEY ("visit_id");



ALTER TABLE ONLY "public"."visit_sync_flags"
    ADD CONSTRAINT "visit_sync_flags_pkey" PRIMARY KEY ("visit_id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_public_id_unique" UNIQUE ("public_id");



ALTER TABLE ONLY "public"."webhook_events_log"
    ADD CONSTRAINT "webhook_events_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."webhook_tokens"
    ADD CONSTRAINT "webhook_tokens_pkey" PRIMARY KEY ("source_system");



ALTER TABLE ONLY "public"."zones"
    ADD CONSTRAINT "zones_code_unique" UNIQUE ("code");



ALTER TABLE ONLY "public"."zones"
    ADD CONSTRAINT "zones_pkey" PRIMARY KEY ("id");



CREATE INDEX "audit_logs_changed_at_idx" ON ONLY "audit"."logs" USING "btree" ("changed_at" DESC);



CREATE INDEX "audit_logs_changed_by_idx" ON ONLY "audit"."logs" USING "btree" ("changed_by", "changed_at" DESC) WHERE ("changed_by" IS NOT NULL);



CREATE INDEX "audit_logs_record_id_idx" ON ONLY "audit"."logs" USING "btree" ((("record_pk" ->> 'id'::"text"))) WHERE ("record_pk" ? 'id'::"text");



CREATE INDEX "audit_logs_table_changed_idx" ON ONLY "audit"."logs" USING "btree" ("table_name", "changed_at" DESC);



CREATE INDEX "idx_audit_logs_app_source" ON ONLY "audit"."logs" USING "btree" ("app_source");



CREATE INDEX "logs_default_app_source_idx" ON "audit"."logs_default" USING "btree" ("app_source");



CREATE INDEX "logs_default_changed_at_idx" ON "audit"."logs_default" USING "btree" ("changed_at" DESC);



CREATE INDEX "logs_default_changed_by_changed_at_idx" ON "audit"."logs_default" USING "btree" ("changed_by", "changed_at" DESC) WHERE ("changed_by" IS NOT NULL);



CREATE INDEX "logs_default_expr_idx" ON "audit"."logs_default" USING "btree" ((("record_pk" ->> 'id'::"text"))) WHERE ("record_pk" ? 'id'::"text");



CREATE INDEX "logs_default_table_name_changed_at_idx" ON "audit"."logs_default" USING "btree" ("table_name", "changed_at" DESC);



CREATE INDEX "logs_p20260201_app_source_idx" ON "audit"."logs_p20260201" USING "btree" ("app_source");



CREATE INDEX "logs_p20260201_changed_at_idx" ON "audit"."logs_p20260201" USING "btree" ("changed_at" DESC);



CREATE INDEX "logs_p20260201_changed_by_changed_at_idx" ON "audit"."logs_p20260201" USING "btree" ("changed_by", "changed_at" DESC) WHERE ("changed_by" IS NOT NULL);



CREATE INDEX "logs_p20260201_expr_idx" ON "audit"."logs_p20260201" USING "btree" ((("record_pk" ->> 'id'::"text"))) WHERE ("record_pk" ? 'id'::"text");



CREATE INDEX "logs_p20260201_table_name_changed_at_idx" ON "audit"."logs_p20260201" USING "btree" ("table_name", "changed_at" DESC);



CREATE INDEX "logs_p20260301_app_source_idx" ON "audit"."logs_p20260301" USING "btree" ("app_source");



CREATE INDEX "logs_p20260301_changed_at_idx" ON "audit"."logs_p20260301" USING "btree" ("changed_at" DESC);



CREATE INDEX "logs_p20260301_changed_by_changed_at_idx" ON "audit"."logs_p20260301" USING "btree" ("changed_by", "changed_at" DESC) WHERE ("changed_by" IS NOT NULL);



CREATE INDEX "logs_p20260301_expr_idx" ON "audit"."logs_p20260301" USING "btree" ((("record_pk" ->> 'id'::"text"))) WHERE ("record_pk" ? 'id'::"text");



CREATE INDEX "logs_p20260301_table_name_changed_at_idx" ON "audit"."logs_p20260301" USING "btree" ("table_name", "changed_at" DESC);



CREATE INDEX "logs_p20260401_app_source_idx" ON "audit"."logs_p20260401" USING "btree" ("app_source");



CREATE INDEX "logs_p20260401_changed_at_idx" ON "audit"."logs_p20260401" USING "btree" ("changed_at" DESC);



CREATE INDEX "logs_p20260401_changed_by_changed_at_idx" ON "audit"."logs_p20260401" USING "btree" ("changed_by", "changed_at" DESC) WHERE ("changed_by" IS NOT NULL);



CREATE INDEX "logs_p20260401_expr_idx" ON "audit"."logs_p20260401" USING "btree" ((("record_pk" ->> 'id'::"text"))) WHERE ("record_pk" ? 'id'::"text");



CREATE INDEX "logs_p20260401_table_name_changed_at_idx" ON "audit"."logs_p20260401" USING "btree" ("table_name", "changed_at" DESC);



CREATE INDEX "logs_p20260501_app_source_idx" ON "audit"."logs_p20260501" USING "btree" ("app_source");



CREATE INDEX "logs_p20260501_changed_at_idx" ON "audit"."logs_p20260501" USING "btree" ("changed_at" DESC);



CREATE INDEX "logs_p20260501_changed_by_changed_at_idx" ON "audit"."logs_p20260501" USING "btree" ("changed_by", "changed_at" DESC) WHERE ("changed_by" IS NOT NULL);



CREATE INDEX "logs_p20260501_expr_idx" ON "audit"."logs_p20260501" USING "btree" ((("record_pk" ->> 'id'::"text"))) WHERE ("record_pk" ? 'id'::"text");



CREATE INDEX "logs_p20260501_table_name_changed_at_idx" ON "audit"."logs_p20260501" USING "btree" ("table_name", "changed_at" DESC);



CREATE INDEX "logs_p20260601_app_source_idx" ON "audit"."logs_p20260601" USING "btree" ("app_source");



CREATE INDEX "logs_p20260601_changed_at_idx" ON "audit"."logs_p20260601" USING "btree" ("changed_at" DESC);



CREATE INDEX "logs_p20260601_changed_by_changed_at_idx" ON "audit"."logs_p20260601" USING "btree" ("changed_by", "changed_at" DESC) WHERE ("changed_by" IS NOT NULL);



CREATE INDEX "logs_p20260601_expr_idx" ON "audit"."logs_p20260601" USING "btree" ((("record_pk" ->> 'id'::"text"))) WHERE ("record_pk" ? 'id'::"text");



CREATE INDEX "logs_p20260601_table_name_changed_at_idx" ON "audit"."logs_p20260601" USING "btree" ("table_name", "changed_at" DESC);



CREATE INDEX "logs_p20260701_app_source_idx" ON "audit"."logs_p20260701" USING "btree" ("app_source");



CREATE INDEX "logs_p20260701_changed_at_idx" ON "audit"."logs_p20260701" USING "btree" ("changed_at" DESC);



CREATE INDEX "logs_p20260701_changed_by_changed_at_idx" ON "audit"."logs_p20260701" USING "btree" ("changed_by", "changed_at" DESC) WHERE ("changed_by" IS NOT NULL);



CREATE INDEX "logs_p20260701_expr_idx" ON "audit"."logs_p20260701" USING "btree" ((("record_pk" ->> 'id'::"text"))) WHERE ("record_pk" ? 'id'::"text");



CREATE INDEX "logs_p20260701_table_name_changed_at_idx" ON "audit"."logs_p20260701" USING "btree" ("table_name", "changed_at" DESC);



CREATE INDEX "logs_p20260801_app_source_idx" ON "audit"."logs_p20260801" USING "btree" ("app_source");



CREATE INDEX "logs_p20260801_changed_at_idx" ON "audit"."logs_p20260801" USING "btree" ("changed_at" DESC);



CREATE INDEX "logs_p20260801_changed_by_changed_at_idx" ON "audit"."logs_p20260801" USING "btree" ("changed_by", "changed_at" DESC) WHERE ("changed_by" IS NOT NULL);



CREATE INDEX "logs_p20260801_expr_idx" ON "audit"."logs_p20260801" USING "btree" ((("record_pk" ->> 'id'::"text"))) WHERE ("record_pk" ? 'id'::"text");



CREATE INDEX "logs_p20260801_table_name_changed_at_idx" ON "audit"."logs_p20260801" USING "btree" ("table_name", "changed_at" DESC);



CREATE INDEX "logs_p20260901_app_source_idx" ON "audit"."logs_p20260901" USING "btree" ("app_source");



CREATE INDEX "logs_p20260901_changed_at_idx" ON "audit"."logs_p20260901" USING "btree" ("changed_at" DESC);



CREATE INDEX "logs_p20260901_changed_by_changed_at_idx" ON "audit"."logs_p20260901" USING "btree" ("changed_by", "changed_at" DESC) WHERE ("changed_by" IS NOT NULL);



CREATE INDEX "logs_p20260901_expr_idx" ON "audit"."logs_p20260901" USING "btree" ((("record_pk" ->> 'id'::"text"))) WHERE ("record_pk" ? 'id'::"text");



CREATE INDEX "logs_p20260901_table_name_changed_at_idx" ON "audit"."logs_p20260901" USING "btree" ("table_name", "changed_at" DESC);



CREATE INDEX "clients_class_idx" ON "public"."clients" USING "btree" ("client_class") WHERE ("client_class" IS NOT NULL);



CREATE INDEX "derm_email_sends_client_id_idx" ON "public"."derm_email_sends" USING "btree" ("client_id");



CREATE INDEX "derm_email_sends_manifest_id_idx" ON "public"."derm_email_sends" USING "btree" ("manifest_id");



CREATE INDEX "derm_email_sends_real_sent_idx" ON "public"."derm_email_sends" USING "btree" ("manifest_id", "client_id", "sent_at" DESC) WHERE (("status" = 'sent'::"text") AND ("is_test" = false));



CREATE UNIQUE INDEX "derm_manifests_client_wm_unique" ON "public"."derm_manifests" USING "btree" ("client_id", "white_manifest_number") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "derm_manifests_client_yt_unique" ON "public"."derm_manifests" USING "btree" ("client_id", "yellow_ticket_number") WHERE ("deleted_at" IS NULL);



CREATE UNIQUE INDEX "gdos_client_location_id_uniq" ON "public"."gdos" USING "btree" ("client_location_id") WHERE ("client_location_id" IS NOT NULL);



CREATE INDEX "idx_app_shift_reviews_bonus_status" ON "public"."app_shift_reviews" USING "btree" ("bonus_status");



CREATE INDEX "idx_app_shift_reviews_review_status_date" ON "public"."app_shift_reviews" USING "btree" ("review_status", "shift_date" DESC);



CREATE INDEX "idx_app_visit_reviews_bonus_status" ON "public"."app_visit_reviews" USING "btree" ("bonus_status");



CREATE INDEX "idx_app_visit_reviews_review_status_visit" ON "public"."app_visit_reviews" USING "btree" ("review_status", "external_visit_id" DESC);



CREATE INDEX "idx_client_locations_client_id" ON "public"."client_locations" USING "btree" ("client_id");



CREATE INDEX "idx_client_locations_property_id" ON "public"."client_locations" USING "btree" ("property_id");



CREATE INDEX "idx_clients_code" ON "public"."clients" USING "btree" ("client_code");



CREATE INDEX "idx_clients_group_id" ON "public"."clients" USING "btree" ("group_id") WHERE ("group_id" IS NOT NULL);



CREATE INDEX "idx_clients_name" ON "public"."clients" USING "btree" ("name");



CREATE INDEX "idx_clients_status" ON "public"."clients" USING "btree" ("status");



CREATE INDEX "idx_derm_client" ON "public"."derm_manifests" USING "btree" ("client_id");



CREATE INDEX "idx_derm_date" ON "public"."derm_manifests" USING "btree" ("service_date" DESC);



CREATE INDEX "idx_derm_manifests_derm_address_no" ON "public"."derm_manifests" USING "btree" ("derm_address_no") WHERE ("derm_address_no" IS NOT NULL);



CREATE INDEX "idx_derm_manifests_gdo_id" ON "public"."derm_manifests" USING "btree" ("gdo_id");



CREATE INDEX "idx_derm_unsent_city" ON "public"."derm_manifests" USING "btree" ("sent_to_city") WHERE (NOT "sent_to_city");



CREATE INDEX "idx_derm_unsent_client" ON "public"."derm_manifests" USING "btree" ("sent_to_client") WHERE (NOT "sent_to_client");



CREATE INDEX "idx_dmnp_manifest" ON "public"."derm_manifest_number_proposals" USING "btree" ("manifest_id");



CREATE INDEX "idx_dmnp_status" ON "public"."derm_manifest_number_proposals" USING "btree" ("review_status", "created_at" DESC);



CREATE INDEX "idx_employees_role" ON "public"."employees" USING "btree" ("role");



CREATE INDEX "idx_employees_status" ON "public"."employees" USING "btree" ("status");



CREATE INDEX "idx_esl_entity" ON "public"."entity_source_links" USING "btree" ("entity_type", "entity_id");



CREATE UNIQUE INDEX "idx_esl_entity_source" ON "public"."entity_source_links" USING "btree" ("entity_type", "entity_id", "source_system");



CREATE INDEX "idx_esl_source" ON "public"."entity_source_links" USING "btree" ("source_system", "source_id");



CREATE UNIQUE INDEX "idx_esl_source_id" ON "public"."entity_source_links" USING "btree" ("entity_type", "source_system", "source_id");



CREATE INDEX "idx_gdos_client_id" ON "public"."gdos" USING "btree" ("client_id");



CREATE INDEX "idx_gdos_client_location_id" ON "public"."gdos" USING "btree" ("client_location_id");



CREATE INDEX "idx_gdos_gdo_number" ON "public"."gdos" USING "btree" ("gdo_number");



CREATE INDEX "idx_inspections_date" ON "public"."inspections" USING "btree" ("shift_date" DESC);



CREATE INDEX "idx_inspections_employee" ON "public"."inspections" USING "btree" ("employee_id");



CREATE INDEX "idx_inspections_issues" ON "public"."inspections" USING "btree" ("has_issue") WHERE "has_issue";



CREATE UNIQUE INDEX "idx_inspections_shift_unique" ON "public"."inspections" USING "btree" ("shift_date", "vehicle_id", "employee_id", "inspection_type") WHERE (("vehicle_id" IS NOT NULL) AND ("employee_id" IS NOT NULL));



CREATE INDEX "idx_inspections_type" ON "public"."inspections" USING "btree" ("inspection_type");



CREATE INDEX "idx_inspections_vehicle" ON "public"."inspections" USING "btree" ("vehicle_id");



CREATE INDEX "idx_invoices_client" ON "public"."invoices" USING "btree" ("client_id");



CREATE INDEX "idx_invoices_due" ON "public"."invoices" USING "btree" ("due_date");



CREATE INDEX "idx_invoices_job" ON "public"."invoices" USING "btree" ("job_id");



CREATE INDEX "idx_invoices_outstanding" ON "public"."invoices" USING "btree" ("outstanding_amount") WHERE ("outstanding_amount" > (0)::numeric);



CREATE INDEX "idx_invoices_status" ON "public"."invoices" USING "btree" ("invoice_status");



CREATE INDEX "idx_jobber_oversized_client" ON "public"."jobber_oversized_attachments" USING "btree" ("client_id");



CREATE INDEX "idx_jobber_oversized_visit" ON "public"."jobber_oversized_attachments" USING "btree" ("visit_id");



CREATE INDEX "idx_jobs_client" ON "public"."jobs" USING "btree" ("client_id");



CREATE INDEX "idx_jobs_property" ON "public"."jobs" USING "btree" ("property_id");



CREATE INDEX "idx_jobs_quote" ON "public"."jobs" USING "btree" ("quote_id");



CREATE INDEX "idx_jobs_start" ON "public"."jobs" USING "btree" ("start_at");



CREATE INDEX "idx_jobs_status" ON "public"."jobs" USING "btree" ("job_status");



CREATE INDEX "idx_line_items_invoice_id" ON "public"."line_items" USING "btree" ("invoice_id") WHERE ("invoice_id" IS NOT NULL);



CREATE INDEX "idx_line_items_visit" ON "public"."line_items" USING "btree" ("visit_id");



CREATE INDEX "idx_lineitems_job" ON "public"."line_items" USING "btree" ("job_id");



CREATE INDEX "idx_lineitems_quote" ON "public"."line_items" USING "btree" ("quote_id");



CREATE INDEX "idx_manifests_disposal_fac" ON "public"."derm_manifests" USING "btree" ("disposal_facility_id") WHERE ("disposal_facility_id" IS NOT NULL);



CREATE INDEX "idx_mv_visit" ON "public"."manifest_visits" USING "btree" ("visit_id");



CREATE INDEX "idx_notes_author" ON "public"."notes" USING "btree" ("author_employee_id");



CREATE INDEX "idx_notes_client" ON "public"."notes" USING "btree" ("client_id", "note_date" DESC);



CREATE INDEX "idx_notes_job" ON "public"."notes" USING "btree" ("job_id");



CREATE INDEX "idx_notes_property" ON "public"."notes" USING "btree" ("property_id") WHERE ("property_id" IS NOT NULL);



CREATE INDEX "idx_notes_source" ON "public"."notes" USING "btree" ("source");



CREATE INDEX "idx_notes_visit" ON "public"."notes" USING "btree" ("visit_id") WHERE ("visit_id" IS NOT NULL);



CREATE INDEX "idx_photo_links_entity" ON "public"."photo_links" USING "btree" ("entity_type", "entity_id");



CREATE INDEX "idx_photo_links_photo" ON "public"."photo_links" USING "btree" ("photo_id");



CREATE INDEX "idx_photos_uploaded_by" ON "public"."photos" USING "btree" ("uploaded_by_employee_id");



CREATE INDEX "idx_properties_client" ON "public"."properties" USING "btree" ("client_id");



CREATE INDEX "idx_properties_disposal_fac" ON "public"."properties" USING "btree" ("default_disposal_facility_id") WHERE ("default_disposal_facility_id" IS NOT NULL);



CREATE INDEX "idx_quotes_client" ON "public"."quotes" USING "btree" ("client_id");



CREATE INDEX "idx_quotes_property" ON "public"."quotes" USING "btree" ("property_id");



CREATE INDEX "idx_quotes_status" ON "public"."quotes" USING "btree" ("quote_status");



CREATE INDEX "idx_service_configs_property_id" ON "public"."service_configs" USING "btree" ("property_id");



CREATE INDEX "idx_shift_reviews_employee" ON "public"."shift_reviews" USING "btree" ("employee_id");



CREATE INDEX "idx_svcconfig_client" ON "public"."service_configs" USING "btree" ("client_id");



CREATE INDEX "idx_svcconfig_type" ON "public"."service_configs" USING "btree" ("service_type");



CREATE INDEX "idx_synclog_source" ON "public"."sync_log" USING "btree" ("sync_source");



CREATE INDEX "idx_synclog_started" ON "public"."sync_log" USING "btree" ("started_at" DESC);



CREATE INDEX "idx_synclog_status" ON "public"."sync_log" USING "btree" ("status");



CREATE INDEX "idx_va_employee" ON "public"."visit_assignments" USING "btree" ("employee_id");



CREATE INDEX "idx_visit_locations_location" ON "public"."visit_locations" USING "btree" ("client_location_id");



CREATE INDEX "idx_visit_recommendations_visit_id" ON "public"."visit_recommendations" USING "btree" ("visit_id");



CREATE INDEX "idx_visits_client" ON "public"."visits" USING "btree" ("client_id");



CREATE INDEX "idx_visits_date" ON "public"."visits" USING "btree" ("visit_date" DESC);



CREATE INDEX "idx_visits_invoice" ON "public"."visits" USING "btree" ("invoice_id");



CREATE INDEX "idx_visits_job" ON "public"."visits" USING "btree" ("job_id");



CREATE INDEX "idx_visits_property" ON "public"."visits" USING "btree" ("property_id");



CREATE INDEX "idx_visits_source_cron_scheduled" ON "public"."visits" USING "btree" ("client_id", "service_type", "visit_date") WHERE (("source" = 'supabase_cron'::"text") AND ("visit_status" = 'scheduled'::"text"));



CREATE INDEX "idx_visits_status" ON "public"."visits" USING "btree" ("visit_status");



CREATE INDEX "idx_visits_type" ON "public"."visits" USING "btree" ("service_type");



CREATE INDEX "idx_visits_vehicle" ON "public"."visits" USING "btree" ("vehicle_id");



CREATE INDEX "idx_vtr_recorded" ON "public"."vehicle_telemetry_readings" USING "btree" ("recorded_at");



CREATE INDEX "idx_vtr_vehicle_time" ON "public"."vehicle_telemetry_readings" USING "btree" ("vehicle_id", "recorded_at" DESC);



CREATE INDEX "idx_wel_created_at" ON "public"."webhook_events_log" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_wel_entity" ON "public"."webhook_events_log" USING "btree" ("entity_type", "entity_id") WHERE ("entity_id" IS NOT NULL);



CREATE INDEX "idx_wel_source_time" ON "public"."webhook_events_log" USING "btree" ("source_system", "created_at" DESC);



CREATE INDEX "idx_wel_status" ON "public"."webhook_events_log" USING "btree" ("status") WHERE ("status" = 'failed'::"text");



CREATE UNIQUE INDEX "photo_classifications_id_idx" ON "public"."photo_classifications" USING "btree" ("id");



CREATE INDEX "photo_classifications_service_phase_idx" ON "public"."photo_classifications" USING "btree" ("service_phase");



CREATE INDEX "properties_zone_id_idx" ON "public"."properties" USING "btree" ("zone_id");



CREATE UNIQUE INDEX "uq_client_locations_client_name" ON "public"."client_locations" USING "btree" ("client_id", "name");



CREATE UNIQUE INDEX "uq_properties_one_primary_per_client" ON "public"."properties" USING "btree" ("client_id") WHERE ("is_primary" = true);



COMMENT ON INDEX "public"."uq_properties_one_primary_per_client" IS 'Each client_id may have at most one is_primary=true property row. Added 2026-05-23f after a 41-client duplicate-primary cleanup. Prevents recurrence from future sync/backfill scripts.';



CREATE INDEX "visit_sync_flags_unresolved_idx" ON "public"."visit_sync_flags" USING "btree" ("created_at") WHERE ("resolved_at" IS NULL);



CREATE INDEX "visits_deleted_at_null_idx" ON "public"."visits" USING "btree" ("visit_date") WHERE ("deleted_at" IS NULL);



CREATE INDEX "visits_service_line_item_id_idx" ON "public"."visits" USING "btree" ("service_line_item_id");



ALTER INDEX "audit"."idx_audit_logs_app_source" ATTACH PARTITION "audit"."logs_default_app_source_idx";



ALTER INDEX "audit"."audit_logs_changed_at_idx" ATTACH PARTITION "audit"."logs_default_changed_at_idx";



ALTER INDEX "audit"."audit_logs_changed_by_idx" ATTACH PARTITION "audit"."logs_default_changed_by_changed_at_idx";



ALTER INDEX "audit"."audit_logs_record_id_idx" ATTACH PARTITION "audit"."logs_default_expr_idx";



ALTER INDEX "audit"."logs_pkey" ATTACH PARTITION "audit"."logs_default_pkey";



ALTER INDEX "audit"."audit_logs_table_changed_idx" ATTACH PARTITION "audit"."logs_default_table_name_changed_at_idx";



ALTER INDEX "audit"."idx_audit_logs_app_source" ATTACH PARTITION "audit"."logs_p20260201_app_source_idx";



ALTER INDEX "audit"."audit_logs_changed_at_idx" ATTACH PARTITION "audit"."logs_p20260201_changed_at_idx";



ALTER INDEX "audit"."audit_logs_changed_by_idx" ATTACH PARTITION "audit"."logs_p20260201_changed_by_changed_at_idx";



ALTER INDEX "audit"."audit_logs_record_id_idx" ATTACH PARTITION "audit"."logs_p20260201_expr_idx";



ALTER INDEX "audit"."logs_pkey" ATTACH PARTITION "audit"."logs_p20260201_pkey";



ALTER INDEX "audit"."audit_logs_table_changed_idx" ATTACH PARTITION "audit"."logs_p20260201_table_name_changed_at_idx";



ALTER INDEX "audit"."idx_audit_logs_app_source" ATTACH PARTITION "audit"."logs_p20260301_app_source_idx";



ALTER INDEX "audit"."audit_logs_changed_at_idx" ATTACH PARTITION "audit"."logs_p20260301_changed_at_idx";



ALTER INDEX "audit"."audit_logs_changed_by_idx" ATTACH PARTITION "audit"."logs_p20260301_changed_by_changed_at_idx";



ALTER INDEX "audit"."audit_logs_record_id_idx" ATTACH PARTITION "audit"."logs_p20260301_expr_idx";



ALTER INDEX "audit"."logs_pkey" ATTACH PARTITION "audit"."logs_p20260301_pkey";



ALTER INDEX "audit"."audit_logs_table_changed_idx" ATTACH PARTITION "audit"."logs_p20260301_table_name_changed_at_idx";



ALTER INDEX "audit"."idx_audit_logs_app_source" ATTACH PARTITION "audit"."logs_p20260401_app_source_idx";



ALTER INDEX "audit"."audit_logs_changed_at_idx" ATTACH PARTITION "audit"."logs_p20260401_changed_at_idx";



ALTER INDEX "audit"."audit_logs_changed_by_idx" ATTACH PARTITION "audit"."logs_p20260401_changed_by_changed_at_idx";



ALTER INDEX "audit"."audit_logs_record_id_idx" ATTACH PARTITION "audit"."logs_p20260401_expr_idx";



ALTER INDEX "audit"."logs_pkey" ATTACH PARTITION "audit"."logs_p20260401_pkey";



ALTER INDEX "audit"."audit_logs_table_changed_idx" ATTACH PARTITION "audit"."logs_p20260401_table_name_changed_at_idx";



ALTER INDEX "audit"."idx_audit_logs_app_source" ATTACH PARTITION "audit"."logs_p20260501_app_source_idx";



ALTER INDEX "audit"."audit_logs_changed_at_idx" ATTACH PARTITION "audit"."logs_p20260501_changed_at_idx";



ALTER INDEX "audit"."audit_logs_changed_by_idx" ATTACH PARTITION "audit"."logs_p20260501_changed_by_changed_at_idx";



ALTER INDEX "audit"."audit_logs_record_id_idx" ATTACH PARTITION "audit"."logs_p20260501_expr_idx";



ALTER INDEX "audit"."logs_pkey" ATTACH PARTITION "audit"."logs_p20260501_pkey";



ALTER INDEX "audit"."audit_logs_table_changed_idx" ATTACH PARTITION "audit"."logs_p20260501_table_name_changed_at_idx";



ALTER INDEX "audit"."idx_audit_logs_app_source" ATTACH PARTITION "audit"."logs_p20260601_app_source_idx";



ALTER INDEX "audit"."audit_logs_changed_at_idx" ATTACH PARTITION "audit"."logs_p20260601_changed_at_idx";



ALTER INDEX "audit"."audit_logs_changed_by_idx" ATTACH PARTITION "audit"."logs_p20260601_changed_by_changed_at_idx";



ALTER INDEX "audit"."audit_logs_record_id_idx" ATTACH PARTITION "audit"."logs_p20260601_expr_idx";



ALTER INDEX "audit"."logs_pkey" ATTACH PARTITION "audit"."logs_p20260601_pkey";



ALTER INDEX "audit"."audit_logs_table_changed_idx" ATTACH PARTITION "audit"."logs_p20260601_table_name_changed_at_idx";



ALTER INDEX "audit"."idx_audit_logs_app_source" ATTACH PARTITION "audit"."logs_p20260701_app_source_idx";



ALTER INDEX "audit"."audit_logs_changed_at_idx" ATTACH PARTITION "audit"."logs_p20260701_changed_at_idx";



ALTER INDEX "audit"."audit_logs_changed_by_idx" ATTACH PARTITION "audit"."logs_p20260701_changed_by_changed_at_idx";



ALTER INDEX "audit"."audit_logs_record_id_idx" ATTACH PARTITION "audit"."logs_p20260701_expr_idx";



ALTER INDEX "audit"."logs_pkey" ATTACH PARTITION "audit"."logs_p20260701_pkey";



ALTER INDEX "audit"."audit_logs_table_changed_idx" ATTACH PARTITION "audit"."logs_p20260701_table_name_changed_at_idx";



ALTER INDEX "audit"."idx_audit_logs_app_source" ATTACH PARTITION "audit"."logs_p20260801_app_source_idx";



ALTER INDEX "audit"."audit_logs_changed_at_idx" ATTACH PARTITION "audit"."logs_p20260801_changed_at_idx";



ALTER INDEX "audit"."audit_logs_changed_by_idx" ATTACH PARTITION "audit"."logs_p20260801_changed_by_changed_at_idx";



ALTER INDEX "audit"."audit_logs_record_id_idx" ATTACH PARTITION "audit"."logs_p20260801_expr_idx";



ALTER INDEX "audit"."logs_pkey" ATTACH PARTITION "audit"."logs_p20260801_pkey";



ALTER INDEX "audit"."audit_logs_table_changed_idx" ATTACH PARTITION "audit"."logs_p20260801_table_name_changed_at_idx";



ALTER INDEX "audit"."idx_audit_logs_app_source" ATTACH PARTITION "audit"."logs_p20260901_app_source_idx";



ALTER INDEX "audit"."audit_logs_changed_at_idx" ATTACH PARTITION "audit"."logs_p20260901_changed_at_idx";



ALTER INDEX "audit"."audit_logs_changed_by_idx" ATTACH PARTITION "audit"."logs_p20260901_changed_by_changed_at_idx";



ALTER INDEX "audit"."audit_logs_record_id_idx" ATTACH PARTITION "audit"."logs_p20260901_expr_idx";



ALTER INDEX "audit"."logs_pkey" ATTACH PARTITION "audit"."logs_p20260901_pkey";



ALTER INDEX "audit"."audit_logs_table_changed_idx" ATTACH PARTITION "audit"."logs_p20260901_table_name_changed_at_idx";



CREATE OR REPLACE VIEW "public"."client_services_flat" WITH ("security_invoker"='true') AS
 SELECT "c"."id",
    "c"."name",
    "c"."client_code",
    "p"."address",
    "p"."city",
    "p"."zone",
    "c"."status",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'GT'::"text") THEN "s"."equipment_size_gallons"
            ELSE NULL::numeric
        END) AS "gt_size_gallons",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'GT'::"text") THEN "s"."frequency_days"
            ELSE NULL::integer
        END) AS "gt_frequency_days",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'GT'::"text") THEN "s"."price_per_visit"
            ELSE NULL::numeric
        END) AS "gt_price_per_visit",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'GT'::"text") THEN "s"."last_visit"
            ELSE NULL::"date"
        END) AS "gt_last_visit",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'GT'::"text") THEN (("s"."last_visit" + (("s"."frequency_days" || ' days'::"text"))::interval))::"date"
            ELSE NULL::"date"
        END) AS "gt_next_visit",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'GT'::"text") THEN
            CASE
                WHEN (("s"."last_visit" IS NULL) OR ("s"."frequency_days" IS NULL)) THEN 'UNKNOWN'::"text"
                WHEN ((("s"."last_visit" + (("s"."frequency_days" || ' days'::"text"))::interval))::"date" < CURRENT_DATE) THEN 'OVERDUE'::"text"
                WHEN ((("s"."last_visit" + (("s"."frequency_days" || ' days'::"text"))::interval))::"date" <= (CURRENT_DATE + 14)) THEN 'DUE_SOON'::"text"
                ELSE 'OK'::"text"
            END
            ELSE NULL::"text"
        END) AS "gt_status",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'CL'::"text") THEN "s"."frequency_days"
            ELSE NULL::integer
        END) AS "cl_frequency_days",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'CL'::"text") THEN "s"."price_per_visit"
            ELSE NULL::numeric
        END) AS "cl_price_per_visit",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'CL'::"text") THEN "s"."last_visit"
            ELSE NULL::"date"
        END) AS "cl_last_visit",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'CL'::"text") THEN (("s"."last_visit" + (("s"."frequency_days" || ' days'::"text"))::interval))::"date"
            ELSE NULL::"date"
        END) AS "cl_next_visit",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'CL'::"text") THEN
            CASE
                WHEN (("s"."last_visit" IS NULL) OR ("s"."frequency_days" IS NULL)) THEN 'UNKNOWN'::"text"
                WHEN ((("s"."last_visit" + (("s"."frequency_days" || ' days'::"text"))::interval))::"date" < CURRENT_DATE) THEN 'OVERDUE'::"text"
                WHEN ((("s"."last_visit" + (("s"."frequency_days" || ' days'::"text"))::interval))::"date" <= (CURRENT_DATE + 14)) THEN 'DUE_SOON'::"text"
                ELSE 'OK'::"text"
            END
            ELSE NULL::"text"
        END) AS "cl_status",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'WD'::"text") THEN "s"."frequency_days"
            ELSE NULL::integer
        END) AS "wd_frequency_days",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'WD'::"text") THEN "s"."price_per_visit"
            ELSE NULL::numeric
        END) AS "wd_price_per_visit",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'WD'::"text") THEN "s"."last_visit"
            ELSE NULL::"date"
        END) AS "wd_last_visit",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'WD'::"text") THEN (("s"."last_visit" + (("s"."frequency_days" || ' days'::"text"))::interval))::"date"
            ELSE NULL::"date"
        END) AS "wd_next_visit",
    "max"(
        CASE
            WHEN ("s"."service_type" = 'WD'::"text") THEN
            CASE
                WHEN (("s"."last_visit" IS NULL) OR ("s"."frequency_days" IS NULL)) THEN 'UNKNOWN'::"text"
                WHEN ((("s"."last_visit" + (("s"."frequency_days" || ' days'::"text"))::interval))::"date" < CURRENT_DATE) THEN 'OVERDUE'::"text"
                WHEN ((("s"."last_visit" + (("s"."frequency_days" || ' days'::"text"))::interval))::"date" <= (CURRENT_DATE + 14)) THEN 'DUE_SOON'::"text"
                ELSE 'OK'::"text"
            END
            ELSE NULL::"text"
        END) AS "wd_status"
   FROM (("public"."clients" "c"
     LEFT JOIN "public"."properties" "p" ON ((("p"."client_id" = "c"."id") AND ("p"."is_primary" = true))))
     LEFT JOIN "public"."service_configs" "s" ON (("s"."client_id" = "c"."id")))
  GROUP BY "c"."id", "p"."address", "p"."city", "p"."zone";



CREATE OR REPLACE VIEW "public"."visits_recent" WITH ("security_invoker"='true') AS
 SELECT "v"."id",
    "v"."visit_date",
    "v"."service_type",
    "c"."name" AS "client_name",
    "p"."address",
    "p"."zone",
    "v"."visit_status",
    "v"."is_gps_confirmed",
    "v"."actual_arrival_at",
    "v"."actual_departure_at",
    "veh"."name" AS "vehicle_name",
    "string_agg"("e"."full_name", ', '::"text" ORDER BY "e"."full_name") AS "assigned_to"
   FROM ((((("public"."visits" "v"
     JOIN "public"."clients" "c" ON (("c"."id" = "v"."client_id")))
     LEFT JOIN "public"."properties" "p" ON ((("p"."client_id" = "c"."id") AND ("p"."is_primary" = true))))
     LEFT JOIN "public"."vehicles" "veh" ON (("veh"."id" = "v"."vehicle_id")))
     LEFT JOIN "public"."visit_assignments" "va" ON (("va"."visit_id" = "v"."id")))
     LEFT JOIN "public"."employees" "e" ON (("e"."id" = "va"."employee_id")))
  WHERE ("v"."visit_date" >= (CURRENT_DATE - 30))
  GROUP BY "v"."id", "v"."visit_date", "v"."service_type", "c"."name", "p"."address", "p"."zone", "v"."visit_status", "v"."is_gps_confirmed", "v"."actual_arrival_at", "v"."actual_departure_at", "veh"."name"
  ORDER BY "v"."visit_date" DESC, "v"."start_at" DESC;



CREATE OR REPLACE TRIGGER "audit_client_locations" AFTER INSERT OR DELETE OR UPDATE ON "public"."client_locations" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_clients" AFTER INSERT OR DELETE OR UPDATE ON "public"."clients" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_derm_email_sends" AFTER INSERT OR DELETE OR UPDATE ON "public"."derm_email_sends" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_derm_manifest_number_proposals" AFTER INSERT OR DELETE OR UPDATE ON "public"."derm_manifest_number_proposals" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_derm_manifests" AFTER INSERT OR DELETE OR UPDATE ON "public"."derm_manifests" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_disposal_facilities" AFTER INSERT OR DELETE OR UPDATE ON "public"."disposal_facilities" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_employees" AFTER INSERT OR DELETE OR UPDATE ON "public"."employees" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_gdos" AFTER INSERT OR DELETE OR UPDATE ON "public"."gdos" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_manifest_visits" AFTER INSERT OR DELETE OR UPDATE ON "public"."manifest_visits" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_municipality_regulators" AFTER INSERT OR DELETE OR UPDATE ON "public"."municipality_regulators" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_photo_classifications" AFTER INSERT OR DELETE OR UPDATE ON "public"."photo_classifications" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_properties" AFTER INSERT OR DELETE OR UPDATE ON "public"."properties" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_service_configs" AFTER INSERT OR DELETE OR UPDATE ON "public"."service_configs" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_service_line_items" AFTER INSERT OR DELETE OR UPDATE ON "public"."service_line_items" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_shift_reviews" AFTER INSERT OR DELETE OR UPDATE ON "public"."shift_reviews" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_vehicles" AFTER INSERT OR DELETE OR UPDATE ON "public"."vehicles" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_visit_assignments" AFTER INSERT OR DELETE OR UPDATE ON "public"."visit_assignments" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_visit_locations" AFTER INSERT OR DELETE OR UPDATE ON "public"."visit_locations" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_visit_reviews" AFTER INSERT OR DELETE OR UPDATE ON "public"."visit_reviews" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_visits" AFTER INSERT OR DELETE OR UPDATE ON "public"."visits" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_webhook_tokens" AFTER INSERT OR DELETE OR UPDATE ON "public"."webhook_tokens" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "audit_zones" AFTER INSERT OR DELETE OR UPDATE ON "public"."zones" FOR EACH ROW EXECUTE FUNCTION "audit"."log_change"();



CREATE OR REPLACE TRIGGER "client_groups_touch_updated_at" BEFORE UPDATE ON "public"."client_groups" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "disposal_facilities_touch_updated_at" BEFORE UPDATE ON "public"."disposal_facilities" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "photo_classifications_set_updated_at" BEFORE UPDATE ON "public"."photo_classifications" FOR EACH ROW EXECUTE FUNCTION "public"."tg_set_updated_at"();



CREATE OR REPLACE TRIGGER "properties_sync_zone_columns_trg" BEFORE INSERT OR UPDATE ON "public"."properties" FOR EACH ROW EXECUTE FUNCTION "public"."properties_sync_zone_columns"();



CREATE OR REPLACE TRIGGER "set_updated_at_client_locations" BEFORE UPDATE ON "public"."client_locations" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "set_updated_at_zones" BEFORE UPDATE ON "public"."zones" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_app_shift_reviews_updated_at" BEFORE UPDATE ON "public"."app_shift_reviews" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_app_visit_reviews_updated_at" BEFORE UPDATE ON "public"."app_visit_reviews" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_client_contacts_updated_at" BEFORE UPDATE ON "public"."client_contacts" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_client_default_location" AFTER INSERT ON "public"."clients" FOR EACH ROW EXECUTE FUNCTION "public"."ensure_client_has_location"();



CREATE OR REPLACE TRIGGER "trg_clients_updated_at" BEFORE UPDATE ON "public"."clients" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_clients_wipe_upcoming_on_inactive" BEFORE UPDATE OF "status" ON "public"."clients" FOR EACH ROW WHEN (("new"."status" IS DISTINCT FROM "old"."status")) EXECUTE FUNCTION "public"."trg_wipe_upcoming_on_inactive"();



CREATE OR REPLACE TRIGGER "trg_derm_manifest_number_proposals_updated_at" BEFORE UPDATE ON "public"."derm_manifest_number_proposals" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_derm_manifests_updated_at" BEFORE UPDATE ON "public"."derm_manifests" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_employees_updated_at" BEFORE UPDATE ON "public"."employees" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_gdo_compliance_check" AFTER INSERT OR UPDATE OF "service_type" ON "public"."visits" FOR EACH ROW EXECUTE FUNCTION "public"."fn_check_gdo_on_visit"();



CREATE OR REPLACE TRIGGER "trg_gdos_updated_at" BEFORE UPDATE ON "public"."gdos" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_inspections_updated_at" BEFORE UPDATE ON "public"."inspections" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_invoices_updated_at" BEFORE UPDATE ON "public"."invoices" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_jobs_updated_at" BEFORE UPDATE ON "public"."jobs" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_line_items_updated_at" BEFORE UPDATE ON "public"."line_items" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_municipality_regulators_updated_at" BEFORE UPDATE ON "public"."municipality_regulators" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_notes_updated_at" BEFORE UPDATE ON "public"."notes" FOR EACH ROW EXECUTE FUNCTION "public"."trg_set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_properties_updated_at" BEFORE UPDATE ON "public"."properties" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_push_visit_insert" AFTER INSERT ON "public"."visits" FOR EACH ROW WHEN ((("new"."source" = ANY (ARRAY['visit-calendar'::"text", 'supabase_cron'::"text"])) AND ("new"."client_id" = 381))) EXECUTE FUNCTION "public"."fn_push_visit_to_jobber"();



CREATE OR REPLACE TRIGGER "trg_push_visit_update" AFTER UPDATE ON "public"."visits" FOR EACH ROW WHEN ((("new"."source" = ANY (ARRAY['visit-calendar'::"text", 'supabase_cron'::"text"])) AND ("new"."client_id" = 381) AND (("old"."visit_date" IS DISTINCT FROM "new"."visit_date") OR ("old"."start_at" IS DISTINCT FROM "new"."start_at") OR ("old"."end_at" IS DISTINCT FROM "new"."end_at") OR ("old"."title" IS DISTINCT FROM "new"."title") OR ("old"."job_id" IS DISTINCT FROM "new"."job_id") OR ("old"."service_line_item_id" IS DISTINCT FROM "new"."service_line_item_id") OR ("old"."deleted_at" IS DISTINCT FROM "new"."deleted_at")))) EXECUTE FUNCTION "public"."fn_push_visit_to_jobber"();



CREATE OR REPLACE TRIGGER "trg_quotes_updated_at" BEFORE UPDATE ON "public"."quotes" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_service_configs_updated_at" BEFORE UPDATE ON "public"."service_configs" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_service_line_items_updated_at" BEFORE UPDATE ON "public"."service_line_items" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_shift_reviews_updated_at" BEFORE UPDATE ON "public"."shift_reviews" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_sync_cursors_updated_at" BEFORE UPDATE ON "public"."sync_cursors" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_sync_log_updated_at" BEFORE UPDATE ON "public"."sync_log" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_vehicles_updated_at" BEFORE UPDATE ON "public"."vehicles" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_visit_default_locations" AFTER INSERT ON "public"."visits" FOR EACH ROW EXECUTE FUNCTION "public"."seed_visit_locations"();



CREATE OR REPLACE TRIGGER "trg_visit_reviews_updated_at" BEFORE UPDATE ON "public"."visit_reviews" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_visit_sync_flags_updated_at" BEFORE UPDATE ON "public"."visit_sync_flags" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_visits_updated_at" BEFORE UPDATE ON "public"."visits" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_webhook_tokens_updated_at" BEFORE UPDATE ON "public"."webhook_tokens" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "visit_recommendations_touch_updated_at" BEFORE UPDATE ON "public"."visit_recommendations" FOR EACH ROW EXECUTE FUNCTION "public"."touch_updated_at"();



CREATE OR REPLACE TRIGGER "zones_cascade_code_rename_trg" AFTER UPDATE OF "code" ON "public"."zones" FOR EACH ROW EXECUTE FUNCTION "public"."zones_cascade_code_rename"();



ALTER TABLE ONLY "public"."client_contacts"
    ADD CONSTRAINT "client_contacts_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."client_locations"
    ADD CONSTRAINT "client_locations_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."client_locations"
    ADD CONSTRAINT "client_locations_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."clients"
    ADD CONSTRAINT "clients_group_id_fkey" FOREIGN KEY ("group_id") REFERENCES "public"."client_groups"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."derm_email_sends"
    ADD CONSTRAINT "derm_email_sends_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id");



ALTER TABLE ONLY "public"."derm_email_sends"
    ADD CONSTRAINT "derm_email_sends_manifest_id_fkey" FOREIGN KEY ("manifest_id") REFERENCES "public"."derm_manifests"("id");



ALTER TABLE ONLY "public"."derm_manifest_number_proposals"
    ADD CONSTRAINT "derm_manifest_number_proposals_manifest_id_fkey" FOREIGN KEY ("manifest_id") REFERENCES "public"."derm_manifests"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."derm_manifests"
    ADD CONSTRAINT "derm_manifests_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id");



ALTER TABLE ONLY "public"."derm_manifests"
    ADD CONSTRAINT "derm_manifests_disposal_facility_id_fkey" FOREIGN KEY ("disposal_facility_id") REFERENCES "public"."disposal_facilities"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."derm_manifests"
    ADD CONSTRAINT "derm_manifests_gdo_id_fkey" FOREIGN KEY ("gdo_id") REFERENCES "public"."gdos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."gdos"
    ADD CONSTRAINT "gdos_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gdos"
    ADD CONSTRAINT "gdos_client_location_id_fkey" FOREIGN KEY ("client_location_id") REFERENCES "public"."client_locations"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."gdos"
    ADD CONSTRAINT "gdos_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."inspections"
    ADD CONSTRAINT "inspections_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id");



ALTER TABLE ONLY "public"."inspections"
    ADD CONSTRAINT "inspections_vehicle_id_fkey" FOREIGN KEY ("vehicle_id") REFERENCES "public"."vehicles"("id");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id");



ALTER TABLE ONLY "public"."jobber_oversized_attachments"
    ADD CONSTRAINT "jobber_oversized_attachments_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id");



ALTER TABLE ONLY "public"."jobber_oversized_attachments"
    ADD CONSTRAINT "jobber_oversized_attachments_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id");



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."jobs"
    ADD CONSTRAINT "jobs_quote_id_fkey" FOREIGN KEY ("quote_id") REFERENCES "public"."quotes"("id");



ALTER TABLE ONLY "public"."line_items"
    ADD CONSTRAINT "line_items_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."line_items"
    ADD CONSTRAINT "line_items_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id");



ALTER TABLE ONLY "public"."line_items"
    ADD CONSTRAINT "line_items_quote_id_fkey" FOREIGN KEY ("quote_id") REFERENCES "public"."quotes"("id");



ALTER TABLE ONLY "public"."line_items"
    ADD CONSTRAINT "line_items_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."manifest_visits"
    ADD CONSTRAINT "manifest_visits_manifest_id_fkey" FOREIGN KEY ("manifest_id") REFERENCES "public"."derm_manifests"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."manifest_visits"
    ADD CONSTRAINT "manifest_visits_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notes"
    ADD CONSTRAINT "notes_author_employee_id_fkey" FOREIGN KEY ("author_employee_id") REFERENCES "public"."employees"("id");



ALTER TABLE ONLY "public"."notes"
    ADD CONSTRAINT "notes_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id");



ALTER TABLE ONLY "public"."notes"
    ADD CONSTRAINT "notes_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id");



ALTER TABLE ONLY "public"."notes"
    ADD CONSTRAINT "notes_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."notes"
    ADD CONSTRAINT "notes_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."photo_classifications"
    ADD CONSTRAINT "photo_classifications_photo_link_id_fkey" FOREIGN KEY ("photo_link_id") REFERENCES "public"."photo_links"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."photo_links"
    ADD CONSTRAINT "photo_links_photo_id_fkey" FOREIGN KEY ("photo_id") REFERENCES "public"."photos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."photos"
    ADD CONSTRAINT "photos_uploaded_by_employee_id_fkey" FOREIGN KEY ("uploaded_by_employee_id") REFERENCES "public"."employees"("id");



ALTER TABLE ONLY "public"."properties"
    ADD CONSTRAINT "properties_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."properties"
    ADD CONSTRAINT "properties_default_disposal_facility_id_fkey" FOREIGN KEY ("default_disposal_facility_id") REFERENCES "public"."disposal_facilities"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."properties"
    ADD CONSTRAINT "properties_zone_id_fkey" FOREIGN KEY ("zone_id") REFERENCES "public"."zones"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."quotes"
    ADD CONSTRAINT "quotes_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id");



ALTER TABLE ONLY "public"."quotes"
    ADD CONSTRAINT "quotes_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."service_configs"
    ADD CONSTRAINT "service_configs_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."service_configs"
    ADD CONSTRAINT "service_configs_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."shift_reviews"
    ADD CONSTRAINT "shift_reviews_bonus_decided_by_fkey" FOREIGN KEY ("bonus_decided_by") REFERENCES "public"."employees"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."shift_reviews"
    ADD CONSTRAINT "shift_reviews_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."shift_reviews"
    ADD CONSTRAINT "shift_reviews_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."employees"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."vehicle_telemetry_readings"
    ADD CONSTRAINT "vehicle_fuel_readings_vehicle_id_fkey" FOREIGN KEY ("vehicle_id") REFERENCES "public"."vehicles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."visit_assignments"
    ADD CONSTRAINT "visit_assignments_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."visit_assignments"
    ADD CONSTRAINT "visit_assignments_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."visit_locations"
    ADD CONSTRAINT "visit_locations_client_location_id_fkey" FOREIGN KEY ("client_location_id") REFERENCES "public"."client_locations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."visit_locations"
    ADD CONSTRAINT "visit_locations_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."visit_recommendations"
    ADD CONSTRAINT "visit_recommendations_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."visit_reviews"
    ADD CONSTRAINT "visit_reviews_bonus_decided_by_fkey" FOREIGN KEY ("bonus_decided_by") REFERENCES "public"."employees"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."visit_reviews"
    ADD CONSTRAINT "visit_reviews_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."employees"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."visit_reviews"
    ADD CONSTRAINT "visit_reviews_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."visit_sync_flags"
    ADD CONSTRAINT "visit_sync_flags_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_job_id_fkey" FOREIGN KEY ("job_id") REFERENCES "public"."jobs"("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_property_id_fkey" FOREIGN KEY ("property_id") REFERENCES "public"."properties"("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_service_line_item_id_fkey" FOREIGN KEY ("service_line_item_id") REFERENCES "public"."service_line_items"("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_vehicle_id_fkey" FOREIGN KEY ("vehicle_id") REFERENCES "public"."vehicles"("id");



CREATE POLICY "authenticated_read_all" ON "audit"."logs" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "audit"."logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "Allow anon read on derm_manifests" ON "public"."derm_manifests" FOR SELECT TO "anon" USING (true);



CREATE POLICY "Allow anon read on line_items" ON "public"."line_items" FOR SELECT TO "anon" USING (true);



CREATE POLICY "Allow anon read on manifest_visits" ON "public"."manifest_visits" FOR SELECT TO "anon" USING (true);



CREATE POLICY "Allow anon read on visit_assignments" ON "public"."visit_assignments" FOR SELECT TO "anon" USING (true);



CREATE POLICY "Allow authenticated read on derm_manifests" ON "public"."derm_manifests" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated read on invoices" ON "public"."invoices" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated read on jobs" ON "public"."jobs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated read on line_items" ON "public"."line_items" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated read on manifest_visits" ON "public"."manifest_visits" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated read on quotes" ON "public"."quotes" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated read on service_configs" ON "public"."service_configs" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated read on sync_cursors" ON "public"."sync_cursors" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated read on sync_log" ON "public"."sync_log" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated read on visit_assignments" ON "public"."visit_assignments" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow public read access on clients" ON "public"."clients" FOR SELECT USING (true);



CREATE POLICY "Allow public read access on inspections" ON "public"."inspections" FOR SELECT USING (true);



CREATE POLICY "Allow service_role full access on clients" ON "public"."clients" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role full access on derm_manifests" ON "public"."derm_manifests" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role full access on employees" ON "public"."employees" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role full access on inspections" ON "public"."inspections" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role full access on invoices" ON "public"."invoices" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role full access on jobs" ON "public"."jobs" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role full access on line_items" ON "public"."line_items" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role full access on manifest_visits" ON "public"."manifest_visits" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role full access on properties" ON "public"."properties" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role full access on quotes" ON "public"."quotes" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role full access on service_configs" ON "public"."service_configs" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role full access on sync_cursors" ON "public"."sync_cursors" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role full access on sync_log" ON "public"."sync_log" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role full access on vehicles" ON "public"."vehicles" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role full access on visit_assignments" ON "public"."visit_assignments" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Allow service_role full access on visits" ON "public"."visits" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Anon read photos" ON "public"."photos" FOR SELECT TO "anon" USING (true);



CREATE POLICY "Authenticated insert photo_links" ON "public"."photo_links" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated read jobber_oversized_attachments" ON "public"."jobber_oversized_attachments" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated read notes" ON "public"."notes" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated read photo_links" ON "public"."photo_links" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated read photos" ON "public"."photos" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated read properties" ON "public"."properties" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated read vehicle_telemetry_readings" ON "public"."vehicle_telemetry_readings" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated read vehicles" ON "public"."vehicles" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated read visits" ON "public"."visits" FOR SELECT TO "authenticated" USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Authenticated users can read employees" ON "public"."employees" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Service role full access jobber_oversized_attachments" ON "public"."jobber_oversized_attachments" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role full access notes" ON "public"."notes" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role full access photo_links" ON "public"."photo_links" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role full access photos" ON "public"."photos" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role full access vehicle_telemetry_readings" ON "public"."vehicle_telemetry_readings" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role full access webhook_events_log" ON "public"."webhook_events_log" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role full access webhook_tokens" ON "public"."webhook_tokens" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "admin_review_anon_read_clients" ON "public"."clients" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "admin_review_anon_read_employees" ON "public"."employees" FOR SELECT TO "anon" USING (true);



CREATE POLICY "admin_review_anon_read_jobs" ON "public"."jobs" FOR SELECT TO "anon" USING (true);



CREATE POLICY "admin_review_anon_read_photo_links" ON "public"."photo_links" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "admin_review_anon_read_photos" ON "public"."photos" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "admin_review_anon_read_vehicles" ON "public"."vehicles" FOR SELECT TO "anon" USING (true);



CREATE POLICY "admin_review_anon_read_visits" ON "public"."visits" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "anon_delete_manifest_visits" ON "public"."manifest_visits" FOR DELETE TO "anon" USING (true);



CREATE POLICY "anon_insert_derm_manifests" ON "public"."derm_manifests" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "anon_insert_dmnp" ON "public"."derm_manifest_number_proposals" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "anon_insert_manifest_visits" ON "public"."manifest_visits" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "anon_read_client_contacts" ON "public"."client_contacts" FOR SELECT TO "anon" USING (true);



CREATE POLICY "anon_read_disposal_facilities" ON "public"."disposal_facilities" FOR SELECT TO "anon" USING (true);



CREATE POLICY "anon_read_dmnp" ON "public"."derm_manifest_number_proposals" FOR SELECT TO "anon" USING (true);



CREATE POLICY "anon_read_entity_source_links" ON "public"."entity_source_links" FOR SELECT TO "anon" USING (true);



CREATE POLICY "anon_read_gdos" ON "public"."gdos" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "anon_read_properties" ON "public"."properties" FOR SELECT TO "anon" USING (true);



CREATE POLICY "anon_update_derm_manifests" ON "public"."derm_manifests" FOR UPDATE TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "anon_update_dmnp" ON "public"."derm_manifest_number_proposals" FOR UPDATE TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "anon_update_gdo_labels" ON "public"."gdos" FOR UPDATE TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "anon_update_visit_derm_required" ON "public"."visits" FOR UPDATE TO "authenticated", "anon" USING (("visit_status" = 'completed'::"text")) WITH CHECK (("visit_status" = 'completed'::"text"));



ALTER TABLE "public"."app_shift_reviews" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "app_shift_reviews_authenticated_all" ON "public"."app_shift_reviews" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



ALTER TABLE "public"."app_visit_reviews" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "app_visit_reviews_authenticated_all" ON "public"."app_visit_reviews" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (("auth"."uid"() IS NOT NULL));



CREATE POLICY "auth_read_client_contacts" ON "public"."client_contacts" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "auth_read_entity_source_links" ON "public"."entity_source_links" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "authenticated_read_disposal_facilities" ON "public"."disposal_facilities" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "authenticated_read_dmnp" ON "public"."derm_manifest_number_proposals" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "authenticated_write_dmnp" ON "public"."derm_manifest_number_proposals" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."client_contacts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_groups" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_locations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "client_locations_anon_read" ON "public"."client_locations" FOR SELECT TO "anon" USING (true);



CREATE POLICY "client_locations_authenticated_all" ON "public"."client_locations" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."clients" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."derm_email_sends" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."derm_manifest_number_proposals" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."derm_manifests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."disposal_facilities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."employees" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."entity_source_links" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gdos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."inspections" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invoices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."jobber_oversized_attachments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."jobs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."line_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."manifest_visits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."municipality_regulators" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."photo_classifications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "photo_classifications_anon_insert" ON "public"."photo_classifications" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "photo_classifications_anon_select" ON "public"."photo_classifications" FOR SELECT TO "anon" USING (true);



CREATE POLICY "photo_classifications_anon_update" ON "public"."photo_classifications" FOR UPDATE TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "photo_classifications_authenticated_all" ON "public"."photo_classifications" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."photo_links" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."photos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."properties" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "properties_anon_update_manhole" ON "public"."properties" FOR UPDATE TO "anon" USING (true) WITH CHECK (true);



ALTER TABLE "public"."quotes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."service_configs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."service_line_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "service_line_items_read" ON "public"."service_line_items" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."shift_reviews" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "shift_reviews_anon_insert" ON "public"."shift_reviews" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "shift_reviews_anon_select" ON "public"."shift_reviews" FOR SELECT TO "anon" USING (true);



CREATE POLICY "shift_reviews_anon_update" ON "public"."shift_reviews" FOR UPDATE TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "shift_reviews_auth_all" ON "public"."shift_reviews" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "shift_reviews_service_all" ON "public"."shift_reviews" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "sr_all_client_contacts" ON "public"."client_contacts" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "sr_all_entity_source_links" ON "public"."entity_source_links" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "public"."sync_cursors" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sync_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."vehicle_telemetry_readings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."vehicles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."visit_assignments" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "visit_assignments_anon_delete" ON "public"."visit_assignments" FOR DELETE TO "anon" USING (true);



CREATE POLICY "visit_assignments_anon_insert" ON "public"."visit_assignments" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "visit_assignments_anon_select" ON "public"."visit_assignments" FOR SELECT TO "anon" USING (true);



ALTER TABLE "public"."visit_locations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "visit_locations_anon_read" ON "public"."visit_locations" FOR SELECT TO "anon" USING (true);



CREATE POLICY "visit_locations_auth_all" ON "public"."visit_locations" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "visit_locations_service_all" ON "public"."visit_locations" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "public"."visit_recommendations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."visit_reviews" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "visit_reviews_anon_insert" ON "public"."visit_reviews" FOR INSERT TO "anon" WITH CHECK (true);



CREATE POLICY "visit_reviews_anon_select" ON "public"."visit_reviews" FOR SELECT TO "anon" USING (true);



CREATE POLICY "visit_reviews_anon_update" ON "public"."visit_reviews" FOR UPDATE TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "visit_reviews_auth_all" ON "public"."visit_reviews" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "visit_reviews_service_all" ON "public"."visit_reviews" TO "service_role" USING (true) WITH CHECK (true);



ALTER TABLE "public"."visits" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "visits_anon_update_manhole" ON "public"."visits" FOR UPDATE TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "visits_calendar_insert" ON "public"."visits" FOR INSERT TO "authenticated", "anon" WITH CHECK (("source" = 'visit-calendar'::"text"));



CREATE POLICY "visits_calendar_update" ON "public"."visits" FOR UPDATE TO "authenticated", "anon" USING (("source" = 'visit-calendar'::"text")) WITH CHECK (("source" = 'visit-calendar'::"text"));



ALTER TABLE "public"."webhook_events_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."webhook_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."zones" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "zones_anon_insert" ON "public"."zones" FOR INSERT TO "authenticated", "anon" WITH CHECK (true);



CREATE POLICY "zones_anon_select_all" ON "public"."zones" FOR SELECT TO "authenticated", "anon" USING (true);



CREATE POLICY "zones_anon_update" ON "public"."zones" FOR UPDATE TO "authenticated", "anon" USING (true) WITH CHECK (true);





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "audit" TO "authenticated";
GRANT USAGE ON SCHEMA "audit" TO "service_role";






GRANT USAGE ON SCHEMA "customer" TO "anon";
GRANT USAGE ON SCHEMA "customer" TO "authenticated";
GRANT USAGE ON SCHEMA "customer" TO "service_role";



GRANT USAGE ON SCHEMA "derm" TO "anon";
GRANT USAGE ON SCHEMA "derm" TO "authenticated";
GRANT USAGE ON SCHEMA "derm" TO "service_role";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";
GRANT USAGE ON SCHEMA "public" TO "yannick_readonly";






GRANT USAGE ON SCHEMA "ops" TO "yannick_readonly";
GRANT USAGE ON SCHEMA "ops" TO "anon";
GRANT USAGE ON SCHEMA "ops" TO "authenticated";
GRANT USAGE ON SCHEMA "ops" TO "service_role";



GRANT USAGE ON SCHEMA "raw" TO "service_role";



REVOKE ALL ON FUNCTION "audit"."log_change"() FROM PUBLIC;
























GRANT ALL ON FUNCTION "customer"."bigint_from_uuid"("u" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "customer"."bigint_from_uuid"("u" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "customer"."uuid_from_bigint"("b" bigint) TO "anon";
GRANT ALL ON FUNCTION "customer"."uuid_from_bigint"("b" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "customer"."uuid_from_bigint"("b" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."gen_short_id"("n_chars" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."gen_short_id"("n_chars" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."gen_short_id"("n_chars" integer) TO "service_role";



GRANT ALL ON TABLE "public"."derm_manifests" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."derm_manifests" TO "anon";
GRANT SELECT ON TABLE "public"."derm_manifests" TO "authenticated";
GRANT SELECT ON TABLE "public"."derm_manifests" TO "yannick_readonly";



GRANT UPDATE("gdo_id") ON TABLE "public"."derm_manifests" TO "anon";
GRANT UPDATE("gdo_id") ON TABLE "public"."derm_manifests" TO "authenticated";



GRANT ALL ON TABLE "public"."employees" TO "service_role";
GRANT SELECT ON TABLE "public"."employees" TO "anon";
GRANT SELECT ON TABLE "public"."employees" TO "authenticated";
GRANT SELECT ON TABLE "public"."employees" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."manifest_visits" TO "service_role";
GRANT SELECT,INSERT,DELETE ON TABLE "public"."manifest_visits" TO "anon";
GRANT SELECT ON TABLE "public"."manifest_visits" TO "authenticated";
GRANT SELECT ON TABLE "public"."manifest_visits" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."properties" TO "service_role";
GRANT SELECT ON TABLE "public"."properties" TO "anon";
GRANT SELECT ON TABLE "public"."properties" TO "authenticated";
GRANT SELECT ON TABLE "public"."properties" TO "yannick_readonly";



GRANT UPDATE("grease_trap_manhole_count") ON TABLE "public"."properties" TO "anon";



GRANT ALL ON TABLE "public"."service_configs" TO "service_role";
GRANT SELECT ON TABLE "public"."service_configs" TO "anon";
GRANT SELECT ON TABLE "public"."service_configs" TO "authenticated";
GRANT SELECT ON TABLE "public"."service_configs" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."vehicles" TO "service_role";
GRANT SELECT ON TABLE "public"."vehicles" TO "anon";
GRANT SELECT ON TABLE "public"."vehicles" TO "authenticated";
GRANT SELECT ON TABLE "public"."vehicles" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."visit_assignments" TO "service_role";
GRANT SELECT,INSERT,DELETE ON TABLE "public"."visit_assignments" TO "anon";
GRANT SELECT ON TABLE "public"."visit_assignments" TO "authenticated";
GRANT SELECT ON TABLE "public"."visit_assignments" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."visits" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."visits" TO "anon";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."visits" TO "authenticated";
GRANT SELECT ON TABLE "public"."visits" TO "yannick_readonly";



GRANT INSERT("client_id") ON TABLE "public"."visits" TO "anon";



GRANT INSERT("property_id") ON TABLE "public"."visits" TO "anon";



GRANT INSERT("job_id") ON TABLE "public"."visits" TO "anon";



GRANT INSERT("vehicle_id"),UPDATE("vehicle_id") ON TABLE "public"."visits" TO "anon";



GRANT INSERT("visit_date"),UPDATE("visit_date") ON TABLE "public"."visits" TO "anon";



GRANT INSERT("start_at") ON TABLE "public"."visits" TO "anon";



GRANT INSERT("end_at") ON TABLE "public"."visits" TO "anon";



GRANT INSERT("completed_at"),UPDATE("completed_at") ON TABLE "public"."visits" TO "anon";



GRANT INSERT("duration_minutes") ON TABLE "public"."visits" TO "anon";



GRANT INSERT("title") ON TABLE "public"."visits" TO "anon";



GRANT INSERT("service_type") ON TABLE "public"."visits" TO "anon";



GRANT INSERT("visit_status"),UPDATE("visit_status") ON TABLE "public"."visits" TO "anon";



GRANT UPDATE("actual_arrival_at") ON TABLE "public"."visits" TO "anon";



GRANT UPDATE("actual_departure_at") ON TABLE "public"."visits" TO "anon";



GRANT INSERT("source") ON TABLE "public"."visits" TO "anon";



GRANT UPDATE("manhole_count") ON TABLE "public"."visits" TO "anon";



GRANT UPDATE("manhole_breakdown") ON TABLE "public"."visits" TO "anon";



GRANT UPDATE("ticket_number") ON TABLE "public"."visits" TO "anon";



GRANT UPDATE("trap_condition_notes") ON TABLE "public"."visits" TO "anon";



GRANT UPDATE("derm_required") ON TABLE "public"."visits" TO "authenticated";
GRANT INSERT("derm_required"),UPDATE("derm_required") ON TABLE "public"."visits" TO "anon";



GRANT SELECT ON TABLE "customer"."work_orders" TO "anon";
GRANT SELECT ON TABLE "customer"."work_orders" TO "authenticated";



GRANT ALL ON FUNCTION "customer"."get_visit_by_slug_and_token"("p_slug" "text", "p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "customer"."get_visit_by_slug_and_token"("p_slug" "text", "p_token" "text") TO "authenticated";



GRANT ALL ON FUNCTION "customer"."public_url"("storage_path" "text") TO "anon";
GRANT ALL ON FUNCTION "customer"."public_url"("storage_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "customer"."public_url"("storage_path" "text") TO "service_role";



GRANT ALL ON FUNCTION "customer"."thumbnail_url"("storage_path" "text", "width" integer, "height" integer, "quality" integer) TO "anon";
GRANT ALL ON FUNCTION "customer"."thumbnail_url"("storage_path" "text", "width" integer, "height" integer, "quality" integer) TO "authenticated";
GRANT ALL ON FUNCTION "customer"."thumbnail_url"("storage_path" "text", "width" integer, "height" integer, "quality" integer) TO "service_role";






















































































































































GRANT ALL ON FUNCTION "public"."ensure_client_has_location"() TO "anon";
GRANT ALL ON FUNCTION "public"."ensure_client_has_location"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_client_has_location"() TO "service_role";



GRANT ALL ON FUNCTION "public"."file_manifest"("p_client_id" bigint, "p_jurisdiction" "text", "p_number" "text", "p_disposal_facility_id" bigint, "p_dump_date" "date", "p_visit_ids" bigint[]) TO "anon";
GRANT ALL ON FUNCTION "public"."file_manifest"("p_client_id" bigint, "p_jurisdiction" "text", "p_number" "text", "p_disposal_facility_id" bigint, "p_dump_date" "date", "p_visit_ids" bigint[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."file_manifest"("p_client_id" bigint, "p_jurisdiction" "text", "p_number" "text", "p_disposal_facility_id" bigint, "p_dump_date" "date", "p_visit_ids" bigint[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_check_gdo_on_visit"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_check_gdo_on_visit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_check_gdo_on_visit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_push_visit_to_jobber"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_push_visit_to_jobber"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_push_visit_to_jobber"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."next_derm_address_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."next_derm_address_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_derm_address_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."pgaudit_ddl_command_end"() TO "postgres";
GRANT ALL ON FUNCTION "public"."pgaudit_ddl_command_end"() TO "anon";
GRANT ALL ON FUNCTION "public"."pgaudit_ddl_command_end"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."pgaudit_ddl_command_end"() TO "service_role";



GRANT ALL ON FUNCTION "public"."pgaudit_sql_drop"() TO "postgres";
GRANT ALL ON FUNCTION "public"."pgaudit_sql_drop"() TO "anon";
GRANT ALL ON FUNCTION "public"."pgaudit_sql_drop"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."pgaudit_sql_drop"() TO "service_role";



GRANT ALL ON FUNCTION "public"."properties_sync_zone_columns"() TO "anon";
GRANT ALL ON FUNCTION "public"."properties_sync_zone_columns"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."properties_sync_zone_columns"() TO "service_role";



GRANT ALL ON FUNCTION "public"."seed_visit_locations"() TO "anon";
GRANT ALL ON FUNCTION "public"."seed_visit_locations"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."seed_visit_locations"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_visit_manholes"("p_visit_id" bigint, "p_location_ids" bigint[]) TO "anon";
GRANT ALL ON FUNCTION "public"."set_visit_manholes"("p_visit_id" bigint, "p_location_ids" bigint[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_visit_manholes"("p_visit_id" bigint, "p_location_ids" bigint[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."touch_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."trg_wipe_upcoming_on_inactive"() TO "anon";
GRANT ALL ON FUNCTION "public"."trg_wipe_upcoming_on_inactive"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."trg_wipe_upcoming_on_inactive"() TO "service_role";



GRANT ALL ON FUNCTION "public"."zones_cascade_code_rename"() TO "anon";
GRANT ALL ON FUNCTION "public"."zones_cascade_code_rename"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."zones_cascade_code_rename"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."zones_hard_delete"("_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."zones_hard_delete"("_code" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."zones_hard_delete"("_code" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."zones_hard_delete"("_code" "text") TO "service_role";












GRANT SELECT ON TABLE "audit"."logs" TO "authenticated";
GRANT ALL ON TABLE "audit"."logs" TO "service_role";









GRANT SELECT,MAINTAIN ON TABLE "public"."photo_links" TO "anon";
GRANT ALL ON TABLE "public"."photo_links" TO "authenticated";
GRANT ALL ON TABLE "public"."photo_links" TO "service_role";
GRANT SELECT ON TABLE "public"."photo_links" TO "yannick_readonly";



GRANT SELECT,MAINTAIN ON TABLE "public"."photos" TO "anon";
GRANT ALL ON TABLE "public"."photos" TO "authenticated";
GRANT ALL ON TABLE "public"."photos" TO "service_role";
GRANT SELECT ON TABLE "public"."photos" TO "yannick_readonly";



GRANT SELECT ON TABLE "customer"."client_access_photos" TO "anon";
GRANT SELECT ON TABLE "customer"."client_access_photos" TO "authenticated";
GRANT SELECT ON TABLE "customer"."client_access_photos" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."client_groups" TO "anon";
GRANT ALL ON TABLE "public"."client_groups" TO "authenticated";
GRANT ALL ON TABLE "public"."client_groups" TO "service_role";
GRANT SELECT ON TABLE "public"."client_groups" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."clients" TO "service_role";
GRANT SELECT ON TABLE "public"."clients" TO "anon";
GRANT SELECT ON TABLE "public"."clients" TO "authenticated";
GRANT SELECT ON TABLE "public"."clients" TO "yannick_readonly";



GRANT SELECT,MAINTAIN ON TABLE "public"."disposal_facilities" TO "anon";
GRANT ALL ON TABLE "public"."disposal_facilities" TO "authenticated";
GRANT ALL ON TABLE "public"."disposal_facilities" TO "service_role";
GRANT SELECT ON TABLE "public"."disposal_facilities" TO "yannick_readonly";



GRANT SELECT,MAINTAIN ON TABLE "public"."gdos" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."gdos" TO "authenticated";
GRANT ALL ON TABLE "public"."gdos" TO "service_role";
GRANT SELECT ON TABLE "public"."gdos" TO "yannick_readonly";



GRANT UPDATE("location_label") ON TABLE "public"."gdos" TO "anon";
GRANT UPDATE("location_label") ON TABLE "public"."gdos" TO "authenticated";



GRANT UPDATE("property_id") ON TABLE "public"."gdos" TO "anon";
GRANT UPDATE("property_id") ON TABLE "public"."gdos" TO "authenticated";



GRANT UPDATE("status") ON TABLE "public"."gdos" TO "anon";
GRANT UPDATE("status") ON TABLE "public"."gdos" TO "authenticated";



GRANT UPDATE("notes") ON TABLE "public"."gdos" TO "anon";
GRANT UPDATE("notes") ON TABLE "public"."gdos" TO "authenticated";



GRANT SELECT ON TABLE "customer"."clients" TO "anon";
GRANT SELECT ON TABLE "customer"."clients" TO "authenticated";
GRANT SELECT ON TABLE "customer"."clients" TO "service_role";



GRANT ALL ON TABLE "public"."inspections" TO "service_role";
GRANT SELECT ON TABLE "public"."inspections" TO "anon";
GRANT SELECT ON TABLE "public"."inspections" TO "authenticated";
GRANT SELECT ON TABLE "public"."inspections" TO "yannick_readonly";



GRANT SELECT ON TABLE "customer"."inspection_items" TO "anon";
GRANT SELECT ON TABLE "customer"."inspection_items" TO "authenticated";



GRANT SELECT ON TABLE "customer"."permits" TO "anon";
GRANT SELECT ON TABLE "customer"."permits" TO "authenticated";
GRANT SELECT ON TABLE "customer"."permits" TO "service_role";



GRANT SELECT,INSERT,MAINTAIN,UPDATE ON TABLE "public"."visit_recommendations" TO "anon";
GRANT ALL ON TABLE "public"."visit_recommendations" TO "authenticated";
GRANT ALL ON TABLE "public"."visit_recommendations" TO "service_role";
GRANT SELECT ON TABLE "public"."visit_recommendations" TO "yannick_readonly";



GRANT SELECT ON TABLE "customer"."recommendations" TO "anon";
GRANT SELECT ON TABLE "customer"."recommendations" TO "authenticated";



GRANT SELECT ON TABLE "customer"."scheduled_visits" TO "anon";
GRANT SELECT ON TABLE "customer"."scheduled_visits" TO "authenticated";



GRANT SELECT,INSERT,MAINTAIN,UPDATE ON TABLE "public"."photo_classifications" TO "anon";
GRANT ALL ON TABLE "public"."photo_classifications" TO "authenticated";
GRANT ALL ON TABLE "public"."photo_classifications" TO "service_role";
GRANT SELECT ON TABLE "public"."photo_classifications" TO "yannick_readonly";



GRANT SELECT ON TABLE "customer"."wo_photos" TO "anon";
GRANT SELECT ON TABLE "customer"."wo_photos" TO "authenticated";



GRANT SELECT ON TABLE "derm"."disposal_facilities" TO "anon";
GRANT SELECT ON TABLE "derm"."disposal_facilities" TO "authenticated";
GRANT ALL ON TABLE "derm"."disposal_facilities" TO "service_role";



GRANT SELECT ON TABLE "derm"."gdos" TO "anon";
GRANT SELECT ON TABLE "derm"."gdos" TO "authenticated";
GRANT ALL ON TABLE "derm"."gdos" TO "service_role";



GRANT SELECT ON TABLE "derm"."manifest_health" TO "anon";
GRANT SELECT ON TABLE "derm"."manifest_health" TO "authenticated";
GRANT ALL ON TABLE "derm"."manifest_health" TO "service_role";



GRANT ALL ON TABLE "public"."derm_manifest_number_proposals" TO "anon";
GRANT ALL ON TABLE "public"."derm_manifest_number_proposals" TO "authenticated";
GRANT ALL ON TABLE "public"."derm_manifest_number_proposals" TO "service_role";
GRANT SELECT ON TABLE "public"."derm_manifest_number_proposals" TO "yannick_readonly";



GRANT SELECT ON TABLE "derm"."manifest_number_proposals" TO "anon";
GRANT SELECT ON TABLE "derm"."manifest_number_proposals" TO "authenticated";
GRANT ALL ON TABLE "derm"."manifest_number_proposals" TO "service_role";



GRANT ALL ON TABLE "public"."derm_email_sends" TO "service_role";
GRANT SELECT ON TABLE "public"."derm_email_sends" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."municipality_regulators" TO "service_role";
GRANT SELECT ON TABLE "public"."municipality_regulators" TO "yannick_readonly";



GRANT SELECT ON TABLE "derm"."manifests" TO "anon";
GRANT SELECT ON TABLE "derm"."manifests" TO "authenticated";
GRANT ALL ON TABLE "derm"."manifests" TO "service_role";



GRANT ALL ON TABLE "public"."client_contacts" TO "service_role";
GRANT SELECT ON TABLE "public"."client_contacts" TO "anon";
GRANT SELECT ON TABLE "public"."client_contacts" TO "authenticated";
GRANT SELECT ON TABLE "public"."client_contacts" TO "yannick_readonly";



GRANT SELECT ON TABLE "derm"."manifest_recipients" TO "anon";
GRANT SELECT ON TABLE "derm"."manifest_recipients" TO "authenticated";



GRANT SELECT ON TABLE "derm"."manifest_visits" TO "anon";
GRANT SELECT ON TABLE "derm"."manifest_visits" TO "authenticated";
GRANT ALL ON TABLE "derm"."manifest_visits" TO "service_role";



GRANT ALL ON TABLE "public"."jobs" TO "service_role";
GRANT SELECT ON TABLE "public"."jobs" TO "anon";
GRANT SELECT ON TABLE "public"."jobs" TO "authenticated";
GRANT SELECT ON TABLE "public"."jobs" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."line_items" TO "service_role";
GRANT SELECT ON TABLE "public"."line_items" TO "anon";
GRANT SELECT ON TABLE "public"."line_items" TO "authenticated";
GRANT SELECT ON TABLE "public"."line_items" TO "yannick_readonly";



GRANT SELECT ON TABLE "derm"."visits" TO "anon";
GRANT SELECT ON TABLE "derm"."visits" TO "authenticated";
GRANT ALL ON TABLE "derm"."visits" TO "service_role";









GRANT SELECT ON TABLE "ops"."client_jobs" TO "anon";
GRANT SELECT ON TABLE "ops"."client_jobs" TO "authenticated";
GRANT SELECT ON TABLE "ops"."client_jobs" TO "service_role";
GRANT SELECT ON TABLE "ops"."client_jobs" TO "yannick_readonly";



GRANT SELECT ON TABLE "ops"."clients" TO "yannick_readonly";
GRANT SELECT ON TABLE "ops"."clients" TO "anon";
GRANT SELECT ON TABLE "ops"."clients" TO "authenticated";
GRANT SELECT ON TABLE "ops"."clients" TO "service_role";



GRANT ALL ON TABLE "public"."client_locations" TO "anon";
GRANT ALL ON TABLE "public"."client_locations" TO "authenticated";
GRANT ALL ON TABLE "public"."client_locations" TO "service_role";
GRANT SELECT ON TABLE "public"."client_locations" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."invoices" TO "service_role";
GRANT SELECT ON TABLE "public"."invoices" TO "anon";
GRANT SELECT ON TABLE "public"."invoices" TO "authenticated";
GRANT SELECT ON TABLE "public"."invoices" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."visit_locations" TO "anon";
GRANT ALL ON TABLE "public"."visit_locations" TO "authenticated";
GRANT ALL ON TABLE "public"."visit_locations" TO "service_role";
GRANT SELECT ON TABLE "public"."visit_locations" TO "yannick_readonly";



GRANT SELECT ON TABLE "ops"."invoice_locations" TO "anon";
GRANT SELECT ON TABLE "ops"."invoice_locations" TO "authenticated";
GRANT SELECT ON TABLE "ops"."invoice_locations" TO "service_role";
GRANT SELECT ON TABLE "ops"."invoice_locations" TO "yannick_readonly";



GRANT SELECT ON TABLE "ops"."properties" TO "yannick_readonly";
GRANT SELECT ON TABLE "ops"."properties" TO "anon";
GRANT SELECT ON TABLE "ops"."properties" TO "authenticated";
GRANT SELECT ON TABLE "ops"."properties" TO "service_role";



GRANT SELECT ON TABLE "ops"."service_configs" TO "yannick_readonly";
GRANT SELECT ON TABLE "ops"."service_configs" TO "anon";
GRANT SELECT ON TABLE "ops"."service_configs" TO "authenticated";
GRANT SELECT ON TABLE "ops"."service_configs" TO "service_role";



GRANT ALL ON TABLE "public"."service_line_items" TO "anon";
GRANT ALL ON TABLE "public"."service_line_items" TO "authenticated";
GRANT ALL ON TABLE "public"."service_line_items" TO "service_role";
GRANT SELECT ON TABLE "public"."service_line_items" TO "yannick_readonly";



GRANT SELECT ON TABLE "ops"."service_options" TO "anon";
GRANT SELECT ON TABLE "ops"."service_options" TO "authenticated";
GRANT SELECT ON TABLE "ops"."service_options" TO "service_role";
GRANT SELECT ON TABLE "ops"."service_options" TO "yannick_readonly";



GRANT SELECT ON TABLE "ops"."v_ar_aging" TO "yannick_readonly";
GRANT SELECT ON TABLE "ops"."v_ar_aging" TO "anon";
GRANT SELECT ON TABLE "ops"."v_ar_aging" TO "authenticated";
GRANT SELECT ON TABLE "ops"."v_ar_aging" TO "service_role";



GRANT SELECT ON TABLE "ops"."v_billing_by_location" TO "anon";
GRANT SELECT ON TABLE "ops"."v_billing_by_location" TO "authenticated";
GRANT SELECT ON TABLE "ops"."v_billing_by_location" TO "service_role";
GRANT SELECT ON TABLE "ops"."v_billing_by_location" TO "yannick_readonly";



GRANT SELECT ON TABLE "ops"."v_calendar_driver" TO "anon";
GRANT SELECT ON TABLE "ops"."v_calendar_driver" TO "authenticated";
GRANT SELECT ON TABLE "ops"."v_calendar_driver" TO "service_role";
GRANT SELECT ON TABLE "ops"."v_calendar_driver" TO "yannick_readonly";



GRANT SELECT ON TABLE "ops"."v_calendar_truck" TO "anon";
GRANT SELECT ON TABLE "ops"."v_calendar_truck" TO "authenticated";
GRANT SELECT ON TABLE "ops"."v_calendar_truck" TO "service_role";
GRANT SELECT ON TABLE "ops"."v_calendar_truck" TO "yannick_readonly";



GRANT SELECT ON TABLE "ops"."v_calendar_visit" TO "anon";
GRANT SELECT ON TABLE "ops"."v_calendar_visit" TO "authenticated";
GRANT SELECT ON TABLE "ops"."v_calendar_visit" TO "service_role";
GRANT SELECT ON TABLE "ops"."v_calendar_visit" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."entity_source_links" TO "service_role";
GRANT SELECT ON TABLE "public"."entity_source_links" TO "yannick_readonly";



GRANT SELECT ON TABLE "ops"."v_calendar_visit_detail" TO "anon";
GRANT SELECT ON TABLE "ops"."v_calendar_visit_detail" TO "authenticated";
GRANT SELECT ON TABLE "ops"."v_calendar_visit_detail" TO "service_role";
GRANT SELECT ON TABLE "ops"."v_calendar_visit_detail" TO "yannick_readonly";



GRANT SELECT ON TABLE "ops"."v_derm_compliance" TO "yannick_readonly";
GRANT SELECT ON TABLE "ops"."v_derm_compliance" TO "anon";
GRANT SELECT ON TABLE "ops"."v_derm_compliance" TO "authenticated";
GRANT SELECT ON TABLE "ops"."v_derm_compliance" TO "service_role";



GRANT SELECT ON TABLE "ops"."v_driver_kpi" TO "yannick_readonly";
GRANT SELECT ON TABLE "ops"."v_driver_kpi" TO "anon";
GRANT SELECT ON TABLE "ops"."v_driver_kpi" TO "authenticated";
GRANT SELECT ON TABLE "ops"."v_driver_kpi" TO "service_role";



GRANT SELECT ON TABLE "ops"."v_gdo_expiry" TO "yannick_readonly";
GRANT SELECT ON TABLE "ops"."v_gdo_expiry" TO "anon";
GRANT SELECT ON TABLE "ops"."v_gdo_expiry" TO "authenticated";
GRANT SELECT ON TABLE "ops"."v_gdo_expiry" TO "service_role";



GRANT SELECT ON TABLE "ops"."v_revenue_summary" TO "yannick_readonly";
GRANT SELECT ON TABLE "ops"."v_revenue_summary" TO "anon";
GRANT SELECT ON TABLE "ops"."v_revenue_summary" TO "authenticated";
GRANT SELECT ON TABLE "ops"."v_revenue_summary" TO "service_role";



GRANT SELECT ON TABLE "ops"."v_route_today" TO "yannick_readonly";
GRANT SELECT ON TABLE "ops"."v_route_today" TO "anon";
GRANT SELECT ON TABLE "ops"."v_route_today" TO "authenticated";
GRANT SELECT ON TABLE "ops"."v_route_today" TO "service_role";



GRANT SELECT ON TABLE "ops"."v_service_due" TO "yannick_readonly";
GRANT SELECT ON TABLE "ops"."v_service_due" TO "anon";
GRANT SELECT ON TABLE "ops"."v_service_due" TO "authenticated";
GRANT SELECT ON TABLE "ops"."v_service_due" TO "service_role";



GRANT SELECT ON TABLE "ops"."v_truck_utilization" TO "yannick_readonly";
GRANT SELECT ON TABLE "ops"."v_truck_utilization" TO "anon";
GRANT SELECT ON TABLE "ops"."v_truck_utilization" TO "authenticated";
GRANT SELECT ON TABLE "ops"."v_truck_utilization" TO "service_role";



GRANT SELECT ON TABLE "ops"."vehicles" TO "yannick_readonly";
GRANT SELECT ON TABLE "ops"."vehicles" TO "anon";
GRANT SELECT ON TABLE "ops"."vehicles" TO "authenticated";
GRANT SELECT ON TABLE "ops"."vehicles" TO "service_role";



GRANT SELECT ON TABLE "ops"."visits" TO "yannick_readonly";
GRANT SELECT ON TABLE "ops"."visits" TO "anon";
GRANT SELECT ON TABLE "ops"."visits" TO "authenticated";
GRANT SELECT ON TABLE "ops"."visits" TO "service_role";



GRANT SELECT,MAINTAIN ON TABLE "public"."app_shift_reviews" TO "anon";
GRANT ALL ON TABLE "public"."app_shift_reviews" TO "authenticated";
GRANT ALL ON TABLE "public"."app_shift_reviews" TO "service_role";
GRANT SELECT ON TABLE "public"."app_shift_reviews" TO "yannick_readonly";



GRANT SELECT,MAINTAIN ON TABLE "public"."app_visit_reviews" TO "anon";
GRANT ALL ON TABLE "public"."app_visit_reviews" TO "authenticated";
GRANT ALL ON TABLE "public"."app_visit_reviews" TO "service_role";
GRANT SELECT ON TABLE "public"."app_visit_reviews" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."client_contacts_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."client_contacts_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."client_contacts_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."client_contacts_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."client_groups_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."client_groups_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."client_groups_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."client_groups_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."client_locations_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."client_locations_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."client_locations_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."client_locations_id_seq" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."client_services_flat" TO "anon";
GRANT ALL ON TABLE "public"."client_services_flat" TO "authenticated";
GRANT ALL ON TABLE "public"."client_services_flat" TO "service_role";
GRANT SELECT ON TABLE "public"."client_services_flat" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."clients_due_service" TO "anon";
GRANT ALL ON TABLE "public"."clients_due_service" TO "authenticated";
GRANT ALL ON TABLE "public"."clients_due_service" TO "service_role";
GRANT SELECT ON TABLE "public"."clients_due_service" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."clients_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."clients_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."clients_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."clients_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."derm_address_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."derm_address_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."derm_address_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."derm_address_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."derm_email_sends_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."derm_email_sends_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."derm_email_sends_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."derm_email_sends_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."derm_manifest_number_proposals_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."derm_manifest_number_proposals_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."derm_manifest_number_proposals_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."derm_manifest_number_proposals_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."derm_manifests_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."derm_manifests_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."derm_manifests_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."derm_manifests_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."disposal_facilities_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."disposal_facilities_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."disposal_facilities_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."disposal_facilities_id_seq" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."driver_inspection_status" TO "anon";
GRANT ALL ON TABLE "public"."driver_inspection_status" TO "authenticated";
GRANT ALL ON TABLE "public"."driver_inspection_status" TO "service_role";
GRANT SELECT ON TABLE "public"."driver_inspection_status" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."employees_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."employees_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."employees_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."employees_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."entity_source_links_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."entity_source_links_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."entity_source_links_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."entity_source_links_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."gdos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."gdos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."gdos_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."gdos_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."inspections_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."inspections_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."inspections_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."inspections_id_seq" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."inspections_with_review" TO "anon";
GRANT ALL ON TABLE "public"."inspections_with_review" TO "authenticated";
GRANT ALL ON TABLE "public"."inspections_with_review" TO "service_role";
GRANT SELECT ON TABLE "public"."inspections_with_review" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."invoices_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."invoices_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."invoices_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."invoices_id_seq" TO "yannick_readonly";



GRANT SELECT,MAINTAIN ON TABLE "public"."jobber_oversized_attachments" TO "anon";
GRANT ALL ON TABLE "public"."jobber_oversized_attachments" TO "authenticated";
GRANT ALL ON TABLE "public"."jobber_oversized_attachments" TO "service_role";
GRANT SELECT ON TABLE "public"."jobber_oversized_attachments" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."jobber_oversized_attachments_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."jobber_oversized_attachments_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."jobber_oversized_attachments_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."jobber_oversized_attachments_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."jobs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."jobs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."jobs_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."jobs_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."line_items_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."line_items_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."line_items_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."line_items_id_seq" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."manifest_detail" TO "anon";
GRANT ALL ON TABLE "public"."manifest_detail" TO "authenticated";
GRANT ALL ON TABLE "public"."manifest_detail" TO "service_role";
GRANT SELECT ON TABLE "public"."manifest_detail" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."manifest_pickable_visits" TO "anon";
GRANT ALL ON TABLE "public"."manifest_pickable_visits" TO "authenticated";
GRANT ALL ON TABLE "public"."manifest_pickable_visits" TO "service_role";
GRANT SELECT ON TABLE "public"."manifest_pickable_visits" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."municipality_regulators_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."municipality_regulators_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."municipality_regulators_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."municipality_regulators_id_seq" TO "yannick_readonly";



GRANT SELECT,MAINTAIN ON TABLE "public"."notes" TO "anon";
GRANT ALL ON TABLE "public"."notes" TO "authenticated";
GRANT ALL ON TABLE "public"."notes" TO "service_role";
GRANT SELECT ON TABLE "public"."notes" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."notes_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."notes_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."notes_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."notes_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."photo_classifications_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."photo_classifications_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."photo_classifications_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."photo_classifications_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."photo_links_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."photo_links_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."photo_links_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."photo_links_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."photos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."photos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."photos_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."photos_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."properties_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."properties_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."properties_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."properties_id_seq" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."quotes" TO "service_role";
GRANT SELECT ON TABLE "public"."quotes" TO "anon";
GRANT SELECT ON TABLE "public"."quotes" TO "authenticated";
GRANT SELECT ON TABLE "public"."quotes" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."quotes_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."quotes_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."quotes_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."quotes_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."service_configs_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."service_configs_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."service_configs_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."service_configs_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."service_line_items_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."service_line_items_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."service_line_items_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."service_line_items_id_seq" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."shift_reviews" TO "anon";
GRANT ALL ON TABLE "public"."shift_reviews" TO "authenticated";
GRANT ALL ON TABLE "public"."shift_reviews" TO "service_role";
GRANT SELECT ON TABLE "public"."shift_reviews" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."sync_cursors" TO "service_role";
GRANT SELECT ON TABLE "public"."sync_cursors" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."sync_log" TO "service_role";
GRANT SELECT ON TABLE "public"."sync_log" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."sync_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sync_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sync_log_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."sync_log_id_seq" TO "yannick_readonly";



GRANT SELECT,MAINTAIN ON TABLE "public"."vehicle_telemetry_readings" TO "anon";
GRANT ALL ON TABLE "public"."vehicle_telemetry_readings" TO "authenticated";
GRANT ALL ON TABLE "public"."vehicle_telemetry_readings" TO "service_role";
GRANT SELECT ON TABLE "public"."vehicle_telemetry_readings" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."v_vehicle_telemetry_latest" TO "anon";
GRANT ALL ON TABLE "public"."v_vehicle_telemetry_latest" TO "authenticated";
GRANT ALL ON TABLE "public"."v_vehicle_telemetry_latest" TO "service_role";
GRANT SELECT ON TABLE "public"."v_vehicle_telemetry_latest" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."vehicle_fuel_readings_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."vehicle_fuel_readings_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."vehicle_fuel_readings_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."vehicle_fuel_readings_id_seq" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."vehicles_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."vehicles_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."vehicles_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."vehicles_id_seq" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."visit_manhole_options" TO "anon";
GRANT ALL ON TABLE "public"."visit_manhole_options" TO "authenticated";
GRANT ALL ON TABLE "public"."visit_manhole_options" TO "service_role";
GRANT SELECT ON TABLE "public"."visit_manhole_options" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."visit_recommendations_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."visit_recommendations_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."visit_recommendations_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."visit_recommendations_id_seq" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."visit_reviews" TO "anon";
GRANT ALL ON TABLE "public"."visit_reviews" TO "authenticated";
GRANT ALL ON TABLE "public"."visit_reviews" TO "service_role";
GRANT SELECT ON TABLE "public"."visit_reviews" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."visit_sync_flags" TO "anon";
GRANT ALL ON TABLE "public"."visit_sync_flags" TO "authenticated";
GRANT ALL ON TABLE "public"."visit_sync_flags" TO "service_role";
GRANT SELECT ON TABLE "public"."visit_sync_flags" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."visits_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."visits_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."visits_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."visits_id_seq" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."visits_recent" TO "anon";
GRANT ALL ON TABLE "public"."visits_recent" TO "authenticated";
GRANT ALL ON TABLE "public"."visits_recent" TO "service_role";
GRANT SELECT ON TABLE "public"."visits_recent" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."visits_with_review" TO "anon";
GRANT ALL ON TABLE "public"."visits_with_review" TO "authenticated";
GRANT ALL ON TABLE "public"."visits_with_review" TO "service_role";
GRANT SELECT ON TABLE "public"."visits_with_review" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."visits_with_status" TO "anon";
GRANT ALL ON TABLE "public"."visits_with_status" TO "authenticated";
GRANT ALL ON TABLE "public"."visits_with_status" TO "service_role";
GRANT SELECT ON TABLE "public"."visits_with_status" TO "yannick_readonly";



GRANT SELECT,MAINTAIN ON TABLE "public"."webhook_events_log" TO "anon";
GRANT ALL ON TABLE "public"."webhook_events_log" TO "authenticated";
GRANT ALL ON TABLE "public"."webhook_events_log" TO "service_role";
GRANT SELECT ON TABLE "public"."webhook_events_log" TO "yannick_readonly";



GRANT ALL ON SEQUENCE "public"."webhook_events_log_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."webhook_events_log_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."webhook_events_log_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."webhook_events_log_id_seq" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."webhook_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."zones" TO "service_role";
GRANT SELECT ON TABLE "public"."zones" TO "yannick_readonly";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."zones" TO "anon";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."zones" TO "authenticated";



GRANT ALL ON SEQUENCE "public"."zones_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."zones_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."zones_id_seq" TO "service_role";
GRANT SELECT ON SEQUENCE "public"."zones_id_seq" TO "yannick_readonly";



GRANT ALL ON TABLE "public"."zones_with_usage" TO "anon";
GRANT ALL ON TABLE "public"."zones_with_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."zones_with_usage" TO "service_role";
GRANT SELECT ON TABLE "public"."zones_with_usage" TO "yannick_readonly";



GRANT ALL ON TABLE "raw"."jobber_pull_clients" TO "service_role";



GRANT ALL ON TABLE "raw"."jobber_pull_invoices" TO "service_role";



GRANT ALL ON TABLE "raw"."jobber_pull_jobs" TO "service_role";



GRANT ALL ON TABLE "raw"."jobber_pull_line_items" TO "service_role";



GRANT ALL ON TABLE "raw"."jobber_pull_properties" TO "service_role";



GRANT ALL ON TABLE "raw"."jobber_pull_quotes" TO "service_role";



GRANT ALL ON TABLE "raw"."jobber_pull_users" TO "service_role";



GRANT ALL ON TABLE "raw"."jobber_pull_visits" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "derm" GRANT SELECT ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "derm" GRANT SELECT ON TABLES TO "authenticated";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "ops" GRANT SELECT ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "ops" GRANT SELECT ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "ops" GRANT SELECT ON TABLES TO "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "ops" GRANT SELECT ON TABLES TO "yannick_readonly";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT ON SEQUENCES TO "yannick_readonly";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT ON TABLES TO "yannick_readonly";































