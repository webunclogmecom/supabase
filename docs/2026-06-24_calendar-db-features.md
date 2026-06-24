# 2026-06-24 — Three Calendar/DB features: residential guard, ripple reschedule, GDO permits

*Supabase data-ops session · companion records: [`jobs-visits-calendar-workflow.md`](jobs-visits-calendar-workflow.md),
[`schema.md`](schema.md), the four `migrations/2026-06-2*` files, and the Lovable-side handoff
`../../Building Apps/building apps - calendar app - task.md`.*

Three features were designed together, adversarially reviewed for DB-logic coherence, verified
against the live Prod DB, then implemented. They touch **disjoint DB objects** (clients column+trigger /
visits RPC / no DDL for GDO) so they ship independently. This is the canonical record of what was built,
why, how it was verified, and what remains.

## How these were designed (process)
A multi-agent workflow ran **Understand → Design (one per feature) → adversarial Review (4 lenses:
coherence, trigger/recursion correctness, data-rule compliance, live-mutation risk) → live verification
of every load-bearing claim → synthesize a per-feature GO / NO-GO**. Verdicts: residential guard = GO,
ripple = GO-to-build (global enable gated), GDO = needs-Fred (decided: public bucket). The dry-runs +
live test then **caught 4 real bugs** in the draft SQL before anything customer-facing ran (see Ripple).

---

## 1. Residential client_class guard ✅ DONE

**Problem.** `public.clients.client_class` is auto-derived from Jobber `Client.isCompany`. But **every
Airtable-coded client is `isCompany=true`** in Jobber, so genuine residentials that were hand-classified
(`119-ME` Mosche Elghrissi, `121-FRO` 9072 Froude LLC, `126-YM` Yonadav Madar — confirmed residential by
Google Places address lookup) would be **flipped back to `commercial` on the next `*/5` poll** (both
`webhook-jobber.handleClient` and `backfill_clients_class.js` re-derive blindly).

**Built.** Migration [`2026-06-24_clients_class_source.sql`](migrations/2026-06-24_clients_class_source.sql):
- `clients.client_class_source TEXT NOT NULL DEFAULT 'jobber'` + CHECK `IN ('jobber','manual')`. 3NF
  (provenance of `client_class`, depends only on the PK). Rule-1-safe — the *value* `'jobber'` names a
  system as data; it is **not** a `jobber_*` column.
- `BEFORE UPDATE` trigger `trg_clients_protect_manual_class` — when `client_class_source='manual'`, it
  silently preserves the old `client_class` (never RAISEs, so the poll never fails).
- Pinned the 3 residentials to `residential` / `manual`.
- Code (cosmetic, the trigger is authoritative): `webhook-jobber/index.ts` drops `client_class` from the
  update when the row is manual; `backfill_clients_class.js` skips manual rows.

**Verified (live).** Forced-`commercial` write on a manual row → reverts to `residential` (rolled-back
negative test); a `jobber`-source row still flips freely (guard is scoped to manual only); backfill
dry-run = **0 phantom updates**. Commit `e6a548b`.

**Note.** The `webhook-jobber` edit is committed but **not deployed** — purely cosmetic since the DB
trigger enforces protection regardless; it rides the next webhook-jobber deploy.

---

## 2. Ripple reschedule ✅ BACKEND DONE + LIVE-VERIFIED · ⏳ frontend wiring + global enable gated

**Problem (Fred).** Moving a visit should keep the job's cadence: freq 10d with visits 07/01 & 07/11,
drag 07/01→07/03 ⇒ the next should re-anchor to **07/13**, not stay at 07/11. Today a drag moves only that
one visit; the chain drifts.

**Decision: an RPC, not a trigger.** `fn_push_visit_to_jobber` has **no recursion depth guard** (verified),
so a date-change trigger that itself writes `visit_date` would infinite-loop. The cascade lives in the RPC's
own loop and reuses the verified push path unchanged.

