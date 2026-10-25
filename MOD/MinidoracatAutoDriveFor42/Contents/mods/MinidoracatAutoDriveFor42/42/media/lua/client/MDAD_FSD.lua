-- MDAD_FSD.lua — FSD 卡片（1024a）。坐換掉原版儀表的選配儀表 MOD 的車（MDAD.HUD.teslaRect 可見）時，HUD 面板
-- （MDADHUDPanel）不走四種主題，改成貼在那個儀表上方、同寬的一張卡：左邊航向朝上的場景，右欄狀態晶片／巡航上限／
-- 預計抵達／主鈕，下排檔位與策略鍵；可收成一顆晶片。其他車完全不經過本檔。
--
-- 分工：控制鈕、回呼、250ms refresh 算的字串全部沿用 MDAD_HUD（同一批 ISButton 子元件，只換位置與配色）；本檔只管
-- 卡片版面（layout／reposition）、狀態對照與配色（refresh 尾端）、繪製（prerender／render）。場景資料讀
-- MDADScene 快照（MDAD_Scene.lua，HUD update 每 0.1 秒 build）；prerender 只讀快照＋一次 getTimestampMs 外推，
-- 不讀遊戲狀態、不配置 table／closure。線段一律 drawPolygon（引擎 DrawLine 的寬度往斜角推，MiniMap 踩過），
-- 場景用 setStencilRect 裁在自己的矩形內。
-- 引擎出處：UIElement.DrawPolygon（UIElement.java:531-546，貼圖 nil＝純色，GenericSpriteRenderState.java:962）、
-- setStencilRect／clearStencilRect（UIElement.java:1875-1926；Lua 包裝 ISUIElement.lua:459、1254）、
-- 子元件畫在面板 prerender 之後、render 之前（UIElement.java:1615-1635）。

MDADFSD = MDADFSD or {}
local F = MDADFSD

local floor, max, sqrt = math.floor, math.max, math.sqrt

local function rgb(r, g, b, a)
    return { r = r / 255, g = g / 255, b = b / 255, a = a or 1 }
end

-- 色票＝選配儀表 MOD 的儀表 token（它的 references/hud.md「顏色」），綠色只給抵達（充電／回收的語意），自駕中是藍。
local T = {
    bg = rgb(18, 20, 23, 0.94), surface = rgb(30, 34, 39), track = rgb(46, 52, 59),
    text = rgb(243, 245, 247), text2 = rgb(174, 182, 191), text3 = rgb(142, 152, 163),
    accent = rgb(91, 140, 255), accentFill = rgb(62, 106, 225), ok = rgb(61, 214, 140),
    warn = rgb(245, 181, 68), danger = rgb(255, 107, 107), white = rgb(255, 255, 255),
    scene = rgb(14, 16, 19), road = rgb(32, 37, 43), curb = rgb(58, 65, 72), parked = rgb(74, 82, 91),
    ego = rgb(230, 233, 237), glass = rgb(42, 48, 55), clear = rgb(0, 0, 0, 0), hover = rgb(46, 52, 59, 0.6),
}
F.COLORS = T

-- 透視：前方 y 公尺的縮放 w＝D0/(D0+y)；畫面 y 從自車往上壓縮到 FAR，橫向乘 w。NEAR＝自車後方也畫到的距離，
-- YMIN 防除以 0。KF＝橫向相對縱向的放大（路面看起來比 1:1 寬，同原廠視覺）。
local D0, FAR, NEAR, YMIN, KF = 15, 52, -4, -9, 1.3
local PATH_HW = 0.55  -- 路徑帶半寬（公尺）
-- 軟目標畫成直立柱、車輛畫成有高度的方塊（高度用橫向比例 pK×w 換像素）：場景高度只有約 130px 卻涵蓋 56m，
-- 30–50m 外的車只有 1–2px 深，平面多邊形看起來是一條線（實機 1024a6 車牆截圖）。
local ZOM_W, ZOM_H = 0.5, 1.6
local VEH_H = 1.4
local EGO_HW, EGO_HL = 0.95, 2.35
local DESIGN_W, CARD_GAP = 552, 8
local AMBER = { dodging = true, unstick = true, side = true, lowfps = true, areawait = true, rehitch = true,
    rehitchwait = true, rehitchfound = true, rehitchback = true, uturn = true, uturnslow = true }
