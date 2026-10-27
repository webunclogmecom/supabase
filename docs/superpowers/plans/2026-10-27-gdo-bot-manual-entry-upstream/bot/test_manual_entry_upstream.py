"""
test_manual_entry_upstream.py -- a hand filing ("Add a report by hand") is
recorded upstream: it carries the identifiers rpa-derm-result needs, and the
FINAL payload (the one with the county email) is what stays cached when the
POST fails.

Drives the REAL live success branch of run_reporter with the production
evidence flags (INLINE_EMAIL_EVIDENCE + LATE_EVIDENCE_LIVE, ruling B) through
a fake portal copied from test_faseM ('full' mode). Asserts behaviour (what
was POSTed, what is in pending_api_results), never source text.

T1..T8 as in the plan; each check is labelled with its test so a red run
says which.
"""
import base64
import json
import os
import re
import sqlite3
import sys
import tempfile
import types
from datetime import datetime, timezone

_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(_HERE)
sys.path.insert(0, _ROOT)
os.environ["DATA_DIR"] = tempfile.mkdtemp(prefix="manual_upstream_")
os.environ["SHADOW_MODE"] = "false"

try:
    import playwright  # noqa: F401
except ImportError:
    _fake = types.ModuleType("playwright.sync_api")
    _fake.sync_playwright = lambda: None
    _fake.TimeoutError = type("TimeoutError", (Exception,), {})
    _pw = types.ModuleType("playwright")
    _pw.sync_api = _fake
    sys.modules["playwright"] = _pw
    sys.modules["playwright.sync_api"] = _fake
try:
    import httpx  # noqa: F401
except ImportError:
    sys.path.insert(0, os.path.join(_HERE, "stubs"))

import config
config.RPA_BOT_KEY = "k"
config.SHADOW_MODE = False
# Production flags (ruling B, Fred 2026-08-19).
config.INLINE_EMAIL_EVIDENCE = True
config.LATE_EVIDENCE_LIVE = True
config.mailbox_ready = lambda: True
config.EMAIL_WAIT_SECONDS = 0
config.EMAIL_POLL_SECONDS = 0

import reporter
import db
import email_waiter
import email_harvester
from derm_email import parse_derm_email
from gmail_client import GmailMessage

FAILS = {}
def check(test, label, cond, extra=None):
    print(("  PASS  " if cond else "  FAIL  ") + f"{test}: {label}"
          + ("" if cond or extra is None else f"  -> {extra}"))
    FAILS.setdefault(test, 0)
    if not cond:
        FAILS[test] += 1


# ---- fake portal (copied from test_faseM: it runs its suite at import) ----
class Loc:
    def __init__(s, sel, page): s.sel = sel; s.page = page
    @property
    def first(s): return s
    def input_value(s): return s.page.email
    def is_visible(s):
        if s.sel == '#MainContent_txtConfirmFacilityEmail': return s.page.confirm_visible
        if s.sel == '#MainContent_rbSelectByLWTPermitNumber': return s.page.logged_in
        return False
    def inner_text(s): return ""
    def check(s): pass
    def click(s, *a, **k): pass
class Page:
    def __init__(s, email, reveal_confirm=True, mode='full', confirm_shown=False):
        s.email = email; s.confirm_visible = confirm_shown; s.reveal = reveal_confirm
        s.mode = mode; s.logged_in = False; s.login_clicked = False
        s.acciones = []
    def goto(s, u): pass
    def wait_for_selector(s, sel, *a, **k): pass
    def press(s, *a, **k): pass
    def click(s, sel, *a, **k):
        if sel == '#MainContent_btnSubmit':
            s.login_clicked = True
            s.logged_in = s.mode == 'full'
    def wait_for_timeout(s, *a): pass
    def select_option(s, *a, **k): pass
    def wait_for_url(s, *a, **k): pass
    def locator(s, sel): return Loc(sel, s)
    def screenshot(s, **k): return b"x"
    def fill(s, sel, val):
        s.acciones.append((sel, val))
        if sel == '#MainContent_txtFacilityEmail':
            if val.lower() != s.email: s.confirm_visible = s.reveal
            s.email = val.lower()
class Ctx:
    def __init__(s, page): s._p = page; s.closed = False
    def set_default_timeout(s, x): pass
    def new_page(s): return s._p
    def close(s): s.closed = True
class Browser:
    def new_context(self): return Ctx(Page(config.PRIMARY_EMAIL))
    def close(self): pass
class PW:
    def __enter__(s):
        class P:
            class chromium:
                @staticmethod
                def launch(**k): return Browser()
        return P
    def __exit__(s, *a): return False
reporter.sync_playwright = lambda: PW()

