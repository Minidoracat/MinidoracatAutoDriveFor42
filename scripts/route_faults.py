"""路網資料錯誤追蹤：從伺服器上傳片段／摘要列出「疑似路網錯誤」座標與證據，跨玩家／跨趟聚合（只讀資料）。

    python scripts/route_faults.py scan .omc/uploads/20261006 [更多批次目錄…] [--top 40] [--radius 12]
        [--raster PATH|none] [--all]
    python scripts/route_faults.py at x0 y0 x1 y1 [批次目錄…] [--raster PATH|none] [--streets streets.xml]

scan 訊號（每筆證據帶片段路徑；--radius 公尺內聚成一個候選）：
  solid   導航線上（離 route cutover src 折線 ≤ ON_LINE_M）的固定硬物：r=0.26 格邊牆（帶碰撞的籬笆）、r=0.7 整格
          方塊（建築牆／solid 物件），取自樣本 sen.near；同候選 ≥2 格＝導航線穿牆或路網接錯（玩家自建牆也會中，
          看是否跨伺服器／跨玩家重複）
  thin    導航線上的 r=0 細桿（無碰撞旗標的籬笆 sprite，引擎不給形狀；常是散落木板等地圖裝飾）——弱訊號，
          多半是感知把可壓過的物件當硬物，不是路網錯
  tree    導航線上的樹幹（r=0.15、格 +0.6；室外路燈柱同形狀）——土路長樹或導航線偏離路面
  hit     判堵／改道命中點（blocked hitX/hitY、detour stuck）落在導航線上，附命中物種類（車輛命中不算路網訊號）
  geom    src 幾何：髮夾／反折（≥100° 短臂 <8m，或 ≥120° 短臂 <12m）、Z 字錯位（兩個反向折點夾短段、進出近平行；
          短段 ≥6m 另標「寬 Z」＝錯位路口或跨分隔帶接線）、極短段（<4m 夾兩個 ≥20° 且合計 ≥90° 的折點）、窄路急彎
          （≥75°、窄臂 ≤4m）、段面夾心（前後段 paved／gravel、中間段 dirt＝主 MOD 判那段中線不在鋪面上）；後綴 +ds＝
          MDADFollower.despikeRoute 會收（本 MOD 已容錯，資料仍錯）；附該線 route ready 的 fallback／despike 數
  raster  （有 raster 時）導航線中心連續 ≥RASTER_RUN_M 公尺落在預期路面外：段面 paved／gravel 要 P／G，其餘要非
          natural；raster 是原版 Muldraugh，ModMaps／模組地圖區域會誤報（看 srcS 與伺服器 mods）
  width   （有 raster 時）鋪面段每 WIDTH_STEP_M 量垂直方向 P／G 帶：srcW 比實際寬 ≥WIDTH_SLACK_M 或中線偏 ≥1.5m
          ＝靠右基準算錯（例：段寬把路肩／人行道算進去）；很常見，只有附近有人出事才列進 A
  inc     出事座標：片段觸發（stuck／unstick／contact／takeover／route／detour）＋摘要 inc＋StopStuck 收尾，
          以「不同玩家數」加權——同座標跨玩家重複出事
分數＝3×出事玩家數＋出事趟數(≤10)＋solid(2/4)＋thin 1＋tree 2＋hit 2＋geom 最高分(未收 2–4／已收 1)＋raster 3＋width 2。
輸出兩段：A＝有路網訊號（solid／thin／tree／hit／geom／raster；width 要有人出事）的候選依分數排序；B＝只有 ≥2 名
玩家重複出事、無路網訊號（多半是 MDAD 行為、交通或世界障礙，仍值得看）。分數只排序看的先後，分類要靠 at 疊圖與人判。
`python scripts/route_faults.py selftest`：幾何偵測回歸自測（10-06 復盤的真實頂點＋直線不報）。

at：印原版路面點陣（P 鋪面 G 碎石 d 土 e 土緣 . 自然 空白＝無資料）疊片段導航線（* 線、O 頂點）、streets.xml 折線
（# 在路面／X 在路面外、V 頂點；與導航線同格＝ = 與 8）與片段看到的硬點（w 帶碰撞籬笆／牆、b 方塊、i 無碰撞細桿、t 樹；
落在導航線上大寫 W／B／I／T）；並列出框內頂點與出處。直接給檔案路徑（例：本機 E2E session log）也收。
raster 預設 ../MinidoracatMapRendering/target/tmp/road-surfaces-full-v2.json，以主 MOD scripts/audit_streets.py 讀取。
"""
import argparse, glob, json, math, os, sys
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MINIMAP_SCRIPTS = os.path.join(ROOT, "..", "MinidoracatMiniMapFor42", "scripts")
RASTER = os.path.join(ROOT, "..", "MinidoracatMapRendering", "target", "tmp", "road-surfaces-full-v2.json")
STREETS = "D:/SteamLibrary/steamapps/common/ProjectZomboid/media/maps/Muldraugh, KY/streets.xml"
ON_LINE_M = 1.0
RASTER_RUN_M = 3
WIDTH_STEP_M, WIDTH_SLACK_M = 20, 3
TROUBLE = {"stuck": 3, "unstick": 2, "route": 2, "detour": 2, "contact": 1, "takeover": 1}
JOG_MAX_M, JOG_CLEAR_M, JOG_ARM_RATIO, SPIKE_M = 4.5, 2.4, 4, 2  # 對齊 MDADFollower.despikeRoute


