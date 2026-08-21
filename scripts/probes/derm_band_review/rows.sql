with pagesrc as (   -- the image the redactor actually used, per (folder, effective_page)
  select r.dump_folder, coalesce(r.stamp_page,r.page) as pg,
         d.source_url, count(*) as n
    from derm.address_row_map r
    join derm.redacted_manifest_docs d
      on d.manifest_id = r.matched_manifest_id
     and d.client_id   = r.matched_client_id
     and d.effective_page = coalesce(r.stamp_page,r.page)
   group by 1,2,3
), best as (
  select distinct on (dump_folder, pg) dump_folder, pg, source_url, n,
         count(*) over (partition by dump_folder, pg) as distinct_srcs
    from pagesrc order by dump_folder, pg, n desc
)
select r.dump_folder,
       coalesce(r.stamp_page, r.page) as pg,
       coalesce(b.source_url, r.image_url) as src,
       b.distinct_srcs,
       r.id, c.client_code,
       round(r.stamp_y_pct::numeric,3) as s,
       round(r.band_y0_pct::numeric,3) as by0,
       round(r.band_y1_pct::numeric,3) as by1,
       r.band_source,
       exists (select 1 from derm.redacted_manifest_docs d
                where d.manifest_id = r.matched_manifest_id
                  and d.client_id   = r.matched_client_id
                  and d.effective_page = coalesce(r.stamp_page,r.page)) as served
  from derm.address_row_map r
  left join public.clients c on c.id = r.matched_client_id
  left join best b on b.dump_folder = r.dump_folder and b.pg = coalesce(r.stamp_page,r.page)
 where r.band_y0_pct is not null and r.band_y1_pct is not null
 order by 1,2, r.band_y0_pct;
