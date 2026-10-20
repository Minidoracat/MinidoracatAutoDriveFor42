-- MDAD_Consumption.lua — GPS／自駕的 server-authoritative 電力與燃油成本。
--
-- Fuel：包住 vanilla Vehicles.Update.GasTank，先讓原版依引擎、檔位、車重、車況、
-- CarGasConsumption 等條件扣一次，再只對 before-after 差分加成。client 永不突變。
-- 自駕時原版那份改照「同車速手動駕駛會用的檔」計（autoFuelBase），再乘加成。
-- Power：不能包 Battery（client 的 drainBatteryUpdateHack 也會跑該 updater，會雙扣）；
-- 改用 EveryOneMinute，在 server/SP 依 world age 差分補扣裝置負載。
if isClient() then return end

require "MDAD"

local MAX_POWER_MINUTES = 5
local lastWorldAgeHours = nil
local powerVehicles = {}
local powerNav = {}

local function wipe(t)
    for key in pairs(t) do t[key] = nil end
end

local function elapsedPowerMinutes()
    local now = getGameTime():getWorldAgeHours()
    if type(now) ~= "number" or now ~= now then return 1 end
    local last = lastWorldAgeHours
    lastWorldAgeHours = now
    if type(last) ~= "number" or now <= last then return 1 end
    local minutes = (now - last) * 60
    if minutes > MAX_POWER_MINUTES then return MAX_POWER_MINUTES end
    return minutes
end

local function collectPlayer(player, minutes)
    if not player or player:isDead() then return end
    local vehicle = player:getVehicle()
    local navOn, source = MDAD.isNavUsageActive(player, vehicle)
    if vehicle then
        local vehicleId = vehicle:getId()
        if MDAD.isFiniteInt(vehicleId) then
            powerVehicles[vehicleId] = vehicle
            if navOn and source == "vehicle" then
                powerNav[vehicleId] = true
            elseif navOn then
                local portable = MDAD.findChargedPortableGPS(player)
                if portable then MDAD.consumePortablePower(portable, minutes) end
            end
        end
    elseif navOn then
        local portable = MDAD.findChargedPortableGPS(player)
        if portable then MDAD.consumePortablePower(portable, minutes) end
    end
end

local function consumeCollectedVehicles(minutes)
    for vehicleId, vehicle in pairs(powerVehicles) do
        local navOn = powerNav[vehicleId] == true
        local autoOn = MDAD.isAutoUsageActive(vehicle)
        if navOn or autoOn then
            MDAD.consumeVehiclePowerModes(vehicle, navOn, autoOn, minutes)
        end
    end
end

local function onEveryOneMinute()
    local minutes = elapsedPowerMinutes()
    wipe(powerVehicles)
    wipe(powerNav)

    if isServer() then
        local online = getOnlinePlayers()
        local count = online and online:size() or 0
        for i = 0, count - 1 do collectPlayer(online:get(i), minutes) end
    else
        local count = getNumActivePlayers()
        if type(count) ~= "number" or count < 0 then count = 0 end
        for i = 0, count - 1 do collectPlayer(getSpecificPlayer(i), minutes) end
    end

    consumeCollectedVehicles(minutes)
    MDAD.pruneNavUsage()
    MDAD.pruneAutoUsage()
end

-- 自駕的原版油耗基準（2026-10-17 使用者裁定：修好自駕轉彎、繞行多耗的油，不得影響車速——只改計費、不動控制）。
-- 原版每遊戲分鐘扣 MDAD.gasGearTerm（檔位項）×轉速÷2500×其他倍率（Vehicles.lua:464-487）：
-- 同一檔車速越低扣越多。自駕靠 regulator 控速，regulator 開著時引擎不掛 N、加油只升不降檔
-- （CarController.java:494-504、719-727），彎前與繞行減速後一路卡在高檔，每分鐘多扣 4–14 倍；玩家自己開會掛 N，
-- 再踩油門照車速選檔。所以改照 CarController 依當下車速會選的檔（MDAD.fairGear）換算；客戶端摘要 fuE 用同兩支算期望。
-- 只在實扣量吻合原版公式時換算：別的 MOD 改寫 GasTank、或原版改了公式，就照實扣量計。
local GAS_MATCH_REL = 0.02
local GAS_MATCH_ABS = 0.0002

