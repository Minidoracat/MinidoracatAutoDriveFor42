-- MDAD_Overlay.lua — 自駕世界軌跡＋debug 感知標記。
--
-- 一般玩家：自駕 session 活著時，以半透明連續世界線畫未來 52m 實走軌跡；
-- 藍＝正常 follower 線，黃＝已 commit 的 dodge 進入／保持／收回線。停止、
-- 失效或換 route 立即清快取；沒有 session 就不提交任何 renderIsoLine。
--
-- DebugOverlay 只額外顯示：
--   障礙紅圈  感知快照的硬障礙（圈半徑＝逐點半徑＋車安全裕度示意）
--   路面帶綠點 roadLo/roadHi 邊界；橙圈＝最近行進中前車錨
-- 一般軌跡不再使用 marker 圈，因此 debug 關閉也能畫線且不建立 WorldMarkers。
--
-- API 出處（家規：每個呼叫都要有原版出處）：
--   renderIsoLine(x,y,z,tx,ty,tz,thickness,r,g,b,a)
--      LuaManager.java:10141-10154；原版用例 ISMoveableCursor.lua:443-460。
--   OnPostRender 位於世界繪製之後、UI 之前且逐 split viewport 觸發：
--      IngameState.java:1165-1175/1257-1273；getPlayer() 回該 viewport 的
--      IsoPlayer.instance（LuaManager.java:3873-3879）。
--   getWorldMarkers()/addGridSquareMarker/remove 只供 debug 圈：
--      ISSpawnHordeUI.lua:398/406；WorldMarkers.java:508。
--   cell:getGridSquare(x,y,z)  用例 ISDestroyCursor.lua:278。

MDADOverlay = MDADOverlay or {}

local sin, cos = math.sin, math.cos

local TRAIL_AHEAD = 52      -- 玩家軌跡前視（公尺；比標準掃描帶 48 略長，看得到回歸）
local TRAIL_STEP = 1.5      -- 線段取樣距；連續直線不需要舊 marker 的 0.8m 密度
local TRAIL_ALPHA = 0.48    -- 半透明；LineDrawer 直接吃 0..1 alpha
local TRAIL_Z_LIFT = 0.02   -- 略抬離地面，避免非 FBO 路徑與地板同面閃爍
local BLUE_R, BLUE_G, BLUE_B = 0.15, 0.85, 1.0
local YELLOW_R, YELLOW_G, YELLOW_B = 1.0, 0.85, 0.1
local HARD_MAX_SHOW = 24    -- debug 障礙圈上限（快照可能上百點）
local ROAD_STEP = 6         -- debug 路面帶邊界點間距
local ROAD_SIZE = 0.4
local MAX_PLAYERS = 4
local TRAIL_THICKNESS = { 1, 3, 7 } -- 細／標準／粗：單一世界線的像素粗細
local OV_STEP = MDADFollower.OV_STEP -- M6 承諾折線步距的跨模組單一事實源

-- 每槽常駐緩衝：update 每 250ms 覆寫，OnPostRender 只讀；第一輪撐容後不再配置。
local trailX = { {}, {}, {}, {} }
local trailY = { {}, {}, {}, {} }
local trailDodge = { {}, {}, {}, {} }
local trailN = { 0, 0, 0, 0 }
local trailZ = { 0, 0, 0, 0 }
local trailWidth = { 2, 2, 2, 2 }

local markers = { {}, {}, {}, {} } -- debug WorldMarkers 亦按 split-screen 槽隔離
local markerN = { 0, 0, 0, 0 }

local function slotOf(playerNum)
    if type(playerNum) ~= "number" or playerNum < 0 or playerNum >= MAX_PLAYERS
            or playerNum % 1 ~= 0 then return nil end
    return playerNum + 1
end

local function clearMarkerSlot(slot)
    local list = markers[slot]
    for i = 1, markerN[slot] do
        local m = list[i]
        if m ~= nil then
            m:remove()
            list[i] = nil
        end
    end
    markerN[slot] = 0
end

local function clearMarkers(playerNum)
    local slot = slotOf(playerNum)
    if slot then
        clearMarkerSlot(slot)
        return
    end
    for i = 1, MAX_PLAYERS do clearMarkerSlot(i) end
end

function MDADOverlay.clearTrail(playerNum)
    local slot = slotOf(playerNum)
    if slot then
        trailN[slot] = 0
        return
    end
    for i = 1, MAX_PLAYERS do trailN[i] = 0 end
end

function MDADOverlay.clear(playerNum)
    clearMarkers(playerNum)
    MDADOverlay.clearTrail(playerNum)
end

function MDADOverlay.setTrajectoryWidth(width)
    if type(width) ~= "number" or width ~= width or width < 1 or width > 3 then return false end
    width = width - width % 1
    for slot = 1, MAX_PLAYERS do trailWidth[slot] = width end
    return true
