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
-- build 印記：載入時印進 console（不受 getDebug 管）——實機回報「行為沒變」時
-- 第一件事就是對這行，判定使用者跑的是不是新版（2026-08-28 三場撞樹回報
-- 無法從 log 判定 code 版本的教訓）。每次行為修正遞增尾碼。
MDAD.BUILD = "m62-20260831a"
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

function MDAD.getState(vehicle)
    local part = MDAD.getBatteryPart(vehicle)
    local md = part and part:getModData()
    local st = md and md.MDAD
    if type(st) ~= "table" then return nil end
    return st
end

function MDAD.ensureState(part)
    local md = part:getModData()
    local st = md.MDAD
    if type(st) ~= "table" then
        st = { v = 1 }
        md.MDAD = st
    end
    st.v = 1
    return st
end

function MDAD.isNavInstalled(vehicle)
    local st = MDAD.getState(vehicle)
    return st ~= nil and st.nav == true
end

function MDAD.isAutoInstalled(vehicle)
    local st = MDAD.getState(vehicle)
    return st ~= nil and st.auto == true
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
-- 站在車外、同層、通得過保險屋權限，且**站在電瓶艙 area 內**才算可及——
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
    local part = MDAD.getBatteryPart(vehicle)
    local area = part and part:getArea()
    if area then
        -- 有 area 就以 area 為唯一判準（client 端會先 pathToVehicleArea 走進去）
        return vehicle:isInArea(area, player) == true
    end
    -- script 未定義電瓶艙 area（腳踏車／拖車等）：退回相鄰格＋阻隔檢查
    return psq:canReachTo(vsq) == true
end

-- 回 nil＝可進行；否則翻譯鍵
function MDAD.deviceBlockReason(player, vehicle, kind, install)
    if not player or not vehicle then return "UI_MinidoracatAutoDrive_InstallFailed" end
    if kind ~= "nav" and kind ~= "auto" then return "UI_MinidoracatAutoDrive_InstallFailed" end
    local part = MDAD.getBatteryPart(vehicle)
    if not part then return "UI_MinidoracatAutoDrive_NoBattery" end
    if not MDAD.findScrewdriver(player) then return "UI_MinidoracatAutoDrive_NoScrewdriver" end
    if not MDAD.hasInstallSkill(player) then return "UI_MinidoracatAutoDrive_NeedElectricity1" end
    local installed
    if kind == "nav" then
        installed = MDAD.isNavInstalled(vehicle)
    else
        installed = MDAD.isAutoInstalled(vehicle)
    end
    -- 兩條失敗規則：裝了又要裝／沒裝卻要卸
    if install and installed then return "UI_MinidoracatAutoDrive_AlreadyInstalled" end
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
-- itemId 只有 install＝true 才需要（卸載的物品由 instanceItem 生成，沒有來源 id，
-- 呼叫端可省略），且必須是有限整數才准進 getItemWithIDRecursiv。
-- 驗證順序（任一關失敗即整批放棄，物品與 modData 一律不動）：
--   ① schema ② actor ③ 載具／零件 ④ 可及性／保險屋 ⑤ 工具／技能 ⑥ 狀態轉移 ⑦ 物品
-- 最後才進入突變段（prepare-then-mutate）：卸載先把要還的物品做出來，成功了才清狀態，
-- 否則「狀態清了、物品沒生出來」＝裝置憑空消失。
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

    -- ③ 載具／零件
    if not vehicle then return false, MDAD.FAIL_GENERIC end
    local part = MDAD.getBatteryPart(vehicle)
    if not part then return false, MDAD.FAIL_NO_BATTERY end

    -- ④ 可及性（含保險屋權限、同層、電瓶艙 area）
    if not MDAD.canReachVehicle(player, vehicle) then return false, MDAD.FAIL_TOO_FAR end

    -- ⑤⑥ 工具／技能／狀態轉移：與選單置灰共用同一份規則，避免兩套判準漂移
    local reason = MDAD.deviceBlockReason(player, vehicle, kind, install)
    if reason then return false, reason end

    local want = MDAD.TYPE_GPS
    if kind == "auto" then want = MDAD.TYPE_AUTO end

    if install then
        -- ⑦ 物品：只從**操作者自己的**背包樹依 ID 重解析
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
        -- navDelta 一律 server 從實物讀取並 clamp，不採任何 client 值
        local delta = 0
        if kind == "nav" then delta = clampDelta(item:getCurrentUsesFloat()) end

        -- 以下不再有失敗點
        item:setJobDelta(0)
        player:removeFromHands(item)
        container:DoRemoveItem(item)
        if isServer() then sendRemoveItemFromContainer(container, item) end

        local st = MDAD.ensureState(part)
        if kind == "nav" then
            st.nav = true
            st.navDelta = delta
        else
            st.auto = true
        end
        vehicle:transmitPartModData(part)
        return true
    end

    -- 卸載：instanceItem 可能回 nil（script 缺失／改名），先做出來再動狀態
    local item = instanceItem(want)
    if not item then return false, MDAD.FAIL_GENERIC end
    local st = MDAD.ensureState(part)
    if kind == "nav" then
        item:setUsedDelta(clampDelta(st.navDelta))
        st.nav = false
        st.navDelta = nil
    else
        st.auto = false
    end
    vehicle:transmitPartModData(part)
    giveItem(player, item)
    return true
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
