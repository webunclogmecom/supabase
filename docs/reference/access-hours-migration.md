# Property access hours: the migration off the legacy trio (2026-08-07)

**Read this before touching `public.properties.access_hours_start`, `access_hours_end`,
`access_days` or `access_schedule`, in the DB or in any app.**

Fred, 2026-08-07: *"The idea is to migrate from the legacy access hours to the new access hours,
and for it to be applied on all the apps."*

---

## Where it stands right now

| column | what it is | populated |
|---|---|---|
| `access_schedule` (jsonb) | **the authoritative copy.** `{"mon":{"open":"22:00","close":"06:00"}, ...}` | **198** of 861 |
| `access_hours_start` / `_end` (text) | one window for the whole property. **A compatibility mirror now, not storage** | 198 |
| `access_days` (text[]) | which days that window applies to | 201 |

⚠ **The denominator MOVES.** It was 856 on 2026-08-07 and is **861** today: the hourly Jobber
property sweep inserts rows while this migration is in flight. New properties arrive with all four
columns NULL, so they need no backfill, but never quote a "N of TOTAL" figure as if it were stable.

Step 1 shipped: `docs/migrations/2026-08-07_1649_access_hours_backfill_schedule.sql`.
**Every property that has access hours now has a schedule. There are ZERO legacy-only rows.**

🛑 **`access_schedule` IS NO LONGER A DEAD COLUMN.** It held 1 row for a week and now holds 198.
Any note saying "0 populated, never use it" is stale as of 2026-08-07 and has been corrected in
`Building Apps/Visit Calendar/CLAUDE.md`.

---

## The rules the backfill applied, and why

Fred's rule was: schedule wins if present; else copy the legacy hours into the schedule; else drop
the legacy one.

1. **An existing `access_schedule` DOMINATES** and is never overwritten. (1 property.)
2. **Legacy hours become a schedule on the RECORDED days**, not on all seven.
   🛑 The instruction said *"copy those access hours to all the days"*. Measured first: **31 of the
   200 legacy-only properties record FEWER than seven accessible days** (8 have four, 16 five, 2 six,
   5 none). All seven would have told a driver a site is open on days the office marked closed, and
   would have contradicted the app, which already renders an absent day as "Closed". **Fred chose
   recorded days.** For the 169 that already list all seven it is identical, so the divergence only
   ever protects the other 26. The 2 with hours but no days recorded did get all seven, because
   nothing was restricted.
3. **Neither**: nothing to do, the legacy columns were already NULL. (655 properties.)
4. **The literal word `REQ`** sat in a time field on 3 properties with no end and no days. It cannot
   become a schedule. Fred: *"just clear them."* Their `old_row` is in `audit.logs` if wanted back.

**Two things that would have broken it silently:**
- **20 rows carried an unpadded hour** (`9:00`, not `09:00`). The legacy columns are plain `text` and
  were never validated. `access_schedule` **is** validated as `HH:MM` by
  `client.update_property_operational`. Unpadded values would have written a schedule the RPC then
  refused to accept back on the next save. They are padded on the way in.
- **114 of the 197 are OVERNIGHT** (`open > close`, e.g. `22:00` to `06:00`). Legal and normal here,
  rendered with a `+1`. Not a bug, do not "correct" them.

---

## 🛑 THE UNRESOLVED CONFLICT: `00:00` to `00:00` MEANS TWO OPPOSITE THINGS TODAY

**32 properties** store `access_hours_start = access_hours_end = '00:00'`. All 32 now carry that pair
in their new schedule as well, because the backfill copied faithfully rather than interpreting.
**221 Visit Calendar visits** hang off those properties.

| app | what it does with it | source |
|---|---|---|
| **Client App** | renders **"All day"** | Fred, 2026-08-06: *"00:00 – 00:00 means all day"* |
| **Visit Calendar** | treats it as a **PLACEHOLDER meaning NO window**, and suppresses the hours warning | its own `CLAUDE.md` |

Those cannot both be right, and the same 32 sites are currently described to staff both ways
depending on which screen they open.

⚠ **This predates the migration and was NOT introduced by it**, but the migration propagated it into
`access_schedule`, and that matters more than it did before: the whole point of the new column is
that every app moves onto it. If the Calendar migrates while keeping "equal means no window", the
contradiction survives the migration in a newer format.

**Not resolved here on purpose.** Fred's statement was made about the Client App's rendering, and
reading it as a ruling about the DATA would silently change what 221 Calendar visits show. That is a
decision, not a cleanup. **Ask before either app changes its interpretation.**

---

---

# 🛑 AUDIT, 2026-08-10: THE COLUMNS CANNOT BE DROPPED YET, AND THE REASON IS NOT WHAT ANYONE EXPECTED

