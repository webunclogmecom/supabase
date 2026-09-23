-- =============================================================================
-- 2026-09-23_1015_client_v_intake_questions.sql
-- Step 5.2 support: the question tree as a VIEW the Client App can read.
--
-- WHY. public.fn_intake_form_current() is the one definition of the current form,
-- but the Client App reads the `client` schema with `.from(...)` on views; it has no
-- reason to call a public-schema function and unpack jsonb in the browser. This
-- flattens the tree into rows so the Schedule Intake checklist is a plain select,
-- ordered, with the L1 section and the L2 question already separated.
--
-- This is a projection, not a second source of truth: it reads
-- fn_intake_form_current() and nothing else, so the function stays the only place a
-- question is defined. The VERIFY block asserts the row count matches the tree.
--
-- RULE 8, AUDIT: a view, nothing to opt in.
-- ATOMIC: no COMMIT, so a failed assertion rolls the whole migration back.
-- =============================================================================

create or replace view client.v_intake_questions as
select
  s.ord::integer                 as section_order,
  s.section ->> 'id'             as section_id,
  s.section ->> 'title'          as section_title,
  q.ord::integer                 as question_order,
  q.question ->> 'key'           as question_key,
  q.question ->> 'label'         as label,
  q.question ->> 'type'          as type,
  q.question -> 'options'        as options,
  q.question ->> 'show_if'       as show_if
from jsonb_array_elements(public.fn_intake_form_current() -> 'sections')
       with ordinality s(section, ord),
     jsonb_array_elements(s.section -> 'questions')
       with ordinality q(question, ord);

comment on view client.v_intake_questions is
  'The current intake question tree, flattened for the Schedule Intake checklist: one row '
  'per L2 question with its L1 section. A projection of public.fn_intake_form_current(), '
  'which stays the only place a question is defined. Order by section_order then '
  'question_order. show_if is a plain "key=value" string the form uses to hide a follow-up '
  'until its parent is answered; it is a display hint and is NOT enforced anywhere.';

grant select on client.v_intake_questions to authenticated;

-- ------------------------------------------------------------------- VERIFY
do $verify$
declare
  v_rows int;
  v_tree int;
  v_sections int;
  v_bad int;
begin
  select count(*) into v_rows from client.v_intake_questions;
  select count(*) into v_tree
    from jsonb_array_elements(public.fn_intake_form_current() -> 'sections') s,
         jsonb_array_elements(s -> 'questions') q;
  if v_rows <> v_tree then
    raise exception 'VERIFY: the view has % rows but the tree has % questions', v_rows, v_tree;
  end if;
  if v_rows <> 35 then
    raise exception 'VERIFY: expected 35 questions, got %', v_rows;
  end if;

  select count(distinct section_id) into v_sections from client.v_intake_questions;
  if v_sections <> 6 then raise exception 'VERIFY: expected 6 sections, got %', v_sections; end if;

  select count(*) into v_bad from client.v_intake_questions
   where question_key is null or label is null or type is null or section_id is null;
  if v_bad <> 0 then raise exception 'VERIFY: % rows are missing a key, label, type or section', v_bad; end if;

  -- ordering is stable and starts at 1 in every section
  select count(*) into v_bad from (
    select section_id, min(question_order) mn from client.v_intake_questions group by section_id) z
   where mn <> 1;
  if v_bad <> 0 then raise exception 'VERIFY: % sections do not start their questions at 1', v_bad; end if;

  -- the anon portal must not be able to read the form
  if has_table_privilege('anon','client.v_intake_questions','SELECT') then
    raise exception 'VERIFY: anon can read the intake questions';
  end if;
  if not has_table_privilege('authenticated','client.v_intake_questions','SELECT') then
    raise exception 'VERIFY: authenticated cannot read the intake questions';
  end if;

  raise notice 'VERIFY: % questions across % sections', v_rows, v_sections;
end $verify$;

notify pgrst, 'reload schema';
