-- MDAD_Summon.lua — 召喚的伺服器權威（MP 專用伺服器與 SP 共用；契約見 shared/MDAD.lua 的「召喚 API」段）。
--
-- 召喚＝車外的召喚者客戶端用 AutoDrive 的駕駛迴圈推一台沒人的車。車上沒有駕駛，引擎不會替我們做的事都在這裡：
--   ① startSummon 驗條件、需要時代為發動（tryStartEngine(true)：沒人在車上照樣進 Starting，haveKey 一定要傳 true，
--      否則 getDriver() 是 nil 會 NPE＝BaseVehicle.java:7570-7598）；
--   ② 引擎 Running 後把物理權限交給召喚者（authorizationServerOnSeat(p,true)＝BaseVehicle.java:3979-3989，權限屬伺服器
--      才給；拖車中走 addPointConstraint 不給，所以開始前就拒絕拖車），送 SummonStart；
--   ③ 每 250ms 輪詢中止條件——伺服器沒有座位、斷線的 Lua 事件（OnEnterVehicle／OnExitVehicle／OnDisconnect 只在客戶端
--      觸發），引擎也不會收回車外玩家的權限，onlineID 還會被新玩家重用，所以只能靠輪詢；
--   ④ finish 是唯一出口：交還權限（authorizationChanged(getDriver())＝BaseVehicle.java:10130-10136：沒人＝Server、有人
--      坐駕駛座＝交給他）、熄掉召喚發動的引擎（車上有人不熄）、呼叫 onEnd、送 SummonEnd。
-- session 只存純量與呼叫端的回呼，不跨 tick 持有 Java 物件（同 MDAD_TrafficRelay）。
-- SP 走同一份：沒有權限交接，SummonStart／SummonEnd 改成直接呼叫 client Driver（MDAD.Drive），客戶端的 Summon 心跳也直接
-- 呼叫 Summon.onCommand（同 Driver reportAutoUsage 的 SP 分支）。
if isClient() then return end

require "MDAD"

local Summon = {}
MDAD.Summon = Summon

Summon.POLL_MS = 250
Summon.START_MS = 8000      -- 代為發動等 Running 的上限（實測約 1.5 秒進 Running）
Summon.RETRY_MS = 2000      -- 發動中引擎回到 Idle（上一次失敗、或剛熄火還在 ShuttingDown 時按的那次沒進 Starting）就重按
Summon.START_TRIES = 3      -- 最多按幾次（每次 Idle→Starting 扣 0.025 電，同玩家轉鑰匙；E2E tesla-sum-1027-sp-c）
Summon.MOVING_KMH = 0.8     -- 同原版 isStopped 的門檻（BaseVehicle.java:4259-4260）
Summon.START_CHARGE = 0.1   -- tryStartEngine 在電瓶 ≤0.1 時只會發動失敗（BaseVehicle.java:7582-7586）

local KEY = {
    OFF = "UI_MinidoracatAutoDrive_SummonOff",
    TOO_FAR = "UI_MinidoracatAutoDrive_SummonTooFar",
    OCCUPIED = "UI_MinidoracatAutoDrive_SummonOccupied",
    TOWING = "UI_MinidoracatAutoDrive_SummonTowing",
    MOVING = "UI_MinidoracatAutoDrive_SummonMoving",
    BUSY = "UI_MinidoracatAutoDrive_SummonBusy",
    ON_FOOT = "UI_MinidoracatAutoDrive_SummonOnFoot",
    ENGINE_FAIL = "UI_MinidoracatAutoDrive_SummonEngineFail",
    ENGINE = "UI_MinidoracatAutoDrive_EngineOff",
    MODULE = "UI_MinidoracatAutoDrive_NeedModule",
    API = "UI_MinidoracatAutoDrive_NavApiMissing",
}
Summon.KEY = KEY

local sessions = {} -- vehicleId → { username, playerId, startedMs, beatAt, startUntil, tries, retryAt, phase, engineBy, mode, tx,
--                     ty, dir, onEnd }
local count = 0
local nextPollMs = 0
local pollIds = {} -- 輪詢時先抄下 id 再處理：finish 會刪表項，Kahlua 的 table 走 pairs 時不能改

local function log(msg)
    print("[" .. MDAD.MOD_ID .. "] summon " .. msg)
end

