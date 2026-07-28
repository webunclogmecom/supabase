-- ============================================================================
-- 2026-07-28e — default gdos.nickname = 'Main' for single-permit clients
-- ============================================================================
-- Fred: "is that nickname working for all the clients? because in the case of
-- just having one, the nickname should be `main`, as a default, later on the
-- client's app we can change it."
--
-- ANALYSIS FIRST (per the standing DB-change workflow):
--   * 220 gdos total: 135 ACTIVE + well-formed, 84 inactive, 37 placeholders.
--   * Clients by ACTIVE real permits: 125 hold exactly ONE, 2 hold two, 2 hold three.
--   * Of the 125 single-permit rows: 103 have NO location_label, and **22 DO**
--     (e.g. 'Pura Vida Brickell', 'ANGELOS PIZZARAUNTE', 'ALADDIN MARKET & FOOD, INC.').
--
-- THE TRAP, and the call: display is COALESCE(nickname, location_label, gdo_number),
-- so writing nickname='Main' onto those 22 HIDES their existing label. Applying
-- Fred's rule literally anyway, because (a) it is what he asked for, (b) nothing is
-- lost — location_label stays in the row and is still exposed by client.gdos, so the
-- app can show both, and (c) nicknames become editable in the Client App, so this is
-- a starting value, not a decision. Reversal is one UPDATE.
--
-- DELIBERATELY NOT TOUCHED:
--   * multi-permit clients still unlabelled (043-MIL x2, 148-MOR x2, 242-WYN x3):
--     'Main' is ambiguous when there are several traps — which one is main? Left NULL
--     for ops to name, exactly like Casa Neos was named Kitchen/Bar/Lounge.
--   * 009-CN Casa Neos: already Kitchen/Bar/Lounge (guarded by nickname IS NULL).
--   * INACTIVE permits and the 37 placeholders: not real permits, left NULL.
--
-- NO COLUMN DEFAULT: a DEFAULT cannot know how many permits the client holds, so a
-- new permit arrives with nickname NULL and display falls back to
-- location_label -> gdo_number until someone names it.
--
-- 'Main' is title-case to match the existing Kitchen / Bar / Lounge seeds.
-- AUDIT (ADR 010): public.gdos is audited; these UPDATEs are captured automatically.
-- Rollback: update public.gdos set nickname = null where nickname = 'Main';
-- ============================================================================

begin;

update public.gdos g
   set nickname = 'Main'
 where g.nickname is null
   and g.status = 'ACTIVE'
   and g.gdo_number ~ '^GDO-[0-9]+$'
   and (select count(*) from public.gdos g2
         where g2.client_id = g.client_id
           and g2.status = 'ACTIVE'
           and g2.gdo_number ~ '^GDO-[0-9]+$') = 1;

commit;
