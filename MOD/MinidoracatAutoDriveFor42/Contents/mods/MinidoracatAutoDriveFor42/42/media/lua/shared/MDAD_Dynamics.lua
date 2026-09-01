-- MDAD_Dynamics.lua -- shared, pure scalar vehicle/path dynamics.
-- No PZ API. Hot-path helpers return only scalars and allocate no tables.

MDADDynamics = MDADDynamics or {}
if MDADDynamics.finite then return end

local D = MDADDynamics
local sqrt, sin, cos, tan = math.sqrt, math.sin, math.cos, math.tan
local acos = math.acos
local atan2 = math.atan2 or math.atan
local PI = math.pi
local DEG20 = 20 * PI / 180
local DEG90 = PI * 0.5
local EPS = 1e-9

D.JERK_MAX = 2                 -- m/s^3, provisional until telemetry calibration
D.LATERAL_JERK_MAX = 2         -- m/s^3, same conservative provisional bound
D.SNAPSHOT_FRESH_MS = 750
D.ALIGN_HOLD_MS = 250
-- 2026-09-01 telemetry s062（capReason align 137 筆、S 彎壓到 4 km/h 蠕動）：
-- 彎中 heading error 12-15° 是前視點幾何常態，5° 閾值把正常過彎姿態當
-- 「未對齊」二次懲罰（剖面已為彎減速）。15° 起罰、22° 破遲滯（維持 ~1.5×
-- 非對稱），對齊資格更穩、full gate 不再被彎中姿態反覆打斷。
D.ALIGN_BREAK_RAD = 22 * PI / 180
D.ALIGN_HEADING_RAD = 15 * PI / 180
D.FILLET_SAMPLE_MAX_M = 1
D.FILLET_MIN_RAD = DEG20
D.FILLET_MAX_RAD = DEG90
D.FILLET_SEGMENT_SHARE = 0.45  -- two adjacent corners therefore consume <=90%
D.ROAD_EDGE_MARGIN = 0.4
D.FILLET_ANGLE_MAX_RAD = 2 * PI / 180
D.FILLET_SOURCE_MAX = 64
D.FILLET_OUTPUT_MAX = 512
D.FILLET_ARC_MAX = 64
D.FILLET_FIT_ITERS = 4
D.SEG_LINE = 0
D.SEG_ARC = 1
D.SEG_FALLBACK = 2

D.DODGE_STATIC = 1
D.DODGE_VEHICLE = 2
D.DODGE_STATIC_CAP = 160
D.DODGE_VEHICLE_CAP = 20
D.DODGE_SQUEEZE_CAP = 12

function D.finite(n)
    return type(n) == "number" and n * 0 == 0
end

function D.distanceToSegmentSq(px, py, ax, ay, bx, by)
    local ex, ey = bx - ax, by - ay
    local den = ex * ex + ey * ey
    local t = 0
    if den > 0 then
        t = ((px - ax) * ex + (py - ay) * ey) / den
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local dx, dy = px - ax - ex * t, py - ay - ey * t
    return dx * dx + dy * dy
end
function D.rawBandContains(rawPts, rawWidths, src, halfW, x, y)
    if type(rawPts) ~= "table" or type(rawWidths) ~= "table"
            or not D.finite(src) or not D.finite(halfW)
            or not D.finite(x) or not D.finite(y) then return false end
    local width = rawWidths[src]
    if not D.finite(width) then return false end
    local erode = width * 0.5 - halfW - D.ROAD_EDGE_MARGIN
    local p = src * 2 - 1
    return erode > 0 and D.finite(rawPts[p]) and D.finite(rawPts[p + 3])
        and D.distanceToSegmentSq(x, y,
            rawPts[p], rawPts[p + 1], rawPts[p + 2], rawPts[p + 3])
            <= erode * erode
end

-- The source-band union is non-convex. Splitting at the midpoint is continuous:
-- each half-chord must have both endpoints in the same convex source capsule.
function D.chordCoveredByBand(rawPts, rawWidths, sourceA, sourceB, halfW,
        x0, y0, x1, y1)
    if not (D.finite(x0) and D.finite(y0) and D.finite(x1) and D.finite(y1)) then
        return false
    end
    local mx, my = (x0 + x1) * 0.5, (y0 + y1) * 0.5
    local a0 = D.rawBandContains(rawPts, rawWidths, sourceA, halfW, x0, y0)
    local b0 = D.rawBandContains(rawPts, rawWidths, sourceB, halfW, x0, y0)
    local am = D.rawBandContains(rawPts, rawWidths, sourceA, halfW, mx, my)
    local bm = D.rawBandContains(rawPts, rawWidths, sourceB, halfW, mx, my)
    local a1 = D.rawBandContains(rawPts, rawWidths, sourceA, halfW, x1, y1)
    local b1 = D.rawBandContains(rawPts, rawWidths, sourceB, halfW, x1, y1)
    return ((a0 and am) or (b0 and bm))
        and ((am and a1) or (bm and b1))
end

-- Three-point circumcircle curvature. Collinear/degenerate triples return zero.
function D.circumcircleKappa(ax, ay, bx, by, cx, cy)
    if not (D.finite(ax) and D.finite(ay) and D.finite(bx) and D.finite(by)
            and D.finite(cx) and D.finite(cy)) then return 0 end
    local abx, aby = bx - ax, by - ay
    local bcx, bcy = cx - bx, cy - by
    local acx, acy = cx - ax, cy - ay
    local ab2 = abx * abx + aby * aby
    local bc2 = bcx * bcx + bcy * bcy
    local ac2 = acx * acx + acy * acy
    if ab2 <= EPS or bc2 <= EPS or ac2 <= EPS then return 0 end
    local cross = abx * bcy - aby * bcx
    if cross < 0 then cross = -cross end
    return 2 * cross / sqrt(ab2 * bc2 * ac2)
end

-- Conservative steering curvature reconstructed from the script's linear clamp.
function D.steeringKappa(wheelbase, delta0, deltaV, maxSpeedKmh, speedKmh)
    if not (D.finite(wheelbase) and wheelbase > 0 and D.finite(delta0) and delta0 > 0
            and D.finite(deltaV) and deltaV > 0 and D.finite(maxSpeedKmh)
            and maxSpeedKmh > 0) then return 0 end
    local v = speedKmh
    if not D.finite(v) then v = 0 end
    if v < 0 then v = -v end
    local t = v / maxSpeedKmh
    if t > 1 then t = 1 end
    local delta = delta0 + (deltaV - delta0) * t
    if delta <= 0 then return 0 end
    return tan(delta) / wheelbase
