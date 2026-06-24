#!/usr/bin/env python3
# ============================================================================
# sa_status_report.py — Service Agreement Status Report (PDF)
# ----------------------------------------------------------------------------
# Self-contained operational snapshot of Service Agreement (SA) coverage gaps
# and leftover open jobs, for Fred / ops / Yan to act on. See the full intent +
# section definitions in docs/reports/sa-status-report.md.
#
# It answers three operational questions:
#   1. Which SA agreements exist but CAN'T generate recurring visits yet
#      (Frequency = 0 / blank, or no line items)?  -> finish setup in Jobber.
#   2. Which active/recurring clients have NO Service Agreement at all
#      (split: serviced in 2026 = likely real gap; no 2026 service = likely
#      emergency-only)?  -> decide whether to create an SA.
#   3. Which old pre-restructure [OLD] jobs are still open in Jobber?
#      -> archive once their pending visits complete.
#
# Reads Prod (public.jobs/clients/line_items/visits) via the Supabase Management
# API using SUPABASE_PAT + SUPABASE_PROJECT_ID from ../../.env (gitignored — no
# secrets in this file; the repo is public).
#
# Usage:
#   python scripts/reports/sa_status_report.py                 # -> ~/Downloads/Clients_SA_Status_<today>.pdf
#   python scripts/reports/sa_status_report.py --out X.pdf     # custom path
#   python scripts/reports/sa_status_report.py --date 2026-06-24
#
# Requires: reportlab (pip install reportlab). Python stdlib for the HTTP query.
# ============================================================================
import os, sys, json, argparse, datetime, urllib.request
from reportlab.lib import colors
from reportlab.lib.pagesizes import letter
from reportlab.lib.units import inch
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.platypus import SimpleDocTemplate, Paragraph, Table, TableStyle

# ---- env + query -----------------------------------------------------------
def load_env(path):
    env = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env

ENV = load_env(os.path.join(os.path.dirname(__file__), "..", "..", ".env"))
PAT = ENV["SUPABASE_PAT"]
PROJECT = ENV["SUPABASE_PROJECT_ID"]

def pg(sql):
    # NOTE: the Supabase Management API is behind Cloudflare, which 403s the default
    # urllib User-Agent — a real UA header is required.
    req = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{PROJECT}/database/query",
        data=json.dumps({"query": sql}).encode(),
        headers={"Authorization": f"Bearer {PAT}", "Content-Type": "application/json",
                 "User-Agent": "unclogme-sa-status-report/1.0"},
        method="POST")
    with urllib.request.urlopen(req, timeout=60) as r:
        out = json.loads(r.read().decode())
    if not isinstance(out, list):
        raise RuntimeError(f"query failed: {json.dumps(out)[:300]}")
    return out

# ---- the three section queries (definitions live in the doc) ----------------
# "SA job" = title ILIKE 'Service Agreement%' AND not archived AND not [OLD].
Q_PENDING = """
SELECT c.client_code, c.name, c.status, j.job_number, j.frequency_days,
  (SELECT count(*) FROM line_items li WHERE li.job_id=j.id) AS line_items
FROM jobs j JOIN clients c ON c.id=j.client_id
WHERE j.title ILIKE 'Service Agreement%' AND j.job_status<>'archived' AND j.title NOT ILIKE '%[OLD]%'
  AND (COALESCE(j.frequency_days,0)=0 OR NOT EXISTS (SELECT 1 FROM line_items li WHERE li.job_id=j.id))
ORDER BY c.client_code"""

Q_MISSING = """
SELECT c.client_code, c.name, c.status,
  EXISTS (SELECT 1 FROM jobs j WHERE j.client_id=c.id AND j.title='Service Call' AND j.job_status<>'archived' AND j.title NOT ILIKE '%[OLD]%') AS has_sc,
  (SELECT max(v.visit_date) FROM visits v WHERE v.client_id=c.id AND v.deleted_at IS NULL AND v.visit_status='completed') AS last_visit
FROM clients c
WHERE c.client_code IS NOT NULL AND c.status IN ('ACTIVE','RECURRING')
  AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.client_id=c.id AND j.title ILIKE 'Service Agreement%' AND j.job_status<>'archived' AND j.title NOT ILIKE '%[OLD]%')
ORDER BY c.client_code"""

Q_OLDJOBS = """
SELECT c.client_code, c.name, j.job_number, j.job_status, j.title,
  (SELECT count(*) FROM visits v WHERE v.job_id=j.id AND v.deleted_at IS NULL AND v.visit_date>=current_date) AS future_visits
FROM jobs j JOIN clients c ON c.id=j.client_id
WHERE j.title ILIKE '%[OLD]%' AND j.job_status<>'archived'
ORDER BY c.client_code, j.job_number"""

