# -*- coding: utf-8 -*-
"""發版前驗證閘門：一次跑完全部靜態檢查，任一失敗以非零碼結束。

用法（repo 根目錄或任意位置）：
    python scripts/verify_mod.py

零設定：自動偵測 MOD/<folder>/Contents/mods/<folder>/42/。
涵蓋的檢查與其對應的實際事故（皆有反編譯出處，詳見 AGENTS.md 踩坑錄）：

  1. luac -p 語法        — 需要 PATH 有 luac；沒有則列為 SKIP 而非 PASS
 1b. 每個函式的累計 local — Debug 用固定 200 格記錄宣告；含離開作用域的變數，預算 190
 1c. 呼叫自己的 Lua 函式時固定參數傳齊 — Kahlua 不替少傳的固定參數補 nil，陣列建構式最後一項是呼叫或 ... 之後
                         少傳的參數讀到堆疊殘值（KahluaThread.java:604-613,839-859、LuaCallFrame.java:96-109；
                         2026-10-31 Builder 宣傳片情境 cellsX(4, 8, 1) 的 z 收到 2）。既有的少傳記在
                         scripts/kahlua_args_baseline.txt，只有比它多才 FAIL；沒有 baseline 時 WARN（不擋），
                         python scripts/verify_mod.py --rebase-args 建一份。檢查本身每次先用內建 fixture 自驗
  2. BOM / CRLF          — 有 BOM 或 CRLF 的翻譯檔會被引擎「靜默忽略」
  3. 翻譯鍵集一致          — 缺鍵的語系會顯示原始 key
  4. 裸 % 檢查           — 42.20.1 起 formatted() 遇裸 % 崩潰；只允許 %1-%9 與 %%
 4b. 翻譯佔位與 EN 相同   — 各語系同一鍵的 %1-%9（多重集合）與 %% 數量要和 EN 一樣：漏掉的佔位少顯示資料，
                          多出的沒有參數可填（12 語多數是 AI 翻譯，鍵集一致與裸 % 檢查都抓不到）
  5. Kahlua 禁用全域       — next/xpcall 不存在（BaseLib 未註冊），os.clock 也沒有（OsLib 只註冊 date／difftime／time，
                           OsLib.java:322-324；2026-11-26 從 Safehouse 移來），呼叫→
                           「Object tried to call nil」。luac 與標準 Lua 測試都攔不住
                           （語法合法、標準 Lua 有這些函式），只能靜態掃描
                           assert 不在此列：遊戲根目錄 stdlib.lua 以 Lua 定義，Kahlua 可用
  6. table.sort 禁用      — Kahlua 的 sort 是遞迴 quicksort（coroutine 堆疊上限 3000），
                           已排序輸入退化 O(n) 深度、數百筆即溢位；一律用迭代 merge sort
  7. MOD/ 樹雜物          — .omc/.claude/.gitnexus 目錄與 .gitkeep 檔；Workshop 整包上傳不看 .gitignore
 7b. mod.info 多值欄位語法 — require/incompatible/load order 只接受逗號且 key 緊貼 =
 7c. MOD 清單封面與首發預覽 — 主選單 MOD 清單走一般貼圖、只畫 poster= 第一張，APNG 只解出各幀、主貼圖空白
                         （ChooseGameInfo.java:519-536、ImageData.java:136-191；2026-10-26 盤點 24 個 MOD 封面都是 APNG）。
                         MOD/<資料夾>/preview.png 首發前（workshop_publish.json 的 published_file_id 是 null 或沒有）也要
                         靜態：遊戲內上傳器的預覽框用 getTexture 畫（WorkshopSubmitScreen.lua:318），APNG 一樣空白
                         （Tesla 首發 2026-10-29 照舊文件用 APNG）。已發布只 PASS 註明：preview.png 只在首發用
  8. 佔位符殘留            — {{TOKEN}} 漏替換（略過根層 temp/、output/、tracker-state/ 與各層 node_modules/）
  9. Steam 描述位元組      — 各語言 ≤8000 UTF-8 bytes（中日文 3 bytes/字，容易低估）
 9b. Steam 指南稿長度     — STEAM_GUIDE.md／STEAM_GUIDE_EN.md 照 pz-family-docs/scripts/steam_guide.js 的 parse 切章：
                          檔頭要有標題／摘要註解，標題、章名 ≤128 bytes，摘要、每章內文 ≤8000 bytes（{{img:名}} 以
                          最長的 previewicon 標籤估算）。超過時上傳工具送到一半才丟錯（2026-11-26 從 Builder 移來）。
                          沒有指南稿則 SKIP
 10. 沙盒選項翻譯配對       — 每個 option 要有 Sandbox_<translation> 標題＋ _tooltip＋分頁名
 11. 公開文件洩漏掃描      — CHANGELOG bullet 與 STEAM_*.md 都會原樣貼到公開 Steam 頁；掃基礎設施
                           樣式（/home/ 路徑、IP、SteamID64、ssh、主機名）當最後防線。
                           攻擊配方與玩家識別資訊機器認不出來，靠撰寫規則（AGENTS.md）
 11b. 更新說明日期不晚於今天 — CHANGELOG.md 的 `## [版本] - YYYY-MM-DD` 與 STEAM_CHANGELOG.md 裡的 YYYY-MM-DD 晚於今天
                          （本機日期）＝FAIL（Tesla 0.7.0 2026-11-13 寫成 11-15，備妥後才發現）。認不出的寫法不檢查
 12. drainable 輸入消耗語意 — 配方的 drainable 輸入要帶 flags[ItemCount] 或 flags[IsFull]，
                          否則按剩餘用量計，空件會被整批連坐銷毀（AutoDrive 正式服實爆）
 13. PACKS 使用者包範本    — PACKS/<Item>/ 是給服主自備素材後自行上傳的 MOD 形狀資料夾：
                          preview.png 256/512 正方形 PNG ≤1,024,000 bytes、Contents/ 只有
                          mods/、mod.info 行首 id= 等於資料夾名且非家族前綴、無 require=、
                          無上傳黑名單副檔名、無 Lua／scripts、音效直接放 42/media/sound/、
                          無雜物、有 README.txt。沒有 PACKS/ 則 SKIP
 14. 翻譯字元原版字型能顯示 — 原版字型沒有退回字型：超過最大字碼畫成 ?（EN 的 → ≈ ✓ ① 與
                          所有中日文）、範圍內缺字畫成空白（CH/CN 的 → … ・ — “ ”）。依 TextManager
                          規則解析各語言實際載入的 .fnt 取交集；CN 漢字缺字是原版限制不計。
                          需要遊戲字型（PZ_PATH，預設 Steam 路徑），找不到則 SKIP
 15. 腳本區塊註解與大括號   — 註解 /* 沒有對應的 */ 時，ScriptParser.stripComments 從最後一個 */ 往回剝
                          （ScriptParser.java:52-87），剩下的 /* 連同整個 module 被當成區塊標頭，整檔靜默不載入
                          （Knox Pass 2026-10-06 實踩：template 不見、感應盒槽全部沒注入，只有實機看得出來）
 16. client 物品名稱用 getItemName — getItemNameFromFullType 只回翻譯表的物品名；原版背包顯示車輛零件時再接上車型，
                          getItemName 照同一規則（LuaManager.java:8745-8763）。BigGasTank1／2／3 因此都顯示「油箱 (大型)」
                          （Economy、UIFor42 2026-10-18）。不拿來顯示或不會出現車輛零件的用法寫進 verify_ignore.txt 並註明查證依據
 17. vehiclewheel 模型兩層 UV — vehiclewheel_static.vert 從 location 3 讀 uv，FBX／GLB 靜態網格進引擎是 pos、normal、
                          UV0、UV1（ImportedStaticMesh.java:29-35）；只有一層時讀到前一次 draw 留下的 attribute 3，
                          車上零件拿到車身的 UV1，貼圖亂掉、沒有錯誤（Tesla 輪子 2026-10-24）。第二層放同一份 UV
 18. server／shared 用顯示名稱 setName（WARN，不擋）— setName 的名稱和原名（專用伺服器上是物品全名）不同時存進存檔、
                         照原樣送給每個客戶端（InventoryItem.java:1711-1714 存、:2038 讀回），伺服器用自己語言的顯示名稱
                         命名，所有玩家都看到伺服器語言（Tesla 0.1.0 正式服 2026-10-29：卡片鑰匙、手機變英文）。
                         做法：伺服器不命名、客戶端用自己的語言命名（Tesla client/MinidoracatTesla/KeysUI.lua 的 UI.nameAll）；
                         `x:setName(x:getScriptItem():getDisplayName())` 是設回原名、不存不送，不列（Bags bags-names-1030a）；
                         本來就要改名的 repo（翻譯包）寫進 verify_ignore.txt 並註明理由。抓不到原版程式寫進的名字
                         （ISClothingExtraAction:createItemNew 換穿時把帶磨損、染血字樣的 getName() 當成改名，:76-79）
 19. repo 專屬檢查        — scripts/verify_local.py（選用）：只有單一 MOD 用得到的靜態檢查放那裡，不改本檔
                          （本檔是家族模板的副本，照模板更新時整份覆寫）。它照本檔格式印 PASS／FAIL／SKIP／WARN 行
                          （兩個空白、狀態、兩個空白、標籤），本檔逐行轉印並算進總結；結束碼非零卻沒印 FAIL 行也算 FAIL。
                          verify_ignore.txt 不套用到它的輸出，豁免由它自己決定
                          （Builder 管理面板規則頁的標籤寬：ES、PT 的譯文從 0.2.0 起被截，2026-11-01 才由 E2E 看到）

新增檢查時：同步把對應的坑記進 AGENTS.md 踩坑錄，並依「踩坑進化協議」回流到
pz-mod-template（見 AGENTS.md）。
"""
from datetime import date
import json
import os
import re
import shutil
import subprocess
import struct
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

passed, failed, skipped, warned = [], [], [], []

# 豁免清單（選用）：scripts/verify_ignore.txt，每行一個子字串樣式（# 開頭為註解）。
# 命中樣式的 finding 會列出但不計 FAIL／WARN——用於「已逐一查證屬合理例外」的殘留
# （例：翻譯包鏡像了來源 MOD 原文的裸 %）。每個樣式旁必須有註解說明查證依據。
IGNORE_PATTERNS = []
_ign = os.path.join(os.path.dirname(os.path.abspath(__file__)), "verify_ignore.txt")
if os.path.isfile(_ign):
    with open(_ign, encoding="utf-8") as _fh:
        for _line in _fh:
            _line = _line.strip()
            if _line and not _line.startswith("#"):
                IGNORE_PATTERNS.append(_line)


def ok(label):
    passed.append(label)
    print(f"  PASS  {label}")


def _unwaived(label, details):
    """印出 verify_ignore.txt 豁免的 finding，回傳剩下的；全數豁免（或本來就沒有）時記成 PASS。"""
    details = details or []
    kept = [d for d in details if not any(p in d for p in IGNORE_PATTERNS)]
    waived = [d for d in details if any(p in d for p in IGNORE_PATTERNS)]
    for d in waived:
        print(f"  WAIVE {label}: {d}（verify_ignore.txt 豁免）")
    if not kept:
        ok(f"{label}（{len(waived)} 筆豁免）" if waived else label)
    return kept


def fail(label, details=None):
    if not details:  # 沒帶細節也是失敗；不能經 _unwaived，空清單在那裡會記成 PASS
        failed.append(label)
        print(f"  FAIL  {label}")
        return
    kept = _unwaived(label, details)
    if not kept:
        return
    failed.append(label)
    print(f"  FAIL  {label}")
    for d in kept:
        print(f"        {d}")


