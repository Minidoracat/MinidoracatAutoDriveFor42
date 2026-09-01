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
near(D.crossTrackSteer(2, 15), 0.3696, 1e-12,
    "15km/h 右偏 2m 產生正向修正量")
near(D.crossTrackSteer(-2, 15), -0.3696, 1e-12,
    "cross-track 修正左右鏡像")
local highSpeedCross = D.crossTrackSteer(1.9, 70)
check(highSpeedCross > 0 and highSpeedCross < 0.08,
    "70km/h 的 cross-track 修正保持小幅")
near(D.crossTrackSteer(10, 0), 0.77, 1e-12,
    "低速大偏離夾在獨立的安全轉向增量上限")
near(D.crossTrackSteer(0 / 0, 15), 0, 1e-12,
    "非法 cross-track 輸入不產生推力")
near(D.longitudinalAssistRatio(0, 15), 0.2, 1e-12,
    "重車靜止且速度差充足時使用完整前推比例（2026-09-02 0.15→0.2）")
near(D.longitudinalAssistRatio(9.5, 10), 0, 1e-12,
    "距目標 1km/h 內不再前推（2026-09-02 斜坡提前：3→1）")
near(D.longitudinalAssistRatio(-1, 15), 0, 1e-12,
    "倒退中不施加向前推力")
near(D.longitudinalAssistRatio(25, 70), 0, 1e-12,
    "25km/h 以上交還原生引擎與 regulator")
near(D.longitudinalAssistRatio(0 / 0, 15), 0, 1e-12,
    "非法速度不產生前推比例")
-- 越野／繞行推力補償（2026-09-02 增幅加大：使用者裁定「越野增幅多一點」）：
-- rough 情境保底 ×ASSIST_OFFROAD_BASE（eff≈1 的普通車在草地也掉牽引，舊制
-- 1/eff 對它們＝零增幅）；效率更低的車取 1/eff；上限 ASSIST_OFFROAD_MAX。
near(D.assistOffroadScale(1), D.ASSIST_OFFROAD_BASE, 1e-12,
    "標定車（eff 1）也吃保底增幅（草地掉牽引是普遍事實）")
near(D.assistOffroadScale(0.5), D.ASSIST_OFFROAD_BASE, 1e-12, "效率 0.5 的 1/eff=2 低於保底 2.5＝吃保底")
near(D.assistOffroadScale(0.2), D.ASSIST_OFFROAD_MAX, 1e-12,
    "效率 0.2 的補償被上限夾住，不無限放大")
near(D.assistOffroadScale(2), D.ASSIST_OFFROAD_BASE, 1e-12,
    "效率優於標定仍吃保底（rough 已是事實）")
near(D.assistOffroadScale(nil), D.ASSIST_OFFROAD_BASE, 1e-12,
    "讀不到效率＝保底增幅（rough 由呼叫端把關）")
near(D.assistOffroadScale(0 / 0), D.ASSIST_OFFROAD_BASE, 1e-12, "非法效率＝保底")
near(D.assistOffroadScale(0), D.ASSIST_OFFROAD_BASE, 1e-12, "效率 0（除零）＝保底")
check(D.ASSIST_OFFROAD_BASE > 1 and D.ASSIST_OFFROAD_BASE < D.ASSIST_OFFROAD_MAX,
    "保底落在 (1, MAX) 帶內")
-- 橫向速度阻尼（2026-09-02 前臂化補課）：向線收斂太快（dLat 與 latDev 反號）
-- 時提前回打；遠離線（同號）時加強修正。第三參缺席＝原 P 行為不變。
near(D.crossTrackSteer(2, 36), D.crossTrackSteer(2, 36, nil), 1e-12,
    "無阻尼參數＝原 P 行為")
check(D.crossTrackSteer(2, 36, -3) < D.crossTrackSteer(2, 36),
    "朝線收斂中（dLat<0）阻尼提前回打（修正變小）")