-- 召喚者：MP 以 onlineID 反查再核對 username（onlineID 會被新玩家重用＝GameServer.java:2670-2698）；SP 以 playerNum。
-- getPlayerByOnlineID＝LuaManager.java:3940。
local function findPlayer(sess)
    local p
    if isServer() then
        p = getPlayerByOnlineID(sess.playerId)
    else
        p = getSpecificPlayer(sess.playerId)
    end
    if not p or p:getUsername() ~= sess.username then return nil end
    return p
end

local function dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy
end

local function towing(vehicle)
    return vehicle:getVehicleTowing() ~= nil or vehicle:getVehicleTowedBy() ~= nil
end

-- 召喚者（或 target 的目標）超出沙盒範圍？
local function outOfRange(sess, player, vehicle)
    local r = MDAD.summonRange()
    if r <= 0 then return true end
    local px, py = player:getX(), player:getY()
    if dist2(px, py, vehicle:getX(), vehicle:getY()) > r * r then return true end
    return sess.mode == "target" and dist2(px, py, sess.tx, sess.ty) > r * r
end

-- 這位玩家（身分）有沒有正在進行的召喚：一人同時只叫一台
local function sessionOf(username, playerId)
    for vid, sess in pairs(sessions) do
        if sess.username == username and sess.playerId == playerId then return vid, sess end
    end
    return nil
end

-- SP 小地圖與伺服器在同一個 Lua state：起步就能擋 v13 不足（MP 的專用伺服器沒有小地圖 API，由客戶端回 NO_ROUTE）
local function routeApiOk()
    local api = MinidoracatMiniMapAPI
    if type(api) ~= "table" then return false end
    local v = api.navApiVersion
    return type(v) == "number" and v >= 13 and type(api.requestRouteFrom) == "function"
        and type(api.requestDetourFrom) == "function"
end

function Summon.start(player, vehicle, opts)
    -- ① 格式
    local mode, tx, ty, dir = MDAD.summonOpts(opts)
    if not mode or not player or not vehicle then return false, MDAD.KEY_SUMMON_INVALID end
    local onEnd = opts and opts.onEnd
    if onEnd ~= nil and type(onEnd) ~= "function" then return false, MDAD.KEY_SUMMON_INVALID end
    -- ② 召喚者
    if player:isDead() then return false, MDAD.KEY_SUMMON_INVALID end
    if player:getVehicle() ~= nil then return false, KEY.ON_FOOT end
    local username, playerId = MDAD.playerIdentity(player)
    if not username then return false, MDAD.KEY_SUMMON_INVALID end
    -- ③ 沙盒距離（同 outOfRange，只是 session 還沒建）
    local r = MDAD.summonRange()
    if r <= 0 then return false, KEY.OFF end
    local px, py = player:getX(), player:getY()
    if dist2(px, py, vehicle:getX(), vehicle:getY()) > r * r
            or (mode == "target" and dist2(px, py, tx, ty) > r * r) then
        return false, KEY.TOO_FAR
    end
    -- ④ 車
    if vehicle:getDriver() ~= nil or vehicle:hasPassenger() then return false, KEY.OCCUPIED end
    if towing(vehicle) then return false, KEY.TOWING end
    local kmh = vehicle:getCurrentSpeedKmHour()
    if not (kmh < Summon.MOVING_KMH and kmh > -Summon.MOVING_KMH) then return false, KEY.MOVING end
    local vid = vehicle:getId()
    if not MDAD.isFiniteInt(vid) then return false, MDAD.KEY_SUMMON_INVALID end
    if sessions[vid] or sessionOf(username, playerId) then return false, KEY.BUSY end
    -- 權限已經在某個客戶端手上（有人剛下車、別人在拖動）：交出去會兩邊搶
    if isServer() and vehicle:getNetPlayerId() ~= -1 then return false, KEY.BUSY end
    if not MDAD.isBatteryLive(vehicle) then return false, KEY.ENGINE end
    if MDAD.sandbox("NeedItemForAutoDrive", true) == true and not MDAD.isAutoInstalled(vehicle) then
        return false, KEY.MODULE
    end
    if mode ~= "dumb" then
        local ok, why = MDAD.summonNavOk(player, vehicle)
        if not ok then return false, why end
        if not isServer() and not routeApiOk() then return false, KEY.API end
    end
    -- ⑤ 引擎
    local running = vehicle:isEngineRunning()
    if not running then
        if not (opts and opts.startEngine == true) then return false, KEY.ENGINE end
        if vehicle:getBatteryCharge() <= Summon.START_CHARGE then return false, KEY.ENGINE_FAIL end
    end
    -- ⑥ session。交權限與 SummonStart 留給下一次輪詢（≤250ms）：onEnd 一律在 startSummon 回傳之後才可能被呼叫
    local now = getTimestampMs()
    sessions[vid] = {
        username = username, playerId = playerId, startedMs = now, beatAt = now,
        startUntil = now + Summon.START_MS, tries = running and 0 or 1, retryAt = now + Summon.RETRY_MS,
        phase = "starting", engineBy = not running, mode = mode, tx = tx, ty = ty, dir = dir, onEnd = onEnd,
    }
    count = count + 1
    nextPollMs = 0
    if not running then vehicle:tryStartEngine(true) end
    log("start vid=" .. tostring(vid) .. " by=" .. username .. " mode=" .. mode
        .. " engine=" .. (running and "running" or "start"))
    return true
