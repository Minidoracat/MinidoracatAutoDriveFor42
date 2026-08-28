--[[
繞行縫隙規劃器的離線測試：載入**真正的** shared/MDAD_Corridor.lua，跑數值情境並斷言。

    lua scripts/test_corridor.lua        （repo 根目錄或 scripts/ 執行皆可；標準 Lua 5.x）

為什麼需要（縫隙判定的錯誤 luac -p 與 smoke_harness 都抓不到）：
- 「車半寬有沒有膨脹進障礙」寫錯，遊戲裡的表徵是車擦著障礙開過去或明明過得去卻
  停在路中央。肉眼分不出是門檻少加了 OBS_HALF、還是群聚合把遠障礙拉進來
- 群聚合是「多輪線性掃描直到邊界不再擴張」（Kahlua 不准 table.sort），輪數上限
  截短群的行為必須有測試釘住，否則之後有人把上限改小會安靜地生出偏短的繞行段
- 斷點單調（a < b <= c < d）是側偏剖面的前提；障礙就在眼前時的夾限最容易破壞它
- 「零 table 配置」沒有計數器就無法證明

本檔載入的 production（真檔，無任何 source-text 斷言）：
    shared/MDAD_Corridor.lua

不需要任何假 PZ 全域——corridor 是純數學模組，這正是它獨立成一檔的理由。

每個情境都包在 do ... end 裡：Lua 單一函式（含主 chunk）的 local 上限是 200 個，
情境用的暫時變數若全放檔案層級會頂到上限，之後新增一條斷言就編譯不過。

限制（必須誠實面對）：
- 本檔只驗「給定 (s, l) 點集 → 側偏剖面」這一層。點集本身正不正確（sprite 分類、
  走廊投影）屬 client/MDAD_Sensor 的責任，不在此驗
- 所有期望值都由測試自己按契約手算（膨脹半徑 clr = 0.7 + needHalf、格點 0.25 錨在
  l = 0、群間距 6），刻意不重用 production 的常數推導，否則常數打錯兩邊一起錯
- 這是標準 Lua 不是 Kahlua：next/assert/xpcall/table.sort 的誤用由 scripts/verify_mod.py
  的靜態掃描負責（本檔在 42/media 之外，可自由用標準函式庫）
]]

-- 家族佈局固定，直接填死最省事
local MEDIA = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua"
local ROOTS = { "", "../" }

-- loadfile 對「檔案不存在」和「語法錯誤」都回 nil；先用 io.open 確認檔案在，
-- 再讓 loadfile 的錯誤訊息原樣浮上來（否則語法錯會被誤報成「找不到」）
local function loadProduction(rel)
    for _, root in ipairs(ROOTS) do
        local path = root .. MEDIA .. "/" .. rel
        local fh = io.open(path, "r")
        if fh then
            fh:close()
            local chunk, err = loadfile(path)
            if not chunk then error("載入失敗（語法錯誤？）：" .. tostring(err)) end
            chunk()
            return path
        end
    end
    error("找不到 " .. rel .. "（請從 repo 根目錄或 scripts/ 執行）")
end

loadProduction("shared/MDAD_Corridor.lua")

local C = MDADCorridor

-- =====================================================================
-- 測試工具（與 scripts/test_follower.lua 同一套形狀）
-- =====================================================================

local failures, assertions, scenarios = 0, 0, 0
local scenarioBase, scenarioAsserts, scenarioTitle = 0, 0, nil

local function show(v)
    if type(v) == "string" then return '"' .. v .. '"' end
    if type(v) == "number" and v == v and v - v == 0 and v % 1 ~= 0 then
        return string.format("%.6f", v)
    end
    return tostring(v)
end

local function check(ok, label)
    assertions = assertions + 1
    if not ok then
        failures = failures + 1
        print("  FAIL  " .. label)
    end
    return ok
end

local function checkTrue(v, label)
    return check(v == true, label .. "（實得 " .. show(v) .. "）")
end

local function checkEq(actual, expected, label)
    return check(actual == expected,
        label .. "（期望 " .. show(expected) .. "、實得 " .. show(actual) .. "）")
end

local function checkNear(actual, expected, eps, label)
    local ok = type(actual) == "number" and actual == actual
        and math.abs(actual - expected) <= eps
    return check(ok, label .. "（期望 ~" .. show(expected) .. "、實得 " .. show(actual) .. "）")
end

local function closeScenario()
    if not scenarioTitle then return end
    if failures - scenarioBase == 0 then
        print("  ok（" .. (assertions - scenarioAsserts) .. " 項斷言全過）")
    end
end

