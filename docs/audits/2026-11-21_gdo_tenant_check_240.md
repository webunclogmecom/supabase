# GDO permits checked against the client: name, unit, and the county's inspections (Trello #240, 2026-11-21 to 11-22)

**Trello #240 `wyCCimZk`. Read only: nothing in `public.gdos`, the permit files or the county was changed.** The changes wait on
Yannick's or Diego's answers (section 5).

## 1. The ask

Yan, #gdo-permit (Nov 19, asked again Nov 21): client **062-TCE** (Carrot Express, Aventura Mall) showed **GDO-009394**, whose
permit is issued to **another tenant of the mall** (unit #789). *"please run the AI thru the data base so we have the correct permit
for each of our customer"*.

Why the July audit (`2026-07-17_gdo_full_audit.md`) passed it: it compared the ADDRESS only. A mall, plaza, hotel or food hall is one
address for many tenants, so another tenant's permit matched.

## 2. How it was checked (five passes, each one catching what the one before missed)

| pass | what | found |
|---|---|---|
| 1. Our files | Every live GDO permit (142: 138 ACTIVE, 4 EXPIRED) read from its stored file: 125 PDFs with text, 3 scans and 3 TIFF pictures read as images, 11 with no file. 12 readers compared issued-to / d/b/a / facility location / unit with the client and its Jobber property. | 95 matched, 47 flagged |
| 2. Second readers | Each flagged permit went to a reader told to prove the first reading wrong, using the county's public documents search. 6 matched permits went to the same kind of reader as a control. | 9 first readings overturned; 6 of 6 controls held |
| 3. County permits | A script read the county's NEWEST operating permit for every number (`county.mjs`). | 27 numbers with no permit valid for 2026; **GDO-009070 (206-CAC) reissued Jun 17, 2026 to another business**, found only by comparing our file's name with the county's newest |
| 4. Page review | Six readers re-derived every card that needs an answer, plus the page's code and words. | 27 cards changed, among them: 213-TRUE is a coffee shop (unit #160), not a truck; 036-LG, 114-CI, 091-SB, 201-ALA run without a current permit |
| 5. Inspections (Fred, Nov 22) | Every county document since 2022 that is not a permit (462 on 154 numbers: inspection reports, enforcement notices, correspondence), read in full, comments included (`county3.mjs`; 283 with text, 179 scans read as images by the readers). 66 permits re-judged (the 54 cards + 12 matching permits with a notice or a change of business); every rewritten card checked by a skeptic, every factual correction by a second one. | 11 cards rewritten (below) |

Pass 5 exists because Fred found what passes 1 to 4 missed: the county's **Jul 2, 2025 inspection report** of GDO-014031 says on its
last page *"the facility is no longer operating as Sabores Latinas and they are now operating as Cook unity. Field notice as issued
for new facility."* The card had told the office to drop the permit (our only address for 105-CU is in Hialeah). It is Cook Unity's
own spot at 955 Alton Rd, unit K-26, Miami Beach; the card now asks where we pump.

## 3. What the 54 cards say (after pass 5)

| group | permits | what it means |
|---|---|---|
| Another business's permit | 5 | 062-TCE (its own: **GDO-011423**, unit K1993, valid 2026), 221-YAS, 244-URI, 176-SOU, 213-TRUE |
| The county issued it to someone else | 1 | 206-CAC |
| Food truck on the host's permit | 3 | 214-MYK, 209-TRUE (Truluck's GDO-008422), 212-TRUE (the hotel's GDO-007147) |
| Right number, wrong file | 9 | #236's wrong files, plus the cards the inspections moved here |
| No file stored | 11 | |
| Another name, same address | 16 | the permit goes with the spot; several need the unit or the business confirmed |
| No 2026 permit at the county | 9 | |
| Matching, nothing to do | 88 | |

Rewritten by pass 5: 001-VIN (the county's own plans: "7105 Collins Ave aka 7135 Collins #10", one storefront), 105-CU, 171-CAF (two
kitchens, two traps), 176-SOU, 201-ALA (new operator, failed inspection Oct 28, 2026), 114-CI (new trap approved Nov 2024), 203-GF,
206-CAC, 210-KAY, 221-YAS, 036-LG (open county case for running without a permit).

None of the four permits the check proposes to ADD (GDO-011423, -013034, -009698, -014927) is on any `gdos` row, inactive included.

## 4. Rules learned (apply them to the next permit check)

1. **The unit decides, not the address.** In a mall, plaza, hotel or food hall the facility location's unit must match the client's.
2. **A different name at the same address and unit is usually the earlier business, and the permit stays** (the 2026-06-28 rule).
   It is wrong only when another CURRENT business holds it (other unit, other building).
3. **Read the county's inspection reports and notices, all of them, comments in full, and look at scans as images.** They name the
   business operating there today (`Facility (Current)` / `Facility (New)`, `Field Notice Type`, `Inspector Comments`). Reading only
   the permits called live enforcement cases "dead" and told the office to drop Cook Unity's own permit.
4. **Compare our file's name with the county's NEWEST permit for the same number**: the county can give a number to another business
   (GDO-009070, Jun 17, 2026).
5. The county's search keys a case as `GDO-` + **5** digits (`GDO-09394`) although the permit prints 6; the unit is `unitNumber`; its
   list names (`facilityName`) are often an earlier tenant. Its newer files are served as `application/octet-stream` (they download
   instead of opening) and it sends no cross-site headers, so a page cannot fetch them.

## 5. State and what is left

- **Nothing changed in the database.** Fred (Nov 22): the page is for **Yannick or Diego**, not him. Each card asks one question they
  can answer (for example "Where do we pump Cook Unity's grease trap?"), with answer buttons; "Copy the answers" makes the instruction
  an AI applies: claim the rows, back them up, never delete (a wrong permit becomes INACTIVE with a dated note), add permits with the
  county's PDF through `client.upsert_gdo_permit` or the Client App, re-check each row first, check each client in the Client App
  after, run `scripts/checks/gdo_permit_pdf_numbers.mjs`, message no client. An unanswered card means "change nothing".
- **Open:** the answers; the tenant check in the standing check `scripts/checks/gdo_permit_pdf_numbers.mjs` (the card's item 5, not
  built); card #236's eight wrong files are among the "wrong file" cards; Jobber address and name fixes the answers flag go to Fred.
- **Where the work is:** local only, because it holds client documents: `mockups/2026-11-21-240-gdo-check/` at the workspace root
  (`build.mjs` + `answers.mjs` + `page.js` build the page `mockups/2026-11-21-240-gdo-permit-fixes.html`; `county.mjs`, `county2.mjs`,
  `county3.mjs`, `embed.py` read the county; `test.mjs` 37 browser checks; `data/` holds the readings, the reviews and the overrides).
