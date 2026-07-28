-- ============================================================================
-- 2026-07-28k — client codes for the 5 uncoded clients on the Studio manifests
-- ============================================================================
-- Fred, 2026-07-28, from the DERM Stamp Studio client list: five clients were
-- showing with no client code (which is why "Adam Nadler" could not be found by
-- code when looking at manifest 309661). "check Jobber + our DB, if they don't
-- [have] one create one for them and update them."
--
-- NUMBERING: codes run sequentially and the highest in use is 293-ALC, so these
-- take 294-298. Gaps below 293 (237, 228, 219, ...) were deliberately NOT reused
-- — a retired code can still appear on historical paperwork, and reusing it would
-- make an old DERM manifest resolve to a different business.
--
-- SUFFIXES follow the existing name-derived convention (061..092-TCE are all
-- Carrot Express). 'AN' was unavailable for Adam Nadler (280-AN exists), so NAD.
--
-- 298-PAR — Pari Pari gets its OWN code even though 220-WYN is already named
-- "Pari Pari". Fred confirmed this is deliberate, not a duplicate to merge:
-- 220-WYN (client 475, now INACTIVE) is the record from when Pari Pari was served
-- through Wynd 28; Diego created client 513 because "it was directly Pari Pari who
-- called this time, not Wynd 28, so he created a new client as Pari Pari, so we
-- can quote Pari Pari directly." Two billing relationships, two records, two
-- codes. 220-WYN is left untouched on the inactive record.
--
-- SAFE AGAINST THE JOBBER POLL: webhook-jobber parses a NNN-XX prefix out of the
-- Jobber company name on INSERT only, and explicitly does NOT overwrite an
-- existing client_code on update ("that would clobber [the] authoritative value",
-- index.ts ~line 263). So a code set here survives every subsequent poll.
--
-- NOT DONE HERE: writing the prefix back into the Jobber Company Name. Yan's habit
-- is to type "294-TCE ..." into Jobber so office staff see the code there. That is
-- a Jobber write and was not requested, so it is left for Fred to decide.
--
-- AUDIT (ADR 010): public.clients is audited; these UPDATEs are captured in full.
-- ============================================================================

begin;

update public.clients set client_code = '294-TCE' where id = 514 and client_code is null;
update public.clients set client_code = '295-NAD' where id = 504 and client_code is null;
update public.clients set client_code = '296-KAT' where id = 517 and client_code is null;
update public.clients set client_code = '297-MAR' where id = 516 and client_code is null;
update public.clients set client_code = '298-PAR' where id = 513 and client_code is null;

commit;
