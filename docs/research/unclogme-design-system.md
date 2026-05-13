# UnclogMe Sales App — Full Context for Claude Design

> This document contains everything needed to understand, replicate, or extend the UnclogMe Sales Portal app. Use it as a reference when building new apps for UnclogMe.

---

## 1. Company Context

### About UnclogMe
- **Full Name**: UnclogMe LLC
- **Industry**: Drain cleaning, grease trap service, plumbing
- **HQ**: 650 NW 33rd Street, Miami, FL 33127
- **Website**: https://unclogme.com
- **Phone**: +1 (305) 339-5638
- **Email**: contact@unclogme.com
- **Territory**: Miami-Dade (150+ clients), Broward (27+), Palm Beach (9+)
- **Founded**: 2023 by Aaron Azoulay

### What They Do
- **Residential**: Drain unclogging ($225), hydro jetting ($349), camera inspections ($399)
- **Commercial**: Grease trap cleaning ($249–$1,400+/visit), recurring drain line cleaning, DERM compliance
- **Recurring GT frequencies**: 30 / 45 / 60 / 90 / 120 days
- **DERM Licensed Hauler**: Permit #1404-25

### Key Team
| Name | Role |
|------|------|
| Aaron Azoulay | Founder / Owner / Field Ops / Sales |
| Yannick Ayache (Yan) | Founder / Owner / Growth & Strategy |
| Fred Zerpa | COO / CTO (software, process, workflow) |
| Diego Hernandez | Manager (schedules, invoices, client comms) |

### Software Stack
| Tool | Purpose |
|------|---------|
| Airtable | Master CRM (clients, visits, routes, DERM, leads) |
| Jobber | Field scheduling, invoicing, job tracking |
| Samsara | GPS + fleet tracking |
| Trello | Task management |
| Ramp | Expense management |
| QuickBooks | Accounting |
| Supabase | Database (preferred for new apps) |

### Fleet
| Name | Vehicle | Capacity | Role |
|------|---------|----------|------|
| Cloggy | Toyota Tundra 2020 | 126 gal | Day / small residential |
| David | International 2017 | 1,800 gal | Night commercial |
| Moise | Kenworth T880 2023 | 3,800 gal grease / 1,200 gal water | Night GT primary |

### Compliance
- Miami-Dade DERM GDO permits required for all commercial grease trap operations
- Fines: $500–$3,000 per missed cycle (Miami-Dade Code Sec. 24-42.6, 24-46, 21-49.2)
- GDO manifests filed per visit (DADE: 481xxx, BROWARD: 294xxx)

---

## 2. Tech Stack

### Framework & Build
| Layer | Technology | Version |
|-------|-----------|---------|
| Frontend | React | 19.2 |
| Build tool | Vite | 7.2 |
| Language | TypeScript | 5.9 |
| Package manager | Bun | latest |
| Linter/formatter | Biome | 2.3 |

### Styling
| Tool | Details |
|------|---------|
| Tailwind CSS | v4 (CSS-native, `@theme inline`) |
| shadcn/ui | 53 components (see list below) |
| Framer Motion | Animation library |
| Custom CSS | Heavy use for presentation slides |

### Backend
| Tool | Details |
|------|---------|
| Convex | Real-time database + backend functions |
| Convex Auth | Email/password authentication (dev/preview only for test user) |

### Maps
| Tool | Details |
|------|---------|
| Leaflet | 1.9.4 — interactive maps |

### Deployment
| Service | Details |
|---------|---------|
| Vercel | Frontend hosting |
| Convex Cloud | Backend hosting |

### Key Dependencies
```
react, react-dom, react-router-dom, convex, @convex-dev/auth
tailwindcss, tw-animate-css, tailwind-merge, class-variance-authority, clsx
@radix-ui/* (full suite), lucide-react, recharts, sonner, vaul
leaflet, framer-motion, react-hook-form, zod, date-fns, cmdk
```

---

## 3. Design System

### Brand Colors

