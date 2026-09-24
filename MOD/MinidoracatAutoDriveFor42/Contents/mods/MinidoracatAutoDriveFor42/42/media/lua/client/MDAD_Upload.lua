-- MDAD_Upload.lua — 伺服器診斷上傳（2026-09-24 使用者裁定）。
--
-- 伺服器沙盒 DiagnosticsUpload 開啟、玩家沒在選項退出時，自駕期間在**記憶體**保留最近
-- 30 秒的診斷紀錄（與本機診斷同一份 JSONL 編碼，由 MDAD_Diagnostics 餵進來），只在出事
-- 時把前後片段、每趟一份摘要送到伺服器（server/MDAD_UploadServer.lua 收）。玩家硬碟零 I/O。
--
-- 片段自足（使用者要求「足夠判斷並修復」）：檔頭＋最近一次路線原始點列＋整趟非 replan
-- 事件＋事前 PRE_MS／事後到脫困結束（最長 POST_MAX_MS）的完整取樣。
--
-- 引擎限制（42.20.4）：
--   字串以有號 short 記長度（GameWindow.java:1266；ByteBufferReader.java:48-52），超過
--   32767 bytes 伺服器解析拋錯、整筆丟（GameServer.java:2256-2261）。Kahlua 的 # 算 UTF-16
--   字元，最壞 3 bytes／字元 → 每塊 ≤10000 字元。
--   ClientCommand 是 HIGH 優先級（PacketTypes.java:498），車輛物理同步是 MEDIUM
--   （VehiclePhysicsUnreliablePacket.java:7-10）：行駛中放慢節奏，停車／行程外才加快。
--   ClientCommand 每秒封包數全 MOD 共用，客戶端超量靜默丟包（PacketTypes.java:704-706、
--   ServerOptions.java:209 預設 300）：一次最多一包、間隔 ≥500ms。

if MDADUpload then return end

local U = {}
MDADUpload = U

local PRE_MS = 30000
local POST_MIN_MS = 5000
local QUIET_MS = 5000
local POST_MAX_MS = 60000
local STALL_MS = 3000
local ANOMALY_TAKEOVER_MS = 10000
local RING_N = 480
local EVLOG_N = 400
local CLIP_MAX = 900000
local CHUNK = 10000
local SUM_MAX = CHUNK
local CLIPS_PER_DRIVE = 6
local CLIPS_PER_HOUR = 8
local HOUR_MS = 3600000
local KIND_COOLDOWN_MS = 60000
local OUTBOX_MAX = 4000000
local SEND_IDLE_MS = 500
local SEND_DRIVING_MS = 2000
local DRIVING_KMH = 10
local INC_MAX = 8

U.PRE_MS, U.CHUNK, U.CLIP_MAX = PRE_MS, CHUNK, CLIP_MAX

-- 片段優先級：數字越小越重要（伺服器每人 32 段滿了先覆蓋數字大的）。
local PRI = { stuck = 1, fault = 1, contact = 2, takeover = 3, unstick = 3, route = 3, brake = 4 }
U.PRI = PRI
local STOP_KIND = {
    UI_MinidoracatAutoDrive_StopStuck = "stuck",
    UI_MinidoracatAutoDrive_UnsupportedVehicle = "fault",
    UI_MinidoracatAutoDrive_LostRoute = "route",
    UI_MinidoracatAutoDrive_RouteTooFar = "route",
}

local outbox = {}      -- pn → { msgs..., n }
local hourly = {}      -- pn → clip 時戳（最近一小時）
local noticed = {}     -- pn → 本次遊戲已提示
local nextSendMs = 0
local msgSeq = 0
local lastSpeed = {}   -- pn → 最近一次取樣速度（節流用）

local function finite(n)
    return type(n) == "number" and n * 0 == 0
end

local function nowMs()
    if type(getTimestampMs) ~= "function" then return 0 end
    local ok, v = pcall(getTimestampMs)
    if ok and finite(v) then return v end
    return 0
end

local function jstr(s)
    return MDADDiagnostics.jstr(s)
end

local function jnum(n)
    if not finite(n) then return "0" end
    return tostring(n)
end

local function sandboxOn()
    local sb = MDAD and MDAD.sandbox
    if type(sb) ~= "function" then return false end
    local ok, v = pcall(sb, "DiagnosticsUpload", false)
    return ok and v == true
end

