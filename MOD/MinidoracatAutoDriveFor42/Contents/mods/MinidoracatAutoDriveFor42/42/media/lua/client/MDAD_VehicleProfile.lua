-- MDAD_VehicleProfile.lua -- cached vehicle scalars for telemetry (Phase 1).
-- Observational only: never feeds AutoDrive control, speed, path, footprint, or steer force.
--
-- MDADVehicleProfile.build(vehicle) -> table of scalars:
--   valid, fallback, scriptName, bodyW, bodyL, halfW, halfL, mass, maxSpeed,
--   wheelbase, track, clamp0, clamp30, clampMax, wheelFriction,
--   delta0Safe, deltaVSafe, rMin, lookScale, rearArm, needHalf, probeR
-- Units: body/axle/radius/arm scalars are metres; mass is kg; maxSpeed is km/h;
-- steering clamps are radians; lookScale and wheelFriction are unitless.
--
-- Source: BaseVehicle runtime mass/maxSpeed plus VehicleScript getters once.
-- No Java instance fields (Kahlua does not expose them; LuaJavaClassExposer.java:292-324).
-- Extents via getExtents():x()/:z() (ISVehicleSeatUI.lua:206-207). Wheels via
-- getWheelById("FrontLeft"|"FrontRight"|"RearLeft"|"RearRight") then
-- getOffset():x()/:z() (VehicleScript.java:1729-1737,2705-2707).
-- Steering clamps via getSteeringClamp(speed) (VehicleScript.java:1678-1686).
--
-- Finite domains (unsupported -> valid=false, safe fallback, never throw):
--   bodyW [0.6, 3.5], bodyL [1.5, 12], runtime mass [200, 5000],
--   runtime maxSpeed (0, 1000], wheelbase [0.8, 7], track [0, 4],
--   wheelFriction (0, 2000] and all sampled clamps [0.1, 0.9], monotonic by sample speed.
-- Missing wheels: wheelbase = clamp(0.65 * bodyL, 0.8, 6).
-- State meanings: (valid,!fallback)=all sources measured; (valid,fallback)=
-- in-domain wheel estimate; (!valid,fallback)=patchwork safe substitutions.
-- The last state is not a coherent vehicle model and must never feed control.
-- Derived values implement the approved conservative steering envelope:
--   delta0Safe=clamp(0.8*clamp0,0.35,0.75), Rmin=wheelbase/tan(delta0Safe);
--   lookScale and rearArm scale with sqrt(wheelbase/1.35), arm capped at +35%;
--   footprint/probe values derive from full extents. No script-name behavior branches.

MDADVehicleProfile = MDADVehicleProfile or {}
if MDADVehicleProfile.build then return end


local BODY_W_LO, BODY_W_HI = 0.6, 3.5
local BODY_L_LO, BODY_L_HI = 1.5, 12
local MASS_LO, MASS_HI = 200, 5000
local WB_LO, WB_HI, WB_FALLBACK_HI = 0.8, 7, 6
local TRACK_LO, TRACK_HI = 0, 4
local FRIC_LO, FRIC_HI = 0, 2000
local CLAMP_LO, CLAMP_RAW_HI, CLAMP_ACCEPT_HI = 0.1, 0.9, 0.900001
local MAX_SPEED_HI = 1000

local SAFE_W, SAFE_L, SAFE_MASS, SAFE_MAX_SPEED = 1.8, 4.4, 1200, 70
local SAFE_TRACK, SAFE_FRIC = 1.4, 1.5
local SAFE_C0, SAFE_C30, SAFE_CMAX = 0.9, 0.68571428571429, 0.4
local WB_BODY, WB_REF = 0.65, 1.35
local STEER_MARGIN = 0.8
local SAFE_D0_LO, SAFE_D0_HI, SAFE_DV_LO = 0.35, 0.75, 0.1
local LOOK_LO, LOOK_HI = 0.85, 1.5
local ARM_REF, ARM_SCALE_LO, ARM_SCALE_HI = 2.2, 0.85, 1.35
local NEED_BASE, NEED_MARGIN = 1.4, 0.4
local PROBE_EXTRA, PROBE_LO, PROBE_HI = 1, 3, 7

local function isFinite(n)
    return type(n) == "number" and n * 0 == 0
end

local function clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

local function inOpenHi(n, lo, hi)
    return isFinite(n) and n > lo and n <= hi
end