#### UnclogMe Brand Palette
```css
--uc-orange:       #f14714    /* Primary brand orange */
--uc-orange-dark:  #c93a0f    /* Hover/pressed states */
--uc-orange-light: #ff6b3d    /* Lighter accent */
--uc-orange-pale:  #fff4f0    /* Subtle backgrounds */
--uc-black:        #1a1a1a    /* Primary text / dark backgrounds */
--uc-gray:         #4a4a4a    /* Secondary text */
--uc-light-gray:   #8a8a8a    /* Muted text / captions */
--uc-border:       #e5e5e5    /* Borders */
--uc-bg:           #ffffff    /* White background */
--uc-bg-soft:      #f8f8f8    /* Soft gray background */
--uc-green:        #16a34a    /* Success / on-schedule */
--uc-green-bg:     #f0fdf4    /* Success background */
--uc-red:          #dc2626    /* Danger / off-schedule / fines */
--uc-red-bg:       #fff1f0    /* Danger background */
```

#### shadcn/ui Theme Tokens (Light Mode — OKLCH)
```css
--primary:              oklch(0.56 0.22 38)   /* Maps to brand orange */
--primary-foreground:   white
--background:           oklch(0.985 0 0)       /* Near-white */
--foreground:           oklch(0.15 0.01 260)   /* Near-black */
--card:                 oklch(1 0 0)           /* Pure white */
--secondary:            oklch(0.96 0.005 260)  /* Light gray */
--muted:                oklch(0.96 0.005 260)
--muted-foreground:     oklch(0.45 0.015 260)
--accent:               oklch(0.96 0.005 260)
--destructive:          oklch(0.55 0.22 25)    /* Red */
--border:               oklch(0.92 0.005 260)
--ring:                 oklch(0.3 0.02 260)
--radius:               0.625rem
```

#### Semantic Colors
```css
--success:    emerald-600 / emerald-400 (dark)
--warning:    amber-500 / amber-400 (dark)
--info:       cyan-500 / cyan-400 (dark)
```

#### Chart Palette
```css
--chart-1: teal-500    --chart-2: orange-500    --chart-3: cyan-500
--chart-4: rose-500    --chart-5: lime-500
```

#### Dark Mode
Dark mode is supported via `.dark` class on `<html>`. In dark mode:
- Primary flips to white with slate-900 foreground
- Background becomes `oklch(0.12 0.01 260)`
- Cards: `oklch(0.16 0.01 260)`
- Borders: `oklch(1 0 0 / 10%)`

### Typography

#### Primary Font
```css
font-family: 'Manrope', sans-serif;
```
- Imported from Google Fonts: `Manrope:wght@300;400;500;600;700;800`
- Used throughout the entire app — all body text, headings, buttons, labels

#### Secondary Font (Map Section Only)
```css
font-family: 'DM Sans', sans-serif;        /* Map labels, legend, captions */
font-family: 'Cormorant Garamond', serif;   /* Map section title */
```

#### Typography Scale
| Element | Size | Weight | Extras |
|---------|------|--------|--------|
| Cover title | `clamp(40px, 5vw, 68px)` | 800 | `letter-spacing: -1.5px` |
| Slide title | `clamp(26px, 3.5vw, 38px)` | 800 | `letter-spacing: -0.5px` |
| Eyebrow labels | `9–10px` | 700 | `letter-spacing: 2–3px`, uppercase |
| Body text | `13–15px` | 400–500 | |
| Table headers | `9px` | 700 | `letter-spacing: 2px`, uppercase |
| Table body | `14px` | 400–700 | |
| Badges | `11–12px` | 600 | |
| Fine amounts | `16px` (cell), `52–54px` (hero) | 800 | |
| Sidebar labels | `13px` | 500 | |
| Group labels | `10px` | 700 | `letter-spacing: 0.08em`, uppercase |

### Spacing & Layout
- **Max content width**: `1140px` (centered with `margin: 0 auto`)
- **Horizontal padding**: `48px` (desktop), `24px` (tablet), `20px` (mobile)
- **Border radius**: `0.625rem` base, buttons `4px`, badges `20px`/`999px`, cards `12px`, modals `12px`
- **Sidebar width**: `16rem` (expanded), `3rem` (icon only)