check(D.crossTrackSteer(2, 36, 3) > D.crossTrackSteer(2, 36),
    "遠離線中（dLat>0）阻尼加強修正")
near(D.crossTrackSteer(0, 36, 0), 0, 1e-12, "在線且無橫速＝零修正")
check(D.crossTrackSteer(9, 36, 99) <= 0.77 + 1e-12,
    "PD 合成仍受最大轉向夾限")
-- ratio 端：on-road 行為完全不變（第三參數省略／1）；越野 scale 直接放大
near(D.longitudinalAssistRatio(0, 15), D.longitudinalAssistRatio(0, 15, 1), 1e-12,
    "省略 scale 等同 on-road scale 1（原契約不變）")
near(D.longitudinalAssistRatio(0, 15, 2), 0.40, 1e-12,
    "越野補償把上限一併放大（否則補償等於沒補）")
check(D.longitudinalAssistRatio(0, 15, 2) > D.longitudinalAssistRatio(0, 15),
    "同條件下越野 assist 嚴格大於 on-road")
near(D.longitudinalAssistRatio(0, 15, 99), 0.2 * D.ASSIST_OFFROAD_MAX, 1e-12,
    "ratio 端同樣夾上限（呼叫端傳爛值不得突破）")
near(D.longitudinalAssistRatio(0, 15, 0.1), 0.2, 1e-12,
    "scale<1 一律當 1（補償只會加不會減）")
near(D.longitudinalAssistRatio(0, 15, 0 / 0), 0.2, 1e-12, "非法 scale 退 1")
near(D.longitudinalAssistRatio(-1, 15, 2), 0, 1e-12,
    "倒退中即使在越野也不施加向前推力")
near(D.longitudinalAssistRatio(25, 70, 2), 0, 1e-12,
    "25km/h 以上即使在越野也交還原生引擎")
near(D.sweepRadius(0.7, 0.35, 0.05, 0.1), 0.95, 1e-12,
    "整格障礙的厚規劃 pad 補償 0.1 量化肥邊")
near(D.sweepRadius(0.7, 0.06, 0.05, 0.1), 0.76, 1e-12,
    "薄規劃 pad 不補償：規劃半徑永不低於物理包絡")
near(D.sweepRadius(0.7, 0.15, 0.05, 0.1), 0.85, 1e-12,
    "補償門檻邊界（pad=phys+comp）不觸發")
near(D.sweepRadius(0.4, 0.35, 0.05, 0.1), 0.75, 1e-12,
    "非整格障礙（樹幹細桿）不補償")

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
-- 15 地板只留近場未知三位：sensor(1)/obb(5)/sweep(12)。stale/visibility/
-- corridor 改走 90%（上限 80）比例檔——固定 15 會覆蓋連續 visibilityCap
--（2026-09-01 三模型對抗審 P0；植入違規驗證：改回 15 清單本表即紅）。
for i = 1, #reasons do
    local cap, why = D.ungatedCapKmh(120, reasons[i], 90)
    check(type(cap) == "number" and cap >= 0 and cap < 120,
        "gate false bit " .. i .. " produces a real strict cap")
    if i == 1 or i == 5 or i == 12 then
        check(cap <= 18, "near-field gate bit <=18（2026-09-02 警戒帽 15→18）#" .. i)
    elseif i == 8 then
        near(cap, 90, 1e-9, "align bit follows the supplied alignment cap")
    else
        check(cap > 15, "proportional gate bit stays above 15 #" .. i)
        check(cap <= 80, "proportional gate bit respects 80 ceiling #" .. i)
    end
    eq(why, reasons[i], "ungated reason remains named #" .. i)
end
local visCap = D.ungatedCapKmh(85, "visibility", 0)
near(visCap, 76.5, 1e-9,
    "visibility gate failure is proportional (85×0.9), never the old 15 floor")
