"""
build_db_audit_pdf.py — render the DB reliability audit as an Unclogme-branded PDF.
  PYTHONIOENCODING=utf-8 python docs/reports/build_db_audit_pdf.py
"""
from __future__ import annotations
from datetime import datetime
from pathlib import Path
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import LETTER
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (BaseDocTemplate, Frame, Image, NextPageTemplate,
                                PageBreak, PageTemplate, Paragraph, Spacer, Table, TableStyle)

HERE = Path(__file__).resolve().parent
LOGO_PATH = Path(r"C:/Users/FRED/Desktop/Virtrify/Yannick/unclogme logo.png")
COMPANY_NAME = "Unclogme LLC"
COMPANY_ADDR = "333 West 41st Street, Suite 606, Miami Beach FL 33140"
ORANGE      = colors.HexColor("#E85A1F")
ORANGE_SOFT = colors.HexColor("#FFEDE2")
INK         = colors.HexColor("#1A1A1A")
INK_SOFT    = colors.HexColor("#4A4A4A")
GRAY_LINE   = colors.HexColor("#E5E5E5")
GRAY_BAND   = colors.HexColor("#F7F7F7")
BG_NEUTRAL  = colors.HexColor("#FAFAFA")
GREEN       = colors.HexColor("#1E7F4F")
GREEN_SOFT  = colors.HexColor("#E6F2EB")

PASSED = [
    ("Orphan visits &rarr; clients / properties / jobs / vehicles / invoices", "0"),
    ("Orphan manifest_visits &rarr; manifests / visits", "0"),
    ("Orphan properties / service_configs / gdos / client_locations / derm_manifests", "0"),
    ("Orphan entity_source_links &rarr; their targets", "0"),
    ("One Jobber gid or Airtable rec mapped to two client rows", "0"),
    ("One source id mapped to two entities (any type)", "0"),
    ("Null client name / visit date / visit client / manifest client", "0"),
    ("Within-client duplicate manifest # / GDO #", "0"),
]
FINDINGS = [
    ("Duplicate client_code", "2 &rarr; 0", "FIXED",
     "144-LTG (Airtable row merged into the Jobber row) + 172-NU (empty orphan removed). A cross-source merge gap from the 4/29 backfill + later Jobber sync — NOT an Airtable duplicate."),
    ("Same client + same address, 2 property rows", "150", "BY DESIGN",
     "100% are the Jobber billing-address vs service-address split (one row flagged is_billing). Not corruption."),
    ("Visits with no source link", "454", "BY DESIGN",
     "100% are source = supabase_cron — the upcoming visits our own generator creates. Every externally-sourced visit IS traceable."),
    ("Clients with no source link", "3 &rarr; 0", "FIXED",
     "1 was the dup orphan (removed); the other 2 (050-PV, 150-KOS) had their Airtable source links backfilled. Every client is now traceable."),
]

base = getSampleStyleSheet()
def ps(name, **kw): return ParagraphStyle(name, parent=base["Normal"], **kw)
S = {
    "cover_title": ps("ct", fontName="Helvetica-Bold", fontSize=30, leading=36, textColor=INK, spaceAfter=8),
    "cover_sub":   ps("cs", fontName="Helvetica", fontSize=13, leading=17, textColor=INK_SOFT, spaceAfter=18),
    "cover_meta":  ps("cm", fontName="Helvetica", fontSize=9, leading=14, textColor=INK_SOFT),
    "verdict":     ps("vd", fontName="Helvetica-Bold", fontSize=15, leading=19, textColor=GREEN, alignment=TA_LEFT),
    "h1":          ps("h1", fontName="Helvetica-Bold", fontSize=17, leading=22, textColor=INK, spaceBefore=4, spaceAfter=4),
    "lead":        ps("ld", fontName="Helvetica", fontSize=10, leading=14, textColor=INK_SOFT, spaceAfter=14),
    "h2":          ps("h2", fontName="Helvetica-Bold", fontSize=11, leading=14, textColor=ORANGE, spaceBefore=14, spaceAfter=8),
    "stat_v":      ps("sv", fontName="Helvetica-Bold", fontSize=22, leading=26, textColor=INK, alignment=TA_CENTER),
    "stat_l":      ps("sl", fontName="Helvetica", fontSize=7.5, leading=9, textColor=INK_SOFT, alignment=TA_CENTER, spaceBefore=2),
    "th":          ps("th", fontName="Helvetica-Bold", fontSize=8, leading=10, textColor=colors.white),
    "cell":        ps("cl", fontName="Helvetica", fontSize=9, leading=12, textColor=INK),
    "cell_soft":   ps("cls", fontName="Helvetica", fontSize=8.5, leading=11, textColor=INK_SOFT),
    "ok":          ps("ok", fontName="Helvetica-Bold", fontSize=11, leading=12, textColor=GREEN, alignment=TA_CENTER),
}

