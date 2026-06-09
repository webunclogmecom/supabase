Phase 2c bot batch + analyzer done. 36 rows classified.

**Auto-applying in `2026-05-25n`:**
- CONFIRMED_MATCH: **12** (UPDATE max_frequency_days)
- WRONG_CLIENT clean: **9** (DEMOTE, low name similarity)
- DIFFERENT_TENANT clean: **3** (DEMOTE, low name similarity)
- NO_PERMIT: **0** (DEMOTE)

**Auto-total: 24 rows**

**Deferring to your call** — bot data has reliability issues in this batch:

**WRONG_GDO_NUMBER (1)** — `name_match=true` from bot but borderline. Need your judgment:
- 171-CAF Ironside Cafe (id=99): our `GDO-10248` -> bot `GDO-10249` (`THE OM CENTER, LLC DBA PIZZA AT IRONSIDE`, sim=0.46)

**WRONG_CLIENT with name similarity (1)** — bot says wrong client but names look related. Real match or false positive?
- 011-CCC Cine Citta Cafe (Franck Taieb) (id=86, `GDO-05625`): bot says `CINE CITTA, LLC` (sim=0.61, shared=['cine', 'citta'])

**Applying the auto-batch now.** I'll surface results in this thread once landed.
For the deferrals: your call on whether to UPDATE/DEMOTE/skip each.