-- MDAD_UploadServer.lua — 伺服器端收診斷上傳（client/MDAD_Upload.lua 送）。
--
-- 版面（getFileWriter 相對 <伺服器 Zomboid>/Lua/，LuaManager.java:1263-1264、6729-6761）：
--   MinidoracatAutoDrive/Uploads/index.txt            全部片段一列一筆（追加；啟動時整理）
--   MinidoracatAutoDrive/Uploads/<玩家名>/clip-NN.log  每人 32 槽，滿了先覆蓋優先級低、較舊的
--   MinidoracatAutoDrive/Uploads/summary-N.log         行程摘要，8 檔 × 1MB 輪流（每列伺服器補 srv／u）
--
-- 信任邊界：玩家身分只取 OnClientCommand actor（GameServer.java:2264）；資料夾、檔名、
-- index 欄位都由伺服器產生或清理。客戶端只能寫進自己的資料夾。收到就寫、不在記憶體累積
-- 內容（每位玩家只記一筆進行中的中繼資料）。
-- 沒有刪檔 API：清除＝寫空檔，資料夾保留。writeLog 不用：ZLogger 超過 10MB 以同名重開
-- 等於清空（ZLogger.java:95-101）。
if isClient() then return end

require "MDAD"

local S = {}
MDADUploadServer = S

local ROOT = "MinidoracatAutoDrive/Uploads"
local INDEX = ROOT .. "/index.txt"
local SLOTS = 32
local CHUNK_MAX = 10000
local CLIP_MAX = 1000000
local SUM_FILES = 8
local SUM_FILE_MAX = 1048576
local HOUR_MS = 3600000
local HOUR_BUDGET = 12000000
local STALE_MS = 300000
local MB = 1048576
local KINDS = { stuck = true, fault = true, contact = true, takeover = true,
    unstick = true, route = true, brake = true }
S.SLOTS, S.CHUNK_MAX, S.CLIP_MAX = SLOTS, CHUNK_MAX, CLIP_MAX

local loaded = false
local folders = {}      -- folder → { user = , slots = { [i] = clip } }
local userFolder = {}   -- username → folder
local total = 0         -- 現存片段字元數
local rows = 0          -- index 列數（整理門檻）
local live = 0
local sumIdx, sumBytes = 1, 0
local inprog = {}       -- username → 進行中訊息
local budget = {}       -- username → { start, used }

local function finite(n)
    return type(n) == "number" and n * 0 == 0
end

local function isInt(n, lo, hi)
    return finite(n) and math.floor(n) == n and n >= lo and n <= hi
end

local function now()
    return getTimestampMs()
end

-- TSV 欄位：去 tab／換行、限長。
local function cell(v, maxLen)
    local s = tostring(v == nil and "" or v)
    s = string.gsub(s, "[%z\1-\31]", " ")
    if #s > maxLen then s = string.sub(s, 1, maxLen) end
    return s
end

local function numCell(v)
    if not finite(v) then return "" end
    return tostring(v)
end

local function clipName(i)
    if i < 10 then return "clip-0" .. i .. ".log" end
    return "clip-" .. i .. ".log"
end

local function writeFile(path, text, append)
    local w = getFileWriter(path, true, append == true)
    if not w then return false end
    local ok = pcall(function() w:write(text) end)
    pcall(function() w:close() end)
    return ok
end

local function jstr(s)
    s = string.gsub(tostring(s or ""), "\\", "\\\\")
    s = string.gsub(s, "\"", "\\\"")
    s = string.gsub(s, "[%z\1-\31]", " ")
    return '"' .. s .. '"'
end

-- 玩家名 → 資料夾名：保留可讀（含中文），只換掉路徑危險字元；撞名加 ~N。
local function folderFor(user)
    local f = userFolder[user]
    if f then return f end
    local base = string.gsub(user, '[%z\1-\31/\\:%*%?"<>|]', "_")
    base = string.gsub(base, "%.%.+", "_")
    base = string.gsub(base, "^[%.%s]+", "_")
    base = string.gsub(base, "[%.%s]+$", "_")
    if #base > 48 then base = string.sub(base, 1, 48) end
    if base == "" then base = "player" end
    f = base
    local n = 2
    while folders[f] and folders[f].user ~= user do
        f = base .. "~" .. n
        n = n + 1
    end
    if not folders[f] then folders[f] = { user = user, slots = {} } end
    userFolder[user] = f
    return f
end

local function indexRow(c)
    return table.concat({ "C", c.id, numCell(c.ts), c.folder, tostring(c.slot),
        tostring(c.bytes), c.kind, tostring(c.pri), numCell(c.trig), c.rev, c.veh,
        numCell(c.x), numCell(c.y), c.user, numCell(c.drive) }, "\t")
end

local HEADER = "# type\tid\tserverTs\tfolder\tslot\tbytes\tkind\tpri\ttrig\trev\tveh\tx\ty\tuser\tdrive"

