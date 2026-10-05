# 2026-10-05: public repo security cleanup

Owner: Supabase 2 session. Source: the read-only system audit of 2026-10-05 (workspace-level folder
`system-audit-2026-10-05/`, local, in no repo: `REPORT.md` findings SECURITY-01, SECURITY-03,
SECURITY-05 and HYGIENE_APPS-01, and `REPO_SCRUB_PLAN.md`). This file is the durable record. The one-line
rules it produced live in this repo's `CLAUDE.md` ("This repo is PUBLIC") and in the root `CLAUDE.md`.

This repo is public. This record names no password, no code and no list of which clients' codes are
still in git history; that list stays in the local audit folder.

## Fred's decisions (verbatim, 2026-10-05)

| Ask | Fred |
|---|---|
| The `yannick_readonly` password published in this repo | "About yannick password, then remove it." |
| Remove the codes, fix the two Yannick docs, take out the client files | "Go ahead" |
| Tell the clients whose lock box codes were exposed | "No need to tell" |
| Stop showing access notes on the open Field Portal page | "Show them, do not worry." (kept as is) |
| Yannick's future read access | a staff app login, not a database password ("Sounds good") |
| Backups: PITR, or an own copy on Railway | "Can we minimize the 6 hours up to 2 hours?" (open) |
| A new Railway project, two-step login, a second admin | "what is this for?" (explained; open) |
| Make this repo private | yes, after the timed jobs move to Railway and the 3 raw-link flows move; no history purge ("Sounds good") |

## 1. `yannick_readonly`: login off, password gone

- **Why:** its full connection string, password included, sat in two handoff docs here (since 2026-05-11 and
  2026-06-02). The role could log in, bypassed RLS and had no expiry, so anyone holding it could read every
  client, contact and lock box code.
- **Measured before:** 0 live sessions. `pg_stat_statements` since its 2026-09-03 reset kept one statement for
  the role (`SELECT 1`, 8 calls), but it has evicted entries 85 times since, so that is a hint, not proof that
  nothing else ran. No `.env`, settings or config file uses it.
- **Done (14:25 ET):** `docs/migrations/2026-10-05_1425_yannick_readonly_login_off.sql`: NOLOGIN, NOBYPASSRLS,
  PASSWORD NULL, default privileges removed, the 154 existing grants kept (inert without a login; migrations
  and `scripts/probes/job_step_ledger.js` rely on the role existing). Dry run, and a mutation control (the
  VERIFY fails without the ALTER) both behaved. Commit `15bf7d4` replaced the 4 password lines with
  `<PASSWORD-REMOVED-2026-10-05>`; the pushed tree was then checked: 0 of 2,465 files hold the value.
- **Leftovers (`9ead448`):** intake reference rule 15 rewritten; `scripts/migrations/create_yannick_readonly_role.sql`
  kept behind a DO NOT RE-RUN header (re-running it restores BYPASSRLS and SELECT on every public table);
  the dead `scripts/probes/_archive/apply_yannick_readonly.js` deleted.

## 2. Real lock box codes: replaced with placeholders

- **Where they were:** sessions had pasted real client codes as examples into 4 applied migrations
  (header comments and VERIFY fixtures), `CLAUDE.md`, 2 probe scripts, 1 one-shot sync script and the Jobber
  tech-lead summary. Six clients were affected in this repo: five certain and one probable (an access code
  quoted in the tech-lead summary since 2026-04-21 that matches a stored value).
- **Done (`d11a7cd`, 29 lines in 9 files; plus `e4642ba`, 1 line):** each value became `REDACTED-<client code>`
  (one placeholder per client and value, so every VERIFY that feeds a value and then asserts it still pairs up),
  `<client code> lock box code` and `<code redacted>` in prose, and `TEST-LB-0001` in `lock_box_crud_smoke.js`
  (different from its CREATE value). The verification pass then found one more real value, a Grease Trap
  size string test in `2026-09-02_1000` step 8c that the plan had called a coincidence; `e4642ba` made it `'2500'`. Line numbers
  are unchanged. Each edited migration got one note line appended at its end: a record, not re-runnable.
- **Same pass, outside this repo:** Building Apps `1fddebe` (22 lines in 3 Client App and intake docs), a
  memory note (3 lines) and `WORKING-NOW.md` (24 lines, then 4 more where a letter was glued to a code; in
  place, announced first).
- **How it was verified:** a sweep that reads the live `properties.lock_box_key` values and code-like digits
  from `properties.access_notes` into memory only, scans every tracked file of both repos plus memory and `WORKING-NOW.md`,
  and writes `file:line client` lines, never a value. Positive control: before editing it found every line
  on the plan's list (including the two an earlier tool missed). After: the before/after lists differed by
  exactly the edited lines, with nothing added. An independent verification pass then widened the sources
  (intake answers and accepts, Jobber note bodies, calendar tasks, page content, the audit history of
  `lock_box_key` and `access_notes`) and matched codes with letters glued on; it found the two misses above
  and nothing else. The remaining hits are ids, prices, migration-id suffixes and street numbers that happen
  to equal a code, each looked at with the number masked. Next sweep: read those wider sources too.
