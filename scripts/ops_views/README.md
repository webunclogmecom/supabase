# `ops_views/` — generated snapshots of the live `ops.*` views

Every `*.sql` file here is **auto-generated** from the live database by
[`resync_from_live.js`](resync_from_live.js) (via `pg_get_viewdef`). The folder
mirrors **all 21 `ops.*` views** so you can read/diff them in-repo without
hitting the DB.

## Do not hand-edit the `.sql` files
To change a view: write a migration in `docs/migrations/` that
`CREATE OR REPLACE`s the live view, apply it, then re-mirror the folder:

```
node scripts/ops_views/resync_from_live.js            # dry-run: prints the plan
node scripts/ops_views/resync_from_live.js --execute  # rewrites/creates files
```

The generator is idempotent — re-running against an unchanged DB produces no
diff. It also reports orphans (a file whose view no longer exists live) and
keeps coverage at `N/N`.

## File naming
- **`NN_v_*.sql`** — the original 8 analytical views, kept in their historical
  apply-order numbering (`01`–`08`): `v_ar_aging`, `v_service_due`,
  `v_route_today`, `v_truck_utilization`, `v_gdo_expiry`, `v_derm_compliance`,
  `v_revenue_summary`, `v_driver_kpi`.
- **`<viewname>.sql`** (unnumbered) — views whose canonical edit-source is a
  migration: the Jobber-first **merge views** (`clients`, `properties`,
  `visits`, `vehicles`, `service_configs`, `service_options`, `client_jobs`),
  the **calendar** views (`v_calendar_*`), and **location/billing**
  (`invoice_locations`, `v_billing_by_location`). Mirrored here for reference
  only — edit them via their migration.

## History
Before 2026-06-09 the 8 numbered files were stale older designs — `04`/`06`/`08`
even carried a `v.visit_status = 'COMPLETED'` (uppercase) bug that would
under-report if re-applied (the live views had already been fixed by
`docs/migrations/2026-05-23c_ops_views_completed_casing_fix.sql`). The generator
+ this full snapshot eliminate that drift and keep the folder honest going
forward.
