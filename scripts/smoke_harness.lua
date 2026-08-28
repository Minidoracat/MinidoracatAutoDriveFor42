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
    shared/MDAD_Follower.lua
    shared/TimedActions/ISAutoDriveDeviceAction.lua
    server/Items/MDAD_Distributions.lua
    server/MDAD_Server.lua
    client/MDAD_Client.lua
    client/MDAD_Driver.lua

三條派送路徑都走真的程式碼，不再測早已不存在的 complete()：
- SP：TimedAction:perform() → MDAD.applyDeviceChange（同 process 直接突變）
- MP client：TimedAction:perform() → sendClientCommand（只送四個純量，本地不突變）
- MP server：Events.OnClientCommand → MDAD_Server → MDAD.applyDeviceChange
  （actor 取事件第三參數，不採 payload；vehicleId／itemId 一律重新解析）
單一 process 靠切換 isClient()／isServer() 假旗標模擬三種佈署。

M3 自駕核心（client/MDAD_Driver.lua）走的是**每幀熱路徑**，斷言的重點與上面三條
派送路徑不同——它的回歸不會丟例外，只會讓玩家的車撞牆或掉 FPS：
- 假的 BaseVehicle 向量池會記帳（alloc／release／水位／重複 release），
  addImpulse 記錄「同一幀被呼叫幾次」——單槽陷阱（BaseVehicle.java:678-689）
  同幀第二次呼叫會讓整幀不施力，只有計數器抓得到
- 沒有人在自駕時，OnPlayerUpdate 用一顆絆線玩家（任何方法被呼叫都計數）證明
  「零 Java 呼叫」
- 力矩由 relPos × impulse 就地算出來，斷言的是**符號關係**（誤差反號→力矩反號、
  幀奇偶讓中心力反號但力矩同向），不抄 production 的力學係數
- 衝量的**量級**另外圈區間（推得動 1200kg／不甩尾、隨速度單調且會封頂）：符號全對
  但推力小兩個數量級＝實機「按了自駕卻完全不轉彎」，符號斷言一條都抓不到
- 診斷輸出（getDebug()）：關閉時 print 與 string.format 的呼叫數必須都是 0，
  開啟時跟線遙測每秒只有一行——每幀一行會洗爆 console 也吃 FPS

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

-- M3 自駕的觀測面。全部掛在一顆 table 上有兩個理由：一是「哪些是自駕核心的
-- 觀測點」一目了然；二是本檔主 chunk 的 local 數量已經接近 Lua 的 200 個上限，
-- 再往上堆扁平 local 會直接編不過。
local drive = {
    -- BaseVehicle 的 thread-local 向量池水位（BaseVehicle.java:507-521）。
    -- live（沒還回來的顆數）與 bad（還了一顆不在手上的向量）是累積證據，
    -- 刻意不隨觀測窗歸零，才能在收尾一次證明全程都沒發生。
    pool = { alloc = 0, release = 0, live = 0, bad = 0 },
    free = {},                -- 已回收、可再發的向量（引擎的池也會重複發同一顆）
    mult = 1.6,               -- getGameTime():getMultiplier()；1.6＝30fps 基準
    keys = {},                -- isKeyDown（Left／Right／Forward／Backward／Brake）
    -- getTexture：完整 media 路徑刻意查不到，逼 production 走無路徑的退路
    textures = { ["Item_AutopilotModule"] = "tex:AutopilotModule" },
    texCalls = {},            -- getTexture 的查詢序列（證明先試完整路徑、且只查一次）
    menus = {},               -- getPlayerRadialMenu
    orig = { n = 0 },         -- 原版 ISVehicleMenu.showRadialMenu 被呼叫幾次
    paused = false,            -- UIManager speedControls：true 模擬遊戲暫停
    -- 主 MOD 導航查詢面的可控狀態：tx 為 nil＝地圖上沒有目標
    nav = { targetCalls = 0, routeCalls = 0, tx = nil, ty = nil, route = nil, state = "ok" },
    calls = {
        setRegulator = 0, regulatorOn = 0, regulatorOff = 0,
        setRegulatorSpeed = 0, maxRegSpeed = 0, badRegSpeed = 0,
        forceBrake = 0, getForwardVector = 0,
    },
    -- 每幀不變式的違規計數＋首次違規的幀號（0＝沒有違規）
    bad = { impulse = 0, atImpulse = 0, pair = 0, atPair = 0, live = 0, atLive = 0 },
    frames = 0,
    trip = { n = 0 },
    spy = { begin = 0, reset = 0, control = 0 },
    -- 診斷輸出的觀測面：debug＝getDebug() 回什麼、logs＝熱路徑攔下來的 print 行、
    -- fmt＝string.format 被呼叫幾次（關閉診斷時連字串都不該生成，計數是唯一證據）
    debug = false,
    logs = {},
    fmt = 0,
}

-- 絆線玩家：任何方法被呼叫都計數。用來證明「沒有人在自駕時 OnPlayerUpdate 連玩家
-- 都不碰」——這是熱路徑第一鐵則（sessionCount == 0 一次整數比較就 return），
-- 少了它每幀會多好幾次跨 Lua↔Java 邊界的呼叫，而且不會有任何錯誤訊息。
drive.tripPlayer = setmetatable({}, {
    __index = function()
        return function()
            drive.trip.n = drive.trip.n + 1
            return nil
        end
    end,
})

-- 網路與 UI 的觀測佇列
local sentClient = {}    -- sendClientCommand（client → server）
local sentServer = {}    -- sendServerCommand（server → client）
local halos = {}         -- HaloTextHelper.addBadText／addGoodText（kind 分紅綠字）
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

