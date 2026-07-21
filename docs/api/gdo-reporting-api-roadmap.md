# GDO Online Reporting API — proposed additions (roadmap)

Companion to [`gdo-reporting-api.md`](gdo-reporting-api.md). Output of a 4-lens brainstorm
(integrator DX / ops-safety / security-privacy / observability) + an adversarial YAGNI critic,
2026-07-21. Judged against the real shape: **2 endpoints, one trusted server-to-server consumer, 3
clients, low volume, compliance-critical, 0 submissions yet, rollout imminent.** Nothing here is built;
this is the decision menu.

Ranking rule: anything that cuts **double-file risk** or **PII exposure** ranks high; a config flag
beats a new table; scale / rate-limit / pagination ideas die on a 3-client feed.

---

## KEEP-NOW shortlist (recommended, in build order)

| # | Addition | Effort | Why it matters |
|---|---|---|---|
| 1 | **Rollout control flags** in `app_config`: `rpa_queue_paused` (queue returns `{count:0,paused:true}` + the `/run` trigger short-circuits, freezing BOTH poll and push from one flag) and `rpa_rollout_allowlist` (queue also intersects an allow-list of visit_ids/clients) | S | Instant emergency freeze without a deploy; makes "1 live visit Fred picks" explicit instead of bending the cutoff. Ship both **before the first live visit**. |
| 2 | **`ALREADY_FILED` terminal status** — exits the queue, carries `portal_confirmation` if scrapable else a screenshot of the existing filing, NOT counted as a new submission | S | The honest terminal when the bot's check-before-file finds a prior filing (crashed run that filed, or a human filed). Today the only terminal is `SUCCESS`, forcing a re-file or a faked success. **Highest compliance value.** |
| 3 | **Manual close-out RPC** `rpa_mark_filed_manually(visit_id, portal_confirmation, note)` — guarded, append-only, audited, requires a real confirmation | S/M | If a human files by hand while the bot is down, nothing records it → the recovered bot re-dispenses and double-files. Very likely to fire during rollout (the first live filing may be manual). |
| 4 | **Retry context in the queue response**: `attempt_count`, `last_attempt_at`, `last_status`, `last_run_id` per report | S | Tells the bot "this is a RETRY, run check-before-file FIRST" on exactly the visits most likely to carry a half-done prior run. Already computed. Also gives `ALREADY_FILED` its trigger. |
| 5 | **Dead-letter / needs-human surface**: on `retryable=false` (or attempt_count ≥ N), flag `needs_human`, drop from the live queue until cleared, expose via `derm.gdo_report_status` + a `v_rpa_derm_deadletter` view | M | Today a permanent data error (missing GDO#, bad address) is "not-SUCCESS" so it re-dispenses every 20h forever, burning attempts and risking a mis-file on bad data. |
| 6 | **Watchdog compliance signals** on the existing `v_rpa_derm_health` + cron: lease-expired-without-result, flagged-evidence-present, bot-silent > N h; route to Slack (MCP-as-Fred) | S | The lease-expired alert is the direct guard for the one double-file path the 20h lease does not fully close (crash after the portal accepts, before our result POST). Flagged (oversize) screenshots currently rot unseen. |

**Cheap riders (ship alongside, near-zero downside):** cut the signed-URL TTL from **4h → ~1h** (the bot polls every 15-30 min and downloads immediately, so hours of replay window buys nothing but exposure), and **length-cap + no-roster-data** contract on `failure_reason`.

---

## DEFER (worth it later, with the trigger that earns it)

- **Reconcile GET `?visit_id=`** — when a real crash needs a cheap state check without re-POSTing a 5MB screenshot (adds a 3rd endpoint; wait for the pain).
- **Self-service health/status endpoint for John** — when John asks to self-serve "empty because paused or no work?" (3rd endpoint, separate read key).
- **Pre-signed evidence upload URL** — when the flagged-evidence count from #6 actually exceeds 0 (proves real full-res loss).
- **Per-client rollup + ops board views + distinct bot principal** — once live volume > 0 and you want the "which of the 3 are up to date" board. Build a shared `v_rpa_queue_eligible` predicate first so the board can never disagree with the queue.
- **`portal_confirmation` uniqueness alert** — once ≥ 2 real successes exist (can't fire before).
- **Tunable lease/cooldown config** — when a real long-fill or incident needs tuning without a deploy (ship with a hard floor so it can't re-introduce re-dispense-mid-file).
- **Status enum + machine-readable error codes** — when John reports branching pain on prose errors (pairs with `ALREADY_FILED`, but doc work with no consumer pain today).
- **Per-key label + last-used telemetry** — at the first key rotation.
- **IP-allowlist to John's Railway egress** — when he provides a static egress IP (may be a paid Railway feature).
- **Evidence retention/purge policy** — after the compliance audit window is defined (never purge SUCCESS evidence before it).

---

## DROP (YAGNI for this API)

Cursor/offset pagination (3 clients, depth ≈ 0, 25-cap never hit) · rate limiting (one trusted consumer) · lease-heartbeat endpoint (violates the 2-endpoint shape; use the lease floor) · no-downgrade result guard (SUCCESS already permanently exits) · `total_pending`/TTL fields in the response (depth ≈ 0; the bot re-fetches to re-mint URLs anyway) · `schema_version` field (single consumer coordinated out of band; add it the day a breaking change ships) · trimming scalar PII (`county` constant, `client_email`/`name` low-exposure to a trusted box — the roster sheet is the real delta, below) · full pre-submit-marker auto-hold state machine (covered more cheaply by #2 + #4 + #6).

---

## Decisions for Fred

1. **Raw roster vs redacted address sheet** (the big one; blocks nothing but answer before open). The queue signs the **raw multi-client** address sheet, shipping every other code-27 client's name/address/GDO# to John's box and the county. Ask John: does the DERM portal upload need the full county-issued multi-client document, or only **this client's own row**? If a single-client extract is accepted, switch the queue to sign the **FP-Blackout redacted copy**. **Recommendation: default to redacted unless John confirms the portal needs the full doc.**

2. **Rollout gating: allow-list, or bend the cutoff?** "1 live visit you pick" currently needs `rpa_launch_cutoff()` bent so exactly one visit qualifies (brittle, dated). **Recommendation: ship `rpa_rollout_allowlist` (#1)** so "exactly these visits go live" is explicit and the first real county filing exposes one submission, not three clients.

3. **Recovery semantics for crash-after-file-before-POST.** (a) Keep auto-re-dispense after the 20h lease, relying on the bot's check-before-file + `ALREADY_FILED` + the lease-expired watchdog alert; or (b) hold any visit with an unconfirmed prior submit out of the live feed for human verification. **Recommendation: (a)** — full human-hold is more machinery than a 3-client feed warrants, and the alert already puts a human at the portal before the lease releases.

---

## Suggested build order

Before the **first live visit**: #1 (kill-switch + allow-list). Before **opening to all three**: #2 (`ALREADY_FILED`) + #3 (manual close-out) + #6's lease-expired alert. #4 + #5 as the recovery layer once volume is non-zero. The cheap riders any time.
