# -*- coding: utf-8 -*-
"""Zones 包 poster/preview 產生器（家族流程：主 repo scripts/poster/finish_posters.py 同款
告示板/警戒紋/膠帶語彙）。主視覺＝zones_art.png（codex imagegen 依主 repo
scripts/poster/mascot.png 生成的家族吉祥物插畫，同 main_art/maps_art 流程；
換構圖才需重新生成主視覺，改標題只要重跑本腳本），疊 PZ 風標題板＋ADD-ON 徽章。
Deterministic：無隨機數。輸出：42/poster.png 與 MOD 根 preview.png（512×512）。"""
import os
from PIL import Image, ImageDraw, ImageFont

SP = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(SP, "..", ".."))
SRC = os.path.join(SP, "zones_art.png")
MOD_DIR = os.path.join(REPO, "MOD", "MinidoracatMiniMapZonesFor42")
OUT_POSTER = os.path.join(MOD_DIR, "Contents", "mods", "MinidoracatMiniMapZonesFor42",
                          "42", "poster.png")
OUT_PREVIEW = os.path.join(MOD_DIR, "preview.png")

FONTS = r"C:/Windows/Fonts"
GOLD = (233, 195, 90, 255)
PALE = (240, 234, 214, 255)
INK = (28, 26, 20, 255)
BOARD = (38, 40, 30, 235)
BOARD_EDGE = (18, 18, 12, 255)
TAPE = (214, 200, 160, 210)
HAZ_Y = (208, 168, 40, 255)
HAZ_K = (24, 22, 18, 255)


def font(size, *names):
    for n in names:
        p = os.path.join(FONTS, n)
        if os.path.isfile(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def fit(draw, text, max_w, size, *names):
    f = font(size, *names)
    while size > 12 and draw.textlength(text, font=f) > max_w:
        size -= 2
        f = font(size, *names)
    return f


def stroked(draw, xy, text, f, fill, stroke, w):
    draw.text(xy, text, font=f, fill=fill, stroke_width=w, stroke_fill=stroke)


def tape(draw, cx, cy, w=64, h=26):
    draw.rectangle([cx - w // 2, cy - h // 2, cx + w // 2, cy + h // 2], fill=TAPE)


def hazard_strip(draw, x0, y0, x1, y1, step=26):
    draw.rectangle([x0, y0, x1, y1], fill=HAZ_Y)
    for s in range(x0 - (y1 - y0), x1, step * 2):
        draw.polygon([(s, y1), (s + step, y1), (s + step + (y1 - y0), y0),
                      (s + (y1 - y0), y0)], fill=HAZ_K)
    draw.rectangle([x0, y0, x1, y1], outline=BOARD_EDGE, width=3)


def zones_art():
    # 主視覺插畫（構圖已預留底部暗區給標題板，毋須再壓暗角）
    art = Image.open(SRC).convert("RGBA")
    if art.size != (1024, 1024):
        art = art.resize((1024, 1024), Image.LANCZOS)
    return art


def zones_poster():
    im = zones_art()
    d = ImageDraw.Draw(im)
    # 標題板：底部整寬（同 maps_poster 版式）
    bx0, by0, bx1, by1 = 26, 776, 998, 976
    d.rectangle([bx0 + 6, by0 + 8, bx1 + 6, by1 + 8], fill=(0, 0, 0, 130))
    d.rectangle([bx0, by0, bx1, by1], fill=BOARD, outline=BOARD_EDGE, width=4)
    hazard_strip(d, bx0, by1 - 14, bx1, by1)
    f_title = fit(d, "ZONES", bx1 - bx0 - 420, 118, "impact.ttf", "arialbd.ttf")
    stroked(d, (bx0 + 36, by0 + 22), "ZONES", f_title, GOLD, (60, 44, 20, 255), 6)
    f_sub = font(40, "segoeuib.ttf", "arialbd.ttf")
    sub = "MiniMap Server Zones"
    sw = d.textlength(sub, font=f_sub)
    sx1 = bx1 - 24
    sx0 = sx1 - sw - 40
    d.rectangle([sx0, by1 - 84, sx1, by1 - 26], fill=(52, 46, 34, 230),
                outline=BOARD_EDGE, width=3)
    stroked(d, (sx0 + 20, by1 - 78), sub, f_sub, PALE, INK, 2)
    tape(d, bx0 + 26, by0 + 10)
    tape(d, bx1 - 26, by0 + 10)
    # ADD-ON 徽章（同 maps_poster：疊標題板左上）
    f_badge = font(42, "arialbd.ttf", "segoeuib.ttf")
    bw = d.textlength("ADD-ON", font=f_badge)
    ax0, ay0 = bx0 + 14, by0 - 34
    d.rectangle([ax0, ay0, ax0 + bw + 48, ay0 + 62], fill=HAZ_Y, outline=BOARD_EDGE, width=4)
    for s in range(int(ax0) - 60, int(ax0 + bw + 48), 30):
        d.polygon([(s, ay0 + 62), (s + 12, ay0 + 62), (s + 24, ay0), (s + 12, ay0)],
                  fill=HAZ_K if (s // 30) % 2 == 0 else HAZ_Y)
    d.rectangle([ax0 + 34, ay0 + 6, ax0 + bw + 14, ay0 + 56], fill=HAZ_Y)
    stroked(d, (ax0 + 38, ay0 + 8), "ADD-ON", f_badge, HAZ_K, HAZ_Y, 1)
    # for Build 42 小板（頂部左，主 poster 語彙）
    f_b42 = font(38, "segoeuib.ttf", "arialbd.ttf")
    tw = d.textlength("for Build 42", font=f_b42)
    d.rectangle([26, 26, 26 + tw + 44, 82], fill=(52, 46, 34, 225), outline=BOARD_EDGE, width=3)
    stroked(d, (48, 32), "for Build 42", f_b42, PALE, INK, 2)
    return im


im = zones_poster().resize((512, 512), Image.LANCZOS).convert("RGB")
im.save(OUT_POSTER, "PNG")
im.save(OUT_PREVIEW, "PNG")
print("寫出:", OUT_POSTER)
print("寫出:", OUT_PREVIEW)
