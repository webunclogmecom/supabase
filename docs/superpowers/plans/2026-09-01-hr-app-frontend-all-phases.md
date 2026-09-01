# HR App Front End, All Phases, Read-Only Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Build the complete HR app front end across all three phases, reading real data where it exists, with every Create, Update and Delete control visible but disabled.

**Architecture:** A Lovable app joined to the shared staff session. It reads `public.employees` directly through PostgREST, which needs no database work: `authenticated` already holds SELECT plus a `USING (true)` policy. Everything HR-specific has no table behind it yet, so those areas render honest empty states rather than invented data.

**Tech Stack:** Lovable (React + Vite + supabase-js), Supabase Prod `wbasvhvvismukaqdnouk` read-only.

**Spec:** [`docs/superpowers/specs/2026-08-31-hr-app-employee-management-design.md`](../specs/2026-08-31-hr-app-employee-management-design.md)

**Supersedes for now:** [`2026-09-01-hr-app-phase-1.md`](2026-09-01-hr-app-phase-1.md) is the database plan. It is **deferred, not cancelled**: it stays the correct plan for when the backend is built, and this front end is what tells us whether its data model is right.

---

## Scope

**In:** every screen of all three phases, read-only.

**Out:** all database work. No migrations, no tables, no views, no RPCs, no buckets, no edge functions. Nothing in this plan changes Prod.

🛑 **The app performs the R of CRUD only.** Create, Update and Delete controls are **rendered and visibly disabled**, not removed. Fred needs to review the whole UX, and a hidden button cannot be reviewed.

---

## 🛑 What is real and what is not

Measured 2026-09-01. Getting this wrong is the only way this plan can mislead.

| area | data source | status |
|---|---|---|
| Directory list | `public.employees`, 21 rows, 9 ACTIVE | **REAL** |
| Canonical record card | same | **REAL** |
| `access_level` (admin / office / field) | `public.employees.access_level` | **REAL** |
| Person colour | `public.employees.color_hex` | **REAL** |
| Pay rates | nothing exists | **EMPTY STATE** |
| Documents | nothing exists | **EMPTY STATE** |
| Emergency contact | nothing exists | **EMPTY STATE** |
| Auth account state | `auth.users` is not reachable from the app | **EMPTY STATE** |
| Audit log | the `audit` schema is not exposed to PostgREST | **EMPTY STATE** |
| Per-app privileges | does not exist as data | **DESIGN ONLY** |

⚠ **Never invent numbers.** A mocked salary on a screen Fred reviews becomes a number somebody quotes. Every area without a source shows an empty state that names what is missing, for example *"No pay rates recorded. This is stored in `hr.pay_rate`, which is not built yet."* Those empty states double as the specification for the backend plan.

⚠ The employee list has **no Type column**. W2/1099 was dropped as a duplicate of role.
⚠ Role values in Prod are `Technician`, `Admin`, `Owner`, `Office`. The prototype's `driver / helper / plumber` **do not exist**. Populate every role filter from the data, never from a literal.

---

## Task 1: Create the app and join the shared session

**Lovable project:** `816f8580-af86-43f4-92b6-780af367abd4`

🛑 This is the seventh app joining one shared login. Rule 0b in `Building Apps/CLAUDE.md` lists four ways to break it, and **every one fails silently: green build, no console error, nothing in `audit.logs`.**

- [x] **Step 1: Wire the Supabase client, then check all four breakers**

1. **No explicit `storageKey`, anywhere.** All apps leave it unset so supabase-js derives the same default, which is what makes the cookie shared. Set one and this app quietly gets a private session and just asks the user to log in again.
2. **`VITE_PROD_SUPABASE_URL` stays the default `<ref>.supabase.co` form.** The cookie name derives from the URL's *first hostname label*, not the project ref. A custom auth domain silently renames the cookie to `sb-auth-auth-token`.
3. **Set `auth.userStorage`** so the user object lives in per-origin localStorage. A full session is 4,080 bytes against a ~4,062 byte ceiling: without the split the cookie silently never exists, and every *other* app then serves a stale token.
4. **The staff gate uses `await supabase.auth.getUser()`, never `session.user`.** On a first cross-origin arrival auth-js substitutes a proxy and any read of `session.user` throws, including through optional chaining. Treat a `getUser()` error as UNKNOWN with a retry state and **never call `signOut()` there**: sign-out is global, so a gate misfire evicts the user from every app on `unclogme.app`.