end

-- OnPostRender 在每個 split viewport 的世界之後、UI 之前呼叫；只畫目前
-- IsoPlayer.instance 所屬 slot。粗細是 renderIsoLine 的單一 thickness 參數，
-- 三檔每段都只有一次 client 呼叫。
function MDADOverlay.render()
    if type(renderIsoLine) ~= "function" or type(getPlayer) ~= "function" then return end
    local playerObj = getPlayer()
    if playerObj == nil then return end
    local slot = slotOf(playerObj:getPlayerNum())
    if not slot then return end
    local n = trailN[slot]
    if n < 2 then return end
    local xs, ys, ds = trailX[slot], trailY[slot], trailDodge[slot]
    local thickness = TRAIL_THICKNESS[trailWidth[slot]] or TRAIL_THICKNESS[2]
    local z = trailZ[slot] + TRAIL_Z_LIFT
    local x1, y1, d1 = xs[1], ys[1], ds[1]
    for i = 2, n do
        local x2, y2, d2 = xs[i], ys[i], ds[i]
        if x1 ~= x2 or y1 ~= y2 then
            local r, g, b = BLUE_R, BLUE_G, BLUE_B
            if d1 or d2 then r, g, b = YELLOW_R, YELLOW_G, YELLOW_B end
            renderIsoLine(x1, y1, z, x2, y2, z, thickness, r, g, b, TRAIL_ALPHA)
        end
        x1, y1, d1 = x2, y2, d2
    end
end

-- 內部：在世界 (wx, wy, z) 放一顆圈。square 不存在（未載入）就跳過。
-- alpha 三坑（2026-08-28 全踩過，出處都在反編譯）：
--   1. doAlpha=true＝脈動模式，alpha 從 0 以 0.006/tick 爬升（WorldMarkers.java
--      :453-476），~0.5 秒才可見——本模組每 250ms 整批重建，永遠停在隱形段。
--   2. 舊渲染管線 doAlpha=false 恆全亮（WorldMarkers.java:553）——所以傳 false。
--   3. **B42 實際走 FBO 管線**（PerformanceSettings.fboRenderChunk），它直接畫
--      m.alpha、完全無視 doAlpha（FBORenderWorldMarkers.java:75）；而 alpha
--      建構初值是 0（WorldMarkers.java:532）——必須 add 後立刻 setAlpha(1)
--      抬到全亮，否則 FBO 畫出來的圈近全透明＝「開了什麼都看不到」。
local function put(slot, cell, wx, wy, z, r, g, b, size)
    local sq = cell:getGridSquare(wx - wx % 1, wy - wy % 1, z)
    if sq == nil then return end
    local m = getWorldMarkers():addGridSquareMarker(sq, r, g, b, false, size)
    if m ~= nil then
        m:setAlpha(1)
        local n = markerN[slot] + 1
        markerN[slot] = n
        markers[slot][n] = m
    end
end

-- 內部：弧長 s 的中心線點與段朝向。startIdx 由同輪前一取樣傳回，52m 點列
-- 只單調走一次 profile；debug edgeAt 不傳時才從 1 起掃。
local function lineAt(profile, sPos, startIdx)
    local ss = profile.s
    local hi = profile.n - 1
    local idx = startIdx
    if type(idx) ~= "number" or idx < 1 then idx = 1
    elseif idx > hi then idx = hi end
    while idx > 1 and ss[idx] > sPos do idx = idx - 1 end
    while idx < hi and ss[idx + 1] <= sPos do idx = idx + 1 end
    local t = 0
    local segLen = profile.segLen[idx]
    if segLen > 0 then
        t = (sPos - ss[idx]) / segLen
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local x = profile.x[idx] + (profile.x[idx + 1] - profile.x[idx]) * t
    local y = profile.y[idx] + (profile.y[idx + 1] - profile.y[idx]) * t
    return x, y, profile.segH[idx], idx
end

-- 中心線橫向偏 l 的世界點（路面帶邊界用；l 正＝行進方向右側，同 follower 慣例）
local function edgeAt(profile, sPos, l)
    local x, y, h = lineAt(profile, sPos)
    return x - sin(h) * l, y + cos(h) * l
end

