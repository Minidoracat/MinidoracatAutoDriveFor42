--[[
離線實驗（非閘門）：yaw-rate 內環是否值得加到跟線控制器。

    lua scripts/exp_yawrate_inner.lua

A＝現制（真 MDADFollower.control − 真 crossTrackSteer）；B＝同外環＋固定增益 yaw-rate P 內環。
Plant：自行車＋一階 yaw 延遲。旋鈕：TAU、K_OMEGA（下方）。印貼縫落後／S 彎翻號率對照表，
沒有斷言（除有限性）。背景與結論見 AGENTS.md「Derpy BackStepping-MFAC 評估」條。
]]

local MEDIA = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua"
local ROOTS = { "", "../" }
local function loadProduction(rel)
    for _, root in ipairs(ROOTS) do
        local path = root .. MEDIA .. "/" .. rel
        local fh = io.open(path, "r")
        if fh then
            fh:close()
            local chunk, err = loadfile(path)
            if not chunk then error("載入失敗：" .. tostring(err)) end
            chunk()
            return path
        end
    end
    error("找不到 " .. rel)
end
loadProduction("shared/MDAD_Dynamics.lua")
loadProduction("shared/MDAD_Follower.lua")
local F, D = MDADFollower, MDADDynamics

local KMH = 3.6
local KAPPA_MAX = 1 / 4.0 -- 轉向飽和曲率（rMin 4m；本 MOD 廂型車 profile rMin 2.9、F350 4.3）
local TAU = 0.35          -- yaw 一階延遲（秒）——旋鈕
local K_OMEGA = 1.0       -- 內環 P 增益——旋鈕
local STEER_MAX = F.STEER_MAX

local function buildRoute(pts)
    local p = F.begin({ pts = pts }, 60)
    local calls = 0
    while not p.ready and calls < 100000 do F.stepBuild(p, 4096); calls = calls + 1 end
    assert(p.ready, "stepBuild 沒收斂")
    return p
end

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- 一步：回 steer 命令（含 cross-track）與更新後的車態
local function stepCar(variant, prof, st, car, dt, gapCtx)
    local steer, tspd, _, reached, err, _, latSigned = F.control(prof, st, car.x, car.y, car.h, car.spd, dt)
    -- cross-track PD（與 Driver 同式：latDev＝實際橫向 − 期望 lane；貼縫時增益 ×3／上限 2.5）
    local xt = 0
    if gapCtx then
        local expL = gapCtx.laneAt(car.x)
        local latDev = car.y - expL
        local dLat = nil
        if car.prevLat ~= nil then dLat = (latDev - car.prevLat) / dt end
        car.prevLat = latDev
        xt = D.crossTrackSteer(latDev, car.spd, dLat, D.CROSS_TRACK_DODGE_GAIN, D.CROSS_TRACK_DODGE_MAX)
        car.latDev = latDev
    end
    local u = steer - xt
    if u > STEER_MAX then u = STEER_MAX elseif u < -STEER_MAX then u = -STEER_MAX end
    local v = car.spd / KMH
    if variant == "B" then
        -- 外環輸出當期望 yaw-rate；固定增益 P 內環補 plant 延遲，換算回 steer 單位後疊加
        local wDes = (u / STEER_MAX) * KAPPA_MAX * v
        local wErr = wDes - car.w
        local denom = KAPPA_MAX * v
        if denom > 1e-6 then
            u = u + K_OMEGA * STEER_MAX * wErr / denom
        end
        if u > STEER_MAX then u = STEER_MAX elseif u < -STEER_MAX then u = -STEER_MAX end
    end
    -- plant：命令曲率 → 目標 yaw-rate，一階延遲追上
    local wCmd = (u / STEER_MAX) * KAPPA_MAX * v
    car.w = car.w + (wCmd - car.w) * (dt / TAU)
    car.h = car.h + car.w * dt
    car.x = car.x + math.cos(car.h) * v * dt
    car.y = car.y + math.sin(car.h) * v * dt
    car.err, car.u, car.reached, car.tspd = err, u, reached, tspd
    return u
end

