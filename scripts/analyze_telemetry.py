"""telemetry 復盤工具：本機 session、E2E 收集目錄、上傳片段共用。

來源參數（可給多個；同一趟的多個 part 依 header 的 drive／part 自動串成一趟，給的順序不拘）：
    012 / 12                       本機 %USERPROFILE%\\Zomboid\\Lua\\MinidoracatAutoDrive\\Telemetry\\session-012.log
    <檔案路徑>                      session-NNN.log 或上傳片段 clip-NN.log（片段各自獨立，不跨檔合併）
    <目錄>                          E2E 收集目錄（讀其下 Telemetry/）、Telemetry 目錄或 Uploads 的玩家資料夾

    python scripts/analyze_telemetry.py sum 012 013        # 每趟：時長、cap／intent／hbr 分布、事件、弧段數、sk<0.5 數
    python scripts/analyze_telemetry.py corner 012          # 每個弧段：R、cap、入弧速、最低 tgt／spd、sk／ld／err、BRAKE／CONTACT 旗標
    python scripts/analyze_telemetry.py stops 012           # spd<3 持續 ≥0.8s 的窗口與當時 intent／cap／ctl／hbr／hold
    python scripts/analyze_telemetry.py contact 018         # contact／unstick／blocked／return／progress 事件＋contact 前 16 筆逐幀
    python scripts/analyze_telemetry.py win 013 21 25       # 逐幀（秒＝相對第一筆樣本；含計算出的 yaw 角速度）
    python scripts/analyze_telemetry.py tl <來源> [console.txt] [--from 秒 --to 秒]
        # 事件＋console 依時間合併（給 --from/--to 才加逐幀樣本）。console 行換算：Debug print 尾端 t=<epoch ms> 直接用；
        # 其餘行用 [E2E] CLOCK ms= 那幾行的 f:<幀號>→epoch 對照線性內插（行首 C= 精確、C~ 內插）。
        # 兩種都沒有的舊 log 會明講「對不上」，只印 telemetry。
    python scripts/analyze_telemetry.py first <來源> [--pre 5]
        # 第一個 contact／impact／blocked／forceBrake／state-error／teleport，與各自前 5 秒逐筆（樣本＋事件）
    python scripts/analyze_telemetry.py clips <Uploads 目錄|clip...>   # 上傳片段一列一段自動分流（觸發前後速度、掉速、帽、事件）
    python scripts/analyze_telemetry.py --self-test

判讀口訣與欄位字典在 postmortem skill 與 references/telemetry.md。
"""
import argparse
import bisect
import collections
import glob
import json
import math
import os
import re
import statistics as S
import sys

TDIR = os.path.expandvars(r"%USERPROFILE%\Zomboid\Lua\MinidoracatAutoDrive\Telemetry")


# ---------- 載入 ----------

def load_file(path):
    clip = hdr = None
    recs = []
    for line in open(path, encoding="utf-8", errors="replace"):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        t = o.get("t")
        if t == "clip":
            clip = o
        elif t == "h":
            hdr = o
        elif t in ("s", "e") and isinstance(o.get("ts"), (int, float)):
            recs.append(o)
    return clip, hdr or {}, recs


def resolve(arg):
    if os.path.isfile(arg):
        return [arg]
    if os.path.isdir(arg):
        # 收集目錄：舊版 <輪次>/Telemetry、新版 <輪次>/clientN/Telemetry；否則就是 Telemetry 或玩家資料夾本身
        ds = [d for d in [os.path.join(arg, "Telemetry")] + sorted(glob.glob(os.path.join(arg, "*", "Telemetry")))
              if os.path.isdir(d)] or [arg]
        files = sorted(f for d in ds for pat in ("session-*.log", "clip-*.log") for f in glob.glob(os.path.join(d, pat)))
        if not files:
            sys.exit(f"{arg}：目錄裡沒有 session-*.log／clip-*.log")
        return files
    if arg.isdigit():
        p = os.path.join(TDIR, "session-%03d.log" % int(arg))
        if os.path.isfile(p):
            return [p]
    sys.exit(f"找不到來源：{arg}")