local HOT = { zombie = true, animal = true, player = true }

-- 每幀的投影參數與外推量（prerender 寫、proj／mv 讀；純量 upvalue，不配置）
local pcx, pyE, pH, pInv, pK = 0, 0, 1, 1, 1
local ca, sa, mx, my = 1, 0, 0, 0
local LX, LY, RX, RY = {}, {}, {}, {}

local function proj(x, y)
    if y < YMIN then y = YMIN end
    local w = D0 / (D0 + y)
    return pcx + x * pK * w, pyE - pH * (1 - w) * pInv, w
end

local function mv(x, y)
    local X, Y = x - mx, y - my
    return X * ca - Y * sa, X * sa + Y * ca
end

local function poly(p, x1, y1, x2, y2, x3, y3, x4, y4, c, a)
    p:drawPolygon(nil, x1, y1, x2, y2, x3, y3, x4, y4, c.r, c.g, c.b, a or c.a)
end

-- 螢幕空間固定像素寬的線（四邊形）
local function line(p, x1, y1, x2, y2, hw, c)
    local dx, dy = x2 - x1, y2 - y1
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.5 then return end
    local nx, ny = -dy / len * hw, dx / len * hw
    poly(p, x1 + nx, y1 + ny, x2 + nx, y2 + ny, x2 - nx, y2 - ny, x1 - nx, y1 - ny, c)
end

local function skin()
    local ui = MinidoracatUI and MinidoracatUI.v1
    return ui and ui.API_MAJOR == 1 and ui.Skin or nil
end

local function fill(p, x, y, w, h, c)
    local fw = skin()
    if fw then return fw.fill(p, x, y, w, h, c, "round") end
    p:drawRect(x, y, w, h, c.a, c.r, c.g, c.b)
end

-- 自車座標的軸對齊矩形 [x0,x1]×[y0,y1]（公尺）投影成四邊形（前窄後寬）
local function box(p, x0, y0, x1, y1, c)
    local ax, ay = proj(x0, y1)
    local bx, by = proj(x1, y1)
    local cx, cy = proj(x1, y0)
    local dx, dy = proj(x0, y0)
    poly(p, ax, ay, bx, by, cx, cy, dx, dy, c)
end

local function rect(b, x, y, w, h)
    b:setX(x)
    b:setY(y)
    b:setWidth(w)
    b:setHeight(h)
end

local function copy(t, s)
    t.r, t.g, t.b, t.a = s.r, s.g, s.b, s.a
end

-- ISButton 配色：不呼叫 setEnable（HUD updateButtons 已依策略鎖設好可否點擊，setEnable 會用快照覆寫顏色）。
local function tint(b, bg, fg)
    copy(b.backgroundColor, bg)
    copy(b.backgroundColorMouseOver, T.hover)
    b.borderColor.a = 0
    copy(b.textColor, fg)
    if b.textureColor then copy(b.textureColor, fg) end
end

local function textW(font, s)
    return getTextManager():MeasureStringX(font, s or "")
end

local function fits(s, w)
    return s ~= nil and textW(UIFont.Small, s) <= w
end

-- 沿路線還剩多遠：滿 1 公里一位小數 km，否則四捨五入到 10 m。
function F.distText(m)
    if type(m) ~= "number" or m * 0 ~= 0 or m < 0 then return nil end
    if m >= 1000 then return string.format("%.1f km", m / 1000) end
    return string.format("%d m", floor(m / 10 + 0.5) * 10)
end

local function hideAll(p)
    for i = 1, 4 do p.gearButtons[i]:setVisible(false) end
    p.cycleButton:setVisible(false)
    p.zombieButton:setVisible(false)
    p.corpseButton:setVisible(false)
    p.autoButton:setVisible(false)
    p.animalButton:setVisible(false)
    p.speedButton:setVisible(false)
    p.contButton:setVisible(false)
    p.actionButton:setVisible(false)
    p.homeButton:setVisible(false)
    p.themeButton:setVisible(false)
    p.wingButton:setVisible(false)
    p.voiceButton:setVisible(false)
    p.detourButton:setVisible(false)
    p.statusTip:setVisible(false)
    p.capTip:setVisible(false)
    p.etaTip:setVisible(false)
    p.volumeSlider:setVisible(false)
    p.collapseButton:setVisible(true)