def recs(path):
    out = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def show(path):
    return "/".join(path.replace("\\", "/").split("/")[-3:])


def find_logs(paths, summary):
    """目錄遞迴找片段（clip-*.log、本機 E2E session-*.log）或摘要（*summary*.log）；直接給的檔照副檔名歸類。"""
    out = set()
    for p in paths:
        if os.path.isfile(p):
            if ("summary" in os.path.basename(p)) == summary:
                out.add(p)
        else:
            for pat in (("*summary*.log",) if summary else ("clip-*.log", "session-*.log")):
                out.update(glob.glob(os.path.join(p, "**", pat), recursive=True))
    return sorted(out)


def hard_kind(p):
    """sen.near 一點的種類（半徑見 MDAD_Sensor.lua OBS_HALF_R／WALL_R／TRUNK_*／COST_HARD_THIN）。"""
    r, x, y = p.get("r", -1), p.get("x", 0), p.get("y", 0)
    if r == 0:
        return "thin", "無碰撞籬笆 sprite"
    if abs(r - 0.26) < 0.01:
        return "solid", "籬笆／牆"
    if abs(r - 0.7) < 0.01:
        return "solid", "整格方塊"
    if abs(r - 0.15) < 0.01:
        return ("tree", "樹幹／路燈") if abs(x % 1 - 0.6) < 0.02 and abs(y % 1 - 0.6) < 0.02 else (None, "車輛")
    return None, "樹叢"


def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    l2 = dx * dx + dy * dy
    t = 0 if l2 < 1e-12 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


def line_dist(pts, x, y, pad=3):
    best = 1e9
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        if min(ax, bx) - pad <= x <= max(ax, bx) + pad and min(ay, by) - pad <= y <= max(ay, by) + pad:
            best = min(best, seg_dist(x, y, ax, ay, bx, by))
    return best


def parse_route(e):
    pts = [tuple(map(float, p.split(","))) for p in e["src"].split(";") if "," in p]
    w = [float(v) if v else None for v in (e.get("srcW") or "").split(";")] if e.get("srcW") else []
    s = (e.get("srcS") or "").split(";") if e.get("srcS") else []
    return pts, w, s


def signed_turn(ax, ay, bx, by):
    return math.degrees(math.atan2(ax * by - ay * bx, ax * bx + ay * by))


