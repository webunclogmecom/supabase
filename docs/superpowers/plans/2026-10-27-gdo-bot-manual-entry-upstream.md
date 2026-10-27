# GDO bot: hand filings recorded upstream. Implementation plan (2026-10-27, reviewed)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.
> The bot repo's own rules bind every bot step: `CLAUDE.md`, `docs/WORKING_AGREEMENTS.md`, `docs/PROJECT_INSTRUCTIONS.md`.
> Code, comments, docs and commit messages in English.

**Goal:** a report filed by hand from the bot dashboard ("Add a report by hand") is recorded in our apps as a manual
filing without a person, whenever the bot holds the evidence for it.

**Architecture:** two halves. **Our side** (`rpa-derm-result`) already accepts `manual_entry` (live since 2026-10-26)
and gets one race fix (Part A, can ship now). **The bot** (`webunclogmecom/unclogme-gdo-report-bot`, ours since the
2026-10-08 handoff) sends the identifiers our side needs and keeps the payload that carries the county email when the
send fails (Part B; a push is a deploy and waits on the gate in B9).

**Tech stack:** Python 3.12 (FastAPI, Playwright, SQLite) on Railway; plain-script tests run by `run_tests.py`, judged by
exit code, in the runtime Docker image plus node. Our side: Supabase edge function (Deno, TypeScript).

**Review record.** Drafted from five code readers, then attacked by four reviewers (2026-10-27): one built Part B in a
throwaway copy (41/41 suites green before, 42/42 after, Python 3.13 + node; Docker not run), one checked the logic,
one checked our API with an offline harness, one checked deploy and docs. Their prototypes are kept next to this file,
in `2026-10-27-gdo-bot-manual-entry-upstream/` (`bot/` and `edge-harness/`). The `bot/` prototype still sends
`dump_date` and runs `normalize_permit`; this plan drops both (B2).

---

## 1. Root cause (measured)

| fact | where |
|---|---|
| Commit `9114249` (2026-08-10) took the live SUCCESS branch off `_post_and_cache`: it writes a crash-insurance seed straight into the retry cache and sends the final payload with `api_client.post_result` | `git show 9114249 -- reporter.py`; today `reporter.py:963` and `:1060`. (`58276d2`, 2026-08-28, only added `reason=SEED_REASON` to the seed line) |
| The flush at the start of every run re-sends cached payloads raw | `reporter.py:447` |
| Five weeks later, commit `b730dff` (2026-09-17, its message is about the 830197 rule) added "Add a report by hand", a guard in `_post_and_cache`, and a docstring saying "the one door all ten call sites go through". `_post_and_cache` has 9 call sites; the success branch was already outside it, so the docstring was false the day it was written | `reporter.py:383-397` |
| A hand filing runs through the same loop, so its SUCCESS left through the seed and the final POST | `reporter.py:503-511`, `925-1063` |
| No test ran a hand filing through the success branch: the dashboard tests fake `run_reporter`; the one real manual run in the suite is a refused entry | `tests/test_dashboard.py:678-853`, `tests/test_batch1_paths_and_context.py:86-130` |
| `manual_entry` was designed as local provenance `{created_by, why}`: no permit, manifest or date | `reporter.py:336-346` |
| First real use 2026-10-26 (visit 8888), four more 2026-10-27 (8889-8892); all reached our API, all were recorded by a person | `docs/reference/gdo-report-bot.md` section 10 |

**Responsibility.** The defect is in Jon's build from before the handoff, and his tests never ran that path (his brief
lists it as known debt). Since 2026-10-08 the bot is ours: HANDOFF.md section 10 says changes and fixes after that date
are a separate agreement, so the fix is ours. Recording hand filings in our apps is Fred's decision of 2026-10-26, a new
requirement: our API half is live, the bot half is this plan.

## 2. What this fix can and cannot do

After the fix, a hand filing is recorded automatically only when all of these hold at the moment the bot sends it:

| condition | if it fails |
|---|---|
| the county confirmation email arrived inside the bot's 120 s wait (the payload then carries its image) | no image: refused `manual_entry_no_image` |
| the visit is completed and its DERM manifest is filed and linked in the DERM Tracker | refused `manual_entry_no_matching_visit` (or 22023) |
| the client has an ACTIVE `GDO-<digits>` permit and the visit is a GDO-reporting visit | refused |
| the typed manifest and service date match that visit (exact date) | refused |
| the process did not die during the email wait (then only the seed is sent, with no image) | refused `manual_entry_no_image` |

