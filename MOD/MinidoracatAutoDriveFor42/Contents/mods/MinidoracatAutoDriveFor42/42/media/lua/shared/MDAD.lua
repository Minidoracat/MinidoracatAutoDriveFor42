-- MDAD.lua — AutoDrive runtime 共用常數／查詢／耗電／安裝突變（shared：SP 直接呼叫、MP 由 server 呼叫）
-- 命名空間 MDAD；配方 OnTest 走獨立全域 MDAD_Recipe，不在這裡。

MDAD = MDAD or {}

MDAD.MOD_ID = "MinidoracatAutoDriveFor42"
MDAD.TYPE_GPS = "MinidoracatAutoDrive.GPSNavigator"
MDAD.TYPE_AUTO = "MinidoracatAutoDrive.AutopilotModule"
-- 專屬雜誌：教兩個配方的維修手冊（一本教兩個短名）。戰利品注入與生成過濾都用
-- 這個 full type，不在 server/Items 那邊再抄一份字串。
MDAD.TYPE_MANUAL = "MinidoracatAutoDrive.NavigationRepairManual"
-- craftRecipe 的**短名**：兩個配方已移進 `module Base`，所以配方名不帶命名空間
-- 前綴（items 的 full type 仍是 MinidoracatAutoDrive.*，兩者是不同的名字空間）。
-- 配方名是 getScriptManager():getCraftRecipe 的鍵、也是 LearnedRecipes 與
-- Researchablerecipes 寫的值；登入補學（server/MDAD_Server.lua）就靠這兩個常數。
MDAD.RECIPE_GPS = "CraftGPSNavigator"
MDAD.RECIPE_AUTO = "CraftAutopilotModule"
-- build 印記：載入時印進 console（不受 getDebug 管），telemetry header 的 build 欄
-- 也帶它——實機回報「行為沒變」時第一件事就是對這行（2026-08-28 三場撞樹回報
-- 無法從 log 判定 code 版本的教訓）。值直接取 mod.info 的 modversion
-- （`getModInfoByID`＝LuaManager.java:5368 → ChooseGameInfo.getModDetails 檔案快取、
-- client／server 同源；`getModVersion`＝ChooseGameInfo.java:696；原版用例
-- ISPauseModListUI.lua:22、ModInfoPanelParam.lua:23）。舊制手寫常數十三次 REV
-- 都沒人 bump（m68-20260831a 掛到 0902m）——死印記比沒印記更誤導。
-- 開發期細粒度版本另看 telemetry header 的 rev（MDAD.Drive.REV）。
MDAD.BUILD = "unknown"
do
    -- API 缺席／info 為 nil 都在 pcall 內變成 error → 保持 "unknown"
    local ok, v = pcall(function() return getModInfoByID(MDAD.MOD_ID):getModVersion() end)
    if ok and type(v) == "string" and v ~= "" then MDAD.BUILD = v end
end
print("[MinidoracatAutoDrive] build " .. MDAD.BUILD)

-- client → server 的安裝／卸載請求（server/MDAD_Server.lua 收）與失敗回報
MDAD.CMD_DEVICE = "Device"
MDAD.CMD_DEVICE_FAILED = "DeviceFailed"
MDAD.CMD_USAGE = "Usage"
MDAD.CMD_NAV_USAGE = "NavUsage"
-- client 登入／分割畫面新 slot 上線時請伺服器替**該 actor** 重掃本 MOD 的兩個配方
-- （AutoLearnAny 只在升等瞬間與 SP 開局被檢查，MP 既有角色永遠補不上）。payload 空。
MDAD.CMD_RECIPE_RESCAN = "RecipeRescan"

MDAD.FAIL_GENERIC = "UI_MinidoracatAutoDrive_InstallFailed"
MDAD.FAIL_NO_BATTERY = "UI_MinidoracatAutoDrive_NoBattery"
MDAD.FAIL_TOO_FAR = "UI_MinidoracatAutoDrive_TooFar"

-- 裝置電力基準（電瓶 usedDelta／遊戲分鐘）與 fuel 原生實耗加成基準。
-- 四個 sandbox 百分比各自縮放；GPS＋自駕同時啟用時只相加一次。
MDAD.RATE_NAV = 0.00002
MDAD.RATE_AUTO = 0.0001
MDAD.FUEL_OVERHEAD_NAV = 0.05
MDAD.FUEL_OVERHEAD_AUTO = 0.25
MDAD.AUTO_USAGE_TTL_MS = 15000
MDAD.NAV_USAGE_TTL_MS = 15000

local GATE_REASON = "UI_MinidoracatAutoDrive_NeedGPS"
local GATE_TTL_MS = 1000

local function predicateNotBroken(item)
    return not item:isBroken()
end

local function predicateChargedGPS(item)
    return item:getCurrentUsesFloat() > 0
