# DERM Tracker email send gates

*Spec, 2026-09-03. Three changes Fred asked for, one of which turns out to close a real hole.*

## What Fred asked

> *"include service photos checkbox at the derm app should be checked by default, but we should have
> a verification to make sure we first have images classified, if we don't then disable it. also the
> checkbox is not aligned. Another thing we shouldn't be able to send an email from the DERM App if
> the manifest isn't blackedout meaning we also need a way to verify if the manifest is blackedout."*

## What is true today, measured before designing

| | |
|---|---|
| live manifests | 685 |
| blacked out (a `derm.redacted_manifest_docs` row exists) | 665 |
| **NOT blacked out** | **20** |
| `authenticated` can read `derm.redacted_manifest_docs` | **no** |
| `public.v_visit_photo_counts.classified_images` exists and is readable by the app | **yes** |
| DERM Tracker reads any of this today | **no** |

🛑 **THE CITY PATH ALREADY REFUSES; THE CLIENT PATH DOES NOT.** `send-derm-email` guards the city
send on `no_redacted_sheet` and skips. The client loop has **no redaction check at all**. So today a
customer can be mailed a Service Report whose FOG manifest section is missing, because that section
IS the redacted document (`customer.work_orders.derm_manifest_url` is
`derm.redacted_manifest_docs.url`). Fred's ask closes a real hole, not just a UI gap.

⚠ **The photos checkbox is a no-op on a visit with nothing classified.** The report's before/after
sections come from `public.photo_classifications.service_phase`, not from `photo_links.role` (every
role in the estate is `other` or `attachment`). Measured: visit 6347 has 42 photos, 0 classified, and
renders a byte-identical 271 KB PDF with the flag on or off. So disabling the checkbox there is not
cosmetic - it stops the operator making a choice that cannot have an effect.

## Design

### 1. One view, `public.v_derm_manifest_email_readiness`

Per manifest, everything the dialog needs to decide what to enable:

| column | meaning |
|---|---|
| `manifest_id`, `client_id`, `white_manifest_number` | keys the app already has |
| `is_blacked_out` | a `derm.redacted_manifest_docs` row exists |
| `classified_images` | summed across the manifest's visits |
| `has_classified_photos` | `classified_images > 0` |
| `send_blocker` | `'not_blacked_out'`, else NULL when sendable |

**Why a view and not a join in the app:** `authenticated` cannot read
`derm.redacted_manifest_docs`. An owner-rights view (no `security_invoker`) launders that grant,
which is the established schema-per-app pattern here.

🛑 **No SECURITY INVOKER function may go inside it.** That adds an invoker-side EXECUTE check to the
read path and produced a `42501` on `pg_read_all_data` once already (`2026-08-25_1400`). Plain SQL
only.

⚠ `send_blocker` deliberately does NOT include "no classified photos". That is not a reason to block
a send; it is a reason to disable one checkbox. Conflating them would stop 665-blacked-out manifests
being emailed just because nobody classified their photos.

### 2. Server: the client path gets the same guard

Mirror the city path's `no_redacted_sheet` skip into the client loop. The UI gate is a browser-side
check and this estate's rule is that a browser check is half a gate.

### 3. App: three changes to the DERM Tracker

1. **Send disabled when not blacked out**, on BOTH dialogs, with the reason visible rather than a
   dead button: *"This manifest has not been blacked out yet. The Service Report embeds the redacted
   sheet, so it cannot be sent until the blackout is published."*
2. **Photos checkbox disabled when `has_classified_photos` is false**, and unchecked in that state so
   the request honestly sends `include_photos: false`. Helper text says why:
   *"No photos have been classified for this visit yet, so the report has none to include."*
   Default stays **checked** whenever photos do exist.
3. **Alignment**: the checkbox and its label are not on a shared baseline.

## Step by step, each verified before the next

| # | step | how it is verified |
|---|---|---|
| 1 | create the view + grant | query it for a blacked-out manifest (1763), a non-blacked one (1719), and a blacked one with 0 classified (1750); assert `authenticated` can SELECT and that the numbers match an independent recomputation |
| 2 | client-path redaction guard | a real gated client send for manifest **1719** must come back `skipped / no_redacted_sheet`; a send for **1774** must still succeed |
| 3 | app gating + alignment | open both dialogs on 1763 (enabled, checkbox on), 1750 (enabled, checkbox disabled), 1719 (send disabled); screenshot each |

### Fixtures

| manifest | client | blacked out | classified | expected |
|---|---|---|---|---|
| 1763 | 009-CN | yes | 39 | send enabled, checkbox enabled and checked |
| 1750 | 238-PV | yes | 0 | send enabled, **checkbox disabled** |
| 1719 | 029-JOS | **no** | 0 | **send disabled** |
| 1718 | 092-TCE | **no** | 6 | **send disabled** (photos are irrelevant when not blacked out) |

⚠ All three non-blacked fixtures sit on ticket **833049**, which is frozen by a CHECK constraint on
purpose (its `ticket_page_images` array is corrupted by a page=2 card, see `CLAUDE.md`). That makes
them stable test fixtures: they are not about to become blacked out under the test.

## Out of scope

- The `pdf_service_504` on photo-heavy renders. Pre-existing, unrelated, still outstanding.
- The client dialog's stale **preview** text in the app. The server letter is fixed; the preview
  block in the DERM Tracker still shows the old wording.
