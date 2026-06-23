# Calendar App — "Create Visit" redesign (Jobs-workflow compliant)

*Design — 2026-06-23 · owner: data-ops (Supabase) + Visit Calendar (Building Apps) · Fred-approved*

## Problem

The Calendar App (`calendar.unclogme.app`, Lovable `6533c3ee…`, reads/writes Prod
`wbasvhvvismukaqdnouk`) is the **single source of truth for visits**. Its existing
"Create Visit" form (built 2026-06-01) picks a job from `ops.client_jobs` and a service from
the **generic 27-item** `service_line_items` dropdown. After the 2026-06-23 Jobber Jobs
restructure (every client now has a clean **Service Call** job + recurring clients have
**Service Agreement** jobs carrying a Frequency + agreed line items), that form is no longer
workflow-aware: it has no explicit client picker, no Service-Call-vs-Service-Agreement
framing, and it offers the whole catalog instead of *the chosen job's actual agreed services*.

## The jobs ↔ visits ↔ calendar workflow (canonical)

- **Job types.** `public.jobs.title = 'Service Call'` → **SC** (ad-hoc one-offs).
  `title ILIKE 'Service Agreement%'` → **SA** (recurring; `jobs.frequency_days > 0`, agreed
  line items). `job_status <> 'archived'`. Old jobs were renamed `… [OLD]` and are excluded.
- **A visit belongs to a job** via `visits.job_id`. SA visits recur per `frequency_days`;
  SC visits are manual one-offs.
- **Services = line items** from the canonical `public.service_line_items` taxonomy (codes
  01–27): SA items **01–08**, SC items **09–24**, fees 25/26, GDO reporting 27. A visit's
  `service_type` (GT/CL/WD) is derived from its primary line item; **DERM is required iff a
  pumping item (01–04 / 09–11) is present** (`service_line_items.requires_derm`).
- **Location grain.** A visit hits one **property** (address) and one or more
  **`client_locations`** (tenant/manhole) via `visit_locations` (M:N). Single-site clients
  default to their `'Main'` location + primary property.
- **Source of truth.** Calendar writes `public.visits` with `source='visit-calendar'`; a DB
  trigger pushes to Jobber via `jobber-push-visit`, **gated to client 112-YA (id 381)** until
  go-live.

## Live DB readiness (probed 2026-06-23)

| Need | State |
|---|---|
| `service_line_items` (8 SA + 16 SC + fees, derm flags, all schedulable) | ✓ |
| `client_locations` (419 locs / 410 clients, 405 "Main") | ✓ |
| `ops` views (`client_jobs`, `v_calendar_visit`, `v_calendar_visit_detail`, truck/driver) | ✓ |
| `visits` cols (`job_id`, `service_line_item_id`, `derm_required`, `property_id`) | ✓ |
| **SA jobs' line items in `public.line_items`** | ✗ **GAP: 161 new SA jobs, 0 have line items** |

**Root cause of the gap:** the restructure created SA jobs *with* line items in Jobber, but
the jobs poll (`sync-jobber-poll`) is `createdAt`-cursored and **does not pull `lineItems`**
— so the agreed services never landed in our DB. (Same family as `reference_jobs_sync_gaps`.)

## Design

### DB layer (this repo)

1. **Job line-item sync — `scripts/sync/sync_job_line_items.js`.** Read-only fetch from
   Jobber of every non-archived **SA** job's `lineItems` → upsert into `public.line_items`
   (`job_id` scope; idempotent on `(job_id, name)`). SC jobs are intentionally empty
   (services chosen at visit time). Documented as a recurring need: add `lineItems` to the
   jobs poll + `handleJob` so this stays fresh (tracked under `reference_jobs_sync_gaps`).

2. **View `ops.client_service_options`.** One row per (client, non-archived SC/SA job):
   `client_id, client_code, client_name, job_id, job_number, job_kind ('SC'|'SA'),
   job_title, frequency_days, property_id`, plus the SA's agreed services as a JSON array of
   `{code, title, requires_derm}` (line_items joined to `service_line_items` by the leading
   `NN -` code). Anon + authenticated SELECT.

3. **Catalog + locations** the form also reads directly: `service_line_items`
   (`reason='Service Call' AND schedulable` for the SC picker), `client_locations`,
   `properties` (per client).

4. **`derm_required`** is derived at create time from the chosen line items
   (`bool_or(requires_derm)`) and stored on the visit.

### Form (Visit Calendar Lovable app — built by me, no Building Apps handoff)

Guided flow, replacing the current job+service dropdowns:

1. **Client** — searchable picker (code + name).
2. **Service options load** for the client (from `ops.client_service_options` + locations +
   properties).
3. **Pick the job:** a **Service Agreement** (renders its agreed line items read-only +
   frequency; visit inherits them) **or** the **Service Call** (pick service(s) from the SC
   catalog 09–24). Clients with neither → message + link to set up a job in Jobber.
4. **Property + location(s)** — default primary property / "Main"; multi-location clients
   choose the tenant/manhole.
5. **Date** (+ optional time), **instructions**, optional vehicle.
6. **Create →** `public.visits` (`job_id`, primary `service_line_item_id`, derived
   `service_type` + `derm_required`, `property_id`, `source='visit-calendar'`,
   `visit_status='scheduled'`) + per-visit `line_items` (`visit_id` scope) + `visit_locations`.

### Jobber push (NOT changed here)

The visit→Jobber push stays **gated to 112-YA**. Widening it writes to Jobber → Fred's
go/no-go (the restructure precondition is now met). The form is correct for all clients in our
DB regardless; un-gated clients simply stay DB-only until go-live.

## Testing

- DB: after the sync, every non-archived SA job has ≥1 `line_items` row mapping to a
  `service_line_items` code; `ops.client_service_options` returns SA rows with non-empty
  services + SC rows.
- Form: SC path (ad-hoc service pick) and SA path (inherited services) each create a valid
  `visits` row + `line_items` + `visit_locations`; `derm_required` correct for a pumping item.
- 112-YA SA + SC create round-trips push to Jobber (existing gate); revert test visits.

## Out of scope / follow-ups

- Widening the Jobber push gate (Fred go/no-go).
- Adding `lineItems` to the jobs poll (durable fix for the sync gap) — flagged.
- SA visit-generation cron go-live (separate, gated on the push decision).
