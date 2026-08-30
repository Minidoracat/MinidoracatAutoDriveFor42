--[[
MDAD_Diagnostics.lua offline tests: load production module with an in-memory
fake filesystem. Covers allocation-off, slot reuse/retention/clock rollback/
full capacity, size cap, one-file/session, manifest recovery, batching/
checkpoint, escaping, privacy exclusions, and copy paths.
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
local failWriter = false
local failOpenAt = nil
local throwWrite = false
local silentDrop = false
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
    failWriter = false
    failOpenAt = nil
    throwWrite = false
    silentDrop = false
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
    if failWriter or writerCalls == failOpenAt then return nil end
    if not append or files[path] == nil then files[path] = "" end
    return {
        write = function(_, s)
            if throwWrite then error("io") end
            if not silentDrop then files[path] = files[path] .. (s or "") end
        end,
        close = function() writerCloses = writerCloses + 1 end,
    }
end

function getFileReader(path, _)
    readerCalls = readerCalls + 1
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

local function sessionFiles()
    local n = 0
    local path
    for path in pairs(files) do
        if string.find(path, "session%-", 1) then n = n + 1 end
    end
    return n
end

local function sessionPath(i)
    local name
    if i < 10 then name = "session-00" .. i .. ".log"
    else name = "session-0" .. i .. ".log" end
    return "MinidoracatAutoDrive/Telemetry/" .. name
end

local profile = {
    valid = true, fallback = false, scriptName = 'Base.Car"X',
    bodyW = 1.8, bodyL = 4.5, halfW = 0.9, halfL = 2.25, mass = 1200,
    maxSpeed = 70, wheelbase = 2.6, track = 1.5,
    clamp0 = 0.9, clamp30 = 0.64, clampMax = 0.3,
    wheelFriction = 1.2, delta0Safe = 0.72, deltaVSafe = 0.24,
    rMin = 3.2, lookScale = 1.3, rearArm = 2.9, needHalf = 1.4, probeR = 3.5,
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
MDADDiagnostics.event(0, "x", 1, 2, 3, 4)
MDADDiagnostics.stop(0, "end")
checkEq(writerCalls, w0, "no getFileWriter")
checkEq(readerCalls, r0, "no getFileReader")
checkEq(listCalls, l0, "no listFiles")
checkEq(sessionFiles(), 0, "no session files")
check(not MDADDiagnostics.hasLatest(), "hasLatest false")
enabled = true

--------------------------------------------------------------------------------
scenario("sample gates 200ms normal / 100ms critical; events skip the gate")
resetFs()
nowMs = 5000
checkEq(MDADDiagnostics.start(0, nil, profile), true, "enabled start reports active")
MDADDiagnostics.sample(0, 5000, 1, 2, 0, 10, 10, 50, 0, 0, 0, 0, "follow", 1, false, nil)
MDADDiagnostics.sample(0, 5100, 1, 2, 0, 10, 10, 50, 0, 0, 0, 0, "follow", 1, false, nil)
MDADDiagnostics.event(0, "ping", 1)
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
    roadC = 0.5,
}
MDADDiagnostics.sample(0, 40000, 10700.25, 9800.5, 1.2, 33, 30, 12, 0.4, 8, 0.2, 1,
    "follow", 2, true, sen)
MDADDiagnostics.sample(0, 40200, 10700.25, 9800.5, 1.2, 33, 30, 12, 0.4, 8, 0.2, 1,
    "follow", 2, true, sen)
MDADDiagnostics.event(0, 'a"b\\c' .. string.char(1), "ok", 2)
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
check(string.find(body, '"x":10700.25', 1, true) ~= nil, "opt-in absolute x allowed")
check(string.find(body, "username", 1, true) == nil, "no username")
check(string.find(body, "steamId", 1, true) == nil, "no steamId")
check(string.find(body, "SteamID", 1, true) == nil, "no SteamID")
check(string.find(body, "chat", 1, true) == nil, "no chat")
check(string.find(body, "modlist", 1, true) == nil, "no modlist")
check(string.find(body, '"hardX"', 1, true) == nil, "no full sensor world X")
check(string.find(body, '"hardY"', 1, true) == nil, "no full sensor world Y")
check(string.find(body, '"hardS"', 1, true) == nil, "no full sensor S array")
check(countNeedle(body, '"near":') == 1, "near list only when stamp changes")
check(countNeedle(body, '{"s":') <= 8, "at most 8 near records")
check(string.find(body, '"hardN":12', 1, true) ~= nil, "sensor aggregate kept")

--------------------------------------------------------------------------------
scenario("copy latest/folder absolute paths and Halo")
resetFs()
nowMs = 50000
check(not MDADDiagnostics.hasLatest(), "no latest before a session")
check(MDADDiagnostics.copyLatestPath(0) == false, "copy latest fails")
checkEq(halos[#halos] and halos[#halos].kind, "bad", "latest miss is Halo bad")
check(MDADDiagnostics.copyFolderPath(0) == true, "folder copy works empty")
checkEq(clipText, "C:/Zomboid/Lua/MinidoracatAutoDrive/Telemetry", "folder abs path")
MDADDiagnostics.start(0, nil, profile)
nowMs = 51000
MDADDiagnostics.stop(0, "end")
check(MDADDiagnostics.hasLatest() == true, "hasLatest after session")
halos = {}
check(MDADDiagnostics.copyLatestPath(0) == true, "copy latest ok")
checkEq(clipText, "C:/Zomboid/Lua/MinidoracatAutoDrive/Telemetry/session-001.log",
    "latest abs path")
checkEq(halos[#halos] and halos[#halos].kind, "good", "latest copy Halo good")

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
scenario("slot reuse after retention and clock rollback; protected-full refuse")
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
checkEq(MDADDiagnostics.start(0, nil, profile), false,
    "protected-full start reports inactive")
MDADDiagnostics.sample(0, nowMs, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, "follow", 1, false, nil)
MDADDiagnostics.stop(0, "end")
checkEq(files[sessionPath(1)], first, "protected-full does not reuse slot 1")
local sawFull = false
local hi2 = 1
while hi2 <= #halos do
    if halos[hi2].kind == "bad" then sawFull = true end
    hi2 = hi2 + 1
end
check(sawFull, "visible Halo when slots are full")
nowMs = 100000 + DAY_MS + 10000
MDADDiagnostics.start(0, nil, profile)
nowMs = nowMs + 1000
MDADDiagnostics.stop(0, "end")
check(string.find(files[sessionPath(1)] or "", '"t":"h"', 1, true) ~= nil,
    "expired slot truncated and reused")
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

closeScenario()
print()
print("scenarios " .. scenarios .. ", asserts " .. assertions)
if failures > 0 then
    print(failures .. " failed")
    os.exit(1)
end
print("all passed")
