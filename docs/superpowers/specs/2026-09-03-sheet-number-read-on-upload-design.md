# Sheet-number reads: event-driven, once per page, self-re-arming

*Spec. 2026-09-03. Fred: "it should only be done once per manifest (in all its pages), unless there
is an update of the manifest (like adding, deleting pages, etc)... so instead of a cron, maybe a
trigger, when a manifest (with its pages) gets uploaded on the DERM App, it should happen."*

## The problem in one paragraph

Every DERM scan has a sheet number printed in the corner (`1106-1`, `1108-2`, or a bare pad number
like `338`). It is the ONLY thing that establishes which physical page each stored scan is, and that
governs where every stamp lands and which scan a client's redacted document is cut from. A cron is
supposed to read it. **It has been a structural no-op**: `derm.fn_sheet_number_ocr_targets()` returns
0 rows estate-wide (positive control: `_for(ARRAY['834742'])` returns 1 row, so the machinery works).
Arm A needs an unplaced card and there are none; Arm B is documented SELF-DRAINING and every folder
it covers has been read once. A reversed scan pair can therefore never be auto-detected again, and a
reversed pair is exactly what put every stamp on the wrong scan on `ticket-833813`, `ticket-312433`
and `ticket-833049`.

## Why the current predicate cannot express Fred's rule

Both arms ask **"has this folder/page ever been read?"**:

```sql
not exists (select 1 from derm.address_sheet_scan_reads sr
             where sr.dump_folder = p.dump_folder and sr.page = g.ord)
```

`image_url` is not compared. So once a page has any read, it is never offered again **even if the
image at that position changed**. Deleting a page shifts every later position onto a different
scan, and the stale reads keep asserting the old mapping. That is a silent wrong answer, and it is
the failure this design removes.

## The rule, expressed as a derived condition

> An image position needs reading **iff** no scan read names the image that is at that position
> **now**.

```sql
not exists (select 1 from derm.address_sheet_scan_reads sr
             where sr.dump_folder = p.dump_folder
               and sr.page       = g.ord
               and sr.image_url  = g.url)     -- <- the whole change
```

This is Fred's rule exactly, and it needs no state to maintain:

| event | effect on the predicate |
|---|---|
| manifest uploaded with N pages | N positions with no read -> N reads, once |
| nothing changes | every position matches -> **no work, forever** |
| a page is added | the new position has no read -> read it |
| a page is deleted | later positions now hold a different URL -> those re-read |
| a scan is replaced | the URL at that position changes -> re-read |

**It is also self-healing.** A trigger-fed queue misses any write that bypasses the trigger, and this
estate backfills these tables by SQL constantly. A derived predicate cannot miss one.

## Trigger or cron: both, with different jobs

A trigger cannot do the reading. The read is a vision call over HTTP; it must not sit inside the
operator's upload transaction, and a fire-and-forget failure from a trigger is lost silently. The
estate already has the right shape (`trg_properties_enqueue_outbound` records intent, a worker
drains it).

- **Trigger** on `public.derm_manifests` (INSERT, or UPDATE of the image columns) provides
  IMMEDIACY. It fires once per statement and only when the backlog is non-empty.
- **Derived predicate** is the source of truth.
- **Cron stays**, at a low frequency, as the safety net. It normally finds nothing and makes no HTTP
  call, the same shape as `city-email-sweep` (measured there at 1.5 seconds of DB time per day).

## The retry bound, and why it is narrower than I first thought

The handler writes a row **even when the number is unreadable** (`confidence: 'unreadable'`,
`sheet_no_read: null`), and that row carries `image_url`. So the derived predicate **self-drains
after one attempt on any page the handler actually reaches** - no ledger needed for that.

The exception path is the gap. On a failed image fetch or a vision error the handler does
`continue` without writing ("leave it unread; the gate treats no read as no opinion"). Those pages
would be retried for ever.

⇒ `derm.sheet_number_ocr_attempts`, keyed `(dump_folder, page, image_url)`, bounds only that path.
Because `image_url` is IN THE KEY, replacing a scan re-arms it automatically, with no expiry logic.