def drives(args):
    """來源參數 → 一趟一個 dict：name hdr clip recs rows evs t0。session 依 header drive 分組、part 排序。"""
    groups = collections.OrderedDict()
    for a in args:
        for p in resolve(a):
            clip, hdr, recs = load_file(p)
            key = ("clip", p) if clip else ("drive", hdr.get("drive") or hdr.get("ts") or p)
            groups.setdefault(key, []).append((hdr.get("part") or 1, p, clip, hdr, recs))
    out = []
    for parts in groups.values():
        parts.sort(key=lambda x: x[0])
        recs = sorted((r for x in parts for r in x[4]), key=lambda r: r["ts"])
        rows = [r for r in recs if r["t"] == "s"]
        name = "+".join(os.path.basename(x[1]) for x in parts)
        t0 = rows[0]["ts"] if rows else (recs[0]["ts"] if recs else 0)
        out.append({"name": name, "hdr": parts[0][3], "clip": parts[0][2], "recs": recs, "rows": rows,
                    "evs": [r for r in recs if r["t"] == "e"], "t0": t0, "parts": [x[0] for x in parts]})
    return out


# ---------- 格式 ----------

# (鍵, 顯示名, 小數位)；只印有值的欄位；旗標（None 位數）只在為真時印。
KEYS = [("spd", "spd", 1), ("tgt", "tgt", 1), ("ftg", "ftg", 1), ("des", "des", 1), ("cmdA", "cmdA", 2),
        ("capReason", "cap", ""), ("intent", "int", ""), ("ctl", "ctl", ""), ("m", "m", ""), ("pm", "pm", ""),
        ("rs", "rs", 1), ("rem", "rem", 1), ("lat", "lat", 2), ("el", "el", 2), ("ld", "ld", 2), ("rb", "rb", 2),
        ("err", "err", 2), ("st", "st", 2), ("sff", "sff", 2), ("ast", "ast", 2), ("sk", "sk", 2), ("tn", "tn", ""),
        ("fbl", "fbl", 0), ("fbw", "fbw", ""), ("hbr", "hbr", ""), ("holdReason", "hold", ""),
        ("curveKappa", "ck", 3), ("curveCap", "cc", 1), ("stateError", "stateError", ""),
        ("ib", "ib", None), ("fbt", "fbt", None), ("fb", "fb", None), ("bl", "bl", None), ("dg", "dg", None),
        ("lc", "lc", None), ("ra", "ra", None), ("rh", "rh", None), ("po", "po", None),
        ("curveHardActive", "ch", None)]


def fmt(o, t0, prev=None):
    out = ["(%.1f,%.1f)" % (o.get("x") or 0, o.get("y") or 0)]
    if prev is not None and o["ts"] > prev["ts"] and o.get("h") is not None and prev.get("h") is not None:
        dh = (o["h"] - prev["h"] + math.pi) % (2 * math.pi) - math.pi
        out.append("yaw=%+.3f" % (dh / ((o["ts"] - prev["ts"]) / 1000)))
    for k, name, nd in KEYS:
        v = o.get(k)
        if v is None or v == "":
            continue
        if nd is None:
            if v:
                out.append(name)
        elif isinstance(v, (int, float)) and not isinstance(v, bool) and nd != "":
            out.append("%s=%.*f" % (name, nd, v))
        else:
            out.append(f"{name}={v}")
    sen = o.get("sen") or {}
    for k, name in (("hardN", "hn"), ("zombieN", "zn")):
        if sen.get(k) is not None:
            out.append(f"{name}={sen[k]}")
    return " ".join(out)


def fmt_ev(e):
    keep = {k: v for k, v in e.items() if k not in ("t", "ts", "n", "src", "srcW", "srcS")}
    return f"{e.get('n')} " + json.dumps(keep, ensure_ascii=False, separators=(",", ":"))[:300]