local function scenario(title)
    closeScenario()
    scenarios = scenarios + 1
    scenarioTitle = title
    scenarioBase = failures
    scenarioAsserts = assertions
    print("情境" .. scenarios .. "：" .. title)
end

-- =====================================================================
-- 契約小工具（測試自己按檔頭契約手算參考值，刻意不讀 production 的推導）
-- =====================================================================

local NEED = 1.4      -- 典型車半寬 + margin
local CORR = 3.0      -- 典型走廊半寬（6 公尺道寬）
local OBS = 0.7       -- 契約寫死的障礙格半寬
local CLR = OBS + NEED  -- 膨脹後的橫向淨空門檻＝2.1
local EPS = 1e-9

-- 四個斷點的單調性：側偏剖面的前提，任何 mode == "dodge" 都必須成立
local function checkMono(a, b, c, d, label)
    checkTrue(a < b, label .. "：a < b（進入段長度 > 0）")
    checkTrue(b <= c, label .. "：b <= c（保持段長度 >= 0）")
    checkTrue(c < d, label .. "：c < d（回歸段長度 > 0）")
end

-- 候選 lane 對「s 窗口內每個障礙」的橫向淨空（測試端獨立實作，O(n)）
local function worstClearance(sArr, lArr, n, sLo, sHi, l)
    local worst = nil
    for i = 1, n do
        local s = sArr[i]
        if s >= sLo and s <= sHi then
            local d = math.abs(l - lArr[i])
            if worst == nil or d < worst then worst = d end
        end
    end
    return worst
end

-- =====================================================================
-- 情境一：沒有障礙擋住中心線 → clear（含「全在走廊邊緣」）
-- =====================================================================
scenario("clear：障礙全落在中心線外（|l| >= 膨脹門檻）時不規劃繞行")
do
    -- |l| = 2.2 與 3.0 都 >= CLR = 2.1：車沿 l = 0 開得過去，不該生出繞行剖面
    local mode, a, b, c, d, offL = C.plan({ 20, 30 }, { 2.2, -3.0 }, 2, NEED, CORR)
    checkEq(mode, "clear", "走廊邊緣的兩個障礙 → clear")
    checkEq(a, 0, "clear 的 a 為 0")
    checkEq(b, 0, "clear 的 b 為 0")
    checkEq(c, 0, "clear 的 c 為 0")
    checkEq(d, 0, "clear 的 d 為 0")
    checkEq(offL, 0, "clear 的 offL 為 0")

    -- 門檻是嚴格小於：恰好等於 CLR 的障礙算「不擋線」
    local m2 = C.plan({ 40 }, { CLR }, 1, NEED, CORR)
    checkEq(m2, "clear", "|l| 恰等於膨脹門檻 → 仍算不擋線")

    -- 差一點點就擋線
    local m3 = C.plan({ 40 }, { CLR - 0.05 }, 1, NEED, CORR)
    checkEq(m3, "dodge", "|l| 比門檻小 0.05 → 進入繞行")
end

-- =====================================================================
-- 情境二：單一擋線障礙 → dodge，往障礙的反側偏、斷點單調
-- =====================================================================
scenario("dodge：單一擋線障礙往反側偏，左右鏡像對稱、斷點單調")
do
    -- 障礙在 l = +1.5（右側偏一點）。可行 lane 必須 |l - 1.5| >= 2.1 → l <= -0.6；
    -- 格點錨在 0、步長 0.25 → 最靠中線的可行格點是 -0.75
    local mode, a, b, c, d, offL = C.plan({ 30 }, { 1.5 }, 1, NEED, CORR)
    checkEq(mode, "dodge", "障礙在右 → dodge")
    checkTrue(offL < 0, "障礙在右（l > 0）→ 往左偏（offL 為負）")
    checkEq(offL, -0.75, "offL ＝ 最靠中線的可行格點")
    checkTrue(math.abs(offL - 1.5) >= CLR - EPS, "選出的 lane 對障礙保有膨脹淨空")
    checkEq(a, 30 - 8, "a ＝ sObs0 - ENTRY")
    checkEq(b, 30 - 2, "b ＝ sObs0 - GAP")
    checkEq(c, 30 + 2, "c ＝ sObs1 + GAP")
    checkEq(d, 30 + 8, "d ＝ sObs1 + EXIT")
    checkMono(a, b, c, d, "單一障礙")

    -- 鏡像：同一場景左右翻轉必須得到符號相反、大小相同的結果
    local mMir, aMir, bMir, cMir, dMir, offMir = C.plan({ 30 }, { -1.5 }, 1, NEED, CORR)
    checkEq(mMir, "dodge", "鏡像場景同樣 dodge")
    checkEq(offMir, 0.75, "障礙在左 → 往右偏（offL ＝ +0.75，與鏡像大小相同）")
    checkEq(aMir, a, "鏡像不影響 a")
    checkEq(bMir, b, "鏡像不影響 b")
    checkEq(cMir, c, "鏡像不影響 c")
    checkEq(dMir, d, "鏡像不影響 d")

    -- 障礙就在眼前：a 夾在 >= 0，進入段被壓到 MIN_SEG = 2，單調性仍須成立
    local mNear, aNear, bNear, cNear, dNear, offNear = C.plan({ 1 }, { 1.5 }, 1, NEED, CORR)
    checkEq(mNear, "dodge", "障礙在 s = 1 仍規劃繞行")
    checkEq(aNear, 0, "a 夾在 >= 0（不得倒退到路線起點之前）")
    checkEq(bNear, 2, "進入段壓到 MIN_SEG ＝ 2")
    checkEq(cNear, 3, "c ＝ sObs1 + GAP（未被夾限）")
    checkEq(dNear, 9, "d ＝ sObs1 + EXIT")
    checkEq(offNear, -0.75, "近距離不改變 lane 選擇")
    checkMono(aNear, bNear, cNear, dNear, "障礙就在眼前")
