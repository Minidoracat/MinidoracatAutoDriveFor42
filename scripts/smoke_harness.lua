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
    server/MDAD_Consumption.lua
    client/MDAD_Client.lua
    client/MDAD_Driver.lua

三條派送路徑都走真的程式碼，不再測早已不存在的 complete()：
- SP：TimedAction:perform() → MDAD.applyDeviceChange（同 process 直接突變）
- MP client：TimedAction:perform() → sendClientCommand（只送四個純量，本地不突變）
- MP server：Events.OnClientCommand → MDAD_Server → MDAD.applyDeviceChange
  （actor 取事件第三參數，不採 payload；vehicleId／itemId 一律重新解析）
資源路徑另走真實 `NavUsage`／`Usage` command：client 只宣告 active，server 從事件
actor 重驗 onlineID／vehicle／裝置來源後建立 TTL lease，再由 GasTank wrapper 與
EveryOneMinute 決定實際油電 amount；player modData 不參與 billing。
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

function instanceof(obj, cls) return type(obj) == "table" and obj._class == cls end
ItemTag = { SCREWDRIVER = "SCREWDRIVER" }
Perks = { Electricity = "Electricity" }
Metabolics = { MediumWork = "MediumWork" }

-- 觀測計數器：用來證明「沒有做不該做的事」
local stats = {
    setUsedDelta = 0,        -- 寫入電量的次數（雙扣／重複寫的唯一證據）
    transmitUsedDelta = 0,   -- 車電同步（VehicleUtils.compareFloats 門檻）
    transmitModData = 0,     -- part modData 同步
    sendItemStats = 0,       -- 隨身物品同步
    setFuel = 0,             -- GasTank content 寫入（vanilla＋extra 分開可觀測）
    gasUpdates = 0,          -- vanilla GasTank updater 呼叫次數
    transmitFuel = 0,        -- extra/vanilla fuel part sync
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
        setRegulatorSpeed = 0, maxRegSpeed = 0, badRegSpeed = 0, fractionalRegSpeed = 0,
        forceBrake = 0, getForwardVector = 0, getMass = 0,
        getEnginePower = 0, getBrakingForce = 0, getWheelFriction = 0,
        getPartById = 0, getInventoryItem = 0, isAnyTireMissing = 0,
        isDoingOffroad = 0, isBraking = 0, getMinWheelSkid = 0,
        getEngineSpeed = 0, getTransmissionNumber = 0, getRegulatorSpeed = 0,
        getLinearVelocity = 0,
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
    worldAge = 0,             -- getGameTime():getWorldAgeHours()
    online = {},              -- getOnlinePlayers() 的 server roster
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

-- 配方系統的最小假面（MP 登入補學路徑）。全部掛在一顆 table 上：本檔主 chunk 的
-- local 數量已接近 Lua 的 200 上限。
-- 出處：
--   getScriptManager():getCraftRecipe(name)＝ScriptManager.java:1004
--     （原版 Lua 用例 ISFirearmRadialMenu.lua:465）；
--   CraftRecipe.checkAutoLearnAnySkills(chr)＝CraftRecipe.java:858-872＋890-905；
--   IsoGameCharacter.getKnownRecipes()＝IsoGameCharacter.java:11531（learnRecipe
--     就是往這條 list 加，:11583-11585）；
--   sendSyncPlayerFields(player, flags)＝LuaManager.java:4274，PF_Recipes=0x01
--     ＝SyncPlayerFieldsPacket.java:22（原版 Lua 用例 ISResearchRecipe.lua:85）。
local recipeWorld = { defs = {}, lookups = {}, learns = {}, syncs = {}, globalScans = 0 }

-- Java List<String> 的最小面：Lua 端只用 size／contains／add
function recipeWorld.newKnownList()
    local list = { _v = {} }
    function list:size() return #self._v end
    function list:contains(name)
        for i = 1, #self._v do
            if self._v[i] == name then return true end
        end
        return false
    end
    function list:add(name) self._v[#self._v + 1] = name end
    return list
end

-- 假 CraftRecipe 照抄引擎 checkAutoLearnAnySkills 的三個前提（未學過、有
-- AutoLearnAny 門檻、技能達標）才 learnRecipe。**故意不無條件學會**：production
-- 若哪天自己抄一份等級判定、或繞過引擎直接 learnRecipe，斷言才抓得到。
-- level 為 nil＝該配方沒有 AutoLearnAny（getAutoLearnAnySkillCount()==0，
-- CraftRecipe.java:952）：引擎在那種情況什麼都不做。
function recipeWorld.newRecipe(name, perk, level)
    local r = {}
    function r:checkAutoLearnAnySkills(chr)
        recipeWorld.learns[#recipeWorld.learns + 1] = { name = name, chr = chr }
        if level == nil then return end
        if chr:getKnownRecipes():contains(name) then return end
        if chr:getPerkLevel(perk) < level then return end
        chr:learnRecipe(name, false)
    end
    return r
end

recipeWorld.sm = {}
function recipeWorld.sm:getCraftRecipe(name)
    recipeWorld.lookups[#recipeWorld.lookups + 1] = name
    return recipeWorld.defs[name]
end

-- 絆線：ScriptManager.checkAutoLearn 掃的是全伺服器所有 MOD 的 craftRecipes
-- （ScriptManager.java:1142），本 MOD 一次登入補學就會替玩家學走整包不相關配方。
-- 刻意**不**放進 resetStats，才能在收尾一次證明全程沒被呼叫。
function recipeWorld.sm:checkAutoLearn(_)
    recipeWorld.globalScans = recipeWorld.globalScans + 1
end

function getScriptManager() return recipeWorld.sm end

function sendSyncPlayerFields(player, flags)
    recipeWorld.syncs[#recipeWorld.syncs + 1] = { player = player, flags = flags }
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
    clearList(recipeWorld.lookups)
    clearList(recipeWorld.learns)
    clearList(recipeWorld.syncs)
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
function gameTime:getWorldAgeHours() return drive.worldAge end
function getGameTime() return gameTime end

OnlinePlayersStub = {}
function OnlinePlayersStub:size() return #drive.online end
function OnlinePlayersStub:get(index) return drive.online[index + 1] end
function getOnlinePlayers() return OnlinePlayersStub end

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
        _onlineId = opts.onlineId or (1000 + (opts.num or 0)),
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
    function p:getOnlineID() return self._onlineId end
    function p:isDead() return self._dead end
    function p:isTimedActionInstant() return self._instant == true end
    -- player modData（IsoPlayer 恆有；檔位／減速偏好的持久面）
    p._modData = {}
    function p:getModData() return self._modData end
    function p:faceThisObject(_) self.faced = self.faced + 1 end
    function p:shouldBeTurning() return false end
    function p:setMetabolicTarget(_) end
    function p:getUseableVehicle() return self._useable end
    function p:getNearVehicle() return self._near end
    function p:getPrimaryHandItem() return self._hand end
    -- 已學會的配方（IsoGameCharacter.getKnownRecipes()＝IsoGameCharacter.java:11531；
    -- learnRecipe(name, checkMetaRecipe) 就是往這條 list 加，:11583-11585）
    p._known = recipeWorld.newKnownList()
    function p:getKnownRecipes() return self._known end
    function p:learnRecipe(name, _)
        if self._known:contains(name) then return false end
        self._known:add(name)
        return true
    end
    return p
end

local function newBatteryPart(battery, area)
    local part = { _md = {}, _item = battery, _area = area }
    function part:getModData() return self._md end
    function part:getInventoryItem() return self._item end
    function part:getArea() return self._area end
    return part
end

local function newGasPart(amount, capacity)
    local part = { _amount = amount or 0, _capacity = capacity or 1, _gas = true,
        _item = newItem("Base.PetrolCanEmpty") }
    function part:getInventoryItem() return self._item end
    function part:getContainerContentAmount() return self._amount end
    function part:getContainerCapacity() return self._capacity end
    function part:setContainerContentAmount(value)
        if value < 0 then value = 0 elseif value > self._capacity then value = self._capacity end
        self._amount = value
        stats.setFuel = stats.setFuel + 1
    end
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
        _maxSpeed = opts.maxSpeed or 200, -- 載具極速（瘋狂檔讀 getMaxSpeed）
        _driver = opts.driver,
        _regulator = nil,
        _regSpeed = nil,
        -- 每幀施力的帳：frame＝本幀次數、max＝觀測窗內單幀最高、total＝總次數
        _imp = { frame = 0, max = 0, total = 0, useAfterRelease = 0 },
    }
    local ext = newVec3():set(opts.bodyW or 1.8, 1, opts.bodyL or 4.4)
    local com = newVec3():set(opts.comX or 0, opts.comY or 0.5, opts.comZ or 0)
    local script = {}
    function script:getFullName() return opts.scriptName or "Base.TestVehicle" end
    function script:getExtents() return ext end
    function script:getCenterOfMassOffset() return com end
    if opts.profileFull then
        local ids = { "FrontLeft", "FrontRight", "RearLeft", "RearRight" }
        local wheels = {}
        for i = 1, 4 do
            local id = ids[i]
            local left = i == 1 or i == 3
            local front = i <= 2
            local off = newVec3():set(
                (left and -1 or 1) * (opts.bodyW or 1.8) * 0.35,
                0, (front and 1 or -1) * (opts.bodyL or 4.4) * 0.25)
            wheels[id] = {
                getOffset = function() return off end,
                getId = function() return id end,
            }
        end
        function script:getWheelById(id) return wheels[id] end
        function script:getWheelCount() return 4 end
        function script:getWheel(index) return wheels[ids[index + 1]] end
        function script:getSteeringClamp(speed)
            local av = speed < 0 and -speed or speed
            local top = opts.maxSpeed or 90
            local t = av / top
            if t > 1 then t = 1 end
            return 0.9 + (0.3 - 0.9) * t
        end
        function script:getWheelFriction() return opts.wheelFriction or 1.5 end
        function script:getOffroadEfficiency() return opts.offroadEfficiency or 1 end
        function script:getRollInfluence() return opts.rollInfluence or 0.7 end
    end
    v._script, v._com = script, com
    nextVehicleId = nextVehicleId + 1
    vehiclesById[v._id] = v

    function v:getId() return self._id end
    function v:getMaxSpeed() return self._maxSpeed end
    function v:getScript() return self._script end
    function v:getSquare() return self._square end
    function v:getBattery() return self._part end
    function v:getDriver() return self._driver end
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
    function v:transmitPartModData(part)
        stats.transmitModData = stats.transmitModData + 1
        if part and part._gas then stats.transmitFuel = stats.transmitFuel + 1 end
    end

    -- isDriver(chr) ⇔ getSeat(chr)==0（BaseVehicle.java:1853-1864）
    function v:isDriver(chr) return self._driver ~= nil and self._driver == chr end
    function v:getX() return self._x end
    function v:getY() return self._y end
    function v:getMass()
        drive.calls.getMass = drive.calls.getMass + 1
        return self._mass
    end
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
    -- getWorldPos(float,float,float,out) returns PZ world x/y/z in Vector3f x/y/z
    -- (BaseVehicle.java:1871-1889). Local z is forward; local x is lateral.
    function v:getWorldPos(localX, localY, localZ, out)
        drive.calls.getWorldPos = (drive.calls.getWorldPos or 0) + 1
        return out:set(
            self._x + localZ * self._fwdX + localX * self._fwdY,
            self._y + localZ * self._fwdY - localX * self._fwdX,
            self._z + localY)
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
        if type(kmh) == "number" and kmh == kmh and kmh % 1 ~= 0 then
            c.fractionalRegSpeed = c.fractionalRegSpeed + 1
        end
    end

    -- setForceBrake 寫 clientControls.forceBrake，效期 1 秒（CarController.java:973-979）
    function v:setForceBrake() drive.calls.forceBrake = drive.calls.forceBrake + 1 end
    if opts.profileFull then
        local tirePart = {
            getInventoryItem = function()
                drive.calls.getInventoryItem = drive.calls.getInventoryItem + 1
                return {}
            end,
            getWheelFriction = function()
                drive.calls.getWheelFriction = drive.calls.getWheelFriction + 1
                return opts.tireFriction or opts.wheelFriction or 1.5
            end,
        }
        function v:getEnginePower()
            drive.calls.getEnginePower = drive.calls.getEnginePower + 1
            return opts.enginePower or 4000
        end
        function v:getBrakingForce()
            drive.calls.getBrakingForce = drive.calls.getBrakingForce + 1
            if opts.brakingForce ~= nil then return opts.brakingForce end
            return 80
        end
        function v:isAnyTireMissing()
            drive.calls.isAnyTireMissing = drive.calls.isAnyTireMissing + 1
            return opts.tireMissing == true
        end
        function v:getPartById(id)
            drive.calls.getPartById = drive.calls.getPartById + 1
            if type(id) == "string" and string.sub(id, 1, 4) == "Tire" then
                return tirePart
            end
            return nil
        end
    end
    -- Phase A 診斷 getter：只應在 s.diag 真時被呼叫。
    function v:isDoingOffroad()
        drive.calls.isDoingOffroad = drive.calls.isDoingOffroad + 1
        return self._offroad == true
    end
    function v:isBraking()
        drive.calls.isBraking = drive.calls.isBraking + 1
        return self._braking == true
    end
    function v:getMinWheelSkid()
        drive.calls.getMinWheelSkid = drive.calls.getMinWheelSkid + 1
        return self._skid or 1
    end
    function v:getEngineSpeed()
        drive.calls.getEngineSpeed = drive.calls.getEngineSpeed + 1
        return self._engineSpeed or 800
    end
    function v:getTransmissionNumber()
        drive.calls.getTransmissionNumber = drive.calls.getTransmissionNumber + 1
        return self._trans or 2
    end
    function v:getRegulatorSpeed()
        drive.calls.getRegulatorSpeed = drive.calls.getRegulatorSpeed + 1
        return self._regSpeed or 0
    end
    function v:getLinearVelocity(out)
        drive.calls.getLinearVelocity = drive.calls.getLinearVelocity + 1
        local ms = (self._speed or 0) / 3.6
        return out:set(self._fwdX * ms, 0, self._fwdY * ms)
    end
    return v
end

VehicleUtils = {
    compareFloats = function(a, b, precision)
        if (a == 0.0) ~= (b == 0.0) then return true end
        if (a == 1.0) ~= (b == 1.0) then return true end
        return round(a, precision) ~= round(b, precision)
    end,
}
Vehicles = { Update = {} }
function Vehicles.Update.GasTank(vehicle, part, elapsedMinutes)
    stats.gasUpdates = stats.gasUpdates + 1
    local old = part:getContainerContentAmount()
    part:setContainerContentAmount(old - (drive.fuelBurn or 0.1) * elapsedMinutes, false, true)
    local amount = part:getContainerContentAmount()
    local precision = amount < 0.5 and 2 or 1
    if VehicleUtils.compareFloats(old, amount, precision) then vehicle:transmitPartModData(part) end
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
require "MDAD_Consumption"
-- MDAD_Client 在載入期就會呼叫一次 registerNavGate()。此時 MinidoracatMiniMapAPI
-- 刻意不存在，好讓「主 MOD 未安裝」這條路徑真的被走到；診斷訊息留給情境去斷言。
local clientLoadLog = capturePrint(function() require "MDAD_Client" end)

-- MDAD_Driver 只 require 它自己需要的東西：這一行同時證明它的 require 鏈
-- （MDAD、MDAD_Follower、MDAD_VehicleProfile、MDAD_Diagnostics、原版
-- ISVehicleMenu）沒有斷。載入期會註冊 OnPlayerUpdate 並把
-- ISVehicleMenu.showRadialMenu 包起來；沒有 session 時前者是零成本的。
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
-- 情境二：戰利品注入＋OnFillContainer 生成政策
-- =====================================================================
scenario("戰利品：merge 防重，GPS／自駕在容器生成時各自過濾")

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

local function newLootContainer(types)
    local container = { _items = {} }
    for i = 1, #types do container._items[i] = newItem(types[i]) end
    local list = {}
    function list:size() return #container._items end
    function list:get(index) return container._items[index + 1] end
    function container:getItems() return list end
    function container:DoRemoveItem(item)
        for i = #self._items, 1, -1 do
            if self._items[i] == item then table.remove(self._items, i) end
        end
    end
    function container:count(fullType)
        local count = 0
        for i = 1, #self._items do
            if self._items[i]:getFullType() == fullType then count = count + 1 end
        end
        return count
    end
    return container
end

ProceduralDistributions = { list = {} }
for _, name in ipairs(DIST_NAMES) do
    local e = BASE_ENTRY[name]
    ProceduralDistributions.list[name] = { items = { e[1], e[2] } }
end
setSandbox({ SpawnGPS = true, SpawnAutopilot = true })

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
checkEq(#ProceduralDistributions.list.ArmyStorageElectronics.items, 8,
    "同時是三種目標的表補了 GPS／自駕／手冊三組 pair")
checkEq(#ProceduralDistributions.list.EngineerTools.items, 4, "單一道具目標只補一組 pair")

-- Merge 發生在 SandboxOptions.load 前：即使此刻 Spawn/Craft=false，三組 pair 都必須
-- 留給 ItemPicker parse；真正政策在 OnFillContainer（已載入沙盒）執行。
setSandbox({ SpawnGPS = false, SpawnAutopilot = true })
fire("OnPostDistributionMerge")
checkEq(countIn(ProceduralDistributions.list.ArmyStorageElectronics.items, GPS_T), 1,
    "SpawnGPS=false 不在過早的 merge 階段移除 GPS pair")
checkEq(countIn(ProceduralDistributions.list.ArmyStorageElectronics.items, AUTO_T), 1,
    "merge 階段仍保留自駕 pair")

do
    local loot = newLootContainer({ GPS_T, AUTO_T, "Base.Plank" })
    fire("OnFillContainer", "garage", "crate", loot)
    checkEq(loot:count(GPS_T), 0, "SpawnGPS=false：新生成容器移除 GPS")
    checkEq(loot:count(AUTO_T), 1, "關閉 GPS 不影響自駕模組")
    checkEq(loot:count("Base.Plank"), 1, "生成過濾不碰原版物品")

    setSandbox({ SpawnGPS = true, SpawnAutopilot = false })
    loot = newLootContainer({ GPS_T, AUTO_T, "Base.Plank" })
    fire("OnFillContainer", "garage", "crate", loot)
    checkEq(loot:count(GPS_T), 1, "關閉自駕模組不影響 GPS")
    checkEq(loot:count(AUTO_T), 0, "SpawnAutopilot=false：新生成容器移除自駕模組")

    setSandbox({ SpawnGPS = false, SpawnAutopilot = false })
    loot = newLootContainer({ GPS_T, AUTO_T, "Base.Plank" })
    fire("OnFillContainer", "garage", "crate", loot)
    checkEq(#loot._items, 1, "兩個生成開關都關：只保留原版物品")
    local child = newLootContainer({ GPS_T, AUTO_T, "Base.Nails" })
    local bag = newItem("Base.Bag_DuffelBag")
    bag._class = "InventoryContainer"
    function bag:getInventory() return child end
    loot = newLootContainer({ "Base.Plank" })
    loot._items[#loot._items + 1] = bag
    local nested = { bag }
    function loot:getAllEvalRecurse(predicate)
        local matches = {}
        for i = 1, #nested do
            if predicate(nested[i]) then matches[#matches + 1] = nested[i] end
        end
        return {
            size = function() return #matches end,
            get = function(_, index) return matches[index + 1] end,
        }
    end
    fire("OnFillContainer", "garage", "crate", loot)
    checkEq(child:count(GPS_T), 0, "正常外層 event 會遞迴清掉巢狀 bag 的 GPS")
    checkEq(child:count(AUTO_T), 0, "正常外層 event 會遞迴清掉巢狀 bag 的自駕模組")
    checkEq(child:count("Base.Nails"), 1, "巢狀過濾不碰原版物品")

    setSandbox({ SpawnGPS = true, SpawnAutopilot = true })
    loot = newLootContainer({ GPS_T, AUTO_T, "Base.Plank" })
    fire("OnFillContainer", "garage", "crate", loot)
    checkEq(#loot._items, 3, "兩個生成開關都開：容器內容完全不動")

    clientFlag = true
    setSandbox({ SpawnGPS = false, SpawnAutopilot = false })
    loot = newLootContainer({ GPS_T, AUTO_T })
    fire("OnFillContainer", "garage", "crate", loot)
    checkEq(#loot._items, 2, "MP client 不改 server 權威生成內容")
    clientFlag = false
    checkTrue(pcall(fire, "OnFillContainer", "garage", "crate", nil),
        "OnFillContainer 缺 container 時安全早退")
    checkTrue(pcall(fire, "OnFillContainer", "Zombie Bag", "bag", {}),
        "vanilla 誤傳 ItemPickerContainer（無 getItems/DoRemoveItem）時安全早退")
    setSandbox({ SpawnGPS = true, SpawnAutopilot = true })
end

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
scenario("車電耗電：GPS／自駕倍率獨立、同輪相加、引擎負載、滿電短路與同步門檻")

local RATE_NAV, RATE_AUTO = 0.00002, 0.0001
local dv, db

local function drainVehicle(charge, engineRunning)
    db = newItem("Base.CarBattery", { uses = charge })
    dv = newVehicle({ battery = db, engineRunning = engineRunning })
end

setSandbox({ GPSPowerPercent = 100, AutoDrivePowerPercent = 100 })
drainVehicle(0.5)
resetStats()
checkTrue(MDAD.consumeVehiclePowerModes(dv, true, false, 10), "GPS 扣電後仍有電：回 true")
checkNear(db._uses, 0.5 - RATE_NAV * 10, EPS, "GPS 10 分鐘只扣一次 rate*minutes")
checkEq(stats.setUsedDelta, 1, "單次呼叫只寫一次 usedDelta")
checkEq(stats.transmitUsedDelta, 0, "round 2 位沒變、未跨 0/1：不同步")

drainVehicle(0.5)
MDAD.consumeVehiclePowerModes(dv, false, true, 10)
checkNear(0.5 - db._uses, RATE_AUTO * 10, EPS, "自駕 10 分鐘扣自己的 RATE_AUTO")

drainVehicle(0.5)
resetStats()
MDAD.consumeVehiclePowerModes(dv, true, true, 10)
checkNear(0.5 - db._uses, (RATE_NAV + RATE_AUTO) * 10, EPS,
    "GPS＋自駕同時啟用時，各費率只相加一次")
checkEq(stats.setUsedDelta, 1, "疊加模式合併成一次 usedDelta write")

setSandbox({ GPSPowerPercent = 0, AutoDrivePowerPercent = 100 })
drainVehicle(0.5)
MDAD.consumeVehiclePowerModes(dv, true, true, 10)
checkNear(0.5 - db._uses, RATE_AUTO * 10, EPS,
    "GPSPowerPercent=0 只關 GPS，不影響自駕")

setSandbox({ GPSPowerPercent = 100, AutoDrivePowerPercent = 0 })
drainVehicle(0.5)
MDAD.consumeVehiclePowerModes(dv, true, true, 10)
checkNear(0.5 - db._uses, RATE_NAV * 10, EPS,
    "AutoDrivePowerPercent=0 只關自駕，不影響 GPS")

setSandbox({ GPSPowerPercent = 50, AutoDrivePowerPercent = 200 })
drainVehicle(0.5)
MDAD.consumeVehiclePowerModes(dv, true, true, 10)
checkNear(0.5 - db._uses, (RATE_NAV * 0.5 + RATE_AUTO * 2) * 10, EPS,
    "兩個非預設倍率分別縮放後再相加")

setSandbox({ GPSPowerPercent = 500, AutoDrivePowerPercent = 500 })
checkNear(MDAD.powerScale("nav"), 5, EPS, "GPSPowerPercent=500 → 5 倍")
checkNear(MDAD.powerScale("auto"), 5, EPS, "AutoDrivePowerPercent=500 → 5 倍")
checkTrue(RATE_NAV * 5 + RATE_AUTO * 5 < 0.001,
    "雙 500% 最大負載仍小於 vanilla 發電機每分鐘 0.001 充電")
setSandbox({ GPSPowerPercent = 100000, AutoDrivePowerPercent = -50 })
checkNear(MDAD.powerScale("nav"), 5, EPS, "GPS 倍率超過 500 截到 500")
checkNear(MDAD.powerScale("auto"), 0, EPS, "自駕倍率負值截到 0")
setSandbox({ GPSPowerPercent = "abc", AutoDrivePowerPercent = 0 / 0 })
checkNear(MDAD.powerScale("nav"), 1, EPS, "GPS 倍率非數字退回 100")
checkNear(MDAD.powerScale("auto"), 1, EPS, "自駕倍率 NaN 退回 100")
setSandbox(nil)
checkNear(MDAD.powerScale("nav"), 1, EPS, "沙盒未載入時 GPS 使用預設 100")
checkNil(MDAD.powerScale("radio"), "未知 power mode 沒有倍率")

setSandbox({ GPSPowerPercent = 100, AutoDrivePowerPercent = 100 })
drainVehicle(0.5, true)
resetStats()
checkTrue(MDAD.consumeVehiclePowerModes(dv, true, true, 60),
    "引擎運轉、電瓶未滿時照計兩項裝置負載")
checkNear(db._uses, 0.5 - (RATE_NAV + RATE_AUTO) * 60, EPS,
    "發電機與裝置負載並存：本函式只補扣負載")
checkEq(stats.setUsedDelta, 1, "引擎運轉未滿電仍寫入負載")

drainVehicle(1.0, true)
resetStats()
checkTrue(MDAD.consumeVehiclePowerModes(dv, true, true, 60), "滿電＋引擎運轉回 true")
checkEq(db._uses, 1.0, "滿電由發電機 headroom 供應，不製造 1.0↔0.999x 抖動")
checkEq(stats.setUsedDelta, 0, "滿電短路不寫 usedDelta")
checkEq(stats.transmitUsedDelta, 0, "滿電短路不廣播")

drainVehicle(0.5)
resetStats()
checkFalse(MDAD.consumeVehiclePowerModes(nil, true, false, 10), "無車輛")
checkTrue(MDAD.consumeVehiclePowerModes(dv, false, false, 10), "兩個 mode 都未啟用：不耗電")
checkTrue(MDAD.consumeVehiclePowerModes(dv, true, false, 0), "minutes=0：不耗電但回報有電")
checkTrue(MDAD.consumeVehiclePowerModes(dv, true, false, -5), "minutes 負值：不耗電")
checkTrue(MDAD.consumeVehiclePowerModes(dv, true, false, "10"), "minutes 非數字：不耗電")
checkEq(db._uses, 0.5, "無效參數一律不動電量")
checkEq(stats.setUsedDelta, 0, "無效參數不寫 usedDelta")
checkFalse(MDAD.consumeVehiclePowerModes(newVehicle({ noBattery = true }), true, false, 10),
    "無電瓶 part")
checkFalse(MDAD.consumeVehiclePowerModes(newVehicle({}), true, false, 10),
    "電瓶槽沒有 item")
checkFalse(MDAD.consumeVehiclePowerModes(
    newVehicle({ battery = newItem("Base.Plank") }), true, false, 10),
    "電瓶槽塞了非 drainable 物品")

drainVehicle(0.0001)
resetStats()
checkFalse(MDAD.consumeVehiclePowerModes(dv, true, false, 100), "電量歸零時回 false")
checkEq(db._uses, 0, "clamp01 截到 0，不會變負數")
checkEq(stats.transmitUsedDelta, 1, "跨越 0 邊界一定同步")
resetStats()
checkFalse(MDAD.consumeVehiclePowerModes(dv, true, false, 100), "已經 0 電再呼叫仍回 false")
checkEq(stats.setUsedDelta, 0, "電量已是 0：不重複寫入")

drainVehicle(0.5)
resetStats()
MDAD.consumeVehiclePowerModes(dv, false, true, 100)
checkNear(db._uses, 0.49, EPS, "自駕 100 分鐘扣 0.01")
checkEq(stats.transmitUsedDelta, 1, "round 2 位由 0.50 變 0.49：同步")

drainVehicle(1.0, false)
resetStats()
MDAD.consumeVehiclePowerModes(dv, true, false, 10)
checkNear(db._uses, 1.0 - RATE_NAV * 10, EPS, "熄火滿電仍由電瓶供應 GPS")
checkEq(stats.transmitUsedDelta, 1, "熄火離開滿電 1.0 邊界一定同步")

drainVehicle(0.5)
clientFlag = true
resetStats()
checkFalse(MDAD.consumeVehiclePowerModes(dv, true, false, 10), "MP client 直接 return false")
checkEq(db._uses, 0.5, "MP client 不動電量（server-authoritative）")
checkEq(stats.setUsedDelta, 0, "MP client 不寫 usedDelta")
clientFlag = false

-- =====================================================================
-- 情境七：隨身 GPS 耗電
-- =====================================================================
scenario("隨身 GPS 耗電：UseDelta、獨立 GPS 倍率、耗盡與 sendItemStats")

setSandbox({ GPSPowerPercent = 100, AutoDrivePowerPercent = 100 })
local pi = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
resetStats()
checkTrue(MDAD.consumePortablePower(pi, 10), "GPS 扣電後仍有電")
checkNear(0.5 - pi._uses, 0.006 * 10, EPS, "採用 item 自己的 UseDelta（0.006/分）")
checkEq(stats.setUsedDelta, 1, "單次呼叫只寫一次 usedDelta")
checkEq(stats.sendItemStats, 1, "MP server 上同步 item 狀態")

pi = newItem(GPS_T, { uses = 0.5 })
MDAD.consumePortablePower(pi, 10)
checkNear(0.5 - pi._uses, 0.06, EPS, "沒有 getUseDelta 時退回內建 0.006")
pi = newItem(GPS_T, { uses = 0.5, useDelta = 0 })
MDAD.consumePortablePower(pi, 10)
checkNear(0.5 - pi._uses, 0.06, EPS, "UseDelta=0 不被採用（否則永不耗電）")
pi = newItem(GPS_T, { uses = 0.5, useDelta = -1 })
MDAD.consumePortablePower(pi, 10)
checkNear(0.5 - pi._uses, 0.06, EPS, "UseDelta 負值不被採用（否則會充電）")
pi = newItem(GPS_T, { uses = 0.5, useDelta = "0.5" })
MDAD.consumePortablePower(pi, 10)
checkNear(0.5 - pi._uses, 0.06, EPS, "UseDelta 非數字不被採用")
pi = newItem(GPS_T, { uses = 1.0, useDelta = 0.02 })
MDAD.consumePortablePower(pi, 10)
checkNear(1.0 - pi._uses, 0.2, EPS, "UseDelta 被改大時費率跟著改")

pi = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
resetStats()
checkTrue(MDAD.consumePortablePower(pi, 0), "minutes=0：不耗電但回報有電")
checkTrue(MDAD.consumePortablePower(pi, "10"), "minutes 非數字：不耗電")
checkEq(pi._uses, 0.5, "無效 minutes 不動電量")
checkEq(stats.setUsedDelta, 0, "無效 minutes 不寫 usedDelta")
checkFalse(MDAD.consumePortablePower(nil, 10), "無物品")
checkFalse(MDAD.consumePortablePower(newItem(AUTO_T), 10),
    "AutopilotModule 不是 drainable，不存在 portable-auto 假路徑")

setSandbox({ GPSPowerPercent = 0, AutoDrivePowerPercent = 500 })
pi = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
resetStats()
checkTrue(MDAD.consumePortablePower(pi, 10), "GPSPowerPercent=0：仍回報有電")
checkEq(pi._uses, 0.5, "GPSPowerPercent=0：隨身 GPS 電量完全不動")
checkEq(stats.sendItemStats, 0, "GPSPowerPercent=0：不發同步")
setSandbox({ GPSPowerPercent = 500, AutoDrivePowerPercent = 0 })
pi = newItem(GPS_T, { uses = 1.0, useDelta = 0.006 })
MDAD.consumePortablePower(pi, 10)
checkNear(1.0 - pi._uses, 0.3, EPS, "GPSPowerPercent=500：隨身 GPS 扣 5 倍")

setSandbox({ GPSPowerPercent = 100, AutoDrivePowerPercent = 100 })
pi = newItem(GPS_T, { uses = 0.05, useDelta = 0.006 })
resetStats()
checkFalse(MDAD.consumePortablePower(pi, 10), "電量歸零時回 false")
checkEq(pi._uses, 0, "clamp01 截到 0，不會變負數")
checkEq(stats.setUsedDelta, 1, "耗盡那一次要寫入")
checkEq(stats.sendItemStats, 1, "耗盡那一次要同步")
resetStats()
checkFalse(MDAD.consumePortablePower(pi, 10), "已經 0 電再呼叫仍回 false")
checkEq(stats.setUsedDelta, 0, "電量已是 0：不重複寫入")
checkEq(stats.sendItemStats, 0, "電量沒變化：不重複同步")

pi = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
serverFlag = false
resetStats()
checkTrue(MDAD.consumePortablePower(pi, 10), "SP 照樣耗電")
checkNear(0.5 - pi._uses, 0.06, EPS, "SP 扣的量與 MP server 相同")
checkEq(stats.sendItemStats, 0, "SP 不發 sendItemStats")
serverFlag = true

pi = newItem(GPS_T, { uses = 0.5, useDelta = 0.006 })
clientFlag = true
resetStats()
checkFalse(MDAD.consumePortablePower(pi, 10), "MP client 直接 return false")
checkEq(pi._uses, 0.5, "MP client 不動電量")
checkEq(stats.sendItemStats, 0, "MP client 不發同步")
clientFlag = false

-- =====================================================================
-- Fuel wrapper＋EveryOneMinute power collector（server/SP 權威）
-- =====================================================================
scenario("資源整合：heartbeat TTL、原生油耗比例加成、四倍率相加、同車去重與跳分鐘補償")
do
    local c = {}
    clientFlag, serverFlag = false, true
    setSandbox({
        NeedItemForAutoDrive = true,
        GPSPowerPercent = 100, AutoDrivePowerPercent = 100,
        GPSFuelPercent = 100, AutoDriveFuelPercent = 100,
    })

    c.wrapper = Vehicles.Update.GasTank
    c.minuteHandlers = #(eventHandlers.EveryOneMinute or {})
    loaded.MDAD_Consumption = nil
    require "MDAD_Consumption"
    checkEq(Vehicles.Update.GasTank, c.wrapper,
        "Consumption chunk 重載不會把 GasTank wrapper 疊包")
    checkEq(#(eventHandlers.EveryOneMinute or {}), c.minuteHandlers,
        "Consumption chunk 重載不會重複註冊 EveryOneMinute")
    Vehicles.Update.GasTank = function() end
    c.hookLog = capturePrint(function() fire("OnServerStarted") end)
    checkTrue(logHas(c.hookLog, "fuel hook slot changed after install"),
        "第三方在載入後覆寫 GasTank slot 會留下明確相容性診斷")
    Vehicles.Update.GasTank = c.wrapper

    c.driver = newPlayer({ num = 0, username = "fuel-driver", remote = true })
    c.battery = newItem("Base.CarBattery", { uses = 0.5 })
    c.vehicle = newVehicle({ battery = c.battery, engineRunning = true, driver = c.driver })
    c.driver._vehicle = c.vehicle
    c.driver._modData.MinidoracatMiniMapTX = 100
    c.driver._modData.MinidoracatMiniMapTY = 200
    c.state = MDAD.ensureState(c.vehicle:getBattery())
    c.state.nav, c.state.auto = true, true

    nowMs = nowMs + 1001
    resetStats()
    fire("OnClientCommand", MOD_ID, MDAD.CMD_NAV_USAGE, c.driver,
        { active = true, victimOnlineId = 9999, amount = -999 })
    checkTrue(MDAD.isNavUsageActive(c.driver, c.vehicle),
        "NavUsage 只採 server actor；不接受 victim／座標／amount")
    fire("OnClientCommand", MOD_ID, MDAD.CMD_USAGE, c.driver,
        { vehicleId = c.vehicle:getId(), active = true, amount = -999 })
    checkTrue(MDAD.isAutoUsageActive(c.vehicle),
        "Usage command 只採 actor／vehicleId／active，忽略 client 偽造 amount")
    checkEq(stats.getVehicleById, 1, "合法 Usage heartbeat 由 server 以 id 重查車輛")
    fire("OnClientCommand", MOD_ID, MDAD.CMD_USAGE, c.driver,
        { vehicleId = c.vehicle:getId(), active = false })
    checkFalse(MDAD.isAutoUsageActive(c.vehicle),
        "active=false 在同一節流窗仍立即清除，不留下幽靈成本")
    resetStats()
    fire("OnClientCommand", MOD_ID, MDAD.CMD_USAGE, c.driver,
        { vehicleId = c.vehicle:getId(), active = true })
    checkTrue(MDAD.isAutoUsageActive(c.vehicle),
        "成功 off 會清 throttle timestamp，立即重開也能當場 ACTIVE")
    checkEq(stats.getVehicleById, 1, "快速 off→on 的新 on 沒被舊 heartbeat timestamp 吃掉")
    resetStats()
    fire("OnClientCommand", MOD_ID, MDAD.CMD_USAGE, c.driver,
        { vehicleId = 999999, active = false })
    fire("OnClientCommand", MOD_ID, MDAD.CMD_USAGE, c.driver,
        { vehicleId = c.vehicle:getId(), active = true })
    checkEq(stats.getVehicleById, 0,
        "沒有清到 entry 的偽造 off 不會重設 throttle、不能拿來繞 flood gate")
    nowMs = nowMs + 1001
    resetStats()
    fire("OnClientCommand", MOD_ID, MDAD.CMD_USAGE, c.driver,
        { vehicleId = 0 / 0, active = true })
    checkEq(stats.getVehicleById, 0, "NaN vehicleId 在進 Java getVehicleById 前拒絕")

    checkTrue(MDAD.setAutoUsage(c.driver, c.vehicle), "合法駕駛 heartbeat 建立 ACTIVE registry")
    checkTrue(MDAD.isAutoUsageActive(c.vehicle), "ACTIVE registry 可被燃油／電力消費點讀到")
    c.driver._modData.MinidoracatMiniMapTX = nil
    c.driver._modData.MinidoracatMiniMapTY = nil
    checkTrue(MDAD.isAutoUsageActive(c.vehicle),
        "任意 client 就算毒化／清除 player modData，也不能改變 actor-bound billing")
    fire("OnClientCommand", MOD_ID, MDAD.CMD_NAV_USAGE, c.driver, { active = false })
    checkFalse(MDAD.isNavUsageActive(c.driver, c.vehicle),
        "NavUsage off 立即停止 GPS billing，不等待 15s TTL")
    c.attacker = newPlayer({ num = 3, username = "attacker", remote = true, onlineId = 9003 })
    c.attackerPortable = newItem(GPS_T, { uses = 1.0, useDelta = 0.006 })
    c.attacker:getInventory():AddItem(c.attackerPortable)
    fire("OnClientCommand", MOD_ID, MDAD.CMD_NAV_USAGE, c.attacker,
        { active = true, victimOnlineId = c.driver:getOnlineID() })
    checkFalse(MDAD.isNavUsageActive(c.driver, c.vehicle),
        "別人的 actor-bound NavUsage 無法替受害者建立／延長 billing")
    checkTrue(MDAD.isNavUsageActive(c.attacker, nil),
        "同一偽造封包最多只讓 attacker 自己的 portable 付費")
    fire("OnClientCommand", MOD_ID, MDAD.CMD_NAV_USAGE, c.attacker, { active = false })
    checkTrue(MDAD.isAutoUsageActive(c.vehicle),
        "NeedItemForNav=false 時 Auto billing 獨立，不因 GPS off 被誤清")
    fire("OnClientCommand", MOD_ID, MDAD.CMD_USAGE, c.driver,
        { vehicleId = c.vehicle:getId(), active = false })
    checkFalse(MDAD.isAutoUsageActive(c.vehicle), "Auto Usage off 獨立停止自駕 billing")
    fire("OnClientCommand", MOD_ID, MDAD.CMD_NAV_USAGE, c.driver, { active = true })
    fire("OnClientCommand", MOD_ID, MDAD.CMD_USAGE, c.driver,
        { vehicleId = c.vehicle:getId(), active = true })
    checkTrue(MDAD.isAutoUsageActive(c.vehicle), "兩個 actor-bound heartbeat 都可立即恢復")
    c.passenger = newPlayer({ num = 1, username = "passenger", remote = true })
    c.passenger._vehicle = c.vehicle
    checkFalse(MDAD.setAutoUsage(c.passenger, c.vehicle), "乘客偽造 heartbeat 被 driver identity 擋住")
    nowMs = nowMs + MDAD.AUTO_USAGE_TTL_MS + 1
    checkFalse(MDAD.isNavUsageActive(c.driver, c.vehicle), "GPS NavUsage 同樣在 15 秒 TTL 失效")
    checkFalse(MDAD.isAutoUsageActive(c.vehicle), "heartbeat 過 15 秒 TTL 自動失效")
    checkTrue(MDAD.setNavUsage(c.driver), "TTL 後先恢復 actor-bound GPS heartbeat")
    checkTrue(MDAD.setAutoUsage(c.driver, c.vehicle), "TTL 後合法 auto heartbeat 可重新啟用")
    c.vehicle._driver = c.passenger
    checkFalse(MDAD.isAutoUsageActive(c.vehicle), "同車換座立刻失效，不持有舊 player object")
    c.vehicle._driver = c.driver
    checkTrue(MDAD.setNavUsage(c.driver), "換回原駕駛先恢復 GPS heartbeat")
    checkTrue(MDAD.setAutoUsage(c.driver, c.vehicle), "換回原駕駛可重新啟用 auto")

    checkNear(MDAD.extraFuelFactor(true, true), 0.30, EPS,
        "雙 100%＝GPS +5% 加自駕 +25%，合計 +30%")
    setSandbox({
        NeedItemForAutoDrive = true,
        GPSPowerPercent = 100, AutoDrivePowerPercent = 100,
        GPSFuelPercent = 0, AutoDriveFuelPercent = 500,
    })
    checkNear(MDAD.extraFuelFactor(true, true), 1.25, EPS,
        "GPSFuel=0、AutoFuel=500 只留下自駕 +125%")
    setSandbox({
        NeedItemForAutoDrive = true,
        GPSPowerPercent = 100, AutoDrivePowerPercent = 100,
        GPSFuelPercent = 100, AutoDriveFuelPercent = 100,
    })

    drive.fuelBurn = 0.1
    c.gas = newGasPart(1.0, 1.0)
    resetStats()
    Vehicles.Update.GasTank(c.vehicle, c.gas, 1)
    checkNear(c.gas._amount, 0.87, EPS,
        "vanilla 0.10L 只扣一次，再加 GPS 0.005L＋自駕 0.025L")
    checkEq(stats.gasUpdates, 1, "wrapper 每次只呼叫一次 vanilla GasTank")
    checkEq(stats.setFuel, 2, "vanilla write＋單次 extra write，沒有第三次重扣")

    MDAD.clearAutoUsage(c.driver, c.vehicle:getId())
    c.gas = newGasPart(1.0, 1.0)
    Vehicles.Update.GasTank(c.vehicle, c.gas, 1)
    checkNear(c.gas._amount, 0.895, EPS, "只有車載 GPS 時原生 0.10L 再加 5%")

    c.state.nav = false
    checkTrue(MDAD.setAutoUsage(c.driver, c.vehicle), "沒有車載 GPS 仍可獨立啟用自駕 registry")
    c.gas = newGasPart(1.0, 1.0)
    Vehicles.Update.GasTank(c.vehicle, c.gas, 1)
    checkNear(c.gas._amount, 0.875, EPS, "只有自駕時原生 0.10L 再加 25%")
    MDAD.clearAutoUsage(c.driver, c.vehicle:getId())
    c.driverPortable = newItem(GPS_T, { uses = 1.0, useDelta = 0.006 })
    c.driver:getInventory():AddItem(c.driverPortable)
    checkTrue(MDAD.setNavUsage(c.driver), "隨身 GPS 加入後 actor heartbeat 建立 portable nav")
    c.gas = newGasPart(1.0, 1.0)
    Vehicles.Update.GasTank(c.vehicle, c.gas, 1)
    checkNear(c.gas._amount, 0.895, EPS,
        "駕駛以帶電隨身 GPS 導航時，也套 GPSFuel +5%")
    checkTrue(MDAD.setAutoUsage(c.driver, c.vehicle), "隨身 GPS＋自駕可同時 ACTIVE")
    c.gas = newGasPart(1.0, 1.0)
    Vehicles.Update.GasTank(c.vehicle, c.gas, 1)
    checkNear(c.gas._amount, 0.87, EPS,
        "隨身 GPS＋自駕同時運作仍相加為 +30%")
    c.driver:getInventory():DoRemoveItem(c.driverPortable)
    c.state.nav = true

    setSandbox({
        NeedItemForAutoDrive = true,
        GPSPowerPercent = 100, AutoDrivePowerPercent = 100,
        GPSFuelPercent = 0, AutoDriveFuelPercent = 500,
    })
    c.gas = newGasPart(1.0, 1.0)
    Vehicles.Update.GasTank(c.vehicle, c.gas, 1)
    checkNear(c.gas._amount, 0.775, EPS,
        "GPSFuel=0／AutoFuel=500：0.10L 原生＋0.125L 自駕，沒有 GPS 分量")

    c.gas = newGasPart(0.05, 1.0)
    Vehicles.Update.GasTank(c.vehicle, c.gas, 1)
    checkEq(c.gas._amount, 0, "vanilla 已扣到零時 extra clamp 仍不會產生負油量")

    setSandbox({
        NeedItemForAutoDrive = true,
        GPSPowerPercent = 100, AutoDrivePowerPercent = 100,
        GPSFuelPercent = 100, AutoDriveFuelPercent = 100,
    })
    c.state.nav = true
    c.battery._uses = 0.5
    checkTrue(MDAD.setAutoUsage(c.driver, c.vehicle), "power collector 前續期 registry")
    c.passenger._modData.MinidoracatMiniMapTX = 300
    c.passenger._modData.MinidoracatMiniMapTY = 400
    checkFalse(MDAD.setNavUsage(c.passenger),
        "乘客不能用別人的車機建立 billing；可偽造 modData 也無效")
    c.passengerPortable = newItem(GPS_T, { uses = 1.0, useDelta = 0.006 })
    c.passenger:getInventory():AddItem(c.passengerPortable)
    checkTrue(MDAD.setNavUsage(c.passenger), "乘客自己的 charged portable 可建立自己的 billing")
    drive.online = { c.driver, c.passenger }
    drive.worldAge = 100
    resetStats()
    fire("EveryOneMinute")
    checkNear(c.battery._uses, 0.5 - RATE_NAV - RATE_AUTO, EPS,
        "driver 車機 GPS 與自駕各扣一份，不因乘客 heartbeat 多扣車電")
    checkNear(c.passengerPortable._uses, 0.994, EPS,
        "乘客導航成本落在自己的 portable，不落在駕駛車機")
    checkEq(stats.setUsedDelta, 2,
        "車輛 GPS＋自駕合併一 write，乘客 portable 另一 write")

    c.walker = newPlayer({ num = 2, username = "walker", remote = true })
    c.walker._modData.MinidoracatMiniMapTX = 500
    c.walker._modData.MinidoracatMiniMapTY = 600
    c.portable = newItem(GPS_T, { uses = 1.0, useDelta = 0.006 })
    c.walker:getInventory():AddItem(c.portable)
    checkTrue(MDAD.setNavUsage(c.walker), "步行者 charged portable 建立 actor-bound NavUsage")
    drive.online = { c.driver, c.passenger, c.walker }
    drive.worldAge = drive.worldAge + 1 / 60
    fire("EveryOneMinute")
    checkNear(c.portable._uses, 0.994, EPS,
        "步行導航每分鐘重找 charged portable 並扣自己的電池")

    c.beforeJump = c.battery._uses
    drive.worldAge = drive.worldAge + 10 / 60
    fire("EveryOneMinute")
    checkNear(c.beforeJump - c.battery._uses, (RATE_NAV + RATE_AUTO) * 5, EPS,
        "單次跨 10 遊戲分鐘按 worldAge 補償，但寬容 clamp 在 5 分鐘")

    c.battery._uses = 1.0
    drive.worldAge = drive.worldAge + 1 / 60
    resetStats()
    fire("EveryOneMinute")
    checkEq(c.battery._uses, 1.0, "EveryOneMinute 遇滿電運轉車不製造邊界抖動")
    checkEq(stats.transmitUsedDelta, 0, "滿電運轉不發 PartUsedDelta")

    drive.online = {}
    drive.worldAge = drive.worldAge + 1 / 60
    resetStats()
    fire("EveryOneMinute")
    checkEq(stats.scanTypeEval, 0, "零在線玩家直接 return，不掃任何背包")
    checkEq(stats.setUsedDelta, 0, "零在線玩家不寫任何裝置電量")

    MDAD.clearAutoUsage(c.driver, c.vehicle:getId())
    MDAD.clearNavUsage(c.driver)
    MDAD.clearNavUsage(c.passenger)
    MDAD.clearNavUsage(c.walker)
    drive.online = {}
    clientFlag, serverFlag = false, true
end

-- =====================================================================
-- 情境八～十：MDAD.applyDeviceChange（安裝／卸載的唯一突變點）
--
-- 以 MP 專用伺服器的旗標組合（isClient=false、isServer=true）直接驅動突變段，
-- 這正是 OnClientCommand 會呼叫到的同一份程式碼；派送層另有情境十二～十四。
-- =====================================================================
scenario("apply 安裝：nav 保存 delta＋從實際容器移除＋同步；auto 只動 auto 欄位")

setSandbox({ InstallSkillGate = true })
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

-- actor-bound GPS billing heartbeat：只送 active，不送目標／vehicle／item／amount。
players[2], players[3], players[4], players[5] = nil, nil, nil, nil
activePlayers = 2
drive.clientNavTargets = { [0] = { 10, 20 } }
MinidoracatMiniMapAPI.navApiVersion = 2
MinidoracatMiniMapAPI.getNavTarget = function(playerNum)
    local target = drive.clientNavTargets[playerNum]
    if not target then return nil end
    return target[1], target[2]
end
resetStats()
fire("OnTick")
local navUsageMessages = {}
for i = 1, #sentClient do
    if sentClient[i].command == MDAD.CMD_NAV_USAGE then
        navUsageMessages[#navUsageMessages + 1] = sentClient[i]
    end
end
checkEq(#navUsageMessages, 1, "首次 check 只替有導航的 slot 送 on；無導航 slot 不送空 off")
local navUsageMessage = navUsageMessages[1]
checkEq(navUsageMessage and navUsageMessage.command, MDAD.CMD_NAV_USAGE,
    "GPS billing 使用獨立 NavUsage command")
checkEq(navUsageMessage and navUsageMessage.args.active, true, "有目標的 slot 宣告 active=true")
checkNil(navUsageMessage and navUsageMessage.args.vehicleId, "NavUsage 不讓 client 指定 vehicle")
checkNil(navUsageMessage and navUsageMessage.args.tx, "NavUsage 不送座標")
nowMs = nowMs + 1100
resetStats()
for _ = 1, 60 do fire("OnTick") end
checkEq(#sentClient, 1, "on 轉態 1.1 秒後快速重試，自癒 server 1 秒節流")
resetStats()
for _ = 1, 60 do fire("OnTick") end
checkEq(#sentClient, 0, "快速重試後、未滿 5 秒不再送")
nowMs = nowMs + 5000
resetStats()
for _ = 1, 60 do fire("OnTick") end
checkEq(#sentClient, 1, "穩態滿 5 秒只替 active slot 續期")
checkEq(sentClient[1] and sentClient[1].args.active, true, "續期維持 slot0 active=true")
resetStats()
drive.clientNavTargets[0] = nil
for _ = 1, 60 do fire("OnTick") end
checkEq(#sentClient, 1, "目標清除在下一個約 1 秒檢查立即送 off")
checkEq(sentClient[1] and sentClient[1].args.active, false, "目標清除的 NavUsage 是 active=false")
resetStats()
nowMs = nowMs + 5000
for _ = 1, 60 do fire("OnTick") end
checkEq(#sentClient, 0, "off 狀態不送永久性 5 秒空 heartbeat")

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
local DODGE_CAP_TEST = 24 -- production DODGE_CAP（速度斷言上限）
local DKEY = {
    NEED_MODULE = "UI_MinidoracatAutoDrive_NeedModule",
    ROUTE = "UI_MinidoracatAutoDrive_RouteNotReady",
    LOST = "UI_MinidoracatAutoDrive_LostRoute",
    NOT_DRIVER = "UI_MinidoracatAutoDrive_NotDriver",
    ENGINE = "UI_MinidoracatAutoDrive_EngineOff",
    UNSUPPORTED = "UI_MinidoracatAutoDrive_UnsupportedVehicle",
    MANUAL = "UI_MinidoracatAutoDrive_ManualOverride",
    ARRIVED = "UI_MinidoracatAutoDrive_Arrived",
    START = "UI_MinidoracatAutoDrive_Start",
    STOP = "UI_MinidoracatAutoDrive_Stop",
    STUCK = "UI_MinidoracatAutoDrive_StopStuck",
    UNSTICK = "UI_MinidoracatAutoDrive_Unstick",
    DETOUR = "UI_MinidoracatAutoDrive_Detour",
    BLOCKED = "UI_MinidoracatAutoDrive_Blocked",
    RESUME = "UI_MinidoracatAutoDrive_Resume",
    DODGE = "UI_MinidoracatAutoDrive_Dodge",
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
        -- nav API v3：改道重算。成功＝覆寫路線快取（主 MOD 語意——之後的
        -- requestRoute 回 detour 線）；nav.detourRoute nil＝noroad（無替代路）
        requestDetour = function(playerNum, tx, ty, ax, ay, ar)
            local nav = drive.nav
            nav.detourCalls = (nav.detourCalls or 0) + 1
            nav.lastDetour = { pn = playerNum, tx = tx, ty = ty, ax = ax, ay = ay, ar = ar }
            if nav.detourRoute then
                nav.route = nav.detourRoute
                return nav.detourRoute, "ok"
            end
            return nil, "noroad"
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
    for _ = 1, 2 do driveTick(dp, dveh) end
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
do
    local info = { MDAD.Drive.slowdownInfo(0) }
    checkEq(table.concat(info, ","), "2,48,3,25,15,10,20",
        "HUD slowdownInfo 與 production 判定常數同源：range／band／三階殭屍／屍體 cap")
    setSandbox({ AutoDriveMaxSpeed = 100 })
    info = { MDAD.Drive.slowdownInfo(0) }
    checkEq(info[2], 110, "高速沙盒設定時 tooltip 前視範圍同步成 110 公尺")
    setSandbox({ InstallSkillGate = true, NeedItemForNav = false,
        NeedItemForAutoDrive = true, AutoDriveMaxSpeed = 40 })
end
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
installNavApi(2.5)
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "fractional nav API version is rejected at trust boundary")
installNavApi(0 / 0)
driveReset(dveh)
checkFalse(MDAD.Drive.start(dp), "nonfinite nav API version is rejected at trust boundary")

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

setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false, AutoDriveMaxSpeed = 40, RightLaneBias = 0 })
driveReset(dveh)
checkTrue(MDAD.Drive.start(dp), "沙盒關掉模組需求時不裝模組也能開")
MDAD.Drive.stop(0, nil)
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = true, AutoDriveMaxSpeed = 40, RightLaneBias = 0 })
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
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = true, AutoDriveMaxSpeed = 40, RightLaneBias = 0 })

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

-- 控制幾何必須是原車 script 的可信 extents/COM；不可拿 fallback 盒啟動。
do
    local realBuild = MDADVehicleProfile.build
    MDADVehicleProfile.build = function()
        return { geometryValid = false, halfW = 0.9, halfL = 2.2 }
    end
    driveReset(dveh)
    checkFalse(MDAD.Drive.start(dp), "geometryValid=false：拒絕啟動")
    checkEq(haloKey(), DKEY.UNSUPPORTED, "不支援載具提示 UnsupportedVehicle")
    MDADVehicleProfile.build = realBuild
end


-- 條件齊備
driveReset(dveh)
checkTrue(MDAD.Drive.start(dp), "條件齊備：啟動成功")
checkTrue(MDAD.Drive.isActive(0), "啟動後 isActive")
checkEq(#halos, 1, "啟動只提示一次")
checkEq(haloKey(), DKEY.START, "啟動提示 Start")
checkEq(halos[1] and halos[1].kind, "good", "啟動是綠字（addGoodText）")
checkEq(#sentClient, 2, "啟動成功即送 NavUsage＋Auto Usage 兩則 actor-bound heartbeat")
checkEq(sentClient[1] and sentClient[1].command, MDAD.CMD_NAV_USAGE,
    "啟動先續期 GPS NavUsage")
checkEq(sentClient[1] and sentClient[1].args.active, true, "NavUsage 只宣告 active=true")
checkEq(sentClient[2] and sentClient[2].command, MDAD.CMD_USAGE,
    "自駕使用獨立 Usage command")
checkEq(sentClient[2] and sentClient[2].args.vehicleId, dveh:getId(),
    "Auto heartbeat 只帶 server 可重查的 vehicleId")
checkEq(sentClient[2] and sentClient[2].args.active, true, "Auto heartbeat 宣告 active=true")
checkEq(drive.nav.lastTargetNum, 0, "查目標帶的是玩家 slot 編號")
checkEq(drive.nav.lastTx, 300, "要路線時把目標座標原樣傳進去")
checkEq(drive.nav.lastTy, 0, "目標 y 也原樣傳進去")
do
    setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = true,
        AutoDriveMaxSpeed = 100, RightLaneBias = 0 })
    local _, _, shownCap = MDAD.Drive.hudState(0)
    checkEq(shownCap, 40,
        "active HUD 顯示 session 實際 40 上限，不先顯示尚未重啟套用的 sandbox 100")
    setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = true,
        AutoDriveMaxSpeed = 40, RightLaneBias = 0 })
end
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
checkEq(#sentClient, 0, "重複 start 不重送 heartbeat")

nowMs = nowMs + 1100
driveReset(dveh)
driveTick(dp, dveh)
checkEq(#sentClient, 2, "active session 1.1 秒快速重試初始 heartbeat，之後改每 5 秒")
checkEq(sentClient[1] and sentClient[1].command, MDAD.CMD_NAV_USAGE,
    "快速重試先續期 GPS")
checkEq(sentClient[2] and sentClient[2].args.active, true, "快速重試的 Auto heartbeat 維持 active=true")

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

-- 300 points now use geometry/coast/brake/merge/accel = 1497 bounded operations;
-- 128 per frame means the first 11 frames build and the 12th starts control.
resetStats()
MDAD.Drive.stop(0, nil)
checkEq(#sentClient, 1, "clearSession 對 stop／抵達／失效共用 best-effort off")
checkEq(sentClient[1] and sentClient[1].command, MDAD.CMD_USAGE,
    "停止使用同一 Usage command")
checkEq(sentClient[1] and sentClient[1].args.active, false, "停止 heartbeat 宣告 active=false")
drive.nav.route = newRoute(300, 0, 0, 4, 0)
dveh._x, dveh._y, dveh._speed, dveh._steering = 0, 0, 20, 0
setHeading(dveh, 0.3)
dveh._regulator = true   -- 玩家上車前自己設的定速：建構期必須是關著的
driveReset(dveh)
checkTrue(MDAD.Drive.start(dp), "長路線也能啟動（建表攤到後續幀）")
checkEq(drive.calls.regulatorOff, 1, "長路線一樣在啟動當下就把舊定速關掉")
checkEq(dveh._regulator, false, "建表還沒開始，舊定速就已經失效")

driveReset(dveh)
for _ = 1, 11 do driveTick(dp, dveh) end
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
checkEq(dveh._imp.total, 1, "第 12 幀剖面建好，開始控車")
checkEq(drive.calls.setRegulatorSpeed, 1, "第 12 幀開始控速")
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
checkEq(drive.calls.fractionalRegSpeed, 0,
    "寫進原版 regulator 的速度是整數（儀表不露出長小數）")
checkTrue(drive.calls.maxRegSpeed <= 40,
    "定速不超過沙盒 AutoDriveMaxSpeed=40（實得 " .. tostring(drive.calls.maxRegSpeed) .. "）")
checkEq(drive.calls.forceBrake, 0, "正常跟線不搶煞車")
checkEq(drive.nav.targetCalls, 0, "60 幀都在 250ms 節流窗內：完全沒重查導航目標")

-- Phase F: arbitrary actual-target gap never force-brakes. Normal 20/45/90°
-- curves coast through the envelope; only an actual hard curvature breach brakes.
do
    local savedSpeed = dveh._speed
    local function productionCurveRoute(degrees)
        local pts, radius = {}, 20
        for i = 0, 10 do
            pts[#pts + 1] = i * 4
            pts[#pts + 1] = 0
        end
        local steps = math.ceil(degrees / 5)
        for i = 1, steps do
            local a = -math.pi * 0.5 + math.rad(degrees) * i / steps
            pts[#pts + 1] = 40 + radius * math.cos(a)
            pts[#pts + 1] = 20 + radius * math.sin(a)
        end
        local endA = math.rad(degrees)
        local ex, ey = pts[#pts - 1], pts[#pts]
        for i = 1, 25 do
            pts[#pts + 1] = ex + math.cos(endA) * i * 4
            pts[#pts + 1] = ey + math.sin(endA) * i * 4
        end
        return { pts = pts }
    end

    for _, degrees in ipairs({ 20, 45, 90 }) do
        MDAD.Drive.stop(0, nil)
        drive.nav.route = productionCurveRoute(degrees)
        dveh._x, dveh._y, dveh._speed, dveh._stopped = 39, 0, 10, false
        setHeading(dveh, 0)
        checkTrue(MDAD.Drive.start(dp),
            degrees .. "° production curve profile starts")
        for _ = 1, 16 do driveTick(dp, dveh) end
        driveReset(dveh)
        driveTick(dp, dveh)
        checkEq(drive.calls.forceBrake, 0,
            degrees .. "° production curve coasts without forceBrake")
        checkEq(dveh._imp.total, 1,
            degrees .. "° production curve retains steering authority")
    end

    MDAD.Drive.stop(0, nil)
    drive.nav.route = newRoute(300, 0, 0, 4, 0)
    dveh._x, dveh._y, dveh._speed = 0, 0, 20
    setHeading(dveh, 0)
    checkTrue(MDAD.Drive.start(dp), "restore straight production profile")
    for _ = 1, 20 do driveTick(dp, dveh) end
    driveReset(dveh)

    local realControl = MDADFollower.control
    MDADFollower.control = function(_, state)
        state.curveValid = true
        state.curveHardActive = false
        state.curveKappa, state.curveCapKmh = 0, 29.6
        return 1, 29.6, 100, false, 0, 0, 0
    end
    dveh._speed = 100
    driveReset(dveh)
    driveTick(dp, dveh)
    checkEq(drive.calls.forceBrake, 0,
        "straight actual-target gap alone never force-brakes")
    checkEq(drive.calls.setRegulatorSpeed, 1,
        "straight overspeed keeps regulator/coast command")

    MDADFollower.control = function(_, state)
        state.curveValid = true
        state.curveHardActive = false
        state.curveKappa, state.curveCapKmh = 0.2, 5
        return 1, 5, 100, false, 0, 0, 0
    end
    dveh._speed = 20
    driveReset(dveh)
    driveTick(dp, dveh)
    checkEq(drive.calls.forceBrake, 0,
        "future horizon curvature only coasts; straight current segment never hard-brakes")
    checkEq(dveh._imp.total, 1,
        "future curve cap preserves current straight steering authority")

    MDADFollower.control = function(_, state)
        state.curveValid = true
        state.curveHardActive = true
        state.curveKappa, state.curveCapKmh = 0.2, 5
        return 1, 5, 100, false, 0, 0, 0
    end
    dveh._speed = 20
    driveReset(dveh)
    driveTick(dp, dveh)
    checkEq(drive.calls.forceBrake, 1,
        "current SEG_ARC actual breach hard-brakes")
    checkEq(dveh._imp.total, 0,
        "hard curvature breach never emits a competing steering impulse")

    MDADFollower.control = function(_, state)
        state.curveValid = true
        state.curveHardActive = false
        state.curveKappa, state.curveCapKmh = 0, 0
        return 0, 0, 100, false, 0, 0, 0
    end
    dveh._speed = 0
    driveReset(dveh)
    driveTick(dp, dveh)
    checkTrue(MDAD.Drive.isActive(0), "legal target=0 remains an active non-fault command")
    checkEq(drive.calls.forceBrake, 0, "legal target=0 does not masquerade as invalid")

    MDADFollower.control = function(_, state)
        state.curveValid = true
        state.curveHardActive = false
        state.curveKappa, state.curveCapKmh = 0, 40
        return 1, 0 / 0, 100, false, 0, 0, 0
    end
    dveh._speed = 20
    driveReset(dveh)
    driveTick(dp, dveh)
    checkEq(drive.calls.forceBrake, 1,
        "non-finite cruise aggregation best-effort brakes in the same frame")
    checkEq(dveh._imp.total, 0, "invalid command emits no steering impulse")
    checkFalse(MDAD.Drive.isActive(0), "invalid command visibly terminates the session")
    checkEq(haloKey(), DKEY.UNSUPPORTED, "invalid command reports unsupported dynamics")
    MDADFollower.control = realControl
    dveh._speed = savedSpeed
end

-- 沙盒上限的三段夾限：太小夾到 5、太大夾到 120、非數字回預設 70。
-- 一律用 300 點的長路線，才有足夠跑道讓起點速度真的頂到上限（短路線會被
-- follower 的反向制動壓低，測不到夾限）。車頭要幾乎對準路線（< 誤差減速的
-- 10° 門檻）：帶著 0.3 rad 誤差時 follower 會收油，觀測到的是「夾限×收油」
-- 的合成值而不是夾限本身。檔位切瘋狂（gearCap＝fake 車極速 200 > 沙盒）：
-- 量測目標是**沙盒天花板**，預設檔位運動 70 會把 120 的案例蓋成 70；999 案
-- 沙盒夾 120，且 >85 觸發高速檔（掃描帶 110m、感知上限 120）→ 頂到 120。
dp._modData.MDADGear = 4
for _, ok in ipairs({ { 1, 5 }, { 999, 120 }, { "fast", 70 } }) do
    MDAD.Drive.stop(0, nil)
    setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = true, AutoDriveMaxSpeed = ok[1], RightLaneBias = 0 })
    dveh._x, dveh._y, dveh._speed = 0, 0, 0
    setHeading(dveh, 0.0) -- 完全對準：高速誤差護欄（>70 按誤差折返）不介入
    drive.nav.route = newRoute(300, 0, 0, 4, 0)
    checkTrue(MDAD.Drive.start(dp), "AutoDriveMaxSpeed=" .. tostring(ok[1]) .. " 可以啟動")
    driveReset(dveh)
    for _ = 1, 72 do driveTick(dp, dveh) end
    local expectedCap = ok[2]
    if expectedCap > 15 then expectedCap = 15 end
    checkTrue(drive.calls.maxRegSpeed > 0 and drive.calls.maxRegSpeed <= expectedCap,
        "sensor missing keeps real command within gate cap " .. expectedCap
        .. "（實得 " .. tostring(drive.calls.maxRegSpeed) .. "）")
    checkEq(drive.calls.badRegSpeed, 0, "夾限後的定速仍是非負數字")
end
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = true, AutoDriveMaxSpeed = 40, RightLaneBias = 0 })
dp._modData.MDADGear = nil -- 還原預設檔位（後續情境量 40 上限，運動 70 不干擾）

-- 檔位 cap 必須在 sensor 塊之外（codex M5.5 對抗審 BLOCKING）：此區
-- MDADSensor 尚未 require（在情境二十八才載入），session.sensor＝false＝
-- 感知缺席退 M3 純跟線——檔位照樣要生效。
dp._modData.MDADGear = 1 -- 輕鬆 30 < 沙盒 40
MDAD.Drive.stop(0, nil)
dveh._x, dveh._y, dveh._speed = 0, 0, 0
setHeading(dveh, 0.05)
drive.nav.route = newRoute(300, 0, 0, 4, 0)
checkTrue(MDAD.Drive.start(dp), "感知缺席＋輕鬆檔情境啟動")
driveReset(dveh)
for _ = 1, 72 do driveTick(dp, dveh) end
checkTrue(drive.calls.maxRegSpeed > 0 and drive.calls.maxRegSpeed <= 15,
    "感知缺席時實際 command 受 sensor gate <=15（實得 "
    .. tostring(drive.calls.maxRegSpeed) .. "）")
-- hudState 契約（M5.5b HUD 的資料面；多值純量、不洩漏 session）。
-- do block：釋放 local slot（harness 主 chunk 貼 PUC 200 活躍上限）
do
    local hudKey, hudGear, hudCap, hudZ, hudC = MDAD.Drive.hudState(0)
    checkEq(hudKey, "follow", "hudState 狀態鍵：跟線中")
    checkEq(hudGear, 1, "hudState 檔位＝輕鬆")
    checkEq(hudCap, 30, "hudState 有效上限＝min(檔位 30, 沙盒 40)")
    checkEq(hudZ, true, "hudState 殭屍減速：政策預設由玩家決定＋偏好預設開")
    checkEq(hudC, true, "hudState 屍體減速：同上")
    checkEq(MDAD.Drive.hudState(9), nil, "無 session 的槽回 nil")
    checkEq(MDAD.Drive.effectiveCap(0, dveh), 30,
        "effectiveCap：無論 session 是否存在都與 hudState 同一上限")
    checkEq(MDAD.Drive.hudStartReason(0), nil,
        "hudStartReason：引擎／模組／導航目標齊全可啟動")
    local savedState, savedRoute = drive.nav.state, drive.nav.route
    drive.nav.state = "building"
    checkEq(MDAD.Drive.hudStartReason(0), DKEY.ROUTE,
        "hudStartReason：路網仍在 building 不得誤顯示可啟動")
    drive.nav.state, drive.nav.route = "noroad", nil
    checkEq(MDAD.Drive.hudStartReason(0), DKEY.ROUTE,
        "hudStartReason：noroad 沒有可用路線時回 RouteNotReady")
    drive.nav.state, drive.nav.route = savedState, savedRoute
    local savedTX = drive.nav.tx
    drive.nav.tx = nil
    checkEq(MDAD.Drive.hudStartReason(0), DKEY.ROUTE,
        "hudStartReason：未設導航目標回短狀態可用的原因鍵")
    drive.nav.tx = savedTX
    -- 偏好切換即時反映（setSlowPref 直接刷新 active session 快取）
    MDAD.Drive.setSlowPref(0, "zombie", false)
    local _, _, _, hudZ2 = MDAD.Drive.hudState(0)
    checkEq(hudZ2, false, "關掉殭屍減速偏好：hudState 即時反映")
    checkEq(dp._modData.MDADZombieSlow, false, "偏好寫進 player modData")
    MDAD.Drive.setSlowPref(0, "zombie", true)
end
dp._modData.MDADGear = nil
MDAD.Drive.stop(0, nil)

-- No fixed 70km/h stack remains. Misalignment uses the profile's continuous
-- heading envelope (and adaptive sessions additionally use the named align gate).
dp._modData.MDADGear = 4
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = true, AutoDriveMaxSpeed = 100, RightLaneBias = 0 })
MDAD.Drive.stop(0, nil)
dveh._x, dveh._y, dveh._speed = 0, 0, 0
setHeading(dveh, 0.0873)
drive.nav.route = newRoute(300, 0, 0, 4, 0)
checkTrue(MDAD.Drive.start(dp), "高速無固定帽情境啟動")
driveReset(dveh)
for _ = 1, 72 do driveTick(dp, dveh) end
checkTrue(drive.calls.maxRegSpeed > 0 and drive.calls.maxRegSpeed <= 15,
    "即使對正，sensor missing gate 仍實際限制 <=15（實得 "
    .. tostring(drive.calls.maxRegSpeed) .. "）")
setHeading(dveh, 0.21)
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed <= 15,
    "misalignment cannot bypass sensor gate（實得 "
    .. tostring(drive.calls.maxRegSpeed) .. "）")
dp._modData.MDADGear = nil
MDAD.Drive.stop(0, nil)
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = true, AutoDriveMaxSpeed = 40, RightLaneBias = 0 })

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
checkTrue(MDAD.Drive.start(dp), "短路線啟動（coast/brake 分幀）")
driveReset(dveh)
driveTick(dp, dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 1, "短路線第二幀建完剖面並施力")
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
-- 給飽和轉向。**速度固定 3 km/h**：大誤差速度閘（誤差 >90° 且速度 >5 主動煞停、
-- 近停才旋轉——帶動量旋轉＝漂移甩出 22m，st 88,113 遙測）放行的區間內量。
-- 不抄 production 的係數，只圈出可用區間：下界＝夠力調頭，上界＝不會把車彈飛。
MDAD.Drive.stop(0, nil)
dveh._x, dveh._y, dveh._steering = 0, 0, 0
dveh._speed, dveh._mass = 3, 1200
setHeading(dveh, 2.8)
drive.nav.route = newRoute(40, 0, 0, 4, 0)
checkTrue(MDAD.Drive.start(dp), "轉向飽和情境啟動")
driveReset(dveh)
driveTick(dp, dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 1, "轉向飽和幀照樣只施力一次")
drive.f3 = impulseMag(dveh)
checkTrue(drive.f3 >= 8000, "1200kg／3km/h／調頭飽和：衝量至少 8000（實得 "
    .. tostring(drive.f3) .. "；誤差 >90° 走耦力模式，力量乘 ROTATE_FORCE_SCALE"
    .. "——全額調頭＝實機快速循轉，縮到四成才是緩慢平穩的迴轉）")
checkTrue(drive.f3 <= 60000, "同一組條件下衝量不超過 60000（實得 "
    .. tostring(drive.f3) .. "；再大調頭又會轉太快）")

-- 耦力調頭：誤差 > 90° 時衝量與施力主臂同乘幀奇偶——力矩恆定同向、側向中心力
-- 幀間抵消＝原地旋轉不橫滑（橫推調頭實機會把車推橫滑 24 km/h 滑出路外撞東西）
drive.rotSnapX, drive.rotSnapTq = dveh._imp.x, dveh._imp.torqueY
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(dveh._imp.x * drive.rotSnapX < 0,
    "調頭模式：連續兩幀側向中心力反號（幀間抵消，不推車橫滑）")
checkTrue(dveh._imp.torqueY * drive.rotSnapTq > 0,
    "調頭模式：力矩與幀奇偶無關，持續同向（q² 相消）")

-- 大誤差速度閘：同樣的 160° 誤差、30 km/h → 主動煞停、本幀不施力
dveh._speed = 30
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 0,
    "誤差 160°、車速 30 km/h：速度閘煞停不施側推（yield 中調頭再放手不得瞬間甩車）")
checkTrue(drive.calls.forceBrake > 0, "帶動量的調頭需求：主動煞停（不只滑行等速）")
dveh._speed = 4
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 1, "同誤差、車速降到 4（≤5 近停）：放行，開始施力調頭")

-- 速度增益：0 km/h 仍有轉向權威、護欄內隨速度單調上升；封頂（60 cap）用小誤差
-- （30°，護欄不介入）在 70 vs 200 km/h 驗——兩者 steer 相同，衝量只差 gain(v)
dveh._speed = 0
driveReset(dveh)
driveTick(dp, dveh)
drive.f0 = impulseMag(dveh)
checkTrue(drive.f0 > 0 and drive.f0 == drive.f0 and drive.f0 < math.huge,
    "0 km/h 仍有有限且非零的轉向權威（原地掉頭要推得動，實得 " .. tostring(drive.f0) .. "）")
checkTrue(drive.f3 > drive.f0, "轉向衝量隨速度單調上升（0 km/h＝" .. tostring(drive.f0)
    .. "、3 km/h＝" .. tostring(drive.f3) .. "）")

MDAD.Drive.stop(0, nil)
dveh._x, dveh._y, dveh._speed = 0, 0, 70
setHeading(dveh, 0.52)  -- 30°：護欄之下、死區之上
drive.nav.route = newRoute(40, 0, 0, 4, 0)
checkTrue(MDAD.Drive.start(dp), "封頂情境啟動")
driveReset(dveh)
driveTick(dp, dveh)
drive.f70 = impulseMag(dveh)
dveh._speed = 200
driveReset(dveh)
driveTick(dp, dveh)
drive.f200 = impulseMag(dveh)
checkTrue(drive.f70 > 0, "小誤差高速照常施力（實得 " .. tostring(drive.f70) .. "）")
local capDiff = drive.f200 - drive.f70
if capDiff < 0 then capDiff = -capDiff end
checkTrue(capDiff <= drive.f70 * 0.02,
    "70 km/h 以上封頂：量級不再隨速度成長（70＝" .. tostring(drive.f70)
    .. "、200＝" .. tostring(drive.f200) .. "；±2% 內為控制歷史量測差）")

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

-- 放手：恢復是「連續 2 秒無輸入」的時間制（舊制 10 幀＝手一離開就接管，玩家
-- 調頭到一半就被暴力搶回）。放手瞬間先記時戳、觀察期不施力，滿 2 秒才恢復
-- 並提示，且恢復幀會清 PID 歷史（保留投影游標）。
dveh._steering = 0
driveReset(dveh)
for _ = 1, 9 do driveTick(dp, dveh) end
checkEq(dveh._imp.total, 0, "放手後時間未滿：觀察期不施力（幀數再多也一樣）")
checkEq(drive.calls.setRegulatorSpeed, 0, "觀察期不控速")
checkEq(drive.pool.alloc, 0, "觀察期不取向量池")
nowMs = nowMs + 1999
driveTick(dp, dveh)
checkEq(dveh._imp.total, 0, "1999ms：還差 1ms，不恢復")
nowMs = nowMs + 1
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 1, "滿 2 秒無輸入：恢復跟線並施力")
checkEq(drive.calls.setRegulatorSpeed, 1, "恢復後重新控速")
checkEq(haloKey(), DKEY.RESUME, "恢復時頭上提示 Resume")
checkEq(halos[1] and halos[1].kind, "good", "恢復是綠字")

-- 油門／煞車沒有等價的類比觀測（isGasPedalPressed 在 regulator 供油時恆真），
-- 所以改看鍵位；五個綁定名都必須讓位
for _, ok in ipairs({ "Left", "Right", "Forward", "Backward", "Brake" }) do
    drive.keys[ok] = true
    driveReset(dveh)
    driveTick(dp, dveh)
    checkEq(dveh._imp.total, 0, ok .. " 鍵按下：當幀不施力")
    checkTrue(MDAD.Drive.isActive(0), ok .. " 鍵按下不結束 session")
    drive.keys[ok] = false
    driveTick(dp, dveh)          -- 記乾淨時戳
    nowMs = nowMs + 2100
    driveTick(dp, dveh)          -- 滿 2 秒恢復
end
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 1, "五個鍵都放開並等滿恢復緩衝後回到跟線")

-- =====================================================================
-- 情境二十二：超速主動煞車與抵達停車
-- =====================================================================
scenario("超速主動煞車；抵達目的地煞停，停妥後交還控制權，途中玩家接手立刻放手")

-- regulator 只會「不再供油」，下坡或超速時它不會煞車，所以超出目標太多要自己煞
driveReset(dveh)
driveTick(dp, dveh)
checkEq(drive.calls.regulatorOn, 1, "沒超速時 regulator 開著供油")
checkEq(drive.calls.forceBrake, 0, "沒超速不煞車")

setHeading(dveh, 0)
dveh._speed = 100
driveReset(dveh)
driveTick(dp, dveh)
checkEq(drive.calls.forceBrake, 0,
    "straight overspeed without a hard stopping/curvature breach does not forceBrake")
checkEq(drive.calls.regulatorOn, 1, "straight overspeed coasts under regulator command")
checkEq(drive.calls.setRegulatorSpeed, 1, "straight overspeed still writes the lower command")
checkTrue(dveh._imp.total <= 1, "straight overspeed still obeys one-impulse maximum")
checkEq(drive.pool.live, 0, "coast path同樣不漏 release")
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
-- 而車其實還在 20 公尺外的路邊。此佈置對前視點的朝向誤差 ≈101°、車速 20：
-- 大誤差速度閘（>90° 且 >5 km/h）會**主動煞停**——先停、原地轉向、再爬回
-- 終點，這是調頭動量甩出（st 88,113）修正後的新契約；但絕不宣告抵達。
dveh._x, dveh._y = 26, 20
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.forceBrake > 0, "橫向偏離終點 20m＋誤差 >90°：速度閘先煞停（不帶動量轉向）")
checkEq(dveh._imp.total, 0, "煞停幀不施轉向")
checkTrue(MDAD.Drive.isActive(0), "橫向偏離終點：session 繼續（不是 arrive）")
-- 這個早期 M3 fixture 尚未載入 Sensor／Corridor；RETURN 不得成為啟動依賴，
-- 因此保持既有 pure follower 主動煞停後跟線，而不是誤進 RETURN HOLD。
checkEq(drive.calls.setRegulatorSpeed, 1, "alignment brake may follow an already-issued coast command")
checkEq(drive.calls.regulatorOn, 1, "alignment handling remains best-effort after regulator update")
dveh._y = 0

dveh._x = 26           -- 沿路徑剩 2 公尺、離終點直線距離也是 2 公尺 <= ARRIVE_M(5)
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._imp.total, 0, "抵達當幀不再施力（停車時不能還在推車）")
checkEq(drive.calls.forceBrake, 1, "pure follower brake 與 arrive 共用當前冪等煞車狀態")
checkEq(drive.calls.regulatorOff, 1, "pure follower brake 與 arrive 都維持 regulator 關閉")
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
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = true, AutoDriveMaxSpeed = 40, RightLaneBias = 0 })

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

-- 抵達競態：主 MOD 在距目標 NAV_ARRIVE_DIST（5 格）內**每幀**自動清除導航目標
-- （小地圖「走到旗子就收旗」），必然搶在 follower reached（沿線開完＋停妥）之前
-- ——目標消失但車已在剛才目標的抵達圈（12 格）內＝「到達」：轉入 arrive 煞停
-- 流程收綠字，不是紅字 LostRoute（2026-08-28 實機：每次開到目的地都閃紅字）
checkTrue(armDrive(), "抵達清除競態情境重新啟動")
dveh._x = 296                      -- 距 armDrive 目標 (300,0) 4 格＝主 MOD 清除圈內
drive.nav.tx = nil                 -- 主 MOD navCheckArrival 收走目標
nowMs = nowMs + 250
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(MDAD.Drive.isActive(0), "抵達圈內目標消失：不結束（轉入到站煞停）")
checkEq(#halos, 0, "接管當幀不彈紅字")
checkTrue(drive.calls.forceBrake > 0, "接管當幀開始煞停")
dveh._speed = 0
dveh._stopped = true
driveReset(dveh)
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "停妥後結束 session")
checkEq(haloKey(), DKEY.ARRIVED, "提示已抵達（不是路線遺失）")

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
checkTrue(armDrive(), "zero forward vector 情境重新啟動")
dveh._fwdX, dveh._fwdY = 0, 0
driveReset(dveh)
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0),
    "finite zero-length forward vector visibly fail-stops")
