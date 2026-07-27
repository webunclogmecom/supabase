# Queue audit — execution order, tests, blast radius, safeguards

*Supabase session, 2026-07-27. Joint audit with the Building Apps session (their half merges in below once received). Fred asked for: what ships first, in what order, the test for each change, how each can affect something else, and the safeguards if something breaks.*

---

## The two findings that drive everything

**1. PITR is OFF.** Verified live: `pitr_enabled: false`; only daily physical backups (`walg_enabled: true`). So today, a bad write means **up to 24h of data loss and no point-in-time rewind**. Three queued items are destructive (delete rows / delete storage objects / drop columns).

**2. The photo over-attach is GROWING.** 3,719 bad links on 2026-07-24 → **3,784 today**. ~65 new bad links in 3 days, because the linker itself is still wrong. Every day we wait, the cleanup gets bigger and more visits show inflated photo counts.

**The structural conclusion:** don't order the queue as 9 monolithic tasks. **Split every task into its non-destructive part and its destructive tail**, ship all the non-destructive parts now, and batch the destructive tails behind one PITR decision. That single reframing removes PITR as a blocker for ~80% of the queue.

---

## Execution order

### WAVE A — ship now. Zero destructive ops, no dependencies, no PITR needed.

| # | Change | Why first |
|---|---|---|
| A1 | **Security cleanup** — revoke `zones` UPDATE from authenticated; drop leftover `gdos` column-level UPDATE grants (`location_label,notes,property_id,status`) | Cheapest, no deps, and it **must** precede the wave-1 RPCs or the RPC won't be the only write path to `gdos` |
| A2 | **Photo LINKER fix** (stop the bleeding) — link a note's photos to `notes.visit_id` only. **No historical delete yet** | The bug is actively accruing (+65/3d). Fixing the writer is separate from the cleanup and carries none of its risk |
| A3 | **GDO permit thumbnails** — render + backfill 174 PDFs → `gdo/thumbs/`, populate `permit_thumbnail_path` | Purely additive. Column already live; app already wired with a placeholder fallback |
| A4 | **STAGED_2026-06-15c A/B** — per-app anon-write verification, then apply | Closes remaining anon write surface. Verification-gated, reversible |

### WAVE B — the storage move. Non-destructive up to the final step.

