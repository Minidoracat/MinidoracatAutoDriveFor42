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
    1020 起（摘要有 fuT／fuE）另印各段每分鐘扣量、實扣÷原版公式期望（held＝實際檔、fair＝伺服器換算檔），與油量判準
    (彎道＋繞行)/其他 的實扣÷期望比＋玩家叢集 95%（boot_players；fair 區間含 1＝換算在作用）
  D contact ≥10 km/h（現行 rev）：scost、弧上（前 2.5s curveHardActive）、前 2.5s |ld|>0.5、lag 帽（capReason=lag）、主導 ctl、sprite 家族
  E 判堵後接手：takeover 片段觸發前 10s 內有 blocked；窗口內首筆 blocked→接手秒數、其間 unstick start、detour=false、最後一筆 why／shape
  F 判堵熱點：blocked x,y 的 25m 格（玩家、趟、事件、車型）
  G 起步調頭 uturn done：依 start（1012 起步段原地轉，出場 30°）× probe 分組（aligned ms、stop 的 detail）；room＝倒車騰空間判定
  H 判堵鎖輪 brake 片段（at.fbw=blocked）：鎖輪速度、該趟是否 5s 內結束（摘要 end）
  I tow lost／relook
  J 結案檢查：area start kind=behind 後 20s 同趟 progress suspect；gate phase／why；detour kind=towcorner why=ok
  K 接手結束的趟（現行 rev）依 rem 分桶；≥300m 的趟 ev 沒有異常事件（blocked／uturn／unstick／contact／impact／progress）的數量
  分析用 helper（`import upload_report as UR`）：Anon(root)、hm、q、ci、binom_p、boot_ratio、boot_players、fuel_model、opts_of、
    is_tow、per_em、load_summaries、load_clips（since 省略＝pull.json）、dedupe、trips、events、window、edge_row、classify_impact、
    real_impacts
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


FUEL_HI = ("arc", "dodge")   # 油量判準的「彎道＋繞行」段


def fuel_model(L, mi):
    """1020 摘要 fuS（實扣 %）與 fuE（原版 GasTank 期望，[held, fair]）→ (段比, {段: [實扣, 正規化期望]})。mi 0＝held、1＝fair。
    每趟期望以該趟實扣總量正規化（消掉油箱、引擎品質、耗油沙盒值、遊戲時間倍率）；段比＝(arc+dodge) 實扣÷期望 對其他段，
    1＝和模型一致。沒有 fuE 或實扣 0 的趟不算；段比缺分母回 None。fu 是伺服器同步值、落在值到達那一筆的段：弧上的油有一部分記到 post。"""
    seg = collections.defaultdict(lambda: [0.0, 0.0])
    for o in L:
        fs, fe = o.get("fuS") or {}, o.get("fuE") or {}
        tot_o = sum(((fs.get(s) or [0])[0] or 0) for s in fe)
        tot_e = sum(v[mi] or 0 for v in fe.values())
        if tot_o <= 0 or tot_e <= 0:
            continue
        k = tot_o / tot_e
        for s, v in fe.items():
            seg[s][0] += (fs.get(s) or [0])[0] or 0
            seg[s][1] += (v[mi] or 0) * k
    o1, e1 = (sum(seg[s][i] for s in seg if s in FUEL_HI) for i in (0, 1))
    o2, e2 = (sum(seg[s][i] for s in seg if s not in FUEL_HI) for i in (0, 1))
    return ((o1 / e1) / (o2 / e2) if e1 and e2 and o2 else None), dict(seg)


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


