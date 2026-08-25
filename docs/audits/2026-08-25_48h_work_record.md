# 48-hour work record — 2026-08-23 → 2026-08-25

*Fred: "document everything since 48 hours ago." Window taken from the DB (`now() at time zone
'America/New_York'` = **2026-08-25 15:16 ET**), not from the session clock, per
`feedback_get_todays_date_from_the_db_not_memory`.*

**Volume:** 168 commits across three repos — 84 in `Supabase`, 30 in `Building Apps`, 54 in the
workspace-root claim file. 37 new migrations. 10 edge functions touched.

⚠ **TWO SESSIONS SHARE THESE REPOS AND ONE AUTHOR IDENTITY.** Some of what follows was done by the
parallel session, and `git log` cannot separate us. Where a workstream is clearly one session's, the
`WORKING-NOW.md` claim entries are the record; where it is not, this file does not guess.

---

## 🛑 READ THIS FIRST: GIT TIMESTAMPS IN THESE REPOS ARE 6 HOURS AHEAD OF ET

Measured 2026-08-25 while writing this file, and not documented anywhere before:

| source | reads | actually |
|---|---|---|
| DB, `now() at time zone 'America/New_York'` | 15:16 ET | **the truth** |
| `git log` on this machine | 21:13 | the same instant |
| the machine itself (`date`) | `Tue Aug 25 21:16 RDT` | **UTC+02:00** |

`git log -1 --format=%aI` returns `2026-08-25T21:13:17+02:00`. So **a commit stamped 21:13 happened
at 15:13 ET**, and one stamped `08-25 00:54` happened at **18:54 ET on 08-24**.

⇒ **Do not correlate a commit time against an ET business event, a `sync_log` row, or `audit.logs`
(which is UTC) without converting.** Several commits in this window carry dates that look like the
following day. The root `CLAUDE.md` §3 rule "always work in ET" has never covered git, and this is
the gap it leaves. It also means `--since="2026-08-23 00:00"` selects a window shifted 6 hours
earlier than intended.

---

## The workstreams

### 1. LWT monthly endpoint — built, then hardened over 19 audit iterations

**The endpoint.** `GET /functions/v1/rpa-derm-monthly?month=YYYY-MM` feeds Jonathan's Miami-Dade
Liquid Waste Transporter filing from `derm.v_lwt_monthly_rows`.
Design, and the reasoning behind the row-grain scope rule:
[`docs/specs/2026-08-24-lwt-monthly-endpoint-design.md`](../specs/2026-08-24-lwt-monthly-endpoint-design.md).

**Then Fred asked for the two cosmetic fields to be normalised, and that turned into the longest
thread of the window.** Four migrations, `2026-08-25_0400` → `_1200` → `_1400` → `_1500`. The last
one defines the deployed object; read all four, because the earliest alone no longer describes it.

🛑 **BOTH OBVIOUS IMPLEMENTATIONS WOULD HAVE FALSIFIED A COMPLIANCE FORM, in opposite directions.**
- `state = 'FL'` is the one-liner. `public.properties.state` holds California, New York and Québec
  rows, so a constant would relabel a non-Florida property the first time one took a Miami-Dade
  pickup. It is an explicit CASE, and unrecognised values pass through **verbatim**.
- `unaccent()` is the one-liner for the punctuation half, and it would **misspell a county form**:
  "Fendi Château Residences" and "409/448 Española Way" are the correct spellings of a registered
  business and a real Miami Beach street. The fold is a fixed list of typographic characters.

**What the 19 iterations actually found.** The object never regressed — not once. Every finding
after the second round was in the prose or the assertions written around it, and the valuable ones
were:

| Found | Why it mattered |
|---|---|
| The published contract still said `"state": "Florida"` | `postman/README.md` is the page Jonathan was pointed at. "No change needed" beside it is how he writes a `{'Florida':'FL'}` map that misses every row |
| A **live privilege regression** | Moving built-ins into a SECURITY INVOKER function added an EXECUTE check to the view's read path; `pg_read_all_data` got `42501` on the `state` column. Read-only dashboards and ETL. Prod unaffected (edge fn holds service_role) |
| The VERIFY pinned `all_rows = 690` | It went red the next morning when Diego filed ten legitimate rows |
| The suite was blind to `state` collapsing to NULL | The State column could print blank on an entire filing with all ten tests green |
| The accent checks did not test the accent | `ñ→ò` passed while serving **"448 Espaòola Way"**; and two carriers in one `EXISTS` is an OR, so stripping one passed |
| `truck_capacity_gallons` checked fleet *membership* | Every David row at 9000 = **5× the filed volume and the county fee**, nothing failing |
| A wrong-but-two-letter state on any subset | `FL→GL` on one row was invisible. Fixed with a **cross-field** check: every Florida county must pair with `FL` |

