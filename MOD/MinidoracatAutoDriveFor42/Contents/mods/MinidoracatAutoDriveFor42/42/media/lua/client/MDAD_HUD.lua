-- MDAD_HUD.lua
-- M5.5b 駕駛 HUD：每位本機玩家各一個面板，預設金屬擬物＋完整雙行；
-- 簡約／精簡由 PZAPI.ModOptions 切換，收合狀態跟角色存進 player modData。
--
-- 效能契約：UIElement.update 約 10Hz（UIElement.java:1661-1687），本檔再以
-- getTimestampMs 做 250ms 閘門；車輛 getter、getText、文字量測只在 refresh/layout。
-- prerender 每幀只讀 ESC root 與 dashboard identity/可見性，其餘只畫快取，不配置 table/closure。
--
-- 原版／框架出處：
--   ISPanel/ISButton 建構：ISPanel.lua:96-115、ISButton.lua:479-533
--   add/remove/always-on-top：ISUIElement.lua:1319-1323、1365-1379
--   車輛 HUD 事件與分割畫面定位：ISVehicleDashboard.lua:420-433、601-633
--   UIFor42 Skin.fill/border/dot：MinidoracatUI/V1.lua:166-210（缺席退直角）
--   ModOptions create/combo/apply/save：PZAPI/ModOptions.lua:121-155、247-289
--   現速／車電／油量：BaseVehicle.java:4268、VehicleParts.java:152-156、
--   BaseVehicle.java:9293-9296；原版用例 ISVehicleDashboard.lua:252、280-283、370-373。

require "MDAD"
require "MDAD_Driver"
require "ISUI/ISPanel"
require "ISUI/ISButton"

if MDAD.HUD then return end

-- Driver 載入失敗的次生防線。Kahlua 是以整個 chunk 為編譯單位：MDAD_Driver.lua 只要
-- 撞到結構上限（單一 function >60 upvalues／>190 locals）就整檔一行都不執行，
-- MDAD.Drive 根本沒建起來——2026-08-31 實機 KahluaException
-- 「MDAD_Driver.lua:4182: function at line 3207 has more than 60 upvalues」，
-- 接著 HUD 每 250ms 一輪讀 Drive.hudState，console 被
-- "attempted index: hudState of non-table: null" 洗爆，真正的根因那一行被推出捲軸，
-- 比「HUD 根本沒出現」難查一個數量級。所以這裡印一行安裝級診斷（同 Driver
-- startSession 對 MDADFollower 的慣例，不受 getDebug() 管）就退場：不建面板、
-- 不註冊事件、不掛 dashboard 控制。根因由發版閘門守（scripts/verify_mod.py 檢查
-- 1b 的 Kahlua 結構上限），這條只保證失敗安靜且訊息讀得到。
if type(MDAD.Drive) ~= "table" or type(MDAD.Drive.hudState) ~= "function" then
    print("[" .. MDAD.MOD_ID .. "] HUD disabled: MDAD_Driver not loaded")
    return
end

if not (MinidoracatUI and MinidoracatUI.v1) then
    pcall(require, "MinidoracatUI/V1")
end

local HUD = {}
local Drive = MDAD.Drive
local REFRESH_MS = 250
-- B42.20.4 UI2.pack 的原版 dashboard atlas 實測：row 0-6 是透明斜角，
-- row 7 起 alpha>=128；主體 #343434、外緣約 #5A5A5A。
local DASH_VISIBLE_TOP_INSET = 7
local DASH_CONTROL_SIZE = 18
local DASH_THEME_CONTROL_WIDTH = 28
local DASH_CONTROL_Y = 7
local DASH_CONTROL_RIGHT_INSET = 62
local DASH_CONTROL_GAP = 4
local STYLE_METAL = 1
local STYLE_MINIMAL = 2
local LAYOUT_FULL = 1
local LAYOUT_COMPACT = 2
local OPTION_ID = "MinidoracatAutoDrive"
local TRAJECTORY_WIDTH_DEFAULT = 2
local RETENTION_DAYS = { 1, 3, 7, 14, 30 }
local COLLAPSED_MD_KEY = "MDADHudCollapsed"
local SCALES = { 0.75, 1.0, 1.25 }
local GEAR_SHORT = { "30", "50", "70", "MAX" }
local GEAR_TOOLTIPS = {
    "UI_MinidoracatAutoDrive_GearChill",
    "UI_MinidoracatAutoDrive_GearStandard",
    "UI_MinidoracatAutoDrive_GearSport",
    "UI_MinidoracatAutoDrive_GearInsane",
}

local STATUS_KEYS = {
    arrive = "UI_MinidoracatAutoDrive_HUDStatusArrive",
    yield = "UI_MinidoracatAutoDrive_HUDStatusYield",
    unstick = "UI_MinidoracatAutoDrive_HUDStatusUnstick",
    blocked = "UI_MinidoracatAutoDrive_HUDStatusBlocked",
    dodging = "UI_MinidoracatAutoDrive_HUDStatusDodging",
    build = "UI_MinidoracatAutoDrive_HUDStatusBuild",
    follow = "UI_MinidoracatAutoDrive_HUDStatusFollow",
}

-- 停用原因 → HUD 短標籤。只列有專屬標籤的原因；其餘（例如 addon navGate
-- 回傳的自訂鍵）走 NotReady 退路，完整原因照樣進 actionButton tooltip。
local REASON_KEYS = {
    UI_MinidoracatAutoDrive_EngineOff = "UI_MinidoracatAutoDrive_HUDStatusEngineOff",
    UI_MinidoracatAutoDrive_RouteNotReady = "UI_MinidoracatAutoDrive_HUDStatusNoRoute",
    UI_MinidoracatAutoDrive_NeedGPS = "UI_MinidoracatAutoDrive_HUDStatusNoGPS",
    UI_MinidoracatAutoDrive_NavApiMissing = "UI_MinidoracatAutoDrive_HUDStatusNoNav",
}

-- 面板寬度取「最長狀態字串」；量測鍵表固定不變，留在載入期讓 applyLayout 不重建 table。
local STATUS_WIDTH_KEYS = {
    "UI_MinidoracatAutoDrive_HUDStatusArrive",
    "UI_MinidoracatAutoDrive_HUDStatusYield",
    "UI_MinidoracatAutoDrive_HUDStatusUnstick",
    "UI_MinidoracatAutoDrive_HUDStatusBlocked",
    "UI_MinidoracatAutoDrive_HUDStatusDodging",
    "UI_MinidoracatAutoDrive_HUDStatusBuild",
    "UI_MinidoracatAutoDrive_HUDStatusFollow",
    "UI_MinidoracatAutoDrive_HUDStatusReady",
    "UI_MinidoracatAutoDrive_HUDStatusEngineOff",
    "UI_MinidoracatAutoDrive_HUDStatusNoRoute",
    "UI_MinidoracatAutoDrive_HUDStatusNoGPS",
    "UI_MinidoracatAutoDrive_HUDStatusNoNav",
    "UI_MinidoracatAutoDrive_HUDStatusNotReady",
}

