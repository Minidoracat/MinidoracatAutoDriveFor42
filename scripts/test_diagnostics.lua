--[[
MDAD_Diagnostics.lua offline tests: load production module with an in-memory
fake filesystem. Covers allocation-off, retention and slot reuse failures,
size and I/O caps, one-file/session, manifest/index recovery and checkpoints,
escaping/privacy, collision evidence, clipboard paths, Toast, and Halo fallback.
]]

local MEDIA = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua"
local ROOTS = { "", "../" }

local function findProd()
    local rel = MEDIA .. "/client/MDAD_Diagnostics.lua"
    local i = 1
    while i <= #ROOTS do
        local path = ROOTS[i] .. rel
        local f = io.open(path, "rb")
        if f then
            f:close()
            return path
        end
        i = i + 1
    end
    error("missing MDAD_Diagnostics.lua")
end

local PROD = findProd()

local failures, assertions, scenarios = 0, 0, 0
local scenarioBase, scenarioTitle = 0, nil

local function show(v)
    if type(v) == "string" then return '"' .. v .. '"' end
    return tostring(v)
end

local function check(ok, label)
    assertions = assertions + 1
    if not ok then
        failures = failures + 1
        print("  FAIL " .. label)
    end
    return ok
end

local function checkEq(actual, expected, label)
    return check(actual == expected,
        label .. " (expected " .. show(expected) .. ", got " .. show(actual) .. ")")
end

local function closeScenario()
    if not scenarioTitle then return end
    local n = assertions - scenarioBase
    print("  " .. n .. " asserts")
end

local function scenario(title)
    closeScenario()
    scenarios = scenarios + 1
    scenarioBase = assertions
    scenarioTitle = title
    print("scenario " .. scenarios .. ": " .. title)
end

local files = {}
local writerCalls = 0
local readerCalls = 0
local listCalls = 0
local writerCloses = 0
local writerOpens = {}
local openWriters = {}
local failWriter = false
local failOpenAt = nil
-- 只讓某一個路徑的 writer 開不起來：管理檔（索引）與紀錄檔的失敗要能分開驗
local failPath = nil
local throwWrite = false
local silentDrop = false
local dropPath = nil
local lockLiveReads = false
local nowMs = 1000000
local enabled = true
local days = 7
local clipText = nil
local clipFail = false
local halos = {}
local player0 = { id = 0 }
local DAY_MS = 86400000
local menuHandlers = {}

local function resetFs()
    files = {}
    writerCalls = 0
    readerCalls = 0
    listCalls = 0
    writerCloses = 0
    writerOpens = {}
    openWriters = {}
    failWriter = false
    failOpenAt = nil
    failPath = nil
    throwWrite = false
    silentDrop = false
    dropPath = nil
    lockLiveReads = false
    clipText = nil
    clipFail = false
    halos = {}
end

function getTimestampMs() return nowMs end
function getMyDocumentFolder() return "C:/Zomboid" end
function getFileSeparator() return "/" end
function getSpecificPlayer(pn)
    if pn == 0 then return player0 end
    return nil
end
function getText(key) return key end

Clipboard = {
    setClipboard = function(text)
        if clipFail then error("clip") end
        clipText = text
    end,
}

