# Triage: the three unread health alarms

**2026-08-24.** `public.sync_log` is write-only, and three health checks had been in
`attention` with nobody told. This is what they were actually saying, what was wrong with the
alarms themselves, and what still needs a person.

**Headline: every one of the three alarms was wrong about its own subject in a way that mattered.**
Not merely unread. An alarm nobody reads is also an alarm nobody *checks*.

---

## 1. `blackout-health` — right to fire, wrong on both numbers and wrong on the prose

**Verdict: real, but the hold is deliberate and correct. The alarm undercounts by more than 2x.**

`ticket-833049` is frozen on purpose by `page_block_extents_no_ticket_833049`
(`2026-08-19_2355` PART 5). `derm.ticket_page_images` emits a duplicate page slot for it, so
`effective_page 1` resolves to the physical page 2 image and **five clients were served a page they
do not appear on**. It is also a 6-slot handwritten form carrying 5-slot template bands. **Do not
drop that constraint.** The alarm's own advice — *"Run a measurement pass"* — is precisely the act
that re-opens the leak.

Two things it said that are false:

- **"10 clients see an EMPTY DERM FOG eManifest card."** They do not. The card renders
  `DERM FOG eManifest` / `DERM 833049` / a `DOCUMENTED` chip / *"On file, not available for online
  viewing"*, with no thumbnail and no Download button. That is exactly what Field Portal rule 8
  prescribes for a document number with no viewable file, and it **complies** with Yannick's standing
  rule that the customer app must not show what we do not have. Nothing 404s.
- **"10 clients."** It is **22 work orders across 22 clients.**
  `derm.v_blackout_blocked_sheets` starts `FROM derm.address_row_map WHERE stamp_y_pct IS NOT NULL`,
  so it is structurally blind to **unstamped** sheets:

  | ticket | work orders | visible to the alarm? |
  |---|---|---|
  | 833049 | 10 | yes — the deliberate hold |
  | 312024 | 9 | **no** — 0 stamped rows |
  | 833530 | 3 | **no** — 0 stamped rows |

  The customer-facing measure is
  `select count(*) from customer.work_orders where derm_manifest_number is not null and derm_manifest_url is null` → **22**
  (positive control: 647 work orders *do* have a file).

It also **overcounts** in one place: `window5-sheet3`'s manifest 959 has **zero** `manifest_visits`
links, so it never reaches `customer.work_orders`. No card is rendered at all. Its real remedy is a
re-stamp in the Studio (`blocker = no_stamp_timestamp`), not a measurement.

**Shipped:** `2026-08-24_1700` — the payload now carries both numbers and says which answers which
question, plus the per-sheet `blocker` and `what_to_do` the view already computed and the function was
discarding.

**Still needs a person:** tickets `312024` (9 clients) and `833530` (3 clients) are ordinary Stamp
Studio work — stamp, then measure a `page_block_extents` row per effective page. That is the whole
difference between "10 clients" and "22".

---

## 2. `rpa-derm-health` — one real compliance gap, hidden behind a latch

**Verdict: real and actionable. Compliance.**

**One Miami-Dade DERM report is unfiled.** Visit **6617**, client **043-MIL (Mila)**, permit
**GDO-11024**, service date 2026-08-04, dump ticket 832194. Four attempts, all
`ERROR_LOGIN_FAILED` — *"Either the Password or GDO Permit # is incorrect"* — on Aug 11, 14, 18, 19,
every one `retryable=false`.

**It is a credential problem, not a bot fault.** The same client's other permit on the same manifest,
**GDO-14117**, filed successfully on Aug 7. One permit authenticates, the other does not. Provenance
risk worth naming: GDO-11024 was split out of the malformed concatenated value
`"GDO-14117 / GDO-11024"` on 2026-07-20 and confirmed by a bot lookup, **not by a portal login**.
This is the first time anything tried to log in as 11024, and it has failed every time.

**The bot is not stuck** — there has been nothing to file. 7 of 8 candidate (visit, permit) pairs
since the 2026-07-21 cutoff are `SUCCESS`.

Two defects in the alarm itself:

- **It could never clear.** `visits_ge3_attempts` counted visits with ≥3 attempts *all time*, with no
  condition that anything was still unfiled. Fixed in `2026-08-24_1630`.
  🛑 **The obvious fix would have silenced a live compliance gap.** Adding "and no SUCCESS" while
  still grouping by `visit_id` returns **0**, because the sibling permit succeeded. The filing unit is
  the permit, so the grain is `(visit_id, gdo_id)` → **1**. Measured before applying, not after.