Every refusal is an HTTP 200 plus a Slack post in #apps-notifications ("GDO report not recorded") naming the permit,
manifest, service date, who filed it and the bot run, plus the visit once matched. The bot treats the 200 as delivered
and drops its copy, so fixing our data later re-sends nothing: a person records it from the bot's `/evidence-export`,
as for 8888-8892. The late-evidence drain cannot help (it needs a `visit_id`, `db.py:1385-1388`; our evidence endpoint
keys on `(visit_id, run_id)`).

How often the email misses (read-only, `derm_portal_submissions`): October 17 of 17 caught inline; since inline email
evidence went live (2026-08-24) 31 of 35. So expect about 1 hand filing in 9 to still need a person (D1).

Known interaction (G8 below): if a hand filing is refused and its visit is after the 2026-07-21 launch cutoff, the
queue still serves it, the bot's "already filed" check matches its own ledger, and the re-assert path posts a normal
bot SUCCESS for the queue visit under the hand filing's run id, with no image. Our side then shows it as an automated
filing, and a person following the Slack refusal will be told it is already filed. Rare (hand filings so far are
pre-cutoff visits); not changed here.

## 3. Decisions for Fred

| # | question | recommended | why |
|---|---|---|---|
| D1 | When the county email misses the 120 s wait, should a hand filing send the Preview screenshot instead of no image? | **No.** Keep ruling B (2026-08-19: the evidence is the county email). The Slack refusal and a person cover about 1 in 9 | The Preview is pre-submission evidence and ruling B forbids substituting it |
| D2 | Fix the race in our API now (Part A)? | **Yes** | A duplicate request can delete the image of the record just made and post a false "already filed" alert; also covers a lost RPC answer. A few lines, no bot push |
| D3 | Should the bot dashboard show what our API answered? | **No** | Slack names every refusal; a structured return from `post_result` touches 3 call sites and 6 tests |
| D4 | "Filed by" on our record: the person who TYPED the entry, or the one who pressed **File it**? | **Who pressed File it** | It is the person who filed with the county. Today `_manual_by` is the entry's author (`server.py:1298`) and our API turns it into `filed_by_email` |
| D5 | Push gate: "September close SENT to DERM and no close in progress", or "September RECORDED as filed" (after DERM approves)? | **Sent, and no close in progress** | The written hold (our reference section 9, bot HANDOFF) says "filed"; "recorded" waits on DERM's approval and can take weeks (August: sent 09-22, recorded 10-13) |

Add a `decisions-to-build.md` row for each answer in the same turn (root CLAUDE.md section 7).

## 4. Part A: our side (`rpa-derm-result`), ships without the bot

### Task A0: claim
- [ ] Append to `WORKING-NOW.md` (append only, commit at once): `CLAIMING: edge fn rpa-derm-result,
  docs/reference/gdo-report-bot.md, postman/README.md`. Read the other sessions' claims first.

### Task A1: the race fix

**File:** `supabase/functions/rpa-derm-result/index.ts:296-298` (start of the `if (rpcErr)` branch in `recordManualEntry`).

**Defect (reproduced offline):** two requests with the same bot run can both pass the dedupe at `:189-203`, both
upload to `<visit>/manual-bot-<run>.<ext>` (`upsert: true`); the first RPC records, the second gets `23505`, and `:298`
removes the image the first row points at, then posts "already has a filing on record ... county now has it twice".
Reachable when the bot's 30 s client timeout fires during a stall and it resends (`api_client.py:105`, `:152-158`).
The same branch also deleted the evidence of a row whose RPC committed but whose answer was lost.

- [ ] Replace `:296-298` with the following, and keep the existing `23505` / `22023` / 500 branches after it:

```ts
  if (rpcErr) {
    // Re-read BEFORE removing anything. The image at `path` is a recorded row's evidence when a concurrent duplicate
    // of THIS run recorded first (the bot resends after its 30 s client timeout while this request still runs), or when
    // this RPC committed and only its answer was lost. Same read as the dedupe above.
    const { data: won, error: wonErr } = await sb
      .from('derm_portal_submissions')
      .select('id, visit_id, gdo_id, screenshot_path')
      .eq('run_id', runId)
      .limit(1)
    if (wonErr) {
      // Cannot tell whether a row points at the image: keep it. The bot retries; its retry dedupes or records.
      console.error('manual entry re-read after a record error failed:', wonErr.message, '| record error:', rpcErr.message)
      return json({ error: 'result_lookup_failed_retry' }, 500)
    }
    if (won && won.length > 0) {
      return json({ recorded: true, deduped: true, manual_entry: true, id: won[0].id, visit_id: won[0].visit_id,
        gdo_id: won[0].gdo_id, run_id: runId, screenshot_stored: won[0].screenshot_path !== null }, 200)
    }
    if (rpcErr.code === '23505' || rpcErr.code === '22023') {
      // A refusal, and no row carries this run_id (fn_record_manual_gdo_report pins every manual path to
      // <visit>/<run_id>.<ext>), so nothing references `path`: remove it so no orphan image stays. Any other error
      // keeps it: the bot retries and the retry rewrites the same path.
      await sb.storage.from('rpa-evidence').remove([path])
    }
    if (rpcErr.code === '23505') {   // ...existing code from here, unchanged
```

