--[[
離線實驗（非閘門）：直路段承諾線改投影到線本身、沿線預視（Follower lineQ／TANGENT_LINE_PREVIEW_M，1004e）
對陡進入段追線落後的效果。

    lua scripts/exp_steep_entry.lua            [KPS=0.16 TAU=0.35 環境變數調 plant]

off＝關掉線投影（1004e 前：路線弧長同 s 點取切線）；pN＝線投影、預視線長 N m（改寫 TANGENT_LINE_PREVIEW_M 後載入）。
Plant 與 cross-track 同 scripts/exp_gap_tangent.lua（自行車＋一階 yaw 延遲、Driver 同式 cross-track ×3）。
欄位：lag＝b 前 3m 到 b 後 4m 內落在障礙側的最大橫距（@ 相對 b 的位置）、over＝保持段甩到線外、h@b＝到 b 時車頭角、
|ld|max＝全程對線最大偏差（m／度）。第一組 13m／11.5m 是 E2E dixie9160 擦車角那條線。
]]
local MEDIA = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua"
assert(loadfile(MEDIA .. "/shared/MDAD_Dynamics.lua"))()
local D = MDADDynamics
local function loadF(variant)
    local fh = assert(io.open(MEDIA .. "/shared/MDAD_Follower.lua")); local src = fh:read("*a"); fh:close()
    local n
    if variant == "off" then
        src, n = src:gsub("if ovQ == nil and lineLat ~= nil and state%.trackTangent == true", "if false and ovQ == nil", 1)
    else
        src, n = src:gsub("local TANGENT_LINE_PREVIEW_M = [%d%.]+", "local TANGENT_LINE_PREVIEW_M = " .. variant, 1)
    end
    assert(n == 1, variant)
    local env = setmetatable({}, { __index = _G }) -- 各變體各自一份（同一張 MDADFollower 表會互蓋）
    assert(load(src, "Follower-" .. variant, "t", env))()
    return env.MDADFollower
end
local KMH = 3.6
local KPS = tonumber(os.getenv("KPS") or "0.16")
local KMAX = tonumber(os.getenv("KMAX") or tostring(1 / 2.92))
local TAU = tonumber(os.getenv("TAU") or "0.35")
local function run(F, entry, y0, offL, vEntry, vHold)
    local dt = 1 / 30
    local p = F.begin({ pts = { 0, 0, 60, 0, 120, 0, 180, 0 } }, 60); while not p.ready do F.stepBuild(p, 4096) end
    local a = 2; local b = a + entry; local c, d = b + 5.8, b + 63.3
    local ox, oy = {}, {}
    local n, s0, why, s1 = F.buildOffsetLine(p, 0, a, b, c, d, offL, y0, ox, oy, nil, nil, nil, y0)
    assert(why == "ok", why)
    local st = F.newState(); F.setLaneBias(st, y0)
    assert(F.setOffset(st, a, b, c, d, offL, ox, oy, n, s0, s1)); st.trackTangent = true
    local function lineY(sx)
        if sx <= a then return y0 elseif sx >= d then return y0 end
        if sx < b then local t = (sx - a) / (b - a); t = t * t * (3 - 2 * t); return y0 + (offL - y0) * t end
        if sx <= c then return offL end
        local t = (d - sx) / (d - c); t = t * t * (3 - 2 * t); return y0 + (offL - y0) * t
    end
    local car = { x = 0, y = y0, h = 0, w = 0 }
    local prevLd
    local sgn = offL < y0 and 1 or -1 -- 障礙側＝起點那側
    local lagMax, lagAt, overMax, hAtB, ldMax = -1e9, 0, 0, nil, 0
    while car.x < c + 6 do
        local spd = car.x < b and vEntry or vHold
        local steer, _, _, _, _, _, latSigned, lineLat = F.control(p, st, car.x, car.y, car.h, spd, dt)
        local latDev = lineLat and (latSigned - lineLat) or 0
        local dLat = prevLd and (latDev - prevLd) / dt or nil; prevLd = latDev
        if dLat and (dLat > 5 or dLat < -5) then dLat = nil end
        local xt = D.crossTrackSteer(latDev, spd, dLat, D.CROSS_TRACK_DODGE_GAIN, D.CROSS_TRACK_DODGE_MAX)
        local u = steer - xt; if u > 5 then u = 5 elseif u < -5 then u = -5 end
        local v = spd / KMH; local k = u * KPS; if k > KMAX then k = KMAX elseif k < -KMAX then k = -KMAX end
        car.w = car.w + (k * v - car.w) * (dt / TAU); car.h = car.h + car.w * dt
        car.x = car.x + math.cos(car.h) * v * dt; car.y = car.y + math.sin(car.h) * v * dt
        local lag = (car.y - lineY(car.x)) * sgn
        if car.x >= b - 3 and car.x <= b + 4 and lag > lagMax then lagMax, lagAt = lag, car.x - b end
        if car.x >= b and car.x <= c and -lag > overMax then overMax = -lag end
        if hAtB == nil and car.x >= b then hAtB = math.deg(car.h) end
        local ald = latDev < 0 and -latDev or latDev
        if ald > ldMax then ldMax = ald end
    end
    return string.format("lag=%.2f@%+.1f over=%.2f h@b=%5.1f |ld|max=%.2f", lagMax, lagAt, overMax, hAtB or 0, ldMax)
end
local variants = { "off", "1.5", "2.0", "2.5", "3.0" }
local Fs = {}
for _, v in ipairs(variants) do Fs[v] = loadF(v) end
print(string.format("plant KPS=%.2f KMAX=%.2f TAU=%.2f", KPS, KMAX, TAU))
-- { 進入段長, 起點 lane, offL, 進入速度, 保持速度 }
local cases = {
    { 11.5, 3, -10, 7, 10 }, { 11.5, 3, -10, 15, 15 },
    { 6, 0, -1.5, 10, 10 }, { 6, 0, -4.0, 10, 10 }, { 4, 0, -1.5, 5, 5 }, { 6, 0, -3.5, 5, 5 },
    { 10, 0, -2.0, 15, 15 }, { 15, 0, -6, 15, 20 }, { 20, 0, -2.0, 30, 30 }, { 30, 0, -3.0, 45, 45 },
}
for _, cs in ipairs(cases) do
    print(string.format("entry %4.1f dl %4.1f v %2d/%2d", cs[1], math.abs(cs[3] - cs[2]), cs[4], cs[5]))
    for _, v in ipairs(variants) do
        print(string.format("   %-4s %s", v, run(Fs[v], cs[1], cs[2], cs[3], cs[4], cs[5])))
    end
end
