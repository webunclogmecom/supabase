-- 2026-07-04_derm_ocr_flywheel.sql  (rev 2 — post adversarial review)
-- OCR FLYWHEEL: every human-confirmed stamp row becomes a persistent, reusable
-- label (messy handwritten facility text -> true client), so each week of
-- Yannick's stamping makes the next batch's auto-matching better.
-- Review fixes applied:
--   * REVOKE ... FROM PUBLIC (function EXECUTE defaults to PUBLIC; revoking only
--     anon/authenticated was a no-op — anon could have called _upsert_alias and
--     poisoned the label store). Also default-privileges override for future
--     derm functions + retro-fix for derm._require_stamp_key.
--   * pg_trgm installed WITH SCHEMA extensions (Supabase convention) and every
--     consumer's search_path includes extensions.
-- Audit Rule 8: client_aliases is derived tooling data (rebuildable from
-- address_row_map, which IS audited) -> opt-out, documented here.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA extensions;

-- Future derm functions must not default to PUBLIC EXECUTE (review finding).
ALTER DEFAULT PRIVILEGES IN SCHEMA derm REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
-- Retro-fix the same broken-revoke pattern on the existing gate helper.
REVOKE EXECUTE ON FUNCTION derm._require_stamp_key() FROM PUBLIC, anon, authenticated;

