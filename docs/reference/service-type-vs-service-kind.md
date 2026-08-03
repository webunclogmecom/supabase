# `service_type` vs `service_kind` — why the legacy column stays (2026-08-03)

**Fred asked:** *"should that not be the 'pumping', 'cleaning' and 'warranty' instead? because
they're the real 'type' of a service, because having `service_kind` and `service_type` is the same
but with different wording, be critic and think first before answering."*

## 🛑 CONCLUSION REVISED 2026-08-03 — FRED IS RIGHT. THE RENAME SHOULD HAPPEN.

An earlier version of this document concluded "keep the key, it is not a rename". **That was
wrong, and it was wrong because I argued from the constraint instead of measuring the data.**
Three checks overturned it:

**1. The sheet is the authority, and it says the type is column G.** Read live from
`19ArflSwdhcpnu1U6Lii5q2VFmDLjwskurDCghN0aanE` on 2026-08-03. Column F = reason, **column G =
the service type**, column H = the equipment, column I = method. Row for code 04:
`Service Agreement | Pumping | Lift Station & Tank Cleaning`. **The sheet itself calls Lift
Station "Pumping".** Diffed all 20 rows against the DB: `service_kind` matches column G
**20 of 20, zero mismatches**; `location_target` matches column H on 19 of 20 (code 13 differs
only by a double space).

**2. `service_type` is not a taxonomy, it is a sparse legacy label.** It is **NULL on 11 of the
20** catalogue codes: 03 Grey Water, 04 Lift Station, 08 Warranty, 10, 11, 15-18 Unclogging,
19 Camera Inspection, 20 Dye Test. It only ever covered grease trap and cleaning.

**3. LS is dead, so the "blockers" were hollow.** Measured:
   - All **7 LS `service_configs` rows are completely empty** — 0 have a frequency, 0 have a price.
     Deleting or folding them costs nothing; the UNIQUE-violation objection evaporates.
   - **15 LS visits exist in total**, all `completed`, all `source='jobber'`, **0 scheduled in the
     future**, last one 2026-05-24. Eleven belong to one client (057-BAY), many on consecutive days,
     which is one-off work and not a cadence.
   - LS is **already excluded** from all three cadence filters, so those visits contribute nothing
     today. Folding them into Pumping *gives* them an anchor they currently lack rather than
     corrupting one.

**So the end state is `Pumping` / `Cleaning` / `Warranty of Drainage`, with LS folded into Pumping.**
What remains is mechanical, not conceptual, and is listed in §2 below: 13 literal call sites, 2 CHECK
constraints, `fn_check_gdo_on_visit`, `webhook-jobber`, and the `client_services_flat` GT/CL/WD pivot.
It must land as ONE migration — rewriting `visits` but not `service_configs` breaks every join
silently rather than loudly — and should be proven by a before/after comparison of every client's
computed cadence.

⚠ The one genuinely separate issue: **CL is only 36% actually Cleaning** at the visit level (54 of
151 derivable). That is a data-quality problem that exists today under the name "CL" and will still
exist under the name "Cleaning". Fix it separately; it is not a reason to keep the old vocabulary.

---

*The original analysis follows. Its §2 (what depends on the column) and §3 (CL accuracy) are still
accurate and are the migration checklist. Its top-line conclusion is superseded by the above.*

**Superseded answer:** *he is right about the words, and right that the two columns are the same
axis, but wrong that this makes it a rename;* `visits.service_type` *is a series key, so do the
label fix and leave the key alone.*

---

## 1. They ARE the same axis — the "equipment vs action" defence is wrong

⚠ **This corrects an answer given to Fred earlier in the same session.** The argument was that
GT/LS encode EQUIPMENT while `service_kind` encodes ACTION, so a merge would lose information.
That is false: the equipment axis is **a separate column that already exists**,
`service_line_items.location_target`.

`public.service_line_items` decomposes a service into five columns:
`reason`, `service_kind`, `location_target`, `method`, `service_type`.

```
01 SA | Pumping  | Grease Trap & Tank Cleaning         | GT
02 SA | Pumping  | Grease Trap, Tank Cleaning & Warr.  | GT
03 SA | Pumping  | Grey Water                          | NULL
04 SA | Pumping  | Lift Station & Tank Cleaning        | NULL
09 SC | Pumping  | Grease Trap & Tank Cleaning         | GT
05/06/07/12/13/14  Cleaning                            | CL
08    | Warranty of Drainage                           | NULL
```

`service_type = 'GT'` is exactly `location_target LIKE 'Grease Trap%'`. **No row has GT with a
non-grease-trap target, and none has a grease-trap target without GT.**

