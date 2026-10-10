"""伺服器診斷上傳的索引工具：列出新片段、標記已分析、對帳本機缺檔。

伺服器端 Uploads/index.txt（MDAD_UploadServer.lua 產生）以唯讀方式抓回本機後：
    python scripts/upload_index.py new  <Uploads 目錄> [--since EPOCH]   # 本機有、尚未分析的片段＋窗口內缺檔的 MISSING
    python scripts/upload_index.py all  <Uploads 目錄>                   # index 裡全部現存片段
    python scripts/upload_index.py mark <Uploads 目錄> <片段 id>...       # 記為已分析（id 必須在 index 裡）
    python scripts/upload_index.py mark <Uploads 目錄> --new [--since EPOCH]  # 把目前 new 列出的全部記為已分析
    python scripts/upload_index.py --self-test
窗口（只看這段時間上傳的片段）：--since（epoch 秒或毫秒）＞目錄裡 pull.json 的 since（取回工具寫）＞本機最早片段。
「本機有」＝路徑存在、內容的 UTF-16 code unit 數等於 index 的 bytes（伺服器記的是 Kahlua `#`＝UTF-16 單位，
不是位元組；非 BMP 字元算 2），且首行片段檔頭的 drive／trig 與 index 相同（槽會被覆蓋，同路徑舊檔不算）。
窗口內 index 有、本機沒有或對不上＝MISSING（附原因），exit 1。
已分析清單在 .omc/upload-ledger.txt（本機、不入庫）；伺服器一律唯讀，不回寫。
片段本體用 analyze_telemetry.py 分析：python scripts/analyze_telemetry.py tl <clip 路徑>
"""
import argparse
import json
import os
import sys

LEDGER = os.path.join(os.path.dirname(__file__), "..", ".omc", "upload-ledger.txt")
COLS = ["type", "id", "serverTs", "folder", "slot", "bytes", "kind", "pri", "trig",
        "rev", "veh", "x", "y", "user", "drive"]


def rows(root):
    with open(os.path.join(root, "index.txt"), encoding="utf-8") as fh:
        for line in fh:
            yield line.rstrip("\n").split("\t")


def live_clips(root):
    """C 列依序套用、X 列清除；同一槽以最後一列為準（與伺服器 load() 相同：槽號取整數）。"""
    slots = {}
    for t in rows(root):
        if t[0] == "C" and len(t) >= len(COLS) and t[4].isdigit() and t[3]:
            slots[(t[3], int(t[4]))] = dict(zip(COLS, t))
        elif t[0] == "X" and len(t) >= 3 and t[2].isdigit():
            slots.pop((t[1], int(t[2])), None)
    return sorted(slots.values(), key=lambda c: float(c["serverTs"] or 0))


def clip_path(root, c):
    return os.path.join(root, c["folder"], "clip-%02d.log" % int(c["slot"]))


def utf16_units(text):
    return len(text.encode("utf-16-le")) // 2


def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def local_state(root, c):
    """本機檔與 index 列對得上回傳 None，否則回傳原因。"""
    p = clip_path(root, c)
    if not os.path.isfile(p):
        return "無檔"
    with open(p, "rb") as fh:
        raw = fh.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return "不是 UTF-8"
    units = utf16_units(text)
    if units != _num(c["bytes"]):
        return f"長度 {units}≠index {c['bytes']}（UTF-16 單位）"
    try:
        head = json.loads(text.split("\n", 1)[0])
    except ValueError:
        head = None
    if not isinstance(head, dict) or head.get("t") != "clip":
        return "首行不是片段檔頭"
    for k in ("drive", "trig"):
        iv, hv = _num(c[k]), _num(head.get(k))
        if iv is not None and hv is not None and abs(iv - hv) > 0.5:
            return f"首行 {k} 不符（同槽舊檔）"
    return None


def is_local(root, c):
    return local_state(root, c) is None


def window_since(root, clips, since, state):
    """回傳 (since 毫秒, 來源)。state＝{id: local_state}。"""
    if since is not None:
        return (since * 1000 if since < 1e12 else since), "--since"
    pj = os.path.join(root, "pull.json")
    if os.path.exists(pj):
        with open(pj, encoding="utf-8") as fh:
            return float(json.load(fh)["since"]) * 1000, "pull.json"
    local = [float(c["serverTs"]) for c in clips if state[c["id"]] is None]
    return (min(local), "本機最早片段") if local else (0, "整份 index（本機沒有任何片段）")


