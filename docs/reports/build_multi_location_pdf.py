"""
build_multi_location_pdf.py

Render docs/reports/<date>_multi_location_clients.pdf — the multi-location client
discovery for Diego / Yannick verification (companion to
docs/multi-location-clients-for-diego-yan.md). Unclogme branding.

Run:
  PYTHONIOENCODING=utf-8 python docs/reports/build_multi_location_pdf.py
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
AMBER       = colors.HexColor("#B07A1E")

# ─── curated content (from reports/_multi_location_discovery.json, 2026-06-01) ───
BRAND_FAMILIES = [  # suffix, brand, count, note
    ("-PV",  "Pura Vida",          "23", "Chain — different addresses"),
    ("-TCE", "The Carrot Express", "23", "Chain — different addresses"),
    ("-LG",  "La Granja",          "6",  "Chain"),
    ("-GRO", "Grove Kosher",       "4",  "Chain"),
    ("-BB",  "Bagel Boss",         "4",  "Chain"),
    ("-G7",  "G7 Kitchens",        "3",  "019+020 same building · 215 separate"),
    ("-TRUE","True Barista",       "3",  "209 @ 777 Brickell · 212+213 @ 1395 Brickell"),
    ("-FIA", "Fialkoff's",         "2",  "Chain (Miami Beach / Surfside)"),
    ("-KRU", "Krudo",              "2",  "Fish Market / Warehouse"),
    ("-MYK", "Myka",               "2",  "Lincoln Rd / 777 Brickell"),
    ("-MP",  "Mrs / Mr Pasta",     "2",  "Same building (220 SW 31st St)"),
    ("-FRK", "Fresko",             "2",  "Adjacent — Fresko + Bakery"),
    ("-NU",  "Nu Real Food",       "2",  "045 / 172 — 172 entered twice"),
    ("-LTG", "Lettuce & Tomato",   "2",  "Same building (17070 W Dixie) — 144 twice"),
    ("-WYN", "Wynd 28",            "5",  "Same building — ALREADY merging"),
    ("-CN",  "Casa Neos",          "2",  "Same building — ALREADY done"),
]
SAME_BRAND_ADDR = [
    ("5450 S State Rd 7, Ft Lauderdale", "G7 Kitchens 34 (019-G7) + G7 Roof Top (020-G7)"),
    ("1395 Brickell Ave, Miami",         "True Barista Temp (212-TRUE) + Grease Trap (213-TRUE)"),
    ("220 SW 31st St, Ft Lauderdale",    "Mrs. Pasta (044-MP) + Mr. Pasta Factory (221-MP)"),
    ("17070 W Dixie Hwy, N Miami Beach", "Lettuce & Tomato (139-LTG) + its Bakery (144-LTG)"),
    ("19048 / 19062 NE 29th Ave",        "Fresko (192-FRK) + Fresko Bakery (193-FRK)"),
]
CROSS_BRAND_ADDR = [
    ("777 Brickell Ave, Miami",        "True Barista Truck (209-TRUE) + Myka Brickell (214-MYK)"),
    ("1657 N Miami Ave, suite A",      "Pura Vida Bakery (170-PV) + What Soup (176-SOU)"),
    ("668 W Hallandale Beach Blvd",    "Kosher Bagel Cove (030-KGC) + Bakey (229-BAK)"),
    ("1936 Normandy Dr, Miami Beach",  "Mosche Elghrissi (119-ME) + BMN Normandy (122-BMN)"),
    ("1747 Alton Rd, Miami Beach",     "Meir Fellig (128-MF) + Pummarola (132-PUM)"),
]
ADJACENT = [
    ("~9543 / 9545 Harding Ave, Surfside", "Bagel Boss (087-BB) + Kresy Kosher Pizza (183-KRE)"),
    ("~9472 / 9476 Harding Ave, Surfside", "Hikari Miami (116-HIK) + Rustico (149-RUS)"),
]
DUPS = [
    ("172-NU", "Nu Real Food — Coral Gables", "ids 464 + 224"),
    ("144-LTG","Lettuce & Tomato (Bakery)",        "ids 466 + 147"),
]

base = getSampleStyleSheet()
def ps(name, **kw): return ParagraphStyle(name, parent=base["Normal"], **kw)
S = {
    "cover_title": ps("ct", fontName="Helvetica-Bold", fontSize=30, leading=36, textColor=INK, spaceAfter=8),
    "cover_sub":   ps("cs", fontName="Helvetica", fontSize=13, leading=17, textColor=INK_SOFT, spaceAfter=20),
    "cover_meta":  ps("cm", fontName="Helvetica", fontSize=9, leading=14, textColor=INK_SOFT),
    "h1":          ps("h1", fontName="Helvetica-Bold", fontSize=17, leading=22, textColor=INK, spaceBefore=4, spaceAfter=4),
    "lead":        ps("ld", fontName="Helvetica", fontSize=10, leading=14, textColor=INK_SOFT, spaceAfter=14),
    "h2":          ps("h2", fontName="Helvetica-Bold", fontSize=11, leading=14, textColor=ORANGE, spaceBefore=14, spaceAfter=8),
    "stat_v":      ps("sv", fontName="Helvetica-Bold", fontSize=24, leading=28, textColor=INK, alignment=TA_CENTER),
    "stat_l":      ps("sl", fontName="Helvetica", fontSize=8, leading=10, textColor=INK_SOFT, alignment=TA_CENTER, spaceBefore=2),
    "th":          ps("th", fontName="Helvetica-Bold", fontSize=8, leading=10, textColor=colors.white),
    "code":        ps("cd", fontName="Courier-Bold", fontSize=9, leading=12, textColor=INK),
    "cell":        ps("cl", fontName="Helvetica", fontSize=9, leading=12, textColor=INK),
    "cell_soft":   ps("cls", fontName="Helvetica", fontSize=8.5, leading=11, textColor=INK_SOFT),
}

def draw_header_footer(canvas, doc, report_date, is_cover=False):
    canvas.saveState()
    pw, ph = LETTER
    if not is_cover:
        try:
            canvas.drawImage(str(LOGO_PATH), 0.5*inch, ph-0.7*inch, width=0.32*inch, height=0.32*inch,
                             preserveAspectRatio=True, mask="auto")
        except Exception:
            pass
        canvas.setFont("Helvetica-Bold", 9); canvas.setFillColor(INK)
        canvas.drawString(0.95*inch, ph-0.55*inch, "Multi-Location Clients")
        canvas.setFont("Helvetica", 9); canvas.setFillColor(INK_SOFT)
        canvas.drawString(0.95*inch, ph-0.7*inch, "Discovery for review")
        canvas.setFont("Helvetica", 9); canvas.setFillColor(INK_SOFT)
        canvas.drawRightString(pw-0.5*inch, ph-0.55*inch, f"Page {canvas.getPageNumber()}")
        canvas.drawRightString(pw-0.5*inch, ph-0.7*inch, report_date)
        canvas.setStrokeColor(GRAY_LINE); canvas.setLineWidth(0.5)
        canvas.line(0.5*inch, ph-0.85*inch, pw-0.5*inch, ph-0.85*inch)
    canvas.setStrokeColor(GRAY_LINE); canvas.setLineWidth(0.5)
    canvas.line(0.5*inch, 0.6*inch, pw-0.5*inch, 0.6*inch)
    canvas.setFont("Helvetica", 7); canvas.setFillColor(INK_SOFT)
    canvas.drawString(0.5*inch, 0.42*inch, COMPANY_NAME + "  ·  " + COMPANY_ADDR)
    canvas.drawRightString(pw-0.5*inch, 0.42*inch, "Confidential  ·  Internal Use Only")
    canvas.restoreState()

def stat_card(value, label, bg=ORANGE_SOFT):
    t = Table([[Paragraph(str(value), S["stat_v"])], [Paragraph(label, S["stat_l"])]],
              colWidths=[1.6*inch], rowHeights=[0.5*inch, 0.32*inch])
    t.setStyle(TableStyle([("BACKGROUND",(0,0),(-1,-1),bg), ("BOX",(0,0),(-1,-1),0.6,GRAY_LINE),
        ("LEFTPADDING",(0,0),(-1,-1),6),("RIGHTPADDING",(0,0),(-1,-1),6),
        ("TOPPADDING",(0,0),(-1,-1),4),("BOTTOMPADDING",(0,0),(-1,-1),4),
        ("VALIGN",(0,0),(-1,0),"BOTTOM"),("VALIGN",(0,1),(-1,1),"TOP")]))
    return t

def _tbl_style(n):
    st = TableStyle([("BACKGROUND",(0,0),(-1,0),INK),("TEXTCOLOR",(0,0),(-1,0),colors.white),
        ("TOPPADDING",(0,0),(-1,0),6),("BOTTOMPADDING",(0,0),(-1,0),6),
        ("LEFTPADDING",(0,0),(-1,-1),8),("RIGHTPADDING",(0,0),(-1,-1),8),
        ("TOPPADDING",(0,1),(-1,-1),5),("BOTTOMPADDING",(0,1),(-1,-1),5),
        ("VALIGN",(0,0),(-1,-1),"MIDDLE"),
        ("LINEBELOW",(0,0),(-1,-1),0.25,GRAY_LINE),("BOX",(0,0),(-1,-1),0.6,GRAY_LINE)])
    for i in range(1, n):
        if i % 2 == 0: st.add("BACKGROUND",(0,i),(-1,i),GRAY_BAND)
    return st

def brand_table():
    data=[[Paragraph("CODE",S["th"]),Paragraph("BRAND",S["th"]),Paragraph("#",S["th"]),Paragraph("NOTES",S["th"])]]
    for sx,brand,n,note in BRAND_FAMILIES:
        data.append([Paragraph(sx,S["code"]),Paragraph(brand,S["cell"]),Paragraph(n,S["cell"]),Paragraph(note,S["cell_soft"])])
    t=Table(data,colWidths=[0.75*inch,1.75*inch,0.4*inch,4.6*inch],repeatRows=1); t.setStyle(_tbl_style(len(data))); return t

def addr_table(rows):
    data=[[Paragraph("ADDRESS",S["th"]),Paragraph("CLIENT RECORDS",S["th"])]]
    for a,c in rows:
        data.append([Paragraph(a,S["cell"]),Paragraph(c,S["cell_soft"])])
    t=Table(data,colWidths=[2.7*inch,4.8*inch],repeatRows=1); t.setStyle(_tbl_style(len(data))); return t

def dup_table():
    data=[[Paragraph("CODE",S["th"]),Paragraph("NAME",S["th"]),Paragraph("RECORDS",S["th"])]]
    for code,name,recs in DUPS:
        data.append([Paragraph(code,S["code"]),Paragraph(name,S["cell"]),Paragraph(recs,S["cell_soft"])])
    t=Table(data,colWidths=[1.1*inch,3.6*inch,2.8*inch],repeatRows=1); t.setStyle(_tbl_style(len(data))); return t

def build_cover():
    story=[Spacer(1,0.25*inch)]
    story.append(Paragraph("Multi-Location<br/>Clients", S["cover_title"]))
    story.append(Paragraph("Clients that may be one business with multiple locations — for Diego / Yannick review",
                           S["cover_sub"]))
    for line in [f"<b>Generated:</b> {datetime.now().strftime('%B %d, %Y')}",
                 "<b>Method:</b> grouped by client-code suffix + shared address (normalized + lat/long geo)",
                 "<b>Scope:</b> 206 database clients + 212 Airtable records",
                 "<b>Goal:</b> model the real ones like Wynd 28 and Casa Neos (one client → N locations)"]:
        story.append(Paragraph(line, S["cover_meta"]))
    story.append(Spacer(1,0.45*inch))
    cards=[[stat_card("16","BRAND FAMILIES",BG_NEUTRAL), stat_card("12","SHARED-ADDRESS CLUSTERS",ORANGE_SOFT),
            stat_card("2","ALREADY MODELLED",BG_NEUTRAL)]]
    ct=Table(cards,colWidths=[1.95*inch]*3,hAlign="LEFT")
    ct.setStyle(TableStyle([("LEFTPADDING",(0,0),(-1,-1),0),("RIGHTPADDING",(0,0),(2,-1),12)]))
    story.append(ct); story.append(Spacer(1,0.4*inch))
    story.append(Paragraph("How to read this", S["h2"]))
    story.append(Paragraph(
        "<b>Section A</b> groups clients by the letters in their code (e.g. <font face='Courier'>-PV</font>, "
        "<font face='Courier'>-TCE</font>) — same letters means the same company. <b>Section B</b> groups by "
        "shared address — two client records at one building, the Wynd 28 / Casa Neos pattern. <b>Section C</b> "
        "lists records that look like the same client entered twice. Please tell us, per group, which are truly one "
        "business so we can model them as one client with multiple locations.", S["lead"]))
    return story

def build_body():
    story=[Paragraph("A. Brand families (same code suffix = one company)", S["h1"])]
    story.append(Paragraph("Each shares the letters in its client code. Confirm each is one company, and whether you "
        "want it managed as one client with multiple locations. Wynd 28 and Casa Neos are already handled.", S["lead"]))
    story.append(brand_table())
    story.append(PageBreak())

    story.append(Paragraph("B. Same address — multiple client records", S["h1"]))
    story.append(Paragraph("The Wynd 28 / Casa Neos pattern. For each: one operator with multiple units (we merge into "
        "one client + locations) or separate businesses sharing a building?", S["lead"]))
    story.append(Paragraph("Same brand at one address — looks like multi-unit", S["h2"]))
    story.append(addr_table(SAME_BRAND_ADDR))
    story.append(Paragraph("Different brands, same address — related, or just neighbors?", S["h2"]))
    story.append(addr_table(CROSS_BRAND_ADDR))
    story.append(Paragraph("Adjacent storefronts — probably separate, please confirm", S["h2"]))
    story.append(addr_table(ADJACENT))
    story.append(Spacer(1,0.3*inch))
    story.append(Paragraph("What we need back", S["h2"]))
    story.append(Paragraph("1. Section A: confirm the brand families + whether each chain should be one client with N "
        "locations.<br/>2. Section B: for each address, “one operator, multiple units” vs “separate businesses.”",
        S["lead"]))
    return story

def build_pdf():
    report_date = datetime.now().strftime("%b %d, %Y")
    out = HERE / f"{datetime.now().strftime('%Y-%m-%d')}_multi_location_clients.pdf"
    pw, ph = LETTER
    mx, mtop, mbot = 0.5*inch, 1.0*inch, 0.75*inch
    fk = dict(x1=mx, y1=mbot, width=pw-2*mx, height=ph-mtop-mbot, leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0)
    frame_cover = Frame(id="cover", **{**fk, "height": ph-0.9*inch-mbot})
    frame_body  = Frame(id="body", **fk)
    doc = BaseDocTemplate(str(out), pagesize=LETTER, leftMargin=mx, rightMargin=mx, topMargin=mtop, bottomMargin=mbot,
                          title="Multi-Location Clients", author=COMPANY_NAME)
    doc.addPageTemplates([
        PageTemplate(id="cover", frames=[frame_cover], onPage=lambda c,d: draw_header_footer(c,d,report_date,is_cover=True)),
        PageTemplate(id="body",  frames=[frame_body],  onPage=lambda c,d: draw_header_footer(c,d,report_date,is_cover=False)),
    ])
    story=[]
    if LOGO_PATH.exists():
        story.append(Image(str(LOGO_PATH), width=0.9*inch, height=0.9*inch, hAlign="LEFT", kind="proportional"))
        story.append(Spacer(1,0.12*inch))
    story.extend(build_cover())
    story.append(NextPageTemplate("body")); story.append(PageBreak())
    story.extend(build_body())
    doc.build(story)
    return out

if __name__ == "__main__":
    out = build_pdf()
    print(f"OK  {out}")
    print(f"    bytes: {out.stat().st_size:,}")
