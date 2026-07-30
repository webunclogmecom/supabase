# Properties manhole/sample-port columns: RPC cutover design

*Design only. No migration written, no DB change made, no session claim taken. Fred routes the work
(root `CLAUDE.md` §5.1); this exists so whoever gets it starts from measurements rather than from
the two wrong premises below.*

**Audited 2026-07-30 against Prod `wbasvhvvismukaqdnouk`.** Everything here is a measurement, not an
inference. Where a number differs from an earlier message or doc, this file is the corrected one.

---

## Headline: most of this is already built, and I nearly designed it twice

> **`client.update_property_operational` ALREADY EXISTS, is `SECURITY DEFINER`, is granted to
> `authenticated`, and its allowlist ALREADY CONTAINS BOTH COLUMNS.** Shipped by @Supabase in
> `docs/migrations/2026-07-29_1835_client_app_wave1_write_rpcs.sql`, commit `b93c407`
> ("Client App wave 1: three SECDEF write RPCs, applied and verified").
>
> **⇒ NO NEW DB OBJECT IS NEEDED. NO NEW GRANT IS NEEDED.** Admin Review's users are `authenticated`,
> and `authenticated` already holds EXECUTE on that function, so Admin Review can call it **today**
> without any migration at all.
>
> I was one step from writing a duplicate RPC. The only reason I did not is that Fred asked for an
> audit first. Note the file was invisible to a filename-based search for "properties" work: it is
> named `client_app_wave1_write_rpcs`.

## What is actually left

Three steps, and **the order is load-bearing**:

| # | Step | Owner | Reversible? |
|---|---|---|---|
| 1 | Admin Review calls the RPC instead of `PATCH /rest/v1/properties` | **Building Apps** (Lovable) | yes, republish |
| 2 | `REVOKE UPDATE (grease_trap_manhole_count, sample_port_count) ON public.properties FROM authenticated` | either Supabase session | yes, re-GRANT |
| 3 | `DROP POLICY properties_anon_update_manhole_authn ON public.properties` | either Supabase session | yes, recreate |

**⛔ Step 2 before step 1 breaks Admin Review.** It wrote `properties` on 2026-07-29, so it is live,
not dormant. This is the same trap `STAGED_2026-06-15c`'s own header warns about ("apply per-app, and
only after that app's login is live"). A DB-only session cannot sequence this safely alone, because it
does not control when the app republishes. **That is the whole reason this is a routed task and not a
migration.**

Step 3 is only meaningful after step 2: once the column grants are gone, `authenticated` holds no
UPDATE privilege on `properties` at all (table ACL is `authenticated=r`), so the policy becomes dead
weight. Dropping it is what removes the trap, because it leaves nothing for a future column grant to
ride on. Doing 3 without 2 achieves nothing; doing 2 without 3 leaves the trap armed.

---

## Measured current state

```
public.properties        817 rows, owner postgres, RLS enabled, FORCE ROW LEVEL SECURITY = true
table ACL                {postgres=arwdDxtm, service_role=arwdDxtm, authenticated=r, yannick_readonly=r}
                         -> authenticated has SELECT only at table level; anon is ABSENT entirely
column ACLs (the whole set, from pg_attribute.attacl):
  grease_trap_manhole_count   {authenticated=w/postgres}
  sample_port_count           {authenticated=w/postgres}
policies:
  Allow service_role full access   ALL     {service_role}     USING true
  Authenticated read properties    SELECT  {authenticated}    USING (auth.uid() IS NOT NULL)
  anon_read_properties_authn       SELECT  {authenticated}    USING true      <- misleading name, see below
  properties_anon_update_manhole_authn  UPDATE {authenticated} USING true WITH CHECK true
triggers                 audit_properties, trg_properties_updated_at
```

**⚠ `FORCE ROW LEVEL SECURITY` is on, and it is why this design works at all.** FORCE RLS subjects even
the table **owner** to RLS, and there is no policy for `postgres`. A `SECURITY DEFINER` function owned
by a definer *without* `BYPASSRLS` would therefore find zero rows and fail confusingly. Measured:
`postgres` and `service_role` both have `rolbypassrls = true`; `authenticated`, `anon` and
`authenticator` do not. So the existing RPC works because its **owner has BYPASSRLS**, not because it is
SECDEF. 19 of 51 RLS-enabled `public` tables use FORCE RLS, and `public.visits` is one of them, which is
why the Phase-3 `edit_calendar_visit` RPC works the same way. **Do not re-own these functions to a
non-BYPASSRLS role.**

**⚠ Two cosmetic traps in the policy list, worth fixing only if someone is in there anyway.**
`anon_read_properties_authn` applies to `{authenticated}`, not anon: the role was migrated and the
policy name was not. And it duplicates `Authenticated read properties` while being strictly broader
(`USING true` vs `auth.uid() IS NOT NULL`); permissive policies OR together, so the narrower one has no
effect. Neither is a security issue. Both make `pg_policies` misleading to read, which is how the
"anon can update properties" misreading started.

## Measured usage: who actually writes these columns

Enumerated `audit.logs` by `app_source` rather than querying a label, per `CLAUDE.md` §5.5(b).
`properties` has an `audit_properties` trigger, so audit silence here would be meaningful (positive
control passed).

```
grease_trap_manhole_count   15 writes / 10 properties   2026-05-24 .. 2026-07-29
sample_port_count            3 writes /  3 properties   2026-07-08 .. 2026-07-29
distinct properties touched, live columns: 11 of 817
```