def header(dv):
    h = dv["hdr"]
    prof = h.get("profile") or {}
    print(f"== {dv['name']} rev={h.get('rev')} build={h.get('build')} veh={prof.get('scriptName')} mode={h.get('mode')} "
          f"parts={dv['parts']} t0={dv['t0']} opts={h.get('opts')}")
    if dv["clip"]:
        c = dv["clip"]
        print(f"   clip kind={c.get('kind')} trig at t={(c.get('trig', dv['t0']) - dv['t0']) / 1000:.2f}")


def rel(dv, ts):
    return (ts - dv["t0"]) / 1000


# ---------- console 對時 ----------

FRAME = re.compile(r"\bf:(\d+)(?: st:[\d,]+)?>\s?(.*)")   # SP：f:N>；MP 客戶端與伺服器：f:N st:68,351,919>
CLOCK = re.compile(r"\[E2E\] CLOCK ms=(\d+)")
TEQ = re.compile(r"(?<![\w.])t=(\d{13})\b")
KEEP = re.compile(r"\[E2E\]|\[MDAD|\[Minidoracat|ERROR|Exception|STACK TRACE|attempted")
NO_CLOCK = "沒有 [E2E] CLOCK 也沒有 t=<epoch ms>（舊 log）：console 與 telemetry 對不上時間，console 不併入"


def console_lines(path):
    """回傳 ([(ts, 精確?, 文字)], 說明列)。對時點只用 CLOCK（t= 只換算自己那行）；
    幀號倒退＝新段落（重新載入），各段只用自己的對時點。"""
    anchors = collections.defaultdict(dict)     # 段 → {幀: ms}（同幀取第一個）
    kept = []
    frame, seg = None, 0
    for raw in open(path, encoding="utf-8", errors="replace"):
        m = FRAME.search(raw)
        if m:
            f = int(m.group(1))
            if frame is not None and f < frame:
                seg += 1
            frame, msg = f, m.group(2).rstrip()
        elif frame is None:
            continue
        else:
            msg = raw.rstrip()
        c, t = CLOCK.search(msg), TEQ.search(msg)
        if c:
            anchors[seg].setdefault(frame, int(c.group(1)))
        elif KEEP.search(msg):
            kept.append((seg, frame, int(t.group(1)) if t else None, msg))
    if not anchors and not any(k[2] for k in kept):
        return [], [f"console {path}：{NO_CLOCK}"]
    out, lost = [], 0
    for seg, f, ms, msg in kept:
        if ms is not None:
            out.append((ms, True, msg))
            continue
        pts = sorted(anchors[seg].items())
        if len(pts) < 2:
            lost += 1
            continue
        i = min(max(bisect.bisect_left([p[0] for p in pts], f), 1), len(pts) - 1)
        (fa, ma), (fb, mb) = pts[i - 1], pts[i]
        out.append((ma + (f - fa) * (mb - ma) / (fb - fa), False, msg))
    notes = [f"console {path}：CLOCK 對時點 {sum(len(a) for a in anchors.values())} 個"]
    if lost:
        notes.append(f"console：{lost} 行沒有 t= 且所在段落（幀號重新起算算新段）CLOCK 不足 2 個，對不上時間、未併入")
    return out, notes


def timeline(dv, console=None, t_from=None, t_to=None):
    """回傳 ([(ts, 排序鍵, 標記, 文字)], 說明列)。同 ts 時 事件→樣本→console。"""
    recs = dv["recs"]
    lo = dv["t0"] + t_from * 1000 if t_from is not None else (recs[0]["ts"] - 30000 if recs else -math.inf)
    hi = dv["t0"] + t_to * 1000 if t_to is not None else (recs[-1]["ts"] + 30000 if recs else math.inf)
    window = t_from is not None or t_to is not None
    items, prev = [], None
    for r in recs:
        if r["t"] == "s":
            if window and lo <= r["ts"] <= hi:
                items.append((r["ts"], 1, "S ", fmt(r, dv["t0"], prev)))
            prev = r
        elif r.get("n") != "replan" and lo <= r["ts"] <= hi:
            items.append((r["ts"], 0, "E ", fmt_ev(r)))
    notes = []
    if console:
        lines, notes = console_lines(console)
        items += [(ts, 2, "C=" if exact else "C~", msg) for ts, exact, msg in lines if lo <= ts <= hi]
    items.sort(key=lambda x: (x[0], x[1]))
    return items, notes


