-- Pure shared dynamics tests; no PZ globals or mocks.

local MEDIA = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua"
local ROOTS = { "", "../" }
local function loadProduction(rel)
    for _, root in ipairs(ROOTS) do
        local path = root .. MEDIA .. "/" .. rel
        local f = io.open(path, "rb")
        if f then
            f:close()
            local chunk, err = loadfile(path)
            if not chunk then error(err) end
            return chunk()
        end
    end
    error("找不到 " .. rel)
end

loadProduction("shared/MDAD_Dynamics.lua")
local D = MDADDynamics
local failures, assertions, scenarios = 0, 0, 0
local base, title

local function check(ok, label)
    assertions = assertions + 1
    if not ok then failures = failures + 1; print("  FAIL: " .. label) end
    return ok
end
local function eq(a, b, label) return check(a == b, label .. "（實得 " .. tostring(a) .. "）") end
local function near(a, b, e, label)
    return check(type(a) == "number" and math.abs(a - b) <= e,
        label .. "（期望 " .. tostring(b) .. "、實得 " .. tostring(a) .. "）")
end
local function scenario(name)
    if title then print("  " .. (assertions - base) .. " 項斷言") end
    scenarios, base, title = scenarios + 1, assertions, name
    print("情境" .. scenarios .. "：" .. name)
end

scenario("finite／clamp／circumcircle")
eq(D.finite(1), true, "有限數")
eq(D.finite(0 / 0), false, "NaN")
eq(D.finite(math.huge), false, "Inf")
eq(D.clamp(-1, 0, 2), 0, "下限")
eq(D.clamp(3, 0, 2), 2, "上限")
near(D.circumcircleKappa(1, 0, 0, 1, -1, 0), 1, 1e-12, "單位圓曲率")
near(D.circumcircleKappa(0, 0, 1, 0, 2, 0), 0, 1e-12, "共線曲率為零")
local lPts, lWidths = { 0, 0, 10, 0, 10, 10 }, { 4, 4 }
check(D.rawBandContains(lPts, lWidths, 1, 1, 6, 0),
    "non-convex union chord start lies in first source capsule")
check(D.rawBandContains(lPts, lWidths, 2, 1, 10, 4),
    "non-convex union chord end lies in second source capsule")
check(not D.chordCoveredByBand(lPts, lWidths, 1, 2, 1, 6, 0, 10, 4),
    "endpoint-only L-union false positive is rejected by midpoint continuity")
check(D.chordCoveredByBand(lPts, lWidths, 1, 2, 1, 9.6, 0, 10, 0.4),
    "corner-overlap chord shares a convex capsule on each half")

scenario("steering／curve／visibility caps")
local k0 = D.steeringKappa(2.5, 0.7, 0.25, 120, 0)
local k120 = D.steeringKappa(2.5, 0.7, 0.25, 120, 120)
check(k0 > k120 and k120 > 0, "高速 steering kappa 單調降低")
local curve = D.curveSpeedCapKmh(0.05, 3.5, 2.5, 0.7, 0.25, 120)
check(curve > 0 and curve < 120, "曲率 cap 同時受 lateral／steering 限制")
local vis = D.visibilityCapKmh(110, 0.5, 3, 2.2)
check(vis < 120, "110m＋保守 brake 不硬放 120")
local stop = D.stoppingDistance(vis / 3.6, 0.5, 3, 2.2)
check(stop <= 110 + 1e-9, "visibility 正根代回不超 D")
near(D.visibilityCapKmh(stop, 0.5, 3, 2.2), vis, 1e-9, "二次式正根可逆")
near(D.steeringSpeedCapKmh(0.1, 2.5, 0.5, 0.5, 120), 120, 1e-12,
    "constant steering clamp accepts feasible required angle")
near(D.steeringSpeedCapKmh(1, 2.5, 0.5, 0.5, 120), 0, 1e-12,
    "constant steering clamp rejects infeasible required angle")

