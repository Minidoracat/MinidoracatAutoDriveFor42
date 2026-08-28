-- MDAD_Overlay.lua — 自駕 debug 視覺化：把「車實際要走的線」與感知狀態畫進世界。
--
-- 沙盒 DebugOverlay 開啟時（管理員／單機），每輪掃描完成（250ms）重建一批
-- world markers（引擎渲染，縮放／視角自動處理，出處見下）：
--   軌跡點列  藍＝正常跟線、黃＝側偏剖面作用中（進入→保持→回歸的實際軌跡）
--   障礙紅圈  感知快照的硬障礙（世界座標；圈半徑＝逐點半徑＋車安全裕度示意）
--   路面帶綠點 路面對中統計出的帶邊界（roadLo/roadHi；nav 線歪多少一眼可見）
--
-- API 出處（家規：每個呼叫都要有原版出處）：
--   getWorldMarkers()                          用例 ISSpawnHordeUI.lua:398
--   :addGridSquareMarker(sq, r,g,b, doAlpha, size)
--                                              WorldMarkers.java:508；用例同上
--   marker:remove()                            用例 ISSpawnHordeUI.lua:406
--   cell:getGridSquare(x, y, z)                用例 ISDestroyCursor.lua:278
--
-- 效能：markers 由引擎渲染（原版 tutorial／horde UI 同機制，數十顆無感）；
-- 本模組只在「輪完成」事件（250ms）重建 ≤ 60 顆，不在每幀熱路徑。
-- 關閉開關／停止自駕即全清。

MDADOverlay = MDADOverlay or {}

local sin, cos = math.sin, math.cos

local TRAIL_AHEAD = 52      -- 軌跡取樣長度（公尺；比掃描帶 48 略長，看得到回歸段）
local TRAIL_STEP = 0.8      -- 軌跡取樣間距（< 圈直徑 ~0.76×步差 → 視覺連成一條線）
local HARD_MAX_SHOW = 24    -- 障礙圈上限（快照可能上百點，畫太多反而看不清）
local ROAD_STEP = 6         -- 路面帶邊界點間距
-- 圈的大小：2026-08-28 實機——障礙紅圈（size≈1.1）清楚可見、軌跡點 0.3 在
-- 柏油路紋理上完全隱形。小於 ~0.5 的 marker 視覺上不存在。
local TRAIL_SIZE = 0.55
local ROAD_SIZE = 0.4

local markers = {}          -- 目前掛在世界上的 marker（重建前逐顆 remove）
local markerN = 0

function MDADOverlay.clear()
    for i = 1, markerN do
        local m = markers[i]
        if m ~= nil then
            m:remove()
            markers[i] = nil
        end
    end
    markerN = 0
end

-- 內部：在世界 (wx, wy, z) 放一顆圈。square 不存在（未載入）就跳過。
-- alpha 三坑（2026-08-28 全踩過，出處都在反編譯）：
--   1. doAlpha=true＝脈動模式，alpha 從 0 以 0.006/tick 爬升（WorldMarkers.java
--      :453-476），~0.5 秒才可見——本模組每 250ms 整批重建，永遠停在隱形段。
--   2. 舊渲染管線 doAlpha=false 恆全亮（WorldMarkers.java:553）——所以傳 false。
--   3. **B42 實際走 FBO 管線**（PerformanceSettings.fboRenderChunk），它直接畫
--      m.alpha、完全無視 doAlpha（FBORenderWorldMarkers.java:75）；而 alpha
--      建構初值是 0（WorldMarkers.java:534）——必須 add 後立刻 setAlpha(1)
--      抬到全亮，否則 FBO 畫出來的圈近全透明＝「開了什麼都看不到」。
local function put(cell, wx, wy, z, r, g, b, size)
    local sq = cell:getGridSquare(wx - wx % 1, wy - wy % 1, z)
    if sq == nil then return end
    local m = getWorldMarkers():addGridSquareMarker(sq, r, g, b, false, size)
    if m ~= nil then
        m:setAlpha(1)
        markerN = markerN + 1
        markers[markerN] = m
    end
end

-- 由弧長 s 取剖面上的實際行駛點（含 laneBias 與側偏剖面 smoothstep——
-- 與 MDADFollower.control 的前視點公式同一套；fstate 欄位是 follower 的
-- 公開狀態：laneBias／offA..offD／offL）。
-- 內部：弧長 s 的中心線點與段朝向（線性 seek——每次 update 從頭找，冷路徑）。
local function lineAt(profile, sPos)
    local ss = profile.s
    local idx = 1
    local hi = profile.n - 1
    while idx < hi and ss[idx + 1] <= sPos do idx = idx + 1 end
    local t = 0
    local segLen = profile.segLen[idx]
    if segLen > 0 then
        t = (sPos - ss[idx]) / segLen
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local x = profile.x[idx] + (profile.x[idx + 1] - profile.x[idx]) * t
    local y = profile.y[idx] + (profile.y[idx + 1] - profile.y[idx]) * t
    return x, y, profile.segH[idx]
end

