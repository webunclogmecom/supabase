# Jobber Backups & Restore — Deep Research (2026-06-27)

**Question (Fred):** How can Jobber help me make backups? Auto-backups? And if I make a backup,
how do I install/restore it if I ever need to?

**Short answer:** Jobber backs up *its own* database daily for *its* disaster recovery — but it gives
you **no customer-facing "download a backup / restore a backup" feature**. The only data you can pull
out yourself is **per-entity CSV/vCard exports** (manual) and **everything via the GraphQL API**
(programmatic). And there is **no clean "restore into Jobber"** — imports create brand-new records with
new IDs and lose history/links. **The only real, controllable, restorable backup of your Jobber data is
the one we already run: the Supabase warehouse.** Everything below explains why and what to add.

---

## 1. What Jobber backs up (their side — NOT your backup)

From Jobber's own FAQ:

> "Your Jobber data is backed up every day. The infrastructure Jobber runs on is fully redundant, with
> safeguards in place for both storage and processing." (Hosted on AWS; SSL in transit.)

What this means in practice:

- These are **Jobber's internal backups** for *their* disaster recovery. You **cannot download them,
  schedule them, or restore from them** yourself. If Jobber has an outage they restore; if *you* delete
  a client or a year of visits by mistake, Jobber's daily backup does **not** give you a self-service
  "roll back my account to yesterday" button.
- "If your account expires, nothing gets deleted" — but there is **no documented self-service full-account
  export on cancellation**. Don't rely on Jobber to hand you your data later.

**Takeaway:** Jobber's backup protects Jobber, not you. You need your own.

---

## 2. Native exports you CAN take yourself (manual backups)

Admin users can export, per entity, mostly as CSV (emailed to the logged-in admin):

| Data | How | Limits / notes |
|---|---|---|
| **Clients** | Clients list → Export (CSV or vCard); can filter by tag | **≤ 1,500 rows per file** (splits into multiple emailed files above that); admin-only |
| **Jobs** | Jobs/Recurring-Jobs/One-Off-Jobs **Report → Export to CSV** | choose all columns or selected; emailed |
| **Invoices / Quotes / Payments / Expenses / Time sheets** | each has a **Report → Export to CSV** | one report = one CSV; no relationships across reports |

**There is no single "export my whole account" button.** You assemble a backup by exporting each report.
Properties, custom fields, line items, visits, notes, and attachments are only partially covered by these
CSVs (e.g. visit-level detail and file attachments are not in the client/job CSVs).

**Verdict:** fine as an occasional belt-and-suspenders snapshot of the headline tables (clients, jobs,
invoices). Not a complete backup, not automatable from the UI, and not restorable as-is.

---

## 3. Auto / scheduled backups (the real solution)

Jobber has **no built-in scheduled-export / auto-backup** feature in the UI. The supported path for a
complete, automatable backup is the **GraphQL API** (developer.getjobber.com):

- OAuth 2.0; cursor (Relay) pagination; **query-cost rate limiting** (each app+account has a points
  bucket — observed live for our write app: ~10,000 max, **restore rate 500/sec**). You page through
  every entity (clients, properties, jobs, visits, line items, invoices, quotes, payments, expenses,
  users) and write the results to files.
- This is exactly the mechanism **we already run**: `sync-jobber-poll` / `sync-jobber-upcoming-visits`
  + the GitHub `cron_jobber.js` poll pull Jobber deltas through the API into **Supabase** continuously.

### So our real "auto-backup" already exists: the Supabase warehouse
Every Jobber entity we care about is mirrored into `public.*` (clients, jobs, visits, line_items,
invoices, quotes, properties, employees) and cross-linked via `entity_source_links`. That database:
- is **point-in-time recoverable** (PITR is the pending gate — see [project_pending_pitr_enable]),
- is **queryable and exportable** at will,
- and is **independent of Jobber** (different vendor, AWS-different).

**Recommendation — add two cheap layers on top of the live mirror:**
1. **Daily versioned full snapshot.** A scheduled job dumps each Jobber entity (via the API *or* directly
   from the Supabase mirror) to dated JSON/CSV files in **Supabase Storage** (or an S3/Git bucket), keeping
   ~30–90 days. This gives true *point-in-time* copies you can diff and restore from — cheap, ~minutes.
