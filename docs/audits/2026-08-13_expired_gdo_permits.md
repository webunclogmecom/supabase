# 2026-08-13 — the 22 ACTIVE-but-expired GDO permits, checked against the city

Fred: *"now check the 22 expired GDO permits."*

**Result: all 22 are genuinely expired at Miami-Dade DERM. This is not a data problem.** Our stored
`permit_expiration` matches the city's own document in every readable case, and we are still filing
DERM manifests against 18 of them.

---

## The check that mattered, and the control that makes it mean something

The hypothesis worth testing first was that our records are **stale** rather than the permits being
lapsed. A GDO number is stable across renewals (Fred, 2026-08-12), so a renewal would appear as a
newer document under the *same* case number, and we might simply have missed it.

Queried DERM (`api-ecmrer.miamidade.gov/derm/documents`, `documentType: OPERATING PERMIT`,
`sortOrder: date_desc`, 25 docs per case) for all 22.

```
verdicts:  CHECKED 18   PDF_UNREADABLE 4
cases where DERM holds a NEWER permit than we recorded:  0
```

**🛑 The hypothesis is refuted. There is no missed renewal.** In all 18 readable cases the city's
newest operating permit carries exactly the expiration we already store.

**CONTROL, which is what makes that a finding rather than a broken query.** Across today's full
audit of 130 readable ACTIVE permits:

```
permits whose PDF expiry is in the FUTURE ....... 113   <- DERM's system is current and issues renewals
permits whose PDF expiry has PASSED .............  17
records where OUR expiry disagrees with the PDF ..  0   <- our data is accurate
expiry-year distribution: 2018:1  2020:1  2022:2  2023:1  2024:5  2025:7  2026:113
```

So the city is actively issuing 2026 permits (113 of them, to our clients), our reader works, and
our stored dates are right. The 22 are lapsed because they are lapsed.

## The 22, by how long they have been expired

`v180` = completed visits in the last 180 days. `M-after` = DERM manifests we filed **after** the
permit expired.

### Lapsed 5+ years — 7 permits, all actively serviced

| GDO | expired | yrs | client | freq | v180 | M-after | last manifest |
|---|---|---|---|---|---|---|---|
| GDO-05104 | 2007-01-14 | 19.6 | 114-CI Ceviche Inka | — | 5 | 4 | 2026-07-04 |
| GDO-01861 | 2009-12-31 | 16.6 | 193-FRK Fresko Bakery | — | 3 | 3 | 2026-06-12 |
| GDO-01179 | 2011-12-31 | 14.6 | 058-SOH Soho Asian Bar | — | 5 | 4 | 2026-08-10 |
| GDO-11308 | 2018-12-31 | 7.6 | 201-ALA Aladdin Mediterranean | — | 1 | 1 | 2026-07-05 |
| PSO-00025 | 2019-09-30 | 6.9 | 057-BAY Bayshore Executive Plaza | — | 12 | 7 | 2026-07-27 |
| GDO-12484 | 2019-12-31 | 6.6 | 036-LG La Granja South Miami | 90 | 7 | 7 | 2026-07-22 |
| GDO-08935 | 2020-12-31 | 5.6 | 001-VIN Vincenzos Pizzeria | 30 | 7 | 4 | 2026-07-09 |

### Lapsed 2–4 years — 3 permits

| GDO | expired | client | freq | v180 | M-after |
|---|---|---|---|---|---|
| GDO-08940 | 2022-12-31 | 091-SB Street Bar | 30 | 4 | 6 |
| GDO-09852 | 2022-12-31 | 002-41 41 Pizza and Bakery (**PAUSED**) | 30 | 0 | 0 |
| GDO-00951 | 2023-12-31 | 132-PUM Pummarola | 30 | 4 | 6 |

### One renewal cycle behind (expired 2024-12-31) — 5 permits

| GDO | client | freq | v180 | M-after |
|---|---|---|---|---|
| GDO-14294 | 047-PAM Pamplemousse On the Bay | 90 | 5 | 4 |
| GDO-13822 | 066-TCE The Carrot Express | 30 | 1 | 0 |
| GDO-11576 | 179-CIG Espanola Cigars | 60 | 3 | 3 |
| GDO-04840 | 004-BAO Baoli Miami | 90 | 3 | 4 |
| GDO-14031 | 105-CU Cook Unity | 60 | 0 | 1 |

### Current cycle missed (expired 2025-12-31, ~8 months) — 7 permits

