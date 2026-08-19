# Service Call job per property: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every property created from any UnclogMe app also gets a Service Call job, and both New Client dialogs offer a default-checked "use this address as the first property" checkbox.

**Architecture:** One shared server-side helper, `ensureServiceCallJob()`, is the single definition of the rule. It resolves the property's real Jobber GID, checks idempotency before touching Jobber, then delegates to the existing `save-client-job` edge function rather than reimplementing job creation. `create-client` gains a `property_mode` input and calls the helper. Phase 2 adds `save-client-property`, the first code in this repo to call Jobber's `propertyCreate`.

**Tech Stack:** Supabase Edge Functions (Deno, TypeScript), Postgres via the Supabase Management API, Jobber GraphQL API (version `2026-04-16`), two Lovable React apps.

**Spec:** [`docs/superpowers/specs/2026-08-19-sc-job-auto-creation-design.md`](../specs/2026-08-19-sc-job-auto-creation-design.md)

---

## 🛑 THE STANDING PROTOCOL: AUDIT FIRST, THEN VERIFY IN BOTH SYSTEMS

**Fred, 2026-08-19:** *"we need to do audits first on every step and do visual checks too, make sure
it's all as you said, and i mean checks in our db and in jobber."*

This overrides the ordinary "run the step, check the output" rhythm. **Every step runs as three
parts, and none of them is optional:**

1. **AUDIT FIRST.** Before changing anything, measure the CURRENT state of exactly what the step will
   touch, and write the numbers down in the execution log. A step that changes something you never
   measured cannot be verified afterwards, because there is no before.
2. **DO the step.**
3. **VERIFY IN BOTH SYSTEMS.** Our DB *and* Jobber, separately. Neither one alone is evidence:
   - **Our DB** answers "did we record it", by SQL against Prod.
   - **Jobber** answers "does it exist upstream", by **looking at the Jobber UI**, not only by
     GraphQL. A GraphQL read and the write that preceded it can share a wrong assumption; a human
     looking at the job on the client's page cannot.
   - When they disagree, **the disagreement IS the finding.** Stop and report it. Do not reconcile it
     by re-running the write.

**Why the visual half is not ceremony.** This estate has repeatedly produced green API results over
broken reality: a Jobber waiting-room reply at HTTP 200 that read as success, a `sync_log` success row
written while the feature wrote nothing, a `needs_populate = 0` queue that was hiding rows it had
silently given up on. Every one of those passed an API check. **Ask what the feature WROTE, and then
go and look at it.**

⚠ **A screenshot of the Jobber UI is the artifact.** Capture one for every step that touches Jobber,
and state in the log what it shows. "I checked it" is not a record.

⚠ **Some steps touch only one system.** A migration touches only the DB, and a dry run touches
neither. Say so explicitly in the log rather than silently skipping the half that does not apply, so
a reader can tell "not applicable" from "not done".

---

## Read this before Task 1

**There is no unit-test framework for edge functions in this repo.** Do not invent one. The established
idiom, which this plan follows, is:

1. **Probe scripts** in `scripts/probes/*.js`. Plain Node, `require('dotenv').config()`, POST SQL to
   the Management API at `https://api.supabase.com/v1/projects/${SUPABASE_PROJECT_ID}/database/query`
   with `Authorization: Bearer ${SUPABASE_PAT}`.
2. **Rolled-back transactions** for anything that would write.
3. **Every probe carries a positive control that MUST fire.** A probe returning zero failures proves
   nothing unless something in the same run proves the probe can detect a failure at all.
4. **Live smoke tests** against test client `112-YA`, reverted afterwards where revertible.

**Windows note:** PowerShell 5.1 is the default shell and `&&` is not a valid separator. Run one
command per line, or use the Bash tool. Write structured probe results to a file and `JSON.parse`
them, because tool output can corrupt on this machine.

**🛑 SECRETS:** `Supabase/.env` holds `SUPABASE_PAT` and `SUPABASE_SERVICE_ROLE_KEY`. Both repos are
PUBLIC. Never print them, never commit them, never paste them into a probe's output.

**🛑 THE ONE IRREVERSIBLE FACT.** Jobber has no `jobDelete` and no `jobArchive`. The only teardown is
`jobClose(modifyIncompleteVisitsBy: DESTROY_ALL)`, which also destroys the job's scheduled visits.
Any step that reaches `jobCreate` is permanent. Measured 2026-08-19: **112-YA currently has zero
active Service Call jobs**, so Task 5's live create arm WILL mint a real, permanent Jobber job on the
test client. That is accepted (112-YA should have one anyway), but do it once, knowingly, and do not
loop it.

---

## File structure

| Path | Responsibility | Task |
|---|---|---|
| `docs/migrations/2026-08-19_1930_client_create_attempts_job_step.sql` | Ledger columns plus the attention-view branch | 1 |
| `scripts/probes/jobber_property_mode_contract.js` | Answers the one unverified question in the spec | 2 |
| `supabase/functions/_shared/service-call-job.ts` | `ensureServiceCallJob()`. The single definition of the rule | 3 |
| `scripts/probes/ensure_sc_job.js` | Probe for the helper, four arms | 4, 5 |
| `supabase/functions/create-client/index.ts` | Content-type guard, `property_mode`, helper call | 6, 7, 8 |
| Lovable `dbf2133c` (Client App) | Checkbox, `none` branch | 9 |
| Lovable `6533c3ee` (Visit Calendar) | Checkbox, `separate` branch | 10 |
| `supabase/functions/save-client-property/index.ts` | Jobber `propertyCreate` plus helper call | 12 |
| `supabase/config.toml` | `verify_jwt = false` for the new function | 12 |
| `docs/migrations/2026-08-19_2200_create_property_refuse.sql` | Close the DB-only property path | 14 |

---

# PHASE 1

## Task 1: Ledger columns and the attention-view branch

**Files:**
- Create: `docs/migrations/2026-08-19_1930_client_create_attempts_job_step.sql`

- [ ] **Step 1: Write the probe that must FAIL first**

Create `scripts/probes/job_step_ledger.js`:

```js
require('dotenv').config({ path: __dirname + '/../../.env' });
const fs = require('fs');

async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  const t = await r.text();
  try { return JSON.parse(t); } catch { return { error: t.slice(0, 300) }; }
}

(async () => {
  const out = [];
  const cols = await sql(`select column_name from information_schema.columns
    where table_schema='public' and table_name='client_create_attempts'
      and column_name in ('jobber_job_gid','job_id','job_step')`);
  const names = Array.isArray(cols) ? cols.map(c => c.column_name).sort() : [];
  out.push({ check: 'ledger columns exist', pass: names.length === 3, got: names.join(',') });

  const view = await sql(`select pg_get_viewdef('public.v_client_create_attention'::regclass, true) as def`);
  const def = Array.isArray(view) ? String(view[0].def) : '';
  out.push({ check: 'view has a job_step branch', pass: def.includes('job_step'), got: def.includes('job_step') ? 'present' : 'absent' });

  // POSITIVE CONTROL: this MUST pass both before and after the migration.
  // If it fails, the probe itself is broken and the two results above mean nothing.
  out.push({ check: 'CONTROL: view still exposes what_to_do', pass: def.includes('what_to_do'), got: def.includes('what_to_do') ? 'present' : 'absent' });

  fs.writeFileSync(__dirname + '/job_step_ledger.out.json', JSON.stringify(out, null, 1));
  for (const o of out) console.log((o.pass ? 'PASS' : 'FAIL').padEnd(5), o.check, '|', o.got);
  process.exit(out.every(o => o.pass) ? 0 : 1);
})();
```

- [ ] **Step 2: Run it and confirm the two real checks FAIL while the control PASSES**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/job_step_ledger.js
```

Expected: `FAIL  ledger columns exist`, `FAIL  view has a job_step branch`, `PASS  CONTROL: view still exposes what_to_do`.

If the control FAILS, stop. The probe cannot see the view and neither result means anything.

- [ ] **Step 3: Write the migration**

Create `docs/migrations/2026-08-19_1930_client_create_attempts_job_step.sql`:

```sql
-- 2026-08-19_1930_client_create_attempts_job_step.sql
--
-- WHAT: record the Service Call job step on the create-client ledger, and give
--       public.v_client_create_attention a branch for a job-step orphan.
--
-- WHY:  create-client is gaining a third step (client, property, JOB). The attention view keys
--       entirely on the client-level `status`, so without a branch here a client that landed
--       perfectly while Jobber kept a job we never recorded is INVISIBLE to the only human-facing
--       reconciliation surface we have.
--
-- 🛑 `status` KEEPS ITS CURRENT MEANING: the CLIENT landed. It is deliberately NOT widened to mean
--    client+property+job, because 'created' RELEASES the code reservation (2026-08-12_2045) and
--    holding the reservation across the job step would turn this ledger into a permanent second
--    registry of client codes. The job step reports through `job_step`, never through `status`.
--
-- AUDIT (rule 8): public.client_create_attempts is NOT audited and stays NOT audited. Measured
--    before writing this: zero audit.log_change triggers on the table. It is an operational ledger
--    written only by the create-client edge function as service_role, it has no human-editable
--    fields, and it is itself the audit record for the flow. Opting it in would duplicate its own
--    contents into audit.logs on every attempt.
--
-- ⚠ THE VIEW IS `CREATE OR REPLACE`, AND THE COLUMN ORDER IS WHY IT CAN BE. OR REPLACE may only
--    APPEND columns, never insert them. `job_step` and `jobber_job_gid` are therefore added AFTER
--    the existing trailing `what_to_do`, which keeps the grants intact. Reordering them to read
--    more naturally would force DROP + CREATE, and DROP VIEW DISCARDS GRANTS.

