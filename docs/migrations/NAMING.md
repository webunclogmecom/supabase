# Migration file naming — and the letter-collision problem

*Written 2026-07-29 after measuring 19 colliding filenames across 8 dates. Read this before you name
a new migration.*

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
