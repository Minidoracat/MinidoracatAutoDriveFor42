-- OnGameBoot 從標準 template 追加裝置槽；只處理有電瓶、合法工作區且索引安全的車型。
-- 腳本載入後、車輛建立前注入（GameServer.java:1481／Core.java:3962）。
-- 不用 scriptReloaded（清既有物品）或 Loaded（重複縮放幾何）；VehicleScript.copyPartsFrom
-- 只追加我方零件。物品遷移由 server／SP 的 part init 執行，client 只接收結果。

require "MDAD"

MDAD_DeviceParts = MDAD_DeviceParts or {}

local PREFIX = "[MinidoracatAutoDrive]"

local function logInject(msg)
    print(PREFIX .. "[deviceparts] " .. msg)
end

local function logMigration(msg)
    print(PREFIX .. "[migration] " .. msg)
end

-- 原版 Default 不硬性驗技能（Vehicles.lua:911/946），補上本 MOD 的電工門檻。
local function vanillaThen(defaultFn, vehicle, part, chr)
    if type(defaultFn) ~= "function" then return false end
    if defaultFn(vehicle, part, chr) ~= true then return false end
    return MDAD.hasInstallSkill(chr) == true
end

function MDAD_DeviceParts.InstallTest(vehicle, part, chr)
    return vanillaThen(Vehicles and Vehicles.InstallTest and Vehicles.InstallTest.Default,
        vehicle, part, chr)
end

function MDAD_DeviceParts.UninstallTest(vehicle, part, chr)
    return vanillaThen(Vehicles and Vehicles.UninstallTest and Vehicles.UninstallTest.Default,
        vehicle, part, chr)
end

-- create 只設定空安裝座條件，不生成物品；新車不會免費得到裝置。
function MDAD_DeviceParts.onPartCreate(_, part)
    if part then part:setCondition(100) end
end

-- VehicleParts.initParts:265-273 每次建立車輛都會呼叫；只在 authority 的 nav 槽處理一次。
-- init 也可能來自物理重建，audit 只報目前實況，不冒稱剛從磁碟重載。
function MDAD_DeviceParts.onPartInit(vehicle, part)
    if isClient() then return end
    if not vehicle or MDAD.deviceKind(part) ~= "nav" then return end

    local done, events = MDAD.migrateDeviceParts(vehicle)
    local script = tostring(vehicle:getScriptName()) .. " sql=" .. tostring(vehicle:getSqlId())

    if events then
        for _, ev in ipairs(events) do
            logMigration("script=" .. script .. " " .. ev)
        end
        if not done then
            logMigration("script=" .. script .. " INCOMPLETE：舊資料保留，下次載入重試")
        end
    end

    -- 稽核：只印當下槽裡真的有東西的車，空車不噴日誌
    for _, kind in ipairs({ "nav", "auto" }) do
        local slot = MDAD.getDevicePart(vehicle, kind)
        local item = slot and slot:getInventoryItem()
        if item then
            logMigration("audit script=" .. script
                .. " slot=" .. slot:getId()
                .. " type=" .. tostring(item:getFullType())
                .. " item=" .. tostring(item:getID())
                .. (kind == "nav" and (" uses=" .. tostring(item:getCurrentUsesFloat())) or ""))
        end
    end
end

-- ── 腳本注入 ────────────────────────────────────────────────────────────────

-- VehiclePartItem 的網路同步把 part index 當 byte 寫，且續讀那筆沒有 & 255
-- （VehiclePartItem.java:21 `for (int partIndex = bb.getByte() & 255; partIndex != -1;
--   partIndex = bb.getByte())`），index > 127 會被讀成負數 → getPartByIndex 回 null。
-- 所以加完兩個槽之後 part 總數必須 <= 128（最大索引 127）。
local MAX_PARTS = 128

-- 模組限定名稱，避免與其他 template 同名；以 script identity 記錄本次 Lua runtime 注入。
local injected = {}