begin;

alter table public.client_create_attempts
  add column if not exists jobber_job_gid text,
  add column if not exists job_id         bigint,
  add column if not exists job_step       text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'client_create_attempts_job_step_chk') then
    alter table public.client_create_attempts
      add constraint client_create_attempts_job_step_chk
      check (job_step is null or job_step in ('skipped','created','existing','failed','orphaned'));
  end if;
end $$;

comment on column public.client_create_attempts.job_step is
  'Service Call job step outcome: skipped (property_mode=none, there was no property to hang a job on), created, existing (idempotent hit), failed (we tried and it did not happen, nothing was left behind), orphaned (Jobber may hold a job we never recorded). NULL for attempts made before 2026-08-19. ⚠ failed and skipped are deliberately DIFFERENT: skipped means the flow correctly did not try, failed means it tried and did not succeed. Collapsing them hides every real failure inside a legitimate state.';

create or replace view public.v_client_create_attention as
  select
    idempotency_key,
    requested_by,
    client_code,
    status,
    failure_reason,
    jobber_client_gid,
    created_at,
    now() - created_at as age,
    case
      when status = 'orphaned'   then 'Jobber holds this client and we never imported it. Check Jobber, then import or delete it there.'
      when status = 'unknown'    then 'We do not know whether Jobber created this. Check Jobber BEFORE anyone retries.'
      when status = 'started'    then 'Stuck mid-flight. It holds its code reserved. Confirm against Jobber before releasing.'
      when job_step = 'orphaned' then 'The client landed, but Jobber may hold a Service Call job we never recorded. Check Jobber before retrying. There is no jobDelete: the only teardown is jobClose.'
      else null
    end as what_to_do,
    job_step,
    jobber_job_gid
  from client_create_attempts a
  where status in ('orphaned','unknown')
     or (status = 'started' and created_at < now() - interval '5 minutes')
     or job_step = 'orphaned';

-- ---- VERIFY ------------------------------------------------------------------------------------
do $$
declare v_cols int; v_def text; v_seen int;
begin
  select count(*) into v_cols from information_schema.columns
   where table_schema='public' and table_name='client_create_attempts'
     and column_name in ('jobber_job_gid','job_id','job_step');
  if v_cols <> 3 then raise exception 'VERIFY: expected 3 new columns, got %', v_cols; end if;

  select pg_get_viewdef('public.v_client_create_attention'::regclass, true) into v_def;
  if position('job_step' in v_def) = 0 then raise exception 'VERIFY: view has no job_step branch'; end if;
  if position('what_to_do' in v_def) = 0 then raise exception 'VERIFY: view lost what_to_do'; end if;

  -- the CHECK must actually reject a bad value (a constraint that cannot fire is not a constraint)
  begin
    insert into public.client_create_attempts (idempotency_key, requested_by, payload, status, job_step)
    values (gen_random_uuid(), 'verify@probe', '{}'::jsonb, 'failed', 'not_a_valid_value');
    raise exception 'VERIFY: the job_step CHECK did not reject an invalid value';
  exception when check_violation then
    null; -- correct
  end;

  select count(*) into v_seen from public.v_client_create_attention;
  raise notice 'VERIFY ok: 3 columns, view branch present, CHECK rejects bad values, % rows currently need attention', v_seen;
end $$;

commit;
```

- [ ] **Step 4: Apply the migration**

Apply it by POSTing the file's contents to the Management API query endpoint, the same transport the
probes use. Expected: no error, and the `VERIFY ok:` notice.

- [ ] **Step 5: Re-run the probe, expect all PASS**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/job_step_ledger.js
```

Expected: three `PASS` lines.

- [ ] **Step 6: Mutation-test the new view branch**

Prove the branch can actually surface a row, then prove the probe would have caught its absence:

```sql
begin;
insert into public.client_create_attempts (idempotency_key, requested_by, payload, status, job_step)
values ('00000000-0000-0000-0000-0000000000ff', 'mutation@probe', '{}'::jsonb, 'created', 'orphaned');
-- MUST return exactly 1 row, carrying the job sentence
select count(*) as rows_surfaced,
       bool_or(what_to_do like 'The client landed%') as has_job_sentence
  from public.v_client_create_attention
 where idempotency_key = '00000000-0000-0000-0000-0000000000ff';
rollback;
```

Expected: `rows_surfaced = 1`, `has_job_sentence = true`. A `status='created'` attempt is invisible
to the old view, so this row appearing is caused by the new branch and nothing else.

- [ ] **Step 7: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
git add docs/migrations/2026-08-19_1930_client_create_attempts_job_step.sql scripts/probes/job_step_ledger.js
git commit -m "Record the Service Call job step on the create-client ledger

Adds jobber_job_gid, job_id and job_step to public.client_create_attempts and
gives v_client_create_attention a branch for a job-step orphan, which the
client-level status cannot express. status keeps its current meaning because
'created' releases the code reservation.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 2: Answer the one unverified question, before building on it

The spec's `none` path assumes Jobber accepts `clientCreate` with a `billingAddress` and no
`properties[]`. That is the only design assumption not yet measured. Answer it now, because Task 7
depends on it.

**Files:**
- Create: `scripts/probes/jobber_property_mode_contract.js`

- [ ] **Step 1: Write the probe**

It runs `clientCreate` in Jobber's **dry-run-free** world, so it must create and then archive. Jobber
has `clientArchive`, so a test client IS recoverable, unlike a job.

```js
// Answers: what property rows does Jobber mint for each of our three property_mode shapes?
// Creates up to 3 real Jobber clients and ARCHIVES them again (clientArchive exists; clientDelete
// does not). Run it once. Read the output, then delete nothing by hand.
const { execSync } = require('child_process');
const fs = require('fs');
const token = execSync('./jobber-token.sh', { cwd: 'C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Slack' }).toString().trim();

async function gql(query, variables) {
  const r = await fetch('https://api.getjobber.com/api/graphql', {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'X-JOBBER-GRAPHQL-VERSION': '2026-04-16' },
    body: JSON.stringify({ query, variables }),
  });
  const ctype = r.headers.get('content-type') ?? '';
  if (!ctype.includes('json')) throw new Error(`Jobber waiting room: ${ctype} at HTTP ${r.status}`);
  return r.json();
}

const ADDR = { street1: '1 Contract Probe Way', city: 'Miami Beach', province: 'FL', postalCode: '33139', country: 'USA' };

const CASES = [
  { mode: 'client_address', input: { isCompany: true, companyName: 'ZZ Probe client_address', properties: [{ address: ADDR }] } },
  { mode: 'separate',       input: { isCompany: true, companyName: 'ZZ Probe separate', properties: [{ address: { ...ADDR, street1: '2 Property Way' } }], billingAddress: ADDR } },
  { mode: 'none',           input: { isCompany: true, companyName: 'ZZ Probe none', billingAddress: ADDR } },
];

(async () => {
  const out = [];
  for (const c of CASES) {
    let res;
    try { res = await gql(`mutation($input: ClientCreateInput!){ clientCreate(input:$input){ client { id } userErrors { message } } }`, { input: c.input }); }
    catch (e) { out.push({ mode: c.mode, error: String(e.message) }); continue; }
    const errs = res.data?.clientCreate?.userErrors ?? [];
    const id = res.data?.clientCreate?.client?.id ?? null;
    if (!id) { out.push({ mode: c.mode, accepted: false, userErrors: errs.map(e => e.message), graphqlErrors: (res.errors ?? []).map(e => e.message) }); continue; }
    const read = await gql(`query($id: EncodedId!){ client(id:$id){ id billingAddress { street1 city } properties(first:5){ nodes { id address { street1 city } } } } }`, { id });
    const cl = read.data?.client;
    out.push({
      mode: c.mode, accepted: true, client_gid: id,
      billing: cl?.billingAddress?.street1 ?? null,
      property_count: cl?.properties?.nodes?.length ?? 0,
      properties: (cl?.properties?.nodes ?? []).map(n => ({ gid: n.id, street: n.address?.street1 })),
    });
    await gql(`mutation($id: EncodedId!){ clientArchive(id:$id){ client { id } userErrors { message } } }`, { id });
  }
  fs.writeFileSync(__dirname + '/jobber_property_mode_contract.out.json', JSON.stringify(out, null, 1));
  console.log(JSON.stringify(out, null, 1));
})();
```

