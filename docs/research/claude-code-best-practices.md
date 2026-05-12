# Claude Code Best Practices — synthesis for this project

*Compiled 2026-05-13 from Anthropic's official guide at code.claude.com/docs/en/best-practices,
plus patterns observed in production usage by Anthropic engineering teams.*

This is a project-specific synthesis. Generic AI advice has been stripped out;
what remains is concrete and immediately applicable to the UnclogMe Supabase
repo.

---

## The single highest-leverage principle

> "Give Claude a way to verify its work… This is the single highest-leverage
> thing you can do." — Anthropic best practices guide

For our codebase, the verification layers we already use well:

- `scripts/probes/full_session_audit.js` after every batch of fixes (per existing CLAUDE.md rule)
- `scripts/probes/sandbox_lovable_lint.js` for Sandbox contract checks
- Dry-runs (`--dry-run` flag) on every cron / migration script before execute
- Re-querying DB after writes (we do this consistently — confirms the fix landed)

**Gap:** we don't have a unit-test suite. Most verification is "run the script, query the DB, compare." That's fine for this kind of data-engineering work — but we should be explicit about it as the verification contract.

---

## CLAUDE.md hygiene

The official guidance is **uncomfortable but firm**:

> "If your CLAUDE.md is too long, Claude ignores half of it because important
> rules get lost in the noise. **Ruthlessly prune.** For each line, ask:
> *Would removing this cause Claude to make mistakes?* If not, cut it."

Our current `CLAUDE.md` is **~22 KB / ~500 lines**. The guide implies a target of dozens of lines, not hundreds. Hard truths to face:

| What we have | What the guide recommends |
|---|---|
| Full table of "column-name gotchas" in CLAUDE.md | Move to `docs/operations.md` (already exists). CLAUDE.md should link, not duplicate. |
| 20+ rows of "Known blockers" table | This is a project log, not Claude context. Move to `docs/runbook.md` or a project log. |
| Detailed collaboration rules with Fred / Viktor / Yan | High-value, keep. |
| 7 non-negotiable rules | High-value, keep. |
| "Recent wins" history | Belongs in commit log + audit folder, not CLAUDE.md. |

**Recommended action**: Cut CLAUDE.md down to:
1. The 7 non-negotiable rules
2. Collaboration rules (with people)
3. The truck-name + overnight-shift gotchas (these change Claude's *behavior*)
4. Documentation map (1 paragraph)
5. Links to current state in docs/

Target: **~100 lines, ~5 KB.** Move the rest to `docs/operations.md` (already the canonical operations doc).

---

## Folder layout — what the guide implies

The official guide doesn't prescribe a layout, but observed patterns from
mature Claude Code repos:

```
project-root/
├── CLAUDE.md                    # Lean — see hygiene rules above
├── README.md                    # Human-facing overview
├── .claude/
│   ├── agents/                  # Custom subagent definitions (Markdown)
│   ├── skills/                  # SKILL.md files for repeatable workflows
│   ├── settings.json            # Hooks + permission allowlists
│   └── CLAUDE.md  (optional)    # Local-only overrides, .gitignore'd
├── docs/
│   ├── decisions/               # ADRs (we have these)
│   ├── research/                # External-source synthesis (this file!)
│   └── audits/                  # Historical state snapshots (we have these)
├── apps/                        # Prototypes + applications (we just added)
├── scripts/                     # Operational code
└── ...
```

We already match most of this. Gaps:

- **`.claude/` folder is missing.** Per the guide, custom subagents and skills should live here. We have implicit agents (`general-purpose`, `Explore`, etc.) but no project-specific ones.
- **No hooks configured.** The guide is strong on: *"Use hooks for actions that must happen every time with zero exceptions."* Candidates for us:
  - Pre-commit hook: run `sandbox_lovable_lint.js` if any `apps/` or `supabase/functions/` file changes
  - Post-edit hook: re-run `cron_generate_recurring_visits.js --dry-run` after `service_configs` schema changes
- **No SKILL.md files.** We have natural skills that could be formalized:
  - `derm-search` (you've trained me on this 6 times — feedback memory)
  - `viktor-collaboration-protocol` (also in feedback memory)
  - `airtable-mcp-cleanup` (the Goliath/zone fix patterns we built today)

---

## Subagents — official recommendation

> "Since context is your fundamental constraint, subagents are one of the most
> powerful tools available. When Claude researches a codebase it reads lots of
> files, all of which consume your context. Subagents run in separate context
> windows and report back summaries."

We've been using this pattern instinctively (today's session: spawned `general-purpose` for Claude Code research). The official guidance: **be deliberate**, define them in `.claude/agents/*.md`, give each a focused remit + tool restrictions.

Concrete candidates for our project:
- `audit-runner` — runs `full_session_audit.js`, reports findings, never writes
- `at-cross-ref` — pulls AT data + Sbx data, finds discrepancies, never writes
- `migration-reviewer` — reads a draft migration SQL file, flags risks, never writes
- `lovable-handoff-writer` — given a Sbx schema change, drafts the corresponding `handoff/unclogme-lovable-handoff/` update

---

## Anti-patterns to actively avoid

Direct quotes from the guide that hit our session habits:

| Anti-pattern | Our risk |
|---|---|
| "Kitchen sink session" | **High.** Today's session covered NULL audits, Goliath, cron generation, AT linking, Samsara linking, app prototype. Should have split into multiple sessions or used `/clear` between phases. |
| "Correcting over and over" | Medium. The regex backslash-escaping back-and-forth was an example; we recovered, but the better play was `/clear` + a new specific prompt. |
| "Over-specified CLAUDE.md" | **High.** Addressed above. |
| "Trust-then-verify gap" | Low. Our pattern of always re-querying after writes catches this. |
| "Infinite exploration" | Low. We do use subagents for broad search. |

---

## Communication patterns to adopt

The guide recommends:

1. **`AskUserQuestion` for interviewing.** For big features, have Claude interview the user upfront, then write to `SPEC.md`. We could use this for Yannick's full Visit View app design.
2. **Plan mode** for anything non-trivial. We don't use plan mode often — should for multi-file changes.
3. **Resumable named sessions.** When a workstream spans days (e.g., the Lovable handoff), name the session (`oauth-migration` style) so it's findable.

---

## Project-specific recommendations (action list)

Sorted by ROI:

1. **Prune CLAUDE.md to ~100 lines.** Move column-gotchas + blockers + recent-wins out. Highest impact on Claude's instruction-following quality.
2. **Create `.claude/agents/` folder** with `at-cross-ref.md` and `audit-runner.md`. They formalize patterns we already use.
3. **Add a pre-commit hook** to run `sandbox_lovable_lint.js` if `apps/` or `supabase/functions/` files change.
4. **Create `.claude/skills/derm-search.md`** — that's the workflow you've corrected me on most. Hard-coding it as a skill stops the drift.
5. **Move "Known blockers" table from CLAUDE.md to `docs/runbook.md`.** Less context Claude has to scan to find the actual rules.

Not all of these need to happen at once. The CLAUDE.md prune is the single biggest win.

---

## Sources

- **Primary**: https://code.claude.com/docs/en/best-practices (Anthropic, official)
- **Implied via guide references**:
  - https://code.claude.com/docs/en/memory (CLAUDE.md spec)
  - https://code.claude.com/docs/en/skills (skill format)
  - https://code.claude.com/docs/en/sub-agents (subagent format)
  - https://code.claude.com/docs/en/hooks-guide (hook format)
