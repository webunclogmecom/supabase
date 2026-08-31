# Briefing for the GDO Bot session — John's GDO Online Reporting bot + our API + Railway hosting

*Paste this whole thing into the GDO Bot Claude session. It is everything that session needs to (a) understand John's bot, (b) understand the API we exposed, and (c) recommend how to host the bot on Railway. No secrets are included: keys and the portal login are referred to by name only.*

---

## 1. What the bot is

John (Jonathan, IT hire) built a **Python RPA bot** that files **GDO Online Reporting** on the Miami-Dade DERM portal. It is browser automation against an ASP.NET / ViewState portal (log in, fill the online report form, submit, capture a confirmation + a screenshot).

- **Scope is tiny and fixed.** GDO Online Reporting is **Line Item 27** on a client's job, an add-on only **3 clients** carry today (041-MB, 082-TFC, 111-YC). Most days the queue is near-empty; a batch is capped at 25.
- **Unit of work = a serviced dump.** The queue is deduped to **one row per manifest (dump ticket)**; a dump ticket is the unit of one DERM online report. The response still keys each row by `visit_id` (that is the work key the bot echoes back), but each dump appears once even if multiple visits share it.
- **Status:** the first dry-run passed clean end to end on 2026-07-22 (24 `DRY_RUN_COMPLETE` results, each with a screenshot stored, 0 live filings). The bot currently pauses at the portal preview (no submit) during testing. It is NOT live to the county yet. Go-live is gated: dry-run pass, then one live report on a single visit Fred picks and verifies on the county side, then it opens for all.

## 2. The API we gave him (the entire integration surface)

No database access ever leaves our side. The bot talks to **two live Supabase edge functions** on Prod (`wbasvhvvismukaqdnouk`), authenticated by **one shared secret header** `x-rpa-key` (value handed over privately; it lives only in an env var). There is no second key and nothing on our side ever calls the bot.

### 2a. GET `https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/rpa-derm-queue`

Poll for up to 25 reports to file (oldest first). `?mode=dryrun` serves historical visits for testing (their results are tagged dry-run and never count as real).

Response envelope: `{ generated_at, mode: 'live'|'dryrun', count, reports: [ ... ] }`

Each `reports[]` object:

| Field | Type | Notes |
|---|---|---|
| `visit_id` | integer | **The work key.** Echo it back in the result POST. |
| `manifest_id` | integer | Dump-ticket id; optional context to echo back. |
| `dry_run` | boolean | True when served via `?mode=dryrun`. |
| `client_code` | string | e.g. `041-MB`. |
| `client_name` | string | |
| `client_email` | string | |
| `address` | string | |
| `city` | string | |
| `zip` | string | |
| `county` | string | |
| `gdo_number` | string | The GDO permit number to file under. |
| `service_date` | date | The visit's service date (our `visit_date`). |
| `dump_ticket_date` | date | The dump date. |
| `white_manifest_number` | string | The white manifest number. |
| `disposal_facility` | string | Where it was dumped. |
| `documents` | object | `{ address: [signed URLs], receipt: [signed URLs] }`. **Signed, 4-hour TTL, minted fresh on every fetch.** Download everything at the start of the run; never log or store the URLs. |

### 2b. POST `https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/rpa-derm-result`

Log the outcome (same `x-rpa-key`). This feeds our apps (per-client, per-visit "GDO report filed / pending / failed" in the DERM tool + the customer portal), so fields matter. **Unknown fields are rejected with a 400.** Accepted body:

| Field | Required | Rule / format | 400 error code if wrong |
|---|---|---|---|
| `visit_id` | yes | integer, from the queue | `visit_id_required_integer` |
| `manifest_id` | no | integer or omitted | `manifest_id_must_be_integer_or_omitted` |
| `run_id` | yes | `^[A-Za-z0-9_.-]{1,100}$` (it becomes part of a storage key) | `run_id_must_be_alnum_dot_dash_underscore_max100` |
| `status` | yes | `^[A-Z0-9_]{1,64}$` (short uppercase). Literal **`SUCCESS`** marks the visit permanently done. | `status_must_be_short_uppercase_code` |
| `retryable` | yes | boolean. `true` for transient issues (portal timeout), `false` for data problems (missing field). | `retryable_boolean_required` |
| `failure_reason` | no | string, ≤ 1000 chars | `failure_reason_max_1000_chars` |
| `portal_confirmation` | no* | string, ≤ 200 chars. *A real `SUCCESS` MUST include this. | `portal_confirmation_max_200_chars` |
| `attempted_at` | yes | ISO 8601 timestamp. **Display/audit only** — our queue timing uses our own server clock, so a skewed bot clock cannot cause a double-file. | `attempted_at_must_be_iso8601` |
| `screenshot` | no* | base64 JPEG, ≤ 5MB decoded. *Every result carries a screenshot OR `screenshot_missing_reason`. Stored in the PRIVATE `rpa-evidence` bucket; only the path is kept. | (oversize/undecodable is accepted-and-flagged, not dropped) |
| `screenshot_missing_reason` | no* | string, ≤ 300 chars. Send only when capture itself truly failed. | |
| `dry_run` | no | boolean. **Derived server-side from the manifest's cutoff classification, never trusted from the bot.** Send your best guess; the server recomputes it. | |