def draw_hf(canvas, doc, rd, is_cover=False):
    canvas.saveState(); pw, ph = LETTER
    if not is_cover:
        try: canvas.drawImage(str(LOGO_PATH), 0.5*inch, ph-0.7*inch, width=0.32*inch, height=0.32*inch, preserveAspectRatio=True, mask="auto")
        except Exception: pass
        canvas.setFont("Helvetica-Bold", 9); canvas.setFillColor(INK); canvas.drawString(0.95*inch, ph-0.55*inch, "Data Reliability Audit")
        canvas.setFont("Helvetica", 9); canvas.setFillColor(INK_SOFT); canvas.drawString(0.95*inch, ph-0.7*inch, "Prod canonical")
        canvas.drawRightString(pw-0.5*inch, ph-0.55*inch, f"Page {canvas.getPageNumber()}"); canvas.drawRightString(pw-0.5*inch, ph-0.7*inch, rd)
        canvas.setStrokeColor(GRAY_LINE); canvas.setLineWidth(0.5); canvas.line(0.5*inch, ph-0.85*inch, pw-0.5*inch, ph-0.85*inch)
    canvas.setStrokeColor(GRAY_LINE); canvas.setLineWidth(0.5); canvas.line(0.5*inch, 0.6*inch, pw-0.5*inch, 0.6*inch)
    canvas.setFont("Helvetica", 7); canvas.setFillColor(INK_SOFT)
    canvas.drawString(0.5*inch, 0.42*inch, COMPANY_NAME + "  ·  " + COMPANY_ADDR)
    canvas.drawRightString(pw-0.5*inch, 0.42*inch, "Confidential  ·  Internal Use Only")
    canvas.restoreState()

def stat_card(value, label, bg=BG_NEUTRAL):
    t = Table([[Paragraph(str(value), S["stat_v"])], [Paragraph(label, S["stat_l"])]], colWidths=[1.6*inch], rowHeights=[0.5*inch, 0.34*inch])
    t.setStyle(TableStyle([("BACKGROUND",(0,0),(-1,-1),bg),("BOX",(0,0),(-1,-1),0.6,GRAY_LINE),
        ("LEFTPADDING",(0,0),(-1,-1),4),("RIGHTPADDING",(0,0),(-1,-1),4),("TOPPADDING",(0,0),(-1,-1),4),("BOTTOMPADDING",(0,0),(-1,-1),4),
        ("VALIGN",(0,0),(-1,0),"BOTTOM"),("VALIGN",(0,1),(-1,1),"TOP")]))
    return t

def _tbl(n):
    st = TableStyle([("BACKGROUND",(0,0),(-1,0),INK),("TEXTCOLOR",(0,0),(-1,0),colors.white),
        ("TOPPADDING",(0,0),(-1,0),6),("BOTTOMPADDING",(0,0),(-1,0),6),
        ("LEFTPADDING",(0,0),(-1,-1),8),("RIGHTPADDING",(0,0),(-1,-1),8),
        ("TOPPADDING",(0,1),(-1,-1),5),("BOTTOMPADDING",(0,1),(-1,-1),5),("VALIGN",(0,0),(-1,-1),"MIDDLE"),
        ("LINEBELOW",(0,0),(-1,-1),0.25,GRAY_LINE),("BOX",(0,0),(-1,-1),0.6,GRAY_LINE)])
    for i in range(1,n):
        if i%2==0: st.add("BACKGROUND",(0,i),(-1,i),GRAY_BAND)
    return st

def passed_table():
    data=[[Paragraph("INTEGRITY CHECK",S["th"]),Paragraph("ISSUES",S["th"])]]
    for area,res in PASSED:
        data.append([Paragraph(area,S["cell"]),Paragraph("&#10003; "+res,S["ok"])])
    t=Table(data,colWidths=[6.4*inch,1.1*inch],repeatRows=1); t.setStyle(_tbl(len(data))); return t

def findings_table():
    data=[[Paragraph("FINDING",S["th"]),Paragraph("COUNT",S["th"]),Paragraph("VERDICT",S["th"])]]
    for f,cnt,tag,desc in FINDINGS:
        col = GREEN if tag=="FIXED" else INK_SOFT
        verdict=Paragraph(f'<font color="{col.hexval()}"><b>{tag}</b></font> &mdash; {desc}', S["cell_soft"])
        data.append([Paragraph(f,S["cell"]),Paragraph(cnt,S["cell"]),verdict])
    t=Table(data,colWidths=[1.9*inch,0.7*inch,4.9*inch],repeatRows=1); t.setStyle(_tbl(len(data))); return t