def warn(label, details):
    """列出但不影響結束碼。"""
    kept = _unwaived(label, details)
    if not kept:
        return
    warned.append(label)
    print(f"  WARN  {label}")
    for d in kept:
        print(f"        {d}")


def skip(label, why):
    skipped.append(label)
    print(f"  SKIP  {label} — {why}")


def find_media():
    hits = []
    mod_root = os.path.join(REPO, "MOD")
    if os.path.isdir(mod_root):
        for folder in os.listdir(mod_root):
            p = os.path.join(mod_root, folder, "Contents", "mods")
            if not os.path.isdir(p):
                continue
            for inner in os.listdir(p):
                media = os.path.join(p, inner, "42", "media")
                if os.path.isdir(media):
                    hits.append(media)
    return hits


def iter_files(root, exts):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git",)]
        for name in files:
            if os.path.splitext(name)[1] in exts:
                yield os.path.join(base, name)


def lua_local_issues(listing):
    # 家族 190 預算；不能只看 main，也不能以同時活躍的 slots 取代累計 locals。
    summaries = re.findall(
        r"^(?:main|function) <([^\n]+)>[^\n]*\n[^\n]*?(\d+) locals?\b",
        listing, re.MULTILINE)
    if not summaries:
        return ["luac 未提供可辨識的函式摘要"]
    return [f"{source}: {count} locals（>190，Kahlua Debug 上限 200）"
            for source, count in summaries if int(count) > 190]


def self_test_lua_limits():
    compiler = shutil.which("luac")
    if not compiler:
        raise RuntimeError("local 邊界測試需要 luac")
    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "local limits.lua")
        for name, count, nested, reject in (
                ("at-budget", 190, False, False),
                ("over-budget", 191, False, True),
                ("nested-expired-locals", 201, True, True)):
            source = "do local value = 1 end\n" * count
            if nested:
                source = "local function nested()\n" + source + "end\n"
            with open(path, "w", encoding="utf-8", newline="\n") as stream:
                stream.write(source)
            result = subprocess.run([compiler, "-p", "-l", path], capture_output=True,
                                    text=True, encoding="utf-8", errors="replace", check=True)
            if bool(lua_local_issues(result.stdout)) != reject:
                raise AssertionError(name)
    if not lua_local_issues(""):
        raise AssertionError("missing compiler summary must fail closed")
    print("PASS Lua local 邊界：190／191、內層函式的失效作用域、缺少編譯摘要")


if __name__ == "__main__" and "--self-test-lua-limits" in sys.argv:
    self_test_lua_limits()
    sys.exit(0)