-- 只在 MP 客戶端：單機沒有伺服器可收，本機診斷才是那條路。
function U.enabled()
    local okC, client = pcall(isClient)
    if not okC or client ~= true then return false end
    if not sandboxOn() then return false end
    local hud = MDAD and MDAD.HUD
    if type(hud) == "table" and type(hud.shareDiagnostics) == "function" then
        local ok, v = pcall(hud.shareDiagnostics)
        if ok and v == false then return false end
    end
    return true
end

local function notice(pn)
    if noticed[pn] then return end
    noticed[pn] = true
    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(pn) or nil
    if not player or type(HaloTextHelper) ~= "table" then return end
    local text = type(getText) == "function"
        and getText("UI_MinidoracatAutoDrive_UploadNotice")
        or "UI_MinidoracatAutoDrive_UploadNotice"
    -- addText＝白字（HaloTextHelper.java:147-149）：告知、不是警告。
    if type(HaloTextHelper.addText) == "function" then
        pcall(HaloTextHelper.addText, player, text)
    elseif type(HaloTextHelper.addGoodText) == "function" then
        pcall(HaloTextHelper.addGoodText, player, text)
    end
    if MDADDiagnostics and MDADDiagnostics.toast then MDADDiagnostics.toast(text, "info") end
end

function U.begin(pn, now, header, profile)
    local u = {
        pn = pn, active = true,
        -- 與本機 session 共用的取樣閘門欄位（MDAD_Diagnostics.sampleWouldEnqueue／encodeSensor）
        lastSample = nil, lastNow = now, lastStamp = nil,
        drive = now, startTs = now, header = header, routeLine = nil,
        ring = {}, ringTs = {}, ringHead = 0, ringN = 0,
        ev = {}, evTs = {}, evHead = 0, evN = 0,
        cap = nil, clips = 0, lastAnomaly = -1e18, stallSince = nil,
        cooldown = {}, prevFbOn = false, prevFb = false,
        lastTs = nil, lastX = nil, lastY = nil, x0 = nil, y0 = nil, lastRem = nil,
        dist = 0, maxLat = 0, stallMs = 0,
        fb = {}, contact = 0, evc = {}, modeMs = {}, capMs = {},
        fdt = { 0, 0, 0, 0, 0, 0, 0 }, inc = {}, incN = 0,
        rev = MDAD and MDAD.Drive and MDAD.Drive.REV or "",
        build = MDAD and MDAD.BUILD or "",
        veh = type(profile) == "table" and profile.scriptName or "",
        mass = type(profile) == "table" and profile.mass or nil,
        opts = type(header) == "string" and string.match(header, '"opts":"([^"]*)"') or nil,
    }
    notice(pn)
    return u
end

local function push(u, line, ts)
    local i = u.ringHead % RING_N + 1
    u.ringHead = i
    u.ring[i] = line
    u.ringTs[i] = ts
    if u.ringN < RING_N then u.ringN = u.ringN + 1 end
    local cap = u.cap
    if cap then
        if cap.chars + #line + 1 <= CLIP_MAX then
            cap.n = cap.n + 1
            cap.lines[cap.n] = line
            cap.chars = cap.chars + #line + 1
        else
            cap.full = true
        end
    end
end

local function incident(u, kind, ts)
    if u.incN >= INC_MAX then return end
    u.incN = u.incN + 1
    u.inc[u.incN] = { kind, ts, u.lastX, u.lastY }
end

local function hourlyOk(pn, now)
    local list = hourly[pn]
    if not list then list = {}; hourly[pn] = list end
    local keep, k = {}, 0
    local i = 1
    while i <= #list do
        if now - list[i] < HOUR_MS and now >= list[i] then
            k = k + 1
            keep[k] = list[i]
        end
        i = i + 1
    end
    hourly[pn] = keep
    return k < CLIPS_PER_HOUR
end

