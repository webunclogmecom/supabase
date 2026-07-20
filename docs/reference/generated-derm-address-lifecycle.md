# Generated DERM Address sheet — full lifecycle (the physical roundtrip)

*Canonical reference, written 2026-07-20 from Fred's description. This flow was previously
undocumented anywhere, and its absence caused a wrong design assumption the same day (see
"History of the wrong assumption" at the bottom). Cross-referenced from the Stamp Studio docs and
the pdf-service CLAUDE.md. If the flow changes, change THIS file and the pointers.*

## The flow, in Fred's words (2026-07-20)

> "We generate a DERM address manifest for the truck drivers, we print that in physical paper, hand
> it to the drivers, so when they go to the dump they can just deliver it to the city, they will
> read it, fill the empty fields on the bottom part of the manifest, and then stamp it and the
> Driver take a picture/scan it and uploads it to Jobber on the visit of the clients 000 (depending
> on which dump he went to). So at the end we just get an image of the DERM Address Manifest not the
> generated PDF, so we need to do the blackout logic afterwards for the FP App."

## The two phases of a generated sheet

A generated sheet is only **born** digital. It then goes into the physical world and comes back as
a **photo** — at which point it is, for every downstream purpose, the same thing as a handwritten
pad sheet: a photo of a multi-client compliance document.

### Phase 1 — born-digital (before the dump run)

1. **Generate.** `generate-derm-address-pdf` edge fn → pdf-service `/generate/derm-address` renders
   the official form: one Section B row per ACTIVE well-formed permit, siblings by manifest id,
   5 rows per page with overflow pages, OUR sheet number (from `derm_address_seq`, 1000+) stamped
   top-right (`{n}-1`, `{n}-2` on multi-page). The PDF goes to storage
   (`derm/sheets/{n}/address_{utc}.pdf`, versioned) and provenance is recorded in
   `derm.address_sheets` + `derm.address_sheet_manifests` (by immutable manifest id).
2. **Print + hand to the driver.** The paper IS the working document from here on.
3. In this phase: `derm_manifests.derm_address_url` is **NULL** (no photo exists),
   `derm.ticket_page_images()` returns **0 pages**, so the Stamp Studio shows the sheet with its
   cards but no image — **that is correct, not a gap**: there is nothing to look at yet.
   The blackout pipeline correctly ignores it (nothing to redact).
4. Stamp cards materialize as visits get linked; each card **auto-stamps** at the sheet's exact
   printed slot (`trg_ab_autoplace_generated` → `fn_generated_sheet_slot` → template geometry) and
   the sheet auto-completes (`stamp-studio-ai`).

### The physical middle (outside our systems)

5. Driver takes the paper to the dump and hands it to the county.
6. The county reads it, **fills the bottom sections** (transporter/disposal certifications, ticket
   number, date, gallons, signatures) and **stamps it**. The paper is now the real, county-annotated
   compliance document.

### Phase 2 — the return (after the dump)

7. **Driver photographs/scans the completed paper and uploads it to Jobber on the 000 dump-client
   visit** (000-prefixed clients are the dumps; which one depends on where he went — same visits the
   DUMP Schedule QR app creates).
8. **The office files the photo onto the ticket's manifests** (DERM Tracker, exactly like a
   handwritten sheet today): the photo lands in `derm_address_url` (+`derm_address_extra_urls` for
   multi-page). ⚠ Multi-page: file the pages in PRINT order (`{n}-1` first) — `stamp_page` is a
   positional index into `ticket_page_images()`.
