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
T.KEY_FRONT = "UI_MinidoracatAutoDrive_TrailerFront" -- 掛在牽引車車頭前方（推著走），自駕只能拖在車尾
T.KEY_CORNER = "UI_MinidoracatAutoDrive_TrailerCorner"
T.KEY_ROTATE = "UI_MinidoracatAutoDrive_TrailerRotate"
T.KEY_LOST = "UI_MinidoracatAutoDrive_TrailerLost"
T.KEY_TURN = "UI_MinidoracatAutoDrive_TrailerTurn" -- 需要調頭時改走不用調頭的繞行（Driver.towTurnaround）

T.LAT_SCALE = 0.525        -- 拖車時彎道側向加速度預算乘數（牽引車單體預算對掛車太快：E2E 23 km/h 進 143° 斷開）；
                           -- 0928m 單車天花板 7→8，這裡 0.6→0.525 讓拖車實際預算維持 4.2
-- 小於此折角不改寫。20°＝MDADDynamics.FILLET_MIN_RAD：改寫後的路線點數遠超 Follower 圓角的 source 容量
-- （FILLET_SOURCE_MAX，1009 前 128、現 256），容量外 ≥20° 的頂點全標 fallback＝12 km/h 爬行（GitHub #6 拖車 20–25° 小彎）；
-- 這些折角改由本檔排圓弧。規劃不出來的 <BLOCK_MIN_RAD 折角照舊保留頂點、不列不可過（舊制本來就照開）。
T.TURN_MIN_RAD = 20 * math.pi / 180
T.BLOCK_MIN_RAD = 25 * math.pi / 180
T.INTRUSION_MAX = 1.0      -- 掛車內輪壓出路面的容許量（轉角外的草地；桿／號誌由感測另管）
T.HITCH_MAX = 60 * math.pi / 180      -- 規劃期車頭—掛車最大折角
T.STEP = 0.5               -- 運動學步長（公尺）
T.RAMP_MIN, T.RAMP_MAX = 8, 16        -- 外靠過渡段長
T.R_MIN, T.R_MAX = 4, 60             -- 外拉圓弧半徑掃描範圍（planCorner 取不比最小可行半徑更切內的最大；60＝拖車預算 ~4 m/s² 下約 55 km/h）
T.SEG_SHARE = 0.45 -- 圓弧切點距占臂長上限（同 MDADDynamics.FILLET_SEGMENT_SHARE：相鄰兩角合計 ≤90%）
T.CUT_TOL = 0.05  -- 大半徑候選的掛車出路量只准比最小可行半徑多這麼多（m，數值容差；見 planCorner）
T.EXIT_HOLD = 8                       -- 轉出外偏保持段長（掛車軸跟進窄路）
T.GUARD_MS = 100
T.HITCH_SLOW = 45 * math.pi / 180     -- 行駛中折角超過＝降到爬行
T.TILT_SLOW = 0.94                    -- 掛車 upVectorDot 低於（≈20°）＝降到爬行
T.CRAWL_KMH = 5
T.CORNER_STOP_M = 18                  -- 不可過轉角：停在距轉角這麼遠
T.REVERSE_GAIN = 2.5                  -- 倒車折角回正增益（steer＝-gain×φ）
T.REVERSE_HITCH_MAX = 30 * math.pi / 180 -- 倒車折角超過＝收手
T.CACHE_MAX = 8
T.ROPE_M = 1.5 -- 兩台都不是 Trailer 腳本＝繩索連結，最長 1.5m（BaseVehicle.addPointConstraint:10069-10070）

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
-- 回 nil＝沒在拖；字串＝不能自駕的翻譯鍵（呼叫端拒絕啟動）；table＝掛車幾何。
-- 原版拖法（ISVehicleMenu.lua TowMenu）不只「車尾→被拖車頭」：一般車互拖會先試車尾對車尾（被拖的車倒著走），
-- 也能掛在牽引車車頭。三件事都照實際幾何量，不照掛點名稱：
--   輪位＝輪子 offset＋模型 offset（Bullet 建輪就是這樣加：VehicleScript.java:586-588）。原版車模型 offset z 多為 0，
--     MOD 掛車常不是（Autotsar KBAC −1.25：輪 +1.25 只是抵銷；W900 貨櫃 +1.27）——漏加會把軸量到掛點旁，KBAC 的
--     L2 量成 0.81＜1 而拒絕啟動。
--   掛車尾＝離掛點較遠的那端：倒著拖時是被拖車的車頭（舊制取車尾＝貼著掛點，車對車尾互拖一律拒絕）。
--   掛點在牽引車車頭前方＝推著走：自駕只會往前開，那台車又被感測當成自己的掛車而看不見，一律拒絕。
-- 繩索拖車（兩台都不是 Trailer）起步時繩子可能是鬆的，開起來會拉直到 ROPE_M：沿軸向補上還沒拉直的長度。
function T.attach(vehicle)
    local ok, trailer = pcall(function() return vehicle:getVehicleTowing() end)
    if not ok or trailer == nil then return nil end
    local ok2, geo = pcall(function()
        local h = vehicle:getTowingWorldPos(vehicle:getTowAttachmentSelf(), Vector3f.new())
        local sc = trailer:getScript()
        local ext = sc:getExtents()
        local com = sc:getCenterOfMassOffset()
        local mo = sc:getModelOffset()
        local n = sc:getWheelCount()
        local zSum = 0
        for i = 0, n - 1 do zSum = zSum + sc:getWheel(i):getOffset():z() end
        local axleZ = zSum / math.max(n, 1) + (mo and mo:z() or 0)
        local axle = trailer:getWorldPos(com:x(), 0, axleZ, Vector3f.new())
        local front = trailer:getWorldPos(com:x(), 0, com:z() + ext:z() * 0.5, Vector3f.new())
        local rear = trailer:getWorldPos(com:x(), 0, com:z() - ext:z() * 0.5, Vector3f.new())
        local slack = 0
        if not string.find(vehicle:getScriptName(), "Trailer", 1, true)
                and not string.find(trailer:getScriptName(), "Trailer", 1, true) then
            local hb = trailer:getTowingWorldPos(trailer:getTowAttachmentSelf(), Vector3f.new())
            slack = T.ROPE_M - dist(h:x(), h:y(), hb:x(), hb:y())
            if slack < 0 then slack = 0 end
        end
        local toRear = dist(h:x(), h:y(), rear:x(), rear:y())
        local toFront = dist(h:x(), h:y(), front:x(), front:y())
        -- 候選線掛車掃掠用（0929p，Driver sweepLine）：掛點在牽引車座標（車位＋前向／右向）裡的位置、
        -- 掛車車身中心在掛車軸座標裡的位置。掛車軸向＝量到的「軸→掛點」單位向量 v0，不是掛車 forward：
        -- 被倒著拖的車 forward 朝後（0929p 審查），拿 forward 當軸向會把軸放到掛點前面、軌跡變成推車。
        -- axisSign＝v0 與掛車 forward 同向（1）或反向（−1），sweep 起算時用實車 forward×axisSign 當軸向。
        -- 右向同 Driver 的 COM 慣例 (fy, −fx)。
        local vf = vehicle:getForwardVector(Vector3f.new())
        local vfx, vfy = vf:x(), vf:z()
        local vl = sqrt(vfx * vfx + vfy * vfy)
        local tf = trailer:getForwardVector(Vector3f.new())
        local tfx, tfy = tf:x(), tf:z()
        local center = trailer:getWorldPos(com:x(), 0, com:z(), Vector3f.new())
        local dx, dy = h:x() - vehicle:getX(), h:y() - vehicle:getY()
        local cx, cy = center:x() - h:x(), center:y() - h:y()
        local ux, uy = h:x() - axle:x(), h:y() - axle:y()
        local ul = sqrt(ux * ux + uy * uy)
        local hitchZ, hitchX, boxBack, boxSide, axisSign
        if vl > 1e-6 then
            vfx, vfy = vfx / vl, vfy / vl
            hitchZ, hitchX = dx * vfx + dy * vfy, dx * vfy - dy * vfx
        end
        if ul > 1e-6 then
            ux, uy = ux / ul, uy / ul
            boxBack, boxSide = -(cx * ux + cy * uy) + slack, cx * uy - cy * ux
            axisSign = (ux * tfx + uy * tfy) >= 0 and 1 or -1
        end
        return {
            trailer = trailer,
            L2 = ul + slack,
            -- 掛點到掛車尾（拖行方向的尾端＝離掛點遠的那端；倒著拖時是被拖車的車頭）
            hitchToRear = (toRear > toFront and toRear or toFront) + slack,
            halfW = ext:x() * 0.5,
            halfL = ext:z() * 0.5,
            comX = com:x(), comZ = com:z(),
            mass = trailer:getMass(),
            wheels = n,
            hitchZ = hitchZ, hitchX = hitchX, boxBack = boxBack, boxSide = boxSide, axisSign = axisSign,
        }
    end)
    local why = nil
    if not ok2 or type(geo) ~= "table" then
        why = T.KEY_UNSUPPORTED
    elseif finite(geo.hitchZ) and geo.hitchZ > 0 then
        why = T.KEY_FRONT
    elseif not (finite(geo.L2) and geo.L2 >= 1 and geo.L2 <= 25
            and finite(geo.halfW) and geo.halfW > 0.3 and geo.halfW < 3
            and finite(geo.hitchToRear) and geo.hitchToRear >= geo.L2 * 0.5
            and finite(geo.mass) and geo.mass > 0 and geo.wheels > 0) then
        why = T.KEY_UNSUPPORTED
    end
    if why then
        -- 玩家回報「量不到掛車」時 console 唯一的線索：哪兩台、量到什麼
        local g = type(geo) == "table" and geo or {}
        local okN, names = pcall(function()
            return tostring(vehicle:getScriptName()) .. " -> " .. tostring(trailer:getScriptName())
        end)
        print(string.format("[MinidoracatAutoDriveFor42] tow refused (%s): %s L2=%s tail=%s halfW=%s hitchZ=%s wheels=%s",
            why, okN and names or "?", tostring(g.L2), tostring(g.hitchToRear), tostring(g.halfW),
            tostring(g.hitchZ), tostring(g.wheels)))
        return why
    end
    -- 車位到掛車尾（直線時）：繞行保持段要多撐的長度（Driver shapeProfile）。量不到掛點偏移時不延長、
    -- sweepLine 也不驗掛車（退回舊制只驗牽引車），不因此拒絕啟動。
    if finite(geo.hitchZ) and finite(geo.hitchX) and finite(geo.boxBack) and finite(geo.boxSide)
            and (geo.axisSign == 1 or geo.axisSign == -1) then
        geo.trailLen = -geo.hitchZ + geo.hitchToRear
    else
        geo.hitchZ, geo.hitchX, geo.boxBack, geo.boxSide, geo.axisSign = nil, nil, nil, nil, nil
    end
    -- 脫開鑑識用（T.lostState、Driver 的 tow phase=lost）：掛車 id（脫開後用 getVehicleById 查還在不在）與 script 名、
    -- 兩邊掛點名（牽引車自己的／掛車的）。各自 pcall：量不到只少鑑識欄，不拒絕啟動。
    pcall(function() geo.id = trailer:getId() end)
    pcall(function() geo.script = trailer:getScriptName() end)
    pcall(function() geo.hitchSelf = vehicle:getTowAttachmentSelf() end)
    pcall(function() geo.hitchOther = vehicle:getTowAttachmentOther() end)
    return geo
