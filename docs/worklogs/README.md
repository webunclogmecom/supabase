# Work logs

Session-by-session records of what was actually done, by whom, and what was measured.

**Why these are versioned:** they sat at the workspace root, which is an allowlist git repo, so they
were untracked and one bad `git clean` from gone. Fred asked for them here so they survive.

⚠ **Attribution matters in these.** The Supabase and Building Apps repos are shared by parallel
sessions, so a plain `git log` mixes everyone's commits. Each log states whose work it covers and
explicitly excludes the other session's. Do not read a log as "everything that happened that day".

| log | covers |
|---|---|
| [`2026-08-13_to_08-14.md`](2026-08-13_to_08-14.md) | @Building Apps: Field Portal slug links, Admin Review DERM link, Calendar alignment + code 27, the ADR-015 reconciler gate |
| [`2026-08-16_to_08-17.md`](2026-08-16_to_08-17.md) | @Building Apps: FP print report visual pass, the city-email photo count, five Visit Calendar changes. ⚠ **Written 08-17 05:59 ET, so it covers Monday only up to that point** — see the note below for the rest of Monday. |
| [`../audits/2026-08-18_building_apps_day_log.md`](../audits/2026-08-18_building_apps_day_log.md) | @Building Apps, **Tue 08-18**: Admin Review + Visit Calendar releases, the photo-attribution thread (`completed_at` anchor, 96 links removed), and four times I was wrong. ⚠ Filed under `audits/`, not here — indexed so it is findable from the series. |
| [`2026-08-19_to_08-20.md`](2026-08-19_to_08-20.md) | @Building Apps: approval-proof audit + forgery fix, the three-attempt lightbox, code-27 rename, the manual GDO filing build end to end, `derm.visits` line items, the manual-filing modal, and the permit 11024 diagnosis |

## ⚠ Monday 2026-08-17 afternoon is covered by the app changelogs, not by a work log

`2026-08-16_to_08-17.md` was written at 05:59 ET. Four @Building Apps deliverables landed after it
and were documented **in the apps' own changelogs** (rule 4b), which is the binding requirement — but
they are not in any work log, so do not expect to find them here:

| deliverable | documented in |
|---|---|
| Day Start/End markers, smoke-tested end to end | `Building Apps/Visit Calendar/docs/08-changelog.md` — *"Day Start/End points: smoke-tested end to end on real data"* |
| Dump marker smoke test, two real defects found | same file — *"Dump marker smoke-tested; it works, and it found two real defects"* |
| Both Dump defects fixed and verified | same file — *"Both Dump defects FIXED and verified live"* |
| Sync-from-Jobber stale warning, two DB-side defects | same file — *"'Sync from Jobber' left its own warning on screen. Two defects, both DB-side"* |

The Admin Review work from that afternoon (Ready-for-Invoice persistence, queue pagination, the two
city-email defects from Serena's report) is likewise in
`Building Apps/Admin Review/docs/08-changelog.md`.

**Convention going forward:** a work log is a *session* record and is secondary. The binding rule is
workspace `CLAUDE.md` §4b — anything visible in an app goes in that app's `docs/08-changelog.md` in
the same cycle. The work log adds the cross-cutting narrative: what was measured, what was retracted,
and what was wrong.
