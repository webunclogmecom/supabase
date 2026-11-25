# DERM visit prints: who printed which visit, on which sheet, when (Trello #248)

Built 2026-11-25. Diego (#new-app-issues, 2026-11-24): *"a status indicator for the DERM manifests, showing either
"Printed" or "Missing Document." Every time someone prints a manifest, the system should automatically update its
status ... avoid accidentally printing the same document twice."* Fred's design picks and "build it" are in
`docs/decisions-to-build.md` (#248).

## What "printed" means

**Pressing Generate (Manifest / address sheet) counts as printed** (Fred's D1). A web page can never tell that paper left
the printer; Generate is the one moment the system sees, and it already allocated and recorded a sheet number every time.
There is no "mark not printed": a sheet that jammed is simply generated again, after the warning.

## The pieces

| piece | what it does |
|---|---|
| `derm.visit_prints` | one row per visit per print: `visit_id`, `sheet_no`, `form_kind` (`derm-v4` / `fdep-62-705.300-3`), `printed_at`, `printed_by` (employee, NULL when not known), `source` (`generate` from 2026-11-25 on, `history` read once). Audited (`audit_visit_prints`). No grant to any API role. |
| history | read once from the registers in the migration: every live Miami-Dade sheet's visits at the sheet's `created_at` (546 rows, 332 visits since 2026-07-28) and every live Broward visit sheet at `generated_at` (112). Their person was never saved, and Broward reprints before 2026-11-25 are not known. |
| `derm.fn_record_prints(visit_ids, sheet_nos, form_kind)` | the only writer. SECURITY DEFINER, `search_path ''`, EXECUTE for `authenticated` only. The person is `hr.fn_access_caller()`, never a request value. A pair is recorded only if the register holds it (Dade: `address_sheets` + `address_sheet_clients`; Broward: `generated_visit_sheets`) and was written in the last 15 minutes; the same pair twice within a minute is recorded once. |
| `derm.v_visit_prints` | the apps' reader (owner rights; SELECT for `authenticated` only, every write revoked): visit, sheet, form, when, source, the person's name and colour, `visits_on_sheet`. No address, email or note. |
| pdf-service 0.9.1 | `/generate/derm-address/preview` answers `X-Printed-Sheets: <visit>:<sheet>,...` on both forms (absent when no number was recorded). A header only: nothing is drawn on the sheet (pdf-service Rule Zero). Tests in `tests/test_fdep_preview_route.py`. |
| edge fn `generate-derm-address-preview` v55 | after the PDF comes back, calls `fn_record_prints` with the CALLER's token (4 s cap, never blocks the PDF, skipped for the server key). |

## Why a log and not the registers

The registers cannot answer it: a Miami-Dade print makes a new sheet (fine), but a Broward reprint RE-USES the visit's
number and its `regenerate_count` also moves when the stored PDF is recorded (two calls per print), so it cannot count
prints; and neither register ever had a person. The registers are unchanged.

## Apps

- Old DERM Tracker (`derm.unclogme.app`): the grey printer box left of Missing Docs, the hover card, the warning before
  Generate. `Building Apps/DERM Tracker/docs/08-changelog.md` 2026-11-25.
- Ops Portal (`/derm/manifests/visits`): FileX for "No manifest yet", the printer after it, the same card and warning;
  the printer and card on the visit page beside "No manifest linked yet". LIVE 2026-11-25 (portal `2f9b447`): the app's
  `docs/modules/derm.md` and Ops Portal `docs/08-changelog.md`.
  Built by the session named Supabase: `Building Apps/Ops Portal/docs/specs/2026-11-25-derm-printed-248-handoff.md`.

## Checks

```sql
-- prints recorded at Generate since the build, with their person
select printed_at, visit_id, sheet_no, form_kind, printed_by from derm.visit_prints where source = 'generate' order by 1 desc limit 20;
-- visits printed more than once (148 on 2026-11-25)
select count(*) from (select visit_id from derm.visit_prints group by 1 having count(*) > 1) x;
```

Rollback: `docs/migrations/2026-11-25_0300_derm_visit_prints_rollback.sql` (ship the apps' rollback first).
