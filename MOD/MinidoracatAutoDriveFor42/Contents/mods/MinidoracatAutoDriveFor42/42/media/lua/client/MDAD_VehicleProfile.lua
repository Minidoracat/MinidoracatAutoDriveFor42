-- MDAD_VehicleProfile.lua -- one cached vehicle profile per AutoDrive session.
-- Built only on the session-start cold path and shared by control + diagnostics;
-- no profile getter is re-read per frame.
--
-- MDADVehicleProfile.build(vehicle) -> table of scalars:
--   valid, fallback, geometryValid, scriptName, bodyW, bodyL, halfW, halfL,
--   centerOfMassX/Y/Z, mass, maxSpeed, wheelbase, track, clamp0, clamp30,
--   clampMax, wheelFriction, delta0Safe, deltaVSafe, rMin, lookScale, rearArm,
--   needHalf, probeR, enginePower, brakingForce, offroadEfficiency, rollInfluence,
--   tireFrictionMin, tireFrictionAvg, tireFrictionCount, isAnyTireMissing
-- Pure scalar/cold-path helpers:
--   steeringKappa(profile,speedKmh) -> kappa
--   priors(profile,runtimeMass,surfaceId,raining,physicalOffroad,adaptive)
--     -> aDrive,aBrake,aLat,fSurface,fTire,aCoast
--   updateEWMA(mean,dev,seconds,observation,dt) -> mean,dev,seconds,confidence,lower
--   configureFollower(followerProfile,vehicleProfile,runtimeMass,raining) -> adaptive
-- Units: body/axle/radius/arm/centerOfMass are metres; mass is kg; maxSpeed is km/h;
-- enginePower is the runtime engineForce integer (BaseVehicle.java:8077-8078);
-- brakingForce is the accumulated part brake force (BaseVehicle.java:9005-9006);
-- steering clamps are radians; lookScale, wheelFriction, offroadEfficiency,
-- rollInfluence and runtime tire friction are unitless.
--
-- Source: BaseVehicle runtime mass/maxSpeed/enginePower/brakingForce/isAnyTireMissing
-- plus VehicleScript getters once. No Java instance fields (Kahlua does not expose
-- them; LuaJavaClassExposer.java:292-324).
-- Extents via getExtents():x()/:z() (ISVehicleSeatUI.lua:206-207). Wheels via
-- getWheelById("FrontLeft"|"FrontRight"|"RearLeft"|"RearRight") then
-- getOffset():x()/:z() (VehicleScript.java:1729-1737,2705-2707).
-- Steering clamps via getSteeringClamp(speed) (VehicleScript.java:1678-1686).
-- Runtime tire friction: script getWheel(i):getId() → vehicle:getPartById("Tire"..id)
-- → part:getWheelFriction (VehicleScript.java:1721-1723,2701-2702;
-- VehiclePartOwner.java:44-45; VehiclePart.java:915-916).
-- Script physics: getOffroadEfficiency / getRollInfluence / getCenterOfMassOffset():x()/:y()/:z()
-- (VehicleScript.java:2002-2003,1670-1671,1650-1651,2701-2707).
--
-- Finite domains (unsupported legacy geometry -> valid=false, safe fallback, never throw):
--   bodyW [0.6, 3.5], bodyL [1.5, 12], runtime mass [200, 5000],
--   runtime maxSpeed (0, 1000], wheelbase [0.8, 7], track [0, 4],
--   wheelFriction (0, 2000] and all sampled clamps [0.1, 0.9], monotonic by sample speed.
-- geometryValid depends only on extents and finite in-body COM x/z. Invalid COM x/z
-- safely falls back to 0; mass, tires, steering and additive telemetry never poison it.
-- Additive physics fields never affect valid/fallback/geometryValid. Missing APIs,
-- throws and out-of-domain values stay nil so the telemetry encoder omits unknown:
--   enginePower [0, 50000], brakingForce [0, 5000], offroadEfficiency (0, 10],
--   rollInfluence [0, 2], centerOfMassY [-2, 3], runtime tire friction (0, 5],
--   tireFrictionCount [0, 16].
-- Missing wheels: wheelbase = clamp(0.65 * bodyL, 0.8, 6).
-- State meanings: (valid,!fallback)=all sources measured; (valid,fallback)=
-- in-domain wheel estimate; (!valid,fallback)=patchwork safe substitutions.
-- The last state is not a coherent vehicle model and must never feed control.
-- Derived values implement the approved conservative steering envelope:
--   delta0Safe=clamp(0.8*clamp0,0.35,0.75), Rmin=wheelbase/tan(delta0Safe);
--   lookScale and rearArm scale with sqrt(wheelbase/1.35), arm capped at +35%;
--   footprint/probe values derive from full extents. No script-name behavior branches.

