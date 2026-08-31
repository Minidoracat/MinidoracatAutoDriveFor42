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
--   MinidoracatUI/Widgets/Toast.lua Toast.show（家族框架共享堆疊；NBToast 同款）
--
-- Telemetry off: start returns before writer/buffer/Java file IO. hasLatest/copy
-- are explicit user actions that may read old logs; the settings builder never probes.
-- sample periods: 200ms normal / 100ms critical (5Hz/10Hz); events are ungated.
-- D.start returns true only after writer, durable header, and append reopen succeed.
--
-- 三個管理檔（都在 Telemetry 資料夾內，都不含玩家身分）：
--   manifest.txt      機器復原狀態，定長 64 列 4 欄（slot/started/bytes/ended）
--   latest.txt        最新 session 檔名指標（複製最新檔用）
--   session-index.txt 人可讀的段落索引，只列 occupied 槽、最多 64 列，欄位
--                     slot／startTs／endTs／bytes／reason／file；raw epoch ms、
--                     不含時區。start committed 寫 active、正常停止／寫滿／回主
--                     選單／錯誤更新 endTs+bytes+reason，retention 清除即消失。
--                     index 寫失敗只 print 一行，已 durable 的 session data 不受影響。

if MDADDiagnostics then return end

local D = {}
MDADDiagnostics = D

local LOG = "[MinidoracatAutoDrive] "
local DIR = "MinidoracatAutoDrive/Telemetry"
local MANIFEST = "MinidoracatAutoDrive/Telemetry/manifest.txt"
local LATEST = "MinidoracatAutoDrive/Telemetry/latest.txt"
-- 人可讀的段落索引（第三個管理檔）：一段自駕一列，raw epoch ms、不含時區。
-- manifest 是機器復原狀態（4 欄定長 64 列，格式不動）；單檔 JSONL 自己已有 ts，
-- index 的價值是不用打開大型檔就能查「哪個檔是哪一段、何時起迄、為何結束」。
-- 只列 occupied 槽，最多 64 列。
local INDEX = "MinidoracatAutoDrive/Telemetry/session-index.txt"
local REASON_MAX = 48
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
local ioLogged = {}
local indexLogged = false
local lastName = nil

local PK = {
    "valid", "fallback", "geometryValid", "scriptName",
    "bodyW", "bodyL", "halfW", "halfL",
    "centerOfMassX", "centerOfMassY", "centerOfMassZ",
    "mass", "maxSpeed", "wheelbase", "track",
    "clamp0", "clamp30", "clampMax", "wheelFriction",
    "delta0Safe", "deltaVSafe", "rMin", "lookScale",
    "rearArm", "needHalf", "probeR",
    "enginePower", "brakingForce", "offroadEfficiency", "rollInfluence",
    "tireFrictionMin", "tireFrictionAvg", "tireFrictionCount",
    "isAnyTireMissing",
}
-- Named event tables are intentionally closed-schema and emitted in this order.
-- Transition paths may allocate one table; telemetry samples never do.
local EK = {
    "phase", "oldX", "oldY", "x", "y", "why", "tg", "rg", "len", "pts", "target",
    "eid", "attempt", "s", "l", "d", "dt", "wd", "ds", "dyaw", "hit", "gear",
    "progress", "duration", "speed", "rear", "kind", "detail", "poseOnly",
    "navVersion", "currentSurface", "currentSegWidth", "cost", "avoidPenalty",
}

local function logOnce(msg)
    if ioLogged[msg] then return end
    ioLogged[msg] = true
    print(LOG .. msg)
end

-- index 的失敗獨立一支 one-shot：它只是索引，寫不進去不代表 session data 有事，
-- 也不應與 session／manifest 的不同 I/O 故障互相抑制。
local function logIndexOnce(msg)
    if indexLogged then return end
    indexLogged = true
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

-- index 是 TSV：reason 進去前必須沒有 tab/換行，否則整列欄位錯位、外部工具讀爆。
-- reason 的真實來源含翻譯鍵（Drive.stop 傳 UI_MinidoracatAutoDrive_Stuck 這類），
-- 所以不是白名單枚舉，而是「非 [%w-._] 一律換成 -」＋長度上限。
local function safeReason(r)
    if type(r) ~= "string" then r = tostring(r or "") end
    r = string.gsub(r, "[^%w%-%._]", "-")
    if #r > REASON_MAX then r = string.sub(r, 1, REASON_MAX) end
    if r == "" then return "unknown" end
    return r
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

