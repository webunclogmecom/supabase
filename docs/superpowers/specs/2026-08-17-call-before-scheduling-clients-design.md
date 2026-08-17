# Design — call-before-scheduling clients

*Written 2026-08-17. Brainstormed with Fred. Origin: Yannick in Slack
([thread](https://unclogme.slack.com/archives/C0B15CHQ1D4/p1785768018332379), 2026-08-03), asking
whether Diego creating a Service Agreement for client 226 is the correct flow. Fred, same thread:
"Mm it's not the correct flow."*

**Status: DESIGN APPROVED, NOT BUILT.** No implementation has started. The 226 cleanup is
deliberately deferred (see § Deferred cleanup).

---

## The problem

A few clients are active but will not accept a visit we schedule unilaterally — **we must call and
get their approval before booking**. Yannick: *"he doesn't want us to go when we want, we need to
call him and he needs to give us his approval. The issue is it's hard to remember to call those
people at the correct time."*

Diego solved the remembering by creating a **Service Agreement job**, because an SA is the only thing
in the system that reliably puts a dated, recurring, unmissable item in front of him.

## Why the SA is the wrong carrier — measured, not asserted

Client **226-JER Jerusalem Pizza** (client 463). On 2026-06-22 Diego created SA job **`99900892`**
(job 1622), *"Service Agreement - Grease Trap Pumping & Tank Cleaning"*, `frequency_days = 60`,
running to 2028.

| what happened | evidence |
|---|---|
| It generated **4 real scheduled visits** | 6537 (2026-08-14), 6538 (2026-10-13), 6539 (2026-12-12), 6953 (2027-02-10), all `source='supabase_cron'` |
| **2 of them reached Jobber** | 6537 and 6538 carry `entity_source_links` rows — they are on the crew's schedule |
| One is flagged **Late**, on a truck | 6537: `late_status = 'late'`, `truck_name = 'Moises'` |
| It poisoned a real signal | `99900892` is the **only** `job_status='late'` Service Agreement in the system — 1 of 1, so that indicator is currently 100% noise |
| **None of them is ever completed** | all 4 still `scheduled`; the Aug 14 one simply aged into Late |

**The scheduling engine's output is a COMMITMENT** — a dated visit, pushed to Jobber, assigned to a
truck, measured for lateness, and expected to produce DERM paperwork. Diego needed a **REMINDER**.
Using one as the other is the whole defect.

### The correct flow already exists — only the trigger is missing

This is the key finding and it shrinks the work. On 2026-08-17 Jerusalem Pizza **was serviced**:
visit **7797**, *"Jerusalem Pizza - 226-JER - Service Call"*, `source='jobber'`, job 1623, status
**`completed`**. The real-world path is already: **call → client approves → a Service Call is created
→ it gets done.** The SA never participates; its visits are never completed.

⇒ **We are not designing a new scheduling path.** Approval already turns into a Service Call through
machinery that works and reaches Jobber correctly. The only thing missing is *the reminder to call*.

### The cost of not having it

Last completed service before today was **2026-06-01**. Today is 2026-08-17 — a **77-day gap on a
60-day permit ceiling** (GDO-03256, `max_frequency_days = 60`, ACTIVE, expires 2026-12-31). The gap
ran **17 days past the permit ceiling** before the call happened. That is the actual business cost of
"it's hard to remember."

---

## Decisions taken (Fred, 2026-08-17)

| question | decision |
|---|---|
| How many such clients? | **A handful, ~2-10.** Real concept, small surface. YAGNI on everything else. |
| What triggers the call? | **A per-client cadence Diego sets** — *not* the GDO compliance clock. |
| Where does it surface? | **Both**: auto-file into the Calendar's **TO BE SCHEDULED** queue *and* a **Slack** reminder. |
| Client says "not now"? | **Snooze to the date the client gives.** |
| Clean up 226 now? | **No — leave it until the replacement flow exists**, so Diego does not lose his only reminder. |

⚠ **The compliance clock was considered and rejected.** Deriving due-ness from
`gdos.max_frequency_days` would be self-maintaining and is the real obligation, but it is close to
`ops.v_service_due`, which Fred **retired from the Calendar on 2026-07-30**. That decision stands.
This spec does not restore it.

---

## Data model

**New table `ops.client_call_policy`** — one row per call-first client.

| column | purpose |
|---|---|
| `client_id` (PK, FK → `public.clients`) | who |
| `cadence_days` (int, not null) | Diego's call cadence (60 for 226-JER) |
| `next_call_at` (date, not null) | when the next call is due; **the only mutable state** |
| `paused` (bool, default false) | "stop calling" without losing the row |
| `notes` (text, null) | free text, e.g. "ask for Sami, mornings only" |
| `created_at` / `updated_at` | standard |

**Why its own table rather than columns on `clients`:** `clients` is Jobber-mastered identity, and
`next_call_at` is local mutable state, not identity. A dedicated table also keeps the concept
droppable if the idea does not survive contact with reality. Rejected alternatives:

- **Columns on `clients`** — would sit on all 439 rows to serve about five, and mixes local policy
  into a synced table.
- **Reuse `service_configs`** — it is the per-(client, service) config home and even has a dead
  `schedule_notes` field (**used 0 times today**), but its `frequency_days` means *recurring service
  cadence*, which is exactly the thing we are trying to stop conflating with *call cadence*. Reusing
  it rebuilds Diego's confusion in a new place.

**Audit (rule #8):** opt **IN**. It is human-editable business policy, so it gets an
`audit_client_call_policy` trigger.

---

## Flow

### 1. Due → queue

A daily job files a normal **`ops.visit_requests`** row when `next_call_at <= today`, marked as
needing a call first (new `call_required boolean` on `visit_requests`, default false).

⚠ **Audit rule #8 applies to that column's table too.** `ops.visit_requests` must be checked for an
existing `audit.log_change` trigger at implementation time and the migration must state opt-in or
opt-out explicitly. Do not assume — generate the audited-table list, per Supabase `CLAUDE.md`.

⚠ **Idempotency:** the job must not file a second request while an open one already exists for that
client. Key on `(client_id, status='open', call_required)` before inserting, so a re-run or a
double-firing cron cannot produce duplicates in Diego's queue.

It appears in the Calendar's existing **TO BE SCHEDULED** panel, where Diego already works.

🛑 **What it deliberately does NOT do, and this is the entire fix:** no date, no Jobber push, no
truck, no lateness, no DERM expectation. A visit request is *dateless by construction*
(Visit Calendar `06-features-and-routes.md`: "a queued request is not a row in `public.visits`… and
reaches Jobber only once scheduled"). The obligation stops masquerading as a commitment.

### 2. Slack points at the queue

One message listing clients due to call, linking into the Calendar.

🛑 **Slack must never hold a task of its own.** It announces what is in the queue and links to it.
If the message and the queue could disagree, we would have rebuilt the original problem in a second
place. Concretely: announce **new arrivals only**, plus an optional weekly digest of still-open
items, so it cannot become wallpaper that everyone learns to ignore.

*Open: which channel and who is tagged — see § Open questions.*

### 3. Outcomes

| outcome | what happens |
|---|---|
| **Approved** | The existing **Schedule** flow turns the request into a real Service Call visit. Untouched machinery, already correct, already reaches Jobber. `next_call_at` is then set to **`visit_date + cadence_days`** — measured from the visit that was agreed, *not* from the date of the phone call, so a call made three weeks early does not drag the whole cadence forward. |
| **Not now** | Diego records the date the client gave. `next_call_at` moves there; the queue item closes and reappears on that date. The cadence re-arms from the conversation, not from a fixed clock. |
| **Stop calling** | `paused = true`. Row kept, so the history and the notes survive. |

---

## GDO ceiling as a warning (approved, kept deliberately small)

The cadence is Diego's number. But 226's 60 days *is* GDO-03256's ceiling, and the manual cadence
still let the gap reach 77 days.

So: **display the client's GDO `max_frequency_days` next to `cadence_days`, and warn when the cadence
exceeds it.** The cadence stays Diego's; the permit merely stops being invisible. This is a display
and validation concern only — **it does not drive scheduling, and it is not a revival of
`ops.v_service_due`.**

---

## Explicitly out of scope

- Restoring `ops.v_service_due` or any general cadence-backlog panel (Fred, 2026-07-30).
- Any change to how approved visits are created or pushed to Jobber — that path already works.
- Automatic calling, SMS, or client-facing notification of any kind.
- Applying this to the other 125 clients that hold an active GDO with a max frequency. This is for
  the handful who require approval, not for compliance tracking at large.

---

## Deferred cleanup — 226-JER (do NOT run yet)

Fred: **leave it until the flow exists**, so Diego keeps his only reminder in the meantime. When the
replacement ships, in this order:

1. Cancel the **4 SA-generated visits**: 6537, 6538, 6539, 6953. ⚠ **6537 and 6538 are live on the
   Jobber schedule** and must leave both sides; 6539 and 6953 are beyond the push horizon and are
   DB-only.
2. Close SA job **`99900892`** (job 1622). This also restores "late Service Agreement" to a
   meaningful signal — 226 is currently the only one.
3. Create the `ops.client_call_policy` row: client 463, `cadence_days = 60`, `next_call_at` =
   2026-08-17 + 60 = **2026-10-16** (from today's completed Service Call 7797).

🛑 Destructive and outward-facing (it removes visits from a crew's Jobber schedule). Needs Fred's
explicit go at the time, not this spec's approval.

⚠ **Do NOT touch job `99900891` / visit 7797.** That is the *correct* flow working — a real Service
Call, completed today.

---

## Verification plan

- **The queue item is inert.** After a due date fires, assert the new `visit_requests` row produced
  **zero** `public.visits` rows, **zero** `entity_source_links`, and no Jobber Task or Visit. This is
  the property the SA violated, so it is the one to test first.
- **Positive control on the trigger:** a client whose `next_call_at` is in the future must produce
  **no** queue row in the same run. A job that files nothing looks identical to a job that is broken;
  the control is what tells them apart.
- **Snooze round-trip:** set a client-given date, confirm the item leaves the queue and returns on
  that date and not before.
- **Approval path unchanged:** scheduling a `call_required` request produces exactly the same visit
  and Jobber push as scheduling any other request. Diff the two.
- **Slack is a pointer:** with an item already announced, a second run must not re-announce it.

---

## Open questions for Fred

Each has a **recommended default**, so the spec is buildable even if none are answered.

1. **Slack channel and recipient.** Which channel, and is Diego tagged directly?
   *Default if unanswered:* post to the same channel Yannick raised this in, and tag nobody — the
   digest names the clients, and tagging is easy to add later but annoying to walk back.
   ⚠ Slack posts go out **as Fred** (`reference_slack_delivery_capabilities`), so the channel choice
   is his call, not a detail to guess at.
2. **Who maintains `ops.client_call_policy`.** Diego editing it in an app, or Fred by hand?
   *Recommended:* **by hand at this size.** Two to ten rows does not justify a CRUD screen, and
   building one now would be the same over-engineering that produced the SA hack. Revisit if it
   passes ~15 rows.
3. **Lead time before the due date.** Should the request appear *on* `next_call_at` or N days before?
   *Recommended:* **3 days before**, and store it as a single global constant rather than a per-client
   column until someone actually needs it to vary. Reaching a client who screens calls takes more than
   one attempt, and 226's gap ran 17 days past its permit ceiling with zero lead time.