local function inClosed(n, lo, hi)
    return isFinite(n) and n >= lo and n <= hi
end

local function call(obj, name, a)
    if obj == nil then return nil end
    local fn = obj[name]
    if type(fn) ~= "function" then return nil end
    local ok, r
    if a ~= nil then
        ok, r = pcall(fn, obj, a)
    else
        ok, r = pcall(fn, obj)
    end
    if not ok then return nil end
    return r
end

local function axis(v, name)
    local n = call(v, name)
    if not isFinite(n) then return nil end
    return n
end

local function wheelXZ(script, id)
    local wheel = call(script, "getWheelById", id)
    if wheel == nil then return nil, nil end
    local off = call(wheel, "getOffset")
    return axis(off, "x"), axis(off, "z")
end

local function derive(bodyW, bodyL, wheelbase, clamp0, clampMax)
    local halfW = bodyW * 0.5
    local halfL = bodyL * 0.5
    local delta0Safe = clamp(STEER_MARGIN * clamp0, SAFE_D0_LO, SAFE_D0_HI)
    local deltaVSafe = clamp(STEER_MARGIN * clampMax, SAFE_DV_LO, delta0Safe)
    local rMin = wheelbase / math.tan(delta0Safe)
    local scale = math.sqrt(wheelbase / WB_REF)
    local lookScale = clamp(scale, LOOK_LO, LOOK_HI)
    local rearArm = ARM_REF * clamp(scale, ARM_SCALE_LO, ARM_SCALE_HI)
    local needHalf = halfW + NEED_MARGIN
    if needHalf < NEED_BASE then needHalf = NEED_BASE end
    local probeR = clamp(0.5 * math.sqrt(bodyW * bodyW + bodyL * bodyL)
        + PROBE_EXTRA, PROBE_LO, PROBE_HI)
    return halfW, halfL, delta0Safe, deltaVSafe, rMin, lookScale,
        rearArm, needHalf, probeR
end

local function pack(valid, fallback, scriptName, bodyW, bodyL, mass, maxSpeed,
        wheelbase, track, clamp0, clamp30, clampMax, wheelFriction)
    local halfW, halfL, delta0Safe, deltaVSafe, rMin, lookScale,
        rearArm, needHalf, probeR =
        derive(bodyW, bodyL, wheelbase, clamp0, clampMax)
    return {
        valid = valid == true,
        fallback = fallback == true,
        scriptName = scriptName,
        bodyW = bodyW,
        bodyL = bodyL,
        halfW = halfW,
        halfL = halfL,
        mass = mass,
        maxSpeed = maxSpeed,
        wheelbase = wheelbase,
        track = track,
        clamp0 = clamp0,
        clamp30 = clamp30,
        clampMax = clampMax,
        wheelFriction = wheelFriction,
        delta0Safe = delta0Safe,
        deltaVSafe = deltaVSafe,
        rMin = rMin,
        lookScale = lookScale,
        rearArm = rearArm,
        needHalf = needHalf,
        probeR = probeR,
    }
end

local function safePack(scriptName)
    local wb = clamp(WB_BODY * SAFE_L, WB_LO, WB_FALLBACK_HI)
    return pack(false, true, scriptName or "", SAFE_W, SAFE_L, SAFE_MASS,
        SAFE_MAX_SPEED, wb, SAFE_TRACK, SAFE_C0, SAFE_C30, SAFE_CMAX, SAFE_FRIC)
end

