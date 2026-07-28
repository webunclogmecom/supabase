-- ============================================================================
-- 2026-07-28d — GDO nickname + per-GDO stamp cards
-- ============================================================================
-- Fred, 2026-07-28: (1) label the Stamp Studio cards by GDO so a multi-trap
-- location's 3 identical cards can be told apart; (2) "we should have a property
-- in our db for the GDO like nickname, for cases like Casa Neos, that it has
-- Kitchen, Bar and Lounge ... so in the Clients App we can also read them by
-- their nickname too."
--
-- WHY A NEW COLUMN AND NOT public.gdos.location_label: location_label exists but
-- is holding THREE different kinds of value (32 populated rows inspected) —
--   * real nicknames:  'KITCHENS', 'BARS', 'LOUNGE', 'G-COFFEE'
--   * legal/DBA names: 'ALADDIN MARKET & FOOD, INC.', 'APACHE LANDING BAR & GRILL'
--   * plain addresses: '2200 West 8th Court', '1530 Washington Avenue'
-- Roughly 20 nickname-like vs 12 legal-name-like. That is the same one-column-
-- several-meanings problem we have been removing elsewhere
-- ([[feedback_category_in_column_choice]]), so overloading it further would make
-- it worse. `nickname` is the human label for WHICH trap/area this permit covers;
-- location_label keeps whatever the permit/AT actually carried.
--
-- DISPLAY RULE for every surface: COALESCE(nickname, location_label, gdo_number).
--
-- Seeded ONLY Casa Neos (009-CN), the case Fred named and the only client whose
-- three ACTIVE permits are already unambiguously nicknamed. Everything else is
-- left NULL deliberately — guessing a nickname out of a legal name would be
-- inventing data.
--
-- STAMP CARDS: derm.address_row_map gains gdo_id, so a card says WHICH permit it
-- stamps. add_extra_client_card now auto-assigns the client's next ACTIVE permit
-- not yet used on that sheet, so on Casa Neos the three cards self-label
-- KITCHENS / BARS / LOUNGE instead of three identical "no address" cards.
--
-- AUDIT (ADR 010): public.gdos is already audited — the added column is captured
-- automatically. derm.address_row_map is Stamp-Studio working state (unaudited by
-- design, unchanged here).
-- ============================================================================

begin;

-- 1) the nickname itself -------------------------------------------------------
alter table public.gdos add column if not exists nickname text;
comment on column public.gdos.nickname is
  'Human label for WHICH trap/area this permit covers (Kitchen, Bar, Lounge). Distinct from location_label, which carries the permit/Airtable facility or legal name. Display: COALESCE(nickname, location_label, gdo_number).';

update public.gdos set nickname = 'Kitchen' where gdo_number = 'GDO-10877' and nickname is null;
update public.gdos set nickname = 'Bar'     where gdo_number = 'GDO-15062' and nickname is null;
update public.gdos set nickname = 'Lounge'  where gdo_number = 'GDO-16389' and nickname is null;

-- 2) a stamp card knows which permit it is ------------------------------------
alter table derm.address_row_map add column if not exists gdo_id bigint;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'address_row_map_gdo_id_fkey') then
    alter table derm.address_row_map
      add constraint address_row_map_gdo_id_fkey foreign key (gdo_id)
      references public.gdos(id) on delete set null;
  end if;
end $$;
create index if not exists address_row_map_gdo_idx on derm.address_row_map (gdo_id);

-- 3) backfill: single-permit clients are unambiguous ---------------------------
update derm.address_row_map r
   set gdo_id = g.id
  from public.gdos g
 where r.gdo_id is null
   and g.client_id = r.matched_client_id
   and g.status = 'ACTIVE' and g.gdo_number ~ '^GDO-[0-9]+$'
   and (select count(*) from public.gdos g2
         where g2.client_id = r.matched_client_id
           and g2.status = 'ACTIVE' and g2.gdo_number ~ '^GDO-[0-9]+$') = 1;

-- 4) backfill multi-permit clients: assign distinct permits per card, in order --
with ranked as (
  select r.id as row_id,
         row_number() over (partition by r.dump_folder, r.matched_client_id order by r.row_index, r.id) as rn
    from derm.address_row_map r
   where r.gdo_id is null and r.matched_client_id is not null),