local staleCap = D.ungatedCapKmh(60, "stale", 0)
near(staleCap, 54, 1e-9, "stale gate failure is proportional (90%)")
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
local staticCap = D.dodgeSpeedCapKmh(60, 60, 60, 60, 60, D.DODGE_STATIC)
local vehicleCap = D.dodgeSpeedCapKmh(60, 60, 60, 60, 60, D.DODGE_VEHICLE)
check(staticCap > 28, "寬裕 static 公式可高於 28")
check(vehicleCap <= 20, "stopped/moving vehicle 不高於 20")
-- one-size squeeze 帽退役（2026-09-01 使用者裁定「速度隨餘裕連續縮放」）：
-- 縫餘裕經 clearanceCap 連續傳入，離散檔位不再另蓋一層
check(D.dodgeSpeedCapKmh(60, 60, 60, 7, 60, D.DODGE_STATIC) <= 7,
    "小餘裕由 clearanceCap 連續壓速（不靠離散爬行帽）")
check(D.dodgeSpeedCapKmh(60, 60, 60, 60, 60, D.DODGE_STATIC) == staticCap,
    "大餘裕不再被 one-size 爬行帽壓 10")
local badCap, _, badReason = D.dodgeSpeedCapKmh(
    60, 60, 0 / 0, 60, 60, D.DODGE_STATIC)
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

scenario("alignmentCapKmh：彎中常態姿態不罰、爬行地板無條件（2026-09-01 s060/s062）")
-- 彎中 err 11.5°（<15°）、lat 在容差內：正常過彎姿態不受罰（舊 5° 閾值會壓 0.25×）
eq(D.alignmentCapKmh(40, 0.20, 0.3, 0.5, true), 40, "err<15° 且 lat 在容差內不壓速")
-- s060 調頭現場：err 118°、lat 3、target 12（Follower 調頭爬行）→ 地板 12
-- （舊條件地板只在 target>12 生效，12×0.2=2.4 → 引擎 bang-bang 執行不出＝僵死）
eq(D.alignmentCapKmh(12, 2.06, 3.0, 0.5, false), 12, "調頭姿態 target 12 地板保住爬行")
-- target 已低於爬行（近終點制動段）：全額放行，不再打折
eq(D.alignmentCapKmh(8, 2.06, 3.0, 0.5, false), 8, "target<12 全額傳遞")
-- 未對齊仍壓（err 34°>15°）但絕不低於爬行檔
local ac = D.alignmentCapKmh(40, 0.6, 0.3, 0.5, true)
check(ac < 40 and ac >= 12, "err 34° 仍壓速但不低於爬行（實得 " .. tostring(ac) .. "）")