- **Not fixed by this:** git history. Old commits still show the values, and the redaction diff (`d11a7cd`) is
  worse: it shows each removed value on the line next to a placeholder that names its client, so the public
  history is now a labelled list. That is why the rule from now on is a placeholder that does NOT name the
  client in this repo (`CLAUDE.md`, "This repo is PUBLIC"). Going private is what hides the history; the physical lock boxes; the Field Portal, which keeps showing access
  notes by Fred's decision above.

## 3. Client-data files: out of the repo, kept locally

- **What:** 56 tracked files: 10 `docs/backups` dumps, the 3 tracked PDFs, `recurring_jobs.json` (client
  prices), `EXCLUDED_CLIENTS_REVIEW.md` (private customers with balances), the multi-location client list for
  Diego and Yan, GDO permit lists, OPS to-do lists, 10 `reports/` files, the internal-portal prototype (50 client records), 2 PDF builders with
  hard-coded addresses, and 19 underscore scripts the ignore rules already excluded.
- **Done:** `git rm --cached` only, so every file stays on disk. A byte-verified copy of all 56 is in the
  workspace-level `backups/2026-10-05_supabase_public_cleanup/` (`SHA256SUMS.txt`, `FILES.txt`). Ignore rules
  added, and `*.pdf` is now global (`6d7005f`); the untracking itself is `8f75b19` (see the trap below).
  The two schema-only `docs/backups` files stay tracked. `CLAUDE.md`, `README.md` and
  `apps/internal-portal/README.md` repointed (a copy of the prototype is in the private Building Apps repo,
  `ops-portal/prototype.html`, not byte-identical).
- **Readers:** one. `scripts/probes/build_recurring_jobs_xlsx.py` reads `recurring_jobs.json`; it works on the
  local copy, and in a fresh clone run `scripts/probes/fetch_recurring_jobs.js` first. Everything else that
  opens these paths writes them (`fetch_recurring_jobs.js`, archived generators; `build_multi_location_pdf.py`
  is itself one of the 56). `scripts/probes/audit_visit_dups.js` now creates `reports/` itself, since a fresh
  clone no longer has that folder. Older docs that name a `docs/backups/` file as a restore source point at a
  local-only copy now (`schema.md` and the pre-2026 DERM answer say so).

## 4. Traps hit today (keep these)

- 🛑 **After `git rm --cached`, a commit with a path list RE-TRACKS the files.** `git commit -- <paths>` (or
  `--pathspec-from-file`) takes those paths from the working tree, and the files are still on disk, so
  git keeps them. `6d7005f` was meant to untrack 56 files and committed only 4 edits; its message overstates
  it. Untrack by checking `git diff --cached --name-status` equals your list, then `git commit` with NO path
  list (other sessions' unstaged edits are not in the index, so they stay out). This is the one exception to
  "commit with a pathspec".
- A Grep/ripgrep search started at the workspace root finds nothing in the repos: the root `.gitignore` is
  an allowlist (`/*`), and ripgrep honours it. Search inside a repo folder, or use `grep -r`.
- `system-audit-2026-10-05/roq.mjs` prints the first 3,000 characters of every result. Never run a query
  that returns a code or secret through it with output visible.
- A bash heredoc can mangle backslashes in a script; write scripts with a file tool.

## 5. Still open

- **Fred's call, first:** the redaction diff labels each removed code with its client (section 2). The remedies
  are making this repo private sooner, or the clients changing those lock boxes; a history purge needs a
  force-push. Fred decided no client notices and private after the Railway move; this raises the stakes.
- Untracked scratch: about 716 probe outputs under `scripts/probes/` (`rev/`, `p2/`, `g6/`, `addr/`,
  `*.out.json`) are neither tracked nor ignored, one `git add -A` away from this public repo. Tracked as audit
  HYGIENE_APPS-02; removal and ignore rules are `CLEANUP_PLAN.md` S1, S2, S7 and F18.
- Step 6 of the plan (client emails, street addresses, business figures in `docs/company.md`) waits on
  Fred's answer about which `company.md` figures may stay.
- Step 7, a pre-commit guard plus a CI scan for passwords, tokens, codes and client files, is designed in
  `REPO_SCRUB_PLAN.md` 6.7 and not installed. It must run before the repo goes private.
- Going private: after the GitHub timed jobs move (`system-audit-2026-10-05/TIMED_JOBS_PLAN.md`) and the 3
  flows that read files from this repo by raw link move first: `scripts/shared-session/session-storage.ts`
  (all 8 staff apps), the Picture Planner `intake.html`, and John's Postman import link.
- Backups: PITR is OFF (measured 2026-10-05: `pitr_enabled=false`, one daily backup, 8 listed). Fred is
  choosing between PITR (about $100 a month) and an own copy on Railway; he asked whether it can be every 2
  hours. A fifth doc that claimed PITR (`jobber-backup-and-restore.md`) was corrected too.
