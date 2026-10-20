# The GDO report bot: inspection, four fixes, a full check, and the no-permit hold (2026-10-19 to 2026-10-20)

One record of the whole sequence. The standing reference for the bot is
[`docs/reference/gdo-report-bot.md`](../reference/gdo-report-bot.md); this file is the history of how it got there.

## 1. What Fred asked, in order

| when (ET) | Fred | what it led to |
|---|---|---|
| 10-19 | "It's GDO Online Report of Jonathan, he gave us his documentation here ... read the README and the /docs, do a full inspection of it ... also remember they're hosted in Railway too. ... once you have all that project understood to see what that notification on slack is about." | sections 2 and 3 |
| 10-20 morning | "go ahead with 4" (the four bot fixes offered) | section 4 |
| 10-20 afternoon | "Do a full check, to make sure what you understand is correct and what you're trying to do is correct as well. once that is done, design the plan and execute it." | sections 5 to 7 |
| 10-20 evening | "document what you have done" | this file |

## 2. Understanding the bot (10-19)

- Read the whole repo `webunclogmecom/unclogme-gdo-report-bot` at `87b24a2`: README, 23 docs, every module and test
  (ten parallel readers, then a synthesis pass that resolved their disagreements against the code).
- Read the live Railway service (project `unclogme-gdo-report-bot`, service `UnclogMe_Reporter_Bot`): deployments,
  logs, and the variables that are not secrets.
- Since the 2026-10-08 handoff the bot is ours: Fred owns it, Diego operates it, Yan makes policy calls.
- Written up as `docs/reference/gdo-report-bot.md` (Supabase `ff4e203`); `CLAUDE.md` points to it.

## 3. The Slack alert (digest of 10-19, for Oct 18)

"2 needs review", both `No readable GDO permit in ''`: 315-CAP Capas Burger Aventura (visit 7849) and 249-LOU
Skinny Louie Wynwood (visit 7859).

- Neither client has any row in `public.gdos`, so our queue sent `gdo_number` null; the bot's preflight let a null
  through (`str(None)` is the text "None") and refused at the comma split. The refusal was right.
- Both had been refused before and held by queue gate 3. The one-time time-on-site fix wrote both visits at 13:15:48
  ET on 10-18, which lifted the hold; the bot's 13:36 ET run served and refused them again (HTTP 201, Railway logs).
- History found in Slack: Capas had no permit (Fred, 09-03: "under revision"); Wynwood's permit GDO-14738 was found by
  the GDO Slack bot and never entered; Jonathan asked on 09-03 that the queue stop serving visits with no permit.
- 10-20 11:29 ET: visit 7860 (249-LOU) was refused the same way, as predicted.

## 4. Four bot fixes (10-20 morning, "go ahead with 4")

| fix | where |
|---|---|
| preflight refuses a JSON null (permit, ticket number, service date) | bot `reporter.py` |
| the result carries the row's `gdo_id` (when the row names one permit) | bot `build_result_payload` |
| the 08:00 digest and `send_digest_now` count the queue without leasing it | bot `fetch_queue(peek=True)` + our `rpa-derm-queue` v32 `?mode=peek` |
| the digest sleep is measured in UTC (no double digest on 2026-11-01) | bot `server.py` `_next_digest` |

- Bot commit `7681388`, deployed on Railway as `789c211a` at 12:54 ET. New test file
  `tests/test_queue_nulls_and_digest.py`; all 11 mutants (each fix reverted) fail it; full suite 41 of 41.
  The repo's own auditor subagent reviewed it; its findings (the manual digest also leased, a null date reached the
  ledger as "None", no warning when a peek is answered as live, contract tables, a trailing comma) were fixed in the
  same commit.
- Supabase `da11756` (peek mode).

## 5. The full check (10-20 afternoon)

Five independent read-only verifiers (the Oct 18 analysis, the shipped fixes, the reference doc, the facts behind
the open decisions, the design of the next change), then a critic over all five. A PC restart cut the first run; it
was resumed from cache.

**Confirmed:** the Oct 18 cause, the refusal history, the shipped fixes (deployed bodies match the source), and that
only 7849, 7859 and 7860 lack a permit after the launch cutoff.

