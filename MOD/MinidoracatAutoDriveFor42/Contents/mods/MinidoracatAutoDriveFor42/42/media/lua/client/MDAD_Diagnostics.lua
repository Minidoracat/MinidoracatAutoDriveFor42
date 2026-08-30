-- MDAD_Diagnostics.lua
-- Phase 1 opt-in client telemetry ring. Cache and JSONL only; never feeds control.
--
-- File IO (42.20.4, sourced):
--   getFileWriter LuaManager.java:6729-6761; ALLOWED_FILE_EXTENSIONS :1034 (log/txt)
--   getFileReader LuaManager.java:5937-5964 (UTF-8); createIfNull unused here
--   getMyDocumentFolder Core.java:1670-1671 (= ZomboidFileSystem cache dir)
--   getFileSeparator LuaManager.java:5489-5490
--   Clipboard.setClipboard vanilla ISVersionWaterMark.lua:72
-- LuaFileWriter.write/close LuaManager.java:12758-12769. It wraps PrintWriter,
-- whose write errors do not reach Lua; each 60s/stop checkpoint therefore closes
-- the writer and reads back the last JSONL record before reopening append.
-- getTimestampMs LuaManager.java:9268
-- HaloTextHelper.addBadText ISVehiclePartMenu.lua:252
-- HaloTextHelper.addGoodText ISReadABook.lua:95
--
-- Telemetry off: start returns before writer/buffer/Java file IO. hasLatest/copy
-- are explicit user actions that may read old logs; the settings builder never probes.
-- sample periods: 200ms normal / 100ms critical (5Hz/10Hz); events are ungated.
-- D.start returns true only after writer, durable header, and append reopen succeed.

if MDADDiagnostics then return end

local D = {}
MDADDiagnostics = D

local LOG = "[MinidoracatAutoDrive] "
local DIR = "MinidoracatAutoDrive/Telemetry"
local MANIFEST = "MinidoracatAutoDrive/Telemetry/manifest.txt"
local LATEST = "MinidoracatAutoDrive/Telemetry/latest.txt"
local SLOT_N = 64
local SLOT_MAX = 2097152
local BUF_MAX = 64
local BATCH_MS = 1000
local BATCH_B = 8192
local CHECK_MS = 60000
local HZ_N = 200
local HZ_C = 100
local DAY_MS = 86400000
local CRITICAL_ERR_RAD = 1.5707963267949

local sessions = {}
local meta = {}
local ioLogged = false
local lastName = nil

local PK = {
    "valid", "fallback", "scriptName",
    "bodyW", "bodyL", "halfW", "halfL", "mass", "maxSpeed", "wheelbase", "track",
    "clamp0", "clamp30", "clampMax", "wheelFriction",
    "delta0Safe", "deltaVSafe", "rMin", "lookScale",
    "rearArm", "needHalf", "probeR",
}

local function logOnce(msg)
    if ioLogged then return end
    ioLogged = true
    print(LOG .. msg)
end

local function nowMs()
    if type(getTimestampMs) ~= "function" then return 0 end
    local ok, t = pcall(getTimestampMs)
    if ok and type(t) == "number" and t * 0 == 0 then return t end
    return 0
end

local function finite(n)
    return type(n) == "number" and n * 0 == 0
end

local function jnum(n)
    if not finite(n) then return "0" end
    return tostring(n)
end

local function jstr(s)
    if type(s) ~= "string" then s = tostring(s or "") end
    s = string.gsub(s, "\\", "\\\\")
    s = string.gsub(s, "\"", "\\\"")
    s = string.gsub(s, "\r", "\\r")
    s = string.gsub(s, "\n", "\\n")
    s = string.gsub(s, "\t", "\\t")
    s = string.gsub(s, "[%z\1-\31]", function(c)
        local ok, n = pcall(string.byte, c)
        if not ok or type(n) ~= "number" then return "" end
        return string.format("\\u%04x", n)
    end)
    return '"' .. s .. '"'
end

local function slotFile(i)
    if i < 10 then return "session-00" .. i .. ".log" end
    return "session-0" .. i .. ".log"