**The attempt is recorded when the target is HANDED OUT, not when the worker reports back.** That is
deliberate: it gives at-most-N semantics without trusting a worker that may die mid-call. The cost is
that a target handed out and never processed still counts, which is the fail-safe direction.

## Scope: deliberately unchanged, with a gap reported rather than silently closed

The current functions filter `dump_folder like 'ticket-%'`, justified on the grounds that
`window<N>-sheet<M>` folders have no generated-sheet link so "a read can never be used".

🛑 **That is the same premise Arm B was created to refute** - it is true for auto-placement and false
for page identity. Measured:

| folder shape | multi-image positions | unread | folders |
|---|---|---|---|
| `ticket-%` | 42 | **0** | 20 |
| `derm/*` | 11 | **0** | 4 |
| `window*` | 35 | **35** | 17 |

**Those 17 `window*` folders serve 157 client documents**, and `window*` accounts for 371 of the 677
served documents overall. Their page mapping has never been checked by machine.

**This change does NOT widen the scope**, because that is a client-facing decision with a real cost
and a real risk, not a repair:
- 35 vision calls of historical handwritten pads whose reads may be garbage (a first run once read
  `window12-sheet9` as `224`).
- Mitigating fact: `derm.fn_sheet_image_position` only honours a **high-confidence read with a
  `-N` suffix**, so unsuffixed noise like `224` is inert. A garbage read that happened to carry a
  suffix would not be.

⇒ The gap is surfaced by `derm.v_sheet_number_ocr_backlog` (which is scope-free) so it is visible and
countable, and it is Fred's call whether to read them.

## Re-placement: capability, not automation

The deeper half of the `ticket-834742` bug is timing. The card was filed at 12:20:39 and the OCR ran
**9 minutes 24 seconds later**, so `fn_sheet_image_position` was empty at filing and the identity
fallback was used. Even a trigger cannot guarantee the read beats the filing.

Since `2026-09-03_1510` a missing map no longer corrupts anything - `trg_autoplace_generated` simply
does not place the card. So the failure mode is now a **silently unplaced card** rather than a
wrongly-placed one.

🛑 **Unattended re-placement is NOT shipped.** Auto-placement is the mechanism that put every stamp
on the wrong scan on three folders; adding a second, unattended path that fires later, on data whose
page map has just changed, is how that class of defect returns. What ships instead:

- `derm.v_cards_awaiting_page_map` - the detector: unplaced cards on folders whose map has since
  resolved. Empty is healthy.
- The existing manual `_for(...)` escape hatch is untouched and stays unbounded.

## Objects

| object | kind | purpose |
|---|---|---|
| `derm.sheet_number_ocr_attempts` | table | bounds the exception path; keyed on the image URL so a replaced scan re-arms |
| `derm.v_sheet_number_ocr_backlog` | view | the derived predicate, scope-free, countable |
| `derm.fn_sheet_number_ocr_targets(int)` | function | REPLACED: reads the backlog, applies scope + attempt bound, records the attempt |
| `derm.v_cards_awaiting_page_map` | view | unplaced cards whose page map has since resolved |
| `public.fn_request_sheet_number_ocr_if_backlog()` | function | posts only when there is work |
| `trg_zz_request_sheet_number_ocr` | trigger | on `public.derm_manifests`, per STATEMENT, for immediacy |

## How it is tested

The relevant scope has **0 backlog today**, so a passing install proves nothing. The migration builds
a **synthetic two-page folder inside a rolled-back transaction** and drives the whole state machine:

1. two positions, no reads -> backlog **2**, targets offers 2
2. record a read for position 1 naming the image at position 1 -> backlog **1**
3. record a read for position 2 naming the **wrong** image -> still backlog 1 (the url must match)
4. fix it -> backlog **0**, targets offers nothing (**Fred's "once per manifest" rule**)
5. change the image at position 2 -> backlog **1** again (**his "unless the pages change" rule**)
6. burn 3 attempts -> targets stops offering it, backlog still reports it (visible, not silently
   dropped)
7. replace the image -> attempts key changes -> offered again
8. MUTATION CONTROL: the old read-presence predicate must NOT detect case 3 or case 5, or the new
   one is untested
9. the trigger fires exactly once per statement, and not at all when there is no backlog
