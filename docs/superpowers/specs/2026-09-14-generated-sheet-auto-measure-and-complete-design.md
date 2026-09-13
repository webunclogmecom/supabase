# Generated sheets finish themselves: measure from the scan, guided by the layout we printed

*Design, 2026-09-14. Not built. Fred: "go, write the design first."*

## 1. The problem, stated as it actually is

Two rules Fred set are both correct and cannot both hold today.

- **"Generated sheets are automatic."** A DERM address sheet we printed ourselves (sheet number
  1000 and up) is AI-stamped at filing (`derm.trg_autoplace_generated`) and the resolver's
  auto-complete leg marks it complete once every card is placed and renderable
  (`fn_resolve_generated_sheet_for_ticket`, 2026-08-24).
- **"Complete means it will be blacked out."** (2026-09-03) Completion is gated on
  `derm.fn_sheet_publishable`, which requires every band to be on the printed lines and every
  stamped page to have an extent. The gate is a BEFORE trigger on `stamp_sheet_status`
  (`trg_a0_completion_requires_geometry`) that turns the automatic completion into a no-op.

A generated sheet's bands are the generator's **template** (`derm.v_stamp_row_bands.derived_*`,
the amber "estimated" lines in the Studio), and the template is deliberately not accepted as a
measurement: each page is a separate photograph and the same printed form lands 0.3 to 2pp away
from the template on different scans (833813: 25.880 vs 23.848 for the same line). Since
2026-08-19 an extent must never open the publish gate onto template bands. So every generated
sheet now stops at "Cannot complete yet" and waits for a person to open Draw the bands on each
page and save. **Nothing measures a generated sheet automatically, and that is the whole gap.**

What Fred sees is therefore not a fault in either rule. It is the absence of the one step that
would let both hold: an automatic measurement that is as trustworthy as a person's.

### 1a. A correction to something I said on 2026-09-13

The migration `2026-09-13_1200` and my message to Fred claimed the `stamp-studio-ai` label "keeps
the resolver's anti-AI auto-complete clause in force". Read off the live resolver body, **there is
no such clause**. The auto-complete leg completes any folder with no unplaced card, every placed
stamp inside the image list, and `reopened_at` null, whatever placed the stamps. The only thing
holding an AI-stamped generated sheet back is the geometry gate. The label choice stands (the
coordinates came from the AI chain), the justification I gave for it was wrong.

## 2. Measured starting state (2026-09-14)

- **20 generated folders.** 19 completed and serving, all measured by a person in the Studio or by
  a reviewed migration. 33 pages, 33 with an admitted OK scan. The 20th, `ticket-835076`, was
  measured by `2026-09-14_0030` and is publishable, awaiting Fred's click.
- **The 835076 case, which is the shape every new generated sheet will take:**

  | | page 1 | page 2 |
  |---|---|---|
  | AI stamps at filing | 5 of 5 | 0 of 5 (the page-2 sheet-number read landed 0.75 s after the placement pass; refused correctly) |
  | Studio detector | OK, 6 boundaries | **FAILED**, "7 boundaries" |
  | why page 2 failed | | the bottom line of slot 5 is printed half-width in that photo, run 0.507 against 0.99; the validator's phase check reads a half-width "boundary" as a phase flip |
  | detected vs template, per boundary | 0.33 / 0.63 / 0.01 / 0.12 / 0.13 / 0.36 | 0.34 / 0.08 / 0.53 / 0.34 / 0.29 / 0.73 |
  | slot gaps, page 1 vs page 2 | 8.22 / 6.70 / 7.18 / 7.79 / 7.74 | 8.33 / 6.73 / 7.24 / 7.83 / 7.79 |
  | stamps inside their slots | 5 of 5 | 5 of 5 |

  The detection was right on both pages. The **classifier** failed on page 2 because it has no
  idea what the page should look like. We do: we printed it.

- **The template, per printed row of a generated page** (`derm.fn_generated_row_geometry`, and
  the derived band edges): boundaries at 25.84 / 33.76 / 41.10 / 48.15 / 55.93 / 64.16, stamps at
  29.80 / 37.72 / 44.48 / 51.81 / 60.04. Identical on every generated page by construction.

## 3. The principle: the layout is a PRIOR, the scan is the MEASUREMENT

Two things the estate already knows, and this design sits between them:

- **Never template a generated sheet's geometry** (CLAUDE.md, 2026-08-27): the absolute
  positions move ~2pp between photographs. True, and this design never writes a template value.
- **Blind detection needs a classifier**, and the classifier is the weak part: the alternation
  model fails on a half-width line, a missed divider, a header bar, a six-slot form.

For a generated sheet the classifier is unnecessary. We know there are exactly N printed rows on
the page, where each boundary should be to within ~2pp, and that every stamp we placed sits on its
own row. So:

> **Take the detector's raw lines. For each boundary the layout says exists, accept the detected
> line nearest to where the layout says it is, after correcting for the page's uniform shift, if
> it is close enough, whatever its width. Require every boundary to be found, the slot pattern to
> match the layout, and every stamp to sit inside its slot. Then the six lines ARE the
> measurement, and they are on the paper.**

