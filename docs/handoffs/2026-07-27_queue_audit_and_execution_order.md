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

### D1 · Photo cleanup (destructive)
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
