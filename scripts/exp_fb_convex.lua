-- 控制實驗（非閘門；1005 ③ 未上線的證據）：回授正規化依 |steer| 分兩檔（凸性）在凸型 plant 上有沒有收益。
-- 兩檔學習與插值只在本檔（learnBins／fbNormGain，照 Follower yawGainFb 同一個無偏估計器、同排除欄，steer 用
-- hiSteerLag 低通——逐幀 ap 會把小檔估低一半）；production 只有單一 yawGainFb（mode single＝現行 Driver 同式）。
-- plant：yaw 目標＝G·u·φ(|u|)，一階 τ 0.35；φ＝1（線性對照）／q4＝0.25+0.75·min(1,|u|)（小 steer 增益 1/4）／
-- fit＝0.4+0.4·min(|u|,1.5)（語料擬合：0.05–0.2 檔約大施力的 0.44）。G 取低增益車（正規化才會作用）。
-- 情境：①弧上承諾線（同 exp_arc_commit (B) 的 ×DODGE 追線）外漂 out／切內 in；②直路承諾線上起始側偏 1m 的
-- 收斂（過衝 os、進 0.15m 的秒數 ts；99＝窗內沒進）。每格先跑一趟暖機學增益、再帶學到的增益跑量測趟（直路先在弧上暖機）。
-- 抖動：施加 steer 每秒翻號次數 flip、逐幀 |Δu| 平均 du。mode：single／bin（依 |fb| 插值）／binu（依總 |u|）。
--   lua scripts/exp_fb_convex.lua
local MEDIA = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua"
assert(loadfile(MEDIA .. "/shared/MDAD_Dynamics.lua"))()
local D = MDADDynamics
assert(loadfile(MEDIA .. "/shared/MDAD_Follower.lua"))()
local F = MDADFollower
local BIN_MIN, BIN_SPLIT, LO_AT, HI_AT = 0.1, 0.5, 0.2, 0.8
local function wrap(a) return (a + math.pi) % (2 * math.pi) - math.pi end
local function learnFb(st, yk, sk, gk, yawN, apN, alpha, g0)
    local yf, sf = st[yk] or g0 * apN, st[sk] or apN
    yf, sf = yf + (yawN - yf) * alpha, sf + (apN - sf) * alpha
    st[yk], st[sk] = yf, sf
    st[gk] = math.max(0.08, math.min(3, yf / sf))
end
-- control 之後呼叫：ul＝control 剛更新的 hiSteerLag（含上幀施加 steer），yaw＝本幀與上幀 heading 差分
local function learnBins(st, heading, dt, kmh)
    local ph, ul = st.binPrevH, st.hiSteerLag
    st.binPrevH = heading
    if not ph or not ul or kmh < 8 then return end
    local yaw = wrap(heading - ph) / dt
    local sl = ul > 0 and 1 or -1
    local aul = ul * sl
    if aul < BIN_MIN or sl * yaw <= -0.5 then return end
    local alpha = math.min(1, dt / 0.5)
    local g0 = st.yawGainFb or st.yawGain
    if aul < BIN_SPLIT then learnFb(st, "fbYawLoF", "fbSteerLoF", "yawGainFbLo", sl * yaw, aul, alpha, g0)
    else learnFb(st, "fbYawHiF", "fbSteerHiF", "yawGainFbHi", sl * yaw, aul, alpha, g0) end
end
local function fbNormGain(g, gLo, gHi, mag)
    gLo, gHi = gLo or g, gHi or g
    if mag <= LO_AT then return gLo elseif mag >= HI_AT then return gHi end
    return gLo + (gHi - gLo) * (mag - LO_AT) / (HI_AT - LO_AT)
end
local VP = { valid = true, geometryValid = true, halfW = 0.81, rMin = 3.03, wheelbase = 2.66,
    delta0Safe = 0.72, deltaVSafe = 0.24, maxSpeed = 120, lookScale = 1.0 }
local function route(R, deg)
    local ang = math.rad(deg)
    local w = 2 * (R * (1 - math.cos(ang / 2)) + VP.halfW + 0.6)
    if w < 7 then w = 7 end
    return { pts = { 0, 0, 120, 0, 120 + 150 * math.cos(ang), 150 * math.sin(ang) },
        segSurface = { "paved", "paved" }, segWidth = { w, w } }
