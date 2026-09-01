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

loadProduction("shared/MDAD_Dynamics.lua")   -- Follower 於 chunk 期引用 MDADDynamics.finite
loadProduction("shared/MDAD_Follower.lua")   -- priors/configureFollower 讀 MDADFollower.SURFACE_*（協定常數單一出處）
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
    "valid", "fallback", "geometryValid", "scriptName",
    "bodyW", "bodyL", "halfW", "halfL",
    "centerOfMassX", "centerOfMassY", "centerOfMassZ",
    "mass", "maxSpeed", "wheelbase", "track", "clamp0", "clamp30", "clampMax",
    "wheelFriction", "delta0Safe", "deltaVSafe", "rMin", "lookScale",
    "rearArm", "needHalf", "probeR",
    "enginePower", "brakingForce", "offroadEfficiency", "rollInfluence",
    "tireFrictionMin", "tireFrictionAvg", "tireFrictionCount",
    "isAnyTireMissing",
}
local OPTIONAL_KEYS = {
    enginePower = true, brakingForce = true, offroadEfficiency = true,
    rollInfluence = true, centerOfMassY = true,
    tireFrictionMin = true, tireFrictionAvg = true, tireFrictionCount = true,
    isAnyTireMissing = true,
}


local function checkKeys(p, label)
    for i = 1, #KEYS do
        local k = KEYS[i]
        local v = p[k]
        if not OPTIONAL_KEYS[k] then check(v ~= nil, label .. " has " .. k) end
        if v ~= nil then
            if k == "valid" or k == "fallback" or k == "geometryValid"
                    or k == "isAnyTireMissing" then
                check(type(v) == "boolean", label .. " " .. k .. " boolean")
            elseif k ~= "scriptName" then
                check(type(v) == "number" and v * 0 == 0,
                    label .. " " .. k .. " finite scalar")
            end
        end
    end
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

local function wheel(x, z, counts, id)
    local o = {}
    function o:getOffset()
        if counts then counts.offset = (counts.offset or 0) + 1 end
        return vec(x, 0, z, counts)
    end
    function o:getId()
        if counts then counts.wheelId = (counts.wheelId or 0) + 1 end
        return id
    end
    return setmetatable(o, {
        __index = function(_, k) error("field access: " .. tostring(k)) end,
        __newindex = function(_, k) error("field write: " .. tostring(k)) end,
    })
end

local function tirePart(friction, hasItem, counts)
    local o = {}
    function o:getWheelFriction()
        if counts then counts.partFric = (counts.partFric or 0) + 1 end
        return friction
    end
    function o:getInventoryItem()
        if counts then counts.partItem = (counts.partItem or 0) + 1 end
        if hasItem == false then return nil end
        return {}
    end
    return setmetatable(o, {
        __index = function(_, k) error("field access: " .. tostring(k)) end,
        __newindex = function(_, k) error("field write: " .. tostring(k)) end,
    })
end

-- 標準四輪 id 的固定順序：mock getWheel(i) 的索引順序就照這份
local WHEEL_IDS = { "FrontLeft", "FrontRight", "RearLeft", "RearRight" }

