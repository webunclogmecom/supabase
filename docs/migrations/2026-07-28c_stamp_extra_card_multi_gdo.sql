-- ============================================================================
-- 2026-07-28c — Stamp Studio: allow a client to be stamped MORE THAN ONCE
--               on the same sheet (multi-GDO / multi-grease-trap locations)
-- ============================================================================
-- Yan, 2026-07-28: "when you have a location like this that has multiple GT and
-- you need to put multiple GDO permit, it doesnt let you put it 3 times."
--
-- REPRODUCED + ROOT-CAUSED. Sheet 820714 (ticket for 2026-07-22) has THREE
-- Section B rows for 009-CN Casa Neos — GDO-10877 KITCHENS, GDO-15062 BARS,
-- GDO-16389 LOUNGE (all three are real, ACTIVE, separate permits on separate
-- traps). Stamp Studio offers exactly ONE card for that client, so rows 2 and 3
-- can never be stamped.
--
-- The blocker is NOT the schema — derm.address_row_map's natural key is
-- (dump_folder, page, row_index), so N cards per client are already legal. It is
-- a deliberate one-card-per-client guard in BOTH creation paths:
--   * derm._materialize_card  — "IF EXISTS (... white_manifest_number = v_wm AND
--     matched_client_id = v_cid) THEN ... RETURN" (never creates a 2nd card)
--   * derm.add_client_card_and_link — "reuse the client's existing card on this
--     sheet if present", so the "+ Add client" button silently returns the SAME
--     card instead of adding another.
-- That guard is CORRECT for the automatic path (a manifest link must not spam
-- duplicate cards). It is wrong only for the deliberate human action.
--
-- FIX: a NEW, separate function for the explicit "stamp this client again"
-- action. Both existing functions are left completely untouched, so the
-- automatic dedupe still holds and no existing caller changes behaviour —
-- additive-first per the contract-versioning rule, rather than adding a
-- parameter to a function the live app already calls.
--
-- The extra card inherits the client's existing manifest on that sheet
-- (matched_manifest_id) rather than filing a new one: one client + one ticket is
-- still ONE manifest (rule #10, one manifest = one client); what multiplies is
-- the number of STAMP POSITIONS on the page, not the number of manifests. So no
-- manifest churn, no new visit links, no interaction with the link guards.
--
-- Blast radius today: only 4 clients hold more than one ACTIVE, well-formed
-- (^GDO-\d+$) permit, so this affects a small set of co-loaded sheets.
--
-- ⚠ FOLLOW-UP FOR THE FP BLACKOUT (flagged, not changed here): a client with 3
-- cards now has 3 bands. derm.fn_blackout_targets must reveal ALL of that
-- client's bands on their redacted sheet, not just one, or rows 2-3 would be
-- blacked out on the client's own copy. Verify before the next blackout run on a
-- multi-stamped sheet.
--
-- AUDIT (ADR 010): derm.address_row_map is Stamp-Studio working state, already
-- outside the audited business set; this adds no new business table.
-- ============================================================================

begin;

create or replace function derm.add_extra_client_card(
  p_dump_folder text,
  p_client_id   bigint,
  p_page        int default 1
)
returns bigint
language plpgsql
security definer
set search_path to 'derm', 'public'
as $$
declare
  v_wm       text;
  v_existing derm.address_row_map%rowtype;
  v_next     int;
  v_new_id   bigint;
begin
  perform derm._require_stamp_key();
  if p_client_id is null then raise exception 'p_client_id required'; end if;

  select max(white_manifest_number) into v_wm
    from derm.address_row_map where dump_folder = p_dump_folder;
  if v_wm is null then raise exception 'unknown sheet %', p_dump_folder; end if;

  -- The client must ALREADY be on this sheet: this action adds an EXTRA stamp
  -- for a client that belongs here, it is not a way to add a new client (that is
  -- add_client_card_and_link, which also files/links the manifest properly).
  select * into v_existing
    from derm.address_row_map
   where dump_folder = p_dump_folder and matched_client_id = p_client_id
   order by id
   limit 1;
  if not found then
    raise exception 'client % is not on sheet % yet — use add_client_card_and_link first',
      p_client_id, p_dump_folder;
  end if;

  select coalesce(max(row_index), 0) + 1 into v_next
    from derm.address_row_map
   where dump_folder = p_dump_folder and page = coalesce(p_page, 1);

  insert into derm.address_row_map
    (dump_folder, white_manifest_number, page, row_index, image_url,
     matched_client_id, matched_manifest_id, assignment_status, confidence,
     source, flags)
  values
    (p_dump_folder, v_wm, coalesce(p_page, 1), v_next, v_existing.image_url,
     p_client_id, v_existing.matched_manifest_id, 'matched', 'high',
     'extra-stamp', '{"extra_stamp":true}'::jsonb)
  returning id into v_new_id;

  return v_new_id;
end $$;

revoke all on function derm.add_extra_client_card(text, bigint, int) from public;
revoke all on function derm.add_extra_client_card(text, bigint, int) from anon;
grant execute on function derm.add_extra_client_card(text, bigint, int) to authenticated;
grant execute on function derm.add_extra_client_card(text, bigint, int) to service_role;

commit;
