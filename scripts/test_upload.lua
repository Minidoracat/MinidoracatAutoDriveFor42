-- test_upload.lua — 伺服器診斷上傳：client/MDAD_Upload.lua＋server/MDAD_UploadServer.lua
-- 以真程式碼跑（假 PZ 全域；sendClientCommand 直接轉給伺服器模組，模擬網路）。
-- 執行：lua scripts/test_upload.lua（repo 根目錄）

local MEDIA = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua/"

local assertions, failures, scenarios = 0, 0, 0
local function check(ok, label)
    assertions = assertions + 1
    if not ok then
        failures = failures + 1
        print("  [FAIL] " .. label)
    end
end
local function checkEq(a, b, label)
    check(a == b, label .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end
local function scenario(title)
    scenarios = scenarios + 1
    print("scenario " .. scenarios .. ": " .. title)
end

-- ---------------------------------------------------------------- 假 PZ 全域
local files = {}
local nowMs = 1000000
local client = true
local sandbox = { DiagnosticsUpload = true, DiagnosticsUploadMaxMB = 2048 }
local share = true
local halos = {}
local sent = {}           -- 每一塊的 { at, args }
local serverUser = "玩家/One:?"

function getTimestampMs() return nowMs end
function isClient() return client end
function isServer() return false end
function getText(k) return k end
function getMyDocumentFolder() return "C:/Zomboid" end
function getFileSeparator() return "/" end

-- 引擎只允許這幾種副檔名（LuaManager.java:1034、6729-6765），其餘回 nil。
local ALLOWED_EXT = { ini = true, cfg = true, txt = true, log = true, json = true }
function getFileWriter(path, _, append)
    if not ALLOWED_EXT[string.match(path, "%.(%w+)$") or ""] then return nil end
    if not append or files[path] == nil then files[path] = "" end
    return {
        write = function(_, s) files[path] = files[path] .. s end,
        close = function() end,
    }
end
function getFileReader(path)
    local content = files[path]
    if content == nil then return nil end
    local pos = 1
    return {
        readLine = function()
            if pos > #content then return nil end
            local i = string.find(content, "\n", pos, true)
            local line
            if i then line = string.sub(content, pos, i - 1); pos = i + 1
            else line = string.sub(content, pos); pos = #content + 1 end
            return line
        end,
        close = function() end,
    }
end

local player0 = { getUsername = function() return serverUser end }
function getSpecificPlayer(pn) if pn == 0 then return player0 end return nil end
HaloTextHelper = {
    addText = function(_, t) halos[#halos + 1] = t end,
    addGoodText = function(_, t) halos[#halos + 1] = t end,
    addBadText = function(_, t) halos[#halos + 1] = t end,
}

local handlers = {}
Events = setmetatable({}, { __index = function(t, k)
    local e = { Add = function(fn) handlers[k] = handlers[k] or {}; handlers[k][#handlers[k] + 1] = fn end }
    rawset(t, k, e)
    return e
end })
local function fire(name)
    local list = handlers[name] or {}
    for i = 1, #list do list[i]() end
end

function require() end

MDAD = {
    MOD_ID = "MinidoracatAutoDriveFor42",
    BUILD = "test-build",
    Drive = { REV = "0924t", isActive = function() return activeDrive end },
    HUD = {
        telemetryEnabled = function() return false end,
        shareDiagnostics = function() return share end,
    },
}
activeDrive = false
function MDAD.sandbox(name, default)
    local v = sandbox[name]
    if v == nil then return default end
    return v
end
MDAD.CMD_DIAG_UPLOAD = "DiagUpload"

local function copy(t)
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    return o
end

-- 網路：客戶端送出的表逐欄複製後交給伺服器（TableNetworkUtils 只傳字串／數字／布林）
function sendClientCommand(player, module, command, args)
    checkEq(module, MDAD.MOD_ID, "module id")
    checkEq(command, MDAD.CMD_DIAG_UPLOAD, "command")
    sent[#sent + 1] = { at = nowMs, args = copy(args) }
    MDADUploadServer.receive(player0, copy(args))
end

local function loadFile(rel)
    local fn, err = loadfile(MEDIA .. rel)
    if not fn then error(err) end
    fn()
end

client = false
loadFile("server/MDAD_UploadServer.lua")
client = true
loadFile("client/MDAD_Diagnostics.lua")
loadFile("client/MDAD_Upload.lua")
local D, U, S = MDADDiagnostics, MDADUpload, MDADUploadServer

-- ---------------------------------------------------------------- 輔助
local profile = { scriptName = "Base.CarNormal", mass = 1200, halfW = 0.9, halfL = 2.3 }
local x = 100

local function sample(opts)
    opts = opts or {}
    x = x + (opts.speed or 30) / 3.6 * 0.2
    local phys = opts.phys or { capReason = opts.cap or "profile", frameMs = 16 }
    return D.sample(0, nowMs, x, 200, 0, opts.speed or 30, opts.target or 40, 500, opts.lat or 0.1,
        0.02, 0.1, 0, opts.mode or "follow", 3, true, nil, false,
        "clear", 10, nil, nil, nil, 0, nil, nil, 5,
        opts.blocked == true, false, false, false, false, phys,
        1, 1, 0, "ok", 0, false, nil, nil, 0, 0, 2.0, 2.0, opts.contact == true, nil, nil)
end

-- 以 200ms 取樣推進 ms；每 100ms 也跑一次上傳節奏
local function drive(ms, opts)
    local stop = nowMs + ms
    while nowMs < stop do
        nowMs = nowMs + 100
        U.tick()
        if nowMs % 200 == 0 then sample(opts) end
    end
end

local function pump(ms)
    local stop = nowMs + ms
    while nowMs < stop do
        nowMs = nowMs + 100
        U.tick()
    end
end

local ROOT = "MinidoracatAutoDrive/Uploads/"
local function folderPath() return ROOT .. "玩家_One__/" end

local function indexRows(kind)
    local out = {}
    local content = files[ROOT .. "index.txt"] or ""
    for line in string.gmatch(content, "[^\n]+") do
        if string.sub(line, 1, 2) == (kind or "C") .. "\t" then out[#out + 1] = line end
    end
    return out
end

local function field(row, n)
    local i = 0
    for v in string.gmatch(row .. "\t", "([^\t]*)\t") do
        i = i + 1
        if i == n then return v end
    end
end

local function count(s, needle)
    local n, pos = 0, 1
    while true do
        local i = string.find(s or "", needle, pos, true)
        if not i then return n end
        n, pos = n + 1, i + 1
    end
end

local function start()
    nowMs = math.floor(nowMs / 200) * 200
    return D.start(0, nil, profile)
end

-- ================================================================ 情境
scenario("off paths: sandbox off / opt-out / single-player never record or send")
sandbox.DiagnosticsUpload = false
checkEq(start(), false, "sandbox off: no session")
sandbox.DiagnosticsUpload = true
share = false
checkEq(start(), false, "opt-out: no session")
share = true
client = false
checkEq(start(), false, "single-player: no session")
client = true
checkEq(#sent, 0, "nothing sent")
local fileCount = 0
for _ in pairs(files) do fileCount = fileCount + 1 end
checkEq(fileCount, 0, "no file IO on client or server")

scenario("contact clip: header + route + pre-window + post; chunked and paced; one notice")
checkEq(start(), true, "upload session starts without local telemetry")
checkEq(#halos, 1, "first drive shows the participation notice")
D.event(0, "route", { phase = "cutover", src = "1,2;3,4", srcW = "5", srcS = "asphalt" })
D.event(0, "dyn", { phase = "dirty", why = "key" })
drive(40000)
D.event(0, "replan", { phase = "x" })
local tContact = nowMs + 200
drive(200, { contact = true })
drive(4000)
checkEq(#sent, 0, "still inside post window: nothing sent")
drive(2000)
pump(60000)
local clipRows = indexRows("C")
checkEq(#clipRows, 1, "one clip indexed")
local row = clipRows[1] or ""
checkEq(field(row, 7), "contact", "kind contact")
checkEq(field(row, 8), "2", "priority 2")
checkEq(field(row, 14), serverUser, "user column is the actor")
local clip = files[folderPath() .. "clip-01.log"] or ""
checkEq(tonumber(field(row, 6)), #clip, "indexed bytes match file")
check(string.find(clip, '^{"t":"clip"') ~= nil, "clip starts with meta line")
checkEq(count(clip, '"t":"h"'), 1, "header included once")
checkEq(count(clip, '"src":"1,2;3,4"'), 1, "route source included once")
checkEq(count(clip, '"n":"dyn"'), 1, "whole-drive event before window kept")
checkEq(count(clip, '"n":"replan"'), 1, "replan only inside the window")
local firstTs, lastTs = nil, nil
for ts in string.gmatch(clip, '{"t":"s","ts":(%d+)') do
    ts = tonumber(ts)
    firstTs = firstTs or ts
    lastTs = ts
end
check(firstTs and firstTs >= tContact - U.PRE_MS and firstTs <= tContact - U.PRE_MS + 200,
    "pre window starts 30s before the contact")
check(lastTs and lastTs >= tContact + 5000, "post window continues after the contact")
local maxChunk, minGap = 0, 1e9
for i = 1, #sent do
    local d = sent[i].args.data or ""
    if #d > maxChunk then maxChunk = #d end
    if i > 1 then
        local gap = sent[i].at - sent[i - 1].at
        if gap < minGap then minGap = gap end
    end
end
check(maxChunk <= U.CHUNK, "every chunk <= 10000 chars (32767-byte string limit)")
check(#sent > 1, "clip spans several chunks")
check(minGap >= 500, "at most one packet per 500ms")
D.stop(0, "arrive")
pump(5000)
local sum = files[ROOT .. "summary-1.log"] or ""
checkEq(count(sum, '"t":"sum"'), 1, "summary written")
check(string.find(sum, '^{"srv":%d+,"u":"玩家/One:%?",') ~= nil, "server stamps time and actor")
check(string.find(sum, '"reason":"arrive"', 1, true) ~= nil, "summary keeps end reason")
check(string.find(sum, '"contact":1', 1, true) ~= nil, "summary counts contact")
check(string.find(sum, '"veh":"Base.CarNormal"', 1, true) ~= nil, "summary keeps vehicle")

scenario("takeover: clip only when an anomaly happened in the last 10s")
local before = #indexRows("C")
start()
drive(5000)
D.stop(0, "takeover")
pump(10000)
checkEq(#indexRows("C"), before, "calm takeover: summary only")
start()
drive(4000, { blocked = true })
drive(2000)
D.stop(0, "takeover")
pump(60000)
checkEq(#indexRows("C"), before + 1, "takeover after blocked: clip")
checkEq(field(indexRows("C")[before + 1] or "", 7), "takeover", "kind takeover")

scenario("stuck handback and expected braking")
before = #indexRows("C")
start()
drive(3000, { phys = { forceBrakeLeft = 900, forceBrakeWhy = "arrive" } })
drive(3000)
D.stop(0, "UI_MinidoracatAutoDrive_StopStuck")
pump(60000)
checkEq(#indexRows("C"), before + 1, "arrive brake is not an incident; stuck is")
local stuckRow = indexRows("C")[before + 1] or ""
checkEq(field(stuckRow, 7), "stuck", "kind stuck")
checkEq(field(stuckRow, 8), "1", "priority 1")

scenario("per-drive cap and same-kind cooldown")
nowMs = nowMs + 3600000
before = #indexRows("C")
start()
for _ = 1, 3 do
    drive(200, { contact = true })
    drive(6000)
end
D.stop(0, "arrive")
pump(120000)
checkEq(#indexRows("C"), before + 1, "repeat contacts inside 60s cooldown: one clip")

scenario("server: sandbox off, bad chunks, out-of-order sequence")
local rejected = 0
local function rx(args) if not S.receive(player0, args) then rejected = rejected + 1 end end
sandbox.DiagnosticsUpload = false
rx({ id = 900, q = 1, n = 1, k = "sum", data = '{"t":"sum"}' })
sandbox.DiagnosticsUpload = true
rx({ id = 901, q = 1, n = 1, k = "sum", data = string.rep("x", S.CHUNK_MAX + 1) })
rx({ id = 902, q = 1, n = 2, k = "clip", len = 20, kind = "hack", pri = 1, data = "a" })
rx({ id = 903, q = 1, n = 3, k = "clip", len = 30, kind = "brake", pri = 4, data = "0123456789" })
rx({ id = 903, q = 3, n = 3, k = "clip", data = "0123456789" })
rx({ id = 903, q = 2, n = 3, k = "clip", data = "0123456789" })
rx({ id = 904, q = 1, n = 1, k = "clip", len = 5, kind = "brake", pri = 4, data = "0123456789" })
checkEq(rejected, 6, "sandbox-off, oversize, unknown kind, gap, orphan, over-declared rejected")

scenario("server: per-player 32 slots keep the most important")
S._reset()
for k in pairs(files) do if string.find(k, ROOT, 1, true) == 1 then files[k] = nil end end
local id = 1000
local function clipMsg(kind, pri)
    id = id + 1
    nowMs = nowMs + 1000
    local data = kind .. "-" .. id
    return S.receive(player0, { id = id, q = 1, n = 1, k = "clip", len = #data, kind = kind,
        pri = pri, data = data })
end
for _ = 1, 32 do clipMsg("brake", 4) end
check(clipMsg("stuck", 1), "stuck accepted when full")
local st = S._stats()
local fo = st.folders["玩家_One__"]
local kinds = { brake = 0, stuck = 0 }
local oldestBrakeGone = true
for slot = 1, 32 do
    local c = fo.slots[slot]
    kinds[c.kind] = kinds[c.kind] + 1
    if c.kind == "brake" and string.find(files[folderPath() .. "clip-" .. string.format("%02d", slot) .. ".log"], "brake%-1001") then
        oldestBrakeGone = false
    end
end
checkEq(kinds.stuck, 1, "stuck stored")
checkEq(kinds.brake, 31, "one brake replaced")
check(oldestBrakeGone, "the oldest low-priority clip was replaced")

scenario("server: global cap clears the oldest clip anywhere; restart rebuilds from index")
S.capOverride = 60
serverUser = "Second"
check(clipMsg("contact", 2), "second player's clip accepted")
st = S._stats()
check(st.total <= 60, "total within cap")
check(st.folders["Second"] and st.folders["Second"].slots[1] ~= nil, "new clip kept, old ones cleared")
serverUser = "玩家/One:?"
local liveBefore, totalBefore = st.live, st.total
S.capOverride = nil
S._reset()
S.receive(player0, { id = 5000, q = 1, n = 1, k = "sum", data = '{"t":"sum"}' })
st = S._stats()
checkEq(st.live, liveBefore, "restart: live clips rebuilt from index")
checkEq(st.total, totalBefore, "restart: byte total rebuilt")
checkEq(#indexRows("X"), 0, "restart compacts cleared rows away")
check(files[ROOT .. "Second/clip-01.log"] ~= nil, "second player has own folder")

scenario("main menu drops pending uploads")
start()
drive(200, { contact = true })
drive(6000)
fire("OnMainMenuEnter")
D.stop(0, "menu")
local n0 = #sent
pump(10000)
checkEq(#sent, n0, "nothing sent after main menu")
checkEq(U.pending(0), 0, "outbox empty")

print(string.format("情境 %d 個、斷言 %d 項、失敗 %d", scenarios, assertions, failures))
if failures > 0 then os.exit(1) end
