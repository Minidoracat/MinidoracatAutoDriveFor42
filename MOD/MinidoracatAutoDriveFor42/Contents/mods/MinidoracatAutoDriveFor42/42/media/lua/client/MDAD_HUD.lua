-- MDAD_HUD.lua
-- M5.5b 駕駛 HUD：每位本機玩家各一個面板。三種主題（金屬擬物／簡約玻璃／家族卡片）
-- 由 PZAPI.ModOptions 或 HUD 上的「樣式」鈕切換；收合狀態跟角色存進 player modData。
-- 樣式／隱藏／語音／音量四個控制都在 HUD 本體上（2026-09-02 使用者裁定：舊制掛在
-- 原版儀表板右上的 18px 小鈕太不顯眼）。
--
-- 效能契約：UIElement.update 約 10Hz（UIElement.java:1661-1687），本檔再以
-- getTimestampMs 做 250ms 閘門；車輛 getter、getText、文字量測只在 refresh/layout。
-- prerender 每幀只讀 ESC root 與 dashboard identity/可見性，其餘只畫快取，不配置 table/closure。
--
-- 原版／框架出處：
--   ISPanel/ISButton 建構：ISPanel.lua:96-115、ISButton.lua:479-533
--   add/remove/always-on-top：ISUIElement.lua:1319-1323、1365-1379
--   車輛 HUD 事件與分割畫面定位：ISVehicleDashboard.lua:420-433、601-633
--   UIFor42 Skin.fill/border/dot／slider painter：MinidoracatUI/V1.lua:166-210、285-316（缺席退直角）
--   拉桿拖曳／capture 慣例：ISGameSoundVolumeControl.lua:10-35
--   ModOptions create/combo/tick/slider/apply/save：PZAPI/ModOptions.lua:121-155、206-215、247-289
--   現速／車電／油量：BaseVehicle.java:4268、VehicleParts.java:152-156、
--   BaseVehicle.java:9293-9296；原版用例 ISVehicleDashboard.lua:252、280-283、370-373。

require "MDAD"
require "MDAD_Driver"
require "MDAD_Voice"
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
-- 不註冊事件。根因由發版閘門守（scripts/verify_mod.py 檢查 1b 的 Kahlua 結構上限），
-- 這條只保證失敗安靜且訊息讀得到。
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
local STYLE_METAL = 1
local STYLE_GLASS = 2
local STYLE_FAMILY = 3
local STYLE_WINGS = 4
local STYLE_COUNT = 4
local LAYOUT_FULL = 1
local LAYOUT_COMPACT = 2
local OPTION_ID = "MinidoracatAutoDrive"
local TRAJECTORY_WIDTH_DEFAULT = 2
local RETENTION_DAYS = { 1, 3, 7, 14, 30 }
local COLLAPSED_MD_KEY = "MDADHudCollapsed"
-- 側掛主題的兩片側翼各自收合，各自存一格（只留左翼常駐是合法組合）。
local WING_L_MD_KEY = "MDADHudWingL"
local WING_R_MD_KEY = "MDADHudWingR"
local SCALES = { 0.75, 1.0, 1.25 }
local GEAR_SHORT = { "30", "50", "70", "MAX" }
local VOICE_VOLUME_DEFAULT = 70
local VOICE_VOLUME_STEP = 5
local SLIDER_KNOB = 12
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