end

-- Highest speed whose linearly reduced steering clamp can supply kappa.
function D.steeringSpeedCapKmh(kappa, wheelbase, delta0, deltaV, maxSpeedKmh)
    if not (D.finite(maxSpeedKmh) and maxSpeedKmh > 0) then return 0 end
    if not D.finite(kappa) or kappa <= EPS then return maxSpeedKmh end
    if not (D.finite(wheelbase) and wheelbase > 0 and D.finite(delta0)
            and D.finite(deltaV) and delta0 >= deltaV and deltaV > 0) then return 0 end
    local deltaReq = math.atan(kappa * wheelbase)
    if delta0 == deltaV then
        if deltaReq <= delta0 then return maxSpeedKmh end
        return 0
    end
    if deltaReq >= delta0 then return 0 end
    if deltaReq <= deltaV then return maxSpeedKmh end
    local cap = maxSpeedKmh * (delta0 - deltaReq) / (delta0 - deltaV)
    if cap < 0 then return 0 end
    if cap > maxSpeedKmh then return maxSpeedKmh end
    return cap
end

-- Stanley-style cross-track term in follower steer units. Driver subtracts the
-- signed correction because positive latDev is right of the committed lane.
-- Gain and clamp happen to share 0.77; they are independent tuning limits.
-- 量綱註記：P 項 Kp·e/v（秒）、D 項 Kd·ė/v（無因次）——刻意的經驗式相加，
-- 相對權重與車速無關（純量綱一致版 Kd·ė/v² 在低速會過度阻尼）；行為由
-- test_dynamics 的 PD 契約鎖住，調參不改式。
local CROSS_TRACK_GAIN = 0.77
local CROSS_TRACK_DAMP = 0.35  -- 橫向速度阻尼（2026-09-02 前臂化補課：s026
                               -- 定罪彎中 |ld| 1.23→2.17——前臂側移與轉向
                               -- 同向後位置環失去後臂時代的天然阻尼，車帶著
                               -- 橫向速度衝過線再慢慢擺回＝「彎尾不順」。
                               -- P→PD：朝線收斂太快就提前回打）
local CROSS_TRACK_SPEED_FLOOR_MS = 2.5
local CROSS_TRACK_MAX_STEER = 0.77
function D.crossTrackSteer(latDev, speedKmh, dLatPerSec)
    if not D.finite(latDev) or not D.finite(speedKmh) then return 0 end
    local speedMs = speedKmh / 3.6
    if speedMs < 0 then speedMs = -speedMs end
    if speedMs < CROSS_TRACK_SPEED_FLOOR_MS then
        speedMs = CROSS_TRACK_SPEED_FLOOR_MS
    end
    local correction = CROSS_TRACK_GAIN * latDev / speedMs
    if D.finite(dLatPerSec) then
        correction = correction + CROSS_TRACK_DAMP * dLatPerSec / speedMs
    end
    if correction > CROSS_TRACK_MAX_STEER then
        correction = CROSS_TRACK_MAX_STEER
    elseif correction < -CROSS_TRACK_MAX_STEER then
        correction = -CROSS_TRACK_MAX_STEER
    end
    return correction
end

local ASSIST_MAX_RATIO = 0.2   -- 0.15→0.2（2026-09-02 使用者裁定「推力要增加」）
local ASSIST_GAP_MIN_KMH = 1   -- 3→1（2026-09-02 質量等比評估：實測 ratio 只用到
local ASSIST_GAP_FULL_KMH = 6  -- 0.056/上限 0.225——瓶頸是斜坡不是上限；低速差
                               -- 6 km/h 即滿載，rough 卡住救援提前到位）
local ASSIST_SPEED_MAX_KMH = 25
-- 越野／繞行推力補償（2026-09-01 使用者裁定：「車子如果在非道路上，自動駕駛
-- 可以提供推力，協助早點回到正確道路上；包括繞行的時候，可以用推力幫助加速
-- 通過，才不會有卡住的情況」）。
-- offroadEff＝VehicleScript.getOffroadEfficiency（VehicleScript.java:2002-2003，
-- 值域 (0,10]，1 是標定越野能力）。rough 情境一律保底 ×BASE（普通車草地也掉
-- 牽引），效率更低的車取 1/eff，上限 ×MAX。讀不到（nil／非法）＝保底 BASE
-- （rough 已由呼叫端確認為事實，fail-safe 方向仍是「不亂放大」）。
D.ASSIST_OFFROAD_MAX = 5     -- 4→5（2026-09-02 二次上調：非道路推力更大）
D.ASSIST_OFFROAD_BASE = 2.5  -- 2→2.5：rough 保底增幅（疊乘重車超線性 massScale
                             -- 後，2600kg 重車草地滿載可達 ratio×mass×5×2）
function D.assistOffroadScale(offroadEff)
    local scale = D.ASSIST_OFFROAD_BASE
    if D.finite(offroadEff) and offroadEff > 0 then
        local byEff = 1 / offroadEff
        if byEff > scale then scale = byEff end
    end
    -- BASE ≥ 1 且只會被 1/eff 抬高：下限 1 由 BASE 保證，無需再夾
    if scale > D.ASSIST_OFFROAD_MAX then return D.ASSIST_OFFROAD_MAX end
    return scale
end
-- offroadScale 由呼叫端以 assistOffroadScale 導出；on-road 傳 nil／1 即原行為。
-- 上限一併放大（否則補償只是把已經飽和的比例再乘一次，等於沒補）。
function D.longitudinalAssistRatio(speedKmh, targetKmh, offroadScale)
    if not D.finite(speedKmh) or not D.finite(targetKmh)
            or speedKmh < 0 or targetKmh <= speedKmh + ASSIST_GAP_MIN_KMH
            or speedKmh >= ASSIST_SPEED_MAX_KMH then return 0 end
    local ratio = (targetKmh - speedKmh - ASSIST_GAP_MIN_KMH)
        / (ASSIST_GAP_FULL_KMH - ASSIST_GAP_MIN_KMH)
    if ratio > 1 then ratio = 1 end
    local scale = offroadScale
    if not D.finite(scale) or scale < 1 then scale = 1
    elseif scale > D.ASSIST_OFFROAD_MAX then scale = D.ASSIST_OFFROAD_MAX end
    return ASSIST_MAX_RATIO * ratio * scale
