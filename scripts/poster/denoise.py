# -*- coding: utf-8 -*-
"""對候選圖做 NL-means 去噪（保邊緣、抹平噪點與 AI 雜訊）。

用法：python scripts/poster/denoise.py [prefix ...]
預設處理 codex_A/B/C，輸出 <名稱>_clean.png。
h/hColor 刻意保守（5/4），避免把髮絲與 UI 面板細節抹糊。
"""
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

CAND = Path(__file__).parent / "candidates"


def denoise(src: Path, dst: Path, h=5, h_color=4):
    bgr = cv2.cvtColor(np.asarray(Image.open(src).convert("RGB")), cv2.COLOR_RGB2BGR)
    out = cv2.fastNlMeansDenoisingColored(bgr, None, h, h_color, 7, 21)
    Image.fromarray(cv2.cvtColor(out, cv2.COLOR_BGR2RGB)).save(dst, format="PNG")
    print("ok", dst.name)


if __name__ == "__main__":
    names = sys.argv[1:] or ["codex_A", "codex_B", "codex_C"]
    for n in names:
        denoise(CAND / f"{n}.png", CAND / f"{n}_clean.png")