- [ ] **Step 2: Run it once**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/jobber_property_mode_contract.js
```

- [ ] **Step 3: Read the result and record the decision**

The load-bearing question is the `none` row:

- `accepted: true` and `property_count: 0` means the spec's `none` path works as designed. Continue.
- `accepted: true` and `property_count: 1` means Jobber mints a property from `billingAddress`
  anyway. The `none` path then produces a property we did not ask for, and Task 7 must send neither
  `properties[]` NOR `billingAddress`, storing the address only on our own `clients` row. Write that
  finding into the spec before continuing.
- `accepted: false` means `clientCreate` requires an address shape we are not sending. Stop and take
  it back to Fred; the `none` path as ruled is not implementable and he chooses the fallback.

Record the actual answer in the spec's "Verification plan" section, replacing the item that says this
is unverified. Do not leave the spec claiming an open question that is now closed.

- [ ] **Step 4: Confirm the three probe clients are archived in Jobber**

Search Jobber for `ZZ Probe`. Every hit must show as archived. If `clientArchive` failed for any of
them, archive it by hand now: there is no `clientDelete`, so an unarchived probe client would sit in
the real client list and could sync into `public.clients` on the next poll.

- [ ] **Step 5: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
git add scripts/probes/jobber_property_mode_contract.js docs/superpowers/specs/2026-08-19-sc-job-auto-creation-design.md
git commit -m "Measure what Jobber mints for each property_mode shape

Answers the one design assumption the spec could not verify by reading: whether
clientCreate accepts a billingAddress with no properties[], and what property
rows each shape produces. Creates three probe clients and archives them.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 3: The `ensureServiceCallJob` helper

**Files:**
- Create: `supabase/functions/_shared/service-call-job.ts`

- [ ] **Step 1: Write the helper**

Create `supabase/functions/_shared/service-call-job.ts`:

```ts
// The ONE definition of "a property gets a Service Call job". Every path that creates a property
// calls this. Do not assemble the rule a second time anywhere: two copies of one rule is how the
// 2026-08-18 custom-field sync defects were born.
//
// 🛑 THERE IS NO jobDelete AND NO jobArchive. The only teardown is jobClose(DESTROY_ALL), which also
//    destroys the job's scheduled visits. Every check therefore runs BEFORE Jobber is touched, and
//    every DB read that gates the create FAILS CLOSED: a discarded supabase-js error returns
//    data:null, which reads as "no job exists" and would create a duplicate that cannot be removed.
//
// 🛑 THIS DOES NOT BUILD THE JOB ITSELF. save-client-job already creates SC jobs (9 live ones came
//    through it), and it owns the read-back verify and the atomic row+link write via
//    fn_record_client_job. Reimplementing any of that here would be a second assembly of the same
//    rule. This function decides WHETHER, and delegates HOW.

export type EnsureResult =
  | { ok: true;  created: boolean; job_id: number; detail: string }
  | { ok: false; reason: "property_not_in_jobber" | "link_lookup_failed" | "job_lookup_failed"
                       | "job_create_failed" | "job_create_unreadable" | "job_not_recorded";
      detail: string };

const TERMINAL = ["archived", "closed", "destroyed"];

/** A live Service Call job on this property, or null. Title is compared TRIMMED and LOWERCASED. */
function findServiceCall(jobs: Array<{ id: number; title: string | null }> | null) {
  // ⚠ Compared in JS, not in PostgREST. The DB predicate is lower(btrim(title)) = 'service call',
  // which PostgREST cannot express: .ilike() does not trim, and 19 live rows read 'Service call'
  // with one carrying a trailing space. A property holds a handful of jobs, so filtering here is
  // cheap and exact.
  return (jobs ?? []).find((j) => String(j.title ?? "").trim().toLowerCase() === "service call") ?? null;
}