end


function D.curveSpeedCapKmh(kappa, aLat, wheelbase, delta0, deltaV, maxSpeedKmh)
    if not (D.finite(maxSpeedKmh) and maxSpeedKmh > 0) then return 0 end
    if not D.finite(kappa) or kappa <= EPS then return maxSpeedKmh end
    if not D.finite(aLat) or aLat <= 0 then return 0 end
    local cap = 3.6 * sqrt(aLat / kappa)
    local steer = D.steeringSpeedCapKmh(kappa, wheelbase, delta0, deltaV, maxSpeedKmh)
    if steer < cap then cap = steer end
    if cap > maxSpeedKmh then cap = maxSpeedKmh end
    if cap < 0 then cap = 0 end
    return cap
end

-- D = v*tau + v^2/(2*aBrake) + halfL + 2.
function D.stoppingDistance(vMs, tau, aBrake, halfL)
    if not D.finite(vMs) then vMs = 0 end
    if vMs < 0 then vMs = -vMs end
    if not D.finite(tau) or tau < 0 then tau = 0 end
    if not D.finite(halfL) or halfL < 0 then halfL = 0 end
    if not D.finite(aBrake) or aBrake <= 0 then return halfL + 2 end
    return vMs * tau + vMs * vMs / (2 * aBrake) + halfL + 2
end

function D.visibilityCapKmh(visibleAhead, tau, aBrake, halfL)
    if not D.finite(visibleAhead) or visibleAhead <= 0
            or not D.finite(aBrake) or aBrake <= 0 then return 0 end
    if not D.finite(tau) or tau < 0.5 then tau = 0.5 end
    if not D.finite(halfL) or halfL < 0 then halfL = 0 end
    local room = visibleAhead - halfL - 2
    if room <= 0 then return 0 end
    local at = aBrake * tau
    local v = -at + sqrt(at * at + 2 * aBrake * room)
    if v < 0 then v = 0 end
    return v * 3.6
end
-- Full-speed is an all-true proof. Reasons are interned literals, not allocations.
-- sweep 檢查排在 arc/band 之前：煞停視界內的世界掃掠真命中必須歸因 "sweep"
--（近場警戒帽 18，ungatedCapKmh），不得被同幀的證明距離不足搶先改名成
-- "arc"（90% 比例檔）——近場實體障礙與證明品質是不同風險等級（2026-09-01）。
function D.fullSpeedGate(sensorReady, fresh, brakeLoaded, corridorClear, obbClear,
        track, returnDone, aligned, progressHealthy, arcVerified, bandVerified, worldVerified)
    if sensorReady ~= true then return false, "sensor" end
    if fresh ~= true then return false, "stale" end
    if brakeLoaded ~= true then return false, "visibility" end
    if corridorClear ~= true then return false, "corridor" end
    if obbClear ~= true then return false, "obb" end
    if track ~= true then return false, "state" end
    if returnDone ~= true then return false, "return" end
    if aligned ~= true then return false, "align" end
    if progressHealthy ~= true then return false, "progress" end
    if worldVerified ~= true then return false, "sweep" end
    if arcVerified ~= true then return false, "arc" end
    if bandVerified ~= true then return false, "band" end
    return true, "clear"
end


-- 繞行解析 cap（curve/space 假 0 族）的抬升下限（2026-09-02 使用者「繞行速度
-- 再快一點」）：比 MIN_EXEC 高一檔——這些是解析公式的量化假 0，不是真物理
-- 極限；世界掃掠終審把關、contact fail-closed 兜底。
D.DODGE_CAP_FLOOR_KMH = 15   -- 12→15（2026-09-02 s008 剖析：curve FLOOR 主導
                             -- 12-14.7 km/h 全程順跑無 contact＝還有餘裕）
-- 最低可執行速度（2026-09-01 階段 2 首步，codex 契約）：引擎 regulator 是
-- bang-bang（throttle 固定 0.5、超速斷油掛 N，CarController.java:240-245、522），
-- (0, 8) km/h 的目標物理上執行不出來——只會蠕動或誤觸卡死監督。
-- 不變式：powered command 必須是 0 或 ≥ MIN_EXEC。可視上限低於 MIN_EXEC
-- 時歸 WAIT（該停就停），不准用 max() 抬高安全證明。
D.MIN_EXEC_KMH = 8
-- blocked 煞停判距（2026-09-01 s045/s051 兩輪遙測定罪）：route 繞遠／橫偏時
-- 投影弧長虛高（s045 弧長差 1m、世界實距 18m，25m 外停死）；點雲成員資格
-- 也不可用弧長——blockS 是「判 blocked 那輪快照」的弧長、hardS 是當前快照
-- 的弧長，車一移動兩基準就脫節（s051 members=0 → 永遠退弧長）。權威判準＝
-- 車到「群最近擋線點」（呼叫端 blocked 時解析並存於 blockHitX/Y）的世界
-- 歐氏距離；座標缺失才退投影弧長差。
-- 輸入不可信時回 true（fail-closed 煞停，與 contact 同語意）。
-- 第二回傳＝世界距離（座標路徑才有，退弧長時 nil）——telemetry 用。
function D.blockedNear(blockS, sNow, stopDist, vx, vy, hitX, hitY)
    if not D.finite(blockS) or not D.finite(stopDist) then return true end
    if D.finite(hitX) and D.finite(hitY)
            and D.finite(vx) and D.finite(vy) then
        local dx, dy = hitX - vx, hitY - vy
        local d2 = dx * dx + dy * dy
        return d2 <= stopDist * stopDist, sqrt(d2)
    end
    if not D.finite(sNow) then return true end
    return sNow >= blockS - stopDist
end

