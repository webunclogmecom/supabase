-- Rollback of 2026-11-21_1100_lwt_monthly_sends.sql (Trello #238). Drops the send log and the county address setting.
-- 🛑 The send log is the only record of which Monthly Reports were emailed to the county: export it first
-- (select * from derm.lwt_monthly_sends) into the workspace backups/ folder. Deploy the previous lwt-monthly first, or its
-- send_email action fails on the missing table.
begin;
drop table derm.lwt_monthly_sends;
delete from public.app_config where key = 'lwt_county_email';
commit;