Fred: *"Do an audit for the access hours migration, and finish it."* The audit ran five parallel
sweeps (database, Client App bundle, Calendar bundle, all other apps, repo code), then a second pass
whose only job was to find a consumer each sweep had missed.

**All five sweeps were refuted. 25 consumers were missed between them.** That is the finding.

## The two facts that reframe the whole migration

**1. 🛑 `access_schedule` CONTAINS NO PER-DAY DATA. Zero of 198 schedules hold more than one
distinct window.** The backfill copied one window across N days, and nobody has entered genuinely
per-day hours since. So moving any app onto `access_schedule` today gains it **nothing**: it would
read the same single window by a longer route. The migration's value is *future* capability and
*one* source of truth, not richer data today.

**2. 🛑 FIVE PROPERTIES HAVE NO LOSSLESS DESTINATION.** 521 (227-PER), 157 (176-SOU), 73 (140-TYO),
362 (094-MOZ), 109 (109-RAB) hold `access_days` with **`access_hours_start` NULL**. `access_schedule`
requires `open` and `close` per day (the RPC raises `22023` otherwise), so "these days, hours
unknown" **cannot be expressed in the new format at all**. Three of the five have live visits.
⚠ The earlier claim "zero properties have legacy hours without a schedule" is true **for hours** and
**false for days**.

## What the adversarial pass found that the sweeps missed

The sweeps found 5 views and 1 function. The real surface is much wider:

| missed consumer | why it matters |
|---|---|
| **`scripts/sync/refresh_client_mirror.js`** + `.github/workflows/client-mirror-refresh.yml`, **cron `23 * * * *`** | **A LIVE HOURLY JOB** copying `properties` whole-table to the Client App Mirror project. Verified: the workflow exists and `properties` is in its table list. |
| **`client.create_property`** | A second SECURITY DEFINER RPC, `authenticated`-executable, that emits all five access columns. **Invisible to both standard detection methods — see below.** |
| **`client.properties` view** | The Client App's *only* property read path, omitted from that app's own report. |
| **Return contract of both property RPCs** | Both end `to_jsonb(v_row)`, so **dropping a column silently changes the JSON shape the app receives**. The sweep marked this "does not break". It does. |
| **`schema/v2_schema.sql`** | The schema-of-record snapshot declares the three columns and reproduces all four ops views. |
| **`docs/field-portal-compatibility-views.sql` L104-109** | **Executable DDL**, not prose: builds a customer-facing string from all three legacy columns. |
| **`scripts/populate/populate.js`** | Live population procedure, documented in the duplication guide, writes the trio. |
| Calendar drawer visit-to-visit navigation | A second `.from("v_calendar_visit").select("*")` the Calendar sweep missed. |
| "UnclogMe Admin Management" | **An app absent from the app list entirely.** |
| `docs/migrations/2026-08-10_1212_*` | My own padding migration from an hour earlier, writing the trio. Missed by the repo sweep. |

⚠ **The Visit Calendar alone has 13 distinct consumers of the trio, every one of which breaks if it
is dropped.** Its published bundle names the three legacy columns 15 times and `access_schedule`
**zero** times. Two of its PostgREST calls name the columns **explicitly** rather than `select *`,
and one of them **filters** on a legacy column
(`.select("access_hours_start, access_hours_end, access_days").not("access_hours_start","is",null)`),
so a drop is a `42703` on the whole grid query, not a blank field.

## 🛑 THE DETECTION TRAP: A WHOLE-ROW RPC CONSUMES EVERY COLUMN WHILE NAMING NONE

**This is the part worth carrying to any future column-drop audit, and it caught my own sweep.**

`client.create_property` does this:

```sql
declare v_row public.properties;      -- line 21
insert into public.properties ... returning * into v_row;   -- 142-148
return to_jsonb(v_row);               -- 150
```

**The body never contains the string `access`.** Measured:

| detection method | result | why it fails |
|---|---|---|
| regex over `pg_proc.prosrc` | **1 function found**, not 2 | the column names are never written down |
| `pg_depend` → `pg_proc` vs `public.properties` | **0 rows** | a `%ROWTYPE` local creates no column dependency |
| `to_jsonb(v_row)` key count | **27 keys, 5 of them `access*`** | the columns are all there at runtime |

⇒ Both catalogue-based methods return a confident zero. **Dropping a column silently changes the
JSON shape this RPC returns to the app — no error, at either end.**

⚠ **And my confirming check of the audit's finding was itself wrong**, in the same class: I matched
`'%v_row public.properties%'` with one space, the declaration uses five, so my probe returned `false`
and briefly looked like a refutation. **A string match is not a measurement.** Reading
`pg_get_functiondef` settled it in one call.

## Runtime usage, which changes the priority order

From `pg_stat_statements` (control: 4,890 statements tracked, nonsense token 0 calls):