-- 意圖分類（2026-09-01 架構重構階段 1，codex＋Grok 對抗審共識）：八輪實機
-- 衝突的共同根因是「十幾個 cap 依序 min()，監督層再拿結果數字反推該走/該停
-- /卡死」——速度數字承擔了它表達不了的語意。這裡把語意抽成顯式意圖，
-- 優先序第一命中、interned 字串、零 table（比照 fullSpeedGate）。
-- 契約：
--   STOP    = 車身接觸／已到站／動力學失效——必須零速。
--   RECOVER = 恢復鏈進行中（unstick/settle/gear-reset/recover）。
--   ROTATE  = 調頭姿態（follower rotating）——visibility/blocked 的路線
--             前向語意不適用（幾何盲區），不得把它降級成 WAIT。
--   WAIT    = 合法停等（blockedStop/followHold/returnHold/可視歸零）——
--             預算計時歸 WAIT 全體，不逐旗標各自為政。
--   CRAWL   = 保守爬行（squeeze/首輪掃描前/return-unsafe/感知未就緒）。
--   GO      = 正常跟線；cap min() 只該修飾 GO/CRAWL 的數字。
-- 階段 1 僅 shadow（telemetry 驗證分類），不接管行為；階段 2 才由意圖
-- 驅動 demand／wait-budget／MIN_EXEC。
function D.classifyIntent(currentBlocked, reached, dynamicsFault,
        recovering, rotating, blockedStop, followHold, returnHold,
        visibilityCapKmh, squeeze, warm, returnUnsafe, sensorReady)
    if currentBlocked == true or reached == true or dynamicsFault == true then
        return "STOP"
    end
    if recovering == true then return "RECOVER" end
    if rotating == true then return "ROTATE" end
    if blockedStop == true or followHold == true or returnHold == true
            or (D.finite(visibilityCapKmh)
                and visibilityCapKmh < D.MIN_EXEC_KMH) then
        -- 可視上限低於最低可執行速度＝執行不出的減速要求＝該停等；
        -- 不准抬 target 蓋過煞停證明（codex 契約）。
        return "WAIT"
    end
    if squeeze == true or warm == true or returnUnsafe == true
            or sensorReady ~= true then
        return "CRAWL"
    end
    return "GO"
end

-- 停等預算的「真進度」判準（2026-09-01 階段 2 主體 1，codex 契約）。
-- 舊制 waitSince 的重置條件是「任一 1m 世界位移／10° yaw／route cutover／
-- recover 循環」，於是同一個未解決僵局可以無限續命——實測 40s+ 乾等後才
-- 紅字。真進度只有三種，且必須與當下意圖相稱：
--   ROTATE  → 角誤差收斂（原地轉的沿線 s 沒有意義）
--   RETURN  → 橫向偏差收斂（回線中沿線前進不代表回到車道）
--   其餘    → 沿線淨前進（TRACK：真的往目標走了一段）
-- ds／dLat／dErr 一律是「相對本 episode 錨點的改善量」（呼叫端先取絕對值
-- 再相減），非有限值一律不算進度＝fail-closed（寧可交還玩家不可假續命）。
D.WAIT_PROGRESS_M = 10
D.WAIT_CONVERGE_M = 0.5
D.WAIT_CONVERGE_RAD = 8.7266462599716e-2 -- 5°
function D.waitProgressed(rotating, returnActive, ds, dLat, dErr)
    if rotating == true then
        return D.finite(dErr) and dErr >= D.WAIT_CONVERGE_RAD
    end
    if returnActive == true then
        return D.finite(dLat) and dLat >= D.WAIT_CONVERGE_M
    end
    return D.finite(ds) and ds >= D.WAIT_PROGRESS_M
end

-- 只有「近場未知」才配警戒帽：sensor 未 ready、車身 OBB 接觸不確定、世界掃掠
-- 證明缺失。其餘 gate 失敗走比例檔——2026-09-01 三模型對抗審定案（Grok #1
-- blocker）：stale／visibility／corridor 一律打固定地板會覆蓋 stepFollow 已經
-- 算好的連續 visibilityCapKmh（快照年齡已由 tau 膨脹反映在該 cap 裡），Sport
-- 70＋潮濕/重車下 brakeLoaded 幾乎永久失敗＝空直路被鎖死。visibility 的真正
-- 防線是連續煞停證明與 breach forceBrake，不是這裡的固定地板。
-- 2026-09-02 整體提速裁定：警戒帽 15→18、比例 0.85→0.9、上限 70→80；三個
-- 分支的「cap ≥ fullTarget 退比例」統一用同一個 UNGATED_RATIO（舊制近場／
-- align 分支殘留 0.85 是裝訂遺漏，不是刻意保守）。
local UNGATED_RATIO = 0.9
local UNGATED_NEAR_CAP_KMH = 18
local UNGATED_MAX_KMH = 80
function D.ungatedCapKmh(fullTarget, reason, alignmentCap)
    if not D.finite(fullTarget) or fullTarget < 0 or type(reason) ~= "string" then
        return 0, "dynamics-invalid"
    end
    if fullTarget == 0 then return 0, reason end
    local cap
    if reason == "sensor" or reason == "obb" or reason == "sweep" then
        cap = UNGATED_NEAR_CAP_KMH
    elseif reason == "align" and D.finite(alignmentCap) and alignmentCap >= 0 then
        cap = alignmentCap
    else
        cap = fullTarget * UNGATED_RATIO
        if cap > UNGATED_MAX_KMH then cap = UNGATED_MAX_KMH end
    end
    if cap < 0 then cap = 0 end
    if cap >= fullTarget then cap = fullTarget * UNGATED_RATIO end
    return cap, reason
end

function D.lowerHardCap(currentCap, currentReason, candidateCap, candidateReason)
    if not D.finite(currentCap) or currentCap < 0
            or not D.finite(candidateCap) or candidateCap < 0
            or type(currentReason) ~= "string" or type(candidateReason) ~= "string" then
        return 0, "dynamics-invalid", false
    end
    if currentReason == "dynamics-invalid" then return 0, currentReason, false end
    if candidateCap <= currentCap then return candidateCap, candidateReason, true end
    return currentCap, currentReason, true
end