end

local function slotRel(i)
    return DIR .. "/" .. slotFile(i)
end

local function telemetryOn()
    local hud = MDAD and MDAD.HUD
    if not (hud and type(hud.telemetryEnabled) == "function") then return false end
    local ok, v = pcall(hud.telemetryEnabled)
    return ok and v == true
end

local function retentionDays()
    local hud = MDAD and MDAD.HUD
    if hud and type(hud.telemetryRetentionDays) == "function" then
        local ok, v = pcall(hud.telemetryRetentionDays)
        if ok and (v == 1 or v == 3 or v == 7 or v == 14 or v == 30) then return v end
    end
    return 7
end

local function halo(pn, good, key, fallback)
    if type(getSpecificPlayer) ~= "function" then return end
    local okp, player = pcall(getSpecificPlayer, pn)
    if not okp or not player then return end
    local text = fallback
    if type(getText) == "function" then
        local okt, t = pcall(getText, key)
        if okt and type(t) == "string" and t ~= "" then text = t end
    end
    if good then
        if HaloTextHelper and HaloTextHelper.addGoodText then
            pcall(HaloTextHelper.addGoodText, player, text)
        end
    elseif HaloTextHelper and HaloTextHelper.addBadText then
        pcall(HaloTextHelper.addBadText, player, text)
    end
end

local function absFolder()
    if type(getMyDocumentFolder) ~= "function" or type(getFileSeparator) ~= "function" then
        return nil
    end
    local okd, folder = pcall(getMyDocumentFolder)
    local oks, sep = pcall(getFileSeparator)
    if not (okd and oks and type(folder) == "string" and type(sep) == "string") then
        return nil
    end
    return folder .. sep .. "Lua" .. sep .. "MinidoracatAutoDrive" .. sep .. "Telemetry"
end

local function clip(text)
    if not (Clipboard and Clipboard.setClipboard) then return false end
    local ok = pcall(Clipboard.setClipboard, text)
    return ok == true
end

local function closeWriter(writer)
    if not writer then return end
    pcall(function() writer:close() end)
end

local function openWriter(path, append)
    if type(getFileWriter) ~= "function" then return nil end
    local ok, writer = pcall(getFileWriter, path, true, append == true)
    if ok then return writer end
    return nil
end

local function readLine1(path)
    if type(getFileReader) ~= "function" then return nil end
    local ok, reader = pcall(getFileReader, path, false)
    if not ok or not reader then return nil end
    local line = nil
    pcall(function() line = reader:readLine() end)
    pcall(function() reader:close() end)
    return line
end

local function readLastLine(path)
    if type(getFileReader) ~= "function" then return nil end
    local ok, reader = pcall(getFileReader, path, false)
    if not ok or not reader then return nil end
    local last = nil
    local readOk = pcall(function()
        local line = reader:readLine()
        while line ~= nil do
            last = line
            line = reader:readLine()
        end
    end)
    pcall(function() reader:close() end)
    if not readOk then return nil end
    return last
end

local function writeText(path, text, expectedLast)
    local writer = openWriter(path, false)
    if not writer then return false end
    local ok = pcall(function()
        writer:write(text or "")
        writer:close()
    end)
    if not ok then
        closeWriter(writer)
        return false
    end
    if expectedLast == nil then return readLine1(path) == nil end
    return readLastLine(path) == expectedLast
end

local function truncateSlot(i)
    return writeText(slotRel(i), "")
end

local function ensureMeta()
    if meta[1] then return end
    local i = 1
    while i <= SLOT_N do
        meta[i] = { started = 0, bytes = 0, ended = 0 }
        i = i + 1
    end
end

local function parseHeader(line)
    if type(line) ~= "string" then return nil, nil end
    local slot, ts = string.match(line, '"t":"h","slot":(%d+),"ts":([%d%.]+)')
    slot = tonumber(slot)
    ts = tonumber(ts)
    if not slot or slot < 1 or slot > SLOT_N or not finite(ts) then return nil, nil end
    return slot, ts