### Task A2: a standing check that runs the new code (offline)
- [ ] Add `scripts/checks/rpa_derm_result_manual_race.mjs`, adapted from `edge-harness/` beside this plan: esbuild
  strips the imports, stubs replace `createClient`, `Deno.serve` and `fetch`, and it runs the function body through
  seven scenarios: same-run race won, another run already filed the permit, re-read error, lost RPC answer, transient
  RPC error, 22023, happy path. It must PASS on the working tree and FAIL on the pre-fix body
  (`git show HEAD:supabase/functions/rpa-derm-result/index.ts`) for the race-won, lost-answer and re-read-error
  scenarios. Run it with `npx --no-install esbuild@0.24.0` (no deno on this machine).

### Task A3: deploy and read back
- [ ] Deploy `rpa-derm-result` (the `[functions.rpa-derm-result] verify_jwt = false` line in `config.toml` stays as is).
- [ ] `node scripts/probes/edge_deployed_body.js rpa-derm-result "recordManualEntry" "wonErr" "!Same run_id = same object"`:
  the first needle is the control, the second proves the new body, the third proves the old comment is gone; the
  printed version must be above 41.

### Task A4: smoke against Prod (no write, no Slack)
- [ ] Read the bot key into a shell variable without printing it: `KEY=$(grep '^RPA_BOT_KEY=' Supabase/.env | cut -d= -f2-)`
  (rotated 2026-10-22 and updated there; a 401 means it is stale, then read Railway `RPA_BOT_KEY` the same way).
- [ ] Replay the stored run of visit 8889 (bot run `d079deb3-002b-4394-add1-3ddc2b59987d`) with a well-formed manual
  body: expect `200 {recorded:true, deduped:true, id:2030}`. The dedupe runs before matching, upload and Slack, so this
  proves every 400 gate (keys, shape, ids, run id, date) and nothing else.
- [ ] Controls: an extra `manual_entry.client_name` key answers `400 unknown_field_manual_entry.client_name`; a fresh run
  id with `dry_run:true` answers `200 {recorded:false, reason:"only_a_successful_filing_is_recorded"}`.

### Task A5: record and release
- [ ] Supabase commit (explicit paths, `Co-Authored-By` footer), push.
- [ ] `docs/reference/gdo-report-bot.md`: the version in sections 4 (line ~148) and 10 (line ~168) set to the version A3
  printed; the race fix in section 10. `postman/README.md` section 4 (rpa-derm-result): a `manual_entry` subsection (the
  six keys, ISO date, the 201 / 200 deduped / 200 refused / 500 retry answers); the pre-commit hook regenerates the
  Postman description.
- [ ] `decisions-to-build.md`: Part A built. Release the claim in `WORKING-NOW.md`.

## 5. Part B: the bot. Build now, push behind the gate in B9

### Task B0: claim, workspace, green baseline
- [ ] Append a claim to `WORKING-NOW.md`: `CLAIMING: bot repo unclogme-gdo-report-bot (push = Railway deploy), Railway
  service UnclogMe_Reporter_Bot, our docs gdo-report-bot.md / decisions-to-build.md`. Commit at once.
- [ ] Clone OUTSIDE the workspace root (the root repo's allowlist and `git clean` rules are written for four known
  nested repos): `git clone https://github.com/webunclogmecom/unclogme-gdo-report-bot.git C:/Users/FRED/Desktop/Virtrify/Yannick/unclogme-gdo-report-bot`.
  `git log -1` must be `7681388`; if Jon or anyone pushed since, re-read this plan against it.
- [ ] Commit identity, as for `7681388`: `git -c user.name=webunclogmecom -c user.email=web@unclogme.com commit ...`,
  message ending with `Co-Authored-By: <model the session runs on> <noreply@anthropic.com>`.
- [ ] Railway CLI: `railway link` in the clone, project `unclogme-gdo-report-bot`, environment production, service
  `UnclogMe_Reporter_Bot`. Fred's dashboard key: from `railway variables --json`, entry `fred` of `RUN_KEYS`, read into a
  variable, never printed.