| # | Step | Destructive? |
|---|---|---|
| B1 | Create the new private bucket | No |
| B2 | **Copy** (not move) the 2,656 derm objects into it | No |
| B3 | Rewrite `derm_manifests` URL columns to the new bucket (same `/object/public/<bucket>/<path>` shape so all 3 apps' signers auto-follow) | Reversible (columns backed up) |
| B4 | Add the new bucket to `get-derm-doc`; repoint the `send-derm-email` attachment fetch | No |
| B5 | Verify all 3 apps render + FP customer redacted sheets still serve | Gate |
| B6 | **Soak 48h**, then delete the public originals | ⚠ DESTRUCTIVE TAIL → Wave D |

#### ⛔ NEW HARD GATE (BA, 2026-07-27): Field Portal must be re-wired BEFORE B2

**The 2026-07-02 FP signed-URL repoint has REGRESSED.** BA read the live deployed bundle: the doc card accepts either `{manifestId, clientCode, kind}` (→ `get-derm-doc`) **or** a direct `{url}`, and short-circuits on `url` first. Both compliance cards pass a raw `url` from `customer.work_orders`, so the signed branch is **unreachable dead code**.

⚠ **Grepping the bundle for `get-derm-doc` is a FALSE PASS** — the dead path is still bundled. That is exactly why it looked verified on 07-02. *(Method lesson: presence of a string in a bundle ≠ that code path executing.)*

**Impact if I move `derm/*` first:** the WWTP Disposal Receipt dies on **544 of 588 work orders** (388 in `GT - Visits Images/derm/*`, 156 in `manifests/derm/*` — all inside the move set), and because the card is number-gated it renders **DOCUMENTED with a dead preview** rather than degrading to PENDING. **Customer-facing.**

→ **F1 (FP re-wire + publish) is BA's and it BLOCKS Wave B.** Two sub-traps BA will handle: `kind:'fog'` returns the *wrong artifact* for current FP (signs `derm_manifests.fog_manifest_url`, a PDF, while the card renders the redacted JPG) so it needs a new kind (e.g. `'redacted'`); and `get-derm-doc`'s raw-path fallback list is hardcoded `['manifests','GT - Visits Images']` → **must add the new bucket** (mine).

#### ⛔ REVERSAL: do NOT drop `Public can read manifests`, and do NOT flip either bucket

BA retracted their own earlier advice and I accept the correction. The `manifests` bucket also holds the **FP-blackout redacted sheets** (`manifests/redacted/m{id}-*.jpg`) served to **customers via raw public URLs on 545 of 588 work orders**. Dropping that anon policy or flipping the bucket private takes the customer-facing FOG eManifest dark. Likewise `GT - Visits Images` must **stay public**: `customer.public_url()` / `thumbnail_url()` hardcode `/object/public/GT%20-%20Visits%20Images/`, so a whole-bucket flip 404s every visit photo.

**Revised Wave B scope:** move `derm/*` out to the private bucket only; **leave both source buckets public and the redacted path readable** until FP is re-wired. The anon-policy drop moves to a later, separate step gated on FP.

### WAVE C — Client App phase 2 wave 1 (after A1).

| # | Change |
|---|---|
| C1 | Audit trigger: add `app_source='client-app'` |
| C2 | Wave-1 SECDEF RPCs: GDO permit upsert, property operational-fields patch, client notes/group patch |
| C3 | BA wires the UI + call sites |

### WAVE D — destructive tails. **PITR-gated (or per-item pre-image export + Fred's explicit go).**

| # | Change | Magnitude |
|---|---|---|
| D1 | Photo over-attach **historical cleanup** | DELETE ~3,784 rows |
| D2 | Storage: delete the public originals | DELETE 2,656 objects |
| D3 | Ticket# collapse **final drop** of white/yellow | Schema change, 569 rows, 20 dependent views |

### WAVE E — the ticket# collapse, non-destructive portion (independent track)

Add `ticket_number` + backfill, repoint the 20 readers equivalence-gated, migrate the unique indexes — **keeping white/yellow as compat columns**. The drop (D3) is then optional and can wait indefinitely. **Do not run this in the same window as Wave B** — both rewrite `derm_manifests` and hit the same 20 views; a failure would be un-diagnosable.

#### ⚠ DESIGN DECISION (2026-07-27, after a BA flag): compat columns must be DERIVED, not NULL

BA flagged that the Client App visit drawer reads `COALESCE(white_manifest_number, yellow_ticket_number)` from `client.derm_manifests` (shipped 2026-07-25), and DERM Tracker renders `derm.manifests` `display_number` / `display_label` / `jurisdiction` everywhere. Two naive options both fail: **dropping** the columns 400s the app's explicit `.select()` (the `properties.zone` / `derm_manifests.deleted_at` class we've now hit twice); **NULL-filled compat columns** are worse — the drawer silently shows "—" for every visit and nothing errors.

**Adopted: reconstruct the old names as REAL derived values in every read view.**

```sql
white_manifest_number = CASE WHEN jurisdiction = 'dade'    THEN ticket_number END
yellow_ticket_number  = CASE WHEN jurisdiction = 'broward' THEN ticket_number END
-- plus the new ticket_number exposed alongside
```

**Verified against live data, not assumed:** simulated the reconstruction over all **569 live manifests** → **0 white mismatches, 0 yellow mismatches, 0 COALESCE mismatches**. The invariant that makes it lossless also holds exactly: **452 white-only + 117 yellow-only, 0 both-set, 0 neither-set**.

Consequences:
- **Zero frontend change** for the Client App drawer and for DERM Tracker (`display_*` output names/semantics preserved — CountyBadge and the "always use display_label" rule stay valid).
- **No coordinated same-window change** — the sessions decouple instead of synchronizing.
- **D3 becomes genuinely optional**: with derived columns there is no cost to keeping the old names forever → defer D3 indefinitely unless PITR is on.

