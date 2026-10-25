"""正式服上傳批次評估：摘要 KPI、窗口片段、撞擊歸因與各確認項盤點（取代一次性的 temp/eval1012.py）。

    python scripts/upload_report.py <pull 目錄> <sinceEpoch秒> [--current 1010a,1010c] [--picks out.tsv] [--with <較早的 pull 目錄>…]
    python scripts/upload_report.py --self-test

<pull 目錄>＝pull_uploads.py 的落地目錄（<玩家>/clip-NN.log、summary-*.log）；窗口＝片段 trig ≥ since。
--current＝駕駛行為與 HEAD 相同的 rev（C／D／K 與 B 的可用性只看這些）。玩家名一律輸出匿名代號（P##，沿用 pull 目錄的
anon-users.tsv、新玩家接續編號；新的一批還沒有這個檔時沿用同層最新一批的表，代碼才跟前次報告與 open-issues 一致）；每次執行重寫
<pull 目錄>/anon-users.tsv（代碼<TAB>玩家名，摘要＋片段全部玩家）與
clips-anon.tsv（anon path overview，目錄內全部片段），寫完重讀、有人沒代碼或片段沒列到就中止。兩檔含真名，只留本機。
--picks 寫 TSV（category time anon rev kind veh path note）列出 C–E、G–J 背後的片段，path 含真實資料夾名，只留本機。
--with（可重複）＝較早的 pull 目錄：A 節併入它們的摘要（8 檔輪寫，舊 build 的趟會被輪掉；同 (u, drive) 以本批為準）與全部片段。
  A 摘要：(u, drive) 去重、依 build 分組：趟數／玩家／km、impact／impZ／contact 每千 km＋Poisson 95%、
    impact 另列「不含小動物」（扣掉本批與 --with 全部片段裡歸成 small-animal、同 (u, drive) 的撞擊，不限窗口；片段有配額，
    扣的是下限，另印片段涵蓋 n/k 件）、結束原因（全部）、loss 佔比、nm/fm、offset（offN／offMax）；
    相鄰 build 與「同碼 A/A」（--current 內兩個以上 build 時，最早一個對其餘合併）的率比＋玩家叢集 bootstrap 95%（boot_ratio）
    ＋Poisson 條件二項 p——同一玩家連撞時 p 偏小（2026-10-20 同碼 A/A impact p 0.004、玩家叢集區間 0.94–3.84），判版本差看區間並對照 A/A
  B 窗口片段：rev×kind、玩家數、現行 rev 可用性（事前 ≥3s、樣本 ≥10、有 route 點列）
  C 撞擊歸因（現行 rev；事件 (u, drive, ts) 去重）：先排除不算撞擊的上升緣（事件 cls≠hit；1017 前片段：上升緣樣本 m=rehitch、
    rh-attach 後 REHITCH_SETTLE_MS 內＝rehitch，摘要 reason=exit 且撞擊在結束前 EXIT_BRAKE_MS 內、tn 0、fbl 0＝exit），同 (u, drive)
    IMPACT_REARM_MS 內只留第一件；上升緣樣本（ts ≤ 事件+5ms、帶 nb 的最後一筆）nb {kind: [d, s, l]}，
    貼車＝|s| ≤ halfL+0.8（他車再加對方半長 2.5）且 |l| ≤ halfW+0.8；旗標 awt、maneuver（前 2.5s 主導 ctl 為 AVOID／RETURN 或任一 dg）；
    撞擊前 2.5s 內有 contact 事件時 sprite／scost 用它的（命中點 1 格，比車頭 3 格準；scost vehicle 或 tlg ≤1＝vehicle）；
    類別 zombie＞small-animal／animal＞vehicle（貼車）＞static（scost tree／hard／wall）＞corpse（貼車）＞far（有 nb 沒貼車）＞empty；
    small-animal＝貼車的動物 a 體重 <SMALL_KG（nb a 第 5 項；1013f 起含剛死的，第 6 項＝1），讀不到體重算 animal
  L 1017 摘要新欄位（rev 有 rhi 的趟）：rhi／xbk、vfIn／vfInX、aoi、出口偏差、油量分段 %/km、起步到 40m 中位（依 t40k）、blr、eng；
    1020 起（摘要有 fuT／fuE）另印各段每分鐘扣量（記在值到達那筆的段，只描述）。油量換算判準看片段（現行 rev、窗口內）：
    兩次油量同步之間積分原版公式期望（held＝實際檔、fair＝伺服器換算檔），擬合換算比例 α＋玩家叢集 95%，fuel_verdict 判過／不過／
    不確定（fuel_intervals／fuel_alpha）；另印步長指紋（≤FUEL_SMALL_STEP% 的下降佔比）。摘要的 (彎道＋繞行)/其他 段比不能當判準：同步由
    換算前的扣量觸發、下降記在到達那筆的段，換算有作用／沒作用都落在 1.2–1.5（mdad-prod-1025/agent-TowFuelHud.md §1.4）。
    1026g 起：EngineOff 機制（eng_class：est／kso／erm，舊 rev 未分類）；路中停車首見 V5 依區域（trip_region）——摘要有 vfW 用
    vfW／vfWX（失敗窗，vb／va 只參考）與 vfWs 本車 ≥VF_FAST_KMH，舊 rev 以 vfInTs 同玩家 8 s 去重（vf_dedupe，SpeedTime §4a）；
    他車首見 vhN／vhLt／vhMin 依區域
  D contact ≥10 km/h（現行 rev）：scost、弧上（前 2.5s curveHardActive）、前 2.5s |ld|>0.5、lag 帽（capReason=lag）、主導 ctl、sprite 家族
  E 判堵後接手：takeover 片段觸發前 10s 內有 blocked；窗口內首筆 blocked→接手秒數、其間 unstick start、detour=false、最後一筆 why／shape
  F 判堵熱點：blocked x,y 的 25m 格（玩家、趟、事件、車型）
  G 起步調頭 uturn done：依 start（1012 起步段原地轉，出場 30°）× probe 分組（aligned ms、stop 的 detail）；room＝倒車騰空間判定
  H 判堵鎖輪 brake 片段（at.fbw=blocked）：鎖輪速度、該趟是否 5s 內結束（摘要 end）
  I tow lost／relook（1026g alive=true 另帶 tj／tps，門檻未標定，只列值）
  J 結案檢查：area start kind=behind 後 20s 同趟 progress suspect；gate phase／why；detour kind=towcorner why=ok
  K 接手結束的趟（現行 rev）依 rem 分桶；≥300m 的趟 ev 沒有異常事件（blocked／uturn／unstick／contact／impact／progress）的數量
  M 1026g 新鍵（現行 rev 片段，sec_m）：engine off 機制、impact tw／dms（拖車起步拉緊）與 srcC 所在段、damage 依 cls、
    route lost why×區域、dodge commit dbs×區域×拖車與 NB2 型、blocked why=guard 的 gsl／gcs 與之後接手。區域＝NEW_CELLS（三張新圖
    lotheader 的 cell；Riverside 原版格算舊區）
  分析用 helper（`import upload_report as UR`）：Anon(root)、hm、q、ci、binom_p、boot_ratio、boot_players、fuel_intervals、fuel_alpha、
    opts_of、is_tow、per_em、load_summaries、load_clips（since 省略＝pull.json）、dedupe、trips、events、window、edge_row、classify_impact、
    real_impacts、region、trip_region、ev_region、eng_class、vf_dedupe、seg_flag
"""
import argparse
import collections
import datetime as dt
import glob
import json
import math
import os
import random
import re
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze_telemetry as AT  # noqa: E402
import upload_index as UI  # noqa: E402

PFX = "UI_MinidoracatAutoDrive_"
PRE_MS = 2500           # 撞擊／接觸前的回看窗
TAKE_MS = 10000         # 接手前多久內有 blocked 算「判堵後接手」
TAKE_POST_MS = 500      # blocked 可晚於片段 trig 幾十 ms（同一輪 replan 在觸發後才記；正式服見過 +29～+92ms）
TOUCH_PAD = 0.8         # nb 貼車：半車長／半車寬外加
GRID = 25               # 判堵熱點格 m
STATIC = ("tree", "hard", "wall")
ANOMALY = ("blocked", "uturn", "unstick", "contact", "impact", "progress")
NB_KIND = (("z", "zombie"), ("a", "animal"), ("v", "vehicle"))
SMALL_KG = 20          # 同 MDADSensor.ANIMAL_BIG_KG：小型動物不閃不減（2026-10-13 裁定 7：撞母雞 0 車損），撞擊 KPI 拆開
IMPACT_REARM_MS = 2000  # 同 MDAD_Upload IMPACT_REARM_MS：同一趟 2 秒內的第二次撞擊上升緣算同一件
REHITCH_SETTLE_MS = 2500  # 同 Driver TUNE.REHITCH_SETTLE_MS：rh-attach 後這麼久內的掉速是掛回拉攏
EXIT_BRAKE_MS = 2000   # 同 MDAD_Upload EXIT_BRAKE_MS：撞擊後這麼久內以 exit 結束、tn 0、fbl 0＝下車煞車
OTHER_HALF_L = 2.5     # 車對車貼車：對方半車長（nb v 不帶對方幾何）
ANON_USERS, CLIPS_ANON = "anon-users.tsv", "clips-anon.tsv"
KSO_PLAYER_MS = 2000  # 1026g engine off kso（距本機 onShutOff）< 這個值＝玩家關引擎（N 鍵／儀表鑰匙／radial）
ERM_EARLY_MS = 3000   # 1026g engine off erm（距本機看到引擎轉起來）< 這個值＝剛發動就熄（1025 批 3 趟 1.2–2.2 s）
TOW_START_MS = 2000   # 1026g impact tw＝true 且 dms < 這個值＝拖車起步拉緊（正式服 9 件開出 0.8–1.3 s，agent-Safety）
VF_WIN_MS = 8000      # 路中停車首見同玩家去重窗（同 MDAD_Upload VFS_OUT_MS；SpeedTime §4a）
VF_FAST_KMH = 70      # vfWs 第 3 項（本車 km/h）≥ 這個值＝判準要的高速首見
NB2_DBL = 0.5         # dodge commit dbs=tow 且 |dbl| < 這個值＝NB2 型（出口 lane 被拖車線拉回中線）
# 新圖區域＝三張地圖 lotheader 所在的 cell（256 格）：(地圖, cy0, cy1, ((cx0, cx1)…))，範圍含兩端。取自 Workshop 版
# DirkerdamIntegratedB42／BBL_b42／New Hartburg, KY 的 *.lotheader 檔名（2026-10-26）；德克丹 bounds 南緣的 Riverside 原版格
# （如 (24,20)）沒有 lotheader＝舊區（mdad-prod-1025 README：bounds 會把它算進德克丹）。換圖或地圖更新時重抓。
NEW_CELLS = (("Dirkerdam", 7, 12, ((5, 40),)), ("Dirkerdam", 13, 17, ((5, 8), (11, 40))),
             ("Dirkerdam", 18, 18, ((5, 8), (21, 21), (23, 40))), ("Dirkerdam", 19, 19, ((5, 6), (20, 40))),
             ("Dirkerdam", 20, 20, ((5, 5), (18, 19), (28, 30))), ("Dirkerdam", 21, 21, ((5, 5), (28, 28))),
             ("BigBearLake", 26, 33, ((14, 23),)), ("NewHartburg", 42, 45, ((24, 28),)))


class Anon:
    """玩家 → P##。給 root 時沿用 <root>/anon-users.tsv（每列「代碼<TAB>玩家名」），沒列到的從最大號往後編；
    片段資料夾名先經 index.txt 換回玩家名（伺服器把路徑危險字元換成 _），同一人摘要與片段同碼。"""

    def __init__(self, root=None):
        self.ids, self.alias, self.n = {}, {}, 0
        if not root:
            return
        p = os.path.join(root, ANON_USERS)
        if not os.path.exists(p):   # 新的一批：沿用同層最新一批的表（2026-10-20 新批從 P01 重編，open-issues 的 P## 全對不上）
            prev = glob.glob(os.path.join(os.path.dirname(os.path.abspath(root)), "*", ANON_USERS))
            p = max(prev, key=os.path.getmtime, default=p)
        if os.path.exists(p):
            with open(p, encoding="utf-8") as fh:
                for ln in fh:
                    code, _, u = ln.rstrip("\n").partition("\t")
                    if u:
                        self.ids[u] = code
                        self.n = max(self.n, int(code[1:]))
        if os.path.exists(os.path.join(root, "index.txt")):
            self.alias = {t[3]: t[13] for t in UI.rows(root) if t[0] == "C" and len(t) > 13}

    def __call__(self, u):
        u = self.alias.get(u, u)
        if u not in self.ids:
            self.n += 1
            self.ids[u] = f"P{self.n:02d}"
        return self.ids[u]


def hm(ms):
    return dt.datetime.fromtimestamp(ms / 1000, dt.timezone(dt.timedelta(hours=8))).strftime("%m-%d %H:%M:%S")


def ci(k):
    """Poisson 95%（Wilson–Hilferty）。"""
    lo = 0 if k == 0 else k * (1 - 1 / (9 * k) - 1.96 / (3 * math.sqrt(k))) ** 3
    hi = (k + 1) * (1 - 1 / (9 * (k + 1)) + 1.96 / (3 * math.sqrt(k + 1))) ** 3
    return lo, hi


def binom_p(k1, k2, w1, w2):
    """條件二項雙尾 p：給定 k1+k2 件，依曝露 w1:w2 分配。"""
    n, p = k1 + k2, w1 / (w1 + w2)
    pr = [math.comb(n, i) * p ** i * (1 - p) ** (n - i) for i in range(n + 1)]
    return min(1.0, sum(x for x in pr if x <= pr[k1] * (1 + 1e-9)))