end

local function recoverMeta()
    ensureMeta()
    local live = {}
    for _, s in pairs(sessions) do
        if s and s.slot then live[s.slot] = s end
    end
    local i = 1
    while i <= SLOT_N do
        meta[i].started = 0
        meta[i].bytes = 0
        meta[i].ended = 0
        i = i + 1
    end

    local manifestValid = false
    if type(getFileReader) == "function" then
        local ok, reader = pcall(getFileReader, MANIFEST, false)
        if ok and reader then
            local parsedN = 0
            local seen = {}
            local readOk = pcall(function()
                local line = reader:readLine()
                local lineN = 0
                while line ~= nil and lineN < SLOT_N do
                    lineN = lineN + 1
                    local slot, started, bytes, ended = string.match(line,
                        "^(%d+)\t([%-%d%.]+)\t([%-%d%.]+)\t([%-%d%.]+)$")
                    slot = tonumber(slot)
                    started = tonumber(started)
                    bytes = tonumber(bytes)
                    ended = tonumber(ended)
                    if slot and slot >= 1 and slot <= SLOT_N and not seen[slot]
                            and finite(started) and finite(bytes) and finite(ended) then
                        seen[slot] = true
                        parsedN = parsedN + 1
                        meta[slot].started = started
                        meta[slot].bytes = bytes
                        meta[slot].ended = ended
                    end
                    line = reader:readLine()
                end
            end)
            pcall(function() reader:close() end)
            manifestValid = readOk and parsedN == SLOT_N
        end
    end

    i = 1
    while i <= SLOT_N do
        local active = live[i]
        if active then
            meta[i].started = active.started or 0
            meta[i].bytes = active.fileBytes or 0
            meta[i].ended = 0
        elseif manifestValid then
            if meta[i].started > 0 then
                local hslot, ts = parseHeader(readLine1(slotRel(i)))
                if hslot ~= i or ts ~= meta[i].started then
                    meta[i].started = 0
                    meta[i].bytes = 0
                    meta[i].ended = 0
                end
            end
        else
            local hslot, ts = parseHeader(readLine1(slotRel(i)))
            if hslot == i then meta[i].started = ts end
        end
        i = i + 1
    end

    local newest, newestTs = nil, -1
    i = 1
    while i <= SLOT_N do
        local st = meta[i].started or 0
        if st > newestTs then
            newestTs = st
            newest = i
        end
        i = i + 1
    end
    if newest and newestTs > 0 then
        lastName = slotFile(newest)
        if not manifestValid then writeText(LATEST, lastName .. "\n", lastName) end
    else
        lastName = nil
    end
end

local function dumpManifest()
    ensureMeta()
    local parts = {}
    local i = 1
    while i <= SLOT_N do
        local m = meta[i]
        parts[i] = i .. "\t" .. (m.started or 0) .. "\t" .. (m.bytes or 0) .. "\t" .. (m.ended or 0)
        i = i + 1
    end
    return writeText(MANIFEST, table.concat(parts, "\n", 1, SLOT_N) .. "\n",
        parts[SLOT_N])
end

local function liveSlots()
    local live = {}
    for _, s in pairs(sessions) do
        if s and s.slot then live[s.slot] = true end
    end
    return live
end

local function cleanupExpired(now, retainMs)
    ensureMeta()
    local live = liveSlots()
    local i = 1
    while i <= SLOT_N do
        if not live[i] then
            local st = meta[i].started or 0
            if st > 0 and (now < st or (now - st) >= retainMs) then
                truncateSlot(i)
                meta[i].started = 0
                meta[i].bytes = 0
                meta[i].ended = 0
            end
        end
        i = i + 1
    end
end

local function allocSlot(now, retainMs)
    ensureMeta()
    local live = liveSlots()
    local i = 1
    while i <= SLOT_N do
        if not live[i] then
            local st = meta[i].started or 0
            if st <= 0 or now < st or (now - st) >= retainMs then
                if st > 0 then
                    truncateSlot(i)
                    meta[i].started = 0
                    meta[i].bytes = 0
                    meta[i].ended = 0
                end
                return i
            end
        end
        i = i + 1
    end
    return nil
