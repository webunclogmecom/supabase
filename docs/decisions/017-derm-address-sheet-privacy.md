# ADR 017 — DERM "address" sheet privacy gate on `customer.work_orders`

**Date:** 2026-05-27
**Status:** Accepted (option 1 shipped); option 2 deferred
**Supersedes:** Path C predicate in 2026-05-20j (and its carry-forward in
2026-05-21a / 2026-05-25b / 2026-05-25f)
**Related:** ADR 008 (photos normalized out), ADR 010 (audit trail)

## Context

`customer.work_orders` is the Field Portal's per-visit view. It exposes two
DERM compliance URLs to the customer:

| View column | ← from `derm_manifests` table column | What it actually is |
|---|---|---|
| `derm_manifest_url` | `derm_address_url` | **DERM "address" page** — lists EVERY pickup address on the dump run (multi-client roster) |
| `wwtp_receipt_url`  | `derm_manifest_url` | **DERM "manifest" page** — the white-form proof of one physical dump (waste hauler, quantity, facility). Does NOT name other clients. |

The column-name alias swap in the view is historical (the original FP design
called the address page "the manifest"). It is intentionally preserved here
to avoid breaking the FP TypeScript types; the table-side names remain canonical
on `derm_manifests`.

### Original Path C (2026-05-20j)

Fred's privacy concern was: a customer viewing their own visit shouldn't see
OTHER customers on the same dump-run address sheet. The original gate hid
`derm_manifest_url` (in the view) when MULTIPLE rows of `derm_manifests`
shared the same `white_manifest_number`. The assumption was Path C's invariant
of "one `derm_manifests` row per client per dump, all sharing
`white_manifest_number`".

### Why that gate broke

DERM Tracker (live since 2026-05-18) writes **one** `derm_manifests` row per
**physical sheet** and attaches multiple clients via `manifest_visits`. So:
- A multi-client dump-run produces one `derm_manifests` row.
- `COUNT(*) FROM derm_manifests WHERE white_manifest_number = X` = 1.
- The gate's predicate is false → the address PDF passes through.
- Customer sees the multi-client roster. Privacy leak.

The leak was reproduced 2026-05-27 on visit 5079 (client 369 Casa Neos,
2026-05-12, manifest 1043, white_manifest_number 824273). Aggregate at the time
of writing: 81 `customer.work_orders` rows were exposing `derm_address_url`,
some non-zero subset of which are multi-client sheets.

The root issue is structural: **PDF content (whether it's multi-client) is
decoupled from any signal we currently store on the row**. Row-shape gates
will keep failing as the producer changes.

## Decision

### Option 1 — Always hide `derm_manifest_url` (shipped 2026-05-27)

Replace the gate with a hardcoded `NULL::text AS derm_manifest_url` in
`customer.work_orders`. The customer continues to see:

- `derm_manifest_number` (the white form number)
- `wwtp_receipt_url` (the safe-by-design white manifest form)
- `manifest_jurisdiction` (`dade` / `broward`)

…which is enough proof of dump without exposing other clients. The dump-run
address sheet stays accessible to ops via the canonical `derm_manifests.derm_address_url`.

Migration: `docs/migrations/2026-05-27_customer_work_orders_hide_dump_run_sheet.sql`.

### Option 2 — Multi-client sheet flag (deferred follow-up)

Add `derm_manifests.is_multi_client_sheet BOOLEAN` (default `false`), set by
DERM Tracker when the user files >1 client on the same physical sheet. Gate
the view on:

```sql
CASE
  WHEN dm.id IS NULL THEN NULL::text
  WHEN dm.is_multi_client_sheet THEN NULL::text
  ELSE dm.derm_address_url
END AS derm_manifest_url
```

Requires:
1. Migration adding the column + backfill (`UPDATE … SET is_multi_client_sheet = true WHERE id IN (SELECT manifest_id FROM manifest_visits GROUP BY manifest_id HAVING COUNT(DISTINCT v.client_id) > 1)` — but only as best-effort; some single-client manifests may still be multi-client at the PDF level).
2. DERM Tracker UI change: when the user picks >1 client during upload, set the flag.
3. ADR follow-up + this ADR's status updated to "Superseded by 017a".

**Why deferred:** the only known signal today (`COUNT(DISTINCT client_id) via manifest_visits`) misses cases like visit 5079, where the linked visits belong to the same client (GT + CL the same night) but the PDF still rosters other clients. Without a producer-side flag from DERM Tracker, the inference is unsafe. Worth doing once the DERM Tracker UI explicitly captures the multi-client flag at upload time.

### Considered-and-rejected alternative — Per-client redacted sheets

Path B from the original 2026-05-20 brief: DERM Tracker writes per-client
redacted PDFs (`derm/<id>/address-<client_id>.jpg`) and the view serves the
client-specific URL. Rejected for now: requires PDF editing in the browser
(canvas + image black-outs), ~2-3 days of DERM Tracker work, and ops still
needs to see the full sheet. Option 2's boolean flag is the cheaper interim.

## Consequences

### Positive
- Privacy leak closed immediately, zero DB shape change.
- View is now structurally correct (it cannot be wrong, regardless of producer behavior).
- ops retains full access to the dump-run sheet via `public.derm_manifests`.

### Negative
- Customer no longer sees the address page even for legitimate single-client
  dumps. Acceptable trade-off — the white-form receipt + manifest # is enough
  proof and the address page wasn't being shown to most customers anyway
  (only ~81 of 411 work orders before the change).
- Forward path (option 2) needs DERM Tracker UI work + backfill before the
  view can re-expose the address PDF safely.

## Forward work

1. **DERM Tracker UI** — add an `is_multi_client_sheet` flag during upload
   (default true when picking >1 client; user-toggleable for edge cases).
2. **Migration** — add `derm_manifests.is_multi_client_sheet BOOLEAN DEFAULT false`,
   backfill via `manifest_visits` heuristic + manual flagging of known
   multi-client rows.
3. **Replace this view's gate** with the per-row flag. Mark this ADR superseded.
4. **(Optional) Path B** — per-client redacted address PDFs as a UI-level
   feature in DERM Tracker, gated separately. Only if customers ask for it.

## References

- Migration: `docs/migrations/2026-05-27_customer_work_orders_hide_dump_run_sheet.sql`
- Original Path C: `docs/migrations/2026-05-20j_customer_work_orders_pathC_hide_shared_address_pdf.sql`
- Live state pre-fix: `docs/migrations/2026-05-25f_customer_views_public_id.sql`
- Reproduce probe: `docs/gdo-phase-2-2026-05-25/probes/121_verify_work_orders_leak.mjs`
- Apply + verify probe: `docs/gdo-phase-2-2026-05-25/probes/122_apply_work_orders_gate.mjs`