scenario("full-speed gate truth table")
local all = { true, true, true, true, true, true, true, true, true, true, true, true }
local ok, reason = D.fullSpeedGate(table.unpack(all))
eq(ok, true, "全真 gate 開啟")
eq(reason, "clear", "全真理由")
local reasons = { "sensor", "stale", "visibility", "corridor", "obb", "state",
    "return", "align", "progress", "arc", "band", "sweep" }
for i = 1, #all do
    local args = {}
    for j = 1, #all do args[j] = true end
    args[i] = false
    local pass, why = D.fullSpeedGate(table.unpack(args))
    eq(pass, false, "第 " .. i .. " gate fail")
    eq(why, reasons[i], "第 " .. i .. " 具名理由")
end
for i = 1, #reasons do
    local cap, why = D.ungatedCapKmh(120, reasons[i], 90)
    check(type(cap) == "number" and cap >= 0 and cap < 120,
        "gate false bit " .. i .. " produces a real strict cap")
    if i <= 5 or i == 12 then check(cap <= 15, "near-field gate bit <=15 #" .. i) end
    eq(why, reasons[i], "ungated reason remains named #" .. i)
end
local zeroCap, zeroReason = D.ungatedCapKmh(0, "align", 0)
eq(zeroCap, 0, "zero full target is a legal arrived cap")
eq(zeroReason, "align", "zero full target does not become dynamics-invalid")

scenario("jerk invariant and named hard bypass")
local v, a = 0, 0
local dt, lastA = 0.05, 0
for _ = 1, 200 do
    v, a = D.jerkCommand(v, a, 30, dt, 2.5, 6, 2)
    check(math.abs(a - lastA) <= 2 * dt + 1e-12, "正常 transition |da|<=j*dt")
    lastA = a
    check(v <= 30 + 1e-12, "normal jerk command never overshoots desired")
end
local hv, ha, bypass = D.jerkCommand(v, a, 5, dt, 2.5, 6, 2, 3, "visibility")
near(hv, 3, 1e-12, "hard cap 立即 clamp")
near(ha, 0, 1e-12, "bypass 後 command acceleration 歸零")
eq(bypass, "visibility", "bypass 必須具名")
local iv, ia, ir = D.jerkCommand(1, 0, 2, 0 / 0, 2.5, 6, 2)
eq(iv, 0, "invalid jerk scalar fail-stops")
eq(ia, 0, "invalid jerk acceleration clears")
eq(ir, "dynamics-invalid", "invalid jerk is named")
local noOverV, noOverA = D.jerkCommand(10, 2, 11, 1, 2.5, 6, 2)
check(noOverV <= 11, "10m/s command with positive acceleration cannot overshoot 11m/s")
check(math.abs(noOverA - 2) <= 2 * 0.25 + 1e-12,
    "stopping-aware unwind still obeys jerk after dt clamp")
local landV, landA, landReason = D.jerkCommand(10, 2.5, 10.01, 0.25, 2.5, 6, 2)
near(landV, 10.01, 1e-12, "infeasible last-step landing uses exact desired speed")
near(landA, 0, 1e-12, "landing bypass resets acceleration state coherently")
eq(landReason, "landing", "infeasible jerk landing is explicitly named")