### Badge System
```css
.badge-green  { bg: #f0fdf4, color: #16a34a, border: rgba(22,163,74,0.2) }
.badge-red    { bg: #fff1f0, color: #dc2626, border: rgba(220,38,38,0.2) }
.badge-gray   { bg: #f5f5f5, color: #888,    border: #e0e0e0 }
.badge-blue   { bg: #eff6ff, color: #1d4ed8, border: rgba(29,78,216,0.2) }
.badge-purple { bg: #faf5ff, color: #7c3aed, border: rgba(124,58,237,0.2) }
```

### Icons
- **Library**: Lucide React (`lucide-react`)
- **Size**: Typically `16px` in sidebar, `18–22px` in status indicators
- **Status emojis**: 🟢 (≤10 min), 🟡 (10–20 min), 🔴 (>20 min), ✅, ⚠️, 🔥

---

## 4. Component Architecture

### Available shadcn/ui Components (53)
```
accordion, alert, alert-dialog, aspect-ratio, avatar, badge, breadcrumb,
button, button-group, calendar, card, carousel, chart, checkbox, collapsible,
command, context-menu, dialog, drawer, dropdown-menu, empty, field, form,
hover-card, input, input-group, input-otp, item, kbd, label, menubar,
navigation-menu, pagination, popover, progress, radio-group, resizable,
scroll-area, select, separator, sheet, sidebar, skeleton, slider, sonner,
spinner, switch, table, tabs, textarea, toggle, toggle-group, tooltip
```

### Custom Components
| Component | Purpose |
|-----------|---------|
| `AppLayout` | Main layout wrapper (sidebar + content area via `<Outlet>`) |
| `AppSidebar` | Left sidebar with nav, tools list, presentations list |
| `Header` | Sticky top header with logo + "Sales Portal" label |
| `MapSection` | Leaflet map with client pins (orange) + prospect pins (black) |
| `PublicLayout` | Layout wrapper for public (unauthenticated) pages |
| `ErrorBoundary` | React error boundary |
| `ThemeProvider` | Light/dark theme context with system detection + toggle |

### Layout Pattern
```
┌──────────────────────────────────────────────┐
│ SidebarProvider                               │
│ ┌───────────┬──────────────────────────────┐ │
│ │ AppSidebar│ SidebarInset                 │ │
│ │           │ ┌──────────────────────────┐ │ │
│ │ - Logo    │ │ <header> (mobile toggle) │ │ │
│ │ - Nav     │ ├──────────────────────────┤ │ │
│ │ - Tools   │ │ <main> p-4 lg:p-6        │ │ │
│ │ - Decks   │ │   <Outlet /> (page)      │ │ │
│ │ - Footer  │ │                          │ │ │
│ │           │ └──────────────────────────┘ │ │
│ └───────────┴──────────────────────────────┘ │
└──────────────────────────────────────────────┘
```

Presentations (`/p/:slug`) render *outside* the sidebar layout — they are full-width, immersive "slide deck" pages with their own dark cover, table section, map section, and footer.

---

## 5. Pages & Features

### Dashboard (`/dashboard`)
- Lists all sales presentations
- Entry point for the portal

### Sales Presentation (`/p/:slug`) — Public, No Auth
The flagship feature. A scroll-based "deck" layout with distinct sections:

#### Slide 1 — Cover
- Full-viewport dark background (`#1a1a1a`)
- Two-column grid: left = logos + title + meta pills, right = risk card
- UnclogMe logo (white bg, rounded) × Prospect logo
- Large headline (800 weight, up to 68px)
- Meta pills: Date, Locations count, Fine Exposure
- Risk card with total fine exposure or "All Clear" state
- Orange gradient accent (`radial-gradient` from right)

#### Slide 2 — Locations Table
- White background
- Eyebrow → Title → Subtitle header pattern
- Filter bar: All Locations | ⚠️ Off Schedule | 🚨 Expired Permits + location type dropdown + email button
- Full-width data table with black header row, orange uppercase column labels
- Columns: Location, Type, GDO#, Permit Valid, Trap Type, GT Size, Required, Current (editable), Status, Est. Fine, Proximity
- Inline editing: click current frequency to edit
- Permit click → PDF viewer modal (iframe with CORS proxy)
- Sort: off-schedule first → on-schedule → unknown

#### Exposure Banner
- Dark card (`#1a1a1a`) with orange left border accent
- Total fine exposure in large white type
- CTA button + phone number

