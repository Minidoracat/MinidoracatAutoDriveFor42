-- MDAD_TrafficRelay.lua — 伺服器把遠方「有人駕駛」的車轉送給自駕中的玩家（1001i；使用者核准、沙盒 TrafficRelay）。
--
-- 為什麼要轉送：MP 客戶端只收得到「相關範圍」內的車輛封包。伺服器轉發車輛物理封包時只送給 isRelevantTo
-- 的連線（VehiclePhysicsPacket.processServer → sendToRelativeClients），範圍是以客戶端 chunk 寬換算的
-- Chebyshev 方框（UdpConnection.isRelevantTo；客戶端 chunkGridWidth 夾 12..20 → 約 ±64～±88 格），
-- 伺服器設定放不大。對向兩車各 100 km/h 時，看到對方到碰面只剩約 1.2–1.6 秒：拖車側移、讓車都來不及
-- （正式服 0.16.0 Dixie 兩台拖車對開）。
--
-- 做法：每 PERIOD_MS 一次，收集所有有人駕駛的車（含它拖著的掛車）的車身中心、速度、前向與半長寬；對每位
-- 自駕中（Usage heartbeat 仍有效，MDAD.isAutoUsageActive）的駕駛，送出他前方 NEAR_M～RANGE_M 內最近的
-- MAX_CARS 台。客戶端（Drive.mergeRelay）只拿來提早靠右錯開／跟車減速；最後的閃避仍以原生同步的即時位置為準。
-- 量：每台 9 個數字（約 160 B），3 台約 0.5 KB／次＝每位自駕玩家約 2 KB/s；CPU 是「自駕人數 × 行駛車數」次距離比較。
--
-- 伺服器端讀到的位置、速度、旋轉都是駕駛者客戶端上傳的物理封包寫進來的（VehiclePhysicsPacket.processServer：
-- setX/setY、jniTransform、jniLinearVelocity）；掛車若沒有速度，以兩次轉送間的位移估。
-- 本檔在專用伺服器與客戶端都會被載入（media/lua/server），isClient() 早退；SP 沒有別的駕駛，不跑。
if isClient() then return end

require "MDAD"

local PERIOD_MS = 250
local RANGE_M = 300
local NEAR_M = 40   -- 這麼近一定在原生同步範圍內（Chebyshev ±64 格以上），不必轉送；自己與自己的掛車也一定在這裡面
local BEHIND_M = 30 -- 在自駕車後方超過這麼遠不送（後車追上來前就會進入原生範圍）
local MAX_CARS = 8
local POS_TTL_MS = 10000
local F = MDAD.RELAY_FIELDS

local nextMs = 0
local cars = {}    -- 本次收集的行駛車，扁平 F 欄一台：id, x, y, vx, vy, fx, fy, hw, hl
local carsN = 0
local OWNER_FIELDS = 5
local owners = {}  -- 本次自駕中的駕駛：player, x, y, fx, fy（每 OWNER_FIELDS 欄一位）
local ownersN = 0
local lastPos = {} -- id → { x, y, t }：讀不到速度時以位移估
local pruneMs = 0
local pickD = {}   -- 單一駕駛的最近 MAX_CARS 台（距離平方）與 cars 索引，重用
local pickI = {}

local function finite(n)
    return type(n) == "number" and n * 0 == 0
end

-- 車身中心（質心偏移後）、速度、前向（單位向量）、半寬、半長；任何 getter 失敗回 nil。
local function bodyState(v, out)
    local script = v:getScript()
    local ext, com = script:getExtents(), script:getCenterOfMassOffset()
    v:getWorldPos(com:x(), 0, com:z(), out)
    local x, y = out:x(), out:y()
    v:getForwardVector(out)
    local fx, fy = out:x(), out:z()
    v:getLinearVelocity(out)
    local vx, vy = out:x(), out:z()
    return x, y, vx, vy, fx, fy, ext:x() * 0.5, ext:z() * 0.5
end