#### ⚠ GAP IN OPTION 3, CLOSED (BA, 2026-07-27): view compat ≠ base-table compat

Option 3 as first stated protected **view** consumers only. Two consumers hit `public.derm_manifests` **directly**. Both verified in source:

1. **`send-derm-email`** (lines 267-268 / 375-376): `.from('derm_manifests').select('id, client_id, white_manifest_number, yellow_ticket_number, …')` then `const number = m.white_manifest_number || m.yellow_ticket_number || String(id)`. **This is the client + city email path — the highest-consequence surface in the queue.** No view is involved, so view-layer compat would not have saved it.
2. **`webhook-airtable`** (line 542-543 WRITES both columns; 630-638 dup-checks with `.eq()` on them). BA's corollary is correct: **a Postgres GENERATED column fixes the READ but not the WRITE** — generated columns are read-only.

**Resolution — compat lives on the BASE TABLE as GENERATED columns:**
```sql
white_manifest_number GENERATED ALWAYS AS (CASE WHEN jurisdiction='dade'    THEN ticket_number END) STORED
yellow_ticket_number  GENERATED ALWAYS AS (CASE WHEN jurisdiction='broward' THEN ticket_number END) STORED
```
Generated (not trigger-maintained) is the deliberate choice: it is *strictly* derived, so the duplicate-value dirt this whole collapse exists to remove **cannot come back**. A trigger-maintained pair would recreate the exact anti-pattern (cf. the `properties.zone` bidirectional-sync trigger we just deleted).

That leaves the two writers, and both are wanted work anyway:
- **`webhook-airtable`** → **cut the dispatch first** and prove a synthetic event returns `skipped` (the "wired ≠ dead" rule; the `derm_manifest` handler fired 55× after we assumed it dead). Airtable is retired, so preserving write-compat for a dead feed is the wrong trade.
- **The filing RPCs** (`file_manifest`, `file_manifest_on_shared_ticket`, `derm.file_manifest_and_link`, `edit_manifest`) → mine; updated to write `ticket_number` + `jurisdiction`.

Result: **`send-derm-email` needs no redeploy**, all four view-based apps need no change, and no coordinated window is required.

**Confirmed sweep set** (relations exposing the two columns — `client.derm_manifests` explicitly included, it is 3 days old and easy to miss):
`public.derm_manifests`, `public.manifest_detail`, `public.v_derm_portal_fields`, `public.v_derm_portal_queue`, `public.v_derm_portal_dryrun`, `client.derm_manifests`, `derm.manifests`, `derm.manifest_health`, `derm.v_extraction_quality`, `derm.v_orphan_manifests`, `derm.v_sheet_client_count`, `derm.v_stamp_linkage_gaps`, `derm.v_stamp_rows`, `derm.v_stamp_sheets`.

⚠ **`derm.address_row_map` also carries a `white_manifest_number` — it is a DIFFERENT PHYSICAL TABLE (Stamp Studio), not a view of this one. Do NOT rename it in the same migration.**
⚠ `public.v_derm_portal_queue` / `_dryrun` are **Jonathan's external RPA contract** — `white_manifest_number` must keep resolving there (it now sits alongside the `ticket_number` I added 2026-07-24).

⚠ **One lossy edge case:** across all 587 rows (including soft-deleted) exactly **1 soft-deleted row has BOTH numbers set** — the legacy `815064`-class dirt. The reconstruction cannot represent it, so if restored it would lose one number. The collapse migration must resolve that single row **explicitly**, not silently. Live rows are unaffected.

---

## Per-change: test / cross-impact / safeguard

### A1 · Security cleanup
- **Test:** rolled-back write probe as `authenticated` → 0 rows affected on `zones` and `gdos`; SELECT still returns rows; Calendar zone chips + DERM/Client App permit cards still render.
- **Cross-impact:** none expected — audit shows all `gdos`/`zones` writes are `postgres`/`sql`/webhook, zero from `authenticated`. **Risk:** if any app silently writes zones via PostgREST, its save breaks.
- **Safeguard:** one-line re-GRANT restores it instantly; no data touched.

