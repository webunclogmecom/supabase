# Session audit — 2026-08-20 → 2026-08-21

*Every line below was re-measured against live Prod and live endpoints by
`scripts/probes/audit_18h.mjs`. Nothing is taken from a commit message or from recall.*
**Result: 21/21 verified**, after two of my own assertions were found wrong and corrected.

---

## 1. What actually shipped (mine)

14 commits in `Supabase`, 4 in `Building Apps`, plus claim-file entries. The repos also carry ~36
commits from the parallel session in the same window (band-snap, GDO manual filing, city email, FP
report restyle); those are **not** mine and are not audited here.

| Area | Commits |
|---|---|
| GDO report activity trail + actor CHECK | `92b79d4` |
| SC-job plan, Tasks 4–14 | `912bb3c` `3fb912c` `04a2382` `cab99e1` `33eef99` `943ee8c` `3ba975e` `55ac4b9` |
| Jobber webhook research | `079d0ec` `84a3432` |
| Webhook SLA (ack-first) | `a047170` |
| **Webhook payload shape** | `b5b23c0` |
| **Properties soft-delete** | `a3dcea3` |
| App docs | `39086ca` `f5a439d` `6e1136c` `0521723` |

---

## 2. Verified live (21/21)

**GDO activity trail** — CHECK constraint live; buckets `bot=544 person=4 system=122` still sum to
all 670 audit rows; 0 unattributed; anon still cannot read staff emails.

**SC-job rule** — every live service property on 112-YA has exactly 1 Service Call job
(162, 1057, 1091); CONTROL: the billing twin 493 has 0.

**DB-only path closed** — `client.create_property` has exactly ONE overload (it was not accidentally
overloaded) and its body names `save-client-property`.

**Properties soft-delete** — `deleted_at timestamptz` present; exactly the 2 known orphans retired;
CONTROL: their job history survived.

**Webhooks** — real nested Jobber payload accepted; ack in **145 ms** against a 1000 ms SLA;
`x-sync-wait` still returns a real result; unsigned refused 401; **8 genuine Jobber deliveries**
now landed (payloads carry `accountId`).

**Gates** — `save-client-property` and `create-client` both refuse a non-staff token.

**No regression** — webhooks still processing (313 in 3h).

---

## 3. 🛑 Two of my own assertions were WRONG, and that is the most useful part of this audit

### 3a. A case-sensitive check manufactured 35 findings out of nothing

My first assertion flagged **51 "decorated" Service Call titles** using
`btrim(title) <> 'Service Call'` — case-SENSITIVE. The real matcher in
`_shared/service-call-job.ts` is `String(t).trim().toLowerCase() === 'service call'`, i.e.
case-INSENSITIVE.

```
titles the REAL matcher accepts   643
differ only by case               36   <- my false positives, matcher ACCEPTS these
GENUINELY decorated               15   <- real, and PRE-EXISTING
created this session               0
```

⇒ **An assertion that does not mirror the rule it tests manufactures findings.** Same family as the
`\b`-vs-`\y` regex trap and the `["']`-only bundle matcher already in the estate's notes.

**The residual 15 are real but not mine**: `"Service call - 341"`, `"service call (one) [OLD]"` and
similar, created 2026-04-29 → 2026-08-19. The matcher rejects them, so `ensureServiceCallJob` would
not recognise them and could create a second job for that property. Practical risk today is low (the
helper only runs on freshly created properties, which have no jobs), but it is a genuine edge worth
knowing. **Not fixed here** — renaming live job titles is a data change needing Fred.

### 3b. "No failures" was the wrong shape of assertion

I asserted zero real webhook failures in 18h. There is **1** — and it is the `PROPERTY_DESTROY` that
*exposed* the hard-delete bug, which has since been fixed and replayed successfully twice. The
assertion now checks that shape instead of a bare zero, so a genuinely new failure still trips it.

---

## 4. Corrections I made to my own earlier claims during the session

Recorded because each was stated confidently before being disproved:

1. **"We aren't subscribed to any DESTROY webhook."** Wrong. All 22 topics including all six DESTROY
   topics were already subscribed. The topic never fired because the payload was rejected.
2. **"3.9% of 17,984 Jobber deliveries breached the 1-second SLA."** Those were our own replay
   traffic, not Jobber's — no Jobber traffic was getting in at all. The ack-first fix is right and is
   now load-bearing, but the urgency framing was wrong.
3. **The plan's Task 5 premise** ("112-YA has zero Service Call jobs") — property 162 already had one.
4. **The plan's Task 14 signature** `(bigint, text, text, text)` — the live one is `(bigint, jsonb)`.
   Following the plan would have created a second overload and left the original reachable, applying
   green the whole way.
5. **A bundle scan reporting `create_property` absent** — the walk reached 3 chunks of 6 and its
   absences proved nothing.
6. **`resize_window` "succeeded"** — the window never resized.

---

## 5. Open, with nothing pretending to be finished

| # | Item | State |
|---|---|---|
| 1 | **30 views still unfiltered on `deleted_at`** | Enumerated and tiered; not filtered. A retired property still appears everywhere — same as before, since the hard delete never worked |
| 2 | **Orphan reconciler** | Not built. Must key on `data.property === null`, not an errors array |
| 3 | **SC-job plan Task 15** | Phase 2 docs outstanding |
| 4 | **15 legacy decorated SC titles** | Pre-existing; needs Fred's call before renaming live data |
| 5 | **Task 12 Step 6 `separate` live run** | Done; both throwaway clients archived |
| 6 | **390px mobile visual on the Calendar** | Never done — `resize_window` cannot shrink a maximized Chrome |

---

## 6. Test artifacts left on 112-YA (a test client, authorised)

| id | address | state |
|---|---|---|
| 1057 | 9401 Collins Avenue | live, SC job 1846 (#99900535 era) |
| 1090 | 9401 Collins Ave Unit 2 | **retired** — deleted in Jobber, soft-deleted here |
| 1091 | 8777 Collins Avenue | live, SC job #99901067 |
| 1092 | 9601 Collins Avenue | **retired** — the original orphan |

Two throwaway Jobber clients (`ZZ Mode Separate`, `ZZ Mode None`) were created and **archived**.
One permanent Jobber job was destroyed as part of the property-delete test; Jobber has no
`jobDelete`, so that was only possible via the property-delete cascade.
