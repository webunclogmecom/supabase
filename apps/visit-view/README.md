# Visit View

Yannick's upcoming-visits dashboard. The build path is:

1. **Visual prototype in Claude Design** → see [`CLAUDE-DESIGN-PROMPT.md`](CLAUDE-DESIGN-PROMPT.md)
2. **Handoff bundle** from Claude Design → produces HTML + CSS + design tokens
3. **Full-stack wiring in Claude Code** → reads [`DATA-SPEC.md`](DATA-SPEC.md) for the Supabase query

This folder holds the inputs to that pipeline. The actual app will land here
once the handoff bundle is run.

## Files

| File | Purpose |
|---|---|
| [`CLAUDE-DESIGN-PROMPT.md`](CLAUDE-DESIGN-PROMPT.md) | The prompt to paste at claude.ai/design. Includes brand guidance, service-color palette, layout spec, and interaction states. |
| [`DATA-SPEC.md`](DATA-SPEC.md) | What Claude Code needs after the handoff: Supabase query, response shape, grouping logic, RLS notes, acceptance criteria. |
| [`_mockup-reference/`](_mockup-reference/) | Throwaway HTML/CSS/JS demo (not the real UI). Lets you eyeball the layout idea before iterating in Claude Design. **Will be deleted after the real UI lands.** |

## Workflow (the canonical one)

### Step 1 — Claude Design (visual)

1. Open https://claude.ai/design
2. Paste the prompt from `CLAUDE-DESIGN-PROMPT.md`
3. Upload `assets/logo.svg` if you have it (Claude Design extracts palette + typography automatically)
4. Use the visual sliders + inline comments to refine
5. Iterate until the canvas matches your taste

### Step 2 — Handoff bundle

1. Click **Export → Handoff to Claude Code**
2. Claude Design generates a one-line command + a bundle of HTML, CSS, and design tokens
3. Copy the command

### Step 3 — Claude Code (full-stack)

1. Open a Claude Code session at this repo's root
2. Paste the command
3. Claude Code drops the handoff bundle into this folder, reads `DATA-SPEC.md`, wires the Supabase fetch + RLS + filters
4. Test with `python3 -m http.server` or your dev server
5. Iterate on backend behavior (auth, realtime sub, etc.)

## What's intentionally not here yet

- The actual UI (waiting on Claude Design output)
- Auth flow (Lovable owns it)
- Edit/reschedule actions (read-only for now)
- Tests (will land with Step 3)

## Why a reference mockup exists

The mockup in `_mockup-reference/` is a quick HTML demo built before the
Claude Design workflow was settled. It exists only so you can show somebody
"roughly this kind of thing" without firing up Claude Design first. Once the
real UI lands, delete that folder.