def boot_ratio(L1, L2, val, B=2000, seed=7):
    """每千 km 率比（L1／L2）的玩家叢集 bootstrap：兩組各自以玩家（摘要 u）為單位重抽，回傳 (點估計, 2.5%, 97.5%)；
    val(o)＝該趟件數。L2 沒有件數或任一組沒有里程時回 None。撞擊常同一人連發，以趟或件為單位的 Poisson p 會偏小。"""
    def agg(L):
        U = collections.defaultdict(lambda: [0.0, 0.0])
        for o in L:
            u = U[o.get("u")]
            u[0] += val(o)
            u[1] += (o.get("dist") or 0) / 1000
        return list(U.values())

    U1, U2 = agg(L1), agg(L2)
    k1, w1 = sum(x[0] for x in U1), sum(x[1] for x in U1)
    k2, w2 = sum(x[0] for x in U2), sum(x[1] for x in U2)
    if not (k2 and w1 and w2):
        return None
    rnd, rr = random.Random(seed), []
    for _ in range(B):
        a = [rnd.choice(U1) for _ in U1]
        b = [rnd.choice(U2) for _ in U2]
        kb, wa, wb = sum(x[0] for x in b), sum(x[1] for x in a), sum(x[1] for x in b)
        if kb and wa and wb:
            rr.append(sum(x[0] for x in a) / wa / (kb / wb))
    return k1 / w1 / (k2 / w2), q(rr, 0.025), q(rr, 0.975)


def boot_players(L, stat, B=2000, seed=7):
    """玩家叢集 bootstrap：以玩家（摘要 u）為單位重抽 L，stat(趟清單)→值（None 略過）；回傳 (點估計, 2.5%, 97.5%)，
    點估計是 None 就回 None。比值型 KPI（不是每千 km 件數）用這支，率比用 boot_ratio。"""
    by = collections.defaultdict(list)
    for o in L:
        by[o.get("u")].append(o)
    U = list(by.values())
    pt = stat(L)
    if pt is None:
        return None
    rnd, rr = random.Random(seed), []
    for _ in range(B):
        v = stat([o for _ in U for o in rnd.choice(U)])
        if v is not None:
            rr.append(v)
    return pt, q(rr, 0.025), q(rr, 0.975)


FUEL_PASS_LO = 0.9      # 油量換算判準：α 玩家 95% 下限 ≥ 這個值＝過（2026-10-25 正式服 0.95，0.95–1.00）
FUEL_MIN_USERS = 5      # α 玩家叢集 bootstrap 至少這麼多人才判
FUEL_SMALL_STEP = 0.03  # 步長指紋：≤ 這個 % 的油量下降＝退款後的小步（模擬：換算有作用 48–57%、沒換算 9–11%）


def fuel_intervals(C):
    """片段 → (同步區間 [dict(u, rev, key, obs, H, F, ms)], 油量下降步長 % 清單)。
    樣本 fu 是伺服器同步值：兩次油量變動之間＝整數個伺服器計費步，區間內積分原版 GasTank 期望（held＝實際檔 tn、fair＝伺服器換算檔，
    公式同 MDAD_Upload tripKpi 的 fuE；檔數＝片段裡車速 ≥0.4×極速時最高的 tn，同 scriptName 共用），不受「值到達那筆」歸段影響。
    只收「上一次變動是下降、這次下降 0–1%」的區間（第一段起點不明、加油後那段不算）；樣本間隔 ≤0 或 >2 s 切開重來。"""
    gears, mx = collections.Counter(), {}
    for c in C:
        sc, m = c["prof"].get("scriptName"), c["prof"].get("maxSpeed")
        mx[sc] = m
        for r in c["rows"]:
            if isinstance(r.get("tn"), int) and m and abs(r.get("spd") or 0) >= 0.4 * m:
                gears[sc] = max(gears[sc], r["tn"])
    iv, steps = [], []
    for key, t in trips(C).items():
        rec = t["clips"][0]
        sc = rec["prof"].get("scriptName")
        n, m = gears.get(sc), mx.get(sc)
        if not n or n < 2 or not m:
            continue
        per, mm = m / n, abs(1000 - (rec["prof"].get("mass") or 1000)) / 300 + 1
        R = [r for r in t["rows"] if isinstance(r.get("fu"), (int, float))]
        last, H, F, ms, ok = None, 0.0, 0.0, 0, False
        for a, b in zip(R, R[1:]):
            dt = (b["ts"] - a["ts"]) / 1000
            if dt <= 0 or dt > 2:
                last, H, F, ms, ok = None, 0.0, 0.0, 0, False
                continue
            v, es, g = abs(a.get("spd") or 0), a.get("es") or 0, a.get("tn")
            if es > 0 and isinstance(g, int):
                if math.floor(v) > 0:
                    h = gas_term(g, v, per) * mm
                    fg = min(n, math.floor(min(v, m) / per) + 1)
                    f = gas_term(fg, v, per) * mm if g >= 2 and g > fg else h
                else:
                    h = f = 150.0
                H += h * es / 2500 * dt
                F += f * es / 2500 * dt
            ms += b["ts"] - a["ts"]
            if b["fu"] < a["fu"]:
                steps.append(a["fu"] - b["fu"])
            if last is None:
                last = a["fu"]
            if b["fu"] != last:
                if ok and 0 < last - b["fu"] < 1.0:
                    iv.append(dict(u=rec["u"], rev=rec["rev"], key=key, obs=last - b["fu"], H=H, F=F, ms=ms))
                ok = b["fu"] < last
                last, H, F, ms = b["fu"], 0.0, 0.0, 0
    return iv, steps


def gas_term(gear, kmh, per):
    """同 MDAD.gasGearTerm（原版 Vehicles.lua:467-479 的檔位項）。"""
    x = (per * 0.71 * gear - kmh) * 350
    return 800.0 if x < 800 else x


def fuel_alpha(iv):
    """同步區間 → 換算比例 α（0–1，格距 0.05）：擬合 obs ≈ k_趟 ×(α·F + (1−α)·H)，k_趟 以該趟區間總量正規化（消掉油箱、
    引擎品質、耗油沙盒值、自駕加成），α 取 Σ(obs−pred)²/pred 最小。1＝照換算後的檔計費、0＝照實際檔（換算沒作用）。
    少於 3 個區間的趟不算；沒有可用的趟回 None。"""
    byt = collections.defaultdict(list)
    for x in iv:
        byt[x["key"]].append(x)
    rs = [r for r in byt.values() if len(r) >= 3]
    if not rs:
        return None
    best = None
    for i in range(21):
        a, dev = i / 20, 0.0
        for r in rs:
            M = [a * x["F"] + (1 - a) * x["H"] for x in r]
            to, tm = sum(x["obs"] for x in r), sum(M)
            if to <= 0 or tm <= 0:
                continue
            k = to / tm
            dev += sum((x["obs"] - k * p) ** 2 / (k * p) for x, p in zip(r, M) if p > 0)
        if best is None or dev < best[1]:
            best = (a, dev)
    return best[0]


def q(xs, p):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * p
    i = int(k)
    return xs[i] if i + 1 >= len(xs) else xs[i] + (xs[i + 1] - xs[i]) * (k - i)


def opts_of(s):
    return dict(p.split("=", 1) for p in (s or "").split(";") if "=" in p)


def is_tow(o):
    """摘要這趟有拖車（ev.tow 或 cap.tow）。"""
    return bool((o.get("ev") or {}).get("tow") or (o.get("cap") or {}).get("tow"))


def per_em(d, o):
    """摘要 km/h·s 帳（loss／lpw…）÷ em（有效上限時間平均）＝秒；em 缺或 0 回 {}。"""
    em = o.get("em") or 0
    return {k: v / em for k, v in (d or {}).items()} if em > 0 else {}


def fam(sprite):
    return re.sub(r"_\d+$", "", sprite) if sprite else None


def group_by(L, key):
    g = collections.defaultdict(list)
    for o in L:
        g[key(o)].append(o)
    return g