end

-- 唯一出口。vehicle／player 可省略（重新解析）。回 true＝真的收掉一個 session。
function Summon.finish(vid, code, vehicle, player)
    local sess = sessions[vid]
    if not sess then return false end
    sessions[vid] = nil
    count = count - 1
    if not MDAD.SUMMON_CODES[code] then code = "CANCELLED" end
    if vehicle == nil then vehicle = getVehicleById(vid) end
    if player == nil then player = findPlayer(sess) end
    local shut = false
    if vehicle then
        -- 權限仍在召喚者手上才交還（不論停止碼；碼 AUTH 也可能是綁車 MOD 收回駕駛權時呼叫、權限還在召喚者）；
        -- 已被別的客戶端拿走就不碰。B 坐上駕駛座時這一行把權限交給 B
        if isServer() and vehicle:getNetPlayerId() == sess.playerId then
            vehicle:authorizationChanged(vehicle:getDriver())
        end
        -- 發動中（Starting／RetryingStarting／StartingSuccess）也要熄：只看 isEngineRunning 的話，租約刪掉後引擎狀態機
        -- 照樣轉進 Running，無人車自己怠速（VehicleEngine.java:424-434 shutOff 在任何狀態都轉進關閉流程）
        local st = tostring(vehicle:getEngineState())
        if sess.engineBy and vehicle:getDriver() == nil and not vehicle:hasPassenger()
                and (vehicle:isEngineRunning() or st == "Starting" or st == "RetryingStarting" or st == "StartingSuccess") then
            vehicle:shutOff()
            shut = true
        end
    end
    if sess.onEnd then
        local ok, err = pcall(sess.onEnd, vehicle, code, player)
        if not ok then log("onEnd failed vid=" .. tostring(vid) .. ": " .. tostring(err)) end
    end
    local args = { vehicleId = vid, code = code, to = sess.username }
    if isServer() then
        if player then sendServerCommand(player, MDAD.MOD_ID, MDAD.CMD_SUMMON_END, args) end
    else
        local d = MDAD.Drive
        if d then d.summonEndCmd(args) end
    end
    log("end vid=" .. tostring(vid) .. " by=" .. sess.username .. " code=" .. code .. " phase=" .. sess.phase
        .. " ms=" .. tostring(getTimestampMs() - sess.startedMs) .. " shut=" .. tostring(shut))
    return true
end

-- 引擎 Running：交權限（MP）並通知召喚者的客戶端開始開
local function handover(vid, sess, vehicle, player, now)
    if isServer() then
        vehicle:authorizationServerOnSeat(player, true)
        if vehicle:getNetPlayerId() ~= sess.playerId then return Summon.finish(vid, "AUTH", vehicle, player) end
    end
    sess.phase, sess.beatAt = "driving", now
    -- 鍵同 startSummon 的 opts（客戶端用同一支 MDAD.summonOpts 驗）
    local info = { vehicleId = vid, to = sess.username, mode = sess.mode, x = sess.tx, y = sess.ty, dir = sess.dir }
    if isServer() then
        sendServerCommand(player, MDAD.MOD_ID, MDAD.CMD_SUMMON_START, info)
    else
        local d = MDAD.Drive
        if not d then return Summon.finish(vid, "FAULT", vehicle, player) end
        d.summonStartCmd(info)
    end
end

