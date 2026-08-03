# Plan — retire the GT/CL/WD/LS vocabulary, keep the column name `service_type`

**Status: PLAN ONLY. Nothing in here has been executed.** Fred asked for a full audit and a plan
before any change. Four parallel audits ran on 2026-08-03 against live Prod; every number below is
measured, not estimated.

**Fred's decisions already taken (2026-08-03):**
1. Full catalogue vocabulary on `visits`; the recurring subset on `service_configs`. **Approved.**
2. **No shadow/legacy column.** Approved, and verified safe (see §7).
3. **expand → migrate → contract.** Approved.

---

## 1. The naming answer: keep `service_type`, drop `service_kind`

Fred asked: *"is this to remove `service_kind` and make it `service_type` correct?"* **Yes.** Three
measured reasons, and one of them is a hard blocker against doing it the other way.

**(a) They coexist on exactly ONE table.** `service_kind` exists on a single base table,
`public.service_line_items` (28 rows). `service_type` is on that same catalogue **plus**
`public.visits` (2,408 rows) and `public.service_configs` (270 rows). So this is not two parallel
columns being merged. It is one redundant pair on a 28-row catalogue, and a **value rewrite** on
2,678 transactional rows where no `service_kind` exists to merge with.

**(b) Lower churn.** `service_type` is referenced by 29 objects, `service_kind` by 7. Keeping the
name Fred prefers is also the smaller edit.

**(c) 🛑 BLOCKER against reusing the name `service_kind`.** The name is **already taken in the
app-facing views with a completely different vocabulary**. `ops.v_calendar_visit.service_kind` emits
`SA` (1,407 rows) and `SC` (335 rows) — it is the Service Agreement vs Service Call classifier, and
**the Visit Calendar equality-filters on it**. Renaming `visits.service_type` to `service_kind` would
put two meanings on one column name in the same view; the Calendar's cadence and lateness query would
filter the wrong vocabulary and silently return zero prior-visit rows.

**⇒ End state: the column stays `service_type` everywhere. Only its VALUES change.**
`service_line_items.service_kind` is dropped after its readers are re-based.

---

## 2. 🛑 The blocker neither the brief nor the first audit caught

**`ops.fn_service_group` makes `PUMPING_GT` unreachable if `service_line_items.service_type` is
dropped — and 1,006 Calendar chips repaint silently.**

The function signature is `fn_service_group(p_reason, p_kind, p_type)`. Because its parameter is named
`p_type` and not `service_type`, **a name-based catalogue sweep reports "no reference."** Only a
value-based sweep (`pg_get_functiondef ~ '''(GT|CL|WD|LS)'''`) finds it. Its body splits Pumping into
`PUMPING_GT` vs `PUMPING_OTHER` using `p_type = 'GT'`. Drop the column and every Pumping row collapses
to one group.

**Fix, and it must be in the same migration:** re-base the discriminator on
`location_target LIKE 'Grease Trap%'`. That is provably equivalent — `service_type='GT'` and
`location_target LIKE 'Grease Trap%'` agree on every catalogue row with no counterexample.

**Lesson to keep:** a name-based sweep cannot see a value hard-coded behind a differently-named
parameter. Both sweeps are needed. This is the same class as the `["']`-only extractor in §5c of the
root CLAUDE.md, and it is why the plan adds a value-based sweep to `scripts/checks/`.

---

## 3. What actually breaks — the measured inventory

| Category | Count | Note |
|---|---|---|
| Objects **comparing** `service_type` to a legacy literal | **12** objects / 34 lines | All must be rewritten. Includes `fn_service_group` (the 12th, missed by a name sweep). |
| Objects **passing through** `service_type` | 27 | Change only if the value domain changes. |
| CHECK constraints | 2 | `service_configs_service_type_chk`, `visits_service_type_chk` |
| UNIQUE / PK objects at risk | **exactly 1** | `service_configs_client_id_service_type_key` |
| Matviews needing REFRESH | **0** | Asserted, so nobody re-hunts. |
| Policies / rules / cron / non-plpgsql / generated columns | **0** | Negative result with a passing positive control. |
| Other stores holding the vocabulary (jsonb, free text) | **0** | Swept `sync_log`, `webhook_events_log`, `dump_activity`, `saved_views` with controls. |

