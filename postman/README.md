# Postman — GDO Online Reporting bot API

Ready-to-import Postman collection + environment for testing the GDO Online Reporting bot
endpoints (`rpa-derm-queue` / `rpa-derm-result`). Both are live Supabase Edge Functions.
Full API design: `../docs/handoffs/2026-07-21_rpa_bot_reply_to_john.md` and migration `2026-07-21g`.

## Files
- `gdo-reporting-bot.postman_collection.json` — 8 requests in 3 folders (Queue, Result, Validation),
  with tests and inline docs. Auth is one collection-level header `x-rpa-key: {{rpaBotKey}}`.
- `gdo-reporting-bot.postman_environment.json` — env `UnclogMe - RPA (Prod)` with a blank
  `rpaBotKey` (secret) to fill in.

## Import + run (workspace `8033927e-…`)
1. Postman → **Import** → drop both JSON files.
2. Select the **UnclogMe - RPA (Prod)** environment (top-right), and paste the bot key into
   `rpaBotKey`. The value is `RPA_BOT_KEY` in `Supabase/.env` (never commit it).
3. Run **1. Queue → Queue - dry-run** first — it returns real historical code-27 visits and
   captures a `visit_id` the Result requests reuse. Then run the rest top to bottom, or use the
   Collection Runner.

## Notes
- The **live** queue is empty until launch; the **dry-run** queue serves 29 real code-27 visits for testing.
- Result requests send `dry_run: true`, so they write separate rows that never touch the live queue,
  the customer portal, or the DERM Tracker. Clear them anytime:
  `DELETE FROM public.derm_portal_submissions WHERE dry_run;`
- Every request in this collection was verified end-to-end against the live API on 2026-07-21.
- The endpoint/table names are `rpa-derm-*` / `derm_portal_*` (accurate: reporting to the DERM
  portal). Say the word if you'd rather rename them to `gdo-report-*` before John integrates.
