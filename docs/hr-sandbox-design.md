# HR Sandbox Design — Yannick's HR Lovable App

*Drafted 2026-05-29 · Status: PROPOSED, awaiting Fred review · Not yet provisioned*

## Context

Yannick is starting a new Lovable app called **HR** (Employee management — the 3rd-page concept from the prior Yan request, now scoped as its own dedicated app). Per the workspace escalation rule (**sensitive PII → 3-stage clone-sandbox**), HR qualifies for its own Supabase project seeded once from Prod and then diverging during dev.

App will live in its own Supabase project (Free plan, same model as Field Portal Sandbox `klgtrdwrasrlxbmfyvdh`).

---

## Decisions

### D1. Separate Supabase project (Free plan) — confirmed by Fred

- Org: `Dev - Unclogme` (us-east-1)
- Plan: Free (500 MB cap)
- Project name: `unclogme-hr-sandbox` (suggested)
- **Why a separate project (not just a new schema on existing Sandbox / Field Portal):** PII isolation. HR holds DOB, address, SSN-last-4, compensation, reviews. Bleed-over into another app's dev environment is bad. Same reasoning that gave Field Portal its own project.

Net Free-plan footprint estimate: ~30 employee rows + ~37 ESL rows + whatever HR writes during dev. Trivially under 500 MB.

### D2. Clone model: one-time seed + diverge (NOT periodic refresh)

Same model as Field Portal Sandbox. Reasoning:
- Refresh-pattern (TRUNCATE CASCADE in `sandbox-refresh.yml`) would wipe Yannick's HR-side work
- HR data (PTO balances, reviews, certifications) **is authoritative in HR** — nothing to refresh from upstream
- Employee identity (full_name, hire_date) rarely changes; on the rare case it does, manually re-seed that row
- Real FKs are safe `hr.*` → `public.employees` because no TRUNCATE will fire

Migration of `hr.*` back to Prod when HR ships → covered in D10.

### D3. Schema layout

- **`public.employees`** = canonical identity (already exists, 34 rows). HR Sandbox clones the cleaned subset (see D7).
- **`hr.*`** = new app-specific schema. Designed Prod-ready so the same SQL applies when HR graduates to Prod.

This matches the multi-app schema pattern (`customer`, `ops`, `field`, `derm` already exist).

### D4. Existing `public.employees` shape (no schema changes proposed)

```
id              bigint NOT NULL  PK
full_name       text   NOT NULL
role            text             (Office / Admin / Technician / Owner)
status          text             (ACTIVE / INACTIVE / MERGED / TEST after D7)
shift           text             (mostly NULL)
email           text
phone           text
hire_date       date
notes           text
access_level    text
created_at      timestamptz
updated_at      timestamptz
```

12 columns. Audit-tracked per ADR 010. **No additions proposed** — extended PII goes in `hr.employee_profiles` (D5) so non-HR apps don't touch DOB/SSN.

### D5. Proposed `hr.*` tables (10 tables)

All tables: 3NF, audit triggers ON, FK indexes, anon-permissive RLS for ship-first.

#### `hr.employee_profiles` (1:1 with employee)

Extended PII only HR needs.

