-- ============================================================================
-- 2026-07-29d — fill public.photo_classifications.classified_by_user_id
--               (NULL on all 403 rows) via a trigger, + backfill what the audit
--               trail can honestly recover
-- ============================================================================
-- Requested by the Building Apps session 2026-07-29, who found the column NULL
-- on every row. The app's known-issues doc blamed "no authenticated user", which
-- is stale — Admin Review is behind the Command Deck login now, auth.uid() is
-- available, and nothing was setting the column.
--
-- ── ⚠ WHY NOT `DEFAULT auth.uid()`, THE OBVIOUS FIX ────────────────────────
-- A column DEFAULT fires ONLY on INSERT. The Admin Review hook upserts with
-- ON CONFLICT DO UPDATE, so every RE-classification takes the UPDATE branch and
-- the default never fires. You would see it working on freshly classified photos
-- and conclude it was done, while every correction silently kept a stale or NULL
-- attributor. Partial coverage that looks like success — the exact failure shape
-- this workspace has been cataloguing all week. Hence a BEFORE INSERT OR UPDATE
-- trigger, which cannot be bypassed by the upsert branch and needs no app change
-- (so a future hook rewrite cannot forget it).
--
-- ── SEMANTICS (decided by BA, 2026-07-29) ──────────────────────────────────
-- The column means "WHO IS RESPONSIBLE FOR THE CURRENT VALUE", not "who touched
-- it first". Re-classification therefore OVERWRITES. Two reasons: audit.logs
-- already retains the full chain so nothing is lost, and the question anyone
-- actually asks of this column is "who decided this photo is a before shot",
-- which is the current classifier and not whoever was overruled.
-- ⚠ If first-classifier is ever wanted too, that is a SECOND COLUMN, not a
-- different trigger. Do not repurpose this one.
--
-- ── THE NULL-uid GUARD (explicitly requested) ──────────────────────────────
-- A service_role, cron or plain-SQL write has auth.uid() = NULL. Such a write
-- must NEVER blank an existing attributor. Same monotonic shape as the
-- derm_required rule: only ever fill or replace with a real actor, never demote
-- a known value to NULL. This is also what lets the backfill below run safely
-- through the trigger rather than around it.
--
-- ── BACKFILL SCOPE — 132 rows, and 271 deliberately left NULL ──────────────
-- audit.logs carries the actor in jwt_claims->>'sub' for authenticated writes.
-- Measured:
--     photo_classifications rows           403   (all NULL)
--     distinct photos with an actor        142
--     of those, still having a live row    132  <- backfilled here
--     distinct photos with NO actor        203   (role=anon 195, no-jwt 38)
-- ⚠ The 271 rows left NULL are NOT a failed backfill. They were written before
-- the app carried a session, so no actor exists to recover. NULL is the honest
-- answer; inventing one would poison the only column whose entire purpose is
-- attribution. Confirmed with BA: leave them.
-- ⚠ Note the join key: audit.logs.record_pk is JSONB shaped {"photo_link_id": N}
-- — it is NOT the table's `id`. Joining on id silently matches nothing.
-- Both recovered actors resolve against auth.users (2 of 2 matched).
--
-- Side effect, accepted: the backfill fires the existing
-- `photo_classifications_set_updated_at` trigger, so those 132 rows get a fresh
-- updated_at. Rule 7 says updated_at is trigger-managed and never set by hand, so
-- this is left to happen rather than suppressed. The audit trail records the
-- change, as it should.
--
-- ROLLBACK:
--   DROP TRIGGER IF EXISTS photo_classifications_set_classified_by ON public.photo_classifications;
--   DROP FUNCTION IF EXISTS public.fn_set_classified_by();
--   -- data rollback (only if truly wanted; the values are correct):
--   -- UPDATE public.photo_classifications SET classified_by_user_id = NULL;
--
-- AUDIT (ADR 010): public.photo_classifications is already audited
-- (audit_photo_classifications AFTER trigger). The backfill's 132 UPDATEs are
-- captured there with app_source='sql'.
-- ============================================================================

begin;

create or replace function public.fn_set_classified_by()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is not null then
    -- a real signed-in human owns the CURRENT value, on INSERT and UPDATE alike
    new.classified_by_user_id := v_uid;
  elsif tg_op = 'UPDATE' then
    -- service_role / cron / SQL: auth.uid() is NULL. Never blank an existing
    -- attributor, but DO allow an explicit value through (that is the backfill).
    new.classified_by_user_id := coalesce(new.classified_by_user_id,
                                          old.classified_by_user_id);
  end if;
  return new;
end;
$$;

-- BEFORE, so the value is present in the row the AFTER audit trigger records.
drop trigger if exists photo_classifications_set_classified_by on public.photo_classifications;
create trigger photo_classifications_set_classified_by
  before insert or update on public.photo_classifications
  for each row execute function public.fn_set_classified_by();

-- ── backfill: latest authenticated actor per photo, only where still NULL ────
with latest as (
  select (record_pk->>'photo_link_id')::bigint as plid,
         (jwt_claims->>'sub')::uuid            as uid,
         row_number() over (
           partition by (record_pk->>'photo_link_id')::bigint
           order by changed_at desc, id desc)  as rn
    from audit.logs
   where table_name = 'photo_classifications'
     and jwt_claims->>'sub' is not null
     and operation in ('INSERT', 'UPDATE')
)
update public.photo_classifications p
   set classified_by_user_id = l.uid
  from latest l
 where l.rn = 1
   and p.photo_link_id = l.plid
   and p.classified_by_user_id is null;

commit;
