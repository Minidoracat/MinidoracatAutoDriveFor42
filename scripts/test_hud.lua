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
    UI_MinidoracatAutoDrive_HUDStatusYieldResume = "RESUME IN %1 S",
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
    UI_MinidoracatAutoDrive_HUDCruiseCap = "CRUISE LIMIT",
    UI_MinidoracatAutoDrive_HUDGear = "MODE",
    UI_MinidoracatAutoDrive_HUDEnergy = "BAT %1%% FUEL %2%%",
    UI_MinidoracatAutoDrive_HUDDriveTime = "DRIVE TIME",
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
    -- 多停靠點行程（addon-api §6）：Driver 回傳的原因鍵、HUD 短標籤與行程文案
    UI_MinidoracatAutoDrive_TripBusy = "ANOTHER CONTROLLER HAS THIS LEG",
    UI_MinidoracatAutoDrive_TripState = "TRIP STATE CANNOT DRIVE",
    UI_MinidoracatAutoDrive_TripStale = "TRIP CHANGED, START AGAIN",
    UI_MinidoracatAutoDrive_TripNotStopped = "STOP THE CAR FIRST",
    UI_MinidoracatAutoDrive_TripRoadEnd = "ROAD ENDS, WALK THE REST",
    UI_MinidoracatAutoDrive_TripLost = "TRIP CONTROL ENDED",
    UI_MinidoracatAutoDrive_HUDStatusTripBusy = "TAKEN OVER",
    UI_MinidoracatAutoDrive_HUDStatusTripState = "TRIP NOT READY",
    UI_MinidoracatAutoDrive_HUDStatusTripStale = "TRIP CHANGED",
    UI_MinidoracatAutoDrive_HUDStatusTripNotStopped = "STOP FIRST",
    UI_MinidoracatAutoDrive_HUDStatusTripRoadEnd = "ROAD END",
    UI_MinidoracatAutoDrive_HUDStatusTripLost = "CONTROL RETURNED",
    UI_MinidoracatAutoDrive_HUDTripStart = "TRIP START",
    UI_MinidoracatAutoDrive_HUDTripResume = "TRIP RESUME",
    UI_MinidoracatAutoDrive_HUDTripManual = "WALK THERE",
    UI_MinidoracatAutoDrive_HUDTripAt = "PT %1, %2",
    UI_MinidoracatAutoDrive_HUDTripTip = "TRIP %1 OF %2: %3",
    UI_MinidoracatAutoDrive_HUDTripPhaseDraft = "PHASE DRAFT",
    UI_MinidoracatAutoDrive_HUDTripPhaseNavigating = "PHASE NAV",
    UI_MinidoracatAutoDrive_HUDTripPhaseApproach = "PHASE APPROACH",
    UI_MinidoracatAutoDrive_HUDTripPhaseWaiting = "PHASE WAITING",
    UI_MinidoracatAutoDrive_HUDTripPhasePaused = "PHASE PAUSED",
    UI_MinidoracatAutoDrive_HUDTripPhaseCompleted = "TRIP DONE",
    -- 接續模式（v7 快照 schemaVersion 2）：藥丸短字、選單兩項、拒絕原因與階段字
    UI_MinidoracatAutoDrive_HUDTripContinue = "TRIP CONTINUE",
    UI_MinidoracatAutoDrive_HUDCancelPrep = "CANCEL PREP",
    UI_MinidoracatAutoDrive_HUDActionStart = "Start",
    UI_MinidoracatAutoDrive_HUDActionStop = "Stop",
    UI_MinidoracatAutoDrive_HUDActionContinue = "Continue",
    UI_MinidoracatAutoDrive_HUDActionCancel = "Cancel",
    UI_MinidoracatAutoDrive_HUDActionWalk = "Walk",
    UI_MinidoracatAutoDrive_HUDContAuto = "CONT AUTO",
    UI_MinidoracatAutoDrive_HUDContStep = "CONT STEP",
    UI_MinidoracatAutoDrive_HUDContMenuAuto = "MENU AUTO",
    UI_MinidoracatAutoDrive_HUDContMenuStep = "MENU STEP",
    UI_MinidoracatAutoDrive_HUDContTip = "CONT TIP",
    UI_MinidoracatAutoDrive_HUDContFailed = "CONT FAILED SENTENCE",
    UI_MinidoracatAutoDrive_HUDStatusContFailed = "MODE UNCHANGED",
    UI_MinidoracatAutoDrive_HUDStatusTripWaiting = "STOPPED OVER",
    UI_MinidoracatAutoDrive_HUDStatusTripDone = "TRIP COMPLETE",
    UI_MinidoracatAutoDrive_HUDTripDriving = "DRIVE TO %1 THEN %2",
    UI_MinidoracatAutoDrive_HUDTripDrivingLast = "DRIVE TO %1 LAST",
    UI_MinidoracatAutoDrive_HUDTripPrep = "PREP %1",
    UI_MinidoracatAutoDrive_HUDTripTargets = "%1 -> %2",
    UI_MinidoracatAutoDrive_HUDTripHoldShort = "(WAIT)",
    UI_MinidoracatAutoDrive_HUDTripWalkTo = "WALK TO %1",
    UI_MinidoracatAutoDrive_HUDTripStopover = "AT %1 NEXT %2",
    UI_MinidoracatAutoDrive_HUDTripStopoverEnd = "AT %1 DONE",
    UI_MinidoracatAutoDrive_HUDTripHold = "(HOLD)",
    UI_MinidoracatAutoDrive_HUDStatusTripSkipped = "STOP SKIPPED",
    UI_MinidoracatAutoDrive_HUDStatusTripUnavailable = "CONTINUATION BLOCKED",
    UI_MinidoracatAutoDrive_TripUnavailable = "CANNOT CONTINUE SENTENCE",
    UI_MinidoracatAutoDrive_TripNoRoad = "NO ROUTE SENTENCE",
    UI_MinidoracatAutoDrive_HUDTripSkipped = "SKIPPED %1 NEXT %2",
    UI_MinidoracatAutoDrive_HUDTripSkippedEnd = "SKIPPED %1 DONE",
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
-- ISUIElement:isVisible（ISUIElement.lua）——ISButton 繼承同一個讀取面
function ISButton:isVisible() return self.visible end
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
-- ISBaseObject:derive 的等價（ISButton = ISPanel:derive，ISButton.lua:3）：接續模式
-- 藥丸是 ISButton 的子類，底色／命中沿用原版，glyph 與短字自己畫。
function ISButton:derive(name)
    local class = { Type = name }
    class.__index = class
    setmetatable(class, { __index = self })
    return class
