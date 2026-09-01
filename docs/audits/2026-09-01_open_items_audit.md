# Open items, re-measured against live state (2026-09-01)

*Answering Fred's "so the only thing missing is putting the City Email automation live, correct?"*
**No.** City email is the biggest one and the only one whose remaining work is mostly a decision, but
eight other things are open, one of them a live unauthenticated endpoint into Prod.

Everything below was measured against Prod and the published bundles on 2026-09-01, not read out of a
doc. Where a doc disagreed with the measurement, the measurement wins and the doc line is listed for
correction.

---

## Three corrections, two of them mine

**1. `client_email_live_sends` is `true`. I told Fred it was `false` and that customers were
receiving nothing. That was wrong when I said it.**

| | |
|---|---|
| set `false` | 2026-08-28 11:41:26 ET |
| set **`true`** | **2026-09-01 11:53:38 ET** (`app_source='sql'`, not by me) |

🛑 **AND THE TRAP THAT MADE IT HARD TO SEE: `public.app_config.updated_at` DID NOT MOVE.** It still
reads `2026-08-28 11:41:26` for that row, i.e. it records the *previous* change. A verifier reading
`updated_at` concludes the key has been `true` since 2026-08-28 and reports no recent change at all;
one reading `audit.logs` gets 2026-09-01 11:53:38. Both ran the same day and disagreed by four days.
**`updated_at` on `app_config` is not a reliable change timestamp. Read `audit.logs`.**

⚠ Nothing was lost in the gated window. The gate **redirects**, it does not drop: client sends
between those two timestamps went to `fred@ayache.com` and were logged `is_test=true` (5 rows). No
customer email was silently swallowed, which is the opposite of what I implied.

**2. THREE properties hold internal addresses in `properties.city_emails`, not two.** I named two.
Measured, with a control (the regex matches all three and rejects both real `.gov` domains):

| client | property | `city_emails` | candidate rows |
|---|---|---|---|
| 009-CN Casa Neos | 42 | `{fred@ayache.com}` | 9 |
| 249-LOU Skinny Louie Wynwood | 973 | `{fred@ayache.com}` | 4 |
| **(no client_code) Aaron Azoulay** | **363** | **`{yan@ayache.com}`** | 0 |

Only `009-CN/42` is documented anywhere. Property 363 and the `yan@` address appear in no file.
All three are Miami, whose regulator row (`municipality_regulators` id 26) is INACTIVE with zero
emails. No property carries a real municipal address *alongside* a test one, so clearing the three
arrays destroys no real recipient. Corroboration this is a known leak that was half-cleaned: that
regulator row's own note records a 2026-08-21 deactivation for exactly this address. That cleanup
fixed the regulator table and never touched `properties.city_emails`, **which is the table the
sender actually reads**.

**3. The 186-PV 2026-03-31 anomaly is CLOSED, and my earlier verdict was inverted.** I reported
"assigned Moises, 2,761 GPS readings that day, 0 within 150m" and treated it as the one pair with a
real signal. The work ran **overnight into 2026-04-01**, and on that date GPS puts the truck **14 m
from the property**. The visit is fine. The claim "the truck was NOT there" in `WORKING-NOW.md` and
the "GPS is the wrong instrument" note of the same day are both superseded.

---

## City email go-live: what actually remains

The machine is healthy and idle exactly as designed. Cron `city-email-sweep` (jobid 33, `7 * * * *`)
is active, **108 runs in 7 days, 0 failed, avg 63 ms**. All 7 config keys exist and parse. The queue
is 0 and the candidate census is 657 rows: `no_city_email` 514, `before_go_live` 115, `already_sent`
16, `no_property` 12.

⚠ The status CASE has a precedence order, and it is load-bearing: `before_go_live` sits below every
other reason, so **all 115 of those rows already have exactly one resolved city-email property, are
past the 24h delay, and are unsent and unsuppressed. The `start_from` cutoff is the only thing
holding them.**

### Step 0 (a WRITE, must precede everything, the only non-decision blocker)

Clear the three test addresses above. Verify with both a must-be-zero and a must-not-move control:
`@ayache.com` matches must go to 0, and `.gov` matches must **still** be 110.

### Steps 1 to 3: run them in ONE transaction