MDADVehicleProfile = MDADVehicleProfile or {}
MDADVehicleProfile.SURFACE_UNKNOWN = 0
MDADVehicleProfile.SURFACE_PAVED = 1
MDADVehicleProfile.SURFACE_GRAVEL = 2
MDADVehicleProfile.SURFACE_DIRT = 3
if MDADVehicleProfile.build then return end


local BODY_W_LO, BODY_W_HI = 0.6, 3.5
local BODY_L_LO, BODY_L_HI = 1.5, 12
local MASS_LO, MASS_HI = 200, 5000
local WB_LO, WB_HI, WB_FALLBACK_HI = 0.8, 7, 6
local TRACK_LO, TRACK_HI = 0, 4
local FRIC_LO, FRIC_HI = 0, 2000
local TIRE_FRIC_LO, TIRE_FRIC_HI = 0, 5
local CLAMP_LO, CLAMP_RAW_HI, CLAMP_ACCEPT_HI = 0.1, 0.9, 0.900001
local MAX_SPEED_HI = 1000
local ENG_LO, ENG_HI = 0, 50000
local BRAKE_LO, BRAKE_HI = 0, 5000
local OFFROAD_EFF_LO, OFFROAD_EFF_HI = 0, 10
local ROLL_LO, ROLL_HI = 0, 2
local COMY_LO, COMY_HI = -2, 3
local TIRE_N_HI = 16

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

-- Reference force/mass densities of the calibration sedan (4000 N engine force,
-- 80 N brake force at 1200 kg) that the legacy 2.5/6 m/s^2 envelopes were tuned
-- on. A density ratio below 1 means "weaker than reference", so it only lowers.
local ENG_REF_DENSITY, BRAKE_REF_DENSITY = 4000 / 1200, 80 / 1200
local TIRE_SCALE_LO = 0.35     -- worst tire-grip fraction; also the missing-tire floor

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

local function index(obj, name)
    return obj[name]
end

-- Lookup itself is pcall'd: strict mocks / missing Java methods must not
-- abort the whole build. tryCall preserves whether a nil result was returned
-- successfully, which is required to distinguish a missing tire from a failed read.
local function tryCall(obj, name, a)
    if obj == nil then return false, nil end
    local ok, fn = pcall(index, obj, name)
    if not ok or type(fn) ~= "function" then return false, nil end
    local okCall, r
    if a ~= nil then
        okCall, r = pcall(fn, obj, a)
    else
        okCall, r = pcall(fn, obj)
    end
    if not okCall then return false, nil end
    return true, r
end

local function call(obj, name, a)
    local ok, r = tryCall(obj, name, a)
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

local function pack(valid, fallback, geometryValid, scriptName, bodyW, bodyL,
        centerOfMassX, centerOfMassY, centerOfMassZ, mass, maxSpeed,
        wheelbase, track, clamp0, clamp30, clampMax, wheelFriction,
        enginePower, brakingForce, offroadEfficiency, rollInfluence,
        tireFrictionMin, tireFrictionAvg, tireFrictionCount, isAnyTireMissing)
    local halfW, halfL, delta0Safe, deltaVSafe, rMin, lookScale,
        rearArm, needHalf, probeR =
        derive(bodyW, bodyL, wheelbase, clamp0, clampMax)
    return {
        valid = valid == true,
        fallback = fallback == true,
        geometryValid = geometryValid == true,
        scriptName = scriptName,
        bodyW = bodyW,
        bodyL = bodyL,
        halfW = halfW,
        halfL = halfL,
        centerOfMassX = centerOfMassX,
        centerOfMassY = centerOfMassY,
        centerOfMassZ = centerOfMassZ,
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
        enginePower = enginePower,
        brakingForce = brakingForce,
        offroadEfficiency = offroadEfficiency,
        rollInfluence = rollInfluence,
        tireFrictionMin = tireFrictionMin,
        tireFrictionAvg = tireFrictionAvg,
        tireFrictionCount = tireFrictionCount,
        isAnyTireMissing = isAnyTireMissing,
    }
end