-- 依固定順序列出「還在車上」的輪 id（nil／false＝拆掉）。getWheelCount 與
-- getWheel 共用同一份，兩邊的數量與順序不可能漂移。
local function presentWheelIds(wheels)
    local present = {}
    for i = 1, #WHEEL_IDS do
        local id = WHEEL_IDS[i]
        if wheels[id] then present[#present + 1] = id end
    end
    return present
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
        if w then return wheel(w[1], w[2], counts, id) end
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
    if not opts.oldOnly then
        function script:getOffroadEfficiency()
            counts.offroadEff = (counts.offroadEff or 0) + 1
            if opts.throwOffroadEfficiency then error("offroadEfficiency") end
            return opts.offroadEfficiency
        end
        function script:getRollInfluence()
            counts.roll = (counts.roll or 0) + 1
            if opts.throwRollInfluence then error("rollInfluence") end
            return opts.rollInfluence
        end
        function script:getCenterOfMassOffset()
            counts.com = (counts.com or 0) + 1
            if opts.throwCenterOfMass then error("centerOfMass") end
            return vec(opts.centerOfMassX or 0, opts.centerOfMassY,
                opts.centerOfMassZ or 0, counts)
        end
        function script:getWheelCount()
            counts.wheelCount = (counts.wheelCount or 0) + 1
            if opts.throwWheelCount then error("wheelCount") end
            if opts.wheelCount ~= nil then return opts.wheelCount end
            return #presentWheelIds(wheels)
        end
        function script:getWheel(index)
            counts.getWheel = (counts.getWheel or 0) + 1
            if opts.throwWheelIndex == index then error("wheel " .. tostring(index)) end
            local present = presentWheelIds(wheels)
            local id = present[index + 1]
            if not id then return nil end
            local w = wheels[id]
            return wheel(w[1], w[2], counts, id)
        end
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
    if not opts.oldOnly then
        function vehicle:getEnginePower()
            counts.enginePower = (counts.enginePower or 0) + 1
            if opts.throwEnginePower then error("enginePower") end
            return opts.enginePower
        end
        function vehicle:getBrakingForce()
            counts.brakingForce = (counts.brakingForce or 0) + 1
            if opts.throwBrakingForce then error("brakingForce") end
            return opts.brakingForce
        end
        if not opts.noTireMissingGetter then
            function vehicle:isAnyTireMissing()
                counts.tireMissing = (counts.tireMissing or 0) + 1
                if opts.throwTireMissing then error("tireMissing") end
                if opts.tireMissing == nil then return false end
                return opts.tireMissing == true
            end
        end
        if not opts.noPartLookup then
            function vehicle:getPartById(id)
                counts.partById = (counts.partById or 0) + 1
                if opts.throwPartLookup then error("partById") end
                local parts = opts.parts
                if type(parts) ~= "table" then
                    if opts.tireFriction == nil then return nil end
                    if type(id) ~= "string" or string.sub(id, 1, 4) ~= "Tire" then
                        return nil
                    end
                    return tirePart(opts.tireFriction, opts.tireItem ~= false, counts)
                end
                return parts[id]
            end
        end
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
local SMALL_CAR = {
    fullName = "Base.SmallCar",
    bodyW = 1.6,
    bodyL = 3.5,
    mass = 900,
    friction = 1.5,
    steeringClamp = 0.3,
    maxSpeed = 90,
    enginePower = 2600,
    brakingForce = 65,
    offroadEfficiency = 0.9,
    rollInfluence = 0.7,
    centerOfMassY = 0.45,
    tireFriction = 1.5,
    wheels = quad(0.7, 1.2, -0.9),
}
local PICKUP = {
    fullName = "Base.PickUpTruck",
    bodyW = 0.8681 * 1.82,
    bodyL = 2.1868 * 1.82,
    mass = 1030,
    friction = 1.5,
    steeringClamp = 0.3,
    maxSpeed = 70,
    enginePower = 4000,
    brakingForce = 80,
    offroadEfficiency = 1.1,
    rollInfluence = 0.7,
    centerOfMassY = 0.55,
    tireFriction = 1.5,
    wheels = quad(0.3462 * 1.82, 0.7582 * 1.82, -0.5879 * 1.82),
}
local VAN = {
    fullName = "Base.Van",
    bodyW = 2.1,
    bodyL = 5.6,
    mass = 1800,
    friction = 1.6,
    steeringClamp = 0.3,
    maxSpeed = 75,
    enginePower = 4200,
    brakingForce = 90,
    offroadEfficiency = 0.8,
    rollInfluence = 0.8,
    centerOfMassY = 0.65,
    tireFriction = 1.6,
    wheels = quad(0.85, 1.8, -1.8),
}
local F150 = {
    fullName = "Base.93fordF150",
    bodyW = 2.0 * 0.9,
    bodyL = 5.1778 * 0.9,
    mass = 670,
    friction = 1.7,
    steeringClamp = 0.3,
    maxSpeed = 80,
    enginePower = 4800,
    brakingForce = 90,
    offroadEfficiency = 1.1,
    rollInfluence = 0.8,
    centerOfMassY = 0.50,
    tireFriction = 1.7,
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
    enginePower = 5000,
    brakingForce = 100,
    offroadEfficiency = 1.15,
    rollInfluence = 0.8,
    centerOfMassY = 0.52,
    tireFriction = 1.7,
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
    enginePower = 5500,
    brakingForce = 110,
    offroadEfficiency = 1.2,
    rollInfluence = 0.85,
    centerOfMassY = 0.54,
    tireFriction = 1.7,
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
    checkTrue(p.geometryValid, label .. " geometryValid")
    checkNear(p.centerOfMassX, spec.centerOfMassX or 0, 1e-9, label .. " centerOfMassX")
    checkNear(p.centerOfMassZ, spec.centerOfMassZ or 0, 1e-9, label .. " centerOfMassZ")
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
    local needHalf = p.halfW + 0.3 -- 2026-09-01 去保守：NEED_MARGIN 0.3／NEED_BASE 1.2
    if needHalf < 1.2 then needHalf = 1.2 end
    checkNear(p.needHalf, needHalf, 1e-9, label .. " needHalf")
    local scale = math.sqrt(p.wheelbase / 1.35)
    local rear = 2.2 * clamp(scale * scale, 0.85, 1.35) -- 慣量補償：線性 wb 因子
    checkNear(p.rearArm, rear, 1e-9, label .. " rearArm")
    check(p.rearArm <= 2.2 * 1.35 + 1e-12, label .. " rearArm cap+35%")
    local probeR = clamp(0.5 * math.sqrt(p.bodyW * p.bodyW + p.bodyL * p.bodyL)
        + 1, 3, 7)
    checkNear(p.probeR, probeR, 1e-9, label .. " probeR")
    checkNear(p.rMin, p.wheelbase / math.tan(delta0Safe), 1e-9, label .. " rMin")
    checkNear(p.lookScale, clamp(scale, 0.85, 1.5), 1e-9, label .. " lookScale")
    if spec.enginePower then
        checkEq(p.enginePower, spec.enginePower, label .. " enginePower")
        checkEq(p.brakingForce, spec.brakingForce, label .. " brakingForce")
        checkEq(p.offroadEfficiency, spec.offroadEfficiency, label .. " offroadEfficiency")
        checkEq(p.rollInfluence, spec.rollInfluence, label .. " rollInfluence")
        checkNear(p.centerOfMassY, spec.centerOfMassY, 1e-9, label .. " centerOfMassY")
        checkEq(p.tireFrictionCount, 4, label .. " tireFrictionCount")
        checkNear(p.tireFrictionMin, spec.tireFriction, 1e-9, label .. " tireFrictionMin")
        checkNear(p.tireFrictionAvg, spec.tireFriction, 1e-9, label .. " tireFrictionAvg")
        checkFalse(p.isAnyTireMissing, label .. " tires present")
        checkTrue(p.valid, label .. " physics does not flip valid")
    end
    return p
end

--------------------------------------------------------------------------------
scenario("SmallCar / Van / pickup / F150 / F250 / F350 geometry and clamps")
do
    checkSpec(SMALL_CAR, "SmallCar")
    checkSpec(VAN, "Van")
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
        enginePower = 4000,
        brakingForce = 80,
        offroadEfficiency = 1.1,
        rollInfluence = 0.7,
        centerOfMassY = 0.55,
        tireFriction = 1.5,
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
    checkEq(counts.enginePower, 1, "getEnginePower once")
    checkEq(counts.brakingForce, 1, "getBrakingForce once")
    checkEq(counts.offroadEff, 1, "getOffroadEfficiency once")
    checkEq(counts.roll, 1, "getRollInfluence once")
    checkEq(counts.com, 1, "getCenterOfMassOffset once")
    checkEq(counts.wheelCount, 1, "getWheelCount once")
    checkEq(counts.getWheel, 4, "getWheel four indices")
    checkEq(counts.partById, 4, "getPartById four tires")
    checkEq(counts.tireMissing, 1, "isAnyTireMissing once")
    check(counts.x and counts.x >= 2, "Vector3f:x() used")
    check(counts.z and counts.z >= 2, "Vector3f:z() used")
    check(counts.y and counts.y >= 1, "Vector3f:y() used for CoM")
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
scenario("additive physics unknowns are omitted without changing legacy geometry")
do
    local base = {
        fullName = "Base.PickUpTruck",
        bodyW = PICKUP.bodyW,
        bodyL = PICKUP.bodyL,
        mass = 1030,
        friction = 1.5,
        steeringClamp = 0.3,
        maxSpeed = 70,
        wheels = PICKUP.wheels,
    }
    local old = {}
    for k, v in pairs(base) do old[k] = v end
    old.oldOnly = true
    local p = P.build(makeVehicle(old))
    checkKeys(p, "oldOnly")
    checkTrue(p.valid, "missing physics API keeps valid")
    checkFalse(p.fallback, "missing physics API does not set fallback")
    checkFalse(p.geometryValid, "missing COM API invalidates only control geometry")
    checkEq(p.centerOfMassX, 0, "missing COM x safely falls back 0")
    checkEq(p.centerOfMassZ, 0, "missing COM z safely falls back 0")
    checkEq(p.scriptName, "Base.PickUpTruck", "oldOnly keeps scriptName")
    checkEq(p.enginePower, nil, "missing enginePower omitted")
    checkEq(p.brakingForce, nil, "missing brakingForce omitted")
    checkEq(p.offroadEfficiency, nil, "missing offroadEfficiency omitted")
    checkEq(p.rollInfluence, nil, "missing rollInfluence omitted")
    checkEq(p.centerOfMassY, nil, "missing CoM y omitted")
    checkEq(p.tireFrictionCount, nil, "missing wheel enumeration omitted")
    checkEq(p.isAnyTireMissing, nil, "unknown tire state omitted")

    local thrown = {}
    for k, v in pairs(base) do thrown[k] = v end
    thrown.enginePower = 4000
    thrown.brakingForce = 80
    thrown.offroadEfficiency = 1.1
    thrown.rollInfluence = 0.7
    thrown.centerOfMassY = 0.55
    thrown.tireFriction = 1.5
    thrown.throwEnginePower = true
    thrown.throwBrakingForce = true
    thrown.throwOffroadEfficiency = true
    thrown.throwRollInfluence = true
    thrown.throwCenterOfMass = true
    thrown.throwWheelIndex = 2
    thrown.throwTireMissing = true
    local pThrown = P.build(makeVehicle(thrown))
    checkTrue(pThrown.valid, "throwing physics getters keep legacy geometry valid")
    checkFalse(pThrown.fallback, "throwing physics getters do not set legacy fallback")
    checkFalse(pThrown.geometryValid, "throwing COM invalidates only control geometry")
    checkEq(pThrown.centerOfMassX, 0, "throwing COM x falls back 0")
    checkEq(pThrown.centerOfMassZ, 0, "throwing COM z falls back 0")
    checkEq(pThrown.enginePower, nil, "throwing enginePower omitted")
    checkEq(pThrown.brakingForce, nil, "throwing brakingForce omitted")
    checkEq(pThrown.offroadEfficiency, nil, "throwing offroadEfficiency omitted")
    checkEq(pThrown.rollInfluence, nil, "throwing rollInfluence omitted")
    checkEq(pThrown.centerOfMassY, nil, "throwing CoM omitted")
    checkEq(pThrown.tireFrictionCount, nil, "partial wheel enumeration omitted")
    checkEq(pThrown.isAnyTireMissing, nil,
        "throwing runtime getter plus incomplete enumeration stays unknown")

    local pBad = P.build(makeVehicle({
        fullName = "Base.WildPhysics",
        bodyW = PICKUP.bodyW,
        bodyL = PICKUP.bodyL,
        mass = 1030,
        friction = 1.5,
        steeringClamp = 0.3,
        maxSpeed = 70,
        wheels = PICKUP.wheels,
        enginePower = 1e9,
        brakingForce = -4,
        offroadEfficiency = 0,
        rollInfluence = 9,
        centerOfMassY = 50,
        tireFriction = 800,
        tireMissing = true,
    }))
    checkKeys(pBad, "wild physics")
    checkTrue(pBad.valid, "illegal physics does not invalidate geometry")
    checkFalse(pBad.fallback, "illegal physics does not set fallback")
    checkEq(pBad.enginePower, nil, "OOB enginePower omitted")
    checkEq(pBad.brakingForce, nil, "OOB brakingForce omitted")
    checkEq(pBad.offroadEfficiency, nil, "OOB offroadEfficiency omitted")
    checkEq(pBad.rollInfluence, nil, "OOB rollInfluence omitted")
    checkEq(pBad.centerOfMassY, nil, "OOB CoM y omitted")
    checkEq(pBad.tireFrictionMin, nil, "OOB tire friction min omitted")
    checkEq(pBad.tireFrictionAvg, nil, "OOB tire friction average omitted")
    checkEq(pBad.tireFrictionCount, nil, "OOB tire friction aggregate omitted")
    checkTrue(pBad.isAnyTireMissing, "runtime tire getter true is kept")

    local enumerated = {}
    for k, v in pairs(base) do enumerated[k] = v end
    enumerated.enginePower = 4000
    enumerated.brakingForce = 80
    enumerated.offroadEfficiency = 1.1
    enumerated.rollInfluence = 0.7
    enumerated.centerOfMassY = 0.55
    enumerated.tireFriction = 1.4
    enumerated.noTireMissingGetter = true
    local pEnumerated = P.build(makeVehicle(enumerated))
    checkFalse(pEnumerated.isAnyTireMissing,
        "complete wheel enumeration proves no tire missing")

    enumerated.tireItem = false
    local pMiss = P.build(makeVehicle(enumerated))
    checkTrue(pMiss.valid, "missing tire items keep profile")
    checkEq(pMiss.tireFrictionCount, 0, "complete enumeration counts zero installed tires")
    checkEq(pMiss.tireFrictionMin, nil, "zero installed tires has no fake minimum")
    checkEq(pMiss.tireFrictionAvg, nil, "zero installed tires has no fake average")
    checkTrue(pMiss.isAnyTireMissing,
        "complete wheel enumeration proves a tire is missing without runtime getter")
end

--------------------------------------------------------------------------------
scenario("geometryValid isolates extents/COM from mass and additive physics")
do
    local badCom = P.build(makeVehicle({
        fullName = "Base.BadCOM",
        bodyW = PICKUP.bodyW, bodyL = PICKUP.bodyL,
        centerOfMassX = 99, centerOfMassZ = -99,
        mass = 1030, friction = 1.5, steeringClamp = 0.3, maxSpeed = 70,
        wheels = PICKUP.wheels,
    }))
    checkTrue(badCom.valid, "bad COM does not poison legacy valid")
    checkFalse(badCom.fallback, "bad COM does not set legacy fallback")
    checkFalse(badCom.geometryValid, "out-of-body COM fails control geometry")
    checkEq(badCom.centerOfMassX, 0, "bad COM x falls back 0")
    checkEq(badCom.centerOfMassZ, 0, "bad COM z falls back 0")

    local halfOutside = P.build(makeVehicle({
        fullName = "Base.HalfOutsideCOM",
        bodyW = 2, bodyL = 6,
        centerOfMassX = 1.1, centerOfMassZ = -3.1,
        mass = 1030, friction = 1.5, steeringClamp = 0.3, maxSpeed = 70,
        wheels = PICKUP.wheels,
    }))
    checkFalse(halfOutside.geometryValid,
        "half extent < |COM| <= full extent still fails control geometry")
    checkEq(halfOutside.centerOfMassX, 0, "half-outside COM x falls back 0")
    checkEq(halfOutside.centerOfMassZ, 0, "half-outside COM z falls back 0")

    local badMass = P.build(makeVehicle({
        fullName = "Base.BadMass",
        bodyW = PICKUP.bodyW, bodyL = PICKUP.bodyL,
        centerOfMassX = 0.1, centerOfMassZ = -0.2,
        mass = 1, friction = 1.5, steeringClamp = 0.3, maxSpeed = 70,
        wheels = PICKUP.wheels,
    }))
    checkFalse(badMass.valid, "bad mass still fails legacy valid")
    checkTrue(badMass.fallback, "bad mass still uses legacy fallback")
    checkTrue(badMass.geometryValid, "valid extents/COM stay usable despite bad mass")
    checkNear(badMass.centerOfMassX, 0.1, 1e-9, "COM x retained")
    checkNear(badMass.centerOfMassZ, -0.2, 1e-9, "COM z retained")
end

--------------------------------------------------------------------------------
scenario("derived geometry is monotonic; steering kappa shrinks with speed")
do
    local small = P.build(makeVehicle(SMALL_CAR))
    local van = P.build(makeVehicle(VAN))
    check(van.wheelbase > small.wheelbase, "fixture wheelbase grows")
    check(van.lookScale >= small.lookScale, "wheelbase up => lookScale nondecreasing")
    check(van.rearArm >= small.rearArm, "wheelbase up => rearArm nondecreasing")
    check(van.rMin >= small.rMin, "wheelbase up => rMin nondecreasing")
    check(van.bodyW > small.bodyW and van.needHalf > small.needHalf,
        "body width up => needHalf grows")
    check(van.probeR > small.probeR, "body diagonal up => probeR grows")
end

--------------------------------------------------------------------------------
scenario("surface/tire/engine/brake priors only tighten legacy envelopes")
do
    local p = P.build(makeVehicle(PICKUP))
    local ad, bd, ld, fsd, ftd, coast =
        P.priors(p, p.mass, MDADFollower.SURFACE_PAVED, false, false, true)
    local aw, bw, lw, fsw = P.priors(p, p.mass, MDADFollower.SURFACE_PAVED, true, false, true)
    local au, bu, lu, fsu = P.priors(p, p.mass, MDADFollower.SURFACE_UNKNOWN, false, false, true)
    local ao = P.priors(p, p.mass, MDADFollower.SURFACE_PAVED, false, true, true)
    -- aBrake 基準 8、aLat 基準 9（2026-09-02 二次激進化；天氣／胎況仍只降不升）
    check(ad <= 2.5 and bd <= 8 and ld <= 9.0, "dry paved never exceeds base priors")
    checkNear(fsd, 1, 1e-12, "dry paved surface factor")
    checkNear(fsw, 0.7, 1e-12, "wet paved surface factor")
    checkNear(fsu, 0.7, 1e-12, "unknown surface uses offroad factor")
    check(bw < bd and lw < ld, "rain tightens brake and lateral priors")
    check(bu < bd and lu < ld, "unknown surface tightens brake and lateral priors")
    check(ao < ad, "physical offroad tightens drive prior only")
    checkNear(ftd, 1, 1e-12, "known complete tires retain factor one")
    checkNear(coast, 0.6, 1e-12, "coast prior stays fixed at 0.6")
    p.rollInfluence, p.centerOfMassY = 0, 3
    local ar, br, lr = P.priors(p, p.mass, MDADFollower.SURFACE_PAVED, false, false, true)
    checkNear(ar, ad, 1e-12, "rollInfluence/COMY do not enter drive prior")
    checkNear(br, bd, 1e-12, "rollInfluence/COMY do not enter brake prior")
    checkNear(lr, ld, 1e-12, "rollInfluence/COMY do not enter lateral prior")

    local missing = P.build(makeVehicle({
        fullName = PICKUP.fullName, bodyW = PICKUP.bodyW, bodyL = PICKUP.bodyL,
        mass = PICKUP.mass, friction = PICKUP.friction,
        steeringClamp = PICKUP.steeringClamp, maxSpeed = PICKUP.maxSpeed,
        enginePower = PICKUP.enginePower, brakingForce = PICKUP.brakingForce,
        offroadEfficiency = PICKUP.offroadEfficiency, tireMissing = true,
        tireFriction = PICKUP.tireFriction, wheels = PICKUP.wheels,
    }))
    local _, bm, lm, _, ftm = P.priors(
        missing, missing.mass, MDADFollower.SURFACE_PAVED, false, false, true)
    checkNear(ftm, 0.35, 1e-12, "missing tire clamps factor to 0.35")
    check(bm < bd and lm < ld, "missing tire tightens brake/lateral")

    local unknown = P.build(makeVehicle({
        fullName = PICKUP.fullName, bodyW = PICKUP.bodyW, bodyL = PICKUP.bodyL,
        mass = PICKUP.mass, friction = PICKUP.friction,
        steeringClamp = PICKUP.steeringClamp, maxSpeed = PICKUP.maxSpeed,
        oldOnly = true, wheels = PICKUP.wheels,
    }))
    local _, _, _, _, ftu = P.priors(
        unknown, unknown.mass, MDADFollower.SURFACE_PAVED, false, false, false)
    checkNear(ftu, 0.8, 1e-12, "unknown tire reading tightens to 0.8")
    p.enginePower, p.brakingForce = 0, 0
    local zeroDrive, zeroBrake = P.priors(
        p, p.mass, MDADFollower.SURFACE_PAVED, false, false, true)
    checkNear(zeroDrive, 0, 1e-12, "zero engine prior stays zero")
    checkNear(zeroBrake, 0, 1e-12, "zero braking prior stays zero")
end

--------------------------------------------------------------------------------
scenario("EWMA mean/dev/confidence/lower bound follows the approved scalar formula")
do
    local mean, dev, seconds = 2, 0, 0
    local confidence, lower
    for _ = 1, 20 do
        mean, dev, seconds, confidence, lower =
            P.updateEWMA(mean, dev, seconds, 2, 1)
    end
    checkNear(mean, 2, 1e-12, "constant observation keeps mean")
    checkNear(dev, 0, 1e-12, "constant observation keeps deviation zero")
    checkNear(seconds, 20, 1e-12, "valid sample seconds accumulate")
    checkNear(confidence, 1, 1e-12, "20 seconds reaches full confidence")
    checkNear(lower, 2, 1e-12, "lower bound is mean-2dev")
    local m2, d2, s2, c2, l2 = P.updateEWMA(mean, dev, seconds, 0, 1)
    check(m2 < mean and d2 > 0, "new lower observation moves mean/dev")
    checkNear(s2, 21, 1e-12, "next valid second accumulates")
    checkNear(c2, 1, 1e-12, "confidence remains clamped")
    check(l2 >= 0 and l2 <= m2, "lower bound remains nonnegative and conservative")
end

--------------------------------------------------------------------------------
scenario("configureFollower caches priors by four surface ids, independent of route length")
do
    local p = P.build(makeVehicle(PICKUP))
    local follower = {
        n = 401, segSurface = {}, segAccel = {}, segBrake = {}, segCoast = {}, segLat = {},
    }
    for i = 1, 400 do follower.segSurface[i] = (i - 1) % 4 end
    local originalPriors, originalSqrt = P.priors, math.sqrt
    local priorCalls, sqrtCalls = 0, 0
    P.priors = function(...)
        priorCalls = priorCalls + 1
        return originalPriors(...)
    end
    math.sqrt = function(v)
        sqrtCalls = sqrtCalls + 1
        return originalSqrt(v)
    end
    local ok = P.configureFollower(follower, p, p.mass, false)
    math.sqrt, P.priors = originalSqrt, originalPriors
    checkTrue(ok, "long follower remains adaptive")
    checkEq(priorCalls, 4, "one prior calculation per surface id")
    check(sqrtCalls <= 8, "sqrt count bounded by four surfaces, not 400 segments")
    checkEq(follower.segAccel[1], follower.segAccel[5],
        "same surface reuses identical cached prior")
end

scenario("clearanceBudget：餘裕預算單一 authority（階段 2 主體 4）")
do
    -- 三個 mode 的預算值是契約，不是實作細節：cruise 巡航、squeeze 貼縫爬行、
    -- probe 世界掃掠容許的剮蹭量（唯一允許為負者）。
    checkNear(P.clearanceBudget("cruise"), 0.3, 1e-12, "cruise 預算 0.30")
    checkNear(P.clearanceBudget("squeeze"), 0.1, 1e-12, "squeeze 預算 0.10")
    checkNear(P.clearanceBudget("probe"), -0.1, 1e-12, "probe 預算 -0.10（剮蹭）")
    checkNear(P.clearanceBudget("nonsense"), P.clearanceBudget("cruise"), 1e-12,
        "未知 mode 退最保守的 cruise")
    check(P.clearanceBudget("squeeze") < P.clearanceBudget("cruise"),
        "squeeze 必須比 cruise 緊（否則爬行檔沒有存在意義）")
    check(P.clearanceBudget("probe") < 0,
        "probe 是唯一可為負的預算（容許剮蹭）")
    checkNear(P.clearanceBudget("physical"), 0, 1e-12,
        "physical 預算 0（物理終審只認車身本體）")
    check(P.clearanceBudget("physical") < P.clearanceBudget("squeeze"),
        "physical 比 squeeze 更貼身（它是最後一道枚舉檔）")
    checkNear(P.planNeed(0.9, "physical"), 0.9, 1e-12, "physical need = halfW")
    checkNear(P.planNeed(0.5, "physical"), 0.5, 1e-12, "physical 不吃 1.2 地板")
    checkNear(P.sweepBase(0.9, "physical"), 0.8, 1e-12,
        "physical sweep base = halfW-0.1（容許 10cm 名義重疊，不變）")
    -- planNeed：halfW + 該 mode 預算；cruise 吃 1.2 絕對地板，squeeze 不吃
    checkNear(P.planNeed(0.9, "cruise"), 1.2, 1e-12, "1.8m 車 cruise need 1.2")
    checkNear(P.planNeed(1.2, "cruise"), 1.5, 1e-12, "寬車 cruise need = halfW+0.3")
    checkNear(P.planNeed(0.5, "cruise"), 1.2, 1e-12, "窄車 cruise 吃 1.2 地板")
    checkNear(P.planNeed(0.9, "squeeze"), 1.0, 1e-12, "squeeze need = halfW+0.1（無地板）")
    check(P.planNeed(0.9, "squeeze") < P.planNeed(0.9, "cruise"),
        "同車 squeeze need 嚴格小於 cruise need")
    check(P.planNeed(1.4, "cruise") > P.planNeed(1.2, "cruise"),
        "need 隨車寬單調遞增")
    checkNear(P.planNeed(0 / 0, "cruise"), 1.2, 1e-12, "halfW 非有限值退地板")
    -- sweepBase 必須恰好是 planNeed 再加 probe 預算：任何額外私扣都會讓
    -- 餘裕疊加超支，把 2.4m 的縫對 1.8m 的車判死（第六層洋蔥的定罪點）。
    for _, hw in ipairs({ 0.5, 0.9, 1.2, 1.6 }) do
        for _, m in ipairs({ "cruise", "squeeze" }) do
            checkNear(P.sweepBase(hw, m),
                P.planNeed(hw, m) + P.clearanceBudget("probe"), 1e-12,
                "sweepBase(" .. hw .. "," .. m .. ") 只扣一次 probe")
        end
    end
    check(P.sweepBase(0.05, "squeeze") >= 0, "sweepBase 不得為負")
    -- derive 出來的 needHalf 必須就是 authority 的值（不得有第二套公式）
    local p = P.build(makeVehicle({}))
    checkNear(p.needHalf, P.planNeed(p.halfW, "cruise"), 1e-12,
        "profile.needHalf 由 planNeed 導出")
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