end

-- 卡片貼在儀表上方 CARD_GAP×S、水平置中；儀表 MOD 的充電卡開著（_ccY＝它的頂邊，HUD.chargeCardTop）就疊在充電卡上方。
-- 收合成晶片時同一位置。
function F.reposition(p)
    local x = p._tsX + floor((p._tsW - p.width) / 2)
    local y = (p._ccY or p._tsY) - p.height - floor(CARD_GAP * (p._fS or 1) + 0.5)
    local top = getPlayerScreenTop(p.playerNum)
    if y < top + 4 then y = top + 4 end
    p:setX(x)
    p:setY(y)
end

function F.sizePill(p)
    local w, h = p._fPillW or 160, p._fPillH or 24
    p:setWidth(w)
    p:setHeight(h)
    rect(p.collapseButton, 0, 0, w, h)
    F.reposition(p)
end

-- HUD applyLayout 在貼著選配儀表時改走這裡（m＝HUD measure 的量測表）。
function F.layout(p, m)
    p._fsd = true
    p._detourAllowed, p._showStatusText, p._capChip = false, false, false
    p._speedX, p._capX, p._etaX = nil, nil, nil
    p.capTip.fsd = true
    hideAll(p)
    local S = p._tsW / DESIGN_W
    local fontH = m.fontH
    local pad, gap = max(6, floor(12 * S + 0.5)), max(4, floor(CARD_GAP * S + 0.5))
    local ctrlH = max(m.ctrlH, floor(26 * S + 0.5))
    p._fS, p._fPad, p._fGap, p._fCtrlH = S, pad, gap, ctrlH
    p._fDotS = max(6, floor(8 * S + 0.5))
    p._fPillH = fontH + max(6, floor(10 * S + 0.5))
    local largeH = getTextManager():getFontHeight(UIFont.Large)
    local half = floor(gap / 2)
    local colH = fontH * 3 + largeH + ctrlH + half * 3 + gap
    local sceneH = max(colH, floor(118 * S + 0.5))
    -- 充電卡把錨點往上推，展開的卡片頂端會超出這位玩家的畫面：當場收成晶片（只改這次版面、不寫 modData＝玩家的
    -- 收合選擇不變），充電卡關掉或有空間就展開回來。
    local fullH = pad + sceneH + gap + ctrlH + pad
    local cramped = p._ccY ~= nil
        and p._ccY - floor(CARD_GAP * S + 0.5) - fullH < getPlayerScreenTop(p.playerNum) + 4
    if cramped and not p._collapsed then
        p._collapsed, p._fForced = true, true
    elseif not cramped and p._fForced then
        p._collapsed, p._fForced = false, nil
    end
    if p._collapsed then return F.sizePill(p) end
    local W = p._tsW
    local sceneW = floor(W * 0.58 + 0.5)
    p._fSX, p._fSY, p._fSW, p._fSH = pad, pad, sceneW, sceneH
    local cx = pad + sceneW + pad
    p._fCX, p._fCW = cx, W - cx - pad
    p._fChipY = pad
    p._fWhyY = pad + fontH + half
    p._fCapY = p._fWhyY + fontH + half
    p._fLargeH = largeH
    p._fEtaY = p._fCapY + largeH + half
    p._fBtnY = pad + sceneH - ctrlH
    local wF, wB = D0 / (D0 + FAR), D0 / (D0 + NEAR)
    local inv = 1 / (1 - wF)
    local ph = sceneH * 0.96 / ((wB - wF) * inv)
    p._fPInv, p._fPH, p._fPCX = inv, ph, pad + sceneW / 2
    p._fPYE = pad + sceneH - ph * (wB - 1) * inv - 1
    p._fPK = KF * ph * inv / D0
    p:setWidth(W)
    p:setHeight(pad + sceneH + gap + ctrlH + pad)
    -- 下排：左邊檔位分段鈕，右邊策略鍵（＋接續藥丸）、語音、收合
    local rowY = pad + sceneH + gap
    local gw = max(floor(44 * S + 0.5), m.gearW)
    local x = pad
    for i = 1, 4 do
        rect(p.gearButtons[i], x, rowY, gw, ctrlH)
        p.gearButtons[i]:setVisible(true)
        x = x + gw
    end
    local sgap = max(3, floor(6 * S + 0.5))
    x = W - pad - ctrlH
    rect(p.collapseButton, x, rowY, ctrlH, ctrlH)
    if m.controlsOn then
        x = x - sgap - ctrlH
        rect(p.voiceButton, x, rowY, ctrlH, ctrlH)
        p.voiceButton:setVisible(true)
    end
    local pols = m.controlsOn and { p.speedButton, p.animalButton, p.autoButton, p.corpseButton, p.zombieButton }
        or { p.corpseButton, p.zombieButton }
    -- 圖示可用＝方鈕；缺圖退文字寬，那樣放不下（會壓到檔位）就照樣收成方鈕，說明留在 tooltip
    local pw = m.policyW > m.ctrlH and m.policyW or ctrlH
    if x - #pols * (pw + sgap) - m.contW - sgap < p.gearButtons[4].x + gw then pw = ctrlH end
    for i = 1, #pols do
        x = x - sgap - pw
        rect(pols[i], x, rowY, pw, ctrlH)
        pols[i]:setVisible(true)
    end
    if p._contAvail and m.contW > 0 then
        x = x - sgap - m.contW
        p:placeContButton(x, rowY, m.contW, ctrlH, m)
        p.contButton:setVisible(true)
    end
    p.actionButton:setVisible(true)
    F.reposition(p)