-- 色票字面值留在 consumer：框架缺席時顏色仍完整（MiniMap_Skin.lua:27-42）。
local C = {
    glass = { r = 0.05, g = 0.065, b = 0.055, a = 0.88 },
    metalOuter = { r = 0.353, g = 0.353, b = 0.353, a = 1.0 }, -- #5A5A5A
    metalFace = { r = 0.204, g = 0.204, b = 0.204, a = 0.98 }, -- #343434
    border = { r = 0.353, g = 0.353, b = 0.353, a = 0.95 },
    highlight = { r = 0.42, g = 0.42, b = 0.42, a = 0.72 },
    shadow = { r = 0.025, g = 0.025, b = 0.025, a = 0.88 },
    screwEdge = { r = 0.08, g = 0.08, b = 0.08, a = 1.0 },
    text = { r = 0.93, g = 0.92, b = 0.87, a = 1.0 },
    muted = { r = 0.62, g = 0.64, b = 0.61, a = 1.0 },
    faint = { r = 0.38, g = 0.40, b = 0.38, a = 0.85 },
    green = { r = 0.47, g = 0.74, b = 0.45, a = 1.0 },
    amber = { r = 0.82, g = 0.66, b = 0.31, a = 1.0 },
    red = { r = 0.78, g = 0.40, b = 0.34, a = 1.0 },
    blue = { r = 0.43, g = 0.65, b = 0.70, a = 1.0 },
    button = { r = 0.02, g = 0.02, b = 0.02, a = 0.94 },
    buttonHover = { r = 0.16, g = 0.16, b = 0.16, a = 0.96 },
    selected = { r = 0.36, g = 0.27, b = 0.11, a = 0.92 },
    danger = { r = 0.30, g = 0.13, b = 0.12, a = 0.95 },
    start = { r = 0.12, g = 0.24, b = 0.13, a = 0.95 },
    transparent = { r = 0, g = 0, b = 0, a = 0 },
}

local FW = nil
do
    local ui = MinidoracatUI and MinidoracatUI.v1
    if ui and ui.API_MAJOR == 1 and ui.API_REVISION >= 1 and ui.Skin then
        FW = ui.Skin
    end
end

local modOptions = nil
local panels = {}

local function fill(element, x, y, w, h, color, shape)
    if FW then return FW.fill(element, x, y, w, h, color, shape) end
    element:drawRect(x, y, w, h, color.a or 1, color.r, color.g, color.b)
end

local function border(element, x, y, w, h, color, shape)
    if FW then return FW.border(element, x, y, w, h, color, shape) end
    element:drawRectBorder(x, y, w, h, color.a or 1, color.r, color.g, color.b)
end

local function dot(element, x, y, size, color)
    if FW then return FW.dot(element, x, y, size, color, C.screwEdge) end
    element:drawRectBorder(x - 1, y - 1, size + 2, size + 2,
        C.screwEdge.a, C.screwEdge.r, C.screwEdge.g, C.screwEdge.b)
    element:drawRect(x, y, size, size, color.a or 1, color.r, color.g, color.b)
end

local function roundPositive(v)
    if type(v) ~= "number" or v ~= v then return 0 end
    if v < 0 then v = -v end
    return math.floor(v + 0.5)
end

local function clampPercent(v, multiplier)
    if type(v) ~= "number" or v ~= v then return 0 end
    v = v * multiplier
    if v < 0 then v = 0 elseif v > 100 then v = 100 end
    return math.floor(v + 0.5)
end

local function optionIndex(id, default, maximum)
    if not modOptions then return default end
    local option = modOptions:getOption(id)
    local value = option and option:getValue()
    if type(value) ~= "number" or value < 1 or value > maximum then return default end
    return math.floor(value)
end

local function optionBool(id, default)
    if not modOptions then return default end
    local option = modOptions:getOption(id)
    local value = option and option:getValue()
    if type(value) ~= "boolean" then return default end
    return value
end

local function trajectoryVisible()
    return optionBool("ShowTrajectory", true)
end

local function trajectoryWidth()
    return optionIndex("TrajectoryWidth", TRAJECTORY_WIDTH_DEFAULT, 3)
end

local function setClientOption(id, value)
    if not modOptions then return false end
    local option = modOptions:getOption(id)
    if not option then return false end
    option:setValue(value)
    modOptions:apply()
    PZAPI.ModOptions:save()
    return true
end

local function setTrajectoryVisible(value)
    return setClientOption("ShowTrajectory", value == true)
end

local function setTrajectoryWidth(value)
    if type(value) ~= "number" or value ~= value then return false end
    value = math.floor(value)
    if value < 1 or value > 3 then return false end
    return setClientOption("TrajectoryWidth", value)
end

local function telemetryEnabled()
    return optionBool("ExportTelemetry", false)
end

local function telemetryRetentionDays()
    return RETENTION_DAYS[optionIndex("TelemetryRetentionDays", 3, 5)] or 7
end

local function setTelemetryEnabled(value)
    return setClientOption("ExportTelemetry", value == true)
end

local function setTelemetryRetentionDays(value)
    if type(value) ~= "number" or value ~= value then return false end
    value = math.floor(value)
    for i = 1, #RETENTION_DAYS do
        if RETENTION_DAYS[i] == value then
            return setClientOption("TelemetryRetentionDays", i)
        end
    end
    return false
end

local function setTelemetryRetentionIndex(value)
    if type(value) ~= "number" or value ~= value then return false end
    value = math.floor(value)
    if value < 1 or value > 5 then return false end
    return setClientOption("TelemetryRetentionDays", value)
end

local function copyLatestTelemetry(playerNum)
    local diag = MDADDiagnostics
    if diag and type(diag.copyLatestPath) == "function" then
        diag.copyLatestPath(playerNum)
    end
end

local function copyTelemetryFolder(playerNum)
    local diag = MDADDiagnostics
    if diag and type(diag.copyFolderPath) == "function" then
        diag.copyFolderPath(playerNum)
    end
end


local function optionScale()
    return SCALES[optionIndex("HUDScale", 2, 3)] or 1.0
end

local function scaled(value, scale)
    return math.floor(value * scale + 0.5)
end

local function textWidth(font, text)
    return getTextManager():MeasureStringX(font, text or "")
end

local function maximum(a, b)
    if a > b then return a end
    return b
end

local function visibleVehicle(playerObj)
    if not playerObj or not playerObj:isLocalPlayer() or playerObj:isDead() then return nil end
    local vehicle = playerObj:getVehicle()
    if not vehicle or not vehicle:isDriver(playerObj) then return nil end
    if MDAD.sandbox("NeedItemForAutoDrive", true) == true
        and not MDAD.isAutoInstalled(vehicle) then return nil end
    return vehicle
end

-- ESC 不會改 ISUIHandler.allUIVisible；權威狀態是 in-game MainScreen root。
-- ToggleEscapeMenu 先 setVisible、再 deferred removeFromUIManager
-- （MainScreen.lua:1728-1777），isReallyVisible 因此開關即刻收斂。
local function escapeMenuVisible()
    local screen = MainScreen and MainScreen.instance
    return screen and screen.inGame == true and screen:isReallyVisible() or false
