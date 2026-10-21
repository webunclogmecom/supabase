# HR bonus rules: how a visit or shift bonus is decided, priced, recorded and changed

One page for every rule about the driver bonuses, as of 2026-10-21. The rules live in the database (`hr` schema); the
apps only show them. Before changing anything here, read the function named in each rule, and run the probes at the end.

## 1. Where a bonus comes from

| | visit bonus | shift bonus |
|---|---|---|
| decided in | Admin Review `/review/<visit>` | Admin Review `/review-shift/shift-<employee>-<date>` |
| stored as | `public.visit_reviews.bonus_status` | `public.shift_reviews.bonus_status` |
| who earns it | every person on the Visit Calendar crew (`visit_team`), each at their own amount | the person whose shift it is |
| recorded in HR by | trigger `zz_hr_bonus_sync` -> `hr.fn_sync_visit_bonus` | trigger `zz_hr_bonus_sync` -> `hr.fn_sync_shift_bonus` |

- `hr.bonus_events` is append-only: an approved bonus is one row per person (a "grant"); a decision that no longer stands
  adds a negative row (`reverses_id`). Nothing is ever edited or deleted. The hourly sweep (`hr-bonus-sweep`, :41) repairs
  a missing grant, never an amount.
- Test clients (`public.fn_is_non_customer`, e.g. 112-YA) never earn a bonus.

## 2. When a visit bonus is approved

- **Every photo section's "Bonus" is Approved** (Before, After, Internal). One Rejected = no bonus ($0). This is the app's
  rule: Admin Review writes `bonus_status = 'approved'` only then. Quality (Correct / Flag) is separate and only on the
  after-work sections (Yan, huddle 2026-10-19).
- **Every photo is sorted** (Fred, 2026-10-20: "all the pictures there has to be sorted and Approved before the drivers get
  the bonus from now on"). Trigger `ab_bonus_needs_sorted_photos` refuses moving a visit bonus TO approved while
  `public.v_visit_photo_counts` shows a photo not sorted (`2026-10-20_1935`). A bonus approved before that, or before a
  late photo arrived, stays approved. The review page also shows the photo sections only once every photo is confirmed.

## 3. How much

- **Per person** (`2026-10-19_1200`): each person's own dated amounts in `hr.pay_rates` (`per_visit_bonus`,
  `per_shift_bonus`). No amount = $0. Set in the HR App (Pay rates card) through `hr.set_person_bonus`.
- **The amount on a day** is `hr.fn_rate_on(person, kind, day)`. Since `2026-10-21_1553` (Trello ZEYkT63t, Fred) an
  approved shift is paid also when a form is missing or reports an issue, with a note saying so; only a shift with no form
  at all records $0 (rule `forms_issue`). Before that, a missing form or an issue meant $0.