end
local cache = {}
local function build(R, deg)
    local key = R .. ":" .. deg
    if cache[key] then return table.unpack(cache[key]) end
    local p = F.begin(route(R, deg), 120, 4, VP)
    while not p.ready do F.stepBuild(p, 4096) end
    local arcA, arcB
    for i = 1, p.n - 1 do
        if p.segKind[i] == D.SEG_ARC then arcA = arcA or p.s[i]; arcB = p.s[i + 1] end
    end
    cache[key] = { p, arcA, arcB }
    return p, arcA, arcB
end
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
-- Driver Drive.normalizeSteer 同式；mode＝single（舊制）／bin（fbNormGain 依 |fb|）／binu（依總 steer |u|）
local function normalize(st, u, mode)
    local g = st.yawGainFb or st.yawGain
    if mode == "bin" then g = fbNormGain(g, st.yawGainFbLo, st.yawGainFbHi, math.abs(u - (st.ffSteer or 0))) end
    if mode == "binu" then g = fbNormGain(g, st.yawGainFbLo, st.yawGainFbHi, math.abs(u)) end
    local k = 0.5 / g
    if k < 1 then k = 1 elseif k > 3 then k = 3 end
    if k == 1 then return u, k end
    local ff = st.ffSteer or 0
    local fb = u - ff
    local lim = math.abs(fb) > 1.5 and math.abs(fb) or 1.5
    local o = k * fb
    if o > lim then o = lim elseif o < -lim then o = -lim end
    return ff + o, k
end
local PHI = {
    lin = function() return 1 end,
    q4 = function(a) if a > 1 then a = 1 end return 0.25 + 0.75 * a end,
    fit = function(a) if a > 1.5 then a = 1.5 end return 0.4 + 0.4 * a end, -- |u|=1.5 時 1.0
}
local LEARN = { "yawGain", "yawGainFb", "fbYawF", "fbSteerF", "yawGainFbLo", "fbYawLoF", "fbSteerLoF",
    "yawGainFbHi", "fbYawHiF", "fbSteerHiF", "yawGainHi", "hiYawF", "hiSteerF", "hiLearnT" }
-- kind＝arc｜step；回 out, inn（弧）或 os, ts（直路），flip/s，du
local function run(cs, mode, seed, dt)
    local p, arcA, arcB = build(cs.R, cs.deg)
    local st = F.newState(); F.setLaneBias(st, cs.lane); F.setRuntimeLimits(st, 3, 6, 7, 1.2)
    st.yawGain = 0.8
    if seed then for _, k in ipairs(LEARN) do st[k] = seed[k] end end
    local a, x0, y0
    if cs.kind == "arc" then a, x0, y0 = arcB + 40, 60, cs.lane else a, x0, y0 = 70, 20, cs.lane + 1.0 end
    local ox, oy = {}, {}
    local n, s0, why, s1 = F.buildOffsetLine(p, cs.kind == "arc" and 60 or 20, a, a + 10, a + 14, a + 30,
        cs.lane, cs.lane, ox, oy, nil, nil, nil, cs.lane)
    assert(why == "ok", why)
    assert(F.setOffset(st, a, a + 10, a + 14, a + 30, cs.lane, ox, oy, n, s0, s1)); st.trackTangent = true
    local car = { x = x0, y = y0, h = 0, w = 0 }
    local prev, out, inn, kmh = nil, 0, 0, cs.v0
    local os, ts, t = 0, nil, 0
    local flips, lastSign, du, nu, uPrev = 0, 0, 0, 0, nil
    local phi = PHI[cs.phi]
    for _ = 1, math.floor(40 / dt) do
        t = t + dt
        local v = kmh / 3.6
        local steer, _, rem, _, _, _, latSigned, lineLat = F.control(p, st, car.x, car.y, car.h, kmh, dt)
        learnBins(st, car.h, dt, kmh)
        local sNow = p.length - rem
        local latDev = latSigned - (lineLat or cs.lane)
        local dLat = prev and (latDev - prev) / dt or nil
        if dLat and (dLat > 5 or dLat < -5) then dLat = nil end
        prev = latDev
        local g1, m1 = D.crossTrackGains(true, false, st.curveHardActive, false, false)
        local u = steer - D.crossTrackSteer(latDev, kmh, dLat, g1, m1)
        u = normalize(st, u, mode)
        if u > 5 then u = 5 elseif u < -5 then u = -5 end
        if u < 0.02 and u > -0.02 then u = 0 end
        st.appliedSteer = u
        if uPrev then du, nu = du + math.abs(u - uPrev), nu + 1 end
        uPrev = u
        local sgn = u > 0.05 and 1 or (u < -0.05 and -1 or 0)
        if sgn ~= 0 then
            if lastSign ~= 0 and sgn ~= lastSign then flips = flips + 1 end
            lastSign = sgn
        end
        local wT = cs.G * u * phi(math.abs(u))
        if wT > v / VP.rMin then wT = v / VP.rMin elseif wT < -v / VP.rMin then wT = -v / VP.rMin end
        car.w = car.w + (wT - car.w) * (dt / 0.35); car.h = car.h + car.w * dt
        car.x = car.x + math.cos(car.h) * v * dt; car.y = car.y + math.sin(car.h) * v * dt
        local dv = lineDev(st, car.x, car.y)
        if cs.kind == "arc" then
            if cs.v1 and sNow >= arcA - 5 and kmh > cs.v1 then
                kmh = kmh - 2.3 * 3.6 * dt; if kmh < cs.v1 then kmh = cs.v1 end
            end
            if sNow >= arcA and sNow <= arcB and -dv > out then out = -dv end
            if sNow >= arcA and sNow <= arcB + 10 and dv > inn then inn = dv end
            if sNow > arcB + 25 then break end
        else
            -- 起點在線右 1m（dv>0）：過衝＝穿到另一側最深多少；ts＝第一次進 0.15m 且之後 1 秒都在內
            if -dv > os then os = -dv end
            if math.abs(dv) <= 0.15 then
                if not ts then ts = t end
            else
                ts = nil
            end
            if sNow > a + 25 then break end
        end
    end
    local seedOut = {}
    for _, k in ipairs(LEARN) do seedOut[k] = st[k] end
    if cs.kind == "arc" then return out, inn, flips / t, du / math.max(nu, 1), seedOut end
    return os, ts or 99, flips / t, du / math.max(nu, 1), seedOut
