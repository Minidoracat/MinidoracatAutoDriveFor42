--[[
煙霧測試：用假的 PZ 全域載入**真正的** MOD Lua，跑行為情境並斷言結果。

    lua scripts/smoke_harness.lua        （repo 根目錄或 scripts/ 執行皆可；標準 Lua 5.x）

為什麼需要（兩類 luac -p 抓不到的錯誤，皆為正式服實際事故）：
- 改函式簽章漏改呼叫點：語法完全合法，要等該路徑真的執行才炸
- 邏輯回歸：安全把關（耗電倍率、同步門檻、失敗不丟物、伺服器端權威）被改壞時，
  「執行到並斷言」是唯一防線

本檔載入的 production（全部真檔，無任何 source-text 斷言）：
    shared/MDAD.lua
    shared/MDAD_Recipe.lua
    shared/TimedActions/ISAutoDriveDeviceAction.lua
    server/Items/MDAD_Distributions.lua
    server/MDAD_Server.lua
    client/MDAD_Client.lua

三條派送路徑都走真的程式碼，不再測早已不存在的 complete()：
- SP：TimedAction:perform() → MDAD.applyDeviceChange（同 process 直接突變）
- MP client：TimedAction:perform() → sendClientCommand（只送四個純量，本地不突變）
- MP server：Events.OnClientCommand → MDAD_Server → MDAD.applyDeviceChange
  （actor 取事件第三參數，不採 payload；vehicleId／itemId 一律重新解析）
單一 process 靠切換 isClient()／isServer() 假旗標模擬三種佈署。

限制（必須誠實面對）：這是標準 Lua，不是遊戲的 Kahlua。
- 標準 Lua 有 next/assert/xpcall，Kahlua 沒有——本 harness **測不出**誤用，
  那由 scripts/verify_mod.py 的靜態掃描負責（發版前兩者都要跑）。
  verify_mod.py 只掃 42/media 下的 lua，因此本檔可自由用標準函式庫
- 假全域是「形狀對齊」而非引擎實作。已知刻意簡化：
  * inventory 的 *Recurse 系列會走進 AddSubContainer 掛上的巢狀袋子，
    contains／containsID／getItemById 則只看本層（對齊引擎的非遞迴語意）
  * round() 對齊 PZ luautils 的 math.floor(num * mult + 0.5) / mult
  * canReachTo／isInArea／isSafehouseAllowInteract 只回旗標，不模擬牆與門；
    測的是 production 有沒有問對人、以及有沒有偷加距離 fallback
  * AutopilotModule 依 items_autodrive.txt 是 base:normal，因此假物件**故意不提供**
    setUsedDelta；production 若哪天誤呼叫，這裡會直接炸（等同 Kahlua 的
    「Object tried to call nil」）
- Kahlua 專屬行為（table.sort 遞迴深度、Java instance field 不暴露、每個 table 都是
  LinkedHashMap 的記憶體成本）只能靠反編譯查證與實機測試

寫情境的原則：
- 情境要「執行到會炸的路徑」——失敗收尾、跨 tick 的第二輪、快取第二次命中，都是重災區
- 安全邊界要有**反面**斷言（不該扣的電必須沒扣、不該丟的物品必須還在、
  client 說了不算的欄位必須真的不算），不是只測 happy path
- 效能不變式用計數器證明（draw 每幀掃背包＝正式服掉 FPS，只有計數器抓得到）
]]

-- 家族佈局固定，直接填死最省事
local MEDIA = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua"
-- 允許從 repo 根目錄或 scripts/ 執行
local ROOTS = { "", "../" }

-- =====================================================================
-- 假的 PZ 全域（依 MOD 實際用到的 API 增補，多一個都不加）
-- =====================================================================

-- 起始時間要夠大：navGate 的 draw 快取與 server 節流都寫成 now - last < TTL，
-- 從 0 起跳會讓行為失真
local nowMs = 5000000
local clientFlag = false
local serverFlag = true
local instanceItemEnabled = true

function getTimestampMs() return nowMs end
function isClient() return clientFlag end
function isServer() return serverFlag end
function getText(key) return key end

-- PZ luautils 的 round
function round(num, idp)
    local mult = 10 ^ (idp or 0)
    return math.floor(num * mult + 0.5) / mult
end

ItemTag = { SCREWDRIVER = "SCREWDRIVER" }
Perks = { Electricity = "Electricity" }
Metabolics = { MediumWork = "MediumWork" }

-- 觀測計數器：用來證明「沒有做不該做的事」
local stats = {
    setUsedDelta = 0,        -- 寫入電量的次數（雙扣／重複寫的唯一證據）
    transmitUsedDelta = 0,   -- 車電同步（chargeChanged 門檻）
    transmitModData = 0,     -- part modData 同步
    sendItemStats = 0,       -- 隨身物品同步
    sendAddItem = 0,
    sendRemoveItem = 0,
    addWorldItem = 0,        -- 掉地上
    scanType = 0,            -- getFirstTypeRecurse
    scanTypeEval = 0,        -- getFirstTypeEvalRecurse（findChargedPortableGPS 專用）
    scanTagEval = 0,         -- getFirstTagEvalRecurse（findScrewdriver 專用）
    itemById = 0,            -- getItemWithIDRecursiv（server 端重解析物品）
    instanceItem = 0,
    getVehicleById = 0,      -- server 端重解析載具
    canReachTo = 0,          -- IsoGridSquare.canReachTo
    isInArea = 0,            -- BaseVehicle.isInArea
    safehouseCheck = 0,      -- SafeHouse.isSafehouseAllowInteract
    pickVehicle = 0,         -- IsoObjectPicker:PickVehicle
}

-- 距離判定的絆線：production 已改成 area／相鄰格判準，整份測試跑完都不該碰它。
-- 刻意**不**放進 stats（resetStats 會歸零），才能在收尾一次證明全程沒被呼叫。
local distCalls = 0

-- 網路與 UI 的觀測佇列
local sentClient = {}    -- sendClientCommand（client → server）
local sentServer = {}    -- sendServerCommand（server → client）
local halos = {}         -- HaloTextHelper.addBadText
local uiCalls = { exit = {}, toInventory = {}, equip = {}, queue = {} }

local function clearList(t)
    for i = #t, 1, -1 do t[i] = nil end
end

local function resetStats()
    for k in pairs(stats) do stats[k] = 0 end
    clearList(sentClient)
    clearList(sentServer)
    clearList(halos)
    clearList(uiCalls.exit)
    clearList(uiCalls.toInventory)
    clearList(uiCalls.equip)
    clearList(uiCalls.queue)
end

function sendItemStats(_) stats.sendItemStats = stats.sendItemStats + 1 end
function sendAddItemToContainer(_, _) stats.sendAddItem = stats.sendAddItem + 1 end
function sendRemoveItemFromContainer(_, _) stats.sendRemoveItem = stats.sendRemoveItem + 1 end
function getPlayerData(_) return nil end