checkTrue(drive.calls.regulatorOff >= 1,
    "zero forward vector disables regulator before visible stop")
checkEq(drive.calls.forceBrake, 0,
    "zero forward vector cannot issue a steering-dependent brake path")
checkEq(dveh._imp.total, 0, "zero forward vector never emits steering impulse")
checkEq(drive.pool.live, 0, "zero forward vector returns the pooled vector before stop")
checkEq(haloKey(), DKEY.UNSUPPORTED, "zero forward vector reports unsupported dynamics")
setHeading(dveh, 0)
do
checkTrue(armDrive(), "missing curve state 情境重新啟動")
local strictCurveControl = MDADFollower.control
MDADFollower.control = function(_, state)
    state.curveValid = false
    state.curveHardActive = false
    state.curveKappa, state.curveCapKmh = 0, 0
    return 0, 20, 100, false, 0, 0, 0
end
driveReset(dveh)
driveTick(dp, dveh)
MDADFollower.control = strictCurveControl
checkFalse(MDAD.Drive.isActive(0),
    "missing curve validity is a terminal dynamics fault")
checkTrue(drive.calls.regulatorOff >= 1 and drive.calls.forceBrake >= 1,
    "invalid curve state disables regulator and best-effort brakes")
checkEq(dveh._imp.total, 0, "invalid curve state never emits steering impulse")
checkEq(haloKey(), DKEY.UNSUPPORTED, "invalid curve state reports unsupported dynamics")
end

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
driveTick(dp, dveh)
checkEq(drive.spy.control, 1, "第二幀剖面建完並呼叫一次 control")
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

