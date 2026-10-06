// assemble_fix.js <YYYY-MM-DD_HHMM> : the follow-up migration that replaces client.get_client_activity from function.sql.
// The whole body comes from the proven build file (never retyped); the pre-check pins the body applied by 2026-10-06_1736.
const fs = require('fs'), path = require('path');
const name = process.argv[2];
if (!/^\d{4}-\d{2}-\d{2}_\d{4}$/.test(name || '')) { console.error('usage: assemble_fix.js YYYY-MM-DD_HHMM'); process.exit(2); }
const fn = fs.readFileSync(path.join(__dirname, 'function.sql'), 'utf8')
  .replace(/__CFG__/g, 'audit.entity_render_config').replace(/__S__/g, 'audit').replace(/__FN__/g, 'client.get_client_activity');
const sql = `-- ============================================================================
-- ${name} · client.get_client_activity: no summary line under a card; a note is not "edited"
-- ============================================================================
-- Found rendering the round-2 mockup from the live output of 2026-10-06_1736 (112-YA):
--   1. A status card or a cadence card is an INSERT row, so it also got the one-line summary meant for an added
--      record, which rendered as an empty "Contact:" line under the card. Cards now carry no summary line.
--      Smoke case C4 now asserts the card entry has no change lines, and mutation control "cardline" proves it bites.
--   2. A note (public.notes) came back with long = true, which the app renders as "Note edited". A note is new text:
--      long is false and the app wraps it.
-- The whole function body is replaced from scripts/client-app/tests/client_activity/function.sql (the build file the
-- smoke tests run). Nothing else changes: grants are kept by CREATE OR REPLACE (asserted below).
-- Proven: 20/20 smoke cases and 12 mutation controls on the pg_temp copy, then 20/20 on the live function.
-- Rule 8: no table change. ROLLBACK: re-apply the function from 2026-10-06_1736.
-- ============================================================================
BEGIN;
DO $pre$
BEGIN
  IF md5(pg_get_functiondef('client.get_client_activity(bigint,boolean,integer,jsonb)'::regprocedure)) <> 'f89bc700449cb00842d6ff330c63c833' THEN
    RAISE EXCEPTION 'client.get_client_activity changed since 2026-10-06_1736';
  END IF;
END $pre$;

${fn}
DO $verify$
BEGIN
  IF NOT has_function_privilege('authenticated', 'client.get_client_activity(bigint,boolean,integer,jsonb)', 'EXECUTE') THEN RAISE EXCEPTION 'authenticated lost EXECUTE'; END IF;
  IF has_function_privilege('anon', 'client.get_client_activity(bigint,boolean,integer,jsonb)', 'EXECUTE') THEN RAISE EXCEPTION 'anon can execute'; END IF;
  IF has_function_privilege('service_role', 'client.get_client_activity(bigint,boolean,integer,jsonb)', 'EXECUTE') THEN RAISE EXCEPTION 'service_role can execute'; END IF;
  IF position('no summary line under it' in pg_get_functiondef('client.get_client_activity(bigint,boolean,integer,jsonb)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'the new body did not land';
  END IF;
END $verify$;
NOTIFY pgrst, 'reload schema';
COMMIT;
`;
const out = path.join(__dirname, '..', '..', '..', '..', 'docs', 'migrations', `${name}_client_activity_card_line_and_notes.sql`);
fs.writeFileSync(out, sql);
console.log(out, sql.length, 'bytes');
