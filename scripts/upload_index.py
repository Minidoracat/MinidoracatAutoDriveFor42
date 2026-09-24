"""伺服器診斷上傳的索引工具：列出新片段、標記已分析。

伺服器端 Uploads/index.txt（MDAD_UploadServer.lua 產生）以唯讀方式抓回本機後：
    python scripts/upload_index.py new  <Uploads 目錄>          # 尚未分析的現存片段（新的在後）
    python scripts/upload_index.py all  <Uploads 目錄>          # 全部現存片段
    python scripts/upload_index.py mark <片段 id> [...]          # 記為已分析
已分析清單在 .omc/upload-ledger.txt（本機、不入庫）；伺服器一律唯讀，不回寫。
片段本體用 analyze_telemetry.py 分析：python scripts/analyze_telemetry.py contact <clip 路徑>
"""
import os
import sys

LEDGER = os.path.join(os.path.dirname(__file__), "..", ".omc", "upload-ledger.txt")
COLS = ["type", "id", "serverTs", "folder", "slot", "bytes", "kind", "pri", "trig",
        "rev", "veh", "x", "y", "user", "drive"]


def live_clips(root):
    """C 列依序套用、X 列清除；同一槽以最後一列為準（與伺服器載入邏輯相同）。"""
    slots = {}
    with open(os.path.join(root, "index.txt"), encoding="utf-8") as fh:
        for line in fh:
            t = line.rstrip("\n").split("\t")
            if t[0] == "C" and len(t) >= len(COLS):
                slots[(t[3], t[4])] = dict(zip(COLS, t))
            elif t[0] == "X" and len(t) >= 3:
                slots.pop((t[1], t[2]), None)
    return sorted(slots.values(), key=lambda c: float(c["serverTs"] or 0))


def ledger():
    if not os.path.exists(LEDGER):
        return set()
    with open(LEDGER, encoding="utf-8") as fh:
        return {line.strip() for line in fh if line.strip()}


def show(root, clips):
    for c in clips:
        path = os.path.join(root, c["folder"], "clip-%02d.log" % int(c["slot"]))
        print(f"{c['id']}\t{c['kind']}\tpri={c['pri']}\trev={c['rev']}\t{c['veh']}"
              f"\t({c['x']},{c['y']})\t{c['user']}\t{path}")
    print(f"{len(clips)} clips")


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd = argv[0]
    if cmd in ("new", "all"):
        clips = live_clips(argv[1])
        if cmd == "new":
            done = ledger()
            clips = [c for c in clips if c["id"] not in done]
        show(argv[1], clips)
        return 0
    if cmd == "mark":
        os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
        with open(LEDGER, "a", encoding="utf-8") as fh:
            for cid in argv[1:]:
                fh.write(cid + "\n")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
