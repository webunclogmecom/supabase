# Service Agreement Status Report

**Artifact:** `Clients_SA_Status_<YYYY-MM-DD>.pdf` (delivered to the user's `~/Downloads`)
**Generator:** [`scripts/reports/sa_status_report.py`](../../scripts/reports/sa_status_report.py)
**Owner intent:** operational snapshot for Fred / ops / Yan. First produced 2026-06-24.

---

## 1. Purpose / Vision

A periodic, **action-oriented** snapshot of **Service Agreement (SA) coverage gaps** and **leftover open jobs**. It is not an analytics dashboard — every row is something a human should *do something about*. It exists because the SA model (recurring visits auto-generated from Jobber SA jobs — see [service-agreement-visit-generation.md](../service-agreement-visit-generation.md)) only works if:

1. each recurring client **has** an SA job, and
2. that SA job is **fully set up** (a numeric `Frequency` custom field > 0 **and** line items).

When either is missing, that client silently gets **no auto-generated visits** and nobody is alerted — this report is the alert. It also surfaces **old pre-restructure `[OLD]` jobs** that linger un-archived in Jobber after the SA/Service-Call restructure (see [jobber-jobs-service-call-restructure-PLAN.md](../jobber-jobs-service-call-restructure-PLAN.md)), so ops can close them once their pending visits complete.

**The three questions it answers**

| # | Question | Action it drives |
|---|----------|------------------|
| 1 | Which SA agreements exist but **can't generate visits** (Frequency 0/blank or no line items)? | Finish the SA setup in Jobber (set Frequency + add line items). |
| 2 | Which active/recurring clients have **no SA at all**? | Decide whether to create an SA so the cron schedules their recurring visits. |
| 3 | Which old **`[OLD]` jobs are still open**? | Archive in Jobber once pending visits complete. |

Question 2 is deliberately split by service history because **"no recent visit" ≠ "abandoned"** — many active accounts are on-call / emergency-only and legitimately have no recurring SA (see [`feedback_emergency_only_clients`] in agent memory). So the report separates **likely-real gaps** (serviced this year) from **likely emergency-only** (no service this year) instead of implying all are gaps.

---

## 2. How to generate

```bash
cd Supabase
python scripts/reports/sa_status_report.py                 # -> ~/Downloads/Clients_SA_Status_<today>.pdf
python scripts/reports/sa_status_report.py --date 2026-06-24
python scripts/reports/sa_status_report.py --out some/path.pdf
```

- **Requirements:** Python 3 + `reportlab` (`pip install reportlab`). HTTP query uses stdlib only.
- **Credentials:** reads `SUPABASE_PAT` + `SUPABASE_PROJECT_ID` from `Supabase/.env` (git-ignored — **no secrets in the script; this repo is public**).
- **Gotcha:** the Supabase Management API is behind Cloudflare, which 403s the default `urllib` User-Agent — the script sets a real `User-Agent` header. Keep it.
- **Overwrite caution:** the default filename is dated, so re-running on the same day **overwrites** that day's file. If the user has manually annotated a copy, write to a different `--out` rather than clobbering it.

---

## 3. Sections + exact definitions

All queries run against **Prod** (`public.jobs`, `clients`, `line_items`, `visits`). The canonical **"active SA job"** predicate (shared with the visit generator) is:

```
title ILIKE 'Service Agreement%'  AND  job_status <> 'archived'  AND  title NOT ILIKE '%[OLD]%'
```

| § | Section | Population rule |
|---|---------|-----------------|
| 1 | **Pending / incomplete SA** | An active SA job whose `frequency_days` is 0/NULL **OR** that has no `line_items`. These are excluded by the generator (`frequency_days > 0`), so they produce no visits until fixed. |
| 2 | **Missing SA — serviced this year (real gaps)** | Client `status IN ('ACTIVE','RECURRING')` with a non-null `client_code`, **no** active SA job, and a completed visit dated `>= Jan 1 of the report year`. |
| 3 | **Missing SA — no service this year (likely emergency-only)** | Same as §2 but **no** completed visit this year. Flagged, not condemned — review case-by-case. |
| 4 | **Old `[OLD]` jobs still open** | Any job with `title ILIKE '%[OLD]%'` and `job_status <> 'archived'`, with a count of its future (`visit_date >= today`) non-deleted visits. |

`SC?` in §2/§3 = the client already has a `title = 'Service Call'` (non-archived, non-`[OLD]`) job.

The exact SQL lives in the generator (`Q_PENDING` / `Q_MISSING` / `Q_OLDJOBS`) — **the script is the source of truth for the definitions; keep this table in sync if you change them.**

---

## 4. Maintenance / extension notes (for whoever owns this next)

- **Keep the SA-job predicate identical to the visit generator** (`scripts/sync/generate_service_agreement_visits.js`). If the SA model changes (e.g. a new job-title convention), update both together or §1 will misreport which clients can generate.
- **Residential / no-code clients are intentionally excluded** from §2/§3 (`client_code IS NOT NULL`) — they aren't on the SA model. Don't "fix" this.
- **Don't add a residential flag or mark emergency-only clients as gaps** — both are explicit ops rules; §3 exists precisely to avoid that mistake.
- **To add a section:** add a query constant + a `mktable(...)` block in `build()`. Keep it action-oriented (a row should imply a task).
- **Cadence:** currently on-demand (run when ops wants a fresh pull). If it becomes scheduled, a GitHub Action or pg_cron-triggered Edge Function could run it weekly and email/store the PDF — not built yet.
- **This is a reporting artifact, not a pipeline writer** — it only reads. It must never INSERT/UPDATE.

---

## 5. Related

- [service-agreement-visit-generation.md](../service-agreement-visit-generation.md) — the SA visit model the gaps feed into.
- [`scripts/sync/generate_service_agreement_visits.js`](../../scripts/sync/generate_service_agreement_visits.js) — generates the recurring visits for SA jobs that *are* set up.
- [jobber-jobs-service-call-restructure-PLAN.md](../jobber-jobs-service-call-restructure-PLAN.md) — why the `[OLD]` jobs exist.

## Change log
- **2026-06-24** — Created. First report: 7 pending, 28 likely-real missing-SA gaps, 24 likely emergency-only, 60 old `[OLD]` jobs open. Generator promoted from a one-off script to `scripts/reports/sa_status_report.py` (self-contained: query → PDF) + this doc, so it is reproducible and maintainable.