def sec_l(S, cur):
    """1017 摘要新欄位（只算帶 rhi 的摘要＝rev ≥1017f）：假撞另計、路中停車首見、入彎超速明細、出彎偏差、油量、起步、
    煞車學習拒收、EngineOff 關卡。"""
    print("\n== L 1017 摘要新欄位（rev 有 rhi 欄的趟）")
    L = [o for o in S.values() if "rhi" in o and (not cur or o.get("rev") in cur)]
    out = dict(trips=len(L))
    if not L:
        print("  （沒有）")
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
        print(f"  油量 {len(fu)} 趟：起訖差 {sum(o['fu0'] - o['fu1'] for o in fu):.2f}%；分段 %/km "
              + ", ".join(f"{k}:{d / m if m else 0:.2f}({m:.1f}km)" for k, (d, m) in sorted(seg.items())))
    # 1020 油量判準：實扣÷原版公式期望（fair＝伺服器換算後；held＝沒換算），(彎道＋繞行)/其他 的玩家叢集 95% 區間含 1＝換算在作用
    fe = [o for o in fu if o.get("fuE")]
    if fe:
        tm, dr = collections.Counter(), collections.Counter()
        for o in fe:
            tm.update(o.get("fuT") or {})
            dr.update({s: v[0] or 0 for s, v in (o.get("fuS") or {}).items() if isinstance(v, list) and v})
        segs = sorted(set(tm) | set(dr))
        fit = {m: fuel_model(fe, i)[1] for i, m in enumerate(("held", "fair"))}
        res = {m: boot_players(fe, lambda xs, i=i: fuel_model(xs, i)[0]) for i, m in enumerate(("held", "fair"))}
        out["fuelE"] = dict(trips=len(fe), users=len({o.get("u") for o in fe}), ratio=res,
                            perMin={s: round(dr[s] / (tm[s] / 60000), 3) for s in segs if tm[s] > 0},
                            seg={s: [round(fit[m][s][0] / fit[m][s][1], 3) if s in fit[m] and fit[m][s][1] else None
                                     for m in ("held", "fair")] for s in segs})
        print(f"  油量模型 {len(fe)} 趟 {out['fuelE']['users']} 人：每分鐘扣量 %/min "
              + ", ".join(f"{s}:{v:.3f}({tm[s] / 60000:.0f}min)" for s, v in out["fuelE"]["perMin"].items()))
        print("    實扣÷期望（每趟總量正規化，1＝和模型一致）held/fair "
              + ", ".join(f"{s}:{h if h is None else round(h, 2)}/{f if f is None else round(f, 2)}"
                          for s, (h, f) in out["fuelE"]["seg"].items()))
        for m in ("fair", "held"):
            r = res[m]
            print(f"    (彎道＋繞行)/其他 {m}：" + ("分母不足" if r is None else
                                              f"{r[0]:.2f}（玩家 95% {r[1]:.2f}–{r[2]:.2f}）"
                                              + ("" if m == "held" else "；判準：區間含 1"
                                                 + ("，過" if r[1] <= 1 <= r[2] else "，不過"))))
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


def sec_f(E, A):
    print(f"\n== F 判堵熱點（blocked 事件 x,y 的 {GRID}m 格，前 10）")
    cells = collections.defaultdict(lambda: dict(u=set(), d=set(), n=0, veh=set()))
    for e, rec in events(E, "blocked"):
        x, y = e.get("x", e.get("hitX")), e.get("y", e.get("hitY"))
        if x is None or y is None:
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
    keys = ("alive", "rmw", "phi", "od", "dt", "found", "same", "fsc", "fd", "sn", "script")
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
               K=sec_k(S, cur), L=sec_l(S, cur))
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
        check("fuelE" not in L and L["engLow"] == (0, 0), "L 舊摘要（沒有 fuE、eng 沒有 ecd）不出油量模型與引擎狀況")
        # 1020 油量模型：A、B 兩種趟（油箱大小不同＝每 % 對應的油量不同），實扣都照 fair 期望扣；B 的段比例和 A 不同。
        # 每趟正規化後 fair 段比＝1；不正規化會變 0.75。held（沒換算）在彎道期望偏高，段比 <1。舊格式（沒 fuE）與實扣 0 的趟不算。
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
        fair, held = LF["ratio"]["fair"], LF["ratio"]["held"]
        check(LF["trips"] == 4 and LF["users"] == 4 and all(abs(x - 1) < 1e-9 for x in fair),
              "L 油量模型：照 fair 扣的趟每趟正規化後 (arc+dodge)/其他＝1、玩家區間也是 1；沒 fuE 的趟不算（" + str(LF) + "）")
        check(held[0] < 0.9 and held[2] < 1, "L 油量模型：held（沒換算）段比 <1、區間不含 1（" + str(held) + "）")
        check(LF["perMin"] == {"arc": round(7 / 3, 3), "oth": round(17 / 5, 3)}, "L 每分鐘扣量＝fuS 實扣 ÷ fuT 分鐘（只算有 fuE 的趟）")
        check(LF["seg"]["arc"][1] == 1.0 and LF["seg"]["oth"][1] == 1.0, "L 各段實扣÷fair 期望＝1")
        check(LE["engLow"] == (1, 1), "L eng ecd <50 計數")
        man = [ln for ln in out.getvalue().splitlines() if ln.strip().startswith("static")]
        check(man and "maneuver 1" in man[0], "前 2.5s 有 dg＝maneuver")
        e = res["E"]
        check([(o["rec"]["u"], o["dt"], o["un"]) for o in e] == [("pa", 3, 1), ("pd", -0.08, 0)],
              "判堵後接手：10s 內（含觸發後 ≤500ms）、秒數與其間 unstick start；舊 rev 不算")
        top = res["F"]
        check(top[0][0] == (200, 280) and len(top[0][1]["u"]) == 3 and top[0][1]["n"] == 3, "熱點 25m 格聚合三位玩家")
        check(res["K"] == {"2": (20, 20, 20)}, "接手結束 rem ≥300 且 ev 無異常")
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
