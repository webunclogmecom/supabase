# The GDO report bot (Jonathan's RPA, now ours)

Read 2026-10-19. Fred: *"read the README and the /docs, do a full inspection of it, I want you to have a full
understanding of it, also remember they're hosted in Railway too."*

**Sources:**
- The bot repo `webunclogmecom/unclogme-gdo-report-bot` at `87b24a2`: README, all 23 docs, every module and test.
  Ten readers each took one area, then a synthesis pass checked every disagreement between them against the code.
- The live Railway service, read 2026-10-19: deployments, logs, and the non-secret variables.
- Our database.

Paths below are in the bot repo unless they start with `Supabase/`. No secret value appears here.

Since the handoff (Yan decided it 2026-09-25, the call was held 2026-10-08) **Fred owns the bot**. Diego is the
operator and Yan makes the policy calls. Jonathan is out of the loop unless there is a separate agreement
(`docs/HANDOFF.md`). `docs/reference/gdo-rpa-bot-triggers.md` is Jonathan's July copy and is older than this file.

## 1. What it is

One Railway service, one Python process (FastAPI + Playwright + SQLite), holding **two products and a dashboard**:

| | what it does | files anything? |
|---|---|---|
| **GDO bot** | Every hour it reads our queue (`rpa-derm-queue`). It files one GDO online report per (permit, manifest) on the Miami-Dade DERM portal, then posts the result to `rpa-derm-result`. It also harvests the county's confirmation emails from the fog@ mailbox as evidence. | yes, on the county portal |
| **Monthly LWT report** (county form ST) | Builds the county's own .xlsx from `rpa-derm-monthly` plus the paper W&S invoice. Diego previews and approves it, a person emails it to DERM, and it is recorded back through `rpa-derm-monthly-filed`. | no, a person sends it |
| **Dashboard** | Pages `/`, `/dashboard/bot`, `/dashboard/monthly` and `/monthly`. Every data route needs `x-run-key`; there are personal keys in `RUN_KEYS` (Diego has his own). | no |

Prime directives, in Jonathan's order: never file twice, never lose a visit silently, never let a machine file what no
human could trace (`docs/PROJECT_GDO_BOT.md`).

## 2. Where it runs (Railway, measured 2026-10-19)

- **Project:** `unclogme-gdo-report-bot`, service `UnclogMe_Reporter_Bot`, environment `production`. Seen from the
  `web@unclogme.com` Railway login.
- **Volume:** mounted at `/data`. It holds the SQLite ledger (the double-filing memory), logs, emails, screenshots and
  monthly files, plus 7 daily ledger backups on the **same** volume.
- **Deploys:** every push to `main` deploys, and there is no staging. Running now: deployment `9ef62d4a` =
  **`87b24a2`**, live since 2026-10-18 21:27 ET. That commit is monthly-only, and its own note said "push held until
  2026-10-20", but it is live.
- **One replica, one worker.** A second replica would break the double-filing guard silently.
- **No Railway cron.** Three threads inside `server.py` sleep first, then run:
  - **poll:** hourly, currently at about :29 each hour since the 01:29 UTC restart;
  - **harvest:** hourly;
  - **digest:** 08:00 New York time. It backs up the ledger, then posts yesterday's Slack digest.
  - A restart resets the clocks, and a restart after 08:00 skips that day's digest.

**Live switches**, read from Railway. Code defaults are in brackets.