### A2 · Photo linker fix
- **Test:** re-run the linker on a known multi-visit job (1544/client 305); assert each note's photos land ONLY on `notes.visit_id`; assert the over-attach counter stops growing over 24h.
- **Cross-impact:** Client App + FP visit photo counts. Only affects NEW links — historical rows untouched.
- **Safeguard:** it's a code change to the sync, not a data change; revert the commit.

### A3 · GDO thumbnails
- **Test:** `permit_thumbnail_path` populated for 174/174 with a doc; each thumb fetches 200; the 3 `.tif` render; Client App permit card shows a real image; placeholder still shown for the 46 with no doc.
- **Cross-impact:** none — new column, new storage prefix, public bucket unchanged.
- **Safeguard:** `UPDATE gdos SET permit_thumbnail_path=NULL` → app falls back to placeholder. Thumbs are derived; regenerable.

### A4 · Staged anon revoke
- **Test:** per app, BEFORE applying — confirm the app writes as `authenticated` not `anon` (network + audit `db_role`). After: DERM Tracker can still file a manifest + upload; Admin Review can still save a review.
- **Cross-impact:** ⚠ **highest-risk in Wave A.** DERM Tracker still has anon storage-upload policies; revoking the wrong one breaks filing.
- **Safeguard:** apply **one section at a time**, verify that app's write path between each; re-create policy + re-GRANT to roll back.

### B · Storage move
- **Test:** count parity old vs new bucket (2,656); every rewritten URL resolves signed 200; DERM Tracker visit-detail + manifests gallery, FP work-order FOG/WWTP cards, Client App detail docs; **FP customer redacted sheets** (`manifests/redacted/*`) still serve; `send-derm-email` sends with attachment.
- **Cross-impact:** **3 apps + the email edge fn + the PDF service write path.** The `manifests` bucket also holds the customer-facing redacted sheets — they must not be swept into the private move without their own signed path.
- **Safeguard:** copy-then-verify-then-delete (never move-and-hope). Originals stay live through the soak, so rollback = revert the URL columns from the pre-image backup. Keep the column pre-image JSON.

