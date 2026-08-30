--[[
MDADVehicleProfile.build 離線測試：載入真正的 client/MDAD_VehicleProfile.lua，
對假 VehicleScript API 斷言契約。不重作 production 的衍生決策；夾限公式
照抄 VehicleScript.java:1678-1686，wheelbase fallback 照抄契約 0.65*bodyL。

    lua scripts/test_vehicle_profile.lua
]]

local MEDIA = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua"
local ROOTS = { "", "../" }

local function loadProduction(rel)
    for _, root in ipairs(ROOTS) do
        local path = root .. MEDIA .. "/" .. rel
        local fh = io.open(path, "r")
        if fh then
            fh:close()
            local chunk, err = loadfile(path)
            if not chunk then error("load failed: " .. tostring(err)) end
            chunk()
            return path
        end
    end
    error("missing " .. rel)
end

loadProduction("client/MDAD_VehicleProfile.lua")

local P = MDADVehicleProfile

local failures, assertions, scenarios = 0, 0, 0
local scenarioBase, scenarioTitle = 0, nil

local function show(v)
    if type(v) == "string" then return '"' .. v .. '"' end
    return tostring(v)
end

local function check(ok, label)
    assertions = assertions + 1
    if not ok then
        failures = failures + 1
        print("  FAIL " .. label)
    end
    return ok
end

local function checkTrue(v, label)
    return check(v == true, label .. " (got " .. show(v) .. ")")
end

local function checkFalse(v, label)
    return check(v == false, label .. " (got " .. show(v) .. ")")
end

local function checkEq(actual, expected, label)
    return check(actual == expected,
        label .. " (expected " .. show(expected) .. ", got " .. show(actual) .. ")")
end

local function checkNear(actual, expected, eps, label)
    local ok = type(actual) == "number" and actual == actual
        and math.abs(actual - expected) <= eps
    return check(ok, label .. " (expected ~" .. show(expected) .. ", got " .. show(actual) .. ")")
end

local function closeScenario()
    if not scenarioTitle then return end
    local n = assertions - scenarioBase
    print("  " .. n .. " asserts")
end

local function scenario(title)
    closeScenario()
    scenarios = scenarios + 1
    scenarioBase = assertions
    scenarioTitle = title
    print("case " .. scenarios .. ": " .. title)
end

local KEYS = {
    "valid", "fallback", "scriptName", "bodyW", "bodyL", "halfW", "halfL",
    "mass", "maxSpeed", "wheelbase", "track", "clamp0", "clamp30", "clampMax",
    "wheelFriction", "delta0Safe", "deltaVSafe", "rMin", "lookScale",
    "rearArm", "needHalf", "probeR",
}

local function checkKeys(p, label)
    for i = 1, #KEYS do
        local k = KEYS[i]
        check(p[k] ~= nil, label .. " has " .. k)
        if k ~= "valid" and k ~= "fallback" and k ~= "scriptName" then
            check(type(p[k]) == "number" and p[k] * 0 == 0,
                label .. " " .. k .. " finite scalar")
        end
    end
    check(type(p.valid) == "boolean", label .. " valid boolean")
    check(type(p.fallback) == "boolean", label .. " fallback boolean")
    check(type(p.scriptName) == "string", label .. " scriptName string")
end

-- VehicleScript.java:1678-1686
local function javaClamp(speed, steeringClamp, maxSpeed)
    if speed < 0 then speed = -speed end
    local delta = speed / maxSpeed
    if delta > 1 then delta = 1 end
    delta = 1 - delta
    return (0.9 - steeringClamp) * delta + steeringClamp
end

local function clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

local function vec(x, y, z, counts)
    local o = {}
    function o:x()
        if counts then counts.x = (counts.x or 0) + 1 end
        return x
    end
    function o:y()
        if counts then counts.y = (counts.y or 0) + 1 end
        return y
    end
    function o:z()
        if counts then counts.z = (counts.z or 0) + 1 end
        return z
    end
    return setmetatable(o, {
        __index = function(_, k) error("field access: " .. tostring(k)) end,
        __newindex = function(_, k) error("field write: " .. tostring(k)) end,
    })