HaloTextHelper = {
    addGoodText = function(_, text)
        halos[#halos + 1] = { kind = "good", text = text }
    end,
    addBadText = function(_, text)
        halos[#halos + 1] = { kind = "bad", text = text }
    end,
}

MDAD = {
    BUILD = "m57-test",
    HUD = {
        telemetryEnabled = function() return enabled end,
        telemetryRetentionDays = function() return days end,
    },
}

Events = {
    OnMainMenuEnter = {
        Add = function(fn) menuHandlers[#menuHandlers + 1] = fn end,
    },
}

local function fireMainMenu()
    local i = 1
    while i <= #menuHandlers do
        menuHandlers[i]()
        i = i + 1
    end
end

local function splitLines(content)
    local lines, n = {}, 0
    local start = 1
    while true do
        local i = string.find(content, "\n", start, true)
        if not i then
            if start <= #content then
                n = n + 1
                lines[n] = string.sub(content, start)
            end
            break
        end
        n = n + 1
        lines[n] = string.sub(content, start, i - 1)
        if string.sub(lines[n], -1) == "\r" then
            lines[n] = string.sub(lines[n], 1, #lines[n] - 1)
        end
        start = i + 1
    end
    return lines
end

function getFileWriter(path, _, append)
    writerCalls = writerCalls + 1
    writerOpens[#writerOpens + 1] = { path = path, append = append == true }
    if failWriter or writerCalls == failOpenAt or (failPath and path == failPath) then
        return nil
    end
    if not append or files[path] == nil then files[path] = "" end
    openWriters[path] = (openWriters[path] or 0) + 1
    local closed = false
    return {
        write = function(_, s)
            if throwWrite then error("io") end
            if not silentDrop and path ~= dropPath then
                files[path] = files[path] .. (s or "")
            end
        end,
        close = function()
            if closed then return end
            closed = true
            writerCloses = writerCloses + 1
            openWriters[path] = (openWriters[path] or 1) - 1
        end,
    }
end

function getFileReader(path, _)
    readerCalls = readerCalls + 1
    if lockLiveReads and (openWriters[path] or 0) > 0 then return nil end
    local content = files[path]
    if content == nil then return nil end
    local lines = splitLines(content)
    local idx = 0
    return {
        readLine = function()
            idx = idx + 1
            return lines[idx]
        end,
        close = function() end,
    }
end

function listFilesInZomboidLuaDirectory(directory)
    listCalls = listCalls + 1
    local names = {}
    local prefix = directory .. "/"
    local path
    for path in pairs(files) do
        if string.sub(path, 1, #prefix) == prefix then
            names[#names + 1] = string.sub(path, #prefix + 1)
        end
    end
    return {
        size = function() return #names end,
        get = function(_, i) return names[i + 1] end,
    }
end

local function loadProd()
    MDADDiagnostics = nil
    menuHandlers = {}
    local fn, err = loadfile(PROD)
    if not fn then error(err) end
    fn()
end

local function countNeedle(s, needle)
    if type(s) ~= "string" then return 0 end
    local n, pos = 0, 1
    while true do
        local i = string.find(s, needle, pos, true)
        if not i then return n end
        n = n + 1
        pos = i + 1
    end
end

-- 只數 session-NNN.log：管理檔 session-index.txt 也含 "session-"，用寬鬆的
-- 前綴比對會把索引算成一份紀錄檔，「固定 64 槽」的斷言就變成 65。
local function sessionFiles()
    local n = 0
    local path
    for path in pairs(files) do
        if string.find(path, "session%-%d%d%d%.log$") then n = n + 1 end
    end
    return n
end

local INDEX_PATH = "MinidoracatAutoDrive/Telemetry/session-index.txt"
local MANIFEST_PATH = "MinidoracatAutoDrive/Telemetry/manifest.txt"

-- 索引列 → { slot, startTs, endTs, bytes, reason, file } 的陣列（順序保留）
local function indexRows()
    local rows = {}
    local content = files[INDEX_PATH]
    if type(content) ~= "string" then return rows end
    local lines = splitLines(content)
    local i = 1
    while i <= #lines do
        local slot, st, en, bytes, reason, file = string.match(lines[i],
            "^(%d+)\t([%-%d%.]+)\t([%-%d%.]+)\t([%-%d%.]+)\t([^\t]*)\t(.+)$")
        if slot then
            rows[#rows + 1] = {
                slot = tonumber(slot), startTs = tonumber(st), endTs = tonumber(en),
                bytes = tonumber(bytes), reason = reason, file = file,
                raw = lines[i],
            }
        else
            rows[#rows + 1] = { raw = lines[i], malformed = true }
        end
        i = i + 1
    end
    return rows
end

local function indexRow(slot)
    local rows = indexRows()
    local i = 1
    while i <= #rows do
        if rows[i].slot == slot then return rows[i] end
        i = i + 1
    end
    return nil
end

local function sessionPath(i)
    local name
    if i < 10 then name = "session-00" .. i .. ".log"
    else name = "session-0" .. i .. ".log" end
    return "MinidoracatAutoDrive/Telemetry/" .. name
end

local profile = {
    valid = true, fallback = false, geometryValid = true, scriptName = 'Base.Car"X',
    bodyW = 1.8, bodyL = 4.5, halfW = 0.9, halfL = 2.25,
    centerOfMassX = 0.1, centerOfMassY = 0.55, centerOfMassZ = -0.2,
    mass = 1200, maxSpeed = 70, wheelbase = 2.6, track = 1.5,
    clamp0 = 0.9, clamp30 = 0.64, clampMax = 0.3,
    wheelFriction = 1.2, delta0Safe = 0.72, deltaVSafe = 0.24,
    rMin = 3.2, lookScale = 1.3, rearArm = 2.9, needHalf = 1.4, probeR = 3.5,
    enginePower = 4000, brakingForce = 80, offroadEfficiency = 1.1,
    rollInfluence = 0.7,
    tireFrictionMin = 1.4, tireFrictionAvg = 1.5, tireFrictionCount = 4,
    isAnyTireMissing = false,
}

loadProd()

--------------------------------------------------------------------------------
scenario("allocation-off: telemetry disabled does no file IO")
resetFs()
enabled = false
nowMs = 1000000
local w0, r0, l0 = writerCalls, readerCalls, listCalls
checkEq(MDADDiagnostics.start(0, nil, profile), false, "disabled start reports inactive")
MDADDiagnostics.sample(0, nowMs, 10, 20, 0, 30, 30, 100, 0, 0, 0, 0, "follow", 2, true, nil)
MDADDiagnostics.event(0, "x")
MDADDiagnostics.stop(0, "end")
checkEq(writerCalls, w0, "no getFileWriter")
checkEq(readerCalls, r0, "no getFileReader")
checkEq(listCalls, l0, "no listFiles")
checkEq(sessionFiles(), 0, "no session files")
enabled = true

--------------------------------------------------------------------------------
scenario("sample gates 200ms normal / 100ms critical; events skip the gate")
resetFs()
nowMs = 5000
checkEq(MDADDiagnostics.start(0, nil, profile), true, "enabled start reports active")
MDADDiagnostics.sample(0, 5000, 1, 2, 0, 10, 10, 50, 0, 0, 0, 0, "follow", 1, false, nil)
MDADDiagnostics.sample(0, 5100, 1, 2, 0, 10, 10, 50, 0, 0, 0, 0, "follow", 1, false, nil)
MDADDiagnostics.event(0, "ping")
MDADDiagnostics.sample(0, 5200, 1, 2, 0, 10, 10, 50, 0, 0, 0, 0, "follow", 1, false, nil)
MDADDiagnostics.sample(0, 5300, 1, 2, 0, 10, 10, 50, 0, 0, 0, 0, "follow", 1, false, nil, true)
MDADDiagnostics.sample(0, 5400, 1, 2, 0, 10, 10, 50, 0, 1.6, 0, 0, "follow", 1, false, nil)
nowMs = 7000
MDADDiagnostics.stop(0, "end")
local body = files[sessionPath(1)] or ""
checkEq(countNeedle(body, '"t":"s"'), 4, "two normal + two critical samples")
checkEq(countNeedle(body, '"t":"e"'), 1, "event recorded between gated samples")
check(string.find(body, '"n":"ping"', 1, true) ~= nil, "event payload present")

--------------------------------------------------------------------------------
scenario("shouldSample shares the 200/100ms gate and does not mutate it")
resetFs()
loadProd()
nowMs = 5000
checkEq(MDADDiagnostics.shouldSample(0, 5000, "follow", 0, false), false,
    "no session → shouldSample false")
checkEq(MDADDiagnostics.start(0, nil, profile), true, "start for shouldSample")
checkEq(MDADDiagnostics.shouldSample(0, 5000, "follow", 0, false), true,
    "first sample would enqueue")
checkEq(MDADDiagnostics.shouldSample(0, 5000, "follow", 0, false), true,
    "shouldSample is pure: still true before sample")
MDADDiagnostics.sample(0, 5000, 1, 2, 0, 10, 10, 50, 0, 0, 0, 0, "follow", 1, false, nil)
checkEq(MDADDiagnostics.shouldSample(0, 5100, "follow", 0, false), false,
    "100ms later normal gate still closed")
checkEq(MDADDiagnostics.shouldSample(0, 5200, "follow", 0, false), true,
    "200ms later normal gate opens")
MDADDiagnostics.sample(0, 5200, 1, 2, 0, 10, 10, 50, 0, 0, 0, 0, "follow", 1, false, nil)
checkEq(MDADDiagnostics.shouldSample(0, 5250, "follow", 0, true), false,
    "critical 50ms still gated")
checkEq(MDADDiagnostics.shouldSample(0, 5300, "follow", 0, true), true,
    "critical 100ms opens")
checkEq(MDADDiagnostics.shouldSample(0, 0 / 0, "follow", 0, false), false,
    "non-finite now → shouldSample false")
nowMs = 7000
MDADDiagnostics.stop(0, "end")
local gateBody = files[sessionPath(1)] or ""
checkEq(countNeedle(gateBody, '"t":"s"'), 2, "shouldSample queries did not enqueue extra samples")
--------------------------------------------------------------------------------
scenario("batching 1s/8KiB/64 and 60s checkpoint reopen")
resetFs()
nowMs = 20000
MDADDiagnostics.start(0, nil, profile)
local opensAfterStart = #writerOpens
local headerOnly = files[sessionPath(1)] or ""
check(countNeedle(headerOnly, '"t":"s"') == 0, "header flushed, samples still buffered")
MDADDiagnostics.sample(0, 20000, 3, 4, 0, 5, 5, 9, 0, 0, 0, 0, "follow", 1, false, nil)
MDADDiagnostics.sample(0, 20200, 3, 4, 0, 5, 5, 9, 0, 0, 0, 0, "follow", 1, false, nil)
checkEq(countNeedle(files[sessionPath(1)] or "", '"t":"s"'), 0, "under 1s stays in buffer")
MDADDiagnostics.sample(0, 21000, 3, 4, 0, 5, 5, 9, 0, 0, 0, 0, "follow", 1, false, nil)
check(countNeedle(files[sessionPath(1)] or "", '"t":"s"') >= 1, "1s batch flush")
MDADDiagnostics.sample(0, 81000, 3, 4, 0, 5, 5, 9, 0, 0, 0, 0, "follow", 1, false, nil)
local sawAppend = false
local oi = opensAfterStart + 1
while oi <= #writerOpens do
    if writerOpens[oi].append and writerOpens[oi].path == sessionPath(1) then
        sawAppend = true
    end
    oi = oi + 1
end
check(sawAppend, "60s checkpoint reopens append")
nowMs = 82000
MDADDiagnostics.stop(0, "end")
checkEq(sessionFiles(), 1, "checkpoint does not create a part file")

--------------------------------------------------------------------------------
scenario("one file per session, no parts")
resetFs()
nowMs = 30000
MDADDiagnostics.start(0, nil, profile)
local k = 0
while k < 20 do
    nowMs = 30000 + k * 1000
    MDADDiagnostics.sample(0, nowMs, 8, 9, 0.2, 40, 40, 80, 0.1, 2, 0.1, 0, "follow", 2, true, nil)
    k = k + 1
end
MDADDiagnostics.stop(0, "arrive")
checkEq(sessionFiles(), 1, "single session log")
local path
for path in pairs(files) do
    check(string.find(path, ".part", 1, true) == nil, "no part suffix " .. path)
end

--------------------------------------------------------------------------------
scenario("split-screen sessions keep distinct live slots during recovery")
resetFs()
nowMs = 35000
checkEq(MDADDiagnostics.start(0, nil, profile), true, "slot 0 diagnostics starts")
nowMs = 35100
checkEq(MDADDiagnostics.start(1, nil, profile), true, "slot 1 diagnostics starts concurrently")
MDADDiagnostics.sample(0, 35200, 1, 1, 0, 1, 1, 1, 0, 0, 0, 0,
    "follow", 1, false, nil)
MDADDiagnostics.sample(1, 35200, 2, 2, 0, 1, 1, 1, 0, 0, 0, 0,
    "follow", 1, false, nil)
nowMs = 36000
MDADDiagnostics.stop(0, "end")
MDADDiagnostics.stop(1, "end")
checkEq(sessionFiles(), 2, "concurrent players use two files")
check(string.find(files[sessionPath(1)] or "", '"slot":1', 1, true) ~= nil,
    "first live slot survives second start recovery")
check(string.find(files[sessionPath(2)] or "", '"slot":2', 1, true) ~= nil,
    "second player receives next slot")

--------------------------------------------------------------------------------
scenario("escaping, privacy exclusions, sensor aggregate/near-8")
resetFs()
nowMs = 40000
MDADDiagnostics.start(0, nil, profile)
local hardS, hardL = {}, {}
local hi = 1
while hi <= 12 do
    hardS[hi] = 10 + hi
    hardL[hi] = hi - 6
    hi = hi + 1
end
local sen = {
    hardN = 12, hardS = hardS, hardL = hardL, hardX = { 9999 }, hardY = { 8888 },
    softN = 1, zombieN = 2, corpseN = 3, vehN = 0, movingVeh = false,
    unloaded = false, ready = true, sig = 7, stamp = 11, scanS = 10, roadN = 4,
    roadC = 0.5, rain = false, actualSurfaceId = 2, roundStartedAt = 39950,
    completedBandBias = 1.25,
}
MDADDiagnostics.sample(0, 40000, 10700.25, 9800.5, 1.2, 33, 30, 12, 0.4, 8, 0.2, 1,
    "follow", 2, true, sen)
MDADDiagnostics.sample(0, 40200, 10700.25, 9800.5, 1.2, 33, 30, 12, 0.4, 8, 0.2, 1,
    "follow", 2, true, sen)
MDADDiagnostics.event(0, 'a"b\\c' .. string.char(1))
nowMs = 42000
MDADDiagnostics.stop(0, "end")
body = files[sessionPath(1)] or ""
check(string.find(body, 'a\\"b\\\\c', 1, true) ~= nil, "event name escaped")
check(string.find(body, "\\u0001", 1, true) ~= nil, "control byte escaped")
check(string.find(body, 'Base.Car\\"X', 1, true) ~= nil, "profile scriptName escaped")
check(string.find(body, '"delta0Safe":0.72', 1, true) ~= nil,
    "approved steering envelope serialized")
check(string.find(body, '"maxSpeed":70', 1, true) ~= nil,
    "runtime max speed serialized")
check(string.find(body, '"enginePower":4000', 1, true) ~= nil,
    "runtime enginePower serialized")
check(string.find(body, '"isAnyTireMissing":false', 1, true) ~= nil,
    "isAnyTireMissing explicit false")
check(string.find(body, '"geometryValid":true', 1, true) ~= nil,
    "control geometry validity serialized")
check(string.find(body, '"centerOfMassX":0.1', 1, true) ~= nil,
    "COM x serialized")
check(string.find(body, '"centerOfMassZ":-0.2', 1, true) ~= nil,
    "COM z serialized")
check(string.find(body, '"x":10700.25', 1, true) ~= nil, "opt-in absolute x allowed")
check(string.find(body, "username", 1, true) == nil, "no username")
check(string.find(body, "steamId", 1, true) == nil, "no steamId")
check(string.find(body, "SteamID", 1, true) == nil, "no SteamID")
check(string.find(body, "chat", 1, true) == nil, "no chat")
check(string.find(body, "modlist", 1, true) == nil, "no modlist")
check(string.find(body, '"hardX"', 1, true) == nil, "no full sensor world X")
check(string.find(body, '"hardY"', 1, true) == nil, "no full sensor world Y")
check(string.find(body, '"rain":false', 1, true) ~= nil, "sensor rain false explicit")
check(string.find(body, '"actualSurfaceId":2', 1, true) ~= nil,
    "sensor actual surface id recorded")
check(string.find(body, '"roundStartedAt":39950', 1, true) ~= nil,
    "sensor round start timestamp recorded")
check(string.find(body, '"completedBandBias":1.25', 1, true) ~= nil,
    "sensor completed band bias recorded")
check(string.find(body, '"hardS"', 1, true) == nil, "no full sensor S array")
check(countNeedle(body, '"near":') == 1, "near list only when stamp changes")
check(countNeedle(body, '{"s":') <= 8, "at most 8 near records")
check(string.find(body, '"hardN":12', 1, true) ~= nil, "sensor aggregate kept")
--------------------------------------------------------------------------------
scenario("unknown optional profile fields are omitted, not serialized as safe values")
do
    resetFs()
    loadProd()
    nowMs = 45000
    local unknown = {}
    for k, v in pairs(profile) do unknown[k] = v end
    unknown.enginePower = nil
    unknown.brakingForce = nil
    unknown.offroadEfficiency = nil
    unknown.rollInfluence = nil
    unknown.centerOfMassY = nil
    unknown.tireFrictionMin = nil
    unknown.tireFrictionAvg = nil
    unknown.tireFrictionCount = nil
    unknown.isAnyTireMissing = nil
    checkEq(MDADDiagnostics.start(0, nil, unknown), true, "unknown profile starts")
    nowMs = 45100
    MDADDiagnostics.stop(0, "end")
    local unknownBody = files[sessionPath(1)] or ""
    check(string.find(unknownBody, '"valid":true', 1, true) ~= nil,
        "legacy valid semantics remain serialized")
    check(string.find(unknownBody, '"fallback":false', 1, true) ~= nil,
        "legacy fallback semantics remain serialized")
    check(string.find(unknownBody, '"enginePower"', 1, true) == nil,
        "unknown enginePower omitted")
    check(string.find(unknownBody, '"tireFrictionCount"', 1, true) == nil,
        "unknown tire aggregate omitted")
    check(string.find(unknownBody, '"isAnyTireMissing"', 1, true) == nil,
        "unknown tire state omitted instead of false")
end


--------------------------------------------------------------------------------
scenario("copy latest/folder absolute paths and Halo")
resetFs()
nowMs = 50000
check(MDADDiagnostics.copyLatestPath(0) == false, "copy latest fails")
checkEq(halos[#halos] and halos[#halos].kind, "bad", "latest miss is Halo bad")
check(MDADDiagnostics.copyFolderPath(0) == true, "folder copy works empty")
checkEq(clipText, "C:/Zomboid/Lua/MinidoracatAutoDrive/Telemetry", "folder abs path")
lockLiveReads = true
checkEq(MDADDiagnostics.start(0, nil, profile), true, "active copy session starts")
local readsBeforeLiveCopy = readerCalls
halos = {}
check(MDADDiagnostics.copyLatestPath(0) == true, "copy latest works while writer is active")
checkEq(readerCalls, readsBeforeLiveCopy, "live copy bypasses locked file reader")
checkEq(clipText, "C:/Zomboid/Lua/MinidoracatAutoDrive/Telemetry/session-001.log",
    "active latest abs path")
checkEq(halos[#halos] and halos[#halos].kind, "good", "active copy Halo good")
nowMs = 51000
MDADDiagnostics.stop(0, "end")
lockLiveReads = false
check(MDADDiagnostics.copyLatestPath(0) == true, "copy latest still works after close")

--------------------------------------------------------------------------------
scenario("main menu closes writer, flushes tail, and frees runtime session")
resetFs()
nowMs = 55000
checkEq(MDADDiagnostics.start(0, nil, profile), true, "menu scenario starts")
nowMs = 55100
MDADDiagnostics.sample(0, nowMs, 5, 6, 0, 10, 10, 20, 0, 0, 0, 0,
    "follow", 1, false, nil)
local closesBeforeMenu = writerCloses
fireMainMenu()
body = files[sessionPath(1)] or ""
check(string.find(body, '"r":"menu"', 1, true) ~= nil, "menu writes end reason")
check(writerCloses > closesBeforeMenu, "menu closes active writer")
checkEq(MDADDiagnostics.sample(0, nowMs + 100, 1, 1, 0, 0, 0, 0,
    0, 0, 0, 0, "follow", 1, false, nil), false,
    "menu removes runtime diagnostics session")
nowMs = 56000
checkEq(MDADDiagnostics.start(0, nil, profile), true, "new session starts after menu cleanup")
MDADDiagnostics.stop(0, "end")
--------------------------------------------------------------------------------
scenario("explicit diagnostics failure records error reason, log, and Halo")
do
    resetFs()
    loadProd()
    nowMs = 56500
    checkEq(MDADDiagnostics.start(0, nil, profile), true, "failure scenario starts")
    halos = {}
    local originalPrint = print
    local logged = {}
    print = function(...)
        logged[#logged + 1] = tostring((select(1, ...)))
    end
    local okFail, handled = pcall(MDADDiagnostics.fail, 0,
        "physics collection failed: velocity-read")
    print = originalPrint
    check(okFail and handled == true, "failure boundary handles the active session")
    local failBody = files[sessionPath(1)] or ""
    check(string.find(failBody, '"r":"error"', 1, true) ~= nil,
        "session footer records error")
    checkEq(indexRow(1) and indexRow(1).reason, "error",
        "session index records error")
    checkEq(halos[#halos] and halos[#halos].kind, "bad",
        "diagnostics failure is visible through Halo")
    check(string.find(table.concat(logged, "\n"), "velocity-read", 1, true) ~= nil,
        "console log preserves actionable failure detail")
    checkEq(MDADDiagnostics.sample(0, nowMs + 100, 1, 1, 0, 0, 0, 0,
        0, 0, 0, 0, "follow", 1, false, nil), false,
        "failed diagnostics session is no longer live")
end


--------------------------------------------------------------------------------
scenario("start handshake is transactional and detects silent PrintWriter loss")
resetFs()
loadProd()
nowMs = 57000
failOpenAt = 2
checkEq(MDADDiagnostics.start(0, nil, profile), false,
    "append reopen failure rejects start")
checkEq(files[sessionPath(1)], "", "failed start truncates uncommitted header")
failOpenAt = nil
checkEq(MDADDiagnostics.start(0, nil, profile), true,
    "recovered writer immediately reuses slot 1")
check(string.find(files[sessionPath(1)] or "", '"slot":1', 1, true) ~= nil,
    "reused slot has committed header")
MDADDiagnostics.stop(0, "end")

writerCalls = 0
writerOpens = {}
nowMs = 57500
failOpenAt = 3
checkEq(MDADDiagnostics.start(0, nil, profile), false,
    "manifest writer failure rejects otherwise durable start")
failOpenAt = nil
writerCalls = 0
writerOpens = {}
loadProd()
nowMs = 57600
checkEq(MDADDiagnostics.start(0, nil, profile), true,
    "valid old manifest keeps aborted slot reusable after reload")
check(string.find(files[sessionPath(2)] or "", '"slot":2', 1, true) ~= nil,
    "recovered start commits into the same free slot")
MDADDiagnostics.stop(0, "end")

resetFs()
loadProd()
nowMs = 58000
silentDrop = true
checkEq(MDADDiagnostics.start(0, nil, profile), false,
    "non-throwing lost write fails durability readback")
checkEq(halos[#halos] and halos[#halos].kind, "bad",
    "silent durability failure is visible")
silentDrop = false
checkEq(MDADDiagnostics.start(0, nil, profile), true,
    "slot remains reusable after silent start failure")
MDADDiagnostics.stop(0, "end")

resetFs()
loadProd()
nowMs = 59000
local badProfile = setmetatable({}, {
    __index = function() error("profile-read") end,
})
checkEq(MDADDiagnostics.start(0, nil, badProfile), false,
    "profile encoding failure rejects start without escaping")
checkEq(MDADDiagnostics.start(0, nil, profile), true,
    "profile encoding failure leaves slot reusable")
MDADDiagnostics.stop(0, "end")

--------------------------------------------------------------------------------
scenario("manifest recovery by scanning fixed headers")
resetFs()
nowMs = 60000
files["MinidoracatAutoDrive/Telemetry/manifest.txt"] = "not\ta\tmanifest\n"
files[sessionPath(3)] = '{"v":1,"t":"h","slot":3,"ts":60000,"ret":7,"build":"","profile":null}\n'
MDADDiagnostics.start(0, nil, profile)
nowMs = 61000
MDADDiagnostics.stop(0, "end")
check(files[sessionPath(1)] ~= nil and files[sessionPath(1)] ~= "", "allocates free slot 1")
check(string.find(files[sessionPath(3)], '"slot":3', 1, true) ~= nil,
    "occupied slot 3 header kept")
local man = files["MinidoracatAutoDrive/Telemetry/manifest.txt"] or ""
check(string.find(man, "1\t", 1, true) ~= nil, "rewrote manifest TSV")

--------------------------------------------------------------------------------
scenario("slot reuse: retention, clock rollback; full ring overwrites oldest")
resetFs()
days = 1
nowMs = 100000
local n = 1
while n <= 64 do
    nowMs = 100000 + n
    MDADDiagnostics.start(0, nil, profile)
    MDADDiagnostics.stop(0, "end")
    n = n + 1
end
checkEq(sessionFiles(), 64, "64 fixed slots filled")
local first = files[sessionPath(1)]
nowMs = 100000 + 65
-- 2026-09-02 使用者裁定「滿了照樣寫」：全槽都在保留期內時覆蓋 started 最舊
-- 的槽（slot 1），不再拒寫。truncate 驗證與 fail-closed 家規不變。
checkEq(MDADDiagnostics.start(0, nil, profile), true,
    "full ring overwrites the oldest slot instead of refusing")
MDADDiagnostics.sample(0, nowMs, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, "follow", 1, false, nil)
MDADDiagnostics.stop(0, "end")
check(files[sessionPath(1)] ~= first, "oldest slot content replaced")
check(string.find(files[sessionPath(1)] or "", '"t":"h"', 1, true) ~= nil,
    "overwritten slot starts with a fresh header")
checkEq(sessionFiles(), 64, "overwrite never grows past 64 files")
nowMs = 100000 + DAY_MS + 10000
MDADDiagnostics.start(0, nil, profile)
nowMs = nowMs + 1000
MDADDiagnostics.stop(0, "end")
checkEq(sessionFiles(), 64, "reuse never grows past 64 files")


resetFs()
days = 7
nowMs = 9e12
MDADDiagnostics.start(0, nil, profile)
MDADDiagnostics.stop(0, "end")
local future = files[sessionPath(1)]
nowMs = 2000
MDADDiagnostics.start(0, nil, profile)
MDADDiagnostics.stop(0, "end")
check(files[sessionPath(1)] ~= future, "clock rollback treats future stamp as expired")
check(string.find(files[sessionPath(1)] or "", '"ts":2000', 1, true) ~= nil,
    "rollback reuses slot 1 at the rolled-back clock")

--------------------------------------------------------------------------------
scenario("size cap 2MiB, writer nil/errors stop diagnostics only")
resetFs()
days = 7
nowMs = 70000
MDADDiagnostics.start(0, nil, profile)
local big = string.rep("x", 8000)
local ei = 1
while ei <= 400 do
    nowMs = 70000 + ei * 1000
    MDADDiagnostics.event(0, big)
    ei = ei + 1
end
local capBody = files[sessionPath(1)] or ""
check(#capBody <= 2097152, "session file stays within 2MiB")
local capLen = #capBody
nowMs = nowMs + 1000
MDADDiagnostics.event(0, big)
checkEq(MDADDiagnostics.sample(0, nowMs, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0,
    "follow", 1, false, nil), false, "size cap reports inactive")
checkEq(#(files[sessionPath(1)] or ""), capLen, "size cap stops further writes")
MDADDiagnostics.stop(0, "end")

resetFs()
loadProd()
failWriter = true
nowMs = 80000
checkEq(MDADDiagnostics.start(0, nil, profile), false, "nil writer rejects start")
checkEq(halos[#halos] and halos[#halos].kind, "bad", "nil writer failure is visible")
checkEq(sessionFiles(), 0, "nil writer does not keep a session file")
failWriter = false
throwWrite = true
checkEq(MDADDiagnostics.start(0, nil, profile), false, "throwing writer rejects start")
checkEq(MDADDiagnostics.sample(0, 80100, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0,
    "follow", 1, false, nil), false, "failed writer leaves no live session")
throwWrite = false

--------------------------------------------------------------------------------
scenario("session index: raw epoch rows, occupied-only, bounded 64, retention clears")
resetFs()
loadProd()
days = 7
nowMs = 1788113696982
checkEq(MDADDiagnostics.start(0, nil, profile), true, "index scenario starts")
local irow = indexRow(1)
check(irow ~= nil, "index carries a row for the committed slot")
if irow then
    checkEq(irow.startTs, 1788113696982, "startTs is raw epoch ms")
    checkEq(irow.endTs, 0, "a live session has endTs 0")
    checkEq(irow.reason, "active", "committed start records active")
    checkEq(irow.file, "session-001.log", "row names its session file")
    check(irow.bytes > 0, "row carries the committed header bytes")
    check(string.find(irow.raw, ":", 1, true) == nil, "no clock formatting in the index")
    check(string.find(irow.raw, "+", 1, true) == nil, "no timezone offset in the index")
end
checkEq(#indexRows(), 1, "index lists occupied slots only")
nowMs = 1788113900123
MDADDiagnostics.stop(0, "arrive")
irow = indexRow(1)
check(irow ~= nil, "a stopped slot stays in the index")
if irow then
    checkEq(irow.endTs, 1788113900123, "stop writes the raw epoch endTs")
    checkEq(irow.reason, "arrive", "stop reason lands in the index")
    check(irow.bytes > 0, "stop refreshes the byte count")
end

resetFs()
loadProd()
days = 1
local idxN = 1
while idxN <= 64 do
    nowMs = 2000000 + idxN
    MDADDiagnostics.start(0, nil, profile)
    MDADDiagnostics.stop(0, "end")
    idxN = idxN + 1
end
checkEq(#indexRows(), 64, "index never grows past the 64 fixed slots")
nowMs = 2000000 + DAY_MS + 5000
MDADDiagnostics.start(0, nil, profile)
MDADDiagnostics.stop(0, "end")
checkEq(#indexRows(), 1, "retention cleanup drops expired rows from the index")
checkEq(indexRows()[1] and indexRows()[1].slot, 1, "the reused slot is the only row left")

resetFs()
loadProd()
days = 1
nowMs = 3000000
MDADDiagnostics.start(0, nil, profile)
MDADDiagnostics.stop(0, "end")
checkEq(#indexRows(), 1, "one recorded session before expiry")
nowMs = 3000000 + DAY_MS + 1000
failPath = sessionPath(1)
checkEq(MDADDiagnostics.start(0, nil, profile), true,
    "unwritable expired slot is skipped for the next free slot")
failPath = nil
MDADDiagnostics.stop(0, "end")
checkEq(#indexRows(), 2, "failed retention keeps the old row visible and adds slot 2")
check(indexRow(1) ~= nil and #(files[sessionPath(1)] or "") > 0,
    "untruncated coordinate log remains indexed")
checkEq(indexRow(2) and indexRow(2).slot, 2, "new session uses slot 2")

--------------------------------------------------------------------------------
scenario("index recovery: reason survives reload; stale active becomes interrupted")
resetFs()
loadProd()
days = 7
nowMs = 4000000
checkEq(MDADDiagnostics.start(0, nil, profile), true, "reason recovery scenario starts")
nowMs = 4001000
MDADDiagnostics.stop(0, "UI_MinidoracatAutoDrive_Stuck")
checkEq(indexRow(1) and indexRow(1).reason, "UI_MinidoracatAutoDrive_Stuck",
    "translation-key reasons survive the TSV")
local stoppedEnd = indexRow(1) and indexRow(1).endTs
local stoppedBytes = indexRow(1) and indexRow(1).bytes
files[MANIFEST_PATH] = "corrupt\n"
loadProd()
nowMs = 4002000
checkEq(MDADDiagnostics.start(0, nil, profile), true,
    "index restores a stopped slot when manifest is corrupt")
checkEq(indexRow(1) and indexRow(1).reason, "UI_MinidoracatAutoDrive_Stuck",
    "recovery preserves the old reason")
checkEq(indexRow(1) and indexRow(1).endTs, stoppedEnd,
    "recovery preserves the old endTs")
checkEq(indexRow(1) and indexRow(1).bytes, stoppedBytes,
    "recovery preserves the old durable bytes")
checkEq(indexRow(2) and indexRow(2).reason, "active", "the new session is the active row")
nowMs = 4003000
MDADDiagnostics.stop(0, "end")

resetFs()
loadProd()
nowMs = 5000000
checkEq(MDADDiagnostics.start(0, nil, profile), true, "crash simulation starts")
local headerBytes = indexRow(1) and indexRow(1).bytes or 0
nowMs = 5061000
checkEq(MDADDiagnostics.sample(0, nowMs, 1, 1, 0, 5, 5, 9, 0, 0, 0, 0,
    "follow", 1, false, nil), true, "60s sample checkpoint remains live")
local checkpointBytes = indexRow(1) and indexRow(1).bytes or 0
check(checkpointBytes > headerBytes, "periodic checkpoint persists newer durable bytes")
loadProd() -- 沒有 stop：模擬當掉／強制關閉
nowMs = 5062000
checkEq(MDADDiagnostics.start(0, nil, profile), true, "session after a crash starts")
checkEq(indexRow(1) and indexRow(1).reason, "interrupted",
    "an active row with no live session recovers as interrupted")
checkEq(indexRow(1) and indexRow(1).bytes, checkpointBytes,
    "crash recovery keeps the last durable checkpoint bytes")
MDADDiagnostics.stop(0, "end")

resetFs()
loadProd()
nowMs = 6000000
MDADDiagnostics.start(0, nil, profile)
nowMs = 6001000
MDADDiagnostics.stop(0, "menu")
files[INDEX_PATH] = nil
loadProd()
nowMs = 6002000
checkEq(MDADDiagnostics.start(0, nil, profile), true, "start works without an index file")
checkEq(indexRow(1) and indexRow(1).reason, "menu",
    "a missing index falls back to the last end record of the newest slot")
MDADDiagnostics.stop(0, "end")

--------------------------------------------------------------------------------
scenario("index write failure never takes down a durable session")
resetFs()
loadProd()
nowMs = 7000000
failPath = INDEX_PATH
checkEq(MDADDiagnostics.start(0, nil, profile), true,
    "index failure does not reject an otherwise durable start")
checkEq(MDADDiagnostics.sample(0, 7000000, 1, 1, 0, 5, 5, 9, 0, 0, 0, 0,
    "follow", 1, false, nil), true, "the session keeps recording without an index")
nowMs = 7001000
MDADDiagnostics.stop(0, "end")
check(string.find(files[sessionPath(1)] or "", '"r":"end"', 1, true) ~= nil,
    "session data still ends durably")
checkEq(files[INDEX_PATH], nil, "no index file was produced")
failPath = nil

resetFs()
loadProd()
nowMs = 7020000
checkEq(MDADDiagnostics.start(0, nil, profile), true,
    "stale-active index scenario starts with a durable index")
checkEq(indexRow(1) and indexRow(1).reason, "active",
    "the initial index row records an active session")
failPath = INDEX_PATH
nowMs = 7021000
MDADDiagnostics.stop(0, "arrive")
checkEq(indexRow(1) and indexRow(1).reason, "active",
    "failed index finalization leaves the earlier active row on disk")
check(string.find(files[sessionPath(1)] or "", '"r":"arrive"', 1, true) ~= nil,
    "the session footer still records the true final reason")
failPath = nil
loadProd()
nowMs = 7022000
checkEq(MDADDiagnostics.start(0, nil, profile), true,
    "reload repairs a stale active index from manifest and footer")
checkEq(indexRow(1) and indexRow(1).reason, "arrive",
    "a normally closed session is not mislabeled interrupted")
checkEq(indexRow(1) and indexRow(1).endTs, 7021000,
    "repair preserves the manifest final timestamp")
MDADDiagnostics.stop(0, "end")

--------------------------------------------------------------------------------
scenario("final manifest failure stays indexed and self-heals on reload")
resetFs()
loadProd()
nowMs = 7050000
checkEq(MDADDiagnostics.start(0, nil, profile), true, "manifest-finalization scenario starts")
failPath = MANIFEST_PATH
nowMs = 7051000
MDADDiagnostics.stop(0, "arrive")
failPath = nil
local finalizationRow = indexRow(1)
checkEq(finalizationRow and finalizationRow.reason, "arrive",
    "index still commits the final reason when manifest finalization fails")
check(finalizationRow and finalizationRow.bytes > 0,
    "index still commits durable bytes when manifest finalization fails")
local finalizationBytes = finalizationRow and finalizationRow.bytes
loadProd()
nowMs = 7052000
checkEq(MDADDiagnostics.start(0, nil, profile), true,
    "a later start recovers from the newer index row")
checkEq(indexRow(1) and indexRow(1).reason, "arrive",
    "recovery repairs the stale active manifest without losing the reason")
checkEq(indexRow(1) and indexRow(1).bytes, finalizationBytes,
    "recovery repairs the stale active manifest without losing durable bytes")
MDADDiagnostics.stop(0, "end")

--------------------------------------------------------------------------------
scenario("I/O failure reason outranks normal stop and size; durable bytes survive reload")
resetFs()
loadProd()
nowMs = 7100000
checkEq(MDADDiagnostics.start(0, nil, profile), true, "checkpoint failure scenario starts")
local beforeFailureBytes = indexRow(1) and indexRow(1).bytes or 0
failPath = sessionPath(1)
nowMs = 7161000
checkEq(MDADDiagnostics.sample(0, nowMs, 1, 1, 0, 5, 5, 9, 0, 0, 0, 0,
    "follow", 1, false, nil), false, "append reopen failure stops diagnostics")
failPath = nil
local errorRow = indexRow(1)
checkEq(errorRow and errorRow.reason, "error", "checkpoint I/O failure persists error")
checkEq(errorRow and errorRow.endTs, 7161000, "error row records failure timestamp")
check(errorRow and errorRow.bytes > beforeFailureBytes,
    "error row records the last verified durable bytes")
local errorBytes = errorRow and errorRow.bytes
loadProd()
nowMs = 7162000
checkEq(MDADDiagnostics.start(0, nil, profile), true, "reload after I/O failure starts")
checkEq(indexRow(1) and indexRow(1).reason, "error", "error survives reload")
checkEq(indexRow(1) and indexRow(1).bytes, errorBytes, "durable error bytes survive reload")
MDADDiagnostics.stop(0, "end")

resetFs()
loadProd()
nowMs = 7200000
MDADDiagnostics.start(0, nil, profile)
dropPath = sessionPath(1)
nowMs = 7201000
MDADDiagnostics.stop(0, "arrive")
dropPath = nil
checkEq(indexRow(1) and indexRow(1).reason, "error",
    "stop durability failure cannot be mislabeled arrive")

resetFs()
loadProd()
nowMs = 7300000
MDADDiagnostics.start(0, nil, profile)
dropPath = sessionPath(1)
local bigDrop = string.rep("z", 8000)
local dropN = 1
while dropN <= 400 do
    MDADDiagnostics.event(0, bigDrop)
    dropN = dropN + 1
end
dropPath = nil
checkEq(indexRow(1) and indexRow(1).reason, "error",
    "size-full durability failure cannot be mislabeled size")

--------------------------------------------------------------------------------
scenario("copy success uses the shared framework Toast; Halo is the fallback")
resetFs()
loadProd()
nowMs = 8000000
local toasts = {}
MinidoracatUI = { v1 = {
    API_MAJOR = 1,
    CAPABILITIES = { toast = true },
    Toast = { show = function(opts)
        toasts[#toasts + 1] = opts
        return opts
    end },
} }
MDADDiagnostics.start(0, nil, profile)
nowMs = 8001000
MDADDiagnostics.stop(0, "end")
halos = {}
check(MDADDiagnostics.copyLatestPath(0) == true, "copy latest works with the framework")
checkEq(#toasts, 1, "copy latest raises exactly one Toast")
checkEq(toasts[1] and toasts[1].title, "UI_MinidoracatAutoDrive_Options",
    "Toast title resolves through the options translation key")
checkEq(toasts[1] and toasts[1].message, "UI_MinidoracatAutoDrive_TelemetryCopied",
    "Toast message resolves through the copied translation key")
checkEq(#halos, 0, "the shared Toast replaces the good Halo")
check(MDADDiagnostics.copyFolderPath(0) == true, "copy folder works with the framework")
checkEq(#toasts, 2, "the folder button raises a Toast too")

MinidoracatUI.v1.CAPABILITIES.toast = false
halos = {}
check(MDADDiagnostics.copyFolderPath(0) == true, "capability off still copies")
checkEq(#halos, 1, "capability off falls back to exactly one Halo")
checkEq(halos[1] and halos[1].kind, "good", "the capability-off fallback Halo is good")

MinidoracatUI.v1.CAPABILITIES.toast = true
MinidoracatUI.v1.Toast.show = function() error("toast") end
halos = {}
check(MDADDiagnostics.copyFolderPath(0) == true, "a throwing Toast still reports success")
checkEq(#halos, 1, "a throwing Toast falls back to one Halo")
checkEq(halos[1] and halos[1].kind, "good", "the throwing-Toast fallback Halo is good")

MinidoracatUI.v1.Toast.show = function() return nil end
halos = {}
check(MDADDiagnostics.copyFolderPath(0) == true, "a pending or dropped Toast still reports success")
checkEq(#halos, 1, "a nil Toast result falls back to one immediate Halo")
checkEq(halos[1] and halos[1].kind, "good", "the nil-Toast fallback Halo is good")

clipFail = true
halos = {}
check(MDADDiagnostics.copyFolderPath(0) == false, "clipboard failure still reports false")
checkEq(halos[#halos] and halos[#halos].kind, "bad", "failures stay on the bad Halo")
check(MDADDiagnostics.copyReportLink(0) == false, "report link clipboard failure reports false")
checkEq(halos[#halos] and halos[#halos].kind, "bad", "report link failure is a bad Halo")
clipFail = false

-- 回報導航問題：複製固定的 GitHub 表單網址，Toast 走專屬的 ReportLinkCopied 鍵。
MinidoracatUI.v1.Toast.show = function(opts)
    toasts[#toasts + 1] = opts
    return opts
end
toasts = {}
halos = {}
clipText = nil
check(MDADDiagnostics.copyReportLink(0) == true, "report link copies")
checkEq(clipText, "https://github.com/Minidoracat/MinidoracatAutoDriveFor42/issues/new/choose",
    "report link is the GitHub issue chooser")
checkEq(clipText, MDADDiagnostics.REPORT_URL, "REPORT_URL is what gets copied")
checkEq(#toasts, 1, "report link raises one Toast")
checkEq(toasts[1] and toasts[1].message, "UI_MinidoracatAutoDrive_ReportLinkCopied",
    "report Toast uses the report-link translation key, not the path one")
checkEq(#halos, 0, "report Toast replaces the Halo")
MinidoracatUI.v1.CAPABILITIES.toast = false
halos = {}
check(MDADDiagnostics.copyReportLink(0) == true, "report link without Toast still copies")
checkEq(halos[1] and halos[1].kind, "good", "report link falls back to a good Halo")
check(halos[1] and halos[1].text == "UI_MinidoracatAutoDrive_ReportLinkCopied",
    "report fallback Halo resolves the report-link key")
MinidoracatUI = nil

--------------------------------------------------------------------------------
scenario("nearest hard points carry r/x/y for collision analysis")
resetFs()
loadProd()
nowMs = 9000000
MDADDiagnostics.start(0, nil, profile)
local nhS, nhL, nhR, nhX, nhY = {}, {}, {}, {}, {}
local nhi = 1
while nhi <= 3 do
    nhS[nhi] = 10 + nhi
    nhL[nhi] = nhi * 0.125
    nhR[nhi] = 0.6
    nhX[nhi] = 3724 + nhi
    nhY[nhi] = 8388 + nhi
    nhi = nhi + 1
end
-- 第 4 顆只有 x 沒有 y：半個世界座標比沒有更容易誤讀，整組不寫
nhS[4] = 14
nhL[4] = 0.5
nhR[4] = 0.25
nhX[4] = 1
local nsen = {
    hardN = 4, hardS = nhS, hardL = nhL, hardR = nhR, hardX = nhX, hardY = nhY,
    softN = 0, zombieN = 0, corpseN = 0, vehN = 12, movingVeh = true,
    unloaded = false, ready = true, sig = 3, stamp = 21, scanS = 10, roadN = 2,
}
MDADDiagnostics.sample(0, 9000000, 3724, 8388, 0.5, 0.2, 15, 40,
    5.57, 0.1, 0.2, 900, "follow", 2, true, nsen)
nowMs = 9001000
MDADDiagnostics.stop(0, "end")
local nearBody = files[sessionPath(1)] or ""
check(string.find(nearBody, '{"s":1,"l":0.125,"r":0.6,"x":3725,"y":8389}', 1, true) ~= nil,
    "the nearest point serializes s/l/r/x/y together")
checkEq(countNeedle(nearBody, '"r":0.6'), 3, "every point with a radius reports it")
check(string.find(nearBody, '{"s":4,"l":0.5,"r":0.25}', 1, true) ~= nil,
    "half a world coordinate is dropped, radius kept")
check(string.find(nearBody, '"hardR"', 1, true) == nil, "no full sensor R array")
check(string.find(nearBody, '"hardX"', 1, true) == nil, "no full sensor X array")

--------------------------------------------------------------------------------
scenario("sample records plan mode, route/block anchors and control-state flags")
resetFs()
loadProd()
nowMs = 9100000
MDADDiagnostics.start(0, nil, profile)
MDADDiagnostics.sample(0, 9100000, 100, 200, 0.25, 12, 15, 40, 1.5, 0.2, 0.3, 1200,
    "offroad", 2, true, nil, false,
    "offroad-suppress", 123.5, 140.25, 0.8, 1.3, -0.75, 3724, 8388, 17,
    false, true, true, false, true)
MDADDiagnostics.sample(0, 9100500, 101, 201, 0.25, 12, 15, 39, 1.4, 0.1, 0.3, 1200,
    "follow", 2, true, nil, false,
    nil, 124, nil, nil, nil, nil, nil, nil, 18,
    false, false, false, false, false)
nowMs = 9101000
MDADDiagnostics.stop(0, "end")
local exBody = files[sessionPath(1)] or ""
check(string.find(exBody, '"pm":"offroad-suppress"', 1, true) ~= nil, "plan mode recorded")
check(string.find(exBody, '"pm":null', 1, true) ~= nil, "absent plan mode is explicit null")
check(string.find(exBody, '"rs":123.5', 1, true) ~= nil, "route arc length recorded")
check(string.find(exBody, '"bs":140.25', 1, true) ~= nil, "block anchor recorded")
check(string.find(exBody, '"dm":0.8', 1, true) ~= nil, "dodge margin recorded")
check(string.find(exBody, '"dn":1.3', 1, true) ~= nil, "dodge sweep clearance recorded")
check(string.find(exBody, '"rb":-0.75', 1, true) ~= nil, "road-centring bias recorded")
check(string.find(exBody, '"bhx":3724,"bhy":8388', 1, true) ~= nil,
    "sweep hit world point recorded as a pair")
check(string.find(exBody, '"fi":17', 1, true) ~= nil, "follower cursor recorded")
checkEq(countNeedle(exBody, '"bs":'), 1, "an absent block anchor omits the field, not writes 0")
checkEq(countNeedle(exBody, '"dm":'), 1, "an absent margin omits the field")
checkEq(countNeedle(exBody, '"bhx":'), 1, "an absent sweep hit omits the pair")
check(string.find(exBody, '"cr":true', 1, true) ~= nil,
    "the effective 10Hz decision is recorded, not the caller flag")
check(string.find(exBody, '"cr":false', 1, true) ~= nil, "a normal frame records cr false")
check(string.find(exBody, '"bl":false', 1, true) ~= nil, "blocked is written even when false")
check(string.find(exBody, '"dg":true', 1, true) ~= nil, "dodging flag written")
check(string.find(exBody, '"or":true', 1, true) ~= nil, "offroad flag written")
check(string.find(exBody, '"cn":false', 1, true) ~= nil, "corner-latch flag written")
check(string.find(exBody, '"cp":true', 1, true) ~= nil, "coupled-rotation flag written")
check(string.find(exBody, '"cp":false', 1, true) ~= nil,
    "a lateral-push frame records coupled false")

--------------------------------------------------------------------------------
scenario("sample records physical state; missing values omit, bools explicit")
resetFs()
loadProd()
nowMs = 9200000
MDADDiagnostics.start(0, nil, profile)
MDADDiagnostics.sample(0, 9200000, 100, 200, 0.25, 12, 15, 40, 1.5, 0.2, 0.3, 1200,
    "follow", 2, true, nil, false,
    "clear", 10, nil, nil, nil, nil, nil, nil, 1,
    false, false, false, false, false, {
        physicalOffroad = true,
        isBraking = false,
        minWheelSkid = 0.4,
        vLong = 3.2,
        vLat = -0.1,
        engineSpeed = 2200,
        transmissionNumber = 3,
        regulatorSpeed = 15,
        expectedLane = 1.0,
        latDev = 0.5,
        roadState = "band",
        roadLo = -3,
        roadHi = 3,
        unloadedS = 40,
        activeCapReason = "gear",
        capGear = 50,
        capPerception = 85,
        navVersion = 4,
        currentSurfaceId = 1,
        currentSurface = "paved",
        currentSegWidth = 6,
        controlState = "TRACK",
        adaptive = true,
        raining = false,
        returnActive = false,
        returnUnsafe = false,
        returnHold = false,
        returnCapacityFault = false,
        surfaceMismatch = false,
        tractionKey = 1,
        runtimeMass = 1200,
        priorAccel = 2.5, priorBrake = 6, priorLat = 3.5, priorCoast = 0.6,
        coastConfidence = 0.2, coastLower = 0.4,
        safeAccel = 2.2, safeBrake = 5.5, safeLat = 3.1,
        accelConfidence = 0.5, accelLower = 1.9,
        brakeConfidence = 0.25, brakeLower = 4.0,
        yawConfidence = 0.1, yawLower = 2.5,
        steeringKappa = 0.12,
        assistForce = 1234,
        capReturn = 15,
        fullGate = true, gateReason = "clear",
        cmdV = 11.1, cmdA = 0.4, jerkBypass = "visibility",
        curveValid = true, curveKappa = 0.02, curveHardActive = true,
        curveCap = 47, visibilityCap = 52,
        curveVerifiedUntilS = 88, filletN = 2, filletFallbackN = 1,
        dodgeKappa = 0.03, dodgeClearance = 1.2,
        dodgeCurveCap = 38, dodgeClearanceCap = 42,
        dodgeVisibilityCap = 50,
        dodgeSpaceCap = 35, dodgeDesignSpeed = 22,
        dodgeBaseCap = 36, dodgeCapPending = false,
        dodgeSpeedCap = 34, dodgeClass = 1,
        verifyLineReason = "band", proofKappa = 0.04, proofCurveCap = 31,
        laneCurveEnvelope = 26, envelopeBuildLat = 1.2, envelopeBuildCoast = 0.35,
        dodgeBuildReason = "capacity", dodgeBlockReason = "dodge-cap",
        dodgeCommittedLength = 18, stateError = "full-target", invalid = true,
    }, 7, 9, 3, "verify", 2, -1.5, 2.75, "clear", 450, 120,
    0.25, 1.5, true, 123, 456)
MDADDiagnostics.sample(0, 9200500, 101, 201, 0.25, 12, 15, 39, 1.4, 0.1, 0.3, 1200,
    "follow", 2, true, nil, false,
    "clear", 11, nil, nil, nil, nil, nil, nil, 2,
    false, false, false, false, false, {
        physicalOffroad = false,
        expectedLane = 1.0,
        activeCapReason = "sensor",
        capSensor = 15,
    })
MDADDiagnostics.event(0, "target", {
    phase = "change", oldX = 1, oldY = 2, x = 3, y = 4,
    why = "user", tg = 7, navVersion = 4, currentSurface = "paved",
    currentSegWidth = 6, cost = 123.5, avoidPenalty = 0,
})
-- route cutover 原始路線快照＋ready 的 fillet 結果（2026-09-02 玩家 telemetry 定罪缺口）
local srcRoute = {
    pts = { 7426.5, 8275, 7277, 8275, 7277, 8372 },
    segWidth = { 6, 8 }, segSurface = { "paved", "unknown" },
}
MDADDiagnostics.event(0, "route", MDADDiagnostics.routeSource(srcRoute, {
    phase = "cutover", why = "initial", tg = 7, rg = 9, len = 246.5, pts = 3,
}))
MDADDiagnostics.event(0, "route", {
    phase = "ready", why = "initial", tg = 7, rg = 9, len = 240, pts = 40,
    filletN = 1, filletFallbackN = 0, filletBandValid = true,
})
MDADDiagnostics.event(0, "route", {
    phase = "ready", why = "target", tg = 8, rg = 10, len = 7400, pts = 62,
    filletN = 0, filletFallbackN = 60, filletBandValid = true, filletReason = "capacity",
})
local noPts = MDADDiagnostics.routeSource({ len = 5 }, { phase = "cutover" })
local bigRoute = { pts = {}, segWidth = {}, segSurface = {} }
for i = 1, 600 do
    bigRoute.pts[i * 2 - 1], bigRoute.pts[i * 2] = i, 0
    if i < 600 then bigRoute.segWidth[i], bigRoute.segSurface[i] = 8, "paved" end
end
local bigPayload = MDADDiagnostics.routeSource(bigRoute, {})
MDADDiagnostics.event(0, "unstick", {
    phase = "success", eid = 3, attempt = 2, x = 10, y = 20,
    s = 30, d = 3.1, duration = 850, speed = -0.5, rear = "clear",
})
nowMs = 9201000
MDADDiagnostics.stop(0, "end")
local physBody = files[sessionPath(1)] or ""
check(string.find(physBody, '"po":true', 1, true) ~= nil, "physicalOffroad true")
check(string.find(physBody, '"po":false', 1, true) ~= nil, "physicalOffroad false written")
check(string.find(physBody, '"ib":false', 1, true) ~= nil, "isBraking explicit false")
check(string.find(physBody, '"sk":0.4', 1, true) ~= nil, "minWheelSkid recorded")
check(string.find(physBody, '"vl":3.2', 1, true) ~= nil, "vLong recorded")
check(string.find(physBody, '"vt":-0.1', 1, true) ~= nil, "vLat recorded")
check(string.find(physBody, '"es":2200', 1, true) ~= nil, "engineSpeed recorded")
check(string.find(physBody, '"tn":3', 1, true) ~= nil, "transmissionNumber recorded")
check(string.find(physBody, '"rgs":15', 1, true) ~= nil, "regulatorSpeed recorded")
check(string.find(physBody, '"el":1', 1, true) ~= nil, "expectedLane recorded")
check(string.find(physBody, '"ld":0.5', 1, true) ~= nil, "latDev recorded")
check(string.find(physBody, '"rst":"band"', 1, true) ~= nil, "roadState recorded")
check(string.find(physBody, '"rlo":-3', 1, true) ~= nil, "roadLo recorded")
check(string.find(physBody, '"rhi":3', 1, true) ~= nil, "roadHi recorded")
check(string.find(physBody, '"us":40', 1, true) ~= nil, "unloadedS recorded")
check(string.find(physBody, '"acr":"gear"', 1, true) ~= nil, "activeCapReason recorded")
check(string.find(physBody, '"cg":50', 1, true) ~= nil, "capGear recorded")
checkEq(countNeedle(physBody, '"sk":'), 1, "absent skid omits the field, not 0")
checkEq(countNeedle(physBody, '"vl":'), 1, "absent vLong omits the field")
checkEq(countNeedle(physBody, '"ib":'), 1, "absent isBraking omits rather than false")
check(string.find(physBody, '"acr":"sensor"', 1, true) ~= nil, "second sample reason")
check(string.find(physBody, '"csen":15', 1, true) ~= nil, "capSensor recorded")
check(string.find(physBody, '"nv":4', 1, true) ~= nil, "nav version recorded")
check(string.find(physBody, '"surf":"paved"', 1, true) ~= nil, "declared surface recorded")
check(string.find(physBody, '"sw":6', 1, true) ~= nil, "segment width recorded")
check(string.find(physBody, '"ctl":"TRACK"', 1, true) ~= nil, "derived control state recorded")
check(string.find(physBody, '"ad":true', 1, true) ~= nil, "adaptive gate recorded")
check(string.find(physBody, '"rn":false', 1, true) ~= nil, "dry snapshot explicit")
check(string.find(physBody, '"ra":false', 1, true) ~= nil, "RETURN false explicit")
check(string.find(physBody, '"tk":1', 1, true) ~= nil, "traction key recorded")
check(string.find(physBody, '"rh":false', 1, true) ~= nil, "RETURN HOLD false explicit")
check(string.find(physBody, '"rcf":false', 1, true) ~= nil, "RETURN capacity fault false explicit")
check(string.find(physBody, '"rm":1200', 1, true) ~= nil, "runtime mass recorded")
check(string.find(physBody, '"pa":2.5', 1, true) ~= nil, "drive prior recorded")
check(string.find(physBody, '"pco":0.6', 1, true) ~= nil, "coast prior recorded")
check(string.find(physBody, '"ccf":0.2', 1, true) ~= nil, "coast confidence recorded")
check(string.find(physBody, '"sb":5.5', 1, true) ~= nil, "safe brake recorded")
check(string.find(physBody, '"acf":0.5', 1, true) ~= nil, "accel confidence recorded")
check(string.find(physBody, '"bal":4', 1, true) ~= nil, "brake lower bound recorded")
check(string.find(physBody, '"kap":0.12', 1, true) ~= nil, "steering kappa recorded")
check(string.find(physBody, '"af":1234', 1, true) ~= nil,
    "longitudinal assist force recorded")
check(string.find(physBody, '"crt":15', 1, true) ~= nil, "RETURN cap recorded")
check(string.find(physBody, '"fullGate":true', 1, true) ~= nil, "full-speed gate recorded")
check(string.find(physBody, '"gateReason":"clear"', 1, true) ~= nil, "gate reason recorded")
check(string.find(physBody, '"cmdV":11.1', 1, true) ~= nil, "jerk command speed recorded")
check(string.find(physBody, '"cmdA":0.4', 1, true) ~= nil, "jerk command acceleration recorded")
check(string.find(physBody, '"jerkBypass":"visibility"', 1, true) ~= nil, "named jerk bypass recorded")
check(string.find(physBody, '"curveKappa":0.02', 1, true) ~= nil, "curve kappa recorded")
check(string.find(physBody, '"curveValid":true', 1, true) ~= nil,
    "fresh curve-state validity recorded")
check(string.find(physBody, '"curveHardActive":true', 1, true) ~= nil,
    "current-segment curve hard flag recorded")
check(string.find(physBody, '"visibilityCap":52', 1, true) ~= nil, "visibility cap recorded")
check(string.find(physBody, '"filletN":2', 1, true) ~= nil, "fillet count recorded")
check(string.find(physBody, '"dodgeCurveCap":38', 1, true) ~= nil, "dodge curve cap recorded")
check(string.find(physBody, '"dodgeClearanceCap":42', 1, true) ~= nil,
    "dodge clearance cap recorded")
check(string.find(physBody, '"dodgeVisibilityCap":50', 1, true) ~= nil,
    "dodge visibility cap recorded")
check(string.find(physBody, '"laneCurveEnvelope":26', 1, true) ~= nil,
    "actual-lane future curve envelope（brake 反推）recorded")
check(string.find(physBody, '"envelopeBuildCoast":0.35', 1, true) ~= nil,
    "lane envelope snapshot decel（欄名 envelopeBuildCoast 沿用）recorded")
check(string.find(physBody, '"dodgeSpaceCap":35', 1, true) ~= nil, "dodge space cap recorded")
check(string.find(physBody, '"dodgeDesignSpeed":22', 1, true) ~= nil,
    "dodge intended design speed recorded")
check(string.find(physBody, '"dodgeBaseCap":36', 1, true) ~= nil,
    "dodge base cap（telemetry 鏡像）recorded")
check(string.find(physBody, '"dodgeCapPending":false', 1, true) ~= nil,
    "transient dodge cap pending state recorded")
check(string.find(physBody, '"dodgeSpeedCap":34', 1, true) ~= nil, "dodge final cap recorded")
check(string.find(physBody, '"verifyLineReason":"band"', 1, true) ~= nil,
    "proof-line reason recorded")
check(string.find(physBody, '"stateError":"full-target"', 1, true) ~= nil,
    "control invariant stateError recorded")
check(string.find(physBody, '"invalid":true', 1, true) ~= nil,
    "invalid control invariant is explicit, never omitted")
check(string.find(physBody, '"navVersion":4', 1, true) ~= nil,
    "route event additive nav version")
check(string.find(physBody, '"currentSurface":"paved"', 1, true) ~= nil,
    "route event additive surface")
check(string.find(physBody, '"avoidPenalty":0', 1, true) ~= nil,
    "route event additive numeric avoidPenalty zero")
check(string.find(physBody,
    '"src":"7426.5,8275;7277,8275;7277,8372","srcW":"6;8","srcS":"paved;unknown"',
    1, true) ~= nil, "route cutover carries raw points, widths and surfaces")
check(string.find(physBody, '"filletN":1,"filletFallbackN":0,"filletBandValid":true}',
    1, true) ~= nil, "route ready carries fillet result; absent reason omitted")
check(string.find(physBody,
    '"filletN":0,"filletFallbackN":60,"filletBandValid":true,"filletReason":"capacity"',
    1, true) ~= nil, "route ready names capacity fallback")
checkEq(noPts.src, nil, "route without points adds no src field")
checkEq(noPts.phase, "cutover", "routeSource returns the same payload table")
checkEq(select(2, string.gsub(bigPayload.src, ";", "")), 511,
    "oversize route snapshot truncates to 512 points")
checkEq(select(2, string.gsub(bigPayload.srcW, ";", "")), 510,
    "oversize route widths truncate with the points")
check(string.find(physBody, '"tg":7', 1, true) ~= nil, "target generation recorded")
check(string.find(physBody, '"rg":9', 1, true) ~= nil, "route generation recorded")
check(string.find(physBody, '"eid":3', 1, true) ~= nil, "episode id recorded")
check(string.find(physBody, '"ps":"verify"', 1, true) ~= nil, "progress state recorded")
check(string.find(physBody, '"ua":2', 1, true) ~= nil, "attempt recorded")
check(string.find(physBody, '"ban":-1.5', 1, true) ~= nil, "episode ban lane recorded")
check(string.find(physBody, '"ud":2.75', 1, true) ~= nil, "unstick distance recorded")
check(string.find(physBody, '"rear":"clear"', 1, true) ~= nil, "rear status recorded")
check(string.find(physBody, '"rf":450', 1, true) ~= nil, "reverse force recorded")
check(string.find(physBody, '"rms":120', 1, true) ~= nil, "remaining recovery time recorded")
check(string.find(physBody, '"ac":0.25', 1, true) ~= nil, "actual clearance recorded")
check(string.find(physBody, '"pc":1.5', 1, true) ~= nil, "planned clearance recorded")
check(string.find(physBody, '"fb":true', 1, true) ~= nil, "footprint block explicit")
check(string.find(physBody, '"fhx":123', 1, true) ~= nil
    and string.find(physBody, '"fhy":456', 1, true) ~= nil, "footprint hit XY recorded")
check(string.find(physBody,
    '"n":"target","phase":"change","oldX":1,"oldY":2,"x":3,"y":4,"why":"user","tg":7',
    1, true) ~= nil, "named event fields use fixed order")
check(string.find(physBody,
    '"n":"unstick","phase":"success","x":10,"y":20,"eid":3,"attempt":2,"s":30,"d":3.1,"duration":850,"speed":-0.5,"rear":"clear"',
    1, true) ~= nil, "settle completion event records final speed in fixed order")

--------------------------------------------------------------------------------
scenario("header carries game version and activated mods; absent APIs omit the fields")
-- 2026-09-02 玩家 log 復盤：車型 script 名推不出是哪個 MOD／哪一版，主 MOD 與
-- 依賴庫版本只有 console.txt 才有——header 帶 game／mods 一次。
resetFs()
loadProd()
nowMs = 9300000
MDADDiagnostics.start(0, nil, profile)
MDADDiagnostics.stop(0, "end")
local bareHeader = files[sessionPath(1)] or ""
checkEq(countNeedle(bareHeader, '"game":'), 0, "no getCore stub: game field omitted")
checkEq(countNeedle(bareHeader, '"mode":'), 0, "no isClient stub: mode field omitted")
checkEq(countNeedle(bareHeader, '"mods":'), 0, "no getActivatedMods stub: mods field omitted")
check(string.find(bareHeader, '"build":"m57-test","rev":', 1, true) ~= nil,
    "build/rev keep their schema v1 position")

local function javaList(items)
    return {
        size = function() return #items end,
        get = function(_, i) return items[i + 1] end,
    }
end
-- getVersion（Core.java:2871）＝"42.20.4 <git rev>"，修訂號在裡面；getVersionNumber 只有 "42.20"
function getCore() return { getVersion = function() return "42.20.4 a1b2c3d" end } end
function isClient() return true end
function getActivatedMods() return javaList({ "MinidoracatUIFor42", "89volvo200", "MinidoracatAutoDriveFor42" }) end
local modVersions = { MinidoracatUIFor42 = "42.20.4-1.3.0", MinidoracatAutoDriveFor42 = "42.20.4-0.2.1" }
function getModInfoByID(id)
    local v = modVersions[id]
    if v == nil then return nil end
    return { getModVersion = function() return v end }
end
resetFs()
nowMs = 9301000
MDADDiagnostics.start(0, nil, profile)
MDADDiagnostics.stop(0, "end")
local envHeader = files[sessionPath(1)] or ""
check(string.find(envHeader, '"game":"42.20.4 a1b2c3d"', 1, true) ~= nil, "full game version (with revision) recorded")
check(string.find(envHeader, '"mode":"mp"', 1, true) ~= nil, "isClient()=true records mode mp")
check(string.find(envHeader,
    '"mods":"MinidoracatUIFor42@42.20.4-1.3.0;89volvo200@;MinidoracatAutoDriveFor42@42.20.4-0.2.1"',
    1, true) ~= nil, "activated mods recorded in load order; unknown mod info keeps empty version")
check(string.find(envHeader, '"rev":', 1, true) < string.find(envHeader, '"game":', 1, true)
    and string.find(envHeader, '"mods":', 1, true) < string.find(envHeader, '"profile":', 1, true),
    "env stamp sits between rev and profile")
function getActivatedMods() error("boom") end
resetFs()
nowMs = 9302000
checkEq(MDADDiagnostics.start(0, nil, profile), true, "throwing mod API never blocks session start")
MDADDiagnostics.stop(0, "end")
local throwHeader = files[sessionPath(1)] or ""
check(string.find(throwHeader, '"game":"42.20.4 a1b2c3d"', 1, true) ~= nil, "game survives a throwing mods API")
function isClient() return false end
resetFs()
nowMs = 9302500
MDADDiagnostics.start(0, nil, profile)
MDADDiagnostics.stop(0, "end")
check(string.find(files[sessionPath(1)] or "", '"mode":"sp"', 1, true) ~= nil, "isClient()=false records mode sp")
checkEq(countNeedle(throwHeader, '"mods":'), 0, "throwing mods API omits the field")
getCore, getActivatedMods, getModInfoByID, isClient = nil, nil, nil, nil

closeScenario()
print()
print("scenarios " .. scenarios .. ", asserts " .. assertions)
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("all passed")