local function localized(key, fallback)
    if type(getText) == "function" then
        local okt, t = pcall(getText, key)
        if okt and type(t) == "string" and t ~= "" then return t end
    end
    return fallback
end

local function halo(pn, good, key, fallback)
    if type(getSpecificPlayer) ~= "function" then return end
    local okp, player = pcall(getSpecificPlayer, pn)
    if not okp or not player then return end
    local text = localized(key, fallback)
    if good then
        if HaloTextHelper and HaloTextHelper.addGoodText then
            pcall(HaloTextHelper.addGoodText, player, text)
        end
    elseif HaloTextHelper and HaloTextHelper.addBadText then
        pcall(HaloTextHelper.addBadText, player, text)
    end
end

-- 家族 UI 框架的共享 Toast（MinidoracatUI/Widgets/Toast，NoticeBoard NBToast 同款）：
-- 堆疊是框架單例，多個家族 MOD 同時通知不互相蓋字。複製路徑是「玩家按了按鈕」的
-- 明確動作，Halo 在車內視角常被儀表與遮罩吃掉，右上 Toast 才看得到。
-- 【退回】能力缺席（舊框架／widget 沒掛上）或 show 回 nil／丟錯時退回原本的 good Halo，
-- 不自帶第二套通知實作。require 只嘗試一次（失敗是安裝問題，重試沒有新資訊）。
local toastRequired = false
local function frameworkToast()
    local ui = MinidoracatUI and MinidoracatUI.v1
    if not (ui and ui.Toast) and not toastRequired then
        toastRequired = true
        if type(require) == "function" then
            pcall(require, "MinidoracatUI/Widgets/Toast")
        end
        ui = MinidoracatUI and MinidoracatUI.v1
    end
    if ui and ui.API_MAJOR == 1 and ui.CAPABILITIES and ui.CAPABILITIES.toast == true
            and type(ui.Toast) == "table" and type(ui.Toast.show) == "function" then
        return ui.Toast
    end
    return nil
end

-- 複製成功的唯一回饋出口（最新檔與資料夾共用）。Toast.show 回 nil 可能是 pending
-- 或佇列滿丟棄；為了保證按鈕一定有立即回饋，nil／throw 都退 good Halo。
local function copiedNotice(pn)
    local fw = frameworkToast()
    if fw then
        local ok, shown = pcall(fw.show, {
            title = localized("UI_MinidoracatAutoDrive_Options", "AutoDrive"),
            message = localized("UI_MinidoracatAutoDrive_TelemetryCopied", "copied"),
        })
        if ok and shown ~= nil then return end
    end
    halo(pn, true, "UI_MinidoracatAutoDrive_TelemetryCopied", "copied")
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
        meta[i] = { started = 0, bytes = 0, ended = 0, reason = "" }
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

-- 段落索引裡該槽的完整復原資料。slot／startTs／file 必須三者一致；
-- endTs／bytes 另做值域驗證，壞列整筆不用，避免舊槽資料掛到新 session。
local function readIndexRows()
    if type(getFileReader) ~= "function" then return nil end
    local ok, reader = pcall(getFileReader, INDEX, false)
    if not ok or not reader then return nil end
    local acc = {}
    local readOk = pcall(function()
        local line = reader:readLine()
        local lineN = 0
        while line ~= nil and lineN < SLOT_N do
            lineN = lineN + 1
            local slot, started, ended, bytes, reason, file = string.match(line,
                "^(%d+)\t([%-%d%.]+)\t([%-%d%.]+)\t([%-%d%.]+)\t([^\t]*)\t([^\t]+)$")
            slot = tonumber(slot)
            started = tonumber(started)
            ended = tonumber(ended)
            bytes = tonumber(bytes)
            if slot and slot >= 1 and slot <= SLOT_N and not acc[slot]
                    and finite(started) and started > 0
                    and finite(ended) and (ended == 0 or ended >= started)
                    and finite(bytes) and bytes >= 0 and bytes <= SLOT_MAX
                    and file == slotFile(slot)
                    and type(reason) == "string" and reason ~= "" then
                acc[slot] = {
                    started = started, ended = ended, bytes = bytes, reason = reason,
                }
            end
            line = reader:readLine()
        end
    end)
    pcall(function() reader:close() end)
    if not readOk then return nil end
    return acc
