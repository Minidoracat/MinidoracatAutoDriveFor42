# -*- coding: utf-8 -*-
"""發版前驗證閘門：一次跑完全部靜態檢查，任一失敗以非零碼結束。

用法（repo 根目錄或任意位置）：
    python scripts/verify_mod.py

零設定：自動偵測 MOD/<folder>/Contents/mods/<folder>/42/。
涵蓋的檢查與其對應的實際事故（皆有反編譯出處，詳見 AGENTS.md 踩坑錄）：

  1. luac -p 語法        — 需要 PATH 有 luac；沒有則列為 SKIP 而非 PASS
  2. BOM / CRLF          — 有 BOM 或 CRLF 的翻譯檔會被引擎「靜默忽略」
  3. 翻譯鍵集一致          — 缺鍵的語系會顯示原始 key
  4. 裸 % 檢查           — 42.20.1 起 formatted() 遇裸 % 崩潰；只允許 %1-%9 與 %%
  5. Kahlua 禁用全域       — next/assert/xpcall 不存在（BaseLib 未註冊），呼叫→
                           「Object tried to call nil」。luac 與標準 Lua 測試都攔不住
                           （語法合法、標準 Lua 有這些函式），只能靜態掃描
  6. table.sort 禁用      — Kahlua 的 sort 是遞迴 quicksort（coroutine 堆疊上限 3000），
                           已排序輸入退化 O(n) 深度、數百筆即溢位；一律用迭代 merge sort
  7. MOD/ 樹雜物          — .omc/.claude/.gitnexus 目錄與 .gitkeep 檔；Workshop 整包上傳不看 .gitignore
 7b. mod.info 多值語法     — require/incompatible/load order 只接受逗號且 key 緊貼 =
  8. 佔位符殘留            — {{TOKEN}} 漏替換
  9. Steam 描述位元組      — 各語言 ≤8000 UTF-8 bytes（中日文 3 bytes/字，容易低估）
 10. 沙盒選項翻譯配對       — 每個 option 要有 Sandbox_<translation> 標題＋ _tooltip＋分頁名
 11. CHANGELOG 洩漏掃描     — bullet 會被整段貼到公開的 Workshop 更新說明；掃基礎設施
                           樣式（/home/ 路徑、IP、SteamID64、ssh、主機名）當最後防線。
                           攻擊配方與玩家識別資訊機器認不出來，靠撰寫規則（AGENTS.md）
 12. 資產／腳本交叉引用     —— item 的 Icon 要有 textures/Item_<Icon>.png（64x64 8-bit
                           RGBA）；配方 inputs/outputs 引用的本 MOD 物品要真的宣告過；
                           OnTest 的「表.函式」要在 Lua 有實作；Autopilot 配方必須消耗
                           GPS。這類漂移引擎一律靜默處理（icon 顯示問號、配方永遠湊不齊
                           材料、分佈表不生成物品），console 不一定留下訊息
 13. 沙盒選項規格          —— 17 個選項的 type/min/max/default 對表；改壞 default
                           玩家端只是「行為不對」，沒有任何錯誤訊息可查

新增檢查時：同步把對應的坑記進 AGENTS.md 踩坑錄，並依「踩坑進化協議」回流到
pz-mod-template（見 AGENTS.md）。
"""
import json
import os
import re
import shutil
import struct
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

passed, failed, skipped = [], [], []

# 豁免清單（選用）：scripts/verify_ignore.txt，每行一個子字串樣式（# 開頭為註解）。
# 命中樣式的 finding 會列出但不計 FAIL——用於「已逐一查證屬合理例外」的殘留
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


