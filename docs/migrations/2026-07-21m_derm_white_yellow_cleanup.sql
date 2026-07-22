-- ============================================================================
-- 2026-07-21m — Clean the white==yellow dirt on derm_manifests + guard its source
-- ============================================================================
-- FINDING (Building Apps session, routed by Fred 2026-07-21): derm_manifests
-- splits ONE value (the dump-ticket number) across two columns by county —
-- white_manifest_number (Miami-Dade) / yellow_ticket_number (Broward). This is a
-- "category-in-column-choice" anti-pattern (mirrors Airtable's two fields). The
-- data proves the split carries no information: of 555 live manifests, 0 ever
-- hold two DIFFERENT numbers, and 78 hold the SAME number copied into BOTH
-- columns — pure dirt. All 78 are Broward tickets (2xxxxx/3xxxxx yellow series,
-- 8 distinct dump tickets) where the yellow number was wrongly written into
-- white. Verified none of those 8 numbers exists as a legitimate Miami-Dade
-- white-only row (all occurrences are dirt), so nulling white is safe.
--
-- ROOT CAUSE of the *persistence* — a LIVE trigger:
--   trg_ab_adopt_sibling_white (fn_adopt_sibling_white_number, added 2026-07-07)
--   fires BEFORE INSERT/UPDATE OF white/yellow: for a row with white NULL +
--   yellow set, it adopts a same-yellow sibling's white#. Its 07-07 origin case
--   (#298064) was ITSELF a dirty Broward ticket, so the trigger only ever
--   PROPAGATES the yellow-in-white dirt across co-loaded clients — and fights
--   manual fixes (the sql-306859-broward-fix on 07-17 did not stick). It has no
--   legitimate path: the 80 genuine Miami-Dade shared-white tickets are
--   white-only (yellow NULL) and never match its yellow-keyed lookup.
--
-- FIX (two parts, applied guard-first so the cleanup can't be re-dirtied):
--   1. GUARD the trigger fn: never adopt a sibling white# that EQUALS the yellow
--      ticket number (that value is the dirt itself). With the 78 rows cleaned
--      this makes the trigger inert for Broward — correct, since a Broward
--      yellow ticket has no legitimate white to adopt. (Reversible; the trigger
--      shell stays. It can be dropped entirely at the eventual white/yellow ->
--      ticket_number + jurisdiction collapse, deferred to the Airtable sunset.)
--   2. NULL white_manifest_number on the 78 white==yellow rows. The ticket key
--      apps read is COALESCE(white_manifest_number, yellow_ticket_number), which
--      is UNCHANGED by this (was white==yellow, now COALESCE(NULL,yellow)=yellow)
--      — so Stamp cards / manifest links / display_number are all unaffected.
--
-- BACKUP: backups/2026-07-21_derm_white_yellow_dirty_78rows.json (full pre-image;
-- restore = write these white values back if ever needed).
--
-- NOT in scope (deliberate): collapsing white+yellow into ticket_number +
-- jurisdiction. Real blast radius (19 objects read derm_manifests + FP customer
-- views + file_manifest* / edit_manifest RPCs + the partial unique indexes +
-- Airtable sync). Best done at the AT sunset when the AT-shaped constraint dies.
-- ============================================================================

begin;

-- 1) Guard: never propagate a white# that is really the yellow ticket number.
create or replace function derm.fn_adopt_sibling_white_number()
returns trigger language plpgsql as $$
declare v_w text;
begin
  if new.white_manifest_number is null and new.yellow_ticket_number is not null then
    select s.white_manifest_number into v_w
      from public.derm_manifests s
     where s.yellow_ticket_number = new.yellow_ticket_number
       and s.white_manifest_number is not null
       and s.white_manifest_number is distinct from s.yellow_ticket_number  -- 21m: never adopt the yellow-in-white dirt
       and s.deleted_at is null
       and s.id is distinct from new.id
     order by s.id limit 1;
    if v_w is not null then new.white_manifest_number := v_w; end if;
  end if;
  return new;
end $$;

-- 2) Clean the 78 rows (Broward yellow number wrongly copied into white).
--    trg_ae_ticket_key_unambiguous (fn_derm_ticket_key_unambiguous) fires BEFORE
--    ROW and would RAISE mid-update: while some siblings of a ticket are already
--    yellow-key and others still white-key, it reads a transient white/yellow
--    "collision" for the SAME physical Broward ticket (a false alarm here — it is
--    one ticket, not two). Disable ONLY that check for the bulk update; the END
--    state is consistent (each of the 8 numbers exists solely as yellow-key, zero
--    white occurrences — verified: none of them is a legitimate Miami-Dade
--    white-only number), so its invariant holds and it is safe to re-arm. Audit
--    + all other triggers stay live, so the cleanup is fully audited.
alter table public.derm_manifests disable trigger trg_ae_ticket_key_unambiguous;

update public.derm_manifests
   set white_manifest_number = null
 where deleted_at is null
   and white_manifest_number is not null
   and white_manifest_number = yellow_ticket_number;

alter table public.derm_manifests enable trigger trg_ae_ticket_key_unambiguous;

commit;
