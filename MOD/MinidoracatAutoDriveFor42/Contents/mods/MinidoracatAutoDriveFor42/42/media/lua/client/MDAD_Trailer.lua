-- MDAD_Trailer.lua — 拖掛車支援（2026-09-24；Workshop 回報 W900＋貨櫃在急彎翻車，E2E semi-hairpin-mp 重現）。
-- 三件事：
--   1. attach：讀牽引車正在拖的掛車（BaseVehicle.getVehicleTowing:9857），量掛點→掛車軸距 L2、掛車長寬、質量。
--   2. shape：建路線時對每個轉角跑掛車運動學（掛點走車頭路線，掛車軸無側滑 tractrix 跟隨），
--      找出「車頭先往外靠 a、以半徑 R 轉」讓車頭留在路面、掛車出路面 ≤ INTRUSION_MAX、折角 ≤ HITCH_MAX
--      的最小外靠走法，把該轉角換成這條車頭路線（大貨車司機的外拉大彎）。找不到＝blocked（行駛中接近就停下交還）。
--   3. 行駛防線與倒車：每 100ms 讀折角／掛車傾斜（原版傾斜 >~37° 自動斷開：BaseVehicle.checkTrailerVerticalAlignment:10186）。
-- 路寬來自路線 segWidth（主 MOD 讀 streets.xml），不含路口圓弧加寬與路邊物件——後者仍靠感測。
MDADTrailer = MDADTrailer or {}
local T = MDADTrailer

T.KEY_UNSUPPORTED = "UI_MinidoracatAutoDrive_TrailerUnsupported"
T.KEY_CORNER = "UI_MinidoracatAutoDrive_TrailerCorner"
T.KEY_ROTATE = "UI_MinidoracatAutoDrive_TrailerRotate"
T.KEY_LOST = "UI_MinidoracatAutoDrive_TrailerLost"

T.LAT_SCALE = 0.6          -- 拖車時彎道側向加速度預算乘數（牽引車單體預算對掛車太快：E2E 23 km/h 進 143° 斷開）
T.TURN_MIN_RAD = 25 * math.pi / 180   -- 小於此折角不需要外拉
T.INTRUSION_MAX = 1.0      -- 掛車內輪壓出路面的容許量（轉角外的草地；桿／號誌由感測另管）
T.HITCH_MAX = 60 * math.pi / 180      -- 規劃期車頭—掛車最大折角
T.STEP = 0.5               -- 運動學步長（公尺）
T.RAMP_MIN, T.RAMP_MAX = 8, 16        -- 外靠過渡段長
T.EXIT_HOLD = 8                       -- 轉出外偏保持段長（掛車軸跟進窄路）
T.GUARD_MS = 100
T.HITCH_SLOW = 45 * math.pi / 180     -- 行駛中折角超過＝降到爬行
T.TILT_SLOW = 0.94                    -- 掛車 upVectorDot 低於（≈20°）＝降到爬行
T.CRAWL_KMH = 5
T.CORNER_STOP_M = 18                  -- 不可過轉角：停在距轉角這麼遠
T.REVERSE_GAIN = 2.5                  -- 倒車折角回正增益（steer＝-gain×φ）
T.REVERSE_HITCH_MAX = 30 * math.pi / 180 -- 倒車折角超過＝收手
T.CACHE_MAX = 8

local sqrt, abs, atan2, cos, sin, floor = math.sqrt, math.abs, math.atan2, math.cos, math.sin, math.floor

local function finite(n) return type(n) == "number" and n * 0 == 0 end

local function dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return sqrt(dx * dx + dy * dy)
end

local function wrap(a)
    while a > math.pi do a = a - 2 * math.pi end
    while a < -math.pi do a = a + 2 * math.pi end
    return a
end
T.wrap = wrap

