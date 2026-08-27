-- ISAutoDriveDeviceAction.lua
-- 單一 generic TimedAction：kind＝nav|auto、install＝bool。
--
-- **本檔只負責工時、動畫與朝向，不做任何世界狀態突變——刻意不定義 complete()。**
--
-- 為什麼：B42 MP 的伺服器端跑的不是這個 Lua 物件，而是 NetTimedAction 鏡像，
-- 而鏡像是用 client 送來的 new() 參數逐一反序列化重建的——送出端依 new() 的參數名
-- 打包每個欄位（NetTimedAction.set，NetTimedAction.java:36-55），伺服器端 parse 再照樣
-- 呼叫 <Type>.new(...)（NetTimedAction.java:142-170）。也就是 character／vehicle／item
-- 全部由 client 指定。而鏡像的 perform() 唯一做的事就是呼叫 Lua 端的 complete()
-- （NetTimedAction.java:132-139）。把突變寫在 complete() 等於讓 client 自行宣告
-- 「誰、對哪台車、用哪件物品」。
--
-- 不定義 complete() 還會讓引擎連鏡像都不建：LuaTimedActionNew 建構時發現 metatable 沒有
-- complete 就設 useCustomRemoteTimedActionSync=true（LuaTimedActionNew.java:76-78），
-- 於是 start() 的 `GameClient.client && !useCustomRemoteTimedActionSync` 分支不成立，
-- 不會 createNetTimedAction（:128-132）——整條 client 可控的伺服器端執行路徑消失。
--
-- 代價與補償：沒有鏡像就沒有伺服器端的工時／拒絕仲裁，作弊 client 可以把 getDuration
-- 縮到 1 並連發。因此突變端（MDAD.applyDeviceChange）全部重新驗證，且 server handler
-- 另有 per-player 節流（server/MDAD_Server.lua）；最差結果只是「裝得比設計快」，
-- 不會產生物品或改到不該改的車。
--
-- 突變改走：perform() → sendClientCommand → server OnClientCommand → MDAD.applyDeviceChange。
-- Lua perform 在 client 與 SP 都會跑（LuaTimedActionNew.java:151-158），而鏡像不跑 perform，
-- 所以 MP 不會重複執行；SP（isClient()＝false）直接呼叫同一份 shared apply。

require "TimedActions/ISBaseTimedAction"
require "MDAD"

ISAutoDriveDeviceAction = ISBaseTimedAction:derive("ISAutoDriveDeviceAction")

local WORK_TIME = 150

-- clampDelta／giveItem 已移進 shared MDAD（突變段的一部分，只能在 server／SP 執行）

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
    if self.character and self.vehicle then
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
    end
    ISBaseTimedAction.perform(self)
end

function ISAutoDriveDeviceAction:getDuration()
    if self.character and self.character:isTimedActionInstant() then
        return 1
    end
    return WORK_TIME
end

function ISAutoDriveDeviceAction:new(character, vehicle, kind, install, item)
    local o = ISBaseTimedAction.new(self, character)
    o.vehicle = vehicle
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