end

local function dashboardVisible(dashboard)
    return dashboard and dashboard.vehicle ~= nil
        and (not dashboard.isReallyVisible or dashboard:isReallyVisible()) or false
end

local function effectivePolicy(name, playerNum, kind)
    local policy = MDAD.policy3(name, MDAD.POLICY_PLAYER)
    if policy == MDAD.POLICY_FORCE_ON then return true, policy end
    if policy == MDAD.POLICY_FORCE_OFF then return false, policy end
    return Drive.getSlowPref(playerNum, kind), policy
end

local function statusColor(token, reason)
    if reason then return C.red end
    if token == nil then return C.blue end
    if token == "blocked" then return C.red end
    if token == "dodging" or token == "unstick" then return C.amber end
    if token == "yield" or token == "build" then return C.blue end
    return C.green
end

local function setButtonRect(button, x, y, w, h)
    button:setX(x)
    button:setY(y)
    button:setWidth(w)
    button:setHeight(h)
end

-- ISButton:setEnable 會把建構時的顏色快照就地寫回自身 color table
-- （ISButton.lua:416-439）。先讓它完成，再逐欄複製 consumer 色票；絕不把
-- 共用 C.* table 指派給按鈕，否則 disabled 色會永久污染整份 HUD 色票。
local function copyRGBA(target, source)
    target.r, target.g, target.b, target.a = source.r, source.g, source.b, source.a
end

local function styleButton(button, background, text, enabled)
    button:setEnable(enabled ~= false)
    copyRGBA(button.backgroundColor, background)
    copyRGBA(button.backgroundColorMouseOver, C.buttonHover)
    copyRGBA(button.borderColor, C.border)
    copyRGBA(button.textColor, text)
end

-- 減速藥丸：標題／精確策略提示／配色／可否點擊全由
-- 「此刻有沒有在減速」×「政策是否交給玩家」決定。
local function applyPolicyButton(button, labelKey, on, playerChoice, tooltip)
    local valueKey
    if playerChoice then
        valueKey = on and "UI_MinidoracatAutoDrive_HUDOn"
            or "UI_MinidoracatAutoDrive_HUDOff"
    else
        valueKey = on and "UI_MinidoracatAutoDrive_HUDForcedOn"
            or "UI_MinidoracatAutoDrive_HUDForcedOff"
    end
    button:setTitle(getText(labelKey) .. " " .. getText(valueKey))
    button.tooltip = tooltip
    styleButton(button, on and C.start or C.button, on and C.green or C.muted, playerChoice)
end

local function makeButton(parent, title, callback, detached)
    local button = ISButton:new(0, 0, 10, 10, title, parent, callback)
    button:initialise()
    button.font = UIFont.Small
    styleButton(button, C.button, C.text, true)
    if not detached then parent:addChild(button) end
    return button
end

MDADHUDPanel = ISPanel:derive("MDADHUDPanel")

function MDADHUDPanel:new(playerNum)
    local o = ISPanel.new(self, 0, 0, 510, 78)
    o.background = false
    o.moveWithMouse = false
    o.playerNum = playerNum
    o.vehicle = nil
    o._nextMs = 0
    o._forceRefresh = true
    o._collapsed = false
    o._collapseLoaded = false
    o._dashboard = nil
    o._effectiveLayout = LAYOUT_FULL
    o._showStatusText = true
    o._style = STYLE_METAL
    o._layout = LAYOUT_FULL
    o._active = false
    o._gear = 3
    o._speedText = "0"
    o._capText = "--"
    o._energyText = ""
    o._statusText = ""
    o._unitText = ""
    o._capLabel = ""
    o._gearLabel = ""
    o._unitX = 0
    o._capLabelY = 0
    o._capValueX = 0
    o._capValueY = 0
    o._statusColor = C.blue
    o._zombieOn = true
    o._corpseOn = true
    o._zombiePolicy = MDAD.POLICY_PLAYER
    o._corpsePolicy = MDAD.POLICY_PLAYER
    o._reason = nil
    return o
end

function MDADHUDPanel:createChildren()
    self.gearButtons = {}
    for i = 1, 4 do
        local button = makeButton(self, GEAR_SHORT[i], MDADHUDPanel.onGear)
        button.internal = i
        button.tooltip = getText(GEAR_TOOLTIPS[i])
        self.gearButtons[i] = button
    end
    self.cycleButton = makeButton(self, GEAR_SHORT[3], MDADHUDPanel.onCycleGear)
    self.zombieButton = makeButton(self, "", MDADHUDPanel.onZombie)
    self.corpseButton = makeButton(self, "", MDADHUDPanel.onCorpse)
    self.actionButton = makeButton(self, getText("UI_MinidoracatAutoDrive_Start"), MDADHUDPanel.onAction)
    -- 收放鈕稍後掛成原版 ISVehicleDashboard child；detached=true 避免佔 HUD 欄位。
    self.collapseButton = makeButton(self, "v", MDADHUDPanel.onCollapse, true)
    self.themeButton = makeButton(self, "M/S", MDADHUDPanel.onTheme, true)
    self:applyLayout()
end

function MDADHUDPanel:loadCollapsed(playerObj)
    if self._collapseLoaded then return end
    local md = playerObj and playerObj:getModData()
    self._collapsed = md and md[COLLAPSED_MD_KEY] == true or false
    self._collapseLoaded = true
    self:applyLayout()
end

function MDADHUDPanel:setCollapsed(value)
    self._collapsed = value == true
    self._collapseLoaded = true
    local playerObj = getSpecificPlayer(self.playerNum)
    local md = playerObj and playerObj:getModData()
    if md then md[COLLAPSED_MD_KEY] = self._collapsed end
    self:applyLayout()
    self._forceRefresh = true
end

-- 三種佈局只切換 HUD 本體控件；收放鈕獨立掛在原版 dashboard。
function MDADHUDPanel:setControlsVisible(gearsOn, cycleOn, policiesOn, actionOn)
    for i = 1, 4 do self.gearButtons[i]:setVisible(gearsOn) end
    self.cycleButton:setVisible(cycleOn)
    self.zombieButton:setVisible(policiesOn)
    self.corpseButton:setVisible(policiesOn)
    self.actionButton:setVisible(actionOn)
end

