-- ROLLBACK of 2026-10-16_1730_intake_show_if_value_list. Run AFTER rolling back any question list that uses "|"
-- (version 4, 2026-10-16_1745), or forms of that version would show both follow-ups to nobody.
BEGIN;
SET LOCAL lock_timeout = '3s';
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
DO $v$ BEGIN
  IF md5(pg_get_functiondef('public.fn_intake_applicable'::regproc)) IS DISTINCT FROM 'a28ac207c1aab383da525bc78ef52184' THEN
    RAISE EXCEPTION 'rollback: body is not the pre-1730 one'; END IF;
END $v$;
COMMIT;
