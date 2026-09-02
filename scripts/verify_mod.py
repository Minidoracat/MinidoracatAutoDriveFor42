# -*- coding: utf-8 -*-
"""發版前驗證閘門：一次跑完全部靜態檢查，任一失敗以非零碼結束。

用法（repo 根目錄或任意位置）：
    python scripts/verify_mod.py
    python scripts/verify_mod.py --self-test   # 快速迴圈：只跑 parser helper 自測＋1b 閘門
                                               # 自測後早退，不掃 repo（完整執行涵蓋全部）

零設定：自動偵測 MOD/<folder>/Contents/mods/<folder>/42/。
涵蓋的檢查與其對應的實際事故（皆有反編譯出處，詳見 AGENTS.md 踩坑錄）：

  1. luac -p 語法        — 需要 PATH 有 luac；沒有則列為 SKIP 而非 PASS
 1b. Kahlua 結構上限      — 單一 function >60 upvalues 或 >190 locals 是**載入期編譯
                           失敗**（整個 chunk 不執行、命名空間不存在，依賴它的檔案
                           每幀噴 nil）。luac -p 照過，只有 luac -l 的槽數看得到。
                           因為它的失效模式是「靜默永遠 PASS」，每次執行都先自測
                           parser 樣本＋luac 失敗路徑＋真實編譯的邊界值，自測不過就
                           不掃檔案；luac 失敗／空輸出／解析不到 function 標頭一律
                           FAIL，PASS 訊息會報實際比對過的 function 數
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
                           OnTest 的「表.函式」要在 Lua 有實作；Autopilot 配方必須以
                           destroy mode＋ItemCount＋數量 1＋排他候選消耗 GPS，且拒任何
                           電量狀態 flag（IsFull/IsEmpty/NotFull/NotEmpty）；mode 解析
                           逐項對齊引擎 parser（key 字面敏感、值大小寫不敏感、use 為
                           no-op、非法值＝載入期炸整條配方）；本 MOD drainable 輸入須
                           ItemCount 或 IsFull/NotEmpty，非 destroy 時另要求物品宣告
                           KeepOnDeplete（正式服 39 個空電 GPS 連坐全滅事故）。這類
                           漂移引擎一律靜默處理（icon 顯示問號、配方永遠湊不齊材料、
                           分佈表不生成物品），console 不一定留下訊息
 13. 沙盒選項規格          —— 17 個選項的 type/min/max/default 對表；改壞 default
                           玩家端只是「行為不對」，沒有任何錯誤訊息可查
 14. 配方學習鏈          —— 兩個配方必須留在 module Base（無點短名只會在 Base 查表）、
                           NeedToBeLearn／SkillRequired／AutoLearnAny／ResearchSkillLevel
                           對表、專屬手冊的 ItemType／OnCreate／LearnedRecipes 與兩個
                           成品的 Researchablerecipes 必須是精確的短名清單。整條鏈的每一種漂移
                           都是靜默失敗：引擎把查不到的配方名照抄進表，玩家永遠學不到，
                           console 也不留訊息（「做得出來但零產出」的成因）
 15. Phase 1 telemetry 靜態契約 — 新模組檔、HUD 選項／reader、翻譯鍵必須存在；
                           聚焦測試檔列入閘門但只檢查存在、不執行（主流程才跑）

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
import tempfile

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

# ---- 1b 用：Kahlua 結構上限 ----
# Kahlua（PZ 的 Lua 執行期，Lua 5.1 語義）對單一 function 的槽數有硬上限，超過不是
# 執行期例外而是**載入期編譯失敗**：整個 chunk 一行都不跑，命名空間根本沒建起來，
# 依賴它的檔案接著每幀噴 nil。2026-08-31 實機：
#   KahluaException MDAD_Driver.lua:4182: function at line 3207 has more than
#   60 upvalues  → MDAD.Drive == nil → HUD 每 250ms 一輪
#   "attempted index: hudState of non-table: null" 洗爆 console。
# luac -p 只驗語法，這種超限它照過；luac -l 會把每個 function 的 upvalue／local
# 槽數列在標頭行，靜態就能判定。兩個上限取 Lua 5.1 的原始值：
#   upvalues 60 = LUAI_MAXUPVALUES（Kahlua 訊息就是 "more than 60"，61 才爆）
#   locals  190 = LUAI_MAXVARS(200) 留 10 槽餘裕（同一個 function 再長一點就撞牆）
# 計數方向刻意保守（只會誤報、不會漏報）：luac 5.4 把 _ENV 也算一個 upvalue，
# locals 欄位算的是「整個 function 宣告過的 local 總數」而非 5.1 的同時存活數，
# 兩者都 ≥ Kahlua 的實際用量。修法是把非熱幀常數收成一張 table（一個槽承載全部），
# 見 MDAD_Driver.lua 的 TUNE。
#
# 這個閘門唯一該怕的失效模式是**靜默永遠 PASS**：regex 對不上、luac 換版改標頭、
# luac 這次沒吐東西——掃遍全 repo 也只會印一行 PASS，比沒有閘門更糟（有人信它）。
# 所以三道反制全部必要，缺一不可：① 每次跑都先自測邊界值（不只 --self-test）；
# ② 每個檔案都必須真的解析出 ≥1 個 function 標頭，0 個＝格式漂移＝FAIL；
# ③ luac 失敗／空輸出一律 FAIL，不 continue（沉默地跳過就是漏報）。
# 標頭措辭跨版本不同，兩種都吃：Lua 5.1 印 "N stacks"、5.2+ 印 "N slots"，
# 且數量為 1 時全部退化成單數（"1 upvalue"、"1 local"）。
KAHLUA_MAX_UPVALUES = 60
KAHLUA_MAX_LOCALS = 190
KAHLUA_PROTO_RE = re.compile(r"^(?:main|function) <.+:(\d+),(\d+)> \(\d+ instruction")
KAHLUA_SLOT_RE = re.compile(
    r"^\d+\+? params?, \d+ (?:slot|stack)s?, (\d+) upvalues?, (\d+) locals?,")


def kahlua_listing(luac_bin, path):
    """回傳 (listing, err)。err 非 None 代表拿不到可信列表，呼叫端必須當失敗處理。"""
    r = subprocess.run([luac_bin, "-p", "-l", path], capture_output=True, text=True)
    if r.returncode != 0:
        tail = (r.stderr or r.stdout or "").strip().splitlines()
        return None, f"luac -p -l 退出碼 {r.returncode}：{tail[-1] if tail else '無輸出'}"
    if not r.stdout.strip():
        return None, "luac -p -l 沒有輸出任何 function 列表（版本不支援？）"
    return r.stdout, None


def kahlua_over_limit(listing, label):
    """回傳 (findings, protos)：超限清單與**實際解析到**的 function 標頭數。

    protos 是給呼叫端判斷「有沒有真的看懂列表」用的——沒有它，格式漂移會讓
    findings 永遠是空清單而看起來像全部合格。
    """
    out, protos, where = [], 0, None
    for line in listing.splitlines():
        mm = KAHLUA_PROTO_RE.match(line)
        if mm:
            protos += 1
            where = f"{label}:{mm.group(1)}-{mm.group(2)}"
            continue
        mm = KAHLUA_SLOT_RE.match(line)
        if not mm or where is None:
            continue
        ups, locs = int(mm.group(1)), int(mm.group(2))
        if ups > KAHLUA_MAX_UPVALUES:
            out.append(f"{where}: {ups} upvalues（上限 {KAHLUA_MAX_UPVALUES}）")
        if locs > KAHLUA_MAX_LOCALS:
            out.append(f"{where}: {locs} locals（上限 {KAHLUA_MAX_LOCALS}）")
        where = None
    return out, protos


# 解析器的固定樣本：跨 luac 版本的措辭與單複數各驗一次，不依賴本機裝的是哪一版。
# (標籤, 列表文字, 期望 protos, 期望 findings 筆數)
KAHLUA_MOCK_LISTINGS = (
    ("5.1 複數＋stacks＋超限", """
main <t.lua:0,0> (5 instructions, 20 bytes at 0x1)
0+ params, 2 stacks, 1 upvalue, 2 locals, 0 constants, 1 function

function <t.lua:2,9> (3 instructions, 12 bytes at 0x2)
0 params, 2 stacks, 61 upvalues, 3 locals, 0 constants, 0 functions
""", 2, 1),
    ("5.4 單數＋slots＋合格", """
main <t.lua:0,0> (5 instructions at 0x1)
0+ params, 2 slots, 1 upvalue, 2 locals, 0 constants, 1 function

function <t.lua:2,2> (3 instructions at 0x2)
0 params, 2 slots, 60 upvalues, 190 locals, 0 constants, 0 functions
""", 2, 0),
    ("locals 超限", """
function <t.lua:7,80> (9 instructions at 0x3)
2 params, 9 slots, 3 upvalues, 191 locals, 1 constant, 0 functions
""", 1, 1),
    ("同一 function 兩項都超限", """
