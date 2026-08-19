-- ============================================================================
-- 2026-08-18_2231 - v_visit_photo_email_status: who actually sent it
-- ============================================================================
-- Fred, 2026-08-18, on the "Emailed to City on Aug 18, 2026" line in Admin Review:
-- "is a case of when someone sends an email to the city, also add who did it on that text".
--
-- The sender was already recorded (visit_photo_email_sends.sent_by_email, captured from
-- the app-forwarded JWT), and the view already exposed it as last_sent_by. Two reasons
-- this still needed a migration rather than an app-only change:
--
--  🛑 1. last_sent_by IS NOT THE SENDER OF THE SEND BEING DISPLAYED. It is the newest row
--     of ANY status, while last_sent_at is the newest row with status='sent'. Those are
--     different rows whenever the most recent attempt FAILED, and 7 failed sends exist
--     today. Rendering the two together would have printed a real date beside the name of
--     whoever last got an error - a person shown as having sent something they did not.
--     last_sent_by_success_email is filtered to status='sent', so it always describes the
--     same row as last_sent_at.
--
--   2. The UI wants a person, not an address. employees.email resolves it (7 staff
--      addresses, no duplicates), and the view is owner-rights, so a signed-in browser
--      gets the NAME without needing a grant on public.employees.
--
-- last_sent_by is deliberately KEPT and unchanged: it is a different question ("who made
-- the last attempt") and something may already read it.
--
-- The pre-existing body below is the live pg_get_viewdef output, copied not retyped
-- (CLAUDE.md: CREATE OR REPLACE takes the WHOLE definition, so anything not reproduced is
-- silently deleted). The first nine output columns keep their names, types and order.
--
-- AUDIT (rule 8): a VIEW; no table created or altered, no trigger touched.
-- ============================================================================

create or replace view public.v_visit_photo_email_status as
with agg as (
  SELECT visit_id,
      count(*) AS send_count,
      count(*) FILTER (WHERE status = 'sent'::text) AS sent_count,
      max(sent_at) FILTER (WHERE status = 'sent'::text) AS last_sent_at,
      max(sent_at) FILTER (WHERE status = 'sent'::text AND is_test = false) AS last_real_sent_at,
      (array_agg(status ORDER BY sent_at DESC))[1] AS last_status,
      (array_agg(reason ORDER BY sent_at DESC))[1] AS last_reason,
      (array_agg(sent_by_email ORDER BY sent_at DESC))[1] AS last_sent_by,
      (array_agg(photo_count ORDER BY sent_at DESC))[1] AS last_photo_count,
      -- NEW: the sender of the last SUCCESSFUL send, i.e. the one last_sent_at describes
      (array_agg(sent_by_email ORDER BY sent_at DESC) FILTER (WHERE status = 'sent'::text))[1]
        AS last_sent_by_success_email
     FROM visit_photo_email_sends s
    GROUP BY visit_id
)
select a.visit_id,
       a.send_count,
       a.sent_count,
       a.last_sent_at,
       a.last_real_sent_at,
       a.last_status,
       a.last_reason,
       a.last_sent_by,
       a.last_photo_count,
       a.last_sent_by_success_email,
       coalesce(e.full_name, a.last_sent_by_success_email) as last_sent_by_name
  from agg a
  left join lateral (
    select emp.full_name
      from public.employees emp
     where a.last_sent_by_success_email is not null
       and lower(btrim(emp.email)) = lower(btrim(a.last_sent_by_success_email))
     order by emp.id
     limit 1
  ) e on true;

comment on view public.v_visit_photo_email_status is
  'Per-visit city-email status. last_sent_by_name pairs with last_sent_at (both status=sent); '
  'last_sent_by is the newest attempt of ANY status and can name a different person.';

-- ============================================================================
-- VERIFY
-- ============================================================================
do $verify$
declare
  fail text := '';
  v_named int; v_rows int; v_mismatch int;
begin
  -- 1. POSITIVE CONTROL: the 8 visits that have been emailed must resolve to a name,
  --    otherwise an all-null column would look like "nobody has sent anything".
  select count(*) into v_named
    from public.v_visit_photo_email_status where last_sent_by_name is not null;
  if v_named = 0 then
    fail := fail || 'no row resolves a sender name - the join is not matching; ';
  end if;

  -- 2. the resolved name must be a real employee name where one exists, not the raw email
  if not exists (select 1 from public.v_visit_photo_email_status
                  where last_sent_by_name = 'Fred' and last_sent_at is not null) then
    fail := fail || 'the known sender fred@ayache.com does not resolve to the employee name; ';
  end if;

  -- 3. the new column must never describe a DIFFERENT row than last_sent_at: whenever a
  --    visit has a successful send, the success email must be populated.
  select count(*) into v_mismatch
    from public.v_visit_photo_email_status
   where last_sent_at is not null and last_sent_by_success_email is null;
  if v_mismatch > 0 then
    fail := fail || format('%s visits have last_sent_at but no success sender; ', v_mismatch);
  end if;

  -- 4. no rows lost or duplicated by the lateral join
  select count(*) into v_rows from public.v_visit_photo_email_status;
  if v_rows <> (select count(distinct visit_id) from public.visit_photo_email_sends) then
    fail := fail || format('row count %s <> distinct visits in the sends table; ', v_rows);
  end if;

  -- 5. the nine pre-existing columns are still there, still named the same
  if (select count(*) from information_schema.columns
       where table_schema='public' and table_name='v_visit_photo_email_status'
         and column_name in ('visit_id','send_count','sent_count','last_sent_at','last_real_sent_at',
                             'last_status','last_reason','last_sent_by','last_photo_count')) <> 9 then
    fail := fail || 'a pre-existing column was dropped or renamed; ';
  end if;

  -- 6. still readable by the app, still not by anon
  if not has_table_privilege('authenticated', 'public.v_visit_photo_email_status', 'SELECT') then
    fail := fail || 'authenticated lost SELECT; ';
  end if;
  if has_table_privilege('anon', 'public.v_visit_photo_email_status', 'SELECT') then
    fail := fail || 'anon can read it; ';
  end if;

  if fail <> '' then raise exception 'VERIFY FAILED: %', fail; end if;
  raise notice 'sender name exposed on % rows', v_named;
end
$verify$;

select visit_id, last_sent_at::date as sent_on, last_sent_by, last_sent_by_name
  from public.v_visit_photo_email_status
 where last_sent_at is not null
 order by last_sent_at desc limit 5;