-- ---------------------------------------------------------------- 1. attach（冷路徑）
-- 回 nil＝沒在拖；false＝在拖但量不到可信幾何（呼叫端拒絕啟動）；table＝掛車幾何。
function T.attach(vehicle)
    local ok, trailer = pcall(function() return vehicle:getVehicleTowing() end)
    if not ok or trailer == nil then return nil end
    local ok2, geo = pcall(function()
        local attA = vehicle:getTowAttachmentSelf()
        local h = vehicle:getTowingWorldPos(attA, Vector3f.new())
        local sc = trailer:getScript()
        local ext = sc:getExtents()
        local com = sc:getCenterOfMassOffset()
        local n = sc:getWheelCount()
        local zSum = 0
        for i = 0, n - 1 do zSum = zSum + sc:getWheel(i):getOffset():z() end
        local axle = trailer:getWorldPos(com:x(), 0, zSum / math.max(n, 1), Vector3f.new())
        local front = trailer:getWorldPos(com:x(), 0, com:z() + ext:z() * 0.5, Vector3f.new())
        local rear = trailer:getWorldPos(com:x(), 0, com:z() - ext:z() * 0.5, Vector3f.new())
        return {
            trailer = trailer,
            L2 = dist(h:x(), h:y(), axle:x(), axle:y()),
            hitchToRear = dist(h:x(), h:y(), rear:x(), rear:y()),
            hitchToFront = dist(h:x(), h:y(), front:x(), front:y()),
            halfW = ext:x() * 0.5,
            halfL = ext:z() * 0.5,
            comX = com:x(), comZ = com:z(),
            mass = trailer:getMass(),
            wheels = n,
        }
    end)
    if not ok2 or type(geo) ~= "table" then return false end
    if not (finite(geo.L2) and geo.L2 >= 1 and geo.L2 <= 25
            and finite(geo.halfW) and geo.halfW > 0.3 and geo.halfW < 3
            and finite(geo.hitchToRear) and geo.hitchToRear >= geo.L2 * 0.5
            and finite(geo.mass) and geo.mass > 0 and geo.wheels > 0) then
        return false
    end
    return geo
end

