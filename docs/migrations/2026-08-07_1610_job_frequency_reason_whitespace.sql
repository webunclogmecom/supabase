-- ============================================================================
-- 2026-08-07_1610: a cadence reason must contain a NON-WHITESPACE character
-- ============================================================================
-- Found by the adversarial half of the same smoke test that found the grant hole.
-- The original constraint, copied from the sibling table, was:
--     CHECK (btrim(reason) <> '')
-- and its comment claimed it closes the "blank reason" case. It closes TWO of them.
--
-- 🛑 `btrim(text)` WITH ONE ARGUMENT STRIPS U+0020 AND NOTHING ELSE. Measured live,
-- inside rolled-back transactions, 10 of 12 whitespace inputs were ACCEPTED:
--     REFUSED : ''  and '   '            <- the only two the first test exercised
--     ACCEPTED: TAB, LF, CRLF, VT, FF, NBSP, ZWSP, ideographic space,
--               a mixed TAB+LF+space+CR string, and '  '||TAB||'  '
-- The UPDATE path behaved the same way, so a reason could also be blanked after
-- the fact. `btrim(reason, E' \t\n\r\v\f')` would still miss NBSP and ZWSP, so the
-- fix is a class match rather than a longer strip list.
--
-- ⚠ AND THE FIRST FIX FOR THAT WAS ALSO WRONG, CAUGHT BY ITS OWN DRY RUN.
-- `CHECK (reason ~ '[^[:space:]]')` looks like the obvious answer and still ACCEPTS a
-- zero-width space: U+200B is a Unicode FORMAT character (Cf), not whitespace, so it
-- is not in `[:space:]` and satisfies "contains a non-space character". The dry run
-- reported `zwsp WAS ACCEPTED` and nothing else, which is exactly what a must-fail
-- case exists for. Chasing the remaining invisible codepoints (U+FEFF, U+2060,
-- U+180E) is an endless list, so the constraint asks for what a reason actually needs:
--     CHECK (reason ~ '[[:alnum:]]')   -- at least one letter or digit
-- ⚠ That is only safe because `[[:alnum:]]` is NOT Latin-only here. Asserted below
-- with a Spanish control ("El cliente pidió más tiempo"), because a constraint that
-- silently refused accented text would be a worse bug than the one being fixed.
--
-- ⚠ THE FIRST TEST WAS NOT WRONG, ITS SENTENCE WAS. It measured '' and '   ',
-- both correctly refused, and then wrote "refuses empty and whitespace". One
-- character of the whitespace class was exercised and the whole class was claimed.
-- This is the repo's recurring shape: the number is right, the claim around it is
-- not. See CLAUDE.md, "STRUCTURE TELLS YOU WHAT A THING DOES".
--
-- SEVERITY, stated honestly: LOW, and this is defence in depth rather than a live
-- hole. `save-client-job` computes `String(p.frequency_reason ?? "").trim()` and
-- refuses under 3 characters, and JS `.trim()` strips the ENTIRE Unicode whitespace
-- class. Verified against all 10 accepted inputs above: every one trims to length 0
-- (ZWSP to 1) and is refused with `reason_required` before reaching the database.
-- So the app cannot produce one of these rows. A direct service_role write can.
--
-- 🛑 THE SAME GAP EXISTS ON public.client_status_changes_reason_not_blank, which is
-- where this constraint was copied from. It is DELIBERATELY NOT CHANGED HERE: that
-- table belongs to the client status flow, it holds live business rows, and widening
-- a constraint on it is its own change with its own testing. Recorded so the next
-- person does not read this file as having fixed both.
--
-- AUDIT-TRAIL STANDING CHECK (rule 8): no table added or renamed, no trigger
-- touched. The audit trigger installed by 2026-08-07_1235 is unaffected.
-- ============================================================================

alter table public.job_frequency_changes
  drop constraint if exists job_frequency_changes_reason_not_blank;

alter table public.job_frequency_changes
  add constraint job_frequency_changes_reason_not_blank
  check (reason ~ '[[:alnum:]]');

