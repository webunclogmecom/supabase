# HR App: editable employee record, pay rates and a pay and bonus history

*2026-10-18 ET. Status: BUILT and live 2026-10-18 (Supabase `2026-10-18_0320`, `_0400`, the health check `_1626`; HR App build published). The review the same night changed the plan: see the two migration headers, which are the record of what shipped (rights rules on email and status, per-source bonus decisions under a lock, Admin Review's $0 rule for a shift with a form issue, company-only bonus amounts until Admin Review reads them). Supersedes the "current value only" pay decision of
`2026-08-31-hr-app-employee-management-design.md` (decision 4) on Fred's word below.*

## 1. The ask

Fred, 2026-10-18, with Yannick's prototype `unclogme-hr_19 (1).html` (module "Employee management"):

> right now i only need is the Clients list and the page where we can see each client data and that we can
> edit ... remember that it also needs to be reflected on other apps when we change stuff and also what i
> want the most is to have the data of the staff members of the company and to be able to put stuff about
> their pay rate, bonuses and stuff, also i think we need like a history of that, linked to where it comes
> from, like a bonus from the Admin Review where they gave the bonus and stuff.

"Clients" here means the people in the HR App: the employee list and the employee record.

**In scope:** the employee list, an editable employee record, pay rates with their history, bonuses with
their history linked to the Admin Review decision that produced them, and the other apps staying correct
after an edit.
**Not in scope** (left exactly as they are today): documents, emergency contact, the Credentials and
Privileges tabs, Add employee, invites, equipment, onboarding, training.

## 2. What is true today (measured 2026-10-18)

- `public.employees`: 21 rows, 9 ACTIVE. Audited. RLS forced; `authenticated` holds SELECT only, and
  **no RPC writes it**: every edit so far was SQL. `full_name` is UNIQUE.
- 16 foreign keys point at it; `visit_team`, `visit_assignments` and `shift_reviews` are ON DELETE
  CASCADE. A hard delete would erase crew and bonus history. Status is the only "delete".
- 19 views read it. Every app shows the LIVE name and colour: Calendar chips, filter and crew picker,
  Admin Review cards and its 11 AM post, the customer-facing Field Portal "driver", DERM "sent by",
  Stamp Studio, DUMP picker. So an edit in one place shows everywhere with no copy to update.
- Two string matches would break on a rename or an email change:
  - `fillout-inspection` resolves the driver by an alias table that maps to `full_name` (exact match).
    A rename makes new shift inspections land with no driver.
  - "Who did it" names everywhere (`fn_page_staff_name`, DERM, Admin Review send history) are matched on
    `employees.email` = the sign-in email.
- Jobber: no employee sync. `userEdit` can change a Jobber user's name only; it cannot change email or
  phone and Jobber users cannot be created through the API. Our names are DISPLAY names (first names for
  most staff, on purpose), so pushing them to Jobber would rewrite full Jobber names to first names.
  **Decision: an HR edit does not write to Jobber.**
- Samsara: `webhook-samsara` only fills a BLANK name, email or phone on a linked driver. An HR edit is
  never overwritten; a value HR clears can be refilled by Samsara.
- Pay: **nothing is stored anywhere.** No pay table, no amount column.
- Bonuses: Admin Review records a STATUS only.
  - `public.visit_reviews` (one row per visit): `bonus_status` pending / approved / denied. 17 approved,
    3 denied ever. The $10 is a constant in the Admin Review code.
  - `public.shift_reviews` (one row per employee and shift date): 3 approved, 1 denied. The $25 is a
    constant in the Admin Review code.
  - `bonus_decided_by` is never written; who decided is only in `audit.logs.jwt_claims`.
  - A visit bonus belongs to the visit; the person is the crew (`visit_team`), which Jobber rewrites.
  - Admin Review writes both tables directly through PostgREST, not through an RPC.
- Hours: Jobber time sheets hold the clocked hours; we do not sync them. On-site minutes are not hours
  worked.
- `audit.log_change` has no arm for `hr.unclogme.app`: an HR write would be labelled
  `other:hr.unclogme.app`.

## 3. Defaults taken (each one is a single place to change)

Fred confirmed on 2026-10-18: pay rates admins only; each person on a two-person crew gets the visit bonus; the Oct 5 shift approved with a form issue stays $0.

| question | default | why |
|---|---|---|
| Who can edit the employee record | admin and office (`access_level`) | the 2026-08-31 design, decision 2 |
| Who can see and edit pay | **admin only** (today: Fred, Yannick) | the most restrictive; one function to widen |
| A visit bonus on a two-person crew | each person on the crew earns their own per-visit bonus | each person has their own rate; 6 of 388 visits in 60 days had two people (Yan's open question) |
| Bonus amounts when a person has no rate of their own | the company default: $10 per visit, $25 per shift | what Admin Review shows today |
| Which day a bonus counts on | the visit date, or the shift date | the payroll week Admin Review uses (Friday to Thursday) |
| Test clients | never earn a bonus | `public.v_non_customer_clients` |

## 4. Design

### 4.1 Who may do what: one gate

`hr.fn_caller_level()` returns the `access_level` of the ACTIVE employee whose email is the caller's JWT
email (`auth.jwt()`, which reads the plural claims), or NULL. `hr.fn_require(p_need text)` raises a plain
sentence (`Please sign in again.` / `Only an admin can see pay.`) with `DETAIL blocker=...`.
`hr.fn_can_see_pay()` is the single place that decides who sees pay.

### 4.2 Editing the record: `hr.update_employee(p_id, p_patch jsonb)`

SECURITY DEFINER, pinned `search_path`, admin or office. Allowlist: `full_name`, `status`, `shift`,
`email`, `phone`, `hire_date`. Not editable here: `id`, `role` (the job-title vocabulary is not decided),
`access_level` (Privileges, phase 3), `color_hex` (must pass the colour rules, Building Apps rule 4b),
`notes` (readable by every staff account through `client.employees`, so it is not an HR field).
Plain-sentence refusals with `blocker=` details: empty name, a name another person already has, an email
that is not an email, a status other than Active/Inactive, a shift other than day/night/empty.
Returns the saved row plus what the change does elsewhere: for a move to Inactive, how many scheduled
visits and open tasks still list the person (they stay assigned; pickers stop offering them).

**Making renames safe everywhere (the rule, not the record):** `fillout-inspection` maps each alias to an
employee **id**, not a name, so a rename can never detach new inspections.

### 4.3 Pay rates: `hr.pay_rates` (insert only, so it IS the history)

| column | |
|---|---|
| `employee_id` | FK employees, NULL = the company default |
| `kind` | `hourly`, `per_visit_bonus`, `per_shift_bonus`, `salary_weekly`, `salary_yearly` |
| `amount` | `numeric(12,2)`, `>= 0`; NULL = "no longer paid this way" from that date |
| `effective_from` | date |
| `reason`, `created_at`, `created_by_email` | who, when, why |

- A change is a new row; a correction is a new row for the same date (the newest written wins). Nothing
  is ever updated or deleted (`fn_append_only_guard`).
- The rate in force on a day: `hr.fn_rate_on(employee, kind, day)` = that person's newest row with
  `effective_from <= day`, else the company default for the bonus kinds.
- Seeded with the two company defaults ($10 per visit, $25 per shift) from 2026-01-01.
- Written by `hr.set_pay_rates(p_employee_id, p_rates jsonb, p_effective_from, p_reason)`, admin only,
  one row per changed kind, reason required.

### 4.4 Bonuses: `hr.bonus_events` (insert only, linked to the Admin Review decision)

One row per person per decision. A grant is positive; a reversal (the review moved back from approved) is
the same amount negative, so the sum is always what is owed and nothing is rewritten.

| column | |
|---|---|
| `employee_id`, `kind` (`visit_bonus` / `shift_bonus`), `earned_on` (visit or shift date) | |
| `amount` (`numeric(12,2)`), `rate_kind` used, `crew_size` | the money and how it was decided |
| `visit_id` (FK visits) or `shift_employee_id` + `shift_date` | **the source**; the app links to `admin.unclogme.app/review/<visit_id>` or `/review-shift/shift-<employee>-<date>` |
| `decided_by_email`, `decided_at` | who approved it in Admin Review, from the request JWT |
| `reverses_id` | the grant a reversal cancels |

- **Filled by the rule, not by hand:** `hr.fn_sync_visit_bonus(visit_id)` and
  `hr.fn_sync_shift_bonus(employee_id, shift_date)` compare the review's status with the person's net
  ledger and add the missing grant or reversal. Triggers on `visit_reviews` / `shift_reviews` call them
  on every write, whatever app or script wrote it. Admin Review needs no change.
- The crew and the rate are taken at the moment of approval; a later crew change in Jobber or a later
  rate change does not move a bonus already granted.
- A trigger failure must never block an Admin Review save: the trigger catches its error, and a nightly
  sweep (`hr.fn_sync_all_bonuses()`, pg_cron) heals any gap. `hr.v_bonus_drift` lists reviews whose
  ledger disagrees; a health item (`hr-bonus-health`) puts any drift in Fred's daily health email.
- Backfilled once from the 17 + 3 approved reviews, with the decider from `audit.logs` and the amount the
  app showed then (the company default).

### 4.5 Reading: gated functions only

- `hr.get_pay_summary()` (pay viewers): current rates per employee, for the list's Pay column.
- `hr.get_employee_pay(p_employee_id)` (pay viewers): current rates, every rate change, every bonus event
  with its source link, totals per payroll week (Friday to Thursday).
- `hr.get_employee_activity(p_employee_id)` (admin and office): changes to the record from `audit.logs`
  (who, when, field, old, new). Pay is not in `audit.logs`: the two pay tables carry their own who, when
  and why and are append-only, so auditing them would only copy pay into `audit.logs`, which every
  signed-in database role can read. **Rule 8: both pay tables opt OUT, for that reason.**
- No `hr` table is granted to `anon` or `authenticated`; RLS forced; the app reads through the functions.

### 4.6 Attribution

`audit.log_change` gets `hr.unclogme.app` and the project id `816f8580` mapped to `hr-app`, spliced from
the live body with its md5 pinned.

### 4.7 The app (Lovable project `816f8580`)

- **List:** unchanged, plus the Pay column filled from `hr.get_pay_summary()` when the viewer may see
  pay (empty dash otherwise).
- **Record tab:** the Canonical record card's **Edit** opens a dialog (full name, status, shift, email,
  phone, hire date) that calls `hr.update_employee`; before saving it says what changes elsewhere
  ("This name shows in the Calendar, Admin Review and on customer service reports").
- **Pay rates card:** current rates; **Edit pay** opens Yannick's pay dialog (hourly, per visit bonus,
  per shift bonus, salary) plus "Starts on" and "Reason".