⚠ A strict test — `(service_type='GT') IS DISTINCT FROM (location_target LIKE 'Grease Trap%')` —
returns **8 rows** and looks like a refutation. It is not. All 8 are `service_type IS NULL` rows
(codes 03, 04, 10, 11, 15, 16, 17, 18): `NULL = 'GT'` yields NULL, and `NULL IS DISTINCT FROM false`
is true. **A NULL artefact in the instrument, not a counterexample.** Inspect the rows before
concluding — this nearly became a wrong retraction of a correct finding.

`service_type` is populated on only **9 of 28** catalogue rows, and on those 9 it is a pure function
of `service_kind` + `location_target`. It carries no information the other columns do not hold.

**The one apparently two-axis object is not a counterexample.** `ops.fn_service_group(reason, kind,
type)` splits Pumping into `PUMPING_GT` vs `PUMPING_OTHER`. Both callers — `ops.v_calendar_visit`
and `ops.client_service_options` — pass the **catalogue** row, never a visit's or a config's value.
Rewritten as `location_target LIKE 'Grease Trap%'` it is equivalent.

## 2. So why keep it? Because it is a KEY, not a name

In the live `ops.v_calendar_visit`:
- `PARTITION BY visits.client_id, visits.service_type` — the observed-cadence window
- `prev.service_type = v.service_type` — the lateness anchor (`last_completed_date`, `prev_live_date`)
- `LEFT JOIN service_configs sc ON sc.client_id = v.client_id AND sc.service_type = v.service_type`

And `public.service_configs.service_type` is **NOT NULL** with **`UNIQUE (client_id, service_type)`**
(270 rows: GT 183, WD 48, CL 32, LS 7).

**Measured blockers to a value rewrite:**

| Blocker | Evidence |
|---|---|
| Unique-constraint violation | **7 clients hold BOTH a GT and an LS config** — 025-GRO, 057-BAY, 070-TCE, 083-SHUL, 116-HIK, 167-FEN, 168-AVA. Both map to Pumping, so the index is violated. |
| Silent cadence corruption | Merging GT+LS changes the median gap on **3 of 6** testable clients: 083-SHUL 57→42 days, 168-AVA 12→9, 057-BAY 2→3. Wrong lateness, no error raised. |
| Blast radius | **45 objects** reference `service_type`; **13** compare it to a `GT`/`CL`/`WD` literal, plus 2 CHECK constraints, `fn_check_gdo_on_visit` (gates GDO compliance on `!= 'GT'`), and `webhook-jobber` (hard-codes the vocabulary in 18+ places). |
| Vocabularies differ per table | The catalogue holds **zero** WD and **zero** LS rows, yet `service_configs` has 48 WD / 7 LS and `visits` has 141 WD / 16 LS. There is no single global find-and-replace. |

## 3. And the label is not accurate enough to promote

Live visits, `service_type` vs the kind derived from their line items:

- **GT → Pumping on 1,080 of 1,116 derivable (96.8%)** — trustworthy.
- **CL → Cleaning on only 54 of 151 derivable (36%)** — the rest are Unclogging 43, Labor 39,
  Dump Offload 8, Pumping 4, Warranty 2, Assessment 1.

Renaming CL to "Cleaning" would promote a **36%-accurate** value into an authoritative-sounding
service name. That is the same failure already caught and fixed once on `customer.work_orders`.

## 4. What to do

- **Nothing to the key.** `visits.service_type` and `service_configs.service_type` stay GT/CL/WD/LS.
- **The label fix is already shipped.** `service_kind` is canonical, `ops.v_calendar_visit.service_label`
  exposes it, the apps display it, and `fn_generate_sa_visits` now *derives* `service_type` from
  `service_kind` instead of defaulting to GT.
- If the legacy vocabulary is ever retired it is a migration of 13 literal call sites **plus** an
  explicit decision on the 7 GT+LS clients — not a rename.

## 🛑 Live defect found while auditing (unrelated to the rename)

**LS visits have no lateness anchor.** Both CHECK constraints allow `ARRAY['GT','CL','WD','LS']`, but
all three cadence filters in `ops.v_calendar_visit` list only `ARRAY['GT','CL','WD']` — the view
contains no `'LS'` anywhere. **15 live LS visits** and 7 `service_configs` LS rows have silently had
no median gap, no observed price and no expected-next-visit. The array literals have already drifted
out of sync with the CHECK constraint once.

⚠ Also: `docs/schema.md` documents `service_configs.service_type` as
`GT, CL, WD, AUX, SUMP, GREY_WATER, WARRANTY`. The measured domain is only **GT, CL, WD, LS** —
AUX/SUMP/GREY_WATER/WARRANTY have **zero rows**, and **LS is undocumented**. Anyone scoping this work
from schema.md would plan for four values that do not exist and miss the only one that collides.