-- HaloTextHelper.addBadText 用例 ISVehiclePartMenu.lua:252；addGoodText 用例
-- ISReadABook.lua:95。kind 一起記下來：自駕的「讓位／抵達／啟動」是綠字，
-- 失效停止才是紅字，兩者互換是實際的 UX 回歸。
HaloTextHelper = {
    addBadText = function(playerObj, text)
        halos[#halos + 1] = { player = playerObj, text = text, kind = "bad" }
    end,
    addGoodText = function(playerObj, text)
        halos[#halos + 1] = { player = playerObj, text = text, kind = "good" }
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

-- =====================================================================
-- M3 自駕核心用到的假 PZ 全域
-- =====================================================================

-- Vector3f 的最小面：driver 只用 set／x／y／z
local function newVec3()
    local v = { _x = 0, _y = 0, _z = 0, _held = false }
    function v:set(x, y, z)
        self._x, self._y, self._z = x, y, z
        return self
    end
    function v:x() return self._x end
    function v:y() return self._y end
    function v:z() return self._z end
    return v
end

-- BaseVehicle.allocVector3f／releaseVector3f＝BaseVehicle.java:507-521。
-- 引擎的池是 thread-local 且回收後會再發同一顆，這裡照樣重複發——這樣
-- 「用了一顆已經 release 的向量」才會被 addImpulse 的 _held 檢查抓到。
BaseVehicle = {
    allocVector3f = function()
        local p = drive.pool
        p.alloc = p.alloc + 1
        p.live = p.live + 1
        local v = table.remove(drive.free) or newVec3()
        v._held = true
        return v:set(0, 0, 0)
    end,
    releaseVector3f = function(v)
        local p = drive.pool
        p.release = p.release + 1
        -- 還一顆不在手上的向量＝把別人正在用的格子讓出去（引擎會靜靜地壞掉）
        if type(v) ~= "table" or v._held ~= true then
            p.bad = p.bad + 1
            return
        end
        v._held = false
        p.live = p.live - 1
        drive.free[#drive.free + 1] = v
    end,
}

-- getGameTime():getMultiplier()＝真實秒數係數；driver 用 /48 換 dt，也用它縮放施力
local gameTime = {}
function gameTime:getMultiplier() return drive.mult end
function getGameTime() return gameTime end

-- UIManager.getSpeedControls：radial wrapper 用呼叫前狀態區分 open／close，另擋暫停。
UIManager = {
    getSpeedControls = function()
        return {
            getCurrentGameSpeed = function()
                if drive.paused then return 0 end
                return 1
            end,
        }
    end,
}

-- isKeyDown(bindingName)：driver 讀的就是 CarController.java:938-942 那幾個綁定名
function isKeyDown(name) return drive.keys[name] == true end

-- getDebug()＝Core 的除錯模式旗標（原版各處拿它守門診斷輸出）。driver 的遙測全部
-- 掛在它下面，所以情境可以直接切換來驗「關閉時是零成本」。
function getDebug() return drive.debug == true end

-- string.format 的絆線：關閉診斷時 driver 連字串都不該生成。print 只證明「沒印出來」，
-- 抓不到「算了一整條格式字串然後丟掉」——那在每幀熱路徑上一樣是成本。
-- 本 harness 與其他 production 檔都不用 string.format，計數乾淨。
local realFormat = string.format
string.format = function(...)
    drive.fmt = drive.fmt + 1
    return realFormat(...)
end

-- 材質缺漏時 getTexture 回 nil（RadialMenu.java:144-145 有 null 檢查）
function getTexture(name)
    drive.texCalls[#drive.texCalls + 1] = name
    return drive.textures[name]
end

-- getPlayerRadialMenu(playerNum)＝ISPlayerData.lua:143-152。初始不可見；_delayVisible
-- 模擬 UIManager.AddUI 後同一 call stack 尚未回報 really-visible 的實機時序。
local function newRadialMenu()
    local m = { slices = {}, _visible = false, _delayVisible = false }
    function m:isReallyVisible() return self._visible end
    -- addSlice(text, texture, command, arg1..arg6)＝ISRadialMenu.lua:44-52
    function m:addSlice(text, texture, command, arg1)
        self.slices[#self.slices + 1] =
            { text = text, texture = texture, command = command, arg1 = arg1 }
    end
    return m
end

function getPlayerRadialMenu(playerNum) return drive.menus[playerNum] end

-- 原版 showRadialMenu：暫停時早退；原本可見時這次是 toggle-close；open 才
-- clear→建片→addToUIManager。_delayVisible 只延後 visibility 回報，不影響片建立。
ISVehicleMenu.showRadialMenu = function(playerObj)
    drive.orig.n = drive.orig.n + 1
    drive.orig.player = playerObj
    local menu = playerObj and getPlayerRadialMenu(playerObj:getPlayerNum())
    if not menu then return end
    if drive.paused then return end
    if menu._visible then
        menu._visible = false
        return
    end
    clearList(menu.slices)
    menu.slices[1] = { text = "VANILLA" }
    menu._visible = menu._delayVisible ~= true
end

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

-- opts: num、electricity、z、instant、username、remote（isLocalPlayer 回 false）
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
        -- 伺服器端與遠端玩家的 isLocalPlayer 恆 false（IsoPlayer.java:6493）：
        -- 自駕只在駕駛自己的 client 跑，這個旗標是那條早退的唯一入口
        _local = opts.remote ~= true,
        removedFromHands = 0,
        faced = 0,
    }
    function p:getInventory() return self._inv end
    function p:getPerkLevel(perk)
        if perk == Perks.Electricity then return self._perk end
        return 0
    end
    function p:getVehicle() return self._vehicle end
    function p:isLocalPlayer() return self._local == true end
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

-- opts: battery、noBattery、area、inArea、z、engineRunning，
--       以下為 M3 自駕：x／y（世界座標）、fwdX／fwdY（車頭前向）、speed（km/h，
--       有號）、mass、steering（getCurrentSteering）、stopped、driver（isDriver 認的人）
local function newVehicle(opts)
    opts = opts or {}
    local v = {
        _id = nextVehicleId,
        _part = (not opts.noBattery) and newBatteryPart(opts.battery, opts.area) or nil,
        _z = opts.z or 0,
        _engine = opts.engineRunning == true,
        _inArea = opts.inArea == true,
        _square = newSquare(),
        -- 自駕控制面
        _x = opts.x or 0,
        _y = opts.y or 0,
        _fwdX = opts.fwdX or 1,
        _fwdY = opts.fwdY or 0,
        _speed = opts.speed or 0,
        _mass = opts.mass or 1200,
        _steering = opts.steering or 0,
        _stopped = opts.stopped == true,
        _driver = opts.driver,
        _regulator = nil,
        _regSpeed = nil,
        -- 每幀施力的帳：frame＝本幀次數、max＝觀測窗內單幀最高、total＝總次數
        _imp = { frame = 0, max = 0, total = 0, useAfterRelease = 0 },
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

    -- isDriver(chr) ⇔ getSeat(chr)==0（BaseVehicle.java:1853-1864）
    function v:isDriver(chr) return self._driver ~= nil and self._driver == chr end
    function v:getX() return self._x end
    function v:getY() return self._y end
    function v:getMass() return self._mass end
    -- getCurrentSpeedKmHour 可負（倒車）＝BaseVehicle.java:4268
    function v:getCurrentSpeedKmHour() return self._speed end
    -- getCurrentSteering 由 CarController 每幀從 clientControls 寫入（:321）
    function v:getCurrentSteering() return self._steering end
    -- isStopped＝|速度|<0.8 且沒踩油門（BaseVehicle.java:4259-4260）
    function v:isStopped() return self._stopped end

    -- getForwardVector(out)＝BaseVehicle.java:4242-4244：寫進呼叫端給的容器。
    -- Bullet 的 y 是上方向，世界 (X,Y) 對應 (x,z)（CarController.java:406,416 同讀法）
    function v:getForwardVector(out)
        drive.calls.getForwardVector = drive.calls.getForwardVector + 1
        return out:set(self._fwdX, 0, self._fwdY)
    end

    -- addImpulse(impulse, relPos)＝BaseVehicle.java:678-689／3311-3313。**單槽**：
    -- 同幀第二次呼叫且新向量較長時會 enable=false 並把常駐向量推回池，結果是這幀
    -- 完全不施力還汙染下一幀。只記錄次數與向量，讓斷言證明「每幀最多一次」。
    function v:addImpulse(impulse, relPos)
        local imp = self._imp
        imp.frame = imp.frame + 1
        imp.total = imp.total + 1
        if imp.frame > imp.max then imp.max = imp.frame end
        -- 池向量會被回收再發，必須立刻抄純量而不是留引用
        imp.x, imp.y, imp.z = impulse:x(), impulse:y(), impulse:z()
        imp.rx, imp.ry, imp.rz = relPos:x(), relPos:y(), relPos:z()
        -- (r × F)_y = r_z*F_x - r_x*F_z：繞 +y 的偏航力矩（就地算，不抄 production）
        imp.torqueY = imp.rz * imp.x - imp.rx * imp.z
        if impulse._held ~= true or relPos._held ~= true then
            imp.useAfterRelease = imp.useAfterRelease + 1
        end
    end

    -- setRegulator／setRegulatorSpeed＝BaseVehicle.java:9821-9831
    function v:setRegulator(on)
        self._regulator = on
        local c = drive.calls
        c.setRegulator = c.setRegulator + 1
        if on == true then
            c.regulatorOn = c.regulatorOn + 1
        else
            c.regulatorOff = c.regulatorOff + 1
        end
    end

    function v:setRegulatorSpeed(kmh)
        self._regSpeed = kmh
        local c = drive.calls
        c.setRegulatorSpeed = c.setRegulatorSpeed + 1
        if type(kmh) ~= "number" or kmh < 0 then
            c.badRegSpeed = c.badRegSpeed + 1
        elseif kmh > c.maxRegSpeed then
            c.maxRegSpeed = kmh
        end
    end

    -- setForceBrake 寫 clientControls.forceBrake，效期 1 秒（CarController.java:973-979）
    function v:setForceBrake() drive.calls.forceBrake = drive.calls.forceBrake + 1 end
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
    -- MDAD_Driver require 原版的 radial 選單檔；上面的假 ISVehicleMenu 頂替
    ["Vehicles/ISUI/ISVehicleMenu"] = true,
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

-- MDAD_Driver 只 require 它自己需要的東西：這一行同時證明它的 require 鏈
-- （MDAD、MDAD_Follower、原版 ISVehicleMenu）沒有斷。載入期會註冊 OnPlayerUpdate
-- 並把 ISVehicleMenu.showRadialMenu 包起來；沒有 session 時前者是零成本的。
require "MDAD_Driver"

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

-- =====================================================================
-- M3 自駕情境的共用工具（clientFlag 維持 true：MDAD_Driver 是 client-only）
-- =====================================================================

-- M3 新增的翻譯鍵集中成一顆表：主 chunk 的 local 數量已接近 Lua 的 200 上限
local DKEY = {
    NEED_MODULE = "UI_MinidoracatAutoDrive_NeedModule",
    ROUTE = "UI_MinidoracatAutoDrive_RouteNotReady",
    LOST = "UI_MinidoracatAutoDrive_LostRoute",
    NOT_DRIVER = "UI_MinidoracatAutoDrive_NotDriver",
    ENGINE = "UI_MinidoracatAutoDrive_EngineOff",
    MANUAL = "UI_MinidoracatAutoDrive_ManualOverride",
    ARRIVED = "UI_MinidoracatAutoDrive_Arrived",
    START = "UI_MinidoracatAutoDrive_Start",
    STOP = "UI_MinidoracatAutoDrive_Stop",
    STUCK = "UI_MinidoracatAutoDrive_StopStuck",
}

-- 取第 i 則提示的翻譯鍵並登記（登記過的鍵由最後一個情境逐一驗四語翻譯）
local function haloKey(i)
    local h = halos[i or 1]
    return noteReason(h and h.text)
end

-- 車頭前向（世界 X,Y）。driver 自己會正規化，但給單位向量最貼近實機。
local function setHeading(vehicle, rad)
    vehicle._fwdX, vehicle._fwdY = math.cos(rad), math.sin(rad)
end

-- 主 MOD 的 route 物件：follower 只讀 pts（扁平 x,y）。每次呼叫回**新** table——
-- route 的 identity 就是版本號，driver 靠它判斷主 MOD 有沒有重算過路線。
local function newRoute(n, x0, y0, dx, dy)
    local pts = {}
    for i = 1, n do
        pts[i * 2 - 1] = x0 + dx * (i - 1)
        pts[i * 2] = y0 + dy * (i - 1)
    end
    return { pts = pts }
end

-- 主 MOD 的導航查詢面。目標／路線／狀態都放在 drive.nav 由情境直接改；
-- 呼叫計數用來證明 250ms 節流真的有節流。
local function installNavApi(version)
    MinidoracatMiniMapAPI = {
        navApiVersion = version,
        registerNavGate = function() return true end,
        getNavTarget = function(playerNum)
            local nav = drive.nav
            nav.targetCalls = nav.targetCalls + 1
            nav.lastTargetNum = playerNum
            if nav.tx == nil then return nil end
            return nav.tx, nav.ty
        end,
        requestRoute = function(playerNum, tx, ty)
            local nav = drive.nav
            nav.routeCalls = nav.routeCalls + 1
            nav.lastRouteNum, nav.lastTx, nav.lastTy = playerNum, tx, ty
            return nav.route, nav.state
        end,
    }
end

-- 開一段新的觀測窗：M2 的 stats／halos 與 M3 的計數器一起歸零。
-- drive.pool.live 刻意不歸零——它就是「有向量沒還」的累積證據。
local function driveReset(vehicle)
    resetStats()
    local d = drive
    for k in pairs(d.calls) do d.calls[k] = 0 end
    for k in pairs(d.bad) do d.bad[k] = 0 end
    d.frames = 0
    -- pool.bad 與 pool.live 一樣是累積證據（收尾一次證明全程沒發生），不歸零
    d.pool.alloc, d.pool.release = 0, 0
    d.trip.n = 0
    d.nav.targetCalls, d.nav.routeCalls = 0, 0
    d.orig.n = 0
    d.spy.begin, d.spy.reset, d.spy.control = 0, 0, 0
    clearList(d.texCalls)
    clearList(d.logs)
    d.fmt = 0
    d.paused = false
    for _, menu in pairs(d.menus) do
        menu._visible = false
        menu._delayVisible = false
    end
    if vehicle then
        local imp = vehicle._imp
        imp.frame, imp.total, imp.max, imp.useAfterRelease = 0, 0, 0, 0
        imp.torqueY = nil
    end
end

-- 熱路徑的 print 攔截器：診斷行要能斷言內容與頻率，而且關閉診斷時必須一行都沒有。
-- 定義成具名函式（不是每幀新建 closure），免得絆線自己變成觀測對象。
local function recordPrint(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    drive.logs[#drive.logs + 1] = table.concat(parts, "\t")
end

-- 跑一個遊戲幀：歸零本幀的施力帳、觸發真正的 OnPlayerUpdate，再檢查三條**每幀**
-- 不變式。做成累計違規數＋首次違規幀號，才有辦法一口氣跑 60 幀而不是寫 180 條斷言。
-- 這一幀印出來的東西全部收進 drive.logs，不會噴到測試輸出上。
local function driveTick(player, vehicle)
    local d = drive
    d.frames = d.frames + 1
    local imp = vehicle and vehicle._imp
    if imp then imp.frame = 0 end
    local a0, r0 = d.pool.alloc, d.pool.release
    local saved = print
    print = recordPrint
    fire("OnPlayerUpdate", player)
    print = saved
    if imp and imp.frame > 1 then
        d.bad.impulse = d.bad.impulse + 1
        if d.bad.atImpulse == 0 then d.bad.atImpulse = d.frames end
    end
    if (d.pool.alloc - a0) ~= (d.pool.release - r0) then
        d.bad.pair = d.bad.pair + 1
        if d.bad.atPair == 0 then d.bad.atPair = d.frames end
    end
    if d.pool.live ~= 0 then
        d.bad.live = d.bad.live + 1
        if d.bad.atLive == 0 then d.bad.atLive = d.frames end
    end
end

-- 這一幀真的施出去的衝量大小。符號關係另外驗；量級必須單獨看——實機「按了自駕卻
-- 完全不轉彎」就是符號全對、量級小兩個數量級，任何符號斷言都抓不到。
local function impulseMag(vehicle)
    local imp = vehicle._imp
    return math.sqrt(imp.x * imp.x + imp.z * imp.z)
end

-- 自駕的玩家與車。車頭刻意偏 0.3 rad：完全對準路線時轉向落在死區不施力，
-- 那條路徑另外測，其他情境需要「每幀真的施一次力」才驗得到單槽不變式。
local dp = newPlayer({ num = 0, electricity = 2, username = "autodrive0" })
local dveh = newVehicle({
    battery = newItem("Base.CarBattery", { uses = 0.8 }),
    engineRunning = true, mass = 1200, speed = 20,
})
local droute = nil

-- 每個失效情境都要一顆乾淨的 session：復原車況、換一條新路線、啟動，
-- 再跑一幀把剖面建完並進入跟線，最後開新的觀測窗。
local function armDrive()
    MDAD.Drive.stop(0, nil)
    dveh._x, dveh._y, dveh._speed, dveh._steering, dveh._stopped = 0, 0, 20, 0, false
    dveh._engine, dveh._driver = true, dp
    dveh._part._item._uses = 0.8
    dp._vehicle, dp._dead, dp._local = dveh, false, true
    setHeading(dveh, 0.3)
    drive.nav.tx, drive.nav.ty, drive.nav.state = 300, 0, "ok"
    drive.nav.route = newRoute(40, 0, 0, 4, 0)
    if not MDAD.Drive.start(dp) then return false end
    driveTick(dp, dveh)
    driveReset(dveh)
    return MDAD.Drive.isActive(0)
end

-- 前面的情境把 nowMs 推進過，但 navGate 的 draw 快取（1 秒）可能還留著別的玩家
-- 的結果；先跨過 TTL，讓 M3 從乾淨狀態開始。
nowMs = nowMs + 5000
players[0], players[1], players[2], players[3], players[4], players[5] = dp, nil, nil, nil, nil, nil
activePlayers = 1

-- =====================================================================
-- 情境十六：自駕熱路徑（沒有人在自駕時 OnPlayerUpdate 必須是零成本）
-- =====================================================================
scenario("自駕熱路徑：沒有 session 時 OnPlayerUpdate 一次整數比較就 return，零 Java 呼叫")

checkEq(type(MDAD.Drive), "table", "production client/MDAD_Driver.lua 真的載入了")
checkEq(type(MDADFollower), "table", "driver 的 require 把 shared/MDAD_Follower.lua 一起帶進來")
checkEq(type(MDAD.Drive.start), "function", "Drive.start 是 radial 回呼的實作")
checkEq(type(MDAD.Drive.toggle), "function", "Drive.toggle 是 radial 交出去的指令")
checkEq(#(eventHandlers["OnPlayerUpdate"] or {}), 1,
    "driver 只註冊一個 OnPlayerUpdate（雙載會變兩個＝同幀兩次 addImpulse）")
checkFalse(MDAD.Drive.isActive(0), "初始沒有任何 session")

driveReset(nil)
fire("OnPlayerUpdate", drive.tripPlayer)
fire("OnPlayerUpdate", drive.tripPlayer)
checkEq(drive.trip.n, 0, "沒有 session 時完全不呼叫玩家的任何方法")
checkEq(drive.pool.alloc, 0, "沒有 session 時不向 BaseVehicle 取向量")
checkEq(drive.calls.setRegulator, 0, "沒有 session 時不動 regulator")
checkEq(drive.calls.forceBrake, 0, "沒有 session 時不動煞車")
checkEq(drive.nav.targetCalls, 0, "沒有 session 時不查導航目標")
checkEq(drive.pool.live, 0, "沒有 session 時池水位不動")

-- =====================================================================
-- 情境十七：Drive.start 的每一道閘門
-- =====================================================================
scenario("自駕啟動閘門：nav API v2、駕駛座、引擎、電瓶、自駕模組、GPS、導航目標、路線")

setSandbox({ InstallSkillGate = true, NeedItemForNav = false,
             NeedItemForAutoDrive = true, AutoDriveMaxSpeed = 40 })
dp._vehicle = dveh
dveh._driver = dp
droute = newRoute(40, 0, 0, 4, 0)

driveReset(dveh)
checkFalse(MDAD.Drive.start(nil), "playerObj 為 nil：不啟動")
checkEq(#halos, 0, "沒有玩家就沒有提示對象")

dp._local = false
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "遠端玩家（isLocalPlayer false）：不啟動")
checkEq(#halos, 0, "遠端玩家不提示（自駕只在駕駛自己的 client 跑）")
dp._local = true

-- MDAD_Follower 不見了＝本 MOD 的檔案樹壞掉：印診斷＋紅字優雅退場，
-- 不能讓 radial 回呼丟出 nil index 錯誤
drive.savedFollower = MDADFollower
MDADFollower = nil
driveReset(dveh)
log = capturePrint(function() ok = MDAD.Drive.start(dp) end)
MDADFollower = drive.savedFollower
checkFalse(ok, "MDAD_Follower 沒載入：不啟動")
checkTrue(logHas(log, "MDAD_Follower not loaded"), "缺 follower 留下 console 診斷")
checkTrue(logHas(log, MOD_ID), "診斷帶 MOD 名稱前綴")
checkEq(haloKey(), DKEY.ROUTE, "缺 follower 提示 RouteNotReady")

-- nav API：沒裝、版本太舊、缺任一必要函式，一律視同沒裝
MinidoracatMiniMapAPI = nil
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "主 MOD 沒裝：不啟動")
checkEq(haloKey(), NAV_API_MISSING, "沒有 nav API 提示 NavApiMissing")

installNavApi(1)
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "nav API 只有 v1（沒有 getNavTarget 契約）：不啟動")
checkEq(haloKey(), NAV_API_MISSING, "v1 視同缺 API")

installNavApi(2)
MinidoracatMiniMapAPI.getNavTarget = nil
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "v2 但缺 getNavTarget：不啟動")
installNavApi(2)
MinidoracatMiniMapAPI.requestRoute = nil
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "v2 但缺 requestRoute：不啟動")
checkEq(haloKey(), NAV_API_MISSING, "缺函式視同缺 API")

installNavApi(2)
drive.nav.tx, drive.nav.ty = 300, 0
drive.nav.route, drive.nav.state = droute, "ok"

-- 駕駛座
dp._vehicle = nil
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "人不在車上：不啟動")
checkEq(haloKey(), DKEY.NOT_DRIVER, "不在車上提示 NotDriver")
checkEq(drive.nav.targetCalls, 0, "閘門沒過就不去查導航目標")
dp._vehicle = dveh

dveh._driver = nil
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "坐在副駕：不啟動")
checkEq(haloKey(), DKEY.NOT_DRIVER, "非駕駛提示 NotDriver")
dveh._driver = dp

-- 引擎與電瓶
dveh._engine = false
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "引擎沒發動：不啟動（M3 不代客發動）")
checkEq(haloKey(), DKEY.ENGINE, "熄火提示 EngineOff")
dveh._engine = true

dveh._part._item._uses = 0
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "電瓶沒電：不啟動")
checkEq(haloKey(), DKEY.ENGINE, "電瓶死掉沿用 EngineOff（電系已不成立）")
dveh._part._item._uses = 0.8

-- 自駕模組（沙盒 NeedItemForAutoDrive 預設 true）
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "車上沒裝自駕模組：不啟動")
checkEq(haloKey(), DKEY.NEED_MODULE, "缺模組提示 NeedModule")

setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false, AutoDriveMaxSpeed = 40 })
driveReset(dveh)
checkTrue(MDAD.Drive.start(dp), "沙盒關掉模組需求時不裝模組也能開")
MDAD.Drive.stop(0, nil)
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = true, AutoDriveMaxSpeed = 40 })
st = MDAD.ensureState(dveh:getBattery())
st.auto = true

-- 導航道具閘門（M2 既有的 MDAD.navGate，自駕沿用同一顆）
setSandbox({ NeedItemForNav = true, NeedItemForAutoDrive = true, AutoDriveMaxSpeed = 40 })
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "需要 GPS 但身上沒有：不啟動")
checkEq(haloKey(), NEED_GPS, "缺 GPS 提示 NeedGPS")

st.nav = true
driveReset(dveh)
checkTrue(MDAD.Drive.start(dp), "車上已裝 nav 且車電有電：不必再帶隨身 GPS")
MDAD.Drive.stop(0, nil)
st.nav = nil
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = true, AutoDriveMaxSpeed = 40 })

-- 導航目標與路線
drive.nav.tx = nil
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "地圖上沒有導航目標：不啟動")
checkEq(haloKey(), DKEY.ROUTE, "沒目標提示 RouteNotReady")
checkEq(drive.nav.targetCalls, 1, "查了一次目標")
checkEq(drive.nav.routeCalls, 0, "沒有目標就不去要路線")