end

-- 右欄主鈕列（依狀態）：受阻＝［改道］［停止］，待命＝［開始］［回家］，其餘只有主鈕。寬度跟字走，不超過右欄。
local function placeButtons(p, st)
    local x, y, h, cw = p._fCX, p._fBtnY, p._fCtrlH, p._fCW
    local padX = max(12, floor(20 * p._fS + 0.5))
    local minW = floor(56 * p._fS + 0.5)
    local gap = max(3, floor(6 * p._fS + 0.5))
    local function width(b)
        local w = textW(UIFont.Small, b.title) + padX
        if w < minW then w = minW end
        if w > cw then w = cw end
        return w
    end
    local detour = st == "blocked" and p._active
    p.detourButton:setVisible(detour)
    if detour then
        p.detourButton.image = nil
        p.detourButton:setTitle(getText("UI_MinidoracatAutoDrive_HUDDetourButton"))
        local w = width(p.detourButton)
        rect(p.detourButton, x, y, w, h)
        tint(p.detourButton, T.accentFill, T.white)
        x = x + w + gap
    end
    local aw = width(p.actionButton)
    rect(p.actionButton, x, y, aw, h)
    x = x + aw + gap
    local home = not p._active and p._homeAvail == true and x + h <= p._fCX + cw
    p.homeButton:setVisible(home)
    if home then
        local hw = p.homeButton.image and h or width(p.homeButton)
        rect(p.homeButton, x, y, hw, h)
        tint(p.homeButton, T.surface, p._homeSet and T.text or T.text3)
    end
end

-- 狀態對照（refresh 尾端，250ms）：HUD 狀態鍵／停止原因／抵達紀錄 → 六種卡片狀態與晶片、說明、路徑配色。
local function classify(p, token, arrived)
    if p._active then
        if token == "arrive" then return "arrived" end
        if token == "blocked" then return "blocked" end
        if token == "yield" or token == "build" then return "assist" end
        if p._slowCategory or token ~= "follow" then return "slowing" end
        return "engaged"
    end
    if p._stopTip then return "takeover" end
    if arrived then return "arrived" end
    return "standby"
end

