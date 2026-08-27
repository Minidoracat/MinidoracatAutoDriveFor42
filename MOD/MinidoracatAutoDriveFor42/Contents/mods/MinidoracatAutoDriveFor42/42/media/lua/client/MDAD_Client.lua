-- MDAD_Client.lua — registerNavGate＋車輛右鍵安裝／卸載（不做 radial，M3 再加）

require "MDAD"
require "TimedActions/ISAutoDriveDeviceAction"

local OWNER = MDAD.MOD_ID
local LOG = "[" .. OWNER .. "] "

-- nav gate 註冊狀態必須對玩家可見。載入期的 print 只有開 console 的人看得到，而
-- 註冊失敗（主 MOD 未安裝／版本太舊沒有 navApiVersion≥1）代表閘門完全沒掛上：
-- NeedItemForNav=true 的伺服器會變成「設了要道具，實際上誰都能導航」的靜默行為差異。
-- 因此保留 print 當診斷，另外在開局時對本機玩家補一則 halo 提示。
-- option 關閉時閘門本來就永遠放行，註冊失敗無感，不提示（避免無意義的紅字）。
local navGateReady = false
local navWarned = {}

local function registerNavGate()
    if navGateReady then return end
    local api = MinidoracatMiniMapAPI
    if not api or type(api.navApiVersion) ~= "number" or api.navApiVersion < 1
            or type(api.registerNavGate) ~= "function" then
        print(LOG .. "registerNavGate failed: nav API missing")
        return
    end
    local ok = api.registerNavGate(OWNER, MDAD.navGate)
    if not ok then
        print(LOG .. "registerNavGate failed: nav gate NOT installed")
        return
    end
    navGateReady = true
end

-- 每個本機玩家只提示一次（navWarned 以 slot 索引為鍵）。
-- HaloTextHelper.addBadText 用例 ISVehiclePartMenu.lua:252。
local function warnNavGateMissing(playerNum)
    if navGateReady or navWarned[playerNum] then return end
    if MDAD.sandbox("NeedItemForNav", false) ~= true then return end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end
    navWarned[playerNum] = true
    HaloTextHelper.addBadText(playerObj, getText("UI_MinidoracatAutoDrive_NavApiMissing"))
end

-- 載入期 registerNavGate 可能早於主 MOD 的 API 建立（載入順序不保證），所以 OnGameStart
-- 再重試一次；重試後才是最終狀態，這時才提示。
-- getNumActivePlayers()＋getSpecificPlayer 走訪本機 slot 是原版慣例（ISJoyPadListBox.lua:23-24）。
local navGateStarted = false

local function onGameStart()
    registerNavGate()
    navGateStarted = true
    for i = 0, getNumActivePlayers() - 1 do
        warnNavGateMissing(i)
    end
end

registerNavGate()
Events.OnGameStart.Add(onGameStart)
-- 分割畫面第二位玩家在開局後才建立。OnCreatePlayer 只帶 slot 索引，玩家物件自己查
-- （原版慣例 TutorialSetup.lua:34-35）；載入期的 OnCreatePlayer 早於 OnGameStart 重試，
-- 那時註冊狀態還沒定案，因此以 navGateStarted 擋掉、交給 onGameStart 的迴圈負責。
Events.OnCreatePlayer.Add(function(playerNum)
    if navGateStarted then warnNavGateMissing(playerNum) end
end)


local function disableOption(option, key)
    option.notAvailable = true
    local tip = ISWorldObjectContextMenu.addToolTip()
    tip.description = getText(key)
    option.toolTip = tip
end