By app: **Admin Review 17** (12 as `admin-review` + 5 as `other:review.unclogme.app`, the stale-label
window), **DERM Tracker 1** (2026-05-25 only). Code search across both app repos finds exactly **one**
write path, in Admin Review:

```js
const { data, error } = await supabase.from("properties").update({ grease_trap_manhole_count: n })
```

DERM Tracker, Client App, Field Portal and Visit Calendar reference the columns for **reads only**. So
step 1 is a single-app change.

⚠ **The Lovable app source is not in this repo**, so step 1 cannot be done from a Supabase session even
in principle. It must happen in the Admin Review Lovable project.

## Two corrections to earlier statements, recorded so they are not re-derived

1. **"No app has ever written any other `properties` column" was WRONG** (mine). My column-diff query
   omitted `visit-calendar` from its `app_source` filter, the same 310 rows I had flagged one paragraph
   earlier. Including it: `zone` 310 writes / 88 properties on 2026-05-29. It does not change the
   verdict, because **`properties.zone` has since been dropped** (`information_schema.columns` returns
   0 for it; `zone_id` replaced it), so it is unwritable today. Accurate claim: *no app has written any
   other column that still exists.*
2. **"A live exposure worth fixing on its own merits" was WRONG** (@Supabase's, self-corrected). RLS is
   row-level and cannot scope a column, so no policy narrowing fixes this. With no tenancy among staff,
   `USING(true)` is arguably *correct*: any staff user editing any client's property is intended. It is
   a **latent trap**, and the risk is entirely conditional on someone adding a column grant.

Both are the same failure shape: the query was fine and the interpretation was not. See the headline
box in `docs/migrations/NAMING.md`.

## Open decisions for whoever takes this

1. **Reuse `client.update_property_operational`, or add a narrow RPC?** Its allowlist is 10 fields
   (`zone_id`, `county`, `access_hours_start/end`, `access_days`, `access_notes`, `notes`,
   `grease_trap_manhole_count`, `sample_port_count`, `default_disposal_facility_id`); Admin Review needs
   2. **Least privilege argues for a narrow one, but note it changes nothing about what is reachable
   today**: EXECUTE is granted to the `authenticated` ROLE, so an Admin Review session can already call
   all 10 fields regardless of which RPC its UI uses. A narrow RPC is defence against a future bug in
   Admin Review, not a closure of present access. My lean: **reuse it**, and revisit only if per-app
   scoping becomes a real requirement, because two RPCs means two allowlists to keep in sync and the
   `client.*` one is already hardened (identity check, staff-domain check, explicit unsupported-field
   error, non-array `access_days` guard).
2. **Schema naming.** `client.*` reads as "the Client App's schema", but this function is about
   *properties*, not about that app. Calling it from Admin Review is either fine (it is a properties
   RPC that happens to live there) or wants a thin `public` wrapper. Cosmetic; decide once.
3. **Whether to bother.** Nothing is leaking. The grant matches usage exactly, there is no staff
   tenancy to violate, and `docs/security.md` rule 9 now documents the trap and forbids the move that
   would arm it. Steps 2 and 3 are hygiene that remove a footgun; step 1 is a real app change to a live
   surface. **Leaving it documented is a defensible choice.**

## Verification, per step

Use the DB as the record. Do not infer from the filename or from this document.

- **After step 1**, before touching any grant: exercise the Admin Review save and confirm a new
  `audit.logs` row for `properties` whose `app_source` is `admin-review` **and** whose
  `request_context` shows the RPC path rather than `PATCH /properties`. Remember to check **both**
  labels (`admin-review`, `other:review.unclogme.app`) if reading historical rows.
- **After step 2**: `SELECT a.attname, a.attacl FROM pg_attribute a WHERE a.attrelid =
  'public.properties'::regclass AND a.attacl IS NOT NULL;` must return **0 rows**. Then re-exercise the
  Admin Review save; it must still succeed, because it now goes through the RPC.
- **After step 3**: `SELECT count(*) FROM pg_policies WHERE tablename='properties' AND cmd='UPDATE';`
  must be **1** (`service_role` ALL only, no authenticated UPDATE policy). Re-exercise the save once
  more.
- **Negative control, and do not skip it**: a raw `PATCH /rest/v1/properties?id=eq.<id>` with a staff
  JWT setting `grease_trap_manhole_count` must return **401/403**, not 200-with-0-rows. A silent
  zero-row success would look identical to a working revoke while actually meaning RLS filtered the row.

## References

- `docs/migrations/2026-07-29_1835_client_app_wave1_write_rpcs.sql` (`b93c407`) — the existing RPC, and
  a header that already documents this trap in detail. **Read it before writing anything here**; it
  and `docs/security.md` rule 9 are the same finding from two directions, deliberately cross-referenced
  rather than merged.
- `docs/security.md` rule 9 — the standing rule: never add a column UPDATE grant on a table whose
  UPDATE policy is `USING(true)`.
- `docs/migrations/STAGED_2026-06-15c_..._DO-NOT-APPLY-YET.sql` — would `CREATE POLICY ... ON
  public.visits FOR UPDATE TO authenticated USING (true)`, adding a third instance of this shape.
  Must stay unapplied; its header carries the measured status.
- `public.visits` — the same pattern, unresolved: `visits_app_update_authn` is
  `USING (deleted_at IS NULL)`, so the Phase-3 RPC-only lock on `visit_status`/`completed_at` rests on
  the column grant alone. Out of scope here, but it is the second instance and it is larger.