function F.refresh(p, token, now)
    local pn, drive = p.playerNum, MDAD.Drive
    local arrived = not p._active and type(drive.hudArrive) == "function" and drive.hudArrive(pn, p.vehicle) ~= nil
    local st = classify(p, token, arrived)
    p._fState = st
    local cw = (p._fCW or 200) - (p._fDotS or 8) - 6
    local chip, chipC, why, whyC = nil, T.text2, nil, T.text2
    local follow = getText("UI_MinidoracatAutoDrive_HUDStatusFollow")
    if st == "engaged" then
        chip, chipC = follow, T.accent
    elseif st == "slowing" then
        chip, chipC = follow, T.accent
        why = p._statusText
        if AMBER[token] then whyC = T.warn end
        local target = p._targetKmh
        if p._slowCategory and type(target) == "number" and target * 0 == 0 then
            local slow = getText("UI_MinidoracatAutoDrive_FsdSlowTo", p._statusText, string.format("%d", floor(target + 0.5)))
            if fits(slow, cw) then why = slow end
        end
    elseif st == "assist" then
        chip = p._statusText
    elseif st == "blocked" then
        chip, chipC, why = getText("UI_MinidoracatAutoDrive_FsdBlocked"), T.danger, p._statusText
    elseif st == "takeover" then
        chip, chipC, whyC = getText("UI_MinidoracatAutoDrive_FsdTakeover"), T.danger, T.danger
        why = p._reason and getText(p._reason) or nil
        if not fits(why, cw) then why = p._statusText end
    elseif st == "arrived" then
        local label = p._tripLabel
        chip, chipC = label and getText("UI_MinidoracatAutoDrive_FsdArrived", label), T.ok
        if not fits(chip, cw) then chip = getText("UI_MinidoracatAutoDrive_FsdArrivedNoName") end
        if not p._active then why = getText("UI_MinidoracatAutoDrive_FsdTripTime", p._clockText) end
    else
        chip = p._statusText
    end
    if why and not fits(why, cw) then why = nil end
    p._fChip, p._fChipC, p._fWhy, p._fWhyC = chip, chipC, why, whyC
    p._fHot = st == "blocked" or (st == "slowing" and HOT[p._slowCategory or ""] == true)
    if st == "engaged" or st == "slowing" or st == "arrived" then
        p._fPathC, p._fPathA = T.accentFill, 0.9
    elseif st == "blocked" or st == "takeover" then
        p._fPathC, p._fPathA = T.danger, 0.55
    else
        p._fPathC, p._fPathA = T.text3, 0.5
    end
    p._fCapC = (p._active and st ~= "assist") and T.accent or T.text2
    p._fUnit = p._unitText .. " " .. p._capLabel
    -- 預計抵達：剩幾分 | 幾 km | 目的地 | 第 N/M 站；放不下依序丟站數、目的地。分隔字用 ASCII（Kahlua 字面值只收 ASCII，verify 擋）。
    local eta = p._active and p._etaMin ~= nil and p._etaText or nil
    local dist = eta and F.distText(p._etaDist) or nil
    local counter = p._tripTotal and p._tripTotal > 1 and p._tripCounter or nil
    local function join(a, b) return a and b and (a .. " | " .. b) or a or b end
    local short = join(eta, dist)
    local line = join(join(short, p._tripLabel), counter)
    if not fits(line, p._fCW or 200) then line = join(short, p._tripLabel) end
    if not fits(line, p._fCW or 200) then line = short end
    p._fEta = line
    p._fsdDone = st == "arrived" and not p._active and not p._tripActionKey
    if p._collapsed then
        local pill = (chip or "") .. "  " .. p._capText .. " " .. p._unitText
        if eta then pill = pill .. " | " .. eta end
        p._fPill = pill
        local w = (p._fPad or 8) * 2 + 12 + textW(UIFont.Small, pill)
        if w ~= p._fPillW then
            p._fPillW = w
            F.sizePill(p)
        end
        local cb = p.collapseButton
        cb.image = nil
        cb:setTitle("")
        tint(cb, T.clear, T.text)
        return
    end
    F.restyle(p, st)
    placeButtons(p, st)
    local x, fontH = p._fCX, p._fontH or 16
    -- 說明列滑過：完整停止原因＋幾分鐘前／卡頓數據／降速明細
    local tip = p._lowFpsTip or p._stopTip or (p._slowCategory and p._speedTip) or nil
    local showTip = why ~= nil and tip ~= nil
    if showTip then
        rect(p.statusTip, x, p._fWhyY, textW(UIFont.Small, why), fontH)
        p.statusTip.tooltip = tip
    end
    p.statusTip:setVisible(showTip)
    -- 巡航上限：整塊點一下切速度明細、滑過看降速明細（沿用 HUD 的 capTip，畫法見 F.drawCap）
    local cap = p.capTip
    cap.valueText, cap.labelText, cap.valueColor, cap.pinned = p._capText, p._fUnit, p._fCapC, p._speedPin
    cap.valueX = 0
    cap.labelX = textW(UIFont.Large, p._capText) + floor(6 * p._fS + 0.5)
    cap.labelY = p._fLargeH - fontH - 2
    rect(cap, x, p._fCapY, cap.labelX + textW(UIFont.Small, p._fUnit) + 4, p._fLargeH)
    cap.tooltip = p._speedTip
    cap:setVisible(true)
    local tripTip = line and p._tripTip or nil
    if tripTip then
        rect(p.etaTip, x, p._fEtaY, textW(UIFont.Small, line), fontH)
        p.etaTip.tooltip = tripTip
    end
    p.etaTip:setVisible(tripTip ~= nil)
