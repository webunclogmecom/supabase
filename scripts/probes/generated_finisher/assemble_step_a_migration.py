# Assembles docs/migrations/2026-09-14_0810_finisher_places_cards_awaiting_page_map.sql from LIVE
# pg_get_functiondef bodies dumped seconds before (t12.out.json = public.fn_request_generated_measure,
# t15.out.json = derm.fn_sheet_publishable), each patched by ONE anchored replacement asserted to
# occur exactly once. Nothing is retyped (CLAUDE.md, CREATE OR REPLACE rule).
# USE: python scripts/probes/generated_finisher/assemble_step_a_migration.py
import json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.abspath(os.path.join(here, '..', '..', '..'))
mig = os.path.join(root, 'docs', 'migrations', '2026-09-14_0810_finisher_places_cards_awaiting_page_map.sql')

def patched_body(dump, anchor, replacement, name):
    body = json.load(open(os.path.join(here, dump), encoding='utf-8'))[0]['def']
    if body.count(anchor) != 1:
        sys.exit(f'{name}: anchor occurs {body.count(anchor)} times, expected 1')
    out = body.replace(anchor, replacement).rstrip() + ';'
    if not out.rstrip(';').rstrip().endswith('$function$'):
        sys.exit(f'{name}: patched body does not end with $function$')
    return out

# 1. the cron wrapper: the placement step runs first
w_anchor = "  -- 1. completion first: no HTTP, and a generated sheet a person measured by hand completes here\n"
wrapper = patched_body('t12.out.json', w_anchor,
    "  -- 0. (2026-09-14, Step A) place the cards a late sheet-number read left unplaced, only where\n"
    "  --    the row OCR confirms the client on that printed row. No HTTP.\n"
    "  PERFORM derm.fn_place_cards_awaiting_page_map(20);\n\n" + w_anchor,
    'fn_request_generated_measure')

# 2. fn_sheet_publishable: a derived band on a page that already has an extent is not publishable
p_anchor = "        THEN 'needs_extent'\n      ELSE NULL\n    END);"
publishable = patched_body('t15.out.json', p_anchor,
    "        THEN 'needs_extent'\n"
    "      -- 4. (2026-09-14) a stamped card whose band is still the stamp-midpoint heuristic on a page\n"
    "      --    that HAS an extent. An extent opens the gate onto whatever bands exist (2026-08-19), and\n"
    "      --    a stamp cleared and placed again arrives with no band, so this is the one shape the\n"
    "      --    blocked-sheets view cannot see: it reports derived bands only on pages WITHOUT an extent.\n"
    "      --    Measured at install: 3 pages estate-wide (ticket-831102 p1+p2, ticket-831325 p1, the dark\n"
    "      --    scans of 2026-08-20), all completed and serving; they stay completed and are refused only\n"
    "      --    if re-completed unmeasured, which is the rule.\n"
    "      WHEN EXISTS (SELECT 1 FROM derm.address_row_map r\n"
    "                    WHERE r.dump_folder = p_dump_folder AND r.stamp_y_pct IS NOT NULL\n"
    "                      AND (r.band_y0_pct IS NULL OR r.band_y1_pct IS NULL))\n"
    "        THEN 'needs_snap_then_extent'\n"
    "      ELSE NULL\n    END);",
    'fn_sheet_publishable')

src = open(mig, encoding='utf-8').read()
for marker, body in [('@@WRAPPER_BODY@@', wrapper), ('@@PUBLISHABLE_BODY@@', publishable)]:
    if src.count(marker) != 1:
        sys.exit(f'marker {marker} occurs {src.count(marker)} times in the migration')
    src = src.replace(marker, body)
open(mig, 'w', encoding='utf-8', newline='\n').write(src)
print('assembled', mig)