#### Fine Schedule Grid
- 4-column grid showing Miami-Dade code sections + fine amounts
- Links to actual code sections

#### Map Section
- Leaflet map with custom pins
- Orange dots = existing UnclogMe clients (no names for privacy)
- Black dots = prospect locations with frequency labels
- Proximity rings: green/yellow/red
- Frequency dropdown: Required / Current / Lowest
- Legend with proximity indicators

#### Footer
- UnclogMe logo, company info, "DERM Licensed" badge

### GDO Permit Lookup (`/gdo-lookup`)
- Search form: restaurant name + address
- Hits Miami-Dade DERM API
- Result cards: ✅ Valid Permit Found / ⚠️ Old Permit / 🔥 No Permit (Warm Lead) / ⚠️ Error
- "No permit = warm lead" messaging for sales team

### Territory Map (`/territory`)
- Full-screen Leaflet map
- Zone polygons with color coding (10 zones covering Miami-Dade, Broward, Palm Beach)
- Layer toggle: Clients / Prospects / Both
- Click zone filter pills
- Data from Airtable (clients) + Google Sheet (prospects)

---

## 6. Territory Zones

| Zone | Color | Area |
|------|-------|------|
| SOUTH | `#ef4444` | Homestead, Cutler Bay, Palmetto Bay, Pinecrest, Kendall south |
| DOWN | `#3b82f6` | Downtown, Brickell, Coral Gables, Coconut Grove |
| MIAMI BEACH | `#8b5cf6` | Miami Beach, Key Biscayne |
| MID/EDG | `#f59e0b` | Wynwood, Edgewater, Little Haiti, Design District |
| SF/BH | `#06b6d4` | Surfside, Bal Harbour, Bay Harbor |
| AVE | `#f97316` | Aventura, Sunny Isles |
| NMB | `#eab308` | North Miami, NMB, Miami Gardens |
| BRO | `#22c55e` | All of Broward County |
| PALM | `#14b8a6` | Palm Beach County |
| WEST | `#6366f1` | Doral, Hialeah, Medley, Miami Lakes, Miami Springs |

---

## 7. Backend Architecture (Convex)

### Database Schema

#### `presentations`
```typescript
{
  businessName: string,
  slug: string,                    // URL-friendly unique ID
  logoUrl?: string,
  prospectWebsite?: string,
  preparedDate: number,            // timestamp
  status: "draft" | "active",
  createdBy?: string,              // Slack user ID
  notes?: string,
}
// Index: by_slug
```

#### `locations`
```typescript
{
  presentationId: Id<"presentations">,
  name: string,
  address: string,
  gdoPermitNumber?: string,
  gdoPermitUrl?: string,           // PDF URL
  gdoFrequencyDays?: number,       // Required by permit
  gdoPermitIssuedTo?: string,
  gdoFacilityLocation?: string,
  gdoValidFrom?: string,           // "01-JAN-2026"
  gdoValidThrough?: string,        // "31-DEC-2026"
  gdoContact?: string,
  gdoTrapType?: string,            // "MGRU" or "IGT"
  gdoTrapSize?: string,            // "1000 GAL"
  lat?: number,
  lng?: number,
  locationType?: "existing_client" | "prospect",
  currentFrequencyDays?: number,
  lastServiceDate?: string,
  complianceStatus: "on_schedule" | "off_schedule" | "unknown",
  estimatedFine?: number,
  gdoLookupStatus: "pending" | "found" | "not_found" | "error",
}
// Index: by_presentation
```

#### `clientMapSnapshot`
```typescript
{
  updatedAt: number,
  clients: Array<{ address: string, lat: number, lng: number, gtFrequency?: number }>,
}
```

#### `territoryClients`
```typescript
{
  updatedAt: number,
  airtableId: string,
  clientName: string,
  address: string,
  city?: string,
  zone?: string,
  serviceType?: string[],
  gtFrequency?: number,
  lat?: number, lng?: number,
  geocoded: boolean,
}
// Index: by_airtable_id
```