The documented procedure is three separate statements in a specific order. Better: run all three in a
single Management API body, which executes as one transaction, so no intermediate state is ever
observable to the edge function and the ordering traps below become unreachable.

```sql
begin;
update public.app_config set value='true'       where key='city_email_live_sends';
update public.app_config set value=''           where key='city_email_test_recipient';
update public.app_config set value=now()::text  where key='city_email_start_from';
commit;
```

🛑 **Why the order matters if they are ever run separately.**
`fn_request_city_email_sweep` appends `test_recipient` to the request body whenever it is non-empty,
and `send-derm-email` only assigns the fallback recipient *inside* its `if (!live)` branch. It never
**clears** a caller-supplied one. `isTest = !!testRecipient`. So opening the gate while
`test_recipient` still says `fred@ayache.com` means every automatic email goes to Fred, is logged
`is_test=true`, drops the `CITY_BCC` compliance copy, never satisfies `already_sent` (that CTE
filters `is_test=false`), and parks the manifests in `recently_attempted` for 20h to be retried
forever. A daily loop that never drains and never files. And clearing the recipient *first*, before
the gate is open, returns `503 city_gate_misconfigured` on every DERM email, city and client.

### Two decisions only Fred can make

1. **The `start_from` value.** `now()` permanently writes off all **115** August manifests, **105 of
   which were genuinely due to Surfside and Hallandale Beach**, on top of a last-real-filing date of
   **2026-07-21** (42 days ago). A past cutoff files them at 5 per hourly sweep.
2. **What the three Miami properties' `city_emails` should become.** `{}` is the internally
   consistent answer (Miami's regulator is inactive, and 213 other Miami manifests already sit in
   `no_city_email`), but a human typed that address in through the Client App property editor and
   intent should not be deduced from structure.

### 🛑 And one thing an empty queue will never tell you

**Three Surfside filings are structurally invisible to the city-email automation.** 029-JOS manifest
1719, 082-TFC 1717 and 083-SHUL 1715 all sit on `ticket-833049`, which has no redacted document and
is held shut by the deliberate CHECK constraint `page_block_extents_no_ticket_833049`. They are
therefore **not candidates at any status** and no city-email query will ever report them. Either
unblock that folder (Fred's call, and migration `2026-08-19_2355` PART 5 must be read first, because
the obvious one-line fix doubles the exposure) or file those three by hand. **Do not read an empty
city queue as "nothing to file".**

---

## The other eight

| # | item | status | waits on |
|---|---|---|---|
| 1 | 15 customer work orders with a DERM ticket and **no redacted document** | 9 items, 3 need Fred | Fred + a stamper |
| 2 | 9 customer documents still served on **unreviewed derived bands** (4 pages) | open | a reviewer |
| 3 | `blackout-health-check` **did not run today** | needs diagnosis | nobody, then cron owner |
| 4 | **`webhook-airtable` still deployed**, ACTIVE, `verify_jwt=false` | open 39 days | **nobody** |
| 5 | PITR on Prod (`pitr_enabled=false`) | decision + budget | Fred + Yan |
| 6 | DERM storage to private + signed | ~1 day of real work | scoping is wrong, see below |
| 7 | Visit Calendar tasks 6 and 7 | 6 buildable, 7 needs a call | Fred for 7 |
| 8 | July + August LWT monthly reports: **38 of 38 tickets unfiled** | open | Jonathan / Fred |

**#3** is the one worth acting on quickly: cron jobid 28 (`0 12 * * *`) produced no
`cron.job_run_details` row on 2026-09-01 after 12 consecutive daily runs, so `ops.v_health_items` and
the daily escalation mail are currently serving the **2026-08-31** payload. Check again tomorrow
after 08:00 ET; a second miss is a pg_cron problem, not snapshot lag.

**#4** is the highest-severity thing nobody had listed. The Airtable sunset was 2026-07-24 and was
explicitly ungated, but `webhook-airtable` is still an ACTIVE edge function with `verify_jwt` false,
i.e. **an unauthenticated public endpoint into Prod**. Deleting it and the Airtable polling scripts
waits on nobody.