end

-- =====================================================================
-- 情境二b：逐點半徑（hardR）——樹幹細桿 vs 整格箱型物
-- =====================================================================
scenario("hardR 逐點半徑：路緣樹（r=0）不擋線、同位置箱型物（r=0.7）擋線")
do
    -- 路緣樹 l=1.9：細桿門檻 0+1.4=1.4 < 1.9 → 不擋線＝clear（實機 2026-08-28：
    -- 統一肥半徑 2.1 把整排路緣樹判成擋路，車長期貼對側路緣不回中）
    local mTree = C.plan({ 30 }, { 1.9 }, 1, NEED, CORR, 0, { 0 })
    checkEq(mTree, "clear", "路緣樹 l=1.9（r=0）：門檻 1.4 → 不擋線")
    -- 同位置整格箱型物：0.7+1.4=2.1 > 1.9 → 擋線照繞
    local mBox = C.plan({ 30 }, { 1.9 }, 1, NEED, CORR, 0, { 0.7 })
    checkEq(mBox, "dodge", "同位置箱型物（r=0.7）：門檻 2.1 → 擋線繞行")
    -- 樹真擋路（l=0.5 < 1.4）照樣繞；縫隙判定也用細半徑（可行 lane 距樹 ≥1.4）
    local mT2, _, _, _, _, offT2 = C.plan({ 30 }, { 0.5 }, 1, NEED, 6.0, 0, { 0 })
    checkEq(mT2, "dodge", "路中樹（l=0.5）：照樣擋線繞行")
    checkTrue(offT2 <= 0.5 - 1.4 or offT2 >= 0.5 + 1.4,
        "繞樹的 lane 對樹幹保持 1.4 淨空（實得 " .. tostring(offT2) .. "）")
    -- hardR 缺項／壞值：該點退肥半徑（保守），不整批拒收
    local mBad = C.plan({ 30 }, { 1.9 }, 1, NEED, CORR, 0, { "x" })
    checkEq(mBad, "dodge", "hardR 壞值：該點退 OBS_HALF（保守擋線）")
    local mNil = C.plan({ 30 }, { 1.9 }, 1, NEED, CORR, 0, nil)
    checkEq(mNil, "dodge", "hardR 缺席：全部肥半徑（向後相容）")
    -- baseL 行駛基準線：樹 l=1.5 不擋中心線（1.5 ≥ 1.4）但擋 bias=1.0 的行駛線
    -- （|1.5-1|=0.5 < 1.4）→ 觸發繞行；縫隙搜尋以 prefer=1.0 由近而遠，第一個
    -- 對樹保有 1.4 淨空的格點是中心線 lane 0＝「借中線超樹段」（2026-08-28
    -- 實機：以中心線判擋線漏掉這類樹，車 lat=1.2 完美跟線直接蹭樹卡死 ×3）
    local mBase, _, _, _, _, offBase = C.plan({ 30 }, { 1.5 }, 1, NEED, 6.0, 1.0, { 0 }, 1.0)
    checkEq(mBase, "dodge", "樹擋行駛線（bias 1.0）：觸發繞行")
    checkEq(offBase, 0, "縫選中心線 lane 0（借中線超樹，距樹 1.5 ≥ 1.4）")
    checkEq(C.plan({ 30 }, { 1.5 }, 1, NEED, 6.0, 0, { 0 }, 0), "clear",
        "同一棵樹、沿中心線行駛（baseL 0）：不擋線")
    checkEq(C.plan({ 30 }, { 1.5 }, 1, NEED, 6.0, 1.0, { 0 }, 0 / 0), "clear",
        "baseL 為 NaN：當 0（向後相容），不炸")
