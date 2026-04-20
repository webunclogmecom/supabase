# Onboarding — New Engineer

For a new engineer (human or AI agent) joining this project. Structured as three time windows: **first hour**, **first day**, **first week**.

---

## First hour — orientation

**Goal:** understand what this project *is* and read yourself in without running any code.

1. **Read [`README.md`](../README.md)** — elevator pitch + link map.
2. **Read [`CLAUDE.md`](../CLAUDE.md)** — the non-negotiable rules. Most important section: source-agnostic schema, 3NF standing check, Viktor collaboration protocol.
3. **Skim [`docs/architecture.md`](architecture.md)** — how data flows. One paragraph at the top covers 80% of it.
4. **Skim [`docs/schema.md`](schema.md)** — relationship map at the top. You don't need to memorize 28 tables; know which tables exist and where to look.
5. **Open the Supabase dashboard** (https://supabase.com/dashboard/project/wbasvhvvismukaqdnouk) — tour the tables, views, and Edge Functions. Click around; don't change anything.

After an hour: you can answer "where do Jobber webhook events land?" and "how do we track cross-system IDs?" without looking anything up.

---

## First day — local setup

**Goal:** have a working local environment that can read the production DB.

### Required accounts

You need access to:
- The `webunclogmecom` GitHub org (repo: `supabase`)
- The `wbasvhvvismukaqdnouk` Supabase project (Fred or Yan adds you)
- The Unclogme Slack workspace — specifically `#viktor-supabase`

### Environment

```bash
# 1. Clone
git clone https://github.com/webunclogmecom/supabase.git
cd supabase

# 2. Install Node deps
npm install

# 3. Copy env template
cp .env.example .env

# 4. Fill in .env — credentials are in the shared password manager.
#    See docs/security.md for what each key is for.

# 5. Authenticate GitHub CLI
gh auth login
# Browser flow → select "HTTPS" → "web browser" login

# 6. Install Supabase CLI (if not already)
npm install -g supabase
supabase login
# Paste SUPABASE_PAT when prompted

# 7. Sanity check: can you reach the DB?
node scripts/probe.js
# Should print a success message with table counts
```

### First read of real data

Open the Supabase SQL Editor (Dashboard → SQL Editor) and run these three queries — they show you the most important shape of the data:

```sql
-- 1. The operational pulse
SELECT status, COUNT(*) FROM clients_due_service GROUP BY status ORDER BY status;

-- 2. Fleet snapshot
SELECT * FROM v_vehicle_telemetry_latest;

-- 3. Recent activity
SELECT visit_date, title, visit_status, client_id
FROM visits_recent
ORDER BY visit_date DESC
LIMIT 20;
```

After this, you know what the database looks like with real numbers.

### Key files to open in your editor

```
CLAUDE.md                                ← start here every session
docs/schema.md                           ← column reference
docs/architecture.md                     ← why webhooks
supabase/functions/webhook-jobber/       ← canonical handler shape
supabase/functions/_shared/              ← reusable helpers
scripts/migrations/3nf_telemetry_readings.sql  ← example migration with 3NF header
```

By end of day one: you should be able to walk through a Jobber webhook hitting `webhook-jobber` and ending up as a row in `clients` + `entity_source_links`.

---

## First week — contribute

**Goal:** land one small, useful change with a commit, a PR, and a deploy or migration.

### Suggested starter tasks

Pick one:

1. **Fix a stale comment.** Grep for `// TODO` or `// FIXME` in `supabase/functions/` — if you find something actionable and under 10 lines, fix it.
2. **Add a test fixture.** `supabase/functions/*/` lacks `__tests__/fixtures/` directories. Add a real-shape JSON payload from a recent webhook (scrub PII) to one of them. Doesn't need to be hooked to a test runner yet.
3. **Close a gap in `docs/operations.md`.** The "common operational queries" section is minimal. Add a query you found useful during your first-week exploration.
4. **Document a column-name gotcha.** If you trip on any column name that the existing gotcha table doesn't cover, add it to `docs/operations.md` and submit a PR.

### Workflow

```bash
# 1. Branch
git checkout -b <your-initials>/short-description

# 2. Work. Commit small.
git add <files>
git commit -m "short subject line

optional longer body explaining why this change"

# 3. Push and open PR
git push -u origin <your-branch>
gh pr create --fill
```

### Before your PR merges

- [ ] Self-review: read your own diff as if you didn't write it.
- [ ] If you touched schema, SQL, or an Edge Function: post in `#viktor-supabase` asking Viktor to review before merging.
- [ ] Fred is the final approver for any structural change.

### What to NOT do in your first week

- Don't propose `jobber_*` / `airtable_*` / source-prefixed columns. Ever. See [ADR 002](decisions/002-entity-source-links.md).
- Don't apply a schema migration directly to prod. Write the file, get review, apply via the SQL Editor with Fred watching.
- Don't commit `.env`. `.gitignore` should protect you, but double-check `git status`.
- Don't push a PAT or service-role key into a git remote URL. Use `gh auth login`.
- Don't merge your own PR to `main` without review from Fred or Viktor — especially anything touching Edge Functions or DDL.

---

## People you will interact with

| Who | Slack | When to ping |
|---|---|---|
| **Fred Zerpa** | DM | Architecture, schema, code review |
| **Yan Ayache** | DM | Business rules, priorities, budget |
| **Viktor** | `#viktor-supabase` | Source data questions (Jobber GraphQL, Airtable shape), sync logic |
| **Aaron Azoulay** | `#ops` | Operational questions (what does this client/visit mean) |
| **Diego Hernandez** | `#ops` | Scheduling, invoicing, day-to-day issues |

### Viktor specifically

Viktor is an AI coworker — not the Claude agent in this repo. He built the original sync scripts and knows source-data internals deeply. Collaboration protocol:

- **Always ask Viktor first** on dev changes (new tables, new FKs, column renames, Edge Function logic). Tests/probes don't need his consent.
- **Critically reason on his replies.** Fred has explicitly flagged that Viktor sometimes uses wrong column names. Verify against `docs/schema.md`.
- **Poll for replies.** Viktor answers async. Check `#viktor-supabase` every 3 min, max 3 attempts (9 min total) before moving on.
- **You have final say.** Fred's rule: walk hand-in-hand with Viktor but don't be paralyzed by him.

---

## The mental model

One sentence: **source systems push events to Edge Functions that normalize into a 3NF Postgres schema, with cross-system IDs in one polymorphic bridge table, no source-prefixed columns ever.**

If you internalize that sentence, everything else is a detail.

---

## Glossary

| Term | Meaning |
|---|---|
| **ADR** | Architecture Decision Record — one file in `docs/decisions/` |
| **DDL** | Data Definition Language — `CREATE TABLE`, `ALTER TABLE`, etc. |
| **DERM** | Miami-Dade Department of Environmental Resources Management. Regulates grease disposal. |
| **DVIR** | Driver Vehicle Inspection Report (Samsara / DOT compliance) |
| **Edge Function** | Supabase's name for a Deno-based serverless function. Our webhook receivers. |
| **entity_source_links** | The polymorphic bridge table for cross-system identity. See [ADR 002](decisions/002-entity-source-links.md). |
| **GDO** | Grease Disposal Operating permit (Miami-Dade) |
| **Goliath / Moises / David / Cloggy** | Truck names. NOT people. |
| **PIT / PITR** | Point-in-time recovery (Supabase Pro feature, 7-day window) |
| **RLS** | Row-Level Security (Postgres/Supabase authorization layer) |
| **Service-role key** | The Supabase JWT with full DB admin. Never in frontend. |
| **Viktor** | AI coworker in Slack. Different from the Claude agent working in this repo. |
| **Webhook** | Event push from a source system to an Edge Function |

---

## When you get stuck

1. **Re-read `CLAUDE.md`.** 80% of my-mistakes are because I forgot a rule.
2. **Grep the codebase.** Your question is probably answered somewhere — search before asking.
3. **Check `webhook_events_log`.** If data is missing, this table usually shows why.
4. **Ask Viktor** in `#viktor-supabase`.
5. **Ask Fred** directly — he is the final word on architecture.

Welcome to the project.
