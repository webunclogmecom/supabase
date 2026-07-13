-- 2026-07-13 — freeze visit line items on completion (line-item propagation B2)
--
-- WHY: for DB-mastered completions (source supabase_cron/visit-calendar), handleVisit early-returns
-- before its line_items block, so completed SA visits get no visit-scoped line_items and the customer
-- work order goes blank (and this becomes the norm as Jobber sunsets). This trigger freezes the
-- visit's effective services at completion: if the visit already has its own visit-scoped lines
-- (SC / manual Calendar visits) it keeps them; if it has none but its job carries a template (SA jobs),
-- it snapshots the job's job-scoped lines onto the visit. Pure INSERT into line_items (no visits write,
-- no line_items_rev bump) -> no Jobber push, no trigger cascade. DERM is NOT re-derived here:
-- fn_visit_requires_derm already unions job scope and the nightly derm-required-rederive cron backstops.
-- Audit: line_items stays audit-opt-out (ADR-010); trigger adds no human-editable field. Jobber-mastered
-- (source='jobber') visits are excluded (handleVisit already materializes their real visit lines).

CREATE OR REPLACE FUNCTION public.fn_freeze_visit_line_items()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.job_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.line_items li WHERE li.visit_id = NEW.id)
     AND EXISTS (SELECT 1 FROM public.line_items li
                  WHERE li.job_id = NEW.job_id AND li.visit_id IS NULL
                    AND li.invoice_id IS NULL AND li.quote_id IS NULL)
  THEN
    INSERT INTO public.line_items (visit_id, name, description, quantity, unit_price, total_price, taxable)
    SELECT NEW.id, li.name, li.description, li.quantity, li.unit_price, li.total_price, li.taxable
    FROM public.line_items li
    WHERE li.job_id = NEW.job_id AND li.visit_id IS NULL AND li.invoice_id IS NULL AND li.quote_id IS NULL;
  END IF;
  RETURN NULL;  -- AFTER trigger
END;
$$;

DROP TRIGGER IF EXISTS trg_zz_freeze_line_items_on_complete ON public.visits;
CREATE TRIGGER trg_zz_freeze_line_items_on_complete
  AFTER UPDATE OF visit_status ON public.visits
  FOR EACH ROW
  WHEN (NEW.visit_status = 'completed'
        AND OLD.visit_status IS DISTINCT FROM 'completed'
        AND NEW.source IN ('supabase_cron','visit-calendar'))
  EXECUTE FUNCTION public.fn_freeze_visit_line_items();
