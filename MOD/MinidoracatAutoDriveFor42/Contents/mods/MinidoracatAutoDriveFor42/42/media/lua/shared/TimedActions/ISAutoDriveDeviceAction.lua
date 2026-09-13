-- GPS／自駕正式零件的權威拆裝動作。
-- 原版 install/uninstall constructor 先執行（包含其他 MOD 的攔截），只把成功回傳的
-- 我方零件 instance 換成此類別；右鍵與維修面板因此走同一條路。
-- 此類別只繼承 ISBaseTimedAction，不定義 complete：NetTimedAction 的參數可由 client
-- 指定，不能拿鏡像 character 當權威。perform 仍送 OnClientCommand，由連線 actor 重驗。
-- Kahlua rawget 會沿 metatable 找值，不能派生原版動作後僅寫 complete=nil：
-- 那樣仍繼承原版 complete，會再次打開遠端動作突變路徑。

require "TimedActions/ISBaseTimedAction"
require "Vehicles/TimedActions/ISInstallVehiclePart"
require "Vehicles/TimedActions/ISUninstallVehiclePart"
require "MDAD"

ISAutoDriveDeviceAction = ISBaseTimedAction:derive("ISAutoDriveDeviceAction")
-- 原版 derive 只設父類的 __index；此類不呼叫自己的 new，須明確設定實例查找入口。
ISAutoDriveDeviceAction.__index = ISAutoDriveDeviceAction

local WORK_TIME = 150


function ISAutoDriveDeviceAction:isValid()
    if not self.character or not self.vehicle then return false end
    if self.kind ~= "nav" and self.kind ~= "auto" then return false end
    if MDAD.deviceBlockReason(self.character, self.vehicle, self.kind, self.install) then
        return false
    end
    if not MDAD.canReachVehicle(self.character, self.vehicle) then return false end
    if self.install then
        if not self.item then return false end
        local inv = self.character:getInventory()
        if isClient() then
            if not inv:containsID(self.item:getID()) then return false end
        else
            if not inv:contains(self.item) then return false end
        end
        local want = MDAD.TYPE_GPS
        if self.kind == "auto" then want = MDAD.TYPE_AUTO end
        if self.item:getFullType() ~= want then return false end
    end
    return true
end

function ISAutoDriveDeviceAction:waitToStart()
    self.character:faceThisObject(self.vehicle)
    return self.character:shouldBeTurning()
end

function ISAutoDriveDeviceAction:update()
    self.character:faceThisObject(self.vehicle)
    if self.item then
        self.item:setJobDelta(self:getJobDelta())
    end
    self.character:setMetabolicTarget(Metabolics.MediumWork)
end

function ISAutoDriveDeviceAction:start()
    if isClient() and self.item then
        self.item = self.character:getInventory():getItemById(self.item:getID())
    end
    if self.item then
        self.item:setJobType(self.jobType)
    end
    self:setActionAnim("VehicleWorkOnMid")
end

function ISAutoDriveDeviceAction:stop()
    if self.item then
        self.item:setJobDelta(0)
    end
    ISBaseTimedAction.stop(self)
end

function ISAutoDriveDeviceAction:perform()
    local pdata = getPlayerData(self.character:getPlayerNum())
    if pdata ~= nil then
        pdata.playerInventory:refreshBackpacks()
        pdata.lootInventory:refreshBackpacks()
    end
    -- 收尾：清掉物品圖示上的進度條（update 每 tick 都在寫 jobDelta）
    if self.item then
        self.item:setJobDelta(0)
    end
    -- character／vehicle 由 isValid 把關（nil 即 invalid，引擎不會走到 perform）。
    -- 只送純量：vehicleId／kind／install／itemId。actor 不送（server 用連線身分），
    -- partId／navDelta／state 也不送（server 自己解析與讀取）。
    -- sendClientCommand(player, module, command, args)＝LuaManager.java:8912
    -- （原版用例 ISVehicleMechanics.lua:585 的 isClient() 分流同款）；
    -- vehicle:getId()＝BaseVehicle.java:8402，server 端以 getVehicleById 重查。
    local itemId = -1
    if self.item then itemId = self.item:getID() end
    if isClient() then
        sendClientCommand(self.character, MDAD.MOD_ID, MDAD.CMD_DEVICE, {
            vehicleId = self.vehicle:getId(),
            kind = self.kind,
            install = self.install == true,
            itemId = itemId,
        })
    else
        -- SP：沒有網路權威問題，直接走同一份 shared apply（不經 OnClientCommand，
        -- 因此不會與 server handler 重複執行）
        local ok, reason = MDAD.applyDeviceChange(self.character, self.vehicle,
            self.kind, self.install == true, itemId)
        -- 與 MP 的失敗提示對齊（MP 走 server → OnServerCommand → client）。
        -- isServer() 守衛：專用伺服器不畫 UI（正常情況這條分支只在 SP 走到）。
        -- HaloTextHelper.addBadText 在 shared TimedAction 內的原版用例：ISReadABook.lua:7
        if not ok and reason and not isServer() then
            HaloTextHelper.addBadText(self.character, getText(reason))
        end
    end
    ISBaseTimedAction.perform(self)
end

function ISAutoDriveDeviceAction:getDuration()
    if self.character and self.character:isTimedActionInstant() then
        return 1
    end
    return WORK_TIME
end

local function deviceAction(action, character, part, kind, install, item)
    if not action or action.ignoreAction then return action end
    setmetatable(action, ISAutoDriveDeviceAction)
    local o = action
    o.complete = nil
    o.Type = ISAutoDriveDeviceAction.Type
    o.character = character
    o.vehicle = part:getVehicle()
    o.part = part
    o.kind = kind
    o.install = install
    o.item = item
    o.maxTime = o:getDuration()
    if install then
        if kind == "nav" then
            o.jobType = getText("UI_MinidoracatAutoDrive_InstallGPS")
        else
            o.jobType = getText("UI_MinidoracatAutoDrive_InstallAuto")
        end
    else
        if kind == "nav" then
            o.jobType = getText("UI_MinidoracatAutoDrive_UninstallGPS")
        else
            o.jobType = getText("UI_MinidoracatAutoDrive_UninstallAuto")
        end
    end
    return o
end

-- 保留原版具名參數：NetTimedAction.set 會讀 new 的參數名序列化其他零件的動作。
local installNew = ISInstallVehiclePart.new
function ISInstallVehiclePart:new(character, part, item, maxTimeInit)
    local action = installNew(self, character, part, item, maxTimeInit)
    local kind = MDAD.deviceKind(part)
    if not kind then return action end
    return deviceAction(action, character, part, kind, true, item)
end

local uninstallNew = ISUninstallVehiclePart.new
function ISUninstallVehiclePart:new(character, part, workTime)
    local action = uninstallNew(self, character, part, workTime)
    local kind = MDAD.deviceKind(part)
    if not kind then return action end
    return deviceAction(action, character, part, kind, false, nil)
end