function MDADHUDPanel:applyLayout()
    self._style = optionIndex("HUDTheme", STYLE_METAL, 2)
    self._layout = optionIndex("HUDLayout", LAYOUT_FULL, 2)
    local scale = optionScale()
    self._unitText = getText("UI_MinidoracatAutoDrive_HUDSpeedUnit")
    self._capLabel = getText("UI_MinidoracatAutoDrive_HUDCruiseCap")
    self._gearLabel = getText("UI_MinidoracatAutoDrive_HUDGear")
    local tm = getTextManager()
    local fontH = tm:getFontHeight(UIFont.Small)
    local mediumH = tm:getFontHeight(UIFont.Medium)
    local pad = maximum(6, scaled(8, scale))
    local gap = maximum(3, scaled(4, scale))
    local buttonH = maximum(fontH + 6, scaled(22, scale))
    local topH = maximum(mediumH + 4, maximum(buttonH, fontH * 2 + 2))
    local statusW = scaled(126, scale)
    for i = 1, #STATUS_WIDTH_KEYS do
        statusW = maximum(statusW,
            textWidth(UIFont.Small, getText(STATUS_WIDTH_KEYS[i])) + pad * 3)
    end
    local speedValueW = textWidth(UIFont.Medium, "120")
    local speedW = maximum(scaled(62, scale),
        speedValueW + 3 + textWidth(UIFont.Small, self._unitText) + gap)
    local capLabelW = textWidth(UIFont.Small, self._capLabel)
    local capValueW = textWidth(UIFont.Small, "120")
    local capW = maximum(scaled(48, scale), capLabelW + gap + capValueW + gap)
    local actionW = maximum(scaled(58, scale), maximum(
        textWidth(UIFont.Small, getText("UI_MinidoracatAutoDrive_Start")),
        textWidth(UIFont.Small, getText("UI_MinidoracatAutoDrive_Stop"))) + 16)
    local gearW = maximum(scaled(34, scale), textWidth(UIFont.Small, "MAX") + 12)
    local gearLabelW = textWidth(UIFont.Small, self._gearLabel) + gap
    local forcedText = getText("UI_MinidoracatAutoDrive_HUDForcedOff")
    local policyW = maximum(scaled(70, scale), maximum(
        textWidth(UIFont.Small, getText("UI_MinidoracatAutoDrive_HUDZombie") .. " " .. forcedText),
        textWidth(UIFont.Small, getText("UI_MinidoracatAutoDrive_HUDCorpse") .. " " .. forcedText)) + 14)
    local energyW = textWidth(UIFont.Small,
        getText("UI_MinidoracatAutoDrive_HUDEnergy", 100, 100)) + gap
    local cycleW = maximum(scaled(44, scale), textWidth(UIFont.Small, "MAX") + 14)
    local screenW = getPlayerScreenWidth(self.playerNum)
    local maxW = type(screenW) == "number" and screenW - 16 or 1904
    if maxW < 64 then maxW = 64 end
    local fullBase = scaled(510, scale)
    local compactBase = scaled(482, scale)
    if fullBase > maxW then fullBase = maxW end
    if compactBase > maxW then compactBase = maxW end

    local fullContentW = pad * 2 + gearLabelW + gearW * 4 + gap * 6
        + policyW * 2 + energyW
    local topContentW = pad * 2 + statusW + speedW + capW + gap + actionW
    if topContentW > fullContentW then fullContentW = topContentW end
    local fullW = maximum(fullBase, fullContentW)
    local compactPolicyContentW = pad * 2 + statusW + speedW + capW + cycleW
        + policyW * 2 + actionW + gap * 3
    local compactEssentialContentW = pad * 2 + statusW + speedW + capW + cycleW
        + actionW + gap

    local effectiveLayout = self._layout
    local showPolicies = true
    local showStatusText = true
    if effectiveLayout == LAYOUT_FULL and fullW > maxW then
        effectiveLayout = LAYOUT_COMPACT
    end
    local compactW = maximum(compactBase, compactPolicyContentW)
    if effectiveLayout == LAYOUT_COMPACT and compactW > maxW then
        showPolicies = false
        compactW = maximum(compactBase, compactEssentialContentW)
    end
    if effectiveLayout == LAYOUT_COMPACT and compactW > maxW then
        -- 極窄分割畫面：保留狀態燈，省掉狀態文字；其餘控制仍可操作。
        showStatusText = false
        statusW = scaled(24, scale)
        compactEssentialContentW = pad * 2 + statusW + speedW + capW + cycleW
            + actionW + gap
        compactW = maximum(compactBase, compactEssentialContentW)
    end
    if compactW > maxW then compactW = maxW end
    self._effectiveLayout = effectiveLayout
    self._showStatusText = showStatusText

    local panelW
    local panelH
    if self._collapsed then
        panelW = maximum(scaled(68, scale), pad + 16 + speedValueW + pad)
        if panelW > maxW then panelW = maxW end
        panelH = maximum(scaled(34, scale), fontH + pad * 2)
        self:setControlsVisible(false, false, false, false)
        self._dotX = pad
        self._dotY = math.floor((panelH - 8) / 2)
        self._speedX = pad + 16
        self._speedY = math.floor((panelH - mediumH) / 2)
    elseif effectiveLayout == LAYOUT_COMPACT then
        panelW = compactW
        panelH = maximum(scaled(44, scale), buttonH + pad * 2)
        self:setControlsVisible(false, true, showPolicies, true)
        local y = math.floor((panelH - buttonH) / 2)
        local x = pad + statusW + speedW + capW
        setButtonRect(self.cycleButton, x, y, cycleW, buttonH)
        if showPolicies then
            x = x + cycleW + gap
            setButtonRect(self.zombieButton, x, y, policyW, buttonH)
            x = x + policyW + gap
            setButtonRect(self.corpseButton, x, y, policyW, buttonH)
        end
        setButtonRect(self.actionButton, panelW - pad - actionW, y, actionW, buttonH)
        self._dotX = pad
        self._dotY = math.floor((panelH - 8) / 2)
        self._statusX = pad + 16
        self._textY = math.floor((panelH - fontH) / 2)
        self._speedX = pad + statusW
        self._speedY = math.floor((panelH - mediumH) / 2)
        self._capX = pad + statusW + speedW
        self._capLabelY = self._textY
        self._capValueX = self._capX + capLabelW + gap
        self._capValueY = self._textY
    else
        panelW = fullW
        panelH = maximum(scaled(78, scale), pad * 2 + topH + buttonH + gap * 2 + 1)
        self:setControlsVisible(true, false, true, true)
        local topY = pad
        local bottomY = panelH - pad - buttonH
        setButtonRect(self.actionButton, panelW - pad - actionW, topY, actionW, topH)
        local x = pad + gearLabelW
        for i = 1, 4 do
            setButtonRect(self.gearButtons[i], x, bottomY, gearW, buttonH)
            x = x + gearW + gap
        end
        setButtonRect(self.zombieButton, x, bottomY, policyW, buttonH)
        x = x + policyW + gap
        setButtonRect(self.corpseButton, x, bottomY, policyW, buttonH)
        self._dotX = pad
        self._dotY = topY + math.floor((topH - 8) / 2)
        self._statusX = pad + 16
        self._textY = topY + math.floor((topH - fontH) / 2)
        self._speedX = pad + statusW
        self._speedY = topY + math.floor((topH - mediumH) / 2)
        self._capX = pad + statusW + speedW
        self._capLabelY = topY
        self._capValueX = self._capX
        self._capValueY = topY + fontH
        self._labelX = pad
        self._bottomTextY = bottomY + math.floor((buttonH - fontH) / 2)
        self._energyX = panelW - pad - energyW
        self._dividerY = bottomY - gap - 1
    end

    self.collapseButton:setTitle(self._collapsed and "^" or "v")
    -- option/resolution apply 會先於下一次 250ms refresh；同步重算單位 x，
    -- 避免切 layout 後一幀仍沿用舊 speedX。
    self._unitX = self._speedX + textWidth(UIFont.Medium, self._speedText) + 3
    self:setWidth(panelW)
    self:setHeight(panelH)
    self:reposition()
