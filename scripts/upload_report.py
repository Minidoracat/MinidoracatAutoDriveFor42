"""正式服上傳批次評估：摘要 KPI、窗口片段、撞擊歸因與各確認項盤點（取代一次性的 temp/eval1012.py）。

    python scripts/upload_report.py <pull 目錄> <sinceEpoch秒> [--current 1010a,1010c] [--picks out.tsv]
    python scripts/upload_report.py --self-test

<pull 目錄>＝pull_uploads.py 的落地目錄（<玩家>/clip-NN.log、summary-*.log）；窗口＝片段 trig ≥ since。
--current＝駕駛行為與 HEAD 相同的 rev（C／D／K 與 B 的可用性只看這些）。玩家名一律輸出匿名代號（P01…，同一次執行內穩定）；
--picks 寫 TSV（category time anon rev kind veh path note）列出 C–E、G–J 背後的片段，path 含真實資料夾名，只留本機。
  A 摘要：(u, drive) 去重、依 build 分組：趟數／玩家／km、impact／impZ／contact 每千 km＋Poisson 95%、相鄰 build 條件二項 p、
    結束原因、loss 佔比、nm/fm、offset（offN／offMax）
  B 窗口片段：rev×kind、玩家數、現行 rev 可用性（事前 ≥3s、樣本 ≥10、有 route 點列）
  C 撞擊歸因（現行 rev；事件 (u, drive, ts) 去重）：上升緣樣本（ts ≤ 事件+5ms、帶 nb 的最後一筆）nb {kind: [d, s, l]}，
    貼車＝|s| ≤ halfL+0.8 且 |l| ≤ halfW+0.8；旗標 awt、maneuver（前 2.5s 主導 ctl 為 AVOID／RETURN 或任一 dg）；
    類別 zombie＞animal＞vehicle（貼車）＞static（事件 scost tree／hard／wall）＞corpse（貼車）＞far（有 nb 沒貼車）＞empty
  D contact ≥10 km/h（現行 rev）：scost、弧上（前 2.5s curveHardActive）、前 2.5s |ld|>0.5、lag 帽（capReason=lag）、主導 ctl、sprite 家族
  E 判堵後接手：takeover 片段觸發前 10s 內有 blocked；窗口內首筆 blocked→接手秒數、其間 unstick start、detour=false、最後一筆 why／shape
  F 判堵熱點：blocked x,y 的 25m 格（玩家、趟、事件、車型）
  G 起步調頭 uturn done：依 probe 分組（aligned ms、stop 的 detail）
  H 判堵鎖輪 brake 片段（at.fbw=blocked）：鎖輪速度、該趟是否 5s 內結束（摘要 end）
  I tow lost／relook
  J 結案檢查：area start kind=behind 後 20s 同趟 progress suspect；gate phase／why；detour kind=towcorner why=ok
  K 接手結束的趟（現行 rev）依 rem 分桶；≥300m 的趟 ev 沒有異常事件（blocked／uturn／unstick／contact／impact／progress）的數量
"""
import argparse
import collections
import datetime as dt
import glob
import json
import math
import os
import re
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyze_telemetry as AT  # noqa: E402

PFX = "UI_MinidoracatAutoDrive_"
PRE_MS = 2500           # 撞擊／接觸前的回看窗
TAKE_MS = 10000         # 接手前多久內有 blocked 算「判堵後接手」
TAKE_POST_MS = 500      # blocked 可晚於片段 trig 幾十 ms（同一輪 replan 在觸發後才記；正式服見過 +29～+92ms）
TOUCH_PAD = 0.8         # nb 貼車：半車長／半車寬外加
GRID = 25               # 判堵熱點格 m
STATIC = ("tree", "hard", "wall")
ANOMALY = ("blocked", "uturn", "unstick", "contact", "impact", "progress")
NB_KIND = (("z", "zombie"), ("a", "animal"), ("v", "vehicle"))


class Anon:
    def __init__(self):
        self.ids = {}

    def __call__(self, u):
        return self.ids.setdefault(u, f"P{len(self.ids) + 1:02d}")


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


def q(xs, p):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * p
    i = int(k)
    return xs[i] if i + 1 >= len(xs) else xs[i] + (xs[i + 1] - xs[i]) * (k - i)