end

local function failIo(s, msg)
    logOnce(msg or "diagnostics IO failed")
    if not s then return end
    s.active = false
    closeWriter(s.writer)
    s.writer = nil
    s.buf = nil
    s.bufN = 0
    s.bufBytes = 0
    halo(s.pn, false, "UI_MinidoracatAutoDrive_TelemetryWriteFailed",
        "diagnostic logging stopped")
    if s.pn ~= nil then sessions[s.pn] = nil end
end

local function flush(s, now)
    if not s or not s.writer or s.bufN < 1 then return true end
    local chunk = table.concat(s.buf, "\n", 1, s.bufN) .. "\n"
    local ok = pcall(function() s.writer:write(chunk) end)
    if not ok then
        failIo(s, "diagnostics IO failed")
        return false
    end
    s.fileBytes = s.fileBytes + #chunk
    s.bufN = 0
    s.bufBytes = 0
    s.lastFlush = now
    if s.slot and meta[s.slot] then meta[s.slot].bytes = s.fileBytes end
    return true
end

local function checkpoint(s, now)
    if not flush(s, now) then return false end
    closeWriter(s.writer)
    s.writer = nil
    if s.lastLine and readLastLine(s.path) ~= s.lastLine then
        failIo(s, "diagnostics durability check failed")
        return false
    end
    s.writer = openWriter(s.path, true)
    if not s.writer then
        failIo(s, "diagnostics IO failed")
        return false
    end
    s.lastCheck = now
    return true
end

local function stopFull(s, now, reason)
    s.active = false
    local line = '{"t":"x","ts":' .. jnum(now) .. ',"r":' .. jstr(reason or "size") .. '}'
    if s.writer and s.fileBytes + #line + 1 <= SLOT_MAX then
        s.bufN = s.bufN + 1
        s.buf[s.bufN] = line
        s.bufBytes = s.bufBytes + #line + 1
        s.lastLine = line
    end
    local flushed = flush(s, now)
    closeWriter(s.writer)
    s.writer = nil
    local durable = flushed and (not s.lastLine or readLastLine(s.path) == s.lastLine)
    s.buf = nil
    if s.slot and meta[s.slot] then
        meta[s.slot].ended = now
        meta[s.slot].bytes = s.fileBytes
        dumpManifest()
    end
    if s.pn ~= nil then sessions[s.pn] = nil end
    if durable then
        halo(s.pn, false, "UI_MinidoracatAutoDrive_TelemetryFileFull",
            "diagnostic log reached 2 MiB")
    elseif flushed then
        logOnce("diagnostics durability check failed")
        halo(s.pn, false, "UI_MinidoracatAutoDrive_TelemetryWriteFailed",
            "diagnostic logging stopped")
    end
end

local function enqueue(s, line, now)
    if not s or not s.active or not s.writer then return end
    local n = #line
    if s.fileBytes + s.bufBytes + n + 1 > SLOT_MAX then
        if not flush(s, now) then return end
        if s.fileBytes + n + 1 > SLOT_MAX then
            stopFull(s, now, "size")
            return
        end
    end
    s.bufN = s.bufN + 1
    s.buf[s.bufN] = line
    s.bufBytes = s.bufBytes + n + 1
    s.lastLine = line
    if s.bufN >= BUF_MAX or s.bufBytes >= BATCH_B then
        flush(s, now)
    elseif now - s.lastFlush >= BATCH_MS then
        flush(s, now)
    end
    if s.active and now - s.lastCheck >= CHECK_MS then
        checkpoint(s, now)
    end
end

local function encodeProfile(profile)
    local parts = {}
    local n = 0
    local i = 1
    while i <= #PK do
        local k = PK[i]
        local v = profile[k]
        i = i + 1
        local chunk = nil
        if k == "scriptName" then
            if type(v) == "string" then chunk = '"' .. k .. '":' .. jstr(v) end
        elseif k == "valid" or k == "fallback" then
            chunk = '"' .. k .. '":' .. (v == true and "true" or "false")
        elseif finite(v) then
            chunk = '"' .. k .. '":' .. tostring(v)
        end
        if chunk then
            n = n + 1
            parts[n] = chunk
        end
    end
    return "{" .. table.concat(parts, ",", 1, n) .. "}"
