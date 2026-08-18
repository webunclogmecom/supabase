# 2026-08-18 · Photo attribution audit: are photos on the correct client and visit?

*Fred, 2026-08-18: "do an audit to see if the photos are going to the correct client and visit".
Five investigators plus two adversarial passes. Every number here is MEASURED on Prod with a control
that fires; where a pass was refuted by the verifier, the verifier's number is the one recorded.*

---

## The answer in two lines

**CLIENT attribution is 100% correct and always has been. VISIT attribution is not.**

**6 photos are visible to a client right now on the wrong visit.** 22 more are classified but
suppressed. Nothing has ever been emailed to a municipality that contained a visit photo.

---

## 1. Cross-client: ZERO, and the zero is instrumented

| boundary | photos spanning more than one | classified | published to a client |
|---|---|---|---|
| **client** | **0** | 0 | **0** |
| job | 102 | 0 | 0 |
| property | 4 | 0 | 0 |
| visit (control) | 322 | 29 | **6** |

Zero holds **including soft-deleted links**, i.e. no photo has *ever* touched two clients.

🛑 **The zero was proven by INJECTION, not by absence.** Inside `begin; ... rollback;` the verifier
inserted a deliberate cross-client link (photo 2992, client 276, onto visit 1240, client 380) and
classified it `after`:

```
customer.wo_photos      405 -> 406 -> 405
topology detector         0 ->   1 ->   0
path-provenance detector  0 ->   1 ->   0
```

Rollback confirmed from a **fresh connection**: 18,960 links, 0 `role='PROBE_ROLLBACK'` rows, 0
`audit.logs` entries. That is what makes this an all-clear rather than an untested instrument.

⚠ **Two of the five "independent" instruments were ~97% tautological.** `storage_path` is *built from*
the same `visit_id` written to `photo_links.entity_id` (`storagePathFor()`,
`scripts/migrate/jobber_notes_photos.js:494`), so 7,147 of 7,378 rows are the writer agreeing with
itself. Only **245** links carry information the writer did not put there. The conclusion survives on
topology, those 245, and Jobber GID uniqueness.

⚠ **A dead instrument was correctly caught rather than reported.** "Does a photo's note belong to a
different job" is unanswerable: **`notes.job_id` is NULL on all 1,226 rows.** The first run returned
0 with a control that did **not** fire, and was discarded instead of published as an all-clear.

## 2. 🛑 The client boundary is an EMPIRICAL zero, not an enforced one

`public.photo_links` RLS: **`Authenticated insert photo_links`, `WITH CHECK (auth.uid() IS NOT NULL)`.**
No client predicate. No entity predicate. **And `photo_links.entity_id` has no foreign key.**

Any authenticated JWT can insert any `(photo_id,'visit',entity_id)` pair. That is exactly the shape
the injection probe used to publish a foreign photo. Live evidence it is reachable: `audit.logs` has
6 INSERTs from `app_source='admin-review'`, origin `https://admin.unclogme.app`. All 6 are currently
correct, which is an empirical zero over n=6.

Proof the lack of a FK already bites: **14 alive links point at visit 1795, which does not exist.**

⇒ The all-clear rests on the apps never sending a wrong visit id, with **no database check behind it**.
A `client_id` predicate on the insert policy would turn the measured zero into an impossibility.

## 3. Visit attribution: 405 surplus links, 6 of them live

322 photos carry 405 surplus links. Of those, **29 are classified**, 28 with a publishing phase.

**The 6 live rows, fully resolved:** photos **21341-21346** (`TC_00064/65/67/68/69/70.jpeg`) published
under work order `rz1Rr3OoXT` on visit **7103 (152-DAV), dated 2026-07-14** — and every one is also
linked to visit **7083, dated 2026-07-13**. **7103 has no photos of its own. 100% of its gallery is
7083's work.** (`TC_00066` is a 7th, classified `internal`, correctly filtered out.)

🛑 **This is not a leak between clients.** 152-DAV is seeing **its own photos under the wrong date**.
The real harm is narrower and still real: 7103 is DERM-required with a manifest attached, so a
compliance record for 07-14 is illustrated with the 07-13 service event.

**24% cannot be confidently reassigned** (98 of 405), so a remediation would be guessing on a quarter
of them. Breakdown: 15 have a candidate visit with NULL `completed_at`, 47 have a fabricated note date
whose winner flips inside the measured error envelope, 36 have a top-two margin under 60 seconds.
Zero exact ties.

## 4. The other 22 are held back by something weaker than it looks

They sit on visits with `derm_required = false`, which keeps them out of `customer.work_orders`.

🛑 **But `fn_visit_requires_derm` returns TRUE for those same visits** (6989, 6955, 7083). Fleet-wide,
**56 visits have `derm_required = false` while the function says true.** Per the standing rule the
function is authoritative, so **anything that "reconciles the column to the function" publishes 22
wrong photos.**

An automated flip is impossible (`rederive_visits_derm_required` only touches NULLs and skips locked
rows). **The bypass is human and one click:** the same trigger passes the new value straight through
when the write carries `x-app-source: derm-tracker`. A person toggling 6989 in DERM Tracker publishes
all 22 immediately.

## 5. 🛑 "Nothing has ever gone to a city" was FALSE as first written

