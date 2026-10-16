-- ============================================================================
-- 2026-10-16_1730 Site survey follow-ups: a show_if value may be a list "A|B"
-- ============================================================================
-- THE ASK
--   Fred and Yan, 2026-10-16: "Where is the equipment located?" gets a third answer, "Inside / Outside / Inside and
--   Outside. Picking Inside and Outside asks both follow-ups, 'Where is it inside?' and 'Where is it outside?'".
--   A follow-up today shows for ONE exact answer (show_if "key=value"), so "Where is it inside?" cannot show for
--   two answers. This migration is the READER half (rule 13 of docs/reference/client-intake-system.md: reader
--   first, writer second): public.fn_intake_applicable accepts "key=A|B" (shown when the parent's trimmed answer is
--   any of the items, each trimmed). A value with no "|" is compared exactly as before, so "key=" (left blank)
--   is unchanged. The collector form's visible() gets the same rule in form-page.ts (same change). No question
--   list uses "|" yet; version 4 (the next migration) is the first.
--   Unchanged on purpose: public.fn_intake_parent_key (the text before the operator) and the Client App's
--   intakeParentKey, which read only the parent key.
-- VERIFY: every stored intake reads exactly as before for every question (old body kept as a temp function and
--   compared), and a synthetic list condition behaves as specified. Rule 8: no table. Spliced from the live body,
--   md5-pinned; grants unchanged.
-- ROLLBACK: 2026-10-16_rollback_intake_show_if_value_list.sql
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
DO $g$ BEGIN
  IF md5(pg_get_functiondef('public.fn_intake_applicable'::regproc)) IS DISTINCT FROM 'a28ac207c1aab383da525bc78ef52184' THEN
    RAISE EXCEPTION 'fn_intake_applicable changed since this file was written: splice again';
  END IF;
END $g$;
CREATE TEMP TABLE acl_before ON COMMIT DROP AS SELECT proacl::text AS a FROM pg_proc WHERE oid = 'public.fn_intake_applicable'::regproc;