end

local function encodeNear(sensor)
    local n = sensor.hardN
    local hs, hl = sensor.hardS, sensor.hardL
    if not finite(n) or n < 1 or type(hs) ~= "table" or type(hl) ~= "table" then
        return ""
    end
    local scan = finite(sensor.scanS) and sensor.scanS or 0
    local ns, nl, nd = {}, {}, {}
    local count = 0
    local i = 1
    local lim = n
    if lim > 768 then lim = 768 end
    while i <= lim do
        local s = hs[i]
        local l = hl[i]
        i = i + 1
        if finite(s) and finite(l) then
            local ds = s - scan
            local d = ds * ds + l * l
            local j
            if count < 8 then
                count = count + 1
                j = count
            elseif d < nd[8] then
                j = 8
            end
            if j then
                while j > 1 and d < nd[j - 1] do
                    nd[j] = nd[j - 1]
                    ns[j] = ns[j - 1]
                    nl[j] = nl[j - 1]
                    j = j - 1
                end
                nd[j] = d
                ns[j] = ds
                nl[j] = l
            end
        end
    end
    if count < 1 then return "" end
    local parts = {}
    i = 1
    while i <= count do
        parts[i] = '{"s":' .. tostring(ns[i]) .. ',"l":' .. tostring(nl[i]) .. '}'
        i = i + 1
    end
    return ',"near":[' .. table.concat(parts, ",", 1, count) .. ']'
end

local function encodeSensor(s, sensor)
    local stamp = sensor.stamp
    local near = ""
    if stamp ~= s.lastStamp then
        s.lastStamp = stamp
        near = encodeNear(sensor)
    end
    local mv = sensor.movingVeh == true
    local ul = sensor.unloaded == true
    local rd = sensor.ready == true
    local bits = '{"hardN":' .. jnum(sensor.hardN)
        .. ',"softN":' .. jnum(sensor.softN)
        .. ',"zombieN":' .. jnum(sensor.zombieN)
        .. ',"corpseN":' .. jnum(sensor.corpseN)
        .. ',"vehN":' .. jnum(sensor.vehN)
        .. ',"movingVeh":' .. (mv and "true" or "false")
        .. ',"unloaded":' .. (ul and "true" or "false")
        .. ',"ready":' .. (rd and "true" or "false")
        .. ',"sig":' .. jnum(sensor.sig)
        .. ',"stamp":' .. jnum(stamp)
        .. ',"roadN":' .. jnum(sensor.roadN)
    if finite(sensor.roadC) then
        bits = bits .. ',"roadC":' .. tostring(sensor.roadC)
    end
    return bits .. near .. "}"
end

local function isCritical(mode, err)
    if finite(err) then
        local a = err
        if a < 0 then a = -a end
        if a >= CRITICAL_ERR_RAD then return true end
    end
    if type(mode) == "string" then
        return mode == "blocked" or mode == "dodging" or mode == "offroad"
            or mode == "unstick"
    end
    if type(mode) == "table" then
        return mode.blocked == true or mode.dodging == true or mode.offroad == true
    end
    return false
end

local function encodeHeader(slot, now, days, profile)
    local b = MDAD and MDAD.BUILD
    if type(b) ~= "string" then b = "" end
    local pjson = "null"
    if type(profile) == "table" then pjson = encodeProfile(profile) end
    return '{"v":1,"t":"h","slot":' .. slot .. ',"ts":' .. jnum(now)
        .. ',"ret":' .. days .. ',"build":' .. jstr(b) .. ',"profile":' .. pjson .. '}'
end