**Where the assertions live now.** `2026-08-25_1500`'s VERIFY block is the canonical one — 182
checks, mutation-tested, and it compares the view against an **independent base-table recomputation
at the same instant** rather than against remembered numbers.
⚠ The VERIFY blocks in `_0400`, `_1200` and `_1400` are **deliberately red** on today's data and
carry SUPERSEDED banners. Their pinned assertions are left as written because a migration is a dated
record; the "run it any time" promise is withdrawn.

**Postman folder 5** now carries 17 filing assertions plus include=all, ETag and bad-month. Verified
green on all 8 months of 2026 and **red on 83 of 84 constructed defects**. The 84th is the
no-location row, where the mutated row is byte-indistinguishable from the legitimate shape — an
honest limit, not a gap.

---

### 2. Manifest link guard — a legal link that becomes illegal when either side moves

`2026-08-24_1510` shipped `trg_ad_link_visit_completed`, `trg_ae_dump_date_keeps_links_valid`, and
`derm.v_manifest_link_date_conflicts`. Full workings, and the regulatory question that is **still
open**, in [`docs/audits/2026-08-24_manifest_link_830673_visit_6756.md`](2026-08-24_manifest_link_830673_visit_6756.md).

🛑 **Two traps recorded there that generalise.** The obvious diagnosis — comparing the link
timestamp against the visit's current `completed_at` — was **wrong**: that column had been rewritten
twice, and a "state at time T" read from a mutable column is a measurement of now. And the fix
everyone reaches for, putting the check in `ripple_reschedule_visit`, is **the one place it cannot
fire**: that function refuses completed visits, and all 690 linked visits are completed.

---

### 3. DERM portal queue — the gate that cannot see outside the database

Four exclusion gates, documented in `CLAUDE.md`. **Gate 3's freshness anchor is a database
timestamp, so a fix made at the county is structurally invisible to it** — which cost three days on
GDO-11024 while Jonathan's digests read "queue empty".

Shipped: `public.fn_requeue_derm_portal` (`2026-08-24_1900`/`_1910`/`_1930`), which records an
explicit operator decision that gate 3 honours, returns the **post-condition** rather than "ok", and
names whichever gate is still holding the row. And `public.v_derm_portal_queue_held`
(`2026-08-25_0110`) so `{"count": 0}` stops meaning both "nothing to file" and "one filing is stuck".

⚠ Two of the three requeue defects fixed in `_1930` were introduced by `_1910` — a sibling branch
that did not check the pair exists, and a `p_gdo_id => NULL` that was a manifest-wide override.

---

### 4. Health watchdog — verdicts were being written where nothing reads

Four `log_*_health()` crons wrote into `public.sync_log`, where health verdicts are **138 of 34,849
rows**. Three checks sat in `attention` for days with nobody told.

Triage: [`docs/audits/2026-08-24_health_alarm_triage.md`](2026-08-24_health_alarm_triage.md) —
**every alarm was wrong about its own subject.**

Now: `ops.v_health_items` → `fn_health_alert_scan()` → `health_alert_state` → `health-escalate` →
Resend → fred@ayache.com, on a 3-day staleness threshold with time-boxed acknowledgement.
**Silence is the healthy outcome.** The Slack digest shipped earlier the same day was retired.

---

### 5. Stamp Studio, band review, FP blackout

- **The band worklist reached zero.** 80 flagged bands reviewed across four severity tiers, **zero
  real leaks**, every one recorded in `derm.band_review` with its evidence. The passed population
  was sampled too (53 served documents), which is the check nobody remembers to run.
- **`stamp_page` is an ordinal into a list that moves.** Deleting one address image renumbered a
  ticket's pages and left "3/3 stamped" over a blank sheet. Fixed with a **witness** —
  `address_row_map.stamp_image_url`, captured at placement — rather than a re-key, because
  `derm.band_review` has no page column and a re-key would have converted the human backstop into a
  false all-clear.
- **A generated sheet prints one row per PERMIT, not per client.** The auto-stamp gate read the
  client ordinal into printed-row arithmetic, so any sheet carrying a multi-permit client could
  never resolve.
- **The row OCR had never been called by anything** — deployed and working for weeks, filling only
  when somebody invoked it by hand. Now scheduled.

---

### 6. GDO evidence endpoint, and consolidation