def reconcile(root, since=None):
    """窗口內現存片段分成 (本機有, 缺檔或對不上（c["why"]＝原因）, 窗口說明)。取回工具也用這個對帳。"""
    clips = live_clips(root)
    state = {c["id"]: local_state(root, c) for c in clips}
    ms, src = window_since(root, clips, since, state)
    win = [c for c in clips if float(c["serverTs"] or 0) >= ms]
    have = [c for c in win if state[c["id"]] is None]
    missing = [dict(c, why=state[c["id"]]) for c in win if state[c["id"]] is not None]
    return have, missing, f"窗口 serverTs≥{ms:.0f}（{src}）"


def ledger():
    if not os.path.exists(LEDGER):
        return set()
    with open(LEDGER, encoding="utf-8") as fh:
        return {line.strip() for line in fh if line.strip()}


def show(root, clips):
    for c in clips:
        print(f"{c['id']}\t{c['kind']}\tpri={c['pri']}\trev={c['rev']}\t{c['veh']}"
              f"\t({c['x']},{c['y']})\t{c['user']}\t{clip_path(root, c)}")


def new_clips(root, since):
    have, missing, note = reconcile(root, since)
    done = ledger()
    return [c for c in have if c["id"] not in done], missing, note


def cmd_new(a):
    clips, missing, note = new_clips(a.dir, a.since)
    show(a.dir, clips)
    for c in missing:
        print(f"MISSING\t{c['id']}\t{c['why']}\t{clip_path(a.dir, c)}")
    print(f"{len(clips)} new clips, {len(missing)} missing；{note}")
    return 1 if missing else 0


def cmd_all(a):
    clips = live_clips(a.dir)
    show(a.dir, clips)
    print(f"{len(clips)} clips")
    return 0


def cmd_mark(a):
    if a.new:
        if a.ids:
            print("mark：--new 與 id 清單擇一")
            return 2
        ids = [c["id"] for c in new_clips(a.dir, a.since)[0]]
    else:
        known = {t[1] for t in rows(a.dir) if t[0] == "C" and len(t) > 1}
        bad = [i for i in a.ids if i not in known]
        if bad or not a.ids:
            for i in bad:
                print(f"mark：index 沒有這個 id：{i}")
            print("mark：沒有寫入任何 id")
            return 2
        ids = a.ids
    done = ledger()
    add = [i for i in dict.fromkeys(ids) if i not in done]
    os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
    with open(LEDGER, "a", encoding="utf-8", newline="") as fh:
        for i in add:
            fh.write(i + "\n")
    print(f"marked {len(add)}（已在清單 {len(ids) - len(add)}）")
    return 0