local function safePack(scriptName)
    local wb = clamp(WB_BODY * SAFE_L, WB_LO, WB_FALLBACK_HI)
    return pack(false, true, false, scriptName or "", SAFE_W, SAFE_L, 0, nil, 0,
        SAFE_MASS, SAFE_MAX_SPEED, wb, SAFE_TRACK, SAFE_C0, SAFE_C30, SAFE_CMAX,
        SAFE_FRIC, nil, nil, nil, nil, nil, nil, nil, nil)
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
        local geometryValid = true

        local ext = call(script, "getExtents")
        local bodyW = axis(ext, "x")
        local bodyL = axis(ext, "z")
        if not inClosed(bodyW, BODY_W_LO, BODY_W_HI) then
            bodyW = SAFE_W
            valid = false
            fallback = true
            geometryValid = false
        end
        if not inClosed(bodyL, BODY_L_LO, BODY_L_HI) then
            bodyL = SAFE_L
            valid = false
            fallback = true
            geometryValid = false
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

        -- COM x/z defines the OBB centre used by VehiclePoly. It is control geometry,
        -- not optional telemetry: missing/out-of-body values fall back to origin and
        -- make geometryValid=false without coupling mass/tire/steering validity.
        local com = call(script, "getCenterOfMassOffset")
        local centerOfMassX = axis(com, "x")
        local centerOfMassZ = axis(com, "z")
        local comHalfW, comHalfL = bodyW * 0.5, bodyL * 0.5
        if not inClosed(centerOfMassX, -comHalfW, comHalfW) then
            centerOfMassX = 0
            geometryValid = false
        end
        if not inClosed(centerOfMassZ, -comHalfL, comHalfL) then
            centerOfMassZ = 0
            geometryValid = false
        end

        -- Additive physics: unknown/illegal readings stay nil and never affect geometry.
        local enginePower = call(vehicle, "getEnginePower")
        if not inClosed(enginePower, ENG_LO, ENG_HI) then enginePower = nil end
        local brakingForce = call(vehicle, "getBrakingForce")
        if not inClosed(brakingForce, BRAKE_LO, BRAKE_HI) then brakingForce = nil end
        local offroadEfficiency = call(script, "getOffroadEfficiency")
        if not inOpenHi(offroadEfficiency, OFFROAD_EFF_LO, OFFROAD_EFF_HI) then
            offroadEfficiency = nil
        end
        local rollInfluence = call(script, "getRollInfluence")
        if not inClosed(rollInfluence, ROLL_LO, ROLL_HI) then rollInfluence = nil end
        local centerOfMassY = axis(com, "y")
        if not inClosed(centerOfMassY, COMY_LO, COMY_HI) then centerOfMassY = nil end

        local tireMin, tireSum, tireN = nil, 0, 0
        local sawMissingTire = false
        local countOk, nWheels = tryCall(script, "getWheelCount")
        local wheelComplete = countOk and isFinite(nWheels)
            and nWheels >= 0 and nWheels <= TIRE_N_HI and nWheels % 1 == 0
        local frictionComplete = wheelComplete
        if wheelComplete then
            local i = 0
            while i < nWheels do
                local wheelOk, w = tryCall(script, "getWheel", i)
                if not wheelOk or w == nil then
                    wheelComplete = false
                    frictionComplete = false
                else
                    local idOk, id = tryCall(w, "getId")
                    if not idOk or type(id) ~= "string" or id == "" then
                        wheelComplete = false
                        frictionComplete = false
                    else
                        local partOk, part = tryCall(vehicle, "getPartById", "Tire" .. id)
                        if not partOk then
                            wheelComplete = false
                            frictionComplete = false
                        elseif part == nil then
                            sawMissingTire = true
                        else
                            local itemOk, item = tryCall(part, "getInventoryItem")
                            if not itemOk then
                                wheelComplete = false
                                frictionComplete = false
                            elseif item == nil then
                                sawMissingTire = true
                            else
                                local frictionOk, fr = tryCall(part, "getWheelFriction")
                                if frictionOk and inOpenHi(fr, TIRE_FRIC_LO, TIRE_FRIC_HI) then
                                    if tireMin == nil or fr < tireMin then tireMin = fr end
                                    tireSum = tireSum + fr
                                    tireN = tireN + 1
                                else
                                    frictionComplete = false
                                end
                            end
                        end
                    end
                end
                i = i + 1
            end
        end
        local tireFrictionMin, tireFrictionAvg, tireFrictionCount
        if frictionComplete then
            tireFrictionCount = tireN
            if tireN > 0 then
                tireFrictionMin = tireMin
                tireFrictionAvg = tireSum / tireN
            end
        end
        local missingOk, isAnyTireMissing = tryCall(vehicle, "isAnyTireMissing")
        if not missingOk or type(isAnyTireMissing) ~= "boolean" then
            if wheelComplete then isAnyTireMissing = sawMissingTire
            else isAnyTireMissing = nil end
        end

        return pack(valid, fallback, geometryValid, scriptName, bodyW, bodyL,
            centerOfMassX, centerOfMassY, centerOfMassZ, mass, maxSpeed,
            wheelbase, track, clamp0, clamp30, clampMax, wheelFriction,
            enginePower, brakingForce, offroadEfficiency, rollInfluence,
            tireFrictionMin, tireFrictionAvg, tireFrictionCount, isAnyTireMissing)
    end)
    if ok and type(profile) == "table" then return profile end
    return safePack("")