def fail(label, details=None):
    details = details or []
    kept = [d for d in details if not any(p in d for p in IGNORE_PATTERNS)]
    waived = [d for d in details if any(p in d for p in IGNORE_PATTERNS)]
    for d in waived:
        print(f"  WAIVE {label}: {d}（verify_ignore.txt 豁免）")
    if not kept:
        if waived:
            ok(f"{label}（{len(waived)} 筆豁免）")
        else:
            ok(label)
        return
    failed.append(label)
    print(f"  FAIL  {label}")
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
else:
    bad = []
    for f in LUA_FILES:
        r = subprocess.run([luac, "-p", f], capture_output=True, text=True)
        if r.returncode != 0:
            bad.append(r.stderr.strip().splitlines()[-1] if r.stderr else f)
    fail("Lua 語法（luac -p）", bad) if bad else ok(f"Lua 語法（luac -p，{len(LUA_FILES)} 檔）")

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
    mismatch, badpct, broken = [], [], []
    for n in names:
        keysets = {}
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
            for k, v in data.items():
                if find_bare_pct(v, tolerant):
                    badpct.append(f"{l}/{n} 的 {k}")
        if len(keysets) > 1:
            base = next(iter(keysets.values()))
            for l, ks in keysets.items():
                if ks != base:
                    mismatch.append(f"{n}: {l} 鍵集不一致（差 {len(ks ^ base)} 鍵）")
    if broken:
        fail("翻譯 JSON 可解析", broken)
    else:
        ok("翻譯 JSON 可解析")
    fail("翻譯鍵集一致", mismatch) if mismatch else ok(f"翻譯鍵集一致（{'/'.join(langs)}）")
    pct_label = "翻譯值無裸 %（翻譯包模式：另接受 printf 指令）" if tolerant else "翻譯值無裸 %（僅 %1-%9 與 %%）"
    fail(pct_label, sorted(set(badpct))) if badpct else ok(pct_label)

