# ADR-016 — Audit Log App-Source Attribution

**Status:** Accepted (2026-05-23)
**Deciders:** Fred Zerpa
**Supersedes:** Extends ADR-010 (Audit Trail Architecture); not a replacement.

## Context

ADR-010 shipped a three-layer audit trail. Layer 2 (`audit.logs`) captures every write to 11 business tables with `old_row` / `new_row` JSONB diffs. Forensic questions like *"when did this client's GDO expiration change?"* are now answerable.

But: **today every write is attributed to `db_role='postgres'` with `changed_by=NULL` and `jwt_claims=NULL`.**

Root cause:

- All four customer-facing apps (Field Portal, Admin Review, DERM Tracker, Visit Calendar) run on **anon JWTs with no `sub` claim** — there's no user-level auth yet (Phase 2 deferred per ADR-010).
- The trigger function reads `request.jwt.claim.sub` and `request.jwt.claims` — both empty for anon requests, so both columns stay null.
- The `db_role` column captures `CURRENT_USER`, which is the underlying connection role (`postgres` for almost everything that goes through PostgREST, since the SECURITY DEFINER trigger runs as the function owner).

The forensic gap surfaced concretely on 2026-05-23 during a drift audit:

> *"Did Yannick mark v5088 as DERM not required, or was it a stale flag from a backfill script?"*

The audit log showed `db_role=postgres, changed_by=NULL, jwt_claims=NULL` — indistinguishable. The only signal was **microsecond timestamp clustering**: 115 rows updated at the exact same `changed_at` strongly suggested a single bulk operation, likely via the DERM Tracker UI's bulk-select-then-click flow. But that's inference, not evidence.

**Goal**: capture enough request context that "which app made this write?" is directly readable from the audit row, without requiring user-level auth.

### Non-negotiable constraints

1. **No app-side breaking changes.** Whatever ships must work for existing Lovable apps without redeploying them.
2. **Defensive trigger.** `audit.log_change` is `SECURITY DEFINER` and fires on every write. A null-safety bug there would brick the canonical DB.
3. **No new external dependencies.** Postgres + PostgREST settings only.
4. **Forward-compatible with Phase 2 auth.** When user-level JWTs ship, `changed_by` should populate automatically without another migration.
5. **Selective payload.** Don't log `Authorization` / `Cookie` / full `User-Agent` — that's PII / token leak risk inside an internal table.

## Decision

**Adopt Option C (Hybrid — Origin-derived + optional explicit override).**

- Add `audit.logs.app_source TEXT` (nullable, indexed) — one of `derm-tracker` / `field-portal` / `admin-review` / `visit-calendar` / `sql` / `other:<host>` / `NULL`.
- Add `audit.logs.request_context JSONB` (nullable) — curated subset of request metadata: `{ origin, referer, method, path, app_source_hint }`. Excludes auth/cookie headers.
- Update `audit.log_change()` to populate both columns defensively (every read wrapped in `NULLIF + try-cast`).
- Keep `jwt_claims` as-is — it'll populate automatically when Phase 2 auth ships.
- **Lovable apps optionally** set `X-App-Source: <name>` header in their supabase client. When set, it overrides the Origin-derived value. Not required to deploy this ADR.

Origin → app_source mapping (initial):
| Origin substring | app_source |
|---|---|
| `derm.unclogme.app` | `derm-tracker` |
| `fp.unclogme.app` | `field-portal` |
| `*.lovable.app` w/ `grease-buddy-dash` | `admin-review` |
| `*.lovable.app` w/ Visit Calendar project ID `6533c3ee` | `visit-calendar` |
| any other origin | `other:<host>` |
| no origin (direct SQL) | `sql` |

The fallback `other:<host>` preserves the actual origin so future apps surface immediately even before the mapping is updated.

## Options Considered

### Option A — Origin header only

Read `current_setting('request.headers', true)::jsonb->>'origin'`, map subdomain → app name.

| Dimension | Assessment |
|---|---|
| Complexity | Low |
| Cost | One column, one mapping CASE |
| Scalability | Static mapping needs maintenance per new app |
| Team familiarity | High |

**Pros:** Zero Lovable changes. Browsers always send Origin (CORS spec). Hard to spoof from a browser. Works today for all 4 apps.

**Cons:** Static subdomain → name mapping. Direct SQL → `sql` bucket with no further granularity. "Other" origins land in unknown bucket.

### Option B — Custom `X-App-Source` header only

Each Lovable app sets `global.headers: { 'X-App-Source': 'derm-tracker' }` in its supabase client init.

| Dimension | Assessment |
|---|---|
| Complexity | Low (trigger) but distributed (4 apps must opt in) |
| Cost | 4 Lovable PRs |
| Scalability | Self-extending per app |
| Team familiarity | Medium (need to remember to set on new clients) |

**Pros:** Explicit, app-controlled, no Origin mapping. Works for scripts (curl can set the header). Easier to extend.

**Cons:** Requires Lovable changes in every app (4 PRs minimum). Client-controlled — can be spoofed (low risk for our threat model, but worth noting). Won't capture anything for apps that forget to set it.

### Option C — Hybrid (Origin-derived + explicit override) **← chosen**

Capture both. If `X-App-Source` header is set, use it (explicit beats derived). Else derive from Origin. Else null.

| Dimension | Assessment |
|---|---|
| Complexity | Medium (two paths) |
| Cost | One column + small CASE |
| Scalability | Both Origin and explicit can extend |
| Team familiarity | High |

**Pros:** Works immediately without Lovable changes. Supports explicit override (scripts, future bots). Future-proof when an app adds X-App-Source.