end

-- VehicleScript.getSteeringClamp(speed) linearly interpolates clamp0 to clampMax
-- over vehicle max speed (VehicleScript.java:1678-1687). This pure scalar is the
-- conservative bicycle-model envelope; it never reads Java or allocates.
function MDADVehicleProfile.steeringKappa(profile, speedKmh)
    if type(profile) ~= "table" or not isFinite(speedKmh)
            or not inOpenHi(profile.maxSpeed, 0, MAX_SPEED_HI)
            or not inClosed(profile.delta0Safe, SAFE_DV_LO, SAFE_D0_HI)
            or not inClosed(profile.deltaVSafe, SAFE_DV_LO, profile.delta0Safe)
            or not inClosed(profile.wheelbase, WB_LO, WB_HI) then
        return 0
    end
    local av = speedKmh
    if av < 0 then av = -av end
    local t = av / profile.maxSpeed
    if t > 1 then t = 1 end
    local delta = profile.delta0Safe
        + (profile.deltaVSafe - profile.delta0Safe) * t
    return math.tan(delta) / profile.wheelbase
end

-- sqrt of a getter-derived force/mass density normalised against the reference
-- sedan. Never negative; the caller uses it only to lower a legacy envelope.
local function densityScale(force, mass, refDensity)
    local rho = (force / mass) / refDensity
    if rho < 0 then rho = 0 end
    return math.sqrt(rho)
end

-- Conservative priors only lower the legacy ACCEL/BRAKE/LAT envelopes.
-- BaseVehicle.isDoingOffroad and the rain/tire multipliers are sourced from
-- BaseVehicle.java:9029-9042,9165-9190,9231-9241. Getter values remain priors:
-- CarController applies RPM/gear/speed/offroad factors after enginePower.
-- Returns aDrive, aBrake, aLat, fSurface, fTire as scalars.
function MDADVehicleProfile.priors(profile, runtimeMass, surfaceId, raining,
        physicalOffroad, adaptive)
    if type(profile) ~= "table" then profile = {} end
    local mass = runtimeMass
    if not inClosed(mass, MASS_LO, MASS_HI) then mass = profile.mass end
    if not inClosed(mass, MASS_LO, MASS_HI) then mass = SAFE_MASS end
    adaptive = adaptive == true and profile.valid == true
        and profile.geometryValid == true

    local fSurface = surfaceId == MDADVehicleProfile.SURFACE_PAVED and 1 or 0.7
    -- Unknown weather is wet until a sensor snapshot proves dry.
    if raining ~= false then fSurface = fSurface - 0.3 end
    if fSurface < 0.4 then fSurface = 0.4 end

    local fTire = 0.8
    if adaptive and inOpenHi(profile.tireFrictionMin, TIRE_FRIC_LO, TIRE_FRIC_HI)
            and inOpenHi(profile.wheelFriction, FRIC_LO, FRIC_HI) then
        fTire = clamp(profile.tireFrictionMin / profile.wheelFriction,
            TIRE_SCALE_LO, 1)
    end
    if profile.isAnyTireMissing == true and fTire > TIRE_SCALE_LO then
        fTire = TIRE_SCALE_LO -- a missing tire always takes the worst grip
    end

    local aDrive = 2.5
    if adaptive and inClosed(profile.enginePower, ENG_LO, ENG_HI) then
        local rho = densityScale(profile.enginePower, mass, ENG_REF_DENSITY)
        if rho < 1 then aDrive = aDrive * rho end
    end
    if physicalOffroad == true then
        local off = 0.6
        if adaptive and inOpenHi(profile.offroadEfficiency,
                OFFROAD_EFF_LO, OFFROAD_EFF_HI) then
            off = 0.6 * profile.offroadEfficiency
            if off > 1 then off = 1 end
        end
        aDrive = aDrive * off
    end

    local brakeScale = 1
    if adaptive and inClosed(profile.brakingForce, BRAKE_LO, BRAKE_HI) then
        local rho = densityScale(profile.brakingForce, mass, BRAKE_REF_DENSITY)
        if rho < brakeScale then brakeScale = rho end
    end
    return aDrive, 6 * fSurface * fTire * brakeScale,
        3.5 * fSurface * fTire, fSurface, fTire, 0.6