-- A non-gated line remains proportional to its measured alignment error; the
-- 500ms settle window uses 85% rather than reintroducing a fixed 70km/h ceiling.
function D.alignmentCapKmh(targetKmh, headingError, latDev, latTol, settled)
    if not D.finite(targetKmh) or targetKmh <= 0 then return 0 end
    local ah = headingError
    if not D.finite(ah) then ah = PI end
    if ah < 0 then ah = -ah end
    local al = latDev
    if not D.finite(al) then al = 99 end
    if al < 0 then al = -al end
    if not D.finite(latTol) or latTol <= 0 then latTol = 0.5 end
    local ratio = 1
    if ah > D.ALIGN_HEADING_RAD then ratio = D.ALIGN_HEADING_RAD / ah end
    if al > latTol then
        local lr = latTol / al
        if lr < ratio then ratio = lr end
    end
    if settled ~= true and ratio > 0.85 then ratio = 0.85 end
    if ratio < 0.2 then ratio = 0.2 end
    local cap = targetKmh * ratio
    -- 地板無條件化（2026-09-01 s060/s062）：舊版只在 targetKmh>12 時地板，
    -- target 已被彎剖面壓到 ≤12 再乘 ratio 會出 2-4 km/h——引擎 regulator
    -- 是 bang-bang（throttle 固定 0.5，CarController.java:240-245），這種目標
    -- 執行不出來＝蠕動或僵住（調頭 12×0.2=2.4 恆停）。正常玩家姿態再歪也
    -- 保持怠速爬行邊走邊修，不會停下來等姿態變好。
    if cap < 12 then cap = targetKmh < 12 and targetKmh or 12 end
    if cap > targetKmh then cap = targetKmh end
    return cap
end

-- cmdV is m/s, cmdA is m/s^2. Normal steps use jerk-bounded trapezoidal
-- integration and start unwinding at a^2/(2j), so they never cross desiredV.
function D.jerkCommand(cmdV, cmdA, desiredV, dt, aDrive, aBrake, jMax, hardCapV, hardReason)
    if not D.finite(cmdV) or cmdV < 0 or not D.finite(cmdA)
            or not D.finite(desiredV) or desiredV < 0
            or not D.finite(dt) or dt <= 0
            or not D.finite(aDrive) or aDrive < 0
            or not D.finite(aBrake) or aBrake < 0
            or not D.finite(jMax) or jMax <= 0 then
        return 0, 0, "dynamics-invalid"
    end
    if dt > 0.25 then dt = 0.25 end
    local dv = desiredV - cmdV
    local dir = dv >= 0 and 1 or -1
    local distance = dv
    if distance < 0 then distance = -distance end
    local alongA = cmdA * dir
    local aReq = dir > 0 and aDrive or -aBrake
    if distance <= EPS then
        aReq = 0
    elseif alongA > 0 and alongA * alongA / (2 * jMax) >= distance then
        aReq = 0
    end
    local daMax = jMax * dt
    local da = aReq - cmdA
    if da > daMax then da = daMax elseif da < -daMax then da = -daMax end
    local nextA = cmdA + da
    if nextA > aDrive then nextA = aDrive elseif nextA < -aBrake then nextA = -aBrake end
    local nextV = cmdV + (cmdA + nextA) * 0.5 * dt
    local crossed = (dir > 0 and nextV > desiredV) or (dir < 0 and nextV < desiredV)
    if crossed then
        local lastA = 2 * (desiredV - cmdV) / dt - cmdA
        local lo, hi = cmdA - daMax, cmdA + daMax
        if lastA >= lo and lastA <= hi and lastA <= aDrive and lastA >= -aBrake then
            nextA, nextV = lastA, desiredV
        else
            return desiredV, 0, "landing"
        end
    end
    if nextV < 0 then nextV, nextA = 0, 0 end
    if D.finite(hardCapV) and hardCapV >= 0 and nextV > hardCapV then
        return hardCapV, 0, type(hardReason) == "string" and hardReason or "hard"
    elseif hardCapV ~= nil and (not D.finite(hardCapV) or hardCapV < 0) then
        return 0, 0, "dynamics-invalid"
    end
    return nextV, nextA, nil
end

function D.shiftLength(deltaL, speedMs, aLat, kSteer, halfL, jLat)
    if not D.finite(deltaL) then return 0, 0, 0, 0 end
    if deltaL < 0 then deltaL = -deltaL end
    if not D.finite(speedMs) or speedMs < 0 then speedMs = 0 end
    if not D.finite(halfL) or halfL < 0 then halfL = 0 end
    if not D.finite(jLat) or jLat <= 0 then jLat = D.LATERAL_JERK_MAX end
    local base = 2 * halfL
    if base < 2 then base = 2 end
    if deltaL <= EPS then return base, 0, 0, 0 end
    if not D.finite(aLat) or aLat <= 0 or not D.finite(kSteer) or kSteer <= 0 then
        return 0, 0, 0, 0
    end
    local kLat = kSteer
    if speedMs > EPS then
        local byAccel = aLat / (speedMs * speedMs)
        if byAccel < kLat then kLat = byAccel end
    end
    if kLat <= 0 then return 0, 0, 0, 0 end
    local lLat = sqrt(6 * deltaL / kLat)
    local lJerk = speedMs * (12 * deltaL / jLat) ^ (1 / 3)
    local length = base
    if lLat > length then length = lLat end
    if lJerk > length then length = lJerk end
    return length, kLat, lLat, lJerk
end

function D.shiftSpaceSpeedCapKmh(deltaL, available, aLat, wheelbase,
        delta0, deltaV, maxSpeedKmh, jLat)
    if not D.finite(deltaL) then return 0 end
    if deltaL < 0 then deltaL = -deltaL end
    if deltaL <= EPS then return maxSpeedKmh end
    if not D.finite(available) or available <= 0 or not D.finite(aLat) or aLat <= 0 then return 0 end
    if not D.finite(jLat) or jLat <= 0 then jLat = D.LATERAL_JERK_MAX end
    local vLat = sqrt(aLat * available * available / (6 * deltaL)) * 3.6
    local vJerk = available * (jLat / (12 * deltaL)) ^ (1 / 3) * 3.6
    local kReq = 6 * deltaL / (available * available)
    local vSteer = D.steeringSpeedCapKmh(kReq, wheelbase, delta0, deltaV, maxSpeedKmh)
    local cap = maxSpeedKmh
    if vLat < cap then cap = vLat end
    if vJerk < cap then cap = vJerk end
    if vSteer < cap then cap = vSteer end
    if cap < 0 then cap = 0 end
    return cap
end

function D.polylineKappaMax(xs, ys, n)
    if type(xs) ~= "table" or type(ys) ~= "table" or not D.finite(n) then return 0 end
    n = n - n % 1
    if n < 3 then return 0 end
    local best = 0
    for i = 2, n - 1 do
        local k = D.circumcircleKappa(
            xs[i - 1], ys[i - 1], xs[i], ys[i], xs[i + 1], ys[i + 1])
        if k > best then best = k end
    end
    return best