# ---- PDF rendering ---------------------------------------------------------
NAVY = colors.HexColor("#1f3a5f"); GREY = colors.HexColor("#666666"); LIGHT = colors.HexColor("#eef2f7")
styles = getSampleStyleSheet()
h_title = ParagraphStyle("t", parent=styles["Title"], fontSize=18, textColor=NAVY, spaceAfter=2)
h_sub = ParagraphStyle("s", parent=styles["Normal"], fontSize=9, textColor=GREY, spaceAfter=2)
h_sec = ParagraphStyle("sec", parent=styles["Heading2"], fontSize=13, textColor=NAVY, spaceBefore=14, spaceAfter=4)
h_note = ParagraphStyle("n", parent=styles["Normal"], fontSize=8.5, textColor=GREY, spaceAfter=6, leading=11)
cell = ParagraphStyle("c", parent=styles["Normal"], fontSize=8.5, leading=10)
cellb = ParagraphStyle("cb", parent=cell, fontName="Helvetica-Bold")
def P(t, st=cell): return Paragraph("" if t is None else str(t), st)
def mktable(headers, rows, widths):
    data = [[P(h, cellb) for h in headers]] + rows
    t = Table(data, colWidths=widths, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0,0), (-1,0), NAVY), ("TEXTCOLOR", (0,0), (-1,0), colors.white),
        ("FONTNAME", (0,0), (-1,0), "Helvetica-Bold"), ("FONTSIZE", (0,0), (-1,0), 8.5),
        ("VALIGN", (0,0), (-1,-1), "MIDDLE"), ("TOPPADDING", (0,0), (-1,-1), 3), ("BOTTOMPADDING", (0,0), (-1,-1), 3),
        ("LEFTPADDING", (0,0), (-1,-1), 5), ("GRID", (0,0), (-1,-1), 0.4, colors.HexColor("#cccccc")),
        ("ROWBACKGROUNDS", (0,1), (-1,-1), [colors.white, LIGHT])]))
    return t

def build(out_path, report_date):
    pending = pg(Q_PENDING)
    missing = pg(Q_MISSING)
    oldjobs = pg(Q_OLDJOBS)
    lv = lambda r: r.get("last_visit") or ""
    serviced = sorted([r for r in missing if lv(r) >= "%s-01-01" % report_date[:4]], key=lv, reverse=True)
    noservice = sorted([r for r in missing if lv(r) < "%s-01-01" % report_date[:4]], key=lambda r: r.get("client_code") or "zzz")

    story = [P("Unclogme LLC — Service Agreement Status Report", h_title),
             P("333 West 41st Street, Suite 606, Miami Beach FL 33140", h_sub),
             P(f"Generated {report_date} &nbsp;|&nbsp; Clients pending / missing a Service Agreement (SA) and old jobs still open", h_sub)]

    story += [P("1. Pending / incomplete Service Agreements", h_sec),
        P(f"{len(pending)} client(s) have an SA job in Jobber that is NOT ready to generate visits — Frequency is 0/blank and/or it has no line items. Set the Frequency custom field and add line items in Jobber so the daily SA cron will generate their recurring visits.", h_note),
        mktable(["Code","Client","Status","SA Job","Freq (d)","Line items"],
            [[P(r.get("client_code")),P(r.get("name")),P(r.get("status")),P("#"+str(r.get("job_number"))),P(r.get("frequency_days")),P(r.get("line_items"))] for r in pending],
            [0.7*inch,2.5*inch,0.8*inch,1.0*inch,0.7*inch,0.8*inch])]

    story += [P(f"2. Missing a Service Agreement — serviced in {report_date[:4]} (likely real gaps)", h_sec),
        P(f"{len(serviced)} active/recurring client(s) with NO Service Agreement job, but a completed visit this year. Strongest candidates for an SA so the cron can schedule recurring visits. 'SC' = already has a Service Call job.", h_note),
        mktable(["Code","Client","Status","SC?","Last visit"],
            [[P(r.get("client_code")),P(r.get("name")),P(r.get("status")),P("Yes" if r.get("has_sc") else "No"),P(r.get("last_visit") or "-")] for r in serviced],
            [0.7*inch,2.9*inch,0.85*inch,0.6*inch,1.05*inch])]

    story += [P(f"3. Missing a Service Agreement — no {report_date[:4]} service (likely emergency-only)", h_sec),
        P(f"{len(noservice)} active/recurring client(s) with no SA and no completed visit this year. Per ops rule, no recent visit does NOT mean abandoned — many are on-call / emergency-only accounts that legitimately have no recurring SA. Review case-by-case.", h_note),
        mktable(["Code","Client","Status","SC?","Last visit"],
            [[P(r.get("client_code")),P(r.get("name")),P(r.get("status")),P("Yes" if r.get("has_sc") else "No"),P(r.get("last_visit") or "-")] for r in noservice],
            [0.7*inch,2.9*inch,0.85*inch,0.6*inch,1.05*inch])]

    story += [P("4. Old jobs still open in Jobber", h_sec),
        P(f"{len(oldjobs)} job(s) tagged [OLD] still NOT archived in Jobber. Pre-restructure jobs superseded by the new SA / Service Call jobs; archive once their pending visits (if any) complete.", h_note),
        mktable(["Code","Client","Job #","Status","Title","Future visits"],
            [[P(r.get("client_code")),P(r.get("name")),P("#"+str(r.get("job_number"))),P(r.get("job_status")),P((r.get("title") or "")[:42]),P(r.get("future_visits"))] for r in oldjobs],
            [0.7*inch,2.0*inch,0.95*inch,1.05*inch,1.7*inch,0.75*inch])]

    SimpleDocTemplate(out_path, pagesize=letter, leftMargin=0.5*inch, rightMargin=0.5*inch,
        topMargin=0.5*inch, bottomMargin=0.5*inch, title="Unclogme SA Status Report").build(story)
    return len(pending), len(serviced), len(noservice), len(oldjobs)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", default=datetime.date.today().isoformat(), help="report date YYYY-MM-DD (default today)")
    ap.add_argument("--out", default=None, help="output path (default ~/Downloads/Clients_SA_Status_<date>.pdf)")
    a = ap.parse_args()
    out = a.out or os.path.join(os.path.expanduser("~"), "Downloads", f"Clients_SA_Status_{a.date}.pdf")
    p, s, n, o = build(out, a.date)
    print(f"WROTE {out}")
    print(f"counts: pending={p} serviced_gap={s} noservice={n} oldjobs={o}")