-- 中心線橫向偏 l 的世界點（路面帶邊界用；l 正＝行進方向右側，同 follower 慣例）
local function edgeAt(profile, sPos, l)
    local x, y, h = lineAt(profile, sPos)
    return x - sin(h) * l, y + cos(h) * l
end

local function trailPoint(profile, fstate, sPos)
    local x, y, h = lineAt(profile, sPos)
    local lane = fstate.laneBias
    if type(lane) ~= "number" or lane ~= lane then lane = 0 end
    local dodging = false
    local offL = fstate.offL
    -- M6：承諾折線在就直接畫它（畫的＝掃的＝走的同一條世界線）
    if offL ~= nil and (fstate.ovN or 0) >= 2 then
        local fi = (sPos - fstate.ovS0) / 1.0 + 1
        if fi >= 1 and fi <= fstate.ovN then
            local i0 = fi - fi % 1
            if i0 >= fstate.ovN then i0 = fstate.ovN - 1 end
            local ft = fi - i0
            local ovX, ovY = fstate.ovX, fstate.ovY
            local wx = ovX[i0] + (ovX[i0 + 1] - ovX[i0]) * ft
            local wy = ovY[i0] + (ovY[i0 + 1] - ovY[i0]) * ft
            local oa, od = fstate.offA, fstate.offD
            return wx, wy, sPos > oa and sPos < od
        end
    end
    if offL ~= nil and type(offL) == "number" and offL == offL then
        local oa, ob, oc, od = fstate.offA, fstate.offB, fstate.offC, fstate.offD
        if sPos > oa and sPos < od then
            local k
            if sPos < ob then
                k = (sPos - oa) / (ob - oa)
            elseif sPos > oc then
                k = (od - sPos) / (od - oc)
            else
                k = 1
            end
            k = k * k * (3 - 2 * k)
            lane = lane + (offL - lane) * k
            dodging = k > 0.05
        end
    end
    if lane ~= 0 then
        x = x - sin(h) * lane
        y = y + cos(h) * lane
    end
    return x, y, dodging
end

-- 重建整批 marker。呼叫端（driver）保證：session 活著、剖面 ready、
-- 沙盒 DebugOverlay 開啟、每輪掃描完成時呼叫一次（250ms 節流天然成立）。
function MDADOverlay.update(s, vehicle, cell)
    MDADOverlay.clear()
    if type(getWorldMarkers) ~= "function" then return end
    if cell == nil or vehicle == nil then return end
    local profile = s.profile
    if type(profile) ~= "table" or profile.ready ~= true then return end
    local z = vehicle:getZ()
    z = z - z % 1

    -- ① 軌跡點列：藍＝跟線、黃＝側偏剖面作用中
    local sFrom = s.lastSNow
    local sTo = sFrom + TRAIL_AHEAD
    if sTo > profile.length then sTo = profile.length end
    local sPos = sFrom
    while sPos <= sTo do
        local x, y, dodging = trailPoint(profile, s.fstate, sPos)
        if dodging then
            put(cell, x, y, z, 1.0, 0.85, 0.1, TRAIL_SIZE + 0.1)
        else
            put(cell, x, y, z, 0.15, 0.85, 1.0, TRAIL_SIZE)
        end
        sPos = sPos + TRAIL_STEP
    end

    -- ② 感知快照的硬障礙（世界座標現成；只畫前 HARD_MAX_SHOW 顆）
    local sen = s.sensor
    if type(sen) == "table" and sen.ready == true then
        local nShow = sen.hardN
        if nShow > HARD_MAX_SHOW then nShow = HARD_MAX_SHOW end
        for i = 1, nShow do
            local r = sen.hardR[i] or 0.7
            put(cell, sen.hardX[i], sen.hardY[i], z, 1.0, 0.25, 0.2, r + 0.4)
        end

        -- ②b 跟車錨（診斷 MP 車輛盲區）：橙圈＝格級幾何查詢命中且判「行進
        -- 中」的最近前車弧長（isStopped false——半更新的靜止車常這樣被誤判；
        -- 判「靜止」的車已進硬點紅圈）。撞上一台**沒有任何圈**的車＝連
        -- chunk.vehicles 幾何查詢都不在（比 2026-08-28 黑車追尾更深一層）。
        local va = sen.vehAheadS
        if type(va) == "number" then
            local vx2, vy2 = edgeAt(profile, va, 0)
            put(cell, vx2, vy2, z, 1.0, 0.55, 0.1, 1.2)
        end

        -- ③ 路面帶邊界（路面對中統計；nil＝本輪無樣本不畫）
        local lo, hi2 = sen.roadLo, sen.roadHi
        if type(lo) == "number" and type(hi2) == "number" then
            local sEdge = sen.scanS
            local sEnd = sen.scanEndS
            while sEdge <= sEnd do
                local xL, yL = edgeAt(profile, sEdge, lo)
                local xR, yR = edgeAt(profile, sEdge, hi2)
                put(cell, xL, yL, z, 0.3, 1.0, 0.4, ROAD_SIZE)
                put(cell, xR, yR, z, 0.3, 1.0, 0.4, ROAD_SIZE)
                sEdge = sEdge + ROAD_STEP
            end
        end
    end
end