- **It cannot see a dead bot during a quiet period.** The only liveness reason,
  `no_recent_attempts`, is gated on `queue_depth > 0`, and queue_depth has been **0 in all 36 health
  rows ever written**. Not dead code — a death *plus* new work would fire it — but a death in a quiet
  spell is invisible until work arrives. `rpa-derm-queue` writes a lease only when it hands out work,
  so an empty poll leaves no trace: *"polling hourly and finding nothing"* and *"container dead since
  Aug 19"* are identical in our data. **A heartbeat is the fix and it belongs on the bot side.**
  ⚠ Meanwhile there is a free liveness signal we are not using: per
  `docs/reference/gdo-rpa-bot-triggers.md`, John's bot posts a **daily 8:00 AM EST Slack digest** via
  `SLACK_WEBHOOK_URL`. If that digest arrives, the container is alive.

**Latent trap, not biting yet:** `derm.gdo_report_status` is keyed on *visit*, not (visit, permit),
and its LATERAL prefers any SUCCESS — so it reports visit 6617 as `reported` while GDO-11024 is
unfiled. Nothing reads it today, which is exactly why the next consumer will believe it.

**Still needs a person:** file GDO-11024 on the portal, then record it in DERM Tracker at
`/visits/6617` → GDO Online Report → the GDO-11024 block → "Record a manual filing". Do **not**
hand-write `derm_portal_submissions`. And ask John which credential the bot presents per permit.

---

## 3. `calendar-push-health` — a working detector, and a genuine code gap

**Verdict: real and actionable. It should still be firing.**

⚠ **I mischaracterised this one and the correction matters.** I wrote "49 consecutive days since
2026-06-27". It is **49 attention runs out of 62**, with **13 `ok`** interleaved and a clean stretch
on 08-16/17/18. Longest attention streak 29 days (06-27 → 07-25); the current one is 6. I got that by
reading `min(started_at)` over the filtered rows as the start of an unbroken run — **`min()` of a
filtered set is not a run length.** Use gaps-and-islands.

Corrected, it is a **healthy detector with a real, rotating signal**: 3,423 item-reports covering
**636 distinct visits**, mostly `not_in_jobber`, most clearing within days.

**The live item is a real bug.** Visit **7318** (186-PV, dated 2027-01-01, `sync_state='failed'`)
points at a Jobber gid that no longer exists; Jobber answers `visitEditSchedule` with *"Visit not
found"*. In `supabase/functions/jobber-push-visit/index.ts` the **DELETE path has an `ALREADY_GONE`
guard** that treats a dead gid as success and unlinks — **the UPSERT path has no such guard**, so it
throws forever instead of unlinking and falling through to the CREATE branch the same file already
implements. A dead gid is permanently unrecoverable on upsert.

No runaway retry: `fn_calendar_push_auto_retry` caps at 4, and there have been **zero** pushes since
2026-08-19.

**A second instance is hidden:** visit 7754 (083-SHUL) carries the identical flag from 08-14. It left
the alarm not because it was fixed but because the visit was **soft-deleted** on 08-15 and the health
view filters `deleted_at IS NULL`.

**Not shipped — needs a decision.** The code fix is clear, but it changes how a push recovers from a
dead gid, and repairing visit 7318 itself needs a human: a visit dated **2027-01-01** is either real
future work or a typo, and the database cannot tell which.

---

## Why the channel is unusable, independent of who reads it

Measured, and it is structural rather than a matter of attention:

- **No dedup.** Every check re-announces the same unresolved item on every run.
  `jobber_visit_drift` is **161 of the last 180** `attention` rows (89%) and was re-reporting **one**
  visit with `healable=0` every 30 minutes. Across its history **4,408 item-reports describe 105
  distinct problems.**
- **No severity.** `attention` means "I found drift I could not fix" to one writer and "a compliance
  document is not viewable" to another. Same word, same column.
- **Wrong table.** Health verdicts are **138 of 34,849** `sync_log` rows — **0.40%** — under 21,863
  Jobber poll records. `sync_log` is a sync *journal*.

**Fixed (`2026-08-24_1600`):** `ops.v_health_status` gives every check a delta against its previous
run — `new_items`, `resolved_items`, `unchanged_since_last_run`, and a gaps-and-islands streak. It
earned its place before it shipped: the prototype caught `blackout-health` gaining a sheet
(`ticket-833395`) that appeared and cleared within hours on 2026-08-24 with nobody the wiser.

