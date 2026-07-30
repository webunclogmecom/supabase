-- 2026-07-30_1935  Generated-sheet auto-stamp: connect the dropped wire (D1+D2+D3)
--
-- Fred (2026-07-31): "do an audit, brainstorm, plan it, execute it, and test it." Implements
-- docs/specs/2026-07-31-generated-sheet-autostamp-completion.md, endorsed by the lane's author
-- (@Supabase, 0e70654) and with the Studio badge contract corrected by @Building Apps.
--
-- THE ONE-LINE STORY: the 2026-07-28 lane built GENERATE -> FILE -> RESOLVE -> STAMP and never
-- wired stage 3; the stamp trigger refuses-not-guesses, so every generated sheet sat at 0/N
-- silently. Meanwhile 28q recreated v_stamp_rows the same minute 28n shipped corrected geometry,
-- so the AI button path kept numbers 28n measured ~3% high (row-above risk = FP-blackout PII path).
--
-- D1  v_stamp_rows: generated branch now delegates to fn_generated_row_geometry (single source of
--     truth, x 8.00 / y 29.80-60.04) and DROPS the row_index fallback the view still carried
--     (28n: row_index is card-creation order, provably unrelated to printed order). Slot unknown
--     -> guess NULL -> auto_place_page counts it skipped. Script-edited from the LIVE definition
--     with anchors asserted (both matched exactly once; zero old values remain).
-- D3  fn_resolve_generated_sheet_for_ticket: after linking (or when already linked), places the
--     ticket's EXISTING unplaced cards - the BEFORE-INSERT autoplace trigger can never reach
--     cards created before resolution, which is all 9 current ones. Same refusal rules; and it
--     upserts stamp_sheet_status completion ONLY when the folder is fully placed, because
--     trg_zy_generated_sheet_complete is AFTER INSERT only (completion done here, deliberately
--     NOT by widening that trigger, so later human edits can't re-complete a sheet by side effect).
-- D2  AFTER INSERT OR UPDATE OF (numbers, deleted_at) trigger on public.derm_manifests calls the
--     resolver, exception-wrapped: filing is business-critical and must not abort on a resolver
--     failure; the failure mode stays "visibly 0/N in the Studio".
--
-- ⚠ N-1 REFUSALS ARE BY DESIGN (author's note): on an N-client shared ticket the resolver
-- correctly no-ops until the LAST manifest completes the exact client set. Do not "fix" the
-- exact-set guard - it is what prevents cross-client stamping.
--
-- BADGE CONTRACT (measured): Studio binds to v_stamp_sheets placed_rows/ai_placed_rows/
-- filled_by_ai; ai_placed_rows counts stamp_placed_by='stamp-studio-ai'; filled_by_ai strict
-- non-NULL. D3's attribution string feeds it transitively; no Studio change.
--
-- PROBED before applying (single rolled-back txn, this exact body + both real tickets):
--   sheet 1072 -> 7 links slots 1..7; 1071 -> 2 links; cards 7/7 + 2/2 placed with y exactly
--   {29.80,37.72,44.48,51.81,60.04}; v_stamp_sheets 7/7/true + 2/2/true, completed both;
--   derm_address_no mirrored {1071,1072}; view guesses corrected; same-value manifest UPDATE
--   fired the trigger without error; unknown ticket refused. Zero residue after ROLLBACK.
--
-- RULE 8 (ADR 010): no table/column change. derm.* lane unaudited by design (28o) EXCEPT
-- address_row_map + stamp_sheet_status which carry audit triggers - D3's updates are captured.
-- Sheet 1073 (5 clients, unfiled) is deliberately untouched: it is the live end-to-end test of
-- D2 when its manifests are filed through the real DERM Tracker.

BEGIN;
-- ---- D1: view geometry repair (must precede D2/D3 going live) ---------------
CREATE OR REPLACE VIEW derm.v_stamp_rows AS
 SELECT sr.id,
    sr.dump_folder,
    sr.white_manifest_number,
    sr.page,
    sr.row_index,
    sr.image_url,
    sr.facility_name_read,
    sr.address_read,
    sr.client_code,
    sr.client_name,
    sr.service_date,
    sr.assignment_status,
    sr.confidence,
    sr.stamp_x_pct,
    sr.stamp_y_pct,
    sr.stamp_page,
    sr.guess_x_pct,
    sr.guess_y_pct,
    sr.placed,
    sr.is_manual,
    sr.matched_client_id,
    sr.matched_manifest_id,
    sr.band_y0_pct,
    sr.band_y1_pct,
    sr.band_source,
    sr.reviewed,
    sr.visit_linked,
    sr.linked_visit_count,
    sr.guess_confidence,
    sr.is_generated,
    sr.gdo_number,
    sr.gdo_label,
    a.stamp_placed_by,
    (a.stamp_placed_by = 'stamp-studio-ai'::text) AS filled_by_ai
   FROM (( SELECT sr_1.id,
            sr_1.dump_folder,
            sr_1.white_manifest_number,
            sr_1.page,
            sr_1.row_index,
            sr_1.image_url,
            sr_1.facility_name_read,
            sr_1.address_read,
            sr_1.client_code,
            sr_1.client_name,
            sr_1.service_date,
            sr_1.assignment_status,
            sr_1.confidence,
            sr_1.stamp_x_pct,
            sr_1.stamp_y_pct,
            sr_1.stamp_page,
            sr_1.guess_x_pct,
            sr_1.guess_y_pct,
            sr_1.placed,
            sr_1.is_manual,
            sr_1.matched_client_id,
            sr_1.matched_manifest_id,
            sr_1.band_y0_pct,
            sr_1.band_y1_pct,
            sr_1.band_source,
            sr_1.reviewed,
            sr_1.visit_linked,
            sr_1.linked_visit_count,
            sr_1.guess_confidence,
            sr_1.is_generated,
            gg.gdo_number,
            COALESCE(gg.nickname, gg.location_label, gg.gdo_number) AS gdo_label
           FROM (( SELECT r.id,
                    r.dump_folder,
                    r.white_manifest_number,
                    r.page,
                    r.row_index,
                    r.image_url,
                    r.facility_name_read,
                    r.address_read,
                    COALESCE(c.client_code, r.manual_code) AS client_code,
                    COALESCE(c.name, r.manual_code) AS client_name,
                    ( SELECT min(m.service_date) AS min
                           FROM derm_manifests m
                          WHERE ((COALESCE(m.white_manifest_number, m.yellow_ticket_number) = r.white_manifest_number) AND (m.deleted_at IS NULL))) AS service_date,
                    r.assignment_status,
                    r.confidence,
                    r.stamp_x_pct,
                    r.stamp_y_pct,
                    r.stamp_page,
                        CASE
                            WHEN derm.fn_sheet_is_generated(r.white_manifest_number) THEN 8.00
                            ELSE 8.0
                        END AS guess_x_pct,
                    round(
                        CASE
                            WHEN ((r.band_y0_pct IS NOT NULL) AND (r.band_y1_pct IS NOT NULL)) THEN ((r.band_y0_pct + r.band_y1_pct) / (2)::numeric)
                            WHEN derm.fn_sheet_is_generated(r.white_manifest_number) THEN ( SELECT g.o_y_pct FROM derm.fn_generated_row_geometry(derm.fn_generated_sheet_slot(r.matched_manifest_id)) g)
                            WHEN (ext.top_pct IS NOT NULL) THEN LEAST((ext.top_pct + (((r.row_index)::numeric - 0.5) * LEAST(((ext.bottom_pct - ext.top_pct) / (NULLIF(r.mx, 0))::numeric), 6.0))), ext.bottom_pct)
                            ELSE LEAST(((28)::numeric + (((r.row_index)::numeric - 0.5) * 5.2)), (62)::numeric)
                        END, 3) AS guess_y_pct,
                    (r.stamp_placed_at IS NOT NULL) AS placed,
                    (r.source = 'stamp-studio'::text) AS is_manual,
                    r.matched_client_id,
                    r.matched_manifest_id,
                    r.band_y0_pct,
                    r.band_y1_pct,
                    r.band_source,
                    (r.reviewed_at IS NOT NULL) AS reviewed,
                    ((r.matched_manifest_id IS NOT NULL) AND (EXISTS ( SELECT 1
                           FROM manifest_visits mv
                          WHERE (mv.manifest_id = r.matched_manifest_id)))) AS visit_linked,
                    ( SELECT count(*) AS count
                           FROM manifest_visits mv
                          WHERE (mv.manifest_id = r.matched_manifest_id)) AS linked_visit_count,
                        CASE
                            WHEN derm.fn_sheet_is_generated(r.white_manifest_number) THEN 'generated'::text
                            WHEN (r.source = ANY (ARRAY['derm-link'::text, 'linked-backfill'::text])) THEN 'low'::text
                            ELSE 'ok'::text
                        END AS guess_confidence,
                    derm.fn_sheet_is_generated(r.white_manifest_number) AS is_generated
                   FROM ((( SELECT a_1.id,
                            a_1.dump_folder,
                            a_1.white_manifest_number,
                            a_1.page,
                            a_1.row_index,
                            a_1.image_url,
                            a_1.facility_name_read,
                            a_1.address_read,
                            a_1.matched_client_id,
                            a_1.assignment_status,
                            a_1.confidence,
                            a_1.agent_agreement,
                            a_1.flags,
                            a_1.source,
                            a_1.reviewed_by,
                            a_1.reviewed_at,
                            a_1.created_at,
                            a_1.updated_at,
                            a_1.stamp_x_pct,
                            a_1.stamp_y_pct,
                            a_1.stamp_page,
                            a_1.stamp_placed_at,
                            a_1.stamp_placed_by,
                            a_1.manual_code,
                            a_1.matched_manifest_id,
                            a_1.band_y0_pct,
                            a_1.band_y1_pct,
                            a_1.band_source,
                            a_1.band_set_at,
                            a_1.band_set_by,
                            max(a_1.row_index) OVER (PARTITION BY a_1.dump_folder, a_1.page) AS mx
                           FROM derm.address_row_map a_1) r
                     LEFT JOIN clients c ON ((c.id = r.matched_client_id)))
                     LEFT JOIN derm.page_block_extents ext ON (((ext.dump_folder = r.dump_folder) AND (ext.effective_page = COALESCE(r.stamp_page, r.page)))))
                  WHERE ((r.white_manifest_number IS NOT NULL) AND (((r.matched_client_id IS NOT NULL) AND (c.client_code IS NOT NULL)) OR (r.manual_code IS NOT NULL)) AND ((r.stamp_placed_at IS NOT NULL) OR (r.manual_code IS NOT NULL) OR ((r.matched_manifest_id IS NOT NULL) AND (EXISTS ( SELECT 1
                           FROM derm_manifests m
                          WHERE ((m.id = r.matched_manifest_id) AND (m.deleted_at IS NULL)))))))) sr_1
             LEFT JOIN gdos gg ON ((gg.id = ( SELECT r2.gdo_id
                   FROM derm.address_row_map r2
                  WHERE (r2.id = sr_1.id)))))) sr
     LEFT JOIN derm.address_row_map a ON ((a.id = sr.id)));

-- ---- D3: resolver gains placement + completion for EXISTING cards -----------
CREATE OR REPLACE FUNCTION derm.fn_resolve_generated_sheet_for_ticket(p_ticket text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'derm','public'
AS $fn$
declare v_sheet_id bigint; v_n int;
begin
  if p_ticket is null then return null; end if;

  -- already resolved? still run the placement pass: cards may have been created
  -- (or re-created) after the first resolution, and the pass is idempotent.
  select s.id into v_sheet_id
    from derm.address_sheets s
    join derm.address_sheet_manifests l on l.sheet_id = s.id
    join public.derm_manifests m on m.id = l.manifest_id and m.deleted_at is null
   where s.deleted_at is null
     and coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
   limit 1;

  if v_sheet_id is null then
    -- candidates whose printed client set EXACTLY equals the ticket's client set.
    -- ⚠ On an N-client shared ticket this correctly returns NULL for the first N-1
    -- filings and resolves on the LAST one. Refuse-not-guess; do not relax.
    with ticket_clients as (
      select distinct m.client_id
        from public.derm_manifests m
       where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
         and m.deleted_at is null
    ), cand as (
      select c.sheet_id
        from derm.address_sheet_clients c
        join derm.address_sheets s on s.id = c.sheet_id and s.deleted_at is null
       where not exists (select 1 from derm.address_sheet_manifests l where l.sheet_id = c.sheet_id)
       group by c.sheet_id
      having array_agg(distinct c.client_id order by c.client_id)
           = (select array_agg(distinct tc.client_id order by tc.client_id) from ticket_clients tc)
    )
    select count(*), min(sheet_id) into v_n, v_sheet_id from cand;

    if v_n <> 1 then return null; end if;

    insert into derm.address_sheet_manifests (sheet_id, manifest_id, slot)
    select v_sheet_id, m.id, c.slot
      from public.derm_manifests m
      join derm.address_sheet_clients c
        on c.client_id = m.client_id and c.sheet_id = v_sheet_id
     where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
       and m.deleted_at is null
    on conflict (sheet_id, manifest_id) do update set slot = excluded.slot;

    update public.derm_manifests m
       set derm_address_no = (select s.sheet_no from derm.address_sheets s where s.id = v_sheet_id)
     where coalesce(m.white_manifest_number, m.yellow_ticket_number) = p_ticket
       and m.deleted_at is null
       and m.derm_address_no is distinct from (select s.sheet_no from derm.address_sheets s where s.id = v_sheet_id);
  end if;

  -- D3 (2026-07-30): stamp the ticket's EXISTING unplaced cards. The BEFORE-INSERT
  -- autoplace trigger cannot reach cards created before resolution (all 9 current
  -- ones), so the resolver places them here with the SAME refusal rules:
  -- never touch a placed stamp, skip when the slot is unknowable, corrected
  -- geometry only, attributed 'stamp-studio-ai' (which is what the Studio badge
  -- aggregates count).
  update derm.address_row_map a
     set page        = s.o_page,
         stamp_page  = s.o_page,
         stamp_x_pct = round(s.o_x_pct, 3),
         stamp_y_pct = round(s.o_y_pct, 3),
         stamp_placed_at = now(),
         stamp_placed_by = 'stamp-studio-ai'
    from (select r.id, g.o_page, g.o_x_pct, g.o_y_pct
            from derm.address_row_map r
            cross join lateral derm.fn_generated_row_geometry(
                         derm.fn_generated_sheet_slot(r.matched_manifest_id)) g
           where r.white_manifest_number = p_ticket
             and r.stamp_placed_at is null) s
   where a.id = s.id
     and s.o_y_pct is not null;

  -- Completion parity: trg_zy_generated_sheet_complete is AFTER INSERT only, so an
  -- UPDATE-path placement must complete the sheet itself — and ONLY when every card
  -- of the folder is placed. Same upsert shape as the trigger (never overwrites an
  -- existing completion).
  insert into derm.stamp_sheet_status (dump_folder, completed, completed_at, completed_by, updated_at)
  select d.dump_folder, true, now(), 'stamp-studio-ai', now()
    from (select distinct r.dump_folder from derm.address_row_map r
           where r.white_manifest_number = p_ticket) d
   where not exists (select 1 from derm.address_row_map r2
                      where r2.dump_folder = d.dump_folder and r2.stamp_placed_at is null)
  on conflict (dump_folder) do update
     set completed    = true,
         completed_at = coalesce(derm.stamp_sheet_status.completed_at, now()),
         completed_by = coalesce(derm.stamp_sheet_status.completed_by, 'stamp-studio-ai'),
         updated_at   = now()
   where not derm.stamp_sheet_status.completed;

  return v_sheet_id;
end $fn$;

REVOKE ALL ON FUNCTION derm.fn_resolve_generated_sheet_for_ticket(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION derm.fn_resolve_generated_sheet_for_ticket(text) TO authenticated, service_role;

-- ---- D2: the missing wire — resolve at filing time --------------------------
CREATE OR REPLACE FUNCTION derm.trg_resolve_generated_on_manifest()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'derm','public'
AS $fn$
begin
  if new.deleted_at is null then
    begin
      perform derm.fn_resolve_generated_sheet_for_ticket(
        coalesce(new.white_manifest_number, new.yellow_ticket_number));
    exception when others then
      -- Filing is business-critical; a resolver failure must not abort it. The
      -- unresolved sheet stays visibly 0/N in the Studio, which is this lane's
      -- designed failure mode (refuse, visibly).
      raise warning 'generated-sheet resolver failed for %: %',
        coalesce(new.white_manifest_number, new.yellow_ticket_number), sqlerrm;
    end;
  end if;
  return null;
end $fn$;

REVOKE ALL ON FUNCTION derm.trg_resolve_generated_on_manifest() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_zy_resolve_generated_sheet ON public.derm_manifests;
CREATE TRIGGER trg_zy_resolve_generated_sheet
  AFTER INSERT OR UPDATE OF white_manifest_number, yellow_ticket_number, deleted_at
  ON public.derm_manifests
  FOR EACH ROW EXECUTE FUNCTION derm.trg_resolve_generated_on_manifest();

COMMIT;