end

-- 最後一筆結束記錄（"t":"x"）的 reason：index 缺該槽時的退路。readLastLine 會
-- 掃完整個檔（最多 2MiB）——**只給最新槽用**，64 槽全掃等於在啟動路徑上讀
-- 128MiB。回 nil＝檔尾不是結束記錄（當掉／還在寫）。
local function readEndReason(i)
    local line = readLastLine(slotRel(i))
    if type(line) ~= "string" then return nil end
    if not string.find(line, '"t":"x"', 1, true) then return nil end
    local r = string.match(line, '"r":"([^"]*)"')
    if not r or r == "" then return nil end
    return safeReason(r)
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
        meta[i].reason = ""
        i = i + 1
    end
    local idxRows = readIndexRows()

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
            meta[i].reason = "active"
        else
            if manifestValid then
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
            -- reason 只從 index 取，且要求 startTs 對得上：槽會被回收重用，舊列的
            -- reason 掛到新 session 上就是假證據。對不上就維持函式開頭重設的 ""。
            local row = idxRows and idxRows[i]
            if (meta[i].started or 0) > 0 and row and row.started == meta[i].started then
                if not manifestValid or row.ended > (meta[i].ended or 0) then
                    meta[i].ended = row.ended
                    meta[i].bytes = row.bytes
                elseif row.ended == (meta[i].ended or 0)
                        and row.bytes > (meta[i].bytes or 0) then
                    meta[i].bytes = row.bytes
                end
                -- active index 只有在合併後仍 ended==0 才代表中斷。若 manifest 已有
                -- ended，代表 stop 已 durable、只差 index 收尾；reason 留空，讓下方
                -- newest footer 補回 arrive/error 等真實原因，不能誤標 interrupted。
                if row.reason == "active" then
                    meta[i].reason = (meta[i].ended or 0) == 0 and "interrupted" or ""
                else
                    meta[i].reason = row.reason
                end
            else
                meta[i].reason = ""
            end
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
        -- index 缺最新槽的 reason（升級後第一次跑／index 被手動刪）：只對這一槽
        -- 回讀最後一筆結束記錄補回來，其餘槽維持 unknown。
        if meta[newest].reason == "" and not live[newest] then
            meta[newest].reason = readEndReason(newest) or "unknown"
        end
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

-- 段落索引：只列 occupied 槽（started > 0），最多 SLOT_N 列，一列一段自駕。
-- 欄位固定 slot／startTs／endTs／bytes／reason／file，raw epoch ms、不含時區
-- ——時區在跨機器回報時是純噪音，epoch 直接對得上 log 內的 ts 欄位。
-- 沒有任何 occupied 槽時寫成空檔（不是刪檔）：readback 才有穩定的期望值。
local function dumpIndex()
    ensureMeta()
    local parts = {}
    local n = 0
    local i = 1
    while i <= SLOT_N do
        local m = meta[i]
        local st = m.started or 0
        if st > 0 then
            n = n + 1
            parts[n] = i .. "\t" .. st .. "\t" .. (m.ended or 0) .. "\t"
                .. (m.bytes or 0) .. "\t" .. safeReason(m.reason) .. "\t" .. slotFile(i)
        end
        i = i + 1
    end
    if n < 1 then return writeText(INDEX, "") end
    return writeText(INDEX, table.concat(parts, "\n", 1, n) .. "\n", parts[n])
end

-- index 寫失敗只留一行診斷：session data 已經 durable，索引不該回頭把它判死。
local function commitIndex()
    if dumpIndex() then return end
    logIndexOnce("diagnostics session index write failed")
end

