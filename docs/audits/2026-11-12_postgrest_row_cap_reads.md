# Staff app list reads against the 1,000-row cap (audit, 2026-11-12)

Read-only audit. Nothing in any app, database object or Lovable project was changed.

**Why:** Prod answers at most 1,000 rows per PostgREST request (`max_rows = 1000`, checked today through the Management
API `postgrest` config). A larger answer comes back as HTTP 206 with `content-range: 0-999/<total>` and no error;
supabase-js does not throw, and a `.limit()` above 1,000 changes nothing. On 2026-11-12 (Trello #186) the Admin Review
queue lost drivers this way. Spec: `Building Apps/Admin Review/docs/specs/2026-11-12-queue-reads-past-1000-rows.md`.
This audit asks the same question of every other staff app.

Measured 2026-11-12, about 07:00 to 08:00 ET.

> **Update, 2026-11-12 later the same morning: rows 2, 3, 4 and 11 are FIXED and live.** While this audit was measuring,
> the session named Supabase paged the portal queue (Ops Portal `3b5aac1`, 07:44 ET, `useQueueVisits.ts` only). Checked
> on ops.unclogme.app afterwards: the live chunk `_shell.review.index-SGW38IzW.js` carries `.range(` on the driver read
> and no `.limit(2e3)` or `.limit(5e3)`. The numbers below for those rows are what was measured BEFORE that fix; they
> are kept as the record. Row 6 is NOT covered by that fix: the portal's review page chunk
> `_shell.review.visit._visitId-C_QeqKWc.js` still reads the pending visits in one request, and so does admin.unclogme.app.

> **Update, 2026-11-12 ~09:18 ET: rows 1, 5, 9, 10, 14, 16 and 22 (the Client App's Clients list) are FIXED and live.**
> Fred: "Yes, fix it here". Every list read on that page now pages with `fetchAllRows` and `.range()` (Lovable
> `dbf2133c`, live chunk `index-Ddg_9uxM.js`, Building Apps `8fd38c7`). Checked on the live site with
> `scripts/client-app/tests/home_list_row_cap.mjs` at 1440 and 375: before the publish 234-PV showed "—" and the
> completed-visits read returned 1,000 of 1,648; after, 64 of 64 pass (234-PV shows its last visit, 1,648 of 1,648 in
> 2 requests, every list read equals the database's exact count). The numbers in the table are the record from before.
> Still open on the Client App: rows 7 and 8 (the client page's Activity tab and photos).

## Result in one paragraph

**Two reads are already past the cap**, and both are live today: the Client App home list's "Last visit" read (1,648
rows, 648 dropped, 47 clients show no last visit, since about 2026-08-06) and the portal's `/review` driver read (the
#186 defect, unpaged on ops.unclogme.app when measured, fixed since: see the update above). **Four more pass it within
ten weeks:** the portal queue's visit read (about 1 week; fixed since), the portal queue's photo counts (about 3 weeks;
fixed since), the Admin Review "pending visits" list used for
Next / Previous on the review page, on **both** hosts (about 9 weeks; the #186 fix did not cover it), and the Client
App's "Next visit" read (8 to 10 weeks). Two Client App client-page reads follow at about 16 to 28 weeks. Everything
else is under 55% of the cap and grows slowly, is scoped to one record, or already pages.

## The table

Sorted by how soon it passes 1,000. "Rows today" is the size of the answer the read gets today (for a window, the
biggest window measured; for a per-record read, the biggest record). "Weeks" = (1,000 minus rows today) divided by the
weekly growth measured over the last 28 days. "Error ignored" is what the code does if the request itself fails. A cut
is never an error, so even a read that throws on error takes a cut silently, unless it compares with an exact count.

| # | App (host) | Read | Rows today | % of cap | Weeks until 1,000 | Error ignored |
|---|---|---|---|---|---|---|
| 1 | Client App (clients) | home list, "Last visit": `client.visits` completed, not deleted, `order(visit_date desc).limit(10000)` | **1,648** | **165%** | **past (since about 2026-08-06)**; **FIXED, Building Apps `8fd38c7`** | no, throws |
| 2 | Ops Portal `/review` (ops) | queue drivers: `visit_assignments .in('visit_id', <every queue visit>)` | **1,084** | **108%** | **past** (same defect as #186); **FIXED 07:44 ET, `3b5aac1`** | **yes, no error check** |
| 3 | Ops Portal `/review` (ops) | queue: `visits_with_review` completed, in scope, up to today, `.limit(2000)` | 946 | 95% | about 1 (46 a week); **FIXED, `3b5aac1`** | no, throws; has a `truncated` flag from `count: 'exact'` |
| 4 | Ops Portal `/review` (ops) | queue photo counts: `v_visit_photo_counts .in(...).limit(5000)` | 867 | 87% | about 3; **FIXED, `3b5aac1`** | no, throws |
| 5 | Client App (clients) | home list, "Next visit": `client.visits` scheduled, from today, `order(visit_date asc).limit(10000)` | 857 | 86% | 8 to 10 (about 790 four weeks ago); **FIXED, `8fd38c7`** | no, throws |
| 6 | Admin Review (admin) **and** Ops Portal `/review` (ops) | review page Next / Previous: `visits_with_review` completed, pending, in scope, no paging | 829 | 83% | about 9 (184 new in 28 days, 104 reviewed) | no, throws |
| 7 | Client App (clients) | client page, Activity tab: RPC `client.get_client_activity(p_client_id, p_include_system)`, no `p_limit`, so every row | 437 (biggest real client); 685 (test client 112-YA) | 44%; 69% | about 19; about 16 | no, throws |
| 8 | Client App (clients) | client page photos: `photo_links .in('entity_id', <the client's 200 newest visits>)`, then `photos .in('id', ...)` | 495 | 50% | about 28 (the client growing fastest: 483 rows, plus 75 in 28 days) | no, throws |
| 9 | Client App (clients) | home list, monthly value: `line_items .in('job_id', <every recurring job>).limit(20000)` | 375 | 38% | about 45; **FIXED, `8fd38c7`** | no, throws |
| 10 | Client App (clients) | home list, monthly value: `client.jobs` recurring, not archived, `.limit(5000)` | 535 | 54% | about 64; **FIXED, `8fd38c7`** | no, throws |
| 11 | Ops Portal `/review` (ops) | queue: `jobs .in(...)`, `line_items .in(...)` | 362; 342 | 36%; 34% | about 75 to 80; **FIXED, `3b5aac1`** | **yes, no error check** |
| 12 | Ops Portal (admin module) | Grease by client: RPC `public.get_grease_by_client()`, no arguments | 345 | 35% | about 90 | no, throws |
| 13 | Visit Calendar (calendar) and portal `/calendar` | client pickers (task dialog, New Visit): `ops.client_service_options`, whole view | 535 | 54% | about 116 | **yes on the old host and in the portal task dialog (logged, picker stays empty)**; portal New Visit shows a toast |
| 14 | Client App (clients) | home list: `client.client_services_flat .limit(2000)`; `client.clients .limit(5000)` | 500; 500 | 50% | about 133; **FIXED, `8fd38c7`** | no, throws |
| 15 | Visit Calendar and portal `/calendar` | `ops.clients` ACTIVE or RECURRING (plus 112-YA) | 478 | 48% | about 139 | no, throws |
| 16 | Client App (clients) | home list: `client.properties .limit(10000)` | 534 | 53% | about 143; **FIXED, `8fd38c7`** | no, throws |
| 17 | Visit Calendar and portal `/calendar` | month grid: `ops.v_calendar_visit` between the grid's first and last day, not cancelled | 287 (the August grid; the November grid 201) | 29% | about 145 | no, throws |
| 18 | Visit Calendar and portal `/calendar` | month grid RPCs: `ops.calendar_hours_estimates`, `ops.calendar_drive_days`, `ops.calendar_grease_estimates` | 280; 161; 159 | 28%; 16%; 16% | about 145 or more | no, throw (hours also logs) |
| 19 | Visit Calendar and portal `/calendar` | Team filter: `ops.v_visit_team .in('visit_id', <loaded visits>)` | 339 (the August grid) | 34% | about 110 | no, throws |
| 20 | DERM Stamp Studio (stamp) and portal `/stamp` | client list: `derm.v_stamp_clients .limit(2000)` | 341 | 34% | about 175 | toast, list stays empty |
| 21 | Picture Planner (planner) and portal `/planner` | property list: RPC `client.page_builder_list()`, no arguments | 360 | 36% | about 197 | shows the error |
| 22 | Client App (clients) | home list: `client.gdos .limit(10000)` | 194 | 19% | years; **FIXED, `8fd38c7`** | no, throws |
| 23 | Ops Portal (admin module) | Water by driver: RPC `public.get_water_visits(p_from, p_to)`, at most 93 days | 143 | 14% | years (a window) | no, throws |
| 24 | Client App (clients) | job panel: `client.job_activity` for one job | 136 | 14% | years | no, throws |

Every percentage is rows today divided by 1,000.

## What each near or past read does when it is cut

1. **Client App "Last visit" (past).** Live chunk `index-CRrnaduv.js` on clients.unclogme.app, query key
   `home-next-visits`. The read is newest first, so the 648 oldest completed visits are dropped: every client whose last
   completed visit is before 2026-06-08 (the 1,000th row today) shows no last visit. Replay: HTTP 206,
   `content-range 0-999/1648`; 250 of the 297 clients with a completed visit keep their date, **47 lose it**. About 200
   visits are completed each month, so the cut date moves forward about a month every month and the count of clients
   shown with no last visit only grows. Sorting or filtering the list by last visit is wrong for those clients.
2. **Portal `/review` drivers (past when measured, fixed since).** `Building Apps/Ops Portal/app/src/modules/admin/hooks/useQueueVisits.ts:107`
   was the pre-fix code at `ee9d22e`, and the live portal chunk `_shell.review.index-D1WmqBef.js` matched it. Replay:
   84 rows dropped. The session named Supabase fixed it in `3b5aac1` (07:44 ET), live as `_shell.review.index-SGW38IzW.js`.
   Notes 3 and 4 and row 11 are fixed by the same commit.
3. **Portal `/review` queue visits (about 1 week).** `useQueueVisits.ts:55`, `.limit(2000)` at line 88. Past 1,000 the
   queue loses visits. It keeps `count: 'exact'` and a `truncated` flag, so this one is not silent where the flag is
   shown. Same fix as the old host (`fetchAllRows`, `.range()`).
4. **Portal `/review` photo counts (about 3 weeks).** `useQueueVisits.ts:177`, `.limit(5000)` at line 182: visits past
   the cut would show 0 photos.
5. **Client App "Next visit" (8 to 10 weeks, around 2027-01-07 to 01-21).** Same query key as 1, soonest first. Future
   scheduled visits run through May 2027 (about 110 to 140 a month), so the answer grows as recurring clients grow. The
   cut drops the farthest dates first, so at first only a client whose every scheduled visit falls after the cut date
   loses its next date; the harm grows from there.
6. **Pending visits for Next / Previous (about 9 weeks, both hosts).** admin.unclogme.app live chunk `App-DZ9pfyWH.js`
   and the portal `modules/admin/hooks/usePendingVisitIds.ts:12`. Not part of the #186 fix, which covered the queue
   page only (the "every read on the same app" rule). Oldest first, so past 1,000 the newest pending visits drop out of
   the order the review page uses when it was not opened from the queue (`resolveVisitNavigation` in
   `modules/admin/lib/queueOrder.ts`). Grows by new in-scope visits minus reviews: 184 minus 104 in 28 days.
7. **Client activity (about 16 to 19 weeks).** `clients._id-JcxrddMW.js`: the app calls the RPC without `p_limit`, and
   the function ends `limit p_limit`, so it returns every entry. The function already takes `p_limit` and `p_cursor`;
   only the app needs to page. Measured on the 24 biggest clients (12 by jobs, 12 by visits) with "show system" on and
   off; the busiest real client gained 119 rows in 28 days.
8. **Client page photos (about 28 weeks).** `index-M_7TCMGY.js`. The visit list is capped at the 200 newest, but the
   photo links of those visits are not; the two biggest clients gain 14 and 19 links a week. Past 1,000, some visits on
   the page show no photos (the read has no order, so which ones is the table's own order).

## Under 15% of the cap, or scoped to one record

Scoped reads were measured at their biggest record today; none is near the cap and none grows with the business.

- **Visit Calendar, portal `/calendar`:** tasks (`ops.calendar_tasks`, undated plus the grid, at most 62), day
  markers (at most 4), zones 11, trucks 4, drivers 10, service line items 28, dump sites 2, visit requests 12, past
  due 89, push health 1; visit history dialog (each read `.limit(10)` or `.limit(15)`); per-client and per-request
  reads; `get_record_history` (default `p_limit` 50, paged by cursor; the busiest visit has 95 audit rows).
- **DERM Tracker, portal `/derm`:** manifest health page (`manifest_health` not fully complete, `.limit(10000)`: 11
  rows, a backlog), its `manifest_visits .in(...)` (11), pickable visits on Upload (65, a backlog), and the reads scoped
  to one display number, manifest or visit (at most about 20).
- **DERM Stamp Studio, portal `/stamp`:** rows per dump folder (at most 19), printed rules per page (20), page slots
  per page (6), candidate visits per row (12), unlinked visits per client (13).
- **Client App:** client groups (10), intake questions (82), active employees (28), saved views per entity, and the
  client page's contacts, properties, permits, manifests (at most 18), jobs (37), line items (17), manifest links
  (19), status changes (15).
- **Ops Portal admin module:** shift forms (28 days: 31 shifts, with a `truncated` flag), shift reviews (13), one
  visit's photo links (at most 138), classifications (61), driver notes (149).
- **HR App, portal `/hr`:** employees (28).
- **The other set-returning RPCs** (`dump_site_status`, `fn_dump_county_warnings`, `get_review_history`,
  `preview_start_impact`, `start_first_visit`, and the write ones such as `ripple_reschedule_visit` or
  `edit_manifest`) take one visit, one day or a hand-picked list.

## Already paged (no action)

- **DERM Tracker, both hosts:** the dashboard and manifests lists read `visits` (1,575 rows), `manifest_visits` (985),
  `manifests` (954), `manifest_health` (954), `manifest_recipients` (945), deleted manifests and city email sends
  through `fetchAllRows` (live chunk `fetch-all-rows-Cr_tAQtY.js` on derm.unclogme.app; `src/lib/fetch-all-rows.ts`
  in the portal): pages of 1,000, fixed order, stops on a short page, throws on error. `derm.visits` is past 1,000 today,
  so this paging is doing real work: the same read replayed unpaged returns 1,000 of 1,575 (the control).
- **Admin Review, admin.unclogme.app:** the queue page reads (fixed for #186; live chunk `App-DZ9pfyWH.js` carries
  `.range(` on all five).

## Apps with nothing at risk

- **Apps Hub:** one `maybeSingle` read and one access RPC.
- **Field Portal:** no direct table reads; its two RPCs (`get_client_portal`, `get_work_order`) return one JSON value,
  not a set, so the cap does not apply.

## Method

1. **Reads.** Each live host was walked to closure the way `scripts/checks/app-rpc-contract.js` does (absolute and
   relative chunk references, all three quote styles): calendar 3 chunks, derm 27, stamp 7, clients 11, hr 14,
   planner 22, hub 6, fp 18, ops 169, admin 2. An extractor followed every `.from('<table>')` and `.rpc('<fn>')` chain
   and recorded its filters, `.in()`, `.range()`, `.limit()`, `.single()` and `head` counts: 947 call sites in all. The
   portal's local source (`Building Apps/Ops Portal/app`, `ee9d22e`, equal to `origin/main`) gave 309 sites and its live
   bundle 308, so the line numbers above describe what is live. A read counts as a list read when it is not single,
   not a head count and has no `.limit()` of 1,000 or less. Set-returning RPCs were found by looking every called name
   up in `pg_proc.proretset`: 20 of the 110 names return a set.
2. **Rows.** Each read's query was rebuilt as SQL and counted as `postgres` inside a `READ ONLY` transaction through the
   Management API (a negative control, `create temp table`, was refused: "cannot execute CREATE TABLE in a read-only
   transaction"). The two auth-gated RPCs were run with request claims set inside that transaction. These counts skip
   RLS, so they are an upper bound for a signed-in staff user.
3. **Transport check.** The past and near reads were replayed through PostgREST as one unpaged request with
   `Prefer: count=exact`, the same method as `scripts/checks/admin_queue_row_cap.mjs`: rows returned against the
   content-range total. Client App completed visits: 206, `0-999/1648`. Portal drivers: 206, `0-999/1084`.
   `derm.visits` unpaged, the control that must cut: 206, `0-999/1575`. The rest: 200 and complete.
   `derm.v_stamp_clients` answers 403 to the service role (the app reads it as a signed-in user), so its 341 is the
   SQL count only.
4. **Growth.** Whole-table reads: rows created in the last 28 days, divided by 4. Window reads (the Calendar month grid
   and its RPCs): the trend of visits per month from May to October 2026 (140, 151, 217, 183, 235, 214, about 17 more
   each month), scaled to the grid. The Client App "Next visit" read: today's 857 against the same read rebuilt for
   28 days ago (786 to 797). Pending reviews: new in-scope visits minus reviews in 28 days. Every "weeks" figure is
   linear and rounded; a busier season moves it closer.

**Limits of the method.** A chain built across variables, or broken by a comment in the portal source, is read as
having no filter or limit, which over-reports and never hides a read; those cases were checked by hand (Calendar
tasks, DERM duplicate checks). A `.from(<variable>)` is invisible to the extractor; there is one in all the bundles
(Client App `saved_views`, scoped by entity). Reads made inside edge functions were not in scope.

## Not done here

The audit itself was read-only: no app, database object, Lovable project or Trello card was changed while measuring.
The Client App fix came after it, on Fred's go-ahead (second update at the top).

**Who fixes what is still open** (as of the updates above):

- **The portal side of row 6** (and any other portal read): the session named Supabase, which alone works on the Ops
  Portal (root CLAUDE.md).
- **Row 6 on admin.unclogme.app:** a bug fix on the Admin Review Lovable project, which an old host may still take. It
  goes in twice while the old host lives, once there and once in the portal.
- **Rows 7 and 8, the Client App's client page:** a bug fix on clients.unclogme.app. The Client App has no portal module
  yet, so this is not the Supabase session's by rule; Fred routes it. (Rows 1 and 5 are fixed, see the second update.)
