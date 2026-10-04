--[[
離線實驗（非閘門）：承諾線在弧上的追線（1004f）。

    lua scripts/exp_arc_commit.lua

(A) 陡進入段落在弧上（E2E e1004e dixie9050w 改道線：R≈17 弧上原地承諾 3.3m 側移塞 3.8m，落後 1.3m）——
    off＝投影到線本身只在直路段（1004e），on＝弧上的進入／出口過渡段也投影到線本身（Follower lineQ，1004f）。
    Plant 同 scripts/exp_steep_entry.lua（自行車＋一階 yaw 延遲，k＝u·KPS、夾 1/rMin），Driver 同式 cross-track ×3（貼縫）。
    lag＝b 前 3m 到 b 後 4m 內落在障礙側的最大垂距、over＝保持段甩到線外、|d|max＝全程對線最大垂距（m）。
(B) 巡航承諾線在弧上的穩態外漂（E2E f1004e dixie9050w：R≈40 弧外側 0.2m 的 pre-a 線，48→22 km/h 減速中外漂到
    0.5m 擦路邊物）——Driver cross-track 弧段 ×ARC（舊制）對 ×DODGE（承諾線在弧上，1004f）。Plant：yaw 一階追 G·u
    （τ 0.35，夾 v/rMin）；G＝const、prop（G＝c·v，CarNormal 實測 55 km/h 0.98、23 km/h 0.45）或 curv（G＝KPS·v，
    同 (A) 的曲率型 plant，KPS 0.4＝高增益車），Driver 回授正規化照實。
    out＝弧上最大外漂、in＝弧上到出弧 10m 最大切內（m）。
(C) 同 (B) 的承諾線（×DODGE），只對承諾線（trackTangent）把弧段前饋 FRAC 由 0.75（CURVE_FF_FRAC，09-08 裁定欠轉）提高：
    外漂與切內的交換（1004g open-issues「承諾線在弧上減速仍外漂」）。
(D) 同 (B) 的承諾線，轉向增益直接給 plant 真值（不靠線上估計）：外漂還剩多少＝設計欠轉的份，不是估計落後。
(E) 窄縫陡進入段用滿跑道（1004g TUNE.ENTRY_STRETCH_MAX；E2E h1004f dixie9050w：R≈17 弧上 11.45m 塞 6.3m，跑道 19.9m）
    與只降速的對照；量法同 (A)。
垂距一律對承諾線折線本身量（不是路線弧長同 s 的橫距）。
]]
local MEDIA = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua"
assert(loadfile(MEDIA .. "/shared/MDAD_Dynamics.lua"))()
local D = MDADDynamics
local function loadF(variant, frac)
    local fh = assert(io.open(MEDIA .. "/shared/MDAD_Follower.lua")); local src = fh:read("*a"); fh:close()
    local n = 1
    if variant == "off" then
        src, n = src:gsub("or arcK ~= nil and isFinite%(state%.offL%)", "or false and isFinite(state.offL)", 1)
    elseif frac then
        src, n = src:gsub("local frac, g = CURVE_FF_FRAC, yawGain",
            "local frac, g = (state.trackTangent == true and " .. frac .. " or CURVE_FF_FRAC), yawGain", 1)
    end
    assert(n == 1, variant)
    local env = setmetatable({}, { __index = _G }) -- 各變體各自一份（同一張 MDADFollower 表會互蓋）
    assert(load(src, "Follower-" .. variant, "t", env))()
    return env.MDADFollower
end
local VP = { valid = true, geometryValid = true, halfW = 0.81, rMin = 3.03, wheelbase = 2.66,
    delta0Safe = 0.72, deltaVSafe = 0.24, maxSpeed = 120, lookScale = 1.0 }
-- 右轉 deg（PZ y 向南：東行轉南行一側＝dθ>0，內側＝+lane）；路寬讓 band 放得下 R
local function arcRoute(R, deg)
    local ang = math.rad(deg)
    local w = 2 * (R * (1 - math.cos(ang / 2)) + VP.halfW + 0.6)
    if w < 7 then w = 7 end
    return { pts = { 0, 0, 120, 0, 120 + 150 * math.cos(ang), 150 * math.sin(ang) },
        segSurface = { "paved", "paved" }, segWidth = { w, w } }
end
local function build(F, R, deg)
    local p = F.begin(arcRoute(R, deg), 120, 4, VP)
    while not p.ready do F.stepBuild(p, 4096) end
    local arcA, arcB
    for i = 1, p.n - 1 do
        if p.segKind[i] == D.SEG_ARC then arcA = arcA or p.s[i]; arcB = p.s[i + 1] end
    end
    assert(arcA, "no arc")
    return p, arcA, arcB