end

function MDADHUDPanel:setHudVisible(visible)
    self:setVisible(visible)
    if self.collapseButton then self.collapseButton:setVisible(visible) end
    if self.themeButton then self.themeButton:setVisible(visible and modOptions ~= nil) end
end

-- ESC 開啟時的唯一收斂動作；update 與 prerender 兩條 tick 路徑共用，
-- 回傳 true 代表本幀已隱藏、呼叫端直接 return。
function MDADHUDPanel:hideIfEscapeMenu()
    if not escapeMenuVisible() then return false end
    self:setHudVisible(false)
    self._forceRefresh = true
    return true
end

-- 「兩顆控制都在這個 dashboard 上」是 update 與 prerender 共用的唯一真相：
-- _dashboard 是我們記的身分，getParent 是原版真的持有的關係，兩邊都得對上。
function MDADHUDPanel:controlsAttached(dashboard)
    return self._dashboard == dashboard
        and self.collapseButton:getParent() == dashboard
        and (not modOptions or self.themeButton:getParent() == dashboard)
end

-- dashboard 的 UIManager membership／identity 不屬於 250ms 車況資料；
-- 每個 UI tick（約 100ms）先收斂，手把 inventory 或 split-screen 重建不殘影。
function MDADHUDPanel:syncDashboardBeforeRefresh()
    local dashboard = getPlayerVehicleDashboard(self.playerNum)
    if not dashboardVisible(dashboard) then
        self:setHudVisible(false)
        self._forceRefresh = true
        return false
    end
    if not self:controlsAttached(dashboard) then
        self:attachDashboardButton(dashboard)
        self:applyLayout()
        self._forceRefresh = true
    end
    return true
end

function MDADHUDPanel:dashboardAttachedAndVisible()
    local dashboard = getPlayerVehicleDashboard(self.playerNum)
    return dashboardVisible(dashboard) and self:controlsAttached(dashboard)
end

-- 兩顆控制都掛在原版 dashboard；PZAPI 缺席時主題鈕不承諾可用、也不掛載。
function MDADHUDPanel:attachDashboardButton(dashboard)
    if not dashboard then return false end
    local collapse = self.collapseButton
    local theme = self.themeButton
    if collapse:getParent() ~= dashboard then dashboard:addChild(collapse) end
    if modOptions and theme:getParent() ~= dashboard then dashboard:addChild(theme) end
    self._dashboard = dashboard
    self:positionDashboardButton()
    return true
end

function MDADHUDPanel:positionDashboardButton()
    local dashboard = self._dashboard
    if not dashboard then return end
    local tex = dashboard.backgroundTex
    local width = tex and tex:getWidth() or dashboard:getWidth()
    local size = DASH_CONTROL_SIZE
    -- atlas row 7 起才是可見 #343434 面板；右側斜角透明至約 x=W-58。
    local collapseX = width - DASH_CONTROL_RIGHT_INSET - size
    if collapseX < DASH_THEME_CONTROL_WIDTH + DASH_CONTROL_GAP + 4 then
        collapseX = DASH_THEME_CONTROL_WIDTH + DASH_CONTROL_GAP + 4
    end
    local themeX = collapseX - DASH_CONTROL_GAP - DASH_THEME_CONTROL_WIDTH
    if modOptions then
        setButtonRect(self.themeButton, themeX, DASH_CONTROL_Y,
            DASH_THEME_CONTROL_WIDTH, size)
    end
    setButtonRect(self.collapseButton, collapseX, DASH_CONTROL_Y, size, size)
end

function MDADHUDPanel:reposition()
    local playerNum = self.playerNum
    local left = getPlayerScreenLeft(playerNum)
    local top = getPlayerScreenTop(playerNum)
    local width = getPlayerScreenWidth(playerNum)
    local height = getPlayerScreenHeight(playerNum)
    local dashboard = getPlayerVehicleDashboard(playerNum)
    -- attachDashboardButton 自己每次重驗 identity 並重放鈕位，這裡不複製條件。
    self:attachDashboardButton(dashboard)
    local dashboardH = 120
    local dashboardY = nil
    if dashboard then
        if dashboard.backgroundTex then dashboardH = dashboard.backgroundTex:getHeight()
        elseif dashboard.getHeight then dashboardH = dashboard:getHeight() end
        if dashboard.getY then dashboardY = dashboard:getY() end
    end
    local x = left + math.floor((width - self.width) / 2)
    -- element row 0-6 是透明斜角；HUD 向下 overlap 7px，底邊正好碰到第一列
    -- 可見 dashboard 像素，而不是只貼到看不見的 element 邊界。
    local y = dashboardY and (dashboardY - self.height + DASH_VISIBLE_TOP_INSET)
        or (top + height - dashboardH - self.height)
    if y < top + 4 then y = top + 4 end
    self:setX(x)
    self:setY(y)
end

function MDADHUDPanel:refresh(now)
    self._nextMs = now + REFRESH_MS
    self._forceRefresh = false
    local playerObj = getSpecificPlayer(self.playerNum)
    local vehicle = visibleVehicle(playerObj)
    if not vehicle then
        self.vehicle = nil
        self:setHudVisible(false)
        return
    end
    self:loadCollapsed(playerObj)
    self.vehicle = vehicle
    local dashboard = getPlayerVehicleDashboard(self.playerNum)
    -- attach 先跑：即使 dashboard 這一刻不可見，reparent／鈕位也要收斂。
    if not self:attachDashboardButton(dashboard)
        or not dashboardVisible(dashboard)
        or escapeMenuVisible()
        or (ISUIHandler and ISUIHandler.allUIVisible == false) then
        self:setHudVisible(false)
        self._forceRefresh = true
        return
    end
    self:setHudVisible(true)
    self:reposition()

    local token, gear, cap, zombieOn, corpseOn = Drive.hudState(self.playerNum)
    local reason = nil
    self._active = token ~= nil
    -- 政策三態（藥丸鎖不鎖）與 session 無關，兩種狀態都要讀。啟用中「此刻要不要
    -- 減速」以 hudState 的 session 快取為準，停用態才顯示政策×偏好的合成值。
    local policyZombieOn, policyCorpseOn
    policyZombieOn, self._zombiePolicy = effectivePolicy(
        "ZombieAreaSlowdown", self.playerNum, "zombie")
    policyCorpseOn, self._corpsePolicy = effectivePolicy(
        "CorpseSlowdown", self.playerNum, "corpse")
    if self._active then
        self._statusText = getText(STATUS_KEYS[token] or STATUS_KEYS.follow)
    else
        reason = Drive.hudStartReason(self.playerNum)
        self._statusText = getText(REASON_KEYS[reason]
            or (reason and "UI_MinidoracatAutoDrive_HUDStatusNotReady"
                or "UI_MinidoracatAutoDrive_HUDStatusReady"))
        gear = Drive.getGear(self.playerNum)
        cap = Drive.effectiveCap(self.playerNum, vehicle)
        zombieOn = policyZombieOn
        corpseOn = policyCorpseOn
    end
    self._reason = reason
    self._gear = gear or Drive.getGear(self.playerNum)
    self._zombieOn = zombieOn == true
    self._corpseOn = corpseOn == true
    self._statusColor = statusColor(token, reason)
    self._speedText = tostring(roundPositive(vehicle:getCurrentSpeedKmHour()))
    self._unitX = self._speedX + textWidth(UIFont.Medium, self._speedText) + 3
    self._capText = cap and tostring(roundPositive(cap)) or "--"
    local battery = clampPercent(vehicle:getBatteryCharge(), 100)
    local fuel = clampPercent(vehicle:getRemainingFuelPercentage(), 1)
    self._energyText = getText("UI_MinidoracatAutoDrive_HUDEnergy", battery, fuel)
    self:updateButtons()