-- 出事：已在擷取就併入（升級優先級、延長事後窗）；否則從 ring 取事前 PRE_MS 開新片段。
local function trigger(u, now, kind)
    u.lastAnomaly = now
    incident(u, kind, now)
    local pri = PRI[kind] or 4
    local cap = u.cap
    if cap then
        if pri < cap.pri then cap.pri, cap.kind = pri, kind end
        return
    end
    if u.clips >= CLIPS_PER_DRIVE then return end
    local last = u.cooldown[kind]
    if last and now >= last and now - last < KIND_COOLDOWN_MS then return end
    if not hourlyOk(u.pn, now) then return end
    u.cooldown[kind] = now
    cap = { kind = kind, pri = pri, t0 = now, x = u.lastX, y = u.lastY,
        lines = {}, n = 0, chars = 0, full = false }
    -- ring 由舊到新：找第一筆 ≥ t0-PRE_MS
    local from = now - PRE_MS
    local idx = u.ringHead - u.ringN
    local k = 1
    while k <= u.ringN do
        local j = (idx + k - 1) % RING_N + 1
        local ts = u.ringTs[j]
        if ts and ts >= from then
            local line = u.ring[j]
            cap.n = cap.n + 1
            cap.lines[cap.n] = line
            cap.chars = cap.chars + #line + 1
        end
        k = k + 1
    end
    cap.wStart = from
    u.cap = cap
    u.clips = u.clips + 1
    local list = hourly[u.pn]
    list[#list + 1] = now
end
U.trigger = trigger

local function enqueueMsg(pn, msg)
    local box = outbox[pn]
    if not box then box = { n = 0, chars = 0 }; outbox[pn] = box end
    -- 超過上限：丟掉最不重要、尚未開始送的一筆（進行中的不動），直到放得下。
    while box.chars + #msg.text > OUTBOX_MAX and box.n > 0 do
        local victim, vi = nil, nil
        local i = 1
        while i <= box.n do
            local m = box[i]
            if m.off == 0 and (not victim or m.pri > victim.pri) then victim, vi = m, i end
            i = i + 1
        end
        if not victim or victim.pri < msg.pri then return false end
        box.chars = box.chars - #victim.text
        table.remove(box, vi)
        box.n = box.n - 1
    end
    msgSeq = msgSeq + 1
    msg.id = msgSeq
    msg.off = 0
    msg.q = 0
    msg.total = math.floor((#msg.text + CHUNK - 1) / CHUNK)
    box.n = box.n + 1
    box[box.n] = msg
    box.chars = box.chars + #msg.text
    return true
end

local function finishClip(u, now)
    local cap = u.cap
    if not cap then return end
    u.cap = nil
    local head = '{"t":"clip","v":1,"kind":' .. jstr(cap.kind) .. ',"pri":' .. cap.pri
        .. ',"trig":' .. jnum(cap.t0) .. ',"end":' .. jnum(now)
        .. ',"drive":' .. jnum(u.drive) .. ',"pre":' .. PRE_MS
        .. ',"x":' .. jnum(cap.x) .. ',"y":' .. jnum(cap.y)
        .. ',"full":' .. (cap.full and "true" or "false") .. '}'
    local parts, n = { head }, 1
    local used = #head + 1
    if type(u.header) == "string" then
        n = n + 1; parts[n] = u.header; used = used + #u.header + 1
    end
    -- 路線點列與整趟事件只補事前窗之前的（窗內的已在取樣序列裡）。
    if u.routeLine and (u.routeTs or 0) < cap.wStart then
        n = n + 1; parts[n] = u.routeLine; used = used + #u.routeLine + 1
    end
    local budget = CLIP_MAX - cap.chars - used
    local startK = 1
    local evBytes = 0
    local k = u.evN
    while k >= 1 do
        local j = (u.evHead - u.evN + k - 1) % EVLOG_N + 1
        if u.evTs[j] < cap.wStart then
            local len = #u.ev[j] + 1
            if evBytes + len > budget then startK = k + 1; break end
            evBytes = evBytes + len
        end
        k = k - 1
    end
    k = startK
    while k <= u.evN do
        local j = (u.evHead - u.evN + k - 1) % EVLOG_N + 1
        if u.evTs[j] < cap.wStart and u.ev[j] ~= u.routeLine then
            n = n + 1; parts[n] = u.ev[j]
        end
        k = k + 1
    end
    local i = 1
    while i <= cap.n do
        n = n + 1; parts[n] = cap.lines[i]
        i = i + 1
    end
    enqueueMsg(u.pn, {
        k = "clip", kind = cap.kind, pri = cap.pri, trig = cap.t0, x = cap.x, y = cap.y,
        drive = u.drive, rev = u.rev, veh = u.veh,
        text = table.concat(parts, "\n", 1, n) .. "\n",
    })
end

local function captureTick(u, now)
    local cap = u.cap
    if not cap then return end
    local age = now - cap.t0
    if cap.full or age >= POST_MAX_MS
            or (age >= POST_MIN_MS and now - u.lastAnomaly >= QUIET_MS) then
        finishClip(u, now)
    end
end

-- 取樣：line 已由 MDAD_Diagnostics 編好（與本機紀錄同一字串，不重複編碼）。
function U.sample(u, line, now, x, y, speed, target, mode, remaining, lat,
        blocked, footprintBlocked, phys)
    push(u, line, now)
    if finite(x) and finite(y) then
        if not u.x0 then u.x0, u.y0 = x, y end
        u.lastX, u.lastY = x, y
    end
    if finite(remaining) then u.lastRem = remaining end
    if finite(speed) then lastSpeed[u.pn] = speed < 0 and -speed or speed end
    local dt = 0
    if u.lastTs and now > u.lastTs then
        dt = now - u.lastTs
        if dt > 1000 then dt = 1000 end
    end
    u.lastTs = now
    local spd = finite(speed) and (speed < 0 and -speed or speed) or 0
    u.dist = u.dist + spd / 3.6 * dt / 1000
    if finite(lat) then
        local a = lat < 0 and -lat or lat
        if a > u.maxLat then u.maxLat = a end
    end
    if type(mode) == "string" then u.modeMs[mode] = (u.modeMs[mode] or 0) + dt end
    local fbl, fbw, capReason, fdt
    if type(phys) == "table" then
        fbl, fbw, capReason, fdt = phys.forceBrakeLeft, phys.forceBrakeWhy, phys.capReason, phys.frameMs
    end
    if type(capReason) == "string" then u.capMs[capReason] = (u.capMs[capReason] or 0) + dt end
    if finite(fdt) then
        local b = fdt < 10 and 1 or fdt < 17 and 2 or fdt < 25 and 3 or fdt < 34 and 4
            or fdt < 50 and 5 or fdt < 100 and 6 or 7
        u.fdt[b] = u.fdt[b] + 1
    end
    -- 停滯：要走（目標 ≥10）卻幾乎不動，持續 STALL_MS 算異常（接手判定用）。
    if finite(target) and target >= 10 and spd < 3 then
        if not u.stallSince then u.stallSince = now end
        u.stallMs = u.stallMs + dt
        if now - u.stallSince >= STALL_MS then u.lastAnomaly = now end
    else
        u.stallSince = nil
    end
    if blocked == true or mode == "unstick" or mode == "recover" then u.lastAnomaly = now end
    local fbNow = finite(fbl) and fbl > 0
    if fbNow and not u.prevFbOn then
        local why = type(fbw) == "string" and fbw or "?"
        u.fb[why] = (u.fb[why] or 0) + 1
        -- 預期中的煞車（到站、脫困流程）與幾乎靜止時的煞車不算事故
        if why ~= "arrive" and string.sub(why, 1, 7) ~= "unstick" and why ~= "contact"
                and spd >= 3 then
            trigger(u, now, "brake")
        end
    end
    u.prevFbOn = fbNow
    local fbHit = footprintBlocked == true
    if fbHit and not u.prevFb then
        u.contact = u.contact + 1
        trigger(u, now, "contact")
    end
    u.prevFb = fbHit
    captureTick(u, now)
end

function U.event(u, line, now, name, a)
    push(u, line, now)
    name = tostring(name or "")
    u.evc[name] = (u.evc[name] or 0) + 1
    if name ~= "replan" then
        local i = u.evHead % EVLOG_N + 1
        u.evHead = i
        u.ev[i] = line
        u.evTs[i] = now
        if u.evN < EVLOG_N then u.evN = u.evN + 1 end
    end
    if string.find(line, '"src":"', 1, true) then
        u.routeLine, u.routeTs = line, now
    end
    local phase = type(a) == "table" and a.phase or nil
    if name == "unstick" and phase == "start" then
        trigger(u, now, "unstick")
    elseif name == "blocked" or name == "unstick" or name == "progress" then
        u.lastAnomaly = now
    elseif name == "takeover" and now - u.lastAnomaly <= ANOMALY_TAKEOVER_MS then
        trigger(u, now, "takeover")
    end
    captureTick(u, now)
end

local function mapJson(t)
    local parts, n = {}, 0
    for k, v in pairs(t) do
        n = n + 1
        parts[n] = jstr(k) .. ":" .. jnum(v)
    end
    return "{" .. table.concat(parts, ",", 1, n) .. "}"
end

local function summaryText(u, now, reason, withMaps)
    local inc, n = {}, 0
    local i = 1
    while i <= u.incN do
        local e = u.inc[i]
        n = n + 1
        inc[n] = "[" .. jstr(e[1]) .. "," .. jnum(e[2]) .. "," .. jnum(e[3]) .. "," .. jnum(e[4]) .. "]"
        i = i + 1
    end
    local text = '{"t":"sum","v":1,"drive":' .. jnum(u.drive) .. ',"end":' .. jnum(now)
        .. ',"dur":' .. jnum(now - u.startTs) .. ',"reason":' .. jstr(reason)
        .. ',"rev":' .. jstr(u.rev) .. ',"build":' .. jstr(u.build)
        .. ',"veh":' .. jstr(u.veh) .. ',"mass":' .. jnum(u.mass)
        .. (u.opts and (',"opts":' .. jstr(u.opts)) or "")
        .. ',"dist":' .. jnum(math.floor(u.dist * 10 + 0.5) / 10)
        .. ',"maxLat":' .. jnum(math.floor(u.maxLat * 100 + 0.5) / 100)
        .. ',"stallMs":' .. jnum(u.stallMs)
        .. ',"x0":' .. jnum(u.x0) .. ',"y0":' .. jnum(u.y0)
        .. ',"x1":' .. jnum(u.lastX) .. ',"y1":' .. jnum(u.lastY)
        .. ',"rem":' .. jnum(u.lastRem) .. ',"clips":' .. u.clips
        .. ',"contact":' .. u.contact .. ',"fb":' .. mapJson(u.fb)
        .. ',"fdt":[' .. table.concat(u.fdt, ",") .. ']'
        .. ',"inc":[' .. table.concat(inc, ",", 1, n) .. ']'
    if withMaps then
        text = text .. ',"ev":' .. mapJson(u.evc) .. ',"mode":' .. mapJson(u.modeMs)
            .. ',"cap":' .. mapJson(u.capMs)
    end
    return text .. "}"
end

-- 行程結束：終局原因本身也可能是事故（卡住交還、車輛不支援、路線遺失、接手前有異常）。
function U.finish(u, now, reason)
    if not u or not u.active then return end
    u.active = false
    reason = tostring(reason or "stop")
    local kind = STOP_KIND[reason]
    if kind then
        trigger(u, now, kind)
    elseif reason == "takeover" and now - u.lastAnomaly <= ANOMALY_TAKEOVER_MS then
        trigger(u, now, "takeover")
    end
    finishClip(u, now)
    if reason == "menu" then return end
    local text = summaryText(u, now, reason, true)
    if #text > SUM_MAX then text = summaryText(u, now, reason, false) end
    if #text > SUM_MAX then return end
    enqueueMsg(u.pn, { k = "sum", pri = 0, drive = u.drive, rev = u.rev, veh = u.veh, text = text })
end

local function sendChunk(pn, args)
    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(pn) or nil
    if not player then return false end
    sendClientCommand(player, MDAD.MOD_ID, MDAD.CMD_DIAG_UPLOAD, args)
    return true
end

-- 每幀只做一次時間比較；到期才送一塊（全部本機玩家共用節奏）。
function U.tick()
    local now = nowMs()
    if now < nextSendMs then return end
    local pn, box = nil, nil
    local p = 0
    while p <= 3 do
        local b = outbox[p]
        if b and b.n > 0 then pn, box = p, b; break end
        p = p + 1
    end
    if not box then return end
    local m = box[1]
    local q = m.q + 1
    local data = string.sub(m.text, m.off + 1, m.off + CHUNK)
    local args = { id = m.id, q = q, n = m.total, k = m.k, data = data }
    if q == 1 then
        args.len = #m.text
        args.kind = m.kind
        args.pri = m.pri
        args.trig = m.trig
        args.drive = m.drive
        args.rev = m.rev
        args.veh = m.veh
        args.x = m.x
        args.y = m.y
    end
    local ok, sent = pcall(sendChunk, pn, args)
    if not ok or not sent then
        -- 玩家不在（分割畫面離開）：這位玩家的待送全部作廢，不改掛到別人名下。
        outbox[pn] = nil
        return
    end
    m.q = q
    m.off = m.off + #data
    if m.off >= #m.text then
        box.chars = box.chars - #m.text
        table.remove(box, 1)
        box.n = box.n - 1
    end
    local driving = MDAD and MDAD.Drive and type(MDAD.Drive.isActive) == "function"
        and MDAD.Drive.isActive(pn) and (lastSpeed[pn] or 0) >= DRIVING_KMH
    nextSendMs = now + (driving and SEND_DRIVING_MS or SEND_IDLE_MS)
end

function U.pending(pn)
    local box = outbox[pn]
    return box and box.n or 0
end

-- 回主選單：連線已斷，待送全部作廢（下次進遊戲重新提示）。
function U.reset()
    outbox = {}
    noticed = {}
    lastSpeed = {}
    nextSendMs = 0
end

if Events and Events.OnTick and Events.OnTick.Add then
    Events.OnTick.Add(function() U.tick() end)
end
if Events and Events.OnMainMenuEnter and Events.OnMainMenuEnter.Add then
    Events.OnMainMenuEnter.Add(function() U.reset() end)
end