def opts_of(s):
    return dict(p.split("=", 1) for p in (s or "").split(";") if "=" in p)


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


def load_clips(root, since_ms):
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

def nb_touch(nb, prof):
    """nb {kind: [d, s, l]} → [(kind, d, 貼車?)]。"""
    hl, hw = (prof.get("halfL") or 0) + TOUCH_PAD, (prof.get("halfW") or 0) + TOUCH_PAD
    out = []
    for k, v in (nb or {}).items():
        if isinstance(v, list) and len(v) >= 3:
            out.append((k, v[0], abs(v[1]) <= hl and abs(v[2]) <= hw))
    return out


def classify_impact(e, rec):
    """→ (類別, awt, maneuver, nb 清單)。"""
    ts = e["ts"]
    edge = [r for r in rec["rows"] if r["ts"] <= ts + 5 and "nb" in r]
    nb = nb_touch(edge[-1]["nb"], rec["prof"]) if edge else []
    pre = window(rec["rows"], ts)
    man = dominant_ctl(pre) in ("AVOID", "RETURN") or any(r.get("dg") for r in pre)
    touch = {k for k, _, t in nb if t}
    cls = next((name for k, name in NB_KIND if k in touch), None)
    if cls is None:
        cls = ("static" if e.get("scost") in STATIC else "corpse" if "c" in touch else "far" if nb else "empty")
    return cls, bool(e.get("awt")), man, nb


# ---------- 各節 ----------

def sec_a(S):
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
        K[b] = (km, k)
        revs = dict(collections.Counter(o.get("rev") for o in L))
        print(f"{b} rev={revs} trips={n} users={len({o.get('u') for o in L})} km={km:.0f}")
        if km:
            print("  " + "  ".join(f"{f} {v}={v / km * 1000:.1f}/千km (95% {ci(v)[0] / km * 1000:.1f}-{ci(v)[1] / km * 1000:.1f})"
                                   for f, v in k.items()))
        rs = collections.Counter((o.get("reason") or "?").replace(PFX, "") for o in L)
        print("  reasons " + ", ".join(f"{r}:{v}({v / n * 100:.1f}%)" for r, v in rs.most_common(10)))
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
    for i in range(1, len(order)):
        (w1, k1), (w2, k2) = K[order[i]], K[order[i - 1]]
        if w1 and w2:
            print(f"  {order[i]} vs {order[i - 1]}: " + " ".join(f"{f} p={binom_p(k1[f], k2[f], w1, w2):.3f}" for f in k1))
    return {b: dict(trips=len(by[b]), km=K[b][0], **K[b][1]) for b in order}


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


def sec_c(E, A, picks):
    print("\n== C 撞擊歸因（現行 rev，(u, drive, ts) 去重）")
    rows = []
    for e, rec in events(E, "impact"):
        cls, awt, man, nb = classify_impact(e, rec)
        rows.append((rec["rev"], cls, awt, man, rec))
        tag = "awt-" if awt else "maneuver-" if man else ""
        picks.append((f"impact-{tag}{cls}", e["ts"], rec, f"v={e.get('speed')} dv={e.get('dv')} scost={e.get('scost')} "
                      f"sprite={e.get('sprite')} nb={[(k, round(d, 2), t) for k, d, t in nb]}"))
    cnt = collections.Counter((r[0], r[1]) for r in rows)
    revs = sorted({r[0] for r in rows})
    print(f"  共 {len(rows)} 件；awt {sum(1 for r in rows if r[2])}、maneuver {sum(1 for r in rows if r[3])}")
    for cls in ("zombie", "animal", "vehicle", "static", "corpse", "far", "empty"):
        print(f"  {cls:8s} " + "  ".join(f"{rev}:{cnt[(rev, cls)]}" for rev in revs) + f"  計 {sum(cnt[(rev, cls)] for rev in revs)}"
              + ("（maneuver %d）" % sum(1 for r in rows if r[1] == cls and r[3])))
    zo = collections.Counter(f"zdodge={r[4]['opts'].get('zdodge')} zslow={r[4]['opts'].get('zslow')}" for r in rows if r[1] == "zombie")
    print("  zombie 依 opts " + ", ".join(f"{k}:{v}" for k, v in zo.most_common()))
    return collections.Counter(r[1] for r in rows)


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
    print("\n== G 起步調頭 uturn done（依 probe）")
    by = collections.defaultdict(list)
    for e, rec in events(E, "uturn", "done"):
        by[e.get("probe")].append(e)
        picks.append((f"uturn-{e.get('probe')}", e["ts"], rec, f"why={e.get('why')} ms={e.get('ms')} detail={e.get('detail')}"))
    print(f"  共 {sum(len(v) for v in by.values())}")
    for probe, L in sorted(by.items(), key=lambda kv: str(kv[0])):
        al = [(e.get("ms") or 0) / 1000 for e in L if e.get("why") == "aligned"]
        line = f"  probe={probe} n={len(L)} why " + ", ".join(f"{k}:{v}" for k, v in collections.Counter(e.get("why") for e in L).most_common())
        if al:
            line += f"；aligned s 中位 {statistics.median(al):.2f} p75 {q(al, .75):.2f} max {max(al):.2f}"
        stop = collections.Counter(e.get("detail") for e in L if e.get("why") == "stop")
        if stop:
            line += "；stop " + ", ".join(f"{k}:{v}" for k, v in stop.most_common())
        print(line)
    return {k: len(v) for k, v in by.items()}


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