-- New 300-point profile needs 12 total bounded build calls; cutover already did one.
driveReset(dveh)
for _ = 1, 10 do driveTick(dp, dveh) end
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
checkEq(#drive.menus[0].slices, 3, "原版的片還在，自駕片＋檔位片補在後面")
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
-- 檔位片：文字帶 GearSlice 鍵（fake getText 丟參數回鍵名）、點了循環到下一檔。
-- do block：釋放 local slot（主 chunk 貼 PUC 200 活躍上限）
do
    local gearOpt = drive.menus[0].slices[3]
    checkEq(noteReason(gearOpt.text), "UI_MinidoracatAutoDrive_GearSlice", "第三片是檔位片")
    checkEq(MDAD.Drive.getGear(0), 3, "未設定過檔位：預設運動（升級不無聲降速）")
    gearOpt.command(gearOpt.arg1)
    checkEq(MDAD.Drive.getGear(0), 4, "點檔位片：循環到下一檔（運動→瘋狂）")
    checkEq(haloKey(), "UI_MinidoracatAutoDrive_GearInsane", "切檔頭上綠字回饋新檔位")
    checkEq(dp._modData.MDADGear, 4, "檔位寫進 player modData（跨 session 持久）")
    gearOpt.command(gearOpt.arg1)
    checkEq(MDAD.Drive.getGear(0), 1, "瘋狂再切：繞回輕鬆")
    dp._modData.MDADGear = nil
end
driveReset(dveh)

driveReset(dveh)
ISVehicleMenu.showRadialMenu(dp)
checkEq(#drive.texCalls, 0, "第二次開選單不再查貼圖（已快取）")
checkEq(#drive.menus[0].slices, 3, "第二次開選單仍然只補兩片（自駕＋檔位）")

-- 回呼：啟動 → 標題變成停止 → 再按一次關閉
driveReset(dveh)
opt.command(opt.arg1)
checkTrue(MDAD.Drive.isActive(0), "radial 回呼真的啟動自駕")
checkEq(haloKey(), DKEY.START, "啟動提示 Start")
driveTick(dp, dveh)
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
checkEq(#drive.menus[0].slices, 3,
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
checkEq(#drive.menus[0].slices, 3, "重複載入不會把自駕／檔位片加兩次")

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
-- 情境二十七：單一 progress supervisor（Sensor 缺席時 rear unknown fail-closed）
-- =====================================================================
scenario("進度監督：70km/h 輪速但 2.5s 僅移 0.04m 進 suspect；rear unknown 零倒車衝量；旋轉 10° 視為健康")

setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
    AutoDriveMaxSpeed = 70, ObstaclePolicy = 1, RightLaneBias = 0 })
dp._modData.MDADGear = 3
checkTrue(armDrive(), "高速零進度情境啟動")
dveh._speed = 70
-- armDrive 的第一個 follow 幀已建立 progress anchor；保持同 heading，只移 0.04m。
nowMs = nowMs + 2501
dveh._x = 0.04
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(MDAD.Drive.isActive(0), "2.5s 零進度先進 recover stop，不在向量仍借出時停 session")
checkTrue(drive.calls.forceBrake >= 1, "suspect 的 unknown near 進 recovery brake")
checkEq(dveh._imp.total, 0, "suspect/recover transition 零 impulse")

-- reported wheel speed 收到 0 後才做 rear check；Sensor 缺席＝unknown/unloaded，
-- 必須 fail-closed 停止，不能沿用舊版「感知缺席也直接倒車」。
dveh._speed = 0
nowMs = nowMs + 16
driveReset(dveh)
driveTick(dp, dveh)
checkFalse(MDAD.Drive.isActive(0), "rear unknown：停止 session")
checkEq(haloKey(), DKEY.STUCK, "rear unknown 使用 StopStuck 提示")
checkEq(dveh._imp.total, 0, "rear unknown 全程零 reverse impulse")

-- Rotation itself is progress: 12° > 10° re-arms the 2.5s window even at zero world/S.
checkTrue(armDrive(), "旋轉進度情境啟動")
dveh._speed = 0
nowMs = nowMs + 2600
setHeading(dveh, 0.52)
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(MDAD.Drive.isActive(0), "原地 yaw 12° 視為健康，不進 recovery")
checkTrue(haloKey() ~= DKEY.UNSTICK and haloKey() ~= DKEY.STUCK,
    "旋轉進度無脫困／放棄提示")
MDAD.Drive.stop(0, nil)

-- =====================================================================
-- 情境二十八：走廊感知與繞行（真 MDAD_Sensor + MDAD_Corridor，假世界）
-- =====================================================================
-- 到這裡才載入感知兩檔：前面所有自駕情境都跑在 session.sensor=false 的 M3 退路上
-- ——那也是 production 契約（檔案樹缺 Sensor 不得炸、跟線照常）。實機引擎會把
-- client 目錄全部載入，感知路徑由本情境覆蓋。
require "MDAD_Corridor"
require "MDAD_Sensor"
scenario("走廊感知：淨空直行、中線障礙繞行、堵死煞停可自動恢復、殭屍跟車未載入減速、停車政策不繞")

checkEq(type(MDADCorridor), "table", "production shared/MDAD_Corridor.lua 真的載入了")
checkEq(type(MDADSensor), "table", "production client/MDAD_Sensor.lua 真的載入了")

-- 感知的假世界。Sensor 的 PZ 入口全走參數（cell、vehicle）與延後綁定
-- （IsoFlagType/IsoObjectType/instanceof 首輪掃描才讀），這裡塞替身即可。
IsoFlagType = { water = "water", solidfloor = "solidfloor", doorN = "doorN", doorW = "doorW" }
IsoObjectType = { isMoveAbleObject = 28 }
function instanceof(obj, cls) return type(obj) == "table" and obj._class == cls end
drive.world = {}
drive.cellVehicles = {}  -- 全域車輛清單（調頭探測 probeAround 走 Set:iterator() 迭代）
drive.vehGeo = {}        -- 格級車輛佔位（production 走 square:getVehicleContainer() 幾何查詢）
drive.cell = {
    getGridSquare = function(_, x, y, _z) return drive.world[x * 100000 + y] end,
    -- 42.20.4 的 getVehicles() 回 Set<BaseVehicle>：**沒有 get(int)**，只能 iterator。
    -- fake 也只給 iterator/size，production 若倒退回 :get(i-1)（ISVehicleBloodUI 的
    -- 過期寫法，實機 nil call）這裡會當場炸。
    getVehicles = function()
        local i, n = 0, #drive.cellVehicles
        return {
            size = function() return n end,
            iterator = function()
                return {
                    hasNext = function() return i < n end,
                    next = function()
                        i = i + 1
                        return drive.cellVehicles[i]
                    end,
                }
            end,
        }
    end,
}
function getCell() return drive.cell end

function drive.mkSquare(x, y)
    local objs, mv, smv = {}, {}, {}
    local sq = { _objs = objs, _mv = mv, _smv = smv, _floor = false }
    -- production 的水面判定看地板 sprite（getFloor():hasProperty(water)）；
    -- 假格預設無地板物件（回 nil）＝非水。要造水面就把 _floor 換成帶
    -- hasProperty 的假物件。
    sq.getFloor = function() return sq._floor or nil end
    sq._objList = { size = function() return #objs end, get = function(_, i) return objs[i + 1] end }
    sq._mvList = { size = function() return #mv end, get = function(_, i) return mv[i + 1] end }
    -- 屍體容器（IsoDeadBody 住 staticMovingObjects，見 Sensor 的出處註解）
    sq._smvList = { size = function() return #smv end, get = function(_, i) return smv[i + 1] end }
    sq.getObjects = function() return sq._objList end
    -- 格級幾何查詢（IsoGridSquare.getVehicleContainer 的假版）：production 的
    -- 車輛感知唯一入口。單格佔位＝點車（等同舊 movingObjects 錨語意）。
    sq.getVehicleContainer = function() return drive.vehGeo[x * 100000 + y] end
    sq.getMovingObjects = function() return sq._mvList end
    sq.getStaticMovingObjects = function() return sq._smvList end
    drive.world[x * 100000 + y] = sq
    return sq
end

-- 佈滿空格的路面（含路肩）：走廊帶 ±4 公尺內任何 nil 格都算「未載入」，
-- 所以淨空情境也要把格子填好填滿
function drive.fillWorld(x0, x1, y0, y1)
    drive.world = {}
    drive.vehGeo = {}
    for x = x0, x1 do
        for y = y0, y1 do drive.mkSquare(x, y) end
    end
end

-- 鋪路面：把矩形範圍的假格地板換成 blends_street 家族 sprite（路面對中統計
-- 認前綴；hasProperty 回 false＝非水）。production 讀 floorObj:getSpriteName()。
function drive.putRoad(x0, x1, y0, y1)
    for x = x0, x1 do
        for y = y0, y1 do
            local sq = drive.world[x * 100000 + y] or drive.mkSquare(x, y)
            sq._floor = {
                getSpriteName = function() return "blends_street_01_16" end,
                hasProperty = function() return false end,
            }
        end
    end
end

-- 格級車輛：塞進 vehGeo（getVehicleContainer 幾何佔位）。stopped＝isStopped 回傳
-- （true＝硬障礙要繞；false＝跟車減速）。回傳假車物件供情境調 isStopped 波動
-- 或改 _x/_y 模擬移動（production 的跨輪位置比對讀 getX/getY＋getId）。
drive.vehIdSeq = 0
function drive.putVehicle(x, y, stopped)
    drive.vehIdSeq = drive.vehIdSeq + 1
    local id = drive.vehIdSeq
    local v = {
        _class = "BaseVehicle",
        _stopped = stopped,
        _x = x + 0.5,
        _y = y + 0.5,
    }
    v.getX = function() return v._x end
    v.getY = function() return v._y end
    v.getId = function() return id end
    v.isStopped = function() return v._stopped end
    drive.vehGeo[x * 100000 + y] = v
    return v
end

function drive.clearVehicle(x, y)
    drive.vehGeo[x * 100000 + y] = nil
end

-- 移動假車到新格（保 id：production 的跨輪位置比對以 vehicleId 為鍵，
-- 「同一台車動了」必須同 id 才測得到）
function drive.moveVehicle(v, x, y)
    for k, vv in pairs(drive.vehGeo) do
        if vv == v then drive.vehGeo[k] = nil end
    end
    v._x, v._y = x + 0.5, y + 0.5
    drive.vehGeo[x * 100000 + y] = v
end

-- 硬障礙：有碰撞、非地板（Sensor 分類器：shouldHaveCollision 且非 solidfloor＝HARD）
function drive.putSolid(x, y, name)
    local props = { has = function() return false end }
    local sprite = {
        shouldHaveCollision = function() return true end,
        getProperties = function() return props end,
    }
    local sq = drive.world[x * 100000 + y] or drive.mkSquare(x, y)
    sq._objs[#sq._objs + 1] = {
        getSpriteName = function() return name end,
        getSprite = function() return sprite end,
        getProperties = function() return props end,
        getType = function() return nil end,
    }
end

-- 城市路邊物件：分開模擬 collision／HitByCar／StopCar。引擎是 StopCar 才把
-- tile type 設成 isMoveAbleObject；tile 的 IsMoveAble 屬性本身不會。
function drive.putSpriteObject(x, y, name, collision, hitByCar, stopCar)
    local props = {
        has = function(_, key)
            if key == "HitByCar" then return hitByCar == true end
            if key == "StopCar" then return stopCar == true end
            return false
        end,
    }
    local sprite = {
        shouldHaveCollision = function() return collision == true end,
        getProperties = function() return props end,
    }
    local sq = drive.world[x * 100000 + y] or drive.mkSquare(x, y)
    sq._objs[#sq._objs + 1] = {
        getSpriteName = function() return name end,
        getSprite = function() return sprite end,
        getProperties = function() return props end,
        getType = function()
            if stopCar then return IsoObjectType.isMoveAbleObject end
            return nil
        end,
    }
end

-- 樹：sprite **無**碰撞 flag（實機樹對 shouldHaveCollision 隱形，靠
-- instanceof IsoTree 判 HARD——2026-08-28 撞樹鬼打牆的修正）
function drive.putTree(x, y, name)
    local props = { has = function() return false end }
    local sprite = {
        shouldHaveCollision = function() return false end,
        getProperties = function() return props end,
    }
    local sq = drive.world[x * 100000 + y] or drive.mkSquare(x, y)
    sq._objs[#sq._objs + 1] = {
        _class = "IsoTree",
        getSpriteName = function() return name end,
        getSprite = function() return sprite end,
        getProperties = function() return props end,
        getType = function() return nil end,
    }
end

function drive.putMoving(x, y, mv)
    local sq = drive.world[x * 100000 + y] or drive.mkSquare(x, y)
    sq._mv[#sq._mv + 1] = mv
end

-- 地面屍體：進 staticMovingObjects、instanceof IsoDeadBody
function drive.putCorpse(x, y)
    local sq = drive.world[x * 100000 + y] or drive.mkSquare(x, y)
    sq._smv[#sq._smv + 1] = { _class = "IsoDeadBody" }
end

function drive.clearCell(x, y)
    local sq = drive.world[x * 100000 + y]
    if not sq then return end
    for i = #sq._objs, 1, -1 do sq._objs[i] = nil end
    for i = #sq._mv, 1, -1 do sq._mv[i] = nil end
    for i = #sq._smv, 1, -1 do sq._smv[i] = nil end
end

-- 跑完一整輪掃描＋規劃；nowMs 先跨過 250ms 節流窗。
function drive.scanRound(freezeProgress)
    nowMs = nowMs + 300
    -- Most sensor-policy fixtures report a non-zero wheel speed. Keep their mock world
    -- physically consistent with the progress supervisor without changing final geometry:
    -- after the round is complete (nextMs is in the future), move >1m for one tick and
    -- return for one tick. Intentional stuck/contact cases pass true to suppress this.
    for _ = 1, 28 do driveTick(dp, dveh) end
    local av = dveh._speed
    if av < 0 then av = -av end
    if not freezeProgress and av >= 1 and MDAD.Drive.isActive(0) then
        local ox, oy = dveh._x, dveh._y
        dveh._x = ox + dveh._fwdX * 1.1
        dveh._y = oy + dveh._fwdY * 1.1
        driveTick(dp, dveh)
        dveh._x, dveh._y = ox, oy
        driveTick(dp, dveh)
    end
end

-- ① 淨空：跑完一輪，沒有任何檔位介入，定速吃滿剖面（沙盒 40）
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false, AutoDriveMaxSpeed = 40, RightLaneBias = 0 })
drive.fillWorld(-2, 70, -7, 7)
checkTrue(armDrive(), "感知情境啟動")
-- 車頭幾乎對準路線（< 航向誤差減速的 10° 門檻）：本情境量的是「感知檔位」，
-- 不能讓 M3 的誤差收油混進來（armDrive 預設 0.3 rad 會把 40 壓到 35）
setHeading(dveh, 0.05)
dveh._speed = 20
driveReset(dveh)
drive.scanRound()
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 40,
    "走廊淨空 command 不超 profile envelope")
checkEq(drive.calls.forceBrake, 0, "走廊淨空：不煞車")
checkEq(#halos, 0, "走廊淨空：無提示")

-- ①a 真正無 physics body 的 HitByCar 小物：小郵箱／輪式垃圾桶已在 shipped
-- 分類順序正確放行，不應產生 hard 或 soft 限速。
drive.putSpriteObject(20, 0, "street_decoration_01_18", false, true, false)
drive.putSpriteObject(22, 1, "trashcontainers_01_0", false, true, false)
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 40,
    "無 physics body 城市小物不抬高 command")
checkEq(#halos, 0, "無 physics body 的城市小物不顯示繞行提示")
drive.clearCell(20, 0)
drive.clearCell(22, 1)

-- ①b prefix 不能 blanket-ignore：實體 public mailbox 即使有 HitByCar，也先被
-- solidtrans/StopCar 收編。
checkTrue(armDrive(), "實體郵筒對照重臂")
setHeading(dveh, 0.05)
driveReset(dveh)
drive.putSpriteObject(20, 0, "street_decoration_01_8", true, true, true)
drive.scanRound()
checkEq(haloKey(), DKEY.DODGE, "solidtrans＋StopCar public mailbox 仍觸發繞行")
drive.clearCell(20, 0)

checkTrue(armDrive(), "水泥路障對照重臂")
setHeading(dveh, 0.05)
driveReset(dveh)
drive.putSpriteObject(20, 0, "street_decoration_01_28", false, false, true)
drive.scanRound()
checkEq(haloKey(), DKEY.DODGE, "StopCar 水泥路障即使無 collision flag 仍觸發繞行")
drive.clearCell(20, 0)

checkTrue(armDrive(), "大型 dumpster 對照重臂")
setHeading(dveh, 0.05)
driveReset(dveh)
drive.putSpriteObject(24, 0, "trashcontainers_01_8", true, false, false)
drive.scanRound()
checkEq(haloKey(), DKEY.DODGE, "沒有 HitByCar 的 solid 大型 dumpster 仍觸發繞行")
drive.clearCell(24, 0)

-- 使用者實景：路邊停放的黑車橫跨三格；另在 a 前放合法近樹，並在距車群
-- 7m 的 c..d 收回段放 l=-1.5 細樹（不擋 baseL、不會被 GROUP_GAP 併群）。
-- 兩者若誤納 minMargin 都會降速；碰撞仍要驗，但不得污染 entry＋hold cap。
local blackParked = drive.putVehicle(20, 0, true)
drive.vehGeo[20 * 100000 - 1] = blackParked
drive.vehGeo[20 * 100000 + 1] = blackParked
drive.putTree(4, 1, "vegetation_trees_01_5")
drive.putTree(27, -2, "vegetation_trees_01_7")
checkTrue(armDrive(), "黑色停車 comfort speed 重臂")
setHeading(dveh, 0.05)
driveReset(dveh)
drive.scanRound()
checkEq(haloKey(), DKEY.BLOCKED,
    "停車旁近樹使 intended-speed 轉場不足：保守判 blocked，不忽略實體")
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 15,
    "stopped vehicle dynamic class immediately remains <=15")
drive.vehGeo[20 * 100000 - 1] = nil
drive.clearVehicle(20, 0)
drive.vehGeo[20 * 100000 + 1] = nil
drive.clearCell(4, 1)
drive.clearCell(27, -2)

-- squeeze 檔：主障礙的 normal comfort lane 會在 entry 段撞上左右兩棵細樹；
-- 三條 normal retry 也分別撞左右樹。縮到 need=1.2 後 first-safe 側偏較小，
-- entry 與兩樹距離超過 1.1m，world sweep 才能通過。這條成功路徑必全段限 10。
drive.putSolid(20, 0, "harness_squeeze_main")
drive.putTree(15, -3, "vegetation_trees_01_5")
drive.putTree(15, 2, "vegetation_trees_01_6")
checkTrue(armDrive(), "窄縫 squeeze cap 重臂")
setHeading(dveh, 0.05)
driveReset(dveh)
drive.scanRound()
checkEq(haloKey(), DKEY.BLOCKED,
    "squeeze candidate below the 0.4m error reserve is rejected, not speed-masked")
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.forceBrake > 0
        or (drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 12),
    "unsafe squeeze resolves to HOLD/blocked approach")
checkTrue(MDAD.Drive.isActive(0), "unsafe squeeze keeps the session alive for rescan")
drive.clearCell(20, 0)
drive.clearCell(15, -3)
drive.clearCell(15, 2)

-- 對抗式 phase collision：把已烘好的第一個 baseline 點壓到一棵「弧座標不擋線」
-- 的樹上。若碰撞判定被錯包進 a..c 的 inCap，這條會誤 commit。
do
    local realBuild = MDADFollower.buildOffsetLine
    local realSetOffset = MDADFollower.setOffset
    local commits = 0
    MDADFollower.buildOffsetLine = function(profile, s0, a, b, c, d, off, bias, outX, outY)
        local n, lineS0 = realBuild(profile, s0, a, b, c, d, off, bias, outX, outY)
        if n >= 1 then outX[1], outY[1] = 4.5, 1.5 end
        return n, lineS0
    end
    MDADFollower.setOffset = function(...)
        commits = commits + 1
        return realSetOffset(...)
    end
    drive.putSolid(20, 0, "harness_phase_baseline_main")
    drive.putTree(4, 1, "vegetation_trees_01_8")
    checkTrue(armDrive(), "baseline sweep collision 重臂")
    setHeading(dveh, 0.05)
    driveReset(dveh)
    drive.scanRound()
    MDADFollower.buildOffsetLine = realBuild
    MDADFollower.setOffset = realSetOffset
    checkEq(commits, 0, "baseline 實碰撞：不得 commit 繞行剖面")
    checkEq(haloKey(), DKEY.BLOCKED, "baseline 實碰撞：分類 blocked")
    drive.clearCell(20, 0)
    drive.clearCell(4, 1)
end

-- 同一守衛的 exit 負向案例：每條候選烘線的末點都壓到 c 後細樹上。
-- margin 不計 exit，不代表碰撞可以不驗；normal 與 squeeze 都必須拒絕。
do
    local realBuild = MDADFollower.buildOffsetLine
    local realSetOffset = MDADFollower.setOffset
    local commits = 0
    MDADFollower.buildOffsetLine = function(profile, s0, a, b, c, d, off, bias, outX, outY)
        local n, lineS0 = realBuild(profile, s0, a, b, c, d, off, bias, outX, outY)
        if n >= 1 then outX[n], outY[n] = 25.5, -1.5 end
        return n, lineS0
    end
    MDADFollower.setOffset = function(...)
        commits = commits + 1
        return realSetOffset(...)
    end
    drive.putSolid(20, 0, "harness_phase_exit_main")
    drive.putTree(25, -2, "vegetation_trees_01_9")
    checkTrue(armDrive(), "exit sweep collision 重臂")
    setHeading(dveh, 0.05)
    driveReset(dveh)
    drive.scanRound()
    MDADFollower.buildOffsetLine = realBuild
    MDADFollower.setOffset = realSetOffset
    checkEq(commits, 0, "exit 實碰撞：不得 commit 繞行剖面")
    checkEq(haloKey(), DKEY.BLOCKED, "exit 實碰撞：分類 blocked")
    drive.clearCell(20, 0)
    drive.clearCell(25, -2)
end
checkTrue(armDrive(), "一般硬障礙情境重臂")
setHeading(dveh, 0.05)
driveReset(dveh)

-- ② 單格中線障礙 → 繞行：first-safe 是左側 -1.75；same-side refinement
--    最多再外推 0.75m 到 -2.50，取得足夠餘裕後以 24 km/h 通過。
drive.debug = true
drive.putSolid(20, 0, "harness_barrel")
drive.scanRound()
-- 提示斷言先於 driveReset（reset 會清 halos 帳本）
checkEq(#halos, 1, "繞行開始提示一次（玩家要知道慢下來的原因）")
checkEq(haloKey(), DKEY.DODGE, "繞行提示 Dodge")
checkEq(halos[1] and halos[1].kind, "good", "繞行是綠字（自動處理中，不是要玩家介入）")
drive.scanRound()
checkEq(#halos, 1, "持續繞行期間不重複轟提示（sig 每輪微變、replan 反覆進來也只提示一次）")
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed < 40,
    "static dodge command obeys dynamic cap")
checkEq(drive.calls.forceBrake, 0, "safe static dodge coasts without forceBrake")
checkTrue(MDAD.Drive.isActive(0), "繞行不結束 session")

-- ③ 五格橫排堵死 → blocked：±5 走廊的可行帶是 ±3.6，兩三格還繞得過（借路肩），
--    y=-2..2 五格（l 記錄 -1.5..2.5）把 lane 全吃光才是真堵死。
--    blocked 先「漸進接近」：障礙群在 15 公尺外時不急煞，以 12 km/h 滑行逼近
--    （近距離掃描的縫隙判定更準）；15 公尺內才煞停等待。
drive.putSolid(20, -5, "harness_wreck_l2") -- 走廊擴到 ±7 後堵死要排更寬（±5.5 格心）
drive.putSolid(20, -4, "harness_wreck_l1")
drive.putSolid(20, -2, "harness_wreck_a")
drive.putSolid(20, -1, "harness_wreck_b")
drive.putSolid(20, 1, "harness_wreck_c")
drive.putSolid(20, 2, "harness_wreck_d")
drive.putSolid(20, 4, "harness_wreck_r1")
drive.putSolid(20, 5, "harness_wreck_r2")
drive.scanRound()
checkEq(haloKey(), DKEY.BLOCKED, "堵死提示 Blocked")
checkEq(halos[1] and halos[1].kind, "bad", "堵死是紅字（要玩家注意）")
-- 車在 s≈0、障礙群 20：距離 >15 → 接近段（滑行不煞停）
driveReset(dveh)
driveTick(dp, dveh)
checkEq(drive.calls.forceBrake, 0, "障礙還在 15 公尺外：接近段不煞停")
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 12,
    "blocked approach command never exceeds 12")
-- 車逼近到 8（距障礙群 <15）→ 煞停等待
dveh._x = 8
driveTick(dp, dveh) -- 投影窗跟上新位置
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.forceBrake > 0, "逼近 15 公尺內：主動煞停")
checkEq(drive.calls.regulatorOn, 0, "煞停時不再供油")
checkTrue(MDAD.Drive.isActive(0), "堵死不結束 session（障礙消失要能自動恢復）")
local halosBefore = #halos
drive.scanRound()
checkEq(#halos, halosBefore, "堵死持續期間不重複轟紅字（只提示一次）")

-- ④ 清障 → blocked 解除（守護驗證通過、恢復供油）。immutable 承諾**不因
--    clear 提前釋放**——剖面（d≈28.5）走完才回全速（多繞幾公尺比換邊安全；
--    實機車在動、承諾必然走完，「駛過 d 後釋放」由 ⑩c 與紅測試覆蓋）。
drive.clearCell(20, -2)
drive.clearCell(20, -1)
drive.clearCell(20, 0)
drive.clearCell(20, 1)
drive.clearCell(20, 2)
drive.clearCell(20, -5)
drive.clearCell(20, -4)
drive.clearCell(20, 4)
drive.clearCell(20, 5)
dveh._x = 8
drive.scanRound()
drive.scanRound() -- 守護驗證連續通過：blocked 解除（單輪抖動自癒的反向）
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._regulator, true, "障礙消失：自動恢復供油")
checkTrue(drive.calls.maxRegSpeed > 0 and drive.calls.maxRegSpeed < 40,
    "immutable commitment retains its computed dynamic cap")
-- 駛過剖面末端（d≈28.5）：**每幀**釋放承諾、繞行帽解除——不依賴 replan
-- （replan 是障礙簽章事件驅動；通過後路面乾淨 sig 不變，釋放若只在 replan
-- 會永遠沒人跑，爬行帽在開闊直路掛死——2026-08-29 圖 4 實測 bug）
dveh._x = 60
driveTick(dp, dveh) -- 投影跟上（40m 路線段長 10m、前向搜索 12 段）
drive.fillWorld(-2, 140, -12, 12)
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 40,
    "released commitment remains within profile/gate envelope")
-- ⑤ 系列要乾淨旗標＋車回 s≈0：重臂（armDrive 換同構 40m 路線）
checkTrue(armDrive(), "④→⑤ 重臂")
setHeading(dveh, 0.05)
dveh._speed = 20
driveReset(dveh)

-- ⑤ 殭屍密度減速：1 隻 → 25；4 隻 → 15；8 隻 → 10；沙盒關閉 → 不減速
drive.putMoving(25, 0, { _class = "IsoZombie" })
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 25,
    "1 zombie command never exceeds 25")
drive.putMoving(25, -1, { _class = "IsoZombie" })
drive.putMoving(26, 0, { _class = "IsoZombie" })
drive.putMoving(26, 1, { _class = "IsoZombie" })
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 15,
    "4 zombie command never exceeds 15")