- [ ] Start Docker Desktop. Baseline on the UNCHANGED clone (RUNBOOK section 1):
  `docker build --target runtime -t unclogme-rpa:runtime .`, `docker build -f Dockerfile.test -t unclogme-rpa:test .`,
  `docker run --rm unclogme-rpa:test`: exit 0 over 41 suites. A red baseline stops the plan. Never push `:test` (its
  fixtures carry real client data).

### Task B1: the failing tests first

**Create:** `tests/test_manual_entry_upstream.py`. Start from `bot/test_manual_entry_upstream.py` beside this plan (built
and run by the reviewer). Its harness, which must be kept:
- `DATA_DIR = tempfile.mkdtemp()` and `SHADOW_MODE=false` set before importing `config` / `reporter`; playwright and httpx
  stubbed when missing, as in `test_queue_nulls_and_digest`.
- Fake portal copied from `tests/test_faseM.py` (`Loc`, `Page`, `Ctx`; its suite runs at import, so it cannot be
  imported), with `Browser` and `PW` at module level, `Page(config.PRIMARY_EMAIL, mode='full')`, and
  `reporter.sync_playwright = lambda: PW()`.
- Live evidence flags forced: `INLINE_EMAIL_EVIDENCE=True`, `LATE_EVIDENCE_LIVE=True`, `mailbox_ready=lambda: True`,
  `EMAIL_WAIT_SECONDS=0`, `EMAIL_POLL_SECONDS=0`. `email_waiter.wait_for_confirmation` faked with the parsed fixture
  `tests/fixtures/derm_confirmation_14965.eml` (hit) or `(None, None, None)` (miss); `email_harvester._build_client`,
  `_save_eml` and the Slack sender stubbed; `api_client.post_result` replaced by a recorder (scripted bool, JSON copy of
  each payload, optional `on_post` hook).
- `reset()` empties `audit_logs`, `pending_api_results` and `email_evidence` before each scenario (except T4, which
  follows T2): without it the second live run of the same pair takes the re-assert path and the test measures the wrong
  branch.

The hand item is what `server._manual_payload` builds, with a date the bot accepts and our API refuses raw:

```python
MANUAL = {"gdo_number": "14965", "ticket_number": "487956", "service_date": "2025-3-25",
          "client_name": "", "dump_ticket_date": "", "dry_run": False,
          "_manual": True, "_manual_by": "yan"}
```

(`validate_manual_entry` accepts `2025-3-25` and types 03/25/2025 into the county form; our `isoDate` returns null for
it, so forwarding the raw text would be refused `manual_entry_bad_service_date`.)

| test | drives | must hold |
|---|---|---|
| T1 | hand filing, email caught, POST True | one POST; `manual_entry == {created_by:"yan", why, gdo_number:"14965", ticket_number:"487956", service_date:"2025-03-25"}` exactly; a `screenshot` and no `screenshot_missing_reason`; `portal_confirmation == PORTAL_CONF_EMAIL`; `visit_id`/`manifest_id` null; no `gdo_id`; nothing pending |
| T2 | hand filing, email caught, POST False; `on_post` ages the seed (`created_at` one hour back, `retry_count=3`) | one row for the run; its payload is the FINAL one (same screenshot as posted, `PORTAL_CONF_EMAIL`, no missing reason, identifiers); same row `id` as the seed; `created_at` and `retry_count` kept. Control: before the replace the seed had no image and `confirmation_email_wait_interrupted` |
| T3 | QUEUE item (visit 6036, gdo_id 69), email caught, POST False | the pending row is still the SEED (no image, `confirmation_email_wait_interrupted`, no `manual_entry`) |
| T4 | the next run after T2 (`run_reporter(items=[])`) | the flush POSTs the cached final payload once, verbatim (image and identifiers), and deletes the row on True |
| T5 | hand filing, `dry_run=True` | control: the ledger shows `DRY_RUN_COMPLETE`; zero POSTs; zero pending rows |
| T6 | contract, on T1's payload | top-level keys within `ALLOWED_FIELDS`; `manual_entry` keys within `MANUAL_ENTRY_FIELDS`; ISO date regex; run id `^[A-Za-z0-9_.-]{1,86}$`; image magic JPEG/PNG. The two lists are copied from `rpa-derm-result/index.ts:50-56` and `:93` (cite them; point at `docs/API_CONTRACT.md` once B8 adds the section) |
| T7 | `build_result_payload` directly | `2025-3-25` and `03/25/2025` become `service_date "2025-03-25"`; garbage, `""` and `None` leave it absent; never raises; `manual_entry` always a dict with the four other keys; a queue item has no `manual_entry` |
| T8 | hand filing, email missed, POST True | one POST, no screenshot, `confirmation_email_not_received`, identifiers present |
| T9 | a SUCCESS ledger row for (`14965`, `487956`) already present, then the hand item live | zero POSTs, zero rows (the re-assert path must stay behind the guard) |
| T10 | the fake waiter raises `KeyboardInterrupt` (caught by the test) | the cached row is the seed WITH the identifiers, no screenshot, `confirmation_email_wait_interrupted` |
| T11 | `db.cache_failed_result` raises when `replace=True`; POST False | the run completes; the newest ledger row is still SUCCESS (no `ERROR_UNHANDLED`); the seed stays |
| T12 | in `tests/test_dashboard.py`, a new TEST: an entry added under one key and filed under another, `run_reporter` faked to capture its items | the captured item's `_manual_by` is the key that pressed File it (D4). Keep it free of node so `test_js_checks_required` is unaffected |