drive.nav.tx, drive.nav.ty = 300, 0
drive.nav.state = "pending"
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "路線還在算（state ~= ok）：不啟動")
checkEq(haloKey(), DKEY.ROUTE, "路線未就緒提示 RouteNotReady")
drive.nav.state = "ok"

-- 失敗的啟動不得碰玩家的 regulator：他自己設的定速要原封不動留著
dveh._regulator = true
drive.nav.route = { pts = { 1, 1 } }
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "路線只有一個點：follower 判 badroute，不啟動")
checkEq(haloKey(), DKEY.ROUTE, "badroute 提示 RouteNotReady")
checkEq(drive.calls.setRegulator, 0, "啟動失敗不動 regulator（閘門在寫 session 之前）")
checkTrue(dveh._regulator, "啟動失敗：玩家自己設的定速原封不動")
drive.nav.route = droute

-- 條件齊備
driveReset(dveh)
checkTrue(MDAD.Drive.start(dp), "條件齊備：啟動成功")
checkTrue(MDAD.Drive.isActive(0), "啟動後 isActive")
checkEq(#halos, 1, "啟動只提示一次")
checkEq(haloKey(), DKEY.START, "啟動提示 Start")
checkEq(halos[1] and halos[1].kind, "good", "啟動是綠字（addGoodText）")
checkEq(drive.nav.lastTargetNum, 0, "查目標帶的是玩家 slot 編號")
checkEq(drive.nav.lastTx, 300, "要路線時把目標座標原樣傳進去")
checkEq(drive.nav.lastTy, 0, "目標 y 也原樣傳進去")
-- 啟動時唯一一次 regulator 動作＝關掉。玩家上車前自己設的定速（或前一位駕駛留下的）
-- 若原封不動留著，剖面分幀建構的那七八幀車子會照舊速繼續衝，而 stepFollow 還沒開始跑，
-- 沒有任何人在控速——玩家看到的是「按下自駕，車子加速衝出去」。
checkEq(drive.calls.setRegulator, 1, "啟動動一次 regulator（把上車前的舊定速關掉）")
checkEq(drive.calls.regulatorOff, 1, "動的方向是關掉")
checkEq(drive.calls.regulatorOn, 0, "啟動本身不供油（要等第一幀才控速）")
checkEq(drive.calls.setRegulatorSpeed, 0, "啟動本身不設定速")
checkEq(dveh._regulator, false, "啟動後舊的巡航定速不再生效")
checkEq(drive.pool.alloc, 0, "啟動本身不取向量池")

driveReset(dveh)
checkTrue(MDAD.Drive.start(dp), "已在自駕再按一次：回 true 但不重開 session")
checkEq(#halos, 0, "重複啟動不再提示")
checkEq(drive.nav.targetCalls, 0, "重複啟動不重查導航目標")
checkEq(drive.calls.setRegulator, 0, "重複啟動不再動 regulator（既有 session 直接回 true）")

-- OnPlayerUpdate 的兩道早退：不是本機玩家、以及這個 slot 沒有 session
driveReset(dveh)
it = newPlayer({ num = 0, remote = true })
fire("OnPlayerUpdate", it)
checkEq(drive.calls.getForwardVector, 0, "遠端玩家擋在最前面（就算他的 slot 有 session）")
checkEq(drive.pool.alloc, 0, "遠端玩家不取向量池")

players[1] = newPlayer({ num = 1, username = "autodrive1" })
fire("OnPlayerUpdate", players[1])
checkEq(drive.calls.getForwardVector, 0, "別的 slot 在自駕不會誤動這個 slot 的車")
checkEq(drive.pool.alloc, 0, "沒有自己的 session：不取向量池")
players[1] = nil

-- =====================================================================
-- 情境十八：限速剖面分幀建構
-- =====================================================================
scenario("限速剖面分幀建構：每幀 128 點、建構期不控速也不施力")

-- 300 點、每段 4 公尺（1196 公尺）。follower 的建表運算量＝geometry n ＋ brake n-1
-- ＋ accel n-1 ＝ 3n-2 ＝ 898 個點運算；driver 每幀給 128 → 需要 8 次 stepBuild，
-- 也就是前 7 幀還在建表、第 8 幀才開始控車。一次算完的話玩家會看到啟動瞬間卡一下。
MDAD.Drive.stop(0, nil)
drive.nav.route = newRoute(300, 0, 0, 4, 0)
dveh._x, dveh._y, dveh._speed, dveh._steering = 0, 0, 20, 0
setHeading(dveh, 0.3)
dveh._regulator = true   -- 玩家上車前自己設的定速：建構期必須是關著的
driveReset(dveh)
checkTrue(MDAD.Drive.start(dp), "長路線也能啟動（建表攤到後續幀）")
checkEq(drive.calls.regulatorOff, 1, "長路線一樣在啟動當下就把舊定速關掉")
checkEq(dveh._regulator, false, "建表還沒開始，舊定速就已經失效")

driveReset(dveh)
for _ = 1, 7 do driveTick(dp, dveh) end
checkEq(dveh._imp.total, 0, "剖面還沒建好：不施力")
checkEq(drive.calls.setRegulator, 0, "剖面還沒建好：不動 regulator")
checkEq(dveh._regulator, false, "整段建構期舊定速都不生效（start 關掉、建構幀不再碰）")
checkEq(drive.calls.setRegulatorSpeed, 0, "剖面還沒建好：不設定速")
checkEq(drive.calls.forceBrake, 0, "剖面還沒建好：不煞車")
checkEq(drive.calls.getForwardVector, 0, "剖面還沒建好：連前向向量都不讀")
checkEq(drive.pool.alloc, 0, "建構幀不取向量池（stepBuild 沒完成就 return）")
checkEq(drive.nav.targetCalls, 0, "250ms 節流內不重查導航目標")
checkTrue(MDAD.Drive.isActive(0), "建構期間 session 還活著")

driveTick(dp, dveh)
checkEq(dveh._imp.total, 1, "第 8 幀剖面建好，開始控車（每幀恰一次施力）")
checkEq(drive.calls.setRegulatorSpeed, 1, "第 8 幀開始控速")
checkEq(drive.calls.regulatorOn, 1, "沒超速：regulator 開著供油")
checkEq(drive.calls.getForwardVector, 1, "控制幀只讀一次前向向量")
checkEq(drive.pool.alloc, 2, "控制幀取兩顆池向量（forward／relPos 共用一顆＋impulse 一顆）")
checkEq(drive.pool.release, 2, "取幾顆就還幾顆")
checkEq(drive.pool.live, 0, "幀末池水位歸零")
checkEq(drive.bad.impulse + drive.bad.pair + drive.bad.live, 0, "8 幀都沒有違反每幀不變式")

-- =====================================================================
-- 情境十九：跟線 60 幀的每幀不變式
-- =====================================================================
scenario("跟線 60 幀：每幀最多一次 addImpulse、向量池成對歸零、定速不超過沙盒上限")

-- 沿用情境十八建好的 session。20 km/h ＝ 5.556 m/s，dt ＝ 1.6/48 秒，
-- 所以每幀前進 0.1852 公尺——讓進度真的推進（投影窗口、前視點都會跟著動）。
driveReset(dveh)
for _ = 1, 60 do
    dveh._x = dveh._x + 0.1852
    driveTick(dp, dveh)
end
checkEq(drive.frames, 60, "跑了 60 幀")
checkEq(dveh._imp.max, 1, "單幀施力次數的最高水位是 1（addImpulse 是單槽）")
checkEq(drive.bad.impulse, 0,
    "沒有任何一幀施力超過一次（首次違規幀 " .. tostring(drive.bad.atImpulse) .. "）")
checkEq(drive.bad.pair, 0,
    "每幀 alloc 與 release 成對（首次違規幀 " .. tostring(drive.bad.atPair) .. "）")
checkEq(drive.bad.live, 0,
    "每幀結束時池水位歸零（首次違規幀 " .. tostring(drive.bad.atLive) .. "）")
checkEq(drive.pool.live, 0, "60 幀跑完沒有任何向量沒還")
checkEq(drive.pool.alloc, 120, "60 個控制幀各取兩顆向量")
checkEq(drive.pool.alloc, drive.pool.release, "取還總數相同")
checkEq(drive.pool.bad, 0, "沒有 release 過不在手上的向量")
checkEq(dveh._imp.useAfterRelease, 0, "施力用的向量都還在手上（沒有 use-after-release）")
checkEq(dveh._imp.total, 60, "60 幀各施力一次")
checkEq(drive.calls.getForwardVector, 60, "每幀只讀一次前向向量")
checkEq(drive.calls.setRegulatorSpeed, 60, "60 幀各設一次定速")
checkEq(drive.calls.badRegSpeed, 0, "定速不曾是負數或非數字")
checkTrue(drive.calls.maxRegSpeed <= 40,
    "定速不超過沙盒 AutoDriveMaxSpeed=40（實得 " .. tostring(drive.calls.maxRegSpeed) .. "）")
checkEq(drive.calls.forceBrake, 0, "正常跟線不搶煞車")
checkEq(drive.nav.targetCalls, 0, "60 幀都在 250ms 節流窗內：完全沒重查導航目標")

-- 沙盒上限的三段夾限：太小夾到 5、太大夾到 120、非數字回預設 70。
-- 一律用 300 點的長路線，才有足夠跑道讓起點速度真的頂到上限（短路線會被
-- follower 的反向制動壓低，測不到夾限）。車頭要幾乎對準路線（< 誤差減速的
-- 10° 門檻）：帶著 0.3 rad 誤差時 follower 會收油，觀測到的是「夾限×收油」
-- 的合成值而不是夾限本身。
for _, ok in ipairs({ { 1, 5 }, { 999, 120 }, { "fast", 70 } }) do
    MDAD.Drive.stop(0, nil)
    setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = true, AutoDriveMaxSpeed = ok[1] })
    dveh._x, dveh._y, dveh._speed = 0, 0, 0
    setHeading(dveh, 0.05)
    drive.nav.route = newRoute(300, 0, 0, 4, 0)
    checkTrue(MDAD.Drive.start(dp), "AutoDriveMaxSpeed=" .. tostring(ok[1]) .. " 可以啟動")
    driveReset(dveh)
    for _ = 1, 8 do driveTick(dp, dveh) end
    checkTrue(drive.calls.maxRegSpeed > ok[2] - 1 and drive.calls.maxRegSpeed <= ok[2],
        "AutoDriveMaxSpeed=" .. tostring(ok[1]) .. " 夾到 " .. ok[2] ..
        " km/h（實得 " .. tostring(drive.calls.maxRegSpeed) .. "）")
    checkEq(drive.calls.badRegSpeed, 0, "夾限後的定速仍是非負數字")