end

local function wheel(x, z, counts)
    local o = {}
    function o:getOffset()
        if counts then counts.offset = (counts.offset or 0) + 1 end
        return vec(x, 0, z, counts)
    end
    return setmetatable(o, {
        __index = function(_, k) error("field access: " .. tostring(k)) end,
        __newindex = function(_, k) error("field write: " .. tostring(k)) end,
    })
end

local function makeVehicle(opts)
    opts = opts or {}
    local counts = opts.counts or {}
    local wheels = opts.wheels or {}
    local script = {}
    function script:getFullName()
        counts.fullName = (counts.fullName or 0) + 1
        return opts.fullName or opts.name or ""
    end
    function script:getName()
        counts.name = (counts.name or 0) + 1
        return opts.name or ""
    end
    function script:getExtents()
        counts.extents = (counts.extents or 0) + 1
        if opts.noExtents then return nil end
        return vec(opts.bodyW, opts.bodyH or 1, opts.bodyL, counts)
    end
    function script:getMass()
        counts.mass = (counts.mass or 0) + 1
        return opts.mass
    end
    function script:getWheelById(id)
        counts.wheel = (counts.wheel or 0) + 1
        local w = wheels[id]
        if w == false then return nil end
        if w then return wheel(w[1], w[2], counts) end
        return nil
    end
    function script:getSteeringClamp(speed)
        counts.clamp = (counts.clamp or 0) + 1
        if opts.clampFn then return opts.clampFn(speed) end
        return javaClamp(speed, opts.steeringClamp or 0.3,
            opts.scriptMaxSpeed or opts.maxSpeed or 70)
    end
    function script:getWheelFriction()
        counts.friction = (counts.friction or 0) + 1
        return opts.friction
    end
    setmetatable(script, {
        __index = function(_, k) error("field access: " .. tostring(k)) end,
        __newindex = function(_, k) error("field write: " .. tostring(k)) end,
    })
    local vehicle = {}
    function vehicle:getScript()
        counts.script = (counts.script or 0) + 1
        if opts.noScript then return nil end
        return script
    end
    function vehicle:getScriptName()
        counts.scriptName = (counts.scriptName or 0) + 1
        return opts.fullName or opts.name or ""
    end
    function vehicle:getMass()
        counts.runtimeMass = (counts.runtimeMass or 0) + 1
        return opts.mass
    end
    function vehicle:getMaxSpeed()
        counts.maxSpeed = (counts.maxSpeed or 0) + 1
        return opts.maxSpeed or 70
    end
    setmetatable(vehicle, {
        __index = function(_, k) error("field access: " .. tostring(k)) end,
        __newindex = function(_, k) error("field write: " .. tostring(k)) end,
    })
    return vehicle, counts
end

local function quad(hx, fz, rz)
    return {
        FrontLeft = { hx, fz },
        FrontRight = { -hx, fz },
        RearLeft = { hx, rz },
        RearRight = { -hx, rz },
    }
end

-- Scaled extents/offsets as VehicleScript.Loaded() would return.
local PICKUP = {
    fullName = "Base.PickUpTruck",
    bodyW = 0.8681 * 1.82,
    bodyL = 2.1868 * 1.82,
    mass = 1030,
    friction = 1.5,
    steeringClamp = 0.3,
    maxSpeed = 70,
    wheels = quad(0.3462 * 1.82, 0.7582 * 1.82, -0.5879 * 1.82),
}
local F150 = {
    fullName = "Base.93fordF150",
    bodyW = 2.0 * 0.9,
    bodyL = 5.1778 * 0.9,
    mass = 670,
    friction = 1.7,
    steeringClamp = 0.3,
    maxSpeed = 80,
    wheels = quad(0.8333 * 0.9, 2.1667 * 0.9, -0.7667 * 0.9),
}
local F250 = {
    fullName = "Base.93fordF250",
    bodyW = 2.0 * 0.9,
    bodyL = 5.5556 * 0.9,
    mass = 700,
    friction = 1.7,
    steeringClamp = 0.3,
    maxSpeed = 80,
    wheels = quad(0.8333 * 0.9, 2.1667 * 0.9, -1.1667 * 0.9),
}
local F350 = {
    fullName = "Base.93fordF350",
    bodyW = 2.0 * 0.9,
    bodyL = 6.4444 * 0.9,
    mass = 880,
    friction = 1.7,
    steeringClamp = 0.3,
    maxSpeed = 85,
    wheels = quad(0.8333 * 0.9, 2.1667 * 0.9, -2.0444 * 0.9),
}