local function poll(vid, sess, now)
    local vehicle = getVehicleById(vid)
    if not vehicle or vehicle:isRemovedFromWorld() then return Summon.finish(vid, "GONE", vehicle) end
    local player = findPlayer(sess)
    if not player then return Summon.finish(vid, "LEFT", vehicle) end
    if player:isDead() then return Summon.finish(vid, "DEAD", vehicle, player) end
    if player:getVehicle() ~= nil then return Summon.finish(vid, "BOARDED", vehicle, player) end
    if vehicle:getDriver() ~= nil then return Summon.finish(vid, "TAKEOVER", vehicle, player) end
    if vehicle:hasPassenger() then return Summon.finish(vid, "OCCUPIED", vehicle, player) end
    if towing(vehicle) then return Summon.finish(vid, "TOWING", vehicle, player) end
    if outOfRange(sess, player, vehicle) then return Summon.finish(vid, "FAR", vehicle, player) end
    if sess.phase == "starting" then
        if vehicle:isEngineRunning() then return handover(vid, sess, vehicle, player, now) end
        if now >= sess.startUntil then return Summon.finish(vid, "ENGINE_START", vehicle, player) end
        if sess.engineBy and now >= sess.retryAt and sess.tries < Summon.START_TRIES
                and tostring(vehicle:getEngineState()) == "Idle" then
            sess.tries, sess.retryAt = sess.tries + 1, now + Summon.RETRY_MS
            vehicle:tryStartEngine(true)
        end
        return
    end
    if isServer() and vehicle:getNetPlayerId() ~= sess.playerId then
        return Summon.finish(vid, "AUTH", vehicle, player)
    end
    -- 熄火、電瓶沒電、模組被拆：伺服器自己收（不靠客戶端 driveGate；改過的客戶端照送心跳也留不住權限）
    if not vehicle:isEngineRunning() or not MDAD.isBatteryLive(vehicle) then
        return Summon.finish(vid, "ENGINE", vehicle, player)
    end
    if MDAD.sandbox("NeedItemForAutoDrive", true) == true and not MDAD.isAutoInstalled(vehicle) then
        return Summon.finish(vid, "MODULE", vehicle, player)
    end
    if now < sess.beatAt or now - sess.beatAt > MDAD.AUTO_USAGE_TTL_MS then
        return Summon.finish(vid, "TIMEOUT", vehicle, player)
    end
end

function Summon.tick()
    if count == 0 then return end
    local now = getTimestampMs()
    if now < nextPollMs then return end
    nextPollMs = now + Summon.POLL_MS
    local n = 0
    for vid in pairs(sessions) do
        n = n + 1
        pollIds[n] = vid
    end
    for i = 1, n do
        local vid = pollIds[i]
        pollIds[i] = nil
        local sess = sessions[vid]
        if sess then poll(vid, sess, now) end
    end
end

-- client 的 Summon 指令（MP 經 MDAD_Server 的 HANDLERS 與節流；SP 由 Driver 直接呼叫）。只接受持有者對自己那台車的
-- 心跳與停止；code 不在停止碼表就當 CANCELLED。回 true＝真的處理到自己的 session（節流表照 Usage 的規則清）。
function Summon.onCommand(player, args)
    if type(args) ~= "table" or type(args.active) ~= "boolean" or not MDAD.isFiniteInt(args.vehicleId) then return false end
    local sess = sessions[args.vehicleId]
    if not sess then return false end
    local username, playerId = MDAD.playerIdentity(player)
    if not username or username ~= sess.username or playerId ~= sess.playerId then return false end
    if args.active == false then
        local code = args.code
        if type(code) ~= "string" or not MDAD.SUMMON_CODES[code] then code = "CANCELLED" end
        -- 起步失敗的細分原因（客戶端 summonBegin；路線狀態或理由鍵）：只收短的英數字串、只印 log
        local why = args.why
        if type(why) == "string" and #why <= 64 and string.match(why, "^[%w_]+$") then
            log("stop vid=" .. tostring(args.vehicleId) .. " by=" .. username .. " code=" .. code .. " why=" .. why)
        end
        return Summon.finish(args.vehicleId, code, nil, player)
    end
    if sess.phase ~= "driving" then return false end
    sess.beatAt = getTimestampMs()
    -- 導航誰付（同駕駛：車上有電的 GPS＝車付，見 Summon.navOn；否則召喚者身上的 GPS）；前進／後退不導航
    if sess.mode ~= "dumb" then
        local vehicle = getVehicleById(args.vehicleId)
        if not (vehicle and MDAD.hasVehicleNavPower(vehicle)) then MDAD.setNavUsage(player) end
    end
    return true
end

function Summon.stop(vehicle, code)
    if not vehicle then return false end
    local vid = vehicle:getId()
    if not sessions[vid] then return false end
    if code == nil then code = "CANCELLED" end
    return Summon.finish(vid, code, vehicle)
end