scenario("buildFilletPath：臂長預算按角間距、不按取樣段（2026-09-01 過彎太慢定罪）")
-- 4m 取樣、兩臂各 12m 的 90° 路口（住宅區真實幾何）＋皮卡 rMin 5：
-- 舊版預算按取樣段（4×0.45=1.8 < rMin）→ 整批 fallback 爬行 7 km/h。
-- 新版共線點不吃預算 → r=0.45×12=5.4 ≥ rMin → fillet 成功。
do
    local pts = {0,0, 4,0, 8,0, 12,0, 12,4, 12,8, 12,12}
    local oR = {}
    local count, fN, fbN, valid = D.buildFilletPath(
        pts, {1,1,1,1,1,1}, {7,7,7,7,7,7}, 0.9, 5, {}, {}, {}, {}, {}, {}, oR)
    local rMax = 0
    for i = 1, count do if oR[i] and oR[i] > rMax then rMax = oR[i] end end
    check(valid == true and fN == 1 and fbN == 0,
        "4m 取樣 12m 臂 90° 角 fillet 成功（fillet=" .. tostring(fN)
        .. " fallback=" .. tostring(fbN) .. "）")
    check(rMax >= 5, "半徑吃滿角間臂（實得 " .. tostring(rMax) .. "）")
    -- 對照：真短臂（4m 到頭）幾何真的不夠 → 照舊 fallback 爬行
    local c2, f2, fb2 = D.buildFilletPath(
        {0,0, 4,0, 4,4}, {1,1}, {7,7}, 0.9, 5, {}, {}, {}, {}, {}, {}, {})
    check(f2 == 0 and fb2 == 1, "真 4m 短臂照舊 fallback（安全語意保留）")
    -- Z 字相鄰雙角共享 10m 臂：各吃 45%、合計 ≤90% 不重疊
    local o3R = {}
    local c3, f3, fb3 = D.buildFilletPath(
        {0,0, 5,0, 10,0, 10,5, 10,10, 15,10, 20,10},
        {1,1,1,1,1,1}, {7,7,7,7,7,7}, 0.9, 3, {}, {}, {}, {}, {}, {}, o3R)
    local r3 = 0
    for i = 1, c3 do if o3R[i] and o3R[i] > r3 then r3 = o3R[i] end end
    check(f3 == 2 and fb3 == 0 and r3 * 2 <= 10 + 1e-9,
        "相鄰雙角共享臂不重疊（r=" .. tostring(r3) .. "）")
    -- 被弧跨過的共線取樣點不得輸出（2026-09-02 s035 實機：T 字切點距真角 3.1m、
    -- tangent 5.5m，輸出「切點→退回 tangent 點→弧」＝導航線倒鉤、車壓到 12 km/h）。
    -- 同一條 12m 臂：tangent 5.4 吞掉 (8,0) 與 (12,4)，(4,0)／(12,8) 在跨距外保留。
    local oP, oK = {}, {}
    local oc = D.buildFilletPath(pts, {1,1,1,1,1,1}, {7,7,7,7,7,7}, 0.9, 5,
        oP, {}, {}, oK, {}, {}, {})
    local worstTurn, saw8, saw4 = 0, false, false
    for i = 2, oc - 1 do
        local ax, ay = oP[i*2-1] - oP[i*2-3], oP[i*2] - oP[i*2-2]
        local bx, by = oP[i*2+1] - oP[i*2-1], oP[i*2+2] - oP[i*2]
        local la, lb = math.sqrt(ax*ax + ay*ay), math.sqrt(bx*bx + by*by)
        if la > 1e-9 and lb > 1e-9 then
            local c = (ax*bx + ay*by) / (la*lb)
            if c < -1 then c = -1 elseif c > 1 then c = 1 end
            local deg = math.deg(math.acos(c))
            if deg > worstTurn then worstTurn = deg end
        end
    end
    for i = 1, oc do
        if oP[i*2-1] == 8 and oP[i*2] == 0 then saw8 = true end
        if oP[i*2-1] == 4 and oP[i*2] == 0 then saw4 = true end
    end
    check(worstTurn < 45, "弧跨過的共線點不輸出＝無倒鉤（最大折角 "
        .. string.format("%.1f", worstTurn) .. "°）")
    check(not saw8, "tangent 跨距內的共線點 (8,0) 被吞掉")
    check(saw4, "跨距外的共線點 (4,0) 保留")
end

scenario("classifyIntent：優先序與八輪衝突的 characterization 矩陣（重構階段 1）")
-- 參數順序：currentBlocked, reached, dynamicsFault, recovering, rotating,
--           blockedStop, followHold, returnHold, visCap, squeeze, warm,
--           returnUnsafe, sensorReady
local function intent(over)
    local p = { false, false, false, false, false,
        false, false, false, 40, false, false, false, true }
    for k, v in pairs(over) do p[k] = v end
    return D.classifyIntent(p[1], p[2], p[3], p[4], p[5], p[6], p[7],
        p[8], p[9], p[10], p[11], p[12], p[13])