end

-- 子元件配色（updateButtons 之後覆寫成卡片色票）：開著的鍵＝accent 圖示＋底線（底線在 F.overlay），不只靠顏色。
function F.restyle(p, st)
    for i = 1, 4 do
        local b = p.gearButtons[i]
        b._fOn = i == p._gear
        tint(b, b._fOn and T.track or T.surface, b._fOn and T.text or T.text2)
    end
    local hud = MDAD.HUD
    local function pol(b, on)
        b._fOn = on == true
        tint(b, T.surface, b.enable == false and T.track or (b._fOn and T.accent or T.text3))
    end
    pol(p.zombieButton, p._zombieOn)
    pol(p.corpseButton, p._corpseOn)
    pol(p.autoButton, hud.autoDetour())
    pol(p.animalButton, hud.animalDodge() ~= 1)
    pol(p.speedButton, p._speedPin)
    pol(p.voiceButton, p._voiceOn)
    tint(p.contButton, T.surface, p._tripAutoContinue == true and T.accent or T.text2)
    local cb = p.collapseButton
    if hud.setGlyph then hud.setGlyph(cb, "chevron_down", getText("UI_MinidoracatAutoDrive_HUDHideButton"), p._fS) end
    tint(cb, T.surface, T.text2)
    local ab = p.actionButton
    if p._fsdDone then
        ab:setTitle(getText("UI_MinidoracatAutoDrive_FsdDone"))
        tint(ab, T.surface, T.text)
    elseif p._active then
        tint(ab, T.surface, T.danger)
    elseif p._tripActionKey and not p._tripAction then
        tint(ab, T.surface, T.text3)
    else
        tint(ab, T.accentFill, T.white)
    end
end

-- HUD update（約 10 Hz）：卡片展開才建場景快照。沒有自駕 session（手動開）時每 PASSIVE_MS 被動掃一次附近的殭屍、
-- 玩家、動物與車輛（MDADOverlay.scanPassive，1025a）；有 session 由 Sensor 每輪寫，這裡不掃。
local PASSIVE_MS = 250
function F.update(p, now)
    if p._collapsed or not p.vehicle or not MDADScene then return end
    if MDADOverlay and now >= (p._fScanAt or 0) and not MDAD.Drive.isActive(p.playerNum) then
        p._fScanAt = now + PASSIVE_MS
        MDADOverlay.scanPassive(p.playerNum, p.vehicle)
    end
    MDADScene.build(p.playerNum, p.vehicle, now, p._tripLabel)
end

-- 「完成」：收掉抵達紀錄回到待命（Drive.clearArrive），不發車。
function F.done(p)
    local drive = MDAD.Drive
    if type(drive.clearArrive) == "function" then drive.clearArrive(p.playerNum) end
    p._forceRefresh = true
end

