-- 2026-08-19_0130_access_schedule_shape_check.sql
--
-- WHAT: a CHECK constraint pinning the SHAPE of public.properties.access_schedule (jsonb):
--       every day entry must carry `open` and `close` as 24-hour "HH:MM" strings.
--
-- WHY: Fred asked whether access hours should be stored 24h or 12h. 24h is the only sensible
--      store (12h sorts wrong lexically, needs parsing on every read, is locale-dependent, and
--      breaks the ::time casts queries use); the 12h conversion belongs in the display layer and
--      shipped there on 2026-08-18. This constraint makes the storage format GUARANTEED rather
--      than merely OBSERVED.
--
-- WHY IT IS NOT REDUNDANT WITH THE RPC. `client.update_property_operational` is the ONLY function
--      that writes this column and it already validates object-ness, day keys, and both times
--      against the identical regex. This constraint is not for that path -- it is for the BYPASS
--      path. Direct SQL is not hypothetical here: `app_source='sql'` was the single largest writer
--      in audit.logs over the preceding 12 hours (314 rows). A migration, a script or a console
--      query can write this column without ever touching the RPC.
--
-- ⚠ THE REGEX IS DELIBERATELY DUPLICATED between this constraint and
--      `client.update_property_operational`. That is a known drift risk, accepted because the two
--      serve different callers. **If you change one, change the other in the same commit.**
--      The RPC keeps the richer job: it also validates the DAY KEYS (mon..sun) and returns a
--      readable `22023` instead of a raw constraint violation. This constraint deliberately does
--      NOT validate keys -- a set-returning function (jsonb_object_keys) cannot appear in a CHECK,
--      and expressing it in jsonpath would trade real readability for a case the RPC already
--      covers and which does not corrupt rendering.
--
-- SHAPE ACCEPTED (verified, 17-case truth table, all correct):
--      NULL - empty object - same-day - OVERNIGHT (open > close, 76% of live data)
--      - the 00:00-00:00 "All day" sentinel (222 visits / 32 properties)
-- SHAPE REJECTED:
--      12h "9:00 AM" (the guard) - hour 25 - minute 75 - single-digit hour - truncated minutes
--      - json null - missing key - number instead of string - "HH:MM:SS" - array - one bad day
--        among otherwise good ones
--
-- SAFETY: measured before applying -- 901 properties, 702 NULL, 199 with a schedule,
--      **0 would fail**. Applied VALIDATED (not NOT VALID) precisely because the table is clean;
--      a NOT VALID constraint here would be weaker for no benefit.
--
-- AUDIT (rule 8): no change. This adds a constraint only; `public.properties` keeps whatever
--      audit triggers it already had. No new table, no new column, no new function, no grant change.
--
-- jsonb_path_exists(jsonb, jsonpath) is IMMUTABLE (provolatile='i') and therefore legal in a CHECK.
-- Its _tz sibling is STABLE and must NOT be used here.

alter table public.properties
  add constraint properties_access_schedule_shape_chk
  check (
    access_schedule is null
    or (
      jsonb_typeof(access_schedule) = 'object'
      and not jsonb_path_exists(access_schedule,
        '$.* ? (@.open.type() != "string" || @.close.type() != "string"
                || !(@.open  like_regex "^([01][0-9]|2[0-3]):[0-5][0-9]$")
                || !(@.close like_regex "^([01][0-9]|2[0-3]):[0-5][0-9]$"))')
    )
  );

comment on constraint properties_access_schedule_shape_chk on public.properties is
  'access_schedule day entries must carry open/close as 24h "HH:MM" strings. Overnight (open > close) is legal and is 76% of live data. Regex duplicated in client.update_property_operational - change both together.';