def lua_clean(src):
    """註解換成空白、字串內容換成底線（長度與換行不變），之後才能用樣式找呼叫。"""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        long_open = re.match(r"(--)?\[(=*)\[", src[i:]) if c in "-[" else None
        if long_open:
            end = src.find("]" + long_open.group(2) + "]", i)
            end = n if end < 0 else end + len(long_open.group(2)) + 2
            fill = " " if long_open.group(1) else "_"
            body = "".join("\n" if ch == "\n" else fill for ch in src[i:end])
            out.append(body if long_open.group(1) else '"' + body[1:-1] + '"')
            i = end
        elif src.startswith("--", i):
            end = src.find("\n", i)
            end = n if end < 0 else end
            out.append(" " * (end - i))
            i = end
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            out.append(c + "_" * (j - i - 1) + c)
            i = j + 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def call_args(text, open_at):
    """open_at 是呼叫的 '('。回 (引數個數, 第一個引數, 最後一個引數)；括號不成對回 None。巢狀函式本體裡的逗號不算。"""
    depth, block, count, start, first, i, n = 0, 0, 0, open_at + 1, None, open_at, len(text)
    while i < n:
        c = text[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                last = text[start:i].strip()
                if last or count:
                    count += 1
                return count, (last if first is None else first), last
        elif c == "," and depth == 1 and block == 0:
            if first is None:
                first = text[start:i].strip()
            count += 1
            start = i + 1
        elif c.isalpha() or c == "_":
            word = re.match(r"\w+", text[i:]).group(0)
            if word == "function" or (block > 0 and word in ("if", "do", "repeat")):
                block += 1
            elif block > 0 and word in ("end", "until"):
                block -= 1
            i += len(word)
            continue
        i += 1
    return None


def expands(arg):
    """引數是不是單獨一個呼叫（放在最後會展開成它全部的回傳值）。有運算子、或整個包在括號裡的只算一個值。"""
    if not arg.endswith(")"):
        return False
    depth, first_zero, i, n = 0, None, 0, len(arg)
    while i < n:
        c = arg[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0 and first_zero is None:
                first_zero = i
        elif depth == 0:
            if c in "+-*/%^#<>=~" or arg.startswith("..", i):
                return False
            if c.isalpha() or c == "_":
                word = re.match(r"\w+", arg[i:]).group(0)
                if word in ("and", "or", "not"):
                    return False
                i += len(word)
                continue
        i += 1
    return not (arg[0] == "(" and first_zero == n - 1)


def short_calls(lua_roots, extra=()):
    """lua_roots（各 MOD 的 42/media/lua）裡，傳的引數比定義的固定參數少的呼叫。回 [(key, 位置說明)]，
    key＝檔|函式|傳幾個<要幾個（檔是相對 media/lua 的路徑）。Builder scripts/verify_local.py 2026-11-19 起的做法搬來：
    MOD 的根表＝頂層 `X = X or {}`／`X = {}` 宣告的全域。呼叫照「哪個模組的哪個函式」對定義：`Queue.cancel(`、
    `Root.Queue.cancel(`、`local Q = Root.Queue` 之後的 `Q.cancel(` 都對 `Root.Queue = Queue` 那個檔的那一個（照名稱對、
    同名取最少的做法，別的模組有同名而參數較少的函式時會漏）。別名照呼叫的位置找：看得到、最近宣告的那個
    `local 名稱 = …`，`local A, B = R.A, R.B` 這種平行指派也認。沒前綴的呼叫對同檔最近、還在範圍內的 local 函式，
    `local f = Check.safehouse` 這種別名跟著對；`self:f(` 對同檔的方法；認不出接收者的 `obj:f(` 照方法名對（同名取
    最少的），`x.f(` 不看（別人的表或欄位裡的函式：`ArrayList.new()`、`UI.Button.new`）。
    最後一個引數是 ... 的不報；是單獨一個呼叫的（會展開成好幾個值）當一個算、照報，key 的 < 換成 ~、後面接那個
    呼叫的函式名（換成別的函式就不算 baseline 裡那一筆）。
    定義只認 `function A.b(…)`、`function A:b(…)`、`local function b(…)`、`A.b = function(…)`（表建構式裡的欄位不算）；
    `pcall(f, …)` 當成呼叫 f。extra＝另外要看的檔（自驗 fixture）：當成 MOD 的檔掃，key 的檔是相對 REPO。"""
    name_re = r"[A-Za-z_]\w*"
    chain_re = rf"{name_re}(?:\.{name_re})*"
    texts, base_of, defs, def_parens, roots, mods, aliases = {}, {}, {}, set(), {}, {}, {}

    def split_top(src):
        out, depth, cur = [], 0, ""
        for ch in src:
            depth += (ch in "({[") - (ch in ")}]")
            if ch == "," and depth == 0:
                out.append(cur.strip())
                cur = ""
            else:
                cur += ch
        return out + [cur.strip()]

    def fixed(params):
        return len([p for p in (q.strip() for q in params.split(",")) if p and p != "..."])

    def scope_end(text, pos):
        """local 函式看得到的範圍：到縮排比它淺的下一行（外層區塊收尾）為止；頂層的到檔尾。"""
        start = text.rfind("\n", 0, pos) + 1
        indent = len(text[start:pos]) - len(text[start:pos].lstrip())
        if indent:
            for m in re.finditer(r"\n([ \t]*)\S", text[pos:]):
                if len(m.group(1)) < indent:
                    return pos + m.start() + 1
        return len(text)

    def add(name, path, pos, table, form, params, local):
        text = texts[path]
        defs.setdefault(name, []).append({
            "path": path, "line": text.count("\n", 0, pos) + 1, "pos": pos, "table": table, "form": form,
            "need": fixed(params), "local": local, "end": scope_end(text, pos) if local else len(text)})

    files = [(f, root) for root in lua_roots for f in iter_files(root, {".lua"})] + [(f, REPO) for f in extra]
    for path, root in files:
        with open(path, encoding="utf-8", errors="replace") as fh:
            texts[path] = lua_clean(fh.read())
        base_of[path] = root
    root_names = {r for text in texts.values()
                  for r in re.findall(rf"^({name_re})\s*=\s*(?:\1\s+or\s+)?\{{", text, re.M)} - {"local"}

    for path, text in texts.items():
        # local a, b = e1, e2（同一行分號後面的也算）：（位置, 看得到的範圍結尾, 名稱, 運算式）
        aliases[path] = [(m.end(1), scope_end(text, m.end(1)), n.strip(), e)
                         for m in re.finditer(rf"(?:^|;)([ \t]*)local\s+({name_re}(?:\s*,\s*{name_re})*)\s*=\s*([^;\n]+)", text, re.M)
                         for n, e in zip(m.group(2).split(","), split_top(m.group(3)))]
        roots[path] = root_names | {a[2] for a in aliases[path] if a[3] in root_names}
        root = "|".join(sorted(roots[path]))
        mods[path] = {t: x for x, t in re.findall(rf"^[ \t]*(?:{root})\.({name_re})\s*=\s*({name_re})[ \t]*$", text, re.M)} \
            if root else {}
        for m in re.finditer(rf"(local\s+)?\bfunction\s+({chain_re})(?::({name_re}))?\s*\(([^)]*)\)", text):
            local, dotted, method, params = m.groups()
            def_parens.add((path, text.index("(", m.start(2))))
            if method:
                add(method, path, m.start(), dotted, "colon", params, False)
            elif "." in dotted:
                add(dotted.rsplit(".", 1)[1], path, m.start(), dotted.rsplit(".", 1)[0], "dot", params, False)
            else:
                add(dotted, path, m.start(), None, "bare", params, bool(local))
        for m in re.finditer(rf"^[ \t]*(local\s+)?({chain_re})\s*=\s*function\s*\(([^)]*)\)", text, re.M):
            local, dotted, params = m.groups()
            if "." in dotted:
                add(dotted.rsplit(".", 1)[1], path, m.start(), dotted.rsplit(".", 1)[0], "dot", params, False)
            else:
                add(dotted, path, m.start(), None, "bare", params, bool(local))
    modkeys = {x for path in texts for x in mods[path].values()}

    def alias_of(path, name, at):
        """at 這個位置看得到、最近宣告的 `local name = 運算式` 那一筆（位置, 範圍結尾, 名稱, 運算式）；沒有回 None。"""
        seen = [a for a in aliases[path] if a[2] == name and a[0] < at < a[1]]
        return max(seen) if seen else None

    def is_root(path, name, at):
        a = alias_of(path, name, at)
        return a[3] in root_names if a else name in root_names

    def modkey(path, chain, at):
        """at 這個位置，a.b 這種接收者指的是哪個模組（根表.X 的 X）；認不出回 None。
        別名的右邊照它宣告的位置解析（之後同名的變數換了別的東西，不影響先前取好的）。"""
        comps = chain.split(".")
        if len(comps) == 2 and is_root(path, comps[0], at):
            return comps[1] if comps[1] in modkeys else None
        if len(comps) == 1:
            a = alias_of(path, chain, at)
            m = a and re.fullmatch(rf"({name_re})\.({name_re})(?:\s+or\s+\{{\s*\}})?", a[3])
            if m and is_root(path, m.group(1), a[0]):
                return m.group(2) if m.group(2) in modkeys else None
            return mods[path].get(chain) or (chain if a is None and chain in modkeys else None)
        return None

    def of_module(name, key):
        return [d for d in defs.get(name, []) if d["form"] != "bare" and d["table"]
                and modkey(d["path"], d["table"], d["pos"]) == key]

    def receiver(text, at):
        """at 是呼叫名稱前面那個 . 或 : 的位置。回接收者（a.b 這種一串名字）；前面是運算式（x[i].f、g().f）回 None。"""
        head = text[max(0, at - 160):at]
        m = re.search(rf"({chain_re})\s*$", head)
        return None if not m or head[:m.start()].rstrip()[-1:] in (".", ":") else m.group(1)

    keywords = {"if", "and", "or", "not", "return", "while", "until", "elseif", "in", "function", "for", "do", "then", "else", "end", "local"}
    hits = []
    for path, text in texts.items():
        rel = os.path.relpath(path, base_of[path]).replace(os.sep, "/")
        for m in re.finditer(rf"([.:]?)\b({name_re})\s*\(", text):
            sep, name = m.groups()
            open_at = m.end() - 1
            if name in keywords or (path, open_at) in def_parens:
                continue
            got = call_args(text, open_at)
            if not got:
                continue
            count, first, last = got
            chain = receiver(text, m.start()) if sep else None
            if name == "pcall" and sep == "" and re.fullmatch(chain_re, first or ""):
                chain, name, count = first.rpartition(".")[0] or None, first.rsplit(".", 1)[-1], count - 1
                sep = "." if chain else ""
            named = defs.get(name, [])
            if sep == "":
                here = [d for d in named if d["form"] == "bare" and d["path"] == path]
                scoped = [d for d in here if d["local"] and d["pos"] < m.start() < d["end"]]
                alias = alias_of(path, name, m.start())
                alias = alias if alias and re.fullmatch(rf"{name_re}(?:\.{name_re})+", alias[3]) else None
                if scoped:
                    cands = [max(scoped, key=lambda d: d["pos"])]
                elif [d for d in here if not d["local"]]:   # 先宣告、後面才 `f = function` 的
                    cands = [d for d in here if not d["local"]]
                elif alias:
                    key = modkey(path, alias[3].rpartition(".")[0], alias[0])
                    cands = of_module(alias[3].rsplit(".", 1)[1], key) if key else []
                    sep = "."
                else:
                    cands = [d for d in named if d["form"] == "bare" and not d["local"]]
            else:
                key = chain and modkey(path, chain, m.start())
                mine = [d for d in named if d["form"] != "bare" and d["path"] == path]
                if key:
                    cands = of_module(name, key)
                elif chain == "self" and mine:
                    cands = mine
                elif chain and [d for d in mine if d["table"] == chain]:
                    cands = [d for d in mine if d["table"] == chain]
                elif sep == ":":   # 認不出是誰的方法呼叫：照方法名，同名取最少的
                    cands = [d for d in named if d["form"] == "colon"]
                else:              # 別人的表或欄位裡的函式
                    cands = []
            if not cands or last == "...":
                continue
            need = min(d["need"] + (1 if sep == "." and d["form"] == "colon" else -1 if sep == ":" and d["form"] == "dot" else 0)
                       for d in cands)
            if count < need:
                d = min(cands, key=lambda d: d["need"])
                line = text.count("\n", 0, m.start()) + 1
                tail = expands(last)
                callee = "?"   # f(x):g() 展開的是 g 的值：具名呼叫的右括號在引數最後面才記它的名字
                cm = re.match(rf"({chain_re}(?::{name_re})?)\s*\(", last.strip()) if tail else None
                depth = 0
                for i in range(cm.end() - 1, len(last.strip())) if cm else ():
                    depth += (last.strip()[i] == "(") - (last.strip()[i] == ")")
                    if depth == 0:
                        callee = cm.group(1) if i == len(last.strip()) - 1 else "?"
                        break
                hits.append((f"{rel}|{name}|{count}{'~' if tail else '<'}{need}" + (f"|{callee}" if tail else ""),
                             f"{rel}:{line}  {name} 傳 {count} 個{'（最後一個是呼叫，它回幾個值要自己看）' if tail else ''}、"
                             f"定義 {need} 個（{os.path.basename(d['path'])}:{d['line']}）"))
    return hits


# 1c 的自驗 fixture：行尾 --! 的行要被報成少傳，其他行不能報；驚嘆號後面接的字是尾端呼叫那一筆 key 最後記的函式名。
ARGS_FIXTURE_DEFS = """FixRoot = FixRoot or {}
local Queue = {}
FixRoot.Queue = Queue
function Queue.push(p, name, anchors) end
local Lib = {}
FixRoot.PlanLibrary = Lib
function Lib.saveFirst(pn, go) end
function Lib.opt(pn, ...) end
local Check = {}
FixRoot.Check = Check
function Check.item(p, name, d, anchor) end
function Check.safehouse(p, c, x) end
local Cursor = {}
FixRoot.Cursor = Cursor
function Cursor.send(p, name, anchors) end
local Mode = {}
FixRoot.PlanMode = Mode
function Mode.selectRect(a, b, c, d, e) end
function Mode:pick(a, b) end
"""
ARGS_FIXTURE_CALLS = """local B = FixRoot
local Q, L = B.Queue, B.PlanLibrary -- 平行指派的別名
local C = B.Check
local function one() return 1 end
local sh = C.safehouse -- 函式別名：之後 C 換成別的模組，sh 還是 Check.safehouse

Q.push(p, name) --!
Q.push(p, name, anchors)
L.saveFirst(pn) --!
L.saveFirst(pn, go)
L.opt(pn)
L.opt() --!
B.Queue.push(p, one()) --!one
B.Queue.push(p, one():rep(2)) --!?
B.Queue.push(p, ...)
C.item(p, name, d) --!
C.item(p, name, d, anchor)
local function inner()
    local C = B.Cursor -- 同名的別名在這個函式裡指另一個模組
    C.send(p, name) --!
    C.send(p, name, anchors)
    sh(p, c) --!
    sh(p, c, true)
end
C.item(p, name, d, anchor) -- 出了那個函式 C 又是 Check
C.item(p) --!
pcall(Q.push, p, name) --!
pcall(Q.push, p, name, anchors)
local function shadow()
    local B = {} -- 這個 B 不是 MOD 的根
    B.Queue.push(p, name)
end
local function sameLine()
    local M = B.PlanMode; M.selectRect(1, 2) --!
end
B.PlanMode:pick(1) --!
B.PlanMode:pick(1, 2)
B.PlanMode.pick(B.PlanMode, 1, 2)
one(1, 2)
"""


def self_test_args():
    """用 ARGS_FIXTURE_* 驗 short_calls：標 --! 的行要報（尾端呼叫要記對函式名）、其他行不報。回錯誤說明或 None。"""
    with tempfile.TemporaryDirectory(dir=REPO) as directory:
        defs_path, calls_path = os.path.join(directory, "defs.lua"), os.path.join(directory, "calls.lua")
        for path, body in ((defs_path, ARGS_FIXTURE_DEFS), (calls_path, ARGS_FIXTURE_CALLS)):
            with open(path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write(body)
        calls = os.path.relpath(calls_path, REPO).replace(os.sep, "/")
        want = {i: m.group(1) for i, line in enumerate(ARGS_FIXTURE_CALLS.splitlines(), 1)
                for m in [re.search(r"--!(\S*)", line)] if m}
        seen = {}
        for key, where in short_calls([], [defs_path, calls_path]):
            if not key.startswith(calls + "|"):
                return f"fixture 的定義檔被報：{where}"
            seen[int(where.split("  ")[0].rsplit(":", 1)[1])] = key.rsplit("|", 1)[1] if "~" in key else ""
    if seen != want:
        return f"fixture 標的 {sorted(want.items())}，實際報的 {sorted(seen.items())}"
    return None


if __name__ == "__main__" and "--self-test-args" in sys.argv:
    _err = self_test_args()
    print(f"FAIL 固定參數檢查自驗：{_err}" if _err else "PASS 固定參數檢查自驗")
    sys.exit(1 if _err else 0)


MEDIA_DIRS = find_media()
if not MEDIA_DIRS:
    print("找不到 MOD/*/Contents/mods/*/42/media，中止")
    sys.exit(2)

LUA_FILES = [f for m in MEDIA_DIRS for f in iter_files(os.path.join(m, "lua"), {".lua"})
             if os.path.isdir(os.path.join(m, "lua"))]

# ---- 1. luac 語法 ----
luac = shutil.which("luac")
if not luac:
    skip("Lua 語法（luac -p）", "PATH 沒有 luac")
    skip("Kahlua local 預算（每個函式 ≤190）", "PATH 沒有 luac")
else:
    bad, bad_limits = [], []
    for f in LUA_FILES:
        r = subprocess.run([luac, "-p", "-l", f], capture_output=True,
                           text=True, encoding="utf-8", errors="replace")
        if r.returncode != 0:
            bad.append(r.stderr.strip().splitlines()[-1] if r.stderr else f)
            bad_limits.append(f"{os.path.relpath(f, REPO)}: 語法失敗，無法檢查 local 預算")
        else:
            bad_limits.extend(lua_local_issues(r.stdout))
    fail("Lua 語法（luac -p）", bad) if bad else ok(f"Lua 語法（luac -p，{len(LUA_FILES)} 檔）")
    fail("Kahlua local 預算（每個函式 ≤190）", bad_limits) if bad_limits \
        else ok("Kahlua local 預算（每個函式 ≤190）")


# ---- 1c. 呼叫自己的 Lua 函式時固定參數傳齊（Kahlua 不補 nil）----
_t = "呼叫自己的 Lua 函式時固定參數傳齊（Kahlua 不補 nil）"
_base_path = os.path.join(REPO, "scripts", "kahlua_args_baseline.txt")
_err = self_test_args()
if _err:
    fail(_t, [f"檢查本身壞了：{_err}"])
else:
    _now = {}
    for _key, _where in short_calls([os.path.join(m, "lua") for m in MEDIA_DIRS if os.path.isdir(os.path.join(m, "lua"))]):
        _now.setdefault(_key, []).append(_where)
    _total = sum(len(v) for v in _now.values())
    if "--rebase-args" in sys.argv:
        with open(_base_path, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("# 既有的「固定參數少傳」呼叫（scripts/verify_mod.py 第 1c 項）。只會變少：改掉一處就重跑\n"
                     "# python scripts/verify_mod.py --rebase-args。不要為了讓新的呼叫通過而重跑：少的補 nil 傳齊，\n"
                     "# 或把選用參數改成 ... 接。只有確定呼叫的是 Java 方法，或最後一個引數的呼叫確定每條路都回夠多個值\n"
                     "# （key 裡是 ~，後面是那個呼叫的函式名）才加進來。\n")
            for _key in sorted(_now):
                fh.write(f"{len(_now[_key])}\t{_key}\n")
        ok(f"{_t}（baseline 重寫，{_total} 處）")
    elif not os.path.isfile(_base_path):
        warn(f"{_t}：沒有 scripts/kahlua_args_baseline.txt（先 --rebase-args 建一份才會擋新增的）",
             [w for k in sorted(_now) for w in _now[k]]) if _now else ok(_t)
    else:
        _base = {}
        with open(_base_path, encoding="utf-8") as fh:
            for _line in fh:
                if _line.strip() and not _line.startswith("#"):
                    _n, _key = _line.rstrip("\n").split("\t", 1)
                    _base[_key] = int(_n)
        _bad = [w + (f"（這個檔同樣的呼叫 baseline 只有 {_base[k]} 處）" if k in _base else "")
                for k in sorted(_now) if len(_now[k]) > _base.get(k, 0) for w in _now[k]]
        if _bad:
            fail(_t, _bad + ["少的補 nil 傳齊，或把選用參數改成 ... 接（local a, b = ...）；"
                             "確定呼叫的是 Java 方法才 python scripts/verify_mod.py --rebase-args"])
        else:
            ok(f"{_t}（新增 0 處；既有 {_total} 處記在 baseline）")

# ---- 2. BOM / CRLF ----
bad = []
for m in MEDIA_DIRS:
    for f in iter_files(m, {".lua", ".json", ".txt"}):
        with open(f, "rb") as fh:
            data = fh.read()
        rel = os.path.relpath(f, REPO)
        if data.startswith(b"\xef\xbb\xbf"):
            bad.append(f"BOM: {rel}")
        if b"\r" in data:
            bad.append(f"CRLF: {rel}")
fail("BOM / CRLF（42/media 下）", bad) if bad else ok("BOM / CRLF（42/media 下）")

# ---- 3+4. 翻譯鍵集一致 / 裸 % ----
# 裸 % 的判定分兩種模式：
#   嚴格（家族自製 MOD，語系含 EN 等四語）：只認引擎 Translator.formatted() 的 %1-%9 與 %%
#   寬容（翻譯包，語系 ⊆ {CH,CN}）：另接受 printf 指令（%s/%d/%.1f…）——第三方 MOD 常用
#     string.format(getText(...)) 消費譯文，這時保留 %d 才是對的，逸出反而弄壞
# 刻意不含 printf 旗標字元（-+空白#0）：含空白旗標會讓「50% done」的「% d」被解析成
# 合法指令而漏抓——翻譯實務上只會出現簡單的 %s/%d/%.1f，罕見旗標用法交給豁免清單
PRINTF_RE = re.compile(r"%\d*(?:\.\d+)?[sdifuxXcqgGeE]")
# 和引擎 FORMAT_TOKEN 一樣從左到右切（Translator.java:170）：「%%20」是 %% 加 20，不是 %2（TR 把 % 寫在數字前）；
# findall 對 %% 回空字串、對 %N 回數字，排序後比對同時涵蓋 %1-%9 與 %% 的數量
PCT_N_RE = re.compile(r"%%|%([1-9])")


def find_bare_pct(value, tolerant):
    s = str(value)
    i = 0
    while i < len(s):
        if s[i] != "%":
            i += 1
            continue
        if i + 1 < len(s) and s[i + 1] in "123456789%":
            i += 2          # 消耗合法配對——lookahead 不消耗會把 "40%%" 誤報（踩過）
            continue
        if tolerant:
            mm = PRINTF_RE.match(s, i)
            if mm:
                i = mm.end()
                continue
        return True
    return False


for m in MEDIA_DIRS:
    troot = os.path.join(m, "lua", "shared", "Translate")
    if not os.path.isdir(troot):
        continue
    langs = sorted(d for d in os.listdir(troot) if os.path.isdir(os.path.join(troot, d)))
    tolerant = set(langs) <= {"CH", "CN"}   # 翻譯包偵測
    names = sorted({n for l in langs for n in os.listdir(os.path.join(troot, l)) if n.endswith(".json")})
    mismatch, badpct, broken, pctdiff = [], [], [], []
    for n in names:
        keysets, datas = {}, {}
        for l in langs:
            p = os.path.join(troot, l, n)
            if not os.path.isfile(p):
                mismatch.append(f"{n}: {l} 缺檔")
                continue
            try:
                with open(p, encoding="utf-8") as fh:
                    data = json.load(fh)
            except Exception as e:
                broken.append(f"{l}/{n}: {e}")
                continue
            keysets[l] = set(data)
            datas[l] = data
            for k, v in data.items():
                if find_bare_pct(v, tolerant):
                    badpct.append(f"{l}/{n} 的 {k}")
        if len(keysets) > 1:
            base = next(iter(keysets.values()))
            for l, ks in keysets.items():
                if ks != base:
                    mismatch.append(f"{n}: {l} 鍵集不一致（差 {len(ks ^ base)} 鍵）")
        en = datas.get("EN")
        if en is not None:
            for l, d in datas.items():
                for k, v in d.items():
                    ev = en.get(k)
                    if l != "EN" and isinstance(ev, str) and isinstance(v, str) and \
                            sorted(PCT_N_RE.findall(v)) != sorted(PCT_N_RE.findall(ev)):
                        pctdiff.append(f"{l}/{n} 的 {k}")
    if broken:
        fail("翻譯 JSON 可解析", broken)
    else:
        ok("翻譯 JSON 可解析")
    fail("翻譯鍵集一致", mismatch) if mismatch else ok(f"翻譯鍵集一致（{'/'.join(langs)}）")
    pct_label = "翻譯值無裸 %（翻譯包模式：另接受 printf 指令）" if tolerant else "翻譯值無裸 %（僅 %1-%9 與 %%）"
    fail(pct_label, sorted(set(badpct))) if badpct else ok(pct_label)
    if "EN" in langs:
        label = "翻譯佔位與 EN 相同（%1-%9、%%）"
        fail(label, pctdiff) if pctdiff else ok(label)

# ---- 4b. Lua 字串字面值不得含非 ASCII ----
# Kahlua 的 LexState 以 Reader 讀入 char 卻用 byte[] 存 token（LexState.java:70,178,194-199），任何 code point > 255
# 的字面值到執行期都是亂碼（pz-family-docs pitfalls「非 ASCII 字串字面值」）。luac -p 與標準 Lua 的 harness 都正確處理
# UTF-8，只有實機才炸：Economy 2026-09-06 中文 toast 變 !p8；Safehouse 2026-10-11 寫出的報告檔頭截出單獨的 \r，
# readLine 把註解切成壞行（模板原本沒有這項，Safehouse 照模板建立而漏掉）。玩家可見文字一律走 Translate/<LANG>/*.json；
# 註解不受影響（先剝掉再掃）。
_LONG_COMMENT = re.compile(r"--\[(=*)\[.*?\]\1\]", re.DOTALL)
_LONG_STRING = re.compile(r"\[(=*)\[.*?\]\1\]", re.DOTALL)
_SHORT_STRING = re.compile(r'"(?:[^"\\\n]|\\.)*"|\'(?:[^\'\\\n]|\\.)*\'')
nonascii = []
for f in LUA_FILES:
    rel = os.path.relpath(f, REPO)
    with open(f, encoding="utf-8", errors="replace") as fh:
        src = fh.read()
    src = _LONG_COMMENT.sub(lambda mm: "\n" * mm.group().count("\n"), src)
    for mm in _LONG_STRING.finditer(src):
        if any(ord(ch) > 127 for ch in mm.group()):
            nonascii.append(f"{rel}:{src.count(chr(10), 0, mm.start()) + 1}: 長字串含非 ASCII")
    src = _LONG_STRING.sub(lambda mm: "\n" * mm.group().count("\n"), src)
    for lineno, line in enumerate(src.split("\n"), 1):
        code = line.split("--", 1)[0]
        for mm in _SHORT_STRING.finditer(code):
            if any(ord(ch) > 127 for ch in mm.group()):
                nonascii.append(f"{rel}:{lineno}: {mm.group()[:30]}")
fail("Lua 字串字面值純 ASCII（Kahlua 截斷）", nonascii) if nonascii \
    else ok(f"Lua 字串字面值純 ASCII（{len(LUA_FILES)} 檔）")

# ---- 5+6. Kahlua 禁用全域 / table.sort ----
FORBIDDEN = ("next", "xpcall")
FORBIDDEN_MEMBERS = ("os.clock",)  # OsLib.java:322-324 只註冊 date／difftime／time，os.clock 是 nil
hits_forbidden, hits_sort = [], []
for f in LUA_FILES:
    rel = os.path.relpath(f, REPO)
    with open(f, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            code = line.split("--", 1)[0]
            for name in FORBIDDEN:
                for mm in re.finditer(rf"(?<![\w_:.]){name}\s*\(", code):
                    hits_forbidden.append(f"{rel}:{lineno} 用了 {name}()")
            for name in FORBIDDEN_MEMBERS:  # 任何引用都擋：別名（local c = os.clock）炸在呼叫處，訊息看不出是 os.clock
                if re.search(r"(?<![\w.])" + r"\s*\.\s*".join(map(re.escape, name.split("."))) + r"\b", code):
                    hits_forbidden.append(f"{rel}:{lineno} 用了 {name}")
            if re.search(r"(?<![\w_])table\.sort\s*\(", code):
                hits_sort.append(f"{rel}:{lineno}")
fail("Kahlua 禁用全域（next/xpcall/os.clock）", hits_forbidden) if hits_forbidden \
    else ok("Kahlua 禁用全域（next/xpcall/os.clock）")
fail("無 table.sort（用迭代 sortSafe，見 AGENTS.md）", hits_sort) if hits_sort \
    else ok("無 table.sort")

# ---- 7. MOD/ 樹雜物 ----
# .gitkeep 也算雜物：引擎會把 MOD 樹內任何檔案列舉成 mod 資源（console 出現
# "overrides media/lua/client/.gitkeep"），且 Workshop 上傳整包不看 .gitignore。
# MOD/ 樹內空目錄不撐 .gitkeep，靠首個實檔建立（引擎對不存在的 lua 子目錄不報錯）。
junk = []
for base, dirs, files in os.walk(os.path.join(REPO, "MOD")):
    for d in list(dirs):
        if d in (".omc", ".claude", ".gitnexus"):
            junk.append(os.path.relpath(os.path.join(base, d), REPO))
            dirs.remove(d)
    for name in files:
        if name == ".gitkeep":
            junk.append(os.path.relpath(os.path.join(base, name), REPO))
fail("MOD/ 樹無雜物（AI 狀態目錄／.gitkeep）", junk) if junk \
    else ok("MOD/ 樹無雜物（AI 狀態目錄／.gitkeep）")

# ---- 7b. mod.info 多值欄位語法 ----
# ChooseGameInfo.java:224/226/228/230 用 contains("key=") 後直接 split(",")。
manifest_bad = []
multi_keys = ("require", "incompatible", "loadModAfter", "loadModBefore")
canonical_re = re.compile(
    r"^\s*(require|incompatible|loadModAfter|loadModBefore)=(.*)$")
for base, _, files in os.walk(os.path.join(REPO, "MOD")):
    if "mod.info" not in files:
        continue
    info = os.path.join(base, "mod.info")
    rel_info = os.path.relpath(info, REPO)
    with open(info, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            for key in multi_keys:
                marker = key + "="
                if marker in line:
                    match = canonical_re.match(line.rstrip("\r\n"))
                    if not match or match.group(1) != key:
                        manifest_bad.append(
                            f"{rel_info}:{lineno}: {key}= 前不得有註解或其他文字")
                        continue
                    value = match.group(2)
                    if "#" in value:
                        manifest_bad.append(
                            f"{rel_info}:{lineno}: mod.info 不支援 {key} 行尾註解")
                    if ";" in value:
                        manifest_bad.append(
                            f"{rel_info}:{lineno}: {key} 多值必須用逗號，不是分號")
                elif re.search(rf"{key}\s+=", line):
                    manifest_bad.append(
                        f"{rel_info}:{lineno}: {key}= 鍵名與等號間不得有空格")
fail("mod.info 多值欄位語法", manifest_bad) if manifest_bad \
    else ok("mod.info 多值欄位語法")

# ---- 7c. MOD 清單封面（poster=）----
# 主選單「模組」的封面走一般貼圖，只畫 poster= 的第一張（ChooseGameInfo.java:519-536）。
# APNG 在這條路上只解出各幀、主貼圖是空的，畫成空白也不報錯（ImageData.java:136-191）；
# poster= 找不到檔一樣是空白。路徑照引擎：先找版本資料夾，沒有再找 common/（ChooseGameInfo.java:210-219）。
# 有 preview.png 的項目（要上 Workshop）版本資料夾的 mod.info 一定要有 poster=；還沒做封面的開發中 MOD 不擋。
# 2026-10-26 Zones 玩家回報後盤點：24 個 MOD 的封面都是 APNG，SafeSpawn 的 42/mod.info 沒有 poster=。
def png_animated(path):
    """第一個 IDAT 之前有 acTL 就是 APNG；不是 PNG 回 False（只抓已知會畫成空白的 APNG）。"""
    with open(path, "rb") as fh:
        if fh.read(8) != b"\x89PNG\r\n\x1a\n":
            return False
        while len(head := fh.read(8)) == 8:
            if head[4:] in (b"acTL", b"IDAT"):
                return head[4:] == b"acTL"
            fh.seek(int.from_bytes(head[:4], "big") + 4, 1)
    return False


poster_bad, poster_n = [], 0
for base, _, files in os.walk(os.path.join(REPO, "MOD")):
    mod_dir = os.path.dirname(base)
    if "mod.info" not in files or os.path.basename(os.path.dirname(mod_dir)) != "mods" \
            or os.path.basename(base) == "common":
        continue
    rel_info = os.path.relpath(os.path.join(base, "mod.info"), REPO)
    item_dir = os.path.dirname(os.path.dirname(os.path.dirname(mod_dir)))   # MOD/<資料夾>
    publish = os.path.isfile(os.path.join(item_dir, "preview.png"))
    with open(os.path.join(base, "mod.info"), encoding="utf-8") as fh:
        names = [line.strip().replace("poster=", "") for line in fh if "poster=" in line]
    names = [n for n in names if n]
    if publish and not names:
        poster_bad.append(f"{rel_info}: 沒有 poster=，MOD 清單的封面是空白")
    for name in names:
        path = os.path.join(base, name)
        if not os.path.isfile(path):
            path = os.path.join(mod_dir, "common", name)
        if not os.path.isfile(path):
            if publish:
                poster_bad.append(f"{rel_info}: poster={name} 找不到檔")
            continue
        poster_n += 1
        if png_animated(path):
            poster_bad.append(f"{os.path.relpath(path, REPO)}: APNG 在 MOD 清單畫成空白，改用靜態 PNG（still.png）")
fail("MOD 清單封面（poster=）", poster_bad) if poster_bad \
    else ok(f"MOD 清單封面是靜態 PNG（{poster_n} 張）")

# ---- 7c（續）. 首發前 preview.png 是靜態 PNG ----
# 遊戲內上傳器的預覽框用 getTexture 畫 preview.png（WorkshopSubmitScreen.lua:318），APNG 走這條路只解出各幀、
# 主貼圖空白（Tesla 首發 2026-10-29 照舊文件用 APNG，預覽框空白）。preview.png 只在首發用：已發布不擋。
_pub_file = os.path.join(REPO, "scripts", "workshop_publish.json")
_published = False
if os.path.isfile(_pub_file):
    with open(_pub_file, encoding="utf-8") as fh:
        _published = bool(json.load(fh).get("published_file_id"))
_mod_root = os.path.join(REPO, "MOD")
_previews = [os.path.join(_mod_root, d, "preview.png") for d in sorted(os.listdir(_mod_root))
             if os.path.isfile(os.path.join(_mod_root, d, "preview.png"))] if os.path.isdir(_mod_root) else []
_apng = [os.path.relpath(p, REPO) for p in _previews if png_animated(p)]
_t = "首發 preview.png 是靜態 PNG（上傳器預覽框）"
if _apng and not _published:
    fail(_t, [f"{p}: APNG 在遊戲內上傳器預覽框畫成空白，首發前改用靜態 PNG" for p in _apng])
elif _apng:
    ok(f"{_t}：已發布，preview.png 只在首發用（{len(_apng)} 張 APNG 不擋）")
else:
    ok(f"{_t}（{len(_previews)} 張）")

# ---- 8. 佔位符殘留 ----
tokens = []
SELF = os.path.abspath(__file__)   # 本檔 docstring 有 {{TOKEN}} 範例字樣，排除自己
for base, dirs, files in os.walk(REPO):
    # 根層 temp/（E2E 產物）、output/（本機草稿）是 gitignored、不入版控也不上傳；node_modules/ 是相依套件；
    # tracker-state/ 是上游追蹤的狀態（ModLang、ModMaps，不上傳；ModLang 本機下載時曾有 11.9 萬檔，這一項跑 555 秒）。
    # 2026-10-19 Economy 的 temp/（3.4 萬檔）讓這一項跑 146 秒，LangFor42 的 output/ 草稿造成假 FAIL。
    # 依目錄名略過、不用「git 忽略的全略過」：AGENTS.md 也被 git 忽略，但 scaffold 後要檢查它的佔位符。
    dirs[:] = [d for d in dirs if d not in (".git", ".omc", ".claude", ".gitnexus", "__pycache__", "node_modules")
               and not (base == REPO and d in ("temp", "output", "tracker-state"))]
    for name in files:
        p = os.path.join(base, name)
        if os.path.abspath(p) == SELF:
            continue
        try:
            with open(p, encoding="utf-8") as fh:
                text = fh.read()
        except (UnicodeDecodeError, OSError):
            continue
        for mm in re.finditer(r"\{\{[A-Z_]+\}\}", text):
            tokens.append(f"{os.path.relpath(p, REPO)}: {mm.group()}")
fail("無 {{TOKEN}} 佔位符殘留", tokens) if tokens else ok("無 {{TOKEN}} 佔位符殘留")

# ---- 9. Steam 描述位元組 ----
descs = [f for f in os.listdir(REPO) if f.startswith("STEAM_DESCRIPTION") and f.endswith(".md")]
over = []
for f in descs:
    size = os.path.getsize(os.path.join(REPO, f))
    if size > 8000:
        over.append(f"{f}: {size} bytes（上限 8000）")
if descs:
    fail("Steam 描述 ≤8000 bytes", over) if over else ok(f"Steam 描述 ≤8000 bytes（{len(descs)} 檔）")

# ---- 9b. Steam 指南稿長度 ----
# 照 pz-family-docs/scripts/steam_guide.js 的 parse()（改那邊就要照著改這裡）：整行 <!-- --> 註解不送；以行首「=== 」切章、
# 第一行是章名；內文頭尾去空白、章內 [h3] 前補一個空行；{{img:名}} 以最長的 previewicon 標籤估算。上限出處：
# pz-family-docs/release.md「長度上限都算 UTF-8 位元組」（2026-10-11 實測：章內文 8001 bytes 被拒；章名、指南標題 ≤128）。
_t = "Steam 指南稿：標題、章名 ≤128 bytes，摘要、每章 ≤8000 bytes"
_guides = [g for g in ("STEAM_GUIDE.md", "STEAM_GUIDE_EN.md") if os.path.isfile(os.path.join(REPO, g))]
_bad, _n = [], 0


def _u8(s):
    return len(s.encode("utf-8"))


for _g in _guides:
    with open(os.path.join(REPO, _g), encoding="utf-8", errors="replace", newline="") as fh:  # 同 steam_guide.js：只換 \r\n
        _lines = fh.read().replace("\r\n", "\n").split("\n")
    _meta = {}
    for _line in _lines:
        _m = re.match(r"^<!--\s*(指南網址|標題|摘要)：(.*?)\s*-->$", _line)
        if _m:
            _meta[_m[1]] = _m[2].strip()
    for _k, _cap in (("標題", 128), ("摘要", 8000)):
        if not _meta.get(_k):
            _bad.append(f"{_g}：檔頭缺 <!-- {_k}：… -->")
        elif _u8(_meta[_k]) > _cap:
            _bad.append(f"{_g} 指南{_k} {_u8(_meta[_k])} bytes（上限 {_cap}）")
    _chunks = re.split(r"^=== ", "\n".join(x for x in _lines if not re.match(r"^<!--.*-->$", x)), flags=re.M)[1:]
    if not _chunks:
        _bad.append(f"{_g}：沒有「=== 章名」開頭的章節")
    for _c in _chunks:
        _n += 1
        _title, _, _body = _c.partition("\n")
        _title = _title.strip()
        _body = re.sub(r"([^\n])\n\[h3\]", r"\1\n\n[h3]", _body.strip())
        if not _title or _u8(_title) > 128:
            _bad.append(f"{_g}：章名空白或超過 128 bytes：「{_title}」")
        if not _body:
            _bad.append(f"{_g}「{_title}」：沒有內文")
        _size = _u8(re.sub(r"\{\{img:([^}]+)\}\}",
                           lambda m: f"[previewicon=000000000000;sizeOriginal,inline;{m[1]}][/previewicon]", _body))
        if _size > 8000:
            _bad.append(f"{_g}「{_title}」：{_size} bytes（上限 8000；中文字 3、emoji 4）")
if not _guides:
    skip(_t, "沒有 STEAM_GUIDE.md／STEAM_GUIDE_EN.md")
elif _bad:
    fail(_t, _bad + ["縮短或照功能拆章；上傳工具 pz-family-docs/scripts/steam_guide.js 用同樣的規則"])
else:
    ok(f"{_t}（{len(_guides)} 檔 {_n} 章）")

# ---- 10. 沙盒選項翻譯配對 ----
for m in MEDIA_DIRS:
    sb = os.path.join(m, "sandbox-options.txt")
    if not os.path.isfile(sb):
        continue
    with open(sb, encoding="utf-8") as fh:
        txt = fh.read()
    opts = set(re.findall(r"translation\s*=\s*(\S+?)\s*,", txt))
    pages = set(re.findall(r"page\s*=\s*(\S+?)\s*,", txt))
    ch = os.path.join(m, "lua", "shared", "Translate", "CH", "Sandbox.json")
    if not os.path.isfile(ch):
        fail("沙盒選項翻譯配對", ["有 sandbox-options.txt 但無 CH/Sandbox.json"])
        continue
    with open(ch, encoding="utf-8") as fh:
        keys = set(json.load(fh))
    miss = [f"缺標題: Sandbox_{o}" for o in opts if f"Sandbox_{o}" not in keys]
    miss += [f"缺 tooltip: Sandbox_{o}_tooltip" for o in opts if f"Sandbox_{o}_tooltip" not in keys]
    miss += [f"缺分頁名: Sandbox_{p}" for p in pages if f"Sandbox_{p}" not in keys]
    fail("沙盒選項翻譯配對", miss) if miss else ok(f"沙盒選項翻譯配對（{len(opts)} 選項）")

# ---- 11. 公開文件洩漏掃描 ----
# STEAM_*.md 也掃：2026-10-18 三個發版代理都把 gen_steam_changelog.py 的草稿整篇手寫覆蓋，
# 生成器的掃描只在產生當下跑，覆蓋後的稿沒人再掃。
LEAK_PATTERNS = [
    (re.compile(r"/home/\w+"), "Linux 家目錄路徑"),
    (re.compile(r"[A-Z]:\\Users\\"), "Windows 使用者路徑"),
    (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), "IPv4 位址"),
    (re.compile(r"\b7656\d{13}\b"), "SteamID64"),
    (re.compile(r"\bssh\b", re.IGNORECASE), "ssh 字樣"),
    (re.compile(r"pz-?server", re.IGNORECASE), "伺服器主機名"),
]
_pub = [n for n in sorted(os.listdir(REPO)) if re.fullmatch(r"CHANGELOG\.md|STEAM_.*\.md", n)]
leaks = []
for _n in _pub:
    with open(os.path.join(REPO, _n), encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            for pat, desc in LEAK_PATTERNS:
                mm = pat.search(line)
                if mm:
                    leaks.append(f"{_n}:{lineno} {desc}（{mm.group()[:40]}）")
_t = f"公開文件無基礎設施洩漏樣式（{len(_pub)} 檔）"
fail(_t, leaks) if leaks else ok(_t)

# ---- 11b. 更新說明日期不晚於今天 ----
# 日期是手打的，寫成未來的日子沒有別的檢查會抓：Tesla 0.7.0 2026-11-13 的 CHANGELOG 與 STEAM_CHANGELOG 寫成 11-15，
# 備妥上車後才發現。只認 YYYY-MM-DD（家族的 `## [版本] - YYYY-MM-DD` 與 `[i]YYYY-MM-DD[/i]`），其他寫法與不存在的日期不檢查。
_dates = []
for _n, _pat in (("CHANGELOG.md", r"(?m)^## \[[^\]]+\] - (\d{4})-(\d{2})-(\d{2})\b"),
                 ("STEAM_CHANGELOG.md", r"(?<!\d)(\d{4})-(\d{2})-(\d{2})(?!\d)")):
    if os.path.isfile(os.path.join(REPO, _n)):
        with open(os.path.join(REPO, _n), encoding="utf-8") as fh:
            for mm in re.finditer(_pat, fh.read()):
                try:
                    _dates.append((_n, mm.group(), date(*map(int, mm.groups()))))
                except ValueError:
                    pass
_today = date.today()
_t = f"更新說明日期不晚於今天 {_today}（{len(_dates)} 個日期）"
_future = [f"{n}: {s.strip()}" for n, s, d in _dates if d > _today]
fail(_t, _future) if _future else ok(_t)

# ---- 12. drainable 輸入消耗語意（本 MOD drainable）----
# CraftRecipeManager.java:633/652：item 輸入沒有 flags[ItemCount] 時計量按
# getCurrentUses() 而非件數——空電 drainable 每件貢獻 0 卻仍被收進消耗集合
# （:621-630），湊足需求那一刻整批連坐銷毀（processDestroyAndUsedItems，
# CraftRecipeData.java:544-564）。AutoDrive 正式服實爆：39 個空電 GPS 一次製作全滅。
# 兩種合法寫法：flags[ItemCount]（按件計，Base.Battery 型，recipes_electrical.txt:30）
# 或 flags[IsFull]（滿件才可入料、天然無空件連坐，Base.Claybag 型，
# recipes_sacks.txt:27）。非 destroy mode 也不安全：空件同樣被連坐收集，且 UseItem
# 對 uses<=0 且無 KeepOnDeplete=true 的物品一樣 RemoveItem（ItemUser.java:69-72）。
# 引擎 parser 逐項對齊：mode 的 key 是字面 `mode:`（大小寫敏感，InputScript.java:666
# startsWith），值才 equalsIgnoreCase（:670-674），缺省 Normal（:68），同行多個
# mode: token 取最後；flags split(";") 後直接 InputFlag.valueOf（:744-748，無 trim、
# 大小寫敏感）——閘門比引擎寬（re.I、strip、substring search）就會放行載入期會炸
# 或行為相反的寫法。輕量掃描：只認本 MOD scripts 內宣告的 drainable 短名與其 Tags
# （原版 drainable 的輸入這裡看不到；同名跨 module 極罕見，寧可誤報）。
drain_bad = []


def _input_mode(raw):
    # mode:use 是引擎 no-op（InputScript.java:670 守衛外不賦值），本閘門對它偏嚴；
    # 適用前提：輸入行無 +/- 續行（續行在 OnPostWorldDictionaryInit 覆寫 mode 成
    # Keep，InputScript.java:817、:834-835）。
    mode = "normal"
    for tok in raw.split():
        if tok.startswith("mode:"):
            mode = tok[5:].rstrip(",").lower()
    return mode


def _bracket_union(raw, key):
    # 引擎逐 token 累積 key[...]（InputScript.java:742-750），first-match 會漏第二個。
    # 各項不 strip：flags 走 InputFlag.valueOf 無 trim。
    out = set()
    for mm in re.finditer(rf"(?<!\w){key}\[([^\]]+)\]", raw):
        out.update(mm.group(1).split(";"))
    return out


def _norm_tag(t):
    # tag 走 ResourceLocation.of：lower＋無 namespace 補 base:（ResourceLocation.java:18-29）
    t = t.strip().lower()
    return t if ":" in t else f"base:{t}"


for m in MEDIA_DIRS:
    sdir = os.path.join(m, "scripts")
    if not os.path.isdir(sdir):
        continue
    texts = []
    for f in iter_files(sdir, {".txt"}):
        with open(f, encoding="utf-8") as fh:
            texts.append((os.path.relpath(f, REPO),
                          re.sub(r"/\*.*?\*/", "", fh.read(), flags=re.S)))
    drain_keep, drain_tag_map = {}, {}
    for _, txt in texts:
        for mm in re.finditer(r"(?<![\w.])item\s+(\w+)\s*\{([^{}]*)\}", txt):
            body = mm.group(2)
            if not re.search(r"ItemType\s*=\s*base:drainable", body, re.I):
                continue
            drain_keep[mm.group(1)] = \
                re.search(r"KeepOnDeplete\s*=\s*true", body, re.I) is not None
            tg = re.search(r"Tags\s*=\s*([^,\r\n]+)", body)
            drain_tag_map[mm.group(1)] = {_norm_tag(t) for t in tg.group(1).split(";")
                                          if t.strip()} if tg else set()
    if not drain_keep:
        continue
    for rel, txt in texts:
        for lineno, line in enumerate(txt.splitlines(), 1):
            im = re.match(r"\s*item\s+\d+\s+(.*)", line)
            if not im:
                continue
            rest = im.group(1)
            br = re.search(r"(?<!\w)\[([^\]]+)\]", rest)
            hit = set()
            if br:
                hit = {t.strip().rsplit(".", 1)[-1]
                       for t in br.group(1).split(";")} & set(drain_keep)
            in_tags = {_norm_tag(t) for t in _bracket_union(rest, "tags")}
            if in_tags:
                hit |= {name for name, tags in drain_tag_map.items() if in_tags & tags}
            if not hit:
                continue
            flags = _bracket_union(rest, "flags")
            if "ItemCount" in flags or "IsFull" in flags:
                continue
            mode = _input_mode(rest)
            if mode == "destroy":
                drain_bad.append(f"{rel}:{lineno} `{rest.strip()}` —— drainable 走 destroy "
                                 f"必須帶 flags[ItemCount]（或 IsFull），否則空件被連坐吞噬")
            elif any(not drain_keep[s] for s in hit):
                drain_bad.append(f"{rel}:{lineno} `{rest.strip()}` —— 非 destroy 的 drainable "
                                 f"輸入（mode={mode}）需該物品宣告 KeepOnDeplete = true，"
                                 f"否則空件耗盡被靜默移除（ItemUser.java:69-72）且同樣被連坐收集")
fail("drainable 輸入消耗語意（ItemCount/IsFull/KeepOnDeplete）", drain_bad) if drain_bad \
    else ok("drainable 輸入消耗語意（ItemCount/IsFull/KeepOnDeplete；本 MOD drainable）")

# ---- 15. 腳本區塊註解與大括號 ----
# 引擎從最後一個 */ 往回配對 /*（可巢狀），配不到就停（ScriptParser.java:52-87）；剩下的文字照大括號
# 深度切區塊（parseTokens，:89 起）。所以只要 /* 與 */ 數量不等，或剝掉註解後大括號不平衡、沒有任何
# module 區塊，就會整檔或部分區塊靜默消失。
script_bad = []
for m in MEDIA_DIRS:
    sdir = os.path.join(m, "scripts")
    if not os.path.isdir(sdir):
        continue
    for f in iter_files(sdir, {".txt"}):
        with open(f, encoding="utf-8") as fh:
            raw = fh.read()
        rel = os.path.relpath(f, REPO)
        if raw.count("/*") != raw.count("*/"):
            script_bad.append(f"{rel}: /* {raw.count('/*')} 個、*/ {raw.count('*/')} 個（註解沒有成對）")
            continue
        body = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
        if body.count("{") != body.count("}"):
            script_bad.append(f"{rel}: 去掉註解後 {{ {body.count('{')} 個、}} {body.count('}')} 個")
        elif not re.search(r"(?m)^\s*module\s+\w+\s*\{?", body):
            script_bad.append(f"{rel}: 去掉註解後找不到 module 區塊")
fail("腳本區塊註解與大括號", script_bad) if script_bad else ok("腳本區塊註解與大括號")

# ---- 13. PACKS 使用者包範本 ----
# PACKS/<Item>/ 是給服主複製、自備素材後自行上傳 Workshop 的 MOD 形狀資料夾（不是本 repo
# 的發布物，MOD/ 才是）。規則出自 42.21.0 反編譯：上傳器 SteamWorkshopItem.java 的
# validatePreviewImage:487-512（a）、validateContents:514-562（b）、validateModsFolder
# :450-477（c）、validateModDotInfo:277-307 用 startsWith("id=")（d）、validateFileTypes
# :242-275（e）；GameSounds.getOrCreateSound:94-138 只探測 media/sound/<名稱>.ogg|.wav、
# 不看子資料夾（g）。家族前綴 id 會被 pz-family-docs sync_mod.ps1:38-41 當家族 MOD 去 MOD/
# 找來源而拒絕啟動（d）。範本只放素材：不帶 Lua／scripts（scripts 進 checksum、兩端須一致）
# 也不 require=（f、d）；整包發給服主，雜物一律擋（h）；README.txt 是服主說明唯一出處（i）。
PACK_JUNK = {".gitkeep", "thumbs.db", "desktop.ini", ".ds_store", ".omc", ".claude", ".gitnexus"}
PACK_BANNED_EXTS = (".exe", ".dll", ".bat", ".app", ".dylib", ".sh", ".so", ".zip")
PACK_SOUND_EXTS = (".ogg", ".wav")
PACK_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")
PACK_FAMILY_ID_RE = re.compile(r"Minidoracat.*|Cat.*For42", re.I)   # PowerShell -like 不分大小寫
PNG_SIG = b"\x89PNG\r\n\x1a\n"


def _prel(path):
    return os.path.relpath(path, REPO).replace(os.sep, "/")


def pack_problems(item_dir):
    bad = []
    readme = os.path.join(item_dir, "README.txt")
    if not os.path.isfile(readme):
        bad.append(f"{_prel(readme)}: 缺少（i：服主說明唯一出處）")

    preview = os.path.join(item_dir, "preview.png")
    rp = _prel(preview)
    if not os.path.isfile(preview):
        bad.append(f"{rp}: 缺少（a：上傳器回 PreviewNotFound）")
    else:
        size = os.path.getsize(preview)
        if size > 1024000:
            bad.append(f"{rp}: {size:,} bytes（a：上限 1,024,000 bytes）")
        with open(preview, "rb") as fh:
            head = fh.read(24)
        if len(head) < 24 or head[:8] != PNG_SIG or head[12:16] != b"IHDR":
            bad.append(f"{rp}: 不是 PNG（a：上傳器回 PreviewFormat）")
        else:
            w, h = int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")
            if w != h or w not in (256, 512):
                bad.append(f"{rp}: {w}x{h}（a：需 256 或 512 正方形）")

    contents = os.path.join(item_dir, "Contents")
    if not os.path.isdir(contents):
        bad.append(f"{_prel(contents)}/: 缺少（b：上傳器回 MissingContents）")
        return bad
    for name in sorted(os.listdir(contents)):
        p = os.path.join(contents, name)
        if not os.path.isdir(p):
            bad.append(f"{_prel(p)}: Contents/ 底下不可放檔案（b：FileNotAllowedInContents）")
        elif name != "mods":
            bad.append(f"{_prel(p)}/: Contents/ 底下只能有 mods/（b：FolderNotAllowedInContents）")

    mods = os.path.join(contents, "mods")
    if not os.path.isdir(mods):
        bad.append(f"{_prel(mods)}/: 缺少（c：至少要一個 MOD 資料夾）")
        return bad
    folders = []
    for name in sorted(os.listdir(mods)):
        p = os.path.join(mods, name)
        if os.path.isdir(p):
            folders.append(name)
        else:
            bad.append(f"{_prel(p)}: mods/ 底下只能放資料夾（c：FileNotAllowedInMods）")
    if not folders:
        bad.append(f"{_prel(mods)}/: 至少要一個 MOD 資料夾（c：EmptyModsFolder）")

    for folder in folders:
        info = os.path.join(mods, folder, "42", "mod.info")
        ri = _prel(info)
        if not os.path.isfile(info):
            bad.append(f"{ri}: 缺少（d）")
            continue
        with open(info, encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
        mod_id = next((ln[3:].strip() for ln in lines if ln.startswith("id=")), "")
        if not mod_id:
            bad.append(f"{ri}: 沒有行首 id= 或值為空（d：上傳器 startsWith(\"id=\")，不允許前置空白）")
        else:
            if mod_id != folder:
                bad.append(f"{ri}: id={mod_id} 與資料夾名 {folder} 不同（d）")
            if not PACK_ID_RE.fullmatch(mod_id):
                bad.append(f"{ri}: id={mod_id} 只能用英數開頭、後接英數 _ . -（d）")
            if PACK_FAMILY_ID_RE.fullmatch(mod_id):
                bad.append(f"{ri}: id={mod_id} 用了家族前綴 Minidoracat*／Cat*For42"
                           f"（d：sync_mod.ps1 會當家族 MOD 去 MOD/ 找來源而拒絕啟動）")
        for lineno, ln in enumerate(lines, 1):
            if "require=" in ln:   # ChooseGameInfo 用 contains 判斷
                bad.append(f"{ri}:{lineno}: 不可有 require=（d：範本只放素材、不依賴載入順序）")

    for base, dirs, files in os.walk(contents):
        parts = os.path.relpath(base, contents).replace(os.sep, "/").split("/")
        sound_dir = len(parts) == 5 and parts[0] == "mods" and parts[2:] == ["42", "media", "sound"]
        for d in dirs:
            rd = _prel(os.path.join(base, d))
            if parts[-1].lower() == "media" and d.lower() in ("lua", "scripts"):
                bad.append(f"{rd}/: 不可有 media/{d}/（f：範本只放素材，不帶程式／scripts）")
            if sound_dir:
                bad.append(f"{rd}/: 42/media/sound/ 不可有子資料夾（g：引擎只探測 media/sound/<名稱>）")
        for name in files:
            low = name.lower()
            rf = _prel(os.path.join(base, name))
            if low.endswith(PACK_BANNED_EXTS) and not low.endswith("pyramid.zip"):
                bad.append(f"{rf}: 副檔名禁止上傳（e：上傳器回 FileTypeNotAllowed）")
            if low.endswith(".lua"):
                bad.append(f"{rf}: 不可有 .lua（f：範本只放素材，不帶程式）")
            if low.endswith(PACK_SOUND_EXTS) and not sound_dir:
                bad.append(f"{rf}: 音效只能直接放在 42/media/sound/（g：引擎不看子資料夾或其他位置）")
            elif sound_dir and not low.endswith(PACK_SOUND_EXTS):
                bad.append(f"{rf}: 42/media/sound/ 只能放 .ogg／.wav（g）")
    return bad


_packs_root = os.path.join(REPO, "PACKS")
if not os.path.isdir(_packs_root):
    skip("PACKS 使用者包範本", "repo 沒有 PACKS/ 目錄")
else:
    _pack_bad = []
    for _base, _dirs, _files in os.walk(_packs_root):
        for _name in _dirs + _files:
            if _name.lower() in PACK_JUNK:
                _pack_bad.append(f"{_prel(os.path.join(_base, _name))}: 雜物（h：整包發給服主，"
                                 f"引擎也會把 MOD 樹每個檔案列成資源）")
    _packs = sorted(d for d in os.listdir(_packs_root) if os.path.isdir(os.path.join(_packs_root, d)))
    for _item in _packs:
        _pack_bad += pack_problems(os.path.join(_packs_root, _item))
    fail("PACKS 使用者包範本", _pack_bad) if _pack_bad \
        else ok(f"PACKS 使用者包範本（{len(_packs)} 包）")

# ---- 14. 翻譯字元：原版字型能顯示 ----
# 原版字型沒有退回機制：字碼超過該字型的最大字碼畫成「?」，範圍內但沒有字形就畫成空白（寬 0）。
# 依 TextManager 的規則找出各語言實際載入的 .fnt（EN/fonts.txt 疊上該語言的 fonts.txt；語言或字級資料夾
# 沒有該檔就退回 EN），取六種 UI 字型與各字級的交集；MOD 自帶 media/fonts 時以 MOD 的為準。
# CN 缺的漢字是原版字型本身的限制（原版簡中介面一樣缺），不計。出處與替代字見 pitfalls.md「原版字型缺很多常用符號」。
PZ_PATH = os.environ.get("PZ_PATH", r"D:\SteamLibrary\steamapps\common\ProjectZomboid")
GLYPH_UI_FONTS = ("Small", "Medium", "Large", "NewSmall", "NewMedium", "NewLarge")
# 替代字候選：只提示該語言字型畫得出的（CH／CN／JP／KO 有 ￩￪￫￬￭ 與 －～「」，EN 等西文字型沒有；2026-11-26 對原版 .fnt
# 逐字查，ModLang 截圖確認）。Print Media 的 _info 正文多一個 > 會讓第二段之後被丟，所以 CJK 的箭頭先提 ￫。
GLYPH_HINTS = {0x2192: ("￫", "->"), 0x2190: ("￩", "<-"), 0x2191: ("￪",), 0x2193: ("￬",), 0x25A0: ("￭",),
               0x2026: ("...",), 0x30FB: ("·",), 0x2022: ("·",), 0x2014: ("－", "-"), 0x2013: ("～", "-"),
               0x2248: ("~", "約"), 0x2103: ("°C",), 0x201C: ("「",), 0x201D: ("」",), 0x2018: ("『",), 0x2019: ("』",)}
_fnt_cache = {}


def _fnt_chars(path):
    if path not in _fnt_cache:
        with open(path, encoding="utf-8", errors="replace") as fh:
            ids = [int(x) for x in re.findall(r"^char id=(\d+)", fh.read(), re.M)]
        _fnt_cache[path] = (frozenset(ids), max(ids) if ids else 0)
    return _fnt_cache[path]


def _font_file(roots, rel):
    for r in roots:
        p = os.path.join(r, rel)
        if os.path.isfile(p):
            return p
    return None


def font_glyphs(roots, lang):
    """該語言所有 UI 字型、字級都畫得出的字集與最小的最大字碼；找不到字型回 None。"""
    names = {}
    for code in ("EN",) if lang == "EN" else ("EN", lang):
        p = _font_file(roots, os.path.join(code, "fonts.txt"))
        if p:
            with open(p, encoding="utf-8", errors="replace") as fh:
                for name, body in re.findall(r"font\s+(\w+)\s*\{([^}]*)\}", fh.read()):
                    f = re.search(r"fnt\s*=\s*([^,\s]+)", body)
                    if f:
                        names[name] = f.group(1)
    sets, tops = [], []
    for ui in GLYPH_UI_FONTS:
        fn = names.get(ui)
        if not fn:
            continue
        for size in (None, "1x", "2x", "3x", "4x"):
            cands = ([os.path.join(lang, size, fn)] if size else []) + [os.path.join(lang, fn)]
            if lang != "EN":
                cands += ([os.path.join("EN", size, fn)] if size else []) + [os.path.join("EN", fn)]
            cands.append(fn)
            path = next((p for p in (_font_file(roots, c) for c in cands) if p), None)
            if path:
                s, top = _fnt_chars(path)
                sets.append(s)
                tops.append(top)
    return (frozenset.intersection(*sets), min(tops)) if sets else None


def _cjk_ideograph(cp):
    return 0x3400 <= cp <= 0x4DBF or 0x4E00 <= cp <= 0x9FFF or 0xF900 <= cp <= 0xFAFF or 0x20000 <= cp <= 0x3FFFF


GLYPH_LABEL = "翻譯字元：原版字型能顯示"
_vanilla_fonts = os.path.join(PZ_PATH, "media", "fonts")
if not os.path.isdir(_vanilla_fonts):
    skip(GLYPH_LABEL, f"找不到遊戲字型 {_vanilla_fonts}（設定 PZ_PATH）")
else:
    _roots = [os.path.join(m, "fonts") for m in MEDIA_DIRS if os.path.isdir(os.path.join(m, "fonts"))] + [_vanilla_fonts]
    _glyph_problems, _cn_missing, _glyphs = [], set(), {}
    for m in MEDIA_DIRS:
        troot = os.path.join(m, "lua", "shared", "Translate")
        if not os.path.isdir(troot):
            continue
        for lang in sorted(os.listdir(troot)):
            ldir = os.path.join(troot, lang)
            if not os.path.isdir(ldir):
                continue
            if lang not in _glyphs:
                _glyphs[lang] = font_glyphs(_roots, lang)
            if _glyphs[lang] is None:
                _glyph_problems.append(f"{lang}：找不到這個語言的字型")
                continue
            have, top = _glyphs[lang]
            for name in sorted(os.listdir(ldir)):
                if not name.endswith(".json"):
                    continue
                try:
                    with open(os.path.join(ldir, name), encoding="utf-8") as fh:
                        data = json.load(fh)
                except Exception:
                    continue  # 解析失敗由翻譯 JSON 檢查回報
                for key, val in data.items():
                    if not isinstance(val, str):
                        continue
                    bad = []
                    for ch in dict.fromkeys(val):
                        cp = ord(ch)
                        if cp < 32 or ch.isspace() or cp in have:
                            continue
                        if lang == "CN" and _cjk_ideograph(cp):
                            _cn_missing.add(ch)
                            continue
                        hint = " 或 ".join(h for h in GLYPH_HINTS.get(cp, ()) if all(ord(c) in have for c in h))
                        bad.append(f"{ch}（U+{cp:04X}）畫成{'?' if cp > top else '空白'}" + (f"，可改 {hint}" if hint else ""))
                    if bad:
                        _glyph_problems.append(f"{lang}/{name} {key}：" + "；".join(bad))
    _label = GLYPH_LABEL + (f"（CN 另有 {len(_cn_missing)} 個漢字原版字型就缺，不計）" if _cn_missing else "")
    fail(_label, _glyph_problems) if _glyph_problems else ok(_label)

# ---- 16. client 顯示物品名稱用 getItemName ----
# getItemNameFromFullType 只回翻譯表的物品名；原版背包顯示車輛零件時再接上車型，getItemName 照同一規則
# （LuaManager.java:8745-8763；getItemNameFromFullType 在 :8579-8583）。BigGasTank1／2／3 因此都顯示「油箱 (大型)」
# （Economy、UIFor42 物品挑選器 2026-10-18，家族 pitfalls.md「UI」）。不拿來顯示、或那裡不會出現車輛零件的用法：
# 把 finding 寫進 scripts/verify_ignore.txt（寫到檔名加冒號就好，不寫行號），上一行用 # 註明查證依據。
_PLAIN_NAME = re.compile(r"(?<!\w)getItemNameFromFullType\b")
plain_names = []
for f in LUA_FILES:
    lua_rel = os.path.relpath(f, REPO).replace(os.sep, "/").split("/lua/", 1)[-1]
    if not lua_rel.startswith("client/"):
        continue
    with open(f, encoding="utf-8", errors="replace") as fh:
        src = _LONG_COMMENT.sub(lambda mm: "\n" * mm.group().count("\n"), fh.read())
    for lineno, line in enumerate(src.split("\n"), 1):
        if _PLAIN_NAME.search(line.split("--", 1)[0]):
            plain_names.append(f"getItemNameFromFullType in {lua_rel}:{lineno}")
_t = "client 顯示物品名稱用 getItemName（getItemNameFromFullType 沒有車型）"
fail(_t, plain_names) if plain_names else ok(_t)

# ---- 17. vehiclewheel 模型的 FBX／GLB 要兩層 UV ----
# vehiclewheel_static.vert 從 location 3 讀 uv（location 2 是原版 .txt 網格的 tangent）；FBX／GLB 靜態網格進引擎是
# pos、normal、UV0、UV1，照元素序號綁 location（ImportedStaticMesh.java:29-35、VertexBufferObject.java:324-345）。
# 只有一層時 shader 讀到前一次 draw 留下的 attribute 3（FinishDraw 不關 array，VertexBufferObject.java:368-375）：
# 車上零件拿到車身同序號頂點的 UV1，貼圖亂掉、沒有任何錯誤（Tesla 輪子 2026-10-24：平灰圓片、整顆黑）。
# 做法：網格加第二層 UV，內容同第一層。
def mesh_uv_layers(path):
    with open(path, "rb") as fh:
        data = fh.read()
    if path.lower().endswith(".glb"):
        n = struct.unpack_from("<I", data, 12)[0]
        prims = [p for mm in json.loads(data[20:20 + n]).get("meshes", []) for p in mm.get("primitives", [])]
        return min((sum(k.startswith("TEXCOORD_") for k in p.get("attributes", {})) for p in prims), default=0)
    if data.startswith(b"Kaydara FBX Binary"):
        return data.count(b"\x0eLayerElementUV")  # 節點名：長度 14 緊接名稱（字串屬性值前是 4 位元組長度）
    return len(re.findall(rb"(?m)^\s*LayerElementUV:\s*\d+", data))


def model_blocks(body):
    for mm in re.finditer(r"(?m)^\s*model\s+(\w+)\s*\{", body):
        depth, i = 1, mm.end()
        while depth and i < len(body):
            depth += {"{": 1, "}": -1}.get(body[i], 0)
            i += 1
        inner = body[mm.end():i - 1]
        while re.search(r"\{[^{}]*\}", inner):
            inner = re.sub(r"\{[^{}]*\}", "", inner)
        yield mm.group(1), {k.lower(): v.strip() for k, v in re.findall(r"(\w+)\s*=\s*([^,\n]*)", inner)}


wheel_uv, model_names, model_refs = [], set(), []
for m in MEDIA_DIRS:
    sdir = os.path.join(m, "scripts")
    if not os.path.isdir(sdir):
        continue
    for f in iter_files(sdir, {".txt"}):
        with open(f, encoding="utf-8") as fh:
            body = re.sub(r"/\*.*?\*/", "", fh.read(), flags=re.S)
        model_names.update(name for name, _ in model_blocks(body))
        model_refs += [(f, name) for name in re.findall(r"(?m)^\s*file\s*=\s*(\w+)\s*,?\s*$", body)]
        for name, kv in model_blocks(body):
            if kv.get("shader", "").lower() != "vehiclewheel" or kv.get("static", "true").lower() == "false":
                continue
            for ext in (".fbx", ".glb"):
                mesh = os.path.join(m, "models_X", kv.get("mesh", "") + ext)
                if os.path.isfile(mesh) and mesh_uv_layers(mesh) < 2:
                    wheel_uv.append(f"model {name}: {_prel(mesh)} 只有 {mesh_uv_layers(mesh)} 層 UV")
_t = "vehiclewheel 模型的 FBX／GLB 有兩層 UV（引擎從第二層讀）"
fail(_t, wheel_uv) if wheel_uv else ok(_t)

# ---- 17b. 零件 `file = X` 指到的 model 要有定義 ----
# 車輛零件的 `file = X` 沒有對應的 `model X` 區塊時，那個零件在遊戲裡不畫（Tesla Model S 後輪 2026-11-13：加了
# `_WheelRear` 的 FBX、貼圖與輪胎零件，漏了 scripts/models 的 model 區塊，實機八個朝向後輪都只剩卡鉗；離線出圖
# 不讀遊戲腳本，看不出來）。只查 MOD 自己有同名網格檔的名字：指到原版 model 的不算。
_meshes = {os.path.splitext(os.path.basename(f))[0] for m in MEDIA_DIRS if os.path.isdir(os.path.join(m, "models_X"))
           for f in iter_files(os.path.join(m, "models_X"), {".fbx", ".glb", ".x"})}
model_missing = sorted({f"{_prel(f)}: file = {name} 沒有 model {name} 區塊"
                        for f, name in model_refs if name in _meshes and name not in model_names})
_t = "零件 file 指到的自家網格都有 model 區塊"
fail(_t, model_missing) if model_missing else ok(_t)

# ---- 18. server／shared 不用顯示名稱 setName（警告）----
# 伺服器端 setName 的名稱和原名不同時存進存檔、照原樣送給每個客戶端（InventoryItem.java:1711-1714 存、:2038 讀回）；
# 專用伺服器上新物品的原名是物品全名，用伺服器語言的顯示名稱 setName，所有玩家都看到伺服器語言
# （Tesla 0.1.0 正式服 2026-10-29：卡片鑰匙、手機變英文）。做法：伺服器不命名，客戶端用自己的語言命名
# （Tesla client/MinidoracatTesla/KeysUI.lua 的 UI.nameAll）。`x:setName(x:getScriptItem():getDisplayName())` 設的是
# 原名，不存不送（Bags 2026-10-30 bags-names-1030a 英文伺服器＋中文客戶端實測），不列。翻譯包這類本來就要改名的
# repo：把 finding 寫進 scripts/verify_ignore.txt（例 `setName in shared/Foo.lua:`），上一行用 # 註明理由。
# 只看參數，括號跨行也算。抓不到原版程式寫進的名字：原版 ISClothingExtraAction:createItemNew 換穿時把伺服器
# getName()（帶磨損、染血字樣）和腳本名稱比，不同就當成改名寫進新物品（ISClothingExtraAction.lua:76-79）。
_DISPLAY_NAME = re.compile(r"(?<!\w)(?:getDisplayName|getItemName|getText|getTextOrNull)\s*\(")
server_names = []
for f in LUA_FILES:
    lua_rel = os.path.relpath(f, REPO).replace(os.sep, "/").split("/lua/", 1)[-1]
    if not lua_rel.startswith(("server/", "shared/")):
        continue
    with open(f, encoding="utf-8", errors="replace") as fh:
        src = _LONG_COMMENT.sub(lambda mm: "\n" * mm.group().count("\n"), fh.read())
    code = "\n".join(line.split("--", 1)[0] for line in src.split("\n"))
    for mm in re.finditer(r"(\w[\w.]*)?:setName\s*\(", code):
        depth, i = 1, mm.end()
        while depth and i < len(code):
            depth += {"(": 1, ")": -1}.get(code[i], 0)
            i += 1
        arg = code[mm.end():i - 1]
        if mm.group(1) and re.fullmatch(rf"\s*{re.escape(mm.group(1))}\s*:\s*getScriptItem\s*\(\s*\)\s*:\s*getDisplayName\s*\(\s*\)\s*", arg):
            continue  # 設回原名
        if _DISPLAY_NAME.search(arg):
            server_names.append(f"setName in {lua_rel}:{code.count(chr(10), 0, mm.end()) + 1}")
warn("server／shared 不用顯示名稱 setName（名稱存檔並照原樣送給所有客戶端）", server_names)

# ---- 19. repo 專屬檢查（scripts/verify_local.py，選用）----
# 只有單一 MOD 用得到的檢查放那個檔，本檔照模板整份更新時才不會蓋掉它（Builder 2026-11-01：管理面板規則頁的標籤寬）。
# 它的 PASS／FAIL／SKIP／WARN 行逐行轉印並算進總結（2026-11-26 以前併成一行 PASS，裡面的 SKIP 看不出來）。
# verify_ignore.txt 不套用：ModMaps 的豁免樣式只為了模板第 3 項，套到這裡會把它真的鍵集檢查一起靜音。
_local = os.path.join(REPO, "scripts", "verify_local.py")
if os.path.isfile(_local):
    _t = "repo 專屬檢查（scripts/verify_local.py）"
    _p = subprocess.run([sys.executable, _local], cwd=REPO, capture_output=True, text=True, encoding="utf-8",
                        errors="replace", env={**os.environ, "PYTHONIOENCODING": "utf-8"})
    _lists = {"PASS": passed, "FAIL": failed, "SKIP": skipped, "WARN": warned}
    _seen = {k: 0 for k in _lists}
    print(f"  ---- {_t} ----")
    for _line in (_p.stdout + _p.stderr).splitlines():
        if not _line.strip():
            continue
        print(_line)
        _m = re.match(r"^  (PASS|FAIL|SKIP|WARN)  (\S.*)$", _line)  # 只認本檔格式，縮排的細節行（Lua 測試輸出）不計
        if _m:
            _lists[_m[1]].append(f"verify_local：{_m[2]}")
            _seen[_m[1]] += 1
    if _p.returncode and not _seen["FAIL"]:
        fail(f"{_t}：結束碼 {_p.returncode}，沒有印 FAIL 行")
    elif not any(_seen.values()):
        ok(_t)

# ---- 總結 ----
print()
print(f"PASS {len(passed)} / FAIL {len(failed)} / SKIP {len(skipped)}")
if warned:
    print(f"WARN {len(warned)}（不影響結束碼）")
sys.exit(1 if failed else 0)