local function expectGeom(spec)
    local fl = spec.wheels.FrontLeft
    local fr = spec.wheels.FrontRight
    local rl = spec.wheels.RearLeft
    local rr = spec.wheels.RearRight
    local wb = ((fl[2] - rl[2] < 0 and rl[2] - fl[2] or fl[2] - rl[2])
        + (fr[2] - rr[2] < 0 and rr[2] - fr[2] or fr[2] - rr[2])) * 0.5
    local tr = ((fl[1] - fr[1] < 0 and fr[1] - fl[1] or fl[1] - fr[1])
        + (rl[1] - rr[1] < 0 and rr[1] - rl[1] or rl[1] - rr[1])) * 0.5
    return wb, tr
end

local function checkSpec(spec, label)
    local v = makeVehicle(spec)
    local p = P.build(v)
    checkKeys(p, label)
    checkTrue(p.valid, label .. " valid")
    checkFalse(p.fallback, label .. " no fallback")
    checkEq(p.scriptName, spec.fullName, label .. " scriptName")
    checkNear(p.bodyW, spec.bodyW, 1e-9, label .. " bodyW")
    checkNear(p.bodyL, spec.bodyL, 1e-9, label .. " bodyL")
    checkNear(p.halfW, spec.bodyW * 0.5, 1e-9, label .. " halfW")
    checkNear(p.halfL, spec.bodyL * 0.5, 1e-9, label .. " halfL")
    checkEq(p.mass, spec.mass, label .. " mass")
    checkEq(p.maxSpeed, spec.maxSpeed, label .. " maxSpeed")
    local wb, tr = expectGeom(spec)
    checkNear(p.wheelbase, wb, 1e-9, label .. " wheelbase")
    checkNear(p.track, tr, 1e-9, label .. " track")
    checkNear(p.clamp0, javaClamp(0, spec.steeringClamp, spec.maxSpeed), 1e-9,
        label .. " clamp0")
    checkNear(p.clamp30, javaClamp(30, spec.steeringClamp, spec.maxSpeed), 1e-9,
        label .. " clamp30")
    checkNear(p.clampMax, javaClamp(spec.maxSpeed, spec.steeringClamp, spec.maxSpeed), 1e-9,
        label .. " clampMax")
    checkEq(p.wheelFriction, spec.friction, label .. " wheelFriction")
    local delta0Safe = clamp(0.8 * p.clamp0, 0.35, 0.75)
    local deltaVSafe = clamp(0.8 * p.clampMax, 0.1, delta0Safe)
    checkNear(p.delta0Safe, delta0Safe, 1e-9, label .. " delta0Safe")
    checkNear(p.deltaVSafe, deltaVSafe, 1e-9, label .. " deltaVSafe")
    local needHalf = p.halfW + 0.4
    if needHalf < 1.4 then needHalf = 1.4 end
    checkNear(p.needHalf, needHalf, 1e-9, label .. " needHalf")
    local scale = math.sqrt(p.wheelbase / 1.35)
    local rear = 2.2 * clamp(scale, 0.85, 1.35)
    checkNear(p.rearArm, rear, 1e-9, label .. " rearArm")
    check(p.rearArm <= 2.2 * 1.35 + 1e-12, label .. " rearArm cap+35%")
    local probeR = clamp(0.5 * math.sqrt(p.bodyW * p.bodyW + p.bodyL * p.bodyL)
        + 1, 3, 7)
    checkNear(p.probeR, probeR, 1e-9, label .. " probeR")
    checkNear(p.rMin, p.wheelbase / math.tan(delta0Safe), 1e-9, label .. " rMin")
    checkNear(p.lookScale, clamp(scale, 0.85, 1.5), 1e-9, label .. " lookScale")
    return p