# ---------- first ----------

def _contact(r):
    if r["t"] == "e":
        return r.get("n") == "contact"
    return bool(r.get("fb")) or r.get("capReason") == "contact"


FIRST = [
    ("contact", _contact),
    ("impact", lambda r: r["t"] == "e" and r.get("n") == "impact"),
    ("blocked", lambda r: (r.get("n") == "blocked") if r["t"] == "e" else bool(r.get("bl"))),
    ("forceBrake", lambda r: r["t"] == "s" and (bool(r.get("fbt")) or (r.get("fbl") or 0) > 0)),
    ("state-error", lambda r: r["t"] == "s" and bool(r.get("stateError"))),
    ("teleport", lambda r: r["t"] == "e" and r.get("n") == "teleport"),
]


def firsts(dv):
    """{種類: 第一筆紀錄 or None}"""
    return {k: next((r for r in dv["recs"] if pred(r)), None) for k, pred in FIRST}


def pre_window(dv, rec, pre_s):
    lo = rec["ts"] - pre_s * 1000
    out, prev = [], None
    for r in dv["recs"]:
        if r["ts"] > rec["ts"]:
            break
        if r["t"] == "s":
            if r["ts"] >= lo:
                out.append((r, fmt(r, dv["t0"], prev)))
            prev = r
        elif r["ts"] >= lo and r.get("n") != "replan":
            out.append((r, fmt_ev(r)))
    return out


def show_rec(dv, r):
    return ("S " + fmt(r, dv["t0"])) if r["t"] == "s" else ("E " + fmt_ev(r))


# ---------- 舊模式 ----------

def g(o, k, dflt=0):
    v = o.get(k)
    return dflt if v is None else v


def mode_sum(dv):
    rows, evs, t0, hdr = dv["rows"], dv["evs"], dv["t0"], dv["hdr"]
    spd = [r.get("spd", 0) for r in rows]
    car = (hdr.get("profile") or {}).get("scriptName")
    print(f"=== {dv['name']} {car} rev={hdr.get('rev')} dur={(rows[-1]['ts']-t0)/1000:.0f}s n={len(rows)} spd med={S.median(spd):.1f} max={max(spd):.1f} end={evs[-1].get('n') if evs else '?'}/{evs[-1].get('why') if evs else ''}")
    print("  cap:", collections.Counter(r.get("capReason") for r in rows).most_common(10))
    print("  int:", collections.Counter(r.get("intent") for r in rows).most_common(), " hbr:", collections.Counter(r.get("hbr") for r in rows if r.get("hbr")).most_common())
    print("  ev:", sorted(collections.Counter((e.get("n"), e.get("phase") or e.get("why")) for e in evs if e.get("n") not in ("replan",)).items(), key=str))
    print("  arc n=%d  sk<0.5=%d  sl=%s sb=%s pco=%s cl=%s" % (sum(1 for r in rows if r.get("curveHardActive")), sum(1 for r in rows if g(r, "sk", 1) < 0.5), rows[-1].get("sl"), rows[-1].get("sb"), rows[-1].get("pco"), rows[-1].get("cl")))


