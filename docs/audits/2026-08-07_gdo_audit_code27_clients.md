# GDO permit audit: every client billed for "27 - GDO Online Reporting" (2026-08-07)

Fred: *"We need to do a deep audit on the GDO for the clients that have a line 27 GDO Online
Report. Use the GDO Bot on Slack and check the PDF for each one of them to try to see if they're
all correct and flag them the ones that are not."*

**Headline: every permit number, expiry and pump frequency we hold is correct.** All ten permits
across the seven clients were confirmed against DERM. Nothing we bill for online reporting is
filed against a wrong or lapsed permit.

**Three things were wrong, and none of them was a value.** Two were documents (one stale, one
missing) and one looked like a location binding.

> ✅ **ALL THREE ARE NOW CLOSED (2026-08-10).** Both documents were pulled from DERM and filed, so
> **all 10 active permits hold a document**. The third turned out **not to be a defect at all**:
> Claudie's two addresses are one site. See "RESOLUTION" below. The original findings are kept
> in full underneath, because the reasoning is why the obvious fix to the third one was wrong.

---

## Who is in scope, and why it is 7 clients

`27 - GDO Online Reporting` appears on **49 line items**, which split three ways:

| scope | rows | resolves to a client via |
|---|---|---|
| visit-scoped (`visit_id` set) | 33 | the visit |
| invoice-scoped (`invoice_id` set, no job, no visit) | 9 | neither, by design |
| job-scoped (`job_id` set) | 7 | the job |

⚠ **The 9 invoice-scoped rows are why a naive count looks like rows lost their client.** An
invoice line carries neither `job_id` nor `visit_id`, so an inner join through `jobs` drops them
and the arithmetic stops adding up. They are not orphans.

Job-scoped and visit-scoped rows together resolve to exactly **7 clients, all RECURRING**:
009-CN, 041-MB, 043-MIL, 082-TFC, 110-CLA, 111-YC, 168-AVA.

## Method: two layers, because they answer different questions

**Layer 1, our row against the PDF we hold.** Every `permit_document_path` was pulled from the
public `gdo-permits` bucket and parsed with `scripts/lib/gdo_permit_parser.js`. This answers *is
our data faithful to the document on file*, and nothing else.
✅ **Positive control:** `GDO-09853.pdf` was parsed first and asserted to yield a complete DERM
permit. Without it, "no parse failures" and "the parser is broken" look identical.

**Layer 2, the document against DERM.** Every address was put to the Slack GDO bot in
[#gdo-permit](https://unclogme.slack.com/archives/C0AL7A73DPY/p1786120173028959). This answers
*is the document still current*, which layer 1 structurally cannot: a PDF that parses perfectly can
be three years out of date, and one of them is.

⚠ **The bot ignores a thread follow-up that does not re-tag it.** The first follow-up in that
thread got no reply at all. Its documented handoff rule is to go silent when another bot is
mentioned, and the Slack app stamps *"Sent using @Claude"* on every message sent through the
connector, which trips exactly that rule. **Re-tag `@GDO` in every message**, including replies
inside a thread it is already answering in.

⚠ Each address was asked **individually**, not as one batch. The bot's own reference records a
56-client bulk fan-out on 2026-05-28 that misattributed permits and contradicted the same bot's
single lookups from three days earlier.

---

## Result

| client | permit | DERM (live) | our row | verdict |
|---|---|---|---|---|
| 009-CN Casa Neos | GDO-10877 KITCHENS | active to 2026-12-31, 60d | same | clean |
| 009-CN | GDO-15062 BARS | active to 2026-12-31, 90d | same | clean |
| 009-CN | GDO-16389 LOUNGE | active to 2026-12-31, 30d | same | clean |
| 041-MB Marie Blachere | GDO-14965 | active to 2026-12-31, 90d | same | ~~stale PDF~~ **FIXED 08-10** |
| 043-MIL Mila | GDO-11024 restaurant | active to 2026-12-31, 90d | same | ~~no PDF~~ **FIXED 08-10** |
| 043-MIL | GDO-14117 bar/lounge | active to 2026-12-31, 60d | same | clean |
| 082-TFC The Fresh Carrot | GDO-09853 | active to 2026-12-31, 30d | same | clean |
| 110-CLA Claudie | GDO-12517 | active to 2026-12-31, 90d | same | ~~wrong property~~ **NOT A DEFECT, one site, two addresses** |
| 111-YC Yann Couvreur | GDO-13263 | active to 2026-12-31, 90d | same | clean |
| 168-AVA AVA | GDO-15675 | active to 2026-12-31, 90d | same | clean |

**Service cadence against the permit ceiling: all seven compliant.** The tightest case is Casa
Neos, whose LOUNGE permit caps at 30 days and whose agreement runs at 30. Nobody is scheduled
looser than their permit allows.

---

---

## RESOLUTION (2026-08-10)

**Two of the three findings are CLOSED. All 10 active permits across the 7 clients now hold a
document (10 of 10).** The third is a recommendation, below, deliberately not acted on.

### ✅ 1 and 2 closed: both PDFs pulled from DERM and filed

Taken from the **authoritative source**, DERM's document API (the same endpoint and payload the GDO
bot uses), not re-uploaded from a Slack copy.

