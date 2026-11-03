-- ROLLBACK of 2026-11-03_1345_dump_go_one_dump_per_run.
-- ORDER: first redeploy dump-visit-create from the commit before the dump_go change (its create then runs its own
-- 90-minute check and calls create_dump_visit again), THEN run this. Dropping the function while the deployed edge
-- function still calls it makes every GO fail with "could not create the visit".
-- Visits already claimed or joined keep their times and notes; nothing here moves them back.
begin;
drop function if exists public.dump_go(bigint, bigint, bigint, bigint, bigint, bigint, text, boolean, boolean);
commit;