function MDADVehicleProfile.build(vehicle)
    local ok, profile = pcall(function()
        if vehicle == nil then return safePack("") end
        local script = call(vehicle, "getScript")
        if script == nil then return safePack("") end

        local scriptName = call(script, "getFullName")
        if type(scriptName) ~= "string" or scriptName == "" then
            scriptName = call(script, "getName")
        end
        if type(scriptName) ~= "string" then
            scriptName = call(vehicle, "getScriptName")
        end
        if type(scriptName) ~= "string" then scriptName = "" end

        local valid = true
        local fallback = false

        local ext = call(script, "getExtents")
        local bodyW = axis(ext, "x")
        local bodyL = axis(ext, "z")
        if not inClosed(bodyW, BODY_W_LO, BODY_W_HI) then
            bodyW = SAFE_W
            valid = false
            fallback = true
        end
        if not inClosed(bodyL, BODY_L_LO, BODY_L_HI) then
            bodyL = SAFE_L
            valid = false
            fallback = true
        end

        local mass = call(vehicle, "getMass")
        if not inClosed(mass, MASS_LO, MASS_HI) then
            mass = SAFE_MASS
            valid = false
            fallback = true
        end

        local flx, flz = wheelXZ(script, "FrontLeft")
        local frx, frz = wheelXZ(script, "FrontRight")
        local rlx, rlz = wheelXZ(script, "RearLeft")
        local rrx, rrz = wheelXZ(script, "RearRight")

        local wbLeft, wbRight = nil, nil
        local wbInvalid = false
        if isFinite(flz) and isFinite(rlz) then
            local d = flz - rlz
            if d < 0 then d = -d end
            if inClosed(d, WB_LO, WB_HI) then wbLeft = d else wbInvalid = true end
        end
        if isFinite(frz) and isFinite(rrz) then
            local d = frz - rrz
            if d < 0 then d = -d end
            if inClosed(d, WB_LO, WB_HI) then wbRight = d else wbInvalid = true end
        end
        local wheelbase
        if wbInvalid then
            wheelbase = clamp(WB_BODY * bodyL, WB_LO, WB_FALLBACK_HI)
            valid = false
            fallback = true
        elseif wbLeft and wbRight then
            wheelbase = (wbLeft + wbRight) * 0.5
        elseif wbLeft or wbRight then
            wheelbase = wbLeft or wbRight
            fallback = true
        else
            wheelbase = clamp(WB_BODY * bodyL, WB_LO, WB_FALLBACK_HI)
            fallback = true
        end

        local trackFront, trackRear = nil, nil
        local trackInvalid = false
        if isFinite(flx) and isFinite(frx) then
            local d = flx - frx
            if d < 0 then d = -d end
            if inClosed(d, TRACK_LO, TRACK_HI) then
                trackFront = d
            else
                trackInvalid = true
            end
        end
        if isFinite(rlx) and isFinite(rrx) then
            local d = rlx - rrx
            if d < 0 then d = -d end
            if inClosed(d, TRACK_LO, TRACK_HI) then
                trackRear = d
            else
                trackInvalid = true
            end
        end
        local track
        if trackInvalid then
            track = SAFE_TRACK
            valid = false
            fallback = true
        elseif trackFront and trackRear then
            track = (trackFront + trackRear) * 0.5
        elseif trackFront or trackRear then
            track = trackFront or trackRear
            fallback = true
        else
            track = 0
            fallback = true
        end

        local maxSpeed = call(vehicle, "getMaxSpeed")
        if not inOpenHi(maxSpeed, 0, MAX_SPEED_HI) then
            maxSpeed = SAFE_MAX_SPEED
            valid = false
            fallback = true
        end
        local clamp0 = call(script, "getSteeringClamp", 0)
        local clamp30 = call(script, "getSteeringClamp", 30)
        local clampMax = call(script, "getSteeringClamp", maxSpeed)
        local clampOrderOk = false
        if isFinite(clamp30) and isFinite(clampMax) then
            if maxSpeed >= 30 then
                clampOrderOk = clampMax <= clamp30
            else
                clampOrderOk = clamp30 <= clampMax
            end
        end
        if not inClosed(clamp0, CLAMP_LO, CLAMP_ACCEPT_HI)
                or not inClosed(clamp30, CLAMP_LO, CLAMP_ACCEPT_HI)
                or not inClosed(clampMax, CLAMP_LO, CLAMP_ACCEPT_HI)
                or clamp30 > clamp0 or clampMax > clamp0 or not clampOrderOk then
            clamp0, clamp30, clampMax = SAFE_C0, SAFE_C30, SAFE_CMAX
            valid = false
            fallback = true
        else
            clamp0 = clamp(clamp0, CLAMP_LO, CLAMP_RAW_HI)
            clamp30 = clamp(clamp30, CLAMP_LO, CLAMP_RAW_HI)
            clampMax = clamp(clampMax, CLAMP_LO, CLAMP_RAW_HI)
        end

        local wheelFriction = call(script, "getWheelFriction")
        if not inOpenHi(wheelFriction, FRIC_LO, FRIC_HI) then
            wheelFriction = SAFE_FRIC
            valid = false
            fallback = true
        end

        return pack(valid, fallback, scriptName, bodyW, bodyL, mass, maxSpeed,
            wheelbase, track, clamp0, clamp30, clampMax, wheelFriction)
    end)
    if ok and type(profile) == "table" then return profile end
    return safePack("")
end
