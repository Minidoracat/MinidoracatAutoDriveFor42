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
local netHold = nil       -- 非 nil：網路先扣住（情境自己決定何時、以什麼節奏送到伺服器）
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

local player0 = { getUsername = function() return serverUser end, getOnlineID = function() return 0 end }
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
    if netHold then netHold[#netHold + 1] = copy(args); return end
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
    return D.sample(0, nowMs, x, 200, opts.heading or 0, opts.speed or 30, opts.target or 40, 500, opts.lat or 0.1,
        0.02, 0.1, 0, opts.mode or "follow", 3, true, opts.sensor, false,
        "clear", opts.rs or 10, nil, nil, nil, 0, nil, nil, 5,
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
-- 1008：takeover phase=resume（讓位恢復）不是接手：異常後 10 秒內恢復也不開 takeover 片段（只有 phase=yield 會）
nowMs = nowMs + 3600000 -- 跨過同 kind 冷卻與每小時上限
before = #indexRows("C")
start()
drive(4000, { blocked = true })
drive(2000)
D.event(0, "takeover", { phase = "resume", ms = 2000 })
drive(2000)
D.stop(0, "button")
pump(60000)
checkEq(#indexRows("C"), before, "takeover resume after blocked: no takeover clip")

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
-- 2026-09-27：拖掛終局（脫開／需要調頭／轉角過不去）也要留片段，否則 TrailerLost 無從定罪
nowMs = nowMs + 3600000 -- 跨過每小時上限
before = #indexRows("C")
start()
drive(3000)
D.stop(0, "UI_MinidoracatAutoDrive_TrailerLost")
pump(60000)
checkEq(#indexRows("C"), before + 1, "trailer lost handback: clip")
local trailerRow = indexRows("C")[before + 1] or ""
checkEq(field(trailerRow, 7), "trailer", "kind trailer")
checkEq(field(trailerRow, 8), "2", "trailer priority 2")
-- 1006：行程模式的交還（TripLost：行程中目標消失、行程 API 失敗）也留片段——單站同義的 LostRoute 是 route，
-- 歸同一類（不新增 kind、伺服器 KINDS 不動）。違規證明：STOP_KIND 拿掉 TripLost＝紅。
nowMs = nowMs + 3600000
before = #indexRows("C")
start()
drive(3000)
D.stop(0, "UI_MinidoracatAutoDrive_TripLost")
pump(60000)
checkEq(#indexRows("C"), before + 1, "trip lost handback: clip")
local tripRow = indexRows("C")[before + 1] or ""
checkEq(field(tripRow, 7), "route", "trip lost files under kind route (same as LostRoute)")
checkEq(field(tripRow, 8), "3", "trip lost priority 3")
-- 1004b：改道請求（不論成敗）留片段，事前窗看得到判堵與寬帶判定（判斷是否太早改道）；交還前沒問的 skip 不留。
-- 違規證明：拿掉 Upload 的 detour 觸發＝第一條紅；skip 也觸發＝第二條紅。
nowMs = nowMs + 3600000
before = #indexRows("C")
start()
drive(3000, { blocked = true })
D.event(0, "detour", { phase = "skip", why = "off" })
drive(3000)
D.stop(0, "button")
pump(60000)
checkEq(#indexRows("C"), before, "detour skip (option off): no clip")
start()
drive(3000, { blocked = true })
D.event(0, "detour", { phase = "auto", why = "noroad", ms = 12000 })
drive(3000)
D.stop(0, "button")
pump(60000)
checkEq(#indexRows("C"), before + 1, "auto detour request: clip")
local detourRow = indexRows("C")[before + 1] or ""
checkEq(field(detourRow, 7), "detour", "kind detour")
checkEq(field(detourRow, 8), "3", "detour priority 3")

scenario("near-standstill brake is not an incident")
before = #indexRows("C")
start()
-- 0924b 正式服：回線待命在 0-1 km/h 觸發的一秒煞車也被收成急煞片段
drive(1000, { speed = 0.5, phys = { forceBrakeLeft = 900, forceBrakeWhy = "return" } })
drive(1000, { speed = 0.5 })
D.stop(0, "button")
pump(60000)
checkEq(#indexRows("C"), before, "standstill return brake: no clip")
start()
drive(1000, { speed = 20, phys = { forceBrakeLeft = 900, forceBrakeWhy = "return" } })
drive(1000)
D.stop(0, "button")
pump(60000)
checkEq(#indexRows("C"), before + 1, "moving return brake: clip")

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

-- 0928a 摘要補欄位：起步越野接線長、前方區域未載入等待（次數／毫秒）、自轉次數（|yaw|>3 上升緣、<1.5 才
-- 重新武裝）、有未載入前緣的毫秒。違規證明：拿掉 spinArmed 重新武裝＝同一次自轉被數兩次（spin 3）紅。
scenario("0928a summary: approach, area wait, spins, unloaded front")
nowMs = nowMs + 3600000
start()
D.event(0, "route", { phase = "ready", approach = 12.34 })
local function ph(extra)
    local t = { capReason = "profile", frameMs = 16 }
    for k, v in pairs(extra) do t[k] = v end
    return { phys = t }
end
drive(1000, ph({ areaWait = true }))
drive(600)
drive(400, ph({ areaWait = true }))
drive(400, ph({ yawRate = 4 }))
drive(400, ph({ yawRate = 2 }))    -- 仍 >1.5：同一次自轉
drive(400, ph({ yawRate = -5 }))   -- 還沒重新武裝：不算新的一次
drive(400, ph({ yawRate = 0.5 }))  -- 重新武裝
drive(400, ph({ yawRate = -3.5 })) -- 第二次
drive(1000, ph({ unloadedS = 40 }))
D.stop(0, "arrive")
pump(5000)
local sumAll = files[ROOT .. "summary-1.log"] or ""
local lastSum = nil
for line in string.gmatch(sumAll, "[^\n]+") do lastSum = line end
lastSum = lastSum or ""
check(string.find(lastSum, '"apr":12.3', 1, true) ~= nil, "summary keeps approach length")
-- 第一筆取樣沒有前一筆可差分（dt 0）：第一段 5 筆只記 800ms，第二段 400ms
check(string.find(lastSum, '"aw":2,"awMs":1200', 1, true) ~= nil,
    "area wait: two episodes, 1200ms (got " .. tostring(string.match(lastSum, '"aw":[^,]*,"awMs":[^,]*')) .. ")")
check(string.find(lastSum, '"spin":2,', 1, true) ~= nil, "spins counted on rising edge with re-arm")
check(string.find(lastSum, '"unlMs":1000', 1, true) ~= nil, "unloaded-front time accumulated")

-- 0929c 摘要：卡頓降速（Driver.updateLowFps 遲滯後的狀態，經 phys.lowFps 帶進每筆取樣）的進入次數與毫秒。
-- 正式服 0.13.1 的 805 趟有 149 趟出現過卡頓降速，舊摘要只有 on／off 事件合計次數，量不到被幀率壓速多久。
-- 違規證明：拿掉上升緣判斷＝每筆都算一次（lf 5）紅。
scenario("0929c summary: low-FPS slowdown episodes and time")
nowMs = nowMs + 3600000
start()
drive(600)
drive(600, ph({ lowFps = true }))
drive(400)
drive(400, ph({ lowFps = true }))
D.stop(0, "arrive")
pump(5000)
sumAll = files[ROOT .. "summary-1.log"] or ""
for line in string.gmatch(sumAll, "[^\n]+") do lastSum = line end
check(string.find(lastSum, '"lf":2,"lfMs":1000', 1, true) ~= nil,
    "low-FPS slowdown: two episodes, 1000ms (got " .. tostring(string.match(lastSum, '"lf":[^,]*,"lfMs":[^,]*')) .. ")")

-- 2026-10-01：片段檔頭帶出事當下的狀態（被截斷時第一塊仍看得到車速）；摘要帶目的地與起步航向（重跑用）；
-- 撞擊（減速度超過一秒鎖輪能給的）自成一類——0.16.0 兩車對撞只被記成「煞車」片段、摘要 contact 0。
-- 違規證明：拿掉撞擊判定＝kind／impact 紅；拿掉檔頭 at＝車速紅；門檻降到 10＝鎖輪也算撞擊紅。
scenario("1001a: impact clip, trigger-time state in the clip head, replay fields in the summary")
nowMs = nowMs + 3600000
before = #indexRows("C")
start()
D.event(0, "route", { phase = "ready", target = "8946.8,11645" })
drive(3000, { speed = 60, heading = 1.25 })
-- 一秒鎖輪 60→51.4 km/h／200ms＝12 m/s²：煞車，不是撞擊
drive(200, { speed = 51.4, phys = { capReason = "arrive", frameMs = 16, forceBrakeLeft = 900, forceBrakeWhy = "arrive" } })
drive(2400, { speed = 51.4 }) -- 隔過同一次撞擊的去重窗，鎖輪若被誤算會多一次
drive(200, { speed = 10, cap = "moving" }) -- 撞上：51→10 km/h／200ms
drive(200, { speed = 2 })
drive(6000, { speed = 0 })
D.stop(0, "arrive")
pump(120000)
checkEq(#indexRows("C"), before + 1, "impact makes a clip")
local impactRow = indexRows("C")[before + 1] or ""
checkEq(field(impactRow, 7), "impact", "kind impact")
checkEq(field(impactRow, 8), "2", "impact is as important as contact")
local impactClip = files[folderPath() .. "clip-" .. string.format("%02d", tonumber(field(impactRow, 5)) or 0) .. ".log"] or ""
local head = string.match(impactClip, "^[^\n]*") or ""
check(string.find(head, '"at":{"spd":10', 1, true) ~= nil, "clip head keeps the speed at the impact (" .. head .. ")")
check(string.find(head, '"cap":"moving"', 1, true) ~= nil, "clip head keeps the cap reason at the impact")
sumAll = files[ROOT .. "summary-1.log"] or ""
for line in string.gmatch(sumAll, "[^\n]+") do lastSum = line end
check(string.find(lastSum, '"impact":1', 1, true) ~= nil, "summary: one impact, the locked-wheel brake is not one")
check(string.find(lastSum, '"target":"8946.8,11645"', 1, true) ~= nil, "summary keeps the destination")
check(string.find(lastSum, '"h0":1.25', 1, true) ~= nil, "summary keeps the starting heading")

-- 1009：第一筆取樣前就交還（起步第一幀判堵交還之類）的趟，摘要起點／終點＝起步車位，不是 0。
-- 違規證明：D.start 不預填車位＝這條紅。
scenario("1009: a drive stopped before its first sample keeps the start position in the summary")
nowMs = math.floor((nowMs + 3600000) / 200) * 200
D.start(0, { getX = function() return 8946.5 end, getY = function() return 11645.25 end }, profile)
D.stop(0, "UI_MinidoracatAutoDrive_StopStuck")
pump(10000)
sumAll = files[ROOT .. "summary-1.log"] or ""
for line in string.gmatch(sumAll, "[^\n]+") do lastSum = line end
check(string.find(lastSum, '"x0":8946.5,"y0":11645.25,"x1":8946.5,"y1":11645.25', 1, true) ~= nil,
    "summary start/end = the car position, not 0 (" .. string.sub(lastSum, 1, 240) .. ")")

-- 2026-10-01：正式服 225 段有 11 段只收到前幾塊（檔長是 10000 的整數倍、index 沒有這一列），其中 8 段同趟
-- 摘要照樣收到＝客戶端送完了。網路重送／伺服器卡頓讓間隔 500ms 送出的塊同一刻到齊，舊的固定 250ms 節流
-- 丟掉後一塊，伺服器依序號放棄整段。違規證明：MDAD_Server 的 UPLOAD_BURST 改 1（＝固定間隔）即紅。
scenario("server throttle: chunks sent 500ms apart but delivered 8 at a time are all kept")
nowMs = nowMs + 3600000
client = false
MDAD.CMD_DEVICE, MDAD.CMD_USAGE = "Device", "Usage"
MDAD.CMD_NAV_USAGE, MDAD.CMD_RECIPE_RESCAN = "NavUsage", "RecipeRescan"
function MDAD.isFiniteInt(n) return type(n) == "number" and n * 0 == 0 and n % 1 == 0 end
loadFile("server/MDAD_Server.lua")
client = true
local onCmd = handlers.OnClientCommand[#handlers.OnClientCommand]
netHold = {}
before = #indexRows("C")
start()
drive(40000)
drive(200, { contact = true })
drive(6000)
D.stop(0, "arrive")
pump(120000)
local held = netHold
netHold = nil
check(#held >= 6, "clip spans several chunks (" .. #held .. ")")
local k = 1
while k <= #held do
    local b = 0
    while b < 8 and k <= #held do
        onCmd(MDAD.MOD_ID, MDAD.CMD_DIAG_UPLOAD, player0, held[k])
        k, b = k + 1, b + 1
    end
    nowMs = nowMs + 4000
end
checkEq(#indexRows("C"), before + 1, "clip indexed although chunks arrived 8 at a time")
local passed = 0
local realReceive = MDADUploadServer.receive
MDADUploadServer.receive = function() passed = passed + 1; return true end
for _ = 1, 20 do
    onCmd(MDAD.MOD_ID, MDAD.CMD_DIAG_UPLOAD, player0, { id = 1, q = 1, n = 1, k = "sum", data = "{}" })
end
MDADUploadServer.receive = realReceive
check(passed < 20, "a flood is still throttled (" .. passed .. " of 20 passed)")

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

-- 1002a 摘要 KPI：舊摘要只有限速理由的時間，車在直路跑到車輛極速時也記成 curve-coast，量不到「多少時間在
-- 最高速」與「慢在哪」。有效上限＝檔位／感知／沙盒／車輛極速／伺服器速限取小；≥0.9×有效上限算貼近上限，其餘依
-- 限速理由記損失（km/h×秒）；入弧次數、入弧超過彎帽 1.15 倍、弧內離期望線 >0.5m；帶內有殭屍時的撞擊；輔助毫秒。
-- 違規證明：有效上限漏取檔位（em 變 120、nm 0）＝nm／em 紅；損失不扣有效上限＝loss 紅；入弧不看上升緣（每筆都算）＝arc 紅。
scenario("1002a summary KPI: time near the effective cap, loss by reason, corners, zombie impacts, assists")
nowMs = nowMs + 3600000
start()
local function kp(extra)
    local t = { capReason = "curve-coast", frameMs = 16, capGear = 60, capPerception = 120, capMax = 120 }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end
drive(2000, { speed = 55, target = 60, phys = kp() })                         -- ≥54＝貼近上限
-- 1005i：第一筆帶預計剩餘的取樣（2s 後）記成 eta0／eta0t；之後的估計不覆寫。違規證明：每筆都覆寫＝eta0 30 紅。
drive(1000, { speed = 40, target = 40, phys = kp({ etaSec = 42.5 }) })        -- 損失 20×1s
drive(400, { speed = 30, target = 25, phys = kp({ curveHardActive = true, curveCap = 25, etaSec = 30 }) }) -- 入弧 30>28.75
drive(400, { speed = 28, target = 25, phys = kp({ curveHardActive = true, curveCap = 25, latDev = 0.7 }) })
drive(400, { speed = 40, target = 60, phys = kp({ capReason = "visibility", accelAssist = 2 }) })
drive(400, { speed = 40, target = 30, phys = kp({ visAssistDecel = 3 }) })
-- 1004：impZ 改看最近一隻離車心（zombieNearS − rs ≤ halfL＋4），fixture 帶 zombieNearS（rs＝10，離 2m）
drive(200, { speed = 40, phys = kp(), sensor = { zombieN = 3, zombieNearS = 12 } })
drive(200, { speed = 20, phys = kp(), sensor = { zombieN = 3, zombieNearS = 12 } }) -- 40→20／200ms＝27.8 m/s²：撞擊
drive(3000, { speed = 0, mode = "unstick", phys = kp() })
D.stop(0, "arrive")
pump(120000)
sumAll = files[ROOT .. "summary-1.log"] or ""
for line in string.gmatch(sumAll, "[^\n]+") do lastSum = line end
local function num(key) return tonumber(string.match(lastSum, '"' .. key .. '":([%d%.%-]+)')) end
checkEq(num("em"), 60, "effective cap is the gear cap (60), not the 120 sandbox/perception")
check(num("nm") == 1800 or num("nm") == 2000, "near-cap time ≈ 2s of 55 km/h at cap 60 (got " .. tostring(num("nm")) .. ")")
check(num("fm") >= 4600 and num("fm") <= 5000, "follow time counted, unstick excluded (got " .. tostring(num("fm")) .. ")")
check(string.find(lastSum, '"loss":{', 1, true) ~= nil, "loss map present")
local lossCurve = tonumber(string.match(lastSum, '"loss":{[^}]*"curve%-coast":(%d+)'))
check(lossCurve ~= nil and lossCurve >= 50 and lossCurve <= 70,
    "curve-coast loss ≈ 20 km/h×1s + arc/assist segments (got " .. tostring(lossCurve) .. ")")
checkEq(num("arc"), 1, "one arc entry (rising edge only)")
checkEq(num("arcOver"), 1, "arc entered at 30 > 1.15×25")
checkEq(num("arcDev"), 1, "arc with |latDev| > 0.5")
checkEq(num("impZ"), 1, "impact with zombies in the band")
checkEq(num("aaMs"), 400, "accel assist time")
checkEq(num("daMs"), 400, "decel assist time")
check(#lastSum < U.CHUNK, "summary still fits one chunk (" .. #lastSum .. ")")
checkEq(num("eta0"), 42.5, "first ETA estimate kept for calibration, later ones do not overwrite it")
local eta0t = num("eta0t")
check(eta0t ~= nil and eta0t >= 2000 and eta0t <= 2200,
    "eta0t = ms from drive start to that first estimate (got " .. tostring(eta0t) .. ")")
check(string.find(sum, '"eta0":null', 1, true) ~= nil, "a drive without any estimate writes eta0 null, not 0")

-- 1004 撞擊誤報（正式服 1002y）：
--  (a) 讓位接手期間不取樣，恢復時拿 5.7 秒前的 90 km/h 跟 0 比、dt 夾成 1 秒＝24.9 m/s²（clip-29）；
--      間隔 1.2 秒、90→0 用原始間隔算是 20.8 m/s²：中間沒取樣就不比。
--  (b) blocked 一秒鎖輪＋本 MOD 中線減速輔助量到 22.9 m/s²，沒碰到東西（clip-11）：本筆或前一筆
--      鎖輪時門檻 25；(c) 沒鎖輪的 22 m/s² 仍是撞擊。
--  (d) impZ 只算車身附近有殭屍的撞擊（clip-01 最近一隻 25m 外也算）；殭屍快照最多舊一輪，撞擊那筆
--      或前一筆近就算（clip-28 撞上那筆的新快照已換成 31m 外的下一隻）。
-- 違規證明：拿掉間隔上限＝(a) 1.2s 紅；改回夾限 dt＝(a) 兩案紅；鎖輪門檻改回 18／拿掉本筆或前一筆的鎖輪判定＝(b) 紅；
-- 門檻抬到 25＝(c) 紅；impZ 改回 zombieN>0／拿掉本筆或前一筆的距離＝(d) 紅。
scenario("1004 impact false positives: sampling gap, locked wheels plus own assist, far zombies")
local function impactDrive(label, steps)
    nowMs = nowMs + 3600000
    start()
    local drive0 = nowMs
    steps()
    D.stop(0, "arrive")
    pump(120000)
    local found = nil
    for k, content in pairs(files) do
        if string.find(k, ROOT .. "summary-", 1, true) == 1 then
            for line in string.gmatch(content, "[^\n]+") do
                if string.find(line, '"drive":' .. string.format("%d", drive0) .. ",", 1, true) then found = line end
            end
        end
    end
    check(found ~= nil, label .. ": summary of this drive found")
    found = found or ""
    return tonumber(string.match(found, '"impact":(%d+)')), tonumber(string.match(found, '"impZ":(%d+)')),
        tonumber(string.match(found, '"tp":(%d+)')), found
end
local locked = { capReason = "blocked", frameMs = 16, forceBrakeLeft = 900, forceBrakeWhy = "blocked" }
local imp = impactDrive("(a) gap", function()
    drive(3000, { speed = 90 })
    pump(1000)                 -- 1.2 秒沒取樣
    drive(200, { speed = 0 })  -- 90→0 原始間隔 1.2s＝20.8 m/s²
    drive(3000, { speed = 90 })
    pump(5400)                 -- 讓位 5.6 秒
    drive(200, { speed = 0 })  -- 夾限 dt 會算成 25 m/s²
    drive(3000, { speed = 0 })
end)
checkEq(imp, 0, "(a) speed drop across a sampling gap is not an impact")
imp = impactDrive("(b) locked", function()
    drive(3000, { speed = 80 })
    drive(200, { speed = 64.2, phys = locked }) -- 本筆鎖輪：80→64.2／200ms＝21.9 m/s²
    drive(200, { speed = 48.4 })                -- 前一筆鎖輪：64.2→48.4＝21.9 m/s²
    drive(3000, { speed = 48.4 })
end)
checkEq(imp, 0, "(b) 22 m/s² while the wheels are locked (this or previous sample) is not an impact")
imp = impactDrive("(c) unlocked", function()
    drive(3000, { speed = 80 })
    drive(200, { speed = 64.2 })                -- 沒鎖輪 21.9 m/s²
    drive(3000, { speed = 64.2 })
end)
checkEq(imp, 1, "(c) 22 m/s² without locked wheels is still an impact")
local impZ
imp, impZ = impactDrive("(d) zombie distance", function()
    local far, near = { zombieN = 3, zombieNearS = 35 }, { zombieN = 3, zombieNearS = 12 } -- rs＝10：25m／2m
    drive(3000, { speed = 60, sensor = far })
    drive(200, { speed = 30, sensor = far })    -- 撞擊 1：前後兩筆都 25m 外＝不算
    drive(3000, { speed = 60, sensor = near })
    drive(200, { speed = 30, sensor = { zombieN = 3, zombieNearS = 41 } }) -- 撞擊 2：前一筆 2m、新快照 31m＝算
    drive(3000, { speed = 60, sensor = far })
    drive(200, { speed = 30, sensor = near })   -- 撞擊 3：本筆 2m＝算
    drive(3000, { speed = 30 })
end)
checkEq(imp, 3, "(d) three impacts")
checkEq(impZ, 2, "(d) impZ counts only impacts with a zombie within halfL+4 of the car (this or previous sample)")
-- 1006 伺服器拉回（瞬移）：41 km/h 時座標一筆跳 171m、速度掉到 10（1005j 正式服兩次 impact 都在跳點、帶內殭屍讓
-- impZ 也記 1）——位移遠超 |v|·間隔＋餘裕＝不是撞擊，另記瞬移（摘要 tp）；同樣掉速、位移正常的真撞照算。
-- 違規證明：impactLike 不看位移＝(tp) impact／impZ 紅；不數 tp＝(tp) tp 紅；瞬移門檻不加速度項（只看餘裕）＝(tp-fast) 紅。
local tp
imp, impZ, tp = impactDrive("(tp) teleport", function()
    drive(3000, { speed = 41 })
    x = x + 171
    drive(200, { speed = 10, sensor = { zombieN = 1, zombieNearS = 11 } }) -- rs＝10：殭屍貼著車
    drive(3000, { speed = 10 })
end)
checkEq(imp, 0, "(tp) a 171m jump with a speed drop is not an impact")
checkEq(impZ, 0, "(tp) nor a zombie impact")
checkEq(tp, 1, "(tp) the jump is counted as a teleport")
imp, impZ, tp = impactDrive("(tp-real) same drop without a jump", function()
    drive(3000, { speed = 41 })
    drive(200, { speed = 10, sensor = { zombieN = 1, zombieNearS = 11 } })
    drive(3000, { speed = 10 })
end)
checkEq(imp, 1, "(tp-real) the same drop with normal displacement is still an impact")
checkEq(impZ, 1, "(tp-real) with a zombie at the car")
checkEq(tp, 0, "(tp-real) no teleport")
imp, impZ, tp = impactDrive("(tp-fast) 120 km/h for one 1s gap", function()
    drive(3000, { speed = 120 })
    pump(800)                    -- 原始間隔 1.0s，120 km/h＝33m：正常位移
    x = x + 33
    drive(200, { speed = 120 })
    drive(3000, { speed = 120 })
end)
checkEq(tp, 0, "(tp-fast) 33m in 1s at 120 km/h is normal travel, not a teleport")

-- 1005：impact／contact 上升緣那一筆強制寫 near（快照 stamp 沒換也寫；正式服 0.18.2 clip-04 撞擊幀沒有點雲），
-- near 每顆點帶引擎形狀的橫向 lc（擋線判定用）。違規證明：拿掉 force＝(contact)(impact) 紅；impact 不看上升緣＝
-- (impact) 數到 2 紅；contact 不看上升緣＝(held) 紅；encodeNear 不寫 lc＝(lc) 紅。
scenario("1005 near: forced on the impact/contact rising edge, carries the shape lateral lc")
do
    nowMs = nowMs + 3600000
    start()
    local lines, orig = {}, U.sample
    U.sample = function(u, line, ...)
        lines[#lines + 1] = line
        return orig(u, line, ...)
    end
    local sen = { hardN = 1, hardS = { 20 }, hardL = { 3.91 }, hardLc = { 3.44 }, hardR = { 0.7 }, hardX = { 120 },
        hardY = { 203.44 }, stamp = 7, scanS = 10 }
    local function nearCount(from)
        local n = 0
        for i = from, #lines do
            if string.find(lines[i], '"near":', 1, true) then n = n + 1 end
        end
        return n
    end
    drive(1000, { speed = 40, sensor = sen })
    checkEq(nearCount(1), 1, "(stamp) same snapshot: near only on its first sample")
    check(string.find(lines[1] or "", '"l":3.91,"lc":3.44', 1, true) ~= nil, "(lc) near carries the shape lateral lc")
    local n0 = #lines
    drive(200, { speed = 40, sensor = sen, contact = true })
    checkEq(nearCount(n0 + 1), 1, "(contact) footprint rising edge writes near with an unchanged stamp")
    n0 = #lines
    drive(1000, { speed = 40, sensor = sen, contact = true })
    checkEq(nearCount(n0 + 1), 0, "(held) contact held on: no repeat")
    drive(1000, { speed = 40, sensor = sen })
    n0 = #lines
    drive(200, { speed = 20, sensor = sen }) -- 40→20／200ms＝27.8 m/s²：撞擊
    drive(200, { speed = 5, sensor = sen })  -- 20→5＝20.8 m/s²：仍達門檻，不是上升緣
    drive(1000, { speed = 5, sensor = sen })
    checkEq(nearCount(n0 + 1), 1, "(impact) impact rising edge writes near once with an unchanged stamp")
    U.sample = orig
    D.stop(0, "arrive")
    pump(120000)
end

-- 1006：impact 上升緣那一筆另寫不分感知帶的最近殭屍／動物／玩家／車各一筆（nb：[距離, 縱向（車頭正）, 橫向（右正）]，
-- 車再帶 km/h；範圍內都沒有＝"nb":{}）——正式服 9 次「高速、感知全空」的撞擊只有帶內點雲，定不了罪。只在上升緣掃一次。
-- 違規證明：拿掉 nb＝(nb) 紅；每筆都掃＝(once) 紅；橫向符號反了＝(fl) 紅；不排除自己這台／掛車＝(v) 紅；空時不寫＝(empty) 紅。
-- 1008 加最近屍體 c（同一個 8m 方框、getStaticMovingObjects 的 IsoDeadBody），讀屍體失敗只少 c、其他照寫。
-- 違規證明：不寫 c＝(c) 紅；屍體掃描併進整欄的 pcall＝(c-fail) 紅。
scenario("1006 nb: impact rising edge writes the nearest zombie/animal/player/vehicle/corpse regardless of band")
do
    nowMs = nowMs + 3600000
    local lines, orig = {}, U.sample
    U.sample = function(u, line, ...)
        lines[#lines + 1] = line
        return orig(u, line, ...)
    end
    local gridCalls = 0
    local function obj(cls, dx, dy, extra)
        local o = { cls = cls, getX = function() return x + dx end, getY = function() return 200 + dy end }
        for k, v in pairs(extra or {}) do o[k] = v end
        return o
    end
    -- heading 0＝朝 +x；世界 y 向南＝右手側 +y
    local placed = { obj("IsoZombie", 3, -1), obj("IsoZombie", -6, 0), obj("IsoAnimal", 0, 4), obj("IsoPlayer", -2, 0) }
    local bodies = { obj("IsoDeadBody", 0.5, -2.5), obj("IsoDeadBody", 6, 6) }
    local staticFails = false
    local trailerCar = obj("BaseVehicle", -5, 0)
    local ownCar = obj("BaseVehicle", 0, 0, {
        getZ = function() return 0 end,
        getVehicleTowing = function() return trailerCar end,
        getVehicleTowedBy = function() return nil end,
    })
    local otherCar = obj("BaseVehicle", 1, 3.5, { getCurrentSpeedKmHour = function() return -35 end })
    local vehicles = { ownCar, trailerCar, otherCar }
    local function list(items)
        return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
    end
    local cell = {
        getGridSquare = function(_, gx, gy, gz)
            gridCalls = gridCalls + 1
            local here = {}
            for i = 1, #placed do
                local o = placed[i]
                if math.floor(o.getX()) == gx and math.floor(o.getY()) == gy and gz == 0 then here[#here + 1] = o end
            end
            local still = {}
            for i = 1, #bodies do
                local o = bodies[i]
                if math.floor(o.getX()) == gx and math.floor(o.getY()) == gy and gz == 0 then still[#still + 1] = o end
            end
            return {
                getMovingObjects = function() return list(here) end,
                getStaticMovingObjects = function()
                    if staticFails then error("static") end
                    return list(still)
                end,
            }
        end,
        getVehicles = function()
            local i = 0
            return { iterator = function()
                return { hasNext = function() return i < #vehicles end, next = function() i = i + 1; return vehicles[i] end }
            end }
        end,
    }
    local oldCell, oldInst, oldSensor, oldVeh = getCell, instanceof, MDADSensor, player0.getVehicle
    getCell = function() return cell end
    instanceof = function(o, c)
        return type(o) == "table" and (o.cls == c or (c == "IsoPlayer" and o.cls == "IsoAnimal"))
    end
    MDADSensor = { softKindOf = function(o)
        if o.cls == "IsoAnimal" then return "animal" elseif o.cls == "IsoPlayer" then return "player" end
    end }
    player0.getVehicle = function() return ownCar end
    start()
    drive(1000, { speed = 40 })
    checkEq(gridCalls, 0, "(once) no scan while driving without an impact")
    local n0 = #lines
    drive(200, { speed = 20 }) -- 40→20／200ms＝27.8 m/s²：撞擊上升緣
    local afterEdge = gridCalls
    drive(200, { speed = 5 })  -- 仍達門檻、不是上升緣
    drive(1000, { speed = 5 })
    checkEq(gridCalls, afterEdge, "(once) only the rising-edge sample scans")
    local nbN, nb = 0, nil
    for i = n0 + 1, #lines do
        local m = string.match(lines[i], '"nb":(%b{})')
        if m then nbN, nb = nbN + 1, m end
    end
    checkEq(nbN, 1, "(nb) exactly one sample carries nb")
    nb = nb or ""
    local function arr(k)
        local body = string.match(nb, '"' .. k .. '":%[([^%]]*)%]')
        local out = {}
        for v in string.gmatch(body or "", "[^,]+") do out[#out + 1] = tonumber(v) end
        return out
    end
    local function near3(a, d, f, l, label)
        check(a[1] and math.abs(a[1] - d) < 0.006 and math.abs(a[2] - f) < 0.006 and math.abs(a[3] - l) < 0.006,
            label .. " (" .. nb .. ")")
    end
    near3(arr("z"), math.sqrt(10), 3, -1, "(fl) nearest zombie: 3.16m, 3m ahead, 1m left")
    near3(arr("a"), 4, 0, 4, "(nb) nearest animal: 4m to the right")
    near3(arr("p"), 2, -2, 0, "(nb) nearest player: 2m behind")
    local v = arr("v")
    near3(v, math.sqrt(13.25), 1, 3.5, "(v) nearest other vehicle, not own car or trailer")
    checkEq(v[4], -35, "(v) vehicle carries its km/h")
    near3(arr("c"), math.sqrt(6.5), 0.5, -2.5, "(c) nearest corpse: 0.5m ahead, 2.5m left")
    -- 讀屍體失敗：只少 c，其他類照寫
    staticFails = true
    n0 = #lines
    drive(1000, { speed = 40 })
    drive(200, { speed = 20 })
    drive(1000, { speed = 20 })
    nb = nil
    for i = n0 + 1, #lines do nb = string.match(lines[i], '"nb":(%b{})') or nb end
    nb = nb or ""
    check(arr("z")[1] ~= nil and arr("c")[1] == nil, "(c-fail) corpse read failure drops only c (" .. nb .. ")")
    staticFails = false
    -- 範圍內沒有東西：寫 "nb":{}，區分「掃了、沒有」與「沒掃」
    placed, bodies, vehicles = {}, {}, { ownCar }
    n0 = #lines
    drive(1000, { speed = 40 })
    drive(200, { speed = 20 })
    drive(1000, { speed = 20 })
    local empty = 0
    for i = n0 + 1, #lines do
        if string.find(lines[i], '"nb":{}', 1, true) then empty = empty + 1 end
    end
    checkEq(empty, 1, "(empty) nothing in range writes an empty nb on the rising edge")
    U.sample = orig
    getCell, instanceof, MDADSensor, player0.getVehicle = oldCell, oldInst, oldSensor, oldVeh
    D.stop(0, "arrive")
    pump(120000)
end

-- 1008 凍結樣本：MP 伺服器拉回前一筆，車速與 vl／vt 三者精確為 0（正式服 0.23.0 片段兩例 71→0、64.8→0，
-- 下一筆跳 56／6 m）——不算 impact、不出片段，摘要另計 frz；同樣掉到 0 但 vl 還有殘值＝真撞照算。
-- 違規證明：impactClass 不分 frozen＝(fz) impact／clips 紅；不數 frz＝(fz) frz 紅；只看車速 0 不看 vl／vt＝(fz-real) 紅。
scenario("1008 frozen sample: exact zeros before a server pull-back are not an impact")
do
    local function ph(vl) return { capReason = "curve-coast", frameMs = 16, vLong = vl, vLat = vl == 0 and 0 or 0.01 } end
    local function n(sum, key) return tonumber(string.match(sum, '"' .. key .. '":(%d+)')) end
    local imp, _, tp, sum = impactDrive("(fz) frozen", function()
        drive(3000, { speed = 70, phys = ph(19.4) })
        drive(200, { speed = 0, phys = ph(0) }) -- 凍結：70→0／200ms
        x = x + 56
        drive(200, { speed = 0, phys = ph(0) }) -- 拉回：跳 56m
        drive(3000, { speed = 0, phys = ph(0) })
    end)
    checkEq(imp, 0, "(fz) a frozen sample is not an impact")
    checkEq(n(sum, "frz"), 1, "(fz) counted once as frozen")
    checkEq(n(sum, "clips"), 0, "(fz) no impact clip")
    checkEq(tp, 1, "(fz) the pull-back jump is still a teleport")
    check(#sum < U.CHUNK, "(fz) summary still fits one chunk (" .. #sum .. ")")
    imp, _, _, sum = impactDrive("(fz-real) same drop with a residual velocity", function()
        drive(3000, { speed = 70, phys = ph(19.4) })
        drive(200, { speed = 0, phys = ph(0.3) })
        drive(3000, { speed = 0, phys = ph(0) })
    end)
    checkEq(imp, 1, "(fz-real) a drop to 0 with vl 0.3 is an impact")
    checkEq(n(sum, "frz"), 0, "(fz-real) not frozen")
end

-- 1008 拖車同步拽動（tow-sync）：SemiTruckLite＋貨櫃在直路定速約每 3.2 秒掉 16–22 km/h，掉速前 0.2–0.4 s 掛車 tup 由
-- 0.9997 掉到 ~0.994、沒煞車、沒 footprint、nb 空（正式服 0.23.0 片段 6 例，其中一例連續兩筆都過門檻）——
-- 分類 tow-sync：不算 impact、不出片段，摘要另計 tws。反面：有 footprint、掛車沒先傾斜（SemiTruck＋Cartrailer 真撞）、
-- 方框內有殭屍、踩煞車，都仍算 impact。
-- 違規證明：impactClass 不分 tow-sync＝(ts) 紅；連續第二筆不沿用分類＝(ts) impact 紅；只在上升緣以外也數 tws＝(ts) tws 紅；
-- 不看 footprint＝(ts-fb) 紅；不看 tup 降幅＝(ts-flat) 紅；不看 nb 近物＝(ts-near) 紅；不看 ib＝(ts-brake) 紅；
-- tup 窗只看本筆（不往前）＝(ts) 紅。
scenario("1008 tow-sync: trailer pulled back by MP sync is not an impact; real towing hits still are")
do
    local placed = {}
    local function list(items)
        return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
    end
    local cell = {
        getGridSquare = function(_, gx, gy)
            local here = {}
            for i = 1, #placed do
                local o = placed[i]
                if math.floor(o.getX()) == gx and math.floor(o.getY()) == gy then here[#here + 1] = o end
            end
            return { getMovingObjects = function() return list(here) end,
                getStaticMovingObjects = function() return list({}) end }
        end,
        getVehicles = function()
            return { iterator = function() return { hasNext = function() return false end } end }
        end,
    }
    local ownCar = { getZ = function() return 0 end, getVehicleTowing = function() return nil end,
        getVehicleTowedBy = function() return nil end }
    local oldCell, oldInst, oldVeh = getCell, instanceof, player0.getVehicle
    getCell = function() return cell end
    instanceof = function(o, c) return type(o) == "table" and o.cls == c end
    player0.getVehicle = function() return ownCar end
    local function tw(up, extra)
        local t = { capReason = "curve-coast", frameMs = 16, towUp = up, isBraking = false, vLong = 10, vLat = 0 }
        for k, v in pairs(extra or {}) do t[k] = v end
        return t
    end
    local function n(sum, key) return tonumber(string.match(sum, '"' .. key .. '":(%d+)')) end
    -- 正式服案例 A 的形狀：tup 0.9997→0.9988→0.9957→0.9946，車速 50→50→43.5→21.6（30 m/s²），下一筆 5（仍過門檻）
    local function jolt(hit, opts)
        opts = opts or {}
        local flat = opts.flat
        drive(3000, { speed = 50, phys = tw(0.9997) })
        drive(200, { speed = 50, phys = tw(flat and 0.9997 or 0.9988) })
        drive(200, { speed = 43.5, phys = tw(flat and 0.9997 or 0.9957) })
        drive(200, { speed = 21.6, phys = tw(flat and 0.9997 or 0.9946, hit), contact = opts.contact })
        drive(200, { speed = 5, phys = tw(0.995) })
        drive(3000, { speed = 5, phys = tw(0.9997) })
    end
    local evLines, origEvent = {}, U.event
    U.event = function(u, line, ...)
        if string.find(line, '"n":"impact"', 1, true) then evLines[#evLines + 1] = line end
        return origEvent(u, line, ...)
    end
    local imp, _, _, sum = impactDrive("(ts) tow-sync", function() jolt() end)
    U.event = origEvent
    checkEq(#evLines, 1, "(ts) one impact event on the rising edge")
    check(string.find(evLines[1] or "", '"cls":"tow-sync"', 1, true) ~= nil,
        "(ts) the impact event carries cls tow-sync (" .. tostring(evLines[1]) .. ")")
    checkEq(imp, 0, "(ts) trailer sync jolt is not an impact (nor its consecutive second sample)")
    checkEq(n(sum, "tws"), 1, "(ts) counted once as tow-sync")
    checkEq(n(sum, "clips"), 0, "(ts) no impact clip")
    check(#sum < U.CHUNK, "(ts) summary still fits one chunk (" .. #sum .. ")")
    imp, _, _, sum = impactDrive("(ts-fb) footprint", function() jolt(nil, { contact = true }) end)
    checkEq(imp, 1, "(ts-fb) same jolt with a footprint hit is an impact")
    checkEq(n(sum, "tws"), 0, "(ts-fb) not tow-sync")
    imp, _, _, sum = impactDrive("(ts-flat) no tilt first", function() jolt(nil, { flat = true }) end)
    checkEq(imp, 1, "(ts-flat) trailer not tilting before the drop (real hit) is an impact")
    checkEq(n(sum, "tws"), 0, "(ts-flat) not tow-sync")
    placed = { { cls = "IsoZombie", getX = function() return x + 3 end, getY = function() return 200 end } }
    imp = impactDrive("(ts-near) zombie in the box", function() jolt() end)
    checkEq(imp, 1, "(ts-near) a zombie within the nb box makes it an impact")
    placed = {}
    imp = impactDrive("(ts-brake) braking", function() jolt({ isBraking = true }) end)
    checkEq(imp, 1, "(ts-brake) braking at the drop makes it an impact")
    getCell, instanceof, player0.getVehicle = oldCell, oldInst, oldVeh
end

-- 1008 伺服器滿槽先淘汰舊版（rev 與這段不同）的片段：舊版 pri 1–2 片段永久佔槽，正式服槽滿的玩家約八成是舊版片段、
-- 新版 takeover 72 段只收到 31。同版才照原規則（pri 數字最大中最舊）。
-- 違規證明：pickSlot 不看 rev＝(rev) 紅；舊版裡不照 pri／時間挑＝(rev-oldest) 紅；帶 rev 時同版片段不當候選（全同版就拒收）＝(same) 紅；
-- beginClip 沒把 rev 傳進 pickSlot＝(rev) 紅。
scenario("server: a full player folder evicts clips of other revs first")
do
    S._reset()
    for k in pairs(files) do if string.find(k, ROOT, 1, true) == 1 then files[k] = nil end end
    local rid = 7000
    local function msg(kind, pri, rev)
        rid = rid + 1
        nowMs = nowMs + 1000
        local data = kind .. "-" .. rev .. "-" .. rid
        return S.receive(player0, { id = rid, q = 1, n = 1, k = "clip", len = #data, kind = kind,
            pri = pri, rev = rev, data = data })
    end
    local function tally()
        local fo = S._stats().folders["玩家_One__"]
        local t = {}
        for slot = 1, 32 do
            local c = fo.slots[slot]
            local key = c and (c.kind .. "@" .. c.rev) or "empty"
            t[key] = (t[key] or 0) + 1
        end
        return t, fo
    end
    for _ = 1, 16 do msg("stuck", 1, "1006a") end
    for _ = 1, 16 do msg("brake", 4, "1008a") end
    check(msg("takeover", 3, "1008a"), "(rev) new-rev clip accepted when full")
    local t, fo = tally()
    checkEq(t["stuck@1006a"], 15, "(rev) one old-rev stuck clip replaced")
    checkEq(t["brake@1008a"], 16, "(rev) same-rev brake clips kept despite lower priority")
    local oldestGone = true
    for slot = 1, 32 do
        local c = fo.slots[slot]
        if c and string.find(files[folderPath() .. "clip-" .. string.format("%02d", slot) .. ".log"] or "", "stuck%-1006a%-7001") then
            oldestGone = false
        end
    end
    check(oldestGone, "(rev-oldest) the oldest old-rev clip went first")
    -- 全部同版：照原規則換掉 pri 數字最大中最舊的
    S._reset()
    for k in pairs(files) do if string.find(k, ROOT, 1, true) == 1 then files[k] = nil end end
    for _ = 1, 16 do msg("stuck", 1, "1008a") end
    for _ = 1, 16 do msg("brake", 4, "1008a") end
    msg("takeover", 3, "1008a")
    t = tally()
    checkEq(t["stuck@1008a"], 16, "(same) same rev everywhere: pri-1 clips kept")
    checkEq(t["brake@1008a"], 15, "(same) the lowest-priority clip is replaced")
end

-- 1004e 越野推力 KPI：推力夠不夠要看自己的紀錄。想加速＝目標−實速 ≥6、前進、沒強制煞車；相鄰兩筆都想加速且同地表才算一對。
-- 違規證明：門檻改成 >6＝oaMs 600 紅；不看同地表＝paMs／oaMs 紅；不排除煞車＝paMs 紅；不擋原始間隔＝paMs 紅；
-- 低加速看錯對＝olMs 紅；oMs 不濾跟線＝oMs 紅。
scenario("1004e offroad accel KPI: wanted-accel pairs per surface, low accel, assist and boost time")
nowMs = nowMs + 3600000
start()
local drive1 = nowMs
local function off(extra)
    local t = { capReason = "profile", frameMs = 16, physicalOffroad = true }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end
drive(1000, { speed = 0, target = 0 })                                  -- 暖身：不想加速
drive(200, { speed = 10, target = 40, phys = off() })                   -- s1 起點
drive(200, { speed = 11, target = 40, phys = off({ assistForce = 500 }) }) -- 1.39 m/s²＝低加速、有輔助
drive(200, { speed = 13, target = 40, phys = off({ assistForce = 500, assistBoost = 3 }) }) -- 2.78、倍率頂
drive(200, { speed = 15, target = 40, phys = off({ accelAssist = 1, assistBoost = 2.5 }) }) -- 有輔助、倍率未頂
drive(200, { speed = 17, target = 23, phys = off() })                   -- 差剛好 6＝算
drive(200, { speed = 18, target = 23.9, phys = off() })                 -- 差 5.9＝不想加速，斷鏈
drive(200, { speed = 19, target = 40, phys = off() })                   -- 前一筆不想加速＝不成對
drive(200, { speed = 20, target = 40 })                                 -- 換鋪面＝不成對
drive(200, { speed = 22, target = 40 })                                 -- 鋪面對
drive(200, { speed = 24, target = 40 })                                 -- 鋪面對
drive(200, { speed = 26, target = 40, phys = { capReason = "blocked", frameMs = 16, forceBrakeLeft = 500 } }) -- 煞車＝排除
drive(200, { speed = 28, target = 40 })                                 -- 前一筆煞車＝不成對
drive(200, { speed = 30, target = 40 })                                 -- 鋪面對
pump(1000)                                                             -- 原始間隔 1.2s
drive(200, { speed = 32, target = 40 })                                 -- 跨間隔＝不成對
drive(400, { speed = 32, target = 32, phys = off() })                   -- 越野不想加速：只算 oMs
drive(400, { speed = 32, target = 40, mode = "unstick", phys = off() }) -- 非跟線：全不算
D.stop(0, "arrive")
pump(120000)
local sum1 = ""
for k, content in pairs(files) do
    if string.find(k, ROOT .. "summary-", 1, true) == 1 then
        for line in string.gmatch(content, "[^\n]+") do
            if string.find(line, '"drive":' .. string.format("%d", drive1) .. ",", 1, true) then sum1 = line end
        end
    end
end
local function num1(key) return tonumber(string.match(sum1, '"' .. key .. '":([%d%.%-]+)')) end
check(sum1 ~= "", "offroad KPI drive summary found")
checkEq(num1("oMs"), 1800, "offroad follow time: 7 wanted-segment + 2 cruise samples, unstick excluded")
checkEq(num1("oaMs"), 800, "offroad wanted pairs: 4 (exactly-6 counts, 5.9 breaks, surface change does not pair)")
checkEq(num1("oaDv"), 1.94, "offroad Δspeed 7 km/h = 1.94 m/s")
checkEq(num1("olMs"), 200, "offroad low-accel (<1.5 m/s²) pair time")
checkEq(num1("oasMs"), 600, "offroad pairs with forward assist (assistForce or accelAssist)")
checkEq(num1("obMs"), 200, "offroad pairs with assistBoost at 3")
checkEq(num1("paMs"), 600, "paved wanted pairs: 3 (braking and >1s gap excluded)")
checkEq(num1("paDv"), 1.67, "paved Δspeed 6 km/h = 1.67 m/s")
check(#sum1 < U.CHUNK, "summary still fits one chunk (" .. #sum1 .. ")")

-- 片段工具：依觸發時刻（index 第 9 欄）找片段列與檔案內容；片段內樣本的 ts 列表
local function clipByTrig(trig)
    local rows = indexRows("C")
    for i = #rows, 1, -1 do
        if tonumber(field(rows[i], 9)) == trig then
            local slot = tonumber(field(rows[i], 5))
            return rows[i], files[ROOT .. field(rows[i], 4) .. "/" .. string.format("clip-%02d.log", slot)] or ""
        end
    end
    return nil, ""
end
local function sampleTs(text)
    local out = {}
    for line in string.gmatch(text, "[^\n]+") do
        local ts = string.match(line, '^{"t":"s","ts":(%d+)')
        if ts then out[#out + 1] = tonumber(ts) end
    end
    return out
end
-- [lo, hi) 內相鄰樣本的最小間隔與筆數
local function gapsIn(list, lo, hi)
    local minGap, n, prev = 1e9, 0, nil
    for i = 1, #list do
        local t = list[i]
        if t >= lo and t < hi then
            n = n + 1
            if prev and t - prev < minGap then minGap = t - prev end
            prev = t
        end
    end
    return minGap, n
end

-- 1010 片段容量：正式服 rev≥1005 片段約 600 段有 62 段 full、觸發後中位只剩 3.9 秒（事前窗佔預算八成七），29 段 unstick
-- 只有 13 段看得到 success／timeout。full 之後樣本不收、窗內事件照收到窗結束（首行 evx＝筆數），預算＝min(CLIP_EV_MAX,
-- 整段 CLIP_TOTAL_MAX 的剩額)；事前窗本身超過 CLIP_MAX 時捨最舊的。整段 ≤ CLIP_TOTAL_MAX：伺服器上限維持 0.27.x 的 1000000
-- （DoLuaChecksum=false，發版到重啟之間新客戶端會連上舊伺服器，超過整段拒收）。
-- 違規證明：full 仍收窗＝(full) success／timeout 紅；full 後事件不收＝同上；不夾整段＝(total) 紅；事件不設 CLIP_EV_MAX＝(evmax) 紅；
-- 首行不寫 evx＝(evx) 紅；事前窗不夾 CLIP_MAX＝(bound) 紅；固定列過長不捨舊列＝(total-fixed) 紅；伺服器加大＝(server) 紅。
scenario("1010 full clip: window events keep coming on their own budget until the window closes")
nowMs = nowMs + 3600000
start()
local fat = { capReason = string.rep("x", 6000), frameMs = 16 }
drive(31000, { phys = fat })                               -- 事前窗 ≈155 筆 × 6KB＞CLIP_MAX：觸發當下就 full
D.event(0, "unstick", { phase = "start" })
local fullTrig = nowMs
drive(8000, { phys = fat, mode = "unstick" })
D.event(0, "unstick", { phase = "timeout" })
for _ = 1, 30 do D.event(0, "progress", { phase = "suspect", detail = string.rep("d", 5000) }) end -- 150KB＞CLIP_EV_MAX
D.event(0, "unstick", { phase = "start" })
drive(6000, { phys = fat, mode = "unstick" })
D.event(0, "unstick", { phase = "success" })
drive(12000, { phys = fat })                               -- 安靜 QUIET_MS 後收窗
D.stop(0, "arrive")
pump(200000)
local fullRow, fullClip = clipByTrig(fullTrig)
check(fullRow ~= nil, "(server) the full clip with extra events is accepted and indexed")
local fullHead = string.match(fullClip, "^[^\n]*") or ""
check(string.find(fullHead, '"full":true', 1, true) ~= nil, "(full) clip head says full")
checkEq(count(fullClip, '"n":"unstick","phase":"timeout"'), 1, "(full) unstick timeout after full is in the clip")
checkEq(count(fullClip, '"n":"unstick","phase":"success"'), 1, "(full) unstick success after full is in the clip")
local progN = count(fullClip, '"n":"progress"')
check(progN >= 15 and progN < 30, "(bound) 5KB events beyond the event budget are dropped (" .. progN .. " of 30 kept)")
local evx = tonumber(string.match(fullHead, '"evx":(%d+)'))
checkEq(evx, progN + 3, "(evx) clip head counts the events kept after full (timeout, start, success + progress)")
local fullTs = sampleTs(fullClip)
check(#fullTs > 0 and fullTs[#fullTs] <= fullTrig, "(full) no samples after full")
check(#fullClip <= U.CLIP_TOTAL_MAX, "(total) the whole clip text stays <= CLIP_TOTAL_MAX (" .. #fullClip .. ")")
checkEq(S.CLIP_MAX, 1000000, "(server) server CLIP_MAX stays at the 0.27.x limit: old and new servers share one limit")
check(U.CLIP_TOTAL_MAX < 1000000, "(server) client total limit is below the old server's 1,000,000")
-- 樣本很大、full 時樣本才 84 萬：整段剩額比 CLIP_EV_MAX 大，事件由 CLIP_EV_MAX 限住
nowMs = nowMs + 3600000
start()
local wide = { capReason = "profile", frameMs = 16, controlState = string.rep("y", 60000) }
-- 窗前事件 75KB：整段剩額要先讓給 full 後的事件，窗前事件只拿剩下的（不讓＝(total) 紅）
for _ = 1, 15 do D.event(0, "dyn", { phase = "dirty", detail = string.rep("p", 5000) }) end
drive(4000, { phys = wide })
D.event(0, "unstick", { phase = "start" })
local evTrig = nowMs
drive(1000, { phys = wide, mode = "unstick" })
for _ = 1, 150 do D.event(0, "progress", { phase = "suspect", detail = string.rep("d", 1000) }) end -- 細粒度：吃滿 CLIP_EV_MAX
drive(12000, { phys = wide })
D.stop(0, "arrive")
pump(400000)
local _, evClip = clipByTrig(evTrig)
local evProg = count(evClip, '"n":"progress"')
check(evClip ~= "" and string.find(evClip, '"full":true', 1, true) ~= nil, "(evmax) the wide-sample clip is full")
check(evProg >= 80 and evProg <= math.floor(U.CLIP_EV_MAX / 1050),
    "(evmax) events after full are held to CLIP_EV_MAX when the total leaves more room (" .. evProg .. " of 150 kept)")
check(#evClip <= U.CLIP_TOTAL_MAX, "(total) pre-window events only get what full-window events leave (" .. #evClip .. ")")
-- 首行異常長（出事當下的 cap 字串 20 萬字元）：固定列＋滿樣本（4 筆 80 萬）超過整段上限，捨最舊的窗內列
nowMs = nowMs + 3600000
start()
local huge = { capReason = string.rep("z", 200000), frameMs = 16 }
drive(3000, { phys = huge })
D.event(0, "unstick", { phase = "start" })
local hugeTrig = nowMs
drive(6000, { phys = huge })
D.stop(0, "arrive")
pump(400000)
local hugeRow, hugeClip = clipByTrig(hugeTrig)
check(hugeRow ~= nil and #hugeClip > 0 and #hugeClip <= U.CLIP_TOTAL_MAX,
    "(total-fixed) an oversize head still fits CLIP_TOTAL_MAX by dropping the oldest window lines (" .. #hugeClip .. ")")
-- success 在預算內那一種：事件少時 full 之後的 success 也收到
nowMs = nowMs + 3600000
start()
drive(31000, { phys = fat })
D.event(0, "unstick", { phase = "start" })
local fullTrig2 = nowMs
drive(8000, { phys = fat, mode = "unstick" })
D.event(0, "unstick", { phase = "success" })
drive(12000, { phys = fat })
D.stop(0, "arrive")
pump(200000)
local _, fullClip2 = clipByTrig(fullTrig2)
checkEq(count(fullClip2, '"n":"unstick","phase":"success"'), 1, "(full) unstick success 8s after a full trigger is in the clip")
check(#fullClip2 > 0 and #fullClip2 <= U.CLIP_MAX + 20000, "(bound) pre-window alone is held to CLIP_MAX (" .. #fullClip2 .. ")")
-- full 的片段只剩事件在收：另一種事故（配額內）先收掉它、開自己的片段（帶事前窗與樣本），不併進去只升級優先級。
-- 違規證明：full 時照舊併入＝(yield) 紅。
nowMs = nowMs + 3600000
start()
drive(31000, { phys = fat })
D.event(0, "unstick", { phase = "start" })
local fullTrig3 = nowMs
drive(3000, { phys = fat, mode = "unstick" })
local contactTrig = nowMs + 200
drive(200, { phys = fat, contact = true })
drive(12000, { phys = fat })
D.stop(0, "arrive")
pump(200000)
local row3, clip3 = clipByTrig(fullTrig3)
local rowC = clipByTrig(contactTrig)
checkEq(field(rowC or "", 7), "contact", "(yield) a contact during a full unstick clip gets its own clip")
checkEq(field(row3 or "", 7), "unstick", "(yield) the full unstick clip keeps its kind")
checkEq(tonumber(string.match(clip3, '"end":(%d+)')), contactTrig, "(yield) the full clip closes when the new one opens")

-- 1010 上傳片段降頻（跳過已編好的列）：事前窗早於觸發 PRE_THIN_BEFORE_MS 的樣本、觸發 THIN_AFTER_MS 之後的樣本都降到 5Hz，
-- 觸發前最後 10 秒與觸發後 5 秒保留 10Hz；本機紀錄照 10Hz。
-- 違規證明：不降頻＝(thin) 紅；從觸發就降＝(early) 紅；事前窗不降＝(pre-thin) 紅；事前窗整段都降＝(pre-keep) 紅；
-- 降頻動到本機紀錄＝(local) 紅。
scenario("1010 upload clip thins samples to 5 Hz (pre-window before t0-10s, post after t0+5s); the local session keeps 10 Hz")
nowMs = nowMs + 3600000
MDAD.HUD.telemetryEnabled = function() return true end
start()
local function crit(ms, opts)
    local stop = nowMs + ms
    while nowMs < stop do
        nowMs = nowMs + 100
        U.tick()
        sample(opts)
    end
end
crit(25000, { mode = "unstick" })
D.event(0, "unstick", { phase = "start" })
local thinTrig = nowMs
crit(12000, { mode = "unstick" })
D.event(0, "unstick", { phase = "success" })
crit(8000)
D.stop(0, "arrive")
MDAD.HUD.telemetryEnabled = function() return false end
pump(120000)
local _, thinClip = clipByTrig(thinTrig)
local thinTs = sampleTs(thinClip)
local g0, n0 = gapsIn(thinTs, thinTrig + 1, thinTrig + U.THIN_AFTER_MS) -- 觸發那筆在事前窗裡，從下一筆量
local g1, n1 = gapsIn(thinTs, thinTrig + U.THIN_AFTER_MS, thinTrig + 12000)
check(g0 == 100 and n0 >= 45, "(early) the first 5 s after the trigger keep 10 Hz (min " .. g0 .. ", n " .. n0 .. ")")
check(g1 >= U.THIN_GAP_MS and n1 >= 30, "(thin) samples after 5 s are >= 200ms apart (min " .. g1 .. ", n " .. n1 .. ")")
local gp, np = gapsIn(thinTs, thinTrig - U.PRE_MS + 1, thinTrig - U.PRE_THIN_BEFORE_MS)
local gk, nk = gapsIn(thinTs, thinTrig - U.PRE_THIN_BEFORE_MS, thinTrig + 1)
check(gp >= U.THIN_GAP_MS and np >= 45, "(pre-thin) pre-window samples older than 10 s are >= 200ms apart (min " .. gp .. ", n " .. np .. ")")
check(gk == 100 and nk >= 95, "(pre-keep) the last 10 s before the trigger keep 10 Hz (min " .. gk .. ", n " .. nk .. ")")
local localText = ""
for k, content in pairs(files) do
    if string.find(k, "Telemetry/session%-%d+%.log$") and string.find(content, '"ts":' .. thinTrig, 1, true) then
        localText = content
    end
end
local localTs = sampleTs(localText)
local lg, ln = gapsIn(localTs, thinTrig + U.THIN_AFTER_MS, thinTrig + 12000)
check(lg == 100 and ln >= 65, "(local) the local session keeps 10 Hz after 5 s (min " .. lg .. ", n " .. ln .. ")")
local lpg, lpn = gapsIn(localTs, thinTrig - U.PRE_MS + 1, thinTrig - U.PRE_THIN_BEFORE_MS)
check(lpg == 100 and lpn >= 95, "(local) the local session keeps 10 Hz before t0-10s (min " .. lpg .. ", n " .. lpn .. ")")

-- 1010 偏離常駐線 KPI（摘要 offMs／offN／offMax）與 offset 片段：玩家回報「繞完一直走路邊」沒事故就完全沒錄到。
-- 有主的偏移不算：繞行 AVOID、RETURN、判堵 HOLD、殭屍軟縫 zln、調頭（|att| ≥ π/2）、接回保護 sg、起步越野接線（rs < apr）；
-- 鏈式停留（lc）量車身−夾過的常駐線 rsl（鏈著時 ld 對的是停留 lane；rsd 沒夾路寬）。連續 ≥2 秒才算一段，單段 8 秒觸發
-- offset（pri 4）。
-- 違規證明：拿掉任一項排除＝(owned) offN／offMs 紅；鏈式不改量＝(chain) 紅；鏈式量沒夾的 rsd＝(chain-rsd) 紅；
-- 短於 2 秒也算＝(short) 紅；不觸發片段／伺服器 KINDS 漏 offset＝(clip) 紅。
scenario("1010 offset KPI: unowned lateral offset > 1m for >= 2s; owned offsets excluded; 8s raises an offset clip")
nowMs = nowMs + 3600000
start()
local offDrive = nowMs
local function ln(extra)
    local t = { capReason = "profile", frameMs = 16, controlState = "TRACK", latDev = 0.2, expectedLane = 0,
        residentBias = 0 }
    for k, v in pairs(extra or {}) do t[k] = v end
    return t
end
D.event(0, "route", { phase = "ready", approach = 50 })
drive(4000, { rs = 20, lat = 2.5, phys = ln({ latDev = 2.5 }) })                    -- 起步越野接線
drive(1000, { rs = 100, phys = ln() })
drive(4000, { rs = 100, lat = 2.5, phys = ln({ latDev = 2.5, controlState = "AVOID" }) })
drive(1000, { rs = 100, phys = ln() })
drive(4000, { rs = 100, lat = 2.5, phys = ln({ latDev = 2.5, controlState = "RETURN" }) })
drive(1000, { rs = 100, phys = ln() })
drive(4000, { rs = 100, lat = 2.5, phys = ln({ latDev = 2.5, controlState = "HOLD" }) })
drive(1000, { rs = 100, phys = ln() })
drive(4000, { rs = 100, lat = 2.5, phys = ln({ latDev = 2.5, zombieLane = 2.5 }) })
drive(1000, { rs = 100, phys = ln() })
drive(4000, { rs = 100, lat = 2.5, phys = ln({ latDev = 2.5, routeHeadingError = 2.8 }) }) -- 調頭
drive(1000, { rs = 100, phys = ln() })
drive(4000, { rs = 100, lat = 2.5, phys = ln({ latDev = 2.5, startGuard = true }) })  -- 接回保護
drive(1000, { rs = 100, phys = ln() })
drive(4000, { rs = 100, lat = 2.5, mode = "unstick", phys = ln({ latDev = 2.5 }) })
drive(1000, { rs = 100, phys = ln() })
drive(1600, { rs = 100, lat = 1.6, phys = ln({ latDev = 1.6 }) })                    -- 8 筆＝1.4s：太短
drive(1000, { rs = 100, phys = ln() })
local offStart = nowMs + 200
drive(9000, { rs = 100, lat = -1.6, phys = ln({ latDev = -1.6 }) })                  -- 45 筆＝8.8s：一段＋片段
drive(1000, { rs = 100, phys = ln() })
drive(3000, { rs = 100, lat = 2.5, phys = ln({ latDev = 0.1, laneChained = true, residentLane = 0 }) }) -- 鏈著：離常駐線 2.5
-- 鏈著、離夾過的常駐線 0.6：不算（沒夾的 rsd 2.5＝彎內側／窄段的原值，量它會誤算）
drive(3000, { rs = 100, lat = 0.6, phys = ln({ latDev = 0.1, laneChained = true, residentLane = 0, residentBias = 2.5 }) })
drive(2000, { rs = 100, phys = ln() })
D.stop(0, "arrive")
pump(120000)
local offSum = ""
for k, content in pairs(files) do
    if string.find(k, ROOT .. "summary-", 1, true) == 1 then
        for line in string.gmatch(content, "[^\n]+") do
            if string.find(line, '"drive":' .. string.format("%d", offDrive) .. ",", 1, true) then offSum = line end
        end
    end
end
local function numO(key) return tonumber(string.match(offSum, '"' .. key .. '":([%d%.%-]+)')) end
check(offSum ~= "", "offset drive summary found")
checkEq(numO("offN"), 2, "(owned)(short)(chain) two segments: the 8.8s unowned one and the 2.8s chained one")
checkEq(numO("offMs"), 8800 + 2800, "(owned)(chain) offMs = 8.8s + 2.8s")
checkEq(numO("offMax"), 8800, "longest segment 8.8s")
check(#offSum < U.CHUNK, "summary still fits one chunk (" .. #offSum .. ")")
local offRow = clipByTrig(offStart + U.OFF_CLIP_MS)
check(offRow ~= nil, "(clip) an offset clip is raised 8s into the segment and indexed")
checkEq(field(offRow or "", 7), "offset", "(clip) kind offset")
checkEq(field(offRow or "", 8), "4", "(clip) offset priority 4")

-- 1010 新客戶端＋舊伺服器（正式服 DoLuaChecksum=false：發版到伺服器重啟之間新客戶端會連上 0.27.x 伺服器）。舊伺服器＝
-- 8063441 的 MDAD_UploadServer 常數：CLIP_MAX 1000000、KINDS 沒有 offset。非 offset 片段（含塞滿＋full 後事件的）全收；
-- offset 被拒（已知坑：佔用一個片段配額，伺服器重啟後恢復）。
-- 違規證明：客戶端不夾整段＝(old) full 片段被拒紅。
scenario("1010 new client + 0.27.x server: every non-offset clip accepted, offset rejected")
local OLD_SERVER_CLIP_MAX = 1000000
local srvSrc = io.open(MEDIA .. "server/MDAD_UploadServer.lua", "r"):read("*a")
local nClip, nKinds
srvSrc, nClip = string.gsub(srvSrc, "local CLIP_MAX = %d+", "local CLIP_MAX = " .. OLD_SERVER_CLIP_MAX)
srvSrc, nKinds = string.gsub(srvSrc, "detour = true, offset = true }", "detour = true }")
checkEq(nClip + nKinds, 2, "old-server constants patched (CLIP_MAX, KINDS)")
local newServer = MDADUploadServer
client = false
assert(load(srvSrc))()
client = true
local oldServer = MDADUploadServer
checkEq(oldServer.CLIP_MAX, OLD_SERVER_CLIP_MAX, "old server limit")
nowMs = nowMs + 3600000
start()
drive(31000, { phys = fat })
D.event(0, "unstick", { phase = "start" })
local oldTrig = nowMs
drive(8000, { phys = fat, mode = "unstick" })
D.event(0, "unstick", { phase = "timeout" })
for _ = 1, 30 do D.event(0, "progress", { phase = "suspect", detail = string.rep("d", 5000) }) end
drive(12000, { phys = fat })
D.stop(0, "arrive")
pump(400000)
local oldRow, oldClip = clipByTrig(oldTrig)
check(oldRow ~= nil and string.find(oldClip, '"full":true', 1, true) ~= nil,
    "(old) a full clip with events after full is accepted by the 0.27.x server (" .. #oldClip .. ")")
checkEq(count(oldClip, '"n":"unstick","phase":"timeout"'), 1, "(old) the unstick result reaches the 0.27.x server")
nowMs = nowMs + 3600000
start()
drive(1000, { rs = 100, phys = ln() })
local oldOffStart = nowMs + 200
drive(9000, { rs = 100, lat = -1.6, phys = ln({ latDev = -1.6 }) })
drive(6000, { rs = 100, phys = ln() })
D.stop(0, "arrive")
pump(400000)
checkEq(clipByTrig(oldOffStart + U.OFF_CLIP_MS), nil, "(old) the 0.27.x server rejects the offset kind")
MDADUploadServer = newServer
S._reset()

-- 1010c 掛車不在世界（tow lost alive=false）：Driver 把診斷收尾延後、脫開後 1s／5s 各記一筆 tow relook，之後才 D.stop(TrailerLost)。
--   (tl-trig) tow lost 事件當下就觸發 trailer 片段（trig＝脫開時間），兩筆 relook 落在同一段；延後的 finish 不再開一段。
--   (tl-sum)  摘要一份，end／dur 以脫開時間計（不含延後的回看）。
--   (tl-join) lost 併入已開著的 contact 片段（同 pri、kind 留 contact、不設 trailer 冷卻）：延後 finish 時那段已收，仍不得重開 trailer 段。
--   違規證明：拿掉 U.event 的 lost 觸發＝(tl-trig) 紅；摘要用 finish 時間＝(tl-sum) 紅；finish 照舊觸發 TrailerLost＝(tl-join) 紅。
scenario("1010c trailer lost with deferred relook: clip at lost time, relook inside, one summary, no duplicate clip")
local function sumLines(d0)
    local n, last = 0, nil
    for k, v in pairs(files) do
        if string.find(k, ROOT .. "summary-", 1, true) == 1 then
            for line in string.gmatch(v, "[^\n]+") do
                if string.find(line, '"drive":' .. tostring(d0) .. ",", 1, true) then n, last = n + 1, line end
            end
        end
    end
    return n, last or ""
end
-- 這趟（index 第 15 欄 drive）的片段列；伺服器槽滿會覆蓋舊列，不能拿總列數比
local function clipsOf(d0)
    local out = {}
    local rows = indexRows("C")
    for i = 1, #rows do if tonumber(field(rows[i], 15)) == d0 then out[#out + 1] = rows[i] end end
    return out
end
nowMs = nowMs + 3600000
start()
local tlDrive = nowMs
drive(3000)
local lostAt = nowMs
D.event(0, "tow", { phase = "lost", alive = false, vid = 42, rmw = true, ox = 10592, oy = 9800, od = 7.5 })
pump(1000)
D.event(0, "tow", { phase = "relook", dt = 1000, vid = 42, found = true, same = false, fsc = "Base.SmallCar", sn = 1, sd = 3,
    sv = 99, rmw = true })
pump(4000)
D.event(0, "tow", { phase = "relook", dt = 5000, vid = 42, found = false, sn = 0, rmw = true })
D.stop(0, "UI_MinidoracatAutoDrive_TrailerLost")
pump(120000)
local tlRow, tlText = clipByTrig(lostAt)
checkEq(#clipsOf(tlDrive), 1, "(tl-trig) one clip for the deferred trailer lost")
check(tlRow ~= nil and field(tlRow, 7) == "trailer", "(tl-trig) trailer clip triggered at the lost event (trig = lost time)")
checkEq(count(tlText, '"phase":"relook"'), 2, "(tl-trig) both relook events inside the clip")
check(string.find(tlText, '"ox":10592', 1, true) ~= nil, "(tl-trig) lost event keeps the new ox field")
check(string.find(tlText, '"fsc":"Base.SmallCar"', 1, true) ~= nil and string.find(tlText, '"sv":99', 1, true) ~= nil,
    "(tl-trig) relook event keeps fsc and sv (EK)")
local tlSumN, tlSum = sumLines(tlDrive)
checkEq(tlSumN, 1, "(tl-sum) one summary")
checkEq(tonumber(string.match(tlSum, '"end":(%d+)')), lostAt, "(tl-sum) summary end = lost time")
checkEq(tonumber(string.match(tlSum, '"dur":(%d+)')), lostAt - tlDrive, "(tl-sum) summary dur ends at lost time")
nowMs = nowMs + 3600000
start()
local tjDrive = nowMs
drive(3000)
drive(400, { contact = true })
drive(600)
D.event(0, "tow", { phase = "lost", alive = false, vid = 42 })
pump(1000)
D.event(0, "tow", { phase = "relook", dt = 1000, vid = 42, found = false })
pump(4000)
D.event(0, "tow", { phase = "relook", dt = 5000, vid = 42, found = false })
D.stop(0, "UI_MinidoracatAutoDrive_TrailerLost")
pump(120000)
local tjRows = clipsOf(tjDrive)
checkEq(#tjRows, 1, "(tl-join) lost joined the open contact clip; the deferred finish opens no second clip")
checkEq(field(tjRows[1] or "", 7), "contact", "(tl-join) the joined clip keeps kind contact")

-- 1010 所有送出的片段整段 ≤ CLIP_TOTAL_MAX（第一塊宣告的 len＝全文長度；伺服器只看這個）
local maxLen = 0
for i = 1, #sent do
    local a = sent[i].args
    if a.k == "clip" and a.q == 1 and a.len > maxLen then maxLen = a.len end
end
check(maxLen > 900000 and maxLen <= U.CLIP_TOTAL_MAX, "(total) every clip sent is <= CLIP_TOTAL_MAX (max " .. maxLen .. ")")

print(string.format("情境 %d 個、斷言 %d 項、失敗 %d", scenarios, assertions, failures))
if failures > 0 then os.exit(1) end
