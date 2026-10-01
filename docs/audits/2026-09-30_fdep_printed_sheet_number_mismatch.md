# 2026-09-30 · Broward per-visit FDEP sheets: the number printed on the paper vs the register

Read-only audit. Nothing was written to the database or to storage. Found while verifying the DERM Tracker
per-visit preview (Building Apps `DERM Tracker/docs/08-changelog.md`, 2026-09-30): the scan for 235-LOU on
yellow ticket 313151 prints "# 10013" while its tile says "Sheet #10021".

## What was measured

All 20 live rows of `derm.manifest_visit_sheets` were checked. Each scan was downloaded and its top-left "#" box
and Section B originator were read by eye. The generated PDFs were read from `derm.generated_visit_sheets`;
`pdf_bucket` / `pdf_path` are empty on all 20 rows of `manifest_visit_sheets`.

| result | count | sheets |
|---|---|---|
| scan number equals the register | 9 | 127-PC 10013; the 2026-09-24 group 10025 to 10031 and 10033 |
| scan number differs | 8 | all on ticket 313151 (table below) |
| cannot be checked | 3 | 312840: 028-HUM 10022, 135-BB 10023, 022-GRO 10024. Older hand-filled form with no printed number; the truck decal "07058" is handwritten in the # box. Their register numbers were minted at upload and never reached the paper |

Ticket 313151, every scan prints **10013**:

| client | visit | register | scan prints | stored PDF prints |
|---|---|---|---|---|
| 205-SAS | 6488 | 10014 | 10013 | 10014 |
| 109-RAB | 6288 | 10015 | 10013 | 10015 |
| 152-DAV | 6357 | 10016 | 10013 | 10016 |
| 020-G7 | 8005 | 10017 | 10013 | 10017 |
| 215-G7 | 6522 | 10018 | 10013 | 10018 |
| 106-ALC | 8001 | 10005 | 10013 | **10019** |
| 019-G7 | 5935 | 10020 | 10013 | 10020 |
| 235-LOU | 7865 | 10021 | 10013 | 10021 |

Every one of the eight shows the RIGHT client in Section B, so the photos are filed correctly; only the number is
wrong. The register is still unique and self-consistent (both tables carry a unique index on `sheet_no`). It no
longer matches the signed paper for these eight visits.

## Two causes

1. **The paper repeat (8 visits), most likely at print time.** The batch was generated 2026-09-08 10:37 ET. The
   register gave 10013 to 10021 in page order, every stored PDF carries its own number, the job's form fields
   each have their own value, and a rebuild of the job renders distinct numbers in two PDF engines. The service
   code did not change between 09-08 and 09-24, and both 09-24 jobs printed correctly. So something after the
   download put page 1's number on every page: most likely the program used to open and print the file (a viewer
   that redraws same-named form fields from the first value), or the printer. The 313151 scans are grayscale
   while the 09-24 ones are colour, which also points to a different setup. **Not confirmed:** the actual 09-08
   print file was not kept.
2. **106-ALC (1 visit), on our side.** Its test row (10005) was generated 2026-09-08 01:08 ET and soft-deleted by
   direct SQL at 01:55 ET. At 10:37 ET the generator could not see the deleted row, so it minted 10019 and
   printed that on the PDF, then the upsert revived the old row with 10005, and the 09-10 upload adopted 10005.
   **10019 was printed but is in no register row.** The mechanism, read off the live
   `public.record_generated_visit_sheet`: its reuse lookup filters `g.deleted_at is null`, so a soft-deleted row
   is invisible and a new number is minted; but its `insert ... on conflict (visit_id) do update` matches that
   same soft-deleted row, sets `deleted_at = null` and deliberately leaves `sheet_no` alone, while the function
   RETURNS the newly minted number, which is what gets printed. The stored and the printed number then differ.
   ⚠ Visit **8022** (10004, still soft-deleted) is set up for the same split the day its manifest is uploaded.

**Nothing reads the printed number off an FDEP scan.** The sheet-number OCR covers the Miami-Dade sheets only, so
none of this can surface in any app, and the DERM Tracker caption shows the register number, not the paper's.

## Why it matters

The regulator-facing number is the one on the signed paper held by the client, us and the receiving facility. On
paper, nine different hauls on ticket 313151 (removals 09-02 and 09-07) carry one manifest number.

## Options (none taken; Fred's call)

1. Ask the office which program and computer printed the 2026-09-08 batch, and open a rebuilt job in it to
   confirm. Cheapest, and it should come first.
2. Keep the register and record the printed number beside it for these 8 visits, so staff see the difference.
3. Make the register match the paper: not workable (unique index, and one number for nine hauls).
4. Correct the office copies by hand or reprint from the stored PDFs. A compliance decision: the signed copies
   elsewhere say 10013.
5. Prevent a repeat by flattening the form fields in the pdf-service print job, so no viewer can redraw them
   (also rename the "#" field). A pdf-service deploy.
6. Read the printed "#" on FDEP scans at upload and flag a mismatch, as the Miami-Dade OCR does.
7. Make the generator see soft-deleted rows (or clear the deleted test rows) before visit 8022 is uploaded.

Evidence (scans, crops, stored PDFs, the rebuilt job, the register and audit row dumps) was kept in the session
scratchpad and is not committed: the scans carry client paperwork.