local function encodeSample(s, now, x, y, heading, speed, target, remaining, lat, err, steer, force, mode, gear, regulator, sensor)
    local mjson = "null"
    if type(mode) == "string" then
        mjson = jstr(mode)
    elseif type(mode) == "number" and finite(mode) then
        mjson = tostring(mode)
    end
    local extra = ""
    if type(sensor) == "table" then
        extra = ',"sen":' .. encodeSensor(s, sensor)
    end
    return '{"t":"s","ts":' .. jnum(now)
        .. ',"x":' .. jnum(x)
        .. ',"y":' .. jnum(y)
        .. ',"h":' .. jnum(heading)
        .. ',"spd":' .. jnum(speed)
        .. ',"tgt":' .. jnum(target)
        .. ',"rem":' .. jnum(remaining)
        .. ',"lat":' .. jnum(lat)
        .. ',"err":' .. jnum(err)
        .. ',"st":' .. jnum(steer)
        .. ',"f":' .. jnum(force)
        .. ',"m":' .. mjson
        .. ',"g":' .. jnum(gear)
        .. ',"reg":' .. (regulator == true and "true" or "false")
        .. extra .. '}'
end

local function encodeEvent(now, name, a, b, c, d)
    local line = '{"t":"e","ts":' .. jnum(now) .. ',"n":' .. jstr(tostring(name or ""))
    local function add(k, v)
        if v == nil then return end
        local tv = type(v)
        if tv == "number" then
            if finite(v) then line = line .. ',"' .. k .. '":' .. tostring(v) end
        elseif tv == "boolean" then
            line = line .. ',"' .. k .. '":' .. (v and "true" or "false")
        elseif tv == "string" then
            line = line .. ',"' .. k .. '":' .. jstr(v)
        end
    end
    add("a", a)
    add("b", b)
    add("c", c)
    add("d", d)
    return line .. "}"
end

local function readPointer()
    if type(lastName) == "string"
            and string.match(lastName, "^session%-%d%d%d%.log$") then
        return lastName
    end
    local line = readLine1(LATEST)
    if type(line) ~= "string" then return nil end
    line = string.match(line, "^%s*(.-)%s*$") or line
    if string.match(line, "^session%-%d%d%d%.log$") then return line end
    return nil
end

function D.start(pn, vehicle, profile)
    if sessions[pn] then D.stop(pn, "restart") end
    if not telemetryOn() then return false end
    local now = nowMs()
    local days = retentionDays()
    local retainMs = days * DAY_MS
    recoverMeta()
    cleanupExpired(now, retainMs)
    local slot = allocSlot(now, retainMs)
    if not slot then
        print(LOG .. "diagnostics slots full; session not recorded")
        halo(pn, false, "UI_MinidoracatAutoDrive_TelemetrySlotsFull", "telemetry slots full")
        dumpManifest()
        return false
    end
    local path = slotRel(slot)
    local writer = openWriter(path, false)
    if not writer then
        logOnce("diagnostics IO failed")
        halo(pn, false, "UI_MinidoracatAutoDrive_TelemetryWriteFailed",
            "diagnostic logging stopped")
        return false
    end
    local s = {
        active = true,
        pn = pn,
        slot = slot,
        path = path,
        writer = writer,
        buf = {},
        bufN = 0,
        bufBytes = 0,
        fileBytes = 0,
        lastFlush = now,
        lastCheck = now,
        lastNow = now,
        lastSample = nil,
        lastStamp = nil,
        lastLine = nil,
        started = now,
    }
    sessions[pn] = s
    local startOk, ready = pcall(function()
        enqueue(s, encodeHeader(slot, now, days, profile), now)
        return checkpoint(s, now)
    end)
    if not startOk then failIo(s, "diagnostics encoding failed") end
    if not startOk or ready ~= true or not s.active then
        truncateSlot(slot)
        return false
    end
    meta[slot].started = now
    meta[slot].bytes = s.fileBytes
    meta[slot].ended = 0
    if not dumpManifest() then
        meta[slot].started, meta[slot].bytes, meta[slot].ended = 0, 0, 0
        failIo(s, "diagnostics manifest write failed")
        truncateSlot(slot)
        return false
    end
    lastName = slotFile(slot)
    if not writeText(LATEST, lastName .. "\n", lastName) then
        logOnce("diagnostics latest-pointer write failed")
    end
    return true
