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
    UI_MinidoracatAutoDrive_HUDStyleButton = "STYLE",
    UI_MinidoracatAutoDrive_HUDHideButton = "HIDE",
    UI_MinidoracatAutoDrive_HUDShowButton = "SHOW",
    UI_MinidoracatAutoDrive_HUDVoice = "VOICE",
    UI_MinidoracatAutoDrive_HUDTheme = "THEME",
    UI_MinidoracatAutoDrive_HUDDetourButton = "REROUTE",
    UI_MinidoracatAutoDrive_HUDDetourTip = "REROUTE TIP",
    UI_MinidoracatAutoDrive_HUDAuto = "AUTO",
    UI_MinidoracatAutoDrive_HUDAutoTip = "AUTO TIP",
    UI_MinidoracatAutoDrive_HUDStatusBlocked = "HOLDING",
    UI_MinidoracatAutoDrive_HUDThemeMetal = "METAL",
    UI_MinidoracatAutoDrive_HUDThemeMinimal = "GLASS",
    UI_MinidoracatAutoDrive_HUDThemeFamily = "FAMILY",
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
function ISPanel:addChild(child)
    self.children[#self.children + 1] = child
    child.parent = self
end
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
function ISPanel:setCapture(value) self.captured = value == true end
function ISPanel:getMouseX() return self.mouseX or 0 end
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
-- ISButton.lua:179-190：image／forceImageSize；render 以 textureColor 染色（:222-226）
function ISButton:setImage(image) self.image = image end
function ISButton:forceImageSize(w, h) self.forcedWidthImage, self.forcedHeightImage = w, h end
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
    -- PZAPI/ModOptions.lua:206-215：slider option 只有 value（數字）
    function options:addSlider(optionId, _, min, max, step, default)
        local option = { value = default, min = min, max = max, step = step }
        function option:getValue() return self.value end
        function option:setValue(value) self.value = value end
        self.dict[optionId] = option
        return option
    end
    -- PZAPI/ModOptions.lua:230-245：button option 只記 onclick；MainOptions.lua:2979
    -- 以 setOnClick(onclick, args) 接線，點擊呼叫 onclick(target, button)。
    function options:addButton(optionId, name, tooltip, onclick)
        local option = { type = "button", name = name, tooltip = tooltip, onclick = onclick }
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

-- MDAD_Voice 樁：只記錄呼叫，HUD 的語音回饋契約（開啟時試播 start、拉桿放開試播 arrive）靠它驗
local voiceCalls = {}
MDAD_VOICE_STUB = { play = function(event, pn) voiceCalls[#voiceCalls + 1] = event .. "@" .. tostring(pn); return true end,
    PACKS = { "zh", "en", "ja" } }

local nowMs = 1000
function getTimestampMs() return nowMs end
function isServer() return false end
function getDebug() return false end
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
        width = 512, height = 110, x = 704, y = 970, visible = true, inManager = true,
        vehicle = true, children = {},
        backgroundTex = {
            getWidth = function() return 512 end,
            getHeight = function() return 110 end,
        },
    }
    function dash:getWidth() return self.width end
    function dash:getHeight() return self.height end
    function dash:getX() return self.x end
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
MDAD.Voice = MDAD_VOICE_STUB
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
local detourCalls = 0
local detourResult = true
function MDAD.Drive.requestDetour(pn)
    detourCalls = detourCalls + 1
    if detourResult then state.token = "follow" end
    return detourResult, detourResult and nil or "through"
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
-- 2026-09-02 使用者裁定：四個控制（樣式／隱藏／語音／音量）都在 HUD 本體，
-- 不再掛原版儀表板；金屬主題＝右側 2×2 方塊（樣式／隱藏 ↑，語音／音量 ↓）＋直分隔線。
local function isChild(child)
    for i = 1, #panel.children do
        if panel.children[i] == child then return true end
    end
    return false
end
check(isChild(panel.themeButton) and isChild(panel.collapseButton)
    and isChild(panel.voiceButton) and isChild(panel.volumeSlider)
    and #dashboards[0].children == 0,
    "style/hide/voice/volume controls are HUD children; vanilla dashboard untouched")
check(panel.themeButton.visible and panel.collapseButton.visible
    and panel.voiceButton.visible and panel.volumeSlider.visible,
    "all four controls visible in full metal layout")
check(panel.themeButton.title == "STYLE" and panel.collapseButton.title == "HIDE",
    "control buttons carry translated labels, not glyph codes")
check(panel.themeButton.y == panel.collapseButton.y
    and panel.collapseButton.x == panel.themeButton.x + panel.themeButton.width + 4
    and panel.voiceButton.y == panel.gearButtons[1].y
    and panel.volumeSlider.x == panel.voiceButton.x + panel.voiceButton.width + 4
    and panel.volumeSlider.y == panel.voiceButton.y
    and panel.themeButton.x == panel.voiceButton.x,
    "metal block is a 2x2 grid aligned with the two HUD rows")
check(panel._blockX ~= nil and panel._blockX < panel.themeButton.x
    and panel.actionButton.x + panel.actionButton.width < panel._blockX,
    "metal block sits right of the action button behind a vertical divider")
check(panel.themeButton.x + panel.themeButton.width <= panel.width - 6
    and panel.volumeSlider.x + panel.volumeSlider.width <= panel.width - 6,
    "metal block fits inside the panel")
check(panel.voiceButton.title == "VOICE ON", "voice pill reflects option default on")
checkEq(panel.volumeSlider.value, 70, "volume slider reflects option default")
checkEq(panel.y + panel.height, dashboards[0].y + 7,
    "HUD overlaps transparent inset and touches first visible dashboard row")

-- 自動改道藥丸（2026-09-02 使用者：ESC 選項也要在 HUD 上）：每個主題都緊接在屍體藥丸
-- 之後、同列同尺寸、與其他藥丸同時顯示／隱藏；讀寫的是 ESC／MiniMap 共用的 AutoDetour 選項。
local function checkAutoPill(label)
    local a, c = panel.autoButton, panel.corpseButton
    check(a.visible == c.visible and a.y == c.y and a.height == c.height and a.width == c.width
        and a.x == c.x + c.width + 4 and a.x + a.width <= panel.width,
        label .. ": auto-reroute pill follows the corpse pill on the same row")
end
checkAutoPill("metal")
check(panel.autoButton.title == "AUTO OFF" and panel.autoButton.enable == true
    and panel.autoButton.tooltip == "AUTO TIP\nTOGGLE",
    "auto-reroute pill reflects the option default (off) and explains itself")
click(panel.autoButton)
check(MDAD.HUD.autoDetour() == true
    and optionSets.MinidoracatAutoDrive:getOption("AutoDetour"):getValue() == true
    and panel.autoButton.title == "AUTO ON",
    "clicking the auto-reroute pill writes the shared AutoDetour option and relabels")
checkEq(optionSaveCalls, 1, "auto-reroute pill persists ModOptions immediately")
click(panel.autoButton)
check(MDAD.HUD.autoDetour() == false and panel.autoButton.title == "AUTO OFF",
    "second click turns auto-reroute back off")
optionSaveCalls = 0

click(panel.themeButton)
check(panel._style == 2
    and optionSets.MinidoracatAutoDrive:getOption("HUDTheme"):getValue() == 2,
    "style button cycles metal → glass and syncs ModOptions")
checkEq(optionSaveCalls, 1, "style button persists ModOptions immediately")
checkEq(panel.themeButton.tooltip, "THEME: GLASS", "style tooltip names the current theme")
check(panel._blockX == nil and panel.voiceButton.y == panel.themeButton.y
    and panel.themeButton.y == panel.actionButton.y + math.floor((panel.actionButton.height - panel.themeButton.height) / 2)
    and panel.collapseButton.x == panel.themeButton.x + panel.themeButton.width + 4
    and panel.voiceButton.x == panel.collapseButton.x + panel.collapseButton.width + 4
    and panel.voiceButton.x + panel.voiceButton.width <= panel.actionButton.x
    and panel.volumeSlider.y == panel.gearButtons[1].y
    and panel.volumeSlider.x + panel.volumeSlider.width == panel.width - 8
    and panel._energyX + 7 * #panel._energyText <= panel.volumeSlider.x,
    "glass theme: trio inline on row one, slider at the right end of row two after energy")
checkAutoPill("glass")
click(panel.themeButton)
check(panel._style == 3
    and optionSets.MinidoracatAutoDrive:getOption("HUDTheme"):getValue() == 3,
    "style button cycles glass → family")
check(panel._headerH > 0 and panel.themeButton.y < panel._headerH
    and panel.voiceButton.y == panel.themeButton.y and panel.volumeSlider.y == panel.themeButton.y
    and panel.volumeSlider.x == panel.voiceButton.x + panel.voiceButton.width + 4
    and panel._dotY < panel._headerH and panel._speedY < panel._headerH
    and panel._capLabelY >= panel._headerH and panel.actionButton.y >= panel._headerH
    and panel.height > 78,
    "family theme: header strip holds status/speed plus controls; cruise and action move below")
checkAutoPill("family")
click(panel.themeButton)
check(panel._style == 4
    and optionSets.MinidoracatAutoDrive:getOption("HUDTheme"):getValue() == 4,
    "style button cycles family → wings")
-- 側掛（2026-09-02 使用者裁定，設計稿 D1）：兩片貼在儀表板左右緣、高度等於可見儀表板，
-- 中段完全不畫（讓出路面）；左右各有自己的 chevron 與 modData，可以只留左翼常駐。
local dashX, dashY = dashboards[0].x, dashboards[0].y
check(panel.height == dashboards[0].height - 7
    and panel.y == dashY + 7
    and panel.x + panel._wingLeftW == dashX
    and panel._wingRightX == panel._wingLeftW + panel._wingDashW
    and panel.width == panel._wingLeftW + panel._wingDashW + panel._wingRightW,
    "wings theme: both wings hug the visible dashboard edges and leave the middle untouched")
check(panel.actionButton.x + panel.actionButton.width <= panel._wingLeftW
    and panel.wingButton.visible and panel.wingButton.y == panel.actionButton.y + math.floor((panel.actionButton.height - panel.wingButton.height) / 2)
    and panel.wingButton.x + panel.wingButton.width + 4 == panel.actionButton.x
    and panel.gearButtons[1].x >= panel._wingRightX
    and panel.zombieButton.x >= panel._wingRightX
    and panel.volumeSlider.x + panel.volumeSlider.width <= panel.width
    and panel.wingButton.visible and panel.collapseButton.visible,
    "wings theme: left wing owns the main button, right wing owns gear/policy/settings")
checkAutoPill("wings")
check(panel.autoButton.x >= panel._wingRightX and panel.autoButton.visible,
    "wings theme: auto-reroute pill lives on the right wing")
local openLeftW, openRightW = panel._wingLeftW, panel._wingRightW
click(panel.collapseButton)
check(panel._wingR == true and panel._wingL == false
    and player._md.MDADHudWingR == true and player._md.MDADHudWingL == nil
    and panel._wingRightW < openRightW and panel._wingLeftW == openLeftW
    and not panel.gearButtons[1].visible and not panel.volumeSlider.visible
    and not panel.autoButton.visible
    and panel.actionButton.visible,
    "folding the right wing keeps the left one resident and persists per side")
click(panel.wingButton)
check(panel._wingL == true and player._md.MDADHudWingL == true
    and panel._wingLeftW < openLeftW and not panel.actionButton.visible
    and panel.wingButton.visible and panel.collapseButton.visible,
    "both wings folded leaves two badges with their own expand chevrons")
click(panel.wingButton)
click(panel.collapseButton)
check(panel._wingL == false and panel._wingR == false
    and panel._wingLeftW == openLeftW and panel._wingRightW == openRightW,
    "expanding each wing restores its own geometry")
-- 中段（儀表板所在）必須一個像素都不畫，否則「不遮路面」這個賣點就沒了。
local wingBands = {}
function panel:drawRect(x, y, w, h) wingBands[#wingBands + 1] = { x, w } end
panel:drawBackground()
panel.drawRect = nil
local gapL, gapR = panel._wingLeftW, panel._wingRightX
local painted = 0
for i = 1, #wingBands do
    local x, w = wingBands[i][1], wingBands[i][2]
    if x + w > gapL and x < gapR then painted = painted + 1 end
end
check(#wingBands > 0 and painted == 0 and gapR > gapL,
    "wings background paints both wings and leaves the dashboard gap untouched")
click(panel.themeButton)
check(panel._style == 1, "style button cycles wings → metal")
check(not panel.wingButton.visible, "leaving the wings theme hides the left-wing chevron (2026-09-02 實機截圖回歸)")
click(panel.collapseButton)
check(not panel.wingButton.visible, "collapsed badge of a top-mounted theme never shows the wing chevron")
click(panel.collapseButton)
checkEq(optionSaveCalls, 4, "each style switch persists")

escapeVisible = true
panel:update()
check(not panel.visible, "ESC root hides HUD before 250ms data refresh")
escapeVisible = false
nowMs = nowMs + 100
panel:update()
check(panel.visible, "closing ESC root restores HUD")
escapeVisible = true
checkEq(panel.bringToTopCalls or 0, 0,
    "ESC/dashboard hide-and-restore cycles never raise HUD root above existing modals")
panel:prerender()
check(not panel.visible, "ESC opened between UI ticks hides HUD")
escapeVisible = false
nowMs = nowMs + 100
panel:update()
dashboards[0].inManager = false -- removeFromUIManager：visible 保持 true
panel:update()
check(dashboards[0].visible and not panel.visible,
    "dashboard UIManager removal hides HUD before 250ms data refresh")
dashboards[0].inManager = true
nowMs = nowMs + 100
panel:update()
check(panel.visible, "dashboard UIManager restore immediately recovers HUD")

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
        -- 控制方塊左側的直分隔線（2026-09-02 控制上 HUD）
        { panel._blockX, 6, 1, ph - 12, 1.0, edge, edge, edge },
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
check(not panel.visible,
    "prerender nil-vehicle guard hides root, not only background")
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
check(panel.width < 200 and panel.actionButton.visible == false
    and not panel.themeButton.visible and not panel.voiceButton.visible
    and not panel.volumeSlider.visible,
    "collapsed mode is badge only: style/voice/volume hidden")
check(panel.collapseButton.visible and panel.collapseButton.title == "SHOW"
    and panel.collapseButton.x + panel.collapseButton.width <= panel.width,
    "collapsed badge keeps the expand control on itself")
click(panel.collapseButton)
checkEq(player._md.MDADHudCollapsed, false, "expand persists")
checkEq(panel.collapseButton.title, "HIDE", "expanded control shows the hide label")

-- 語音開關：點擊翻轉 option 並落盤；開啟瞬間試播 start 給玩家聽音量
local voiceOption = optionSets.MinidoracatAutoDrive:getOption("VoiceEnabled")
local voiceCallsBefore = #voiceCalls
click(panel.voiceButton)
check(voiceOption:getValue() == false and panel.voiceButton.title == "VOICE OFF"
    and #voiceCalls == voiceCallsBefore,
    "voice pill turns the option off, restyles, and plays nothing")
click(panel.voiceButton)
check(voiceOption:getValue() == true and panel.voiceButton.title == "VOICE ON"
    and voiceCalls[#voiceCalls] == "start@0",
    "voice pill turns the option on and previews the start line")
check(MDAD.HUD.voiceEnabled() == true and MDAD.HUD.voiceVolume() == 70,
    "voice accessors expose option state for MDAD_Voice")

-- 音量拉桿：拖曳中只改 option 值（不 apply／不落盤），放開才落盤＋試播 arrive；
-- 滾輪＝±5 且視同放開。
local volumeOption = optionSets.MinidoracatAutoDrive:getOption("VoiceVolume")
local saveBefore = optionSaveCalls
local layoutW = panel.width
local slider = panel.volumeSlider
slider.mouseX = 6 + slider:trackWidth() -- 拉到最右
slider:onMouseDown(0, 0)
check(slider.dragging and slider.captured and slider.value == 100
    and volumeOption:getValue() == 100 and optionSaveCalls == saveBefore,
    "mouse down jumps to the pointed value, captures, writes option without saving")
slider.mouseX = 6 + math.floor(slider:trackWidth() / 2)
slider:onMouseMove(0, 0)
check(slider.value == 50 and volumeOption:getValue() == 50 and optionSaveCalls == saveBefore
    and panel.width == layoutW,
    "dragging updates value in 5-steps without saving or relayout")
slider:onMouseUp(0, 0)
check(not slider.dragging and not slider.captured and optionSaveCalls == saveBefore + 1
    and voiceCalls[#voiceCalls] == "arrive@0" and MDAD.HUD.voiceVolume() == 50,
    "mouse up persists once and previews the short arrive line")
slider:onMouseWheel(-1)
check(slider.value == 55 and volumeOption:getValue() == 55 and optionSaveCalls == saveBefore + 2,
    "wheel up steps +5 and persists")
slider:onMouseWheel(1)
check(slider.value == 50 and optionSaveCalls == saveBefore + 3, "wheel down steps -5")
slider.value = 100
slider:onMouseWheel(-1)
checkEq(slider.value, 100, "wheel cannot exceed 100")
slider.value = 0
slider:onMouseWheel(1)
checkEq(slider.value, 0, "wheel cannot go below 0")
voiceOption:setValue(false)
local voiceCallsMuted = #voiceCalls
panel:refresh(nowMs)
slider:onMouseWheel(-1)
checkEq(#voiceCalls, voiceCallsMuted, "volume preview stays silent while voice is off")
voiceOption:setValue(true)
-- 改道鈕（2026-09-02 車陣策略）：只在「煞停等待」出現、接在狀態字後、點了走 Drive.requestDetour
check(not panel.detourButton.visible, "detour button hidden while inactive")
state.active, state.startReason = true, nil
state.token = "follow"
panel:refresh(nowMs)
check(not panel.detourButton.visible, "detour button hidden while following")
state.token = "blocked"
panel:refresh(nowMs)
check(panel.detourButton.visible and panel.detourButton.title == "REROUTE"
    and panel.detourButton.x == panel._statusX + #panel._statusText * 7 + 4
    and panel.detourButton.x + panel.detourButton.width + 4 <= panel._speedX
    and panel.detourButton.y >= 0,
    "blocked status shows the reroute pill right after the status text, before the speed column")
click(panel.detourButton)
check(detourCalls == 1 and not panel.detourButton.visible and panel._statusText == "FOLLOW",
    "reroute click asks the driver once and the pill disappears once unblocked")
state.token = "blocked"
panel:refresh(nowMs)
click(panel.collapseButton)
check(not panel.detourButton.visible, "collapsed badge never shows the reroute pill")
click(panel.collapseButton)
panel:refresh(nowMs)
check(panel.detourButton.visible, "expanding restores the reroute pill while still blocked")
state.token = "follow"
state.active, state.startReason = false, "UI_MinidoracatAutoDrive_EngineOff"
panel:refresh(nowMs)

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
    and #registeredMiniMapSection.ticks == 4
    and #registeredMiniMapSection.combos == 3,
    "v1 MiniMap spec registers ticks/combos without actions or host layout fields")
check(registeredMiniMapSection.ticks[2].label == "UI_MinidoracatAutoDrive_VoiceEnabled"
    and registeredMiniMapSection.ticks[2].get() == true,
    "MiniMap section exposes the voice tick between trajectory and telemetry")
registeredMiniMapSection.ticks[2].set(false)
check(MDAD.HUD.voiceEnabled() == false
    and options:getOption("VoiceEnabled"):getValue() == false,
    "MiniMap voice tick writes the shared VoiceEnabled option")
registeredMiniMapSection.ticks[2].set(true)
check(registeredMiniMapSection.ticks[3].label == "UI_MinidoracatAutoDrive_AutoDetour"
    and registeredMiniMapSection.ticks[3].get() == false
    and MDAD.HUD.autoDetour() == false,
    "auto-detour tick defaults off and sits before telemetry")
registeredMiniMapSection.ticks[3].set(true)
check(MDAD.HUD.autoDetour() == true
    and options:getOption("AutoDetour"):getValue() == true,
    "MiniMap auto-detour tick writes the shared AutoDetour option")
registeredMiniMapSection.ticks[3].set(false)
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
registeredMiniMapSection.ticks[4].set(false)
check(not MDAD.HUD.telemetryEnabled()
    and options:getOption("ExportTelemetry"):getValue() == false,
    "MiniMap telemetry tick writes the same AutoDrive ModOptions value")
registeredMiniMapSection.combos[3].set(5)
check(MDAD.HUD.telemetryRetentionDays() == 30
    and options:getOption("TelemetryRetentionDays"):getValue() == 5,
    "MiniMap retention combo writes shared option as days")
-- 語音語言 combo（2026-09-02）：index 1 跟隨、2..4＝Voice.PACKS；MiniMap 與 ESC 共用同一 option
local voiceLangCombo = registeredMiniMapSection.combos[2]
check(voiceLangCombo.label == "UI_MinidoracatAutoDrive_VoiceLanguage"
    and #voiceLangCombo.items == 4
    and voiceLangCombo.items[1] == "UI_MinidoracatAutoDrive_VoiceLangAuto"
    and voiceLangCombo.items[4] == "UI_MinidoracatAutoDrive_VoiceLang_ja"
    and voiceLangCombo.default == 1,
    "voice language combo lists follow + the three packs in Voice.PACKS order")
checkEq(MDAD.HUD.voiceLanguage(), "auto", "voice language defaults to follow-game-language")
voiceLangCombo.set(4)
check(MDAD.HUD.voiceLanguage() == "ja"
    and options:getOption("VoiceLanguage"):getValue() == 4,
    "MiniMap voice language combo writes the shared option and maps index to pack")
local voiceLangSaves = optionSaveCalls
check(not MDAD.HUD.setVoiceLanguageIndex(5) and not MDAD.HUD.setVoiceLanguageIndex(0)
    and MDAD.HUD.voiceLanguage() == "ja" and optionSaveCalls == voiceLangSaves,
    "out-of-range voice language index rejected without saving")
options:getOption("VoiceLanguage"):setValue(9)
checkEq(MDAD.HUD.voiceLanguage(), "auto", "corrupt voice language option reads back as follow")
voiceLangCombo.set(1)
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
local copyReportPn = nil
MDADDiagnostics = {
    copyLatestPath = function(pn)
        copyLatestPn = pn
        return true
    end,
    copyFolderPath = function(pn)
        copyFolderPn = pn
        return true
    end,
    copyReportLink = function(pn)
        copyReportPn = pn
        return true
    end,
}
MinidoracatMiniMapAPI.settingsApiVersion = 2
fire(Events.OnGameBoot)
checkEq(miniMapRegisterCalls, 2, "API v2 upgrade re-registers settings once")
check(registeredMiniMapSection.actions ~= nil
    and #registeredMiniMapSection.actions == 3
    and #registeredMiniMapSection.ticks == 4
    and #registeredMiniMapSection.combos == 3,
    "v2 MiniMap spec keeps ticks/combos and adds three actions")
local latestAction = registeredMiniMapSection.actions[1]
local folderAction = registeredMiniMapSection.actions[2]
local reportAction = registeredMiniMapSection.actions[3]
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
check(reportAction.label == "UI_MinidoracatAutoDrive_ReportIssue"
    and reportAction.tooltip == "UI_MinidoracatAutoDrive_ReportIssue_tooltip"
    and type(reportAction.run) == "function"
    and reportAction.enabled == nil,
    "report-issue action has label/tooltip/run and omits enabled")
reportAction.run(1)
checkEq(copyReportPn, 1, "report-issue run copies the link for the given playerNum")
local reportButton = options:getOption("ReportIssue")
check(reportButton ~= nil and reportButton.type == "button"
    and reportButton.name == "UI_MinidoracatAutoDrive_ReportIssue"
    and reportButton.tooltip == "UI_MinidoracatAutoDrive_ReportIssue_tooltip",
    "ESC options register a report-issue button with label and tooltip")
copyReportPn = nil
reportButton.onclick(nil, reportButton)
checkEq(copyReportPn, 0, "ESC report-issue button copies the link for the local main player")
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
check(panel.collapseButton.title == "SHOW"
    and panel.y + panel.height == dashboards[0].y + 7,
    "0.75x badge overlaps transparent inset and keeps its own expand control")
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
check(panel._dashboard == replacementDashboard
    and #oldDashboard.children == 0 and #replacementDashboard.children == 0,
    "dashboard recreation re-docks the panel; vanilla dashboards never receive children")
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
    check(candidate.collapseButton.parent == candidate
        and candidate.collapseButton.x + candidate.collapseButton.width <= candidate.width
        and candidate.themeButton.x >= 0 and #dash.children == 0,
        "split slot " .. slot .. " controls stay inside own HUD")
    check(candidate.zombieButton.visible == candidate.corpseButton.visible
        and candidate.autoButton.visible == candidate.corpseButton.visible,
        "split slot " .. slot .. " policy pills hide or show together")
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
check(not panel.visible, "missing required module hides HUD")
sandbox.NeedItemForAutoDrive = false
panel:refresh(nowMs)
check(panel.visible, "sandbox bypass shows HUD without module")
ISUIHandler.allUIVisible = false
panel:refresh(nowMs)
check(not panel.visible, "global UI hide also hides HUD")
ISUIHandler.allUIVisible = true
panel:refresh(nowMs)
check(panel.visible, "HUD converges visible after global UI returns")

player._vehicle = nil
dashboards[0].vehicle = nil
fire(Events.OnExitVehicle, player)
check(not panel.visible, "exit event hides HUD immediately")
player._vehicle = vehicle
dashboards[0].vehicle = true
fire(Events.OnEnterVehicle, player)
check(panel.visible, "enter event restores HUD immediately")
fire(Events.OnPlayerDeath, player)
check(not panel.added and panel._dashboard == nil,
    "player death removes panel and drops the dashboard reference")
fire(Events.OnPlayerDeath, player2)
check(not panel2.added, "second split-screen panel cleans up independently")

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

-- 圖示模式（2026-09-02 使用者裁定：控制鈕改圖示省空間，說明看 tooltip）：
-- getTexture 回得到 hud_*.png 時，控制鈕／策略藥丸收成方鈕、標題清空、字形依狀態染色；
-- 缺圖（getTexture 回 nil）＝整套退回文字寬與文字標題。快取在 chunk 層，故重載 HUD 再測。
local iconLoads = {}
function getTexture(path)
    iconLoads[#iconLoads + 1] = path
    if path:find("^media/ui/MinidoracatAutoDrive/hud_") then
        return { path = path, getWidthOrig = function() return 32 end, getHeightOrig = function() return 32 end }
    end
    return nil
end
MDAD.HUD = nil -- 讓 chunk 重跑（頂部 `if MDAD.HUD then return end`），圖示快取歸零
loadHUD()
local iconPanel = MDAD.HUD.Panel:new(0)
iconPanel:initialise(); iconPanel:instantiate()
iconPanel:refresh(nowMs)
check(iconPanel.themeButton.width == iconPanel.themeButton.height
    and iconPanel.collapseButton.width == iconPanel.collapseButton.height
    and iconPanel.voiceButton.width == iconPanel.voiceButton.height
    and iconPanel.zombieButton.width == iconPanel.zombieButton.height,
    "icons present: control buttons and policy pills become squares")
check(iconPanel.themeButton.image and iconPanel.themeButton.image.path:find("hud_palette.png", 1, true)
    and iconPanel.themeButton.title == ""
    and iconPanel.collapseButton.image.path:find("hud_chevron_down.png", 1, true)
    and iconPanel.voiceButton.image.path:find("hud_speaker_on.png", 1, true)
    and iconPanel.zombieButton.image.path:find("hud_zombie.png", 1, true)
    and iconPanel.corpseButton.image.path:find("hud_skull.png", 1, true)
    and iconPanel.autoButton.image.path:find("hud_detour.png", 1, true)
    and iconPanel.autoButton.width == iconPanel.autoButton.height and iconPanel.autoButton.title == "",
    "icons present: glyphs replace titles (palette / chevron / speaker / zombie / skull / detour)")
check(iconPanel.voiceButton.textureColor.g > 0.7 and iconPanel.voiceButton.textureColor.r < 0.5,
    "voice-on glyph is tinted green (state lives in the tint, explanation in the tooltip)")
iconPanel:setCollapsed(true)
check(iconPanel.collapseButton.image.path:find("hud_chevron_up.png", 1, true),
    "collapsed badge flips the chevron upward")
iconPanel:setCollapsed(false)
optionSets.MinidoracatAutoDrive:getOption("HUDTheme"):setValue(4)
iconPanel:applyLayout()
check(iconPanel.wingButton.image.path:find("hud_chevron_right.png", 1, true)
    and iconPanel.collapseButton.image.path:find("hud_chevron_left.png", 1, true),
    "wings theme: each chevron points toward the dashboard while expanded")
iconPanel:setWing("left", true)
check(iconPanel.wingButton.image.path:find("hud_chevron_left.png", 1, true),
    "folded left wing points outward to expand")
optionSets.MinidoracatAutoDrive:getOption("HUDTheme"):setValue(1)
local seen = 0
for i = 1, #iconLoads do if iconLoads[i]:find("hud_palette.png", 1, true) then seen = seen + 1 end end
checkEq(seen, 1, "each icon is looked up once and cached for the chunk lifetime")
iconPanel:removeFromUIManager()
getTexture = nil
MDAD.HUD = nil
loadHUD()
MDAD.HUD = liveHUD

print("HUD assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