9. From this moment the sheet behaves like every handwritten sheet:
   - `ticket_page_images()` returns the photo(s) → the Studio **now shows the image**, with the
     AI-placed stamps already on it. The office can visually verify and drag-correct — this is the
     manual-correction requirement, and it needs **no new rendering surface**; the image arrives
     with the return.
   - The blackout eligibility gate (`fn_blackout_targets`, re-keyed 2026-07-20f to **"has an
     uploaded photo to redact"**) now includes the sheet. The remaining fail-closed gates apply
     unchanged: fully-banded + **measured extent required** (`derm.page_block_extents`).
10. **Measurement pass** on the returned photo (same vision pass as handwritten sheets; returned
    generated sheets surface in the standing stamped-but-unmeasured check). Then the sweep
    generates each client's **redacted copy of the photo** → `customer.work_orders.derm_manifest_url`
    → the Field Portal. That redacted photo — not the born-digital PDF — is the customer document.

## Why each piece exists (so nobody "simplifies" it away)

| Piece | Why |
|---|---|
| Auto-stamps at template geometry (phase 1) | They are PRE-POSITIONS for the returned photo. A well-framed scan of the printed page has ~the same proportions as the PDF (verified: measured extents of real sheet photos, ~25.5-63%, match the template's Section B region), so the stamps land on or near the right rows of the photo with zero human work; the office only nudges outliers. They are NOT mere bookkeeping. |
| `fn_generated_sheet_slot` (20j) | The stamp must be on the client's OWN printed row, because post-return those stamps seed the redaction bands. The multi-GDO test proved link-order indexing puts one client's code on another's row. |
| Blackout gate = "has a photo" not "is generated" (20f) | A blanket is-generated exclusion would have permanently blocked phase 2: returned sheets would never redact and their FP clients would never get documents. The photo-existence gate makes eligibility flip automatically at the return. |
| Extent hard gate stays | The photo's framing is the driver's/scanner's, not the PDF's. The measured extent is per-photo truth; template numbers must never substitute for it. |
| Regeneration allowed only until the photo returns | Gate 1 of `record_generated_address_sheet` refuses any ticket carrying a photo. Pre-return, reprint/regenerate freely (lost paper, client added). Post-return the physical sheet is filed with the county — never reprint under that number. |
| Sheet number identity (`derm_address_seq`, never reset) | The number is printed on paper that leaves the building. A gap is cosmetic; a duplicate number on two physical sheets is a county-audit problem. |

## What the office types when filing the return

OBSERVED PRACTICE (2026-07-20, from real preview-era returns 1009/1010): the office files the
return under the DISPOSAL facility's ticket number (the handwritten "Ticket No." — e.g. 829201),
not our printed sheet number. That is fine: provenance is keyed by manifest id, so renumbering the
ticket to the disposal number cannot un-generate the sheet. TWO RULES that make it keep working:
1. RE-USE the generated manifests when filing (attach the photo / renumber the ticket on the rows
   created at generation) — do NOT file fresh duplicate manifests, which would carry no provenance
   and make the sheet read as handwritten.
2. Prefer filing pages in PRINT order ({n}-1 first). The system tolerated a reversed filing
   (829322's photos are stored -2 first; stamp_page is positional so everything stayed
   consistent), but print order keeps the Studio's page tabs intuitive.

## Open items (Fred to green-light; none block the flow)

1. **Review-on-return tripwire (recommended):** when a photo lands on a generated sheet's manifest,
   flag the sheet for a quick visual check (or un-complete it) so the office confirms the AI stamps
   sit on the right rows of the actual photo before it becomes redaction input. Today this is
   caught indirectly by the stamped-but-unmeasured check (the measurement pass is a human moment
   anyway); an explicit flag would make it deliberate.
2. **Jobber 000-visit photo automation (later):** the driver's upload lands on the Jobber dump
   visit; filing it onto the manifests is manual (DERM Tracker). Auto-suggesting "this dump-visit
   photo looks like sheet 1030's return" is possible once real volume exists.
3. **First real return = the acceptance test.** Phase 1 is fully E2E-tested (sheets 1027/1028/1029,
   2026-07-20). Phase 2's chain (photo → pages → bands from AI stamps → measure → redact → FP) is
   the exact handwritten pipeline, live for 527 documents, but the first REAL returned generated
   sheet should be walked end to end before trusting it at volume.

## History of the wrong assumption (kept so it is not re-made)

Migration 2026-07-20d shipped with the rationale "generated sheets' customer copy is the
born-redacted FOG PDF; stamps are bookkeeping, not redaction inputs" — and later the same day the
page-overflow test report called the missing Studio image "a gap" and recommended rasterising the
PDF into page images. **Both were wrong**, because the physical roundtrip was undocumented: the
customer copy is the redacted RETURNED PHOTO, the stamps are its band seeds, and the image
"arrives" by itself in phase 2 — no rasteriser needed. The 20f blackout re-key, argued at the time
purely from the dead-column evidence, turned out to be exactly what the real flow requires.
