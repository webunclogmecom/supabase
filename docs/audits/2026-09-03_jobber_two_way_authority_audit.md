# Jobber two-way authority audit, 2026-09-03

**Fred:** *"Need you to do a digging/audit on all the Apps that when anything there changes it also
affects Jobber, like Clients or Calendar App, and I need you to verify that it's a Two-Way, and no
one has a better say than the other (i mean between the App and Jobber)"*

Read-only audit. Nothing was changed.

---

## The answer in one line

**No. Of roughly 36 field groups that both an app and Jobber can write, exactly TWO are genuinely
two-way.** Everything else is decided by an unannounced precedence rule, and in most cases neither
side is ever told the other disagreed.

A field is only two-way if a change on either side reaches the other **and** a simultaneous change on
both is DETECTED rather than silently resolved. "Last writer wins" is not two-way. "The poll
overwrites us every five minutes" is not two-way.

---

## The three tiers

### 1. Genuinely two-way (2 fields)

Both are property custom fields, and both work because of the same machinery:
`sync.source_field_shadow` stores **what we last saw on Jobber's side**, so `sync.fn_shadow_decision`
can tell "Jobber changed it" from "we changed it" from "both changed it". Both-changed returns
**CONFLICT** and the row freezes until a person decides.

| field | shadow rows | open conflicts |
|---|---|---|
| `properties.grease_trap_size_gallons` | 479 | 0 |
| `properties.lock_box_key` | 476 | 0 |

⚠ One deliberate asymmetry on the lock box: **a CLEAR is not pushed.** Emptying it here leaves
Jobber holding the old key, so a driver still sees a code that no longer applies. It is recorded as
`skipped` with a reason rather than silently dropped, and the app says so.

**This is the pattern to copy.** It is the only mechanism in the estate that can distinguish the
three cases, and it required a stored "last seen" value. Nothing else has one.

### 2. Partial: detected and escalated, but not everywhere

`sync-jobber-visit-drift` compares visit date and time against Jobber every 30 minutes and
classifies the disagreement into heal / adopt / surface. A **surface** outcome is never auto-resolved
and escalates by email.

⚠ It covers only visits that are DB-mastered, still scheduled, and already linked in Jobber:
**244 of 784** scheduled visits on the last run. The other 537 are future SA visits beyond Jobber's
60-day horizon, so they do not exist there yet and genuinely cannot drift.
⚠ Its `time_refinement` branch deliberately adopts Jobber's time when the date agrees. That is a real
collision resolved silently in Jobber's favour, and it is the mechanism behind the `start_at` drift
measured below.

### 3. Everything else: a silent precedence rule

Roughly 15 fields where both sides write and nobody detects the clash, 6 push-only, 3 pull-only.

---

## What has ACTUALLY happened, measured from `audit.logs`

The matrix answers "does a mechanism exist". This answers "has it bitten". Method: find where the
**next** change to a column an app had set was Jobber landing on a **different** value, with no
intervening app write. Since 2026-07-02 (the operating-date rewrite):

| table | app | column | cases | rows | most recent |
|---|---|---|---|---|---|
| visits | visit-calendar | `start_at` | 127 | 87 | 2026-08-31 |
| visits | visit-calendar | `end_at` | 126 | 86 | 2026-08-31 |
| visits | visit-calendar | `completed_at` | 11 | 10 | 2026-08-31 |
| visits | visit-calendar | `visit_date` | 9 | 9 | 2026-07-22 |
| jobs | client-app | `job_status` | 8 | 5 | 2026-09-01 |
| visits | visit-calendar | `visit_status` | 2 | 2 | 2026-08-31 |
| visits | visit-calendar | `service_type` | 1 | 1 | 2026-07-23 |
| visits | visit-calendar | `completed_by` | 1 | 1 | 2026-07-10 |
| clients | client-app | `status` | 1 | 1 | 2026-08-13 |

**How far Jobber moved the value**, which is what separates rounding from lost work:

| column | cases | <=15 min | 15 min-2 h | 2 h-1 day | **>= 1 full day** | worst |
|---|---|---|---|---|---|---|
| `start_at` | 127 | 10 | 56 | 61 | **0** | 12 hours |
| `visit_date` | 9 | 0 | 0 | 0 | **9** | **4 days** |

