# Generated-sheet finisher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A generated DERM address sheet (sheet number 1000 and up, printed by our pdf-service) measures its own pages from the scan, guided by the layout we printed, and marks itself complete, so the blackout follows with no clicks; anything it cannot do with certainty it leaves for a person with a plain sentence saying why. Spec: `docs/superpowers/specs/2026-09-14-generated-sheet-auto-measure-and-complete-design.md` (Fred's answers in its section 8: auto-complete from day one, one machine label `stamp-studio-ai`, tolerances accepted pending Phase 0, Step A pending).

**Architecture:** Three layers, all in this repo. (1) A **pure matcher** in SQL (`derm.fn_match_generated_page`) that takes the detector's raw lines plus the page's stamps and either returns the six printed boundaries or a plain-language refusal; it reads no table, so it is exercised offline over the whole corpus before anything writes (Phase 0). (2) A thin **edge function** `measure-generated-page` that fetches one scan, runs the run-length detector (one shared module, also used by the Node probe) and hands the raw lines to (3) the **writer RPC** `derm.fn_generated_page_measured`, which gathers the cards, calls the matcher and writes ONLY through the two existing guarded RPCs (`derm.record_page_rules` as source `template-v1-<date>`, then `derm.save_page_geometry`), both inside one subtransaction so a refusal writes nothing, then calls `derm.fn_complete_generated_sheet`. A pg_cron job every 10 minutes completes what can be completed (no HTTP) and requests at most two page measurements, budgeted three attempts per image by a ledger. Precedence of rule sources becomes `human-v1 > template-v1 > runlen-v2` in the one selection view and its one duplicate.

**Tech Stack:** PostgreSQL 15 on Supabase Prod `wbasvhvvismukaqdnouk` (PL/pgSQL, SECURITY DEFINER RPCs, pg_cron 1.6, pg_net 0.20), Supabase Edge Functions (Deno, `npm:jpeg-js@0.4.4`), Node 20 probes over the Management API, Python 3 for anchored splices of live function/view bodies.

**How tasks are applied and tested.** Every migration is a dated file in `docs/migrations/` (ADR 010 header, `BEGIN; ... COMMIT;` with `COMMIT;` the LAST statement so `node scripts/probes/apply_sql_file.mjs <file> rehearse` can swap it for `ROLLBACK`). Rehearse first, read the NOTICEs by making the VERIFY block RAISE EXCEPTION with the observations if you need them (NOTICEs are swallowed by the API), then apply for real with `node scripts/probes/apply_sql_file.mjs <file>`. Read-only checks go through `node scripts/q.js <file.sql> <out.json>`. Edge functions deploy with `supabase functions deploy <slug> --project-ref wbasvhvvismukaqdnouk` (the CLI is on PATH; it reads the login from the keyring, never put the PAT on a command line) and are verified against the DEPLOYED body with `node scripts/probes/edge_deployed_body.js <slug> "<needle>" "!<absent>"`, always with a control needle. Never print or commit `.env` values. Commits in this repo end with `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`; stage explicit paths, never `git add -A` (the checkout is shared with a second session). Never use the em-dash character anywhere.

**Standing rules that bind every task below** (from `CLAUDE.md`, re-read them before touching the object):
- `CREATE OR REPLACE` takes the WHOLE body: copy `pg_get_functiondef` / `pg_get_viewdef` output and patch it by an anchor asserted to occur exactly once. Never retype a body.
- PL/pgSQL is not parsed at creation: every new function is CALLED in the migration's VERIFY.
- An extent opens the publish gate onto whatever bands exist; bands and extent are written together, in one `save_page_geometry` call, or not at all.
- Every message a person can read is plain language with no technical word; the code goes to DETAIL or to a `detail` field.
- Everything machine-made is labelled `stamp-studio-ai`.
- `apply_sql_file.mjs rehearse` refuses a file with anything after `COMMIT;`.

---

## File / object map

**Shared detector (Task 1)**
- Create: `supabase/functions/_shared/printed_rule_detector.mjs` (the run-length detector as one ESM module; input a decoded RGBA image, output `{W, H, skew, rules[]}`).
- Create: `scripts/probes/rev/detect_node.mjs` (Node front-end, replaces `detect_node.js`).
- Create: `scripts/probes/generated_finisher/detect_core_test.mjs` + `detect_core_expected.json` (frozen output of the pre-extraction script on a known scan; the regression control).
- Delete: `scripts/probes/rev/detect_node.js` (after the test passes).

**Matcher, read-only (Task 2)**: `docs/migrations/2026-09-15_1000_generated_page_matcher.sql`
- `derm.fn_generated_template_boundaries() RETURNS numeric[]` (the stamp-midpoint template, derived from `fn_generated_row_geometry`, the Phase 0 first-pass prior).
- `derm.fn_match_generated_page(p_lines jsonb, p_stamps jsonb, p_prior numeric[], p_search, p_match, p_gap, p_clear, p_min_run) RETURNS jsonb` (IMMUTABLE, no table reads).
- `derm.fn_generated_page_cards(p_dump_folder text, p_page int) RETURNS jsonb` (STABLE: the page's stamped cards with their printed row, or the plain refusal).

**Phase 0 (Task 3)**: `scripts/probes/generated_finisher/phase0_corpus.mjs`, `phase0_results.json`, `phase0_report.md`, `.gitignore` (`img/`).

**Precedence (Task 4)**: `docs/migrations/2026-09-15_1100_template_rules_precedence.sql` generated by `scripts/probes/generated_finisher/gen_precedence_migration.py`
- `derm._rule_source_rank(text) RETURNS int`, `derm._is_rule_source(text)` widened, `derm.v_page_printed_rules` and `derm.v_band_edge_check` re-ordered, `derm.record_page_rules` refusal text widened.

**Finisher core (Task 5)**: `docs/migrations/2026-09-15_1200_generated_sheet_finisher.sql`
- `derm.fn_generated_page_prior() RETURNS numeric[]` (calibrated in Phase 0).
- `derm.generated_measure_attempts` (ledger; rule 8 opt-out), `derm._gm_record(...)`.
- `derm._actor(text)` and `derm._require_stamp_key()` gain a service_role arm.
- `derm.fn_generated_completion_blocker(text) RETURNS text`, `derm.fn_complete_generated_sheet(text) RETURNS jsonb`.
- `derm.fn_generated_page_measured(text, int, text, jsonb, jsonb) RETURNS jsonb` (the writer).
- `derm.v_generated_measure_backlog`, `derm.fn_generated_measure_targets(int)`, `derm.v_generated_complete_backlog`.
- `derm.fn_sheet_publishable_detail(text)` carries the finisher's reason in its `message`.
- `public.app_config` row `generated_sheet_auto_complete = 'true'`.

**Edge function (Task 6)**: `supabase/functions/measure-generated-page/index.ts`, `supabase/config.toml` entry.

**Cron (Task 7)**: `docs/migrations/2026-09-15_1300_generated_sheet_finisher_cron.sql`: `public.fn_request_generated_measure()`, job `generated-sheet-finisher` at `6-59/10 * * * *`.

**Docs (Task 8)**: `CLAUDE.md` (Supabase), `Building Apps/DERM Stamp Studio/docs/08-changelog.md`, `Building Apps/DERM Stamp Studio/CLAUDE.md`, the spec (one sentence on the calibrated prior), `WORKING-NOW.md`.

**Out of this plan**: Step A (re-placing cards left unplaced by a late sheet-number read). Fred has not answered; it gets its own plan once he does.

---

### Task 0: Claim the work

**Files:**
- Modify: `C:\Users\FRED\Desktop\Virtrify\Yannick\Claude\WORKING-NOW.md` (append only, then commit in the root repo)

- [ ] **Step 1: Append the claim** (append, never a truncating write; the file is under a local-only git repo at the workspace root)

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude" && printf '%s\n' "" "## $(date +%Y-%m-%d) Supabase session: generated-sheet finisher (plan docs/superpowers/plans/2026-09-14-generated-sheet-finisher.md)" "- DB objects: derm.fn_match_generated_page, derm.fn_generated_page_cards, derm.fn_generated_template_boundaries, derm.fn_generated_page_prior, derm.generated_measure_attempts, derm._gm_record, derm.fn_complete_generated_sheet, derm.fn_generated_completion_blocker, derm.fn_generated_page_measured, derm.v_generated_measure_backlog, derm.v_generated_complete_backlog, derm.fn_generated_measure_targets, derm._is_rule_source, derm._rule_source_rank, derm.v_page_printed_rules, derm.v_band_edge_check, derm.record_page_rules (message text only), derm._actor, derm._require_stamp_key, derm.fn_sheet_publishable_detail, public.fn_request_generated_measure, cron job generated-sheet-finisher, app_config key generated_sheet_auto_complete" "- Edge fn: measure-generated-page (new). Files: supabase/functions/_shared/printed_rule_detector.mjs, scripts/probes/rev/detect_node.mjs, scripts/probes/generated_finisher/*" "- Lovable: none. Cleared when: the finisher cron is live and the docs are committed." >> WORKING-NOW.md && git add WORKING-NOW.md && git commit -q -m "Claim: generated-sheet finisher" && git log -1 --format='%h %s'
```

Expected: one new commit hash printed; `git log --numstat -1 -- WORKING-NOW.md` shows insertions only.

---

### Task 1: One detector module shared by the Node probe and the edge function

The run-length detector exists twice today: the browser version (`Building Apps/DERM Stamp Studio/docs/printed-rule-detector.reference.js`, what the Studio runs) and the Node port `scripts/probes/rev/detect_node.js` (what measured 835076). The edge function needs it in Deno. A third copy would be the one nobody re-tests, so the Node port becomes ONE ESM module that both Node and Deno import, and a frozen expected output is the regression control.

**Files:**
- Create: `supabase/functions/_shared/printed_rule_detector.mjs`
- Create: `scripts/probes/rev/detect_node.mjs`
- Create: `scripts/probes/generated_finisher/.gitignore`
- Create: `scripts/probes/generated_finisher/detect_core_test.mjs`
- Create: `scripts/probes/generated_finisher/detect_core_expected.json` (generated by step 2)
- Delete: `scripts/probes/rev/detect_node.js` (step 6)

- [ ] **Step 1: Create the probe folder and fetch the control scan**

The control is page 1 of ticket-835076 (`manifests/derm/1929/address_1.jpg`, 1492x1156, a public-bucket scan whose Node output is known: boundaries 26.125 / 34.343 / 41.047 / 48.227 / 56.012 / 63.754). Scans are client documents: the folder's `.gitignore` keeps them out of the repo.

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && mkdir -p scripts/probes/generated_finisher/img && printf '%s\n' "img/" "*.out.json" > scripts/probes/generated_finisher/.gitignore && node -e "
const fs=require('fs');
fetch('https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1929/address_1.jpg')
  .then(r=>{ if(!r.ok) throw new Error('HTTP '+r.status); return r.arrayBuffer(); })
  .then(b=>{ fs.writeFileSync('scripts/probes/generated_finisher/img/835076_1.jpg', Buffer.from(b)); console.log('bytes', b.byteLength); });
"
```

Expected: `bytes 341889`.

- [ ] **Step 2: Freeze the pre-extraction output as the expected file** (run the OLD script; this is the control that must not change)

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node -e "
const { execFileSync } = require('child_process');
const out = execFileSync('node', ['scripts/probes/rev/detect_node.js', 'scripts/probes/generated_finisher/img/835076_1.jpg'], { encoding: 'utf8' });
const lines = out.split(/\r?\n/);
const head = lines[0].match(/(\d+)x(\d+)\s+skew\s+(-?[\d.]+)/);
const rules = lines.slice(1).filter(l => /run/.test(l)).map(l => { const m = l.trim().match(/^([\d.]+)\s+run\s+([\d.]+)\s+(\w+)/); return { pct: +m[1], run: +m[2], kind: m[3] }; });
const expected = { image: 'img/835076_1.jpg', W: +head[1], H: +head[2], skew: +head[3], rules };
require('fs').writeFileSync('scripts/probes/generated_finisher/detect_core_expected.json', JSON.stringify(expected, null, 2) + '\n');
console.log(expected.W + 'x' + expected.H, 'rules', rules.length, 'boundaries', rules.filter(r => r.kind === 'boundary').map(r => r.pct).join(' '));
"
```

Expected: `1492x1156 rules 15 boundaries 14.317 26.125 34.343 41.047 48.227 56.012 63.754 66.912`.

- [ ] **Step 3: Write the shared module** (the body is the `detect` function of `scripts/probes/rev/detect_node.js` lines 20 to 91 with ONLY the first line changed: the decoded image comes in as a parameter. Copy those lines from the file; do not retype them. The text below is that copy.)

`supabase/functions/_shared/printed_rule_detector.mjs`:

```js
// printed_rule_detector.mjs: the run-length printed-rule detector as ONE module, imported by the
// Node probe (scripts/probes/rev/detect_node.mjs) and by the edge function measure-generated-page.
//
// Transcribed 2026-09-15 from scripts/probes/rev/detect_node.js (itself a port of
// scripts/probes/derm_band_review/detect-run.js, the detector this estate validated against known
// truth; four earlier scorers were tried and rejected, see that folder's README). The only change
// is the input: a decoded image {width, height, data} instead of a file path, so the same bytes run
// in Deno and in Node. scripts/probes/generated_finisher/detect_core_test.mjs asserts the output is
// identical to the pre-extraction script's frozen output on a known scan.
//
// Input:  raw = {width, height, data: Uint8Array RGBA}, what jpeg-js decode(bytes, {useTArray:true})
//         returns. topPct / botPct (optional) bound the roster search, default 18 / 72.
// Output: {W, H, skew, rules: [{pct, run, kind}]} sorted by pct. `kind` is the detector's own
//         long/short label (run >= 0.80 = boundary) and is NOT a classification: the generated-sheet
//         matcher ignores it, and the Studio's classifier re-derives it from alternation.

const FULL_RUN = 0.80;
const MIN_RUN = 0.33;
const MIN_SEP_PP = 0.70;
const SLOPES = [-8, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 8].map((v) => v / 1000);

export function detectRules(raw, topPct = null, botPct = null) {
  const W = raw.width, H = raw.height, d = raw.data;
  const L = new Uint8Array(W * H);
  for (let i = 0, p = 0; p < W * H; p++, i += 4) {
    L[p] = (0.299 * d[i] + 0.587 * d[i + 1] + 0.114 * d[i + 2]) | 0;
  }

  const yA = Math.max(2, Math.round(((topPct != null ? topPct : 18) - 5) / 100 * H));
  const yB = Math.min(H - 3, Math.round(((botPct != null ? botPct : 72) + 5) / 100 * H));
  const x0 = Math.floor(W * 0.02), x1 = Math.floor(W * 0.92), span = x1 - x0;
  const xMid = (x0 + x1) / 2;

  // per-column paper level: 70th percentile down the roster, so a column carrying a vertical
  // table line still resolves to paper rather than to the line
  const cut = new Float32Array(W);
  for (let x = x0; x < x1; x++) {
    const col = [];
    for (let y = yA; y <= yB; y += 2) col.push(L[y * W + x]);
    col.sort((a, b) => a - b);
    const p = col[(col.length * 0.7) | 0];
    cut[x] = p - Math.max(9, p * 0.1);
  }

  const profileFor = (slope) => {
    const rf = new Float32Array(H);
    for (let y = yA - 12; y <= yB + 12; y++) {
      if (y < 1 || y >= H - 1) continue;
      let best = 0, cur = 0;
      for (let x = x0; x < x1; x++) {
        const yy = y + ((slope * (x - xMid)) | 0);
        if (yy < 1 || yy >= H - 1) { cur = 0; continue; }
        const t = cut[x];
        const dark = L[yy * W + x] < t || L[(yy - 1) * W + x] < t || L[(yy + 1) * W + x] < t;
        if (dark) { cur++; if (cur > best) best = cur; } else cur = 0;
      }
      rf[y] = best / span;
    }
    return rf;
  };

  let bestSlope = 0, bestScore = -1;
  for (const s of SLOPES) {
    const rf = profileFor(s);
    let n = 0;
    for (let y = yA - 12; y <= yB + 12; y++) if (rf[y] >= FULL_RUN) n++;
    if (n > bestScore || (n === bestScore && Math.abs(s) < Math.abs(bestSlope))) {
      bestScore = n; bestSlope = s;
    }
  }
  const rf = profileFor(bestSlope);

  const sep = Math.max(3, Math.round(H * MIN_SEP_PP / 100));
  const cand = [];
  for (let y = yA - 12; y <= yB + 12; y++) if (rf[y] >= MIN_RUN) cand.push(y);
  cand.sort((a, b) => rf[b] - rf[a]);
  const taken = [];
  for (const y of cand) {
    if (taken.some((t) => Math.abs(t - y) < sep)) continue;
    taken.push(y);
  }

  const lim = Math.max(2, Math.round(H * MIN_SEP_PP / 200));
  const rules = taken.map((y) => {
    const v = rf[y];
    let a = y, b = y;
    while (a > 1 && y - a < lim && rf[a - 1] >= v - 0.03) a--;
    while (b < H - 2 && b - y < lim && rf[b + 1] >= v - 0.03) b++;
    const mid = (a + b) / 2;
    return { pct: +(mid / H * 100).toFixed(3), run: +v.toFixed(3), kind: v >= FULL_RUN ? 'boundary' : 'divider' };
  }).sort((p, q) => p.pct - q.pct);

  return { W, H, skew: bestSlope, rules };
}
```

- [ ] **Step 4: Write the Node front-end**

`scripts/probes/rev/detect_node.mjs`:

```js
// Node front-end for the shared run-length detector (supabase/functions/_shared/printed_rule_detector.mjs).
// USE: node scripts/probes/rev/detect_node.mjs <jpeg-path> [topPct] [botPct]
// ALWAYS run it against a page whose truth you already know before believing it on a page you do
// not: a detector with no positive control is an untested instrument.
import fs from 'node:fs';
import nodePath from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { detectRules } from '../../../supabase/functions/_shared/printed_rule_detector.mjs';

const require = createRequire(import.meta.url);
const jpeg = require('jpeg-js');

export function detectFile(path, topPct = null, botPct = null) {
  const raw = jpeg.decode(fs.readFileSync(path), { useTArray: true });
  return detectRules(raw, topPct, botPct);
}

// run the CLI only when this file is the entry point (it is also imported by the Phase 0 script)
if (process.argv[1] && nodePath.resolve(process.argv[1]).toLowerCase() === fileURLToPath(import.meta.url).toLowerCase()) {
  const [, , path, top, bot] = process.argv;
  if (!path) { console.error('usage: node detect_node.mjs <jpeg-path> [topPct] [botPct]'); process.exit(2); }
  const r = detectFile(path, top ? +top : null, bot ? +bot : null);
  console.log(`${path}  ${r.W}x${r.H}  skew ${r.skew}`);
  for (const x of r.rules) console.log(`  ${String(x.pct).padStart(7)}  run ${x.run.toFixed(3)}  ${x.kind}`);
}
```

- [ ] **Step 5: Write the equivalence test and run it**

`scripts/probes/generated_finisher/detect_core_test.mjs`:

```js
// Asserts the shared detector module reproduces, byte for byte, the output the pre-extraction
// script (scripts/probes/rev/detect_node.js, now deleted) produced on a known scan. The expected
// file was frozen from that script BEFORE the extraction; regenerating it from the new module
// would make this test compare the module with itself.
// USE: node scripts/probes/generated_finisher/detect_core_test.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { detectFile } from '../rev/detect_node.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const expected = JSON.parse(fs.readFileSync(path.join(here, 'detect_core_expected.json'), 'utf8'));
const img = path.join(here, expected.image);
if (!fs.existsSync(img)) { console.error(`control scan missing: ${img} (Task 1 step 1 fetches it)`); process.exit(2); }

const got = detectFile(img);
const problems = [];
if (got.W !== expected.W || got.H !== expected.H) problems.push(`size ${got.W}x${got.H} vs ${expected.W}x${expected.H}`);
if (got.skew !== expected.skew) problems.push(`skew ${got.skew} vs ${expected.skew}`);
if (got.rules.length !== expected.rules.length) problems.push(`rule count ${got.rules.length} vs ${expected.rules.length}`);
for (let i = 0; i < Math.min(got.rules.length, expected.rules.length); i++) {
  const a = got.rules[i], b = expected.rules[i];
  if (a.pct !== b.pct || a.run !== b.run || a.kind !== b.kind) problems.push(`rule ${i}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`);
}
// the control must be a page with the known generated-sheet shape, or a passing test proves little
const bounds = got.rules.filter(r => r.kind === 'boundary').map(r => r.pct);
if (!bounds.includes(26.125) || !bounds.includes(63.754)) problems.push(`control page lost its known boundaries: ${bounds.join(' ')}`);
if (problems.length) { console.error('DETECTOR DRIFT:\n  ' + problems.join('\n  ')); process.exit(1); }
console.log(`OK: ${got.rules.length} rules identical to the frozen output (${expected.W}x${expected.H}, skew ${got.skew})`);
```

Run:

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/generated_finisher/detect_core_test.mjs
```

Expected: `OK: 15 rules identical to the frozen output (1492x1156, skew 0)`.

- [ ] **Step 6: Delete the old script, run the test again, commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && git rm -q scripts/probes/rev/detect_node.js && node scripts/probes/generated_finisher/detect_core_test.mjs && git pull -q --rebase origin main && git add supabase/functions/_shared/printed_rule_detector.mjs scripts/probes/rev/detect_node.mjs scripts/probes/generated_finisher/.gitignore scripts/probes/generated_finisher/detect_core_test.mjs scripts/probes/generated_finisher/detect_core_expected.json && git commit -q -m "Share the run-length detector between the Node probe and the edge runtime" -m "One ESM module under supabase/functions/_shared, imported by scripts/probes/rev/detect_node.mjs and, next, by the generated-sheet finisher edge function. The output on ticket-835076 page 1 is frozen in detect_core_expected.json from the pre-extraction script and asserted identical." -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" && git push -q origin main && git log -1 --format='%h %s'
```

Expected: the test prints OK after the deletion (the test imports the new module only), one commit pushed.

---
### Task 2: The matcher and the page-card reader, read-only (migration A)

Nothing in this migration writes a business table. It exists first so Phase 0 can replay the real
algorithm over the corpus through the Management API.

**Files:**
- Create: `docs/migrations/2026-09-15_1000_generated_page_matcher.sql`

- [ ] **Step 1: Write the migration**

```sql
-- ============================================================================================
-- 2026-09-15_1000_generated_page_matcher.sql
--
-- The layout-guided matcher for GENERATED DERM address sheets, as read-only functions, so it can be
-- replayed over every accepted page (Phase 0 of the finisher plan) before anything writes.
--
-- Design: docs/superpowers/specs/2026-09-14-generated-sheet-auto-measure-and-complete-design.md
-- Plan:   docs/superpowers/plans/2026-09-14-generated-sheet-finisher.md (Task 2)
--
-- WHY. A generated sheet (number 1000+) is printed by our own pdf-service on the fixed DERM_V4.00
-- form: five Section B slots on every page, six printed boundaries, at positions that differ between
-- photographs by a uniform shift of 0.3 to 2pp. The Studio's blind classifier failed 835076 page 2
-- because one boundary is printed half-width in that scan. A page we printed needs no classifier:
-- the layout is a PRIOR, the scan is the MEASUREMENT.
--
-- THREE FUNCTIONS, NONE OF WHICH WRITES:
--   derm.fn_generated_template_boundaries()  the stamp-midpoint template, derived from
--                                            fn_generated_row_geometry (never typed); the first-pass
--                                            prior for Phase 0, superseded by fn_generated_page_prior
--   derm.fn_match_generated_page(...)        IMMUTABLE: raw lines + stamps + prior -> six boundaries
--                                            or a plain-language refusal
--   derm.fn_generated_page_cards(folder, pg) STABLE: the stamped cards of one image position with
--                                            their PRINTED row, or the plain-language refusal
--
-- EVERY REFUSAL IS A SENTENCE A PERSON CAN ACT ON (CLAUDE.md, Fred 2026-09-14); the technical
-- particulars ride in `detail`, which no app displays.
--
-- RULE 8: no table changes. Grants: service_role only (Phase 0 runs as postgres over the
-- Management API; the Studio never calls these).
-- ============================================================================================
BEGIN;

-- --------------------------------------------------------------------------------------------
-- PART 1. The template: six boundaries implied by the five stamp positions we print at.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_generated_template_boundaries()
RETURNS numeric[]
LANGUAGE sql IMMUTABLE
SET search_path TO 'derm', 'public'
AS $function$
  -- The midpoint between neighbouring stamps, and the same half-gap beyond the first and the last.
  -- This is exactly what derm.v_stamp_row_bands derives for a fully stamped generated page
  -- (25.84 / 33.76 / 41.10 / 48.145 / 55.925 / 64.155). It is a PRIOR and is never written anywhere;
  -- the printed lines on a real scan sit 0.0 to 0.75pp from it (measured on 835076, both pages).
  SELECT ARRAY[
           s[1] - (s[2] - s[1]) / 2,
           (s[1] + s[2]) / 2, (s[2] + s[3]) / 2, (s[3] + s[4]) / 2, (s[4] + s[5]) / 2,
           s[5] + (s[5] - s[4]) / 2 ]
    FROM (SELECT ARRAY(SELECT g.o_y_pct
                         FROM generate_series(1, 5) i
                        CROSS JOIN LATERAL derm.fn_generated_row_geometry(i) g
                        ORDER BY i) AS s) t;
$function$;

-- --------------------------------------------------------------------------------------------
-- PART 2. The matcher. Pure: reads no table, so the same function serves Phase 0 and the writer.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_match_generated_page(
  p_lines   jsonb,               -- [{pct, run, ...}] the detector's raw lines; kind is ignored
  p_stamps  jsonb,               -- [{row, y}] one entry per stamped card, row = printed row 1..5
  p_prior   numeric[],           -- the six expected boundaries
  p_search  numeric DEFAULT 2.5, -- window around each prior boundary when finding the page shift
  p_match   numeric DEFAULT 0.75,-- window around prior + shift when matching a boundary
  p_gap     numeric DEFAULT 0.75,-- tolerance on each slot gap against the printed gap
  p_clear   numeric DEFAULT 0.5, -- a stamp must sit this far inside both lines of its slot
  p_min_run numeric DEFAULT 0.35)-- a line shorter than this fraction of the form width is noise
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE
AS $function$
DECLARE
  v_pct   numeric[];  v_run numeric[];  v_n int;
  v_off   numeric[] := '{}';
  v_shift numeric;
  v_found numeric[] := '{}';  v_runs numeric[] := '{}';  v_res numeric[] := '{}';
  v_best  numeric;  v_bestd numeric;  v_bestj int;
  v_row   int;  v_y numeric;
  i int;  j int;
BEGIN
  IF p_prior IS NULL OR array_length(p_prior, 1) <> 6 THEN
    RETURN jsonb_build_object('ok', false,
      'reason', 'The printed layout for this sheet is not available, so it cannot be measured automatically.',
      'detail', 'prior must hold exactly 6 boundaries');
  END IF;

  -- 1. the usable lines: any width at or above p_min_run, in page order
  SELECT array_agg(x.pct ORDER BY x.pct), array_agg(x.run ORDER BY x.pct)
    INTO v_pct, v_run
    FROM (SELECT (e->>'pct')::numeric AS pct, (e->>'run')::numeric AS run
            FROM jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e) x
   WHERE x.pct IS NOT NULL AND x.run IS NOT NULL AND x.run >= p_min_run;
  v_n := coalesce(array_length(v_pct, 1), 0);
  IF v_n < 5 THEN
    RETURN jsonb_build_object('ok', false,
      'reason', 'The printed rows could not be found on this scan.',
      'detail', format('%s usable lines (run >= %s), need at least 5', v_n, p_min_run));
  END IF;

  -- 2. the page's uniform shift: for each prior boundary the nearest line within p_search; the
  --    shift is the MEDIAN offset so one wrong candidate cannot drag it. At least 5 of 6 must exist.
  FOR i IN 1 .. 6 LOOP
    v_best := NULL; v_bestd := NULL;
    FOR j IN 1 .. v_n LOOP
      IF abs(v_pct[j] - p_prior[i]) <= p_search
         AND (v_bestd IS NULL OR abs(v_pct[j] - p_prior[i]) < v_bestd) THEN
        v_best := v_pct[j]; v_bestd := abs(v_pct[j] - p_prior[i]);
      END IF;
    END LOOP;
    IF v_best IS NOT NULL THEN v_off := v_off || (v_best - p_prior[i]); END IF;
  END LOOP;
  IF coalesce(array_length(v_off, 1), 0) < 5 THEN
    RETURN jsonb_build_object('ok', false,
      'reason', 'The printed rows could not be found on this scan.',
      'detail', format('only %s of 6 boundaries have a line within %spp of the layout',
                       coalesce(array_length(v_off, 1), 0), p_search));
  END IF;
  SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY o) INTO v_shift FROM unnest(v_off) o;

  -- 3. each boundary: the line nearest to prior + shift, within p_match, whatever its width.
  --    This is the step the blind classifier cannot do: a half-width boundary is still the boundary.
  FOR i IN 1 .. 6 LOOP
    v_best := NULL; v_bestd := NULL; v_bestj := NULL;
    FOR j IN 1 .. v_n LOOP
      IF abs(v_pct[j] - (p_prior[i] + v_shift)) <= p_match
         AND (v_bestd IS NULL OR abs(v_pct[j] - (p_prior[i] + v_shift)) < v_bestd) THEN
        v_best := v_pct[j]; v_bestd := abs(v_pct[j] - (p_prior[i] + v_shift)); v_bestj := j;
      END IF;
    END LOOP;
    IF v_best IS NULL THEN
      RETURN jsonb_build_object('ok', false,
        'reason', 'A printed line between two rows is not visible on this scan.',
        'detail', format('boundary %s expected near %s (shift %s), no line within %spp',
                         i, round(p_prior[i] + v_shift, 3), round(v_shift, 3), p_match));
    END IF;
    v_found := v_found || v_best;
    v_runs  := v_runs  || v_run[v_bestj];
    v_res   := v_res   || round(v_best - (p_prior[i] + v_shift), 3);
  END LOOP;

  -- 4. ascending, and every slot gap within p_gap of the printed gap
  FOR i IN 2 .. 6 LOOP
    IF v_found[i] <= v_found[i-1]
       OR abs((v_found[i] - v_found[i-1]) - (p_prior[i] - p_prior[i-1])) > p_gap THEN
      RETURN jsonb_build_object('ok', false,
        'reason', 'The rows on this scan are not spaced like the printed sheet.',
        'detail', format('gap %s is %s, printed %s', i - 1,
                         round(v_found[i] - v_found[i-1], 3), round(p_prior[i] - p_prior[i-1], 3)));
    END IF;
  END LOOP;

  -- 5. every stamp strictly inside its own slot, with clearance from both lines
  FOR v_row, v_y IN
    SELECT (e->>'row')::int, (e->>'y')::numeric
      FROM jsonb_array_elements(coalesce(p_stamps, '[]'::jsonb)) e
  LOOP
    IF v_row IS NULL OR v_row < 1 OR v_row > 5 OR v_y IS NULL THEN
      RETURN jsonb_build_object('ok', false,
        'reason', 'A stamp on this page is not on any printed row.',
        'detail', format('stamp row %s y %s', v_row, v_y));
    END IF;
    IF NOT (v_y > v_found[v_row] + p_clear AND v_y < v_found[v_row + 1] - p_clear) THEN
      RETURN jsonb_build_object('ok', false,
        'reason', 'A stamp sits on the line between two rows. Place it again.',
        'detail', format('row %s stamp at %s, slot %s to %s, clearance %s',
                         v_row, v_y, v_found[v_row], v_found[v_row + 1], p_clear));
    END IF;
  END LOOP;

  RETURN jsonb_build_object('ok', true,
    'boundaries', to_jsonb(v_found), 'runs', to_jsonb(v_runs),
    'shift', round(v_shift, 3), 'residuals', to_jsonb(v_res), 'usable_lines', v_n);
