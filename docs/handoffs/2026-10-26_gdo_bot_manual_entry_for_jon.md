# GDO bot: dashboard manual entries reach the Tracker (for Jon, 2026-10-26)

Two parts: the task brief, written the way the bot repo writes them (`docs/TASK_*.md`; it goes in as
`docs/TASK_MANUAL_ENTRY_UPSTREAM.md`), and the message telling Jon. **Neither is sent or pushed.** Bot-repo pushes are
deploys and wait until the September LWT report is filed (`Supabase/docs/reference/gdo-report-bot.md` section 9).
Our side is live: `rpa-derm-result` v40, section 10 of that reference.

---

## Part 1: the brief (`docs/TASK_MANUAL_ENTRY_UPSTREAM.md`)

```markdown
# Task brief: manual entries are recorded upstream as manual filings (Fred, 2026-10-26)

A report typed on the dashboard ("Add a report by hand") and filed on the county portal must show in the Tracker as
a manual filing. This IMPLEMENTS R7 in docs/REQUIREMENTS_TRACKER_SSO.md: the Tracker side now exists
(rpa-derm-result accepts `manual_entry`, live 2026-10-26). Work under CLAUDE.md's loop: write -> audit ->
mutation-verify -> one commit_msg.txt thread.

First case: manual entry #1 by yan, permit 14965, manifest 808783, date 2025-11-16, run
882d2b19-aa06-4db8-9d43-136d1451bebb. The portal accepted it at 12:00 ET; every POST got 400
unknown_field_manual_entry. Fred recorded it upstream by hand from /evidence-export, so the cached seed now gets
200 deduped and clears itself.

## What is true today (read in the code at 7681388)

- The design says a manual entry never posts (R7, HANDOFF, DOMAIN_RULES, reporter.py comments at 336-341 and
  383-390). The guard lives only in `_post_and_cache` (reporter.py:392-395). Two paths skip it, so every SUCCESS of
  a manual entry DOES post: the F1 seed (reporter.py:963, `db.cache_failed_result` directly, flushed later by
  `_flush_pending_results`, reporter.py:447) and the final POST after the email (reporter.py:1060).
- The body carries nothing that says which filing it is: `visit_id` / `manifest_id` null (server.py
  `_manual_payload` leaves them out on purpose), no permit, manifest or date (`build_result_payload` never copies
  them), no `gdo_id`.
- The retry resends the SEED, written before the email wait, so it has no image: `pending_api_results` is
  `INSERT OR IGNORE` on run_id (db.py:428) and the final payload is never cached (reporter.py:1062-1063 only logs).

## What changes

1. **build_result_payload puts the typed values inside `manual_entry`** (top-level contract unchanged):
   `gdo_number` (the one permit; validate_manual_entry already refuses commas), `ticket_number`, `service_date` as
   ISO YYYY-MM-DD (convert through parse_portal_date; upstream also reads MM/DD/YYYY, send ISO), `dump_date`
   (optional), plus the existing `created_by` and `why`. Upstream refuses any other key inside `manual_entry`
   (400 `unknown_field_manual_entry.<key>`), and refuses `manual_entry` together with a `visit_id`, `manifest_id`
   or `gdo_id`.
2. **A failed final POST replaces the seed with the final payload.** In the else branch at reporter.py:1062, cache
   the final payload (the one carrying the county email) with a replace, for that call only (e.g.
   `cache_failed_result(..., replace=True)` -> `INSERT OR REPLACE`). The default stays IGNORE: the re-assert path
   (reporter.py:641-655) must never overwrite an original seed. Applies to queue items too, harmlessly.
3. **Manual entries post on purpose now, SUCCESS only.** Keep the `_post_and_cache` guard for every other manual
   result (dry run, validation, errors stay local: upstream answers them 200 recorded:false anyway, but nothing is
   gained by sending them). Rewrite the comments that say a manual entry never posts.
4. **Read the answer.** Upstream returns:
   - 201 `{recorded:true, manual_entry:true, visit_id, gdo_id, run_id:"manual-bot-<run_id>", filed_by}`;
   - 200 `{recorded:true, deduped:true, ...}` on a retry;
   - 200 `{recorded:false, reason, announced:true}` when it cannot match ONE visit (no permit/manifest/date, no
     matching visit, several visits on that manifest, no image) or the permit is already filed. Upstream has
     already posted it to #apps-notifications for a person; do NOT retry it;
   - 500 `*_retry` when something on its side failed; retry as today.
   Optional, operator-facing: when `recorded:false`, the manual entry's row on the dashboard says "Filed on the
   county; not recorded in the Tracker: <reason>" instead of plain "Filed" (_finish_manual_item reads only the
   local ledger today).

## Tests (behaviour, mutation-verified)

- build_result_payload on a `_manual` item carries the four values in `manual_entry`, ISO date; a queue item is
  unchanged (no `manual_entry` key at all).
- A failed final POST leaves the FINAL payload (with `screenshot`) in pending_api_results; the re-assert path still
  cannot overwrite a seed (revert `replace` and the first test fails).
- A manual non-SUCCESS result never reaches api_client.post_result.
- Full suite green via run_tests.py before commit_msg.

## Docs in the same change

- REQUIREMENTS_TRACKER_SSO.md R7: DELIVERED 2026-10-26 on the Tracker side, with the shipped shape above.
- PROJECT_GDO_BOT.md (state + roadmap), HANDOFF.md line 113 ("never POST upstream"), API_CONTRACT.md (the
  `manual_entry` body), the server.py `_manual_payload` docstring, reporter.py comments at 336-341 and 383-390.
- A "Delivered" section at the end of this brief, naming what was deliberately NOT done.
```

---

## Part 2: the message to Jon

> Hi Jon, a heads-up on the GDO bot, nothing urgent.
>
> Today Yan used "Add a report by hand" on the bot dashboard for Marie Blachere (permit 14965, manifest 808783,
> 11/16/2025). The county accepted it. The bot then posted the result to our API anyway, which we did not expect
> from R7: the seed and the final POST after the email both skip the `_post_and_cache` guard. Our API refused it
> (unknown field `manual_entry`) and the bot retried every hour.
>
> We decided to treat those as manual filings, so our side now accepts `manual_entry` and records it like a manual
> filing from the DERM app. It needs two things from the bot to work:
> 1. the permit, manifest number and service date (and dump date if there is one) inside `manual_entry`; today the
>    body has nothing that says which visit it is;
> 2. when the final POST fails, keep the final payload (with the county email) instead of the seed, which has no
>    image.
>
> The brief, written your way, is `docs/TASK_MANUAL_ENTRY_UPSTREAM.md` (attached). Until the bot sends those values,
> we answer a manual entry with a 200 and a Slack note for someone to record it by hand, so the bot no longer
> retries it. Yan's entry is already recorded on our side. Pushes wait for the September LWT filing.
>
> Thanks!
