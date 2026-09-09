"""telemetry 復盤工具（0907f）：session-NNN.log 的摘要／停住窗口／弧段窗口／contact 脈絡／逐幀視窗。

    python scripts/analyze_telemetry.py sum 012 013        # 每場：時長、cap／intent／hbr 分布、事件、弧段數、sk<0.5 數
    python scripts/analyze_telemetry.py corner 012          # 每個弧段：R、cap、入弧速、最低 tgt／spd、sk／ld／err、BRAKE／CONTACT 旗標
    python scripts/analyze_telemetry.py stops 012           # spd<3 持續 ≥0.8s 的窗口與當時 intent／cap／ctl／hbr／hold
    python scripts/analyze_telemetry.py contact 018         # contact／unstick／blocked／return／progress 事件＋contact 前 16 筆逐幀
    python scripts/analyze_telemetry.py win 013 21 25       # 逐幀（含 ftg／des／cmdA／ib／fbl）

判讀口訣：`ib=true tn=0` 一秒＝引擎 forceBrake 閂鎖（hbr／fbt 只記當幀會漏採，0907f 起看 fbl／fbw）；
`ftg` 明顯低於 `tgt` 且 cmdA 貼 0＝命令沒跟上剖面。
"""
import json, os, sys, collections, statistics as S
d = os.path.expandvars(r"%USERPROFILE%\Zomboid\Lua\MinidoracatAutoDrive\Telemetry")
def load(n):
    rows, evs, hdr = [], [], None
    for line in open(f"{d}/session-{n}.log", encoding="utf-8"):
        try: o = json.loads(line)
        except Exception: continue
        t = o.get("t")
        if t == "h": hdr = o
        elif t == "s": rows.append(o)
        elif t == "e": evs.append(o)
    return hdr, rows, evs
def g(o, k, dflt=0):
    v = o.get(k); return dflt if v is None else v
def fmt(o, t0):
    s = o.get("sen") or {}
    return ("t=%6.1f (%.0f,%.0f) spd=%5.1f tgt=%5.1f ftg=%5.1f des=%5.1f cmdA=%5.2f cap=%-12s int=%-6s ctl=%-6s ch=%s ck=%.3f cc=%5.1f lat=%5.2f el=%5.2f ld=%5.2f err=%5.2f st=%5.2f sk=%4.2f ib=%s tn=%s fbl=%4.0f fbw=%s hbr=%-8s ra=%s rh=%s hold=%s pm=%s dg=%s bl=%s hardN=%s zn=%s"
        % ((o["ts"]-t0)/1000, o["x"], o["y"], g(o,"spd"), g(o,"tgt"), g(o,"ftg",-1), g(o,"des",-1), g(o,"cmdA"), g(o,"capReason","-"), g(o,"intent","-"), g(o,"ctl","-"),
           "T" if o.get("curveHardActive") else "F", g(o,"curveKappa"), g(o,"curveCap"), g(o,"lat"), g(o,"el"), g(o,"ld"), g(o,"err"), g(o,"st"), g(o,"sk",1),
           "T" if o.get("ib") else "F", g(o,"tn","-"), g(o,"fbl",0), g(o,"fbw","-"), g(o,"hbr","-"), "T" if o.get("ra") else "F", "T" if o.get("rh") else "F", g(o,"holdReason","-"), g(o,"pm","-"), "T" if o.get("dg") else "F", "T" if o.get("bl") else "F", s.get("hardN"), s.get("zombieN")))