def mode_stops(dv):
    rows, t0, n = dv["rows"], dv["t0"], dv["name"]
    i = 0
    while i < len(rows):
        if g(rows[i], "spd") < 3 and (rows[i]["ts"]-t0) > 2000 and (rows[-1]["ts"]-rows[i]["ts"]) > 3000:
            j = i
            while j < len(rows) and g(rows[j], "spd") < 3:
                j += 1
            if rows[j-1]["ts"] - rows[i]["ts"] >= 800:
                pre = rows[max(0, i-8)]
                w = rows[i:j]
                cc = lambda k, m=2: collections.Counter(r.get(k) for r in w).most_common(m)
                print(f"  STOP {n} t={(rows[i]['ts']-t0)/1000:6.1f}..{(rows[j-1]['ts']-t0)/1000:6.1f} ({rows[i]['x']:.0f},{rows[i]['y']:.0f}) pre spd={g(pre,'spd'):.1f} err={g(pre,'err'):.2f} | reasons int={cc('intent')} cap={cc('capReason', 3)} ctl={cc('ctl')} hbr={cc('hbr')} hold={cc('holdReason')} pm={cc('pm')} m={cc('m')} errmax={max(abs(g(r,'err')) for r in w):.2f} ch={any(r.get('curveHardActive') for r in rows[max(0,i-5):j])}")
            i = j
        else:
            i += 1


def mode_corner(dv):
    rows, t0, n = dv["rows"], dv["t0"], dv["name"]
    i = 0
    while i < len(rows):
        if rows[i].get("curveHardActive"):
            j = i
            while j < len(rows) and rows[j].get("curveHardActive"):
                j += 1
            win = rows[max(0, i-12):min(len(rows), j+12)]
            mt = min(win, key=lambda r: r.get("tgt", 99)); ms = min(win, key=lambda r: r.get("spd", 99))
            kmax = max((r.get("curveKappa") or 0) for r in rows[i:j]); ccmin = min((r.get("curveCap") or 99) for r in rows[i:j])
            ent = rows[i]
            flag = ""
            if mt.get("tgt", 99) < 10 or ms.get("spd", 99) < 0.5*ent.get("spd", 1): flag += " <<BRAKE"
            if any(r.get("capReason") == "contact" for r in win): flag += " <<CONTACT"
            if any(r.get("hbr") for r in win): flag += " hbr=" + ",".join(sorted(set(r.get("hbr") for r in win if r.get("hbr"))))
            print(f"  arc {n} t={(ent['ts']-t0)/1000:6.1f}..{(rows[j-1]['ts']-t0)/1000:6.1f} ({ent['x']:.0f},{ent['y']:.0f}) R={1/kmax if kmax>0 else 0:5.1f} cc={ccmin:5.1f} entry={ent.get('spd',0):5.1f} | min tgt={mt.get('tgt',0):5.1f}@{(mt['ts']-t0)/1000:.1f} cap={mt.get('capReason')} | min spd={ms.get('spd',0):5.1f}@{(ms['ts']-t0)/1000:.1f} | skmin={min(g(r,'sk',1) for r in win):.2f} ldmax={max(abs(r.get('ld') or 0) for r in win):.2f} errmax={max(abs(r.get('err') or 0) for r in win):.2f}{flag}")
            i = j
        else:
            i += 1


def mode_contact(dv):
    rows, t0, n = dv["rows"], dv["t0"], dv["name"]
    for e in dv["evs"]:
        if e.get("n") in ("contact", "unstick", "blocked", "return", "progress"):
            print(f"  EV {n} t={(e['ts']-t0)/1000:6.1f} {e.get('n')} {e.get('phase') or ''} {e.get('why') or ''} " + " ".join(f"{k}={e[k]}" for k in ("hitS", "hitX", "hitY", "clearance", "d", "kind", "detail", "blocker", "shape", "s", "l", "x", "y") if k in e))
    prev = None
    for i, r in enumerate(rows):
        if r.get("capReason") == "contact" and prev != "contact":
            print(f"--- {n} contact onset #{i}")
            for k in range(max(0, i-16), min(len(rows), i+4)):
                print("    t=%7.2f %s" % (rel(dv, rows[k]["ts"]), fmt(rows[k], t0, rows[k-1] if k else None)))
        prev = r.get("capReason")


