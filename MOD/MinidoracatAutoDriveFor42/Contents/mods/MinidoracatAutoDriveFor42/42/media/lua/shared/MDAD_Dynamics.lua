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
D.ALIGN_HOLD_MS = 500
D.ALIGN_HEADING_RAD = 5 * PI / 180
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
D.DODGE_VEHICLE_CAP = 15
D.DODGE_SQUEEZE_CAP = 10

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
local CROSS_TRACK_GAIN = 0.77
local CROSS_TRACK_SPEED_FLOOR_MS = 2.5
local CROSS_TRACK_MAX_STEER = 0.77
function D.crossTrackSteer(latDev, speedKmh)
    if not D.finite(latDev) or not D.finite(speedKmh) then return 0 end
    local speedMs = speedKmh / 3.6
    if speedMs < 0 then speedMs = -speedMs end
    if speedMs < CROSS_TRACK_SPEED_FLOOR_MS then
        speedMs = CROSS_TRACK_SPEED_FLOOR_MS
    end
    local correction = CROSS_TRACK_GAIN * latDev / speedMs
    if correction > CROSS_TRACK_MAX_STEER then
        correction = CROSS_TRACK_MAX_STEER
    elseif correction < -CROSS_TRACK_MAX_STEER then
        correction = -CROSS_TRACK_MAX_STEER
    end
    return correction
end

local ASSIST_MAX_RATIO = 0.15
local ASSIST_GAP_MIN_KMH = 3
local ASSIST_GAP_FULL_KMH = 10
local ASSIST_SPEED_MAX_KMH = 25
function D.longitudinalAssistRatio(speedKmh, targetKmh)
    if not D.finite(speedKmh) or not D.finite(targetKmh)
            or speedKmh < 0 or targetKmh <= speedKmh + ASSIST_GAP_MIN_KMH
            or speedKmh >= ASSIST_SPEED_MAX_KMH then return 0 end
    local ratio = (targetKmh - speedKmh - ASSIST_GAP_MIN_KMH)
        / (ASSIST_GAP_FULL_KMH - ASSIST_GAP_MIN_KMH)
    if ratio > 1 then ratio = 1 end
    return ASSIST_MAX_RATIO * ratio
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
    if arcVerified ~= true then return false, "arc" end
    if bandVerified ~= true then return false, "band" end
    if worldVerified ~= true then return false, "sweep" end
    return true, "clear"
end

-- Every failed proof bit produces an actual finite cap. Near-field uncertainty
-- never exceeds 15km/h; state/alignment/progress proofs remain strictly below full.
function D.ungatedCapKmh(fullTarget, reason, alignmentCap)
    if not D.finite(fullTarget) or fullTarget < 0 or type(reason) ~= "string" then
        return 0, "dynamics-invalid"
    end
    if fullTarget == 0 then return 0, reason end
    local cap
    if reason == "sensor" or reason == "stale" or reason == "visibility"
            or reason == "corridor" or reason == "obb" or reason == "sweep" then
        cap = 15
        if cap >= fullTarget then cap = fullTarget * 0.85 end
    elseif reason == "align" and D.finite(alignmentCap) and alignmentCap >= 0 then
        cap = alignmentCap
        if cap >= fullTarget then cap = fullTarget * 0.85 end
    else
        cap = fullTarget * 0.85
        if cap > 70 then cap = 70 end
    end
    if cap < 0 then cap = 0 end
    if cap >= fullTarget then cap = fullTarget * 0.85 end
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
    if cap < 12 and targetKmh > 12 then cap = 12 end
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

function D.dodgeSpeedCapKmh(gearCap, profileCap, curveCap, clearanceCap,
        visibilityCap, classId, squeeze)
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
    if squeeze == true and D.DODGE_SQUEEZE_CAP < classCap then
        classCap = D.DODGE_SQUEEZE_CAP
    end
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
    local radii, signA, fallbackCorner = {}, {}, {}
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
                    local maxT = il * D.FILLET_SEGMENT_SHARE
                    local shareOut = ol * D.FILLET_SEGMENT_SHARE
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
                        radii[i], signA[i] = radius, sign
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
            count = appendPoint(outPts, outSurface, outWidth, outKind,
                outSourceA, outSourceB, outRadius, count, px, py,
                srcSurface[i - 1], srcWidth[i - 1],
                fallbackCorner[i - 1] and D.SEG_FALLBACK or D.SEG_LINE,
                i - 1, i - 1, 0)
            local steps = arcSteps(radius * theta, theta)
            local a0 = atan2(py - ccy, px - ccx)
            local surface = conservativeSurface(srcSurface[i - 1], srcSurface[i])
            local width = srcWidth[i - 1]
            if srcWidth[i] < width then width = srcWidth[i] end
            for j = 1, steps do
                local a = a0 + signA[i] * theta * (j / steps)
                count = appendPoint(outPts, outSurface, outWidth, outKind,
                    outSourceA, outSourceB, outRadius, count,
                    ccx + cos(a) * radius, ccy + sin(a) * radius,
                    surface, width, D.SEG_ARC, i - 1, i, radius)
            end
            filletN = filletN + 1
        else
            local fallback = fallbackCorner[i] or fallbackCorner[i - 1]
            count = appendPoint(outPts, outSurface, outWidth, outKind,
                outSourceA, outSourceB, outRadius, count, bx, by,
                srcSurface[i - 1], srcWidth[i - 1],
                fallback and D.SEG_FALLBACK or D.SEG_LINE, i - 1, i - 1, 0)
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