**Built.** Migrations [`2026-06-25_ripple_reschedule_visit_rpc.sql`](migrations/2026-06-25_ripple_reschedule_visit_rpc.sql)
+ [`2026-06-25b_ops_ripple_reschedule_visit.sql`](migrations/2026-06-25b_ops_ripple_reschedule_visit.sql)
(ops wrapper so the app's ops-schema client can call it):
`public.ripple_reschedule_visit(p_visit_id, p_new_date, p_new_start_at, p_new_end_at, p_dry_run)` —
moves the target and re-anchors the **forward** chain at `jobs.frequency_days` from the new date. Scope =
same `job_id`, `source IN ('visit-calendar','supabase_cron')`, status not completed/cancelled,
`deleted_at IS NULL`, `visit_date > LEAST(old,new)`. Fan-out cap 24 RAISEs (no unbounded push burst);
`freq<=0` ⇒ move-only; timed visits keep their wall-clock (start/end shifted by the same day delta); each
shifted row pushes to Jobber once via the existing `trg_push_visit_update`.

**Bugs the verification caught (before any live write):**
1. `array_agg(...) ... FOR UPDATE` — illegal (aggregate + row lock). Fixed: lock+order in a subquery.
2. `date + bigint` — `WITH ORDINALITY`'s `ord` is bigint; `date + int` only. Fixed: `::int` cast.
3. Re-anchor left timed `start_at` on the old date. Fixed: shift `start_at`/`end_at` by `make_interval`.
4. (design) 112-YA is an invalid cascade test bed — all its jobs are archived/freq 0; used a real chain.

**Verified.** Dry-run on job 1635 (24 visits, freq 7) — earliest-forward, middle-forward, and
last-moved-before-first all re-space at exactly freq. **Live Jobber round-trip on job 1607 (181-PV):**
rippled `06/30→07/01` → Jobber reflected all 3 rows within 3s, GIDs unchanged → reverted → **net-zero**
(DB + Jobber both back to original). Commits `d429ece`, `fcc03a6`.

**Remaining (Lovable/Calendar session — gated).** Wire drag-drop to call `ops.ripple_reschedule_visit`
(dry-run → opt-in confirmation listing the N dates → apply). Global enable across all 144 clients is gated
on that wiring + the opt-in (it writes real customer Jobber reschedules). The RPC is **inert** until wired.

---

## 3. GDO permits — serving + ingestion ✅ DONE

**Problem (Building Apps handoff).** The Calendar drawer's "View permit" reads `gdos.permit_document_path`,
but the PDFs weren't servable: the `gdo-permits` bucket was **private**, and only **48 of 145 ACTIVE** GDOs
had a PDF ingested.

**Decision (Fred): public bucket** — GDO permits are Miami-Dade regulatory records treated as
non-sensitive; same model as DERM manifests. Migration
[`2026-06-24_gdo_permits_public_bucket.sql`](migrations/2026-06-24_gdo_permits_public_bucket.sql) flips
`storage.buckets 'gdo-permits' public=true`. `permit_document_path` stays a bucket-relative path; the
frontend builds `https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/gdo-permits/<path>`.

**Built + ran.** [`scripts/sync/cron_gdo_permit_pdf_ingest.js`](../scripts/sync/cron_gdo_permit_pdf_ingest.js)
resolves each missing permit from (a) the Phase-2 bot result JSONs then (b) a **live Miami-Dade DERM
Strategy-0 case-number lookup** (`POST api-ecmrer.miamidade.gov/derm/documents`, integer-digit case match
to avoid misattribution), downloads, uploads, sets `permit_document_path`. Idempotent, guarded, dry-run
default. **Gotcha: the DERM API needs a browser `User-Agent`** — header-less requests get a WAF 403.

**Result (`--apply`).** **75 uploaded + linked, 0 errors, 0 orphans.** ACTIVE GDOs with a permit:
**48 → 123 of 145.** The remaining 22 have placeholder `gdo_number`s ("Needs review" / "Not available") —
no real permit number, so they correctly show the drawer's empty-state. Spot-checked newly-ingested permits
serve `206 / application/pdf`. Commits `1f1df6d` (bucket), `163b00f` (ingest).

**Refresh later.** Re-run `node scripts/sync/cron_gdo_permit_pdf_ingest.js --apply` (idempotent — skips
already-linked GDOs). Safe to schedule once placeholder numbers get real values.

**Remaining (Lovable/Calendar session).** The drawer (already built) just constructs the public URL above;
null path → keep the existing empty-state.

---

## Commits
| Commit | What |
|---|---|
| `e6a548b` | Residential guard: `client_class_source` + trigger + code edits |
| `d429ece` | `ripple_reschedule_visit` RPC |
| `fcc03a6` | `ops.ripple_reschedule_visit` wrapper |
| `1f1df6d` | gdo-permits bucket → public |
| `163b00f` | GDO permit PDF ingest script (backfilled 75) |
| `c184914` | (Building Apps repo) Calendar task handoff doc |

## Open items
- **Frontend wiring (Lovable session):** ripple drag-drop + opt-in; GDO drawer URL. Documented in the
  Building Apps task doc with paste-ready prompts.
- **Ripple global enable** — gated on the wiring above (customer-facing Jobber writes).
- **`webhook-jobber` deploy** — cosmetic client_class edit committed, not yet deployed (trigger covers it).
- **Full pipeline audit (`zero-runs`)** — not run this session; each change was verified directly. Run
  before declaring the multi-fix session fully closed per the audit-after-fixes rule.