end

-- 掛點到牽引車車頭（shape 的 tractorFront：simulate 從掛點往前量車頭懸伸）。hitchZ＝掛點在牽引車座標的縱向位置
-- （車位起算，負＝在後），量得到＝halfL−hitchZ；量不到（attach 已清掉偏移）退回整車長（保守）。舊制一律整車長＝
-- 第五輪牽引車高估 1.2–1.4 m（正式服 0.23.0 片段 SemiTruckLite 7.20 vs 5.83：兩個 90° 轉角誤判不可過）。
function T.hitchFront(tow, halfL)
    if finite(tow.hitchZ) then return halfL - tow.hitchZ end
    return halfL * 2
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

-- 車頭（掛點）沿路線走一遍：回 ok, 最大折角, 最大出路量（牽引車車頭＋掛車）, 掛車車身最大出路量。
-- 牽引車車身以「掛點前 front、半寬 thw」；掛車以軸 L2、尾 rear、半寬 hw。
local function simulate(c, xs, ys, n, g)
    local hx, hy = xs[1], ys[1]
    local dx, dy = xs[2] - hx, ys[2] - hy
    local dl = sqrt(dx * dx + dy * dy)
    local ax, ay = hx - dx / dl * g.L2, hy - dy / dl * g.L2
    local worstHitch, worstOut, worstTrailer = 0, 0, 0
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
                    return false, worstHitch, worstOut, worstTrailer
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
                    if o > worstTrailer then worstTrailer = o end
                end
            end
            if worstOut > T.INTRUSION_MAX then return false, worstHitch, worstOut, worstTrailer end
        end
    end
    return worstHitch <= T.HITCH_MAX, worstHitch, worstOut, worstTrailer