def self_test():
    import tempfile
    global LEDGER
    fails = []

    def check(ok, label):
        print(("  ok   " if ok else "  FAIL ") + label)
        if not ok:
            fails.append(label)

    with tempfile.TemporaryDirectory() as root:
        LEDGER = os.path.join(root, "ledger.txt")

        def put(folder, slot, ts, body, drive=None, cut=0):
            """寫片段（首行檔頭＋body），回傳 (id, 完整內容的 UTF-16 單位數)；cut＞0＝本機檔少最後 cut 個字。"""
            text = json.dumps({"t": "clip", "trig": ts, "drive": drive or ts}) + "\n" + body
            os.makedirs(os.path.join(root, folder), exist_ok=True)
            with open(os.path.join(root, folder, "clip-%02d.log" % slot), "w", encoding="utf-8", newline="") as fh:
                fh.write(text[:len(text) - cut])
            return f"{folder}/clip-{slot:02d}.log@{ts}", utf16_units(text)

        def crow(cid, ts, folder, slot, nbytes):
            return "\t".join(["C", cid, str(ts), folder, str(slot), str(nbytes), "contact", "2", str(ts),
                              "1010a", "Base.Car", "1", "2", folder, str(ts)])

        wide = '{"t":"e","why":"中文路名🚗"}\n'                 # 中文＝3 bytes／1 單位；🚗 非 BMP＝4 bytes／2 單位
        old = "A/clip-01.log@1000"                       # 窗口外的舊片段（本機沒有，不算缺）
        a2, n2 = put("A", 2, 5000, "x" * 10)              # 本機有
        c1, nc1 = put("C", 1, 5500, wide * 3)             # 本機有、含中文與非 BMP 的完整檔
        c2, nc2 = put("C", 2, 5600, wide * 3, cut=1)      # 同內容但截斷最後一字＝MISSING
        b1 = "B/clip-01.log@6000"                         # 窗口內、本機沒有＝MISSING
        b2 = "B/clip-02.log@4800"                         # 比本機最早片段早、但在 pull.json 窗口內＝MISSING
        a3, n3 = put("A", 3, 7000, "y" * 5)               # 本機舊版：長度不符＝MISSING
        a5, n5 = put("A", 5, 7500, "w" * 5, drive=1)      # 長度相同、首行 drive 是別趟（同槽舊檔）＝MISSING
        a4, n4 = put("A", 4, 8000, "z" * 3)               # 窗口內、本機有，但已被 X 清掉＝不算
        idx = [crow(old, 1000, "A", 1, 9), crow(a2, 5000, "A", 2, n2), crow(c1, 5500, "C", 1, nc1),
               crow(c2, 5600, "C", 2, nc2), crow(b1, 6000, "B", 1, 4), crow(b2, 4800, "B", 2, 4),
               crow(a3, 7000, "A", 3, n3 + 1), crow(a5, 7500, "A", 5, n5), crow(a4, 8000, "A", 4, n4), "X\tA\t4", "S\t2"]
        with open(os.path.join(root, "index.txt"), "w", encoding="utf-8", newline="") as fh:
            fh.write("# header\n" + "\n".join(idx) + "\n")
        with open(os.path.join(root, "pull.json"), "w", encoding="utf-8", newline="") as fh:
            json.dump({"since": 4.5}, fh)
        have, missing, note = reconcile(root)
        why = {c["id"]: c["why"] for c in missing}
        check(os.path.getsize(clip_path(root, {"folder": "C", "slot": 1})) > nc1 > len(wide * 3),
              "（前提）中文／非 BMP 檔：位元組數＞UTF-16 單位數＞字元數")
        check(sorted(c["id"] for c in have) == sorted([a2, c1]), "本機有＝UTF-16 長度相符、檔頭相符、未被 X 清掉（含中文與非 BMP 的完整檔）")
        check(why.get(c2, "").startswith("長度"), "中文檔截斷一字＝MISSING（長度）")
        check(why.get(a5, "").startswith("首行 drive"), "長度相同但首行 drive 不同（同槽舊檔）＝MISSING")
        check(set(why) == {b1, b2, a3, c2, a5} and why[b1] == "無檔" and "pull.json" in note,
              "窗口取 pull.json；窗口內缺檔與對不上都列 MISSING，窗口外不列")
        check(reconcile(root, since=0)[1][0]["id"] == old, "--since 0 時舊片段也算缺")
        check(run(["new", root]) == 1, "有 MISSING 時 new exit 1")
        check(run(["mark", root, "--help"]) == 0 and not os.path.exists(LEDGER), "mark --help 只印說明、不寫 ledger")
        check(run(["mark", root, "B/clip-09.log@1"]) == 2 and not os.path.exists(LEDGER), "mark 拒收 index 沒有的 id、不寫 ledger")
        check(run(["mark", root, a2]) == 0 and ledger() == {a2}, "mark 合法 id 寫入")
        check([c["id"] for c in new_clips(root, None)[0]] == [c1], "mark 後 new 不再列該段，只剩沒 mark 的")
        check(run(["mark", root, a2]) == 0 and open(LEDGER, encoding="utf-8").read().count(a2) == 1, "重複 mark 不重寫")
    print(f"self-test：{len(fails)} 項失敗")
    return 1 if fails else 0


def run(argv):
    try:
        return main(argv)
    except SystemExit as e:
        return e.code


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("new", help="本機有、尚未分析的片段；窗口內缺檔印 MISSING")
    p.add_argument("dir")
    p.add_argument("--since", type=float, help="epoch 秒或毫秒")
    p.set_defaults(fn=cmd_new)
    p = sub.add_parser("all", help="index 裡全部現存片段")
    p.add_argument("dir")
    p.set_defaults(fn=cmd_all)
    p = sub.add_parser("mark", help="記為已分析")
    p.add_argument("dir")
    p.add_argument("ids", nargs="*")
    p.add_argument("--new", action="store_true", help="標記目前 new 列出的全部")
    p.add_argument("--since", type=float)
    p.set_defaults(fn=cmd_mark)
    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
