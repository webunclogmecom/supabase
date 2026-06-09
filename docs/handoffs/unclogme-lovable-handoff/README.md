# Unclogme — Lovable handoff for Yannick

**For:** Yannick · **From:** Fred · **Snapshot date:** 2026-04-30

You're going to build new Unclogme apps in [Lovable](https://lovable.dev). Lovable is an AI-powered app builder — describe what you want in plain English, it generates a working React + Tailwind + Supabase app.

To give you maximum freedom while keeping the production system safe, you get your **own copy of the Unclogme database** — a Sandbox. It's a full clone of Unclogme's data: 445 clients, 3,888 visits, 1,670 invoices, 9,544 photos, 963 DERM manifests, all of it. You can read everything, write anything, add new columns, add new tables. When an app proves out, we promote your schema additions back to the production database.

---

## How it works

```
┌──────────────────────────────────────────────────────┐
│  Production Main DB (wbasvhvvismukaqdnouk)            │
│  ───────────────────────────────────────              │
│  • Single source of truth — webhook-driven from       │
│    Jobber, Airtable, Samsara                          │
│  • Photos in Storage bucket "GT - Visits Images"      │
│    (public-read, accessible from anywhere)            │
└────────────────────┬─────────────────────────────────┘
                     │
                     │ ① Fred clones data + schema → Sandbox
                     │ ② Periodic refresh keeps Sandbox current
                     ▼
┌──────────────────────────────────────────────────────┐
│  Your Sandbox DB                                      │
│  ───────────────────────────────────────              │
│  • Full clone of Main DB at clone-time                │
│  • You add new columns / tables freely                │
│  • Lovable connects HERE                              │
│  • Photos read via direct URLs to Main's public bucket│
└────────────────────┬─────────────────────────────────┘
                     │
                     │ ③ When an app stabilizes:
                     │    Fred ports your schema additions
                     │    to Main DB, app then runs against Main
                     ▼
                  Production
```

You only ever talk to ONE database from your Lovable apps. No cross-DB joins, no two-client setup. Standard Supabase patterns work directly.

---

## What you can build

The Sandbox already has everything about the business in it. Examples that just work:

- **Prospect search app** — find leads, classify clients as `Lead` / `Active` / `Discarded`. (You'll add a `client_type` column to `clients` for this — exactly the pattern.)
- **Client portal** — log in as a client, see service history, last manifest, next due date
- **Sales dashboard** — Aaron-facing, browse clients + 8K GDO prospects
- **Dispatcher view** — today's visits + truck location + manhole counts
- **DERM compliance UI** — search manifests, view photos, mark sent
- **Driver mobile** — at-a-client view, take photos on shift

Whatever you can prompt, the data is already there.

---

## The 4 things to read in order

1. **[01-SANDBOX-SETUP.md](01-SANDBOX-SETUP.md)** — get your Sandbox credentials, connect Lovable. 5 minutes.
2. **[02-WHAT-DATA-EXISTS.md](02-WHAT-DATA-EXISTS.md)** — quick tour of the 25 tables in your Sandbox.
3. **[03-EXTENDING-THE-SCHEMA.md](03-EXTENDING-THE-SCHEMA.md)** — the rules for adding columns, tables, and views so they merge cleanly back to Main DB later. **Read this before adding anything.**
4. **[04-EXAMPLE-PROMPTS.md](04-EXAMPLE-PROMPTS.md)** — copy-paste Lovable prompts for common features.

After those four you have 90% of the context. **[05-RULES.md](05-RULES.md)** is the one-page condensed version of the rules — pin it where you can see it while building.

---

## What's in this handoff

```
unclogme-lovable-handoff/
├── README.md                   ← you are here
├── 01-SANDBOX-SETUP.md         ← connect Lovable to your Sandbox
├── 02-WHAT-DATA-EXISTS.md      ← table-by-table tour of the data
├── 03-EXTENDING-THE-SCHEMA.md  ← how to add columns / tables that merge cleanly
├── 04-EXAMPLE-PROMPTS.md       ← Lovable prompts for common app features
├── 05-RULES.md                 ← five-line summary, pin this
├── .env.example                ← credential template
└── docs/
    ├── schema-quick.md         ← compact column reference per table
    └── source-of-truth.md      ← which source system owns what
```

No SQL files, no migration scripts, no Edge Function code. Lovable + the Sandbox handle that. You just describe what you want.

---

## Quick-start checklist

- [ ] Your Sandbox URL is `https://ubtlwpcyntelgbykdatn.supabase.co` (project: **Unclogme - Sandbox**)
- [ ] Get the `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` from Fred (DM)
- [ ] Open Lovable → new project → click **"Connect Supabase"** → paste URL + anon key
- [ ] Paste the contents of **LOVABLE-SYSTEM-PROMPT.md** into Lovable's Knowledge / AI Context settings
- [ ] Read **02-WHAT-DATA-EXISTS.md** — skim the table list so you know what you can query
- [ ] Try one of the prompts from **04-EXAMPLE-PROMPTS.md** to verify the connection works
- [ ] Read **03-EXTENDING-THE-SCHEMA.md** before adding your first new column or table
- [ ] Build something. Iterate. Send Fred a screenshot when there's a first version.

---

## Sandbox refresh & merge cycle

Your Sandbox is a snapshot — it doesn't auto-sync with Main DB after creation. When you want fresh data:

- **Periodic refresh** (every 1–2 weeks): Fred re-clones Main → Sandbox. Your schema additions are re-applied via the migrations Lovable tracks. Your test data is wiped (it gets replaced by the new Main snapshot).
- **On-demand refresh**: ask Fred. ~10 minutes for him to run.
- **Final merge**: when an app graduates, Fred ports your `migrations/` to Main DB and your app re-points to Main.

If you want stable test data that survives refreshes, keep it in tables you create (`my_test_leads`, `demo_dashboard_seeds`, etc.) — those are never wiped because they're new and not in the Main DB clone.

---

## Communication

- **Fred** — architecture decisions, schema review before merge, refresh requests · direct DM
- **Viktor** (Slack `#viktor-supabase`) — what columns mean, historical context, source-system questions

If Lovable's AI tells you to do something that contradicts **05-RULES.md**, push back. Lovable doesn't know our patterns or our merge plan; you do.

---

*The promise: you can build anything as long as your schema additions follow our conventions. Read **03-EXTENDING-THE-SCHEMA.md** to learn what those are. The rest of this handoff is reference material.*
