-- Can pressing "Re-measure printed lines" hide a page's hand-marked geometry?
--
-- 2026-09-02_1330 widened the supersession guard so a FAILED detector run cannot shadow an
-- operator's scan. The guard reads v_grade, which is the grade the CALLER CLAIMED
-- (coalesce(p_meta->>'grade','FAILED')), and it is evaluated BEFORE fn_validate_page_rules runs.
--
-- So the guard only sees a caller that SAYS "FAILED". The detector always claims OK and lets the
-- server decide. If the validator then downgrades it, the guard has already been passed, the scan
-- is written as the newest for the page, and v_page_printed_rules joins rules on THAT scan's own
-- source -- which has none.
--
-- This is not hypothetical for ticket-834489: its real detector run on 2026-09-02 was rejected with
-- "only 1 slot boundaries". That is the exact payload replayed below.
--
-- Everything is rolled back. The report is carried out in the exception message because the
-- Management API discards NOTICE.

DO $$
DECLARE
  v_res   jsonb;
  v_rep   text := '';
  v_n     int;
  -- the REAL rejected payload shape: 7 lines, only 1 of them a boundary
  BAD     constant jsonb := '[
    {"pct":27.892,"run":0.356,"ink":0.5,"kind":"boundary"},
    {"pct":33.306,"run":0.190,"ink":0.5,"kind":"divider"},
    {"pct":38.721,"run":0.190,"ink":0.5,"kind":"divider"},
    {"pct":44.443,"run":0.187,"ink":0.5,"kind":"divider"},
    {"pct":49.449,"run":0.187,"ink":0.5,"kind":"divider"},
    {"pct":54.966,"run":0.190,"ink":0.5,"kind":"divider"},
    {"pct":60.381,"run":0.129,"ink":0.5,"kind":"divider"}]'::jsonb;
BEGIN
  BEGIN
    SELECT count(*) INTO v_n FROM derm.v_page_printed_rules
     WHERE dump_folder='ticket-834489' AND effective_page=1;
    v_rep := v_rep || format('rules_served_BEFORE=%s; ', v_n);

    SELECT source INTO STRICT v_rep FROM (
      SELECT source FROM derm.v_page_printed_rules
       WHERE dump_folder='ticket-834489' AND effective_page=1 LIMIT 1) q;
    v_rep := format('rules_served_BEFORE=%s source_BEFORE=%s; ', v_n, v_rep);

    -- what the Studio's re-measure does: claim OK, let the server judge
    v_res := derm.record_page_rules('ticket-834489', 1, 'runlen-v2-remeasure-probe',
               'https://example.invalid/x.jpg', BAD,
               '{"grade":"OK","source_etag":"probe"}'::jsonb);
    v_rep := v_rep || format('rpc=%s; ', v_res::text);

    SELECT count(*) INTO v_n FROM derm.v_page_printed_rules
     WHERE dump_folder='ticket-834489' AND effective_page=1;
    v_rep := v_rep || format('rules_served_AFTER=%s; ', v_n);

    SELECT coalesce((SELECT source FROM derm.v_page_printed_rules
       WHERE dump_folder='ticket-834489' AND effective_page=1 LIMIT 1),'<none>')
      INTO v_res;
    v_rep := v_rep || format('source_AFTER=%s; ', v_res);

    SELECT count(*) INTO v_n FROM derm.page_row_rules
     WHERE dump_folder='ticket-834489' AND source LIKE 'human-v1-%';
    v_rep := v_rep || format('hand_rules_still_in_table=%s; ', v_n);
  EXCEPTION WHEN OTHERS THEN
    v_rep := v_rep || format('RAISED %s / %s; ', SQLSTATE, SQLERRM);
  END;

  RAISE EXCEPTION 'REMEASURE_PROBE :: %', v_rep USING ERRCODE='ZZ003';
END $$;