`rpa-derm-evidence` ships so the bot can attach its confirmation-email render after the run
(fill-once, enforced in the DB predicate). `fp-gdo-evidence` was **deleted** and folded into
`get-derm-doc` with an optional `gdo_id`, so one endpoint serves per-permit evidence.
Plan and the message to John:
[`docs/specs/2026-08-24-gdo-evidence-endpoint-plan.md`](../specs/2026-08-24-gdo-evidence-endpoint-plan.md).

---

### 7. Email OOM — a failure that reported success

`send-derm-email` and the city send died on any report over ~5 MB. The base64 encode blew the stack,
and **the send log recorded success throughout**. Fixed with a chunked encoder; `MAX_PDF_BYTES` was
also wrong in the unsafe direction (30 MiB was *over* Resend's cap, not under).
Customer-side record: `Building Apps/Field Portal/docs/`.

---

### 8. Other

- **`jobber-push-visit` upsert guard** — a Jobber visit that no longer exists used to jam the push;
  it now flags and continues (visit 7318).
- **Password-reset link vulnerability** fixed across 6 apps. A Supabase recovery link *is* a login:
  a full session is saved before `PASSWORD_RECOVERY` fires.
- **Calendar Tasks** — settled on a Jobber **Task** after ruling out Events and Assessments on
  measurement, then reversed to an internal row once Fred confirmed it is an office tool. v2 spec in
  `Building Apps`.

---

## 🛑 OPEN — none of these can be closed by another audit

| # | Item | Whose call |
|---|---|---|
| 1 | **Jonathan's message is drafted and unsent**, in Fred's DM ([p1787655515654909](https://unclogme.slack.com/archives/D0AMD1LQK62/p1787655515654909)). It says mark-as-reported does **not** exist (GET-only; POST returns 405) and puts three options to him | Fred sends |
| 2 | **Question 1 of the six**: 44 of 127 tickets used more than one truck. If a three-truck ticket needs three lines and we hand him one, that is a wrong filing — and no audit of our side can find it | Jonathan |
| 3 | **14 rows served with no location at all** — no state, address, city, zip or county — `in_scope: true`. Withhold, or file with a blank generator location? | Fred, regulatory |
| 4 | **The filed-page acceptance test has never been run.** Everything verified is database-vs-endpoint agreement, which cannot speak to what Diego's filed county pages say | Fred/Diego |
| 5 | **Visit 6756 / ticket 830673** — the data question is settled, the regulatory one is not: the paper filed with Miami-Dade lists 175-PV as a generator | Fred |
| 6 | Whether to shrink the `trg_ac` +1-day grace to 0 (would reclassify three links as violations) | Fred |

### Escalated, outside the LWT work

- **11 other views call a function a reader cannot EXECUTE** — the same asymmetry as the regression
  above, pre-existing and estate-wide. `derm.v_band_edge_check` is broken **today** for both
  `service_role` and `authenticated`.
- **`fn_requeue_derm_portal` still lets a zero-width space defeat its required-reason guard.**
- **`v_derm_portal_fields` serves client names unfolded** to the same bot, so two county-facing
  surfaces spell a facility two ways.
- **No production detector for a valid-shape wrong state.** The only assertion lives in a migration
  a human must run.
- **Properties 154, 396 and 567 are Beverly Hills addresses carrying `county = 'Dade'`.** Since
  `in_scope` derives from that county, one taking a pickup would be filed as Miami-Dade activity.
  Zero visits today, so latent — but it is dirty data, not a test artefact.
- Commit messages on `332f379` and `679a94a` carry figures corrected later; rewriting needs a
  force-push and Fred's OK.

---

## What this window is actually a lesson about

The LWT thread ran 19 audit iterations. **The database object never regressed once.** Every round
after the second found defects in the documentation and the tests written the round before — and
five of those rounds existed purely to repair damage the previous round's fixes had caused.

Three of them were the same defect: **a multi-line edit leaving an orphaned fragment**, twice
committed inside the very commit written to repair the previous instance. All three were invisible
to grep, because grep finds the new text and says nothing about the wreckage beside it.
`scripts/checks/orphaned-prose.mjs` now screens for it, and **its own header states its blind spots**
— including that it is syntactic and cannot see a sentence that is grammatically whole and factually
self-contradicting, which is what the final iteration found by hand.

⇒ **The loop's marginal value went to near zero around iteration 14**, when findings dropped to one
documentation wording fix per round. "Keep going until green" is not a safe stopping rule when the
auditors are thorough and the corpus keeps growing: there is nearly always one more comma. The
better rule is to stop when the findings stop touching what could reach a county form, and hand the
residual to a person.