**Live writers of the legacy vocabulary right now** — the column is not dormant:
`supabase_cron` 863 rows (`fn_generate_sa_visits`), `jobber` 782 (the webhook), `visit-calendar` 97.
Newest CL row was created **today**.

### The four that fail SILENTLY (wrong data, no error)

1. **`public.client_services_flat`** pivots on the literals in 16 places. A value rename with no view
   change turns every CASE into a non-match: all `gt_*`, `cl_*`, `wd_*` columns go blank. Not an error.
2. **`public.fn_check_gdo_on_visit`** opens `IF NEW.service_type != 'GT' THEN RETURN NEW`. After the
   rename that is true for every row, so **the GDO compliance alert never fires again**. A compliance
   detector that fails silent is the worst shape of failure. ⚠ It also currently treats **NULL as GT**
   (`NULL != 'GT'` is NULL, so it does not return early) — preserve that deliberately.
3. **`ops.v_gdo_expiry`** starts lying rather than erroring.
4. **`public.fn_generate_sa_visits`** — the one I shipped on 2026-08-01. It contains **both halves of
   the trap**: lines 75-80 down-convert the catalogue kind into the legacy code, and line 114 joins the
   SA cadence anchor on the legacy value. Both must be replaced in the same transaction.

### Verified SAFE (recorded so the plan does not spend effort here)

- **A `service_type`-only UPDATE does NOT push to Jobber and does NOT enqueue `sync_state`.** Read from
  `pg_get_triggerdef`, not inferred: `trg_push_visit_update` and `trg_mark_visit_sync_pending` both
  carry WHEN clauses that omit `service_type`. **Do not add it.**
- No deployed app **sends or filters** on `service_type` — every app use is display-only. The six
  Lovable bundles do **not** need a lockstep republish. This is what makes the whole change tractable.

### ✅ The two Calendar RPCs SELF-MIGRATE — they derive from the catalogue, they do not hard-code

Two audits appeared to disagree here (one said no app sends `service_type`; the other said
`create_calendar_visit` / `edit_calendar_visit` "accept whatever the caller passes"). **Settled by
reading the signature: there is no `service_type` parameter. The app cannot pass it.** Both RPCs
*derive* it:

```
SELECT service_type INTO v_service_type FROM service_line_items WHERE id = p_service_line_item_ids[1]
```

**Consequence, and it removes two writers from Phase A:** the moment
`service_line_items.service_type` holds the new vocabulary, both RPCs start writing the new vocabulary
with **zero code change**. They are pass-throughs from the catalogue, not hard-coded emitters.

**Side benefit the migration delivers for free.** Because the catalogue's `service_type` is NULL on 11
of 20 codes today, the Calendar has been writing NULL: of its 97 alive visits, **52 are NULL** (28 GT,
17 CL), newest today. Populating the catalogue means those visits start carrying a real value instead
of NULL — so they gain a cadence anchor and a config join they have never had. **This is a fix, not
just a rename**, and it is the same defect class as the LS anchor gap in §4/D2.

---

## 4. Three decisions that need Fred before the migration is written

### D1 — CL is a catch-all, and renaming it to "Cleaning" promotes a 62%-wrong label

Measured twice with the same instrument, exact agreement: 258 alive CL visits, 151 derivable from line
items. Of those 151, only **53 derive to exactly Cleaning**; **94 (62.3%) contain no Cleaning at all**
(Unclogging 40, Labor 39, Dump Offload 8, Pumping 4, Warranty 2, Assessment 1).

For contrast, GT is the opposite story and needs no cleanup: **1,102 of 1,116 derivable = 98.7% Pumping.**
The 14 exceptions are 10 visits on one internal account (`000-DH`, already on the generator's exclusion
list) plus 4 strays.