local function queueDeviceAction(playerObj, vehicle, kind, install, item)
    if playerObj:getVehicle() == vehicle then
        ISVehicleMenu.onExit(playerObj)
    end
    if item then
        ISVehiclePartMenu.toPlayerInventory(playerObj, item)
    end
    local part = MDAD.getBatteryPart(vehicle)
    local area = part and part:getArea()
    if area then
        -- ISPathFindAction.lua:172
        ISTimedActionQueue.add(ISPathFindAction:pathToVehicleArea(playerObj, vehicle, area))
    end
    local screwdriver = MDAD.findScrewdriver(playerObj)
    if screwdriver then
        ISWorldObjectContextMenu.equip(playerObj, playerObj:getPrimaryHandItem(), screwdriver, true, false)
    end
    ISTimedActionQueue.add(ISAutoDriveDeviceAction:new(playerObj, vehicle, kind, install, item))
end

local function addDeviceOption(context, playerObj, vehicle, kind, install, item, labelKey)
    local option = context:addOption(getText(labelKey), playerObj, queueDeviceAction, vehicle, kind, install, item)
    local reason = MDAD.deviceBlockReason(playerObj, vehicle, kind, install)
    if reason then
        disableOption(option, reason)
    end
end

local function getTargetVehicle(playerObj, player)
    local vehicle = playerObj:getVehicle()
    if vehicle then return vehicle end
    -- 滑鼠拾取只在鍵鼠模式有意義（手把沒有游標）；ISVehicleMenu.lua:49
    if not JoypadState.players[player + 1] then
        vehicle = IsoObjectPicker.Instance:PickVehicle(getMouseXScaled(), getMouseYScaled())
        if vehicle then return vehicle end
    end
    return playerObj:getUseableVehicle() or playerObj:getNearVehicle()
end

local function onFillWorldObjectContextMenu(player, context, worldobjects, test)
    if test then return end
    local playerObj = getSpecificPlayer(player)
    if not playerObj then return end
    local vehicle = getTargetVehicle(playerObj, player)
    if not vehicle then return end

    if MDAD.isNavInstalled(vehicle) then
        addDeviceOption(context, playerObj, vehicle, "nav", false, nil, "UI_MinidoracatAutoDrive_UninstallGPS")
    else
        local gps = MDAD.findPortableGPS(playerObj)
        if gps then
            addDeviceOption(context, playerObj, vehicle, "nav", true, gps, "UI_MinidoracatAutoDrive_InstallGPS")
        end
    end

    if MDAD.isAutoInstalled(vehicle) then
        addDeviceOption(context, playerObj, vehicle, "auto", false, nil, "UI_MinidoracatAutoDrive_UninstallAuto")
    else
        local module = MDAD.findAutopilot(playerObj)
        if module then
            addDeviceOption(context, playerObj, vehicle, "auto", true, module, "UI_MinidoracatAutoDrive_InstallAuto")
        end
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)


-- 遠端失敗提示：MP 的突變在伺服器端執行（server/MDAD_Server.lua），被拒時回一則
-- 翻譯鍵，這裡以 HaloTextHelper 在操作者頭上單點回報，UX 與 SP 一致。
-- Events.OnServerCommand 簽名（module, command, args）＝ServerCommands.lua:201-212；
-- HaloTextHelper.addBadText 用例 ISVehiclePartMenu.lua:252。
-- 以 args.to（角色名）比對本機玩家：同機分割畫面共用一條 connection，
-- OnServerCommand 收不到「給誰」，沒有 to 會把提示掛到錯的玩家頭上。
-- getNumActivePlayers()＋getSpecificPlayer 走訪本機 slot 是原版慣例（ISJoyPadListBox.lua:23-24）。
local function findLocalPlayer(username)
    if type(username) ~= "string" then return nil end
    for i = 0, getNumActivePlayers() - 1 do
        local playerObj = getSpecificPlayer(i)
        if playerObj and playerObj:getUsername() == username then return playerObj end
    end
    return nil
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= OWNER or command ~= MDAD.CMD_DEVICE_FAILED then return end
    if type(args) ~= "table" or type(args.reason) ~= "string" then return end
    local playerObj = findLocalPlayer(args.to)
    if not playerObj then return end
    HaloTextHelper.addBadText(playerObj, getText(args.reason))
end)