#### `territoryProspects`
```typescript
{
  updatedAt: number,
  businessName: string,
  address: string,
  city?: string, zip?: string,
  establishmentType?: string,
  phone?: string, email?: string,
  gdoPermitNumber?: string,
  gdoFrequency?: string,
  gdoExpirationDate?: string,
  gdoPermitPdf?: string,
  lat?: number, lng?: number,
  geocoded: boolean,
}
// Index: by_gdo_permit
```

#### Other Tables
- `emailQueue` — queued emails (pending → sent → failed)
- `pendingTaskCards` — Trello /task dedup flow
- `appSecrets` — key-value config
- `clientsCache` — Airtable cache (5 min TTL)
- `clientsDebounce` — per-user modal debounce
- Auth tables from `@convex-dev/auth`

### HTTP API Endpoints
| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/seed-presentation` | POST | Create presentation with locations |
| `/api/update-location-gdo` | POST | Update GDO data for a location |
| `/api/update-location-coords` | POST | Update geocoordinates |
| `/api/add-location` | POST | Add a location to existing presentation |
| `/api/delete-presentation` | POST | Delete a presentation |
| `/api/proxy-pdf` | GET | CORS proxy for permit PDFs |
| `/api/gdo-search` | POST | Search DERM API for permits |

### Convex Deployments
| Environment | Deployment | URL |
|------------|-----------|-----|
| Production (Vercel portal) | `coordinated-snail-227` | `https://coordinated-snail-227.convex.site` |
| Dev (Viktor Space) | `vibrant-swordfish-840` | `https://vibrant-swordfish-840.convex.site` |

### Fine Calculation Logic
```
missedCycles = floor(365 / requiredDays) - floor(365 / actualDays)
fine = missedCycles × $500
```
Off-schedule threshold: `currentDays > requiredDays × 1.1` (10% tolerance).

---

## 8. Routing

```
/                → Redirect to /dashboard
/dashboard       → DashboardPage (inside AppLayout with sidebar)
/gdo-lookup      → GdoLookupPage (inside AppLayout)
/territory       → TerritoryMapPage (inside AppLayout)
/p/:slug         → PresentationPage (standalone, no sidebar/auth)
```

Auth is NOT required for any page (removed for sales portal use case). The sidebar layout wraps dashboard-type pages; presentations are standalone public pages.

---

## 9. Key Design Patterns

### Slide-Based Presentation Layout
The presentation page uses a scroll-based "slide deck" approach:
- Each section (`.slide-*`) fills a visual zone
- Cover slide is full-viewport with dark background
- Content slides use white background with consistent max-width
- Section transitions use spacing (48–72px padding) rather than hard breaks

### Data Table Pattern
- Black header row with orange uppercase labels
- Hover rows with soft gray background
- Inline editing via click-to-edit pattern
- Status badges inline (pill-shaped, color-coded)
- Responsive: horizontal scroll on mobile with touch support

### Modal Pattern
- Overlay: `rgba(0,0,0,0.75)` with `backdrop-filter: blur(4px)`
- Card: white, `border-radius: 12px`, centered
- Header bar (dark for PDF viewer, blue for permit detail)
- Close button: circular, top-right
- PDF viewer: iframe-based with CORS proxy

### Map Pattern
- Leaflet with Carto Light tiles
- Custom `divIcon` markers (not default Leaflet pins)
- Orange circles for clients, black circles with proximity rings for prospects
- Click popups with company info
- Frequency mode switcher that re-renders markers without resetting zoom

### Filter Bar Pattern
- Horizontal pill buttons (`border-radius: 999px`)
- Active state: dark fill, count badge
- Color-coded active states (warn = amber, danger = red)
- Dropdown select for secondary filters

---

## 10. Deployment & Infrastructure

### Vercel Config
```json
{
  "rewrites": [
    { "source": "/((?!assets/).*)", "destination": "/index.html" }
  ]
}
```
Single-page app rewrite — all routes serve `index.html` except `/assets/*`.

### Build Commands
```bash
bun run sync:build    # Push Convex functions + build frontend
bun run sync          # Push Convex functions only
bun run test          # Run Playwright e2e tests
bun run screenshot    # Take screenshots
```

### Public Assets
```
/public/
  favicon.png
  unclogme-logo.png        # Primary logo (used in sidebar, header, presentation)
  gdo-prototype.html       # Legacy prototype
```

---

## 11. External API Integrations