def build_cover():
    st=[Spacer(1,0.2*inch)]
    st.append(Paragraph("Data Reliability<br/>Audit", S["cover_title"]))
    st.append(Paragraph("Prod canonical warehouse (wbasvhvvismukaqdnouk) &mdash; full integrity review", S["cover_sub"]))
    # verdict banner
    vb=Table([[Paragraph("&#10003;  VERDICT: The data is reliable.", S["verdict"])]], colWidths=[7.5*inch])
    vb.setStyle(TableStyle([("BACKGROUND",(0,0),(-1,-1),GREEN_SOFT),("BOX",(0,0),(-1,-1),0.8,GREEN),
        ("LEFTPADDING",(0,0),(-1,-1),12),("TOPPADDING",(0,0),(-1,-1),10),("BOTTOMPADDING",(0,0),(-1,-1),10)]))
    st.append(vb); st.append(Spacer(1,0.3*inch))
    for line in [f"<b>Date:</b> {datetime.now().strftime('%B %d, %Y')}",
                 "<b>Scope:</b> ~30 checks &mdash; duplicates, referential integrity, provenance, nulls, cross-source coverage",
                 "<b>Probe:</b> scripts/probes/_db_reliability_audit.js"]:
        st.append(Paragraph(line, S["cover_meta"]))
    st.append(Spacer(1,0.4*inch))
    cards=[[stat_card("0","ORPHANS (every FK)",GREEN_SOFT), stat_card("391 / 391","CLIENTS TRACEABLE",GREEN_SOFT),
            stat_card("0","DUPLICATE CODES",GREEN_SOFT), stat_card("0","OPEN ITEMS",GREEN_SOFT)]]
    ct=Table(cards,colWidths=[1.75*inch]*4,hAlign="LEFT")
    ct.setStyle(TableStyle([("LEFTPADDING",(0,0),(-1,-1),0),("RIGHTPADDING",(0,0),(2,-1),8)]))
    st.append(ct); st.append(Spacer(1,0.35*inch))
    st.append(Paragraph("Why this was run", S["h2"]))
    st.append(Paragraph("A cross-source duplicate client record was found (the same business held two rows in our "
        "database — one from the 4/29 Airtable backfill, one from Jobber). This audit verifies there is no broader "
        "corruption. Result: referential integrity is spotless, every client is traceable to a source, and the only two "
        "scary-looking counts (150 property “duplicates”, 454 source-less visits) are expected system patterns, "
        "not bad data. The two real issues found were fixed.", S["lead"]))
    return st

def build_body():
    st=[Paragraph("Checks that passed clean", S["h1"])]
    st.append(Paragraph("Every foreign-key and identity check returned zero issues — nothing points at a row that "
        "doesn't exist, and no external id is split across two records.", S["lead"]))
    st.append(passed_table()); st.append(PageBreak())
    st.append(Paragraph("The 4 findings", S["h1"]))
    st.append(Paragraph("Two real issues (fixed) and two expected-by-design patterns.", S["lead"]))
    st.append(findings_table()); st.append(Spacer(1,0.25*inch))
    st.append(Paragraph("Root cause &amp; prevention", S["h2"]))
    st.append(Paragraph("The 4/29 Airtable backfill created client rows; a later Jobber sync then made a SECOND row for "
        "the same client instead of matching it (it matched on Jobber gid, which the Airtable-born row didn't carry). Only "
        "2 slipped through. The Airtable-sunset wipe + repopulate (Jobber-canonical) closes this path entirely; until then, "
        "the duplicate-code check in the audit probe catches any new occurrence.", S["lead"]))
    return st

def build_pdf():
    rd = datetime.now().strftime("%b %d, %Y")
    out = HERE / f"{datetime.now().strftime('%Y-%m-%d')}_db_reliability_audit.pdf"
    pw, ph = LETTER; mx, mtop, mbot = 0.5*inch, 1.0*inch, 0.75*inch
    fk = dict(x1=mx, y1=mbot, width=pw-2*mx, height=ph-mtop-mbot, leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)
    doc = BaseDocTemplate(str(out), pagesize=LETTER, leftMargin=mx, rightMargin=mx, topMargin=mtop, bottomMargin=mbot,
                          title="Data Reliability Audit", author=COMPANY_NAME)
    doc.addPageTemplates([
        PageTemplate(id="cover", frames=[Frame(id="cover", **{**fk, "height": ph-0.9*inch-mbot})], onPage=lambda c,d: draw_hf(c,d,rd,True)),
        PageTemplate(id="body",  frames=[Frame(id="body", **fk)], onPage=lambda c,d: draw_hf(c,d,rd,False)),
    ])
    story=[]
    if LOGO_PATH.exists():
        story.append(Image(str(LOGO_PATH), width=0.9*inch, height=0.9*inch, hAlign="LEFT", kind="proportional")); story.append(Spacer(1,0.12*inch))
    story.extend(build_cover()); story.append(NextPageTemplate("body")); story.append(PageBreak())
    story.extend(build_body())
    doc.build(story); return out

if __name__ == "__main__":
    out = build_pdf(); print(f"OK  {out}\n    bytes: {out.stat().st_size:,}")