end
-- 車對承諾線折線的帶號垂距（右正，同 latSigned）
local function lineDev(st, x, y)
    local best, dev = 1e30, 0
    for k = 1, st.ovN - 1 do
        local ax, ay = st.ovX[k], st.ovY[k]
        local ex, ey = st.ovX[k + 1] - ax, st.ovY[k + 1] - ay
        local L2 = ex * ex + ey * ey
        if L2 > 1e-9 then
            local rx, ry = x - ax, y - ay
            local t = (rx * ex + ry * ey) / L2
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            local dx, dy = rx - ex * t, ry - ey * t
            local d2 = dx * dx + dy * dy
            if d2 < best then best, dev = d2, (ex * ry - ey * rx) / math.sqrt(L2) end
        end
    end
    return dev
end
local function driverSteer(st, steer, latDev, kmh, dLat, xg, xm)
    local u = steer - D.crossTrackSteer(latDev, kmh, dLat, xg, xm)
    local g = st.yawGainFb or st.yawGain -- Drive.normalizeSteer
    local k = 0.5 / g
    if k < 1 then k = 1 elseif k > 3 then k = 3 end
    if k ~= 1 then
        local ff = st.ffSteer or 0
        local fb = u - ff
        local lim = math.abs(fb) > 1.5 and math.abs(fb) or 1.5
        local o = k * fb
        if o > lim then o = lim elseif o < -lim then o = -lim end
        u = ff + o
    end
    if u > 5 then u = 5 elseif u < -5 then u = -5 end
    if u < 0.02 and u > -0.02 then u = 0 end
    return u
end

-- (A) 陡進入段在弧上
local KPS, TAU = 0.16, 0.35
local function entry(F, cs)
    local dt = 1 / 30
    local p, arcA = build(F, cs.R, cs.deg)
    local a = arcA + cs.at; local b = a + cs.entry; local c, d = b + 6, b + 40
    local ox, oy = {}, {}
    local n, s0, why, s1 = F.buildOffsetLine(p, 60, a, b, c, d, cs.offL, cs.y0, ox, oy, nil, nil, nil, cs.y0)
    assert(why == "ok", why)
    local st = F.newState(); F.setLaneBias(st, cs.y0); F.setRuntimeLimits(st, 3, 6, 7, 1.2)
    assert(F.setOffset(st, a, b, c, d, cs.offL, ox, oy, n, s0, s1)); st.trackTangent = true
    local car = { x = 60, y = cs.y0, h = 0, w = 0 }
    local sgn = cs.offL < cs.y0 and 1 or -1 -- 障礙側＝起點那側
    local prev, lagMax, overMax, dMax = nil, -1e9, 0, 0
    for _ = 1, 30 * 200 do
        local kmh = cs.v
        local steer, _, rem, _, _, _, latSigned, lineLat = F.control(p, st, car.x, car.y, car.h, kmh, dt)
        local sNow = p.length - rem
        local latDev = latSigned - (lineLat or cs.y0)
        local dLat = prev and (latDev - prev) / dt or nil
        if dLat and (dLat > 5 or dLat < -5) then dLat = nil end
        prev = latDev
        local u = driverSteer(st, steer, latDev, kmh, dLat, D.CROSS_TRACK_DODGE_GAIN, D.CROSS_TRACK_DODGE_MAX)
        st.appliedSteer = u
        local v = kmh / 3.6
        local kps = cs.kps or KPS
        local k = u * kps; if k > 1 / VP.rMin then k = 1 / VP.rMin elseif k < -1 / VP.rMin then k = -1 / VP.rMin end
        car.w = car.w + (k * v - car.w) * (dt / TAU); car.h = car.h + car.w * dt
        car.x = car.x + math.cos(car.h) * v * dt; car.y = car.y + math.sin(car.h) * v * dt
        local dv = lineDev(st, car.x, car.y)
        local lag = dv * sgn
        if sNow >= b - 3 and sNow <= b + 4 and lag > lagMax then lagMax = lag end
        if sNow >= b and sNow <= c and -lag > overMax then overMax = -lag end
        if sNow >= a - 2 and sNow <= c and math.abs(dv) > dMax then dMax = math.abs(dv) end
        if sNow > c + 4 then break end
    end
    return string.format("lag=%5.2f over=%.2f |d|max=%.2f", lagMax, overMax, dMax)
end

