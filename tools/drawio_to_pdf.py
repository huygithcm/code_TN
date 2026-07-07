#!/usr/bin/env python3
"""
drawio_to_pdf.py - Xuat file .drawio (luu do) ra PDF bang matplotlib.

Khong can cai draw.io desktop. Doc truc tiep cac o (vertex) + duong (edge) trong
file mxGraph va ve lai: chu nhat / thoi / binh hanh / terminator / predefined
process, kem nhan canh va waypoint. Phu hop cac luu do don gian (1 trang doc).

Cai dat:  pip install matplotlib   (thuong da co san)

Chay:
    python tools/drawio_to_pdf.py docs/luu_do_giai_thuat.drawio
    python tools/drawio_to_pdf.py docs/luu_do_giai_thuat.drawio -o docs/out.pdf
"""
import argparse
import html
import re
import sys
import textwrap
import xml.etree.ElementTree as ET

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle, FancyBboxPatch, Polygon, FancyArrowPatch


def style_dict(style):
    d = {}
    for part in (style or "").split(";"):
        if not part:
            continue
        if "=" in part:
            k, v = part.split("=", 1)
            d[k] = v
        else:
            d[part] = True
    return d


def clean_text(s):
    """Bo the HTML, doi entity, &#xa; -> xuong dong."""
    s = s or ""
    s = s.replace("&#xa;", "\n")
    s = re.sub(r"<br\s*/?>", "\n", s, flags=re.I)
    s = re.sub(r"</div>", "\n", s, flags=re.I)
    s = re.sub(r"<[^>]+>", "", s)          # bo cac the con lai
    s = s.replace("&nbsp;", " ")
    s = html.unescape(s)
    # gop dong trong thua
    lines = [ln.strip() for ln in s.split("\n")]
    lines = [ln for ln in lines if ln != ""]
    return "\n".join(lines)


def wrap_text(s, width_px):
    cpl = max(8, int(width_px / 7.0))      # uoc luong so ky tu / dong
    out = []
    for ln in s.split("\n"):
        out.extend(textwrap.wrap(ln, cpl) or [""])
    return "\n".join(out)


def parse_drawio(path):
    root = ET.parse(path).getroot()
    model = root.find(".//mxGraphModel")
    cells = model.find("root")
    nodes, edges = {}, []
    for c in cells.findall("mxCell"):
        geo = c.find("mxGeometry")
        st = style_dict(c.get("style"))
        if c.get("vertex") == "1" and geo is not None:
            nodes[c.get("id")] = {
                "x": float(geo.get("x", 0)), "y": float(geo.get("y", 0)),
                "w": float(geo.get("width", 80)), "h": float(geo.get("height", 40)),
                "label": clean_text(c.get("value")), "style": st,
            }
        elif c.get("edge") == "1":
            pts = []
            if geo is not None:
                arr = geo.find("Array[@as='points']")
                if arr is not None:
                    pts = [(float(p.get("x")), float(p.get("y")))
                           for p in arr.findall("mxPoint")]
            edges.append({"source": c.get("source"), "target": c.get("target"),
                          "label": clean_text(c.get("value")), "style": st, "points": pts})
    return nodes, edges


def conn_point(n, sx, sy, default):
    """Diem noi tren bien o: dung exitX/Y - entryX/Y neu co, neu khong dung mac dinh."""
    if sx is not None and sy is not None:
        return (n["x"] + float(sx) * n["w"], n["y"] + float(sy) * n["h"])
    cx, cy = n["x"] + n["w"] / 2, n["y"] + n["h"] / 2
    return {"top": (cx, n["y"]), "bottom": (cx, n["y"] + n["h"]),
            "left": (n["x"], cy), "right": (n["x"] + n["w"], cy)}[default]