### C · Wave-1 RPCs
- **Test:** each RPC as `authenticated` — happy path writes; a hostile call (other client's id, bad payload) rejected; audit row lands with `app_source='client-app'`; `gdos_client_consistency_trg` + `trg_aa_gdos_guard_demoted` still fire; verify no `client.*` view became writable.
- **Cross-impact:** GDO permit writes touch a **DERM compliance** object read by 12 views — a bad write is a compliance data error, not a cosmetic one.
- **Safeguard:** RPCs are `REVOKE ALL` + explicit `GRANT EXECUTE`; revoke the grant to disable the feature instantly without a frontend republish.

### ⚠⚠ D1 REDESIGNED 2026-07-27 — the mass delete as scoped was UNSAFE. BA's findings independently verified.

Every claim below I re-ran against live Prod myself; all confirmed:

| Claim | Verified result |
|---|---|
| `photo_classifications.photo_link_id` is **ON DELETE CASCADE** | ✅ `confdeltype='c'` |
| `photo_links` has **NO audit trigger** → deleted links unrecoverable | ✅ zero triggers (`photo_classifications` *is* audited) |
| The delete destroys **human classifier work** | ✅ **73 of 392** classifications cascade-destroyed (18.6%) |
| **1,747** links sit on photos whose notes ALL have `visit_id` NULL | ✅ exactly 1,747 — **no positive evidence these are wrong** |
| Visits dropping to **zero** photos | ✅ **95** completed visits |
| The row count is **predicate-dependent** | ✅ my earlier 3,784 (rule: "photo linked to >1 visit") vs 3,412 (rule: "link ≠ its note's visit"). Different sets. |

**❗ CORRECTION TO WHAT I TOLD FRED:** I said visit 6989 would go "31 → its real ~9". **Wrong.** Verified: of its 31 links, **0 survive** the strict rule and all 31 belong to note-anchored visit 6835. So 6989 → **0 photos**, not 9. And note the deeper implication: we hold **no** correctly-attributed photos for 6989, yet Jobber shows ~9 — so deletion alone does not produce the right answer, it produces an empty visit. **The complaint would flip from "too many photos" to "the photos disappeared."**

**Revised design (do NOT mass-delete):**
1. **Pin the predicate first** and publish the count under it — the number is meaningless without the rule.
2. **Only delete on positive evidence:** the photo's note HAS a `visit_id` AND it points to a *different* visit AND a link to that correct visit already exists (so the photo stays visible where it belongs). **Exclude all 1,747 all-NULL-note links** — absence of an anchor is not evidence of error.
3. **Move the human work, don't kill it:** `UPDATE photo_classifications SET photo_link_id = <keeper link>` **before** any delete.
4. **Add an audit trigger to `photo_links` before touching it** — it is currently the only table in this plan whose deletions cannot be reconstructed.
5. **Backfill, not just delete:** for the 95 visits that would empty out, re-sync their true photos from Jobber first, then clean up. Delete-only is a regression.
6. Full pre-image export of **both** tables including `id`s (the cascade restore requires the parent link to return with the SAME id).

### D1 · Photo cleanup — original notes (superseded by the redesign above)
- **Pre-req:** validate `notes.visit_id` reliability across all 252 visits first (one 07-02 note was tagged to a 07-01 visit — if that class is common, the "correct" target is wrong and the delete would be wrong).
- **Test:** dry-run producing the exact delete set + a per-visit before/after count; spot-check visit 6989 → 31 drops to its real ~9; assert **zero** note-LESS legacy photos in the delete set (82% of photos have no note anchor — the delete must never touch them).
- **Safeguard:** full pre-image JSON of all 3,784 rows (restore = re-INSERT); run in one transaction; Fred's explicit go.

### D2 · Delete storage originals
- **Test:** post-soak, assert 0 remaining `/object/public/` fetches across all 3 apps for 48h before deleting.
- **Safeguard:** file-list backup; objects are re-uploadable from the new bucket (copy, not move).

### D3 · Ticket# drop
- **Safeguard:** genuinely optional — with E done, white/yellow can stay as compat columns forever at zero cost. **Recommend deferring indefinitely unless PITR is on.**

---

## Cross-change collision rules (hard constraints)

1. **`derm_manifests` is touched by Wave B and Wave E** → never the same window. Verify gate between.
2. **`gdos` is touched by A1, A3, C2** → A1 before C2 (else the RPC isn't the sole write path); A3 is a different column, safe alongside.
3. **`photo_links` (A2/D1)** has only 2 dependent views — narrow, but the apps read it directly.
4. **One destructive change per day, max.** If two land together and something breaks, you can't tell which caused it.
5. Every step ends with a **verify gate**; a failed gate stops the wave rather than continuing.

---

## Global safeguards

- **Backup before every destructive step** into `backups/` (pattern already used for the 78-row white/yellow cleanup and the 49 dry-run screenshots).
- **Transaction-wrap** every data mutation; verify inside the transaction where possible.
- **Verify as the real role** (`authenticated`), not as postgres — a postgres check is a false all-clear.
- **Permission audits check column grants + TRUNCATE**, not just table grants.
- **Announce in `WORKING-NOW.md`** before each wave so the sessions don't collide.
- **Rollback rehearsal:** for D1 and B, write the restore command *before* running the change.

---

## Asks for Fred

1. **PITR (~$105/mo)** — decides whether Wave D happens at all this cycle. Waves A/B/C/E do **not** need it. My read: turn it on before D1 (the 3,784-row delete) or accept a pre-image-export-only safety net.
2. **Order sign-off** — A → B → C → E, with D batched last.
3. Existing open items (`reconcile-jobs` un-archive blind spot; inactive-client orphaned Jobber visits + the hard-delete trigger) are independent and low-risk; they can slot into any wave.
