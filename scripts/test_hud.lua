-- MDAD_HUD.lua 離線行為測試：假 ISUI/PZAPI 驅動 production HUD。
-- 測可見性、250ms getter 節流、按鈕入口、政策鎖、收合持久化、ModOptions、
-- MiniMap v1/v2 設定、telemetry 預設／setter 與零 getter render。

local assertions = 0
local failures = 0

local function check(value, label)
    assertions = assertions + 1
    if value then return end
    failures = failures + 1
    io.stderr:write("FAIL " .. label .. "\n")
end

local function checkEq(actual, expected, label)
    check(actual == expected, label .. " (expected=" .. tostring(expected)
        .. ", actual=" .. tostring(actual) .. ")")
end

local function makeEvent()
    local event = { handlers = {} }
    event.Add = function(fn)
        event.handlers[#event.handlers + 1] = fn
    end
    return event
end

Events = {
    OnEnterVehicle = makeEvent(),
    OnExitVehicle = makeEvent(),
    OnSwitchVehicleSeat = makeEvent(),
    OnCreatePlayer = makeEvent(),
    OnPlayerDeath = makeEvent(),
    OnResolutionChange = makeEvent(),
    OnGameStart = makeEvent(),
    OnGameBoot = makeEvent(),
    OnMainMenuEnter = makeEvent(),
}

local function fire(event, ...)
    for i = 1, #event.handlers do event.handlers[i](...) end
end

local texts = {
    UI_MinidoracatAutoDrive_Start = "START",
    UI_MinidoracatAutoDrive_Stop = "STOP",
    UI_MinidoracatAutoDrive_GearChill = "CHILL",
    UI_MinidoracatAutoDrive_GearStandard = "STANDARD",
    UI_MinidoracatAutoDrive_GearSport = "SPORT",
    UI_MinidoracatAutoDrive_GearInsane = "MAX",
    UI_MinidoracatAutoDrive_HUDStatusArrive = "ARRIVE",
    UI_MinidoracatAutoDrive_HUDStatusYield = "YIELD",
    UI_MinidoracatAutoDrive_HUDStatusUnstick = "UNSTICK",
    UI_MinidoracatAutoDrive_HUDStatusBlocked = "BLOCKED",
    UI_MinidoracatAutoDrive_HUDStatusDodging = "DODGE",
    UI_MinidoracatAutoDrive_HUDStatusBuild = "BUILD",
    UI_MinidoracatAutoDrive_HUDStatusFollow = "FOLLOW",
    UI_MinidoracatAutoDrive_HUDStatusReady = "READY",
    UI_MinidoracatAutoDrive_HUDStatusEngineOff = "ENGINE OFF",
    UI_MinidoracatAutoDrive_HUDStatusNoRoute = "NO ROUTE",
    UI_MinidoracatAutoDrive_HUDStatusNoGPS = "NO GPS",
    UI_MinidoracatAutoDrive_HUDStatusNoNav = "NO NAV",
    UI_MinidoracatAutoDrive_HUDStatusNotReady = "NOT READY",
    UI_MinidoracatAutoDrive_HUDSpeedUnit = "km/h",
    UI_MinidoracatAutoDrive_HUDCruiseCap = "CRUISE",
    UI_MinidoracatAutoDrive_HUDGear = "MODE",
    UI_MinidoracatAutoDrive_HUDEnergy = "BAT %1%% FUEL %2%%",
    UI_MinidoracatAutoDrive_HUDZombie = "Z",
    UI_MinidoracatAutoDrive_HUDCorpse = "C",
    UI_MinidoracatAutoDrive_HUDOn = "ON",
    UI_MinidoracatAutoDrive_HUDOff = "OFF",
    UI_MinidoracatAutoDrive_HUDForcedOn = "LOCK ON",
    UI_MinidoracatAutoDrive_HUDForcedOff = "LOCK OFF",
    UI_MinidoracatAutoDrive_HUDPolicyToggle = "TOGGLE",
    UI_MinidoracatAutoDrive_HUDPolicyLocked = "LOCKED",
    UI_MinidoracatAutoDrive_HUDPolicyLockedOn = "LOCKED ON NOTE",
    UI_MinidoracatAutoDrive_HUDPolicyLockedOff = "LOCKED OFF SAFETY",
    UI_MinidoracatAutoDrive_HUDZombieTipOn = "Z DETECT %1-%2 BAND %3\nZ CAPS %4/%5/%6\nZ NON-OBSTACLE",
    UI_MinidoracatAutoDrive_HUDZombieTipOff = "Z DETECT %1-%2 BAND %3\nZ CAP OFF\nOTHER SAFETY",
    UI_MinidoracatAutoDrive_HUDCorpseTipOn = "C DETECT %1-%2 BAND %3\nC CAP %4\nC NON-OBSTACLE",
    UI_MinidoracatAutoDrive_HUDCorpseTipOff = "C DETECT %1-%2 BAND %3\nC CAP OFF\nOTHER SAFETY",
    UI_MinidoracatAutoDrive_HUDCollapse = "COLLAPSE",
    UI_MinidoracatAutoDrive_HUDExpand = "EXPAND",
    UI_MinidoracatAutoDrive_EngineOff = "ENGINE REASON",
    UI_MinidoracatAutoDrive_TelemetryNoFile = "NO LOG",
}

local getTextCalls = 0
function getText(key, ...)
    getTextCalls = getTextCalls + 1
    local value = texts[key] or key
    local n = select("#", ...)
    for i = 1, n do
        value = value:gsub("%%" .. i, tostring(select(i, ...)))
    end
    return value:gsub("%%%%", "%%")
end

UIFont = { Small = "small", Medium = "medium" }
local measureCalls = 0
local textManager = {
    MeasureStringX = function(_, font, text)
        measureCalls = measureCalls + 1
        return #text * (font == UIFont.Medium and 9 or 7)
    end,
    getFontHeight = function(_, font)
        return font == UIFont.Medium and 18 or 14
    end,
}
function getTextManager() return textManager end

ISPanel = {}
function ISPanel:derive(name)
    local class = { Type = name }
    class.__index = class
    setmetatable(class, { __index = self })
    return class
end
function ISPanel.new(class, x, y, w, h)
    local o = { x = x, y = y, width = w, height = h, children = {}, visible = true }
    setmetatable(o, class)
    return o
end
function ISPanel:initialise() end
function ISPanel:instantiate()
    if self.javaObject then return end
    self.javaObject = true
    if self.createChildren then self:createChildren() end
end
function ISPanel:addChild(child) self.children[#self.children + 1] = child end
function ISPanel:setVisible(value) self.visible = value == true end
function ISPanel:isVisible() return self.visible end
function ISPanel:setAlwaysOnTop(value) self.alwaysOnTopSet = value == true end
function ISPanel:addToUIManager() self.added = true end
function ISPanel:removeFromUIManager() self.added = false end
function ISPanel:bringToTop() self.bringToTopCalls = (self.bringToTopCalls or 0) + 1 end
function ISPanel:setX(value) self.x = value end
function ISPanel:setY(value) self.y = value end
function ISPanel:setWidth(value) self.width = value end
function ISPanel:setHeight(value) self.height = value end
function ISPanel:getHeight() return self.height end
function ISPanel:getAbsoluteX() return self.x end
function ISPanel:getAbsoluteY() return self.y end
function ISPanel:getXScroll() return 0 end
function ISPanel:getYScroll() return 0 end
function ISPanel:drawRect(x, y, w, h, a, r, g, b)
    self.rects = (self.rects or 0) + 1
    if not self.firstRect then
        self.firstRect = { x = x, y = y, w = w, h = h, a = a, r = r, g = g, b = b }
    end
end
function ISPanel:drawRectBorder() self.borders = (self.borders or 0) + 1 end
function ISPanel:drawText() self.textDraws = (self.textDraws or 0) + 1 end

ISButton = {}
ISButton.__index = ISButton
function ISButton:new(x, y, w, h, title, target, onclick)
    return setmetatable({
        x = x, y = y, width = w, height = h, title = title,
        target = target, onclick = onclick, visible = true, enable = true,
        backgroundColor = { r = 0, g = 0, b = 0, a = 1 },
        backgroundColorMouseOver = { r = 0.3, g = 0.3, b = 0.3, a = 1 },
        borderColor = { r = 0.7, g = 0.7, b = 0.7, a = 1 },
        textColor = { r = 1, g = 1, b = 1, a = 1 },
        textureColor = { r = 1, g = 1, b = 1, a = 1 },
    }, self)
end
function ISButton:initialise() end
function ISButton:setX(value) self.x = value end
function ISButton:setY(value) self.y = value end
function ISButton:setWidth(value) self.width = value end
function ISButton:setHeight(value) self.height = value end
function ISButton:setVisible(value) self.visible = value == true end
function ISButton:setBackgroundRGBA(r, g, b, a)
    self.backgroundColor.r, self.backgroundColor.g = r, g
    self.backgroundColor.b, self.backgroundColor.a = b, a
end
function ISButton:setBorderRGBA(r, g, b, a)
    self.borderColor.r, self.borderColor.g = r, g
    self.borderColor.b, self.borderColor.a = b, a
end
function ISButton:setTextureRGBA(r, g, b, a)
    self.textureColor.r, self.textureColor.g = r, g
    self.textureColor.b, self.textureColor.a = b, a
end
function ISButton:setEnable(value)
    self.enable = value == true
    if not self.borderColorEnabled then
        self.borderColorEnabled = {
            r = self.borderColor.r, g = self.borderColor.g,
            b = self.borderColor.b, a = self.borderColor.a,
        }
        self.backgroundColorEnabled = {
            r = self.backgroundColor.r, g = self.backgroundColor.g,
            b = self.backgroundColor.b, a = self.backgroundColor.a,
        }
    end
    if self.enable then
        local bc, bg = self.borderColorEnabled, self.backgroundColorEnabled
        self:setTextureRGBA(1, 1, 1, 1)
        self:setBorderRGBA(bc.r, bc.g, bc.b, bc.a)
        self:setBackgroundRGBA(bg.r, bg.g, bg.b, bg.a)
    else
        self:setTextureRGBA(0.3, 0.3, 0.3, 1)
        self:setBorderRGBA(0.7, 0.1, 0.1, 0.7)
        self:setBackgroundRGBA(0, 0, 0, 1)
    end
end
function ISButton:setTitle(value) self.title = value end
function ISButton:getParent() return self.parent end
function ISButton:detachFromParent()
    if self.parent then self.parent:removeChild(self) end
end

-- 原版 ISButton:onMouseUp 走 self.onclick(self.target, self, ...)（ISButton.lua:47-48）。
local function click(button)
    button.onclick(button.target, button)
end

local optionSets = {}
local function newOptions(id)
    local options = { id = id, dict = {} }
    function options:addDescription() end
    function options:addComboBox(optionId)
        local option = { selected = 1, items = {} }
        function option:addItem(_, selected)
            self.items[#self.items + 1] = true
            if selected then self.selected = #self.items end
        end
        function option:getValue() return self.selected end
        function option:setValue(value) self.selected = value end
        self.dict[optionId] = option
        return option
    end
    function options:addTickBox(optionId, _, default)
        local option = { value = default == true }
        function option:getValue() return self.value end
        function option:setValue(value) self.value = value == true end
        self.dict[optionId] = option
        return option
    end
    function options:getOption(optionId) return self.dict[optionId] end
    optionSets[id] = options
    return options
end
PZAPI = { ModOptions = {} }
function PZAPI.ModOptions:create(id) return newOptions(id) end
local optionSaveCalls = 0
function PZAPI.ModOptions:save() optionSaveCalls = optionSaveCalls + 1 end

local nowMs = 1000
function getTimestampMs() return nowMs end
function isServer() return false end
function instanceof(object, name) return object and object._class == name end
local activePlayers = 1
local viewportWidth = 1920
function getNumActivePlayers() return activePlayers end
function getPlayerScreenLeft(playerNum) return playerNum == 1 and viewportWidth or 0 end
function getPlayerScreenTop() return 0 end
function getPlayerScreenWidth() return viewportWidth end
function getPlayerScreenHeight() return 1080 end
local function newDashboard()
    local dash = {
        width = 512, height = 110, y = 970, visible = true, inManager = true,
        vehicle = true, children = {},
        backgroundTex = {
            getWidth = function() return 512 end,
            getHeight = function() return 110 end,
        },
    }
    function dash:getWidth() return self.width end
    function dash:getHeight() return self.height end
    function dash:getY() return self.y end
    function dash:isReallyVisible() return self.visible and self.inManager end
    function dash:addChild(child)
        if child.parent and child.parent ~= self then child:detachFromParent() end
        self.children[#self.children + 1] = child
        child.parent = self
    end
    function dash:removeChild(child)
        for i = #self.children, 1, -1 do
            if self.children[i] == child then table.remove(self.children, i) end
        end
        -- 忠實模擬 vanilla ISUIElement.removeChild：Java parent/陣列清掉，
        -- Lua child.parent 不清；production destroyPanel 必須自行歸 nil。
    end
    return dash
end
local dashboards = { [0] = newDashboard(), [1] = newDashboard() }
function getPlayerVehicleDashboard(playerNum) return dashboards[playerNum] end
local escapeVisible = false
MainScreen = { instance = {
    inGame = true,
    isReallyVisible = function() return escapeVisible end,
} }
-- MainOptions 可在 ESC 關閉後仍留 visible=true；HUD 不得因此永久隱藏。
MainOptions = { instance = { isReallyVisible = function() return true end } }
ISUIHandler = { allUIVisible = true }

local getters = { speed = 0, battery = 0, fuel = 0 }
local vehicle = {
    _module = true,
    _speed = 47.4,
    _battery = 0.78,
    _fuel = 46.2,
}
function vehicle:isDriver(playerObj) return playerObj._vehicle == self end
function vehicle:getCurrentSpeedKmHour() getters.speed = getters.speed + 1; return self._speed end
function vehicle:getBatteryCharge() getters.battery = getters.battery + 1; return self._battery end
function vehicle:getRemainingFuelPercentage() getters.fuel = getters.fuel + 1; return self._fuel end
function vehicle:getMaxSpeed() return 120 end

local player = { _class = "IsoPlayer", _vehicle = vehicle, _md = {} }
function player:isLocalPlayer() return true end
function player:isDead() return false end
function player:getVehicle() return self._vehicle end
function player:getPlayerNum() return 0 end
function player:getModData() return self._md end
local player2 = { _class = "IsoPlayer", _vehicle = vehicle, _md = {} }
setmetatable(player2, { __index = player })
function player2:getPlayerNum() return 1 end
local players = { [0] = player, [1] = player2 }
function getSpecificPlayer(playerNum) return players[playerNum] end

local sandbox = { NeedItemForAutoDrive = true }
local policies = { ZombieAreaSlowdown = 2, CorpseSlowdown = 2 }
local state = {
    active = true,
    token = "follow",
    gear = 2,
    cap = 50,        -- session 快取回報的巡航上限（hudState 路徑）
    idleCap = 30,    -- 停用態由 Drive.effectiveCap 重算的上限；兩者刻意不同值
    zombie = true,
    corpse = true,
    prefs = { zombie = true, corpse = true },
    startReason = nil,
}
MDAD = {
    MOD_ID = "MinidoracatAutoDriveFor42",
    POLICY_FORCE_ON = 1,
    POLICY_PLAYER = 2,
    POLICY_FORCE_OFF = 3,
}
function MDAD.sandbox(name, default)
    local value = sandbox[name]
    if value == nil then return default end
    return value
end
function MDAD.policy3(name) return policies[name] or MDAD.POLICY_PLAYER end
function MDAD.isAutoInstalled(v) return v._module == true end
MDAD.Drive = {}
function MDAD.Drive.hudState()
    if not state.active then return nil end
    return state.token, state.gear, state.cap, state.zombie, state.corpse
end
function MDAD.Drive.hudStartReason() return state.startReason end
function MDAD.Drive.slowdownInfo() return 2, 48, 3, 25, 15, 10, 20 end
function MDAD.Drive.effectiveCap() return state.idleCap end
function MDAD.Drive.getGear() return state.gear end
function MDAD.Drive.setGear(_, gear) state.gear = gear; return true end
function MDAD.Drive.cycleGear()
    state.gear = state.gear % 4 + 1
    return state.gear
end
function MDAD.Drive.getSlowPref(_, kind) return state.prefs[kind] end
function MDAD.Drive.setSlowPref(_, kind, value)
    state.prefs[kind] = value == true
    if kind == "zombie" then state.zombie = value == true else state.corpse = value == true end
    return true
end
function MDAD.Drive.toggle()
    state.active = not state.active
end

local trajectoryClearCalls = 0
local trajectoryWidthSet = nil
MDADOverlay = {
    clearTrail = function() trajectoryClearCalls = trajectoryClearCalls + 1 end,
    setTrajectoryWidth = function(value) trajectoryWidthSet = value; return true end,
}
local registeredMiniMapSection = nil
local registeredMiniMapOwner = nil
local miniMapRegisterCalls = 0
MinidoracatMiniMapAPI = {
    settingsApiVersion = 1,
    registerSettingsSection = function(owner, spec)
        miniMapRegisterCalls = miniMapRegisterCalls + 1
        registeredMiniMapOwner = owner
        registeredMiniMapSection = spec
        return true
    end,
}

local realRequire = require
local source = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua/client/MDAD_HUD.lua"
-- 測試環境沒有引擎的 ISUI 檔案，重新執行 HUD chunk 時要把 require 吃掉。
local function loadHUD()
    require = function() return true end
    dofile(source)
    require = realRequire
end
loadHUD()

check(type(MDAD.HUD) == "table", "HUD facade published")
check(type(MDAD.HUD.Panel) == "table", "HUD panel class published")
fire(Events.OnGameStart)
local panel = MDAD.HUD.ensure(0)
check(panel.added, "panel added to UIManager")
check(panel.alwaysOnTopSet ~= true,
    "HUD stays on the dashboard's normal UIManager layer so later settings/modal windows cover it")
checkEq(panel.bringToTopCalls or 0, 0,
    "HUD root never requests bringToTop; settings/modal ordering remains authoritative")
check(panel.visible, "eligible local driver sees HUD")
checkEq(panel._style, 1, "default theme is metal")
checkEq(panel._layout, 1, "default layout is full")
check(panel.width >= 510 and panel.height >= 78, "full panel base dimensions")
checkEq(panel._statusText, "FOLLOW", "active status token translated")
checkEq(panel._speedText, "47", "speed rounded")
checkEq(panel._capText, "50", "effective cruise cap shown")
checkEq(panel._energyText, "BAT 78% FUEL 46%", "battery and fuel formatted")
checkEq(panel.zombieButton.tooltip,
    "Z DETECT 2-48 BAND 3\nZ CAPS 25/15/10\nZ NON-OBSTACLE\nTOGGLE",
    "zombie tooltip states range, density caps, non-obstacle behavior, and player scope")
checkEq(panel.corpseButton.tooltip,
    "C DETECT 2-48 BAND 3\nC CAP 20\nC NON-OBSTACLE\nTOGGLE",
    "corpse tooltip states range, one-body cap, non-obstacle behavior, and player scope")
check(panel.isCollapsed == nil, "does not use engine-reserved isCollapsed field")
local dashboardControlsInPanel = false
for i = 1, #panel.children do
    if panel.children[i] == panel.collapseButton
        or panel.children[i] == panel.themeButton then dashboardControlsInPanel = true end
end
check(not dashboardControlsInPanel
    and panel.collapseButton:getParent() == dashboards[0]
    and panel.themeButton:getParent() == dashboards[0],
    "collapse and theme controls are vanilla dashboard children")
check(panel.collapseButton.y == 7 and panel.collapseButton.height == 18
    and panel.themeButton.y == 7 and panel.themeButton.height == 18
    and panel.themeButton.width == 28
    and panel.themeButton.x + panel.themeButton.width + 4 == panel.collapseButton.x
    and panel.collapseButton.x + panel.collapseButton.width == dashboards[0].width - 62,
    "dashboard controls occupy measured visible top band")
checkEq(panel.y + panel.height, dashboards[0].y + 7,
    "HUD overlaps transparent inset and touches first visible dashboard row")

click(panel.themeButton)
check(panel._style == 2 and panel.themeButton.title == "M/S"
    and optionSets.MinidoracatAutoDrive:getOption("HUDTheme"):getValue() == 2,
    "dashboard theme button switches to minimal and syncs ModOptions")
checkEq(optionSaveCalls, 1, "theme button persists ModOptions immediately")
click(panel.themeButton)
check(panel._style == 1 and panel.themeButton.title == "M/S",
    "dashboard theme button switches back to vanilla-metal style")
checkEq(optionSaveCalls, 2, "second theme switch persists")

escapeVisible = true
panel:update()
check(not panel.visible and not panel.collapseButton.visible and not panel.themeButton.visible,
    "ESC root hides HUD and both dashboard controls before 250ms data refresh")
escapeVisible = false
nowMs = nowMs + 100
panel:update()
check(panel.visible and panel.collapseButton.visible and panel.themeButton.visible,
    "closing ESC root restores HUD and both dashboard controls")
escapeVisible = true
checkEq(panel.bringToTopCalls or 0, 0,
    "ESC/dashboard hide-and-restore cycles never raise HUD root above existing modals")
panel:prerender()
check(not panel.visible and not panel.collapseButton.visible and not panel.themeButton.visible,
    "ESC opened between UI ticks hides HUD and both dashboard controls")
escapeVisible = false
nowMs = nowMs + 100
panel:update()
dashboards[0].inManager = false -- removeFromUIManager：visible 保持 true
panel:update()
check(dashboards[0].visible
    and not panel.visible and not panel.collapseButton.visible and not panel.themeButton.visible,
    "dashboard UIManager removal hides HUD and controls before 250ms data refresh")
dashboards[0].inManager = true
nowMs = nowMs + 100
panel:update()
check(panel.visible and panel.collapseButton.visible and panel.themeButton.visible,
    "dashboard UIManager restore immediately recovers HUD and controls")

check(panel._capLabelY < panel._capValueY
    and panel._capValueY + 14 <= panel._dividerY,
    "full layout stacks cruise label/value inside top row")
local speedReads = getters.speed
nowMs = nowMs + 100
panel:update()
checkEq(getters.speed, speedReads, "under 250ms reuses Java getter cache")
nowMs = nowMs + 200
panel:update()
checkEq(getters.speed, speedReads + 1, "after 250ms refreshes Java getters")

local renderSpeedReads = getters.speed
local renderTextReads = getTextCalls
local renderMeasureReads = measureCalls
panel.firstRect = nil
panel:prerender()
checkEq(getters.speed, renderSpeedReads, "prerender performs no vehicle getter")
checkEq(getTextCalls, renderTextReads, "prerender performs no translation lookup")
checkEq(measureCalls, renderMeasureReads, "prerender performs no text measurement")
check((panel.rects or 0) > 0 and (panel.textDraws or 0) > 0, "metal HUD draws background and cache")
check(panel.firstRect and panel.firstRect.x == 6 and panel.firstRect.y == 0
    and math.abs(panel.firstRect.r - 0.353) < 0.001,
    "metal background begins with vanilla #5A5A5A chamfer")

-- 金屬背景是與原版 dashboard 對齊的像素契約：外緣 #5A5A5A 三段由外往內，
-- 主色 #343434 再疊三段做出 6px chamfer，最後一條高光、一條陰影。
-- do block 讓量測用的 local 不佔主 chunk 的活躍 slot。
do
    local bands = {}
    function panel:drawRect(x, y, w, h, a, r, g, b)
        bands[#bands + 1] = { x, y, w, h, a, r, g, b }
    end
    panel:drawBackground()
    panel.drawRect = nil
    local pw, ph = panel.width, panel.height
    local edge, face = 0.353, 0.204
    local expected = {
        { 6, 0, pw - 12, ph, 1.0, edge, edge, edge },
        { 3, 3, pw - 6, ph - 6, 1.0, edge, edge, edge },
        { 0, 6, pw, ph - 12, 1.0, edge, edge, edge },
        { 8, 2, pw - 16, ph - 4, 0.98, face, face, face },
        { 5, 5, pw - 10, ph - 10, 0.98, face, face, face },
        { 2, 8, pw - 4, ph - 16, 0.98, face, face, face },
        { 8, 2, pw - 16, 1, 0.72, 0.42, 0.42, 0.42 },
        { 8, ph - 4, pw - 16, 2, 0.88, 0.025, 0.025, 0.025 },
    }
    checkEq(#bands, #expected, "metal background draws exactly the measured chamfer bands")
    for i = 1, #expected do
        local got, want = bands[i], expected[i]
        local same = got ~= nil
        for k = 1, 8 do
            if not got or math.abs(got[k] - want[k]) > 0.001 then same = false end
        end
        check(same, "metal chamfer band " .. i .. " keeps vanilla geometry and colour")
    end
end

panel.vehicle = nil
panel:setHudVisible(true)
panel:prerender()
check(not panel.visible and not panel.collapseButton.visible and not panel.themeButton.visible,
    "prerender nil-vehicle guard hides root and dashboard controls, not only background")
panel.vehicle = vehicle
panel._forceRefresh = true
panel:update()

click(panel.gearButtons[1])
checkEq(state.gear, 1, "full gear button calls shared setGear")
local selectedBg = panel.gearButtons[1].backgroundColor
local normalBg = panel.gearButtons[2].backgroundColor
check(panel._gear == 1 and (
        selectedBg.r ~= normalBg.r or selectedBg.g ~= normalBg.g
        or selectedBg.b ~= normalBg.b or selectedBg.a ~= normalBg.a),
    "selected gear receives distinct RGBA visual state")
click(panel.cycleButton)
checkEq(state.gear, 2, "compact gear control calls shared cycleGear")
click(panel.zombieButton)
checkEq(state.prefs.zombie, false, "player-choice zombie pill toggles preference")
panel:refresh(nowMs)
checkEq(panel.zombieButton.tooltip,
    "Z DETECT 2-48 BAND 3\nZ CAP OFF\nOTHER SAFETY\nTOGGLE",
    "disabled zombie tooltip says only its dedicated cap is removed")
policies.ZombieAreaSlowdown = MDAD.POLICY_FORCE_ON
-- 偏好先設回 true：政策鎖若失效，onZombie 會把它翻成 false，斷言才抓得到。
state.zombie = true
state.prefs.zombie = true
panel:refresh(nowMs)
check(panel.zombieButton.enable == false and panel.zombieButton.title == "Z LOCK ON",
    "forced policy disables pill and labels it locked")
check(panel.zombieButton.tooltip:find("Z CAPS 25/15/10", 1, true) ~= nil
    and panel.zombieButton.tooltip:find("LOCKED ON NOTE", 1, true) ~= nil,
    "forced-on zombie tooltip keeps strategy detail and explains the lock")
panel:onZombie()
checkEq(state.prefs.zombie, true, "locked pill cannot mutate player preference")
policies.ZombieAreaSlowdown = MDAD.POLICY_PLAYER
policies.CorpseSlowdown = MDAD.POLICY_FORCE_OFF
state.corpse = false
panel:refresh(nowMs)
checkEq(panel.corpseButton.tooltip,
    "C DETECT 2-48 BAND 3\nC CAP OFF\nOTHER SAFETY\nLOCKED OFF SAFETY",
    "forced-off corpse tooltip explains dedicated-cap cancellation and remaining safety")
policies.CorpseSlowdown = MDAD.POLICY_PLAYER
state.corpse = true

click(panel.actionButton)
checkEq(state.active, false, "action button calls shared toggle")
checkEq(panel.actionButton.title, "START", "inactive action changes to start")
state.startReason = "UI_MinidoracatAutoDrive_EngineOff"
panel:refresh(nowMs)
checkEq(panel._statusText, "ENGINE OFF", "inactive reason uses short HUD label")
checkEq(panel.actionButton.tooltip, "ENGINE REASON", "full reason remains tooltip")
checkEq(panel._capText, "30", "inactive HUD recomputes cap via Drive.effectiveCap")

click(panel.collapseButton)
checkEq(player._md.MDADHudCollapsed, true, "collapsed state persists in player modData")
check(panel.width < 200 and panel.actionButton.visible == false,
    "collapsed mode is badge only")
check(panel.collapseButton.title == "^"
    and panel.collapseButton:getParent() == dashboards[0],
    "collapsed badge keeps expand control in vanilla dashboard")
click(panel.collapseButton)
checkEq(player._md.MDADHudCollapsed, false, "expand persists")
checkEq(panel.collapseButton.title, "v", "expanded dashboard control shows collapse direction")

-- 記下切換前的完整版可見性，讓下面那條斷言驗的是「換過去」而不只是「換過來」。
local fullLayoutShowedGears = panel.gearButtons[1].visible and not panel.cycleButton.visible

local options = optionSets.MinidoracatAutoDrive
check(type(options) == "table", "ModOptions namespace registered")
check(options:getOption("ShowTrajectory"):getValue() == true
    and options:getOption("TrajectoryWidth"):getValue() == 2,
    "trajectory options register visible=true and standard width defaults")
check(type(registeredMiniMapSection) == "table"
    and registeredMiniMapOwner == "MinidoracatAutoDriveFor42"
    and registeredMiniMapSection.lane == nil
    and registeredMiniMapSection.actions == nil
    and #registeredMiniMapSection.ticks == 2
    and #registeredMiniMapSection.combos == 2,
    "v1 MiniMap spec registers ticks/combos without actions or host layout fields")
check(options:getOption("ExportTelemetry"):getValue() == false
    and options:getOption("TelemetryRetentionDays"):getValue() == 3
    and MDAD.HUD.telemetryEnabled() == false
    and MDAD.HUD.telemetryRetentionDays() == 7,
    "telemetry defaults to off and 7-day retention")
local telemetrySaves = optionSaveCalls
check(MDAD.HUD.setTelemetryEnabled(true)
    and MDAD.HUD.telemetryEnabled()
    and options:getOption("ExportTelemetry"):getValue() == true
    and optionSaveCalls == telemetrySaves + 1,
    "telemetry enabled setter persists")
check(MDAD.HUD.setTelemetryRetentionDays(14)
    and MDAD.HUD.telemetryRetentionDays() == 14
    and options:getOption("TelemetryRetentionDays"):getValue() == 4,
    "retention setter maps 14 days to combo index 4")
local invalidRetentionSaves = optionSaveCalls
check(not MDAD.HUD.setTelemetryRetentionDays(2)
    and MDAD.HUD.telemetryRetentionDays() == 14
    and optionSaveCalls == invalidRetentionSaves,
    "invalid retention days rejected without saving")
registeredMiniMapSection.ticks[2].set(false)
check(not MDAD.HUD.telemetryEnabled()
    and options:getOption("ExportTelemetry"):getValue() == false,
    "MiniMap telemetry tick writes the same AutoDrive ModOptions value")
registeredMiniMapSection.combos[2].set(5)
check(MDAD.HUD.telemetryRetentionDays() == 30
    and options:getOption("TelemetryRetentionDays"):getValue() == 5,
    "MiniMap retention combo writes shared option as days")
local trajectorySaves = optionSaveCalls
check(MDAD.HUD.setTrajectoryVisible(false), "trajectory visibility setter accepts false")
check(options:getOption("ShowTrajectory"):getValue() == false
    and not MDAD.HUD.trajectoryVisible()
    and trajectoryClearCalls > 0
    and optionSaveCalls == trajectorySaves + 1,
    "visibility setter updates ModOptions, clears active trails, and persists")
registeredMiniMapSection.ticks[1].set(true)
check(MDAD.HUD.trajectoryVisible()
    and options:getOption("ShowTrajectory"):getValue() == true,
    "MiniMap tick callback writes the same AutoDrive ModOptions value")
registeredMiniMapSection.combos[1].set(3)
check(MDAD.HUD.trajectoryWidth() == 3
    and options:getOption("TrajectoryWidth"):getValue() == 3
    and trajectoryWidthSet == 3,
    "MiniMap width combo writes shared option and applies thickness immediately")
local invalidWidthSaves = optionSaveCalls
check(not MDAD.HUD.setTrajectoryWidth(4)
    and optionSaveCalls == invalidWidthSaves,
    "invalid trajectory width is rejected without saving")
MDAD.HUD.setTrajectoryWidth(2)
fire(Events.OnGameBoot)
check(miniMapRegisterCalls == 1,
    "OnGameBoot does not duplicate a successful MiniMap settings registration")
local copyLatestPn = nil
local copyFolderPn = nil
MDADDiagnostics = {
    copyLatestPath = function(pn)
        copyLatestPn = pn
        return true
    end,
    copyFolderPath = function(pn)
        copyFolderPn = pn
        return true
    end,
}
MinidoracatMiniMapAPI.settingsApiVersion = 2
fire(Events.OnGameBoot)
checkEq(miniMapRegisterCalls, 2, "API v2 upgrade re-registers settings once")
check(registeredMiniMapSection.actions ~= nil
    and #registeredMiniMapSection.actions == 2
    and #registeredMiniMapSection.ticks == 2
    and #registeredMiniMapSection.combos == 2,
    "v2 MiniMap spec keeps ticks/combos and adds two actions")
local latestAction = registeredMiniMapSection.actions[1]
local folderAction = registeredMiniMapSection.actions[2]
check(latestAction.label == "UI_MinidoracatAutoDrive_CopyLatestTelemetry"
    and type(latestAction.tooltip) == "string" and latestAction.tooltip ~= ""
    and type(latestAction.run) == "function"
    and latestAction.enabled == nil,
    "copy-latest action omits builder-time disk probing")
check(folderAction.label == "UI_MinidoracatAutoDrive_CopyTelemetryFolder"
    and type(folderAction.tooltip) == "string" and folderAction.tooltip ~= ""
    and type(folderAction.run) == "function"
    and folderAction.enabled == nil,
    "copy-folder action has required fields and omits enabled")
latestAction.run(1)
checkEq(copyLatestPn, 1, "copy-latest run receives playerNum")
folderAction.run(0)
checkEq(copyFolderPn, 0, "copy-folder run receives playerNum")
latestAction.run(0)
checkEq(copyLatestPn, 0, "copy-latest click handles no-file state inside Diagnostics")
options:getOption("HUDTheme"):setValue(2)
options:getOption("HUDLayout"):setValue(2)
options:getOption("HUDScale"):setValue(1)
options:apply()
checkEq(panel._style, 2, "ModOptions applies minimal theme")
checkEq(panel._layout, 2, "ModOptions applies compact layout")
check(fullLayoutShowedGears
    and panel.cycleButton.visible and not panel.gearButtons[1].visible,
    "compact layout swaps four buttons for cycle button")
check(panel._capLabelY == panel._capValueY and panel._capValueX > panel._capX,
    "compact layout keeps cruise label/value inline")
local unitRight = panel._unitX
    + textManager:MeasureStringX(UIFont.Small, panel._unitText)
check(unitRight + 3 <= panel._capX,
    "0.75x compact speed unit ends before cruise column")
local capRight = panel._capValueX
    + textManager:MeasureStringX(UIFont.Small, panel._capText)
check(capRight + 3 <= panel.cycleButton.x,
    "compact cruise value ends before cycle button")
click(panel.collapseButton)
check(panel.collapseButton.title == "^"
    and panel.y + panel.height == dashboards[0].y + 7,
    "0.75x badge overlaps transparent inset while controls remain external")
click(panel.collapseButton)

local compactWidth = panel.width
options:getOption("HUDScale"):setValue(3)
fire(Events.OnResolutionChange)
check(panel.added and panel.width > compactWidth,
    "resolution change re-applies layout instead of dropping the panel")

-- OnCreatePlayer 會重建所有 dashboard；即使只收到 resolution/apply，
-- HUD 也必須拋掉舊實例、重掛按鈕並用新 dashboard Y 定位。
local oldDashboard = dashboards[0]
local replacementDashboard = newDashboard()
replacementDashboard.y = 940
dashboards[0] = replacementDashboard
fire(Events.OnResolutionChange)
check(panel.collapseButton:getParent() == replacementDashboard
    and panel.themeButton:getParent() == replacementDashboard
    and #oldDashboard.children == 0,
    "dashboard recreation reparents both controls without orphan")
checkEq(panel.y + panel.height, replacementDashboard.y + 7,
    "dashboard recreation refreshes visible-edge docking anchor")

texts.UI_MinidoracatAutoDrive_HUDStatusNoNav = string.rep("N", 24)
state.startReason = "UI_MinidoracatAutoDrive_NavApiMissing"
options:getOption("HUDLayout"):setValue(1)
options:getOption("HUDScale"):setValue(2)
options:apply()
panel:refresh(nowMs)
local translatedStatusRight = panel._statusX
    + textManager:MeasureStringX(UIFont.Small, panel._statusText)
check(panel._showStatusText and translatedStatusRight <= panel._speedX,
    "measured long NoNav status ends before speed column")

-- 窄分割畫面＋長語系＋1.25x：OnCreatePlayer 會重建**所有** dashboard
-- 並改 viewport；既有 P0 與新 P1 都要立即 re-layout/reparent/dock。
texts.UI_MinidoracatAutoDrive_HUDStatusNoNav = string.rep("N", 48)
viewportWidth = 640
activePlayers = 2
state.startReason = "UI_MinidoracatAutoDrive_NavApiMissing"
options:getOption("HUDLayout"):setValue(1)
options:getOption("HUDScale"):setValue(3)
local preSplitDashboard0 = dashboards[0]
dashboards[0], dashboards[1] = newDashboard(), newDashboard()
dashboards[0].y, dashboards[1].y = 930, 930
fire(Events.OnCreatePlayer, 1, player2)
local panel2 = MDAD.HUD.ensure(1)
local splitPanels = { panel, panel2 }
for slot = 0, 1 do
    local candidate = splitPanels[slot + 1]
    local dash = dashboards[slot]
    check(candidate._effectiveLayout == 1 or candidate._effectiveLayout == 2,
        "split slot " .. slot .. " selects a valid effective layout")
    check(candidate.width <= viewportWidth - 16,
        "split slot " .. slot .. " HUD stays inside viewport width")
    local slotLeft = getPlayerScreenLeft(slot)
    check(candidate.x >= slotLeft
        and candidate.x + candidate.width <= slotLeft + getPlayerScreenWidth(slot),
        "split slot " .. slot .. " HUD x stays inside its own viewport")
    for i = 1, #candidate.children do
        local child = candidate.children[i]
        if child.visible then
            check(child.x >= 0 and child.x + child.width <= candidate.width,
                "split slot " .. slot .. " control " .. i .. " stays inside panel")
        end
    end
    if candidate._effectiveLayout == 2 then
        local capRight2 = candidate._capValueX
            + textManager:MeasureStringX(UIFont.Small, candidate._capText)
        check(capRight2 + 3 <= candidate.cycleButton.x,
            "split slot " .. slot .. " compact cruise ends before cycle button")
    end
    if candidate._showStatusText then
        local statusRight = candidate._statusX
            + textManager:MeasureStringX(UIFont.Small, candidate._statusText)
        check(statusRight <= candidate._speedX,
            "split slot " .. slot .. " long status ends before speed column")
    end
    check(candidate.collapseButton:getParent() == dash
        and candidate.themeButton:getParent() == dash
        and candidate.collapseButton.x + candidate.collapseButton.width <= dash.width
        and candidate.themeButton.x >= 0,
        "split slot " .. slot .. " controls attach inside own dashboard")
    check(candidate.zombieButton.visible == candidate.corpseButton.visible,
        "split slot " .. slot .. " policy pills hide or show as a pair")
    checkEq(candidate.y + candidate.height, dash.y + 7,
        "split slot " .. slot .. " HUD touches own visible dashboard edge")
end
checkEq(#preSplitDashboard0.children, 0,
    "existing P0 controls leave the dashboard rebuilt by OnCreatePlayer")
viewportWidth = 1920
activePlayers = 1

vehicle._module = false
sandbox.NeedItemForAutoDrive = true
panel:refresh(nowMs)
check(not panel.visible and not panel.collapseButton.visible and not panel.themeButton.visible,
    "missing required module hides HUD and dashboard controls")
sandbox.NeedItemForAutoDrive = false
panel:refresh(nowMs)
check(panel.visible and panel.collapseButton.visible and panel.themeButton.visible,
    "sandbox bypass shows HUD and dashboard controls without module")
ISUIHandler.allUIVisible = false
panel:refresh(nowMs)
check(not panel.visible and not panel.collapseButton.visible and not panel.themeButton.visible,
    "global UI hide also hides HUD and dashboard controls")
ISUIHandler.allUIVisible = true
panel:refresh(nowMs)
check(panel.visible and panel.collapseButton.visible and panel.themeButton.visible,
    "HUD and dashboard controls converge visible after global UI returns")

player._vehicle = nil
dashboards[0].vehicle = nil
fire(Events.OnExitVehicle, player)
check(not panel.visible and not panel.collapseButton.visible and not panel.themeButton.visible,
    "exit event hides HUD and dashboard controls immediately")
player._vehicle = vehicle
dashboards[0].vehicle = true
fire(Events.OnEnterVehicle, player)
check(panel.visible and panel.collapseButton.visible and panel.themeButton.visible,
    "enter event restores HUD and dashboard controls immediately")
fire(Events.OnPlayerDeath, player)
check(not panel.added and panel.collapseButton:getParent() == nil
    and panel.themeButton:getParent() == nil,
    "player death removes panel and detaches dashboard controls")
fire(Events.OnPlayerDeath, player2)
check(not panel2.added and panel2.collapseButton:getParent() == nil
    and panel2.themeButton:getParent() == nil,
    "second split-screen panel and dashboard controls clean up independently")

-- Driver 載入失敗（Kahlua 結構上限超標＝整個 MDAD_Driver.lua chunk 一行都不執行，
-- MDAD.Drive 不存在）。HUD 必須印一行安裝級診斷就退場：不發布 facade、不註冊事件。
-- 少了這條，每 250ms 一輪的 hudState 會變成 "attempted index: hudState of
-- non-table" 洗爆 console，把真正的根因那一行推出捲軸。
local function handlerCount()
    local n = 0
    for _, event in pairs(Events) do n = n + #event.handlers end
    return n
end
local liveHUD, liveDrive = MDAD.HUD, MDAD.Drive
for _, broken in ipairs({ { case = "MDAD.Drive missing", drive = nil },
                          { case = "Drive.hudState missing", drive = {} } }) do
    local baseline = handlerCount()
    local logged = 0
    local realPrint = print
    print = function() logged = logged + 1 end
    MDAD.HUD, MDAD.Drive = nil, broken.drive
    loadHUD()
    print = realPrint
    check(MDAD.HUD == nil, broken.case .. ": HUD facade not published")
    checkEq(handlerCount(), baseline, broken.case .. ": no engine events registered")
    checkEq(logged, 1, broken.case .. ": exactly one install-level diagnostic line")
end
-- 正面對照：閘門不是「永遠退場」——Drive 完整時同一份檔案照樣發布 HUD。
MDAD.Drive = liveDrive
loadHUD()
check(type(MDAD.HUD) == "table" and type(MDAD.HUD.Panel) == "table",
    "intact Drive still publishes the HUD facade through the same guard")
MDAD.HUD = liveHUD

print("HUD assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