-- 由弧長 s 取剖面上的實際行駛點（含 laneBias 與側偏剖面 smoothstep——
-- 與 MDADFollower.control 的前視點公式同一套；fstate 欄位是 follower 的
-- 公開狀態：laneBias／offA..offD／offL）。
local function trailPoint(profile, fstate, sPos, startIdx)
    local x, y, h, idx = lineAt(profile, sPos, startIdx)
    local lane = fstate.laneBias
    if type(lane) ~= "number" or lane ~= lane then lane = 0 end
    local dodging = false
    local offL = fstate.offL
    -- M6：承諾折線在就直接畫它（畫的＝掃的＝走的同一條世界線）
    if offL ~= nil and (fstate.ovN or 0) >= 2 then
        local fi = (sPos - fstate.ovS0) / OV_STEP + 1
        if fi >= 1 and fi <= fstate.ovN then
            local i0 = fi - fi % 1
            if i0 >= fstate.ovN then i0 = fstate.ovN - 1 end
            local ft = fi - i0
            local ovX, ovY = fstate.ovX, fstate.ovY
            local wx = ovX[i0] + (ovX[i0 + 1] - ovX[i0]) * ft
            local wy = ovY[i0] + (ovY[i0 + 1] - ovY[i0]) * ft
            local oa, od = fstate.offA, fstate.offD
            return wx, wy, sPos > oa and sPos < od, idx
        end
    end
    if type(offL) == "number" and offL == offL then
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
    return x, y, dodging, idx
end

local function trajectoryOptions()
    local hud = MDAD and MDAD.HUD
    local visible = true
    local width = 2
    if type(hud) == "table" then
        if type(hud.trajectoryVisible) == "function" then
            visible = hud.trajectoryVisible() == true
        end
        if type(hud.trajectoryWidth) == "function" then
            width = hud.trajectoryWidth()
        end
    end
    if type(width) ~= "number" or width ~= width or width < 1 or width > 3 then width = 2 end
    return visible, width - width % 1
end

-- 每輪掃描完成更新軌跡快取；debugOn 只控制額外 markers，不控制一般線。
function MDADOverlay.update(playerNum, s, vehicle, cell, debugOn)
    local slot = slotOf(playerNum)
    if not slot then return end
    clearMarkers(playerNum)
    trailN[slot] = 0
    if vehicle == nil then return end
    local profile = s.profile
    if type(profile) ~= "table" or profile.ready ~= true then return end
    local z = vehicle:getZ()
    z = z - z % 1

    local showTrajectory, width = trajectoryOptions()
    trailWidth[slot] = width
    if showTrajectory then
        local sFrom = s.lastSNow
        if type(sFrom) ~= "number" then sFrom = 0 end
        local sTo = sFrom + TRAIL_AHEAD
        if sTo > profile.length then sTo = profile.length end
        local xs, ys, ds = trailX[slot], trailY[slot], trailDodge[slot]
        local n = 0
        local sPos = sFrom
        local segIdx = s.fstate.idx
        while sPos <= sTo do
            local x, y, dodging
            x, y, dodging, segIdx = trailPoint(profile, s.fstate, sPos, segIdx)
            n = n + 1
            xs[n], ys[n], ds[n] = x, y, dodging
            sPos = sPos + TRAIL_STEP
        end
        if n == 1 and sTo > sFrom then
            local x, y, dodging = trailPoint(profile, s.fstate, sTo, segIdx)
            n = 2
            xs[n], ys[n], ds[n] = x, y, dodging
        end
        trailZ[slot] = z
        trailN[slot] = n
    end

    if debugOn ~= true or type(getWorldMarkers) ~= "function" or cell == nil then return end

    -- ① 感知快照的硬障礙（世界座標現成；只畫前 HARD_MAX_SHOW 顆）
    local sen = s.sensor
    if type(sen) == "table" and sen.ready == true then
        local nShow = sen.hardN
        if nShow > HARD_MAX_SHOW then nShow = HARD_MAX_SHOW end
        for i = 1, nShow do
            local r = sen.hardR[i] or 0.7
            put(slot, cell, sen.hardX[i], sen.hardY[i], z, 1.0, 0.25, 0.2, r + 0.4)
        end

        -- ①b 橙圈＝格級幾何命中且判為行進中的最近前車錨。
        local va = sen.vehAheadS
        if type(va) == "number" then
            local vx2, vy2 = edgeAt(profile, va, 0)
            put(slot, cell, vx2, vy2, z, 1.0, 0.55, 0.1, 1.2)
        end

        -- ② 路面帶邊界；nil＝樣本不足／歧義，不畫。
        local lo, hi2 = sen.roadLo, sen.roadHi
        if type(lo) == "number" and type(hi2) == "number" then
            local sEdge = sen.scanS
            local sEnd = sen.scanEndS
            while sEdge <= sEnd do
                local xL, yL = edgeAt(profile, sEdge, lo)
                local xR, yR = edgeAt(profile, sEdge, hi2)
                put(slot, cell, xL, yL, z, 0.3, 1.0, 0.4, ROAD_SIZE)
                put(slot, cell, xR, yR, z, 0.3, 1.0, 0.4, ROAD_SIZE)
                sEdge = sEdge + ROAD_STEP
            end
        end
    end
end

Events.OnPostRender.Add(MDADOverlay.render)
