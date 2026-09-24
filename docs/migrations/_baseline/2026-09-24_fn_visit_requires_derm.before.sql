CREATE OR REPLACE FUNCTION public.fn_visit_requires_derm(p_visit_id bigint)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE v_any boolean; v_all boolean; v_cnt integer;
BEGIN
  SELECT bool_or(d IS TRUE), bool_and(d IS NOT NULL), count(*)
    INTO v_any, v_all, v_cnt
  FROM (
    SELECT public.fn_line_item_requires_derm(li.name) AS d
    FROM public.visits v
    JOIN public.line_items li
      ON  li.name IS NOT NULL
      AND ( li.visit_id = v.id
            OR (v.invoice_id IS NOT NULL AND li.invoice_id = v.invoice_id)
            OR (v.job_id     IS NOT NULL AND li.job_id     = v.job_id) )
    WHERE v.id = p_visit_id
  ) q;

  IF v_cnt = 0 OR v_cnt IS NULL THEN RETURN NULL; END IF;
  IF v_any THEN RETURN true; END IF;
  IF v_all THEN RETURN false; END IF;
  RETURN NULL;
END;
$function$