-- (B) 巡航承諾線穩態外漂
local function cruise(F, cs, xg, xm)
    local dt = 1 / 30
    local p, arcA, arcB = build(F, cs.R, cs.deg)
    local st = F.newState(); F.setLaneBias(st, cs.lane); F.setRuntimeLimits(st, 3, 6, 7, 1.2)
    st.yawGain = 0.8
    local a = arcB + 40 -- pre-a 一路沿車的橫向（startLane）＝整個弧都在 pre-a
    local ox, oy = {}, {}
    local n, s0, why, s1 = F.buildOffsetLine(p, 60, a, a + 10, a + 14, a + 30, cs.lane, cs.lane, ox, oy,
        nil, nil, nil, cs.lane)
    assert(why == "ok", why)
    assert(F.setOffset(st, a, a + 10, a + 14, a + 30, cs.lane, ox, oy, n, s0, s1)); st.trackTangent = true
    local car = { x = 60, y = cs.lane, h = 0, w = 0 }
    local prev, out, inn, kmh = nil, 0, 0, cs.v0
    for _ = 1, 30 * 40 do
        local v = kmh / 3.6
        local G = cs.plant == "prop" and math.max(0.12, 0.065 * v) or (cs.plant == "curv" and cs.kps * v) or cs.G
        if cs.oracle then st.yawGain, st.yawGainFb = G, G end
        local steer, _, rem, _, _, _, latSigned, lineLat = F.control(p, st, car.x, car.y, car.h, kmh, dt)
        local sNow = p.length - rem
        local latDev = latSigned - (lineLat or cs.lane)
        local dLat = prev and (latDev - prev) / dt or nil
        if dLat and (dLat > 5 or dLat < -5) then dLat = nil end
        prev = latDev
        local g1, m1 = nil, nil
        if st.curveHardActive then g1, m1 = xg, xm end
        local u = driverSteer(st, steer, latDev, kmh, dLat, g1, m1)
        st.appliedSteer = u
        local wT = G * u
        if wT > v / VP.rMin then wT = v / VP.rMin elseif wT < -v / VP.rMin then wT = -v / VP.rMin end
        car.w = car.w + (wT - car.w) * (dt / 0.35); car.h = car.h + car.w * dt
        car.x = car.x + math.cos(car.h) * v * dt; car.y = car.y + math.sin(car.h) * v * dt
        if cs.v1 and sNow >= arcA - 5 and kmh > cs.v1 then
            kmh = kmh - 2.3 * 3.6 * dt; if kmh < cs.v1 then kmh = cs.v1 end
        end
        local dv = lineDev(st, car.x, car.y)
        if sNow >= arcA and sNow <= arcB and -dv > out then out = -dv end -- 右轉外側＝−
        if sNow >= arcA and sNow <= arcB + 10 and dv > inn then inn = dv end
        if sNow > arcB + 25 then break end
    end
    return string.format("out=%.2f in=%.2f", out, inn)
end

local Foff, Fon = loadF("off"), loadF("on")
print(string.format("(A) 弧上陡進入段  plant KPS=%.2f TAU=%.2f", KPS, TAU))
-- { R, 彎角, 進弧後 at 公尺開始, 進入段長, 起點 lane, offL, km/h }
for _, cs in ipairs({
    { R = 17, deg = 90, at = 4, entry = 3.8, y0 = -0.33, offL = 3, v = 10 },   -- e1004e rs 1153
    { R = 17, deg = 90, at = 4, entry = 3.8, y0 = 0.33, offL = -3, v = 10 },
    { R = 12, deg = 90, at = 3, entry = 6, y0 = 0, offL = -3.5, v = 8 },
    { R = 25, deg = 90, at = 5, entry = 8, y0 = 0, offL = 4, v = 15 },
    { R = 25, deg = 90, at = 5, entry = 8, y0 = 0, offL = -4, v = 15 },
    { R = 40, deg = 60, at = 5, entry = 12, y0 = 0, offL = -5.5, v = 10 },
    { R = 40, deg = 60, at = 5, entry = 20, y0 = 0, offL = 2, v = 30 },   -- 緩線
    { R = 65, deg = 45, at = 5, entry = 25, y0 = 0, offL = -2.5, v = 40 }, -- 緩線
}) do
    print(string.format("  R%-3d at %2d entry %4.1f dl %+4.1f %2d km/h  off %s | on %s", cs.R, cs.at, cs.entry,
        cs.offL - cs.y0, cs.v, entry(Foff, cs), entry(Fon, cs)))
