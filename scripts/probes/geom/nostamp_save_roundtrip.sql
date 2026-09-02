-- Does a save with NO stamp placed actually record anything?
--
-- I previously "verified" the no-stamp save by intercepting window.fetch and returning a canned
-- {wrote:true}. That proved the app SENDS the right call. It proved nothing about what the server
-- does with it, and Fred reports the real answer is "absolutely nothing".
--
-- This is the round trip, against live Prod. The whole thing ends in a RAISE so NOTHING commits:
-- the report is carried out in the exception message, because the Management API discards NOTICE.

DO $$
DECLARE
  v_res  jsonb;
  v_n    int;
  v_rep  text := '';
  RULES  constant jsonb := '[
    {"pct":27.892,"run":0.356,"ink":0.5,"kind":"boundary"},
    {"pct":33.306,"run":0.351,"ink":0.5,"kind":"boundary"},
    {"pct":38.687,"run":0.351,"ink":0.5,"kind":"boundary"},
    {"pct":44.034,"run":0.347,"ink":0.5,"kind":"boundary"},
    {"pct":49.449,"run":0.347,"ink":0.5,"kind":"boundary"},
    {"pct":54.830,"run":0.367,"ink":0.5,"kind":"boundary"},
    {"pct":60.176,"run":0.052,"ink":0.5,"kind":"boundary"}]'::jsonb;
BEGIN
  BEGIN
    -- put the page back to the state Fred was in: nothing placed
    UPDATE derm.address_row_map
       SET stamp_page=NULL, stamp_x_pct=NULL, stamp_y_pct=NULL,
           stamp_placed_at=NULL, stamp_placed_by=NULL,
           band_y0_pct=NULL, band_y1_pct=NULL, band_source=NULL
     WHERE dump_folder='ticket-834489';

    SELECT count(*) INTO v_n FROM derm.address_row_map
     WHERE dump_folder='ticket-834489' AND stamp_placed_at IS NOT NULL;
    v_rep := v_rep || format('placed_after_setup=%s; ', v_n);

    v_res := derm.record_page_rules('ticket-834489', 1, 'human-v1-nostamp-probe',
               'https://example.invalid/probe.jpg', RULES,
               '{"grade":"OK","source_etag":"probe"}'::jsonb);
    v_rep := v_rep || format('rpc=%s; ', v_res::text);

    SELECT count(*) INTO v_n FROM derm.page_row_rules
     WHERE dump_folder='ticket-834489' AND source='human-v1-nostamp-probe';
    v_rep := v_rep || format('rules_written=%s; ', v_n);

    SELECT count(*) INTO v_n FROM derm.v_page_printed_rules
     WHERE dump_folder='ticket-834489' AND source='human-v1-nostamp-probe';
    v_rep := v_rep || format('visible_through_reader=%s; ', v_n);
  EXCEPTION WHEN OTHERS THEN
    v_rep := v_rep || format('RAISED %s / %s; ', SQLSTATE, SQLERRM);
  END;

  -- nothing above is allowed to survive
  RAISE EXCEPTION 'NOSTAMP_PROBE_REPORT :: %', v_rep USING ERRCODE = 'ZZ002';
END $$;
