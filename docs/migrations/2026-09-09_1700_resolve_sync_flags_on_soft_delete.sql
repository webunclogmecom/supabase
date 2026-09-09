-- =====================================================================================
-- 2026-09-09_1700  Close the one stuck push flag, and stop it recurring
--   public.fn_resolve_sync_flags_on_soft_delete()  +  trg_zz_resolve_flags_on_soft_delete
--   plus the one-row cleanup for visit 7754
-- =====================================================================================
-- WHY ---------------------------------------------------------------------------------
-- Fred asked for the Calendar/Jobber sync backlog to be cleared. Measured, the backlog is ONE ROW,
-- and the interesting part is why nothing could ever clear it.
--
-- Visit 7754 (083-SHUL, 2026-08-16):
--   2026-08-14 16:35 ET  push failed -- Jobber answered `visitEditSchedule: "Visit not found"`,
--                        so visit_sync_flags took a `push_exception` row
--   ... 4 attempts, the 1/5/15/60-minute ladder ran out, auto_retry_state = 'exhausted'
--   2026-08-15 05:42 ET  the visit was SOFT-DELETED (the Jobber visit really was gone)
--   ... and the flag has sat unresolved for 622 hours
--
-- 🛑 IT IS UNREACHABLE BY EVERY MECHANISM THAT WOULD OTHERWISE CLEAR IT, and each one filters it
--    out for its own perfectly good reason:
--      * `fn_calendar_push_auto_retry` filters `deleted_at IS NULL`  -- correct: never re-push a
--        deleted visit into Jobber
--      * cron 9 `resolve-stale-visit-sync-pending` filters `deleted_at IS NULL`  -- same reason
--      * `jobber-push-visit`'s `clearFlag()` only runs when a push SETTLES, and no push will ever
--        run again for this visit
--      * `ops.v_calendar_push_health` filters `v.deleted_at IS NULL`, so it is not even VISIBLE
--    So the row is invisible, harmless to the operator, and permanently poisons any count of
--    "unresolved sync flags" -- which is exactly the sort of metric a health check leans on.
--
-- THE FIX IS THE TRIGGER, NOT THE UPDATE ----------------------------------------------
-- Resolving 7754 by hand is a one-line UPDATE and it fixes nothing: the next visit soft-deleted
-- while carrying an open flag lands in the identical state. Soft-deleting a visit is precisely the
-- moment at which an outstanding push flag becomes moot, so that is where it should be resolved.
--
-- ⚠ SCOPE. It resolves ONLY on the NULL -> NOT NULL transition of `deleted_at`, via a WHEN clause,
--   so it does not fire on the ~thousands of ordinary visit UPDATEs this table takes. It never
--   touches a flag on a live visit, and it never un-resolves anything.
--
-- ⚠ TRIGGER ORDER IS NOT LOAD-BEARING HERE, and that is worth stating rather than leaving implicit
--   (this estate has already been bitten by an ordering assumption: `trg_aa_derm_required_shadow`
--   must sort before `trg_derm_required_lock` or it logs zero for ever). This trigger reads only
--   OLD/NEW `deleted_at` and writes only `public.visit_sync_flags`, which no other trigger on
--   `public.visits` reads or writes. It is named `trg_zz_...` so it runs after the existing
--   `trg_zz_freeze_line_items_on_complete` and before `zzz_broadcast_inval`, but nothing depends on
--   that.
--
-- ⚠ resolved_at IS the audit trail for this table, and the reason is recorded in `detail` so a
--   later reader can tell an auto-resolution from a genuine push success. `visit_sync_flags` is not
--   in the rule-8 audited set, which is why the reason has to be in the row itself.
--
-- WHAT THIS DELIBERATELY DOES NOT DO ---------------------------------------------------
-- * It does NOT delete the 48 `entity_source_links` rows that point at Jobber visits behind
--   soft-deleted visits. Measured: 48, all on soft-deleted visits, 0 pointing at a visit row that
--   does not exist. They are inert, `entity_source_links` carries ZERO audit triggers (so a delete
--   leaves no record of any kind), and rule 6 forbids hard-deleting business data without a
--   sanctioned reason. Leave them.
-- * It does NOT touch the 24 `sync_state='pending'` rows on soft-deleted visits. Same reasoning,
--   and cron 9 correctly refuses them. Measured: 0 LIVE visits are pending over an hour old, and
--   0 LIVE visits are `failed`, so there is no live residue at all.
-- * It does NOT chase the 437 scheduled visits with no Jobber link. Measured, ALL 437 are beyond
--   the 60-day Jobber horizon (earliest 2026-11-09, all `supabase_cron`), which is the expected
--   state and not a gap. Within the horizon: 0 unlinked.
--
-- AUDIT (rule 8): no new table. `public.visit_sync_flags` keeps whatever it has.
-- REVERSIBLE: yes. Drop the trigger and the function; the resolved flag can be re-opened by setting
--   resolved_at back to NULL (its `detail` records that this migration closed it).
-- =====================================================================================

begin;

create or replace function public.fn_resolve_sync_flags_on_soft_delete()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
BEGIN
  -- A soft-deleted visit will never be pushed again, so an outstanding push flag is moot. Every
  -- other resolver filters `deleted_at IS NULL` (correctly), which is what left visit 7754's flag
  -- unresolved for 622 hours. Record WHY, because visit_sync_flags is not audited.
  UPDATE public.visit_sync_flags
     SET resolved_at = now(),
         detail = left(coalesce(detail, '') ||
                       ' | auto-resolved: visit soft-deleted ' ||
                       to_char(NEW.deleted_at AT TIME ZONE 'America/New_York', 'YYYY-MM-DD HH24:MI') ||
                       ' ET, no further push possible (2026-09-09_1700)', 2000)
   WHERE visit_id = NEW.id
     AND resolved_at IS NULL;
  RETURN NEW;
END;
$function$;

comment on function public.fn_resolve_sync_flags_on_soft_delete() is
  'Resolves open visit_sync_flags when a visit is soft-deleted. Every other resolver filters deleted_at IS NULL, so without this an exhausted flag is unreachable for ever. See migration 2026-09-09_1700.';

drop trigger if exists trg_zz_resolve_flags_on_soft_delete on public.visits;
create trigger trg_zz_resolve_flags_on_soft_delete
  after update on public.visits
  for each row
  when (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
  execute function public.fn_resolve_sync_flags_on_soft_delete();

-- ------------------------------------------------------------------------------------
-- The one existing row. Pinned by id AND by re-asserting every predicate that makes it
-- resolvable, so it cannot fire if the world changed between the measurement and this write.
-- ------------------------------------------------------------------------------------
update public.visit_sync_flags f
   set resolved_at = now(),
       detail = left(coalesce(f.detail, '') ||
                     ' | auto-resolved: visit soft-deleted 2026-08-15 05:42 ET, retry ladder '
                     'exhausted, no further push possible (2026-09-09_1700)', 2000)
  from public.visits v
 where f.visit_id = 7754
   and v.id = f.visit_id
   and f.resolved_at is null
   and v.deleted_at is not null;

commit;
