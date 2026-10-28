# RLS on every app table, and on every new one (Trello FFSF71BI)

> **BUILT 2026-10-28 18:04 ET:** `docs/migrations/2026-10-28_1804_rls_on_every_app_table.sql` (rollback beside it).
> Results: advisor `rls_disabled_in_public` 17 -> 0; catalogue diff = 49 RLS flags + 1 policy + 1 event trigger,
> nothing else; as `authenticated` (and as Fred's own identity through `fn_request_gate`) every dependent view and 5
> read RPCs unchanged, the 16 unpolicied tables read 0 rows, `page_slots` unchanged. Three views differed only by live
> drift (proven: postgres and authenticated hashes equal at the same instant). Found in passing, not changed:
> `derm.v_band_edge_check`, `v_band_edges_off_rule` and `v_cards_awaiting_page_map` already refuse `authenticated`
> (42501 on `derm.fn_sheet_image_position`), before and after.
> **Live check 2026-10-28 with Fred signed in**, 1440 and 375: Stamp Studio sheet 934861 (its `page_slots` request 200
> with the 6 rows in the DB; a direct `address_row_map` read through the real API 200 with 0 rows), DERM Tracker
> (Visits, Manifests), Visit Calendar, Admin Review: every request 200, no sideways scroll, counts as in the DB.
> Not live-checked: HR App, Client App, Picture Planner, Field Portal (they read none of the 17 tables directly, and
> the 32 other tables grant app roles nothing, so RLS cannot change what they return). Card FFSF71BI in Testing / QA
> 2026-10-28, every item ticked.

*2026-10-28. Card: "Fix Supabase critical security alert: RLS disabled on public tables". Supabase emailed
web@unclogme.com on 2026-10-20 and again on 2026-10-27 (issues as of 10-25): `rls_disabled_in_public`,
"Table publicly accessible", project `wbasvhvvismukaqdnouk`. The email names no tables.*

## What the alert is, measured

The lint flags a table when **all three** hold: it sits in a schema PostgREST exposes (`public, graphql_public,
customer, derm, ops, client, hr`), RLS is off, and `anon` or `authenticated` holds SELECT on it. Live advisor
on 2026-10-28: **17 tables**, 12 `derm`, 2 `ops`, 3 `public`.

| Who can reach them | Measured |
|---|---|
| `anon` | nothing on any of the 17 |
| `authenticated` (any signed-in staff user) | SELECT on all 17; also TRUNCATE, REFERENCES, TRIGGER on `public.dump_sites` and `public.derm_required_backfill_snapshot_2026_06_24` |
| `service_role`, `postgres`, `db_backup_reader` | BYPASSRLS: not affected by RLS at all |

A further **32 tables** in the same six schemas have RLS off but grant `anon` / `authenticated` nothing, so the
lint ignores them and only the grants keep them closed (root `CLAUDE.md`: never let the grant be the only line).

## Who uses the 17 (every consumer checked)

- **Views:** 30+ views read them (`derm.manifests`, `derm.v_stamp_rows`, `public.visits_with_review`,
  `ops.v_client_call_policy`, ...). Every one is owner-rights (no `security_invoker`) and owned by `postgres`,
  which has BYPASSRLS, so RLS on the base table changes nothing they return.
- **Functions:** every function that names one of the 17 is SECURITY DEFINER owned by `postgres`, except the
  trigger function `derm.trg_generated_sheet_complete`. It fires only on `derm.address_row_map` writes, which
  `authenticated` cannot make (SELECT only), so it always runs as `postgres` or `service_role`.
- **Edge functions, pdf-service, GDO bot:** all use the service_role key (`ocr-address-sheet-number`,
  `ocr-address-sheet-rows`, `calculate-driving-time`, `pdf_service/supabase_client.py`).
- **Live app bundles** (calendar, derm, fp, hub, clients, dump, admin, reviews, hr, stamp, planner): only
  **DERM Stamp Studio** names any of them. It reads `derm.page_slots` directly
  (`.from('page_slots').select('slot_index,y0_pct,y1_pct')`, seen in `pg_stat_statements` as `authenticated`),
  and subscribes to `inval:address_row_map`, which is a **private broadcast channel** fed by
  `public.tg_broadcast_inval` (SECDEF) and authorised by `realtime.messages` policies, not by table RLS.
- The Sales App named on the card is a different Supabase project (`qyvagxgaggzqyivqfbrj`); not affected.

## Fred's pick (2026-10-28)

New tables: **"Turn it on automatically"** (over a daily alert, or relying on Supabase's weekly email).

## Design

One migration, rollback beside it:

1. `ENABLE ROW LEVEL SECURITY` on all **49** RLS-off tables in `public, derm, ops, client, customer, hr`
   (explicit list). Not FORCE: the owner keeps bypassing, as on every other table.
2. One policy, `derm.page_slots_staff_read`: SELECT to `authenticated` USING (true), the same shape as
   `derm.generated_visit_sheets_staff_read`. The per-app access gate (`fn_request_gate`) still runs first.
3. Event trigger `rls_auto_enable` on `ddl_command_end` for `CREATE TABLE`, `CREATE TABLE AS`, `SELECT INTO`:
   enables RLS on any new table in those six schemas (`not in_extension`). Function
   `public.rls_auto_enable()`, `search_path` pinned, EXECUTE revoked from PUBLIC / anon / authenticated.
   A table an app must read directly then needs a policy, written in the same migration.

Not done, on purpose:
- No grant changes. The other 16 tables keep their unused `authenticated` SELECT: with RLS on and no policy it
  returns 0 rows. TRUNCATE held by `authenticated` on 18 app tables is not reachable through PostgREST (it has no
  TRUNCATE), so it is left as is.
- The 141 `security_definer_view` ERRORs in the advisor are the schema-per-app pattern (owner-rights views by
  design) and are not in Supabase's email. Out of scope.

## Plan and checks

| Step | Check |
|---|---|
| Guard | exactly 49 RLS-off tables in the six schemas, no policy on `page_slots`, no `rls_auto_enable` yet; else abort |
| Apply | `lock_timeout = 3s`, so a held lock makes it fail instead of queueing app reads |
| VERIFY (inside) | 0 RLS-off tables left; the policy exists for `{authenticated}`; a table created in `public` comes out RLS on (dropped again); as `authenticated`: `page_slots` > 0 rows, `address_row_map` = 0 rows, `derm.v_stamp_rows` > 0 rows |
| Rehearsal (rolled back) | as `authenticated`, row counts of every readable view over the 17, `page_slots`, and 4 read RPCs identical before / after; control: a table created before the trigger exists stays RLS off |
| Rollback rehearsal | apply + rollback in one rolled-back transaction ends at the measured 49 / 0 policy / no trigger |
| After commit | nothing else moved: RLS flags of every table in every schema, every policy and every event trigger, compared before / after |
| Advisor | Management API `advisors/security`: `rls_disabled_in_public` = 0 |
| Visual (live, 1440 and 375) | Stamp Studio sheet with page slots, DERM Tracker, Visit Calendar, Admin Review: every request HTTP 200, counts as before |
| Standing check | `scripts/checks/rls_on_app_tables.sql`: one row `ok`, else names the table or the missing trigger |