-- 段落收尾的唯一出口。ioFailed 優先於呼叫端的 arrive／size／stop：
-- 已驗證落盤的 durableBytes 才能進 index，不能把尚在 PrintWriter buffer 的長度當真。
local function commitEnd(s, now, reason)
    if not s.committed then return end
    local m = s.slot and meta[s.slot]
    if not m then return end
    if s.ioFailed and s.failedAt then now = s.failedAt end
    m.ended = now
    m.bytes = s.durableBytes or 0
    m.reason = s.ioFailed and "error" or safeReason(reason)
    if not dumpManifest() then
        logOnce("diagnostics manifest finalization failed")
    end
    commitIndex()
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
                if truncateSlot(i) then
                    meta[i].started = 0
                    meta[i].bytes = 0
                    meta[i].ended = 0
                    meta[i].reason = ""
                else
                    logOnce("diagnostics expired-slot truncate failed")
                end
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
            if st <= 0 then return i end
            if now < st or (now - st) >= retainMs then
                if truncateSlot(i) then
                    meta[i].started = 0
                    meta[i].bytes = 0
                    meta[i].ended = 0
                    meta[i].reason = ""
                    return i
                end
                logOnce("diagnostics expired-slot truncate failed")
            end
        end
        i = i + 1
    end
    return nil
end

local function failIo(s, msg)
    logOnce(msg or "diagnostics IO failed")
    if not s then return end
    s.ioFailed = true
    s.failedAt = s.failedAt or nowMs()
    s.active = false
    closeWriter(s.writer)
    s.writer = nil
    s.buf = nil
    s.bufN = 0
    s.bufBytes = 0
    commitEnd(s, s.failedAt, "error")
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

-- 關閉 writer 後回讀最後一列；成功才更新 durableBytes。stop 用它直接封尾，
-- 週期 checkpoint 則封尾後再 reopen append。
local function sealWriter(s, now)
    if not flush(s, now) then return false end
    closeWriter(s.writer)
    s.writer = nil
    if s.lastLine and readLastLine(s.path) ~= s.lastLine then return false end
    s.durableBytes = s.fileBytes
    return true
end

local function checkpoint(s, now)
    if not sealWriter(s, now) then
        if not s.ioFailed then failIo(s, "diagnostics durability check failed") end
        return false
    end
    s.writer = openWriter(s.path, true)
    if not s.writer then
        failIo(s, "diagnostics IO failed")
        return false
    end
    s.lastCheck = now
    if s.committed and s.slot and meta[s.slot] then
        meta[s.slot].bytes = s.durableBytes
        meta[s.slot].reason = "active"
        if not dumpManifest() then
            failIo(s, "diagnostics manifest checkpoint failed")
            return false
        end
        commitIndex()
    end
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
    local durable = sealWriter(s, now)
    if not durable and not s.ioFailed then
        s.ioFailed = true
        s.failedAt = s.failedAt or now
        logOnce("diagnostics durability check failed")
        halo(s.pn, false, "UI_MinidoracatAutoDrive_TelemetryWriteFailed",
            "diagnostic logging stopped")
    end
    s.buf = nil
    commitEnd(s, now, reason or "size")
    if s.pn ~= nil then sessions[s.pn] = nil end
    if durable then
        halo(s.pn, false, "UI_MinidoracatAutoDrive_TelemetryFileFull",
            "diagnostic log reached 2 MiB")
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
        elseif k == "valid" or k == "fallback" or k == "geometryValid"
                or k == "isAnyTireMissing" then
            if type(v) == "boolean" then
                chunk = '"' .. k .. '":' .. (v and "true" or "false")
            end
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