-- 整理：只留現存片段（依伺服器接收時間）＋目前摘要檔。
local function compact()
    local list, n = {}, 0
    for _, fo in pairs(folders) do
        for _, c in pairs(fo.slots) do
            n = n + 1
            list[n] = c
        end
    end
    -- 插入排序（Kahlua table.sort 在已排序輸入會堆疊溢位；此處僅啟動／整理時跑）
    local i = 2
    while i <= n do
        local c = list[i]
        local j = i - 1
        while j >= 1 and list[j].ts > c.ts do
            list[j + 1] = list[j]
            j = j - 1
        end
        list[j + 1] = c
        i = i + 1
    end
    local out, m = { HEADER }, 1
    i = 1
    while i <= n do
        m = m + 1
        out[m] = indexRow(list[i])
        i = i + 1
    end
    m = m + 1
    out[m] = "S\t" .. sumIdx
    writeFile(INDEX, table.concat(out, "\n", 1, m) .. "\n", false)
    rows = m
    live = n
end

local function appendRow(line)
    writeFile(INDEX, line .. "\n", true)
    rows = rows + 1
    if rows > live * 2 + 200 then compact() end
end

local function split(line)
    local t, n = {}, 0
    local start = 1
    while true do
        local i = string.find(line, "\t", start, true)
        n = n + 1
        if not i then t[n] = string.sub(line, start); break end
        t[n] = string.sub(line, start, i - 1)
        start = i + 1
    end
    return t, n
end

local function load()
    if loaded then return end
    loaded = true
    local r = getFileReader(INDEX, false)
    if r then
        while true do
            local line = r:readLine()
            if line == nil then break end
            local t, n = split(line)
            if t[1] == "C" and n >= 15 then
                local slot = tonumber(t[5])
                local folder = t[4]
                if isInt(slot, 1, SLOTS) and folder ~= "" then
                    local fo = folders[folder]
                    if not fo then fo = { user = t[14], slots = {} }; folders[folder] = fo end
                    local old = fo.slots[slot]
                    if old then total = total - old.bytes end
                    local c = { id = t[2], ts = tonumber(t[3]) or 0, folder = folder, slot = slot,
                        bytes = tonumber(t[6]) or 0, kind = t[7], pri = tonumber(t[8]) or 9,
                        trig = tonumber(t[9]), rev = t[10], veh = t[11], x = tonumber(t[12]),
                        y = tonumber(t[13]), user = t[14], drive = tonumber(t[15]) }
                    fo.slots[slot] = c
                    total = total + c.bytes
                    if t[14] ~= "" then userFolder[t[14]] = folder end
                end
            elseif t[1] == "X" and n >= 3 then
                local fo = folders[t[2]]
                local slot = tonumber(t[3])
                if fo and slot and fo.slots[slot] then
                    total = total - fo.slots[slot].bytes
                    fo.slots[slot] = nil
                end
            elseif t[1] == "S" and n >= 2 then
                local idx = tonumber(t[2])
                if isInt(idx, 1, SUM_FILES) then sumIdx = idx end
            end
        end
        pcall(function() r:close() end)
    end
    -- 目前摘要檔已寫多少（最多 1MB，只在啟動讀一次）
    local sr = getFileReader(ROOT .. "/summary-" .. sumIdx .. ".log", false)
    if sr then
        while true do
            local line = sr:readLine()
            if line == nil then break end
            sumBytes = sumBytes + #line + 1
        end
        pcall(function() sr:close() end)
    end
    compact()
end

local function clearSlot(fo, folder, slot)
    local c = fo.slots[slot]
    if not c then return end
    writeFile(ROOT .. "/" .. folder .. "/" .. clipName(slot), "", false)
    total = total - c.bytes
    fo.slots[slot] = nil
    live = live - 1
    appendRow("X\t" .. folder .. "\t" .. slot)
end

-- 全伺服器最舊的片段（總量上限用）。
local function evictOldest(skipFolder, skipSlot)
    local vf, vs, vc = nil, nil, nil
    for folder, fo in pairs(folders) do
        for slot, c in pairs(fo.slots) do
            if not (folder == skipFolder and slot == skipSlot)
                    and (not vc or c.ts < vc.ts) then
                vf, vs, vc = folder, slot, c
            end
        end
    end
    if not vc then return false end
    clearSlot(folders[vf], vf, vs)
    return true
end

-- 選槽：空槽優先；否則覆蓋優先級最低（pri 數字最大）中最舊的。
local function pickSlot(fo, folder, busy)
    local i = 1
    while i <= SLOTS do
        if not fo.slots[i] and i ~= busy then return i end
        i = i + 1
    end
    local vs, vc = nil, nil
    i = 1
    while i <= SLOTS do
        local c = fo.slots[i]
        if c and i ~= busy and (not vc or c.pri > vc.pri or (c.pri == vc.pri and c.ts < vc.ts)) then
            vs, vc = i, c
        end
        i = i + 1
    end
    return vs
end

local function capBytes()
    if finite(S.capOverride) then return S.capOverride end
    local mb = MDAD.sandbox("DiagnosticsUploadMaxMB", 2048)
    if not finite(mb) or mb < 128 then mb = 128 end
    return mb * MB
