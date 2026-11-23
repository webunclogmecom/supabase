-- 2026-11-23_1830_page_survey_no_rollback.sql
-- Undoes 2026-11-23_1830_page_survey_no.sql: removes the two anchored edits from the live bodies (md5 guarded on the bodies
-- that migration produced, and proven to land back on the original md5s). A page already saved WITH survey_no stays in
-- public.property_pages (append-only); after this rollback a resubmit of it is refused until the Page Builder drops the key.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $rb$
DECLARE
  d_prob text := pg_get_functiondef('public.fn_page_content_problem(bigint,jsonb)'::regprocedure);
  d_drv  text := pg_get_functiondef('public.fn_driver_page(text,boolean,text)'::regprocedure);
  s text; e text; old_prob text; old_drv text;
BEGIN
  -- the inserted validation block runs from its comment to the blank line before "-- photos must be a list"
  s := '  -- Trello #244: the form answers the builder answered No to';
  e := E'\n\n  -- photos must be a list';
  IF position(s in d_prob) = 0 OR position(e in d_prob) = 0 THEN RAISE EXCEPTION 'the new validator is not the one 1830 made'; END IF;
  old_prob := substr(d_prob, 1, position(s in d_prob) - 1) || substr(d_prob, position(e in d_prob) + 2);
  old_prob := replace(old_prob, $a$'photos','survey_no'))$a$, $a$'photos'))$a$);
  old_drv := replace(d_drv, $a$'content', v_page.content - 'photos' - 'survey_no',$a$, $a$'content', v_page.content - 'photos',$a$);
  IF md5(old_prob) <> 'e1374f5bf701ca3b99fabda62cdaea2c' THEN RAISE EXCEPTION 'rebuilt fn_page_content_problem is not the original (md5 %)', md5(old_prob); END IF;
  IF md5(old_drv) <> '5e3c205852644f414623aa3182dd418f' THEN RAISE EXCEPTION 'rebuilt fn_driver_page is not the original'; END IF;
  EXECUTE old_prob;
  EXECUTE old_drv;
  IF md5(pg_get_functiondef('public.fn_page_content_problem(bigint,jsonb)'::regprocedure)) <> 'e1374f5bf701ca3b99fabda62cdaea2c'
     OR md5(pg_get_functiondef('public.fn_driver_page(text,boolean,text)'::regprocedure)) <> '5e3c205852644f414623aa3182dd418f' THEN
    RAISE EXCEPTION 'VERIFY: the rollback did not restore the original bodies';
  END IF;
END
$rb$;

COMMIT;