local function autoFuelBase(vehicle, burned, elapsedMinutes)
    local kmh = vehicle:getCurrentSpeedKmHour()
    if not (kmh >= 1) then return burned end -- 原版 floor(車速)>0 才看檔位（停車段另一條式子）；NaN 也擋
    local gear = vehicle:getTransmissionNumber()
    if gear < 2 then return burned end
    local script = vehicle:getScript()
    local gears = script and script:getGearRatioCount()
    local maxKmh = vehicle:getMaxSpeed()
    local cgc = SandboxVars and SandboxVars.CarGasConsumption
    if type(gears) ~= "number" or gears < 2 or type(maxKmh) ~= "number" or maxKmh <= 0
            or type(cgc) ~= "number" then
        return burned
    end
    local fair = MDAD.fairGear(kmh, gear, gears, maxKmh)
    if not fair then return burned end
    local perGear = maxKmh / gears
    local held = MDAD.gasGearTerm(gear, kmh, perGear)
    local gasMult = 90000
    local heater = vehicle:getHeater()
    if heater and heater:getModData().active then gasMult = gasMult - 5000 end
    gasMult = gasMult / ((100 - vehicle:getEngineQuality()) / 200 + 1)
        / (math.abs(1000 - script:getMass()) / 300 + 1)
    local expect = held / gasMult * cgc * vehicle:getEngineSpeed() / 2500 * elapsedMinutes
    local miss = burned - expect
    if miss < 0 then miss = -miss end
    if not (miss <= expect * GAS_MATCH_REL + GAS_MATCH_ABS) then return burned end
    return burned * MDAD.gasGearTerm(fair, kmh, perGear) / held
end

local fuelHookWarned = false

local function installFuelHook()
    local current = Vehicles and Vehicles.Update and Vehicles.Update.GasTank
    if type(current) ~= "function" then return false end
    if MDAD._gasTankWrapper and current == MDAD._gasTankWrapper then return true end

    local vanilla = current
    local function wrappedGasTank(vehicle, part, elapsedMinutes)
        local before = part:getContainerContentAmount()
        local result = vanilla(vehicle, part, elapsedMinutes)
        local after = part:getContainerContentAmount()
        local burned = before - after
        if burned <= 0 then return result end

        local navOn, autoOn = MDAD.vehicleUsageModes(vehicle)
        local base = burned
        if autoOn then base = autoFuelBase(vehicle, burned, elapsedMinutes) end
        local factor = MDAD.extraFuelFactor(navOn, autoOn)
        if factor <= 0 and base >= burned then return result end

        -- 退回原版多扣的檔位差（burned−base），再扣本 MOD 的加成（base×factor）
        local amount = after + (burned - base) - base * factor
        if amount < 0 then amount = 0 end
        if amount == after then return result end
        part:setContainerContentAmount(amount, false, true)
        amount = part:getContainerContentAmount()
        local precision = amount < 0.5 and 2 or 1
        if VehicleUtils.compareFloats(after, amount, precision) then
            vehicle:transmitPartModData(part)
        end
        return result
    end

    MDAD._gasTankWrapper = wrappedGasTank
    Vehicles.Update.GasTank = wrappedGasTank
    return true
end

local function retryFuelHook()
    if installFuelHook() or fuelHookWarned then return end
    fuelHookWarned = true
    print("[MinidoracatAutoDrive] build " .. MDAD.BUILD
        .. " fuel hook unavailable; extra fuel consumption disabled")
end

local function verifyFuelHook()
    if not MDAD._gasTankWrapper or MDAD._fuelHookChangedWarned then return end
    local current = Vehicles and Vehicles.Update and Vehicles.Update.GasTank
    if current ~= MDAD._gasTankWrapper then
        MDAD._fuelHookChangedWarned = true
        print("[MinidoracatAutoDrive] build " .. MDAD.BUILD
            .. " fuel hook slot changed after install; extra fuel compatibility unverified")
    end
end

if not MDAD._powerMinuteHandler then
    MDAD._powerMinuteHandler = onEveryOneMinute
    Events.EveryOneMinute.Add(onEveryOneMinute)
end
if not installFuelHook() and not MDAD._fuelRetryHandler then
    -- 正常載入次序下 Vehicles 已存在；若第三方 loader 延後建立 table，世界啟動時補一次。
    MDAD._fuelRetryHandler = retryFuelHook
    Events.OnGameStart.Add(retryFuelHook)
    Events.OnServerStarted.Add(retryFuelHook)
end
if not MDAD._fuelVerifyHandler then
    MDAD._fuelVerifyHandler = verifyFuelHook
    Events.OnGameStart.Add(verifyFuelHook)
    Events.OnServerStarted.Add(verifyFuelHook)
end