- [x] **Step 2: Match the staff allow-list exactly**

`@unclogme.com` + `@ayache.com`, identical to the other six.
⚠ The effective allow-list is the **intersection** of every app's list. A narrower list here narrows the whole estate for everyone.

- [x] **Step 3: Verify token identity, not "still signed in"**

Open the Apps Hub and the HR app in the same browser and compare the access token each reports.
Expected: **identical strings**.
🛑 "Still signed in" is not evidence. An app's own localStorage produces a byte-identical screen while the shared cookie is broken.

- [x] **Step 4: Create the docs folder and commit**

```bash
cd "/c/Users/FRED/Desktop/Virtrify/Yannick/Claude/Building Apps"
mkdir -p "HR App/docs"
```
Write `HR App/docs/08-changelog.md` with a dated entry recording: the app was created, which Supabase project it reads, that it is read-only, and the four SSO checks above with their observed results.

```bash
git add "HR App/docs/08-changelog.md"
git commit -m "Add the HR app and join it to the shared staff session"
```
⚠ Building Apps uses a **one-line commit message, no co-author footer** (workspace rule 4).

---

## Task 2: The read-only data layer

One module is the single place that touches Supabase, so the read-only promise is enforceable by inspection rather than by discipline.

- [x] **Step 1: Build `src/lib/hr-data.ts` with exactly one query**

```ts
// The ONLY Supabase read in this app. Everything else is derived from it or is an empty state.
//
// 🛑 READ-ONLY BY CONSTRUCTION. There is no insert, update, upsert, delete or rpc call in this
// file, and there must not be one anywhere else either. The app is a review surface for the UX;
// the backend that would receive writes does not exist yet.
export type Employee = {
  id: number;
  full_name: string;
  role: string | null;
  status: 'ACTIVE' | 'INACTIVE';
  shift: string | null;
  email: string | null;
  phone: string | null;
  hire_date: string | null;
  access_level: 'admin' | 'office' | 'field' | null;
  color_hex: string | null;
};

export async function listEmployees(): Promise<Employee[]> {
  const { data, error } = await supabase
    .from('employees')
    .select('id, full_name, role, status, shift, email, phone, hire_date, access_level, color_hex')
    .order('status', { ascending: true })
    .order('full_name', { ascending: true });
  if (error) throw error;
  return data ?? [];
}
```

- [x] **Step 2: Add the empty-state registry**

```ts
// Each area with no table behind it names what is missing, so the screen doubles as the
// specification for the backend plan. NEVER substitute sample values here: a mocked salary on a
// screen someone reviews becomes a number somebody later quotes.
export const NOT_BUILT = {
  pay:       { table: 'hr.pay_rate',           label: 'No pay rates recorded' },
  documents: { table: 'hr.employee_document',  label: 'No documents on file' },
  emergency: { table: 'hr.employee_profile',   label: 'No emergency contact recorded' },
  authState: { table: 'auth.users',            label: 'Account status not available' },
  auditLog:  { table: 'audit.logs',            label: 'Change history not available' },
} as const;
```

- [x] **Step 3: Verify no write path exists**

Search the published bundle for `.insert(`, `.update(`, `.upsert(`, `.delete(`, `.rpc(`.
Expected: **zero matches**.
🛑 A backtick-quoted or minified call still matches these substrings; if the search returns zero for all five, the read-only promise holds structurally rather than by intention.

- [x] **Step 4: Commit**

```bash
git add "HR App/docs/08-changelog.md"
git commit -m "Add the read-only data layer and the empty-state registry"
```

---

## Task 3: Phase 1, the directory screen

- [x] **Step 1: Build the list**