- [ ] Rebuild `:test` (the image copies `tests/`) and run the new suite on the UNCHANGED code:
  `docker run --rm unclogme-rpa:test python tests/test_manual_entry_upstream.py`. **Expected on 7681388:** red T1, T2,
  T4, T6, T7, T8, T10 (T1's "one POST" check already passes: the old code does POST, carrying `{created_by, why}`;
  that is the defect seen in behaviour); green T3, T5, T9, T11 (T11 is vacuous before B3). T12 red.

### Task B2: the identifiers

**Modify:** `reporter.py`: add `_manual_iso` after `parse_portal_date` (`:274-293`), and replace the manual block
`:336-346` in `build_result_payload`.

```python
def _manual_iso(raw) -> str | None:
    """A hand-typed date as YYYY-MM-DD, or None. parse_portal_date accepts '2025-3-25'; rpa-derm-result reads only
    zero-padded ISO (or M/D/YYYY), so the date is re-printed, never forwarded as typed. Never raises."""
    text = str(raw or "").strip()
    mdy = parse_portal_date(text) if text else None
    return datetime.strptime(mdy, "%m/%d/%Y").strftime("%Y-%m-%d") if mdy else None
```

```python
    # A hand-entered filing (R7, delivered on the Tracker side 2026-10-26): the identifiers rpa-derm-result needs to
    # record it as a manual filing. Only keys that endpoint accepts; any other is a 400 that the cache would retry for
    # 72 h. Built on EVERY manual payload: its presence is also what _post_and_cache refuses on.
    if item.get("_manual"):
        entry = {
            "created_by": str(item.get("_manual_by") or "unknown"),
            "why": "entered by hand on the bot dashboard",
            "gdo_number": str(item.get("gdo_number") or "").strip(),
            "ticket_number": str(item.get("ticket_number") or "").strip(),
        }
        service_date = _manual_iso(item.get("service_date"))
        if service_date:
            entry["service_date"] = service_date
        payload["manual_entry"] = entry
```

Not sent, on purpose: `dump_date` (our API never reads it, and an odd value would log `parse_portal_date`'s "refusing to
type it into the portal" warning on every build); `normalize_permit` (the server already normalizes on add,
`server.py:1255`, and our `permitKey` strips `GDO-` and zeros itself).

- [ ] Expected: T1, T6, T7, T8, T10 green; T2, T4 still red.

### Task B3: keep the final payload for a hand filing

**Modify:** `db.py:406-434` (`cache_failed_result`) and `reporter.py:1060-1063`.

```python
def cache_failed_result(run_id: str, payload: dict, reason: str = "POST failed", replace: bool = False):
    ...docstring, add: "replace=True has ONE caller, the final payload of a hand filing after a failed POST: it
    overwrites that run's seed in place (id, created_at and retry_count kept). Everything else stays first-write-wins."
        if replace:
            c.execute('''INSERT INTO pending_api_results (run_id, payload) VALUES (?, ?)
                         ON CONFLICT(run_id) DO UPDATE SET payload = excluded.payload''',
                      (run_id, json.dumps(payload)))
        else:
            c.execute('''INSERT OR IGNORE INTO pending_api_results (run_id, payload) VALUES (?, ?)''',
                      (run_id, json.dumps(payload)))
```

(`ON CONFLICT ... DO UPDATE` keeps the row; `INSERT OR REPLACE` would delete and re-insert it. Production already runs
`ON CONFLICT DO UPDATE` in `db.set_harvest_state`, `db.py:1431-1438`.)