end

-- =====================================================================
-- 情境三：雙障礙夾縫 → 走中間；不擋線的側邊障礙真的參與縫隙判定
-- =====================================================================
scenario("夾縫：擋線障礙 + 不擋線側邊障礙夾出的縫，offL 落在縫內且靠近縫中央")
do
    -- 障礙 A 在 +2.0（擋線，2.0 < 2.1）、障礙 B 在 -2.4（不擋線，但決定縫的另一邊）。
    -- 可行帶：l <= 2.0 - 2.1 = -0.1 且 l >= -2.4 + 2.1 = -0.3 → [-0.3, -0.1]
    -- 兩障礙中點 = (2.0 + (-2.4)) / 2 = -0.2；最靠中線的可行格點 = -0.25
    local mode, a, b, c, d, offL = C.plan({ 30, 30 }, { 2.0, -2.4 }, 2, NEED, CORR)
    checkEq(mode, "dodge", "縫寬足夠 → dodge")
    checkEq(offL, -0.25, "offL ＝ 縫內最靠中線的格點")
    checkTrue(offL >= -0.3 - EPS and offL <= -0.1 + EPS, "offL 落在解析可行帶 [-0.3, -0.1] 內")
    checkNear(offL, -0.2, 0.3, "offL 靠近兩障礙中點（-0.2）")
    local worst = worstClearance({ 30, 30 }, { 2.0, -2.4 }, 2, 30 - OBS, 30 + OBS, offL)
    checkTrue(worst >= CLR - EPS, "對縫兩側都保有膨脹淨空（實得最小淨空 "
        .. show(worst) .. "）")
    checkMono(a, b, c, d, "夾縫")

    -- 把不擋線的那顆從 -2.4 收到 -2.2：解析可行帶收成單點 l = -0.1，格點掃不到 → blocked。
    -- 這一組證明「不擋中心線的側邊障礙也參與縫隙判定」——否則結果會與上面一樣是 dodge。
    local mTight, aTight, bTight, cTight, dTight, offTight =
        C.plan({ 30, 30 }, { 2.0, -2.2 }, 2, NEED, CORR)
    checkEq(mTight, "blocked", "縫收窄到 0.2 公尺（< 格點步長）→ blocked")
    checkEq(offTight, 0, "blocked 的 offL 為 0")
    checkEq(aTight, 30, "blocked 的 a ＝ 障礙群起點")
    checkEq(bTight, 30, "blocked 的 b ＝ 障礙群起點")
    checkEq(cTight, 30, "blocked 的 c ＝ 障礙群終點")
    checkEq(dTight, 30, "blocked 的 d ＝ 障礙群終點")

    -- 同 |l| 時偏「數學負」＝PZ 世界的行進方向左側（Y 向南、數學 CCW＝實際順時針；
    -- 1993 肯塔基右側通行，超車走左）：障礙正對中線、走廊夠寬
    local _, _, _, _, _, offTie = C.plan({ 30 }, { 0 }, 1, NEED, 6.0)
    checkEq(offTie, -2.25, "障礙正對中線、左右對稱可行 → 走實際左側（數學負號）")

    -- preferL 側別黏著：同一顆中線障礙左右都可行時，跟著上輪的側別走，
    -- 不因量化跳動而換邊（換邊＝前視點單幀橫跳、車在障礙前左右甩）
    local _, _, _, _, _, offRight = C.plan({ 30 }, { 0 }, 1, NEED, 6.0, 2.25)
    checkEq(offRight, 2.25, "上輪走右 → 沿用右側")
    local _, _, _, _, _, offBad = C.plan({ 30 }, { 0 }, 1, NEED, 6.0, 0 / 0)
    checkEq(offBad, -2.25, "preferL 為 NaN → 當 0（回到實際左側預設），不炸")
    -- 首次繞行（driver 傳 laneBias 而非 0）：縫隙掃描以「現在實際行駛線」為
    -- 中心——障礙居中、左右縫對稱時，靠右行駛（bias +1.0）就該選右縫（橫移
    -- 1.25m）而不是 tie-break 固定的左縫（橫移 3.25m）
    local _, _, _, _, _, offBias = C.plan({ 30 }, { 0 }, 1, NEED, 6.0, 1.0)
    checkEq(offBias, 2.25, "首次繞行以 laneBias 為中心（+1.0 靠右）→ 選右縫")
    -- preferL 不是 STEP 倍數也必須比較原始距離，不能先四捨五入後固定左優先：
    -- +0.1 到右縫 +2.25 是 2.15m，到左縫 -2.25 是 2.35m。
    local _, _, _, _, _, offSmallRight = C.plan({ 30 }, { 0 }, 1, NEED, 6.0, 0.1)
    checkEq(offSmallRight, 2.25, "非格點 bias +0.1：右縫真實距離較近 → 選右")
    local _, _, _, _, _, offSmallLeft = C.plan({ 30 }, { 0 }, 1, NEED, 6.0, -0.1)
    checkEq(offSmallLeft, -2.25, "鏡像：非格點 bias -0.1 → 選左")
    -- 恰在兩格中點時兩者到 preferL 等距，應取較小 l（實際左側）。
    local _, _, _, _, _, offHalfRight = C.plan({ 30 }, { -1.5 }, 1, NEED, 6.0, 1.125)
    checkEq(offHalfRight, 1.0, "正半格 tie：1.0/1.25 等距 → 取較左的 1.0")
    local _, _, _, _, _, offHalfLeft = C.plan({ 30 }, { 1.5 }, 1, NEED, 6.0, -1.125)
    checkEq(offHalfLeft, -1.25, "負半格 tie：-1.25/-1.0 等距 → 取較左的 -1.25")
    -- 偏好側不可行時照樣換邊（黏著不是死守）：走廊半寬 4、第二顆障礙 l=+1.5
    -- 把右側（lane ≥ -0.6 全被 2.1 淨空要求吃掉）封死，唯一縫在左緣
    local _, _, _, _, _, offForce = C.plan({ 30, 30 }, { 0, 1.5 }, 2, NEED, 4.0, 2.25)
    checkTrue(offForce < 0, "偏好右側但右側被第二顆障礙封死 → 換左側（實得 "
        .. tostring(offForce) .. "）")
