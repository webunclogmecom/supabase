#!/usr/bin/env python3
# ============================================================================
# missing_sc_report.py — "Clients Missing a Current Service Call (SC) Job" PDF
# ----------------------------------------------------------------------------
# Companion to sa_status_report.py. Lists active/recurring coded clients that
# have NO open, non-[OLD] "Service Call" job in Jobber -- i.e. their reusable
# Service Call container was never (re)created after the SA/Service-Call
# restructure, or is still sitting as an [OLD]/archived job (the 233-AH case).
# Each row links straight to the client's Jobber page so ops can create/fix the
# Service Call job.
#
# "current SC job" predicate (mirror of sa_status_report.py's has_sc):
#     title ILIKE 'Service Call%' AND job_status <> 'archived' AND title NOT ILIKE '%[OLD]%'
#
# Reads Prod via the Supabase Management API (SUPABASE_PAT + SUPABASE_PROJECT_ID
# from ../../.env — gitignored; no secrets in this file, the repo is public).
# Read-only. Requires reportlab.
#
# Usage:  python scripts/reports/missing_sc_report.py    # -> ~/Downloads/Clients_Missing_SC_<today>.pdf
# ============================================================================
import os, sys, json, argparse, datetime, base64, urllib.request
from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.units import inch
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.platypus import SimpleDocTemplate, Paragraph, Table, TableStyle, Spacer

def load_env(path):
    env = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line: continue
            k, v = line.split("=", 1); env[k.strip()] = v.strip().strip('"').strip("'")
    return env

ENV = load_env(os.path.join(os.path.dirname(__file__), "..", "..", ".env"))
PAT = ENV["SUPABASE_PAT"]; PROJECT = ENV["SUPABASE_PROJECT_ID"]

def pg(sql):
    req = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{PROJECT}/database/query",
        data=json.dumps({"query": sql}).encode(),
        headers={"Authorization": f"Bearer {PAT}", "Content-Type": "application/json",
                 "User-Agent": "unclogme-missing-sc-report/1.0"}, method="POST")
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.loads(r.read().decode())
    if not isinstance(out, list): raise RuntimeError(f"query failed: {json.dumps(out)[:300]}")
    return out

# active/recurring coded clients with NO open, non-[OLD] Service Call job
Q_MISSING_SC = """
WITH base AS (
  SELECT c.id, c.client_code, c.name, c.status,
    (SELECT esl.source_id FROM entity_source_links esl
       WHERE esl.entity_type='client' AND esl.source_system='jobber' AND esl.entity_id=c.id LIMIT 1) AS gid
  FROM clients c
  WHERE c.client_code IS NOT NULL AND c.status IN ('ACTIVE','RECURRING')
    AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.client_id=c.id
        AND j.title ILIKE 'Service Call%' AND j.job_status<>'archived' AND j.title NOT ILIKE '%[OLD]%')
)
SELECT b.*,
  EXISTS (SELECT 1 FROM jobs j WHERE j.client_id=b.id
     AND j.title ILIKE 'Service Agreement%' AND j.job_status<>'archived' AND j.title NOT ILIKE '%[OLD]%') AS has_current_sa,
  (SELECT max(v.visit_date) FROM visits v WHERE v.client_id=b.id AND v.deleted_at IS NULL AND v.visit_status='completed') AS last_visit,
  (SELECT json_agg(json_build_object('n',j.job_number,'t',j.title,'s',j.job_status) ORDER BY j.job_number)
     FROM jobs j WHERE j.client_id=b.id AND j.title ILIKE 'Service Call%') AS sc_jobs
FROM base b ORDER BY b.client_code"""

def jobber_client_url(gid):
    if not gid: return None
    try:
        num = base64.b64decode(gid).decode().split("/")[-1]
        return f"https://secure.getjobber.com/clients/{num}"
    except Exception:
        return None

def sc_summary(sc_jobs):
    if not sc_jobs: return "none"
    parts = []
    for j in sc_jobs:
        tag = " [OLD]" if "[old]" in (j.get("t") or "").lower() else ""
        parts.append(f"#{j['n']} {j['s']}{tag}")
    return "; ".join(parts)