# ---- 5+6. Kahlua 禁用全域 / table.sort ----
FORBIDDEN = ("next", "assert", "xpcall")
hits_forbidden, hits_sort = [], []
for f in LUA_FILES:
    rel = os.path.relpath(f, REPO)
    with open(f, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            code = line.split("--", 1)[0]
            for name in FORBIDDEN:
                for mm in re.finditer(rf"(?<![\w_:.]){name}\s*\(", code):
                    hits_forbidden.append(f"{rel}:{lineno} 用了 {name}()")
            if re.search(r"(?<![\w_])table\.sort\s*\(", code):
                hits_sort.append(f"{rel}:{lineno}")
fail("Kahlua 禁用全域（next/assert/xpcall）", hits_forbidden) if hits_forbidden \
    else ok("Kahlua 禁用全域（next/assert/xpcall）")
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
# ---- 7b. mod.info 依賴語法 ----
# ChooseGameInfo.java:224/226/228/230 用 contains("key=") 後直接 split(",")：
# key 前可有空白，但不能有註解/其他文字；key 與 = 間不能有空格；值不能帶行尾註解。
manifest_bad = []
required_deps = {"MinidoracatUIFor42", "MinidoracatMiniMapFor42"}
multi_keys = ("require", "incompatible", "loadModAfter", "loadModBefore")
canonical_re = re.compile(
    r"^\s*(require|incompatible|loadModAfter|loadModBefore)=(.*)$")
for m in MEDIA_DIRS:
    info = os.path.join(os.path.dirname(m), "mod.info")
    rel_info = os.path.relpath(info, REPO)
    if not os.path.isfile(info):
        manifest_bad.append(f"缺 mod.info: {rel_info}")
        continue
    with open(info, encoding="utf-8") as fh:
        lines = [(lineno, line.rstrip("\r\n")) for lineno, line in enumerate(fh, 1)
                 if line.strip()]
    fields = {key: [] for key in multi_keys}
    for lineno, line in lines:
        for key in multi_keys:
            marker = key + "="
            if marker in line:
                match = canonical_re.match(line)
                if not match or match.group(1) != key:
                    manifest_bad.append(
                        f"{rel_info}:{lineno}: {key}= 前不得有註解或其他文字")
                    continue
                value = match.group(2)
                fields[key].append(value)
                if "#" in value:
                    manifest_bad.append(
                        f"{rel_info}:{lineno}: mod.info 不支援 {key} 行尾註解")
                if ";" in value:
                    manifest_bad.append(
                        f"{rel_info}:{lineno}: {key} 多值必須用逗號，不是分號")
            elif re.search(rf"{key}\s+=", line):
                manifest_bad.append(
                    f"{rel_info}:{lineno}: {key}= 鍵名與等號間不得有空格")
    require_lines = fields["require"]
    if len(require_lines) != 1:
        manifest_bad.append(f"{rel_info}: require= 必須恰有一行")
        raw_require = ""
    else:
        raw_require = require_lines[0]
    deps = {value.strip() for value in raw_require.split(",") if value.strip()}
    missing = sorted(required_deps - deps)
    if missing:
        manifest_bad.append(f"{rel_info}: 缺 require {', '.join(missing)}")
    incompatible = {item.strip() for value in fields["incompatible"]
                    for item in value.split(",") if item.strip()}
    if "Navigator" not in incompatible:
        manifest_bad.append(f"{rel_info}: 缺 incompatible=Navigator")
fail("mod.info 依賴／衝突語法", manifest_bad) if manifest_bad \
    else ok("mod.info 依賴／衝突語法")

# ---- 8. 佔位符殘留 ----
tokens = []
SELF = os.path.abspath(__file__)   # 本檔 docstring 有 {{TOKEN}} 範例字樣，排除自己
for base, dirs, files in os.walk(REPO):
    dirs[:] = [d for d in dirs if d not in (".git", ".omc", ".claude", ".gitnexus", "__pycache__")]
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

# ---- 11. CHANGELOG 洩漏掃描 ----
LEAK_PATTERNS = [
    (re.compile(r"/home/\w+"), "Linux 家目錄路徑"),
    (re.compile(r"[A-Z]:\\Users\\"), "Windows 使用者路徑"),
    (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), "IPv4 位址"),
    (re.compile(r"\b7656\d{13}\b"), "SteamID64"),
    (re.compile(r"\bssh\b", re.IGNORECASE), "ssh 字樣"),
    (re.compile(r"pz-?server", re.IGNORECASE), "伺服器主機名"),
]
_cl = os.path.join(REPO, "CHANGELOG.md")
if os.path.isfile(_cl):
    leaks = []
    with open(_cl, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            for pat, desc in LEAK_PATTERNS:
                mm = pat.search(line)
                if mm:
                    leaks.append(f"CHANGELOG.md:{lineno} {desc}（{mm.group()[:40]}）")
    fail("CHANGELOG 無基礎設施洩漏樣式", leaks) if leaks else ok("CHANGELOG 無基礎設施洩漏樣式")

# ---- 12. M2 資產／腳本交叉引用 ----
# 只做「機器認得出來」的那半：icon 檔規格、item fullType、OnTest callback、配方進度閘門。
# 刻意**不**重作 B42 的 script parser——不解析 imports / template / override，也不讀原版
# media/scripts，因此只驗證本 MOD 命名空間內的引用（原版 Base.* 一律放行）。引擎對這類
# 漂移全部靜默：icon 找不到就顯示問號、配方引用不存在的物品就永遠湊不齊材料、OnTest 解析
# 不到當成沒有可用材料，console 不一定留訊息。實機 smoke（scripts/smoke_harness.lua）
# 仍然是權威，這裡只是把靜態可判定的部分前移到發版閘門。
#
# 待辦：本節**尚未植入違規驗證**。需逐項故意改壞（錯 Icon 名、刪 PNG、改 item fullType、
# 改 OnTest 函式名、拿掉 Autopilot 的 GPS 輸入、改 sandbox default）確認各自 FAIL 再還原；
# 這必須在沒有其他人同時改檔的乾淨工作區單獨跑，故新增當下不執行。
VANILLA_NS = {"Base"}       # 原版命名空間：本檔不讀原版 scripts，無從驗證，放行
ICON_SIZE = 64              # 原版背包 icon 一律 64x64；scripts/icon/ 來源也輸出這個規格
ICON_PNG = (8, 6)           # PNG IHDR 的 (bit depth, colour type)：8-bit RGBA
# 進度閘門：自駕模組是 GPS 的升級品，配方必須真的把 GPS 吃掉（mode:keep 不算消耗）
RECIPE_MUST_CONSUME = {"CraftAutopilotModule": "GPSNavigator"}
BARE_TYPE_RE = re.compile(r"([A-Za-z]\w*(?:\.\w+)?)(?![\w.\[])")
ITEM_ENTRY_RE = re.compile(r"(?m)^\s*item\s+\d+\s+(.+?)\s*,?\s*$")


def take_block(text, at):
    """text[at] 必須是 '{'；用深度計數回傳區塊內容，巢狀 inputs{} 不會被提早截斷。"""
    depth = 0
    for i in range(at, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[at + 1:i]
    return text[at + 1:]


def parse_blocks(text, keyword):
    """掃 `<keyword> <名稱> { … }`，回傳 [(名稱, 內容)]。"""
    return [(mm.group(1), take_block(text, mm.end() - 1))
            for mm in re.finditer(rf"(?<![\w.]){keyword}\s+([\w.]+)\s*\{{", text)]


def sub_block(body, keyword):
    """取無名子區塊（inputs / outputs）的內容。"""
    mm = re.search(rf"(?<![\w.]){keyword}\s*\{{", body)
    return take_block(body, mm.end() - 1) if mm else ""


def parse_fields(body):
    """`Key = value,` 逐項擷取；先剝掉子區塊，免得把 inputs 內容當成欄位。"""
    while True:
        stripped = re.sub(r"\{[^{}]*\}", "", body)
        if stripped == body:
            break
        body = stripped
    return {k: v.strip() for k, v in re.findall(r"(\w+)\s*=\s*([^,\r\n]*)", body)}


def parse_recipe_items(block, module):
    """回傳 [(fullTypes, 原文)]。tags[…] 輸入沒有具體物品，fullTypes 為空。"""
    out = []
    for mm in ITEM_ENTRY_RE.finditer(block):
        rest = mm.group(1)
        br = re.search(r"(?<!\w)\[([^\]]+)\]", rest)   # `[A;B]`；flags[…]/tags[…] 前有字母，不算
        if br:
            raw = br.group(1)
        else:
            bare = BARE_TYPE_RE.match(rest)
            raw = bare.group(1) if bare else ""
        # 不帶模組前綴的名字由引擎補上所在 module——這裡照做，才抓得到未加前綴的錯字
        types = [t if "." in t else f"{module}.{t}"
                 for t in (s.strip() for s in raw.split(";")) if t]
        out.append((types, rest))
    return out


def png_spec(path):
    """回傳 (寬, 高, bit depth, colour type)；不是 PNG 則回 None。"""
    with open(path, "rb") as fh:
        head = fh.read(26)
    if len(head) < 26 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        return None
    w, h = struct.unpack(">II", head[16:24])
    return w, h, head[24], head[25]


LUA_SRC = ""
for f in LUA_FILES:
    with open(f, encoding="utf-8") as fh:
        LUA_SRC += fh.read()

for m in MEDIA_DIRS:
    sdir = os.path.join(m, "scripts")
    if not os.path.isdir(sdir):
        continue
    declared, recipes, modules = {}, [], set()
    for f in sorted(iter_files(sdir, {".txt"})):
        rel = os.path.relpath(f, REPO)
        with open(f, encoding="utf-8") as fh:
            text = re.sub(r"/\*.*?\*/", "", fh.read(), flags=re.S)
        for mod, mbody in parse_blocks(text, "module"):
            modules.add(mod)
            for name, ibody in parse_blocks(mbody, "item"):
                declared[f"{mod}.{name}"] = (parse_fields(ibody).get("Icon"), rel)
            for name, rbody in parse_blocks(mbody, "craftRecipe"):
                recipes.append((mod, name, rbody, rel))
    if not declared and not recipes:
        continue

    # 12a. Icon → textures/Item_<Icon>.png
    tex = os.path.join(m, "textures")
    bad = []
    for full, (icon, rel) in sorted(declared.items()):
        if not icon:
            bad.append(f"{rel}: {full} 沒有 Icon 欄位（背包會顯示問號）")
            continue
        p = os.path.join(tex, f"Item_{icon}.png")
        if not os.path.isfile(p):
            bad.append(f"{full}: Icon = {icon}，但缺 textures/Item_{icon}.png")
            continue
        spec = png_spec(p)
        if spec is None:
            bad.append(f"textures/Item_{icon}.png 不是合法 PNG")
        elif spec != (ICON_SIZE, ICON_SIZE, *ICON_PNG):
            bad.append(f"textures/Item_{icon}.png 是 {spec[0]}x{spec[1]} depth={spec[2]} "
                       f"colour={spec[3]}，要 {ICON_SIZE}x{ICON_SIZE} depth=8 colour=6（RGBA）")
    fail("物品 Icon 有對應 64x64 RGBA PNG", bad) if bad \
        else ok(f"物品 Icon 有對應 64x64 RGBA PNG（{len(declared)} 物品）")

    # 12b/c/d. 配方物品引用 / OnTest 實作 / 進度閘門
    bad_ref, bad_cb, bad_gate = [], [], []
    for mod, name, rbody, rel in recipes:
        fields = parse_fields(rbody)
        inputs = parse_recipe_items(sub_block(rbody, "inputs"), mod)
        for types, _raw in inputs + parse_recipe_items(sub_block(rbody, "outputs"), mod):
            for t in types:
                ns = t.split(".", 1)[0]
                if ns in VANILLA_NS:
                    continue
                if ns not in modules:
                    bad_ref.append(f"{rel}: {name} 引用未知命名空間 {t}"
                                   "（跨 MOD 相依請寫進 verify_ignore.txt 並註明查證依據）")
                elif t not in declared:
                    bad_ref.append(f"{rel}: {name} 引用不存在的物品 {t}")
        cb = fields.get("OnTest")
        if cb and not re.search(rf"function\s+{re.escape(cb)}\s*\(|{re.escape(cb)}\s*=\s*function",
                                LUA_SRC):
            bad_cb.append(f"{rel}: {name} 的 OnTest = {cb} 在 Lua 找不到實作"
                          "（引擎解析不到會當成沒有可用材料，靜默鎖死配方）")
        want = RECIPE_MUST_CONSUME.get(name)
        if want:
            full = f"{mod}.{want}"
            hits = [raw for types, raw in inputs if full in types]
            if not hits:
                bad_gate.append(f"{name} 的 inputs 沒有 {full}")
            elif all("mode:keep" in raw for raw in hits):
                bad_gate.append(f"{name} 的 {full} 是 mode:keep，沒有真的被消耗")
    bad_ref = sorted(set(bad_ref))
    fail("配方物品引用存在", bad_ref) if bad_ref else ok(f"配方物品引用存在（{len(recipes)} 配方）")
    fail("配方 OnTest 有 Lua 實作", bad_cb) if bad_cb else ok("配方 OnTest 有 Lua 實作")
    fail("配方進度閘門（升級配方消耗前一階物品）", bad_gate) if bad_gate \
        else ok("配方進度閘門（升級配方消耗前一階物品）")

    # 12e. Lua／翻譯檔字串裡的 fullType（分佈表、MDAD.TYPE_*、ItemName.json）
    bad_use = []
    for f in iter_files(m, {".lua", ".json"}):
        rel = os.path.relpath(f, REPO)
        with open(f, encoding="utf-8") as fh:
            txt = fh.read()
        for mod in sorted(modules):
            for mm in re.finditer(rf'"({re.escape(mod)}\.\w+)"', txt):
                if mm.group(1) not in declared:
                    bad_use.append(f"{rel}: 參照不存在的物品 {mm.group(1)}")
    bad_use = sorted(set(bad_use))
    fail("Lua／翻譯參照的物品存在", bad_use) if bad_use else ok("Lua／翻譯參照的物品存在")

# ---- 13. 沙盒選項規格 ----
# type/min/max/default 對表。改壞 default 玩家端只會覺得「行為不對」，改壞 min/max 則是
# 管理員拉不到本來能設的值——都沒有錯誤訊息，只能靠對表擋。新增或調整選項時這張表要跟
# sandbox-options.txt 一起改（刻意讓它先擋一次，逼人確認改動是有意的）。
SANDBOX_MODULE = "MinidoracatAutoDrive"
SANDBOX_SPEC = {                            # key: (type, default, min, max)
    "NeedItemForNav":       ("boolean", "false", None, None),
    "NeedItemForAutoDrive": ("boolean", "true", None, None),
    "AllowCraftGPS":        ("boolean", "true", None, None),
    "AllowCraftAutopilot":  ("boolean", "true", None, None),
    "SpawnGPS":            ("boolean", "true", None, None),
    "SpawnAutopilot":      ("boolean", "true", None, None),
    "GPSPowerPercent":     ("integer", "100", "0", "500"),
    "AutoDrivePowerPercent": ("integer", "100", "0", "500"),
    "GPSFuelPercent":      ("integer", "100", "0", "500"),
    "AutoDriveFuelPercent": ("integer", "100", "0", "500"),
    "InstallSkillGate":     ("boolean", "true", None, None),
    "AutoDriveMaxSpeed":    ("integer", "70", "5", "120"),
    "ZombieAreaSlowdown":   ("enum", "2", None, None),
    "CorpseSlowdown":       ("enum", "2", None, None),
    "ObstaclePolicy":       ("enum", "1", None, None),
    "RightLaneBias":        ("double", "1.0", "0.0", "2.0"),
    "DebugOverlay":         ("boolean", "false", None, None),
}
for m in MEDIA_DIRS:
    sb = os.path.join(m, "sandbox-options.txt")
    if not os.path.isfile(sb):
        continue
    with open(sb, encoding="utf-8") as fh:
        blocks = parse_blocks(re.sub(r"/\*.*?\*/", "", fh.read(), flags=re.S), "option")
    mine = {n.split(".", 1)[-1]: parse_fields(b)
            for n, b in blocks if n.startswith(SANDBOX_MODULE + ".")}
    if not mine:
        skip("沙盒選項規格（型別／範圍／預設）", f"沒有 {SANDBOX_MODULE}.* 選項")
        continue
    diff = [f"{k}: sandbox-options.txt 缺這個選項" for k in sorted(set(SANDBOX_SPEC) - set(mine))]
    diff += [f"{k}: 不在規格表（新增選項要同步更新 verify_mod.py 的 SANDBOX_SPEC）"
             for k in sorted(set(mine) - set(SANDBOX_SPEC))]
    for k in sorted(set(SANDBOX_SPEC) & set(mine)):
        want, got = SANDBOX_SPEC[k], mine[k]
        for idx, field in enumerate(("type", "default", "min", "max")):
            if want[idx] is not None and got.get(field) != want[idx]:
                diff.append(f"{k}: {field} = {got.get(field)}，規格是 {want[idx]}")
        if want[2] is None and ("min" in got or "max" in got):
            diff.append(f"{k}: boolean 選項不該有 min/max")
    fail("沙盒選項規格（型別／範圍／預設）", diff) if diff \
        else ok(f"沙盒選項規格（{len(mine)} 選項）")

# ---- 總結 ----
print()
print(f"PASS {len(passed)} / FAIL {len(failed)} / SKIP {len(skipped)}")
sys.exit(1 if failed else 0)