end

function MDADHUDPanel:updateButtons()
    for i = 1, 4 do
        styleButton(self.gearButtons[i], i == self._gear and C.selected or C.button,
            i == self._gear and C.amber or C.text, true)
    end
    self.cycleButton:setTitle(GEAR_SHORT[self._gear] or "--")
    styleButton(self.cycleButton, C.selected, C.amber, true)

    local nearM, aheadM, bandM, zombieCap1, zombieCap4, zombieCap8, corpseCap =
        Drive.slowdownInfo(self.playerNum)
    local playerChoiceZombie = self._zombiePolicy == MDAD.POLICY_PLAYER
    local playerChoiceCorpse = self._corpsePolicy == MDAD.POLICY_PLAYER
    local zombieTip = getText(self._zombieOn
            and "UI_MinidoracatAutoDrive_HUDZombieTipOn"
            or "UI_MinidoracatAutoDrive_HUDZombieTipOff",
        nearM, aheadM, bandM, zombieCap1, zombieCap4, zombieCap8)
        .. "\n" .. getText(playerChoiceZombie
            and "UI_MinidoracatAutoDrive_HUDPolicyToggle"
            or (self._zombieOn and "UI_MinidoracatAutoDrive_HUDPolicyLockedOn"
                or "UI_MinidoracatAutoDrive_HUDPolicyLockedOff"))
    local corpseTip = getText(self._corpseOn
            and "UI_MinidoracatAutoDrive_HUDCorpseTipOn"
            or "UI_MinidoracatAutoDrive_HUDCorpseTipOff",
        nearM, aheadM, bandM, corpseCap)
        .. "\n" .. getText(playerChoiceCorpse
            and "UI_MinidoracatAutoDrive_HUDPolicyToggle"
            or (self._corpseOn and "UI_MinidoracatAutoDrive_HUDPolicyLockedOn"
                or "UI_MinidoracatAutoDrive_HUDPolicyLockedOff"))
    applyPolicyButton(self.zombieButton, "UI_MinidoracatAutoDrive_HUDZombie",
        self._zombieOn, playerChoiceZombie, zombieTip)
    applyPolicyButton(self.corpseButton, "UI_MinidoracatAutoDrive_HUDCorpse",
        self._corpseOn, playerChoiceCorpse, corpseTip)

    self.actionButton:setTitle(getText(self._active
        and "UI_MinidoracatAutoDrive_Stop" or "UI_MinidoracatAutoDrive_Start"))
    self.actionButton.tooltip = self._reason and getText(self._reason) or nil
    styleButton(self.actionButton, self._active and C.danger or C.start,
        self._active and C.red or C.green, true)
    self.collapseButton.tooltip = getText(self._collapsed
        and "UI_MinidoracatAutoDrive_HUDExpand"
        or "UI_MinidoracatAutoDrive_HUDCollapse")
    styleButton(self.collapseButton, C.button, C.muted, true)
    if modOptions then
        local themeKey = self._style == STYLE_METAL
            and "UI_MinidoracatAutoDrive_HUDThemeMetal"
            or "UI_MinidoracatAutoDrive_HUDThemeMinimal"
        self.themeButton:setTitle("M/S")
        self.themeButton.tooltip = getText("UI_MinidoracatAutoDrive_HUDTheme")
            .. ": " .. getText(themeKey)
        styleButton(self.themeButton, C.button, C.muted, true)
    end
end

function MDADHUDPanel:update()
    -- ESC options 需比 250ms 資料 refresh 更快消失；UIElement.update 本身約 10Hz。
    if self:hideIfEscapeMenu() then return end
    if not self:syncDashboardBeforeRefresh() then return end
    local now = getTimestampMs()
    if not self._forceRefresh and now < self._nextMs then return end
    self:refresh(now)
end

function MDADHUDPanel:drawBackground()
    if self._style == STYLE_MINIMAL then
        fill(self, 0, 0, self.width, self.height, C.glass, "round")
        border(self, 0, 0, self.width, self.height, C.border, "round")
        return
    end
    -- 原版 dashboard 是 #343434 平面＋#5A5A5A 斜角，不是亮面圓角金屬。
    -- 三段矩形做 6px chamfer；外框本身就是 bevel，不再疊螺絲／圓角九宮格。
    local w, h = self.width, self.height
    -- 六段只差 x/y；顏色先拆成純量（每幀欄位查表 48 → 10 次），幾何也一眼可讀。
    local edge, face = C.metalOuter, C.metalFace
    local ea, er, eg, eb = edge.a, edge.r, edge.g, edge.b
    local fa, fr, fg, fb = face.a, face.r, face.g, face.b
    self:drawRect(6, 0, w - 12, h, ea, er, eg, eb)
    self:drawRect(3, 3, w - 6, h - 6, ea, er, eg, eb)
    self:drawRect(0, 6, w, h - 12, ea, er, eg, eb)
    self:drawRect(8, 2, w - 16, h - 4, fa, fr, fg, fb)
    self:drawRect(5, 5, w - 10, h - 10, fa, fr, fg, fb)
    self:drawRect(2, 8, w - 4, h - 16, fa, fr, fg, fb)
    self:drawRect(8, 2, w - 16, 1,
        C.highlight.a, C.highlight.r, C.highlight.g, C.highlight.b)
    self:drawRect(8, h - 4, w - 16, 2,
        C.shadow.a, C.shadow.r, C.shadow.g, C.shadow.b)
end

