# Multi-GDO permit cards in the DERM Stamp Studio

*Design spec, 2026-08-27. Written after ticket-312433 was found marked complete by AI with all eight
stamps on the wrong scan, and Casa Neos holding one card against three printed rows.*

---

## The problem

A generated DERM address sheet prints **one row per ACTIVE GDO permit**, not one row per client.
`derm.address_row_map` holds **one card per client per folder**. For a client with several permits
those two disagree, and the gap is invisible.

Live example, sheet 1102 / `ticket-312433`, generated 2026-08-27:

| printed row | client | permit | nickname |
|---|---|---|---|
| 7 | 009-CN | GDO-10877 | Kitchen |
| 8 | 009-CN | GDO-15062 | Bar |
| 9 | 009-CN | GDO-16389 | Lounge |

The folder held **one** card for 009-CN, with `gdo_id` NULL. Rows 8 and 9 were **printed but
unowned**, which is the exact shape that made `ticket-310590` p2 a real cross-client leak on
2026-08-19: no card means no band, and a neighbour's derived band can stretch across the row.

Today the only way to create the missing cards is a hand-written migration. That is how 043-MIL and
009-CN were both repaired, and it does not scale to the next sheet.

---

## Decisions (Fred, 2026-08-27)

| # | Question | Decision |
|---|---|---|
| 1 | When are the extra cards created? | **Automatically, at link time** |
| 2 | Auto-created cards need a stamp or the folder freezes, but auto-placing is what broke 312433 | **Place only when the page mapping is verified**; otherwise create unstamped and let the OCR land |
| 3 | Backfill existing under-carded clients? | **No.** Forward-only |

> **Fred on the backfill:** *"former manifests didn't show the multiple GDO per client, but from now
> on they do."*

---

## Rule 1: expand on the FROZEN `rows_printed`, never on today's permit count

`derm.address_sheet_clients.rows_printed` is written when the sheet is generated and is deliberately
immutable. A printed sheet is a historical artefact; `public.gdos` is mutable.

Measured 2026-08-27 over all **216** sheet-client rows (sheets 1064 to 1102, generated 2026-07-28 to
2026-08-27):

| | |
|---|---|
| rows where frozen `rows_printed` differs from today's active permit count | **77** |
| of those, `frozen > now` | **77** |
| of those, `frozen < now` | **0** |
| rows with `rows_printed > 1` | 8 |

🛑 **Every one of the 77 is `frozen = 1, now = 0`: a client holding no ACTIVE well-formed permit
today.** The generator renders `greatest(1, permit_count)`, so such a client still gets one printed
row, and a client with zero permits is a legal state (the form carries "Facility Name *(if no GDO#)*"
for exactly this). **Re-deriving from today's permits would therefore emit ZERO rows for 77
sheet-client pairs and drop a printed row entirely.** That is a far more common failure than the
tenant-reattribution case, and it is live on more than a third of the table right now.

`frozen < now` at **0 of 216** is the other half: nothing in the estate would gain a card from
re-deriving, so keying on the frozen value costs nothing today and protects every sheet from here on.

Keying on the frozen value also gives the forward-only behaviour **for free, with no cutoff date**:

- a handwritten pad sheet has **no `address_sheet_clients` row**, so it expands to one card, which is
  correct because the writer used one row per client;
- `address_sheet_clients` spans only sheets 1064 to 1102, one month of generated sheets, and **every
  one of them is new-style**. There is no old-style generated sheet to protect against.

---

## Rule 2: a generated sheet is SHARED, so its roster is not the folder's roster

`owed` must be scoped to clients that **already hold at least one card in the folder**. A card is per
`(dump_folder, client, manifest)`, and the function cannot invent a manifest link.

Measured on sheet 1093 / `ticket-833395`:

| slot | client | rows printed | cards in `ticket-833395` |
|---|---|---|---|
| 1 | 242-WYN | 3 | 1 |
| 2 | 069-TCE | 1 | 1 |
| 3 | 032-LG | 1 | 1 |
| 4 to 8 | 026-HAP, 249-LOU, 077-TCE, 199-STK, 226-JER | 1 each | **0** |

Eight clients and ten printed rows, of which **only three clients have a manifest in this folder**.
An unscoped `owed` credits the folder with the whole roster and reports five phantom gaps.

⚠ **This is what a first version of the detector did, and it turned a 1-row worklist into a 7-row
one**, five of them permanent noise. On a worklist whose entire value is "empty means healthy", that
is the failure mode CLAUDE.md already records for `sync_log`.

✅ Measured: **0 folders bind to more than one sheet**, so the `owed` lookup is unambiguous.

---