drive.putMoving(27, -1, { _class = "IsoZombie" })
drive.putMoving(27, 0, { _class = "IsoZombie" })
drive.putMoving(27, 1, { _class = "IsoZombie" })
drive.putMoving(28, 0, { _class = "IsoZombie" })
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 10,
    "8 zombie command never exceeds 10")
drive.clearCell(27, -1); drive.clearCell(27, 0)
drive.clearCell(27, 1); drive.clearCell(28, 0)
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
    AutoDriveMaxSpeed = 40, ZombieAreaSlowdown = false, RightLaneBias = 0 })
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 40,
    "zombie policy off does not bypass other gate caps")
-- ⑤a 三態政策×玩家偏好（上一段的 boolean false＝舊值遷移：強制全速）。
--     政策/偏好改動後要跨 250ms 刷新窗（scanRound 推 nowMs）才進 session 快取。
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
    AutoDriveMaxSpeed = 40, ZombieAreaSlowdown = 1, RightLaneBias = 0 })
MDAD.Drive.setSlowPref(0, "zombie", false)
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed > 0 and drive.calls.maxRegSpeed <= 15,
    "政策強制減速：玩家偏好關掉仍受 15 上限；coast envelope 可更低（實得 "
    .. tostring(drive.calls.maxRegSpeed) .. "）")
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
    AutoDriveMaxSpeed = 40, ZombieAreaSlowdown = 2, RightLaneBias = 0 })
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 40,
    "player preference off does not bypass other gate caps")
MDAD.Drive.setSlowPref(0, "zombie", true)
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkEq(drive.calls.maxRegSpeed, 15, "偏好開回來：減速恢復")
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
    AutoDriveMaxSpeed = 40, ZombieAreaSlowdown = 3, RightLaneBias = 0 })
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 40,
    "forced zombie full-speed still obeys other gates")
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false, AutoDriveMaxSpeed = 40, RightLaneBias = 0 })
drive.clearCell(25, 0); drive.clearCell(25, -1)
drive.clearCell(26, 0); drive.clearCell(26, 1)

-- ⑤b 地面屍體減速：獨立訊號（不進 hard/soft、不觸發繞行／煞停），預設政策
--     由玩家決定＋偏好開＝壓 CORPSE_CAP 20；政策強制全速＝直接輾過
drive.putCorpse(25, 0)
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 20,
    "corpse command never exceeds 20")
checkEq(drive.calls.forceBrake, 0, "屍體不是障礙：不煞停")
checkEq(#halos, 0, "屍體不觸發繞行／堵住提示")
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
    AutoDriveMaxSpeed = 40, CorpseSlowdown = 3, RightLaneBias = 0 })
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 40,
    "corpse policy off still obeys other gates")
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false, AutoDriveMaxSpeed = 40, RightLaneBias = 0 })
drive.clearCell(25, 0)
drive.scanRound()

-- ⑤c 樹＝硬障礙：樹 sprite 無碰撞 flag（shouldHaveCollision 隱形），靠
--     instanceof IsoTree 判 HARD——修 2026-08-28 實機撞樹鬼打牆（全油撞樹→
--     脫困→原路再撞 ×3）。與屍體相反：樹要繞、屍體只減速。
driveReset(dveh)
drive.putTree(20, 0, "vegetation_trees_01_5")
drive.scanRound()
checkEq(haloKey(), DKEY.DODGE, "路中一棵樹：硬障礙 → 繞行")
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed > 0 and drive.calls.maxRegSpeed < 40,
    "tree dodge uses computed dynamic cap")
drive.clearCell(20, 0)
drive.scanRound()
drive.scanRound() -- 守護驗證連續通過（樹已清）：不轉 blocked
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._regulator, true, "樹清除：恢復行駛")
checkTrue(drive.calls.maxRegSpeed > 0 and drive.calls.maxRegSpeed < 40,
    "tree-clear guard preserves the immutable computed cap")
-- 路緣樹段要乾淨旗標：重臂
checkTrue(armDrive(), "⑤c→路緣樹 重臂")
setHeading(dveh, 0.05)
dveh._speed = 20
driveReset(dveh)
-- 路緣樹（l≈-2.5，細桿門檻 1.4 → 不擋線）：不觸發繞行、不減速——實機
-- 2026-08-28：肥半徑把整排路緣樹判成擋路，車長期貼對側路緣不回中
drive.putTree(20, -3, "vegetation_trees_01_7")
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkEq(#halos, 0, "路緣樹：不觸發繞行提示")
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 40,
    "roadside tree does not raise command")
drive.clearCell(20, -3)
drive.scanRound()

-- ⑥ 行進中的別台車 → 跟車減速（不是障礙）；靜止的別台車 → 硬障礙走繞行。
--    車輛感知唯一入口＝square:getVehicleContainer()（格級幾何查詢）——
--    不碰 movingObjects、不碰 cell:getVehicles() 集合（兩者實機都會漏）。
drive.putVehicle(30, 0, false)
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 15,
    "moving vehicle command never exceeds 15")
checkEq(drive.calls.forceBrake, 0, "跟車只降速不煞停")
drive.clearVehicle(30, 0)
drive.putVehicle(32, 0, true)
drive.scanRound()
dveh._x = 14 -- 進入剖面 15m 界內（接近段分級：遠處照常速、近了才壓）
driveTick(dp, dveh)
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed <= DODGE_CAP_TEST, "靜止的車＝硬障礙：進繞行減速（實得 "
    .. tostring(drive.calls.maxRegSpeed) .. "）")
drive.clearVehicle(32, 0)
dveh._x = 0
driveTick(dp, dveh)
driveTick(dp, dveh)

-- ⑥b isStopped 波動＋跨輪靜止判定（2026-08-29 路口皮卡定讞）：MP 假動車
--    isStopped 恆 false，但**位置不會說謊**——同 id 連兩輪（~250ms）位移
--    <0.3m＝實質靜止、強制硬障礙。判停/假動兩態都走繞行，「跟車等一台
--    永不動的車」的誤判態被消滅（舊行為：皮卡不進 hard、plan 從不規劃
--    繞它的縫、車按在原地等它讓路到 20 秒紅字）
local vWobble = drive.putVehicle(30, 0, true)
drive.scanRound()
dveh._x = 12 -- 進 15m 界（剖面 a≈24）
driveTick(dp, dveh)
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed > 0 and drive.calls.maxRegSpeed <= DODGE_CAP_TEST,
    "波動車判「靜止」的輪：硬障礙繞行減速（實得 "
    .. tostring(drive.calls.maxRegSpeed) .. "）")
vWobble._stopped = false -- 半更新誤判成行進中：位置不動 → 照樣硬障礙
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed > 0 and drive.calls.maxRegSpeed <= DODGE_CAP_TEST,
    "波動車假動（isStopped=false 但位置不動）：跨輪靜止判定收編、照樣繞行（實得 "
    .. tostring(drive.calls.maxRegSpeed) .. "）")
drive.clearVehicle(30, 0)
-- 真動車不被誤判：同 id 輪間位移 1m > 0.3m → 行進中 → 跟車減速（非繞行）。
-- 先重臂：波動段的 dodge 剖面殘留會以 margin 縮放 cap（<15）壓過跟車 15。
-- 手動控輪（scanRound 一口氣掃兩輪、輪間動不了車）：250ms 節流＋12 tick 一輪
checkTrue(armDrive(), "(6b) 真動段重臂")
setHeading(dveh, 0.05)
dveh._speed = 20
local vMove = drive.putVehicle(30, 0, false)
nowMs = nowMs + 300
for _ = 1, 12 do driveTick(dp, dveh) end -- 第一輪：無上輪記錄 → moving
drive.moveVehicle(vMove, 31, 0)
nowMs = nowMs + 300
for _ = 1, 12 do driveTick(dp, dveh) end -- 第二輪：位移 1m → 仍 moving
drive.moveVehicle(vMove, 32, 0)
nowMs = nowMs + 300
for _ = 1, 12 do driveTick(dp, dveh) end -- 第三輪：持續移動（快照穩定 moving）
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 15,
    "true moving vehicle remains <=15")
drive.clearVehicle(32, 0) -- vMove 最後停 (32,0)：清錯格＝幽靈 fixture 每輪判 still
drive.scanRound()
checkTrue(armDrive(), "(6b) 段尾重臂") -- 真動段殘留剖面：⑦ 的 15 斷言不吃 margin cap
setHeading(dveh, 0.05)
dveh._speed = 20
-- 近距跟車（<10m）：目標 0 煞停——MP 半更新的靜止車被 isStopped 誤判成
-- 行進中、不進硬障礙（2026-08-28 實機追尾黑車），不能只 cap 15 跟到撞。
-- 車推到 x=8（route 40m 段長 10m：0→8 同段內，投影一幀跟上）、前車格
-- (16,0)＝中心 16.5：gap = 16.5-8 = 8.5 < 10 且在帶內
dveh._x = 8
driveTick(dp, dveh)
drive.putVehicle(16, 0, false)
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
-- 新語意（跨輪靜止判定）：貼近的「假行進」車兩輪即判 still → 直接當障礙。
-- 世界掃掠通過才允許在寬縫以 24 繞行，否則煞停；兩者都不會全速跟撞。
checkTrue(drive.calls.forceBrake > 0
        or (drive.calls.maxRegSpeed > 0 and drive.calls.maxRegSpeed <= 24),
    "前車貼到 10m 內：煞停或掃掠通過後以繞行上限 24 通過（實得 forceBrake="
    .. tostring(drive.calls.forceBrake) .. " maxReg=" .. tostring(drive.calls.maxRegSpeed) .. "）")
drive.clearVehicle(16, 0)
drive.scanRound()
checkTrue(armDrive(), "(6b) 近距段尾重臂") -- 殘留剖面不進 ⑦
setHeading(dveh, 0.05)
dveh._speed = 20

-- ⑦ 未載入 chunk：動態煞停距——距外不減速（chunk 會載入）、距內按「能
--    停住的速度」漸進壓（2026-08-29 使用者裁定：帶尾恆未載入不該永遠 15）
drive.world[35 * 100000 + 0] = nil
drive.scanRound()
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed < 40,
    "exact visibility root never exceeds unloaded horizon cap")
dveh._x = 28 -- gap ~7m < 煞停距：進入動態減速區
driveTick(dp, dveh)
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.forceBrake > 0 or drive.calls.maxRegSpeed == 0,
    "visibility envelope breach immediately clamps/brakes（reg="
    .. tostring(drive.calls.maxRegSpeed) .. "）")
drive.mkSquare(35, 0)
dveh._x = 8 -- 還原 ⑧ 依賴的位置
driveTick(dp, dveh)
driveTick(dp, dveh)

-- ⑧ 停車政策（ObstaclePolicy=2）：就算有縫隙也不繞，一律漸進停車
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
    AutoDriveMaxSpeed = 40, ObstaclePolicy = 2, RightLaneBias = 0 })
dveh._x = 8 -- 靠近障礙（重臂歸零過）：距 barrel ~11.3m < 15 直接煞停
driveTick(dp, dveh)
drive.putSolid(20, 0, "harness_barrel2")
drive.scanRound()
checkEq(haloKey(), DKEY.BLOCKED, "停車政策：有縫隙也提示 Blocked（不繞）")
-- 車已在 x=8（上一段），距障礙群 ~11.3 公尺 <15 → 直接煞停
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.forceBrake > 0, "停車政策：煞停等待")
checkTrue(MDAD.Drive.isActive(0), "停車政策：session 活著（玩家接手或清障恢復）")
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false, AutoDriveMaxSpeed = 40, RightLaneBias = 0 })
drive.clearCell(20, 0)
MDAD.Drive.stop(0, nil)

-- ⑨ 彎道繞行（不禁止，算進去）：障礙群落在轉角段（累計轉角 > 25°）時，縫隙判定
--    用放大的需求半寬（+0.6）重算——內輪差與 pure pursuit 切內彎吃掉的餘裕先扣
--    再判。判得過＝真有寬縫照繞、速度受彎道 16 km/h 天花板限制；判不過＝
--    blocked 煞停，不硬擠。手組 L 型路線：直行到 (76,0) 後右轉往南（+Y），
--    障礙放轉角後（障礙群 b..c 涵蓋 45° 折點）。
do
    local pts = {}
    for i = 0, 19 do pts[#pts + 1] = i * 4; pts[#pts + 1] = 0 end       -- (0,0)..(76,0)
    for i = 1, 19 do pts[#pts + 1] = 80; pts[#pts + 1] = i * 4 end      -- (80,4)..(80,76)
    drive.nav.route = { pts = pts }
end
drive.fillWorld(-9, 90, -7, 90)
-- 車放在直段 s=50（障礙 s≈84 要在 36 公尺掃描帶內）
dveh._x, dveh._y, dveh._speed, dveh._steering = 50, 0, 20, 0
setHeading(dveh, 0.05)
dp._vehicle, dveh._driver = dveh, dp
checkTrue(MDAD.Drive.start(dp), "彎道情境啟動")
driveReset(dveh) -- 清掉 Start 綠字
-- ⑨a: the geometric gap exists, but the swept clearance is below the 0.4m
-- error reserve, so the dynamic clearance cap is zero and the candidate is rejected.
drive.putSolid(80, 4, "harness_curve_obs")
drive.scanRound()
checkEq(haloKey(), DKEY.BLOCKED,
    "curve candidate below error reserve is blocked rather than speed-masked")
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.forceBrake > 0
        or (drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 12),
    "unsafe curve candidate uses blocked approach/HOLD")
checkTrue(MDAD.Drive.isActive(0), "curve clearance rejection keeps session alive")
checkTrue(MDAD.Drive.isActive(0), "彎道繞行不結束 session")

-- ⑨a 承諾走完前不換剖面（immutable）：⑨b 要觀察「窄縫降級」的**新提案**，
-- 先結束 ⑨a 的 session 清承諾（否則 ⑨b 只會走守護驗證、⑨c 的紅字被
-- ⑨b 的守護失敗提前吃掉）
MDAD.Drive.stop(0, nil)
checkTrue(MDAD.Drive.start(dp), "⑨b 重臂")
driveReset(dveh) -- 清掉 Start 綠字
-- ⑨b 彎中並排三格（加嚴後無寬縫、**普通縫仍在** ±3.25）：窄縫降級爬行——
--    不再直接 blocked（2026-08-28 實機：彎道兩台並排車被加嚴判死 → 卡死
--    鬼打牆；真擦撞由世界空間複驗把關），entry 仍受 16 km/h 上限。
drive.putSolid(79, 4, "harness_curve_obs_b")
drive.putSolid(81, 4, "harness_curve_obs_c")
drive.scanRound()
checkEq(haloKey(), DKEY.BLOCKED,
    "彎中窄縫的長車前角 OBB 不安全：blocked，不以中心線 clear 硬擠")
driveReset(dveh)
driveTick(dp, dveh)
checkTrue(drive.calls.forceBrake > 0
        or (drive.calls.maxRegSpeed > 0 and drive.calls.maxRegSpeed <= 12),
    "長車 OBB 否決後只以 blocked approach 爬行，近距才煞停")
checkTrue(MDAD.Drive.isActive(0), "彎中窄縫：session 活著")
-- ⑨c 彎中真堵死（普通 needHalf 也無縫：七顆並排蓋過可行帶 ±5.6）
--    → blocked 煞停等待，這才是「不硬擠」的底線
drive.putSolid(77, 4, "harness_curve_obs_d")
drive.putSolid(83, 4, "harness_curve_obs_e")
drive.putSolid(75, 4, "harness_curve_obs_f") -- 走廊 ±7 後可行帶 ±5.6：堵死要排到 l≈±5
drive.putSolid(85, 4, "harness_curve_obs_g")
drive.scanRound()
checkEq(haloKey(), nil, "已在 blocked 承諾中不重複轟提示")
checkTrue(MDAD.Drive.isActive(0), "彎中堵死：session 活著（等待或玩家接手）")
drive.clearCell(75, 4)
drive.clearCell(77, 4)
drive.clearCell(79, 4)
drive.clearCell(80, 4)
drive.clearCell(81, 4)
drive.clearCell(83, 4)
drive.clearCell(85, 4)
drive.scanRound()
drive.scanRound() -- blocked 解除遲滯：連續兩輪 clear
driveReset(dveh)
driveTick(dp, dveh)
checkEq(dveh._regulator, true, "彎中障礙清除：自動恢復行駛")
MDAD.Drive.stop(0, nil)

-- ⑨d 折點旁障礙：最近 safe lane 會斜切障礙，但同側外推後的 comfort lane
--    仍須經完整 entry／hold／exit 世界掃掠；掃掠通過才 commit，不因「靠近
--    折點」標籤一律誤判 blocked／改道。
do
    dveh._x, dveh._y, dveh._speed, dveh._steering = 50, 0, 20, 0
    setHeading(dveh, 0.05)
    dp._vehicle, dveh._driver = dveh, dp
    checkTrue(MDAD.Drive.start(dp), "⑨d 啟動")
    driveReset(dveh)
    local realSetOffset = MDADFollower.setOffset
    local commits = 0
    MDADFollower.setOffset = function(...)
        commits = commits + 1
        return realSetOffset(...)
    end
    drive.putSolid(79, 3, "harness_corner_a") -- 貼著 L 折點（76,0→80,4 過渡段）
    drive.putSolid(80, 4, "harness_corner_b") -- 折點頂點
    drive.nav.detourCalls = 0
    drive.nav.detourRoute = newRoute(40, 50, 0, 4, 0)
    drive.nav.detourRoute.len = 200
    drive.scanRound()
    MDADFollower.setOffset = realSetOffset
    checkEq(commits, 0, "⑨d 長車前角 OBB 否決中心線看似淨空的 comfort lane")
    checkEq(haloKey(), DKEY.BLOCKED, "⑨d 分類 blocked（不以中心點掃掠誤放行）")
    dveh._speed = 0
    driveReset(dveh)
    driveTick(dp, dveh)
    nowMs = nowMs + 4200
    driveTick(dp, dveh)
    checkEq(drive.nav.detourCalls, 0, "⑨d 已有安全繞行線：不誤送改道請求")
    checkTrue(MDAD.Drive.isActive(0), "⑨d 安全繞行保持 session")
    drive.clearCell(79, 3)
    drive.clearCell(80, 4)
    drive.nav.detourRoute = nil
    MDAD.Drive.stop(0, nil)
end

-- ⑩ 首次繞行以 laneBias 為中心（driver→corridor 接線）：同一顆 (20,0) 障礙，
--    開靠右 1m 後 first-safe 右縫 +2.75 比左縫更近，先選右側，再同側外推至
--    comfort +3.50。offL 用 setOffset spy 觀察（halo／速度看不出側別）。
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
    AutoDriveMaxSpeed = 40, RightLaneBias = 1 })
do
    local realSetOffset = MDADFollower.setOffset
    local spyOffL = nil
    MDADFollower.setOffset = function(st, a, b, c, d, off, ...)
        spyOffL = off
        return realSetOffset(st, a, b, c, d, off, ...)
    end
    checkTrue(armDrive(), "靠右繞行情境啟動")
    drive.putSolid(20, 0, "harness_bias_obs")
    drive.scanRound()
    MDADFollower.setOffset = realSetOffset
    checkEq(haloKey(), DKEY.DODGE, "靠右行駛遇中線障礙：照樣繞行")
    checkEq(spyOffL, 3.5, "首次繞行以 laneBias 為中心：選右側後同側外推至 comfort +3.50")
    drive.clearCell(20, 0)
    MDAD.Drive.stop(0, nil)
end

-- ⑩b 擋線判定以行駛線為中心（plan 第八參 baseL 接線）：路緣樹 (20,1)
--    對中心線不擋，對 bias=+1 的行駛線會擋。first-safe 是中心線 0，
--    comfort refinement 維持左側再推到 -0.75。這同時保留 offL=0 可用的
--    planner 契約；不得把它當 inactive 哨兵。
do
    local realSetOffset = MDADFollower.setOffset
    local spyOffL, spyRet = nil, nil
    MDADFollower.setOffset = function(st2, a, b, c, d, off, ...)
        spyOffL = off
        spyRet = realSetOffset(st2, a, b, c, d, off, ...)
        return spyRet
    end
    checkTrue(armDrive(), "路緣樹情境啟動")
    drive.putTree(20, 1, "vegetation_trees_01_9")
    drive.scanRound()
    MDADFollower.setOffset = realSetOffset
    checkEq(haloKey(), DKEY.DODGE, "路緣樹擋行駛線（不擋中線）：觸發繞行而非直行蹭樹")
    checkEq(spyOffL, -0.75, "先借中心線，再同側外推 0.75m 取得 comfort 餘裕")
    checkEq(spyRet, true, "comfort offL 被 setOffset 接受")
    drive.clearCell(20, 1)
    MDAD.Drive.stop(0, nil)
end

