"""Apply each mutant M1..M8 to a COPY of the changed tree, one at a time, and run the new suite.
A mutant is killed when the suite exits non-zero (a timeout counts as killed). Usage: python mutate.py [M5 extra]"""
import os, re, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "repo")
MUT = os.path.join(HERE, "mut")

MUTANTS = {
    "M1 drop the identifiers": ("reporter.py", '''        entry = {
            "created_by": str(item.get("_manual_by") or "unknown"),
            "why": "entered by hand on the dashboard; no upstream visit",
            "gdo_number": normalize_permit(item.get("gdo_number")),
            "ticket_number": str(item.get("ticket_number") or "").strip(),
        }
        for key, raw in (("service_date", item.get("service_date")), ("dump_date", item.get("dump_ticket_date"))):
            iso = _manual_iso(raw)
            if iso:
                entry[key] = iso
''', '''        entry = {
            "created_by": str(item.get("_manual_by") or "unknown"),
            "why": "entered by hand on the dashboard; no upstream visit",
        }
'''),
    "M2 forward the raw service_date": ("reporter.py",
        '            iso = _manual_iso(raw)\n',
        '            iso = _manual_iso(raw) if key != "service_date" else (str(raw or "").strip() or None)\n'),
    "M3 replace=False at the manual call": ("reporter.py",
        '                                                   replace=True)',
        '                                                   replace=False)'),
    "M4 drop the _manual condition": ("reporter.py",
        "                        if item.get('_manual'):\n                            # PLAN_INLINE_EVIDENCE",
        "                        if True:\n                            # PLAN_INLINE_EVIDENCE"),
    "M5 delete the guard in _post_and_cache": ("reporter.py",
        '''    if payload.get("manual_entry"):
        log.info("Manual entry -- not posting upstream (no visit to settle): "
                 f"run {payload.get('run_id')}")
        return
''', ''),
    "M6 _manual_iso raises on garbage": ("reporter.py",
        '    return datetime.strptime(mdY, "%m/%d/%Y").strftime("%Y-%m-%d") if mdY else None\n',
        '    if not mdY:\n        raise ValueError(text)\n    return datetime.strptime(mdY, "%m/%d/%Y").strftime("%Y-%m-%d")\n'),
    "M7 add client_name to manual_entry": ("reporter.py",
        '        payload["manual_entry"] = entry\n',
        '        entry["client_name"] = str(item.get("client_name") or "")\n        payload["manual_entry"] = entry\n'),
    "M8 INSERT OR REPLACE": ("db.py",
        '''            c.execute(\'\'\'INSERT INTO pending_api_results (run_id, payload) VALUES (?, ?)
                         ON CONFLICT(run_id) DO UPDATE SET payload = excluded.payload\'\'\',''',
        '''            c.execute(\'\'\'INSERT OR REPLACE INTO pending_api_results (run_id, payload) VALUES (?, ?)\'\'\','''),
}

def run(cmd):
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    try:
        p = subprocess.run(cmd, cwd=MUT, capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=300, env=env)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return "timeout", ""

only = sys.argv[1:] and sys.argv[1]
extra = sys.argv[2:]
for name, (fname, old, new) in MUTANTS.items():
    if only and not name.startswith(only):
        continue
    shutil.rmtree(MUT, ignore_errors=True)
    shutil.copytree(SRC, MUT, ignore=shutil.ignore_patterns(".git"))
    path = os.path.join(MUT, fname)
    s = open(path, encoding="utf-8").read()
    n = s.count(old)
    if n != 1:
        print(f"{name}: ANCHOR count {n} -- not applied"); continue
    open(path, "w", encoding="utf-8", newline="").write(s.replace(old, new))
    code, out = run([sys.executable, "tests/test_manual_entry_upstream.py"])
    per = re.findall(r"PER TEST: (.*)", out)
    red = [t for t in (per[0].split() if per else []) if t.endswith("=red")]
    tb = "Traceback" in out
    line = f"{name}: suite exit={code} -> {'KILLED' if code != 0 else 'SURVIVED'}; red={red}{' (traceback)' if tb else ''}"
    for suite in extra:
        c2, o2 = run([sys.executable, f"tests/{suite}.py"])
        line += f"; {suite} exit={c2} fails={o2.count(' FAIL ')}"
    print(line, flush=True)
shutil.rmtree(MUT, ignore_errors=True)
