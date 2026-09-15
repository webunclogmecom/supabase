# Assembles docs/migrations/2026-09-15_1045_client_service_options_hide_destroyed_jobs.sql from the
# LIVE pg_get_viewdef(..., false) body of ops.client_service_options (dumped seconds before into the
# file named by argv[1]; its md5 is pinned in the migration's PRE block), patched by ONE anchored
# insert asserted to occur exactly once. Nothing is retyped (CLAUDE.md, CREATE OR REPLACE rule).
# USE: python scripts/probes/assemble_cso_migration.py <path-to-live-viewdef.sql>
import os, sys
root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
mig = os.path.join(root, 'docs', 'migrations', '2026-09-15_1045_client_service_options_hide_destroyed_jobs.sql')
if len(sys.argv) < 2:
    sys.exit('usage: assemble_cso_migration.py <path-to-live-viewdef.sql>')

body = open(sys.argv[1], encoding='utf-8').read().rstrip().rstrip(';')
anchor = "WHERE ((j.job_status <> 'archived'::text) AND"
if body.count(anchor) != 1:
    sys.exit(f'anchor occurs {body.count(anchor)} times, expected 1')
patched = body.replace(anchor, "WHERE ((j.job_status <> 'archived'::text) AND (j.job_status <> 'destroyed'::text) AND")
if patched.count("'destroyed'") != 1:
    sys.exit('patched body does not carry exactly one destroyed predicate')

src = open(mig, encoding='utf-8').read()
if src.count('@@VIEW_BODY@@') != 1:
    sys.exit('marker occurs %d times in the migration' % src.count('@@VIEW_BODY@@'))
open(mig, 'w', encoding='utf-8', newline='\n').write(src.replace('@@VIEW_BODY@@', patched))
print('assembled', mig)
