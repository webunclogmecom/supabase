# Property access hours: the migration off the legacy trio (2026-08-07)

**Read this before touching `public.properties.access_hours_start`, `access_hours_end`,
`access_days` or `access_schedule`, in the DB or in any app.**

Fred, 2026-08-07: *"The idea is to migrate from the legacy access hours to the new access hours,
and for it to be applied on all the apps."*

---

## Where it stands right now

| column | what it is | populated |
|---|---|---|
| `access_schedule` (jsonb) | **the authoritative copy.** `{"mon":{"open":"22:00","close":"06:00"}, ...}` | **198 of 856** |
| `access_hours_start` / `_end` (text) | one window for the whole property. **A compatibility mirror now, not storage** | 198 |
| `access_days` (text[]) | which days that window applies to | 201 |

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

## What is left, and why none of it shipped with step 1

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