**Corrected:**
1. Gate 3 holds a failure until the visit or manifest row is next WRITTEN, not until it changes:
   `public.set_updated_at` stamps every UPDATE, even a no-op one, and `audit.log_change` drops no-op UPDATEs. So 7849's
   re-serves on 09-03 and 10-06 have no audited cause.
2. GDO-14738 was first returned on 08-17, when Yan asked the GDO Slack bot, not on 09-18. Nobody approved or rejected
   it in Slack.
3. Viktor's GDO Compliance Sentinel names GDO-09083 for 315-CAP. That permit belongs to PLAYCHEF K LLC / Delicious
   Bites and was ruled out on 09-03. A lead nobody followed: SIR FOOD LLC held GDO-14098 (expired 2024-12-31) at Capas
   Aventura's address and paid a Capas invoice.
4. 249-LOU has 6 more scheduled GDO-reporting visits that would each be refused.
5. The planned "anchor gate 3 on the permit's created_at" would fail when an INACTIVE permit is reactivated.
   Exact-pair matching replaced it.
6. Line 27 has been billed $35 three times for reports never filed: #3067 (315-CAP, paid), #3186 (249-LOU, past due),
   #3391 (249-LOU, paid).
7. The bot's alerts and digest did tell people; what was missing was names, an owner and an action.
8. Jonathan's `87b24a2` ("Monthly C", note: "push held until 2026-10-20") was live from 10-18 21:27 ET, so the 10-19
   monthly close ran on it.

## 6. What was built (10-20 afternoon)

**Supabase `2026-10-20_1345_gdo_queue_no_permit_hold`** (applied 13:45 ET, commit `1e50856`):
- `v_derm_portal_queue` never serves a row with `gdo_id IS NULL`; gate 3 is exact-pair (a failure holds only its own
  permit's row), so entering or reactivating a permit releases the visit with no requeue. Gates 1, 2 and 4 unchanged.
- `v_derm_portal_queue_held`: new reason `no_permit` (7849, 7859, 7860); gate 3 exact-pair; the `leased` arm per
  permit; anon/authenticated revoked (no app reads it).
- `v_rpa_derm_health`: the retry-loop count leaves out no-permit groups (they get their own items).
- `log_rpa_derm_health()`: one `gdo_no_permit` health item per held visit, and one item per client whose open job
  bills line 27 with no ACTIVE permit (249-LOU).
- `fn_requeue_derm_portal` mirrors gate 3.

**Supabase `2026-10-20_1405_gdo_queue_followups`** (applied 14:05 ET, commit `9c11a96`), from the post-check below:
- a NULL-permit failure on a visit that has a permit counts in the retry loop again;
- `gdo_filed_permit_changed` health item: a visit filed under a permit that has since left the client's ACTIVE
  permits while it has another (the queue then files that one too; a person decides);
- `fn_requeue_derm_portal`'s sibling message corrected (my `_1345` text blamed the 25-row cap, which was wrong);
- the `_1345` rollback now guards all five objects.

**Edge functions:**
- `rpa-derm-queue` v33: an unknown `mode` returns 400 (it used to be read as live, the one mode that leases).
- `rpa-derm-queue` v34: also refuses any query key except one `mode`; the held note names `no_permit`.
- `rpa-derm-result` v31: keeps the bot's `gdo_id` when it is any permit of the visit's client, instead of guessing
  another one.
- `rpa-derm-result` v32: logs an ownership-check error as such and skips the check for a visit with no client.

**Docs:** `CLAUDE.md` (the four-gates section, the bot bullet, the SHADOW_MODE lease sentence),
`docs/reference/gdo-report-bot.md`, `docs/reference/gdo-multi-permit-filing.md`, the Postman README and collection
("Queue - live (LEASES for 20h)" plus a new "Queue - peek (read only)"), `docs/decisions-to-build.md`. Commits
`8f52365`, `18d1a75`; the Postman publish workflow succeeded on every push.

## 7. How it was proven

- Each migration body was built from the live `pg_get_viewdef` / `pg_get_functiondef` by exact-once anchored edits,
  never retyped, with md5 guards.
- Each migration was rehearsed in BEGIN ... ROLLBACK first: forward, VERIFY, the logger, the health items, a requeue
  probe, then the rollback restored the live md5s.
- In-transaction VERIFY of `_1345`: the queue lost only NULL-permit rows and gained none; only those three rows moved
  hold reason, all to `no_permit`; 8095 stayed `data_error`; grants as intended.
- Live after apply: queue 0; held `already_filed` 38, `no_permit` 3, `data_error` 1, `before_launch_cutoff` 51; the
  queue edge fn's held summary shows `no_permit: 3` with no deploy; the retry loop reads 1 (8095).
- Edge fns: deployed bodies read back with a control needle. Bad queries tested live (`?Mode=peek`, `?mode=peek&x=1`,
  `mode` twice, `?mode=`, `?mode=Peek`) all returned 400; peek and dryrun 200; the lease table byte-identical before
  and after.
- An independent post-check of the shipped work (three read-only skeptics: database, edge functions, docs) confirmed
  the database change row by row against the old logic. Its findings, two medium (a wrong doc explanation, and the
  v31 trade-off below) and the rest low, are fixed in `_1405`, v34, v32 and `18d1a75`.

**The v31 trade-off, decided.** If a permit is replaced between the bot taking a visit and its result arriving,
v31 records the filing under the permit actually used, and the queue then files the new permit too. Before v31 the
filing was recorded against the new permit while the county only had the old number: a false "filed" record. The
truthful record was kept, and `gdo_filed_permit_changed` makes the case visible. 0 such visits exist.

## 8. Not proven yet (watch)

- **Peek on a non-empty queue.** The first real run is the 08:00 digest after 10-20. In the Railway logs expect
  `Queue returned N item(s) (mode=peek)` and no "did not answer mode=peek" warning; `derm_portal_leases` must not grow
  at 12:00 UTC.
- **The first result carrying `gdo_id`.** `derm_portal_submissions.gdo_id` must equal the served row's permit.
- **The new health items in the email.** `log_rpa_derm_health` runs at 05:00 ET and the escalation email at 09:30 ET.
  Expect new items 7849, 7859, 7860 and 249-LOU. On 10-20 the latest run (05:00) was still the old body.
- **`rpa-derm-result`'s same-client branch** has never run on real traffic.

## 9. Needs a person

1. Approve GDO-14738 for 249-LOU (Diego or Yan). The county PDF has been in Slack since 08-17. Fred then enters it in
   the Client App with the PDF (client 499, property 973). 7859 then files by itself, past its 10-15 deadline, and
   7860 on time.
2. Capas: is GDO-14098 (SIR FOOD LLC) its permit, or does it have none?
3. Correct Viktor's sentinel (GDO-09083 is not Capas's). That is a message to Viktor, so it is Fred's call.
4. The $105 billed for unfiled reports.
5. Optional: a Slack post for no-permit items. Today only Fred's health email names them.