comment on constraint job_frequency_changes_reason_not_blank on public.job_frequency_changes is
  'The reason must contain at least one letter or digit. Not btrim (which strips U+0020 only) and not [^[:space:]] (which accepts a zero-width space, since U+200B is a format character rather than whitespace). Requiring something readable is one rule instead of an endless list of invisible codepoints.';

-- ---------------------------------------------------------------------------
-- Prove it, in the same transaction, with a control that MUST pass.
-- ---------------------------------------------------------------------------
do $$
declare
  v_job    bigint;
  v_client bigint;
  v_ok     int := 0;
  v_before int;
  v_bad    text[] := array[]::text[];
  v_in     text;
  v_label  text;
  v_pairs  text[][] := array[
    array['tab',        E'\t'],
    array['lf',         E'\n'],
    array['crlf',       E'\r\n'],
    array['vt',         E'\x0B'],
    array['ff',         E'\x0C'],
    array['nbsp',       E' '],
    array['zwsp',       E'​'],
    array['ideographic',E'　'],
    array['mixed',      E'\t\n \r'],
    array['space+tab',  E'  \t  '],
    array['empty',      ''],
    array['spaces',     '   ']
  ];
begin
  select count(*) into v_before from public.job_frequency_changes;
  select j.id, j.client_id into v_job, v_client
    from public.jobs j where j.frequency_days > 0 order by j.id limit 1;

  for i in 1 .. array_length(v_pairs, 1) loop
    v_label := v_pairs[i][1];
    v_in    := v_pairs[i][2];
    begin
      insert into public.job_frequency_changes
        (job_id, client_id, old_frequency_days, new_frequency_days, reason)
      values (v_job, v_client, 30, 60, v_in);
      v_bad := v_bad || (v_label || ' WAS ACCEPTED');
    exception when check_violation then
      v_ok := v_ok + 1;
    end;
  end loop;

  -- POSITIVE CONTROL: a real reason must still insert, or the constraint is simply
  -- refusing everything and the 12 refusals above mean nothing.
  begin
    insert into public.job_frequency_changes
      (job_id, client_id, old_frequency_days, new_frequency_days, reason)
    values (v_job, v_client, 30, 60, 'client asked for a longer cycle');
  exception when others then
    v_bad := v_bad || ('CONTROL FAILED: a real reason was refused (' || sqlstate || ')');
  end;

  -- SECOND CONTROL: a reason with leading/trailing whitespace around real text must
  -- pass, since the constraint tests for presence, not for tidiness.
  begin
    insert into public.job_frequency_changes
      (job_id, client_id, old_frequency_days, new_frequency_days, reason)
    values (v_job, v_client, 30, 90, E'\t client asked \n');
  exception when others then
    v_bad := v_bad || ('CONTROL 2 FAILED: padded real text refused (' || sqlstate || ')');
  end;

  -- THIRD CONTROL: [[:alnum:]] must not be Latin-only. Diego and Yan write in Spanish
  -- and French, and a constraint that silently refuses "más" would be a worse bug than
  -- the one being fixed.
  begin
    insert into public.job_frequency_changes
      (job_id, client_id, old_frequency_days, new_frequency_days, reason)
    values (v_job, v_client, 30, 120, 'El cliente pidió más tiempo entre visitas');
  exception when others then
    v_bad := v_bad || ('CONTROL 3 FAILED: accented text refused (' || sqlstate || ')');
  end;

  if array_length(v_bad, 1) is not null then
    raise exception 'whitespace constraint check FAILED: %', v_bad;
  end if;

  -- 🛑 The three control rows above are REAL INSERTS and must not survive. This DO block
  -- runs inside the migration, so a RAISE here would roll back the ALTER TABLE with it.
  -- Delete them explicitly instead, and assert the table is back to its prior count.
  delete from public.job_frequency_changes
   where reason in ('client asked for a longer cycle',
                    E'\t client asked \n',
                    'El cliente pidió más tiempo entre visitas');
  if (select count(*) from public.job_frequency_changes) <> v_before then
    raise exception 'control rows were not fully removed: % rows now, % before',
      (select count(*) from public.job_frequency_changes), v_before;
  end if;

  raise notice 'reason constraint: refused % of 12 whitespace inputs, 3 controls passed, control rows removed', v_ok;
end
$$;
