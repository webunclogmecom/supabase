-- 2026-09-22_1825_retire_339cha_billing_twin.sql
--
-- WHY. The handleClient guard shipped earlier today stops a billing twin being created when a live
-- service property already holds the address. It cannot close the BRAND NEW CLIENT case, because the
-- CLIENT webhook runs before the PROPERTY webhook: for 339-CHA the billing row landed at
-- 22:15:52.218Z and the real property at 22:15:52.743Z, half a second later, so at guard time there
-- was nothing to match against. That race is now closed from the other side in handleProperty
-- (deployed 2026-09-22), which retires a same-address twin once the real property exists.
--
-- WHAT. Retires the one twin that was created in the window between the two deploys. Same rules as
-- 2026-09-22_1749: soft-delete, clear is_primary, then promote the surviving service row if the
-- client is left with no primary. Address-matched and client-scoped, so it can only touch that pair.
--
-- RULE 8 (audit): no new table; audit_properties covers it.

DO $$
DECLARE v_twin bigint; v_keep bigint; v_was_primary boolean;
BEGIN
  SELECT b.id, b.is_primary INTO v_twin, v_was_primary
  FROM public.properties b
  JOIN public.clients c ON c.id = b.client_id
  WHERE c.client_code = '339-CHA' AND b.is_billing AND b.deleted_at IS NULL;

  SELECT k.id INTO v_keep
  FROM public.properties k
  JOIN public.clients c ON c.id = k.client_id
  WHERE c.client_code = '339-CHA' AND COALESCE(k.is_billing,false) = false AND k.deleted_at IS NULL
    AND lower(btrim(COALESCE(k.address,''))) = (
      SELECT lower(btrim(COALESCE(b2.address,''))) FROM public.properties b2 WHERE b2.id = v_twin)
  ORDER BY k.id
  LIMIT 1;

  IF v_twin IS NULL OR v_keep IS NULL THEN
    RAISE EXCEPTION 'expected one live billing twin and one same-address service row for 339-CHA, got twin=% keep=%', v_twin, v_keep;
  END IF;

  UPDATE public.properties SET deleted_at = now(), is_primary = false WHERE id = v_twin;

  IF v_was_primary AND NOT EXISTS (
        SELECT 1 FROM public.properties q
        JOIN public.clients c ON c.id = q.client_id
        WHERE c.client_code = '339-CHA' AND q.is_primary AND q.deleted_at IS NULL) THEN
    UPDATE public.properties SET is_primary = true WHERE id = v_keep;
  END IF;

  RAISE NOTICE 'retired twin % , kept %', v_twin, v_keep;
END $$;