def mode_win(dv, a, b):
    rows = dv["rows"]
    for k, r in enumerate(rows):
        if a <= rel(dv, r["ts"]) <= b:
            print("    t=%7.2f %s" % (rel(dv, r["ts"]), fmt(r, dv["t0"], rows[k-1] if k else None)))


# ---------- clips（上傳片段自動分流） ----------

def clip_row(path):
    clip, hdr, recs = load_file(path)
    rows = [r for r in recs if r["t"] == "s"]
    evs = [r for r in recs if r["t"] == "e"]
    if not clip or not rows:
        return None
    trig = clip.get("trig") or rows[-1]["ts"]
    opts = dict(p.split("=", 1) for p in (hdr.get("opts") or "").split(";") if "=" in p)
    pre = [r for r in rows if trig - 5000 <= r["ts"] <= trig]
    post = [r for r in rows if trig < r["ts"] <= trig + 3000]
    at = min(rows, key=lambda r: abs(r["ts"] - trig))
    maxdrop = 0
    for a, b in zip(rows, rows[1:]):
        dt = (b["ts"] - a["ts"]) / 1000
        if trig - 2000 <= b["ts"] <= trig + 2000 and dt > 0.05:
            maxdrop = max(maxdrop, (abs(g(a, "spd")) - abs(g(b, "spd"))) / 3.6 / dt)
    ev = collections.Counter(f"{e.get('n')}:{e.get('phase') or e.get('why') or ''}" for e in evs
                             if trig - 6000 <= e["ts"] <= trig + 2000 and e.get("n") not in ("replan", "zombie"))
    zev = collections.Counter(e.get("why") for e in evs if e.get("n") == "zombie" and e.get("phase") == "plan"
                              and trig - 4000 <= e["ts"] <= trig + 500)
    fbw = collections.Counter(r.get("fbw") for r in pre + post if (r.get("fbl") or 0) > 0)
    return (f"{clip.get('kind')!s:8s} {str(hdr.get('build', '?'))[-6:]} {str((hdr.get('profile') or {}).get('scriptName'))[5:24]:19s} "
            f"g{opts.get('gear')} spd={g(at, 'spd'):5.1f} cap={str(at.get('capReason')):12s} "
            f"vpre={max((abs(g(r, 'spd')) for r in pre), default=0):5.1f} vpost={min((abs(g(r, 'spd')) for r in post), default=0):5.1f} "
            f"drop={maxdrop:5.1f} zn={max(((r.get('sen') or {}).get('zombieN') or 0) for r in pre) if pre else 0} "
            f"dg={int(any(r.get('dg') for r in pre))} arc={int(any(r.get('curveHardActive') for r in pre))} "
            f"tow={int(any(e.get('n') == 'tow' for e in evs))} caps={dict(collections.Counter(r.get('capReason') for r in pre).most_common(3))} "
            f"fb={dict(fbw)} ev={dict(ev)} z={dict(zev)}")


def mode_clips(args):
    files = []
    for a in args:
        files += sorted(glob.glob(os.path.join(a, "*", "clip-*.log"))) if os.path.isdir(a) else [a]
    for f in files:
        row = clip_row(f)
        if row:
            print(f"{os.path.relpath(f, args[0]) if os.path.isdir(args[0]) else f:32s} {row}")


# ---------- self-test ----------