### Miami-Dade DERM API
- **Endpoint**: `https://api-ecmrer.miamidade.gov/derm/documents`
- **Purpose**: Search for GDO permits by address or business name
- **Strategies**: (1) house number + ZIP, (2) house number only, (3) business name

### Airtable
- **Base ID**: `appjMgjjZPeuudqQR`
- **Table ID**: `tbl5lXLtHKUWilDDj`
- **Purpose**: Client database — recurring status, GT frequency, client codes, permit info

### Google Maps
- **Purpose**: Address validation, geocoding, proximity/drive-time calculations
- **Note**: Haversine formula used client-side for approximate drive times (km × 1.8 = minutes)

---

## 12. Important Business Rules

1. **Geographic scope**: Miami-Dade, Broward, Palm Beach counties ONLY
2. **Client vs Prospect**: Only Airtable records with status = "Recurring" are clients; everything else is a prospect
3. **Client code format**: `XXX-PV [Location]` for clients, plain name for prospects
4. **Permit matching**: Match by ADDRESS (not business name — unreliable on permits)
5. **No placeholder values**: Every cell must be a real value or defined fallback (N/A, Unknown, N/E, Pending)
6. **All times in ET**: Never UTC, CEST, or client-local
7. **Work week starts Sunday**: Sun–Sat
8. **Proximity tiers**: 🟢 ≤10 min, 🟡 10–20 min, 🔴 >20 min to nearest existing client
9. **Non-DERM permits** (Hallandale): Use "FOG Notice" button text, "GI" trap type abbreviation

---

## 13. Responsive Breakpoints

| Breakpoint | Changes |
|-----------|---------|
| `≤900px` | Cover → single column, tighter padding |
| `≤768px` | Map height 360px, compact table, mobile sidebar trigger |
| `≤768px` landscape | Compact table cells (smaller fonts, tighter padding) |
| `≤600px` | Fine grid 2-col, meta pills vertical, PDF modal 85vh |

---

## 14. UnclogMe Team Preferences for New Apps

- **Database**: Prefer *Supabase* over Convex for new apps (existing Supabase project: `qyvagxgaggzqyivqfbrj` at `https://qyvagxgaggzqyivqfbrj.supabase.co`)
- **Font**: Manrope is the established brand font
- **Colors**: Orange (#f14714) + Black (#1a1a1a) + White as primary palette
- **Dark mode**: Supported, toggleable via theme provider
- **No external comms without approval**: Never send email/text/external messages without explicit Yan confirmation
- **Accessibility**: Focus states, contrast checks, readable at real content lengths

---

## 15. File Structure Reference

```
unclogme-sales/
├── convex/                    # Backend
│   ├── schema.ts              # Database schema
│   ├── presentations.ts       # Presentation CRUD
│   ├── locations.ts           # Location CRUD + fine calc
│   ├── mapData.ts             # Client snapshot for maps
│   ├── territory.ts           # Territory map data
│   ├── http.ts                # HTTP API endpoints
│   ├── emailQueue.ts          # Email sending queue
│   ├── viktorTools.ts         # Viktor tool gateway
│   ├── auth.ts                # Auth config
│   └── _generated/            # Auto-generated types
├── src/
│   ├── index.css              # All CSS (tokens + presentation styles)
│   ├── App.tsx                # Router setup
│   ├── main.tsx               # Entry point
│   ├── components/
│   │   ├── AppLayout.tsx      # Sidebar + content layout
│   │   ├── AppSidebar.tsx     # Navigation sidebar
│   │   ├── Header.tsx         # Top bar with logo
│   │   ├── MapSection.tsx     # Leaflet map component
│   │   └── ui/                # 53 shadcn/ui components
│   ├── pages/
│   │   ├── DashboardPage.tsx
│   │   ├── PresentationPage.tsx  # Main sales deck
│   │   ├── GdoLookupPage.tsx
│   │   └── TerritoryMapPage.tsx
│   ├── contexts/
│   │   └── ThemeContext.tsx    # Light/dark theme
│   ├── hooks/
│   └── lib/
├── public/
│   ├── unclogme-logo.png
│   └── favicon.png
├── vercel.json
├── package.json
└── vite.config.ts
```

---

*Generated by Viktor — May 2026*
