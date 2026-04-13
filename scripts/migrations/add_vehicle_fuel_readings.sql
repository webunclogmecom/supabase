-- ============================================================================
-- Migration: vehicle_fuel_readings + webhook_events_log
-- ============================================================================
-- Purpose:
--   1. vehicle_fuel_readings — Time-series fuel data from Samsara (3NF)
--      Append-only immutable facts: "at time T, vehicle V had fuel level X"
--      FK to vehicles(id). No updated_at (readings are never modified).
--   2. webhook_events_log — Audit trail for incoming webhook events
--      30-day retention; debugging only.
-- ============================================================================

-- ============================================================================
-- 1. vehicle_fuel_readings — Samsara fuel telemetry (3NF, time-series)
-- ============================================================================
-- 3NF rationale: 1:N from vehicles → fuel readings. Each reading is an
-- independent observation. No transitive deps.  fuel_gallons is pre-computed
-- from percent × tank_capacity at write time (snapshot; tank_capacity could
-- change if a truck is refitted).
--
-- Retention: Keep ~90 days of readings.  Cron job or pg_cron deletes older.
-- At 3 vehicles × 1 reading/10min = ~13K rows/month — negligible storage.

CREATE TABLE IF NOT EXISTS vehicle_fuel_readings (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id      bigint       NOT NULL REFERENCES vehicles(id) ON DELETE CASCADE,
  fuel_percent    numeric(5,2),          -- 0.00 – 100.00
  fuel_gallons    numeric(8,2),          -- percent × tank_capacity / 100 at write time
  odometer_meters bigint,                -- vehicle odometer at reading time (Samsara reports meters)
  engine_state    text,                  -- 'On' | 'Off' | 'Idle' (if available)
  recorded_at     timestamptz  NOT NULL, -- Samsara observation timestamp
  created_at      timestamptz  DEFAULT now()
);

COMMENT ON TABLE  vehicle_fuel_readings IS 'Append-only Samsara fuel telemetry. 3NF: one vehicle → many readings.';
COMMENT ON COLUMN vehicle_fuel_readings.fuel_gallons IS 'Pre-computed snapshot: fuel_percent × vehicles.tank_capacity_gallons / 100 at write time.';
COMMENT ON COLUMN vehicle_fuel_readings.odometer_meters IS 'Samsara reports odometer in meters.  Divide by 1609.34 for miles.';

-- Primary access pattern: "latest reading per vehicle" + time-range queries
CREATE INDEX IF NOT EXISTS idx_vfr_vehicle_time
  ON vehicle_fuel_readings (vehicle_id, recorded_at DESC);

-- Cleanup / retention queries
CREATE INDEX IF NOT EXISTS idx_vfr_recorded
  ON vehicle_fuel_readings (recorded_at);

-- Trigger: no updated_at trigger — readings are immutable.


-- ============================================================================
-- 2. webhook_events_log — Audit trail for webhook processing
-- ============================================================================
-- Lightweight debug table. Not a business table — no entity_source_links.
-- 30-day retention via scheduled cleanup.

CREATE TABLE IF NOT EXISTS webhook_events_log (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_system   text         NOT NULL,   -- 'jobber' | 'airtable' | 'samsara'
  event_type      text         NOT NULL,   -- e.g. 'CLIENT_CREATE', 'record.changed', 'AddressCreated'
  event_id        text,                    -- source-provided idempotency key (if any)
  payload         jsonb,                   -- raw webhook payload (truncated if >64KB)
  entity_type     text,                    -- 'client' | 'visit' | etc. (resolved entity)
  entity_id       bigint,                  -- resolved DB id (NULL if failed)
  status          text         DEFAULT 'received',  -- received | processed | failed | skipped
  error_message   text,
  processing_ms   integer,                 -- wall-clock processing time
  processed_at    timestamptz,
  created_at      timestamptz  DEFAULT now()
);

COMMENT ON TABLE webhook_events_log IS 'Webhook audit trail. 30-day retention. Not a business table.';

CREATE INDEX IF NOT EXISTS idx_wel_source_time
  ON webhook_events_log (source_system, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_wel_status
  ON webhook_events_log (status) WHERE status = 'failed';


-- ============================================================================
-- 3. webhook_tokens — OAuth token cache for webhook re-query flows
-- ============================================================================
-- Jobber webhooks are "thin notifications" (just event + GID). The handler
-- must re-query Jobber's GraphQL API for full data, which requires a valid
-- OAuth access token.  Tokens expire every 2h.  This table caches refreshed
-- tokens so Edge Functions can self-refresh without human intervention.
-- Jobber sunsets May 2026 — this table can be dropped after.

CREATE TABLE IF NOT EXISTS webhook_tokens (
  source_system   text PRIMARY KEY,     -- 'jobber' | 'airtable' | 'samsara'
  access_token    text NOT NULL,
  refresh_token   text,
  client_id       text,
  client_secret   text,
  expires_at      timestamptz,
  updated_at      timestamptz DEFAULT now()
);

COMMENT ON TABLE webhook_tokens IS 'OAuth token cache for webhook handlers. Jobber tokens expire every 2h; refreshed in-place by Edge Functions.';


-- ============================================================================
-- 4. Convenience view: latest fuel reading per vehicle
-- ============================================================================
CREATE OR REPLACE VIEW v_vehicle_fuel_latest AS
SELECT DISTINCT ON (vfr.vehicle_id)
  vfr.vehicle_id,
  v.name              AS vehicle_name,
  vfr.fuel_percent,
  vfr.fuel_gallons,
  v.tank_capacity_gallons,
  vfr.odometer_meters,
  vfr.engine_state,
  vfr.recorded_at,
  ROUND(EXTRACT(EPOCH FROM (now() - vfr.recorded_at)) / 60)  AS minutes_ago
FROM vehicle_fuel_readings vfr
JOIN vehicles v ON v.id = vfr.vehicle_id
ORDER BY vfr.vehicle_id, vfr.recorded_at DESC;

COMMENT ON VIEW v_vehicle_fuel_latest IS 'Latest fuel reading per vehicle. One row per tracked vehicle.';
