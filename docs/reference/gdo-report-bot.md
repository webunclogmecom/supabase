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
| **Dashboard** | Pages `/`, `/dashboard/bot`, `/dashboard/monthly` and `/monthly`. Every data route needs `x-run-key`; there are personal keys in `RUN_KEYS` (`yan`, `diego`, and `fred` since 2026-10-26). The dashboard pages ask for the key in their key box. Address: https://unclogmerpabot-production.up.railway.app. | no |

Prime directives, in Jonathan's order: never file twice, never lose a visit silently, never let a machine file what no
human could trace (`docs/PROJECT_GDO_BOT.md`).

## 2. Where it runs (Railway, measured 2026-10-19)

- **Project:** `unclogme-gdo-report-bot`, service `UnclogMe_Reporter_Bot`, environment `production`. Seen from the
  `web@unclogme.com` Railway login.
- **Volume:** mounted at `/data`. It holds the SQLite ledger (the double-filing memory), logs, emails, screenshots and
  monthly files, plus 7 daily ledger backups on the **same** volume.
- **Deploys:** every push to `main` deploys, and there is no staging. Running now: deployment `789c211a` =
  **`7681388`** (the four fixes of section 9), live since 2026-10-20 12:54 ET. Before it, `87b24a2` (monthly-only,
  its note said "push held until 2026-10-20") had been live since 2026-10-18 21:27 ET. Railway's audit log shows that
  deploy was triggered by Jonathan's account (read 2026-10-22).