end
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = true, AutoDriveMaxSpeed = 40 })

-- =====================================================================
-- 情境二十：轉向的符號關係與力的量級（力矩由 relPos × impulse 就地算，不抄 production 係數）
-- =====================================================================
scenario("轉向符號與量級：誤差反號則力矩反號、幀奇偶只翻中心力、衝量落在推得動又不甩尾的區間")

-- 車頭比路線朝向大 0.3 rad（車頭偏左）→ 前視點落在右手邊 → 誤差為負。
-- 繞 +y 的正向旋轉會讓 (x,z) 向量順時針轉，也就是 heading 變小；因此
-- 「要往右修（誤差為負）」對應的是**正**的偏航力矩。
MDAD.Drive.stop(0, nil)
dveh._x, dveh._y, dveh._speed, dveh._steering = 0, 0, 20, 0
setHeading(dveh, 0.3)
drive.nav.route = newRoute(40, 0, 0, 4, 0)
checkTrue(MDAD.Drive.start(dp), "短路線啟動（40 點＝118 個點運算，第一幀就建完表）")
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 1, "短路線第一幀就建完剖面並施力")
drive.snapTorque = dveh._imp.torqueY
drive.snapForce = dveh._imp.x
drive.snapRelX = dveh._imp.rx
checkTrue(drive.snapTorque > 0,
    "車頭偏左（誤差為負）：偏航力矩為正（實得 " .. tostring(drive.snapTorque) .. "）")
checkEq(dveh._imp.y, 0, "impulse 沒有垂直分量（帶垂直分量會變成翻滾／俯仰力矩）")
checkEq(dveh._imp.ry, 0, "relPos 沒有垂直分量")
checkTrue(dveh._imp.rx * dveh._fwdX + dveh._imp.rz * dveh._fwdY < 0,
    "施力點落在車尾（relPos 沿前向為負）")

driveTick(dp, dveh)
checkEq(dveh._imp.total, 2, "第二幀也只施力一次")
checkTrue(dveh._imp.x * drive.snapForce > 0,
    "側向橫推的中心力兩幀同向（力矩來源是持續的側推，不是幀間交替）")
checkTrue(dveh._imp.torqueY * drive.snapTorque > 0, "力矩與幀奇偶無關，持續同向")
checkNear(dveh._imp.x * dveh._fwdX + dveh._imp.z * dveh._fwdY, 0, 1e-6,
    "中心力是純側向（與前向點積 0）：縱向推力為零，不干擾 regulator 控速")
checkTrue(dveh._imp.rx ~= drive.snapRelX,
    "幀奇偶擺動施力點（車尾左右角交替，防同點數值共振）")

-- 鏡像：車頭偏右（誤差為正）→ 力矩必須反號
MDAD.Drive.stop(0, nil)
dveh._x, dveh._y = 0, 0
setHeading(dveh, -0.3)
drive.nav.route = newRoute(40, 0, 0, 4, 0)
checkTrue(MDAD.Drive.start(dp), "鏡像情境重新啟動（新 session 沒有舊誤差歷史）")
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 1, "鏡像情境第一幀施力一次")
checkTrue(dveh._imp.torqueY < 0,
    "車頭偏右（誤差為正）：偏航力矩為負（實得 " .. tostring(dveh._imp.torqueY) .. "）")
checkTrue(dveh._imp.torqueY * drive.snapTorque < 0, "朝向誤差反號 → 力矩反號")

-- 對準路線：轉向落在死區，不施力也不取 impulse 向量（免無謂抖動）
MDAD.Drive.stop(0, nil)
dveh._x, dveh._y = 0, 0
setHeading(dveh, 0)
drive.nav.route = newRoute(40, 0, 0, 4, 0)
checkTrue(MDAD.Drive.start(dp), "對準路線也能啟動")
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 0, "朝向已對準：轉向落在死區，不施力")
checkEq(drive.calls.setRegulatorSpeed, 1, "死區不施力但照樣控速")
checkEq(drive.pool.alloc, 1, "沒施力時只取一顆向量（forward）")
checkEq(drive.pool.release, 1, "沒施力也要把 forward 還回池子")
checkEq(drive.pool.live, 0, "死區這條路徑同樣不能漏 release")

-- 力的量級：符號全對但推力小兩個數量級＝實機「按了自駕，車直直開過路口」；
-- 2026-08-28 二輪實測連「純力矩×0.8m 臂」的 43k-122k 都只換到每秒 5-9° 偏航。
-- 幾何（2.2m 車尾臂＋側向衝量）與量級改採 Derpy 在整個 Workshop 用戶群驗證過的
-- 標定。把車頭轉到幾乎反向（2.8 rad＝160° > 原地調頭門檻 135°），follower 必定
-- 給飽和轉向，量到的就是這台車拿得到的最大轉向衝量。不抄 production 的係數，
-- 只圈出可用區間：下界＝夠力過路口，上界＝不會把車彈飛。
MDAD.Drive.stop(0, nil)
dveh._x, dveh._y, dveh._steering = 0, 0, 0
dveh._speed, dveh._mass = 30, 1200
setHeading(dveh, 2.8)
drive.nav.route = newRoute(40, 0, 0, 4, 0)
checkTrue(MDAD.Drive.start(dp), "轉向飽和情境啟動")
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 1, "轉向飽和幀照樣只施力一次")
drive.f30 = impulseMag(dveh)
checkTrue(drive.f30 >= 50000, "1200kg／30km/h／轉向飽和：衝量至少 50000（實得 "
    .. tostring(drive.f30) .. "；純力矩模型的 43k 實測過彎偏航率差一個數量級）")
checkTrue(drive.f30 <= 150000, "同一組條件下衝量不超過 150000（實得 "
    .. tostring(drive.f30) .. "；再大就是甩尾／彈飛）")

-- 速度增益：0 km/h 仍有轉向權威、隨速度單調上升、封頂後不再發散
dveh._speed = 0
driveReset(dveh)
driveTick(dp, dveh)
drive.f0 = impulseMag(dveh)
dveh._speed = 70
driveReset(dveh)
driveTick(dp, dveh)
drive.f70 = impulseMag(dveh)
dveh._speed = 200
driveReset(dveh)
driveTick(dp, dveh)
drive.f200 = impulseMag(dveh)
checkTrue(drive.f0 > 0 and drive.f0 == drive.f0 and drive.f0 < math.huge,
    "0 km/h 仍有有限且非零的轉向權威（原地掉頭要推得動，實得 " .. tostring(drive.f0) .. "）")
checkTrue(drive.f70 > drive.f0, "轉向衝量隨速度單調上升（0 km/h＝" .. tostring(drive.f0)
    .. "、70 km/h＝" .. tostring(drive.f70) .. "）")
checkTrue(drive.f70 <= 250000,
    "70 km/h 的衝量仍在上界內（實得 " .. tostring(drive.f70)
    .. "；量級上限採計速度封頂在 60 km/h，不隨車速無限成長）")
checkNear(drive.f200, drive.f70, 1e-6, "70 km/h 以上封頂：速度再高衝量都不成長（200 km/h 實得 "
    .. tostring(drive.f200) .. "）")

-- =====================================================================
-- 情境二十一：玩家讓位與恢復
-- =====================================================================
scenario("玩家讓位：當幀零施力＋關 regulator，連續 10 個乾淨幀才恢復跟線")

MDAD.Drive.stop(0, nil)
dveh._x, dveh._y, dveh._speed, dveh._steering = 0, 0, 20, 0
setHeading(dveh, 0.3)
drive.nav.route = newRoute(40, 0, 0, 4, 0)
checkTrue(MDAD.Drive.start(dp), "讓位情境啟動")
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 1, "正常跟線會施力（讓位斷言才有對照）")

-- getCurrentSteering 的門檻是 0.01：手把的類比轉向會有微小殘值，不能一碰就讓位
dveh._steering = 0.005
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 1, "轉向 0.005 在門檻以下：不算玩家輸入")

