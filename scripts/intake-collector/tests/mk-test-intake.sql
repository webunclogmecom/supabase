BEGIN;
INSERT INTO public.property_intakes (property_id, form_snapshot, requested, requested_by)
SELECT 1164, s, to_jsonb(public.fn_intake_normalise_requested(s, (SELECT array_agg(question_key) FROM client.v_intake_questions))), '[TEST] collector page check (@Supabase 2)'
  FROM (SELECT public.fn_intake_form_current() s) x;
COMMIT;