- **"Since" a date replaces every later dated amount** (`2026-10-21_0511`, Fred: "make since replace later amounts
  too"). Rows written by `set_person_bonus` carry `replaces_later`; `hr.fn_rate_superseded(id, person, kind, from)` is the
  ONE rule (an older row stops counting once a newer `replaces_later` row starts on or before its date). Every reader of
  dated amounts calls it: `fn_rate_on`, `get_person_bonus_amounts` (Admin Review prices from those rows), the record's
  "next change", the setter and the preview. 🛑 A new reader of `hr.pay_rates` that skips it prices with replaced amounts.
  Rows from before 2026-10-21 05:11 ET are `false` and keep the old meaning. Hourly pay is not affected.
- **A custom amount for ONE person on ONE visit** (`2026-10-20_1935`, Yan: "to replace the 13 by something else"): set in
  Admin Review (pencil on the green "Photo Bonus" amount) through `hr.set_visit_bonus(visit, person, amount | null,
  reason)`. It REPLACES the person's amount on that visit; NULL goes back to normal. Kept in `hr.visit_bonus_overrides`
  (append-only, newest row wins, who / when / optional why). `hr.fn_visit_rate_on` prices a visit: custom first, else
  `fn_rate_on`.
- **A custom amount for ONE person on ONE shift** (`2026-10-21_1250`, Fred: "same with the custom bonus for the Visit
  Bonus at the Visits reviews, let's do it for the Shift bonus"): set in Admin Review (pencil on the green "Shift Bonus"
  amount) through `hr.set_shift_bonus(person, shift date, amount | null, reason)`; the shift must have a form. Kept in
  `hr.shift_bonus_overrides` (append-only, newest row per person and shift date wins), read through `hr.fn_shift_rate_on`.
  The shift is (person, shift date) of `public.v_inspection_shifts`, as `shift_reviews` keys it.

## 3b. Which forms make one shift (`2026-10-21_1553`, Trello ZEYkT63t)

Fred: *"the night shift is split across two calendar days ... We need to merge them into one shift."*
- **`public.v_inspection_shifts` is the ONE rule** (one row per person per shift). A POST closes the latest PRE of the
  same person filed before it within 24 hours, with no other POST in between. The shift is dated by its PRE's ET clock
  date; a POST with no PRE filed before noon ET belongs to the night before. Every reader of a shift's forms uses it:
  `fn_sync_shift_bonus`, `fn_pending_bonus`, `get_employee_record`, `set_shift_bonus`, `fn_admin_review_url`, and
  Admin Review's queue and Shift Form Review. 🛑 Never group `inspections` by `shift_date` again: a night POST carries the
  next day's date, which is how a night driver's "complete" shifts were halves of two different nights.
- (person, date) is unique from 2026-09-01; 13 Airtable-era shifts before it collide. A new collision is the health item
  `shift_pairing_collision` (`hr.v_bonus_drift`).
- **Pending** counts undecided PAIRED shifts (an issue no longer blocks); a one-form shift is paid only once a person
  approves it in Admin Review, after the app's "The PRE form is missing" confirmation.

## 4. Pending versus approved

- **Pending** (not decided yet) is priced live, so it always follows the current amounts: `hr.fn_pending_bonus` (the
  Employees list "Pending"), the pending rows of `hr.get_employee_record`, Admin Review's undecided amounts.
- **Approved** is the amount recorded in `hr.bonus_events` when it was approved. Nothing changes it automatically. It moves
  ONLY by a person's act:
  1. a custom visit amount set or changed after the bonus was recorded (`fn_sync_visit_bonus` takes it back and records it
     again; `bonus_events.override_id`), and the same for a custom shift amount (`fn_sync_shift_bonus`,
     `bonus_events.shift_override_id`; notes "Replaced by the custom amount set for this shift." / "The custom amount for
     this shift was removed.");
  2. the HR App checkbox "Also update approved bonuses since <date>" (unticked by default, `2026-10-21_0359`):
     `set_person_bonus(..., p_update_approved => true)`. Which bonuses move is ONLY `hr.fn_bonus_reprice_rows`: every
     approved one of that kind from the date on, not already at the new amount, except a visit or a shift with its own custom
     amount and a $0 forms-issue shift. `hr.preview_person_bonus` gives the dialog its count, net change and `replaces` list.
     Each moved bonus is a reversal plus a new grant, both with `reprice_rate_id`, `filled_by = 'rate_change'`.
- A take-back stays in the payroll week of the work.

## 5. Who can do what

| action | who |
|---|---|
| approve / reject a bonus | Edit in Admin Review |
| see amounts | the HR "See bonus amounts" setting (admin and office by default); otherwise apps show "Hidden" |
| change a person's amount, the checkbox, a custom visit or shift amount | admins, or office with "Pay rates and bonus settings" (`hr_pay`); the custom amount also needs Edit in Admin Review |

## 6. What people see

- **Admin Review:** "Photo Bonus" in the Review Summary is Pending, red "$0 Rejected", or the green amount per person with
  the pencil and a "Custom" tag. "Shift Bonus" on the Shift Form Review works the same way, with one amount (the driver's).
  Approved bonuses show the recorded amount, never re-priced in the app.
- **HR App:** the history shows every bonus with its status, a change as "Bonus taken back" plus a new row with a note
  (custom: "Custom amount for this visit, set by <name>: <why>", or "... for this shift ..."; amount change: "Amount changed to $X from <date> by
  <name>: <reason>"). Activity lists amount changes (RATE), custom amounts (app Admin Review; a shift one reads "Shift bonus, <date>"), "Approved bonuses updated"
  and "Replaces later amounts". A custom amount on a test-client visit never shows in HR (`2026-10-21_0337`).
- **Daily health email** (`log_hr_bonus_health`, 9:27 ET): drift, people with no amount, a take-back after its week ended,
  and ONE item per amount change applied to ended weeks with the net to adjust ("If those weeks were paid, adjust the next
  pay by that amount").

## 7. How to test

- Probes (rolled back, nothing kept): `node scripts/checks/hr_app/run.js` (all HR checks, 135 on 2026-10-21), in
  particular `probe_visit_bonus_custom.sql` (custom amount, sorted photos, test client), `probe_shift_bonus_custom.sql`
  (custom shift amount, an approved issue shift is paid, the checkbox leaves it alone), `probe_shift_pairing.sql` (night
  shifts paired, a morning POST to the night before, one-form and issue shifts paid once approved, the repair) and
  `probe_bonus_reprice.sql` (the checkbox, replacing later amounts, health item). The probes pick their office fixture live (an active office person with no
  access settings of their own) and read each person's own amounts: never hardcode a person or a $10 / $25 amount.
- In the app, ONLY on the test client: Admin Review `docs/07-smoke-tests.md` (112-YA visit 8113). Never save a test on a
  real person: every row is append-only and lands in their pay record.

## 8. Migrations, in order

`2026-10-18_0400` (bonus events, triggers, sweep) · `2026-10-18_1626` (health) · `2026-10-19_1200` (per person) ·
`2026-10-19_1815` (any start date, pending only, `get_review_bonuses`) · `2026-10-19_2130` (payroll week per person) ·
`2026-10-20_1935` (custom visit amount, sorted photos) · `2026-10-21_0337` (test client out of HR) · `2026-10-21_0359`
(update approved since a date) · `2026-10-21_0511` ("since" replaces later amounts) · `2026-10-21_1250` (custom shift amount) · `2026-10-21_1553` (shift pairing, approved shifts paid, Michael's 5
  reviews repaired). App docs: Building Apps
`HR App/CLAUDE.md` section 4 and `Admin Review/CLAUDE.md` rule 6.