end

--------------------------------------------------------------------------------
scenario("vanilla pickup / F150 / F250 / F350 geometry and clamps")
do
    checkSpec(PICKUP, "pickup")
    checkSpec(F150, "F150")
    checkSpec(F250, "F250")
    checkSpec(F350, "F350")
end

--------------------------------------------------------------------------------
scenario("missing wheels: fallback wheelbase = clamp(0.65*bodyL, 0.8, 6)")
do
    local spec = {
        fullName = "Base.PickUpTruck",
        bodyW = PICKUP.bodyW,
        bodyL = PICKUP.bodyL,
        mass = 1030,
        friction = 1.5,
        steeringClamp = 0.3,
        maxSpeed = 70,
        wheels = {},
    }
    local p = P.build(makeVehicle(spec))
    checkKeys(p, "no wheels")
    checkTrue(p.fallback, "missing wheels sets fallback")
    checkTrue(p.valid, "body still valid")
    checkNear(p.wheelbase, clamp(0.65 * spec.bodyL, 0.8, 6), 1e-9,
        "fallback wheelbase")
    checkEq(p.track, 0, "missing track is 0")

    local tiny = {
        fullName = "Base.Tiny",
        bodyW = 1.0,
        bodyL = 1.5,
        mass = 200,
        friction = 1.5,
        steeringClamp = 0.3,
        maxSpeed = 70,
        wheels = {},
    }
    local pTiny = P.build(makeVehicle(tiny))
    checkNear(pTiny.wheelbase, 0.65 * 1.5, 1e-9, "fallback uses lower valid body")

    local huge = {
        fullName = "Base.Huge",
        bodyW = 3.0,
        bodyL = 12.0,
        mass = 4000,
        friction = 1.5,
        steeringClamp = 0.3,
        maxSpeed = 70,
        wheels = {},
    }
    local pHuge = P.build(makeVehicle(huge))
    checkNear(pHuge.wheelbase, 6, 1e-9, "fallback wheelbase cap 6")

    local oneSide = P.build(makeVehicle({
        fullName = "Base.OneSide", bodyW = 1.8, bodyL = 4.4, mass = 1200,
        friction = 1.5, steeringClamp = 0.3, maxSpeed = 70,
        wheels = {
            FrontRight = { -0.7, 1.5 },
            RearRight = { -0.7, -1.0 },
        },
    }))
    checkTrue(oneSide.valid, "one-sided in-domain geometry remains valid")
    checkTrue(oneSide.fallback, "one-sided geometry is explicitly estimated")
    checkNear(oneSide.wheelbase, 2.5, 1e-9, "one-sided wheelbase keeps measured side")

    local badWheelbase = P.build(makeVehicle({
        fullName = "Base.BadWheelbase", bodyW = 1.8, bodyL = 4.4, mass = 1200,
        friction = 1.5, steeringClamp = 0.3, maxSpeed = 70,
        wheels = {
            FrontLeft = { 0.7, 5 }, RearLeft = { 0.7, -5 },
            FrontRight = { -0.7, 1.5 }, RearRight = { -0.7, -1.0 },
        },
    }))
    checkFalse(badWheelbase.valid, "one OOB wheelbase side invalidates profile")
    checkTrue(badWheelbase.fallback, "OOB wheelbase uses fallback")
    checkNear(badWheelbase.wheelbase, 0.65 * 4.4, 1e-9,
        "OOB side cannot average back into valid range")

    local badTrack = P.build(makeVehicle({
        fullName = "Base.BadTrack", bodyW = 1.8, bodyL = 4.4, mass = 1200,
        friction = 1.5, steeringClamp = 0.3, maxSpeed = 70,
        wheels = {
            FrontLeft = { 3, 1.5 }, FrontRight = { -3, 1.5 },
            RearLeft = { 0.7, -1.0 }, RearRight = { -0.7, -1.0 },
        },
    }))
    checkFalse(badTrack.valid, "one OOB track axle invalidates profile")
    checkTrue(badTrack.fallback, "OOB track uses fallback")
    checkNear(badTrack.track, 1.4, 1e-9,
        "OOB axle cannot average back into valid range")