## Rule 3: the gate can freeze a folder, and that is the safe direction

An unstamped card trips `fn_blackout_targets`' whole-folder closed-world gate, so creating one stops
**every** client in that folder from regenerating, not just the client being expanded. If a scan is
permanently unreadable, the gate never passes and the freeze is permanent.

Measured 2026-08-27:

| | |
|---|---|
| ticket-folders whose page mapping would pass the gate | **35 of 39** |
| would fail | 4: `ticket-308684`, `ticket-311045`, `ticket-828604`, `ticket-830574` |
| folders holding a client with `rows_printed > 1` | 3: `ticket-312433`, `ticket-832194`, `ticket-833395` |
| **overlap between the two sets** | **0** |

So the freeze is **unreachable today** and reachable on a future sheet that pairs a multi-permit
client with an unreadable scan.

**We accept the freeze.** The alternative is to withhold the card until the gate passes, which leaves
the client's extra rows **printed but unowned**, and that is the leak shape from 2026-08-19. Between
"stop regenerating, visibly" and "keep publishing a page with an unowned printed row", the first is
the fail-safe direction.

⚠ Two honest qualifications, so nobody over-reads this:

- Freezing does **not** withdraw already-published documents (`derm.redacted_manifest_docs` is read
  directly by `customer.work_orders` and nothing garbage-collects it). Creating the card neither
  fixes nor worsens an existing leak; it stops the folder from publishing anything new until a person
  resolves it.
- It is **already visible**: `derm.v_blackout_blocked_sheets` grew a `frozen_closed_world` arm in
  `2026-08-27_0356` precisely for this state, so a frozen folder lands on the existing worklist and
  the daily escalation mail with no new wiring.

---

## Components

### 1. `derm.fn_ensure_permit_cards(p_dump_folder text) RETURNS integer`

The single place that knows both rules. Idempotent. Returns the number of cards created.

For each `(folder, client)` **that already holds at least one card** on a folder whose manifests bind
to a generated sheet:

1. `owed` := `address_sheet_clients.rows_printed` for that client on that sheet.
2. `held` := count of `address_row_map` cards for that `(folder, client)`.
3. If `owed > held`, create `owed - held` cards.
4. Bind `gdo_id` on all of the client's cards in **`gdo_number` ascending** order, so card N is
   printed row N.

**Why `gdo_number` and not `gdos.id`:** `pdf_service/app.py` line 142 sorts with
`valid.sort(key=lambda g: g["gdo_number"])`, a plain string sort over the whole `GDO-NNNNN` token.
Measured: all **134** active well-formed permits are exactly 9 characters, five digits zero-padded,
so string order is numeric order. And `gdos.id` order **disagrees for 3 of the 4** multi-permit
clients:

| client | by `gdo_number` (printed order) | by `gdos.id` |
|---|---|---|
| 009-CN | 10877, 15062, 16389 | 10877, 15062, 16389 (agrees) |
| 043-MIL | 11024, 14117 | **14117, 11024** |
| 148-MOR | 11226, 14769 | **14769, 11226** |
| 242-WYN | 13814, 14760, 16146 | **13814, 16146, 14760** |

009-CN is the one that coincides, which is why `add_extra_client_card`'s original `ORDER BY g.id`
looked correct in its single production use. Match the generator, not an abstraction of it.

**Invariants:**

- `page` is copied from the client's existing card and **never set to the printed page**.
  `derm.ticket_page_images` builds its array from `address_row_map.page`, so a card claiming page 2
  appends a duplicate entry and silently re-points every later `stamp_page` ordinal at a different
  scan. That is the `ticket-833049` defect, and it was hit again while adding 043-MIL's second card
  earlier today. Only `stamp_page` varies.
- Generated sheets only. A pad sheet expands to nothing, by construction.
- Never removes or renumbers an existing card.

### 2. The placement gate: `derm.fn_sheet_page_mapping_verified(p_dump_folder text) RETURNS boolean`

True only when **every image** in `derm.ticket_page_images` has a `high` confidence row in
`derm.address_sheet_scan_reads`. That is the difference between
`derm.fn_sheet_image_position(p_dump_folder, p_logical_page)` answering from evidence and silently
falling back to the identity mapping.

`fn_ensure_permit_cards` places a new card **only if this returns true**, using
`derm.fn_generated_row_geometry(p_row_index)` and `fn_sheet_image_position`. Otherwise the card is
created **unstamped**.

🛑 **This gate is the whole lesson of 312433.** That folder was auto-placed and auto-completed with
**zero** scan reads, so the mapping was a guess, the two scans were stored in reverse order, and all
eight stamps landed on the opposite page while the sheet reported itself finished.