dveh._steering = 0.02
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 0, "玩家在轉方向盤：當幀完全不施力")
checkEq(drive.calls.regulatorOff, 1, "讓位時關掉 regulator")
checkEq(drive.calls.regulatorOn, 0, "讓位時不再供油")
checkEq(drive.calls.setRegulatorSpeed, 0, "讓位時不設定速")
checkEq(drive.calls.forceBrake, 0, "讓位不搶煞車（玩家要自己接手）")
checkEq(drive.pool.alloc, 0, "讓位幀不取向量池")
checkEq(#halos, 1, "讓位提示一次")
checkEq(haloKey(), DKEY.MANUAL, "讓位提示 ManualOverride")
checkEq(halos[1] and halos[1].kind, "good", "讓位是綠字（不是錯誤）")
checkTrue(MDAD.Drive.isActive(0), "讓位不結束 session（待命中）")

driveReset(dveh)
driveTick(dp, dveh)
driveTick(dp, dveh)
checkEq(#halos, 0, "持續讓位不重複提示")
checkEq(dveh._imp.total, 0, "持續讓位持續不施力")
checkEq(drive.calls.regulatorOff, 0, "已經在 yield 就不重複關 regulator")

-- 放手：前 9 幀還在觀察，第 10 個乾淨幀才恢復
dveh._steering = 0
driveReset(dveh)
for _ = 1, 9 do driveTick(dp, dveh) end
checkEq(dveh._imp.total, 0, "放手後前 9 幀還在觀察，不施力")
checkEq(drive.calls.setRegulatorSpeed, 0, "觀察期不控速")
checkEq(drive.pool.alloc, 0, "觀察期不取向量池")
driveTick(dp, dveh)
checkEq(dveh._imp.total, 1, "第 10 個乾淨幀恢復跟線並施力")
checkEq(drive.calls.setRegulatorSpeed, 1, "恢復後重新控速")

-- 油門／煞車沒有等價的類比觀測（isGasPedalPressed 在 regulator 供油時恆真），
-- 所以改看鍵位；五個綁定名都必須讓位
for _, ok in ipairs({ "Left", "Right", "Forward", "Backward", "Brake" }) do
    drive.keys[ok] = true
    driveReset(dveh)
    driveTick(dp, dveh)
    checkEq(dveh._imp.total, 0, ok .. " 鍵按下：當幀不施力")
    checkTrue(MDAD.Drive.isActive(0), ok .. " 鍵按下不結束 session")
    drive.keys[ok] = false
    for _ = 1, 10 do driveTick(dp, dveh) end
end
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 1, "五個鍵都放開並等滿乾淨幀後回到跟線")

-- =====================================================================
-- 情境二十二：超速主動煞車與抵達停車
-- =====================================================================
scenario("超速主動煞車；抵達目的地煞停，停妥後交還控制權，途中玩家接手立刻放手")

-- regulator 只會「不再供油」，下坡或超速時它不會煞車，所以超出目標太多要自己煞
driveReset(dveh)
driveTick(dp, dveh)
checkEq(drive.calls.regulatorOn, 1, "沒超速時 regulator 開著供油")
checkEq(drive.calls.forceBrake, 0, "沒超速不煞車")

dveh._speed = 100      -- 目標約 40 km/h，超出 60 > OVERSPEED_BRAKE(15)
driveReset(dveh)
driveTick(dp, dveh)
checkEq(drive.calls.forceBrake, 1, "超速超過門檻：主動煞車")
checkEq(drive.calls.regulatorOff, 1, "煞車時關掉 regulator")
checkEq(drive.calls.regulatorOn, 0, "煞車時不供油")
checkEq(drive.calls.setRegulatorSpeed, 0, "煞車時不設定速")
checkEq(dveh._imp.total, 1, "超速煞車時照樣修正轉向（每幀仍只施力一次）")
checkEq(drive.pool.live, 0, "煞車路徑同樣不漏 release")
dveh._speed = 20

-- 抵達：用短路線（8 點×4 公尺＝28 公尺）。follower 的投影搜尋窗只有前後 12 段，
-- 把車瞬移到長路線的終點不會被判定為抵達——那是刻意的防瞬移設計，不是 bug。
MDAD.Drive.stop(0, nil)
dveh._x, dveh._y, dveh._speed, dveh._steering = 0, 0, 20, 0
setHeading(dveh, 0.3)
drive.nav.route = newRoute(8, 0, 0, 4, 0)
checkTrue(MDAD.Drive.start(dp), "短路線啟動")
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 1, "還沒到：照常施力")
-- 假抵達守衛：車移到終點前 2 公尺、但橫向偏離 20 公尺（被撞開／擦身而過）。
-- 沿路徑剩餘距離同樣是 2m，只看 remaining 的話這裡就會宣告到站並煞停，
-- 而車其實還在 20 公尺外的路邊。
dveh._x, dveh._y = 26, 20
driveReset(dveh)
driveTick(dp, dveh)
checkEq(drive.calls.forceBrake, 0, "橫向偏離終點 20m：不進抵達煞停")
checkEq(drive.calls.regulatorOff, 0, "橫向偏離終點：不關 regulator")
checkEq(dveh._imp.total, 1, "橫向偏離終點：照常跟線施力（要往終點收斂）")
checkTrue(MDAD.Drive.isActive(0), "橫向偏離終點：session 繼續跟線，不是 arrive")
-- 而且不能只是「不宣告抵達」：制動剖面在這裡只給 8.8 km/h、再往終點靠會收到 0，
-- 定速 0 的車停在路邊等一個永遠不會成立的 reached。follower 的末段脫困地板把目標
-- 速度抬到爬行 12 km/h，車才有動力自己開回終點（沙盒上限 40 在這之上，不夾）
checkEq(drive.calls.setRegulatorSpeed, 1, "橫向偏離終點：照樣控速")
checkNear(dveh._regSpeed, 12, 1e-9, "橫向偏離終點：定速抬到爬行 12 km/h（不是 0 速卡死）")
checkEq(drive.calls.regulatorOn, 1, "橫向偏離終點：regulator 開著供油（要把車開回終點）")
dveh._y = 0

dveh._x = 26           -- 沿路徑剩 2 公尺、離終點直線距離也是 2 公尺 <= ARRIVE_M(5)
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 0, "抵達當幀不再施力（停車時不能還在推車）")
checkEq(drive.calls.forceBrake, 1, "抵達當幀開始煞車")
checkEq(drive.calls.regulatorOff, 1, "抵達關掉 regulator")
checkEq(dveh._regulator, false, "抵達後 regulator 是關的")
checkEq(drive.pool.alloc, 1, "抵達幀只取 forward 一顆向量")
checkEq(drive.pool.live, 0, "抵達幀也要把向量還回池子")
checkTrue(MDAD.Drive.isActive(0), "還沒停妥：session 繼續（要把車停好）")

-- 煞停途中就算引擎熄火也不能半路放手
dveh._engine = false
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(MDAD.Drive.isActive(0), "煞停途中熄火仍不放手（arrive 排在其他閘門之前）")
checkEq(drive.calls.forceBrake, 1, "繼續送煞車")
checkEq(dveh._imp.total, 0, "煞停途中不施力")
checkEq(drive.calls.getForwardVector, 0, "煞停途中不做跟線運算")
checkEq(drive.pool.alloc, 0, "煞停途中不取向量池")
checkEq(#halos, 0, "還沒停妥不提示")
dveh._engine = true

dveh._stopped = true
driveReset(dveh)
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "停妥後結束 session")
checkEq(drive.calls.forceBrake, 0, "停妥後不再送煞車")
checkEq(drive.calls.regulatorOff, 1, "停妥時關掉 regulator")
checkEq(#halos, 1, "抵達提示一次")
checkEq(haloKey(), DKEY.ARRIVED, "抵達提示 Arrived")
checkEq(halos[1] and halos[1].kind, "good", "抵達是綠字")
dveh._stopped = false

-- 煞停途中玩家自己踩煞車：立刻交還，不跟他搶（已送出的 forceBrake 1 秒後自行失效）
MDAD.Drive.stop(0, nil)
dveh._x, dveh._y = 0, 0
drive.nav.route = newRoute(8, 0, 0, 4, 0)
checkTrue(MDAD.Drive.start(dp), "重新啟動以再測一次抵達")
driveTick(dp, dveh)
dveh._x = 26
driveTick(dp, dveh)
checkTrue(MDAD.Drive.isActive(0), "已進入煞停")
drive.keys.Brake = true
driveReset(dveh)
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "煞停途中玩家踩煞車：立刻交還控制權")
checkEq(drive.calls.forceBrake, 0, "交還後不再送煞車")
checkEq(drive.calls.regulatorOff, 1, "交還時把 regulator 關掉（不留定速給下一個上車的人）")
checkEq(#halos, 0, "玩家自己接手不彈紅字")
drive.keys.Brake = false

-- =====================================================================
-- 情境二十三：失效停止
-- =====================================================================
scenario("失效停止：下車／換車／非駕駛／死亡靜默結束；引擎、電瓶、模組、GPS、nav API、路線各自紅字")

checkTrue(armDrive(), "失效情境的基準 session 建立成功")
dp._vehicle = nil
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "玩家下車：靜默結束")
checkEq(#halos, 0, "下車不是錯誤，不彈紅字")
checkEq(drive.calls.regulatorOff, 1, "下車也要把 regulator 關掉")

checkTrue(armDrive(), "換車情境重新啟動")
veh = newVehicle({ battery = newItem("Base.CarBattery", { uses = 0.8 }), engineRunning = true })
veh._driver = dp
dp._vehicle = veh
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "換到另一輛車：靜默結束")
checkEq(#halos, 0, "換車不彈紅字")
checkEq(dveh._regulator, false, "關掉的是**原本**那台車的 regulator")

checkTrue(armDrive(), "非駕駛情境重新啟動")
dveh._driver = nil
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "被擠到副駕：靜默結束")
checkEq(#halos, 0, "換座位不彈紅字")

checkTrue(armDrive(), "死亡情境重新啟動")
dp._dead = true
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "玩家死亡：靜默結束")
checkEq(#halos, 0, "死亡不彈紅字")
checkEq(drive.calls.getForwardVector, 0, "死亡當幀不再算控制")
checkEq(drive.pool.alloc, 0, "死亡當幀不取向量池")

checkTrue(armDrive(), "熄火情境重新啟動")
dveh._engine = false
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "引擎熄火：結束自駕")
checkEq(haloKey(), DKEY.ENGINE, "熄火提示 EngineOff")
checkEq(halos[1] and halos[1].kind, "bad", "失效停止是紅字")

checkTrue(armDrive(), "電瓶情境重新啟動")
dveh._part._item._uses = 0
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "行進中電瓶沒電：結束自駕")
checkEq(haloKey(), DKEY.ENGINE, "電瓶死掉沿用 EngineOff")

checkTrue(armDrive(), "模組情境重新啟動")
st.auto = nil
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "自駕模組被拆掉：結束自駕")
checkEq(haloKey(), DKEY.NEED_MODULE, "缺模組提示 NeedModule")
st.auto = true

-- 導航道具閘門在行進中失效。driveGate 每幀用 context="draw"，隨身搜尋有 1 秒快取，
-- 所以要跨過 TTL 才會重掃背包——這正是「每幀不掃背包」的效能設計。
setSandbox({ NeedItemForNav = true, NeedItemForAutoDrive = true, AutoDriveMaxSpeed = 40 })
dp:getInventory():AddItem(newItem(GPS_T, { uses = 0.5, useDelta = 0.006 }))
nowMs = nowMs + 2000
checkTrue(armDrive(), "帶著有電 GPS 可以啟動（NeedItemForNav=true）")
it = MDAD.findChargedPortableGPS(dp)
checkTrue(it ~= nil, "GPS 真的在背包裡")
dp:getInventory():DoRemoveItem(it)
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(MDAD.Drive.isActive(0), "GPS 剛掉：draw 快取還沒過期，自駕不受影響")
checkEq(stats.scanTypeEval, 0, "快取有效期內完全不掃背包")
nowMs = nowMs + 1001
driveReset(dveh)
driveTick(dp, dveh)
checkEq(stats.scanTypeEval, 1, "跨過 1 秒快取才重掃一次背包")
checkFalse(MDAD.Drive.isActive(0), "行進中 GPS 掉了：結束自駕")
checkEq(haloKey(), NEED_GPS, "缺 GPS 提示 NeedGPS")
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = true, AutoDriveMaxSpeed = 40 })