# ---- mailbox: a real county email from the fixtures ----
EML = open(os.path.join(_HERE, "fixtures", "derm_confirmation_14965.eml"), "rb").read()
CONF = parse_derm_email(EML)
MSG = GmailMessage(gmail_id="g-inline-1", raw=EML,
                   internal_date=datetime(2026, 8, 5, 13, 33, tzinfo=timezone.utc))
WAIT = {"hit": True, "calls": []}
def fake_wait(client, permit, cleaning_date, timeout_s, poll_s, **kw):
    WAIT["calls"].append((permit, cleaning_date))
    return (CONF, MSG.gmail_id, MSG) if WAIT["hit"] else (None, None, None)
email_waiter.wait_for_confirmation = fake_wait
email_harvester._build_client = lambda: object()
email_harvester._save_eml = lambda gid, raw, conf: ""
reporter.slack_notifier.send_immediate_alert = lambda m: True

# ---- upstream: a recorder with a scripted answer ----
POSTS = []
ANSWER = {"value": True, "on_post": None}
def fake_post(payload, max_retries=3):
    POSTS.append(json.loads(json.dumps(payload)))
    if ANSWER["on_post"]:
        ANSWER["on_post"](payload)
    return ANSWER["value"]
reporter.api_client.post_result = fake_post


def reset():
    con = sqlite3.connect(db.DB_PATH)
    for t in ("audit_logs", "pending_api_results", "email_evidence"):
        con.execute(f"DELETE FROM {t}")
    con.commit(); con.close()
    POSTS.clear(); WAIT["calls"].clear()

def pending_rows():
    con = sqlite3.connect(db.DB_PATH)
    con.row_factory = sqlite3.Row
    rows = [dict(r) for r in con.execute(
        "SELECT id, run_id, payload, created_at, retry_count FROM pending_api_results ORDER BY id")]
    con.close()
    for r in rows:
        r["payload"] = json.loads(r["payload"])
    return rows

def ledger_statuses():
    con = sqlite3.connect(db.DB_PATH)
    out = [r[0] for r in con.execute("SELECT status FROM audit_logs ORDER BY id")]
    con.close()
    return out

def run(item, post_ok=True, hit=True, on_post=None):
    POSTS.clear(); WAIT["calls"].clear()
    ANSWER.update(value=post_ok, on_post=on_post)
    WAIT["hit"] = hit
    reporter.run_reporter(items=[dict(item)])
    ANSWER.update(value=True, on_post=None)


# What server._manual_payload builds (server.py:1290-1299).
MANUAL = {"gdo_number": "14965", "ticket_number": "487956", "service_date": "03/25/2025",
          "client_name": "", "dump_ticket_date": "2025-03-28", "dry_run": False,
          "_manual": True, "_manual_by": "yan"}
IDS = {"created_by": "yan", "gdo_number": "14965", "ticket_number": "487956",
       "service_date": "2025-03-25", "dump_date": "2025-03-28"}
ISO = re.compile(r"^\d{4}-\d{2}-\d{2}$")

# rpa-derm-result/index.ts (Supabase repo) ALLOWED_FIELDS (:50-56) and
# MANUAL_ENTRY_FIELDS (:93). docs/API_CONTRACT.md does not list either yet.
ALLOWED_FIELDS = {"visit_id", "manifest_id", "run_id", "status", "retryable", "failure_reason",
                  "attempted_at", "portal_confirmation", "screenshot",
                  "screenshot_missing_reason", "dry_run", "gdo_id", "gdo_number", "manual_entry"}
MANUAL_ENTRY_FIELDS = {"created_by", "why", "gdo_number", "ticket_number", "service_date", "dump_date"}

def has_ids(p):
    me = p.get("manual_entry") or {}
    return {k: me.get(k) for k in IDS} == IDS


print("\n[T1] hand filing, email caught, POST accepted")
reset()
run(MANUAL, post_ok=True, hit=True)
t1 = POSTS[0] if POSTS else {}
check("T1", "exactly one POST", len(POSTS) == 1, len(POSTS))
check("T1", "the email wait ran for the typed permit and date",
      WAIT["calls"] == [("14965", "03/25/2025")], WAIT["calls"])
check("T1", "manual_entry carries exactly the identifiers",
      set((t1.get("manual_entry") or {})) == MANUAL_ENTRY_FIELDS and has_ids(t1)
      and bool((t1.get("manual_entry") or {}).get("why")), t1.get("manual_entry"))
check("T1", "it carries the email image",
      bool(t1.get("screenshot")) and "screenshot_missing_reason" not in t1,
      {k: t1.get(k) for k in ("screenshot_missing_reason",)})