### 3. The catch-up trigger

An unstamped card blocks the folder (`fn_blackout_targets`' whole-folder closed-world gate), so
something must place it when the scan arrives.

`ocr-address-sheet-number` already writes `derm.address_sheet_scan_reads`. An `AFTER INSERT` trigger
there calls `fn_ensure_permit_cards` for that folder, which now passes the gate and places the
pending cards. No new cron, and the window is one sweep cycle.

### 4. The call site

`derm.fn_card_from_link` / `trg_zz_card_from_link` already materialises the first card when a
manifest is linked. `fn_ensure_permit_cards` is called for the folder immediately after.

### 5. `derm.v_undercarded_clients`

A detector in the same family as `derm.v_blackout_blocked_sheets`: **empty means healthy**. One row
per `(folder, client)` holding a card where `rows_printed > cards`, with `serving` and `measured`
flags so a live case is distinguishable from an idle one.

Without it this recurs silently, which is exactly how both 312433 and 833813 happened: the instance
was repaired, the lesson was written into CLAUDE.md, and nothing watched for the next one.

**Fleet today: 1 row.** `ticket-833395` / 242-WYN, 1 card against 3 printed rows, SERVING.
Deliberately **not** backfilled per decision 3, so the detector starts non-empty by design and that
single row is the documented exception. Every other folder in the estate is fully carded.

---

## What this does NOT do

- **No backfill.** 242-WYN on `ticket-833395` keeps its one card and its one wide band
  (24.309..47.445), which already reveals all three of its own facilities, so that client is missing
  nothing today.
- **No detector for a printed-but-unrowed client.** A client printed on a sheet who holds **no** card
  in any folder is a different and more dangerous shape: `ticket-310590` p2 / 165-LPB is the known
  instance, and it caused a real cross-client leak on 2026-08-19. It is inert today only because the
  bands around it were snapped in `2026-08-19_2355`. CLAUDE.md lists three further sightings found by
  eye (`window4-sheet1` p2, `window10-sheet4` p2, `window3-sheet5` p2). This spec does not address
  it, and folding it into `v_undercarded_clients` would break rule 2's scoping.
- **No pad-sheet support.** One printed row per client there, and the writer's layout is not
  derivable from permits.
- **No change to the FP blackout.** A client with N cards already serves the union of their bands
  (`2026-08-27_1610`), so the customer-facing side is finished.
- **No Studio UI work.** Cards appear on their own; the operator sees N rectangles with N nickname
  badges, which already renders.

---

## Testing

1. **Unit, rolled back:** a 3-permit client on a verified folder gets 3 cards, bound in
   `gdo_number` order, stamped on ascending rows of the correct image.
2. **Gate:** the same folder with its scan reads removed creates the cards **unstamped** and places
   nothing.
3. **Catch-up:** inserting the scan reads then re-running places them.
4. **Idempotence:** running twice creates nothing the second time.
5. **Pad sheet:** a `window<N>-sheet<M>` folder creates nothing.
6. **Frozen-value control:** a client with zero active permits on a sheet that printed one row still
   expands to 1, not to 0. This is the 77-row case and the single most likely regression.
7. **Shared-sheet control:** `ticket-833395` creates cards for 242-WYN only, and nothing for the five
   clients printed on sheet 1093 whose manifests are in other folders.
8. **Freeze is visible:** a folder left with an unstamped card appears in
   `derm.v_blackout_blocked_sheets` as `frozen_closed_world`. A freeze that nothing reports is the
   one outcome this design must not produce.
9. **Image array:** `ticket_page_images` is byte-identical before and after.
10. **Against the paper:** every new stamp sits on the image whose `address_sheet_row_reads` names
   that client. This is the assertion the original defect would have failed.
11. **Fleet regression:** 0 transpositions across all placed cards on OCR-read folders.
12. **Visual:** both scans rendered with stamps overlaid, and the Studio opened on the folder.

Tests 10 and 11 are the ones that matter: they compare against the scanned paper rather than against
our own arithmetic, which was correct throughout the 312433 failure.

---

## Open, not part of this

- `derm.add_extra_client_card(p_dump_folder, p_client_id, p_page)` stays as the manual escape hatch.
  It now binds in `gdo_number` order and fails closed when it cannot resolve a permit
  (`2026-08-27_1650`), but it still creates an **unstamped** card, which transiently blocks the
  folder. Folding it into `fn_ensure_permit_cards` is the natural follow-up.
- The duplicate-folder pairs (`derm/1246` + `ticket-828604`, `ticket-820714` + `ticket-830714`) are
  unrelated and unsettled.
