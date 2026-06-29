-- Migration: 2026-06-29e_visit_title_prefix_trigger
-- Author: Claude (Opus 4.8) for Fred
-- Audit: trigger only sets NEW.title pre-INSERT; the row's audit (audit_visits) logs the final value.
--
-- WHY: 2026-06-29c prefixed visit titles ("CODE Name - <title>") only in the SA GENERATOR.
-- Visits created via the Calendar "New Visit" form go through create_calendar_visit (source
-- 'visit-calendar'), which inserts p_title verbatim -> a manually-created SC visit (e.g. Fred's
-- 168-AVA "Service Call") reached Jobber with NO client prefix. Rather than patch each create
-- path, make it a DB-LEVEL INVARIANT: any visit-calendar/supabase_cron insert gets the client
-- prefix. The SA generator's JS prefix (2026-06-29c) is now redundant-but-harmless (the guard
-- below skips an already-prefixed title). Inbound Jobber visits (source 'jobber') are untouched
-- -- Jobber composes their chip from client.name itself.

CREATE OR REPLACE FUNCTION public.fn_prefix_visit_title()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_code text; v_name text;
BEGIN
  IF NEW.source IN ('visit-calendar','supabase_cron')
     AND NEW.title IS NOT NULL AND btrim(NEW.title) <> '' AND NEW.client_id IS NOT NULL THEN
    SELECT client_code, name INTO v_code, v_name FROM public.clients WHERE id = NEW.client_id;
    IF v_code IS NOT NULL AND NEW.title NOT LIKE (v_code || ' %') THEN
      NEW.title := v_code || ' ' || v_name || ' - ' || NEW.title;   -- e.g. "168-AVA AVA - Service Call"
    END IF;
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_prefix_visit_title ON public.visits;
CREATE TRIGGER trg_prefix_visit_title BEFORE INSERT ON public.visits
  FOR EACH ROW EXECUTE FUNCTION public.fn_prefix_visit_title();

-- One-time backfill of existing un-prefixed cron/calendar FUTURE SCHEDULED visits (pending only;
-- never completed). 3 rows: 6835 (168-AVA SC, Fred's), 6808 (106-ALC SC), 6356 (one cron straggler).
-- In-scope rows re-pushed to Jobber (title-only) and verified live (6835 -> "168-AVA AVA - Service Call").
UPDATE public.visits v SET title = c.client_code||' '||c.name||' - '||v.title
FROM public.clients c
WHERE c.id=v.client_id AND v.source IN ('visit-calendar','supabase_cron')
  AND v.visit_status='scheduled' AND v.deleted_at IS NULL AND v.visit_date >= '2026-06-29'
  AND v.title IS NOT NULL AND v.title NOT LIKE (c.client_code||' %');

-- SMOKE TEST (passed, not part of this migration): inserting a bare 'Service Call' visit-calendar
-- row produced "168-AVA AVA - Service Call" automatically. Inbound 'jobber' visits unaffected.