checkTrue(armDrive(), "nav API 情境重新啟動")
MinidoracatMiniMapAPI = nil
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "行進中主 MOD 被拔掉：結束自駕")
checkEq(haloKey(), NAV_API_MISSING, "缺 API 提示 NavApiMissing")
installNavApi(2)

-- 路線遺失的三條路徑（都要跨過 250ms 節流才會重查）
checkTrue(armDrive(), "目標消失情境重新啟動")
drive.nav.tx = nil
nowMs = nowMs + 250
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "導航目標被清掉：結束自駕")
checkEq(haloKey(), DKEY.LOST, "目標消失提示 LostRoute")

checkTrue(armDrive(), "路線重算中情境重新啟動")
drive.nav.state = "pending"
nowMs = nowMs + 250
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "路線重算中拿不到路線：結束自駕")
checkEq(haloKey(), DKEY.LOST, "路線拿不到提示 LostRoute")

checkTrue(armDrive(), "壞路線情境重新啟動")
drive.nav.route = { pts = { 5, 5 } }
nowMs = nowMs + 250
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "新路線 follower 收不了：結束自駕")
checkEq(haloKey(), DKEY.LOST, "壞路線提示 LostRoute")

-- =====================================================================
-- 情境二十四：route identity 換了才重建剖面
-- =====================================================================
scenario("路線換 identity 才重建剖面：重建期不控速、follower 狀態就地重設")

-- 監看 follower 的四個入口：只是順路記一筆，真正的實作照樣執行
drive.spy.beginReal = MDADFollower.begin
drive.spy.resetReal = MDADFollower.resetState
drive.spy.controlReal = MDADFollower.control
MDADFollower.begin = function(route, maxSpeed)
    drive.spy.begin = drive.spy.begin + 1
    return drive.spy.beginReal(route, maxSpeed)
end
MDADFollower.resetState = function(state)
    drive.spy.reset = drive.spy.reset + 1
    drive.spy.resetState = state
    return drive.spy.resetReal(state)
end
MDADFollower.control = function(profile, state, x, y, heading, speed, dt)
    drive.spy.control = drive.spy.control + 1
    drive.spy.idxIn = state.idx
    drive.spy.state = state
    return drive.spy.controlReal(profile, state, x, y, heading, speed, dt)
end

MDAD.Drive.stop(0, nil)
dveh._x, dveh._y, dveh._speed, dveh._steering = 0, 0, 20, 0
dveh._engine, dveh._driver = true, dp
dveh._part._item._uses = 0.8
dp._vehicle = dveh
setHeading(dveh, 0.3)
drive.nav.tx, drive.nav.ty, drive.nav.state = 300, 0, "ok"
drive.nav.route = newRoute(40, 0, 0, 4, 0)
driveReset(dveh)
checkTrue(MDAD.Drive.start(dp), "route identity 情境啟動")
checkEq(drive.spy.begin, 1, "啟動時建一次剖面")
checkEq(drive.spy.control, 0, "啟動本身不呼叫 control")
driveTick(dp, dveh)
checkEq(drive.spy.control, 1, "第一幀剖面建完並呼叫一次 control")
drive.spy.firstState = drive.spy.state
checkEq(type(drive.spy.firstState), "table", "control 拿到的 follower state 是 table")

for _ = 1, 5 do
    dveh._x = dveh._x + 4
    driveTick(dp, dveh)
end
checkEq(drive.spy.state, drive.spy.firstState, "每幀重用同一顆 state（不是每幀新配一顆）")
checkTrue(drive.spy.idxIn > 1,
    "進度真的推進了（進 control 時的 idx＝" .. tostring(drive.spy.idxIn) .. "）")

-- 同一顆 route：節流到期也不重建
nowMs = nowMs + 250
driveReset(dveh)
driveTick(dp, dveh)
checkEq(drive.nav.targetCalls, 1, "節流到期會重查一次導航目標")
checkEq(drive.nav.routeCalls, 1, "有目標才去要路線")
checkEq(drive.spy.begin, 0, "route 是同一顆：不重建剖面")
checkEq(drive.spy.reset, 0, "route 沒換：不重設 follower 狀態")
checkEq(dveh._imp.total, 1, "沒重建就照常跟線")

-- 換一顆新 route table＝主 MOD 重算過（改目標、偏航重算）：整份重建
drive.nav.route = newRoute(300, 0, 0, 4, 0)
nowMs = nowMs + 250
driveReset(dveh)
driveTick(dp, dveh)
checkEq(drive.spy.begin, 1, "route 換 identity：重建剖面")
checkEq(drive.spy.reset, 1, "重建時重設 follower 狀態（否則吃到舊路線的誤差歷史）")
checkEq(drive.spy.resetState, drive.spy.firstState, "就地重設同一顆 state，不換 table")
checkEq(drive.spy.control, 0, "重建當幀不呼叫 control")
checkEq(dveh._imp.total, 0, "重建當幀不施力")
checkEq(drive.calls.setRegulatorSpeed, 0, "重建當幀不控速")
checkEq(drive.calls.regulatorOff, 1, "重建期間鬆油門讓車滑行")
checkEq(drive.calls.forceBrake, 0, "重建期間不煞車（剖面通常一兩幀就好）")
checkEq(drive.pool.alloc, 0, "重建幀不取向量池")

-- 新剖面同樣分幀建：重建那一幀已經是第 1 次 stepBuild，還要 7 幀才建完
driveReset(dveh)
for _ = 1, 6 do driveTick(dp, dveh) end
checkEq(dveh._imp.total, 0, "新剖面建構期同樣不施力")
driveTick(dp, dveh)
checkEq(dveh._imp.total, 1, "建完新剖面就恢復跟線")
checkEq(drive.spy.idxIn, 1, "重設後從路線起點重新投影（idx 歸 1）")

MDADFollower.begin = drive.spy.beginReal
MDADFollower.resetState = drive.spy.resetReal
MDADFollower.control = drive.spy.controlReal

-- =====================================================================
-- 情境二十五：車輛 radial 選單
-- =====================================================================
scenario("車輛 radial：片補在原版之後、只給駕駛、選單看得見才加、標題隨狀態、回呼真的切換")

MDAD.Drive.stop(0, nil)
drive.menus[0] = newRadialMenu()
dp._vehicle, dveh._driver = dveh, dp
dveh._x, dveh._y, dveh._steering = 0, 0, 0
setHeading(dveh, 0.3)
drive.nav.route = newRoute(40, 0, 0, 4, 0)

