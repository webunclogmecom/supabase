-- Rollback of 2026-11-25_0300_derm_visit_prints.sql (Trello #248). The sheet registers were never changed, so nothing
-- else needs restoring. The apps' printer icon then has nothing to read: ship the apps' rollback first.
begin;
drop view if exists derm.v_visit_prints;
drop function if exists derm.fn_record_prints(bigint[], bigint[], text);
drop table if exists derm.visit_prints;
commit;