| variable | live | meaning |
|---|---|---|
| `SHADOW_MODE` | **false** [true] | live filing; the logs show `mode=live` |
| `MIGRATE_LEGACY_EMAIL` | **true** [false] | moves a permit's portal email from contact@ to fog@ |
| `MIGRATE_ANY_EMAIL` | **true** [false] | moves **whatever** email a permit holds on the county portal to fog@ (Yan's 2026-10-08 rule). `docs/HANDOFF.md` says this was deployed OFF; it is ON |
| `INLINE_EMAIL_EVIDENCE` | **true** [false] | after a submit, waits up to 120 s for the county email and uses it as the evidence image |
| `LATE_EVIDENCE_LIVE` | **true** [false] | a filing whose email was missed posts no image and gets the email later through `rpa-derm-evidence` |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | 120 | lets an in-flight filing finish on a deploy |
| `API_BASE_URL` | our `functions/v1` | |

Everything else is at its code default: poll and harvest every 3600 s, digest hour 8, circuit breaker after 3
failures, login guard after 2, files purged after 60 days.

## 3. How one filing works (`reporter.py`)

1. GET the queue: live, up to 25 rows. Our side leases each row it serves for 20 h, per (visit, permit).
2. **Preflight:** permit, ticket number and service date must not be empty. ⚠ The check is
   `str(item.get(k, '')).strip()`, so a JSON **null becomes the text "None" and passes** (line 221). See section 8.
3. The date must parse, or the item is our `ERROR_VALIDATION`. A date is never typed in that cannot be read.
4. The permit string is split on commas. If no permit is left, the bot refuses with
   `No readable GDO permit in '...'` (lines 577-590).
5. Per permit:
   - in-batch dedup;
   - a ledger check: a permit already filed is re-asserted to us under its original `run_id`, without touching the
     portal.
6. Portal, per permit:
   - permit number;
   - the facility email: fill, accept or migrate to fog@, or stop on a mismatch;
   - password;
   - "Liquid Waste Transporter" and work group "1133 - UNCLOGME LLC";
   - **date pumped**;
   - preview, certify checkbox, screenshot;
   - **Submit**.
   - The manifest number, the client and the dump date are never typed: the county form does not ask for them, and it
     takes **no attachment**.
7. Crash-safe order on a live success: write the ledger row, cache the result, wait for the county email, POST to us,
   then drop the cache.
8. Failure handling:
   - 3 timeouts or crashes in a row abort the queue and alert Slack;
   - 2 login failures in a row do the same;
   - a deploy drains at the next item.
9. At the end of the run, one Slack alert lists every new `ERROR_*` row. It alerts once per process, so a deploy
   alerts again.

### What each result does on our side

Which rows it holds is decided by `v_derm_portal_queue`.

| status the bot posts | retryable | our queue then |
|---|---|---|
| `SUCCESS` (or any non-null `portal_confirmation`) | no | never serves that (manifest, permit) again |
| `ERROR_VALIDATION`, `ERROR_EMAIL_MISMATCH`, `ERROR_LOGIN_FAILED` | **no** | 20 h cooldown, then **held as `data_error`** until the visit or manifest row changes, or someone runs `fn_requeue_derm_portal` |
| `ERROR_PORTAL_TIMEOUT`, `ERROR_UNHANDLED` | yes | serves it again after 20 h |
| `DRY_RUN_COMPLETE` | | stored as a dry run, gates nothing |

⚠ **The `data_error` hold lifts on ANY write to the visit row.** That includes the time-on-site jobs, an invoice sync,
or a truck change: `v_derm_portal_fields.updated_at` is the visit's or manifest's `updated_at`. A held visit is
therefore re-served, and re-refused, whenever something unrelated edits it. Section 8 is the worked example.

## 4. The contract with us

- **Authentication:** header `x-rpa-key` against `RPA_BOT_KEYS`.
- **Endpoints:**
  - GET `rpa-derm-queue`;
  - POST `rpa-derm-result`;
  - POST `rpa-derm-evidence` (the late email image, fill-once);
  - GET `rpa-derm-monthly`;
  - POST `rpa-derm-monthly-filed`.
- **What the bot reads from a queue row:** `gdo_number`, `ticket_number` (as the manifest number), `service_date`,
  `visit_id`, `manifest_id`, `dump_ticket_date`, `dry_run`, `client_name`, `client_code`.
  It ignores `held`, `count`, `gdo_id` and `documents`. `documents` has been sent empty since `2026-10-18_2100`.
- **The result body:**
  - `visit_id`, `manifest_id`, `run_id` (a new uuid per attempt), `status`, `retryable`, `attempted_at`, `dry_run`;
  - either a screenshot or `screenshot_missing_reason`;
  - `failure_reason`, and `portal_confirmation` only on a real filing.
- ⚠ **The bot never sends `gdo_id`.** So `rpa-derm-result` infers the permit (`fn_resolve_rpa_permit`, "lowest
  unfiled ACTIVE permit"). Our own comment there names the case this gets wrong: on a manifest with several permits,
  if the bot files A and C and A fails, C's SUCCESS is recorded against A. The fix on the bot side is one line in
  `build_result_payload`: echo `item["gdo_id"]`. Our endpoint already validates it.

## 5. Evidence

- The county emails the permit's portal address. The email carries no manifest and no confirmation number, so it
  matches a ledger row by (permit as an integer, date pumped).
- **Transport:** IMAP with an app password on the fog@ group member is the main path; Gmail OAuth is the fallback.
- **The evidence image is redrawn** from the parsed email, not screenshotted.
- With both evidence switches on (section 2): a caught email becomes the image at once; a missed one is attached
  later by the hourly drain.

## 6. Slack and the dashboard

- **Daily digest**, 08:00 New York, covering yesterday. It lists one line per ledger row, with no grouping and no
  acks.
  - **filed** = SUCCESS;
  - **failed** = timeout, unhandled or crash;
  - **needs review** = every other live error, VALIDATION included.
  - **"in queue"** is a **live** queue fetch made at send time. ⚠ That fetch leases whatever it returns for 20 h, so a
    visit waiting at 08:00 is not filed by the next hourly poll but about 20 h later (`server.py:2895-2903`).
  - **"Last run"** is the newest ledger time, shown with no date.
- **Immediate alerts:** failures at the end of a run, the login guard, the circuit breaker, a discarded cached
  result, an aborted harvest, and county emails that matched no filing.
- **`/dashboard/bot`:**
  - "Needs attention" counts (permit, manifest) pairs with an error in the last 30 days and no ack.
  - "Mark handled" needs a note and covers rows only up to the ack time. **It never quiets the Slack digest.**
  - Hand-typed GDO entries run through the same loop and are never posted to us.

## 7. The monthly LWT report (in brief)

- **Pipeline:** our feed, then the invoice (PDF text or OCR), then reconcile, then a signed preview, then the .xlsx
  written onto `templates/DADE_Monthly_Fill_Form.xlsx`, then "Record as filed".
- **The month is the county's invoice package**, not the calendar.
- **Gallons:**
  - Dade loads use the decal constant: C1184 = 3,800, C0976 = 2,000.
  - Dade pickups dumped elsewhere use the clients' trap sizes, and the ticket is held whole if one size is missing.
- **Fee** = gallons x $0.00419, truncated per page.
- **Open items:**
  - SSO C1 to C5, our side, is not built;
  - brief D (discard a draft) is not started;
  - the September report is due 2026-10-20.

## 8. Reading a "No readable GDO permit in ''" warning

**What it means:** our queue sent a row whose `gdo_number` was **null**, which happens when the client has no ACTIVE
`GDO-<digits>` permit. Step 2 of section 3 lets the null through. Line 518 turns it into `''`, the split leaves no
permit, and the guard prints the empty quotes.

An empty string would instead have read "No GDO permit on this visit". Either way:
- the bot refuses before opening the portal;
- nothing is filed;
- it posts `ERROR_VALIDATION`, not retryable.

The refusal is right; only the sentence is misleading.

**Worked example: the Oct 18 digest** (sent 2026-10-19 08:00 ET: "0 filed, 2 needs review").

| | visit | manifest (ticket) | permit on file |
|---|---|---|---|
| 315-CAP Capas Burger Aventura | 7849, 2026-08-28 | 1773 (834433) | none |
| 249-LOU Skinny Louie Wynwood | 7859, 2026-09-16 | 1958 (836200) | none |

- **Why they came back that day.** Both rows had been held as `data_error` since earlier refusals: 7849 was refused
  09-01, 09-02, 09-03 and 10-06; 7859 on 09-18, 09-19 and 10-12.
  - At **13:15:48 ET** the one-time time-on-site fix (`app_source = 'time-on-site-fix-2026'`) set
    `time_on_site_source` on both visits. That moved their `updated_at` and lifted the hold.
  - The bot's run at 13:36 ET served both and refused both. Each POST was answered HTTP 201, and the immediate Slack
    alert went out at 13:36.
  - The next morning's digest counted them.
- **History** (Slack `#new-app-issues` and `#gdo-permit`):
  - 2026-09-03: Jonathan flagged Capas plus two Skinny Louie locations. Fred: "They currently don't have GDO's", then
    "Skinnie louie both locations are done, Capa is under revision".
  - The same day, the GDO Slack bot scanned 3 permit PDFs at 21000 W Dixie Hwy and found **no permit for Capas**.
  - 2026-09-18: the GDO Slack bot found **GDO-14738** for FLIP A BURGER LLC DBA SKINNY LOUIE at 322 NW 24th St (active
    through 2026-12-31, every 90 days), the Wynwood address. Fred: "it needs Diego or Yan approval first". It was
    never entered.
- **Reach:** these are the only 2 visits after the launch cutoff that have no permit. 249-LOU is the only client with
  an open Line Item 27 job and no ACTIVE permit. Capas's line 27 came from its invoice, not its job, so its future
  visits are not GDO-reporting. 249-LOU's 2026-10-18 visit (7860) will be served the same way once its manifest is
  filed.
- **Adding a permit alone does not release a held visit:** `gdos` is not part of `updated_at`. Add the permit (ACTIVE,
  `GDO-<digits>`, with its PDF), then run `public.fn_requeue_derm_portal(visit_id, <new gdo_id>, reason, by)`.
- **Open since 2026-09-03:** Jonathan asked that the queue stop serving visits with no permit, or flag them as "no
  permit yet" rather than bad data. It was not built. He also asked whether past visits must be filed retroactively
  once the permit exists.

## 9. Risks the inspection found in the bot

Each was checked against the code. They are not fixed.

1. **No `gdo_id` on results** (section 4): a mis-attributed SUCCESS on a multi-permit manifest.
2. **Preflight passes null:**
   - a null permit gives the misleading sentence;
   - a null `ticket_number` would be filed live with manifest `''`, sharing one ledger key across visits.
   - Fix: `str(item.get(k) or '')`, the form `validate_manual_entry` already uses.
3. **The digest's live fetch takes work away for 20 h** (section 6).
4. **Daylight saving:** the digest sleeps by wall clock. On 2026-11-01 it wakes at 07:00 EST, sends, then sends again
   at 08:00 (two digests for Oct 31). In March it fires at 09:00.
5. **A timeout after the final Submit** is recorded as a retryable timeout with no SUCCESS row, so that report could be
   filed again 20 h later.
6. **Login and email-mismatch failures are not retryable**, so a fixed password still needs a requeue on our side.
   8095 / 246-LOUI is the live case.
7. **Docs that the code contradicts:**
   - "one permit per ticket per pass" and "gdo_id accepted and ignored" (README, API_CONTRACT);
   - "re-queues every 20 h forever" (`reporter.py:574`, RUNBOOK);
   - the digest at "12:00 UTC" (RUNBOOK; that holds in summer only);
   - `MIGRATE_ANY_EMAIL` "deployed OFF" (HANDOFF; it is ON).
   - The repo's tests do not cover a null permit, and the digest has no test at all.