scenario("dynamic lateral shift length／space inverse／dodge class")
local l1 = D.shiftLength(1, 5, 3.5, 0.2, 2, 2)
local l2 = D.shiftLength(2, 5, 3.5, 0.2, 2, 2)
local l3 = D.shiftLength(2, 10, 3.5, 0.2, 2, 2)
check(l2 >= l1, "側移量增加，L 不減")
check(l3 >= l2, "速度增加，L 不減")
check(l1 >= 4, "L>=2*halfL")
local space20 = D.shiftSpaceSpeedCapKmh(2, 20, 3.5, 2.5, 0.7, 0.25, 120, 2)
local space10 = D.shiftSpaceSpeedCapKmh(2, 10, 3.5, 2.5, 0.7, 0.25, 120, 2)
check(space10 < space20, "空間縮短，反解速度 cap 下降")
local staticCap = D.dodgeSpeedCapKmh(60, 60, 60, 60, 60, D.DODGE_STATIC, false)
local vehicleCap = D.dodgeSpeedCapKmh(60, 60, 60, 60, 60, D.DODGE_VEHICLE, false)
local squeezeCap = D.dodgeSpeedCapKmh(60, 60, 60, 60, 60, D.DODGE_STATIC, true)
check(staticCap > 28, "寬裕 static 公式可高於 28")
check(vehicleCap <= 15, "stopped/moving vehicle 不高於 15")
check(squeezeCap <= 10, "squeeze 保留低 cap")
local badCap, _, badReason = D.dodgeSpeedCapKmh(
    60, 60, 0 / 0, 60, 60, D.DODGE_STATIC, false)
eq(badCap, 0, "invalid dodge scalar fail-stops")
eq(badReason, "dynamics-invalid", "invalid dodge scalar is named")

scenario("C1 fillet／band union／metadata／fallback")
local src = { 0, 0, 30, 0, 30, 30 }
local surface, width = { 1, 2 }, { 12, 10 }
local pts, ss, sw, kind, sa, sb, radius = {}, {}, {}, {}, {}, {}, {}
local n, fn, fallback, valid = D.buildFilletPath(src, surface, width, 1, 3,
    pts, ss, sw, kind, sa, sb, radius)
