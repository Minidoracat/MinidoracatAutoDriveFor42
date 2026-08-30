"""把 repo 根目錄的 16:9 系列封面等比例縮入 512×512 黑底，輸出遊戲 poster 與 Workshop preview。

來源已是完成稿（含 Minidoracat / AUTO DRIVE / for Build 42 標題板），不得再疊第二套標題。
用法：python -B scripts/poster/finish_poster.py
"""
from pathlib import Path

from PIL import Image


SCRIPT_DIR = Path(__file__).resolve().parent
REPO = SCRIPT_DIR.parent.parent
SOURCE = REPO / "Minidoracat_AutoDrive_B42_cover_series.png"
MOD_ROOT = REPO / "MOD" / "MinidoracatAutoDriveFor42"
MOD_42 = MOD_ROOT / "Contents" / "mods" / "MinidoracatAutoDriveFor42" / "42"
SIZE = 512
RESAMPLE = Image.Resampling.LANCZOS


def build_poster() -> Image.Image:
    source = Image.open(SOURCE).convert("RGB")
    scale = min(SIZE / source.width, SIZE / source.height)
    resized = source.resize(
        (max(1, round(source.width * scale)), max(1, round(source.height * scale))),
        RESAMPLE,
    )
    poster = Image.new("RGB", (SIZE, SIZE), (0, 0, 0))
    poster.paste(resized, ((SIZE - resized.width) // 2, (SIZE - resized.height) // 2))
    return poster


def save(poster: Image.Image) -> None:
    targets = (
        SCRIPT_DIR / "posters" / "poster.png",
        SCRIPT_DIR / "posters" / "preview.png",
        MOD_42 / "poster.png",
        MOD_ROOT / "preview.png",
    )
    for target in targets:
        target.parent.mkdir(parents=True, exist_ok=True)
        poster.save(target, "PNG")
        print("寫出:", target)


if __name__ == "__main__":
    save(build_poster())
    print("done")
