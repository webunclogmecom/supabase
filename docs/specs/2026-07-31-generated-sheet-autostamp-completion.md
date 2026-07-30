# Generated-sheet auto-stamp: why it stopped one wire short, and how to finish it

*Spec only — no migration written, no DB change made. Audited 2026-07-31 against Prod. Fred's ask
(2026-07-27/28, re-raised 2026-07-31): "when a generated address manifest shows up it should be
auto-stamped, and tagged `AI`." Sheets `310429` and `831325` sit at 0/7 and 0/2 with no AI tag.*

---

## The one-paragraph answer to "why isn't it working"

The feature was designed, built, and even demonstrated (the two green sheets in the Studio,
`309898`/`309944`, carry `stamp-studio-ai` stamps placed 2026-07-28 18:27). But the pipeline has
**four stages and the third was never wired**: nothing ever calls the resolver that tells the system
"this printed sheet IS this ticket." Without that link the auto-stamp trigger — which is deliberately
built to **refuse rather than guess** — correctly does nothing, and it does so silently. Two further
defects compound it: a same-minute migration collision left the AI *button* using geometry the fix
migration had measured as wrong, and the trigger only fires on card INSERT, so cards created before
resolution (all 9 current ones) can never be stamped by it even after wiring.

## The intended pipeline, as actually built

```
1. GENERATE   pdf-service preview  -> derm.address_sheet_clients (sheet, slot, client, visit)
              WORKING. Sheets 1064-1073 recorded; 1072 = the 7-client roster of 310429,
              1071 = the 2-client roster of 831325. Shipped 2026-07-28o + pdf-service.

2. FILE       DERM Tracker file_manifest -> derm_manifests + cards in derm.address_row_map
              WORKING. ticket-310429 has 7 cards, ticket-831325 has 2 (source 'derm-link').
              ⚠ dump_folder keys are 'ticket-<n>', NOT bare numbers — a bare-number filter
              reports zero cards and sends the investigation the wrong way (it did).

3. RESOLVE    derm.fn_resolve_generated_sheet_for_ticket(ticket)
              -> writes derm.address_sheet_manifests (sheet, manifest, slot)
              🛑 BUILT BUT NEVER CALLED BY ANYTHING. Zero callers: no trigger, no cron,
              no DB function, and neither app bundle (DERM Tracker rpcs: file_manifest,
              edit_manifest, file_manifest_on_shared_ticket; Studio rpcs include
              auto_place_page but not the resolver). address_sheet_manifests: 0 rows ever.

4. STAMP      trg_ab_autoplace_generated (BEFORE INSERT on address_row_map)
              gate: fn_sheet_is_generated(ticket)  <- reads address_sheet_manifests (stage 3!)
              slot: fn_generated_sheet_slot(...)   <- NULL when unrecorded => refuse, no guess
              geometry: fn_generated_row_geometry  <- the CORRECTED numbers
              tag: stamp_placed_by = 'stamp-studio-ai'  <- this IS the Studio's AI badge
              ARMED AND CORRECT — and unreachable, because stage 3 never runs.
```

Stage 3 is the single dropped wire. Everything upstream and downstream of it works.

**Verified the resolver would succeed today**: sheet 1072's client set `{10,11,23,307,318,459,499}`
exactly equals ticket 310429's, as the only unlinked candidate; sheet 1071 `{28,503}` = 831325's.
Both tickets have ALL their manifests filed, so the conservative exact-set gate passes right now.

## Three defects to fix (ordered; the order is load-bearing)

### D1 — the AI button uses geometry that 28n measured as wrong (fix FIRST)

`2026-07-28n` measured the y-geometry ~3% high against three physically verified sheets and shipped
corrected numbers in `derm.fn_generated_row_geometry` (x 8.00; y 29.80/37.72/44.48/51.81/60.04).
`2026-07-28q` — **same minute, 21:10** — recreated `derm.v_stamp_rows` carrying the OLD inline
values (x 6.82; y 25.98/34.62/41.58/49.10/57.25) and never calling the corrected function. Measured
live: the view still has the old array (`view_has_corrected_geometry: false`).