⇒ **Date-level conflicts stopped.** All nine are on or before 2026-07-22 and five cluster on
2026-06-29, the +/-1-day oscillation the operating-date rewrite closed on 2026-07-02.
⇒ **Time-of-day drift is ongoing.** 127 cases to 2026-08-31; 61 of them move the time by more than
two hours. Never a different day.

🛑 **A NAIVE VERSION OF THIS QUERY OVERSTATES IT BY A THIRD.** Pairing an app write with any later
Jobber write inside 24h returns 170 `start_at` cases, because it counts rows where the USER changed
the value again in between and Jobber then agreed with the newer value. The 127 above requires that
no app write intervened. Anyone re-running this must exclude that confound.

---

## 🛑 A finding from the audit pass that MEASUREMENT REFUTED

The audit reported *"Client primary email and phone: `handleClient` rewrites the primary contact on
every client update, roughly 400 replays a day"*, citing a real value flip on 2026-09-03 at 14:42 ET
where one person's email and phone were replaced by another's.

**The flip is real. The attribution is wrong.** That write carries `app_source='sql'`, i.e. a direct
script or Management API write, not the Jobber sync. Measured across the whole table:

| writer | UPDATE | INSERT | DELETE |
|---|---|---|---|
| `sql` | 296 | 26 | 3 |
| `client-app` | 7 | 2 | 3 |
| **`jobber`** | **0** | **0** | **0** |

`jobber` has **never** written `public.client_contacts` in any operation, and the table is audited
(322 rows prove the trigger fires). So there is no evidence the Jobber sync has ever overwritten a
contact. The structural claim about the code may still hold for a path that has never fired, but the
alarming half of that finding does not stand.

**Kept here on purpose.** It is the same failure this repo keeps paying for: a correct measurement
with the wrong mechanism bolted onto it. The tell was that `app_source` was never checked.

---

## Verified "app wins", and the one that should worry us

`jobs.billing_type`, `jobs.invoice_frequency`, `jobs.invoice_rrule`: **475 jobs carry a stored
billing type, and the only writers that have ever changed it are `client-app` and `sql`.** `jobber`
writes `public.jobs` but has **never** written those columns.

⇒ There is no inbound reader. Change how a job is billed in Jobber and this app keeps showing, and
re-asserting, the old arrangement. Nothing anywhere can tell you whether the stored value still
matches. **Jobber is the billing master, so this is the one inversion with money attached.**

Other confirmed pins, all deliberate and all correct in intent:

| pin | count | why it exists |
|---|---|---|
| `clients.status_source = 'manual'` | protects a deliberate deactivation from the `*/5` poll | a poll reactivation used to silently undo it |
| `clients.client_class_source` | 3 clients | Jobber's `isCompany` is wrong for 119-ME, 121-FRO, 126-YM |
| `visits.derm_required_locked` | 169 visits | a human's compliance answer must outrank a nightly re-derive |

⚠ **None of the three tells anyone that the two systems now disagree.** 5 of 12 INACTIVE clients were
still active in Jobber as of 2026-08-21: someone looking at Jobber sees a live client we consider
closed, and neither side will ever learn.

---

## Ranked by what it would actually cost

1. **Job billing type and invoice schedule have no inbound path** (475 jobs). Jobber owns billing;
   we assert it and never re-read. Verified.
2. **Visit completion can be reversed without a trace.** A dispatcher un-completes a visit because
   the crew did not do the work, and a Jobber-side writer puts it back. Measured: 11 `completed_at`
   and 2 `visit_status` reversals since 2026-07-02, latest 2026-08-31. This already invalidated a
   DERM manifest link once (visit 6756), which is a county filing asserting work that did not happen.
3. **Start-time drift, 127 cases, unexamined.** Ongoing, never a different day, but 61 move by more
   than two hours. Needs a decision on whether the Calendar's time is authoritative or provisional.
4. **Silent divergence with no announcement** on every pinned field. The pins are right; the silence
   is the defect.

## Not measured

- Whether the `start_at` drift represents lost dispatcher intent or a legitimate Jobber refinement.
  That is a product question, not a data one.
- Fields on tables with no audit trigger. Only 31 tables carry one, and audit silence on the other
  tables proves nothing.
- `audit.logs` records successes only, so a write that always FAILS leaves no trace here.