driveReset(dveh)
ISVehicleMenu.showRadialMenu(dp)
checkEq(drive.orig.n, 1, "原版 showRadialMenu 有被呼叫（wrapper 沒把它吃掉）")
checkEq(drive.orig.player, dp, "原樣把玩家傳給原版")
checkEq(#drive.menus[0].slices, 2, "原版的片還在，自駕片補在後面")
checkEq(drive.menus[0].slices[1].text, "VANILLA",
    "第一片是原版自己加的（我們的片必須在原版 clear() 之後才加）")
opt = drive.menus[0].slices[2]
checkEq(noteReason(opt.text), DKEY.START, "沒在自駕時標題是啟動")
checkEq(opt.command, MDAD.Drive.toggle, "回呼交出的就是 production 的 Drive.toggle")
checkEq(opt.arg1, dp, "回呼帶操作者")
checkEq(opt.texture, "tex:AutopilotModule", "自駕片帶到自訂圖示")
checkEq(drive.texCalls[1], "media/textures/Item_AutopilotModule.png", "先試完整 media 路徑")
checkEq(drive.texCalls[2], "Item_AutopilotModule", "完整路徑拿不到就退回無路徑寫法")
checkEq(#drive.texCalls, 2, "只查兩次貼圖")

driveReset(dveh)
ISVehicleMenu.showRadialMenu(dp)
checkEq(#drive.texCalls, 0, "第二次開選單不再查貼圖（已快取）")
checkEq(#drive.menus[0].slices, 2, "第二次開選單仍然只補一片")

-- 回呼：啟動 → 標題變成停止 → 再按一次關閉
driveReset(dveh)
opt.command(opt.arg1)
checkTrue(MDAD.Drive.isActive(0), "radial 回呼真的啟動自駕")
checkEq(haloKey(), DKEY.START, "啟動提示 Start")
driveTick(dp, dveh)
checkEq(dveh._regulator, true, "radial 啟動的 session 真的在控速（regulator 開著）")
driveReset(dveh)
ISVehicleMenu.showRadialMenu(dp)
opt = drive.menus[0].slices[2]
checkEq(noteReason(opt.text), DKEY.STOP, "正在自駕時標題是停止")
driveReset(dveh)
opt.command(opt.arg1)
checkFalse(MDAD.Drive.isActive(0), "再按一次關閉自駕")
checkEq(haloKey(), DKEY.STOP, "關閉提示 Stop")
checkEq(halos[1] and halos[1].kind, "good", "關閉是綠字")
checkEq(dveh._regulator, false, "關閉自駕時把 regulator 關掉")

-- 不補片的輸入路徑，以及實機抓到的 delayed-visibility 開啟時序
driveReset(dveh)
checkTrue(pcall(ISVehicleMenu.showRadialMenu, nil), "playerObj 為 nil 不炸")
checkEq(drive.orig.n, 1, "nil 玩家也照樣先呼叫原版")

dp._vehicle = nil
ISVehicleMenu.showRadialMenu(dp)
checkEq(#drive.menus[0].slices, 1, "人不在車上（車外 radial）：不補自駕片")
dp._vehicle = dveh

driveReset(dveh)
dveh._driver = nil
ISVehicleMenu.showRadialMenu(dp)
checkEq(#drive.menus[0].slices, 1, "不是駕駛：不補自駕片")
dveh._driver = dp

driveReset(dveh)
clearList(drive.menus[0].slices)
drive.paused = true
ISVehicleMenu.showRadialMenu(dp)
checkEq(#drive.menus[0].slices, 0, "遊戲暫停：原版不開選單，本 MOD 也不補片")

driveReset(dveh)
drive.menus[0].slices[1] = { text = "EXISTING" }
drive.menus[0]._visible = true
ISVehicleMenu.showRadialMenu(dp)
checkEq(#drive.menus[0].slices, 1, "選單原本已開：這次是 toggle-close，不補第二片")
checkFalse(drive.menus[0]._visible, "toggle-close 後選單不可見")

driveReset(dveh)
drive.menus[0]._delayVisible = true
ISVehicleMenu.showRadialMenu(dp)
checkFalse(drive.menus[0]._visible,
    "模擬 addToUIManager 後同 call stack 尚未回報 really-visible")
checkEq(#drive.menus[0].slices, 2,
    "post-call visibility 尚未更新時仍補片（2026-08-28 實機回歸）")

drive.savedMenu = drive.menus[0]
drive.menus[0] = nil
checkTrue(pcall(ISVehicleMenu.showRadialMenu, dp), "拿不到 radial 選單時不炸")
drive.menus[0] = drive.savedMenu

-- 雙載保險：client 目錄的檔案會被引擎自動載入，別的檔案又 require 一次也不能包兩層
loaded["MDAD_Driver"] = nil
require "MDAD_Driver"
checkEq(#(eventHandlers["OnPlayerUpdate"] or {}), 1,
    "重複載入不會註冊第二個 OnPlayerUpdate（每幀跑兩遍＝同幀兩次 addImpulse）")
driveReset(dveh)
ISVehicleMenu.showRadialMenu(dp)
checkEq(drive.orig.n, 1, "重複載入不會把 wrapper 包兩層（原版只被呼叫一次）")
checkEq(#drive.menus[0].slices, 2, "重複載入不會把自駕片加兩次")

clientFlag, serverFlag = false, true

-- =====================================================================
-- 情境二十六：低頻診斷輸出（實機「按了關閉、感覺沒關」的唯一證據來源）
-- =====================================================================
scenario("診斷輸出：關閉時零 print 零 string.format；開啟時每秒一行跟線遙測、start/stop 留痕")

drive.debug = false
checkTrue(armDrive(), "診斷情境的基準 session 建立成功")

-- ① 旗標關閉：熱路徑一行都不印，連格式字串都不生成
driveReset(dveh)
for _ = 1, 60 do driveTick(dp, dveh) end
checkEq(#drive.logs, 0, "getDebug() 為 false：跟線 60 幀一行診斷都沒印")
checkEq(drive.fmt, 0, "getDebug() 為 false：連 string.format 都沒呼叫（字串生成也是每幀成本）")
checkEq(dveh._imp.total, 60, "關閉診斷不影響控制（60 幀照樣各施力一次）")

-- ② 旗標開啟：同一毫秒內跑幾幀都只印一行
drive.debug = true
driveReset(dveh)
for _ = 1, 60 do driveTick(dp, dveh) end
checkEq(#drive.logs, 1, "同一毫秒內連跑 60 幀：跟線遙測只印一行（1 秒節流）")
checkTrue(drive.fmt > 0, "開啟診斷才走 string.format")

nowMs = nowMs + 1000
driveReset(dveh)
driveTick(dp, dveh)
checkEq(#drive.logs, 1, "跨過 1 秒才印下一行")
drive.line = drive.logs[1] or ""
checkTrue(drive.line:find("[MDAD Drive]", 1, true) ~= nil,
    "跟線遙測帶 MOD 前綴（實得 " .. drive.line .. "）")
-- 欄位缺一不可：只有同一行同時看到 errDeg 與 force，才分得出「誤差沒算出來」
-- 與「算對了但推力太小」——這兩種在遊戲裡都是「車不轉彎」
for _, ok in ipairs({ "pn=", "mode=", "speed=", "target=", "errDeg=",
                      "steer=", "force=", "remaining=", "regulator=" }) do
    checkTrue(drive.line:find(ok, 1, true) ~= nil, "跟線遙測含欄位 " .. ok)
end

-- ③ start／stop／toggle 的結果都要留痕：玩家回報「按了沒反應」時，這是唯一能分辨
--    「session 根本沒開」與「開了但車不動」的證據
log = capturePrint(function() MDAD.Drive.stop(0, DKEY.LOST) end)
checkTrue(logHas(log, "stop"), "停止會留下診斷")
checkTrue(logHas(log, DKEY.LOST), "失效停止的診斷帶失效原因鍵")
checkTrue(logHas(log, "regulator=off"), "診斷寫明 regulator 已關掉")
checkTrue(logHas(log, "nobrake"),
    "診斷寫明沒有硬煞：車還在滑就是慣性，不是 session 沒關（Stop 的契約沒變）")

log = capturePrint(function() MDAD.Drive.stop(0, nil) end)
checkEq(#log, 0, "沒有 session 時停止不印任何東西（不是每按一次就刷 log）")

dveh._engine = false
log = capturePrint(function() MDAD.Drive.start(dp) end)
checkTrue(logHas(log, "blocked"), "啟動被閘門擋下也留一行")
checkTrue(logHas(log, DKEY.ENGINE), "擋下的診斷帶原因鍵（與紅字同一個鍵）")
dveh._engine = true

log = capturePrint(function() MDAD.Drive.start(dp) end)
checkTrue(MDAD.Drive.isActive(0), "引擎恢復後重新啟動成功")
checkTrue(logHas(log, "ok maxSpeed="), "啟動成功的那行標成 ok 並帶上限速")

driveReset(dveh)
log = capturePrint(function() MDAD.Drive.toggle(dp) end)
checkFalse(MDAD.Drive.isActive(0), "toggle 把自駕關掉")
checkTrue(logHas(log, "toggle"), "toggle 自己也留一行")
checkTrue(logHas(log, "manual"), "玩家自己關的：停止診斷標成 manual，不是失效原因")
checkEq(drive.calls.regulatorOff, 1, "關閉自駕只關 regulator")
checkEq(drive.calls.forceBrake, 0, "關閉自駕不硬煞（車繼續滑是慣性）")

-- ④ 旗標關回去：後面的情境與收尾斷言都在零診斷狀態下跑
drive.debug = false

-- =====================================================================
-- 情境二十七：卡死偵測（M3 不避障：撞上障礙時不能讓 regulator 永遠推牆）
-- =====================================================================
scenario("卡死偵測：速度／沿線進度／航向三凍結滿 5 秒才自動停車；原地調頭與正常行駛不誤觸")

-- 卡死形狀（實機 2026-08-28）：車頭抵牆，speed≈0、remaining 不動、errDeg 不動，
-- regulator 開著硬推。fake 車的位置由測試控制，speed 歸零＋位置凍結＝完美重現。
checkTrue(armDrive(), "卡死情境啟動")
dveh._speed = 0
-- 第 1 幀只是「開始觀測到凍結」（記下計時起點），從那一幀起算滿 5 秒才停：
-- 5 幀 ×1000ms 後經過 4000ms，session 必須還活著
for i = 1, 5 do
    nowMs = nowMs + 1000
    driveTick(dp, dveh)
end
checkTrue(MDAD.Drive.isActive(0), "凍結 4 秒（未滿 5 秒）：session 還活著（不能太急著放棄）")
checkEq(dveh._regulator, true, "凍結期間 regulator 照常在推（這正是要被斷路的狀態）")
nowMs = nowMs + 1000
driveReset(dveh)
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "三觀測凍結滿 5 秒：自動停車")
checkEq(haloKey(), DKEY.STUCK, "卡死提示 StopStuck")
checkEq(halos[1] and halos[1].kind, "bad", "卡死是紅字（要玩家來處理）")
checkEq(drive.calls.regulatorOff, 1, "卡死停車關掉 regulator")
checkEq(drive.calls.forceBrake, 0, "卡死停車不硬煞（車本來就不動；倒車脫困不被搶煞車）")
checkEq(dveh._regulator, false, "停車後 regulator 是關的")

-- 原地調頭不誤觸：速度近零但航向每幀在轉（> STUCK_ERR_EPS），計時不斷重置
checkTrue(armDrive(), "原地調頭情境啟動")
dveh._speed = 0
for i = 1, 7 do
    setHeading(dveh, 0.3 + i * 0.15)
    nowMs = nowMs + 1000
    driveTick(dp, dveh)
end
checkTrue(MDAD.Drive.isActive(0), "航向持續在轉：7 秒也不算卡死（原地調頭是正常動作）")

-- 正常行駛不誤觸：速度在動就直接重置（其餘兩個觀測連看都不看）
checkTrue(armDrive(), "行駛情境啟動")
dveh._speed = 20
nowMs = nowMs + 6000
driveTick(dp, dveh)
checkTrue(MDAD.Drive.isActive(0), "速度 20 km/h：跨 6 秒的單幀也不觸發（moving 直接重置）")
MDAD.Drive.stop(0, nil)

-- =====================================================================
-- 情境二十八：理由鍵不得缺翻譯（鍵是 runtime 真的吐出來的，不是抄原始碼）
-- =====================================================================
scenario("理由鍵覆蓋：每個分支都跑到，且四語 UI.json 都有對應翻譯")

checkEq(type(MDAD), "table", "production MDAD.lua 真的載入了")
checkEq(type(MDAD_Recipe), "table", "production MDAD_Recipe.lua 真的載入了")
checkEq(type(ISAutoDriveDeviceAction), "table", "production TimedAction 真的載入了")
checkEq(type(MDADFollower), "table", "production MDAD_Follower.lua 真的載入了")
checkEq(type(MDAD.Drive), "table", "production client/MDAD_Driver.lua 真的載入了")
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
checkTrue(#(eventHandlers["OnPlayerUpdate"] or {}) > 0, "client/MDAD_Driver.lua 掛上了 OnPlayerUpdate")

-- 自駕的向量池絆線：所有情境跑完，BaseVehicle 的池必須是空的。
-- 漏一顆 releaseVector3f 在遊戲裡的表徵是「開久了就沒有轉向」，沒有任何錯誤訊息。
checkEq(drive.pool.live, 0, "全程沒有任何池向量沒還（allocVector3f／releaseVector3f 成對）")
checkEq(drive.pool.bad, 0, "全程沒有 release 過不在手上的向量")

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
    -- M3 自駕：每一個鍵都對應一條真的被執行過的分支
    "UI_MinidoracatAutoDrive_NeedModule",
    "UI_MinidoracatAutoDrive_RouteNotReady",
    "UI_MinidoracatAutoDrive_NotDriver",
    "UI_MinidoracatAutoDrive_EngineOff",
    "UI_MinidoracatAutoDrive_ManualOverride",
    "UI_MinidoracatAutoDrive_Arrived",
    "UI_MinidoracatAutoDrive_LostRoute",
    "UI_MinidoracatAutoDrive_Start",
    "UI_MinidoracatAutoDrive_Stop",
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