export async function ensureServiceCallJob(opts: {
  db: any;              // supabase-js client, service_role
  authHeader: string;   // the CALLER's Authorization header, forwarded so the write is attributed
  clientId: number;
  propertyId: number;
}): Promise<EnsureResult> {
  const { db, authHeader, clientId, propertyId } = opts;

  // ---- 1. resolve the property's REAL Jobber GID --------------------------------------------
  // 🛑 A '<gid>_billing' link is NOT a property id. All 428 of them decode to
  //    gid://Jobber/Client/<n> with the literal ASCII '_billing' appended, so jobCreate rejects
  //    them. Select on the LINK SHAPE, never on properties.is_billing: that column happens to be a
  //    perfect proxy today, but it is written by two independent writers and is not an enforced
  //    invariant. Filtering is done in JS because a LIKE pattern of '%\_billing' puts an escape in
  //    the wire format, and '_' is itself a LIKE wildcard.
  const { data: links, error: linkErr } = await db
    .from("entity_source_links")
    .select("source_id")
    .eq("entity_type", "property")
    .eq("entity_id", propertyId)
    .eq("source_system", "jobber");
  if (linkErr) {
    return { ok: false, reason: "link_lookup_failed", detail: `Could not read the property's Jobber link: ${linkErr.message}` };
  }
  const realGid = (links ?? []).map((l: any) => String(l.source_id)).find((s: string) => !s.endsWith("_billing"));
  if (!realGid) {
    return { ok: false, reason: "property_not_in_jobber",
      detail: "This property has no real Jobber property link (only a billing twin, or none at all), so no job can be created on it." };
  }

  // ---- 2. idempotency, BEFORE Jobber ---------------------------------------------------------
  const { data: before, error: jobErr } = await db
    .from("jobs")
    .select("id,title")
    .eq("property_id", propertyId)
    .not("job_status", "in", `(${TERMINAL.join(",")})`);
  if (jobErr) {
    // FAIL CLOSED. Proceeding on an unread table in front of an operation with no undo is the one
    // outcome that cannot be repaired.
    return { ok: false, reason: "job_lookup_failed", detail: `Could not check for an existing Service Call: ${jobErr.message}` };
  }
  const existing = findServiceCall(before);
  if (existing) {
    return { ok: true, created: false, job_id: Number(existing.id), detail: "This property already has a Service Call job." };
  }

  // ---- 3. delegate ---------------------------------------------------------------------------
  // Send NOTHING else. services and fees are hard-refused for SC (Fred, 2026-08-06: an SC job
  // carries no line items at all), and start_date / frequency_days are silently ignored.
  let r: Response;
  try {
    r = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/save-client-job`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: authHeader },
      body: JSON.stringify({
        action: "create",
        client_id: clientId,
        patch: { kind: "SC", property_id: propertyId, billing_type: "visit_based", invoice_frequency: "per_visit" },
      }),
    });
  } catch (e) {
    return { ok: false, reason: "job_create_unreadable", detail: `Could not reach save-client-job: ${e instanceof Error ? e.message : String(e)}` };
  }
  const ctype = r.headers.get("content-type") ?? "";
  if (!ctype.includes("json")) {
    return { ok: false, reason: "job_create_unreadable", detail: `save-client-job returned ${ctype || "an unknown content type"} at HTTP ${r.status}` };
  }
  let j: any = {};
  try { j = await r.json(); } catch { j = {}; }
  if (!r.ok || j?.ok === false) {
    return { ok: false, reason: "job_create_failed", detail: String(j?.message ?? `save-client-job returned HTTP ${r.status}`) };
  }

  // ---- 4. verify what LANDED, re-read, never echoed --------------------------------------------
  // A remote object created while the local write failed is worse than a failed push
  // (jobber-push-task, 2026-08-06). Ask our own DB what is on the property now.
  const { data: after, error: afterErr } = await db
    .from("jobs")
    .select("id,title")
    .eq("property_id", propertyId)
    .not("job_status", "in", `(${TERMINAL.join(",")})`);
  if (afterErr) {
    return { ok: false, reason: "job_not_recorded", detail: `save-client-job reported success but we could not verify: ${afterErr.message}` };
  }
  const landed = findServiceCall(after);
  if (!landed) {
    return { ok: false, reason: "job_not_recorded",
      detail: "save-client-job reported success but no Service Call job is on this property. Jobber may hold a job we never recorded." };
  }
  return { ok: true, created: true, job_id: Number(landed.id), detail: "Service Call job created." };
}
```

- [ ] **Step 2: Type-check it**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && deno check supabase/functions/_shared/service-call-job.ts
```

Expected: no errors. If `deno` is not on PATH, skip this step; the deploy in Task 6 will surface any
type error.

- [ ] **Step 3: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
git add supabase/functions/_shared/service-call-job.ts
git commit -m "Add ensureServiceCallJob, the single definition of the per-property SC rule

Resolves the property's real Jobber GID (never a _billing twin), checks for an
existing Service Call BEFORE touching Jobber because there is no jobDelete, then
delegates to save-client-job rather than reimplementing job creation. Every DB
read that gates the create fails closed.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 4: Test the helper's behaviour without creating anything

Every branch except the successful create can be proven for free. Do those first, so the one
irreversible arm in Task 5 runs against a helper already known to be sound.

**Files:**
- Create: `scripts/probes/ensure_sc_job.js`

- [ ] **Step 1: Write the probe**

```js
// Arms A, B, C are FREE: they must all refuse or short-circuit before Jobber is touched.
// Arm D (the real create) lives in Task 5 and COMMITS.
require('dotenv').config({ path: __dirname + '/../../.env' });
const fs = require('fs');

async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  const t = await r.text();
  try { return JSON.parse(t); } catch { return { error: t.slice(0, 300) }; }
}

(async () => {
  const out = [];

  // Fixture: a property whose ONLY jobber link is a billing twin.
  const twin = await sql(`
    select p.id from properties p
    where exists (select 1 from entity_source_links e where e.entity_type='property'
                  and e.entity_id=p.id and e.source_system='jobber' and e.source_id like '%_billing')
      and not exists (select 1 from entity_source_links e2 where e2.entity_type='property'
                  and e2.entity_id=p.id and e2.source_system='jobber' and e2.source_id not like '%_billing')
    limit 1`);
  out.push({ check: 'fixture: a billing-twin-only property exists', pass: Array.isArray(twin) && twin.length === 1, got: JSON.stringify(twin).slice(0, 80) });

  // Fixture: a property that ALREADY has a live Service Call (the idempotency target).
  const withSc = await sql(`
    select j.property_id, j.id as job_id from jobs j
    where lower(btrim(j.title))='service call'
      and j.job_status not in ('archived','closed','destroyed')
      and j.property_id is not null
    limit 1`);
  out.push({ check: 'fixture: a property with a live SC job exists', pass: Array.isArray(withSc) && withSc.length === 1, got: JSON.stringify(withSc).slice(0, 80) });

  // POSITIVE CONTROL for the title matcher. These strings MUST classify as this table says, or the
  // helper's findServiceCall() is not doing what the probe assumes and every arm below is untested.
  const cases = [
    ['Service Call', true], ['Service call', true], ['  service call  ', true],
    ['Service Agreement - Pumping', false], ['Service Call - 341', false], ['', false],
  ];
  const matcher = (t) => String(t ?? '').trim().toLowerCase() === 'service call';
  const bad = cases.filter(([t, want]) => matcher(t) !== want);
  out.push({ check: 'CONTROL: title matcher classifies all 6 fixtures correctly', pass: bad.length === 0, got: bad.length ? JSON.stringify(bad) : 'all 6 correct' });

  fs.writeFileSync(__dirname + '/ensure_sc_job.out.json', JSON.stringify(out, null, 1));
  for (const o of out) console.log((o.pass ? 'PASS' : 'FAIL').padEnd(5), o.check, '|', o.got);
  process.exit(out.every(o => o.pass) ? 0 : 1);
})();
```

- [ ] **Step 2: Run it**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/ensure_sc_job.js
```

Expected: three `PASS` lines. The third is the control: if the title matcher misclassifies anything,
fix `findServiceCall()` in `service-call-job.ts` before going further.

Note `'Service Call - 341'` must be `false`. Equality is deliberate. `ops.client_jobs` classifies on
a `service call%` PREFIX and would call that row a Service Call, but our idempotency check must not,
or a differently-titled job would suppress the one we owe the property.

- [ ] **Step 3: Test the helper's BEHAVIOUR, not just its fixtures**

The probe above proves the fixtures exist. It does not prove the helper does the right thing with
them, and the helper is a module that no deployed function exposes on its own. Test the branches
directly with a stubbed client. Deno's test runner is built in, so nothing needs installing.

Create `supabase/functions/_shared/service-call-job.test.ts`:

```ts
import { assertEquals } from "https://deno.land/std@0.208.0/assert/mod.ts";
import { ensureServiceCallJob } from "./service-call-job.ts";

/** Minimal stand-in for the supabase-js query builder, enough for this helper's two reads. */
function stubDb(opts: {
  links?: { data: any; error: any };
  jobs?: { data: any; error: any };
}) {
  return {
    from(table: string) {
      const result = table === "entity_source_links"
        ? (opts.links ?? { data: [], error: null })
        : (opts.jobs ?? { data: [], error: null });
      const chain: any = {
        select: () => chain, eq: () => chain, not: () => chain,
        then: (res: any) => Promise.resolve(result).then(res),
      };
      return chain;
    },
  };
}

const ARGS = { authHeader: "Bearer test", clientId: 1, propertyId: 2 };

Deno.test("refuses a property whose only Jobber link is a billing twin", async () => {
  const db = stubDb({ links: { data: [{ source_id: "Z2lkOi8vSm9iYmVyL0NsaWVudC8x_billing" }], error: null } });
  const r = await ensureServiceCallJob({ db, ...ARGS });
  assertEquals(r.ok, false);
  if (!r.ok) assertEquals(r.reason, "property_not_in_jobber");
});

Deno.test("refuses a property with no Jobber link at all", async () => {
  const db = stubDb({ links: { data: [], error: null } });
  const r = await ensureServiceCallJob({ db, ...ARGS });
  assertEquals(r.ok, false);
  if (!r.ok) assertEquals(r.reason, "property_not_in_jobber");
});

Deno.test("FAILS CLOSED when the link lookup errors", async () => {
  const db = stubDb({ links: { data: null, error: { message: "connection reset" } } });
  const r = await ensureServiceCallJob({ db, ...ARGS });
  assertEquals(r.ok, false);
  if (!r.ok) assertEquals(r.reason, "link_lookup_failed");
});

Deno.test("FAILS CLOSED when the existing-job lookup errors, and never reaches Jobber", async () => {
  const db = stubDb({
    links: { data: [{ source_id: "Z2lkOi8vSm9iYmVyL1Byb3BlcnR5LzE=" }], error: null },
    jobs: { data: null, error: { message: "statement timeout" } },
  });
  const r = await ensureServiceCallJob({ db, ...ARGS });
  assertEquals(r.ok, false);
  if (!r.ok) assertEquals(r.reason, "job_lookup_failed");
});

Deno.test("is idempotent: an existing Service Call short-circuits before Jobber", async () => {
  const db = stubDb({
    links: { data: [{ source_id: "Z2lkOi8vSm9iYmVyL1Byb3BlcnR5LzE=" }], error: null },
    jobs: { data: [{ id: 77, title: "  Service call  " }], error: null },
  });
  const r = await ensureServiceCallJob({ db, ...ARGS });
  assertEquals(r.ok, true);
  if (r.ok) { assertEquals(r.created, false); assertEquals(r.job_id, 77); }
});

Deno.test("a Service-Agreement job does NOT satisfy the check", async () => {
  // MUTATION CONTROL: if this passes as 'existing', the matcher is too loose and a client with an
  // SA job would silently never get the Service Call it is owed. Reaching the fetch is the correct
  // behaviour here, so this asserts we got PAST the idempotency check.
  const db = stubDb({
    links: { data: [{ source_id: "Z2lkOi8vSm9iYmVyL1Byb3BlcnR5LzE=" }], error: null },
    jobs: { data: [{ id: 88, title: "Service Agreement - Pumping" }], error: null },
  });
  const r = await ensureServiceCallJob({ db, ...ARGS });
  // No SUPABASE_URL in the test env, so the delegate call fails; the point is that it TRIED.
  assertEquals(r.ok, false);
  if (!r.ok) assertEquals(r.reason === "job_create_unreadable" || r.reason === "job_create_failed", true);
});
```

Run it:

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && deno test --allow-net --allow-env supabase/functions/_shared/service-call-job.test.ts
```

Expected: `ok | 6 passed | 0 failed`.

The last test is the mutation control. Comment out the `.trim()` in `findServiceCall()` and re-run:
the `"  Service call  "` idempotency test MUST fail. Restore it. A suite that cannot fail is not
testing anything.

- [ ] **Step 4: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
git add scripts/probes/ensure_sc_job.js supabase/functions/_shared/service-call-job.test.ts
git commit -m "Probe the free arms of ensureServiceCallJob

Fixtures for the billing-twin and already-has-a-job cases, plus a positive
control on the title matcher covering the 19 live 'Service call' rows and the
prefix case that must NOT match.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 5: Deploy the helper's caller and exercise the one arm that commits

The helper is a module, not a function, so it cannot be deployed or called on its own. It ships with
`create-client` in Task 8. This task is the live exercise, and it is placed here so the plan does not
pretend the create arm was ever free.

- [ ] **Step 1: Read this before running anything**

`112-YA` has **zero** active Service Call jobs (measured 2026-08-19). The create arm will mint a
real Jobber job on it. There is no `jobDelete` and no `jobArchive`. The job is permanent, and
closing it later requires `jobClose(DESTROY_ALL)`, which also destroys any visits on it.

This is accepted: 112-YA is the sanctioned test client and should carry a Service Call anyway. Run it
**once**. Do not loop it, and do not run it against any other client.

- [ ] **Step 2: Defer this task until Task 8 is deployed**

Return here after Task 8. The exercise is:

```bash
curl -s -X POST "https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/save-client-job" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <a real staff JWT>" \
  -d '{"action":"create","client_id":<112-YA client id>,"patch":{"kind":"SC","property_id":<its real property id>,"billing_type":"visit_based","invoice_frequency":"per_visit"}}'
```

- [ ] **Step 3: Assert on what LANDED, not on the response**

```sql
select j.id, j.title, j.job_status, j.frequency_days, j.billing_type, j.invoice_frequency,
       j.start_at, j.property_id,
       (select count(*) from line_items li where li.job_id = j.id) as job_scoped_lines,
       (select e.source_id from entity_source_links e
         where e.entity_type='job' and e.entity_id=j.id and e.source_system='jobber') as jobber_link
  from jobs j
 where j.property_id = <its real property id>
   and lower(btrim(j.title)) = 'service call';
```

Expected, every field: `title` exactly `Service Call`; `frequency_days = 0`; `start_at` NULL;
`billing_type = visit_based`; `invoice_frequency = per_visit`; `job_scoped_lines = 0`;
`jobber_link` a real base64 GID.

- [ ] **Step 4: Prove the app can see it**

```sql
select job_kind, count(*) from ops.client_service_options
 where client_id = <112-YA client id> group by job_kind;
```

Expected: an `SC` row appears. A title check alone is not enough. The consequence that matters is
whether the Calendar can dispatch against the job, and that is what this view answers.

- [ ] **Step 5: Re-run the helper's idempotency arm**

Call the same curl a second time through `create-client`'s path (not `save-client-job` directly, which
has no idempotency check of its own). It must report `created: false` and Jobber must still hold
exactly ONE Service Call for that property. Confirm in Jobber's UI, not only in our DB.

---

## Task 6: Fix `create-client`'s missing content-type guard

This is a live bug in the function the rest of Phase 1 builds on, and it bites BEFORE the mutation.

**Files:**
- Modify: `supabase/functions/create-client/index.ts:127-155` (the `gql` helper)

- [ ] **Step 1: Add the guard**

In `supabase/functions/create-client/index.ts`, inside `gql()`, immediately after the `fetch` and its
`catch`, and BEFORE `let j: any = {}`:

```ts
  // 🛑 JOBBER SHEDS LOAD WITH AN HTML "WAITING ROOM" AT HTTP 200. Not 429, not 5xx, no errors array.
  // Without this, `r.json()` throws, `j` becomes {}, neither the 500 check nor the errors check
  // fires, and this returns ok:true with data UNDEFINED. In THIS function that lands before the
  // mutation: the Jobber-side client-code uniqueness check and both duplicate searches read a
  // missing answer as "the code is free" and "there are no duplicates". An outage then presents as
  // a green pre-check. Content-type is the only honest discriminator; the status lies.
  const ctype = r.headers.get("content-type") ?? "";
  if (!ctype.includes("json")) {
    return { ok: false, kind: "busy",
      detail: `Jobber returned ${ctype || "an unknown content type"} at HTTP ${r.status} (its waiting room), not GraphQL` };
  }
```

- [ ] **Step 2: Confirm `busy` maps to a safe retry**

Read the `RETRY` map at `create-client/index.ts:83-95`. `kind: "busy"` surfaces through the
`jobber_unavailable` failure code, which is already mapped `"safe"`. That is correct here: the guard
fires before anything is created, so a resubmit is genuinely safe. Change nothing.

- [ ] **Step 3: Deploy**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
SUPABASE_ACCESS_TOKEN=<PAT> supabase functions deploy create-client --project-ref wbasvhvvismukaqdnouk
```

Respect `config.toml`. Never pass `--no-verify-jwt` unless it is already set for this function.

- [ ] **Step 4: Verify the function still works end to end**

```bash
curl -s -X POST "https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/create-client" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <a real staff JWT>" \
  -d '{"propose_only":true,"name":"Guard Regression Check"}'
```

Expected: a JSON body containing a `proposal`. The propose path calls `proposeCode`, not Jobber, so
this proves the deploy is healthy without touching Jobber.

- [ ] **Step 5: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
git add supabase/functions/create-client/index.ts
git commit -m "Guard create-client against Jobber's HTML waiting room

Jobber sheds load with text/html at HTTP 200. Without a content-type check the
gql helper returned ok:true with data undefined, so the code-uniqueness check
and both duplicate searches read an outage as 'the code is free' and 'no
duplicates found', in front of a clientCreate that cannot be undone.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 7: Add `property_mode` to `create-client`

**Files:**
- Modify: `supabase/functions/create-client/index.ts:456-465` (address validation)
- Modify: `supabase/functions/create-client/index.ts:589-604` (the `input` construction)

- [ ] **Step 1: Parse and validate the new field**

Replace the address validation block at `create-client/index.ts:456-465`:

```ts
  const isCompany = body?.is_company !== false; // default: a business
  const street = norm(body?.street);
  const city = norm(body?.city);
  const postalCode = norm(body?.postal_code);

  // ---- property_mode -------------------------------------------------------
  // client_address : the one address becomes the first property (today's behaviour, the default)
  // separate       : property_* is the property; the client's own address becomes billingAddress
  // none           : no property at all; the address is stored as billingAddress only
  const property_mode = body?.property_mode === undefined ? "client_address" : String(body.property_mode);
  if (!["client_address", "separate", "none"].includes(property_mode)) {
    return fail("bad_request", `property_mode must be client_address, separate or none. Got "${property_mode}".`);
  }
  const propStreet = norm(body?.property_street);
  const propCity = norm(body?.property_city);
  const propPostalCode = norm(body?.property_postal_code);

  if (!street || !city || !postalCode) {
    return fail("bad_request",
      property_mode === "none"
        ? "Street, city and ZIP are required as the client's billing address, even with no property."
        : "Street, city and ZIP are required. A client with no property cannot be given a job later: jobCreate needs a Jobber propertyId.",
      { fields: [!street ? "street" : null, !city ? "city" : null, !postalCode ? "postal_code" : null].filter(Boolean) });
  }
  if (property_mode === "separate" && (!propStreet || !propCity || !propPostalCode)) {
    return fail("bad_request",
      "The property address needs a street, city and ZIP. Tick 'use this address as the first property' to reuse the client's address instead.",
      { fields: [!propStreet ? "property_street" : null, !propCity ? "property_city" : null, !propPostalCode ? "property_postal_code" : null].filter(Boolean) });
  }
```

- [ ] **Step 2: Build the Jobber input per mode**

Replace the `properties` line inside the `input` object at `create-client/index.ts:603`:

```ts
  const input: Record<string, unknown> = {
    isCompany,
    customFields: [{ customFieldConfigurationId: CODE_CF_GID, valueText: code }],
  };
  // ⚠ THE ADDRESS IS NESTED. PropertyAttributes is { address: AddressAttributes!, ... }; the
  // street/city/postalCode fields live on AddressAttributes, not on PropertyAttributes.
  const asAddress = (s: string, c: string, z: string) =>
    ({ street1: s, city: c, postalCode: z, province: "FL", country: "USA" });

  if (property_mode === "client_address") {
    // ⚠ NO billingAddress. Sending one makes Jobber mint a SECOND, billing-only property whose only
    // link is a synthetic "<gid>_billing" id, which is not a real EncodedId and which jobCreate
    // rejects. properties[] alone yields one real, job-capable property.
    input.properties = [{ address: asAddress(street, city, postalCode) }];
  } else if (property_mode === "separate") {
    input.properties = [{ address: asAddress(propStreet, propCity, propPostalCode) }];
    input.billingAddress = asAddress(street, city, postalCode);
  } else {
    // none: no properties[] at all. Task 2 measured what Jobber does with this shape; if it minted a
    // property anyway, this branch sends neither and the address lives only on our clients row.
    input.billingAddress = asAddress(street, city, postalCode);
  }
```

- [ ] **Step 3: Reflect the mode in the dry-run response**

The dry-run block at `create-client/index.ts:630-638` already returns `would_send: { mutation, input }`,
so the new shape is visible with no change. Add `property_mode` alongside it so the caller can see
which branch was taken:

```ts
      would_send: { mutation: "clientCreate", input, property_mode },
```

- [ ] **Step 4: Dry-run all three modes**

```bash
curl -s -X POST "https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/create-client" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <a real staff JWT>" \
  -d '{"dry_run":true,"idempotency_key":"11111111-1111-1111-1111-111111111111","name":"Mode Check","street":"1 A St","city":"Miami","postal_code":"33139","property_mode":"separate","property_street":"2 B St","property_city":"Miami Beach","property_postal_code":"33141"}'
```

Expected for `separate`: `input.properties[0].address.street1 = "2 B St"` and
`input.billingAddress.street1 = "1 A St"`. Repeat with `"property_mode":"none"` (expect no
`properties` key at all) and with the field omitted (expect today's shape, `properties` present and
no `billingAddress`).

- [ ] **Step 5: Confirm the refusals fire**

```bash
curl -s -X POST "https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/create-client" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <a real staff JWT>" \
  -d '{"dry_run":true,"idempotency_key":"11111111-1111-1111-1111-111111111112","name":"Mode Check","street":"1 A St","city":"Miami","postal_code":"33139","property_mode":"separate"}'
```

Expected: `bad_request` naming `property_street`, `property_city`, `property_postal_code`. Then send
`"property_mode":"nonsense"` and expect the enum refusal. Both must fail BEFORE anything is created.

- [ ] **Step 6: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
git add supabase/functions/create-client/index.ts
git commit -m "Add property_mode to create-client

client_address keeps today's behaviour and stays the default. separate takes a
distinct property address and puts the client's own address on billingAddress.
none creates no property and stores the address as billing only, returning
schedulable:false in the next commit.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 8: Call `ensureServiceCallJob` from `create-client` and record the step

**Files:**
- Modify: `supabase/functions/create-client/index.ts` (imports, and the tail after the property replay at `:822`)

- [ ] **Step 1: Import the helper**

At the top of `create-client/index.ts`, alongside the existing imports:

```ts
import { ensureServiceCallJob } from "../_shared/service-call-job.ts";
```

- [ ] **Step 2: Call it after the primary-property repair**

In `create-client/index.ts`, immediately after the `fn_fix_billing_primary_property` call at `:830`
and before the "report what LANDED" block:

```ts
  // ---- the Service Call job -------------------------------------------------
  // 🛑 ORDER: after fn_fix_billing_primary_property, because that repair decides which property is
  //    primary, and after the PROPERTY_CREATE replay, because the helper needs a real property link
  //    to exist. A job cannot be created before its property is canonical here.
  // 🛑 A FAILURE HERE NEVER ROLLS BACK THE CLIENT OR THE PROPERTY. There is no clientDelete. The
  //    client is real and correct; only the job is missing, and that is a repairable state that the
  //    attention view now surfaces.
  let jobStep: "skipped" | "created" | "existing" | "failed" | "orphaned" = "skipped";
  let jobId: number | null = null;
  let jobNote: string | null = null;

  if (property_mode === "none") {
    jobNote = "No property was created, so this client has no Service Call job and cannot be scheduled yet.";
  } else {
    const { data: realProp } = await db
      .from("properties").select("id").eq("client_id", clientId).eq("is_billing", false)
      .order("id", { ascending: false }).limit(1).maybeSingle();
    if (!realProp?.id) {
      jobStep = "orphaned";
      jobNote = "The property did not materialise here, so no Service Call job was created.";
    } else {
      const res = await ensureServiceCallJob({
        db,
        authHeader: req.headers.get("authorization") ?? "",
        clientId,
        propertyId: Number(realProp.id),
      });
      if (res.ok) {
        jobStep = res.created ? "created" : "existing";
        jobId = res.job_id;
        jobNote = res.detail;
      } else {
        // 🛑 'job_not_recorded' is the dangerous one: save-client-job reported success but no job is
        //    on the property, so Jobber may hold one we never wrote down. That is the ONLY reason
        //    that earns 'orphaned', because 'orphaned' is what puts the attempt in front of a human.
        //    Every other reason refused BEFORE Jobber was touched and left nothing behind, so it is
        //    'failed', never 'skipped': skipped means the flow correctly did not try.
        jobStep = res.reason === "job_not_recorded" ? "orphaned" : "failed";
        jobNote = res.detail;
      }
    }
  }

  await db.from("client_create_attempts")
    .update({ job_step: jobStep, job_id: jobId })
    .eq("idempotency_key", idem);
```

- [ ] **Step 3: Report it in the success payload**

In the success `done({ ... })` block at the end of the function, add:

```ts
    job: { step: jobStep, job_id: jobId, note: jobNote },
    schedulable: jobStep === "created" || jobStep === "existing",
```

- [ ] **Step 4: Deploy**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
SUPABASE_ACCESS_TOKEN=<PAT> supabase functions deploy create-client --project-ref wbasvhvvismukaqdnouk
```

- [ ] **Step 5: Go back and complete Task 5**

Task 5's live arms can only run now. Complete every step of Task 5 before continuing, including the
`ops.client_service_options` check and the idempotency re-run.

- [ ] **Step 6: Exercise `separate` and `none` live, once each**

Task 7 proved the payload SHAPE by dry run and Task 2 proved what Jobber does with each shape. Only
the default mode has been through the real flow. Do the other two once each, on throwaway clients.

⚠ This creates two real Jobber clients. `clientArchive` exists (unlike `jobDelete`), so they are
recoverable, but the Service Call job the `separate` run creates is NOT. Accept one permanent job on
one archived client, or skip the `separate` live run and rely on the dry run plus Task 2. State which
you chose in the commit message rather than leaving it ambiguous.

```bash
# separate: expect a property at the SECOND address, plus a Service Call job
curl -s -X POST "https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/create-client" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <a real staff JWT>" \
  -d '{"idempotency_key":"22222222-2222-2222-2222-222222222221","name":"ZZ Mode Separate","street":"1 Billing St","city":"Miami","postal_code":"33139","property_mode":"separate","property_street":"2 Service St","property_city":"Miami Beach","property_postal_code":"33141"}'

# none: expect NO non-billing property, no job, schedulable:false
curl -s -X POST "https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/create-client" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <a real staff JWT>" \
  -d '{"idempotency_key":"22222222-2222-2222-2222-222222222222","name":"ZZ Mode None","street":"3 Billing Only Ave","city":"Miami","postal_code":"33139","property_mode":"none"}'
```

Assert on the DB, not on the responses:

```sql
select c.client_code, c.name,
       count(*) filter (where p.is_billing = false) as real_properties,
       count(*) filter (where p.is_billing = true)  as billing_properties,
       (select count(*) from jobs j
         where j.client_id = c.id and lower(btrim(j.title)) = 'service call'
           and j.job_status not in ('archived','closed','destroyed')) as sc_jobs,
       min(p.address) filter (where p.is_billing = false) as service_address
  from clients c left join properties p on p.client_id = c.id
 where c.name in ('ZZ Mode Separate','ZZ Mode None')
 group by c.id, c.client_code, c.name;
```

Expected: `ZZ Mode Separate` has `real_properties = 1`, `sc_jobs = 1`, and `service_address` starting
`2 Service St` (NOT `1 Billing St`, which is the whole point of the mode). `ZZ Mode None` has
`real_properties = 0` and `sc_jobs = 0`.

Then archive both in Jobber and confirm they flip to INACTIVE here on the next poll. Do not
hard-delete them: soft-delete only, and `entity_source_links` has no audit trigger, so a hard delete
leaves no record.

- [ ] **Step 7: Verify the ledger recorded the step**

```sql
select idempotency_key, status, job_step, job_id, client_code
  from public.client_create_attempts
 order by created_at desc limit 5;
```

Expected: the `client_address` and `separate` attempts show `job_step` of `created` or `existing`
with a non-null `job_id`; the `none` attempt shows `job_step = 'skipped'` with a NULL `job_id`. A
`none` attempt showing `failed` means the mode branch fell through to the helper, which it must not.

- [ ] **Step 8: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
git add supabase/functions/create-client/index.ts
git commit -m "Create a Service Call job as the third step of create-client

Runs after the primary-property repair, because that decides which property is
primary and the helper needs a real property link. A failure never rolls back
the client or the property: there is no clientDelete, and the missing job is a
repairable state the attention view now surfaces.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 9: The Clients App checkbox

**Lovable project:** `dbf2133c-539c-48ff-864a-68eb284a569d` ("Client View Pro")

- [ ] **Step 1: Claim the project**

Append your claim to `WORKING-NOW.md` at the workspace root and commit it in the same breath. Two
sessions in one Lovable project share a working tree, and a Publish ships BOTH sessions' pending
changes.

- [ ] **Step 2: Send the prompt**

Keep it on ONE line. The editor treats every newline as submit.

```
In the New Client dialog, add a checkbox directly above the address fields, labelled "Use this address as the first property", checked by default, id "new-client-use-as-property". When it is CHECKED, behave exactly as today and send "property_mode":"client_address" in the create-client request body. When it is UNCHECKED, send "property_mode":"none" instead, and show a muted inline note under the checkbox reading "This client will have no service address and cannot be scheduled until you add a property." Do not add any second address block to this dialog. Change nothing else about the dialog, its validation, or its existing fields.
```

- [ ] **Step 3: Confirm the send registered**

The composer must clear AND a Stop button must appear. If the composer keeps its text, a modal is
swallowing the click: screenshot first. If the composer cleared but no Stop button appeared, reload
before re-sending, because the prompt has probably already landed.

- [ ] **Step 4: Publish, then verify against the LIVE bundle**

Reload the editor before publishing. The publish panel can read "Up to date" while the live artifact
lacks the change.

```bash
curl -s https://clients.unclogme.app/ | grep -o '/assets/[A-Za-z0-9._-]*\.js' | head -20
```

Walk the chunks to closure and grep for `new-client-use-as-property` and `property_mode`. The dialog
lives on a lazily-loaded route, so the entry chunk alone gives a false negative.

- [ ] **Step 5: Visual check in the real app**

Open `https://clients.unclogme.app`, open New Client, and confirm: the checkbox renders above the
address block, is checked by default, and unchecking it reveals the note and no second address block.

- [ ] **Step 6: Release the claim**

Append the release to `WORKING-NOW.md` and commit.

---

## Task 10: The Calendar checkbox and its second address block

**Lovable project:** `6533c3ee-94f5-499c-96d1-c8847a729a8f` (Visit Calendar)

- [ ] **Step 1: Claim the project in `WORKING-NOW.md`, commit in the same breath**

- [ ] **Step 2: Send the prompt, on ONE line**

```
In the New Client dialog reached from the mobile create chooser, add a checkbox directly above the address fields, labelled "Use this address as the first property", checked by default, id "new-client-use-as-property". When it is CHECKED, behave exactly as today and send "property_mode":"client_address" in the create-client request body. When it is UNCHECKED, reveal a second address block headed "Property address" with its own Street, City and ZIP fields using the same Google Places autocomplete and the same validation as the client's address block, and send "property_mode":"separate" plus "property_street", "property_city" and "property_postal_code" from that second block. Change nothing else about the dialog or its existing fields.
```

- [ ] **Step 3: Confirm the send registered, then publish and verify the live bundle**

Same checks as Task 9 Step 3 and Step 4, against `https://calendar.unclogme.app/`.

- [ ] **Step 4: Verify at a 390px mobile viewport**

The dialog is reached from the mobile create chooser, so check it at phone width, not desktop.
Confirm the second block appears on uncheck and that both blocks validate independently.

Note: Places autocomplete on `calendar.unclogme.app` currently returns 403 because the referrer
allowlist entry needs to be `https://calendar.unclogme.app/*` rather than a bare host. Typing still
works. Do not treat the 403 as a defect introduced by this task; confirm it predates your change by
checking the same call on the existing address block.

- [ ] **Step 5: Release the claim in `WORKING-NOW.md`**

---

## Task 11: Phase 1 documentation

**Files:**
- Modify: `Building Apps/Client App/docs/08-changelog.md`
- Modify: `Building Apps/Visit Calendar/docs/08-changelog.md`
- Modify: `Building Apps/Client App/CLAUDE.md`
- Modify: `Building Apps/Visit Calendar/CLAUDE.md`

- [ ] **Step 1: Write the changelog entries**

Newest first, dated 2026-08-19. Each entry states what changed, quotes Fred's ask, names the exact
request field (`property_mode` and its three values), and records the rules that must not be
regressed:

- The checkbox is default CHECKED, and unchecking it means different things in the two apps by
  design: `none` in the Client App, `separate` in the Calendar.
- Every property created from an app now gets a Service Call job, created server-side by
  `ensureServiceCallJob`, so neither app should ever create one itself.
- The job title is exactly `Service Call`. A decorated title silently reclassifies the job in
  `ops.v_calendar_visit`.
- There is no `jobDelete` and no `jobArchive`. A mis-created job is permanent.

- [ ] **Step 2: Add the rule to both CLAUDE.md files**

Under the existing job rules, record the invariant and the trap: an SC job carries no line items at
all, fees included, because Jobber inherits a job's lines onto every visit it creates.

- [ ] **Step 3: Commit with the Building Apps convention**

One line, no co-author footer.

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Building Apps"
git pull --rebase origin main
git add "Client App/docs/08-changelog.md" "Client App/CLAUDE.md" "Visit Calendar/docs/08-changelog.md" "Visit Calendar/CLAUDE.md"
git commit -m "Document the first-property checkbox and the automatic Service Call job" "Client App/docs/08-changelog.md" "Client App/CLAUDE.md" "Visit Calendar/docs/08-changelog.md" "Visit Calendar/CLAUDE.md"
git push origin main
```

Stage explicit paths and commit WITH a pathspec. A bare `git commit` ships whatever the other session
has staged.

---

# PHASE 2

## Task 12: `save-client-property`, the first `propertyCreate` caller

**Files:**
- Create: `supabase/functions/save-client-property/index.ts`
- Modify: `supabase/config.toml`

- [ ] **Step 1: Introspect the mutation before writing against it**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Slack" && JT=$(./jobber-token.sh)
curl -s https://api.getjobber.com/api/graphql -H "Authorization: Bearer $JT" \
  -H "Content-Type: application/json" -H "X-JOBBER-GRAPHQL-VERSION: 2026-04-16" \
  -d '{"query":"{ __type(name:\"PropertyCreateInput\"){ inputFields { name type { name kind ofType { name } } } } }"}'
```

Expected: `PropertyCreateInput` exposes `properties: [PropertyAttributes]`. Confirm the nesting
before writing the payload. A flat address was rejected at GraphQL validation once already, and it
was free only because validation failures create nothing.

- [ ] **Step 2: Write the function**

Create `supabase/functions/save-client-property/index.ts`. Copy `getJobberToken`, the CORS echo
helper, and the guarded `gql` (with its content-type check) verbatim from
`supabase/functions/save-client-contact/index.ts`. Do not retype them: a retyped body silently drops
whatever you fail to reproduce.

The body, after those helpers:

```ts
  // ---- staff gate ----------------------------------------------------------
  const m = (req.headers.get("authorization") ?? "").match(/^Bearer (.+)$/);
  if (!m) return fail("forbidden", "Staff account required.");
  const { data: userData, error: userErr } = await db.auth.getUser(m[1]);
  const email = String(userData?.user?.email ?? "").toLowerCase();
  if (userErr || !userData?.user?.id ||
      (!email.endsWith("@ayache.com") && !email.endsWith("@unclogme.com"))) {
    return fail("forbidden", "Staff account required.");
  }

  const body = await req.json().catch(() => null);
  const clientId = Number(body?.client_id);
  const street = String(body?.street ?? "").trim();
  const city = String(body?.city ?? "").trim();
  const postalCode = String(body?.postal_code ?? "").trim();
  if (!clientId || !street || !city || !postalCode) {
    return fail("bad_request", "client_id, street, city and postal_code are all required.");
  }

  // ---- resolve the client's Jobber GID, FAIL CLOSED ------------------------
  const { data: link, error: linkErr } = await db
    .from("entity_source_links").select("source_id")
    .eq("entity_type", "client").eq("entity_id", clientId).eq("source_system", "jobber").maybeSingle();
  if (linkErr) return fail("lookup_failed", `Could not read the client's Jobber link: ${linkErr.message}`);
  if (!link?.source_id) return fail("not_in_jobber", "This client is not linked to Jobber, so a property cannot be created there.");

  const token = await getJobberToken();
  const created = await gql(token,
    `mutation($clientId: EncodedId!, $input: PropertyCreateInput!) {
       propertyCreate(clientId: $clientId, input: $input) {
         properties { id address { street1 city postalCode } }
         userErrors { message }
       }
     }`,
    { clientId: link.source_id,
      input: { properties: [{ address: { street1: street, city, postalCode, province: "FL", country: "USA" } }] } });

  if (!created.ok) return fail("jobber_unavailable", `Jobber did not answer: ${created.detail}`);
  const uerrs = created.data?.propertyCreate?.userErrors ?? [];
  if (uerrs.length) return fail("jobber_rejected", uerrs.map((e: any) => e.message).join("; "));

  // ---- verify BY VALUE, not by cardinality --------------------------------
  const node = (created.data?.propertyCreate?.properties ?? [])
    .find((p: any) => String(p?.address?.street1 ?? "").trim().toLowerCase() === street.toLowerCase());
  if (!node?.id) {
    return fail("verify_failed", "Jobber accepted the request but did not return the property we asked for. Check Jobber before retrying.");
  }
```

Then materialise it through our own handler and CHECK the result:

```ts
  // ---- materialise through handleProperty, the ONE writer -------------------
  // 🛑 CHECK THE RESULT. create-client discards its PROPERTY_CREATE replay result, which is why its
  //    property leg has no verification at all. That is precedent NOT to copy.
  const { data: secretRow } = await db.from("webhook_tokens").select("client_secret").eq("source_system", "jobber").single();
  if (!secretRow?.client_secret) {
    return fail("verify_failed", "Created in Jobber but the webhook secret is missing, so we could not import it.", { jobber_property_gid: node.id });
  }
  const payload = JSON.stringify({ topic: "PROPERTY_CREATE", webHookEvent: { itemId: node.id, occurredAt: new Date().toISOString() } });
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secretRow.client_secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sigBuf = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(payload));
  const sig = btoa(String.fromCharCode(...new Uint8Array(sigBuf)));
  const rp = await fetch(`${Deno.env.get("SUPABASE_URL")}/functions/v1/webhook-jobber`, {
    method: "POST", headers: { "Content-Type": "application/json", "x-jobber-hmac-sha256": sig }, body: payload });
  const rj = await rp.json().catch(() => ({}));
  const propertyId = Number(rj?.entity_id);
  if (!(propertyId > 0)) {
    // entity_id 0 means handleProperty deferred because the owning client is not canonical here.
    return fail("import_failed",
      "Created in Jobber but our importer did not record it. The property exists in Jobber and needs a look.",
      { jobber_property_gid: node.id, entity_id: rj?.entity_id });
  }

  const job = await ensureServiceCallJob({ db, authHeader: req.headers.get("authorization") ?? "", clientId, propertyId });
  return done({
    property_id: propertyId,
    jobber_property_gid: node.id,
    job: { step: job.ok ? (job.created ? "created" : "existing") : "failed", job_id: job.ok ? job.job_id : null, note: job.detail },
    schedulable: job.ok,
  });