end

-- =====================================================================
-- 情境四：整排堵死 → blocked，回障礙群 s 範圍供煞停
-- =====================================================================
scenario("blocked：整排障礙橫跨走廊時回報障礙群範圍，不硬擠")
do
    local sArr = { 25, 25, 25, 25, 25 }
    local lArr = { -3, -1.5, 0, 1.5, 3 }
    local mode, a, b, c, d, offL = C.plan(sArr, lArr, 5, NEED, CORR)
    checkEq(mode, "blocked", "五顆橫排 → blocked")
    checkEq(a, 25, "a ＝ sObs0")
    checkEq(b, 25, "b ＝ sObs0")
    checkEq(c, 25, "c ＝ sObs1")
    checkEq(d, 25, "d ＝ sObs1")
    checkEq(offL, 0, "offL ＝ 0")

    -- 走廊半寬比車半寬還小（needHalf > corridorHalf）：可用半幅為負，一律 blocked
    local mNarrow, aNarrow = C.plan({ 30 }, { 0 }, 1, 4.0, 3.0)
    checkEq(mNarrow, "blocked", "車比走廊寬 → blocked")
    checkEq(aNarrow, 30, "blocked 仍回報障礙群起點")

    -- 只要放寬走廊，同一顆障礙就繞得過去（證明 blocked 不是硬編死路）
    local mWide, _, _, _, _, offWide = C.plan({ 30 }, { 0 }, 1, NEED, 5.0)
    checkEq(mWide, "dodge", "走廊放寬到半寬 5 公尺 → 同一顆障礙可繞")
    checkTrue(math.abs(offWide) >= CLR - EPS, "繞行 lane 對正中障礙保有膨脹淨空")
end