```python
                    if api_client.post_result(payload):
                        db.delete_pending_by_run_id(run_id)
                    elif item.get('_manual'):
                        # PLAN_INLINE_EVIDENCE 5a keeps the SEED on purpose: the late-evidence drain attaches a queue
                        # item's email later. A hand filing has no visit_id, so the drain never sees it
                        # (db.get_unposted_email_evidence) and this payload is the only one that carries its county
                        # email. Never let this write cost the item: the SUCCESS ledger row above stands either way.
                        try:
                            db.cache_failed_result(run_id, payload, replace=True,
                                                   reason="manual entry: final payload kept after a failed POST")
                            log.warning(f"POST failed — hand filing: final payload cached for retry [run_id={run_id}]")
                        except Exception as cache_exc:
                            log.warning(f"POST failed — hand filing: final payload NOT cached ({cache_exc}); "
                                        f"the seed stays, its county email needs a person [run_id={run_id}]")
                    else:
                        log.warning(f"POST failed — seeded payload stays cached for retry [run_id={run_id}]")
```

`if api_client.post_result(payload):` and `db.delete_pending_by_run_id(run_id)` stay byte-identical: `test_batch4` and
`test_email_waiter` TEST 7 pin them by text in a 13000-character window from the Submitted wait (the POST sits at
+9125, unchanged). The warning lines are not pinned.

- [ ] Expected: the whole new suite green.

### Task B4: who filed, and the words

- [ ] D4: in the manual run endpoint, right after `who = _operator_name(operator)` (`server.py:1488`), set
  `payload["_manual_by"] = who`. `_manual_by` has no other reader (`reporter.py:344` only). T12 green.
- [ ] `reporter.py:383-390`, the `_post_and_cache` docstring: 9 call sites; "every manual result that is not a fresh
  portal SUCCESS stays local (validation, dry run, timeout, login, email mismatch, unhandled error, re-assert); a hand
  filing's SUCCESS leaves only through the success branch (seed, final POST, flush) with its identifiers". The guard
  itself does NOT change (T9).
- [ ] `reporter.py:393`, the log text "Manual entry -- not posting upstream (no visit to settle)": say what is now true
  ("only a fresh portal SUCCESS of a hand filing goes upstream").
- [ ] `reporter.py:467-472` and the `server.py:1282-1289` `_manual_payload` docstring.

### Task B5: runtime image, then mutations

- [ ] Rebuild both images; `docker run --rm unclogme-rpa:test`: exit 0, 42 suites. A killed or timed-out run proves
  nothing: re-run it.
- [ ] Mutations, each on a COPIED tree, through `run_tests.run_suite` with a per-mutant limit (a timeout counts as
  killed). `bot/mutate.py` beside this plan is the reviewer's harness for M1-M8. Each must turn the suite red:

| mutant | killed by |
|---|---|
| M1 old `manual_entry` (`{created_by, why}`) | T1, T6, T7, T8, T10 |
| M2 forward the raw `service_date` | T1, T7 |
| M3 drop the manual replace | T2, T4 |
| M4 replace for queue items too (no `_manual` condition) | T3 |
| M5 delete the guard in `_post_and_cache` | T5, T9, `test_batch1` TEST 5 |
| M6 `_manual_iso` raises on garbage | T7 |
| M7 add `client_name` to `manual_entry` | T1, T6 |
| M8 `INSERT OR REPLACE` for the replace | T2 (row id) |
| M9 guard skips SUCCESS (`... and payload.get('status') != 'SUCCESS'`) | T9 |
| M10 the replace without its try/except | T11 |
| M11 `_manual_by` left as the entry's author | T12 |

- [ ] Name the killed mutants in the suite docstring and the commit message.

### Task B6: prove the new payload against OUR live API before any push

- [ ] Inside the test image, build T1's payload with the new `build_result_payload` for the recorded 8889 entry (bot run
  `d079deb3-002b-4394-add1-3ddc2b59987d`, image = its county email from `/evidence-export`) and POST it to
  `rpa-derm-result` with the bot key (A4): expect `200 {recorded:true, deduped:true, id:2030}`, i.e. every 400 gate
  passes for the new shape.
- [ ] Matching uses what the operator TYPED, which we have only for 8888 (`Manual entry #1 written by yan: permit
  '14965' manifest '808783' date '2025-11-16'`). Read the four 2026-10-27 "Manual entry #N written by ..." lines from the
  bot's Railway log (read only) and re-run the read-only matching rehearsal (`v_derm_portal_fields`, `visit_date`,
  `permitKey`, `ticketKey`, one visit, one permit, one-visit manifest) with those exact strings. Each must resolve to the
  visit recorded by hand. A mismatch here would be a 200 refusal after the push, not a 400.

### Task B7: the auditor loop