def geom_faults(pts, w, s):
    """回 [(x, y, kind, 分數, 說明)]；kind 後綴 '+ds'＝despikeRoute 會收（近似其 spike／jog 規則，多段橫移不模擬）。"""
    out, n = [], len(pts)
    ln = [math.dist(pts[i], pts[i + 1]) for i in range(n - 1)] + [0.0]
    d = [(pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1]) for i in range(n - 1)]
    ang = [0.0] * n  # 頂點 i 的有號折角（度，左正）
    for i in range(1, n - 1):
        if ln[i - 1] > 1e-6 and ln[i] > 1e-6:
            ang[i] = signed_turn(*d[i - 1], *d[i])
    wd = lambda k: w[k] if 0 <= k < len(w) else None
    for i in range(1, n - 1):
        a, arm = abs(ang[i]), min(ln[i - 1], ln[i])
        x, y = pts[i]
        if a >= 100 and arm < (12 if a >= 120 else 8):
            ds = a >= 150 and arm < SPIKE_M
            out.append((x, y, "hairpin" + ("+ds" if ds else ""), 1 if ds else 4,
                        "髮夾／反折 %.0f° 臂 %.1f/%.1fm w %s→%s" % (ang[i], ln[i - 1], ln[i], wd(i - 1), wd(i))))
        if i < n - 2 and ln[i - 1] > 1e-6 and ln[i + 1] > 1e-6:
            b, mid = abs(ang[i + 1]), ln[i]
            io = abs(signed_turn(*d[i - 1], *d[i + 1]))
            mx, my = (x + pts[i + 1][0]) / 2, (y + pts[i + 1][1]) / 2
            wtxt = "w %s→%s→%s" % (wd(i - 1), wd(i), wd(i + 1))
            if a >= 20 and b >= 20 and ang[i] * ang[i + 1] < 0 and mid < 12 and io < 30:
                lat = abs(d[i - 1][0] * d[i][1] - d[i - 1][1] * d[i][0]) / ln[i - 1]
                wmin = min([v for v in (wd(i - 1), wd(i + 1)) if v] or [0])
                ds = (mid < JOG_MAX_M and min(ln[i - 1], ln[i + 1]) >= JOG_ARM_RATIO * lat
                      and (lat <= wmin - JOG_CLEAR_M if wmin else mid < SPIKE_M))
                kind = "zjog" if mid < 6 else "widejog"
                out.append((mx, my, kind + ("+ds" if ds else ""), 1 if ds else (4 if mid < 6 else 2),
                            "%s 橫移 %.1fm 短段 %.1fm 折角 %.0f°/%.0f° %s" % (
                                "Z 字錯位" if mid < 6 else "寬 Z", lat, mid, ang[i], ang[i + 1], wtxt)))
            elif min(a, b) >= 20 and a + b >= 90 and mid < 4:
                out.append((mx, my, "shortlink", 3,
                            "極短段 %.1fm 夾折角 %.0f°/%.0f° %s" % (mid, ang[i], ang[i + 1], wtxt)))
        wi, wo = wd(i - 1), wd(i)
        if 75 <= a < 100 and wi and wo and min(wi, wo) <= 4:
            out.append((x, y, "narrowcorner", 1, "窄路急彎 %.0f° w %s→%s" % (ang[i], wi, wo)))
        if i < n - 2 and i + 1 < len(s) and s[i] == "dirt" and s[i - 1] in ("paved", "gravel") \
                and s[i + 1] in ("paved", "gravel") and ln[i] >= 3:
            out.append(((x + pts[i + 1][0]) / 2, (y + pts[i + 1][1]) / 2, "surfdip", 2,
                        "段面夾心 %s→dirt→%s（%.1fm）：中線可能不在鋪面上" % (s[i - 1], s[i + 1], ln[i])))
    return out


def on_class(A, surf, x, y, hard):
    """None＝raster 無資料；True＝在預期路面上（hard：P／G；否則非 natural）。"""
    c = surf.at(x, y)
    if c is A.MISSING:
        return None
    name = A.CLASSES[c]
    return name in ("paved", "gravel") if hard else name != "natural"


