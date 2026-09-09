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

loadProduction("shared/MDAD_Dynamics.lua")
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

local function exactOffset(state, a, b, c, d, l)
    local ox, oy = {}, {}
    local n, s0, reason, s1 = F.buildOffsetLine(
        pLine, 0, a, b, c, d, l, 0, ox, oy)
    if reason ~= "ok" then return false end
    return F.setOffset(state, a, b, c, d, l, ox, oy, n, s0, s1)
end

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
    -- Geometry/speed passes cost 5n-3; range tree costs 2*pow2ceil(n-1)-1.
    local p200, calls200 = buildRoute(straight(200, 10), MAXV, 8)
    checkTrue(p200.ready and p200.rangeReady, "增量建表與 range minima 最終 ready")
    checkEq(calls200, 126, "budget=8：1005 個 bounded build ops 需要 126 次呼叫")
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
    checkEq(table.concat(seen, ">"),
        "geometry>coast>brake>merge>accel>ready",
        "相位單向推進；空 block-tree transitions 不另耗 call")
    checkEq(oneByOne, 23, "budget=1、5 點：22 個 build ops＋1 次收尾")

    -- BUDGET_MAX still bounds each call with speed passes and the range tree.
    local pBig = F.begin(mkRoute(straight(5000, 2)), MAXV)
    checkEq(F.BUDGET_MAX, 4096, "BUDGET_MAX 常數")
    checkFalse(F.stepBuild(pBig, 1e9), "budget 給 10 億：仍被 BUDGET_MAX 夾住，一次做不完")
    checkEq(pBig.cursor, 4096 + 1, "第一次呼叫恰好做了 4096 個點運算")
    checkEq(pBig.phase, "geometry", "第一次呼叫還停在 geometry 相位")
    local bigCalls = 1
    while not pBig.ready and bigCalls < 100 do
        F.stepBuild(pBig, 1e9)
        bigCalls = bigCalls + 1
    end
    checkTrue(pBig.ready, "續呼叫可以做完")
    checkEq(bigCalls, 7, "speed passes＋354 block-tree ops remain within 7 bounded calls")

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
    -- 反向制動：v[i] = sqrt(v[i+1]^2 + 2*BRAKE*L)，BRAKE=8（2026-09-01 調實：
    -- 舊值 6 是「實煞六成留雨天」，與 priors 的 fSurface×fTire 天氣折疊成
    -- 雙重保守；雨天折現在只在 priors 折一次）
    checkNear(pLine.v[20], math.sqrt(2 * 8 * 10), 1e-9, "終點前一點＝sqrt(2*8*10)")
    -- v[19]＝min(sqrt(2·8·20)=17.89, maxV 16.67)：BRAKE=8 的制動段更短、
    -- 此點已被上限 clamp
    checkNear(pLine.v[19], MAXV / KMH, 1e-9, "制動段第二點已回到上限（BRAKE=8 制動段較短）")
    checkNear(pLine.v[18], MAXV / KMH, 1e-9, "制動段第三點維持上限")
    checkTrue(pLine.v[20] * KMH < MAXV, "第 20 點在制動段內")
    local over = 0
    for i = 1, pLine.n do
        if pLine.v[i] * KMH > MAXV + 1e-9 then over = over + 1 end
    end
    checkEq(over, 0, "沒有任何一點超過 maxSpeed")
    checkTrue(maxDecelDemand(pLine) <= 8 + 1e-6, "直線：沒有路段的減速需求超過 BRAKE=8 m/s²")

    -- 8m 段的直角彎：三點 circumcircle kappa=2|cross|/(|AB||BC||AC|)。
    local pCorner = buildRoute({ 0, 0, 8, 0, 16, 0, 24, 0, 24, 8, 24, 16, 24, 24 }, MAXV)
    local k90 = 2 * 64 / (8 * 8 * math.sqrt(8 * 8 + 8 * 8))
    local expect90 = math.sqrt(9.0 / k90) -- LAT_ACCEL 9.0（2026-09-02 二次激進化）
    checkNear(pCorner.v[4], expect90, 1e-9, "直角彎頂點速度＝sqrt(a_lat/kappa_circumcircle)")
    checkTrue(pCorner.v[4] * KMH > F.MIN_SPEED_KMH, "直角彎沒有撞到 12 km/h 下限（約 18.6）")
    checkTrue(pCorner.v[4] * KMH < MAXV * 0.5, "直角彎確實遠慢於 maxSpeed")
    checkTrue(pCorner.v[3] > pCorner.v[4], "彎前一點比彎頂快（反向制動生效）")
    checkNear(pCorner.v[3],
        math.sqrt(pCorner.v[4] * pCorner.v[4] + 2 * F.STYLES.brisk.coast * 8), 1e-9,
        "彎前使用 coast envelope（brisk coast " .. F.STYLES.brisk.coast .. "），不動用 active brake")
    checkNear(F.STYLES.brisk.coast, 3.0, 1e-12,
        "brisk coast 天花板 3.0（0907e：真值由 VehicleProfile 質量制動預算取 min）")
    -- 彎後不再有前向加速包絡（2026-09-01 拆除 forward pass）：v[5] 直接由
    -- 「距終點 16m 的制動包絡」決定，出彎即可全力——加速能力交還引擎。
    checkNear(pCorner.v[5], math.sqrt(2 * 8 * 16), 1e-9,
        "彎後一點＝終點制動包絡 sqrt(2*BRAKE*16)，不再被 ACCEL 壓住")
    checkTrue(pCorner.v[5] > math.sqrt(pCorner.v[4] * pCorner.v[4] + 2 * 2.5 * 8) + 1e-9,
        "彎後速度高於舊 ACCEL=2.5 包絡（前向天花板確實拆除；植入違規驗證）")
    checkTrue(maxDecelDemand(pCorner) <= 8 + 1e-6,
        "直角彎路線：反向制動的可行性不受拆除影響")

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
    checkEq(pDup.n, #dupPts / 2 - 1, "連續重合點在 owned profile canonicalize")
    checkNear(pDup.segLen[2], 10, 1e-12, "canonical profile 不保留零長 segment")
    checkNear(pDup.segH[1], math.pi / 2, 1e-12, "北向段朝向＝90°")
    checkNear(pDup.v[2] * KMH, MAXV, 1e-9, "重合點沒有被偽造的急彎拖慢")
    checkNear(pDup.v[3] * KMH, MAXV, 1e-9, "canonical 下一點同樣不受影響")

    -- 兩點路線（最短的合法路線）
    local pTwo = buildRoute({ 0, 0, 30, 0 }, MAXV)
    checkNear(pTwo.length, 30, 1e-9, "兩點路線的長度")
    checkNear(pTwo.v[2], 0, 1e-12, "兩點路線的終點也要停")
    -- sqrt(2·8·30)=21.9 m/s > maxV 16.67：起點被上限 clamp
    checkNear(pTwo.v[1], MAXV / KMH, 1e-9, "兩點路線的起點速度由制動距離／上限共同決定（BRAKE=8 下被上限 clamp）")

    -- 折點角度限速下限：路網 polyline 在交叉口的點距常常很大（20-30m），
    -- kappa=Δθ/ds 被長段稀釋，曲率公式對急彎算出高速「限速」——2026-08-28 實機
    -- 61.5 km/h 過路口直接甩出路面。角度本身另設上限，點距再大也稀釋不掉。
    local pWide90 = buildRoute({ 0, 0, 30, 0, 60, 0, 60, 30, 60, 60 }, MAXV)
    -- 0907f 折點幾何限速（F350 fallback 頂點 50 km/h 撞路口牆定罪）：無圓角頂點由 pure pursuit
    -- 以前視弦切過，R(v)=(6+0.432v)/(2 sin(θ/2))，v²=aLat·R(v) 正根；rMin（v3 路線預設 3.0）圓為下限。
    -- 舊契約「曲率裁決 49.7／角度上限 50」是圓角之前的角度式常數，90° 折點 50 km/h 沒有車做得到。
    local function vertexGeomMs(aLat, deg, rMin)
        local inv2s = 1 / (2 * math.sin(math.rad(deg) * 0.5))
        local b = aLat * 0.12 * 3.6 * inv2s
        local c = aLat * 6 * inv2s
        local v = (b + math.sqrt(b * b + 4 * c)) * 0.5
        local rm = math.sqrt(aLat * (rMin or 3.0))
        return v > rm and v or rm
    end
    checkNear(pWide90.v[3], vertexGeomMs(9.0, 90), 1e-9,
        "大點距 90° 折點：LAT 9 前視弦幾何 ≈27.7 km/h（角度上限 50／曲率稀釋值都不再作數）")
    checkTrue(pWide90.v[3] * KMH < 30, "90° 折點不再放行 49.7")
    -- 25° 折點：SOFT 門檻恰為 25°——角度式不壓；幾何式 R(v)=30.5m 在 LAT 9 下 59.5 ≈ 全速（60）
    local a25 = 25 * math.pi / 180
    local x3, y3 = 60 + 30 * math.cos(a25), 30 * math.sin(a25)
    local x4, y4 = x3 + 30 * math.cos(a25), y3 + 30 * math.sin(a25)
    local p25 = buildRoute({ 0, 0, 30, 0, 60, 0, x3, y3, x4, y4 }, MAXV)
    checkNear(p25.v[3], vertexGeomMs(9.0, 25), 1e-9,
        "25° 折點＝幾何式 59.5（比全速 60 只低 0.5，SOFT 角度門檻不壓）")
    checkTrue(p25.v[3] * KMH > 59, "25° 折點接近全速")
    -- 小折角（< 20°）不受角度 hard cap；仍使用三點 circumcircle 曲率。
    -- 路線尾巴多留 32m，避免終點反向制動鏈蓋過曲率值。
    local a10 = 10 * math.pi / 180
    local q3, q4 = 16 + 8 * math.cos(a10), 8 * math.sin(a10)
    local c10, s10 = math.cos(a10), math.sin(a10)
    local p10 = buildRoute({ 0, 0, 8, 0, 16, 0, q3, q4,
        q3 + 8 * c10, q4 + 8 * s10, q3 + 16 * c10, q4 + 16 * s10,
        q3 + 24 * c10, q4 + 24 * s10, q3 + 32 * c10, q4 + 32 * s10 }, MAXV)
    local chord10 = math.sqrt((q3 - 8) * (q3 - 8) + q4 * q4)
    local k10 = 2 * (8 * q4) / (8 * 8 * chord10)
    checkNear(p10.v[3], MAXV / KMH, 1e-9,
        "10° 小折角：circumcircle 曲率生效，角度上限不介入")
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
    F.control(pLine, stJump, 0, 0, 0, 0, DT) -- 首次全線定位後，熱幀仍受局部窗口限制。
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

    -- 前視距離：clamp(6 + |speed| * 0.12, 6, 18)（直路 κ≈0；急彎另有 min(look,0.75/κ)、
    -- 下限 4.5 的收縮，實機 s017/s021/s026 三輪定量驗證，離線不重建彎中反推）。
    -- 用「誤差＝atan2(橫向, 前視)」反推
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
    checkTrue(maxDecelDemand(pSine) <= 8 + 1e-6, "S 彎：沒有路段的減速需求超過 BRAKE")
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
    -- sqrt(2·8·40)=91.1 km/h > 沙盒 60：被上限 clamp——遠端不再受制動曲線壓制
    checkNear(tsFar, 60, 1e-9, "剩 40m 的目標速度＝上限 60（BRAKE=8 的制動曲線不再壓到這）")
    local _, tsNear, remNear = driveTo(194, 40)
    checkNear(remNear, 6, 1e-9, "剩 6m")
    checkNear(tsNear, math.sqrt(2 * 8 * 6) * KMH, 1e-9,
        "剩 6m：段內制動包絡 sqrt(2·BRAKE·rem)（BRAKE=8）")
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
    -- 距終點 50m 照制動曲線 sqrt(2·BRAKE·50)，中段夾 maxSpeed（加速側無包絡）。
    do
        local pLong = buildRoute({ 0, 0, 233, 0 }, 120)
        local stLong = F.newState()
        local _, tsMid, remMid = F.control(pLong, stLong, 116.5, 0, 0, 60, DT)
        checkNear(remMid, 116.5, 1e-9, "長段中點：remaining=116.5")
        checkTrue(tsMid > 60, "長段中點距終點 116m：巡航不減速（實得 " .. show(tsMid) .. "）")
        local _, ts50 = F.control(pLong, stLong, 183, 0, 0, 60, DT)
        checkNear(ts50, math.sqrt(2 * 8 * 50) * KMH, 1e-9,
            "長段內距終點 50m：制動包絡 sqrt(2·BRAKE·50)＝101.8，不是線性攤薄的 4.3")
        local _, tsEnd = F.control(pLong, stLong, 231, 0, 0, 20, DT)
        checkNear(tsEnd, math.sqrt(2 * 8 * 2) * KMH, 1e-9,
            "長段內距終點 2m：sqrt(2·BRAKE·2)＝20.4（終點收斂不受包絡影響）")
    end

    -- 末段投影落在終點前 5m、但車橫向偏離 20m（被撞開／擦身而過）：沿線條件成立、
    -- 歐氏條件不成立。這是「假抵達」最貼近實機的形狀
    local _, tsSide, remSide, reachedSide = F.control(pLine, st, 195, 20, 0, 10, DT)
    checkNear(remSide, 5, 1e-9, "橫向偏 20m：沿線剩餘距離照樣回報 5m（診斷／控速仍要用）")
    checkFalse(reachedSide, "橫向偏離終點 20m：沿線 remaining<=5 也不算抵達")
    checkNear(tsSide, 16.362, 0.05,
        "橫向偏 20m（誤差 ≈76°）：ERR 25/90 過渡帶壓向爬行帶（激進化後 ≈16.4，"
        .. "不再壓死 12；t=(90-err)/65 對原制動剖面線性內插）")

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
    local stFlip = F.newState()
    stFlip.iTerm, stFlip.errPrev, stFlip.dFilt = 0.5, -0.1, 0
    local flipSteer = F.control(pLine, stFlip, 100, 0, 0.1, 0, DT)
    checkTrue(flipSteer < 0 and stFlip.iTerm < 0,
        "誤差換側時立即清掉反向積分，不再抵消回線轉向")
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
    checkNear(tgtAt(5), 60, 1e-9, "誤差 5°（< START 25°）：不收油")
    checkNear(tgtAt(-5), 60, 1e-9, "誤差 -5°：對稱不收油")
    -- ERR_SLOW 25°/90°（2026-09-01 激進化）：t=(END-err)/RANGE
    checkNear(tgtAt(30), 12 + (60 - 12) * (90 - 30) / 65, 1e-6,
        "誤差 30°：線性過渡（t≈0.923）")
    checkNear(tgtAt(-30), 12 + (60 - 12) * (90 - 30) / 65, 1e-6, "誤差 -30°：左右對稱")
    checkNear(tgtAt(50), 12 + (60 - 12) * (90 - 50) / 65, 1e-6,
        "誤差 50°：仍在過渡帶（t≈0.615）")
    checkNear(tgtAt(90), 12, 1e-6, "誤差 90°（＝END）：壓到爬行速度（與調頭同一檔）")
    checkNear(tgtAt(95), 12, 1e-6, "誤差 95°：t 夾在 0，仍是爬行速度、不會更低")
    -- 制動段（終點前 8m，剖面原值 ≈22 km/h > 爬行）大誤差：壓到爬行、不因 t=0 而歸零；
    -- cap = 爬行 + (target - 爬行) * t 在 target ≤ 爬行時恆 ≥ target，數學上只壓不抬，
    -- 低於爬行的終點制動速度不會被這條規則抬回去（脫困地板是另一條、有自己的窗口）。
    F.resetState(st)
    st.idx = 19
    local _, tgtBrake, remBrake = F.control(pLine, st, 192, 0, -70 * math.pi / 180, 10, DT)
    checkTrue(remBrake > F.ARRIVE_M, "取樣點在抵達窗之外（排除脫困地板干擾）")
    checkTrue(tgtBrake >= 12 - 1e-6 and tgtBrake <= 22,
        "制動段誤差 70°：壓向爬行帶、絕不低於 12（實得 " .. tostring(tgtBrake) .. "）")
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
    checkTrue(exactOffset(st, 1, 2, 3, 4, 0), "l==0（借中心線）：合法剖面")
    checkTrue(exactOffset(st, 1, 2, 3, 4, 2), "合法剖面：接受")
    checkTrue(exactOffset(st, 1, 2, 2, 4, 2), "b==c（保持段長 0）：接受")

    -- 幾何：車在 pLine (50,0) 壓線、heading=0、speed=30 → look=9.6、前視點弧長 59.6。
    -- 測試自算參考值：err = atan2(偏移量, 9.6)。
    local look = 9.6
    local function errWith(a, b, c, d, l)
        local st2 = F.newState()
        if a then
            if not exactOffset(st2, a, b, c, d, l) then error("setOffset 意外失敗") end
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
    checkNear(errEntry, math.atan2 and math.atan2(2 * tSm, look) or math.atan(2 * tSm / look), 2e-4,
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
    checkTrue(exactOffset(stZero, 50, 58, 70, 78, 0), "offL=0 剖面：接受")
    local _, _, _, _, errZero = F.control(pLine, stZero, 50, 0, 0, 30, DT)
    checkNear(errZero, 0, 1e-9, "保持段：bias 被壓回中心線（offL=0 生效、非 inactive）")

    local st3 = F.newState()
    checkTrue(exactOffset(st3, 50, 58, 70, 78, 2), "先掛上側偏")
    F.clearOffset(st3)
    local _, _, _, _, errCleared = F.control(pLine, st3, 50, 0, 0, 30, DT)
    checkNear(errCleared, 0, 1e-12, "clearOffset 後回到壓線零誤差")
    checkEq(st3.offL, nil, "clearOffset 後 offL 為 nil（數值哨兵退場）")

    local stReset = F.newState()
    checkTrue(exactOffset(stReset, 50, 58, 70, 78, 2), "resetState 前掛上側偏")
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
    checkTrue(exactOffset(st, 50, 58, 70, 78, -2), "掛上繞行剖面（offL=-2，反側）")
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
    local st = F.newState()
    checkTrue(F.setOffset(st, 10, 16, 24, 30, -1.75, ox, oy, n2, 5, 31),
        "validated dodge line commit accepted")
    checkTrue(st.ovX == ox and st.ovY == oy,
        "dodge sweep and control borrow the identical arrays")
    F.clearOffset(st)
    local fracX, fracY = {}, {}
    local fracN, fracS0, fracWhy, fracS1 = F.buildOffsetLine(
        pS, 5, 10, 16, 24, 30.4, -1.75, 0.3, fracX, fracY)
    checkEq(fracWhy, "ok", "fractional endpoint line builds")
    checkNear(fracS1, 31.4, 1e-12, "returned ovEndS is the sampled endpoint arclength")
    checkNear(fracX[fracN], fracS1, 1e-12,
        "fractional final point uses the same arclength parameter")
    checkTrue(F.setOffset(st, 10, 16, 24, 30.4, -1.75,
        fracX, fracY, fracN, fracS0, fracS1), "fractional exact line commit accepted")
    checkNear(st.ovEndS, fracS1, 1e-12, "control state retains exact fractional ovEndS")
    F.clearOffset(st)
    -- coverEnd 契約（2026-09-02 console 定罪：d 允許超 route 終點後，折線只建
    -- 到終點——覆蓋檢查仍要求 d+1 ＝ commit 每輪門口被拒的死循環）
    checkFalse(F.setOffset(st, 10, 16, 24, 40, -1.75,
        fracX, fracY, fracN, fracS0, fracS1),
        "d 超 route 終點且未傳 coverEnd：原契約拒收（線只到 31.4 < 41）")
    checkTrue(F.setOffset(st, 10, 16, 24, 40, -1.75,
        fracX, fracY, fracN, fracS0, fracS1, fracS1),
        "coverEnd＝route 終點：近目標帶偏抵達的截斷線合法 commit")
    checkNear(st.offD, 40, 1e-12, "offD 保留原 d（回線 smoothstep 幾何參數）")
    F.clearOffset(st)
    checkFalse(F.setOffset(st, 10, 16, 24, 28, -1.75,
        fracX, fracY, fracN, fracS0, 28.0, 60),
        "coverEnd 不得放寬超過 d+1（上鉗 29 > 實線 28 仍拒）")
    F.clearOffset(st)
    checkTrue(st.ovX == st.ownOvX and st.ovY == st.ownOvY,
        "dodge release restores owned buffers")
end

-- =====================================================================
-- nav API v4 metadata：嚴格對齊；真正 v2/v3 一律 unknown
-- =====================================================================
scenario("nav v4 metadata strict-copy；v2/v3 ignore similarly named fields")
do
    local route = {
        pts = { 0, 0, 10, 0, 20, 0 },
        segSurface = { "paved", "dirt" },
        segWidth = { 6, 4.5 },
    }
    local p4 = F.begin(route, MAXV, 4)
    checkEq(type(p4), "table", "aligned v4 accepted")
    checkEq(p4.navVersion, 4, "nav version copied")
    checkEq(p4.segSurface[1], F.SURFACE_PAVED, "paved string mapped to numeric id")
    checkEq(p4.segSurface[2], F.SURFACE_DIRT, "dirt string mapped to numeric id")
    checkNear(p4.segWidth[1], 6, 1e-12, "width copied")
    route.segSurface[1], route.segWidth[1] = "gravel", 99
    checkEq(p4.segSurface[1], F.SURFACE_PAVED, "Follower owns metadata copy")
    checkNear(p4.segWidth[1], 6, 1e-12, "width copy is immutable from route mutation")

    local function reject(surface, width, label)
        local p = F.begin({
            pts = { 0, 0, 10, 0, 20, 0 },
            segSurface = surface,
            segWidth = width,
        }, MAXV, 4)
        checkNil(p, label)
    end
    reject(nil, { 6, 6 }, "v4 missing segSurface fail-stop")
    reject({ "paved" }, { 6, 6 }, "v4 wrong surface length fail-stop")
    reject({ "paved", "mud" }, { 6, 6 }, "v4 invalid surface enum fail-stop")
    reject({ "paved", "dirt" }, { 6 }, "v4 wrong width length fail-stop")
    reject({ "paved", "dirt" }, { 6, 0 }, "v4 nonpositive width fail-stop")
    reject({ "paved", "dirt" }, { 6, 0 / 0 }, "v4 nonfinite width fail-stop")
    reject({ "paved", "dirt" }, { 6, 0.5 }, "v4 width below 1m fail-stop")
    reject({ "paved", "dirt" }, { 6, 65 }, "v4 width above 64m fail-stop")
    reject({ "paved", "dirt" }, { 6, 1e308 }, "v4 extreme finite width fail-stop")
    local boundary = F.begin({
        pts = { 0, 0, 10, 0, 20, 0 },
        segSurface = { "paved", "dirt" },
        segWidth = { 1, 64 },
    }, MAXV, 4)
    checkEq(type(boundary), "table", "v4 width boundaries 1/64 accepted")

    for version = 2, 3 do
        local legacy = F.begin({
            pts = { 0, 0, 10, 0, 20, 0 },
            segSurface = { "paved" },
            segWidth = { -1 },
        }, MAXV, version)
        checkEq(type(legacy), "table", "v" .. version .. " basic following accepted")
        checkEq(legacy.segSurface[1], F.SURFACE_UNKNOWN,
            "v" .. version .. " segment 1 explicitly unknown")
        checkEq(legacy.segSurface[2], F.SURFACE_UNKNOWN,
            "v" .. version .. " segment 2 explicitly unknown")
        checkEq(legacy.segWidth[1], 0, "v" .. version .. " width unknown sentinel")
    end
    local trustRoute = { pts = { 0, 0, 10, 0 } }
    checkNil(F.begin(trustRoute, MAXV, 0 / 0), "explicit NaN nav version is malformed")
    checkNil(F.begin(trustRoute, MAXV, 2.5), "fractional nav version is malformed")
    checkNil(F.begin(trustRoute, MAXV, 1), "explicit version below 2 is malformed")
    checkEq(type(F.begin(trustRoute, MAXV, nil)), "table",
        "only nil direct legacy version defaults to v2")
end

-- =====================================================================
-- Adaptive lookScale + RETURN exact world line
-- =====================================================================
scenario("adaptive lookScale changes pursuit; RETURN smoothstep line is borrowed by identity")
do
    local p = buildRoute(straight(20, 5), MAXV)
    local normal, scaled = F.newState(), F.newState()
    p.lookScale = 1
    local steerNormal = F.control(p, normal, 20, 4, 0, 30, DT)
    p.lookScale = 1.5
    local steerScaled = F.control(p, scaled, 20, 4, 0, 30, DT)
    checkTrue(math.abs(steerScaled) < math.abs(steerNormal),
        "longer adaptive lookahead reduces same-offset steering demand")

    local rx, ry = {}, {}
    local n, s0, _, s1 = F.buildReturnLine(p, 10, 30, 4, 1, rx, ry)
    checkTrue(n >= 20, "RETURN line covers the requested longitudinal span")
    checkEq(s0, 10, "RETURN line keeps exact s0")
    checkNear(ry[1], 4, 1e-9, "smoothstep starts at measured lane")
    checkNear(ry[n], 1, 1e-9, "tail reaches target lane")
    local monotonic = true
    for i = 2, n do
        if ry[i] > ry[i - 1] + 1e-9 then monotonic = false end
    end
    checkTrue(monotonic, "laneStart->laneTarget is monotonic")
    local st = F.newState()
    checkTrue(F.setExactLine(st, rx, ry, n, s0, s1), "exact line commit accepted")
    checkTrue(st.ovX == rx and st.ovY == ry,
        "Follower borrows the exact arrays swept by Driver; no second trajectory")
    checkTrue(st.exactLine, "exact-line mode recorded")
    F.clearOffset(st)
    checkFalse(st.exactLine, "clear releases exact-line mode")
    checkTrue(st.ovX == st.ownOvX and st.ovY == st.ownOvY,
        "clear restores preallocated owned dodge buffers")
    local tailProfile = buildRoute(straight(40, 5), 120)
    local tailN, tailS0 = F.buildReturnLine(
        tailProfile, 10, 18, 4, 1, rx, ry, 32)
    checkTrue(tailN >= 40 and tailS0 + tailN - 1 >= 50,
        "short RETURN retains max-lookahead/body tail on the exact line")
    checkNear(ry[tailN], 1, 1e-9, "RETURN tail stays on target lane")
    local longProfile = buildRoute(straight(60, 5), MAXV)
    local tooLong, _, tooLongReason =
        F.buildReturnLine(longProfile, 0, F.OV_MAX + 1, 50, 0, rx, ry)
    checkEq(tooLong, 0,
        "RETURN required samples beyond fixed capacity fail unsafe instead of truncating")
    checkEq(tooLongReason, "capacity", "capacity overflow has deterministic reason")
end

-- =====================================================================
-- Full-route adaptive caps：遠端 braking/curve 都吃 safe lower bound，0 可 fail-safe
-- =====================================================================
scenario("full-route dynamics cap propagates across segments and accepts zero fail-safe")
do
    local pts = straight(11, 10)
    local base = buildRoute(pts, 60)
    local capped = F.begin(mkRoute(pts), 60, 2)
    checkTrue(F.capSegmentLimits(capped, 0.5, 1.0, 0.8, 0.3),
        "material safe limits cap every preallocated segment")
    while not F.stepBuild(capped, 4096) do end
    local allCapped = true
    for i = 1, capped.n - 1 do
        if capped.segAccel[i] > 0.5 or capped.segBrake[i] > 1
                or capped.segLat[i] > 0.8 then allCapped = false end
    end
    checkTrue(allCapped, "all route segments retain the safe caps")
    checkTrue(capped.v[1] < base.v[1],
        "low brake cap propagates backward from a far endpoint")

    local zero = F.begin(mkRoute(pts), 60, 2)
    checkTrue(F.capSegmentLimits(zero, 0, 0, 0, 0), "zero segment limits accepted")
    while not F.stepBuild(zero, 4096) do end
    checkNear(zero.v[1], 0, 1e-12, "zero brake fail-safe propagates stop across route")
    local st = F.newState()
    checkTrue(F.setRuntimeLimits(st, 0, 0, 0, 0), "zero runtime limits accepted")
    checkEq(st.accelSafe, 0, "zero runtime accel retained")
    checkEq(st.brakeSafe, 0, "zero runtime brake retained")
    checkEq(st.latSafe, 0, "zero runtime lateral retained")
end

-- =====================================================================
-- Phase F：v4 adaptive C1 fillet、road-band、metadata 與 proof line
-- =====================================================================
scenario("0907f：adaptive fallback 頂點（≤90°）前視目標同髮夾鉗到切點才放行")
do
    -- session-020 t=13-16：F350 倒車復位後 12-16 km/h 仍在折點前 6-8m 朝另一臂切內撞住。
    -- 4m 路 90° 折點、rMin 4.32：切點距 rMin·tan(45°)＝4.32m；折點前 8m 目標＝頂點（誤差 0），
    -- 折點前 3m 放行到另一臂（誤差 >30°）。RaceCar 同路口圓角成功＝弧段，不走這條。
    local vp = { valid = true, geometryValid = true, halfW = 0.9, halfL = 2.9, rMin = 4.32,
        wheelbase = 3.79, delta0Safe = 0.72, deltaVSafe = 0.24, maxSpeed = 100 }
    local route = { pts = { 0, 0, 60, 0, 60, 60, 60, 120 }, segSurface = { "paved", "paved", "paved" },
        segWidth = { 4, 4, 4 } }
    local p = F.begin(route, 70, 4, vp)
    while not F.stepBuild(p, 4096) do end
    checkEq(p.filletFallbackN, 1, "F350 4m 路 90°：fallback 頂點")
    local function segAt(sq)
        local qi = 1
        while qi < p.n - 1 and p.s[qi + 1] < sq do qi = qi + 1 end
        return qi
    end
    -- 40 km/h 前視 10.8m：折點前 8m 的目標本來會落到另一臂（無鉗制＝誤差 >0）
    local st = F.newState()
    st.idx = segAt(52)
    local _, _, _, _, e8 = F.control(p, st, 52, 0, 0, 40, DT)
    checkNear(e8, 0, 1e-9, "折點前 8m（前視 10.8m 越過折點）：目標鉗在頂點、誤差 0")
    st = F.newState()
    st.idx = segAt(57)
    local _, _, _, _, e3 = F.control(p, st, 57, 0, 0, 12, DT)
    checkTrue(math.abs(e3) > math.rad(30), string.format("折點前 3m（< 切點距 4.32）：放行到另一臂，誤差 %.0f°", math.deg(math.abs(e3))))
    -- 放行那幀＝誤差定義切換（Codex lane 2026-09-07 真 Follower 重現：lookScale 1.5、12 km/h 跨 4.32m
    -- 切點，err 0→58° 一幀、dFilt 0→18、steer 0→5 飽和三幀）：同一份 state 連續走過切點，D 項要清。
    p.lookScale = 1.5
    st = F.newState()
    local x, dtF = 60 - 4.6, 1 / 60
    local steerRel, dFiltRel, seenHeld = nil, nil, false
    for _ = 1, 8 do
        local steer = F.control(p, st, x, 0, 0, 12, dtF)
        if st.kinkHeld then seenHeld = true
        elseif seenHeld and steerRel == nil then steerRel, dFiltRel = steer, st.dFilt end
        x = x + 12 / 3.6 * dtF
    end
    checkTrue(seenHeld and steerRel ~= nil, "持續 state 從鉗制走到放行")
    checkTrue(steerRel ~= nil and math.abs(steerRel) < 3,
        string.format("放行那幀只剩 P 項（steer %.2f，舊制 D-kick 飽和 5）", steerRel or 0))
    checkNear(dFiltRel or 99, 0, 1e-9, "放行那幀 dFilt 已清")
    p.lookScale = 1
    -- 相鄰兩個 fallback 角 A(60,0)→B(60,6)：A 放行那幀直接鉗 B（Codex lane 靜態推導：boolean 記法
    -- held true→true 不清 D、steer 飽和 5）——記頂點弧長才分得出切換
    local r2 = { pts = { 0, 0, 60, 0, 60, 6, 120, 6 }, segSurface = { "paved", "paved", "paved" },
        segWidth = { 4, 4, 4 } }
    local p2 = F.begin(r2, 70, 4, vp)
    while not F.stepBuild(p2, 4096) do end
    checkEq(p2.filletFallbackN, 2, "兩個 fallback 角")
    p2.lookScale = 1.5
    local st2 = F.newState()
    local x2, steerAB, dAB = 55.65, nil, nil
    for _ = 1, 3 do
        local steer, _, _, _, errAB = F.control(p2, st2, x2, 0, 0, 12, 1 / 60)
        if math.abs(errAB) > math.rad(40) and steerAB == nil then steerAB, dAB = steer, st2.dFilt end
        x2 = x2 + 12 / 3.6 / 60
    end
    checkTrue(steerAB ~= nil and math.abs(steerAB) < 3,
        string.format("A 放行同幀鉗到 B：仍清 D（steer %.2f）", steerAB or 0))
    checkNear(dAB or 99, 0, 1e-9, "A→B 切換幀 dFilt 已清")
end

scenario("0907f：adaptive fallback 頂點（rMin 塞不進 band）速度＝sqrt(aLat·rMin)，不再吃角度帽 50")
do
    -- 2026-09-07 F350（halfW 0.9、rMin 4.32）在 4m 路 90° 折點：圓角塞不進 band → fallback 頂點
    -- 舊制只吃 TURN_HARD_MS 50 → 50.8 km/h 直衝路口牆（session-020 t=7）。RaceCar 同路口圓角成功走弧段。
    local f350 = { valid = true, geometryValid = true, halfW = 0.9, halfL = 2.9, rMin = 4.32,
        wheelbase = 3.79, delta0Safe = 0.72, deltaVSafe = 0.24, maxSpeed = 100 }
    local race = { valid = true, geometryValid = true, halfW = 0.66, halfL = 1.62, rMin = 2.26,
        wheelbase = 1.98, delta0Safe = 0.72, deltaVSafe = 0.24, maxSpeed = 120 }
    local function build(vp, w)
        local route = { pts = { 0, 0, 60, 0, 60, 60, 60, 120 }, segSurface = { "paved", "paved", "paved" },
            segWidth = { w, w, w } }
        local p = F.begin(route, 70, 4, vp)
        while not F.stepBuild(p, 4096) do end
        local minV, minI = 99, 0
        for i = 1, p.n - 1 do if p.curveV[i] < minV then minV, minI = p.curveV[i], i end end
        return p, minV, minI
    end
    local pf, vf, vi = build(f350, 4)
    checkEq(pf.filletFallbackN, 1, "F350 4m 路 90°：圓角塞不進 band → fallback 頂點")
    checkEq(pf.segKind[vi], MDADDynamics.SEG_FALLBACK, "最低速在 fallback 頂點段")
    checkNear(vf, math.sqrt(9.0 * 4.32), 1e-9, "fallback 頂點速度＝sqrt(LAT 9 × rMin 4.32)＝22.4 km/h（舊制 50）")
    local pr, vr = build(race, 4)
    checkEq(pr.filletN, 1, "RaceCar 同路口圓角成功")
    checkTrue(vr > math.sqrt(9.0 * 2.26), "圓角成功時走弧段 κ（高於 sqrt(aLat·rMin)）")
    local pw, vw = build(f350, 8)
    checkEq(pw.filletN, 1, "8m 路：F350 圓角成功")
    checkTrue(vw * KMH > 30, "8m 路弧段 R≈8.9 → 32 km/h，不受 fallback 規則影響")
    -- capacity 退路（source > FILLET_SOURCE_MAX）整條標 FALLBACK 但幾何無事：30° 折點走 pure pursuit 式
    -- （≈全速附近），不得吃 sqrt(aLat·rMin)；鉗制也不套
    local many = {}
    for i = 0, MDADDynamics.FILLET_SOURCE_MAX + 2 do many[#many + 1] = i * 4; many[#many + 1] = 0 end
    local a30 = math.rad(30)
    local lx, ly = many[#many - 1], many[#many]
    many[#many + 1] = lx + 40 * math.cos(a30); many[#many + 1] = 40 * math.sin(a30)
    many[#many + 1] = lx + 80 * math.cos(a30); many[#many + 1] = 80 * math.sin(a30)
    local cnt = #many / 2
    local rc = { pts = many, segSurface = {}, segWidth = {} }
    for i = 1, cnt - 1 do rc.segSurface[i], rc.segWidth[i] = "paved", 8 end
    local pc = F.begin(rc, 70, 4, f350)
    while not F.stepBuild(pc, 4096) do end
    checkEq(pc.filletReason, "capacity", "capacity 退路 fixture")
    local vk = 99
    for i = 1, pc.n - 1 do if pc.curveV[i] < vk then vk = pc.curveV[i] end end
    checkTrue(vk > math.sqrt(9.0 * 4.32) + 1, string.format("capacity 退路的 30° 折點不吃 sqrt(aLat·rMin)（實得 %.1f km/h）", vk * KMH))
end

scenario("adaptive v4 fillet is C1/band-safe with aligned metadata and explicit fallback")
do
    local vp = {
        valid = true, geometryValid = true, halfW = 1, rMin = 3,
        wheelbase = 2.5, delta0Safe = 0.7, deltaVSafe = 0.25, maxSpeed = 120,
    }
    local sourcePts = { 0, 0, 30, 0, 30, 30 }
    local sourceCopy = {}
    for i = 1, #sourcePts do sourceCopy[i] = sourcePts[i] end
    local route = {
        pts = sourcePts,
        segSurface = { "paved", "gravel" },
        segWidth = { 12, 10 },
    }
    local p = F.begin(route, 120, 4, vp)
    checkTrue(p ~= nil, "profile builds for fillet route")
    while not F.stepBuild(p, 4096) do end
    checkEq(p.filletN, 1, "20-90° feasible corner becomes one fillet")
    checkEq(p.filletFallbackN, 0, "feasible fillet has no fallback")
    checkTrue(p.n > #sourcePts / 2, "arc samples expand the owned profile only")
    checkEq(#p.segSurface, p.n - 1, "fillet segSurface aligned")
    checkEq(#p.segWidth, p.n - 1, "fillet segWidth aligned")
    checkEq(#p.segKind, p.n - 1, "fillet kind aligned")
    checkEq(route.pts, sourcePts, "route.pts identity remains immutable")
    local sourceDrift = false
    for i = 1, #sourcePts do if sourcePts[i] ~= sourceCopy[i] then sourceDrift = true end end
    checkFalse(sourceDrift, "fillet never mutates source coordinates")

    local firstArc, maxK = nil, 0
    for i = 1, p.n - 1 do
        if (p.kappa[i] or 0) > maxK then maxK = p.kappa[i] end
        if p.segKind[i] == 1 then
            firstArc = firstArc or i
            local mx = (p.x[i] + p.x[i + 1]) * 0.5
            local my = (p.y[i] + p.y[i + 1]) * 0.5
            local d1 = MDADDynamics.distanceToSegmentSq(mx, my, 0, 0, 30, 0)
            local d2 = MDADDynamics.distanceToSegmentSq(mx, my, 30, 0, 30, 30)
            local b1, b2 = 12 / 2 - vp.halfW - 0.4, 10 / 2 - vp.halfW - 0.4
            checkTrue(d1 <= b1 * b1 + 1e-8 or d2 <= b2 * b2 + 1e-8,
                "arc segment remains in adjacent source road-band union #" .. i)
        end
    end
    checkTrue(firstArc ~= nil and firstArc > 1, "arc has a source-line predecessor")
    checkTrue(maxK <= 1 / vp.rMin + 1e-3, "profile kappa <= 1/rMin")
    local lineState = F.newState()
    lineState.idx = 1
    F.setRuntimeLimits(lineState, 3, 6, 3.5, 0.6)
    F.control(p, lineState, (p.x[1] + p.x[2]) * 0.5,
        (p.y[1] + p.y[2]) * 0.5, p.segH[1], 10, DT)
    checkFalse(lineState.curveHardActive,
        "straight segment never arms the current-arc hard brake")
    checkNear(lineState.curveKappa, 0, 1e-12,
        "future arc curvature is not published as current hard curvature")
    local arcState = F.newState()
    arcState.idx = firstArc
    F.setRuntimeLimits(arcState, 3, 6, 3.5, 0.6)
    F.control(p, arcState, (p.x[firstArc] + p.x[firstArc + 1]) * 0.5,
        (p.y[firstArc] + p.y[firstArc + 1]) * 0.5,
        p.segH[firstArc], 10, DT)
    local highArcCap = arcState.curveCapKmh
    checkTrue(arcState.curveHardActive and arcState.curveKappa > 0,
        "current SEG_ARC arms the hard curvature envelope")
    -- 0906i：行駛線往彎內側偏 lt 時硬曲率帽＝κ/(1−lt·κ)（半徑 R−lt），外側不放寬。
    -- 用繞行承諾線驗（保持段沿路平移 offL）：commit／守護的繞行 κ 從此只量兩段過渡，
    -- 弧內側的保持段就靠這一道（review lane 抓到的反例）。違規證明：拿掉修正即紅。
    do
        local mx = (p.x[firstArc] + p.x[firstArc + 1]) * 0.5
        local my = (p.y[firstArc] + p.y[firstArc + 1]) * 0.5
        local hA = p.segH[firstArc]
        local sArc = (p.s[firstArc] + p.s[firstArc + 1]) * 0.5
        local a, b, c, d = sArc - 25, sArc - 18, sArc + 18, sArc + 25
        local function kappaOnLine(offL, latSafe)
            local ox, oy = {}, {}
            local n, s0, reason, s1 = F.buildOffsetLine(p, a - 2, a, b, c, d, offL, 0, ox, oy)
            checkEq(reason, "ok", "偏移 " .. offL .. " 的承諾線可建")
            local st = F.newState()
            st.idx = firstArc
            F.setRuntimeLimits(st, 3, 6, latSafe or 3.5, 0.6)
            checkTrue(F.setOffset(st, a, b, c, d, offL, ox, oy, n, s0, s1), "承諾線 setOffset")
            local _, _, _, _, _, _, _, ll = F.control(p, st,
                mx - math.sin(hA) * offL, my + math.cos(hA) * offL, hA, 10, DT)
            checkTrue(st.curveHardActive, "偏移 " .. offL .. "：車在弧段（硬帽啟用）")
            checkNear(ll, offL, 0.02, "偏移 " .. offL .. "：承諾線在投影點的橫向≈offL（實得 " .. tostring(ll) .. "）")
            return st.curveKappa, st.idx, ll, st.curveCapKmh
        end
        local kIn, iIn, llIn, capIn = kappaOnLine(1.5)   -- 東→南＝右轉（y 向南的世界 dθ>0），內側＝+lane
        local kOut, iOut = kappaOnLine(-1.5)
        local kC = math.max(p.kappa[iOut] or 0, p.kappa[iOut + 1] or 0)
        checkEq(iIn, iOut, "內外側投影到同一弧段")
        checkNear(kOut, kC, 1e-12, "外側偏移：硬曲率帽維持中心線 κ（不放寬）")
        checkNear(kIn, kC / (1 - llIn * kC), 1e-12,
            "內側偏移 1.5：κ/(1−lt·κ)、lt＝承諾線實際橫向（R " .. string.format("%.2f", 1 / kC)
            .. " → " .. string.format("%.2f", 1 / kIn) .. "）")
        checkTrue(kIn > kOut, "內側帽比外側嚴")
        -- 轉向可行性（curveSpeedCapKmh 的另一半，review lane）：硬帽＝min(橫向加速度帽, 轉向帽)，
        -- 轉向帽以修正後 κ 算、地板 12。這台車 δV 0.25 對 κ 0.083 不綁（帽＝橫向）；把剖面的轉向
        -- 參數改成 F350 級（δ0 .25／δV .05）＋橫向 30 讓轉向綁住，帽必須跟著轉向帽走。
        local D = MDADDynamics
        checkNear(capIn, 3.6 * math.sqrt(3.5 / kIn), 1e-9, "內側帽＝橫向加速度帽（轉向未綁）")
        local d0, dv = p.delta0Safe, p.deltaVSafe
        p.delta0Safe, p.deltaVSafe = 0.25, 0.05
        local steerCap = D.steeringSpeedCapKmh(kIn, p.wheelbase, 0.25, 0.05, p.vehicleMaxSpeed)
        checkTrue(steerCap > 12 and steerCap < 3.6 * math.sqrt(30 / kIn),
            "fixture：轉向帽 " .. string.format("%.1f", steerCap) .. " 介於地板與橫向帽（latSafe 30）之間")
        local _, _, _, capSteer = kappaOnLine(1.5, 30)
        checkNear(capSteer, steerCap, 1e-9, "轉向綁住：硬帽＝steeringSpeedCapKmh(修正後 κ)")
        local _, _, _, capOut = kappaOnLine(-1.5, 30)
        checkTrue(capOut > steerCap + 1, "外側偏移（中心線 κ）轉向帽較寬鬆（實得 " .. string.format("%.1f", capOut) .. "）")
        p.delta0Safe, p.deltaVSafe = 0.2, 0.05 -- δ0 < 需求角 0.205 → 轉向帽 0 → 地板 12，不煞停在弧裡
        local _, _, _, capFloor = kappaOnLine(1.5, 30)
        checkNear(capFloor, 12, 1e-9, "轉向轉不出來（帽 0）：壓到曲率地板 12，不否決")
        p.delta0Safe, p.deltaVSafe = d0, dv
    end
    local retainedSegLat = p.segLat[firstArc]
    F.setRuntimeLimits(arcState, 3, 6, 0.2, 0.6)
    F.control(p, arcState, (p.x[firstArc] + p.x[firstArc + 1]) * 0.5,
        (p.y[firstArc] + p.y[firstArc + 1]) * 0.5,
        p.segH[firstArc], 10, DT)
    checkTrue(arcState.curveCapKmh < highArcCap,
        "runtime safeLat drop tightens the active arc before profile rebuild")
    -- 0907：即時弧帽與建表頂點帽同一下限 12（latSafe 0.2 對 κ 0.074 解析出 5.9 km/h；實機 T 字
    -- 路口 9.1 爬 20m 就是這條沒地板）。違規證明：拿掉 MIN_SPEED 夾即紅
    checkNear(arcState.curveCapKmh, 12, 1e-9,
        "即時弧帽不低於曲率地板 12（實得 " .. tostring(arcState.curveCapKmh) .. "）")
    checkNear(p.segLat[firstArc], retainedSegLat, 1e-12,
        "immediate runtime tightening does not mutate the still-high profile")
    checkTrue(arcState.curveValid, "successful control explicitly publishes valid curve state")
    F.control(p, arcState, 0 / 0, 0, 0, 10, DT)
    checkFalse(arcState.curveValid, "invalid-coordinate return clears curve validity first")
    checkFalse(arcState.curveHardActive,
        "invalid-coordinate return cannot retain stale current-arc hard state")
    checkNear(arcState.curveKappa, 0, 1e-12, "invalid-coordinate return clears stale kappa")
    checkNear(arcState.curveCapKmh, 0, 1e-12, "invalid-coordinate return clears stale cap")
    local coastPts = { 0, 0, 10, 0, 20, 0, 30, 0, 40, 0, 50, 0, 60, 0, 60, 30 }
    local coastRoute = { pts = coastPts, segSurface = {}, segWidth = {} }
    for i = 1, #coastPts / 2 - 1 do
        coastRoute.segSurface[i], coastRoute.segWidth[i] = "paved", 12
    end
    local highCoastProfile = F.begin(coastRoute, 120, 4, vp)
    local lowCoastProfile = F.begin(coastRoute, 120, 4, vp)
    checkTrue(F.capSegmentLimits(lowCoastProfile, 3, 6, 3.5, 0.05),
        "lower learned coast limit is accepted before rebuild")
    while not F.stepBuild(highCoastProfile, 4096) do end
    while not F.stepBuild(lowCoastProfile, 4096) do end
    local coastArc = 1
    while coastArc < highCoastProfile.n - 1
            and highCoastProfile.segKind[coastArc] ~= MDADDynamics.SEG_ARC do
        coastArc = coastArc + 1
    end
    local coastLeadSegments = 0
    for i = 1, coastArc - 1 do
        if lowCoastProfile.coastV[i] < highCoastProfile.coastV[i] - 1e-9 then
            coastLeadSegments = coastLeadSegments + 1
        end
    end
    checkTrue(coastLeadSegments > 1,
        "safeCoast decline propagates earlier coast across multiple approach segments")
    local ix, iy = p.x[firstArc] - p.x[firstArc - 1], p.y[firstArc] - p.y[firstArc - 1]
    local ax, ay = p.x[firstArc + 1] - p.x[firstArc], p.y[firstArc + 1] - p.y[firstArc]
    local tangentCross = math.abs(ix * ay - iy * ax)
        / math.sqrt((ix * ix + iy * iy) * (ax * ax + ay * ay))
    checkTrue(tangentCross < 0.08, "line-to-arc tangent is C1 at <=1m sampling")

    local lx, ly, lseg = {}, {}, {}
    local lineEnd = p.length
    if lineEnd > 50 then lineEnd = 50 end
    local ln, ls0, lreason, lastIdx = F.buildLaneLine(p, 0, lineEnd, 1, lx, ly, 1, lseg)
    checkTrue(ln >= 2 and ls0 == 0 and lreason == "ok", "preallocated lane proof line builds")
    checkTrue(lastIdx >= 1 and lastIdx < p.n, "proof line reports verified segment index")
    -- 沿線取樣 ≤1m；段界的 lane 台階（clampLane 逐段夾）是既有設計（無 ramp），只扣掉它
    local spacingOk = true
    for i = 2, ln do
        local dx, dy = lx[i] - lx[i - 1], ly[i] - ly[i - 1]
        local dl = F.laneBiasAt(p, 1, lseg[i]) - F.laneBiasAt(p, 1, lseg[i - 1])
        if math.sqrt(dx * dx + dy * dy) > math.sqrt(1 + dl * dl) + 0.01 then spacingOk = false end
    end
    checkTrue(spacingOk, "lane proof line spacing <=1m")

    local narrow = F.begin({
        pts = { 0, 0, 30, 0, 30, 30 },
        segSurface = { "paved", "paved" }, segWidth = { 3, 3 },
    }, 120, 4, vp)
    while not F.stepBuild(narrow, 4096) do end
    checkEq(narrow.filletN, 0, "insufficient road-band preserves source corner")
    checkTrue(narrow.filletFallbackN >= 1, "insufficient road-band is explicit fallback")
    checkEq(narrow.n, 3, "fallback keeps original point count")
    local fallbackKind = false
    for i = 1, narrow.n - 1 do
        if narrow.segKind[i] == MDADDynamics.SEG_FALLBACK then fallbackKind = true end
    end
    checkTrue(fallbackKind, "Follower localizes raw fallback in per-segment kind")

    local capX, capY = {}, {}
    local capN, _, capReason = F.buildOffsetLine(
        buildRoute(straight(100, 5), MAXV), 0, 1, 10, F.OV_MAX, F.OV_MAX + 20, 2, 0, capX, capY)
    checkEq(capN, 0, "long dodge line never truncates to OV_MAX")
    checkEq(capReason, "capacity", "long dodge capacity rejection is named")

    local minP = F.begin(mkRoute(straight(6, 10)), 60, 2)
    minP.segBrake[3], minP.segLat[4], minP.segCoast[2] = 1.25, 0.75, 0.2
    while not F.stepBuild(minP, 4096) do end
    local minBrake, minLat, minCoast = F.minDynamics(minP, 5, 45, 1)
    checkNear(minBrake, 1.25, 1e-12, "future horizon takes minimum segment brake")
    checkNear(minLat, 0.75, 1e-12, "future horizon takes minimum segment lateral")
    local tinyPts = {}
    for i = 0, 4096 do
        tinyPts[#tinyPts + 1] = i * 0.01
        tinyPts[#tinyPts + 1] = 0
    end
    local tiny = F.begin(mkRoute(tinyPts), 60, 2)
    tiny.segBrake[2500], tiny.segLat[2600], tiny.segCoast[2700] = 0.7, 0.6, 0.1
    while not F.stepBuild(tiny, 4096) do end
    local rawS, sReads = tiny.s, 0
    tiny.s = setmetatable({}, {
        __index = function(_, k) sReads = sReads + 1; return rawS[k] end,
    })
    local tb, tl, tc = F.minDynamics(tiny, 20, 30, 2000)
    checkNear(tb, 0.7, 1e-12, "tiny-segment RMQ returns brake minimum")
    checkNear(tl, 0.6, 1e-12, "tiny-segment RMQ returns lateral minimum")
    checkNear(tc, 0.1, 1e-12, "tiny-segment RMQ returns coast minimum")
    checkTrue(sReads < 80, "tiny-segment query is O(log n), profile.s reads=" .. sReads)
    checkNear(minCoast, 0.2, 1e-12, "future horizon takes minimum segment coast")
    local tinyX, tinyY, tinySeg = {}, {}, {}
    sReads = 0
    local tinyN, _, tinyReason = F.buildLaneLine(
        tiny, 20, 30, 0, tinyX, tinyY, 2000, tinySeg)
    checkTrue(tinyN >= 2 and tinyReason == "ok",
        "tiny-segment proof line builds with bounded binary seeks")
    checkTrue(sReads < 200,
        "proof sampling is O(samples*log n), profile.s reads=" .. sReads)
    local highP = buildRoute(straight(11, 10), 60)
    local highState, lowState = F.newState(), F.newState()
    F.setRuntimeLimits(highState, 3, 6, 3.5, 0.6)
    F.setRuntimeLimits(lowState, 3, 0.2, 3.5, 0.05)
    local _, highTarget = F.control(highP, highState, 85, 0, 0, 30, DT)
    local _, lowTarget = F.control(highP, lowState, 85, 0, 0, 30, DT)
    checkTrue(lowTarget < highTarget,
        "runtime safeBrake/coast drop tightens command while profile remains high")
    checkTrue(highP.segBrake[lowState.idx] > 0.2
            and highP.segCoast[lowState.idx] > 0.05,
        "safe drop regression leaves stored segment minima deliberately stale/high")

    local legacy = F.begin({
        pts = { 0, 0, 30, 0, 30, 30 },
        segSurface = { "paved", "paved" }, segWidth = { 12, 12 },
    }, 120, 3, vp)
    checkEq(legacy.filletN, 0, "v2/v3 never trusts similarly named widths for fillet")

    -- 容量退路的 band 證明語意（2026-09-02 玩家 telemetry s001-s010）：舊制輸出
    -- 超限＝buildFilletPath 回 bandValid=false → Driver 每幀 band proof 零長 →
    -- obb 警戒帽 18 常駐 7.4 km。契約：兩條退路（source 超限／輸出超限）都保持
    -- filletBandValid＝true（點在 raw 中心線上、segSource 直對 raw 段），差別只在
    -- filletReason（source 超限＝"capacity" 全 fallback；輸出超限＝nil、部分弧）。
    local hugeRoute = { pts = {}, segSurface = {}, segWidth = {} }
    local hugeN = MDADDynamics.FILLET_SOURCE_MAX + 1
    for i = 1, hugeN do
        hugeRoute.pts[i * 2 - 1] = i * 10
        hugeRoute.pts[i * 2] = (i % 2 == 0) and 10 or 0
        if i < hugeN then
            hugeRoute.segSurface[i], hugeRoute.segWidth[i] = "paved", 12
        end
    end
    local huge = F.begin(hugeRoute, 120, 4, vp)
    while not F.stepBuild(huge, 4096) do end
    checkEq(huge.filletN, 0, "source 超限：不建弧")
    checkEq(huge.filletReason, "capacity", "source 超限：reason=capacity")
    checkTrue(huge.filletBandValid, "source 超限：band 證明仍有效")
    checkEq(huge.n, hugeN, "source 超限：保留原折線")
    local allFallback = true
    for i = 1, huge.n - 1 do
        if huge.segKind[i] ~= MDADDynamics.SEG_FALLBACK then allFallback = false end
    end
    checkTrue(allFallback, "source 超限：全段 SEG_FALLBACK")

    local zigRoute = { pts = { 0, 0 }, segSurface = {}, segWidth = {} }
    for k = 1, 8 do
        local x, y = zigRoute.pts[#zigRoute.pts - 1], zigRoute.pts[#zigRoute.pts]
        if k % 2 == 1 then x = x + 40 else y = y + 40 end
        zigRoute.pts[#zigRoute.pts + 1], zigRoute.pts[#zigRoute.pts + 2] = x, y
    end
    zigRoute.pts[#zigRoute.pts + 1] = zigRoute.pts[#zigRoute.pts - 1] + 40
    zigRoute.pts[#zigRoute.pts + 1] = zigRoute.pts[#zigRoute.pts - 1]
    for i = 1, #zigRoute.pts / 2 - 1 do
        zigRoute.segSurface[i], zigRoute.segWidth[i] = "paved", 12
    end
    local savedOut = MDADDynamics.FILLET_OUTPUT_MAX
    MDADDynamics.FILLET_OUTPUT_MAX = 200
    local partial = F.begin(zigRoute, 120, 4, vp)
    MDADDynamics.FILLET_OUTPUT_MAX = savedOut
    while not F.stepBuild(partial, 4096) do end
    checkTrue(partial.filletN >= 3, "輸出超限：前段仍有弧")
    checkTrue(partial.filletFallbackN >= 3, "輸出超限：後段降 fallback")
    checkNil(partial.filletReason, "輸出超限：不是 capacity 失敗")
    checkTrue(partial.filletBandValid, "輸出超限：band 證明仍有效")
    checkTrue(partial.n <= 200, "輸出超限：profile 點數不超過上限")
end

-- =====================================================================
-- 彎內側車道偏置餘裕（2026-09-02 s013：F350 右轉切進路口內側圍籬）
-- =====================================================================
scenario("車道偏置過路面餘裕：直段夾路寬、弧段內側夾圓角吃剩、外側保留、無路寬不夾")
do
    -- 玩家 s013 幾何：北行 w=6 → 東行 w=5 的 90.9° 右轉，F350（halfW 0.9、rMin 4.32）
    local vp = {
        valid = true, geometryValid = true, halfW = 0.9, rMin = 4.32,
        wheelbase = 3.79, delta0Safe = 0.72, deltaVSafe = 0.24, maxSpeed = 85,
    }
    local function corner(rightTurn)
        local ex = rightTurn and 108 or -108
        return {
            pts = { 0, 60, 0, 0, ex, 1.78 },  -- 出口向南偏 0.94°：折角 90.94°（玩家路線原樣）
            segSurface = { "paved", "paved" },
            segWidth = { 6, 5 },
        }
    end
    local p = F.begin(corner(true), 85, 4, vp)
    while not F.stepBuild(p, 4096) do end
    checkEq(p.filletN, 1, "90.9° 路口（量化噪音）建弧而非保留折點")
    checkEq(p.filletFallbackN, 0, "90.9° 路口無 fallback")
    checkTrue(p.laneRoomR ~= nil and #p.laneRoomR == p.n - 1, "laneRoom 表逐段對齊")
    local arcI, lastLine
    for i = 1, p.n - 1 do
        if p.segKind[i] == MDADDynamics.SEG_ARC then arcI = arcI or i else lastLine = i end
    end
    checkTrue(arcI ~= nil, "有弧段")
    local bandIn = 6 / 2 - vp.halfW - MDADDynamics.ROAD_EDGE_MARGIN   -- 1.7
    local bandOut = 5 / 2 - vp.halfW - MDADDynamics.ROAD_EDGE_MARGIN  -- 1.2
    checkNear(p.laneRoomR[1], bandIn, 1e-9, "直段右餘裕＝路寬半－halfW－邊界")
    checkNear(p.laneRoomL[1], bandIn, 1e-9, "直段左餘裕同值")
    checkNear(p.laneRoomR[lastLine], bandOut, 1e-9, "出口直段（w=5）餘裕 1.2")
    local r = p.filletRadius[arcI]
    checkTrue(r >= vp.rMin, "弧半徑不小於 rMin")
    local arcE = arcI
    while p.segKind[arcE + 1] == MDADDynamics.SEG_ARC do arcE = arcE + 1 end
    local theta = math.abs(p.segH[arcE + 1] - p.segH[arcI - 1])
    checkTrue(theta > math.rad(90.5) and theta < math.rad(91.5),
        "弧總轉角 ≈ 90.94°（實得 " .. tostring(math.deg(theta)) .. "）")
    local c = math.cos(theta * 0.5)
    local sag = r * (1 - c)
    checkTrue(p.laneRoomR[arcI] < 0.5 and p.laneRoomR[arcI] >= 0,
        "右轉弧段內側餘裕＝圓角吃剩（實得 " .. tostring(p.laneRoomR[arcI]) .. "）")
    -- 2026-09-04：再扣弦矢高（≤1m 弦 L²/8r）＋1cm——弧貼滿 band 時弦中點才不出帶
    local chordSag = MDADDynamics.FILLET_SAMPLE_MAX_M ^ 2 / (8 * r) + 0.01
    checkNear(sag + chordSag + p.laneRoomR[arcI] * c, bandIn, 1e-6,
        "弧心線矢高＋弦矢高＋內側偏置·cos(θ/2) 恰等於寬臂 band")
    checkNear(p.laneRoomL[arcI], bandOut, 1e-9, "右轉弧段外側餘裕＝兩臂較窄帶")
    -- 2026-09-06 session-055：常駐 lane 落點＝room − LANE_BIAS_KEEP（夾 0）；laneRoom 表仍是物理餘裕
    local keep = F.LANE_BIAS_KEEP
    checkTrue(keep > 0.5 and keep < 1, "LANE_BIAS_KEEP 在 0.5..1（實得 " .. tostring(keep) .. "）")
    checkNear(F.laneBiasAt(p, 1.5, 1), bandIn - keep, 1e-9, "w=6 直段 +1.5 夾到 1.7−keep")
    checkNear(F.laneBiasAt(p, 0.5, 1), 0.5, 1e-9, "w=6 直段 +0.5 在 keep 內不夾")
    checkNear(F.laneBiasAt(p, 1.5, lastLine), bandOut - keep, 1e-9, "w=5 直段 +1.5 夾到 1.2−keep")
    checkNear(F.laneBiasAt(p, 1.5, arcI), 0, 1e-9,
        "弧段 +1.5：內側餘裕 " .. tostring(p.laneRoomR[arcI]) .. " < keep → 夾到 0")
    checkNear(F.laneBiasAt(p, -1.0, arcI), -(bandOut - keep), 1e-9, "弧段外側 -1.0 夾到 −(1.2−keep)")
    checkNear(F.laneBiasAt(p, 1.5, nil), 1.5, 1e-9, "無段索引回原值")

    -- 同一張表驅動前視點：laneBias 1.5，前視點落在弧上時偏置不得超過餘裕
    local st = F.newState()
    F.setLaneBias(st, 1.5)
    st.idx = arcI
    F.setRuntimeLimits(st, 3, 6, 3.5, 0.6)
    local lineX, lineY = {}, {}
    local cnt = F.buildLaneLine(p, p.s[arcI], p.s[arcI] + 3, 1.5, lineX, lineY, arcI)
    checkTrue(cnt >= 2, "弧段 lane 線可建")
    local worst = 0
    for k = 1, cnt do
        local best = 1 / 0
        for i = arcI, p.n - 1 do
            local d = MDADDynamics.distanceToSegmentSq(lineX[k], lineY[k],
                p.x[i], p.y[i], p.x[i + 1], p.y[i + 1])
            if d < best then best = d end
        end
        best = math.sqrt(best)
        if best > worst then worst = best end
    end
    checkTrue(worst <= p.laneRoomR[arcI] + 0.05,
        "弧段 lane 線離弧心線 ≤ 內側餘裕（實得 " .. tostring(worst) .. "）")

    -- 鏡像左轉：內側換到左邊
    local q = F.begin(corner(false), 85, 4, vp)
    while not F.stepBuild(q, 4096) do end
    checkEq(q.filletN, 1, "左轉 90.9° 同樣建弧")
    local arcJ
    for i = 1, q.n - 1 do
        if q.segKind[i] == MDADDynamics.SEG_ARC then arcJ = arcJ or i end
    end
    checkNear(q.laneRoomR[arcJ], bandOut, 1e-9, "左轉弧段右（外側）餘裕＝較窄帶")
    checkTrue(q.laneRoomL[arcJ] < 0.5, "左轉弧段左（內側）餘裕＝圓角吃剩")
    checkNear(F.laneBiasAt(q, 1.5, arcJ), bandOut - keep, 1e-9, "左轉弧段 +1.5 夾到外側餘裕 1.2−keep")

    -- v3（無路寬）路線不建表、不夾
    local v3 = F.begin({ pts = { 0, 60, 0, 0, 108, 1.78 } }, 85, 3, vp)
    while not F.stepBuild(v3, 4096) do end
    checkTrue(v3.laneRoomR == nil, "v3 路線無 laneRoom 表")
    checkNear(F.laneBiasAt(v3, 1.5, 1), 1.5, 1e-9, "v3 路線偏置原值")

    -- 違規證明：120° 仍保留折點（FILLET_MAX_RAD 只放過量化噪音）
    local sharp = F.begin({
        pts = { 0, 0, 40, 0, 20, 34.64 },
        segSurface = { "paved", "paved" }, segWidth = { 20, 20 },
    }, 85, 4, { valid = true, geometryValid = true, halfW = 1, rMin = 2,
        wheelbase = 2.5, delta0Safe = 0.7, deltaVSafe = 0.25, maxSpeed = 120 })
    while not F.stepBuild(sharp, 4096) do end
    checkEq(sharp.filletN, 0, "120° 急折仍保留折點")
end

-- =====================================================================
-- 前視窗曲率收縮（2026-09-03 s015：弧建好了仍在弧前 10m 提前右打切內）
-- =====================================================================
scenario("前視窗內有急彎就縮前視：直路接近段不提前切內、前右角遠離路口內側圍籬")
do
    local vp = {
        valid = true, geometryValid = true, halfW = 0.9, rMin = 4.32,
        wheelbase = 3.79, delta0Safe = 0.72, deltaVSafe = 0.24, maxSpeed = 85,
    }
    local p = F.begin({
        pts = { 0, 60, 0, 0, 108, 1.78 },
        segSurface = { "paved", "paved" }, segWidth = { 6, 5 },
    }, 85, 4, vp)
    while not F.stepBuild(p, 4096) do end
    checkEq(p.filletFallbackN, 0, "fixture 的路口有弧")
    p.lookScale = 1.5  -- F350 的 lookScale（玩家 header）
    -- 自行車模型（同情境十）：轉向對應曲率；rMin 取 4.0
    local KAPPA_MAX = 1 / 4.0
    local st = F.newState()
    F.setLaneBias(st, 1.5)
    F.setRuntimeLimits(st, 3, 8, 9, 0.6)
    local x, y, h, spd = 1.5, 55, -math.pi / 2, 20
    local arcStartY = 4.9  -- 弧入口 tangent 點（r 4.83 × tan(45.5°)）
    local maxXApproach, minCorner, steps = -1e9, 1e9, 0
    while steps < 3000 do
        local steer, tspd, _, reached = F.control(p, st, x, y, h, spd, DT)
        if reached or x > 30 then break end
        spd = tspd
        local ms = spd / KMH
        h = h + ms * (steer / F.STEER_MAX) * KAPPA_MAX * DT
        x = x + math.cos(h) * ms * DT
        y = y + math.sin(h) * ms * DT
        steps = steps + 1
        if y > arcStartY and x > maxXApproach then maxXApproach = x end
        -- 前右角到路口內側圍籬角（實機 (10645.5,10072.5) 相對路口＝(4.5, 4.0)）
        local fx, fy = x + 2.9 * math.cos(h), y + 2.9 * math.sin(h)
        local cx, cy = fx - 0.9 * math.sin(h), fy + 0.9 * math.cos(h)
        local dc = math.sqrt((cx - 4.5) ^ 2 + (cy - 4.0) ^ 2)
        if dc < minCorner then minCorner = dc end
    end
    checkTrue(steps > 200 and x > 20, "模擬跑過路口（步數 " .. steps .. "）")
    checkTrue(maxXApproach <= 1.55,
        "直路接近段不提前切內：橫向 ≤ 車道 1.5（實得 " .. string.format("%.2f", maxXApproach) .. "）")
    checkTrue(minCorner >= 2.0,
        "前右角離路口內側圍籬角 ≥ 2m（實得 " .. string.format("%.2f", minCorner) .. "）")
end

scenario("貼縫切線追蹤（trackTangent）：誤差對承諾線切線而非前視點、閉環落後與出口切內較現制小")
do
    -- 2026-09-04 s006/s018/s021/s030：cap 5-10 的貼縫承諾，進入段 4-6m、側移 1.5-4m，
    -- pure pursuit 的前視點（≥6m）比進入段長：車頭一超過「到前視點的弦角」PID 就喊轉回，
    -- 與 cross-track 抵消，落後 0.25-1.3m 撞障礙。trackTangent＝誤差改對線在車前
    -- TANGENT_PREVIEW_M 的切線（Stanley 型），只在 ov 線覆蓋範圍內生效。
    local a, b, c, d, dl = 12, 18, 30, 36, -4
    local st = F.newState()
    checkTrue(exactOffset(st, a, b, c, d, dl), "承諾線建好")
    -- (1) 開環：車在 a 前 1m、車頭沿路——前視點看到 6m 外的側偏，切線 1.5m 處只是入口斜率
    local _, _, _, _, errPP = F.control(pLine, st, a - 1, 0, 0, 10, DT)
    st.trackTangent = true
    local _, _, _, _, errTan = F.control(pLine, st, a - 1, 0, 0, 10, DT)
    -- 前視點：7.2m 外、側偏 −4 → atan(4/7.2)≈−0.51；切線：ov 段 [12,13] 與 [13,14] 按段內比例 0.5 混合
    local function laneS(sx) local t = (sx - a) / (b - a); t = t * t * (3 - 2 * t); return dl * t end
    local slope = 0.5 * (laneS(13) - laneS(12)) + 0.5 * (laneS(14) - laneS(13))
    checkNear(errPP, -math.atan(4 / 7.2), 0.05, "現制：誤差＝到前視點的弦角（實得 " .. string.format("%.3f", errPP) .. "）")
    checkNear(errTan, math.atan(slope), 1e-3,
        "切線：誤差＝線在車前 1.5m 的切線角（混合相鄰段）（實得 " .. string.format("%.3f", errTan) .. "）")
    -- 線外（ov 範圍前）不生效：與現制同值
    st.trackTangent = false
    local _, _, _, _, e0 = F.control(pLine, st, 2, 0, 0, 10, DT)
    st.trackTangent = true
    local _, _, _, _, e1 = F.control(pLine, st, 2, 0, 0, 10, DT)
    checkNear(e1, e0, 1e-9, "ov 線範圍外照舊走前視點")
    -- (2) 閉環：自行車＋一階 yaw 延遲、Driver 同式 cross-track ×3；量進入段峰值／到 b 的落後／出口前切內
    local D = MDADDynamics
    local KPS, KMAX, TAU = 0.16, 1 / 2.92, 0.35 -- s018 實測 steer 0.44 → κ≈0.07
    local function laneAt(sx)
        if sx <= a then return 0 elseif sx >= b then return dl end
        local t = (sx - a) / (b - a); t = t * t * (3 - 2 * t); return dl * t
    end
    local function run(tangent, speed, gain)
        speed, gain = speed or 10, gain or D.CROSS_TRACK_DODGE_GAIN
        local s2 = F.newState()
        assert(exactOffset(s2, a, b, c, d, dl))
        s2.trackTangent = tangent
        local car = { x = 0, y = 0, h = 0, w = 0 }
        local prevLat, peak, atB, exitIn = nil, 0, nil, 0
        local steps = 0
        while car.x < d and steps < 5000 do
            steps = steps + 1
            local steer, _, _, _, _, _, _, lineLat = F.control(pLine, s2, car.x, car.y, car.h, speed, DT)
            local latDev = car.y - (lineLat or laneAt(car.x))
            local dLat = prevLat and (latDev - prevLat) / DT or nil
            prevLat = latDev
            local u = steer - D.crossTrackSteer(latDev, speed, dLat, gain,
                gain == 1 and 0.77 or D.CROSS_TRACK_DODGE_MAX)
            if u > F.STEER_MAX then u = F.STEER_MAX elseif u < -F.STEER_MAX then u = -F.STEER_MAX end
            local k = u * KPS
            if k > KMAX then k = KMAX elseif k < -KMAX then k = -KMAX end
            local v = speed / KMH
            car.w = car.w + (k * v - car.w) * (DT / TAU)
            car.h = car.h + car.w * DT
            car.x = car.x + math.cos(car.h) * v * DT
            car.y = car.y + math.sin(car.h) * v * DT
            local lag = math.abs(latDev)
            if car.x >= a and car.x <= b and lag > peak then peak = lag end
            if atB == nil and car.x >= b then atB = lag end
            if car.x >= c - 3 and car.x <= c and latDev * dl < 0 and lag > exitIn then exitIn = lag end
        end
        return peak, atB or 99, exitIn
    end
    -- (3) 第 8 回傳 lineLat＝ov 線在投影點的橫向：停留式線（returnLane 模式，換道從 s0 就開始）
    --     與 a..b smoothstep 的期望線不同——Driver 的 cross-track 要跟線本身
    do
        local s3 = F.newState()
        local ox, oy = {}, {}
        local n3, s03, why3, s13 = F.buildOffsetLine(pLine, 0, a, b, c, d, dl, 0, ox, oy, 0, dl, b)
        checkEq(why3, "ok", "停留式線建好")
        checkTrue(F.setOffset(s3, a, b, c, d, dl, ox, oy, n3, s03, s13), "停留式線 setOffset")
        local _, _, _, _, _, _, _, ll = F.control(pLine, s3, 9, 0, 0, 10, DT)
        local t2 = 9 / b; t2 = t2 * t2 * (3 - 2 * t2)
        checkNear(ll, dl * t2, 0.05, "lineLat：s=9（a 之前）已隨 s0→b 的換道走到 " .. string.format("%.2f", dl * t2))
        local _, _, _, _, _, _, _, ll2 = F.control(pLine, st, 9, 0, 0, 10, DT)
        checkNear(ll2, 0, 1e-6, "一般繞行線：a 之前 lineLat＝bias 0")
        local _, _, _, _, _, _, _, ll3 = F.control(pLine, st, c - 1, dl, 0, 10, DT)
        checkNear(ll3, dl, 0.02, "一般繞行線：並行段 lineLat＝offL")
        local s4 = F.newState()
        local _, _, _, _, _, _, _, ll4 = F.control(pLine, s4, 9, 0, 0, 10, DT)
        checkNil(ll4, "無承諾線：lineLat 為 nil")
    end
    -- (4) 路口內側偏的 ov 線在彎頂有折點：前視窗內路線轉角 >15° 交回前視點（誤差與不追切線同值）
    do
        local pC = buildRoute({ 0, 0, 30, 0, 30, 30, 30, 60 }, MAXV)
        local sc = F.newState()
        local ox, oy = {}, {}
        local nC, s0C, whyC, s1C = F.buildOffsetLine(pC, 0, 10, 20, 40, 48, -3, 0, ox, oy)
        checkEq(whyC, "ok", "轉角承諾線建好")
        checkTrue(F.setOffset(sc, 10, 20, 40, 48, -3, ox, oy, nC, s0C, s1C), "轉角線 setOffset")
        local _, _, _, _, ePP = F.control(pC, sc, 26, -1.5, 0, 10, DT)
        sc.trackTangent = true
        local _, _, _, _, eGate = F.control(pC, sc, 26, -1.5, 0, 10, DT)
        checkNear(eGate, ePP, 1e-9, "彎前 4m（前視窗含 90° 折點）：不追切線，誤差＝前視點")
        checkFalse(sc.tangentOn, "彎前 tangentOn=false")
        local _, _, _, _, eStr = F.control(pC, sc, 12, -0.3, 0, 10, DT)
        checkTrue(sc.tangentOn == true, "直段（彎在前視窗外）：追切線")
    end
    local pkA, bA, exA = run(false)
    local pkT, bT, exT = run(true)
    checkTrue(pkT < pkA * 0.75,
        string.format("進入段峰值落後較現制少 25%%+（%.2f → %.2f）", pkA, pkT))
    checkTrue(bT < bA * 0.75,
        string.format("到 b 的落後較現制少 25%%+（%.2f → %.2f）", bA, bT))
    checkTrue(exT < exA * 0.5 and exT < 0.25,
        string.format("出口前切內（前視點提前看到回線）較現制少一半且 <0.25（%.2f → %.2f）", exA, exT))
    checkTrue(pkT < 0.8 and bT < 0.6,
        string.format("6m 塞 4m 側移／10 km/h：峰值 <0.8、到 b <0.6（%.2f／%.2f）", pkT, bT))
    -- 長前視已超出線尾，但切線預視點仍在保持段：不能提前朝常駐線轉回。
    local oldLook = pLine.lookScale
    pLine.lookScale = 1.5
    local tailState = F.newState()
    assert(exactOffset(tailState, a, b, c, d, dl))
    tailState.trackTangent = true
    local _, _, _, _, tailErr = F.control(pLine, tailState, c - 3, dl, 0, 20, DT)
    checkNear(tailErr, 0, 1e-9, "長前視超出線尾，車仍沿保持段切線直行")
    -- 0909a 救護車旁：普通繞行沒開切線，長車在縫口落後1.46m；不靠加大位置環。
    a, b, c, d, dl = 1, 14.55, 26.55, 32.55, -3.16
    KPS, KMAX = 0.10, 1 / 4.3212
    local _, normalB, normalExit = run(false, 20, 1)
    local _, tangentB, tangentExit = run(true, 20, 1)
    checkTrue(tangentB < 0.5 and tangentB < normalB * 0.6,
        string.format("普通長車換道到縫口落後低於0.5m（%.2f→%.2f）", normalB, tangentB))
    checkTrue(tangentExit < 0.2 and tangentExit < normalExit * 0.5,
        string.format("普通長車不提前切回障礙側（%.2f→%.2f）", normalExit, tangentExit))
    pLine.lookScale = oldLook
end

-- =====================================================================
-- 情境二十四：行車風格（0906c）——省略＝brisk 逐位元不變；comfort 全線 ≤ brisk；
-- 90° 彎頂＝sqrt(2.5/κ)、≥55° 折點帽 30 km/h、彎前 coast 0.45 包絡、計畫制動 3.0
-- =====================================================================
scenario("行車風格：brisk 省略等價、comfort 全線不快於 brisk、彎頂／折點／滑行／制動各自換檔")
do
    local function buildStyle(pts, style)
        local p = F.begin(mkRoute(pts), MAXV, nil, nil, style)
        while not p.ready do F.stepBuild(p, 4096) end
        return p
    end
    local corner = { 0, 0, 8, 0, 16, 0, 24, 0, 24, 8, 24, 16, 24, 24 }
    local pB0 = buildStyle(corner, nil)
    local pB1 = buildStyle(corner, F.STYLES.brisk)
    local pC = buildStyle(corner, F.STYLES.comfort)
    local same = true
    for i = 1, pB0.n do
        if pB0.v[i] ~= pB1.v[i] or pB0.curveV[i] ~= pB1.curveV[i] then same = false end
    end
    checkTrue(same, "style 省略＝STYLES.brisk 逐位元相同")
    checkEq(pB0.styleName, "brisk", "省略時 styleName=brisk")
    checkEq(pC.styleName, "comfort", "comfort profile 記 styleName")
    local notFaster = true
    for i = 1, pC.n do
        if pC.v[i] > pB1.v[i] + 1e-9 then notFaster = false end
    end
    checkTrue(notFaster, "comfort 每一點目標速度 ≤ brisk")
    local k90 = 2 * 64 / (8 * 8 * math.sqrt(8 * 8 + 8 * 8))
    -- comfort lat 2.5：三點外接圓 3.76 vs 幾何式 3.66（0907f）→ 幾何式勝出；brisk 9：7.71 > 7.135 外接圓仍勝
    local inv2s90 = 1 / (2 * math.sin(math.rad(45)))
    local bC, cC = 2.5 * 0.432 * inv2s90, 2.5 * 6 * inv2s90
    checkNear(pC.v[4], (bC + math.sqrt(bC * bC + 4 * cC)) * 0.5, 1e-9, "comfort 直角彎頂＝前視弦幾何 3.66（低於 sqrt(2.5/κ) 3.76）")
    checkNear(pB1.v[4], math.sqrt(9.0 / k90), 1e-9, "brisk 直角彎頂仍＝sqrt(9/κ)（幾何式 7.71 較高不綁）")
    checkNear(pC.v[3], math.sqrt(pC.v[4] * pC.v[4] + 2 * 0.45 * 8), 1e-9,
        "comfort 彎前用 0.45 滑行包絡（更早收油）")
    checkNear(pC.v[6], math.sqrt(2 * 3.0 * 8), 1e-9, "comfort 終點前一點＝計畫制動 3.0 的包絡")
    checkNear(pB1.v[6], math.sqrt(2 * 8 * 8), 1e-9, "brisk 終點前一點仍＝BRAKE 8")
    checkTrue(maxDecelDemand(pC) <= 3.0 + 1e-6, "comfort 全線減速需求 ≤ 3.0 m/s²")
    checkEq(pC.styleLat, 2.5, "profile 曝露 styleLat 供 configureFollower 當天花板")
    checkEq(pC.styleBrake, 3.0, "profile 曝露 styleBrake")
    checkEq(pC.styleCoast, 0.45, "profile 曝露 styleCoast")
    -- 60° 折點（≥ comfort turnHard 50°、≥ brisk turnHard 55°）：兩檔各自的折點帽
    local sharp = { 0, 0, 20, 0, 40, 0, 60, 0, 60 + 20 * math.cos(math.rad(60)), 20 * math.sin(math.rad(60)),
        60 + 40 * math.cos(math.rad(60)), 40 * math.sin(math.rad(60)), 60 + 60 * math.cos(math.rad(60)), 60 * math.sin(math.rad(60)) }
    local pSB = buildStyle(sharp, F.STYLES.brisk)
    local pSC = buildStyle(sharp, F.STYLES.comfort)
    checkTrue(pSB.curveV[4] * KMH <= 50 + 1e-9 and pSB.curveV[4] * KMH > 30 + 1e-9,
        string.format("brisk 60° 折點：幾何式 34.4 在角度帽 50 之下（實得 %.1f）", pSB.curveV[4] * KMH))
    checkTrue(pSC.curveV[4] * KMH <= 30 + 1e-9,
        string.format("comfort 60° 折點帽 30 km/h（實得 %.1f）", pSC.curveV[4] * KMH))
end

-- =====================================================================
-- 情境二十五：弧段切線追蹤（0907b）——v4 圓角上誤差對「剖面在車前 1.5m 的切線」、
-- 直路遠離弧照舊前視點、弧前 1.5m 外不提前轉入；閉環切內（含 Driver 同式弧段 ×2 位置環）
-- =====================================================================
scenario("弧段切線追蹤＋自適應前饋：SEG_ARC 上 tangentOn、直路不動、弧前不提前轉入、閉環切內／切外")
do
    -- 2026-09-07 session-058 t=14.6-17.8：R≈12 左彎、12-26 km/h，pure pursuit 對弧上前視點的弦角
    -- 一路切內 lat +1.1 → −1.7 撞路燈。離線閉環（temp/exp_arc_tracking.lua，plant 由 session-058
    -- 反推 KPS 0.4／TAU 0.35）：0907a 切內 1.66m → 追切線 0.63 → 再加弧段 cross-track ×2 0.46。
    local D = MDADDynamics
    local R = 12
    local w = 2 * (R * (1 - math.cos(math.pi / 4)) + 0.656 + 0.4) -- band 剛好塞 R
    local route = { pts = { 0, -40, 0, 0, 40, 0 }, segSurface = { "paved", "paved" }, segWidth = { w, w } }
    local vp = { valid = true, geometryValid = true, halfW = 0.656, rMin = 2.26, wheelbase = 1.985,
        delta0Safe = 0.72, deltaVSafe = 0.24, maxSpeed = 120 }
    local p = F.begin(route, 120, 4, vp)
    while not p.ready do F.stepBuild(p, 4096) end
    local arcI, arcE
    for i = 1, p.n - 1 do if p.segKind[i] == D.SEG_ARC then arcI = arcI or i; arcE = i end end
    checkTrue(arcI ~= nil, "有弧段")
    checkTrue(p.filletRadius[arcI] > 10 and p.filletRadius[arcI] < 13,
        string.format("圓角半徑 ≈ 12（實得 %.1f）", p.filletRadius[arcI]))
    local function wrap(a)
        while a > math.pi do a = a - 2 * math.pi end
        while a < -math.pi do a = a + 2 * math.pi end
        return a
    end
    local function segAt(sq)
        local qi = 1
        while qi < p.n - 1 and p.s[qi + 1] < sq do qi = qi + 1 end
        return qi
    end
    -- (1) 弧中：車在弧段中點、車頭＝該段朝向；誤差＝車前 1.5m 那段的切線與車頭夾角
    local mid = math.floor((arcI + arcE) / 2)
    local st = F.newState()
    st.idx = mid
    local mx, my = (p.x[mid] + p.x[mid + 1]) * 0.5, (p.y[mid] + p.y[mid + 1]) * 0.5
    local _, _, rem, _, eArc = F.control(p, st, mx, my, p.segH[mid], 20, DT)
    checkTrue(st.tangentOn == true, "弧段上 tangentOn=true")
    local sMid = p.length - rem
    local qi = segAt(sMid + F.TANGENT_PREVIEW_M)
    checkTrue(p.segKind[qi] == D.SEG_ARC, "預視點仍在弧上")
    checkNear(eArc, wrap(p.segH[qi] - p.segH[mid]), 1e-6, "弧上誤差＝車前 1.5m 切線與車頭夾角")
    checkTrue(eArc ~= 0, "切線角非零（弧上每段有轉角）")
    -- (2) 直路遠離弧（前視窗 7.2m 碰不到弧）：tangentOn=false、誤差＝前視點（車頭略偏時非零）
    local sFar = p.s[arcI] - 12
    local st2 = F.newState()
    st2.idx = segAt(sFar)
    local _, _, _, _, eFar = F.control(p, st2, 0, -40 + sFar, math.pi / 2 + 0.05, 10, DT)
    checkFalse(st2.tangentOn, "直路遠離弧：不追切線")
    checkNear(eFar, -0.05, 1e-6, "直路：誤差＝前視點（車頭偏 0.05 → −0.05）")
    -- (3) 弧前 5m（前視窗已伸進弧、車前 1.5m 仍是直路）：追切線且誤差＝0，不提前轉入；
    --     舊制前視點在弧上 → 誤差 >0 ＝直路上就開始切內（s015／s058 同根）
    local sNear = p.s[arcI] - 5
    local st3 = F.newState()
    st3.idx = segAt(sNear)
    local _, _, _, _, eNear = F.control(p, st3, 0, -40 + sNear, math.pi / 2, 10, DT)
    checkTrue(st3.tangentOn == true, "弧前 5m（前視段在弧上）：追切線")
    checkNear(eNear, 0, 1e-9, "弧前 5m：誤差 0（車前 1.5m 仍是直路，不提前轉入）")
    -- (4) 弧段前饋（0908a）：弧上 ffSteer 與轉向同號、直路 0、弧前 LEAD 秒外 0
    do
        local st4 = F.newState()
        st4.idx = mid
        F.control(p, st4, mx, my, p.segH[mid], 20, DT)
        local dthArc = wrap(p.segH[mid + 1] - p.segH[mid])
        checkTrue((st4.ffSteer or 0) * dthArc > 0, string.format("弧上前饋與轉向同號（ff %.2f、dθ %.3f）", st4.ffSteer or 0, dthArc))
        checkTrue(math.abs(st4.ffSteer) > 0.05, "弧上前饋非零")
        local weak = F.newState()
        weak.idx, weak.yawGain = mid, 0.2
        F.control(p, weak, mx, my, p.segH[mid], 30, DT)
        checkTrue(math.abs(weak.ffSteer) <= 0.8 + 1e-9,
            "低 yaw 反應不可把前饋放大成整車橫推")
        local slow = F.newState()
        slow.idx, slow.yawGain = mid, 3
        F.control(p, slow, mx, my, p.segH[mid], 2, DT)
        checkTrue(slow.ffSteer * dthArc >= 0,
            "低速弧段的前饋不可因扣除切線項而反打")
        checkNear(st2.ffSteer or 0, 0, 1e-9, "直路遠離弧：前饋 0")
        local st5 = F.newState()
        st5.idx = segAt(p.s[arcI] - 5)
        F.control(p, st5, 0, -40 + p.s[arcI] - 5, math.pi / 2, 10, DT)
        checkNear(st5.ffSteer or 0, 0, 1e-9, "弧前 5m、10 km/h（LEAD 0.35s＝1m）：前饋尚未爬升")
        -- 弧前 2m、25 km/h（LEAD 2.4m 內）：已爬升且 κ 用弧真半徑（kap[firstArc] 是直臂＋第一 chord 的
        -- 三點曲率，只有 1/R 的百分之一；Codex lane 2026-09-08 抓的）
        local st6 = F.newState()
        st6.idx = segAt(p.s[arcI] - 2)
        F.control(p, st6, 0, -40 + p.s[arcI] - 2, math.pi / 2, 25, DT)
        checkTrue(math.abs(st6.ffSteer or 0) > 0.03, string.format("弧前 2m、25 km/h：前饋已爬升（實得 %.3f）", st6.ffSteer or 0))
        -- Codex lane 反例：近共線右彎出口（最後 chord 對出口切線殘差 −0.006 反號）——整條弧每個 chord 的前饋同號
        local pts2 = { 0, 0, 40, 0, 40, 1, 40.1, 10, 40.2, 20, 40.3, 40 }
        local r2 = { pts = pts2, segSurface = {}, segWidth = {} }
        for i = 1, 5 do r2.segSurface[i], r2.segWidth[i] = "paved", 9.14 end
        local p2 = F.begin(r2, 120, 4, vp)
        while not p2.ready do F.stepBuild(p2, 4096) end
        local sign, allSame, arcN = nil, true, 0
        for i = 1, p2.n - 1 do
            if p2.segKind[i] == D.SEG_ARC then
                arcN = arcN + 1
                local st7 = F.newState()
                st7.idx = i
                F.control(p2, st7, (p2.x[i] + p2.x[i + 1]) * 0.5, (p2.y[i] + p2.y[i + 1]) * 0.5, p2.segH[i], 20, DT)
                local f = st7.ffSteer or 0
                if sign == nil then sign = f > 0 and 1 or -1 end
                if f * sign <= 0.01 then allSame = false end
            end
        end
        checkTrue(arcN > 10 and allSame, "近共線出口右彎：弧上每個 chord（含最後一個）前饋同號")
        -- Codex lane 反例二：入臂由 20 段 ≤2° 微彎組成（fillet 視為共線臂吞點，入弧前的線段殘留 1.4 rad 折角），
        -- 第一個 chord 的 prev 轉角 −1.40 反號、next +0.035——「取量級較大者」會在第一個 chord 反打；
        -- 方向權威＝同一弧內相鄰 chord（k−1 是弧用 prev，否則用 next）
        local pts3 = {}
        local segs = {}
        for i = 0, 19 do segs[#segs + 1] = math.rad(i * 1.9) end
        local bx, by = 40, 0
        local back = {}
        for i = 1, 20 do
            bx = bx - math.cos(segs[i]); by = by - math.sin(segs[i])
            back[#back + 1] = { bx, by }
        end
        bx = bx - 20 * math.cos(segs[20]); by = by - 20 * math.sin(segs[20])
        pts3[#pts3 + 1] = bx; pts3[#pts3 + 1] = by
        for i = 20, 1, -1 do pts3[#pts3 + 1] = back[i][1]; pts3[#pts3 + 1] = back[i][2] end
        pts3[#pts3 + 1] = 40; pts3[#pts3 + 1] = 0
        pts3[#pts3 + 1] = 40; pts3[#pts3 + 1] = 40
        local r3 = { pts = pts3, segSurface = {}, segWidth = {} }
        for i = 1, #pts3 / 2 - 1 do r3.segSurface[i], r3.segWidth[i] = "paved", w end
        local p3 = F.begin(r3, 120, 4, vp)
        while not p3.ready do F.stepBuild(p3, 4096) end
        local sign3, same3, arcN3, firstArc3 = nil, true, 0, nil
        for i = 1, p3.n - 1 do
            if p3.segKind[i] == D.SEG_ARC then
                arcN3 = arcN3 + 1
                firstArc3 = firstArc3 or i
                local st8 = F.newState()
                st8.idx = i
                F.control(p3, st8, (p3.x[i] + p3.x[i + 1]) * 0.5, (p3.y[i] + p3.y[i + 1]) * 0.5, p3.segH[i], 20, DT)
                local f = st8.ffSteer or 0
                if sign3 == nil then sign3 = f > 0 and 1 or -1 end
                if f * sign3 <= 0.01 then same3 = false end
            end
        end
        checkTrue(firstArc3 ~= nil and math.abs(wrap(p3.segH[firstArc3] - p3.segH[firstArc3 - 1])) > 0.5,
            "微彎入臂：第一個 chord 的 prev 轉角是吞點殘留的大折角（fixture 前提）")
        checkTrue(arcN3 > 10 and same3, "微彎入臂：弧上每個 chord（含第一個）前饋同號")
    end
    -- (5) 閉環：自行車＋一階 yaw 延遲、Driver 同式 cross-track（curveHardActive 時 ×CROSS_TRACK_ARC_GAIN）、
    --     Driver 轉向死區 0.02 與 dLat 台階守門（Codex lane 2026-09-07：切線降低 steer 量級，死區這道非線性要進 plant）。
    --     plant 增益 KPS（κ／單位 steer）由 2026-09-08 十三場 telemetry 反推：RaceCar／救護車 24 km/h 0.16-0.21、
    --     F350 0.10-0.12（舊 0.4 是 session-058 低速反推，比實車高兩三倍——那個 plant 下切線預視的隱含前饋
    --     就夠，實車上只有需求 yaw 率的 30-60%＝四台車同一個彎全撞外側）。
    --     25 km/h 過 R≈12 左彎：K0.18（RaceCar）切內／切外都 <0.3；K0.10（F350）切外 <0.6（無前饋 1.57）。
    local function closedLoop(KPS, ffOn)
        local KMAX, TAU = 1 / 2.5, 0.35
        local dt = 1 / 30
        local kmh = 25
        local sc = F.newState()
        F.setLaneBias(sc, 1.0)
        F.setRuntimeLimits(sc, 3, 6, 3.5, 1.2)
        local car = { x = -1.0, y = -40, h = math.pi / 2, w = 0 }
        local v = kmh / KMH
        local prevLat, cutIn, cutOut = nil, 0, 0
        local sExit = p.s[arcE + 1]
        local steps = 0
        while steps < 3000 do
            steps = steps + 1
            local steer, _, rem2, reached, _, _, latSigned = F.control(p, sc, car.x, car.y, car.h, kmh, dt)
            if not ffOn then steer = steer - (sc.ffSteer or 0) end
            local sNow = p.length - rem2
            local latDev = latSigned - F.laneBiasAt(p, 1.0, sc.idx)
            local dLat = prevLat and (latDev - prevLat) / dt or nil
            prevLat = latDev
            if dLat and (dLat > 5 or dLat < -5) then dLat = nil end -- Driver TUNE.CROSS_TRACK_DLAT_MAX（期望線台階不進 D 項）
            local xg, xm = nil, nil
            if sc.curveHardActive then xg, xm = D.CROSS_TRACK_ARC_GAIN, D.CROSS_TRACK_ARC_MAX end
            local u = steer - D.crossTrackSteer(latDev, kmh, dLat, xg, xm)
            if u > 5 then u = 5 elseif u < -5 then u = -5 end
            if u < 0.02 and u > -0.02 then u = 0 end -- Driver STEER_DEADZONE：低於 0.02 不施力（0907e）
            sc.appliedSteer = u -- Driver applySteering 回寫（yaw 增益估計的分母）
            local k = u * KPS
            if k > KMAX then k = KMAX elseif k < -KMAX then k = -KMAX end
            car.w = car.w + (k * v - car.w) * (dt / TAU)
            car.h = car.h + car.w * dt
            car.x = car.x + math.cos(car.h) * v * dt
            car.y = car.y + math.sin(car.h) * v * dt
            if sNow >= p.s[arcI] - 2 and sNow <= sExit + 4 then
                -- 這條彎的內側是負 lane（右正）：latDev 負＝切內；出弧後 4m 內也算（帶 yaw 率衝進直路）
                if -latDev > cutIn then cutIn = -latDev end
                if latDev > cutOut then cutOut = latDev end
            end
            if reached or sNow > p.length - 3 then break end
        end
        return cutIn, cutOut, sc.yawGain
    end
    local inR, outR, gainR = closedLoop(0.18, true)
    checkTrue(inR < 0.3, string.format("K0.18 25 km/h 過 R≈12 弧：最大切內 <0.3m（實得 %.2f）", inR))
    checkTrue(outR < 0.3, string.format("K0.18 弧段切外 <0.3m（實得 %.2f）", outR))
    checkTrue(math.abs(gainR - 0.18 * 25 / KMH) < 0.35,
        string.format("yaw 增益估計收斂到 plant（K·v＝%.2f，實得 %.2f）", 0.18 * 25 / KMH, gainR))
    local inH, outH = closedLoop(0.10, true)
    local _, outH0 = closedLoop(0.10, false)
    checkTrue(outH < 0.6, string.format("K0.10（重車）弧段切外 <0.6m（實得 %.2f；無前饋 %.2f）", outH, outH0))
    checkTrue(outH < outH0 * 0.5, string.format("前饋把重車切外至少砍半（%.2f → %.2f）", outH0, outH))
    checkTrue(inH < 0.3, string.format("K0.10 切內 <0.3m（實得 %.2f）", inH))
end

-- =====================================================================
-- 情境二十六：髮夾折點（0907c）——90°<θ<150° 非弧頂點前視目標鉗在折點、車距折點 < rMin·tan(θ/2)（理想圓角切點距）才放行；
-- 閉環過 121° 折點不在折點前切內；餘裕表不動
-- =====================================================================
scenario("髮夾折點：前視目標不越過折點、閉環 121° 折點前不切內")
do
    -- 2026-09-07 session-060：4m 路東行 → 121° 右轉進 8m 路，路緣圍籬柱在折點前 4.5m／內側 2.5m；
    -- 前視 4.5m 在折點前就朝另一臂轉＝內側切 1.6m 撞柱（lat −0.6 → +1.6）、倒車兩次 StopStuck。
    local D = MDADDynamics
    local ang = math.rad(121)
    local ax, ay = 60, 0
    local route = { pts = { 0, 0, ax, ay, ax + 30 * math.cos(ang), ay + 30 * math.sin(ang) },
        segSurface = { "paved", "paved" }, segWidth = { 4, 8 } }
    local vp = { valid = true, geometryValid = true, halfW = 0.656, rMin = 2.26, wheelbase = 1.985,
        delta0Safe = 0.72, deltaVSafe = 0.24, maxSpeed = 120 }
    local p = F.begin(route, 120, 4, vp)
    while not p.ready do F.stepBuild(p, 4096) end
    checkEq(p.filletFallbackN, 1, "121° 折點不做圓角＝fallback 保留頂點")
    -- 折點頂點索引
    local kink = nil
    for i = 2, p.n - 1 do
        local d = math.abs(p.segH[i] - p.segH[i - 1])
        if d > math.pi then d = 2 * math.pi - d end
        if d > math.rad(100) then kink = i end
    end
    checkTrue(kink ~= nil, "找到 121° 折點頂點")
    local sK = p.s[kink]
    checkNear(sK, 60, 1e-6, "折點弧長＝60")
    -- (1) 餘裕表不動：折點鄰域的偏置不歸零（逐段表會把整條 60m 直臂的靠右吃掉；內側路緣物交給繞行）
    local function segAt(sq)
        local qi = 1
        while qi < p.n - 1 and p.s[qi + 1] < sq do qi = qi + 1 end
        return qi
    end
    checkTrue(p.laneRoomR[segAt(sK - 3)] > 0.9, "折點前 3m：4m 路餘裕照舊（實得 "
        .. tostring(p.laneRoomR[segAt(sK - 3)]) .. "）")
    -- (2) 折點前 5m、車頭沿臂：前視目標鉗在頂點 → 誤差 0（舊制目標已在另一臂＝誤差 >30°）
    local st = F.newState()
    st.idx = segAt(sK - 5)
    local _, _, _, _, e5 = F.control(p, st, ax - 5, 0, 0, 12, DT)
    checkNear(e5, 0, 1e-9, "折點前 5m：目標＝頂點、誤差 0")
    -- (3) 折點前 3m（< 放行距 rMin·tan(60.5°)＝4.0m）：目標放行到另一臂 → 誤差 >20°；
    --     折點前 0.5m → 誤差 >90°
    local st2 = F.newState()
    st2.idx = segAt(sK - 3)
    local _, _, _, _, e3 = F.control(p, st2, ax - 3, 0, 0, 12, DT)
    checkTrue(math.abs(e3) > math.rad(20), string.format("折點前 3m（切點距 4.0m 內）：目標已在另一臂、誤差 %.0f° > 20°", math.deg(math.abs(e3))))
    local st3 = F.newState()
    st3.idx = segAt(sK - 0.5)
    local _, _, _, _, e05 = F.control(p, st3, ax - 0.5, 0, 0, 12, DT)
    checkTrue(math.abs(e05) > math.rad(90), string.format("折點前 0.5m：誤差 %.0f° > 90°", math.deg(math.abs(e05))))
    -- (4) 閉環：自行車＋一階 yaw 延遲（plant 最小半徑 2.5）、12 km/h 定速、Driver 死區；
    --     折點前最後 6m 的內側偏離 <1.0m（舊制 4.5m 前視切 1.8m）、出彎臂外甩 <2.0m（鉗到 1m 會甩 4m）、
    --     離折點前 4.5m／內側 2.5m 的路緣柱（r 0.7）淨距 >0.8（舊制 0.2＝撞）、過折點後 15m 回 leg 2 ±1m
    local KPS, KMAX, TAU = 0.4, 1 / 2.5, 0.35
    local dt = 1 / 30
    local kmh = 12
    local sc = F.newState()
    local car = { x = ax - 20, y = 0, h = 0, w = 0 }
    local v = kmh / KMH
    local cutPre, steps, done, endLat = 0, 0, false, nil
    local swingOut, postClr = 0, 99
    local ux, uy = math.cos(ang), math.sin(ang)
    while steps < 4000 do
        steps = steps + 1
        local steer, _, rem, reached = F.control(p, sc, car.x, car.y, car.h, kmh, dt)
        if steer > 5 then steer = 5 elseif steer < -5 then steer = -5 end
        if steer < 0.02 and steer > -0.02 then steer = 0 end -- Driver STEER_DEADZONE（0907e）
        local k = steer * KPS
        if k > KMAX then k = KMAX elseif k < -KMAX then k = -KMAX end
        car.w = car.w + (k * v - car.w) * (dt / TAU)
        car.h = car.h + car.w * dt
        car.x = car.x + math.cos(car.h) * v * dt
        car.y = car.y + math.sin(car.h) * v * dt
        local sNow = p.length - rem
        local dPost = math.sqrt((car.x - (ax - 4.5)) ^ 2 + (car.y - 2.5) ^ 2) - 0.7 - 0.656
        if dPost < postClr then postClr = dPost end
        if sNow < sK and car.x >= ax - 6 and car.x <= ax then
            -- 左彎（+121°）內側＝+y
            if car.y > cutPre then cutPre = car.y end
        end
        if sNow >= sK then
            -- 對 leg 2 的橫向：leg 2 起點 (ax,ay)、方向 (ux,uy)，右法向 = (uy, -ux)＝左彎外側
            local rx, ry = car.x - ax, car.y - ay
            local latOut = rx * uy - ry * ux
            if latOut > swingOut then swingOut = latOut end
            if sNow >= sK + 15 then
                endLat = latOut
                done = true
                break
            end
        end
    end
    checkTrue(done, "閉環在 4000 幀內走過折點 15m（實得 done=" .. tostring(done) .. "）")
    checkTrue(cutPre < 1.0, string.format("折點前 6m 內側偏離 <1.0m（實得 %.2f）", cutPre))
    checkTrue(swingOut < 2.0, string.format("出彎臂外甩 <2.0m（實得 %.2f）", swingOut))
    checkTrue(postClr > 0.8, string.format("離折點前路緣柱淨距 >0.8m（實得 %.2f）", postClr))
    checkTrue(endLat ~= nil and math.abs(endLat) < 1.0,
        string.format("過折點 15m 已回 leg 2 中線 ±1m（實得 %s）", tostring(endLat)))
end

-- =====================================================================
-- 情境二十七：lane 落點沿弧長連續（0907c）——弧內側餘裕 0 與直段 1.0 之間 12m smoothstep，
-- proof 線（buildLaneLine）無折點；不傳 sAt 仍是逐段台階（舊語意）
-- =====================================================================
scenario("lane 落點連續：弧前 12m 收到 0、弧後放回、proof 線無折點、逐段語意不變")
do
    -- 2026-09-07 session-064 t=33-36：R 9.5 彎（curveCap 24.9）出弧前 laneCurveEnvelope 24.9→…→0、
    -- mef=curve-coast、車煞到 8 km/h——proof 線在弧邊界 1m 內橫跳 1m（bias 1 → 弧內側 0）＝折點 κ→∞。
    local D = MDADDynamics
    local R = 12
    local w = 2 * (R * (1 - math.cos(math.pi / 4)) + 0.656 + 0.4)
    local route = { pts = { 0, -40, 0, 0, 40, 0 }, segSurface = { "paved", "paved" }, segWidth = { w, w } }
    local vp = { valid = true, geometryValid = true, halfW = 0.656, rMin = 2.26, wheelbase = 1.985,
        delta0Safe = 0.72, deltaVSafe = 0.24, maxSpeed = 120 }
    local p = F.begin(route, 120, 4, vp)
    while not p.ready do F.stepBuild(p, 4096) end
    local arcI, arcE
    for i = 1, p.n - 1 do if p.segKind[i] == D.SEG_ARC then arcI = arcI or i; arcE = i end end
    local sA, sE = p.s[arcI], p.s[arcE + 1]
    -- 這條左彎（−40→0→+40，y-down 世界）內側＝負 lane：用內側 bias 才吃到餘裕 0
    local inside = (p.laneRoomL[arcI] < p.laneRoomR[arcI]) and -1 or 1
    local bias = inside * 1.0
    checkTrue(math.abs(F.laneBiasAt(p, bias, arcI + 2, sA + 2)) < 1e-9, "弧內側落點 0")
    checkNear(F.laneBiasAt(p, bias, 1, sA - 20), bias, 1e-9, "弧前 20m 落點＝bias")
    checkNear(F.laneBiasAt(p, bias, F.segIndexAt(p, sA - 6), sA - 6), bias * 0.5, 0.02, "弧前 6m（ramp 中點）＝bias/2")
    checkTrue(math.abs(F.laneBiasAt(p, bias, F.segIndexAt(p, sA - 0.5), sA - 0.5)) < 0.02, "弧前 0.5m 已收到 ≈0")
    checkNear(F.laneBiasAt(p, bias, F.segIndexAt(p, sE + 6), sE + 6), bias * 0.5, 0.02, "弧後 6m 放回 bias/2")
    -- 連續：每 0.5m 落點變化 ≤ 0.12（1m/12m smoothstep 峰值斜率 0.125）
    local maxStep, prev = 0, nil
    for sq = sA - 20, sE + 20, 0.5 do
        local v = F.laneBiasAt(p, bias, F.segIndexAt(p, sq), sq)
        if prev then local d = math.abs(v - prev); if d > maxStep then maxStep = d end end
        prev = v
    end
    checkTrue(maxStep < 0.08, string.format("落點每 0.5m 變化 <0.08（實得 %.3f）", maxStep))
    -- Codex lane 反例：階梯餘裕 1.6/1.1/0.6（bias 1、keep 0.6 → 夾值 1.0/0.5/0），s=20 段界兩側
    -- 必須同值（第一版「min 各段以本段值為基底的 ramp」在這裡 0.5 → 0.25 跳變）；全線每 0.25m 變化有界
    do
        local fake = { ready = true, n = 4, s = { 0, 20, 26, 50 }, segKind = { 0, 0, 0 },
            laneRoomR = { 1.6, 1.1, 0.6 }, laneRoomL = { 1.6, 1.1, 0.6 } }
        local lm = F.laneBiasAt(fake, 1, 1, 20 - 1e-6)
        local lp = F.laneBiasAt(fake, 1, 2, 20 + 1e-6)
        checkNear(lp, lm, 1e-4, string.format("階梯餘裕段界 s=20 兩側同值（%.4f / %.4f）", lm, lp))
        local lm2 = F.laneBiasAt(fake, 1, 2, 26 - 1e-6)
        local lp2 = F.laneBiasAt(fake, 1, 3, 26 + 1e-6)
        checkNear(lp2, lm2, 1e-4, string.format("階梯餘裕段界 s=26 兩側同值（%.4f / %.4f）", lm2, lp2))
        checkNear(F.laneBiasAt(fake, 1, 1, 2), 1, 1e-9, "遠離段界＝本段夾值 1.0")
        checkNear(F.laneBiasAt(fake, 1, 3, 40), 0, 1e-9, "餘裕 0 的段＝0")
        local mx, pv = 0, nil
        for sq = 0, 50, 0.25 do
            local vv = F.laneBiasAt(fake, 1, F.segIndexAt(fake, sq), sq)
            if pv then local dd = math.abs(vv - pv); if dd > mx then mx = dd end end
            pv = vv
        end
        checkTrue(mx < 0.05, string.format("階梯餘裕全線每 0.25m 變化 <0.05（實得 %.3f）", mx))
    end
    -- Codex lane 反例 2：0.25m 碎段（36 點直路、最後一段餘裕縮小）——逐段走訪會在 12m 窗內被上限截斷，
    -- 較緊的 run 隨車位「突然進窗」＝段界跳變；改逐 run 走訪後全線連續
    do
        local pts, ws = {}, {}
        for i = 1, 36 do pts[#pts + 1] = (i - 1) * 0.25; pts[#pts + 1] = 0 end
        for i = 1, 35 do ws[i] = 5.2 end -- band 5.2/2−0.656−0.4 = 1.544 → 夾 0.944（bias 1、keep 0.6 → 0.944）
        ws[35] = 3.2                      -- 最後一段 band 0.544 → 夾 0（keep 吃光）
        local surf = {}
        for i = 1, 35 do surf[i] = "paved" end
        local pf = F.begin({ pts = pts, segSurface = surf, segWidth = ws }, 120, 4, vp)
        while not pf.ready do F.stepBuild(pf, 4096) end
        checkTrue(pf.laneRunEnd ~= nil and pf.laneRunEnd[1] == 34 and pf.laneRunStart[35] == 35,
            "碎段 run 端點表：前 34 段同一 run、最後一段自己一 run")
        local mx2, pv2 = 0, nil
        for sq = 0, 8.75, 0.05 do
            local vv = F.laneBiasAt(pf, 1, F.segIndexAt(pf, sq), sq)
            if pv2 then local dd = math.abs(vv - pv2); if dd > mx2 then mx2 = dd end end
            pv2 = vv
        end
        checkTrue(mx2 < 0.02, string.format("0.25m 碎段全線每 0.05m 變化 <0.02（實得 %.4f）", mx2))
        checkTrue(math.abs(F.laneBiasAt(pf, 1, 35, 8.6)) < 1e-9, "碎段末段夾 0")
    end
    -- 不傳 sAt＝逐段台階（舊語意；Driver 逐段用途仍靠它）
    local stepOld = math.abs(F.laneBiasAt(p, bias, arcI - 1) - F.laneBiasAt(p, bias, arcI))
    checkTrue(stepOld > 0.9, string.format("不傳 sAt：弧邊界仍是 %.2f 的台階（舊語意）", stepOld))
    -- proof 線：buildLaneLine 逐點折角最大 < 8°（舊制弧邊界 1m 橫跳 1m ≈ 45°）
    local lx, ly = {}, {}
    local cnt, s0 = F.buildLaneLine(p, sA - 20, sE + 20, bias, lx, ly, 1)
    checkTrue(cnt > 40, "proof 線建好（點數 " .. tostring(cnt) .. "）")
    local maxTurn = 0
    for k = 2, cnt - 1 do
        local a1 = math.atan(ly[k] - ly[k - 1], lx[k] - lx[k - 1])
        local a2 = math.atan(ly[k + 1] - ly[k], lx[k + 1] - lx[k])
        local d = math.abs(a2 - a1)
        if d > math.pi then d = 2 * math.pi - d end
        if d > maxTurn then maxTurn = d end
    end
    checkTrue(maxTurn < math.rad(8), string.format("proof 線逐點折角 <8°（實得 %.1f°）", math.deg(maxTurn)))
end

scenario("急折點出彎：先收正姿態與橫偏，再解除爬行帽")
do
    local vp = { valid = true, geometryValid = true, halfW = 0.9, rMin = 4.32,
        wheelbase = 3.79, delta0Safe = 0.72, deltaVSafe = 0.24, maxSpeed = 120 }
    for _, dir in ipairs({ 1, -1 }) do
        local p = F.begin({ pts = { 0, 0, 60, 0, 60, dir * 80 },
            segSurface = { "paved", "paved" }, segWidth = { 4, 4 } }, 70, 4, vp)
        p.lookScale = 1.5
        while not p.ready do F.stepBuild(p, 4096) end
        local st = F.newState()
        F.setRuntimeLimits(st, 2.5, 6, 7, 2.25)
        F.control(p, st, 56, 0, 0, 28, DT)
        local _, atExit = F.control(p, st, 60.3, dir * 2,
            dir * (math.pi / 2 - 0.3), 28, DT)
        checkTrue(atExit <= 12, "前視點已近對準但車身仍偏 17°：不能恢復巡航")
        local straight = F.newState()
        F.setRuntimeLimits(straight, 2.5, 6, 7, 2.25)
        local _, noPoseCap = F.control(p, straight, 60.3, dir * 2, dir * math.pi / 2, 28, DT)
        checkNear(st.profileSpeedKmh, noPoseCap, 1e-9,
            "幾何設計包絡與同位置收正後一致，不吃當下姿態的12帽")
        local _, offLane = F.control(p, st, 61.2, dir * 3, dir * math.pi / 2, 12, DT)
        checkTrue(offLane <= 12, "姿態已正但仍有1.2m橫偏：維持出彎保護")
        local _, settling = F.control(p, st, 60.8, dir * 6,
            dir * (math.pi / 2 - math.rad(10)), 12, DT)
        checkTrue(settling > 12, "出彎只剩10°與0.8m修正：交回連續姿態限速，不再固定爬行")
        local _, aligned = F.control(p, st, 60, dir * 8, dir * math.pi / 2, 12, DT)
        checkTrue(aligned > 12, "同一次出彎回到行駛線：解除爬行，正常加速")
        local comfort = F.begin({ pts = {0, 0, 60, 0, 60, dir * 80},
            segSurface = {"paved", "paved"}, segWidth = {4, 4} }, 70, 4, vp, F.STYLES.comfort)
        while not comfort.ready do F.stepBuild(comfort, 4096) end
        local cs = F.newState()
        F.setRuntimeLimits(cs, 2.5, 6, 7, 2.25)
        F.control(comfort, cs, 56, 0, 0, 28, DT)
        local _, comfortExit = F.control(comfort, cs, 60.8, dir * 6,
            dir * (math.pi / 2 - math.rad(10)), 12, DT)
        checkTrue(comfortExit <= 12, "舒適風格仍等到原來的收正門檻")

        local exact = F.newState()
        F.setRuntimeLimits(exact, 2.5, 6, 7, 2.25)
        F.control(p, exact, 56, 0, 0, 28, DT)
        local lx, ly = {}, {}
        for i = 1, 60 do lx[i], ly[i] = 60.6, dir * (i - 1) end
        assert(F.setExactLine(exact, lx, ly, 60, 60, 119))
        F.control(p, exact, 60.6, dir * 10, dir * math.pi / 2, 12, DT)
        F.clearOffset(exact)
        local _, afterExact = F.control(p, exact, 60.6, dir * 10, dir * math.pi / 2, 12, DT)
        checkTrue(afterExact > 12,
            "承諾線接手並越過急折點後：回到跟線不再受舊出彎帽限制")

        local pending = F.newState()
        local px, py = {}, {}
        local pn, p0, why, p1 = F.buildOffsetLine(p, 56, 100, 108, 120, 132, -1.25,
            0, px, py, nil, nil, nil, 0.8)
        assert(pn > 0, why)
        assert(F.setOffset(pending, 100, 108, 120, 132, -1.25, px, py, pn, p0, p1))
        F.setRuntimeLimits(pending, 2.5, 6, 7, 2.25)
        F.control(p, pending, 56, 0.8, 0, 28, DT)
        local _, preA = F.control(p, pending, 60 - dir * 1.6, dir * 3,
            dir * (math.pi / 2 - 0.3), 28, DT)
        checkTrue(preA <= 12, "遠處繞行尚未進入a：不能取消近處急折點的出彎收正")
        local _, entered = F.control(p, pending, 60 - dir * 1.6, dir * 41,
            dir * math.pi / 2, 12, DT)
        checkTrue(entered > 12, "真正進入繞行段後：交給承諾線，不復活原始折點帽")
        F.resetState(pending)
        assert(F.setOffset(pending, 100, 108, 120, 132, -1.25, px, py, pn, p0, p1))
        F.control(p, pending, 56, 0.8, 0, 28, DT)
        local _, lineAligned = F.control(p, pending, 60 - dir * 0.8, dir * 10,
            dir * math.pi / 2, 12, DT)
        checkTrue(lineAligned > 12, "pre-a已收正到真正承諾線：不強迫回另一條常駐線才放行")
    end
end

scenario("快取長路線：首次從實際車位定位，不從首段追趕游標")
do
    local p = buildRoute(straight(400, 4), 60)
    local st = F.newState()
    local _, _, remaining, arrived, err = F.control(p, st, 1200, 4, 0, 20, DT)
    checkNear(remaining, 396, 1e-9, "第一次控制就使用車位對應的剩餘路長")
    checkTrue(not arrived and math.abs(err) < math.pi / 2, "向前路線不得被誤判成掉頭")
    local loop = {}
    for i = 0, 40 do loop[#loop + 1], loop[#loop + 2] = i * 4, 0 end
    loop[#loop + 1], loop[#loop + 2] = 160, 3
    for i = 39, 0, -1 do loop[#loop + 1], loop[#loop + 2] = i * 4, 3 end
    p = buildRoute(loop, 60)
    st = F.newState()
    local _, _, remainLoop, _, errLoop = F.control(p, st, 20, 1.6, 0, 20, DT)
    checkTrue(st.idx < 13 and remainLoop > 200 and math.abs(errLoop) < math.pi / 2,
        "首段仍合理近：右側車道不得因後方反向臂近0.2m就跳過整個迴圈")
end

closeScenario()
print()
print("情境 " .. scenarios .. " 個、斷言 " .. assertions .. " 項")
if failures > 0 then
    print(failures .. " 項失敗")
    os.exit(1)
end
print("全部通過")