```

- [ ] **Step 3: Register it in `config.toml`**

```toml
[functions.save-client-property]
verify_jwt = false
```

`false` matches its siblings: the staff gate inside the function is stricter than the gateway check,
which the public anon key also passes.

- [ ] **Step 4: Deploy**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
SUPABASE_ACCESS_TOKEN=<PAT> supabase functions deploy save-client-property --project-ref wbasvhvvismukaqdnouk
```

- [ ] **Step 5: Verify the gate before verifying the feature**

```bash
curl -s -o /dev/null -w "%{http_code}\n" -X POST "https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/save-client-property" -d '{}'
curl -s -X POST "https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/save-client-property" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <a NON-staff JWT>" -d '{}'
```

Expected: no-auth is refused, and a non-staff token returns `forbidden`. A feature test on an open
endpoint proves nothing about the gate.

- [ ] **Step 6: Create one real property on 112-YA**

This COMMITS: it creates a real Jobber property and a real, permanent Service Call job. Run it once.

```bash
curl -s -X POST "https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/save-client-property" \
  -H "Content-Type: application/json" -H "Authorization: Bearer <a real staff JWT>" \
  -d '{"client_id":<112-YA client id>,"street":"9401 Collins Avenue Unit 2","city":"Surfside","postal_code":"33154"}'
```

