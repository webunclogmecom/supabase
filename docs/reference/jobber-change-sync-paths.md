# What catches a change made in Jobber

Fred, 2026-11-06: *"they can create new jobs, or visits, but then test it to see if that would be catched by our cron jobs that check for updates made in jobber."* Trello #177 `0mYt3LnE`.

Measured on the test client 112-YA, 2026-11-06 ET, with Viktor making the writes through his Jobber connection (job #99901156, DB job 2194, visit 9101).

**How a lost webhook was tested.** The webhook lands first and hides every timed job, so seeing a row arrive proves nothing about the crons. After each step landed, the test rows were put back by SQL to their earlier values, as if the webhook had never come, labelled `viktor-sync-test-controlled-miss` in `audit.logs`. Then we watched what restored them. No function, trigger or cron was touched.

## The table

| Change made in Jobber | Webhook (normal) | If the webhook is lost |
|---|---|---|
| New job | 2 s | The poll (`jobber-poll-sync`, every 5 min, jobs by `createdAt`) staged it by itself 4 min later. |
| New visit | 13 s | Read in the code, not rehearsed: `sync-jobber-upcoming-visits` replays every upcoming visit with no link first (cap 50), so the next run, at most 15 min. In 30 days of its log, 2 runs saw a missing visit: each still read `residual_gap` 1 right after its replay, and neither was missing on the next run. |
| Job title or status | 1 to 2 s, 7 s for a close | Job drift (`:15`, `:45`): 14 min and 12 min here, 30 at worst. |
| Job dates cleared because its last visit went | 7 s | **Not restored.** Job drift copies dates only when Jobber has some (`sync-jobber-job-drift/index.ts:255-256`), so a lost update leaves the old dates. |
| Visit made in Jobber, moved | 1 to 2 s | Upcoming job's rotation, 25 of about 274 per run: 46 min 41 s here, about 2 h 45 at worst. The daily job below also covers it. Visit drift never does. |
| Visit owned by the Calendar or the generator, moved | **Ignored on purpose** (loop guard in `handleVisit`, `webhook-jobber/index.ts:1003`: it syncs completion and fills an empty hour, never a date) | Visit drift (`:08`, `:38`) adopts it if we never edited the visit, and otherwise parks it for a person or heals our failed push. |
| Visit deleted | 7 s: `visit_status='cancelled'`, `deleted_at` stays NULL | **Only the daily job**, `scripts/sync/cron_jobber_reconcile_anomalies.js` branch 1 (orphan), which soft-deletes it. It is a GitHub job due at 09:15 UTC that has really run between 15:20 and 19:30 UTC lately. Until then the visit shows as scheduled on the Calendar. |

**875 of the 877 upcoming visits belong to the Calendar or the generator** (`source` in `visit-calendar`, `supabase_cron`, read 2026-11-06). So the row for moving a visit made in Jobber describes almost no real visit, and a fast result on a test visit says nothing about the rest. `calendar_visit_drift_candidates` takes only those two sources, which is why visit drift reads 0 for a visit made in Jobber.

Nothing goes back to Jobber on these paths. A VISIT_DESTROY sets `cancelled`, which fires `trg_push_visit_update`, and `fn_push_visit_to_jobber` returns at its origin check for a source other than the Calendar or the generator when the write has no browser origin.

## What a job or visit made in Jobber looks like here

- `visits.source = 'jobber'`, `service_line_item_id` NULL (normal for a visit made in Jobber), no truck or driver until someone assigns one.
- `jobs.total` NULL where Jobber says 0. Job-scope lines are stored only for SA-titled jobs; the visit's own line is stored.
- A visit made in Jobber on the same client and date as a generator placeholder can **take over that placeholder** (`fn_jobber_resolve_visit`, `was_promoted`). A wrong pick is silent. That is why Viktor's rule makes him read that date first and stop if anything is there.

## Viktor's rule that follows (Fred, 2026-11-06)

- He never creates a client, whoever asks. He walks staff through the Client App and warns them off Jobber.
- He may create a job or a visit on a client that already exists, only when clearly asked: live read before, read back after, and he says no truck or driver is assigned yet.
- Moving, renaming, closing and deleting go to the apps. Closing with `DESTROY_ALL` destroys a job's unfinished visits, the same call the Client App's close makes, but there a person chooses it.

⚠ **These rules live in his own skills, so they are only his word.** He passed 8 made-up messages with no correction on 2026-11-06 and pasted his saved lines, which cannot be read from here. Nothing technical stops him: his connection can still create clients. A client made through it shows lead source "Field Unclogme Viktor Integration" (`Client.leadSource`), which is the check from outside. Moving visits on real clients would need its own test on a generator-owned visit.

## Found, not fixed

1. **Client App:** after a visit is deleted in Jobber, the job still says "Next visit <date>" and lists it under Future visits as cancelled, until the daily job soft-deletes it.
2. **Job drift** does not clear job dates when Jobber has none (table above).
3. **`webhook-jobber`** labels a line 21 assessment visit as Pumping: `CODE_SVC` has no `21` (`webhook-jobber/index.ts` lines 874 to 894 and 919). 3 such visits in 180 days, one of them this test.
4. **A lost delete on any visit waits for the daily GitHub job**, whose hour is unreliable (root `CLAUDE.md`, section 6: GitHub timed jobs run only every 4 to 8 hours). This belongs to anyone deleting in Jobber, not only Viktor.
