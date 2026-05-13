# UnclogMe Internal Portal

Yannick's multi-module internal-tool prototype. **`prototype.html` is the
canonical design** — a single-file React-via-CDN app that runs by opening
in a browser. No build step.

## Open the prototype

```bash
# Just open the file in your browser:
start prototype.html        # Windows
open  prototype.html        # macOS
xdg-open prototype.html     # Linux
```

Or serve it locally (so relative URLs work if you add iframes):

```bash
python3 -m http.server 8000
# then visit http://localhost:8000/prototype.html
```

## Modules inside the HTML

| Section | Module | Status (per Yannick) |
|---|---|---|
| Top | Dashboard | LIVE |
| **Sales** | Sales dashboard | LIVE |
| | Sales presentations | LIVE |
| | GDO permit lookup | LIVE *(integrate with our existing GDO Bot)* |
| | Lead pipeline | SOON |
| | Quote builder | SOON |
| | Territory map | LIVE |
| | Compliance alerts | (in code) |
| **Scheduling** | SchedDashboard | (in code) |
| | **MonthlyView** | (in code — calendar view; replaces our earlier `apps/visit-view/` effort) |
| **Visits** | VisitsReview | (in code) |
| **Ops** | Maintenance | (in code) |

## Brand alignment vs `docs/research/unclogme-design-system.md`

Yannick used placeholder values that need to be reconciled with Viktor's
canonical brand doc before/during the wiring pass:

| Token | Yannick's HTML | Viktor's brand doc | Fix |
|---|---|---|---|
| Primary orange | `#EA580C` (Tailwind orange-600) | `#f14714` | Swap CSS variable `--brand` |
| Font | Inter | Manrope | Swap Google Fonts import |
| Border radius base | (Tailwind default) | `0.625rem` | One CSS variable |

Yannick's own header comment says: *"Brand color in CSS variables —
single point of change. Currently #EA580C; replace with exact unclogme.com
hex when available."* — so this swap is expected.

## Wiring plan (what's left)

Yannick's HTML uses inline `MOCK_DATA` at line ~7011. The rebuild path is
to replace each `MOCK_DATA.<key>` lookup with a real Supabase REST call.

| Module | `MOCK_DATA` key | Sbx source |
|---|---|---|
| Top Dashboard KPIs | `kpis` | Several rollup queries — see `DATA-SPEC.md` |
| Top Dashboard / SchedDashboard | `upcomingVisits` | `visits` table (see `DATA-SPEC.md`) — **note: Yannick's mock has `time` field per visit; our schema has only `visit_date` for scheduled visits** |
| Late visits widget | `lateVisits` | `clients_due_service` view |
| Trucks | `trucks` | `vehicles` table + telemetry view |
| AR invoices | `arInvoices` | `invoices` filtered by `invoice_status != 'paid' AND due_date < CURRENT_DATE` |
| AP bills | `apBills` | Not in our schema — would need Ramp integration (out of scope) |
| Sales presentations | `presentations` | Likely Yannick's separate Convex DB (Sales App) — `qyvagxgaggzqyivqfbrj` |
| Pipeline | `pipeline` | Sales App DB (separate from main Unclogme DB) |
| GDO permit lookup | (modal) | Your existing GDO Bot |

`DATA-SPEC.md` in this folder has the Supabase-side query specifications
for the visit-related modules. `VISIT-FIELDS-SPEC.md` keeps the field
contract so we don't regress on the WO-XXXXX-style hallucinations.

## What we explicitly threw away during the pivot

The earlier `apps/visit-view/` work — built before we knew Yannick had
already designed everything — was archived to
`docs/audits/2026-05-13-visit-view-pre-pivot/` (the design prompt and
HTML mockup-reference). Kept for history; not part of the live path.