## 10. Deliberately not done

- **Gate 3 still lifts on any write.** `updated_at` has many readers, so this is its own decision. It is why 8095's
  refused county login is retried whenever something writes that visit.
- **Bot-repo doc edits:** HANDOFF says `MIGRATE_ANY_EMAIL` is off (it is on) and that `87b24a2` was held. Any push to
  the bot repo is a Railway deploy and restarts Diego's `/monthly` page, so these wait until the September LWT report
  is in `public.lwt_filings`. On 10-20 at 18:53 ET the newest real filing was still id 76 (period 07-27 to 08-24).
- **No hand repair of the three visits.** They are held by the rule and will file by the rule once a permit exists.

## 11. Lessons

- A peek test against an empty queue proves nothing: nothing leases on an empty queue in any mode. Say so rather than
  report it as proof.
- In JavaScript, `String.replace(a, b)` reads `$'` inside `b` as "the rest of the string". The new SQL contained
  `'^GDO-[0-9]+$'`, and the logger body came out duplicated. The exact-once anchor check caught it before anything
  ran. Use a function replacer: `replace(a, () => b)`.
- Postgres re-prints a view when it saves it, so a rollback guard must hold the md5 of the saved form, taken after a
  rehearsal, not the md5 of the text that was sent.
- I wrote a wrong explanation (`sibling_won_this_pass` blamed on the 25-row cap) into a function and a doc on the same
  day I was correcting other people's docs. The independent post-check caught it. A fresh reviewer on shipped work is
  worth the time.