end

local function clamp01(n)
    if n < 0 then return 0 end
    if n > 1 then return 1 end
    return n
end

-- 讀 modData／物品電量時型別不保證（舊存檔、缺欄位），非數字一律當 0
local function clampDelta(n)
    if type(n) ~= "number" then return 0 end
    return clamp01(n)
end

-- id 邊界：Java 的 int/long 參數（getVehicleById＝LuaManager.java:10247、
-- ItemContainer.getItemWithIDRecursiv＝ItemContainer.java:3065）收到小數會被靜默截斷、
-- 收到 NaN／±Inf 會變成無意義的 id，兩者都不會報錯——偽造封包送來的欄位因此必須在
-- 進 Java 之前擋掉，否則「型別是 number」這一關等於沒擋。
-- `n * 0 ~= 0` 一次擋掉 NaN 與 ±Inf（有限數乘 0 必為 0，這兩者乘 0 都是 NaN），
-- 不用 math.huge（Kahlua 未保證提供）；再要求 floor 相等＝整數。
-- server（vehicleId）與 applyDeviceChange（itemId）共用同一份判定。
function MDAD.isFiniteInt(n)
    if type(n) ~= "number" then return false end
    if n * 0 ~= 0 then return false end
    return math.floor(n) == n
end


function MDAD.sandbox(name, default)
    local sb = SandboxVars and SandboxVars.MinidoracatAutoDrive
    local v = sb and sb[name]
    if v == nil then return default end
    return v
end

-- 三態減速政策（ZombieAreaSlowdown / CorpseSlowdown）：1=強制減速
-- 2=由玩家決定 3=強制關閉該項專屬減速。**tolerant 讀取**吸收兩類舊值：
--   boolean——ZombieAreaSlowdown 在 0.16.x 以前是 boolean，舊存檔的
--   _SandboxVars.lua 或 MP 舊伺服器仍會給 true/false：true（舊「會減速」）
--   映射 1、false（舊「全速輾」）映射 3，行為與升級前一致；
--   非法值（超界數字、字串、nil）——回 default（呼叫端一律傳 2）。
-- 引擎啟動正規化可能把舊 boolean 重設成 enum default（2＝玩家自選＋偏好
-- 預設開＝照樣減速），任何路徑都不會讓舊伺服器的行為靜默翻面。
MDAD.POLICY_FORCE_ON = 1
MDAD.POLICY_PLAYER = 2
MDAD.POLICY_FORCE_OFF = 3
function MDAD.policy3(name, default)
    local v = MDAD.sandbox(name, default)
    if v == true then return 1 end
    if v == false then return 3 end
    if v == 1 or v == 2 or v == 3 then return v end
    return default
end

local function percentScale(name)
    local v = MDAD.sandbox(name, 100)
    if type(v) ~= "number" or v ~= v then v = 100 end
    if v < 0 then v = 0 elseif v > 500 then v = 500 end
    return v / 100
end

function MDAD.powerScale(mode)
    if mode == "nav" then return percentScale("GPSPowerPercent") end
    if mode == "auto" then return percentScale("AutoDrivePowerPercent") end
    return nil
end

function MDAD.fuelScale(mode)
    if mode == "nav" then return percentScale("GPSFuelPercent") end
    if mode == "auto" then return percentScale("AutoDriveFuelPercent") end
    return nil
end

function MDAD.extraFuelFactor(navOn, autoOn)
    local factor = 0
    if navOn == true then
        factor = factor + MDAD.FUEL_OVERHEAD_NAV * MDAD.fuelScale("nav")
    end
    if autoOn == true then
        factor = factor + MDAD.FUEL_OVERHEAD_AUTO * MDAD.fuelScale("auto")
    end
    return factor
end

-- vehicle:getBattery()＝VehicleParts.java:148-149（腳踏車／拖車可能無此 part）
function MDAD.getBatteryPart(vehicle)
    if not vehicle then return nil end
    return vehicle:getBattery()
end

-- 裝置槽＝真正的 VehiclePart（由 shared/MDAD_DeviceParts.lua 在 OnGameBoot
-- 用原版 copyPartsFrom 注入每個有電瓶＋有合法 area 的車輛腳本）。
-- 舊制把 nav/auto/navDelta 記在電瓶 part 的 modData，讀者一律改讀這兩個槽裡的
-- **實物**；舊資料只剩 MDAD.migrateDeviceParts 會去碰。
MDAD.PART_NAV = "MDADGPS"
MDAD.PART_AUTO = "MDADAutopilot"

-- kind → 該槽應有的 item full type（安裝時比對、遷移時生成）
function MDAD.deviceItemType(kind)
    if kind == "nav" then return MDAD.TYPE_GPS end
    if kind == "auto" then return MDAD.TYPE_AUTO end
    return nil
end