function MDADHUDPanel:prerender()
    if self:hideIfEscapeMenu() then return end
    if not self:dashboardAttachedAndVisible() then
        self:setHudVisible(false)
        self._forceRefresh = true
        return
    end
    if not self.vehicle or (ISUIHandler and ISUIHandler.allUIVisible == false) then
        self:setHudVisible(false)
        self._forceRefresh = true
        return
    end
    self:drawBackground()
    dot(self, self._dotX, self._dotY, 8, self._statusColor)
    if self._collapsed then
        self:drawText(self._speedText, self._speedX, self._speedY,
            C.text.r, C.text.g, C.text.b, C.text.a, UIFont.Medium)
        return
    end
    if self._showStatusText then
        self:drawText(self._statusText, self._statusX, self._textY,
            C.text.r, C.text.g, C.text.b, C.text.a, UIFont.Small)
    end
    self:drawText(self._speedText, self._speedX, self._speedY,
        C.text.r, C.text.g, C.text.b, C.text.a, UIFont.Medium)
    self:drawText(self._unitText, self._unitX, self._textY,
        C.muted.r, C.muted.g, C.muted.b, C.muted.a, UIFont.Small)
    self:drawText(self._capLabel, self._capX, self._capLabelY,
        C.muted.r, C.muted.g, C.muted.b, C.muted.a, UIFont.Small)
    self:drawText(self._capText, self._capValueX, self._capValueY,
        C.amber.r, C.amber.g, C.amber.b, C.amber.a, UIFont.Small)
    if self._effectiveLayout == LAYOUT_FULL then
        self:drawRect(4, self._dividerY, self.width - 8, 1,
            C.faint.a, C.faint.r, C.faint.g, C.faint.b)
        self:drawText(self._gearLabel,
            self._labelX, self._bottomTextY,
            C.muted.r, C.muted.g, C.muted.b, C.muted.a, UIFont.Small)
        self:drawText(self._energyText, self._energyX, self._bottomTextY,
            C.muted.r, C.muted.g, C.muted.b, C.muted.a, UIFont.Small)
    end
end

function MDADHUDPanel:onGear(button)
    Drive.setGear(self.playerNum, button.internal)
    self._forceRefresh = true
    self:refresh(getTimestampMs())
end

function MDADHUDPanel:onCycleGear()
    Drive.cycleGear(self.playerNum)
    self._forceRefresh = true
    self:refresh(getTimestampMs())
end

function MDADHUDPanel:onZombie()
    if self._zombiePolicy ~= MDAD.POLICY_PLAYER then return end
    Drive.setSlowPref(self.playerNum, "zombie", not self._zombieOn)
    self._forceRefresh = true
    self:refresh(getTimestampMs())
end

function MDADHUDPanel:onCorpse()
    if self._corpsePolicy ~= MDAD.POLICY_PLAYER then return end
    Drive.setSlowPref(self.playerNum, "corpse", not self._corpseOn)
    self._forceRefresh = true
    self:refresh(getTimestampMs())
end

function MDADHUDPanel:onAction()
    local playerObj = getSpecificPlayer(self.playerNum)
    if playerObj then Drive.toggle(playerObj) end
    self._forceRefresh = true
    self:refresh(getTimestampMs())
end

function MDADHUDPanel:onCollapse()
    self:setCollapsed(not self._collapsed)
end

function MDADHUDPanel:onTheme()
    if not modOptions then return end
    local option = modOptions:getOption("HUDTheme")
    option:setValue(self._style == STYLE_METAL and STYLE_MINIMAL or STYLE_METAL)
    modOptions:apply()
    PZAPI.ModOptions:save()
    self._forceRefresh = true
    self:refresh(getTimestampMs())
end

local function ensurePanel(playerNum)
    local panel = panels[playerNum]
    if panel then return panel end
    panel = MDADHUDPanel:new(playerNum)
    panel:initialise()
    panel:instantiate()
    panel:setVisible(false)
    -- 與原版 ISVehicleDashboard 同屬一般 UIManager 層；禁止 always-on-top，否則沙盒
    -- 選項／管理視窗會被 HUD 蓋住。後開的 modal 自然在 HUD 上方。
    panel:addToUIManager()
    panels[playerNum] = panel
    return panel
end

-- 原版 removeChild 不清 Lua `parent`（ISUIElement.lua:1480-1506）；銷毀路徑
-- 逐顆歸 nil，避免孤兒參照。
local function detachControl(button)
    if not button then return end
    if button:getParent() then button:detachFromParent() end
    button.parent = nil
end

local function destroyPanel(playerNum)
    local panel = panels[playerNum]
    if not panel then return end
    panel:setHudVisible(false)
    detachControl(panel.collapseButton)
    detachControl(panel.themeButton)
    panel._dashboard = nil
    panel:removeFromUIManager()
    panels[playerNum] = nil
end

local function destroyAll()
    for playerNum = 0, 3 do destroyPanel(playerNum) end
end

local function refreshCharacter(character)
    if not (character and instanceof(character, "IsoPlayer") and character:isLocalPlayer()) then return end
    local panel = ensurePanel(character:getPlayerNum())
    panel._forceRefresh = true
    panel:refresh(getTimestampMs())
end

local function applyAllOptions()
    for playerNum = 0, 3 do
        local panel = panels[playerNum]
        if panel then
            panel:applyLayout()
            panel._forceRefresh = true
        end
    end
    if type(MDADOverlay) == "table" then
        if type(MDADOverlay.setTrajectoryWidth) == "function" then
            MDADOverlay.setTrajectoryWidth(trajectoryWidth())
        end
        if not trajectoryVisible() and type(MDADOverlay.clearTrail) == "function" then
            MDADOverlay.clearTrail()
        end
    end
end

-- client 偏好必須在 MainOptions:create 前於頂層註冊；MainOptions.lua:2796 load、
-- :3760-3766 apply+save。combobox load 只驗 tonumber，讀取端 optionIndex 另做值域防禦。
if PZAPI and PZAPI.ModOptions then
    modOptions = PZAPI.ModOptions:create(OPTION_ID, "UI_MinidoracatAutoDrive_Options")
    modOptions:addDescription("UI_MinidoracatAutoDrive_OptionsDescription")
    modOptions:addTickBox("ShowTrajectory", "UI_MinidoracatAutoDrive_ShowTrajectory", true,
        "UI_MinidoracatAutoDrive_ShowTrajectory_tooltip")
    local trajectoryWidthOption = modOptions:addComboBox("TrajectoryWidth",
        "UI_MinidoracatAutoDrive_TrajectoryWidth")
    trajectoryWidthOption:addItem("UI_MinidoracatAutoDrive_TrajectoryWidthThin", false)
    trajectoryWidthOption:addItem("UI_MinidoracatAutoDrive_TrajectoryWidthStandard", true)
    trajectoryWidthOption:addItem("UI_MinidoracatAutoDrive_TrajectoryWidthThick", false)
    modOptions:addTickBox("ExportTelemetry", "UI_MinidoracatAutoDrive_ExportTelemetry", false,
        "UI_MinidoracatAutoDrive_ExportTelemetry_tooltip")
    local telemetryRetention = modOptions:addComboBox("TelemetryRetentionDays",
        "UI_MinidoracatAutoDrive_TelemetryRetentionDays")
    telemetryRetention:addItem("UI_MinidoracatAutoDrive_TelemetryRetention1", false)
    telemetryRetention:addItem("UI_MinidoracatAutoDrive_TelemetryRetention3", false)
    telemetryRetention:addItem("UI_MinidoracatAutoDrive_TelemetryRetention7", true)
    telemetryRetention:addItem("UI_MinidoracatAutoDrive_TelemetryRetention14", false)
    telemetryRetention:addItem("UI_MinidoracatAutoDrive_TelemetryRetention30", false)
    local theme = modOptions:addComboBox("HUDTheme", "UI_MinidoracatAutoDrive_HUDTheme")
    theme:addItem("UI_MinidoracatAutoDrive_HUDThemeMetal", true)
    theme:addItem("UI_MinidoracatAutoDrive_HUDThemeMinimal", false)
    local layout = modOptions:addComboBox("HUDLayout", "UI_MinidoracatAutoDrive_HUDLayout")
    layout:addItem("UI_MinidoracatAutoDrive_HUDLayoutFull", true)
    layout:addItem("UI_MinidoracatAutoDrive_HUDLayoutCompact", false)
    local scale = modOptions:addComboBox("HUDScale", "UI_MinidoracatAutoDrive_HUDScale")
    scale:addItem("UI_MinidoracatAutoDrive_HUDScale75", false)
    scale:addItem("UI_MinidoracatAutoDrive_HUDScale100", true)
    scale:addItem("UI_MinidoracatAutoDrive_HUDScale125", false)
    function modOptions:apply()
        applyAllOptions()
    end