**#6** the plan understates the work. The move set is 2,831 objects / 1.325 GB and the URL rewrite is
**4,932 values across 11 columns**, not ~3,331 across 7: `derm.address_row_map.stamp_image_url` (687),
`derm.page_rule_scans.source_url` (172) and `derm.address_sheet_scan_reads.image_url` (78) are missing
from the staged plan. **61.9% of the objects are referenced by no DB column at all**, so consumer
testing and byte totals cannot detect a dropped copy; only per-object reconciliation on
(name, size, mimetype, eTag) can. And the write path is still live: 150 new objects landed in August,
so the pdf-service must be repointed first or the leak reopens behind the move.

**#7** Task 7 (the overlap conflict flag) cannot be built as specified: on today's Prod it fires **60
times, 56 of them all-day sentinel pairs, 0 actionable**, and exactly **1** badge on a date anyone can
still act on. The honest recommendation is not to build it, which is Fred's call. Also, the design
doc's own "25" anchor **is** reproducible (27 today, exactly 25 once two later visits are removed) and
my earlier "unreproducible" note should be corrected: the real defect in its check #4 is that it never
excluded all-day, so 19 of its 25 are sentinel.

**#8** 21 July and 17 August tickets have zero non-dry-run `lwt_filings` rows, and the only real
filing on record is a one-off manual backfill through 2026-06-23. Either the bot's write-back to
`rpa-derm-monthly-filed` is not wired, or the reports are being filed outside the system. Both are
questions, not defects.

---

## GDO pipeline: healthy, but three zeros are untested rather than proven

Queue 0, stale leases 0, bot polling hourly, last 200 at 12:58 ET. All correct and all healthy: every
eligible filing is done (14 of 14 in-scope pairs excluded by gate 1). **Do not "fix" the bot because
it filed nothing for three days.**

But three things are unproven rather than working:

- The **stale-lease watchdog shipped today has not yet written a `stale_leases` value**. First
  `rpa-derm-health-check` run is 2026-09-02 05:00 ET. Until that row exists, the watchdog is in the
  function body but not demonstrably in the escalation chain.
- The **multi-permit filing path has never been exercised by a real POST** (zero submissions since
  2026-08-29 09:17 ET). The next Casa Neos / 043-MIL / 242-WYN manifest Diego files is the true
  end-to-end test.
- **Jonathan's `gdo_id` echo is unmeasurable from the data**: there is no provenance column and no
  sample. Ask him; do not try to read it off the table. Making it answerable in future needs a
  provenance column on `derm_portal_submissions`.

Two sheet folders also need a person: `ticket-833395` (242-WYN, 3 active permits, 1 unbound card, and
`derm.add_extra_client_card` correctly refuses until the existing card is bound, which is a question
the paper answers) and `ticket-820714` (the transposed-digit twin of 830714). ⚠ **820714 currently
holds the geometry the LIVE documents match**, so retiring it before 830714 can publish would leave
the correct folder unable to regenerate. Extent first, verify, then retire.

⚠ And before splitting 242-WYN's card: `client_locations` 5 (Presidente) and 6 (CU4) under 242-WYN
have **no `gdos` row**. Splitting to 3 permits when the building may hold 5 bakes the wrong grain into
a regulator-facing document.

---

## Doc lines that are now false and should be corrected

`client_email_live_sends = 'false'` is asserted in 13 places across 6 files:
`Building Apps/Admin Review/CLAUDE.md:274`; `Building Apps/Admin Review/docs/11-city-email.md:25,28,42,395`;
`Building Apps/Admin Review/docs/16-city-email-video-guide.md:18,29`;
`Building Apps/Admin Review/docs/08-changelog.md:43`; `Building Apps/DERM Tracker/docs/08-changelog.md:1586`;
`Supabase/CLAUDE.md:701,2873,2935`.

🛑 `Building Apps/docs/2026-08-31-temporary-no-auth-mode.md:294` is a **past-tense incident record**
and must NOT be rewritten. Correcting a historical record to match the present is how the evidence
disappears.

Also add properties 973 and 363 to the step-0 list at `Supabase/CLAUDE.md:2907`, which names only
`009-CN/42`.

---

*Method: 7 read-only verifiers plus a completeness critic, each measuring against Prod and the live
bundles, each required to state the control it ran. No writes were made and none are authorised. Every
count here is a dated observation; re-measure rather than quoting it.*
