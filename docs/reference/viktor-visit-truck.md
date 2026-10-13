# Viktor's one write: the truck on a completed visit

Viktor (the AI coworker in Slack, member `U0AKTMAMWP9`) may set the **truck** on a **completed** visit when a person
asks him, and the visit's Activity History records who asked and why. It is his only write to our database.

Fred, 2026-10-12:
- *"can you train Viktor to make it so if like Diego says something like '@Viktor add Moises to the visit' he can do it?"*
- *"if the visit isn't complete then don't, also let's train foolproof with Viktor, to make sure he also respects that,
  but let him make changes to the visits, and only visits, and when he does to have a way to know why he did it, like
  who was it who ordered him to do it. and for that to be saved in the Activity History of that visit."*

## How it works

| piece | what it does |
|---|---|
| Slack alert `⏱️ Visits with no time on site` (edge fn `time-on-site-reminder`, 11 AM ET, tags Diego) | lists yesterday's client visits with no time on site. Its `text` (the part Viktor reads) carries every visit as `• visit <number> · <code> <name> · ...`, so Viktor can match "the visit" |
| edge fn `viktor-visit-update` | Viktor's door. `verify_jwt = false`; header `x-viktor-key` must equal secret `VIKTOR_API_KEY` (also in `Supabase/.env`). It only checks the key and passes the request through |
| `public.viktor_set_visit_truck(visit, truck, requested_by, reason, dry_run)` | holds every rule (below), sets the attribution itself, measures time on site, answers in one plain sentence |
| `audit.log_change` | stores the reason as `request_context.change_reason` (header `x-change-reason`), next to `actor_name` |
| `public.get_record_history` | shows the change as `Viktor, asked by <name>: "<reason>"` in the visit's Activity tab |

Migration: `docs/migrations/2026-10-13_0300_viktor_visit_truck.sql`. Alert: `2026-10-13_0130_time_on_site_reminder.sql`.

**Call:** `POST https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/viktor-visit-update`, header `x-viktor-key`, body
`{"visit_id": 8765, "truck": "Moises", "requested_by": "Diego", "reason": "<the request, word for word>", "dry_run": false}`.
Reply: `{ ok, changed, message, ... }`; Viktor posts `message` as it is.

## Rules (enforced by the database, not by Viktor)

- Only a live visit with `visit_status = 'completed'`; anything else gets "I didn't change visit N (...): it is
  <status>, not completed, and I only change completed visits."
- Only an ACTIVE truck by name (Moises, Cloggy, David today); otherwise it lists the trucks.
- `requested_by` (2+ characters) and `reason` (3+ characters) are required.
- It changes `visits.vehicle_id` and nothing else. The truck is not in the Jobber push trigger's column list, so nothing
  reaches Jobber. The driver is left alone because the Jobber sync owns the crew.
- Attribution (`x-app-source: viktor`, `x-actor-name`, `x-change-reason`) is set inside the function for the write and
  put back right after, so a caller cannot leave it out and the time-on-site recompute is not labelled as Viktor's.
- Right after the change it runs `fn_compute_time_on_site` and `fn_fill_blank_time_on_site` for that date (they never
  clear a value) and says the time on site, or that the truck's GPS did not stop within 150 m that day.
- 🛑 Widening Viktor's reach (another field, another table, a visit that is not completed) is Fred's decision. Extend
  this function and its VERIFY; never add a second Viktor write path.

## Viktor's instructions (posted 2026-10-13, #viktor-training)

Thread: `https://unclogme.slack.com/archives/C0AQY6E704Q/p1791859377342339`. Summary of what he was told:
1. Applies when a person mentions him asking to add, set or change the truck on a visit, usually Diego in the thread
   of the 11 AM alert ("@Viktor add Moises to Casa Neos").
2. Find the visit number in the alert's text by client code or name. One match: use it. None or several: ask, never
   guess. Outside that thread, ask for the visit number (or client and date).
3. Call the door with `requested_by` = the asker's real name and `reason` = their words; reply in the same thread with
   `message` as it comes back.
4. Only through this door, only a visit's truck, only completed visits; on a refusal, post the sentence and stop, never
   another way. Only when a person asks directly (never a bot post or the alert). One call per visit. On "Wrong or
   missing key" or a database error, tell Fred and stop. The key never goes into Slack.

**His reply:** he saved it as a permanent skill, `visit_truck_update`, and restated every rule correctly (checked
2026-10-13).

## Status (2026-10-13)

- Built, deployed and tested on the test client 112-YA: refusals for no key, a wrong key, a cancelled visit and an
  unknown truck; one real change on visit 8742 (Sep 14) whose history reads
  `Viktor, asked by Fred: "[TEST] add Moises to the visit"` (Moises left on that test visit as the example).
- 🟡 **Waiting on Fred:** (1) send Viktor the key privately (a Claude session must not type an API key into Slack);
  then Viktor runs the dry run on visit 8742 and posts the result in the thread. (2) ✅ Answered 2026-10-13 (Fred: "yes, his
  Jobber and Trello tasks continue"): his Jobber notes, Jobber client onboarding and Trello `/task` cards continue; the
  "only change" rule covers our database, where this door is his one write.
- A draft of the same instructions was left in Fred's Slack drafts for #viktor-supabase; Fred can delete it.