def region(x, y):
    """世界座標 → 新圖地圖名（NEW_CELLS）／"old"；沒座標回 None。"""
    if not isinstance(x, (int, float)) or not isinstance(y, (int, float)):
        return None
    cx, cy = int(x // 256), int(y // 256)
    return next((m for m, y0, y1, xs in NEW_CELLS if y0 <= cy <= y1 and any(a <= cx <= b for a, b in xs)), "old")


def trip_region(o):
    """摘要起訖 x0,y0／x1,y1 → "old"、地圖名、"mixed"（一新一舊或兩張新圖）、"?"（都沒座標）。"""
    s = {r for r in (region(o.get("x0"), o.get("y0")), region(o.get("x1"), o.get("y1"))) if r}
    return "?" if not s else s.pop() if len(s) == 1 else "mixed"


def ev_region(e, rec):
    """事件區域：事件自帶 x,y，否則用事件當下（≤ts+5ms）最後一筆樣本的 x,y；都沒有＝"?"。"""
    r = edge_row(rec, e.get("ts") or 0)
    return region(e.get("x"), e.get("y")) or region(r.get("x"), r.get("y")) or "?"


def eng_class(d):
    """engine off 事件或摘要 eng（1026g est／kso／erm）→ 機制：kso <KSO_PLAYER_MS＝玩家關引擎；est=Stalling＝熄火或沒油；
    erm <ERM_EARLY_MS＝剛發動就熄；有新鍵但都不中＝其他（est）；三鍵都沒有（舊 rev）＝未分類。"""
    d = d or {}
    if not any(k in d for k in ("est", "kso", "erm")):
        return "未分類"
    if isinstance(d.get("kso"), (int, float)) and d["kso"] < KSO_PLAYER_MS:
        return "玩家關引擎"
    if d.get("est") == "Stalling":
        return "熄火或沒油"
    if isinstance(d.get("erm"), (int, float)) and d["erm"] < ERM_EARLY_MS:
        return "剛發動就熄"
    return f"其他（est={d.get('est')}）"


def vf_dedupe(L):
    """舊 rev（摘要沒有 vfW）路中停車首見 vfInTs 以「同玩家 VF_WIN_MS 窗」去重 → 件數（SpeedTime §4a：同一筆兩個停車條目、
    0.4 s 後再記一次都會 +1）。窗從該窗第一筆起算，不因窗內再見延長。"""
    by = collections.defaultdict(list)
    for o in L:
        by[o.get("u")] += [t for t in o.get("vfInTs") or [] if isinstance(t, (int, float))]
    n = 0
    for ts in by.values():
        t0 = None
        for t in sorted(ts):
            if t0 is None or t - t0 >= VF_WIN_MS:
                n, t0 = n + 1, t
    return n


def seg_flag(e, pt):
    """route 事件的 src（"x,y;x,y;…"）與逐段旗標 srcC（"1;0;…"，第 i 項＝第 i→i+1 點那段）→ 離 pt 最近那段的旗標字串；
    沒有 srcC、點列不足或該段被截掉回 None。"""
    P, F = [], e.get("srcC").split(";") if isinstance(e.get("srcC"), str) else []
    for p in e.get("src").split(";") if isinstance(e.get("src"), str) else ():
        try:
            x, y = map(float, p.split(","))
        except ValueError:          # 截斷的尾點：前面的段照用
            break
        P.append((x, y))
    if not F or len(P) < 2 or None in pt:
        return None

    def d2(a, b):
        vx, vy, wx, wy = b[0] - a[0], b[1] - a[1], pt[0] - a[0], pt[1] - a[1]
        t = max(0.0, min(1.0, (vx * wx + vy * wy) / (vx * vx + vy * vy))) if vx or vy else 0.0
        return (wx - t * vx) ** 2 + (wy - t * vy) ** 2
    i = min(range(len(P) - 1), key=lambda k: d2(P[k], P[k + 1]))
    return F[i] if i < len(F) and F[i] != "" else None


# ---------- 載入 ----------

def load_summaries(root):
    S = {}
    for f in sorted(glob.glob(os.path.join(root, "summary-*.log"))):
        for ln in open(f, encoding="utf-8", errors="replace"):
            if not ln.startswith("{"):
                continue
            try:
                o = json.loads(ln)
            except ValueError:
                continue
            if o.get("t") == "sum":
                S[(o.get("u"), o.get("drive"))] = o
    return S


def load_clips(root, since_ms=None):
    """since_ms 省略＝pull.json 的 since（pull_uploads 寫的窗口）。"""
    if since_ms is None:
        with open(os.path.join(root, "pull.json"), encoding="utf-8") as fh:
            since_ms = json.load(fh)["since"] * 1000
    C = []
    for f in sorted(glob.glob(os.path.join(root, "*", "clip-*.log"))):
        clip, hdr, recs = AT.load_file(f)
        if not clip or (clip.get("trig") or 0) < since_ms:
            continue
        rows = sorted((r for r in recs if r["t"] == "s"), key=lambda r: r["ts"])
        evs = [r for r in recs if r["t"] == "e"]
        prof = hdr.get("profile") or {}
        C.append(dict(f=os.path.relpath(f, root).replace(os.sep, "/"), u=os.path.basename(os.path.dirname(f)),
                      kind=clip.get("kind"), trig=clip.get("trig"), drive=clip.get("drive"), at=clip.get("at") or {},
                      rev=hdr.get("rev"), build=hdr.get("build"), veh=str(prof.get("scriptName"))[5:], prof=prof,
                      opts=opts_of(hdr.get("opts")), rows=rows, evs=evs,
                      src=any("src" in e for e in evs if e.get("n") == "route")))
    return C


def dedupe(C):
    """事件 (u, drive, ts, n, phase) → [(e, rec)…]（同一事件可能出現在同趟多個片段）。"""
    E = collections.defaultdict(list)
    for rec in C:
        for e in rec["evs"]:
            E[(rec["u"], rec["drive"], e.get("ts"), e.get("n"), e.get("phase"))].append((e, rec))
    return E


def trips(C):
    """(u, drive) → dict(rows, evs, clips)：同趟多個片段的樣本依 ts、事件依 (ts, n, phase) 去重後合併、依 ts 排序。"""
    T = {}
    for rec in C:
        t = T.setdefault((rec["u"], rec["drive"]), dict(rows={}, evs={}, clips=[]))
        t["clips"].append(rec)
        for r in rec["rows"]:
            t["rows"].setdefault(r["ts"], r)
        for e in rec["evs"]:
            t["evs"].setdefault((e.get("ts"), e.get("n"), e.get("phase")), e)
    for t in T.values():
        t["rows"] = sorted(t["rows"].values(), key=lambda r: r["ts"])
        t["evs"] = sorted(t["evs"].values(), key=lambda e: e.get("ts") or 0)
    return T


def window(rows, ts, ms=PRE_MS):
    return [r for r in rows if ts - ms <= r["ts"] <= ts + 5]


def pick(occ):
    """同一事件多個片段時，取事件前窗口樣本最多的那段。"""
    return max(occ, key=lambda er: len(window(er[1]["rows"], er[0]["ts"])))


def events(E, n, phase=None):
    out = [pick(occ) for k, occ in E.items() if k[3] == n and (phase is None or k[4] == phase)]
    return sorted(out, key=lambda er: er[0]["ts"])


def dominant_ctl(rows):
    c = collections.Counter(r.get("ctl") for r in rows if r.get("ctl"))
    return c.most_common(1)[0][0] if c else None


# ---------- 撞擊歸因 ----------

def nb_touch(nb, prof, ego_kmh=None, gap_ms=None):
    """nb {kind: [d, s, l]} → [(kind, d, 貼車?)]。他車（v）縱向用兩車半長（本車＋OTHER_HALF_L），並扣掉撞後到這筆取樣兩車已拉開的距離
    （nb v 第 4 項＝對方 km/h；(對方 − 本車)×原始間隔，只扣正值）：nb 在撞擊上升緣那筆（撞後）才掃，追撞後前車照開、本車掉到 7 km/h，
    200 ms 就拉開 3–4 m（正式服 P06 E150long 追撞 F350，車心距 7.2 m 被歸 far）。"""
    hl, hw = (prof.get("halfL") or 0) + TOUCH_PAD, (prof.get("halfW") or 0) + TOUCH_PAD
    out = []
    for k, v in (nb or {}).items():
        if isinstance(v, list) and len(v) >= 3 and isinstance(v[1], (int, float)) and isinstance(v[2], (int, float)):
            s = abs(v[1])
            if k == "v":
                ov = v[3] if len(v) >= 4 and isinstance(v[3], (int, float)) else None
                if ov is not None and isinstance(ego_kmh, (int, float)) and isinstance(gap_ms, (int, float)):
                    s -= max(0.0, (abs(ov) - abs(ego_kmh)) / 3.6 * gap_ms / 1000)
            lim = hl + OTHER_HALF_L if k == "v" else hl
            out.append((k, v[0], s <= lim and abs(v[2]) <= hw))
    return out


def edge_row(rec, ts):
    rows = [r for r in rec["rows"] if r["ts"] <= ts + 5]
    return rows[-1] if rows else {}


def impact_false(e, rec, S=None):
    """不算撞擊的上升緣 → 類別或 None：事件 cls≠hit（frozen／tow-sync／rehitch，1008／1017）；1017 前的片段用樣本推：
    上升緣樣本 m=rehitch、或 rh-attach 後 REHITCH_SETTLE_MS 內＝rehitch；摘要 reason=exit、撞擊在結束前 EXIT_BRAKE_MS 內、
    上升緣 tn 0 且 fbl 0＝exit。"""
    cls = e.get("cls")
    if cls and cls != "hit":
        return cls
    ts = e["ts"]
    r = edge_row(rec, ts)
    rh = e.get("rhMs")
    if e.get("m") == "rehitch" or r.get("m") == "rehitch" or (isinstance(rh, (int, float)) and 0 <= rh <= REHITCH_SETTLE_MS) \
            or any(x.get("n") == "tow" and x.get("phase") == "rh-attach" and 0 <= ts - (x.get("ts") or 0) <= REHITCH_SETTLE_MS
                   for x in rec["evs"]):
        return "rehitch"
    o = (S or {}).get((rec["u"], rec["drive"])) or (S or {}).get(("*", rec["drive"])) or {}
    tn = e.get("tn", r.get("tn"))
    if (o.get("reason") or "").replace(PFX, "") == "exit" and isinstance(o.get("end"), (int, float)) \
            and 0 <= o["end"] - ts <= EXIT_BRAKE_MS and tn == 0 and not (r.get("fbl") or 0) > 0:
        return "exit"
    return None


def contact_near(e, rec):
    """撞擊前 PRE_MS 內（到撞擊後 5 ms）最後一筆 contact 事件：命中點 1 格內的 sprite，比車頭 3 格搜尋準。"""
    cs = [x for x in rec["evs"] if x.get("n") == "contact" and e["ts"] - PRE_MS <= (x.get("ts") or 0) <= e["ts"] + 5]
    return max(cs, key=lambda x: x["ts"]) if cs else None


def classify_impact(e, rec):
    """→ (類別, awt, maneuver, nb 清單, sprite, scost)。static 判定與 sprite：有 contact 事件時用它的，否則用事件車頭 3 格；
    contact 命中他車輪廓（scost vehicle）或撞擊當下 lead 車距 tlg ≤1 m（1017 起事件帶）＝vehicle。"""
    ts = e["ts"]
    edge = [r for r in rec["rows"] if r["ts"] <= ts + 5 and "nb" in r]
    nb = nb_touch(edge[-1]["nb"], rec["prof"], edge[-1].get("spd"), e.get("ms")) if edge else []
    pre = window(rec["rows"], ts)
    man = dominant_ctl(pre) in ("AVOID", "RETURN") or any(r.get("dg") for r in pre)
    touch = {k for k, _, t in nb if t}
    c = contact_near(e, rec)
    sprite, scost = (c.get("sprite"), c.get("scost")) if c else (e.get("sprite"), e.get("scost"))
    tlg = e.get("tlg")
    if scost == "vehicle" or (isinstance(tlg, (int, float)) and tlg <= 1):
        touch.add("v")
    cls = next((name for k, name in NB_KIND if k in touch), None)
    if cls == "animal":
        a = (edge[-1]["nb"] or {}).get("a")
        kg = a[4] if isinstance(a, list) and len(a) >= 5 else None
        if isinstance(kg, (int, float)) and kg < SMALL_KG:
            cls = "small-animal"
    if cls is None:
        cls = ("static" if scost in STATIC else "corpse" if "c" in touch else "far" if nb else "empty")
    return cls, bool(e.get("awt")), man, nb, sprite, scost


def real_impacts(E, S=None):
    """→ ([(e, rec)…] 真撞擊, Counter 不算的類別)：排除 impact_false，同 (u, drive) IMPACT_REARM_MS 內只留第一件。"""
    out, skip, last = [], collections.Counter(), {}
    for e, rec in events(E, "impact"):
        f = impact_false(e, rec, S)
        if f:
            skip[f] += 1
            continue
        k = (rec["u"], rec["drive"])
        if k in last and e["ts"] - last[k] < IMPACT_REARM_MS:
            skip["rearm"] += 1
            continue
        last[k] = e["ts"]
        out.append((e, rec))
    return out, skip


def small_impacts(E, S=None):
    """(u, drive) → 歸成 small-animal 的撞擊件數（A 節扣除用；E 不限 rev；假撞與 rearm 重複先排除）。"""
    out = collections.Counter()
    for e, rec in real_impacts(E, S)[0]:
        if classify_impact(e, rec)[0] == "small-animal":
            out[(rec["u"], rec["drive"])] += 1
    return out


# ---------- 各節 ----------

def sec_a(S, small=None, cur=(), cover=None):
    print("== A 摘要（(u, drive) 去重、依 build）")
    by = collections.defaultdict(list)
    for o in S.values():
        by[o.get("build") or "?"].append(o)
    order = sorted((b for b in by if len(by[b]) >= 20), key=lambda b: [int(x) for x in re.findall(r"\d+", b)])
    K = {}
    for b in order:
        L = by[b]
        n = len(L)
        km = sum(o.get("dist") or 0 for o in L) / 1000
        k = {f: sum(o.get(f) or 0 for o in L) for f in ("impact", "impZ", "contact")}
        sm = sum((small or {}).get((o.get("u"), o.get("drive")), 0) for o in L)
        ns = max(0, k["impact"] - sm)
        revs = dict(collections.Counter(o.get("rev") for o in L))
        print(f"{b} rev={revs} trips={n} users={len({o.get('u') for o in L})} km={km:.0f}")
        if km:
            print("  " + "  ".join(f"{f} {v}={v / km * 1000:.1f}/千km (95% {ci(v)[0] / km * 1000:.1f}-{ci(v)[1] / km * 1000:.1f})"
                                   for f, v in k.items()))
            print(f"  impact 不含小動物 {ns}={ns / km * 1000:.1f}/千km (95% {ci(ns)[0] / km * 1000:.1f}-{ci(ns)[1] / km * 1000:.1f})"
                  f"（扣 small-animal {sm}；片段涵蓋 {(cover or {}).get(b, 0)}/{k['impact']} 件）")
        K[b] = (km, k, ns, collections.Counter(o.get("rpt") or "unknown" for o in L))
        if set(K[b][3]) != {"unknown"}:      # 1018a 起摘要 rpt＝最後一次 route cutover 的主 MOD RoadPatch 狀態；缺＝舊 rev／舊主 MOD
            print("  RoadPatch rpt " + ", ".join(f"{r}:{v}" for r, v in K[b][3].most_common()))
        rs = collections.Counter((o.get("reason") or "?").replace(PFX, "") for o in L)
        print("  reasons " + ", ".join(f"{r}:{v}({v / n * 100:.1f}%)" for r, v in rs.most_common()))
        loss = collections.Counter()
        for o in L:
            for r, v in (o.get("loss") or {}).items():
                if r != "none":
                    loss[r] += v
        tot = sum(loss.values())
        if tot:
            print("  loss " + ", ".join(f"{r}:{v / tot * 100:.0f}%" for r, v in loss.most_common(8)))
        fm, nm = sum(o.get("fm") or 0 for o in L), sum(o.get("nm") or 0 for o in L)
        hasoff = [o for o in L if "offN" in o]
        line = f"  nm/fm={nm / fm if fm else 0:.3f}"
        if hasoff:
            offn = sum(o.get("offN") or 0 for o in hasoff)
            line += (f"  offset 趟={len(hasoff)} 有偏離={sum(1 for o in hasoff if o.get('offN'))} offN={offn}"
                     f"（{offn / km * 100 if km else 0:.1f}/百km） offMax={max(o.get('offMax') or 0 for o in hasoff) / 1000:.1f}s")
        print(line)
    sm = small or {}
    val = {"impact": lambda o: o.get("impact") or 0, "impZ": lambda o: o.get("impZ") or 0,
           "contact": lambda o: o.get("contact") or 0,
           "impact不含小動物": lambda o: max(0, (o.get("impact") or 0) - sm.get((o.get("u"), o.get("drive")), 0))}

    def cmp(name, L1, L2):
        w1, w2 = (sum(o.get("dist") or 0 for o in L) / 1000 for L in (L1, L2))
        parts = []
        for f, fn in val.items():
            r = boot_ratio(L1, L2, fn)
            p = binom_p(sum(map(fn, L1)), sum(map(fn, L2)), w1, w2) if w1 + w2 else 1.0
            parts.append(f"{f} ×{r[0]:.2f}（{r[1]:.2f}–{r[2]:.2f}）p={p:.3f}" if r else f"{f} —（基準 0 件）p={p:.3f}")
        print(f"  {name}: " + "  ".join(parts))

    print("  率比（玩家叢集 bootstrap 95%；p＝Poisson 條件二項，同一玩家連撞時偏小：判版本差看區間，並對照同碼 A/A）")
    for i in range(1, len(order)):
        cmp(f"{order[i]} vs {order[i - 1]}", by[order[i]], by[order[i - 1]])
    same = [b for b in order if cur and {o.get("rev") for o in by[b]} <= set(cur)]
    if len(same) >= 2:
        cmp(f"同碼 A/A（--current 駕駛相同）{same[0]} vs {'+'.join(same[1:])}", by[same[0]], [o for b in same[1:] for o in by[b]])
    return {b: dict(trips=len(by[b]), km=K[b][0], impactNoSmall=K[b][2], rpt=dict(K[b][3]), **K[b][1]) for b in order}


def sec_b(C, cur, A):
    print(f"\n== B 窗口片段 {len(C)} 段，玩家 {len({r['u'] for r in C})}")
    byrk = collections.defaultdict(collections.Counter)
    for r in C:
        byrk[r["rev"]][r["kind"]] += 1
    for rev in sorted(byrk, key=lambda x: x or ""):
        print(f"  rev={rev} n={sum(byrk[rev].values())} " + ", ".join(f"{k}:{v}" for k, v in byrk[rev].most_common()))
    cr = [r for r in C if r["rev"] in cur]
    ok = [r for r in cr if len(r["rows"]) >= 10 and r["src"] and (r["trig"] - r["rows"][0]["ts"]) >= 3000]
    print(f"  現行 rev {len(cr)} 段；可用（事前 ≥3s、樣本 ≥10、有 route 點列）{len(ok)} 段")
    print("  現行 rev kind 可用/全部 " + ", ".join(f"{k}:{sum(1 for r in ok if r['kind'] == k)}/{sum(1 for r in cr if r['kind'] == k)}"
                                          for k in sorted({r["kind"] for r in cr})))
    return dict(clips=len(C), usable=len(ok))


def sec_c(E, A, picks, S=None):
    print("\n== C 撞擊歸因（現行 rev，(u, drive, ts) 去重；排除 cls≠hit／掛回／下車煞車，同趟 2s 內只算一件）")
    rows = []
    real, skip = real_impacts(E, S)
    for e, rec in real:
        cls, awt, man, nb, sprite, scost = classify_impact(e, rec)
        rows.append((rec["rev"], cls, awt, man, rec))
        tag = "awt-" if awt else "maneuver-" if man else ""
        picks.append((f"impact-{tag}{cls}", e["ts"], rec, f"v={e.get('speed')} dv={e.get('dv')} scost={scost} "
                      f"sprite={sprite} tlg={e.get('tlg')} nb={[(k, round(d, 2), t) for k, d, t in nb]}"))
    cnt = collections.Counter((r[0], r[1]) for r in rows)
    revs = sorted({r[0] for r in rows})
    print(f"  共 {len(rows)} 件；awt {sum(1 for r in rows if r[2])}、maneuver {sum(1 for r in rows if r[3])}；"
          f"排除 " + ", ".join(f"{k}:{v}" for k, v in sorted(skip.items())))
    for cls in ("zombie", "small-animal", "animal", "vehicle", "static", "corpse", "far", "empty"):
        print(f"  {cls:12s} " + "  ".join(f"{rev}:{cnt[(rev, cls)]}" for rev in revs) + f"  計 {sum(cnt[(rev, cls)] for rev in revs)}"
              + ("（maneuver %d）" % sum(1 for r in rows if r[1] == cls and r[3])))
    zo = collections.Counter(f"zdodge={r[4]['opts'].get('zdodge')} zslow={r[4]['opts'].get('zslow')}" for r in rows if r[1] == "zombie")
    print("  zombie 依 opts " + ", ".join(f"{k}:{v}" for k, v in zo.most_common()))
    out = collections.Counter(r[1] for r in rows)
    out.update({"skip-" + k: v for k, v in skip.items()})
    return out


def fuel_verdict(res):
    """α 的 (點估計, 2.5%, 97.5%) → 判定：下限 ≥FUEL_PASS_LO＝過；上限 <FUEL_PASS_LO＝不過（換算沒作用或只部分作用；
    反證模擬沒換算 α 0.05–0.25）；區間跨過 FUEL_PASS_LO＝不確定（樣本太少分不出，不能當成不過）；None＝樣本不足。"""
    if res is None:
        return "樣本不足"
    return "過" if res[1] >= FUEL_PASS_LO else "不過" if res[2] < FUEL_PASS_LO else "不確定"


def fuel_check(C):
    """L 節油量判準（片段同步區間積分，fuel_intervals／fuel_alpha）：α 全部與依 rev 的玩家叢集 95% 與 fuel_verdict，
    少於 FUEL_MIN_USERS 人＝樣本不足；另印步長指紋（≤FUEL_SMALL_STEP % 的下降佔比，只監控）。
    取代 1020 起的摘要 (彎道＋繞行)/其他 段比：伺服器同步由原版扣量（換算前）觸發，下降記在值到達那筆的段，
    模擬在換算有作用／沒作用時段比都落在 1.2–1.5，沒有鑑別力（.omc/plans/mdad-prod-1025/agent-TowFuelHud.md §1.4）。"""
    iv, steps = fuel_intervals(C)
    out = dict(steps=len(steps), small=sum(1 for s in steps if s <= FUEL_SMALL_STEP + 1e-9))
    print("  油量換算判準（片段兩次油量同步之間積分原版公式期望；α 1＝照伺服器換算檔計費、0＝照實際檔＝換算沒作用）")
    revs = sorted({x["rev"] for x in iv})
    for name, g in [("全部", iv)] + ([(r, [x for x in iv if x["rev"] == r]) for r in revs] if len(revs) > 1 else []):
        users = len({x["u"] for x in g})
        res = boot_players(g, fuel_alpha, B=500) if users >= FUEL_MIN_USERS else None
        verdict = fuel_verdict(res)
        out[name] = dict(alpha=res and tuple(round(v, 2) for v in res), n=len(g), trips=len({x["key"] for x in g}),
                         users=users, verdict=verdict)
        print(f"    {name}：α " + ("—" if res is None else f"{res[0]:.2f}（玩家 95% {res[1]:.2f}–{res[2]:.2f}）")
              + f"；區間 {len(g)}、趟 {out[name]['trips']}、人 {users}、{sum(x['ms'] for x in g) / 60000:.0f} 分鐘"
              + f"；判準（{FUEL_MIN_USERS} 人以上）下限 ≥{FUEL_PASS_LO} 過、上限 <{FUEL_PASS_LO} 不過、跨過＝不確定：{verdict}")
    if steps:
        print(f"    步長指紋：油量下降 {len(steps)} 步，≤{FUEL_SMALL_STEP}% 佔 {out['small'] / len(steps) * 100:.0f}%"
              "（模擬：換算有作用 48–57%、沒換算 9–11%；只監控）")
    return out


def sec_l(S, cur, C=()):
    """1017 摘要新欄位（只算帶 rhi 的摘要＝rev ≥1017f）：假撞另計、路中停車首見、入彎超速明細、出彎偏差、油量、起步、
    煞車學習拒收、EngineOff 關卡；C（現行 rev 片段）另算油量換算判準 fuel_check。"""
    print("\n== L 1017 摘要新欄位（rev 有 rhi 欄的趟）")
    L = [o for o in S.values() if "rhi" in o and (not cur or o.get("rev") in cur)]
    out = dict(trips=len(L))
    if C:
        out["fuelA"] = fuel_check(C)
    if not L:
        print("  （沒有摘要）")
        return out
    km = sum(o.get("dist") or 0 for o in L) / 1000
    tot = {f: sum(o.get(f) or 0 for o in L) for f in ("impact", "rhi", "xbk", "vfIn", "vfInX", "exN", "exDev", "exN50", "exDev50")}
    out.update(tot, km=round(km, 3))
    print(f"  趟 {len(L)} km {km:.1f}：impact {tot['impact']} rhi {tot['rhi']} xbk {tot['xbk']}；路中停車首見 vfIn {tot['vfIn']}"
          f"（8s 內出事 {tot['vfInX']}）；出口 {tot['exDev']}/{tot['exN']}（≥50 km/h {tot['exDev50']}/{tot['exN50']}）")
    aoi = [a for o in L for a in (o.get("aoi") or [])]
    out["aoi"] = len(aoi)
    if aoi:
        print(f"  入彎超速明細 {len(aoi)} 筆：第一個弧 {sum(1 for a in aoi if len(a) > 7 and a[7] == 1)}、"
              f"有 vad {sum(1 for a in aoi if len(a) > 4 and (a[4] or 0) > 0)}、spd/cap 中位 "
              f"{statistics.median(a[1] / a[2] for a in aoi if len(a) > 2 and a[1] and a[2]):.2f}")
    fu = [o for o in L if isinstance(o.get("fu0"), (int, float)) and isinstance(o.get("fu1"), (int, float))]
    seg = collections.defaultdict(lambda: [0.0, 0.0])
    for o in fu:
        for k, v in (o.get("fuS") or {}).items():
            if isinstance(v, list) and len(v) >= 2:
                seg[k][0] += v[0] or 0
                seg[k][1] += v[1] or 0
    out["fuel"] = {k: [round(d, 2), round(m, 3)] for k, (d, m) in seg.items()}
    if fu:
        print(f"  油量 {len(fu)} 趟：起訖差 {sum(o['fu0'] - o['fu1'] for o in fu):.2f}%；分段 %/km（記在值到達那筆的段，只描述） "
              + ", ".join(f"{k}:{d / m if m else 0:.2f}({m:.1f}km)" for k, (d, m) in sorted(seg.items())))
    fe = [o for o in fu if o.get("fuE")]
    if fe:
        tm, dr = collections.Counter(), collections.Counter()
        for o in fe:
            tm.update(o.get("fuT") or {})
            dr.update({s: v[0] or 0 for s, v in (o.get("fuS") or {}).items() if isinstance(v, list) and v})
        out["fuelE"] = dict(trips=len(fe), users=len({o.get("u") for o in fe}),
                            perMin={s: round(dr[s] / (tm[s] / 60000), 3) for s in sorted(set(tm) | set(dr)) if tm[s] > 0})
        print(f"  每分鐘扣量 %/min（摘要 fuT 有記的 {len(fe)} 趟 {out['fuelE']['users']} 人，同樣是到達歸段，只描述） "
              + ", ".join(f"{s}:{v:.3f}({tm[s] / 60000:.0f}min)" for s, v in out["fuelE"]["perMin"].items()))
    t40 = collections.defaultdict(list)
    for o in L:
        if isinstance(o.get("t40"), (int, float)):
            t40[o.get("t40k") or "?"].append(o["t40"])
    out["t40"] = {k: round(statistics.median(v)) for k, v in t40.items()}
    print("  起步到 40m 中位 ms " + ", ".join(f"{k}:{statistics.median(v):.0f}(n={len(v)})" for k, v in sorted(t40.items())))
    blr = collections.Counter()
    for o in L:
        blr.update(o.get("blr") or {})
    out["blr"] = dict(blr)
    print("  煞車學習拒收 " + (", ".join(f"{k}:{v}" for k, v in blr.most_common()) or "0"))
    eng = collections.Counter((o.get("eng") or {}).get("why") for o in L if o.get("eng"))
    out["eng"] = dict(eng)
    ecd = [o["eng"]["ecd"] for o in L if isinstance((o.get("eng") or {}).get("ecd"), (int, float))]
    out["engLow"] = (sum(1 for c in ecd if c < 50), len(ecd))
    print("  EngineOff 關卡 " + (", ".join(f"{k}:{v}" for k, v in eng.most_common()) or "0")
          + (f"；引擎零件狀況 <50（原版隨機熄火區）{out['engLow'][0]}/{len(ecd)}" if ecd else ""))
    ec = collections.Counter(eng_class(o["eng"]) for o in L if o.get("eng"))
    out["engClass"] = dict(ec)
    if ec:
        print(f"  EngineOff 機制（1026g 摘要 eng est／kso／erm：kso <{KSO_PLAYER_MS}ms 玩家關引擎、est=Stalling 熄火或沒油、"
              f"erm <{ERM_EARLY_MS}ms 剛發動就熄；舊 rev 未分類） " + ", ".join(f"{k}:{v}" for k, v in ec.most_common()))
    out["vf"] = {}
    for g, R in sorted(group_by(L, trip_region).items()):
        nw, od = [o for o in R if "vfW" in o], [o for o in R if "vfW" not in o]
        km_g = sum(o.get("dist") or 0 for o in R) / 1000
        v = dict(km=round(km_g, 1))
        if nw:   # 1026g 起：以窗計，vfWX＝窗內接觸／visibility／moving 鎖輪＝判準的失敗窗；vb（blocked 鎖輪）／va（可視輔助）只參考
            xk = collections.Counter()
            for o in nw:
                xk.update({k: n for k, n in (o.get("vfXk") or {}).items() if isinstance(n, (int, float))})
            ws = [w for o in nw for w in o.get("vfWs") or [] if isinstance(w, list) and len(w) >= 3]
            v.update(trips=len(nw), vfW=sum(o.get("vfW") or 0 for o in nw), vfWX=sum(o.get("vfWX") or 0 for o in nw),
                     xk=dict(xk), fast=sum(1 for w in ws if isinstance(w[2], (int, float)) and w[2] >= VF_FAST_KMH), ws=len(ws))
        if od:   # 舊 rev：vfIn 每個首見 +1、vfInX 含 blocked 鎖輪 → vfInTs 同玩家 8 s 去重；失敗只能參考 fb visibility／moving
            v.update(oldTrips=len(od), vfIn=sum(o.get("vfIn") or 0 for o in od), vfInDedup=vf_dedupe(od),
                     vfInX=sum(o.get("vfInX") or 0 for o in od),
                     fbVM=sum((o.get("fb") or {}).get(k) or 0 for o in od for k in ("visibility", "moving")))
        out["vf"][g] = v
    print(f"  路中停車首見 V5（依區域；1026g vfW 窗數／vfWX 失敗窗、vfWs 本車 ≥{VF_FAST_KMH} km/h 的窗；"
          f"舊 rev vfInTs 同玩家 {VF_WIN_MS // 1000}s 去重，vfInX 含 blocked 鎖輪只參考）")
    for g, v in out["vf"].items():
        line = f"    {g} {v['km']}km"
        if "vfW" in v:
            line += (f"：1026g {v['trips']} 趟 vfW {v['vfW']} vfWX {v['vfWX']}（vb {v['xk'].get('vb', 0)} va {v['xk'].get('va', 0)} 參考）"
                     f" ≥{VF_FAST_KMH}km/h {v['fast']}/{v['ws']}")
        if "vfIn" in v:
            line += (f"：舊 rev {v['oldTrips']} 趟 vfIn {v['vfIn']} 去重 {v['vfInDedup']}；vfInX {v['vfInX']}、"
                     f"fb visibility+moving {v['fbVM']}（參考）")
        print(line)
    vh = group_by([o for o in L if "vhN" in o], trip_region)
    out["vh"] = {g: dict(trips=len(R), vhN=sum(o.get("vhN") or 0 for o in R), vhLt=sum(o.get("vhLt") or 0 for o in R),
                         vhMin=min((o["vhMin"] for o in R if isinstance(o.get("vhMin"), (int, float))), default=None))
                 for g, R in sorted(vh.items())}
    if out["vh"]:
        print("  他車首見（1026g vhN 次／vhLt <15m 次／vhMin m，依區域） " + ", ".join(
            f"{g}:{v['vhN']}/{v['vhLt']}/{v['vhMin']}({v['trips']}趟)" for g, v in out["vh"].items()))
    return out


def sec_d(E, A, picks):
    print("\n== D contact ≥10 km/h（現行 rev）")
    by = collections.defaultdict(list)
    for e, rec in events(E, "contact"):
        if (e.get("speed") or 0) < 10:
            continue
        pre = window(rec["rows"], e["ts"])
        ldm = max((abs(r.get("ld") or 0) for r in pre), default=0)
        d = dict(scost=e.get("scost"), arc=any(r.get("curveHardActive") for r in pre), ld=ldm > 0.5,
                 lag=any(r.get("capReason") == "lag" for r in pre), ctl=dominant_ctl(pre), fam=fam(e.get("sprite")),
                 u=rec["u"])
        by[rec["rev"]].append(d)
        picks.append(("contact>=10", e["ts"], rec, f"{e.get('speed'):.0f}km/h {d['scost']} {e.get('sprite')} arc={int(d['arc'])} "
                      f"ldm={ldm:.2f} ctl={d['ctl']} lag={int(d['lag'])}"))
    for rev, L in sorted(by.items()):
        print(f"  rev={rev} n={len(L)} 玩家 {len({d['u'] for d in L})} 弧上 {sum(d['arc'] for d in L)} |ld|>0.5 {sum(d['ld'] for d in L)} "
              f"lag帽 {sum(d['lag'] for d in L)}")
        for f in ("scost", "ctl", "fam"):
            print(f"    {f} " + ", ".join(f"{k}:{v}" for k, v in collections.Counter(d[f] for d in L).most_common(10)))
    return {rev: len(L) for rev, L in by.items()}


def sec_e(C, A, picks):
    print(f"\n== E 判堵後接手（takeover 片段，觸發前 {TAKE_MS // 1000}s 內有 blocked）")
    out = []
    for rec in C:
        if rec["kind"] != "takeover":
            continue
        trig = rec["trig"]
        bl = [e for e in rec["evs"] if e.get("n") == "blocked" and trig - TAKE_MS <= e["ts"] <= trig + TAKE_POST_MS]
        if not bl:
            continue
        t0 = min(e["ts"] for e in bl)                 # 窗口內第一筆 blocked＝開始判堵；玩家等了多久從這裡算
        last = max(bl, key=lambda e: e["ts"])
        un = sum(1 for e in rec["evs"] if e.get("n") == "unstick" and e.get("phase") == "start" and t0 <= e["ts"] <= trig)
        out.append(dict(rec=rec, dt=(trig - t0) / 1000, un=un, det=rec["opts"].get("detour"),
                        last=f"{last.get('why')}/{last.get('shape')}"))
        picks.append(("takeover-after-blocked", trig, rec, f"blocked→接手 {(trig - t0) / 1000:.1f}s unstick={un} "
                      f"detour={rec['opts'].get('detour')} last={last.get('why')}/{last.get('shape')}"))
    dts = [o["dt"] for o in out]
    print(f"  {len(out)} 段、玩家 {len({o['rec']['u'] for o in out})}；rev " + ", ".join(
        f"{k}:{v}" for k, v in collections.Counter(o['rec']['rev'] for o in out).most_common()))
    if out:
        print(f"  首筆 blocked→接手 s 中位 {statistics.median(dts):.1f} p25 {q(dts, .25):.1f} p75 {q(dts, .75):.1f}；"
              f"其間有 unstick start {sum(1 for o in out if o['un'])} 段；detour=false {sum(1 for o in out if o['det'] == 'false')}"
              f"（{sum(1 for o in out if o['det'] == 'false') / len(out) * 100:.0f}%）")
        print("  最後一筆 why/shape " + ", ".join(f"{k}:{v}" for k, v in collections.Counter(o["last"] for o in out).most_common()))
    return out


def blocked_xy(e):
    """blocked 事件的熱點座標：錨 x,y → 主候選第一個失敗 hx0,hy0 → 候選鏈命中 hitX,hitY；(0,0) 不算（1020a 前非撞擊的掃掠
    失敗寫 0,0，舊片段還會有）。都沒有回 (None, None)。"""
    for kx, ky in (("x", "y"), ("hx0", "hy0"), ("hitX", "hitY")):
        x, y = e.get(kx), e.get(ky)
        if x is not None and y is not None and (x, y) != (0, 0):
            return x, y
    return None, None


def sec_f(E, A):
    print(f"\n== F 判堵熱點（blocked 事件 x,y 的 {GRID}m 格，前 10）")
    cells = collections.defaultdict(lambda: dict(u=set(), d=set(), n=0, veh=set()))
    for e, rec in events(E, "blocked"):
        x, y = blocked_xy(e)
        if x is None:
            continue
        c = cells[(int(x // GRID), int(y // GRID))]
        c["u"].add(rec["u"])
        c["d"].add((rec["u"], rec["drive"]))
        c["n"] += 1
        c["veh"].add(rec["veh"])
    top = sorted(cells.items(), key=lambda kv: (-len(kv[1]["u"]), -kv[1]["n"], kv[0]))[:10]
    for (cx, cy), c in top:
        print(f"  x {cx * GRID}-{cx * GRID + GRID} y {cy * GRID}-{cy * GRID + GRID}: 玩家 {len(c['u'])} 趟 {len(c['d'])} 事件 {c['n']} "
              f"車型 {len(c['veh'])} [{', '.join(sorted(A(u) for u in c['u']))}]")
    return top


def sec_g(E, A, picks):
    print("\n== G 起步調頭 uturn done（依 start × probe；start＝1012 起步段、轉到 30° 才收，ms 不和舊制比）")
    by = collections.defaultdict(list)
    for e, rec in events(E, "uturn", "done"):
        by[(bool(e.get("start")), e.get("probe"))].append(e)
        picks.append((f"uturn-{e.get('probe')}", e["ts"], rec, f"why={e.get('why')} ms={e.get('ms')} detail={e.get('detail')}"))
    print(f"  共 {sum(len(v) for v in by.values())}")
    for (start, probe), L in sorted(by.items(), key=lambda kv: (kv[0][0], str(kv[0][1]))):
        al = [(e.get("ms") or 0) / 1000 for e in L if e.get("why") == "aligned"]
        line = f"  start={int(start)} probe={probe} n={len(L)} why " + ", ".join(f"{k}:{v}" for k, v in collections.Counter(e.get("why") for e in L).most_common())
        if al:
            line += f"；aligned s 中位 {statistics.median(al):.2f} p75 {q(al, .75):.2f} max {max(al):.2f}"
        stop = collections.Counter(e.get("detail") for e in L if e.get("why") == "stop")
        if stop:
            line += "；stop " + ", ".join(f"{k}:{v}" for k, v in stop.most_common())
        print(line)
    room = collections.Counter(e.get("probe") for e, _ in events(E, "uturn", "room"))
    if room:
        print("  room（被擋時倒車騰空間的判定）" + ", ".join(f"{k}:{v}" for k, v in room.most_common()))
    return {f"{int(k[0])}/{k[1]}": len(v) for k, v in by.items()}


def sec_h(C, S, A, picks):
    print("\n== H 判堵鎖輪（brake 片段 at.fbw=blocked）")
    L = []
    for rec in C:
        if rec["kind"] != "brake" or rec["at"].get("fbw") != "blocked":
            continue
        s = S.get((rec["u"], rec["drive"]))
        end = None if s is None else (s.get("end") or 0) - rec["trig"]
        L.append((rec, rec["at"].get("spd") or 0, end))
        picks.append(("brake-blocked-lock", rec["trig"], rec,
                      f"spd={rec['at'].get('spd')} end=" + ("無摘要" if end is None else f"+{end / 1000:.1f}s")))
    sp = [x[1] for x in L]
    print(f"  {len(L)} 段；≥12 km/h {sum(1 for v in sp if v >= 12)}；max {max(sp, default=0)}；"
          f"5s 內結束 {sum(1 for x in L if x[2] is not None and x[2] <= 5000)}；沒有摘要 {sum(1 for x in L if x[2] is None)}")
    for rec, v, end in L:
        print(f"    {hm(rec['trig'])} {A(rec['u'])} rev={rec['rev']} spd={v} veh={rec['veh']} 結束 " +
              ("無摘要" if end is None else f"+{end / 1000:.1f}s"))
    return L


def sec_i(E, A, picks):
    print("\n== I tow lost／relook")
    keys = ("alive", "rmw", "phi", "od", "dt", "found", "same", "fsc", "fd", "sn", "script", "tj", "tps")  # tj／tps：1026g（門檻未標定，只列值）
    L = [er for ph in ("lost", "relook") for er in events(E, "tow", ph)]
    for e, rec in sorted(L, key=lambda er: er[0]["ts"]):
        note = " ".join(f"{k}={e[k]}" for k in keys if k in e)
        print(f"  {hm(e['ts'])} {A(rec['u'])} rev={rec['rev']} {e.get('phase')} {note}")
        picks.append((f"tow-{e.get('phase')}", e["ts"], rec, note))
    return L


def sec_j(E, A, picks):
    print("\n== J 結案檢查")
    sus = collections.defaultdict(list)
    for e, rec in events(E, "progress", "suspect"):
        sus[(rec["u"], rec["drive"])].append(e["ts"])
    ab = [(e, rec) for e, rec in events(E, "area", "start") if e.get("kind") == "behind"]
    hit = 0
    for e, rec in ab:
        n = sum(1 for t in sus[(rec["u"], rec["drive"])] if e["ts"] < t <= e["ts"] + 20000)
        hit += n > 0
        picks.append(("area-behind", e["ts"], rec, f"speed={e.get('speed')} suspect20s={n}"))
    print(f"  area start kind=behind {len(ab)}：之後 20s 同趟有 progress suspect {hit}、沒有 {len(ab) - hit}")
    g = events(E, "gate")
    print(f"  gate {len(g)}：" + ", ".join(f"{k}:{v}" for k, v in collections.Counter(f"{e.get('phase')}/{e.get('why')}" for e, _ in g).most_common()))
    for e, rec in g:
        picks.append(("gate", e["ts"], rec, f"{e.get('phase')} why={e.get('why')} d={e.get('d')}"))
    tc = [(e, rec) for e, rec in events(E, "detour") if e.get("kind") == "towcorner" and e.get("why") == "ok"]
    print(f"  detour towcorner ok {len(tc)}")
    for e, rec in tc:
        print(f"    {hm(e['ts'])} {A(rec['u'])} rev={rec['rev']} len={e.get('len')} towN={e.get('towN')} towLeft={e.get('towLeft')}")
        picks.append(("towcorner-ok", e["ts"], rec, f"len={e.get('len')} towN={e.get('towN')} towLeft={e.get('towLeft')}"))
    return dict(behind=len(ab), behind_suspect=hit, gate=len(g), towcorner_ok=len(tc))


def sec_k(S, cur):
    print("\n== K 接手結束的趟（現行 rev）依 rem")
    out = {}
    for rev in sorted(cur):
        L = [o for o in S.values() if o.get("rev") == rev and (o.get("reason") or "").replace(PFX, "") == "takeover"]
        if not L:
            continue
        rem = [o.get("rem") or 0 for o in L]
        far = [o for o in L if (o.get("rem") or 0) >= 300]
        calm = sum(1 for o in far if not any((o.get("ev") or {}).get(k) for k in ANOMALY))
        out[rev] = (len(L), calm, len(far))
        print(f"  rev={rev} {len(L)} 趟：<50m {sum(1 for r in rem if r < 50)}、50–300m {sum(1 for r in rem if 50 <= r < 300)}、"
              f"≥300m {len(far)}（ev 無異常事件 {calm}，{calm / len(far) * 100 if far else 0:.0f}%）")
    return out


def sec_m(E, C, A, S=None):
    """1026g 新鍵（現行 rev 片段；舊 rev 沒有這些鍵＝未分類／缺，不推）：engine off 機制（eng_class）；真撞擊的 tw／dms（拖車且
    dms <TOW_START_MS＝拖車起步拉緊）與 srcC（撞前最後一筆 route cutover／far 離車位最近那段＝自訂道路）；damage 依 cls 的 dmg
    中位／p90 與 dpt 前 3（small-animal 先列）；route lost why×區域；dodge commit dbs×區域×拖車（樣本有 thd＝拖車）與 NB2 型；
    blocked why=guard 的 gsl／gcs 與同趟之後第一個 takeover 片段的等待秒數。"""
    print("\n== M 1026g 新鍵（現行 rev 片段；沒有新鍵＝未分類／缺）")
    out = dict(engine=collections.Counter(eng_class(e) for e, _ in events(E, "engine", "off")))
    print("  engine off 機制 " + (", ".join(f"{k}:{v}" for k, v in out["engine"].most_common()) or "0"))
    tw, start, src = collections.Counter(), [], collections.Counter()
    for e, rec in real_impacts(E, S)[0]:
        cls = classify_impact(e, rec)[0]
        tw["缺" if "tw" not in e else "拖車" if e["tw"] else "非拖車"] += 1
        if e.get("tw") is True and isinstance(e.get("dms"), (int, float)) and e["dms"] < TOW_START_MS:
            start.append((e, rec, cls))
        rt = [x for x in rec["evs"] if x.get("n") == "route" and x.get("phase") in ("cutover", "far") and "srcC" in x
              and (x.get("ts") or 0) <= e["ts"]]
        r = edge_row(rec, e["ts"])
        f = seg_flag(max(rt, key=lambda x: x["ts"]), (r.get("x"), r.get("y"))) if rt else None
        src[(cls, {"1": "自訂", "0": "原版"}.get(f, "缺"))] += 1
    out.update(impactTw=tw, towStart=len(start), srcC=src)
    print(f"  impact tw（真撞擊）" + (", ".join(f"{k}:{v}" for k, v in tw.most_common()) or "0")
          + f"；拖車起步拉緊（tw 且 dms <{TOW_START_MS}ms）{len(start)}")
    for e, rec, cls in start:
        print(f"    {hm(e['ts'])} {A(rec['u'])} rev={rec['rev']} dms={e.get('dms')} v={e.get('speed')} dv={e.get('dv')} 歸類 {cls}")
    print("  impact 所在段 srcC（cls/自訂｜原版｜缺） " + (", ".join(f"{c}/{k}:{v}" for (c, k), v in sorted(src.items())) or "0"))
    dm = group_by([e for e, _ in events(E, "damage")], lambda e: e.get("cls") or "?")
    out["damage"] = {}
    for cls in sorted(dm, key=lambda c: (c != "small-animal", -len(dm[c]), c)):
        g = [e["dmg"] for e in dm[cls] if isinstance(e.get("dmg"), (int, float))]
        top = collections.Counter(e.get("dpt") for e in dm[cls] if e.get("dpt")).most_common(3)
        out["damage"][cls] = dict(n=len(dm[cls]), med=g and statistics.median(g), p90=g and q(g, 0.9), dpt=top)
        print(f"  damage {cls} n={len(dm[cls])} dmg 中位 " + (f"{statistics.median(g):.1f} p90 {q(g, 0.9):.1f}" if g else "—")
              + " dpt " + (", ".join(f"{k}:{v}" for k, v in top) or "—"))
    out["routeLost"] = collections.Counter((e.get("why") or "?", ev_region(e, rec)) for e, rec in events(E, "route", "lost"))
    print("  route lost why/區域 " + (", ".join(f"{w}/{g}:{v}" for (w, g), v in sorted(out["routeLost"].items())) or "0"))
    db, nb2, nodbs = collections.Counter(), collections.Counter(), 0
    for e, rec in events(E, "dodge", "commit"):
        if "dbs" not in e:
            nodbs += 1
            continue
        g = ev_region(e, rec)
        db[(g, "拖車" if edge_row(rec, e["ts"]).get("thd") is not None else "無拖車", e["dbs"])] += 1
        if e["dbs"] == "tow" and isinstance(e.get("dbl"), (int, float)) and abs(e["dbl"]) < NB2_DBL:
            nb2[g] += 1
    out.update(dbs=db, nb2=nb2)
    print("  dodge commit dbs（區域/拖車/dbs） " + (", ".join(f"{g}/{t}/{s}:{v}" for (g, t, s), v in sorted(db.items())) or "0")
          + f"；缺 dbs {nodbs}；NB2 型（dbs=tow 且 |dbl|<{NB2_DBL}） " + (", ".join(f"{g}:{v}" for g, v in sorted(nb2.items())) or "0"))
    gd, waits = [(e, rec) for e, rec in events(E, "blocked") if e.get("why") == "guard" and "gsl" in e], []
    for e, rec in gd:
        tk = [c["trig"] for c in C if c["kind"] == "takeover" and (c["u"], c["drive"]) == (rec["u"], rec["drive"]) and c["trig"] >= e["ts"]]
        if tk and isinstance(e.get("gcs"), (int, float)):
            waits.append(((min(tk) - e["ts"]) / 1000, e["gcs"]))
    gsl = [e["gsl"] for e, _ in gd if isinstance(e.get("gsl"), (int, float))]
    gcs = [e["gcs"] for e, _ in gd if isinstance(e.get("gcs"), (int, float))]
    out["guard"] = dict(n=len(gd), takeover=len(waits), early=sum(1 for w, c in waits if w < c))
    print(f"  blocked why=guard 帶 gsl {len(gd)} 件" + (f"：gsl m 中位 {statistics.median(gsl):.1f} p90 {q(gsl, 0.9):.1f}" if gsl else "")
          + (f"；gcs s 中位 {statistics.median(gcs):.1f}（帽 ≤0 缺 {len(gd) - len(gcs)}）" if gcs else "")
          + f"；之後同趟接手 {len(waits)}，等不到 gcs 就接手 {out['guard']['early']}"
          + (f"、等待/gcs 中位 {statistics.median(w / c for w, c in waits if c > 0):.2f}" if any(c > 0 for _, c in waits) else ""))
    return out


def write_anon(root, S, A):
    """摘要與片段裡的玩家全部編碼，寫 anon-users.tsv 與 clips-anon.tsv（path 一律 / 分隔）；寫完用 Anon(root) 重讀，
    有玩家沒代碼或片段沒列到就中止（2026-10-17 舊表漏 2 人、clips-anon 缺 11 段，各復盤代理自補 X##／Px1／P?? 對不起來）。"""
    files = sorted(glob.glob(os.path.join(root, "*", "clip-*.log")))
    folders = [os.path.basename(os.path.dirname(f)) for f in files]
    rows = [(A(u), f.replace("\\", "/"), AT.clip_row(f) or "") for u, f in zip(folders, files)]
    users = sorted({u for u, _ in S if u is not None})
    for u in users:
        A(u)
    with open(os.path.join(root, ANON_USERS), "w", encoding="utf-8", newline="") as fh:
        fh.write("".join(f"{c}\t{u}\n" for u, c in sorted(A.ids.items(), key=lambda x: int(x[1][1:]))))
    with open(os.path.join(root, CLIPS_ANON), "w", encoding="utf-8", newline="") as fh:
        fh.write("anon\tpath\toverview\n" + "".join("\t".join(r) + "\n" for r in rows))
    back = Anon(root)
    miss = {back.alias.get(u, u) for u in folders + users} - set(back.ids)
    with open(os.path.join(root, CLIPS_ANON), encoding="utf-8") as fh:
        listed = {ln.split("\t")[1] for ln in list(fh)[1:]}
    lost = [f for f in files if f.replace("\\", "/") not in listed]
    if miss or lost:
        raise SystemExit(f"匿名對照不完整（{root}）：{len(miss)} 位玩家沒代碼、{len(lost)} 段片段沒列進 {CLIPS_ANON}")
    print(f"匿名對照：{ANON_USERS} {len(back.ids)} 人（片段 {len(set(folders))} 人＋摘要 {len(users)} 人全有代碼）、"
          f"{CLIPS_ANON} {len(files)} 段 → {root}（含真名，只留本機）\n")


def write_picks(path, picks, A):
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write("category\ttime(+08)\tanon\trev\tkind\tveh\tpath\tnote\n")
        for cat, ts, rec, note in sorted(picks, key=lambda p: (p[0], p[1])):
            fh.write("\t".join(map(str, (cat, hm(ts), A(rec["u"]), rec["rev"], rec["kind"], rec["veh"], rec["f"], note))) + "\n")


def report(root, since_s, cur, picks_path=None, withs=()):
    since = float(since_s) * 1000
    A, picks = Anon(root), []
    S = {}
    for d in (*withs, root):                          # 摘要 8 檔輪寫、舊 build 的趟會被輪掉：先載較早的批，同 (u, drive) 以本批為準
        S.update(load_summaries(d))
    write_anon(root, S, A)
    C = load_clips(root, since)
    # 下車煞車判定要查同趟摘要：片段資料夾名是伺服器清理過的玩家名，和摘要 u 不一定相同，另以 drive 唯一時備查
    Sd = dict(S)
    byd = collections.Counter(d for _, d in S)
    for (u, d), o in S.items():
        if byd[d] == 1:
            Sd[("*", d)] = o
    Eall = dedupe([r for d in (*withs, root) for r in load_clips(d, 0)])   # A 不限窗口：各 build 有片段的撞擊都扣小動物
    cover = collections.Counter(rec["build"] for _, rec in real_impacts(Eall, Sd)[0])
    a = sec_a(S, small_impacts(Eall, Sd), cur, cover)  # 不限 rev：摘要也是全部 build
    b = sec_b(C, cur, A)
    C = [r for r in C if r["rev"] in cur]             # C–J 只看現行 rev（舊版只能排除，不拿來定罪）
    E = dedupe(C)
    res = dict(A=a, B=b, C=sec_c(E, A, picks, Sd), D=sec_d(E, A, picks), E=sec_e(C, A, picks),
               F=sec_f(E, A), G=sec_g(E, A, picks), H=sec_h(C, S, A, picks), I=sec_i(E, A, picks), J=sec_j(E, A, picks),
               K=sec_k(S, cur), L=sec_l(S, cur, C), M=sec_m(E, C, A, Sd))
    if picks_path:
        write_picks(picks_path, picks, A)
        print(f"\npicks {len(picks)} 列 → {picks_path}（含真實資料夾名，只留本機）")
    return res


# ---------- self-test ----------

def self_test():
    import contextlib
    import io
    import tempfile
    bad = []

    def check(ok, label):
        print(("  ok   " if ok else "  FAIL ") + label)
        if not ok:
            bad.append(label)

    prof = {"halfL": 2.0, "halfW": 0.8, "scriptName": "Base.Car"}
    check([t for _, _, t in nb_touch({"z": [2.5, 2.5, 1.0], "a": [2.9, 2.9, 0], "c": [1.7, 0, 1.7]}, prof)] == [True, False, False],
          "nb 貼車：|s|≤halfL+0.8 且 |l|≤halfW+0.8（邊界含）")
    lp = {"halfL": 3.3, "halfW": 1.0}
    check([t for _, _, t in nb_touch({"v": [7.2, 7.2, 0.2, 74]}, lp, 7.3, 220)] == [True]
          and [t for _, _, t in nb_touch({"v": [7.2, 7.2, 0.2, 74]}, lp)] == [False],
          "他車貼車扣掉撞後拉開的距離（P06 型：車心 7.2 m、前車 74 本車 7.3 km/h、間隔 220 ms＝貼車；沒車速資料＝不貼）")
    check(blocked_xy({"x": 0, "y": 0, "hx0": 12.5, "hy0": 3.5, "hitX": 0, "hitY": 0}) == (12.5, 3.5)
          and blocked_xy({"hitX": 0, "hitY": 0}) == (None, None) and blocked_xy({"x": 5, "y": 0}) == (5, 0)
          and blocked_xy({"hitX": 7, "hitY": 8}) == (7, 8),
          "F 熱點座標：x→hx0→hitX，(0,0) 略過（1020a 前非撞擊掃掠失敗寫 0,0）；單軸 0 照收")
    T = 1790000000000
    with tempfile.TemporaryDirectory() as d:
        def put(name, objs):
            p = os.path.join(d, name)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8", newline="") as fh:
                fh.write("".join(json.dumps(o) + "\n" for o in objs))

        def sm(u, drive, build, **kw):
            return dict(t="sum", u=u, drive=drive, build=build, rev=build[-1], dist=1000, end=drive + 60000, **kw)

        old = [sm("u%d" % i, T + i, "b-1", impact=0) for i in range(20)]
        new = [sm("u%d" % i, T + 100 + i, "b-2", impact=1 if i < 2 else 0, reason=PFX + "takeover", rem=400,
                  **({"rpt": "raw"} if i < 3 else {})) for i in range(20)]
        put("summary-1.log", old + new[:10])
        put("summary-2.log", new)                                   # new[:10] 在兩份輪寫摘要都有：去重
        put("summary-3.log", [sm("u1", T + 200, "b-3")])             # <20 趟的 build 不列

        def clip(u, slot, kind, trig, rows, evs, rev="2", drive=T):
            put(f"{u}/clip-{slot:02d}.log", [dict(t="clip", kind=kind, trig=trig, drive=drive, at={"fbw": "blocked", "spd": 14}),
                                            dict(t="h", rev=rev, build="b-2", drive=drive, opts="detour=false", profile=prof),
                                            dict(t="e", ts=trig - 30000, n="route", src=[1])]
                 + [dict(t="s", ts=trig - 100 * k, ctl="TRACK", x=0, y=0, **r) for k, r in rows]
                 + [dict(t="e", **e) for e in evs])

        base = [(k, {}) for k in range(40, 0, -1)]
        clip("pa", 1, "impact", T + 50000, base + [(0, {"nb": {"z": [1.0, 1.0, 0.5]}})],
             [dict(ts=T + 50000, n="impact", speed=40)])
        clip("pb", 1, "contact", T + 50000, base + [(0, {"nb": {"z": [1.0, 1.0, 0.5]}})],   # pb 同 ts 不同玩家：另算一件
             [dict(ts=T + 50000, n="impact", speed=40)])
        clip("pa", 2, "impact", T + 60000, base + [(0, {"nb": {"v": [6.0, 6.0, 0]}})],
             [dict(ts=T + 60000, n="impact", speed=40), dict(ts=T + 50000, n="impact", speed=40)])  # 第二筆＝pa/clip-01 那件重複
        clip("pa", 3, "impact", T + 70000, [(k, {"dg": k < 5}) for k in range(40, 0, -1)] + [(0, {"nb": {}})],
             [dict(ts=T + 70000, n="impact", speed=40, scost="tree")])
        clip("pa", 4, "takeover", T + 80000, base, [dict(ts=T + 77000, n="blocked", why="plan", x=5010, y=7010),
                                                    dict(ts=T + 78000, n="unstick", phase="start"),
                                                    dict(ts=T + 79000, n="blocked", why="wide", x=0, y=0)])  # 秒數從首筆算
        clip("pb", 2, "takeover", T + 90000, base, [dict(ts=T + 79000, n="blocked", why="plan", x=5020, y=7020)])  # 11s 前：不算
        clip("pc", 1, "brake", T + 95000, base, [dict(ts=T + 94000, n="blocked", why="guard", x=5015, y=7010),
                                                 dict(ts=T + 94500, n="blocked", why="guard", x=5030, y=7010)])  # 隔壁格
        clip("pd", 1, "takeover", T + 100000, base, [dict(ts=T + 100080, n="blocked", why="guard", x=100, y=100)])  # 觸發後 80ms
        clip("pe", 1, "takeover", T + 100000, base, [dict(ts=T + 99000, n="blocked", why="plan", x=5010, y=7010)], rev="1")  # 舊 rev
        clip("pa", 9, "impact", T - 10 ** 7, base, [])                # 窗口外
        # 1013f 小動物：貼車的動物 a 體重 <20 kg＝small-animal（剛死的帶第 6 項 1）；20 kg 整、讀不到體重（1010 前格式）＝animal。
        # u0／u1 是摘要 b-2 有 impact 的兩趟：A 的「不含小動物」扣掉它們（u1 那段是舊 rev，A 不限 rev、C 只算現行 rev）
        def ani(u, drive, a, rev="2"):
            clip(u, 1, "impact", T + 110000, base + [(0, {"nb": {"a": a}})], [dict(ts=T + 110000, n="impact", speed=30)],
                 rev=rev, drive=drive)
        ani("u0", T + 100, [1.0, 1.0, 0.3, "hen", 2.4, 1])
        ani("u1", T + 101, [1.2, 1.1, -0.2, "chick", 0.3, 1], rev="1")
        ani("u5", T + 105, [1.5, 1.5, 0.2, "cow", 600])
        ani("u6", T + 106, [1.5, 1.5, 0.2, "lamb", 20])
        ani("u7", T + 107, [1.5, 1.5, 0.2])
        ani("u8", T + 108, [6.0, 6.0, 0.2, "hen", 2.4, 1])             # 小動物沒貼車＝far
        # 1017：不算撞擊（事件 cls≠hit；1017 前片段用樣本推）、同趟 2s 內只算一件、他車用兩車半長、contact sprite 優先
        zb = base + [(0, {"nb": {"z": [1.0, 1.0, 0.5]}})]
        t1 = T + 120000
        clip("x1", 1, "impact", t1, zb, [dict(ts=t1, n="impact", speed=60, cls="frozen")])
        clip("x2", 1, "impact", t1, zb, [dict(ts=t1, n="impact", speed=30, cls="rehitch", m="follow", rhMs=300)])
        clip("x3", 1, "impact", t1, base + [(0, {"m": "rehitch", "nb": {"z": [1.0, 1.0, 0.5]}})],
             [dict(ts=t1, n="impact", speed=30)])                                        # 1015c 舊格式：樣本 m=rehitch
        clip("x4", 1, "impact", t1, zb, [dict(ts=t1 - 1000, n="tow", phase="rh-attach"), dict(ts=t1, n="impact", speed=30)])
        clip("x5", 1, "impact", t1, base + [(0, {"tn": 0, "fbl": 0, "nb": {"z": [1.0, 1.0, 0.5]}})],
             [dict(ts=t1, n="impact", speed=50)], drive=T + 500)                         # 1.0 s 後以 exit 結束
        clip("x6", 1, "impact", t1, base + [(10, {"nb": {"z": [1.0, 1.0, 0.5]}}), (0, {"nb": {"z": [1.0, 1.0, 0.5]}})],
             [dict(ts=t1 - 1000, n="impact", speed=40), dict(ts=t1, n="impact", speed=20)])
        clip("x7", 1, "impact", t1, base + [(0, {"nb": {"v": [4.0, 4.0, 0.3, 70]}})], [dict(ts=t1, n="impact", speed=70)])
        clip("x8", 1, "impact", t1, base + [(0, {"nb": {}})],
             [dict(ts=t1 - 1000, n="contact", sprite=None, scost="vehicle"), dict(ts=t1, n="impact", speed=50, scost="hard",
                                                                                   sprite="lighting_outdoor_01_16")])
        clip("x9", 1, "impact", t1, base + [(0, {"nb": {}})],
             [dict(ts=t1 - 800, n="contact", sprite="vegetation_trees_01_8", scost="tree"),
              dict(ts=t1, n="impact", speed=50, sprite="lighting_outdoor_01_16", scost="hard")])
        put("summary-4.log", [dict(t="sum", u="x5", drive=T + 500, build="b-9", rev="2", dist=1000, end=t1 + 1000, reason="exit",
                                   impact=0, rhi=1, xbk=1, vfIn=2, vfInX=1, exN=3, exDev=1, exN50=2, exDev50=1,
                                   aoi=[[t1, 60, 40, 50, 3.5, "curve", 6.2, 1, 120]], fu0=50, fu1=48.5,
                                   fuS={"arc": [0.5, 0.2], "oth": [1.0, 0.8]}, t40=3200, t40k="tow",
                                   blr={"unloaded": 2}, eng={"why": "battery", "chg": 0, "es": 2400, "fu": 48.5})])
        clip("p q", 1, "route", T + 130000, base, [])                  # 資料夾名有空白（2026-10-17 舊 clips-anon 漏掉這種）
        with open(os.path.join(d, ANON_USERS), "w", encoding="utf-8", newline="") as fh:
            fh.write("P05\tpa\n")                                     # 上一輪的表：沿用、新玩家從 P06 接續
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            res = report(d, T / 1000, {"2"}, os.path.join(d, "picks.tsv"))
        a = res["A"]
        check(set(a) == {"b-1", "b-2"} and a["b-2"]["trips"] == 20 and a["b-2"]["impact"] == 2 and a["b-2"]["km"] == 20,
              "摘要 (u, drive) 去重、依 build 分組、<20 趟不列")
        check(a["b-2"]["impactNoSmall"] == 0 and a["b-1"]["impactNoSmall"] == 0,
              "A impact 不含小動物：扣掉同 (u, drive) 的 small-animal 片段撞擊（不限 rev）")
        check(any("impact 不含小動物 0=0.0/千km" in ln and "扣 small-animal 2" in ln for ln in out.getvalue().splitlines()),
              "A 印出不含小動物的 impact／千 km 與扣掉的件數")
        check(res["B"]["clips"] == 25, "窗口：trig < since 的片段不算")
        check(a["b-2"]["rpt"] == {"raw": 3, "unknown": 17} and any("RoadPatch rpt unknown:17, raw:3" in ln
                                                                     for ln in out.getvalue().splitlines()),
              "A RoadPatch rpt 計數（缺＝unknown）")
        back = Anon(d)
        files = glob.glob(os.path.join(d, "*", "clip-*.log"))
        users = {u for u, _ in load_summaries(d)} | {os.path.basename(os.path.dirname(f)) for f in files}
        check(back.ids.get("pa") == "P05" and set(back.ids) == users
              and sorted(int(c[1:]) for c in back.ids.values()) == list(range(5, 5 + len(users))),
              "anon-users.tsv：摘要＋片段全部玩家，沿用舊碼、新碼從最大號接續不重複")
        with open(os.path.join(d, CLIPS_ANON), encoding="utf-8") as fh:
            paths = [ln.split("\t")[1] for ln in list(fh)[1:]]
        check(len(paths) == len(files) and any(p.endswith("/p q/clip-01.log") for p in paths) and not any("\\" in p for p in paths),
              "clips-anon.tsv 列全部片段（含空白資料夾名），路徑一律 /")
        tr = trips(load_clips(d, T))[("pa", T)]
        check(len(tr["clips"]) == 4 and sum(1 for e in tr["evs"] if e.get("n") == "impact" and e["ts"] == T + 50000) == 1
              and [r["ts"] for r in tr["rows"]] == sorted({r["ts"] for c in tr["clips"] for r in c["rows"]}),
              "trips：同趟多片段合併，事件 (ts, n, phase) 去重、樣本依 ts 去重排序")
        check(res["C"] == {"zombie": 3, "far": 2, "static": 2, "small-animal": 1, "animal": 3, "vehicle": 2,
                           "skip-frozen": 1, "skip-rehitch": 3, "skip-exit": 1, "skip-rearm": 1},
              "撞擊 (u, drive, ts) 去重、類別 zombie／far／static；<20 kg 貼車動物＝small-animal，20 kg 整／缺體重／舊 rev／沒貼車不算；"
              "1017：cls frozen／rehitch、樣本 m=rehitch、rh-attach 後 1 s、exit 前 1 s 且 tn 0＝不算，同趟 1 s 內第二件不算，"
              "他車 s 4.0 在兩車半長內＝vehicle，contact 撞他車輪廓＝vehicle、contact 樹＝static（" + str(dict(res["C"])) + "）")
        check("lighting_outdoor_01_16" not in [ln for ln in open(os.path.join(d, "picks.tsv"), encoding="utf-8")
                                                if "vegetation_trees_01_8" in ln][0], "static 用 contact 事件的 sprite，不用車頭 3 格")
        L = res["L"]
        check(L["trips"] == 1 and L["rhi"] == 1 and L["xbk"] == 1 and L["vfIn"] == 2 and L["vfInX"] == 1 and L["aoi"] == 1
              and L["exN50"] == 2 and L["fuel"] == {"arc": [0.5, 0.2], "oth": [1.0, 0.8]} and L["t40"] == {"tow": 3200}
              and L["blr"] == {"unloaded": 2} and L["eng"] == {"battery": 1}, "L 1017 摘要新欄位彙整（" + str(L) + "）")
        check("fuelE" not in L and L["engLow"] == (0, 0) and L["fuelA"]["全部"]["verdict"] == "樣本不足",
              "L 舊摘要（沒有 fuE、eng 沒有 ecd）不出每分鐘扣量與引擎狀況；片段沒有 fu＝油量判準樣本不足")
        # 1020 摘要 fuT／fuE：每分鐘扣量只算有 fuE 的趟（舊格式沒 fuE 的不算）；段比判準已拿掉（到達歸段沒有鑑別力）。
        def fs(u, drive, fuS, fuT=None, fuE=None, eng=None):
            o = dict(t="sum", u=u, drive=drive, rev="2", rhi=0, fu0=50, fu1=40, fuS=fuS)
            o.update({k: v for k, v in (("fuT", fuT), ("fuE", fuE), ("eng", eng)) if v is not None})
            return o
        A = dict(fuS={"arc": [1.0, 0.2], "oth": [1.0, 1.0]}, fuT={"arc": 60000, "oth": 120000},
                 fuE={"arc": [200, 100], "oth": [100, 100]})
        B = dict(fuS={"arc": [5.0, 0.2], "oth": [15.0, 1.0]}, fuT={"arc": 60000, "oth": 60000},
                 fuE={"arc": [400, 100], "oth": [100, 300]})
        SF = [fs("f1", 1, **A), fs("f2", 2, **B), fs("f3", 3, **A), fs("f4", 4, {"arc": [9.0, 0.1]}),
              fs("f5", 5, {}, None, {"oth": [10, 10]}, {"why": "engine", "ecd": 38, "eq": 60})]
        with contextlib.redirect_stdout(io.StringIO()):
            LE = sec_l({(o["u"], o["drive"]): o for o in SF}, {"2"})
        LF = LE["fuelE"]
        check(LF["trips"] == 4 and LF["users"] == 4 and set(LF) == {"trips", "users", "perMin"},
              "L 每分鐘扣量只算有 fuE 的趟，不再輸出段比 ratio／seg（" + str(LF) + "）")
        check(LF["perMin"] == {"arc": round(7 / 3, 3), "oth": round(17 / 5, 3)}, "L 每分鐘扣量＝fuS 實扣 ÷ fuT 分鐘（只算有 fuE 的趟）")
        check(LE["engLow"] == (1, 1), "L eng ecd <50 計數")
        # 油量換算判準（片段同步區間積分）：合成片段，油箱照 truth（fair＝換算檔、held＝實際檔）的原版公式扣，
        # 累積下降 ≥0.02% 才同步一次（樣本 fu 只在同步時變）。換算有作用＝α 1 過；沒作用＝α 0 不過；不到 5 人＝樣本不足。
        def fuel_clips(truth, users, seed=3):
            rnd, C = random.Random(seed), []
            fprof = {"scriptName": "Base.F", "maxSpeed": 150, "mass": 1300}   # 5 檔、每檔 30 km/h、車重倍率 2
            for i in range(users):
                rows, tank, shown, ts = [], 40.0, 40.0, T
                while ts < T + 120000:
                    v = rnd.choice((30, 55, 80, 120))
                    end = ts + rnd.uniform(2000, 10000)
                    while ts < end:
                        g = 5 if v >= 120 else 4
                        rows.append(dict(t="s", ts=ts, spd=v, tn=g, es=2500, fu=shown))
                        fg = min(5, v // 30 + 1)
                        rate = gas_term(g if truth == "held" or g <= fg else fg, v, 30) * 2
                        tank -= rate * 0.05 / 38640 * 0.25
                        if shown - tank >= 0.02:
                            shown = tank
                        ts += 250
                C.append(dict(u="g%d" % i, drive=T + i, rev="ab"[i % 2], prof=fprof, rows=rows, evs=[]))
            return C
        with contextlib.redirect_stdout(io.StringIO()):
            fa, fh, fn = (fuel_check(fuel_clips(t, n)) for t, n in (("fair", 10), ("held", 10), ("fair", 4)))
        check(fa["全部"]["alpha"][0] == 1.0 and fa["全部"]["verdict"] == "過" and fa["a"]["verdict"] == "過"
              and fa["b"]["users"] == 5 and fa["全部"]["n"] >= 30,
              "L 油量判準：油照換算檔扣＝α 1、全部與各 rev 都過（" + str(fa["全部"]) + "）")
        check(fh["全部"]["alpha"][2] <= 0.1 and fh["全部"]["verdict"] == "不過",
              "L 油量判準：油照實際檔扣（換算沒作用）＝α≈0、不過（" + str(fh["全部"]) + "）")
        check(fn["全部"]["verdict"] == "樣本不足" and fn["全部"]["alpha"] is None, "L 油量判準：不到 5 人＝樣本不足、不判")
        check([fuel_verdict(r) for r in ((0.95, 0.95, 1.0), (0.85, 0.6, 1.0), (0.5, 0.3, 0.85), None)]
              == ["過", "不確定", "不過", "樣本不足"],
              "L 油量判定：下限 ≥0.9 過、區間跨 0.9 不確定（1020 批 1018a 型：0.85，0.60–1.00）、上限 <0.9 不過")
        man = [ln for ln in out.getvalue().splitlines() if ln.strip().startswith("static")]
        check(man and "maneuver 1" in man[0], "前 2.5s 有 dg＝maneuver")
        e = res["E"]
        check([(o["rec"]["u"], o["dt"], o["un"]) for o in e] == [("pa", 3, 1), ("pd", -0.08, 0)],
              "判堵後接手：10s 內（含觸發後 ≤500ms）、秒數與其間 unstick start；舊 rev 不算")
        top = res["F"]
        check(top[0][0] == (200, 280) and len(top[0][1]["u"]) == 3 and top[0][1]["n"] == 3, "熱點 25m 格聚合三位玩家")
        check(res["K"] == {"2": (20, 20, 20)}, "接手結束 rem ≥300 且 ev 無異常")
        check(res["L"]["engClass"] == {"未分類": 1} and res["L"]["vf"] == {"?": dict(km=1.0, oldTrips=1, vfIn=2, vfInDedup=0, vfInX=1, fbVM=0)}
              and res["L"]["vh"] == {} and not res["M"]["engine"] and set(res["M"]["impactTw"]) == {"缺"}
              and set(k for _, k in res["M"]["srcC"]) == {"缺"} and not res["M"]["damage"] and not res["M"]["dbs"]
              and res["M"]["guard"]["n"] == 0,
              "1026g 新鍵：舊 rev 片段／摘要一律未分類／缺（沒有 vfW 走 vfIn、沒有 vhN 不列、impact 沒 tw＝缺、src 不是字串＝缺）")
        tsv = open(os.path.join(d, "picks.tsv"), encoding="utf-8").read()
        check("pa/clip-04.log" in tsv and "pa/" not in out.getvalue() and "pb" not in out.getvalue(), "picks 有路徑、stdout 不含玩家名")
        dold = os.path.join(d, "_old")                                 # 較早的一批：只有摘要（同 (u, drive) 的那趟以本批為準）
        put("_old/summary-1.log", [sm("o%d" % i, T - 10 ** 6 + i, "b-0", impact=0) for i in range(20)]
            + [sm("u0", T + 100, "b-2", impact=5)])
        with contextlib.redirect_stdout(io.StringIO()):
            a2 = report(d, T / 1000, {"2"}, None, [dold])["A"]
        check(a2.get("b-0", {}).get("trips") == 20 and a2["b-2"]["impact"] == 2,
              "--with 併入較早一批的摘要（多出 b-0）；同 (u, drive) 以本批為準（b-2 impact 仍 2）")
    one = [dict(u="a0", dist=1000, impact=1) for _ in range(20)] + [dict(u="a%d" % i, dist=1000, impact=0) for i in range(1, 20)]
    two = [dict(u="b%d" % i, dist=1000, impact=1 if i < 2 else 0) for i in range(20)]
    r = boot_ratio(one, two, lambda o: o["impact"])
    check(binom_p(20, 2, 39, 20) < 0.05 and r[1] < 1 < r[2],
          f"boot_ratio 以玩家重抽：20 件全是同一人的 20 趟時 Poisson p<0.05、玩家叢集區間仍含 1（{r}）")
    S2 = {("u%d" % i, i): dict(u="u%d" % i, drive=i, build="b-7" if i < 20 else "b-8", rev="x", dist=1000, impact=int(i % 7 == 0))
          for i in range(40)}
    out2 = io.StringIO()
    with contextlib.redirect_stdout(out2):
        sec_a(S2, {}, {"x"})
    check("同碼 A/A（--current 駕駛相同）b-7 vs b-8" in out2.getvalue() and "同碼 A/A（--current" not in out.getvalue(),
          "A：--current 內有兩個以上 build 才印同碼 A/A 率比")
    with tempfile.TemporaryDirectory() as par:
        for sub in ("old", "new"):
            os.makedirs(os.path.join(par, sub))
        with open(os.path.join(par, "old", ANON_USERS), "w", encoding="utf-8", newline="") as fh:
            fh.write("P07\tzz\n")
        an = Anon(os.path.join(par, "new"))
        check(an("zz") == "P07" and an("yy") == "P08", "新一批還沒有 anon-users.tsv：沿用同層最新一批的表，代碼不重編")
    # 1026g 新鍵（Telemetry.md §4）：區域（lotheader cell）、EngineOff 機制、V5、他車首見、impact tw／dms／srcC、damage、route lost、
    # dodge dbs、guard gsl／gcs、tow lost tj／tps。
    check([region(6377.9, 5283.5), region(4462.6, 2809.6), region(4000, 7000), region(6500, 11000), region(9 * 256 + 10, 14 * 256 + 10),
           region(None, 1)] == ["old", "Dirkerdam", "BigBearLake", "NewHartburg", "old", None],
          "區域＝新圖 lotheader cell：Riverside 原版格 (24,20) 在德克丹 bounds 內但算 old、德克丹 (9,14) 空洞算 old、沒座標 None")
    DK, OL = dict(x=4462.6, y=2809.6), dict(x=10760, y=9771)
    check([trip_region(dict(x0=DK["x"], y0=DK["y"], x1=OL["x"], y1=OL["y"])), trip_region(dict(x0=DK["x"], y0=DK["y"])),
           trip_region(dict(x0=4000, y0=7000, x1=DK["x"], y1=DK["y"])), trip_region({})] == ["mixed", "Dirkerdam", "mixed", "?"],
          "摘要區域：一新一舊／兩張新圖＝mixed、只有起點照起點、沒座標＝?")
    check([eng_class(x) for x in ({"why": "engine", "ecd": 30}, {"est": "ShuttingDown", "kso": 209, "erm": 16933},
                                  {"est": "Stalling", "kso": 1999}, {"est": "Stalling", "kso": 5000}, {"est": "Idle", "erm": 1500},
                                  {"est": "Idle", "kso": 2000, "erm": 3000}, None)]
          == ["未分類", "玩家關引擎", "玩家關引擎", "熄火或沒油", "剛發動就熄", "其他（est=Idle）", "未分類"],
          "EngineOff 機制：kso <2000 先判玩家關引擎、Stalling＝熄火或沒油、erm <3000＝剛發動就熄、門檻值本身不中、舊 rev 未分類")
    check(vf_dedupe([dict(u="a", vfInTs=[7999, 0, 400, 8000, 20000]), dict(u="b", vfInTs=[0]), dict(u="a", vfInTs=None)]) == 4,
          "vfInTs 同玩家 8 s 窗去重：0／400／7999 一件、8000 起新窗、不同玩家各算")
    sg = dict(src="0,0;10,0;10,10", srcC="0;1")
    check([seg_flag(sg, (10.5, 5)), seg_flag(sg, (5, 0.2)), seg_flag(dict(src=sg["src"]), (5, 0)), seg_flag(dict(sg, srcC="0"), (10.5, 5)),
           seg_flag(dict(src="0,0;10,0;10,", srcC="0;1"), (10.5, 5)), seg_flag(dict(src=[1], srcC="1"), (0, 0)), seg_flag(sg, (None, None))]
          == ["1", "0", None, None, "0", None, None],
          "srcC 取離車位最近那段：第 2 段＝1、第 1 段＝0；沒 srcC、該段被截掉、src 不是字串、沒車位＝None；截斷的尾點不用")
    T6 = 1792900000000
    old_xy, dk_xy = dict(x0=10760, y0=9771, x1=10750, y1=9700), dict(x0=DK["x"], y0=DK["y"], x1=DK["x"] + 50, y1=DK["y"])
    SV = [dict(u="v1", drive=1, rev="2", rhi=0, dist=2000, vfIn=2, vfInX=1, vfW=2, vfWX=1, vfXk={"c": 1, "vb": 3, "va": 1},
               vfWs=[[T6, 50, 72], [T6 + 9000, 40, 60]], vhN=2, vhMin=12.0, vhLt=1, eng={"why": "engine", "est": "Stalling"}, **old_xy),
          dict(u="v2", drive=2, rev="2", rhi=0, dist=1000, vfIn=1, vfW=1, vfWX=0, vfXk={}, vfWs=[[T6, 45, 80]], vhN=1, vhMin=30.0,
               vhLt=0, **dk_xy),
          dict(u="v3", drive=3, rev="2", rhi=0, dist=1000, vfIn=3, vfInX=2, vfInTs=[T6, T6 + 400, T6 + 9000],
               fb={"visibility": 1, "moving": 1, "blocked": 4}, eng={"why": "engine"}, **old_xy)]
    with contextlib.redirect_stdout(io.StringIO()):
        LV = sec_l({(o["u"], o["drive"]): o for o in SV}, {"2"})
    check(LV["vf"] == {"old": dict(km=3.0, trips=1, vfW=2, vfWX=1, xk={"c": 1, "vb": 3, "va": 1}, fast=1, ws=2,
                                   oldTrips=1, vfIn=3, vfInDedup=2, vfInX=2, fbVM=2),
                       "Dirkerdam": dict(km=1.0, trips=1, vfW=1, vfWX=0, xk={}, fast=1, ws=1)},
          "V5：1026g 用 vfW／vfWX（vb／va 只參考、不加進失敗）、vfWs ≥70 km/h；舊 rev 同玩家 8 s 去重；新舊區分開（" + str(LV["vf"]) + "）")
    check(LV["vh"] == {"old": dict(trips=1, vhN=2, vhLt=1, vhMin=12.0), "Dirkerdam": dict(trips=1, vhN=1, vhLt=0, vhMin=30.0)}
          and LV["engClass"] == {"熄火或沒油": 1, "未分類": 1},
          "他車首見依區域（沒有 vhN 的舊 rev 不列）；L EngineOff 機制計數")
    mp = {"halfL": 2.0, "halfW": 0.8, "scriptName": "Base.Car"}

    def rc(u, kind, trig, rows, evs, drive=T6):
        return dict(u=u, drive=drive, kind=kind, trig=trig, rev="2", build="b", veh="Car", prof=mp, opts={}, at={},
                    f=u + "/clip-01.log", src=True, rows=sorted(rows, key=lambda r: r["ts"]), evs=evs)

    def rw(t, n=50, **kw):
        return [dict(t="s", ts=t - 100 * k, **kw) for k in range(n, -1, -1)]
    t = T6 + 60000
    route = dict(t="e", ts=t - 5000, n="route", phase="cutover", src="0,0;10,0;10,10", srcC="1;0")
    zb = {"nb": {"z": [1.0, 1.0, 0.5]}}
    CM = [rc("m1", "impact", t, rw(t, x=5, y=0.5, thd=0.1, **zb),
             [route, dict(t="e", ts=t, n="impact", speed=18, dv=8, tw=True, dms=1200),
              dict(t="e", ts=t + 1500, n="damage", cls="small-animal", dmg=2, dpt="TireFrontLeft"),
              dict(t="e", ts=t - 3000, n="dodge", phase="commit", dbs="tow", dbl=0.2),
              dict(t="e", ts=t - 2000, n="engine", phase="off", why="engine", est="Stalling", kso=9000)]),
          rc("m2", "impact", t, rw(t, x=10.5, y=5),
             [route, dict(t="e", ts=t, n="impact", speed=30, tw=False, dms=500),
              dict(t="e", ts=t - 3000, n="dodge", phase="commit", dbs="tow", dbl=2),
              dict(t="e", ts=t - 2500, n="dodge", phase="commit"),
              dict(t="e", ts=t - 2000, n="engine", phase="off", why="engine")]),
          rc("m3", "impact", t, rw(t, x=5, y=0), [dict(route, srcC=None), dict(t="e", ts=t, n="impact", speed=30)]),
          rc("m4", "impact", t, rw(t, x=5, y=0, **zb), [dict(t="e", ts=t, n="impact", speed=20, tw=True, dms=2000)]),
          rc("m5", "route", t, rw(t, **DK),
             [dict(t="e", ts=t - 3000, n="route", phase="lost", why="noroad", x=DK["x"], y=DK["y"]),
              dict(t="e", ts=t - 2000, n="route", phase="lost", why="notarget", **OL),
              dict(t="e", ts=t - 1000, n="route", phase="lost", why="noroad")]
             + [dict(t="e", ts=t - 900 + i, n="damage", cls="zombie", dmg=v, dpt=p)
                for i, (v, p) in enumerate(((5, "EngineDoor"), (15, "EngineDoor"), (25, "HeadlightLeft"), (35, "EngineDoor")))]
             + [dict(t="e", ts=t - 400, n="damage", cls="vehicle")]),
          rc("m6", "brake", t, rw(t, **OL), [dict(t="e", ts=t, n="blocked", why="guard", gsl=12.0, gcs=3.0),
                                             dict(t="e", ts=t + 10, n="blocked", why="plan", gsl=1.0, gcs=9.0),
                                             dict(t="e", ts=t + 20, n="blocked", why="guard", **OL)]),
          rc("m6", "takeover", t + 2000, rw(t + 2000, **OL), []),
          rc("m7", "brake", t, rw(t, **OL), [dict(t="e", ts=t, n="blocked", why="guard", gsl=5.0)])]
    with contextlib.redirect_stdout(io.StringIO()) as mo:
        M = sec_m(dedupe(CM), CM, Anon(), {})
    check(M["engine"] == {"熄火或沒油": 1, "未分類": 1}, "M engine off 機制（事件）：est=Stalling、舊格式未分類")
    check(M["impactTw"] == {"拖車": 2, "非拖車": 1, "缺": 1} and M["towStart"] == 1
          and any("dms=1200" in ln for ln in mo.getvalue().splitlines()) and "dms=2000" not in mo.getvalue(),
          "M impact tw：拖車且 dms <2000＝拖車起步拉緊（1200 中、2000 整與非拖車 500 不中、沒 tw＝缺）")
    check(M["srcC"] == {("zombie", "自訂"): 1, ("empty", "原版"): 1, ("empty", "缺"): 1, ("zombie", "缺"): 1},
          "M srcC：撞前最後一筆 route 離車位最近那段（第 1 段 1＝自訂、第 2 段 0＝原版）；srcC 空或沒有 route＝缺（" + str(M["srcC"]) + "）")
    check(list(M["damage"]) == ["small-animal", "zombie", "vehicle"] and M["damage"]["zombie"]["med"] == 20
          and abs(M["damage"]["zombie"]["p90"] - 32) < 1e-9 and M["damage"]["zombie"]["dpt"][0] == ("EngineDoor", 3)
          and M["damage"]["small-animal"]["n"] == 1 and M["damage"]["vehicle"]["med"] == [],
          "M damage：small-animal 先列、依 cls 的 dmg 中位／p90 與 dpt 前 3；沒 dmg 不算進中位")
    check(M["routeLost"] == {("noroad", "Dirkerdam"): 2, ("notarget", "old"): 1},
          "M route lost why×區域（事件沒 x,y 用當下樣本座標）")
    check(M["dbs"] == {("old", "拖車", "tow"): 1, ("old", "無拖車", "tow"): 1} and M["nb2"] == {"old": 1}
          and "缺 dbs 1" in mo.getvalue(),
          "M dodge dbs×區域×拖車（樣本有 thd＝拖車）；NB2 型只算 dbs=tow 且 |dbl|<0.5；沒 dbs 另計")
    check(M["guard"] == dict(n=2, takeover=1, early=1),
          "M guard：只算 why=guard 且帶 gsl；之後同趟 takeover 2 s < gcs 3 s＝等不到爬完就接手；gcs 缺不比")
    tl = [rc("t1", "tow", t, rw(t), [dict(t="e", ts=t, n="tow", phase="lost", alive=True, tj=0.9, tps=300),
                                     dict(t="e", ts=t + 1, n="tow", phase="lost", alive=False)])]
    with contextlib.redirect_stdout(io.StringIO()) as io_:
        sec_i(dedupe(tl), Anon(), [])
    il = [ln for ln in io_.getvalue().splitlines() if "alive=" in ln]
    check(len(il) == 2 and "alive=True tj=0.9 tps=300" in il[0] and "tj=" not in il[1], "I tow lost 列 tj／tps 值（沒有就不印）")
    print(f"self-test：{len(bad)} 項失敗")
    return 1 if bad else 0


def main(argv):
    if argv == ["--self-test"]:
        return self_test()
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root")
    ap.add_argument("since", type=float, help="窗口起點 epoch 秒（片段 trig ≥ since）")
    ap.add_argument("--current", default="1010a,1010c", help="駕駛行為與 HEAD 相同的 rev，逗號分隔")
    ap.add_argument("--picks", help="輸出片段清單 TSV（含真實資料夾名，只留本機）")
    ap.add_argument("--with", dest="withs", action="append", default=[], help="較早的 pull 目錄（可重複）：A 節併入它們的摘要與片段")
    a = ap.parse_args(argv)
    report(a.root, a.since, set(a.current.split(",")), a.picks, a.withs)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
