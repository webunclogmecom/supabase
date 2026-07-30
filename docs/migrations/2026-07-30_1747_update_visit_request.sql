-- 2026-07-30_1747_update_visit_request.sql
--
-- EDITING A QUEUED "TO BE SCHEDULED" REQUEST.
--
-- Fred: "And what if we want to edit the to be scheduled visits?" Until now the only way to change a
-- queued item was Remove + create a new one, which **resets created_at**. That matters: the queue card
-- bolds with a leading "!" at 14 days to surface work going stale, so remove-and-recreate silently
-- launders away the age of a request that has been sitting untouched. Editing preserves it.
--
-- 🛑 THIS MIGRATION PAYS A DEBT THE ORIGINAL ONE WROTE DOWN. `2026-07-30_1156` opted the three child
-- tables OUT of audit, and stated the exact condition for revisiting it:
--     "Accepted because a request is never edited, only created, scheduled or cancelled.
--      **If editing is ever added, opt these in.**"
-- Editing is now being added, so they are opted in HERE, in the same migration, not "later". Without
-- this, someone changing the services on a request would leave **no trace of what they used to be**:
-- the parent's old_row/new_row does not contain child rows, so the audit trail would show a bare
-- updated_at bump against an unchanged-looking parent. That is precisely the shape of gap this
-- workspace keeps getting burned by.
--
-- WHAT IS EDITABLE, and what is deliberately NOT:
--   editable : services (+ per-line prices and descriptions), locations, truck, crew, title, notes,
--              property.
--   NOT      : client_id and job_id. Changing the client makes it a different request, and job_id is
--              validated AGAINST the client, so permitting either invites a mismatched pair that no
--              later guard would catch. Remove and recreate is the honest path there.
--   NOT      : status, converted_visit_id, converted_at, cancel_reason, deleted_at. Those are
--              lifecycle, owned by schedule/cancel, and hand-editing them could break the
--              `visit_requests_converted_iff_scheduled` invariant.
--
-- ⚠ OPEN REQUESTS ONLY. A 'scheduled' request already produced a real row in public.visits; editing it
-- here would silently diverge the queue's memory from the visit that exists, and the visit would NOT
-- be updated (nor pushed to Jobber). Edit the visit in the Calendar drawer instead. A 'cancelled'
-- request is soft-deleted and must stay immutable so the audit trail means something.
--
-- PATCH SEMANTICS, copied from public.edit_calendar_visit so the app calls this the same way it
-- already calls that: a jsonb patch where **key presence** decides. `p_patch ? 'notes'` sets notes
-- (to NULL if the value is null/empty); omitting the key leaves it alone. This is the only shape that
-- can express "clear this field" and "do not touch this field" as different things, which a plain
-- nullable-argument signature cannot.
--
-- Child collections (services / locations / team) are REPLACE-on-presence: if the key is present the
-- set is replaced wholesale, if absent it is untouched. Same as edit_calendar_visit's team branch.
--
-- Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>

BEGIN;
SET LOCAL lock_timeout = '3s';

-- ---------------------------------------------------------------------------
-- 1. Audit the child tables. See the header: this is the debt from 2026-07-30_1156.
-- ---------------------------------------------------------------------------

CREATE TRIGGER audit_visit_request_services
  AFTER INSERT OR UPDATE OR DELETE ON ops.visit_request_services
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

CREATE TRIGGER audit_visit_request_locations
  AFTER INSERT OR UPDATE OR DELETE ON ops.visit_request_locations
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

CREATE TRIGGER audit_visit_request_team
  AFTER INSERT OR UPDATE OR DELETE ON ops.visit_request_team
  FOR EACH ROW EXECUTE FUNCTION audit.log_change();

-- ---------------------------------------------------------------------------
-- 2. The edit RPC.
-- ---------------------------------------------------------------------------

