# lwt-monthly: the rules of the monthly county report

`monthly-rules.ts` is the logic of the bot's `/monthly` page (`static/monthly.js` at
`d00636a`) with the DOM removed. The bot stays the engine. This file decides the POST
body sent to it, so a wrong port changes a county filing. The plan is
`Building Apps/DERM Tracker/docs/specs/2026-11-05-monthly-report-in-the-app.md`.

**The app's copy is byte-identical to this file. Never edit the app's copy.** Change this
one, run both checks, then download it again (the `session-storage.ts` pattern).

## The checks

```
node --experimental-strip-types run.mjs
```
Fast, on this machine, made-up data, plain asserts. It ends by breaking the module one
rule at a time and requires the suite to fail each time. Non-zero exit on any failure.

```
powershell -File golden/run-in-container.ps1 -MonthlyJs <path to monthly.js> -Work <empty scratch folder>
```
The proof. Runs the original page under a small DOM and this module side by side, the
same acts, and compares after every act: the body (`payload()`) byte for byte in its
key order, which is stricter than canonical JSON, the saved file, every flag, the
counts, the approval lock. Recorded sequences (`golden/sequences.mjs`), then 400 random
months. Then controls: an act dropped, a rule broken in a copy, the page itself changed;
each must fail. The script copies `monthly.js` into `-Work`, and the container has no
network, no capabilities, a read-only mount and no secrets. `run-golden.mjs` refuses to
run outside it. No bot source lives in this folder. It stops if the page's hash is not
the one it was proven against: re-read the page, then update `EXPECTED_SHA`.

`package.json` is here so Node reads `.ts` as a module (this repo's root says commonjs).

## The public API

`new MonthlyRules(ym)`. It holds what were the page's globals, under the same names
(`LOADS`, `FETCHF`, `PAPER_DATES`, `PAPER_DECALS`, `PAPER_FORM`, `INV_DECALS`, `INV_DATES`,
`ARCHIVED`, `PREVIEW_FINDINGS`, ...) and what were its fields (`ym`, `invoiceText`,
`invoiceId`). It mutates in place, as the page did: re-render after each act.

- Fetch: `adoptFetch(resp)` (a clean pull), `reload(resp)` (keeps departing acts)
- Invoice: `adoptDroppedInvoice(parsed, name, b64)`, `applyInvoiceParse(parsed, source)`,
  `invoiceTyping(text)`, `invoiceFinished(text?)`, `setInvoiceId(v)`, `addInvTicket(raw, decal?)`,
  `removeInvTicket(n)`, `acceptCandidate(n)`, `applyMonth(ym)`
- Ticks: `setIncluded(i, on)`, `matchInvoiceExactly()`
- Truck: `setLoadDecal(i, d)`, `useInvoiceDecal(i)`, `setNumberDecal(n, d)`, `setPaperDecal(t, v)`,
  `blockerSetDecal(i, v)`, `blockerLeaveOff(i)`
- Date: `useInvoiceDate(t)`, `undoInvoiceDate(t)`, `datedLines()`
- Hand rows: `addPaperLoad(num, offload, decal, {clients, pickup, offloadSrc})`, `clientFromVisit(v)`,
  `knownClients()`, `searchClients(q)`, the form `formFor`, `pfPick`, `pfPickVisit`, `pfTyped`,
  `pfRemove`, `pfPickup`, `pfOffload`, `addPaperFromForm(t)`, Edit `openPaperEdit`, `savePaperEdit`, `cancelPaperEdit`
- Archive: `archiveGuard(l)`, `archiveBody(t, reason, text, dup)`, `applyArchived(t, j)`,
  `applyRestored(t, j)`, `meetArchive(j)`
- Read: `payload()`, `blockingLoads()`, `decisions()`, `counts()`, `combinedFlagsByTicket()`, `invoiceOnlyTickets()`,
  `inWindowNotBilled()`, `invoiceWindow()`, `reportShape()`, `isHeld(l)`, `resolvedGallons(l)`, `heldClients()`, `blockOf(l)`,
  and each findings function
- Approval: `setPreviewResult(sentBody, findings, token)`, `flagsAreStale()`, `approvalDisabled`,
  `setApproved(on)`, `canGenerate()`, `generateBody()`, `setGenerated(sentBody, {id, tickets, list})`, `recordBody()`
- Saved work: `savedFileBody()` (`schema: 2`, a live reference: stringify it), `adoptSavedFile(j)`,
  `applySavedReread(inv, parsed)`, `rereadFailed(inv)`
- Exported: `configDrift(configJsText)`, `RULE_INFO`, `DECAL_GALLONS`, `PRICE_TO_DECAL`, `RECEIPT_RULES`,
  `NO_TICKET_KEY`, `ruleInfo`, `parseTickets`, `monthLabel`, `explainError`, `recordOutcome`, `filingList`,
  `bytesToB64`, `b64ToBytes`

## Standing check for the vocabulary

`configDrift(text)` takes the text of a live `/monthly/config.js` and returns one line per
difference from the tables here; `[]` is no drift and text it cannot read is a drift.
`PRICE_TO_DECAL` is not served there, so it cannot check that one. The tables were read
from the bot's Python at `d00636a` by parsing it, not by running it.

## Rules kept as they were, though they look odd

- A change back does not unlock approval. Only a new check opens it.
- "Leave it off" (`blockerLeaveOff`) sets no hand mark, so the next read of the invoice ticks the row again if the paper bills it.
- A truck named in "Gallons missing" (`blockerSetDecal`) does not pin and is not validated, unlike `setLoadDecal`.
- `setIncluded` can tick a held row. The old page never offered a checkbox there, so the page must not either.
- The bot's token does not cover `candidate_pool`, whatever the old comment says, though the page's own staleness check does.
- `invoiceWindow` compares date strings, so a `09/11/2026` date would sort wrongly. The feed sends ISO.

## Traps for the page

- `reload` starts Dade ticks over. Run it when a person presses Reload, not on every open after `adoptSavedFile`.
- With no paper to re-read (`invoice.source` null) the truck and date cross-checks stay silent, and the body can differ
  from the one saved, until the invoice is dropped again. `adoptSavedFile` asks for a re-read when `source.b64` is a string.
- `setPreviewResult` needs the body that was POSTed, not a fresh `payload()`.

## What changed from the old page, on purpose

Only for a client picked from a real visit (`clientFromVisit`, `_src: 'picked'`, `_from: 'visit'`):
the pickup comes from the visits (their latest date), and `manual_load_from_paper` reads
`pickup <date> from the visit` and `N clients picked from recorded visits` where the old words
(`typed`, `from this month's list`) would be false. With no visit every word is the old one.
`decisions()` is new and read-only, and keeps its "not on the paper" items after a check, where
the old page hands those over to the server's voice.