local THEME_KEYS = {
    "UI_MinidoracatAutoDrive_HUDThemeMetal",
    "UI_MinidoracatAutoDrive_HUDThemeMinimal",
    "UI_MinidoracatAutoDrive_HUDThemeFamily",
    "UI_MinidoracatAutoDrive_HUDThemeWings",
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
    -- 家族卡片（UIFor42 DARK token：surface 0/0/0/0.8、surfaceTitle 白 10%、
    -- accent 金 #FFD966；設計稿 C 把 surface 調到 rgba(20,20,20,0.92)）
    familySurface = { r = 0.08, g = 0.08, b = 0.08, a = 0.92 },
    familyTitle = { r = 1.0, g = 1.0, b = 1.0, a = 0.08 },
    familyBorder = { r = 0.4, g = 0.4, b = 0.4, a = 1.0 },
    familyAccent = { r = 1.0, g = 0.85, b = 0.4, a = 1.0 },
    familySelected = { r = 0.45, g = 0.36, b = 0.14, a = 0.95 },
    sliderTrack = { r = 0.22, g = 0.22, b = 0.22, a = 1.0 },
    sliderFill = { r = 0.75, g = 0.55, b = 0.20, a = 1.0 },
    sliderKnob = { r = 1.0, g = 1.0, b = 1.0, a = 1.0 },
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

local function voiceEnabled()
    return optionBool("VoiceEnabled", true)
end

-- 自動改道（2026-09-02）：預設關；HUD「改道」鈕不受此影響，永遠可手動按。
local function autoDetour()
    return optionBool("AutoDetour", false)
end

local function setAutoDetour(value)
    return setClientOption("AutoDetour", value == true)
end

-- 語音語言（2026-09-02）：combo index 1＝跟隨遊戲語言，2..＝MDAD.Voice.PACKS 順序的
-- 語音包（zh／en／ja）。包清單只有 Voice 一份；Voice 缺席時下拉只剩「跟隨」。
local VOICE_PACKS = (type(MDAD.Voice) == "table" and type(MDAD.Voice.PACKS) == "table")
    and MDAD.Voice.PACKS or {}
local VOICE_LANG_KEYS = { "UI_MinidoracatAutoDrive_VoiceLangAuto" }
for i = 1, #VOICE_PACKS do
    VOICE_LANG_KEYS[i + 1] = "UI_MinidoracatAutoDrive_VoiceLang_" .. VOICE_PACKS[i]
end

local function voiceLanguageIndex()
    return optionIndex("VoiceLanguage", 1, #VOICE_LANG_KEYS)
end

-- "auto" 或 pack 名；Voice.language() 以此為準。
local function voiceLanguage()
    return VOICE_PACKS[voiceLanguageIndex() - 1] or "auto"
end

local function setVoiceLanguageIndex(value)
    if type(value) ~= "number" or value ~= value then return false end
    value = math.floor(value)
    if value < 1 or value > #VOICE_LANG_KEYS then return false end
    return setClientOption("VoiceLanguage", value)
end

-- 0..100 整數；slider option 缺席／壞值退預設。
local function voiceVolume()
    if not modOptions then return VOICE_VOLUME_DEFAULT end
    local option = modOptions:getOption("VoiceVolume")
    local value = option and option:getValue()
    if type(value) ~= "number" or value ~= value then return VOICE_VOLUME_DEFAULT end
    if value < 0 then value = 0 elseif value > 100 then value = 100 end
    return math.floor(value + 0.5)
end

local function setVoiceEnabled(value)
    return setClientOption("VoiceEnabled", value == true)
end

-- persist=false＝拖曳中：只寫 option 值（語音模組每次播放都重讀），不 apply
-- （apply 會讓每個 panel 重算 layout）也不落盤；放開時才 persist。
local function setVoiceVolume(value, persist)
    if type(value) ~= "number" or value ~= value then return false end
    if value < 0 then value = 0 elseif value > 100 then value = 100 end
    value = math.floor(value + 0.5)
    if persist == false then
        if not modOptions then return false end
        local option = modOptions:getOption("VoiceVolume")
        if not option then return false end
        option:setValue(value)
        return true
    end
    return setClientOption("VoiceVolume", value)
end

-- 語音模組是獨立檔（MDAD_Voice.lua）；缺席／拋錯都不得影響 HUD。
local function playVoice(event, playerNum)
    local voice = MDAD.Voice
    if voice then pcall(voice.play, event, playerNum) end
end

local function copyDiag(playerNum, method)
    local diag = MDADDiagnostics
    if diag and type(diag[method]) == "function" then
        diag[method](playerNum)
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
    -- 圖示鈕：白色 RGBA 字形以 textureColor 染色（ISButton.lua:222-226），開關狀態
    -- 靠同一組文字色（綠＝開、灰＝關、琥珀＝改道），說明留給 hover tooltip。
    if button.textureColor then copyRGBA(button.textureColor, text) end
end

-- 圖示（2026-09-02 使用者裁定：控制鈕改圖示省空間，說明滑過看 tooltip）：
-- 32×32 純白 RGBA，`42/media/ui/MinidoracatAutoDrive/hud_<name>.png`（codex 生成
-- 圖示表切片，見 scripts/slice_hud_icons.py）。缺檔＝`getTexture` 回 null
-- （Texture.java:413-421 例外吞掉、:506 nullTextures 快取）→ 退回文字標題，
-- 版面同步退回文字寬。一次查一次，之後只讀快取。
local ICON_PATH = "media/ui/MinidoracatAutoDrive/hud_"
local ICON_PX = 16
local iconCache = {}
local function icon(name)
    local cached = iconCache[name]
    if cached == nil then
        local ok, tex = pcall(getTexture, ICON_PATH .. name .. ".png")
        cached = ok and tex or false
        iconCache[name] = cached
    end
    return cached or nil
end

-- 整套圖示一起出貨；用調色盤當哨兵決定版面走圖示寬（方鈕）還是文字寬。
local function iconsOn()
    return icon("palette") ~= nil
end

-- 圖示有＝方鈕＋空標題；沒有＝文字標題（原本的 HUD 文案）。
local function setGlyph(button, name, title, scale)
    local tex = name and icon(name) or nil
    if tex then
        button:setImage(tex)
        local px = scaled(ICON_PX, scale or 1)
        button:forceImageSize(px, px)
        button:setTitle("")
    else
        button.image = nil
        button:setTitle(title)
    end
end

-- 減速藥丸：標題／精確策略提示／配色／可否點擊全由
-- 「此刻有沒有在減速」×「政策是否交給玩家」決定；有圖示時標題退成圖示，
-- 開關看染色（綠／灰），鎖定看 tooltip。
local function applyPolicyButton(button, labelKey, glyph, on, playerChoice, tooltip, scale)
    local valueKey
    if playerChoice then
        valueKey = on and "UI_MinidoracatAutoDrive_HUDOn"
            or "UI_MinidoracatAutoDrive_HUDOff"
    else
        valueKey = on and "UI_MinidoracatAutoDrive_HUDForcedOn"
            or "UI_MinidoracatAutoDrive_HUDForcedOff"
    end
    setGlyph(button, glyph, getText(labelKey) .. " " .. getText(valueKey), scale)
    button.tooltip = tooltip
    styleButton(button, on and C.start or C.button, on and C.green or C.muted, playerChoice)
end

local function makeButton(parent, title, callback)
    local button = ISButton:new(0, 0, 10, 10, title, parent, callback)
    button:initialise()
    button.font = UIFont.Small
    styleButton(button, C.button, C.text, true)
    parent:addChild(button)
    return button
end

-- =====================================================================
-- 音量拉桿：0..100、步進 5。拖曳／滾輪改值即時 apply（語音模組每次播放讀
-- option），放開才落盤並播一段短語音當回饋。拖曳 capture 慣例同
-- ISGameSoundVolumeControl.lua:10-35；ISUIElement.getMouseX 是相對座標。
-- =====================================================================
MDADHUDSlider = ISPanel:derive("MDADHUDSlider")

function MDADHUDSlider:new(target)
    local o = ISPanel.new(self, 0, 0, 80, 22)
    o.background = false
    o.moveWithMouse = false
    o.target = target
    o.value = VOICE_VOLUME_DEFAULT
    o.dragging = false
    o.valueW = 0
    return o
end

function MDADHUDSlider:trackWidth()
    local w = self.width - self.valueW - SLIDER_KNOB
    if w < SLIDER_KNOB then w = SLIDER_KNOB end
    return w
end

function MDADHUDSlider:valueAtX(x)
    local trackW = self:trackWidth()
    local ratio = (x - SLIDER_KNOB / 2) / trackW
    if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
    local steps = math.floor(ratio * 100 / VOICE_VOLUME_STEP + 0.5)
    return steps * VOICE_VOLUME_STEP
end

function MDADHUDSlider:setValue(value, committed)
    if type(value) ~= "number" or value ~= value then return end
    if value < 0 then value = 0 elseif value > 100 then value = 100 end
    value = math.floor(value + 0.5)
    local changed = value ~= self.value
    self.value = value
    if (changed or committed) and self.target then
        self.target:onVolume(value, committed == true)
    end
end

function MDADHUDSlider:onMouseDown(x, y)
    self:setValue(self:valueAtX(self:getMouseX()), false)
    self.dragging = true
    self:setCapture(true)
    return true
end

function MDADHUDSlider:onMouseMove(dx, dy)
    if self.dragging then self:setValue(self:valueAtX(self:getMouseX()), false) end
end

function MDADHUDSlider:onMouseMoveOutside(dx, dy)
    if self.dragging then self:setValue(self:valueAtX(self:getMouseX()), false) end
end

function MDADHUDSlider:onMouseUp(x, y)
    if not self.dragging then return end
    self.dragging = false
    self:setCapture(false)
    self:setValue(self.value, true)
    return true
end

function MDADHUDSlider:onMouseUpOutside(x, y)
    self:onMouseUp(x, y)
end

function MDADHUDSlider:onMouseWheel(del)
    local step = del > 0 and -VOICE_VOLUME_STEP or VOICE_VOLUME_STEP
    self:setValue(self.value + step, true)
    return true
end

function MDADHUDSlider:prerender()
    local trackW = self:trackWidth()
    local ratio = self.value / 100
    local x = math.floor(SLIDER_KNOB / 2)
    local h = self.height
    if not (FW and type(FW.slider) == "function"
            and FW.slider(self, x, 0, trackW, h, ratio, C.sliderColors)) then
        local trackY = math.floor((h - 4) / 2)
        self:drawRect(x, trackY, trackW, 4,
            C.sliderTrack.a, C.sliderTrack.r, C.sliderTrack.g, C.sliderTrack.b)
        local fillW = math.floor(trackW * ratio + 0.5)
        if fillW > 0 then
            self:drawRect(x, trackY, fillW, 4,
                C.sliderFill.a, C.sliderFill.r, C.sliderFill.g, C.sliderFill.b)
        end
        dot(self, x + fillW - math.floor(SLIDER_KNOB / 2),
            math.floor((h - SLIDER_KNOB) / 2), SLIDER_KNOB, C.sliderKnob)
    end
    self:drawText(self.valueText or "", x + trackW + math.floor(SLIDER_KNOB / 2) + 2,
        self.valueTextY or 0, C.muted.r, C.muted.g, C.muted.b, C.muted.a, UIFont.Small)
end

C.sliderColors = { track = C.sliderTrack, fill = C.sliderFill, knob = C.sliderKnob, border = C.border }

-- =====================================================================
-- 面板
-- =====================================================================
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
    o._headerH = 0
    o._blockX = nil
    o._dividerY = nil
    o._statusColor = C.blue
    o._zombieOn = true
    o._corpseOn = true
    o._zombiePolicy = MDAD.POLICY_PLAYER
    o._corpsePolicy = MDAD.POLICY_PLAYER
    o._reason = nil
    o._voiceOn = true
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
    -- 自動改道藥丸（2026-09-02 使用者：ESC 選項也要出現在 HUD 上）：與減速藥丸同列同款，
    -- 讀寫同一個 ModOptions 選項（ESC／MiniMap 設定三處同源）；無 ModOptions＝不顯示。
    self.autoButton = makeButton(self, "", MDADHUDPanel.onAutoDetour)
    self.actionButton = makeButton(self, getText("UI_MinidoracatAutoDrive_Start"), MDADHUDPanel.onAction)
    self.themeButton = makeButton(self, getText("UI_MinidoracatAutoDrive_HUDStyleButton"), MDADHUDPanel.onTheme)
    self.collapseButton = makeButton(self, getText("UI_MinidoracatAutoDrive_HUDHideButton"), MDADHUDPanel.onCollapse)
    -- 側掛主題的左翼 chevron；其餘主題只有一顆（collapseButton＝右翼／整面板）。
    self.wingButton = makeButton(self, getText("UI_MinidoracatAutoDrive_HUDHideButton"), MDADHUDPanel.onWing)
    self.wingButton:setVisible(false)
    self.voiceButton = makeButton(self, "", MDADHUDPanel.onVoice)
    -- 改道鈕：只在「煞停等待」出現，接在狀態字後（statusW 已為最長狀態字保留寬度）。
    self.detourButton = makeButton(self, getText("UI_MinidoracatAutoDrive_HUDDetourButton"), MDADHUDPanel.onDetour)
    self.detourButton:setVisible(false)
    self.volumeSlider = MDADHUDSlider:new(self)
    self.volumeSlider:initialise()
    self:addChild(self.volumeSlider)
    self:applyLayout()
end

function MDADHUDPanel:loadCollapsed(playerObj)
    if self._collapseLoaded then return end
    local md = playerObj and playerObj:getModData()
    self._collapsed = md and md[COLLAPSED_MD_KEY] == true or false
    self._wingL = md and md[WING_L_MD_KEY] == true or false
    self._wingR = md and md[WING_R_MD_KEY] == true or false
    self._collapseLoaded = true
    self:applyLayout()
end

-- 側掛：side 為 "left"／"right"，各自一格 modData。
function MDADHUDPanel:setWing(side, value)
    local folded = value == true
    if side == "left" then self._wingL = folded else self._wingR = folded end
    self._collapseLoaded = true
    local playerObj = getSpecificPlayer(self.playerNum)
    local md = playerObj and playerObj:getModData()
    if md then md[side == "left" and WING_L_MD_KEY or WING_R_MD_KEY] = folded end
    self:applyLayout()
    self._forceRefresh = true
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

function MDADHUDPanel:setControlsVisible(gearsOn, cycleOn, policiesOn, actionOn, sliderOn)
    for i = 1, 4 do self.gearButtons[i]:setVisible(gearsOn) end
    self.cycleButton:setVisible(cycleOn)
    self.zombieButton:setVisible(policiesOn)
    self.corpseButton:setVisible(policiesOn)
    self.autoButton:setVisible(policiesOn and modOptions ~= nil)
    self.actionButton:setVisible(actionOn)
    -- 樣式／語音只在展開態；隱藏鈕永遠在（收合徽章上它就是「展開」）。
    self.themeButton:setVisible(not self._collapsed and modOptions ~= nil)
    self.voiceButton:setVisible(not self._collapsed and modOptions ~= nil)
    self.collapseButton:setVisible(true)
    self.wingButton:setVisible(false) -- 左翼 chevron 只屬側掛主題
    self.volumeSlider:setVisible(sliderOn and modOptions ~= nil)
    self._detourAllowed = not self._collapsed and self._showStatusText
    self.detourButton:setVisible(self._detourAllowed and self._blocked == true)
end

-- 兩套版面（上掛三主題 applyLayout／側掛 layoutWings）共用的量測：字高、間距、
-- 控制鈕高、各鈕最小寬、狀態字最長寬。只在 layout 跑（冷路徑），回一張表；
-- 各版面自己再加邊距／地板。圖示可用時控制鈕與策略藥丸都收成方鈕（寬＝高）。
local function measure(self, scale)
    local tm = getTextManager()
    local m = {}
    m.fontH = tm:getFontHeight(UIFont.Small)
    m.mediumH = tm:getFontHeight(UIFont.Medium)
    m.pad = maximum(6, scaled(8, scale))
    m.gap = maximum(3, scaled(4, scale))
    m.ctrlH = maximum(m.fontH + 6, scaled(22, scale))
    local statusW = 0
    for i = 1, #STATUS_WIDTH_KEYS do
        statusW = maximum(statusW, textWidth(UIFont.Small, getText(STATUS_WIDTH_KEYS[i])))
    end
    m.statusTextW = statusW
    m.blockedW = textWidth(UIFont.Small, getText("UI_MinidoracatAutoDrive_HUDStatusBlocked"))
    m.detourW = maximum(scaled(40, scale),
        textWidth(UIFont.Small, getText("UI_MinidoracatAutoDrive_HUDDetourButton")) + 12)
    m.speedValueW = textWidth(UIFont.Medium, "120")
    m.unitW = textWidth(UIFont.Small, self._unitText)
    m.capLabelW = textWidth(UIFont.Small, self._capLabel)
    m.capValueW = textWidth(UIFont.Small, "120")
    m.actionW = maximum(scaled(58, scale), maximum(
        textWidth(UIFont.Small, getText("UI_MinidoracatAutoDrive_Start")),
        textWidth(UIFont.Small, getText("UI_MinidoracatAutoDrive_Stop"))) + 16)
    m.gearW = maximum(scaled(34, scale), textWidth(UIFont.Small, "MAX") + 12)
    m.gearLabelW = textWidth(UIFont.Small, self._gearLabel) + m.gap
    local forcedText = getText("UI_MinidoracatAutoDrive_HUDForcedOff")
    m.policyW = maximum(scaled(70, scale), maximum(
        textWidth(UIFont.Small, getText("UI_MinidoracatAutoDrive_HUDZombie") .. " " .. forcedText),
        maximum(textWidth(UIFont.Small, getText("UI_MinidoracatAutoDrive_HUDCorpse") .. " " .. forcedText),
            textWidth(UIFont.Small, getText("UI_MinidoracatAutoDrive_HUDAuto") .. " " .. forcedText))) + 14)
    m.energyW = textWidth(UIFont.Small, getText("UI_MinidoracatAutoDrive_HUDEnergy", 100, 100))
    -- 控制鈕寬：三顆同寬、取最長標題（樣式／隱藏／展開／語音 開／語音 關）
    local voiceLabel = getText("UI_MinidoracatAutoDrive_HUDVoice")
    m.ctrlW = maximum(scaled(44, scale), maximum(
        maximum(textWidth(UIFont.Small, getText("UI_MinidoracatAutoDrive_HUDStyleButton")),
            maximum(textWidth(UIFont.Small, getText("UI_MinidoracatAutoDrive_HUDHideButton")),
                textWidth(UIFont.Small, getText("UI_MinidoracatAutoDrive_HUDShowButton")))),
        maximum(textWidth(UIFont.Small, voiceLabel .. " " .. getText("UI_MinidoracatAutoDrive_HUDOn")),
            textWidth(UIFont.Small, voiceLabel .. " " .. getText("UI_MinidoracatAutoDrive_HUDOff")))) + 12)
    if iconsOn() then m.ctrlW, m.policyW = m.ctrlH, m.ctrlH end
    m.valueW = textWidth(UIFont.Small, "100") + 4
    m.sliderW = maximum(scaled(84, scale), SLIDER_KNOB * 3 + m.valueW)
    m.controlsOn = modOptions ~= nil
    m.policyN = m.controlsOn and 3 or 2 -- 殭屍／屍體＋自動改道（無 ModOptions 時不顯示）
    local screenW = getPlayerScreenWidth(self.playerNum)
    m.maxW = type(screenW) == "number" and screenW - 16 or 1904
    return m
end

-- 側掛（2026-09-02 使用者裁定，設計稿 docs/design/hud-mockup-D1-wings-metal.png）：
-- 兩片與可見儀表板同高同材質的側翼貼在儀表板左右緣，儀表板上方的路面完全不遮。
-- 左右各有自己的 chevron、各自存 modData——「只留左翼常駐」是合法組合。
-- 面板是一整片橫跨儀表板的透明元件（中段不畫任何東西）：ISPanel 不吃滑鼠
-- （moveWithMouse=false → onMouseDown 回 isWantMouseEvents()＝false），未命中子元件
-- 的點擊回 FALSE（UIElement.java:1123、1132），UIManager 繼續往下派送
-- （UIManager.java:672-683 只在 consumed 才停），所以原版儀表板的 btn_partSpeed 照樣可點。
function MDADHUDPanel:layoutWings(scale)
    local m = measure(self, scale)
    local fontH, mediumH, pad, gap, ctrlH = m.fontH, m.mediumH, m.pad, m.gap, m.ctrlH
    local statusW = maximum(m.statusTextW, m.blockedW + gap + m.detourW)
    local detourW, speedValueW = m.detourW, m.speedValueW
    local speedW = speedValueW + 3 + m.unitW
    local capLabelW = m.capLabelW
    local capW = capLabelW + gap + m.capValueW
    local actionW, gearW, gearLabelW, policyW, energyW = m.actionW, m.gearW, m.gearLabelW, m.policyW, m.energyW
    local ctrlW, valueW, sliderW, controlsOn, policyN = m.ctrlW, m.valueW, m.sliderW, m.controlsOn, m.policyN

    local dashW, dashH, dashX = self:dashboardGeometry()
    local wingH = maximum(scaled(56, scale), dashH - DASH_VISIBLE_TOP_INSET)
    local maxW = m.maxW

    -- 展開／收合各自的寬度；空間不夠時先摺右翼再摺左翼（版面層強制，不動玩家的 modData）
    local leftOpenW = pad * 2 + maximum(16 + statusW + gap + speedW,
        capW + gap * 2 + ctrlW + gap + actionW)
    local rightOpenW = pad * 2 + maximum(
        gearLabelW + gearW * 4 + gap * 3,
        maximum(policyW * policyN + gap * policyN + energyW,
            (controlsOn and (ctrlW * 3 + gap * 3 + sliderW) or ctrlW)))
    local leftFoldW = pad * 2 + 16 + speedValueW + gap + ctrlW
    local rightFoldW = pad * 2 + textWidth(UIFont.Small, "MAX") + gap + ctrlW
    local foldL, foldR = self._wingL == true, self._wingR == true
    local function totalW()
        return (foldL and leftFoldW or leftOpenW) + dashW + (foldR and rightFoldW or rightOpenW)
    end
    if totalW() > maxW then foldR = true end
    if totalW() > maxW then foldL = true end
    self._wingLFolded, self._wingRFolded = foldL, foldR
    local leftW = foldL and leftFoldW or leftOpenW
    local rightW = foldR and rightFoldW or rightOpenW
    local rightX = leftW + dashW
    self._wingLeftW, self._wingRightW, self._wingRightX = leftW, rightW, rightX
    self._wingDashX, self._wingDashW = dashX, dashW

    self._effectiveLayout = LAYOUT_FULL
    self._showStatusText = not foldL
    self._headerH = 0
    self._blockX = nil
    self._dividerY = nil
    for i = 1, 4 do self.gearButtons[i]:setVisible(not foldR) end
    self.cycleButton:setVisible(false)
    self.zombieButton:setVisible(not foldR)
    self.corpseButton:setVisible(not foldR)
    self.autoButton:setVisible(not foldR and controlsOn)
    self.actionButton:setVisible(not foldL)
    self.themeButton:setVisible(not foldR and controlsOn)
    self.voiceButton:setVisible(not foldR and controlsOn)
    self.volumeSlider:setVisible(not foldR and controlsOn)
    self.collapseButton:setVisible(true)
    self.wingButton:setVisible(true)
    self._detourAllowed = not foldL
    self.detourButton:setVisible(self._detourAllowed and self._blocked == true)

    -- 左翼：上列狀態＋現速，下列巡航＋主鈕（收合＝狀態燈＋現速＋chevron）
    if foldL then
        self._dotX, self._dotY = pad, math.floor((wingH - 8) / 2)
        self._speedX = pad + 16
        self._speedY = math.floor((wingH - mediumH) / 2)
        self._statusX, self._textY = pad + 16, math.floor((wingH - fontH) / 2)
        self._capX, self._capValueX = nil, nil
        setButtonRect(self.wingButton, leftW - pad - ctrlW,
            math.floor((wingH - ctrlH) / 2), ctrlW, ctrlH)
    else
        local rowH = math.floor((wingH - pad * 2 - gap) / 2)
        if rowH < ctrlH then rowH = ctrlH end
        local topY = math.floor((wingH - rowH * 2 - gap) / 2)
        local bottomY = topY + rowH + gap
        self._dotX, self._dotY = pad, topY + math.floor((rowH - 8) / 2)
        self._statusX = pad + 16
        self._textY = topY + math.floor((rowH - fontH) / 2)
        self._speedX = leftW - pad - speedW
        self._speedY = topY + math.floor((rowH - mediumH) / 2)
        self._capX = pad
        self._capLabelY = bottomY + math.floor((rowH - fontH) / 2)
        self._capValueX = pad + capLabelW + gap
        self._capValueY = self._capLabelY
        self._detourY = topY + math.floor((rowH - ctrlH) / 2)
        setButtonRect(self.actionButton, leftW - pad - actionW, bottomY, actionW, rowH)
        -- 左翼 chevron：下列巡航值與主鈕之間（改道鈕在上列狀態字後，兩者不撞）
        setButtonRect(self.wingButton, leftW - pad - actionW - gap - ctrlW,
            bottomY + math.floor((rowH - ctrlH) / 2), ctrlW, ctrlH)
        self._wingLDividerY = topY + rowH + math.floor(gap / 2)
    end

    -- 右翼：三列（檔位／策略＋電油／樣式・隱藏・語音＋音量），收合＝檔位字＋chevron
    if foldR then
        self._gearBadgeX = rightX + pad
        self._gearBadgeY = math.floor((wingH - fontH) / 2)
        setButtonRect(self.collapseButton, rightX + rightW - pad - ctrlW,
            math.floor((wingH - ctrlH) / 2), ctrlW, ctrlH)
        self._labelX, self._energyX, self._wingRDividerY = nil, nil, nil
    else
        local rows = controlsOn and 3 or 2
        local rowH = ctrlH
        local blockH = rowH * rows + gap * (rows - 1)
        local rowY = math.floor((wingH - blockH) / 2)
        local x = rightX + pad + gearLabelW
        for i = 1, 4 do
            setButtonRect(self.gearButtons[i], x, rowY, gearW, rowH)
            x = x + gearW + gap
        end
        self._labelX = rightX + pad
        self._bottomTextY = rowY + math.floor((rowH - fontH) / 2)
        local row2 = rowY + rowH + gap
        setButtonRect(self.zombieButton, rightX + pad, row2, policyW, rowH)
        setButtonRect(self.corpseButton, rightX + pad + policyW + gap, row2, policyW, rowH)
        setButtonRect(self.autoButton, rightX + pad + (policyW + gap) * 2, row2, policyW, rowH)
        self._energyX = rightX + rightW - pad - energyW
        self._energyY = row2 + math.floor((rowH - fontH) / 2)
        local row3 = row2 + rowH + gap
        if controlsOn then
            setButtonRect(self.themeButton, rightX + pad, row3, ctrlW, ctrlH)
            setButtonRect(self.voiceButton, rightX + pad + ctrlW + gap, row3, ctrlW, ctrlH)
            setButtonRect(self.collapseButton, rightX + pad + (ctrlW + gap) * 2, row3, ctrlW, ctrlH)
            setButtonRect(self.volumeSlider, rightX + rightW - pad - sliderW, row3, sliderW, ctrlH)
        else
            setButtonRect(self.collapseButton, rightX + rightW - pad - ctrlW, row3, ctrlW, ctrlH)
        end
        self._wingRDividerY = row2 - math.floor(gap / 2) - 1
    end

    self._detourW, self._detourH, self._detourGap = detourW, ctrlH, gap
    self.volumeSlider.valueW = valueW
    self.volumeSlider.valueTextY = math.floor((ctrlH - fontH) / 2)
    -- 左翼摺起＝往左展開（‹）、展開中＝往右收（›）；右翼相反。文字退路沿用隱藏／展開。
    setGlyph(self.wingButton, foldL and "chevron_left" or "chevron_right", getText(foldL
        and "UI_MinidoracatAutoDrive_HUDShowButton"
        or "UI_MinidoracatAutoDrive_HUDHideButton"), scale)
    setGlyph(self.collapseButton, foldR and "chevron_right" or "chevron_left", getText(foldR
        and "UI_MinidoracatAutoDrive_HUDShowButton"
        or "UI_MinidoracatAutoDrive_HUDHideButton"), scale)
    self._unitX = self._speedX + textWidth(UIFont.Medium, self._speedText) + 3
    self:setWidth(leftW + dashW + rightW)
    self:setHeight(wingH)
    self:reposition()
end

-- 儀表板幾何（寬／高／螢幕 x／螢幕 y）；缺席時退 552×120、x／y nil（呼叫端自算置中）。
function MDADHUDPanel:dashboardGeometry()
    local dashboard = getPlayerVehicleDashboard(self.playerNum)
    local w, h, x, y = 552, 120, nil, nil
    if dashboard then
        if dashboard.backgroundTex then
            w = dashboard.backgroundTex:getWidth() or w
            h = dashboard.backgroundTex:getHeight() or h
        elseif dashboard.getHeight then h = dashboard:getHeight() or h end
        if dashboard.getWidth then w = dashboard:getWidth() or w end
        if dashboard.getX then x = dashboard:getX() end
        if dashboard.getY then y = dashboard:getY() end
    end
    return w, h, x, y
end

-- 三種主題只差「四個控制放哪」與底色：
--   金屬＝右側 2×2 方塊（樣式／隱藏 ↑，語音／音量 ↓）＋直分隔線；
--   玻璃＝第 1 列巡航後一排三顆，音量拉桿在第 2 列右端；
--   家族＝頂部標題條（狀態＋現速 ｜ 三顆＋拉桿），本體兩列（巡航＋主鈕／檔位列）。
-- 精簡單行與收合徽章三主題共用；精簡單行不放拉桿（音量走 ESC 選項）。
function MDADHUDPanel:applyLayout()
    self._style = optionIndex("HUDTheme", STYLE_METAL, STYLE_COUNT)
    self._layout = optionIndex("HUDLayout", LAYOUT_FULL, 2)
    local scale = optionScale()
    self._unitText = getText("UI_MinidoracatAutoDrive_HUDSpeedUnit")
    self._capLabel = getText("UI_MinidoracatAutoDrive_HUDCruiseCap")
    self._gearLabel = getText("UI_MinidoracatAutoDrive_HUDGear")
    -- 側掛的量測與擺位自成一套（無精簡單行／收合徽章分支），共用上面三個標籤字串。
    if self._style == STYLE_WINGS then return self:layoutWings(scale) end
    local m = measure(self, scale)
    local fontH, mediumH, pad, gap, buttonH = m.fontH, m.mediumH, m.pad, m.gap, m.ctrlH
    local topH = maximum(mediumH + 4, maximum(buttonH, fontH * 2 + 2))
    -- 狀態欄要容得下「煞停等待 ＋ 改道鈕」（英文 Holding + Reroute 比中文寬）
    local detourW = m.detourW
    local statusW = maximum(maximum(scaled(126, scale), m.statusTextW + pad * 3),
        16 + m.blockedW + gap + detourW + gap + pad)
    local speedValueW = m.speedValueW
    local speedW = maximum(scaled(62, scale), speedValueW + 3 + m.unitW + gap)
    local capLabelW = m.capLabelW
    local capW = maximum(scaled(48, scale), capLabelW + gap + m.capValueW + gap)
    local actionW, gearW, gearLabelW, policyW = m.actionW, m.gearW, m.gearLabelW, m.policyW
    local energyW = m.energyW + gap
    local cycleW = maximum(scaled(44, scale), textWidth(UIFont.Small, "MAX") + 14)
    local ctrlW, valueW, sliderW, controlsOn, policyN = m.ctrlW, m.valueW, m.sliderW, m.controlsOn, m.policyN
    local trioW = controlsOn and (ctrlW * 3 + gap * 2) or (ctrlW + gap)
    local maxW = m.maxW
    if maxW < 64 then maxW = 64 end
    local fullBase = scaled(510, scale)
    local compactBase = scaled(482, scale)
    if fullBase > maxW then fullBase = maxW end
    if compactBase > maxW then compactBase = maxW end

    local style = self._style
    local blockW = 0
    if style == STYLE_METAL then
        -- 2×2 方塊：左欄樣式／語音（控制鈕寬），右欄隱藏／音量拉桿（拉桿寬）——
        -- 圖示模式下左欄收成方鈕，方塊寬從 2×拉桿寬降到 方鈕＋拉桿
        blockW = ctrlW + gap + maximum(ctrlW, sliderW)
    end
    local bottomContentW = pad * 2 + gearLabelW + gearW * 4 + gap * (4 + policyN)
        + policyW * policyN + energyW
    local topContentW = pad * 2 + statusW + speedW + capW + gap + actionW
    if style == STYLE_GLASS then
        topContentW = topContentW + trioW + gap
        bottomContentW = bottomContentW + sliderW + gap
    elseif style == STYLE_METAL then
        topContentW = topContentW + blockW + gap * 2
        bottomContentW = bottomContentW + blockW + gap * 2
    else
        -- 家族：標題條＝狀態＋現速＋控制三顆＋拉桿；本體第 1 列只有巡航＋主鈕
        topContentW = pad * 2 + statusW + speedW + gap + trioW + gap + sliderW
    end
    local fullContentW = maximum(topContentW, bottomContentW)
    local fullW = maximum(fullBase, fullContentW)
    local compactPolicyContentW = pad * 2 + statusW + speedW + capW + cycleW
        + (policyW + gap) * policyN + trioW + actionW + gap * 2
    local compactEssentialContentW = pad * 2 + statusW + speedW + capW + cycleW
        + trioW + actionW + gap * 2

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
            + trioW + actionW + gap * 2
        compactW = maximum(compactBase, compactEssentialContentW)
    end
    if compactW > maxW then compactW = maxW end
    self._effectiveLayout = effectiveLayout
    self._showStatusText = showStatusText
    self._headerH = 0
    self._blockX = nil
    self._dividerY = nil

    local panelW
    local panelH
    local ctrlH = buttonH
    if self._collapsed then
        panelW = maximum(scaled(68, scale), pad + 16 + speedValueW + gap + ctrlW + pad)
        if panelW > maxW then panelW = maxW end
        panelH = maximum(scaled(34, scale), maximum(fontH, ctrlH) + pad * 2)
        self:setControlsVisible(false, false, false, false, false)
        self._dotX = pad
        self._dotY = math.floor((panelH - 8) / 2)
        self._speedX = pad + 16
        self._speedY = math.floor((panelH - mediumH) / 2)
        setButtonRect(self.collapseButton, panelW - pad - ctrlW,
            math.floor((panelH - ctrlH) / 2), ctrlW, ctrlH)
    elseif effectiveLayout == LAYOUT_COMPACT then
        panelW = compactW
        panelH = maximum(scaled(44, scale), buttonH + pad * 2)
        self:setControlsVisible(false, true, showPolicies, true, false)
        local y = math.floor((panelH - buttonH) / 2)
        local x = pad + statusW + speedW + capW
        setButtonRect(self.cycleButton, x, y, cycleW, buttonH)
        x = x + cycleW + gap
        if showPolicies then
            setButtonRect(self.zombieButton, x, y, policyW, buttonH)
            x = x + policyW + gap
            setButtonRect(self.corpseButton, x, y, policyW, buttonH)
            x = x + policyW + gap
            if controlsOn then
                setButtonRect(self.autoButton, x, y, policyW, buttonH)
                x = x + policyW + gap
            end
        end
        self:placeControlTrio(x, y, ctrlW, ctrlH, gap, controlsOn)
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
        self._detourY = math.floor((panelH - ctrlH) / 2)
    else
        panelW = fullW
        local headerH = 0
        if style == STYLE_FAMILY then headerH = ctrlH + gap * 2 end
        panelH = maximum(scaled(78, scale) + headerH,
            pad * 2 + headerH + topH + buttonH + gap * 2 + 1)
        self:setControlsVisible(true, false, true, true, true)
        local topY = pad + headerH
        local bottomY = panelH - pad - buttonH
        local rightEdge = panelW - pad
        self._headerH = headerH
        if style == STYLE_METAL then
            local cell = maximum(ctrlW, sliderW)
            local blockX = panelW - pad - blockW
            self._blockX = blockX - gap
            rightEdge = blockX - gap * 2
            local rowTop = topY + math.floor((topH - ctrlH) / 2)
            local col2 = blockX + ctrlW + gap
            setButtonRect(self.themeButton, blockX, rowTop, ctrlW, ctrlH)
            setButtonRect(self.collapseButton, col2, rowTop, ctrlW, ctrlH)
            setButtonRect(self.voiceButton, blockX, bottomY, ctrlW, ctrlH)
            setButtonRect(self.volumeSlider, col2, bottomY, cell, ctrlH)
        elseif style == STYLE_GLASS then
            local trioX = pad + statusW + speedW + capW + gap
            self:placeControlTrio(trioX, topY + math.floor((topH - ctrlH) / 2),
                ctrlW, ctrlH, gap, controlsOn)
            setButtonRect(self.volumeSlider, panelW - pad - sliderW, bottomY, sliderW, ctrlH)
        else
            local headerY = math.floor((headerH - ctrlH) / 2)
            setButtonRect(self.volumeSlider, panelW - pad - sliderW, headerY, sliderW, ctrlH)
            self:placeControlTrio(panelW - pad - sliderW - gap - trioW, headerY,
                ctrlW, ctrlH, gap, controlsOn)
        end
        setButtonRect(self.actionButton, rightEdge - actionW, topY, actionW, topH)
        local x = pad + gearLabelW
        for i = 1, 4 do
            setButtonRect(self.gearButtons[i], x, bottomY, gearW, buttonH)
            x = x + gearW + gap
        end
        setButtonRect(self.zombieButton, x, bottomY, policyW, buttonH)
        x = x + policyW + gap
        setButtonRect(self.corpseButton, x, bottomY, policyW, buttonH)
        x = x + policyW + gap
        setButtonRect(self.autoButton, x, bottomY, policyW, buttonH)
        if style == STYLE_FAMILY then
            local headerTextY = math.floor((headerH - fontH) / 2)
            self._dotX = pad
            self._dotY = math.floor((headerH - 8) / 2)
            self._statusX = pad + 16
            self._textY = headerTextY
            self._speedX = pad + statusW
            self._speedY = math.floor((headerH - mediumH) / 2)
            self._capX = pad
            self._capLabelY = topY + math.floor((topH - fontH) / 2)
            self._capValueX = pad + capLabelW + gap
            self._capValueY = self._capLabelY
            self._detourY = math.floor((headerH - ctrlH) / 2)
        else
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
            self._detourY = topY + math.floor((topH - ctrlH) / 2)
        end
        self._labelX = pad
        self._bottomTextY = bottomY + math.floor((buttonH - fontH) / 2)
        local energyRight = rightEdge
        if style == STYLE_GLASS then energyRight = panelW - pad - sliderW - gap end
        self._energyX = energyRight - energyW
        self._dividerY = bottomY - gap - 1
    end

    -- 改道鈕幾何：x 隨狀態字寬在 refresh 決定；寬高與控制鈕同檔。
    self._detourW = detourW
    self._detourH = ctrlH
    self._detourGap = gap
    self.volumeSlider.valueW = valueW
    self.volumeSlider.valueTextY = math.floor((ctrlH - fontH) / 2)
    -- 上掛主題：收合＝往下（˅）、徽章展開＝往上（˄）
    setGlyph(self.collapseButton, self._collapsed and "chevron_up" or "chevron_down",
        getText(self._collapsed
            and "UI_MinidoracatAutoDrive_HUDShowButton"
            or "UI_MinidoracatAutoDrive_HUDHideButton"), scale)
    -- option/resolution apply 會先於下一次 250ms refresh；同步重算單位 x，
    -- 避免切 layout 後一幀仍沿用舊 speedX。
    self._unitX = self._speedX + textWidth(UIFont.Medium, self._speedText) + 3
    self:setWidth(panelW)
    self:setHeight(panelH)
    self:reposition()
end

-- 改道鈕接在狀態字後面；塞不進速度欄前就不顯示（極窄分割畫面）。
function MDADHUDPanel:placeDetourButton()
    local show = self._detourAllowed == true and self._blocked == true
    if show then
        local x = self._statusX + textWidth(UIFont.Small, self._statusText) + self._detourGap
        if x + self._detourW + self._detourGap > self._speedX then show = false end
        if show then
            setButtonRect(self.detourButton, x, self._detourY, self._detourW, self._detourH)
        end
    end
    self.detourButton:setVisible(show)
end

-- 一排三顆（樣式／隱藏／語音）；PZAPI 缺席時只剩隱藏鈕（樣式與語音都靠 option）。
function MDADHUDPanel:placeControlTrio(x, y, w, h, gap, controlsOn)
    if controlsOn then
        setButtonRect(self.themeButton, x, y, w, h)
        x = x + w + gap
    end
    setButtonRect(self.collapseButton, x, y, w, h)
    x = x + w + gap
    if controlsOn then setButtonRect(self.voiceButton, x, y, w, h) end
end

function MDADHUDPanel:setHudVisible(visible)
    self:setVisible(visible)
end

-- ESC 開啟時的唯一收斂動作；update 與 prerender 兩條 tick 路徑共用，
-- 回傳 true 代表本幀已隱藏、呼叫端直接 return。
function MDADHUDPanel:hideIfEscapeMenu()
    if not escapeMenuVisible() then return false end
    self:setHudVisible(false)
    self._forceRefresh = true
    return true
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
    if self._dashboard ~= dashboard then
        self._dashboard = dashboard
        self:applyLayout()
        self._forceRefresh = true
    end
    return true
end

function MDADHUDPanel:dashboardAttachedAndVisible()
    local dashboard = getPlayerVehicleDashboard(self.playerNum)
    return dashboardVisible(dashboard) and self._dashboard == dashboard
end

function MDADHUDPanel:reposition()
    local playerNum = self.playerNum
    local left = getPlayerScreenLeft(playerNum)
    local top = getPlayerScreenTop(playerNum)
    local width = getPlayerScreenWidth(playerNum)
    local height = getPlayerScreenHeight(playerNum)
    self._dashboard = getPlayerVehicleDashboard(playerNum)
    local _, dashboardH, _, dashboardY = self:dashboardGeometry()
    -- 側掛：左翼右緣貼儀表板左緣、右翼左緣貼右緣，高度與可見儀表板同高。
    if self._style == STYLE_WINGS then
        local dashX = self._wingDashX
        if dashX == nil then dashX = left + math.floor((width - (self._wingDashW or 552)) / 2) end
        local wx = dashX - (self._wingLeftW or 0)
        if wx < left then wx = left end
        local wy = dashboardY and (dashboardY + DASH_VISIBLE_TOP_INSET)
            or (top + height - dashboardH + DASH_VISIBLE_TOP_INSET)
        if wy + self.height > top + height then wy = top + height - self.height end
        self:setX(wx)
        self:setY(wy)
        return
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
    if not dashboard
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
    self._blocked = token == "blocked"
    self:placeDetourButton()
    self._voiceOn = voiceEnabled()
    if not self.volumeSlider.dragging then
        self.volumeSlider.value = voiceVolume()
    end
    self.volumeSlider.valueText = tostring(self.volumeSlider.value)
    self:updateButtons()
end

function MDADHUDPanel:updateButtons()
    local selectedBg = self._style == STYLE_FAMILY and C.familySelected or C.selected
    local selectedText = self._style == STYLE_FAMILY and C.familyAccent or C.amber
    for i = 1, 4 do
        styleButton(self.gearButtons[i], i == self._gear and selectedBg or C.button,
            i == self._gear and selectedText or C.text, true)
    end
    self.cycleButton:setTitle(GEAR_SHORT[self._gear] or "--")
    styleButton(self.cycleButton, selectedBg, selectedText, true)

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
    applyPolicyButton(self.zombieButton, "UI_MinidoracatAutoDrive_HUDZombie", "zombie",
        self._zombieOn, playerChoiceZombie, zombieTip, optionScale())
    applyPolicyButton(self.corpseButton, "UI_MinidoracatAutoDrive_HUDCorpse", "skull",
        self._corpseOn, playerChoiceCorpse, corpseTip, optionScale())
    applyPolicyButton(self.autoButton, "UI_MinidoracatAutoDrive_HUDAuto", "detour",
        autoDetour(), true,
        getText("UI_MinidoracatAutoDrive_HUDAutoTip") .. "\n"
            .. getText("UI_MinidoracatAutoDrive_HUDPolicyToggle"),
        optionScale())

    self.actionButton:setTitle(getText(self._active
        and "UI_MinidoracatAutoDrive_Stop" or "UI_MinidoracatAutoDrive_Start"))
    self.actionButton.tooltip = self._reason and getText(self._reason) or nil
    styleButton(self.actionButton, self._active and C.danger or C.start,
        self._active and C.red or C.green, true)
    -- 側掛：兩顆 chevron 各自報自己那片的方向（左翼／右翼），其餘主題沿用整面板文案。
    local wings = self._style == STYLE_WINGS
    self.collapseButton.tooltip = getText((wings and self._wingR or self._collapsed)
        and (wings and "UI_MinidoracatAutoDrive_HUDWingRShow"
            or "UI_MinidoracatAutoDrive_HUDExpand")
        or (wings and "UI_MinidoracatAutoDrive_HUDWingRHide"
            or "UI_MinidoracatAutoDrive_HUDCollapse"))
    styleButton(self.collapseButton, C.button, C.muted, true)
    if wings then
        self.wingButton.tooltip = getText(self._wingL
            and "UI_MinidoracatAutoDrive_HUDWingLShow"
            or "UI_MinidoracatAutoDrive_HUDWingLHide")
        styleButton(self.wingButton, C.button, C.muted, true)
    end
    self.detourButton.tooltip = getText("UI_MinidoracatAutoDrive_HUDDetourTip")
    setGlyph(self.detourButton, "detour", getText("UI_MinidoracatAutoDrive_HUDDetourButton"), optionScale())
    styleButton(self.detourButton, C.selected, C.amber, true)
    if modOptions then
        self.themeButton.tooltip = getText("UI_MinidoracatAutoDrive_HUDTheme")
            .. ": " .. getText(THEME_KEYS[self._style] or THEME_KEYS[1])
        setGlyph(self.themeButton, "palette", getText("UI_MinidoracatAutoDrive_HUDStyleButton"), optionScale())
        styleButton(self.themeButton, C.button, C.muted, true)
        setGlyph(self.voiceButton, self._voiceOn and "speaker_on" or "speaker_off",
            getText("UI_MinidoracatAutoDrive_HUDVoice") .. " "
                .. getText(self._voiceOn and "UI_MinidoracatAutoDrive_HUDOn"
                    or "UI_MinidoracatAutoDrive_HUDOff"), optionScale())
        self.voiceButton.tooltip = getText("UI_MinidoracatAutoDrive_HUDVoiceTip")
        styleButton(self.voiceButton, self._voiceOn and C.start or C.button,
            self._voiceOn and C.green or C.muted, true)
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
    local w, h = self.width, self.height
    if self._style == STYLE_GLASS then
        fill(self, 0, 0, w, h, C.glass, "round")
        border(self, 0, 0, w, h, C.border, "round")
        return
    end
    if self._style == STYLE_FAMILY then
        fill(self, 0, 0, w, h, C.familySurface, "round")
        if self._headerH > 0 then
            fill(self, 0, 0, w, self._headerH, C.familyTitle, "roundTop")
            self:drawRect(0, self._headerH, w, 1,
                C.familyBorder.a, C.familyBorder.r, C.familyBorder.g, C.familyBorder.b)
        end
        border(self, 0, 0, w, h, C.familyBorder, "round")
        return
    end
    -- 原版 dashboard 是 #343434 平面＋#5A5A5A 斜角，不是亮面圓角金屬。
    -- 三段矩形做 6px chamfer；外框本身就是 bevel，不再疊螺絲／圓角九宮格。
    if self._style == STYLE_WINGS then
        -- 兩片各自畫框，中段（儀表板所在）一個像素都不畫。
        self:drawMetalFrame(0, 0, self._wingLeftW or 0, h)
        self:drawMetalFrame(self._wingRightX or 0, 0, self._wingRightW or 0, h)
        return
    end
    self:drawMetalFrame(0, 0, w, h)
    if self._blockX then
        self:drawRect(self._blockX, 6, 1, h - 12,
            C.metalOuter.a, C.metalOuter.r, C.metalOuter.g, C.metalOuter.b)
    end
end

-- 六段只差 x/y；顏色先拆成純量（每幀欄位查表 48 → 10 次），幾何也一眼可讀。
function MDADHUDPanel:drawMetalFrame(x, y, w, h)
    if w <= 16 or h <= 16 then return end
    local edge, face = C.metalOuter, C.metalFace
    local ea, er, eg, eb = edge.a, edge.r, edge.g, edge.b
    local fa, fr, fg, fb = face.a, face.r, face.g, face.b
    self:drawRect(x + 6, y, w - 12, h, ea, er, eg, eb)
    self:drawRect(x + 3, y + 3, w - 6, h - 6, ea, er, eg, eb)
    self:drawRect(x, y + 6, w, h - 12, ea, er, eg, eb)
    self:drawRect(x + 8, y + 2, w - 16, h - 4, fa, fr, fg, fb)
    self:drawRect(x + 5, y + 5, w - 10, h - 10, fa, fr, fg, fb)
    self:drawRect(x + 2, y + 8, w - 4, h - 16, fa, fr, fg, fb)
    self:drawRect(x + 8, y + 2, w - 16, 1,
        C.highlight.a, C.highlight.r, C.highlight.g, C.highlight.b)
    self:drawRect(x + 8, y + h - 4, w - 16, 2,
        C.shadow.a, C.shadow.r, C.shadow.g, C.shadow.b)
end

-- 側掛的文字：左翼（狀態燈／狀態字／現速／巡航）與右翼（檔位標籤／電油）各自
-- 依自己的收合狀態畫；摺起來的那一片只剩徽章字。
function MDADHUDPanel:renderWings()
    dot(self, self._dotX, self._dotY, 8, self._statusColor)
    self:drawText(self._speedText, self._speedX, self._speedY,
        C.text.r, C.text.g, C.text.b, C.text.a, UIFont.Medium)
    if not self._wingLFolded then
        self:drawText(self._statusText, self._statusX, self._textY,
            C.text.r, C.text.g, C.text.b, C.text.a, UIFont.Small)
        self:drawText(self._unitText, self._unitX, self._speedY,
            C.muted.r, C.muted.g, C.muted.b, C.muted.a, UIFont.Small)
        self:drawText(self._capLabel, self._capX, self._capLabelY,
            C.muted.r, C.muted.g, C.muted.b, C.muted.a, UIFont.Small)
        self:drawText(self._capText, self._capValueX, self._capValueY,
            C.amber.r, C.amber.g, C.amber.b, C.amber.a, UIFont.Small)
        if self._wingLDividerY then
            self:drawRect(4, self._wingLDividerY, (self._wingLeftW or 8) - 8, 1,
                C.faint.a, C.faint.r, C.faint.g, C.faint.b)
        end
    end
    if self._wingRFolded then
        self:drawText(GEAR_SHORT[self._gear] or "--", self._gearBadgeX, self._gearBadgeY,
            C.amber.r, C.amber.g, C.amber.b, C.amber.a, UIFont.Small)
        return
    end
    self:drawText(self._gearLabel, self._labelX, self._bottomTextY,
        C.muted.r, C.muted.g, C.muted.b, C.muted.a, UIFont.Small)
    self:drawText(self._energyText, self._energyX, self._energyY,
        C.muted.r, C.muted.g, C.muted.b, C.muted.a, UIFont.Small)
    if self._wingRDividerY then
        self:drawRect((self._wingRightX or 0) + 4, self._wingRDividerY,
            (self._wingRightW or 8) - 8, 1,
            C.faint.a, C.faint.r, C.faint.g, C.faint.b)
    end
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
    if self._style == STYLE_WINGS then return self:renderWings() end
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
    local capColor = self._style == STYLE_FAMILY and C.familyAccent or C.amber
    self:drawText(self._capText, self._capValueX, self._capValueY,
        capColor.r, capColor.g, capColor.b, capColor.a, UIFont.Small)
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

function MDADHUDPanel:onAutoDetour()
    setAutoDetour(not autoDetour())
    self._forceRefresh = true
    self:refresh(getTimestampMs())
end

function MDADHUDPanel:onAction()
    local playerObj = getSpecificPlayer(self.playerNum)
    if playerObj then Drive.toggle(playerObj) end
    self._forceRefresh = true
    self:refresh(getTimestampMs())
end

-- 側掛時 collapseButton＝右翼 chevron，wingButton＝左翼；其餘主題只有整面板收合。
function MDADHUDPanel:onCollapse()
    if self._style == STYLE_WINGS then return self:setWing("right", not self._wingR) end
    self:setCollapsed(not self._collapsed)
end

function MDADHUDPanel:onWing()
    self:setWing("left", not self._wingL)
end

function MDADHUDPanel:onTheme()
    if not modOptions then return end
    local nextStyle = self._style + 1
    if nextStyle > STYLE_COUNT then nextStyle = 1 end
    setClientOption("HUDTheme", nextStyle)
    self._forceRefresh = true
    self:refresh(getTimestampMs())
end

function MDADHUDPanel:onDetour()
    if type(Drive.requestDetour) ~= "function" then return end
    local ok, why = Drive.requestDetour(self.playerNum)
    if getDebug() and not ok then
        print("[" .. MDAD.MOD_ID .. "] HUD detour rejected: " .. tostring(why))
    end
    self._forceRefresh = true
    self:refresh(getTimestampMs())
end

function MDADHUDPanel:onVoice()
    if not modOptions then return end
    setVoiceEnabled(not self._voiceOn)
    self._forceRefresh = true
    self:refresh(getTimestampMs())
    if self._voiceOn then playVoice("start", self.playerNum) end
end

-- 拉桿回呼：拖曳中只 apply（不落盤）；放開／滾輪＝committed：落盤＋播短句回饋。
function MDADHUDPanel:onVolume(value, committed)
    if not modOptions then return end
    setVoiceVolume(value, committed)
    self.volumeSlider.valueText = tostring(value)
    if committed then
        self._forceRefresh = true
        if self._voiceOn then playVoice("arrive", self.playerNum) end
    end
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

local function destroyPanel(playerNum)
    local panel = panels[playerNum]
    if not panel then return end
    panel:setHudVisible(false)
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
    modOptions:addTickBox("VoiceEnabled", "UI_MinidoracatAutoDrive_VoiceEnabled", true,
        "UI_MinidoracatAutoDrive_VoiceEnabled_tooltip")
    modOptions:addSlider("VoiceVolume", "UI_MinidoracatAutoDrive_VoiceVolume",
        0, 100, VOICE_VOLUME_STEP, VOICE_VOLUME_DEFAULT,
        "UI_MinidoracatAutoDrive_VoiceVolume_tooltip")
    local voiceLanguageOption = modOptions:addComboBox("VoiceLanguage",
        "UI_MinidoracatAutoDrive_VoiceLanguage", "UI_MinidoracatAutoDrive_VoiceLanguage_tooltip")
    for i = 1, #VOICE_LANG_KEYS do
        voiceLanguageOption:addItem(VOICE_LANG_KEYS[i], i == 1)
    end
    modOptions:addTickBox("AutoDetour", "UI_MinidoracatAutoDrive_AutoDetour", false,
        "UI_MinidoracatAutoDrive_AutoDetour_tooltip")
    -- 回報導航問題：按鈕複製 GitHub 表單網址（PZAPI addButton＝ModOptions.lua:230；
    -- MainOptions.lua:2978-2980 以 setOnClick(onclick, args) 接線，onclick(target, button)）。
    -- ESC 選項是本機主玩家的，固定 playerNum 0。
    if type(modOptions.addButton) == "function" then
        modOptions:addButton("ReportIssue", "UI_MinidoracatAutoDrive_ReportIssue",
            "UI_MinidoracatAutoDrive_ReportIssue_tooltip",
            function() copyDiag(0, "copyReportLink") end)
    end
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
    for i = 1, #THEME_KEYS do theme:addItem(THEME_KEYS[i], i == 1) end
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
    -- 同時改每人 viewport；所有既有 panel 都要重算 layout。
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
HUD.trajectoryVisible = trajectoryVisible
HUD.trajectoryWidth = trajectoryWidth
HUD.setTrajectoryVisible = setTrajectoryVisible
HUD.setTrajectoryWidth = setTrajectoryWidth
HUD.telemetryEnabled = telemetryEnabled
HUD.telemetryRetentionDays = telemetryRetentionDays
HUD.setTelemetryEnabled = setTelemetryEnabled
HUD.setTelemetryRetentionDays = setTelemetryRetentionDays
HUD.voiceEnabled = voiceEnabled
HUD.voiceVolume = voiceVolume
HUD.setVoiceEnabled = setVoiceEnabled
HUD.setVoiceVolume = setVoiceVolume
HUD.voiceLanguage = voiceLanguage
HUD.voiceLanguageIndex = voiceLanguageIndex
HUD.setVoiceLanguageIndex = setVoiceLanguageIndex
HUD.autoDetour = autoDetour
HUD.setAutoDetour = setAutoDetour
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
            { label = "UI_MinidoracatAutoDrive_VoiceEnabled",
                tooltip = "UI_MinidoracatAutoDrive_VoiceEnabled_tooltip",
                get = voiceEnabled, set = setVoiceEnabled },
            { label = "UI_MinidoracatAutoDrive_AutoDetour",
                tooltip = "UI_MinidoracatAutoDrive_AutoDetour_tooltip",
                get = autoDetour, set = setAutoDetour },
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
            { label = "UI_MinidoracatAutoDrive_VoiceLanguage",
                tooltip = "UI_MinidoracatAutoDrive_VoiceLanguage_tooltip",
                items = VOICE_LANG_KEYS,
                default = 1,
                get = voiceLanguageIndex, set = setVoiceLanguageIndex },
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
                run = function(pn) copyDiag(pn, "copyLatestPath") end },
            { label = "UI_MinidoracatAutoDrive_CopyTelemetryFolder",
                tooltip = "UI_MinidoracatAutoDrive_CopyTelemetryFolder_tooltip",
                run = function(pn) copyDiag(pn, "copyFolderPath") end },
            { label = "UI_MinidoracatAutoDrive_ReportIssue",
                tooltip = "UI_MinidoracatAutoDrive_ReportIssue_tooltip",
                run = function(pn) copyDiag(pn, "copyReportLink") end },
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
