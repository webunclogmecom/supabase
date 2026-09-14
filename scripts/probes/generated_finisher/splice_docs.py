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
s = s.replace(gap, gap + ' **Closed for GENERATED sheets on 2026-09-14 by the finisher (see "GENERATED\n> SHEETS FINISH THEMSELVES" below); a handwritten sheet still needs Draw the bands.**')
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