end
T._simulate = simulate

-- 繞行候選線上的掛車折角（Driver Drive.towFold）：牽引車參考點（車輛原點）沿候選線 (cx, cy) 與基準線 (bx, by)（同弧長取樣、
-- 不偏移照原 lane）各推一台掛車：掛點＝參考點＋前向×hz＋法向×hx（同 Driver sweepLine），掛車軸無側滑（tractrix，同 simulate）；
-- 起始軸向＝線首航向減實測折角 phi0（T.state 同號）。某點候選 |折角| > max(lim, 同點基準 |折角|＋tol)＝不 ok：超過門檻的部分
-- 必須是候選自己加的。回 ok, 候選線最大 |折角|（rad）, 最壞違規點索引（ok 時 nil）。
local function trail(xs, ys, k, ax, ay, hz, hx, L2, phi0)
    local fx, fy = xs[k + 1] - xs[k], ys[k + 1] - ys[k]
    local fl = sqrt(fx * fx + fy * fy)
    if fl < 1e-6 then return ax, ay, nil end
    fx, fy = fx / fl, fy / fl
    local px, py = xs[k] + fx * hz + fy * hx, ys[k] + fy * hz - fx * hx
    local vx, vy
    if ax == nil then
        local h = atan2(fy, fx) - phi0
        vx, vy = cos(h), sin(h)
    else
        vx, vy = px - ax, py - ay
        local vl = sqrt(vx * vx + vy * vy)
        if vl < 1e-6 then return ax, ay, nil end
        vx, vy = vx / vl, vy / vl
    end
    return px - vx * L2, py - vy * L2, abs(atan2(fx * vy - fy * vx, fx * vx + fy * vy))
