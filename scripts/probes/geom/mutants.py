import io
F = 'docs/migrations/2026-09-02_0200_geometry_violation_hints.sql'
t = io.open(F, encoding='utf-8').read()

# MUTANT A: the precondition arm swallows G9 for EVERY page, measured or not.
# VERIFY 2 must catch this: it is the difference between fixing the noise and disabling the guard.
a_old = """  IF NOT EXISTS (
    SELECT 1 FROM derm.v_page_printed_rules pr
     WHERE pr.dump_folder = p_dump_folder AND pr.effective_page = p_effective_page
       AND pr.kind IN ('boundary','divider')
  ) THEN"""
a_new = """  IF TRUE THEN"""
assert t.count(a_old) == 1, 'mutant A anchor %d' % t.count(a_old)
io.open('scripts/probes/geom/mA.sql', 'w', encoding='utf-8', newline='\n').write(t.replace(a_old, a_new))

# MUTANT B: one guard loses its hint, falling through to the loud ELSE. VERIFY 3 must catch it.
b_old = "    WHEN 'G9_NOT_MEASURED' THEN"
b_new = "    WHEN 'G9_NOT_MEASURED_TYPO' THEN"
assert t.count(b_old) == 1, 'mutant B anchor %d' % t.count(b_old)
io.open('scripts/probes/geom/mB.sql', 'w', encoding='utf-8', newline='\n').write(t.replace(b_old, b_new))

# MUTANT C: the DROP + CREATE happens but the re-grant is forgotten. VERIFY 4 must catch it.
c_old = """GRANT EXECUTE ON FUNCTION derm.check_page_geometry(text, integer, jsonb, numeric, numeric)
  TO authenticated, service_role;"""
c_new = "-- re-grant deliberately omitted for the mutation test"
assert t.count(c_old) == 1, 'mutant C anchor %d' % t.count(c_old)
io.open('scripts/probes/geom/mC.sql', 'w', encoding='utf-8', newline='\n').write(t.replace(c_old, c_new))

print('3 mutants written')
