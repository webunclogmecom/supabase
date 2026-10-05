# Anthropic API usage (Claude models we call from our own code)

Last verified 2026-10-05. Read this before changing a model, adding a caller, or when something that
reads documents with Claude stops working.

## Who calls the API

| Caller | What it does | Model (since 2026-10-05) | Runs | Key |
|---|---|---|---|---|
| edge fn `gdo-permit-label` | reads "Permit Issued To" from a GDO permit PDF into `gdos.location_label` | `claude-opus-5-5`, effort low | on upload (triggers) + daily retry | Supabase secret `ANTHROPIC_API_KEY` (ends `rwAA`) |
| edge fn `ocr-address-sheet-number` | reads the printed sheet number (top right) of a scanned DERM address sheet | `claude-sonnet-5-5`, effort low | cron `sheet-number-ocr-sweep` + trigger on `derm_manifests` | same |
| edge fn `ocr-address-sheet-rows` | reads every Section B row (client code + facility name) of an address sheet | `claude-sonnet-5-5`, effort medium | cron `sheet-row-ocr-sweep` | same |
| `scripts/sync/*ocr*.js`, `scripts/checks/*` | hand-run backfills and checks (sheet numbers, receipts) | per script (`ocr_address_sheet_numbers.js` mirrors the edge fn) | only when someone runs them | `Supabase/.env` `ANTHROPIC_API_KEY` (same `rwAA` key) |
| Slack GDO Bot (`webunclogmecom/unclogme-gdo-bot`, Railway) | the GDO lookup agent in Slack, up to 15 tool rounds | `claude-sonnet-5-5` | per Slack question (~30/week) | Railway variable `ANTHROPIC_API_KEY`; the local `.env` holds a DIFFERENT key (ends `JgAA`) |

Nothing else uses it: no Lovable app, not the pdf-service, not the HR Sandbox or "frozen leads" Supabase
projects, no GitHub workflow (all checked 2026-10-05). The Supabase secret was proven equal to
`Supabase/.env` by comparing its SHA-256 digest (the secrets API returns digests, never values).

## Billing: why "credits"

The API is billed per token from the organization's **prepaid credit balance**, separately from any Claude
subscription. When it reaches zero every call fails with HTTP 400 `"Your credit balance is too low to
access the Anthropic API"` (seen 2026-10-05 ~10:54 UTC, mid-way through a permit backfill). All the callers
above stop at once, including the DERM Stamp sheet reading. Which workspace a key belongs to, and any
per-workspace spend limit, is visible only in the Anthropic Console (API keys page); a normal key cannot
report it.

What each caller does with a failed call, so nothing is lost:
- `gdo-permit-label`: records `outcome='error'` in `public.gdo_permit_label_reads`; a permit whose latest
  read is an error is retried by the next trigger or the daily sweep (up to 3 errors per file per 24 h).
- `ocr-address-sheet-number`: a non-`end_turn` reply writes nothing, so the page stays in the backlog and is
  retried within `derm.sheet_number_ocr_attempts`.
- `ocr-address-sheet-rows`: attempts are bounded by `derm.row_ocr_attempts` (3 per image set).

Rough cost at today's volumes: a few dollars a month in total. 30 days before the change: 17 sheet-number
reads, 68 sheet-row page reads; the permit reader runs only when a permit PDF changes.

## Changing a model

The model is one constant per caller: `const MODEL` in each edge fn's `index.ts`, `MODEL` in the bot's
`gdo_bot/claude_agent.py`. Edge fns go live on `supabase functions deploy <fn>`; the bot redeploys on
Railway when `main` is pushed (watch `gh api repos/webunclogmecom/unclogme-gdo-bot/deployments`).

🛑 **Measure before you switch, on pages whose answer is known.** "Stronger tier" is not evidence:
on 2026-10-05 `claude-opus-5-5` read the row reader's test set 36/37 and, 4 runs of 4, declined the tiny
printed code "249-LOU" (ticket-836200 page 1 row 3) as not sure, while `claude-sonnet-5-5` read 37/37. A
declined code is "no opinion" to the placement gate, so the stronger model would have held back a correct
stamp. The harness that settles it in minutes: load the function's own `index.ts` with Node's
`stripTypeScriptTypes` into a `vm` context, then call its `askVision` / `parseRows` / `classify` directly
against images whose stored reads you trust (`derm.address_sheet_scan_reads`,
`derm.address_sheet_row_reads`). That tests the exact request the function sends.

⚠ **Some request settings depend on the model.** Check them when you change it:
- `output_config.effort` is accepted by Opus 5.5 / Sonnet 5.5; **Haiku 4.5 rejects it** (400).
- Opus 5.5 and Sonnet 5.5 always think, and thinking counts toward `max_tokens`: keep headroom (the readers
  use 2048 / 16000 / 4000). A cut-off reply must never be treated as "unreadable"; both readers already
  refuse to classify a reply that did not stop with `end_turn`.
- `fallbacks: "default"` with header `anthropic-beta: server-side-fallback-2026-07-01` (all four callers
  send it) answers a refusal with another model inside the same call. It is valid for Opus 5.5 and, on the
  Claude API, Sonnet 5.5; remove it for a model that does not accept it.
- Sonnet 5.5 / Opus 5.5 return 400 on forced `tool_choice` (`any` / `tool`) and on `thinking: disabled`.
  The bot uses neither (its forced final answer sends `tools` + `tool_choice: none`).
- A model change resets the bot's prompt cache (caches are per model): the first few lookups cost a little more.
- `ocr-address-sheet-number` keeps `effort: low` because low and default gave identical answers on 8
  known sheets x 4 runs; re-run that comparison on any new model before keeping low.

## History

- 2026-10-05: sheet readers `claude-sonnet-5` -> `claude-sonnet-5-5` (Supabase `0ab1b3a`, `c69cb92`),
  bot `claude-sonnet-4-6` -> `claude-sonnet-5-5` (bot `a0b1ee1`), new `gdo-permit-label` on
  `claude-opus-5-5` (`be65ee5`, triggers `22e6647`). All four got the default refusal fallback.
