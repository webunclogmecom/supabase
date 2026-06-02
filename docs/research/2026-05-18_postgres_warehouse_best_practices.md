# PostgreSQL / Supabase Operational-Warehouse Best Practices

**Compiled:** 2026-05-18
**Scope:** Industry practices from first-party engineering blogs (Stripe, Shopify, Notion, GitLab, Supabase, Crunchy Data, pganalyze, PlanetScale, Heroku) and the official PostgreSQL wiki. URLs verified via WebFetch unless noted otherwise.

The 15 sections below are deliberately framed as the *industry* practice with the source link; fit evaluation is left to the parent session.

---

### 1. Normalization in operational warehouses (3NF vs intentional denormalization)

**The practice:** Start fully normalized (3NF/BCNF) in OLTP/operational systems; denormalize only when a specific access pattern is *measurably* expensive after correct indexing.

**Why it matters:** Normalized schemas keep writes correct and avoid update anomalies — the dominant concern in operational systems. Denormalization optimizes specific reads but multiplies the surface area for inconsistency, and indexing typically closes most of the read-speed gap for free.

**Evidence:**
- [Elysiate — PostgreSQL Normalization vs Denormalization Guide](https://www.elysiate.com/blog/postgresql-normalization-vs-denormalization-guide) — "Normalize first unless you have a clear reason not to. Denormalize only when a real access pattern justifies it."
- [Truong Nguyen — Engineer's Guide to Normalization vs Denormalization (Medium)](https://medium.com/@truongtud90/normalization-vs-denormalization-the-engineers-complete-guide-to-database-design-trade-offs-ab2ac1983a58) — "Proper indexing on a normalized schema closes 85% of the performance gap for free."
- [Shopify Engineering — Under Deconstruction: The State of Shopify's Monolith](https://shopify.engineering/shopify-monolith) — Cautions that grouping code/tables purely by "informational cohesion" (same data) drifts away from modularity; functional cohesion is preferred.

**Caveats / when it doesn't apply:** Read-heavy analytics dashboards may justify a denormalized materialized view downstream — but the base tables should still be normalized.

---

### 2. Audit-trail patterns (pgaudit, supa_audit, trigger-based, append-only event logs)

**The practice:** For row-level history on a small/medium operational DB, use trigger-based row audit (e.g. `supa_audit`) writing JSONB into a single `audit.record_version` table with a BRIN index on the timestamp. For compliance-grade auditing at scale, use `pgaudit` (logs to Postgres log files, not into tables). Audit tables should be append-only (revoke UPDATE/DELETE on the role that writes them).

**Why it matters:** Triggers give you queryable, application-visible history with very little code. `pgaudit` produces the compliance artifacts that auditors expect but is operationally heavier. The two are complementary, not interchangeable.

**Evidence:**
- [Supabase — Postgres Auditing in 150 lines of SQL](https://supabase.com/blog/postgres-audit) — "For throughput less than 1000 writes per second the overhead is typically negligible." (BRIN on the `ts` column.)
- [pganalyze — pgAudit vs supa_audit (5mins of Postgres E8)](https://pganalyze.com/blog/5mins-postgres-auditing-pgaudit-supabase-supa-audit) — "If you're doing high concurrent writes then you will notice that the trigger overhead is a problem."
- [Supabase Docs — pgaudit](https://supabase.com/docs/guides/database/extensions/pgaudit) — pgAudit "selectively tracks activities within your database" via Postgres logs; use cautiously to avoid log volume.
- [postgresql-event-sourcing (reference repo)](https://github.com/eugene-khyst/postgresql-event-sourcing) — "Events are immutables, so SQL UPDATE and DELETE statements are not used."

**Caveats:** Trigger-based audit becomes a write-amplification problem above ~1k writes/sec on the audited table; at that point switch the hot table to pgAudit or a streaming CDC approach.

---

### 3. RLS at scale + anon-write surface design

**The practice:** Every RLS policy needs (a) indexes on the columns referenced in the policy, (b) `(select auth.uid())` instead of bare `auth.uid()` so Postgres caches the value as an initPlan, (c) explicit `TO authenticated` (or `TO anon`) targeting to avoid evaluating policies for roles that can't reach the table, and (d) explicit `WHERE` filters in queries — policies are *additional* filters, not a substitute for query selectivity.

**Why it matters:** RLS executes per-row. A naive policy turns every SELECT into a sequential scan + per-row function call. The `(select auth.uid())` wrapping and targeted indexes are the single biggest wins reported in benchmarks (>100× on large tables).

**Evidence:**
- [Supabase Docs — RLS Performance and Best Practices](https://supabase.com/docs/guides/troubleshooting/rls-performance-and-best-practices-Z5Jjwv) — "Add indexes on any columns used within the Policies which are not already indexed."
- [Supabase Docs — Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security) — Wrapping `auth.uid()` in a SELECT yielded "94.97% improvements in execution speed" on their benchmarks.
- [Makerkit — Supabase RLS Best Practices](https://makerkit.dev/blog/tutorials/supabase-rls-best-practices) — Recommends `security definer` helper functions to bypass RLS recursion on join tables.

**Caveats:** `security definer` functions must NEVER live in a schema exposed via the PostgREST API — they run as the function owner and can leak rows.

---

### 4. Multi-tenant / multi-app schema isolation (schema-per-app vs DB-per-app vs shared-schema)

**The practice:** For SaaS multi-tenancy, **shared-schema with `tenant_id` + RLS is the industry default**. Schema-per-tenant is viable up to a few hundred tenants but has catalog overhead. Database-per-tenant breaks Postgres's connection model (PgBouncer pools per-database, exhausts `max_connections` fast). For separating *apps* (not tenants) inside one Postgres cluster, schema-per-app (e.g. `public` for canonical 3NF, then `customer`, `ops`, `field`, `sales` per app) is a clean pattern.

**Why it matters:** Postgres was designed for a small number of databases and a moderate number of schemas. Tens of thousands of either degrades the system catalog, ANALYZE/pg_dump runtimes, and pooler behavior.

**Evidence:**
- [PlanetScale — Approaches to Tenancy in Postgres](https://planetscale.com/blog/approaches-to-tenancy-in-postgres) — "Shared-schema is the most common and is our recommended approach"; schema-per-tenant "likely won't scale beyond a few hundred tenants."
- [Aditya Agrawal — SaaS Multi-Tenancy on Postgres Patterns](https://www.adiagr.com/blog/07-saas-postgres-multitenancy-patterns/) — Compares the three patterns; flags connection-pool exhaustion as the DB-per-tenant killer.
- [Bytebase — Multi-Tenant Database Architecture Patterns](https://www.bytebase.com/blog/multi-tenant-database-architecture-patterns-explained/) — Notes 60-80% lower onboarding cost in shared-schema vs DB-per-tenant.

**Caveats:** Strict regulatory isolation (HIPAA, PCI in some interpretations) may force DB-per-tenant despite the operational cost.

---

### 5. Soft-delete patterns vs hard-delete + retention

**The practice:** Soft delete (`deleted_at TIMESTAMPTZ`) is widely used but increasingly questioned. The favored alternative is **hard delete with a `deleted_record` archive table** (JSONB blob keyed by original table + id + `deleted_at`). Add RLS or partial indexes filtered on `deleted_at IS NULL` if you keep soft delete, and run a periodic purge for GDPR compliance.

**Why it matters:** `deleted_at IS NULL` filters leak into every query — one forgotten predicate leaks deleted data. Foreign keys also misbehave (you can soft-delete a parent without cascading to children).

**Evidence:**
- [brandur.org — Soft Deletion Probably Isn't Worth It](https://brandur.org/soft-deletion) — Recommends a single `deleted_record` JSONB table over per-table `deleted_at`; in 10+ years he never saw undelete used in practice.
- [Evil Martians — Soft deletion with PostgreSQL, but with logic on the database](https://evilmartians.com/chronicles/soft-deletion-with-postgresql-but-with-logic-on-the-database) — Use partial unique indexes (`WHERE deleted_at IS NULL`) so uniqueness only applies to live rows.
- [Bemi — The Day Soft Deletes Caused Chaos](https://blog.bemi.io/soft-deleting-chaos/) — Real incident report of soft-delete leaks in production queries.

**Caveats:** Soft-delete is reasonable when undelete is a real, frequent user-visible feature (e.g., Gmail trash) — not when it's "just in case."

---

### 6. Idempotent upserts (`ON CONFLICT`) and webhook idempotency

**The practice:** Every webhook handler and every external-event ingest path should be idempotent. Use `INSERT … ON CONFLICT (external_id) DO UPDATE SET …` keyed by the *source's* event ID (e.g. Stripe `evt_…`). For multi-step handlers, use Brandur's pattern: an `idempotency_keys` table with `recovery_point` phases, atomic phases committed under SERIALIZABLE isolation, request-hash comparison on retry.

**Why it matters:** Webhooks are at-least-once by design. A non-idempotent handler double-charges, double-emails, or double-inserts. The cost of getting it right once is small; the cost of getting it wrong recurs forever.

**Evidence:**
- [brandur.org — Implementing Stripe-like Idempotency Keys in Postgres](https://brandur.org/idempotency-keys) — "Atomic phases should be safely committed *before* initiating any foreign state mutation."
- [Stripe — Designing robust and predictable APIs with idempotency](https://stripe.com/blog/idempotency) — "You can safely retry it with the same idempotency key, and the customer is charged only once."
- [Hookdeck — How to Implement Webhook Idempotency](https://hookdeck.com/webhooks/guides/implement-webhook-idempotency) — Use the source event ID as the conflict key; reject mismatched payloads with the same key.

**Caveats:** `ON CONFLICT` requires a unique constraint to target. If your source emits a stable ID, lift that to a `UNIQUE` column; don't rely on `(date, type)` heuristics.

---

### 7. Source-agnostic schema design (avoid source-prefixed columns)

**The practice:** Business tables should describe the *domain entity*, not the *source system*. Names like `jobber_id`, `airtable_email`, `stripe_status` create permanent coupling to today's vendor. Instead, model the canonical entity (`clients.email`, `clients.status`) and put source-system references in a separate bridge/identity table (`client_external_ids(client_id, source, external_id)`). This is the "canonical data model" pattern from enterprise integration.

**Why it matters:** Source systems get swapped, sunset, or merged. A source-prefixed schema either rots or grows duplicate columns each migration. A canonical schema lets you swap the ingest layer without touching downstream apps.

**Evidence:**
- [DZone — The Right ETL Architecture for Multi-Source Data Integration](https://dzone.com/articles/etl-architecture-multi-source-data-integration) — A canonical data model "ensures transformations are uniform across sources" and decouples downstream from upstream.
- [Agility at Scale — Canonical Data Model: The Enterprise Integration Pattern](https://agility-at-scale.com/ai/architecture/canonical-data-model/) — CDM as a stable internal contract that "isolates each system from changes in others."
- [End Point Dev — Database Design: Using Natural Keys](https://www.endpointdev.com/blog/2021/03/database-design-using-natural-keys/) — Recommends keeping the natural/external key as `UNIQUE NOT NULL` adjacent to a surrogate PK — never as the PK itself.

**Caveats:** Staging/landing tables in an ETL pipeline *should* mirror the source 1:1 (raw zone). The canonical schema lives one layer downstream.

---

### 8. Bridge tables / cross-source identity (instead of polymorphic associations)

**The practice:** Use **explicit bridge tables** (`entity_external_ids` with `entity_type`, `entity_id`, `source`, `external_id`) or **separate per-type tables** rather than polymorphic columns (`commentable_id` + `commentable_type`). Polymorphic columns can't have a real foreign key, lose referential integrity, and confuse the planner.

**Why it matters:** Polymorphic associations look elegant but every integrity guarantee Postgres gives you depends on real FKs. Without them, you can orphan rows silently and the planner can't use selectivity statistics across the type column.

**Evidence:**
- [GitLab Docs — Polymorphic Associations](https://docs.gitlab.com/development/database/polymorphic_associations/) — "Always use separate tables instead of polymorphic associations."
- [Hashrocket — Modeling Polymorphic Associations in a Relational Database](https://hashrocket.com/blog/posts/modeling-polymorphic-associations-in-a-relational-database) — Walks through the "exclusive arc" with `CHECK (num_nonnulls(...) = 1)` if you absolutely must.
- [Cybertec — Conditional foreign keys and polymorphism in SQL: 4 Methods](https://www.cybertec-postgresql.com/en/conditional-foreign-keys-polymorphism-in-sql/) — Four PG-specific patterns when polymorphism is unavoidable; all use CHECK constraints to preserve integrity.

**Caveats:** If the *number* of types is large and unbounded (user-defined), per-type tables stop scaling and a JSONB attribute on a single table may be the lesser evil.

---

### 9. Time-series + partition management (pg_partman + pg_cron)

**The practice:** For append-mostly time-series tables (audit logs, telemetry, events) **above the multi-GB / multi-TB range**, range-partition by time and let `pg_partman` + `pg_cron` create/detach partitions automatically. Below ~200GB, partitioning typically adds more complexity than it removes.

**Why it matters:** Partitioning makes retention free (`DETACH PARTITION` is metadata-only), prunes index size, and lets vacuum work per-partition. But it adds operational complexity (unique-constraint columns must include the partition key) and is a one-way migration for a live system.

**Evidence:**
- [Crunchy Data — Partitioning with Native Postgres and pg_partman](https://www.crunchydata.com/blog/native-partitioning-with-postgres) — "Do you need to partition a 200GB database? Probably not."
- [Supabase Docs — pg_partman: partition management](https://supabase.com/docs/guides/database/extensions/pg_partman) — Recommends scheduling `partman.run_maintenance_proc()` via `pg_cron`.
- [Supabase Docs — Partitioning tables](https://supabase.com/docs/guides/database/partitions) — "Partitions introduce complexity, and complexity should be avoided until it's needed."

**Caveats:** Hash partitioning is rarely the right answer; pick range (time/id) or list (region/tenant). Sub-partitioning is almost always overkill.

---

### 10. Index strategy for read-heavy operational dashboards

**The practice:** For dashboard queries, build composite btree indexes with **equality columns leading, range/sort columns trailing**, optionally with `INCLUDE` for index-only scans. Add partial indexes for filtered queries (`WHERE flagged = true`). Build indexes with `CREATE INDEX CONCURRENTLY` to avoid table locks. Audit unused indexes regularly — they have a write cost.

**Why it matters:** Most OLTP latency problems are missing or mis-shaped indexes. Each extra index slows down writes proportionally, so over-indexing is also a real problem; the right answer is a small, query-shaped set.

**Evidence:**
- [Heroku Dev Center — Efficient Use of PostgreSQL Indexes](https://devcenter.heroku.com/articles/postgresql-indexes) — Use `CREATE INDEX CONCURRENTLY` on production; partial indexes "with a WHERE clause" reduce size and maintenance.
- [pganalyze — How we built the pganalyze Indexing Engine](https://pganalyze.com/blog/automatic-indexing-system-postgres-pganalyze-indexing-engine) — "Creating the right indexes on your database requires thought and detailed analysis." Tradeoff: scan cost vs. write overhead.
- [Mydbops — PostgreSQL Index Best Practices](https://www.mydbops.com/blog/postgresql-indexing-best-practices-guide) — "Leading columns should be equality predicates, trailing columns range predicates or sort keys."

**Caveats:** Don't index for queries you don't run. `pg_stat_user_indexes` shows unused indexes — drop them.

---

### 11. Migration discipline (forward-only, append-only DDL)

**The practice:** Migrations should be **forward-only** (no `down`-as-a-feature in production) and **expand-then-contract**: add the new column/table, dual-write, backfill async, switch reads, then drop the old. Never combine DDL and DML in the same migration. Use `CREATE INDEX CONCURRENTLY` and `ALTER TABLE … ADD COLUMN … NULL` (not NOT NULL with a default on a populated table on older PG versions). No migration should require downtime.

**Why it matters:** A single non-concurrent index build on a hot table can lock the application for minutes. Mixing DDL and DML makes rollback impossible. Expand-then-contract is the industry pattern for shipping schema changes with live traffic.

**Evidence:**
- [GitLab Docs — Migration Style Guide](https://docs.gitlab.com/development/migration_style_guide/) — "Migrations are *not* allowed to require GitLab installations to be taken offline ever." Separates DDL from DML migrations.
- [Stripe — Online migrations at scale](https://stripe.com/blog/online-migrations) — "All our changes were incremental. We never attempted to change thousands of lines of code at once." The 4-step pattern: dual-write → change reads → change writes → drop old.
- [Stripe — pg-schema-diff (GitHub)](https://github.com/stripe/pg-schema-diff) — Tool that "computes differences between Postgres schemas and generates SQL required to migrate with minimal downtime & locks."

**Caveats:** Cosmetic migrations (renaming a column) still need expand-then-contract — the rename itself blocks until clients are off the old name.

---

### 12. Connection pooling for serverless / edge functions

**The practice:** Serverless functions (Vercel, Supabase Edge Functions, AWS Lambda) must connect through a **transaction-mode pooler** (Supavisor or PgBouncer), not directly. Use port 6543 (transaction mode) for app queries, port 5432 (direct/session) only for migrations. Disable prepared statements in your client driver — transaction mode doesn't preserve them across the pool.

**Why it matters:** Each serverless invocation can open its own connection. Without pooling, a few hundred concurrent invocations exhaust Postgres's `max_connections` (default 100) and the database refuses new clients.

**Evidence:**
- [Supabase Docs — Connect to your database](https://supabase.com/docs/guides/database/connecting-to-postgres) — "Serverside-poolers sit between clients and the database and can be thought of as load balancers for Postgres connections." Use port 6543 for serverless.
- [Supabase Blog — PgBouncer is now available in Supabase](https://supabase.com/blog/supabase-pgbouncer) — "Serverless functions create a new database connection for each concurrent request, potentially overwhelming Postgres."
- [Circleback — How we fixed Postgres connection pooling on serverless with PgDog](https://circleback.ai/blog/how-we-fixed-postgres-connection-pooling-on-serverless-with-pgdog) — Real-world write-up of the serverless-PG mismatch.

**Caveats:** Long-running connections (LISTEN/NOTIFY, advisory locks, prepared statements, `SET LOCAL`) all break in transaction mode. Use session mode (port 5432 via Supavisor) for those workloads.

---

### 13. Updated_at trigger management

**The practice:** Use a **single reusable trigger function** (`set_updated_at_to_now()`) and attach it via `BEFORE UPDATE FOR EACH ROW` triggers on every table with an `updated_at TIMESTAMPTZ NOT NULL DEFAULT now()` column. Don't rely on the application to set `updated_at` — applications forget, and direct-SQL fixes from operators won't go through the app at all.

**Why it matters:** `updated_at` is load-bearing for change-data-capture, sync workers, cache invalidation, and audit queries. A row that updates without bumping `updated_at` is invisible to downstream systems.

**Evidence:**
- [Hasura Docs — Postgres: Adding created_at / updated_at Timestamps](https://hasura.io/docs/2.0/schema/postgres/default-values/created-updated-timestamps/) — Canonical pattern: `CREATE FUNCTION trigger_set_timestamp() … BEFORE UPDATE FOR EACH ROW EXECUTE FUNCTION …`.
- [Blue Label Labs — Use PostgreSQL Triggers to Automate Creation & Modification Timestamps](https://www.bluelabellabs.com/blog/how-to-use-postgresql-trigger-functions-to-automate-creation-and-last-modification-timestamps/) — One reusable function per database; attach via per-table triggers.
- [The Art of Web — PostgreSQL trigger for updating last modified timestamp](https://www.the-art-of-web.com/sql/trigger-update-timestamp/) — Includes `WHEN (OLD.* IS DISTINCT FROM NEW.*)` guard so no-op UPDATEs don't bump the timestamp.

**Caveats:** If you use logical replication or CDC tools that already see the change, the trigger is still worth keeping for human-driven SQL.

---

### 14. Materialized views vs regular views

**The practice:** Use **regular views** when you need real-time correctness and the underlying query is cheap. Use **materialized views** for expensive aggregations on slowly-changing data, refreshed via `pg_cron` (or trigger-based refresh on critical paths). Materialized views require a unique index for `REFRESH MATERIALIZED VIEW CONCURRENTLY`.

**Why it matters:** Materialized views trade freshness for read speed. They're a sharp tool: full refresh cost scales with total data size, not the changed delta — so refreshing a 100M-row view to update 500 rows still scans all 100M.

**Evidence:**
- [PostgreSQL Docs — REFRESH MATERIALIZED VIEW](https://www.postgresql.org/docs/current/sql-refreshmaterializedview.html) — `CONCURRENTLY` requires a unique index; otherwise refresh holds an `ACCESS EXCLUSIVE` lock.
- [Epsio — Postgres Materialized Views: Basics, Tutorial, and Optimization Tips](https://www.epsio.io/blog/postgres-materialized-views-basics-tutorial-and-optimization-tips) — Use for "complex queries that are expensive to compute repeatedly" and "reporting and analytics requiring quick access."
- [RisingWave — PostgreSQL Materialized Views: An Overview](https://risingwave.com/blog/postgresql-materialized-views-an-overview/) — Full refresh "cost scales with total data size, not change size."

**Caveats:** For genuinely real-time aggregates on high-write tables, neither view type is right — use a streaming MV solution (RisingWave, ReadySet, Materialize) or pre-aggregate on write via triggers.

---

### 15. Timestamp + money column conventions

**The practice:** **Always `TIMESTAMPTZ` for timestamps**, stored as UTC, with timezone conversion at the display layer. **Always `NUMERIC(precision, scale)` for money** (typical `NUMERIC(19, 4)`) — never `float`, never the Postgres `money` type. Store the currency code as a separate ISO 4217 column if multi-currency. Avoid `char(n)` for any purpose. Avoid `TIME` without a date.

**Why it matters:** `TIMESTAMP` (without time zone) silently drops the offset and corrupts arithmetic across DST boundaries. `money` is locale-dependent and can't store fractional cents. `float` accumulates rounding errors that show up as $0.01 invoice discrepancies.

**Evidence:**
- [PostgreSQL Wiki — Don't Do This](https://wiki.postgresql.org/wiki/Don't_Do_This) — `money` "doesn't store a currency with the value." `char(n)` "doesn't reject values that are too short, it just silently pads them with spaces."
- [Crunchy Data — Working with Time in Postgres](https://www.crunchydata.com/blog/working-with-time-in-postgres) — "TIMESTAMPTZ is going to be the MVP of Postgres time storage." Store in UTC, convert at display.
- [Crunchy Data — Working with Money in Postgres](https://www.crunchydata.com/blog/working-with-money-in-postgres) — "Numeric is widely considered the ideal datatype for storing money in Postgres."

**Caveats:** If you have a strict whole-cent rule and need maximum throughput, `BIGINT` cents (1234 = $12.34) is a valid pattern — convert at the display layer.

---

## Bonus: ENUM vs CHECK constraint vs lookup table

Not one of the 15 numbered topics, but a recurring decision in operational schema work.

**The practice:** Prefer **CHECK constraint on a text column** over native `ENUM` for evolvable status fields. ENUM changes acquire `ACCESS EXCLUSIVE`; CHECK validation runs at the more permissive `SHARE UPDATE EXCLUSIVE`. Use a **lookup table with FK** when the set has metadata (display name, color, ordering) or is genuinely large/dynamic.

**Evidence:**
- [Crunchy Data — Enums vs Check Constraints in Postgres](https://www.crunchydata.com/blog/enums-vs-check-constraints-in-postgres) — "If you're thinking about enums, do a test drive of the CHECK constraint."
- [Cybertec — What is better: a lookup table or an enum type?](https://www.cybertec-postgresql.com/en/lookup-table-or-enum-type/) — Lookup tables fit when the set has attributes; enums for static value sets that never change.
- [Close — Native enums or CHECK constraints in PostgreSQL?](https://making.close.com/posts/native-enums-or-check-constraints-in-postgresql/) — Some teams prefer CHECK precisely because the migration story is gentler.

---

## Topics deliberately not included

- **Sharding** (Notion-style 480 logical shards) — researched but excluded from the main list because it's irrelevant at multi-GB scale; included here as evidence that Notion didn't shard until VACUUM stalled and they faced transaction-ID wraparound: [Notion — Herding elephants: lessons learned from sharding Postgres at Notion](https://www.notion.com/blog/sharding-postgres-at-notion).
- **CDC at sharded-monolith scale** — Shopify's pattern is well-documented but operationally out of band for a single-tenant DB: [Shopify Engineering — Capturing Every Change From Shopify's Sharded Monolith](https://shopify.engineering/capturing-every-change-shopify-sharded-monolith).

These two are real, but the practices that apply at petabyte scale aren't necessarily the practices you want at gigabyte scale. They appear here as context, not prescription.