end

--------------------------------------------------------------------------------
scenario("invalid NaN / extreme: valid=false, safe fallback, never throw")
do
    local nan = 0 / 0
    local inf = 1 / 0
    local pNil = P.build(nil)
    checkKeys(pNil, "nil vehicle")
    checkFalse(pNil.valid, "nil vehicle invalid")
    checkTrue(pNil.fallback, "nil vehicle fallback")

    local pNoScript = P.build(makeVehicle({ noScript = true, bodyW = 1.8, bodyL = 4.4,
        mass = 1200, friction = 1.5 }))
    checkFalse(pNoScript.valid, "no script invalid")
    checkTrue(pNoScript.fallback, "no script fallback")

    local pNan = P.build(makeVehicle({
        fullName = "Base.NaN",
        bodyW = nan,
        bodyL = nan,
        mass = nan,
        friction = nan,
        steeringClamp = 0.3,
        maxSpeed = 70,
        wheels = quad(nan, nan, nan),
        clampFn = function() return nan end,
    }))
    checkKeys(pNan, "NaN")
    checkFalse(pNan.valid, "NaN invalid")
    checkTrue(pNan.fallback, "NaN fallback")
    checkNear(pNan.bodyW, 1.8, 1e-9, "NaN bodyW safe")
    checkNear(pNan.bodyL, 4.4, 1e-9, "NaN bodyL safe")

    local pExt = P.build(makeVehicle({
        fullName = "Base.Extreme",
        bodyW = 100,
        bodyL = 100,
        mass = 1e9,
        friction = 1e9,
        steeringClamp = 0.3,
        maxSpeed = 70,
        wheels = quad(50, 50, -50),
    }))
    checkFalse(pExt.valid, "extreme invalid")
    checkTrue(pExt.fallback, "extreme fallback")
    checkNear(pExt.bodyW, 1.8, 1e-9, "extreme bodyW safe")
    check(pExt.wheelbase >= 0.8 and pExt.wheelbase <= 6, "extreme wheelbase clamped")

    local pInf = P.build(makeVehicle({
        fullName = "Base.Inf",
        bodyW = inf,
        bodyL = -inf,
        mass = inf,
        friction = -1,
        steeringClamp = 0.3,
        maxSpeed = 70,
        wheels = quad(inf, inf, -inf),
        clampFn = function() return inf end,
    }))
    checkFalse(pInf.valid, "Inf invalid")
    checkTrue(pInf.fallback, "Inf fallback")
    local pOrder = P.build(makeVehicle({
        fullName = "Base.BadClampOrder",
        bodyW = 1.8,
        bodyL = 4.4,
        mass = 1200,
        friction = 1.5,
        maxSpeed = 70,
        wheels = quad(0.7, 1.4, -1.1),
        clampFn = function(speed) return speed == 0 and 0.3 or 0.8 end,
    }))
    checkFalse(pOrder.valid, "non-monotonic clamps invalid")
    checkTrue(pOrder.fallback, "non-monotonic clamps fallback")
    checkNear(pOrder.clamp0, 0.9, 1e-9, "non-monotonic clamps use safe envelope")

    local okCall, errCall = pcall(P.build, makeVehicle({
        fullName = "Base.Boom",
        bodyW = 1.8,
        bodyL = 4.4,
        mass = 1200,
        friction = 1.5,
        clampFn = function() error("boom") end,
        wheels = quad(0.6, 1.3, -1.0),
    }))
    checkTrue(okCall, "getter throw does not escape")
    if okCall then
        checkKeys(errCall, "thrown getter")
        checkFalse(errCall.valid, "thrown getter invalid")
    end