end
-- ISButton:prerender 畫底色／邊框（ISButton.lua:111-140）、render 畫圖與標題（:196-240）
function ISButton:prerender() self.prerenders = (self.prerenders or 0) + 1 end
function ISButton:render() self.renders = (self.renders or 0) + 1 end
function ISButton:drawRect(x, y, w, h, a, r, g, b)
    self.rects = self.rects or {}
    self.rects[#self.rects + 1] = { x = x, y = y, w = w, h = h, a = a, r = r, g = g, b = b }
end
function ISButton:drawText(text, x, y)
    self.texts = self.texts or {}
    self.texts[#self.texts + 1] = { text = text, x = x, y = y }
end

-- 原版 ISButton:onMouseUp 走 self.onclick(self.target, self, ...)（ISButton.lua:47-48）。
local function click(button)
    button.onclick(button.target, button)
end

-- 原版右鍵選單樁：get 取玩家單例並清空（ISContextMenu.lua:1166-1196）；點擊走
-- option.onSelect(option.target, option.param1…)（:66-70），notAvailable 會被擋下（:66）。
ISContextMenu = {}
ISContextMenu.get = function(player, x, y)
    local menu = { player = player, x = x, y = y, options = {} }
    function menu:addOption(name, target, onSelect, param1, param2)
        local option = { name = name, target = target, onSelect = onSelect, param1 = param1, param2 = param2 }
        self.options[#self.options + 1] = option
        return option
    end
    function menu:pick(name)
        for i = 1, #self.options do
            local option = self.options[i]
            if option.name == name then
                if option.notAvailable then return false end
                option.onSelect(option.target, option.param1, option.param2)
                return true
            end
        end
        return false
    end
    ISContextMenu.lastMenu = menu
    return menu
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
    -- 0908c 契約：第 7 值＝本趟／末趟現實秒數（nil＝尚無紀錄）。停用態前 6 值維持
    -- nil（inactive），第 7 值仍回報凍結的末趟秒數。
    if not state.active then
        return nil, nil, nil, nil, nil, nil, state.elapsed
    end
    return state.token, state.gear, state.cap, state.zombie, state.corpse,
        state.resumeIn, state.elapsed, state.legReportWhy
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
dofile("MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua/shared/MDAD_Dynamics.lua")
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
do
    local originalInfo = MDAD.Drive.slowdownInfo
    local ahead = 63.999999999
    MDAD.Drive.slowdownInfo = function() return 2, ahead, 3, 25, 15, 10, 20 end
    panel:refresh(nowMs)
    checkEq(panel.zombieButton.tooltip:match("DETECT (%S+)"), "2-63",
        "zombie range uses whole metres without overstating completed coverage")
    checkEq(panel.corpseButton.tooltip:match("DETECT (%S+)"), "2-63",
        "corpse range does not expose fractional scan arithmetic")
    ahead = 64.25
    panel:refresh(nowMs)
    checkEq(panel.zombieButton.tooltip:match("DETECT (%S+)"), "2-64",
        "zombie range still follows updated effective sensing distance")
    checkEq(panel.corpseButton.tooltip:match("DETECT (%S+)"), "2-64",
        "corpse range refreshes at the same metre boundary")
    MDAD.Drive.slowdownInfo = originalInfo
    panel:refresh(nowMs)
end
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
-- 行車時間（0908d）：左翼展開時與巡航同款——欄名一列、數值一列，兩欄並排。
do
    state.elapsed = 45296
    panel:refresh(nowMs)
    local capRight = math.max(
        panel._capX + textManager:MeasureStringX(UIFont.Small, panel._capLabel),
        panel._capValueX + textManager:MeasureStringX(UIFont.Small, panel._capText))
    local timeRight = math.max(
        panel._timeX + textManager:MeasureStringX(UIFont.Small, panel._timeLabel),
        panel._timeValueX + textManager:MeasureStringX(UIFont.Small, panel._clockText))
    check(panel._timeLabelY == panel._capLabelY and panel._timeValueY == panel._capValueY
        and panel._capValueY == panel._capLabelY + textManager:getFontHeight(UIFont.Small)
        and panel._capValueX == panel._capX and panel._timeValueX == panel._timeX
        and panel._timeX >= capRight and timeRight + 4 <= panel.wingButton.x,
        "wings theme: both columns stack the name over the value on the same two rows, clear of the chevron")
    state.elapsed = nil
    panel:refresh(nowMs)
end
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
do
    local clockW = textManager:MeasureStringX(UIFont.Small, "00:00:00")
    check(panel._timeX == nil
        and panel._timeValueX >= panel._speedX + textManager:MeasureStringX(UIFont.Medium, "120")
        and panel._timeValueX + clockW + 4 <= panel.wingButton.x,
        "wings theme: the folded left badge drops the column name and keeps the bare clock")
end
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

check(panel._capLabelY < panel._capValueY and panel._capValueX == panel._capX
    and panel._timeLabelY == panel._capLabelY and panel._timeValueY == panel._capValueY
    and panel._timeValueX == panel._timeX and panel._timeX > panel._capX
    and panel._capValueY + textManager:getFontHeight(UIFont.Small) <= panel._dividerY,
    "full layout stacks name over value for both cruise and drive time inside the top row")
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
check(panel.actionButton.visible == false
    and not panel.themeButton.visible and not panel.voiceButton.visible
    and not panel.volumeSlider.visible,
    "collapsed mode is badge only: style/voice/volume hidden")
check(panel.collapseButton.visible and panel.collapseButton.title == "SHOW"
    and panel.collapseButton.x + panel.collapseButton.width <= panel.width,
    "collapsed badge keeps the expand control on itself")
-- 收合徽章：狀態燈＋現速＋純數字時間＋展開鈕；欄名省掉，時間欄仍以 "00:00:00"
-- 保留寬度，所以跨過一小時也不會推到 chevron 上。
do
    local clockW = textManager:MeasureStringX(UIFont.Small, "00:00:00")
    check(panel._timeX == nil
        and panel._timeValueX >= panel._speedX + textManager:MeasureStringX(UIFont.Medium, "120")
        and panel._timeValueX + clockW + 4 <= panel.collapseButton.x
        and panel._clockText == "--:--",
        "collapsed badge drops the column name and keeps the bare clock before the expand chevron")
end
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
do
    local oldPending, oldVolume = MDAD.Drive.isPausePending, MDAD.HUD.voiceVolume()
    MDAD.Drive.isPausePending = function() return true end
    panel:refresh(nowMs)
    local count = #voiceCalls
    panel:onVolume(35, true)
    checkEq(#voiceCalls, count, "待暫停通知未播完：調音量不以試聽蓋掉通知")
    click(panel.voiceButton)
    click(panel.voiceButton)
    checkEq(#voiceCalls, count, "待暫停通知未播完：重開語音不以試聽蓋掉通知")
    MDAD.Drive.isPausePending = function() return false end
    count = #voiceCalls
    panel:onVolume(oldVolume, true)
    checkEq(#voiceCalls, count + 1, "沒有待暫停通知時保留原本音量試聽")
    MDAD.Drive.isPausePending = oldPending
end
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
-- 讓位狀態（2026-09-06）：按著＝「手動操作中」；放手後 hudState 第 6 值＝幾秒後恢復 → 倒數文案
state.token = "yield"
panel:refresh(nowMs)
checkEq(panel._statusText, "YIELD", "yield without countdown shows the manual-control label")
state.resumeIn = 2
panel:refresh(nowMs)
checkEq(panel._statusText, "RESUME IN 2 S", "yield countdown formats the seconds into the status text")
state.resumeIn = nil
state.token = "follow"
panel:refresh(nowMs)
checkEq(panel._statusText, "FOLLOW", "countdown value is ignored outside yield")
state.active, state.startReason = false, "UI_MinidoracatAutoDrive_EngineOff"
panel:refresh(nowMs)

-- 行車時間（0908d，hudState 第 7 值）：格式進位、停用凍結、缺值退路，欄名固定不隨狀態改字，
-- 以及「每 250ms 換一次字串不得動到版面」這條硬契約。
do
    state.active, state.startReason, state.token = true, nil, "follow"
    local driveTimeLabel = panel._timeLabel
    state.elapsed = nil
    panel:refresh(nowMs)
    checkEq(panel._clockText, "--:--", "no drive on record shows the placeholder instead of a zero clock")
    state.elapsed = 0
    panel:refresh(nowMs)
    checkEq(panel._clockText, "00:00", "a fresh start reads zero, not the previous drive")
    state.elapsed = 605
    panel:refresh(nowMs)
    checkEq(panel._clockText, "10:05", "under an hour stays MM:SS with padded seconds")
    state.elapsed = 3599
    panel:refresh(nowMs)
    checkEq(panel._clockText, "59:59", "the last second under an hour is still MM:SS")
    local underHourWidth, underHourValueX = panel.width, panel._timeValueX
    state.elapsed = 3600
    panel:refresh(nowMs)
    checkEq(panel._clockText, "1:00:00", "crossing one hour switches to H:MM:SS")
    state.elapsed = 45296
    panel:refresh(nowMs)
    checkEq(panel._clockText, "12:34:56", "hours are unpadded, minutes and seconds padded")
    check(panel.width == underHourWidth and panel._timeValueX == underHourValueX,
        "the clock never relayouts: MM:SS and H:MM:SS share one reserved column")
    -- 位置：接在巡航欄之後、與巡航欄同兩列，且整欄停在主鈕與金屬控制方塊之前
    local capRight = math.max(
        panel._capX + textManager:MeasureStringX(UIFont.Small, panel._capLabel),
        panel._capValueX + textManager:MeasureStringX(UIFont.Small, panel._capText))
    local timeRight = math.max(
        panel._timeX + textManager:MeasureStringX(UIFont.Small, panel._timeLabel),
        panel._timeValueX + textManager:MeasureStringX(UIFont.Small, panel._clockText))
    check(panel._timeX >= capRight and panel._timeLabelY == panel._capLabelY
        and panel._timeValueY == panel._capValueY
        and timeRight <= panel.actionButton.x and timeRight <= panel._blockX,
        "full metal: the drive-time column mirrors the cruise column and clears the action button")
    state.active, state.startReason = false, "UI_MinidoracatAutoDrive_EngineOff"
    panel:refresh(nowMs)
    check(panel._statusText == "ENGINE OFF" and panel._clockText == "12:34:56"
        and panel._timeLabel == driveTimeLabel,
        "stopping freezes the last drive time under the very same column name")
    state.elapsed = 0
    panel:refresh(nowMs)
    checkEq(panel._clockText, "00:00", "a completed zero-second drive is still a record")
    state.elapsed = 359999
    panel:refresh(nowMs)
    checkEq(panel._clockText, "99:59:59", "the last second before the ceiling is still a real duration")
    state.elapsed = 360000
    panel:refresh(nowMs)
    checkEq(panel._clockText, "100h+", "long drives use an explicit overflow marker, not a false duration")
    state.elapsed = math.huge
    panel:refresh(nowMs)
    checkEq(panel._clockText, "--:--", "non-finite elapsed time is refused, not rendered")
    state.elapsed = nil
    panel:refresh(nowMs)
    checkEq(panel._clockText, "--:--", "an inactive HUD with nothing on record shows the placeholder")
    state.elapsed = -1
    panel:refresh(nowMs)
    checkEq(panel._clockText, "--:--", "a negative elapsed value is refused, not rendered")
    state.active, state.startReason, state.token = true, nil, "follow"
    state.elapsed = 900
    panel:refresh(nowMs)
    checkEq(panel._clockText, "15:00", "restoring the full contract resumes the live clock")
    -- prerender 只畫快取：數值在 refresh 算好、欄名在 layout 算好，畫面路徑不得再 getText／量測
    local textsBefore, measuresBefore = getTextCalls, measureCalls
    panel:prerender()
    check(getTextCalls == textsBefore and measureCalls == measuresBefore,
        "prerender draws the cached column name and clock without translating or measuring")
    state.active, state.startReason = false, "UI_MinidoracatAutoDrive_EngineOff"
    state.elapsed = nil
    panel:refresh(nowMs)
end

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
    and registeredMiniMapSection.actions == nil,
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
-- 閃避殭屍 tick（0906c；預設開）坐在改道與診斷之間
check(registeredMiniMapSection.ticks[4].label == "UI_MinidoracatAutoDrive_ZombieDodge"
    and registeredMiniMapSection.ticks[4].get() == true
    and MDAD.HUD.zombieDodge() == true,
    "zombie-dodge tick defaults on and sits between auto-detour and telemetry")
registeredMiniMapSection.ticks[4].set(false)
check(MDAD.HUD.zombieDodge() == false
    and options:getOption("ZombieDodge"):getValue() == false,
    "MiniMap zombie-dodge tick writes the shared ZombieDodge option")
registeredMiniMapSection.ticks[4].set(true)
registeredMiniMapSection.ticks[5].set(false)
check(not MDAD.HUD.telemetryEnabled()
    and options:getOption("ExportTelemetry"):getValue() == false,
    "MiniMap telemetry tick writes the same AutoDrive ModOptions value")
do
    local stuckTick, arrivalTick
    for _, tick in ipairs(registeredMiniMapSection.ticks) do
        if tick.label == "UI_MinidoracatAutoDrive_PauseOnStuck" then stuckTick = tick end
        if tick.label == "UI_MinidoracatAutoDrive_PauseOnArrival" then arrivalTick = tick end
    end
    check(stuckTick and stuckTick.get() == true and MDAD.HUD.pauseOnStuck() == true
        and options:getOption("PauseOnStuck"):getValue() == true,
        "受困暫停在 MiniMap、ESC 與 Driver getter 預設開啟")
    check(arrivalTick and arrivalTick.get() == true and MDAD.HUD.pauseOnArrival() == true
        and options:getOption("PauseOnArrival"):getValue() == true,
        "抵達暫停在 MiniMap、ESC 與 Driver getter 預設開啟")
    stuckTick.set(false)
    check(stuckTick.get() == false and options:getOption("PauseOnStuck"):getValue() == false
        and MDAD.HUD.pauseOnStuck() == false,
        "MiniMap 關閉受困暫停同步反映到 ESC 與 Driver getter")
    check(arrivalTick.get() == true and options:getOption("PauseOnArrival"):getValue() == true
        and MDAD.HUD.pauseOnArrival() == true,
        "關閉受困暫停不更動抵達暫停")
    stuckTick.set(true)
    arrivalTick.set(false)
    check(arrivalTick.get() == false and options:getOption("PauseOnArrival"):getValue() == false
        and MDAD.HUD.pauseOnArrival() == false,
        "MiniMap 關閉抵達暫停同步反映到 ESC 與 Driver getter")
    check(stuckTick.get() == true and options:getOption("PauseOnStuck"):getValue() == true
        and MDAD.HUD.pauseOnStuck() == true,
        "關閉抵達暫停不更動已開啟的受困暫停")
    stuckTick.set(false)
    options:getOption("PauseOnStuck"):setValue(true)
    options:apply()
    check(stuckTick.get() == true and MDAD.HUD.pauseOnStuck() == true,
        "ESC 開啟受困暫停同步反映到 MiniMap 與 Driver getter")
    check(arrivalTick.get() == false and options:getOption("PauseOnArrival"):getValue() == false
        and MDAD.HUD.pauseOnArrival() == false,
        "ESC 開啟受困暫停不更動抵達暫停")
    options:getOption("PauseOnArrival"):setValue(true)
    options:apply()
    check(arrivalTick.get() == true and MDAD.HUD.pauseOnArrival() == true,
        "ESC 開啟抵達暫停同步反映到 MiniMap 與 Driver getter")
    check(stuckTick.get() == true and options:getOption("PauseOnStuck"):getValue() == true
        and MDAD.HUD.pauseOnStuck() == true,
        "ESC 開啟抵達暫停不更動受困暫停")
end
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
-- 手動介入後 combo（2026-09-06 使用者裁定預設「不自動恢復」）：index 1＝0ms（介入即關閉），
-- 2..5＝2/3/5/10 秒；Driver 讀 manualResumeMs、MiniMap 與 ESC 共用同一 option
local manualResumeCombo = registeredMiniMapSection.combos[4]
check(manualResumeCombo.label == "UI_MinidoracatAutoDrive_ManualResume"
    and #manualResumeCombo.items == 5
    and manualResumeCombo.items[1] == "UI_MinidoracatAutoDrive_ManualResumeOff"
    and manualResumeCombo.items[5] == "UI_MinidoracatAutoDrive_ManualResume10"
    and manualResumeCombo.default == 1,
    "manual-resume combo lists off + 2/3/5/10 s with off as default")
check(MDAD.HUD.manualResumeMs() == 0 and MDAD.HUD.manualResumeIndex() == 1
    and options:getOption("ManualResume"):getValue() == 1,
    "manual resume defaults to 0 ms = intervention switches autodrive off")
manualResumeCombo.set(2)
check(MDAD.HUD.manualResumeMs() == 2000
    and options:getOption("ManualResume"):getValue() == 2,
    "MiniMap manual-resume combo writes the shared option and maps index 2 to 2000 ms")
manualResumeCombo.set(5)
checkEq(MDAD.HUD.manualResumeMs(), 10000, "index 5 maps to 10000 ms")
local manualResumeSaves = optionSaveCalls
check(not MDAD.HUD.setManualResumeIndex(6) and not MDAD.HUD.setManualResumeIndex(0)
    and MDAD.HUD.manualResumeMs() == 10000 and optionSaveCalls == manualResumeSaves,
    "out-of-range manual-resume index rejected without saving")
manualResumeCombo.set(1)
checkEq(MDAD.HUD.manualResumeMs(), 0, "back to off = 0 ms")
-- 調頭方式 combo（2026-09-06 使用者裁定預設「溫和」）：index 1＝gentle、2＝fast；Driver 每次
-- 調頭開始讀 uturnMode；MiniMap 與 ESC 共用同一 option
local uturnCombo = registeredMiniMapSection.combos[5]
check(uturnCombo.label == "UI_MinidoracatAutoDrive_UTurnMode"
    and #uturnCombo.items == 2
    and uturnCombo.items[1] == "UI_MinidoracatAutoDrive_UTurnGentle"
    and uturnCombo.items[2] == "UI_MinidoracatAutoDrive_UTurnFast"
    and uturnCombo.default == 1,
    "U-turn combo lists gentle + fast with gentle as default")
check(MDAD.HUD.uturnMode() == "gentle" and MDAD.HUD.uturnIndex() == 1
    and options:getOption("UTurnMode"):getValue() == 1,
    "U-turn style defaults to gentle")
uturnCombo.set(2)
check(MDAD.HUD.uturnMode() == "fast" and options:getOption("UTurnMode"):getValue() == 2,
    "MiniMap U-turn combo writes the shared option and maps index 2 to fast")
local uturnSaves = optionSaveCalls
check(not MDAD.HUD.setUTurnIndex(3) and not MDAD.HUD.setUTurnIndex(0)
    and MDAD.HUD.uturnMode() == "fast" and optionSaveCalls == uturnSaves,
    "out-of-range U-turn index rejected without saving")
options:getOption("UTurnMode"):setValue(9)
checkEq(MDAD.HUD.uturnMode(), "gentle", "corrupt U-turn option reads back as gentle")
uturnCombo.set(1)
do
    local perception = registeredMiniMapSection.combos[6]
    checkEq(MDAD.HUD.perceptionDistance(), 120, "new sensing default is 120 metres")
    perception.set(1)
    checkEq(MDAD.HUD.perceptionDistance(), 48, "MiniMap can select the lower sensing distance")
    check(MDAD.HUD.setPerceptionDistance(200) and perception.get() == 5,
        "distance setter and MiniMap use the same persisted option")
    local saves = optionSaveCalls
    check(not MDAD.HUD.setPerceptionDistance(121) and not perception.set(0)
        and not perception.set(0 / 0) and optionSaveCalls == saves
        and MDAD.HUD.perceptionDistance() == 200, "invalid distances/indices do not overwrite preferences")
    options:getOption("PerceptionDistance"):setValue(0 / 0)
    checkEq(MDAD.HUD.perceptionDistance(), 120, "corrupt sensing setting returns the documented default")
    perception.set(3)
end
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
check(registeredMiniMapSection.actions ~= nil,
    "v2 MiniMap spec exposes actions")
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
-- 精簡單行：行車時間也是同列基線的「欄名＋數值」，整欄插在巡航值與檔位鈕之間
do
    state.elapsed = 45296
    panel:refresh(nowMs)
    local timeRight = panel._timeValueX
        + textManager:MeasureStringX(UIFont.Small, panel._clockText)
    check(panel._timeX >= capRight
        and panel._timeLabelY == panel._capLabelY and panel._timeValueY == panel._capValueY
        and panel._timeValueX > panel._timeX
            + textManager:MeasureStringX(UIFont.Small, panel._timeLabel)
        and timeRight + 3 <= panel.cycleButton.x,
        "compact layout keeps the drive-time name and clock inline on the cruise baseline")
    state.elapsed = nil
    panel:refresh(nowMs)
end
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
    if candidate._effectiveLayout == 2 and candidate._capValueX then
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
    else
        check(candidate._timeX == nil and candidate._timeValueX == nil,
            "split slot " .. slot .. " ultra-narrow degradation drops the whole drive-time column")
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

-- 多停靠點行程（addon-api §6）：HUD 只讀公開的 getNavLeg／getNavItinerary，
-- 接續一律走 Drive.continueItinerary。這段守的是狀態切換、revision 節流、
-- 舊主 MOD 降級與「四主題／精簡／窄 viewport 都不能裁掉操作」。
do
    local trip = {
        phase = nil,
        revision = 7,
        stopId = nil,
        legCalls = 0,
        snapshotCalls = 0,
        continueCalls = 0,
        continueOk = true,
        continueReason = nil,
        data = {
            schemaVersion = 1,
            count = 3,
            currentStopId = nil,
            stops = {
                { id = 1, x = 100, y = 200, label = "HOME", status = "arrived" },
                { id = 2, x = 300, y = 400, label = "GAS STATION", status = "pending" },
                { id = 3, x = 500, y = 600, status = "pending" },
            },
        },
    }
    -- 契約回傳形狀：(legToken, stopId, x, y, phase, revision)；無行程 (nil, "noitinerary")。
    MinidoracatMiniMapAPI.getNavLeg = function()
        trip.legCalls = trip.legCalls + 1
        if not trip.phase then return nil, "noitinerary" end
        return trip.legToken, trip.stopId, 300, 400, trip.phase, trip.revision
    end
    MinidoracatMiniMapAPI.getNavItinerary = function()
        trip.snapshotCalls = trip.snapshotCalls + 1
        if not trip.phase then return nil, "noitinerary" end
        trip.data.revision = trip.revision
        trip.data.phase = trip.phase
        return trip.data
    end
    MDAD.Drive.continueItinerary = function()
        trip.continueCalls = trip.continueCalls + 1
        if trip.continueOk then return true end
        return false, trip.continueReason
    end

    texts.UI_MinidoracatAutoDrive_HUDStatusNoNav = "NO NAV"
    options:getOption("HUDTheme"):setValue(1)
    options:getOption("HUDLayout"):setValue(1)
    options:getOption("HUDScale"):setValue(2)
    options:apply()
    state.active, state.token, state.startReason = false, "follow", nil

    -- 舊主 MOD：版本不足或函式缺席都必須整段降級成原本的單站 HUD。
    trip.phase = "draft"
    MinidoracatMiniMapAPI.navApiVersion = 5
    panel:refresh(nowMs)
    check(panel._hasTrip == false and panel._tripText == nil
        and panel.actionButton.title == "START",
        "navApiVersion 5 keeps the single-stop HUD; no trip line, no trip action")
    MinidoracatMiniMapAPI.navApiVersion = 6
    local liveLeg = MinidoracatMiniMapAPI.getNavLeg
    MinidoracatMiniMapAPI.getNavLeg = nil
    panel:refresh(nowMs)
    check(panel._hasTrip == false and panel.actionButton.title == "START",
        "v6 version field without the trip functions still degrades to the single-stop HUD")
    MinidoracatMiniMapAPI.getNavLeg = liveLeg

    -- draft：目前站是第一個 pending（已完成前綴保留），主鈕變成「開始行程」。
    panel:refresh(nowMs)
    check(panel._hasTrip, "v6 itinerary switches the HUD into trip mode")
    checkEq(panel.actionButton.title, "TRIP START", "draft offers the start-trip action")
    check(panel._tripText and panel._tripText:find("GAS STATION", 1, true)
        and panel._tripText ~= panel._tripCounter,
        "the trip line names the stop being headed to instead of only its N/M counter")
    checkEq(panel._tripCounter, "2/3", "the counter stays available as the secondary short form")
    check(panel.actionButton.tooltip and panel.actionButton.tooltip:find("GAS STATION", 1, true),
        "the full readable trip hint reaches the main button tooltip")
    check(panel._tripDrawY == panel._textY + textManager:getFontHeight(UIFont.Small)
        and panel._tripTextY == panel._tripDrawY and panel._tripTextX == panel._statusX
        and panel._tripDrawY + textManager:getFontHeight(UIFont.Small) <= panel._dividerY,
        "full layout stacks the trip line under the status line without touching the button row")
    check(panel._unitY > panel._textY,
        "the km/h unit stays on the speed baseline when the status column becomes two lines")
    check(panel._tripTextX + textManager:MeasureStringX(UIFont.Small, panel._tripText)
        <= panel._statusX + panel._tripMaxW,
        "trip line stays inside its own column")

    -- 行駛中：安全狀態與改道鈕優先，主鈕回到停止自駕且不經過行程入口。
    state.active, state.token = true, "blocked"
    panel:refresh(nowMs)
    checkEq(panel._statusText, "HOLDING", "trip mode never hides the driving safety status")
    check(panel.detourButton.visible, "reroute pill is still reachable in trip mode")
    if panel._tripText then
        check(panel._tripTextX + textManager:MeasureStringX(UIFont.Small, panel._tripText)
            <= panel.detourButton.x - panel._detourGap,
            "the trip second line stays clear of the reroute button")
    end
    state.token = "arrive"
    panel:refresh(nowMs)
    local acceptedArrivalStatus = panel._statusText
    state.legReportWhy = "UI_MinidoracatAutoDrive_TripBusy"
    panel:refresh(nowMs)
    check(panel._statusText ~= acceptedArrivalStatus
        and panel.actionButton.tooltip:find(getText("UI_MinidoracatAutoDrive_TripBusy"), 1, true),
        "a rejected arrival stays visible with its cause instead of claiming arrival")
    state.legReportWhy = nil
    panel:refresh(nowMs)
    checkEq(panel._statusText, acceptedArrivalStatus, "a resolved arrival clears the old failure")
    state.token = "blocked"
    panel:refresh(nowMs)
    checkEq(panel.actionButton.title, "STOP", "an active session keeps the disengage action")
    local activeCalls = trip.continueCalls
    click(panel.actionButton)
    check(trip.continueCalls == activeCalls and state.active == false,
        "stopping autodrive never routes through the trip continuation entry")
    state.token = "follow"

    -- waiting：主鈕＝前往下一站，且真的呼叫 Driver 的有副作用入口。
    trip.phase = "waiting"
    trip.data.currentStopId = 1
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    local reachedAt = panel.actionButton.tooltip:find("HOME", 1, true)
    local nextAt = panel.actionButton.tooltip:find("GAS STATION", 1, true)
    check(reachedAt and nextAt and reachedAt < nextAt,
        "waiting names the stop just reached before the one it will head to next")
    checkEq(panel.actionButton.title, "TRIP CONTINUE",
        "waiting labels the main button as an explicit autodrive continuation")
    local waitingCalls = trip.continueCalls
    click(panel.actionButton)
    checkEq(trip.continueCalls, waitingCalls + 1,
        "the next-stop button calls Drive.continueItinerary once")

    -- 被拒：狀態列看得到原因、完整句在 tooltip，且原因會過期回到常態啟動守門。
    trip.continueOk, trip.continueReason = false, "UI_MinidoracatAutoDrive_TripNotStopped"
    click(panel.actionButton)
    checkEq(panel._statusText, "STOP FIRST",
        "a rejected trip start shows the driver's reason instead of doing nothing")
    check(panel.actionButton.tooltip
        and panel.actionButton.tooltip:find("STOP THE CAR FIRST", 1, true),
        "the full rejection sentence reaches the main button tooltip")
    nowMs = nowMs + 6000
    panel:refresh(nowMs)
    checkEq(panel._statusText, "STOPPED OVER",
        "the rejection notice expires back to the phase wording, not to the single-stop 'ready'")
    trip.continueOk, trip.continueReason = true, nil

    -- 無名稱的站退座標；快照只在 phase／revision／目前站變更時重取。
    trip.data.stops[2].status = "arrived"
    trip.phase, trip.stopId, trip.legToken = "navigating", 3, "leg3"
    trip.data.currentStopId = 3
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    check(panel._tripText and panel._tripText:find("500", 1, true)
        and panel._tripText:find("LAST", 1, true),
        "a stop without a label falls back to its coordinates and reports it is the last one")
    local snapshots = trip.snapshotCalls
    local legReads = trip.legCalls
    panel:refresh(nowMs)
    panel:refresh(nowMs)
    check(trip.snapshotCalls == snapshots and trip.legCalls == legReads + 2,
        "unchanged revision reuses the cached snapshot; only the zero-alloc leg getter runs")
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    checkEq(trip.snapshotCalls, snapshots + 1, "a revision bump refetches the snapshot exactly once")

    -- prerender 仍是純快取繪製（行程行不得引入 getText／量測），三段文字各自的基線也要對：
    -- 狀態在上、行程在下、km/h 仍貼著現速，不會被兩行狀態欄拉走。
    local renderTexts, renderMeasures = getTextCalls, measureCalls
    local painted = {}
    panel.drawText = function(_, text, x, y) painted[#painted + 1] = { text = text, y = y } end
    panel:prerender()
    panel.drawText = nil
    local function paintedY(text)
        for i = 1, #painted do
            if painted[i].text == text then return painted[i].y end
        end
        return nil
    end
    check(getTextCalls == renderTexts and measureCalls == renderMeasures and #painted > 0,
        "trip mode prerender draws from cache only: no translation lookup, no measurement")
    check(paintedY(panel._statusText) == panel._textY
        and paintedY(panel._tripText) == panel._tripDrawY
        and paintedY(panel._unitText) == panel._unitY
        and panel._unitY ~= panel._textY,
        "status, trip line and the km/h unit each paint on their own baseline")

    -- approach：契約禁止自駕再次接管，主鈕顯示手動前往，按下只回報原因。
    trip.phase = "approach"
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    checkEq(panel.actionButton.title, "WALK THERE", "approach offers no autodrive action")
    checkEq(panel._statusText, "READY", "approach without a driver reason keeps the normal status")
    local approachCalls = trip.continueCalls
    click(panel.actionButton)
    check(trip.continueCalls == approachCalls and panel._statusText == "ROAD END",
        "the manual-walk button reports why instead of starting autodrive or doing nothing")

    -- paused／completed 的主鈕語意
    trip.phase = "paused"
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    checkEq(panel.actionButton.title, "TRIP RESUME", "paused offers the resume action")
    trip.phase = "completed"
    trip.data.stops[3].status = "arrived"
    trip.data.currentStopId = nil
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    check(panel.actionButton.title == "START" and panel._tripText == "TRIP DONE",
        "a completed trip stops offering trip actions and reports the trip as finished")
    trip.phase = "waiting"
    trip.data.stops[3].status = "pending"
    trip.data.currentStopId = 2
    trip.revision = trip.revision + 1

    -- 四主題＋精簡單行＋窄分割 viewport：行程行可以退讓，操作控制不能被裁掉。
    for _, layoutMode in ipairs({ 1, 2 }) do
        options:getOption("HUDLayout"):setValue(layoutMode)
        for theme = 1, 4 do
            options:getOption("HUDTheme"):setValue(theme)
            options:apply()
            panel:refresh(nowMs)
            local label = "layout " .. layoutMode .. " theme " .. theme
            check(panel.actionButton.visible and panel.actionButton.x >= 0
                and panel.actionButton.x + panel.actionButton.width <= panel.width,
                label .. ": trip action stays reachable inside the panel")
            check(panel.actionButton.title == "TRIP CONTINUE",
                label .. ": trip action keeps its waiting-phase meaning")
            if panel._tripText then
                local right = panel._tripTextX
                    + textManager:MeasureStringX(UIFont.Small, panel._tripText)
                local limit = panel._tripDrawY and (panel._statusX + panel._tripMaxW)
                    or panel._speedX
                check(right <= limit, label .. ": trip line never overruns the next column")
            end
        end
    end
    options:getOption("HUDTheme"):setValue(1)
    options:getOption("HUDLayout"):setValue(1)
    options:getOption("HUDScale"):setValue(3)
    viewportWidth = 640
    fire(Events.OnResolutionChange)
    panel:refresh(nowMs)
    check(panel.width <= viewportWidth - 16 and panel.actionButton.visible
        and panel.actionButton.x >= 0
        and panel.actionButton.x + panel.actionButton.width <= panel.width,
        "narrow split viewport keeps the trip action inside the panel")
    if panel._tripText then
        check(panel._tripTextX
            + textManager:MeasureStringX(UIFont.Small, panel._tripText) <= panel._speedX,
            "narrow split viewport trip line still ends before the speed column")
    end
    viewportWidth = 1920
    options:getOption("HUDScale"):setValue(2)

    -- 收合徽章只剩狀態燈／現速／時間；行程行讓位，展開後回來。
    panel:setCollapsed(true)
    panel:refresh(nowMs)
    check(panel._tripText == nil, "collapsed badge drops the trip line")
    panel:setCollapsed(false)
    panel:refresh(nowMs)
    check(panel._tripText ~= nil, "expanding restores the trip line")

    -- 行程消失（清空／換角色）：面板必須回到原本的單站 HUD。
    trip.phase = nil
    panel:refresh(nowMs)
    check(panel._hasTrip == false and panel._tripText == nil
        and panel.actionButton.title == "START",
        "losing the itinerary returns the HUD to the single-stop layout")

    MinidoracatMiniMapAPI.navApiVersion = nil
    MinidoracatMiniMapAPI.getNavLeg = nil
    MinidoracatMiniMapAPI.getNavItinerary = nil
    MDAD.Drive.continueItinerary = nil
    options:apply()
    panel:refresh(nowMs)
end

-- 接續模式（navApiVersion 7／快照 schemaVersion 2）：HUD 只讀 trip.autoContinue，
-- 寫入只有「玩家從原版選單挑了」這一條路，走 API.setNavContinuation(pn, revision, bool)。
-- 這段守的是：不自己寫、不自己發車；expectedRevision 被拒有原因；模式與停靠旗標的
-- 顯示優先序；v6／缺 setter／舊快照都不得出現假亮的新控制；四主題與精簡單行下
-- 新藥丸不覆蓋任何既有控制；waiting 的「已停靠 A／接著去 B」兩個名字不互換。
do
    local trip = {
        phase = "navigating", revision = 20, stopId = 2, autoContinue = true,
        legCalls = 0, snapshotCalls = 0, setCalls = 0,
        setOk = true, setReason = nil, continueCalls = 0,
    }
    trip.data = {
        schemaVersion = 2,
        count = 3,
        currentStopId = 2,
        autoContinue = true,
        stops = {
            { id = 1, x = 100, y = 200, label = "HOME", status = "arrived" },
            { id = 2, x = 300, y = 400, label = "GAS STATION", status = "pending" },
            -- 第三站被玩家標成「一定停等」：自動接續下仍然要看得出來
            { id = 3, x = 500, y = 600, label = "CABIN", status = "pending", pause = true },
        },
    }
    MinidoracatMiniMapAPI.navApiVersion = 7
    MinidoracatMiniMapAPI.getNavLeg = function()
        trip.legCalls = trip.legCalls + 1
        if not trip.phase then return nil, "noitinerary" end
        return "leg", trip.stopId, 300, 400, trip.phase, trip.revision
    end
    MinidoracatMiniMapAPI.getNavItinerary = function()
        trip.snapshotCalls = trip.snapshotCalls + 1
        if not trip.phase then return nil, "noitinerary" end
        trip.data.revision = trip.revision
        trip.data.autoContinue = trip.autoContinue
        return trip.data
    end
    -- 契約：setNavContinuation(pn, expectedRevision, enabled) → true, "ok" 或 false, reason[, detail]
    MinidoracatMiniMapAPI.setNavContinuation = function(pn, expected, enabled)
        trip.setCalls = trip.setCalls + 1
        if pn ~= 0 or expected ~= trip.revision then return false, "stale" end
        if not trip.setOk then return false, trip.setReason, "detail" end
        trip.revision = trip.revision + 1
        trip.autoContinue = enabled == true
        return true, "ok"
    end
    MDAD.Drive.continueItinerary = function()
        trip.continueCalls = trip.continueCalls + 1
        return true
    end
    state.active, state.token, state.startReason, state.legReportWhy = false, "follow", nil, nil
    nowMs = nowMs + 6000
    options:getOption("HUDTheme"):setValue(1)
    options:getOption("HUDLayout"):setValue(1)
    options:getOption("HUDScale"):setValue(2)
    options:apply()
    panel:refresh(nowMs)

    -- 只是顯示：讀快照不寫設定、也不碰自駕
    check(panel.contButton.visible and panel.contButton.valueText == "CONT AUTO",
        "a v7 snapshot shows the continuation pill carrying the trip's own value")
    checkEq(trip.setCalls, 0, "reading the trip never writes the continuation setting")
    checkEq(trip.continueCalls, 0, "showing the continuation control never starts autodrive")
    check(panel._tripFull and panel._tripFull:find("GAS STATION", 1, true)
        and panel._tripFull:find("(HOLD)", 1, true) == nil,
        "an ordinary auto-continued target is not marked as a forced wait")

    -- 目前目標本身被標成停等：模式是自動，但旗標優先顯示
    trip.data.currentStopId, trip.stopId = 3, 3
    trip.data.stops[2].status = "arrived"
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    check(panel._tripFull and panel._tripFull:find("CABIN", 1, true)
        and panel._tripFull:find("(HOLD)", 1, true),
        "auto mode still shows that this particular stop waits for you")

    -- waiting：兩個站名不互換，主鈕是明確的「繼續自駕」，狀態字講階段
    trip.phase = "waiting"
    trip.data.currentStopId, trip.stopId = 2, 2
    trip.data.stops[3].status = "pending"
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    local atPos = panel._tripFull and panel._tripFull:find("GAS STATION", 1, true)
    local nextPos = panel._tripFull and panel._tripFull:find("CABIN", 1, true)
    check(atPos and nextPos and atPos < nextPos,
        "waiting reports the stop already reached first, then the one it will head to")
    check(panel._tripFull:find("(HOLD)", 1, true),
        "the forced wait of the next stop is visible while auto mode is on")
    checkEq(panel.actionButton.title, "TRIP CONTINUE",
        "waiting offers an explicit autodrive continuation")
    checkEq(panel._statusText, "STOPPED OVER",
        "waiting states the phase instead of the single-stop 'ready to engage'")

    -- 選單：兩項、目前值不可再選、挑了才寫一次，且帶畫面上那份快照的 revision
    local setsBefore, continuesBefore = trip.setCalls, trip.continueCalls
    click(panel.contButton)
    local menu = ISContextMenu.lastMenu
    check(menu and #menu.options == 2 and menu.player == 0,
        "the pill opens the vanilla context menu for this player with exactly the two modes")
    check(menu.options[1].notAvailable == true and menu.options[2].notAvailable ~= true,
        "the mode already in force cannot be re-picked; the other one can")
    checkEq(trip.setCalls, setsBefore, "opening the menu writes nothing by itself")
    check(menu:pick("MENU STEP"), "the stop-by-stop option is selectable")
    checkEq(trip.continueCalls, continuesBefore,
        "switching the continuation mode never starts autodrive or claims a leg")
    checkEq(state.active, false, "switching the mode never toggles the single-stop session either")
    checkEq(panel.contButton.valueText, "CONT STEP", "the pill immediately shows the stored new value")
    check(panel._tripFull and panel._tripFull:find("(HOLD)", 1, true) == nil,
        "stop-by-stop mode drops the per-stop wait marker: every stop waits anyway")
    checkEq(panel.contButton.tooltip, "CONT TIP",
        "the pill explains itself in a tooltip instead of relying on its colour")

    -- 繪製只讀快取；圖形與字的位置由實際 draw capture 驗收，不綁 draw-call 數量。
    local glyphTexts, glyphMeasures = getTextCalls, measureCalls
    panel.contButton:render()
    check(getTextCalls == glyphTexts and measureCalls == glyphMeasures,
        "painting the pill performs no translation lookup and no text measurement")

    -- expectedRevision 過期：被拒要有一句能行動的原因，值不得假裝改掉。
    -- 契約：API 回傳的 reason 是 enum（stale／…），不是翻譯鍵，HUD 不做鍵探測。
    click(panel.contButton)
    local staleMenu = ISContextMenu.lastMenu
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    check(staleMenu:pick("MENU AUTO"), "the old menu can still receive the delayed click")
    checkEq(panel._statusText, "MODE UNCHANGED",
        "a stale-revision rejection is reported on the HUD instead of failing silently")
    check(panel.actionButton.tooltip
        and panel.actionButton.tooltip:find("CONT FAILED SENTENCE", 1, true),
        "the full rejection sentence reaches the main button tooltip")
    checkEq(panel.contButton.valueText, "CONT STEP",
        "a rejected switch keeps showing the value that is really stored")
    trip.setOk, trip.setReason = false, "nonav"
    click(panel.contButton)
    ISContextMenu.lastMenu:pick("MENU AUTO")
    checkEq(panel._statusText, "MODE UNCHANGED",
        "any other rejection enum is reported the same actionable way, never as a raw token")
    -- 行駛安全狀態不能被通知蓋掉，但切換失敗仍須有完整文字出口。
    for _, token in ipairs({ "follow", "build", "blocked" }) do
        state.active, state.token = true, token
        trip.phase, trip.revision = "navigating", trip.revision + 1
        panel:refresh(nowMs)
        local status, mode = panel._statusText, trip.autoContinue
        click(panel.contButton)
        ISContextMenu.lastMenu:pick(mode and "MENU STEP" or "MENU AUTO")
        check(panel._statusText == status and trip.autoContinue == mode,
            token .. ": rejected mode changes preserve driving status and the saved mode")
        check(panel.contButton.tooltip:find("CONT FAILED SENTENCE", 1, true),
            token .. ": the mode control exposes its full failure while driving")
    end
    state.active, state.token = false, "follow"
    trip.phase, trip.revision = "waiting", trip.revision + 1
    trip.setOk, trip.setReason = true, nil
    nowMs = nowMs + 6000
    panel:refresh(nowMs)

    -- 快照自己帶的 trip.reason（Core enum）：被擋下的接續要壓過階段字，
    -- 但 manual／cancelled 是正常停止，不能講成錯誤。
    trip.data.reason = "unavailable"
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    checkEq(panel._statusText, "CONTINUATION BLOCKED",
        "a gate-blocked continuation outranks the stopover phase wording")
    check(panel.actionButton.tooltip
        and panel.actionButton.tooltip:find("CANNOT CONTINUE SENTENCE", 1, true),
        "the blocked-continuation sentence reaches the main button tooltip")
    checkEq(panel.actionButton.title, "TRIP CONTINUE",
        "a blocked continuation still lets the player retry explicitly")
    trip.data.reason = "manual"
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    checkEq(panel._statusText, "STOPPED OVER",
        "a normal manual stop keeps the phase wording instead of an error")
    trip.data.reason = "noroad"
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    checkEq(panel._statusText, "NO ROUTE",
        "no-route reuses the existing route failure label instead of a new invented one")
    trip.data.reason = nil
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)

    -- 目前站是被略過而不是已停靠：顯示要誠實
    trip.data.stops[2].status = "skipped"
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    check(panel._tripFull and panel._tripFull:find("SKIPPED GAS STATION", 1, true)
        and panel._tripFull:find("CABIN", 1, true),
        "a skipped current stop is reported as skipped, not as a stop that was reached")
    checkEq(panel._statusText, "STOP SKIPPED", "the phase label says skipped too")
    trip.data.stops[2].status = "arrived"
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)

    -- HUD 永遠不因 phase 變化播聲音（完成／停靠的語音只由 Driver 事件發）
    local voiceBefore = #voiceCalls
    for _, phaseName in ipairs({ "navigating", "waiting", "completed", "paused", "approach" }) do
        trip.phase = phaseName
        trip.revision = trip.revision + 1
        panel:refresh(nowMs)
    end
    checkEq(#voiceCalls, voiceBefore,
        "no trip phase transition, completion included, ever plays a voice line from the HUD")
    trip.phase = "waiting"
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)

    -- Driver 的錯誤與車控危險提示永遠壓過行程字
    state.active, state.token = true, "blocked"
    state.legReportWhy = "UI_MinidoracatAutoDrive_TripLost"
    panel:refresh(nowMs)
    checkEq(panel._statusText, "CONTROL RETURNED",
        "a driver failure still outranks every trip phase wording")
    state.legReportWhy = nil
    panel:refresh(nowMs)
    checkEq(panel._statusText, "HOLDING",
        "braking and waiting keeps priority over the trip message")
    state.token = "build"
    panel:refresh(nowMs)
    checkEq(panel.actionButton.title, "CANCEL PREP",
        "the preparation phase reads as a cancel, not as stopping a moving car")
    state.active, state.token = false, "follow"

    -- 沒有待辦站的 waiting：不得假裝可以出發
    trip.data.stops[3].status = "arrived"
    trip.data.currentStopId, trip.stopId = 3, 3
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    check(panel.actionButton.title == "START" and panel._tripFull == "AT CABIN DONE",
        "a waiting stop with nothing left pending falls back to the single-stop action")
    local idleContinues = trip.continueCalls
    click(panel.actionButton)
    checkEq(trip.continueCalls, idleContinues,
        "that fallback never routes through the trip continuation entry")
    state.active = false
    trip.data.stops[3].status = "pending"
    trip.data.currentStopId, trip.stopId = 2, 2
    trip.phase = "waiting"
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)

    -- 降級：v6、缺 setter、舊快照都不得出現一顆假亮的新控制
    MinidoracatMiniMapAPI.navApiVersion = 6
    panel:refresh(nowMs)
    check(panel._hasTrip and not panel.contButton.visible
        and panel.contButton.valueText == nil,
        "v6 keeps the trip HUD but offers no continuation control at all")
    local v6Sets = trip.setCalls
    panel:onContinuation()
    checkEq(trip.setCalls, v6Sets, "the continuation entry is inert without the v7 setter")
    MinidoracatMiniMapAPI.navApiVersion = 7
    local liveSetter = MinidoracatMiniMapAPI.setNavContinuation
    MinidoracatMiniMapAPI.setNavContinuation = nil
    panel:refresh(nowMs)
    check(not panel.contButton.visible,
        "a v7 version field without the setter still shows no continuation control")
    MinidoracatMiniMapAPI.setNavContinuation = liveSetter
    trip.autoContinue = nil
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    check(not panel.contButton.visible,
        "a snapshot that carries no autoContinue value shows no continuation control")
    trip.autoContinue = true
    trip.revision = trip.revision + 1
    panel:refresh(nowMs)
    check(panel.contButton.visible and panel.contButton.valueText == "CONT AUTO",
        "the control returns once the schema really carries the value")

    -- 四主題＋精簡單行：新藥丸永遠在面板內，且不覆蓋任何既有控制
    local function noOverlap(a, b, label)
        check(not (a.visible and b.visible
                and a.x < b.x + b.width and b.x < a.x + a.width
                and a.y < b.y + b.height and b.y < a.y + a.height), label)
    end
    for _, layoutMode in ipairs({ 1, 2 }) do
        options:getOption("HUDLayout"):setValue(layoutMode)
        for theme = 1, 4 do
            options:getOption("HUDTheme"):setValue(theme)
            options:apply()
            panel:refresh(nowMs)
            local label = "layout " .. layoutMode .. " theme " .. theme
            check(panel.contButton.visible, label .. ": continuation pill stays reachable")
            check(panel.contButton.x >= 0
                and panel.contButton.x + panel.contButton.width <= panel.width
                and panel.contButton.y >= 0
                and panel.contButton.y + panel.contButton.height <= panel.height,
                label .. ": continuation pill stays inside the panel")
            check(panel.contButton.valueText ~= nil,
                label .. ": continuation pill always carries its short word, not colour alone")
            noOverlap(panel.contButton, panel.corpseButton, label .. ": clear of the corpse pill")
            noOverlap(panel.contButton, panel.autoButton, label .. ": clear of the auto-reroute pill")
            noOverlap(panel.contButton, panel.actionButton, label .. ": clear of the main button")
            noOverlap(panel.contButton, panel.volumeSlider, label .. ": clear of the volume slider")
            noOverlap(panel.contButton, panel.themeButton, label .. ": clear of the style button")
            noOverlap(panel.contButton, panel.collapseButton, label .. ": clear of the hide button")
            noOverlap(panel.contButton, panel.voiceButton, label .. ": clear of the voice button")
            noOverlap(panel.contButton, panel.gearButtons[4], label .. ": clear of the gear row")
        end
    end
    options:getOption("HUDTheme"):setValue(1)
    options:getOption("HUDLayout"):setValue(1)
    options:apply()
    panel:setCollapsed(true)
    panel:refresh(nowMs)
    check(not panel.contButton.visible, "the collapsed badge drops the continuation pill too")
    panel:setCollapsed(false)
    panel:refresh(nowMs)

    -- 行程消失：控制與值都要收乾淨
    trip.phase = nil
    panel:refresh(nowMs)
    check(not panel.contButton.visible and panel.contButton.valueText == nil
        and panel.actionButton.title == "START",
        "losing the itinerary removes the continuation control and its value")

    MinidoracatMiniMapAPI.navApiVersion = nil
    MinidoracatMiniMapAPI.getNavLeg = nil
    MinidoracatMiniMapAPI.getNavItinerary = nil
    MinidoracatMiniMapAPI.setNavContinuation = nil
    MDAD.Drive.continueItinerary = nil
    options:apply()
    panel:refresh(nowMs)
end

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

-- 真 PZ 字型與原版 ISButton 的離線 draw capture 所對應的幾何回歸：
-- 真字高 1x＝Small 19／Medium 29、4x＝Small 38／Medium 45，量寬以「一個 CJK 佔一格
-- 字高、半形佔半格」估。捕捉到的三類問題都守在這裡：320 寬時樣式／語音／收合／檔位
-- 掉出面板、巡航欄的字壓到主鈕、4x 側掛把檔位列推到負 Y 且底列超出儀表板高度。
-- 圖示模式（方鈕）與離線繪製同條件；本測試量寬仍是下列估算模型。
do
    local realMeasure, realHeight = textManager.MeasureStringX, textManager.getFontHeight
    local themeOption = optionSets.MinidoracatAutoDrive:getOption("HUDTheme")
    MinidoracatMiniMapAPI.navApiVersion = 7
    MinidoracatMiniMapAPI.getNavLeg = function() return nil, nil, nil, nil, "waiting", 1 end
    MinidoracatMiniMapAPI.getNavItinerary = function()
        return { revision = 1, count = 2, currentStopId = 1, autoContinue = true, stops = {
            { id = 1, label = "HOME", status = "arrived", pause = false },
            { id = 2, label = "CABIN", status = "pending", pause = false },
        } }
    end
    MinidoracatMiniMapAPI.setNavContinuation = function() return true, "ok" end
    iconPanel:setWing("left", false)
    iconPanel:setWing("right", false)

    local function useFontProfile(smallH, mediumH)
        textManager.getFontHeight = function(_, font)
            return font == UIFont.Medium and mediumH or smallH
        end
        textManager.MeasureStringX = function(_, font, text)
            local h = font == UIFont.Medium and mediumH or smallH
            local half, width, i = math.floor(h / 2), 0, 1
            while i <= #text do
                local byte = text:byte(i)
                if byte >= 0xF0 then width, i = width + h, i + 4
                elseif byte >= 0xE0 then width, i = width + h, i + 3
                elseif byte >= 0xC0 then width, i = width + h, i + 2
                else width, i = width + half, i + 1 end
            end
            return width
        end
    end
    -- 「可見的子元件有幾個掉出面板」：一格斷言涵蓋全部控制，出事時看數字就知道規模。
    local function outside(p)
        local n = 0
        for i = 1, #p.children do
            local child = p.children[i]
            if child.visible and (child.x < 0 or child.y < 0
                    or child.x + child.width > p.width
                    or child.y + child.height > p.height) then
                n = n + 1
            end
        end
        return n
    end

    for _, profile in ipairs({ { name = "1x", small = 19, medium = 29 },
                               { name = "4x", small = 38, medium = 45 } }) do
        useFontProfile(profile.small, profile.medium)
        for _, width in ipairs({ 320, 640, 1920 }) do
            viewportWidth = width
            for theme = 1, 4 do
                themeOption:setValue(theme)
                iconPanel:applyLayout()
                iconPanel:refresh(nowMs)
                local label = "CH " .. profile.name .. " " .. width .. "px theme " .. theme
                checkEq(outside(iconPanel), 0,
                    label .. ": every visible control stays inside the panel")
                check(iconPanel.actionButton.visible and iconPanel.collapseButton.visible,
                    label .. ": the main action and the fold entry never degrade away")
                if iconPanel._capX then
                    local capRight = math.max(
                        iconPanel._capX
                            + textManager:MeasureStringX(UIFont.Small, iconPanel._capLabel),
                        iconPanel._capValueX
                            + textManager:MeasureStringX(UIFont.Small, iconPanel._capText))
                    check(capRight <= iconPanel.actionButton.x,
                        label .. ": cruise text never reaches the main button")
                else
                    check(iconPanel._capValueX == nil,
                        label .. ": a yielded cruise column leaves no stale coordinate")
                end
                if iconPanel._speedX == nil then
                    check(iconPanel._effectiveLayout == 2 and not iconPanel._showStatusText,
                        label .. ": only the ultra-narrow single row may drop the speed column")
                end
            end
        end
    end

    -- 一般解析度不得無故退化：1x／1920 四個主題都照選的走，仍是完整展開版面。
    useFontProfile(19, 29)
    viewportWidth = 1920
    for theme = 1, 4 do
        themeOption:setValue(theme)
        iconPanel:applyLayout()
        checkEq(iconPanel._style, theme,
            "CH 1x 1920px keeps the chosen theme " .. theme)
        checkEq(iconPanel._effectiveLayout, 1,
            "CH 1x 1920px theme " .. theme .. " stays on the full layout")
    end
    themeOption:setValue(4)
    iconPanel:applyLayout()
    check(iconPanel.height <= dashboards[0].height - 7
        and iconPanel.actionButton.visible and iconPanel.gearButtons[1].visible,
        "CH 1x wings still fit the visible dashboard band with both wings open")

    -- 4x 的側翼三列（44×3＋間距）放不進 103px 的可見儀表板：退回上掛，不得出現
    -- 負 Y 的檔位列，也不得把底列壓進儀表板。
    useFontProfile(38, 45)
    themeOption:setValue(4)
    iconPanel:applyLayout()
    checkEq(iconPanel._style, 1,
        "CH 4x wings hand over to the top-mounted layout when the dashboard band is too short")
    check(iconPanel.gearButtons[1].y >= 0
        and iconPanel.volumeSlider.y + iconPanel.volumeSlider.height <= iconPanel.height
        and iconPanel.y + iconPanel.height == dashboards[0].y + 7,
        "CH 4x wings fallback docks above the dashboard instead of overflowing it")
    click(iconPanel.themeButton)
    checkEq(themeOption:getValue(), 1, "fallback keeps the saved Wings-to-Metal cycle")
    useFontProfile(19, 29)
    iconPanel:applyLayout()
    checkEq(iconPanel._style, 1, "restoring font size keeps the user's saved Metal selection")

    -- 英文完整主鈕比窄版剩餘空間長；原版 ISButton 不會自動裁切標題。
    local oldContinue, oldCancel = texts.UI_MinidoracatAutoDrive_HUDTripContinue,
        texts.UI_MinidoracatAutoDrive_HUDCancelPrep
    local oldEntry = MDAD.Drive.continueItinerary
    local oldActive, oldToken = state.active, state.token
    MDAD.Drive.continueItinerary = function() return true end
    texts.UI_MinidoracatAutoDrive_HUDTripContinue = "Continue autodrive"
    texts.UI_MinidoracatAutoDrive_HUDCancelPrep = "Cancel preparation"
    useFontProfile(38, 45)
    viewportWidth = 320
    for _, mode in ipairs({ "idle", "build" }) do
        state.active, state.token = mode == "build", mode
        iconPanel:applyLayout(); iconPanel:refresh(nowMs)
        local full = mode == "build" and "Cancel preparation" or "Continue autodrive"
        check(textManager:MeasureStringX(UIFont.Small, iconPanel.actionButton.title)
                <= iconPanel.actionButton.width - 12,
            mode .. ": a long action title must fit rather than overflow a valid rectangle")
        check(iconPanel.actionButton.tooltip and iconPanel.actionButton.tooltip:find(full, 1, true),
            mode .. ": shortened action retains its full meaning in the tooltip")
    end
    texts.UI_MinidoracatAutoDrive_HUDTripContinue = oldContinue
    texts.UI_MinidoracatAutoDrive_HUDCancelPrep = oldCancel
    MDAD.Drive.continueItinerary = oldEntry
    state.active, state.token = oldActive, oldToken

    textManager.MeasureStringX, textManager.getFontHeight = realMeasure, realHeight
    viewportWidth = 1920
    themeOption:setValue(1)
    MinidoracatMiniMapAPI.navApiVersion = nil
    MinidoracatMiniMapAPI.getNavLeg = nil
    MinidoracatMiniMapAPI.getNavItinerary = nil
    MinidoracatMiniMapAPI.setNavContinuation = nil
    iconPanel:applyLayout()
    iconPanel:refresh(nowMs)
end
iconPanel:removeFromUIManager()
getTexture = nil
MDAD.HUD = nil
loadHUD()
MDAD.HUD = liveHUD

-- 缺 ModOptions 仍有兩顆策略鈕與 v7 模式控制；不能為隱藏的改道鈕留假空位。
do
    local savedOptions, savedAPI = PZAPI, MinidoracatMiniMapAPI
    PZAPI, MDAD.HUD = nil, nil
    MinidoracatMiniMapAPI = {
        navApiVersion = 7,
        getNavLeg = function() return nil, nil, nil, nil, "waiting", 1 end,
        getNavItinerary = function()
            return { revision = 1, count = 2, currentStopId = 1, autoContinue = true, stops = {
                { id = 1, label = "HOME", status = "arrived", pause = false },
                { id = 2, label = "CABIN", status = "pending", pause = false },
            } }
        end,
        setNavContinuation = function() return true, "ok" end,
    }
    loadHUD()
    local noOptions = MDAD.HUD.Panel:new(0)
    noOptions:initialise(); noOptions:instantiate(); noOptions:refresh(nowMs)
    check(noOptions.contButton.visible and not noOptions.autoButton.visible,
        "without ModOptions the trip mode remains available but auto-detour stays hidden")
    check(noOptions.contButton.x + noOptions.contButton.width <= noOptions._energyX,
        "without ModOptions the trip mode stays clear of the battery and fuel text")
    noOptions:removeFromUIManager()
    PZAPI, MinidoracatMiniMapAPI, MDAD.HUD = savedOptions, savedAPI, liveHUD
end

print("HUD assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