- **Pay and bonus history card** (new, below Pay rates): newest first, one line per rate change ("Per
  visit bonus $12 from Oct 20, by Fred: raise") and per bonus ("Visit bonus $10, Oct 3, 034-LG, approved
  by Serena in Admin Review", the visit opens in Admin Review); a week filter with the week's total.
- **View audit log** (Quick actions) opens the record's activity.
- Unchanged: Emergency contact, Documents, Credentials, Privileges, Add employee (still disabled), the
  protected sign-in files.

## 5. What reflects in the other apps

| change | where it shows | anything to build |
|---|---|---|
| name | every app, at once (they read the live row) | `fillout-inspection` by id (4.2) |
| status Inactive | gone from every picker; future visits stay assigned | the save says how many |
| email | sign-in name labels in every app | the dialog warns it must be the sign-in email |
| phone, shift, hire date | HR App (Calendar roster view exposes phone; no app shows it) | none |
| bonus approved in Admin Review | HR App history, automatically | the triggers (4.4) |

Later, not now: Admin Review's $10 and $25 constants could read `hr.fn_rate_on`; hourly earnings need the
Jobber time sheet sync.

## 6. Order and checks

1. Migration A (`hr` gate, `update_employee`, `hr.unclogme.app` audit arm) and Migration B (pay rates,
   bonus events, triggers, sweep, drift view, health, backfill, readers). Each rehearsed with COMMIT
   replaced by ROLLBACK, with a VERIFY block and rolled-back probes as `authenticated` (an admin JWT, an
   office JWT, a non-staff JWT) proving who can call what; `relacl` asserted on every new table.
2. `fillout-inspection` by id: deploy, then replay a test payload with a renamed employee in a rolled-back
   probe.
3. The HR App build in Lovable, published; the live bundle checked; one real edit and one rate change
   made on a test basis and put back; the protected files' md5 unchanged.
4. Docs: HR App `08-changelog.md`, `02-architecture.md`, `09-known-issues.md` (and a new HR App
   `CLAUDE.md`), Supabase `CLAUDE.md` and `docs/schema.md`, the decisions register.