- [ ] Brief an agent with `.claude/agents/auditor.md` on the uncommitted diff in the work clone. Tell it the runtime
  image plus node replaces the venv (there is none in the clone; the host's Python packages differ from the pins), and
  ask for its report in English (its format says Spanish because the operator read it; the operator is now Fred).
- [ ] Reproduce each finding, apply the ones that survive, re-run B5. Name rejected findings with the reason.

### Task B8: the bot's docs, in the same commit

Write `docs/TASK_MANUAL_ENTRY_UPSTREAM.md` from THIS plan as built, in the TASK format (context, what changes, tests,
docs), with a "Delivered <date>" section listing what was deliberately not done (D1, D3, `dump_date`, G1-G8). Not from
the 2026-10-26 handoff draft, which disagrees with this plan in four places (mark that draft superseded, Part C).

| doc | change |
|---|---|
| `docs/REQUIREMENTS_TRACKER_SSO.md` R7 (~104-108) | DELIVERED 2026-10-26 on the Tracker side; shipped shape (the five keys sent, ISO date, the 201 / 200 deduped / 200 refused / 500 retry answers); "never POST" was already untrue at `b730dff` |
| `docs/DOMAIN_RULES.md`, "GDO filings" (~313) | Fred's 2026-10-26 decision, with who and when (the file's rule: never edit without naming who changed it) |
| `docs/PROJECT_GDO_BOT.md` (~105 and roadmap) | the invariant "never POSTed upstream ... the one door" replaced by the rule above; F1 harness debt partly paid |
| `docs/HANDOFF.md` section 4 (~112-113), ~177, ~246 | the dashboard line; "41 suites" becomes 42 (twice) |
| `docs/RUNBOOK.md` section 3 (~109) and section 4 | drop the stale "[Shipping in the Sept 2026 dashboard batch ...]"; add a playbook: a hand filing appears in our apps within minutes; if Slack says "GDO report not recorded", record it in the DERM App; never file it again |
| `docs/TASK_UI_ACKS_AND_MANUAL_GDO.md` | a dated note under "Delivered" (never an edit of the record) |
| `docs/PLAN_INLINE_EVIDENCE.md` step 5a | the manual exception to "INSERT OR IGNORE keeps the seed" |
| `docs/API_CONTRACT.md` | a `manual_entry` section mirroring our Postman README |
| `docs/TASK_MONTHLY_CLOSEOUT.md:85`, `docs/TASK_OPERATOR_REQUESTS.md:316`, `:64` | keep as dated records (they pin the GDO rule this reverses); add a dated note at `:64` pointing the monthly hand-row rule at its own basis, DOMAIN_RULES ~202 |
| NOT touched | DOMAIN_RULES ~202 and REQUIREMENTS_TRACKER_DATA 18: the monthly LWT hand row, a different feature |

- [ ] `commit_msg.txt`: what was wrong (the `9114249` / `b730dff` history), how it was found, what changed, what was not,
  the killed mutants. Read its first line, then `git commit -F commit_msg.txt`. One commit. Do not push yet.

### Task B9: gates before the push

- [ ] **September close** (D5): confirmed SENT to DERM by Diego or Yan, and no monthly close in progress (Diego's
  `/monthly` restarts with the service). If Fred picks "recorded" instead: `select id, period_start, period_end from
  public.lwt_filings where not dry_run order by id desc limit 1` shows a period after 2026-08-24.
- [ ] **Nothing new on main:** `git fetch`; `origin/main` is still our base, otherwise rebase and re-run B5.
- [ ] **Nothing waiting to send:** the dashboard's "N waiting to send" (`/dashboard/bot/data`, Fred's key, read only) is
  0. It is a count only; a non-zero count is read from the Railway log ("Retrying run_id=...") before going on.
- [ ] **People told, each message with Fred's OK first:** Diego (a restart interrupts `/monthly` for about a minute);
  Yan, simply and without technical words (his next hand filing records itself; if Slack says "not recorded", a person
  records it, it is never filed again); Jon, in Spanish (the draft brought up to date: 8889-8892, Part A, and an
  explicit request not to push to main in the window; he still has GitHub write).
- [ ] **Fred: go.**

### Task B10: the push
- [ ] Read the active deployment id and commit hash (Railway API, read only) and write them down for the rollback.
- [ ] Window: right after an hourly poll run finished (the last scheduled-run line in the Railway log; the poll sleeps
  3600 s from the last restart), `GET /health` shows `busy:false`, no hand entry shows "Filing now", not 07:30 to 08:30
  ET (the 08:00 digest).
- [ ] `git push origin main`. This is the deploy.

### Task B11: after the deploy
- [ ] The new deployment is SUCCESS with our commit hash; the startup lines show three schedulers and the ASSET OK lines;
  `/health` is `{"status":"ok","busy":false,"supabase":"connected"}`; `RAILWAY_DEPLOYMENT_DRAINING_SECONDS=120` is still
  set.