Two passes stated it and both were wrong. `public.visit_photo_email_sends` is indeed 24 rows, all
`is_test = true`, 0 production. **But `public.derm_email_sends` holds 88 rows with real external
recipients, 2026-06-05 to 2026-08-14, including `hallandalebeachfl.gov` and `townofsurfsidefl.gov`.**
50 manifests carry `sent_to_city = true`.

**The conclusion survives, for a reason neither pass gave:** `send-derm-email` attaches only manifest
and address-sheet documents. **It carries no visit photos.** And 0 manifests linked to any visit
holding a surplus link have been sent to a city (control: 51 manifests have been, so the query can
detect it).

⇒ The photo channel is structurally blocked, not merely dormant. Say it that way; "no email has gone
out" is not true of this business.

## 6. The mechanism is NOT what the 6835 investigation concluded

⚠ **Correction.** That investigation named `sync_jobber_note_photos.js` (`NOTE_WINDOW_DAYS = 2`) as
the engine. It is a contributor, not the main one. Measured:

| writer | what it does | scale |
|---|---|---|
| **`classifyNote()`** in `scripts/migrate/jobber_notes_photos.js:326` | picks the visit by **nearest `visit_date`** within a window, `LIMIT 1`. A **date guess**. | 5,090 photos, **4,538 of 7,393** publish-eligible links |
| `recover_visit_note_photos_window2d.js` | "for each completed visit with NO photos, look at notes within +/-2 days" | the 6835 cluster |
| `sync_jobber_note_photos.js` | job-scoped note fan-out, +/-2 days | the live cron; 0 cross-job in 2,153 photos |
| ClientNote path | `Visit.notes` union includes `... on ClientNote`, which is **client-scoped, not job-scoped** | 663 photos, 100 linked to visits, 0 published |

**Client is pinned in every one of them** by an outer per-client loop or a client-joined query, which
is why cross-client is structurally zero. The visit is a guess in the largest one.

## 7. Data integrity defects found in passing

| defect | measured | control |
|---|---|---|
| `entity_source_links` note rows pointing at a nonexistent note | **1,230 of 2,454 (50.1%)** | 0 of 1,605 visit rows dangle |
| `photo_links(entity_type='note')` pointing at a nonexistent note | **540 of 4,495 (12.0%)** | 3,955 resolve |
| `photo_links(entity_type='visit')` pointing at nonexistent visit 1795 | **14** | all other visit links resolve |
| `notes.job_id` | **NULL on 1,226 of 1,226** | n/a |

## 8. What I would do, in order

1. **7103 (152-DAV) is the only live case.** Unlink its 6 published links; it then correctly shows an
   empty gallery rather than another day's work.
2. **Add a client predicate to the `photo_links` insert policy**, and a foreign key on `entity_id`.
   That converts the audit's central finding from "measured zero" to "cannot happen".
3. **Do not reconcile `derm_required` to the function** without first clearing the 22.
4. **Leave the 98 undecidable links alone.** A wrong unlink deletes a client's real photo.
5. ⚠ **Do not apply nearest-note-wins broadly.** 214 of the links it would remove sit inside the
   +/-2 day window Fred already ruled on (2026-08-14: *"yes keep the ones inside the 2 day window"*).

## 9. Correction to a number I broadcast

`WORKING-NOW.md` earlier carried **"77 visits hold 614 shared links"**, taken from the 6835
investigation. This audit measures **322 photos / 405 surplus links / 34 visits** on the strict rule.
The 614 figure counted every link of a shared photo rather than the surplus, and is superseded.

---

## 10. CORRECTION 2026-08-18, found while applying the 7103 fix

**I said "the client sees the same 6 photos twice, on 07-13 and again on 07-14". That was WRONG**, and
it is the exact trap section 1 of this document warns about: I counted `customer.wo_photos` without
joining `customer.work_orders`.

```
7083  vqQ4UExiN4  2026-07-13  derm column FALSE / function TRUE  work_orders 0  wo_photos 6
7103  rz1Rr3OoXT  2026-07-14  derm column TRUE  / function TRUE  work_orders 1  wo_photos 6 -> 0
```

`wo_photos` holds rows for BOTH visits, but **7083 has no `work_orders` row**, so the Field Portal
answers **"Work order not found"** for it. The 6 photos were therefore visible on **7103 only**, i.e.
exclusively on the wrong visit. Seeing them twice was never possible.

⇒ **The fix is still correct and its effect is unchanged**: the client has stopped seeing another
day's work on the 07-14 compliance page.

🛑 **But it exposes the real problem for this client, which is NOT the photo link.** Visit 7083 is one
of the **56 visits where `derm_required = false` while `fn_visit_requires_derm` returns TRUE**. Its
own six photos are now visible nowhere, because the visit they belong to publishes no report at all,
on the strength of a stale boolean.

**Do not simply flip it.** The same flip on the other affected visits publishes 22 wrong photos (see
section 4), and `derm_required` carries a locking trigger. The right sequence is: clear the wrong-visit
links first, then reconcile the column to the function, and only then will 7083 publish its own work.

⚠ **The general lesson, restated because I proved it the hard way within minutes of writing it:**
`customer.wo_photos` alone is NOT the published surface. It overstates by 45 rows. The published
surface is `wo_photos` INNER JOIN `work_orders`, and `work_orders` gates on
`visit_status='completed' AND client_id IS NOT NULL AND COALESCE(derm_required,true)=true`.