-- sendClientCommand(player, module, command, args)＝LuaManager.java:8912
function sendClientCommand(player, module, command, args)
    sentClient[#sentClient + 1] =
        { player = player, module = module, command = command, args = args }
end

-- sendServerCommand(player, module, command, args)＝LuaManager.java:8942
function sendServerCommand(player, module, command, args)
    sentServer[#sentServer + 1] =
        { player = player, module = module, command = command, args = args }
end

HaloTextHelper = {
    addBadText = function(playerObj, text)
        halos[#halos + 1] = { player = playerObj, text = text }
    end,
}

-- SafeHouse.isSafehouseAllowInteract(square, player)＝SafeHouse.java:245
local safehouseAllow = true
local lastSafehouse = {}
SafeHouse = {
    isSafehouseAllowInteract = function(square, player)
        stats.safehouseCheck = stats.safehouseCheck + 1
        lastSafehouse.square = square
        lastSafehouse.player = player
        return safehouseAllow
    end,
}

ISTransferAction = {
    GetDropItemOffset = function(_, _, _) return 0.5, 0.5, 0 end,
}

-- client 端 UI／排程門面：只記錄呼叫，讓情境能斷言「排了什麼、帶了什麼參數」
ISWorldObjectContextMenu = {
    addToolTip = function() return {} end,
    equip = function(playerObj, current, item, primary, secondary)
        uiCalls.equip[#uiCalls.equip + 1] = {
            player = playerObj, current = current, item = item,
            primary = primary, secondary = secondary,
        }
    end,
}

ISVehicleMenu = {
    onExit = function(playerObj) uiCalls.exit[#uiCalls.exit + 1] = playerObj end,
}

ISVehiclePartMenu = {
    toPlayerInventory = function(playerObj, item)
        uiCalls.toInventory[#uiCalls.toInventory + 1] = { player = playerObj, item = item }
    end,
}

ISPathFindAction = {
    pathToVehicleArea = function(_, playerObj, vehicle, area)
        return { _kind = "pathToVehicleArea", character = playerObj, vehicle = vehicle, area = area }
    end,
}

ISTimedActionQueue = {
    add = function(action) uiCalls.queue[#uiCalls.queue + 1] = action end,
}

JoypadState = { players = {} }

local pickedVehicle = nil
IsoObjectPicker = {
    Instance = {
        PickVehicle = function(_, _, _)
            stats.pickVehicle = stats.pickVehicle + 1
            return pickedVehicle
        end,
    },
}

function getMouseXScaled() return 0 end
function getMouseYScaled() return 0 end

-- ISBaseObject/ISBaseTimedAction 的 derive/new 語意：實例的 metatable 是子類，
-- 子類的 metatable 是父類，方法沿鏈往上找
ISBaseTimedAction = {}

function ISBaseTimedAction:derive(name)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.Type = name
    return o
end

function ISBaseTimedAction:new(character)
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o.character = character
    o.maxTime = -1
    o.jobDelta = 0
    o.stopped = false
    o.performed = false
    return o
end

function ISBaseTimedAction:getJobDelta() return self.jobDelta or 0 end
function ISBaseTimedAction:setActionAnim(anim) self.actionAnim = anim end
function ISBaseTimedAction:stop() self.stopped = true end
function ISBaseTimedAction:perform() self.performed = true end

-- 事件註冊表：MDAD_Distributions 掛 OnPostDistributionMerge、MDAD_Server 掛
-- OnClientCommand、MDAD_Client 掛 OnGameStart／OnCreatePlayer／
-- OnFillWorldObjectContextMenu／OnServerCommand，全靠 fire() 觸發
local eventHandlers = {}
Events = setmetatable({}, {
    __index = function(_, name)
        return {
            Add = function(fn)
                local list = eventHandlers[name]
                if not list then
                    list = {}
                    eventHandlers[name] = list
                end
                list[#list + 1] = fn
            end,
            Remove = function(fn)
                local list = eventHandlers[name] or {}
                for i = #list, 1, -1 do
                    if list[i] == fn then table.remove(list, i) end
                end
            end,
        }
    end,
})

local function fire(name, ...)
    for _, fn in ipairs(eventHandlers[name] or {}) do fn(...) end
end

-- 沙盒：setSandbox(nil) 代表主選單／載入中（SandboxVars 還不存在）
local function setSandbox(t)
    if t == nil then
        SandboxVars = nil
    else
        SandboxVars = { MinidoracatAutoDrive = t }
    end
end

-- 本機玩家 slot（getSpecificPlayer／getNumActivePlayers）
local players = {}
local activePlayers = 0
function getSpecificPlayer(n) return players[n] end
function getNumActivePlayers() return activePlayers end

-- 載入期／事件期的 print 是玩家唯一看得到的診斷，攔下來才能斷言
local realPrint = print
local function capturePrint(fn)
    local out = {}
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        out[#out + 1] = table.concat(parts, "\t")
    end
    local ok, err = pcall(fn)
    print = realPrint
    if not ok then error(err, 0) end
    return out
end

local function logHas(log, needle)
    for i = 1, #log do
        if log[i]:find(needle, 1, true) then return true end
    end
    return false
end

-- =====================================================================
-- 假世界建構子
-- =====================================================================

local nextItemId = 1

-- opts: uses（nil＝非 drainable，不提供 getCurrentUsesFloat/setUsedDelta）、
--       useDelta（nil＝不提供 getUseDelta）、broken、tags
local function newItem(fullType, opts)
    opts = opts or {}
    local it = {
        _id = nextItemId,
        _fullType = fullType,
        _uses = opts.uses,
        _useDelta = opts.useDelta,
        _broken = opts.broken == true,
        _tags = opts.tags or {},
        _container = nil,
        jobDelta = nil,
        jobType = nil,
    }
    nextItemId = nextItemId + 1

    function it:getID() return self._id end
    function it:getFullType() return self._fullType end
    function it:isBroken() return self._broken end
    function it:hasTag(tag) return self._tags[tag] == true end
    function it:getContainer() return self._container end
    function it:setJobDelta(v) self.jobDelta = v end
    function it:setJobType(v) self.jobType = v end

    if opts.uses ~= nil then
        function it:getCurrentUsesFloat() return self._uses end
        function it:setUsedDelta(v)
            self._uses = v
            stats.setUsedDelta = stats.setUsedDelta + 1
        end
    end
    if opts.useDelta ~= nil then
        function it:getUseDelta() return self._useDelta end
    end
    return it
end

local GPS_T = "MinidoracatAutoDrive.GPSNavigator"
local AUTO_T = "MinidoracatAutoDrive.AutopilotModule"

function instanceItem(fullType)
    if not instanceItemEnabled then return nil end
    stats.instanceItem = stats.instanceItem + 1
    if fullType == GPS_T then
        -- base:drainable，新品滿電；production 會 setUsedDelta 覆寫
        return newItem(fullType, { uses = 1.0, useDelta = 0.006 })
    end
    -- AutopilotModule 是 base:normal：刻意不給 uses／setUsedDelta
    return newItem(fullType)
end

local function indexOf(list, item)
    for i = 1, #list do
        if list[i] == item then return i end
    end
    return nil
end

-- *Recurse 走進巢狀袋子；contains/containsID/getItemById 只看本層（對齊引擎）
local function walkRecurse(inv, fn)
    for i = 1, #inv._items do
        local hit = fn(inv._items[i])
        if hit then return hit end
    end
    for i = 1, #inv._subs do
        local hit = walkRecurse(inv._subs[i], fn)
        if hit then return hit end
    end
    return nil
end

local newInventory
newInventory = function()
    local inv = { _items = {}, _roomFor = true, _subs = {} }

    function inv:AddItem(item)
        self._items[#self._items + 1] = item
        item._container = self
        return item
    end

    -- 背包裡的袋子：AddItem 進去的物品 getContainer() 會回這個子容器，
    -- 不是主背包——server 端要用 item:getContainer() 移除才會正確
    function inv:AddSubContainer()
        local sub = newInventory()
        self._subs[#self._subs + 1] = sub
        return sub
    end

    function inv:contains(item)
        return indexOf(self._items, item) ~= nil
    end

    function inv:containsID(id)
        for i = 1, #self._items do
            if self._items[i]:getID() == id then return true end
        end
        return false
    end

    function inv:getItemById(id)
        for i = 1, #self._items do
            if self._items[i]:getID() == id then return self._items[i] end
        end
        return nil
    end

    function inv:DoRemoveItem(item)
        local i = indexOf(self._items, item)
        if i then
            table.remove(self._items, i)
            item._container = nil
        end
    end

    function inv:hasRoomFor(_, _) return self._roomFor ~= false end

    function inv:getFirstTypeRecurse(fullType)
        stats.scanType = stats.scanType + 1
        return walkRecurse(self, function(x)
            if x:getFullType() == fullType then return x end
        end)
    end

    function inv:getFirstTypeEvalRecurse(fullType, pred)
        stats.scanTypeEval = stats.scanTypeEval + 1
        return walkRecurse(self, function(x)
            if x:getFullType() == fullType and pred(x) then return x end
        end)
    end

    function inv:getFirstTagEvalRecurse(tag, pred)
        stats.scanTagEval = stats.scanTagEval + 1
        return walkRecurse(self, function(x)
            if x:hasTag(tag) and pred(x) then return x end
        end)
    end

    -- ItemContainer.getItemWithIDRecursiv＝ItemContainer.java:3065
    function inv:getItemWithIDRecursiv(id)
        stats.itemById = stats.itemById + 1
        return walkRecurse(self, function(x)
            if x:getID() == id then return x end
        end)
    end

    return inv
end

local function newSquare()
    local sq = { _canReach = true }
    function sq:AddWorldInventoryItem(item, x, y, z)
        stats.addWorldItem = stats.addWorldItem + 1
        self._dropped = item
        self._dropAt = { x, y, z }
        return item
    end
    -- IsoGridSquare.canReachTo＝IsoGridSquare.java:841
    function sq:canReachTo(other)
        stats.canReachTo = stats.canReachTo + 1
        self._reachArg = other
        return self._canReach
    end
    return sq
end

-- opts: num、electricity、z、instant、username
local function newPlayer(opts)
    opts = opts or {}
    local p = {
        _inv = newInventory(),
        _perk = opts.electricity or 0,
        _vehicle = nil,
        _z = opts.z or 0,
        _square = newSquare(),
        _num = opts.num or 0,
        _instant = opts.instant == true,
        _username = opts.username or ("player" .. tostring(opts.num or 0)),
        _dead = false,
        _useable = nil,
        _near = nil,
        _hand = nil,
        removedFromHands = 0,
        faced = 0,
    }
    function p:getInventory() return self._inv end
    function p:getPerkLevel(perk)
        if perk == Perks.Electricity then return self._perk end
        return 0
    end
    function p:getVehicle() return self._vehicle end
    function p:getZ() return self._z end
    -- 絆線：canReachVehicle 已不准用距離判定，被呼叫就會在收尾被抓出來
    function p:DistToSquared(_)
        distCalls = distCalls + 1
        return 0
    end
    function p:removeFromHands(_) self.removedFromHands = self.removedFromHands + 1 end
    function p:getCurrentSquare() return self._square end
    function p:getPlayerNum() return self._num end
    function p:getUsername() return self._username end
    function p:isDead() return self._dead end
    function p:isTimedActionInstant() return self._instant == true end
    function p:faceThisObject(_) self.faced = self.faced + 1 end
    function p:shouldBeTurning() return false end
    function p:setMetabolicTarget(_) end
    function p:getUseableVehicle() return self._useable end
    function p:getNearVehicle() return self._near end
    function p:getPrimaryHandItem() return self._hand end
    return p
end

local function newBatteryPart(battery, area)
    local part = { _md = {}, _item = battery, _area = area }
    function part:getModData() return self._md end
    function part:getInventoryItem() return self._item end
    function part:getArea() return self._area end
    return part
end

-- getVehicleById 的登記簿：server 端只認 id，不收 client 送來的物件
local nextVehicleId = 1
local vehiclesById = {}

function getVehicleById(id)
    stats.getVehicleById = stats.getVehicleById + 1
    return vehiclesById[id]
end

-- opts: battery、noBattery、area、inArea、z、engineRunning
local function newVehicle(opts)
    opts = opts or {}
    local v = {
        _id = nextVehicleId,
        _part = (not opts.noBattery) and newBatteryPart(opts.battery, opts.area) or nil,
        _z = opts.z or 0,
        _engine = opts.engineRunning == true,
        _inArea = opts.inArea == true,
        _square = newSquare(),
    }
    nextVehicleId = nextVehicleId + 1
    vehiclesById[v._id] = v

    function v:getId() return self._id end
    function v:getSquare() return self._square end
    function v:getBattery() return self._part end
    function v:getBatteryCharge()
        local bat = self._part and self._part._item
        if not bat or bat.getCurrentUsesFloat == nil then return 0 end
        return bat:getCurrentUsesFloat()
    end
    function v:isEngineRunning() return self._engine end
    function v:getZ() return self._z end
    -- BaseVehicle.isInArea(areaId, chr)＝BaseVehicle.java:8225
    function v:isInArea(area, chr)
        stats.isInArea = stats.isInArea + 1
        self._areaArg = area
        self._chrArg = chr
        return self._inArea
    end
    function v:transmitPartUsedDelta(_) stats.transmitUsedDelta = stats.transmitUsedDelta + 1 end
    function v:transmitPartModData(_) stats.transmitModData = stats.transmitModData + 1 end
    return v
end

-- =====================================================================
-- 載入受測程式碼
-- =====================================================================

local DIRS = { "shared", "shared/TimedActions", "server", "server/Items", "client" }
-- 原版檔案不在 MOD 樹內，用上面的假物件頂替
local loaded = {
    ["TimedActions/ISBaseTimedAction"] = true,
    ["ISBaseObject"] = true,
    ["luautils"] = true,
}

-- loadfile 對「檔案不存在」和「語法錯誤」都回 nil，直接吞掉會把 production 的語法錯
-- 誤報成「找不到」。先用 io.open 確認檔案在，再讓 loadfile 的錯誤訊息原樣浮上來。
function require(name)
    if loaded[name] then return true end
    for _, root in ipairs(ROOTS) do
        for _, dir in ipairs(DIRS) do
            local path = root .. MEDIA .. "/" .. dir .. "/" .. name .. ".lua"
            local fh = io.open(path, "r")
            if fh then
                fh:close()
                local chunk, err = loadfile(path)
                if not chunk then
                    error("載入失敗 " .. path .. "：" .. tostring(err))
                end
                loaded[name] = true
                chunk()
                return true
            end
        end
    end
    error("require 找不到: " .. name .. "（請從 repo 根目錄或 scripts/ 執行）")
end

require "MDAD"
require "MDAD_Recipe"
require "TimedActions/ISAutoDriveDeviceAction"
require "MDAD_Distributions"
-- MDAD_Server 開頭是 `if isClient() then return end`：要在 clientFlag=false 時載入
require "MDAD_Server"
-- MDAD_Client 在載入期就會呼叫一次 registerNavGate()。此時 MinidoracatMiniMapAPI
-- 刻意不存在，好讓「主 MOD 未安裝」這條路徑真的被走到；診斷訊息留給情境去斷言。
local clientLoadLog = capturePrint(function() require "MDAD_Client" end)

-- =====================================================================
-- 測試工具
-- =====================================================================

local failures, assertions, scenarios = 0, 0, 0
local scenarioBase, scenarioFails, scenarioTitle = 0, 0, nil

local function show(v)
    if type(v) == "string" then return '"' .. v .. '"' end
    return tostring(v)
end

local function check(ok, label)
    assertions = assertions + 1
    if not ok then
        failures = failures + 1
        scenarioFails = scenarioFails + 1
        print("        [FAIL] " .. label)
    end
    return ok
end

local function checkTrue(v, label) return check(v == true, label .. "（實得 " .. show(v) .. "）") end
local function checkFalse(v, label) return check(v == false, label .. "（實得 " .. show(v) .. "）") end
local function checkNil(v, label) return check(v == nil, label .. "（實得 " .. show(v) .. "）") end

local function checkEq(actual, expected, label)
    return check(actual == expected,
        label .. "（期望 " .. show(expected) .. "、實得 " .. show(actual) .. "）")
end

local function checkNear(actual, expected, eps, label)
    local ok = type(actual) == "number" and math.abs(actual - expected) <= eps
    return check(ok, label .. "（期望 ~" .. show(expected) .. "、實得 " .. show(actual) .. "）")
end

local function closeScenario()
    if not scenarioTitle then return end
    if scenarioFails == 0 then
        print("        " .. (assertions - scenarioBase) .. " 項斷言全部通過")
    else
        print("        " .. scenarioFails .. " / " .. (assertions - scenarioBase) .. " 項失敗")
    end
end

local function scenario(title)
    closeScenario()
    scenarios = scenarios + 1
    scenarioBase = assertions
    scenarioFails = 0
    scenarioTitle = title
    print("情境" .. scenarios .. "：" .. title)
end

-- 收集所有真的被 production 吐出來的理由鍵；最後一個情境驗證每個鍵都有翻譯
local reasonKeys = {}
local function noteReason(key)
    if type(key) == "string" then reasonKeys[key] = true end
    return key
end

local function gate(playerNum, context)
    local allowed, reason = MDAD.navGate(playerNum, context)
    noteReason(reason)
    return allowed, reason
end

local function blockReason(player, vehicle, kind, install)
    return noteReason(MDAD.deviceBlockReason(player, vehicle, kind, install))
end

local NEED_GPS = "UI_MinidoracatAutoDrive_NeedGPS"
local FAILED = "UI_MinidoracatAutoDrive_InstallFailed"
local NO_BATTERY = "UI_MinidoracatAutoDrive_NoBattery"
local NO_TOOL = "UI_MinidoracatAutoDrive_NoScrewdriver"
local NEED_SKILL = "UI_MinidoracatAutoDrive_NeedElectricity1"
local ALREADY = "UI_MinidoracatAutoDrive_AlreadyInstalled"
local TOO_FAR = "UI_MinidoracatAutoDrive_TooFar"
local NAV_API_MISSING = "UI_MinidoracatAutoDrive_NavApiMissing"
local MOD_ID = "MinidoracatAutoDriveFor42"
local EPS = 1e-9

local function newScrewdriver(broken)
    return newItem("Base.Screwdriver", { tags = { SCREWDRIVER = true }, broken = broken })
end

-- =====================================================================
-- 情境一：配方沙盒閘門（MDAD_Recipe，引擎的 OnTest 回呼）
-- =====================================================================
scenario("配方沙盒閘門：沙盒未載入／鍵不存在／true／false")

-- 引擎以 (item, character) 呼叫 OnTest，production 忽略參數——照原樣傳進去
local probeItem = newItem("Base.ElectronicsScrap")
local probeChar = newPlayer()

setSandbox(nil)
checkTrue(MDAD_Recipe.canCraftGPS(probeItem, probeChar), "沙盒未載入時 GPS 配方放行（主選單不得誤鎖）")
checkTrue(MDAD_Recipe.canCraftAutopilot(probeItem, probeChar), "沙盒未載入時自駕配方放行")

setSandbox({})
checkTrue(MDAD_Recipe.canCraftGPS(), "沙盒在但鍵不存在時 GPS 配方放行")
checkTrue(MDAD_Recipe.canCraftAutopilot(), "沙盒在但鍵不存在時自駕配方放行")

setSandbox({ AllowCraftGPS = true, AllowCraftAutopilot = true })
checkTrue(MDAD_Recipe.canCraftGPS(), "AllowCraftGPS=true 放行")
checkTrue(MDAD_Recipe.canCraftAutopilot(), "AllowCraftAutopilot=true 放行")

setSandbox({ AllowCraftGPS = false, AllowCraftAutopilot = true })
checkFalse(MDAD_Recipe.canCraftGPS(), "AllowCraftGPS=false 擋住 GPS 配方")
checkTrue(MDAD_Recipe.canCraftAutopilot(), "擋 GPS 不影響自駕配方（沙盒鍵沒接錯）")

setSandbox({ AllowCraftGPS = true, AllowCraftAutopilot = false })
checkFalse(MDAD_Recipe.canCraftAutopilot(), "AllowCraftAutopilot=false 擋住自駕配方")
checkTrue(MDAD_Recipe.canCraftGPS(), "擋自駕不影響 GPS 配方")

-- 非 boolean 的殘留值（舊版沙盒升級）：只有 true 才放行
setSandbox({ AllowCraftGPS = 1, AllowCraftAutopilot = "true" })
checkFalse(MDAD_Recipe.canCraftGPS(), "數值 1 不等於 true：擋住")
checkFalse(MDAD_Recipe.canCraftAutopilot(), "字串 \"true\" 不等於 true：擋住")

-- =====================================================================
-- 情境二：戰利品注入（MDAD_Distributions，OnPostDistributionMerge）
-- =====================================================================
scenario("戰利品注入：連跑三次不重複、權重不疊、items 成對、缺表不炸")

local DIST_NAMES = {
    "ArmyStorageElectronics", "ElectronicStoreMisc", "EngineerTools", "CrateElectronics",
    "RadioFactoryComponents", "ElectronicStoreComputers", "CrateRandomJunk",
}
local BASE_ENTRY = {
    ArmyStorageElectronics = { "Base.ElectronicsScrap", 10 },
    ElectronicStoreMisc = { "Base.ElectronicsScrap", 8 },
    EngineerTools = { "Base.Screwdriver", 6 },
    CrateElectronics = { "Base.ElectricWire", 4 },
    RadioFactoryComponents = { "Base.ElectronicsScrap", 12 },
    ElectronicStoreComputers = { "Base.ElectronicsScrap", 5 },
    CrateRandomJunk = { "Base.Plank", 3 },
}
local EXPECT_GPS = {
    ArmyStorageElectronics = 2, ElectronicStoreMisc = 2, EngineerTools = 1, CrateElectronics = 1,
}
local EXPECT_AUTO = {
    ArmyStorageElectronics = 0.5, RadioFactoryComponents = 0.5, ElectronicStoreComputers = 0.2,
}

local function countIn(items, fullType)
    local n, weight = 0, nil
    for i = 1, #items - 1, 2 do
        if items[i] == fullType then
            n = n + 1
            weight = items[i + 1]
        end
    end
    return n, weight
end

ProceduralDistributions = { list = {} }
for _, name in ipairs(DIST_NAMES) do
    local e = BASE_ENTRY[name]
    ProceduralDistributions.list[name] = { items = { e[1], e[2] } }
end

fire("OnPostDistributionMerge")

local sizeAfterFirst = {}
for _, name in ipairs(DIST_NAMES) do
    sizeAfterFirst[name] = #ProceduralDistributions.list[name].items
end

-- 同一行程回主選單再讀檔＝事件再觸發；ProceduralDistributions 是不重置的 Lua 全域表
fire("OnPostDistributionMerge")
fire("OnPostDistributionMerge")

for _, name in ipairs(DIST_NAMES) do
    local items = ProceduralDistributions.list[name].items
    checkEq(#items, sizeAfterFirst[name], name .. "：連跑三次長度不變（沒有重複注入）")
    checkEq(#items % 2, 0, name .. "：items 一定成對（type, weight）")

    local nGps, wGps = countIn(items, GPS_T)
    local nAuto, wAuto = countIn(items, AUTO_T)
    checkEq(nGps, EXPECT_GPS[name] and 1 or 0, name .. "：GPS 出現次數")
    checkEq(nAuto, EXPECT_AUTO[name] and 1 or 0, name .. "：自駕模組出現次數")
    if EXPECT_GPS[name] then
        checkEq(wGps, EXPECT_GPS[name], name .. "：GPS 權重沒有被疊加")
    end
    if EXPECT_AUTO[name] then
        checkEq(wAuto, EXPECT_AUTO[name], name .. "：自駕模組權重沒有被疊加")
    end
    checkEq(items[1], BASE_ENTRY[name][1], name .. "：原版既有條目沒被動到")
    checkEq(items[2], BASE_ENTRY[name][2], name .. "：原版既有權重沒被改")
end

checkEq(#ProceduralDistributions.list.CrateRandomJunk.items, 2, "不在目標清單的表完全沒被碰")
checkEq(#ProceduralDistributions.list.ArmyStorageElectronics.items, 6,
    "同時是兩種道具目標的表補了兩組 pair")
checkEq(#ProceduralDistributions.list.EngineerTools.items, 4, "單一道具目標只補一組 pair")

-- 原版改名／移除某張表時必須靜靜跳過，不能整包炸
ProceduralDistributions.list.EngineerTools = nil
checkTrue(pcall(fire, "OnPostDistributionMerge"), "目標表不存在時不丟錯（原版改名不炸 MOD）")
checkEq(#ProceduralDistributions.list.CrateElectronics.items, 4, "缺表不影響其他表")

-- 目標表存在但沒有 items 欄位（原版改結構）
ProceduralDistributions.list.CrateElectronics = {}
checkTrue(pcall(fire, "OnPostDistributionMerge"), "目標表沒有 items 欄位時不丟錯")
checkNil(ProceduralDistributions.list.CrateElectronics.items, "不會替原版無 items 的表憑空造 items")

-- 事件在 ProceduralDistributions 還沒建立時被觸發（載入順序意外）
ProceduralDistributions = nil
checkTrue(pcall(fire, "OnPostDistributionMerge"), "ProceduralDistributions 為 nil 時安全早退")
ProceduralDistributions = {}
checkTrue(pcall(fire, "OnPostDistributionMerge"), "ProceduralDistributions.list 為 nil 時安全早退")

-- =====================================================================
-- 情境三：navGate（MiniMap nav API 的閘門；draw 是每幀熱路徑）
-- =====================================================================
scenario("navGate：選項關閉／帶電隨身 GPS／draw 1 秒快取／車上已裝＋車電有電")

local pBasic = newPlayer({ num = 0 })
players[0] = pBasic

setSandbox({ NeedItemForNav = false })
resetStats()
local ok, reason = gate(0, "draw")
checkTrue(ok, "NeedItemForNav=false：放行")
checkNil(reason, "放行時不帶理由")
checkEq(stats.scanTypeEval, 0, "選項關閉時完全不掃背包（O(1) 早退）")

setSandbox({})
ok, reason = gate(0)
checkTrue(ok, "沙盒鍵不存在時預設放行（預設值 false）")
checkNil(reason, "預設放行不帶理由")

setSandbox(nil)
checkTrue(gate(0), "沙盒未載入（主選單）時放行")

setSandbox({ NeedItemForNav = true })
players[7] = nil
ok, reason = gate(7)
checkTrue(ok, "玩家還沒生成時 fail-open 放行")
checkNil(reason, "fail-open 不帶理由")

-- 帶電隨身 GPS
resetStats()
local heldGps = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
pBasic:getInventory():AddItem(heldGps)
ok, reason = gate(0)
checkTrue(ok, "帶電隨身 GPS 放行")
checkNil(reason, "放行不帶理由")
checkEq(stats.scanTypeEval, 1, "非 draw 情境掃一次背包")

heldGps._uses = 0
ok, reason = gate(0)
checkFalse(ok, "沒電的隨身 GPS 不放行（predicate 是 > 0，不是 >= 0）")
checkEq(reason, NEED_GPS, "拒絕時一定回傳理由鍵")

heldGps._uses = 0.0001
checkTrue(gate(0), "只剩一絲電也算帶電（> 0 的下邊界）")

pBasic:getInventory():DoRemoveItem(heldGps)
ok, reason = gate(0)
checkFalse(ok, "完全沒 GPS 不放行")
checkEq(reason, NEED_GPS, "沒 GPS 的理由鍵")

resetStats()
gate(0); gate(0); gate(0)
checkEq(stats.scanTypeEval, 3, "非 draw 情境不吃快取（選單類要即時判定）")

-- draw 快取：1 秒 TTL，禁止每幀掃背包
local pDraw = newPlayer({ num = 1 })
players[1] = pDraw
nowMs = 8000000
resetStats()
ok, reason = gate(1, "draw")
checkFalse(ok, "draw 首次判定：沒 GPS 拒絕")
checkEq(reason, NEED_GPS, "draw 拒絕也帶理由鍵")
checkEq(stats.scanTypeEval, 1, "draw 首次掃一次背包")

for _ = 1, 60 do gate(1, "draw") end
checkEq(stats.scanTypeEval, 1, "同一幀連跑 60 次仍只掃一次（禁止每幀掃背包）")

-- 快取未過期就把 GPS 塞進背包：結論必須沿用舊值——這才證明快取真的生效
pDraw:getInventory():AddItem(newItem(GPS_T, { uses = 1.0, useDelta = 0.006 }))
nowMs = nowMs + 999
ok, reason = gate(1, "draw")
checkFalse(ok, "999ms 內沿用上一輪結論（快取確實命中）")
checkEq(reason, NEED_GPS, "快取命中時理由鍵不遺失")
checkEq(stats.scanTypeEval, 1, "999ms 內不重掃")

nowMs = nowMs + 1
ok, reason = gate(1, "draw")
checkTrue(ok, "距上次滿 1000ms 後重掃並改判放行")
checkNil(reason, "重掃放行不帶理由")
checkEq(stats.scanTypeEval, 2, "TTL 到期只重掃一次")

for _ = 1, 30 do gate(1, "draw") end
checkEq(stats.scanTypeEval, 2, "放行結論也進快取（不是只快取拒絕）")

-- 快取要 per-player：另一位玩家不得沿用別人的結論
local pDraw2 = newPlayer({ num = 2 })
players[2] = pDraw2
resetStats()
checkFalse(gate(2, "draw"), "另一位玩家沒 GPS：不得沿用他人快取")
checkEq(stats.scanTypeEval, 1, "新玩家自己掃一次")
checkTrue(gate(1, "draw"), "原玩家的放行快取沒被覆寫")
checkEq(stats.scanTypeEval, 1, "原玩家仍走快取")

-- 隨身 GPS 塞在背包裡的袋子：*Recurse 必須找得到（不是只看主層）
local pBag = newPlayer({ num = 6 })
players[6] = pBag
local bag = pBag:getInventory():AddSubContainer()
bag:AddItem(newItem(GPS_T, { uses = 0.4, useDelta = 0.006 }))
checkTrue(gate(6), "GPS 放在背包裡的袋子也算帶著（走遞迴搜尋 API）")

-- 車上已裝 nav＋車電有電：O(1) 短路，不進背包也不進快取
local vehBat = newItem("Base.CarBattery", { uses = 0.5 })
local navVeh = newVehicle({ battery = vehBat })
local navSt = MDAD.ensureState(navVeh:getBattery())
navSt.nav = true
local pInCar = newPlayer({ num = 3 })
pInCar._vehicle = navVeh
players[3] = pInCar

checkTrue(MDAD.isNavInstalled(navVeh), "isNavInstalled 讀得到 part modData 狀態")
checkFalse(MDAD.isAutoInstalled(navVeh), "只裝 nav 時 isAutoInstalled 為 false")
checkTrue(MDAD.isBatteryLive(navVeh), "車電有電：isBatteryLive")
checkFalse(MDAD.isBatteryLive(newVehicle({ noBattery = true })), "無電瓶 part：isBatteryLive 為 false")
checkFalse(MDAD.isBatteryLive(nil), "無車輛：isBatteryLive 為 false")

resetStats()
ok, reason = gate(3)
checkTrue(ok, "車上已裝 nav 且車電有電：放行")
checkNil(reason, "車電路徑放行不帶理由")
checkEq(stats.scanTypeEval, 0, "車電路徑完全不掃背包")

checkTrue(gate(3, "draw"), "draw 情境同樣走車電短路")
checkEq(stats.scanTypeEval, 0, "車電短路發生在快取判斷之前")

vehBat._uses = 0
ok, reason = gate(3)
checkFalse(ok, "車電耗盡後改判拒絕（不是裝了就永久放行）")
checkEq(reason, NEED_GPS, "車電耗盡的理由鍵")
checkEq(stats.scanTypeEval, 1, "車電耗盡才回退掃背包")

vehBat._uses = 1.0
navSt.nav = false
resetStats()
ok, reason = gate(3)
checkFalse(ok, "只有車電、沒裝 nav：不放行")
checkEq(reason, NEED_GPS, "未安裝時的理由鍵")
checkEq(stats.scanTypeEval, 1, "沒裝 nav 就得回退掃背包")

navSt.nav = true
navVeh._part._item = nil
checkFalse(gate(3), "已裝 nav 但電瓶槽空了：不放行")
navVeh._part._item = newItem("Base.Plank")
checkFalse(gate(3), "電瓶槽塞非 drainable 物品：不放行（不呼叫不存在的方法）")

-- =====================================================================
-- 情境四：deviceBlockReason ＋ 隨身道具查詢
-- =====================================================================
scenario("安裝阻擋原因：無電瓶／無工具／技能不足／已安裝，與隨身道具查詢")

setSandbox({ InstallSkillGate = true })
local pOk = newPlayer({ num = 4, electricity = 1 })
pOk:getInventory():AddItem(newScrewdriver(false))
local vOk = newVehicle({ battery = newItem("Base.CarBattery", { uses = 0.6 }) })

resetStats()
checkNil(blockReason(pOk, vOk, "nav", true), "備齊工具與技能：安裝 nav 不被擋")
checkNil(blockReason(pOk, vOk, "auto", true), "備齊工具與技能：安裝 auto 不被擋")
checkTrue(MDAD.findScrewdriver(pOk) ~= nil, "findScrewdriver 找得到未損壞螺絲刀")
checkTrue(stats.scanTagEval > 0, "findScrewdriver 真的走了 tag 搜尋 API")
checkNil(MDAD.findScrewdriver(nil), "無玩家：findScrewdriver 為 nil")

checkEq(blockReason(nil, vOk, "nav", true), FAILED, "無玩家")
checkEq(blockReason(pOk, nil, "nav", true), FAILED, "無車輛")
checkEq(blockReason(pOk, vOk, "turbo", true), FAILED, "未知 kind")
checkEq(blockReason(pOk, vOk, nil, true), FAILED, "kind 為 nil")

local bike = newVehicle({ noBattery = true })
checkEq(blockReason(pOk, bike, "nav", true), NO_BATTERY, "腳踏車／拖車沒有電瓶 part")
checkEq(blockReason(pOk, bike, "nav", false), NO_BATTERY, "無電瓶時卸載也擋在同一關")
checkNil(MDAD.getBatteryPart(bike), "getBatteryPart 對無電瓶車輛回 nil")
checkNil(MDAD.getBatteryPart(nil), "getBatteryPart 對 nil 車輛回 nil")

local pNoTool = newPlayer({ electricity = 1 })
checkEq(blockReason(pNoTool, vOk, "nav", true), NO_TOOL, "沒螺絲刀")
local pBadTool = newPlayer({ electricity = 1 })
pBadTool:getInventory():AddItem(newScrewdriver(true))
checkEq(blockReason(pBadTool, vOk, "nav", true), NO_TOOL, "壞掉的螺絲刀不算工具")
checkNil(MDAD.findScrewdriver(pBadTool), "findScrewdriver 排除已損壞工具")

local pNoSkill = newPlayer({ electricity = 0 })
pNoSkill:getInventory():AddItem(newScrewdriver(false))
checkEq(blockReason(pNoSkill, vOk, "nav", true), NEED_SKILL, "電工 0 級被技能閘門擋下")
checkFalse(MDAD.hasInstallSkill(pNoSkill), "hasInstallSkill：0 級不足")
setSandbox({ InstallSkillGate = false })
checkNil(blockReason(pNoSkill, vOk, "nav", true), "關掉技能閘門後 0 級可安裝")
checkTrue(MDAD.hasInstallSkill(pNoSkill), "關閘門時 hasInstallSkill 直接放行")
setSandbox({ InstallSkillGate = true })
checkTrue(MDAD.hasInstallSkill(pOk), "電工 1 級剛好過門檻")
checkFalse(MDAD.hasInstallSkill(nil), "無玩家：hasInstallSkill 為 false")

-- 工具／技能關卡的順序：沒工具又沒技能時，先報缺工具
local pNothing = newPlayer({ electricity = 0 })
checkEq(blockReason(pNothing, vOk, "nav", true), NO_TOOL, "沒工具又沒技能：先報缺工具")

local stOk = MDAD.ensureState(vOk:getBattery())
stOk.nav = true
checkEq(blockReason(pOk, vOk, "nav", true), ALREADY, "已裝 nav 不能再裝")
checkNil(blockReason(pOk, vOk, "nav", false), "已裝 nav 可以卸")
checkNil(blockReason(pOk, vOk, "auto", true), "nav 已裝不影響 auto 安裝（狀態欄位沒接錯）")
checkEq(blockReason(pOk, vOk, "auto", false), FAILED, "auto 沒裝不能卸")
stOk.auto = true
checkEq(blockReason(pOk, vOk, "auto", true), ALREADY, "已裝 auto 不能再裝")
checkNil(blockReason(pOk, vOk, "auto", false), "已裝 auto 可以卸")
stOk.nav = nil
stOk.auto = nil
checkEq(blockReason(pOk, vOk, "nav", false), FAILED, "都沒裝時卸載被擋")

-- 隨身道具查詢（client context menu 靠這兩支決定要不要出現安裝選項）
checkNil(MDAD.findPortableGPS(pOk), "背包沒 GPS：findPortableGPS 為 nil")
checkNil(MDAD.findAutopilot(pOk), "背包沒自駕模組：findAutopilot 為 nil")
local invGps = pOk:getInventory():AddItem(newItem(GPS_T, { uses = 0, useDelta = 0.006 }))
local invAuto = pOk:getInventory():AddItem(newItem(AUTO_T))
checkEq(MDAD.findPortableGPS(pOk), invGps, "findPortableGPS 不看電量（沒電也能安裝）")
checkNil(MDAD.findChargedPortableGPS(pOk), "findChargedPortableGPS 排除沒電的 GPS")
checkEq(MDAD.findAutopilot(pOk), invAuto, "findAutopilot 找得到自駕模組")
checkNil(MDAD.findPortableGPS(nil), "無玩家：findPortableGPS 為 nil")
checkNil(MDAD.findAutopilot(nil), "無玩家：findAutopilot 為 nil")
checkNil(MDAD.findChargedPortableGPS(nil), "無玩家：findChargedPortableGPS 為 nil")
resetStats()
MDAD.findPortableGPS(pOk)
MDAD.findAutopilot(pOk)
checkEq(stats.scanType, 2, "findPortableGPS／findAutopilot 各只掃一次背包（不重複遍歷）")

-- =====================================================================
-- 情境五：canReachVehicle（拆裝可及性的唯一判準）
--
-- production 已拿掉 DistToSquared 距離 fallback：距離平方 < 16 等於整車周圍
-- 約 4 格全放行，隔牆偷裝在 MP 下是真的漏洞。這裡逐條釘住新判準，並在收尾
-- 用 distCalls 證明距離 API 全程沒被碰。
-- =====================================================================
scenario("canReachVehicle：坐車一律拒絕、保險屋、同層、有 area 只認 isInArea、無 area 認相鄰格")

safehouseAllow = true
local pR = newPlayer({ num = 8 })
local vR = newVehicle({ battery = newItem("Base.CarBattery", { uses = 1 }) })

resetStats()
checkTrue(MDAD.canReachVehicle(pR, vR), "無 area：站在相鄰格且無阻隔＝可及")
checkEq(stats.canReachTo, 1, "無 area 才走 canReachTo")
checkEq(stats.isInArea, 0, "無 area 不呼叫 isInArea")
checkEq(pR._square._reachArg, vR._square, "canReachTo 的對象是車輛所在格")
checkEq(stats.safehouseCheck, 1, "每次判定都問一次保險屋權限")

pR._square._canReach = false
checkFalse(MDAD.canReachVehicle(pR, vR), "無 area：canReachTo 為 false（隔牆／不相鄰）不可及")
pR._square._canReach = 1
checkFalse(MDAD.canReachVehicle(pR, vR), "canReachTo 回非 true 值一律拒絕（== true 不能鬆掉）")
pR._square._canReach = true

-- 坐在車上一律拒絕：車內座標對電瓶艙沒有意義，必須先下車
pR._vehicle = vR
resetStats()
checkFalse(MDAD.canReachVehicle(pR, vR), "坐在同一輛車上：不可及（拿不到電瓶艙）")
checkEq(stats.canReachTo, 0, "坐車時直接早退，不做格子判定")
checkEq(stats.safehouseCheck, 0, "坐車時連保險屋都不用查")
local vOther = newVehicle({ battery = newItem("Base.CarBattery", { uses = 1 }) })
checkFalse(MDAD.canReachVehicle(pR, vOther), "坐在別的車上：對其他車也一樣不可及")
pR._vehicle = nil
checkTrue(MDAD.canReachVehicle(pR, vR), "下車後恢復可及")

-- 格子缺失一律 fail closed（權威突變的前置條件，資訊不全只能拒絕）
vR._square = nil
checkFalse(MDAD.canReachVehicle(pR, vR), "車輛沒有格子：fail closed")
vR._square = newSquare()
pR._square = nil
checkFalse(MDAD.canReachVehicle(pR, vR), "玩家沒有格子：fail closed")
pR._square = newSquare()
checkTrue(MDAD.canReachVehicle(pR, vR), "格子回來後恢復可及")

-- 保險屋權限
safehouseAllow = false
resetStats()
checkFalse(MDAD.canReachVehicle(pR, vR), "保險屋不允許互動：不可及")
checkEq(stats.canReachTo, 0, "保險屋擋下後不再做相鄰判定")
checkEq(lastSafehouse.square, vR._square, "保險屋以車輛所在格判定（不是玩家的格）")
checkEq(lastSafehouse.player, pR, "保險屋帶入操作者")
safehouseAllow = true
checkTrue(MDAD.canReachVehicle(pR, vR), "保險屋放行後恢復可及")

-- 同層
pR._z, vR._z = 0, 1
checkFalse(MDAD.canReachVehicle(pR, vR), "不同樓層：不可及")
pR._z, vR._z = 0.9, 0.2
checkTrue(MDAD.canReachVehicle(pR, vR), "同層小數高度差（floor 相同）：可及")
pR._z, vR._z = 0, 0

-- 有 area：唯一判準，不得再有距離／相鄰 fallback
local pA = newPlayer({ num = 9 })
local vA = newVehicle({ battery = newItem("Base.CarBattery", { uses = 1 }), area = "engine" })
vA._inArea = true
pA._square._canReach = false        -- 相鄰判定刻意為 false
resetStats()
checkTrue(MDAD.canReachVehicle(pA, vA), "有 area：isInArea 為 true 就可及")
checkEq(stats.isInArea, 1, "有 area 走 isInArea")
checkEq(stats.canReachTo, 0, "有 area 時不再退回相鄰格判定")
checkEq(vA._areaArg, "engine", "isInArea 帶入 part 的 area id")
checkEq(vA._chrArg, pA, "isInArea 帶入操作者（chr 為 nil 時引擎直接回 false）")

vA._inArea = false
pA._square._canReach = true         -- 就算相鄰也不准
resetStats()
checkFalse(MDAD.canReachVehicle(pA, vA), "有 area：不在 area 內就不可及（沒有相鄰格 fallback）")
checkEq(stats.canReachTo, 0, "不在 area 內也不退回相鄰格")
vA._inArea = 1
checkFalse(MDAD.canReachVehicle(pA, vA), "isInArea 回非 true 值一律拒絕")
vA._inArea = true

-- 沒有電瓶 part（腳踏車／拖車）：拿不到 area，退回相鄰格判定
local vBike = newVehicle({ noBattery = true })
checkTrue(MDAD.canReachVehicle(pR, vBike), "無電瓶 part：退回相鄰格＋阻隔判定")
vBike._square = nil
checkFalse(MDAD.canReachVehicle(pR, vBike), "無電瓶 part 且無格子：仍 fail closed")

checkFalse(MDAD.canReachVehicle(nil, vR), "無玩家：不可及")
checkFalse(MDAD.canReachVehicle(pR, nil), "無車輛：不可及")

checkEq(distCalls, 0, "整段可及性判定都沒有呼叫 DistToSquared（距離 fallback 已移除）")

-- =====================================================================
-- 情境六：車電耗電（server-authoritative）
-- =====================================================================
scenario("車電耗電：DrainPercent 0/100/500、nav 對 auto 倍率、引擎運轉、單次扣值、同步門檻")

local RATE_NAV, RATE_AUTO = 0.00002, 0.0001
local dv, db

local function drainVehicle(charge, engineRunning)
    db = newItem("Base.CarBattery", { uses = charge })
    dv = newVehicle({ battery = db, engineRunning = engineRunning })
end

setSandbox({ DrainPercent = 100 })
drainVehicle(0.5)
resetStats()
checkTrue(MDAD.consumeVehiclePower(dv, "nav", 10), "nav 扣電後仍有電：回 true")
checkNear(db._uses, 0.5 - RATE_NAV * 10, EPS, "nav 10 分鐘只扣一次 rate*minutes（雙扣會失敗）")
checkEq(stats.setUsedDelta, 1, "單次呼叫只寫一次 usedDelta")
checkEq(stats.transmitUsedDelta, 0, "round 2 位沒變、未跨 0/1：不同步（避免每分鐘廣播）")
local navDrop = 0.5 - db._uses

drainVehicle(0.5)
MDAD.consumeVehiclePower(dv, "auto", 10)
checkNear(0.5 - db._uses, navDrop * 5, EPS, "auto 費率是 nav 的 5 倍")
checkNear(0.5 - db._uses, RATE_AUTO * 10, EPS, "auto 10 分鐘扣 RATE_AUTO*minutes")

setSandbox({ DrainPercent = 0 })
drainVehicle(0.5)
resetStats()
checkTrue(MDAD.consumeVehiclePower(dv, "nav", 10), "DrainPercent=0：仍回報有電")
checkEq(db._uses, 0.5, "DrainPercent=0：電量完全不動")
checkEq(stats.setUsedDelta, 0, "DrainPercent=0：不寫 usedDelta")
checkEq(stats.transmitUsedDelta, 0, "DrainPercent=0：不同步")
drainVehicle(0)
checkFalse(MDAD.consumeVehiclePower(dv, "nav", 10), "DrainPercent=0 且電量 0：回 false")

setSandbox({ DrainPercent = 500 })
drainVehicle(0.5)
MDAD.consumeVehiclePower(dv, "nav", 10)
checkNear(db._uses, 0.5 - RATE_NAV * 10 * 5, EPS, "DrainPercent=500：扣 5 倍")
local drop500 = 0.5 - db._uses

setSandbox({ DrainPercent = 100000 })
drainVehicle(0.5)
MDAD.consumeVehiclePower(dv, "nav", 10)
checkNear(0.5 - db._uses, drop500, EPS, "DrainPercent 超過 500 截斷為 500")

setSandbox({ DrainPercent = -50 })
drainVehicle(0.5)
checkTrue(MDAD.consumeVehiclePower(dv, "nav", 10), "DrainPercent 負值：仍回報有電")
checkEq(db._uses, 0.5, "DrainPercent 負值截斷為 0：不耗電")

setSandbox({ DrainPercent = "abc" })
drainVehicle(0.5)
MDAD.consumeVehiclePower(dv, "nav", 10)
checkNear(db._uses, 0.5 - RATE_NAV * 10, EPS, "DrainPercent 非數字時退回 100")

setSandbox(nil)
drainVehicle(0.5)
MDAD.consumeVehiclePower(dv, "nav", 10)
checkNear(db._uses, 0.5 - RATE_NAV * 10, EPS, "沙盒未載入時用預設 100")

setSandbox({ DrainPercent = 100 })
drainVehicle(0.5, true)
resetStats()
checkTrue(MDAD.consumeVehiclePower(dv, "auto", 60), "引擎運轉中回報有電")
checkEq(db._uses, 0.5, "引擎運轉中完全不耗車電（發電機在充）")
checkEq(stats.setUsedDelta, 0, "引擎運轉中不寫 usedDelta")
checkEq(stats.transmitUsedDelta, 0, "引擎運轉中不同步")
drainVehicle(0, true)
checkFalse(MDAD.consumeVehiclePower(dv, "auto", 60), "引擎運轉但電量 0：回 false")

drainVehicle(0.5)
resetStats()
checkFalse(MDAD.consumeVehiclePower(nil, "nav", 10), "無車輛")
checkFalse(MDAD.consumeVehiclePower(dv, "radio", 10), "未知 mode")
checkFalse(MDAD.consumeVehiclePower(dv, nil, 10), "mode 為 nil")
checkTrue(MDAD.consumeVehiclePower(dv, "nav", 0), "minutes=0：不耗電但回報有電")
checkTrue(MDAD.consumeVehiclePower(dv, "nav", -5), "minutes 負值：不耗電")
checkTrue(MDAD.consumeVehiclePower(dv, "nav", "10"), "minutes 非數字：不耗電")
checkEq(db._uses, 0.5, "無效參數一律不動電量")
checkEq(stats.setUsedDelta, 0, "無效參數不寫 usedDelta")
checkFalse(MDAD.consumeVehiclePower(newVehicle({ noBattery = true }), "nav", 10), "無電瓶 part")
checkFalse(MDAD.consumeVehiclePower(newVehicle({}), "nav", 10), "電瓶槽沒有 item")
checkFalse(MDAD.consumeVehiclePower(newVehicle({ battery = newItem("Base.Plank") }), "nav", 10),
    "電瓶槽塞了非 drainable 物品")

drainVehicle(0.0001)
resetStats()
checkFalse(MDAD.consumeVehiclePower(dv, "nav", 100), "電量歸零時回 false")
checkEq(db._uses, 0, "clamp01 截到 0，不會變負數")
checkEq(stats.transmitUsedDelta, 1, "跨越 0 邊界一定同步")
resetStats()
checkFalse(MDAD.consumeVehiclePower(dv, "nav", 100), "已經 0 電再呼叫仍回 false")
checkEq(stats.setUsedDelta, 0, "電量已是 0：不重複寫入")
checkEq(stats.transmitUsedDelta, 0, "電量沒變化：不重複廣播")

drainVehicle(0.5)
resetStats()
MDAD.consumeVehiclePower(dv, "auto", 100)
checkNear(db._uses, 0.49, EPS, "auto 100 分鐘扣 0.01")
checkEq(stats.transmitUsedDelta, 1, "round 2 位由 0.50 變 0.49：同步")

drainVehicle(1.0)
resetStats()
MDAD.consumeVehiclePower(dv, "nav", 10)
checkNear(db._uses, 1.0 - RATE_NAV * 10, EPS, "滿電車也照樣耗")
checkEq(stats.transmitUsedDelta, 1, "離開滿電 1.0：round 沒變也要同步")

drainVehicle(0.5)
clientFlag = true
resetStats()
checkFalse(MDAD.consumeVehiclePower(dv, "nav", 10), "MP client 直接 return false")
checkEq(db._uses, 0.5, "MP client 不動電量（server-authoritative）")
checkEq(stats.setUsedDelta, 0, "MP client 不寫 usedDelta")
clientFlag = false

-- =====================================================================
-- 情境七：隨身 GPS 耗電
-- =====================================================================
scenario("隨身耗電：UseDelta 採用規則、auto 同為 5 倍、非法 mode、耗盡、sendItemStats 條件")

setSandbox({ DrainPercent = 100 })
local pi = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
resetStats()
checkTrue(MDAD.consumePortablePower(pi, "nav", 10), "nav 扣電後仍有電")
local portNavDrop = 0.5 - pi._uses
checkNear(portNavDrop, 0.006 * 10, EPS, "nav 採用 item 自己的 UseDelta（0.006/分）")
checkEq(stats.setUsedDelta, 1, "單次呼叫只寫一次 usedDelta")
checkEq(stats.sendItemStats, 1, "MP server 上同步 item 狀態")

pi = newItem(GPS_T, { uses = 1.0, useDelta = 0.006 })
MDAD.consumePortablePower(pi, "auto", 10)
checkNear(1.0 - pi._uses, portNavDrop * 5, EPS, "auto 是 nav 的 5 倍（與車電同倍率）")

-- 沒有 getUseDelta 的物品要退回內建費率，且維持同一倍率關係
pi = newItem(GPS_T, { uses = 0.5 })
MDAD.consumePortablePower(pi, "nav", 10)
checkNear(0.5 - pi._uses, 0.06, EPS, "沒有 getUseDelta 時退回內建 nav 0.006")
pi = newItem(GPS_T, { uses = 0.5 })
MDAD.consumePortablePower(pi, "auto", 10)
checkNear(0.5 - pi._uses, 0.3, EPS, "沒有 getUseDelta 時退回內建 auto 0.03（仍是 5 倍）")

pi = newItem(GPS_T, { uses = 0.5, useDelta = 0 })
MDAD.consumePortablePower(pi, "nav", 10)
checkNear(0.5 - pi._uses, 0.06, EPS, "UseDelta=0 不被採用（否則永不耗電）")
pi = newItem(GPS_T, { uses = 0.5, useDelta = -1 })
MDAD.consumePortablePower(pi, "nav", 10)
checkNear(0.5 - pi._uses, 0.06, EPS, "UseDelta 負值不被採用（否則會充電）")
pi = newItem(GPS_T, { uses = 0.5, useDelta = "0.5" })
MDAD.consumePortablePower(pi, "nav", 10)
checkNear(0.5 - pi._uses, 0.06, EPS, "UseDelta 非數字不被採用")
pi = newItem(GPS_T, { uses = 1.0, useDelta = 0.02 })
MDAD.consumePortablePower(pi, "nav", 10)
checkNear(1.0 - pi._uses, 0.2, EPS, "UseDelta 被改大時費率跟著改（真的讀 item 資料）")

pi = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
resetStats()
checkFalse(MDAD.consumePortablePower(pi, "gps", 10), "未知 mode")
checkFalse(MDAD.consumePortablePower(pi, nil, 10), "mode 為 nil")
checkEq(pi._uses, 0.5, "非法 mode 不動電量")
checkEq(stats.setUsedDelta, 0, "非法 mode 不寫 usedDelta")
checkEq(stats.sendItemStats, 0, "非法 mode 不發同步")
checkTrue(MDAD.consumePortablePower(pi, "nav", 0), "minutes=0：不耗電但回報有電")
checkTrue(MDAD.consumePortablePower(pi, "nav", "10"), "minutes 非數字：不耗電")
checkEq(pi._uses, 0.5, "無效 minutes 不動電量")
checkEq(stats.setUsedDelta, 0, "無效 minutes 不寫 usedDelta")
checkFalse(MDAD.consumePortablePower(nil, "nav", 10), "無物品")
checkFalse(MDAD.consumePortablePower(newItem(AUTO_T), "nav", 10),
    "非 drainable 物品（AutopilotModule 沒有 usedDelta）不被扣電")

setSandbox({ DrainPercent = 0 })
pi = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
resetStats()
checkTrue(MDAD.consumePortablePower(pi, "nav", 10), "DrainPercent=0：仍回報有電")
checkEq(pi._uses, 0.5, "DrainPercent=0：電量完全不動")
checkEq(stats.sendItemStats, 0, "DrainPercent=0：不發同步")
setSandbox({ DrainPercent = 500 })
pi = newItem(GPS_T, { uses = 1.0, useDelta = 0.006 })
MDAD.consumePortablePower(pi, "nav", 10)
checkNear(1.0 - pi._uses, 0.3, EPS, "DrainPercent=500：隨身也扣 5 倍")

setSandbox({ DrainPercent = 100 })
pi = newItem(GPS_T, { uses = 0.05, useDelta = 0.006 })
resetStats()
checkFalse(MDAD.consumePortablePower(pi, "nav", 10), "電量歸零時回 false")
checkEq(pi._uses, 0, "clamp01 截到 0，不會變負數")
checkEq(stats.setUsedDelta, 1, "耗盡那一次要寫入")
checkEq(stats.sendItemStats, 1, "耗盡那一次要同步")
resetStats()
checkFalse(MDAD.consumePortablePower(pi, "nav", 10), "已經 0 電再呼叫仍回 false")
checkEq(stats.setUsedDelta, 0, "電量已是 0：不重複寫入")
checkEq(stats.sendItemStats, 0, "電量沒變化：不重複同步（KeepOnDeplete 物品每分鐘廣播是實災）")

-- SP（isClient/isServer 皆 false）：照扣電，但不發網路同步
pi = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
serverFlag = false
resetStats()
checkTrue(MDAD.consumePortablePower(pi, "nav", 10), "SP 照樣耗電")
checkNear(0.5 - pi._uses, 0.06, EPS, "SP 扣的量與 MP server 相同")
checkEq(stats.setUsedDelta, 1, "SP 寫入 usedDelta")
checkEq(stats.sendItemStats, 0, "SP 不發 sendItemStats")
serverFlag = true

pi = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
clientFlag = true
resetStats()
checkFalse(MDAD.consumePortablePower(pi, "nav", 10), "MP client 直接 return false")
checkEq(pi._uses, 0.5, "MP client 不動電量")
checkEq(stats.setUsedDelta, 0, "MP client 不寫 usedDelta")
checkEq(stats.sendItemStats, 0, "MP client 不發同步")
clientFlag = false

-- =====================================================================
-- 情境八～十：MDAD.applyDeviceChange（安裝／卸載的唯一突變點）
--
-- 以 MP 專用伺服器的旗標組合（isClient=false、isServer=true）直接驅動突變段，
-- 這正是 OnClientCommand 會呼叫到的同一份程式碼；派送層另有情境十二～十四。
-- =====================================================================
scenario("apply 安裝：nav 保存 delta＋從實際容器移除＋同步；auto 只動 auto 欄位")

setSandbox({ InstallSkillGate = true, DrainPercent = 100 })
clientFlag, serverFlag = false, true
safehouseAllow = true

local function mkPlayer(skill)
    local c = newPlayer({ num = 5, electricity = skill or 2, username = "worker" })
    c:getInventory():AddItem(newScrewdriver(false))
    return c
end

local function mkVehicle(charge)
    return newVehicle({ battery = newItem("Base.CarBattery", { uses = charge or 0.8 }) })
end

local ch, veh, it, st, got

-- 一律以「物品 id」進 apply，對齊 server 端只收純量的契約
local function apply(owner, vehicle, kind, install, item)
    local id = -1
    if item ~= nil then id = item:getID() end
    local okA, reasonA = MDAD.applyDeviceChange(owner, vehicle, kind, install, id)
    noteReason(reasonA)
    return okA, reasonA
end

-- 失敗路徑通用斷言：不丟物、不寫狀態、不同步、不生成道具
local function noSideEffect(label, expected, owner, vehicle, kind, install, item)
    resetStats()
    local okA, reasonA = apply(owner, vehicle, kind, install, item)
    checkFalse(okA, label .. "：apply 回 false")
    checkEq(reasonA, expected, label .. "：理由鍵")
    if item and owner then
        checkTrue(owner:getInventory():contains(item), label .. "：物品仍在背包（失敗不丟物）")
    end
    if owner then
        checkEq(owner.removedFromHands, 0, label .. "：沒有從手上移除")
    end
    checkEq(stats.sendRemoveItem, 0, label .. "：沒有發移除同步")
    checkEq(stats.transmitModData, 0, label .. "：沒有同步 part modData")
    checkEq(stats.instanceItem, 0, label .. "：沒有生成道具")
    if vehicle then
        checkFalse(MDAD.isNavInstalled(vehicle), label .. "：nav 狀態未被寫入")
        checkFalse(MDAD.isAutoInstalled(vehicle), label .. "：auto 狀態未被寫入")
    end
end

-- 安裝 nav：happy path
ch = mkPlayer()
veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.42, useDelta = 0.006 })
ch:getInventory():AddItem(it)
resetStats()
checkTrue(apply(ch, veh, "nav", true, it), "安裝 nav：apply 回 true")
st = MDAD.getState(veh)
checkTrue(st ~= nil, "安裝後 part modData 有 MDAD 狀態表")
checkEq(st.v, 1, "狀態版本欄位寫成 1")
checkTrue(st.nav, "st.nav = true")
checkNear(st.navDelta, 0.42, EPS, "navDelta 由 server 從實物讀取（不採 client 值）")
checkNil(st.auto, "安裝 nav 不碰 st.auto")
checkFalse(ch:getInventory():contains(it), "物品已從背包移除")
checkEq(ch.removedFromHands, 1, "先從手上卸下再移除")
checkEq(it.jobDelta, 0, "移除前把 jobDelta 歸零（避免殘留進度條）")
checkEq(stats.itemById, 1, "只依 id 重解析一次物品")
checkEq(stats.sendRemoveItem, 1, "MP server 發了一次移除同步")
checkEq(stats.transmitModData, 1, "同步了一次 part modData")
checkEq(stats.addWorldItem, 0, "安裝不會掉東西在地上")
checkTrue(MDAD.isNavInstalled(veh), "isNavInstalled 反映安裝結果")
checkFalse(MDAD.isAutoInstalled(veh), "只裝 nav 時 auto 仍為未安裝")
checkTrue(MDAD.hasVehicleNavPower(veh), "裝好後車電有電：hasVehicleNavPower")

-- 重播同一個請求：被 deviceBlockReason 擋下，且不得再改狀態
resetStats()
local okR, reasonR = apply(ch, veh, "nav", true, it)
checkFalse(okR, "同一請求重播：回 false")
checkEq(reasonR, ALREADY, "重播理由鍵是已安裝")
checkNear(st.navDelta, 0.42, EPS, "重播不覆寫 navDelta")
checkEq(stats.transmitModData, 0, "重播不再同步")
checkEq(stats.sendRemoveItem, 0, "重播不再發移除")

-- 物品放在背包裡的袋子：要從**實際容器**移除，不是預設主背包
ch = mkPlayer(); veh = mkVehicle()
local pouch = ch:getInventory():AddSubContainer()
it = newItem(GPS_T, { uses = 0.3, useDelta = 0.006 })
pouch:AddItem(it)
resetStats()
checkTrue(apply(ch, veh, "nav", true, it), "物品在背包裡的袋子：仍解析得到並安裝")
checkFalse(pouch:contains(it), "從袋子（實際容器）移除，不是從主背包移除")
checkEq(stats.sendRemoveItem, 1, "移除同步發一次")
checkTrue(MDAD.isNavInstalled(veh), "袋子裡的物品照樣完成安裝")

-- 電量 clamp 邊界
ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = 1.5, useDelta = 0.006 })
ch:getInventory():AddItem(it)
checkTrue(apply(ch, veh, "nav", true, it), "電量 1.5 仍可安裝")
checkEq(MDAD.getState(veh).navDelta, 1, "navDelta 上限截到 1")

ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = -0.5, useDelta = 0.006 })
ch:getInventory():AddItem(it)
checkTrue(apply(ch, veh, "nav", true, it), "電量負值仍可安裝")
checkEq(MDAD.getState(veh).navDelta, 0, "navDelta 下限截到 0")

ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
ch:getInventory():AddItem(it)
it._uses = nil   -- getCurrentUsesFloat 存在但回傳非數字
checkTrue(apply(ch, veh, "nav", true, it), "電量非數字仍可安裝")
checkEq(MDAD.getState(veh).navDelta, 0, "非數字電量退回 0（不會把 nil 寫進 modData）")

-- 安裝 auto：happy path。AutopilotModule 是 base:normal，
-- production 若對它呼叫 getCurrentUsesFloat/setUsedDelta，假物件沒有這些方法會直接炸
ch = mkPlayer()
veh = mkVehicle()
it = newItem(AUTO_T)
ch:getInventory():AddItem(it)
resetStats()
checkTrue(apply(ch, veh, "auto", true, it), "安裝 auto：apply 回 true")
st = MDAD.getState(veh)
checkTrue(st.auto, "st.auto = true")
checkNil(st.nav, "安裝 auto 不碰 st.nav")
checkNil(st.navDelta, "安裝 auto 不寫 navDelta")
checkFalse(ch:getInventory():contains(it), "自駕模組已從背包移除")
checkEq(stats.setUsedDelta, 0, "auto 路徑完全不碰電量 API")
checkEq(stats.transmitModData, 1, "auto 安裝同步一次")
checkTrue(MDAD.isAutoInstalled(veh), "isAutoInstalled 反映安裝結果")
checkFalse(MDAD.isNavInstalled(veh), "裝 auto 不會誤報 nav 已裝")

-- nav 與 auto 可同時存在，彼此不覆寫
it = newItem(GPS_T, { uses = 0.9, useDelta = 0.006 })
ch:getInventory():AddItem(it)
checkTrue(apply(ch, veh, "nav", true, it), "auto 已裝時仍可裝 nav")
st = MDAD.getState(veh)
checkTrue(st.auto, "裝 nav 後 auto 狀態保留")
checkTrue(st.nav, "nav 狀態寫入")
checkNear(st.navDelta, 0.9, EPS, "navDelta 正確")

-- =====================================================================
-- 情境九：apply 的七道驗證關卡，任一關不過都不動世界
-- =====================================================================
scenario("apply 安裝失敗：schema／actor／可及性／工具／物品任一關不過都不動世界")

-- ① schema
ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
ch:getInventory():AddItem(it)
noSideEffect("kind 不合法", FAILED, ch, veh, "turbo", true, it)
noSideEffect("kind 為 nil", FAILED, ch, veh, nil, true, it)

resetStats()
local okS, reasonS = MDAD.applyDeviceChange(ch, veh, "nav", "true", it:getID())
checkFalse(okS, "install 非 boolean：回 false")
checkEq(noteReason(reasonS), FAILED, "install 非 boolean 的理由鍵")
checkEq(stats.itemById, 0, "install 非 boolean：連物品都不去解析")
okS, reasonS = MDAD.applyDeviceChange(ch, veh, "nav", nil, it:getID())
checkFalse(okS, "install 為 nil：回 false")
checkTrue(ch:getInventory():contains(it), "schema 失敗：物品仍在背包")

-- ② actor
ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
ch:getInventory():AddItem(it)
resetStats()
okS, reasonS = MDAD.applyDeviceChange(nil, veh, "nav", true, it:getID())
checkFalse(okS, "player 為 nil：回 false")
checkEq(noteReason(reasonS), FAILED, "player 為 nil 的理由鍵")
ch._dead = true
noSideEffect("屍體不能修車", FAILED, ch, veh, "nav", true, it)
ch._dead = false
ch._vehicle = veh
noSideEffect("還坐在車上", TOO_FAR, ch, veh, "nav", true, it)
ch._vehicle = nil

-- ③ 載具／零件
resetStats()
okS, reasonS = MDAD.applyDeviceChange(ch, nil, "nav", true, it:getID())
checkFalse(okS, "vehicle 為 nil：回 false")
checkEq(noteReason(reasonS), FAILED, "vehicle 為 nil 的理由鍵")

ch = mkPlayer()
local vBikeApply = newVehicle({ noBattery = true })
it = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
ch:getInventory():AddItem(it)
noSideEffect("車輛沒有電瓶 part", NO_BATTERY, ch, vBikeApply, "nav", true, it)

-- ④ 可及性（含保險屋、area）——每一種不可及都必須是 TooFar，不能靜默通過
ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
ch:getInventory():AddItem(it)
ch._square._canReach = false
noSideEffect("站太遠／隔著牆", TOO_FAR, ch, veh, "nav", true, it)
ch._square._canReach = true

local savedSquare = ch._square
ch._square = nil
noSideEffect("玩家沒有站立格", TOO_FAR, ch, veh, "nav", true, it)
ch._square = savedSquare

safehouseAllow = false
noSideEffect("保險屋不允許互動", TOO_FAR, ch, veh, "nav", true, it)
safehouseAllow = true

local vAreaApply = newVehicle({ battery = newItem("Base.CarBattery", { uses = 0.8 }), area = "engine" })
noSideEffect("有 area 卻不在 area 內", TOO_FAR, ch, vAreaApply, "nav", true, it)
vAreaApply._inArea = true
resetStats()
checkTrue(apply(ch, vAreaApply, "nav", true, it), "走進電瓶艙 area 後可以安裝")

-- ⑤⑥ 工具／技能／狀態轉移
ch = newPlayer({ num = 5, electricity = 2 })   -- 無螺絲刀
veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
ch:getInventory():AddItem(it)
noSideEffect("沒有螺絲刀", NO_TOOL, ch, veh, "nav", true, it)

ch = mkPlayer(0); veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
ch:getInventory():AddItem(it)
noSideEffect("電工技能不足", NEED_SKILL, ch, veh, "nav", true, it)

-- ⑦ 物品
ch = mkPlayer(); veh = mkVehicle()
it = newItem(AUTO_T)
ch:getInventory():AddItem(it)
noSideEffect("nav 請求卻指向自駕模組", FAILED, ch, veh, "nav", true, it)

ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
ch:getInventory():AddItem(it)
noSideEffect("auto 請求卻指向 GPS", FAILED, ch, veh, "auto", true, it)

ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })   -- 刻意不放進任何容器
resetStats()
okS, reasonS = apply(ch, veh, "nav", true, it)
checkFalse(okS, "物品不在操作者背包樹內：回 false")
checkEq(reasonS, FAILED, "找不到物品的理由鍵")
checkEq(stats.transmitModData, 0, "找不到物品：不同步狀態")
checkFalse(MDAD.isNavInstalled(veh), "找不到物品：狀態未寫入")

-- 在背包清單裡但 getContainer() 為 nil（序列化走鐘）：不能拿它當已解析容器用
ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
table.insert(ch:getInventory()._items, it)   -- 刻意不設 _container
resetStats()
okS, reasonS = apply(ch, veh, "nav", true, it)
checkFalse(okS, "物品沒有容器：回 false")
checkEq(reasonS, FAILED, "沒有容器的理由鍵")
checkEq(stats.sendRemoveItem, 0, "沒有容器：不發移除同步")
checkFalse(MDAD.isNavInstalled(veh), "沒有容器：狀態未寫入")

-- itemId 非有限整數：不得進 Java 的 getItemWithIDRecursiv
ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
ch:getInventory():AddItem(it)
for _, bad in ipairs({ 1.5, 0 / 0, math.huge, -math.huge }) do
    resetStats()
    okS, reasonS = MDAD.applyDeviceChange(ch, veh, "nav", true, bad)
    checkFalse(okS, "itemId 非有限整數（" .. tostring(bad) .. "）：回 false")
    checkEq(noteReason(reasonS), FAILED, "itemId 非有限整數的理由鍵")
    checkEq(stats.itemById, 0, "itemId 非有限整數：不呼叫 getItemWithIDRecursiv")
end
resetStats()
okS, reasonS = MDAD.applyDeviceChange(ch, veh, "nav", true, "5")
checkFalse(okS, "itemId 是字串：回 false")
checkEq(stats.itemById, 0, "itemId 是字串：不呼叫 getItemWithIDRecursiv")
checkTrue(ch:getInventory():contains(it), "上述 itemId 檢查全程沒動到物品")

-- MP client 沒有權威：整支函式在第一行就拒絕
clientFlag = true
ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
ch:getInventory():AddItem(it)
resetStats()
okS, reasonS = apply(ch, veh, "nav", true, it)
checkFalse(okS, "MP client 呼叫 apply：回 false")
checkEq(reasonS, FAILED, "MP client 的理由鍵")
checkTrue(ch:getInventory():contains(it), "MP client：物品不動")
checkEq(stats.transmitModData, 0, "MP client：不同步")
checkFalse(MDAD.isNavInstalled(veh), "MP client：不寫狀態")
clientFlag = false

-- =====================================================================
-- 情境十：apply 卸載
-- =====================================================================
scenario("apply 卸載：還原物品與 delta、重播不複製道具、生成失敗不吃裝置")

local function mkInstalled(kind, navDelta)
    local c = mkPlayer()
    local v = mkVehicle()
    local s = MDAD.ensureState(v:getBattery())
    if kind == "nav" then
        s.nav = true
        s.navDelta = navDelta
    else
        s.auto = true
    end
    return c, v, s
end

ch, veh, st = mkInstalled("nav", 0.37)
resetStats()
checkTrue(apply(ch, veh, "nav", false, nil), "卸載 nav：apply 回 true")
checkFalse(st.nav, "st.nav 設為 false（不是留 true）")
checkNil(st.navDelta, "st.navDelta 清掉（不留舊電量給下一顆）")
checkEq(st.v, 1, "狀態版本欄位保持 1")
checkEq(stats.instanceItem, 1, "生成一顆 GPS")
checkEq(stats.itemById, 0, "卸載不需要 itemId：不呼叫 getItemWithIDRecursiv")
checkEq(stats.transmitModData, 1, "同步一次 part modData")
checkEq(stats.sendAddItem, 1, "背包有空間：走 AddItem＋同步")
checkEq(stats.addWorldItem, 0, "背包有空間：不掉地上")
got = ch:getInventory():getFirstTypeRecurse(GPS_T)
checkTrue(got ~= nil, "GPS 回到背包")
checkEq(got:getFullType(), GPS_T, "還原的是 GPS 型別")
checkNear(got._uses, 0.37, EPS, "安裝時保存的電量原封不動還回來")
checkFalse(MDAD.isNavInstalled(veh), "卸載後 isNavInstalled 為 false")
checkFalse(MDAD.hasVehicleNavPower(veh), "卸載後 hasVehicleNavPower 為 false")

resetStats()
local okU, reasonU = apply(ch, veh, "nav", false, nil)
checkFalse(okU, "重播卸載請求：回 false")
checkEq(reasonU, FAILED, "重播卸載的理由鍵（沒裝卻要卸）")
checkEq(stats.instanceItem, 0, "重複卸載不再生成道具（道具複製漏洞的反面斷言）")
checkEq(stats.sendAddItem, 0, "重複卸載不發加入同步")
checkEq(stats.transmitModData, 0, "重複卸載不再同步")

-- navDelta 缺失／超界（舊存檔或被外部改壞）
ch, veh, st = mkInstalled("nav", nil)
checkTrue(apply(ch, veh, "nav", false, nil), "navDelta 為 nil 仍可卸")
checkEq(ch:getInventory():getFirstTypeRecurse(GPS_T)._uses, 0, "navDelta 為 nil 時還原成 0 電")

ch, veh, st = mkInstalled("nav", 5)
checkTrue(apply(ch, veh, "nav", false, nil), "navDelta 超上界仍可卸")
checkEq(ch:getInventory():getFirstTypeRecurse(GPS_T)._uses, 1, "navDelta 5 截到 1（不給滿溢電量）")

ch, veh, st = mkInstalled("nav", -2)
checkTrue(apply(ch, veh, "nav", false, nil), "navDelta 負值仍可卸")
checkEq(ch:getInventory():getFirstTypeRecurse(GPS_T)._uses, 0, "navDelta -2 截到 0")

ch, veh, st = mkInstalled("nav", "0.5")
checkTrue(apply(ch, veh, "nav", false, nil), "navDelta 非數字仍可卸")
checkEq(ch:getInventory():getFirstTypeRecurse(GPS_T)._uses, 0, "navDelta 非數字退回 0")

-- 背包滿：掉在腳下
ch, veh, st = mkInstalled("nav", 0.5)
ch:getInventory()._roomFor = false
resetStats()
checkTrue(apply(ch, veh, "nav", false, nil), "背包滿仍可卸")
checkEq(stats.addWorldItem, 1, "背包滿：掉在腳下的格子")
checkEq(stats.sendAddItem, 0, "背包滿：不發加入容器同步")
checkNil(ch:getInventory():getFirstTypeRecurse(GPS_T), "背包滿：物品不在背包裡")
checkEq(ch._square._dropped:getFullType(), GPS_T, "掉在地上的是 GPS")
checkNear(ch._square._dropped._uses, 0.5, EPS, "掉在地上的 GPS 也保有電量")
checkFalse(st.nav, "背包滿也照樣完成卸除")

-- 沒有站立格：可及性就先擋掉了，走不到丟物分支——裝置必須原封不動留在車上
ch, veh, st = mkInstalled("nav", 0.5)
ch:getInventory()._roomFor = false
ch._square = nil
resetStats()
okU, reasonU = apply(ch, veh, "nav", false, nil)
checkFalse(okU, "沒有站立格：卸載被可及性擋下")
checkEq(reasonU, TOO_FAR, "沒有站立格的理由鍵")
checkEq(stats.instanceItem, 0, "被擋下就不生成道具")
checkEq(stats.addWorldItem, 0, "被擋下不會掉地上")
checkTrue(st.nav, "被擋下時狀態保留（裝置不會憑空消失）")

-- 卸載 auto
ch, veh, st = mkInstalled("auto")
resetStats()
checkTrue(apply(ch, veh, "auto", false, nil), "卸載 auto：apply 回 true")
checkFalse(st.auto, "st.auto 設為 false")
checkNil(st.nav, "卸載 auto 不碰 st.nav")
checkNil(st.navDelta, "卸載 auto 不寫 navDelta")
checkEq(stats.setUsedDelta, 0, "auto 卸載完全不碰電量 API（AutopilotModule 非 drainable）")
checkEq(stats.instanceItem, 1, "生成一顆自駕模組")
checkEq(stats.transmitModData, 1, "同步一次")
got = ch:getInventory():getFirstTypeRecurse(AUTO_T)
checkTrue(got ~= nil, "自駕模組回到背包")
checkFalse(MDAD.isAutoInstalled(veh), "卸載後 isAutoInstalled 為 false")

-- instanceItem 回 nil（items 腳本沒載入／型別改名）：不能吃掉玩家的裝置
instanceItemEnabled = false
ch, veh, st = mkInstalled("nav", 0.6)
resetStats()
checkFalse(apply(ch, veh, "nav", false, nil), "生成 GPS 失敗：回 false")
checkTrue(st.nav, "生成失敗時 nav 狀態保留（裝置不能憑空消失）")
checkNear(st.navDelta, 0.6, EPS, "生成失敗時 navDelta 保留")
checkEq(stats.transmitModData, 0, "生成失敗不同步")
checkNil(ch:getInventory():getFirstTypeRecurse(GPS_T), "生成失敗背包不會多東西")

ch, veh, st = mkInstalled("auto")
resetStats()
checkFalse(apply(ch, veh, "auto", false, nil), "生成自駕模組失敗：回 false")
checkTrue(st.auto, "生成失敗時 auto 狀態保留")
checkEq(stats.transmitModData, 0, "生成失敗不同步")
instanceItemEnabled = true

-- 未安裝就卸載／不可及：不得生成道具
ch = mkPlayer(); veh = mkVehicle()
resetStats()
checkFalse(apply(ch, veh, "nav", false, nil), "沒裝 nav 不能卸")
checkFalse(apply(ch, veh, "auto", false, nil), "沒裝 auto 不能卸")
checkEq(stats.instanceItem, 0, "沒裝就卸不會生成道具（另一條道具複製路徑）")

ch, veh, st = mkInstalled("nav", 0.5)
ch._square._canReach = false
resetStats()
checkFalse(apply(ch, veh, "nav", false, nil), "站太遠不能卸")
checkTrue(st.nav, "站太遠時狀態不動")
checkEq(stats.instanceItem, 0, "站太遠不生成道具")

-- 完整往返：裝進去的電量原值取回
ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.73, useDelta = 0.006 })
ch:getInventory():AddItem(it)
checkTrue(apply(ch, veh, "nav", true, it), "往返：安裝成功")
checkTrue(apply(ch, veh, "nav", false, nil), "往返：卸載成功")
got = ch:getInventory():getFirstTypeRecurse(GPS_T)
checkTrue(got ~= nil and got ~= it, "往返後拿到的是新生成的實例（不是舊物件）")
checkNear(got._uses, 0.73, EPS, "往返後電量完全一致（0.73 進、0.73 出）")
checkNil(MDAD.getState(veh).navDelta, "往返結束後 navDelta 清空")

-- =====================================================================
-- 情境十一：TimedAction 只管工時／動畫，**刻意沒有 complete()**
-- =====================================================================
scenario("TimedAction 生命週期：不得有 complete、new 欄位契約、jobType、duration、isValid、start/stop")

local act
ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
ch:getInventory():AddItem(it)
act = ISAutoDriveDeviceAction:new(ch, veh, "nav", true, it)

-- 這一條是整份安全重構的樑柱：只要 metatable 上出現 complete，引擎就會建
-- NetTimedAction 鏡像，client 送來的 character／vehicle／item 會被伺服器照單全收。
checkNil(ISAutoDriveDeviceAction.complete, "類別上不得定義 complete（否則引擎會建 NetTimedAction 鏡像）")
checkNil(act.complete, "實例沿 metatable 也查不到 complete")

-- NetTimedAction.set 依 new() 參數名打包欄位，欄位名改掉 MP 就靜默失效
checkEq(act.character, ch, "new 存 character")
checkEq(act.vehicle, veh, "new 存 vehicle（欄位名必須是 vehicle）")
checkEq(act.kind, "nav", "new 存 kind")
checkEq(act.install, true, "new 存 install")
checkEq(act.item, it, "new 存 item")
checkEq(act.maxTime, 150, "maxTime 取 WORK_TIME")
checkEq(act:getDuration(), 150, "非 instant 玩家 duration 為 150")
checkEq(noteReason(act.jobType), "UI_MinidoracatAutoDrive_InstallGPS", "安裝 nav 的 jobType")
checkEq(noteReason(ISAutoDriveDeviceAction:new(ch, veh, "auto", true, it).jobType),
    "UI_MinidoracatAutoDrive_InstallAuto", "安裝 auto 的 jobType")
checkEq(noteReason(ISAutoDriveDeviceAction:new(ch, veh, "nav", false, nil).jobType),
    "UI_MinidoracatAutoDrive_UninstallGPS", "卸載 nav 的 jobType")
checkEq(noteReason(ISAutoDriveDeviceAction:new(ch, veh, "auto", false, nil).jobType),
    "UI_MinidoracatAutoDrive_UninstallAuto", "卸載 auto 的 jobType")
checkEq(ISAutoDriveDeviceAction:new(ch, veh, "nav", false, nil).install, false, "卸載時 install 為 false")

ch._instant = true
checkEq(ISAutoDriveDeviceAction:new(ch, veh, "nav", true, it).maxTime, 1, "instant 玩家 maxTime 為 1")
ch._instant = false

-- isValid
checkTrue(act:isValid(), "備齊條件時 isValid 為 true")
act.kind = "turbo"
checkFalse(act:isValid(), "kind 不合法：isValid 為 false")
act.kind = "nav"
act.item = newItem(AUTO_T)
ch:getInventory():AddItem(act.item)
checkFalse(act:isValid(), "拿錯型別：isValid 為 false")
act.item = it
checkTrue(act:isValid(), "改回正確型別：isValid 為 true")
ch:getInventory():DoRemoveItem(it)
checkFalse(act:isValid(), "物品已不在背包：isValid 為 false")
ch:getInventory():AddItem(it)
ch._square._canReach = false
checkFalse(act:isValid(), "不可及：isValid 為 false")
ch._square._canReach = true
ch._vehicle = veh
checkFalse(act:isValid(), "坐在車上：isValid 為 false")
ch._vehicle = nil
act.item = nil
checkFalse(act:isValid(), "安裝但沒有物品：isValid 為 false")
act.item = it

-- MP client：isValid 走 containsID、start 依 id 重抓實例
clientFlag = true
checkTrue(act:isValid(), "MP client：containsID 找得到就有效")
act.item = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })   -- 同型別但 id 不在背包
checkFalse(act:isValid(), "MP client：id 不在背包則無效")
act.item = it
act:start()
checkEq(act.item, it, "MP client：start 依 id 重抓到背包裡的實例")
checkEq(it.jobType, act.jobType, "start 把 jobType 寫進物品")
checkEq(act.actionAnim, "VehicleWorkOnMid", "start 設定動作動畫")
clientFlag = false

it.jobDelta = 0.5
act:stop()
checkEq(it.jobDelta, 0, "stop 把物品 jobDelta 歸零")
checkTrue(act.stopped, "stop 有呼叫父類 stop")

ch.faced = 0
act:update()
checkTrue(ch.faced > 0, "update 面向車輛")
checkEq(it.jobDelta, 0, "update 把 jobDelta 同步到物品")
checkFalse(act:waitToStart(), "轉身完成後 waitToStart 為 false")
checkTrue(ch.faced > 1, "waitToStart 也會面向車輛")

-- getState／ensureState 的狀態表契約
veh = mkVehicle()
checkNil(MDAD.getState(veh), "全新車輛沒有狀態表")
st = MDAD.ensureState(veh:getBattery())
checkEq(st.v, 1, "ensureState 寫入版本 1")
checkEq(MDAD.ensureState(veh:getBattery()), st, "ensureState 是 idempotent（不會換新表）")
checkEq(MDAD.getState(veh), st, "getState 讀到同一張表")
veh:getBattery():getModData().MDAD = "壞掉的舊資料"
checkNil(MDAD.getState(veh), "modData.MDAD 不是 table 時視為無狀態（不炸）")
checkFalse(MDAD.isNavInstalled(veh), "壞掉的狀態不會誤判為已安裝")
st = MDAD.ensureState(veh:getBattery())
checkEq(type(st), "table", "ensureState 把壞掉的資料換成新表")
checkEq(st.v, 1, "換新表後版本仍是 1")
checkNil(MDAD.getState(newVehicle({ noBattery = true })), "無電瓶車輛：getState 為 nil")
checkNil(MDAD.getState(nil), "無車輛：getState 為 nil")

-- =====================================================================
-- 情境十二：SP 派送（isClient=false、isServer=false）
-- perform() 直接呼叫同一份 shared apply，且只呼叫一次
-- =====================================================================
scenario("SP 派送：perform 直接突變一次、不發封包、失敗以 halo 回報、專用伺服器不畫 UI")

clientFlag, serverFlag = false, false
safehouseAllow = true

ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.42, useDelta = 0.006 })
ch:getInventory():AddItem(it)
act = ISAutoDriveDeviceAction:new(ch, veh, "nav", true, it)
resetStats()
act:perform()
checkEq(#sentClient, 0, "SP：不發 sendClientCommand")
checkTrue(MDAD.isNavInstalled(veh), "SP：perform 就完成安裝")
checkNear(MDAD.getState(veh).navDelta, 0.42, EPS, "SP：navDelta 由 apply 從實物讀取")
checkFalse(ch:getInventory():contains(it), "SP：物品已移除")
checkEq(stats.transmitModData, 1, "SP：perform 只呼叫一次 apply（同步剛好一次）")
checkEq(stats.sendRemoveItem, 0, "SP：isServer 為 false，不廣播移除")
checkEq(#halos, 0, "SP：成功不提示")
checkEq(it.jobDelta, 0, "perform 收尾把 jobDelta 歸零")
checkTrue(act.performed, "SP：仍呼叫父類 perform")

-- 同一個 action 再 perform 一次（queue 被灌爆時真的會）：失敗且以 halo 回報
resetStats()
act:perform()
checkEq(stats.transmitModData, 0, "SP：重播不再突變")
checkEq(#halos, 1, "SP：失敗回報一則 halo")
checkEq(noteReason(halos[1] and halos[1].text), ALREADY, "SP：halo 帶的是 production 的理由鍵")
checkEq(halos[1] and halos[1].player, ch, "SP：halo 掛在操作者身上")

-- 卸載也走同一條
ch, veh, st = mkInstalled("nav", 0.5)
act = ISAutoDriveDeviceAction:new(ch, veh, "nav", false, nil)
resetStats()
act:perform()
checkFalse(st.nav, "SP：perform 完成卸載")
checkEq(stats.instanceItem, 1, "SP：卸載生成一顆 GPS")
checkEq(#sentClient, 0, "SP：卸載也不發封包")

-- 專用伺服器（isClient=false、isServer=true）不畫 UI：失敗不得呼叫 HaloTextHelper
serverFlag = true
ch = mkPlayer(); veh = mkVehicle()
act = ISAutoDriveDeviceAction:new(ch, veh, "nav", false, nil)   -- 沒裝卻要卸，必失敗
resetStats()
act:perform()
checkEq(#halos, 0, "專用伺服器：失敗也不畫 halo")
checkEq(stats.instanceItem, 0, "專用伺服器：失敗不生成道具")
serverFlag = false

-- character／vehicle 缺一：不派送，但仍要收尾呼叫父類 perform
ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
ch:getInventory():AddItem(it)
act = ISAutoDriveDeviceAction:new(ch, veh, "nav", true, it)
act.vehicle = nil
resetStats()
act.performed = false
act:perform()
checkTrue(act.performed, "vehicle 為 nil：仍呼叫父類 perform")
checkEq(stats.transmitModData, 0, "vehicle 為 nil：不突變")
checkEq(#sentClient, 0, "vehicle 為 nil：不發封包")
checkTrue(ch:getInventory():contains(it), "vehicle 為 nil：物品仍在背包")

-- =====================================================================
-- 情境十三：MP client 派送（isClient=true）
-- perform 只送四個純量，本地一點世界狀態都不能動
-- =====================================================================
scenario("MP client 派送：只送 vehicleId/kind/install/itemId、本地零突變、不夾帶 actor")

clientFlag, serverFlag = true, false

ch = mkPlayer(); veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.42, useDelta = 0.006 })
ch:getInventory():AddItem(it)
act = ISAutoDriveDeviceAction:new(ch, veh, "nav", true, it)
resetStats()
act:perform()

checkEq(#sentClient, 1, "MP client：發一次 sendClientCommand")
local msg = sentClient[1] or {}
local margs = msg.args or {}
checkEq(msg.player, ch, "sendClientCommand 第一參數是操作者")
checkEq(msg.module, MOD_ID, "module 是 MOD_ID")
checkEq(msg.command, "Device", "command 是 Device")
checkEq(msg.command, MDAD.CMD_DEVICE, "command 常數與 shared 一致")
checkEq(type(msg.args), "table", "payload 是 table")
checkEq(margs.vehicleId, veh:getId(), "payload 帶 vehicleId（不是車輛物件）")
checkEq(type(margs.vehicleId), "number", "vehicleId 是純量")
checkEq(margs.kind, "nav", "payload 帶 kind")
checkEq(margs.install, true, "payload 帶 install")
checkEq(margs.itemId, it:getID(), "payload 帶 itemId（不是物品物件）")

local fieldCount = 0
for _ in pairs(margs) do fieldCount = fieldCount + 1 end
checkEq(fieldCount, 4, "payload 只有四個欄位（不夾帶 actor／partId／navDelta／state）")
checkNil(margs.actor, "payload 不帶 actor")
checkNil(margs.character, "payload 不帶 character")
checkNil(margs.navDelta, "payload 不帶 navDelta")
checkNil(margs.state, "payload 不帶 state")
checkNil(margs.partId, "payload 不帶 partId")

checkFalse(MDAD.isNavInstalled(veh), "MP client：本地不寫狀態")
checkTrue(ch:getInventory():contains(it), "MP client：物品沒被本地移除")
checkEq(stats.transmitModData, 0, "MP client：不同步 part modData")
checkEq(stats.sendRemoveItem, 0, "MP client：不發移除同步")
checkEq(stats.itemById, 0, "MP client：不做任何權威解析")
checkEq(#halos, 0, "MP client：不本地提示（等伺服器回報）")
checkEq(it.jobDelta, 0, "MP client：perform 仍把 jobDelta 收乾淨")
checkTrue(act.performed, "MP client：仍呼叫父類 perform")

-- 卸載：沒有來源物品，itemId 送 -1（server 端 install=false 不會用到）
act = ISAutoDriveDeviceAction:new(ch, veh, "nav", false, nil)
resetStats()
act:perform()
checkEq(#sentClient, 1, "MP client 卸載：也發一次")
checkEq(sentClient[1] and sentClient[1].args.install, false, "卸載 payload 的 install 為 false")
checkEq(sentClient[1] and sentClient[1].args.itemId, -1, "卸載沒有來源物品：itemId 送 -1")

-- install 一律正規化成 boolean（欄位被外部改成雜值時不得原樣送出）
act = ISAutoDriveDeviceAction:new(ch, veh, "nav", true, it)
act.install = 1
resetStats()
act:perform()
checkEq(sentClient[1] and sentClient[1].args.install, false, "install 非 true 的雜值一律送 false（== true 正規化）")
checkEq(type(sentClient[1] and sentClient[1].args.install), "boolean", "install 一定是 boolean")

clientFlag, serverFlag = false, true

-- =====================================================================
-- 情境十四：MP server 權威路徑（Events.OnClientCommand → server/MDAD_Server.lua）
--
-- 這條是整個安全重構的收斂點：client 只能送四個純量，「誰在操作」由伺服器用連線
-- 反查（OnClientCommand 的第三參數），載具與物品一律用 id 在伺服器端重新解析。
-- =====================================================================
scenario("MP server：actor 取事件玩家（H1）、物品只認自己背包（H2）、有限 ID、節流、重播、失敗回報")

clientFlag, serverFlag = false, true
safehouseAllow = true
setSandbox({ InstallSkillGate = true })

local function mkActor(name)
    local p = newPlayer({ num = 5, electricity = 2, username = name })
    p:getInventory():AddItem(newScrewdriver(false))
    return p
end

-- OnClientCommand 簽名（module, command, player, args）＝ClientCommands.lua:1249-1260
local function rawDevice(player, args)
    fire("OnClientCommand", MOD_ID, MDAD.CMD_DEVICE, player, args)
end

-- 一般情境：先把時間推過 250ms 節流窗，再清觀測值
local function fireDevice(player, args)
    nowMs = nowMs + 300
    resetStats()
    rawDevice(player, args)
end

-- MDAD.isFiniteInt：vehicleId 與 itemId 共用的邊界判定
checkTrue(MDAD.isFiniteInt(0), "isFiniteInt：0")
checkTrue(MDAD.isFiniteInt(-3), "isFiniteInt：負整數")
checkTrue(MDAD.isFiniteInt(2147483647), "isFiniteInt：int 上限")
checkTrue(MDAD.isFiniteInt(3.0), "isFiniteInt：3.0 是整數值")
checkFalse(MDAD.isFiniteInt(1.5), "isFiniteInt：小數會被 Java 靜默截斷，擋掉")
checkFalse(MDAD.isFiniteInt(0 / 0), "isFiniteInt：NaN")
checkFalse(MDAD.isFiniteInt(math.huge), "isFiniteInt：+Inf")
checkFalse(MDAD.isFiniteInt(-math.huge), "isFiniteInt：-Inf")
checkFalse(MDAD.isFiniteInt("5"), "isFiniteInt：字串")
checkFalse(MDAD.isFiniteInt(nil), "isFiniteInt：nil")
checkFalse(MDAD.isFiniteInt(true), "isFiniteInt：boolean")

local pOwner = mkActor("owner")
local pIntruder = mkActor("intruder")
-- 兩位操作者也登記成玩家 slot：任何「跨玩家／跨背包找物品」的改動都會在這裡露餡
players[0], players[1] = pOwner, pIntruder
activePlayers = 2
local vTarget = mkVehicle()
it = newItem(GPS_T, { uses = 0.6, useDelta = 0.006 })
pOwner:getInventory():AddItem(it)

-- happy path：事件玩家用自己的 GPS 裝在自己搆得到的車上
fireDevice(pOwner, { vehicleId = vTarget:getId(), kind = "nav", install = true, itemId = it:getID() })
checkEq(stats.getVehicleById, 1, "server 用 vehicleId 重查載具")
checkEq(stats.itemById, 1, "server 用 itemId 在操作者背包樹重解析物品")
checkTrue(MDAD.isNavInstalled(vTarget), "OnClientCommand 走完整條鏈完成安裝")
checkNear(MDAD.getState(vTarget).navDelta, 0.6, EPS, "navDelta 由 server 讀實物")
checkFalse(pOwner:getInventory():contains(it), "物品從操作者背包移除")
checkEq(stats.sendRemoveItem, 1, "MP server 廣播移除")
checkEq(#sentServer, 0, "成功不回報失敗")

-- 重播：同一份 payload 再送一次（封包重放）
fireDevice(pOwner, { vehicleId = vTarget:getId(), kind = "nav", install = true, itemId = it:getID() })
checkEq(#sentServer, 1, "重播被拒並回報一則失敗")
checkEq(sentServer[1] and sentServer[1].command, MDAD.CMD_DEVICE_FAILED, "失敗回報用 DeviceFailed")
checkEq(sentServer[1] and sentServer[1].module, MOD_ID, "失敗回報帶 MOD_ID")
checkEq(sentServer[1] and sentServer[1].player, pOwner, "失敗回報送回事件玩家的連線")
checkEq(noteReason(sentServer[1] and sentServer[1].args.reason), ALREADY, "重播理由鍵是已安裝")
checkEq(sentServer[1] and sentServer[1].args.to, "owner", "回報帶 to（分割畫面要靠它定位）")
checkEq(stats.transmitModData, 0, "重播不再同步")
checkEq(stats.instanceItem, 0, "重播不生成道具")

-- H1：payload 宣稱的 actor 完全不算數，一律以事件玩家判定
-- 入侵者站得太遠，卻在 payload 裡指名搆得到的 owner，並指向 owner 的物品
veh = mkVehicle()
got = newItem(GPS_T, { uses = 0.9, useDelta = 0.006 })
pOwner:getInventory():AddItem(got)
pIntruder._square._canReach = false
fireDevice(pIntruder, {
    vehicleId = veh:getId(), kind = "nav", install = true, itemId = got:getID(),
    actor = pOwner, character = pOwner, username = "owner", player = pOwner,
})
checkFalse(MDAD.isNavInstalled(veh), "H1：payload 的 actor 不被採信，用事件玩家的可及性判定")
checkTrue(pOwner:getInventory():contains(got), "H1：別人背包的 GPS 沒被動")
checkEq(#sentServer, 1, "H1：回報一則失敗")
checkEq(noteReason(sentServer[1] and sentServer[1].args.reason), TOO_FAR, "H1：理由是事件玩家太遠")
checkEq(sentServer[1] and sentServer[1].args.to, "intruder", "H1：回報對象是事件玩家，不是 payload 宣稱的人")

-- H2：物品只能從事件玩家自己的背包樹解析，跨背包一律失敗
pIntruder._square._canReach = true
fireDevice(pIntruder, {
    vehicleId = veh:getId(), kind = "nav", install = true, itemId = got:getID(), actor = pOwner,
})
checkEq(stats.itemById, 1, "H2：只在事件玩家自己的背包樹找一次")
checkFalse(MDAD.isNavInstalled(veh), "H2：拿別人背包裡的 itemId 裝不起來")
checkTrue(pOwner:getInventory():contains(got), "H2：別人的 GPS 不會被消耗")
checkEq(stats.sendRemoveItem, 0, "H2：沒有任何物品被移除")
checkEq(noteReason(sentServer[1] and sentServer[1].args.reason), FAILED, "H2：理由是找不到物品")

-- 事件玩家用自己的物品：同一發 payload 就成立
it = newItem(GPS_T, { uses = 0.25, useDelta = 0.006 })
pIntruder:getInventory():AddItem(it)
fireDevice(pIntruder, {
    vehicleId = veh:getId(), kind = "nav", install = true, itemId = it:getID(), actor = pOwner,
})
checkTrue(MDAD.isNavInstalled(veh), "事件玩家用自己的 GPS：安裝成立")
checkNear(MDAD.getState(veh).navDelta, 0.25, EPS, "navDelta 取事件玩家實物的電量")
checkFalse(pIntruder:getInventory():contains(it), "消耗的是事件玩家自己的物品")
checkEq(#sentServer, 0, "成功不回報")

-- payload 夾帶 vehicle 物件：一律不看，只認 vehicleId 重查
st = mkVehicle()   -- 誘餌車
it = newItem(AUTO_T)
pIntruder:getInventory():AddItem(it)
fireDevice(pIntruder, {
    vehicleId = veh:getId(), kind = "auto", install = true, itemId = it:getID(),
    vehicle = st, partId = 3, navDelta = 1.0, state = { nav = true, auto = true },
})
checkTrue(MDAD.isAutoInstalled(veh), "只認 vehicleId 指到的車")
checkNil(MDAD.getState(st), "payload 夾帶的誘餌車完全沒被碰")
checkNear(MDAD.getState(veh).navDelta, 0.25, EPS, "payload 的 navDelta 不被採用（維持實物讀到的值）")

-- vehicleId 查不到：靜默早退，連失敗都不回（避免變成 id 探測 oracle）
fireDevice(pOwner, { vehicleId = 999999, kind = "nav", install = true, itemId = 1 })
checkEq(stats.getVehicleById, 1, "查不到的 id 也只查一次")
checkEq(stats.itemById, 0, "查不到載具就不再解析物品")
checkEq(#sentServer, 0, "查不到載具靜默早退")

-- vehicleId 非有限整數：不得進 Java 的 getVehicleById
for _, ok in ipairs({ 1.5, 0 / 0, math.huge, -math.huge }) do
    fireDevice(pOwner, { vehicleId = ok, kind = "nav", install = true, itemId = 1 })
    checkEq(stats.getVehicleById, 0, "vehicleId 非有限整數（" .. tostring(ok) .. "）：不呼叫 getVehicleById")
    checkEq(#sentServer, 0, "vehicleId 非有限整數：不回報")
end
fireDevice(pOwner, { vehicleId = "1", kind = "nav", install = true, itemId = 1 })
checkEq(stats.getVehicleById, 0, "vehicleId 是字串：不呼叫 getVehicleById")
fireDevice(pOwner, { kind = "nav", install = true, itemId = 1 })
checkEq(stats.getVehicleById, 0, "沒有 vehicleId：不呼叫 getVehicleById")
fireDevice(pOwner, "not a table")
checkEq(stats.getVehicleById, 0, "args 不是 table：早退")
fireDevice(pOwner, nil)
checkEq(stats.getVehicleById, 0, "args 為 nil：早退")

-- module／player／未知 command
nowMs = nowMs + 300
resetStats()
fire("OnClientCommand", "SomeOtherMod", MDAD.CMD_DEVICE, pOwner,
    { vehicleId = vTarget:getId(), kind = "nav", install = false })
checkEq(stats.getVehicleById, 0, "別的 module 的指令不處理")
fire("OnClientCommand", MOD_ID, MDAD.CMD_DEVICE, nil,
    { vehicleId = vTarget:getId(), kind = "nav", install = false })
checkEq(stats.getVehicleById, 0, "沒有 player 的指令不處理")
fire("OnClientCommand", MOD_ID, "TotallyUnknown", pOwner, {})
fire("OnClientCommand", MOD_ID, 12345, pOwner, {})
checkEq(stats.getVehicleById, 0, "未知 command 不處理")
-- 未知 command 若寫進節流表，任意偽造字串就能吃掉緊接著的合法指令（也是記憶體 DoS）
rawDevice(pOwner, { vehicleId = vTarget:getId(), kind = "nav", install = false })
checkEq(stats.getVehicleById, 1, "未知 command 不進節流表，不影響緊接著的合法指令")

-- 節流：per-player、250ms
veh = mkVehicle()
it = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
pOwner:getInventory():AddItem(it)
local payload = { vehicleId = veh:getId(), kind = "nav", install = false }
nowMs = nowMs + 300
resetStats()
rawDevice(pOwner, payload)
checkEq(stats.getVehicleById, 1, "節流窗外的第一發放行")
nowMs = nowMs + 249
rawDevice(pOwner, payload)
checkEq(stats.getVehicleById, 1, "249ms 內的第二發被節流掉（連載具都不查）")
nowMs = nowMs + 1
rawDevice(pOwner, payload)
checkEq(stats.getVehicleById, 2, "距上一發滿 250ms 後放行")
resetStats()
rawDevice(pOwner, payload)
checkEq(stats.getVehicleById, 0, "同一玩家立刻連發：被節流")
rawDevice(pIntruder, payload)
checkEq(stats.getVehicleById, 1, "節流是 per-player：別的玩家不受影響")

-- 被節流時不得回報失敗（否則偽造封包可以反覆逼伺服器發包）
resetStats()
rawDevice(pOwner, payload)
checkEq(#sentServer, 0, "被節流的指令不回報失敗")

-- =====================================================================
-- 情境十五：client/MDAD_Client.lua（nav gate 註冊、失敗提示、右鍵選單）
-- =====================================================================
scenario("client：nav gate 註冊契約、API 缺失每 slot 提示一次、右鍵選項與排入的動作參數")

clientFlag, serverFlag = true, false
setSandbox({ InstallSkillGate = true, NeedItemForNav = false })

-- 載入期就試過一次；主 MOD 不在時要留下 console 診斷
checkTrue(logHas(clientLoadLog, "registerNavGate failed: nav API missing"),
    "載入期註冊失敗會 print 診斷")
checkTrue(logHas(clientLoadLog, MOD_ID), "診斷帶 MOD 名稱前綴")

local pc0 = newPlayer({ num = 0, electricity = 2, username = "slot0" })
local pc1 = newPlayer({ num = 1, electricity = 2, username = "slot1" })
players[0], players[1], players[2], players[3] = pc0, pc1, nil, nil
activePlayers = 2

-- option 關閉時閘門本來就永遠放行，註冊失敗無感：不提示
local log
resetStats()
log = capturePrint(function() fire("OnGameStart") end)
checkEq(#halos, 0, "NeedItemForNav=false 時註冊失敗不提示（避免無意義紅字）")
checkTrue(logHas(log, "nav API missing"), "仍留下 console 診斷")

-- option 開啟：每個本機 slot 各提示一次
setSandbox({ InstallSkillGate = true, NeedItemForNav = true })
resetStats()
capturePrint(function() fire("OnCreatePlayer", 1) end)
checkEq(#halos, 1, "分割畫面第二位玩家上線：提示一次")
checkEq(halos[1] and halos[1].player, pc1, "提示掛在該 slot 的玩家身上")
checkEq(noteReason(halos[1] and halos[1].text), NAV_API_MISSING, "提示用 NavApiMissing 翻譯鍵")
resetStats()
capturePrint(function() fire("OnCreatePlayer", 1) end)
checkEq(#halos, 0, "同一個 slot 不重複提示")

resetStats()
capturePrint(function() fire("OnGameStart") end)
checkEq(#halos, 1, "OnGameStart 只補提示還沒提示過的 slot")
checkEq(halos[1] and halos[1].player, pc0, "補提示的是 slot 0")

-- API 版本太舊：視同未安裝，連 registerNavGate 都不呼叫
local apiCalls = { n = 0 }
MinidoracatMiniMapAPI = {
    navApiVersion = 0,
    registerNavGate = function(owner, fn)
        apiCalls.n = apiCalls.n + 1
        apiCalls.owner = owner
        apiCalls.fn = fn
        return true
    end,
}
players[2] = newPlayer({ num = 2, username = "slot2" })
activePlayers = 3
resetStats()
log = capturePrint(function() fire("OnGameStart") end)
checkEq(apiCalls.n, 0, "navApiVersion < 1：不呼叫 registerNavGate")
checkTrue(logHas(log, "nav API missing"), "版本太舊視同 API 缺失")
checkEq(#halos, 1, "新 slot 仍會收到提示")

-- API 在但註冊被拒：獨立診斷，且仍算沒掛上
MinidoracatMiniMapAPI.navApiVersion = 1
MinidoracatMiniMapAPI.registerNavGate = function(owner, fn)
    apiCalls.n = apiCalls.n + 1
    apiCalls.owner = owner
    apiCalls.fn = fn
    return false
end
players[3] = newPlayer({ num = 3, username = "slot3" })
activePlayers = 4
resetStats()
log = capturePrint(function() fire("OnGameStart") end)
checkEq(apiCalls.n, 1, "版本夠新就會呼叫 registerNavGate")
checkEq(apiCalls.owner, MOD_ID, "註冊時帶自己的 owner id")
checkEq(apiCalls.fn, MDAD.navGate, "註冊時交出的就是 production 的 MDAD.navGate")
checkTrue(logHas(log, "nav gate NOT installed"), "註冊被拒有獨立診斷（與 API 缺失分得開）")
checkEq(#halos, 1, "註冊被拒也提示新 slot")

-- 註冊成功
MinidoracatMiniMapAPI.registerNavGate = function(owner, fn)
    apiCalls.n = apiCalls.n + 1
    apiCalls.owner = owner
    apiCalls.fn = fn
    return true
end
players[4] = newPlayer({ num = 4, username = "slot4" })
activePlayers = 5
resetStats()
log = capturePrint(function() fire("OnGameStart") end)
checkEq(apiCalls.n, 2, "重試時再呼叫一次")
checkEq(apiCalls.owner, MOD_ID, "成功註冊帶的 owner")
checkEq(apiCalls.fn, MDAD.navGate, "成功註冊交出的就是 production 的 MDAD.navGate")
checkEq(#halos, 0, "註冊成功後不提示")
checkEq(#log, 0, "註冊成功不印診斷")

resetStats()
capturePrint(function() fire("OnGameStart") end)
checkEq(apiCalls.n, 2, "已註冊就不重複註冊（navGateReady 早退）")
players[5] = newPlayer({ num = 5, username = "slot5" })
activePlayers = 6
resetStats()
capturePrint(function() fire("OnCreatePlayer", 5) end)
checkEq(#halos, 0, "註冊成功後新 slot 也不提示")

-- 遠端失敗提示：以 args.to 定位本機玩家（分割畫面共用一條連線）
resetStats()
fire("OnServerCommand", MOD_ID, MDAD.CMD_DEVICE_FAILED, { reason = TOO_FAR, to = "slot1" })
checkEq(#halos, 1, "伺服器回報失敗：提示一次")
checkEq(halos[1] and halos[1].player, pc1, "以 to（角色名）掛到正確的本機玩家")
checkEq(noteReason(halos[1] and halos[1].text), TOO_FAR, "提示內容是伺服器回的理由鍵")

resetStats()
fire("OnServerCommand", "SomeOtherMod", MDAD.CMD_DEVICE_FAILED, { reason = TOO_FAR, to = "slot1" })
fire("OnServerCommand", MOD_ID, "SomethingElse", { reason = TOO_FAR, to = "slot1" })
fire("OnServerCommand", MOD_ID, MDAD.CMD_DEVICE_FAILED, "not a table")
fire("OnServerCommand", MOD_ID, MDAD.CMD_DEVICE_FAILED, { reason = 42, to = "slot1" })
fire("OnServerCommand", MOD_ID, MDAD.CMD_DEVICE_FAILED, { reason = TOO_FAR })
fire("OnServerCommand", MOD_ID, MDAD.CMD_DEVICE_FAILED, { reason = TOO_FAR, to = "nobody" })
checkEq(#halos, 0, "module／command／欄位型別／收件人不符時一律不提示")

-- ===== 右鍵選單 =====
-- 缺項時回一個空殼而不是 nil：選項／佇列被改沒了時，斷言要一條一條乾淨地失敗，
-- 而不是在第一個 nil 索引就把整份 harness 炸掉（那會蓋掉後面所有防護）
local EMPTY_OPT = { args = table.pack(), fn = function() end }
local EMPTY_MT = { __index = function() return EMPTY_OPT end }

local function newContext()
    local c = { options = setmetatable({}, EMPTY_MT) }
    function c:addOption(name, target, fn, ...)
        local o = { name = name, target = target, fn = fn, args = table.pack(...) }
        rawset(self.options, #self.options + 1, o)
        return o
    end
    return c
end

local function at(list, i) return list[i] or EMPTY_OPT end

local function invoke(o)
    return o.fn(o.target, table.unpack(o.args, 1, o.args.n))
end

local ctx, opt
ch = pc0
ch:getInventory():AddItem(newScrewdriver(false))
veh = mkVehicle()
ch._near = veh
pickedVehicle = nil
JoypadState.players = {}

-- 引擎兩段式呼叫：test 階段只是問「有沒有東西可加」，不得真的加
ctx = newContext()
resetStats()
fire("OnFillWorldObjectContextMenu", 0, ctx, {}, true)
checkEq(#ctx.options, 0, "test 階段不加任何選項")
checkEq(stats.pickVehicle, 0, "test 階段連車輛都不找")

ch._near = nil
ctx = newContext()
fire("OnFillWorldObjectContextMenu", 0, ctx, {}, false)
checkEq(#ctx.options, 0, "找不到車輛：不加選項")
ch._near = veh

ctx = newContext()
fire("OnFillWorldObjectContextMenu", 0, ctx, {}, false)
checkEq(#ctx.options, 0, "背包沒有 GPS／自駕模組：不出現安裝選項")

it = newItem(GPS_T, { uses = 0.8, useDelta = 0.006 })
ch:getInventory():AddItem(it)
ctx = newContext()
fire("OnFillWorldObjectContextMenu", 0, ctx, {}, false)
checkEq(#ctx.options, 1, "有 GPS：出現一個安裝選項")
opt = ctx.options[1]
checkEq(opt.name, "UI_MinidoracatAutoDrive_InstallGPS", "選項標題用安裝 GPS 的翻譯鍵")
checkNil(opt.notAvailable, "條件齊備時選項可用")
checkEq(opt.target, ch, "選項的 target 是操作者")
checkEq(opt.args.n, 4, "選項帶四個參數（vehicle, kind, install, item）")
checkEq(opt.args[1], veh, "選項帶目標車輛")
checkEq(opt.args[2], "nav", "選項帶 kind=nav")
checkEq(opt.args[3], true, "選項帶 install=true")
checkEq(opt.args[4], it, "選項帶背包裡的那顆 GPS")

resetStats()
invoke(opt)
checkEq(#uiCalls.exit, 0, "沒坐在這輛車上：不呼叫 onExit")
checkEq(#uiCalls.toInventory, 1, "安裝前先把物品收進玩家背包")
checkEq(at(uiCalls.toInventory, 1).item, it, "收的是選中的那顆 GPS")
checkEq(#uiCalls.equip, 1, "自動裝備螺絲刀")
checkEq(at(uiCalls.equip, 1).player, ch, "裝備的對象是操作者")
checkTrue(at(uiCalls.equip, 1).item ~= nil and at(uiCalls.equip, 1).item:hasTag("SCREWDRIVER"),
    "裝備的是螺絲刀")
checkEq(#uiCalls.queue, 1, "沒有 area 時只排一個動作")
act = at(uiCalls.queue, 1)
checkEq(act.Type, "ISAutoDriveDeviceAction", "排進去的是 ISAutoDriveDeviceAction")
checkEq(act.character, ch, "動作的 character 是操作者")
checkEq(act.vehicle, veh, "動作的 vehicle 是目標車")
checkEq(act.kind, "nav", "動作的 kind")
checkEq(act.install, true, "動作的 install")
checkEq(act.item, it, "動作的 item")

-- 有電瓶艙 area：先排走過去的 pathfind，再排安裝
veh = newVehicle({ battery = newItem("Base.CarBattery", { uses = 0.8 }), area = "engine", inArea = true })
ch._near = veh
ctx = newContext()
fire("OnFillWorldObjectContextMenu", 0, ctx, {}, false)
resetStats()
invoke(ctx.options[1])
checkEq(#uiCalls.queue, 2, "有 area：先排 pathToVehicleArea 再排安裝")
checkEq(at(uiCalls.queue, 1)._kind, "pathToVehicleArea", "第一個是走到電瓶艙的 pathfind")
checkEq(at(uiCalls.queue, 1).area, "engine", "pathfind 帶 part 的 area")
checkEq(at(uiCalls.queue, 1).vehicle, veh, "pathfind 帶目標車")
checkEq(at(uiCalls.queue, 2).Type, "ISAutoDriveDeviceAction", "第二個才是安裝動作")

-- 坐在目標車上：先下車
ch._vehicle = veh
ctx = newContext()
fire("OnFillWorldObjectContextMenu", 0, ctx, {}, false)
resetStats()
invoke(ctx.options[1])
checkEq(#uiCalls.exit, 1, "坐在目標車上：先呼叫 onExit 下車")
checkEq(at(uiCalls.exit, 1), ch, "下車的是操作者")
ch._vehicle = nil

-- 被 deviceBlockReason 擋下的選項要置灰＋掛 tooltip（slot1 沒有螺絲刀）
pc1:getInventory():AddItem(newItem(GPS_T, { uses = 0.5, useDelta = 0.006 }))
pc1._near = veh
ctx = newContext()
fire("OnFillWorldObjectContextMenu", 1, ctx, {}, false)
checkEq(#ctx.options, 1, "沒工具時選項仍然出現（但要置灰）")
checkTrue(ctx.options[1].notAvailable, "沒螺絲刀：選項置灰")
checkEq(noteReason(ctx.options[1].toolTip and ctx.options[1].toolTip.description), NO_TOOL,
    "tooltip 說明缺工具")

-- 已安裝：改出卸載選項，且不帶 item
st = MDAD.ensureState(veh:getBattery())
st.nav = true
st.auto = true
ctx = newContext()
fire("OnFillWorldObjectContextMenu", 0, ctx, {}, false)
checkEq(#ctx.options, 2, "nav 與 auto 都已安裝：兩個卸載選項")
checkEq(ctx.options[1].name, "UI_MinidoracatAutoDrive_UninstallGPS", "第一個是卸載 GPS")
checkEq(ctx.options[1].args[2], "nav", "卸載選項的 kind=nav")
checkEq(ctx.options[1].args[3], false, "卸載選項 install=false")
checkNil(ctx.options[1].args[4], "卸載選項不帶 item")
checkEq(ctx.options[2].name, "UI_MinidoracatAutoDrive_UninstallAuto", "第二個是卸載自駕模組")
checkEq(ctx.options[2].args[2], "auto", "卸載選項的 kind=auto")
checkEq(ctx.options[2].args[3], false, "卸載 auto 的 install=false")

resetStats()
invoke(ctx.options[1])
checkEq(#uiCalls.toInventory, 0, "卸載沒有來源物品：不呼叫 toPlayerInventory")
act = at(uiCalls.queue, #uiCalls.queue)
checkEq(act.kind, "nav", "排進去的卸載動作 kind=nav")
checkEq(act.install, false, "排進去的卸載動作 install=false")
checkNil(act.item, "排進去的卸載動作沒有 item")

-- 目標車輛的取得順序
st.nav = nil
st.auto = nil
JoypadState.players[1] = {}
pickedVehicle = mkVehicle()
ctx = newContext()
resetStats()
fire("OnFillWorldObjectContextMenu", 0, ctx, {}, false)
checkEq(stats.pickVehicle, 0, "手把模式沒有游標：不做滑鼠拾取")
checkEq(ctx.options[1].args[1], veh, "手把模式退回 getUseableVehicle／getNearVehicle")

JoypadState.players[1] = nil
ctx = newContext()
resetStats()
fire("OnFillWorldObjectContextMenu", 0, ctx, {}, false)
checkEq(stats.pickVehicle, 1, "鍵鼠模式會嘗試滑鼠拾取")
checkEq(ctx.options[1].args[1], pickedVehicle, "滑鼠拾取到的車優先於 getNearVehicle")
pickedVehicle = nil

ch._vehicle = veh
ctx = newContext()
resetStats()
fire("OnFillWorldObjectContextMenu", 0, ctx, {}, false)
checkEq(stats.pickVehicle, 0, "人在車上時直接用該車，不做滑鼠拾取")
checkEq(ctx.options[1].args[1], veh, "人在車上：目標就是所在的車")
ch._vehicle = nil

clientFlag, serverFlag = false, true

-- =====================================================================
-- 情境十六：理由鍵不得缺翻譯（鍵是 runtime 真的吐出來的，不是抄原始碼）
-- =====================================================================
scenario("理由鍵覆蓋：每個分支都跑到，且四語 UI.json 都有對應翻譯")

checkEq(type(MDAD), "table", "production MDAD.lua 真的載入了")
checkEq(type(MDAD_Recipe), "table", "production MDAD_Recipe.lua 真的載入了")
checkEq(type(ISAutoDriveDeviceAction), "table", "production TimedAction 真的載入了")
checkEq(MDAD.MOD_ID, MOD_ID, "MOD_ID 常數")
checkEq(MDAD.TYPE_GPS, GPS_T, "TYPE_GPS 與 items 腳本一致")
checkEq(MDAD.TYPE_AUTO, AUTO_T, "TYPE_AUTO 與 items 腳本一致")
checkEq(MDAD.CMD_DEVICE, "Device", "CMD_DEVICE 常數（client／server 共用的封包名）")
checkEq(MDAD.CMD_DEVICE_FAILED, "DeviceFailed", "CMD_DEVICE_FAILED 常數")
checkEq(MDAD.FAIL_GENERIC, FAILED, "FAIL_GENERIC 常數")
checkEq(MDAD.FAIL_NO_BATTERY, NO_BATTERY, "FAIL_NO_BATTERY 常數")
checkEq(MDAD.FAIL_TOO_FAR, TOO_FAR, "FAIL_TOO_FAR 常數")

-- server／client 檔真的被執行過：兩者都在載入時掛了事件
checkTrue(#(eventHandlers["OnClientCommand"] or {}) > 0, "server/MDAD_Server.lua 掛上了 OnClientCommand")
checkTrue(#(eventHandlers["OnFillWorldObjectContextMenu"] or {}) > 0,
    "client/MDAD_Client.lua 掛上了 OnFillWorldObjectContextMenu")
checkTrue(#(eventHandlers["OnServerCommand"] or {}) > 0, "client 掛上了 OnServerCommand 失敗回報")
checkTrue(#(eventHandlers["OnGameStart"] or {}) > 0, "client 掛上了 OnGameStart 重試註冊")
checkTrue(#(eventHandlers["OnCreatePlayer"] or {}) > 0, "client 掛上了 OnCreatePlayer")

-- 距離判定的絆線：整份測試（含 apply／server／client 全鏈）都不該碰 DistToSquared
checkEq(distCalls, 0, "全程沒有任何程式碼呼叫 DistToSquared（距離 fallback 不得復活）")

-- 這些鍵必須在前面的情境中「真的被 production 回傳過」，
-- 否則代表某條分支根本沒被執行到（測試自己失去防護力）
local EXPECT_KEYS = {
    "UI_MinidoracatAutoDrive_NeedGPS",
    "UI_MinidoracatAutoDrive_InstallFailed",
    "UI_MinidoracatAutoDrive_NoBattery",
    "UI_MinidoracatAutoDrive_NoScrewdriver",
    "UI_MinidoracatAutoDrive_NeedElectricity1",
    "UI_MinidoracatAutoDrive_AlreadyInstalled",
    "UI_MinidoracatAutoDrive_TooFar",
    "UI_MinidoracatAutoDrive_NavApiMissing",
    "UI_MinidoracatAutoDrive_InstallGPS",
    "UI_MinidoracatAutoDrive_InstallAuto",
    "UI_MinidoracatAutoDrive_UninstallGPS",
    "UI_MinidoracatAutoDrive_UninstallAuto",
}
for _, ok in ipairs(EXPECT_KEYS) do
    check(reasonKeys[ok] == true, "分支有被執行到並吐出 " .. ok)
end

local function readFile(rel)
    for _, root in ipairs(ROOTS) do
        local fh = io.open(root .. rel, "r")
        if fh then
            local text = fh:read("*a")
            fh:close()
            return text
        end
    end
    return nil
end

-- 排序輸出，讓失敗訊息可重現
local emitted = {}
for ok in pairs(reasonKeys) do emitted[#emitted + 1] = ok end
table.sort(emitted)

for _, ok in ipairs({ "EN", "CH", "CN", "JP" }) do
    it = readFile(MEDIA .. "/shared/Translate/" .. ok .. "/UI.json")
    if check(it ~= nil, ok .. "/UI.json 讀得到") then
        for _, reason in ipairs(emitted) do
            check(it:find('"' .. reason .. '"', 1, true) ~= nil,
                ok .. "/UI.json 缺翻譯鍵 " .. reason)
        end
    end
end

-- =====================================================================
-- 總結
-- =====================================================================
closeScenario()
print()
print("情境 " .. scenarios .. " 個、斷言 " .. assertions .. " 項")
if failures > 0 then
    print(failures .. " 項失敗")
    os.exit(1)
end
print("全部通過")