def self_test():
    import tempfile
    bad = []

    def check(ok, label):
        print(("  ok   " if ok else "  FAIL ") + label)
        if not ok:
            bad.append(label)

    T = 1790000000000
    with tempfile.TemporaryDirectory() as d:
        def put(name, lines):
            p = os.path.join(d, name)
            with open(p, "w", encoding="utf-8", newline="") as fh:
                fh.write("".join(json.dumps(o) + "\n" for o in lines))
            return p

        def s(ms, **kw):
            return dict(t="s", ts=T + ms, x=1, y=2, h=0, spd=10, **kw)

        p1 = put("session-001.log", [
            dict(t="h", ts=T, drive=T, part=1, rev="t1"),
            s(0), dict(t="e", ts=T + 2000, n="start"),
            s(3000), s(3500, fbw="stale", fbl=0),          # fbw 殘值、fbl=0：不算 forceBrake
            s(4000, fb=True), s(6000, fbl=900),
        ])
        p2 = put("session-002.log", [
            dict(t="h", ts=T + 7000, drive=T, part=2, cont="session-001.log"),
            dict(t="e", ts=T + 8000, n="contact"), dict(t="e", ts=T + 9000, n="replan"),
            dict(t="e", ts=T + 9500, n="blocked", why="plan"), s(10000, stateError="bad"),
            dict(t="e", ts=T + 11000, n="impact", cls="hit"), dict(t="e", ts=T + 12000, n="teleport", d=40),
        ])
        con = os.path.join(d, "console.txt")
        with open(con, "w", encoding="utf-8", newline="") as fh:
            fh.write("LOG  : General      f:0> boot\n"
                     f"LOG  : Lua          f:100> [E2E] CLOCK ms={T}\n"
                     "LOG  : Lua          f:150> [E2E] step 7 drive start\n"            # 內插 → T+2500
                     f"LOG  : Lua          f:160> [MDAD Drive] pn=0 blockedStop x t={T + 9000}\n"  # 精確 t=（內插會是 T+3000）
                     f"LOG  : Lua          f:200> [E2E] CLOCK ms={T + 5000}\n"
                     "LOG  : Lua          f:250> [E2E] after\n"                         # 外插 → T+7500
                     "LOG  : Lua          f:10> [E2E] reloaded\n"                       # 幀號倒退＝新段落、無對時點
                     f"LOG  : Lua          f:20> [MDAD Drive] seg2 t={T + 20000}\n")      # 新段落沒 CLOCK，t= 行照樣精確
        old = os.path.join(d, "old.txt")
        with open(old, "w", encoding="utf-8", newline="") as fh:
            fh.write("LOG  : Lua          f:150> [E2E] step 7 drive start\n")
        mpc = os.path.join(d, "mp.txt")
        with open(mpc, "w", encoding="utf-8", newline="") as fh:
            fh.write("LOG  : General      f:0> boot\n"
                     f"LOG  : Lua          f:60 st:68,334,312> [E2E] CLOCK ms={T}\n"
                     "LOG  : Lua          f:110 st:68,336,800> [E2E] mp mid\n"         # 內插 → T+2500
                     f"LOG  : Lua          f:160 st:68,339,313> [E2E] CLOCK ms={T + 5000}\n")

        dvs = drives([p2, p1])
        check(len(dvs) == 1 and dvs[0]["parts"] == [1, 2], "同一趟兩個 part（給的順序顛倒）串成一趟、依 part 排序")
        dv = dvs[0]
        check([r["ts"] for r in dv["recs"]] == sorted(r["ts"] for r in dv["recs"]), "合併後紀錄依 ts 排序")

        lines, notes = console_lines(con)
        got = {msg.split("] ", 1)[1][:10]: (ts, ex) for ts, ex, msg in lines}
        check(got.get("step 7 dri") == (T + 2500, False), "CLOCK 之間的行以幀號線性內插")
        check(got.get("after") == (T + 7500, False), "最後一個 CLOCK 之後的行外插")
        check(got.get("pn=0 block") == (T + 9000, True), "Debug print 尾端 t= 優先於幀號換算")
        check("reloaded" not in got and any("未併入" in n for n in notes), "幀號重新起算的段落不借用前段對時點、明講未併入")
        check(got.get("seg2 t=179") == (T + 20000, True), "沒有 CLOCK 的段落裡 t= 行仍精確併入")
        ol, on = console_lines(old)
        check(ol == [] and any("對不上" in n for n in on), "沒有 CLOCK／t= 的舊 log 明講對不上、不併入")
        ml, mn = console_lines(mpc)
        check([(ts, ex) for ts, ex, msg in ml if "mp mid" in msg] == [(T + 2500, False)]
              and any("對時點 2 個" in n for n in mn), "MP console（f:N st:…>）照樣認幀號與 CLOCK")

        items, _ = timeline(dv, con, t_from=0, t_to=20)
        seq = [(it[0] - T, it[2].strip()) for it in items]
        check(seq.index((2000, "E")) < seq.index((2500, "C~")) < seq.index((3000, "S")), "時間軸依 ts 合併事件、console、樣本")
        check((9000, "E") not in seq, "replan 不進時間軸")
        items2, _ = timeline(dv, con)
        check(all(it[2].strip() != "S" for it in items2), "沒給 --from/--to 時不印逐幀樣本")

        f = firsts(dv)
        check(f["contact"]["ts"] == T + 4000, "contact 取最早的（樣本 fb 早於 contact 事件）")
        check(f["forceBrake"]["ts"] == T + 6000, "forceBrake 認 fbl>0，不認 fbw 殘值")
        check(f["blocked"]["ts"] == T + 9500 and f["state-error"]["ts"] == T + 10000, "blocked 事件與 stateError 樣本")
        check(f["impact"]["ts"] == T + 11000 and f["teleport"]["ts"] == T + 12000, "impact／teleport 事件")
        win = [r["ts"] - T for r, _ in pre_window(dv, f["impact"], 5)]
        check(win[0] == 6000 and win[-1] == 11000 and 9000 not in win, "前 5 秒窗口：含觸發那筆、不含 5 秒前與 replan")
    print(f"self-test：{len(bad)} 項失敗")
    return 1 if bad else 0