**My recommendation: rename CL→Cleaning 1:1 in this migration, and fix CL accuracy as a separate
change.** Reasoning: deriving per-visit would **fragment the cadence partition** (visits scatter into
Unclogging/Labor series) and **orphan the `service_configs` join** (there is no Unclogging config). That
is a behavioural change dressed as a rename, and it would blow up the zero-diff proof in §6 — leaving
no way to tell a migration bug from an intended data fix. The imprecision exists today under the name
"CL" and will exist tomorrow under the name "Cleaning"; it is not made worse by the rename, only more
visible. Two changes, two proofs.

### D2 — LS: which value, and a hard DELETE that needs explicit sign-off

**The 15 LS visits.** Job titles say **cleaning** — 13 of 15 are literally titled *"Lyft station
cleaning"*, one *"Hydrojet Cleaning Lyft station"*. Hydrojetting a lift station is Cleaning work. So
LS→**Pumping** inherits a label the evidence contradicts. Recommend **LS→Cleaning**, recorded with the
reason.

**Either way, folding LS is a DATA MERGE, not a rename.** `ops.v_calendar_visit`'s three cadence CTEs
filter to `ARRAY['GT','CL','WD']` — LS is excluded today, so those 15 visits contribute nothing. Once
they carry a filtered value they enter the medians for the first time. Read-only simulation of the
Pumping fold measured: **057-BAY 2→3 days, 083-SHUL 57→42 days, 168-AVA 12→9.** No error is raised.
These deltas must be an **approved allowlist declared before the run**, or the proof cannot tell them
from a bug.

Related: after the fold those 15 visits also start joining the client's real Pumping `service_config`
and would **inherit a frequency and price they do not have**.

**🛑 The 7 LS `service_configs` rows require a HARD DELETE.** Confirmed empty (0 of 7 have a frequency,
price, size, stop date, notes or material type), one batch, 2026-05-14. All 7 belong to clients that
**also** hold a GT config, so **7 of 7 collide** on `UNIQUE (client_id, service_type)` — a single-statement
UPDATE aborts with `23505` on the first row. They must be retired **before** the value UPDATE.
`service_configs` has **no `status` and no `deleted_at` column**, so there is no soft-delete available.
**This is a hard delete of business data and needs Fred's explicit OK under rule #6.**

### D3 — the 70 NULL visits: derive only, never default

70 alive rows are NULL; 59 are derivable from line items. **Only 1 of the 59 derives to Pumping.** A
backfill that defaults NULL to Pumping would be wrong 58 times out of 59 and would drag those visits
into a cadence series and a config join they do not belong in. Recommendation: **derive the 59, leave
the 11 underivable ones NULL** — they are completed historical visits that will never acquire line
items, and NULL is the honest value. Or skip the NULL backfill entirely this cycle.

---

## 5. The phased plan (expand → migrate → contract)

Each step is its own transaction, so a failure at step 4 does not roll back steps 1-3.

**PHASE A — EXPAND (nothing changes meaning yet)**
1. Widen both CHECK constraints to accept **both** vocabularies.
2. Add the **11th kind**: code 28 `Dump Offload` is in production (30 live visits) and is **not** in the
   ten-name list. Writing the new CHECK from the ten names would reject it and break live visits.
3. Deploy `webhook-jobber` accepting/emitting the new vocabulary. It is the **only live edge writer**
   and a single choke point — but note it also **filters** on `service_type` at L794-800 to match the
   cron-generated placeholder visit for promotion. If the placeholder and the derive disagree, that
   dedupe fails **silently into duplicate visits**. This is why the window is mandatory, not optional.
4. Widen the script-side Sets **and push to main first** — `derive_visit_vehicle_id.js` runs **hourly**
   and the workflow checks out main at job start, so the deploy window is up to one hour.
   Also: `reconcile_jobber_visits.js` holds a **verbatim copy** of the webhook derive logic, and
   `cron_generate_recurring_visits.js` is dormant but manually dispatchable and writes legacy codes.

**PHASE B — MIGRATE (one transaction, in this exact order)**
5. Retire the 7 LS `service_configs` rows (**pending D2 sign-off**).
6. `UPDATE` values on `visits` and `service_configs`, **chunked ~250 rows** to bound the audit write and
   WAL burst.