perms as (
  select r.dump_folder, r.matched_client_id, g.id as gdo_id,
         row_number() over (partition by r.dump_folder, r.matched_client_id order by g.id) as rn
    from (select distinct dump_folder, matched_client_id from derm.address_row_map where matched_client_id is not null) r
    join public.gdos g on g.client_id = r.matched_client_id
                      and g.status = 'ACTIVE' and g.gdo_number ~ '^GDO-[0-9]+$')
update derm.address_row_map t
   set gdo_id = p.gdo_id
  from ranked k
  join derm.address_row_map src on src.id = k.row_id
  join perms p on p.dump_folder = src.dump_folder
              and p.matched_client_id = src.matched_client_id
              and p.rn = k.rn
 where t.id = k.row_id and t.gdo_id is null;

-- 5) the extra-card RPC now picks the next UNUSED permit on that sheet ---------
create or replace function derm.add_extra_client_card(
  p_dump_folder text,
  p_client_id   bigint,
  p_page        int default 1
)
returns bigint
language plpgsql
security definer
set search_path to 'derm', 'public'
as $fn$
declare
  v_wm text; v_existing derm.address_row_map%rowtype;
  v_next int; v_new_id bigint; v_gdo bigint;
begin
  perform derm._require_stamp_key();
  if p_client_id is null then raise exception 'p_client_id required'; end if;

  select max(white_manifest_number) into v_wm
    from derm.address_row_map where dump_folder = p_dump_folder;
  if v_wm is null then raise exception 'unknown sheet %', p_dump_folder; end if;

  select * into v_existing from derm.address_row_map
   where dump_folder = p_dump_folder and matched_client_id = p_client_id
   order by id limit 1;
  if not found then
    raise exception 'client % is not on sheet % yet — use add_client_card_and_link first',
      p_client_id, p_dump_folder;
  end if;

  -- the client's next ACTIVE permit not already claimed by a card on this sheet
  select g.id into v_gdo
    from public.gdos g
   where g.client_id = p_client_id
     and g.status = 'ACTIVE' and g.gdo_number ~ '^GDO-[0-9]+$'
     and not exists (select 1 from derm.address_row_map r2
                      where r2.dump_folder = p_dump_folder and r2.gdo_id = g.id)
   order by g.id
   limit 1;

  select coalesce(max(row_index), 0) + 1 into v_next
    from derm.address_row_map
   where dump_folder = p_dump_folder and page = coalesce(p_page, 1);

  insert into derm.address_row_map
    (dump_folder, white_manifest_number, page, row_index, image_url,
     matched_client_id, matched_manifest_id, gdo_id, assignment_status, confidence, source, flags)
  values
    (p_dump_folder, v_wm, coalesce(p_page, 1), v_next, v_existing.image_url,
     p_client_id, v_existing.matched_manifest_id, v_gdo, 'matched', 'high',
     'extra-stamp', '{"extra_stamp":true}'::jsonb)
  returning id into v_new_id;

  return v_new_id;
end $fn$;

revoke all on function derm.add_extra_client_card(text, bigint, int) from public;
revoke all on function derm.add_extra_client_card(text, bigint, int) from anon;
grant execute on function derm.add_extra_client_card(text, bigint, int) to authenticated;
grant execute on function derm.add_extra_client_card(text, bigint, int) to service_role;

