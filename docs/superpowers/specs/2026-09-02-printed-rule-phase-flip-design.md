# The printed-rule phase flip: why a measured page can end up with no rules

**Status:** spec only. Nothing here is built. Written 2026-09-02 at Fred's request, after
`2026-09-02_0200` fixed the *symptom* (six errors from one missing input) and deliberately left the
*cause* alone.

**Fred:** *"we need to solve the root cause, so it doesn't happen again."* The hint work stops the
Studio shouting codes. This is the thing underneath it.

---

## 1. What actually happens

The detector finds printed lines on a scanned sheet and labels them alternately: slot **boundary**,
mid-slot **divider**, boundary, divider, down the roster. Bands snap to boundaries. Boundaries drive
the blackout. So the labelling is load-bearing for a customer-facing redaction.

The label comes from a **phase choice**: the chain of detected rules is split into evens and odds,
and whichever half has the longer mean run is called the boundaries.

```js
const phase = (p) => chain.filter((_, i) => i % 2 === p);
const scoreOf = (p) => mean(phase(p).runs) - mean(phase(1 - p).runs);
const best = s0 >= s1 ? 0 : 1;
```

If one extra rule survives at either end of the chain, **every label below it inverts**. The chain is
off by one and the whole page is mislabelled.

The server then re-checks independently in `derm.fn_validate_page_rules` and **refuses** the write.
Nothing is stored. The page ends with a `page_rule_scans` row graded `FAILED` and **zero** rows in
`page_row_rules`.

That is the state `ticket-834433` is in:

> `rejected by fn_validate_page_rules: run-length split disagrees with the labels at chain position 13 (run 0.994, cut 0.751, labelled divider): a phase flip`

A rule with run **0.994**, far above the page's own long/short cut of **0.751**, was labelled a
divider. That is not a marginal call. It is the signature of an off-by-one chain.

**The refusal is correct and must not be weakened.** The reference detector says so in as many
words: a drifted client *"can only produce a refused write, never a dangerous one."* Writing an
unverified phase would put bands on the wrong lines, and bands on the wrong lines is how one client
was shown another client's address on 2026-08-19.

## 2. The root cause: the client and the server judge validity differently

This is the finding, and it is not the end-bar trim.

| | question it asks | criterion |
|---|---|---|
| **client** (`classifyPage`) | which phase is more likely? | **comparative**: mean run of evens minus mean run of odds, must beat `MIN_PHASE_EDGE` 0.04 |
| **server** (`fn_validate_page_rules`) | is this labelling self-consistent? | **absolute, per rule**: no rule labelled `divider` may have a run above the page's long/short cut |

Those are not the same test, so **the client can be confident and still be refused**. It picks a
winner on a mean, ships it, and the server finds an individual rule that contradicts the labels.
Every phase-flip refusal is that disagreement.

⇒ **Align the criteria.** If the client applied the server's per-rule test before choosing, it would
either produce a set the server accepts, or grade `FAILED` honestly and stop. It could never hand a
person a page that looks measured and then vanishes.

Concretely: score each phase by the server's rule (`count of dividers whose run exceeds the cut`),
prefer the phase with zero violations, and fall back to the mean-run edge only to break a tie.

## 3. Why the end-bar trim is the *mechanism* but not the *fix*

The trim removes the form's header and footer bars, which are printed rules but not part of the
roster's alternating chain:

```js
while (chain.length > 6 && guard++ < 2
  && isLong(chain[0]) && isLong(chain[1]) && close(chain[0], chain[1])) chain = chain.slice(1);
```

🛑 **It only fires when the outermost TWO rules are both LONG.** On a page whose outermost rule at
either end is SHORT, the real bar stays in the chain and the phase inverts. `ticket-312024` p1 was
the first instance; `ticket-834433` is the second.

Widening the trim is the obvious repair and it is the risky one, because the trim runs on every page:
**173 pages have already been measured by `runlen-v2` and 204 measured pages exist in total, across
130 folders.** Changing the trim changes the chain on some of them, which changes labels, which
changes which bands are considered on-rule, which changes what `v_band_edge_check` grades and
potentially what gets published. That is a fleet-wide re-validation, not a patch, and it is the
reason this was deferred twice already.

Fixing the *criterion* (section 2) is strictly safer: it can only cause the client to refuse more
often, never to accept a labelling the server would reject.

## 4. How bad is it today

Measured 2026-09-02 over `derm.page_rule_scans`: **174 scanned pages, 161 OK, 13 not.**

