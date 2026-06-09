# `scripts/migrations/` — FROZEN (pre-2026-05-13 schema migrations)

These `.sql` files are the schema migrations from the **initial build**
(2026-04-13 → 2026-05-13). **This folder is frozen — do NOT add new migrations here.**

➡ **Active migrations now live in [`../../docs/migrations/`](../../docs/migrations/)**
(dated `YYYY-MM-DD<letter>_name.sql`, applied via `scripts/sync/apply_sql.js`).

The files here are kept in place — not moved — because ADRs (`docs/decisions/`),
`docs/duplication-guide.md`, `docs/building-new-apps.md`, and `docs/schema.md` reference
specific files in this directory as the historical record, the from-zero apply order, and
3NF-header templates. Moving them would break those links.

`scripts/probes/full_session_audit.js` checks BOTH this frozen dir and the active
`docs/migrations/` for uncommitted files.