---

## Where an alert can land — the survey

⚠ **The standing note "Slack posts AS Fred" is true only of the interactive MCP tool.** It is **not**
true of the automated paths, and it should not be carried into this decision.

| option | exists today | what it would take |
|---|---|---|
| **Slack `#viktor-supabase`** (`C0B08S21HHD`) | **Yes, fully.** Four GitHub Actions post via `chat.postMessage` with `SLACK_BOT_TOKEN`, as the bot *"Supabase - Notifications"*. A third path, an incoming webhook, is proven by John's bot digest and by `dump-visit-create`. | One script + one workflow, copying the existing ~10-line `postSlack()` helper. |
| **A staff app panel** | Partly. **All 33 `ops.*` views are already SELECT-granted to `authenticated`**, so no new grant and no edge function. | A panel in a staff app. ⚠ Never the Field Portal. |
| **A new `#ops-health` channel** | Same mechanism as above. | One channel, one secret, same script. |
| **Email** | **No.** Resend exists but both users are customer/regulator-facing, and city sending is OFF. | A new path from scratch. |

**The channel had to be unmuted first, and that is done.** `audit_critical_poll.js` allow-listed
`jobber:postgres:sql` for the benign hourly token refresh but not `jobber_write:postgres:sql`, which
is the same refresh for the write-OAuth token. Measured over 7 days on non-`service_role`
`webhook_tokens` rows, keyed exactly as the poller keys them: `jobber` **286 allowed**,
`jobber_write` **249 alerted** (31 in the last 24h). Roughly 31 false "critical" alerts a day is what
made that channel unreadable. Fixed.

⚠ **One surface already exists and is structurally invisible:** the Visit Calendar renders an amber
chip from `ops.v_calendar_push_health`. The single flagged row is visit 7318, dated **2027-01-01** —
five months out, on a grid people navigate by month. It technically works and cannot be seen. Worth
remembering before adding a second surface with the same property.

## DECIDED AND SHIPPED, 2026-08-24

**Threshold, Fred:** post only when something changes. Silence means nothing changed. Today that
would have posted exactly once, for the blocked sheet that appeared and cleared.

**Channel, Fred:** a Slack **incoming webhook** to the **#tests** channel of the GDO Online Report
Slack app. Note this is a *test* destination; moving it to a real channel is a change to the secret,
not to any file.

**Shipped:** `scripts/alerts/health_digest.js` + `.github/workflows/health-digest.yml`, reading
`ops.v_health_status` and posting via `SLACK_HEALTH_WEBHOOK_URL`. Runs 17:00 UTC, after all four
checks have written (the last is `blackout-health` at 08:00 ET).

🛑 **IT WILL NOT RUN UNTIL SOMEONE ADDS THE GITHUB ACTIONS SECRET** `SLACK_HEALTH_WEBHOOK_URL`.
The webhook is a secret and this repo is PUBLIC, so it is in `.env` locally and nowhere in the repo.
Verified before committing that neither new file nor any tracked file contains it.

**Why John's bot is not the home for this**, since it was considered: his bot already posts a daily
8:00 AM EST digest and that is a *free liveness signal we should use* — if it does not arrive, the
container is down. But it cannot carry the health verdict itself, because **a bot cannot report its
own death**: `rpa-derm-health` exists partly to notice when that bot stops, and routing the verdict
through it makes a dead bot produce silence, which is indistinguishable from health. Three of the
four checks are also outside its domain, and it runs on an outside contractor's container.

**An empty `ops.v_health_status` posts loudly rather than staying quiet.** If the view breaks or the
crons stop writing, silence would look exactly like health, which is the failure this exists to fix.

---

## What needs a person, in priority order

1. **File GDO-11024** for visit 6617 (Mila) and record it in DERM Tracker. Compliance deadline.
2. **Ask John** which credential the bot presents per permit, and whether 11024 is registered for
   online reporting at all.
3. **Stamp tickets `312024` and `833530`** — 12 clients currently showing a DERM number with no
   viewable file, invisible to the alarm.
4. **Decide on visit 7318**: is a visit dated 2027-01-01 real work or a typo? Then the
   `jobber-push-visit` upsert guard can be fixed with a known-good target.
5. **Pick the alert channel** so `ops.v_health_status` has somewhere to go.
