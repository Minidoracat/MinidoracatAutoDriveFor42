--[[
路線跟隨核心的離線模擬測試：載入**真正的** shared/MDAD_Follower.lua，跑數值情境並斷言。

    lua scripts/test_follower.lua        （repo 根目錄或 scripts/ 執行皆可；標準 Lua 5.x）

為什麼需要（控制律的錯誤 luac -p 與 smoke_harness 都抓不到）：
- 控制律寫錯在遊戲裡的表徵是「車撞牆／原地繞圈／終點不停」。那種回歸只能靠肉眼，
  而肉眼看不出「積分項飽和」或「投影倒退 1 段」這種問題出在哪一條式子
- 速度規劃是連鎖遞推（曲率 → 反向制動 → 前向加速），任一項係數打錯都會安靜地
  生出一份「看起來很合理」的表；只有把數字跟解析式對起來才驗得出來
- 熱路徑不變式（每幀不建 table、不改 profile、budget 硬上限）沒有計數器就無法證明

本檔載入的 production（真檔，無任何 source-text 斷言）：
    shared/MDAD_Follower.lua

不需要任何假 PZ 全域——follower 是純數學模組，這正是它獨立成一檔的理由。
唯一的環境差異：math.atan2 在遊戲的 Kahlua 裡存在（原版用例
client/Foraging/ISBaseIcon.lua:210），標準 Lua 5.3 起改成 math.atan(y, x) 兩參數形式。
production 自己寫成 `math.atan2 or math.atan`，因此兩邊都不用打 shim。

每個情境都包在 do ... end 裡：Lua 單一函式（含主 chunk）的 local 上限是 200 個，
情境用的暫時變數若全放檔案層級會頂到上限，之後新增一條斷言就編譯不過。

限制（必須誠實面對）：
- 閉環情境用的是「簡化自行車模型」（轉向對應曲率、速度直接吃 targetSpeed），
  不是 PZ 的車輛物理。它能證明控制律會收斂、不發散、不卡死，**不能**證明實機手感；
  輪胎抓地、質量、impulse 施力點只能實機測（M3 的施力部分在 client 的 MDAD.Drive）
- 已知超出本模組職責的情境（刻意不斷言）：route 折返 180° 走同一條線（路網節點順序
  造成）時，前視＋只准前進的投影會讓車在折點附近繞圈。M3 的契約是「跟線」，
  折返路線的脫困屬於後續里程碑
- 座標一律當「1 tile ＝ 1 公尺」的平面，與 nav 回傳的 route.pts 同一空間
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

loadProduction("shared/MDAD_Follower.lua")

local F = MDADFollower

-- =====================================================================
-- 測試工具（與 scripts/smoke_harness.lua 同一套形狀）
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

local function checkFalse(v, label)
    return check(v == false, label .. "（實得 " .. show(v) .. "）")
end

local function checkNil(v, label)
    return check(v == nil, label .. "（實得 " .. show(v) .. "）")
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
-- 幾何小工具（測試自己算參考值，刻意不重用 production 的實作）
-- =====================================================================

local DT = 1 / 30      -- 遊戲傳的是真秒數（60fps 約 0.0167）；這裡取 30fps 當基準
local KMH = 3.6
local MAXV = 60        -- 情境共用的巡航上限（km/h）

local function mkRoute(pts)
    return { pts = pts }
end

-- n 個點、每段 step 公尺的東向直線
local function straight(n, step)
    local pts = {}
    for i = 0, n - 1 do
        pts[#pts + 1] = i * step
        pts[#pts + 1] = 0
    end
    return pts
end

-- 建到 ready，回 (profile, stepBuild 呼叫次數, route)
local function buildRoute(pts, maxSpeed, budget)
    local route = mkRoute(pts)
    local p, why = F.begin(route, maxSpeed)
    if not p then error("begin 意外失敗：" .. tostring(why)) end
    local calls = 0
    while not p.ready and calls < 100000 do
        F.stepBuild(p, budget or 4096)
        calls = calls + 1
    end
    if not p.ready then error("stepBuild 沒有收斂（疑似相位卡住）") end
    return p, calls, route
end

-- 沿折線走到弧長 sWant 的座標與該段朝向
local function pointAt(p, sWant)
    local n = p.n
    if sWant <= 0 then return p.x[1], p.y[1], p.segH[1] end
    if sWant >= p.length then return p.x[n], p.y[n], p.segH[n - 1] end
    local i = 1
    while i < n - 1 and p.s[i + 1] < sWant do i = i + 1 end
    local l = p.segLen[i]
    local t = (l > 0) and ((sWant - p.s[i]) / l) or 0
    return p.x[i] + (p.x[i + 1] - p.x[i]) * t,
        p.y[i] + (p.y[i + 1] - p.y[i]) * t,
        p.segH[i]
end

-- 全域最近距離（測試用，O(n)；production 刻意只在窗口內找，理由見其註解）
local function distToPath(p, x, y)
    local best
    for i = 1, p.n - 1 do
        local ax, ay = p.x[i], p.y[i]
        local ex, ey = p.x[i + 1] - ax, p.y[i + 1] - ay
        local l2 = ex * ex + ey * ey
        local t = 0
        if l2 > 0 then
            t = ((x - ax) * ex + (y - ay) * ey) / l2
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
        end
        local dx, dy = x - (ax + ex * t), y - (ay + ey * t)
        local d2 = dx * dx + dy * dy
        if best == nil or d2 < best then best = d2 end
    end
    return math.sqrt(best or 0)
end

-- 相鄰兩點的最大減速需求：證明「前向加速 pass 沒有破壞反向制動的可行性」
local function maxDecelDemand(p)
    local worst = 0
    for i = 1, p.n - 1 do
        local l = p.segLen[i]
        if l > 0 then
            local need = (p.v[i] * p.v[i] - p.v[i + 1] * p.v[i + 1]) / (2 * l)
            if need > worst then worst = need end
        end
    end
    return worst
end

-- 跨情境共用的兩條路線（在各自情境內建好）
local pLine   -- 21 點、每段 10m、全長 200m 的東向直線
local pSine   -- 41 點的 S 彎

-- =====================================================================
-- 情境一：begin — route 形狀／有限值／退化路徑／maxSpeed 夾限
-- =====================================================================
scenario("begin：route 形狀、座標有限值、退化路徑、maxSpeed 夾限")
do
    local function badRoute(route, label)
        local p, why = F.begin(route, 50)
        checkNil(p, label .. "：不回 profile")
        checkEq(why, "badroute", label .. "：理由是 badroute")
    end

    badRoute(nil, "route 為 nil")
    badRoute("nope", "route 是字串")
    badRoute(42, "route 是數字")
    badRoute({}, "route 沒有 pts")
    badRoute({ pts = "nope" }, "pts 不是 table")
    badRoute({ pts = {} }, "pts 是空表")
    badRoute({ pts = { 0, 0 } }, "只有一個點（nav 的 A* 真的會回 1 點）")
    badRoute({ pts = { 0, 0, 10 } }, "pts 長度是奇數")
    badRoute({ pts = { 0, 0, 10, 0 / 0 } }, "座標含 NaN")
    badRoute({ pts = { 0, 0, 1 / 0, 5 } }, "座標含 +Inf")
    badRoute({ pts = { 0, 0, -1 / 0, 5 } }, "座標含 -Inf")
    badRoute({ pts = { 0, 0, "10", 0 } }, "座標是字串")
    badRoute({ pts = { 5, 5, 5, 5, 5, 5 } }, "所有點重合（路徑長 0，投影／曲率全無意義）")

    local okRoute = mkRoute({ 0, 0, 10, 0 })
    local p = F.begin(okRoute, 50)
    checkEq(type(p), "table", "合法路線回 profile")
    checkFalse(p.ready, "begin 不做任何運算：ready 為 false")
    checkEq(p.phase, "geometry", "起始相位是 geometry")
    checkEq(p.cursor, 1, "起始 cursor")
    checkEq(p.n, 2, "點數＝#pts/2")
    checkEq(p.pointCount, 2, "pointCount 對外可讀")
    checkEq(p.route, okRoute, "profile 帶原 route 引用（呼叫端比對 identity 用）")
    checkEq(p.maxSpeed, 50, "maxSpeed 照收（km/h）")
    checkNear(p.maxSpeedMs, 50 / KMH, 1e-12, "maxSpeedMs＝maxSpeed/3.6")

    checkEq(F.begin(okRoute, nil).maxSpeed, F.MIN_SPEED_KMH, "maxSpeed 為 nil：夾到下限 12")
    checkEq(F.begin(okRoute, 0 / 0).maxSpeed, F.MIN_SPEED_KMH, "maxSpeed 為 NaN：夾到下限")
    -- 非有限值一律當「不可信」處理 → 夾到下限（不是上限）：沙盒值壞掉時寧可慢
    checkEq(F.begin(okRoute, 1 / 0).maxSpeed, F.MIN_SPEED_KMH, "maxSpeed 為 +Inf：夾到下限")
    checkEq(F.begin(okRoute, "60").maxSpeed, F.MIN_SPEED_KMH, "maxSpeed 是字串：夾到下限")
    checkEq(F.begin(okRoute, 3).maxSpeed, F.MIN_SPEED_KMH,
        "maxSpeed 低於曲率下限：抬到 12（否則曲率夾限上下顛倒）")
    checkEq(F.begin(okRoute, 9999).maxSpeed, 160, "maxSpeed 過大：夾到 160")
    checkEq(F.begin(okRoute, -50).maxSpeed, F.MIN_SPEED_KMH, "maxSpeed 為負：抬到下限")
end

-- =====================================================================
-- 情境二：stepBuild — 相位推進、每 call 上限、BUDGET_MAX 硬上限、route 唯讀
-- =====================================================================
scenario("stepBuild：相位單向推進、每 call 最多 budget 個點運算、BUDGET_MAX 硬上限")
do
    -- 點運算總數 ＝ geometry n ＋ brake (n-1) ＋ accel (n-1) ＝ 3n-2
    local p200, calls200 = buildRoute(straight(200, 10), MAXV, 8)
    checkTrue(p200.ready, "增量建表最終 ready")
    checkEq(calls200, 75, "budget=8：3*200-2=598 個點運算需要 ceil(598/8)=75 次呼叫")
    checkTrue(F.stepBuild(p200, 8), "已 ready 再呼叫：直接回 true")
    checkEq(p200.cursor, p200.n, "已 ready 不再推進 cursor")

    -- budget=1：每次呼叫剛好一個點運算；相位切換不算運算，但相位單向不回頭
    local pPhase = F.begin(mkRoute(straight(5, 10)), MAXV)
    local seen = { pPhase.phase }
    local oneByOne = 0
    while not pPhase.ready and oneByOne < 200 do
        F.stepBuild(pPhase, 1)
        if seen[#seen] ~= pPhase.phase then seen[#seen + 1] = pPhase.phase end
        oneByOne = oneByOne + 1
    end
    checkEq(table.concat(seen, ">"), "geometry>brake>accel>ready", "相位單向推進，不回頭")
    checkEq(oneByOne, 3 * 5 - 2 + 1,
        "budget=1、5 點：13 個點運算＋1 次收尾（budget 用完的那一幀還看不到 accel 結束）")

    -- BUDGET_MAX 硬上限：5000 點＝3*5000-2＝14998 個點運算，呼叫端給再大的 budget 也
    -- 不能一次做完（geometry 相位本身就有 5000 個運算 > 4096，第一次呼叫必然停在
    -- geometry 中途——這是「每幀最多花多少時間」的唯一保證）
    local pBig = F.begin(mkRoute(straight(5000, 2)), MAXV)
    checkEq(F.BUDGET_MAX, 4096, "BUDGET_MAX 常數")
    checkFalse(F.stepBuild(pBig, 1e9), "budget 給 10 億：仍被 BUDGET_MAX 夾住，一次做不完")
    checkEq(pBig.cursor, 4096 + 1, "第一次呼叫恰好做了 4096 個點運算（cursor 從 1 前進 4096）")
    checkEq(pBig.phase, "geometry", "第一次呼叫還停在 geometry 相位")
    local bigCalls = 1
    while not pBig.ready and bigCalls < 100 do
        F.stepBuild(pBig, 1e9)
        bigCalls = bigCalls + 1
    end
    checkTrue(pBig.ready, "續呼叫可以做完")
    checkEq(bigCalls, 4, "14998 個點運算 ÷ 4096 ＝ 4 次呼叫（ceil）")

    -- 爛 budget 一律夾成「至少推進一格」，不得空轉（空轉＝自駕永遠啟動不了）
    local function budgetProbe(budget, expectCursor, label)
        local p = F.begin(mkRoute(straight(300, 5)), MAXV)
        F.stepBuild(p, budget)
        checkEq(p.cursor, expectCursor, label)
    end
    budgetProbe(nil, 65, "budget 非數字：退回預設 64")
    budgetProbe(0 / 0, 65, "budget 為 NaN：退回預設 64")
    budgetProbe("8", 65, "budget 是字串：退回預設 64")
    budgetProbe(0, 2, "budget=0：至少做一個點運算")
    budgetProbe(-50, 2, "budget 為負：同樣夾成 1")
    budgetProbe(7.9, 8, "budget 是小數：floor 成 7")

    checkFalse(F.stepBuild(nil, 8), "profile 為 nil：回 false 不炸")
    checkFalse(F.stepBuild("nope", 8), "profile 不是 table：回 false")

    -- route 全程唯讀
    local snapPts = straight(50, 6)
    local snapCopy = {}
    for i = 1, #snapPts do snapCopy[i] = snapPts[i] end
    local _, _, snapRoute = buildRoute(snapPts, MAXV, 16)
    local drift = 0
    for i = 1, #snapPts do
        if snapPts[i] ~= snapCopy[i] then drift = drift + 1 end
    end
    checkEq(drift, 0, "建表全程不改動 route.pts（route 視為唯讀）")
    checkEq(#snapPts, 100, "也沒有往 pts 追加東西")
    checkEq(snapRoute.pts, snapPts, "route.pts 仍是原本那顆 table")
end

-- =====================================================================
-- 情境三：速度規劃 — 直線／末端制動／90° 彎／180° 假彎／重合點
-- =====================================================================
scenario("速度規劃：直線吃滿上限、末端反向制動、90° 彎限速、180° 假彎撞 12km/h 下限")
do
    pLine = buildRoute(straight(21, 10), MAXV)
    checkNear(pLine.length, 200, 1e-9, "累積弧長＝全長 200m")
    checkNear(pLine.s[11], 100, 1e-9, "第 11 點的累積弧長")
    checkNear(pLine.segLen[1], 10, 1e-9, "段長")
    checkNear(pLine.segH[1], 0, 1e-12, "東向直線的段朝向＝0")

    checkNear(pLine.v[1] * KMH, MAXV, 1e-9, "直線起點吃滿 maxSpeed")
    checkNear(pLine.v[16] * KMH, MAXV, 1e-9, "距終點 50m 仍是 maxSpeed")
    checkNear(pLine.v[21], 0, 1e-12, "終點速度 0（必須停下）")
    -- 反向制動：v[i] = sqrt(v[i+1]^2 + 2*BRAKE*L)，BRAKE=6（2026-08-29 動態
    -- 煞停距裁定：引擎實煞 ~10、取六成——終點與進彎不再提前 20m+ 收油）
    checkNear(pLine.v[20], math.sqrt(2 * 6 * 10), 1e-9, "終點前一點＝sqrt(2*6*10)")
    checkNear(pLine.v[19], math.sqrt(2 * 6 * 20), 1e-9, "再前一點＝sqrt(2*6*20)")
    -- v[18]＝min(sqrt(2·6·30)=18.97, maxV 16.67)：BRAKE=6 的制動段更短、
    -- 此點已被上限 clamp
    checkNear(pLine.v[18], MAXV / KMH, 1e-9, "制動段第三點已回到上限（BRAKE=6 制動段較短）")
    checkTrue(pLine.v[19] * KMH < MAXV, "第 19 點在制動段內")
    local over = 0
    for i = 1, pLine.n do
        if pLine.v[i] * KMH > MAXV + 1e-9 then over = over + 1 end
    end
    checkEq(over, 0, "沒有任何一點超過 maxSpeed")
    checkTrue(maxDecelDemand(pLine) <= 6 + 1e-6, "直線：沒有路段的減速需求超過 BRAKE=6 m/s²")

    -- 8m 段的直角彎：kappa=(pi/2)/8，v=sqrt(a_lat*ds/dθ)=sqrt(3.5*8/(pi/2))≈4.22 m/s≈15.2 km/h
    local pCorner = buildRoute({ 0, 0, 8, 0, 16, 0, 24, 0, 24, 8, 24, 16, 24, 24 }, MAXV)
    local expect90 = math.sqrt(3.5 * 8 / (math.pi / 2))
    checkNear(pCorner.v[4], expect90, 1e-9, "直角彎頂點速度＝sqrt(a_lat*ds/dθ)")
    checkTrue(pCorner.v[4] * KMH > F.MIN_SPEED_KMH, "直角彎沒有撞到 12 km/h 下限（約 15.2）")
    checkTrue(pCorner.v[4] * KMH < MAXV * 0.5, "直角彎確實遠慢於 maxSpeed")
    checkTrue(pCorner.v[3] > pCorner.v[4], "彎前一點比彎頂快（反向制動生效）")
    checkNear(pCorner.v[3], math.sqrt(pCorner.v[4] * pCorner.v[4] + 2 * 6 * 8), 1e-9,
        "彎前制動量＝2*BRAKE*L（BRAKE=6）")
    checkNear(pCorner.v[5], math.sqrt(pCorner.v[4] * pCorner.v[4] + 2 * 2.5 * 8), 1e-9,
        "彎後一點被前向加速上限壓住＝sqrt(v_corner^2+2*ACCEL*L)（ACCEL=2.5）")
    checkTrue(maxDecelDemand(pCorner) <= 6 + 1e-6,
        "直角彎路線：前向 pass 沒有破壞反向制動的可行性")

    -- 180° 假彎（路網節點順序會生出這種折返）：
    -- sqrt(3.5*8/pi)=2.985 m/s=10.7 km/h < 12，被下限抬起來，否則車會停在路口出不來
    local hairPts = { 0, 0, 8, 0, 16, 0, 8, 0, 0, 0 }
    local pHair = buildRoute(hairPts, MAXV)
    checkNear(pHair.segH[3], math.pi, 1e-12, "折返段朝向＝180°")
    checkNear(pHair.v[3] * KMH, F.MIN_SPEED_KMH, 1e-9, "180° 假彎撞到 12 km/h 下限")
    local pHairSlow = buildRoute(hairPts, 8)
    checkEq(pHairSlow.maxSpeed, F.MIN_SPEED_KMH, "maxSpeed 低於下限時被抬到 12")
    checkNear(pHairSlow.v[3] * KMH, F.MIN_SPEED_KMH, 1e-9, "上下限相等時曲率限速仍是 12")

    -- 重合點（nav 的節點量化後可能與前一點相同）：不得偽造急彎。
    -- 北向直線＋一個重合點：若段朝向退回 atan2(0,0)=0（假的「朝東」），
    -- 這裡會生出一個假 90° 彎、把整條直路砍到 12 km/h
    local dupPts = { 0, 0, 0, 10, 0, 10 }
    for k = 2, 20 do
        dupPts[#dupPts + 1] = 0
        dupPts[#dupPts + 1] = k * 10
    end
    local pDup = buildRoute(dupPts, MAXV)
    checkNear(pDup.segLen[2], 0, 1e-12, "重合段長度 0")
    checkNear(pDup.segH[1], math.pi / 2, 1e-12, "北向段朝向＝90°")
    checkNear(pDup.segH[2], pDup.segH[1], 1e-12, "重合段沿用前一段朝向")
    checkNear(pDup.v[2] * KMH, MAXV, 1e-9, "重合點沒有被偽造的急彎拖慢")
    checkNear(pDup.v[3] * KMH, MAXV, 1e-9, "重合點後一點同樣不受影響")

    -- 兩點路線（最短的合法路線）
    local pTwo = buildRoute({ 0, 0, 30, 0 }, MAXV)
    checkNear(pTwo.length, 30, 1e-9, "兩點路線的長度")
    checkNear(pTwo.v[2], 0, 1e-12, "兩點路線的終點也要停")
    -- sqrt(2·6·30)=18.97 m/s > maxV 16.67：起點被上限 clamp
    checkNear(pTwo.v[1], MAXV / KMH, 1e-9, "兩點路線的起點速度由制動距離／上限共同決定（BRAKE=6 下被上限 clamp）")

    -- 折點角度限速下限：路網 polyline 在交叉口的點距常常很大（20-30m），
    -- kappa=Δθ/ds 被長段稀釋，曲率公式對急彎算出高速「限速」——2026-08-28 實機
    -- 61.5 km/h 過路口直接甩出路面。角度本身另設上限，點距再大也稀釋不掉。
    local pWide90 = buildRoute({ 0, 0, 30, 0, 60, 0, 60, 30, 60, 60 }, MAXV)
    -- 曲率公式在 30m 點距下給 sqrt(3.5*30/(π/2)) ≈ 8.18 m/s ≈ 29.4 km/h；
    -- 90° ≥ TURN_HARD(40°) → 硬上限 18 km/h
    checkNear(pWide90.v[3] * KMH, 18, 1e-9,
        "大點距 90° 折點：角度硬上限 18 km/h（曲率公式被點距稀釋到 29 也壓得住）")
    -- 25° 折點（SOFT 20° 與 HARD 40° 之間）：上限從 maxSpeed 線性壓向 18——
    -- t=(25-20)/20=0.25 → cap = 16.67 + (5 - 16.67)*0.25 ≈ 13.75 m/s ≈ 49.5 km/h，
    -- 低於曲率公式的 55.8，取角度上限
    local a25 = 25 * math.pi / 180
    local x3, y3 = 60 + 30 * math.cos(a25), 30 * math.sin(a25)
    local x4, y4 = x3 + 30 * math.cos(a25), y3 + 30 * math.sin(a25)
    local p25 = buildRoute({ 0, 0, 30, 0, 60, 0, x3, y3, x4, y4 }, MAXV)
    local cap25 = (MAXV / KMH) + (18 / KMH - MAXV / KMH) * 0.25
    checkNear(p25.v[3], cap25, 1e-9,
        "25° 折點（SOFT 與 HARD 之間）：線性過渡上限（≈49.5 km/h）")
    -- 小折角（< 20°）不受影響：8m 段 10° 折點的曲率限速 sqrt(3.5*8/0.1745)
    -- ≈ 12.67 m/s < maxSpeed → 曲率值本身生效，角度上限不介入。
    -- 路線尾巴多留 32m：終點反向制動鏈 sqrt(2*3*32)=13.9 > 12.67 才不會蓋過曲率值
    local a10 = 10 * math.pi / 180
    local q3, q4 = 16 + 8 * math.cos(a10), 8 * math.sin(a10)
    local c10, s10 = math.cos(a10), math.sin(a10)
    local p10 = buildRoute({ 0, 0, 8, 0, 16, 0, q3, q4,
        q3 + 8 * c10, q4 + 8 * s10, q3 + 16 * c10, q4 + 16 * s10,
        q3 + 24 * c10, q4 + 24 * s10, q3 + 32 * c10, q4 + 32 * s10 }, MAXV)
    checkNear(p10.v[3], math.sqrt(3.5 * 8 / a10), 1e-9,
        "10° 小折角：照走曲率公式，角度上限不介入")
end

-- =====================================================================
-- 情境四：control — 直線零轉向、左右偏差正負對稱、投影窗口與防倒退
-- =====================================================================
scenario("control：直線零轉向、左右偏差對稱、投影窗口 +12 段、單幀最多倒退 1 段")
do
    local st = F.newState()
    checkEq(st.idx, 1, "newState 的初始段")
    checkEq(st.iTerm, 0, "newState 的初始積分項")
    checkFalse(st.rotating, "newState 不在調頭模式")

    local steer, tspd, rem, reached, err, latSq = F.control(pLine, st, 0, 0, 0, 0, DT)
    checkNear(steer, 0, 1e-12, "完全在直線上、車頭對齊：轉向恰好 0")
    checkNear(err, 0, 1e-12, "朝向誤差 0")
    checkNear(rem, 200, 1e-9, "剩餘距離＝全長")
    checkNear(latSq, 0, 1e-12, "壓線：橫偏平方 0")
    checkFalse(reached, "起點不算抵達")
    checkNear(tspd, MAXV, 1e-9, "起點目標速度＝maxSpeed")
    checkEq(st.iTerm, 0, "零誤差不累積積分項")
    checkEq(st.idx, 1, "還在第 1 段")

    -- 左右偏差：路徑沿 +x，車在 y=-2（南側）時要往 +heading 方向修正
    local stL = F.newState()
    local steerL, _, remL, _, errL, latL = F.control(pLine, stL, 100, -2, 0, 30, DT)
    local stR = F.newState()
    local steerR, _, _, _, errR, latR = F.control(pLine, stR, 100, 2, 0, 30, DT)
    checkNear(latL, 4, 1e-9, "偏 2m：lateralSq = 4（平方、無符號）")
    checkNear(latR, 4, 1e-9, "另一側同距：lateralSq 同值")
    checkTrue(steerL > 0, "車在路徑南側（y=-2）、車頭朝東：steer > 0（往 heading 變大的方向轉）")
    checkTrue(steerR < 0, "車在路徑北側（y=+2）：steer < 0")
    checkNear(steerL, -steerR, 1e-12, "左右同幅度偏差：轉向量對稱")
    checkNear(errL, -errR, 1e-12, "朝向誤差對稱")
    checkNear(remL, 100, 1e-9, "橫向偏差不影響沿路徑的剩餘距離")
    checkEq(stL.idx, 10,
        "x=100 是第 10、11 段的共同端點：取先找到的第 10 段（strict < 的平手規則）")
    -- 前視點在 100 + 6 + 30*0.12 = 109.6 處，橫向偏差 2m
    checkNear(errL, math.atan(2 / 9.6), 1e-12, "誤差＝atan2(橫向偏差, 前視距離)")
    checkNear(steerL, 2.2 * errL + 0.15 * errL * DT, 1e-12,
        "重設後第一幀 steer = P + I（errPrev 留空 → D 貢獻 0）")

    -- 空 table 當 state：與 newState 完全同結果，且欄位就地補齊
    local bare = {}
    checkNear(F.control(pLine, bare, 100, -2, 0, 30, DT), steerL, 1e-12,
        "空 table 當 state：結果與 newState 一致")
    checkEq(bare.idx, 10, "control 就地補寫 state 欄位")
    checkEq(bare.rotating, false, "調頭旗標也補寫")

    -- state 欄位被寫壞（舊 session 殘留／外部亂改）：一律回退預設，不得傳染出 NaN
    local junk = { idx = "nope", iTerm = 0 / 0, errPrev = "x", dFilt = 1 / 0, rotating = "yes" }
    local sJunk, tJunk, rJunk, _, eJunk = F.control(pLine, junk, 100, -2, 0, 30, DT)
    checkNear(sJunk, steerL, 1e-12, "壞掉的 state 欄位一律回退預設")
    checkTrue(tJunk == tJunk and rJunk == rJunk and eJunk == eJunk,
        "壞掉的 state 不會讓回傳值變成 NaN")
    checkEq(junk.idx, 10, "壞掉的 idx 被就地修正")

    -- 投影窗口：每幀最多往前 12 段，瞬移不會一次跳到底（自我交叉路線的保護）
    local stJump = F.newState()
    local _, _, remJump = F.control(pLine, stJump, 180, 0, 0, 0, DT)
    checkEq(stJump.idx, 13, "投影窗口只往前 12 段（idx 1 → 13）")
    checkNear(remJump, 70, 1e-9, "剩餘距離跟著窗口上限（下一幀再往前收斂）")
    local _, _, remJump2 = F.control(pLine, stJump, 180, 0, 0, 0, DT)
    checkNear(remJump2, 20, 1e-9, "第二幀收斂到 x=180")

    -- 防倒退：單幀最多退 1 段
    local stBack = F.newState()
    F.control(pLine, stBack, 100, 0, 0, 0, DT)
    checkEq(stBack.idx, 10, "先推進到第 10 段")
    F.control(pLine, stBack, 0, 0, 0, 0, DT)
    checkEq(stBack.idx, 9, "車被撞回起點：單幀只退 1 段")
    F.control(pLine, stBack, 0, 0, 0, 0, DT)
    checkEq(stBack.idx, 8, "下一幀再退 1 段（逐幀收斂，不瞬移）")

    -- 前視距離：clamp(6 + |speed| * 0.12, 6, 18)。用「誤差＝atan2(橫向, 前視)」反推
    local function lookaheadOf(speed)
        local s = F.newState()
        local _, _, _, _, e = F.control(pLine, s, 100, -2, 0, speed, DT)
        return 2 / math.tan(e)
    end
    checkNear(lookaheadOf(0), 6, 1e-9, "速度 0：前視 6m（下限）")
    checkNear(lookaheadOf(-40), 6 + 40 * 0.12, 1e-9, "倒車 -40 km/h：取絕對值")
    checkNear(lookaheadOf(50), 6 + 50 * 0.12, 1e-9, "50 km/h：前視 12m")
    checkNear(lookaheadOf(200), 18, 1e-9, "200 km/h：夾在上限 18m")
end

-- =====================================================================
-- 情境五：control 防呆 — profile 未 ready／nil、爛座標、爛 dt
-- =====================================================================
scenario("control 防呆：profile 未建完／nil、座標非有限、dt 異常都不炸且不亂轉")
do
    local pRaw = F.begin(mkRoute(straight(10, 10)), MAXV)
    local stRaw = F.newState()
    local s, t, r, c, e = F.control(pRaw, stRaw, 0, 0, 0, 0, DT)
    checkEq(s, 0, "profile 還沒建完：不轉向")
    checkEq(t, 0, "profile 還沒建完：不給速度")
    checkEq(r, 0, "profile 還沒建完：剩餘距離 0")
    checkFalse(c, "profile 還沒建完：不算抵達")
    checkEq(e, 0, "profile 還沒建完：誤差 0")
    checkEq(stRaw.idx, 1, "profile 還沒建完：不動 state")

    checkEq(select("#", F.control(nil, stRaw, 0, 0, 0, 0, DT)), 7, "profile 為 nil 也回七個值")
    -- 帶號橫偏（第 7 值）：正＝行進方向右側（PZ 世界 CCW 法向），與 laneBias 同座標
    do
        local st7 = F.newState()
        local _, _, _, _, _, sq7, lt7 = F.control(pLine, st7, 60, 2, 0, 10, DT)
        checkNear(lt7, 2, 1e-9, "車在線右側 2m：latSigned = +2")
        checkNear(sq7, 4, 1e-9, "無號 lateralSq 仍是距離平方（向後相容）")
        local _, _, _, _, _, _, lt7b = F.control(pLine, st7, 60, -1.5, 0, 10, DT)
        checkNear(lt7b, -1.5, 1e-9, "車在線左側 1.5m：latSigned = -1.5")
    end
    checkEq((F.control(nil, stRaw, 0, 0, 0, 0, DT)), 0, "profile 為 nil：steer 0")
    checkEq((F.control("nope", stRaw, 0, 0, 0, 0, DT)), 0, "profile 不是 table：steer 0")
    checkEq((F.control(pLine, nil, 0, 0, 0, 0, DT)), 0, "state 為 nil：steer 0")
    checkEq((F.control(pLine, "nope", 0, 0, 0, 0, DT)), 0, "state 不是 table：steer 0")

    local stNaN = F.newState()
    local sN, tN, rN, cN, eN = F.control(pLine, stNaN, 0 / 0, 0, 0, 30, DT)
    checkEq(sN, 0, "座標 NaN：不轉向")
    checkEq(tN, 0, "座標 NaN：不給速度")
    checkNear(rN, pLine.length, 1e-9, "座標 NaN：剩餘距離照實回報全長")
    checkFalse(cN, "座標 NaN：不算抵達")
    checkEq(eN, 0, "座標 NaN：誤差 0")
    checkEq((F.control(pLine, stNaN, 0, 1 / 0, 0, 30, DT)), 0, "y 為 Inf：不轉向")
    checkEq((F.control(pLine, stNaN, 0, 0, 0 / 0, 30, DT)), 0, "heading 為 NaN：不轉向")

    -- dt 的爛值：夾限而非傳染。重設後第一幀 D 貢獻 0，所以方向與幅度都該正常
    local function dtProbe(dtv, label)
        local s2 = F.newState()
        local sv, tv, rv, _, ev = F.control(pLine, s2, 100, -2, 0, 30, dtv)
        checkTrue(sv == sv and tv == tv and rv == rv and ev == ev, label .. "：回傳都是有限數")
        checkTrue(sv > 0 and sv <= F.STEER_MAX, label .. "：轉向方向正確且在限幅內")
    end
    dtProbe(0, "dt=0")
    dtProbe(-5, "dt 為負")
    dtProbe(0 / 0, "dt 為 NaN")
    dtProbe(1 / 0, "dt 為 +Inf")
    dtProbe(1e9, "dt 超大")
    dtProbe(nil, "dt 為 nil")
    dtProbe("x", "dt 是字串")

    local stSpd = F.newState()
    local _, tSpd = F.control(pLine, stSpd, 0, 0, 0, 0 / 0, DT)
    checkNear(tSpd, MAXV, 1e-9, "speed 為 NaN：當 0 處理，仍給得出目標速度")
end

-- =====================================================================
-- 情境六：S 彎 — 沿路徑前進時投影單調（帶橫向偏差也不例外）
-- =====================================================================
scenario("S 彎：remaining 單調不增、idx 單調不減、回傳值全程有限")
do
    local pts = {}
    for k = 0, 40 do
        pts[#pts + 1] = k * 5
        pts[#pts + 1] = 8 * math.sin(k * 0.3)
    end
    pSine = buildRoute(pts, MAXV, 32)
    checkTrue(pSine.length > 200, "S 彎路徑長度合理（實得 " .. show(pSine.length) .. "m）")
    checkTrue(maxDecelDemand(pSine) <= 6 + 1e-6, "S 彎：沒有路段的減速需求超過 BRAKE")
    local vMin = pSine.v[1]
    for i = 1, pSine.n do
        if pSine.v[i] < vMin then vMin = pSine.v[i] end
    end
    checkTrue(vMin >= 0, "沒有負速度")

    for _, offset in ipairs({ 0, 1.2, -1.2 }) do
        local st = F.newState()
        local prevRem, prevIdx = pSine.length + 1, 0
        local badRem, badIdx, badFinite, frames = 0, 0, 0, 0
        local reachedRem
        local sPos = 0
        while sPos <= pSine.length and frames < 5000 do
            local cx, cy, ch = pointAt(pSine, sPos)
            local nx, ny = -math.sin(ch), math.cos(ch)
            local steer, tspd, rem, reached, err =
                F.control(pSine, st, cx + nx * offset, cy + ny * offset, ch, 30, DT)
            if rem > prevRem + 1e-9 then badRem = badRem + 1 end
            if st.idx < prevIdx then badIdx = badIdx + 1 end
            if not (steer == steer and tspd == tspd and rem == rem and err == err) then
                badFinite = badFinite + 1
            end
            if reached and not reachedRem then reachedRem = rem end
            prevRem, prevIdx = rem, st.idx
            sPos = sPos + 1
            frames = frames + 1
        end
        local tag = "（橫向偏移 " .. show(offset) .. "m）"
        checkEq(badRem, 0, "沿路徑前進時 remaining 從不增加" .. tag)
        checkEq(badIdx, 0, "idx 從不倒退" .. tag)
        checkEq(badFinite, 0, "全程回傳值都是有限數" .. tag)
        checkTrue(reachedRem ~= nil and reachedRem <= F.ARRIVE_M, "走到終點會回報 reached" .. tag)
        -- 走訪步長 1m，所以最後一幀落在終點前 1m 內（不是恰好 0）
        checkTrue(prevRem < 2,
            "終點 remaining 收斂到 2m 以內" .. tag .. "（實得 " .. show(prevRem) .. "）")
    end
end

-- =====================================================================
-- 情境七：末端 — 降速、reached 的兩個條件（沿線＋歐氏）、越過終點不出負數
-- =====================================================================
scenario("末端：接近終點降速、reached 同時要求沿線剩餘與離終點直線距離、越過終點夾在 0")
do
    local st = F.newState()
    local function driveTo(sPos, spd)
        local cx, cy, ch = pointAt(pLine, sPos)
        return F.control(pLine, st, cx, cy, ch, spd or 0, DT)
    end

    driveTo(100, 40)
    local _, tsFar, remFar = driveTo(160, 40)
    checkNear(remFar, 40, 1e-9, "剩 40m")
    -- sqrt(2·6·40)=78.9 km/h > 沙盒 60：被上限 clamp——遠端不再受制動曲線壓制
    checkNear(tsFar, 60, 1e-9, "剩 40m 的目標速度＝上限 60（BRAKE=6 的制動曲線不再壓到這）")
    local _, tsNear, remNear = driveTo(194, 40)
    checkNear(remNear, 6, 1e-9, "剩 6m")
    checkNear(tsNear, math.sqrt(2 * 6 * 6) * KMH, 1e-9,
        "剩 6m：段內制動包絡 sqrt(2·BRAKE·rem)（BRAKE=6）")
    checkTrue(tsNear < tsFar, "越接近終點目標速度越低（末端制動）")

    local _, _, remHit, reachedHit = driveTo(195, 40)
    checkNear(remHit, 5, 1e-9, "剩正好 5m")
    checkTrue(reachedHit, "沿線剩 5m 且車就在終點 5m 內：回報 reached")
    checkEq(F.ARRIVE_M, 5, "ARRIVE_M 常數（沿線剩餘距離與終點直線距離共用同一個半徑）")

    local _, tsAt, remAt, reachedAt = driveTo(200, 10)
    checkNear(remAt, 0, 1e-9, "走到終點 remaining=0")
    checkTrue(reachedAt, "終點回報 reached")
    checkNear(tsAt, 0, 1e-9, "終點目標速度 0")

    -- 越過終點 60m：投影點釘在終點讓 remaining 歸零，但車根本不在終點——只看
    -- remaining 的呼叫端會在 60m 外煞停並宣告到站
    local _, tsOver, remOver, reachedOver = F.control(pLine, st, 260, 0, 0, 10, DT)
    checkNear(remOver, 0, 1e-9, "越過終點 remaining 夾在 0（不出負數）")
    checkFalse(reachedOver, "越過終點 60m：remaining=0 也不算抵達（車不在終點附近）")
    -- 制動剖面在終點是 0 m/s。若原樣送出去，車就停在 60m 外等一個永遠不會成立的
    -- reached；末段脫困地板把它抬到爬行速度，車才有動力調頭開回終點
    checkNear(tsOver, 12, 1e-9, "越過終點但未抵達：目標速度抬到爬行 12 km/h（不是 0）")

    -- 小幅越過但還在判定半徑內：這才是真的到了
    local _, _, remNudge, reachedNudge = F.control(pLine, st, 203, 1, 0, 10, DT)
    checkNear(remNudge, 0, 1e-9, "小幅越過終點 remaining 仍是 0")
    checkTrue(reachedNudge, "越過終點 3.2m（在 ARRIVE_M 半徑內）：算抵達")

    -- 段內物理包絡回歸（2026-08-28 實機）：163 號公路長直路的 nav 末段是一條
    -- ~233m 的單一線段（路網節點在路口），舊的段內「線性插值」把整段畫成
    -- v[n-1]→0 的長斜坡——車在 233m 外就以 target≈0.087×remaining 龜速爬完全程
    -- （遙測 target 20.1→4.3 與 remaining 嚴格成正比）。包絡修正後：長段內
    -- 距終點 50m 照制動曲線 sqrt(2·BRAKE·50)，距段頭照加速曲線，中段夾 maxSpeed。
    do
        local pLong = buildRoute({ 0, 0, 233, 0 }, 120)
        local stLong = F.newState()
        local _, tsMid, remMid = F.control(pLong, stLong, 116.5, 0, 0, 60, DT)
        checkNear(remMid, 116.5, 1e-9, "長段中點：remaining=116.5")
        checkTrue(tsMid > 60, "長段中點距終點 116m：巡航不減速（實得 " .. show(tsMid) .. "）")
        local _, ts50 = F.control(pLong, stLong, 183, 0, 0, 60, DT)
        checkNear(ts50, math.sqrt(2 * 6 * 50) * KMH, 1e-9,
            "長段內距終點 50m：制動包絡 sqrt(2·BRAKE·50)＝88.2，不是線性攤薄的 4.3")
        local _, tsEnd = F.control(pLong, stLong, 231, 0, 0, 20, DT)
        checkNear(tsEnd, math.sqrt(2 * 6 * 2) * KMH, 1e-9,
            "長段內距終點 2m：sqrt(2·BRAKE·2)＝17.6（終點收斂不受包絡影響）")
    end

    -- 末段投影落在終點前 5m、但車橫向偏離 20m（被撞開／擦身而過）：沿線條件成立、
    -- 歐氏條件不成立。這是「假抵達」最貼近實機的形狀
    local _, tsSide, remSide, reachedSide = F.control(pLine, st, 195, 20, 0, 10, DT)
    checkNear(remSide, 5, 1e-9, "橫向偏 20m：沿線剩餘距離照樣回報 5m（診斷／控速仍要用）")
    checkFalse(reachedSide, "橫向偏離終點 20m：沿線 remaining<=5 也不算抵達")
    checkNear(tsSide, 12, 1e-9,
        "橫向偏 20m＝車頭不朝終點（誤差 ≈76°）：航向誤差減速壓到爬行（原制動剖面 13.9）")

    -- 距終點正好 ARRIVE_M（3-4-5 直角三角形）：兩個條件都是 <=，邊界算抵達
    local _, _, remEdge, reachedEdge = F.control(pLine, st, 197, 4, 0, 10, DT)
    checkNear(remEdge, 3, 1e-9, "沿線剩 3m")
    checkTrue(reachedEdge, "離終點正好 5m：邊界算抵達")

    -- 反例（M3 的實機卡死形狀）：投影點正好壓在終點、車橫向偏 20m。remaining=0 讓
    -- 制動剖面給 0 速，reached 又因歐氏條件不成立而永遠是 false——沒有地板的話
    -- 呼叫端每幀都設定速 0，車停在路邊不動，session 永遠結束不了
    local _, tsStuck, remStuck, reachedStuck = F.control(pLine, st, 200, 20, 0, 10, DT)
    checkNear(remStuck, 0, 1e-9, "正橫向偏離終點 20m：沿線 remaining 已經是 0")
    checkFalse(reachedStuck, "正橫向偏離終點 20m：不算抵達")
    checkNear(tsStuck, 12, 1e-9,
        "remaining=0 但未抵達：目標速度抬到爬行 12 km/h，車才收斂得回終點")

    -- 同一個位置收進判定半徑內：reached 成立，地板不得介入（抵達要的就是 0 速）
    local _, tsIn, remIn, reachedIn = F.control(pLine, st, 200, 2, 0, 10, DT)
    checkNear(remIn, 0, 1e-9, "收進半徑內 remaining 仍是 0")
    checkTrue(reachedIn, "離終點 2m：算抵達")
    checkNear(tsIn, 0, 1e-9, "抵達後目標速度維持 0（脫困地板只在未抵達時作用）")

    -- 前視點與車身重合時（終點）改用路段朝向；若退回 atan2(0,0) 會回假的「零誤差」
    local stTip = F.newState()
    stTip.idx = pLine.n - 1
    local _, _, _, _, errTip = F.control(pLine, stTip, 200, 0, math.pi / 6, 0, DT)
    checkNear(errTip, -math.pi / 6, 1e-12,
        "前視點壓在車身上：改用路段朝向算誤差（不是 atan2(0,0)=0 的假零誤差）")
end

-- =====================================================================
-- 情境八：PID — 限幅 ±5、飽和不累積積分、積分夾 ±0.5 可回落、微分低通
-- =====================================================================
scenario("PID：限幅 ±5、飽和 antiwindup、積分夾 ±0.5 可回落、微分先低通")
do
    checkEq(F.STEER_MAX, 5, "STEER_MAX 常數（呼叫端要用 steer/STEER_MAX 正規化）")

    -- 132° 誤差：P = 2.2 * 2.304 = 5.07 → 飽和，但還沒到 135° 的調頭門檻
    local hSat = -132 * math.pi / 180
    local stSat = F.newState()
    local satSteer, _, _, _, satErr = F.control(pLine, stSat, 100, 0, hSat, 0, DT)
    checkNear(satErr, -hSat, 1e-12, "車在路徑上時 headingError = -heading")
    checkFalse(stSat.rotating, "132° 未達 135° 進入門檻：不是調頭模式")
    checkEq(satSteer, F.STEER_MAX, "P 項超過限幅：steer 恰好夾在 +5")
    for _ = 1, 300 do F.control(pLine, stSat, 100, 0, hSat, 0, DT) end
    checkEq(stSat.iTerm, 0, "飽和且誤差同向：積分項一次都沒累積（條件積分 antiwindup）")
    checkEq((F.control(pLine, stSat, 100, 0, hSat, 0, DT)), F.STEER_MAX, "300 幀後仍夾在 +5")

    local stSatN = F.newState()
    checkEq((F.control(pLine, stSatN, 100, 0, -hSat, 0, DT)), -F.STEER_MAX, "反向大誤差夾在 -5")
    for _ = 1, 300 do F.control(pLine, stSatN, 100, 0, -hSat, 0, DT) end
    checkEq(stSatN.iTerm, 0, "反向飽和同樣不累積")

    -- 小而持續的誤差（0.2 rad）：積分項慢慢長大、停在 +0.5
    local stI = F.newState()
    local lastSteer
    for _ = 1, 3000 do
        lastSteer = F.control(pLine, stI, 100, 0, -0.2, 0, DT)
    end
    checkNear(stI.iTerm, 0.5, 1e-9, "持續誤差把積分項推到飽和值 +0.5（不會超過）")
    checkNear(lastSteer, 2.2 * 0.2 + 0.5, 1e-9, "穩態 steer = P + I（D 已衰減到 0）")
    checkTrue(lastSteer < F.STEER_MAX, "穩態沒有飽和（所以積分才有機會累積）")
    for _ = 1, 200 do F.control(pLine, stI, 100, 0, 0.2, 0, DT) end
    checkTrue(stI.iTerm < 0.5 - 1e-9, "誤差反向後積分項開始回落（不會黏在飽和值）")
    checkTrue(stI.iTerm >= -0.5, "回落不會衝破另一側飽和")

    -- 微分低通：誤差階躍時 D 吃的是 D_ALPHA * Δerr/dt，不是 raw Δerr/dt
    local stD = F.newState()
    F.control(pLine, stD, 100, 0, 0, 0, DT)             -- 先把 errPrev 建立成 0
    local stepSteer = F.control(pLine, stD, 100, 0, -0.1, 0, DT)
    local rawD = 0.35 * (0.1 / DT)
    checkNear(stepSteer, 2.2 * 0.1 + 0.15 * 0.1 * DT + 0.35 * 0.3 * (0.1 / DT), 1e-9,
        "階躍後 steer = P + I + KD*(D_ALPHA*Δerr/dt)")
    checkTrue(stepSteer < rawD, "D 有低通（沒有低通會是 " .. show(rawD) .. "）")
end

-- =====================================================================
-- 情境九：原地調頭 — 135° 進入／100° 離開的遲滯、飽和轉向、爬行速度、凍結 I/D
-- =====================================================================
scenario("原地調頭：135°/100° 遲滯、飽和轉向、爬行速度、期間凍結 I/D")
do
    -- 車在路徑上時 err = -heading，所以用「想要的誤差角度」反推 heading
    local function headOf(deg) return -deg * math.pi / 180 end

    local st = F.newState()
    local s130, ts130 = F.control(pLine, st, 100, 0, headOf(130), 0, DT)
    checkFalse(st.rotating, "130° < 135°：不進入調頭模式")
    checkNear(ts130, 12, 1e-9,
        "非調頭但誤差 130° 遠超 ERR_SLOW_END：航向誤差減速仍壓到爬行（不必等進調頭）")
    checkTrue(s130 > 4.9 and s130 <= F.STEER_MAX,
        "130° 的 P 項幾乎撐滿限幅，但走的是 PID 分支（實得 " .. show(s130) .. "）")

    local s170, ts170 = F.control(pLine, st, 100, 0, headOf(170), 0, DT)
    checkTrue(st.rotating, "170° > 135°：進入調頭模式")
    checkEq(s170, F.STEER_MAX, "調頭：飽和轉向")
    checkNear(ts170, 12, 1e-9, "調頭：速度壓到爬行 12 km/h")

    local _, ts120 = F.control(pLine, st, 100, 0, headOf(120), 0, DT)
    checkTrue(st.rotating, "120° 未低於 100° 離開門檻：維持調頭（遲滯）")
    checkNear(ts120, 12, 1e-9, "維持調頭：仍是爬行速度")

    local s95, ts95 = F.control(pLine, st, 100, 0, headOf(95), 0, DT)
    checkFalse(st.rotating, "95° < 100°：離開調頭模式")
    checkNear(ts95, 12, 1e-9,
        "離開調頭但誤差仍 95°：換航向誤差減速接手壓爬行——速度要回 profile 得等誤差收斂")
    checkTrue(s95 > 0 and s95 < F.STEER_MAX, "離開調頭後由 PID 接手（未飽和、方向仍正確）")

    checkEq((F.control(pLine, st, 100, 0, headOf(140), 0, DT)), F.STEER_MAX,
        "140° 再次跨過進入門檻：又是飽和轉向")
    checkTrue(st.rotating, "重新進入調頭模式")

    local stN = F.newState()
    checkEq((F.control(pLine, stN, 100, 0, headOf(-170), 0, DT)), -F.STEER_MAX,
        "反向 170°：轉向 -5")
    checkTrue(stN.rotating, "反向 170° 同樣進入調頭")

    local st180 = F.newState()
    local s180 = F.control(pLine, st180, 100, 0, math.pi, 0, DT)
    checkTrue(st180.rotating, "正好 180°：進入調頭")
    checkEq(math.abs(s180), F.STEER_MAX, "180° 仍給飽和轉向（不會在 0 附近抖）")

    local stFreeze = F.newState()
    for _ = 1, 500 do F.control(pLine, stFreeze, 100, 0, headOf(170), 0, DT) end
    checkEq(stFreeze.iTerm, 0, "調頭期間不累積積分項")
    checkEq(stFreeze.dFilt, 0, "調頭期間不更新微分項")
    checkNear(stFreeze.errPrev, 170 * math.pi / 180, 1e-12,
        "調頭期間仍更新誤差歷史（離開調頭時 D 才不會吃到過期的 errPrev）")
end

-- =====================================================================
-- 情境（新）：航向誤差減速 — 誤差大就收油，斷開「誤差越大車越快」的正反饋
-- =====================================================================
scenario("航向誤差減速：10° 內不收油、30° 半收、50° 起壓到爬行、制動段只壓不抬")
do
    -- 車在 pLine 的 (50, 0) 恰好壓線：前視點正東，err = -heading（同情境九慣例）。
    -- 直線中段的剖面速度＝MAXV（60），收油與否全由誤差決定，參考值乾淨。
    local st = F.newState()
    local function tgtAt(errDeg, spd)
        F.resetState(st)
        local _, tgt = F.control(pLine, st, 50, 0, -errDeg * math.pi / 180, spd or 30, DT)
        return tgt
    end
    checkNear(tgtAt(0), 60, 1e-9, "誤差 0°：直線目標速不變")
    checkNear(tgtAt(5), 60, 1e-9, "誤差 5°（< START 10°）：不收油")
    checkNear(tgtAt(-5), 60, 1e-9, "誤差 -5°：對稱不收油")
    checkNear(tgtAt(30), 12 + (60 - 12) * 0.5, 1e-6, "誤差 30°：t=0.5，油門收一半")
    checkNear(tgtAt(-30), 12 + (60 - 12) * 0.5, 1e-6, "誤差 -30°：左右對稱")
    checkNear(tgtAt(50), 12, 1e-6, "誤差 50°（＝END）：壓到爬行速度（與調頭同一檔）")
    checkNear(tgtAt(70), 12, 1e-6, "誤差 70°：t 夾在 0，仍是爬行速度、不會更低")

    -- 制動段（終點前 8m，剖面原值 ≈22 km/h > 爬行）大誤差：壓到爬行、不因 t=0 而歸零；
    -- cap = 爬行 + (target - 爬行) * t 在 target ≤ 爬行時恆 ≥ target，數學上只壓不抬，
    -- 低於爬行的終點制動速度不會被這條規則抬回去（脫困地板是另一條、有自己的窗口）。
    F.resetState(st)
    st.idx = 19
    local _, tgtBrake, remBrake = F.control(pLine, st, 192, 0, -70 * math.pi / 180, 10, DT)
    checkTrue(remBrake > F.ARRIVE_M, "取樣點在抵達窗之外（排除脫困地板干擾）")
    checkNear(tgtBrake, 12, 1e-6, "制動段誤差 70°：壓到爬行而非更低")
end

-- =====================================================================
-- 情境（新）：側偏疊加 — setOffset 只動前視點，進度語意不變
-- =====================================================================
scenario("側偏疊加：參數驗證、三段剖面插值、只動前視點不動 remaining、清除即歸零")
do
    -- setOffset 參數驗證：非法一律 false 且不動 state
    local st = F.newState()
    checkFalse(F.setOffset(nil, 1, 2, 3, 4, 2), "state 非 table：拒絕")
    checkFalse(F.setOffset(st, 2, 2, 3, 4, 2), "a==b：拒絕（進入段長 0 會除零）")
    checkFalse(F.setOffset(st, 1, 2, 3, 3, 2), "c==d：拒絕（回歸段長 0 會除零）")
    checkFalse(F.setOffset(st, 1, 3, 2, 4, 2), "b>c：拒絕")
    checkFalse(F.setOffset(st, 0 / 0, 2, 3, 4, 2), "NaN 斷點：拒絕")
    checkEq(st.offL, nil, "全部拒絕後 state 未被污染（無剖面＝offL 為 nil）")
    checkTrue(F.setOffset(st, 1, 2, 3, 4, 0), "l==0（借中心線）：合法剖面")
    checkTrue(F.setOffset(st, 1, 2, 3, 4, 2), "合法剖面：接受")
    checkTrue(F.setOffset(st, 1, 2, 2, 4, 2), "b==c（保持段長 0）：接受")

    -- 幾何：車在 pLine (50,0) 壓線、heading=0、speed=30 → look=9.6、前視點弧長 59.6。
    -- 測試自算參考值：err = atan2(偏移量, 9.6)。
    local look = 9.6
    local function errWith(a, b, c, d, l)
        local st2 = F.newState()
        if a then
            if not F.setOffset(st2, a, b, c, d, l) then error("setOffset 意外失敗") end
        end
        local _, _, rem, _, err = F.control(pLine, st2, 50, 0, 0, 30, DT)
        return err, rem
    end
    local errBase, remBase = errWith(nil)
    checkNear(errBase, 0, 1e-12, "無側偏：壓線零誤差")

    local errHold, remHold = errWith(50, 58, 70, 78, 2)
    checkNear(errHold, math.atan2 and math.atan2(2, look) or math.atan(2 / look), 1e-9,
        "保持段（t=1）：前視點左偏滿 2m，誤差＝atan2(2, 前視距)")
    checkTrue(errHold > 0, "左偏（l>0）→ 誤差為正（要求左轉）")
    checkNear(remHold, remBase, 1e-9, "側偏不改 remaining（進度仍以中心線為準）")

    local tRaw = (59.6 - 55) / 10
    local tSm = tRaw * tRaw * (3 - 2 * tRaw)
    local errEntry = errWith(55, 65, 70, 80, 2)
    checkNear(errEntry, math.atan2 and math.atan2(2 * tSm, look) or math.atan(2 * tSm / look), 1e-9,
        "進入段：smoothstep 插值（t=0.46 → 偏移 " .. string.format("%.3f", 2 * tSm) .. "m）")
    checkTrue(errEntry > 0 and errEntry < errHold, "進入段偏移小於峰值")

    local errMirror = errWith(50, 58, 70, 78, -2)
    checkNear(errMirror, -errHold, 1e-12, "右偏（l<0）：誤差鏡像反號")

    local errOutside = errWith(70, 75, 80, 85, 2)
    checkNear(errOutside, 0, 1e-12, "前視點在剖面範圍外：不偏")

    -- 借中線（codex 對抗審 BLOCKING 回歸）：常駐右偏 bias=2 時，offL=0 的剖面
    -- 必須把前視點壓回中心線——0 若被當 inactive 哨兵，車只會停不會繞。
    local stZero = F.newState()
    F.setLaneBias(stZero, 2)
    local _, _, _, _, errBias = F.control(pLine, stZero, 50, 0, 0, 30, DT)
    checkNear(errBias, math.atan2 and math.atan2(2, look) or math.atan(2 / look), 1e-9,
        "bias=2 基準：前視點偏離中心線 2m")
    checkTrue(F.setOffset(stZero, 50, 58, 70, 78, 0), "offL=0 剖面：接受")
    local _, _, _, _, errZero = F.control(pLine, stZero, 50, 0, 0, 30, DT)
    checkNear(errZero, 0, 1e-9, "保持段：bias 被壓回中心線（offL=0 生效、非 inactive）")

    local st3 = F.newState()
    checkTrue(F.setOffset(st3, 50, 58, 70, 78, 2), "先掛上側偏")
    F.clearOffset(st3)
    local _, _, _, _, errCleared = F.control(pLine, st3, 50, 0, 0, 30, DT)
    checkNear(errCleared, 0, 1e-12, "clearOffset 後回到壓線零誤差")
    checkEq(st3.offL, nil, "clearOffset 後 offL 為 nil（數值哨兵退場）")

    local stReset = F.newState()
    checkTrue(F.setOffset(stReset, 50, 58, 70, 78, 2), "resetState 前掛上側偏")
    F.resetState(stReset)
    checkEq(stReset.offL, nil, "resetState 一併清側偏（換路線不得帶舊剖面）")
end

-- =====================================================================
-- 情境（新）：車道偏置 — 常駐靠右、與繞行剖面混合、reset 不清
-- =====================================================================
-- 符號慣例：l 的數學正向（CCW 法向）在 PZ 世界（Y 向南）是行進方向的**右側**，
-- 所以「靠右行駛」＝正 bias（driver 傳沙盒正值）。2026-08-28 曾因把數學正向
-- 標成「左」而給負號，實機整路靠左開。
scenario("車道偏置：常駐靠右（數學正）、繞行段從偏置過渡到絕對車道再回來、reset 保留設定")
do
    local look = 9.6 -- speed 30 → 6 + 30*0.12
    local st = F.newState()
    checkTrue(F.setLaneBias(st, 1.5), "設定靠右 1.5（數學正＝PZ 實際右側，driver 同款用法）")
    local _, _, remB, _, errB = F.control(pLine, st, 50, 0, 0, 30, DT)
    checkNear(errB, math.atan2 and math.atan2(1.5, look) or math.atan(1.5 / look), 1e-9,
        "常駐偏置：壓線車看到的前視點在數學正側 1.5m（誤差為正）")
    checkNear(remB, 150, 1e-9, "偏置不改 remaining（進度仍以中心線為準）")

    -- 繞行剖面作用時：保持段的橫向位置＝offL（絕對車道），不是 bias + offL
    checkTrue(F.setOffset(st, 50, 58, 70, 78, -2), "掛上繞行剖面（offL=-2，反側）")
    local _, _, _, _, errMix = F.control(pLine, st, 50, 0, 0, 30, DT)
    checkNear(errMix, math.atan2 and math.atan2(-2, look) or math.atan(-2 / look), 1e-9,
        "保持段（t=1）：lane ＝ offL 絕對值 -2（Corridor 已以中心線為基準算好，不疊 bias）")

    -- 剖面範圍外：回到常駐偏置
    F.clearOffset(st)
    local _, _, _, _, errBack = F.control(pLine, st, 50, 0, 0, 30, DT)
    checkNear(errBack, math.atan2 and math.atan2(1.5, look) or math.atan(1.5 / look), 1e-9,
        "clearOffset 後回到右車道（不是回中心線）")

    -- reset 語意：bias 是「設定」不是「狀態」——resetState / resetControl 都保留
    F.resetState(st)
    checkNear(st.laneBias, 1.5, 1e-12, "resetState 保留車道偏置（換路線照樣靠右）")
    F.resetControl(st)
    checkNear(st.laneBias, 1.5, 1e-12, "resetControl 保留車道偏置（脫困後照樣靠右）")

    -- 防呆：非有限值當 0（關閉）
    checkTrue(F.setLaneBias(st, 0 / 0), "NaN 偏置：接受但視為 0")
    local _, _, _, _, errOff = F.control(pLine, st, 50, 0, 0, 30, DT)
    checkNear(errOff, 0, 1e-12, "NaN 偏置＝關閉：回壓線零誤差")
    checkFalse(F.setLaneBias(nil, 1), "state 非 table：拒絕")
end

-- =====================================================================
-- 情境十：閉環 — 從偏離狀態出發能收斂並開到終點（簡化自行車模型）
-- =====================================================================
scenario("閉環模擬：偏離 6m 出發能收斂並抵達終點、車頭反向能靠調頭救回")
do
    -- 車輛模型：轉向對應**曲率**（yaw 速率 ＝ v * kappa），這是真車的行為——
    -- 同一個方向盤角度在任何速度下畫出同一個半徑。
    -- 刻意**不用**「yaw 速率 ∝ 轉向」的更簡模型：那等於「高速時半徑變大」，
    -- 會讓任何前視型控制器在高速彎道系統性地切內線，量出來的偏差是模型假象
    -- 而不是控制律的問題（實測差距：同一條 S 彎，假模型 7.0m、自行車模型 2.8m）。
    local KAPPA_MAX = 1 / 6   -- 轉向飽和時的曲率＝最小轉彎半徑 6m（一般小客車量級）

    -- 回 (是否抵達, 幀數, 熱機後最大橫向偏差, 是否用過調頭模式)
    local function simulate(x0, y0, h0, warmup)
        local st = F.newState()
        local x, y, h, spd = x0, y0, h0, 0
        local dev, steps, arrived, rotated = 0, 0, false, false
        while steps < 20000 and not arrived do
            local steer, tspd, _, reached = F.control(pSine, st, x, y, h, spd, DT)
            if st.rotating then rotated = true end
            if reached then
                arrived = true
            else
                spd = tspd
                local ms = spd / KMH
                h = h + ms * (steer / F.STEER_MAX) * KAPPA_MAX * DT
                x = x + math.cos(h) * ms * DT
                y = y + math.sin(h) * ms * DT
                steps = steps + 1
                if steps > warmup then
                    local d = distToPath(pSine, x, y)
                    if d > dev then dev = d end
                end
            end
        end
        return arrived, steps, dev, rotated
    end

    local arrived, steps, dev = simulate(0, 6, 0, 90)
    checkTrue(arrived, "從偏離 6m 出發能開到終點（用了 " .. steps .. " 幀）")
    checkTrue(steps > 60, "不是一開始就誤判抵達")
    -- 這條 S 彎振幅 8m、波長約 105m，比真實路網彎得多；前視 12～18m 必然切一點內線，
    -- 穩態偏差約 2.9m。門檻放 4.5m＝「有餘裕但抓得到發散」
    checkTrue(dev < 4.5, "收斂後橫向偏差有界（實得 " .. show(dev) .. "m）")

    -- 車頭朝西、偏北：必須先靠調頭模式把車頭甩回來
    local revArrived, revSteps, _, revRotated = simulate(20, 4, math.pi, 1e9)
    checkTrue(revRotated, "車頭完全反向時真的進入過調頭模式")
    checkTrue(revArrived, "調頭後仍能開到終點（用了 " .. revSteps .. " 幀）")
end

-- =====================================================================
-- 情境十一：熱路徑守則 — control 不改 profile、不配置 table
-- =====================================================================
scenario("熱路徑守則：control 全程不改動 profile、每幀零 table 配置")
do
    local function checksum(p)
        local acc = p.length * 1.000001 + p.n + p.maxSpeedMs * 3
        for i = 1, p.n do
            acc = acc + p.x[i] * 3 + p.y[i] * 5 + p.s[i] * 7 + p.v[i] * 11
        end
        for i = 1, p.n - 1 do
            acc = acc + p.segLen[i] * 13 + p.segH[i] * 17
        end
        return acc
    end

    local before = checksum(pSine)
    local stRO = F.newState()
    for k = 1, 2000 do
        F.control(pSine, stRO, k % 200, (k % 17) - 8, (k % 31) * 0.2 - 3, (k % 90) - 20, DT)
    end
    checkEq(checksum(pSine), before, "control 跑 2000 幀完全不改動 profile（唯讀）")
    checkEq(pSine.phase, "ready", "phase 沒被動到")
    checkEq(pSine.cursor, pSine.n, "cursor 沒被動到")
    checkEq(pSine.ready, true, "ready 沒被動到")

    -- 零配置：關掉 GC 讓堆增量純粹反映配置量。
    -- 每幀若建一個 table（Lua 5.4 空表約 56 bytes），2 萬幀會多出 1MB 以上。
    local stGC = F.newState()
    local acc = 0
    collectgarbage("collect")
    collectgarbage("stop")
    local kb0 = collectgarbage("count")
    for k = 1, 20000 do
        local sv = F.control(pSine, stGC, k % 200, (k % 13) - 6, (k % 29) * 0.21 - 3,
            (k % 70) - 10, DT)
        acc = acc + sv
    end
    local kb1 = collectgarbage("count")
    collectgarbage("restart")
    checkTrue(acc == acc, "累加值是有限數（迴圈真的跑完了）")
    checkTrue(kb1 - kb0 < 16, "20000 次 control 的堆增量 < 16KB（實得 "
        .. string.format("%.1f", kb1 - kb0) .. "KB；每幀建一個 table 會是 1MB 以上）")
end

-- =====================================================================
-- 情境十二：輔助函式 — headingFromForward 慣例、resetState 就地重設
-- =====================================================================
scenario("輔助函式：headingFromForward 與 control 共用同一份慣例、resetState 就地重設")
do
    checkNear(F.headingFromForward(1, 0), 0, 1e-12, "前向 +x → heading 0")
    checkNear(F.headingFromForward(0, 1), math.pi / 2, 1e-12, "前向 +y → heading +90°")
    checkNear(F.headingFromForward(-1, 0), math.pi, 1e-12, "前向 -x → heading 180°")
    checkNear(F.headingFromForward(0, -1), -math.pi / 2, 1e-12, "前向 -y → heading -90°")
    checkEq(F.headingFromForward(0, 0), 0, "零向量回 0（不呼叫 atan2(0,0)）")
    checkEq(F.headingFromForward(0 / 0, 1), 0, "非有限輸入回 0")
    checkEq(F.headingFromForward("1", 1), 0, "非數字輸入回 0")

    local stConv = F.newState()
    local _, _, _, _, errConv =
        F.control(pLine, stConv, 100, 0, F.headingFromForward(1, 0), 0, DT)
    checkNear(errConv, 0, 1e-12, "headingFromForward 的輸出餵進 control：直線上誤差 0")

    local reused = F.newState()
    F.control(pLine, reused, 100, -3, 0.4, 40, DT)
    checkEq(F.resetState(reused), reused, "resetState 回同一顆 table（就地重設、不配置）")
    checkEq(reused.idx, 1, "idx 歸零")
    checkEq(reused.iTerm, 0, "積分項歸零")
    checkEq(reused.dFilt, 0, "微分項歸零")
    checkNil(reused.errPrev, "誤差歷史清空（重設後第一幀不吃 (err-0)/dt 的假微分尖刺）")
    checkFalse(reused.rotating, "調頭旗標歸零")
    checkNil(F.resetState(nil), "resetState(nil) 不炸")

    -- 模組表面：該有的都在，且沒有任何 PZ 相依
    checkEq(type(F.begin), "function", "begin 存在")
    checkEq(type(F.stepBuild), "function", "stepBuild 存在")
    checkEq(type(F.control), "function", "control 存在")
    checkEq(type(F.newState), "function", "newState 存在")
    checkEq(type(F.resetState), "function", "resetState 存在")
    checkEq(type(F.headingFromForward), "function", "headingFromForward 存在")
    checkEq(F.MIN_SPEED_KMH, 12, "MIN_SPEED_KMH 常數")
end

-- =====================================================================
-- M6 世界 offset 折線：折點連續性（codex 架構裁決的驗收條件）
-- =====================================================================
scenario("buildOffsetLine：折點法向混合＝相鄰點無跳變；直路與舊求值等價")
do
    -- 90° L 折點路線：直行 40m 後右轉 40m（相鄰點距 4m）
    local pts = {}
    for i = 0, 10 do pts[#pts + 1] = i * 4; pts[#pts + 1] = 0 end
    for i = 1, 10 do pts[#pts + 1] = 40; pts[#pts + 1] = i * 4 end
    local pL = buildRoute(pts)
    local ox, oy = {}, {}
    -- 剖面跨折點（折點 s=40）：a=30 b=36 c=44 d=50、offL=4.25——舊「逐段
    -- 法向」在折點的 offset 點跳 2·4.25·sin(45°)≈6m；混合後任兩相鄰取樣點
    -- （1m 步）距離必須 < 2m（連續）
    local n, s0 = F.buildOffsetLine(pL, 25, 30, 36, 44, 50, 4.25, 0, ox, oy)
    checkTrue(n >= 20, "折線點數合理（實得 " .. tostring(n) .. "）")
    checkEq(s0, 25, "s0＝呼叫端指定的掃掠起點")
    local maxStep = 0
    for k = 2, n do
        local dx = ox[k] - ox[k - 1]
        local dy = oy[k] - oy[k - 1]
        local dd = math.sqrt(dx * dx + dy * dy)
        if dd > maxStep then maxStep = dd end
    end
    checkTrue(maxStep < 2.0,
        "折點處相鄰取樣點無跳變（最大步距 " .. string.format("%.2f", maxStep) .. " < 2）")
    -- 直路等價：無折點時折線點＝路線點＋法向×lane（與舊求值一致）
    local pS = buildRoute({ 0, 0, 40, 0, 80, 0 })
    local n2 = F.buildOffsetLine(pS, 5, 10, 16, 24, 30, -1.75, 0.3, ox, oy)
    local okEq = true
    for k = 1, n2 do
        local sk = 5 + (k - 1)
        local lane = 0.3
        if sk > 10 and sk < 30 then
            local t
            if sk < 16 then t = (sk - 10) / 6
            elseif sk > 24 then t = (30 - sk) / 6
            else t = 1 end
            t = t * t * (3 - 2 * t)
            lane = 0.3 + (-1.75 - 0.3) * t
        end
        -- 直路 heading 0：offset 點 = (sk, lane)（n̂=(0,1)、y=+lane…慣例
        -- x - sin(0)*lane = sk、y + cos(0)*lane = lane）
        local ex, ey = sk, lane
        if math.abs(ox[k] - ex) > 0.01 or math.abs(oy[k] - ey) > 0.01 then okEq = false end
    end
    checkTrue(okEq, "直路折線＝舊逐段法向求值（向後等價）")
    -- 引數防呆
    local n3 = F.buildOffsetLine(nil, 0, 1, 2, 3, 4, 1, 0, ox, oy)
    checkEq(n3, 0, "無 profile 回 0")
end

-- =====================================================================
-- 總結
-- =====================================================================
closeScenario()
print()
print("情境 " .. scenarios .. " 個、斷言 " .. assertions .. " 項")
if failures > 0 then
    print(failures .. " 項失敗")
    os.exit(1)
end
print("全部通過")
