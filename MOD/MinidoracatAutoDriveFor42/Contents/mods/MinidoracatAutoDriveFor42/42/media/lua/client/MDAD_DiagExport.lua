-- MDAD_DiagExport.lua
-- 匯出診斷（1010）：玩家按一個鈕（ESC MOD 選項／MiniMap 齒輪「自動駕駛」分類），把「環境資訊＋最近幾趟
-- telemetry」合成單一 .txt，Toast／Halo 告知路徑並複製到剪貼簿。只有截圖的回報定不了罪（10-09 拖車回報
-- 分析 47 分鐘、跑 9 輪仍缺車型／MOD 清單／選項），這個檔讓玩家附一個檔就夠。
--
-- 檔案：<cache>/Lua/MinidoracatAutoDrive/Export/diag-export.txt。getFileWriter 只收 ini/cfg/txt/log/json、
-- 路徑禁 ..、目錄自動 mkdirs（LuaManager.java:1035、6727-6763，42.21）。
-- ponytail: 每次匯出覆寫同一檔（沒有刪檔 API，不累積磁碟）；要保留多份再改成固定槽輪替。
-- 大檔分 tick：OnTickEvenPaused（單機暫停／ESC 也照跑，GameWindow.java:354-367）每 tick 最多搬 E.TICK_BYTES，
-- 寫完再分 tick 回讀「行數＋末行」驗證落盤——PrintWriter 吞錯（pz-family-docs/pitfalls.md「getFileWriter
-- 寫檔失敗不會報錯」），只看 write 沒丟錯會把空檔當成功。
-- ExportTelemetry 關著照樣匯出環境段（＋還留著的舊紀錄），另一則 Toast 提示開啟後重現。
-- 環境段的 header 行與 telemetry header 同源：MDADDiagnostics.envStamp／encodeProfile（game／mode／mods／opts／profile）。

if MDADDiagExport then return end

local E = {}
MDADDiagExport = E

E.DIR = "MinidoracatAutoDrive/Export"
E.FILE = "diag-export.txt"
E.TELEMETRY = "MinidoracatAutoDrive/Telemetry"
E.DRIVES = 3            -- 最近幾趟（index 的 drive 欄；一趟可跨多個 part 檔）
E.MAX_BYTES = 8388608   -- 紀錄內容總上限：超過就不再往更舊的那趟加（至少收最新一趟）
E.TICK_BYTES = 65536    -- 每 tick 最多搬／回讀的字元數
E.END = "== end of MDAD diagnostic export =="

local job = nil

local function try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

local function jstr(s)
    s = string.gsub(tostring(s or ""), "\\", "\\\\")
    s = string.gsub(s, "\"", "\\\"")
    return "\"" .. string.gsub(s, "%c", " ") .. "\""
end

local function notify(pn, good, key, arg)
    local ok, text
    if arg ~= nil then ok, text = pcall(getText, key, arg) else ok, text = pcall(getText, key) end
    if not ok or type(text) ~= "string" then text = key end
    local okp, player = pcall(getSpecificPlayer, pn)
    local halo = HaloTextHelper and (good and HaloTextHelper.addGoodText or HaloTextHelper.addBadText)
    if okp and player and halo then pcall(halo, player, text) end
    local diag = MDADDiagnostics
    if diag and type(diag.toast) == "function" then pcall(diag.toast, text, good and "good" or "bad") end
end

local function absPath()
    local folder = try(getMyDocumentFolder)
    local sep = try(getFileSeparator)
    if type(folder) ~= "string" or type(sep) ~= "string" then return "Zomboid/Lua/" .. E.DIR .. "/" .. E.FILE end
    return folder .. sep .. "Lua" .. sep .. "MinidoracatAutoDrive" .. sep .. "Export" .. sep .. E.FILE
end

local function openReader(path)
    if type(getFileReader) ~= "function" then return nil end
    local ok, reader = pcall(getFileReader, path, false)
    if ok then return reader end
    return nil
end

local function closeHandle(h)
    if h then pcall(function() h:close() end) end
end

-- 讀整個小檔（index／latest，≤64 列）成行陣列；讀不到回 nil。
local function readSmall(path)
    local reader = openReader(path)
    if not reader then return nil end
    local lines, n = {}, 0
    pcall(function()
        local line = reader:readLine()
        while line ~= nil and n < 256 do
            n = n + 1
            lines[n] = line
            line = reader:readLine()
        end
    end)
    closeHandle(reader)
    return lines
end

