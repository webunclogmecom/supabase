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

----------------------------------------------------------------------------
2026-08-27: THREE MORE REJECTED APPROACHES, this time for the EXTENT, not the
band scorer. Read this before automating derm.page_block_extents.

The four rejected SCORERS above answer "where are the printed rules". These
three answer "which of them bound the roster", and all three failed against
pages a human had already measured:

  1. Ask the vision model for each row's top/bottom as a % of image height.
     On ticket-833813 p1 it returned a flawless 8.0pp ladder
     (20.5/28.5/36.5/44.5/52.5) against real slots of 8.363/6.690/7.218/
     8.099/7.746. Wrong by up to 5.38pp; half a slot is ~3.8pp. It generates
     a uniform grid rather than measuring, and the uniformity is the tell.

  2. Draw the detected rules on the image, label them A..Q, and ask the model
     to NAME each row's bounding labels. Estimation -> selection, which ought
     to be easier. It read the labels but returned them out of order
     (B, D, F, E, G...) and missed 3 of 17.

  3. No model at all: pick the contiguous run of N+1 full-width rules that
     puts one stamp in each slot, with N from the row OCR, optionally also
     requiring one mid-slot divider per slot.

       variant                        proposed refused exact  LANDED SHORT
       geometry alone                    132      30     21      110
       + row-OCR row count                11       6      7        4
       + one divider per slot             12       5      7        5

     The first line is the lesson: WITHOUT KNOWING HOW MANY ROWS ARE PRINTED
     the boundary lands short on 83% of pages, by up to 27pp. Stamps cannot
     see a printed row nobody owns - the ticket-310590 p2 blindness.

  GOOD RESULT WORTH KEEPING: the "printed rows == owned cards" gate REFUSES
  ticket-310590 p2, the one confirmed leak in the fleet. Keep that check even
  if nothing automated ever consumes it. Its input, derm.address_sheet_row_reads,
  covered only 20 of 175 pages on 2026-08-27.

  CONCLUSION: the extent is set by a person, in the Stamp Studio, as part of
  stamping. See Building Apps/DERM Stamp Studio/docs/11-completion-gated-publish-spec.md