end

local function onGameStart()
    if isServer() then return end
    destroyAll()
    local count = getNumActivePlayers()
    for playerNum = 0, count - 1 do
        local playerObj = getSpecificPlayer(playerNum)
        if playerObj then refreshCharacter(playerObj) end
    end
end

local function onCreatePlayer()
    -- vanilla createPlayerData 會對所有 active slot 重建 dashboard，且 split-screen
    -- 同時改每人 viewport；所有既有 panel 都要重算 layout＋立即 reparent。
    local now = getTimestampMs()
    for playerNum = 0, 3 do
        local playerObj = getSpecificPlayer(playerNum)
        if playerObj then
            local panel = ensurePanel(playerNum)
            panel:applyLayout()
            panel._forceRefresh = true
            panel:refresh(now)
        end
    end
end

local function onPlayerDeath(playerObj)
    if playerObj and playerObj:isLocalPlayer() then destroyPanel(playerObj:getPlayerNum()) end
end

HUD.Panel = MDADHUDPanel
HUD.ensure = ensurePanel
HUD.refresh = refreshCharacter
HUD.applyOptions = applyAllOptions
HUD.destroyAll = destroyAll
HUD.modOptions = modOptions
HUD.trajectoryVisible = trajectoryVisible
HUD.trajectoryWidth = trajectoryWidth
HUD.setTrajectoryVisible = setTrajectoryVisible
HUD.setTrajectoryWidth = setTrajectoryWidth
HUD.telemetryEnabled = telemetryEnabled
HUD.telemetryRetentionDays = telemetryRetentionDays
HUD.setTelemetryEnabled = setTelemetryEnabled
HUD.setTelemetryRetentionDays = setTelemetryRetentionDays
MDAD.HUD = HUD

-- MiniMap 齒輪視窗的 addon section：值與 ESC MOD Options 共用同一 option 物件，
-- MiniMap 只當第二個 UI 入口，不複製設定、不碰伺服器。
local miniMapSettingsApi = 0
local function registerMiniMapSettings()
    local api = MinidoracatMiniMapAPI
    if not (api and type(api.settingsApiVersion) == "number"
            and api.settingsApiVersion >= 1
            and type(api.registerSettingsSection) == "function") then return end
    if miniMapSettingsApi >= api.settingsApiVersion then return end
    local spec = {
        label = "UI_MinidoracatAutoDrive_Options",
        ticks = {
            { label = "UI_MinidoracatAutoDrive_ShowTrajectory",
                tooltip = "UI_MinidoracatAutoDrive_ShowTrajectory_tooltip",
                get = trajectoryVisible, set = setTrajectoryVisible },
            { label = "UI_MinidoracatAutoDrive_ExportTelemetry",
                tooltip = "UI_MinidoracatAutoDrive_ExportTelemetry_tooltip",
                get = telemetryEnabled, set = setTelemetryEnabled },
        },
        combos = {
            { label = "UI_MinidoracatAutoDrive_TrajectoryWidth",
                tooltip = "UI_MinidoracatAutoDrive_TrajectoryWidth_tooltip",
                items = {
                    "UI_MinidoracatAutoDrive_TrajectoryWidthThin",
                    "UI_MinidoracatAutoDrive_TrajectoryWidthStandard",
                    "UI_MinidoracatAutoDrive_TrajectoryWidthThick",
                },
                default = TRAJECTORY_WIDTH_DEFAULT,
                get = trajectoryWidth, set = setTrajectoryWidth },
            { label = "UI_MinidoracatAutoDrive_TelemetryRetentionDays",
                tooltip = "UI_MinidoracatAutoDrive_TelemetryRetentionDays_tooltip",
                items = {
                    "UI_MinidoracatAutoDrive_TelemetryRetention1",
                    "UI_MinidoracatAutoDrive_TelemetryRetention3",
                    "UI_MinidoracatAutoDrive_TelemetryRetention7",
                    "UI_MinidoracatAutoDrive_TelemetryRetention14",
                    "UI_MinidoracatAutoDrive_TelemetryRetention30",
                },
                default = 3,
                get = function()
                    return optionIndex("TelemetryRetentionDays", 3, 5)
                end,
                set = setTelemetryRetentionIndex },
        },
    }
    if api.settingsApiVersion >= 2 then
        spec.actions = {
            { label = "UI_MinidoracatAutoDrive_CopyLatestTelemetry",
                tooltip = "UI_MinidoracatAutoDrive_CopyLatestTelemetry_tooltip",
                run = copyLatestTelemetry },
            { label = "UI_MinidoracatAutoDrive_CopyTelemetryFolder",
                tooltip = "UI_MinidoracatAutoDrive_CopyTelemetryFolder_tooltip",
                run = copyTelemetryFolder },
        }
    end
    if api.registerSettingsSection(MDAD.MOD_ID, spec) == true then
        miniMapSettingsApi = api.settingsApiVersion
    end
end

registerMiniMapSettings()
Events.OnGameBoot.Add(registerMiniMapSettings)

-- Events 簽章與載入存檔已在車內的補救：ISVehicleDashboard.lua:601-633、717-720；
-- OnCreatePlayer(playerIndex, playerObj)：LuaManager.java:3955／AddCoopPlayer.java:162。
Events.OnEnterVehicle.Add(refreshCharacter)
Events.OnExitVehicle.Add(refreshCharacter)
Events.OnSwitchVehicleSeat.Add(refreshCharacter)
Events.OnCreatePlayer.Add(onCreatePlayer)
Events.OnPlayerDeath.Add(onPlayerDeath)
Events.OnResolutionChange.Add(applyAllOptions)
Events.OnGameStart.Add(onGameStart)
Events.OnMainMenuEnter.Add(destroyAll)