Rows are ~7.5-8% apart, so ~3% high pushes a stamp toward the row ABOVE. The FP customer blackout
derives each client's visible band from the stamp, so a wrong row = showing client A client B's line
on a compliance document — the exact PII leak 28n exists to prevent. `auto_place_page` (the AI
button) stamps whatever the view guesses, so **the button must not be used on generated sheets until
this is repointed**. Wiring stage 3 without D1 makes things worse, not better: it flips
`fn_sheet_is_generated` TRUE, which switches the view onto the wrong-geometry generated branch.

Fix: the view's generated branch delegates to `fn_generated_row_geometry(slot)` (single source of
truth; the trigger already uses it). Same-columns-appended-nothing, so `CREATE OR REPLACE VIEW` is
legal. This is a 28q repair, not new design.

### D2 — nothing calls the resolver (the dropped wire)

Fix: `AFTER INSERT ON public.derm_manifests FOR EACH ROW` trigger calling
`derm.fn_resolve_generated_sheet_for_ticket(coalesce(NEW.white_manifest_number, NEW.yellow_ticket_number))`.

Why a trigger and not the app: filing is the moment manifests exist (28o: "the second is RESOLVED
from the first once the manifests exist"), every filing path funnels through the DB (three RPCs),
and the resolver is already idempotent (early-returns when linked) and conservative (exact-set,
single-candidate, else refuses). Calling it on every manifest insert is safe by construction:
while a ticket is partially filed the client sets differ, it returns NULL, and the LAST manifest's
insert completes the set and resolves. No app deploy, no new failure mode, ADR-010 note only
(no table change; `derm.*` working-state lane is unaudited by design, consistent with 28o).

### D3 — cards inserted BEFORE resolution stay unstamped forever

`trg_ab_autoplace_generated` is BEFORE **INSERT** only. At filing time the card insert and the
manifest insert are in the SAME transaction, and card materialisation (`trg_zz_card_from_link`)
runs off the manifest_visits link — meaning cards routinely exist before the ticket's LAST manifest
completes the set and resolves. Today's 7+2 cards are exactly this state, permanently.

Fix: after a SUCCESSFUL resolution, the resolver places stamps on the ticket's EXISTING cards by
UPDATE, with the same refusal rules as the trigger:
  - only `stamp_placed_at IS NULL` rows (never touch a human stamp),
  - slot from `fn_generated_sheet_slot`, skip (do not guess) when NULL,
  - geometry from `fn_generated_row_geometry`, `stamp_placed_by = 'stamp-studio-ai'`.
This single addition makes the whole feature order-independent AND clears the current backlog the
moment D2 fires for these tickets (or the resolver is invoked once by hand). No separate backfill
step needed.

## Also in scope: re-check the two "demo" sheets

`309898`/`309944`'s AI stamps were placed **2026-07-28 18:27**, nearly 3 hours BEFORE 28n's
corrected geometry landed (21:10) — so they carry the old, ~3%-high positions. They are marked
Completed. After D1, re-derive their positions and compare; if materially off, clear + re-place
(`clear_stamp_position` + the D3 pass) and let the return-review trigger resurface them. Do not
silently trust "Completed": that flag is a human attestation, not a geometry check
(`reference_stamp_completed_human_verified`).

## Explicitly OUT of scope

- Any change to `auto_place_page`, GATE 1, or the refuse-not-guess policy — they are correct.
- Relaxing the resolver's exact-set match. Ambiguity must keep refusing (28o: "Refusing is safe;
  guessing is not").
- The scanned-sheet (vision) lane. The one-shot 2026-07-01 vision pass and the 23 vision-less
  folders are a separate gap with a separate economics question.
- Studio UI changes. **⚠ Badge contract, corrected by @Building Apps from the live bundle and
  verified here against the DB**: the Studio never sees `stamp_placed_by`. The badge binds to three
  aggregates on `derm.v_stamp_sheets`:
  `placed_rows` / `ai_placed_rows` / `filled_by_ai`, where (measured)
  `ai_placed_rows = count(*) FILTER (WHERE stamp_placed_by='stamp-studio-ai')` and
  `filled_by_ai = (placed_rows > 0 AND ai_placed_rows = placed_rows)`. So the chain from D3's
  attribution string to the badge holds TRANSITIVELY, and no Studio change is needed — but anything
  altering how those aggregates are computed changes the badge without touching the Studio.
  Live shapes today: `ticket-310429` = 0/0/false (no badge, correct), demo `ticket-309898` =
  5/5/true (badge "AI").
  **⚠ The badge component is strict on BOTH branches** (`r === true`, `r !== false`): a
  NULL/undefined `filled_by_ai` renders NO badge even at 7/7, and `ai_placed_rows = 0` renders
  nothing rather than "AI 0/7". The DB view yields non-NULL in the measured shapes (the count
  lateral returns 0 on a miss, not NULL), so this is a contract to PRESERVE, not a bug to fix.
  **⚠ The Studio also reads `v_stamp_rows` directly at three call sites for on-screen stamp
  positions** (@Building Apps, from the bundle). Nuance: PLACED stamps render from STORED
  `stamp_x/y_pct` (so the demo sheets' ~3% offset is in their stored values and is fixed by
  re-placement, not by D1), while UNPLACED rows' previews/AI-button use the view's guess (fixed by
  D1). Both matter; different fixes.

## Verification protocol (per last night's lessons: through the transport, no empty-set passes)

1. **Probe, rolled back**: BEGIN; call the resolver for `310429`; assert `address_sheet_manifests`
   gets 7 rows with slots 1..7 matching `address_sheet_clients` order; assert the D3 pass stamps 7
   cards with corrected geometry; ROLLBACK. Same for `831325`. Positive control: a ticket whose
   set matches NO sheet must return NULL and write nothing.
2. **Apply D1**, re-read `v_stamp_rows` for a generated folder: guesses must equal
   `fn_generated_row_geometry` output exactly.
3. **Apply D2+D3 live**, then file-or-resolve the two real tickets and verify in the STUDIO UI
   (browser, not catalogue): progress bars 7/7 and 2/2, AI badge visible. That UI step is
   @Building Apps' or mine via Chrome — the badge is the deliverable Fred asked for.
4. **End-to-end for the NEXT sheet**: generate → file all manifests → confirm cards arrive
   already-stamped with zero manual action. Until one sheet has done this through the real DERM
   Tracker flow, the feature is not "verified", it is "probed".
5. Audit rows: `derm.*` is unaudited by design; verify via the tables + Studio UI, not audit.logs.

## Authorship and intent — ANSWERED by the author (@Supabase, 2026-07-31)

**Author: @Supabase (session 1).** Commits `0e70654` (28n/28o/28q, 21:10) and `601d32b` (28r);
`0e70654`'s own message third-persons this session ("renamed to avoid colliding with the migrations
Supabase 2 pushed"), which settles it from the record.

**Intent: DROPPED IN HANDOFF, not a staged go-live. Nobody was waiting on Fred.** The author's own
28o amendment shaped the resolver's grant "so the filing app can trigger resolution" — the caller
was intended (DERM Tracker filing path) and never built. This spec closes that gap; it does not
override any decision. **D1 has the author's explicit no-objection** ("it restores what 28n
intended"), with the clobber reproduced live on their side too.

Three author notes folded into the design above and binding on the implementer:

- **(a) Ordering confirmed load-bearing from the author's side as well**: the generated branch is
  dead code TODAY (that is why the 28q clobber has been harmless); it goes live the instant
  resolution works. Geometry lands BEFORE or WITH the wiring, never after.
- **(b) D1 blast radius, measured by the author**: `v_stamp_rows` has 0 dependent views; its only
  referencing function is `derm.auto_place_page` (the intended consumer), and crucially
  **`v_stamp_row_bands` does NOT reference it**, so FP blackout band geometry does not shift under
  D1. The PII path is mis-placement → blackout serves the wrong client's row — one step further
  along than "geometry → blackout", same conclusion.
- **(c) ⚠ THE RESOLVER REFUSES N-1 TIMES PER SHEET, BY DESIGN — DO NOT "FIX" IT.** Manifests are
  filed one-per-client on a shared ticket, so on an N-client sheet the first N-1 inserts leave the
  ticket's client set incomplete and the AFTER-INSERT resolver correctly no-ops each time,
  resolving only when the LAST manifest completes the set. Testing with one manifest and stopping
  will read as "broken". The exact-set match is the guard that stops cross-client stamping;
  relaxing it is how the PII bug gets reintroduced.

Unrelated heads-up from the same exchange, recorded for whoever implements: `public.gdos` gained
`trg_gdo_number_one_address` (2026-07-30_2103, `a9dd79e`) — one ACTIVE `GDO-` number per address,
a new refusal path for anything WRITING `gdos`. This spec only READS `gdos`
(`fn_generated_sheet_slot`'s multi-permit expansion), so no impact here.