Then assert on the DB, not the response:

```sql
select p.id, p.address, p.is_billing,
       (select e.source_id from entity_source_links e where e.entity_type='property'
         and e.entity_id=p.id and e.source_system='jobber') as link,
       (select count(*) from jobs j where j.property_id=p.id
         and lower(btrim(j.title))='service call'
         and j.job_status not in ('archived','closed','destroyed')) as sc_jobs
  from properties p
 where p.client_id = <112-YA client id> and p.address like '9401 Collins Avenue Unit 2%';
```

Expected: one row, `is_billing = false`, a real base64 `link` that does NOT end in `_billing`, and
`sc_jobs = 1`.

- [ ] **Step 7: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
git add supabase/functions/save-client-property/index.ts supabase/config.toml
git commit -m "Add save-client-property, the first propertyCreate caller in this repo

Creates the property in Jobber, verifies by value, materialises it through
handleProperty and CHECKS the returned entity_id (create-client discards that
result, which is why its property leg has no verification), then creates the
Service Call job through the shared helper.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 13: Repoint the Clients App Add Property button

**Lovable project:** `dbf2133c-539c-48ff-864a-68eb284a569d`

- [ ] **Step 1: Claim the project in `WORKING-NOW.md`, commit in the same breath**

- [ ] **Step 2: Send the prompt, on ONE line**