-- 最近 8 顆硬障礙點。s/l 是弧座標（沿線／橫向），只有它們無法回答實機碰撞分析
-- 的兩個問題：「那顆點多大」與「它在地圖哪裡」——r 是膨脹半徑（Corridor 的縫隙
-- 判定直接吃它），x/y 是世界座標（能疊回地圖看到底撞上什麼）。仍只輸出最近 8 顆，
-- 不是整包快照：每幀 table 與整包點雲都不進 log。
local function encodeNear(sensor)
    local n = sensor.hardN
    local hs, hl = sensor.hardS, sensor.hardL
    if not finite(n) or n < 1 or type(hs) ~= "table" or type(hl) ~= "table" then
        return ""
    end
    local scan = finite(sensor.scanS) and sensor.scanS or 0
    local hr = sensor.hardR
    local hx, hy = sensor.hardX, sensor.hardY
    if type(hr) ~= "table" then hr = nil end
    if type(hx) ~= "table" or type(hy) ~= "table" then hx, hy = nil, nil end
    -- nk＝來源索引：r/x/y 在輸出時才查，插入排序的內圈只多搬一個純量
    local ns, nl, nd, nk = {}, {}, {}, {}
    local count = 0
    local i = 1
    local lim = n
    if lim > 768 then lim = 768 end
    while i <= lim do
        local src = i
        local s = hs[src]
        local l = hl[src]
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
                    nk[j] = nk[j - 1]
                    j = j - 1
                end
                nd[j] = d
                ns[j] = ds
                nl[j] = l
                nk[j] = src
            end
        end
    end
    if count < 1 then return "" end
    local parts = {}
    i = 1
    while i <= count do
        local src = nk[i]
        local piece = '{"s":' .. tostring(ns[i]) .. ',"l":' .. tostring(nl[i])
        local r = hr and hr[src]
        if finite(r) then piece = piece .. ',"r":' .. tostring(r) end
        local px = hx and hx[src]
        local py = hy and hy[src]
        -- 世界座標成對才有意義：只有一半的點不寫（半個座標比沒有更容易誤讀）
        if finite(px) and finite(py) then
            piece = piece .. ',"x":' .. tostring(px) .. ',"y":' .. tostring(py)
        end
        parts[i] = piece .. "}"
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
    if type(sensor.rain) == "boolean" then
        bits = bits .. ',"rain":' .. (sensor.rain and "true" or "false")
    end
    if finite(sensor.actualSurfaceId) then
        bits = bits .. ',"actualSurfaceId":' .. tostring(sensor.actualSurfaceId)
    end
    if finite(sensor.roundStartedAt) then
        bits = bits .. ',"roundStartedAt":' .. tostring(sensor.roundStartedAt)
    end
    if finite(sensor.completedBandBias) then
        bits = bits .. ',"completedBandBias":' .. tostring(sensor.completedBandBias)
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

-- schema v1 相容：既有欄位一個都不改名、不改語意，新欄位純 additive。
-- 新欄位全是純量（沒有每幀 table）：pm＝replan 的離場分類、rs／bs＝沿線弧長與
-- 煞停錨、dm／dn＝承諾剖面的餘裕與掃掠淨距、rb＝路面對中校正、bhx／bhy＝掃掠
-- 真命中的世界座標、fi＝follower 投影游標、cr＝這一幀採用的 10Hz 判定、
-- bl／dg／or／cn／cp＝blocked／dodging／offroad／corner-latch／耦力調頭。
-- Phase A 物理狀態（最後一參 phys table，缺席＝舊簽章）：po／ib＝Java
-- isDoingOffroad／isBraking、sk＝minWheelSkid、vl／vt＝縱／橫向速度、
-- es／tn／rgs＝引擎轉速／檔位／regulatorSpeed、el／ld＝期望車道與橫偏、
-- rst／rlo／rhi／us＝路面帶狀態與未載入弧長、acr＋csen／cg／cpc／cw／cof／
-- ch／cbl／cdg＝綁定 cap 原因與各檔純量。數值缺值省略、布林有值才顯式寫出。
-- 為什麼要這些：舊 sample 缺 pm，無法直接看出 replan 是否走 offroad-suppress；
-- 也缺 cp，無法區分真正耦力旋轉與一般橫推。倒車脫困仍由 unstick event／mode
-- 與負 spd 判讀；cp 不代表倒車（2026-08-31 實機分析）。
local function encodePhys(phys)
    if type(phys) ~= "table" then return "" end
    local bits = ""
    local function addBool(src, json)
        local v = phys[src]
        if v == true then
            bits = bits .. ',"' .. json .. '":true'
        elseif v == false then
            bits = bits .. ',"' .. json .. '":false'
        end
    end
    local function addNum(src, json)
        local v = phys[src]
        if finite(v) then bits = bits .. ',"' .. json .. '":' .. tostring(v) end
    end
    local function addStr(src, json)
        local v = phys[src]
        if type(v) == "string" then bits = bits .. ',"' .. json .. '":' .. jstr(v) end
    end
    addBool("physicalOffroad", "po")
    addBool("isBraking", "ib")
    addNum("minWheelSkid", "sk")
    addNum("vLong", "vl")
    addNum("vLat", "vt")
    addNum("engineSpeed", "es")
    addNum("transmissionNumber", "tn")
    addNum("regulatorSpeed", "rgs")
    addNum("expectedLane", "el")
    addNum("latDev", "ld")
    addStr("roadState", "rst")
    addNum("roadLo", "rlo")
    addNum("roadHi", "rhi")
    addNum("unloadedS", "us")
    addStr("activeCapReason", "acr")
    addNum("capSensor", "csen")
    addNum("capGear", "cg")
    addNum("capPerception", "cpc")
    addNum("capWarm", "cw")
    addNum("capOffroad", "cof")
    addNum("capHeading", "ch")
    addNum("capBlocked", "cbl")
    addNum("capDodge", "cdg")
    addNum("navVersion", "nv")
    addNum("currentSurfaceId", "sid")
    addStr("currentSurface", "surf")
    addNum("currentSegWidth", "sw")
    addStr("controlState", "ctl")
    addBool("adaptive", "ad")
    addBool("raining", "rn")
    addBool("returnActive", "ra")
    addBool("returnUnsafe", "ru")
    addBool("returnHold", "rh")
    addBool("returnCapacityFault", "rcf")
    addBool("surfaceMismatch", "sm")
    addNum("tractionKey", "tk")
    addNum("runtimeMass", "rm")
    addNum("priorAccel", "pa")
    addNum("priorCoast", "pco")
    addNum("priorBrake", "pb")
    addNum("priorLat", "pl")
    addNum("safeAccel", "sa")
    addNum("safeBrake", "sb")
    addNum("safeLat", "sl")
    addNum("accelConfidence", "acf")
    addNum("coastConfidence", "ccf")
    addNum("coastLower", "cl")
    addNum("accelLower", "al")
    addNum("brakeConfidence", "bcf")
    addNum("brakeLower", "bal")
    addNum("yawConfidence", "ycf")
    addNum("yawLower", "yl")
    addNum("steeringKappa", "kap")
    addNum("capReturn", "crt")
    return bits