end

--------------------------------------------------------------------------------
scenario("no field access: getters only, each source getter once")
do
    local counts = {}
    local v = makeVehicle({
        counts = counts,
        fullName = "Base.PickUpTruck",
        bodyW = PICKUP.bodyW,
        bodyL = PICKUP.bodyL,
        mass = 1030,
        friction = 1.5,
        steeringClamp = 0.3,
        maxSpeed = 70,
        wheels = PICKUP.wheels,
    })
    local p = P.build(v)
    checkTrue(p.valid, "getter-only vehicle valid")
    checkEq(counts.script, 1, "getScript once")
    checkEq(counts.extents, 1, "getExtents once")
    checkEq(counts.runtimeMass, 1, "runtime getMass once")
    checkEq(counts.maxSpeed, 1, "runtime getMaxSpeed once")
    checkEq(counts.mass, nil, "VehicleScript getMass unused")
    checkEq(counts.friction, 1, "getWheelFriction once")
    checkEq(counts.clamp, 3, "getSteeringClamp three speeds")
    checkEq(counts.wheel, 4, "getWheelById four standard ids")
    check(counts.x and counts.x >= 2, "Vector3f:x() used")
    check(counts.z and counts.z >= 2, "Vector3f:z() used")
    check(counts.offset and counts.offset >= 4, "getOffset used")
end

--------------------------------------------------------------------------------
scenario("exact clamps follow VehicleScript.getSteeringClamp")
do
    local seen = {}

    local lowSpeed = P.build(makeVehicle({
        fullName = "Base.LowRuntimeMax",
        bodyW = 1.8,
        bodyL = 4.4,
        mass = 1200,
        friction = 1.5,
        steeringClamp = 0.3,
        scriptMaxSpeed = 70,
        maxSpeed = 20,
        wheels = quad(0.7, 1.4, -1.1),
    }))
    checkTrue(lowSpeed.valid, "runtime max below 30 keeps speed-ordered clamps valid")
    check(lowSpeed.clamp30 <= lowSpeed.clampMax,
        "clamp30 is below clampMax when runtime max speed is below 30")
    local v = makeVehicle({
        fullName = "Base.ClampCar",
        bodyW = 1.8,
        bodyL = 4.4,
        mass = 1200,
        friction = 1.5,
        wheels = quad(0.7, 1.4, -1.1),
        clampFn = function(speed)
            seen[#seen + 1] = speed
            if speed == 0 then return 0.8 end
            if speed == 30 then return 0.5 end
            return 0.3
        end,
    })
    local p = P.build(v)
    checkTrue(p.valid, "monotonic clamps valid")
    checkNear(p.clamp0, 0.8, 1e-12, "clamp0 from getter")
    checkNear(p.clamp30, 0.5, 1e-12, "clamp30 from getter")
    checkNear(p.clampMax, 0.3, 1e-12, "clampMax from getter")
    checkEq(seen[1], 0, "first clamp speed 0")
    checkEq(seen[2], 30, "second clamp speed 30")
    checkEq(seen[3], 70, "third clamp uses runtime max speed")

    local pickup = P.build(makeVehicle(PICKUP))
    checkNear(pickup.clamp0, 0.9, 1e-9, "pickup clamp0 = 0.9")
    checkNear(pickup.clampMax, 0.3, 1e-9, "pickup clampMax = steeringClamp")
    checkNear(pickup.clamp30, javaClamp(30, 0.3, 70), 1e-9, "pickup clamp30")
end

--------------------------------------------------------------------------------
closeScenario()
print()
print("cases " .. scenarios .. ", asserts " .. assertions)
if failures > 0 then
    print(failures .. " failed")
    if os and os.exit then os.exit(1) end
    error(failures .. " failed")
end
print("all passed")