end
-- 基本態
eq(intent({}), "GO", "全清＝GO")
eq(intent({ [1] = true }), "STOP", "contact＝STOP")
eq(intent({ [2] = true }), "STOP", "reached＝STOP")
eq(intent({ [3] = true }), "STOP", "dynamicsFault＝STOP")
eq(intent({ [4] = true }), "RECOVER", "恢復鏈進行中＝RECOVER")
eq(intent({ [5] = true }), "ROTATE", "調頭姿態＝ROTATE")
eq(intent({ [6] = true }), "WAIT", "blockedStop＝WAIT")
eq(intent({ [7] = true }), "WAIT", "followHold＝WAIT")
eq(intent({ [8] = true }), "WAIT", "returnHold＝WAIT")
eq(intent({ [9] = 0 }), "WAIT", "可視歸零＝WAIT（衝突 2：壓停不是卡死）")
eq(intent({ [10] = true }), "CRAWL", "squeeze＝CRAWL")
eq(intent({ [11] = true }), "CRAWL", "首輪掃描前＝CRAWL")
eq(intent({ [13] = false }), "CRAWL", "感知未就緒＝CRAWL")
-- 優先序（衝突史核心）
eq(intent({ [1] = true, [4] = true, [5] = true }), "STOP",
    "contact 蓋過 recover/rotate")
eq(intent({ [4] = true, [5] = true, [9] = 0 }), "RECOVER",
    "恢復鏈蓋過 rotate 與可視歸零")
eq(intent({ [5] = true, [9] = 0 }), "ROTATE",
    "衝突 5：調頭不因可視歸零降級成 WAIT（幾何盲區豁免的意圖化）")
eq(intent({ [5] = true, [6] = true }), "ROTATE",
    "衝突 5：調頭不因走廊反向掃 blocked 降級成 WAIT")
eq(intent({ [6] = true, [10] = true }), "WAIT",
    "WAIT 蓋 CRAWL（停等優先於爬行）")
eq(intent({ [9] = 0, [13] = false }), "WAIT",
    "可視歸零蓋感知未就緒")
-- MIN_EXEC 契約（階段 2 首步）：可視低於最低可執行速度＝執行不出的減速
-- 要求＝WAIT；恰在門檻上＝GO（powered command 非 0 即 ≥MIN_EXEC）。
eq(intent({ [9] = 0.5 }), "WAIT", "visCap 0.5 < MIN_EXEC＝WAIT（不准抬 target 蓋煞停證明）")
eq(intent({ [9] = D.MIN_EXEC_KMH - 0.01 }), "WAIT", "visCap 恰低於 MIN_EXEC＝WAIT")
eq(intent({ [9] = D.MIN_EXEC_KMH }), "GO", "visCap 恰等於 MIN_EXEC＝GO")
check(D.MIN_EXEC_KMH >= 8 and D.MIN_EXEC_KMH <= 12,
    "MIN_EXEC 落在引擎 bang-bang 可執行帶（實得 " .. tostring(D.MIN_EXEC_KMH) .. "）")

scenario("waitProgressed：停等預算的真進度判準（階段 2 主體 1）")
-- TRACK：沿線淨前進滿 10m 才算真進度；9.99m 不算（零星蠕動不得續命）
check(D.waitProgressed(false, false, D.WAIT_PROGRESS_M, 0, 0),
    "TRACK 淨前進 10m＝真進度")
check(not D.waitProgressed(false, false, D.WAIT_PROGRESS_M - 0.01, 0, 0),
    "TRACK 淨前進 9.99m 不算")
check(not D.waitProgressed(false, false, -20, 0, 0), "沿線倒退不算進度")
-- ROTATE：原地轉的沿線 s 無意義，只認角誤差收斂
check(D.waitProgressed(true, false, 0, 0, D.WAIT_CONVERGE_RAD),
    "ROTATE 角誤收斂 5°＝真進度")
check(not D.waitProgressed(true, false, 999, 999, 0),
    "ROTATE 不吃沿線／橫偏進度（幾何盲區）")
check(not D.waitProgressed(true, false, 0, 0, -0.5),
    "ROTATE 角誤擴大不算進度")
-- RETURN：回線中沿線前進不代表回到車道，只認橫偏收斂
check(D.waitProgressed(false, true, 0, D.WAIT_CONVERGE_M, 0),
    "RETURN 橫偏收斂 0.5m＝真進度")
