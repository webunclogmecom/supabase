# Audit — all Calendar / Audit-Trail / Team work shipped 2026-06-25

*Fact-based verification sweep of everything built today, plus the fixes the sweep
surfaced. Terminal state: **GREEN** (no regressions; 2 in-scope fixes applied + verified).*

## Scope audited

| # | Deliverable | Migration / artifact |
|---|---|---|
| 1 | Delete-in-Calendar → delete-in-Jobber | `2026-06-25_propagate_calendar_deletes_to_jobber.sql` |
| 2 | Calendar line-item prices | `2026-06-25_calendar_visit_line_item_prices.sql` + `ops_service_line_items_unit_price.sql` |
| 3 | `edit_calendar_visit` patch RPC (drawer editing) | `2026-06-25_edit_calendar_visit_rpc.sql` |
| 4 | SC line-item push (idempotent) | `jobber-push-visit` `syncVisitLineItems` |
| 5 | Audit Trail Phase 1 (`get_record_history`) | `2026-06-25_audit_trail_phase1.sql` |
| 6 | Audit secret redaction | `2026-06-25_audit_redact_webhook_token_secrets.sql` |
| 7 | App timezone = ET | `2026-06-25_app_timezone_et_audit.md` (doc) |
| 8 | Team multi-select (Driver→Team) | `2026-06-25_visit_team.sql` + edge fn + Lovable |

## Verification results

| Check | Result |
|---|---|
| Function overloads — no 13-arg/14-arg `create_calendar_visit` collision | ✓ exactly **1** signature per schema (public + ops) |
| `create_calendar_visit` signature | ✓ 14 args incl. `p_line_item_prices` + `p_team_ids` |
| `ops` wrappers (`create_calendar_visit`/`edit_calendar_visit`/`get_record_history`) | ✓ all granted anon EXECUTE |
| `ops.service_line_items.unit_price`, `ops.v_visit_team` (+ anon SELECT) | ✓ present |
| Push trigger `fn_push_visit_to_jobber` Origin gate | ✓ present |
| Secret leak in `audit.logs` (token values) | ✓ **0**; `redacted_columns` denylist = 3 |
| `visit_team` table / `team_rev` / `audit_visit_team` / FKs | ✓ all present |
| `get_record_history` whitelist refuses `webhook_tokens` | ✓ **REFUSED** (P0001) |
| **Delete-in-Calendar → Jobber (live)** | ✓ visit 6804 soft-deleted → Jobber "Visit not found" |
| **Team UI end-to-end (live)** | ✓ visit 6813: form→`p_team_ids`→`visit_team`[Aaron,Grecia]→Jobber assignedUsers both |
| **SC line-item push (live)** | ✓ same visit: Jobber lineItems `["12 …","22 - Service Call - Labor"]` |
| Pipeline freshness | ✓ 707 visits / 48h, 0 webhook failures / 6h |

## Fixes applied during the audit

1. **Test-artifact cleanup** — soft-deleted my test visits 6804, 6809, 6810, 6813 (6811/6812
   were already deleted). Legit visit 5654 ("Emergency call [OLD]") preserved. The 6804
   delete doubled as the live delete-propagation test.
2. **`visit_team` backfill** — `2026-06-25_visit_team_backfill_from_driver.sql`: 4 visits
   (6805-6808) had `assigned_driver_id` but no `visit_team` row, so the new drawer would
   show an empty Team. Backfilled → gap now **0**. Non-recurring (inbound doesn't set
   drivers).

## Notes / non-issues

- `audit.logs` `changed_by` is null because the apps use the anon key (per-person
  attribution is Phase 2, data-blocked — needs crew Supabase logins). App-level actor
  labels ("Edited in <app>" / "System") work today.
- The 2 Lovable "security" warnings on publish are the known anon-permissive RLS posture
  (ship-first), accepted.
- `_pdf_render.html` in the repo root is a stray 2026-06-24 render artifact (untracked,
  not committed).