end

function D.sample(pn, now, x, y, heading, speed, target, remaining, lat, err, steer, force, mode, gear, regulator, sensor, critical)
    local s = sessions[pn]
    if not s or not s.active then return false end
    if not finite(now) then return true end
    local gap = HZ_N
    if critical == true or isCritical(mode, err) then gap = HZ_C end
    if s.lastSample ~= nil and now >= s.lastNow
            and now - s.lastSample < gap then
        return true
    end
    s.lastNow = now
    s.lastSample = now
    enqueue(s, encodeSample(s, now, x, y, heading, speed, target, remaining, lat, err, steer, force, mode, gear, regulator, sensor), now)
    return s.active == true
end

function D.event(pn, name, a, b, c, d)
    local s = sessions[pn]
    if not s or not s.active then return end
    local now = nowMs()
    enqueue(s, encodeEvent(now, name, a, b, c, d), now)
end

function D.stop(pn, reason)
    local s = sessions[pn]
    if not s then return end
    local now = nowMs()
    if s.active and s.writer then
        local ok = pcall(function()
            enqueue(s, '{"t":"x","ts":' .. jnum(now) .. ',"r":'
                .. jstr(tostring(reason or "stop")) .. '}', now)
            if s.active and s.writer then checkpoint(s, now) end
        end)
        if not ok then failIo(s, "diagnostics encoding failed") end
        closeWriter(s.writer)
    end
    if s.slot and meta[s.slot] then
        meta[s.slot].ended = now
        meta[s.slot].bytes = s.fileBytes or 0
        dumpManifest()
    end
    s.active = false
    s.writer = nil
    s.buf = nil
    sessions[pn] = nil
end

function D.hasLatest()
    local name = readPointer()
    if type(name) ~= "string" or name == "" then return false end
    local line = readLine1(DIR .. "/" .. name)
    return type(line) == "string" and line ~= ""
end

function D.copyLatestPath(pn)
    local name = readPointer()
    if type(name) ~= "string" or name == "" then
        halo(pn, false, "UI_MinidoracatAutoDrive_TelemetryNoFile", "no diagnostic log yet")
        return false
    end
    local folder = absFolder()
    if not folder then
        halo(pn, false, "UI_MinidoracatAutoDrive_TelemetryCopyFailed", "copy failed")
        return false
    end
    local line = readLine1(DIR .. "/" .. name)
    if type(line) ~= "string" or line == "" then
        halo(pn, false, "UI_MinidoracatAutoDrive_TelemetryNoFile", "no diagnostic log yet")
        return false
    end
    local sep
    local oks, s = pcall(getFileSeparator)
    if oks then sep = s end
    if type(sep) ~= "string" then
        halo(pn, false, "UI_MinidoracatAutoDrive_TelemetryCopyFailed", "copy failed")
        return false
    end
    local path = folder .. sep .. name
    if clip(path) then
        halo(pn, true, "UI_MinidoracatAutoDrive_TelemetryCopied", "copied")
        return true
    end
    halo(pn, false, "UI_MinidoracatAutoDrive_TelemetryCopyFailed", "copy failed")
    return false
end

function D.copyFolderPath(pn)
    local folder = absFolder()
    if not folder then
        halo(pn, false, "UI_MinidoracatAutoDrive_TelemetryCopyFailed", "copy failed")
        return false
    end
    if clip(folder) then
        halo(pn, true, "UI_MinidoracatAutoDrive_TelemetryCopied", "copied")
        return true
    end
    halo(pn, false, "UI_MinidoracatAutoDrive_TelemetryCopyFailed", "copy failed")
    return false
end

local function onMainMenuEnter()
    for pn = 0, 3 do
        if sessions[pn] then pcall(D.stop, pn, "menu") end
    end
end
if Events and Events.OnMainMenuEnter and Events.OnMainMenuEnter.Add then
    Events.OnMainMenuEnter.Add(onMainMenuEnter)
end
