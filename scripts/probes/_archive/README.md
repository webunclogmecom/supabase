# Archive — one-off migration runners

These scripts each ran a single SQL migration from `scripts/migrations/` and
verified the result. After successful execution they have no further use —
the corresponding `.sql` files are preserved in `scripts/migrations/` and
are the canonical record of what was applied.

Kept here for reference in case you ever need to see the exact JS-side
verification logic that was paired with a migration.

If you need to apply a migration again, write a fresh script. Don't re-run
these — most assume specific pre-state that no longer exists.

Files moved here on 2026-05-11.