| view | calls ever |
|---|---|
| `ops.v_calendar_visit` | **37,290** |
| `ops.v_service_due` | 3,636 |
| `ops.properties` | **7** |
| `ops.v_route_today` | **4** |

**Two of the four `ops` views are effectively dead.** The migration's real exposure is one view and
one app, not four and six.

## Two more consumers, both dormant rather than harmless

- **`scripts/ops_views/{properties,v_calendar_visit,02_v_service_due,03_v_route_today}.sql`** are
  checked-in copies of exactly the four view bodies. **Re-applying a stale copy after the switch
  silently reverts the view**, with no error. They must move in the same commit as any view change.
- **`supabase/functions/webhook-airtable/index.ts`** writes `access_hours_start` (L217) and
  `access_days` (L234) in `handleClientRecord`. `'client'` was severed from `ENTITY_TO_HANDLER` on
  2026-07-30 and carries a `DO NOT RE-ADD`, so it is unreachable — but it is the one thing that could
  re-create a legacy-only row if anyone ever re-adds the entity.

## 🛑 THE 2026-08-10 12:00 VERDICT ("the columns stay") IS SUPERSEDED. Read this instead.

That verdict said dropping bought no capability while requiring a cutover across an hourly cron, two
RPC response shapes, 13 Calendar consumers and an unlisted app. **Every fact in it was right and the
conclusion did not follow** — the same shape as the three failures catalogued in `CLAUDE.md` under
"structure tells you what a thing does".

It assumed the only route was **porting every app to read `access_schedule`**. There is a second
route: **make the views DERIVE the trio**, so the apps never learn anything changed. The column
names, types and positions stay identical; only where the values come from moves. That deletes the
entire cutover cost the verdict was built on.

Fred, 2026-08-10, setting the order that made this obvious: *"we can just do the migration for the
old way of the access hours to the current one, and once that is complete to do view checks on the
apps, and do smoke tests to also check the DB, and once that is complete we can drop the old way."*

## Where it actually stands

| step | state |
|---|---|
| 1. `access_schedule` populated and authoritative | ✅ `2026-08-07_1649`, 198 rows |
| 2a. Hours padded so stored == derived | ✅ `2026-08-10_1212`, 20 rows |
| 2b. Days normalised so stored == derived | ✅ `2026-08-10_1305`, 7 properties |
| 3. Five views derive the trio from `access_schedule` | ✅ `2026-08-10_1330` |
| 4. Drop the trio | ✅ `2026-08-10_1415`, applied on Fred's explicit go |

**THE MIGRATION IS COMPLETE.** `public.properties` now holds `access_schedule` and `access_notes`
and nothing else access-related. The three legacy columns exist only as **derived output** of the
five views, so every app still reads the same field names and nothing on any screen moved.

Verified live after applying, and again through the apps' own sessions:

| | |
|---|---|
| base table columns remaining | `access_schedule`, `access_notes` |
| `client.properties` / `ops.properties` | 198 hours, 198 day arrays / 198 |
| `ops.v_calendar_visit` / `ops.v_service_due` | 1,512 / 151 |
| `properties` rowtype | 27 keys → **24** |
| Calendar, signed in | 093-KC still `23:00`–`05:00`, all seven days, count **1,512** |
| Client App, signed in | 200, 31 keys, a 5-day property still `mon,tue,wed,thu,sun` |
| **PostgREST on the BASE table** | **400, `column properties.access_hours_start does not exist`** |

That last row is the negative control. Without it, "the apps still work" is equally consistent with
the drop never having happened.

### How to put a column back, if it ever matters

Nothing was lost: `access_schedule` holds everything the trio held, proven by `stored == derived` on
all 198 rows before the drop. Re-adding is
`alter table public.properties add column access_hours_start text` then
`update public.properties set access_hours_start = public.fn_sched_open(access_schedule)`.

### What the derivation is, in one place

Three pure `IMMUTABLE STRICT` helpers, reproducing the exact rule the RPC already used (modal open /
modal close, ties broken lexically ascending):

`public.fn_sched_open(jsonb)` · `fn_sched_close(jsonb)` · `fn_sched_days(jsonb)`

🛑 **They are `fn_sched_*` and not `fn_access_*` on purpose.** `fn_access_days` *contains* the string
`access_days`, so a later find-and-replace on the column name would maul the function and every call
site — the `service_kind` collision again. The generator's guard (legacy names may survive only as
output aliases) **failed** under the old name. The rename is what makes the guard mean anything.

🛑 **`authenticated` needs EXECUTE on all three.** The views are owner-rights and launder the *table*
grant, but a SECURITY INVOKER function called from inside one runs as the **caller**. Without the
grant every staff user gets `42501` on the Calendar grid — the `fn_resolve_gdo_id` failure of
2026-07-28h. Asserted with `has_function_privilege`, which does not depend on a role switch behaving.

### Verified after applying, not before