end
local CASES = {
    { kind = "arc", R = 40, deg = 60, lane = -0.2, v0 = 48, v1 = 22 },
    { kind = "arc", R = 25, deg = 90, lane = 0.5, v0 = 30 },
    { kind = "arc", R = 25, deg = 90, lane = -1.0, v0 = 30 },
    { kind = "arc", R = 30, deg = 60, lane = -0.3, v0 = 45 },
    { kind = "arc", R = 65, deg = 45, lane = 0, v0 = 60, v1 = 35 },
    { kind = "step", R = 40, deg = 60, lane = 0, v0 = 30 },
    { kind = "step", R = 40, deg = 60, lane = 0, v0 = 50 },
}
local GS = { 0.3, 0.5, 0.8 }
for _, dt in ipairs({ 1 / 30, 1 / 60 }) do
    for _, ph in ipairs({ "lin", "q4", "fit" }) do
        print(string.format("== plant φ=%s  dt=1/%d ==  (弧：out/in m；直路：過衝 m/進 0.15m 秒) flip/s du", ph, math.floor(1 / dt + 0.5)))
        for _, G in ipairs(GS) do
            for _, c in ipairs(CASES) do
                local cs = {}
                for k, v in pairs(c) do cs[k] = v end
                cs.phi, cs.G = ph, G
                local row = {}
                local gl = ""
                for _, mode in ipairs({ "single", "bin", "binu" }) do
                    local seed = nil
                    if cs.kind == "step" then -- 直路本身學不到增益：先在弧上暖機（同車在前一個彎學過）
                        local w = { kind = "arc", R = 25, deg = 90, lane = 0.5, v0 = 30, phi = ph, G = G }
                        _, _, _, _, seed = run(w, mode, nil, dt)
                    end
                    _, _, _, _, seed = run(cs, mode, seed, dt)
                    local a1, b1, fl, du, s2 = run(cs, mode, seed, dt)
                    row[#row + 1] = string.format("%5.2f/%5.2f %4.2f %.3f", a1, b1, fl, du)
                    if mode == "bin" then
                        gl = string.format("g %.2f lo %s hi %s", s2.yawGainFb or -1,
                            s2.yawGainFbLo and string.format("%.2f", s2.yawGainFbLo) or "-",
                            s2.yawGainFbHi and string.format("%.2f", s2.yawGainFbHi) or "-")
                    end
                end
                print(string.format("G%.1f %-4s R%-3d %2d° l%+.1f %2d->%-2s | single %s | bin %s | binu %s | %s", G,
                    cs.kind, cs.R, cs.deg, cs.lane, cs.v0, tostring(cs.v1 or "-"), row[1], row[2], row[3], gl))
            end
        end
    end
end