**Idempotency + lifecycle guarantees (why the bot is safe to run freely):**
- The POST is **idempotent on `(visit_id, gdo_id, run_id)`** (widened 2026-08-31; it was `(visit_id, run_id)`), so a retried POST returns 200. So: generate `run_id` **once per attempt, before hitting the portal**, reuse it verbatim on every retry, and keep retrying the POST until you get a 2xx. Never treat a report as done before we acknowledge it.
- The **queue only returns visits still needing a filing.** A `SUCCESS` (or any status carrying `portal_confirmation`) removes the dump permanently.
- Each dispensed dump is **leased for 20 hours** (`derm_portal_leases`) the moment it is handed out, so a crash mid-run can't get it re-handed to a second run.
- **No optimistic success ever:** a visit counts as reported only when the portal actually confirmed it (enforced by DB constraints, not just the function).
- There is a **launch cutoff** on our side (`dump_ticket_date >= 2026-07-21`) so the first live run cannot re-submit the historical backlog to the county.

## 3. Deployment shape (this is what drives the Railway decision)

- **Poll model, fully self-managed.** Nothing on our side calls the bot. It owns its cadence: poll the GET queue on a slow schedule (say every 15-30 min), file each report, POST the result. That is the entire loop.
- Therefore the bot is **outbound-only**: it makes HTTPS calls to our two endpoints plus the DERM portal. It **exposes no endpoint, needs no public URL, no inbound port, no healthcheck**.
- Safe to run as often as it likes (see the lifecycle guarantees above: queue-only-if-unfiled + 20h lease + idempotent POST = a duplicate or retried run never double-files).
- It runs a **headless browser** (Selenium or Playwright — confirm which with John) and logs into the county portal with a **separate portal login** (also a secret; Fred sends it privately).

**Fred's non-negotiable hygiene rules for the deploy (this system touches client PII):**
1. New **PRIVATE repo** under the `webunclogmecom` GitHub org; Railway auto-deploys from `main`.
2. The **portal login and the `x-rpa-key` live only in Railway environment variables**, never in code or logs.
3. The bot **logs `visit_id` and `status` only** — never request bodies, signed URLs, or client fields.
4. The bot **deletes downloaded documents and screenshots from disk once the result POST is acknowledged**, so nothing persists between runs.
5. **No real client data, CSVs, screenshots, or portal dumps ever go in the repo.** Test fixtures are synthetic. If the current repo has ever contained real data or credentials, start the org repo clean rather than migrating history.

## 4. Your job: recommend the Railway setup

The main decision is the **Railway service type** for a poll-based, browser-automation bot. Weigh:

- **Cron Job (scheduled).** Runs the script every ~20-30 min: poll, file the batch, POST results, exit. No idle cost, clean start each run, maps 1:1 onto the poll model. Trade-off: cold-starts a headless browser and re-logs into the portal every run.
- **Always-on Worker (persistent loop).** A `poll → sleep → poll` process that can keep a warm, already-logged-in browser session between polls. Better if the portal login is slow or has 2FA. Costs idle time.
- **Not a Web service** — nothing calls the bot, so no reason to expose a port.

Given the feed is tiny and the model is poll-based, a **Cron Job is the leaner default**; a **Worker** wins only if reusing a logged-in browser session between runs is worth the always-on cost. To decide, confirm with John:
1. Selenium vs Playwright (drives the Docker base image + memory).
2. Whether the DERM portal login is slow or has **2FA** (i.e. is a persistent session worth keeping warm?).
3. How long one full run takes (a Cron Job must finish comfortably inside its run budget, and always inside the 4-hour signed-URL window — trivial for a small batch).

Then cover the concrete Railway bits in the recommendation:
- A **Dockerfile** with Chromium + the RPA framework installed (Playwright's official image, or `apt-get` chromium for Selenium), plus the JPEG/screenshot toolchain.
- **Env vars:** `x-rpa-key`, the queue/result base URL (`https://wbasvhvvismukaqdnouk.supabase.co/functions/v1`), and the county portal login.
- **No `PORT` / healthcheck** for a worker or cron (not a web service).
- **Memory sizing** for a headless browser (Chromium is memory-hungry; size the plan accordingly).
- Bake **hygiene rules 2-5** above into the deploy (env-only secrets, minimal logging, disk cleanup after ACK, clean repo).
- If a Cron Job: set the schedule to the poll cadence (e.g. every 20-30 min) and make the script idempotent to a mid-run kill (it already is, via `run_id`).

## 5. Reference (our side, for deeper context)

- Full contract + the reply Fred sent John: `Supabase/docs/handoffs/2026-07-21_rpa_bot_reply_to_john.md` (has the 2026-07-23 update: first dry-run, per-manifest dedup, DERM-required flag).
- Edge functions: `Supabase/supabase/functions/rpa-derm-queue/index.ts` and `.../rpa-derm-result/index.ts`.
- Queue is deduped per manifest: migration `2026-07-23_gdo_queue_dedup_per_manifest.sql`.
- Hardening + go-live prereqs (server-clock gates, dispense lease, DB backstops, watchdog): migration `2026-07-21f_rpa_backend_hardening.sql`; watchdog `public.v_rpa_derm_health` + `log_rpa_derm_health()` + pg_cron `rpa-derm-health-check`.
- Status surfaces our apps read: `derm.gdo_report_status` (DERM Tracker) and `customer.gdo_reports` (Field Portal).
