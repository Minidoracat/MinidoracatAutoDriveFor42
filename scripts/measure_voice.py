"""量 MDAD 語音音檔的響度與 true peak（新錄、重錄或調整語音後跑；需要 ffmpeg）。
用法（repo 根目錄）：python scripts/measure_voice.py [額外比較檔或資料夾 ...]
每檔跑 ffmpeg ebur128=peak=true，取 Integrated LUFS 與 True peak dBTP；依聲音（actor）分組印中位數。
判準見知識庫 hud-voice.md〈不變式〉：TP ≤ −1.5 dBTP、各聲音響度中位差 ≤1 dB。
"""
import concurrent.futures as cf
import glob
import os
import re
import statistics
import subprocess
import sys

VOICE_DIR = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/sound/MinidoracatAutoDrive"
ACTORS = ["stacy_brief", "yui_brief", "stacy", "yui", "classic"]


def measure(path):
    r = subprocess.run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-af", "ebur128=peak=true", "-f", "null", "-"],
                       capture_output=True, text=True, errors="replace").stderr
    tail = r[r.rfind("Summary:"):]
    i = re.search(r"I:\s+(-?[\d.]+|-inf) LUFS", tail)
    p = re.search(r"Peak:\s+(-?[\d.]+|-inf) dBFS", tail)
    return path, float(i.group(1)) if i else None, float(p.group(1)) if p else None


def actor_of(name):
    for a in ACTORS:  # brief 先比，免得被 stacy 吃掉
        if name.endswith("_" + a + ".wav"):
            return a
    return "?"


def summarize(label, rows):
    lufs = [x[1] for x in rows if x[1] is not None and x[1] > -70]
    peak = [x[2] for x in rows if x[2] is not None]
    if not lufs:
        print(f"{label:22s} n=0")
        return
    print(f"{label:22s} n={len(lufs):3d}  LUFS median {statistics.median(lufs):6.1f}  min {min(lufs):6.1f}  max {max(lufs):6.1f}"
          f"  | truePeak median {statistics.median(peak):5.1f}  max {max(peak):5.1f} dBTP")


def main():
    files = sorted(glob.glob(os.path.join(VOICE_DIR, "voice_*.wav")))
    with cf.ThreadPoolExecutor(8) as ex:
        rows = list(ex.map(measure, files))
    by = {}
    for row in rows:
        by.setdefault(actor_of(os.path.basename(row[0])), []).append(row)
    print("== 全部語言，依聲音 ==")
    for a in ACTORS:
        summarize(a, by.get(a, []))
    print("== 只看 zh（簡中玩家預設語音包）==")
    for a in ACTORS:
        summarize(a + " zh", [r for r in by.get(a, []) if "_zh_" in os.path.basename(r[0])])
    summarize("ALL", rows)
    extra = []
    for arg in sys.argv[1:]:
        extra += sorted(glob.glob(os.path.join(arg, "**", "*.*"), recursive=True)) if os.path.isdir(arg) else [arg]
    extra = [f for f in extra if f.lower().endswith((".wav", ".ogg", ".mp3"))]
    if extra:
        with cf.ThreadPoolExecutor(8) as ex:
            ext = list(ex.map(measure, extra))
        print("== 比較檔 ==")
        for path, i, p in ext:
            print(f"{i!s:>7} LUFS  {p!s:>6} dBTP  {path}")


if __name__ == "__main__":
    main()