function <t.lua:1,2> (9 instructions at 0x4)
0 params, 9 slots, 61 upvalues, 191 locals, 1 constant, 0 functions
""", 1, 2),
    ("格式漂移（認不出標頭）", "some future luac wrote something else entirely\n", 0, 0),
)


def kahlua_selftest(luac_bin):
    """驗「閘門本身有效」：parser 對固定樣本、luac 失敗路徑、真實編譯的邊界值。

    回傳問題清單（空＝閘門可信）。檔案掃描前一定會先跑這個，自測不過就不准
    宣稱任何檔案合格。
    """
    bad = []
    for label, listing, want_protos, want_findings in KAHLUA_MOCK_LISTINGS:
        findings, protos = kahlua_over_limit(listing, label)
        if protos != want_protos:
            bad.append(f"樣本「{label}」: 解析到 {protos} 個 function 標頭"
                       f"，期望 {want_protos}")
        if len(findings) != want_findings:
            bad.append(f"樣本「{label}」: {len(findings)} 筆 finding"
                       f"，期望 {want_findings}；實得 {findings or '無'}")
    cases = []
    for n in (KAHLUA_MAX_UPVALUES, KAHLUA_MAX_UPVALUES + 1):
        names = [f"u{i}" for i in range(n)]
        src = "".join(f"local {x} = 1\n" for x in names) \
            + f"local function f() return {' + '.join(names)} end\nreturn f\n"
        cases.append((f"{n}-upvalue", src, n > KAHLUA_MAX_UPVALUES))
    for n in (KAHLUA_MAX_LOCALS, KAHLUA_MAX_LOCALS + 1):
        body = "".join(f"    local v{i} = 1\n" for i in range(n))
        cases.append((f"{n}-local",
                      f"local function g()\n{body}    return v0\nend\nreturn g\n",
                      n > KAHLUA_MAX_LOCALS))
    with tempfile.TemporaryDirectory() as tmp:
        # luac 失敗路徑：檔案不存在與語法壞掉都必須回 err，不能被當成「沒有超限」
        missing, err = kahlua_listing(luac_bin, os.path.join(tmp, "nope.lua"))
        if missing is not None or not err:
            bad.append("luac 失敗路徑: 不存在的檔案沒有回報錯誤")
        broken = os.path.join(tmp, "broken.lua")
        with open(broken, "w", encoding="utf-8") as fh:
            fh.write("local = = end\n")
        listing, err = kahlua_listing(luac_bin, broken)
        if listing is not None or not err:
            bad.append("luac 失敗路徑: 語法錯誤的檔案沒有回報錯誤")
        for name, src, want_block in cases:
            p = os.path.join(tmp, f"{name}.lua")
            with open(p, "w", encoding="utf-8") as fh:
                fh.write(src)
            listing, err = kahlua_listing(luac_bin, p)
            if listing is None:
                # 本機 luac 是 Lua 5.1（上限與 Kahlua 相同）時，超限樣本會被
                # 編譯器自己擋下——這正是要防的事發生了，算通過；
                # 但「應該合格」的樣本編不出來就是閘門或環境有問題。
                if want_block:
                    continue
                bad.append(f"{name}: 應可編譯卻失敗（{err}）")
                continue
            findings, protos = kahlua_over_limit(listing, name)
            if protos == 0:
                bad.append(f"{name}: 解析不到 function 標頭（luac 列表格式已改？）")
                continue
            if bool(findings) != want_block:
                bad.append(f"{name}: 期望{'擋下' if want_block else '放行'}"
                           f"，實得 {findings or '放行'}")
    return bad


KAHLUA_SELFTEST_LABEL = (f"Kahlua 結構上限閘門自測（parser 樣本 "
                         f"{len(KAHLUA_MOCK_LISTINGS)} 組、luac 失敗路徑、邊界 "
                         f"{KAHLUA_MAX_UPVALUES}/{KAHLUA_MAX_UPVALUES + 1} upvalues、"
                         f"{KAHLUA_MAX_LOCALS}/{KAHLUA_MAX_LOCALS + 1} locals）")


# 引擎逐 token 解析輸入行（InputScript.java:617 起 split 空白）：mode 的 key 是字面
# `mode:`（大小寫敏感，:666 startsWith），值才 equalsIgnoreCase（:670-674）；沒寫
# mode 是 ItemApplyMode.Normal（:68）；真正會賦值的只有 keep／destroy（:672、:674）
# ——`mode:use` 落在守衛外、deprecated 的 useprop*/keepprop*/prop* 只印 error，
# 全部**不**覆寫前值（:670、:675-686）；**非法值與 unknown token 在遇到的當下就
# throw**（:687、:762）——載入期炸整條配方，閘門必須逐 token 驗證而非只看最終值。
# 適用前提：輸入行無 `+`/`-` 續行——`+` 續行在 OnPostWorldDictionaryInit
# 無條件把 mode 覆寫成 Keep（InputScript.java:817）；`-` 續行僅在非 Destroy 時轉
# Keep（:834-835，Destroy 保留）；本 repo 目前無續行輸入。
VALID_ITEM_MODES = {"use", "keep", "destroy", "useprop1", "useprop2",
                    "keepprop1", "keepprop2", "prop1", "prop2"}
# InputFlag 全枚舉（42.20.4 InputFlag.java 逐字抄錄；引擎 valueOf 大小寫敏感無 trim）。
# 引擎升版新增 flag 時這裡會假紅——寧紅勿綠，補名單即可。
INPUT_FLAGS = {
    "HandcraftOnly", "AutomationOnly", "IsFull", "NotFull", "ItemIsUses",
    "ItemIsFluid", "ItemIsEnergy", "IsEmpty", "NotEmpty", "Prop1", "Prop2",
    "ToolLeft", "ToolRight", "IsDamaged", "IsUndamaged", "IsWholeFoodItem",
    "IsEmptyContainer", "IsUncookedFoodItem", "IsCookedFoodItem", "IsNotDull",
    "IsHeadPart", "IsSharpenable", "DontPutBack", "InheritColor",
    "InheritCondition", "InheritEquipped", "InheritSharpness",
    "InheritHeadCondition", "MayDegrade", "MayDegradeLight",
    "MayDegradeVeryLight", "MayDegradeHeavy", "SharpnessCheck", "InheritUses",
    "InheritUsesAndEmpty", "InheritFood", "InheritFoodAge", "InheritCooked",
    "InheritModelVariation", "InheritWeight", "InheritName",
    "InheritFreezingTime", "DontInheritCondition", "AllowFrozenItem",
    "AllowRottenItem", "NoBrokenItems", "AllowDestroyedItem", "IsWorn",
    "IsNotWorn", "InheritAmmunition", "CopyClothing", "AllowFavorite",
    "InheritFavorite", "FakeOutput", "DontReplace", "CanBeDoneFromFloor",
    "ItemCount", "IsExclusive", "RecordInput", "DontRecordInput",
    "ResearchInput", "IsBlunt", "HasOneUse", "HasNoUses", "IsSealed",
    "IsNotSealed", "Unseal", "EquipSecondary", "SetActivated",
}


def input_modes(raw):
    """有序回傳同行全部 mode: token 的值（lower）。"""
    return [tok[5:].rstrip(",").lower() for tok in raw.split()
            if tok.startswith("mode:")]


def input_mode(raw):
    mode = "normal"
    for v in input_modes(raw):
        if v in ("keep", "destroy"):   # 只有這兩值真賦值；use 與 deprecated prop* 皆 no-op
            mode = v
    return mode


def _bracket_union(raw, key):
    """收集同行所有 `key…[...]` token 的分號項聯集。引擎以「token 起點」startsWith
    分派（InputScript.java:722 tags、:742 flags），`flags-extra[...]` 這類任意後綴
    也算同類 token，且逐 token 累積（:746-750 迴圈 input.flags.add）。起點必須是
    空白邊界：`[GPS]flags[X]` 是單一 token、引擎走 selector 分支，flags 靜默丟失
    ——regex 用 (?<!\\w) 會誤抽。各項刻意不 strip：flags 走 InputFlag.valueOf
    無 trim（:748）。"""
    out = set()
    for mm in re.finditer(rf"(?:^|(?<=\s)){key}[^\s\[\]]*\[([^\]]+)\]", raw):
        out.update(mm.group(1).split(";"))
    return out


def input_flags(raw):
    return _bracket_union(raw, "flags")


def norm_tag(t, trim=True):
    """tag／ItemType 值走 ResourceLocation.of：lower＋無 namespace 補 base:
    （ResourceLocation.java:18-19、:26-29）。trim 只對 item 側 Tags 欄位成立
    （Item.java:2345 逐項 trim）；輸入行 tags[...] 的項目引擎**不** trim
    （InputScript.java:727-732 原樣餵 ResourceLocation.of）——input 側呼叫
    要傳 trim=False，帶空白的項目與引擎一樣永不命中。"""
    if trim:
        t = t.strip()
    t = t.lower()
    return t if ":" in t else f"base:{t}"


def field_get(fields, key, default=""):
    """欄位名大小寫不敏感讀取——引擎 DoParam 逐欄位 equalsIgnoreCase、單值欄位
    後蓋前（Item.java:1970、:2341；CraftRecipe.LoadMainBlock:369-496 同）。
    parse_fields 已把 key 統一成 lower（唯一 key、天然 last-wins），這裡 O(1) 查。"""
    return fields.get(key.lower(), default)


def _java_float(s):
    """Java Float.parseFloat 的近似：Python float 另接受引擎合法的 f/F/d/D 尾綴
    （`1.0f`）。回 float 或 None（None＝引擎 NumberFormatException）。"""
    if s and s[-1] in "fFdD" and len(s) > 1:
        s = s[:-1]
    try:
        return float(s)
    except ValueError:
        return None


def amount_load_error(amt_raw):
    """引擎數量解析（InputScript.java:588-599）：contains("variable")（不是
    startsWith）走 `[lo:hi]` 兩個 Float.parseFloat（:592-595，缺括號 substring
    越界、缺第二值 values[1] 越界、非 float 皆炸）；否則整值 parseFloat（:597）。
    回錯誤描述或 None。"""
    if "variable" in amt_raw:
        lb, rb = amt_raw.find("["), amt_raw.find("]")
        if lb < 0 or rb < lb:
            return "variable 數量缺括號（substring 越界炸，InputScript.java:592）"
        parts = amt_raw[lb + 1:rb].split(":")
        if len(parts) < 2:
            return "variable 數量缺上限（values[1] 越界炸，InputScript.java:595）"
        for p in parts[:2]:
            if _java_float(p) is None:
                return f"variable 數量 `{p}` 非 float（parseFloat 炸，InputScript.java:594-595）"
        return None
    if _java_float(amt_raw) is None:
        return "數量非數值（Float.parseFloat 炸，InputScript.java:597）"
    return None


def field_show(fields, key):
    """診斷訊息用：區分「未宣告」與「宣告了空值」（判定邏輯仍走 field_get）。"""
    return repr(field_get(fields, key)) if key.lower() in fields else "(未宣告)"


def _bracket_body(t, what, errs):
    """token 內 `[...]` 取值；缺括號＝引擎 substring 越界炸（selector :620、
    tags :727、flags :743、mappers :752 同型）。回 None 表示已記錯誤。"""
    lb, rb = t.find("["), t.find("]")
    if lb < 0 or rb < lb:
        errs.append(f"`{t}`：{what} 缺括號（substring 越界炸）")
        return None
    return t[lb + 1:rb]


def input_line_load_errors(raw):
    """模擬引擎 InputScript.Load 對 Item 配方輸入行的**載入期 throw** 路徑
    （InputScript.java:619-766 的 token 分派）。回傳錯誤清單；空＝可載入。
    任一 throw 都是整條配方不存在——玩家端零訊息，只能靜態擋。"""
    errs = []
    for tok in raw.split():
        t = tok.rstrip(",")
        if not t:
            continue
        if t.startswith("["):
            _bracket_body(t, "item selector", errs)
        elif t.startswith("shapedIndex:"):
            # Integer.parseInt 接受 +/- 前綴但限 32-bit（溢位＝NumberFormatException）
            sv = t[12:]
            if (not re.fullmatch(r"[+-]?\d+", sv)
                    or not -2147483648 <= int(sv) <= 2147483647):
                errs.append(f"`{t}`：shapedIndex 非 32-bit 整數（Integer.parseInt 炸，:659）")
        elif t.startswith("apply:"):
            errs.append(f"`{t}`：apply 已停用（引擎 throw，InputScript.java:663）")
        elif t.startswith("mode:"):
            if t[5:].lower() not in VALID_ITEM_MODES:
                errs.append(f"`{t}`：非法 mode 值（引擎 throw，InputScript.java:687）")
        elif t.startswith("tags"):
            body = _bracket_body(t, "tags", errs)
            if body is not None:
                for entry in body.split(";"):
                    # 空值／空 namespace／空 path 皆炸（ResourceLocation.java:15-22、:27-31）
                    if not entry or entry.startswith(":") or entry.endswith(":"):
                        errs.append(f"tags 項 `{entry}`：空值、空 namespace 或空 path"
                                    f"（ResourceLocation.of 炸，:15-22/:27-31）")
        elif t.startswith("categories"):
            errs.append(f"`{t}`：categories 僅限 Fluid 輸入（Item 配方 throw，"
                        f"InputScript.java:735-737）")
        elif t.startswith("flags"):
            body = _bracket_body(t, "flags", errs)
            if body is not None:
                for entry in body.split(";"):
                    if entry not in INPUT_FLAGS:
                        errs.append(f"flags 值 `{entry}`：不在 InputFlag 枚舉"
                                    f"（valueOf 炸，InputScript.java:748；大小寫敏感無 trim）")
        elif t.startswith("overlayMapper"):
            pass    # 引擎直接註冊、不取括號（InputScript.java:761-766），裸 token 合法
        elif t.startswith("mappers"):
            _bracket_body(t, "mappers", errs)
        else:
            errs.append(f"`{t}`：unknown recipe param（引擎 throw，InputScript.java:762）")
    return errs


# parser helper 自測（全量執行與 --self-test 都先跑；壞一項即崩＝非零碼）
assert input_mode("mode:destroy") == "destroy"
assert input_mode("[X] flags[A]") == "normal"
assert input_mode("mode:destroy mode:keep") == "keep"          # 重複取最後
assert input_mode("mode:destroy mode:use") == "destroy"        # use 是 no-op
assert input_mode("mode:destroy mode:prop1") == "destroy"      # deprecated prop* 也 no-op
assert input_modes("mode:bogus mode:destroy") == ["bogus", "destroy"]
assert input_flags("flags[A] flags[B]") == {"A", "B"}          # 逐 token 聯集
assert input_flags("flags-extra[C]") == {"C"}                  # startsWith 任意後綴
assert input_flags("flags[A; B]") == {"A", " B"}               # 不 strip（引擎同炸）
assert norm_tag("UsesBattery") == "base:usesbattery"
assert norm_tag(" Base:Drainable ") == "base:drainable"
assert norm_tag(" base:x", trim=False) == " base:x"            # input 側不 trim＝永不命中
assert field_get({"itemtype": "x"}, "ItemType") == "x"         # lower-key O(1) 查找
assert input_line_load_errors("[A.B] mode:destroy flags[ItemCount]") == []
assert input_line_load_errors("Mode:destroy") != []            # unknown param（:762 throw）
assert input_line_load_errors("mode:bogus mode:destroy") != [] # 前置非法值先炸
assert input_line_load_errors("flags[itemcount]") != []        # flag 值錯大小寫
assert input_line_load_errors("flags[ItemCount; IsFull]") != []  # 帶空白項炸
assert input_line_load_errors("[A.B") != []                    # selector 缺右括號炸
assert input_line_load_errors("tags[]") != []                  # 空 tag 項炸
assert input_line_load_errors("tags[:x]") != []                # 空 namespace 炸
assert input_flags("[GPS]flags[X]") == set()                   # 非 token 起點不誤抽


BARE_TYPE_RE = re.compile(r"([A-Za-z]\w*(?:\.\w+)?)(?![\w.\[])")
# 引擎 keyword 與數量都寬鬆：equalsIgnoreCase("item")、數量 Float.parseFloat 或
# variable[...]（InputScript.Load:564-588 區）；regex 收所有候選行，數量合法性
# 由 parse_recipe_items 與載入期檢查分工。
ITEM_ENTRY_RE = re.compile(r"(?mi)^\s*item\s+(\S+)\s+(.+?)\s*,?\s*$")


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
    """`Key = value,` 逐項擷取；先剝掉子區塊，免得把 inputs 內容當成欄位。
    key 一律轉 lower 儲存（引擎 DoParam equalsIgnoreCase＋單值欄位後蓋前——
    lower 化天然 last-wins，混大小寫重複欄位也取檔案最後一筆）。
    累積欄位例外：Tags（Item.java:2341-2347 itemTags.add）與
    Researchablerecipes（Item.java:2776-2781 addResearchableRecipe）依引擎語意
    join 累積，不後蓋前。"""
    while True:
        stripped = re.sub(r"\{[^{}]*\}", "", body)
        if stripped == body:
            break
        body = stripped
    fields = {}
    acc = {"tags": [], "researchablerecipes": []}
    for k, v in re.findall(r"(\w+)\s*=\s*([^,\r\n]*)", body):
        k, v = k.lower(), v.strip()
        if k in acc:
            acc[k].append(v)
            continue
        fields[k] = v
    for k, vals in acc.items():
        if vals:
            fields[k] = ";".join(vals)
    return fields


def parse_recipe_items(block, module):
    """回傳 [(fullTypes, 原文, 數量, 數量原文)]。tags[…] 輸入沒有具體物品，
    fullTypes 為空；數量無法解析成 float 時為 None（載入期檢查另行判定）。"""
    out = []
    for mm in ITEM_ENTRY_RE.finditer(block):
        amt_raw, rest = mm.group(1), mm.group(2)
        amount = _java_float(amt_raw)
        br = re.search(r"(?<!\w)\[([^\]]+)\]", rest)   # `[A;B]`；flags[…]/tags[…] 前有字母，不算
        if br:
            raw = br.group(1)
        else:
            bare = BARE_TYPE_RE.match(rest)
            raw = bare.group(1) if bare else ""
        # 不帶模組前綴的名字由引擎補上所在 module——這裡照做，才抓得到未加前綴的錯字
        types = [t if "." in t else f"{module}.{t}"
                 for t in (s.strip() for s in raw.split(";")) if t]
        out.append((types, rest, amount, amt_raw))
    return out


# 組合層自測（依賴 parse_fields／parse_recipe_items，故放定義後）
assert field_get(parse_fields("tags = a,\ntags = b,"), "Tags") == "a;b"
assert field_get(parse_fields("TAGS = a,\nTags = b,"), "Tags") == "a;b"   # 混大小寫也累積
assert field_get(parse_fields("Icon = A,\nicon = B,\nIcon = C,"), "Icon") == "C"  # 引擎後蓋前
assert field_get(parse_fields("Researchablerecipes = A,\nresearchablerecipes = B,"),
                 "Researchablerecipes") == "A;B"               # 引擎累積（Item.java:2776-2781）
assert parse_recipe_items("item 3 [A.B] mode:destroy,", "M")[0][2] == 3
assert parse_recipe_items("ITEM 1.0 [A.B],", "M")[0][2] == 1   # keyword/數量同引擎寬鬆
assert parse_recipe_items("item nope [A.B],", "M")[0][2] is None
assert amount_load_error("1") is None and amount_load_error("1.0f") is None
assert amount_load_error("variable[1:2]") is None
assert amount_load_error("variable[1]") is not None            # 缺上限炸
assert amount_load_error("variable[x:2]") is not None          # 非 float 炸
assert amount_load_error("nope") is not None
assert input_line_load_errors("shapedIndex:+1") == []          # parseInt 接受 + 前綴
assert input_line_load_errors("shapedIndex:2147483648") != []  # 32-bit 溢位炸
assert input_line_load_errors("tags[base:]") != []             # 空 path 炸
assert input_line_load_errors("overlayMapper") == []           # 裸 token 合法（不取括號）
assert input_line_load_errors("mappers") != []                 # mappers 缺括號炸
assert field_show({"itemtype": ""}, "ItemType") == "''"
assert field_show({}, "ItemType") == "(未宣告)"

if "--self-test" in sys.argv:
    # 快速迴圈：parser helpers＋兩組 module-level assert 已在上方執行，此處補跑
    # 1b 閘門自測後即早退——位於第 1 節之前，1-15 節全部不掃（涵蓋面見 docstring）。
    _luac = shutil.which("luac")
    if not _luac:
        print("--self-test 需要 PATH 有 luac")
        sys.exit(2)
    _bad = kahlua_selftest(_luac)
    fail(KAHLUA_SELFTEST_LABEL, _bad) if _bad else ok(KAHLUA_SELFTEST_LABEL)
    sys.exit(1 if _bad else 0)
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

# ---- 1b. Kahlua 結構上限（upvalue／local 槽數）----
# 順序是契約的一部分：自測不過就不掃檔案，也不准印出任何「合格」結論。
KAHLUA_LABEL = "Kahlua 結構上限（upvalue／local 槽數）"
if not luac:
    skip(KAHLUA_SELFTEST_LABEL, "PATH 沒有 luac")
    skip(KAHLUA_LABEL, "PATH 沒有 luac")
else:
    selftest_bad = kahlua_selftest(luac)
    fail(KAHLUA_SELFTEST_LABEL, selftest_bad) if selftest_bad else ok(KAHLUA_SELFTEST_LABEL)
    if selftest_bad:
        fail(KAHLUA_LABEL, ["閘門自測未通過，掃描結果不可信；先修閘門再談檔案"])
    else:
        bad, protos_total = [], 0
        for f in LUA_FILES:
            rel = os.path.relpath(f, REPO)
            listing, err = kahlua_listing(luac, f)
            if err:
                # 不 continue：拿不到列表就是「這個檔沒被驗過」，必須紅
                bad.append(f"{rel}: {err}")
                continue
            findings, protos = kahlua_over_limit(listing, rel)
            bad.extend(findings)
            if protos == 0:
                bad.append(f"{rel}: 解析不到任何 function 標頭"
                           f"（luac 列表格式已改？此檔等於沒驗）")
            protos_total += protos
        fail(KAHLUA_LABEL, bad) if bad \
            else ok(f"{KAHLUA_LABEL}：≤{KAHLUA_MAX_UPVALUES} upvalues、"
                    f"≤{KAHLUA_MAX_LOCALS} locals（{len(LUA_FILES)} 檔、"
                    f"{protos_total} 個 function 實際解析並比對）")

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
# 進度閘門：自駕模組是 GPS 的升級品，配方必須真的把 GPS 吃掉（mode:keep 不算消耗）。
# 這裡寫完整 fullType 而不是短名——配方宣告在 module Base（見 14），短名會被補成
# Base.GPSNavigator 而永遠對不上輸入寫的 MinidoracatAutoDrive.GPSNavigator。
RECIPE_MUST_CONSUME = {"CraftAutopilotModule": "MinidoracatAutoDrive.GPSNavigator"}




def png_spec(path):
    """回傳 (寬, 高, bit depth, colour type)；不是 PNG 則回 None。"""
    with open(path, "rb") as fh:
        head = fh.read(26)
    if len(head) < 26 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        return None
    w, h = struct.unpack(">II", head[16:24])
    return w, h, head[24], head[25]


def parse_scripts(sdir):
    """掃一個 media/scripts/，回傳 (declared, recipes, modules)。

    declared: {fullType: (欄位 dict, 相對路徑)}；recipes: [(module, 名稱, 內容, 相對路徑)]。
    """
    declared, recipes, modules = {}, [], set()
    for f in sorted(iter_files(sdir, {".txt"})):
        rel = os.path.relpath(f, REPO)
        with open(f, encoding="utf-8") as fh:
            text = re.sub(r"/\*.*?\*/", "", fh.read(), flags=re.S)
        for mod, mbody in parse_blocks(text, "module"):
            modules.add(mod)
            for name, ibody in parse_blocks(mbody, "item"):
                declared[f"{mod}.{name}"] = (parse_fields(ibody), rel)
            for name, rbody in parse_blocks(mbody, "craftRecipe"):
                recipes.append((mod, name, rbody, rel))
    return declared, recipes, modules


LUA_SRC = ""
for f in LUA_FILES:
    with open(f, encoding="utf-8") as fh:
        LUA_SRC += fh.read()

for m in MEDIA_DIRS:
    sdir = os.path.join(m, "scripts")
    if not os.path.isdir(sdir):
        continue
    declared, recipes, modules = parse_scripts(sdir)
    if not declared and not recipes:
        continue

    # 12a. Icon → textures/Item_<Icon>.png
    tex = os.path.join(m, "textures")
    bad = []
    for full, (ifields, rel) in sorted(declared.items()):
        icon = field_get(ifields, "Icon")
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

    # 12b/c/d/f. 配方物品引用 / OnTest 實作 / 進度閘門 / drainable 消耗語意
    #
    # 12f 範圍：本 MOD 宣告的 drainable——含 fullType 直接引用與 tags[...] selector
    # 命中本 MOD drainable 之 Tags 者（本檔不讀原版 scripts，原版 drainable 的配方
    # 輸入這裡看不到）。CraftRecipeManager.java:633/652：無 flags[ItemCount] 時計量
    # 按 getCurrentUses()，空件貢獻 0 卻仍被收進消耗集合（:621-630），湊滿那一刻
    # 整批連坐銷毀（processDestroyAndUsedItems，CraftRecipeData.java:544-564）。
    # 正式服實爆：39 個空電 GPS 一次製作全滅、只產出 1 個模組。
    # 三種合法寫法：flags[ItemCount]（按件計，Base.Battery 型，recipes_electrical.txt:30）
    # 、flags[IsFull]（滿件才可入料，Base.Claybag 型，recipes_sacks.txt:27）或
    # flags[NotEmpty]（同拒空件入料，InputScript.java:1057-1058）——後兩者天然無空件
    # 連坐。非 destroy mode 也不安全：空件同樣被收進消耗集合，且
    # UseItem 對 uses<=0 且無 KeepOnDeplete=true 的物品一樣 RemoveItem
    # （ItemUser.java:69-72）——本 MOD 現況安全只因 GPSNavigator 帶 KeepOnDeplete，
    # 該前提由本閘門明確檢查，不靠默契。flags 比對不 strip 也不折大小寫：引擎
    # split(";") 後直接 InputFlag.valueOf（InputScript.java:744-748，無 trim、大小寫
    # 敏感），帶空白或錯大小寫是載入期 IllegalArgumentException。
    # ItemType 值走 norm_tag 正規化（`Drainable`／`Base:Drainable` ≡ base:drainable，
    # 引擎 Item.java:1970-1971 ItemType.get(ResourceLocation.of(val.trim()))）；
    # 欄位名走 field_get（equalsIgnoreCase）；Tags 由 parse_fields 依引擎語意累積。
    drainables = {ft: ifields for ft, (ifields, _) in declared.items()
                  if norm_tag(field_get(ifields, "ItemType")) == "base:drainable"}
    drain_tag_map = {ft: {norm_tag(t) for t in field_get(ifields, "Tags").split(";")
                          if t.strip()}
                     for ft, ifields in drainables.items()}
    bad_ref, bad_cb, bad_gate, bad_drain = [], [], [], []
    bad_mode = []
    for mod, name, rbody, rel in recipes:
        fields = parse_fields(rbody)
        inputs = parse_recipe_items(sub_block(rbody, "inputs"), mod)
        for types, raw, amt, amt_raw in inputs:
            # 全 input 行的載入期驗證：引擎在第一個非法 token 就 throw（整條配方
            # 炸掉不存在，玩家端零訊息）——「後面還有合法寫法」救不回來。
            # 數量同屬載入期：引擎解析見 amount_load_error（variable[lo:hi] 或 parseFloat）。
            amt_err = amount_load_error(amt_raw)
            if amt_err:
                bad_mode.append(f"{rel}: {name} 輸入數量 `{amt_raw}` {amt_err}"
                                f"——載入期整條配方不存在")
            for err in input_line_load_errors(raw):
                bad_mode.append(f"{rel}: {name} 輸入 `{raw.strip()}` {err}")
        for types, _raw, _amt, _ar in inputs + parse_recipe_items(sub_block(rbody, "outputs"), mod):
            for t in types:
                ns = t.split(".", 1)[0]
                if ns in VANILLA_NS:
                    continue
                if ns not in modules:
                    bad_ref.append(f"{rel}: {name} 引用未知命名空間 {t}"
                                   "（跨 MOD 相依請寫進 verify_ignore.txt 並註明查證依據）")
                elif t not in declared:
                    bad_ref.append(f"{rel}: {name} 引用不存在的物品 {t}")
        cb = field_get(fields, "OnTest")
        if cb and not re.search(rf"function\s+{re.escape(cb)}\s*\(|{re.escape(cb)}\s*=\s*function",
                                LUA_SRC):
            bad_cb.append(f"{rel}: {name} 的 OnTest = {cb} 在 Lua 找不到實作"
                          "（引擎解析不到會當成沒有可用材料，靜默鎖死配方）")
        want = RECIPE_MUST_CONSUME.get(name)
        if want:
            hits = [(raw, types, amt) for types, raw, amt, _ar in inputs if want in types]
            if len(hits) != 1:
                bad_gate.append(
                    f"{name} 的 {want} 命中 {len(hits)} 條 input——公開契約是「固定只"
                    f"消耗 1 個」，0 條＝沒消耗、多條＝引擎每條各吃一次")
            for raw, htypes, amt in hits:
                mode = input_mode(raw)
                if mode != "destroy":
                    bad_gate.append(
                        f"{name} 的 {want} mode={mode}，必須 mode:destroy——非 destroy 時"
                        f"耗盡的 KeepOnDeplete 物品仍留存（ItemUser.java:69-72），"
                        f"同一件可重複製作")
                if amt != 1:
                    bad_gate.append(
                        f"{name} 的 {want} 數量是 item {amt if amt is not None else '非數值'}"
                        f"——公開契約是「固定只消耗 1 個」，多於 1 會整批多吃")
                if len(htypes) != 1:
                    bad_gate.append(
                        f"{name} 的 {want} 候選集合 {htypes} 非排他——引擎可用其他候選"
                        f"湊滿而零消耗 GPS，升級閘門失效")
                gate_flags = input_flags(raw)
                if "ItemCount" not in gate_flags:
                    bad_gate.append(
                        f"{name} 的 {want} 缺 flags[ItemCount]——電量狀態 flag 會拒料、"
                        f"無 flag 會連坐吞噬，皆違反「空電可入料、固定吃一件」的"
                        f"公開行為契約（CHANGELOG 已對玩家承諾）")
                else:
                    st = gate_flags & {"IsFull", "IsEmpty", "NotFull", "NotEmpty"}
                    if st:
                        bad_gate.append(
                            f"{name} 的 {want} 帶電量狀態 flag {sorted(st)}——引擎逐 flag"
                            f" 獨立套用（doesItemPassIsOrNotEmptyAndFullTests，"
                            f"InputScript.java:1044-1059），ItemCount 不能抵銷，"
                            f"「不看電量」的公開契約被限縮")
        for types, raw, _amt, _ar in inputs:
            hit_types = [t for t in types if t in drainables]
            in_tags = {norm_tag(t, trim=False) for t in _bracket_union(raw, "tags")}
            if in_tags:
                hit_types += [ft for ft in drainables
                              if ft not in hit_types and in_tags & drain_tag_map[ft]]
            if not hit_types:
                continue
            in_flags = input_flags(raw)
            mode = input_mode(raw)
            if mode == "destroy":
                # ItemCount（按件計）或 IsFull/NotEmpty（拒空件入料）都使連坐不可能
                if not (in_flags & {"ItemCount", "IsFull", "NotEmpty"}):
                    bad_drain.append(
                        f"{rel}: {name} 輸入 `{raw.strip()}` —— drainable 走 destroy 必須帶 "
                        f"flags[ItemCount]（或 IsFull/NotEmpty），否則空件被連坐吞噬")
            elif not (in_flags & {"IsFull", "NotEmpty"}) and any(
                    # 非 destroy：空件仍被連坐收集，UseItem 對 uses<=0 且無
                    # KeepOnDeplete 者照樣 RemoveItem——ItemCount 不豁免此路徑
                    field_get(drainables[t], "KeepOnDeplete").strip().lower() != "true"
                    for t in hit_types):
                bad_drain.append(
                    f"{rel}: {name} 輸入 `{raw.strip()}` —— 非 destroy 的 drainable 輸入"
                    f"（mode={mode}）需該物品宣告 KeepOnDeplete = true，否則空件耗盡被"
                    f"靜默移除（ItemUser.java:69-72）且同樣被連坐收集")
    bad_ref = sorted(set(bad_ref))
    fail("配方物品引用存在", bad_ref) if bad_ref else ok(f"配方物品引用存在（{len(recipes)} 配方）")
    fail("配方 OnTest 有 Lua 實作", bad_cb) if bad_cb else ok("配方 OnTest 有 Lua 實作")
    fail("配方進度閘門（升級配方消耗前一階物品）", bad_gate) if bad_gate \
        else ok("配方進度閘門（升級配方消耗前一階物品）")
    fail("配方輸入載入期擋炸（mode／flags／unknown token）", bad_mode) if bad_mode \
        else ok("配方輸入載入期擋炸（mode／flags／unknown token）")
    fail("drainable 輸入消耗語意（ItemCount/IsFull/KeepOnDeplete）", bad_drain) if bad_drain \
        else ok("drainable 輸入消耗語意（ItemCount/IsFull/KeepOnDeplete；本 MOD drainable）")

    # 12e. Lua／翻譯檔字串裡的 fullType（分佈表、MDAD.TYPE_*、ItemName.json）
    bad_use = []
    for f in iter_files(m, {".lua", ".json"}):
        rel = os.path.relpath(f, REPO)
        with open(f, encoding="utf-8") as fh:
            txt = fh.read()
        for mod in sorted(modules):
            # 配方搬進 module Base 後 modules 會含 Base；原版 fullType 本檔無從驗證，放行
            if mod in VANILLA_NS:
                continue
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

# ---- 14. 配方學習鏈（module Base／NeedToBeLearn／雜誌／研究） ----
# 「配方做得出來卻沒人學得到」的每一段都是靜默失敗，只能靠對表擋（皆為 42.20.4 反編譯出處）：
#   * ScriptBucketCollection.java:72-81 —— getScript(name) 對不含 '.' 的名字一律查
#     getModule("Base")。LearnedRecipes / Researchablerecipes 寫的是短名，所以配方本身
#     必須宣告在 module Base；搬回自家 module 後雜誌與研究都查不到，且沒有任何錯誤訊息。
#   * Item.java:3494-3500 —— addResearchableRecipe() 查不到配方時把字串「照抄」進
#     researchableRecipes。模組限定名（含 '.'）因此不會報錯，只變成永遠學不到的死項目。
#   * Item.java:3513-3516 —— 只有 canBeResearched() 為真才進表，而 CraftRecipe.java:181
#     的 canBeResearched() 需要 needToBeLearn = true；拿掉 true 整條研究路徑直接消失。
#   * CraftRecipe.java:1221-1232 —— ResearchSkillLevel 沒寫時引擎自己推
#     round(最高技能需求 * 2/3)（Electricity:3 → 2、:6 → 4），與本 MOD 要的 3／6 不同，
#     所以一定要明寫並對表；寫成 0 還會讓 canAlwaysBeResearched() 為真而完全跳過閘門。
#   * ScriptManager.java:1043-1048 —— needToBeLearn 又沒有 AutoLearn 也沒有雜誌教的配方，
#     只在 console 印一行 "is not learnable"，發版前沒人會看到。
# 只驗證腳本文字。「手冊真的刷得出來／登入補學真的跑」屬行為面，歸 scripts/smoke_harness.lua。
# 手冊 icon 的 64x64 RGBA 材質由 12a 一併覆蓋（它掃所有宣告過的 item），此處不重複。
LEARN_MODULE = "Base"
MANUAL_FULL = "MinidoracatAutoDrive.NavigationRepairManual"
MANUAL_ICON = "NavigationRepairManual"
MANUAL_LEARNED = "CraftGPSNavigator;CraftAutopilotModule"
MANUAL_ITEM_TYPE = "base:literature"
MANUAL_ON_CREATE = "ItemCodeOnCreate.onCreateRecipeMagazine"
RECIPE_LEARN_SPEC = {          # 配方短名: (SkillRequired, AutoLearnAny, ResearchSkillLevel)
    "CraftGPSNavigator":    ("Electricity:3", "Electricity:6", "3"),
    "CraftAutopilotModule": ("Electricity:6", "Electricity:8", "6"),
}
RESEARCHABLE_SPEC = {          # 成品 fullType: Researchablerecipes 的精確值
    "MinidoracatAutoDrive.GPSNavigator":    "CraftGPSNavigator",
    "MinidoracatAutoDrive.AutopilotModule": "CraftGPSNavigator;CraftAutopilotModule",
}
for m in MEDIA_DIRS:
    sdir = os.path.join(m, "scripts")
    if not os.path.isdir(sdir):
        continue
    declared, recipes, _ = parse_scripts(sdir)
    if not declared and not recipes:
        continue

    # 14a. 配方所在 module ＋ 學習欄位對表
    bad_learn = []
    for want_name, (skill, auto, research) in sorted(RECIPE_LEARN_SPEC.items()):
        found = [(mod, rbody, rel) for mod, name, rbody, rel in recipes if name == want_name]
        if not found:
            bad_learn.append(f"找不到 craftRecipe {want_name}"
                             "（雜誌與研究都靠這個短名查表，改名等於整條學習鏈斷掉）")
            continue
        if len(found) > 1:
            bad_learn.append(f"{want_name} 宣告了 {len(found)} 次，引擎只留一個，"
                             "實際行為看載入順序")
        for mod, rbody, rel in found:
            if mod != LEARN_MODULE:
                bad_learn.append(
                    f"{rel}: {want_name} 在 module {mod}，必須是 module {LEARN_MODULE}"
                    "（短名只在 Base 查得到，見 ScriptBucketCollection.java:77）")
            rfields = parse_fields(rbody)
            if field_get(rfields, "NeedToBeLearn").lower() != "true":
                bad_learn.append(
                    f"{rel}: {want_name} 的 NeedToBeLearn = "
                    f"{field_show(rfields, 'NeedToBeLearn')}，"
                    "必須是 true（false 則開局就會，雜誌與研究全部失去意義）")
            for field, expect in (("SkillRequired", skill), ("AutoLearnAny", auto),
                                  ("ResearchSkillLevel", research)):
                if field_get(rfields, field) != expect:
                    bad_learn.append(f"{rel}: {want_name} 的 {field} = "
                                     f"{field_show(rfields, field)}，規格是 {expect}")
    fail("配方學習閘門（module Base／NeedToBeLearn／技能對表）", bad_learn) if bad_learn \
        else ok(f"配方學習閘門（{len(RECIPE_LEARN_SPEC)} 配方）")

    # 14b. 專屬手冊（唯一雜誌來源）＋ 兩個成品的研究來源
    bad_src = []
    manual = declared.get(MANUAL_FULL)
    if manual is None:
        bad_src.append(f"缺 item {MANUAL_FULL}"
                       "（沒有專屬雜誌就只剩 AutoLearn 與成品研究）")
    else:
        mfields, mrel = manual
        if field_get(mfields, "ItemType") != MANUAL_ITEM_TYPE:
            bad_src.append(f"{mrel}: {MANUAL_FULL} 的 ItemType = "
                           f"{field_show(mfields, 'ItemType')}，規格是 {MANUAL_ITEM_TYPE}"
                           "（非 literature 就無法閱讀學會配方）")
        if field_get(mfields, "OnCreate") != MANUAL_ON_CREATE:
            bad_src.append(f"{mrel}: {MANUAL_FULL} 的 OnCreate = "
                           f"{field_show(mfields, 'OnCreate')}，規格是 {MANUAL_ON_CREATE}"
                           "（維持原版配方雜誌的已讀狀態）")
        if field_get(mfields, "Icon") != MANUAL_ICON:
            bad_src.append(f"{mrel}: {MANUAL_FULL} 的 Icon = "
                           f"{field_show(mfields, 'Icon')}，規格是 {MANUAL_ICON}")
        if field_get(mfields, "LearnedRecipes") != MANUAL_LEARNED:
            bad_src.append(f"{mrel}: {MANUAL_FULL} 的 LearnedRecipes = "
                           f"{field_show(mfields, 'LearnedRecipes')}，規格是 {MANUAL_LEARNED}"
                           "（一本手冊教兩個配方）")
    for full, expect in sorted(RESEARCHABLE_SPEC.items()):
        entry = declared.get(full)
        if entry is None:
            bad_src.append(f"缺 item {full}，無從掛 Researchablerecipes")
            continue
        ifields, rel = entry
        if field_get(ifields, "Researchablerecipes") != expect:
            bad_src.append(f"{rel}: {full} 的 Researchablerecipes = "
                           f"{field_show(ifields, 'Researchablerecipes')}，規格是 {expect}")
    fail("配方學習來源（手冊 LearnedRecipes／成品 Researchablerecipes）", bad_src) if bad_src \
        else ok("配方學習來源（手冊 LearnedRecipes／成品 Researchablerecipes）")

    # 14c. 短名不變式：學習欄位一律短名，帶模組前綴會變成查不到的死項目
    bad_short = []
    for full, (ifields, rel) in sorted(declared.items()):
        for field in ("LearnedRecipes", "Researchablerecipes"):
            for entry in (s.strip() for s in field_get(ifields, field).split(";")):
                if entry and "." in entry:
                    bad_short.append(
                        f"{rel}: {full} 的 {field} 有模組限定名 {entry}，只能寫配方短名"
                        "（Item.java:3499 會把查不到的名字照抄進表，永遠學不到又不報錯）")
    fail("學習欄位只用配方短名", bad_short) if bad_short else ok("學習欄位只用配方短名")

# ---- 15. Phase 1 telemetry 靜態契約（不執行測試）----
# 模組／選項／翻譯由本閘門靜態確認；聚焦 Lua 測試只驗證檔案存在，不在這裡 lua 執行。
LUA_BASENAMES = {os.path.basename(f) for f in LUA_FILES}
phase1 = []
if "MDAD_VehicleProfile.lua" not in LUA_BASENAMES and "MDADVehicleProfile.lua" not in LUA_BASENAMES:
    phase1.append("缺 MDADVehicleProfile 模組（client/MDAD_VehicleProfile.lua）")
if "MDAD_Diagnostics.lua" not in LUA_BASENAMES and "MDADDiagnostics.lua" not in LUA_BASENAMES:
    phase1.append("缺 MDADDiagnostics 模組（client/MDAD_Diagnostics.lua）")
if "MDAD_Dynamics.lua" not in LUA_BASENAMES:
    phase1.append("缺 shared/MDAD_Dynamics.lua")
hud_src = ""
for f in LUA_FILES:
    if os.path.basename(f) == "MDAD_HUD.lua":
        with open(f, encoding="utf-8") as fh:
            hud_src = fh.read()
        break
if not hud_src:
    phase1.append("缺 MDAD_HUD.lua")
else:
    for token in ("ExportTelemetry", "TelemetryRetentionDays",
                  "telemetryEnabled", "telemetryRetentionDays",
                  "setTelemetryEnabled", "setTelemetryRetentionDays"):
        if token not in hud_src:
            phase1.append(f"MDAD_HUD.lua 缺 {token}")
TELEM_KEYS = (
    "UI_MinidoracatAutoDrive_ExportTelemetry",
    "UI_MinidoracatAutoDrive_ExportTelemetry_tooltip",
    "UI_MinidoracatAutoDrive_TelemetryRetentionDays",
    "UI_MinidoracatAutoDrive_TelemetryRetentionDays_tooltip",
    "UI_MinidoracatAutoDrive_TelemetryRetention1",
    "UI_MinidoracatAutoDrive_TelemetryRetention3",
    "UI_MinidoracatAutoDrive_TelemetryRetention7",
    "UI_MinidoracatAutoDrive_TelemetryRetention14",
    "UI_MinidoracatAutoDrive_TelemetryRetention30",
    "UI_MinidoracatAutoDrive_CopyLatestTelemetry",
    "UI_MinidoracatAutoDrive_CopyLatestTelemetry_tooltip",
    "UI_MinidoracatAutoDrive_CopyTelemetryFolder",
    "UI_MinidoracatAutoDrive_CopyTelemetryFolder_tooltip",
    "UI_MinidoracatAutoDrive_TelemetryNoFile",
    "UI_MinidoracatAutoDrive_TelemetryCopied",
    "UI_MinidoracatAutoDrive_TelemetryCopyFailed",
    "UI_MinidoracatAutoDrive_TelemetrySlotsFull",
    "UI_MinidoracatAutoDrive_TelemetryWriteFailed",
    "UI_MinidoracatAutoDrive_TelemetryFileFull",
)
for m in MEDIA_DIRS:
    en = os.path.join(m, "lua", "shared", "Translate", "EN", "UI.json")
    if not os.path.isfile(en):
        phase1.append(f"缺 {os.path.relpath(en, REPO)}")
        continue
    with open(en, encoding="utf-8") as fh:
        en_keys = json.load(fh)
    for key in TELEM_KEYS:
        if key not in en_keys:
            phase1.append(f"EN/UI.json 缺 {key}")
FOCUSED_TESTS = (
    "scripts/test_hud.lua",
    "scripts/test_vehicle_profile.lua",
    "scripts/test_diagnostics.lua",
    "scripts/test_dynamics.lua",
    "scripts/test_follower.lua",
    "scripts/test_voice.lua",
)
for rel in FOCUSED_TESTS:
    if not os.path.isfile(os.path.join(REPO, rel)):
        phase1.append(f"缺聚焦測試 {rel}（閘門只檢查存在，不執行）")
fail("Phase 1 telemetry 靜態契約", phase1) if phase1 else ok(
    "Phase 1 telemetry 靜態契約（模組／選項／翻譯／聚焦測試檔存在且未執行）")

# ---- 16. 意圖層階段 2 結構契約（RECOVER 單一進口）----
# 2026-09-01 重構階段 2 主體 2：舊制五個需求方各自呼 startRecoveryAttempt，
# 優先序靠賦值順序隱式決定。現在需求方一律只呼 requestRecover 設旗標＋原因，
# 恢復動作由 stepFollow 尾端單一 dispatch 判定。這是結構不變式：離線行為測試
# 抓不到「有人又加了第六個直接進口」（新進口自己也會動、測試照綠），只有
# 靜態計數擋得住。
phase2 = []
drv_src = ""
for f in LUA_FILES:
    if os.path.basename(f) == "MDAD_Driver.lua":
        with open(f, encoding="utf-8") as fh:
            drv_src = fh.read()
        break
if not drv_src:
    phase2.append("缺 client/MDAD_Driver.lua")
else:
    # 定義 1 次 + 呼叫 1 次；註解／字串裡的名字不帶左括號，故只數 "name("
    calls = drv_src.count("startRecoveryAttempt(")
    defs = drv_src.count("local function startRecoveryAttempt(")
    if defs != 1:
        phase2.append(f"startRecoveryAttempt 定義應為 1 處（實得 {defs}）")
    if calls - defs != 1:
        phase2.append(
            f"startRecoveryAttempt 呼叫點應唯一（實得 {calls - defs}）"
            "——恢復需求請改呼 requestRecover 設旗標")
    if "local function requestRecover(" not in drv_src:
        phase2.append("缺 requestRecover 單一進口函式")
    if "TUNE.RECOVER_RANK" not in drv_src:
        phase2.append("缺 TUNE.RECOVER_RANK 顯式優先序表")
    # s.recoverWhy 的唯一賦值寫法：requestRecover 內一處，加上清旗標（= nil）
    bad = [ln.strip() for ln in drv_src.splitlines()
           if "s.recoverWhy =" in ln or "s.recoverWhy," in ln]
    setters = [ln for ln in bad if "nil" not in ln]
    if len(setters) != 1:
        phase2.append(
            f"s.recoverWhy 的設值點應唯一（requestRecover 內），實得 {len(setters)}")
fail("階段 2 結構契約（RECOVER 單一進口）", phase2) if phase2 else ok(
    "階段 2 結構契約（RECOVER 單一進口／顯式優先序）")

# ---- 17. 意圖層階段 2 結構契約（餘裕預算單一 authority）----
# 2026-09-01 重構階段 2 主體 4：sensor 半徑／needHalf／squeezeNeed／sweep base
# ／QUANT_COMP 各自扣一層餘裕，疊加超支把 2.4m 的縫對 1.8m 的車判死。現在
# need／base 一律由 MDADVehicleProfile.planNeed／sweepBase 從同一張預算表導出。
# 這同樣是結構不變式：私扣一層 5cm 在離線測試裡看不出來（只有邊際縫才顯形），
# 只有靜態禁寫法擋得住。
phase2b = []
prof_src = ""
for f in LUA_FILES:
    if os.path.basename(f) == "MDAD_VehicleProfile.lua":
        with open(f, encoding="utf-8") as fh:
            prof_src = fh.read()
        break
if not prof_src:
    phase2b.append("缺 client/MDAD_VehicleProfile.lua")
else:
    for token in ("function MDADVehicleProfile.clearanceBudget(",
                  "function MDADVehicleProfile.planNeed(",
                  "function MDADVehicleProfile.sweepBase("):
        if token not in prof_src:
            phase2b.append(f"MDAD_VehicleProfile.lua 缺 {token[9:]}")
    if prof_src.count("CLEARANCE_BUDGET = {") != 1:
        phase2b.append("CLEARANCE_BUDGET 預算表應為唯一一張")
# 禁止的私扣寫法：任何一行只要同時出現「餘裕識別字」與「±小數字面值」，就是
# 在單一 authority 之外自己加減餘裕。註解不算（歷史說明用得到），具名常數
# （例如 CURVE_NEED_EXTRA 這種有物理理由的加碼）也不算——只擋裸字面值。
MARGIN_IDENT = re.compile(
    r"\b(needHalf|needUsed|needBase|squeezeNeed|sweepBase|squeezeSweepBase"
    r"|dodgeNeed|probeNeed|probeBase|halfW)\b")
MARGIN_LITERAL = re.compile(r"[-+]\s*(?:0?\.\d|\d+\.\d)")
for label, src in (("MDAD_Driver.lua", drv_src),
                   ("MDAD_VehicleProfile.lua", prof_src)):
    for i, line in enumerate(src.splitlines(), 1):
        code = line.split("--", 1)[0]
        if MARGIN_IDENT.search(code) and MARGIN_LITERAL.search(code):
            phase2b.append(
                f"{label}:{i} 私扣餘裕 `{code.strip()}`"
                "——請改用 clearanceBudget／planNeed／sweepBase")
fail("階段 2 結構契約（餘裕預算單一 authority）", phase2b) if phase2b else ok(
    "階段 2 結構契約（餘裕預算單一 authority／禁私扣）")

# ---- 18. 意圖層階段 2 結構契約（mode／progressState 契約值收斂）----
# 2026-09-01 重構階段 2 主體 5：mode 只留「會繞過 stepFollow 或整段停控」的狀態；
# 恢復鏈的內部階段一律在 progressState，「有恢復需求」是 s.recoverWhy 旗標。
# 靜態掃描賦值字面值，任何新增的第三種狀態機值都會被擋下——這是離線行為測試
# 抓不到的（新值自己也會走出一條路，測試照綠，語意卻又分裂成兩套）。
MODE_CONTRACT = {"build", "follow", "unstick", "settle", "yield", "arrive"}
PROGRESS_CONTRACT = {"disarmed", "watch", "verify", "suspect",
                     "recover", "gear-reset", "settle"}
phase2c = []
if not drv_src:
    phase2c.append("缺 client/MDAD_Driver.lua")
else:
    for field, allowed in (("mode", MODE_CONTRACT),
                           ("progressState", PROGRESS_CONTRACT)):
        pat = re.compile(r"""s\.%s\s*=\s*["']([^"']+)["']""" % field)
        for i, line in enumerate(drv_src.splitlines(), 1):
            code = line.split("--", 1)[0]
            for value in pat.findall(code):
                if value not in allowed:
                    phase2c.append(
                        f"MDAD_Driver.lua:{i} s.{field} 寫入非契約值 "
                        f"\"{value}\"（契約：{sorted(allowed)}）")
    # gear-reset／recover 必須已經離開 mode
    for banned in ('s.mode = "gear-reset"', 's.mode = "recover"',
                   's.mode == "gear-reset"', 's.mode == "recover"'):
        if banned in drv_src:
            phase2c.append(
                f"MDAD_Driver.lua 仍有 `{banned}`"
                "——恢復階段請用 progressState／recoverWhy")
fail("階段 2 結構契約（mode／progressState 契約值）", phase2c) if phase2c else ok(
    "階段 2 結構契約（mode／progressState 契約值收斂）")

# ---- 19. 意圖層階段 2 結構契約（調頭單一權威）----
# 2026-09-01 重構階段 2 主體 6：Driver 的 ROTATE_ERR_RAD=90° 與 Follower 的
# ROTATE_ENTER=135°／EXIT=100° 在 90-135° 匯流區各說各話（Driver 判「要調頭」
# 主動煞停，Follower 判「還在跟線」照給轉向）。調頭姿態的唯一權威是
# fstate.rotating；Driver 不得再有第二條角度門檻。
phase2d = []
if not drv_src:
    phase2d.append("缺 client/MDAD_Driver.lua")
else:
    if "ROTATE_ERR_RAD" in drv_src:
        phase2d.append(
            "MDAD_Driver.lua 仍有 ROTATE_ERR_RAD——調頭判定請讀 s.fstate.rotating")
    if "s.fstate.rotating" not in drv_src:
        phase2d.append("MDAD_Driver.lua 未讀 s.fstate.rotating（調頭單一權威）")
fol_src = ""
for f in LUA_FILES:
    if os.path.basename(f) == "MDAD_Follower.lua":
        with open(f, encoding="utf-8") as fh:
            fol_src = fh.read()
        break
if not fol_src:
    phase2d.append("缺 shared/MDAD_Follower.lua")
elif "ROTATE_ENTER" not in fol_src or "ROTATE_EXIT" not in fol_src:
    phase2d.append("MDAD_Follower.lua 缺 ROTATE_ENTER／ROTATE_EXIT 遲滯門檻")
fail("階段 2 結構契約（調頭單一權威）", phase2d) if phase2d else ok(
    "階段 2 結構契約（調頭單一權威＝fstate.rotating）")
# ---- 20. 0902 結構契約（持有權仲裁／連續縮放／coverEnd／測試常數對齊）----
# 2026-09-02 一輪快刀後的機器鎖：這些都是「離線行為測試抓得到症狀、抓不到
# 結構回退」的契約——例如 dodgeSpeedCapKmh 若有人補回第 7 參 squeeze 帽，
# harness 的速度上緣斷言照過（更保守也在區間內），只有簽章掃描擋得住。
c0902 = []
dyn_src = ""
for f in LUA_FILES:
    if os.path.basename(f) == "MDAD_Dynamics.lua":
        with open(f, encoding="utf-8") as fh:
            dyn_src = fh.read()
        break
if not drv_src or not dyn_src:
    c0902.append("缺 MDAD_Driver.lua／MDAD_Dynamics.lua")
else:
    # ① one-size 爬行帽退役：dodgeSpeedCapKmh 六參，不得再有 squeeze 參
    m = re.search(r"function D\.dodgeSpeedCapKmh\(([^)]*)\)", dyn_src)
    if not m:
        c0902.append("Dynamics 缺 dodgeSpeedCapKmh")
    else:
        params = [p.strip() for p in m.group(1).replace("\n", " ").split(",")]
        if len(params) != 6 or "squeeze" in m.group(1):
            c0902.append(
                "dodgeSpeedCapKmh 簽章非六參（one-size 爬行帽已退役：速度只由"
                "連續物理量決定，不得補回 squeeze 檔位參數）")
    # ② fstate 單一持有權：profileOwner 定義唯一，且 replan 的 dodge commit
    #    （setOffset 呼叫）之前必經 owner 判定
    if len(re.findall(r"local function profileOwner\(", drv_src)) != 1:
        c0902.append("profileOwner 定義數 ≠ 1（fstate 持有權仲裁必須單一）")
    if "local owner = profileOwner(s)" not in drv_src:
        c0902.append("replan 未讀 profileOwner（dodge commit 前必經仲裁）")
    if "if owner == \"rotate\" or owner == \"dodge\" then return end" not in drv_src:
        c0902.append("updateReturnSnapshot 未在 ROTATE／DODGE 持有時掛起 RETURN")
    # ③ setOffset 呼叫必帶 coverEnd（d 可超 route 終點，覆蓋檢查要鉗 route 長）
    for call in re.finditer(r"MDADFollower\.setOffset\(([^;]*?)\)\s*then", drv_src, re.S):
        args = call.group(1)
        if "coverEnd" not in args:
            c0902.append("Driver 的 MDADFollower.setOffset 呼叫未傳 coverEnd（近目標 commit 會被舊 d+1 覆蓋契約拒收）")
    # ④ 擋線判定單一定義：replan 內不得再手寫 |l-bias| < r+needHalf
    if len(re.findall(r"local function blocksLine\(", drv_src)) != 1:
        c0902.append("blocksLine 定義數 ≠ 1（擋線判定單一定義）")
    if re.search(r"dl2? < r2? \+ (s\.needHalf|nh)", drv_src.split("local function replan(")[-1]):
        c0902.append("replan 內出現手寫擋線判定——請走 blocksLine／lineBlockerAhead")
    # ⑤ harness 測試常數與 production 對齊（TUNE 不 export，改靜態抽值比對）
    mt = re.search(r"TUNE\.RETURN_UNSAFE_CAP\s*=\s*([0-9.]+)", drv_src)
    harness_path = os.path.join(REPO, "scripts", "smoke_harness.lua")
    if mt and os.path.exists(harness_path):
        with open(harness_path, encoding="utf-8") as fh:
            hs = fh.read()
        mh = re.search(r"local TUNE_RETURN_UNSAFE_CAP_TEST\s*=\s*([0-9.]+)", hs)
        if not mh:
            c0902.append("smoke_harness 缺 TUNE_RETURN_UNSAFE_CAP_TEST")
        elif float(mh.group(1)) != float(mt.group(1)):
            c0902.append(
                f"smoke_harness TUNE_RETURN_UNSAFE_CAP_TEST={mh.group(1)} ≠ "
                f"Driver TUNE.RETURN_UNSAFE_CAP={mt.group(1)}（平行常數漂移）")
fail("0902 結構契約", c0902) if c0902 else ok(
    "0902 結構契約（六參 cap／持有權仲裁唯一／coverEnd／擋線單一定義／測試常數對齊）")

# ---- 33. 語音資產契約（2026-09-02）----
# Voice.EVENTS × Voice.PACKS 每一格都要有 sound script 條目＋wav 檔＋語言下拉的翻譯鍵；
# 缺一格＝實機那句靜默（play 只警告一次），離線 test_voice 用假 registered 表抓不到。
voice_errs = []
voice_src, sound_txt = "", ""
MEDIA = MEDIA_DIRS[0]
for f in LUA_FILES:
    if os.path.basename(f) == "MDAD_Voice.lua":
        with open(f, encoding="utf-8") as fh:
            voice_src = fh.read()
        break
sound_path = os.path.join(MEDIA, "scripts", "sounds_autodrive.txt")
if os.path.exists(sound_path):
    with open(sound_path, encoding="utf-8") as fh:
        sound_txt = fh.read()
if not voice_src or not sound_txt:
    voice_errs.append("缺 MDAD_Voice.lua／scripts/sounds_autodrive.txt")
else:
    ev_m = re.search(r"local EVENTS = \{(.*?)\}", voice_src, re.S)
    pk_m = re.search(r"Voice\.PACKS = \{(.*?)\}", voice_src, re.S)
    events = re.findall(r"(\w+)\s*=\s*true", ev_m.group(1)) if ev_m else []
    packs = re.findall(r'"(\w+)"', pk_m.group(1)) if pk_m else []
    if not events or not packs:
        voice_errs.append("抽不到 Voice.EVENTS／Voice.PACKS")
    sound_dir = os.path.join(MEDIA, "sound", "MinidoracatAutoDrive")
    for ev in events:
        for pk in packs:
            name = f"MDAD_Voice_{ev}_{pk}"
            m = re.search(r"sound\s+" + re.escape(name) + r"\s*\{.*?file\s*=\s*([^\s,]+)", sound_txt, re.S)
            if not m:
                voice_errs.append(f"sounds_autodrive.txt 缺 {name}")
                continue
            rel = m.group(1)
            if not os.path.exists(os.path.join(MEDIA, *rel.split("/")[1:])):
                voice_errs.append(f"{name} 指到不存在的檔 {rel}")
    for pk in packs:
        key = f"UI_MinidoracatAutoDrive_VoiceLang_{pk}"
        for lang in ("EN", "CH", "CN", "JP"):
            ui = os.path.join(MEDIA, "lua", "shared", "Translate", lang, "UI.json")
            if os.path.exists(ui):
                with open(ui, encoding="utf-8") as fh:
                    if key not in fh.read():
                        voice_errs.append(f"Translate/{lang}/UI.json 缺 {key}")
fail("語音資產契約", voice_errs) if voice_errs else ok(
    f"語音資產契約（{len(events) if voice_src else 0} 事件 × {len(packs) if voice_src else 0} 語音包＝sound script／wav／翻譯鍵齊全）")

# ---- 總結 ----
print()
print(f"PASS {len(passed)} / FAIL {len(failed)} / SKIP {len(skipped)}")
sys.exit(1 if failed else 0)