end
function T.dodgeFold(cx, cy, bx, by, n, hz, hx, L2, phi0, lim, tol)
    local cax, cay, bax, bay, cphi, bphi
    local worst, badK, badPhi, base = 0, nil, 0, 0
    for k = 1, n - 1 do
        cax, cay, cphi = trail(cx, cy, k, cax, cay, hz, hx, L2, phi0)
        bax, bay, bphi = trail(bx, by, k, bax, bay, hz, hx, L2, phi0)
        if bphi then base = bphi end
        if cphi then
            if cphi > worst then worst = cphi end
            if cphi > lim and cphi > base + tol and cphi > badPhi then badK, badPhi = k, cphi end
        end
    end
    return badK == nil, worst, badK
end

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
    local arc0 = n + 1 -- 圓弧第一點的索引（shape 標記弧段給 Follower）
    local a0 = atan2(tay - cy, tax - cx)
    local sweep = c.turnAbs
    local m = floor(sweep * R / step)
    if m < 2 then m = 2 end
    for i = 0, m do
        local ang = a0 + s * sweep * i / m
        n = n + 1
        XS[n], YS[n] = cx + R * cos(ang), cy + R * sin(ang)
    end
    local arc1 = n
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
    return n, sIn, sOut, arc0, arc1
end

T._candidate = function(...) return candidate(...), XS, YS end