end
-- 世界掃掠的有效碰撞半徑：整格障礙（r>=0.5）的圓形近似比 1x1 方格角落
-- 多出量化肥邊，規劃 pad 夠厚才補償；扣除後永不低於物理 pad 包絡。
function D.sweepRadius(r, pointPad, physPad, comp)
    local rr = r + pointPad
    if r >= 0.5 and pointPad > physPad + comp then
        rr = rr - comp
    end
    return rr
end


function D.clearanceCapKmh(minClearance, errorReserve, tau, aLat, sinHeading)
    if not D.finite(minClearance) or not D.finite(aLat) or aLat <= 0 then return 0 end
    if not D.finite(errorReserve) or errorReserve < 0 then errorReserve = 0.4 end
    if not D.finite(tau) or tau < 0 then tau = 0.5 end
    local margin = minClearance - errorReserve
    if margin <= 0 then return 0 end
    local at = aLat * tau
    local u = sqrt(at * at + 2 * aLat * margin) - at
    local sh = sinHeading
    if not D.finite(sh) then sh = 1 end
    if sh < 0 then sh = -sh end
    if sh < 0.05 then sh = 0.05 end
    return 3.6 * u / sh
end

-- 繞行速度上限＝連續物理量的 min（2026-09-01 使用者裁定「確定可過＝全油門、
-- 速度隨餘裕縮放」）：clearanceCap（縫餘裕連續）、spaceCap（過渡長連續，經
-- profileCap 入口）、curveCap（曲率）、visibilityCap（可視）。舊 one-size
-- squeeze 帽（縫再大也 10）退役——margin 0.05 的縫由 clearanceCap 自然壓到
-- 個位數、margin 1.0 自然放行 30+，不需離散檔位再蓋一層。
function D.dodgeSpeedCapKmh(gearCap, profileCap, curveCap, clearanceCap,
        visibilityCap, classId)
    if not (D.finite(gearCap) and gearCap >= 0
            and D.finite(profileCap) and profileCap >= 0
            and D.finite(curveCap) and curveCap >= 0
            and D.finite(clearanceCap) and clearanceCap >= 0
            and D.finite(visibilityCap) and visibilityCap >= 0)
            or (classId ~= D.DODGE_STATIC and classId ~= D.DODGE_VEHICLE) then
        return 0, 0, "dynamics-invalid"
    end
    local cap = gearCap
    if profileCap < cap then cap = profileCap end
    if curveCap < cap then cap = curveCap end
    if clearanceCap < cap then cap = clearanceCap end
    if visibilityCap < cap then cap = visibilityCap end
    local classCap = D.DODGE_STATIC_CAP
    if classId == D.DODGE_VEHICLE then classCap = D.DODGE_VEHICLE_CAP end
    if classCap < cap then cap = classCap end
    return cap, classCap, nil
end

local function conservativeSurface(a, b)
    if a == 0 or b == 0 then return 0 end
    if a == b then return a end
    if a > b then return a end
    return b
end

local function appendPoint(outPts, outSurface, outWidth, outKind, outSourceA, outSourceB,
        outRadius, count, x, y, surface, width, kind, sourceA, sourceB, radius)
    if count > 0 then
        local ox, oy = outPts[count * 2 - 1], outPts[count * 2]
        if ox == x and oy == y then return count end
    end
    count = count + 1
    outPts[count * 2 - 1], outPts[count * 2] = x, y
    if count > 1 then
        local s = count - 1
        outSurface[s], outWidth[s], outKind[s] = surface, width, kind
        outSourceA[s], outSourceB[s], outRadius[s] = sourceA, sourceB, radius
    end
    return count
end

-- Interior turn angle at a corner, from its unit in/out directions.
local function cornerTheta(inX, inY, outX, outY)
    local dot = inX * outX + inY * outY
    if dot < -1 then dot = -1 elseif dot > 1 then dot = 1 end
    return acos(dot)
end

-- Unit in/out directions of corner b plus the raw source segment lengths.
-- Coincident points give zero directions; callers gate on the returned lengths.
local function cornerDirs(ax, ay, bx, by, cx, cy)
    local ix, iy, ox, oy = bx - ax, by - ay, cx - bx, cy - by
    local il, ol = sqrt(ix * ix + iy * iy), sqrt(ox * ox + oy * oy)
    if il <= EPS or ol <= EPS then return 0, 0, 0, 0, il, ol end
    return ix / il, iy / il, ox / ol, oy / ol, il, ol
end

-- Arc subdivision satisfies both chord length <=1m and tangent error <=2deg.
local function arcSteps(arc, theta)
    local steps = arc / D.FILLET_SAMPLE_MAX_M
    local angleSteps = theta / D.FILLET_ANGLE_MAX_RAD
    if angleSteps > steps then steps = angleSteps end
    local whole = steps - steps % 1
    if whole < steps then whole = whole + 1 end
    if whole < 1 then whole = 1 end
    return whole
end

-- Fillet arc of corner b: turn angle, tangent entry point, arc centre.
local function filletGeometry(bx, by, inX, inY, outX, outY, radius, turnSign)
    local theta = cornerTheta(inX, inY, outX, outY)
    local tangent = radius * tan(theta * 0.5)
    local px, py = bx - inX * tangent, by - inY * tangent
    local nx, ny = -inY * turnSign, inX * turnSign
    return theta, px, py, px + nx * radius, py + ny * radius
end

local function filletFits(ax, ay, bx, by, cx0, cy0, inX, inY, outX, outY,
        radius, turnSign, bandA, bandB)
    local theta, px, py, cx, cy = filletGeometry(
        bx, by, inX, inY, outX, outY, radius, turnSign)
    local steps = arcSteps(radius * theta, theta)
    if steps > D.FILLET_ARC_MAX then return false end
    local a0 = atan2(py - cy, px - cx)
    local halfStep = theta / steps * 0.5
    local sagitta = radius * (1 - cos(halfStep))
    for j = 0, steps do
        local a = a0 + turnSign * theta * (j / steps)
        local x, y = cx + cos(a) * radius, cy + sin(a) * radius
        local da = sqrt(D.distanceToSegmentSq(x, y, ax, ay, bx, by)) + sagitta
        local db = sqrt(D.distanceToSegmentSq(x, y, bx, by, cx0, cy0)) + sagitta
        if da > bandA and db > bandB then return false end
        if j < steps then
            a = a0 + turnSign * theta * ((j + 0.5) / steps)
            x, y = cx + cos(a) * radius, cy + sin(a) * radius
            da = sqrt(D.distanceToSegmentSq(x, y, ax, ay, bx, by)) + sagitta
            db = sqrt(D.distanceToSegmentSq(x, y, bx, by, cx0, cy0)) + sagitta
            if da > bandA and db > bandB then return false end
        end
    end
    return true