- **Keys rotated 2026-10-22 (Railway breach, `docs/audits/2026-10-22_railway_breach_rotation.md`):** `RPA_BOT_KEY`
  (edge `RPA_BOT_KEYS` holds only the new one), `RUN_KEY`, `RUN_KEYS` (now `yan` and `diego`; Jonathan's key
  removed), `SLACK_WEBHOOK_URL` (a new hook of the Slack app "GDO Online Report", #new-app-issues). Jonathan is no
  longer a member of this Railway project (Fred: keep his GitHub write). **Not yet rotated:** `GDO_PASSWORD` (county
  portal, the office changes it) and `FOG_IMAP_APP_PASSWORD` (the mailbox owner). The redeploys restarted the bot's
  timers: the poll now runs about :27 each hour. The new webhook's first real use is the 2026-10-23 08:00 ET digest
  (bot log "Daily Slack digest sent", or the post in #new-app-issues).
  ⚠ The verification found the OLD `RPA_BOT_KEY` used from OUTSIDE Railway before the breach: 22
  `rpa-derm-queue?mode=dryrun` calls on 2026-10-18 and 2026-10-20 with the bot's own HTTP client, most likely a local
  copy of this bot (inferred, not verified). Such a copy also needs the two passwords above, which is one more reason
  to rotate them. The old key now answers 401.
- **One replica, one worker.** A second replica would break the double-filing guard silently.
- **No Railway cron.** Three threads inside `server.py` sleep first, then run:
  - **poll:** hourly, timed from the last restart (since 2026-10-20 12:54 ET, about :54 each hour);
  - **harvest:** hourly;
  - **digest:** 08:00 New York time. It backs up the ledger, then posts yesterday's Slack digest.
  - A restart resets the clocks. A restart after 08:00 sends no digest that day, unless the old process already had.

**Live switches**, read from Railway. Code defaults are in brackets.

| variable | live | meaning |
|---|---|---|
| `SHADOW_MODE` | **false** [true] | live filing; the logs show `mode=live` |
| `MIGRATE_LEGACY_EMAIL` | **true** [false] | moves a permit's portal email from contact@ to fog@ |
| `MIGRATE_ANY_EMAIL` | **true** [false] | moves **whatever** email a permit holds on the county portal to fog@ (Yan's 2026-10-07 rule, `docs/DOMAIN_RULES.md`). `docs/HANDOFF.md` says this was deployed OFF; it is ON |
| `INLINE_EMAIL_EVIDENCE` | **true** [false] | after a submit, waits up to 120 s for the county email and uses it as the evidence image |
| `LATE_EVIDENCE_LIVE` | **true** [false] | a filing whose email was missed posts no image and gets the email later through `rpa-derm-evidence` |
| `RAILWAY_DEPLOYMENT_DRAINING_SECONDS` | 120 | lets an in-flight filing finish on a deploy |
| `API_BASE_URL` | our `functions/v1` | |

Everything else is at its code default: poll and harvest every 3600 s, digest hour 8, circuit breaker after 3
failures, login guard after 2, files purged after 60 days.

## 3. How one filing works (`reporter.py`)

1. GET the queue: live, up to 25 rows. Our side leases each row it serves for 20 h, per (visit, permit).
2. **Preflight:** permit, ticket number and service date must not be empty or null. Until `7681388` (2026-10-20)
   the check was `str(item.get(k, ''))`, so a JSON null became the text "None" and passed. See section 8.
3. The date must parse, or the item is our `ERROR_VALIDATION`. A date is never typed in that cannot be read.
4. The permit string is split on commas. If no permit is left, the bot refuses with
   `No readable GDO permit in '...'` (`run_reporter`, after the comma split).
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
| `ERROR_VALIDATION`, `ERROR_EMAIL_MISMATCH`, `ERROR_LOGIN_FAILED` | **no** | 20 h cooldown, then **held as `data_error`** for that same permit (exact pair since `2026-10-20_1345`) until the visit or manifest row is next written, or someone runs `fn_requeue_derm_portal` |
| `ERROR_PORTAL_TIMEOUT`, `ERROR_UNHANDLED` | yes | serves it again after 20 h |
| `DRY_RUN_COMPLETE` | | stored as a dry run, gates nothing |

⚠ **The `data_error` hold lifts on ANY write to the visit or manifest row**, even one that changes nothing:
`public.set_updated_at` stamps `updated_at` on every UPDATE and `audit.log_change` drops a no-op one, so a re-serve can
have no audited cause (7849 on 09-03 and 10-06). The time-on-site jobs, an invoice sync and a truck change all do it.
Section 8 is the worked example.

🛑 **A visit with no permit is never served since `2026-10-20_1345`.** The queue skips `gdo_id IS NULL`, the held
view names it `no_permit`, and the health email lists it per visit (section 8).

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
  Since `7681388` it also reads `gdo_id`, to echo it. It ignores `documents` (sent empty since `2026-10-18_2100`) and
  the row's `jurisdiction`; `held` and `count` are response-level and unused.
- **The result body:**
  - `visit_id`, `manifest_id`, `run_id` (a new uuid per attempt), `status`, `retryable`, `attempted_at`, `dry_run`;
  - either a screenshot or `screenshot_missing_reason`;
  - `failure_reason`, and `portal_confirmation` only on a real filing.
- **The bot echoes `gdo_id` since `7681388` (2026-10-20)**, when the row's `gdo_number` holds exactly one permit.
  `rpa-derm-result` (validation since 2026-08-31) uses it when it is one of the visit's permits in the queue's fields;
  since v31 (2026-10-20) it also keeps it when it is any permit of the visit's client (it may have left the fields
  between the serve and the POST); only then does it infer (`fn_resolve_rpa_permit`, "lowest unfiled ACTIVE permit").
  Results before 2026-10-20 were all inferred. ⚠ The first real result carrying `gdo_id` is the first proof.
- **`?mode=`** is `dryrun` (a 25-row historical sample, no lease), `peek` (the live queue, no lease, since v32) or
  absent (live, leased). Anything else is refused with 400 `unknown_mode` since v33 (it used to read as live).
- **A dashboard manual entry posts `manual_entry` and no `visit_id` (accepted since `rpa-derm-result` v40,
  2026-10-26; race fix v42, 2026-10-27).** Section 10.

## 10. Dashboard manual entries ("Add a report by hand", 2026-10-26)

Fred, 2026-10-26: *"what data means is that someone used [the bot] dashboard to file it manually ... so at the end of
the day it was a manual filing, so we can just accept that new data as a criteria and we can classify it as a manual
filing in our apps"*.

**What happened first.** Yan filed 041-MB visit 8888 (permit 14965, manifest 808783, service date 2025-11-16) from the
dashboard at 12:00 ET. The county accepted it. The bot then POSTed a body carrying `manual_entry: {created_by, why}`
with `visit_id` and `manifest_id` null, and `rpa-derm-result` answered 400 `unknown_field_manual_entry`, every hour.
Two bot facts behind it (bot repo at `7681388`):
- the bot's design says a manual entry never posts (R7 in `docs/REQUIREMENTS_TRACKER_SSO.md`), but the guard lives
  only in `reporter._post_and_cache`; the crash-insurance seed (`reporter.py:963`, `db.cache_failed_result`) and the
  final POST after the email (`reporter.py:1060`) skip it, so every SUCCESS of a manual entry reaches us;
- the body carries nothing that says which visit it is (no permit, manifest or date), and the hourly retry resends the
  SEED, written before the county email arrived, so it has no image either (`INSERT OR IGNORE`, `db.py:428`). The
  bot drops a cached result after 11 failed retries and posts "Result discarded without delivery to Supabase".

**What `rpa-derm-result` does now (`recordManualEntry`, v40; v42 since 2026-10-27 14:25 ET adds the "record error" row):**

| step | rule |
|---|---|
| shape | `manual_entry` keys allowed: `created_by`, `why`, `gdo_number`, `ticket_number`, `service_date`, `dump_date`; anything else is 400. A body with `manual_entry` AND a `visit_id` / `manifest_id` / `gdo_id` is 400 |
| dedupe | first, on the stored run_id `manual-bot-<bot run_id>` alone |
| only a filing | status `SUCCESS`, `dry_run` not true and a `portal_confirmation`, else 200 `recorded:false` and nothing written |
| the visit | `v_derm_portal_fields` rows on that `visit_date` (YYYY-MM-DD or MM/DD/YYYY), permit compared as digits without zeros, ticket without leading zeros; exactly one visit and one permit, and the manifest covers no other visit (a typed dump date can be the OTHER visit's service date: ticket 815951, visits 1353/1360) |
| the image | a JPEG or PNG in `screenshot` is required (`fn_record_manual_gdo_report` needs it in storage first) |
| the record | uploaded to `rpa-evidence/<visit>/manual-bot-<run>.<ext>`, then `fn_record_manual_gdo_report` with the matched `gdo_id`, so the row is exactly a DERM App manual filing: Manual chip and "Filed by" in the DERM Tracker, "Filed manually, DERM portal confirmed (no tracking number)" in the Field Portal |
| record error (v42) | re-read by run_id BEFORE removing anything: a row for this run means a duplicate request recorded first, or this RPC committed and only its answer was lost, so the image is that row's evidence: 200 `deduped`, nothing removed, no Slack. A failed re-read is 500 `result_lookup_failed_retry` and keeps the image. Only a refusal (23505, 22023) with no row removes the image; any other error keeps it for the retry. Until v41 the branch removed the image first, so a duplicate request deleted the recorded row's evidence and posted a false "already filed". Standing check: `node scripts/checks/rpa_derm_result_manual_race.mjs` (7 scenarios; must fail on the pre-fix body `4deebe7`) |
| filed by | `yan` = yannick@ayache.com, `fred` = fred@ayache.com, `diego` = contact@unclogme.com (Fred, 2026-10-26); anyone else `GDO bot dashboard (<name>)` |
| refusal | 🛑 **200 + a Slack post to #apps-notifications, never a 4xx** ("GDO report not recorded", what was sent, "record it in the DERM App ... do not file it again"). A 4xx makes the bot retry for ~11 hours and then tell people to check whether the county has it, which is the wrong question. If the post fails, 500, so the bot keeps retrying and the refusal cannot go silent |

`manual-bot-` keeps the run_id under `manual-%` (is_manual, the dry-run guard's exemption, the
`actor_markers_agree` CHECK) and tells a bot-dashboard filing apart from a DERM App one (`manual-<uuid>`).

**Visit 8888 (the first case) was recorded by hand on 2026-10-26 at 18:00 ET**, exactly as the endpoint would have:
the county confirmation email from the bot's `/evidence-export` (DERM message
`<7471d93e-b51c-4119-9e41-abf9cf3176f3@s0146923.miamidade.gov>`) at `rpa-evidence/8888/manual-bot-882d2b19-aa06-4db8-9d43-136d1451bebb.jpg`,
submission 2027, filed by yannick@ayache.com, attempted 16:00:58 UTC. The bot's hourly retry of the identifier-less
seed now gets 200 `deduped`, which clears it (seen in the bot log at 22:57 UTC). Checked in the DERM Tracker visit
page and the Field Portal report.

**2026-10-27: four more, recorded the same way.** Yan filed the other 2025 visits of 041-MB / GDO-14965 by hand
between 12:11 and 12:25 ET; `rpa-derm-result` refused all four (`manual_entry_missing_permit_manifest_or_date`, Slack
posts in #apps-notifications), as designed until the bot sends the identifiers. Each run was matched to its visit
by the cleaning date on its county email in `/evidence-export` (one completed 041-MB visit on each date):

| bot run | cleaning date | visit | manifest | submission | email received (ET) |
|---|---|---|---|---|---|
| `d079deb3-002b-4394-add1-3ddc2b59987d` | 2025-03-25 | 8889 | 487956 | 2030 | 12:24:48 |
| `ec99167a-5ad5-4d16-960a-2ef065d10eac` | 2025-05-29 | 8890 | 494043 | 2031 | 12:24:04 |
| `ed513327-a556-4d56-9b92-0bbeccec2182` | 2025-07-28 | 8891 | 499208 | 2032 | 12:18:49 |
| `521c5130-72c0-496b-a3f4-a5a0763413df` | 2025-10-16 | 8892 | 805660 | 2033 | 12:11:33 |

Each through `fn_record_manual_gdo_report` with run_id `manual-bot-<run>`, image at
`rpa-evidence/<visit>/manual-bot-<run>.jpg`, filed by yannick@ayache.com, attempted = the email's received time.
Checked in the DERM Tracker (SUCCESS · Manual, evidence 1000x768) and the Field Portal (REPORTED, Filed manually).
The export holds exactly five visit-less entries and all five are recorded. Still unfiled in our records for 041-MB /
GDO-14965: 1291 (2026-01-18), 1529 (2026-03-24), 4740 (2026-05-24), all before the 2026-07-21 launch cutoff.

**Still needed on the bot side (ours since the 2026-10-08 handoff, not done; pushes wait for the September LWT
filing, section 9). Brief, corrected 2026-10-27 after reading every bot doc:
`docs/handoffs/2026-10-26_gdo_bot_manual_entry_for_jon.md`.**
1. put `gdo_number`, `ticket_number`, `service_date` (ISO) and `dump_date` inside `manual_entry`
   (`build_result_payload`);
2. for a MANUAL entry only, when the final POST fails, replace the cached seed with the final payload (it carries the
   county email). Queue items keep the seed on purpose (PLAN_INLINE_EVIDENCE: the late-evidence drain fills their
   image), but the drain requires a visit_id, so it never attaches a manual entry's email;
3. update R7, DOMAIN_RULES and the "manual entries never post" docs and comments. Until then every manual entry
   lands in the refusal path, with a Slack post, and is recorded by a person as above.

## 5. Evidence

- The county emails the permit's portal address. The email carries no manifest and no confirmation number, so it
  matches a ledger row by (permit as an integer, date pumped).
- **Transport:** IMAP with an app password on the fog@ group member. The code falls back to Gmail OAuth when no app
  password is set, but Railway has no `GMAIL_*` variables, so in production there is no fallback: a failing app
  password aborts the harvest with an alert.
- **The evidence image is redrawn** from the parsed email, not screenshotted.
- With both evidence switches on (section 2): a caught email becomes the image at once; a missed one is attached
  later by the hourly drain.

## 6. Slack and the dashboard

- **Daily digest**, 08:00 New York, covering yesterday. It lists one line per ledger row, with no grouping and no
  acks.
  - **filed** = SUCCESS;
  - **failed** = timeout, unhandled or crash;
  - **needs review** = every other live error, VALIDATION included.
  - **"in queue"** is counted with `rpa-derm-queue?mode=peek` (since 2026-10-20), which leases nothing. Before that it
    was a live fetch that leased every waiting visit for 20 h, which would have delayed a visit waiting at 08:00 by
    about 20 h (never observed).
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
  - the September report: planned filing 2026-10-20 (`public.lwt_filings` had no September row on 10-20 at 13:50 ET).
  - `87b24a2` ("Monthly C") was live from 2026-10-18 21:27 ET despite its "push held until 2026-10-20" note, so the
    10-19 close ran on it, not on `7fb15e0` as the bot's HANDOFF.md says (who pushed it is not known), until
    `7681388` replaced it at 2026-10-20 12:54 ET.

## 8. Reading a "No readable GDO permit in ''" warning

The full history of the 10-19 / 10-20 work (inspection, fixes, full check, post-check, open items):
[`docs/audits/2026-10-20_gdo_bot_full_check_and_no_permit_hold.md`](../audits/2026-10-20_gdo_bot_full_check_and_no_permit_hold.md).

**What it means:** our queue sent a row whose `gdo_number` was **null**, which happens when the client has no ACTIVE
`GDO-<digits>` permit. Before `7681388` preflight let the null through, the split left no permit, and the guard
printed the empty quotes. **Since 2026-10-20 the same case reads "No GDO permit on this visit"**, and since
`2026-10-20_1345` our queue no longer serves such a row at all, so the warning should not appear again: the visit is
held as `no_permit` and Fred's health email names it instead, the day it appears (then at 3 days, then weekly). Either way:
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
  - 2026-08-17: Yan asked the GDO Slack bot about 322 NW 24th St and it returned **GDO-14738** (FLIP A BURGER LLC DBA
    SKINNY LOUIE, active through 2026-12-31, every 90 days) with the county's PDF. The bot gets permits from the
    Miami-Dade DERM documents search and parses the county's own PDF.
  - 2026-09-18: Fred found it again. Fred: "it needs Diego or Yan approval first". Nobody approved or rejected it in
    Slack, and it was never entered (0 rows in `gdos`, no stored PDF).
  - Capas lead nobody followed: SIR FOOD LLC held **GDO-14098** (expired 2024-12-31) at 21000 W Dixie Hwy, Capas
    Aventura's address, and SIR FOOD paid a Capas invoice. ⚠ Viktor's GDO Compliance Sentinel names GDO-09083 for
    315-CAP ("pending Fred's insert"); that permit belongs to PLAYCHEF K LLC / Delicious Bites and was ruled out on
    09-03. Never enter it for Capas.
- **Reach (2026-10-20):** 3 completed visits after the launch cutoff have no permit: 7849, 7859 and 7860 (refused
  10-20 11:29 ET). 249-LOU is the only client with an open Line Item 27 job (job 1856, Jobber #99901073) and no ACTIVE
  permit, so its 6 scheduled visits (7861 on 11-17, 7862, 7863, 7864, 7982, 8704 on 2027-04-16) would each join them.
  Capas's line 27 is on its invoice #3067 only, not its job, so its future visits are not GDO-reporting.
  Line 27 has been billed $35 on #3067 (paid), #3186 (past due) and #3391 (paid) for reports never filed.
- **Fixed by `2026-10-20_1345` (Fred: "design the plan and execute it"; Jonathan's 2026-09-03 ask):** the queue never
  serves a no-permit row, the held view names it `no_permit`, and `log_rpa_derm_health` emails one `gdo_no_permit` item
  per visit plus one item per client whose open job bills line 27 with no permit (249-LOU today). Gate 3 is exact-pair,
  so **entering the permit releases the held visits on the first bot pass after any 20h cooldown or lease, with no
  requeue**, even when late: 7859's DERM deadline (the 15th of the next month) passed on 10-15, 7860's is 11-15. It
  releases every visit after the launch cutoff not yet filed for that permit (gate 1 is per permit), including any
  filed under the client's other permit. Before this, adding a permit did not release anything: the two Skinny
  Louie visits flagged on 09-03 (308-LOU 7852, 247-LOU 7872) filed on 09-04 09:36 only because an unrelated manifest
  write moved the anchor.
- **Follow-up `2026-10-20_1405`** (from an independent post-check): the retry loop counts a NULL-permit failure on a
  visit that has a permit again; `gdo_filed_permit_changed` names a visit filed under a permit that has since left
  the client's ACTIVE permits while it has another (the queue files that one too); `rpa-derm-queue` v34 refuses any
  query key but one `mode`; `rpa-derm-result` v32 logs an ownership-check error as such.
- **Still people's calls:** approve GDO-14738 (Diego or Yan; Fred enters it in the Client App with the county PDF,
  client 499, property 973); Capas (is GDO-14098 / SIR FOOD LLC its permit, or none?); the $105 billed for unfiled
  reports; correcting Viktor's sentinel.

## 9. Risks the inspection found in the bot

Each was checked against the code. **1 to 4 are FIXED in `7681388` (2026-10-20, Fred: "go ahead with 4")**, with
`tests/test_queue_nulls_and_digest.py` (11 mutants, all red on revert) and our `rpa-derm-queue` v32 (`?mode=peek`,
`da11756`). The manual digest (`send_digest_now`) had the same lease and is fixed too. 7 is fixed except the HANDOFF
line. 5 and 6 are open. ⚠ Not yet seen on real traffic: peek against a non-empty queue (the first 08:00 digest
after 10-20) and the first result carrying `gdo_id`.

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
   - `MIGRATE_ANY_EMAIL` "deployed OFF" (HANDOFF; it is ON). Still open. `7681388` was pushed at 12:49 ET on 10-20
     (Fred: "go ahead with 4") before the LWT push hold came to light; further bot-repo pushes (each one is a deploy
     and a restart of Diego's `/monthly` page) wait until the September LWT report is filed.
   - Before `7681388` no test fed a null permit or checked the DST sleep (`tests/test_digest_scheduler.py` exists since
     2026-09-03).