def write_picks(path, picks, A):
    with open(path, "w", encoding="utf-8", newline="") as fh:
        fh.write("category\ttime(+08)\tanon\trev\tkind\tveh\tpath\tnote\n")
        for cat, ts, rec, note in sorted(picks, key=lambda p: (p[0], p[1])):
            fh.write("\t".join(map(str, (cat, hm(ts), A(rec["u"]), rec["rev"], rec["kind"], rec["veh"], rec["f"], note))) + "\n")


def report(root, since_s, cur, picks_path=None):
    since = float(since_s) * 1000
    A, picks = Anon(), []
    S = load_summaries(root)
    a = sec_a(S)
    C = load_clips(root, since)
    b = sec_b(C, cur, A)
    C = [r for r in C if r["rev"] in cur]             # C–J 只看現行 rev（舊版只能排除，不拿來定罪）
    E = dedupe(C)
    res = dict(A=a, B=b, C=sec_c(E, A, picks), D=sec_d(E, A, picks), E=sec_e(C, A, picks),
               F=sec_f(E, A), G=sec_g(E, A, picks), H=sec_h(C, S, A, picks), I=sec_i(E, A, picks), J=sec_j(E, A, picks),
               K=sec_k(S, cur))
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
        new = [sm("u%d" % i, T + 100 + i, "b-2", impact=1 if i < 2 else 0, reason=PFX + "takeover", rem=400) for i in range(20)]
        put("summary-1.log", old + new[:10])
        put("summary-2.log", new)                                   # new[:10] 在兩份輪寫摘要都有：去重
        put("summary-3.log", [sm("u1", T + 200, "b-3")])             # <20 趟的 build 不列

        def clip(u, slot, kind, trig, rows, evs, rev="2"):
            put(f"{u}/clip-{slot:02d}.log", [dict(t="clip", kind=kind, trig=trig, drive=T, at={"fbw": "blocked", "spd": 14}),
                                            dict(t="h", rev=rev, build="b-2", drive=T, opts="detour=false", profile=prof),
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
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            res = report(d, T / 1000, {"2"}, os.path.join(d, "picks.tsv"))
        a = res["A"]
        check(set(a) == {"b-1", "b-2"} and a["b-2"]["trips"] == 20 and a["b-2"]["impact"] == 2 and a["b-2"]["km"] == 20,
              "摘要 (u, drive) 去重、依 build 分組、<20 趟不列")
        check(res["B"]["clips"] == 9, "窗口：trig < since 的片段不算")
        check(res["C"] == {"zombie": 2, "far": 1, "static": 1}, "撞擊 (u, drive, ts) 去重、類別 zombie／far／static")
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
    a = ap.parse_args(argv)
    report(a.root, a.since, set(a.current.split(",")), a.picks)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