end
print("(B) 巡航承諾線在弧上（off/on × cross-track ×ARC／×DODGE）")
local ARC_CASES = {
    { R = 40, deg = 60, lane = -0.2, v0 = 48, v1 = 22, plant = "prop" }, -- f1004e
    { R = 40, deg = 60, lane = -0.2, v0 = 48, v1 = 22, G = 0.6 },
    { R = 40, deg = 60, lane = -0.2, v0 = 22, plant = "prop" },
    { R = 25, deg = 90, lane = 0.5, v0 = 30, plant = "prop" },
    { R = 25, deg = 90, lane = -1.0, v0 = 30, G = 0.4 },
    { R = 12, deg = 90, lane = -0.5, v0 = 18, plant = "prop" },
    { R = 12, deg = 90, lane = -0.5, v0 = 18, G = 1.0 },
    { R = 30, deg = 60, lane = -0.3, v0 = 45, G = 0.6 },
    { R = 65, deg = 45, lane = 0, v0 = 60, v1 = 35, plant = "prop" },
    { R = 8, deg = 90, lane = -0.3, v0 = 12, plant = "prop" },
    { R = 12, deg = 90, lane = -0.3, v0 = 25, plant = "curv", kps = 0.4 },
    { R = 20, deg = 90, lane = -0.3, v0 = 35, plant = "curv", kps = 0.16 },
    { R = 8, deg = 90, lane = -0.3, v0 = 15, plant = "curv", kps = 0.4 },
}
local function plantTag(cs) return cs.plant == "curv" and ("k" .. cs.kps) or cs.plant or ("G" .. cs.G) end
for _, cs in ipairs(ARC_CASES) do
    local row = {}
    for _, vr in ipairs({ { "off", Foff, "x2", D.CROSS_TRACK_ARC_GAIN, D.CROSS_TRACK_ARC_MAX },
        { "on", Fon, "x2", D.CROSS_TRACK_ARC_GAIN, D.CROSS_TRACK_ARC_MAX },
        { "on", Fon, "x3", D.CROSS_TRACK_DODGE_GAIN, D.CROSS_TRACK_DODGE_MAX } }) do
        row[#row + 1] = string.format("%s%s %s", vr[1], vr[3], cruise(vr[2], cs, vr[4], vr[5]))
    end
    print(string.format("  R%-3d lane %+4.1f %2d%s km/h %-5s | %s", cs.R, cs.lane, cs.v0, cs.v1 and ("->" .. cs.v1) or "",
        plantTag(cs), table.concat(row, " | ")))
end
print("(C) 承諾線弧段前饋 FRAC（×DODGE；0.75＝現行 CURVE_FF_FRAC）")
local FR = { "0.75", "0.85", "0.95", "1.05" }
local Ffr = {}
for _, f in ipairs(FR) do Ffr[f] = f == "0.75" and Fon or loadF("frac", f) end
for _, cs in ipairs(ARC_CASES) do
    local row = {}
    for _, f in ipairs(FR) do
        row[#row + 1] = "frac " .. f .. " " .. cruise(Ffr[f], cs, D.CROSS_TRACK_DODGE_GAIN, D.CROSS_TRACK_DODGE_MAX)
    end
    print(string.format("  R%-3d lane %+4.1f %2d%s km/h %-5s | %s", cs.R, cs.lane, cs.v0, cs.v1 and ("->" .. cs.v1) or "",
        plantTag(cs), table.concat(row, " | ")))
end
print("(D) 承諾線（×DODGE）：線上估計的轉向增益 vs 直接給 plant 真值")
for _, cs in ipairs(ARC_CASES) do
    local est = cruise(Fon, cs, D.CROSS_TRACK_DODGE_GAIN, D.CROSS_TRACK_DODGE_MAX)
    cs.oracle = true
    local orc = cruise(Fon, cs, D.CROSS_TRACK_DODGE_GAIN, D.CROSS_TRACK_DODGE_MAX)
    cs.oracle = nil
    print(string.format("  R%-3d lane %+4.1f %2d%s km/h %-5s | 估計 %s | 真值 %s", cs.R, cs.lane, cs.v0,
        cs.v1 and ("->" .. cs.v1) or "", plantTag(cs), est, orc))
end
print("(E) 窄縫陡進入段（R17 弧、+1.83 → −4.5）：進入段長 × 車速 × plant KPS")
for _, kps in ipairs({ 0.16, 0.25 }) do
    for _, L in ipairs({ 11.45, 15, 19.9 }) do
        for _, v in ipairs({ 15, 10, 7, 5, 3 }) do
            print(string.format("  KPS %.2f entry %5.2f %2d km/h  %s", kps, L, v,
                entry(Fon, { R = 17, deg = 90, at = 4, entry = L, y0 = 1.83, offL = -4.5, v = v, kps = kps })))
        end
    end
end