-- Normalizer (IMMUTABLE so it can back indexes): lowercase, drop noise words,
-- strip non-alphanumerics.
CREATE OR REPLACE FUNCTION derm.normalize_facility(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT NULLIF(
    regexp_replace(
      regexp_replace(lower(coalesce(p_name,'')), '\m(llc|inc|corp|co|the)\M', '', 'g'),
      '[^a-z0-9]', '', 'g'),
    '')
$$;

-- Label store.
CREATE TABLE IF NOT EXISTS derm.client_aliases (
  id              bigserial PRIMARY KEY,
  client_id       bigint NOT NULL REFERENCES public.clients(id),
  alias_raw       text   NOT NULL,
  alias_norm      text   NOT NULL,
  source          text   NOT NULL,  -- 'human-verify' | 'manual-add' | 'pipeline-high' | 'canonical'
  times_confirmed integer NOT NULL DEFAULT 1,
  first_seen      timestamptz NOT NULL DEFAULT now(),
  last_confirmed  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (alias_norm, client_id)
);
CREATE INDEX IF NOT EXISTS idx_client_aliases_norm      ON derm.client_aliases (alias_norm);
CREATE INDEX IF NOT EXISTS idx_client_aliases_norm_trgm ON derm.client_aliases
  USING gin (alias_norm extensions.gin_trgm_ops);

-- Internal upsert (rank: human sources upgrade pipeline ones, never downgrade).
CREATE OR REPLACE FUNCTION derm._upsert_alias(p_client_id bigint, p_raw text, p_source text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
DECLARE v_norm text;
BEGIN
  v_norm := derm.normalize_facility(p_raw);
  IF v_norm IS NULL OR length(v_norm) < 3 OR p_raw ILIKE '%illegible%' OR p_client_id IS NULL THEN
    RETURN;
  END IF;
  INSERT INTO derm.client_aliases (client_id, alias_raw, alias_norm, source)
  VALUES (p_client_id, left(btrim(p_raw), 200), v_norm, p_source)
  ON CONFLICT (alias_norm, client_id) DO UPDATE SET
    times_confirmed = derm.client_aliases.times_confirmed + 1,
    last_confirmed  = now(),
    source = CASE
      WHEN EXCLUDED.source IN ('human-verify','manual-add')
        OR derm.client_aliases.source IN ('human-verify','manual-add')
      THEN CASE WHEN EXCLUDED.source IN ('human-verify','manual-add')
                THEN EXCLUDED.source ELSE derm.client_aliases.source END
      ELSE derm.client_aliases.source END;
END $$;
REVOKE EXECUTE ON FUNCTION derm._upsert_alias(bigint, text, text) FROM PUBLIC, anon, authenticated;

-- Idempotent bulk refresh (seed now; reran by the pipeline after each load).
CREATE OR REPLACE FUNCTION derm.refresh_client_aliases()
RETURNS TABLE (aliases_total bigint) LANGUAGE plpgsql SECURITY DEFINER
SET search_path = derm, public AS $$
DECLARE r record;
BEGIN
  FOR r IN SELECT c.id, c.name, c.client_code FROM public.clients c WHERE c.client_code IS NOT NULL LOOP
    PERFORM derm._upsert_alias(r.id, r.name, 'canonical');
    PERFORM derm._upsert_alias(r.id, r.client_code, 'canonical');
  END LOOP;
  FOR r IN
    SELECT m.matched_client_id AS cid, m.facility_name_read AS nm,
           CASE WHEN m.reviewed_at IS NOT NULL THEN 'human-verify' ELSE 'pipeline-high' END AS src
    FROM derm.address_row_map m
    WHERE m.matched_client_id IS NOT NULL
      AND m.facility_name_read IS NOT NULL
      AND (m.reviewed_at IS NOT NULL
           OR (m.assignment_status = 'matched' AND m.confidence = 'high'))
  LOOP
    PERFORM derm._upsert_alias(r.cid, r.nm, r.src);
  END LOOP;
  RETURN QUERY SELECT count(*)::bigint FROM derm.client_aliases;
END $$;
REVOKE EXECUTE ON FUNCTION derm.refresh_client_aliases() FROM PUBLIC, anon, authenticated;

-- Live capture: a human Verify or a manual Add instantly writes the label.
CREATE OR REPLACE FUNCTION derm.trg_capture_alias()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = derm, public AS $$
BEGIN
  IF TG_OP = 'UPDATE'
     AND NEW.reviewed_at IS NOT NULL AND OLD.reviewed_at IS NULL
     AND NEW.matched_client_id IS NOT NULL THEN
    PERFORM derm._upsert_alias(NEW.matched_client_id, NEW.facility_name_read, 'human-verify');
  ELSIF TG_OP = 'INSERT'
     AND NEW.source = 'stamp-studio' AND NEW.matched_client_id IS NOT NULL THEN
    PERFORM derm._upsert_alias(NEW.matched_client_id, NEW.facility_name_read, 'manual-add');
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_address_row_map_capture_alias ON derm.address_row_map;
CREATE TRIGGER trg_address_row_map_capture_alias
AFTER INSERT OR UPDATE OF reviewed_at ON derm.address_row_map
FOR EACH ROW EXECUTE FUNCTION derm.trg_capture_alias();

-- Lookup for the ingest pipeline (exact norm first, then trigram fuzzy).
CREATE OR REPLACE FUNCTION derm.lookup_client_alias(p_name text, p_min_similarity real DEFAULT 0.45)
RETURNS TABLE (client_id bigint, client_code text, matched_alias text, sim real, exact_match boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = derm, public, extensions AS $$
  WITH norm AS (SELECT derm.normalize_facility(p_name) AS n)
  SELECT a.client_id, c.client_code, a.alias_raw,
         extensions.similarity(a.alias_norm, norm.n)::real AS sim,
         (a.alias_norm = norm.n) AS exact_match
  FROM derm.client_aliases a
  JOIN public.clients c ON c.id = a.client_id
  CROSS JOIN norm
  WHERE norm.n IS NOT NULL
    AND (a.alias_norm = norm.n OR extensions.similarity(a.alias_norm, norm.n) >= p_min_similarity)
  ORDER BY exact_match DESC, sim DESC, a.times_confirmed DESC
  LIMIT 5
$$;
GRANT EXECUTE ON FUNCTION derm.lookup_client_alias(text, real) TO anon, authenticated;
GRANT SELECT ON derm.client_aliases TO anon, authenticated;

-- Measurement loop: per-sheet extraction quality (+ driver sheet-quality input).
CREATE OR REPLACE VIEW derm.v_extraction_quality AS
SELECT m.dump_folder,
       max(m.white_manifest_number)                              AS white_manifest_number,
       count(*)                                                  AS total_rows,
       count(*) FILTER (WHERE m.assignment_status='matched' AND m.confidence='high'
                          AND coalesce(m.agent_agreement,'') NOT IN ('rematch','alias')) AS auto_matched,
       count(*) FILTER (WHERE m.agent_agreement = 'alias')       AS alias_matched,
       count(*) FILTER (WHERE m.agent_agreement = 'rematch'
                          OR m.source = 'stamp-studio')          AS human_corrected,
       count(*) FILTER (WHERE m.assignment_status = 'unmatched') AS unmatched,
       count(*) FILTER (WHERE m.facility_name_read ILIKE '%illegible%') AS illegible,
       count(*) FILTER (WHERE m.reviewed_at IS NOT NULL)         AS human_reviewed,
       round(100.0 * count(*) FILTER (WHERE m.assignment_status='matched' AND m.confidence='high')
             / NULLIF(count(*),0), 1)                            AS match_rate_pct
FROM derm.address_row_map m
GROUP BY m.dump_folder;
GRANT SELECT ON derm.v_extraction_quality TO anon, authenticated;

COMMIT;