local function addCar(v, now, out)
    local okId, id = pcall(v.getId, v)
    if not okId or not finite(id) then return end
    local ok, x, y, vx, vy, fx, fy, hw, hl = pcall(bodyState, v, out)
    if not ok or not (finite(x) and finite(y) and finite(fx) and finite(fy) and finite(hw) and finite(hl)) then return end
    local fl = math.sqrt(fx * fx + fy * fy)
    if fl < 1e-6 then return end
    fx, fy = fx / fl, fy / fl
    if not (finite(vx) and finite(vy)) then vx, vy = 0, 0 end
    local lp = lastPos[id]
    if vx * vx + vy * vy < 0.25 and lp and now - lp.t >= 150 then
        local dt = (now - lp.t) / 1000
        local ux, uy = (x - lp.x) / dt, (y - lp.y) / dt
        if ux * ux + uy * uy >= 1 and ux * ux + uy * uy <= 4900 then vx, vy = ux, uy end
    end
    if not lp then
        lp = {}
        lastPos[id] = lp
    end
    lp.x, lp.y, lp.t = x, y, now
    local b = carsN * F
    cars[b + 1], cars[b + 2], cars[b + 3], cars[b + 4], cars[b + 5] = id, x, y, vx, vy
    cars[b + 6], cars[b + 7], cars[b + 8], cars[b + 9] = fx, fy, hw, hl
    carsN = carsN + 1
end

local function collect(now)
    carsN, ownersN = 0, 0
    local players = getOnlinePlayers()
    if not players then return end
    local out = BaseVehicle.allocVector3f()
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        local v = p and p:getVehicle()
        if v and v:isDriver(p) then
            local before = carsN
            addCar(v, now, out)
            local okT, trailer = pcall(v.getVehicleTowing, v)
            if okT and trailer then addCar(trailer, now, out) end
            if carsN > before and MDAD.isAutoUsageActive(v) then
                local b, o = before * F, ownersN * OWNER_FIELDS
                owners[o + 1], owners[o + 2], owners[o + 3] = p, cars[b + 2], cars[b + 3]
                owners[o + 4], owners[o + 5] = cars[b + 6], cars[b + 7]
                ownersN = ownersN + 1
            end
        end
    end
    BaseVehicle.releaseVector3f(out)
end

-- 一位自駕駕駛的轉送：前方 NEAR_M～RANGE_M 內最近 MAX_CARS 台（自己與自己的掛車在 NEAR_M 內，天然排除）。
local function send(o)
    local player, ax, ay, afx, afy = owners[o + 1], owners[o + 2], owners[o + 3], owners[o + 4], owners[o + 5]
    local k = 0
    local range2, near2 = RANGE_M * RANGE_M, NEAR_M * NEAR_M
    for c = 0, carsN - 1 do
        local b = c * F
        local dx, dy = cars[b + 2] - ax, cars[b + 3] - ay
        local d2 = dx * dx + dy * dy
        if d2 >= near2 and d2 <= range2 and dx * afx + dy * afy >= -BEHIND_M
                and (k < MAX_CARS or d2 < pickD[k]) then
            -- 插入排序保留最近 MAX_CARS 台（滿了就擠掉最遠那台）
            local j = k < MAX_CARS and k or k - 1
            if k < MAX_CARS then k = k + 1 end
            while j > 0 and pickD[j] > d2 do
                pickD[j + 1], pickI[j + 1] = pickD[j], pickI[j]
                j = j - 1
            end
            pickD[j + 1], pickI[j + 1] = d2, b
        end
    end
    if k == 0 then return end
    local payload = { n = k }
    for j = 1, k do
        local b, pb = pickI[j], (j - 1) * F
        for f = 1, F do payload[pb + f] = cars[b + f] end
    end
    sendServerCommand(player, MDAD.MOD_ID, MDAD.CMD_TRAFFIC, payload)
end

local function prune(now)
    if now < pruneMs then return end
    pruneMs = now + POS_TTL_MS
    local stale = nil
    for id, lp in pairs(lastPos) do
        if now - lp.t > POS_TTL_MS then
            stale = stale or {}
            stale[#stale + 1] = id
        end
    end
    if stale then
        for i = 1, #stale do lastPos[stale[i]] = nil end
    end
end

local function onTick()
    local now = getTimestampMs()
    if now < nextMs then return end
    nextMs = now + PERIOD_MS
    if not isServer() or MDAD.sandbox("TrafficRelay", true) ~= true then return end
    collect(now)
    for o = 0, ownersN - 1 do
        send(o * OWNER_FIELDS)
        owners[o * OWNER_FIELDS + 1] = nil -- 不跨 tick 持有 Java 玩家物件
    end
    prune(now)
end

Events.OnTick.Add(onTick)
