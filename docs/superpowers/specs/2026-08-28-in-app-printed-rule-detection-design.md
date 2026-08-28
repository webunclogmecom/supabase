# In-app printed-rule detection for the DERM Stamp Studio

*Design spec, 2026-08-28. Written after Fred dragged a rectangle on `ticket-312433` and got ten
`G9_OFF_RULE` errors reading "nearest no rules for this page", with no way forward inside the app.*

---

## The problem

`derm.save_page_geometry` refuses a band edge that does not sit on a **printed rule detected on the
scan**. That guard is correct and it is the control that stops a repeat of the 2026-08-19 leak, where
derived bands were published and clients were served redactions showing a neighbour's GDO number and
street address.

But nothing in the product ever produces the data the guard needs. Every `page_row_rules` row in
history was written by a developer running `scripts/probes/derm_band_review/detect.js` in a
Playwright browser, piping the result through `classify.js`, and hand-authoring a migration.

**Fred, verbatim:** *"I don't want to be needing you to do that, it's supposed to be something done
by the app, what about an office member like diego working on it, he doesn't have you to work for
him."*

That is the whole defect. Diego opens a new sheet, drags a rectangle, hits a wall of red, and there
is no button anywhere in the app that fixes it.

---

## Scale, measured 2026-08-28

| | |
|---|---|
| pages carrying stamps | 174 |
| have detected rules | 168 |
| **blocked (no rules)** | **6** |
| of those, currently serving a client | **0** |

The six are `ticket-312024` p1/p2, `ticket-312433` p1/p2 and `ticket-833049` p1/p2 (the last is
frozen by a CHECK constraint for the duplicate-image defect and is out of scope).

🛑 **The backlog is not the point. The RATE is.** Every newly generated sheet arrives in this state,
and Diego files manifests daily. Four pages today is one or two more per sheet, forever, each one
requiring a developer.

---

## Feasibility: this needs no new infrastructure

I expected to be specifying an edge function plus a cron sweep. It does not need either.

`detect.js` is **pure canvas pixel arithmetic with no AI call and no server dependency**. It loads
the image with `crossOrigin = 'anonymous'`, draws it to a `<canvas>`, reads `getImageData`, and
scores each scanline by its longest contiguous run of dark pixels. Printed lines fall out of a
sharply bimodal distribution: run ~1.0 is a full-width slot boundary, ~0.41 is a mid-slot divider
that stops at the first vertical column line.

The Stamp Studio already has every piece:

- it loads that exact image with `crossOrigin="anonymous"`, so the canvas will not taint;
- it already uses canvas and `toBlob` for the PNG export;
- the image is already decoded and on screen at the moment detection is wanted.

### Proven, not assumed

The extracted algorithm was run in Chrome against live storage URLs on 2026-08-28.

**Positive control, `ticket-832194` p1**, which already carries 11 rules from
`runlen-v2-2026-08-21`: **9 of 11 reproduced to 0.000pp** (24.486, 33.109, 36.669, 40.071, 43.434,
47.587, 51.266, 55.578, 59.217); the remaining two differed by 0.079 and 0.277pp. The instrument is
faithful.

**The blocked pages detect cleanly.** `ticket-312433` p1 returns a textbook alternation with
boundaries at run ~0.99 and dividers at ~0.40, zero skew:

```
24.945 F · 29.075 p · 33.206 F · 36.625 p · 39.880 F · 43.189 p
       · 47.101 F · 50.875 p · 54.978 F · 58.698 p · 62.746 F
```

Six boundaries and five dividers: a clean 5-slot roster. p2 is equally clean. `ticket-312024` p1
likewise (pitch 7.86).

⚠ **`ticket-312024` p2 is NOT clean and must not be written blind.** Its pitch is **5.434** against
7.86 on its own page 1, with a denser rule set. That is the shape CLAUDE.md records as "the writer
sometimes fits more clients on the form than it has slots, by halving the rows". It needs a person
to look at it, and the design must degrade safely rather than record a confident wrong answer.

---

## Design

### Where each half runs

**Pixels in the browser, semantics in the database.**

The browser does what only the browser can do cheaply: decode the image and emit raw detections
`{pct, run, ink, kind, thick}` plus page stats (`W`, `H`, skew, luma percentiles).

`classify.js`'s 270 lines of trim, duplicate suppression, end-bar removal, phase alternation and
grading move into **`derm.fn_classify_page_rules(...)`**, called by the write RPC. Reasons:

- it is the half that decides `boundary` vs `divider`, and `derm.v_page_printed_rules` and
  `v_band_edge_check` already live in SQL and grade against it;
- keeping it server-side means a stale browser bundle cannot write a differently-classified page;
- and it avoids the failure this estate has already paid for once, where the base64 encoder existed
  in two files that had to stay byte-identical and the second copy was the one nobody re-tested.

### `derm.record_page_rules(p_dump_folder, p_effective_page, p_source, p_detections jsonb, p_stats jsonb)`

