--[[
離線實驗（非閘門）：承諾線的運動學可行性（1006，Driver Drive.kinProof）。

    lua scripts/exp_kin_proof.lua

(A) 陡進入段／停留線（直路，rs 起換 dl）：閉環車（自行車＋一階 yaw 延遲 τ、k＝u·KPS 夾 1/rMin；Driver 貼縫 cross-track ×3）
    在 b..b+3 的側移量（entry1／entry6＝a 在車前 1m／6m），對照兩條運動學線——Lo＝2·sqrt(dl·R−dl²/4)（rMin 最佳 S 彎的長度，Drive.kinProof 用的）與
    Lk＝sqrt(6·dl·R)（曲率處處 ≤1/rMin 的 smoothstep）；起點同 Drive.kinProof（停留線 rs、一般繞行 max(a−TANGENT_PREVIEW_M, rs)）。
    ahead＝車比 Lo 線多換了多少（>0＝Lo 不是下限）；全表 ≤0 才是「Lo 線只會比車樂觀」。Lk 在大側移時落在車後面 1m 以上
    （悲觀），所以證明線不用 Lk。
(B) fallback 折點外側承諾線（test_follower「外側承諾線繞非弧折點」同 plant）：線在頂點的折線曲率（1m 取樣外接圓）
    對閉環往彎內切進線的量。|l| 越小折線曲率越大（殘留頂點折角），切內反而越小——「曲率 >1/rMin 就拒收」在折點是錯的。
]]
local MEDIA = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua"
assert(loadfile(MEDIA .. "/shared/MDAD_Dynamics.lua"))()
assert(loadfile(MEDIA .. "/shared/MDAD_Follower.lua"))()
local F, D = MDADFollower, MDADDynamics
local DT, KMH = 1 / 30, 3.6
local function ss(t) if t <= 0 then return 0 elseif t >= 1 then return 1 end return t * t * (3 - 2 * t) end
-- Drive.normalizeSteer 同式（回授放大 0.5/g，夾 1..3）
local function driverSteer(st, steer, latDev, kmh, dLat)
    local u = steer - D.crossTrackSteer(latDev, kmh, dLat, D.CROSS_TRACK_DODGE_GAIN, D.CROSS_TRACK_DODGE_MAX)
    local k = 0.5 / (st.yawGainFb or st.yawGain)
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

local function steep(vp, stay, dl, L, v, kps, tau, aOff)
    local p = F.begin({ pts = { 0, 0, 300, 0 }, segSurface = { "paved" }, segWidth = { 30 } }, 120, 4, vp)
    while not p.ready do F.stepBuild(p, 4096) end
    local rs, y0, off = 60, 0, dl
    local x0 = stay and rs or rs + aOff
    local b, c = x0 + L, x0 + L + 12
    local d = c + (stay and 5 or 15)
    local ox, oy = {}, {}
    local n, s0, why, s1
    if stay then
        n, s0, why, s1 = F.buildOffsetLine(p, rs, x0, b, c, d, off, y0, ox, oy, y0, off, b, nil, 0)
    else
        n, s0, why, s1 = F.buildOffsetLine(p, rs, x0, b, c, d, off, y0, ox, oy, nil, nil, nil, y0)
    end
    assert(why == "ok", why)
    local st = F.newState(); F.setLaneBias(st, y0); F.setRuntimeLimits(st, 3, 6, 7, 1.2)
    assert(F.setOffset(st, x0, b, c, d, off, ox, oy, n, s0, s1)); st.trackTangent = true
    local car, prev, got = { x = rs, y = y0, h = 0, w = 0 }, nil, {}
    for _ = 1, 30 * 120 do
        local steer, _, _, _, _, _, latSigned, lineLat = F.control(p, st, car.x, car.y, car.h, v, DT)
        local latDev = latSigned - (lineLat or y0)
        local dLat = prev and (latDev - prev) / DT or nil
        if dLat and (dLat > 5 or dLat < -5) then dLat = nil end
        prev = latDev
        local u = driverSteer(st, steer, latDev, v, dLat)
        st.appliedSteer = u
        local k = u * kps; if k > 1 / vp.rMin then k = 1 / vp.rMin elseif k < -1 / vp.rMin then k = -1 / vp.rMin end
        local ms = v / KMH
        car.w = car.w + (k * ms - car.w) * (DT / tau); car.h = car.h + car.w * DT
        car.x = car.x + math.cos(car.h) * ms * DT; car.y = car.y + math.sin(car.h) * ms * DT
        for m = 0, 3 do
            if not got[m] and car.x >= b + m then got[m] = car.y - y0 end
        end
        if car.x > b + 4 then break end
    end
    local R = vp.rMin
    local Lo = dl < 2 * R and 2 * math.sqrt(dl * R - dl * dl / 4) or 2 * R
    local Lk = math.sqrt(6 * dl * R)
    local k0 = stay and x0 or math.max(x0 - F.TANGENT_PREVIEW_M, rs)
    local ahead, behindK = -9, -9
    for m = 0, 3 do
        local car_ = math.min(got[m] or 0, dl)
        local o = dl * ss((b + m - k0) / Lo)
        local kk = dl * ss((b + m - k0) / Lk)
        if car_ - o > ahead then ahead = car_ - o end
        if car_ - kk > behindK then behindK = car_ - kk end
    end
    return ahead, behindK, dl - (got[0] or 0), Lo, Lk