function Summon.info(vehicle)
    local sess = vehicle and sessions[vehicle:getId()]
    if not sess then return nil end
    return { by = sess.username, phase = sess.phase, startedMs = sess.startedMs, mode = sess.mode }
end

-- 計費的唯一判準（MDAD.isAutoUsageActive 第一行、Consumption collect）：session 在開、心跳在 TTL 內、沒有駕駛、
-- 召喚者在線且身分相符、引擎在轉、電瓶有電、模組有裝。
function Summon.isActive(vehicle)
    if count == 0 or not vehicle then return false end
    local sess = sessions[vehicle:getId()]
    if not sess or sess.phase ~= "driving" then return false end
    local now = getTimestampMs()
    if now < sess.beatAt or now - sess.beatAt > MDAD.AUTO_USAGE_TTL_MS then return false end
    if vehicle:getDriver() ~= nil or not findPlayer(sess) then return false end
    if not vehicle:isEngineRunning() or not MDAD.isBatteryLive(vehicle) then return false end
    return MDAD.sandbox("NeedItemForAutoDrive", true) ~= true or MDAD.isAutoInstalled(vehicle)
end

-- 車上 GPS 算不算在導航（MDAD.vehicleUsageModes 的無駕駛分支、collect）：到我這裡／指定地點、車上有電的 GPS
-- ＝車付導航電與 GPS 油耗加成（同駕駛時 navUsageSource 先認車機）；前進／後退不導航。
function Summon.navOn(vehicle)
    if not Summon.isActive(vehicle) then return false end
    return sessions[vehicle:getId()].mode ~= "dumb" and MDAD.hasVehicleNavPower(vehicle)
end

-- Consumption 每遊戲分鐘只收「在線玩家所在的車」；召喚中的車沒人在上面，這裡補進去（扣這台車的 12V，同駕駛模式）
function Summon.collect(powerVehicles, powerNav)
    if count == 0 then return end
    for vid in pairs(sessions) do
        local vehicle = getVehicleById(vid)
        if vehicle and Summon.isActive(vehicle) then
            powerVehicles[vid] = vehicle
            if powerNav and Summon.navOn(vehicle) then powerNav[vid] = true end
        end
    end
end

-- 全部收掉（離線測試清場；回收掉幾個）。不另外把 sessions 掛出去：刪表項不走 finish 會漏交權限與 onEnd。
function Summon.finishAll(code)
    local ids, n = {}, 0
    for vid in pairs(sessions) do ids[#ids + 1] = vid end
    for i = 1, #ids do
        if Summon.finish(ids[i], code) then n = n + 1 end
    end
    return n
end

-- 召喚中撞東西：持權限的召喚者客戶端照常送原版 vehicle/crash、damageObjects（BaseVehicle.java:4648-4651 等），但原版
-- 伺服器要 vehicle:isDriver(player) 才套用（server/Vehicles/VehicleCommands.lua:282-314），沒有駕駛＝撞了不扣損。
-- 送的人是這台車的召喚持有者、車上沒有駕駛時，照原版同一支方法代為套用（參數信任度同原版信任駕駛）。只在 MP。
-- damageFromHitChr 引擎要本機駕駛才送（BaseVehicle.java:3856），召喚車實際不會來；留著是同一張原版指令表。
local CRASH = { crash = true, damageObjects = true, damageFromHitChr = true }
local function finiteNum(n) return type(n) == "number" and n * 0 == 0 end

function Summon.onVehicleCommand(module, command, player, args)
    if module ~= "vehicle" or not CRASH[command] or count == 0 or not player or type(args) ~= "table" then return end
    if not MDAD.isFiniteInt(args.vehicle) then return end
    local sess = sessions[args.vehicle]
    if not sess or sess.phase ~= "driving" then return end
    local username, playerId = MDAD.playerIdentity(player)
    if username ~= sess.username or playerId ~= sess.playerId then return end
    local vehicle = getVehicleById(args.vehicle)
    if not vehicle or vehicle:getDriver() ~= nil then return end
    if command == "crash" then
        if finiteNum(args.amount) and type(args.front) == "boolean" then vehicle:crash(args.amount, args.front) end
    elseif command == "damageObjects" then
        if finiteNum(args.damage) then vehicle:damageObjects(args.damage) end
    elseif finiteNum(args.dmgFront) and finiteNum(args.dmgBack) then
        vehicle:damageFromHitChr(args.dmgFront, args.dmgBack)
    end
end

Events.OnTick.Add(Summon.tick)
if isServer() then Events.OnClientCommand.Add(Summon.onVehicleCommand) end