-- =====================================================================
-- 情境五：障礙群聚合 — 6 公尺內合併、遠的不合併、鏈式擴張與輪數上限
-- =====================================================================
scenario("群聚合：GROUP_GAP 內合併成一段持續側偏，超出的留給下一次規劃")
do
    -- (a) 相隔 4 公尺（<= 6）→ 一群：保持段 c - b 必須跨越兩顆
    local _, a1, b1, c1, d1 = C.plan({ 30, 34 }, { 1.5, 1.5 }, 2, NEED, CORR)
    checkEq(b1, 28, "群起點 30 → b = 28")
    checkEq(c1, 36, "群終點 34 → c = 36")
    checkTrue(c1 - b1 >= 34 - 30, "保持段跨越整個障礙群")
    checkMono(a1, b1, c1, d1, "相隔 4 公尺")

    -- (b) 相隔 20 公尺（> 6）→ 只處理近的那顆
    local _, a2, b2, c2, d2 = C.plan({ 30, 50 }, { 1.5, 1.5 }, 2, NEED, CORR)
    checkEq(b2, 28, "只取近障礙：b = 28")
    checkEq(c2, 32, "只取近障礙：c = 32（不跨到 s = 50）")
    checkEq(d2, 38, "只取近障礙：d = 38")
    checkMono(a2, b2, c2, d2, "相隔 20 公尺")

    -- (c) 鏈式擴張：30-35-40 每節 5 公尺 → 群 [30, 40]
    local _, _, b3, c3 = C.plan({ 30, 35, 40 }, { 1.5, 1.5, 1.5 }, 3, NEED, CORR)
    checkEq(b3, 28, "鏈式群起點 30")
    checkEq(c3, 42, "鏈式群終點 40（每節 5 公尺逐節串起來）")

    -- (d) 同一組資料倒序輸入 → 結果必須一致（多輪掃描的存在理由）
    local _, _, b4, c4 = C.plan({ 40, 35, 30 }, { 1.5, 1.5, 1.5 }, 3, NEED, CORR)
    checkEq(b4, b3, "倒序輸入的群起點與正序相同")
    checkEq(c4, c3, "倒序輸入的群終點與正序相同")

    -- (e) 輪數上限：11 節倒序鏈（每節 5 公尺）在最壞排序下每輪只串一節，
    --     8 輪用盡群邊界仍在成長＝沒收斂——截短的群會漏掉群尾障礙、算出擦撞
    --     剖面，所以 fail-safe 回 blocked（等下一輪；感知層天然輸出遞增，
    --     一輪就收斂，這條只防契約允許的最壞排序）。
    local sDesc, lDesc = {}, {}
    for i = 1, 11 do
        sDesc[i] = 85 - i * 5     -- 80, 75, ..., 30
        lDesc[i] = 1.5
    end
    local mDesc = C.plan(sDesc, lDesc, 11, NEED, CORR)
    checkEq(mDesc, "blocked", "最壞排序下 8 輪沒收斂：fail-safe 回 blocked（不拿截短群規劃）")

    -- 8 輪內收斂的倒序鏈（7 節）仍正常繞行：上限防的是「沒收斂」，不是「倒序」
    local sDesc7, lDesc7 = {}, {}
    for i = 1, 7 do
        sDesc7[i] = 65 - i * 5    -- 60, 55, ..., 30
        lDesc7[i] = 1.5
    end
    local m7, _, b7, c7 = C.plan(sDesc7, lDesc7, 7, NEED, CORR)
    checkEq(m7, "dodge", "7 節倒序鏈第 8 輪收斂：照常繞行")
    checkEq(b7, 28, "7 節倒序鏈群起點")
    checkEq(c7, 62, "7 節倒序鏈群終點 60 → c = 62")

    -- 同一組資料改成 s 遞增（感知層的自然輸出）→ 邊界即時生效，一輪就收完整群
    local sAsc, lAsc = {}, {}
    for i = 1, 11 do
        sAsc[i] = 25 + i * 5      -- 30, 35, ..., 80
        lAsc[i] = 1.5
    end
    local _, _, bAsc, cAsc = C.plan(sAsc, lAsc, 11, NEED, CORR)
    checkEq(bAsc, 28, "遞增輸入的群起點")
    checkEq(cAsc, 82, "遞增輸入一輪就串完整條鏈 → c = 82")
end