def draw_node(ax, n):
    st = n["style"]
    x, y, w, h = n["x"], n["y"], n["w"], n["h"]
    fc = "#" + st.get("fillColor", "#ffffff").lstrip("#")
    ec = "#" + st.get("strokeColor", "#000000").lstrip("#")
    cx, cy = x + w / 2, y + h / 2

    if "rhombus" in st:
        ax.add_patch(Polygon([(cx, y), (x + w, cy), (cx, y + h), (x, cy)],
                             closed=True, facecolor=fc, edgecolor=ec, lw=1.3))
    elif "parallelogram" in st:
        dx = w * 0.18
        ax.add_patch(Polygon([(x + dx, y), (x + w, y), (x + w - dx, y + h), (x, y + h)],
                             closed=True, facecolor=fc, edgecolor=ec, lw=1.3))
    elif st.get("rounded") == "1":
        ax.add_patch(FancyBboxPatch((x + 8, y + 6), w - 16, h - 12,
                     boxstyle="round,pad=6,rounding_size=18",
                     facecolor=fc, edgecolor=ec, lw=1.3))
    else:
        ax.add_patch(Rectangle((x, y), w, h, facecolor=fc, edgecolor=ec, lw=1.3))
        if st.get("shape") == "process":      # predefined process: 2 vach doc
            ax.plot([x + 8, x + 8], [y, y + h], color=ec, lw=1.0)
            ax.plot([x + w - 8, x + w - 8], [y, y + h], color=ec, lw=1.0)

    ax.text(cx, cy, wrap_text(n["label"], w), ha="center", va="center",
            fontsize=8, zorder=5, wrap=True)


def main():
    ap = argparse.ArgumentParser(description="Xuat .drawio ra PDF.")
    ap.add_argument("input", help="File .drawio")
    ap.add_argument("-o", "--output", help="File PDF ra (mac dinh: cung ten .pdf)")
    args = ap.parse_args()
    out = args.output or re.sub(r"\.drawio$", "", args.input) + ".pdf"

    nodes, edges = parse_drawio(args.input)
    if not nodes:
        print("[LOI] Khong doc duoc o nao trong file.", file=sys.stderr)
        sys.exit(1)

    xs = [n["x"] for n in nodes.values()] + [n["x"] + n["w"] for n in nodes.values()]
    ys = [n["y"] for n in nodes.values()] + [n["y"] + n["h"] for n in nodes.values()]
    for e in edges:
        for p in e["points"]:
            xs.append(p[0]); ys.append(p[1])
    minx, maxx, miny, maxy = min(xs) - 40, max(xs) + 40, min(ys) - 40, max(ys) + 40
    W, H = maxx - minx, maxy - miny

    fig, ax = plt.subplots(figsize=(W / 96.0, H / 96.0))
    ax.set_xlim(minx, maxx)
    ax.set_ylim(miny, maxy)
    ax.invert_yaxis()                     # drawio: y huong xuong
    ax.set_aspect("equal")
    ax.axis("off")

    # duong (ve truoc de nam duoi o)
    for e in edges:
        s, t = nodes.get(e["source"]), nodes.get(e["target"])
        if not s or not t:
            continue
        st = e["style"]
        # diem dau/cuoi (uu tien exit/entry, neu khong tu suy theo vi tri tuong doi)
        if "exitX" in st:
            p0 = conn_point(s, st.get("exitX"), st.get("exitY"), "bottom")
        else:
            p0 = conn_point(s, None, None, "bottom" if t["y"] >= s["y"] else "top")
        if "entryX" in st:
            p1 = conn_point(t, st.get("entryX"), st.get("entryY"), "top")
        else:
            p1 = conn_point(t, None, None, "top" if t["y"] >= s["y"] else "bottom")
        poly = [p0] + e["points"] + [p1]
        xs_e = [p[0] for p in poly]; ys_e = [p[1] for p in poly]
        ax.plot(xs_e, ys_e, color="#555555", lw=1.1, zorder=1)
        # mui ten o doan cuoi
        ax.add_patch(FancyArrowPatch(poly[-2], poly[-1], arrowstyle="-|>",
                     mutation_scale=12, color="#555555", lw=1.1, zorder=2))
        if e["label"]:
            mid = poly[len(poly) // 2]
            ax.text(mid[0] + 6, mid[1] - 4, e["label"], fontsize=7.5,
                    color="#b85450", ha="left", va="bottom", zorder=6,
                    bbox=dict(boxstyle="round,pad=0.1", fc="white", ec="none", alpha=0.8))

    for n in nodes.values():
        draw_node(ax, n)

    fig.tight_layout(pad=0.2)
    fig.savefig(out, format="pdf", bbox_inches="tight")
    print(f"[OK] Da xuat: {out}")


if __name__ == "__main__":
    main()