That is what `2026-09-14_0030` did by hand for 835076 page 2, and it is what a person does with
their eyes in Draw the bands on a generated sheet: they are not discovering the layout, they are
confirming it on this photograph.

## 4. The pipeline: the generated-sheet finisher

Runs every 10 minutes (pg_cron, same shape as `sheet-row-ocr-sweep`) and makes no HTTP call when
there is nothing to do. Three steps, each independently gated, each leaving a plain-language
reason when it stops.

```
filing (derm-link)  ->  cards + insert-time AI placement          (exists)
     -> sheet-number OCR, trigger + sweep -> page map              (exists)
     -> row OCR sweep -> row reads                                 (exists)
     -> FINISHER, per generated folder that is not completed and not reopened:
          A. place the cards still awaiting their page map         (new, see 4.A)
          B. measure every stamped page that has no admitted geometry
               B1 detector on the scan (edge function)             (new)
               B2 layout-guided matching + validation (SQL)        (new)
               B3 record_page_rules + save_page_geometry           (exist)
          C. complete, through the resolver's own write            (exists, re-invoked)
     -> trg_zz_publish_on_complete -> blackout sweep               (exists)
```

### 4.A Place the cards still awaiting their page map

`derm.v_cards_awaiting_page_map` lists cards whose printed page's image was unknown at insert
time (the 835076 race, 5 cards; the 834742 case, 9 minutes). Step A re-runs the insert trigger's
own chain for those cards, with **one gate the trigger does not have**: the page's **row reads must
exist and confirm the client on that row** (`fn_row_read_confirms(...) IS TRUE`, not merely
`IS NOT FALSE`). This reverses the 2026-09-03 decision not to re-place unattended, and the reason
that decision existed no longer applies to this path: it was taken when placement could fall back
to an identity page map with no read at all; here the map comes from a high-confidence suffixed
read and the row OCR has to name the client. A card that fails the gate stays unplaced, visibly,
in the same view.

### 4.B Measure a page

**B1, the detector.** A new edge function `measure-generated-page` takes `{dump_folder, page}`,
resolves the image through `derm.ticket_page_images`, decodes it and runs the run-length detector.
The code is the Node port at `scripts/probes/rev/detect_node.js` (itself transcribed, not
retyped, from the validated browser detector; `jpeg-js` is available to Deno as `npm:jpeg-js`).
It returns the raw lines `{pct, run, ink}` and nothing else: **the edge function classifies
nothing and writes nothing**. Same shape as `ocr-address-sheet-rows`: service-role, one page per
call, an attempts ledger keyed on `(dump_folder, page, image_url)` so a page that cannot be read
is tried three times and then left for a person, and re-armed if the image is replaced.

**B2, the matching, in SQL** (`derm.fn_match_generated_page(dump_folder, page, lines jsonb)`,
pure, returns the six boundaries or a refusal reason):

1. `expected[1..N+1]` = the template boundaries for this page's N printed rows (derived band
   edges of the page's cards, which come from `fn_generated_row_geometry`).
2. `shift` = the median of `(nearest line within 2.5pp of expected[i]) - expected[i]` over the
   expected boundaries that have such a line; refuse unless at least N of the N+1 have one
   ("could not find the printed rows on this scan"). The shift absorbs the photograph's offset
   (0.3 to 2pp measured); dividers sit 3.3 to 4.1pp from the nearest boundary, so after the shift
   they are outside the window below.