-- =====================================================================
-- 情境六：邊界防呆 — 筆數、缺項、非法半寬
-- =====================================================================
scenario("防呆：非法筆數／缺項一律當 0 筆，非法半寬回落預設值")
do
    local sArr, lArr = { 30 }, { 1.5 }   -- 這組資料在正常參數下是 dodge

    checkEq(C.plan(sArr, lArr, 0, NEED, CORR), "clear", "hardN = 0（明確空）→ clear")
    -- malformed 一律 fail-safe 回 blocked：「資料壞掉＝當作沒障礙」會讓已知硬障礙
    -- 被靜默降級成淨空、車直接開過去；壞資料該讓車停著等下一輪好資料
    checkEq(C.plan(sArr, lArr, -1, NEED, CORR), "blocked", "hardN 為負 → blocked（fail-safe）")
    checkEq(C.plan(sArr, lArr, 2.5, NEED, CORR), "blocked", "hardN 非整數 → blocked")
    checkEq(C.plan(sArr, lArr, "1", NEED, CORR), "blocked", "hardN 非數字 → blocked")
    checkEq(C.plan(sArr, lArr, nil, NEED, CORR), "blocked", "hardN 為 nil → blocked")
    checkEq(C.plan(sArr, lArr, 0 / 0, NEED, CORR), "blocked", "hardN 為 NaN → blocked")
    checkEq(C.plan(nil, lArr, 1, NEED, CORR), "blocked", "hardS 不是 table → blocked")
    checkEq(C.plan(sArr, nil, 1, NEED, CORR), "blocked", "hardL 不是 table → blocked")
    checkEq(C.plan("x", "y", 1, NEED, CORR), "blocked", "兩條陣列都不是 table → blocked")

    -- 缺項／非有限值 → 整批不信、fail-safe（不逐點跳過；理由見檔頭契約）
    checkEq(C.plan({ 30, 40 }, { 1.5 }, 2, NEED, CORR), "blocked", "hardL 缺第 2 格 → blocked")
    checkEq(C.plan({ 30 }, { 1.5, 1.5 }, 2, NEED, CORR), "blocked", "hardS 缺第 2 格 → blocked")
    checkEq(C.plan({ 30, 0 / 0 }, { 1.5, 1.5 }, 2, NEED, CORR), "blocked", "hardS 有 NaN → blocked")
    checkEq(C.plan({ 30, 40 }, { 1.5, "x" }, 2, NEED, CORR), "blocked", "hardL 有字串 → blocked")

    -- 非法 needHalf / corridorHalf → 回落預設 1.4 / 3.0，結果必須與顯式傳預設值一致
    local rm, ra, rb, rc, rd, ro = C.plan(sArr, lArr, 1, 1.4, 3.0)
    local badNeed = { 0, -1, 0 / 0, "1.4", nil }
    for i = 1, 5 do
        local m, a, b, c, d, o = C.plan(sArr, lArr, 1, badNeed[i], 3.0)
        checkEq(m, rm, "非法 needHalf 回落預設：mode 一致")
        checkEq(o, ro, "非法 needHalf 回落預設：offL 一致")
        checkTrue(a == ra and b == rb and c == rc and d == rd,
            "非法 needHalf 回落預設：四個斷點一致")
    end
    local badCorr = { 0, -2, 0 / 0, "3.0", nil }
    for i = 1, 5 do
        local m, a, b, c, d, o = C.plan(sArr, lArr, 1, 1.4, badCorr[i])
        checkEq(m, rm, "非法 corridorHalf 回落預設：mode 一致")
        checkEq(o, ro, "非法 corridorHalf 回落預設：offL 一致")
        checkTrue(a == ra and b == rb and c == rc and d == rd,
            "非法 corridorHalf 回落預設：四個斷點一致")
    end
    checkEq(ro, -0.75, "預設半寬下的 offL（作為上面兩組比較的基準值本身要正確）")

    -- 加寬走廊不改變「近中線優先」的選擇
    local _, _, _, _, _, offWide = C.plan(sArr, lArr, 1, NEED, 10.0)
    checkEq(offWide, ro, "走廊加寬到半寬 10 公尺 → 仍選最靠中線的同一格點")

    -- 回傳值一律六個純量、恆非 nil
    local m6, a6, b6, c6, d6, o6 = C.plan(sArr, lArr, 1, NEED, CORR)
    checkEq(type(m6), "string", "mode 是 string")
    checkTrue(type(a6) == "number" and type(b6) == "number"
        and type(c6) == "number" and type(d6) == "number" and type(o6) == "number",
        "a, b, c, d, offL 都是 number（恆非 nil）")
end