-- BaseVehicle.getPartById(String)＝VehicleParts.java:113-115 的委派（原版 Lua 用例
-- Vehicles.lua:906）。腳本沒被注入（無電瓶／無合法 area／part 數量爆表）就回 nil。
function MDAD.getDevicePart(vehicle, kind)
    if not vehicle then return nil end
    local id
    if kind == "nav" then
        id = MDAD.PART_NAV
    elseif kind == "auto" then
        id = MDAD.PART_AUTO
    else
        return nil
    end
    local part = vehicle:getPartById(id)
    if MDAD.deviceKind(part) == kind then return part end
    return nil
end

-- VehiclePart.getId＝VehiclePart.java:119
function MDAD.deviceKind(part)
    if not part then return nil end
    local id = part:getId()
    if id ~= MDAD.PART_NAV and id ~= MDAD.PART_AUTO then return nil end
    -- 同名衝突已被注入器拒絕；讀者／動作也不能接管對方零件。
    if part:getLuaFunction("init") ~= "MDAD_DeviceParts.onPartInit" then return nil end
    if id == MDAD.PART_NAV then return "nav" end
    if id == MDAD.PART_AUTO then return "auto" end
    return nil
end

-- 「裝了」＝槽存在、槽裡有 item，且 fullType 正確。
-- fullType 必須查：原版維修面板在 specificItem=false 的情況下可以塞別的型號，
-- 而 MDAD 的耗電與駕駛邏輯只認自己的兩個 full type。
local function deviceInstalled(vehicle, kind)
    local part = MDAD.getDevicePart(vehicle, kind)
    if not part then return false end
    local item = part:getInventoryItem()
    if not item then return false end
    return item:getFullType() == MDAD.deviceItemType(kind)
end

function MDAD.isNavInstalled(vehicle)
    return deviceInstalled(vehicle, "nav")
end

function MDAD.isAutoInstalled(vehicle)
    return deviceInstalled(vehicle, "auto")
end

-- getBatteryCharge：VehicleParts.java:152-156，無電瓶 item 或非 drainable＝0
function MDAD.isBatteryLive(vehicle)
    if not vehicle then return false end
    return vehicle:getBatteryCharge() > 0
end

function MDAD.hasVehicleNavPower(vehicle)
    return MDAD.isNavInstalled(vehicle) and MDAD.isBatteryLive(vehicle)
end

-- GPS／自駕 billing 都只能信任 OnClientCommand 第三參數 actor 的短效 heartbeat。
-- **禁止**再以 IsoPlayer modData 的 TX/TY 當權威：42.20.4 ObjectModDataPacket 只要求
-- LoginOnServer，沒有 connection ownership，惡意 client 能覆寫別人的 player modData。
-- registry 只存 server-derived identity／vehicle id／timestamp 純量，不持 Java object。
local navUsage = {}
local autoUsage = {}

local function playerIdentity(player)
    if not player then return nil, nil end
    local username = player:getUsername()
    local playerId
    if isServer() then
        playerId = player:getOnlineID()
    else
        playerId = player:getPlayerNum()
    end
    if type(username) ~= "string" or not MDAD.isFiniteInt(playerId) or playerId < 0 then
        return nil, nil
    end
    return username, playerId
end