end

local function encodeSample(s, now, x, y, heading, speed, target, remaining, lat, err,
        steer, force, mode, gear, regulator, sensor, critical,
        planMode, routeS, blockS, dodgeMargin, dodgeNeed, roadBias,
        blockHitX, blockHitY, followerIdx,
        blocked, dodging, offroad, corner, coupled, phys,
        targetGen, routeGen, episodeId, progressState, attempt, ban,
        unstickDistance, rearStatus, reverseForce, remainingMs,
        actualClearance, plannedClearance, footprintBlocked, footHitX, footHitY)
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
    extra = extra .. encodePhys(phys)
    local pmjson = "null"
    if type(planMode) == "string" then pmjson = jstr(planMode) end
    local plan = ',"pm":' .. pmjson
    -- 數值缺值就整欄不寫（不是寫 0）：0 是合法的弧長／餘裕，假 0 會讓分析誤判
    if finite(routeS) then plan = plan .. ',"rs":' .. tostring(routeS) end
    if finite(blockS) then plan = plan .. ',"bs":' .. tostring(blockS) end
    if finite(dodgeMargin) then plan = plan .. ',"dm":' .. tostring(dodgeMargin) end
    if finite(dodgeNeed) then plan = plan .. ',"dn":' .. tostring(dodgeNeed) end
    if finite(roadBias) then plan = plan .. ',"rb":' .. tostring(roadBias) end
    if finite(blockHitX) and finite(blockHitY) then
        plan = plan .. ',"bhx":' .. tostring(blockHitX)
            .. ',"bhy":' .. tostring(blockHitY)
    end
    if finite(followerIdx) then plan = plan .. ',"fi":' .. tostring(followerIdx) end
    if finite(targetGen) then plan = plan .. ',"tg":' .. tostring(targetGen) end
    if finite(routeGen) then plan = plan .. ',"rg":' .. tostring(routeGen) end
    if finite(episodeId) then plan = plan .. ',"eid":' .. tostring(episodeId) end
    if type(progressState) == "string" then
        plan = plan .. ',"ps":' .. jstr(progressState)
    end
    if finite(attempt) then plan = plan .. ',"ua":' .. tostring(attempt) end
    if finite(ban) then
        plan = plan .. ',"ban":' .. tostring(ban)
    elseif type(ban) == "boolean" then
        plan = plan .. ',"ban":' .. (ban and "true" or "false")
    end
    if finite(unstickDistance) then plan = plan .. ',"ud":' .. tostring(unstickDistance) end
    if type(rearStatus) == "string" then plan = plan .. ',"rear":' .. jstr(rearStatus) end
    if finite(reverseForce) then plan = plan .. ',"rf":' .. tostring(reverseForce) end
    if finite(remainingMs) then plan = plan .. ',"rms":' .. tostring(remainingMs) end
    if finite(actualClearance) then plan = plan .. ',"ac":' .. tostring(actualClearance) end
    if finite(plannedClearance) then plan = plan .. ',"pc":' .. tostring(plannedClearance) end
    if type(footprintBlocked) == "boolean" then
        plan = plan .. ',"fb":' .. (footprintBlocked and "true" or "false")
    end
    if finite(footHitX) and finite(footHitY) then
        plan = plan .. ',"fhx":' .. tostring(footHitX)
            .. ',"fhy":' .. tostring(footHitY)
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
        .. plan
        -- 布林一律寫出來（含 false）：碰撞那一幀「當時沒有 blocked」跟「這版沒有
        -- 這個欄位」必須分得開，缺欄位＝分析要猜，那就等於沒有證據。
        .. ',"cr":' .. (critical == true and "true" or "false")
        .. ',"bl":' .. (blocked == true and "true" or "false")
        .. ',"dg":' .. (dodging == true and "true" or "false")
        .. ',"or":' .. (offroad == true and "true" or "false")
        .. ',"cn":' .. (corner == true and "true" or "false")
        .. ',"cp":' .. (coupled == true and "true" or "false")
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
    if type(a) == "table" then
        local i = 1
        while i <= #EK do
            local k = EK[i]
            add(k, a[k])
            i = i + 1
        end
    else
        add("a", a)
        add("b", b)
        add("c", c)
        add("d", d)
    end
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