NAVY = colors.HexColor("#1f3a5f"); GREY = colors.HexColor("#666666"); LIGHT = colors.HexColor("#eef2f7"); LINK = colors.HexColor("#1c5779")
styles = getSampleStyleSheet()
h_title = ParagraphStyle("t", parent=styles["Title"], fontSize=18, textColor=NAVY, spaceAfter=2)
h_sub = ParagraphStyle("s", parent=styles["Normal"], fontSize=9, textColor=GREY, spaceAfter=2)
h_note = ParagraphStyle("n", parent=styles["Normal"], fontSize=8.5, textColor=GREY, spaceAfter=8, leading=11)
cell = ParagraphStyle("c", parent=styles["Normal"], fontSize=8.5, leading=10)
cellb = ParagraphStyle("cb", parent=cell, fontName="Helvetica-Bold")
def P(t, st=cell): return Paragraph("" if t is None else str(t), st)

def build(out_path, report_date):
    rows = pg(Q_MISSING_SC)
    table_rows = []
    for r in rows:
        url = jobber_client_url(r.get("gid"))
        name = (r.get("name") or "").replace("&", "&amp;")
        name_cell = Paragraph(f'<a href="{url}" color="#1c5779"><u>{name}</u></a>' if url else name, cell)
        link_cell = Paragraph(f'<a href="{url}" color="#1c5779"><u>open</u></a>' if url else "-", cell)
        table_rows.append([
            P(r.get("client_code"), cellb), name_cell, P(r.get("status")),
            P("Yes" if r.get("has_current_sa") else "No"),
            P(r.get("last_visit") or "-"),
            P(sc_summary(r.get("sc_jobs"))),
            link_cell,
        ])

    story = [
        P("Unclogme LLC — Clients Missing a Current Service Call Job", h_title),
        P(f"Generated {report_date} &nbsp;|&nbsp; verified against live Jobber", h_sub),
        Spacer(1, 6),
        P(f"{len(rows)} active/recurring client(s) with a client code have NO open Service Call job in Jobber "
          f"(no job titled 'Service Call' that is non-archived and not tagged [OLD]). Their reusable Service Call "
          f"container was never recreated after the restructure, or is still an [OLD]/archived job. Click a client "
          f"to open it in Jobber and create/fix the Service Call job. Context columns: <b>SA?</b> = has a current "
          f"Service Agreement (recurring coverage) even without an SC; <b>Existing SC jobs</b> = any Service-Call-"
          f"titled jobs and their status.", h_note),
        mktable(),
    ]

    def _mk():
        headers = ["Code", "Client (→ Jobber)", "Status", "SA?", "Last visit", "Existing SC jobs", "Link"]
        data = [[P(h, cellb) for h in headers]] + table_rows
        t = Table(data, colWidths=[0.6*inch, 2.15*inch, 0.7*inch, 0.4*inch, 0.75*inch, 2.35*inch, 0.5*inch], repeatRows=1)
        t.setStyle(TableStyle([
            ("BACKGROUND", (0,0), (-1,0), NAVY), ("TEXTCOLOR", (0,0), (-1,0), colors.white),
            ("FONTNAME", (0,0), (-1,0), "Helvetica-Bold"), ("FONTSIZE", (0,0), (-1,0), 8.5),
            ("VALIGN", (0,0), (-1,-1), "MIDDLE"), ("TOPPADDING", (0,0), (-1,-1), 3), ("BOTTOMPADDING", (0,0), (-1,-1), 3),
            ("LEFTPADDING", (0,0), (-1,-1), 5), ("GRID", (0,0), (-1,-1), 0.4, colors.HexColor("#cccccc")),
            ("ROWBACKGROUNDS", (0,1), (-1,-1), [colors.white, LIGHT])]))
        return t
    story[-1] = _mk()

    SimpleDocTemplate(out_path, pagesize=letter, leftMargin=0.5*inch, rightMargin=0.5*inch,
        topMargin=0.5*inch, bottomMargin=0.5*inch, title="Unclogme Clients Missing SC").build(story)
    return len(rows)

def mktable():  # placeholder replaced in build()
    return Spacer(1, 0)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    out = a.out or os.path.join(os.path.expanduser("~"), "Downloads", f"Clients_Missing_SC_{a.date}.pdf")
    n = build(out, a.date)
    print(f"WROTE {out}")
    print(f"clients missing current SC: {n}")