SECURITY DEFINER, `authenticated` EXECUTE, and the **only** way rules are written.

1. Classify the raw detections (trim to roster, dedupe, assign kind by alternation, grade).
2. Write one **`page_rule_scans`** row **always**, carrying the grade, the source and the image
   etag, whatever the outcome.
3. Write `page_row_rules` **only** when the grade is acceptable.
4. Return the grade and rule count so the UI can say what happened.

🛑 **Three invariants, each of which has already cost this estate something:**

- **`source` must be `runlen-v2-%`**, because `derm.v_page_printed_rules` selects on that prefix and
  deliberately ignores the five hand-recorded `claude-*` sources. A new algorithm gets `v3` and is
  deliberately not picked up until someone opts in.
- **`page_row_rules`' primary key includes `source`.** Do not upsert across sources: that is what
  silently overwrote 61 hand-recorded rules on 2026-08-21.
- **A scan row is written even when detection fails.** "Detection ran and could not read this page"
  and "nobody ever looked" are different states, and collapsing them is the false all-clear this
  estate keeps paying for.

### 🛑 The safety rule: garbage rules are strictly worse than no rules

Today the guard blocks because it knows it is blind. If detection records lines that are not on the
paper, the guard starts **accepting** bands snapped to fiction, and the operator gets a green light
for a wrong redaction. That is a worse outcome than the wall Fred hit.

So a page whose detection did not produce a confident, cleanly alternating roster **keeps blocking**.
`ticket-312024` p2 is the live test case for this: it must land as a `page_rule_scans` row with a
non-OK grade and **zero** `page_row_rules`, leaving G9 refusing exactly as it does now.

### What it does NOT do

- **It never moves a band.** Detection records where the printed lines are. Snapping is still the
  operator dragging, and `save_page_geometry` still validates.
- **It never writes a page extent**, so it cannot cause anything to publish. The extent stays a
  separate deliberate act, which is the property that lets geometry be banked on a page that serves
  nothing.
- **It never auto-completes a sheet.**

### The UI

Detection runs automatically when the Studio opens a page that has no scan row, before the operator
touches anything. In the normal case Diego sees nothing at all: he opens a new sheet and the
rectangles simply save.

Two visible states are needed for the cases that are not normal:

- a **"Re-detect printed lines"** action, for when a scan image is replaced;
- an explicit, readable message when the grade is not OK, saying the page could not be measured
  automatically and needs review. **Not** the current wall of ten identical `G9_OFF_RULE` lines,
  which is a developer's error text shown to an operator.

⚠ The current message is itself part of the defect. `row 1029 top edge 33.104 is not on a printed
rule (nearest no rules for this page)` tells Diego nothing he can act on. The parenthetical is the
only informative part and it is last.

---

## Testing

1. **Positive control, non-negotiable:** re-detecting `ticket-832194` p1 through the in-app path
   reproduces the stored `runlen-v2-2026-08-21` positions. If the app's numbers do not match the
   ones already in the table, the port is wrong.
2. **Byte-fidelity of the port:** the browser detection code is extracted from `detect.js`, not
   retyped, and a token-stream comparison proves equivalence. (Already done once for this spec's
   feasibility run: 769 tokens before and after comment stripping, identical.)
3. **The blocked pages:** `ticket-312433` p1/p2 and `ticket-312024` p1 detect and grade OK.
4. **The unsafe page:** `ticket-312024` p2 grades non-OK, writes a scan row, writes **zero** rules,
   and G9 still refuses. This is the test that matters most.
5. **End to end:** open `ticket-312433` in the Studio, drag the same edge Fred dragged, and the save
   succeeds. Fred's submitted edges were within 0.2 to 0.3pp of the real printed boundaries, so they
   should snap cleanly.
6. **Idempotence:** opening the page twice does not duplicate rules or scan rows.
7. **No publish side effects:** page extents and `redacted_manifest_docs` are unchanged; the folder
   still serves nothing.
8. **Grant check:** `anon` cannot execute the RPC; `authenticated` can; and the RPC refuses a
   `source` outside `runlen-v2-%`.
9. **Fleet regression:** the 168 pages that already have rules are untouched, and
   `derm.v_band_edges_off_rule` does not grow.
10. **Visual:** the detected lines rendered over the scan (`annotate.js` already does this) confirm
    they sit on printed rules and not on text.

---

## Open questions for Fred

1. **Auto-run on open, or a button?** Recommended auto, because the whole complaint is that Diego
   should not need to know this step exists. A button is a smaller change and keeps a human in the
   loop on every write.
2. **What happens to the dev scripts?** Once the app is canonical, `detect.js` / `classify.js`
   should either be retired or kept solely for fleet-wide backfills with a fixture test asserting
   they agree with the app. Two implementations that drift is the specific failure this repo has
   already recorded.
3. **`ticket-312024` p2** needs a person to look at the paper regardless of what ships here.