2. **Monthly native CSV pull.** Once a month, export the Clients + Jobs + Invoices reports from the Jobber
   UI and drop them in the same bucket. Vendor-format copies, useful if you ever migrate off Jobber.

(With **PITR enabled on the Supabase Prod project**, the Supabase side alone already covers most
"oops, restore to yesterday" scenarios for the mirrored data.)

---

## 4. "Installing"/restoring a backup — what's actually possible

This is the hard truth: **Jobber is not built for customer-controlled full restore.** Your options:

| Restore path | Restores | Does NOT restore |
|---|---|---|
| **Native CSV import** — *Import Clients*, *Import Jobs* (field mapping) | clients + jobs as **new** records | original IDs, visit history, invoices/payments, attachments, links between records |
| **GraphQL write API** (our `jobber_write` app) | re-create clients, jobs, **visits**, line items, assignments | historical timestamps, completed/invoiced state, original GIDs |

Key caveats for any Jobber restore:
- **IDs change.** A re-imported client/job gets a **new** Jobber GID, so every external link
  (our `entity_source_links`, QuickBooks, etc.) must be re-mapped.
- **History/financials don't come back.** Past completed visits, issued invoices, and payments can't be
  faithfully re-created via import/API.
- So a "restore" is really a **re-seed of the active, operational data** (clients, open jobs, upcoming
  visits + their line items), **not** a faithful rollback.

### Practical restore playbook (if Jobber data is lost/corrupted)
1. **Restore the source of truth first** — Supabase (PITR or the dated snapshot from §3.1). This is the
   authoritative copy.
2. **Re-seed Jobber from Supabase** via the write API, in order: clients → properties → jobs (+ line
   items / frequency) → upcoming visits (+ crew). We already have all of these write paths
   (`jobber-push-visit`, the SA generator, `create_calendar_visit`). The 60-day horizon means we only
   need to re-push the near-term window, not a year.
3. **Re-map links** — repopulate `entity_source_links` with the new Jobber GIDs as records are created
   (the push already writes these back).
4. **Re-import financial history only if needed** via the Clients/Jobs CSVs (accepting new IDs), or leave
   historical invoices in Supabase/QuickBooks as the system of record.

---

## 5. Recommendation for UnclogMe (layered strategy)

| Layer | What | Status |
|---|---|---|
| **L0 — Jobber's own daily backup** | Jobber's internal DR | exists, but **not yours to restore** |
| **L1 — Live mirror** | Supabase warehouse continuously synced from the Jobber API | **already running** |
| **L2 — Point-in-time** | **Enable PITR** on the Supabase Prod project | **pending gate** ([project_pending_pitr_enable]) — finish it |
| **L3 — Versioned snapshots** | Daily JSON/CSV dump of all entities → Storage bucket, 30–90 day retention | **recommended to add** (small cron) |
| **L4 — Vendor-format copy** | Monthly native Clients/Jobs/Invoices CSV exports | **recommended** (manual or scripted) |
| **Restore** | Supabase = source of truth → re-seed Jobber's near-term window via the write API | **playbook in §4** |

**Bottom line:** Don't count on Jobber for *your* backup or restore — it isn't built for it. Our Supabase
mirror **is** the backup; the work left is (a) turn on PITR, and (b) add a small daily snapshot-to-Storage
job for true point-in-time copies. Restoring means restoring Supabase, then re-pushing the active window to
a fresh/repaired Jobber account.

---

## Sources
- [Jobber FAQ — data backed up daily, AWS, redundant](https://www.getjobber.com/faq/)
- [Export Client Information — Jobber Help Center](https://help.getjobber.com/hc/en-us/articles/115009619328-Export-Client-Information)
- [Import or Export Clients — Jobber Help Center](https://help.getjobber.com/hc/en-us/sections/7792823112087-Import-or-Export-Clients)
- [Import your Jobs — Jobber Help Center](https://help.getjobber.com/hc/en-us/articles/25782525960215-Import-your-Jobs)
- [Jobber Developer Center — GraphQL API](https://developer.getjobber.com/docs/)
- [GraphQL queries & mutations (pagination)](https://developer.getjobber.com/docs/using_jobbers_api/api_queries_and_mutations/)
- [Jobber GraphQL API rate limits](https://developer.getjobber.com/docs/using_jobbers_api/api_rate_limits/)