-- 6) surface it where the apps read -------------------------------------------
-- Stamp Studio card list: wrap the existing view and append the GDO columns
-- (wrap pattern, so the existing column list is preserved byte-for-byte).
create or replace view derm.v_stamp_rows as
select sr.*,
       gg.gdo_number as gdo_number,
       coalesce(gg.nickname, gg.location_label, gg.gdo_number) as gdo_label
  from (SELECT r.id,
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
          WHERE COALESCE(m.white_manifest_number, m.yellow_ticket_number) = r.white_manifest_number AND m.deleted_at IS NULL) AS service_date,
    r.assignment_status,
    r.confidence,
    r.stamp_x_pct,
    r.stamp_y_pct,
    r.stamp_page,
        CASE
            WHEN derm.fn_sheet_is_generated(r.white_manifest_number) THEN 6.82
            ELSE 8.0
        END AS guess_x_pct,
    round(
        CASE
            WHEN r.band_y0_pct IS NOT NULL AND r.band_y1_pct IS NOT NULL THEN (r.band_y0_pct + r.band_y1_pct) / 2::numeric
            WHEN derm.fn_sheet_is_generated(r.white_manifest_number) THEN (ARRAY[25.98, 34.62, 41.58, 49.10, 57.25])[(COALESCE(derm.fn_generated_sheet_slot(r.matched_manifest_id), r.row_index) - 1) % 5 + 1]
            WHEN ext.top_pct IS NOT NULL THEN LEAST(ext.top_pct + (r.row_index::numeric - 0.5) * LEAST((ext.bottom_pct - ext.top_pct) / NULLIF(r.mx, 0)::numeric, 6.0), ext.bottom_pct)
            ELSE LEAST(28::numeric + (r.row_index::numeric - 0.5) * 5.2, 62::numeric)
        END, 3) AS guess_y_pct,
    r.stamp_placed_at IS NOT NULL AS placed,
    r.source = 'stamp-studio'::text AS is_manual,
    r.matched_client_id,
    r.matched_manifest_id,
    r.band_y0_pct,
    r.band_y1_pct,
    r.band_source,
    r.reviewed_at IS NOT NULL AS reviewed,
    r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
           FROM manifest_visits mv
          WHERE mv.manifest_id = r.matched_manifest_id)) AS visit_linked,
    ( SELECT count(*) AS count
           FROM manifest_visits mv
          WHERE mv.manifest_id = r.matched_manifest_id) AS linked_visit_count,
        CASE
            WHEN derm.fn_sheet_is_generated(r.white_manifest_number) THEN 'generated'::text
            WHEN r.source = ANY (ARRAY['derm-link'::text, 'linked-backfill'::text]) THEN 'low'::text
            ELSE 'ok'::text
        END AS guess_confidence,
    derm.fn_sheet_is_generated(r.white_manifest_number) AS is_generated
   FROM ( SELECT a.id,
            a.dump_folder,
            a.white_manifest_number,
            a.page,
            a.row_index,
            a.image_url,
            a.facility_name_read,
            a.address_read,
            a.matched_client_id,
            a.assignment_status,
            a.confidence,
            a.agent_agreement,
            a.flags,
            a.source,
            a.reviewed_by,
            a.reviewed_at,
            a.created_at,
            a.updated_at,
            a.stamp_x_pct,
            a.stamp_y_pct,
            a.stamp_page,
            a.stamp_placed_at,
            a.stamp_placed_by,
            a.manual_code,
            a.matched_manifest_id,
            a.band_y0_pct,
            a.band_y1_pct,
            a.band_source,
            a.band_set_at,
            a.band_set_by,
            max(a.row_index) OVER (PARTITION BY a.dump_folder, a.page) AS mx
           FROM derm.address_row_map a) r
     LEFT JOIN clients c ON c.id = r.matched_client_id
     LEFT JOIN derm.page_block_extents ext ON ext.dump_folder = r.dump_folder AND ext.effective_page = COALESCE(r.stamp_page, r.page)
  WHERE r.white_manifest_number IS NOT NULL AND (r.matched_client_id IS NOT NULL AND c.client_code IS NOT NULL OR r.manual_code IS NOT NULL) AND (r.stamp_placed_at IS NOT NULL OR r.manual_code IS NOT NULL OR r.matched_manifest_id IS NOT NULL AND (EXISTS ( SELECT 1
           FROM derm_manifests m
          WHERE m.id = r.matched_manifest_id AND m.deleted_at IS NULL)))) sr
  left join public.gdos gg on gg.id = (select r2.gdo_id from derm.address_row_map r2 where r2.id = sr.id);

-- Client App: expose the nickname
create or replace view client.gdos as
  select id, client_id, gdo_number, location_label, property_id, permit_expiration,
         permit_document_path, status, notes, created_at, updated_at,
         max_frequency_days, client_location_id, permit_thumbnail_path,
         (gdo_number !~ '^GDO-[0-9]+$') as is_placeholder,
         nickname,
         coalesce(nickname, location_label, gdo_number) as display_label
    from public.gdos;

commit;
