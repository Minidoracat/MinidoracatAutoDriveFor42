# -*- coding: utf-8 -*-
"""把主視覺（codex imagegen 產出的 1024x1024）疊上 PZ 風標題板，
輸出 poster.png / preview.png（512x512）並部署到 MOD 目錄。Deterministic：無隨機數。

前置：把主視覺放成本目錄下的 main_art.png（1024x1024，上方 25% 需留白給標題板）。
用法：python scripts/poster/finish_poster.py

家族視覺語言：暗橄欖告示板＋警戒黃斜紋條＋泛黃膠帶，標題用 Impact 金色、品牌名 Segoe UI Bold 米白。
"""
import os
from PIL import Image, ImageDraw, ImageFont

SP = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(SP))
MOD_42 = os.path.join(REPO, "MOD", "MinidoracatAutoDriveFor42", "Contents", "mods", "MinidoracatAutoDriveFor42", "42")
MOD_ROOT = os.path.join(REPO, "MOD", "MinidoracatAutoDriveFor42")

TITLE = "AUTODRIVE"      # 主標（英文大寫，如 MINIMAP / CLEANER）
BRAND = "Minidoracat"
SUBTITLE = "for Build 42"

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
        draw.polygon([(s, y1), (s + step, y1), (s + step + (y1 - y0), y0), (s + (y1 - y0), y0)],
                     fill=HAZ_K)
    draw.rectangle([x0, y0, x1, y1], outline=BOARD_EDGE, width=3)


def load_art(name="main_art.png"):
    im = Image.open(os.path.join(SP, name)).convert("RGBA")
    if im.size != (1024, 1024):
        im = im.resize((1024, 1024), Image.LANCZOS)
    return im


def build_poster():
    im = load_art()
    d = ImageDraw.Draw(im)
    bx0, by0, bx1, by1 = 28, 26, 660, 232
    d.rectangle([bx0 + 6, by0 + 8, bx1 + 6, by1 + 8], fill=(0, 0, 0, 120))   # 投影
    d.rectangle([bx0, by0, bx1, by1], fill=BOARD, outline=BOARD_EDGE, width=4)
    hazard_strip(d, bx0, by0, bx1, by0 + 14)
    tape(d, bx0 + 26, by0 + 10)
    tape(d, bx1 - 26, by0 + 10)

    f_brand = fit(d, BRAND, bx1 - bx0 - 60, 54, "segoeuib.ttf", "arialbd.ttf")
    f_title = fit(d, TITLE, bx1 - bx0 - 56, 106, "impact.ttf", "arialbd.ttf")
    stroked(d, (bx0 + 30, by0 + 30), BRAND, f_brand, PALE, INK, 3)
    stroked(d, (bx0 + 28, by0 + 88), TITLE, f_title, GOLD, INK, 5)

    f_sub = font(38, "segoeuib.ttf", "arialbd.ttf")
    sw = d.textlength(SUBTITLE, font=f_sub)
    d.rectangle([bx0, by1 + 10, bx0 + sw + 44, by1 + 66], fill=(52, 46, 34, 225),
                outline=BOARD_EDGE, width=3)
    stroked(d, (bx0 + 22, by1 + 16), SUBTITLE, f_sub, PALE, INK, 2)
    return im


def save(im):
    small = im.resize((512, 512), Image.LANCZOS).convert("RGB")
    out = os.path.join(SP, "posters")
    os.makedirs(out, exist_ok=True)
    for t in [os.path.join(out, "poster.png"),
              os.path.join(out, "preview.png"),
              os.path.join(MOD_42, "poster.png"),      # 遊戲內海報
              os.path.join(MOD_ROOT, "preview.png")]:  # Workshop 預覽
        os.makedirs(os.path.dirname(t), exist_ok=True)
        small.save(t, "PNG")
        print("寫出:", t)


if __name__ == "__main__":
    save(build_poster())
    print("done")