END $function$;

-- --------------------------------------------------------------------------------------------
-- PART 3. The page's cards with their PRINTED row. Refuses, in plain words, every shape the matcher
-- must not be handed: a card not on the printed list, a card printed on another page, a client
-- printed on several rows (the 834986 lesson: the insert trigger stacks its cards on one row), two
-- stamps on one row, a stamp with a position but no placement.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_generated_page_cards(p_dump_folder text, p_page integer)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $function$
DECLARE
  v_ticket text; v_refusal text; v_detail text; v_cards jsonb; v_n int;
BEGIN
  SELECT r.white_manifest_number INTO v_ticket
    FROM derm.address_row_map r
   WHERE r.dump_folder = p_dump_folder AND r.white_manifest_number IS NOT NULL
   LIMIT 1;
  IF v_ticket IS NULL OR NOT coalesce(derm.fn_sheet_is_generated(v_ticket), false) THEN
    RETURN jsonb_build_object(
      'refusal', 'This sheet was not printed by us, so it cannot be measured automatically. Measure it with Draw the bands.',
      'detail', 'no generated-sheet link for ' || coalesce(v_ticket, p_dump_folder),
      'ticket', v_ticket, 'cards', '[]'::jsonb);
  END IF;

  WITH c AS (
    SELECT r.id, r.matched_client_id, r.stamp_y_pct, r.stamp_placed_at, s.slot,
           CASE WHEN s.slot IS NULL THEN NULL ELSE ((s.slot - 1) / 5) + 1 END AS printed_page,
           CASE WHEN s.slot IS NULL THEN NULL ELSE ((s.slot - 1) % 5) + 1 END AS row_on_page,
           (SELECT max(sc.rows_printed)
              FROM derm.address_sheet_manifests l
              JOIN derm.address_sheet_clients sc ON sc.sheet_id = l.sheet_id AND sc.slot = l.slot
             WHERE l.manifest_id = r.matched_manifest_id) AS rows_printed
      FROM derm.address_row_map r
      CROSS JOIN LATERAL (SELECT derm.fn_generated_sheet_slot(r.matched_manifest_id) AS slot) s
     WHERE r.dump_folder = p_dump_folder
       AND coalesce(r.stamp_page, r.page) = p_page
       AND r.stamp_y_pct IS NOT NULL
  )
  SELECT count(*),
         CASE
           WHEN count(*) = 0 THEN
             'Nothing has been stamped on this page yet.'
           WHEN bool_or(stamp_placed_at IS NULL) THEN
             'A stamp on this page has a position but was never actually placed. Place it again.'
           WHEN bool_or(slot IS NULL) THEN
             'A client on this page is not on the printed list of this sheet, so its row cannot be found automatically. A person needs to check this page in Draw the bands.'
           WHEN bool_or(derm.fn_sheet_image_position(p_dump_folder, printed_page) IS DISTINCT FROM p_page) THEN
             'A client on this page is printed on a different page of this sheet. A person needs to check this page in Draw the bands.'
           WHEN bool_or(rows_printed > 1) OR count(*) > count(DISTINCT matched_client_id) THEN
             'A client on this page is printed on several rows. Give it one card per permit and place each stamp on its own row, then measure the page with Draw the bands.'
           WHEN count(*) > count(DISTINCT row_on_page) THEN
             'Two stamps on this page sit on the same printed row. Place them again.'
         END,
         format('%s stamped cards, %s clients, %s without a printed slot, %s multi-row',
                count(*), count(DISTINCT matched_client_id),
                count(*) FILTER (WHERE slot IS NULL), count(*) FILTER (WHERE rows_printed > 1)),
         jsonb_agg(jsonb_build_object('row_id', id, 'client_id', matched_client_id,
                                      'row', row_on_page, 'y', stamp_y_pct)
                   ORDER BY row_on_page, id)
    INTO v_n, v_refusal, v_detail, v_cards
    FROM c;

  RETURN jsonb_build_object('refusal', v_refusal, 'detail', v_detail, 'ticket', v_ticket,
                            'cards', coalesce(v_cards, '[]'::jsonb));
END $function$;

