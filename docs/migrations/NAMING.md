# Migration file naming — and the prefix-collision problem

*Written 2026-07-29, corrected twice the same evening as the measurement got sharper. Read this before
you name a new migration.*

> **⚠ HEADLINE, and it is bigger than either of the first two passes said:
> 266 of 459 migration files (58%) do NOT have a unique prefix.**
>
> ```
> lettered prefixes used by 2+ files:    19 prefixes  ->   41 files
> bare-DATE prefixes used by 2+ files:   36 prefixes  ->  225 files
> TOTAL files with a non-unique prefix:              266 of 459  (58%)
> ```
>
> **The first two passes of this doc both said "19 files" and "55 files". Both were wrong, and wrong
> in the same way: 19 and 36 are counts of *prefixes*, not of files.** A prefix used by 3 files is one
> prefix and three ambiguous migrations. Mistaking one unit for the other understated the problem by
> roughly 5x. Kept here on purpose, because a units error is the easiest way for a careful measurement
> to produce a confident wrong number: see `feedback_inference_travels_past_measurement` in memory.

## The problem, measured

The convention has been `YYYY-MM-DD<letter>_<name>.sql`, where each session picks "the next unused
letter". With **three sessions sharing one repo**, each picks the next letter *from its own sequence*,
so the same letter gets used twice on the same day. Current state:

```
3 x 2026-05-17a    2 x 2026-07-21b    2 x 2026-07-29b
2 x 2026-07-18b    3 x 2026-07-21c    2 x 2026-07-29c
2 x 2026-07-20b    2 x 2026-07-23b    2 x 2026-07-29d
2 x 2026-07-20c    2 x 2026-07-23c    2 x 2026-07-29e
3 x 2026-07-20d    2 x 2026-07-23d    2 x 2026-07-29f
2 x 2026-07-20e    2 x 2026-07-24d    2 x 2026-07-29g
                                      2 x 2026-07-29h
```

### A SECOND collision class, worse than the letter one (added by @Supabase 2, re-measuring the above)

The 19 letter collisions are exact, confirmed independently. But counting only *lettered* prefixes
understates it, because the **bare date with no letter is itself a shared prefix**: the convention's
"first migration of the day gets no letter" means a session that does not know a file already exists
writes another bare-date name. Measured across `docs/migrations/`:

```
19 lettered prefixes used by 2+ files   ->   41 files
36 bare-DATE prefixes used by 2+ files  ->  225 files
```

*(Counts corrected: the original wording here said "19 files" and mixed prefixes with files. The
bare-date class is by far the larger one, 225 files against 41.)*

The worst is **`2026-05-26`, which names SEVEN different migrations**:

```
2026-05-26_calendar_ops_views.sql              2026-05-26_hr_sandbox_setup.sql
2026-05-26_calendar_visit_anon_insert_rls.sql  2026-05-26_rollback_hr_sandbox_additions.sql
2026-05-26_calendar_visit_anon_write_rls.sql   2026-05-26_visits_source_add_visit_calendar.sql
2026-05-26_hr_sandbox_recovery.sql
```

So "revert `2026-05-26`" is seven-way ambiguous, and three of those seven are an
apply / recovery / rollback trio for the same subsystem, i.e. exactly the case where getting the wrong
one is most damaging. That same date also carries `x`, `y`, `z` suffixes, a third ad-hoc scheme.

**This does not change the fix.** A `HHMM` prefix is unique per minute, so it closes both classes at
once. It does mean the scheme failed across **55 prefixes covering 266 files (58% of the directory)**,
not 19 of anything, and that the failure **predates the three-session setup**: a single session
re-using a bare date on its own is enough to trigger it. So the letter scheme was never sound; adding
sessions only made an existing flaw visible.

**Why the recovery recipe below matters more than it looks:** with a bare-date prefix there is not even
a letter to hint at intended order, so `git log --diff-filter=A` is the *only* way to recover the
sequence for those 36.

**Why it actually hurts, beyond untidiness:**

1. **The filename no longer identifies a migration.** "Revert `2026-07-29g`" is ambiguous: it is both
   `2026-07-29g_storage_revoke_anon_list.sql` and `2026-07-29g_sync_trigger_key_cleanup.sql`, which
   touch unrelated subsystems. Commit messages, changelog entries and ADRs all refer to migrations by
   this name.
2. **🛑 SORTED FILENAME ORDER IS NOT APPLICATION ORDER.** On 2026-07-29 one session used `a`–`i`
   between 00:13 and 16:09, then another restarted the alphabet at 17:23 and reused `b`–`h`. So a
   replay in filename order would apply `2026-07-29b_duplicate_guard_secdef` (committed 18:03) **before**
   `2026-07-29i_revert_gdo_permits_anon_policy` (committed 16:09), inverting roughly two hours of
   history. Anything that replays this directory alphabetically is wrong.

## Getting the true order

Authorship time, not filename, is the record:

```bash
cd Supabase
for f in $(ls docs/migrations/ | grep '<date>'); do
  git log --diff-filter=A --format='%ad|%h' --date=format:'%H:%M' -1 -- "docs/migrations/$f"
  echo "|$f"
done | sort
```

## The convention going forward: use a TIME prefix, not a letter

```
YYYY-MM-DD_HHMM_<short_name>.sql        e.g. 2026-07-30_0915_close_airtable_client_dispatch.sql
```

Times in **ET** (the workspace standard). This is **self-coordinating**: two sessions cannot collide
without shipping in the same minute, no claim file or cross-session check is needed, and it sorts
correctly *because* it sorts by time. The letter scheme required every session to know what every
other session had already used, which is exactly the assumption that failed 19 times.

If you must keep a letter (e.g. amending a same-minute pair), append a session tag rather than
guessing an unused letter: `2026-07-30_0915b_...`.

## Do NOT rename the existing colliding files

They are referenced by commit messages, `docs/migrations/` headers, app changelogs under
`Building Apps/*/docs/`, and ADRs. Renaming an **applied** migration changes its identity and breaks
those references without fixing anything: the migrations are already applied, so the filename is a
historical label, not an instruction. Leave them and rely on the git-order recipe above.

See also: ADR 010 (migration header format), the root `CLAUDE.md` §5 parallel-session protocol, and
`Supabase/CLAUDE.md` for the deploy + commit conventions.