| row | client | was | now |
|---|---|---|---|
| 69 | 041-MB | `gdo/GDO-14965.pdf` (**the 2023 permit**) | `gdo/GDO-14965-uploaded-2026-08-10.pdf` |
| 230 | 043-MIL | **NULL** | `gdo/GDO-11024-uploaded-2026-08-10.pdf` |

**The audit's diagnosis was exactly right about Marie Blachere: DERM holds TWO documents for
GDO-14965**, one expiring 2026-12-31 and one 2023-12-31, and we had filed the 2023 one.

🛑 **Every document was PARSED AND ASSERTED BEFORE THE ROW WAS RE-POINTED** (number, expiry and
frequency all had to match the row, and it had to be a real DERM permit). Pointing a row at the
wrong document is worse than leaving it empty: it looks correct and nobody re-checks it.

Uploaded with `x-upsert: false`, so **nothing was overwritten** and the 2023 document survives at its
old path. `public.gdos` is audited, so `old_row` holds the previous value and either row is
individually revertible.

⚠ **Mila is filed at DERM under "800 LOCCOLN ROAD BUILDING"**, their typo for Lincoln. A
facility-name search for "MILA" returns 93 candidates and **0 matches**; the address search finds it
immediately. That is the bot's address-first design earning its keep.

### ✅ 3 CLOSED (2026-08-10): Claudie is ONE site with two addresses. Binding stays.

**Asked Diego directly, and his answer resolves what coordinates could not.** Verbatim:

> *"La entrada de la trampa de grasa está ubicada en la torre 1100. Pero la locación como tal es la 1101."*

**The grease trap is reached through the 1100 tower; the business itself is 1101.** So
1100 Brickell Bay Drive and 1101 Brickell Avenue are the **same site**, which is exactly the
"one building, two frontages" case the 80-metre measurement could not distinguish from
"two separate properties". Neither address is wrong, and **there is nothing to correct**.

**Outcome: the permit stays on property 38 and nothing was changed.** Diego's answer is now appended
to `gdos` row 2's notes, together with the reason, so the next person who notices the mismatch finds
the explanation rather than repeating the analysis. The note was **appended**, leaving the 2026-05 /
06 / 07 provenance intact.

🛑 **Property 501 must NOT be retired either.** My earlier recommendation offered that as an option
if it turned out to be a duplicate. **It is not a duplicate** — it is the real, permit-bearing address
of the business. Retiring it would delete the only record of where Claudie actually is.

The reasoning below is kept because it is why the obvious fix is wrong, and it still applies.

### 🛑 Why moving the permit would have been a regression (retained)

Moving `gdos` row 2 to property 501 (1101 Brickell Ave, the address DERM confirms) looks like the
obvious correction. **It would cause a client-facing compliance regression.**

`customer.permits` computes "last serviced", and therefore `over_gdo_max` and `compliant`, with:

```sql
WHERE v.client_id = g.client_id AND v.visit_status = 'completed' AND v.deleted_at IS NULL
  AND ( v.property_id = g.property_id
        OR lower(btrim(vp.address)) = lower(btrim(gp.address)) )
```

Measured for Claudie: the permit currently links to **7 completed visits via `property_id`**, and
**0 via the address string**. Move it to 501 and **both arms fail** (501 has 0 visits, and the two
address strings differ), so the compliance date goes NULL and the client's Field Portal loses its
DERM status. **A cosmetic address mismatch would become a real compliance regression.**

| | property 38 | property 501 |
|---|---|---|
| address | 1100 Brickell Bay Drive | 1101 Brickell Avenue s 113 |
| jobs / visits | **10 / 9** | 0 / 0 |
| holds the GDO | yes | no |

They are **80 metres apart**, both Jobber-linked, created 5 days apart. That is too close to call
"two different sites" and too far to call "one building, two frontages" from coordinates alone.