```
Change the Add Property dialog so that instead of calling the client.create_property RPC it POSTs to the save-client-property edge function with a JSON body of {client_id, street, city, postal_code} and the user's Authorization bearer token, exactly like the existing save-client-contact call does. On success it returns {property_id, job, schedulable}: keep the current success behaviour and additionally show a muted line reading "Service Call job created." when job.step is "created". On failure show the returned message verbatim. Change nothing else about the dialog or its fields.
```

- [ ] **Step 3: Publish and verify the live bundle**

Grep the walked chunks for `save-client-property`. It must be present, and `create_property` must be
absent from the Add Property path.

- [ ] **Step 4: Exercise it once from the real UI**

Add a property to 112-YA through the app. This COMMITS a Jobber property and a permanent job. Confirm
the muted "Service Call job created." line appears, then verify in the DB exactly as in Task 12
Step 6.

- [ ] **Step 5: Release the claim in `WORKING-NOW.md`**

---

## Task 14: Close the DB-only property path

Do this ONLY after Task 13 is verified live. This is a tightening, so the UI ships first: a server
that refuses more than the UI sends breaks every save from the current bundle.

**Files:**
- Create: `docs/migrations/2026-08-19_2200_create_property_refuse.sql`

- [ ] **Step 1: Confirm nothing still calls the RPC**