| GDO | client | freq | v180 | M-after |
|---|---|---|---|---|
| GDO-14760 | 242-WYN Wynd 28 | 60 | 2 | 2 |
| GDO-06762 | 094-MOZ Mozart Cafe | 30 | 0 | 0 |
| GDO-07278 | 147-OST Maison Ostrow | 90 | 6 | 2 |
| GDO-15268 | 222-SPE Le Specialita | 90 | 2 | 1 |
| GDO-14528 | 183-KRE Kresy Kosher (**PAUSED**) | 90 | 2 | 3 |
| GDO-09027 | 140-TYO Tacos Yoyo | 30 | 2 | 2 |
| GDO-05216 | 261-LC Lunita Cafeteria | 90 | 1 | 0 |

## What we have actually been doing against them

```
DERM manifests filed AFTER the permit expired ..... 64   across 18 of the 22 clients
most recent ....................................... 2026-08-10 (058-SOH, permit lapsed 2011)
CONTROL: manifests on file 619 total, 505 in the last 180 days
```

18 of the 22 clients hold visits scheduled into 2027. Two are PAUSED (002-41, 183-KRE); four have
had no completed visit in 180 days.

## ✅ The automated city reporting has NOT touched them, but that is近 worthless as reassurance

```
derm_portal_submissions against an expired permit:  0
CONTROL: 530 submissions exist, of which only 6 are LIVE (not dry_run)
```

⚠ **Do not read that as a safeguard.** The GDO RPA bot runs in `SHADOW_MODE`, so only 6 live
submissions exist system-wide; zero hits on 22 permits is what you would expect by chance. The
forward-looking question is whether the queue *would* exclude them, and it would not:

```
fn_resolve_rpa_permit references permit_expiration ....... false
v_gdo_permits_short_filed is expiry-aware ................ no
v_rpa_derm_health / gdo_report_status / visit_gdo_report .. no
```

**⇒ Nothing in the RPA path gates on permit expiry. When the bot leaves shadow mode it will report
to the city against lapsed permits unless an expiry gate is added.** That is a concrete, cheap fix
and it is the one thing here I would act on without a business decision. Not done: it changes the
queue that session 1 and Jonathan's bot both consume, so it needs sequencing.

## 🛑 Two checks I ran that DO NOT support any conclusion — recorded so nobody repeats them

1. **"Is there a newer permit under a different case number at this address?"** DERM's `houseNumber`
   search is **not address-scoped** — it matches that house number across all of Miami-Dade. Querying
   house `20` returned South Miami Hospital, Aventura Hospital and 38 others on unrelated streets.
   The instrument cannot answer the question. **Discarded.**
2. **"The permit names a different business, so it belongs to a prior tenant."** Tempting, and the
   examples look convincing (`GDO-00951` reads *MACALUSOS RESTAURANT*, not Pummarola). **The control
   refutes it:** current, valid permits mismatch our client name **58%** of the time versus 77% for
   the expired ones. Name mismatch is *normal*, which is exactly what the GDO rule predicts — a
   permit is issued to a **location**, not the business operating there, so it keeps the name of
   whoever registered it. `GDO-14760` reads *NINO GORDO RESTAURANT*, which is a real 242-WYN unit.
   **Discarded.**

The finding rests only on the city's own expiration date, which is unambiguous and which our records
match exactly.

## Limits of this audit, stated plainly

- **It does not establish what any of this legally requires.** Whether a lapsed GDO prohibits
  service, whether the obligation to renew sits with the facility or the hauler, and what exposure
  attaches to a manifest filed against a lapsed permit are questions for Fred and Yan, not
  deductions from the schema. I have measured the facts, not the rules.
- **4 permits could not be read** (GDO-05104, GDO-01861, GDO-01179, GDO-12484). Their newest DERM
  documents date to 2006, 2008, 2011 and 2019, consistent with genuine lapse, but the expiry printed
  on those PDFs was never parsed, so those four rest on our stored value rather than a re-read.
- **2 permits have no PDF stored on our side** (`permit_document_path IS NULL`): GDO-14760 (242-WYN)
  and GDO-15268 (222-SPE).
- **Nothing was changed.** No status flipped, no permit edited, no client contacted.

## Recommended next steps, in the order I would take them

1. **Add an expiry gate to the RPA queue** so the bot cannot report against a lapsed permit when it
   leaves shadow mode. Technical, low risk, no business decision needed.
2. **Ask the 7 clients in the "current cycle missed" bucket for their 2026 permit.** Expiry
   2025-12-31 with no renewal on file is most likely a normal annual renewal that simply has not
   been collected, and it is the cheapest bucket to clear.
3. **Escalate the 5+ year bucket to Yan.** Seven facilities we pump on a route, one lapsed since
   2007, with 30 manifests filed between them since expiry. This is a business/compliance call.
4. **Decide the `status` question**, which has been open since 2026-08-12. These 22 remain
   `status='ACTIVE'` deliberately: flipping them to INACTIVE would hide the gap behind a tidy table.
   If a separate "lapsed" state is wanted, that is a schema change worth doing properly.
