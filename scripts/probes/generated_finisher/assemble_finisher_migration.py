# Assembles docs/migrations/2026-09-14_0615_generated_sheet_finisher.sql: replaces its three body
# markers with the LIVE pg_get_functiondef output patched by anchored replacement (each anchor
# asserted to occur exactly once), and its fixture marker with the Phase 0 detector lines.
# USE: python scripts/probes/generated_finisher/assemble_finisher_migration.py [fixture-key]
#      fixture-key defaults to ticket-834742_p2 (a key of phase0_calibration.json -> lines)
import json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.abspath(os.path.join(here, '..', '..', '..'))
mig = os.path.join(root, 'docs', 'migrations', '2026-09-14_0615_generated_sheet_finisher.sql')
fixture = sys.argv[1] if len(sys.argv) > 1 else 'ticket-834742_p2'

defs = {r['k']: r['def'] for r in json.load(open(os.path.join(here, 'finisher_defs.out.json'), encoding='utf-8'))}
lines = json.load(open(os.path.join(here, 'phase0_calibration.json'), encoding='utf-8'))['lines'][fixture]['lines']
if len(lines) < 6: sys.exit(f'{fixture}: only {len(lines)} lines')

def patch(body, pairs, name):
    for old, new in pairs:
        n = body.count(old)
        if n != 1: sys.exit(f'{name}: anchor occurs {n} times, expected 1:\n{old}')
        body = body.replace(old, new)
    return body.rstrip() + ';'

actor = patch(defs['_actor'], [
    ("DECLARE\n  v_email text;\nBEGIN\n  BEGIN\n    v_email := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email';\n  EXCEPTION WHEN others THEN\n    v_email := NULL;\n  END;\n",
     "DECLARE\n  v_email text;\n  v_role  text;\nBEGIN\n  BEGIN\n    v_email := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email';\n    v_role  := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role';\n  EXCEPTION WHEN others THEN\n    v_email := NULL;\n    v_role  := NULL;\n  END;\n"
     "  -- 2026-09-14: a service_role caller with no email is a machine (the generated-sheet finisher\n"
     "  -- writes bands and extents through save_page_geometry as service_role). Fred, 2026-09-14:\n"
     "  -- everything machine-made carries the one label. A person's JWT still wins below, and direct\n"
     "  -- SQL (no JWT at all) still gets p_default.\n"
     "  IF v_role = 'service_role' AND nullif(v_email, '') IS NULL THEN\n    RETURN 'stamp-studio-ai';\n  END IF;\n"),
], '_actor')

key = patch(defs['_require_stamp_key'], [
    ("DECLARE v_headers text; v_key text;", "DECLARE v_headers text; v_key text; v_role text;"),
    ("  v_key := v_headers::jsonb->>'x-stamp-key';",
     "  -- 2026-09-14: a service_role request (the generated-sheet finisher: edge fn -> PostgREST) is\n"
     "  -- let through. That key already writes every table directly; the Studio's header key was\n"
     "  -- never a barrier to it, only to a browser holding the anon or a user key.\n"
     "  BEGIN\n    v_role := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role';\n"
     "  EXCEPTION WHEN others THEN\n    v_role := NULL;\n  END;\n"
     "  IF v_role = 'service_role' THEN\n    RETURN;\n  END IF;\n"
     "  v_key := v_headers::jsonb->>'x-stamp-key';"),
], '_require_stamp_key')

detail = patch(defs['fn_sheet_publishable_detail'], [
    ("  ), agg AS (\n    SELECT (SELECT blocker FROM code) AS blocker,\n",
     "  ), fin AS (\n"
     "    -- 2026-09-14: the generated-sheet finisher's latest reason for a page still needing geometry,\n"
     "    -- so the banner says WHY the sheet was not measured automatically (plain words, from the\n"
     "    -- ledger derm.generated_measure_attempts).\n"
     "    SELECT string_agg('Page ' || a.page || ' could not be measured automatically: ' || a.last_reason,\n"
     "                      ' ' ORDER BY a.page) AS reasons\n"
     "      FROM derm.generated_measure_attempts a\n"
     "     WHERE a.dump_folder = p_dump_folder\n"
     "       AND a.last_outcome IN ('refused', 'error')\n"
     "       AND a.last_reason IS NOT NULL\n"
     "       AND a.page IN (SELECT pg FROM need_band UNION SELECT pg FROM need_ext)\n"
     "  ), agg AS (\n    SELECT (SELECT blocker FROM code) AS blocker,\n"
     "           (SELECT reasons FROM fin) AS finisher_reasons,\n"),
    ("    'pages_needing_extent', to_jsonb(a.pages_ext),\n",
     "    'pages_needing_extent', to_jsonb(a.pages_ext),\n    'finisher_reasons', a.finisher_reasons,\n"),
    ("          THEN 'Page ' ||\n               array_to_string(",
     "          THEN coalesce(a.finisher_reasons || ' ', '') || 'Page ' ||\n               array_to_string("),
], 'fn_sheet_publishable_detail')

src = open(mig, encoding='utf-8').read()
for marker, body in [('@@ACTOR_BODY@@', actor), ('@@STAMP_KEY_BODY@@', key), ('@@PUBLISHABLE_DETAIL_BODY@@', detail),
                     ('@@LINES_834742_P2@@', json.dumps(lines))]:
    if src.count(marker) != 1: sys.exit(f'marker {marker} occurs {src.count(marker)} times in the migration')
    src = src.replace(marker, body)
with open(mig, 'w', encoding='utf-8', newline='\n') as f:
    f.write(src)
print('assembled', mig, 'fixture', fixture, 'lines', len(lines))