```sql
CREATE TABLE hr.employee_profiles (
  employee_id              BIGINT PRIMARY KEY REFERENCES public.employees(id) ON DELETE RESTRICT,
  date_of_birth            DATE,
  ssn_last_4               TEXT,                       -- last 4 only; full SSN NEVER stored
  home_address_line1       TEXT,
  home_address_line2       TEXT,
  home_city                TEXT,
  home_state               TEXT,
  home_zip                 TEXT,
  emergency_contact_name   TEXT,
  emergency_contact_relationship TEXT,
  emergency_contact_phone  TEXT,
  driver_license_number    TEXT,
  driver_license_state     TEXT,
  driver_license_expires   DATE,
  i9_status                TEXT CHECK (i9_status IN ('verified','pending','expired')),
  w4_filing_status         TEXT,
  payroll_id_external      TEXT,                       -- e.g. Gusto employee ID once payroll picked
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

3NF: every column depends only on `employee_id`.

#### `hr.compensation_history` (1:N)

Pay rate history with effective dates.

```sql
CREATE TABLE hr.compensation_history (
  id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id       BIGINT NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
  effective_date    DATE   NOT NULL,
  pay_type          TEXT   NOT NULL CHECK (pay_type IN ('hourly','salary','contract')),
  pay_rate          NUMERIC(12,2) NOT NULL,
  pay_frequency     TEXT CHECK (pay_frequency IN ('weekly','biweekly','semimonthly','monthly')),
  currency          TEXT NOT NULL DEFAULT 'USD',
  reason            TEXT,                              -- 'hire','raise','promotion','cola'
  approved_by       BIGINT REFERENCES public.employees(id),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (employee_id, effective_date)
);
CREATE INDEX comp_hist_employee_idx ON hr.compensation_history (employee_id);
```

Current pay = view `hr.v_employee_current_pay` returning the latest effective row ≤ today.

#### `hr.time_off_balances`

```sql
CREATE TABLE hr.time_off_balances (
  employee_id    BIGINT NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
  balance_type   TEXT   NOT NULL CHECK (balance_type IN ('vacation','sick','personal')),
  accrued_hours  NUMERIC(10,2) NOT NULL DEFAULT 0,
  used_hours     NUMERIC(10,2) NOT NULL DEFAULT 0,
  as_of_date     DATE   NOT NULL DEFAULT CURRENT_DATE,
  PRIMARY KEY (employee_id, balance_type)
);
```

#### `hr.time_off_requests`

```sql
CREATE TABLE hr.time_off_requests (
  id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id       BIGINT NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
  balance_type      TEXT   NOT NULL CHECK (balance_type IN ('vacation','sick','personal')),
  start_date        DATE   NOT NULL,
  end_date          DATE   NOT NULL,
  hours_requested   NUMERIC(10,2) NOT NULL,
  reason            TEXT,
  status            TEXT   NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','denied','cancelled')),
  decided_by        BIGINT REFERENCES public.employees(id),
  decided_at        TIMESTAMPTZ,
  decision_note     TEXT,
  requested_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX tor_employee_idx ON hr.time_off_requests (employee_id);
CREATE INDEX tor_pending_idx  ON hr.time_off_requests (status) WHERE status = 'pending';
```

#### `hr.certifications`

DERM operator card, CDL, water/wastewater operator, OSHA, first aid.

```sql
CREATE TABLE hr.certifications (
  id                   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id          BIGINT NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
  certification_type   TEXT   NOT NULL,   -- 'derm_operator','cdl_class_b','wastewater_operator','first_aid','osha_10','osha_30'
  certification_number TEXT,
  issued_date          DATE,
  expires_date         DATE,
  issuing_body         TEXT,
  document_path        TEXT,              -- supabase storage path
  status               TEXT   NOT NULL DEFAULT 'active' CHECK (status IN ('active','expired','revoked')),
  notes                TEXT,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX cert_employee_idx ON hr.certifications (employee_id);
CREATE INDEX cert_expires_idx  ON hr.certifications (expires_date) WHERE status = 'active';
```

#### `hr.reviews`

```sql
CREATE TABLE hr.reviews (
  id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id       BIGINT NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
  review_period     TEXT   NOT NULL,        -- '2026-Q1','2026-annual'
  review_date       DATE   NOT NULL,
  reviewed_by       BIGINT REFERENCES public.employees(id),
  overall_rating    TEXT CHECK (overall_rating IN ('exceeds','meets','below','unsatisfactory')),
  strengths         TEXT,
  areas_to_improve  TEXT,
  goals             TEXT,
  document_path     TEXT,
  acknowledged_by_employee BOOLEAN NOT NULL DEFAULT false,
  acknowledged_at   TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX reviews_employee_idx ON hr.reviews (employee_id);
```

#### `hr.disciplinary_actions`

```sql
CREATE TABLE hr.disciplinary_actions (
  id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id       BIGINT NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
  incident_date     DATE   NOT NULL,
  action_type       TEXT   NOT NULL CHECK (action_type IN ('verbal','written','final','suspension','termination')),
  description       TEXT   NOT NULL,
  issued_by         BIGINT REFERENCES public.employees(id),
  document_path     TEXT,
  acknowledged_by_employee BOOLEAN NOT NULL DEFAULT false,
  acknowledged_at   TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX disc_employee_idx ON hr.disciplinary_actions (employee_id);
```

#### `hr.documents` (general bucket)

Onboarding paper trail outside compensation / certifications / reviews.

```sql
CREATE TABLE hr.documents (
  id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id       BIGINT NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
  document_type     TEXT   NOT NULL,        -- 'i9','w4','offer_letter','handbook_ack','direct_deposit'
  document_path     TEXT   NOT NULL,        -- supabase storage path
  uploaded_by       BIGINT REFERENCES public.employees(id),
  uploaded_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_date      DATE,
  notes             TEXT
);
CREATE INDEX docs_employee_idx ON hr.documents (employee_id);
```

#### `hr.equipment_assignments`

Phones, uniforms, keys, vehicles out with employees.

```sql
CREATE TABLE hr.equipment_assignments (
  id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id       BIGINT NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
  equipment_type    TEXT   NOT NULL,        -- 'phone','uniform','keys','vehicle','laptop'
  identifier        TEXT,                   -- IMEI / serial / VIN
  assigned_date     DATE   NOT NULL DEFAULT CURRENT_DATE,
  returned_date     DATE,
  notes             TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX eq_employee_idx     ON hr.equipment_assignments (employee_id);
CREATE INDEX eq_outstanding_idx  ON hr.equipment_assignments (employee_id) WHERE returned_date IS NULL;
```

#### `hr.benefits_enrollment`

```sql
CREATE TABLE hr.benefits_enrollment (
  id                       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id              BIGINT NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
  benefit_type             TEXT   NOT NULL,   -- 'health','dental','vision','401k'
  plan_name                TEXT,
  enrolled_date            DATE,
  ended_date               DATE,
  employee_contribution    NUMERIC(12,2),
  employer_contribution    NUMERIC(12,2),
  notes                    TEXT,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX benefits_employee_idx ON hr.benefits_enrollment (employee_id);
```

### D6. Clone scope (what comes from Prod, what doesn't)

**INCLUDE:**

| Table | Filter | Approx rows |
|---|---|---|
| `public.employees` | `status NOT IN ('TEST','MERGED')` AFTER D7 cleanup | ~25 |
| `public.entity_source_links` | `entity_type='employee'` | ~37 (29 Jobber + 8 Samsara) |

**EXCLUDE:**
- `public.clients` / `properties` / `jobs` / `visits` / `derm_*` / `vehicles` / `service_configs` — HR doesn't need any of this
- `public.webhook_*` / `samsara_*` raw / `airtable_*` raw — none
- All `ops.*` / `customer.*` / `derm.*` / `field.*` views — none

The clone is intentionally tiny: HR is a closed app, not a cross-system dashboard.

### D7. Pre-clone cleanup of `public.employees` (Prod-side, BEFORE seeding)

Today's roster has 34 rows with clear issues (verified 2026-05-29):

**Test/fake rows to mark `status='TEST'` (4 rows):**

| id | full_name | VA | Reason |
|---|---|---:|---|
| 6 | Driver Example | 0 | Template/demo row |
| 7 | Mateus Dev | 0 | Dev-test account |
| 12 | TEST | 0 | Literal test row |
| 14 | KAVAGY | 0 | Likely Yannick's design-vendor account |

**Suspect duplicate pairs (role='Technician' with 0 VA — almost certainly Jobber-side duplicates of the admin-side row):**

| id | full_name (technician) | Likely duplicate of | Master VA |
|---|---|---|---:|
| 29 | Yannick | 27 Yannick Ayache | 2 |
| 30 | Aaron | 26 Aaron Driver | 39 |
| 31 | Diego | 28 Diego HERNANDEZ COLLA | 5 |
| 32 | Keyon | 21 Keyon Green | 0 |
| 34 | Ishad | 8 Ishad Knight | 20 |

Proposed: merge each technician row into its admin twin. Steps per pair:
1. Verify ESL mappings — the technician row may carry a *different Jobber GID* (Jobber technician profile vs admin user). If yes, **move that ESL to the admin row** so Jobber webhook lookups still resolve correctly.
2. Update any VA pointing at the technician id (none today, but safety check) → repoint to admin id.
3. Mark technician row `status='MERGED'`, `notes='merged into id=<X> on 2026-05-29'`.

**Non-driver office rows with 0 VA (13 rows):** Hanna Cohen, Aziz, Andres, Noa Dahan, Jennifer Powell, Pablo, Diego Martin Sarachaga, Noa, Emilie Avot, Ahsan, angela, david derval, Keyon Green — *unclear* whether real employees or AT-imported noise. **Punt to Fred/Yannick** to mark `status='INACTIVE'` per row.

**Real ops staff to keep ACTIVE (12 rows):** Grecia, Fred, Ishad Knight, A Azoulay (admin), Raymond Lee, Kevis Bell, Steven, Jeffry, Aaron Driver, Yannick Ayache, Diego HERNANDEZ COLLA, Donald Barron — these have ≥3 VA each, clearly real.

Cleanup is audited via `audit.logs` on `public.employees` (opt-in per ADR 010).

### D8. RLS + perf config (per UnclogMe standing rules)

On the HR Sandbox project, on first migration:

```sql
-- Per memory: bump anon statement timeout
ALTER ROLE anon SET statement_timeout = '15s';

-- Per memory: ship-first anon-permissive RLS on hr.* (no Lovable auth yet)
ALTER TABLE hr.employee_profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY anon_all ON hr.employee_profiles FOR ALL USING (true) WITH CHECK (true);
-- (repeat for all hr.* tables)

-- Per ADR 010: HR is PII + human-editable → audit ON for every hr.* table
CREATE TRIGGER audit_employee_profiles AFTER INSERT OR UPDATE OR DELETE
  ON hr.employee_profiles FOR EACH ROW EXECUTE FUNCTION audit.log_change();
-- (repeat for all hr.* tables)
```

All `auth.uid()` calls in any future hardened RLS wrapped in `(SELECT auth.uid())` per perf rule.

### D9. Provisioning steps

| # | Step | Owner | Notes |
|---|---|---|---|
| 1 | Pre-clone cleanup of `public.employees` on Prod (D7) | Claude → Fred sign-off | Audited mutations. Drops roster from 34 → ~25 ACTIVE |
| 2 | Create new Supabase project `unclogme-hr-sandbox` (Free, us-east-1) | Fred via dashboard OR Claude via mgmt API | Capture project ref |
| 3 | Add env vars `HR_SANDBOX_URL` / `HR_SANDBOX_SERVICE_ROLE_KEY` / `HR_SANDBOX_PROJECT_ID` to `.env` + GitHub Secrets | Fred | Same pattern as `FIELD_PORTAL_*` |
| 4 | Migration 01 — clone base schema (`public.employees` + `public.entity_source_links` DDL only) | Claude | `pg_dump --schema-only --table=...` from Prod, apply to Sandbox |
| 5 | Migration 02 — create `hr` schema + 10 tables + audit triggers + RLS + anon timeout (D5 + D8) | Claude | Idempotent SQL with header per ADR 010 |
| 6 | Seed `scripts/clone/seed_hr_sandbox.js` — pull cleaned employees + their ESL from Prod, INSERT into HR Sandbox | Claude | Idempotent `ON CONFLICT (id) DO UPDATE`. Re-runnable. |
| 7 | Document in `docs/architecture/hr-sandbox.md` + write **ADR 017 — HR Sandbox provisioning** | Claude | After Fred sign-off |
| 8 | Hand off to Yannick: URL + anon key + Lovable Knowledge doc (`<10k chars`) | Claude → Fred → Yannick | Use the field-portal-lovable-knowledge.md as template |

### D10. Prod migration path (when HR app ships)

When Yannick's HR app graduates:

1. Apply `hr` schema migrations to Prod (same SQL, same audit triggers, same RLS pattern).
2. One-time bulk-import of HR Sandbox `hr.*` rows → Prod `hr.*` (manual, audited).
3. Yannick repoints HR Lovable URL Sandbox → Prod.
4. HR Sandbox stays as the dev environment for the next iteration.

This is the **3-stage**: dev (Sandbox) → review (Fred) → Prod.

---

## What's intentionally NOT included

- **Time tracking / clock-in / clock-out** — Samsara already tracks driver shifts via engineStates. Adding parallel clock-in in HR would duplicate. Punt until ops asks.
- **Payroll execution** — HR stores payroll_id_external mapping but actual payroll runs through Gusto/etc. Stay on the side of "store identity, not transactions."
- **Org chart / reporting structure** — could add `public.employees.manager_id` later, low value for v1.
- **Self-service portal for employees to update their own info** — single-admin model first (Yannick + Fred), employee portal is a v2 ask.

---

## Open decisions for Fred / Yannick

1. **Pre-clone employee de-dup**: should I draft the merge script + run it on Prod (after sign-off) before cloning, or punt to Yannick to decide once he sees the data in the sandbox?
2. **SSN handling**: store `ssn_last_4` only (proposed), OR skip SSN entirely from Sandbox (Sandbox = no real SSN ever, only Prod gets the field)?
3. **Compensation data in Sandbox**: seed with real pay rows from Fred's records, mock numbers, or leave empty for Yannick to populate manually?
4. **Create `hr` schema on Prod NOW (empty) vs only on Sandbox**: creating it now on Prod makes the eventual migration a one-line `INSERT … SELECT …` per table. Cost: pollutes Prod with empty tables.
5. **Document storage bucket**: new `hr-documents` Storage bucket on the HR Sandbox project, with `path = <employee_id>/<doc_id>` convention and RLS limiting visibility to admins?

---

## Pointers

- Field Portal Sandbox precedent: `klgtrdwrasrlxbmfyvdh`, memory `project_field_portal_sandbox.md`
- Multi-app schema pattern: memory `project_multi_app_schema_pattern.md`
- Ship-first RLS: memory `feedback_ship_first_harden_later.md`
- Sandbox FK / canonical-mirror rule: memory `feedback_no_real_fk_on_sandbox_canonical_mirrors.md` (does NOT apply here — HR Sandbox is clone-once, not refresh)
- Anon timeout: memory `feedback_supabase_anon_timeout_3s.md`
- ADR 010 audit-trail standing check: required for every `hr.*` table
- ADR 016 app-source attribution: HR app should set `X-App-Source: hr` on writes; trigger CASE in `audit.log_change()` will need a new branch