Columns: **Name** (with email beneath), **Role**, **Level**, **Shift**, **Hired**, **Pay**, **Status**.
- **Level** is `access_level`, real data, rendered as a chip: `admin` / `office` / `field`.
- **Pay** renders the empty-state dash with a tooltip naming `hr.pay_rate`. It is never a number.
- 🛑 **No Type column.**

Filters: free-text search over name, role and email; a role dropdown; a status dropdown defaulting to **Active**.
⚠ Build the role dropdown from `distinct role` in the fetched rows. Hardcoding `driver / helper / plumber` yields a filter that matches nothing.

Header counts read `21 total`, `9 active` from the data, not from constants.

- [x] **Step 2: Verify against reality**

Open the app and confirm: 21 rows with the status filter set to All, 9 with Active, and that the four technicians show `field`, Fred and Yannick `admin`, Aaron, Diego and Serena `office`.

- [x] **Step 3: Commit**

```bash
git add "HR App/docs/08-changelog.md"
git commit -m "Add the employee directory, reading real employees"
```

---

## Task 4: Phase 1, the detail screen

- [x] **Step 1: Build the cards**

- **Hero:** name, role pill, email, phone, shift. 🛑 The pill is the role alone; the `W2 ·` prefix went with the type concept.
- **Canonical record:** id, full_name, role, status, shift, email, phone, hire_date, access_level. **All real.** Its `Edit` button is present and **disabled**.
- **Emergency contact:** empty state naming `hr.employee_profile`. `Edit` present and disabled.
- **Pay rates:** empty state naming `hr.pay_rate`. `Edit pay` present and disabled.
- **Documents:** empty state naming `hr.employee_document`. `Upload` present and disabled.

- [x] **Step 2: Build the Quick actions panel, all disabled**

Four buttons, each rendered with a tooltip saying why it is disabled:

| button | tooltip |
|---|---|
| Edit canonical fields | `Writes are disabled in this build` |
| Update pay | `Needs hr.pay_rate, which is not built yet` |
| Request document | `Needs the signed upload flow, which is a separate plan` |
| View audit log | `The audit schema is not exposed to the app` |

🛑 **Reassign equipment is not rendered at all.** It is cut from the design, not merely unbuilt, because no equipment data exists and none is planned.
⚠ "Update pay" reads **hourly + per-job + per-shift**. The prototype's "per-location" appears nowhere in its own data model.

- [x] **Step 3: Commit**

```bash
git add "HR App/docs/08-changelog.md"
git commit -m "Add the employee detail screen with disabled write controls"
```

---

## Task 5: Phase 2, the credentials screen

⚠ This screen has **no mockup**. Yannick's HTML does not cover Phase 2, so this is new design work.

- [x] **Step 1: Build the account panel on the detail screen**

Fields, all empty states for now: account exists, provider, last sign-in. Each names `auth.users` as the missing source.

⚠ **There is no username field, and there should not be one.** Supabase Auth identifies people by **email** plus either a provider or a password. If a display name is wanted, that is `employees.full_name`, which the canonical card already shows.

- [x] **Step 2: Render the three actions, disabled**

| action | tooltip |
|---|---|
| Send invite | `Blocked until privileges exist. An invited account currently sees every app` |
| Send password reset | `Everyone here signs in with Google, so there is no password to reset` |
| Disable account | `Writes are disabled in this build` |

🛑 **The invite tooltip is not decoration.** Having no account is currently the only thing keeping the four technicians out of every app in the estate. That is worth saying on the button itself so nobody enables it casually.

- [x] **Step 3: Commit**

```bash
git add "HR App/docs/08-changelog.md"
git commit -m "Add the Phase 2 credentials panel, actions disabled"
```

---

## Task 6: Phase 3, the privileges screen

⚠ No mockup exists for this either. It is the largest piece of new design in the plan.

- [x] **Step 1: Build the per-person privileges panel**

Two parts, and the distinction between them is the point:

**Access level, REAL.** Shows `admin` / `office` / `field` from `public.employees.access_level`, with a one-line description of each. The control to change it is present and **disabled**.