def raster_runs(A, surf, p, q, want):
    """一段導航線中心連續 ≥RASTER_RUN_M 公尺落在預期路面外：回 [(x, y, 說明)]。"""
    out, hard = [], want in ("paved", "gravel")
    (ax, ay), (bx, by) = p, q
    n = max(int(math.dist(p, q)), 1)
    run, cls = [], defaultdict(int)
    for k in range(n + 2):
        px, py = ax + (bx - ax) * min(k, n) / n, ay + (by - ay) * min(k, n) / n
        ok = on_class(A, surf, px, py, hard) if k <= n else True
        if ok is False:
            run.append((px, py))
            cls[A.CLASSES[surf.at(px, py)]] += 1
        elif run:
            if len(run) >= RASTER_RUN_M:
                mx, my = run[len(run) // 2]
                out.append((mx, my, "導航線 %dm 落在%s外（段面 %s，raster %s）" % (
                    len(run), "鋪面" if hard else "路面", want, ",".join("%s×%d" % kv for kv in sorted(cls.items())))))
            run, cls = [], defaultdict(int)
    return out


def raster_width(A, surf, p, q, want, w):
    """鋪面段每 WIDTH_STEP_M 量一次垂直方向的 P／G 連續帶：段寬比 raster 寬 ≥WIDTH_SLACK_M 或中心偏 ≥1.5m
    就回 [(x, y, 說明)]（只看長 ≥20m 的段、避開兩端 10m 路口）。"""
    if want not in ("paved", "gravel") or not w or math.dist(p, q) < 20:
        return []
    (ax, ay), (bx, by) = p, q
    L = math.dist(p, q)
    ux, uy = (bx - ax) / L, (by - ay) / L
    out, half = [], w / 2 + 6
    for k in range(10, int(L) - 9, WIDTH_STEP_M):
        cx, cy = ax + ux * k, ay + uy * k
        on = [o / 2 for o in range(int(-half * 2), int(half * 2) + 1) if on_class(A, surf, cx - uy * o / 2, cy + ux * o / 2, True)]
        if not on or on_class(A, surf, cx, cy, True) is None:
            continue
        lo = hi = min(on, key=abs)
        s = set(on)
        while lo - 0.5 in s: lo -= 0.5
        while hi + 0.5 in s: hi += 0.5
        rw, off = hi - lo + 0.5, (lo + hi) / 2
        if hi >= half - 0.5 or lo <= -half + 0.5:
            continue  # 帶延伸到量測窗外＝路口或廣場，不判
        if w - rw >= WIDTH_SLACK_M or abs(off) >= 1.5:
            out.append((cx, cy, "段寬 %g 但 raster 鋪面寬 %.1f、中心偏 %+.1fm（+＝行進方向右側）" % (w, rw, off)))
    return out


class Ev:
    __slots__ = ("x", "y", "sig", "score", "who", "drive", "where", "text", "rev")

    def __init__(self, x, y, sig, score, who, drive, where, text, rev):
        self.x, self.y, self.sig, self.score = x, y, sig, score
        self.who, self.drive, self.where, self.text, self.rev = who, drive, where, text, rev


def collect(dirs, A, surf):
    evs, seen_clip, seen_sum, seen_inc, seen_seg = [], set(), set(), set(), set()
    clip_paths, sum_paths = find_logs(dirs, False), find_logs(dirs, True)
    nroutes = 0
    for path in clip_paths:
        rr = recs(path)
        clip = next((o for o in rr if o.get("t") == "clip"), {})
        hdr = next((o for o in rr if o.get("t") == "h"), {})
        who = os.path.basename(os.path.dirname(path))
        drive, rev = clip.get("drive") or hdr.get("drive"), hdr.get("rev")
        if (who, drive, clip.get("trig")) in seen_clip:
            continue
        seen_clip.add((who, drive, clip.get("trig")))
        where = show(path)

        def mk(x, y, sig, sc, txt):
            evs.append(Ev(x, y, sig, sc, who, drive, where, txt, rev))
        kind = clip.get("kind")
        if kind in TROUBLE and clip.get("x"):
            seen_inc.add((drive, clip.get("trig")))
            mk(clip["x"], clip["y"], "inc", TROUBLE[kind], "片段 %s" % kind)
        ready = {o.get("rg"): o for o in rr if o.get("t") == "e" and o.get("n") == "route" and o.get("phase") == "ready"}
        line = []  # 依時間排序的 (ts, pts)
        for o in rr:
            if o.get("t") == "e" and o.get("n") == "route" and o.get("src"):
                pts, w, s = parse_route(o)
                rd = ready.get(o.get("rg")) or {}
                info = ("fallback=%s %s" % (rd.get("filletFallbackN", "?"), rd.get("detail") or "")).strip()
                line.append((o["ts"], pts))
                nroutes += 1
                for x, y, k, sc, txt in geom_faults(pts, w, s):
                    mk(x, y, "geom:" + k, sc, "%s（%s 線 ready %s）" % (txt, o.get("why"), info))
                if surf is not None:
                    segs = [(i, p, q) for i, (p, q) in enumerate(zip(pts, pts[1:])) if (p, q) not in seen_seg]
                    seen_seg.update((p, q) for _, p, q in segs)
                    for i, p, q in segs:
                        want, wi = s[i] if i < len(s) else "unknown", w[i] if i < len(w) else None
                        for x, y, txt in raster_runs(A, surf, p, q, want):
                            mk(x, y, "raster", 3, txt)
                        for x, y, txt in raster_width(A, surf, p, q, want, wi):
                            mk(x, y, "width", 2, txt)
        if not line:
            continue
        hard, near_at = {}, {}  # hard：(格, 種類) → (x, y, 線, 說明)；near_at：硬點座標 → 說明（標 hit 的命中物）
        for o in rr:
            ts = o.get("ts", 0)
            act = None
            for lts, pts in line:
                if lts <= ts:
                    act = pts
            if act is None:
                continue
            if o.get("t") == "s":
                for p in (o.get("sen") or {}).get("near") or []:
                    k, label = hard_kind(p)
                    near_at[(round(p.get("x", 0), 1), round(p.get("y", 0), 1))] = label
                    if k:
                        hard.setdefault((math.floor(p["x"]), math.floor(p["y"]), k), (p["x"], p["y"], act, label))
            elif o.get("t") == "e" and (o.get("n") == "blocked" or (o.get("n") == "detour" and o.get("phase") == "stuck")):
                hx, hy = o.get("hitX") or o.get("x"), o.get("hitY") or o.get("y")
                if hx and line_dist(act, hx, hy) <= ON_LINE_M:
                    label = near_at.get((round(hx, 1), round(hy, 1)), "?")
                    mk(hx, hy, "hit" if label != "車輛" else "hit-veh", 2 if label != "車輛" else 0,
                       "%s %s %s 命中導航線上（%s）" % (o["n"], o.get("why") or o.get("phase"), o.get("detail") or "", label))
        for (_, _, k), (x, y, act, label) in hard.items():
            dd = line_dist(act, x, y)
            if dd <= ON_LINE_M:
                mk(x, y, k, 1, "%s 離導航線 %.1fm" % (label, dd))
    for path in sum_paths:
        for o in recs(path):
            if o.get("t") != "sum" or (o.get("u"), o.get("drive")) in seen_sum:
                continue
            seen_sum.add((o.get("u"), o.get("drive")))
            for kind, ts, x, y in o.get("inc") or []:
                if kind in TROUBLE and (o.get("drive"), ts) not in seen_inc:
                    seen_inc.add((o.get("drive"), ts))
                    evs.append(Ev(x, y, "inc", TROUBLE[kind], o.get("u"), o.get("drive"), "summary", "摘要 inc %s" % kind, o.get("rev")))
            if str(o.get("reason", "")).endswith("StopStuck") and o.get("x1"):
                evs.append(Ev(o["x1"], o["y1"], "inc", 3, o.get("u"), o.get("drive"), "summary", "摘要收尾 StopStuck", o.get("rev")))
    return evs, nroutes


def load_raster(path):
    if path == "none" or not os.path.exists(path):
        return None, None
    sys.path.insert(0, MINIMAP_SCRIPTS)
    import audit_streets as A
    with open(path, "rb") as fh:
        return A, A.SurfaceIndex(A.load_surfaces(fh.read()))


def cluster(evs, R):
    cells, clusters = defaultdict(list), []
    for ev in sorted(evs, key=lambda e: (e.sig == "inc", -e.score)):  # 路網訊號先當錨
        gx, gy = int(ev.x // R), int(ev.y // R)
        hit = next((c for cx in (gx - 1, gx, gx + 1) for cy in (gy - 1, gy, gy + 1) for c in cells[(cx, cy)]
                    if math.hypot(c["x"] - ev.x, c["y"] - ev.y) <= R), None)
        if hit is None:
            hit = {"x": ev.x, "y": ev.y, "evs": []}
            cells[(gx, gy)].append(hit)
            clusters.append(hit)
        hit["evs"].append(ev)
    return clusters


def scan(args):
    A, surf = load_raster(args.raster)
    evs, nroutes = collect(args.dirs, A, surf)
    rows = []
    for c in cluster(evs, args.radius):
        E = c["evs"]
        inc = [e for e in E if e.sig == "inc"]
        players = {e.who for e in inc} | {e.who for e in E if e.sig.startswith("hit")}
        drives = {e.drive for e in inc}
        solid = {(math.floor(e.x), math.floor(e.y)) for e in E if e.sig == "solid"}
        trees = {(math.floor(e.x), math.floor(e.y)) for e in E if e.sig == "tree"}
        thin = {(math.floor(e.x), math.floor(e.y)) for e in E if e.sig == "thin"}
        geoms = {}
        for e in E:
            if e.sig.startswith("geom:"):
                geoms[e.sig[5:]] = max(geoms.get(e.sig[5:], 0), e.score)
        hit = any(e.sig == "hit" for e in E)
        ras = any(e.sig == "raster" for e in E)
        wid = any(e.sig == "width" for e in E)
        road = bool(solid or thin or trees or geoms or hit or ras or (wid and players))  # 路寬不符很常見，要有人出事才算
        if not road and len(players) < 2:
            continue
        score = 3 * len(players) + min(len(drives), 10)
        score += (4 if len(solid) >= 2 else 2) if solid else 0
        score += (2 if trees else 0) + (1 if thin else 0) + (2 if hit else 0) + (3 if ras else 0) + (2 if wid else 0)
        score += max(geoms.values()) if geoms else 0
        sigs = []
        if players: sigs.append("出事 %d 玩家／%d 趟" % (len(players), len(drives)))
        if solid: sigs.append("線上硬物 %d 格" % len(solid))
        if thin: sigs.append("線上細桿 %d 格" % len(thin))
        if trees: sigs.append("線上樹 %d 棵" % len(trees))
        if hit: sigs.append("判堵命中線上")
        if geoms: sigs.append("幾何 " + ",".join(sorted(geoms)))
        if ras: sigs.append("raster 離路")
        if wid: sigs.append("raster 路寬不符")
        rows.append((road, score, c, sigs))
    print("證據 %d 筆、導航線 %d 條、raster=%s" % (len(evs), nroutes, "on" if surf else "off"))
    for road, title in ((True, "A. 有路網訊號"), (False, "B. 只有跨玩家重複出事（無路網訊號）")):
        part = sorted((r for r in rows if r[0] == road), key=lambda r: -r[1])
        print("\n== %s：%d 個候選 ==" % (title, len(part)))
        for rank, (_, score, c, sigs) in enumerate(part[:args.top], 1):
            revs = sorted({e.rev for e in c["evs"] if e.rev})
            print("#%d score=%d (%.1f,%.1f) %s  rev=%s" % (rank, score, c["x"], c["y"], "；".join(sigs), ",".join(revs)))
            shown = set()
            for e in sorted(c["evs"], key=lambda e: (e.sig == "inc", -e.score)):
                k = (e.sig, e.where, e.text)
                if k in shown or (e.sig == "inc" and e.where == "summary" and not args.all):
                    continue
                shown.add(k)
                if not args.all and len(shown) > 6:
                    break
                print("    %-17s (%.1f,%.1f) %s  %s" % (e.sig, e.x, e.y, e.text, e.where if e.where != "summary" else "summary/%s@%s" % (e.who, e.rev)))
            sm = [e for e in c["evs"] if e.sig == "inc" and e.where == "summary"]
            if sm and not args.all:
                names = sorted({"%s@%s" % (e.who, e.rev) for e in sm})
                print("    摘要 inc %d 筆：%s%s" % (len(sm), ", ".join(names[:8]), " …" if len(names) > 8 else ""))


def at(args):
    x0, y0, x1, y1 = (int(math.floor(v)) for v in args.box)
    A, surf = load_raster(args.raster)
    sym = {0: " ", 1: "P", 2: "G", 3: "d", 4: ".", 5: "e"}
    grid = {}
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            c = surf.at(x, y) if surf else None
            grid[(x, y)] = "?" if surf is None or c is A.MISSING else sym.get(c, "?")
    base = dict(grid)
    inbox = lambda x, y: x0 <= x <= x1 and y0 <= y <= y1
    cx, cy, half = (x0 + x1) / 2, (y0 + y1) / 2, math.hypot(x1 - x0, y1 - y0) / 2

    def draw(pts, line_ch, off_ch, vtx_ch):
        for (ax, ay), (bx, by) in zip(pts, pts[1:]):
            n = max(1, int(math.dist((ax, ay), (bx, by)) * 2))
            for k in range(n + 1):
                c = (math.floor(ax + (bx - ax) * k / n), math.floor(ay + (by - ay) * k / n))
                if not inbox(*c) or grid[c] in "VO8WTBIwtbi":
                    continue
                ch = line_ch if off_ch is None or base[c] in "PGde" else off_ch
                grid[c] = "=" if line_ch != "*" and grid[c] == "*" else ch
        for x, y in pts:
            c = (math.floor(x), math.floor(y))
            if inbox(*c):
                grid[c] = "8" if grid[c] in "OV" and grid[c] != vtx_ch else vtx_ch

    seen, hards = {}, {}
    for path in find_logs(args.dirs, False):
        for o in recs(path):
            if o.get("t") == "e" and o.get("n") == "route" and o.get("src"):
                pts, w, s = parse_route(o)
                segs = [i for i in range(len(pts) - 1) if line_dist(pts[i:i + 2], cx, cy, half) <= half]
                if not segs:
                    continue
                lo, hi = max(0, segs[0] - 1), min(len(pts) - 1, segs[-1] + 2)
                key = " → ".join("(%.1f,%.1f)" % pts[i] + (" [w%s %s]" % (w[i], s[i] if i < len(s) else "")
                                                           if i < hi and i < len(w) else "") for i in range(lo, hi + 1))
                seen.setdefault(key, []).append("%s(%s)" % (show(path), o.get("why")))
                draw(pts, "*", None, "O")
            elif o.get("t") == "s":
                for p in (o.get("sen") or {}).get("near") or []:
                    k, label = hard_kind(p)
                    c = (math.floor(p.get("x", 0)), math.floor(p.get("y", 0)))
                    if k and inbox(*c):
                        hards[c] = {"樹幹／路燈": "t", "整格方塊": "b", "無碰撞籬笆 sprite": "i"}.get(label, "w")
    for c, ch in hards.items():  # 硬點蓋在導航線上＝大寫
        grid[c] = ch.upper() if grid[c] in "*O" else ch
    for key, refs in seen.items():
        print("導航線 %s\n    ← %d 次：%s" % (key, len(refs), ", ".join(refs[:4]) + (" …" if len(refs) > 4 else "")))
    if A and os.path.exists(args.streets):
        with open(args.streets, "rb") as fh:
            streets = A.parse_streets(fh.read())
        for st in streets:
            get = (lambda k: st.get(k)) if isinstance(st, dict) else (lambda k: getattr(st, k, None))
            raw = get("pts")
            pts = list(zip(raw[0::2], raw[1::2])) if raw and not isinstance(raw[0], (list, tuple)) else [tuple(p) for p in raw]
            if line_dist(pts, cx, cy, half) <= half:
                near = [(round(x, 1), round(y, 1)) for x, y in pts if x0 - 40 <= x <= x1 + 40 and y0 - 40 <= y <= y1 + 40]
                print("streets.xml %r w=%s 頂點(框±40)=%s" % (get("name"), get("width"), near))
                draw(pts, "#", "X", "V")
    print("       " + "".join(str((x // 10) % 10) if x % 10 == 0 else " " for x in range(x0, x1 + 1)))
    for y in range(y0, y1 + 1):
        print("%6d %s" % (y, "".join(grid[(x, y)] for x in range(x0, x1 + 1))))


def selftest(_args):
    kinds = lambda pts, w, s=(): {k for _, _, k, _, _ in geom_faults(pts, w, list(s))}
    # (5454,5836)：KY-163／Olin／Long Needle 端點不相接，135° 短臂 5.7m（despike 只收 ≥150° 且臂 <2m）
    assert kinds([(5458, 6000), (5458, 5840), (5454, 5836), (5700, 5836)], [8, 8, 8]) == {"hairpin"}
    # (4571.5,10646)：117° 臂 2.7/2.0m
    assert "hairpin" in kinds([(4500, 10503), (4570.3, 10643.6), (4571.5, 10646), (4569.49, 10645.99), (4500, 10645.56)],
                              [17, 16, 8, 8])
    # rc61 0017 (10671,9436)：右 85° 接 3.9m 再左 40°（進出差 45°，不是 Z）
    assert kinds([(10647, 9460), (10671, 9436), (10674, 9438.5), (10761, 9438.5)], [6, 5, 5]) == {"shortlink"}
    # (15137,3455→3445)：KY-841 跨分隔帶 10m 寬 Z
    assert "widejog" in kinds([(15000, 3455), (15137, 3455), (15137, 3445), (15144.5, 3445), (15162, 3436)], [6, 6, 6, 6])
    # 2m 橫移、兩臂長、路寬夠＝despike 會收
    assert kinds([(8000, 11204.5), (8104, 11204.5), (8104, 11206.5), (8200, 11206.5)], [8, 8, 8]) == {"zjog+ds"}
    # Long Branch Road 段面 gravel→dirt→gravel
    assert "surfdip" in kinds([(4032.5, 5817.5), (4153.5, 5817), (4171, 5833), (4291, 5833)], [5, 5, 5],
                              ["gravel", "dirt", "gravel"])
    assert kinds([(0, 0), (100, 0), (200, 1), (300, 1)], [8, 8, 8]) == set()
    assert hard_kind({"r": 0, "x": 1.5, "y": 1.5})[0] == "thin" and hard_kind({"r": 0.15, "x": 3.6, "y": 4.6})[0] == "tree"
    assert hard_kind({"r": 0.15, "x": 3.2, "y": 4.9})[0] is None
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan")
    s.add_argument("dirs", nargs="+")
    s.add_argument("--top", type=int, default=40)
    s.add_argument("--radius", type=float, default=12)
    s.add_argument("--raster", default=RASTER)
    s.add_argument("--all", action="store_true", help="列出每個候選的全部證據")
    a = sub.add_parser("at")
    a.add_argument("box", nargs=4, type=float)
    a.add_argument("dirs", nargs="*")
    a.add_argument("--raster", default=RASTER)
    a.add_argument("--streets", default=STREETS)
    sub.add_parser("selftest")
    args = ap.parse_args()
    {"scan": scan, "at": at, "selftest": selftest}[args.cmd](args)


if __name__ == "__main__":
    main()