eq(valid, true, "fillet build valid")
eq(fn, 1, "90° 可行折點生成 fillet")
eq(fallback, 0, "可行折點不 fallback")
eq(#ss, n - 1, "segSurface 與輸出 segment 對齊")
eq(#sw, n - 1, "segWidth 與輸出 segment 對齊")
eq(#kind, n - 1, "seg kind 對齊")
local firstArc, lastArc
for i = 1, n - 1 do
    check(type(ss[i]) == "number" and type(sw[i]) == "number", "metadata 無洞 #" .. i)
    local dx, dy = pts[i * 2 + 1] - pts[i * 2 - 1], pts[i * 2 + 2] - pts[i * 2]
    check(math.sqrt(dx * dx + dy * dy) <= 1.000001 or kind[i] == 0,
        "arc sample spacing <=1m #" .. i)
    if kind[i] == 1 then
        firstArc = firstArc or i
        lastArc = i
        check(radius[i] >= 3, "R>=rMin #" .. i)
        eq(ss[i], 2, "mixed paved/gravel arc takes rougher surface")
        local mx = (pts[i * 2 - 1] + pts[i * 2 + 1]) * 0.5
        local my = (pts[i * 2] + pts[i * 2 + 2]) * 0.5
        local d1 = D.distanceToSegmentSq(mx, my, 0, 0, 30, 0)
        local d2 = D.distanceToSegmentSq(mx, my, 30, 0, 30, 30)
        local b1, b2 = 12 / 2 - 1 - 0.4, 10 / 2 - 1 - 0.4
        check(d1 <= b1 * b1 + 1e-8 or d2 <= b2 * b2 + 1e-8,
            "arc midpoint 在兩 source road-band union #" .. i)
    end
end
check(firstArc ~= nil and lastArc ~= nil, "找得到 arc segment")
local up, us, uw, uk, ua, ub, ur = {}, {}, {}, {}, {}, {}, {}
local un = D.buildFilletPath(src, { 0, 3 }, { 12, 10 }, 1, 3,
    up, us, uw, uk, ua, ub, ur)
local sawUnknownArc = false
for i = 1, un - 1 do
    if uk[i] == D.SEG_ARC then
        sawUnknownArc = true
        eq(us[i], 0, "any unknown source makes mixed arc surface unknown")
    end
end
check(sawUnknownArc, "unknown/dirt metadata test generated an arc")
local maxK = D.polylineKappaMax((function()
    local x = {}; for i = 1, n do x[i] = pts[i * 2 - 1] end; return x end)(),
    (function() local y = {}; for i = 1, n do y[i] = pts[i * 2] end; return y end)(), n)
check(maxK <= 1 / 3 + 1e-3, "fillet kappa<=1/rMin")
local tInX, tInY = pts[firstArc * 2 - 1] - pts[firstArc * 2 - 3], pts[firstArc * 2] - pts[firstArc * 2 - 2]
local tArcX, tArcY = pts[firstArc * 2 + 1] - pts[firstArc * 2 - 1], pts[firstArc * 2 + 2] - pts[firstArc * 2]
local crossIn = math.abs(tInX * tArcY - tInY * tArcX)
    / math.sqrt((tInX * tInX + tInY * tInY) * (tArcX * tArcX + tArcY * tArcY))
check(crossIn < 0.08, "fillet entry tangent C1")

local p2, s2, w2, k2, a2, b2, r2 = {}, {}, {}, {}, {}, {}, {}
local n2, fn2, fb2 = D.buildFilletPath(src, surface, { 3, 3 }, 1, 3,
    p2, s2, w2, k2, a2, b2, r2)
eq(fn2, 0, "窄 band 不生成假 fillet")
local sawFallbackKind = false
for i = 1, #k2 do if k2[i] == D.SEG_FALLBACK then sawFallbackKind = true end end
check(sawFallbackKind, "raw fallback is localized in per-segment metadata")
check(fb2 >= 1 and n2 == 3, "窄 band 保留原折點＋fallback")
local u = { 0, 0, 20, 0, 10, 17.3205080757 }
local p3, s3, w3, k3, a3, b3, r3 = {}, {}, {}, {}, {}, {}, {}
local n3, fn3, fb3 = D.buildFilletPath(u, { 1, 1 }, { 20, 20 }, 1, 2,
    p3, s3, w3, k3, a3, b3, r3)
eq(fn3, 0, ">90° 保留折點")
local hugePts, hugeSurface, hugeWidth = {}, {}, {}
local oversize = D.FILLET_SOURCE_MAX + 1
for i = 1, oversize do
    hugePts[i * 2 - 1], hugePts[i * 2] = i, 0
    if i < oversize then hugeSurface[i], hugeWidth[i] = 1, 12 end
end
local hn, _, _, hv, hr = D.buildFilletPath(
    hugePts, hugeSurface, hugeWidth, 1, 3, {}, {}, {}, {}, {}, {}, {})
eq(hn, 0, "oversize source never enters synchronous fillet expansion")
eq(hv, false, "oversize fillet falls back")
eq(hr, "capacity", "oversize fillet reason is deterministic")
check(fb3 >= 1 and n3 == 3, "U-turn/急折點低速 fallback")

scenario("hot scalar helpers do not retain per-call tables")
collectgarbage("collect")
local kb0 = collectgarbage("count")
local vv, aa = 0, 0
for i = 1, 50000 do
    vv, aa = D.jerkCommand(vv, aa, 20, 0.016, 2.5, 6, 2)
    D.fullSpeedGate(true, true, true, true, true, true, true, true, true, true, true, true)
    D.visibilityCapKmh(110, 0.5, 3, 2)
    D.shiftLength(2, 10, 3.5, 0.1, 2, 2)
end
collectgarbage("collect")
local kb1 = collectgarbage("count")
check(kb1 - kb0 < 16, "hot scalar calls retained <16KB（實得 " .. tostring(kb1 - kb0) .. "KB）")

print("  " .. (assertions - base) .. " 項斷言")
print()
print("情境 " .. scenarios .. " 個、斷言 " .. assertions .. " 項")
if failures > 0 then print(failures .. " 項失敗"); os.exit(1) end
print("全部通過")