**App access, DESIGN ONLY.** A checklist of the seven staff apps: Apps Hub, Visit Calendar, Admin Review, DERM Tracker, DERM Stamp Studio, Client App, Field Portal. Each shows whether that level would have access under a proposed rule, with every checkbox disabled.

Proposed default, to be reviewed rather than assumed correct: `admin` sees all seven, `office` sees all but the Field Portal, `field` sees none today because no technician has an account.

- [x] **Step 2: Add the banner that keeps this screen honest**

🛑 A privileges screen that does not restrict anything is the most dangerous artefact in this plan. Put a persistent, unmissable banner at the top:

> **Nothing on this screen is enforced yet.** Access levels are recorded but no app reads them. Measured 2026-09-01: of 136 row-level security policies, 113 place no restriction at all, and exactly one table in the estate restricts by who you are. Changing a level here would change nothing anywhere.

⚠ Do not soften this into a subtitle. The failure it prevents is somebody believing they have restricted a colleague when they have not.

- [x] **Step 3: Commit**

```bash
git add "HR App/docs/08-changelog.md"
git commit -m "Add the Phase 3 privileges screen, clearly marked unenforced"
```

---

## Task 7: The honesty pass

- [x] **Step 1: Sweep every screen**

Confirm, screen by screen:
- No number, name, rate or date appears that did not come from `public.employees`.
- Every empty state names the table that will hold that data.
- Every disabled control has a tooltip explaining why.
- No control performs a write.

- [x] **Step 2: Re-run the write-path search on the published bundle**

Search for `.insert(`, `.update(`, `.upsert(`, `.delete(`, `.rpc(`.
Expected: **zero matches**.
🛑 If any appears, find it and remove it before showing the app to anyone. The read-only promise is the basis on which this plan touches Prod at all.

- [x] **Step 3: Publish and verify the live bundle**

Verify against the **published bundle**, not the editor preview. The editor can show a build that was never published.

- [x] **Step 4: Commit**

```bash
git add "HR App/docs/08-changelog.md"
git commit -m "Verify the app is read-only and every empty state names its source"
```

---

## Task 8: Documentation

- [x] **Step 1: Write the app docs**

In `Building Apps/HR App/docs/`:
- `02-architecture.md`: one Supabase read, the empty-state registry, why the app is read-only, and the four SSO checks with observed results.
- `08-changelog.md`: dated entries, newest first.
- `09-known-issues.md`: seed with the real ones. That pay, documents, emergency contact, auth state and audit history have no backend. That the privileges screen is unenforced and why. That the invite action is blocked deliberately.

- [x] **Step 2: Note the deferral on the database plan**

Add a line at the top of `docs/superpowers/plans/2026-09-01-hr-app-phase-1.md` recording that it is deferred in favour of this front-end-first plan, and that the empty states here are its acceptance criteria.

- [x] **Step 3: Commit both repos**

```bash
cd "/c/Users/FRED/Desktop/Virtrify/Yannick/Claude/Building Apps"
git add "HR App/docs"
git commit -m "Document the HR app architecture and what is not built yet"

cd /c/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase
git add docs/superpowers/plans/2026-09-01-hr-app-phase-1.md
git commit -m "$(printf 'Note that the database plan is deferred behind the front end\n\nFred wants the front end for all three phases first, read-only. The empty\nstates in that app name the tables this plan would build, so they become its\nacceptance criteria rather than a parallel description.\n\nCo-Authored-By: Claude Opus 5 <noreply@anthropic.com>')"
```

---

## Done when

- [x] The directory lists all 21 real people, defaulting to the 9 active.
- [x] Levels render correctly: Fred and Yannick `admin`, Aaron, Diego and Serena `office`, the four technicians `field`.
- [x] Every screen across all three phases is reachable and reviewable.
- [x] Every write control is visible, disabled, and explains itself.
- [x] Searching the published bundle for the five write methods returns **zero** matches.
- [x] The HR app and the Apps Hub report the **same access token**.
- [x] The privileges screen carries its unenforced banner.
