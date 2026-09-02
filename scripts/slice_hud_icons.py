#!/usr/bin/env python3
"""把 codex image_gen 產出的 HUD 圖示表切成 32×32 純白 RGBA 按鈕圖示。

輸入：docs/design/hud-icons-sheet.png（2048×1536，4 欄 × 3 列，每格 512×512，
      白色圖示；背景透明或純黑皆可——有 alpha 就用 alpha×亮度，否則用亮度當 alpha）。
輸出：MOD/…/42/media/ui/MinidoracatAutoDrive/hud_<name>.png（只輸出 HUD 有用到的格）。

用法：python scripts/slice_hud_icons.py [--sheet PATH] [--size 32] [--dry-run]
"""
import argparse
import os
import sys

from PIL import Image, ImageChops, ImageOps

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHEET = os.path.join(REPO, "docs", "design", "hud-icons-sheet.png")
OUT_DIR = os.path.join(REPO, "MOD", "MinidoracatAutoDriveFor42", "Contents", "mods",
                       "MinidoracatAutoDriveFor42", "42", "media", "ui", "MinidoracatAutoDrive")
COLS, ROWS = 4, 3
# 表上 12 格的順序（temp/codex-hud-icons-prompt.md）；None＝備用格不出貨
NAMES = ["chevron_left", "chevron_right", "chevron_up", "chevron_down",
         "palette", "speaker_on", "speaker_off", "detour",
         "zombie", "skull", None, None]
GLYPH_FILL = 0.82  # 圖示佔 32 格的比例（留 3px 呼吸邊，按鈕 16px 顯示時不糊邊）


def cell_alpha(cell):
    """回傳 L 模式 alpha：透明底＝自身 alpha × 亮度（白圖示，邊緣不帶灰）；不透明底
    （黑底白圖）＝亮度。"""
    lum = ImageOps.grayscale(cell.convert("RGB"))
    if cell.mode in ("RGBA", "LA"):
        alpha = cell.getchannel("A")
        if alpha.getextrema()[0] < 255:  # 真的有透明像素
            return ImageChops.multiply(lum, alpha)
    return lum


def slice_sheet(sheet_path, out_dir, size, dry_run):
    sheet = Image.open(sheet_path)
    w, h = sheet.size
    cw, ch = w // COLS, h // ROWS
    if (cw, ch) != (512, 512):
        print(f"warn: 格尺寸 {cw}x{ch}（預期 512x512），照比例切", file=sys.stderr)
    written = []
    for idx, name in enumerate(NAMES):
        if name is None:
            continue
        col, row = idx % COLS, idx // COLS
        cell = sheet.crop((col * cw, row * ch, (col + 1) * cw, (row + 1) * ch))
        alpha = cell_alpha(cell).point(lambda v: 0 if v < 24 else v)  # 壓掉底噪
        bbox = alpha.getbbox()
        if not bbox:
            raise SystemExit(f"格 {idx + 1}（{name}）沒有白色像素")
        alpha = alpha.crop(bbox)
        side = max(alpha.size)
        square = Image.new("L", (side, side), 0)
        square.paste(alpha, ((side - alpha.width) // 2, (side - alpha.height) // 2))
        glyph_px = max(1, int(round(size * GLYPH_FILL)))
        small = square.resize((glyph_px, glyph_px), Image.LANCZOS)
        out_alpha = Image.new("L", (size, size), 0)
        out_alpha.paste(small, ((size - glyph_px) // 2, (size - glyph_px) // 2))
        rgba = Image.merge("RGBA", [Image.new("L", (size, size), 255)] * 3 + [out_alpha])
        path = os.path.join(out_dir, f"hud_{name}.png")
        coverage = sum(1 for v in out_alpha.getdata() if v > 64) / (size * size)
        print(f"{name:14s} 格 {idx + 1:2d} bbox={bbox} 覆蓋率={coverage:.1%} -> {os.path.relpath(path, REPO)}")
        if not dry_run:
            os.makedirs(out_dir, exist_ok=True)
            rgba.save(path, optimize=True)
        written.append(path)
    return written


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sheet", default=SHEET)
    ap.add_argument("--out-dir", default=OUT_DIR)
    ap.add_argument("--size", type=int, default=32)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    written = slice_sheet(args.sheet, args.out_dir, args.size, args.dry_run)
    print(f"{'would write' if args.dry_run else 'wrote'} {len(written)} icons")


if __name__ == "__main__":
    main()