-- =====================================================================
-- 情境七：熱路徑守則 — plan 不改動輸入陣列、零 table 配置
-- =====================================================================
scenario("熱路徑守則：plan 視輸入為唯讀、單次與多次呼叫都不配置 table")
do
    local sArr = { 12, 18, 30, 34, 41, 60 }
    local lArr = { 2.6, -0.4, 1.5, 1.5, -2.9, 0.2 }
    local N = 6

    local function checksum()
        local acc = 0
        for i = 1, N do
            acc = acc + sArr[i] * 3 + lArr[i] * 7
        end
        return acc
    end

    local before = checksum()
    for k = 1, 500 do
        C.plan(sArr, lArr, N, NEED, CORR)
    end
    checkEq(checksum(), before, "plan 跑 500 次完全不改動輸入陣列（唯讀）")
    checkEq(#sArr, N, "hardS 長度沒被動到")
    checkEq(#lArr, N, "hardL 長度沒被動到")

    -- 零配置：關掉 GC 讓堆增量純粹反映配置量。
    -- 每次呼叫若建一個 table（Lua 5.4 空表約 56 bytes），2 萬次會多出 1MB 以上。
    local accS, accN = 0, 0
    collectgarbage("collect")
    collectgarbage("stop")
    local kb0 = collectgarbage("count")
    for k = 1, 20000 do
        local mode, a, b, c, d, offL = C.plan(sArr, lArr, N, 1.2 + (k % 5) * 0.1, CORR)
        accS = accS + a + b + c + d + offL
        if mode == "dodge" then accN = accN + 1 end
    end
    local kb1 = collectgarbage("count")
    collectgarbage("restart")
    checkTrue(accS == accS, "累加值是有限數（迴圈真的跑完了）")
    checkTrue(accN > 0, "迴圈裡確實走過 dodge 分支（不是空轉）")
    checkTrue(kb1 - kb0 < 16, "20000 次 plan 的堆增量 < 16KB（實得 "
        .. string.format("%.1f", kb1 - kb0) .. "KB；每次建一個 table 會是 1MB 以上）")

    -- 模組表面：該有的都在，且沒有任何 PZ 相依
    checkEq(type(C.plan), "function", "plan 存在")
    checkEq(C.OBS_HALF, 0.7, "OBS_HALF 常數")
    checkEq(C.GROUP_GAP, 6, "GROUP_GAP 常數")
    checkEq(C.ROUNDS_MAX, 8, "ROUNDS_MAX 常數")
    checkEq(C.ENTRY, 8, "ENTRY 常數")
    checkEq(C.EXIT, 8, "EXIT 常數")
    checkEq(C.GAP, 2, "GAP 常數")
    checkEq(C.MIN_SEG, 2, "MIN_SEG 常數")
    checkEq(C.STEP, 0.25, "STEP 常數")
    checkEq(C.NEED_HALF_DEFAULT, 1.4, "needHalf 預設值")
    checkEq(C.CORRIDOR_HALF_DEFAULT, 3.0, "corridorHalf 預設值")
end

-- =====================================================================
-- 情境九：路面帶兩遍搜尋 — 帶內縫優先於較近的帶外縫；帶內全滅才放開全域
-- =====================================================================
scenario("路面帶：帶內縫優先（即使帶外縫離 preferL 更近）、無帶資訊退回全域")
do
    -- 障礙 l=+0.5（擋中線；r 預設 0.7 → 擋帶 (-1.6, 2.6)）。可行 lane：<= -1.75
    -- 或 >= 2.75。走廊用 production 的 ±5（檔內 CORR=3 的可行域 ±1.6 兩側縫都
    -- 放不下）。preferL=0 時全域最近縫是 -1.75（|−1.75| < |2.75|）。
    -- 路面帶 [-1, 4]：-1.75 在帶外（草地）、2.75 在帶內 → 帶內優先選 2.75
    -- （2026-08-28 實機：右樹排把縫逼到左外 3.5m，車繞出路面在草地上跑）。
    local sArr, lArr = { 30 }, { 0.5 }
    local mode, _, _, _, _, offL = C.plan(sArr, lArr, 1, NEED, 5, 0, nil, 0, -1, 4)
    checkEq(mode, "dodge", "路面帶內有縫：dodge")
    checkEq(offL, 2.75, "帶內縫 2.75 優先於較近的帶外縫 -1.75")

    -- 無帶資訊（nil）＝舊行為：全域最近縫 -1.75
    local m2, _, _, _, _, off2 = C.plan(sArr, lArr, 1, NEED, 5, 0, nil, 0)
    checkEq(m2, "dodge", "無路面資訊：照樣 dodge")
    checkEq(off2, -1.75, "無路面資訊退回全域最近縫（向後相容）")

    -- 帶內全滅（帶只涵蓋被擋的範圍）→ 放開全域，仍回 -1.75 而不是 blocked
    local m3, _, _, _, _, off3 = C.plan(sArr, lArr, 1, NEED, 5, 0, nil, 0, -1, 2.5)
    checkEq(m3, "dodge", "帶內全滅：放開全域仍找得到縫（草地縫是最後手段、不是禁區）")
    checkEq(off3, -1.75, "全域縫＝-1.75")

    -- 壞帶（lo >= hi）＝無資訊
    local m4, _, _, _, _, off4 = C.plan(sArr, lArr, 1, NEED, 5, 0, nil, 0, 3, -3)
    checkEq(m4, "dodge", "壞帶（lo>=hi）：當無資訊處理")
    checkEq(off4, -1.75, "壞帶退回全域行為")
end

-- =====================================================================
-- 總結
-- =====================================================================
closeScenario()
print()
print("情境 " .. scenarios .. " 個、斷言 " .. assertions .. " 項")
if failures > 0 then
    print(failures .. " 項失敗")
    if os and os.exit then os.exit(1) end
    error(failures .. " 項失敗")
end
print("全部通過")