local function playerUsageKey(username, playerId)
    return tostring(#username) .. ":" .. username .. ":" .. tostring(playerId)
end

local function currentVehicle(player)
    local vehicle = player and player:getVehicle()
    if not vehicle then return nil, -1 end
    local vehicleId = vehicle:getId()
    if not MDAD.isFiniteInt(vehicleId) then return nil, nil end
    return vehicle, vehicleId
end

-- 車機只准由實際 driver 計費；乘客不能靠車機讓別人的車付帳。乘客／步行者若有
-- charged portable，成本只落在 actor 自己的 item。NeedItemForNav=false 且沒裝置
-- 代表免費導航，不虛構 GPS 裝置成本。
local function navUsageSource(player, vehicle)
    if vehicle and vehicle:isDriver(player) and MDAD.hasVehicleNavPower(vehicle) then
        return "vehicle"
    end
    if MDAD.findChargedPortableGPS(player) then return "portable" end
    return nil
end

function MDAD.setNavUsage(player)
    if isClient() then return false end
    local username, playerId = playerIdentity(player)
    if not username then return false end
    local vehicle, vehicleId = currentVehicle(player)
    if vehicleId == nil or not navUsageSource(player, vehicle) then return false end
    local key = playerUsageKey(username, playerId)
    local entry = navUsage[key]
    if not entry then
        entry = {}
        navUsage[key] = entry
    end
    entry.username = username
    entry.playerId = playerId
    entry.vehicleId = vehicleId
    entry.at = getTimestampMs()
    return true
end

function MDAD.clearNavUsage(player)
    if isClient() then return false end
    local username, playerId = playerIdentity(player)
    if not username then return false end
    local key = playerUsageKey(username, playerId)
    if not navUsage[key] then return false end
    navUsage[key] = nil
    return true
end

function MDAD.isNavUsageActive(player, expectedVehicle)
    local username, playerId = playerIdentity(player)
    if not username then return false end
    local key = playerUsageKey(username, playerId)
    local entry = navUsage[key]
    if not entry then return false end
    local now = getTimestampMs()
    local vehicle, vehicleId = currentVehicle(player)
    local source = navUsageSource(player, vehicle)
    if type(entry.at) ~= "number" or now < entry.at
        or now - entry.at > MDAD.NAV_USAGE_TTL_MS
        or entry.username ~= username or entry.playerId ~= playerId
        or entry.vehicleId ~= vehicleId
        or (expectedVehicle ~= nil and vehicle ~= expectedVehicle)
        or not source then
        navUsage[key] = nil
        return false
    end
    return true, source
end

function MDAD.pruneNavUsage()
    local now = getTimestampMs()
    for key, entry in pairs(navUsage) do
        if type(entry.at) ~= "number" or now < entry.at
            or now - entry.at > MDAD.NAV_USAGE_TTL_MS then
            navUsage[key] = nil
        end
    end
end

function MDAD.clearAutoUsage(player, vehicleId)
    if isClient() or not MDAD.isFiniteInt(vehicleId) then return false end
    local username, playerId = playerIdentity(player)
    local entry = autoUsage[vehicleId]
    if not username or not entry or entry.username ~= username
        or entry.playerId ~= playerId then return false end
    autoUsage[vehicleId] = nil
    return true
end

function MDAD.setAutoUsage(player, vehicle)
    if isClient() or not player or not vehicle then return false end
    if not vehicle:isDriver(player) or not vehicle:isEngineRunning() then return false end
    if not MDAD.isBatteryLive(vehicle) then return false end
    if MDAD.sandbox("NeedItemForAutoDrive", true) == true
        and not MDAD.isAutoInstalled(vehicle) then return false end
    -- AutoDrive 本身可在 NeedItemForNav=false 下合法運作；若 actor 確有 GPS source，
    -- server 順手續期 nav，確保 auto＋GPS 的兩份成本不能靠漏送 NavUsage 拆開。
    MDAD.setNavUsage(player)
    local vehicleId = vehicle:getId()
    local username, playerId = playerIdentity(player)
    if not MDAD.isFiniteInt(vehicleId) or not username then return false end
    local entry = autoUsage[vehicleId]
    if not entry then
        entry = {}
        autoUsage[vehicleId] = entry
    end
    entry.username = username
    entry.playerId = playerId
    entry.at = getTimestampMs()
    return true
end

function MDAD.isAutoUsageActive(vehicle)
    if not vehicle then return false end
    local vehicleId = vehicle:getId()
    if not MDAD.isFiniteInt(vehicleId) then return false end
    local entry = autoUsage[vehicleId]
    if not entry then return false end
    local now = getTimestampMs()
    local driver = vehicle:getDriver()
    local username, playerId = playerIdentity(driver)
    if type(entry.at) ~= "number" or now < entry.at
        or now - entry.at > MDAD.AUTO_USAGE_TTL_MS
        or entry.username ~= username or entry.playerId ~= playerId
        or not vehicle:isEngineRunning() or not MDAD.isBatteryLive(vehicle)
        or (MDAD.sandbox("NeedItemForAutoDrive", true) == true
            and not MDAD.isAutoInstalled(vehicle)) then
        autoUsage[vehicleId] = nil
        return false
    end
    return true
end

function MDAD.pruneAutoUsage()
    local now = getTimestampMs()
    for vehicleId, entry in pairs(autoUsage) do
        if type(entry.at) ~= "number" or now < entry.at
            or now - entry.at > MDAD.AUTO_USAGE_TTL_MS then
            autoUsage[vehicleId] = nil
        end
    end
end

function MDAD.vehicleUsageModes(vehicle)
    if not vehicle then return false, false, nil end
    local driver = vehicle:getDriver()
    local navOn = driver ~= nil and MDAD.isNavUsageActive(driver, vehicle)
    return navOn, MDAD.isAutoUsageActive(vehicle), driver
end

function MDAD.findScrewdriver(player)
    if not player then return nil end
    local inv = player:getInventory()
    if not inv then return nil end
    -- ItemTag.SCREWDRIVER＋predicateNotBroken：ISVehicleMechanics.lua:1567-1568
    return inv:getFirstTagEvalRecurse(ItemTag.SCREWDRIVER, predicateNotBroken)
end

function MDAD.hasInstallSkill(player)
    if not player then return false end
    if MDAD.sandbox("InstallSkillGate", true) ~= true then return true end
    return player:getPerkLevel(Perks.Electricity) >= 1
end

function MDAD.findPortableGPS(player)
    if not player then return nil end
    local inv = player:getInventory()
    if not inv then return nil end
    return inv:getFirstTypeRecurse(MDAD.TYPE_GPS)
end

function MDAD.findChargedPortableGPS(player)
    if not player then return nil end
    local inv = player:getInventory()
    if not inv then return nil end
    return inv:getFirstTypeEvalRecurse(MDAD.TYPE_GPS, predicateChargedGPS)
end

function MDAD.findAutopilot(player)
    if not player then return nil end
    local inv = player:getInventory()
    if not inv then return nil end
    return inv:getFirstTypeRecurse(MDAD.TYPE_AUTO)
end

-- 拆裝可及性（安裝／卸載唯一判準；server 端亦用同一份）。
-- 站在車外、同層、通得過保險屋權限，且**站在裝置槽 area 內**才算可及——
-- 不再退回 DistToSquared 距離：距離平方 <16 等於整輛車周圍約 4 格全放行，
-- 隔著牆／從屋內對街上的車動手都會通過，MP 下就是隔牆偷裝。
-- 出處：
--   BaseVehicle.getSquare＝BaseVehicle.java:9708；
--   SafeHouse.isSafehouseAllowInteract＝SafeHouse.java:245（拆裝屬 interact 不是 loot，
--     原版同判準用例 ISMoveablesAction.lua:60 的 scrap 分支）；
--   VehiclePart.getArea＝VehiclePart.java:127（回 script area id 字串，腳踏車／拖車可能為 nil）；
--   BaseVehicle.isInArea(areaId, chr)＝BaseVehicle.java:8225（chr 為 nil 直接 false）。
--     原版**伺服器端**存取判定用的就是這組合：server/Vehicles/Vehicles.lua:25-26
--     先 `chr:getVehicle()` 排除車內，再 `vehicle:isInArea(part:getArea(), chr)`，
--     全程沒有距離 fallback——本函式照抄這個判準；
--   IsoGridSquare.canReachTo＝IsoGridSquare.java:841（只認同格／相鄰格，且查窗／門／牆阻隔；
--     原版 Lua 用例 ISInventoryPage.lua:1679、ISGrabCorpseAction.lua:6）。
-- area 取自**裝置槽**（注入端讓兩個槽共用同一個 area，client 的
-- pathToVehicleArea 與維修面板也走同一個），槽不存在才退回電瓶 part——
-- 那條退路只為了讓「腳本沒被注入／遷移失敗」的車還能給出可診斷的既有行為。
function MDAD.canReachVehicle(player, vehicle)
    if not player or not vehicle then return false end
    -- 坐在車上拿不到電瓶艙，且車內座標對 area 判定沒有意義；一律要求先下車
    if player:getVehicle() ~= nil then return false end
    local vsq = vehicle:getSquare()
    local psq = player:getCurrentSquare()
    -- 格子缺失一律 fail closed。原版 ISGrabItemAction.lua:15-19 在此是 fail **open**
    -- （拿不到格子就跳過阻隔檢查），那是純 client UX 判定；本函式是權威突變的前置條件，
    -- 資訊不全時只能拒絕。
    if not vsq or not psq then return false end
    if not SafeHouse.isSafehouseAllowInteract(vsq, player) then return false end
    if math.floor(player:getZ()) ~= math.floor(vehicle:getZ()) then return false end
    local part = MDAD.getDevicePart(vehicle, "nav")
        or MDAD.getDevicePart(vehicle, "auto")
        or MDAD.getBatteryPart(vehicle)
    local area = part and part:getArea()
    if area then
        -- 有 area 就以 area 為唯一判準（client 端會先 pathToVehicleArea 走進去）
        return vehicle:isInArea(area, player) == true
    end
    -- script 未定義該 area（腳踏車／拖車等）：退回相鄰格＋阻隔檢查
    return psq:canReachTo(vsq) == true
end

-- 回 nil＝可進行；否則翻譯鍵
function MDAD.deviceBlockReason(player, vehicle, kind, install)
    if not player or not vehicle then return "UI_MinidoracatAutoDrive_InstallFailed" end
    if kind ~= "nav" and kind ~= "auto" then return "UI_MinidoracatAutoDrive_InstallFailed" end
    -- 電瓶仍是先決條件：裝置吃車電，沒有電瓶 part 的載具（腳踏車／拖車）不支援
    if not MDAD.getBatteryPart(vehicle) then return "UI_MinidoracatAutoDrive_NoBattery" end
    -- 槽不存在＝這台車的腳本沒被注入（無合法 area／part 數量超過網路上限）。
    -- 不另開翻譯鍵：對玩家而言就是「裝不上去」。
    if not MDAD.getDevicePart(vehicle, kind) then return "UI_MinidoracatAutoDrive_InstallFailed" end
    if not MDAD.findScrewdriver(player) then return "UI_MinidoracatAutoDrive_NoScrewdriver" end
    if not MDAD.hasInstallSkill(player) then return "UI_MinidoracatAutoDrive_NeedElectricity1" end
    local installed = deviceInstalled(vehicle, kind)
    -- 兩條失敗規則：裝了又要裝／沒裝卻要卸
    if install and MDAD.getDevicePart(vehicle, kind):getInventoryItem() ~= nil then
        return "UI_MinidoracatAutoDrive_AlreadyInstalled"
    end
    if not install and not installed then return "UI_MinidoracatAutoDrive_InstallFailed" end
    return nil
end

-- 把卸下的裝置還給操作者：塞得下進背包，否則掉在腳邊。
-- server 端 DoRemoveItem／AddItem＋AddWorldInventoryItem 是原版慣例
-- （SCampfireGlobalObject.lua:142-143）；sendAddItemToContainer 在非 server 端是 no-op
-- （LuaManager.java:12306-12310），仍顯式 isServer() 以標明只有 server 需要廣播。
local function giveItem(player, item)
    local inv = player:getInventory()
    if inv and inv:hasRoomFor(player, item) then
        inv:AddItem(item)
        if isServer() then sendAddItemToContainer(inv, item) end
        return
    end
    local square = player:getCurrentSquare()
    if not square then
        -- 沒有格子可放就寧可讓背包超重，也不能讓裝置人間蒸發
        if inv then
            inv:AddItem(item)
            if isServer() then sendAddItemToContainer(inv, item) end
        end
        return
    end
    local dropX, dropY, dropZ = ISTransferAction.GetDropItemOffset(player, square, item)
    square:AddWorldInventoryItem(item, dropX, dropY, dropZ)
end

-- 安裝／卸載的唯一突變點。MP 由 server/MDAD_Server.lua 在 OnClientCommand 內呼叫
-- （actor 取連線身分）；SP 由 TimedAction:perform 直接呼叫。
-- 只收純量 {kind, install, itemId}＋server 自己解析出來的 player／vehicle：
-- 不接受 client 傳來的 actor、userdata、partId、navDelta 或 state。
-- itemId 只有 install＝true 才需要（卸載還的是槽裡那顆**實物**，沒有來源 id，
-- 呼叫端可省略），且必須是有限整數才准進 getItemWithIDRecursiv。
-- 驗證順序（任一關失敗即整批放棄，物品與零件一律不動）：
--   ① schema ② actor ③ 載具／電瓶 ④ 可及性／保險屋 ⑤ 工具／技能／槽／狀態轉移 ⑥ 物品
-- 突變本身是「把同一顆 item 在背包與 VehiclePart 之間搬移」：
--   安裝＝從容器移除後 part:setInventoryItem(item)
--   卸載＝part:setInventoryItem(nil) 後把**同一顆**還給玩家
-- 不再 instanceItem 複製：GPS 電量、耐久、其他 mod 寫在 item modData 上的資料
-- 全部隨實物走，也不會有「複製出一顆、原件還在」的增殖風險。
-- 回傳 (true) 或 (false, 翻譯鍵)。
function MDAD.applyDeviceChange(player, vehicle, kind, install, itemId)
    -- client 端沒有權威，且 sendRemoveItemFromContainer 走 SyncItemDelete 需 EditItem
    -- 權限（SyncItemDeletePacket.java:7-14），一般玩家發送會觸發反作弊踢出
    if isClient() then return false, MDAD.FAIL_GENERIC end

    -- ① schema
    if kind ~= "nav" and kind ~= "auto" then return false, MDAD.FAIL_GENERIC end
    if type(install) ~= "boolean" then return false, MDAD.FAIL_GENERIC end
    -- itemId 直接餵 Java int（getItemWithIDRecursiv）：小數會被截斷成別的 id、
    -- NaN／±Inf 會變成垃圾 id，型別檢查不夠，要 isFiniteInt
    if install and not MDAD.isFiniteInt(itemId) then return false, MDAD.FAIL_GENERIC end

    -- ② actor：屍體不能修車；還在車上一律先下車（可及性也會再擋一次）
    if not player or player:isDead() then return false, MDAD.FAIL_GENERIC end
    if player:getVehicle() ~= nil then return false, MDAD.FAIL_TOO_FAR end

    -- ③ 載具／電瓶
    if not vehicle then return false, MDAD.FAIL_GENERIC end
    if not MDAD.getBatteryPart(vehicle) then return false, MDAD.FAIL_NO_BATTERY end

    -- ④ 可及性（含保險屋權限、同層、裝置槽 area）
    if not MDAD.canReachVehicle(player, vehicle) then return false, MDAD.FAIL_TOO_FAR end

    -- ⑤ 工具／技能／槽存在／狀態轉移：與選單置灰共用同一份規則，避免兩套判準漂移
    local reason = MDAD.deviceBlockReason(player, vehicle, kind, install)
    if reason then return false, reason end

    -- blockReason 已驗過槽存在
    local part = MDAD.getDevicePart(vehicle, kind)
    local want = MDAD.deviceItemType(kind)

    if install then
        -- ⑥ 物品：只從**操作者自己的**背包樹依 ID 重解析
        -- （ItemContainer.getItemWithIDRecursiv＝ItemContainer.java:3065，會遞迴進袋子），
        -- 所以車上零件容器、地板、他人背包裡的同型物品都拿不到；
        -- fullType 必須對上 kind；移除時用 item:getContainer()（InventoryItem.java:3837）
        -- 解析出來的**實際**容器，而不是預設主背包。
        local inv = player:getInventory()
        local item = inv and inv:getItemWithIDRecursiv(itemId)
        if not item then return false, MDAD.FAIL_GENERIC end
        if item:getFullType() ~= want then return false, MDAD.FAIL_GENERIC end
        local container = item:getContainer()
        if not container then return false, MDAD.FAIL_GENERIC end

        -- 以下不再有失敗點
        item:setJobDelta(0)
        player:removeFromHands(item)
        container:DoRemoveItem(item)
        if isServer() then sendRemoveItemFromContainer(container, item) end

        -- VehiclePart.setInventoryItem＝VehiclePart.java:163-165（內部會跑
        -- doInventoryItemStats：condition／容量／質量同步，Lua 端不必自己補）
        part:setInventoryItem(item)
        -- BaseVehicle.transmitPartItem＝BaseVehicle.java:8145（MP 廣播整顆 item）
        vehicle:transmitPartItem(part)
        return true
    end

    -- 卸載：blockReason 已驗過「裝了」＝槽裡有正確 fullType 的實物
    local item = part:getInventoryItem()
    if not item then return false, MDAD.FAIL_GENERIC end
    -- 遷移印記只在「槽裡這顆是遷移生出來的」期間有意義，回到玩家手上就清掉
    local imd = item:getModData()
    if imd then imd.MDADMigrated = nil end
    part:setInventoryItem(nil)
    vehicle:transmitPartItem(part)
    giveItem(player, item)
    return true
end

-- server／SP 逐槽把 Battery.modData.MDAD 舊旗標轉成實物。
-- 回讀實物成功或確認同型遷移印記後，才清該槽旗標；失敗保留未完成部分。
-- 回傳 (done, events)：全部完成／原本乾淨為 true；events 為 nil 或診斷字串陣列。
function MDAD.migrateDeviceParts(vehicle)
    if isClient() or not vehicle then return true, nil end
    local bat = MDAD.getBatteryPart(vehicle)
    if not bat then return true, nil end
    local md = bat:getModData()
    local st = md and md.MDAD
    if type(st) ~= "table" then return true, nil end

    local events = {}
    local done = true
    local dirty = false

    for _, kind in ipairs({ "nav", "auto" }) do
        if st[kind] == true then
            local part = MDAD.getDevicePart(vehicle, kind)
            if not part then
                -- 這台車的腳本沒被注入：不是失敗，是還沒有槽可以放
                done = false
                if not st.noSlotLogged then
                    st.noSlotLogged = true
                    dirty = true
                    events[#events + 1] = "deferred no-slot kind=" .. kind
                end
            else
                local existing = part:getInventoryItem()
                if existing ~= nil then
                    local emd = existing:getModData()
                    if existing:getFullType() == MDAD.deviceItemType(kind)
                        and emd and emd.MDADMigrated == true then
                        -- 上一輪裝好了、但清旗標前中斷：收尾即可
                        st[kind] = nil
                        if kind == "nav" then st.navDelta = nil end
                        dirty = true
                        events[#events + 1] = "resumed kind=" .. kind
                            .. " item=" .. tostring(existing:getID())
                    else
                        -- 實物與舊旗標同時存在且不是我們裝的：不複製、不覆寫、不清資料
                        done = false
                        if st[kind .. "Conflict"] ~= true then
                            st[kind .. "Conflict"] = true
                            dirty = true
                            events[#events + 1] = "conflict kind=" .. kind
                                .. " existing=" .. tostring(existing:getFullType())
                        end
                    end
                else
                    local item = instanceItem(MDAD.deviceItemType(kind))
                    if not item then
                        done = false
                        events[#events + 1] = "failed instanceItem kind=" .. kind
                    else
                        local oldDelta
                        if kind == "nav" then
                            oldDelta = clampDelta(st.navDelta)
                            item:setUsedDelta(oldDelta)
                        end
                        item:getModData().MDADMigrated = true
                        part:setInventoryItem(item)
                        vehicle:transmitPartItem(part)
                        -- 回讀驗證：確定槽裡真的是這顆，才准動舊資料
                        if part:getInventoryItem() == item then
                            st[kind] = nil
                            if kind == "nav" then st.navDelta = nil end
                            dirty = true
                            events[#events + 1] = "migrated kind=" .. kind
                                .. " item=" .. tostring(item:getID())
                                .. (kind == "nav" and (" oldUses=" .. tostring(oldDelta)
                                    .. " uses=" .. tostring(item:getCurrentUsesFloat())) or "")
                        else
                            done = false
                            events[#events + 1] = "failed verify kind=" .. kind
                        end
                    end
                end
            end
        end
    end

    if done and st.nav == nil and st.auto == nil
        and st.navConflict ~= true and st.autoConflict ~= true then
        -- 舊表整個是我們的，清乾淨；電瓶 modData 的其他 key 一律不動
        md.MDAD = nil
        dirty = true
    end
    if dirty then vehicle:transmitPartModData(bat) end
    if #events == 0 then return done, nil end
    return done, events
end

-- 閘門：NeedItemForNav false 放行；否則 charged 隨身 GPS 或 已裝 nav＋活車電。
-- draw 熱路徑：沙盒／車電 O(1)；隨身搜尋有 1s 快取，禁止每幀掃背包。
local gateCache = {}

function MDAD.navGate(playerNum, context)
    if MDAD.sandbox("NeedItemForNav", false) ~= true then return true end
    local player = getSpecificPlayer(playerNum)
    if not player then return true end
    if MDAD.hasVehicleNavPower(player:getVehicle()) then return true end
    if context == "draw" then
        local now = getTimestampMs()
        local c = gateCache[playerNum]
        if c and (now - c.t) < GATE_TTL_MS then
            if c.allowed then return true end
            return false, GATE_REASON
        end
        local allowed = MDAD.findChargedPortableGPS(player) ~= nil
        if not c then
            c = {}
            gateCache[playerNum] = c
        end
        c.t = now
        c.allowed = allowed
        if allowed then return true end
        return false, GATE_REASON
    end
    if MDAD.findChargedPortableGPS(player) then return true end
    return false, GATE_REASON
end


-- server-authoritative。原版 Vehicles.Update.Battery 仍照引擎狀態充電；本函式只補扣
-- 裝置負載，因此引擎運轉時是「發電機充電 − GPS − 自駕」，不是把裝置成本免除。
-- navOn／autoOn 同一輪合併成一次 usedDelta write，避免疊加時互踩與重複同步。
function MDAD.consumeVehiclePowerModes(vehicle, navOn, autoOn, minutes)
    if isClient() or not vehicle then return false end
    local part = MDAD.getBatteryPart(vehicle)
    local bat = part and part:getInventoryItem()
    if not bat or not bat.getCurrentUsesFloat or not bat.setUsedDelta then return false end
    local old = bat:getCurrentUsesFloat()
    -- 滿電＋引擎運轉時由發電機 headroom 直接供應，避免 vanilla 每分鐘充回 1.0、
    -- 本函式又拉到 0.999x，造成 1.0 邊界雙向同步抖動。未滿電仍照扣＝充電變慢。
    if old >= 1 and vehicle:isEngineRunning() then return true end
    if type(minutes) ~= "number" or minutes <= 0 then return old > 0 end
    local rate = 0
    if navOn == true then rate = rate + MDAD.RATE_NAV * MDAD.powerScale("nav") end
    if autoOn == true then rate = rate + MDAD.RATE_AUTO * MDAD.powerScale("auto") end
    if rate <= 0 then return old > 0 end
    local charge = clamp01(old - rate * minutes)
    if charge ~= old then
        bat:setUsedDelta(charge)
        if VehicleUtils.compareFloats(old, charge, 2) then
            vehicle:transmitPartUsedDelta(part)
        end
    end
    return charge > 0
end


-- 隨身裝置只有 GPS；AutoDrive module 不是 drainable，拒絕維護不存在的 portable-auto 路徑。
function MDAD.consumePortablePower(item, minutes)
    if isClient() then return false end
    if not item or not item.getCurrentUsesFloat or not item.setUsedDelta then return false end
    local rate = 0.006
    if item.getUseDelta then
        local ud = item:getUseDelta()
        if type(ud) == "number" and ud > 0 then rate = ud end
    end
    local scale = MDAD.powerScale("nav")
    if scale <= 0 or type(minutes) ~= "number" or minutes <= 0 then
        return item:getCurrentUsesFloat() > 0
    end
    local old = item:getCurrentUsesFloat()
    local charge = clamp01(old - rate * minutes * scale)
    if charge ~= old then
        item:setUsedDelta(charge)
        if isServer() then sendItemStats(item) end
    end
    return charge > 0
end