check("T1", "portal_confirmation is the email wording",
      t1.get("portal_confirmation") == reporter.PORTAL_CONF_EMAIL, t1.get("portal_confirmation"))
check("T1", "status SUCCESS, not a dry run",
      t1.get("status") == "SUCCESS" and t1.get("dry_run") is False)
check("T1", "visit_id and manifest_id null, no gdo_id",
      t1.get("visit_id") is None and t1.get("manifest_id") is None and "gdo_id" not in t1)
check("T1", "nothing left in pending_api_results", pending_rows() == [], pending_rows())


print("\n[T2] hand filing, email caught, POST refused")
reset()
SEEN = {}
def age_seed(payload):
    # The seed exists right now (written before the wait). Age it so a
    # delete-and-reinsert is visible: id, created_at and retry_count are the
    # 72 h / 10-retry clocks of the flush.
    con = sqlite3.connect(db.DB_PATH)
    con.execute("UPDATE pending_api_results SET created_at = datetime('now','-1 hour'), "
                "retry_count = 3 WHERE run_id = ?", (payload["run_id"],))
    con.commit(); con.close()
    rows = pending_rows()
    SEEN["seed"] = rows[0] if rows else None
run(MANUAL, post_ok=False, hit=True, on_post=age_seed)
rows = pending_rows()
row = rows[0] if rows else {"payload": {}}
cached = row["payload"]
seed = SEEN.get("seed") or {"payload": {}}
check("T2", "control: the seed (before the POST) had no image",
      "screenshot" not in seed["payload"]
      and seed["payload"].get("screenshot_missing_reason") == "confirmation_email_wait_interrupted",
      seed["payload"].get("screenshot_missing_reason"))
check("T2", "one POST, one pending row, same run_id",
      len(POSTS) == 1 and len(rows) == 1 and POSTS[0].get("run_id") == row.get("run_id"),
      (len(POSTS), len(rows)))
check("T2", "the cached payload is the FINAL one (email image + email wording)",
      bool(cached.get("screenshot")) and cached.get("screenshot") == (POSTS[0] if POSTS else {}).get("screenshot")
      and cached.get("portal_confirmation") == reporter.PORTAL_CONF_EMAIL
      and "screenshot_missing_reason" not in cached,
      {k: cached.get(k) for k in ("portal_confirmation", "screenshot_missing_reason")})
check("T2", "the cached payload carries the identifiers", has_ids(cached), cached.get("manual_entry"))
check("T2", "the row was updated in place: id, created_at, retry_count kept",
      seed.get("id") == row.get("id") and seed.get("created_at") == row.get("created_at")
      and row.get("retry_count") == 3,
      ({k: seed.get(k) for k in ("id", "created_at", "retry_count")},
       {k: row.get(k) for k in ("id", "created_at", "retry_count")}))
T2_RUN = row.get("run_id")


print("\n[T4] the next run's flush after T2")
before = pending_rows()
POSTS.clear()
reporter.run_reporter(items=[])
t4 = [p for p in POSTS if p.get("run_id") == T2_RUN]
check("T4", "the flush POSTs the cached row once, verbatim",
      len(POSTS) == 1 and len(t4) == 1 and before and t4[0] == before[0]["payload"], len(POSTS))
check("T4", "and deletes the row on True", pending_rows() == [], pending_rows())
check("T4", "what it POSTs is the final payload (image + identifiers)",
      bool(t4 and t4[0].get("screenshot")) and bool(t4 and has_ids(t4[0])))


print("\n[T3] QUEUE item, email caught, POST refused: the seed stays (Jon's 5a)")
reset()
QUEUE = {"gdo_number": "GDO-14965", "ticket_number": "487956", "service_date": "2025-03-25",
         "visit_id": 6036, "manifest_id": 1234, "gdo_id": 69, "dry_run": False}
run(QUEUE, post_ok=False, hit=True)
rows = pending_rows()
q = rows[0]["payload"] if rows else {}
check("T3", "control: the final POST carried the email image",
      len(POSTS) == 1 and bool(POSTS[0].get("screenshot")), len(POSTS))
check("T3", "the pending row is still the SEED",
      len(rows) == 1 and "screenshot" not in q
      and q.get("screenshot_missing_reason") == "confirmation_email_wait_interrupted"
      and q.get("portal_confirmation") == reporter.PORTAL_CONF_PLAIN,
      {k: q.get(k) for k in ("screenshot_missing_reason", "portal_confirmation")})
check("T3", "and it is a queue payload (visit, gdo_id, no manual_entry)",
      q.get("visit_id") == 6036 and q.get("gdo_id") == 69 and "manual_entry" not in q)


