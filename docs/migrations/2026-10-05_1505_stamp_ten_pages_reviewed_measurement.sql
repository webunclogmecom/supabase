-- Stamp Studio: a reviewed machine measurement for the 10 pages that had none graded OK
--
-- Fred, 2026-10-05: "measure the 10 pages that lost their check". Since 2026-10-05_1600 derm.save_page_bands
-- trusts only a measurement graded OK as its independent check, and 10 pages (all on COMPLETED sheets) had only a
-- SPARSE or IRREGULAR one (the 2026-08-21 fleet pass). This records one OK measurement per page as
-- runlen-v2-2026-10-05 through derm.record_page_rules (the validator judges each set), so each page has a reference
-- again and the band review grades read correct lines.
--
-- HOW THE SETS WERE MADE (scratchpad review, 2026-10-05):
-- * Every position, run and ink value is the detector's OWN output on the page's current scan
--   (_shared/printed_rule_detector.mjs, with and without the page's Limit as the window). No line was moved or added.
-- * 3 pages measured cleanly by machine (828604 p1, 830714 p1, window5-sheet3 p1). On the 7 others the automatic
--   labeller confused full-width slot boundaries and short mid-slot dividers (dark scans, handwriting over a line, a
--   missed divider), so a reviewer relabelled the detector's lines from what the paper shows, and two independent
--   reviewers per page (printed lines; geometry and consequence) tried to refute every set, the 3 automatic ones too.
--   Both reviewers refuted the automatic sets of 830714 p1 and window5-sheet3 p1 for the same single label (the title
--   bar's top edge called a divider); that one label is fixed here. All other sets were not refuted.
-- * Where the detector missed a printed mid-slot divider, strict alternation is impossible, so the honest record is
--   a chain of slot boundaries only (validator V4b: evenly pitched; every page here is within 3%).
-- * Every page has 7 slot boundaries (6 printed slots).
--
-- EFFECT, simulated in rolled-back transactions before this file was written: the off-rule worklist
-- (derm.v_band_edges_off_rule) is empty for all 10 pages before and after; band slot grades improve on 6 pages
-- (PART_SLOT / SPANS_MULTIPLE that came from flipped labels become ONE_CLIENT); one band moves the other way and is
-- right to (ticket-831102 p2 169-TCE: PART_SLOT -> SPANS_MULTIPLE, its top edge sits 1.08pp above the printed line
-- between it and 024-GRO). No band, extent or document is changed by this file.
-- Old scans are kept (runlen-v2-2026-08-21 rows stay); the new rows rank equal and newer, so they are what is served.
-- ROLLBACK: delete from derm.page_row_rules / derm.page_rule_scans where source = 'runlen-v2-2026-10-05' and
-- (dump_folder, effective_page) is one of the 10 pages below. Neither table is audited (rule 8, unchanged).
-- Applied 2026-10-05 15:05 ET.

begin;

do $$
declare v jsonb;
begin
  -- ticket-828604 p1: 13 rules, alternating
  v := derm.record_page_rules('ticket-828604', 1, 'runlen-v2-2026-10-05', 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1246/address_1.JPG',
         '[{"pct":27.97,"run":0.988,"ink":0,"kind":"boundary"},{"pct":30.87,"run":0.357,"ink":0,"kind":"divider"},{"pct":33.494,"run":0.989,"ink":0,"kind":"boundary"},{"pct":36.119,"run":0.356,"ink":0,"kind":"divider"},{"pct":39.019,"run":0.987,"ink":0,"kind":"boundary"},{"pct":41.644,"run":0.355,"ink":0,"kind":"divider"},{"pct":44.406,"run":0.989,"ink":0,"kind":"boundary"},{"pct":47.099,"run":0.357,"ink":0,"kind":"divider"},{"pct":49.793,"run":0.991,"ink":0,"kind":"boundary"},{"pct":52.555,"run":0.356,"ink":0,"kind":"divider"},{"pct":55.318,"run":0.989,"ink":0,"kind":"boundary"},{"pct":57.942,"run":0.355,"ink":0,"kind":"divider"},{"pct":60.704,"run":0.987,"ink":0,"kind":"boundary"}]'::jsonb,
         '{"grade":"OK","detail":"reviewed measurement 2026-10-05 (alternating): automatic labels, confirmed by two reviewers","image_w":952,"image_h":724,"skew":0}'::jsonb, false);
  if not coalesce((v->>'wrote')::boolean, false) or v->>'grade' <> 'OK' or (v->>'rules_written')::int <> 13 then
    raise exception 'ticket-828604 p1 not recorded: %', v;
  end if;
  -- ticket-830714 p1: 16 rules, alternating
  v := derm.record_page_rules('ticket-830714', 1, 'runlen-v2-2026-10-05', 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1622/address_1.jpeg',
         '[{"pct":25.319,"run":0.357,"ink":0,"kind":"header-footer"},{"pct":27.679,"run":0.984,"ink":0,"kind":"boundary"},{"pct":30.485,"run":0.357,"ink":0,"kind":"divider"},{"pct":33.163,"run":0.985,"ink":0,"kind":"boundary"},{"pct":35.906,"run":0.358,"ink":0,"kind":"divider"},{"pct":38.648,"run":0.985,"ink":0,"kind":"boundary"},{"pct":41.327,"run":0.359,"ink":0,"kind":"divider"},{"pct":44.069,"run":0.986,"ink":0,"kind":"boundary"},{"pct":46.811,"run":0.358,"ink":0,"kind":"divider"},{"pct":49.617,"run":0.986,"ink":0,"kind":"boundary"},{"pct":52.296,"run":0.358,"ink":0,"kind":"divider"},{"pct":55.102,"run":0.986,"ink":0,"kind":"boundary"},{"pct":57.844,"run":0.358,"ink":0,"kind":"divider"},{"pct":60.523,"run":0.986,"ink":0,"kind":"boundary"},{"pct":62.564,"run":0.985,"ink":0,"kind":"header-footer"},{"pct":64.987,"run":0.985,"ink":0,"kind":"header-footer"}]'::jsonb,
         '{"grade":"OK","detail":"reviewed measurement 2026-10-05 (alternating): automatic labels with ONE fix: 25.319 is the top edge of the B title bar (header-footer), not a mid-slot divider; found by both reviewers","image_w":1024,"image_h":784,"skew":0}'::jsonb, false);
  if not coalesce((v->>'wrote')::boolean, false) or v->>'grade' <> 'OK' or (v->>'rules_written')::int <> 16 then
    raise exception 'ticket-830714 p1 not recorded: %', v;
  end if;
  -- window5-sheet3 p1: 16 rules, alternating
  v := derm.record_page_rules('window5-sheet3', 1, 'runlen-v2-2026-10-05', 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/52/address.jpg',
         '[{"pct":25.091,"run":0.354,"ink":0,"kind":"header-footer"},{"pct":27.514,"run":0.978,"ink":0,"kind":"boundary"},{"pct":30.254,"run":0.354,"ink":0,"kind":"divider"},{"pct":32.948,"run":0.978,"ink":0,"kind":"boundary"},{"pct":35.688,"run":0.36,"ink":0,"kind":"divider"},{"pct":38.383,"run":0.978,"ink":0,"kind":"boundary"},{"pct":41.168,"run":0.354,"ink":0,"kind":"divider"},{"pct":43.863,"run":0.979,"ink":0,"kind":"boundary"},{"pct":46.626,"run":0.353,"ink":0,"kind":"divider"},{"pct":49.343,"run":0.98,"ink":0,"kind":"boundary"},{"pct":52.106,"run":0.355,"ink":0,"kind":"divider"},{"pct":54.778,"run":0.981,"ink":0,"kind":"boundary"},{"pct":57.563,"run":0.356,"ink":0,"kind":"divider"},{"pct":60.281,"run":0.981,"ink":0,"kind":"boundary"},{"pct":62.274,"run":0.98,"ink":0,"kind":"header-footer"},{"pct":64.697,"run":0.98,"ink":0,"kind":"header-footer"}]'::jsonb,
         '{"grade":"OK","detail":"reviewed measurement 2026-10-05 (alternating): automatic labels with ONE fix: 25.091 is the top edge of the B title bar (header-footer), not a mid-slot divider; found by both reviewers","image_w":2988,"image_h":2208,"skew":0}'::jsonb, false);
  if not coalesce((v->>'wrote')::boolean, false) or v->>'grade' <> 'OK' or (v->>'rules_written')::int <> 16 then
    raise exception 'window5-sheet3 p1 not recorded: %', v;
  end if;
  -- ticket-830574 p1: 9 rules, boundaries only
  v := derm.record_page_rules('ticket-830574', 1, 'runlen-v2-2026-10-05', 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1453/address_1.JPG',
         '[{"pct":28.037,"run":0.831,"ink":0,"kind":"boundary"},{"pct":33.451,"run":0.842,"ink":0,"kind":"boundary"},{"pct":38.908,"run":0.982,"ink":0,"kind":"boundary"},{"pct":44.278,"run":0.983,"ink":0,"kind":"boundary"},{"pct":49.692,"run":0.984,"ink":0,"kind":"boundary"},{"pct":55.106,"run":0.984,"ink":0,"kind":"boundary"},{"pct":60.519,"run":0.985,"ink":0,"kind":"boundary"},{"pct":62.588,"run":0.984,"ink":0,"kind":"header-footer"},{"pct":64.965,"run":0.982,"ink":0,"kind":"header-footer"}]'::jsonb,
         '{"grade":"OK","detail":"reviewed measurement 2026-10-05 (boundaries only): boundaries only: slot 2 mid-slot divider (about 36.2) printed but not detected","image_w":1444,"image_h":1136,"skew":0.002}'::jsonb, false);
  if not coalesce((v->>'wrote')::boolean, false) or v->>'grade' <> 'OK' or (v->>'rules_written')::int <> 9 then
    raise exception 'ticket-830574 p1 not recorded: %', v;
  end if;
  -- ticket-831047 p1: 10 rules, boundaries only
  v := derm.record_page_rules('ticket-831047', 1, 'runlen-v2-2026-10-05', 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1638/address_1.jpg',
         '[{"pct":24.857,"run":0.362,"ink":0,"kind":"header-footer"},{"pct":27.34,"run":0.991,"ink":0,"kind":"boundary"},{"pct":32.877,"run":0.992,"ink":0,"kind":"boundary"},{"pct":38.299,"run":0.992,"ink":0,"kind":"boundary"},{"pct":43.75,"run":0.993,"ink":0,"kind":"boundary"},{"pct":49.258,"run":0.644,"ink":0,"kind":"boundary"},{"pct":54.795,"run":0.994,"ink":0,"kind":"boundary"},{"pct":60.274,"run":0.939,"ink":0,"kind":"boundary"},{"pct":62.243,"run":0.667,"ink":0,"kind":"header-footer"},{"pct":64.612,"run":0.667,"ink":0,"kind":"header-footer"}]'::jsonb,
         '{"grade":"OK","detail":"reviewed measurement 2026-10-05 (boundaries only): boundaries only: slot 4-6 dividers (about 46.6, 52.1, 57.5) not detected; 61.30 is bar text, left out","image_w":2264,"image_h":1752,"skew":-0.008}'::jsonb, false);
  if not coalesce((v->>'wrote')::boolean, false) or v->>'grade' <> 'OK' or (v->>'rules_written')::int <> 10 then
    raise exception 'ticket-831047 p1 not recorded: %', v;
  end if;
  -- ticket-831102 p1: 10 rules, boundaries only
  v := derm.record_page_rules('ticket-831102', 1, 'runlen-v2-2026-10-05', 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1639/address_1.jpg',
         '[{"pct":25.2,"run":0.351,"ink":0,"kind":"header-footer"},{"pct":27.733,"run":0.791,"ink":0,"kind":"boundary"},{"pct":33.2,"run":0.894,"ink":0,"kind":"boundary"},{"pct":38.667,"run":0.954,"ink":0,"kind":"boundary"},{"pct":44.133,"run":0.991,"ink":0,"kind":"boundary"},{"pct":49.6,"run":0.992,"ink":0,"kind":"boundary"},{"pct":55.067,"run":0.991,"ink":0,"kind":"boundary"},{"pct":60.5,"run":0.99,"ink":0,"kind":"boundary"},{"pct":62.5,"run":0.99,"ink":0,"kind":"header-footer"},{"pct":64.933,"run":0.989,"ink":0,"kind":"header-footer"}]'::jsonb,
         '{"grade":"OK","detail":"reviewed measurement 2026-10-05 (boundaries only): boundaries only: slot 1 divider (about 30.4) not detected; 25.2 is the B title bar top (header-footer)","image_w":1852,"image_h":1500,"skew":0.003}'::jsonb, false);
  if not coalesce((v->>'wrote')::boolean, false) or v->>'grade' <> 'OK' or (v->>'rules_written')::int <> 10 then
    raise exception 'ticket-831102 p1 not recorded: %', v;
  end if;
  -- ticket-831102 p2: 10 rules, boundaries only
  v := derm.record_page_rules('ticket-831102', 2, 'runlen-v2-2026-10-05', 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1639/address_2.jpg',
         '[{"pct":22.764,"run":0.36,"ink":0,"kind":"header-footer"},{"pct":25.407,"run":0.716,"ink":0,"kind":"boundary"},{"pct":30.894,"run":0.785,"ink":0,"kind":"boundary"},{"pct":36.382,"run":0.922,"ink":0,"kind":"boundary"},{"pct":41.87,"run":0.991,"ink":0,"kind":"boundary"},{"pct":47.392,"run":0.99,"ink":0,"kind":"boundary"},{"pct":52.947,"run":0.99,"ink":0,"kind":"boundary"},{"pct":58.537,"run":0.988,"ink":0,"kind":"boundary"},{"pct":60.637,"run":0.988,"ink":0,"kind":"header-footer"},{"pct":63.076,"run":0.988,"ink":0,"kind":"header-footer"}]'::jsonb,
         '{"grade":"OK","detail":"reviewed measurement 2026-10-05 (boundaries only): boundaries only: slot 2 divider (about 33.6) not detected; the photo is bowed (lines sit 0.3-0.7pp higher at the left edge)","image_w":1912,"image_h":1476,"skew":0.008}'::jsonb, false);
  if not coalesce((v->>'wrote')::boolean, false) or v->>'grade' <> 'OK' or (v->>'rules_written')::int <> 10 then
    raise exception 'ticket-831102 p2 not recorded: %', v;
  end if;
  -- window10-sheet4 p2: 10 rules, boundaries only
  v := derm.record_page_rules('window10-sheet4', 2, 'runlen-v2-2026-10-05', 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/284/address.jpg',
         '[{"pct":24.846,"run":0.366,"ink":0,"kind":"header-footer"},{"pct":27.137,"run":0.98,"ink":0,"kind":"boundary"},{"pct":32.511,"run":0.944,"ink":0,"kind":"boundary"},{"pct":37.841,"run":0.898,"ink":0,"kind":"boundary"},{"pct":43.282,"run":0.916,"ink":0,"kind":"boundary"},{"pct":48.722,"run":0.947,"ink":0,"kind":"boundary"},{"pct":54.207,"run":0.98,"ink":0,"kind":"boundary"},{"pct":59.714,"run":0.946,"ink":0,"kind":"boundary"},{"pct":61.762,"run":0.963,"ink":0,"kind":"header-footer"},{"pct":64.229,"run":0.977,"ink":0,"kind":"header-footer"}]'::jsonb,
         '{"grade":"OK","detail":"reviewed measurement 2026-10-05 (boundaries only): boundaries only: slot 2-5 dividers (about 35.2, 40.6, 46.0, 51.5) not detected","image_w":3000,"image_h":2270,"skew":0.002}'::jsonb, false);
  if not coalesce((v->>'wrote')::boolean, false) or v->>'grade' <> 'OK' or (v->>'rules_written')::int <> 10 then
    raise exception 'window10-sheet4 p2 not recorded: %', v;
  end if;
  -- window11-sheet8 p1: 16 rules, alternating
  v := derm.record_page_rules('window11-sheet8', 1, 'runlen-v2-2026-10-05', 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/77/address.jpg',
         '[{"pct":25.954,"run":0.36,"ink":0,"kind":"header-footer"},{"pct":28.422,"run":0.991,"ink":0,"kind":"boundary"},{"pct":31.052,"run":0.36,"ink":0,"kind":"divider"},{"pct":33.776,"run":0.991,"ink":0,"kind":"boundary"},{"pct":36.406,"run":0.358,"ink":0,"kind":"divider"},{"pct":39.153,"run":0.991,"ink":0,"kind":"boundary"},{"pct":41.806,"run":0.36,"ink":0,"kind":"divider"},{"pct":44.507,"run":0.991,"ink":0,"kind":"boundary"},{"pct":47.183,"run":0.339,"ink":0,"kind":"divider"},{"pct":49.93,"run":0.993,"ink":0,"kind":"boundary"},{"pct":52.607,"run":0.362,"ink":0,"kind":"divider"},{"pct":55.331,"run":0.993,"ink":0,"kind":"boundary"},{"pct":58.007,"run":0.362,"ink":0,"kind":"divider"},{"pct":60.638,"run":0.993,"ink":0,"kind":"boundary"},{"pct":62.663,"run":0.993,"ink":0,"kind":"header-footer"},{"pct":65.037,"run":0.671,"ink":0,"kind":"header-footer"}]'::jsonb,
         '{"grade":"OK","detail":"reviewed measurement 2026-10-05 (alternating): labels relabelled from the paper: 25.954, 62.663, 65.037 are bar edges; the automatic run had flipped them into the chain","image_w":2704,"image_h":2148,"skew":0}'::jsonb, false);
  if not coalesce((v->>'wrote')::boolean, false) or v->>'grade' <> 'OK' or (v->>'rules_written')::int <> 16 then
    raise exception 'window11-sheet8 p1 not recorded: %', v;
  end if;
  -- window4-sheet5 p1: 9 rules, boundaries only
  v := derm.record_page_rules('window4-sheet5', 1, 'runlen-v2-2026-10-05', 'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/GT%20-%20Visits%20Images/derm/970/address.jpg',
         '[{"pct":28.669,"run":0.975,"ink":0,"kind":"boundary"},{"pct":34.119,"run":0.991,"ink":0,"kind":"boundary"},{"pct":39.465,"run":0.978,"ink":0,"kind":"boundary"},{"pct":44.838,"run":0.987,"ink":0,"kind":"boundary"},{"pct":50.236,"run":0.96,"ink":0,"kind":"boundary"},{"pct":55.582,"run":0.975,"ink":0,"kind":"boundary"},{"pct":60.901,"run":0.989,"ink":0,"kind":"boundary"},{"pct":63.05,"run":0.831,"ink":0,"kind":"header-footer"},{"pct":65.225,"run":0.947,"ink":0,"kind":"header-footer"}]'::jsonb,
         '{"grade":"OK","detail":"reviewed measurement 2026-10-05 (boundaries only): boundaries only: all six dividers printed but not detected","image_w":2428,"image_h":1908,"skew":-0.003}'::jsonb, false);
  if not coalesce((v->>'wrote')::boolean, false) or v->>'grade' <> 'OK' or (v->>'rules_written')::int <> 9 then
    raise exception 'window4-sheet5 p1 not recorded: %', v;
  end if;
end $$;

-- VERIFY: every page serves the new set, is graded OK, is the reference save_page_bands would pick, and the off-rule
-- worklist stays empty for these pages
do $verify$
declare r record; n int;
begin
  for r in select * from (values ('ticket-828604', 1, 13), ('ticket-830714', 1, 16), ('window5-sheet3', 1, 16), ('ticket-830574', 1, 9), ('ticket-831047', 1, 10), ('ticket-831102', 1, 10), ('ticket-831102', 2, 10), ('window10-sheet4', 2, 10), ('window11-sheet8', 1, 16), ('window4-sheet5', 1, 9)) t(f, p, nrules) loop
    select count(*) into n from derm.v_page_printed_rules where dump_folder = r.f and effective_page = r.p and source = 'runlen-v2-2026-10-05';
    if n <> r.nrules then raise exception 'VERIFY % p%: % served rules from the new scan, expected %', r.f, r.p, n, r.nrules; end if;
    if not exists (select 1 from derm.page_rule_scans s
                    where s.dump_folder = r.f and s.effective_page = r.p and s.source = 'runlen-v2-2026-10-05' and s.grade = 'OK'
                      and s.source_etag = derm._img_etag(s.source_url)) then
      raise exception 'VERIFY % p%: no OK reference for the current scan', r.f, r.p; end if;
    if exists (select 1 from derm.v_band_edges_off_rule o where o.dump_folder = r.f and o.effective_page = r.p) then
      raise exception 'VERIFY % p%: the off-rule worklist is not empty', r.f, r.p; end if;
  end loop;
end $verify$;

commit;