-- 轉角規劃：回 {a, b, R, ramp, sIn, sOut, approach, exitLen} 或 nil（不可過）。外靠／外偏都用到
-- 路面邊緣（後軸在路面、半寬＋0.3m 餘裕）；先找總偏移最小的走法。同一組偏移先找最小可行半徑（＝舊制，
-- 可過與否、最保守的掛車軌跡都由它決定），再從大往小找更大的可行半徑：剖面照圓弧曲率限速（sqrt(aLat·R)），
-- 只取最小的 R=4 連 28° 寬彎都壓到 12 km/h 地板（GitHub #6）。更大的半徑要同時滿足：①圓弧切點距在短臂段長
-- ×SEG_SHARE 內（相鄰轉角各用不到一半，重疊＝撤點折線）；②掛車車身出路量不超過最小可行半徑那條＋CUT_TOL
-- ——牽引車走大弧＝弧中點往彎內移 R(1/cos(θ/2)−1)，掛車再往內 off-track，車身掃進彎內角路外（1006 E2E
-- semi-corner：14m→8m 直角 R 6→12，掛車出路 0.07→0.71m，撞上彎內 0.8m 外的路邊物）；路外有什麼只有感測知道，
-- 規劃不得比舊制更切內。都不符就用最小可行半徑。
function T.planCorner(c, g)
    local maxA = c.wIn * 0.5 - g.thw - 0.3
    if maxA < 0 then maxA = 0 end
    local maxB = c.wOut * 0.5 - g.thw - 0.3
    if maxB < 0 then maxB = 0 end
    local approach = g.L2 + g.rear + T.RAMP_MAX + 4
    local exitLen = g.rear + g.L2 + T.RAMP_MAX
    -- 掃描上限：置中圓弧切點距 R·tan(θ/2) 到短臂份額為止；舊範圍（≤24）照掃，退回最小可行半徑要看得到它
    local maxT = T.SEG_SHARE * (c.lenIn < c.lenOut and c.lenIn or c.lenOut)
    local rTop = floor(maxT / math.tan(c.turnAbs * 0.5) * 0.5) * 2
    if rTop > T.R_MAX then rTop = T.R_MAX end
    if rTop < 24 then rTop = 24 end
    local total = 0
    while total <= maxA + maxB + 1e-9 do
        local a = total < maxA and total or maxA
        while a >= 0 do
            local bAbs = total - a
            for sign = 1, -1, -2 do
              local b = bAbs * sign
              if bAbs <= maxB + 1e-9 and not (sign < 0 and bAbs == 0) then
                local ramp = (a > 0 or b ~= 0) and T.RAMP_MAX or T.RAMP_MIN
                -- 基準：最小可行半徑（舊制的走法與掛車出路量）
                local base, baseCut = nil, nil
                for R = T.R_MIN, rTop, 2 do
                    local n, sIn, sOut = candidate(c, a, b, R, ramp, approach, exitLen)
                    if n > 3 then
                        local ok, _, _, cut = simulate(c, XS, YS, n, g)
                        if ok then
                            base = { a = a, b = b, R = R, ramp = ramp, sIn = sIn, sOut = sOut,
                                approach = approach, exitLen = exitLen }
                            baseCut = cut
                            break
                        end
                    end
                end
                if base then
                    for R = rTop, base.R + 2, -2 do
                        local n, sIn, sOut = candidate(c, a, b, R, ramp, approach, exitLen)
                        if n > 3 and sIn >= -maxT and sOut <= maxT then
                            local ok, _, _, cut = simulate(c, XS, YS, n, g)
                            if ok and cut <= baseCut + T.CUT_TOL then
                                return { a = a, b = b, R = R, ramp = ramp, sIn = sIn, sOut = sOut,
                                    approach = approach, exitLen = exitLen }
                            end
                        end
                    end
                    return base
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
-- 回新 route table（pts／segSurface／segWidth 同格式，給 MDADFollower.begin），加 towBlocked＝{x1,y1,x2,y2,...}、
-- towBlockedR＝{r1,r2,...}（每個不可過轉角的路口方塊半對角線＝兩臂半路寬的斜邊；Driver 改道避讓圈要蓋住整個轉角）、
-- segArcR＝每段的規劃圓弧半徑（0＝不是弧）：改寫線 0.5m 一點、遠超 Follower 圓角 source 容量，不標的話 Follower 只看到
-- 逐點小折線——沒有弧段前饋、切線追蹤與弧上即時帽，純追跡切弦內切（正式服 0.23.0 拖車轉角 ld 0.5–1.55m）。
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
    local out, ow, os, oa, blocked, blockedR, arcN = {}, {}, {}, {}, {}, {}, 0
    -- fold＝true（轉角規劃出來的點）：新點讓上一段反向（>90°；規劃點 0.5m 一點、圓弧 R≥4，正常每點
    -- 只轉幾度）就撤掉上一點再比。相鄰轉角段很短時，前一個轉角的轉出點已畫進本段、本轉角的外靠點又從
    -- 段中起算＝線往回折（0.13.1 正式服 StepVan＋掛車：90° 左轉接 13m 後 28° 彎，改寫線在 (10853,9976)
    -- 折返 176°，車頭到那裡 Follower 判原地調頭→TrailerRotate 交還）。原始路線節點（不可過的轉角）不做。
    local function push(x, y, w, surf, fold, arcR)
        local k = #out
        if k >= 2 and out[k - 1] == x and out[k] == y then return end
        while fold and k >= 4 do
            local ux, uy = out[k - 1] - out[k - 3], out[k] - out[k - 2]
            local vx, vy = x - out[k - 1], y - out[k]
            if ux * vx + uy * vy > 0 then break end
            out[k], out[k - 1] = nil, nil
            ow[#ow], os[#os], oa[#oa] = nil, nil, nil
            k = k - 2
        end
        if k >= 2 then ow[#ow + 1], os[#os + 1], oa[#oa + 1] = w, surf, arcR or 0 end
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
            arcN = arcN + 1
            -- 車頭路線寫進 route：外靠段寬度縮成「以偏移線為中心的虛擬路寬」，
            -- 讓 Follower 的路寬證明對偏移線仍保守成立。
            -- 轉出段只能畫到下一個路線點之前（從切出點算起）：畫過頭再接下一點＝路線往回折，
            -- Follower 判成要原地調頭（E2E semi-hairpin-mp：轉過 143° 後在支路上被 TrailerRotate 交還）
            local exitRoom = c.lenOut - 1 - (plan.sOut > 0 and plan.sOut or 0)
            if exitRoom < 0 then exitRoom = 0 end
            local n, _, _, arc0, arc1 = candidate(c, plan.a, plan.b, plan.R, plan.ramp, plan.approach,
                plan.b ~= 0 and math.min(plan.exitLen, exitRoom) or 0)
            -- 只取節點前後各自實際段長內的點，不越過前一個／下一個路線點。不外靠（a＝0）的進入段就是原中心線，
            -- 只留到臂長一半：前一個轉角的圓弧可能畫到這一臂的 SEG_SHARE，進入點從更前面起算＝撤點後弧被截成
            -- 40°+ 的折點（容量外標 fallback 爬行）；退回的小半徑切點在一半外時從切點起留。
            local back = -c.lenIn * 0.9
            if plan.a == 0 then
                back = plan.sIn - 1e-6
                if back > -c.lenIn * 0.5 then back = -c.lenIn * 0.5 end
                if back < -c.lenIn * 0.9 then back = -c.lenIn * 0.9 end
            end
            -- 虛擬路寬下限＝Follower 路寬證明（MDADDynamics.rawBandContains：每側 halfW＋ROAD_EDGE_MARGIN）剛好過、再留
            -- 每側 0.05：改寫線本身已由 simulate 驗過（掛點兩側在路面、車頭與掛車出路 ≤INTRUSION_MAX），證明只需認它。
            -- 舊下限每側只留 0.2＝改寫段證明永遠不過，彎速一律落到 obb 近場帽 18 km/h（正式服 1,290 筆 sw＝2·halfW＋0.4）。
            local minW = 2 * (g.thw + MDADDynamics.ROAD_EDGE_MARGIN) + 0.1
            local prevK = nil
            for k = 1, n do
                local x, y = XS[k], YS[k]
                local along = (x - nx) * c.dIn[1] + (y - ny) * c.dIn[2]
                local ahead = (x - nx) * c.dOut[1] + (y - ny) * c.dOut[2]
                if along > back and ahead < c.lenOut - 1 then
                    local vw = minW
                    if along < plan.sIn then
                        local off = abs((x - nx) * c.nIn[1] + (y - ny) * c.nIn[2])
                        vw = 2 * (wIn * 0.5 - off)
                        if vw < minW then vw = minW end
                    end
                    if vw < 1 then vw = 1 end
                    -- 弧段＝前後兩點都是這個轉角的圓弧點（弧第一點之前那段是外靠直線）
                    push(x, y, vw, ss[i - 1], true, (prevK == k - 1 and k > arc0 and k <= arc1) and plan.R or 0)
                    prevK = k
                end
            end
        else
            -- 最後一個節點的出臂短於到站半徑（MDADFollower.ARRIVE_M）＝車在轉之前就到站，不是要轉的角
            -- （正式服 0.23.0 片段 (13956.5,3757)：路線終點 0.7 m 殘段折 135°，列不可過→終點前 19 m 交還、改道圈蓋住終點全被 end 拒收）
            if c and not plan and c.turnAbs >= T.BLOCK_MIN_RAD
                    and not (i == np - 1 and c.lenOut < MDADFollower.ARRIVE_M) then
                blocked[#blocked + 1] = nx; blocked[#blocked + 1] = ny
                blockedR[#blockedR + 1] = sqrt(c.hwIn * c.hwIn + c.hwOut * c.hwOut)
            end
            push(nx, ny, wIn, ss[i - 1])
        end
    end
    push(pts[np * 2 - 1], pts[np * 2], sw[np - 1], ss[np - 1])
    -- 最後一段寬度／路面補齊（push 以「前一段」屬性記，最後一點需要 np-1 段）
    while #ow < #out / 2 - 1 do ow[#ow + 1], os[#os + 1], oa[#oa + 1] = sw[np - 1], ss[np - 1], 0 end
    local shaped = {}
    for k, v in pairs(route) do shaped[k] = v end
    shaped.pts, shaped.segWidth, shaped.segSurface, shaped.segArcR, shaped.towArcN = out, ow, os, oa, arcN
    shaped.towBlocked, shaped.towBlockedR = blocked, blockedR
    shaped.towSource = route
    cacheB, cacheA = cacheA, { route = route, tow = tow, shaped = shaped }
    return shaped
end

-- ---------------------------------------------------------------- 3. 行駛防線與倒車
-- 車頭—掛車折角（有號，rad，正＝牽引車航向比掛車大）與掛車 upVectorDot。掛車航向取拖行軸
-- （forward×axisSign，朝掛點）：倒著拖的車 forward 朝後，直接拿 forward 會讓直線時折角量成 180°。
function T.state(vehicle, tow)
    local ok, phi, up = pcall(function()
        local a = BaseVehicle.allocVector3f()
        local b = BaseVehicle.allocVector3f()
        vehicle:getForwardVector(a)
        tow.trailer:getForwardVector(b)
        local h1 = atan2(a:z(), a:x())
        local h2 = atan2(b:z(), b:x()) + (tow.axisSign == -1 and math.pi or 0)
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

-- 倒車折角還在上限內（讀不到＝不行）。Driver 起手（startRecoveryAttempt：超限＝rear=hitch 不吃額度）與
-- 倒車中（stepUnstick：已退出 UNSTICK_MIN_M＝倒夠了，否則同起手）共用。
function T.canReverse(phi)
    return phi ~= nil and abs(phi) <= T.REVERSE_HITCH_MAX
end

-- 掛車車身（倒車後方探測用）：中心、拖行軸（forward×axisSign，朝掛點；探測往它的反方向）、半寬、半長。
function T.body(tow)
    local ok, x, y, fx, fy = pcall(function()
        local tr = tow.trailer
        local c = tr:getWorldPos(tow.comX, 0, tow.comZ, Vector3f.new())
        local f = BaseVehicle.allocVector3f()
        tr:getForwardVector(f)
        local l = sqrt(f:x() * f:x() + f:z() * f:z())
        local sg = tow.axisSign == -1 and -1 or 1
        local ux, uy = sg * f:x() / l, sg * f:z() / l
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

-- 脫開當下的鑑識（1006；Driver 在 TrailerLost 交還前寫 tow phase=lost）：1002y 兩次平穩行駛中脫開，片段只有 tph／tup，
-- 分不出掛車被刪、被別台搶走、還是約束斷了。回 cur（牽引車 getVehicleTowing：nil／same／other；讀不到 nil）、
-- alive（getVehicleById(掛車 id) 找得到；沒記到 id 或沒有這個全域＝nil）、by（掛車 getVehicleTowedBy：nil／self／other）、
-- hd（牽引車掛點↔掛車掛點的世界距離，m）、kmh、up（掛車車速與 upVectorDot）。掛車已不存在就不讀它。只在交還時跑一次。
function T.lostState(vehicle, tow)
    local cur, alive, by, hd, kmh, up = nil, nil, nil, nil, nil, nil
    pcall(function()
        local c = vehicle:getVehicleTowing()
        cur = c == nil and "nil" or (c == tow.trailer and "same" or "other")
    end)
    local tr = tow.trailer
    if tow.id ~= nil and type(getVehicleById) == "function" then
        local okV, v = pcall(getVehicleById, tow.id)
        if okV then alive, tr = v ~= nil, v end
    end
    if tr == nil then return cur, alive, by, hd, kmh, up end
    pcall(function()
        local b = tr:getVehicleTowedBy()
        by = b == nil and "nil" or (b == vehicle and "self" or "other")
    end)
    pcall(function() kmh = tr:getCurrentSpeedKmHour() end)
    pcall(function() up = tr:getUpVectorDot() end)
    if tow.hitchSelf ~= nil and tow.hitchOther ~= nil then
        pcall(function()
            local a = vehicle:getTowingWorldPos(tow.hitchSelf, Vector3f.new())
            local b = tr:getTowedByWorldPos(tow.hitchOther, Vector3f.new())
            hd = dist(a:x(), a:y(), b:x(), b:y())
        end)
    end
    return cur, alive, by, hd, kmh, up
end

-- 拖車樣本（1008；Driver collectPhys 只在拖車時、每筆取樣讀一次，telemetry tlo／tla／tkm／thd）：掛車車位相對牽引車車位的
-- 縱向（車頭正）／橫向（右正，同 nb），fx, fy＝牽引車前向單位向量；掛車 km/h；hd（兩掛點世界距離 m，同 lostState）。
-- MP 同步拉回掛車時看得到位置跳動與 hd 尖峰（正式服 0.23.0 SemiTruckLite＋貨櫃週期性掉速，缺這幾欄定不了罪）。
-- 位置／車速與 hd 各自 pcall，讀不到的回 nil。
function T.sampleState(vehicle, tow, fx, fy)
    local tr = tow.trailer
    local lon, lat, kmh, hd = nil, nil, nil, nil
    pcall(function()
        local dx, dy = tr:getX() - vehicle:getX(), tr:getY() - vehicle:getY()
        lon, lat = dx * fx + dy * fy, dy * fx - dx * fy
        kmh = tr:getCurrentSpeedKmHour()
    end)
    if tow.hitchSelf ~= nil and tow.hitchOther ~= nil then
        pcall(function()
            local a = BaseVehicle.allocVector3f()
            local b = BaseVehicle.allocVector3f()
            local pa = vehicle:getTowingWorldPos(tow.hitchSelf, a)
            local pb = tr:getTowedByWorldPos(tow.hitchOther, b)
            hd = dist(pa:x(), pa:y(), pb:x(), pb:y())
            BaseVehicle.releaseVector3f(a)
            BaseVehicle.releaseVector3f(b)
        end)
    end
    return lon, lat, kmh, hd
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
    s.towPhi, s.towUp = phi, up -- telemetry tph／tup：脫掛前的折角與傾斜（TrailerLost 定罪用）
    if phi and (abs(phi) > T.HITCH_SLOW or (finite(up) and up < T.TILT_SLOW)) then cap = T.CRAWL_KMH end
    -- 剖面實際建構的那條（Driver.profileRouteOf：清過微反折再改寫）；拿原始路線重算會把資料殘點
    -- 當成不可過轉角（2026-09-28 正式服 SemiTruck 在 (5180,11145) 反折點前停下交還）
    local shaped = s.profileRoute or T.shape(s.route, tow)
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