-- Windows/PZ may reject getFileReader while the append writer is open. A live
-- session already passed the durable-header checkpoint, so it is safe to expose
-- its path without reopening the same file.
local function latestExists(name)
    for _, s in pairs(sessions) do
        if s and s.active and s.slot and slotFile(s.slot) == name then return true end
    end
    local line = readLine1(DIR .. "/" .. name)
    return type(line) == "string" and line ~= ""
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
        commitIndex()
        return false
    end
    local path = slotRel(slot)
    local writer = openWriter(path, false)
    if not writer then
        logOnce("diagnostics IO failed")
        halo(pn, false, "UI_MinidoracatAutoDrive_TelemetryWriteFailed",
            "diagnostic logging stopped")
        -- cleanupExpired／allocSlot 可能已經清掉過期槽：index 必須跟著那個清除，
        -- 否則索引會留著已經被截空的檔案列。
        commitIndex()
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
        durableBytes = 0,
        committed = false,
        ioFailed = false,
        failedAt = nil,
    }
    sessions[pn] = s
    local startOk, ready = pcall(function()
        enqueue(s, encodeHeader(slot, now, days, profile), now)
        return checkpoint(s, now)
    end)
    if not startOk then failIo(s, "diagnostics encoding failed") end
    if not startOk or ready ~= true or not s.active then
        truncateSlot(slot)
        commitIndex()
        return false
    end
    meta[slot].started = now
    meta[slot].bytes = s.fileBytes
    meta[slot].ended = 0
    -- committed 的 session 在 index 裡就是 active：endTs 0＝還在寫。下一輪遊戲
    -- 看到「active 但沒有 live session」就會被 recoverMeta 判成 interrupted。
    meta[slot].reason = "active"
    if not dumpManifest() then
        meta[slot].started, meta[slot].bytes, meta[slot].ended = 0, 0, 0
        meta[slot].reason = ""
        failIo(s, "diagnostics manifest write failed")
        truncateSlot(slot)
        commitIndex()
        return false
    end
    s.committed = true
    lastName = slotFile(slot)
    if not writeText(LATEST, lastName .. "\n", lastName) then
        logOnce("diagnostics latest-pointer write failed")
    end
    -- index 失敗只記一行：header／manifest 都已 durable，session data 照跑。
    commitIndex()
    return true
end