-- ---------------------------------------------------------------- 貼縫
local pS = buildRoute({ 0, 0, 40, 0, 80, 0, 120, 0 })
local function gapCase(variant, entryLen, dl, kmh, fps)
    local dt = 1 / fps
    local a = 12
    local b = a + entryLen
    local c, d = b + 12, b + 18
    local offL = -dl
    local ox, oy = {}, {}
    local n, s0, why, s1 = F.buildOffsetLine(pS, 0, a, b, c, d, offL, 0, ox, oy)
    assert(why == "ok", why)
    local st = F.newState()
    assert(F.setOffset(st, a, b, c, d, offL, ox, oy, n, s0, s1))
    local function laneAt(sx)
        if sx <= a then return 0 elseif sx >= b then return offL end
        local t = (sx - a) / (b - a)
        t = t * t * (3 - 2 * t)
        return offL * t
    end
    local car = { x = 0, y = 0, h = 0, w = 0, spd = kmh }
    local peak, atB = 0, nil
    for _ = 1, 20000 do
        stepCar(variant, pS, st, car, dt, { laneAt = laneAt })
        if car.x >= a and car.x <= b + 2 then
            local lag = math.abs(car.latDev or 0)
            if lag > peak then peak = lag end
            if atB == nil and car.x >= b then atB = lag end
        end
        if car.x > b + 4 then break end
    end
    F.clearOffset(st)
    return peak, atB or 0
end

-- ---------------------------------------------------------------- S 彎蛇行
local sinePts = {}
for i = 0, 40 do
    local x = i * 5
    sinePts[#sinePts + 1] = x
    sinePts[#sinePts + 1] = 8 * math.sin(x / 105 * 2 * math.pi)
end
local pSine = buildRoute(sinePts)
local function sineCase(variant, kmh, fps)
    local dt = 1 / fps
    local st = F.newState()
    local car = { x = 0, y = 0, h = 0, w = 0, spd = kmh }
    local flips, prevSign, steps, maxDev = 0, 0, 0, 0
    local function distToPath(x, y)
        local best
        for i = 1, pSine.n - 1 do
            local ax, ay = pSine.x[i], pSine.y[i]
            local ex, ey = pSine.x[i + 1] - ax, pSine.y[i + 1] - ay
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
    for _ = 1, 40000 do
        stepCar(variant, pSine, st, car, dt, nil)
        car.spd = kmh -- 定速比較（不吃 targetSpeed，把兩個變體放在同一速度）
        steps = steps + 1
        if steps > 3 * fps then
            local sg = (car.err > 0.01) and 1 or ((car.err < -0.01) and -1 or 0)
            if sg ~= 0 and prevSign ~= 0 and sg ~= prevSign then flips = flips + 1 end
            if sg ~= 0 then prevSign = sg end
            local dv = distToPath(car.x, car.y)
            if dv > maxDev then maxDev = dv end
        end
        if car.reached or car.x > 195 then break end
    end
    local secs = (steps - 3 * fps) / fps
    return flips / math.max(secs, 1e-6), maxDev
end

-- ---------------------------------------------------------------- 跑
print(string.format("plant: bicycle + first-order yaw lag tau=%.2fs, kappaMax=%.3f, inner K_OMEGA=%.2f", TAU, KAPPA_MAX, K_OMEGA))
print("")
print("貼縫進入段橫向落後（m）：peak / at-b    [A=現制  B=+yaw-rate 內環]")
print(string.format("%-28s %-15s %-15s %-15s %-15s", "case", "A@30fps", "B@30fps", "A@60fps", "B@60fps"))
local allFinite = true
for _, cs in ipairs({ { 4, 1.5, 5 }, { 4, 1.5, 10 }, { 6, 1.5, 10 }, { 4, 3.5, 5 }, { 6, 3.5, 5 }, { 6, 3.5, 10 } }) do
    local row = {}
    for _, cfg in ipairs({ { "A", 30 }, { "B", 30 }, { "A", 60 }, { "B", 60 } }) do
        local pk, ab = gapCase(cfg[1], cs[1], cs[2], cs[3], cfg[2])
        if not (finite(pk) and finite(ab)) then allFinite = false end
        row[#row + 1] = string.format("%.2f / %.2f", pk, ab)
    end
    print(string.format("%-28s %-15s %-15s %-15s %-15s",
        string.format("entry %dm dl %.1f %dkm/h", cs[1], cs[2], cs[3]), row[1], row[2], row[3], row[4]))
end
print("")
print("S 彎蛇行：航向誤差翻號率（次/秒）/ 最大偏差（m）")
print(string.format("%-28s %-15s %-15s %-15s %-15s", "case", "A@30fps", "B@30fps", "A@60fps", "B@60fps"))
for _, kmh in ipairs({ 25, 40, 55 }) do
    local row = {}
    for _, cfg in ipairs({ { "A", 30 }, { "B", 30 }, { "A", 60 }, { "B", 60 } }) do
        local fl, dv = sineCase(cfg[1], kmh, cfg[2])
        if not (finite(fl) and finite(dv)) then allFinite = false end
        row[#row + 1] = string.format("%.2f / %.2f", fl, dv)
    end
    print(string.format("%-28s %-15s %-15s %-15s %-15s", string.format("sine %dkm/h", kmh), row[1], row[2], row[3], row[4]))
end
print("")
print(allFinite and "ok（全部有限）" or "FAIL（出現 NaN/inf）")
