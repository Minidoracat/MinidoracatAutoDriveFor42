"""一次跑全部離線閘門，逐支判綠並印表；任一不綠 exit 1。repo 根目錄執行：

    python scripts/gates.py              # 全部 14 支（並行）
    python scripts/gates.py -v           # 不綠的那支另印最後 40 行
    python scripts/gates.py --self-test  # 判讀規則自測

判綠＝rc 0、輸出最末端是這支自己的摘要行、摘要的失敗數為 0（verify 另要 SKIP 0）、全文沒有 FAIL 行。
只數 FAIL 不夠：harness 中途 crash 時 FAIL 數也是 0，所以摘要行缺席本身就是紅。
"""
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

# (指令, 摘要 regex)；有 fail 群組的取失敗數，沒有的（只印 PASS 型）由 FAIL 行與 rc 判。
SECTION = re.compile(r"情境 \d+ 個、斷言 \d+ 項\n(?:(?P<fail>\d+) 項失敗|全部通過)$")
EN = re.compile(r"(?:cases|scenarios) \d+, asserts \d+\n(?:(?P<fail>\d+) failed|all passed)$")
TALLY = re.compile(r"情境 \d+ 個、斷言 \d+ 項、失敗 (?P<fail>\d+)$")
GATES = [
    # verify 綠＝PASS N / FAIL 0 / SKIP 0（缺 luac 時槽數檢查整段 SKIP、仍 exit 0），SKIP 併入失敗數。
    ("python scripts/verify_mod.py", re.compile(r"PASS \d+ / FAIL (?P<fail>\d+) / SKIP (?P<skip>\d+)$")),
    ("lua scripts/smoke_harness.lua", SECTION),
    ("lua scripts/test_hud.lua", re.compile(r"HUD assertions \d+, failures (?P<fail>\d+)$")),
    ("lua scripts/test_vehicle_profile.lua", EN),
    ("lua scripts/test_diagnostics.lua", EN),
    ("lua scripts/test_dynamics.lua", SECTION),
    ("lua scripts/test_follower.lua", SECTION),
    ("lua scripts/test_corridor.lua", SECTION),
    ("lua scripts/test_voice.lua", re.compile(r"test_voice: \d+ 項斷言、(?P<fail>\d+) 項失敗(?:\n全部通過)?$")),
    ("lua scripts/test_sensor.lua", SECTION),
    ("lua scripts/test_minimap_itinerary.lua", re.compile(r"test_minimap_itinerary: PASS \(.*\)$")),
    ("lua scripts/test_trailer.lua", re.compile(r"test_trailer: \d+ 項斷言、(?P<fail>\d+) 項失敗$")),
    ("lua scripts/test_upload.lua", TALLY),
    ("lua scripts/test_relay.lua", TALLY),
]
FAIL_LINE = re.compile(r"(?:^|[\s\[])FAIL(?:\]|:|\s|$)")
SUMMARY_LINE = re.compile(r"/ FAIL \d+ /")   # verify 的摘要行本身含 FAIL


def fail_lines(text):
    return [l for l in text.splitlines() if FAIL_LINE.search(l) and not SUMMARY_LINE.search(l)]


def judge(rx, rc, out, err=""):
    """回傳 (綠?, 摘要文字, 說明)。摘要必須在 stdout 最末端（後面還有東西＝crash 或多印，算紅）；
    stderr 另算（test_hud 的 FAIL 行寫 stderr，Lua crash 也在 stderr），其中的 FAIL 行一樣算紅。"""
    fails = fail_lines(out) + fail_lines(err)
    m = rx.search("\n".join(l.rstrip() for l in out.splitlines() if l.strip()))
    if not m:
        return False, "(沒有尾行摘要)", f"rc={rc} FAIL行={len(fails)}"
    n = int(m.group("fail")) if "fail" in rx.groupindex and m.group("fail") else 0
    skip = int(m.group("skip")) if "skip" in rx.groupindex else 0
    ok = rc == 0 and n == 0 and skip == 0 and not fails
    return ok, m.group(0).replace("\n", " / "), f"rc={rc} 失敗={n} SKIP={skip} FAIL行={len(fails)}"


def run(gate):
    cmd, rx = gate
    p = subprocess.run(cmd.split(), capture_output=True, text=True, encoding="utf-8", errors="replace")
    return (cmd,) + judge(rx, p.returncode, p.stdout, p.stderr) + (p.stdout + "\n" + p.stderr,)


def self_test():
    bad = []

    def check(ok, label):
        print(("  ok   " if ok else "  FAIL ") + label)
        if not ok:
            bad.append(label)

    check(judge(SECTION, 0, "x\n情境 3 個、斷言 9 項\n全部通過\n")[0], "完整摘要＋rc0＝綠")
    check(not judge(SECTION, 0, "情境1：a\n  ok\n")[0], "中途 crash（沒有摘要、0 個 FAIL）＝紅")
    check(not judge(SECTION, 1, "情境 3 個、斷言 9 項\n2 項失敗\n")[0], "摘要失敗數非 0＝紅")
    check(not judge(GATES[0][1], 0, "  FAIL  x\nPASS 3 / FAIL 0 / SKIP 0\n")[0], "摘要說 0 但有 FAIL 行＝紅")
    check(judge(GATES[0][1], 0, "  PASS  x\nPASS 3 / FAIL 0 / SKIP 0\n")[0], "verify 摘要行本身不算 FAIL 行")
    check(not judge(GATES[0][1], 0, "  SKIP  luac\n  SKIP  y\nPASS 3 / FAIL 0 / SKIP 2\n")[0], "verify 有 SKIP（exit 0）＝紅")
    check(not judge(GATES[0][1], 0, "PASS 3 / FAIL 0 / SKIP 1\n")[0], "verify SKIP 1＝紅")
    check(not judge(TALLY, 0, "情境 2 個、斷言 5 項、失敗 1\n")[0], "test_upload 型摘要失敗數非 0＝紅")
    check(not judge(GATES[2][1], 0, "HUD assertions 9, failures 0\nstack traceback:\n")[0], "摘要後面還有輸出（crash）＝紅")
    check(not judge(EN, 3, "scenarios 1, asserts 2\nall passed\n")[0], "rc 非 0＝紅")
    hud = judge(GATES[2][1], 1, "HUD assertions 9, failures 1\n", "FAIL label\n")
    check(not hud[0] and "failures 1" in hud[1], "FAIL 寫 stderr 時仍讀得到 stdout 摘要的失敗數＝紅")
    check(judge(GATES[2][1], 0, "HUD assertions 9, failures 0\n", "warning: x\n")[0], "stderr 無 FAIL 的雜訊不影響 stdout 摘要")
    check(not judge(GATES[2][1], 0, "HUD assertions 9, failures 0\n", "  FAIL x\n")[0], "stderr 有 FAIL 行＝紅")
    print(f"self-test：{len(bad)} 項失敗")
    return 1 if bad else 0


def main(argv):
    if "--self-test" in argv:
        return self_test()
    with ThreadPoolExecutor(max_workers=6) as ex:
        results = list(ex.map(run, GATES))
    bad = 0
    for cmd, ok, summary, detail, text in results:
        print(f"{'OK ' if ok else 'BAD'}  {cmd:40s} {detail:22s} {summary}")
        if not ok:
            bad += 1
            for l in fail_lines(text)[:15]:
                print("       " + l.strip()[:240])
            if "-v" in argv:
                for l in text.splitlines()[-40:]:
                    print("     | " + l[:240])
    print(f"GATES {'GREEN' if not bad else 'RED'}：{len(GATES) - bad}/{len(GATES)} 綠")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
