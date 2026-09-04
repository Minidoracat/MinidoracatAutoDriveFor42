--[[
離線實驗（非閘門）：貼縫承諾中改追承諾線切線（Follower state.trackTangent）對進入段落後的效果。

    lua scripts/exp_gap_tangent.lua            [KPS=0.16 TAU=0.35 環境變數調 plant]

A＝現制（前視點 pure pursuit）；pN＝切線追蹤、預視 N m（改寫 TANGENT_PREVIEW_M 後載入）；
kd0＝同時關掉 PID 的 D 項（只看趨勢，不是候選）。全部疊 Driver 同式 cross-track ×3。
Plant：自行車＋一階 yaw 延遲，κ/steer 由 2026-09-04 s018 反推（steer 0.44 → κ≈0.07）。
欄位：進入段峰值落後 / 到 b 的落後 / 並行段峰值 / 並行段外甩 / 出口前切內（單位 m）。
背景與結論見 AGENTS.md「貼縫進入段追線落後」條。
]]
local MEDIA = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua"
local function loadF(preview, kd)
    local fh = assert(io.open(MEDIA .. "/shared/MDAD_Follower.lua")); local src = fh:read("*a"); fh:close()
    src = src:gsub("local TANGENT_PREVIEW_M = [%d%.]+", "local TANGENT_PREVIEW_M = " .. preview)
    if kd then src = src:gsub("local KP, KI, KD = 2.2, 0.15, 0.35", "local KP, KI, KD = 2.2, 0.15, " .. kd) end
    assert(load(src))()
    return MDADFollower
end
assert(loadfile(MEDIA .. "/shared/MDAD_Dynamics.lua"))()
local D = MDADDynamics
local KMH, KPS, KMAX = 3.6, tonumber(os.getenv("KPS") or "0.16"), 1/2.92
local TAU = tonumber(os.getenv("TAU") or "0.35")
local XG, XM = tonumber(os.getenv("XG") or "0"), tonumber(os.getenv("XM") or "0")
local Y0 = tonumber(os.getenv("Y0") or "0") -- 起步時離常駐 lane 的偏差（實機常見 0.7）
local function run(F, entry, dl, kmh, tt)
    local dt = 1/30
    local p = F.begin({ pts = { 0, 0, 40, 0, 80, 0, 120, 0 } }, 60); while not p.ready do F.stepBuild(p, 4096) end
    local a = 12; local b = a + entry; local c, d = b + 12, b + 18; local offL = -dl
    local ox, oy = {}, {}
    local n, s0, why, s1 = F.buildOffsetLine(p, 0, a, b, c, d, offL, 0, ox, oy); assert(why == "ok")
    local st = F.newState(); assert(F.setOffset(st, a, b, c, d, offL, ox, oy, n, s0, s1)); st.trackTangent = tt
    local function laneAt(sx) if sx <= a then return 0 elseif sx >= b then return offL end local t = (sx - a) / (b - a); t = t*t*(3-2*t); return offL*t end
    local car = { x = 0, y = Y0, h = 0, w = 0, spd = kmh }; local prevLat
    local peak, atB, along, out, exitIn = 0, nil, 0, 0, 0
    while car.x < d + 4 do
        local steer = F.control(p, st, car.x, car.y, car.h, car.spd, dt)
        local latDev = car.y - laneAt(car.x)
        local dLat = prevLat and (latDev - prevLat) / dt or nil; prevLat = latDev
        local xt = D.crossTrackSteer(latDev, car.spd, dLat, XG > 0 and XG or D.CROSS_TRACK_DODGE_GAIN, XM > 0 and XM or D.CROSS_TRACK_DODGE_MAX)
        local u = steer - xt; if u > 5 then u = 5 elseif u < -5 then u = -5 end
        local v = car.spd / KMH; local k = u * KPS; if k > KMAX then k = KMAX elseif k < -KMAX then k = -KMAX end
        car.w = car.w + (k*v - car.w) * (dt/TAU); car.h = car.h + car.w*dt
        car.x = car.x + math.cos(car.h)*v*dt; car.y = car.y + math.sin(car.h)*v*dt
        local lag = math.abs(latDev)
        if car.x >= a and car.x <= b and lag > peak then peak = lag end
        if atB == nil and car.x >= b then atB = lag end
        if car.x >= b and car.x <= c then
            if lag > along then along = lag end
            if latDev * offL > 0 and lag > out then out = lag end
            -- 出口前切內（車比線更靠障礙側）
            if car.x >= c - 3 and latDev * offL < 0 and lag > exitIn then exitIn = lag end
        end
    end
    return string.format("%.2f/%.2f/%.2f/%.2f/%.2f", peak, atB or 0, along, out, exitIn)
end
local cases = { { 6, 1.5, 10 }, { 6, 4.0, 10 }, { 4, 1.5, 5 }, { 6, 3.5, 5 }, { 6, 2.0, 10 }, { 10, 2.0, 15 } }
local variants = { { "A", nil, nil, false }, { "p1.0", 1.0 }, { "p1.5", 1.5 }, { "p2.0", 2.0 }, { "p3.0", 3.0 }, { "p1.5kd0", 1.5, 0 } }
print(string.format("plant KPS=%.2f TAU=%.2f   entryPeak/atB/along/outward/exitCutIn", KPS, TAU))
for _, cs in ipairs(cases) do
    local row = {}
    for _, vv in ipairs(variants) do
        local F = loadF(vv[2] or 2, vv[3])
        row[#row + 1] = vv[1] .. "=" .. run(F, cs[1], cs[2], cs[3], vv[4] ~= false)
    end
    print(string.format("entry %2dm dl %.1f %2dkm/h  %s", cs[1], cs[2], cs[3], table.concat(row, "  ")))
end