7. In the *same* transaction, replace all 12 literal-comparing objects — including
   `fn_check_gdo_on_visit`, `fn_generate_sa_visits` (both the emit CASE and the line-114 join),
   `client_services_flat`, `v_gdo_expiry`, `v_calendar_visit`, and `fn_service_group` re-based on
   `location_target`.

**PHASE C — CONTRACT**
8. Narrow both CHECK constraints to the new vocabulary only.
9. Drop `service_line_items.service_type`; drop `service_kind` after its 7 readers are re-based.
10. Update `scripts/ops_views/*.sql` — these are **checked-in source-of-truth view DDL that will REVERT
    the migration if re-applied**. Same commit, or the migration is only half-shipped.
11. Add the **value-based** sweep to `scripts/checks/` with an inline positive control.

---

## 6. Proof design — the failure mode here is blank output, not an exception

Confirmed by probe on 2026-08-03: **the Management API honours an explicit `BEGIN ... ROLLBACK` in one
body**, so the entire rehearsal runs as snapshot → migrate → re-snapshot → compare → ROLLBACK in a
single `REPEATABLE READ` transaction. That also freezes out the 16 active crons and kills clock drift
(`client_services_flat` uses `CURRENT_DATE`). Largest surface is 1,742 rows / 216 ms; the whole
snapshot is ~5,700 rows.

Snapshot with `to_jsonb(t)`, **not** an enumerated column list — enumerating columns is how you
silently omit the column that broke.

**GO requires ALL of:**
- Keyset diffs = **0**; rowset diffs = **0**; chip-colour diffs = **0**
- Value diffs not on the frozen allowlist = **0**
- **A negative control that must be NON-zero** — "zero diffs everywhere" is also what a migration that
  did nothing produces. Without this the proof cannot distinguish success from a no-op.
- `client_services_flat` returns **>0 rows with a non-null `gt_frequency_days`** (assert non-empty, not
  just no-error — this view fails by going blank)
- Post-deploy re-check of `webhook-jobber` at **T+15 and T+60** as a hard gate

---

## 7. Rollback — why no shadow column is safe here

Restoring state needs the `visits` values, the `service_configs` values (including the 7 retired rows),
the constraints, and the object definitions. GT/CL/WD map 1:1 and invert trivially.

**The only irreversible piece is LS**, because GT and LS both collapse into one value. Measured: only
**1 of 15** LS visits is identifiable from line items — but **13 of 15 carry it in their job title**
(*"Lyft station cleaning"*). Combined with all 15 being completed, zero scheduled, and zero future
impact, the information survives in readable form. **A shadow column is not warranted.** (Fred's call,
independently verified rather than assumed.)

---

## 8. Recorded, not fixed by this migration

- **`audit.logs` permanently mixes both vocabularies at the same jsonb key** — 16,467 `visits` rows plus
  363 `service_configs` rows, 2026-05-18 onward. Not rewritable (rewriting an audit trail needs Fred's
  OK and is the wrong instinct anyway). **Rule to carry: any historical query over `service_type` must
  accept both vocabularies.** Document the cut timestamp in the migration header.
- **The bulk UPDATE rewrites `updated_at` on 2,408 rows** and writes ~5 MB of audit rows. Note it in the
  header so nobody later reads 2026-08-XX as real activity.
- **Pre-existing defect:** `v_calendar_visit`'s three cadence CTEs have **no `deleted_at IS NULL`
  filter**, so 530 soft-deleted rows already sit inside every median and price. Migrate all 2,408 rows
  uniformly so this does not surface as an apparent cadence regression, and fix it separately.
- **`docs/schema.md` is wrong today**: it documents four `service_type` values with zero rows
  (`AUX`, `SUMP`, `GREY_WATER`, `WARRANTY`) and omits `LS`, the only one that collides. Anyone scoping
  from it plans for values that do not exist and misses the real blocker.
- `webhook-airtable`'s legacy writer is unreachable dead code (dispatch severed). Delete rather than
  port — it targets a retired system.