end

-- Builds an owned path copy. Eligible corners use tangent circular geometry, emitted
-- as a driven polyline with <=1m chords and <=2° tangent error; infeasible/>90°
-- corners retain the source vertex as SEG_FALLBACK. Adjacent 45% shares consume <=90%.
function D.buildFilletPath(srcPts, srcSurface, srcWidth, halfW, rMin,
        outPts, outSurface, outWidth, outKind, outSourceA, outSourceB, outRadius)
    if type(srcPts) ~= "table" or type(srcSurface) ~= "table" or type(srcWidth) ~= "table"
            or type(outPts) ~= "table" or type(outSurface) ~= "table"
            or type(outWidth) ~= "table" or type(outKind) ~= "table"
            or type(outSourceA) ~= "table" or type(outSourceB) ~= "table"
            or type(outRadius) ~= "table" or not D.finite(halfW) or halfW <= 0
            or not D.finite(rMin) or rMin <= 0 then return 0, 0, 0, false end
    local n = #srcPts / 2
    if n < 2 or n % 1 ~= 0 or n > D.FILLET_SOURCE_MAX
            or #srcSurface ~= n - 1 or #srcWidth ~= n - 1 then
        return 0, 0, 0, false, "capacity"
    end
    -- 臂長預算（2026-09-01 定罪「過彎太慢／減速太早」）：tangent 消耗上限
    -- 舊版按**相鄰取樣段長**×SHARE——12m 直臂被 4m 取樣切碎後 90° 角只分到
    -- 1.8m，半徑永遠小於車輛 rMin（皮卡 ~5m）→ 住宅區路網所有路口整批
    -- fallback 爬行。改按「沿嚴格共線臂的累積折線長」：取樣點偏角 ≤
    -- FILLET_ANGLE_MAX_RAD（2°，既有「視為直線」閾值）才可穿越累積——
    -- tangent 點的幾何放置假設臂是直線（沿緊鄰段方向延伸），微彎（2°~20°）
    -- 一旦穿越，tangent 點就會偏出實際路線畫出鬼圈（2026-09-01 實機：S 彎
    -- 連續 10° 折點被當共線，導航線彎成三角圈）。相鄰兩真角共享直臂 L 時
    -- 各吃 0.45L 合計 ≤0.9L——防重疊不變式原樣保留。
    -- 弧不出路面仍由 bandA/bandB sagitta 與 filletFits 把關，安全語意不動。
    local armIn, armOut = {}, {}
    do
        local isBend = {}
        for i = 2, n - 1 do
            local ix, iy, ox, oy, il, ol = cornerDirs(
                srcPts[i * 2 - 3], srcPts[i * 2 - 2],
                srcPts[i * 2 - 1], srcPts[i * 2],
                srcPts[i * 2 + 1], srcPts[i * 2 + 2])
            isBend[i] = il <= EPS or ol <= EPS
                or cornerTheta(ix, iy, ox, oy) > D.FILLET_ANGLE_MAX_RAD
        end
        local acc = 0
        for i = 2, n - 1 do
            local dx = srcPts[i * 2 - 1] - srcPts[i * 2 - 3]
            local dy = srcPts[i * 2] - srcPts[i * 2 - 2]
            acc = acc + sqrt(dx * dx + dy * dy)
            armIn[i] = acc
            if isBend[i] then acc = 0 end
        end
        acc = 0
        for i = n - 1, 2, -1 do
            local dx = srcPts[i * 2 + 1] - srcPts[i * 2 - 1]
            local dy = srcPts[i * 2 + 2] - srcPts[i * 2]
            acc = acc + sqrt(dx * dx + dy * dy)
            armOut[i] = acc
            if isBend[i] then acc = 0 end
        end
    end
    local radii, signA, tanS, fallbackCorner = {}, {}, {}, {}
    local filletN, fallbackN = 0, 0
    for i = 2, n - 1 do
        local ax, ay = srcPts[i * 2 - 3], srcPts[i * 2 - 2]
        local bx, by = srcPts[i * 2 - 1], srcPts[i * 2]
        local cx, cy = srcPts[i * 2 + 1], srcPts[i * 2 + 2]
        local ix, iy, ox, oy, il, ol = cornerDirs(ax, ay, bx, by, cx, cy)
        if il > EPS and ol > EPS then
            local theta = cornerTheta(ix, iy, ox, oy)
            if theta >= D.FILLET_MIN_RAD then
                local cross = ix * oy - iy * ox
                local radius
                if theta <= D.FILLET_MAX_RAD and cross * cross > EPS then
                    local bandA = srcWidth[i - 1] * 0.5 - halfW - D.ROAD_EDGE_MARGIN
                    local bandB = srcWidth[i] * 0.5 - halfW - D.ROAD_EDGE_MARGIN
                    local maxT = armIn[i] * D.FILLET_SEGMENT_SHARE
                    local shareOut = armOut[i] * D.FILLET_SEGMENT_SHARE
                    if shareOut < maxT then maxT = shareOut end
                    local tanHalf = tan(theta * 0.5)
                    local upper = tanHalf > EPS and maxT / tanHalf or 0
                    local sagittaScale = 1 - cos(theta * 0.5)
                    local maxBand = bandA
                    if bandB > maxBand then maxBand = bandB end
                    if sagittaScale > EPS then
                        local bandUpper = maxBand / sagittaScale
                        if bandUpper < upper then upper = bandUpper end
                    end
                    local sign = cross >= 0 and 1 or -1
                    if bandA > 0 and bandB > 0 and upper >= rMin
                            and filletFits(ax, ay, bx, by, cx, cy, ix, iy, ox, oy,
                                rMin, sign, bandA, bandB) then
                        radius = upper
                        if not filletFits(ax, ay, bx, by, cx, cy, ix, iy, ox, oy,
                                radius, sign, bandA, bandB) then
                            local lo, hi = rMin, upper
                            for _ = 1, D.FILLET_FIT_ITERS do
                                local mid = (lo + hi) * 0.5
                                if filletFits(ax, ay, bx, by, cx, cy, ix, iy, ox, oy,
                                        mid, sign, bandA, bandB) then lo = mid else hi = mid end
                            end
                            radius = lo
                        end
                        radii[i], signA[i], tanS[i] = radius, sign, radius * tanHalf
                    end
                end
                -- Angle-eligible corners that cannot host an arc keep the source
                -- vertex; the explicit crawl fallback owns them.

                if not radius then
                    fallbackN = fallbackN + 1
                    fallbackCorner[i] = true
                end
            end
        end
    end
    local predicted = 2
    for i = 2, n - 1 do
        if radii[i] then
            local ix, iy, ox, oy = cornerDirs(
                srcPts[i * 2 - 3], srcPts[i * 2 - 2],
                srcPts[i * 2 - 1], srcPts[i * 2],
                srcPts[i * 2 + 1], srcPts[i * 2 + 2])
            local theta = cornerTheta(ix, iy, ox, oy)
            predicted = predicted + 1 + arcSteps(radii[i] * theta, theta)
        else
            predicted = predicted + 1
        end
        if predicted > D.FILLET_OUTPUT_MAX then
            return 0, 0, fallbackN, false, "capacity"
        end
    end

    -- 臂長預算升級後 tangent 點可落在角的緊鄰段之外（共線臂上游），source
    -- 若仍寫死 i-1/i，band 驗證的膠囊查找會撲空（點距 i-1 段端點可達十餘米）
    -- → 整條 proof 判 band fail。輸出點的 source 改記「實際最近的 raw 段」；
    -- 冷路徑（route 重建一次），n≤64、輸出 ≤512，全窗掃可負擔。
    local function nearestRawSeg(px, py)
        local best, bestD = 1, 1 / 0
        for si = 1, n - 1 do
            local p = si * 2 - 1
            local d = D.distanceToSegmentSq(px, py,
                srcPts[p], srcPts[p + 1], srcPts[p + 2], srcPts[p + 3])
            if d < bestD then best, bestD = si, d end
        end
        local sb = best + 1
        if sb > n - 1 then sb = n - 1 end
        return best, sb
    end
    -- 同一個預算升級的另一半：tangent 跨過共線取樣點後，被跨過的點若照序輸出，
    -- 折線會「先到取樣點、再退回 tangent 點、才進弧」＝倒鉤（2026-09-02 s035
    -- 實機：路網 T 字切點距真角 3.1m、tangent 5.5m，導航線在路口折返、曲率表把
    -- 該點壓到 12 km/h）。以 source 弧長判定：取樣點落在前一弧出口 tangent 之前
    -- 或下一弧入口 tangent 之後就跳過。tangent ≤ 0.45×共線臂、臂在 >2° 折點歸零，
    -- 所以被吞的只可能是共線取樣點，真折點（含 fallback 角）永不被跳過。
    local cum = { 0 }
    for i = 2, n do
        local dx = srcPts[i * 2 - 1] - srcPts[i * 2 - 3]
        local dy = srcPts[i * 2] - srcPts[i * 2 - 2]
        cum[i] = cum[i - 1] + sqrt(dx * dx + dy * dy)
    end
    local nextArc = {}
    do
        local k
        for i = n - 1, 2, -1 do
            if radii[i] then k = i end
            nextArc[i] = k
        end
    end
    local covered = -1
    local count = 0
    count = appendPoint(outPts, outSurface, outWidth, outKind, outSourceA, outSourceB,
        outRadius, count, srcPts[1], srcPts[2], 0, 0, 0, 0, 0, 0)
    for i = 2, n - 1 do
        local bx, by = srcPts[i * 2 - 1], srcPts[i * 2]
        local radius = radii[i]
        if radius then
            local ix, iy, ox, oy = cornerDirs(
                srcPts[i * 2 - 3], srcPts[i * 2 - 2], bx, by,
                srcPts[i * 2 + 1], srcPts[i * 2 + 2])
            local theta, px, py, ccx, ccy = filletGeometry(
                bx, by, ix, iy, ox, oy, radius, signA[i])
            local ta, tb = nearestRawSeg(px, py)
            count = appendPoint(outPts, outSurface, outWidth, outKind,
                outSourceA, outSourceB, outRadius, count, px, py,
                srcSurface[i - 1], srcWidth[i - 1],
                fallbackCorner[i - 1] and D.SEG_FALLBACK or D.SEG_LINE,
                ta, tb, 0)
            local steps = arcSteps(radius * theta, theta)
            local a0 = atan2(py - ccy, px - ccx)
            local surface = conservativeSurface(srcSurface[i - 1], srcSurface[i])
            local width = srcWidth[i - 1]
            if srcWidth[i] < width then width = srcWidth[i] end
            for j = 1, steps do
                local a = a0 + signA[i] * theta * (j / steps)
                local axp = ccx + cos(a) * radius
                local ayp = ccy + sin(a) * radius
                local aa, ab = nearestRawSeg(axp, ayp)
                count = appendPoint(outPts, outSurface, outWidth, outKind,
                    outSourceA, outSourceB, outRadius, count,
                    axp, ayp, surface, width, D.SEG_ARC, aa, ab, radius)
            end
            filletN = filletN + 1
            covered = cum[i] + tanS[i]
        else
            local k = nextArc[i]
            local swallowed = cum[i] <= covered + EPS
                or (k ~= nil and cum[k] - tanS[k] <= cum[i] + EPS)
            if not swallowed then
                local fallback = fallbackCorner[i] or fallbackCorner[i - 1]
                count = appendPoint(outPts, outSurface, outWidth, outKind,
                    outSourceA, outSourceB, outRadius, count, bx, by,
                    srcSurface[i - 1], srcWidth[i - 1],
                    fallback and D.SEG_FALLBACK or D.SEG_LINE, i - 1, i - 1, 0)
            end
        end
    end
    count = appendPoint(outPts, outSurface, outWidth, outKind,
        outSourceA, outSourceB, outRadius, count, srcPts[n * 2 - 1], srcPts[n * 2],
        srcSurface[n - 1], srcWidth[n - 1],
        fallbackCorner[n - 1] and D.SEG_FALLBACK or D.SEG_LINE,
        n - 1, n - 1, 0)
    if count > D.FILLET_OUTPUT_MAX then return 0, 0, fallbackN, false, "capacity" end
    return count, filletN, fallbackN, true, nil
end
