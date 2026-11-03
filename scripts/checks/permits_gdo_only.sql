-- The DERM readers show only GDO permits; public.gdos holds every permit type since 2026-11-02 (Trello sWPaXFZO,
-- plan docs/specs/2026-11-02-permits-one-table-plan.md). Fred: "the DERM sheets, the filing bot and the portal still
-- see only GDO".
-- Checks, each must be 0:
--   rule_gdo_number_other_type  a live (not INACTIVE) permit numbered GDO... whose type is not GDO. The ~20 readers that
--                               test gdo_number ~ '^GDO-[0-9]+$' are GDO-only ONLY while this is 0
--                               (trg_aa_permit_number_matches_type enforces it on every write).
--   rule_gdo_bad_number         a live GDO permit whose number is not GDO-n.
--   rule_retired_type_live      a live permit whose type is retired (permit_types.status not ACTIVE; PSO since
--                               2026-11-02_2030, Fred: "we don't have a PSO miami remove it"). Same trigger enforces it.
--   derm_gdos / derm_compliance / portal_gdo_link / filing_fields / label_reader: a non-GDO permit in a GDO-only reader.
-- Positive control: public.gdos must hold at least one non-GDO permit, or the reader checks
-- above compare against nothing and prove nothing. Before 2026-11-02_1810 derm_gdos, derm_compliance, portal_gdo_link
-- and label_reader each read 1 (057-BAY's PSO-00025), which is the check's own failing control.
-- Healthy = status 'ok'. Read-only.
with other as (select id, client_id, gdo_number, permit_document_path from public.gdos where permit_type <> 'GDO'),
c as (
  select
    (select count(*) from public.gdos where status <> 'INACTIVE' and permit_type <> 'GDO' and gdo_number ~* '^[[:space:]]*GDO') as rule_gdo_number_other_type,
    (select count(*) from public.gdos where status <> 'INACTIVE' and permit_type = 'GDO' and gdo_number !~ '^GDO-[0-9]+$') as rule_gdo_bad_number,
    (select count(*) from public.gdos g join public.permit_types t on t.code = g.permit_type
      where g.status <> 'INACTIVE' and t.status <> 'ACTIVE') as rule_retired_type_live,
    (select count(*) from derm.gdos d where d.id in (select id from other)) as derm_gdos,
    (select count(*) from ops.v_derm_compliance d join other o on o.client_id = d.id and o.gdo_number = d.permit_number) as derm_compliance,
    (select count(*) from customer.clients cc where cc.gdo_permit_url in (select permit_document_path from other)) as portal_gdo_link,
    (select count(*) from public.v_derm_portal_fields f where f.gdo_id in (select id from other)) as filing_fields,
    (select count(*) from public.fn_gdo_permit_label_targets(1000, (select array_agg(id) from other))) as label_reader,
    (select count(*) from public.gdos where permit_type <> 'GDO') as control_other_types
)
select case
         when control_other_types = 0 then 'CONTROL FAILED: no non-GDO permit exists, so the reader checks prove nothing'
         when rule_gdo_number_other_type + rule_gdo_bad_number + rule_retired_type_live + derm_gdos + derm_compliance + portal_gdo_link
              + filing_fields + label_reader > 0 then 'LEAK'
         else 'ok' end as status,
       c.*
from c;