CREATE FUNCTION pg_temp.fn_applicable_before(p_snapshot jsonb, p_answers jsonb, p_key text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
  v_key    text := p_key;
  v_show   text;
  v_pos    int;
  v_op     text;
  v_parent text;
  v_want   text;
  v_got    text;
  v_depth  int := 0;
begin
  loop
    v_show := null;
    select q ->> 'show_if' into v_show
      from jsonb_array_elements(coalesce(p_snapshot -> 'sections', '[]'::jsonb)) s,
           jsonb_array_elements(coalesce(s -> 'questions', '[]'::jsonb)) q
     where jsonb_typeof(q) = 'object' and q ->> 'key' = v_key
     limit 1;
    if v_show is null or btrim(v_show) = '' then
      return true;                                   -- no condition: always asked
    end if;
    -- The operator is the FIRST '=' or '>'. LEAST ignores NULL, so a missing one drops out.
    v_pos := least(nullif(position('=' in v_show), 0), nullif(position('>' in v_show), 0));
    if v_pos is null then
      return true;                                   -- no operator: not a condition
    end if;
    v_op     := substr(v_show, v_pos, 1);
    v_parent := public.fn_intake_trim(substr(v_show, 1, v_pos - 1));
    v_want   := public.fn_intake_trim(substr(v_show, v_pos + 1));
    v_got    := public.fn_intake_trim(coalesce(p_answers -> v_parent ->> 'value', ''));
    if v_op = '=' then
      if v_got is distinct from v_want then
        return false;                                -- the form hid it
      end if;
    else
      -- '>': a number above the threshold. CASE, not OR, so the cast never runs on text.
      -- v_got is already trimmed by the JS set; the pattern is ASCII only, so the cast cannot raise.
      if not (case when v_got ~ '^-?[0-9]+([.][0-9]+)?$'
                    and v_want ~ '^-?[0-9]+([.][0-9]+)?$'
                   then v_got::numeric > v_want::numeric
                   else false end) then
        return false;
      end if;
    end if;
    v_depth := v_depth + 1;
    if v_depth >= 10 then
      return true;                                   -- a cycle in an authored tree: stay visible
    end if;
    v_key := v_parent;                               -- the parent must itself have been shown
  end loop;
end $function$;

CREATE OR REPLACE FUNCTION public.fn_intake_applicable(p_snapshot jsonb, p_answers jsonb, p_key text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO ''
AS $function$
declare
  v_key    text := p_key;
  v_show   text;
  v_pos    int;
  v_op     text;
  v_parent text;
  v_want   text;
  v_got    text;
  v_depth  int := 0;
begin
  loop
    v_show := null;
    select q ->> 'show_if' into v_show
      from jsonb_array_elements(coalesce(p_snapshot -> 'sections', '[]'::jsonb)) s,
           jsonb_array_elements(coalesce(s -> 'questions', '[]'::jsonb)) q
     where jsonb_typeof(q) = 'object' and q ->> 'key' = v_key
     limit 1;
    if v_show is null or btrim(v_show) = '' then
      return true;                                   -- no condition: always asked
    end if;
    -- The operator is the FIRST '=' or '>'. LEAST ignores NULL, so a missing one drops out.
    v_pos := least(nullif(position('=' in v_show), 0), nullif(position('>' in v_show), 0));
    if v_pos is null then
      return true;                                   -- no operator: not a condition
    end if;
    v_op     := substr(v_show, v_pos, 1);
    v_parent := public.fn_intake_trim(substr(v_show, 1, v_pos - 1));
    v_want   := public.fn_intake_trim(substr(v_show, v_pos + 1));
    v_got    := public.fn_intake_trim(coalesce(p_answers -> v_parent ->> 'value', ''));
    if v_op = '=' then
      -- Since question list version 4 the value may be a list "A|B": shown when the parent is any of them, each
      -- trimmed. A value with no "|" is compared exactly as before (an empty value still means "left blank").
      if (case when position('|' in v_want) = 0 then v_got is distinct from v_want
               else not (v_got = any (array(select public.fn_intake_trim(x) from unnest(string_to_array(v_want, '|')) x)))
          end) then
        return false;                                -- the form hid it
      end if;
    else
      -- '>': a number above the threshold. CASE, not OR, so the cast never runs on text.
      -- v_got is already trimmed by the JS set; the pattern is ASCII only, so the cast cannot raise.
      if not (case when v_got ~ '^-?[0-9]+([.][0-9]+)?$'
                    and v_want ~ '^-?[0-9]+([.][0-9]+)?$'
                   then v_got::numeric > v_want::numeric
                   else false end) then
        return false;
      end if;
    end if;
    v_depth := v_depth + 1;
    if v_depth >= 10 then
      return true;                                   -- a cycle in an authored tree: stay visible
    end if;
    v_key := v_parent;                               -- the parent must itself have been shown
  end loop;
end $function$;

DO $v$
DECLARE n int; d int; s jsonb;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE pg_temp.fn_applicable_before(i.form_snapshot, i.answers, q->>'key')
                                     IS DISTINCT FROM public.fn_intake_applicable(i.form_snapshot, i.answers, q->>'key'))
    INTO n, d
    FROM public.property_intakes i,
         jsonb_array_elements(coalesce(i.form_snapshot->'sections','[]'::jsonb)) sec,
         jsonb_array_elements(coalesce(sec->'questions','[]'::jsonb)) q
   WHERE jsonb_typeof(q) = 'object';
  IF n = 0 THEN RAISE EXCEPTION 'VERIFY: no stored question to compare: the check proves nothing'; END IF;
  IF d <> 0 THEN RAISE EXCEPTION 'VERIFY: % of % stored questions read differently', d, n; END IF;
  s := '{"sections":[{"questions":[{"key":"p","type":"choice"},{"key":"c","show_if":"p= Inside | Inside and Outside "},{"key":"b","show_if":"p="},{"key":"g","show_if":"c=x"}]}]}';
  IF NOT public.fn_intake_applicable(s, '{"p":{"value":"Inside"}}', 'c') THEN RAISE EXCEPTION 'VERIFY: first item'; END IF;
  IF NOT public.fn_intake_applicable(s, '{"p":{"value":" Inside and Outside"}}', 'c') THEN RAISE EXCEPTION 'VERIFY: second item'; END IF;
  IF public.fn_intake_applicable(s, '{"p":{"value":"Outside"}}', 'c') THEN RAISE EXCEPTION 'VERIFY: not in the list'; END IF;
  IF public.fn_intake_applicable(s, '{}', 'c') THEN RAISE EXCEPTION 'VERIFY: blank parent showed a list follow-up'; END IF;
  IF NOT public.fn_intake_applicable(s, '{}', 'b') THEN RAISE EXCEPTION 'VERIFY: key= no longer means left blank'; END IF;
  IF public.fn_intake_applicable(s, '{"p":{"value":"Outside"},"c":{"value":"x"}}', 'g') THEN RAISE EXCEPTION 'VERIFY: hidden parent did not hide its child'; END IF;
  IF NOT public.fn_intake_applicable(s, '{"p":{"value":"Inside"},"c":{"value":"x"}}', 'g') THEN RAISE EXCEPTION 'VERIFY: chain through a list'; END IF;
  IF (SELECT proacl::text FROM pg_proc WHERE oid = 'public.fn_intake_applicable'::regproc) IS DISTINCT FROM (SELECT a FROM acl_before) THEN
    RAISE EXCEPTION 'VERIFY: grants moved'; END IF;
  RAISE NOTICE 'VERIFY passed: % stored questions unchanged', n;
END $v$;
COMMIT;