3. `found[i]` = the line nearest to `expected[i] + shift` within **0.75pp**, of any width with
   `run >= 0.35`; refuse if any boundary has none ("a printed line between two rows is not visible
   on this scan").
4. `found` strictly ascending; each gap within 0.75pp of the template gap ("the rows on this scan
   are not spaced like the printed sheet").
5. Every stamp on the page strictly inside its slot with at least 0.5pp clearance from both edges
   ("a stamp sits on the line between two rows; place it again").
6. A client holding more than one card on the folder is refused on the whole page ("this client
   is printed on several rows; give it one card per permit first", the 834986 lesson), and a
   client printed on more rows than it holds cards refuses the whole folder in step C.

Every refusal is a plain sentence, written to `derm.generated_measure_attempts` and surfaced by
`fn_sheet_publishable_detail` so the Studio's banner says exactly why the sheet is waiting.

**B3, the writes**, both through RPCs that already exist and already run every guard:

- `derm.record_page_rules(folder, page, 'template-v1-<date>', url, <the N+1 boundaries as kind
  boundary, no dividers>, meta)`. This is byte-for-byte how Draw the bands records lines, and the
  validator treats it as a pure-boundary chain (pitch check, no phase check). `meta` carries the
  shift, the per-boundary residuals and the detector's raw output, so the record can be audited.
- `derm.save_page_geometry(folder, page, <bands: consecutive boundaries>, found[1], found[N+1])`.
  G1..G14 run. A refusal there is a refusal of the page, with the guard's hint as the reason.

`derm.v_page_printed_rules` admits a third source prefix, `template-v1-%`, with precedence
**human-v1 > template-v1 > runlen-v2**: a person's lines always win; the layout-guided set wins
over the blind classifier's on the same page (when the blind scan graded OK the two are the same
lines anyway). `v_band_edge_check` follows the view, as it has since `2026-09-02_0330`.

### 4.C Complete

The same INSERT ... ON CONFLICT the resolver's auto-complete leg performs, in a function of its
own (`derm.fn_complete_generated_sheet(folder)`), with the leg's conditions (no unplaced card,
every stamp inside the image list, `reopened_at` null) plus one: **every client's card count equals
its printed row count on the sheet** (`v_sheet_printed_rows`), so an under-carded multi-permit
client can never complete and publish a neighbour's row. `trg_a0_completion_requires_geometry`
still gates it on `fn_sheet_publishable`, so if anything above left a page unmeasured this is a
no-op with a WARNING, exactly as today. `completed_by = 'stamp-studio-auto'`, distinct from
`'stamp-studio-ai'` (the insert-time placement) and from a person's email, so a completion this
path made is always identifiable.

## 5. What this fixes, concretely

- A new generated sheet whose scans are legible completes and blacks out **with no clicks**:
  filing, seconds for the sheet-number reads, up to 10 min for the row-read sweep, up to 10 min
  for the finisher, then the 5-minute blackout sweep: typically under 30 minutes end to end, worst
  case about 40, and every step is visible.
- The 835076 race (page-N cards left unplaced by a read that lands seconds late) heals on the next
  finisher run instead of waiting for a person to notice.
- The half-width-line failure that made page 2 grade FAILED cannot recur for generated sheets: the
  layout says the line is there, the detector found it, its width is irrelevant.
- A generated sheet the finisher cannot finish says **why**, in the banner, in plain words, and
  stays exactly where it is for a person. Nothing is guessed.

## 6. What must not break

- **No template value is ever written.** Every band edge and both extents are detected lines on
  THIS scan. The template only chooses which detected lines are the boundaries. VERIFY on the
  corpus below asserts every written value equals a detector output.
- **Human lines always win** (`human-v1-` outranks `template-v1-`), and the finisher never touches
  a page that already has admitted geometry of any source, never a completed sheet, never a
  reopened one (`reopened_at`, the pin that already protects the resolver's leg).
- **Handwritten sheets are untouched.** The finisher's backlog view is `is_generated` only. A pad
  sheet has no layout to use as a prior and keeps the Draw the bands path.
- **The 2026-08-19 rule** (an extent opens the gate onto whatever bands exist) is why step B writes
  bands and extent in one `save_page_geometry` call per page, never the extent alone, and why it
  writes nothing at all on any refusal.
- **The closed-world gate and the multi-card rule** stay: an unplaced card, or a client with fewer
  cards than printed rows, means no completion, with the reason shown.
- **The existing screens keep watching.** Every finisher-written band lands in `v_band_edge_check`
  and `v_band_edges_off_rule` like any other; the finisher adds a fourth blocker view, not a
  replacement for the three that exist.

## 7. Staging

**Phase 0, before anything writes: the corpus.** The 19 completed generated folders hold 31 pages
whose geometry a person accepted and whose documents were opened by eye. Run the detector on each
scan offline, apply the matcher, and compare its six boundaries to the accepted bands and extent.
Acceptance: on every page the matcher either produces boundaries within 0.35pp of the accepted
ones, or refuses with a reason that a person agrees with. A matcher that silently produces a
different tiling on an accepted page does not ship. This is the positive control for the algorithm
and the calibration of the 2.5 / 0.75 / 0.5pp tolerances above, which are measured on two pages so
far and are not yet a spec.

**Phase 1, measure only.** Ship B (edge function, matcher, backlog view, attempts ledger, the
`template-v1-` source) and the plain-language reasons. Completion stays the operator's click. This
runs on every new generated sheet for at least ten sheets while Fred compares what the finisher
wrote with what he would have drawn.

**Phase 2, complete.** Ship C behind a config key (`public.app_config` `generated_sheet_auto_complete`,
default `false`, the same on/off shape as `city_email_start_from`). Flip it when Phase 1 has
produced no geometry Fred would have drawn differently.

**Phase 3, re-place awaiting cards.** Ship A, with the row-read requirement, after Phase 2 has run
clean, because it is the one step that reverses a recorded decision.

## 8. Open questions for Fred

1. **Auto-complete from day one, or Phase 1 first?** My recommendation is Phase 1 first: the cost
   is one click per generated sheet for a couple of weeks, the benefit is that the first ten
   automatic measurements are seen by a person before any of them publishes unattended.
2. **Step A (re-placing cards after a late read) reverses the 2026-09-03 decision.** With the
   row-read requirement I think it is safe; say if you want it left out.
3. **Tolerances.** 2.5pp search window, 0.75pp match window, 0.75pp gap tolerance, 0.5pp stamp
   clearance are from two pages. Phase 0 will either confirm them or move them; you will see the
   numbers before they are pinned.
4. **`completed_by = 'stamp-studio-auto'`** so a finisher completion is distinguishable from the
   insert-time AI placement and from a person. Fine, or keep everything machine-made under
   `'stamp-studio-ai'`?