CREATE FUNCTION ops.update_visit_request(p_request_id bigint, p_patch jsonb)
RETURNS ops.visit_requests LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE r ops.visit_requests; v_ids bigint[]; v_bad int; v_locs bigint[]; v_team bigint[];
BEGIN
  SELECT * INTO r FROM ops.visit_requests WHERE id = p_request_id FOR UPDATE;
  IF NOT FOUND OR r.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'update_visit_request: request % not found', p_request_id;
  END IF;
  IF r.status <> 'open' THEN
    RAISE EXCEPTION 'update_visit_request: request % is % and can no longer be edited', p_request_id, r.status;
  END IF;
  IF p_patch IS NULL OR p_patch = '{}'::jsonb THEN RETURN r; END IF;

  -- Refuse loudly rather than silently ignoring a key the caller believed would apply.
  IF p_patch ?| ARRAY['client_id','job_id','status','converted_visit_id','converted_at','deleted_at','cancel_reason'] THEN
    RAISE EXCEPTION 'update_visit_request: client_id, job_id and lifecycle fields are not editable; remove and recreate instead';
  END IF;

  -- Scalars. Key presence decides; an absent key leaves the column untouched.
  UPDATE ops.visit_requests SET
    title       = CASE WHEN p_patch ? 'title'       THEN NULLIF(p_patch->>'title','')      ELSE title END,
    notes       = CASE WHEN p_patch ? 'notes'       THEN NULLIF(p_patch->>'notes','')      ELSE notes END,
    property_id = CASE WHEN p_patch ? 'property_id' THEN (p_patch->>'property_id')::bigint ELSE property_id END,
    vehicle_id  = CASE WHEN p_patch ? 'vehicle_id'  THEN (p_patch->>'vehicle_id')::bigint  ELSE vehicle_id END
  WHERE id = p_request_id;

  -- Services: replace on presence. Validated exactly like create_visit_request.
  IF p_patch ? 'service_line_item_ids' THEN
    SELECT array_agg(x::bigint) INTO v_ids
      FROM jsonb_array_elements_text(p_patch->'service_line_item_ids') AS x;
    IF v_ids IS NULL OR array_length(v_ids,1) IS NULL THEN
      RAISE EXCEPTION 'update_visit_request: at least one service is required';
    END IF;
    SELECT count(*) INTO v_bad FROM unnest(v_ids) x
     WHERE NOT EXISTS (SELECT 1 FROM service_line_items s
                        WHERE s.id = x AND s.reason = 'Service Call' AND s.schedulable AND s.active);
    IF v_bad > 0 THEN
      RAISE EXCEPTION 'update_visit_request: % non Service-Call service(s) supplied', v_bad;
    END IF;

    DELETE FROM ops.visit_request_services WHERE request_id = p_request_id;
    INSERT INTO ops.visit_request_services (request_id, service_line_item_id, seq_no, quantity, unit_price, description)
    SELECT p_request_id, x.id, x.ord::smallint,
           (p_patch -> 'line_item_prices' -> x.id::text ->> 'quantity')::numeric,
           (p_patch -> 'line_item_prices' -> x.id::text ->> 'unit_price')::numeric,
           nullif(btrim(p_patch -> 'line_item_descriptions' ->> x.id::text), '')
      FROM unnest(v_ids) WITH ORDINALITY AS x(id, ord);
  END IF;

  IF p_patch ? 'client_location_ids' THEN
    SELECT array_agg(x::bigint) INTO v_locs
      FROM jsonb_array_elements_text(p_patch->'client_location_ids') AS x;
    DELETE FROM ops.visit_request_locations WHERE request_id = p_request_id;
    IF v_locs IS NOT NULL AND array_length(v_locs,1) IS NOT NULL THEN
      INSERT INTO ops.visit_request_locations (request_id, client_location_id)
      SELECT p_request_id, l FROM unnest(v_locs) l ON CONFLICT DO NOTHING;
    END IF;
  END IF;

  IF p_patch ? 'team_ids' THEN
    SELECT array_agg(x::bigint) INTO v_team
      FROM jsonb_array_elements_text(p_patch->'team_ids') AS x WHERE NULLIF(x,'') IS NOT NULL;
    DELETE FROM ops.visit_request_team WHERE request_id = p_request_id;
    IF v_team IS NOT NULL AND array_length(v_team,1) IS NOT NULL THEN
      INSERT INTO ops.visit_request_team (request_id, employee_id, seq_no)
      SELECT p_request_id, x.id, x.ord::smallint
        FROM unnest(v_team) WITH ORDINALITY AS x(id, ord)
      ON CONFLICT DO NOTHING;
    END IF;
  END IF;

  SELECT * INTO r FROM ops.visit_requests WHERE id = p_request_id;
  RETURN r;
END $$;

-- REVOKE FROM PUBLIC is not enough on this project; default privileges hand out anon/service_role.
REVOKE ALL ON FUNCTION ops.update_visit_request(bigint,jsonb) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION ops.update_visit_request(bigint,jsonb) TO authenticated;

COMMIT;

NOTIFY pgrst, 'reload schema';