-- ---------------------------------------------------------------- 2. 轉角運動學（純函式，離線可測）
local function segDist(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local t = 0
    if l2 > 0 then t = ((px - ax) * dx + (py - ay) * dy) / l2 end
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local qx, qy = ax + t * dx - px, ay + t * dy - py
    return sqrt(qx * qx + qy * qy)
end

-- 兩段路面（進入段／轉出段，各自中心線＋半寬）聯集外的距離；0＝在路面內。
local function outside(c, px, py)
    local d1 = segDist(px, py, c.ax, c.ay, c.nx1, c.ny1) - c.hwIn
    local d2 = segDist(px, py, c.nx0, c.ny0, c.bx, c.by) - c.hwOut
    local d = d1 < d2 and d1 or d2
    return d > 0 and d or 0
end

-- 車頭（掛點）沿路線走一遍：回 ok, 最大折角, 掛車最大出路量。路線點用 path(i) 迭代。
-- 牽引車車身以「掛點前 front、半寬 thw」；掛車以軸 L2、尾 rear、半寬 hw。
local function simulate(c, xs, ys, n, g)
    local hx, hy = xs[1], ys[1]
    local dx, dy = xs[2] - hx, ys[2] - hy
    local dl = sqrt(dx * dx + dy * dy)
    local ax, ay = hx - dx / dl * g.L2, hy - dy / dl * g.L2
    local worstHitch, worstOut = 0, 0
    for i = 2, n do
        local px, py = xs[i], ys[i]
        local tx, ty = px - hx, py - hy
        local tl = sqrt(tx * tx + ty * ty)
        if tl > 1e-6 then
            tx, ty = tx / tl, ty / tl
            hx, hy = px, py
            local vx, vy = hx - ax, hy - ay
            local vl = sqrt(vx * vx + vy * vy)
            vx, vy = vx / vl, vy / vl
            ax, ay = hx - vx * g.L2, hy - vy * g.L2
            local hitch = abs(atan2(tx * vy - ty * vx, tx * vx + ty * vy))
            if hitch > worstHitch then worstHitch = hitch end
            -- 牽引車：掛點與車頭兩側
            local nx, ny = -ty, tx
            local fx, fy = hx + tx * g.front, hy + ty * g.front
            -- 後軸（掛點）兩側必須在路面；車頭懸伸（長鼻牽引車 5-7m）轉彎時必然甩過路緣／路口對邊，
            -- 與掛車內輪同樣只容許 INTRUSION_MAX（草地可壓、硬物由感測管）。
            for side = -1, 1, 2 do
                if outside(c, hx + nx * g.thw * side, hy + ny * g.thw * side) > 0 then
                    return false, worstHitch, worstOut
                end
                local o = outside(c, fx + nx * g.thw * side, fy + ny * g.thw * side)
                if o > worstOut then worstOut = o end
            end
            -- 掛車：掛點、軸、尾、中段兩側
            local mx, my = -vy, vx
            local rx, ry = hx - vx * g.rear, hy - vy * g.rear
            for k = 0, 3 do
                local qx, qy
                if k == 0 then qx, qy = hx, hy
                elseif k == 1 then qx, qy = ax, ay
                elseif k == 2 then qx, qy = rx, ry
                else qx, qy = (hx + rx) * 0.5, (hy + ry) * 0.5 end
                for side = -1, 1, 2 do
                    local o = outside(c, qx + mx * g.hw * side, qy + my * g.hw * side)
                    if o > worstOut then worstOut = o end
                end
            end
            if worstOut > T.INTRUSION_MAX then return false, worstHitch, worstOut end
        end
    end
    return worstHitch <= T.HITCH_MAX, worstHitch, worstOut
end
T._simulate = simulate

-- 產生候選車頭路線：進入段外靠 a、轉出段外偏 b（兩者正＝往轉彎外側），圓角半徑 R。
-- 轉出後保持 b 一段再 smoothstep 回中線（大貨車司機轉進窄路後先貼外側、掛車進來再回正）。
-- scratch 陣列重用（冷路徑，但一條路線可能試上百組）。
local XS, YS = {}, {}
local function candidate(c, a, b, R, ramp, approach, exitLen)
    local s = c.turnSign
    local oxIn, oyIn = c.nIn[1] * (-s) * a, c.nIn[2] * (-s) * a
    local oxOut, oyOut = c.nOut[1] * (-s) * b, c.nOut[2] * (-s) * b
    -- 圓心：進入外靠線與轉出外偏線各往彎內偏 R 的交點
    local c1x = c.nx + oxIn + c.nIn[1] * s * R
    local c1y = c.ny + oyIn + c.nIn[2] * s * R
    local c2x = c.nx + oxOut + c.nOut[1] * s * R
    local c2y = c.ny + oyOut + c.nOut[2] * s * R
    local den = c.dIn[1] * c.dOut[2] - c.dIn[2] * c.dOut[1]
    if abs(den) < 1e-6 then return 0 end
    local t = ((c2x - c1x) * c.dOut[2] - (c2y - c1y) * c.dOut[1]) / den
    local cx, cy = c1x + c.dIn[1] * t, c1y + c.dIn[2] * t
    local tax, tay = cx - c.nIn[1] * s * R, cy - c.nIn[2] * s * R     -- 切入點（外靠線上）
    local tbx, tby = cx - c.nOut[1] * s * R, cy - c.nOut[2] * s * R   -- 切出點（轉出外偏線上）
    local sIn = (tax - c.nx) * c.dIn[1] + (tay - c.ny) * c.dIn[2]
    local sOut = (tbx - c.nx) * c.dOut[1] + (tby - c.ny) * c.dOut[2]
    if sIn > c.wOut * 0.5 + 2 or sOut < -c.wIn * 0.5 - 2 then return 0 end
    local n = 0
    local step = T.STEP
    local s0 = sIn - approach
    local rampEnd = s0 + ramp
    local sCur = s0
    while sCur < sIn do
        local off = a
        if sCur < rampEnd then
            local u = (sCur - s0) / ramp
            off = a * u * u * (3 - 2 * u)
        end
        n = n + 1
        XS[n] = c.nx + c.dIn[1] * sCur + c.nIn[1] * (-s) * off
        YS[n] = c.ny + c.dIn[2] * sCur + c.nIn[2] * (-s) * off
        sCur = sCur + step
    end
    local a0 = atan2(tay - cy, tax - cx)
    local sweep = c.turnAbs
    local m = floor(sweep * R / step)
    if m < 2 then m = 2 end
    for i = 0, m do
        local ang = a0 + s * sweep * i / m
        n = n + 1
        XS[n], YS[n] = cx + R * cos(ang), cy + R * sin(ang)
    end
    -- 轉出：保持 b 直到掛車也進來（hold），再 ramp 回中線；exitLen 截斷
    local hold = b ~= 0 and T.EXIT_HOLD or 0
    local e = step
    while e <= exitLen do
        local off = b
        if e > hold then
            local u = (e - hold) / ramp
            if u >= 1 then off = 0 else off = b * (1 - u * u * (3 - 2 * u)) end
        end
        local dOff = off - b
        n = n + 1
        XS[n] = tbx + c.dOut[1] * e + c.nOut[1] * (-s) * dOff
        YS[n] = tby + c.dOut[2] * e + c.nOut[2] * (-s) * dOff
        e = e + step
    end
    return n, sIn, sOut
end

T._candidate = function(...) return candidate(...), XS, YS end

-- 轉角規劃：回 {a, b, R, ramp, sIn, sOut, approach, exitLen} 或 nil（不可過）。外靠／外偏都用到
-- 路面邊緣（後軸在路面、半寬＋0.3m 餘裕）；先找總偏移最小的走法。
function T.planCorner(c, g)
    local maxA = c.wIn * 0.5 - g.thw - 0.3
    if maxA < 0 then maxA = 0 end
    local maxB = c.wOut * 0.5 - g.thw - 0.3
    if maxB < 0 then maxB = 0 end
    local approach = g.L2 + g.rear + T.RAMP_MAX + 4
    local exitLen = g.rear + g.L2 + T.RAMP_MAX
    local total = 0
    while total <= maxA + maxB + 1e-9 do
        local a = total < maxA and total or maxA
        while a >= 0 do
            local bAbs = total - a
            for sign = 1, -1, -2 do
              local b = bAbs * sign
              if bAbs <= maxB + 1e-9 and not (sign < 0 and bAbs == 0) then
                local ramp = (a > 0 or b ~= 0) and T.RAMP_MAX or T.RAMP_MIN
                for R = 4, 24, 2 do
                    local n, sIn, sOut = candidate(c, a, b, R, ramp, approach, exitLen)
                    if n > 3 and simulate(c, XS, YS, n, g) then
                        return { a = a, b = b, R = R, ramp = ramp, sIn = sIn, sOut = sOut,
                            approach = approach, exitLen = exitLen }
                    end
                end
              end
            end
            a = a - 0.5
        end
        total = total + 0.5
    end
    return nil
end

-- 由路線三點建轉角幾何。回 nil＝折角小於 TURN_MIN。
function T.cornerOf(px, py, nx, ny, qx, qy, wIn, wOut)
    local dix, diy = nx - px, ny - py
    local dox, doy = qx - nx, qy - ny
    local li, lo = sqrt(dix * dix + diy * diy), sqrt(dox * dox + doy * doy)
    if li < 1e-6 or lo < 1e-6 then return nil end
    dix, diy, dox, doy = dix / li, diy / li, dox / lo, doy / lo
    local turn = atan2(dix * doy - diy * dox, dix * dox + diy * doy)
    if abs(turn) < T.TURN_MIN_RAD then return nil end
    local c = {
        nx = nx, ny = ny, dIn = { dix, diy }, dOut = { dox, doy },
        nIn = { -diy, dix }, nOut = { -doy, dox },
        turnSign = turn > 0 and 1 or -1, turnAbs = abs(turn),
        wIn = wIn, wOut = wOut, hwIn = wIn * 0.5, hwOut = wOut * 0.5,
        lenIn = li, lenOut = lo,
    }
    -- 路面模型：進入段往回 li、跨過節點半個轉出路寬（路口方塊）；轉出段從節點前半個進入路寬起
    -- 進入路面往回多延伸 40m：掛車尾在規劃起點後方，路本來就在（前一個轉角另算）
    c.ax, c.ay = nx - dix * (li + 40), ny - diy * (li + 40)
    c.nx1, c.ny1 = nx + dix * wOut * 0.5, ny + diy * wOut * 0.5
    c.nx0, c.ny0 = nx - dox * wIn * 0.5, ny - doy * wIn * 0.5
    c.bx, c.by = nx + dox * (lo + 40), ny + doy * (lo + 40) -- 轉出後同理：下一個轉角另算
    return c
end

-- ---------------------------------------------------------------- shape：整條路線
-- 回新 route table（pts／segSurface／segWidth 同格式，給 MDADFollower.begin），加 towBlocked＝{x1,y1,x2,y2,...}。
-- 同一個原始 route table 快取（Driver 用原始 identity 比對 cutover）。
local cacheA, cacheB = nil, nil -- 最近兩條（現行＋cutover 新線）；不用弱表

function T.shape(route, tow, tractorHalfW, tractorFront)
    if type(route) ~= "table" or type(tow) ~= "table" then return route end
    if cacheA and cacheA.route == route and cacheA.tow == tow then return cacheA.shaped end
    if cacheB and cacheB.route == route and cacheB.tow == tow then return cacheB.shaped end
    local pts, sw, ss = route.pts, route.segWidth, route.segSurface
    if type(pts) ~= "table" or type(sw) ~= "table" or type(ss) ~= "table" then return route end
    local np = #pts / 2
    local g = { L2 = tow.L2, rear = tow.hitchToRear, hw = tow.halfW,
        front = tractorFront or 4, thw = tractorHalfW or 1.2 }
    local out, ow, os, blocked = {}, {}, {}, {}
    local function push(x, y, w, surf)
        local k = #out
        if k >= 2 and out[k - 1] == x and out[k] == y then return end
        if k >= 2 then ow[#ow + 1], os[#os + 1] = w, surf end
        out[k + 1], out[k + 2] = x, y
    end
    push(pts[1], pts[2], sw[1], ss[1])
    for i = 2, np - 1 do
        local px, py = pts[i * 2 - 3], pts[i * 2 - 2]
        local nx, ny = pts[i * 2 - 1], pts[i * 2]
        local qx, qy = pts[i * 2 + 1], pts[i * 2 + 2]
        local wIn, wOut = sw[i - 1], sw[i]
        local c = T.cornerOf(px, py, nx, ny, qx, qy, wIn, wOut)
        local plan = c and T.planCorner(c, g) or nil
        if plan then
            -- 車頭路線寫進 route：外靠段寬度縮成「以偏移線為中心的虛擬路寬」，
            -- 讓 Follower 的路寬證明對偏移線仍保守成立。
            -- 轉出段只能畫到下一個路線點之前（從切出點算起）：畫過頭再接下一點＝路線往回折，
            -- Follower 判成要原地調頭（E2E semi-hairpin-mp：轉過 143° 後在支路上被 TrailerRotate 交還）
            local exitRoom = c.lenOut - 1 - (plan.sOut > 0 and plan.sOut or 0)
            if exitRoom < 0 then exitRoom = 0 end
            local n = candidate(c, plan.a, plan.b, plan.R, plan.ramp, plan.approach,
                plan.b ~= 0 and math.min(plan.exitLen, exitRoom) or 0)
            -- 只取節點前後各自實際段長內的點，不越過前一個／下一個路線點
            for k = 1, n do
                local x, y = XS[k], YS[k]
                local along = (x - nx) * c.dIn[1] + (y - ny) * c.dIn[2]
                local ahead = (x - nx) * c.dOut[1] + (y - ny) * c.dOut[2]
                if along > -c.lenIn * 0.9 and ahead < c.lenOut - 1 then
                    local minW = 2 * g.thw + 0.4
                    local vw = minW
                    if along < plan.sIn then
                        local off = abs((x - nx) * c.nIn[1] + (y - ny) * c.nIn[2])
                        vw = 2 * (wIn * 0.5 - off)
                        if vw < minW then vw = minW end
                    end
                    if vw < 1 then vw = 1 end
                    push(x, y, vw, ss[i - 1])
                end
            end
        else
            if c and not plan then blocked[#blocked + 1] = nx; blocked[#blocked + 1] = ny end
            push(nx, ny, wIn, ss[i - 1])
        end
    end
    push(pts[np * 2 - 1], pts[np * 2], sw[np - 1], ss[np - 1])
    -- 最後一段寬度／路面補齊（push 以「前一段」屬性記，最後一點需要 np-1 段）
    while #ow < #out / 2 - 1 do ow[#ow + 1], os[#os + 1] = sw[np - 1], ss[np - 1] end
    local shaped = {}
    for k, v in pairs(route) do shaped[k] = v end
    shaped.pts, shaped.segWidth, shaped.segSurface = out, ow, os
    shaped.towBlocked = blocked
    shaped.towSource = route
    cacheB, cacheA = cacheA, { route = route, tow = tow, shaped = shaped }
    return shaped
end

-- ---------------------------------------------------------------- 3. 行駛防線與倒車
-- 車頭—掛車折角（有號，rad，正＝牽引車航向比掛車大）與掛車 upVectorDot。
function T.state(vehicle, tow)
    local ok, phi, up = pcall(function()
        local a = BaseVehicle.allocVector3f()
        local b = BaseVehicle.allocVector3f()
        vehicle:getForwardVector(a)
        tow.trailer:getForwardVector(b)
        local h1 = atan2(a:z(), a:x())
        local h2 = atan2(b:z(), b:x())
        BaseVehicle.releaseVector3f(a)
        BaseVehicle.releaseVector3f(b)
        return wrap(h1 - h2), tow.trailer:getUpVectorDot()
    end)
    if not ok then return nil, nil end
    return phi, up
end

-- 倒車時把折角拉回 0：牽引車要往掛車方向轉（航向減 φ）。steer 正＝航向增加（右轉，y 向南）。
-- 推導：倒車 φ' = v/L1·tanδ − v/L2·sinφ（v<0 時第二項使 |φ| 發散），要 φ' 與 φ 反號需 tanδ 同號且
-- 大於 (L1/L2)sinφ——等價於牽引車航向變化 −sign(φ)。離線驗證見 scripts/test_trailer.lua。
function T.reverseSteer(phi)
    local s = -T.REVERSE_GAIN * phi
    if s > 2 then s = 2 elseif s < -2 then s = -2 end
    return s
end

-- 掛車車身（倒車後方探測用）：中心、前向、半寬、半長。
function T.body(tow)
    local ok, x, y, fx, fy = pcall(function()
        local tr = tow.trailer
        local c = tr:getWorldPos(tow.comX, 0, tow.comZ, Vector3f.new())
        local f = BaseVehicle.allocVector3f()
        tr:getForwardVector(f)
        local l = sqrt(f:x() * f:x() + f:z() * f:z())
        local ux, uy = f:x() / l, f:z() / l
        BaseVehicle.releaseVector3f(f)
        return c:x(), c:y(), ux, uy
    end)
    if not ok then return nil end
    return x, y, fx, fy, tow.halfW, tow.halfL
end

-- 距離最近的不可過轉角（世界座標）；無則 nil。
function T.nearestBlocked(route, x, y)
    local b = type(route) == "table" and route.towBlocked or nil
    if not b or #b == 0 then return nil end
    local best, bx, by = nil, nil, nil
    for k = 1, #b, 2 do
        local d = dist(b[k], b[k + 1], x, y)
        if best == nil or d < best then best, bx, by = d, b[k], b[k + 1] end
    end
    return best, bx, by
end

-- 掛車還掛著嗎（getter 失敗不當脫開，避免誤停）。
function T.lost(vehicle, tow)
    local ok, cur = pcall(function() return vehicle:getVehicleTowing() end)
    return ok and cur ~= tow.trailer
end

-- 行駛防線（Driver 每幀呼叫；Java 讀取以 GUARD_MS 節流）。回 cap（km/h 或 nil）, why：
--   "lost"＝掛車脫落（原版傾斜斷開或玩家拆掉）；"corner"＝已停在不可過轉角前。
function T.guard(s, vehicle, now, speedKmh)
    local tow = s.tow
    if T.lost(vehicle, tow) then return nil, "lost" end
    if now < (s.towNextMs or 0) then return s.towCap, nil end
    s.towNextMs = now + T.GUARD_MS
    local cap = nil
    local phi, up = T.state(vehicle, tow)
    if phi and (abs(phi) > T.HITCH_SLOW or (finite(up) and up < T.TILT_SLOW)) then cap = T.CRAWL_KMH end
    local shaped = T.shape(s.route, tow)
    local vx, vy = vehicle:getX(), vehicle:getY()
    local d, bx, by = T.nearestBlocked(shaped, vx, vy)
    if d then
        local okF, fx, fy = pcall(function()
            local f = BaseVehicle.allocVector3f()
            vehicle:getForwardVector(f)
            local x, y = f:x(), f:z()
            BaseVehicle.releaseVector3f(f)
            return x, y
        end)
        if okF and (bx - vx) * fx + (by - vy) * fy > 0 then
            local room = d - T.CORNER_STOP_M
            if room <= 1 then
                local av = speedKmh < 0 and -speedKmh or speedKmh
                if av < 2 then
                    s.towCap = 0
                    return 0, "corner"
                end
                cap = 0
            else
                -- 只能斷油滑行（沒有比例煞車）：以學到的滑行減速度反推接近帽
                local a = s.safeCoast
                if not finite(a) or a <= 0 then a = 0.6 end
                local v = sqrt(2 * a * room) * 3.6
                if cap == nil or v < cap then cap = v end
            end
        end
    end
    s.towCap = cap
    return cap, nil
end

return T