-- --------------------------------------------------------------------------------------------
-- PART 4. Grants: the default privileges hand EXECUTE to authenticated; take it back.
-- --------------------------------------------------------------------------------------------
REVOKE ALL ON FUNCTION derm.fn_generated_template_boundaries() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_generated_template_boundaries() TO service_role;
REVOKE ALL ON FUNCTION derm.fn_match_generated_page(jsonb, jsonb, numeric[], numeric, numeric, numeric, numeric, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_match_generated_page(jsonb, jsonb, numeric[], numeric, numeric, numeric, numeric, numeric) TO service_role;
REVOKE ALL ON FUNCTION derm.fn_generated_page_cards(text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_generated_page_cards(text, integer) TO service_role;

-- --------------------------------------------------------------------------------------------
-- VERIFY. PL/pgSQL is not parsed at creation: every arm is CALLED here.
-- --------------------------------------------------------------------------------------------
DO $verify$
DECLARE
  v_prior numeric[] := derm.fn_generated_template_boundaries();
  v_ok    jsonb;   -- lines exactly on the template, run 0.99
  v_m     jsonb;
  v_cards jsonb;
  v_lines_835076_p1 jsonb := '[{"pct":14.317,"run":0.990},{"pct":23.789,"run":0.404},{"pct":26.125,"run":0.990},{"pct":30.19,"run":0.404},{"pct":34.343,"run":0.989},{"pct":37.716,"run":0.404},{"pct":41.047,"run":0.987},{"pct":44.291,"run":0.403},{"pct":48.227,"run":0.987},{"pct":51.903,"run":0.403},{"pct":56.012,"run":0.988},{"pct":59.689,"run":0.404},{"pct":63.754,"run":0.989},{"pct":66.912,"run":0.987},{"pct":69.247,"run":0.698}]';
  -- ticket-833049 page 1: a handwritten SIX-slot pad linked to a generated sheet record. The one
  -- page in the estate that MUST be refused: the matcher has no business on a form we did not print.
  v_lines_833049_p1 jsonb := '[{"pct":13.118,"run":0.719},{"pct":15.865,"run":0.981},{"pct":26.992,"run":0.359},{"pct":29.396,"run":0.980},{"pct":32.349,"run":0.368},{"pct":35.096,"run":0.981},{"pct":37.981,"run":0.359},{"pct":40.728,"run":0.982},{"pct":43.613,"run":0.366},{"pct":46.36,"run":0.982},{"pct":49.245,"run":0.359},{"pct":51.992,"run":0.983},{"pct":54.876,"run":0.363},{"pct":57.624,"run":0.984},{"pct":60.508,"run":0.361},{"pct":63.324,"run":0.984},{"pct":65.385,"run":0.984},{"pct":67.995,"run":0.983}]';
  v_stamps jsonb := '[{"row":1,"y":29.80},{"row":2,"y":37.72},{"row":3,"y":44.48},{"row":4,"y":51.81},{"row":5,"y":60.04}]';
  v_tech  text := '(_|\[|\]|jsonb|numeric|null|prior|boundary [0-9])';
  v_b     numeric[];
BEGIN
  -- 0. the template is the derived one, not a typed one
  IF v_prior IS DISTINCT FROM ARRAY[25.84, 33.76, 41.10, 48.145, 55.925, 64.155]::numeric[] THEN
    RAISE EXCEPTION 'VERIFY 0 FAILED: template is %', v_prior;
  END IF;
  SELECT jsonb_agg(jsonb_build_object('pct', p, 'run', 0.99)) INTO v_ok FROM unnest(v_prior) p;

  -- a. lines exactly on the template: accepted, shift 0, residuals 0
  v_m := derm.fn_match_generated_page(v_ok, v_stamps, v_prior);
  IF NOT (v_m->>'ok')::boolean OR (v_m->>'shift')::numeric <> 0
     OR (SELECT bool_or(r::numeric <> 0) FROM jsonb_array_elements_text(v_m->'residuals') r) THEN
    RAISE EXCEPTION 'VERIFY a FAILED: %', v_m;
  END IF;

  -- b. the same lines shifted by +2.4 (inside the search window): accepted, shift 2.4;
  --    shifted by +2.6 (outside it): refused
  v_m := derm.fn_match_generated_page((SELECT jsonb_agg(jsonb_build_object('pct', p + 2.4, 'run', 0.99)) FROM unnest(v_prior) p),
                                      '[]'::jsonb, v_prior);
  IF NOT (v_m->>'ok')::boolean OR (v_m->>'shift')::numeric <> 2.4 THEN RAISE EXCEPTION 'VERIFY b1 FAILED: %', v_m; END IF;
  v_m := derm.fn_match_generated_page((SELECT jsonb_agg(jsonb_build_object('pct', p + 2.6, 'run', 0.99)) FROM unnest(v_prior) p),
                                      '[]'::jsonb, v_prior);
  IF (v_m->>'ok')::boolean OR v_m->>'reason' <> 'The printed rows could not be found on this scan.' THEN
    RAISE EXCEPTION 'VERIFY b2 FAILED: %', v_m;
  END IF;

  -- c. a real generated page (835076 p1, the Node detector's output): accepted, the six known lines
  v_m := derm.fn_match_generated_page(v_lines_835076_p1, v_stamps, v_prior);
  v_b := ARRAY(SELECT r::numeric FROM jsonb_array_elements_text(v_m->'boundaries') r);
  IF NOT (v_m->>'ok')::boolean OR v_b IS DISTINCT FROM ARRAY[26.125, 34.343, 41.047, 48.227, 56.012, 63.754]::numeric[] THEN
    RAISE EXCEPTION 'VERIFY c FAILED: %', v_m;
  END IF;
  -- and the header (14.317) and footer (66.912) bars never got picked
  IF 14.317 = ANY(v_b) OR 66.912 = ANY(v_b) THEN RAISE EXCEPTION 'VERIFY c FAILED: a form bar was taken as a boundary'; END IF;

  -- d. a six-slot pad (833049 p1): refused, whatever the reason, and the reason is plain
  v_m := derm.fn_match_generated_page(v_lines_833049_p1, '[]'::jsonb, v_prior);
  IF (v_m->>'ok')::boolean THEN RAISE EXCEPTION 'VERIFY d FAILED: a handwritten pad was accepted: %', v_m; END IF;
  IF v_m->>'reason' !~ '^(A printed line between two rows is not visible on this scan\.|The rows on this scan are not spaced like the printed sheet\.|The printed rows could not be found on this scan\.)$' THEN
    RAISE EXCEPTION 'VERIFY d FAILED: unexpected reason %', v_m;
  END IF;

  -- e. one boundary missing (the 4th): refused as "not visible"
  v_m := derm.fn_match_generated_page((SELECT jsonb_agg(jsonb_build_object('pct', p, 'run', 0.99)) FROM unnest(v_prior) WITH ORDINALITY u(p, n) WHERE n <> 4),
                                      '[]'::jsonb, v_prior);
  IF (v_m->>'ok')::boolean OR v_m->>'reason' <> 'A printed line between two rows is not visible on this scan.' THEN
    RAISE EXCEPTION 'VERIFY e FAILED: %', v_m;
  END IF;

  -- f. a stamp on a line: refused
  v_m := derm.fn_match_generated_page(v_ok, '[{"row":1,"y":33.9}]'::jsonb, v_prior);
  IF (v_m->>'ok')::boolean OR v_m->>'reason' <> 'A stamp sits on the line between two rows. Place it again.' THEN
    RAISE EXCEPTION 'VERIFY f FAILED: %', v_m;
  END IF;

  -- g. a short line (run 0.20) and a mid-slot divider (run 0.40) added: ignored / not picked
  v_m := derm.fn_match_generated_page(v_ok || '[{"pct":30.0,"run":0.20},{"pct":30.3,"run":0.40}]'::jsonb, v_stamps, v_prior);
  v_b := ARRAY(SELECT r::numeric FROM jsonb_array_elements_text(v_m->'boundaries') r);
  IF NOT (v_m->>'ok')::boolean OR v_b IS DISTINCT FROM v_prior THEN RAISE EXCEPTION 'VERIFY g FAILED: %', v_m; END IF;

  -- h. two boundaries pushed towards each other by 0.7 each (each still matches, the gap does not)
  v_m := derm.fn_match_generated_page(
           (SELECT jsonb_agg(jsonb_build_object('pct', CASE n WHEN 3 THEN p + 0.7 WHEN 4 THEN p - 0.7 ELSE p END, 'run', 0.99))
              FROM unnest(v_prior) WITH ORDINALITY u(p, n)),
           '[]'::jsonb, v_prior);
  IF (v_m->>'ok')::boolean OR v_m->>'reason' <> 'The rows on this scan are not spaced like the printed sheet.' THEN
    RAISE EXCEPTION 'VERIFY h FAILED: %', v_m;
  END IF;

  -- i. a 5-element prior is refused up front
  v_m := derm.fn_match_generated_page(v_ok, '[]'::jsonb, v_prior[1:5]);
  IF (v_m->>'ok')::boolean THEN RAISE EXCEPTION 'VERIFY i FAILED'; END IF;

  -- j. no refusal sentence carries a technical word
  FOR v_m IN
    SELECT derm.fn_match_generated_page(l, s, v_prior)
      FROM (VALUES (v_lines_833049_p1, '[]'::jsonb), (v_ok, '[{"row":1,"y":33.9}]'::jsonb),
                   ('[]'::jsonb, '[]'::jsonb), (v_ok, '[{"row":9,"y":50}]'::jsonb)) t(l, s)
  LOOP
    IF (v_m->>'ok')::boolean OR v_m->>'reason' ~ v_tech THEN RAISE EXCEPTION 'VERIFY j FAILED: %', v_m; END IF;
  END LOOP;

  -- k. the page-card reader on live data (read-only)
  v_cards := derm.fn_generated_page_cards('ticket-835076', 1);
  IF v_cards->>'refusal' IS NOT NULL OR jsonb_array_length(v_cards->'cards') <> 5
     OR (SELECT array_agg((c->>'row')::int ORDER BY (c->>'row')::int) FROM jsonb_array_elements(v_cards->'cards') c) IS DISTINCT FROM ARRAY[1,2,3,4,5] THEN
    RAISE EXCEPTION 'VERIFY k1 FAILED: %', v_cards;
  END IF;
  v_cards := derm.fn_generated_page_cards('ticket-833395', 1);        -- 242-WYN: 3 printed rows, 1 card
  IF v_cards->>'refusal' IS NULL OR v_cards->>'refusal' ~ v_tech THEN RAISE EXCEPTION 'VERIFY k2 FAILED: %', v_cards; END IF;
  v_cards := derm.fn_generated_page_cards('ticket-834986', 1);        -- a pad page on a folder with a generated link
  IF v_cards->>'refusal' IS NULL OR v_cards->>'refusal' ~ v_tech THEN RAISE EXCEPTION 'VERIFY k3 FAILED: %', v_cards; END IF;
  v_cards := derm.fn_generated_page_cards('window4-sheet1', 1);       -- handwritten, no link at all
  IF v_cards->>'refusal' NOT LIKE 'This sheet was not printed by us%' THEN RAISE EXCEPTION 'VERIFY k4 FAILED: %', v_cards; END IF;
  v_cards := derm.fn_generated_page_cards('ticket-835076', 9);        -- a page that does not exist
  IF v_cards->>'refusal' <> 'Nothing has been stamped on this page yet.' THEN RAISE EXCEPTION 'VERIFY k5 FAILED: %', v_cards; END IF;

  -- l. grants
  IF has_function_privilege('authenticated', 'derm.fn_match_generated_page(jsonb, jsonb, numeric[], numeric, numeric, numeric, numeric, numeric)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'derm.fn_generated_page_cards(text, integer)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'derm.fn_generated_page_cards(text, integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY l FAILED: grants';
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: template derived, matcher accepts the template and a real page, refuses a pad, a missing line, a bad gap, a stamp on a line, and every refusal is plain language; page-card reader agrees with the live corpus.';
END
$verify$;

COMMIT;
```

- [ ] **Step 2: Rehearse (rolled back), then apply**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-15_1000_generated_page_matcher.sql rehearse
```

Expected: `REHEARSAL: commit swapped for rollback`, `HTTP 201`, body `[]`. A `VERIFY <letter> FAILED` in the body means the assertion named it; a `42601`/`42P01` means a typo in a body that was never parsed until now. Fix the file, rehearse again. Then:

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-15_1000_generated_page_matcher.sql
```

Expected: `HTTP 201`, `[]`.

- [ ] **Step 3: Prove the functions exist live and are callable**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && printf '%s\n' "select derm.fn_generated_template_boundaries() as prior, derm.fn_match_generated_page('[{\"pct\":25.84,\"run\":0.99},{\"pct\":33.76,\"run\":0.99},{\"pct\":41.10,\"run\":0.99},{\"pct\":48.145,\"run\":0.99},{\"pct\":55.925,\"run\":0.99},{\"pct\":64.155,\"run\":0.99}]'::jsonb, '[]'::jsonb, derm.fn_generated_template_boundaries()) as m;" > scripts/probes/generated_finisher/t2.out.sql && node scripts/q.js scripts/probes/generated_finisher/t2.out.sql scripts/probes/generated_finisher/t2.out.json && cat scripts/probes/generated_finisher/t2.out.json
```

Expected: `"ok": true`, `"shift": 0`.

- [ ] **Step 4: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && git pull -q --rebase origin main && git add docs/migrations/2026-09-15_1000_generated_page_matcher.sql && git commit -q -m "Generated-sheet matcher: layout-guided boundary matching as read-only functions" -m "derm.fn_match_generated_page (pure), derm.fn_generated_page_cards and the derived template, so Phase 0 can replay the real algorithm over every accepted generated page before anything writes." -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" && git push -q origin main && git log -1 --format='%h %s'
```

---
### Task 3: Phase 0, the corpus replay (nothing writes)

Every stamped page of every generated folder (33 pages over 20 folders on 2026-09-14, all but 835076
completed and serving) gets the detector run on its scan and the matcher run on the result, and the
six boundaries are compared with the geometry a person accepted. The same run calibrates the prior
(the mean printed layout) and the tolerances. **The finisher does not ship until Fred has seen this
report.**

**Files:**
- Create: `scripts/probes/generated_finisher/phase0_corpus.mjs`
- Create (by running it): `scripts/probes/generated_finisher/phase0_results.json`, `phase0_report.md`

- [ ] **Step 1: Write the script**

`scripts/probes/generated_finisher/phase0_corpus.mjs`:

```js
// Phase 0 of docs/superpowers/plans/2026-09-14-generated-sheet-finisher.md.
// Replays the layout-guided matcher (derm.fn_match_generated_page, migration 2026-09-15_1000) over
// every stamped page of every generated folder, WITHOUT WRITING ANYTHING, and compares its six
// boundaries with the geometry a person accepted (bands, extent, admitted printed rules). Pass 1
// uses the stamp-midpoint template as the prior; the pages it accepts calibrate the prior (the mean
// printed layout) and pass 2 re-runs everything with it and reports the residuals that pin the
// tolerances.
//
// USE: node scripts/probes/generated_finisher/phase0_corpus.mjs
// Reads Supabase/.env (Management API), downloads scans into img/ (gitignored), writes
// phase0_results.json and phase0_report.md next to this file. Re-runnable; cached scans are reused.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { detectRules } from '../../../supabase/functions/_shared/printed_rule_detector.mjs';

const require = createRequire(import.meta.url);
const jpeg = require('jpeg-js');
const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../../..');

for (const line of fs.readFileSync(path.join(root, '.env'), 'utf8').split(/\r?\n/)) {
  const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/);
  if (!m) continue;
  let v = m[2].trim();
  if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
  if (!(m[1] in process.env)) process.env[m[1]] = v;
}

async function sql(query) {
  const r = await fetch(`https://api.supabase.com/v1/projects/${process.env.SUPABASE_PROJECT_ID}/database/query`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${process.env.SUPABASE_PAT}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  const t = await r.text();
  if (!r.ok) throw new Error(`HTTP ${r.status}: ${t.slice(0, 500)}`);
  return JSON.parse(t);
}
const lit = (v) => `'${JSON.stringify(v).replace(/'/g, "''")}'::jsonb`;
const arr = (a) => `ARRAY[${a.map((x) => x.toFixed(4)).join(',')}]::numeric[]`;

// 1. the corpus: one row per (generated folder, stamped image position), with what a person accepted
const CORPUS_SQL = `
with gen as (
  select distinct r.dump_folder, r.white_manifest_number as ticket
    from derm.address_row_map r
   where r.white_manifest_number is not null and derm.fn_sheet_is_generated(r.white_manifest_number)
), pages as (
  select g.dump_folder, g.ticket, coalesce(r.stamp_page, r.page) as page
    from gen g join derm.address_row_map r on r.dump_folder = g.dump_folder
   where r.stamp_y_pct is not null
   group by 1, 2, 3
)
select p.dump_folder, p.ticket, p.page,
       (derm.ticket_page_images(p.ticket))[p.page] as image_url,
       derm.fn_generated_page_cards(p.dump_folder, p.page) as cards,
       (select jsonb_agg(jsonb_build_object('row_id', r.id, 'y', r.stamp_y_pct, 'y0', r.band_y0_pct, 'y1', r.band_y1_pct) order by r.stamp_y_pct)
          from derm.address_row_map r
         where r.dump_folder = p.dump_folder and coalesce(r.stamp_page, r.page) = p.page and r.stamp_y_pct is not null) as accepted_bands,
       e.top_pct, e.bottom_pct, e.source as extent_source,
       (select jsonb_agg(v.rule_pct order by v.rule_pct) from derm.v_page_printed_rules v
         where v.dump_folder = p.dump_folder and v.effective_page = p.page and v.kind = 'boundary') as admitted_boundaries,
       (select string_agg(distinct v.source, ',') from derm.v_page_printed_rules v
         where v.dump_folder = p.dump_folder and v.effective_page = p.page) as admitted_source,
       coalesce(s.completed, false) as completed
  from pages p
  left join derm.page_block_extents e on e.dump_folder = p.dump_folder and e.effective_page = p.page
  left join derm.stamp_sheet_status s on s.dump_folder = p.dump_folder
 order by 1, 3;`;

async function scanFor(row) {
  const file = path.join(here, 'img', `${row.dump_folder}_p${row.page}.jpg`);
  if (!fs.existsSync(file)) {
    const r = await fetch(row.image_url);
    if (!r.ok) throw new Error(`${row.dump_folder} p${row.page}: image HTTP ${r.status}`);
    fs.writeFileSync(file, Buffer.from(await r.arrayBuffer()));
  }
  const bytes = fs.readFileSync(file);
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8) return { error: 'not a JPEG (the finisher will leave this page to a person)' };
  return detectRules(jpeg.decode(bytes, { useTArray: true }));
}

function compare(bounds, row) {
  // how far the matched boundaries sit from what a person accepted; null when nothing to compare
  const byRow = new Map((row.cards.cards || []).map((c) => [c.row_id, c.row]));
  const deltas = { bands: [], extent: [], admitted: [] };
  for (const b of row.accepted_bands || []) {
    const r = byRow.get(b.row_id);
    if (!r || b.y0 == null) continue;
    deltas.bands.push(+Math.abs(bounds[r - 1] - b.y0).toFixed(3), +Math.abs(bounds[r] - b.y1).toFixed(3));
  }
  if (row.top_pct != null) deltas.extent.push(+Math.abs(bounds[0] - row.top_pct).toFixed(3), +Math.abs(bounds[5] - row.bottom_pct).toFixed(3));
  for (const x of bounds) {
    const adm = (row.admitted_boundaries || []).map(Number);
    if (adm.length) deltas.admitted.push(+Math.min(...adm.map((a) => Math.abs(a - x))).toFixed(3));
  }
  const max = (a) => (a.length ? Math.max(...a) : null);
  return { max_band: max(deltas.bands), max_extent: max(deltas.extent), max_admitted: max(deltas.admitted), deltas };
}

async function runPass(rows, prior, label) {
  const out = [];
  for (const row of rows) {
    const stamps = (row.cards.cards || []).filter((c) => c.row != null).map((c) => ({ row: c.row, y: Number(c.y) }));
    const m = (await sql(`select derm.fn_match_generated_page(${lit(row.lines)}, ${lit(stamps)}, ${arr(prior)}) as m;`))[0].m;
    const rec = { dump_folder: row.dump_folder, page: row.page, pass: label, ineligible: row.cards.refusal || null,
                  ok: m.ok, reason: m.reason || null, detail: m.detail || null, shift: m.shift ?? null,
                  residuals: m.residuals || null, boundaries: m.boundaries || null };
    if (m.ok) {
      const c = compare(m.boundaries.map(Number), row);
      Object.assign(rec, c);
      const tol = 0.35;
      rec.verdict = rec.ineligible ? 'INELIGIBLE_BUT_MATCHED'
        : (c.max_band != null && c.max_band <= tol && (c.max_extent == null || c.max_extent <= tol)) ? 'MATCH'
        : (c.max_admitted != null && c.max_admitted <= tol) ? 'RULES_ONLY'
        : 'MISMATCH';
      // stamp clearance: the smallest distance from any stamp to either line of its slot
      rec.min_clearance = stamps.length ? +Math.min(...stamps.map((s) => Math.min(s.y - m.boundaries[s.row - 1], m.boundaries[s.row] - s.y))).toFixed(3) : null;
      rec.gap_dev = +Math.max(...[1, 2, 3, 4, 5].map((i) => Math.abs((m.boundaries[i] - m.boundaries[i - 1]) - (prior[i] - prior[i - 1])))).toFixed(3);
    } else {
      rec.verdict = rec.ineligible ? 'INELIGIBLE_AND_REFUSED' : 'REFUSED';
    }
    out.push(rec);
  }
  return out;
}

const roundUp = (x, step) => Math.ceil(x / step - 1e-9) * step;

(async () => {
  fs.mkdirSync(path.join(here, 'img'), { recursive: true });
  const rows = await sql(CORPUS_SQL);
  if (rows.length < 30) throw new Error(`corpus has ${rows.length} pages; expected the 33 measured on 2026-09-14 or more. Check fn_sheet_is_generated.`);
  const template = (await sql('select derm.fn_generated_template_boundaries() as p;'))[0].p.map(Number);

  for (const row of rows) {
    const d = await scanFor(row);
    row.lines = d.error ? null : d.rules;
    row.detect = d.error ? { error: d.error } : { W: d.W, H: d.H, skew: d.skew, n: d.rules.length };
    if (d.error) console.log(`${row.dump_folder} p${row.page}: ${d.error}`);
  }
  const usable = rows.filter((r) => r.lines);

  // pass 1: the template as the prior
  const pass1 = await runPass(usable, template, 'template');
  const accepted = pass1.filter((r) => r.ok && r.verdict === 'MATCH');
  if (accepted.length < 10) throw new Error(`only ${accepted.length} pages MATCH with the template prior; calibration needs at least 10. Read pass 1 before going on.`);
  // the calibrated prior: the mean of each matched boundary over the pages that MATCH (offset and all;
  // the matcher removes the per-page shift itself, so only the SHAPE matters)
  const prior2 = [0, 1, 2, 3, 4, 5].map((i) => +(accepted.reduce((s, r) => s + Number(r.boundaries[i]), 0) / accepted.length).toFixed(3));

  // pass 2: the calibrated prior
  const pass2 = await runPass(usable, prior2, 'calibrated');
  const ok2 = pass2.filter((r) => r.ok);
  const maxRes = Math.max(...ok2.flatMap((r) => r.residuals.map((x) => Math.abs(Number(x)))));
  const maxGap = Math.max(...ok2.map((r) => r.gap_dev));
  const minClear = Math.min(...ok2.filter((r) => r.min_clearance != null).map((r) => r.min_clearance));
  const tolerances = {
    // rule: the worst value the accepted corpus needs, rounded up to 0.05, plus 0.25 of margin;
    // never below 0.5 and never above 1.0. Phase 0's job is to make these measured, not chosen.
    match: Math.min(1.0, Math.max(0.5, roundUp(maxRes + 0.25, 0.05))),
    gap:   Math.min(1.0, Math.max(0.5, roundUp(maxGap + 0.25, 0.05))),
    clear: minClear >= 1.0 ? 0.5 : +Math.max(0.2, roundUp(minClear / 2, 0.05)).toFixed(2),
    search: 2.5,
    measured: { max_abs_residual: +maxRes.toFixed(3), max_gap_deviation: +maxGap.toFixed(3), min_stamp_clearance: +minClear.toFixed(3) },
  };

  const results = { generated_at: new Date().toISOString(), pages: rows.length, usable: usable.length,
                    template_prior: template, calibrated_prior: prior2, tolerances,
                    pass1, pass2,
                    lines: Object.fromEntries(usable.map((r) => [`${r.dump_folder}_p${r.page}`, { image_url: r.image_url, detect: r.detect, lines: r.lines }])) };
  fs.writeFileSync(path.join(here, 'phase0_results.json'), JSON.stringify(results, null, 1) + '\n');

  const fmt = (r) => `| ${r.dump_folder} | ${r.page} | ${r.verdict} | ${r.ok ? `shift ${r.shift}; band ${r.max_band ?? '-'} extent ${r.max_extent ?? '-'} rules ${r.max_admitted ?? '-'}` : r.reason} | ${r.ineligible ?? ''} |`;
  const md = [
    `# Phase 0: the layout-guided matcher over the generated-sheet corpus`, ``,
    `Generated ${results.generated_at} by phase0_corpus.mjs. ${rows.length} pages, ${usable.length} with a readable JPEG. Nothing was written.`, ``,
    `Template prior (stamp midpoints): ${template.join(' / ')}`,
    `Calibrated prior (mean over ${accepted.length} MATCH pages): ${prior2.join(' / ')}`,
    `Tolerances to pin: match ${tolerances.match} (worst residual ${tolerances.measured.max_abs_residual}), gap ${tolerances.gap} (worst ${tolerances.measured.max_gap_deviation}), clear ${tolerances.clear} (smallest stamp clearance ${tolerances.measured.min_stamp_clearance}), search 2.5`, ``,
    `Verdicts: MATCH = every band edge and both extents within 0.35pp of what a person accepted; RULES_ONLY = the six boundaries are the admitted printed rules but the saved bands or extent differ (read why: a templated extent, a hand-set band); MISMATCH = different geometry, must be explained or the matcher does not ship; REFUSED = the matcher declined, a person says whether the refusal is right; INELIGIBLE = fn_generated_page_cards refused the page (multi-row client, card not on the printed list, ...), the matcher result is shown for information only.`, ``,
    `## Pass 2 (calibrated prior)`, ``, `| folder | page | verdict | result | ineligible because |`, `|---|---|---|---|---|`,
    ...pass2.map(fmt), ``,
    `## Pass 1 (template prior)`, ``, `| folder | page | verdict | result | ineligible because |`, `|---|---|---|---|---|`,
    ...pass1.map(fmt), ``,
    `## Counts`, ``,
    ...['MATCH', 'RULES_ONLY', 'MISMATCH', 'REFUSED', 'INELIGIBLE_BUT_MATCHED', 'INELIGIBLE_AND_REFUSED'].map((v) => `- pass 2 ${v}: ${pass2.filter((r) => r.verdict === v).length}`),
    ``, `## Sign-off`, ``, `- [ ] Fred has read the REFUSED / INELIGIBLE / MISMATCH / RULES_ONLY rows and agrees with each (write the reason next to each row that is not MATCH).`, ``,
  ].join('\n');
  fs.writeFileSync(path.join(here, 'phase0_report.md'), md);
  console.log(md.split('\n').slice(0, 8).join('\n'));
  console.log(...['MATCH', 'RULES_ONLY', 'MISMATCH', 'REFUSED', 'INELIGIBLE_BUT_MATCHED', 'INELIGIBLE_AND_REFUSED'].map((v) => `${v}=${pass2.filter((r) => r.verdict === v).length}`));
})().catch((e) => { console.error(e); process.exit(1); });
```

- [ ] **Step 2: Run it**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/generated_finisher/phase0_corpus.mjs
```

Expected: the report head (both priors, the tolerances) and a count line. What the 2026-09-14 census predicts, so a surprise is recognisable:
- `ticket-833049` p1 and p2: REFUSED or INELIGIBLE (handwritten six-slot pads 338 and 387 linked to sheet 1089; boundaries 5.5pp apart). A person agrees.
- `ticket-834986` p1: INELIGIBLE (its cards are not on sheet 1079's one-client list) and the lines are a six-slot pad. p2: the second boundary is printed at run 0.108, below `p_min_run`; expect REFUSED "not visible", and a person agrees (it took a hand-marked line).
- `ticket-833395` p1: INELIGIBLE (242-WYN is printed on three rows and holds one card). Known un-split folder.
- `ticket-310429`, `ticket-831325`: extents are the templated 25.8 / 64.4 from 2026-08-03, not measured, so expect RULES_ONLY with `extent` deltas up to about 1pp. That is a finding about those extents, not about the matcher.
- `ticket-311045` p1, `ticket-831325` p1: bands are DERIVED (no override), so `band` deltas are against the stamp-midpoint heuristic; expect RULES_ONLY.
- `ticket-832194` p1: the admitted set has 5 boundaries (the top one was classified as a divider); the matcher should pick 24.486 as boundary 1; compare against the extent (24.4).
- Everything else: MATCH, with `band` and `extent` deltas at or under 0.05 (the admitted rules came from the same detector; the Node port sits about 0.04pp from the browser run).
- `ticket-835076` p1: MATCH against `2026-09-14_0030` (26.168 / 63.798 versus the Node 26.125 / 63.754).

If a page reads MISMATCH, open its scan and the served document before touching a tolerance: a tolerance is calibrated on pages that are RIGHT, never widened to admit a page that is wrong.

- [ ] **Step 3: Read every non-MATCH row against the scan** (`scripts/probes/derm_band_review/annotate.js` draws a page's rules over its scan; the served documents open from `derm.redacted_manifest_docs.url`). Write the agreed reason next to each row in `phase0_report.md`, in the Sign-off section. Then commit the report and results (numbers only; the scans stay in the gitignored `img/`).

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && git status --porcelain scripts/probes/generated_finisher/ && git pull -q --rebase origin main && git add scripts/probes/generated_finisher/phase0_corpus.mjs scripts/probes/generated_finisher/phase0_results.json scripts/probes/generated_finisher/phase0_report.md && git commit -q -m "Phase 0: replay the generated-sheet matcher over the accepted corpus, calibrate the prior" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" && git push -q origin main && git log -1 --format='%h %s'
```

Expected: `git status` shows only the three files (img/ is ignored); one commit pushed.

- [ ] **Step 4: CHECKPOINT. Show Fred the report and stop.** Post the pass-2 table and the tolerance line in chat, name every row that is not MATCH with its agreed reason, and ask for his go-ahead before Task 4. Nothing below writes until he says so. Record his answer in `phase0_report.md`'s Sign-off section and in `WORKING-NOW.md`.

---
### Task 4: Admit `template-v1-` rules, ranked human > template > runlen (migration B)

Two views select "the scan whose rules a page uses": `derm.v_page_printed_rules` (the guards and the
Studio read it) and `derm.v_band_edge_check`, which carries its own copy of the same CTE (found the
hard way on 2026-09-07; that migration's VERIFY could not see a view). Both are patched from the
LIVE `pg_get_viewdef` output by a generator that asserts each anchor occurs exactly once, so nothing
is retyped. The predicate and the rank become two tiny functions so a fourth reader cannot diverge.

**Files:**
- Create: `scripts/probes/generated_finisher/gen_precedence_migration.py`
- Create (generated): `docs/migrations/2026-09-15_1100_template_rules_precedence.sql`

- [ ] **Step 1: Dump the live bodies**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && printf '%s\n' "select 'v_page_printed_rules' as k, pg_get_viewdef('derm.v_page_printed_rules'::regclass, true) as def union all select 'v_band_edge_check', pg_get_viewdef('derm.v_band_edge_check'::regclass, true) union all select 'record_page_rules', pg_get_functiondef('derm.record_page_rules(text,integer,text,text,jsonb,jsonb,boolean)'::regprocedure) union all select 'is_rule_source', pg_get_functiondef('derm._is_rule_source(text)'::regprocedure);" > scripts/probes/generated_finisher/precedence_defs.out.sql && node scripts/q.js scripts/probes/generated_finisher/precedence_defs.out.sql scripts/probes/generated_finisher/precedence_defs.out.json && node -e "const r=require('./scripts/probes/generated_finisher/precedence_defs.out.json'); for (const x of r) console.log(x.k, x.def.length);"
```

Expected: four lines with byte counts (`v_page_printed_rules` about 850, `v_band_edge_check` about 7500).

- [ ] **Step 2: Write the generator**

`scripts/probes/generated_finisher/gen_precedence_migration.py`:

```python
# Generates docs/migrations/2026-09-15_1100_template_rules_precedence.sql from the LIVE view and
# function bodies dumped by precedence_defs.out.sql (Task 4 step 1). Every patch is an anchored
# replacement asserted to occur exactly once; nothing is retyped (CLAUDE.md, CREATE OR REPLACE rule).
# USE: python scripts/probes/generated_finisher/gen_precedence_migration.py
import json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.abspath(os.path.join(here, '..', '..', '..'))
defs = {r['k']: r['def'] for r in json.load(open(os.path.join(here, 'precedence_defs.out.json'), encoding='utf-8'))}

def patch(body, pairs, name):
    for old, new in pairs:
        n = body.count(old)
        if n != 1:
            sys.exit(f'{name}: anchor occurs {n} times, expected 1:\n{old}')
        body = body.replace(old, new)
    return body

vppr = patch(defs['v_page_printed_rules'], [
    ("WHERE s.source ~~ 'runlen-v2-%'::text OR s.source ~~ 'human-v1-%'::text",
     "WHERE derm._is_rule_source(s.source)"),
    ("ORDER BY s.dump_folder, s.effective_page, (s.source ~~ 'human-v1-%'::text) DESC, s.scanned_at DESC",
     "ORDER BY s.dump_folder, s.effective_page, derm._rule_source_rank(s.source), s.scanned_at DESC"),
], 'v_page_printed_rules')

vbec = patch(defs['v_band_edge_check'], [
    ("WHERE page_rule_scans.source ~~ 'runlen-v2-%'::text OR page_rule_scans.source ~~ 'human-v1-%'::text",
     "WHERE derm._is_rule_source(page_rule_scans.source)"),
    ("ORDER BY page_rule_scans.dump_folder, page_rule_scans.effective_page, (page_rule_scans.source ~~ 'human-v1-%'::text) DESC, page_rule_scans.scanned_at DESC",
     "ORDER BY page_rule_scans.dump_folder, page_rule_scans.effective_page, derm._rule_source_rank(page_rule_scans.source), page_rule_scans.scanned_at DESC"),
], 'v_band_edge_check')

rpr = patch(defs['record_page_rules'], [
    ("RAISE EXCEPTION 'source must match runlen-v2-%% or human-v1-%%, got %',",
     "RAISE EXCEPTION 'source must match runlen-v2-%%, human-v1-%% or template-v1-%%, got %',"),
], 'record_page_rules')
if not rpr.rstrip().endswith('$function$'):
    sys.exit('record_page_rules body does not end with $function$')

# the predicate lives in _is_rule_source; assert the live body is the two-prefix one we replace
if "p_source LIKE 'runlen-v2-%' OR p_source LIKE 'human-v1-%'" not in defs['is_rule_source']:
    sys.exit('_is_rule_source is not the two-prefix body this generator expects')

header = '''-- ============================================================================================
-- 2026-09-15_1100_template_rules_precedence.sql   (GENERATED by
-- scripts/probes/generated_finisher/gen_precedence_migration.py from the live bodies; do not edit
-- the view bodies by hand, re-run the generator)
--
-- A third rule source, `template-v1-<date>`: printed lines matched to the layout of a GENERATED sheet
-- by the finisher (derm.fn_generated_page_measured, migration 2026-09-15_1200). Precedence per page:
--     human-v1  (a person marked the lines)            rank 0
--     template-v1 (layout-guided match on a sheet we printed)  rank 1
--     runlen-v2 (the blind detector + classifier)      rank 2
-- A person's lines always win. The layout-guided set outranks the blind classifier's on the same
-- page: when the blind scan graded OK the two are the same six lines anyway, and when it did not
-- (835076 page 2, a half-width boundary) the layout-guided set is the one that is right.
--
-- ONE PREDICATE, ONE RANK, TWO READERS. derm._is_rule_source() already existed (writer side, in
-- record_page_rules); derm._rule_source_rank() is new. Both readers that select a scan are
-- re-pointed at them: derm.v_page_printed_rules AND derm.v_band_edge_check, whose own copy of the
-- selection CTE was missed once already (2026-09-07_1810). record_page_rules' refusal text names
-- the third prefix.
--
-- INERT AT INSTALL: no template-v1 scan exists yet, so both views serve byte-identical rows before
-- and after (VERIFY 1). The precedence is proven on a synthetic scan inside a savepoint (VERIFY 2).
--
-- BODY PROVENANCE: pg_get_viewdef / pg_get_functiondef output patched by anchored replacement, each
-- anchor asserted to occur exactly once by the generator.
-- RULE 8: no table changes, views and functions only.
-- ============================================================================================
BEGIN;

CREATE TEMP TABLE _vppr_before ON COMMIT DROP AS SELECT * FROM derm.v_page_printed_rules;
CREATE TEMP TABLE _vbec_before ON COMMIT DROP AS
  SELECT dump_folder, effective_page, row_id, edge_verdict, slot_verdict FROM derm.v_band_edge_check;

CREATE OR REPLACE FUNCTION derm._rule_source_rank(p_source text)
RETURNS integer
LANGUAGE sql IMMUTABLE
AS $function$
  -- lower wins. NULL for a source no reader admits.
  SELECT CASE
           WHEN p_source LIKE 'human-v1-%'    THEN 0
           WHEN p_source LIKE 'template-v1-%' THEN 1
           WHEN p_source LIKE 'runlen-v2-%'   THEN 2
         END;
$function$;

CREATE OR REPLACE FUNCTION derm._is_rule_source(p_source text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $function$
  SELECT p_source IS NOT NULL
     AND (p_source LIKE 'runlen-v2-%' OR p_source LIKE 'human-v1-%' OR p_source LIKE 'template-v1-%');
$function$;

'''

body = (header
    + 'CREATE OR REPLACE VIEW derm.v_page_printed_rules AS\n' + vppr.rstrip().rstrip(';') + ';\n\n'
    + 'CREATE OR REPLACE VIEW derm.v_band_edge_check AS\n' + vbec.rstrip().rstrip(';') + ';\n\n'
    + rpr.rstrip() + ';\n\n'
    + '''-- --------------------------------------------------------------------------------------------
-- VERIFY
-- --------------------------------------------------------------------------------------------
DO $verify$
DECLARE v_n int; v_url text; v_j jsonb; v_on_before int; v_on_after int;
BEGIN
  -- 1. inert at install: both readers serve the same rows as before
  SELECT count(*) INTO v_n FROM (
    (SELECT * FROM derm.v_page_printed_rules EXCEPT SELECT * FROM _vppr_before)
    UNION ALL
    (SELECT * FROM _vppr_before EXCEPT SELECT * FROM derm.v_page_printed_rules)) d;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 1a FAILED: v_page_printed_rules moved % rows', v_n; END IF;
  SELECT count(*) INTO v_n FROM (
    (SELECT dump_folder, effective_page, row_id, edge_verdict, slot_verdict FROM derm.v_band_edge_check EXCEPT SELECT * FROM _vbec_before)
    UNION ALL
    (SELECT * FROM _vbec_before EXCEPT SELECT dump_folder, effective_page, row_id, edge_verdict, slot_verdict FROM derm.v_band_edge_check)) d;
  IF v_n <> 0 THEN RAISE EXCEPTION 'VERIFY 1b FAILED: v_band_edge_check moved % rows', v_n; END IF;

  -- 1c. the rank and the predicate
  IF derm._rule_source_rank('human-v1-x') <> 0 OR derm._rule_source_rank('template-v1-x') <> 1
     OR derm._rule_source_rank('runlen-v2-x') <> 2 OR derm._rule_source_rank('claude-fix') IS NOT NULL
     OR NOT derm._is_rule_source('template-v1-2026-09-15') OR derm._is_rule_source('template-v2-x') OR derm._is_rule_source(NULL) THEN
    RAISE EXCEPTION 'VERIFY 1c FAILED: rank or predicate';
  END IF;

  -- 2. precedence, on a real page inside a savepoint. ticket-310429 p1: one runlen-v2 scan, no human
  --    scan, serving documents (so v_band_edge_check grades it).
  IF EXISTS (SELECT 1 FROM derm.page_rule_scans WHERE dump_folder = 'ticket-310429' AND effective_page = 1 AND source NOT LIKE 'runlen-v2-%') THEN
    RAISE EXCEPTION 'VERIFY 2 SETUP: ticket-310429 p1 is no longer a runlen-only page; pick another fixture';
  END IF;
  SELECT count(*) INTO v_on_before FROM derm.v_band_edge_check WHERE dump_folder = 'ticket-310429' AND effective_page = 1 AND edge_verdict = 'ON_RULE';
  IF v_on_before = 0 THEN RAISE EXCEPTION 'VERIFY 2 SETUP: ticket-310429 p1 has no ON_RULE band to move; pick another fixture'; END IF;
  v_url := (derm.ticket_page_images('310429'))[1];
  BEGIN
    -- a template scan OLDER than the runlen one, with six lines nowhere near the real ones
    INSERT INTO derm.page_rule_scans (dump_folder, effective_page, source_url, n_rules, n_boundaries, grade, source, scanned_at, source_etag)
    VALUES ('ticket-310429', 1, v_url, 6, 6, 'OK', 'template-v1-verify', '2020-01-01', derm._img_etag(v_url));
    INSERT INTO derm.page_row_rules (dump_folder, effective_page, rule_pct, ink_frac, source, run_frac, kind, kind_confirmed)
    SELECT 'ticket-310429', 1, p, 0.9, 'template-v1-verify', 0.99, 'boundary', false FROM unnest(ARRAY[10,20,30,40,50,60]) p;
    IF (SELECT count(*) FROM derm.v_page_printed_rules WHERE dump_folder = 'ticket-310429' AND effective_page = 1 AND source = 'template-v1-verify') <> 6
       OR (SELECT count(*) FROM derm.v_page_printed_rules WHERE dump_folder = 'ticket-310429' AND effective_page = 1 AND source <> 'template-v1-verify') <> 0 THEN
      RAISE EXCEPTION 'VERIFY 2a FAILED: an older template-v1 scan did not outrank the runlen-v2 scan';
    END IF;
    -- the band grader follows: the real bands are now off the (fake) rules, so ON_RULE must drop
    SELECT count(*) INTO v_on_after FROM derm.v_band_edge_check WHERE dump_folder = 'ticket-310429' AND effective_page = 1 AND edge_verdict = 'ON_RULE';
    IF v_on_after >= v_on_before THEN
      RAISE EXCEPTION 'VERIFY 2b FAILED: v_band_edge_check still grades against the runlen scan (ON_RULE % -> %)', v_on_before, v_on_after;
    END IF;
    -- a human scan older still: it wins over the template scan
    INSERT INTO derm.page_rule_scans (dump_folder, effective_page, source_url, n_rules, n_boundaries, grade, source, scanned_at, source_etag)
    VALUES ('ticket-310429', 1, v_url, 7, 7, 'OK', 'human-v1-verify', '2019-01-01', derm._img_etag(v_url));
    INSERT INTO derm.page_row_rules (dump_folder, effective_page, rule_pct, ink_frac, source, run_frac, kind, kind_confirmed)
    SELECT 'ticket-310429', 1, p, 0.9, 'human-v1-verify', 0.99, 'boundary', false FROM unnest(ARRAY[11,21,31,41,51,61,71]) p;
    IF (SELECT count(*) FROM derm.v_page_printed_rules WHERE dump_folder = 'ticket-310429' AND effective_page = 1 AND source = 'human-v1-verify') <> 7 THEN
      RAISE EXCEPTION 'VERIFY 2c FAILED: a human scan did not outrank the template scan';
    END IF;
    -- 2d. record_page_rules accepts the new prefix and refuses an unknown one with the new words
    v_j := derm.record_page_rules('ticket-310429', 1, 'template-v1-verify2', v_url,
             (SELECT jsonb_agg(jsonb_build_object('pct', p, 'run', 0.99, 'kind', 'boundary')) FROM unnest(derm.fn_generated_template_boundaries()) p),
             '{"grade":"OK","detail":"verify"}'::jsonb);
    IF NOT coalesce((v_j->>'wrote')::boolean, false) THEN RAISE EXCEPTION 'VERIFY 2d FAILED: %', v_j; END IF;
    BEGIN
      PERFORM derm.record_page_rules('ticket-310429', 1, 'bogus-v1-x', v_url, '[]'::jsonb, '{}'::jsonb);
      RAISE EXCEPTION 'VERIFY 2e FAILED: an unknown source was accepted';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE 'VERIFY 2e%' THEN RAISE; END IF;
      IF SQLERRM NOT LIKE 'source must match runlen-v2-%, human-v1-% or template-v1-%' THEN
        RAISE EXCEPTION 'VERIFY 2e FAILED: message is "%"', SQLERRM;
      END IF;
    END;
    RAISE EXCEPTION 'RB';   -- roll the fixture back
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'RB' THEN RAISE; END IF;
  END;
  IF EXISTS (SELECT 1 FROM derm.page_rule_scans WHERE source LIKE '%-verify%') THEN
    RAISE EXCEPTION 'VERIFY 2 CLEANUP FAILED: fixture scans survived the rollback';
  END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: inert at install; template-v1 outranks runlen-v2 and is outranked by human-v1 in BOTH readers; record_page_rules admits the prefix.';
END
$verify$;

COMMIT;
''')

out = os.path.join(root, 'docs', 'migrations', '2026-09-15_1100_template_rules_precedence.sql')
with open(out, 'w', encoding='utf-8', newline='\n') as f:
    f.write(body)
print('wrote', out, len(body), 'bytes')
```

- [ ] **Step 3: Generate, read the diff of the two view bodies, rehearse, apply**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && python scripts/probes/generated_finisher/gen_precedence_migration.py && grep -n "_is_rule_source\|_rule_source_rank\|template-v1" docs/migrations/2026-09-15_1100_template_rules_precedence.sql | head -20 && node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-15_1100_template_rules_precedence.sql rehearse
```

Expected: `wrote ... bytes`; the grep shows the two `WHERE derm._is_rule_source(...)` lines, the two `derm._rule_source_rank(...)` ORDER BY lines and the widened RAISE; the rehearsal returns `HTTP 201 []`. If VERIFY 2 SETUP fires, `ticket-310429` p1 has gained a human scan since; pick another page whose only scan is `runlen-v2-` and that serves documents (query `derm.page_rule_scans` grouped by folder/page) and change the fixture name in the generator in the three places it appears.

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-15_1100_template_rules_precedence.sql
```

Expected: `HTTP 201 []`.

- [ ] **Step 4: Commit the generator and the generated migration**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && git pull -q --rebase origin main && git add scripts/probes/generated_finisher/gen_precedence_migration.py docs/migrations/2026-09-15_1100_template_rules_precedence.sql && git commit -q -m "Rule sources: admit template-v1 and rank human > template > runlen in both readers" -m "derm._rule_source_rank is the one definition of precedence; derm.v_page_printed_rules and derm.v_band_edge_check both read it. Inert at install (no template-v1 scan exists), proven on a synthetic scan in a savepoint." -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" && git push -q origin main && git log -1 --format='%h %s'
```

---
### Task 5: The finisher core: ledger, writer, completion, backlog, banner reason (migration C)

Only after Fred's go-ahead on the Phase 0 report. This migration is the one that writes geometry
unattended, and every write goes through `derm.record_page_rules` and `derm.save_page_geometry`,
inside one subtransaction, so a refusal leaves no trace except the ledger row and the banner reason.

**Files:**
- Create: `docs/migrations/2026-09-15_1200_generated_sheet_finisher.sql`
- Create: `scripts/probes/generated_finisher/assemble_finisher_migration.py` (splices the two patched helper bodies and the Phase 0 fixture lines into the migration)

Three numbers come from Phase 0 and are copied by hand into PART 1 below: `calibrated_prior` (six
values) and `tolerances.match` / `tolerances.gap` / `tolerances.clear` from
`scripts/probes/generated_finisher/phase0_results.json`. The VERIFY fixture's detector lines are
spliced in by the assembly script in step 2 so a 60-number array is never retyped, and so are the two helper bodies.

- [ ] **Step 1: Write the migration** (the file as written carries four markers, `@@ACTOR_BODY@@`, `@@STAMP_KEY_BODY@@`, `@@PUBLISHABLE_DETAIL_BODY@@` and `@@LINES_834742_P2@@`, each exactly once; the assembly script in step 2 replaces the first three from live bodies and the last from Phase 0)

```sql
-- ============================================================================================
-- 2026-09-15_1200_generated_sheet_finisher.sql
--
-- THE GENERATED-SHEET FINISHER. A DERM address sheet we printed (number 1000+) now measures its
-- own pages from the scan, guided by the layout we printed, and marks itself complete when every
-- gate the human path applies is satisfied, so the blackout follows with no clicks.
--
-- Design: docs/superpowers/specs/2026-09-14-generated-sheet-auto-measure-and-complete-design.md
-- Plan:   docs/superpowers/plans/2026-09-14-generated-sheet-finisher.md (Task 5)
-- Phase 0 (the corpus replay that calibrated the prior and the tolerances below):
--         scripts/probes/generated_finisher/phase0_report.md
--
-- WHY (Fred, 2026-09-14, on 835076): "why if it has been stamped by AI can't it be marked as
-- complete? ... if it's a generated manifest ... it should be auto-stamped and auto marked as
-- complete unless it can be certain of the stamps". Two of his rules could not both hold:
-- "generated sheets are automatic" and "complete means it will be blacked out" (2026-09-03), because
-- nothing MEASURED a generated sheet automatically. This is that step.
--
-- WHAT WRITES, AND THROUGH WHAT. derm.fn_generated_page_measured(folder, page, image_url, lines,
-- meta) is called by the edge function measure-generated-page with the detector's raw lines. It
--   1. checks the image at that position is still the one measured (derm.ticket_page_images),
--   2. takes the page's cards with their PRINTED row (derm.fn_generated_page_cards, migration
--      2026-09-15_1000) and refuses the shapes a machine must not decide,
--   3. runs the pure matcher (derm.fn_match_generated_page) with the calibrated prior,
--   4. inside ONE subtransaction: derm.record_page_rules(source 'template-v1-<date>', the six
--      boundaries as kind boundary, no dividers) then derm.save_page_geometry(bands = consecutive
--      boundaries per card, extent = first..last boundary). Both or neither. Every guard G1..G14
--      runs. The 2026-08-19 rule (an extent opens the gate onto whatever bands exist) is why the two
--      are one call and why nothing is written on any refusal.
--   5. derm.fn_complete_generated_sheet(folder): the resolver's own completion write, keyed on the
--      folder, plus a gate the human path lacks: every client's card count equals its printed row
--      count on the sheet. trg_a0_completion_requires_geometry still gates it on fn_sheet_publishable.
-- Every outcome lands in derm.generated_measure_attempts (the ledger: attempts per image, the plain
-- reason, the technical detail, the raw lines), and derm.fn_sheet_publishable_detail puts the
-- reason in the Studio banner: "Page 2 could not be measured automatically: <reason>. Page 2: ...".
--
-- WHAT NEVER HAPPENS.
--   * No template value is written. Every band edge and both extents are detected lines on THIS scan;
--     the prior only chooses which lines are the boundaries. VERIFY 4d asserts it on a real page.
--   * A person's lines always win (human-v1 outranks template-v1, migration 2026-09-15_1100), and a
--     page that already has a human scan is not in the backlog at all.
--   * A completed sheet, a reopened sheet (reopened_at, the resolver's own pin), a handwritten sheet
--     (no generated-sheet link) are never touched.
--   * A client printed on several rows, a card not on the printed list, a card printed on another
--     page, two stamps on one row, a stamp with no placement: refused, in words, for a person.
--
-- TWO SMALL CHANGES TO EXISTING HELPERS, both "service_role is a machine":
--   derm._actor(text)          returns 'stamp-studio-ai' for a service_role caller with no email
--                              (Fred: everything machine-made carries the one label). A person's
--                              JWT still wins; direct SQL still gets the default.
--   derm._require_stamp_key()  lets a service_role caller through. The finisher writes through
--                              PostgREST as service_role (edge fn -> RPC), and that key already
--                              writes every table directly; the Studio's header key was never a
--                              barrier to it. Bodies copied from pg_get_functiondef, one arm added.
--
-- THE OFF SWITCH. public.app_config 'generated_sheet_auto_complete' = 'true' (missing = true).
-- 'false' stops COMPLETION only, in one statement, without a deploy; measuring continues, so the
-- geometry is banked and a person's Mark completed still works.
--
-- RULE 8: derm.generated_measure_attempts OPTS OUT (machine bookkeeping, regenerable; same as
-- derm.row_ocr_attempts and derm.sheet_number_ocr_attempts). public.app_config is already audited.
-- Grants: service_role only on every new object; authenticated reads nothing new (the banner reason
-- reaches the Studio through fn_sheet_publishable_detail, which is SECURITY DEFINER).
-- ============================================================================================
BEGIN;

CREATE TEMP TABLE _fin_before ON COMMIT DROP AS
  SELECT p.proname, p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS cfg, pg_get_functiondef(p.oid) AS def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'derm' AND p.proname IN ('_actor', '_require_stamp_key', 'fn_sheet_publishable_detail');

DO $pre$
BEGIN
  IF (SELECT count(*) FROM _fin_before) <> 3 THEN RAISE EXCEPTION 'PRE 0.1: expected the three helpers'; END IF;
  IF (SELECT def FROM _fin_before WHERE proname = '_actor') NOT LIKE '%nullif(current_setting(''request.jwt.claim.email'', true), ''''),%' THEN
    RAISE EXCEPTION 'PRE 0.2: derm._actor is not the body this file was patched from';
  END IF;
  IF (SELECT def FROM _fin_before WHERE proname = '_require_stamp_key') NOT LIKE '%RETURN;  -- direct SQL (not PostgREST): admin scripts stay allowed%' THEN
    RAISE EXCEPTION 'PRE 0.3: derm._require_stamp_key is not the body this file was patched from';
  END IF;
  IF (SELECT def FROM _fin_before WHERE proname = 'fn_sheet_publishable_detail') NOT LIKE '%''pages_needing_extent'', to_jsonb(a.pages_ext),%' THEN
    RAISE EXCEPTION 'PRE 0.4: derm.fn_sheet_publishable_detail is not the body this file was patched from';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'derm' AND p.proname = 'fn_match_generated_page') THEN
    RAISE EXCEPTION 'PRE 0.5: apply 2026-09-15_1000 first';
  END IF;
  IF NOT derm._is_rule_source('template-v1-2026-09-15') THEN RAISE EXCEPTION 'PRE 0.6: apply 2026-09-15_1100 first'; END IF;
END
$pre$;

-- --------------------------------------------------------------------------------------------
-- PART 1. The calibrated prior and the tolerances. COPIED FROM phase0_results.json; the VERIFY
-- checks them against the template they were calibrated from, and the real-page fixture proves
-- they measure a page a person accepted.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_generated_page_prior()
RETURNS numeric[]
LANGUAGE sql IMMUTABLE
AS $function$
  -- The six printed boundaries of the DERM_V4.00 form as our pdf-service prints them, measured as
  -- the mean over the Phase 0 corpus pages the matcher accepted (phase0_results.json,
  -- calibrated_prior). A PRIOR: it chooses which detected lines are the boundaries and is never
  -- written. The stamp-midpoint template (derm.fn_generated_template_boundaries) is 0.0 to 0.75pp
  -- from the printed lines; this is what the printed lines actually average to.
  SELECT ARRAY[25.840, 33.760, 41.100, 48.145, 55.925, 64.155]::numeric[];   -- REPLACE with calibrated_prior
$function$;

CREATE OR REPLACE FUNCTION derm.fn_generated_match_tolerances()
RETURNS jsonb
LANGUAGE sql IMMUTABLE
AS $function$
  -- phase0_results.json -> tolerances. search: window around each prior boundary when finding the
  -- page's shift; match: window around prior + shift when taking a boundary; gap: per-slot deviation
  -- from the printed gap; clear: a stamp's distance from both lines of its slot; min_run: shortest
  -- usable line as a fraction of the form width.
  SELECT jsonb_build_object('search', 2.5, 'match', 0.75, 'gap', 0.75, 'clear', 0.5, 'min_run', 0.35);   -- REPLACE match/gap/clear
$function$;

-- --------------------------------------------------------------------------------------------
-- PART 2. The ledger.
-- --------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS derm.generated_measure_attempts (
  dump_folder      text        NOT NULL,
  page             integer     NOT NULL,
  image_url        text,
  source_etag      text,
  attempts         integer     NOT NULL DEFAULT 0,
  first_attempt_at timestamptz NOT NULL DEFAULT now(),
  last_attempt_at  timestamptz NOT NULL DEFAULT now(),
  last_outcome     text,
  last_reason      text,
  last_detail      text,
  lines            jsonb,
  meta             jsonb,
  measured_at      timestamptz,
  CONSTRAINT generated_measure_attempts_pkey PRIMARY KEY (dump_folder, page),
  CONSTRAINT generated_measure_attempts_attempts_chk CHECK (attempts >= 0 AND attempts <= 100),
  CONSTRAINT generated_measure_attempts_outcome_chk
    CHECK (last_outcome IS NULL OR last_outcome IN ('requested', 'measured', 'refused', 'error'))
);
COMMENT ON TABLE derm.generated_measure_attempts IS
  'The generated-sheet finisher''s ledger, one row per (folder, image position). attempts counts '
  'hand-outs (recorded when the cron REQUESTS a measurement, so a worker that dies still consumes '
  'its budget); three per image, re-armed when the image or its etag changes or a card on the page '
  'is edited after the last attempt. last_reason is the plain sentence the Studio banner shows; '
  'last_detail and lines are the forensic record. Unaudited by design (rule 8 opt-out): machine '
  'bookkeeping, regenerable, deleting a row only re-arms a measurement.';
REVOKE ALL ON TABLE derm.generated_measure_attempts FROM PUBLIC;
REVOKE ALL ON TABLE derm.generated_measure_attempts FROM anon;
REVOKE ALL ON TABLE derm.generated_measure_attempts FROM authenticated;
GRANT SELECT, INSERT, UPDATE ON TABLE derm.generated_measure_attempts TO service_role;

CREATE OR REPLACE FUNCTION derm._gm_record(
  p_dump_folder text, p_page integer, p_image_url text, p_outcome text,
  p_reason text, p_detail text, p_lines jsonb, p_meta jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_attempts int; v_reason text := p_reason;
BEGIN
  INSERT INTO derm.generated_measure_attempts
    (dump_folder, page, image_url, source_etag, attempts, last_outcome, last_reason, last_detail, lines, meta, measured_at)
  VALUES
    (p_dump_folder, p_page, p_image_url, derm._img_etag(p_image_url), 1, p_outcome, p_reason,
     left(p_detail, 4000), p_lines, p_meta, CASE WHEN p_outcome = 'measured' THEN now() END)
  ON CONFLICT (dump_folder, page) DO UPDATE
     SET image_url = EXCLUDED.image_url, source_etag = EXCLUDED.source_etag,
         last_outcome = EXCLUDED.last_outcome, last_reason = EXCLUDED.last_reason,
         last_detail = EXCLUDED.last_detail, lines = EXCLUDED.lines, meta = EXCLUDED.meta,
         last_attempt_at = now(),
         measured_at = coalesce(EXCLUDED.measured_at, derm.generated_measure_attempts.measured_at)
  RETURNING attempts INTO v_attempts;
  -- the third failed read is the last one the cron will request: say so, in words
  IF p_outcome = 'error' AND v_attempts >= 3 THEN
    v_reason := 'The scan could not be read after three tries. Measure this page with Draw the bands.';
    UPDATE derm.generated_measure_attempts SET last_reason = v_reason
     WHERE dump_folder = p_dump_folder AND page = p_page;
  END IF;
  RETURN jsonb_build_object('outcome', p_outcome, 'reason', v_reason, 'detail', p_detail, 'attempts', v_attempts);
END $function$;
REVOKE ALL ON FUNCTION derm._gm_record(text, integer, text, text, text, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm._gm_record(text, integer, text, text, text, text, jsonb, jsonb) TO service_role;

-- --------------------------------------------------------------------------------------------
-- PART 3. "service_role is a machine": one arm in each helper. The two bodies below are spliced in
-- by scripts/probes/generated_finisher/assemble_finisher_migration.py from the LIVE
-- pg_get_functiondef output, each anchor asserted to occur exactly once (the Studio write key in
-- _require_stamp_key is not retyped here on purpose).
-- --------------------------------------------------------------------------------------------
@@ACTOR_BODY@@

@@STAMP_KEY_BODY@@

-- --------------------------------------------------------------------------------------------
-- PART 4. Completion: the pre-checks a machine applies beyond the human path, then the resolver's
-- own write, keyed on the folder.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_generated_completion_blocker(p_dump_folder text)
RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_ticket text; v_status record; v_cfg text;
BEGIN
  SELECT r.white_manifest_number INTO v_ticket FROM derm.address_row_map r
   WHERE r.dump_folder = p_dump_folder AND r.white_manifest_number IS NOT NULL LIMIT 1;
  IF v_ticket IS NULL OR NOT coalesce(derm.fn_sheet_is_generated(v_ticket), false) THEN
    RETURN 'This sheet was not printed by us, so it is not completed automatically.';
  END IF;
  SELECT * INTO v_status FROM derm.stamp_sheet_status WHERE dump_folder = p_dump_folder;
  IF FOUND AND v_status.completed THEN
    RETURN 'This sheet is already marked complete.';
  END IF;
  IF FOUND AND v_status.reopened_at IS NOT NULL THEN
    RETURN 'This sheet was reopened for a person to look at, so it is not completed automatically.';
  END IF;
  SELECT lower(btrim(value)) INTO v_cfg FROM public.app_config WHERE key = 'generated_sheet_auto_complete';
  IF v_cfg = 'false' THEN
    RETURN 'Automatic completion is switched off.';
  END IF;
  IF EXISTS (SELECT 1 FROM derm.address_row_map r WHERE r.dump_folder = p_dump_folder AND r.stamp_placed_at IS NULL) THEN
    RETURN 'A card on this sheet has no stamp yet.';
  END IF;
  IF EXISTS (SELECT 1 FROM derm.address_row_map r
              WHERE r.dump_folder = p_dump_folder AND r.stamp_placed_at IS NOT NULL
                AND (r.stamp_page IS NULL OR r.stamp_page < 1
                     OR r.stamp_page > coalesce(array_length(derm.ticket_page_images(r.white_manifest_number), 1), 0))) THEN
    RETURN 'A stamp on this sheet is on a page that no longer exists.';
  END IF;
  -- one card per printed row, per client, or a neighbour's row could be published as this client's
  IF EXISTS (
    SELECT 1
      FROM (SELECT r.matched_client_id AS client_id, count(*) AS cards
              FROM derm.address_row_map r WHERE r.dump_folder = p_dump_folder GROUP BY 1) c
      LEFT JOIN (SELECT sc.client_id, sum(sc.rows_printed) AS rows_printed
                   FROM derm.address_sheet_manifests l
                   JOIN public.derm_manifests m ON m.id = l.manifest_id AND m.deleted_at IS NULL
                   JOIN derm.address_sheets s ON s.id = l.sheet_id AND s.deleted_at IS NULL
                   JOIN derm.address_sheet_clients sc ON sc.sheet_id = l.sheet_id AND sc.slot = l.slot
                  WHERE coalesce(m.white_manifest_number, m.yellow_ticket_number) = v_ticket
                  GROUP BY 1) p ON p.client_id = c.client_id
     WHERE p.rows_printed IS NULL) THEN
    RETURN 'A client on this sheet is not on the printed list of this sheet. A person needs to check it.';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM (SELECT r.matched_client_id AS client_id, count(*) AS cards
              FROM derm.address_row_map r WHERE r.dump_folder = p_dump_folder GROUP BY 1) c
      JOIN (SELECT sc.client_id, sum(sc.rows_printed) AS rows_printed
              FROM derm.address_sheet_manifests l
              JOIN public.derm_manifests m ON m.id = l.manifest_id AND m.deleted_at IS NULL
              JOIN derm.address_sheets s ON s.id = l.sheet_id AND s.deleted_at IS NULL
              JOIN derm.address_sheet_clients sc ON sc.sheet_id = l.sheet_id AND sc.slot = l.slot
             WHERE coalesce(m.white_manifest_number, m.yellow_ticket_number) = v_ticket
             GROUP BY 1) p ON p.client_id = c.client_id
     WHERE p.rows_printed <> c.cards) THEN
    RETURN 'A client on this sheet does not have one card per printed row. Give it one card per permit first.';
  END IF;
  RETURN NULL;
END $function$;
REVOKE ALL ON FUNCTION derm.fn_generated_completion_blocker(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_generated_completion_blocker(text) TO service_role;

CREATE OR REPLACE FUNCTION derm.fn_complete_generated_sheet(p_dump_folder text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $function$
DECLARE v_block text; v_pub text; v_done boolean;
BEGIN
  v_block := derm.fn_generated_completion_blocker(p_dump_folder);
  IF v_block = 'This sheet is already marked complete.' THEN
    RETURN jsonb_build_object('completed', true, 'reason', v_block);
  END IF;
  IF v_block IS NOT NULL THEN
    RETURN jsonb_build_object('completed', false, 'reason', v_block);
  END IF;
  -- the same gate trg_a0_completion_requires_geometry applies, checked here first so a refused
  -- attempt writes no status row and no audit row every ten minutes
  v_pub := derm.fn_sheet_publishable(p_dump_folder);
  IF v_pub IS NOT NULL THEN
    RETURN jsonb_build_object('completed', false,
      'reason', coalesce(derm.fn_sheet_publishable_detail(p_dump_folder)->>'message', derm.fn_publishable_hint(v_pub)),
      'blocker', v_pub);
  END IF;
  -- the resolver's own write (fn_resolve_generated_sheet_for_ticket, auto-complete leg), by folder
  INSERT INTO derm.stamp_sheet_status (dump_folder, completed, completed_at, completed_by, updated_at)
  VALUES (p_dump_folder, true, now(), 'stamp-studio-ai', now())
  ON CONFLICT (dump_folder) DO UPDATE
     SET completed    = true,
         completed_at = coalesce(derm.stamp_sheet_status.completed_at, now()),
         completed_by = coalesce(derm.stamp_sheet_status.completed_by, 'stamp-studio-ai'),
         updated_at   = now()
   WHERE NOT derm.stamp_sheet_status.completed
     AND derm.stamp_sheet_status.reopened_at IS NULL;
  SELECT completed INTO v_done FROM derm.stamp_sheet_status WHERE dump_folder = p_dump_folder;
  RETURN jsonb_build_object('completed', coalesce(v_done, false),
    'reason', CASE WHEN coalesce(v_done, false)
                   THEN 'Marked complete. The blacked-out copy follows on the next sweep.'
                   ELSE 'The completion was refused at the last moment; the sheet stays open.' END);
END $function$;
REVOKE ALL ON FUNCTION derm.fn_complete_generated_sheet(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_complete_generated_sheet(text) TO service_role;

-- --------------------------------------------------------------------------------------------
-- PART 5. The backlog: which (folder, image position) the finisher may measure, and which folders
-- it may complete. Derived predicates, no state to drift.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW derm.v_generated_measure_backlog AS
WITH gen AS (
  SELECT r.dump_folder, max(r.white_manifest_number) AS ticket
    FROM derm.address_row_map r
   WHERE r.white_manifest_number IS NOT NULL AND r.dump_folder LIKE 'ticket-%'
   GROUP BY r.dump_folder
), open_folders AS (
  SELECT g.dump_folder, g.ticket
    FROM gen g
    LEFT JOIN derm.stamp_sheet_status s ON s.dump_folder = g.dump_folder
   WHERE coalesce(s.completed, false) = false
     AND s.reopened_at IS NULL
     AND coalesce(derm.fn_sheet_is_generated(g.ticket), false)
), pages AS (
  SELECT o.dump_folder, o.ticket, coalesce(r.stamp_page, r.page) AS page,
         count(*) AS stamped_cards,
         count(*) FILTER (WHERE r.band_y0_pct IS NOT NULL AND r.band_y1_pct IS NOT NULL) AS banded_cards,
         max(r.updated_at) AS cards_updated_at
    FROM open_folders o
    JOIN derm.address_row_map r ON r.dump_folder = o.dump_folder
   WHERE r.stamp_y_pct IS NOT NULL AND r.stamp_placed_at IS NOT NULL
   GROUP BY 1, 2, 3
), img AS (
  SELECT p.*, (derm.ticket_page_images(p.ticket))[p.page] AS image_url FROM pages p
)
SELECT i.dump_folder, i.ticket, i.page, i.image_url,
       derm._img_etag(i.image_url) AS source_etag,
       i.stamped_cards, i.banded_cards, i.cards_updated_at,
       EXISTS (SELECT 1 FROM derm.page_block_extents e
                WHERE e.dump_folder = i.dump_folder AND e.effective_page = i.page) AS has_extent,
       a.attempts, a.last_outcome, a.last_reason, a.last_attempt_at,
       -- the budget counts against THIS image and THIS card state: a replaced scan, a changed etag
       -- or a card edited after the last attempt re-arms it
       CASE WHEN a.dump_folder IS NULL THEN 0
            WHEN a.image_url IS DISTINCT FROM i.image_url THEN 0
            WHEN a.source_etag IS DISTINCT FROM derm._img_etag(i.image_url) THEN 0
            WHEN i.cards_updated_at > a.last_attempt_at THEN 0
            ELSE a.attempts END AS attempts_on_this_image
  FROM img i
  LEFT JOIN derm.generated_measure_attempts a ON a.dump_folder = i.dump_folder AND a.page = i.page
 WHERE (i.banded_cards < i.stamped_cards
        OR NOT EXISTS (SELECT 1 FROM derm.page_block_extents e
                        WHERE e.dump_folder = i.dump_folder AND e.effective_page = i.page))
   -- a person who has started marking lines on this page owns it
   AND NOT EXISTS (SELECT 1 FROM derm.page_rule_scans sc
                    WHERE sc.dump_folder = i.dump_folder AND sc.effective_page = i.page
                      AND sc.source LIKE 'human-v1-%');
COMMENT ON VIEW derm.v_generated_measure_backlog IS
  'Pages of open generated sheets the finisher may measure: stamped, missing a band or the extent, '
  'no human-marked lines. attempts_on_this_image is the budget consumed against the CURRENT scan '
  'and card state; fn_generated_measure_targets hands out pages below 3.';
REVOKE ALL ON derm.v_generated_measure_backlog FROM PUBLIC;
REVOKE ALL ON derm.v_generated_measure_backlog FROM anon;
REVOKE ALL ON derm.v_generated_measure_backlog FROM authenticated;
GRANT SELECT ON derm.v_generated_measure_backlog TO service_role;

CREATE OR REPLACE FUNCTION derm.fn_generated_measure_targets(p_limit integer DEFAULT 2)
RETURNS TABLE(dump_folder text, ticket text, page integer, image_url text, source_etag text, attempts_on_this_image integer)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path TO 'derm', 'public'
AS $function$
  SELECT b.dump_folder, b.ticket, b.page, b.image_url, b.source_etag, b.attempts_on_this_image
    FROM derm.v_generated_measure_backlog b
   WHERE b.image_url IS NOT NULL AND b.attempts_on_this_image < 3
   ORDER BY b.attempts_on_this_image, b.last_attempt_at NULLS FIRST, b.dump_folder, b.page
   LIMIT greatest(1, least(coalesce(p_limit, 2), 5));
$function$;
REVOKE ALL ON FUNCTION derm.fn_generated_measure_targets(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_generated_measure_targets(integer) TO service_role;

CREATE OR REPLACE VIEW derm.v_generated_complete_backlog AS
WITH gen AS (
  SELECT r.dump_folder, max(r.white_manifest_number) AS ticket
    FROM derm.address_row_map r
   WHERE r.white_manifest_number IS NOT NULL AND r.dump_folder LIKE 'ticket-%'
   GROUP BY r.dump_folder
)
SELECT g.dump_folder, g.ticket, derm.fn_generated_completion_blocker(g.dump_folder) AS blocker
  FROM gen g
  LEFT JOIN derm.stamp_sheet_status s ON s.dump_folder = g.dump_folder
 WHERE coalesce(s.completed, false) = false
   AND s.reopened_at IS NULL
   AND coalesce(derm.fn_sheet_is_generated(g.ticket), false)
   AND NOT EXISTS (SELECT 1 FROM derm.address_row_map r
                    WHERE r.dump_folder = g.dump_folder AND r.stamp_placed_at IS NULL);
COMMENT ON VIEW derm.v_generated_complete_backlog IS
  'Open generated sheets with every card placed. blocker NULL means fn_complete_generated_sheet '
  'will try (it still checks fn_sheet_publishable); otherwise the plain reason it will not.';
REVOKE ALL ON derm.v_generated_complete_backlog FROM PUBLIC;
REVOKE ALL ON derm.v_generated_complete_backlog FROM anon;
REVOKE ALL ON derm.v_generated_complete_backlog FROM authenticated;
GRANT SELECT ON derm.v_generated_complete_backlog TO service_role;

-- --------------------------------------------------------------------------------------------
-- PART 6. The writer.
-- --------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION derm.fn_generated_page_measured(
  p_dump_folder text, p_page integer, p_image_url text, p_lines jsonb, p_meta jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'derm', 'public', 'pg_temp'
AS $function$
DECLARE
  v_ticket text; v_live_url text; v_cards jsonb; v_stamps jsonb; v_m jsonb; v_tol jsonb;
  v_bounds numeric[]; v_runs numeric[]; v_rules jsonb; v_bands jsonb;
  v_rec jsonb; v_geo jsonb; v_done jsonb; v_reason text; v_source text;
  v_meta jsonb := coalesce(p_meta, '{}'::jsonb);
BEGIN
  IF p_dump_folder IS NULL OR p_page IS NULL OR p_image_url IS NULL THEN
    RAISE EXCEPTION 'dump_folder, page and image_url are required' USING ERRCODE = '22023';
  END IF;
  v_source := 'template-v1-' || to_char(now() AT TIME ZONE 'America/New_York', 'YYYY-MM-DD');

  -- 0. identity: a generated sheet, and the image at this position is the one that was measured
  SELECT r.white_manifest_number INTO v_ticket FROM derm.address_row_map r
   WHERE r.dump_folder = p_dump_folder AND r.white_manifest_number IS NOT NULL LIMIT 1;
  IF v_ticket IS NULL OR NOT coalesce(derm.fn_sheet_is_generated(v_ticket), false) THEN
    RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'refused',
      'This sheet was not printed by us, so it cannot be measured automatically. Measure it with Draw the bands.',
      'no generated-sheet link', p_lines, v_meta);
  END IF;
  v_live_url := (derm.ticket_page_images(v_ticket))[p_page];
  IF v_live_url IS DISTINCT FROM p_image_url THEN
    RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'error',
      'The scan for this page changed while it was being measured. It will be measured again.',
      format('measured %s, live position %s holds %s', p_image_url, p_page, coalesce(v_live_url, '(nothing)')),
      p_lines, v_meta);
  END IF;
  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN
    RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'error',
      'The scan could not be read this time. It will be tried again.',
      coalesce(v_meta->>'error', 'no lines'), p_lines, v_meta);
  END IF;

  -- 1. still in the backlog? (open folder, stamped page, unmeasured, no human-marked lines)
  IF NOT EXISTS (SELECT 1 FROM derm.v_generated_measure_backlog b
                  WHERE b.dump_folder = p_dump_folder AND b.page = p_page) THEN
    RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'refused',
      'This page no longer needs measuring automatically.',
      'not in v_generated_measure_backlog: completed, reopened, already measured, or a person is measuring it',
      p_lines, v_meta);
  END IF;

  -- 2. the cards, with their printed row (or the plain refusal)
  v_cards := derm.fn_generated_page_cards(p_dump_folder, p_page);
  IF v_cards->>'refusal' IS NOT NULL THEN
    RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'refused',
      v_cards->>'refusal', v_cards->>'detail', p_lines, v_meta);
  END IF;
  SELECT jsonb_agg(jsonb_build_object('row', c->'row', 'y', c->'y')) INTO v_stamps
    FROM jsonb_array_elements(v_cards->'cards') c;

  -- 3. the match
  v_tol := derm.fn_generated_match_tolerances();
  v_m := derm.fn_match_generated_page(p_lines, v_stamps, derm.fn_generated_page_prior(),
           (v_tol->>'search')::numeric, (v_tol->>'match')::numeric, (v_tol->>'gap')::numeric,
           (v_tol->>'clear')::numeric, (v_tol->>'min_run')::numeric);
  IF NOT coalesce((v_m->>'ok')::boolean, false) THEN
    RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'refused',
      v_m->>'reason', v_m->>'detail', p_lines, v_meta || jsonb_build_object('match', v_m));
  END IF;
  v_bounds := ARRAY(SELECT e::numeric FROM jsonb_array_elements_text(v_m->'boundaries') e);
  v_runs   := ARRAY(SELECT e::numeric FROM jsonb_array_elements_text(v_m->'runs') e);
  v_rules  := (SELECT jsonb_agg(jsonb_build_object('pct', v_bounds[i], 'run', v_runs[i], 'kind', 'boundary') ORDER BY i)
                 FROM generate_series(1, 6) i);
  v_bands  := (SELECT jsonb_agg(jsonb_build_object('row_id', (c->>'row_id')::bigint,
                                                    'y0', v_bounds[(c->>'row')::int],
                                                    'y1', v_bounds[(c->>'row')::int + 1]))
                 FROM jsonb_array_elements(v_cards->'cards') c);

  -- 4. both writes or neither, through the guarded RPCs, in one subtransaction
  BEGIN
    v_rec := derm.record_page_rules(p_dump_folder, p_page, v_source, p_image_url, v_rules,
               jsonb_build_object(
                 'grade', 'OK',
                 'detail', format('generated-sheet finisher: six printed boundaries matched to the printed layout (shift %spp, residuals %s, %s usable lines)',
                                  v_m->>'shift', v_m->'residuals', v_m->>'usable_lines'),
                 'image_w', v_meta->'image_w', 'image_h', v_meta->'image_h', 'skew', v_meta->'skew'));
    IF NOT coalesce((v_rec->>'wrote')::boolean, false) OR coalesce((v_rec->>'n_boundaries')::int, 0) <> 6 THEN
      RAISE EXCEPTION 'GM_RULES_REFUSED:%', coalesce(v_rec->>'hint', v_rec->>'detail', 'the printed lines were not accepted');
    END IF;
    v_geo := derm.save_page_geometry(p_dump_folder, p_page, v_bands, v_bounds[1], v_bounds[6]);
  EXCEPTION WHEN OTHERS THEN
    -- the subtransaction rolled both writes back. The words go to the person, the rest to the log.
    v_reason := CASE
      WHEN SQLERRM LIKE 'GM_RULES_REFUSED:%' THEN
        'The printed lines found on this scan were not accepted as a row layout. Measure this page with Draw the bands.'
      WHEN SQLERRM LIKE 'page geometry refused:%' THEN
        regexp_replace(regexp_replace(regexp_replace(SQLERRM, '^page geometry refused:\s*', ''),
                                      '\s*\[G[0-9A-Z_]+:[^]]*\]', '', 'g'),
                       '\s*\n\s*', ' ', 'g')
      ELSE 'This page could not be saved automatically. Measure it with Draw the bands.'
    END;
    RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'refused', v_reason, SQLERRM,
                           p_lines, v_meta || jsonb_build_object('match', v_m));
  END;

  -- 5. complete when every gate passes; a no-op with a reason otherwise
  v_done := derm.fn_complete_generated_sheet(p_dump_folder);
  RETURN derm._gm_record(p_dump_folder, p_page, p_image_url, 'measured', NULL,
           format('bands %s, extent %s to %s, shift %s, residuals %s, source %s',
                  v_geo->>'saved_bands', v_bounds[1], v_bounds[6], v_m->>'shift', v_m->'residuals', v_source),
           p_lines, v_meta || jsonb_build_object('match', v_m))
         || jsonb_build_object('geometry', v_geo, 'completion', v_done, 'source', v_source);
END $function$;
REVOKE ALL ON FUNCTION derm.fn_generated_page_measured(text, integer, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION derm.fn_generated_page_measured(text, integer, text, jsonb, jsonb) TO service_role;

-- --------------------------------------------------------------------------------------------
-- PART 7. The banner carries the finisher's reason. Body spliced from pg_get_functiondef by the
-- assembly script (a `fin` CTE and one prefix on the page-aware message; nothing else moves).
-- --------------------------------------------------------------------------------------------
@@PUBLISHABLE_DETAIL_BODY@@

-- --------------------------------------------------------------------------------------------
-- PART 8. The off switch (missing = on).
-- --------------------------------------------------------------------------------------------
INSERT INTO public.app_config (key, value)
SELECT 'generated_sheet_auto_complete', 'true'
 WHERE NOT EXISTS (SELECT 1 FROM public.app_config WHERE key = 'generated_sheet_auto_complete');

NOTIFY pgrst, 'reload schema';

-- --------------------------------------------------------------------------------------------
-- VERIFY. A real generated page, a person's accepted geometry as the truth, everything in one
-- savepoint that is rolled back. The pad lines are the refusal control.
-- --------------------------------------------------------------------------------------------
DO $verify$
DECLARE
  -- THE FIXTURE: a completed generated folder whose Phase 0 verdict is MATCH, with five single-row
  -- cards on the page. ticket-834742 page 2 (derm/1776/address_2.jpg) unless Phase 0 says otherwise.
  v_fx_folder text := 'ticket-834742';
  v_fx_ticket text := '834742';
  v_fx_page   int  := 2;
  v_fx_suffix text := '/derm/1776/address_2.jpg';
  v_lines jsonb := '@@LINES_834742_P2@@'::jsonb;    -- phase0_results.json -> lines["ticket-834742_p2"].lines
  v_pad   jsonb := '[{"pct":13.118,"run":0.719},{"pct":15.865,"run":0.981},{"pct":26.992,"run":0.359},{"pct":29.396,"run":0.980},{"pct":32.349,"run":0.368},{"pct":35.096,"run":0.981},{"pct":37.981,"run":0.359},{"pct":40.728,"run":0.982},{"pct":43.613,"run":0.366},{"pct":46.36,"run":0.982},{"pct":49.245,"run":0.359},{"pct":51.992,"run":0.983},{"pct":54.876,"run":0.363},{"pct":57.624,"run":0.984},{"pct":60.508,"run":0.361},{"pct":63.324,"run":0.984},{"pct":65.385,"run":0.984},{"pct":67.995,"run":0.983}]';
  v_tech  text := '(_|\[|\]|jsonb|numeric|null|G[0-9]+|template-v1|runlen|human-v1)';
  v_url text; v_j jsonb; v_n int; v_max numeric; v_r record;
  v_fx_bands jsonb; v_fx_top numeric; v_fx_bot numeric; v_msg text;
BEGIN
  -- 0. preconditions and the prior's shape
  IF array_length(derm.fn_generated_page_prior(), 1) <> 6 THEN RAISE EXCEPTION 'PRE: prior'; END IF;
  FOR v_n IN 1 .. 6 LOOP
    IF abs((derm.fn_generated_page_prior())[v_n] - (derm.fn_generated_template_boundaries())[v_n]) > 1.0 THEN
      RAISE EXCEPTION 'PRE: prior boundary % is more than 1pp from the template; the pasted numbers are wrong', v_n;
    END IF;
  END LOOP;
  IF (derm.fn_generated_match_tolerances()->>'match')::numeric NOT BETWEEN 0.5 AND 1.0
     OR (derm.fn_generated_match_tolerances()->>'gap')::numeric NOT BETWEEN 0.5 AND 1.0 THEN
    RAISE EXCEPTION 'PRE: tolerances outside the range Phase 0 allows';
  END IF;
  IF jsonb_typeof(v_lines) <> 'array' OR jsonb_array_length(v_lines) < 6 THEN RAISE EXCEPTION 'PRE: the fixture lines were not spliced in'; END IF;
  IF NOT EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = v_fx_folder AND completed) THEN
    RAISE EXCEPTION 'PRE: % is not a completed folder; pick another MATCH page from Phase 0', v_fx_folder;
  END IF;
  v_url := (derm.ticket_page_images(v_fx_ticket))[v_fx_page];
  IF v_url NOT LIKE '%' || v_fx_suffix THEN RAISE EXCEPTION 'PRE: image % is %, not %', v_fx_page, v_url, v_fx_suffix; END IF;
  IF EXISTS (SELECT 1 FROM derm.v_generated_measure_backlog WHERE dump_folder = v_fx_folder) THEN
    RAISE EXCEPTION 'PRE: % is already in the backlog', v_fx_folder;
  END IF;
  IF (SELECT value FROM public.app_config WHERE key = 'generated_sheet_auto_complete') <> 'true' THEN RAISE EXCEPTION 'PRE: config'; END IF;

  -- =========================== fixture A: the happy path and the refusal control ===========================
  BEGIN
    SELECT jsonb_object_agg(id, jsonb_build_object('y0', band_y0_pct, 'y1', band_y1_pct)) INTO v_fx_bands
      FROM derm.address_row_map WHERE dump_folder = v_fx_folder AND coalesce(stamp_page, page) = v_fx_page;
    SELECT top_pct, bottom_pct INTO v_fx_top, v_fx_bot FROM derm.page_block_extents WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page;
    IF v_fx_top IS NULL OR (SELECT count(*) FROM jsonb_object_keys(v_fx_bands)) < 3 THEN RAISE EXCEPTION 'SETUP: fixture has no accepted geometry'; END IF;
    -- un-complete without leaving the reopen pin (the pin trigger sets reopened_at on the flip)
    UPDATE derm.stamp_sheet_status SET completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = v_fx_folder;
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL WHERE dump_folder = v_fx_folder;
    -- strip the page's geometry and the person's lines
    UPDATE derm.address_row_map SET band_y0_pct = NULL, band_y1_pct = NULL, band_source = NULL, band_set_at = NULL, band_set_by = NULL
     WHERE dump_folder = v_fx_folder AND coalesce(stamp_page, page) = v_fx_page;
    DELETE FROM derm.page_block_extents WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page;
    DELETE FROM derm.page_row_rules  WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'human-v1-%';
    DELETE FROM derm.page_rule_scans WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'human-v1-%';

    -- 1. the backlog names exactly this page; completion says why it cannot yet
    IF (SELECT count(*) FROM derm.v_generated_measure_backlog WHERE dump_folder = v_fx_folder) <> 1
       OR NOT EXISTS (SELECT 1 FROM derm.v_generated_measure_backlog WHERE dump_folder = v_fx_folder AND page = v_fx_page AND image_url = v_url AND attempts_on_this_image = 0) THEN
      RAISE EXCEPTION 'VERIFY 1 FAILED: backlog';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM derm.fn_generated_measure_targets(5) t WHERE t.dump_folder = v_fx_folder AND t.page = v_fx_page) THEN RAISE EXCEPTION 'VERIFY 1a FAILED: targets'; END IF;
    v_j := derm.fn_complete_generated_sheet(v_fx_folder);
    IF (v_j->>'completed')::boolean OR v_j->>'blocker' IS NULL THEN RAISE EXCEPTION 'VERIFY 1b FAILED: %', v_j; END IF;

    -- 2. the refusal control: pad lines. Nothing is written; the ledger and the banner carry the reason.
    v_j := derm.fn_generated_page_measured(v_fx_folder, v_fx_page, v_url, v_pad, '{"image_w":980,"image_h":728,"skew":0}'::jsonb);
    IF v_j->>'outcome' <> 'refused' OR v_j->>'reason' ~ v_tech THEN RAISE EXCEPTION 'VERIFY 2 FAILED: %', v_j; END IF;
    IF EXISTS (SELECT 1 FROM derm.address_row_map WHERE dump_folder = v_fx_folder AND coalesce(stamp_page, page) = v_fx_page AND band_y0_pct IS NOT NULL)
       OR EXISTS (SELECT 1 FROM derm.page_block_extents WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page)
       OR EXISTS (SELECT 1 FROM derm.page_rule_scans WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'template-v1-%')
       OR EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = v_fx_folder AND completed) THEN
      RAISE EXCEPTION 'VERIFY 2a FAILED: a refusal wrote something';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM derm.generated_measure_attempts WHERE dump_folder = v_fx_folder AND page = v_fx_page AND last_outcome = 'refused' AND last_reason !~ v_tech AND lines = v_pad) THEN
      RAISE EXCEPTION 'VERIFY 2b FAILED: ledger';
    END IF;
    v_msg := derm.fn_sheet_publishable_detail(v_fx_folder)->>'message';
    IF v_msg NOT LIKE 'Page ' || v_fx_page || ' could not be measured automatically: %' OR v_msg ~ v_tech THEN
      RAISE EXCEPTION 'VERIFY 2c FAILED: banner reads "%"', v_msg;
    END IF;

    -- 3. a wrong image url is an error, and writes nothing
    v_j := derm.fn_generated_page_measured(v_fx_folder, v_fx_page, 'https://example.invalid/x.jpg', v_lines, '{}'::jsonb);
    IF v_j->>'outcome' <> 'error' THEN RAISE EXCEPTION 'VERIFY 3 FAILED: %', v_j; END IF;
    IF EXISTS (SELECT 1 FROM derm.page_rule_scans WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'template-v1-%') THEN RAISE EXCEPTION 'VERIFY 3a FAILED'; END IF;

    -- 4. the real lines: measured, the person's geometry reproduced, completed by the machine
    v_j := derm.fn_generated_page_measured(v_fx_folder, v_fx_page, v_url, v_lines, '{"image_w":1492,"image_h":1156,"skew":0}'::jsonb);
    IF v_j->>'outcome' <> 'measured' THEN RAISE EXCEPTION 'VERIFY 4 FAILED: %', v_j; END IF;
    SELECT max(greatest(abs(r.band_y0_pct - (v_fx_bands->(r.id::text)->>'y0')::numeric),
                        abs(r.band_y1_pct - (v_fx_bands->(r.id::text)->>'y1')::numeric))) INTO v_max
      FROM derm.address_row_map r WHERE r.dump_folder = v_fx_folder AND coalesce(r.stamp_page, r.page) = v_fx_page;
    IF v_max IS NULL OR v_max > 0.35 THEN RAISE EXCEPTION 'VERIFY 4b FAILED: bands sit %pp from the accepted ones', v_max; END IF;
    IF NOT EXISTS (SELECT 1 FROM derm.page_block_extents e WHERE e.dump_folder = v_fx_folder AND e.effective_page = v_fx_page
                     AND abs(e.top_pct - v_fx_top) <= 0.35 AND abs(e.bottom_pct - v_fx_bot) <= 0.35) THEN
      RAISE EXCEPTION 'VERIFY 4c FAILED: extent';
    END IF;
    -- 4d. NO TEMPLATE VALUE: every band edge and both extents are a detected line on this scan
    IF EXISTS (SELECT 1 FROM derm.address_row_map r
                WHERE r.dump_folder = v_fx_folder AND coalesce(r.stamp_page, r.page) = v_fx_page
                  AND (NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_lines) l WHERE (l->>'pct')::numeric = r.band_y0_pct)
                    OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_lines) l WHERE (l->>'pct')::numeric = r.band_y1_pct)))
       OR NOT EXISTS (SELECT 1 FROM derm.page_block_extents e WHERE e.dump_folder = v_fx_folder AND e.effective_page = v_fx_page
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_lines) l WHERE (l->>'pct')::numeric = e.top_pct)
                        AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_lines) l WHERE (l->>'pct')::numeric = e.bottom_pct)) THEN
      RAISE EXCEPTION 'VERIFY 4d FAILED: a written value is not a detected line';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = v_fx_folder AND completed AND completed_by = 'stamp-studio-ai') THEN
      RAISE EXCEPTION 'VERIFY 4e FAILED: not completed by the machine: %', v_j;
    END IF;
    IF (SELECT count(DISTINCT source) FROM derm.v_page_printed_rules WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page) <> 1
       OR NOT EXISTS (SELECT 1 FROM derm.v_page_printed_rules WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'template-v1-%') THEN
      RAISE EXCEPTION 'VERIFY 4f FAILED: the template scan is not the admitted source';
    END IF;
    IF EXISTS (SELECT 1 FROM derm.v_generated_measure_backlog WHERE dump_folder = v_fx_folder) THEN RAISE EXCEPTION 'VERIFY 4g FAILED: still in the backlog'; END IF;
    IF NOT EXISTS (SELECT 1 FROM derm.generated_measure_attempts WHERE dump_folder = v_fx_folder AND page = v_fx_page AND last_outcome = 'measured' AND measured_at IS NOT NULL) THEN RAISE EXCEPTION 'VERIFY 4h FAILED: ledger'; END IF;
    IF derm.fn_sheet_publishable(v_fx_folder) IS NOT NULL THEN RAISE EXCEPTION 'VERIFY 4i FAILED: not publishable after the measure'; END IF;
    -- the grader sees the page as any other: no band edge off a printed rule
    IF EXISTS (SELECT 1 FROM derm.v_band_edge_check WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND edge_verdict = 'OFF_RULE') THEN RAISE EXCEPTION 'VERIFY 4j FAILED: off-rule band'; END IF;

    -- 5. a second call is refused as no longer needed and changes nothing
    v_j := derm.fn_generated_page_measured(v_fx_folder, v_fx_page, v_url, v_lines, '{}'::jsonb);
    IF v_j->>'outcome' <> 'refused' OR v_j->>'reason' <> 'This page no longer needs measuring automatically.' THEN RAISE EXCEPTION 'VERIFY 5 FAILED: %', v_j; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- =========================== fixture B: the off switch measures but does not complete ===========================
  BEGIN
    UPDATE derm.stamp_sheet_status SET completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = v_fx_folder;
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL WHERE dump_folder = v_fx_folder;
    UPDATE derm.address_row_map SET band_y0_pct = NULL, band_y1_pct = NULL, band_source = NULL, band_set_at = NULL, band_set_by = NULL
     WHERE dump_folder = v_fx_folder AND coalesce(stamp_page, page) = v_fx_page;
    DELETE FROM derm.page_block_extents WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page;
    DELETE FROM derm.page_row_rules  WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'human-v1-%';
    DELETE FROM derm.page_rule_scans WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'human-v1-%';
    UPDATE public.app_config SET value = 'false' WHERE key = 'generated_sheet_auto_complete';
    v_j := derm.fn_generated_page_measured(v_fx_folder, v_fx_page, v_url, v_lines, '{}'::jsonb);
    IF v_j->>'outcome' <> 'measured' OR (v_j->'completion'->>'completed')::boolean
       OR v_j->'completion'->>'reason' <> 'Automatic completion is switched off.' THEN
      RAISE EXCEPTION 'VERIFY 6 FAILED: %', v_j;
    END IF;
    IF EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = v_fx_folder AND completed) THEN RAISE EXCEPTION 'VERIFY 6a FAILED: completed with the switch off'; END IF;
    -- geometry was still banked, so a person's Mark completed would work
    IF derm.fn_sheet_publishable(v_fx_folder) IS NOT NULL THEN RAISE EXCEPTION 'VERIFY 6b FAILED: geometry not banked'; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- =========================== fixture C: the reopen pin and the under-carded client ===========================
  BEGIN
    UPDATE derm.stamp_sheet_status SET completed = false WHERE dump_folder = v_fx_folder;   -- pin sets reopened_at
    v_j := derm.fn_complete_generated_sheet(v_fx_folder);
    IF (v_j->>'completed')::boolean OR v_j->>'reason' NOT LIKE 'This sheet was reopened%' THEN RAISE EXCEPTION 'VERIFY 7 FAILED: %', v_j; END IF;
    IF EXISTS (SELECT 1 FROM derm.v_generated_measure_backlog WHERE dump_folder = v_fx_folder) THEN RAISE EXCEPTION 'VERIFY 7a FAILED: a reopened folder is in the measure backlog'; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;
  BEGIN
    -- ticket-833395: 242-WYN printed on 3 rows, 1 card (the known un-split folder)
    UPDATE derm.stamp_sheet_status SET completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = 'ticket-833395';
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL WHERE dump_folder = 'ticket-833395';
    v_j := derm.fn_complete_generated_sheet('ticket-833395');
    IF (v_j->>'completed')::boolean OR v_j->>'reason' NOT LIKE 'A client on this sheet%' OR v_j->>'reason' ~ v_tech THEN RAISE EXCEPTION 'VERIFY 8 FAILED: %', v_j; END IF;
    IF (SELECT blocker FROM derm.v_generated_complete_backlog WHERE dump_folder = 'ticket-833395') IS NULL THEN RAISE EXCEPTION 'VERIFY 8a FAILED: complete backlog shows no blocker'; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- =========================== fixture D: the budget and its re-arming ===========================
  BEGIN
    UPDATE derm.stamp_sheet_status SET completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = v_fx_folder;
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL WHERE dump_folder = v_fx_folder;
    DELETE FROM derm.page_block_extents WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page;
    DELETE FROM derm.page_rule_scans WHERE dump_folder = v_fx_folder AND effective_page = v_fx_page AND source LIKE 'human-v1-%';
    INSERT INTO derm.generated_measure_attempts (dump_folder, page, image_url, source_etag, attempts, last_outcome, last_attempt_at)
    VALUES (v_fx_folder, v_fx_page, v_url, derm._img_etag(v_url), 3, 'refused', now());
    IF EXISTS (SELECT 1 FROM derm.fn_generated_measure_targets(5) t WHERE t.dump_folder = v_fx_folder) THEN RAISE EXCEPTION 'VERIFY 9 FAILED: a page at 3 attempts was handed out'; END IF;
    IF NOT EXISTS (SELECT 1 FROM derm.v_generated_measure_backlog WHERE dump_folder = v_fx_folder AND attempts_on_this_image = 3) THEN RAISE EXCEPTION 'VERIFY 9a FAILED: the backlog hides a budgeted page'; END IF;
    UPDATE derm.generated_measure_attempts SET source_etag = 'replaced' WHERE dump_folder = v_fx_folder AND page = v_fx_page;
    IF NOT EXISTS (SELECT 1 FROM derm.fn_generated_measure_targets(5) t WHERE t.dump_folder = v_fx_folder) THEN RAISE EXCEPTION 'VERIFY 9b FAILED: a replaced scan did not re-arm'; END IF;
    UPDATE derm.generated_measure_attempts SET source_etag = derm._img_etag(v_url), last_attempt_at = '2020-01-01' WHERE dump_folder = v_fx_folder AND page = v_fx_page;
    IF NOT EXISTS (SELECT 1 FROM derm.fn_generated_measure_targets(5) t WHERE t.dump_folder = v_fx_folder) THEN RAISE EXCEPTION 'VERIFY 9c FAILED: a card edited after the last attempt did not re-arm'; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- =========================== fixture E: "service_role is a machine" ===========================
  BEGIN
    PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
    PERFORM set_config('request.headers', '{"x-nothing":"1"}', true);
    IF derm._actor('stamp-studio') <> 'stamp-studio-ai' THEN RAISE EXCEPTION 'VERIFY 10 FAILED: service_role actor is %', derm._actor('stamp-studio'); END IF;
    PERFORM derm._require_stamp_key();   -- must not raise
    PERFORM set_config('request.jwt.claims', '{"role":"authenticated","email":"person@ayache.com"}', true);
    IF derm._actor('stamp-studio') <> 'person@ayache.com' THEN RAISE EXCEPTION 'VERIFY 10a FAILED: a person''s email did not win'; END IF;
    BEGIN
      PERFORM derm._require_stamp_key();
      RAISE EXCEPTION 'VERIFY 10b FAILED: an authenticated caller without the key was let through';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE 'VERIFY%' THEN RAISE; END IF;
    END;
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.headers', '', true);
    IF derm._actor('stamp-studio') <> 'stamp-studio' THEN RAISE EXCEPTION 'VERIFY 10c FAILED: direct SQL default'; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);

  -- =========================== after the rollbacks ===========================
  IF NOT EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = v_fx_folder AND completed)
     OR NOT EXISTS (SELECT 1 FROM derm.stamp_sheet_status WHERE dump_folder = 'ticket-833395' AND completed)
     OR EXISTS (SELECT 1 FROM derm.generated_measure_attempts)
     OR EXISTS (SELECT 1 FROM derm.page_rule_scans WHERE source LIKE 'template-v1-%')
     OR (SELECT value FROM public.app_config WHERE key = 'generated_sheet_auto_complete') <> 'true' THEN
    RAISE EXCEPTION 'CLEANUP FAILED: a fixture survived its rollback';
  END IF;
  -- grants, SECDEF and search_path of the three patched helpers unchanged
  FOR v_r IN SELECT p.proname, p.proacl::text AS acl, p.prosecdef, p.proconfig::text AS cfg
               FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'derm' AND p.proname IN ('_actor', '_require_stamp_key', 'fn_sheet_publishable_detail')
  LOOP
    IF v_r.acl IS DISTINCT FROM (SELECT acl FROM _fin_before b WHERE b.proname = v_r.proname)
       OR v_r.prosecdef IS DISTINCT FROM (SELECT prosecdef FROM _fin_before b WHERE b.proname = v_r.proname)
       OR v_r.cfg IS DISTINCT FROM (SELECT cfg FROM _fin_before b WHERE b.proname = v_r.proname) THEN
      RAISE EXCEPTION 'VERIFY 11 FAILED: % acl/secdef/search_path moved', v_r.proname;
    END IF;
  END LOOP;
  IF has_function_privilege('authenticated', 'derm.fn_generated_page_measured(text, integer, text, jsonb, jsonb)', 'EXECUTE')
     OR has_table_privilege('authenticated', 'derm.generated_measure_attempts', 'SELECT')
     OR has_table_privilege('authenticated', 'derm.v_generated_measure_backlog', 'SELECT')
     OR NOT has_function_privilege('service_role', 'derm.fn_generated_page_measured(text, integer, text, jsonb, jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'VERIFY 12 FAILED: grants';
  END IF;
  -- the live backlog today: nothing to measure unless a generated sheet is open right now
  SELECT count(*) INTO v_n FROM derm.v_generated_measure_backlog;
  RAISE NOTICE 'ALL VERIFY PASSED: a real page measured from its own lines within 0.35pp of the accepted geometry and completed by the machine; a pad refused with nothing written; the off switch, the reopen pin, the under-carded gate, the budget and its re-arming, and the service_role arms all proven; live measure backlog % page(s).', v_n;
END
$verify$;

COMMIT;
```

- [ ] **Step 2: Write the assembly script and run it**

`scripts/probes/generated_finisher/assemble_finisher_migration.py`:

```python
# Assembles docs/migrations/2026-09-15_1200_generated_sheet_finisher.sql: replaces its three body
# markers with the LIVE pg_get_functiondef output patched by anchored replacement (each anchor
# asserted to occur exactly once), and its fixture marker with the Phase 0 detector lines.
# USE: python scripts/probes/generated_finisher/assemble_finisher_migration.py [fixture-key]
#      fixture-key defaults to ticket-834742_p2 (a key of phase0_results.json -> lines)
import json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.abspath(os.path.join(here, '..', '..', '..'))
mig = os.path.join(root, 'docs', 'migrations', '2026-09-15_1200_generated_sheet_finisher.sql')
fixture = sys.argv[1] if len(sys.argv) > 1 else 'ticket-834742_p2'

defs = {r['k']: r['def'] for r in json.load(open(os.path.join(here, 'finisher_defs.out.json'), encoding='utf-8'))}
lines = json.load(open(os.path.join(here, 'phase0_results.json'), encoding='utf-8'))['lines'][fixture]['lines']
if len(lines) < 6: sys.exit(f'{fixture}: only {len(lines)} lines')

def patch(body, pairs, name):
    for old, new in pairs:
        n = body.count(old)
        if n != 1: sys.exit(f'{name}: anchor occurs {n} times, expected 1:\n{old}')
        body = body.replace(old, new)
    return body.rstrip() + ';'

actor = patch(defs['_actor'], [
    ("DECLARE\n  v_email text;\nBEGIN\n  BEGIN\n    v_email := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email';\n  EXCEPTION WHEN others THEN\n    v_email := NULL;\n  END;\n",
     "DECLARE\n  v_email text;\n  v_role  text;\nBEGIN\n  BEGIN\n    v_email := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email';\n    v_role  := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role';\n  EXCEPTION WHEN others THEN\n    v_email := NULL;\n    v_role  := NULL;\n  END;\n"
     "  -- 2026-09-15: a service_role caller with no email is a machine (the generated-sheet finisher\n"
     "  -- writes bands and extents through save_page_geometry as service_role). Fred, 2026-09-14:\n"
     "  -- everything machine-made carries the one label. A person's JWT still wins below, and direct\n"
     "  -- SQL (no JWT at all) still gets p_default.\n"
     "  IF v_role = 'service_role' AND nullif(v_email, '') IS NULL THEN\n    RETURN 'stamp-studio-ai';\n  END IF;\n"),
], '_actor')

key = patch(defs['_require_stamp_key'], [
    ("DECLARE v_headers text; v_key text;", "DECLARE v_headers text; v_key text; v_role text;"),
    ("  v_key := v_headers::jsonb->>'x-stamp-key';",
     "  -- 2026-09-15: a service_role request (the generated-sheet finisher: edge fn -> PostgREST) is\n"
     "  -- let through. That key already writes every table directly; the Studio's header key was\n"
     "  -- never a barrier to it, only to a browser holding the anon or a user key.\n"
     "  BEGIN\n    v_role := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role';\n"
     "  EXCEPTION WHEN others THEN\n    v_role := NULL;\n  END;\n"
     "  IF v_role = 'service_role' THEN\n    RETURN;\n  END IF;\n"
     "  v_key := v_headers::jsonb->>'x-stamp-key';"),
], '_require_stamp_key')

detail = patch(defs['fn_sheet_publishable_detail'], [
    ("  ), agg AS (\n    SELECT (SELECT blocker FROM code) AS blocker,\n",
     "  ), fin AS (\n"
     "    -- 2026-09-15: the generated-sheet finisher's latest reason for a page still needing geometry,\n"
     "    -- so the banner says WHY the sheet was not measured automatically (plain words, from the\n"
     "    -- ledger derm.generated_measure_attempts).\n"
     "    SELECT string_agg('Page ' || a.page || ' could not be measured automatically: ' || a.last_reason,\n"
     "                      ' ' ORDER BY a.page) AS reasons\n"
     "      FROM derm.generated_measure_attempts a\n"
     "     WHERE a.dump_folder = p_dump_folder\n"
     "       AND a.last_outcome IN ('refused', 'error')\n"
     "       AND a.last_reason IS NOT NULL\n"
     "       AND a.page IN (SELECT pg FROM need_band UNION SELECT pg FROM need_ext)\n"
     "  ), agg AS (\n    SELECT (SELECT blocker FROM code) AS blocker,\n"
     "           (SELECT reasons FROM fin) AS finisher_reasons,\n"),
    ("    'pages_needing_extent', to_jsonb(a.pages_ext),\n",
     "    'pages_needing_extent', to_jsonb(a.pages_ext),\n    'finisher_reasons', a.finisher_reasons,\n"),
    ("          THEN 'Page ' ||\n               array_to_string(",
     "          THEN coalesce(a.finisher_reasons || ' ', '') || 'Page ' ||\n               array_to_string("),
], 'fn_sheet_publishable_detail')

src = open(mig, encoding='utf-8').read()
for marker, body in [('@@ACTOR_BODY@@', actor), ('@@STAMP_KEY_BODY@@', key), ('@@PUBLISHABLE_DETAIL_BODY@@', detail),
                     ('@@LINES_834742_P2@@', json.dumps(lines))]:
    if src.count(marker) != 1: sys.exit(f'marker {marker} occurs {src.count(marker)} times in the migration')
    src = src.replace(marker, body)
with open(mig, 'w', encoding='utf-8', newline='\n') as f:
    f.write(src)
print('assembled', mig, 'fixture', fixture, 'lines', len(lines))
```

Dump the three live bodies, then assemble:

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && printf '%s\n' "select '_actor' as k, pg_get_functiondef('derm._actor(text)'::regprocedure) as def union all select '_require_stamp_key', pg_get_functiondef('derm._require_stamp_key()'::regprocedure) union all select 'fn_sheet_publishable_detail', pg_get_functiondef('derm.fn_sheet_publishable_detail(text)'::regprocedure);" > scripts/probes/generated_finisher/finisher_defs.out.sql && node scripts/q.js scripts/probes/generated_finisher/finisher_defs.out.sql scripts/probes/generated_finisher/finisher_defs.out.json && python scripts/probes/generated_finisher/assemble_finisher_migration.py && grep -c "@@" docs/migrations/2026-09-15_1200_generated_sheet_finisher.sql
```

Expected: `assembled ... fixture ticket-834742_p2 lines <N>` and the grep count `0` (no marker left). If the fixture page's Phase 0 verdict was not MATCH, pass another MATCH page's key (for example `ticket-835309_p2`) AND change the four `v_fx_*` values at the top of the VERIFY to that page before assembling.

- [ ] **Step 3: Paste the calibrated numbers, rehearse, apply**

Replace the two `-- REPLACE` lines in PART 1 with `calibrated_prior` and `tolerances` from `phase0_results.json` (six numbers with three decimals; match/gap/clear to two decimals), then:

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && grep -n -- "-- REPLACE" docs/migrations/2026-09-15_1200_generated_sheet_finisher.sql; node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-15_1200_generated_sheet_finisher.sql rehearse
```

Expected: the grep prints nothing (both markers gone); the rehearsal returns `HTTP 201 []`. A `VERIFY 4b FAILED: bands sit Xpp from the accepted ones` means the fixture page's person-marked lines differ from the detector's: pick a Phase 0 MATCH page as the fixture (step 2) rather than widening anything. Then:

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-15_1200_generated_sheet_finisher.sql
```

Expected: `HTTP 201 []`.

- [ ] **Step 4: Read the live state once, then commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && printf '%s\n' "select (select count(*) from derm.v_generated_measure_backlog) as measure_backlog, (select count(*) from derm.v_generated_complete_backlog) as complete_backlog, (select value from public.app_config where key='generated_sheet_auto_complete') as switch, derm.fn_generated_page_prior() as prior, derm.fn_generated_match_tolerances() as tol;" > scripts/probes/generated_finisher/t5.out.sql && node scripts/q.js scripts/probes/generated_finisher/t5.out.sql scripts/probes/generated_finisher/t5.out.json && cat scripts/probes/generated_finisher/t5.out.json && git pull -q --rebase origin main && git add docs/migrations/2026-09-15_1200_generated_sheet_finisher.sql scripts/probes/generated_finisher/assemble_finisher_migration.py && git commit -q -m "Generated-sheet finisher: measure a page from its scan through the guarded RPCs, then complete" -m "derm.fn_generated_page_measured writes only through record_page_rules (template-v1) and save_page_geometry, both or neither; derm.fn_complete_generated_sheet is the resolver's completion write plus the one-card-per-printed-row gate; the ledger, the backlog views, the banner reason, the off switch, and the service_role arms in _actor and _require_stamp_key. Proven on ticket-834742 page 2 inside a rolled-back savepoint against the geometry a person accepted." -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" && git push -q origin main && git log -1 --format='%h %s'
```

Expected: `measure_backlog` 0 and `complete_backlog` 0 (unless a generated sheet is open at that moment; 835076 reads 1 in `complete_backlog` if Fred has not clicked yet, and that is correct: the cron in Task 7 will complete it), `switch` `true`; one commit pushed.

---
### Task 6: The edge function `measure-generated-page`

Thin on purpose: fetch one scan, decode, run the shared detector, hand the raw lines to the writer
RPC. It classifies nothing and writes nothing itself.

**Files:**
- Create: `supabase/functions/measure-generated-page/index.ts`
- Modify: `supabase/config.toml` (one block after `[functions.ocr-address-sheet-rows]`)

- [ ] **Step 1: Write the function**

`supabase/functions/measure-generated-page/index.ts`:

```ts
// measure-generated-page: runs the printed-rule detector on ONE page of a GENERATED DERM address
// sheet and hands the raw lines to derm.fn_generated_page_measured, which decides everything.
// This function classifies nothing and writes nothing itself.
//
// WHY IT IS THIS THIN. The decision (which lines are the six printed boundaries, whether the
// stamps sit inside them, whether anything may be written) lives in SQL, where it was replayed
// over the whole accepted corpus before it shipped (scripts/probes/generated_finisher/phase0_report.md)
// and is exercised by migration 2026-09-15_1200's VERIFY. The only work that needs a runtime with a
// JPEG decoder is fetching the scan and running the detector, and the detector is the SAME module
// the Node probe runs: supabase/functions/_shared/printed_rule_detector.mjs.
//
// INVOKED BY pg_cron (public.fn_request_generated_measure) with a service_role bearer, one page per
// call, body {dump_folder, ticket, page, image_url}. The cron records the attempt BEFORE asking, so
// a worker that dies here still consumes its budget (three per image).
//
// A FAILED FETCH OR DECODE IS STILL REPORTED: the RPC is called with p_lines null and meta.error,
// so the ledger reads "could not be read" instead of the page sitting at "requested" for ever.
//
// AUTH: verify_jwt=true (config.toml) PLUS the in-handler role gate. The anon key is a validly
// signed JWT, so the gateway check alone is half a gate.

import { decode } from "npm:jpeg-js@0.4.4";
import { detectRules } from "../_shared/printed_rule_detector.mjs";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const MAX_IMAGE_BYTES = 12 * 1024 * 1024;

function json(p: unknown, status = 200): Response {
  return new Response(JSON.stringify(p), { status, headers: { "Content-Type": "application/json" } });
}
function bearerRole(req: Request): string | null {
  try {
    const tok = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
    return JSON.parse(atob(tok.split(".")[1] ?? ""))?.role ?? null;
  } catch { return null; }
}
const dermHeaders = {
  "Content-Type": "application/json",
  "Content-Profile": "derm",
  apikey: SERVICE_KEY,
  Authorization: `Bearer ${SERVICE_KEY}`,
};

// The hand-off. Everything after this line is the database's decision.
async function report(body: Record<string, unknown>) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/fn_generated_page_measured`, {
    method: "POST", headers: dermHeaders, body: JSON.stringify(body),
  });
  const text = await r.text();
  let parsed: unknown = text;
  try { parsed = JSON.parse(text); } catch { /* keep the raw text */ }
  return { ok: r.ok, status: r.status, result: parsed };
}

Deno.serve(async (req) => {
  if (bearerRole(req) !== "service_role") return json({ error: "service_role required" }, 403);
  let body: { dump_folder?: string; page?: number; image_url?: string; ticket?: string };
  try { body = await req.json(); } catch { return json({ error: "invalid json" }, 400); }
  const dumpFolder = String(body?.dump_folder ?? "").trim();
  const page = Number(body?.page);
  const imageUrl = String(body?.image_url ?? "").trim();
  if (!/^ticket-\d{4,8}$/.test(dumpFolder)) return json({ error: "need dump_folder 'ticket-<digits>'" }, 400);
  if (!Number.isInteger(page) || page < 1 || page > 9) return json({ error: "need page 1..9" }, 400);
  // only our own public manifests bucket: anything else is not a scan of ours
  const allowed = `${SUPABASE_URL}/storage/v1/object/public/manifests/`;
  if (!imageUrl.startsWith(allowed)) return json({ error: "image_url must be a public manifests object" }, 400);

  const base = { p_dump_folder: dumpFolder, p_page: page, p_image_url: imageUrl };
  const t0 = Date.now();
  // deno-lint-ignore no-explicit-any
  let raw: any;
  try {
    const img = await fetch(imageUrl);
    if (!img.ok) throw new Error(`image HTTP ${img.status}`);
    const ct = (img.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
    const bytes = new Uint8Array(await img.arrayBuffer());
    if (bytes.length > MAX_IMAGE_BYTES) throw new Error(`image is ${bytes.length} bytes, over the ${MAX_IMAGE_BYTES} limit`);
    if (!(bytes[0] === 0xff && bytes[1] === 0xd8)) throw new Error(`not a JPEG (content-type ${ct || "?"}); only JPEG scans are measured automatically`);
    raw = decode(bytes, { useTArray: true });
  } catch (e) {
    const handoff = await report({ ...base, p_lines: null, p_meta: { error: String(e).slice(0, 300), ms: Date.now() - t0 } });
    return json({ ok: false, stage: "fetch", error: String(e).slice(0, 300), handoff });
  }
  const r = detectRules(raw);
  const handoff = await report({
    ...base,
    p_lines: r.rules,
    p_meta: { image_w: r.W, image_h: r.H, skew: r.skew, detector: "printed_rule_detector.mjs", ms: Date.now() - t0 },
  });
  return json({ ok: handoff.ok, dump_folder: dumpFolder, page, lines: r.rules.length, ms: Date.now() - t0, handoff });
});
```

- [ ] **Step 2: Register it in `config.toml`** (anchored insert, never a hand edit in the middle of a 700-line file)

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && python - <<'EOF'
p = 'supabase/config.toml'
s = open(p, encoding='utf-8').read()
anchor = '[functions.ocr-address-sheet-rows]\nverify_jwt = true\n'
assert s.count(anchor) == 1, 'anchor'
block = anchor + '''
# measure-generated-page: the generated-sheet finisher's detector (2026-09-15). Invoked by pg_cron
# (public.fn_request_generated_measure) with a service_role bearer; the handler decodes the JWT and
# requires role=service_role, so the gateway MUST verify the signature. Never deploy --no-verify-jwt.
[functions.measure-generated-page]
verify_jwt = true
'''
open(p, 'w', encoding='utf-8', newline='\n').write(s.replace(anchor, block))
print('ok')
EOF
grep -n -A1 "functions.measure-generated-page" supabase/config.toml
```

Expected: `ok`, then the two lines of the new block.

- [ ] **Step 3: Deploy, then verify the DEPLOYED body**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && SUPABASE_ACCESS_TOKEN="$(grep '^SUPABASE_PAT=' .env | cut -d= -f2- | tr -d '"\r')" supabase functions deploy measure-generated-page --project-ref wbasvhvvismukaqdnouk 2>&1 | tail -5
```

Expected: `Deployed Functions on project wbasvhvvismukaqdnouk: measure-generated-page`. (The PAT is read from `.env` inside the command substitution and never echoed.)

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/edge_deployed_body.js measure-generated-page "rpc/fn_generated_page_measured" "service_role required" "!x-stamp-key" "!ANTHROPIC_API_KEY"
```

Expected: the two present needles reported present (the first is the control), the two absent ones absent. ⚠ The deployed bundle inlines `../_shared/printed_rule_detector.mjs`; if `detectRules` is reported absent, the bundler renamed it, which is fine, but `rpc/fn_generated_page_measured` must be present.

- [ ] **Step 4: Smoke test on a real page, end to end** (835076 page 1: a measured generated page, so the RPC must answer "no longer needs measuring" and the ledger must hold the 15 detected lines; nothing about the page changes)

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node -e "
const fs=require('fs');
for (const line of fs.readFileSync('.env','utf8').split(/\r?\n/)) { const m=line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$/); if(m && !(m[1] in process.env)) process.env[m[1]]=m[2].trim().replace(/^[\"']|[\"']$/g,''); }
const url='https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/measure-generated-page';
const body={dump_folder:'ticket-835076', ticket:'835076', page:1, image_url:'https://wbasvhvvismukaqdnouk.supabase.co/storage/v1/object/public/manifests/derm/1929/address_1.jpg'};
fetch(url,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+process.env.SUPABASE_SERVICE_ROLE_KEY},body:JSON.stringify(body)})
  .then(async r=>{const t=await r.text(); console.log('HTTP',r.status); console.log(t.slice(0,600));});
"
```

Expected: `HTTP 200`, `"lines":15`, and inside `handoff.result`: `"outcome":"refused"`, `"reason":"This page no longer needs measuring automatically."`. Then confirm the ledger row and that the page did not move:

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && printf '%s\n' "select dump_folder, page, attempts, last_outcome, last_reason, jsonb_array_length(lines) as lines, meta->>'ms' as ms, meta->>'image_w' as w from derm.generated_measure_attempts; select count(*) filter (where source like 'template-v1-%') as template_scans from derm.page_rule_scans where dump_folder='ticket-835076';" > scripts/probes/generated_finisher/t6.out.sql && node scripts/q.js scripts/probes/generated_finisher/t6.out.sql scripts/probes/generated_finisher/t6.out.json && cat scripts/probes/generated_finisher/t6.out.json
```

Expected: one ledger row (`ticket-835076`, 1, attempts 1, `refused`, 15 lines, `w` 1492) and `template_scans` 0. That ledger row is bookkeeping and stays; it is never shown (the banner only reads reasons for pages that still need geometry).

- [ ] **Step 5: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && git pull -q --rebase origin main && git add supabase/functions/measure-generated-page/index.ts supabase/config.toml && git commit -q -m "Edge fn measure-generated-page: detect one page's printed lines and hand them to the finisher RPC" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" && git push -q origin main && git log -1 --format='%h %s'
```

---

### Task 7: The cron (migration D)

**Files:**
- Create: `docs/migrations/2026-09-15_1300_generated_sheet_finisher_cron.sql`

- [ ] **Step 1: Write the migration**

```sql
-- ============================================================================================
-- 2026-09-15_1300_generated_sheet_finisher_cron.sql
--
-- Schedules the generated-sheet finisher: every ten minutes, complete what can be completed (no
-- HTTP, and it is what a HAND-measured generated sheet needs too), then request at most two page
-- measurements from the edge function measure-generated-page, budgeted three attempts per image by
-- derm.generated_measure_attempts. No HTTP call when there is nothing to do (same shape as
-- city-email-sweep and sheet-row-ocr-sweep).
--
-- Minute offset 6-59/10: after sheet-number-ocr-sweep (2-59/10) and sheet-row-ocr-sweep (4-59/10),
-- so a freshly filed sheet's page map and row reads have usually landed by the time it runs, and
-- before redact-manifest-sweep's next 3-59/5 tick picks up the completion.
--
-- The attempt is recorded BEFORE the request is posted (derm.generated_measure_attempts, same rule
-- as row_ocr_attempts): a worker that dies still consumes its budget, which is the fail-safe side.
-- RULE 8: no table changes.
-- ============================================================================================
BEGIN;

CREATE OR REPLACE FUNCTION public.fn_request_generated_measure()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_key text; t record; f record;
BEGIN
  -- 1. completion first: no HTTP, and a generated sheet a person measured by hand completes here
  FOR f IN SELECT dump_folder FROM derm.v_generated_complete_backlog WHERE blocker IS NULL LOOP
    PERFORM derm.fn_complete_generated_sheet(f.dump_folder);
  END LOOP;

  -- 2. measurement requests, budgeted
  SELECT decrypted_secret INTO v_key FROM vault.decrypted_secrets WHERE name = 'edge_invoke_service_key';
  IF v_key IS NULL THEN
    RAISE WARNING 'edge_invoke_service_key vault secret missing; skipping generated-sheet measure';
    RETURN;
  END IF;
  FOR t IN SELECT * FROM derm.fn_generated_measure_targets(2) LOOP
    INSERT INTO derm.generated_measure_attempts (dump_folder, page, image_url, source_etag, attempts, last_outcome)
    VALUES (t.dump_folder, t.page, t.image_url, t.source_etag, 1, 'requested')
    ON CONFLICT (dump_folder, page) DO UPDATE
       SET attempts = CASE
                        WHEN derm.generated_measure_attempts.image_url IS DISTINCT FROM EXCLUDED.image_url
                          OR derm.generated_measure_attempts.source_etag IS DISTINCT FROM EXCLUDED.source_etag
                        THEN 1                                            -- new scan, fresh budget
                        ELSE derm.generated_measure_attempts.attempts + 1
                      END,
           image_url = EXCLUDED.image_url, source_etag = EXCLUDED.source_etag,
           last_outcome = 'requested', last_attempt_at = now();
    PERFORM net.http_post(
      url := 'https://wbasvhvvismukaqdnouk.supabase.co/functions/v1/measure-generated-page',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key),
      body := jsonb_build_object('dump_folder', t.dump_folder, 'ticket', t.ticket, 'page', t.page, 'image_url', t.image_url),
      timeout_milliseconds := 120000);
  END LOOP;
END $function$;
REVOKE ALL ON FUNCTION public.fn_request_generated_measure() FROM PUBLIC, anon, authenticated;

SELECT cron.schedule('generated-sheet-finisher', '6-59/10 * * * *',
                     'SELECT public.fn_request_generated_measure()');

-- --------------------------------------------------------------------------------------------
-- VERIFY
-- --------------------------------------------------------------------------------------------
DO $verify$
DECLARE v_n int; v_q0 bigint; v_q1 bigint; v_att int;
BEGIN
  IF (SELECT count(*) FROM cron.job WHERE jobname = 'generated-sheet-finisher') <> 1 THEN RAISE EXCEPTION 'VERIFY 1 FAILED: job'; END IF;
  IF (SELECT schedule FROM cron.job WHERE jobname = 'generated-sheet-finisher') <> '6-59/10 * * * *' THEN RAISE EXCEPTION 'VERIFY 1a FAILED: schedule'; END IF;
  IF (SELECT count(*) FROM cron.job WHERE schedule = '6-59/10 * * * *') <> 1 THEN RAISE EXCEPTION 'VERIFY 1b FAILED: another job shares the minute'; END IF;

  -- 2. with an empty measure backlog the wrapper queues NO request (in a savepoint, so the
  --    completion loop's real work, if any, is left to the first scheduled run, not to this file)
  IF EXISTS (SELECT 1 FROM derm.fn_generated_measure_targets(5)) THEN
    RAISE EXCEPTION 'VERIFY 2 SETUP: the measure backlog is not empty right now; re-run when it is, or read it first';
  END IF;
  BEGIN
    SELECT count(*) INTO v_q0 FROM net.http_request_queue;
    PERFORM public.fn_request_generated_measure();
    SELECT count(*) INTO v_q1 FROM net.http_request_queue;
    IF v_q1 <> v_q0 THEN RAISE EXCEPTION 'VERIFY 2 FAILED: % request(s) queued with nothing to do', v_q1 - v_q0; END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;

  -- 3. with one page in the backlog (ticket-834742 p2, stripped inside a savepoint) it queues exactly
  --    one request and records the attempt first; a second run counts the second attempt
  BEGIN
    UPDATE derm.stamp_sheet_status SET completed = false, completed_at = NULL, completed_by = NULL WHERE dump_folder = 'ticket-834742';
    UPDATE derm.stamp_sheet_status SET reopened_at = NULL, reopened_by = NULL WHERE dump_folder = 'ticket-834742';
    DELETE FROM derm.page_block_extents WHERE dump_folder = 'ticket-834742' AND effective_page = 2;
    DELETE FROM derm.page_rule_scans WHERE dump_folder = 'ticket-834742' AND effective_page = 2 AND source LIKE 'human-v1-%';
    SELECT count(*) INTO v_q0 FROM net.http_request_queue;
    PERFORM public.fn_request_generated_measure();
    SELECT count(*) INTO v_q1 FROM net.http_request_queue;
    IF v_q1 - v_q0 <> 1 THEN RAISE EXCEPTION 'VERIFY 3 FAILED: % request(s) queued for one page', v_q1 - v_q0; END IF;
    SELECT attempts INTO v_att FROM derm.generated_measure_attempts WHERE dump_folder = 'ticket-834742' AND page = 2 AND last_outcome = 'requested';
    IF v_att IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'VERIFY 3a FAILED: attempts %', v_att; END IF;
    PERFORM public.fn_request_generated_measure();
    SELECT attempts INTO v_att FROM derm.generated_measure_attempts WHERE dump_folder = 'ticket-834742' AND page = 2;
    IF v_att IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'VERIFY 3b FAILED: attempts %', v_att; END IF;
    -- the queued request carries the page and the live image
    IF NOT EXISTS (SELECT 1 FROM net.http_request_queue q
                    WHERE q.url LIKE '%/functions/v1/measure-generated-page'
                      AND convert_from(q.body, 'UTF8')::jsonb->>'dump_folder' = 'ticket-834742'
                      AND (convert_from(q.body, 'UTF8')::jsonb->>'page')::int = 2) THEN
      RAISE EXCEPTION 'VERIFY 3c FAILED: the queued body is not the page';
    END IF;
    RAISE EXCEPTION 'RB';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'RB' THEN RAISE; END IF; END;
  IF EXISTS (SELECT 1 FROM derm.generated_measure_attempts WHERE dump_folder = 'ticket-834742') THEN RAISE EXCEPTION 'CLEANUP FAILED'; END IF;

  RAISE NOTICE 'ALL VERIFY PASSED: job scheduled at 6-59/10; no request with an empty backlog; one request per backlog page, attempt recorded first, second run counts 2.';
END
$verify$;

COMMIT;
```

⚠ `net.http_request_queue.body` is `bytea` in pg_net 0.20; if VERIFY 3c fails with a type error, replace `convert_from(q.body, 'UTF8')::jsonb` with `q.body::jsonb` (older layouts store jsonb) and rehearse again. The rehearsal rolls the queued rows back, so no request is sent by the VERIFY itself.

- [ ] **Step 2: Rehearse, apply, watch the first two runs**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-15_1300_generated_sheet_finisher_cron.sql rehearse && node scripts/probes/apply_sql_file.mjs docs/migrations/2026-09-15_1300_generated_sheet_finisher_cron.sql
```

Expected: `HTTP 201 []` twice. Then, after the next :06 or :16 minute:

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && printf '%s\n' "select r.start_time at time zone 'America/New_York' as started_et, r.status, r.return_message from cron.job_run_details r join cron.job j on j.jobid = r.jobid where j.jobname = 'generated-sheet-finisher' order by r.start_time desc limit 3; select dump_folder, completed, completed_by, completed_at at time zone 'America/New_York' as completed_et from derm.stamp_sheet_status where dump_folder = 'ticket-835076';" > scripts/probes/generated_finisher/t7.out.sql && node scripts/q.js scripts/probes/generated_finisher/t7.out.sql scripts/probes/generated_finisher/t7.out.json && cat scripts/probes/generated_finisher/t7.out.json
```

Expected: the run rows `succeeded`; and if Fred had not clicked Mark completed on 835076, it now reads `completed true, completed_by stamp-studio-ai` (it was publishable since `2026-09-14_0030`), and `derm.redacted_manifest_docs` starts filling on the next blackout sweep (one document per five minutes, ten documents, about fifty minutes). Tell Fred either way.

- [ ] **Step 3: Commit**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && git pull -q --rebase origin main && git add docs/migrations/2026-09-15_1300_generated_sheet_finisher_cron.sql && git commit -q -m "Schedule the generated-sheet finisher every ten minutes" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" && git push -q origin main && git log -1 --format='%h %s'
```

---

### Task 8: Documentation, in the same cycle

**Files:**
- Modify: `CLAUDE.md` (this repo): a new section, and one correction to the 2026-09-02 blackout note
- Modify: `Building Apps/DERM Stamp Studio/docs/08-changelog.md` (new dated entry at the top)
- Modify: `Building Apps/DERM Stamp Studio/CLAUDE.md` (one paragraph)
- Modify: `docs/superpowers/specs/2026-09-14-generated-sheet-auto-measure-and-complete-design.md` (status line + the calibrated prior)
- Modify: `C:\Users\FRED\Desktop\Virtrify\Yannick\Claude\WORKING-NOW.md` (clear the claim)

- [ ] **Step 1: Supabase `CLAUDE.md`.** Write the section below to `scripts/probes/generated_finisher/claude_section.out.md` (fill `<N>` from `phase0_report.md`), then splice it in immediately BEFORE the regulator-facing-form section, anchored and asserted once. Use the Write tool for the splice script (`scripts/probes/generated_finisher/splice_docs.py`) rather than a shell heredoc: a heredoc inside a heredoc has already eaten one edit in this project.

`scripts/probes/generated_finisher/splice_docs.py`:

```python
# Splices the finisher documentation into the Supabase CLAUDE.md and the Stamp Studio docs, each
# insert anchored and asserted once. Inputs: claude_section.out.md, changelog_entry.out.md,
# studio_claude.out.md next to this file. USE: python scripts/probes/generated_finisher/splice_docs.py
import os, sys
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.abspath(os.path.join(here, '..', '..', '..'))
def read(p): return open(p, encoding='utf-8').read()
def write(p, s): open(p, 'w', encoding='utf-8', newline='\n').write(s)

# 1. Supabase CLAUDE.md: the section, plus the closure note on the 2026-09-02 gap paragraph
p = os.path.join(root, 'CLAUDE.md'); s = read(p)
anchor = '### 🛑 A DERM SHEET IS A REGULATOR-FACING COMPLIANCE FORM: FILL IT, NEVER MARK IT (Fred, 2026-08-04)'
if s.count(anchor) != 1: sys.exit('CLAUDE.md anchor')
gap = 'Studio. Until that path covers pre-placed sheets, expect this backlog to recur; watch\n> `v_blackout_blocked_sheets`.'
if s.count(gap) != 1: sys.exit('CLAUDE.md gap paragraph anchor')
s = s.replace(gap, gap + ' **Closed for GENERATED sheets on 2026-09-15 by the finisher (see "GENERATED\n> SHEETS FINISH THEMSELVES" below); a handwritten sheet still needs Draw the bands.**')
s = s.replace(anchor, read(os.path.join(here, 'claude_section.out.md')).rstrip() + '\n\n' + anchor)
write(p, s)

# 2. Stamp Studio changelog: new entry under the title line
cl = os.path.join(root, '..', 'Building Apps', 'DERM Stamp Studio', 'docs', '08-changelog.md'); c = read(cl)
title, rest = c.split('\n', 1)
if not title.startswith('# DERM Stamp Studio'): sys.exit('changelog title')
write(cl, title + '\n\n' + read(os.path.join(here, 'changelog_entry.out.md')).rstrip() + '\n\n' + rest.lstrip('\n'))

# 3. Stamp Studio CLAUDE.md: one paragraph after the plain-language section
ck = os.path.join(root, '..', 'Building Apps', 'DERM Stamp Studio', 'CLAUDE.md'); k = read(ck)
a2 = 'after the editor was gone.\n'
if k.count(a2) != 1: sys.exit('Studio CLAUDE.md anchor (end of the plain-language section)')
write(ck, k.replace(a2, a2 + '\n' + read(os.path.join(here, 'studio_claude.out.md')).rstrip() + '\n'))
print('ok')
```

Run it after writing the three `.out.md` inputs (steps 1 and 2): `python scripts/probes/generated_finisher/splice_docs.py`, expected `ok`.

The section for `claude_section.out.md`:

```markdown
### ✅ GENERATED SHEETS FINISH THEMSELVES: measured from the scan, guided by the layout we printed (2026-09-15)

Fred, 2026-09-14, on 835076: *"if it's a generated manifest ... it should be auto-stamped and auto
marked as complete unless it can be certain of the stamps."* Two of his rules could not both hold,
"generated sheets are automatic" and "complete means it will be blacked out" (2026-09-03), because
nothing MEASURED a generated sheet automatically. Now something does, and only for sheets we printed.

**The finisher** (`generated-sheet-finisher`, `6-59/10`, `public.fn_request_generated_measure()`):
1. completes every open generated folder that passes every gate (no HTTP; a hand-measured
   generated sheet completes here too), through `derm.fn_complete_generated_sheet`, the resolver's
   own write plus one gate the human path lacks: **one card per printed row, per client**;
2. hands at most two stamped, unmeasured pages to the edge function `measure-generated-page`,
   which runs the run-length detector (ONE shared module, `supabase/functions/_shared/printed_rule_detector.mjs`,
   the same code the Node probe runs) and posts the raw lines to `derm.fn_generated_page_measured`.
3. That RPC matches the lines to the printed layout (`derm.fn_match_generated_page`, pure: the
   layout is a PRIOR, the scan is the MEASUREMENT; a half-width boundary is still the boundary)
   and writes ONLY through `derm.record_page_rules` (source `template-v1-<date>`) and
   `derm.save_page_geometry`, both in one subtransaction: both or neither, every guard G1..G14
   runs, and no template value is ever written (every band edge and both extents are detected
   lines on THIS scan).

**Precedence of rule sources is now `human-v1 > template-v1 > runlen-v2`** (`derm._rule_source_rank`,
read by BOTH `v_page_printed_rules` and `v_band_edge_check`). A person's lines always win; a page
with a human-marked scan is not in the backlog at all.

**What it refuses, in words, for a person** (the Studio banner reads "Page N could not be measured
automatically: <reason>. Page N: ..." through `fn_sheet_publishable_detail`): a handwritten sheet
(no generated-sheet link, e.g. the pads linked to 833049 and 834986), a client printed on several
rows (833395's 242-WYN), a card not on the printed list, a card printed on another page, a stamp on
a line, a missing or wrongly spaced printed line, a scan that is not a JPEG. Three attempts per
image (`derm.generated_measure_attempts`, re-armed by a replaced scan or a card edit), then it is
left alone.

**Watch:** `derm.v_generated_measure_backlog` (pages waiting; `attempts_on_this_image` 3 means a
person is needed) and `derm.v_generated_complete_backlog` (open generated folders; `blocker` says
why one is not completing). **Off switch:** `public.app_config` `generated_sheet_auto_complete`
= `false` stops completion only; measuring continues so the geometry is banked and Mark completed
still works. Missing key = on.

**Calibration:** the prior and the tolerances (`derm.fn_generated_page_prior`,
`derm.fn_generated_match_tolerances`) were measured over the <N>-page accepted corpus, not chosen:
`scripts/probes/generated_finisher/phase0_report.md`. Re-run `phase0_corpus.mjs` before touching
either; a tolerance is calibrated on pages that are RIGHT, never widened to admit a page that is
wrong.

🛑 **"service_role is a machine" is now encoded in two helpers**: `derm._actor` returns
`stamp-studio-ai` for a service_role caller with no email (Fred: one label for everything
machine-made), and `derm._require_stamp_key` lets service_role through. Do not add a second
machine label.

⚠ **Not shipped: re-placing cards left unplaced by a late sheet-number read** (the 835076 race;
Step A of the design). Those cards still wait for Auto-place, and `derm.v_cards_awaiting_page_map`
still lists them. Fred's call, pending.
```

(The splice script also appends the closure note to the 2026-09-02 "systemic gap" paragraph; if that anchor no longer matches, find the sentence "expect this backlog to recur; watch `v_blackout_blocked_sheets`" and append the same note by hand.)

- [ ] **Step 2: Stamp Studio changelog and CLAUDE.md.** Write the entry below to `scripts/probes/generated_finisher/changelog_entry.out.md` and the paragraph after it to `scripts/probes/generated_finisher/studio_claude.out.md`; the splice script from step 1 places both. The changelog entry:

```markdown
## 2026-09-15 - generated sheets measure and complete themselves (server; no app deploy)

Fred, 2026-09-14: *"if it's a generated manifest ... it should be auto-stamped and auto marked as
complete unless it can be certain of the stamps."* Since 2026-09-03 completion has required
measured bands and an extent, and nothing measured a generated sheet automatically, so every one
stopped at "Cannot complete yet" until a person opened Draw the bands. Now a cron
(`generated-sheet-finisher`, every ten minutes) measures each stamped page of a generated sheet
from its own scan, guided by the layout we printed, saves through the same two RPCs Draw the bands
uses (`record_page_rules` as source `template-v1-<date>`, then `save_page_geometry`), and marks the
sheet complete under `stamp-studio-ai`, so the blackout follows with no clicks. Typical end to end:
under thirty minutes from filing.

**What the operator sees.** Nothing new to press. A generated sheet that the finisher could not
measure keeps the amber banner, which now starts with the reason: "Page 2 could not be measured
automatically: a printed line between two rows is not visible on this scan. Page 2: Some rows on
this page are still on an estimated position ...". Draw the bands then works exactly as before, and
a person's lines always win over the finisher's (`human-v1` outranks `template-v1`). Mark completed
still works by hand, including when the switch below is off.

**What never happens.** No template value is written (every line is detected on the scan). A
handwritten sheet, a client printed on several rows without one card per permit, a stamp sitting
on a line, a reopened sheet: refused, in words, for a person. Three attempts per scan.

**Rules that must not be regressed.** The banner text comes from
`derm.fn_sheet_publishable_detail(folder)->>'message'` (unchanged contract, one more sentence in
front). `derm.v_page_printed_rules` now admits a third source prefix, `template-v1-`; Draw the bands
seeds from it like any other. The off switch is `public.app_config` `generated_sheet_auto_complete`.
DB side: Supabase `CLAUDE.md` "GENERATED SHEETS FINISH THEMSELVES", migrations `2026-09-15_1000`
`_1100` `_1200` `_1300`, edge fn `measure-generated-page`, Phase 0 corpus report
`scripts/probes/generated_finisher/phase0_report.md`.
```

The paragraph for `studio_claude.out.md` (it lands after the plain-language section added on 2026-09-14):

```markdown
**Generated sheets measure and complete themselves (2026-09-15).** A cron measures each stamped page
of a sheet we printed and completes the sheet; the app has nothing to do. When it cannot, the amber
banner starts with the reason ("Page N could not be measured automatically: ..."), and Draw the
bands works as before. The app must keep showing `message` verbatim and never display `finisher_reasons`
or `detail` separately. Server details: Supabase `CLAUDE.md`, "GENERATED SHEETS FINISH THEMSELVES".
```

- [ ] **Step 3: The spec.** Two Edit-tool replacements in `docs/superpowers/specs/2026-09-14-generated-sheet-auto-measure-and-complete-design.md`, each old string occurring once:
  - old: `*Design, 2026-09-14. Not built. Fred: "go, write the design first."*`
    new: `*Design, 2026-09-14. Built 2026-09-15 (plan: docs/superpowers/plans/2026-09-14-generated-sheet-finisher.md). Step A (section 4.A) is NOT built, pending Fred.*`
  - old: `   edges of the page's cards, which come from `fn_generated_row_geometry`).`
    new: `   edges of the page's cards, which come from `fn_generated_row_geometry`). Phase 0 replaced that
   stamp-midpoint template with the mean printed layout measured over the accepted corpus
   (`derm.fn_generated_page_prior`); the template remains the first-pass prior the calibration
   starts from.`

- [ ] **Step 4: Commit the two repos, clear the claim**

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Supabase" && git pull -q --rebase origin main && git add CLAUDE.md docs/superpowers/specs/2026-09-14-generated-sheet-auto-measure-and-complete-design.md && git commit -q -m "Document the generated-sheet finisher: what runs, what it refuses, what to watch, the off switch" -m "Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" && git push -q origin main && git log -1 --format='%h %s'
```

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude/Building Apps" && git pull -q --rebase origin main && git add "DERM Stamp Studio/docs/08-changelog.md" "DERM Stamp Studio/CLAUDE.md" && git commit -q -m "Stamp Studio: generated sheets now measure and complete themselves; the banner carries the finisher's reason" && git push -q origin main && git log -1 --format='%h %s'
```

```bash
cd "C:/Users/FRED/Desktop/Virtrify/Yannick/Claude" && printf '%s\n' "" "## $(date +%Y-%m-%d) Supabase session: generated-sheet finisher SHIPPED (cron generated-sheet-finisher live). Claim cleared. Pending Fred: Step A (re-place cards after a late read)." >> WORKING-NOW.md && git add WORKING-NOW.md && git commit -q -m "Clear claim: generated-sheet finisher shipped" && git log -1 --format='%h %s'
```

---

## Phase 2 (Step A): not in this plan

Re-placing cards that a late sheet-number read left unplaced (the 835076 race) reverses the
2026-09-03 decision against unattended re-placement. It is one function (re-run the insert
trigger's chain for `derm.v_cards_awaiting_page_map`, requiring `fn_row_read_confirms(...) IS TRUE`)
and one more loop in `fn_request_generated_measure`, and it gets its own plan once Fred answers
question 2 of the spec.

## Self-review notes (done while writing)

- **Spec coverage.** 4.B B1 (detector, service-role, one page per call, attempts ledger keyed on image,
  re-armed on replacement): Tasks 1, 5, 6, 7. B2 (matcher steps 1 to 6, plain refusals, ledger,
  banner): Tasks 2, 5. B3 (record_page_rules + save_page_geometry, `template-v1-`, precedence):
  Tasks 4, 5. 4.C (completion, card-count gate, `stamp-studio-ai`): Task 5. Section 6 (no template
  value, human wins, handwritten untouched, both-or-neither, closed world, existing screens):
  Task 5 VERIFY 4d/4f/2a, Task 4, Task 5 PART 5. Section 7 Phase 0: Task 3; Phase 1 with the off
  switch defaulting on: Tasks 5 and 7; Phase 2: deferred by Fred. Section 8 answers 1, 3, 4: Task 5.
- **One departure from the spec, deliberate:** the prior is the corpus mean of the printed
  boundaries, not the stamp-midpoint template (835076 page 2 sat 0.73pp from the template, too close
  to the 0.75pp window to be a spec). The template stays as the first-pass prior. Task 8 records it
  in the spec.
- **Names used consistently:** `derm.fn_match_generated_page(jsonb, jsonb, numeric[], numeric, numeric, numeric, numeric, numeric)`,
  `derm.fn_generated_page_cards(text, integer)`, `derm.fn_generated_template_boundaries()`,
  `derm.fn_generated_page_prior()`, `derm.fn_generated_match_tolerances()`, `derm._gm_record(...)`,
  `derm.fn_generated_completion_blocker(text)`, `derm.fn_complete_generated_sheet(text)`,
  `derm.fn_generated_page_measured(text, integer, text, jsonb, jsonb)`,
  `derm.v_generated_measure_backlog`, `derm.fn_generated_measure_targets(integer)`,
  `derm.v_generated_complete_backlog`, `derm.generated_measure_attempts`, `derm._rule_source_rank(text)`,
  `public.fn_request_generated_measure()`, cron `generated-sheet-finisher`, edge fn
  `measure-generated-page`, config key `generated_sheet_auto_complete`, source prefix `template-v1-`.