# ---------- main ----------

def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("mode", choices=["sum", "corner", "stops", "contact", "win", "tl", "first", "clips"])
    ap.add_argument("args", nargs="+")
    ap.add_argument("--from", dest="t_from", type=float)
    ap.add_argument("--to", dest="t_to", type=float)
    ap.add_argument("--pre", type=float, default=5)
    a = ap.parse_args(argv)
    if a.mode == "clips":
        mode_clips(a.args)
        return 0
    if a.mode == "win":
        srcs, lo, hi = a.args[:1], float(a.args[1]), float(a.args[2]) if len(a.args) > 2 else 1e9
    else:
        srcs = [x for x in a.args if not x.lower().endswith(".txt")]
    console = next((x for x in a.args if x.lower().endswith(".txt")), None)
    for dv in drives(srcs):
        if not dv["rows"] and a.mode not in ("tl", "first"):
            print(f"=== {dv['name']}: no samples")
            continue
        if a.mode == "sum":
            mode_sum(dv)
        elif a.mode == "stops":
            mode_stops(dv)
        elif a.mode == "corner":
            mode_corner(dv)
        elif a.mode == "contact":
            mode_contact(dv)
        elif a.mode == "win":
            mode_win(dv, lo, hi)
        elif a.mode == "tl":
            header(dv)
            items, notes = timeline(dv, console, a.t_from, a.t_to)
            for n in notes:
                print("   " + n)
            for ts, _, tag, text in items:
                print("  %8.2f %s %s" % (rel(dv, ts), tag, text[:400]))
        elif a.mode == "first":
            header(dv)
            fs = firsts(dv)
            for k, r in fs.items():
                print(f"   {k:12s} " + ("-" if r is None else "t=%7.2f %s" % (rel(dv, r["ts"]), show_rec(dv, r)[:200])))
            shown = {}
            for k, r in sorted(((k, r) for k, r in fs.items() if r), key=lambda x: x[1]["ts"]):
                if id(r) in shown:
                    print(f"--- 第一個 {k}：與 {shown[id(r)]} 同一筆，窗口同上")
                    continue
                shown[id(r)] = k
                print(f"--- 第一個 {k} t={rel(dv, r['ts']):.2f}，前 {a.pre:g} 秒逐筆")
                for rr, text in pre_window(dv, r, a.pre):
                    print("  %8.2f %s %s" % (rel(dv, rr["ts"]), "S" if rr["t"] == "s" else "E", text[:400]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
