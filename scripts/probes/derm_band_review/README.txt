DERM blackout band review - the tools that actually work.

  rows.sql   pull every banded row with the image the redactor really used
             (address_row_map.image_url is NOT it: on a multi-page sheet it usually
              points at page 1, so 157 pages would be reviewed against the wrong scan.
              redacted_manifest_docs.source_url is the authoritative one.)
  queue.js   build sweep-queue.json from rows.sql output, ordered by band height
  sweep.js   render band overlays over the roster column, several pages per composite
  served.js  render the SERVED redacted documents - the ground truth a client opens
  ruler.js   render one page's roster at high zoom with a y-scale in page-percent,
             so a boundary can be READ off the paper

Order of use: sweep.js to triage, ruler.js to measure a repair, served.js to confirm.

Do NOT write output into the repo. These scans carry several clients' names and
addresses on one page and this repository is PUBLIC. Everything renders to the
session scratchpad.

Four automated scorers have been tried and rejected against known truth; see the
header of docs/migrations/2026-08-21_0651_fix_derm_1194_p3_boundary_leak.sql before
building a fifth.
