-- test_trailer.lua：MDAD_Trailer 純運動學契約（轉角外拉規劃、不可過判定、route 改寫、倒車回正方向）。
-- 幾何取 rSemiTruck W900＋SemiTrailerContainer（腳本×1.43，E2E 掛點對齊實測）。
local ROOT = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua/"
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

-- ⑥ attach（0929p 候選線掛車掃掠用的幾何）：掛點在牽引車座標、車身中心在「軸→掛點」座標、axisSign。
--    被倒著拖的車 forward 朝後：軸向要照量到的軸→掛點，不能照 forward（0929p 審查）。
local function V(x, y, z)
    return { _x = x, _y = y, _z = z,
        x = function(v) return v._x end, y = function(v) return v._y end, z = function(v) return v._z end,
        set = function(v, a, b, cc) v._x, v._y, v._z = a, b, cc; return v end }
end
Vector3f = { new = function() return V(0, 0, 0) end }
local function fakeTrailer(cx, fwdX, wheelZ)
    return {
        getScript = function() return {
            getExtents = function() return V(2.5, 1, 12) end,
            getCenterOfMassOffset = function() return V(0, 0, 0) end,
            getWheelCount = function() return 2 end,
            getWheel = function() return { getOffset = function() return V(0, 0, wheelZ) end } end,
        } end,
        getWorldPos = function(_, _, _, lz, out) return out:set(cx + fwdX * lz, 0, 0) end,
        getForwardVector = function(_, out) return out:set(fwdX, 0, 0) end,
        getMass = function() return 1500 end,
    }
end
local function fakeTractor(trl, hx)
    return {
        getVehicleTowing = function() return trl end,
        getTowAttachmentSelf = function() return "trailer" end,
        getTowingWorldPos = function(_, _, out) return out:set(hx, 0, 0) end,
        getForwardVector = function(_, out) return out:set(1, 0, 0) end,
        getX = function() return 0 end, getY = function() return 0 end,
    }
end
local function near(a, b) return type(a) == "number" and math.abs(a - b) < 1e-9 end
-- 正常掛車：車身中心 x=−8、長 12、軸在中心後 4（x=−12），掛點 x=−2（牽引車後 2m）
local gN = T.attach(fakeTractor(fakeTrailer(-8, 1, -4), -2))
check(type(gN) == "table" and near(gN.hitchZ, -2) and near(gN.hitchX, 0) and near(gN.boxBack, 6)
    and near(gN.boxSide, 0) and gN.axisSign == 1 and near(gN.trailLen, 14),
    "attach 正常掛車：掛點在車後 2m、車身中心在掛點後 6m、軸向同 forward、車位到掛車尾 14m")
-- 被倒著拖：forward 朝 −x，軸（輪子 local z=+2）仍在掛點後方 x=−10
local gR = T.attach(fakeTractor(fakeTrailer(-8, -1, 2), -5))
check(type(gR) == "table" and gR.axisSign == -1 and near(gR.L2, 5) and near(gR.boxBack, 3)
    and near(gR.trailLen, 8),
    "attach 被倒著拖（forward 朝後）：axisSign −1、車身中心仍在掛點後 3m（照軸→掛點，不照 forward）")

print(string.format("test_trailer: %d 項斷言、%d 項失敗", asserts, fails))
if fails > 0 then os.exit(1) end