check(not D.waitProgressed(false, true, 999, 0, 999),
    "RETURN 不吃沿線／角誤進度（平行爬行不是回線）")
-- ROTATE 優先於 RETURN（調頭姿態下橫偏無意義）
check(not D.waitProgressed(true, true, 0, 99, 0),
    "ROTATE 蓋 RETURN 判準")
-- 非有限值一律 fail-closed（寧可交還玩家，不可假續命）
check(not D.waitProgressed(false, false, 0 / 0, 0, 0), "ds NaN fail-closed")
check(not D.waitProgressed(true, false, 0, 0, 1 / 0 - 1 / 0), "dErr NaN fail-closed")
check(not D.waitProgressed(false, true, 0, 0 / 0, 0), "dLat NaN fail-closed")
check(D.WAIT_PROGRESS_M >= 5 and D.WAIT_CONVERGE_M > 0 and D.WAIT_CONVERGE_RAD > 0,
    "預算門檻常數皆為正且 TRACK 門檻不低於 5m")

scenario("blockedNear：blocked 煞停判距以世界距離為權威（s045/s051 定罪）")
-- s045 實機重現：投影說車距群 1m（rs 39.5、bs 40.5），世界實距 18m。
-- 舊弧長判定＝25m 外停死；世界距離（呼叫端存的群最近擋線點）＝滑行接近。
-- s051 補課：點雲成員資格不可用弧長（blockS 舊快照 vs hardS 新快照脫節、
-- members=0 永遠退弧長）——簽名改吃 blockHitX/Y 座標錨。
check(not D.blockedNear(40.5, 39.5, 10, 10668, 9711, 10665.5, 9729.5),
    "投影差 1m 但世界距 18.7m＝不停（滑行接近）")
check(D.blockedNear(40.5, 39.5, 10, 10666, 9721, 10665.5, 9729.5),
    "世界距 8.5m＝煞停（同一錨點，車真的近了）")
-- 座標錨缺失→退投影弧長差（保守分支沒有擋線點）
check(D.blockedNear(40.5, 39.5, 10, 10668, 9711, nil, nil),
    "無錨退弧長：39.5 >= 30.5＝停")
check(not D.blockedNear(40.5, 25.0, 10, 10668, 9711, nil, nil),
    "無錨退弧長：25 < 30.5＝滑行")
-- fail-closed：輸入不可信一律煞停
check(D.blockedNear(0 / 0, 39.5, 10, 10668, 9711, 10665.5, 9729.5),
    "blockS NaN fail-closed")
check(D.blockedNear(40.5, 0 / 0, 10, 10668, 9711, nil, nil),
    "sNow NaN 且無錨 fail-closed")
check(D.blockedNear(40.5, 39.5, 10, 0 / 0, 9711, 10665.5, 9729.5),
    "車座標 NaN＝座標路徑失效退弧長（39.5>=30.5 停）")
-- corner 檔距（8m）同函式共用
check(not D.blockedNear(40.5, 39.5, 8, 10666, 9721, 10665.5, 9729.5),
    "corner 檔 8m：世界距 8.5m＝還不停")
-- 第二回傳＝世界距（telemetry wd）；退弧長時 nil
local _, wdA = D.blockedNear(40.5, 39.5, 10, 10668, 9711, 10665.5, 9729.5)
check(wdA ~= nil and wdA > 18 and wdA < 19, "第二回傳＝世界距 18.x")
local _, wdB = D.blockedNear(40.5, 39.5, 10, 10668, 9711, nil, nil)
check(wdB == nil, "退弧長時第二回傳 nil")



print("  " .. (assertions - base) .. " 項斷言")
print()
print("情境 " .. scenarios .. " 個、斷言 " .. assertions .. " 項")
if failures > 0 then print(failures .. " 項失敗"); os.exit(1) end
print("全部通過")