| check | result |
|---|---|
| views naming the base columns | **0** (was 5) |
| `pg_depend` rows on the three columns | **0** — control: **5** on `access_schedule`, so the zero is meaningful |
| PostgREST reads of them off the base table | **0**; every read is `ops.v_calendar_visit` |
| `authenticated` UPDATE on them | **false** (only `grease_trap_manhole_count`, `sample_port_count`) |
| all five views read as `authenticated` | clean, no `42501` |
| `route_today`'s expression across every live visit | **1,759 checked, 0 mismatches**, control 1,512 non-null |
| **Visit Calendar, live, signed in** | **1,512 rows**, overnight windows intact (23:00–05:00), day arrays correct |
| **Client App, live, signed in** | 200, 31 keys, 198 hours, 198 day arrays; a 5-day property derives in correct `mon..sun` order |

⚠ `ops.v_route_today` returned **0 rows** in the role probe because no visit is dated today. That
proves it *executes* (a bad `GROUP BY` raises at plan time) but not its values — hence the separate
1,759-visit check of its expression. It has **4 calls ever**, so this is proportionate.

### The two open questions from the morning audit, both now closed

1. **The 5 days-only properties** — closed by `2026-08-10_1305`. All five recorded **all seven days**,
   which says the same as "no restriction", and `access_schedule` cannot express "these days, hours
   unknown" at all. Cleared, audited, revertible.
2. **Is the drop worth it** — the question was really "is the cutover worth it", and the derivation
   removed the cutover. What remains is one `ALTER TABLE`.

### The latent defect is now moot

`client.update_property_operational` re-derived `access_hours_start/_end` from the schedule but never
`access_days`, so the two could silently disagree. The staged migration **removes all three
assignments**, so there is nothing left to disagree.

🛑 **Its accepted-key allowlist is deliberately NOT touched.** Removing a key does not make the RPC
ignore it, it makes the RPC **refuse the whole patch** — every property save from any cached bundle
would fail. The three keys are accept-and-ignore from here on. A legacy-**only** patch (the keys
*without* `access_schedule`) raises `22023` rather than being silently discarded, because "saved"
with nothing saved is the worst of the three options.

---

## What was left after step 1 (retained, superseded in part by the audit above)

Step 1 was deliberately **additive**: it filled the new column, changed no view, and moved nothing on
any screen.

**Five views read the legacy trio, all as PLAIN PASS-THROUGH COLUMNS with no logic attached:**

| view | exposes |
|---|---|
| `client.properties` | start, end, days **and `access_schedule`** |
| `ops.properties` | start, end, days |
| `ops.v_calendar_visit` | start, end, days (COALESCEd visit property over primary property) |
| `ops.v_route_today` | start, end (also in its GROUP BY, so adding a column means touching that) |
| `ops.v_service_due` | start, end |

Because they are pipes rather than logic, **finishing this is a swap, not a rewrite.**

1. **Expose `access_schedule` on the four `ops` views that lack it.** Additive; `CREATE OR REPLACE
   VIEW` can append a column. ⚠ `ops.v_route_today` aggregates, so its `GROUP BY` needs the new
   column too. ⚠ `ops.v_calendar_visit` also carries `service_kind`, which a careless find-and-replace
   destroys (see `CLAUDE.md`, the service_type/service_kind collision).
2. **Move each app to render from `access_schedule`.** Per app, one at a time. The Client App
   already reads it. The Visit Calendar is the one with the `00:00` conflict above, so it should not
   move until that is settled.
3. **Stop `client.update_property_operational` deriving the legacy pair.** It currently writes both,
   picking the MODAL open and close across the days, which is lossy and has a known tie-break defect
   (`Client App/docs/09-known-issues.md` 0d: a tie breaks lexically per field, so a property can be
   given a window belonging to no actual day).
4. **Drop the three legacy columns.**

**Do steps in that order.** Dropping or clearing the trio before step 2 blanks access hours on the
Calendar, the route view and the Field Portal in the same instant.

⚠ **The Field Portal is NOT affected today.** A catalogue sweep of every view definition found the
legacy columns in exactly the five views above, none of them in `customer.*`.

---

## Safety notes

- **The hourly Jobber property poll cannot clobber any of this.** It writes `address`, `city`,
  `state`, `zip`, `name`, `client_id`, `latitude`, `longitude`. It touches no access column. That
  disjointness is what makes property edits safe at all, so re-verify it before adding a column to
  either side (`Building Apps/Client App/CLAUDE.md`).
- **All 200 backfill writes are in `audit.logs` with `old_row` intact**, so any single property is
  individually revertible without a restore.
- **`access_schedule: {}` is accepted by the RPC and NULLs both legacy columns.** 0 rows hold `{}`
  today. It is asymmetric with `access_days: []`, which the same function normalises to NULL by
  documented contract.