mode = sys.argv[1]; sessions = sys.argv[2:]
for n in sessions:
    hdr, rows, evs = load(n)
    if not rows: print(f"=== session-{n}: no samples"); continue
    t0 = rows[0]["ts"]
    car = (hdr.get("profile") or {}).get("scriptName")
    if mode == "sum":
        spd = [r.get("spd",0) for r in rows]
        print(f"=== session-{n} {car} rev={hdr.get('rev')} dur={(rows[-1]['ts']-t0)/1000:.0f}s n={len(rows)} spd med={S.median(spd):.1f} max={max(spd):.1f} end={evs[-1].get('n') if evs else '?'}/{evs[-1].get('why') if evs else ''}")
        print("  cap:", collections.Counter(r.get("capReason") for r in rows).most_common(10))
        print("  int:", collections.Counter(r.get("intent") for r in rows).most_common(), " hbr:", collections.Counter(r.get("hbr") for r in rows if r.get("hbr")).most_common())
        print("  ev:", sorted(collections.Counter((e.get("n"), e.get("phase") or e.get("why")) for e in evs if e.get("n") not in ("replan",)).items()))
        print("  arc n=%d  sk<0.5=%d  sl=%s sb=%s pco=%s cl=%s" % (sum(1 for r in rows if r.get("curveHardActive")), sum(1 for r in rows if (r.get("sk") if r.get("sk") is not None else 1) < 0.5), rows[-1].get("sl"), rows[-1].get("sb"), rows[-1].get("pco"), rows[-1].get("cl")))
    elif mode == "stops":
        # windows spd<3 for >=0.8s, excluding first 2s and last 3s
        i = 0
        while i < len(rows):
            if rows[i]["spd"] < 3 and (rows[i]["ts"]-t0) > 2000 and (rows[-1]["ts"]-rows[i]["ts"]) > 3000:
                j = i
                while j < len(rows) and rows[j]["spd"] < 3: j += 1
                if rows[j-1]["ts"] - rows[i]["ts"] >= 800:
                    pre = rows[max(0,i-8)]
                    print(f"  STOP session-{n} t={(rows[i]['ts']-t0)/1000:6.1f}..{(rows[j-1]['ts']-t0)/1000:6.1f} ({rows[i]['x']:.0f},{rows[i]['y']:.0f}) pre spd={pre['spd']:.1f} err={pre['err']:.2f} | reasons int={collections.Counter(r.get('intent') for r in rows[i:j]).most_common(2)} cap={collections.Counter(r.get('capReason') for r in rows[i:j]).most_common(3)} ctl={collections.Counter(r.get('ctl') for r in rows[i:j]).most_common(2)} hbr={collections.Counter(r.get('hbr') for r in rows[i:j]).most_common(2)} hold={collections.Counter(r.get('holdReason') for r in rows[i:j]).most_common(2)} pm={collections.Counter(r.get('pm') for r in rows[i:j]).most_common(2)} m={collections.Counter(r.get('m') for r in rows[i:j]).most_common(2)} errmax={max(abs(r['err']) for r in rows[i:j]):.2f} ch={any(r.get('curveHardActive') for r in rows[max(0,i-5):j])}")
                i = j
            else: i += 1
    elif mode == "corner":
        i = 0
        while i < len(rows):
            if rows[i].get("curveHardActive"):
                j = i
                while j < len(rows) and rows[j].get("curveHardActive"): j += 1
                lo = max(0, i-12); hi = min(len(rows), j+12)
                win = rows[lo:hi]
                mt = min(win, key=lambda r: r.get("tgt", 99)); ms = min(win, key=lambda r: r.get("spd", 99))
                kmax = max((r.get("curveKappa") or 0) for r in rows[i:j]); ccmin = min((r.get("curveCap") or 99) for r in rows[i:j])
                ent = rows[i]
                flag = ""
                if mt.get("tgt",99) < 10 or ms.get("spd",99) < 0.5*ent.get("spd",1): flag += " <<BRAKE"
                if any(r.get("capReason")=="contact" for r in win): flag += " <<CONTACT"
                if any(r.get("hbr") for r in win): flag += " hbr=" + ",".join(sorted(set(r.get("hbr") for r in win if r.get("hbr"))))
                print(f"  arc {n} t={(ent['ts']-t0)/1000:6.1f}..{(rows[j-1]['ts']-t0)/1000:6.1f} ({ent['x']:.0f},{ent['y']:.0f}) R={1/kmax if kmax>0 else 0:5.1f} cc={ccmin:5.1f} entry={ent.get('spd',0):5.1f} | min tgt={mt.get('tgt',0):5.1f}@{(mt['ts']-t0)/1000:.1f} cap={mt.get('capReason')} | min spd={ms.get('spd',0):5.1f}@{(ms['ts']-t0)/1000:.1f} | skmin={min((r.get('sk') if r.get('sk') is not None else 1) for r in win):.2f} ldmax={max(abs(r.get('ld') or 0) for r in win):.2f} errmax={max(abs(r.get('err') or 0) for r in win):.2f}{flag}")
                i = j
            else: i += 1
    elif mode == "contact":
        for e in evs:
            if e.get("n") in ("contact","unstick","blocked","return","progress") : print(f"  EV {n} t={(e['ts']-t0)/1000:6.1f} {e.get('n')} {e.get('phase') or ''} {e.get('why') or ''} " + " ".join(f"{k}={e[k]}" for k in ("hitS","hitX","hitY","clearance","d","kind","detail","blocker","shape","s","l","x","y") if k in e))
        prev=None
        for i,r in enumerate(rows):
            if r.get("capReason")=="contact" and prev!="contact":
                print(f"--- session-{n} contact onset #{i}")
                for rr in rows[max(0,i-16):i+4]: print("   ", fmt(rr,t0))
            prev=r.get("capReason")
    elif mode == "win":
        a, b = float(sessions[1]), float(sessions[2]) if len(sessions) > 2 else 1e9
        for r in rows:
            t=(r["ts"]-t0)/1000
            if a <= t <= b: print("   ", fmt(r,t0))
        break
