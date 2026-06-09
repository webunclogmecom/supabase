# 2026-06-09 — Mixed-jurisdiction DERM manifests: DB safety check

**Context.** As of 2026-06-09 the DERM Tracker app (Building Apps session,
`derm.unclogme.app`) relaxed its visit↔manifest linking so **one manifest can
cover both Miami-Dade and Broward client visits**. The jurisdiction (white
manifest # vs yellow ticket #) is decided by the **physical disposal receipt**
the user holds, **not** the client locations — so `visits.county` (via
`properties.county`) can now legitimately differ from its manifest's
jurisdiction (e.g. a Broward client's visit on a Miami-Dade white-# manifest).
The change was **app-only**: the `/upload` selection lock + the County
auto-sync were frontend, and the save still keys `white_manifest_number` /
`yellow_ticket_number` off the **form County**, not per-visit. (Building Apps
`DERM Tracker/CLAUDE.md` rules #8 + #10, commit `5249f53`.)

**Question audited.** Does any DB object (view, trigger/function, constraint,
or probe) assume `visit.county == manifest.jurisdiction`? Such an assumption
would now false-flag legitimate mixed-county manifests.

**Method.** Repo grep (`scripts/probes`, `scripts/ops_views`,
`docs/migrations`) + live-DB introspection on Prod `wbasvhvvismukaqdnouk` via
the Management API (read-only):
- `pg_views`: definitions referencing a jurisdiction signal
  (`white_manifest_number` / `yellow_ticket_number` / `jurisdiction`) **AND**
  `county` → **1 hit** (`public.manifest_detail`).
- `pg_proc` (normal/trigger functions, `prokind='f'`) referencing both → **0 hits**.

**Findings — no coupling exists.**

| Object | Verdict |
|---|---|
| `public.manifest_pickable_visits` (the `/upload` + picker source) | Filters on `visit_status='completed'` + `derm_required` + not-already-linked **only**. Selects `county` for display; **no county/jurisdiction filter**. The picker never coupled them — the old lock was app-side. |
| `public.manifest_detail` (the only live view referencing both terms) | **Display-only** — emits `white_manifest_number` and `p.county AS service_county` as independent output columns; no `WHERE`/comparison ties them. |
| `ops.v_derm_compliance` | References manifest numbers, **not county** (did not appear in the coupling scan). Its "risk" rows match a GT visit to a missing manifest by **`client_id` + service month**, never by county/jurisdiction; `visit_linked` is informational. |
| trigger / RPC functions coupling county + jurisdiction | **none (0)**. |
| `county` probes (`audit_county_vs_at`, `audit_clients_full_vs_at`, `smoke_*_derm`, …) | Property-county **data-quality** checks (DB vs Airtable) + coverage — unrelated to manifests. |
| OCR scripts (`calibrate_ocr_receipts`, `ocr_derm_receipts_for_number_and_date`, `lib/receipt_ocr_prompts`) | Derive jurisdiction **from the receipt itself** (`yellow_ticket_number ? 'broward' : 'dade'`), never from the visit's county. Correct under the new rule. |

**Conclusion.** The DB has always treated `jurisdiction` (per-manifest, derived
from the white/yellow number) and `county` (per-property) as **independent**.
The pre-2026-06-09 single-jurisdiction lock was purely an app-side UX guardrail;
**no schema, view, trigger, constraint, or probe enforced or assumed
alignment.** The mixed-jurisdiction change is **DB-safe — no migration or probe
change required.**

*Audited from the Building Apps session at Fred's request (the Supabase session
was occupied). Read-only introspection — no DB mutation performed.*