end

local function budgetOk(user, t, len)
    local b = budget[user]
    if not b or t < b.start or t - b.start >= HOUR_MS then
        b = { start = t, used = 0 }
        budget[user] = b
    end
    if b.used + len > HOUR_BUDGET then return false end
    b.used = b.used + len
    return true
end

local function writeSummary(user, data, t)
    if string.sub(data, 1, 1) ~= "{" then return end
    data = string.gsub(data, "[\r\n]", " ")
    local line = '{"srv":' .. tostring(t) .. ',"u":' .. jstr(user) .. ',' .. string.sub(data, 2)
    if sumBytes + #line + 1 > SUM_FILE_MAX then
        sumIdx = sumIdx % SUM_FILES + 1
        sumBytes = 0
        writeFile(ROOT .. "/summary-" .. sumIdx .. ".log", "", false)
        appendRow("S\t" .. sumIdx)
    end
    if writeFile(ROOT .. "/summary-" .. sumIdx .. ".log", line .. "\n", true) then
        sumBytes = sumBytes + #line + 1
    end
end

local function beginClip(user, args, t)
    local len = args.len
    if not isInt(len, 1, CLIP_MAX) or len > args.n * CHUNK_MAX then return nil end
    if not KINDS[args.kind] or not isInt(args.pri, 1, 9) then return nil end
    if not budgetOk(user, t, len) then return nil end
    local folder = folderFor(user)
    local fo = folders[folder]
    local slot = pickSlot(fo, folder, nil)
    if not slot then return nil end
    if fo.slots[slot] then clearSlot(fo, folder, slot) end
    local cap = capBytes()
    while total + len > cap do
        if not evictOldest(folder, slot) then break end
    end
    local p = {
        id = args.id, n = args.n, len = len, q = 0, got = 0, folder = folder, slot = slot,
        path = ROOT .. "/" .. folder .. "/" .. clipName(slot), at = t,
        kind = args.kind, pri = args.pri,
        trig = finite(args.trig) and args.trig or nil,
        drive = finite(args.drive) and args.drive or nil,
        x = finite(args.x) and args.x or nil, y = finite(args.y) and args.y or nil,
        rev = cell(args.rev, 32), veh = cell(args.veh, 64),
    }
    return p
end

-- 一塊資料：q=1 開新訊息（檔頭中繼資料只在第一塊），之後依序接續；亂序／逾時即放棄。
function S.receive(player, args)
    if MDAD.sandbox("DiagnosticsUpload", false) ~= true then return false end
    if type(args) ~= "table" then return false end
    local data = args.data
    if type(data) ~= "string" or #data < 1 or #data > CHUNK_MAX then return false end
    if not isInt(args.id, 1, 1e12) or not isInt(args.n, 1, CLIP_MAX / CHUNK_MAX + 1)
            or not isInt(args.q, 1, args.n) then
        return false
    end
    local user = player:getUsername()
    if type(user) ~= "string" or user == "" then return false end
    load()
    local t = now()
    if args.k == "sum" then
        if args.n ~= 1 or not budgetOk(user, t, #data) then return false end
        writeSummary(user, data, t)
        return true
    end
    if args.k ~= "clip" then return false end
    local p = inprog[user]
    if args.q == 1 then
        p = beginClip(user, args, t)
        inprog[user] = p
        if not p then return false end
    elseif not p or p.id ~= args.id or args.q ~= p.q + 1 or t - p.at > STALE_MS then
        inprog[user] = nil
        return false
    end
    -- 實際內容不得超過第一塊宣告的長度（總量上限依宣告預先騰出空間）
    if p.got + #data > p.len then
        inprog[user] = nil
        return false
    end
    if not writeFile(p.path, data, args.q > 1) then
        inprog[user] = nil
        return false
    end
    p.q, p.got, p.at = args.q, p.got + #data, t
    if p.q < p.n then return true end
    inprog[user] = nil
    local fo = folders[p.folder]
    -- 多塊期間同一槽可能被總量上限清掉（別人的大片段），此時仍以完成的內容記回。
    local c = { id = p.folder .. "/" .. clipName(p.slot) .. "@" .. tostring(t), ts = t,
        folder = p.folder, slot = p.slot, bytes = p.got, kind = p.kind, pri = p.pri,
        trig = p.trig, rev = p.rev, veh = p.veh, x = p.x, y = p.y,
        user = cell(user, 64), drive = p.drive }
    if fo.slots[p.slot] then total = total - fo.slots[p.slot].bytes else live = live + 1 end
    fo.slots[p.slot] = c
    total = total + c.bytes
    appendRow(indexRow(c))
    return true
end

-- 測試用：清記憶體狀態（重開伺服器）
function S._reset()
    loaded, folders, userFolder, total, rows, live = false, {}, {}, 0, 0, 0
    sumIdx, sumBytes, inprog, budget = 1, 0, {}, {}
end

function S._stats()
    return { total = total, live = live, rows = rows, sumIdx = sumIdx, folders = folders }
end