local function drawScene(p, snap, now)
    local sx, sy, sw, sh = p._fSX, p._fSY, p._fSW, p._fSH
    local c = T.scene
    p:drawRect(sx, sy, sw, sh, c.a, c.r, c.g, c.b)
    p:setStencilRect(sx, sy, sw, sh)
    pcx, pyE, pH, pInv, pK = p._fPCX, p._fPYE, p._fPH, p._fPInv, p._fPK
    if snap then
        ca, sa, mx, my = MDADScene.motion(snap, now)
        local lw = max(1, p._fS * 0.75)
        local n = snap.roadN
        for i = 1, n do
            LX[i], LY[i] = proj(mv(snap.roadLX[i], snap.roadLY[i]))
            RX[i], RY[i] = proj(mv(snap.roadRX[i], snap.roadRY[i]))
        end
        for i = 1, n - 1 do
            poly(p, LX[i], LY[i], RX[i], RY[i], RX[i + 1], RY[i + 1], LX[i + 1], LY[i + 1], T.road)
        end
        for i = 1, n - 1 do
            line(p, LX[i], LY[i], LX[i + 1], LY[i + 1], lw, T.curb)
            line(p, RX[i], RY[i], RX[i + 1], RY[i + 1], lw, T.curb)
        end
        n = snap.pathN
        if n >= 2 then
            local xs, ys = snap.pathX, snap.pathY
            for i = 1, n do
                local i0, i1 = i > 1 and i - 1 or 1, i < n and i + 1 or n
                local tx, ty = xs[i1] - xs[i0], ys[i1] - ys[i0]
                local tl = sqrt(tx * tx + ty * ty)
                if tl < 1e-6 then tx, ty, tl = 0, 1, 1 end
                local nx, ny = ty / tl * PATH_HW, -tx / tl * PATH_HW
                LX[i], LY[i] = proj(mv(xs[i] - nx, ys[i] - ny))
                RX[i], RY[i] = proj(mv(xs[i] + nx, ys[i] + ny))
            end
            -- 軌跡起點是上一輪掃描的 lastSNow，車已往前開（70 km/h 一輪約 5m）：遠端已在車心後方的段不畫，
            -- 跨過車心的那段壓在自車底下（實機 1024a4 截圖：藍帶從車底一路畫到場景下緣）
            local pc, pa, dodge = p._fPathC, p._fPathA, snap.pathDodge
            for i = 1, n - 1 do
                if LY[i + 1] + RY[i + 1] < pyE + pyE then
                    local d = dodge[i] or dodge[i + 1]
                    poly(p, LX[i], LY[i], RX[i], RY[i], RX[i + 1], RY[i + 1], LX[i + 1], LY[i + 1],
                        d and T.accent or pc, d and 0.75 or pa)
                end
            end
        end
        local hot = p._fHot
        -- 快照是近→遠（掃描順序），由遠往近畫，近的蓋住遠的
        for i = snap.zomN, 1, -1 do
            local x, y = mv(snap.zomX[i], snap.zomY[i])
            local px, py, w = proj(x, y)
            local zw, zh = max(3, ZOM_W * pK * w), max(5, ZOM_H * pK * w)
            local k = snap.zomKind[i]
            c = k == "corpse" and T.parked or (hot and snap.zomBand[i]) and T.warn or T.text3
            if k == "corpse" then zh = zw end -- 倒地的屍體不立起來
            p:drawRect(px - zw / 2, py - zh, zw, zh, c.a, c.r, c.g, c.b)
        end
        -- 車輛：OBB 四角投影成底面，四個側面往上拉 VEH_H，頂面最後畫（前側面蓋住後側面露出的部分，不必判可見面）
        for i = snap.vehN, 1, -1 do
            local cx, cy = mv(snap.vehX[i], snap.vehY[i])
            local dx, dy = snap.vehDX[i], snap.vehDY[i]
            local DX, DY = dx * ca - dy * sa, dx * sa + dy * ca
            local hl, hw = snap.vehHL[i], snap.vehHW[i]
            local fx, fy, rx, ry = DX * hl, DY * hl, DY * hw, -DX * hw
            local x1, y1, w1 = proj(cx + fx - rx, cy + fy - ry)
            local x2, y2, w2 = proj(cx + fx + rx, cy + fy + ry)
            local x3, y3, w3 = proj(cx - fx + rx, cy - fy + ry)
            local x4, y4, w4 = proj(cx - fx - rx, cy - fy - ry)
            local h = VEH_H * pK
            local t1, t2, t3, t4 = y1 - h * w1, y2 - h * w2, y3 - h * w3, y4 - h * w4
            local moving = snap.vehMoving[i]
            local side = moving and T.parked or T.track
            poly(p, x1, y1, x2, y2, x2, t2, x1, t1, side)
            poly(p, x2, y2, x3, y3, x3, t3, x2, t2, side)
            poly(p, x3, y3, x4, y4, x4, t4, x3, t3, side)
            poly(p, x4, y4, x1, y1, x1, t1, x4, t4, side)
            poly(p, x1, t1, x2, t2, x3, t3, x4, t4, moving and T.text3 or T.parked)
        end
    end
    -- 自車（航向朝上，固定在畫面下方）：車身＋前後擋風玻璃
    box(p, -EGO_HW, -EGO_HL, EGO_HW, EGO_HL, T.ego)
    box(p, -EGO_HW * 0.72, EGO_HL * 0.2, EGO_HW * 0.72, EGO_HL * 0.55, T.glass)
    box(p, -EGO_HW * 0.72, -EGO_HL * 0.85, EGO_HW * 0.72, -EGO_HL * 0.62, T.glass)
    p:clearStencilRect()