**What was decided (superseded by Diego's answer above, kept for the reasoning):**
1. **Now: change nothing.** The permit is correct, current, and its compliance link works.
2. **Ask the client which address Claudie actually operates from.** That is the only thing that
   resolves it, and it is a question for a person.
3. **If 501 is a duplicate, retire 501** (0 jobs, 0 visits, so it is free to retire). The
   discrepancy then disappears without ever touching the permit.
4. **Never option 3-from-the-other-direction**: do not move the permit to 501 while the visits are
   on 38.

⚠ **A wider fragility found while measuring this, worth its own look:** that address-string arm means
**anyone tidying the address text on either property silently breaks compliance** for whoever relies
on it. Across 136 active permits: 88 link by `property_id`, **2 link ONLY by the address string**,
and 46 link by neither (so their compliance date is already NULL). The 2 are the exposed ones.

---

## Flagged

### 1. 041-MB Marie Blachere: the PDF on file is the 2023 permit (`gdos` row 69)

`gdo/GDO-14965.pdf` parses cleanly and says **valid through 2023-12-31**. Our row says
2026-12-31, and DERM confirms 2026-12-31, so **the row is right and the document is three years
old**. Anyone who opens the attachment to prove compliance is looking at an expired permit.

This is the one finding layer 1 alone would have called a data error and layer 2 alone would
have called clean. Neither layer sees it by itself.

**Action:** download the current GDO-14965 from DERM and replace the document. The new
drag-and-drop on the GDO card makes this a ten-second job.

### 2. 043-MIL Mila: GDO-11024 has no document at all (`gdos` row 230)

The row is correct in every value (active to 2026-12-31, 90 days, confirmed by the bot on
2026-07-28 and again today) but `permit_document_path` is NULL. Mila's other permit, GDO-14117,
does have its PDF.

**Action:** upload the GDO-11024 PDF.

### 3. 110-CLA Claudie: the permit is bound to the wrong property row

`gdos` row 2 points at property **38, "1100 Brickell Bay Drive"**. The permit PDF header reads
**1101 BRICKELL AVE (101)**, and the bot resolved it explicitly: searching 1101 Brickell Avenue
returns `pdf_address_confirmed: true`, searching 1100 Brickell Bay Drive returns `false`.

A GDO attaches to a **physical location, not a business** ([CLAUDE.md, GDO permits](../../CLAUDE.md)),
so which property row it hangs off is the whole point of the record.

Claudie already has a second property row, **501, "1101 Brickell Avenue s 113"**, which matches
the permit. But row 38 is the one that is actually operated: **12 visits and 10 jobs** against
**0 and 0** for row 501.

🛑 **Do not act on this from the desk, and specifically do not do what the bot suggested.** Its
reply says *"The 1100 Brickell Bay Drive address should be removed from your records."* That is
the address we service, every visit and every job hangs off it, and deleting it would be a data
loss dressed up as a correction. The two addresses may well be two frontages of one building, in
which case nothing is wrong except which row the permit hangs on.
**Somebody who knows the site needs to say which it is.** Diego or Fred, not this audit.

---

## Housekeeping, lower priority

Three legacy rows are inert but misleading if anyone reads them literally:

| row | client | what it is |
|---|---|---|
| 164 | 009-CN | `gdo_number` = `"GDO-10877, GDO-15062, GDO-16389"`, INACTIVE, expiry 2025-12-04. Its PDF is actually just GDO-10877, valid to 2026-12-31. A pre-split combined row, superseded by rows 63/64/65. |
| 157 | 043-MIL | `gdo_number` = `"GDO-14117 / GDO-11024"`, INACTIVE. Its PDF is just GDO-14117. Superseded by rows 156/230. |
| 155 | 043-MIL | `gdo_number` = `"Needs review"`, INACTIVE, no frequency, no document. A placeholder nobody closed out. |

All three are INACTIVE, so no live surface reads them. Worth clearing when someone is in there
anyway, and worth knowing about before a future sweep counts "permits per client" and gets 4 for
a client that holds 3.

## Noticed while measuring, deliberately not chased

Every one of the seven clients has **two property rows at the same address**, one carrying all
the visits and jobs and one carrying none. Estate-wide that is **392 duplicate (client, address)
groups across 856 properties**.

⚠ I first read this as fallout from enabling the Jobber property poll on 2026-08-04. **It is
not.** These rows were created in April and May 2026 and *both* halves carry an
`entity_source_links` row, so they are two Jobber-side properties, not a local row plus a Jobber
twin. It is systemic, it predates the poll by three months, and it is nothing to do with GDO
permits. Recorded here only so the next person does not re-derive the wrong cause.
