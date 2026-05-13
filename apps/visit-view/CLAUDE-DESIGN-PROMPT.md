# Claude Design Prompt — Upcoming Visits view

Paste the prompt below at https://claude.ai/design to generate the UI.
Upload the optional brand assets listed at the end so the canvas inherits
Unclogme's identity automatically.

A reference mockup of what we already have in mind lives in
`_mockup-reference/` (HTML + CSS + JS) — open `_mockup-reference/index.html`
locally if you want a quick visual baseline before iterating in Claude Design.

---

## The prompt (copy-paste this)

```
Build an "Upcoming Visits" dashboard for UnclogMe — a Miami-based commercial
grease-trap, drain-cleaning, and Lyft-station servicing company. The view is
read-only for now; ops uses it to see what's scheduled across the next 3
months without opening Airtable or Jobber.

LAYOUT (single page, no nav rail needed — keep it focused):

• Header: company brand mark + "Visits" wordmark on the left, a live "N
  visits" counter on the right.

• Toolbar row immediately below the header:
    - A search input ("Search by client, service, or date…")
    - A "Service" filter dropdown (options: All services, Grease Trap (GT),
      Cleaning (CL), Water Discharge (WD), Lyft Station (LS))
    - A segmented "Group by" control with two pills: "By day" (default) and
      "By client"

• Page heading: "Upcoming visits" — h1
  Subheading: "Next 3 months · auto-generated from your service schedule
  every morning at 4:30 AM ET."

• Body: a stack of grouped sections. Each section has:
    - An eyebrow label (e.g., "Today", "Tomorrow", "In 3 days", or the
      client_code like "045-NU")
    - A bold section title (the full date in long form, or the client name)
    - A right-aligned "N visits" count
    - A list of visit rows

• Visit row (one card per visit) shows:
    - LEFT: a pill badge with the service-type code (GT, CL, WD, LS) — the
      badge has a service-specific tint (see SERVICE COLORS below)
    - MIDDLE: client display name as the primary text (e.g. "Vincenzo's
      Pizzeria"), with secondary muted text below in the form
      "{client_code} · {service-name}" (e.g. "174-VIN · Grease Trap")
    - RIGHT: status pill (typically "scheduled" in blue), plus a large
      day-number with "{weekday-short} · {month-short}" beneath
      (e.g.  "12 / Wed · Jun")

• Empty state when filter yields nothing: a soft, centered message
  ("No upcoming visits match. Adjust the filters or check back tomorrow —
  the cron runs daily at 4:30 AM ET.")

• Skeleton/loading state for when data is fetching: three subtle pulsing
  placeholder bars in the visit-row shape.

SERVICE COLORS (use as accent tints on the service badges):

• GT (Grease Trap): amber — convey "oil/grease". Use a warm amber on a very
  light amber background.
• CL (Cleaning): blue — convey "water/cleaning". Use a confident blue on a
  very light blue background.
• WD (Water Discharge): purple — convey "fluid flow". Use a deep purple on a
  very light lavender background.
• LS (Lyft Station): green — convey "outdoor/station". Use a forest green
  on a mint background.

DESIGN PRINCIPLES:

• Information-dense without feeling cluttered. Ops scans this in 30 seconds
  before driving to a job.
• Tabular numerals for dates and counts so columns align.
• Generous vertical rhythm; cards have light borders and lift on hover.
• Mobile-friendly — at small widths, the right column (status + date)
  collapses below the middle column with a thin divider.
• Modern, clean — think Linear, Stripe, Notion. Not corporate. Not
  gradient-heavy. No skeuomorphism.
• Subtle accent for the brand color throughout interactive elements
  (focus rings, the brand mark, primary buttons if any get added later).

INTERACTIONS (visual states):

• Visit row hover: border slightly darker, faint shadow lifts the card.
• Filter dropdown open: standard light menu.
• Search input focus: brand-color border ring.
• Segmented toggle: pressed state has a white surface with subtle shadow on
  the dark/grey track.

OUT OF SCOPE for this view (don't design these):

• Auth / login screens (handled separately by Lovable)
• Visit editing or status-change actions (this is read-only for now)
• Mobile route-planning maps (different app)
• Settings / admin
```

---

## Brand assets to upload in Claude Design

If you don't have a logo file handy, the mark in the reference mockup is a
plain 24×24 rounded square in UnclogMe blue (`#1e40af`). Upload whatever
logo asset you have; Claude Design will extract palette + typography
automatically.

| Asset | Purpose |
|---|---|
| `assets/logo.svg` (or PNG) | Brand mark + automatic palette extraction |
| Color seed | `#1e40af` (UnclogMe blue) — if Claude Design asks for a starting hue |
| GitHub link (optional) | `https://github.com/webunclogmecom/supabase` — Claude Design can scan for tokens already in this repo |

---

## After Claude Design produces the bundle

1. Click **Export → Handoff to Claude Code** in claude.ai/design
2. Copy the one-line handoff command Claude Design gives you
3. Paste it in a Claude Code session at this repo's root
4. Claude Code will land the HTML/CSS/tokens — it'll know to wire them to
   the data spec at `apps/visit-view/DATA-SPEC.md`