**Cons:** Two sources of truth — must document which wins. Trigger logic slightly more complex than A or B alone.

### Option D — PostgreSQL session variables (`set_config`)

Each connection or transaction sets `SET LOCAL app.source = 'derm-tracker'`. Trigger reads `current_setting('app.source', true)`.

| Dimension | Assessment |
|---|---|
| Complexity | High (per-request SET LOCAL plumbing) |
| Cost | Every app must issue SET LOCAL before writes |
| Scalability | Heavyweight for our volume |
| Team familiarity | Low (uncommon pattern in PostgREST stack) |

**Pros:** Works for direct SQL with explicit setting. Transactional scoping.

**Cons:** Requires app code to issue SET LOCAL — PostgREST doesn't natively pass-through. Pre-request middleware needed. Heavyweight for 150-200 writes/day.

### Option E — Schema-level per-app roles

Create distinct Postgres roles (`app_derm_tracker`, `app_field_portal`, etc.). Each Lovable app's supabase client authenticates with a JWT minted for its role. Trigger captures `current_user`.

| Dimension | Assessment |
|---|---|
| Complexity | High (per-role grants, RLS, JWT minting) |
| Cost | Major refactor |
| Scalability | Postgres-native, can't be spoofed |
| Team familiarity | Low |

**Pros:** Postgres-native trust model — same attribution as JWT role. Scales naturally if/when per-app permission boundaries are needed.

**Cons:** Massive refactor. Each app needs its own role + grants + RLS update. Supabase JWT minting per app needs custom Edge Function or external auth. Doesn't help distinguish scripts (still `postgres`). Likely collides with Phase 2 user-level JWT scheme.

### Option F — Wait for Phase 2 auth

Accept anon-era attribution gap. Add real `changed_by` when user JWTs ship.

| Dimension | Assessment |
|---|---|
| Complexity | Zero |
| Cost | Zero |
| Scalability | N/A |
| Team familiarity | N/A |

**Pros:** No work now. Phase 2 will give real user identity.

**Cons:** Pre-Phase-2 forensics stay degraded for months. Today's audit gap (Yannick's 5/21 bulk action vs Fred's SQL script) keeps repeating. Doesn't address the **app-source** question even after Phase 2 (a user might use multiple apps).

## Trade-off Analysis

**Why C over A**: A is simpler but doesn't help scripts. C lets `audit_critical_poll.js` and future automation explicitly identify themselves with `X-App-Source: script:audit-poll`.

**Why C over B**: B requires 4 Lovable PRs to ship. C ships value on day one (via Origin) and adds value when apps opt in. No blocking dependency on Lovable cycles.

**Why C over D**: D requires every PostgREST request to issue SET LOCAL. There's no clean middleware hook in supabase-js for this. C reads what's already there.

**Why C over E**: E's permission-isolation benefit isn't currently needed (all 4 apps already have appropriate RLS at the table level). The Postgres-native trust upside doesn't outweigh the refactor cost.

**Why C over F**: F leaves the gap we're trying to close.

## Consequences

### Easier
- Forensic queries: `SELECT * FROM audit.logs WHERE app_source = 'derm-tracker' AND changed_at > NOW() - INTERVAL '24 hours'` — fast with the new index.
- Tier 1 alerts (per ADR-010) can refine the anon allow-list to be app-source-aware: a `visits:UPDATE` from `derm-tracker` is normal; from `unknown` it's worth flagging.
- Future bot/script writers can self-identify by setting `X-App-Source: bot:viktor-derm-backfill`.
- When Phase 2 user JWTs ship, `changed_by` populates automatically — `app_source` continues to capture which app the user was using.

### Harder
- One more column to remember in audit queries. Mitigated by the `audit.recent_changes` view (already proposed in ADR-010) — extend it to include app_source.
- The Origin → app_source mapping is hardcoded in the trigger. When a new app comes online with a new subdomain, the mapping needs an update or it falls into `other:<host>`. Acceptable — `other:` is informative, not broken.
- New columns on partitioned table propagate to all child partitions automatically (pg_partman + native partition inheritance), but adding indexes touches every partition. Low cost at our current row count (~5K).

### What we'll need to revisit
- When Phase 2 ships and `auth.uid()` populates `changed_by`, decide whether `app_source` becomes redundant for user-facing writes (it won't — same user can use multiple apps).
- If `X-App-Source` gets widely set in Lovable apps, the Origin mapping might become vestigial. Worth re-evaluating in 6 months.
- The `request_context` jsonb has a soft size budget. If routes/method/origin balloon (very unlikely at our volume), consider whether to limit retention on it independently.

## Action Items

1. ✅ Migration `2026-05-23d_audit_log_app_source.sql` — adds columns, updates trigger.
2. ✅ Apply + verify via 3 synthetic writes (REST-from-app / REST-with-X-App-Source / direct SQL).
3. ✅ Re-audit: run a known UPDATE through the DERM Tracker live UI, confirm `app_source='derm-tracker'`.
4. ⏳ (Optional) Lovable apps add explicit `X-App-Source` header in their supabase client config — small PR per app, deferred until ops asks.
5. ⏳ Update `scripts/alerts/audit_critical_poll.js` to surface `app_source` in alert messages (next iteration).
6. ⏳ Update ADR-010 with a forward-ref to this ADR.

## References

- ADR-010 (Audit Trail Architecture) — the substrate this builds on.
- [PostgREST request context settings](https://postgrest.org/en/stable/references/auth.html#client-info)
- [Supabase `X-Client-Info` header](https://supabase.com/docs/reference/javascript/initializing)