-- ⑩c 側別記憶只限當前剖面（黏側修正）：群1 兩顆箱物堵死中線與左側 → 只能借
--    右外側；車駛過剖面末端後，群2 路緣樹只擋行駛線（中線可行）→ 新繞行段
--    必須回到以行駛線為基準選左側，再取 comfort -0.75。修正前 prefer 沿用
--    lastOffL 會黏在路肩——實機 2026-08-28 曾沿草地走完整段路。
do
    local realSetOffset = MDADFollower.setOffset
    local offs = {}
    local tuples = {}
    MDADFollower.setOffset = function(st2, a, b, c, d, off, ...)
        offs[#offs + 1] = off
        tuples[#tuples + 1] = string.format("a=%.1f d=%.1f off=%.2f", a, d, off)
        return realSetOffset(st2, a, b, c, d, off, ...)
    end
    checkTrue(armDrive(), "黏側情境啟動")
    drive.putSolid(20, -1, "harness_stick1")
    drive.putSolid(20, 0, "harness_stick2")
    drive.scanRound()
    checkEq(haloKey(), DKEY.DODGE, "群1 堵中線與左側：繞行")
    checkTrue(offs[#offs] ~= nil and offs[#offs] > 2,
        "群1 只剩右外側縫（實得 " .. tostring(offs[#offs]) .. "）")
    dveh._x = 45 -- beyond dynamic d≈42 while the next obstacle at x=55 stays ahead
    for _ = 1, 8 do driveTick(dp, dveh) end
    drive.clearCell(20, -1); drive.clearCell(20, 0)
    drive.putTree(55, 1, "vegetation_trees_02_1")
    drive.scanRound() -- 首輪收舊帶（0..36 起點鎖定於輪首）：clear 遲滯 +1
    drive.scanRound() -- 新帶 40..76 掃到樹 → 新繞行段
    MDADFollower.setOffset = realSetOffset
    checkEq(offs[#offs], -0.75,
        "剖面走完後的新繞行回行駛線基準側，再取同側 comfort -0.75（全序列 "
        .. table.concat(tuples, " | ", 1, #tuples) .. "；halo=" .. tostring(haloKey())
        .. " n=" .. tostring(#offs) .. "）")
    drive.clearCell(55, 1)
    MDAD.Drive.stop(0, nil)
end
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false, AutoDriveMaxSpeed = 40, RightLaneBias = 0 })

-- ⑫ 路面對中：nav 線（streets.xml）偏離實際路面時，行駛線用地板 sprite 統計
--    校正——鋪一條偏左的路（l∈[-4.5,-0.5]、中心 ≈-2.5，模擬實測「線在路面
--    東緣外」），EMA 數輪後 laneBias 收斂到 ≈-2.5×0.9；清掉路面（全帶無樣本）
--    後校正衰減回 0（nav 線是唯一剩下的參考，不硬掰）。RightLaneBias=0 隔離。
do
    local realSetBias = MDADFollower.setLaneBias
    local spyBias = nil
    MDADFollower.setLaneBias = function(st2, b)
        spyBias = b
        return realSetBias(st2, b)
    end
    checkTrue(armDrive(), "路面對中情境啟動")
    drive.putRoad(0, 70, -5, -1)
    for _ = 1, 8 do
        drive.scanRound()
        if spyBias ~= nil then dveh._y = spyBias end
    end -- 模擬車跟上逐輪 EMA，隔離 RETURN 對真實偏離的守門
    checkTrue(spyBias ~= nil and spyBias < -1.8 and spyBias > -3.01,
        "行駛線向實際路面中心校正（期望 ≈-2.3、實得 " .. tostring(spyBias) .. "）")
    drive.fillWorld(-2, 70, -7, 7) -- 重建無地板世界＝路面樣本消失
    for _ = 1, 12 do
        drive.scanRound()
        if spyBias ~= nil then dveh._y = spyBias end
    end
    checkTrue(spyBias ~= nil and spyBias > -0.5 and spyBias < -0.1,
        "無路面樣本：roadBias 逐輪衰減回 nav 線（實得 " .. tostring(spyBias) .. "）")
    MDADFollower.setLaneBias = realSetBias
    dveh._y = 0
    MDAD.Drive.stop(0, nil)
end

-- ⑫-2 route cutover：roadBias 與 scanBias 都是舊 route 法向上的量。換線當幀
-- follower 必立刻回 sandBias；新 route 首輪掃描也須以 sandBias 置中，且首輪
-- 完成後不能讓舊 EMA 值復活。
do
    local realSetBias = MDADFollower.setLaneBias
    local spyBias = nil
    MDADFollower.setLaneBias = function(st2, b)
        spyBias = b
        return realSetBias(st2, b)
    end
    drive.putRoad(0, 70, -5, -1)
    checkTrue(armDrive(), "route cutover roadBias 情境啟動")
    for _ = 1, 8 do
        drive.scanRound()
        if spyBias ~= nil then dveh._y = spyBias end
    end
    checkTrue(spyBias ~= nil and spyBias < -1.8,
        "換線前先建立非零 roadBias（實得 " .. tostring(spyBias) .. "）")
    drive.fillWorld(-2, 70, -7, 7)
    dveh._y = 0
    drive.nav.route = newRoute(80, 0, 0, 4, 0)
    nowMs = nowMs + 300
    driveReset(dveh)
    driveTick(dp, dveh)
    checkTrue(spyBias ~= nil and spyBias > -0.1 and spyBias < 0.1,
        "route cutover 當幀立即回 sandBias（實得 " .. tostring(spyBias) .. "）")
    local realGetGridSquare = drive.cell.getGridSquare
    local scanMinY, scanMaxY = 999, -999
    drive.cell.getGridSquare = function(self, x, y, z)
        if y < scanMinY then scanMinY = y end
        if y > scanMaxY then scanMaxY = y end
        return realGetGridSquare(self, x, y, z)
    end
    -- 當幀的 spy 只證明 follower 槽被覆寫；若內部 s.roadBias 沒清，這個
    -- 無路面輪會把舊值乘 0.85 後重新送回 follower，所以下方斷言獨立守該槽。
    drive.scanRound()
    drive.cell.getGridSquare = realGetGridSquare
    checkTrue(scanMinY <= -7 and scanMaxY >= 6,
        "新 route 首輪掃描以 sandBias=0 置中（y="
        .. tostring(scanMinY) .. ".." .. tostring(scanMaxY) .. "）")
    checkTrue(spyBias ~= nil and spyBias > -0.1 and spyBias < 0.1,
        "新 route 首輪後舊 roadBias 不復活（實得 " .. tostring(spyBias) .. "）")
    MDADFollower.setLaneBias = realSetBias
    MDAD.Drive.stop(0, nil)
end

-- ⑫a 停車場歧義：Rosewood 座標 8262,11511 的官方街道寬 6m，但西側
-- `blends_street` 停車場與路面連成 11 格寬。fixture 兩緣都在掃描帶內，
-- 單獨守住 span >9 的拒絕；若把整條鋪面當街道平均，roadC 會偏 -0.5m。
do
    local realSetBias = MDADFollower.setLaneBias
    local spyBias = nil
    MDADFollower.setLaneBias = function(st2, b)
        spyBias = b
        return realSetBias(st2, b)
    end
    drive.putRoad(0, 70, -6, 4) -- 11 格、中心 -0.5m、span 10，兩緣完整可見
    checkTrue(armDrive(), "停車場歧義情境啟動")
    for _ = 1, 8 do drive.scanRound() end
    MDADFollower.setLaneBias = realSetBias
    checkTrue(spyBias ~= nil and spyBias > -0.1 and spyBias < 0.1,
        "過寬鋪面不校正行駛線，退回 nav 線（實得 " .. tostring(spyBias) .. "）")
    drive.fillWorld(-2, 70, -7, 7)
    MDAD.Drive.stop(0, nil)
end

-- ⑫a-2 門檻邊界：10 格合法寬路＝格心 span 9，必須仍可校正；`>=` 寫錯
-- 會把 vanilla 10m 街道誤殺。
do
    local realSetBias = MDADFollower.setLaneBias
    local spyBias = nil
    MDADFollower.setLaneBias = function(st2, b)
        spyBias = b
        return realSetBias(st2, b)
    end
    drive.putRoad(0, 70, -6, 3) -- 10 格、中心 -1m、span 恰 9
    checkTrue(armDrive(), "10m 合法寬路情境啟動")
    for _ = 1, 8 do drive.scanRound() end
    MDADFollower.setLaneBias = realSetBias
    checkTrue(spyBias ~= nil and spyBias < -0.6 and spyBias > -1.2,
        "10m 邊界樣本仍向路中心校正（實得 " .. tostring(spyBias) .. "）")
    drive.fillWorld(-2, 70, -7, 7)
    MDAD.Drive.stop(0, nil)
end

-- ⑫a-3 帶截斷拒絕：11 格鋪面的西端在 ±6.5 掃描帶外，表面上只看到
-- span 9；因鋪面碰到帶端，這只是寬度下界，必須全輪拒絕，不能啟動正回饋。
do
    local realSetBias = MDADFollower.setLaneBias
    local spyBias = nil
    MDADFollower.setLaneBias = function(st2, b)
        spyBias = b
        return realSetBias(st2, b)
    end
    drive.putRoad(0, 70, -8, 2)
    checkTrue(armDrive(), "停車場帶截斷拒絕情境啟動")
    for _ = 1, 12 do drive.scanRound() end
    MDADFollower.setLaneBias = realSetBias
    checkTrue(spyBias ~= nil and spyBias > -0.1 and spyBias < 0.1,
        "截斷寬度只是下界：全輪拒絕、roadBias 留在 nav 線（實得 " .. tostring(spyBias) .. "）")
    drive.fillWorld(-2, 70, -7, 7)
    MDAD.Drive.stop(0, nil)
end

-- ⑫b 縫隙帶內優先（plan 第 9/10 參端到端）：路面帶格心 [-0.5,3.5]（roadLo/Hi＝
--    [-1,4]），障礙 l=0.5 擋掉中間；帶內 first-safe 2.75，再同側外推至
--    comfort 3.50。不得改選帶外較近的草地縫。
do
    local realSetOffset = MDADFollower.setOffset
    local spyOffL = nil
    MDADFollower.setOffset = function(st2, a2, b2, c2, d2, off, ...)
        spyOffL = off
        return realSetOffset(st2, a2, b2, c2, d2, off, ...)
    end
    checkTrue(armDrive(), "帶內優先情境啟動")
    drive.putRoad(0, 70, -1, 3)
    drive.putSolid(20, 0, "harness_band1")
    for _ = 1, 3 do drive.scanRound() end
    MDADFollower.setOffset = realSetOffset
    checkEq(haloKey(), DKEY.DODGE, "帶內優先情境：繞行觸發")
    checkTrue(spyOffL ~= nil and spyOffL >= 3.25 and spyOffL <= 3.75,
        "繞行縫優先留在路面帶內右側並外推至 comfort ~3.50，不選帶外草地縫"
        .. "（實得 " .. tostring(spyOffL) .. "）")
    drive.clearCell(20, 0)
    drive.fillWorld(-2, 70, -7, 7)
    MDAD.Drive.stop(0, nil)
end

-- ⑬ 世界軌跡與 debug 標記：一般玩家 active session 在 OnPostRender 以
-- renderIsoLine 畫單一半透明藍／黃線；DebugOverlay 只加紅／綠／橙 marker。
-- 關 debug 不影響線，route cutover 與 stop 都要立即清線。
drive.markerN = 0
drive.markerAlphaN = 0
drive.markerAlpha = nil
drive.worldLines = {}
drive.trajectoryVisible = true
drive.trajectoryWidth = 2
drive.renderPlayerNum = 0
MDAD.HUD = {
    trajectoryVisible = function() return drive.trajectoryVisible end,
    trajectoryWidth = function() return drive.trajectoryWidth end,
}
drive.renderPlayer = { getPlayerNum = function() return drive.renderPlayerNum or 0 end }
function getPlayer() return drive.renderPlayer end
function renderIsoLine(x, y, z, x2, y2, z2, thickness, r, g, b, a)
    local n = #drive.worldLines + 1
    drive.worldLines[n] = {
        x = x, y = y, z = z, x2 = x2, y2 = y2, z2 = z2,
        thickness = thickness, r = r, g = g, b = b, a = a,
    }
end
drive.overlayRenderBefore = #(eventHandlers.OnPostRender or {})
function getWorldMarkers()
    return {
        addGridSquareMarker = function(_, sq, r, g, b, doAlpha, size)
            drive.markerN = drive.markerN + 1
            local alive = true
            return {
                setAlpha = function(_, a)
                    drive.markerAlphaN = drive.markerAlphaN + 1
                    drive.markerAlpha = a
                end,
                remove = function()
                    if alive then
                        alive = false
                        drive.markerN = drive.markerN - 1
                    end
                end,
            }
        end,
    }
end
require "MDAD_Overlay"
checkEq(type(MDADOverlay), "table", "production client/MDAD_Overlay.lua 真的載入了")
checkEq(#(eventHandlers.OnPostRender or {}), drive.overlayRenderBefore + 1,
    "Overlay 只註冊一個 OnPostRender 世界線 renderer")
checkTrue(type(MDADFollower.OV_STEP) == "number" and MDADFollower.OV_STEP > 0,
    "Follower 導出有效的 M6 折線步距供 Overlay 共用")
checkFalse(MDADOverlay.setTrajectoryWidth(0 / 0), "Overlay 拒絕 NaN 軌跡粗細")
checkTrue(MDADOverlay.setTrajectoryWidth(2), "Overlay 接受合法標準軌跡粗細")
local function testTrajectoryOverlay()
    setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
        AutoDriveMaxSpeed = 40, RightLaneBias = 0, DebugOverlay = false })
    checkTrue(armDrive(), "一般玩家軌跡情境啟動")
    drive.putRoad(0, 70, -2, 2)
    drive.putSolid(20, 0, "harness_ovl_obs")
    local overlayState = nil
    local realOverlayUpdate = MDADOverlay.update
    MDADOverlay.update = function(pn, s, ...)
        if pn == 0 then overlayState = s end
        return realOverlayUpdate(pn, s, ...)
    end
    drive.scanRound()
    MDADOverlay.update = realOverlayUpdate
    checkEq(type(overlayState), "table", "Driver 把 active session 交給 Overlay 更新")
    checkEq(drive.markerN, 0, "DebugOverlay 關閉：一般軌跡不建立 marker 圈")
    local savedProfile, savedFstate, savedSNow =
        overlayState.profile, overlayState.fstate, overlayState.lastSNow
    local fracProfile = MDADFollower.begin(
        { pts = { 0, 0, 30, 0, 30, 60 } }, 40, 2)
    while not MDADFollower.stepBuild(fracProfile, 4096) do end
    local fracX, fracY = {}, {}
    local fracN, fracS0, fracWhy, fracEnd = MDADFollower.buildOffsetLine(
        fracProfile, 5, 10, 16, 24, 30.4, -1.75, 0.3, fracX, fracY)
    local fracState = MDADFollower.newState()
    MDADFollower.setLaneBias(fracState, 0.3)
    checkEq(fracWhy, "ok", "fractional d=30.4 overlay line builds")
    checkNear(fracEnd, 31.4, 1e-12, "fractional overlay line keeps true ovEndS")
    checkTrue(MDADFollower.setOffset(fracState, 10, 16, 24, 30.4, -1.75,
        fracX, fracY, fracN, fracS0, fracEnd), "fractional overlay line commits")
    local queryS = 31.2
    local lastStart = fracS0 + (fracN - 2) * MDADFollower.OV_STEP
    local ft = (queryS - lastStart) / (fracEnd - lastStart)
    local expectX = fracX[fracN - 1] + (fracX[fracN] - fracX[fracN - 1]) * ft
    local expectY = fracY[fracN - 1] + (fracY[fracN] - fracY[fracN - 1]) * ft
    overlayState.profile, overlayState.fstate, overlayState.lastSNow =
        fracProfile, fracState, queryS
    MDADOverlay.update(0, overlayState, dveh, drive.cell, false)
    clearList(drive.worldLines)
    drive.renderPlayerNum = 0
    fire("OnPostRender")
    checkNear(drive.worldLines[1].x, expectX, 1e-6,
        "Overlay last interval x uses ovEndS-lastStart denominator")
    checkNear(drive.worldLines[1].y, expectY, 1e-6,
        "Overlay last interval y matches Follower exact fractional coordinate")
    overlayState.profile, overlayState.fstate, overlayState.lastSNow =
        savedProfile, savedFstate, savedSNow
    MDADOverlay.update(0, overlayState, dveh, drive.cell, false)

    clearList(drive.worldLines)
    drive.renderPlayerNum = 0
    fire("OnPostRender")
    checkTrue(#drive.worldLines > 10,
        "一般玩家 active session：OnPostRender 送出連續線段（實得 "
        .. tostring(#drive.worldLines) .. "）")
    local standardLineN = #drive.worldLines
    local standardFirst = drive.worldLines[1]
    local sawBlue, sawYellow, lineStyleOk = false, false, true
    for i = 1, #drive.worldLines do
        local ln = drive.worldLines[i]
        if not (ln.a > 0 and ln.a < 1 and ln.thickness == 3
                and (ln.x ~= ln.x2 or ln.y ~= ln.y2) and ln.z == ln.z2) then
            lineStyleOk = false
        end
        if ln.r < 0.3 and ln.g > 0.7 and ln.b > 0.8 then sawBlue = true end
        if ln.r > 0.8 and ln.g > 0.7 and ln.b < 0.3 then sawYellow = true end
    end
    checkTrue(lineStyleOk, "標準軌跡是單一 thickness=3 半透明直線")
    checkTrue(sawBlue, "正常 follower 段使用藍線")
    checkTrue(sawYellow or not overlayState.dodging,
        "yellow is emitted exactly when the dynamic candidate is committed")

    drive.trajectoryWidth = 1
    drive.scanRound(true)
    clearList(drive.worldLines)
    fire("OnPostRender")
    local thinLineN = #drive.worldLines
    local thinFirst = drive.worldLines[1]
    checkEq(thinLineN, standardLineN, "細／標準每段都只提交一條線")
    checkTrue(thinFirst and thinFirst.thickness == 1, "細線使用 thickness=1")
    checkNear(thinFirst.x, standardFirst.x, 1e-6, "改粗細不改軌跡 x")
    checkTrue(type(thinFirst.y) == "number", "細線軌跡 y 保持有限")

    drive.trajectoryWidth = 3
    drive.scanRound(true)
    clearList(drive.worldLines)
    fire("OnPostRender")
    checkEq(#drive.worldLines, thinLineN, "粗線仍是每段單次 client draw")
    checkTrue(drive.worldLines[1].thickness == 7, "粗線使用 thickness=7")
    checkNear(drive.worldLines[1].x, thinFirst.x, 1e-6, "粗線仍沿同一條中心軌跡 x")
    checkTrue(type(drive.worldLines[1].y) == "number", "粗線中心軌跡 y 保持有限")
    drive.trajectoryWidth = 0 / 0
    drive.scanRound(true)
    clearList(drive.worldLines)
    fire("OnPostRender")
    checkTrue(drive.worldLines[1].thickness == 3, "NaN 軌跡粗細退回標準 thickness=3")

    drive.trajectoryVisible = false
    drive.scanRound()
    clearList(drive.worldLines)
    fire("OnPostRender")
    checkEq(#drive.worldLines, 0, "關閉顯示軌跡：active session 也不提交線段")
    drive.trajectoryVisible = true
    drive.trajectoryWidth = 2
    drive.scanRound()

    setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
        AutoDriveMaxSpeed = 40, RightLaneBias = 0, DebugOverlay = true })
    drive.scanRound()
    checkTrue(drive.markerN > 10,
        "DebugOverlay 開啟：紅／綠診斷 markers 額外出現（實得 "
        .. tostring(drive.markerN) .. "）")
    checkTrue(drive.markerAlphaN > 0 and drive.markerAlpha == 1,
        "Debug marker 建立後立刻 setAlpha(1)，FBO 路徑不隱形")
    local slot0Markers = drive.markerN
    MDADOverlay.update(1, overlayState, dveh, drive.cell, true)
    checkTrue(drive.markerN > slot0Markers,
        "split slot1 debug markers 與 slot0 並存（實得 "
        .. tostring(slot0Markers) .. "→" .. tostring(drive.markerN) .. "）")
    MDADOverlay.clear(0)
    checkTrue(drive.markerN > 0, "清 slot0 不會抹掉 slot1 debug markers")
    clearList(drive.worldLines)
    drive.renderPlayerNum = 1
    fire("OnPostRender")
    checkTrue(#drive.worldLines > 0, "清 slot0 後 slot1 viewport 軌跡仍存在")
    MDADOverlay.clear(1)
    checkEq(drive.markerN, 0, "清 slot1 後 split debug markers 才歸零")
    MDADOverlay.update(0, overlayState, dveh, drive.cell, true)
    clearList(drive.worldLines)
    drive.renderPlayerNum = 0
    fire("OnPostRender")
    checkTrue(#drive.worldLines > 0, "DebugOverlay 開啟時一般藍／黃線仍照畫")

    setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
        AutoDriveMaxSpeed = 40, RightLaneBias = 0, DebugOverlay = false })
    drive.scanRound()
    checkEq(drive.markerN, 0, "DebugOverlay 關閉：debug markers 全清")
    clearList(drive.worldLines)
    fire("OnPostRender")
    checkTrue(#drive.worldLines > 0, "關閉 debug 不會關掉一般玩家軌跡線")

    drive.nav.route = newRoute(300, 0, 0, 4, 0)
    nowMs = nowMs + 300
    driveReset(dveh)
    driveTick(dp, dveh)
    clearList(drive.worldLines)
    fire("OnPostRender")
    checkEq(#drive.worldLines, 0, "route cutover 建構期：舊軌跡立即清除")
    drive.scanRound()
    clearList(drive.worldLines)
    fire("OnPostRender")
    checkTrue(#drive.worldLines > 0, "新 route 首輪完成：軌跡線重新出現")

    MDAD.Drive.stop(0, nil)
    clearList(drive.worldLines)
    fire("OnPostRender")
    checkEq(#drive.worldLines, 0, "停止自駕：下一 viewport render 不再提交軌跡線")
    checkEq(drive.markerN, 0, "停止自駕：debug markers 亦全清")
    drive.clearCell(20, 0)
    drive.fillWorld(-2, 70, -7, 7)
end
testTrajectoryOverlay()
setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false, AutoDriveMaxSpeed = 40, RightLaneBias = 0 })

-- ⑪ 調頭安全探測：原地耦力旋轉前先探車周 3m——淨空＝耦力（衝量幀間反向、
--    中心力抵消不橫滑）；有牆＝退回橫推大弧（衝量幀間同向；爬行前進轉，
--    空間不夠自然由卡死→脫困鏈接手）。車頭朝西（誤差 180°）：側向＝世界 z 軸。
checkTrue(armDrive(), "調頭探測情境啟動")
dveh._x, dveh._y, dveh._speed = 10, 0, 0
setHeading(dveh, math.pi)
driveTick(dp, dveh)                -- 投影跟上＋第一次車周探測（淨空）
driveReset(dveh)
driveTick(dp, dveh)
do
    local i1 = dveh._imp.z
    driveTick(dp, dveh)
    checkTrue(i1 ~= 0 and dveh._imp.z ~= 0 and i1 * dveh._imp.z < 0,
        "車周淨空：耦力調頭＝衝量幀間反向（實得 " .. tostring(i1) .. " / "
        .. tostring(dveh._imp.z) .. "）")
    drive.putSolid(12, 0, "harness_rot_wall") -- 格心 (12.5,0.5) 距車 2.5m：半徑 3 內
    nowMs = nowMs + 600                       -- 跨過 500ms 探測節流
    driveTick(dp, dveh)                       -- 重探：不淨空
    driveReset(dveh)
    driveTick(dp, dveh)
    local j1 = dveh._imp.z
    driveTick(dp, dveh)
    checkTrue(j1 ~= 0 and dveh._imp.z ~= 0 and j1 * dveh._imp.z > 0,
        "車周 3m 有牆：退回橫推大弧＝衝量幀間同向（實得 " .. tostring(j1) .. " / "
        .. tostring(dveh._imp.z) .. "）")
end
-- 車周有「cell 清單的靜止車」（MP 靜止車在逐格 movingObjects 不可靠——
-- 2026-08-28 實機：探測回 clear、原地旋轉直接撞上旁邊的救護車）：
-- 全域列舉必須抓到 → 退大弧（衝量幀間同向）
do
    drive.clearCell(12, 0)
    drive.cellVehicles[1] = { getX = function() return 13 end,
        getY = function() return 1 end, isStopped = function() return true end }
    nowMs = nowMs + 600
    driveTick(dp, dveh)                       -- 重探：cell 車輛清單命中
    driveReset(dveh)
    driveTick(dp, dveh)
    local k1 = dveh._imp.z
    driveTick(dp, dveh)
    checkTrue(k1 ~= 0 and dveh._imp.z ~= 0 and k1 * dveh._imp.z > 0,
        "車周 3m 有 cell 清單的車（movingObjects 掃不到）：退大弧（實得 "
        .. tostring(k1) .. " / " .. tostring(dveh._imp.z) .. "）")
    drive.cellVehicles[1] = nil
end
-- 樹（COST_HARD_THIN 細桿）也擋調頭：探測曾只認 COST_HARD，樹旁判「淨空」
-- 原地旋轉直接掃到樹（2026-08-28 實機）。樹格心 (13.5,1.5) 距車 3.8m——
-- 舊半徑 3 掃不到、新半徑 4 必須掃到 → 退大弧
do
    drive.putTree(13, 1, "harness_rot_tree")
    nowMs = nowMs + 600
    driveTick(dp, dveh)                       -- 重探：樹命中
    driveReset(dveh)
    driveTick(dp, dveh)
    local t1 = dveh._imp.z
    driveTick(dp, dveh)
    checkTrue(t1 ~= 0 and dveh._imp.z ~= 0 and t1 * dveh._imp.z > 0,
        "車周 4m 有樹（細桿硬障礙）：退大弧（實得 "
        .. tostring(t1) .. " / " .. tostring(dveh._imp.z) .. "）")
    drive.clearCell(13, 1)
end
drive.clearCell(12, 0)
MDAD.Drive.stop(0, nil)

-- =====================================================================
-- 情境二十八b：immutable DODGE 承諾語意＋停等豁免（2026-08-28 對抗審紅測試）
-- =====================================================================
scenario("immutable 承諾：單次 setOffset／大側偏不誤判 offroad／停等不倒車")

-- (a) 同一承諾期只呼叫一次 setOffset：承諾後世界變化（不擋剖面線）只走
--     守護驗證，不重新提案——「每輪重規劃可覆寫執行中的承諾」正是實測
--     offL 逐輪翻面震盪的結構性根因
do
    local realSetOffset = MDADFollower.setOffset
    local spyN = 0
    MDADFollower.setOffset = function(st2, a2, b2, c2, d2, off, ...)
        spyN = spyN + 1
        return realSetOffset(st2, a2, b2, c2, d2, off, ...)
    end
    checkTrue(armDrive(), "(a) 啟動")
    drive.putSolid(20, 0, "harness_imm_a")
    drive.scanRound()
    checkEq(spyN, 1, "(a) 首次提案：setOffset 恰一次")
    -- 帶內新增一顆不擋剖面線的障礙：sig 變、replan 進來，但承諾不可變
    drive.putSolid(24, 3, "harness_imm_b")
    drive.scanRound()
    drive.scanRound()
    MDADFollower.setOffset = realSetOffset
    checkEq(spyN, 1, "(a) 承諾期間 sig 變化不重新提案（setOffset 仍恰一次）")
    checkTrue(MDAD.Drive.isActive(0), "(a) 承諾期間 session 活著")
    drive.clearCell(20, 0)
    drive.clearCell(24, 3)
    MDAD.Drive.stop(0, nil)
end

-- (b) 合法大側偏剖面跟隨不觸發 offroad：甩出量＝|latSigned−期望線|——
--     舊判法量「到中心線距離」>4，|offL|>4 的合法繞行會自己觸發 offroad
--     →清剖面→回線→再繞行的鋸齒循環，這種縫永遠執行不完
do
    local realSetOffset = MDADFollower.setOffset
    local spyOffL = nil
    MDADFollower.setOffset = function(st2, a2, b2, c2, d2, off, ...)
        spyOffL = off
        return realSetOffset(st2, a2, b2, c2, d2, off, ...)
    end
    checkTrue(armDrive(), "(b) 啟動")
    for y = -3, 4 do drive.putSolid(20, y, "harness_wide_" .. y) end
    drive.scanRound()
    MDADFollower.setOffset = realSetOffset
    checkEq(haloKey(), DKEY.DODGE, "(b) 寬障礙：外側縫繞行")
    checkTrue(type(spyOffL) == "number" and (spyOffL > 4 or spyOffL < -4),
        "(b) 縫在大側偏（|offL|>4；實得 " .. tostring(spyOffL) .. "）")
    -- 車擺在剖面保持段的期望位置：dev≈0 → 不觸發 offroad，也不額外壓到 15
    dveh._x = 20
    dveh._y = spyOffL
    driveTick(dp, dveh) -- 投影跟上（40m 路線段長 10m、前向搜索 12 段）
    driveReset(dveh)
    driveTick(dp, dveh)
    local hasOffroad = false
    for _, l in ipairs(drive.logs) do
        if l:find("offroad", 1, true) then hasOffroad = true end
    end
    checkFalse(hasOffroad, "(b) 沿剖面大側偏：不誤判 offroad（無掃回 log）")
    checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 28,
        "(b) committed large offset remains within dynamic cap")
    -- 對照組：同一 s、真甩出（偏離期望線再 6m、更外側的草地）→ offroad 掃回
    dveh._y = spyOffL < 0 and spyOffL - 6 or spyOffL + 6
    driveTick(dp, dveh) -- 觸發幀：offroad 設立並清 dodging（當幀 dodge cap 已先套）
    driveReset(dveh)
    driveTick(dp, dveh)
    checkEq(drive.calls.maxRegSpeed, 0,
        "(b) 無 fresh lane proof 的 RETURN 進 HOLD，不允許 8 km/h")
    checkTrue(drive.calls.forceBrake > 0, "RETURN HOLD target0 主動煞停")
    for y = -3, 4 do drive.clearCell(20, y) end
    MDAD.Drive.stop(0, nil)
end

-- (c) 停等豁免：blocked 煞停是合法等待——不進 unstick 倒車（車隊裡倒車
--     危險且必然紅字放棄）、不在 STUCK_MS(5s) 後紅字；獨立超時 20s 才停用
do
    checkTrue(armDrive(), "(c) 啟動")
    for _, y in ipairs({ -5, -4, -2, -1, 0, 1, 2, 4, 5 }) do
        drive.putSolid(20, y, "harness_wall_" .. y)
    end
    -- 先進入 blocked 的 15m 煞停線；x=0 仍屬 target=12 接近段，
    -- 不適合驗 target=0 的合法停等豁免。
    dveh._x = 8
    driveTick(dp, dveh)
    drive.scanRound()
    checkEq(haloKey(), DKEY.BLOCKED, "(c) 堵死紅字")
    dveh._speed = 0 -- 車停妥（blocked 等待）
    driveReset(dveh)
    driveTick(dp, dveh)  -- waitSince 起算
    nowMs = nowMs + 6000 -- 6 秒 > STUCK_MS 5 秒：舊行為此刻已倒車脫困
    driveTick(dp, dveh)
    checkTrue(MDAD.Drive.isActive(0), "(c) 停等 6 秒：session 活著（不 unstick 不放棄）")
    checkTrue(haloKey() ~= DKEY.UNSTICK and haloKey() ~= DKEY.STUCK,
        "(c) 停等 6 秒：無倒車／放棄提示（實得 " .. tostring(haloKey()) .. "）")
    nowMs = nowMs + 15000 -- 累計 21 秒 > WAIT_TIMEOUT 20 秒
    driveTick(dp, dveh)
    checkTrue(not MDAD.Drive.isActive(0), "(c) 停等逾 20 秒：超時停用（交還玩家）")
    checkEq(haloKey(), DKEY.STUCK, "(c) 超時紅字 StopStuck")
    for _, y in ipairs({ -5, -4, -2, -1, 0, 1, 2, 4, 5 }) do drive.clearCell(20, y) end
end

-- (c2) 近距跟車（followHold）同豁免：前車臨停常超過 5 秒，倒車＝追撞隊友
do
    checkTrue(armDrive(), "(c2) 啟動")
    dveh._x = 8
    driveTick(dp, dveh)
    -- 前車＝真行進中（輪間位移 0.4m > 0.3 判動、gap 恆 <10 保 followHold）。
    -- 手動控輪：scanRound 一口氣掃兩輪、輪間動不了車；微動用 _x 直調（格鍵
    -- 不變，位置讀 getX）
    local vLead = drive.putVehicle(16, 0, false)
    -- 12 tick＝剛好一輪（658 格 ÷ 56 格/tick）：讓「動車」正好落在輪邊界，
    -- 下一輪讀到的位置必是新值（14 tick 會把下一輪的車格掃進同段——車還沒
    -- 再動，位移 0 被誤判 still）
    nowMs = nowMs + 300
    for _ = 1, 12 do driveTick(dp, dveh) end
    vLead._x = vLead._x + 0.4
    nowMs = nowMs + 300
    for _ = 1, 12 do driveTick(dp, dveh) end
    vLead._x = vLead._x + 0.4
    nowMs = nowMs + 300
    for _ = 1, 12 do driveTick(dp, dveh) end
    dveh._speed = 0
    driveReset(dveh)
    driveTick(dp, dveh) -- followHold（gap ≈ 8.9 < 10）＋waitSince 起算
    vLead._x = vLead._x + 0.4
    nowMs = nowMs + 3000
    driveTick(dp, dveh)
    vLead._x = vLead._x + 0.4
    nowMs = nowMs + 3000
    driveTick(dp, dveh)
    checkTrue(MDAD.Drive.isActive(0), "(c2) 跟車停等 6 秒：session 活著")
    checkTrue(haloKey() ~= DKEY.UNSTICK and haloKey() ~= DKEY.STUCK,
        "(c2) 跟車停等：無倒車／放棄提示（實得 " .. tostring(haloKey()) .. "）")
    drive.clearVehicle(16, 0)
    MDAD.Drive.stop(0, nil)
end

-- (d) 2.5s supervisor：near-clear 的高檔只 pulse 一次；VERIFY 失敗後 rear-clear
--     才進 unstick。倒車期間每 100ms rear 重查，新增障礙的那幀必須 0 impulse。
do
    drive.fillWorld(-10, 70, -7, 7)
    dveh._com:set(0, 0.5, 1.1) -- valid non-zero COM，舊 bodyCenter anchor 會與 vehicle origin 差 >1m
    checkTrue(armDrive(), "(d) gear-reset/rear 情境啟動")
    setHeading(dveh, 0)
    driveTick(dp, dveh) -- yaw progress，重臂到 heading=0
    drive.scanRound()
    dveh._x = 8
    driveTick(dp, dveh) -- new-route verify 必須以既有 s>1 的同座標系重新 anchor
    dveh._speed, dveh._trans = 70, 3
    local gearReads = 0
    local realTransmission = dveh.getTransmissionNumber
    dveh.getTransmissionNumber = function(self)
        gearReads = gearReads + 1
        return realTransmission(self)
    end
    nowMs = nowMs + 2501
    driveReset(dveh)
    driveTick(dp, dveh)
    checkTrue(MDAD.Drive.isActive(0), "(d) suspect 後 session 活著")
    checkEq(dveh._imp.total, 0, "(d) gear-reset transition 0 impulse")
    checkEq(drive.calls.forceBrake, 0, "(d) 150ms neutral pulse 不混 forceBrake")
    dveh._speed = 0
    nowMs = nowMs + 100
    driveReset(dveh)
    driveTick(dp, dveh)
    checkEq(dveh._regulator, false, "(d) pulse 未滿 150ms 繼續 regulator off")
    checkEq(dveh._imp.total, 0, "(d) pulse 未滿 150ms 仍 0 impulse")
    checkEq(drive.calls.forceBrake, 0, "(d) pulse 未滿 150ms 仍不 forceBrake")
    drive.nav.route = newRoute(40, 0, 0, 4, 0) -- same-target cutover after pulse deadline
    nowMs = nowMs + 150
    driveReset(dveh)
    driveTick(dp, dveh)
    driveTick(dp, dveh)
    checkTrue(MDAD.Drive.isActive(0),
        "(d) gear-reset cutover build 後重新 anchor 2s VERIFY")
    nowMs = nowMs + 2001
    driveReset(dveh)
    driveTick(dp, dveh) -- VERIFY timeout → recovery stop → initial rear clear → unstick
    checkEq(gearReads, 1, "(d) 同 episode 高檔 getter/pulse 恰一次")
    checkEq(haloKey(), DKEY.UNSTICK, "(d) rear clear 才開始 unstick")
    drive.putSolid(4, 0, "harness_rear_mid") -- 車在 x=8、COM forward offset=1.1；rear sweep 約 x=3..7
    nowMs = nowMs + 100
    driveReset(dveh)
    driveTick(dp, dveh)
    checkFalse(MDAD.Drive.isActive(0), "(d) unstick 中途 rear hard 立即停用")
    checkEq(dveh._imp.total, 0, "(d) rear hard 命中幀零 reverse impulse")
    checkEq(haloKey(), DKEY.STUCK, "(d) rear hard 使用 StopStuck")
    dveh.getTransmissionNumber = realTransmission
    dveh._com:set(0, 0.5, 0)
end

-- (d1b) Sensor probe Java errors preserve detail through the public pcall boundary.
-- Driver fails closed, logs the detail once, and sends no reverse impulse.
do
    drive.fillWorld(-10, 70, -7, 7)
    checkTrue(armDrive(), "(d1b) probe throw 啟動")
    setHeading(dveh, 0)
    driveTick(dp, dveh)
    dveh._speed, dveh._trans = 0, 1
    local realGrid = drive.cell.getGridSquare
    drive.cell.getGridSquare = function(self, x, y, z)
        if x == -4 then error("probe-grid-boom") end -- rear strip only；不炸 forward Sensor.step
        return realGrid(self, x, y, z)
    end
    nowMs = nowMs + 2501
    driveReset(dveh)
    driveTick(dp, dveh)
    drive.cell.getGridSquare = realGrid
    checkFalse(MDAD.Drive.isActive(0), "(d1b) probe throw fail-closed 停止")
    checkEq(dveh._imp.total, 0, "(d1b) probe throw 0 reverse impulse")
    local sawDetail = false
    for _, line in ipairs(drive.logs) do
        if line:find("probe-grid-boom", 1, true) then sawDetail = true end
    end
    checkTrue(sawDetail, "(d1b) probe throw detail log once 可見")
    dveh._trans = 2
end

-- (d2) current-body contact 產生 episode ban；成功倒 3m 先 SETTLE 到 <1km/h，
--      sensor reset 與 same-target route cutover 都保留 ban；前進 10m＋兩輪 clear 才 rearm。
do
    drive.fillWorld(-10, 70, -7, 7)
    local realPlan = MDADCorridor.plan
    local sawRecoveryBan = false
    MDADCorridor.plan = function(hs, hl, hn, need, corr, prefer, hr, ...)
        if type(hr) == "table" then
            for i = 1, hn do
                if hr[i] == 0.6 then sawRecoveryBan = true end
            end
        end
        return realPlan(hs, hl, hn, need, corr, prefer, hr, ...)
    end
    checkTrue(armDrive(), "(d2) contact/settle 情境啟動")
    setHeading(dveh, 0)
    driveTick(dp, dveh)
    dveh._trans = 1 -- contact 不走 gear-reset；低檔也不應 pulse
    drive.putSolid(2, 0, "harness_current_contact")
    drive.scanRound(true)
    dveh._x = 1.1 -- 已跨舊 progress anchor 1m，但車身仍包住 x=2.5 障礙
    driveReset(dveh)
    driveTick(dp, dveh)
    checkEq(dveh._regulator, false,
        "(d2) world progress 達標不得旁路 currentBlocked")
    checkTrue(drive.calls.forceBrake >= 1,
        "(d2) currentBlocked 只由兩輪 footprint clear 解除")
    drive.clearCell(2, 0)
    drive.scanRound()
    driveReset(dveh)
    driveTick(dp, dveh)
    checkEq(dveh._regulator, false, "(d2) 一輪 footprint clear 仍保持 currentBlocked")
    drive.scanRound()
    driveReset(dveh)
    driveTick(dp, dveh)
    checkEq(MDAD.Drive.controlState(0), "HOLD",
        "(d2) current-body clear 已完成，但 planned blocker 仍走自己的 clear hysteresis")
    drive.scanRound()
    driveReset(dveh)
    driveTick(dp, dveh)
    checkEq(dveh._regulator, false,
        "(d2) infeasible recovery-ban shift remains HOLD and arms recovery, not a legal wait")
    drive.putSolid(2, 0, "harness_current_contact_again")
    drive.scanRound(true)
    dveh._x = 0
    dveh._speed = 0
    driveReset(dveh)
    driveTick(dp, dveh) -- 先以目前卡點重臂 progress anchor，再累計完整 2.5s
    nowMs = nowMs + 2501
    driveReset(dveh)
    driveTick(dp, dveh)
    checkEq(haloKey(), DKEY.UNSTICK, "(d2) current contact rear-clear 後開始 unstick")
    nowMs = nowMs + 16
    driveReset(dveh)
    driveTick(dp, dveh)
    checkEq(dveh._imp.total, 1, "(d2) unstick 幀恰一次 reverse impulse")
    checkTrue(dveh._imp.x * dveh._fwdX + dveh._imp.z * dveh._fwdY < 0,
        "(d2) reverse impulse 無 longitudinal forward 分量")

    dveh._x, dveh._speed = -3.1, -13
    nowMs = nowMs + 16
    driveReset(dveh)
    driveTick(dp, dveh)
    checkTrue(MDAD.Drive.isActive(0), "(d2) 退 3m 成功後進 settle，session 保留")
    checkEq(dveh._regulator, false, "(d2) settle regulator off")
    checkTrue(drive.calls.forceBrake >= 1, "(d2) -13km/h settle 強制煞停")
    checkEq(dveh._imp.total, 0, "(d2) settle 0 impulse")
    dveh._speed = -0.5
    nowMs = nowMs + 100
    driveReset(dveh)
    driveTick(dp, dveh) -- settle 完成，sensor reset + forced replan
    drive.clearCell(2, 0) -- remap 不得依賴首輪仍掃到舊 hard point

    sawRecoveryBan = false
    drive.nav.route = newRoute(40, 0, 0, 4, 0) -- same target deviation
    nowMs = nowMs + 300
    driveTick(dp, dveh)
    drive.scanRound()
    checkTrue(sawRecoveryBan, "(d2) same-target route cutover remap 並保留 recovery ban")

    sawRecoveryBan = false
    drive.nav.route = newRoute(40, 0, 8, 4, 0) -- old hit 離新 route > corridor、但不超 RETURN 容量
    nowMs = nowMs + 300
    driveTick(dp, dveh)
    drive.scanRound()
    checkFalse(sawRecoveryBan,
        "(d2) world hit 離新 route 太遠：保留 attempts/world memory 但不套 Frenet ban")

    sawRecoveryBan = false
    drive.nav.route = newRoute(40, 0, 0, 4, 0)
    nowMs = nowMs + 300
    driveTick(dp, dveh)
    for _ = 1, 4 do
        if not sawRecoveryBan then drive.scanRound() end
    end
    checkTrue(sawRecoveryBan, "(d2) 後續 near route 可重新投影同一 world hit")
    dveh._x, dveh._speed = 13.0, 20 -- >10m from projected world hit
    drive.scanRound()
    drive.scanRound() -- >10m world + 連續兩輪 footprint clear
    sawRecoveryBan = false
    drive.putSolid(20, 0, "harness_rearmed")
    drive.scanRound()
    checkFalse(sawRecoveryBan, "(d2) 10m＋兩輪 clear 後 episode rearmed、ban 清除")
    MDADCorridor.plan = realPlan
    drive.clearCell(20, 0)
    dveh._trans = 2
    MDAD.Drive.stop(0, nil)
end

-- (d2b) SETTLE itself is bounded: non-finite speed or a brake phase exceeding its
-- deadline stops instead of holding forceBrake forever.
do
    local function enterSettle(label)
        drive.fillWorld(-10, 70, -7, 7)
        checkTrue(armDrive(), label .. " 啟動")
        setHeading(dveh, 0)
        driveTick(dp, dveh)
        dveh._trans = 1
        drive.putSolid(2, 0, "harness_settle_bound")
        drive.scanRound(true)
        dveh._speed = 0
        nowMs = nowMs + 2501
        driveReset(dveh)
        driveTick(dp, dveh)
        dveh._x, dveh._speed = -3.1, -13
        nowMs = nowMs + 16
        driveReset(dveh)
        driveTick(dp, dveh)
        checkTrue(MDAD.Drive.isActive(0), label .. " 已進 settle")
    end

    enterSettle("(d2b) NaN")
    dveh._speed = 0 / 0
    nowMs = nowMs + 16
    driveTick(dp, dveh)
    checkFalse(MDAD.Drive.isActive(0), "(d2b) settle NaN fail-stop")

    enterSettle("(d2b) deadline")
    dveh._speed = -5
    nowMs = nowMs + 4001
    driveTick(dp, dveh)
    checkFalse(MDAD.Drive.isActive(0), "(d2b) settle deadline fail-stop")
    dveh._trans = 2
end

-- (d2c) A true target change never preserves recovery state. Mid-unstick it first
-- enters bounded settle (zero impulse), then builds the new route after stopping.
do
    drive.fillWorld(-10, 70, -7, 7)
    checkTrue(armDrive(), "(d2c) target change mid-unstick 啟動")
    setHeading(dveh, 0)
    driveTick(dp, dveh)
    dveh._trans = 1
    drive.putSolid(2, 0, "harness_target_change_recovery")
    drive.scanRound(true)
    driveReset(dveh)
    driveTick(dp, dveh) -- current contact 完成後明確建立 2.5s progress anchor
    dveh._speed = 0
    nowMs = nowMs + 2501
    driveTick(dp, dveh)
    checkEq(haloKey(), DKEY.UNSTICK, "(d2c) 已進 unstick")
    dveh._speed = -5
    drive.nav.tx = 300.1
    drive.nav.route = newRoute(40, 0, 0, 4, 0)
    nowMs = nowMs + 250
    driveReset(dveh)
    driveTick(dp, dveh)
    checkTrue(MDAD.Drive.isActive(0), "(d2c) true target change 保留 bounded settle session")
    checkEq(dveh._imp.total, 0, "(d2c) target change 當幀停止 reverse impulse")
    checkTrue(drive.calls.forceBrake >= 1, "(d2c) target change mid-unstick 先 settle")
    dveh._speed = 0
    nowMs = nowMs + 16
    driveTick(dp, dveh) -- settle 完成 → build
    driveReset(dveh)
    driveTick(dp, dveh) -- build ready；首輪新 snapshot 前仍須保留 current contact
    checkTrue(MDAD.Drive.isActive(0), "(d2c) 停妥後建立新 route")
    checkEq(dveh._regulator, false,
        "(d2c) true target change 不得清掉世界座標 current contact")
    checkTrue(drive.calls.maxRegSpeed <= 15 or drive.calls.regulatorOff > 0,
        "(d2c) 新 route 首輪 snapshot 前 fail-closed command <=15")
    drive.nav.tx = 300
    dveh._trans = 2
    MDAD.Drive.stop(0, nil)
end

-- (d3) attempt budget belongs to the episode, not a route identity. Three successful
-- reverse attempts without 10m rearm are allowed; the fourth recovery request stops.
do
    drive.fillWorld(-10, 70, -7, 7)
    checkTrue(armDrive(), "(d3) max-attempt episode 啟動")
    setHeading(dveh, 0)
    driveTick(dp, dveh)
    dveh._trans = 1
    drive.putSolid(2, 0, "harness_attempt_limit")
    drive.scanRound(true)
    for attempt = 1, 3 do
        dveh._speed = 0
        nowMs = nowMs + 2501
        driveReset(dveh)
        driveTick(dp, dveh)
        checkEq(haloKey(), DKEY.UNSTICK,
            "(d3) attempt " .. tostring(attempt) .. " starts")
        dveh._x, dveh._speed = -3.1, -13
        nowMs = nowMs + 16
        driveReset(dveh)
        driveTick(dp, dveh) -- success → settle
        dveh._speed = 0
        nowMs = nowMs + 16
        driveTick(dp, dveh) -- settle complete
        if attempt < 3 then
            dveh._x = 0
            drive.scanRound() -- same episode contact again；world progress <10m
        end
    end
    dveh._x, dveh._speed = 0, 0
    drive.scanRound()
    nowMs = nowMs + 2501
    driveReset(dveh)
    driveTick(dp, dveh)
    checkFalse(MDAD.Drive.isActive(0), "(d3) fourth recovery request stops")
    checkEq(haloKey(), DKEY.STUCK, "(d3) max3 uses StopStuck")
    dveh._trans = 2
    drive.clearCell(2, 0) -- 不把 current-contact fixture 洩漏到 warm／detour 情境
end

-- (e) 感知空窗爬行：session 起步／route cutover 後首輪掃描完成前，
--     「hardN=0」是**還不知道**不是淨空——壓爬行 12 等首輪（事件驅動）。
--     2026-08-29 實測：改導航目標→調頭→正對 4m 外剛才還有紅圈的車加速，
--     首輪掃完 blocked 已物理煞不住
do
    checkTrue(armDrive(), "(e) 啟動")
    setHeading(dveh, 0.05) -- 車頭對準：排除航向誤差減速（armDrive 預設 0.3 rad 壓 40→35）
    driveReset(dveh)
    driveTick(dp, dveh) -- armDrive 後尚未跑過任何掃描輪：stamp==0
    checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 12,
        "(e) 首輪掃描完成前 command 不超過 12")
    drive.scanRound() -- 首輪完成（stamp>0）
    driveReset(dveh)
    driveTick(dp, dveh)
    checkTrue(drive.calls.maxRegSpeed >= 0 and drive.calls.maxRegSpeed <= 40,
        "(e) 首輪完成後仍按 jerk/gate 包絡恢復")
    MDAD.Drive.stop(0, nil)
end


-- (f) 堵死改道（nav API v3）：blocked 停等 4 秒 → requestDetour 帶堵點座標
--     → 主 MOD 覆寫路線快取 → cutover 換線恢復行駛（含感知空窗爬行保護）；
--     無替代路（noroad）→ 只試一次、繼續停等到 20 秒紅字
do
    checkTrue(armDrive(), "(f) 啟動")
    setHeading(dveh, 0.05)
    dveh._x = 8 -- 進 blocked 停止線，detour 計時只從近停後起算
    driveTick(dp, dveh) -- detour 計時只在近停 planned-blocked wait 啟動
    for _, y in ipairs({ -5, -4, -2, -1, 0, 1, 2, 4, 5 }) do
        drive.putSolid(20, y, "harness_dwall_" .. y)
    end
    drive.nav.detourCalls = 0
    drive.nav.detourRoute = newRoute(40, 0, 4, 4, 0) -- 繞路：平移到 y=4 的平行線
    drive.nav.detourRoute.len = 160 -- 真 route 有 len（detour 塊以此判「有沒有繞開」）
    drive.scanRound()
    checkEq(haloKey(), DKEY.BLOCKED, "(f) 堵死紅字")
    dveh._speed = 0
    driveReset(dveh)
    driveTick(dp, dveh)  -- waitSince 起算
    nowMs = nowMs + 4200 -- 逾 DETOUR_AFTER_MS 4 秒
    driveTick(dp, dveh)  -- detour 觸發：requestDetour＋綠字＋nextRouteMs=0
    checkEq(drive.nav.detourCalls, 1, "(f) 停等 4 秒：呼叫 requestDetour 恰一次")
    checkTrue(drive.nav.lastDetour ~= nil and type(drive.nav.lastDetour.ax) == "number"
        and drive.nav.lastDetour.ax > 10 and drive.nav.lastDetour.ax < 30,
        "(f) 避讓圈錨在堵點附近（實得 "
        .. tostring(drive.nav.lastDetour and drive.nav.lastDetour.ax) .. "）")
    checkEq(haloKey(), DKEY.DETOUR, "(f) 改道綠字")
    driveTick(dp, dveh)  -- route 刷新塊 cutover（nextRouteMs=0）
    checkTrue(MDAD.Drive.isActive(0), "(f) 改道後 session 活著")
    driveReset(dveh)
    for _ = 1, 4 do driveTick(dp, dveh) end
    checkTrue(MDAD.Drive.isActive(0),
        "(f) 換線 bounded rebuild 期間 session 保持、blocked 已隨 cutover 清除")
    driveReset(dveh)
    driveTick(dp, dveh)
    checkTrue(MDAD.Drive.isActive(0), "(f) cutover 後仍可持續掃描並恢復")
    for _, y in ipairs({ -5, -4, -2, -1, 0, 1, 2, 4, 5 }) do drive.clearCell(20, y) end
    drive.nav.detourRoute = nil
    MDAD.Drive.stop(0, nil)
    -- 對照：無替代路（requestDetour 回 noroad）→ 不換線、本次 episode 只試一次
    checkTrue(armDrive(), "(f) 對照組啟動")
    dveh._x = 8
    driveTick(dp, dveh)
    for _, y in ipairs({ -5, -4, -2, -1, 0, 1, 2, 4, 5 }) do
        drive.putSolid(20, y, "harness_dwall2_" .. y)
    end
    drive.nav.detourCalls = 0
    drive.scanRound()
    dveh._speed = 0
    driveReset(dveh)
    driveTick(dp, dveh)
    nowMs = nowMs + 4200
    driveTick(dp, dveh)
    nowMs = nowMs + 1000
    driveTick(dp, dveh)
    checkEq(drive.nav.detourCalls, 1, "(f) 無替代路：只試一次不重試")
    checkTrue(MDAD.Drive.isActive(0), "(f) 無替代路：繼續停等（20 秒紅字另有守）")
    for _, y in ipairs({ -5, -4, -2, -1, 0, 1, 2, 4, 5 }) do drive.clearCell(20, y) end
    MDAD.Drive.stop(0, nil)
end


-- =====================================================================
-- 情境二十八c：MP 登入補學（client 逐 slot 請求 → server actor-bound 補學）
--              ＋專屬雜誌的戰利品注入與生成政策
--
-- 實機病徵：MP 玩家「完成製作但零產出」。NeedToBeLearn=true 的配方對既有角色
-- 永遠沒學到——AutoLearnAny 只在升等瞬間（XpUpdate.lua:204 →
-- ScriptManager.checkAutoLearn＝ScriptManager.java:1141-1154）與**單機**開局
-- （IsoWorld.java:2410，只針對 IsoPlayer.getInstance()）被檢查，專用伺服器上的
-- 遠端角色兩個時機都碰不到。
-- =====================================================================
scenario("MP 登入補學：主玩家延到首個 Tick、逐 slot 請求、只信 actor、只補自己的兩個配方、學到才同步；雜誌注入與生成政策")

-- (1) client 端：OnGameStart 尚不能送 command；首個 Tick 逐本機 slot，新 slot 上線再補一則
do
    clientFlag, serverFlag = true, false
    setSandbox({ InstallSkillGate = true, NeedItemForNav = false })
    local a = newPlayer({ num = 0, username = "rescan0", onlineId = 7001 })
    local b = newPlayer({ num = 1, username = "rescan1", onlineId = 7002 })
    players[0], players[1], players[2] = a, b, nil
    activePlayers = 2

    resetStats()
    capturePrint(function() fire("OnGameStart") end)
    checkEq(#sentClient, 0, "OnGameStart 尚未 ingame，不提前送登入補學請求")
    capturePrint(function() fire("OnTick", 0) end)
    checkEq(#sentClient, 2, "首個 Tick 替每個本機 slot 各送一則登入補學請求")
    checkEq(sentClient[1] and sentClient[1].module, MOD_ID, "請求帶自己的 module 名")
    checkEq(sentClient[1] and sentClient[1].command, MDAD.CMD_RECIPE_RESCAN,
        "使用獨立的 RecipeRescan command")
    -- 分割畫面共用一條連線：伺服器只能靠具體玩家物件分辨 actor，送 slot 索引等於
    -- 讓兩位玩家的補學互相蓋掉
    checkEq(sentClient[1] and sentClient[1].player, a, "slot 0 的請求帶 slot 0 的玩家物件")
    checkEq(sentClient[2] and sentClient[2].player, b, "slot 1 的請求帶 slot 1 的玩家物件")
    checkEq(type(sentClient[1] and sentClient[1].args), "table", "payload 是表（空表）")
    checkNil(sentClient[1] and sentClient[1].args.recipe, "client 不指定要補哪個配方")
    checkNil(sentClient[1] and sentClient[1].args.target, "client 不指定要補給誰")
    checkNil(sentClient[1] and sentClient[1].args.username, "client 不指定角色名")
    checkEq(#halos, 0, "登入補學不對玩家丟提示（NeedItemForNav 關閉時本來就無感）")
    local sentAfterReady = #sentClient
    capturePrint(function() fire("OnTick", 1) end)
    checkEq(#sentClient, sentAfterReady, "登入補學 Tick callback 執行一次後即移除")

    players[2] = newPlayer({ num = 2, username = "rescan2", onlineId = 7003 })
    activePlayers = 3
    resetStats()
    capturePrint(function() fire("OnCreatePlayer", 2) end)
    checkEq(#sentClient, 1, "分割畫面新 slot 上線只補送自己那一則")
    checkEq(sentClient[1] and sentClient[1].player, players[2], "補送的是新 slot 的玩家物件")

    -- 玩家物件還沒建立的 slot：不能送 nil actor 的請求
    players[2] = nil
    resetStats()
    capturePrint(function() fire("OnCreatePlayer", 2) end)
    checkEq(#sentClient, 0, "玩家物件還沒建立時不送請求")

    -- SP：P0 由引擎開局補學，但後加入的分割畫面 slot 沒有該 Java 路徑；
    -- client 檔因此就地逐配方重掃，且不發 client command／同步封包。
    clientFlag, serverFlag = false, false
    recipeWorld.defs[MDAD.RECIPE_GPS] =
        recipeWorld.newRecipe(MDAD.RECIPE_GPS, Perks.Electricity, 6)
    recipeWorld.defs[MDAD.RECIPE_AUTO] =
        recipeWorld.newRecipe(MDAD.RECIPE_AUTO, Perks.Electricity, 8)
    players[0] = newPlayer({ num = 0, electricity = 9, username = "sp0", onlineId = -1 })
    players[1] = newPlayer({ num = 1, electricity = 9, username = "sp1", onlineId = -1 })
    activePlayers = 2
    resetStats()
    capturePrint(function() fire("OnGameStart") end)
    checkEq(#sentClient, 0, "SP 就地補學，不發 client command")
    checkTrue(players[0]:getKnownRecipes():contains(MDAD.RECIPE_GPS)
        and players[0]:getKnownRecipes():contains(MDAD.RECIPE_AUTO),
        "SP slot 0 兩份配方皆按門檻補學")
    checkTrue(players[1]:getKnownRecipes():contains(MDAD.RECIPE_GPS)
        and players[1]:getKnownRecipes():contains(MDAD.RECIPE_AUTO),
        "SP 後加入的 split-screen slot 也補學")
    checkEq(#recipeWorld.syncs, 0, "SP 本機狀態不送 PF_Recipes 封包")
    players[2] = newPlayer({ num = 2, electricity = 9, username = "sp2", onlineId = -1 })
    activePlayers = 3
    resetStats()
    capturePrint(function() fire("OnCreatePlayer", 2) end)
    checkEq(#sentClient, 0, "SP 後加入 slot 不發 client command")
    checkTrue(players[2]:getKnownRecipes():contains(MDAD.RECIPE_GPS)
        and players[2]:getKnownRecipes():contains(MDAD.RECIPE_AUTO),
        "SP 後加入 slot 由 OnCreatePlayer 就地補學")
    checkEq(#recipeWorld.syncs, 0, "SP 後加入 slot 不送 PF_Recipes")
    recipeWorld.defs[MDAD.RECIPE_GPS] = nil
    players[3] = newPlayer({ num = 3, electricity = 9, username = "sp3", onlineId = -1 })
    activePlayers = 4
    resetStats()
    local missingLog1 = capturePrint(function() fire("OnCreatePlayer", 3) end)
    resetStats()
    local missingLog2 = capturePrint(function() fire("OnCreatePlayer", 3) end)
    checkTrue(logHas(missingLog1, "craftRecipe not found: " .. MDAD.RECIPE_GPS),
        "SP 缺配方留下含短名的診斷")
    checkFalse(logHas(missingLog2, "craftRecipe not found: " .. MDAD.RECIPE_GPS),
        "SP 同一缺配方只記錄一次")
    recipeWorld.defs[MDAD.RECIPE_GPS] =
        recipeWorld.newRecipe(MDAD.RECIPE_GPS, Perks.Electricity, 6)
end

-- (2) server 端：只信事件 actor、只碰自己的兩個配方、真的學到才同步
do
    clientFlag, serverFlag = false, true
    recipeWorld.defs[MDAD.RECIPE_GPS] =
        recipeWorld.newRecipe(MDAD.RECIPE_GPS, Perks.Electricity, 6)
    recipeWorld.defs[MDAD.RECIPE_AUTO] =
        recipeWorld.newRecipe(MDAD.RECIPE_AUTO, Perks.Electricity, 8)

    local veteran = newPlayer({ num = 0, electricity = 9, username = "veteran", onlineId = 7101 })
    local rookie = newPlayer({ num = 1, electricity = 2, username = "rookie", onlineId = 7102 })
    local mid = newPlayer({ num = 2, electricity = 6, username = "mid", onlineId = 7103 })

    -- 技能早就達標卻沒學過（正是實機那批老角色）：兩個配方都補上，同步一次
    nowMs = nowMs + 1000
    resetStats()
    fire("OnClientCommand", MOD_ID, MDAD.CMD_RECIPE_RESCAN, veteran, {})
    checkTrue(veteran:getKnownRecipes():contains(MDAD.RECIPE_GPS), "技能 9：補學 GPS 配方")
    checkTrue(veteran:getKnownRecipes():contains(MDAD.RECIPE_AUTO), "技能 9：補學自駕配方")
    checkEq(#recipeWorld.lookups, 2, "只查本 MOD 自己的兩個配方")
    checkEq(recipeWorld.lookups[1], MDAD.RECIPE_GPS, "查的第一支是 GPS 配方短名")
    checkEq(recipeWorld.lookups[2], MDAD.RECIPE_AUTO, "查的第二支是自駕配方短名")
    checkEq(#recipeWorld.learns, 2, "兩支都交給引擎的 checkAutoLearnAnySkills 判定")
    checkEq(recipeWorld.learns[1] and recipeWorld.learns[1].chr, veteran,
        "判定對象是事件 actor")
    checkEq(recipeWorld.learns[2] and recipeWorld.learns[2].chr, veteran,
        "第二支的判定對象也是同一位 actor")
    checkEq(#recipeWorld.syncs, 1, "真的學到新配方才送一次 PF_Recipes")
    checkEq(recipeWorld.syncs[1] and recipeWorld.syncs[1].flags, 0x01,
        "同步旗標是 PF_Recipes（0x01）")
    checkEq(recipeWorld.syncs[1] and recipeWorld.syncs[1].player, veteran,
        "同步的是 actor 自己")

    -- 重播：已經學會 → knownRecipes 沒變 → 不再送封包
    nowMs = nowMs + 1000
    resetStats()
    fire("OnClientCommand", MOD_ID, MDAD.CMD_RECIPE_RESCAN, veteran, {})
    checkEq(#recipeWorld.learns, 2, "已學會仍照樣交給引擎重判（判定權不搬進 Lua）")
    checkEq(#recipeWorld.syncs, 0, "已學會時不送同步（每次登入白送封包沒意義）")
    checkEq(veteran:getKnownRecipes():size(), 2, "不會重複塞同一個配方")

    -- 技能不足：一個都不補、也不同步
    nowMs = nowMs + 1000
    resetStats()
    fire("OnClientCommand", MOD_ID, MDAD.CMD_RECIPE_RESCAN, rookie, {})
    checkEq(#recipeWorld.learns, 2, "技能不足也照樣問引擎（門檻只寫在 scripts）")
    checkEq(rookie:getKnownRecipes():size(), 0, "技能 2：不補學")
    checkEq(#recipeWorld.syncs, 0, "沒學到就不送同步")

    -- 只達 GPS 門檻：部分補學也要同步一次
    nowMs = nowMs + 1000
    resetStats()
    fire("OnClientCommand", MOD_ID, MDAD.CMD_RECIPE_RESCAN, mid, {})
    checkTrue(mid:getKnownRecipes():contains(MDAD.RECIPE_GPS), "技能 6：補學 GPS 配方")
    checkFalse(mid:getKnownRecipes():contains(MDAD.RECIPE_AUTO), "技能 6 未達自駕門檻：不補")
    checkEq(#recipeWorld.syncs, 1, "只補到一支也要同步一次")

    -- 偽造 payload：不能替別人補、不能指定配方、不能宣告等級
    local victim = newPlayer({
        num = 3, electricity = 9, username = "victim", onlineId = 7106,
    })
    nowMs = nowMs + 1000
    resetStats()
    fire("OnClientCommand", MOD_ID, MDAD.CMD_RECIPE_RESCAN, rookie,
        { target = victim, username = "victim", recipe = "Herbalist",
            recipes = { "Herbalist" }, electricity = 10, level = 10 })
    checkEq(rookie:getKnownRecipes():size(), 0, "偽造等級不能讓技能不足者補學")
    checkFalse(rookie:getKnownRecipes():contains("Herbalist"), "client 指定的配方一律不學")
    checkEq(#recipeWorld.lookups, 2, "偽造 recipe 欄位不會多查一支配方")
    checkEq(recipeWorld.lookups[1], MDAD.RECIPE_GPS, "偽造封包查的仍是自己的 GPS 配方")
    checkEq(#recipeWorld.syncs, 0, "偽造封包不觸發任何同步")
    checkEq(victim:getKnownRecipes():size(), 0, "偽造 target 不能替別人補學")
    checkEq(recipeWorld.learns[1] and recipeWorld.learns[1].chr, rookie,
        "偽造 payload 後引擎判定對象仍是事件 actor")

    -- 空／非表 payload 走同一條路（production 完全不讀 payload）
    nowMs = nowMs + 1000
    resetStats()
    fire("OnClientCommand", MOD_ID, MDAD.CMD_RECIPE_RESCAN, mid, nil)
    checkEq(#recipeWorld.lookups, 2, "payload 為 nil 照樣替 actor 重掃")
    nowMs = nowMs + 1000
    resetStats()
    fire("OnClientCommand", MOD_ID, MDAD.CMD_RECIPE_RESCAN, mid, "forged")
    checkEq(#recipeWorld.lookups, 2, "payload 是字串也不影響（完全不讀）")

    -- 沒有 actor／別的 module：不處理
    nowMs = nowMs + 1000
    resetStats()
    fire("OnClientCommand", MOD_ID, MDAD.CMD_RECIPE_RESCAN, nil, {})
    fire("OnClientCommand", "SomeOtherMod", MDAD.CMD_RECIPE_RESCAN, veteran, {})
    checkEq(#recipeWorld.lookups, 0, "沒有 actor 或別的 module 的封包完全不處理")

    -- 沿用既有 250ms per-player 節流：洪水封包不能每發都重掃配方
    nowMs = nowMs + 1000
    resetStats()
    fire("OnClientCommand", MOD_ID, MDAD.CMD_RECIPE_RESCAN, rookie, {})
    checkEq(#recipeWorld.lookups, 2, "節流窗外的請求正常處理")
    fire("OnClientCommand", MOD_ID, MDAD.CMD_RECIPE_RESCAN, rookie, {})
    checkEq(#recipeWorld.lookups, 2, "同一 actor 250ms 內的重發被既有節流擋掉")
    nowMs = nowMs + 250
    fire("OnClientCommand", MOD_ID, MDAD.CMD_RECIPE_RESCAN, rookie, {})
    checkEq(#recipeWorld.lookups, 4, "滿 250ms 後放行")

    -- 配方腳本缺失（scripts 打錯名／被別的 MOD 蓋掉）：帶配方名的診斷，最多一次
    nowMs = nowMs + 1000
    recipeWorld.defs[MDAD.RECIPE_AUTO] = nil
    local fresh = newPlayer({ num = 3, electricity = 9, username = "fresh", onlineId = 7104 })
    resetStats()
    local rlog = capturePrint(function()
        fire("OnClientCommand", MOD_ID, MDAD.CMD_RECIPE_RESCAN, fresh, {})
    end)
    checkTrue(logHas(rlog, "craftRecipe not found: " .. MDAD.RECIPE_AUTO),
        "配方腳本缺失留下帶配方名的 console 診斷")
    checkTrue(logHas(rlog, MDAD.BUILD), "診斷帶 build 印記（實機才判得出跑的是哪版）")
    checkTrue(fresh:getKnownRecipes():contains(MDAD.RECIPE_GPS),
        "一支配方缺失不影響另一支的補學")
    checkEq(#recipeWorld.syncs, 1, "缺一支仍替學到的那支同步一次")

    nowMs = nowMs + 1000
    local other = newPlayer({ num = 4, electricity = 9, username = "other", onlineId = 7105 })
    resetStats()
    rlog = capturePrint(function()
        fire("OnClientCommand", MOD_ID, MDAD.CMD_RECIPE_RESCAN, other, {})
    end)
    checkEq(#rlog, 0, "同一支缺失的配方不重複洗 log（每個配方名最多印一次）")
    recipeWorld.defs[MDAD.RECIPE_AUTO] =
        recipeWorld.newRecipe(MDAD.RECIPE_AUTO, Perks.Electricity, 8)
end

-- (3) 專屬雜誌：戰利品注入的目標／權重／防重，與 AllowCraft* 生成政策
do
    clientFlag, serverFlag = false, true
    local names = { "ArmyStorageElectronics", "ElectronicStoreMisc", "BookstoreComputer",
        "LibraryComputer", "MagazineRackMixed", "CrateRandomJunk" }
    local expect = { ArmyStorageElectronics = 1, ElectronicStoreMisc = 2,
        BookstoreComputer = 2, LibraryComputer = 1, MagazineRackMixed = 0.5 }
    ProceduralDistributions = { list = {} }
    for i = 1, #names do
        ProceduralDistributions.list[names[i]] = { items = { "Base.Plank", 3 } }
    end
    setSandbox({ AllowCraftGPS = true, AllowCraftAutopilot = true,
        SpawnGPS = true, SpawnAutopilot = true })

    fire("OnPostDistributionMerge")
    local sizes = {}
    for i = 1, #names do sizes[names[i]] = #ProceduralDistributions.list[names[i]].items end
    -- 同一行程回主選單再讀檔＝事件再觸發；ProceduralDistributions 不重置
    fire("OnPostDistributionMerge")
    fire("OnPostDistributionMerge")
    for i = 1, #names do
        local items = ProceduralDistributions.list[names[i]].items
        local n, w = countIn(items, MDAD.TYPE_MANUAL)
        checkEq(#items, sizes[names[i]], names[i] .. "：連跑三次長度不變（雜誌沒有重複注入）")
        checkEq(#items % 2, 0, names[i] .. "：items 一定成對（type, weight）")
        checkEq(n, expect[names[i]] and 1 or 0, names[i] .. "：雜誌出現次數")
        if expect[names[i]] then
            checkEq(w, expect[names[i]], names[i] .. "：雜誌權重沒有被疊加")
        end
        checkEq(items[1], "Base.Plank", names[i] .. "：原版既有條目沒被動到")
        checkEq(items[2], 3, names[i] .. "：原版既有權重沒被改")
    end
    checkEq(#ProceduralDistributions.list.CrateRandomJunk.items, 2,
        "不在雜誌目標清單的表完全沒被碰")

    -- 生成政策：手冊教的是那兩個配方，只要還有一個做得出來就有用。
    -- 與 SpawnGPS／SpawnAutopilot 分開判斷——那兩個管的是裝置本體的生成。
    local loot = newLootContainer({ MDAD.TYPE_MANUAL, GPS_T, "Base.Plank" })
    fire("OnFillContainer", "bookstore", "shelves", loot)
    checkEq(loot:count(MDAD.TYPE_MANUAL), 1, "兩個製作開關都開：保留手冊")

    setSandbox({ AllowCraftGPS = true, AllowCraftAutopilot = false,
        SpawnGPS = true, SpawnAutopilot = true })
    loot = newLootContainer({ MDAD.TYPE_MANUAL, "Base.Plank" })
    fire("OnFillContainer", "bookstore", "shelves", loot)
    checkEq(loot:count(MDAD.TYPE_MANUAL), 1, "只開 GPS 製作：手冊仍有用，保留")

    setSandbox({ AllowCraftGPS = false, AllowCraftAutopilot = true,
        SpawnGPS = true, SpawnAutopilot = true })
    loot = newLootContainer({ MDAD.TYPE_MANUAL, "Base.Plank" })
    fire("OnFillContainer", "bookstore", "shelves", loot)
    checkEq(loot:count(MDAD.TYPE_MANUAL), 1, "只開自駕製作：手冊仍有用，保留")

    setSandbox({ AllowCraftGPS = false, AllowCraftAutopilot = false,
        SpawnGPS = true, SpawnAutopilot = true })
    loot = newLootContainer({ MDAD.TYPE_MANUAL, GPS_T, AUTO_T, "Base.Plank" })
    fire("OnFillContainer", "bookstore", "shelves", loot)
    checkEq(loot:count(MDAD.TYPE_MANUAL), 0, "兩個製作開關都關才移除手冊")
    checkEq(loot:count(GPS_T), 1, "關閉製作不影響 SpawnGPS 開著的 GPS 本體")
    checkEq(loot:count(AUTO_T), 1, "關閉製作不影響 SpawnAutopilot 開著的自駕模組本體")
    checkEq(loot:count("Base.Plank"), 1, "手冊過濾不碰原版物品")

    -- 沙盒未載入（主選單／載入中）：預設是「留著」，不得誤刪
    setSandbox(nil)
    loot = newLootContainer({ MDAD.TYPE_MANUAL })
    fire("OnFillContainer", "bookstore", "shelves", loot)
    checkEq(loot:count(MDAD.TYPE_MANUAL), 1, "沙盒未載入時不移除手冊（fail-open）")

    clientFlag = true
    setSandbox({ AllowCraftGPS = false, AllowCraftAutopilot = false })
    loot = newLootContainer({ MDAD.TYPE_MANUAL })
    fire("OnFillContainer", "bookstore", "shelves", loot)
    checkEq(loot:count(MDAD.TYPE_MANUAL), 1, "MP client 不改 server 權威的生成內容")
    clientFlag = false
    setSandbox({ AllowCraftGPS = true, AllowCraftAutopilot = true,
        SpawnGPS = true, SpawnAutopilot = true })
end

-- =====================================================================
-- 情境二十八d：opt-in telemetry 接線（production Diagnostics／VehicleProfile）
-- =====================================================================
scenario("opt-in telemetry：lifecycle／pn／單檔路徑／關閉零呼叫／失敗不中斷／vprofile 不進控制")

local function scenarioTelemetry()
    checkEq(type(MDADVehicleProfile), "table", "production MDAD_VehicleProfile.lua 真的載入了")
    checkEq(type(MDADDiagnostics), "table", "production MDAD_Diagnostics.lua 真的載入了")
    checkEq(type(MDADVehicleProfile.build), "function", "VehicleProfile.build 存在")
    checkEq(type(MDADDiagnostics.start), "function", "Diagnostics.start 存在")
    checkEq(type(MDADDiagnostics.sample), "function", "Diagnostics.sample 存在")
    checkEq(type(MDADDiagnostics.event), "function", "Diagnostics.event 存在")
    checkEq(type(MDADDiagnostics.stop), "function", "Diagnostics.stop 存在")
    checkEq(type(MDADDiagnostics.fail), "function", "Diagnostics.fail 存在")

    if type(MDAD.HUD) ~= "table" then MDAD.HUD = {} end
    local hudTelem = MDAD.HUD.telemetryEnabled
    MDAD.HUD.telemetryEnabled = function() return drive.telemOn == true end

    local oldDocumentFolder = getMyDocumentFolder
    local oldFileSeparator = getFileSeparator
    local oldClipboard = Clipboard
    local copiedPath = nil
    getMyDocumentFolder = function() return "C:/Zomboid" end
    getFileSeparator = function() return "/" end
    Clipboard = {
        setClipboard = function(text) copiedPath = text end,
    }

    drive.telemOn = false
    drive.diag = {
        build = 0, start = 0, sample = 0, critical = 0, event = 0, stop = 0, fail = 0,
        startPn = nil, samplePn = nil, stopPn = nil, stopReason = nil,
        failPn = nil, failMessage = nil, names = {}, fields = {}, phases = {},
        last = {}, -- 最後一幀的碰撞證據欄位（Driver 端接線用；編碼由 test_diagnostics 驗）
    }

    local origStart = MDADDiagnostics.start
    local origSample = MDADDiagnostics.sample
    local origEvent = MDADDiagnostics.event
    local origStop = MDADDiagnostics.stop
    local origFail = MDADDiagnostics.fail
    local origShould = MDADDiagnostics.shouldSample
    local origBuild = MDADVehicleProfile.build
    local forceShould = nil
    MDADVehicleProfile.build = function(vehicle)
        drive.diag.build = drive.diag.build + 1
        return origBuild(vehicle)
    end

    MDADDiagnostics.start = function(pn, vehicle, profile)
        drive.diag.start = drive.diag.start + 1
        drive.diag.startPn = pn
        drive.diag.startProfile = profile
        return true -- Driver lifecycle spy; production file IO is covered by test_diagnostics.lua
    end
    MDADDiagnostics.sample = function(pn, nowMsArg, x, y, heading, speed, target, remaining, lat, err, steer, force, mode, gear, regulator, sensor, critical,
            planMode, routeS, blockS, dodgeMargin, dodgeNeed, roadBias,
            blockHitX, blockHitY, followerIdx,
            blocked, dodging, offroad, corner, coupled, phys)
        drive.diag.sample = drive.diag.sample + 1
        drive.diag.samplePn = pn
        if critical == true then drive.diag.critical = drive.diag.critical + 1 end
        local last = drive.diag.last
        last.planMode = planMode
        last.routeS = routeS
        last.blockS = blockS
        last.dodgeMargin = dodgeMargin
        last.dodgeNeed = dodgeNeed
        last.roadBias = roadBias
        last.blockHitX = blockHitX
        last.blockHitY = blockHitY
        last.followerIdx = followerIdx
        last.blocked = blocked
        last.dodging = dodging
        last.offroad = offroad
        last.corner = corner
        last.coupled = coupled
        last.phys = phys
        return true -- Driver lifecycle spy; production sampling is covered separately
    end
    MDADDiagnostics.event = function(pn, name, a, b, c, d)
        drive.diag.event = drive.diag.event + 1
        if type(a) == "table" then
            drive.diag.fields = drive.diag.fields or {}
            drive.diag.fields[name] = a
            drive.diag.phases[name .. ":" .. tostring(a.phase)] = a
        end
        drive.diag.names[name] = true
        if origEvent then return origEvent(pn, name, a, b, c, d) end
    end
    MDADDiagnostics.stop = function(pn, reason)
        drive.diag.stop = drive.diag.stop + 1
        drive.diag.stopPn = pn
        drive.diag.stopReason = reason
        if origStop then return origStop(pn, reason) end
    end
    MDADDiagnostics.fail = function(pn, detail)
        drive.diag.fail = drive.diag.fail + 1
        drive.diag.failPn = pn
        drive.diag.failMessage = detail
        MDADDiagnostics.stop(pn, "error")
        return true
    end
    MDADDiagnostics.shouldSample = function()
        if forceShould ~= nil then return forceShould end
        return true
    end

    drive.telemOn = false
    checkTrue(armDrive(), "telemetry off 仍可啟動")
    driveReset(dveh)
    for _ = 1, 8 do driveTick(dp, dveh) end
    checkEq(dveh._imp.max, 1, "off：每幀最多一次 addImpulse")
    MDAD.Drive.stop(0, nil)
    checkEq(drive.diag.start, 0, "off：零 start")
    checkEq(drive.diag.build, 1, "off：session-start 仍恰 build 一次共用 profile")
    checkEq(drive.diag.sample, 0, "off：零 sample")
    checkEq(drive.diag.event, 0, "off：零 event")
    checkEq(drive.diag.stop, 0, "off：零 stop")
    checkEq(drive.calls.isDoingOffroad, 0, "off：零 isDoingOffroad")
    checkEq(drive.calls.isBraking, 0, "off：零 isBraking")
    checkEq(drive.calls.getMinWheelSkid, 0, "off：零 getMinWheelSkid")
    checkEq(drive.calls.getEngineSpeed, 0, "off：零 getEngineSpeed")
    checkEq(drive.calls.getTransmissionNumber, 0, "off：零 getTransmissionNumber")
    checkEq(drive.calls.getRegulatorSpeed, 0, "off：零 getRegulatorSpeed")
    checkEq(drive.calls.getLinearVelocity, 0, "off：零 getLinearVelocity")

    drive.diag.start, drive.diag.sample, drive.diag.event, drive.diag.stop,
        drive.diag.build = 0, 0, 0, 0, 0
    drive.diag.names, drive.diag.fields, drive.diag.phases = {}, {}, {}
    drive.telemOn = true
    checkTrue(armDrive(), "telemetry on 啟動")
    checkEq(drive.diag.start, 1, "on：start 一次")
    checkEq(drive.diag.build, 1, "on：VehicleProfile.build 一次")
    checkEq(drive.diag.startPn, 0, "start 用精確 pn")
    checkTrue(drive.diag.sample > 0, "on：sample 有接到")
    checkEq(drive.diag.fields.target and drive.diag.fields.target.phase, "set",
        "initial target event phase=set")
    checkEq(drive.diag.fields.route and drive.diag.fields.route.why, "initial",
        "initial route event why=initial")
    checkEq(drive.diag.phases["route:cutover"].len, nil,
        "initial cutover 無 route.len 時省略，不寫假 0")
    checkNear(drive.diag.phases["route:ready"].len, 156, 1e-9,
        "profile build ready event 寫入精確非零 length")
    checkEq(drive.diag.samplePn, 0, "sample 用精確 pn")
    checkTrue(drive.diag.names.start == true, "event start 有接到")
    driveReset(dveh)
    for _ = 1, 5 do
        dveh._x = dveh._x + 0.1852
        driveTick(dp, dveh)
    end
    checkEq(dveh._imp.max, 1, "on：每幀最多一次 addImpulse")
    checkEq(drive.bad.impulse, 0, "on：無單幀兩次 impulse")

    -- 碰撞證據欄位真的從 Driver 接到 Diagnostics（值來源＝既有 session 狀態）
    local dlast = drive.diag.last
    checkEq(type(dlast.planMode), "string", "sample 帶 replan 離場分類 planMode")
    checkEq(type(dlast.routeS), "number", "sample 帶沿線弧長 routeS")
    checkEq(type(dlast.blockS), "number", "sample 帶煞停錨 blockS")
    checkEq(type(dlast.dodgeNeed), "number", "sample 帶掃掠淨距 dodgeNeed")
    checkEq(type(dlast.roadBias), "number", "sample 帶路面對中校正")
    checkEq(type(dlast.followerIdx), "number", "sample 帶 follower 投影游標")
    checkEq(dlast.blocked, false, "跟線幀 blocked=false")
    checkEq(dlast.dodging, false, "跟線幀 dodging=false")
    checkEq(dlast.corner, false, "跟線幀 corner latch=false")
    checkEq(dlast.coupled, false, "橫推跟線幀 coupled=false（不是耦力調頭）")
    checkEq(dveh._imp.max, 1, "擴充遙測欄位不改變 addImpulse 次數")
    checkEq(drive.pool.live, 0, "on：物理速度向量成對歸還")
    check(drive.calls.isDoingOffroad > 0, "on：讀 isDoingOffroad")
    check(drive.calls.getLinearVelocity > 0, "on：讀 getLinearVelocity")
    checkEq(type(dlast.phys), "table", "sample 帶 phys table")
    checkEq(type(dlast.phys.physicalOffroad), "boolean", "phys.physicalOffroad")
    checkEq(type(dlast.phys.isBraking), "boolean", "phys.isBraking")
    checkEq(type(dlast.phys.minWheelSkid), "number", "phys.minWheelSkid")
    checkEq(type(dlast.phys.vLong), "number", "phys.vLong")
    checkEq(type(dlast.phys.vLat), "number", "phys.vLat")
    checkEq(type(dlast.phys.engineSpeed), "number", "phys.engineSpeed")
    checkEq(type(dlast.phys.transmissionNumber), "number", "phys.transmissionNumber")
    checkEq(type(dlast.phys.regulatorSpeed), "number", "phys.regulatorSpeed")
    checkEq(type(dlast.phys.expectedLane), "number", "phys.expectedLane")
    checkEq(type(dlast.phys.latDev), "number", "phys.latDev")
    checkEq(type(dlast.phys.roadState), "string", "phys.roadState")
    checkEq(type(dlast.phys.capPerception), "number", "phys.capPerception")
    checkEq(dlast.phys.physicalOffroad, false, "跟線幀 Java offroad=false")

    driveReset(dveh)
    drive.diag.sample = 0
    for _ = 1, 5 do
        dveh._x = dveh._x + 0.1852
        driveTick(dp, dveh)
    end
    check(drive.diag.sample > 0, "對齊窗有 sample")
    checkEq(drive.calls.isDoingOffroad, drive.diag.sample, "isDoingOffroad 次數 = sample")
    checkEq(drive.calls.getLinearVelocity, drive.diag.sample, "getLinearVelocity 次數 = sample")

    forceShould = false
    driveReset(dveh)
    drive.diag.sample = 0
    for _ = 1, 5 do driveTick(dp, dveh) end
    checkTrue(drive.calls.isDoingOffroad <= 1,
        "gate skip 不跑診斷 getter；至多一筆 sensor snapshot 輔證")
    checkEq(drive.calls.getLinearVelocity, 0, "gate skip 零 getLinearVelocity")
    check(drive.diag.sample > 0, "gate skip 仍呼叫 sample 探活")
    forceShould = nil
    drive.nav.route = newRoute(40, 0, 0, 4, 0)
    drive.nav.route.len = 156
    nowMs = nowMs + 250
    driveTick(dp, dveh)
    checkEq(drive.diag.fields.route and drive.diag.fields.route.why, "deviation",
        "same-target route cutover event why=deviation")
    checkTrue(drive.diag.names.route == true, "route cutover 有 event")
    checkNear(drive.diag.phases["route:cutover"].len, 156, 1e-9,
        "cutover 優先寫 finite route.len")

    drive.nav.tx = 300.1
    drive.nav.route = newRoute(40, 0, 0, 4, 0)
    nowMs = nowMs + 250
    driveTick(dp, dveh)
    checkEq(drive.diag.fields.target and drive.diag.fields.target.phase, "change",
        "任意非零 target 座標差都算 true target change")
    checkEq(drive.diag.fields.route and drive.diag.fields.route.why, "target",
        "小於 0.5m 的 target change route 仍分類 target")

    dveh._y = 20
    driveTick(dp, dveh)
    checkTrue(drive.diag.names["return"] == true, "RETURN enter 有 event")
    checkTrue(drive.diag.critical > 0, "offroad sample 切到 10Hz critical flag")
    checkEq(drive.diag.last.offroad, true, "offroad 旗標進到 sample 欄位")
    dveh._y = 0

    MDAD.Drive.stop(0, nil)
    checkEq(drive.diag.stop, 1, "stop 在 session 移除前呼叫一次")
    checkEq(drive.diag.stopPn, 0, "stop 用精確 pn")
    checkTrue(drive.diag.stopReason ~= nil, "stop 帶 reason")

    local copied = false
    pcall(function()
        if type(MDADDiagnostics.hasLatest) == "function" and MDADDiagnostics.hasLatest() then
            copied = MDADDiagnostics.copyLatestPath(0)
        end
        if not copied and type(MDADDiagnostics.copyFolderPath) == "function" then
            copied = MDADDiagnostics.copyFolderPath(0)
        end
    end)
    checkTrue(copied, "session 檔路徑複製成功")
    checkEq(type(copiedPath), "string", "剪貼簿收到一個 session 檔路徑")
    checkTrue(string.find(copiedPath, "Telemetry", 1, true) ~= nil,
        "路徑落在 Lua/MinidoracatAutoDrive/Telemetry")
    checkTrue(string.find(copiedPath, "Steam", 1, true) == nil, "路徑不含 SteamID")

    local stopsBeforeMenu = drive.diag.stop
    checkTrue(armDrive(), "menu cleanup 情境啟動")
    dveh._regulator = true
    fire("OnMainMenuEnter")
    checkFalse(MDAD.Drive.isActive(0), "回主選單清除 drive session")
    checkEq(drive.diag.stop, stopsBeforeMenu + 1, "回主選單關閉 telemetry writer")
    checkEq(drive.diag.stopReason, "menu", "回主選單記錄 menu end reason")
    checkEq(dveh._regulator, false, "回主選單關閉原車 regulator")

    local sampleSpy = MDADDiagnostics.sample
    MDADDiagnostics.sample = function() error("sample-fail") end
    drive.diag.fail, drive.diag.failMessage, drive.diag.stopReason = 0, nil, nil
    driveReset(dveh)
    checkTrue(MDAD.Drive.start(dp), "Diagnostics.sample 丟錯仍啟動")
    driveTick(dp, dveh)
    driveTick(dp, dveh)
    checkTrue(MDAD.Drive.isActive(0), "sample 失敗只停診斷、不拆 drive session")
    checkEq(dveh._imp.max, 1, "sample 失敗不改變 addImpulse")
    checkEq(drive.pool.live, 0, "sample 失敗仍歸還外層向量")
    checkEq(drive.diag.fail, 1, "sample 失敗走單一 diagnostics fail boundary")
    checkTrue(string.find(drive.diag.failMessage or "", "sample-fail", 1, true) ~= nil,
        "sample failure 保留原始錯誤")
    checkEq(drive.diag.stopReason, "error", "sample 失敗以 error 收掉 telemetry session")
    MDAD.Drive.stop(0, nil)
    MDADDiagnostics.sample = sampleSpy

    local gateSpy = MDADDiagnostics.shouldSample
    MDADDiagnostics.shouldSample = function() error("gate-fail") end
    drive.diag.fail, drive.diag.failMessage, drive.diag.stopReason = 0, nil, nil
    checkTrue(armDrive(), "Diagnostics.shouldSample 丟錯仍維持 drive session")
    MDADDiagnostics.shouldSample = gateSpy
    driveReset(dveh)
    driveTick(dp, dveh)
    checkTrue(MDAD.Drive.isActive(0), "gate 失敗後 Drive 繼續")
    checkEq(dveh._imp.max, 1, "gate 失敗後下一幀控制照常")
    checkEq(drive.calls.isDoingOffroad, 0, "gate 失敗在 physics getter 前收口")
    checkEq(drive.pool.live, 0, "gate 失敗仍歸還外層向量")
    checkEq(drive.diag.fail, 1, "gate 失敗走單一 fail boundary")
    checkTrue(string.find(drive.diag.failMessage or "", "gate-fail", 1, true) ~= nil,
        "gate failure 保留原始錯誤")
    checkEq(drive.diag.stopReason, "error", "gate 失敗記 error")
    MDAD.Drive.stop(0, nil)


    -- Recovery-only sampling owns its own vector. Allocation/getter failure must stop
    -- telemetry through diagFail while SETTLE control continues and the pool stays balanced.
    drive.fillWorld(-10, 70, -7, 7)
    forceShould = true
    checkTrue(armDrive(), "recovery telemetry boundary 情境啟動")
    setHeading(dveh, 0)
    driveTick(dp, dveh)
    dveh._trans = 1
    drive.putSolid(2, 0, "harness_recovery_diag")
    drive.scanRound(true)
    dveh._speed = 0
    nowMs = nowMs + 2501
    driveTick(dp, dveh)
    dveh._x, dveh._speed = -3.1, -13
    local recoveryAlloc = BaseVehicle.allocVector3f
    BaseVehicle.allocVector3f = function() error("recovery-alloc-fail") end
    drive.diag.fail, drive.diag.failMessage = 0, nil
    nowMs = nowMs + 16
    driveReset(dveh)
    driveTick(dp, dveh)
    BaseVehicle.allocVector3f = recoveryAlloc
    forceShould = nil
    checkTrue(MDAD.Drive.isActive(0), "recovery telemetry alloc 失敗不拆控制 session")
    checkTrue(drive.calls.forceBrake >= 1, "telemetry 失敗後 settle brake 仍執行")
    checkEq(drive.diag.fail, 1, "recovery telemetry 失敗走 diagFail")
    checkTrue(string.find(drive.diag.failMessage or "", "recovery-alloc-fail", 1, true) ~= nil,
        "recovery telemetry 保留原始錯誤")
    checkEq(drive.pool.live, 0, "recovery telemetry alloc failure 無池洩漏")
    checkTrue(drive.diag.phases["unstick:settle"] ~= nil,
        "倒足 3m 先記 settle transition")
    checkEq(drive.diag.phases["unstick:success"], nil,
        "尚未停到 |speed|<1 前不得宣告 success")
    dveh._trans = 2
    MDAD.Drive.stop(0, nil)

    drive.diag.phases = {}
    forceShould = true
    drive.fillWorld(-10, 70, -7, 7)
    checkTrue(armDrive(), "settle success event 情境啟動")
    setHeading(dveh, 0)
    driveTick(dp, dveh)
    dveh._trans = 1
    drive.putSolid(2, 0, "harness_settle_event")
    drive.scanRound(true)
    dveh._speed = 0
    nowMs = nowMs + 2501
    driveTick(dp, dveh)
    dveh._x, dveh._speed = -3.1, -13
    nowMs = nowMs + 16
    driveTick(dp, dveh)
    checkEq(drive.diag.phases["unstick:success"], nil,
        "settle entry 仍沒有 success event")
    dveh._speed = -0.5
    nowMs = nowMs + 100
    driveTick(dp, dveh)
    forceShould = nil
    checkNear(drive.diag.phases["unstick:success"].speed, -0.5, 1e-9,
        "真正停妥才記 success 與 final speed")
    dveh._trans = 2
    MDAD.Drive.stop(0, nil)

    local eventSpy = MDADDiagnostics.event
    MDADDiagnostics.event = function() error("event-fail") end
    drive.diag.fail, drive.diag.failMessage, drive.diag.stopReason = 0, nil, nil
    checkTrue(armDrive(), "Diagnostics.event 丟錯仍維持 drive session")
    MDADDiagnostics.event = eventSpy
    checkTrue(MDAD.Drive.isActive(0), "event 失敗只停診斷、不拆 Drive")
    checkEq(drive.diag.fail, 1, "event 失敗走單一 fail boundary")
    checkTrue(string.find(drive.diag.failMessage or "", "event-fail", 1, true) ~= nil,
        "event failure 保留原始錯誤")
    checkEq(drive.diag.stopReason, "error", "event 失敗記 error")
    MDAD.Drive.stop(0, nil)

    checkTrue(armDrive(), "getter lookup failure 情境啟動")
    local lookupGetter = dveh.isDoingOffroad
    local lookupMeta = getmetatable(dveh)
    dveh.isDoingOffroad = nil
    setmetatable(dveh, {
        __index = function(obj, key)
            if key == "isDoingOffroad" then error("lookup-fail") end
            local inherited = lookupMeta and lookupMeta.__index
            if type(inherited) == "function" then return inherited(obj, key) end
            if type(inherited) == "table" then return inherited[key] end
            return nil
        end,
    })
    drive.diag.fail, drive.diag.failMessage, drive.diag.stopReason = 0, nil, nil
    driveReset(dveh)
    driveTick(dp, dveh)
    dveh.isDoingOffroad = lookupGetter
    setmetatable(dveh, lookupMeta)
    checkTrue(MDAD.Drive.isActive(0), "getter lookup 丟錯不拆 Drive")
    checkEq(drive.pool.live, 0, "getter lookup 丟錯仍歸還外層向量")
    checkEq(drive.diag.fail, 1, "getter lookup 丟錯走 fail boundary")
    checkTrue(string.find(drive.diag.failMessage or "", "lookup-fail", 1, true) ~= nil,
        "getter lookup failure 保留原始錯誤")
    checkEq(drive.diag.stopReason, "error", "getter lookup failure 記 error")
    MDAD.Drive.stop(0, nil)

    checkTrue(armDrive(), "velocity allocation failure 情境啟動")
    local allocSpy = BaseVehicle.allocVector3f
    local skidSpy = dveh.getMinWheelSkid
    local physicsAlloc = false
    dveh.getMinWheelSkid = function(self)
        physicsAlloc = true
        return skidSpy(self)
    end
    BaseVehicle.allocVector3f = function()
        if physicsAlloc then
            physicsAlloc = false
            error("alloc-fail")
        end
        return allocSpy()
    end
    drive.diag.fail, drive.diag.failMessage, drive.diag.stopReason = 0, nil, nil
    driveReset(dveh)
    driveTick(dp, dveh)
    BaseVehicle.allocVector3f = allocSpy
    dveh.getMinWheelSkid = skidSpy
    checkTrue(MDAD.Drive.isActive(0), "velocity alloc 丟錯不拆 Drive")
    checkEq(drive.pool.live, 0, "velocity alloc 丟錯仍歸還外層向量")
    checkEq(drive.diag.fail, 1, "velocity alloc 丟錯走 fail boundary")
    checkTrue(string.find(drive.diag.failMessage or "", "alloc-fail", 1, true) ~= nil,
        "velocity alloc failure 保留原始錯誤")
    checkEq(drive.diag.stopReason, "error", "velocity alloc failure 記 error")
    MDAD.Drive.stop(0, nil)

    checkTrue(armDrive(), "velocity read failure 情境啟動")
    local velocitySpy = dveh.getLinearVelocity
    dveh.getLinearVelocity = function() error("velocity-read-fail") end
    drive.diag.fail, drive.diag.failMessage, drive.diag.stopReason = 0, nil, nil
    driveReset(dveh)
    driveTick(dp, dveh)
    dveh.getLinearVelocity = velocitySpy
    checkTrue(MDAD.Drive.isActive(0), "velocity read 丟錯不拆 Drive")
    checkEq(drive.pool.live, 0, "velocity read 丟錯先歸還 inner 與 outer 向量")
    checkEq(drive.bad.pair, 0, "velocity read 丟錯該幀 alloc/release 成對")
    checkEq(drive.diag.fail, 1, "velocity read 丟錯走 fail boundary")
    checkTrue(string.find(drive.diag.failMessage or "", "velocity-read-fail", 1, true) ~= nil,
        "velocity read failure 保留原始錯誤")
    checkEq(drive.diag.stopReason, "error", "velocity read failure 記 error")
    MDAD.Drive.stop(0, nil)

    -- 同幀 dodge 候選 24 與 8 隻殭屍 10 競合：最終 winner 必須是 zombie；
    -- dodge 候選仍獨立保留，不能用 s.dodging 推測 active reason。
    setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
        AutoDriveMaxSpeed = 40, RightLaneBias = 0 })
    MDAD.Drive.setSlowPref(0, "zombie", true)
    drive.fillWorld(-2, 70, -7, 7)
    drive.putSolid(20, 0, "telemetry_winner")
    drive.putMoving(25, 0, { _class = "IsoZombie" })
    drive.putMoving(25, -1, { _class = "IsoZombie" })
    drive.putMoving(26, 0, { _class = "IsoZombie" })
    drive.putMoving(26, 1, { _class = "IsoZombie" })
    drive.putMoving(27, -1, { _class = "IsoZombie" })
    drive.putMoving(27, 0, { _class = "IsoZombie" })
    drive.putMoving(27, 1, { _class = "IsoZombie" })
    drive.putMoving(28, 0, { _class = "IsoZombie" })
    drive.diag.last = {}
    checkTrue(armDrive(), "dodge+zombie winner 情境啟動")
    setHeading(dveh, 0.05)
    dveh._speed = 20
    driveReset(dveh)
    drive.scanRound()
    driveReset(dveh)
    driveTick(dp, dveh)
    local winnerPhys = drive.diag.last.phys or {}
    checkTrue(drive.calls.maxRegSpeed > 0 and drive.calls.maxRegSpeed <= 10,
        "dodge+zombie target respects zombie 10 ceiling and stricter coast envelope")
    checkEq(winnerPhys.activeCapReason, "corridor",
        "activeCapReason preserves the stricter full-gate winner")
    checkTrue(type(winnerPhys.capSensor) == "number"
            and winnerPhys.capSensor > 0 and winnerPhys.capSensor <= 10,
        "capSensor saves the stricter aggregate winner under the zombie ceiling")
    checkTrue(type(winnerPhys.capDodge) == "number"
            and winnerPhys.capDodge > 0,
        "capDodge independently preserves the dynamic dodge candidate")
    MDAD.Drive.stop(0, nil)

    MDADDiagnostics.start = function() error("diag-fail") end
    drive.telemOn = true
    driveReset(dveh)
    checkTrue(MDAD.Drive.start(dp), "Diagnostics.start 丟錯仍啟動")
    checkTrue(MDAD.Drive.isActive(0), "diag 失敗不拆 session")
    driveTick(dp, dveh)
    driveTick(dp, dveh)
    checkEq(dveh._imp.max, 1, "diag 失敗不改變 addImpulse")
    MDAD.Drive.stop(0, nil)
    MDADDiagnostics.start = function(pn, vehicle, profile)
        drive.diag.start = drive.diag.start + 1
        drive.diag.startPn = pn
        return true
    end

    MDADVehicleProfile.build = function(_)
        return {
            valid = true, fallback = false, geometryValid = true, scriptName = "x",
            bodyW = 1.8, bodyL = 4.4, halfW = 0.9, halfL = 2.2,
            centerOfMassX = 0, centerOfMassY = 0.5, centerOfMassZ = 0,
            mass = 1, maxSpeed = 1, wheelbase = 1, track = 1,
            clamp0 = 0, clamp30 = 0, clampMax = 0,
            wheelFriction = 0, delta0Safe = 0, deltaVSafe = 0,
            rMin = 0, lookScale = 0, rearArm = 0, needHalf = 99, probeR = 0,
        }
    end
    drive.telemOn = true
    checkTrue(armDrive(), "wild non-geometry vprofile 仍啟動")
    driveReset(dveh)
    driveTick(dp, dveh)
    checkEq(dveh._imp.total, 1, "non-geometry profile scalars 不改變 addImpulse 次數")
    checkTrue(dveh._imp.torqueY ~= 0 or dveh._imp.x ~= 0,
        "wild rearArm=0 仍用 Driver REAR_ARM 施力")
    MDAD.Drive.stop(0, nil)

    MDADDiagnostics.start = origStart
    MDADDiagnostics.sample = origSample
    MDADDiagnostics.event = origEvent
    MDADDiagnostics.stop = origStop
    MDADDiagnostics.fail = origFail
    MDADDiagnostics.shouldSample = origShould
    MDADVehicleProfile.build = origBuild
    MDAD.HUD.telemetryEnabled = hudTelem
    drive.telemOn = false
    getMyDocumentFolder = oldDocumentFolder
    getFileSeparator = oldFileSeparator
    Clipboard = oldClipboard
end
scenarioTelemetry()

-- =====================================================================
-- Phase E：v4 strict consumer、hot getter、EWMA key、surface-aware RETURN
-- =====================================================================
scenario("Phase E：v4 strict metadata、adaptive getter cache、traction reset、RETURN exact line")
local function scenarioPhaseE()
    local oldVeh = dveh
    local hotVeh = newVehicle({
        battery = newItem("Base.CarBattery", { uses = 0.8 }),
        engineRunning = true, mass = 1200, speed = 20, maxSpeed = 90,
        bodyW = 2.0, bodyL = 5.2, comX = 0.6, comZ = 0.4, profileFull = true,
        enginePower = 4000, brakingForce = 80,
        wheelFriction = 1.5, tireFriction = 1.5,
    })
    dveh = hotVeh
    hotVeh._driver, dp._vehicle = dp, hotVeh
    local function v4Route(surface, width)
        local route = newRoute(40, 0, 0, 4, 0)
        route.segSurface, route.segWidth = {}, {}
        for i = 1, 39 do
            route.segSurface[i], route.segWidth[i] = surface, width
        end
        route.len, route.cost = 156, 156
        route.avoidPenalty, route.approachSurface = 0, "unknown"
        return route
    end
    local function v4CurveRoute(degrees)
        local pts = {}
        for i = 0, 10 do
            pts[#pts + 1] = i * 4
            pts[#pts + 1] = 0
        end
        local endA = math.rad(degrees)
        local ex, ey = 40, 0
        for i = 1, 25 do
            pts[#pts + 1] = ex + math.cos(endA) * i * 4
            pts[#pts + 1] = ey + math.sin(endA) * i * 4
        end
        local route = { pts = pts, segSurface = {}, segWidth = {},
            avoidPenalty = 0, approachSurface = "unknown" }
        for i = 1, #pts / 2 - 1 do
            route.segSurface[i], route.segWidth[i] = "paved", 10
        end
        return route
    end
    local captured = nil
    local realOverlayUpdate = MDADOverlay.update
    MDADOverlay.update = function(pn, s, ...)
        if pn == 0 then captured = s end
        return realOverlayUpdate(pn, s, ...)
    end

    setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
        AutoDriveMaxSpeed = 40, RightLaneBias = 0 })
    installNavApi(4)
    drive.nav.tx, drive.nav.ty, drive.nav.state = 300, 0, "ok"
    drive.nav.route = v4Route("paved", 10)
    drive.fillWorld(-2, 170, -9, 9)
    drive.putRoad(-2, 170, -9, 9)
    driveReset(hotVeh)
    checkTrue(MDAD.Drive.start(dp), "aligned v4 route starts")
    local massStart = drive.calls.getMass
    local engineStart = drive.calls.getEnginePower
    local brakeStart = drive.calls.getBrakingForce
    local tireStart = drive.calls.getWheelFriction
    local partStart = drive.calls.getPartById
    for _ = 1, 10 do driveTick(dp, hotVeh) end
    checkEq(drive.calls.getMass, massStart, "N hot frames do not reread mass")
    checkEq(drive.calls.getEnginePower, engineStart, "N hot frames do not reread enginePower")
    checkEq(drive.calls.getBrakingForce, brakeStart, "N hot frames do not reread brakingForce")
    checkEq(drive.calls.getWheelFriction, tireStart, "N hot frames do not reread tire friction")
    checkEq(drive.calls.getPartById, partStart, "N hot frames do not enumerate tires")
    nowMs = nowMs + 999
    driveTick(dp, hotVeh)
    checkEq(drive.calls.getMass, massStart, "mass remains cached before 1 second")
    nowMs = nowMs + 1
    driveTick(dp, hotVeh)
    checkEq(drive.calls.getMass, massStart + 1, "1 second boundary performs one finite mass refresh")
    checkEq(drive.calls.getEnginePower, engineStart, "mass refresh does not reread enginePower")
    checkEq(drive.calls.getBrakingForce, brakeStart, "mass refresh does not reread brakingForce")
    checkEq(drive.calls.getWheelFriction, tireStart, "mass refresh does not reread tires")

    hotVeh._x, hotVeh._y, hotVeh._speed = 0, 0, 20
    setHeading(hotVeh, 0)
    drive.scanRound()
    checkEq(type(captured), "table", "completed sensor round exposes active session to overlay")
    local cachedMass = captured.runtimeMass
    local cachedAccel = captured.profile.segAccel[1]
    hotVeh._mass = cachedMass + 0.5
    nowMs = nowMs + 1000
    driveTick(dp, hotVeh)
    checkEq(captured.runtimeMass, cachedMass,
        "sub-threshold modded mass jitter does not move the retained baseline")
    checkNear(captured.profile.segAccel[1], cachedAccel, 1e-12,
        "sub-threshold mass jitter does not dirty/rebuild dynamics")
    hotVeh._mass = cachedMass + 6
    nowMs = nowMs + 1000
    captured.horizonStamp = captured.sensor.stamp
    captured.horizonMinBrake = captured.safeBrake
    driveTick(dp, hotVeh)
    driveTick(dp, hotVeh)
    checkEq(captured.horizonStamp, -1,
        "non-material mass rebuild invalidates snapshot horizon stamp")
    checkEq(captured.horizonMinBrake, 0,
        "non-material mass rebuild clears stale horizon minima")
    checkEq(captured.runtimeMass, cachedMass + 6,
        "accumulated delta at 0.5 percent threshold refreshes runtime mass")
    checkTrue(captured.profile.segAccel[1] < cachedAccel,
        "threshold-crossing mass refresh rebuilds conservative segment dynamics")
    checkEq(captured.navVersion, 4, "Driver records nav v4")
    checkEq(captured.currentSurfaceId, MDADFollower.SURFACE_PAVED,
        "Driver records current declared surface")
    checkEq(captured.currentSegWidth, 10, "Driver records current segment width")
    checkEq(MDAD.Drive.controlState(0), "TRACK", "derived control state is TRACK")
    captured.blocked, captured.returnActive = true, true
    checkEq(MDAD.Drive.controlState(0), "RETURN", "RETURN outranks planned blocked")
    captured.currentBlocked = true
    checkEq(MDAD.Drive.controlState(0), "HOLD", "current contact HOLD outranks RETURN")
    captured.currentBlocked, captured.blocked, captured.returnActive = false, false, false
    captured.dodging = true
    checkEq(MDAD.Drive.controlState(0), "AVOID", "dodge derives AVOID")
    captured.dodging, captured.mode = false, "recover"
    checkEq(MDAD.Drive.controlState(0), "RECOVER", "recovery mode derives RECOVER")
    captured.mode = "follow"
    captured.returnActive, captured.returnHold = true, true
    checkEq(MDAD.Drive.controlState(0), "HOLD", "returnHold outranks derived RETURN")
    captured.returnActive, captured.returnHold = false, false
    local baseRoute = drive.nav.route
    local penalized = v4Route("paved", 10)
    penalized.avoidPenalty = 5
    drive.nav.detourRoute = penalized
    drive.nav.detourCalls = 0
    captured.blocked, captured.detourTried = true, false
    captured.waitSince = nowMs - 5000
    captured.blockHitX, captured.blockHitY = 20, 0
    driveTick(dp, hotVeh)
    checkEq(drive.nav.detourCalls, 1, "v4 positive avoidPenalty detour is evaluated")
    checkEq(captured.pendingRouteWhy, nil, "v4 positive avoidPenalty is rejected")
    drive.nav.route = baseRoute
    captured.nextRouteMs = nowMs + 250
    local cleanDetour = v4Route("paved", 10)
    drive.nav.detourRoute = cleanDetour
    captured.detourTried, captured.waitSince = false, nowMs - 5000
    driveTick(dp, hotVeh)
    checkEq(captured.pendingRouteWhy, "detour", "v4 numeric avoidPenalty zero is accepted")
    drive.nav.route, drive.nav.detourRoute = baseRoute, nil
    captured.pendingRouteWhy, captured.blocked = nil, false
    captured.forceBrakeUntil = 0
    captured.waitSince, captured.nextRouteMs = 0, nowMs + 250
    captured.nextDynamicsMs = nowMs + 10000
    captured.dynamicsDirty, captured.mode = false, "follow"
    captured.tractionKey = captured.currentSurfaceId
        + (captured.rain ~= false and 4 or 0)
        + (captured.physicalOffroad and 32 or 0)
    captured.kinPrevMs, captured.kinPrevV, captured.kinPrevH =
        nowMs - 100, hotVeh._speed / 3.6, 0
    captured.forceBrakePrev, captured.regulatorPrev = false, true
    captured.targetPrev = 40
    for _ = 1, 6 do
        nowMs = nowMs + 100
        hotVeh._x = hotVeh._x + hotVeh._speed / 36
        driveTick(dp, hotVeh)
    end
    checkTrue(captured.accelTime > 0, "stable TRACK regulator samples accumulate EWMA time")
    local accelTimeBeforeCoast = captured.accelTime
    captured.coastMean, captured.coastDev, captured.coastTime = 0, 0, 0
    captured.coastConfidence, captured.coastLower = 0, 0
    captured.kinPrevMs, captured.kinPrevV, captured.kinPrevH =
        nowMs - 100, hotVeh._speed / 3.6 + 0.01, 0
    captured.forceBrakeUntil, captured.ewmaSuppressUntil = 0, 0
    captured.forceBrakePrev, captured.regulatorPrev = false, true
    captured.targetPrev = hotVeh._speed
    captured.nextDynamicsMs = nowMs + 10000
    driveTick(dp, hotVeh)
    checkTrue(captured.coastTime > 0,
        "regulator-on target at/below actual speed records loosened-throttle coast")
    checkNear(captured.accelTime, accelTimeBeforeCoast, 1e-12,
        "loosened regulator frame is not misclassified as acceleration")
    checkTrue(captured.safeCoast < captured.priorCoast,
        "weak observed coast immediately tightens safeCoast")
    captured.coastMean, captured.coastDev, captured.coastTime = 0, 0, 0
    captured.coastConfidence, captured.coastLower = 0, 0
    captured.safeCoast = captured.priorCoast
    MDADFollower.setRuntimeLimits(captured.fstate, captured.safeAccel,
        captured.safeBrake, captured.safeLat, captured.safeCoast)
    captured.brakeLower, captured.brakeConfidence, captured.brakeTime = 1, 1, 20
    captured.nextDynamicsMs = nowMs
    driveTick(dp, hotVeh) -- schedules material full-profile rebuild
    driveTick(dp, hotVeh) -- applies configure -> min safe -> invalidate/build
    checkEq(captured.horizonStamp, -1,
        "material rebuild invalidates completed-snapshot horizon cache")
    checkEq(captured.horizonMinBrake, 0,
        "material rebuild clears stale cached brake minimum")
    for _ = 1, 8 do driveTick(dp, hotVeh) end
    checkEq(captured.mode, "follow",
        "material profile finishes rebuilding before same-profile safe-drop probe")
    local rebuiltBrake = captured.dynamicsBrakeCap
    checkTrue(rebuiltBrake <= 1 and captured.profile.segBrake[39] <= rebuiltBrake,
        "material EWMA lower bound rebuilds the full multi-segment brake envelope")
    local beforeThrottle = captured.profile.segBrake[1]
    captured.brakeLower, captured.brakeConfidence, captured.brakeTime =
        beforeThrottle * 0.5, 1, 20
    captured.nextDynamicsMs = nowMs + 1000
    captured.forceBrakePrev, captured.regulatorPrev, captured.targetPrev = false, true, 40
    captured.horizonStamp = captured.sensor.stamp
    captured.horizonMinBrake = beforeThrottle
    driveTick(dp, hotVeh)
    checkNear(captured.profile.segBrake[1], beforeThrottle, 1e-12,
        "material rebuild is throttled before the one-second boundary")
    checkTrue(captured.safeBrake < beforeThrottle,
        "safe brake drops immediately while stored profile is still high")
    checkTrue(captured.horizonMinBrake <= captured.safeBrake,
        "same-stamp horizon minimum is tightened by the immediate safe brake")
    nowMs = nowMs + 1000
    for _ = 1, 12 do driveTick(dp, hotVeh) end
    local tightenedBrake = captured.profile.segBrake[1]
    checkTrue(tightenedBrake < beforeThrottle,
        "material boundary rebuild commits the immediate lower brake evidence")
    captured.brakeLower, captured.brakeConfidence, captured.brakeTime =
        captured.priorBrake, 1, 20
    captured.nextDynamicsMs = nowMs
    driveTick(dp, hotVeh) -- schedule conservative recovery
    driveTick(dp, hotVeh) -- rebuild from prior, capped by recovered safe value
    for _ = 1, 8 do driveTick(dp, hotVeh) end
    checkTrue(captured.profile.segBrake[1] > tightenedBrake
            and captured.profile.segBrake[1] <= captured.priorBrake,
        "recovered material evidence rebuilds upward without exceeding the legacy prior")
    captured.nextDynamicsMs = nowMs + 10000
    local materialBrakeCap = captured.profile.segBrake[1]
    captured.rain = false
    captured.dynamicsDirty, captured.dynamicsCapMaterial = false, false
    for _ = 1, 4 do driveTick(dp, hotVeh) end
    checkTrue(captured.profile.segBrake[1] >= materialBrakeCap,
        "dry regime rebuild keeps the recovered prior instead of carrying a stale lower cap")
    drive.nav.route = v4Route("dirt", 8)
    nowMs = nowMs + 300
    captured.dynamicsDirty, captured.mode = false, "follow"
    captured.nextDynamicsMs = nowMs + 10000
    captured.tractionKey = -1
    captured.kinPrevMs = 0
    for _ = 1, 12 do
        if captured.tractionKey < 0 then driveTick(dp, hotVeh) end
    end
    checkTrue(captured.tractionKey >= 0
            and captured.tractionKey % 4 == captured.currentSurfaceId,
        "surface change installs a traction key whose low bits match dirt")
    checkEq(captured.accelTime, 0, "traction key change resets EWMA confidence window")

    hotVeh._offroad, hotVeh._x, hotVeh._y = true, 0, 0
    drive.fillWorld(-2, 170, -9, 9)
    for x = -2, 170 do
        for y = -9, 9 do
            drive.world[x * 100000 + y]._floor = {
                getSpriteName = function() return "blends_natural_01_20" end,
                hasProperty = function() return false end,
            }
        end
    end
    drive.scanRound()
    checkTrue(captured.physicalOffroad, "physical offroad is sampled once per snapshot")
    checkFalse(captured.returnActive, "declared dirt + physical offroad remains legal on-route")
    checkFalse(captured.surfaceMismatch, "dirt route cannot accumulate paved mismatch")
    captured.nextDynamicsMs = nowMs + 10000
    captured.dynamicsDirty, captured.mode = false, "follow"
    captured.nextDynamicsMs = nowMs + 10000
    captured.tractionKey = captured.currentSurfaceId
        + (captured.rain ~= false and 4 or 0) + 32
    captured.kinPrevMs, captured.kinPrevV, captured.kinPrevH =
        nowMs - 100, hotVeh._speed / 3.6, 0
    captured.forceBrakeUntil, captured.ewmaSuppressUntil = 0, 0
    captured.forceBrakePrev, captured.regulatorPrev = false, true
    captured.targetPrev = 40
    for _ = 1, 6 do
        nowMs = nowMs + 100
        hotVeh._x = hotVeh._x + hotVeh._speed / 36
        driveTick(dp, hotVeh)
    end
    checkTrue(captured.accelTime > 0,
        "declared dirt may learn its own traction key while physicalOffroad=true")

    MDAD.Drive.stop(0, nil)
    installNavApi(4)
    drive.nav.route = v4Route("paved", 10)
    driveReset(hotVeh)
    checkTrue(MDAD.Drive.start(dp), "paved/actual mismatch evidence fixture starts")
    for _ = 1, 30 do driveTick(dp, hotVeh) end
    checkFalse(captured.surfaceMismatch, "one mismatch snapshot is not continuous evidence")
    checkFalse(captured.returnActive, "physical offroad mismatch cannot trigger RETURN alone")
    drive.scanRound()
    checkTrue(captured.surfaceMismatch, "two known paved/actual mismatch snapshots latch evidence")
    checkFalse(captured.returnActive, "latDev is still required even after mismatch evidence")
    for _ = 1, 6 do
        nowMs = nowMs + 100
        hotVeh._x = hotVeh._x + hotVeh._speed / 36
        driveTick(dp, hotVeh)
    end
    checkEq(captured.accelTime, 0,
        "paved + known non-paved actual mismatch never contaminates paved EWMA")
    MDAD.Drive.stop(0, nil)

    installNavApi(4)
    drive.nav.route = v4Route("paved", 10)
    hotVeh._offroad, hotVeh._x, hotVeh._y = true, 0, 0
    drive.fillWorld(-2, 170, -9, 9) -- loaded but floor class unknown
    driveReset(hotVeh)
    checkTrue(MDAD.Drive.start(dp), "paved/unknown-actual learning fixture starts")
    for _ = 1, 4 do driveTick(dp, hotVeh) end
    drive.scanRound()
    checkEq(captured.sensor.actualSurfaceId, MDADSensor.SURFACE_UNKNOWN,
        "loaded floor without known class remains actual unknown")
    captured.dynamicsDirty, captured.mode = false, "follow"
    captured.nextDynamicsMs = nowMs + 10000
    captured.tractionKey = captured.currentSurfaceId
        + (captured.rain ~= false and 4 or 0) + 32
    captured.kinPrevMs, captured.kinPrevV, captured.kinPrevH =
        nowMs - 100, hotVeh._speed / 3.6, 0
    captured.forceBrakePrev, captured.regulatorPrev = false, true
    captured.targetPrev = 40
    captured.nextDynamicsMs = nowMs + 10000
    for _ = 1, 6 do
        nowMs = nowMs + 100
        hotVeh._x = hotVeh._x + hotVeh._speed / 36
        driveTick(dp, hotVeh)
    end
    checkTrue(MDAD.Drive.isActive(0),
        "actual unknown does not decide mismatch or disable paved-key control")
    checkTrue(captured.tractionKey >= 32,
        "physicalOffroad participates in the traction key")
    checkTrue(captured.safeAccel <= captured.priorAccel
            and captured.safeBrake <= captured.priorBrake
            and captured.safeLat <= captured.priorLat,
        "EWMA safe limits never exceed their priors")
    checkFalse(captured.surfaceMismatch, "actual unknown never latches paved mismatch")
    checkFalse(captured.returnActive, "physical offroad + actual unknown cannot trigger RETURN")
    MDAD.Drive.stop(0, nil)
    installNavApi(3)
    drive.nav.route = newRoute(40, 0, 0, 4, 0)
    driveReset(hotVeh)
    checkTrue(MDAD.Drive.start(dp), "genuine v3 basic following starts")
    for _ = 1, 4 do driveTick(dp, hotVeh) end
    drive.scanRound()
    checkEq(captured.sensor.actualSurfaceId, MDADSensor.SURFACE_UNKNOWN,
        "v3 fixture keeps actual floor unknown")
    checkEq(captured.currentSurfaceId, MDADFollower.SURFACE_UNKNOWN,
        "v3 current surface is explicit unknown")
    checkFalse(captured.returnActive, "v3 unknown never RETURNs from physical offroad alone")

    MDAD.Drive.stop(0, nil)
    installNavApi(4)
    drive.nav.route = v4Route("paved", 10)
    hotVeh._offroad, hotVeh._x, hotVeh._y = false, 0, 4
    drive.fillWorld(-10, 170, -15, 15)
    drive.putRoad(-10, 170, -15, 15)
    driveReset(hotVeh)
    checkTrue(MDAD.Drive.start(dp), "RETURN exact-line fixture starts")
    for _ = 1, 4 do driveTick(dp, hotVeh) end
    drive.putSolid(-1, 2, "return_near_lateral")
    drive.scanRound(true)
    checkTrue(captured.returnActive and captured.returnUnsafe,
        "near lateral union blocks diagonal RETURN commit")
    checkFalse(captured.fstate.exactLine,
        "near lateral obstacle cannot be hidden behind the route scan start")
    drive.clearCell(-1, 2)
    drive.scanRound(true)
    checkFalse(captured.returnUnsafe, "clear near lateral snapshot commits RETURN line")
    checkEq(MDAD.Drive.controlState(0), "RETURN", "derived state reports RETURN")
    checkTrue(captured.fstate.exactLine, "Follower is consuming an exact world line")
    checkTrue(captured.fstate.ovX == captured.returnX
            and captured.fstate.ovY == captured.returnY,
        "Follower and long-vehicle OBB sweep share the identical preallocated arrays")
    local exactSpan = (captured.fstate.ovN - 1) * MDADFollower.OV_STEP
    local requiredTail = 18 * captured.profile.lookScale
        + captured.vehicleProfile.halfL
    checkTrue(exactSpan >= captured.returnEndS - captured.returnStartS + requiredTail,
        "RETURN exact line retains max-lookahead plus body tail")
    local nominalHalfL = captured.vehicleProfile.halfL
    captured.vehicleProfile.halfL = 20
    drive.scanRound(true)
    checkTrue(captured.returnUnsafe,
        "long halfL + nonzero comX invalidates the completed-band diagonal proof")
    checkTrue(captured.returnHold,
        "long halfL remains HOLD when no separately proved fallback fits the snapshot")
    checkFalse(captured.fstate.exactLine,
        "long halfL completed-band failure cannot fall back to raw laneBias")
    captured.vehicleProfile.halfL = nominalHalfL
    drive.scanRound(true)
    checkTrue(captured.fstate.exactLine and not captured.returnCrawlExact,
        "restored body footprint permits the full exact RETURN line on the same completed band")
    drive.keys.Forward = true
    driveTick(dp, hotVeh)
    drive.keys.Forward = false
    driveTick(dp, hotVeh) -- arm clean-since after releasing manual input
    nowMs = nowMs + 2001
    driveTick(dp, hotVeh)
    checkTrue(captured.returnActive and captured.returnHold
            and not captured.fstate.exactLine and captured.sensor.stamp == 0,
        "yield reset invalidates full exact RETURN until a fresh snapshot")
    drive.scanRound(true)
    checkTrue(captured.fstate.exactLine and not captured.returnCrawlExact,
        "fresh snapshot recommits full RETURN after yield reset")
    local mid = captured.fstate.ovN - captured.fstate.ovN % 2
    mid = mid / 2
    local guardX = math.floor(captured.returnX[mid])
    local guardY = math.floor(captured.returnY[mid])
    drive.putSolid(guardX, guardY, "return_guard_obstacle")
    captured.blocked = true
    drive.scanRound(true)
    checkTrue(captured.returnUnsafe, "fresh obstacle invalidates committed RETURN line")
    checkTrue(captured.returnCrawlExact and captured.fstate.exactLine,
        "invalidated diagonal switches to the separately swept exact parallel line")
    checkTrue(captured.blocked, "unsafe RETURN does not erase the planned blocker")
    checkEq(captured.mode, "follow", "RETURN guard never jumps directly to RECOVER")
    checkEq(MDAD.Drive.controlState(0), "RETURN",
        "unsafe guard remains RETURN while holding current parallel lane")
    drive.clearCell(guardX, guardY)
    drive.scanRound(true)
    checkTrue(captured.fstate.exactLine, "next clear snapshot recommits an exact RETURN line")

    local savedColumn = {}
    for y = -15, 15 do
        local key = guardX * 100000 + y
        savedColumn[y] = drive.world[key]
        drive.world[key] = nil
    end
    drive.scanRound(true)
    checkTrue(captured.returnUnsafe, "fresh unloaded coverage invalidates committed RETURN line")
    checkTrue(captured.returnCrawlExact and captured.fstate.exactLine,
        "unloaded full line switches to the swept exact constant-lane proof")
    checkEq(captured.mode, "follow", "unloaded guard also leaves escalation to supervisor")
    checkEq(MDAD.Drive.controlState(0), "RETURN",
        "far unloaded full line may crawl only after near current-lane proof")
    driveReset(hotVeh)
    driveTick(dp, hotVeh)
    checkTrue(drive.calls.maxRegSpeed > 0 and drive.calls.maxRegSpeed <= 8,
        "proven current-lane stopping horizon never exceeds bounded 8 km/h crawl")
    drive.keys.Forward = true
    driveTick(dp, hotVeh)
    drive.keys.Forward = false
    driveTick(dp, hotVeh) -- arm clean-since after releasing manual input
    nowMs = nowMs + 2001
    driveTick(dp, hotVeh)
    checkTrue(captured.returnHold and not captured.fstate.exactLine
            and not captured.returnCrawlExact and captured.sensor.stamp == 0,
        "yield reset invalidates crawl exact RETURN until a fresh snapshot")
    drive.scanRound(true)
    checkTrue(captured.returnCrawlExact and captured.fstate.exactLine,
        "fresh snapshot recommits guarded crawl exact after yield reset")
    for y = -15, 15 do drive.world[guardX * 100000 + y] = savedColumn[y] end

    MDAD.Drive.stop(0, nil)
    drive.nav.route = v4Route("paved", 10)
    hotVeh._x, hotVeh._y, hotVeh._speed = 0, 7, 20
    drive.fillWorld(-10, 170, -20, 20)
    drive.putRoad(-10, 170, -20, 20)
    driveReset(hotVeh)
    checkTrue(MDAD.Drive.start(dp), "delta7 streaming crawl fixture starts")
    drive.putSolid(5, 7, "delta7_old_band_obstacle")
    for _ = 1, 4 do driveTick(dp, hotVeh) end
    drive.scanRound(true)
    checkTrue(captured.returnHold and not captured.fstate.exactLine,
        "old completed band cannot authorize delta7 crawl")
    drive.scanRound(true)
    checkTrue(captured.returnHold and not captured.fstate.exactLine,
        "fresh midpoint band sees the old-band-exterior obstacle")
    drive.clearCell(5, 7)
    drive.scanRound(true)
    checkTrue(captured.returnUnsafe and not captured.returnHold,
        "fresh midpoint band can authorize current-lane crawl after obstacle clears")
    checkTrue(captured.returnCrawlExact and captured.fstate.exactLine,
        "delta7 crawl follows its guarded exact parallel line")
    driveReset(hotVeh)
    driveTick(dp, hotVeh)
    checkTrue(drive.calls.maxRegSpeed > 0 and drive.calls.maxRegSpeed <= 8,
        "delta7 streaming crawl ramps smoothly but never exceeds 8")
    captured.sensor.aheadM = 80
    drive.scanRound(true)
    checkTrue(captured.returnHold and not captured.fstate.exactLine,
        "full transition waits for a fresh midpoint band after crawl")
    drive.scanRound(true)
    checkTrue(captured.fstate.exactLine and not captured.returnCrawlExact,
        "fresh midpoint band plus expanded coverage commits the full exact line")
    MDAD.Drive.stop(0, nil)
    local longRoute = newRoute(400, 0, 0, 4, 0)
    longRoute.segSurface, longRoute.segWidth = {}, {}
    for i = 1, 399 do
        longRoute.segSurface[i], longRoute.segWidth[i] = "paved", 10
    end
    drive.nav.route = longRoute
    hotVeh._x, hotVeh._y, hotVeh._speed = 1200, 4, 20
    drive.fillWorld(1170, 1370, -15, 15)
    drive.putRoad(1170, 1370, -15, 15)
    driveReset(hotVeh)
    checkTrue(MDAD.Drive.start(dp), "long-route late-index RETURN fixture starts")
    for _ = 1, 50 do driveTick(dp, hotVeh) end
    checkTrue(captured.fstate.idx > 250, "long-route follower is tracking a late segment")
    for _ = 1, 3 do drive.scanRound(true) end
    checkTrue(captured.fstate.exactLine, "late-index fixture commits an exact RETURN line")
    local realRouteS = captured.profile.s
    local sReads, minSRead = 0, 1000000
    captured.profile.s = setmetatable({}, {
        __index = function(_, i)
            sReads = sReads + 1
            if type(i) == "number" and i < minSRead then minSRead = i end
            return realRouteS[i]
        end,
    })
    drive.scanRound(true)
    captured.profile.s = realRouteS
    checkTrue(minSRead > 250,
        "late-index snapshot never walks profile.s from the route prefix")
    checkTrue(sReads < 1500,
        "late-index snapshot reads remain bounded by local horizons; reads=" .. sReads)
    MDAD.Drive.stop(0, nil)

    drive.nav.route = v4Route("paved", 10)
    hotVeh._x, hotVeh._y, hotVeh._speed = 0, 7, 8
    drive.fillWorld(-10, 170, -20, 20)
    drive.putRoad(-10, 170, -20, 20)
    for x = -4, 4 do
        for y = -12, 12 do drive.world[x * 100000 + y] = nil end
    end
    driveReset(hotVeh)
    checkTrue(MDAD.Drive.start(dp), "near-unloaded HOLD timeout fixture starts")
    for _ = 1, 4 do driveTick(dp, hotVeh) end
    drive.scanRound(true)
    checkTrue(captured.returnHold, "near current-lane unknown cannot crawl")
    for _, speed in ipairs({ 8, 15 }) do
        hotVeh._speed = speed
        driveReset(hotVeh)
        driveTick(dp, hotVeh)
        checkTrue(drive.calls.forceBrake > 0,
            "RETURN HOLD force-brakes at " .. speed .. " km/h")
        checkEq(drive.calls.regulatorOn, 0,
            "RETURN HOLD never enables regulator at " .. speed .. " km/h")
    end
    checkTrue(captured.forceBrakeUntil > nowMs,
        "forceBrake command records the whole 1s effective window")
    captured.returnActive, captured.returnHold = false, false
    captured.sensor.ready, captured.sensor.unloaded = true, false
    captured.tractionKey = captured.currentSurfaceId
        + (captured.rain ~= false and 4 or 0)
    captured.kinPrevMs, captured.kinPrevV, captured.kinPrevH =
        nowMs - 100, hotVeh._speed / 3.6, 0
    captured.lastLatDev, captured.lastHeadingError = 0, 0
    captured.forceBrakePrev, captured.regulatorPrev = false, true
    captured.targetPrev = 40
    captured.accelTime, captured.coastTime, captured.brakeTime = 0, 0, 0
    nowMs = nowMs + 100
    driveTick(dp, hotVeh)
    checkTrue(captured.brakeTime > 0
            and captured.accelTime == 0 and captured.coastTime == 0,
        "forceBrake effective window classifies brake and excludes accel/coast")
    captured.accelTime, captured.coastTime, captured.brakeTime = 0, 0, 0
    captured.ewmaSuppressUntil = captured.forceBrakeUntil
    captured.kinPrevMs, captured.kinPrevV, captured.kinPrevH =
        nowMs - 100, hotVeh._speed / 3.6, 0
    captured.forceBrakePrev, captured.regulatorPrev, captured.targetPrev =
        false, true, 40
    nowMs = nowMs + 100
    driveTick(dp, hotVeh)
    checkTrue(captured.brakeTime == 0 and captured.accelTime == 0
            and captured.coastTime == 0,
        "epoch reset suppresses the old native brake window from contaminating new key")
    captured.returnActive, captured.returnHold = true, true
    captured.sensor.unloaded = true
    hotVeh._speed = 0
    driveReset(hotVeh)
    driveTick(dp, hotVeh)
    nowMs = nowMs + 20001
    driveReset(hotVeh)
    driveTick(dp, hotVeh)
    checkFalse(MDAD.Drive.isActive(0), "near-unloaded HOLD exits through visible wait timeout")
    checkEq(haloKey(), DKEY.STUCK, "near-unloaded timeout reports stuck")
    drive.nav.route = v4Route("paved", 10)
    hotVeh._x, hotVeh._y, hotVeh._speed, hotVeh._offroad = 0, 30, 20, false
    drive.fillWorld(-10, 170, -50, 50)
    drive.putRoad(-10, 170, -50, 50)
    driveReset(hotVeh)
    checkTrue(MDAD.Drive.start(dp), "oversize RETURN capacity fixture starts")
    for _ = 1, 4 do driveTick(dp, hotVeh) end
    drive.scanRound(true)
    checkTrue(captured.returnActive and captured.returnUnsafe and captured.returnHold,
        "RETURN beyond fixed sample capacity enters deterministic HOLD")
    checkFalse(captured.fstate.exactLine,
        "oversize RETURN never commits a truncated exact line")
    checkEq(MDAD.Drive.controlState(0), "HOLD", "capacity fault derives HOLD")
    hotVeh._speed, hotVeh._stopped = 0, true
    driveReset(hotVeh)
    driveTick(dp, hotVeh)
    checkFalse(MDAD.Drive.isActive(0),
        "capacity fault visibly fail-stops once the vehicle is settled")
    checkEq(haloKey(), DKEY.STUCK, "capacity fault uses visible stuck fail-stop")
    hotVeh._stopped = false
    setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
        AutoDriveMaxSpeed = 40, ObstaclePolicy = 1, RightLaneBias = 0 })
    drive.nav.route = v4Route("paved", 10)
    hotVeh._x, hotVeh._y, hotVeh._speed = 0, 0, 0
    setHeading(hotVeh, 0)
    drive.fillWorld(-10, 170, -20, 20)
    drive.putRoad(-10, 170, -20, 20)
    drive.putSolid(30, 0, "zero_speed_large_shift")
    driveReset(hotVeh)
    checkTrue(MDAD.Drive.start(dp), "zero-speed intended-dodge fixture starts")
    for _ = 1, 6 do driveTick(dp, hotVeh) end
    drive.scanRound(true)
    checkTrue(captured.dodging,
        "zero current speed with ample space can commit a large lateral shift")
    checkTrue(captured.dodgeDesignSpeed >= MDADDynamics.DODGE_SQUEEZE_CAP
            and captured.dodgeShiftLength > 2 * captured.vehicleProfile.halfL,
        "dodge geometry uses intended crawl-or-higher speed, not current zero")
    checkTrue(captured.dodgeSpaceCap > 0,
        "available entry/exit space yields a positive inverse speed cap")
    checkNear(captured.lastOvEndS, captured.fstate.ovEndS, 1e-12,
        "candidate sweep and committed dodge share the exact ovEndS")
    checkNear(captured.fstate.ovEndS, captured.fstate.offD + 1, 1e-9,
        "committed dodge endpoint is the true d+1 arclength")
    do
        local baseCap = captured.dodgeBaseCap
        local realVisibilityCap = MDADDynamics.visibilityCapKmh
        MDADDynamics.visibilityCapKmh = function() return 0 end
        drive.scanRound(true)
        checkTrue(captured.dodging and captured.dodgeCapPending
                and captured.dodgeSpeedCap == 0,
            "fresh transient zero cap holds the immutable dodge without destroying it")
        MDADDynamics.visibilityCapKmh = realVisibilityCap
        drive.scanRound(true)
        checkTrue(captured.dodging and not captured.dodgeCapPending
                and not captured.blocked and captured.dodgeSpeedCap > 0
                and captured.dodgeSpeedCap <= baseCap,
            "next fresh positive proof restores speed from immutable base cap")
    end
    driveReset(hotVeh)
    for _ = 1, 10 do driveTick(dp, hotVeh) end
    checkTrue(drive.calls.maxRegSpeed > 0,
        "committed zero-speed dodge is allowed to accelerate")
    drive.clearCell(30, 0)
    MDAD.Drive.stop(0, nil)
    drive.nav.route = v4CurveRoute(45)
    hotVeh._x, hotVeh._y, hotVeh._speed = 0, 0, 30
    setHeading(hotVeh, 0)
    drive.fillWorld(-10, 180, -20, 180)
    drive.putRoad(-10, 180, -20, 180)
    driveReset(hotVeh)
    setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
        AutoDriveMaxSpeed = 40, RightLaneBias = 1 })
    checkTrue(MDAD.Drive.start(dp), "v4 actual-lane curve envelope fixture starts")
    for _ = 1, 6 do driveTick(dp, hotVeh) end
    drive.scanRound(true)
    checkEq(captured.verifyLineReason, "ok",
        "actual-lane curve proof passes continuous road-band and world sweep")
    checkTrue(captured.laneCurveEnvelope > 0 and captured.laneCurveEnvelope < 40,
        "future actual-lane curve builds a soft coast envelope below cruise")
    checkFalse(captured.curveHardActive,
        "straight approach to future curve does not arm current hard curvature")
    driveReset(hotVeh)
    driveTick(dp, hotVeh)
    checkEq(drive.calls.forceBrake, 0,
        "straight approach coasts for future actual-lane curve without forceBrake")
    local curveStamp = captured.sensor.stamp
    local coastCap0 = captured.laneCurveEnvelope
    hotVeh._x, hotVeh._y, hotVeh._speed = 10, 0, 10
    setHeading(hotVeh, 0)
    driveReset(hotVeh)
    driveTick(dp, hotVeh)
    local coastCap10 = captured.laneCurveEnvelope
    checkEq(captured.sensor.stamp, curveStamp,
        "10m approach remains on the same completed snapshot")
    checkEq(drive.calls.forceBrake, 0,
        "same-snapshot 10m approach remains soft coast only")
    hotVeh._x = 20
    driveReset(hotVeh)
    driveTick(dp, hotVeh)
    local coastCap20 = captured.laneCurveEnvelope
    checkEq(captured.sensor.stamp, curveStamp,
        "20m approach remains on the same completed snapshot")
    checkTrue(coastCap10 <= coastCap0 + 1e-9
            and coastCap20 <= coastCap10 + 1e-9 and coastCap20 < coastCap0,
        "same-snapshot effective lane cap monotonically drops toward the curve")
    checkEq(drive.calls.forceBrake, 0,
        "same-snapshot 20m approach never turns future curvature into hard brake")
    local cachedEnvelopeSlot = captured.verifyEnvelope[1]
    local buildLat, buildCoast =
        captured.envelopeBuildLat, captured.envelopeBuildCoast
    local effectiveBeforeScale = captured.laneCurveEnvelope
    captured.yawLower, captured.yawConfidence, captured.yawTime =
        buildLat * 0.25, 1, 20
    captured.coastLower, captured.coastConfidence, captured.coastTime =
        buildCoast * 0.25, 1, 20
    captured.ewmaSuppressUntil = nowMs + 1000
    captured.nextDynamicsMs = nowMs + 10000
    driveReset(hotVeh)
    driveTick(dp, hotVeh)
    local scaledEnvelope = captured.laneCurveEnvelope
    checkNear(captured.verifyEnvelope[1], cachedEnvelopeSlot, 1e-12,
        "small EWMA tightening never rebuilds the 128-point cached envelope")
    checkTrue(captured.laneEnvelopeScale < 1 and scaledEnvelope < effectiveBeforeScale,
        "per-frame safeLat/safeCoast tightening applies conservative O(1) scale")
    local heldScale = captured.laneEnvelopeScale
    captured.yawLower, captured.yawConfidence = captured.priorLat, 1
    captured.coastLower, captured.coastConfidence = captured.priorCoast, 1
    driveReset(hotVeh)
    driveTick(dp, hotVeh)
    checkNear(captured.laneEnvelopeScale, heldScale, 1e-12,
        "same-snapshot safe increase never raises the cached envelope")
    checkTrue(captured.laneCurveEnvelope <= scaledEnvelope + 1e-9,
        "same-position effective cap remains conservative until a new snapshot")
    captured.ewmaSuppressUntil = 0

    local firstCurveSeg = nil
    for i = 1, captured.profile.n - 1 do
        if captured.profile.segKind[i] == MDADDynamics.SEG_ARC then
            firstCurveSeg = i
            break
        end
    end
    checkTrue(firstCurveSeg ~= nil, "v4 curve fixture exposes a current SEG_ARC")
    if firstCurveSeg then
    captured.fstate.idx = firstCurveSeg
    hotVeh._x = (captured.profile.x[firstCurveSeg]
        + captured.profile.x[firstCurveSeg + 1]) * 0.5
    hotVeh._y = (captured.profile.y[firstCurveSeg]
        + captured.profile.y[firstCurveSeg + 1]) * 0.5
    hotVeh._speed = 10
    setHeading(hotVeh, captured.profile.segH[firstCurveSeg])
    drive.scanRound(true)
    local currentCurveCap = captured.curveCap
    hotVeh._speed = currentCurveCap + 5
    driveReset(hotVeh)
    driveTick(dp, hotVeh)
    checkTrue(captured.curveHardActive and captured.curveKappa > 0,
        "inside actual-lane arc arms current hard curvature")
    checkEq(drive.calls.forceBrake, 1,
        "current arc actual-speed breach force-brakes")
    end
    MDAD.Drive.stop(0, nil)
    setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
        AutoDriveMaxSpeed = 40, RightLaneBias = 0 })
    drive.nav.route = v4Route("paved", 10)
    drive.nav.route.segWidth[39] = nil
    driveReset(hotVeh)
    checkFalse(MDAD.Drive.start(dp), "malformed v4 metadata fail-stops startup")
    checkEq(haloKey(), DKEY.ROUTE, "malformed v4 reports route unavailable")

    local zeroBrakeVeh = newVehicle({
        battery = newItem("Base.CarBattery", { uses = 0.8 }),
        engineRunning = true, mass = 1200, speed = 0, maxSpeed = 90,
        bodyW = 2.0, bodyL = 5.2, profileFull = true, brakingForce = 0,
    })
    dveh = zeroBrakeVeh
    zeroBrakeVeh._driver, dp._vehicle = dp, zeroBrakeVeh
    drive.nav.route = v4Route("paved", 10)
    driveReset(zeroBrakeVeh)
    checkFalse(MDAD.Drive.start(dp), "finite zero brakingForce rejects startup")
    checkEq(haloKey(), DKEY.UNSUPPORTED, "zero brakingForce reports unsupported vehicle")

    dveh = oldVeh
    oldVeh._driver, dp._vehicle = dp, oldVeh
    driveReset(oldVeh)
    checkTrue(MDAD.Drive.start(dp), "nil brakingForce keeps legacy conservative fallback")
    MDAD.Drive.stop(0, nil)

    dveh = hotVeh
    hotVeh._driver, dp._vehicle = dp, hotVeh
    hotVeh._x, hotVeh._y, hotVeh._speed = 0, 0, 20
    driveReset(hotVeh)
    checkTrue(MDAD.Drive.start(dp), "learned-zero brake fault fixture starts")
    for _ = 1, 4 do driveTick(dp, hotVeh) end
    drive.scanRound()
    captured.tractionKey = captured.currentSurfaceId
        + (captured.rain ~= false and 4 or 0)
        + (captured.physicalOffroad and 32 or 0)
    captured.kinPrevMs, captured.kinPrevV, captured.kinPrevH =
        nowMs - 100, hotVeh._speed / 3.6, 0
    captured.lastLatDev, captured.lastHeadingError = 0, 0
    captured.brakeMean, captured.brakeDev, captured.brakeTime = 0, 0, 20
    captured.brakeConfidence, captured.brakeLower = 1, 0
    captured.forceBrakeUntil, captured.ewmaSuppressUntil = 0, 0
    driveReset(hotVeh)
    driveTick(dp, hotVeh)
    checkFalse(MDAD.Drive.isActive(0), "learned uncontrollable brake bound visibly stops")
    checkEq(haloKey(), DKEY.UNSUPPORTED, "learned zero brake reports unsupported vehicle")
    checkTrue(drive.calls.forceBrake >= 1,
        "uncontrollable brake fault still attempts narrow best-effort forceBrake")
    local savedSensor, savedCorridor = MDADSensor, MDADCorridor
    dveh = hotVeh
    hotVeh._driver, dp._vehicle = dp, hotVeh
    hotVeh._x, hotVeh._y, hotVeh._speed = 0, 20, 20
    setHeading(hotVeh, 0)
    drive.nav.route = v4Route("paved", 10)
    MDADSensor = nil
    driveReset(hotVeh)
    checkTrue(MDAD.Drive.start(dp), "missing Sensor keeps M3 startup available")
    for _ = 1, 4 do driveTick(dp, hotVeh) end
    checkFalse(captured.returnActive, "missing Sensor never enters RETURN")
    checkEq(MDAD.Drive.controlState(0), "TRACK",
        "missing Sensor + large latDev stays pure follower, not RETURN/HOLD")
    MDAD.Drive.stop(0, nil)
    MDADSensor = savedSensor

    MDADCorridor = nil
    driveReset(hotVeh)
    checkTrue(MDAD.Drive.start(dp), "missing Corridor keeps M3 startup available")
    for _ = 1, 4 do driveTick(dp, hotVeh) end
    drive.scanRound(true)
    checkFalse(captured.returnActive, "missing Corridor never enters RETURN after a fresh snapshot")
    checkFalse(captured.blocked, "missing Corridor snapshot does not turn optional M4 into HOLD")
    checkEq(MDAD.Drive.controlState(0), "TRACK",
        "missing Corridor + large latDev stays pure follower, not RETURN/HOLD")
    MDAD.Drive.stop(0, nil)
    MDADCorridor = savedCorridor
    MDADOverlay.update = realOverlayUpdate
    MDAD.Drive.stop(0, nil)
    dveh = oldVeh
    oldVeh._driver, dp._vehicle = dp, oldVeh
    installNavApi(2)
    drive.nav.route = newRoute(40, 0, 0, 4, 0)
    drive.fillWorld(-2, 70, -7, 7)
end
scenarioPhaseE()

-- =====================================================================
-- 情境二十九：理由鍵不得缺翻譯（鍵是 runtime 真的吐出來的，不是抄原始碼）
-- =====================================================================
local function scenarioReasonKeys()
scenario("理由鍵覆蓋：每個分支都跑到，且四語 UI.json 都有對應翻譯")

checkEq(type(MDAD), "table", "production MDAD.lua 真的載入了")
checkEq(type(MDAD_Recipe), "table", "production MDAD_Recipe.lua 真的載入了")
checkEq(type(ISAutoDriveDeviceAction), "table", "production TimedAction 真的載入了")
checkEq(type(MDADFollower), "table", "production MDAD_Follower.lua 真的載入了")
checkEq(type(MDAD.Drive), "table", "production client/MDAD_Driver.lua 真的載入了")
checkEq(MDAD.MOD_ID, MOD_ID, "MOD_ID 常數")
checkEq(MDAD.TYPE_GPS, GPS_T, "TYPE_GPS 與 items 腳本一致")
checkEq(MDAD.TYPE_AUTO, AUTO_T, "TYPE_AUTO 與 items 腳本一致")
checkEq(MDAD.TYPE_MANUAL, "MinidoracatAutoDrive.NavigationRepairManual",
    "TYPE_MANUAL 與 items 腳本一致")
-- 配方名是短名（兩個 craftRecipe 已在 module Base），與 items 的
-- MinidoracatAutoDrive.* full type 是不同的名字空間，混用會查不到配方
checkEq(MDAD.RECIPE_GPS, "CraftGPSNavigator", "GPS 配方短名（module Base）")
checkEq(MDAD.RECIPE_AUTO, "CraftAutopilotModule", "自駕配方短名（module Base）")
checkEq(MDAD.CMD_RECIPE_RESCAN, "RecipeRescan", "登入補學 command 常數")
checkEq(MDAD.CMD_DEVICE, "Device", "CMD_DEVICE 常數（client／server 共用的封包名）")
checkEq(MDAD.CMD_DEVICE_FAILED, "DeviceFailed", "CMD_DEVICE_FAILED 常數")
checkEq(MDAD.CMD_USAGE, "Usage", "Auto Usage command 常數")
checkEq(MDAD.CMD_NAV_USAGE, "NavUsage", "GPS NavUsage command 常數")
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
checkTrue(#(eventHandlers["OnTick"] or {}) > 0, "client 掛上 NavUsage 低頻 heartbeat")
checkTrue(#(eventHandlers["EveryOneMinute"] or {}) > 0, "server/SP 掛上電力消耗週期")
checkTrue(#(eventHandlers["OnFillContainer"] or {}) > 0, "loot 生成後掛上 Spawn* 政策過濾")
checkTrue(#(eventHandlers["OnPlayerUpdate"] or {}) > 0, "client/MDAD_Driver.lua 掛上了 OnPlayerUpdate")

-- 自駕的向量池絆線：所有情境跑完，BaseVehicle 的池必須是空的。
-- 漏一顆 releaseVector3f 在遊戲裡的表徵是「開久了就沒有轉向」，沒有任何錯誤訊息。
checkEq(drive.pool.live, 0, "全程沒有任何池向量沒還（allocVector3f／releaseVector3f 成對）")
checkEq(drive.pool.bad, 0, "全程沒有 release 過不在手上的向量")

-- 距離判定的絆線：整份測試（含 apply／server／client 全鏈）都不該碰 DistToSquared
checkEq(distCalls, 0, "全程沒有任何程式碼呼叫 DistToSquared（距離 fallback 不得復活）")

-- 全域補學的絆線：本 MOD 只准補自己的兩個配方，一次登入把玩家沒接觸過的
-- 整包 MOD 配方全學走是不可逆的存檔污染，而且不會有任何錯誤訊息
checkEq(recipeWorld.globalScans, 0,
    "全程沒有呼叫 ScriptManager.checkAutoLearn（禁止全域補學）")

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
    "UI_MinidoracatAutoDrive_UnsupportedVehicle",
    "UI_MinidoracatAutoDrive_ManualOverride",
    "UI_MinidoracatAutoDrive_Arrived",
    "UI_MinidoracatAutoDrive_LostRoute",
    "UI_MinidoracatAutoDrive_Start",
    "UI_MinidoracatAutoDrive_Stop",
    "UI_MinidoracatAutoDrive_Detour",
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
end
scenarioReasonKeys()

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