print("\n[T5] hand filing, dry run: nothing leaves, nothing is cached")
reset()
run(dict(MANUAL, dry_run=True), post_ok=True, hit=True)
check("T5", "control: the dry run reached Preview", ledger_statuses() == ["DRY_RUN_COMPLETE"],
      ledger_statuses())
check("T5", "zero POSTs", POSTS == [], len(POSTS))
check("T5", "zero pending rows", pending_rows() == [], pending_rows())


print("\n[T6] contract: T1's payload against rpa-derm-result")
me = t1.get("manual_entry") or {}
check("T6", "top-level keys within ALLOWED_FIELDS", set(t1) <= ALLOWED_FIELDS and bool(t1),
      set(t1) - ALLOWED_FIELDS)
check("T6", "manual_entry keys within MANUAL_ENTRY_FIELDS", set(me) <= MANUAL_ENTRY_FIELDS and bool(me),
      set(me) - MANUAL_ENTRY_FIELDS)
check("T6", "created_by, gdo_number, ticket_number, service_date all present",
      all(str(me.get(k) or "").strip() for k in ("created_by", "gdo_number", "ticket_number", "service_date")),
      me)
check("T6", "service_date and dump_date are YYYY-MM-DD",
      bool(ISO.match(str(me.get("service_date", "")))) and
      ("dump_date" not in me or bool(ISO.match(str(me["dump_date"])))), me)
check("T6", "never a visit, manifest or gdo_id (the API 400s on any)",
      t1.get("visit_id") is None and t1.get("manifest_id") is None and t1.get("gdo_id") is None)
check("T6", "run_id fits 'manual-bot-' + ^[A-Za-z0-9_.-]{1,86}$",
      bool(re.match(r"^[A-Za-z0-9_.-]{1,86}$", str(t1.get("run_id") or ""))))
_img = base64.b64decode(t1.get("screenshot") or "") if t1.get("screenshot") else b""
check("T6", "the image is a JPEG or PNG (the API sniffs the bytes)",
      _img[:3] == b"\xff\xd8\xff" or _img[:8] == b"\x89PNG\r\n\x1a\n", _img[:8])


print("\n[T7] build_result_payload on hand items: never raises, never forwards raw text")
def bp(**over):
    return reporter.build_result_payload(dict(MANUAL, **over), "r-1", "SUCCESS",
                                         portal_confirmation="x")
cases = [
    ("garbage service date", dict(service_date="not a date"), {"service_date": None}),
    ("empty dump date", dict(dump_ticket_date=""), {"dump_date": None}),
    ("dump date 1/5/2026", dict(dump_ticket_date="1/5/2026"), {"dump_date": "2026-01-05"}),
    ("service date 2025-3-25", dict(service_date="2025-3-25"), {"service_date": "2025-03-25"}),
    ("service date 03/25/2025", dict(service_date="03/25/2025"), {"service_date": "2025-03-25"}),
    ("None dates", dict(service_date=None, dump_ticket_date=None), {"service_date": None, "dump_date": None}),
]
for label, over, want in cases:
    try:
        p = bp(**over); err = None
    except Exception as e:
        p = {}; err = e
    me = p.get("manual_entry")
    ok_case = (err is None and isinstance(me, dict)
               and all((me.get(k) == v) if v else (k not in me) for k, v in want.items())
               and all(ISO.match(me[k]) for k in ("service_date", "dump_date") if k in me))
    check("T7", label, ok_case, err or me)
check("T7", "a queue item carries no manual_entry",
      "manual_entry" not in reporter.build_result_payload(QUEUE, "r-2", "SUCCESS"))


print("\n[T8] hand filing, email missed: posted without image, identifiers on board")
reset()
run(MANUAL, post_ok=True, hit=False)
t8 = POSTS[0] if POSTS else {}
check("T8", "exactly one POST", len(POSTS) == 1, len(POSTS))
check("T8", "no image, reason confirmation_email_not_received",
      "screenshot" not in t8 and t8.get("screenshot_missing_reason") == "confirmation_email_not_received",
      t8.get("screenshot_missing_reason"))
check("T8", "plain wording", t8.get("portal_confirmation") == reporter.PORTAL_CONF_PLAIN)
check("T8", "identifiers present", has_ids(t8), t8.get("manual_entry"))
check("T8", "nothing left cached", pending_rows() == [])


print("\nPER TEST: " + "  ".join(f"{t}={'red' if n else 'green'}" for t, n in sorted(FAILS.items())))
bad = any(FAILS.values())
print("RESULT: " + ("THERE ARE FAILURES" if bad else "ALL OK"))
sys.exit(1 if bad else 0)