end

local range2 = { valid = true, geometryValid = true, halfW = 0.82, rMin = 2.63, wheelbase = 2.31,
    delta0Safe = 0.72, deltaVSafe = 0.24, maxSpeed = 86, lookScale = 1.31 }
local f350 = { valid = true, geometryValid = true, halfW = 0.9, rMin = 4.32, wheelbase = 3.79,
    delta0Safe = 0.72, deltaVSafe = 0.24, maxSpeed = 100, lookScale = 1.5 }
print("(A) 陡進入段：ahead＝車比 Lo 線多換的量（≤0＝Lo 樂觀）、aheadLk＝車比 Lk 線多換的量（>0＝Lk 悲觀）、lag@b")
local worst = -9
for _, vv in ipairs({ { "range2", range2 }, { "F350", f350 } }) do
    for _, mode in ipairs({ { "stay", true, 0 }, { "entry1", false, 1 }, { "entry6", false, 6 } }) do
        for _, g in ipairs({ { 2.25, 3.29 }, { 0.25, 1.2 }, { 1, 2.5 }, { 1.5, 4 }, { 4, 5.5 } }) do
            for _, pl in ipairs({ { 0.16, 0.35 }, { 0.4, 0.25 } }) do
                for _, v in ipairs({ 3, 8 }) do
                    local ah, ak, lag, Lo, Lk = steep(vv[2], mode[2], g[1], g[2], v, pl[1], pl[2], mode[3])
                    if ah > worst then worst = ah end
                    print(string.format("  %-6s %-5s dl %.2f L %.2f K%.2f %d km/h  ahead %+.2f aheadLk %+.2f lag@b %.2f (Lo %.1f Lk %.1f)",
                        vv[1], mode[1], g[1], g[2], pl[1], v, ah, ak, lag, Lo, Lk))
                end
            end
        end
    end
end
print(string.format("  全表 ahead 最大 %+.2f", worst))

-- (B) 外側承諾線繞 fallback 折點
local function lineSide(xs, ys, n, x, y)
    local best, sgn = 1e9, 1
    for i = 1, n - 1 do
        local ex, ey = xs[i + 1] - xs[i], ys[i + 1] - ys[i]
        local L2 = ex * ex + ey * ey
        local t = L2 > 0 and ((x - xs[i]) * ex + (y - ys[i]) * ey) / L2 or 0
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local qx, qy = xs[i] + ex * t - x, ys[i] + ey * t - y
        local dd = math.sqrt(qx * qx + qy * qy)
        if dd < best then best, sgn = dd, (ex * (y - ys[i]) - ey * (x - xs[i])) >= 0 and 1 or -1 end
    end
    return best, sgn