-- 兩個入口與伺服器可及性共用此工作區：Engine 存在時優先，否則第一個合法 area。
local function pickAreaId(script)
    if script:getAreaById("Engine") ~= nil then return "Engine" end
    for i = 1, script:getAreaCount() do
        local area = script:getArea(i - 1)
        local id = area and area:getId()
        -- 這個字串等一下要餵回 ScriptParser，限制成識別字避免語法注入
        if type(id) == "string" and string.find(id, "^%a[%w_]*$") ~= nil then
            return id
        end
    end
    return nil
end

-- Part.area 沒有 Lua setter；LoadPart:909-915 可按 ID 更新 donor 的指定欄位。
local function patchArea(script, areaId)
    local body = "vehicle MDADDeviceParts\n"
        .. "{\n"
        .. "    part " .. MDAD.PART_NAV .. "\n"
        .. "    {\n"
        .. "        area = " .. areaId .. ",\n"
        .. "        mechanicArea = " .. areaId .. ",\n"
        .. "    }\n"
        .. "    part " .. MDAD.PART_AUTO .. "\n"
        .. "    {\n"
        .. "        area = " .. areaId .. ",\n"
        .. "        mechanicArea = " .. areaId .. ",\n"
        .. "    }\n"
        .. "}\n"
    return pcall(function() script:Load("MDADDeviceParts", body) end)
end

function MDAD_DeviceParts.injectAll()
    local sm = getScriptManager()
    if not sm then return end

    local tmpl
    local t = sm:getVehicleTemplate("Base.MDADDeviceParts")
    if t then tmpl = t:getScript() end
    if not tmpl or not tmpl:getPartById(MDAD.PART_NAV) or not tmpl:getPartById(MDAD.PART_AUTO) then
        logInject("ABORT: template MDADDeviceParts 缺失或不完整，這次不注入任何裝置槽")
        return
    end

    local scripts = sm:getAllVehicleScripts()
    local added, skipped, conflict = 0, 0, 0
    for i = 1, scripts:size() do
        local script = scripts:get(i - 1)
        local full = tostring(script:getFullName())
        if injected[script] and script:getPartById(MDAD.PART_NAV)
            and script:getPartById(MDAD.PART_AUTO) then
            -- 這個 process 內已經加過，parts 還在，什麼都不用做
            added = added + 1
        elseif script:getPartById("Battery") == nil then
            skipped = skipped + 1
        elseif script:getPartById(MDAD.PART_NAV) ~= nil or script:getPartById(MDAD.PART_AUTO) ~= nil then
            -- 同名 part 但不是我們加的：別人（另一個 mod／手改腳本）先佔了這個 id。
            -- 覆寫會把對方的定義換掉，寧可整台不支援也不動它。
            conflict = conflict + 1
            logInject("CONFLICT script=" .. full .. " 已存在 " .. MDAD.PART_NAV
                .. "／" .. MDAD.PART_AUTO .. " 且非本 MOD 定義，不覆寫、此車無裝置槽")
        else
            local areaId = pickAreaId(script)
            if not areaId then
                skipped = skipped + 1
            elseif script:getPartCount() + 2 > MAX_PARTS then
                skipped = skipped + 1
                logInject("SKIP script=" .. full .. " partCount=" .. tostring(script:getPartCount())
                    .. " 加兩個槽會超過 byte part index 上限（128）")
            else
                -- 先在 donor 準備好共同工作區；失败不把缺少 area 的半成品加進真車。
                local ok, err = patchArea(tmpl, areaId)
                if not ok then
                    skipped = skipped + 1
                    logInject("SKIP script=" .. full .. " area 改寫失敗：" .. tostring(err))
                else
                    script:copyPartsFrom(tmpl, MDAD.PART_NAV)
                    script:copyPartsFrom(tmpl, MDAD.PART_AUTO)
                    injected[script] = true
                    added = added + 1
                end
            end
        end
    end
    logInject("schema=2 side=" .. (isClient() and "client" or "authority")
        .. " added=" .. added .. " skipped=" .. skipped .. " conflict=" .. conflict)
end

Events.OnGameBoot.Add(MDAD_DeviceParts.injectAll)
