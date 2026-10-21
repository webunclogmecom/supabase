-- Rollback for 2026-10-21_0145_hr_access_shared_read_gate.sql
-- Step 1 is the kill switch on its own: it stops the gate on the next request, no deploy.
alter role authenticator reset pgrst.db_pre_request;
notify pgrst, 'reload config';

-- Step 2 (only after step 1 is confirmed: a REST response no longer carries x-access-gate):
BEGIN;
drop function if exists public.fn_request_gate();
drop function if exists hr.fn_any_app_open(boolean);
COMMIT;