-- 純查詢：這一幀 sample() 會不會真的 enqueue，第二回值＝這一幀採用的 10Hz
-- 判定（crit），由 sample() 直接沿用，不重算。不碰 lastSample。
-- Driver 只在 true 時才跑新 Java getter，避免 5/10Hz gate 被 UI 幀繞過。
local function sampleWouldEnqueue(s, now, mode, err, critical)
    if not s or not s.active then return false end
    if not finite(now) then return false end
    local crit = critical == true or isCritical(mode, err)
    local gap = HZ_N
    if crit then gap = HZ_C end
    if s.lastSample ~= nil and now >= s.lastNow
            and now - s.lastSample < gap then
        return false
    end
    return true, crit
end

function D.shouldSample(pn, now, mode, err, critical)
    -- 對外只回單一布林：多回值會漏進呼叫端的參數列。
    local want = sampleWouldEnqueue(sessions[pn], now, mode, err, critical)
    return want
end

function D.sample(pn, now, x, y, heading, speed, target, remaining, lat, err,
        steer, force, mode, gear, regulator, sensor, critical,
        planMode, routeS, blockS, dodgeMargin, dodgeNeed, roadBias,
        blockHitX, blockHitY, followerIdx,
        blocked, dodging, offroad, corner, coupled, phys,
        targetGen, routeGen, episodeId, progressState, attempt, ban,
        unstickDistance, rearStatus, reverseForce, remainingMs,
        actualClearance, plannedClearance, footprintBlocked, footHitX, footHitY)
    local s = sessions[pn]
    if not s or not s.active then return false end
    -- now 非有限、或還在 gate 內：不 enqueue，但 session 照樣算活著。
    local want, crit = sampleWouldEnqueue(s, now, mode, err, critical)
    if not want then return true end
    s.lastNow = now
    s.lastSample = now
    -- 記進 log 的是**這一幀真正採用的** 10Hz 判定（呼叫端旗標 or 誤差/模式推導），
    -- 不是呼叫端傳進來的原值：分析要對得上取樣密度。
    enqueue(s, encodeSample(s, now, x, y, heading, speed, target, remaining, lat, err,
        steer, force, mode, gear, regulator, sensor, crit,
        planMode, routeS, blockS, dodgeMargin, dodgeNeed, roadBias,
        blockHitX, blockHitY, followerIdx,
        blocked, dodging, offroad, corner, coupled, phys,
        targetGen, routeGen, episodeId, progressState, attempt, ban,
        unstickDistance, rearStatus, reverseForce, remainingMs,
        actualClearance, plannedClearance, footprintBlocked, footHitX, footHitY), now)
    return s.active == true
end

function D.event(pn, name, a, b, c, d)
    local s = sessions[pn]
    if not s or not s.active then return end
    local now = nowMs()
    enqueue(s, encodeEvent(now, name, a, b, c, d), now)
end

-- Non-I/O diagnostics faults share one visible terminal path: preserve the
-- actionable detail in the console, close the durable session as error, and
-- tell the player that only recording stopped.
function D.fail(pn, detail)
    local s = sessions[pn]
    if not s then return false end
    local okText, text = pcall(tostring, detail)
    if not okText or type(text) ~= "string" or text == "" then text = "unknown error" end
    logOnce("diagnostics failed: " .. text)
    halo(pn, false, "UI_MinidoracatAutoDrive_TelemetryWriteFailed",
        "diagnostic logging stopped")
    D.stop(pn, "error")
    return true
end

function D.stop(pn, reason)
    local s = sessions[pn]
    if not s then return end
    local now = nowMs()
    if s.active and s.writer then
        local ok, durable = pcall(function()
            enqueue(s, '{"t":"x","ts":' .. jnum(now) .. ',"r":'
                .. jstr(tostring(reason or "stop")) .. '}', now)
            if not s.active or not s.writer then return false end
            return sealWriter(s, now)
        end)
        if not ok then
            failIo(s, "diagnostics encoding failed")
        elseif not durable and not s.ioFailed and sessions[pn] == s then
            failIo(s, "diagnostics durability check failed")
        end
    end
    -- enqueue 可能因 size 直接走 stopFull；failIo 也已自行 error 收尾。
    if sessions[pn] ~= s then return end
    commitEnd(s, now, reason or "stop")
    s.active = false
    s.writer = nil
    s.buf = nil
    sessions[pn] = nil
end

function D.hasLatest()
    local name = readPointer()
    return type(name) == "string" and name ~= "" and latestExists(name)
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
    if not latestExists(name) then
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
        copiedNotice(pn)
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
        copiedNotice(pn)
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