-- session-index.txt（8 欄 TSV：slot startTs endTs bytes reason file drive part）→ 最近 E.DRIVES 趟的檔，
-- 由舊到新、同一趟依 part。檔名只收 session-NNN.log（index 是磁碟內容，不信任它拼路徑）。
-- 回 { {file, drive, part, bytes, reason}, ... }；沒有 index 退回 latest.txt 那一檔。
function E.pickFiles(indexLines)
    local rows, n = {}, 0
    for i = 1, #(indexLines or {}) do
        local _, st, _, bytes, reason, file, drive, part = string.match(indexLines[i],
            "^(%d+)\t(%d+)\t(%d+)\t(%d+)\t([^\t]*)\t([^\t]+)\t(%d+)\t(%d+)")
        if file and string.match(file, "^session%-%d%d%d%.log$") then
            n = n + 1
            rows[n] = { file = file, drive = tonumber(drive), part = tonumber(part), bytes = tonumber(bytes),
                reason = reason, st = tonumber(st) }
        end
    end
    local groups, total, chosen = {}, 0, {}
    for _ = 1, E.DRIVES do
        local best = nil
        for i = 1, n do
            local d = rows[i].drive
            if not chosen[d] and (best == nil or d > best) then best = d end
        end
        if best == nil then break end
        chosen[best] = true
        -- 收這一趟實際存在的列，再依 part 選擇式排序（part 是續檔序號、沒有上限；index 最多 64 列；Kahlua 禁 table.sort）
        local bytes, parts, m = 0, {}, 0
        for i = 1, n do
            if rows[i].drive == best then
                m = m + 1
                parts[m] = rows[i]
                bytes = bytes + rows[i].bytes
            end
        end
        for a = 1, m - 1 do
            local k = a
            for b = a + 1, m do
                if parts[b].part < parts[k].part then k = b end
            end
            parts[a], parts[k] = parts[k], parts[a]
        end
        if #groups > 0 and total + bytes > E.MAX_BYTES then break end
        total = total + bytes
        groups[#groups + 1] = parts
    end
    local files = {}
    for g = #groups, 1, -1 do
        for i = 1, #groups[g] do files[#files + 1] = groups[g][i] end
    end
    if #files == 0 and n == 0 then
        local latest = readSmall(E.TELEMETRY .. "/latest.txt")
        local name = latest and latest[1] and string.match(latest[1], "^%s*(session%-%d%d%d%.log)%s*$")
        if name then files[1] = { file = name } end
    end
    return files
end

-- 環境段：回行陣列。每項各自 pcall，失敗只少那一行，不擋住匯出。
function E.envLines(pn, now, files, indexLines)
    local out = {}
    local function add(s) out[#out + 1] = (string.gsub(s, "[\r\n]", " ")) end
    local hud, drive = MDAD and MDAD.HUD, MDAD and MDAD.Drive
    local rev, build = drive and drive.REV or "", MDAD and MDAD.BUILD or ""
    add("== MDAD diagnostic export v1 ==")
    add("exportedTs: " .. tostring(now))
    add("rev: " .. tostring(rev))
    add("build: " .. tostring(build))
    add("game: " .. tostring(try(function() return getCore():getVersion() end)))
    add("mode: " .. (try(isClient) and "mp" or "sp"))
    local vehicle = try(function() return getSpecificPlayer(pn):getVehicle() end)
    local profile = vehicle and MDADVehicleProfile and try(MDADVehicleProfile.build, vehicle) or nil
    local diag = MDADDiagnostics
    local stamp = diag and try(diag.envStamp, pn)
    local pjson = type(profile) == "table" and diag and try(diag.encodeProfile, profile) or "null"
    -- 與 telemetry header 同欄位（t=env 取代 h；analyze_telemetry 以外的讀者照 header 字典讀）
    add('header: {"v":1,"t":"env","ts":' .. tostring(now) .. ',"build":' .. jstr(build) .. ',"rev":' .. jstr(rev)
        .. (type(stamp) == "string" and stamp or "") .. ',"profile":' .. tostring(pjson) .. '}')
    add("map: " .. tostring(try(function() return getWorld():getMap() end)))
    local lots = try(function()
        local list, parts = getLotDirectories(), {}
        for i = 0, list:size() - 1 do parts[#parts + 1] = tostring(list:get(i)) end
        return table.concat(parts, ";")
    end)
    add("lots: " .. tostring(lots))
    add("telemetry: ExportTelemetry=" .. tostring(hud and try(hud.telemetryEnabled))
        .. " ShareDiagnostics=" .. tostring(hud and try(hud.shareDiagnostics))
        .. " upload=" .. tostring(MDADUpload and try(MDADUpload.enabled))
        .. " retentionDays=" .. tostring(hud and try(hud.telemetryRetentionDays)))
    if vehicle then
        local towing = try(function() return vehicle:getVehicleTowing() end)
        add("vehicle: " .. tostring(try(function() return vehicle:getScriptName() end))
            .. " towing=" .. tostring(towing and try(function() return towing:getScriptName() end) or "-")
            .. " autodrive=" .. tostring(drive and try(drive.isActive, pn)))
        if type(profile) == "table" then
            add("profile: valid=" .. tostring(profile.valid) .. " fallback=" .. tostring(profile.fallback)
                .. " geometryValid=" .. tostring(profile.geometryValid) .. " script=" .. tostring(profile.scriptName))
        end
    else
        add("vehicle: none (not in a vehicle)")
    end
    add("-- options --")
    local opts = try(function() return PZAPI.ModOptions:getOptions("MinidoracatAutoDrive").dict end)
    if type(opts) == "table" then
        for id, option in pairs(opts) do
            local v = type(option) == "table" and try(option.getValue, option)
            if v ~= nil then add(tostring(id) .. "=" .. tostring(v)) end
        end
    end
    add("-- sandbox --")
    local sv = try(function() return SandboxVars.MinidoracatAutoDrive end)
    if type(sv) == "table" then
        for k, v in pairs(sv) do add(tostring(k) .. "=" .. tostring(v)) end
    end
    add("-- session-index.txt --")
    for i = 1, #(indexLines or {}) do add(indexLines[i]) end
    add("-- files: " .. #files .. " --")
    return out
end

local function put(j, lines, n)
    if n < 1 then return end
    j.writer:write(table.concat(lines, "\n", 1, n) .. "\n")
    j.written = j.written + n
end

local function finish(j, ok)
    job = nil
    closeHandle(j.reader)
    closeHandle(j.writer)
    j.reader, j.writer = nil, nil
    if not ok then
        notify(j.pn, false, "UI_MinidoracatAutoDrive_ExportDiagFailed")
        return
    end
    local path = absPath()
    if Clipboard and Clipboard.setClipboard then pcall(Clipboard.setClipboard, path) end
    notify(j.pn, true, "UI_MinidoracatAutoDrive_ExportDiagDone", path)
    if not j.telemetry then notify(j.pn, false, "UI_MinidoracatAutoDrive_ExportDiagTelemetryOff") end
end

-- 一個 tick 的工作：copy 階段搬一段紀錄（或開下一檔）；verify 階段回讀一段。回 false＝失敗。
local function step(j)
    local buf, n, size = {}, 0, 0
    if j.phase == "copy" then
        if not j.reader then
            j.fi = j.fi + 1
            local f = j.files[j.fi]
            if not f then
                put(j, { E.END }, 1)
                closeHandle(j.writer)
                j.writer = nil
                j.reader = openReader(E.DIR .. "/" .. E.FILE)
                if not j.reader then return false end
                j.phase, j.read, j.last = "verify", 0, nil
                return true
            end
            j.reader = openReader(E.TELEMETRY .. "/" .. f.file)
            if not j.reader then
                put(j, { "== file " .. f.file .. " unreadable ==" }, 1)
                return true
            end
            n = 1
            buf[1] = "== file " .. f.file .. " drive=" .. tostring(f.drive) .. " part=" .. tostring(f.part)
                .. " bytes=" .. tostring(f.bytes) .. " reason=" .. tostring(f.reason) .. " =="
        end
        while size < E.TICK_BYTES do
            local line = j.reader:readLine()
            if line == nil then
                closeHandle(j.reader)
                j.reader = nil
                n = n + 1
                buf[n] = "== end file =="
                break
            end
            n = n + 1
            buf[n] = line
            size = size + #line + 1
        end
        put(j, buf, n)
        return true
    end
    while size < E.TICK_BYTES do
        local line = j.reader:readLine()
        if line == nil then
            closeHandle(j.reader)
            j.reader = nil
            finish(j, j.read == j.written and j.last == E.END)
            return true
        end
        j.read = j.read + 1
        j.last = line
        size = size + #line + 1
    end
    return true
end

function E.pump()
    local j = job
    if not j then return end
    local ok, res = pcall(step, j)
    if (not ok or res == false) and job == j then finish(j, false) end
end

function E.busy()
    return job ~= nil
end

-- 回 true＝已開始（結果之後由 Toast／Halo 告知）。同時只跑一份。
function E.start(pn)
    pn = pn or 0
    if job then
        notify(pn, false, "UI_MinidoracatAutoDrive_ExportDiagBusy")
        return false
    end
    local writer = nil
    if type(getFileWriter) == "function" then
        local ok, w = pcall(getFileWriter, E.DIR .. "/" .. E.FILE, true, false)
        if ok then writer = w end
    end
    if not writer then
        notify(pn, false, "UI_MinidoracatAutoDrive_ExportDiagFailed")
        return false
    end
    local indexLines = readSmall(E.TELEMETRY .. "/session-index.txt") or {}
    local files = E.pickFiles(indexLines)
    local hud = MDAD and MDAD.HUD
    local j = { pn = pn, writer = writer, files = files, fi = 0, written = 0, phase = "copy",
        telemetry = hud and try(hud.telemetryEnabled) == true }
    local okEnv, lines = pcall(E.envLines, pn, try(getTimestampMs) or 0, files, indexLines)
    if not okEnv or not pcall(put, j, lines, #lines) then
        closeHandle(writer)
        notify(pn, false, "UI_MinidoracatAutoDrive_ExportDiagFailed")
        return false
    end
    job = j
    notify(pn, true, "UI_MinidoracatAutoDrive_ExportDiagStarted")
    return true
end

local function abort()
    local j = job
    if not j then return end
    job = nil
    closeHandle(j.reader)
    closeHandle(j.writer)
end

if Events then
    if Events.OnTickEvenPaused then Events.OnTickEvenPaused.Add(E.pump) end
    if Events.OnMainMenuEnter then Events.OnMainMenuEnter.Add(abort) end
end
