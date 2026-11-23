-- 2026-11-23_1830_page_survey_no.sql
--
-- WHAT: a Site file page may carry `survey_no`: the intake-form answers the builder answered No to, each with the
--   form's value and an optional reason. Two anchored edits of the LIVE bodies (pg_get_functiondef, md5 pinned),
--   never retyped:
--   1. public.fn_page_content_problem accepts the top-level key `survey_no` and checks its shape
--      ({ "<fact key>": { "form": text | number | null, "note": text | null } }, at most 40 keys, 500 characters each).
--   2. public.fn_driver_page strips it: `content - 'photos' - 'survey_no'`. The reasons are for the approver, NEVER for
--      the public Site file (drivers and clients).
--
-- WHY (Trello #244, Fred 2026-11-23): "let's add Yes/No buttons instead of the this `<-` "arrows", and when pressed "No"
--   we need to add an optional box explaining why is different from that value." He picked Y2 on
--   mockups/2026-11-23-planner-photos-244.html. Without (1) a page carrying a reason is refused at Submit with "The page
--   could not be read" (the validator refuses any key it does not know); without (2) the reason would reach the public
--   Site file through driver-page.
--
-- READERS OF page content (measured 2026-11-23, every function/view in public/client/ops/derm/customer/hr naming
--   property_pages): public: fn_driver_page only (service_role; the driver-page edge fn). Staff only: client.get_page_builder,
--   get_page_versions, page_builder_list, approve_property_page, submit_property_page. ops.portal_my_work only tests that an
--   approved page EXISTS. No view reads it.
--
-- AUDIT (rule 8): no table changes; property_pages keeps its audit trigger.
-- ROLLBACK: 2026-11-23_1830_page_survey_no_rollback.sql (md5-guarded on the new bodies). A page already saved WITH
--   survey_no stays readable after a rollback only by staff; a resubmit of it would be refused until survey_no is removed.

BEGIN;
SET LOCAL lock_timeout = '3s';

DO $mig$
DECLARE
  d_prob text := pg_get_functiondef('public.fn_page_content_problem(bigint,jsonb)'::regprocedure);
  d_drv  text := pg_get_functiondef('public.fn_driver_page(text,boolean,text)'::regprocedure);
  a1 text := $a$where k not in ('v','facts','hours','notes','contacts','include_map','photos'))$a$;
  b1 text := $a$where k not in ('v','facts','hours','notes','contacts','include_map','photos','survey_no'))$a$;
  a2 text := $a$  -- photos must be a list$a$;
  b2 text := $a$  -- Trello #244: the form answers the builder answered No to, with the form's value and an optional reason.
  -- Staff read it (the approver's review); fn_driver_page strips it, so drivers and clients never see it.
  if p ? 'survey_no' and jsonb_typeof(p -> 'survey_no') <> 'null' then
    if jsonb_typeof(p -> 'survey_no') <> 'object' then return 'The page could not be read. Reload the Page Builder and try again.'; end if;
    if (select count(*) from jsonb_object_keys(p -> 'survey_no')) > 40 then return 'A page holds at most 40 answers not taken from the form.'; end if;
    if exists (select 1 from jsonb_each(p -> 'survey_no') e(k, val)
                where k !~ '^[a-z_]{1,60}$'
                   or jsonb_typeof(val) <> 'object'
                   or exists (select 1 from jsonb_object_keys(val) kk where kk not in ('form','note'))
                   or coalesce(jsonb_typeof(val -> 'form'), 'null') not in ('string','number','null')
                   or coalesce(jsonb_typeof(val -> 'note'), 'null') not in ('string','null')
                   or length(coalesce(val ->> 'form', '')) > 500
                   or length(coalesce(val ->> 'note', '')) > 500
                   or translate(coalesce(val ->> 'note', ''), E'\n\t', '') ~ '[[:cntrl:]]') then
      return 'Each answer not taken from the form keeps the form''s value and a reason of 500 characters at most.';
    end if;
  end if;

  -- photos must be a list$a$;
  a3 text := $a$'content', v_page.content - 'photos',$a$;
  b3 text := $a$'content', v_page.content - 'photos' - 'survey_no',$a$;
  ok_page jsonb := '{"v":1,"facts":{},"photos":[],"survey_no":{"cleanouts":{"form":3,"note":"Only 2 are ours."},"gate":{"form":"yes","note":null}}}';
  n int;
BEGIN
  IF md5(d_prob) <> 'e1374f5bf701ca3b99fabda62cdaea2c' THEN RAISE EXCEPTION 'fn_page_content_problem changed since this file was written: re-copy'; END IF;
  IF md5(d_drv) <> '5e3c205852644f414623aa3182dd418f' THEN RAISE EXCEPTION 'fn_driver_page changed since this file was written: re-copy'; END IF;
  -- control: the OLD validator refuses the key (so the test below can tell the edit worked)
  IF public.fn_page_content_problem(1, ok_page) IS DISTINCT FROM 'The page could not be read. Reload the Page Builder and try again.' THEN
    RAISE EXCEPTION 'CONTROL: the old validator should refuse survey_no, got %', public.fn_page_content_problem(1, ok_page);
  END IF;
  n := (length(d_prob) - length(replace(d_prob, a1, ''))) / length(a1); IF n <> 1 THEN RAISE EXCEPTION 'anchor 1 found % times', n; END IF;
  n := (length(d_prob) - length(replace(d_prob, a2, ''))) / length(a2); IF n <> 1 THEN RAISE EXCEPTION 'anchor 2 found % times', n; END IF;
  n := (length(d_drv) - length(replace(d_drv, a3, ''))) / length(a3);   IF n <> 1 THEN RAISE EXCEPTION 'anchor 3 found % times', n; END IF;
  EXECUTE replace(replace(d_prob, a1, b1), a2, b2);
  EXECUTE replace(d_drv, a3, b3);
END
$mig$;

-- VERIFY
DO $verify$
DECLARE
  d_prob text := pg_get_functiondef('public.fn_page_content_problem(bigint,jsonb)'::regprocedure);
  d_drv  text := pg_get_functiondef('public.fn_driver_page(text,boolean,text)'::regprocedure);
  base jsonb := '{"v":1,"facts":{},"photos":[]}';
  bad text := 'Each answer not taken from the form keeps the form''s value and a reason of 500 characters at most.';
  r text;
BEGIN
  -- nothing else moved: undoing the anchored edits gives the old bodies exactly
  IF md5(replace(d_drv, $a$'content', v_page.content - 'photos' - 'survey_no',$a$, $a$'content', v_page.content - 'photos',$a$)) <> '5e3c205852644f414623aa3182dd418f' THEN
    RAISE EXCEPTION 'VERIFY: fn_driver_page differs by more than the strip';
  END IF;
  IF position($a$'photos','survey_no'))$a$ in d_prob) = 0 THEN RAISE EXCEPTION 'VERIFY: survey_no not allowed'; END IF;
  -- behaviour
  IF public.fn_page_content_problem(1, base) IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: a plain page is refused'; END IF;
  r := public.fn_page_content_problem(1, base || '{"survey_no":{"cleanouts":{"form":3,"note":"Only 2 are ours."},"gate":{"form":"yes","note":null},"obstacles":{"form":null,"note":"line one\nline two"}}}');
  IF r IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: a valid survey_no is refused: %', r; END IF;
  IF public.fn_page_content_problem(1, base || '{"survey_no":null}') IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: survey_no null refused'; END IF;
  IF public.fn_page_content_problem(1, base || '{"survey_no":[]}') IS DISTINCT FROM 'The page could not be read. Reload the Page Builder and try again.' THEN RAISE EXCEPTION 'VERIFY: a list passed'; END IF;
  IF public.fn_page_content_problem(1, base || '{"survey_no":{"Cleanouts":{"form":3,"note":null}}}') IS DISTINCT FROM bad THEN RAISE EXCEPTION 'VERIFY: a bad key passed'; END IF;
  IF public.fn_page_content_problem(1, base || '{"survey_no":{"cleanouts":{"form":3,"note":null,"x":1}}}') IS DISTINCT FROM bad THEN RAISE EXCEPTION 'VERIFY: an extra field passed'; END IF;
  IF public.fn_page_content_problem(1, base || '{"survey_no":{"cleanouts":{"form":true,"note":null}}}') IS DISTINCT FROM bad THEN RAISE EXCEPTION 'VERIFY: a boolean form passed'; END IF;
  IF public.fn_page_content_problem(1, base || '{"survey_no":{"cleanouts":3}}') IS DISTINCT FROM bad THEN RAISE EXCEPTION 'VERIFY: a bare value passed'; END IF;
  IF public.fn_page_content_problem(1, base || jsonb_build_object('survey_no', jsonb_build_object('cleanouts', jsonb_build_object('form', 3, 'note', repeat('a', 501))))) IS DISTINCT FROM bad THEN RAISE EXCEPTION 'VERIFY: a long note passed'; END IF;
  IF public.fn_page_content_problem(1, base || jsonb_build_object('survey_no', (select jsonb_object_agg('k' || chr(97 + g / 26) || chr(97 + g % 26), '{"form":1,"note":null}'::jsonb) from generate_series(1, 40) g))) IS NOT NULL THEN RAISE EXCEPTION 'VERIFY: 40 answers refused'; END IF;
  IF public.fn_page_content_problem(1, base || jsonb_build_object('survey_no', (select jsonb_object_agg('k' || chr(97 + g / 26) || chr(97 + g % 26), '{"form":1,"note":null}'::jsonb) from generate_series(1, 41) g))) IS DISTINCT FROM 'A page holds at most 40 answers not taken from the form.' THEN RAISE EXCEPTION 'VERIFY: 41 answers passed'; END IF;
  IF public.fn_page_content_problem(1, base || '{"other":1}') IS DISTINCT FROM 'The page could not be read. Reload the Page Builder and try again.' THEN RAISE EXCEPTION 'VERIFY: another unknown key now passes'; END IF;
  -- the strip itself, on a value shaped like a stored page
  IF ((base || '{"survey_no":{"cleanouts":{"form":3,"note":"x"}}}') - 'photos' - 'survey_no') ? 'survey_no' THEN RAISE EXCEPTION 'VERIFY: strip'; END IF;
END
$verify$;

COMMIT;
