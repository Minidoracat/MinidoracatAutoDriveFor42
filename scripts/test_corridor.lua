--[[
繞行縫隙規劃器與 current-pose footprint guard 的離線測試：載入真正的 production Lua。

    lua scripts/test_corridor.lua        （repo 根目錄或 scripts/ 執行皆可；標準 Lua 5.x）

為什麼需要（縫隙／車身幾何判定的錯誤 luac -p 與 smoke_harness 都抓不到）：
- 「車半寬有沒有膨脹進障礙」寫錯，遊戲裡的表徵是車擦著障礙開過去或明明過得去卻
  停在路中央。肉眼分不出是門檻少加了 OBS_HALF、還是群聚合把遠障礙拉進來
- 群聚合是「多輪線性掃描直到邊界不再擴張」（Kahlua 不准 table.sort），輪數上限
  截短群的行為必須有測試釘住，否則之後有人把上限改小會安靜地生出偏短的繞行段
- 斷點單調（a < b <= c < d）是側偏剖面的前提；障礙就在眼前時的夾限最容易破壞它
- 兩個純函式的「零 table 配置」沒有計數器就無法證明

本檔載入的 production（真檔，無任何 source-text 斷言）：
    shared/MDAD_Corridor.lua

不需要任何假 PZ 全域——corridor 是純數學模組，這正是它獨立成一檔的理由。

每個情境都包在 do ... end 裡：Lua 單一函式（含主 chunk）的 local 上限是 200 個，
情境用的暫時變數若全放檔案層級會頂到上限，之後新增一條斷言就編譯不過。

限制（必須誠實面對）：
- 本檔驗「(s, l) 點集 → 側偏剖面」與「hard 點集 → current OBB 淨空」兩層。
  點集本身正不正確（sprite 分類、走廊投影）屬 client/MDAD_Sensor 的責任，不在此驗
- 所有期望值都由測試自己按契約手算（planner 膨脹半徑、格點／群距，以及 footprint
  的 rectangle-vs-disk 與固定 0.15m），刻意不重用 production 常數推導
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
    -- 障礙在 l=+1.5。原最近 safe lane 是 -0.75；comfort refinement 只沿同一
    -- 側最多外推 0.75m，第一條達 need+0.7 的 lane 是 -1.50。
    local mode, a, b, c, d, offL = C.plan({ 30 }, { 1.5 }, 1, NEED, CORR)
    checkEq(mode, "dodge", "障礙在右 → dodge")
    checkTrue(offL < 0, "障礙在右（l > 0）→ 往左偏（offL 為負）")
    checkEq(offL, -1.5, "offL ＝ 同側最近的 comfort lane")
    checkTrue(math.abs(offL - 1.5) >= CLR + 0.7 - EPS,
        "comfort lane 對障礙多保留 0.7m（供 24 km/h margin）")
    checkEq(a, 30 - 8, "a ＝ sObs0 - ENTRY")
    checkEq(b, 30 - 2, "b ＝ sObs0 - GAP")
    checkEq(c, 30 + 2, "c ＝ sObs1 + GAP")
    checkEq(d, 30 + 8, "d ＝ sObs1 + EXIT")
    checkMono(a, b, c, d, "單一障礙")

    -- 鏡像：同一場景左右翻轉必須得到符號相反、大小相同的結果
    local mMir, aMir, bMir, cMir, dMir, offMir = C.plan({ 30 }, { -1.5 }, 1, NEED, CORR)
    checkEq(mMir, "dodge", "鏡像場景同樣 dodge")
    checkEq(offMir, 1.5, "障礙在左 → 往右 comfort lane（與鏡像大小相同）")
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
    checkEq(offNear, -1.5, "近距離不改變 comfort lane 選擇")
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
    -- baseL 行駛基準線：樹 l=1.5 不擋中心線、但擋 bias=1.0 的行駛線。
    -- 最近 safe 是 0；同側向左外推到 -0.75 才達 comfort。
    local mBase, _, _, _, _, offBase = C.plan({ 30 }, { 1.5 }, 1, NEED, 6.0, 1.0, { 0 }, 1.0)
    checkEq(mBase, "dodge", "樹擋行駛線（bias 1.0）：觸發繞行")
    checkEq(offBase, -0.75, "從中心線 safe lane 同側外推至 -0.75 comfort lane")
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

    -- 同 |l| 時先選實際左側的最近 safe，再保持同側最多外推 0.75m 找 comfort。
    local _, _, _, _, _, offTie = C.plan({ 30 }, { 0 }, 1, NEED, 6.0)
    checkEq(offTie, -3.0, "對稱障礙：左側 safe -2.25 同側外推到 comfort -3.0")

    -- preferL 側別黏著：不換側，只沿既有 safe lane 的同一側外推。
    local _, _, _, _, _, offRight = C.plan({ 30 }, { 0 }, 1, NEED, 6.0, 2.25)
    checkEq(offRight, 3.0, "上輪走右 → 右側 comfort 3.0")
    local _, _, _, _, _, offBad = C.plan({ 30 }, { 0 }, 1, NEED, 6.0, 0 / 0)
    checkEq(offBad, -3.0, "preferL NaN → 當 0，走左側 comfort")
    local _, _, _, _, _, offBias = C.plan({ 30 }, { 0 }, 1, NEED, 6.0, 1.0)
    checkEq(offBias, 3.0, "首次靠右 bias → 選右 safe，再同側外推 comfort")
    local _, _, _, _, _, offSmallRight = C.plan({ 30 }, { 0 }, 1, NEED, 6.0, 0.1)
    checkEq(offSmallRight, 3.0, "非格點 bias +0.1：維持右側並外推")
    local _, _, _, _, _, offSmallLeft = C.plan({ 30 }, { 0 }, 1, NEED, 6.0, -0.1)
    checkEq(offSmallLeft, -3.0, "鏡像 bias -0.1：維持左側並外推")
    -- safe tie-break 仍先較小 l；若同側 0.75m 內找到 comfort，才往外。
    local _, _, _, _, _, offHalfRight = C.plan({ 30 }, { -1.5 }, 1, NEED, 6.0, 1.125)
    checkEq(offHalfRight, 1.0, "正半格 tie：safe 1.0 已無同側 comfort，逐位元 fallback")
    local _, _, _, _, _, offHalfLeft = C.plan({ 30 }, { 1.5 }, 1, NEED, 6.0, -1.125)
    checkEq(offHalfLeft, -1.5, "負半格 tie：safe -1.25 同側外推到 comfort -1.5")
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
    checkEq(ro, -1.5, "預設半寬下的 comfort offL 基準值")

    -- 加寬走廊不會把 satisficing 變成 max-margin；達 0.8 即止。
    local _, _, _, _, _, offWide = C.plan(sArr, lArr, 1, NEED, 10.0)
    checkEq(offWide, ro, "走廊加寬仍在同一條最近 comfort lane 停止")

    -- 回傳值一律六個純量、恆非 nil
    local m6, a6, b6, c6, d6, o6 = C.plan(sArr, lArr, 1, NEED, CORR)
    checkEq(type(m6), "string", "mode 是 string")
    checkTrue(type(a6) == "number" and type(b6) == "number"
        and type(c6) == "number" and type(d6) == "number" and type(o6) == "number",
        "a, b, c, d, offL 都是 number（恆非 nil）")
end

-- =====================================================================
-- 情境七：熱路徑守則 — 兩個純函式都不改輸入陣列、零 table 配置
-- =====================================================================
scenario("熱路徑守則：plan／currentFootprintHit 唯讀，且呼叫期間不配置 table")
do
    local sArr = { 12, 18, 30, 34, 41, 60 }
    local lArr = { 2.6, -0.4, 1.5, 1.5, -2.9, 0.2 }
    local N = 6
    local fpS, fpL = { 14, 13.1 }, { 0, 0.2 }
    local fpX, fpY, fpR = { 104, 103.1 }, { 200, 200.2 }, { 0, 0.7 }
    local function footprintChecksum()
        local acc = 0
        for i = 1, 2 do
            acc = acc + fpS[i] * 3 + fpL[i] * 5 + fpX[i] * 7 + fpY[i] * 11
                + fpR[i] * 13
        end
        return acc
    end

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

    local fpBefore = footprintChecksum()
    for k = 1, 500 do
        C.currentFootprintHit(fpS, fpL, fpX, fpY, fpR, 2,
            100, 200, 0, 0.8, 2.9, 2.5)
    end
    checkEq(footprintChecksum(), fpBefore,
        "currentFootprintHit 跑 500 次完全不改動五條輸入陣列")
    checkEq(#fpS, 2, "footprint hardS 長度沒被動到")
    checkEq(#fpL, 2, "footprint hardL 長度沒被動到")
    checkEq(#fpX, 2, "footprint hardX 長度沒被動到")
    checkEq(#fpY, 2, "footprint hardY 長度沒被動到")
    checkEq(#fpR, 2, "footprint hardR 長度沒被動到")

    -- 零配置：關掉 GC 讓堆增量純粹反映配置量。
    -- 每次呼叫若建一個 table（Lua 5.4 空表約 56 bytes），2 萬次會多出 1MB 以上。
    local accS, accN, fpAcc, fpHits = 0, 0, 0, 0
    collectgarbage("collect")
    collectgarbage("stop")
    local kb0 = collectgarbage("count")
    for k = 1, 20000 do
        local mode, a, b, c, d, offL = C.plan(sArr, lArr, N, 1.2 + (k % 5) * 0.1, CORR)
        accS = accS + a + b + c + d + offL
        if mode == "dodge" then accN = accN + 1 end
        local blocked, actual, planned, hitIndex, hitS, hitL, hitX, hitY, poseOnly =
            C.currentFootprintHit(fpS, fpL, fpX, fpY, fpR, 2,
                100, 200, 0, 0.8, 2.9, 2.5)
        fpAcc = fpAcc + actual + planned + hitIndex + hitS + hitL + hitX + hitY
        if blocked and poseOnly then fpHits = fpHits + 1 end
    end
    local kb1 = collectgarbage("count")
    collectgarbage("restart")
    checkTrue(accS == accS, "累加值是有限數（迴圈真的跑完了）")
    checkTrue(accN > 0, "迴圈裡確實走過 dodge 分支（不是空轉）")
    checkTrue(fpAcc == fpAcc, "footprint 累加值是有限數（迴圈真的跑完了）")
    checkEq(fpHits, 20000, "配置 spy 每圈都走 footprint hit／poseOnly 分支")
    checkTrue(kb1 - kb0 < 16, "20000 次 plan＋currentFootprintHit 的堆增量 < 16KB（實得 "
        .. string.format("%.1f", kb1 - kb0) .. "KB；每次建一個 table 會是 1MB 以上）")

    -- 模組表面：該有的都在，且沒有任何 PZ 相依
    checkEq(type(C.plan), "function", "plan 存在")
    checkEq(type(C.currentFootprintHit), "function", "currentFootprintHit 存在")
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
    -- 障礙 l=+0.5。最近 safe 是 -1.75／+2.75；同側 comfort 外推後是
    -- -2.50／+3.50。路面帶 [-1,4] 只容得右 comfort，因此選 +3.50。
    local sArr, lArr = { 30 }, { 0.5 }
    local mode, _, _, _, _, offL = C.plan(sArr, lArr, 1, NEED, 5, 0, nil, 0, -1, 4)
    checkEq(mode, "dodge", "路面帶內有縫：dodge")
    checkEq(offL, 3.5, "路面內右 comfort 優先於較近的帶外 safe")

    -- 無帶資訊：全域先選左 safe -1.75，再同側外推到 -2.50。
    local m2, _, _, _, _, off2 = C.plan(sArr, lArr, 1, NEED, 5, 0, nil, 0)
    checkEq(m2, "dodge", "無路面資訊：照樣 dodge")
    checkEq(off2, -2.5, "無路面資訊：全域左 comfort")

    -- 帶內全滅 → 放開全域 comfort，不會變 blocked。
    local m3, _, _, _, _, off3 = C.plan(sArr, lArr, 1, NEED, 5, 0, nil, 0, -1, 2.5)
    checkEq(m3, "dodge", "帶內全滅：放開全域仍找得到縫")
    checkEq(off3, -2.5, "全域 comfort＝-2.50")

    -- 壞帶（lo >= hi）＝無資訊
    local m4, _, _, _, _, off4 = C.plan(sArr, lArr, 1, NEED, 5, 0, nil, 0, 3, -3)
    checkEq(m4, "dodge", "壞帶（lo>=hi）：當無資訊處理")
    checkEq(off4, -2.5, "壞帶退回全域 comfort")
end

-- =====================================================================
-- 情境十：comfort refinement — 寬縫滿額、窄縫逐位元 fallback、路面與側別不變
-- =====================================================================
scenario("comfort refinement：同側最多外推 0.75m，找不到即回原 safe lane")
do
    -- 靠路邊停車的兩個箱型點；最近 safe=2.75，向同側 3 格到 3.50 即達 comfort。
    local mode, _, _, _, _, off = C.plan(
        { 30, 30 }, { -0.5, 0.5 }, 2, NEED, 7, 1.0, { 0.7, 0.7 }, 1.0)
    checkEq(mode, "dodge", "黑車情境仍是 dodge")
    checkEq(off, 3.5, "黑車情境選最近同側 comfort lane 3.50")
    local _, _, _, _, _, offSafe = C.plan(
        { 30, 30 }, { -0.5, 0.5 }, 2, NEED, 7, 1.0, { 0.7, 0.7 }, 1.0,
        nil, nil, false)
    checkEq(offSafe, 2.75, "禁用 refinement 時保留 first-safe lane，供實體回饋 ban 重規劃")
    local minDist = math.min(math.abs(off + 0.5), math.abs(off - 0.5))
    checkNear(minDist - 2.0, 1.0, EPS,
        "對 Driver sweep 門檻 2.0 的推導 margin 為 1.0（可吃滿 24）")

    -- 走廊邊界只容得 normal safe，沒有 need+0.7 comfort；不得改 blocked。
    local mNarrow, _, _, _, _, offNarrow = C.plan({ 30 }, { 1.5 }, 1, NEED, 2.4, 0)
    checkEq(mNarrow, "dodge", "無 comfort 的窄走廊仍 fallback dodge")
    checkEq(offNarrow, -0.75, "窄走廊逐位元保留原 first-safe lane")

    -- 路面帶內只有 safe，帶外有 comfort；路面優先高於速度 comfort。
    local mRoad, _, _, _, _, offRoad = C.plan(
        { 30 }, { 0.5 }, 1, NEED, 5, 0, nil, 0, -2.0, -1.7)
    checkEq(mRoad, "dodge", "路面內 safe 仍可用")
    checkEq(offRoad, -1.75, "不為帶外 comfort 放棄路面內 safe")

    -- refinement 不換側、橫移硬上限 0.75m；達標即止，不跑到走廊邊緣。
    local _, _, _, _, _, offSide = C.plan({ 30 }, { 0 }, 1, NEED, 6, 2.25)
    checkTrue(offSide > 0, "既有右側 safe 維持右側")
    checkNear(offSide - 2.25, 0.75, EPS, "同側外推量恰為上限 0.75m")
    checkEq(C.COMFORT_EXTRA, 0.7, "comfort extra 由既有 margin 飽和點固定為 0.7")
end

-- =====================================================================
-- 情境十一：current-pose 車身 OBB — world 權威、壞資料 fail-closed
-- =====================================================================
scenario("current footprint：長車旋轉 OBB 對 point disk，另與 expected lane 做 OR-gate 歸因")
do
    local bodyX, bodyY = 100, 200
    local halfW, halfL = 0.8, 2.9 -- F350 近似 extents；長車前緣比 planner 掃描起點更早碰障礙

    -- 最近 actual clearance 必選第二點：車身座標 u=3.1、v=0.2、r=0.7。
    -- du=0.2、dv=0、disk=0.85，所以 actual=-0.65；expected lane=2.5 則 planned=+0.65。
    local sArr, lArr = { 14, 13.1 }, { 0, 0.2 }
    local xArr, yArr, rArr = { 104, 103.1 }, { 200, 200.2 }, { 0, 0.7 }
    local blocked, actual, planned, hitIndex, hitS, hitL, hitX, hitY, poseOnly =
        C.currentFootprintHit(sArr, lArr, xArr, yArr, rArr, 2,
            bodyX, bodyY, 0, halfW, halfL, 2.5)
    checkTrue(blocked, "F350 u=3.1／v=0.2／r=0.7 命中 current body")
    checkNear(actual, -0.65, EPS, "rectangle-vs-disk actual clearance")
    checkNear(planned, 0.65, EPS, "同一點對 expected lane 尚有正淨空")
    checkEq(hitIndex, 2, "多點時選 actual clearance 最小者")
    checkNear(hitS, 13.1, EPS, "回傳命中點 hardS")
    checkNear(hitL, 0.2, EPS, "回傳命中點 hardL")
    checkNear(hitX, 103.1, EPS, "world 模式原樣回傳權威 hardX")
    checkNear(hitY, 200.2, EPS, "world 模式原樣回傳權威 hardY")
    checkTrue(poseOnly, "actual hit 但 expected path clear → poseOnly")

    local nearBlocked, _, nearPlanned, _, _, _, _, _, nearPoseOnly =
        C.currentFootprintHit({ 13.1 }, { 0.2 }, { 103.1 }, { 200.2 }, { 0.7 }, 1,
            bodyX, bodyY, 0, halfW, halfL, 0.2)
    checkTrue(nearBlocked, "planned lane 靠近時 current body 仍命中")
    checkNear(nearPlanned, -1.65, EPS, "expected lane 貼點時 planned clearance 為負")
    checkEq(nearPoseOnly, false, "planned lane 也受威脅 → 非 poseOnly")

    -- 同一顆障礙移到 v=1.8：du=0.2、dv=1.0，圓角淨距
    -- sqrt(0.2²+1.0²)-0.85 > 0，不應只因落在 OBB 的 AABB 就誤擋。
    local clear, clearActual, _, clearIndex =
        C.currentFootprintHit({ 13.1 }, { 1.8 }, { 103.1 }, { 201.8 }, { 0.7 }, 1,
            bodyX, bodyY, 0, halfW, halfL, 2.5)
    checkEq(clear, false, "u=3.1／v=1.8 已離開 rounded OBB")
    checkNear(clearActual, math.sqrt(0.2 * 0.2 + 1.0) - 0.85, EPS,
        "未命中仍回最小正 actual clearance")
    checkEq(clearIndex, 1, "合法非命中 snapshot 仍回最近點索引")

    -- 半徑是逐點契約：同一 u=3.2，細桿 r=0 尚有 0.15m，箱型 r=0.7 已侵入 0.55m。
    local thin, thinActual = C.currentFootprintHit(
        { 13.2 }, { 0 }, { 103.2 }, { 200 }, { 0 }, 1,
        bodyX, bodyY, 0, halfW, halfL, 0)
    local box, boxActual = C.currentFootprintHit(
        { 13.2 }, { 0 }, { 103.2 }, { 200 }, { 0.7 }, 1,
        bodyX, bodyY, 0, halfW, halfL, 0)
    checkEq(thin, false, "hardR=0 細桿不命中")
    checkNear(thinActual, 0.15, EPS, "hardR=0 的 actual clearance")
    checkTrue(box, "hardR=0.7 箱型點命中")
    checkNear(boxActual, -0.55, EPS, "hardR=0.7 的 actual clearance")

    -- 45° 長車：先將車身座標的前角點旋回世界。corner distance 逐軸算，不用 AABB。
    local h45, c45 = math.pi * 0.25, math.sqrt(0.5)
    local u45, v45 = 3.45, 1.35
    local x45 = bodyX + u45 * c45 - v45 * c45
    local y45 = bodyY + u45 * c45 + v45 * c45
    local cornerHit, cornerActual = C.currentFootprintHit(
        { 13.45 }, { 1.35 }, { x45 }, { y45 }, { 0.7 }, 1,
        bodyX, bodyY, h45, halfW, halfL, 1.35)
    checkTrue(cornerHit, "45° 長車前角與 disk 相交")
    checkNear(cornerActual, math.sqrt(0.55 * 0.55 + 0.55 * 0.55) - 0.85, EPS,
        "45° 前角用 oriented rectangle 淨空")

    local uOutside, vOutside = 3.7, 1.2
    local xOutside = bodyX + uOutside * c45 - vOutside * c45
    local yOutside = bodyY + uOutside * c45 + vOutside * c45
    local cornerClear, cornerClearance = C.currentFootprintHit(
        { 13.7 }, { 1.2 }, { xOutside }, { yOutside }, { 0.7 }, 1,
        bodyX, bodyY, h45, halfW, halfL, 1.2)
    checkEq(cornerClear, false, "45° expanded AABB 角落不誤判為 OBB-disk 命中")
    checkNear(cornerClearance, math.sqrt(0.8 * 0.8 + 0.4 * 0.4) - 0.85, EPS,
        "AABB 角落保留正 clearance")

    -- X/Y 整組缺失＝感知快照破損：不做 Frenet 重建，一律 fail-closed。
    local noWorld, _, _, noWorldIndex = C.currentFootprintHit(
        { 13.1 }, { 0.2 }, nil, nil, { 0.7 }, 1,
        bodyX, bodyY, h45, halfW, halfL, 0)
    checkTrue(noWorld, "hardX/Y 整組缺失 → fail-closed blocked")
    checkEq(noWorldIndex, 0, "缺 world 陣列回 invalid hitIndex=0")

    -- 任一必要 parallel 格有洞／NaN 都拒絕整份 snapshot；hitIndex=0 是 invalid sentinel。
    local badNaN, _, _, badNaNIndex = C.currentFootprintHit(
        { 0 / 0 }, { 0.2 }, { 103.1 }, { 200.2 }, { 0.7 }, 1,
        bodyX, bodyY, 0, halfW, halfL, 2.5)
    checkTrue(badNaN, "hardS NaN → fail-closed")
    checkEq(badNaNIndex, 0, "NaN snapshot 回 invalid hitIndex=0")
    local badMissing, _, _, badMissingIndex = C.currentFootprintHit(
        { 13.1 }, {}, { 103.1 }, { 200.2 }, { 0.7 }, 1,
        bodyX, bodyY, 0, halfW, halfL, 2.5)
    checkTrue(badMissing, "hardL 缺項 → fail-closed")
    checkEq(badMissingIndex, 0, "缺項 snapshot 回 invalid hitIndex=0")
    local badWorld, _, _, badWorldIndex = C.currentFootprintHit(
        { 13.1 }, { 0.2 }, { 103.1 }, {}, { 0.7 }, 1,
        bodyX, bodyY, 0, halfW, halfL, 2.5)
    checkTrue(badWorld, "hardY 有洞 → fail-closed")
    checkEq(badWorldIndex, 0, "world parallel array 有洞 → invalid hitIndex=0")
    local badRadius, _, _, badRadiusIndex = C.currentFootprintHit(
        { 13.1 }, { 0.2 }, { 103.1 }, { 200.2 }, {}, 1,
        bodyX, bodyY, 0, halfW, halfL, 2.5)
    checkTrue(badRadius, "hardR 缺項 → fail-closed")
    checkEq(badRadiusIndex, 0, "radius parallel array 有洞 → invalid hitIndex=0")
end

-- =====================================================================
-- Long-vehicle trajectory OBB：中心點淨空但前角命中
-- =====================================================================
scenario("swept OBB：同一障礙對 SmallCar clear、對長車前角 hit")
do
    local px, py = 3.0, 1.2
    local centreRadius = math.sqrt(px * px + py * py)
    checkTrue(centreRadius > 1.0 + 0.2 + 0.15,
        "legacy centre-distance/half-width circle would report clear")
    local rr = 0.2 + 0.15
    local small = C.orientedDistanceSqUnchecked(0, 0, 1, 0, 1.0, 1.8, px, py)
    local long = C.orientedDistanceSqUnchecked(0, 0, 1, 0, 1.0, 3.0, px, py)
    checkTrue(small > rr * rr, "SmallCar front does not reach obstacle")
    checkTrue(long <= rr * rr, "long vehicle front corner hits obstacle")
    local rotated = C.orientedDistanceSqUnchecked(0, 0, 0, 1, 1.0, 3.0, px, py)
    checkTrue(rotated > rr * rr, "OBB heading, not an axis-aligned length box, controls the hit")
    local realType, typeCalls = type, 0
    _G.type = function(v) typeCalls = typeCalls + 1; return realType(v) end
    for _ = 1, 100 do
        C.orientedDistanceSqUnchecked(0, -1, 1, 0, 1, 2, 0, -2.2)
    end
    _G.type = realType
    checkEq(typeCalls, 0, "unchecked hard-pair helper performs no repeated type validation")
end

-- =====================================================================
-- thread()：車陣蛇行（2026-09-02）。plan() 只找固定 lane；錯落車陣要蛇行。
-- fixture 用「車輛」點雲：每台車 2×4 格、每格一點（r=0.7），與 Sensor 的
-- 格級幾何查詢同型。走廊 ±7、needHalf 1.1、halfL 2.2＝實機 Volvo。
-- =====================================================================
local function addCar(sArr, lArr, rArr, n, s0, l0, len, wid)
    -- 車體占 s∈[s0, s0+len)、l∈[l0, l0+wid)，格心取樣
    local s = s0 + 0.5
    while s < s0 + len do
        local l = l0 + 0.5
        while l < l0 + wid do
            n = n + 1
            sArr[n], lArr[n], rArr[n] = s, l, 0.7
            l = l + 1
        end
        s = s + 1
    end
    return n
end

local function threadWork()
    return {}, {}, {}
end

-- 折線每欄（2m）對點雲的橫向餘裕，測試端獨立實作：沿線內插 lane、對 s 窗
-- ±(halfL+r) 內的點量 |l−l_i|−r−need 的最小值
local function threadWorst(sArr, lArr, n, outS, outL, count, halfL, need)
    local worst = nil
    for k = 1, count - 1 do
        local s0, s1 = outS[k], outS[k + 1]
        local steps = math.max(1, math.floor((s1 - s0) / 0.5))
        for q = 0, steps do
            local t = q / steps
            local s = s0 + (s1 - s0) * t
            local l = outL[k] + (outL[k + 1] - outL[k]) * t
            for i = 1, n do
                if math.abs(sArr[i] - s) <= halfL + 0.7 then
                    local extra = math.abs(lArr[i] - l) - 0.7 - need
                    if worst == nil or extra < worst then worst = extra end
                end
            end
        end
    end
    return worst
end

scenario("thread：錯落車陣——固定 lane 無解、蛇行有解")
do
    local S, L, R = {}, {}, {}
    local n = 0
    -- 四台車交錯：s 14／28／42／56，各占半條路（l [-5,-1) 與 [1,5)），車距 10m
    -- （4.4m 車身要在兩台車之間橫移 2m 的物理下限：兩側 s 窗各 2.9m＋斜率 0.5），
    -- 路寬 ±5。plan() 對第一台的單次繞行 d 會落進第二台的 s 窗（回不了基準線）
    n = addCar(S, L, R, n, 14, -5, 4, 4)
    n = addCar(S, L, R, n, 28, 1, 4, 4)
    n = addCar(S, L, R, n, 42, -5, 4, 4)
    n = addCar(S, L, R, n, 56, 1, 4, 4)
    -- 兩側路緣外的圍籬（l=±6.5 一整排）：走廊到 ±7 但草地不可走
    for s = 8, 70 do
        n = n + 1; S[n], L[n], R[n] = s + 0.5, -6.5, 0.7
        n = n + 1; S[n], L[n], R[n] = s + 0.5, 6.5, 0.7
    end
    local mode, pa, pb, pc, pd = C.plan(S, L, n, 1.1, 7, 0, R, 0, -5, 5, true)
    checkEq(mode, "dodge", "plan：只看最近群（第一台），提一次側偏")
    -- 回歸終點 d 已回到基準線（被第二台擋住的線），掃掠覆蓋到 d+1 時車身前緣
    -- （+halfL+r）已伸進第二台＝世界掃掠必否決＝單次側偏機制在此無解
    checkTrue(pd + 1 + 2.2 + 0.7 >= 28.5, "plan：單次繞行回基準線後車身已伸進第二台（d=" .. tostring(pd) .. "）")
    local work, outS, outL = threadWork()
    local count, why, minExtra, maxSlope = C.thread(S, L, R, n, 1.1, 7,
        4, 0, 68, 2.2, 0.9, 0, -5, 5, work, outS, outL, 32)
    checkTrue(count >= 4, "thread：找到折線（節點 " .. tostring(count) .. "，why=" .. tostring(why) .. "）")
    if count >= 2 then
        checkNear(outS[1], 4, EPS, "thread：首節點在 sFrom")
        checkNear(outL[1], 0, EPS, "thread：首節點 lane＝laneFrom")
        checkTrue(outS[count] >= 68, "thread：末節點覆蓋到 sTo")
        local worst = threadWorst(S, L, n, outS, outL, count, 2.2, 1.1)
        checkTrue(worst ~= nil and worst >= -1e-9,
            "thread：折線每點對車陣淨空 ≥ needHalf（實得餘裕 " .. tostring(worst) .. "）")
        checkTrue(minExtra >= -1e-9 and minExtra <= (worst or 0) + 0.5,
            "thread：回報的 minExtra 與獨立量測同量級（" .. tostring(minExtra) .. "）")
        checkTrue(maxSlope <= 0.5 + EPS, "thread：斜率 ≤ 1m/2m（實得 " .. tostring(maxSlope) .. "）")
        -- 蛇行：第一台（l<0 側）從右邊過、第二台（l>0 側）從左邊過
        local function laneAt(s)
            for k = 1, count - 1 do
                if s >= outS[k] and s <= outS[k + 1] then
                    local t = (s - outS[k]) / (outS[k + 1] - outS[k])
                    return outL[k] + (outL[k + 1] - outL[k]) * t
                end
            end
            return outL[count]
        end
        checkTrue(laneAt(16) > 0, "thread：第一台車（左側）從右邊過")
        checkTrue(laneAt(30) < 0, "thread：第二台車（右側）從左邊過")
        checkTrue(laneAt(44) > 0 and laneAt(58) < 0, "thread：第三、四台照樣交錯")
        local endDev = math.abs(outL[count] - 0)
        checkTrue(endDev <= 1.0 + EPS, "thread：終點回到基準線附近（偏 " .. tostring(endDev) .. "）")
        -- 帶外（草地）成本高：全線都在路面帶內
        local off = false
        for k = 1, count do if outL[k] < -5 or outL[k] > 5 then off = true end end
        checkTrue(not off, "thread：有帶內解時不走草地")
    end
    -- work 重用：連跑三次結果逐位元相同（DP 不殘留上次狀態）
    local c1 = C.thread(S, L, R, n, 1.1, 7, 4, 0, 68, 2.2, 0.9, 0, -5, 5, work, outS, outL, 32)
    local firstS, firstL = {}, {}
    for k = 1, c1 do firstS[k], firstL[k] = outS[k], outL[k] end
    local c2 = C.thread(S, L, R, n, 1.1, 7, 4, 0, 68, 2.2, 0.9, 0, -5, 5, work, outS, outL, 32)
    local same = c1 == c2
    for k = 1, c1 do if outS[k] ~= firstS[k] or outL[k] ~= firstL[k] then same = false end end
    checkTrue(same, "thread：work 重用不殘留上次 DP 狀態（兩次結果相同）")
end

scenario("thread：實體牆＝無路；斜率不可行＝無路；壞參數")
do
    local S, L, R = {}, {}, {}
    local n = 0
    -- 整條路寬的牆（l -6.5..6.5 全擋）
    for l = -6, 6 do n = n + 1; S[n], L[n], R[n] = 20.5, l + 0.5, 0.7 end
    local work, outS, outL = threadWork()
    local count, why = C.thread(S, L, R, n, 1.1, 7, 4, 0, 40, 2.2, 0.9, 0, nil, nil, work, outS, outL, 32)
    checkEq(count, 0, "thread：整寬牆無路")
    checkEq(why, "nopath", "thread：無路 why=nopath（三種失敗分辨：band／start／nopath）")
    -- 兩台車緊貼（s 相鄰、左右互換）：2m 內要橫移 4m＝斜率 2 > 0.5，不可行
    S, L, R, n = {}, {}, {}, 0
    n = addCar(S, L, R, n, 14, -6, 4, 6)   -- 占 l [-6, 0)
    n = addCar(S, L, R, n, 18, 0, 4, 6)    -- 占 l [0, 6)，緊接著
    count, why = C.thread(S, L, R, n, 1.1, 7, 4, -3, 40, 2.2, 0.9, 0, nil, nil, work, outS, outL, 32)
    checkEq(count, 0, "thread：緊貼互換的兩台車＝斜率不可行，無路")
    -- 同樣兩台車拉開 12m（起點 lane -1，8m 內能橫移到 1.3 以右）：可蛇行
    S, L, R, n = {}, {}, {}, 0
    n = addCar(S, L, R, n, 14, -6, 4, 6)
    n = addCar(S, L, R, n, 30, 0, 4, 6)
    count, why = C.thread(S, L, R, n, 1.1, 7, 4, -1, 44, 2.2, 0.9, 0, nil, nil, work, outS, outL, 32)
    checkTrue(count >= 3, "thread：拉開 12m 可蛇行（why=" .. tostring(why) .. "）")
    -- 壞參數：sTo <= sFrom、work 缺、hardN 非整數
    count, why = C.thread(S, L, R, n, 1.1, 7, 4, 0, 4, 2.2, 0.9, 0, nil, nil, work, outS, outL, 32)
    checkEq(why, "badargs", "thread：sTo<=sFrom 拒收")
    count, why = C.thread(S, L, R, n, 1.1, 7, 4, 0, 40, 2.2, 0.9, 0, nil, nil, nil, outS, outL, 32)
    checkEq(why, "badargs", "thread：缺 work 拒收")
    count, why = C.thread(S, L, R, 1.5, 1.1, 7, 4, 0, 40, 2.2, 0.9, 0, nil, nil, work, outS, outL, 32)
    checkEq(why, "badargs", "thread：hardN 非整數拒收")
    count, why = C.thread(S, L, R, n, 1.1, 7, 4, 0, 4 + 2 * 65, 2.2, 0.9, 0, nil, nil, work, outS, outL, 32)
    checkEq(why, "capacity", "thread：超過 64 欄拒收")
    -- 起欄被擋（車現在的 lane 上就有點）＝無路
    S, L, R, n = {}, {}, {}, 0
    n = n + 1; S[n], L[n], R[n] = 5, 0, 0.7
    count, why = C.thread(S, L, R, n, 1.1, 7, 4, 0, 40, 2.2, 0.9, 0, nil, nil, work, outS, outL, 32)
    checkEq(why, "start", "thread：起欄被擋回 start（車已貼著障礙，不是沒路）")
    -- band：走廊寬度扣掉需求後放不下一格 lane
    count, why = C.thread(S, L, R, 0, 7.0, 7, 4, 0, 40, 2.2, 0.9, 0, nil, nil, work, outS, outL, 32)
    checkEq(why, "band", "thread：需求吃掉整條走廊回 band")
end

scenario("thread：直行可過時折線不亂扭；草地是最後手段")
do
    local S, L, R = {}, {}, {}
    local n = 0
    -- 只有右側一台車，左側整條空：折線只該偏一次再回來
    n = addCar(S, L, R, n, 20, 1, 4, 2)
    local work, outS, outL = threadWork()
    local count, why, minExtra, maxSlope = C.thread(S, L, R, n, 1.1, 7, 4, 1, 40, 2.2, 0.9, 1, -5, 5, work, outS, outL, 32)
    checkTrue(count >= 3 and count <= 12, "thread：單一障礙的折線節點有限（" .. tostring(count) .. "）")
    local minL = 99
    for k = 1, count do if outL[k] < minL then minL = outL[k] end end
    checkTrue(minL <= -0.5, "thread：從左邊繞過右側障礙（最左 " .. tostring(minL) .. "）")
    checkTrue(outL[count] >= 0 and outL[count] <= 2, "thread：終點回到基準線附近")
    -- 路面帶 ±3 全擋、只有草地（±3..±6）可走：帶外成本高但仍是解
    S, L, R, n = {}, {}, {}, 0
    for l = -3, 2 do n = n + 1; S[n], L[n], R[n] = 20.5, l + 0.5, 0.7 end
    count, why = C.thread(S, L, R, n, 1.1, 7, 4, 0, 40, 2.2, 0.9, 0, -3, 3, work, outS, outL, 32)
    checkTrue(count >= 3, "thread：只有草地可走時仍給折線（why=" .. tostring(why) .. "）")
    local wentOff = false
    for k = 1, count do if outL[k] < -3 or outL[k] > 3 then wentOff = true end end
    checkTrue(wentOff, "thread：折線確實走到帶外")
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