end

local function dot(p, x, y, s, c)
    p:drawRect(x, y, s, s, c.a, c.r, c.g, c.b)
end

-- HUD prerender（每幀）：只畫 refresh／layout 算好的欄位與場景快照。
function F.draw(p)
    local fontH = p._fontH or 16
    local pad = p._fPad or 8
    local dotS = p._fDotS or 8
    if p._collapsed then
        fill(p, 0, 0, p.width, p.height, T.bg)
        local c = p._fChipC or T.text2
        local y = floor((p.height - fontH) / 2)
        dot(p, pad, floor((p.height - dotS) / 2), dotS, c)
        if p._fPill then p:drawText(p._fPill, pad + dotS + 6, y, c.r, c.g, c.b, c.a, UIFont.Small) end
        return
    end
    fill(p, 0, 0, p.width, p.height, T.bg)
    local now = getTimestampMs()
    drawScene(p, MDADScene and MDADScene.get(p.playerNum, now) or nil, now)
    local x = p._fCX
    local c = p._fChipC or T.text2
    dot(p, x, p._fChipY + floor((fontH - dotS) / 2), dotS, c)
    if p._fChip then p:drawText(p._fChip, x + dotS + 6, p._fChipY, c.r, c.g, c.b, c.a, UIFont.Small) end
    if p._fWhy then
        c = p._fWhyC
        p:drawText(p._fWhy, x, p._fWhyY, c.r, c.g, c.b, c.a, UIFont.Small)
    end
    if p._fEta then
        c = T.text2
        p:drawText(p._fEta, x, p._fEtaY, c.r, c.g, c.b, c.a, UIFont.Small)
    end
end

-- HUD render（子元件之後）：選中的檔位與開著的策略鍵加 accent 底線。
local function underline(p, b)
    if not b._fOn or not b:isVisible() then return end
    local c = T.accent
    p:drawRect(b.x + 3, b.y + b.height - 2, b.width - 6, 2, c.a, c.r, c.g, c.b)
end

function F.overlay(p)
    if p._collapsed then return end
    for i = 1, 4 do underline(p, p.gearButtons[i]) end
    underline(p, p.zombieButton)
    underline(p, p.corpseButton)
    underline(p, p.autoButton)
    underline(p, p.animalButton)
    underline(p, p.speedButton)
    underline(p, p.voiceButton)
end

-- 巡航上限熱區（MDADHUDCapZone，fsd 旗標）：大字數值＋單位與欄名；滑過淡底，速度明細開著加 accent 底線。
function F.drawCap(z)
    if z.mouseOver then
        local h = T.hover
        z:drawRect(0, 0, z.width, z.height, h.a, h.r, h.g, h.b)
    end
    if z.pinned then
        local a = T.accent
        z:drawRect(0, z.height - 2, z.width, 2, a.a, a.r, a.g, a.b)
    end
    local c = z.valueColor or T.text2
    z:drawText(z.valueText, z.valueX or 0, 0, c.r, c.g, c.b, c.a, UIFont.Large)
    c = T.text2
    z:drawText(z.labelText, z.labelX or 0, z.labelY or 0, c.r, c.g, c.b, c.a, UIFont.Small)
end