⚠ **Every count in this spec is a DATED OBSERVATION, not an invariant.** They move whenever a
page is measured. Within hours of writing this, `ticket-834433` was recorded and the totals went
to 176 scanned and 174 `runlen-v2` pages. Re-measure before acting on any number here rather
than quoting it:

```sql
select grade, count(*) from derm.page_rule_scans group by 1 order by 2 desc;
select count(*) from (select distinct dump_folder, effective_page
                        from derm.page_row_rules where source like 'runlen-v2-%') p;
```

| grade | pages | rules written | meaning |
|---|---|---|---|
| `OK` | 161 | yes | healthy |
| `SPARSE` | 8 | yes | one gap above the pitch, a missed rule; still usable |
| `IRREGULAR` | 2 | yes | gaps off the pitch |
| `FAILED` | 3 | **1 of them wrote nothing** | see below |

The three `FAILED` pages are **two different faults**, and only one is blocking:

- `derm/1236` p1 and `window4-sheet1` p2: *"the two phases are indistinguishable (edge 0)"*. The
  detector honestly could not tell, graded FAILED, and **14 rules were still written** for each from
  an earlier or hand-recorded source. Not blocked.
- **`ticket-834433` p1: the phase flip. 14 rules found, 7 boundaries, `0` written.** This is the only
  page in the fleet currently rule-less because of the classifier.

⇒ **Blast radius today is one page.** The reason to fix it is not the backlog, it is that the
mechanism recurs and each occurrence costs an operator an afternoon of unreadable errors.

## 5. Options

**A. Align the client's criterion with the server's.** *(recommended)*
Score phases by the server's per-rule test. Cannot loosen anything: a page that would have been
refused now grades FAILED locally instead, and a page that would have passed is unaffected.
No fleet re-validation, because stored rules are not recomputed.
⚠ It does not by itself rescue `ticket-834433`; it makes the failure honest and immediate rather than
a refusal after the fact. Pair with B or C.

**B. Let a person resolve the phase in the Studio.** *(recommended alongside A)*
When the classifier cannot pick a phase, show both candidate labellings over the scan and let the
operator choose. Record the choice with its own `source` so it is never confused with a detector
result. This matches how every other hard call in this estate is settled: the machine refuses, a
person decides, and the decision is attributed.
⚠ `fn_validate_page_rules` must still run on the human's choice. A person picking the wrong phase is
exactly as dangerous as a classifier picking it.

**C. Widen the end-bar trim.** *(defer)*
The real repair of the mechanism, and the one that needs the 173-page re-validation. Worth doing
once A and B mean nobody is blocked while it is planned. Requires: recompute labels for every
`runlen-v2` page, diff against stored, and review every page whose labels move before writing
anything.

**D. Hand-record the rules for `ticket-834433`.** *(tactical, unblocks today)*
Precedent exists: `2026-08-28_2010` recorded `ticket-312024` p1 by hand, changing **only three
`kind` labels** and keeping every position, run and ink value the detector produced. One page, one
migration, no code change.

## 6. What must not happen

- 🛑 **Do not weaken `fn_validate_page_rules`.** The refusal is the only thing standing between a
  flipped phase and a customer-facing redaction built on the wrong lines.
- 🛑 **Do not re-add a stamp-based phase test.** It was tried, agreed with the run-length phase on
  128 of 133 pages, and is circular: the interval between two consecutive mid-slot dividers also
  contains exactly one stamp, offset by half a pitch. The reference detector carries this warning
  and it should stay carried.
- ⚠ **Do not treat `FAILED` as "detector broken".** Two of the three FAILED pages have rules and are
  serving. `FAILED` means the classifier declined to assert a phase, which is the honest outcome.

## 7. Acceptance criteria

1. A page the server would refuse is never presented to an operator as measured.
2. `ticket-834433` p1 has rules, or a recorded reason why it cannot.
3. No page that is currently `OK` changes its stored labels without a person seeing the diff.
4. `derm.v_band_edges_off_rule` is no larger after the change than before it.
5. The Studio never shows a raw guard code (already true as of `2026-09-02_0200`).

## 8. Open questions for Fred

1. **A + B now, C later?** That unblocks operators without a fleet re-validation.
2. **`ticket-834433`: hand-record it (D) or wait for the real fix?** Hand-recording is one migration
   and has precedent; it also means one more page whose rules are not the detector's own output.
3. **Who resolves an ambiguous phase?** Option B assumes an operator can be shown two candidate
   labellings and pick. If that is the wrong person for the job, B becomes an escalation to you
   instead, which is slower but has a shorter list of people who can get it wrong.