- [ ] The next hourly run logs normally; a queue filing still logs `POST /rpa-derm-result OK ... recorded=True`.
- [ ] **End to end, the next real hand filing:** the bot log shows `recorded=True deduped=False` (HTTP 201), no Slack
  refusal, the DERM Tracker visit shows SUCCESS · Manual with the county email and "Filed by" the person who pressed
  File it, the Field Portal shows REPORTED. A refusal for one of the reasons in section 2 is expected behaviour.

### Task B12: rollback (rehearse read-only, never execute it as a rehearsal)
- [ ] Durable: `git revert <sha>` and push (a Railway-only rollback is undone by the next push to main).
- [ ] Stopgap: in Railway, Redeploy the deployment recorded in B10 (the previously ACTIVE one, never just the newest in
  the list). Rehearsal = read the deployment and confirm the token can reach it; do not run it.
- [ ] No schema change, so both are safe; payloads cached by the new code are accepted by the old flush and by our API.

## 6. Part C: our documentation and tracking, same cycle as the push

- [ ] `docs/reference/gdo-report-bot.md`: section 10 (the bot half shipped, its commit and date, what still needs a person:
  section 2 of this plan); section 2 line ~37 (the running deployment); section 6 line ~247 ("never posted to us" is
  false); section 9 item 7 (the push hold is resolved).
- [ ] `docs/decisions-to-build.md`: the 2026-10-26 section 4 row's "bot half not built" closed; the section 2 row moved
  to section 4 with the bot commit; rows for D1-D5 and for G1-G8 (or tasks), each with an owner.
- [x] `docs/handoffs/2026-10-26_gdo_bot_manual_entry_for_jon.md`: marked superseded by this plan (2026-10-27).
- [ ] `Building Apps/DERM Tracker/docs/08-changelog.md` and `Building Apps/Field Portal/docs/08-changelog.md`: hand filings
  from the bot dashboard now appear on their own (Building Apps commit: one line, no footer).
- [ ] Memory `project_gdo_report_bot_inspection_2026_10_19.md` and its MEMORY.md line; commit the memory repo (explicit
  paths).
- [ ] Release the claims in `WORKING-NOW.md`.

## 7. Found while planning, not in this change (each needs an owner)

| # | defect | evidence | risk |
|---|---|---|---|
| G1 | The bot's "already filed" check compares permits as exact text, although its README says permits are compared as integers: a hand entry `9853` and a queue row `09853` are different pairs to it | `db.py:326-339` (`WHERE gdo_permit = ?`) | a second county filing of the same report |
| G2 | An exception after the SUCCESS ledger row writes `ERROR_UNHANDLED` for the same run; the dashboard reads the newest row and says nothing was filed | `reporter.py:933`, `:1104-1121`, `server._finish_manual_item` | operator told "not filed" for a filed report |
| G3 | A portal timeout after the final Submit is `ERROR_PORTAL_TIMEOUT` with no seed | `reporter.py:1081` | a county filing unknown to us |
| G4 | The flush-discard Slack alert tells people to check DERM; for a hand filing the action is to record it | `reporter.py:432-438` | wrong instruction (only after a contract break) |
| G5 | `post_result` drops the response body, so the bot log never says why our API refused | `api_client.py:108-132` | refusals visible only in Slack |
| G6 | `server.py` says client and dump date are typed into the county form; only the permit, hauler and date pumped are | `server.py:614`, `:902-905` | misleading |
| G7 | Three 041-MB 2026 visits have no GDO filing in our records: 1291 (01-18), 1529 (03-24), 4740 (05-24), all before the launch cutoff, all matchable | `derm.visit_gdo_our_record` | if Yan files them by hand before the bot ships, record them like 8889 (owner: whoever is on GDO duty) |
| G8 | A refused hand filing on a post-cutoff visit is later re-asserted by the queue as a normal bot SUCCESS under the hand run id, no image (section 2) | `reporter.py:628-655`, `db.py:326-339` | an automated record for a hand filing; the person following Slack is told it is already filed |

## 8. Self-review

- Requirement: B2 (identifiers), B3 (the image kept), B4 (who filed), Part A (no lost image on a duplicate). What stays
  manual is listed in section 2 and decided in D1.
- Bot rules: tests first and red on the old code (B1), red on revert for every change (B5, M1-M11), behaviour not text,
  runtime image (B0, B5), auditor (B7), docs in the same commit (B8), push = deploy with gates, a window and a rollback
  (B9-B12).
- Workspace rules: claims (A0, B0), commit conventions per repo, decisions rows (section 3, Part C), messages only with
  Fred's OK (B9).