end

-- Exact approved EWMA scalar update. The caller owns traction-key resets and
-- decides which stable samples are valid; this helper has no hidden state.
function MDADVehicleProfile.updateEWMA(mean, dev, validSeconds, observation, dt)
    if not isFinite(mean) then mean = 0 end
    if not isFinite(dev) or dev < 0 then dev = 0 end
    if not isFinite(validSeconds) or validSeconds < 0 then validSeconds = 0 end
    if not isFinite(observation) or observation < 0
            or not isFinite(dt) or dt <= 0 then
        local confidence = validSeconds / 20
        if confidence > 1 then confidence = 1 end
        local lower = mean - 2 * dev
        if lower < 0 then lower = 0 end
        return mean, dev, validSeconds, confidence, lower
    end
    local alpha = dt / (10 + dt)
    mean = mean + alpha * (observation - mean)
    local delta = observation - mean
    if delta < 0 then delta = -delta end
    dev = dev + alpha * (delta - dev)
    validSeconds = validSeconds + dt
    local confidence = validSeconds / 20
    if confidence > 1 then confidence = 1 end
    local lower = mean - 2 * dev
    if lower < 0 then lower = 0 end
    return mean, dev, validSeconds, confidence, lower
end

-- Cold-path wiring: fill the Follower's preallocated per-segment dynamics arrays
-- from one coherent session profile. No table is created here.
function MDADVehicleProfile.configureFollower(follower, profile, runtimeMass, raining)
    if type(follower) ~= "table" or type(profile) ~= "table"
            or type(follower.segSurface) ~= "table"
            or type(follower.segAccel) ~= "table"
            or type(follower.segBrake) ~= "table"
            or type(follower.segCoast) ~= "table"
            or type(follower.segLat) ~= "table"
            or type(follower.n) ~= "number" then
        return false
    end
    local adaptive = profile.valid == true and profile.geometryValid == true
    follower.adaptive = adaptive
    follower.lookScale = adaptive and profile.lookScale or 1
    local have0, have1, have2, have3 = false, false, false, false
    local a0, b0, l0, c0, a1, b1, l1, c1, a2, b2, l2, c2, a3, b3, l3, c3
    local i = 1
    while i < follower.n do
        local sid = follower.segSurface[i]
        local aDrive, aBrake, aLat, aCoast
        if sid == MDADVehicleProfile.SURFACE_PAVED then
            if not have1 then
                a1, b1, l1, _, _, c1 = MDADVehicleProfile.priors(
                    profile, runtimeMass, sid, raining, false, adaptive)
                have1 = true
            end
            aDrive, aBrake, aLat, aCoast = a1, b1, l1, c1
        elseif sid == MDADVehicleProfile.SURFACE_GRAVEL then
            if not have2 then
                a2, b2, l2, _, _, c2 = MDADVehicleProfile.priors(
                    profile, runtimeMass, sid, raining, false, adaptive)
                have2 = true
            end
            aDrive, aBrake, aLat, aCoast = a2, b2, l2, c2
        elseif sid == MDADVehicleProfile.SURFACE_DIRT then
            if not have3 then
                a3, b3, l3, _, _, c3 = MDADVehicleProfile.priors(
                    profile, runtimeMass, sid, raining, false, adaptive)
                have3 = true
            end
            aDrive, aBrake, aLat, aCoast = a3, b3, l3, c3
        else
            if not have0 then
                a0, b0, l0, _, _, c0 = MDADVehicleProfile.priors(
                    profile, runtimeMass, MDADVehicleProfile.SURFACE_UNKNOWN,
                    raining, false, adaptive)
                have0 = true
            end
            aDrive, aBrake, aLat, aCoast = a0, b0, l0, c0
        end
        follower.segAccel[i], follower.segBrake[i], follower.segLat[i],
            follower.segCoast[i] = aDrive, aBrake, aLat, aCoast
        i = i + 1
    end
    return adaptive
end