```sql
select app_source, count(*), max(changed_at)
  from audit.logs
 where table_name = 'properties' and operation = 'INSERT'
   and changed_at > now() - interval '2 days'
 group by 1 order by 3 desc;
```

Expected: no new `client-app` INSERTs since Task 13 shipped. If any appear, the old bundle is still
being served somewhere. Stop and find out where before continuing.

- [ ] **Step 2: Write the migration**

```sql
-- 2026-08-19_2200_create_property_refuse.sql
--
-- WHAT: client.create_property now refuses, directing callers to save-client-property.
--
-- WHY:  a property created only in our DB can never carry a Jobber job, and every property is now
--       required to have a Service Call job. The DB-only path was an accepted trade-off during the
--       Jobber bridge (2026-07-30_0709), which Fred reversed on 2026-08-19.
--
-- ⚠ SAFE TO DO: measured before writing this, client.create_property has been invoked in production
--   exactly ONCE in its lifetime, a smoke test on 2026-07-31 whose row was deleted 79 seconds later.
--   Task 13 repointed the only caller.
--
-- AUDIT (rule 8): no table changed. Function body only.

begin;

create or replace function client.create_property(p_client_id bigint, p_address text, p_city text, p_zip text)
returns jsonb
language plpgsql
security definer
set search_path = client, public
as $$
begin
  raise exception using
    errcode = '22023',
    message = 'Properties must be created through the save-client-property edge function so they exist in Jobber and can carry a Service Call job.',
    hint    = 'POST to /functions/v1/save-client-property with {client_id, street, city, postal_code}.';
end $$;

-- ---- VERIFY ------------------------------------------------------------------------------------
do $$
declare v_raised boolean := false;
begin
  begin
    perform client.create_property(1, 'x', 'y', 'z');
  exception when others then
    v_raised := true;
  end;
  if not v_raised then raise exception 'VERIFY: create_property did not refuse'; end if;
  raise notice 'VERIFY ok: client.create_property now refuses';
end $$;

commit;
```

⚠ Before applying, read the live signature and copy it exactly:

```sql
select pg_get_functiondef(oid) from pg_proc p
 join pg_namespace n on n.oid = p.pronamespace
 where n.nspname='client' and p.proname='create_property';
```

`CREATE OR REPLACE FUNCTION` cannot change an argument name while callers depend on it, and a
mismatched signature creates a SECOND overload rather than replacing the first, leaving the original
reachable. If the signature differs from the one above, use the real one.

- [ ] **Step 3: Apply and confirm the app still works**

Add a property through the Clients App again. It must still succeed, because it now goes through the
edge function. If it fails, the UI is still on the old path: roll this migration back immediately by
restoring the previous function body from `2026-07-30_0709_client_create_property_rpc.sql`.

- [ ] **Step 4: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
git add docs/migrations/2026-08-19_2200_create_property_refuse.sql
git commit -m "Close the DB-only property path

client.create_property now refuses and points callers at save-client-property,
because a property created only in our DB can never carry a Jobber job and
every property now needs a Service Call. Reverses the 2026-07-30 bridge
trade-off, per Fred 2026-08-19.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main
```

---

## Task 15: Phase 2 documentation and the workflow-doc correction

**Files:**
- Modify: `Building Apps/Client App/docs/08-changelog.md`
- Modify: `Building Apps/Client App/CLAUDE.md`
- Modify: `docs/jobber-calendar-job-migration/jobs-visits-calendar-workflow.md`

- [ ] **Step 1: Document Phase 2 in the app folder**

Record that Add Property now goes through `save-client-property`, that `client.create_property`
refuses, and the rule that must not be regressed: a property must exist in Jobber before it can
carry a job, so no app may create one DB-only.

- [ ] **Step 2: Correct the workflow doc's coverage claim**

It currently claims every active or recurring client has a Service Call ("0 missing"). Replace that
with the audited figures, using Fred's denominator (clients with at least one completed visit in the
last 6 months, measured 2026-08-19): 234 clients, 915 visits, 0 INACTIVE, 3 with no client code, and
12 without a strict Service Call job, of which 8 hold an active Service Agreement and 3 more carry
SC-class jobs titled `Service` or `Emergency call`.

Add the finding that is genuinely open, and mark it as an ops question rather than a scheduling-rule
one: **three clients we visited have no active job at all** (235-LOU with 5 visits, 107-PV with 2,
ABA Plumbing with 1). Do not fix them here. Fred ruled no backfill.

- [ ] **Step 3: Commit both repos separately, with their own conventions**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase"
git add docs/jobber-calendar-job-migration/jobs-visits-calendar-workflow.md
git commit -m "Correct the Service Call coverage claim with an audited figure

The doc claimed 0 clients missing a Service Call. Audited against clients with
at least one completed visit in the last 6 months: 12 of 234 lack a strict SC
job, 8 of which hold an active Service Agreement. Records the three visited
clients with no active job at all as an open ops question.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
git push origin main

cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Building Apps"
git pull --rebase origin main
git add "Client App/docs/08-changelog.md" "Client App/CLAUDE.md"
git commit -m "Document save-client-property and the closed DB-only property path" "Client App/docs/08-changelog.md" "Client App/CLAUDE.md"
git push origin main
```

---

## Done when

- [ ] A new client created from either app has a property and a Service Call job, verified in the DB and visible in `ops.client_service_options`.
- [ ] Unchecking the box in the Clients App creates no property and returns `schedulable: false`.
- [ ] Unchecking the box in the Calendar creates a property at the second address.
- [ ] Adding a property from the Clients App creates it in Jobber and gives it a Service Call job.
- [ ] `client.create_property` refuses.
- [ ] A job-step orphan appears in `v_client_create_attention` with its own sentence.
- [ ] Both app changelogs and both CLAUDE.md files are updated, and the workflow doc's coverage claim is corrected.
