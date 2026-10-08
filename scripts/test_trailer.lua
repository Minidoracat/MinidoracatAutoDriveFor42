-- test_trailer.lua：MDAD_Trailer 純運動學契約（轉角外拉規劃、不可過判定、route 改寫、倒車回正方向）。
-- 幾何取 rSemiTruck W900＋SemiTrailerContainer（腳本×1.43，E2E 掛點對齊實測）。
local ROOT = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua/"
dofile(ROOT .. "shared/MDAD_Dynamics.lua") -- shape 的虛擬路寬下限讀 ROAD_EDGE_MARGIN；⑩ 用路寬證明
dofile(ROOT .. "shared/MDAD_Follower.lua") -- shape 讀 MDADFollower.ARRIVE_M（終點殘段不列不可過）
dofile(ROOT .. "client/MDAD_Trailer.lua")
local T = MDADTrailer

local fails, asserts = 0, 0
local function check(c, msg)
    asserts = asserts + 1
    if not c then fails = fails + 1; print("[FAIL] " .. msg) end
end

local G = { L2 = 9.5, rear = 12.0, hw = 1.27, front = 7.1, thw = 1.19 }

-- ① 12m 路直角轉 6m 路：要外拉才過，且外拉方向在轉彎外側。
local c = T.cornerOf(-60, 0, 0, 0, 0, 60, 12, 6)
local t0 = os.clock()
local plan = T.planCorner(c, G)
local ms = (os.clock() - t0) * 1000
check(plan ~= nil, "12m→6m 90° 有可行走法")
check(plan and plan.a > 0, "12m→6m 需要外拉（置中轉不過）: a=" .. tostring(plan and plan.a))
check(ms < 500, string.format("單一轉角規劃 <500ms（實測 %.0fms）", ms))
-- 轉向往 +y（右轉，y 向南）：內側是 +y，外拉＝往 -y
local tow = { L2 = G.L2, hitchToRear = G.rear, halfW = G.hw }
local route = { pts = { -60, 0, 0, 0, 0, 60 }, segWidth = { 12, 6 }, segSurface = { "paved", "paved" } }
local shaped = T.shape(route, tow, G.thw, G.front)
local minY = 0
for k = 2, #shaped.pts, 2 do if shaped.pts[k] < minY then minY = shaped.pts[k] end end
check(minY < -0.4, "外拉往轉彎外側（-y）: minY=" .. minY)
check(#shaped.towBlocked == 0, "可過轉角不列 blocked")
check(#shaped.segWidth == #shaped.pts / 2 - 1 and #shaped.segSurface == #shaped.segWidth,
    "route 改寫後段屬性數量對齊點數")
local okW = true
for i = 1, #shaped.segWidth do
    local w = shaped.segWidth[i]
    if type(w) ~= "number" or w < 1 or w > 64 then okW = false end
end
check(okW, "所有段寬落在 Follower 接受範圍 [1,64]")
check(T.shape(route, tow, G.thw, G.front) == shaped, "同一路線同一掛車回快取（Driver 以原 identity 比對）")
check(shaped.towSource == route, "改寫線記得原路線")

-- ② 4m 窄巷直角：不可過
local narrow = { pts = { -60, 0, 0, 0, 0, 60 }, segWidth = { 4, 4 }, segSurface = { "paved", "paved" } }
local ns = T.shape(narrow, tow, G.thw, G.front)
check(#ns.towBlocked == 2 and ns.towBlocked[1] == 0 and ns.towBlocked[2] == 0, "4m 巷直角列為不可過轉角")
local d = T.nearestBlocked(ns, 0, -20)
check(d and math.abs(d - 20) < 1e-6, "nearestBlocked 回世界距離")

-- ②b Fallas 143°（KY-60 17m→支路 7m，Workshop 回報翻車點）：外靠＋轉出偏移後可過
local fal = T.cornerOf(5150, 11129.5, 5244.6, 11176.8, 5230, 11147.5, 17, 7)
local fp = T.planCorner(fal, G)
check(fp ~= nil and fp.a > 0, "Fallas 143° 用外拉大彎可過: " .. tostring(fp and (fp.a .. "/" .. fp.b)))

-- ②c 改寫後的路線不得往回折（轉出偏移段畫過下一點＝Follower 判成原地調頭）
local falRoute = { pts = { 5150, 11129.5, 5244.6, 11176.8, 5230, 11147.5, 5217.5, 11122.5 },
    segWidth = { 17, 7, 7 }, segSurface = { "paved", "paved", "paved" } }
local fs = T.shape(falRoute, tow, G.thw, G.front)
local maxTurn = 0
for k = 3, #fs.pts - 3, 2 do
    local ax, ay = fs.pts[k] - fs.pts[k - 2], fs.pts[k + 1] - fs.pts[k - 1]
    local bx, by = fs.pts[k + 2] - fs.pts[k], fs.pts[k + 3] - fs.pts[k + 1]
    local turn = math.abs(math.atan2(ax * by - ay * bx, ax * bx + ay * by))
    if turn > maxTurn then maxTurn = turn end
end
check(#fs.towBlocked == 0 and maxTurn < math.pi / 2,
    string.format("Fallas 改寫線無折返（最大相鄰折角 %.0f°）", math.deg(maxTurn)))

-- ②d 相鄰轉角段很短（0.13.1 正式服 StepVan＋掛車 clip-31：90° 左轉接 13m 後 28° 彎）：前一個轉角的轉出點
-- 已畫進本段、下一個轉角的外靠點又從段中起算，舊版在 (10853,9976) 折返 176°＝Follower 判原地調頭交還。
-- 違規證明：拿掉 push 的 fold 撤點＝紅。
local shortPts = { 10857, 10055, 10857, 10016.5, 10857, 9976, 10844, 9976, 10831, 9969, 10825, 9963,
    10819, 9944, 10819, 9900 }
local shortRoute = { pts = shortPts, segWidth = { 4, 4, 8, 8, 8, 8, 8 },
    segSurface = { "paved", "paved", "paved", "paved", "paved", "paved", "paved" } }
local smallTow = { L2 = 3.2, hitchToRear = 4.2, halfW = 0.9 }
local ss2 = T.shape(shortRoute, smallTow, 1.1, 6)
local maxShort, atX, atY = 0, 0, 0
for k = 3, #ss2.pts - 3, 2 do
    local ax, ay = ss2.pts[k] - ss2.pts[k - 2], ss2.pts[k + 1] - ss2.pts[k - 1]
    local bx, by = ss2.pts[k + 2] - ss2.pts[k], ss2.pts[k + 3] - ss2.pts[k + 1]
    local turn = math.abs(math.atan2(ax * by - ay * bx, ax * bx + ay * by))
    if turn > maxShort then maxShort, atX, atY = turn, ss2.pts[k], ss2.pts[k + 1] end
end
check(maxShort <= math.pi / 2 + 1e-6, string.format("短段相鄰轉角改寫線無折返（最大相鄰折角 %.0f° 在 %.1f,%.1f）",
    math.deg(maxShort), atX, atY))
check(#ss2.segWidth == #ss2.pts / 2 - 1 and #ss2.segSurface == #ss2.segWidth, "撤點後段屬性數量仍對齊點數")

-- ③ 小折角不動
local gentle = { pts = { -60, 0, 0, 0, 60, 10 }, segWidth = { 8, 8 }, segSurface = { "paved", "paved" } }
local gs = T.shape(gentle, tow, G.thw, G.front)
check(#gs.pts == 6, "小於門檻的折角原樣保留")

-- ③b 可行的走法取最大半徑，不取最小的 R=4（GitHub #6：StepVan＋原版掛車連 28° 寬彎都排成 R=4 圓弧，剖面
--    sqrt(aLat·4) 壓到 12 km/h 地板；玩家路線離線剖面 27 個轉角全是 12.0）。另驗切點不超過臂長份額。
--    違規證明：planCorner 改回 R 由 4 往上取第一個可行＝紅；拿掉臂長份額判斷＝短段直角紅。
local GV = { L2 = 1.79, rear = 2.67, hw = 0.57, front = 4.24, thw = 0.81 } -- StepVan＋Base.Trailer（腳本×1.82）
local wide = T.planCorner(T.cornerOf(6737, 6700, 6737, 6663, 6754, 6630, 8, 8), GV)
check(wide and wide.R >= 20, "28° 寬彎 8m 路取大半徑: R=" .. tostring(wide and wide.R))
local right = T.planCorner(T.cornerOf(-60, 0, 0, 0, 0, 60, 8, 8), GV)
check(right and right.R > 4 and right.a == 0 and right.b == 0,
    "8m 路直角：不外拉、半徑大於 4: R=" .. tostring(right and right.R))
-- 圓弧切點不得超過相鄰段長一半（下一個轉角的圓弧從另一半開始，重疊＝撤點折線）
local shortC = T.cornerOf(-12, 0, 0, 0, 0, 12, 8, 8)
local sp = T.planCorner(shortC, GV)
check(sp and sp.sIn >= -0.5 * shortC.lenIn - 1e-6 and sp.sOut <= 0.5 * shortC.lenOut + 1e-6,
    "12m 短段直角：切點在段長一半內: sIn=" .. tostring(sp and sp.sIn) .. " sOut=" .. tostring(sp and sp.sOut))
-- ③c 20–25° 小彎也改寫（改寫線點數超過 Follower 圓角容量，留著的 ≥20° 頂點會被標 fallback 爬行 12 km/h），
--    但規劃不出來時照舊保留頂點、不列不可過（舊制 <25° 本來就照開，不得因此新增 TrailerCorner）。
--    違規證明：TURN_MIN_RAD 改回 25°＝第一項紅；拿掉 BLOCK_MIN_RAD 判斷＝第二項紅。
local k22 = { pts = { -60, 0, 0, 0, 60 * math.cos(math.rad(22)), 60 * math.sin(math.rad(22)) },
    segWidth = { 8, 8 }, segSurface = { "paved", "paved" } }
check(#T.shape(k22, tow, G.thw, G.front).pts > 6, "22° 小彎改寫成圓弧")
local k22n = { pts = k22.pts, segWidth = { 2, 2 }, segSurface = { "paved", "paved" } }
local s22n = T.shape(k22n, tow, G.thw, G.front)
check(#s22n.towBlocked == 0 and #s22n.pts == 6, "規劃不出來的 22° 小彎保留頂點、不列不可過")
-- ③d 連續小折點組成的彎（玩家路線 (6973.5,7540)→(7003,7569)，四個 18–25° 折點、臂長 13–16m）：前一個圓弧畫到
--    下一臂的 SEG_SHARE，下一個轉角不外靠的進入段若從臂長 0.9 處起算＝撤點把弧截成 40°+ 折點。
--    違規證明：shape 的 a＝0 進入段改回 0.9 臂長起留＝紅（42°）。
local curvePts = { 6950, 7529, 6973.5, 7540, 6986, 7546, 6997.5, 7557, 7003, 7569, 7003, 7585, 7003, 7650 }
local cs4 = T.shape({ pts = curvePts, segWidth = { 8, 8, 8, 8, 8, 8 },
    segSurface = { "paved", "paved", "paved", "paved", "paved", "paved" } },
    { L2 = GV.L2, hitchToRear = GV.rear, halfW = GV.hw }, GV.thw, GV.front)
local maxCurve = 0
for k = 3, #cs4.pts - 3, 2 do
    local ax, ay = cs4.pts[k] - cs4.pts[k - 2], cs4.pts[k + 1] - cs4.pts[k - 1]
    local bx, by = cs4.pts[k + 2] - cs4.pts[k], cs4.pts[k + 3] - cs4.pts[k + 1]
    local turn = math.abs(math.atan2(ax * by - ay * bx, ax * bx + ay * by))
    if turn > maxCurve then maxCurve = turn end
end
check(maxCurve < math.rad(20), string.format("連續小折點的改寫線無 ≥20° 折點（最大 %.1f°）", math.deg(maxCurve)))

-- ③e 大半徑不得讓掛車比最小可行半徑更切內（1006 E2E semi-corner：#6 取最大半徑後 Dixie 14m→8m 直角 R 6→12，
--    牽引車走大弧＝弧中點往彎內移，掛車車身出路 0.07→0.71m，撞上彎內角 0.8m 外的路邊物）。幾何取 E2E 實測
--    SemiTruck＋貨櫃（tow attach L2 7.99、trailLen 12.38、hitchZ −2.23、halfW 1.16；牽引車 halfW 0.95、halfL 3.41）。
--    違規證明：planCorner 拿掉「cut ≤ baseCut＋CUT_TOL」＝兩項紅。
local GS = { L2 = 7.994, rear = 12.377 - 2.233, hw = 1.16, front = 3.41 * 2, thw = 0.95 }
local function cutOf(cc, p)
    local ramp = (p.a > 0 or p.b ~= 0) and T.RAMP_MAX or T.RAMP_MIN
    local n, xs, ys = T._candidate(cc, p.a, p.b, p.R, ramp, p.approach, p.exitLen)
    local _, _, _, cut = T._simulate(cc, xs, ys, n, GS)
    return cut
end
local function baseOf(cc, p)
    for R = T.R_MIN, 60, 2 do
        local q = { a = p.a, b = p.b, R = R, approach = p.approach, exitLen = p.exitLen }
        local ramp = (p.a > 0 or p.b ~= 0) and T.RAMP_MAX or T.RAMP_MIN
        local n, xs, ys = T._candidate(cc, p.a, p.b, R, ramp, p.approach, p.exitLen)
        if n > 3 and T._simulate(cc, xs, ys, n, GS) then return q end
    end
end
for _, cc in ipairs({
    { "Dixie 14m→8m 直角", T.cornerOf(10592, 9600, 10592, 9627, 10642, 9627, 14, 8), 0.2 },
    { "Fallas 90° 接 72°（第二彎）", T.cornerOf(5244.6, 11176.8, 5249.5, 11167, 5230, 11147.5, 7, 7), nil },
}) do
    local p = T.planCorner(cc[2], GS)
    local cut, base = p and cutOf(cc[2], p), p and baseOf(cc[2], p)
    local baseCut = base and cutOf(cc[2], base)
    check(p and base and cut <= baseCut + T.CUT_TOL + 1e-9,
        string.format("%s：掛車出路不比最小可行半徑多（R=%s 出路 %.2f／R=%s 出路 %.2f）", cc[1],
            tostring(p and p.R), cut or -1, tostring(base and base.R), baseCut or -1))
    if cc[3] then
        check(cut and cut <= cc[3], string.format("%s：掛車出路 ≤%.1fm（實測 %.2f）", cc[1], cc[3], cut or -1))
    end
end

-- ④ 倒車回正：牽引車航向變化率＝steer（正＝航向增加），掛車 θ2' = v/L2·sin(θ1-θ2)，v<0。
local function reverseRun(control)
    local th1, th2, v, dt = 0.2, 0, -1.5, 0.05
    for _ = 1, 200 do
        local phi = T.wrap(th1 - th2)
        local steer = control and T.reverseSteer(phi) or 0
        th1 = th1 + steer * 0.25 * dt
        th2 = th2 + v / G.L2 * math.sin(th1 - th2) * dt
    end
    return math.abs(T.wrap(th1 - th2))
end
check(reverseRun(false) > 0.2, "沒控制時倒車折角發散（證明模型有意義）")
check(reverseRun(true) < 0.02, "reverseSteer 把倒車折角拉回 0")

-- ⑤ 模擬器本身：直線行駛折角 0、不出路面
local cs = T.cornerOf(-60, 0, 0, 0, 0, 60, 12, 6)
local xs, ys = {}, {}
for i = 1, 100 do xs[i], ys[i] = -59 + i * 0.5, 0 end
local ok, hitch, outM = T._simulate(cs, xs, ys, 100, G)
check(ok and hitch < 1e-6 and outM == 0, "直線：折角 0、不出路面")

-- ⑥ attach（0929p 候選線掛車掃掠用的幾何；1002a 拖法通用化）：掛點在牽引車座標、車身中心在「軸→掛點」座標、
--    axisSign。假車沿 x 軸：牽引車在 0、朝 +x；被拖車車心 cx、forward fwd（±1）、輪 local z、模型 offset z、自己的掛點 local z。
local function V(x, y, z)
    return { _x = x, _y = y, _z = z,
        x = function(v) return v._x end, y = function(v) return v._y end, z = function(v) return v._z end,
        set = function(v, a, b, cc) v._x, v._y, v._z = a, b, cc; return v end }
end
Vector3f = { new = function() return V(0, 0, 0) end }
BaseVehicle = { allocVector3f = function() return V(0, 0, 0) end, releaseVector3f = function() end }
local function fakeTrailer(o)
    return {
        getScript = function() return {
            getExtents = function() return V(o.w or 2.5, 1, o.len) end,
            getCenterOfMassOffset = function() return V(0, 0, 0) end,
            getModelOffset = function() return o.mz and V(0, 0, o.mz) or nil end,
            getWheelCount = function() return 2 end,
            getWheel = function() return { getOffset = function() return V(0, 0, o.wheelZ) end } end,
        } end,
        getWorldPos = function(_, _, _, lz, out) return out:set(o.cx + o.fwd * lz, 0, 0) end,
        getForwardVector = function(_, out) return out:set(o.fwd, 0, 0) end,
        getMass = function() return 1500 end,
        getScriptName = function() return o.name end,
        getTowAttachmentSelf = function() return "self" end,
        getTowingWorldPos = function(_, _, out) return out:set(o.cx + o.fwd * o.attZ, 0, 0) end,
        getUpVectorDot = function() return 1 end,
    }
end
local function fakeTractor(trl, hx)
    return {
        getVehicleTowing = function() return trl end,
        getTowAttachmentSelf = function() return "trailer" end,
        getTowingWorldPos = function(_, _, out) return out:set(hx, 0, 0) end,
        getForwardVector = function(_, out) return out:set(1, 0, 0) end,
        getX = function() return 0 end, getY = function() return 0 end,
        getScriptName = function() return "Base.PickUpTruck" end,
    }
end
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end
-- 掛車（腳本名含 Trailer＝剛性連結，不補繩長）：車身中心 x=−8、長 12、軸在中心後 4（x=−12），掛點 x=−2
local gN = T.attach(fakeTractor(fakeTrailer({ name = "Base.Trailer", cx = -8, fwd = 1, len = 12, wheelZ = -4,
    attZ = 6 }), -2))
check(type(gN) == "table" and near(gN.hitchZ, -2) and near(gN.hitchX, 0) and near(gN.L2, 10)
    and near(gN.boxBack, 6) and near(gN.boxSide, 0) and gN.axisSign == 1 and near(gN.trailLen, 14),
    "attach 正常掛車：掛點在車後 2m、L2 10、車身中心在掛點後 6m、軸向同 forward、車位到掛車尾 14m")
-- Autotsar KBAC（Workshop 3402493701，腳本×1.9）：輪 offset z +1.25 被模型 offset −1.25 抵銷＝軸在車心；
-- 掛點（attachment 3.31＋模型 −1.25）在車心前 2.06。漏加模型 offset＝軸量到掛點旁、L2 0.81 拒絕啟動（玩家實例）。
local gK = T.attach(fakeTractor(fakeTrailer({ name = "Base.TrailerKbac", cx = -4.06, fwd = 1, w = 1.2, len = 1.78,
    wheelZ = 1.25, mz = -1.25, attZ = 2.06 }), -2))
check(type(gK) == "table" and near(gK.L2, 2.06) and gK.axisSign == 1,
    "attach 模型 offset：KBAC 的軸在車心、L2＝2.06（不是 0.81）")
-- 一般車互拖、車尾對車尾（原版 TowMenu 先試 trailer↔trailer）：被拖車朝 −x 倒著走、車尾掛點在 x=−2.5，
-- 繩子還鬆 0.5m（兩台都不是 Trailer＝繩索 1.5m）。掛車尾＝被拖車的車頭 x=−7.1。
local gB = T.attach(fakeTractor(fakeTrailer({ name = "Base.SmallCar", cx = -4.8, fwd = -1, len = 4.6, wheelZ = 0,
    attZ = -2.3 }), -2))
check(type(gB) == "table" and gB.axisSign == -1 and near(gB.L2, 2.8 + 1.0) and near(gB.hitchToRear, 5.1 + 1.0)
    and near(gB.boxBack, 2.8 + 1.0) and near(gB.trailLen, 2 + 5.1 + 1.0),
    "attach 車尾對車尾：axisSign −1、尾端取被拖車車頭、軸向長度補上沒拉直的繩長 1.0")
-- 一般車互拖、車尾對車頭：同樣補繩長
local gF = T.attach(fakeTractor(fakeTrailer({ name = "Base.SmallCar", cx = -4.7, fwd = 1, len = 4.6, wheelZ = 0,
    attZ = 2.3 }), -2))
check(type(gF) == "table" and gF.axisSign == 1 and near(gF.L2, 2.7 + 1.1) and near(gF.hitchToRear, 5.0 + 1.1),
    "attach 車尾對車頭（繩索）：L2 與尾端都補繩長 1.1")
-- 掛在牽引車車頭前方（原版 trailerfront↔trailer）：自駕只會往前開＝推著那台車，拒絕並給專屬原因
local gP = T.attach(fakeTractor(fakeTrailer({ name = "Base.SmallCar", cx = 5.3, fwd = 1, len = 4.6, wheelZ = 0,
    attZ = -2.3 }), 2.5))
check(gP == T.KEY_FRONT, "attach 掛在車頭前方：回 KEY_FRONT（got " .. tostring(gP) .. "）")
check(T.attach(fakeTractor(fakeTrailer({ name = "Base.Trailer", cx = -8, fwd = 1, len = 12, wheelZ = -4, attZ = 6,
    w = 0.4 }), -2)) == T.KEY_UNSUPPORTED, "attach 量到不合理的寬度：回 KEY_UNSUPPORTED")
-- 折角／倒車探測照拖行軸：倒著拖的車直線時折角 0（照 forward 會量成 180° 而永遠爬行 5 km/h）
local trB = fakeTrailer({ name = "Base.SmallCar", cx = -4.8, fwd = -1, len = 4.6, wheelZ = 0, attZ = -2.3 })
local trac = fakeTractor(trB, -2)
local phiB = T.state(trac, { trailer = trB, axisSign = -1 })
check(near(phiB, 0), "state 倒著拖直線：折角 0（got " .. tostring(phiB) .. "）")
local bx, by, bfx, bfy = T.body({ trailer = trB, axisSign = -1, comX = 0, comZ = 0, halfW = 0.9, halfL = 2.3 })
check(near(bx, -4.8) and near(bfx, 1) and near(bfy, 0),
    "body 倒著拖：拖行軸朝掛點（+x），倒車探測往 −x")

-- ⑦ 1006 脫開鑑識（T.lostState；Driver 在 TrailerLost 交還前寫 tow phase=lost——1002y 兩次平穩行駛中脫開只有 tph／tup
--    查不下去）：attach 記下掛車 id 與兩邊掛點名；脫開後量「牽引車掛著誰」「掛車還在不在（getVehicleById）」「掛車被誰拖」
--    「兩掛點距離」「掛車速度／傾斜」。違規證明：attach 不記 id＝(alive) 紅；距離不用記下的掛車掛點名＝(hd) 紅；
--    cur 分不出別台＝(other) 紅；不查 getVehicleById＝(gone) 紅。
local trL = fakeTrailer({ name = "Base.Trailer", cx = -8, fwd = 1, len = 12, wheelZ = -4, attZ = 6 })
trL.getId = function() return 42 end
trL.getCurrentSpeedKmHour = function() return 37.5 end
trL.getUpVectorDot = function() return 0.6 end
trL.getVehicleTowedBy = function() return nil end
trL.getTowedByWorldPos = function(_, name, out)
    if name ~= "trailerfront" then return nil end
    return out:set(-5, 0, 0)
end
local tracL = fakeTractor(trL, -2)
tracL.getTowAttachmentOther = function() return "trailerfront" end
local gL = T.attach(tracL)
check(type(gL) == "table" and gL.id == 42 and gL.hitchSelf == "trailer" and gL.hitchOther == "trailerfront",
    "attach 記下掛車 id 與兩邊掛點名")
tracL.getVehicleTowing = function() return nil end
getVehicleById = function(id) if id == 42 then return trL end end
local cur, alive, by, hd, kmh, up = T.lostState(tracL, gL)
check(cur == "nil" and alive == true and by == "nil", "(alive) 脫開：牽引車沒掛東西、掛車還在、掛車沒被拖（got "
    .. tostring(cur) .. "/" .. tostring(alive) .. "/" .. tostring(by) .. "）")
check(near(hd, 3), "(hd) 兩掛點距離 3m（got " .. tostring(hd) .. "）")
check(near(kmh, 37.5) and near(up, 0.6), "掛車速度與 upVectorDot")
tracL.getVehicleTowing = function() return {} end
check((T.lostState(tracL, gL)) == "other", "(other) 牽引車掛著別台")
getVehicleById = function() return nil end
cur, alive, by, hd = T.lostState(tracL, gL)
check(alive == false and by == nil and hd == nil, "(gone) 掛車已不存在：alive=false、不量距離")
getVehicleById = nil

-- ⑧ 1008 拖車樣本（T.sampleState；collectPhys 每筆取樣讀一次，telemetry tlo／tla／tkm／thd）：掛車相對牽引車的縱向（車頭正）
--    ／橫向（右正，同 nb；朝 +x 時世界 +y＝右）、掛車 km/h、兩掛點距離；掛點讀不到只少 hd。
--    違規證明：橫向符號反了＝(lat) 紅；hd 不用記下的掛車掛點名＝(thd) 紅；位置與 hd 共用一個 pcall＝(hd-fail) 紅。
tracL.getVehicleTowing = function() return trL end
trL.getX = function() return -8 end
trL.getY = function() return 1.5 end
local lon, lat, skmh, shd = T.sampleState(tracL, gL, 1, 0)
check(near(lon, -8) and near(lat, 1.5), "(lat) 掛車在牽引車後 8m、右側 1.5m（got " .. tostring(lon) .. "," .. tostring(lat) .. "）")
check(near(skmh, 37.5) and near(shd, 3), "(thd) 掛車 km/h 與兩掛點距離（got " .. tostring(skmh) .. "," .. tostring(shd) .. "）")
trL.getTowedByWorldPos = function() error("hitch") end
lon, lat, skmh, shd = T.sampleState(tracL, gL, 1, 0)
check(near(lon, -8) and near(skmh, 37.5) and shd == nil, "(hd-fail) 掛點讀不到只少 hd")

-- ⑨ 1008 正式服 0.23.0 拖車轉角的兩個過度保守（temp/prod1008/report-trailer.md F1／F2）與倒車折角門檻。
--   (front) 外拉規劃的車頭懸伸從量到的掛點起算（T.hitchFront＝halfL−hitchZ）：第五輪 SemiTruckLite＋SemiTrailerVan
--           （正式服 0.23.0 案例 A）在 6m→6m 直角 (14013,2263)：整車長 7.20 判不可過、實值 5.83 可過；量不到 hitchZ
--           退回整車長。違規證明：hitchFront 恆回整車長＝紅。
--   (stub)  路線終點 0.7m 殘段折 135°（正式服 0.23.0 案例 B，(13956.5,3757)）不列不可過；同一個角出臂 6m（> ARRIVE_M）照列。
--           違規證明：拿掉出臂條件＝stub 紅；出臂門檻改恆真＝6m 紅。
--   (rev)   canReverse：上限內可倒、超過或讀不到不行。違規證明：nil 當可倒＝紅。
do
    local nrTow = { L2 = 6.715, hitchToRear = 8.880, halfW = 1.10, hitchZ = -2.23 }
    local front = T.hitchFront(nrTow, 3.60)
    check(math.abs(front - 5.83) < 1e-9, "(front) 第五輪：掛點→車頭＝halfL−hitchZ（got " .. tostring(front) .. "）")
    check(T.hitchFront({ L2 = 6.715 }, 3.60) == 7.2, "(front) 量不到 hitchZ 退回整車長")
    local function nr() return { pts = { 14013, 2171, 14013, 2263, 14100, 2263 }, segWidth = { 6, 6 },
        segSurface = { "paved", "paved" } } end
    check(#T.shape(nr(), nrTow, 1.06, 7.20).towBlocked == 2, "(front) 整車長 7.20：6m 直角判不可過（舊制誤判）")
    check(#T.shape(nr(), nrTow, 1.06, front).towBlocked == 0, "(front) 實值 5.83：同一個直角可過")

    local tmTow = { L2 = 5.773, hitchToRear = 9.533, halfW = 1.11 }
    local stub = T.shape({ pts = { 13800, 3757, 13956.5, 3757, 13956, 3757.5 }, segWidth = { 4, 3 },
        segSurface = { "paved", "paved" } }, tmTow, 1.09, 7.16)
    check(#stub.towBlocked == 0, "(stub) 終點 0.7m 殘段 135° 不列不可過（n=" .. #stub.towBlocked / 2 .. "）")
    local d = 6 / math.sqrt(2)
    local long = T.shape({ pts = { 13800, 3757, 13956.5, 3757, 13956.5 - d, 3757 + d }, segWidth = { 4, 3 },
        segSurface = { "paved", "paved" } }, tmTow, 1.09, 7.16)
    check(#long.towBlocked == 2, "(stub) 同一個角出臂 6m（> ARRIVE_M）照列不可過")

    local lim = T.REVERSE_HITCH_MAX
    check(T.canReverse(0) and T.canReverse(-lim) and not T.canReverse(lim + 0.01) and not T.canReverse(-lim - 0.01)
        and not T.canReverse(nil), "(rev) 倒車折角門檻：上限內可倒、超過或讀不到不行")
end

-- ⑩ 1008 改寫段要過 Follower 路寬證明、圓弧要標出來（正式服 0.23.0：虛擬路寬下限 2·thw+0.4 每側只留 0.2，證明要 0.4＝
--    改寫段 verifyLineReason 永遠 band→obb 帽 18；弧點照抄成 LINE＝Follower 看不到曲率、沒有前饋，切弦內切）。
--    證明照 Driver buildSnapshotProof：每條弦（兩端同一 raw 段）以牽引車半寬 chordCoveredByBand。幾何同 ①、正式服 0.23.0
--    片段 SemiTruckBox_mil（halfW 1.03、halfL 4.12）＋M101A3（tow attach L2 2.33、trailLen 7.67、hitchZ −4.39、halfW 0.98）。
--    違規證明：下限改回 2·thw+0.4＝(band) 紅；push 不帶弧半徑＝(arc) 紅。
local D = MDADDynamics
for _, cc in ipairs({
    { "12m→6m 直角＋W900 貨櫃", route, tow, G.thw, G.front },
    { "8m 直角＋SemiTruckBox_mil", { pts = { 8644.0, 8388.5, 8644.034, 8400.0, 8644.5, 8562.0, 8449.0, 8562.0, 8400.0, 8562.0 },
        segWidth = { 8, 8, 8, 8 }, segSurface = { "paved", "paved", "paved", "paved" } },
        { L2 = 2.327, hitchToRear = 7.670 - 4.385, halfW = 0.98 }, 1.03, 4.12 * 2 },
}) do
    local sh = T.shape(cc[2], cc[3], cc[4], cc[5])
    local bandBad, narrowN, arcN, arcTurn, badR = 0, 0, 0, 0, nil
    local plan
    for v = 2, #cc[2].pts / 2 - 1 do
        local p = cc[2].pts
        local cv = T.cornerOf(p[v * 2 - 3], p[v * 2 - 2], p[v * 2 - 1], p[v * 2], p[v * 2 + 1], p[v * 2 + 2],
            cc[2].segWidth[v - 1], cc[2].segWidth[v])
        plan = plan or (cv and T.planCorner(cv, { L2 = cc[3].L2, rear = cc[3].hitchToRear, hw = cc[3].halfW,
            front = cc[5], thw = cc[4] }))
    end
    for i = 1, #sh.segWidth do
        local x0, y0, x1, y1 = sh.pts[i * 2 - 1], sh.pts[i * 2], sh.pts[i * 2 + 1], sh.pts[i * 2 + 2]
        if sh.segWidth[i] < 6 then
            narrowN = narrowN + 1
            if not D.chordCoveredByBand(sh.pts, sh.segWidth, i, i, cc[4], x0, y0, x1, y1) then bandBad = bandBad + 1 end
        end
        local r = sh.segArcR[i]
        if r > 0 then
            arcN = arcN + 1
            if r ~= plan.R then badR = r end
            if i > 1 and sh.segArcR[i - 1] > 0 then
                local ha = math.atan2(sh.pts[i * 2] - sh.pts[i * 2 - 2], sh.pts[i * 2 - 1] - sh.pts[i * 2 - 3])
                local hb = math.atan2(y1 - y0, x1 - x0)
                arcTurn = arcTurn + math.abs(T.wrap(hb - ha))
            end
        end
    end
    check(narrowN > 0 and bandBad == 0, string.format("(band) %s：改寫段 %d 條弦過路寬證明（失敗 %d）", cc[1], narrowN, bandBad))
    check(#sh.segArcR == #sh.segWidth and sh.towArcN == 1 and arcN > 0 and badR == nil
        and math.abs(arcTurn - math.pi / 2) < math.rad(10),
        string.format("(arc) %s：segArcR 對齊段數、弧 %d 段半徑＝規劃 R %s、弧內轉角 %.0f°", cc[1], arcN,
            tostring(plan and plan.R), math.deg(arcTurn)))
end

print(string.format("test_trailer: %d 項斷言、%d 項失敗", asserts, fails))
if fails > 0 then os.exit(1) end
