# Claude Design Prompt — Upcoming Visits view

Paste the prompt below at https://claude.ai/design to generate the UI.

**Brand reference**: full UnclogMe design system is documented at
[`docs/research/unclogme-design-system.md`](../../docs/research/unclogme-design-system.md)
(prepared by Viktor for the Sales App, but the brand tokens apply to every
new UnclogMe app — same orange, same Manrope, same look).

A reference mockup of a *first-draft* shape lives in `_mockup-reference/`
(HTML + CSS + JS) — open `_mockup-reference/index.html` locally if you want
a quick visual baseline before iterating in Claude Design.

---

## The prompt (copy-paste this)

```
Build an "Upcoming Visits" dashboard for UnclogMe — a Miami-based commercial
grease-trap, drain-cleaning, and Lyft-station servicing company. The view is
read-only for now; ops uses it to see what's scheduled across the next 3
months without opening Airtable or Jobber.

BRAND (this app is part of the UnclogMe product family — match the Sales
App's established identity):

• Primary brand color: #f14714 (UnclogMe orange)
  - Hover/pressed: #c93a0f
  - Light accent: #ff6b3d
  - Pale background tint: #fff4f0
• Black: #1a1a1a (primary text + dark surfaces)
• Gray scale: #4a4a4a body-secondary · #8a8a8a captions · #e5e5e5 borders
• White / soft white: #ffffff base, #f8f8f8 soft surface
• Success green: #16a34a on #f0fdf4
• Danger red: #dc2626 on #fff1f0
• Font: Manrope (weights 300/400/500/600/700/800) for everything. Import
  from Google Fonts.
• Border radius base: 0.625rem. Buttons 4px. Badges/pills 999px (fully
  rounded). Cards 12px. Modals 12px.
• Max content width: 1140px centered. Page padding: 48px (desktop),
  24px (tablet), 20px (mobile).
• Dark mode supported via a `.dark` class on <html>. In dark: primary
  flips to a slightly lighter orange; background ~oklch(0.12 0.01 260);
  cards ~oklch(0.16 0.01 260); borders white-on-10%.

LAYOUT (single page, no nav rail needed — keep it focused):

• Header: brand mark on the left (orange rounded square + "UnclogMe" wordmark
  in Manrope 700), thin "Visits" sub-label, then a right-aligned live
  "N visits" counter.

• Toolbar row immediately below the header:
    - A search input ("Search by client, service, or date…") with a search
      icon on the left and brand-orange focus ring
    - A "Service" filter dropdown (options: All services, Grease Trap (GT),
      Cleaning (CL), Water Discharge (WD), Lyft Station (LS))
    - A "Zone" filter dropdown (options: All zones, then the 10 territory
      zones — SOUTH, DOWN, MIAMI BEACH, MID/EDG, SF/BH, AVE, NMB, BRO,
      PALM, WEST). When the user picks one, the visit list filters.
    - A segmented "Group by" control with three pills: "By day" (default),
      "By client", "By zone".

• Page heading: "Upcoming visits" — h1 in Manrope 800, ~32px, letter-spacing
  -0.5px
  Subheading (Manrope 400, muted gray): "Next 3 months · auto-generated from
  your service schedule every morning at 4:30 AM ET."

• Body: a stack of grouped sections. Each section has:
    - An eyebrow label in Manrope 700, 10px, letter-spacing 2px, uppercase,
      orange brand color (e.g., "TODAY", "TOMORROW", "IN 3 DAYS", or the
      client_code like "045-NU")
    - A bold section title (the full date in long form, or the client name)
      in Manrope 700, 18px, black
    - A right-aligned "N visits" count, Manrope 500, gray
    - A list of visit rows

• Visit row (one card per visit) shows:
    - LEFT: a pill badge with the service-type code (GT, CL, WD, LS) — see
      SERVICE COLORS below for each tint
    - MIDDLE: client display name as the primary text (e.g. "Vincenzo's
      Pizzeria"), Manrope 500, 15px, black. Secondary muted text below in
      Manrope 400, 13px, #8a8a8a: "{client_code} · {service-name}"
      (e.g. "174-VIN · Grease Trap")
    - RIGHT: status pill (typically "scheduled" — gray-blue tint), plus a
      large day-number with "{weekday-short} · {month-short}" beneath
      (e.g.  "12 / Wed · Jun"). Tabular numerals so day-numbers align.

• Empty state when filter yields nothing: a soft, centered message
  ("No upcoming visits match. Adjust the filters or check back tomorrow —
  the cron runs daily at 4:30 AM ET.") in Manrope 500, gray.

• Skeleton/loading state for when data is fetching: three subtle pulsing
  placeholder bars in the visit-row shape, using a #f5f5f5 → #fafafa
  shimmer animation.

SERVICE COLORS — tints for the service badges. The brand orange is reserved
for primary CTAs and the brand mark, so service badges use a complementary
palette that doesn't fight with it:

• GT (Grease Trap):    amber/yellow — text #b45309 on #fef3c7 background
                       Conveys "oil/grease"; matches the brand warmth.
• CL (Cleaning):       cool blue — text #1d4ed8 on #eff6ff background
                       Conveys "water/cleaning".
• WD (Water Discharge): purple — text #7c3aed on #faf5ff background
                       Distinct from CL while still in the "fluid" family.
• LS (Lyft Station):   emerald — text #15803d on #f0fdf4 background
                       Outdoor/station distinct from the indoor blues.

The status pill ("scheduled") uses a cool gray-blue: text #475569 on #f1f5f9.

ZONE COLORS — UnclogMe's 10 territory zones (canonical palette from the
Sales App brand system, applied identically here for consistency across
apps). Each visit's property has a `zone` value; use these as accent
hues for zone-aware UI.

• SOUTH        #ef4444   Homestead, Cutler Bay, Palmetto Bay, Pinecrest
• DOWN         #3b82f6   Downtown, Brickell, Coral Gables, Coconut Grove
• MIAMI BEACH  #8b5cf6   Miami Beach, Key Biscayne
• MID/EDG      #f59e0b   Wynwood, Edgewater, Little Haiti, Design District
• SF/BH        #06b6d4   Surfside, Bal Harbour, Bay Harbor Islands
• AVE          #f97316   Aventura, Sunny Isles (incl. "SUNNY" data — same zone)
• NMB          #eab308   North Miami, North Miami Beach, Miami Gardens
• BRO          #22c55e   All of Broward County
• PALM         #14b8a6   Palm Beach County
• WEST         #6366f1   Doral, Hialeah, Medley, Miami Lakes, Miami Springs

ZONE TREATMENT in the visit row + group view (pick whichever you think
reads cleanest; option B + C combined is what ops actually needs):

  (A) 4px colored stripe on the LEFT edge of each visit card, in the
      zone color. Subtle but instantly scannable.
  (B) Small rounded zone pill in the metadata row, next to client_code:
      [DOWN] · 174-VIN · Grease Trap
      The pill background is the zone color at 12% opacity; text is the
      zone color at 100%. Pill stays small (10–11px text).
  (C) "By zone" group header (when grouping=By zone):
      ─── DOWN · 16 visits ─── [horizontal accent line in zone color]
      The line is 2px, the eyebrow label uses the zone color.

Default both B + C ON when zones are visible. Skip A unless you find
the metadata pill feels light at glance distance.

DESIGN PRINCIPLES:

• Information-dense without feeling cluttered. Ops scans this in 30 seconds
  before driving to a job.
• Tabular numerals for dates and counts so columns align (font-variant-numeric).
• Generous vertical rhythm; cards have light borders and lift on hover (subtle
  shadow, no transform).
• Mobile-friendly — at small widths (<720px), the right column (status +
  date) collapses below the middle column with a 1px divider line.
• Modern, clean — think Linear / Stripe / Notion / Anthropic. Not corporate.
  Not gradient-heavy. No skeuomorphism.
• Brand orange used SPARINGLY — focus rings, the brand mark, the section
  eyebrow labels, and any primary CTA we add later. NOT on every card.

INTERACTIONS (visual states):

• Visit row hover: border darkens from #e5e5e5 → #d4d4d4, subtle 1-2px
  shadow lifts the card.
• Filter dropdown open: standard light menu, brand-orange highlight on
  hover within the menu.
• Search input focus: 2px orange ring (#f14714).
• Segmented toggle: pressed state has a white surface with subtle shadow on
  the #f8f8f8 track.

OUT OF SCOPE for this view (don't design these):

• Auth / login screens (handled separately by Lovable)
• Visit editing or status-change actions (this is read-only for now)
• Mobile route-planning maps (different app)
• Settings / admin
```

---

## Brand assets to upload in Claude Design

Drag-and-drop these into the canvas after pasting the prompt, so Claude
Design can lock in the brand:

| Asset | Purpose |
|---|---|
| `assets/unclogme-logo.png` (or `.svg` if you have it) | Brand mark — Claude Design auto-extracts palette + type from logos |
| Color seed | `#f14714` orange (Claude Design uses this if no logo is uploaded) |
| Font seed | `Manrope` from Google Fonts |
| GitHub link (optional) | `https://github.com/webunclogmecom/supabase` — for token-extraction passes |

The Sales App's full brand reference (Tailwind tokens, dark-mode OKLCH
values, typography scale, badge system, responsive breakpoints) is at
[`docs/research/unclogme-design-system.md`](../../docs/research/unclogme-design-system.md).

---

## After Claude Design produces the bundle

1. Click **Export → Handoff to Claude Code** in claude.ai/design
2. Copy the one-line handoff command Claude Design gives you
3. Paste it in a Claude Code session at this repo's root
4. Claude Code will land the HTML/CSS/tokens — it'll know to wire them to
   the data spec at [`apps/visit-view/DATA-SPEC.md`](DATA-SPEC.md)