end
local function kink(p, a, b, c, d, offL, kmh, kmax, tau)
    local turn = p.segH[2] - p.segH[1]
    local st = F.newState()
    F.setRuntimeLimits(st, 3, 7, 6, 2)
    F.setLaneBias(st, 0)
    local ox, oy = {}, {}
    local n, s0, why, s1 = F.buildOffsetLine(p, a - 4, a, b, c, d, offL, 0, ox, oy, nil, nil, nil, 0)
    assert(why == "ok", why)
    local km = D.polylineKappaMax(ox, oy, n)
    assert(F.setOffset(st, a, b, c, d, offL, ox, oy, n, s0, s1))
    st.trackTangent = true
    local qi = F.segIndexAt(p, a - 2)
    local h = p.segH[qi]
    local t = (a - 2 - p.s[qi]) / p.segLen[qi]
    local car = { x = p.x[qi] + (p.x[qi + 1] - p.x[qi]) * t, y = p.y[qi] + (p.y[qi + 1] - p.y[qi]) * t,
        h = h, w = 0, v = kmh / KMH }
    local inside, prevLd = 0, nil
    for _ = 1, 6000 do
        local v = car.v * KMH
        local steer, tgt, rem, _, _, _, latS, lineLat = F.control(p, st, car.x, car.y, car.h, v, DT)
        local sNow = p.length - rem
        if not st.rotating and v >= 1 and lineLat then
            local ld = latS - lineLat
            local dl = prevLd and (ld - prevLd) / DT or nil
            if dl and (dl > 5 or dl < -5) then dl = nil end
            steer = steer - D.crossTrackSteer(ld, v, dl)
            prevLd = ld
        else
            prevLd = nil
        end
        local tv = math.min(tgt, kmh) / KMH
        if tv < car.v then car.v = math.max(tv, car.v - 7 * DT) else car.v = math.min(tv, car.v + 3 * DT) end
        if steer > 5 then steer = 5 elseif steer < -5 then steer = -5 end
        if steer < 0.02 and steer > -0.02 then steer = 0 end
        st.appliedSteer = steer
        local k = math.max(-kmax, math.min(kmax, steer * 0.4))
        car.w = car.w + (k * car.v - car.w) * (DT / tau)
        car.h = car.h + car.w * DT
        car.x = car.x + math.cos(car.h) * car.v * DT
        car.y = car.y + math.sin(car.h) * car.v * DT
        if sNow > a and sNow < c then
            local dv, sg = lineSide(ox, oy, n, car.x, car.y)
            if sg * turn > 0 and dv > inside then inside = dv end
        end
        if sNow > c then break end
    end
    return km, inside
end
print("(B) fallback 折點外側承諾線：線的折線曲率 κ（R＝1/κ）對閉環切進線內的量")
local vf = { valid = true, geometryValid = true, halfW = 1.0, halfL = 2.9, rMin = 4.32,
    wheelbase = 3.6, delta0Safe = 0.7, deltaVSafe = 0.25, maxSpeed = 90 }
local vc = { valid = true, geometryValid = true, halfW = 0.81, halfL = 2.37, rMin = 3.03,
    wheelbase = 2.66, delta0Safe = 0.72, deltaVSafe = 0.24, maxSpeed = 90 }
for _, vv in ipairs({ { "F350", vf }, { "Car", vc } }) do
    for _, deg in ipairs({ 90, 120 }) do
        local th = math.rad(deg)
        local q = F.begin({ pts = { 0, 0, 40, 0, 40 + 40 * math.cos(th), 40 * math.sin(th) },
            segSurface = { "paved", "paved" }, segWidth = { 4, 4 } }, 90, 8, vv[2])
        q.lookScale = 1.5
        while not F.stepBuild(q, 100000) do end
        assert(q.filletFallbackN == 1, "fixture：頂點是 fallback")
        for _, l in ipairs({ -1, -2, -3, -4.25 }) do
            for _, kmh in ipairs({ 4, 10 }) do
                local km, inside = kink(q, 24, 34, 46, 56, l, kmh, 1 / vv[2].rMin, 0.35)
                print(string.format("  %-4s %3d° l %+5.2f %2d km/h  κ %.2f (R %.2f, rMin %.2f)  切內 %.2f",
                    vv[1], deg, l, kmh, km, 1 / km, vv[2].rMin, inside))
            end
        end
    end
end
