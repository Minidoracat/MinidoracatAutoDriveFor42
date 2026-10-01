-- test_relay.lua — 伺服器轉送遠方行進車（server/MDAD_TrafficRelay.lua）：以真程式碼跑（假 PZ 全域）。
-- 收集有人駕駛的車（含掛車）、只送給自駕中的駕駛、只送前方 NEAR～RANGE 內最近 8 台、不含自己與自己的掛車、
-- 沙盒關掉不送、伺服器讀不到速度時以位移估、節流 250ms。客戶端的接收與合併由 smoke_harness 的 (relay) 案鎖。
-- 執行：lua scripts/test_relay.lua（repo 根目錄）

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
local function checkNear(a, b, tol, label)
    check(type(a) == "number" and math.abs(a - b) <= tol, label .. " (got " .. tostring(a) .. ", want ~" .. tostring(b) .. ")")
end
local function scenario(title)
    scenarios = scenarios + 1
    print("scenario " .. scenarios .. ": " .. title)
end

-- ---------------------------------------------------------------- 假 PZ 全域
local nowMs = 1000000
local sandbox = { TrafficRelay = true }
local sent = {}
local auto = {}    -- 車 id → true：駕駛的 Usage heartbeat 有效（自駕中）
local players = {}
local tickFn = nil

function getTimestampMs() return nowMs end
function isClient() return false end
function isServer() return true end
function require() end
Events = { OnTick = { Add = function(fn) tickFn = fn end } }
function sendServerCommand(player, module, command, args)
    sent[#sent + 1] = { player = player, module = module, command = command, args = args }
end
function getOnlinePlayers()
    return { size = function() return #players end, get = function(_, i) return players[i + 1] end }
end
local function vec()
    local v = { _x = 0, _y = 0, _z = 0 }
    function v:x() return self._x end
    function v:y() return self._y end
    function v:z() return self._z end
    return v
end
BaseVehicle = { allocVector3f = vec, releaseVector3f = function() end }
MDAD = { MOD_ID = "MinidoracatAutoDriveFor42", CMD_TRAFFIC = "Traffic", RELAY_FIELDS = 9 }
function MDAD.sandbox(name, default)
    local v = sandbox[name]
    if v == nil then return default end
    return v
end
function MDAD.isAutoUsageActive(v) return auto[v._id] == true end

-- 車：中心 (x,y)、速度 (vx,vy)、前向 (fx,fy)；質心偏移 0、半寬 0.9、半長 2.3（getWorldPos 只加縱向偏移）
local function vehicle(id, x, y, vx, vy, fx, fy)
    local v = { _id = id, _x = x, _y = y, _vx = vx, _vy = vy, _fx = fx, _fy = fy }
    function v:getId() return self._id end
    function v:getScript()
        return {
            getExtents = function() local e = vec(); e._x, e._y, e._z = 1.8, 1.5, 4.6; return e end,
            getCenterOfMassOffset = function() return vec() end,
        }
    end
    function v:getWorldPos(lx, _, lz, out)
        out._x, out._y = self._x + lx, self._y + lz
        return out
    end
    function v:getForwardVector(out) out._x, out._z = self._fx, self._fy; return out end
    function v:getLinearVelocity(out) out._x, out._z = self._vx, self._vy; return out end
    function v:isDriver(p) return p._vehicle == self end
    function v:getVehicleTowing() return self._towing end
    return v
end
local function driver(v)
    local p = { _vehicle = v }
    function p:getVehicle() return self._vehicle end
    players[#players + 1] = p
    return p
end
local function lastTo(p)
    for i = #sent, 1, -1 do
        if sent[i].player == p then return sent[i].args end
    end
    return nil
end
local function idsOf(args)
    local t = {}
    for k = 0, (args and args.n or 0) - 1 do t[#t + 1] = args[k * 9 + 1] end
    return t
end
local function sentTo(p)
    local n = 0
    for i = 1, #sent do if sent[i].player == p then n = n + 1 end end
    return n
end

local fn, err = loadfile(MEDIA .. "server/MDAD_TrafficRelay.lua")
if not fn then error(err) end
fn()
check(type(tickFn) == "function", "OnTick 掛上轉送")
local function tick(ms)
    nowMs = nowMs + (ms or 250)
    tickFn()
end

-- ---------------------------------------------------------------- 情境
scenario("只送給自駕中的駕駛：前方 40～300m、不含自己、近／遠／後方不送")
local A = vehicle(1, 0, 0, 10, 0, 1, 0)
local pa = driver(A)
auto[1] = true
local B = vehicle(2, 200, 0, -20, 0, -1, 0)
local pb = driver(B)
driver(vehicle(3, 20, 0, -10, 0, -1, 0))   -- 太近：原生同步一定有
driver(vehicle(4, -100, 0, 10, 0, 1, 0))   -- 後方 100m
driver(vehicle(5, 400, 0, -20, 0, -1, 0))  -- 超過 300m
tick()
checkEq(sentTo(pa), 1, "自駕中的 A 收到一次轉送")
checkEq(sentTo(pb), 0, "沒在自駕的 B 不收")
local args = lastTo(pa)
checkEq(args and args.n, 1, "A 只收到前方範圍內的一台")
checkEq(sent[1].module, "MinidoracatAutoDriveFor42", "module＝MOD id")
checkEq(sent[1].command, "Traffic", "command＝Traffic")
checkEq(args[1], 2, "欄 1：車 id")
checkNear(args[2], 200, 1e-9, "欄 2：車身中心 x")
checkNear(args[3], 0, 1e-9, "欄 3：車身中心 y")
checkNear(args[4], -20, 1e-9, "欄 4：速度 x")
checkNear(args[6], -1, 1e-9, "欄 6：前向 x（單位向量）")
checkNear(args[8], 0.9, 1e-9, "欄 8：半寬")
checkNear(args[9], 2.3, 1e-9, "欄 9：半長")

scenario("節流 250ms、沙盒關掉不送")
local before = #sent
tick(100)
checkEq(#sent, before, "100ms 內不重送")
sandbox.TrafficRelay = false
tick(300)
checkEq(#sent, before, "沙盒 TrafficRelay 關掉不送")
sandbox.TrafficRelay = true
tick(300)
checkEq(#sent, before + 1, "沙盒打開後照送")

scenario("最近 8 台、由近到遠")
for k = 1, 10 do driver(vehicle(100 + k, 40 + 20 * k, 1, -15, 0, -1, 0)) end
tick()
args = lastTo(pa)
local got = idsOf(args)
checkEq(#got, 8, "超過 8 台只送最近 8 台")
checkEq(got[1], 101, "最近的在前（x=60）")
checkEq(got[8], 2, "第 8 近是 x=200 的 B（同 x 的 108 在 y=1、略遠，被擠掉）")
local sorted = true
for k = 2, #got do
    local dPrev, d = args[(k - 2) * 9 + 2], args[(k - 1) * 9 + 2]
    if d < dPrev then sorted = false end
end
check(sorted, "由近到遠排序")
for i = #players, 1, -1 do
    if players[i]._vehicle._id > 100 then table.remove(players, i) end
end

scenario("掛車：自己的掛車不送；別人的掛車讀不到速度時以兩次轉送間的位移估")
A._towing = vehicle(7, -8, 0, 10, 0, 1, 0)
local TB = vehicle(8, 208, 0, 0, 0, -1, 0)
B._towing = TB
tick()
got = idsOf(lastTo(pa))
local hasOwn, hasTB = false, false
for _, id in ipairs(got) do
    if id == 7 then hasOwn = true end
    if id == 8 then hasTB = true end
end
check(not hasOwn, "自己的掛車不送")
check(hasTB, "別人的掛車照送（有人駕駛的車拖著）")
TB._x = 203
tick()
args = lastTo(pa)
local tbVx = nil
for k = 0, args.n - 1 do
    if args[k * 9 + 1] == 8 then tbVx = args[k * 9 + 4] end
end
checkNear(tbVx, -20, 0.5, "掛車速度讀不到：以 250ms 位移 5m 估成 −20 m/s")


scenario("兩位自駕對開：各自收到對方（正式服 Dixie 兩台拖車的情境）")
B._towing = nil
auto[2] = true
local beforeA, beforeB = sentTo(pa), sentTo(pb)
tick()
checkEq(sentTo(pa), beforeA + 1, "A 收到一次")
checkEq(sentTo(pb), beforeB + 1, "B 也收到一次")
local gotB = idsOf(lastTo(pb))
local hasA = false
for _, id in ipairs(gotB) do if id == 1 then hasA = true end end
check(hasA, "B 收到的轉送裡有 A")
print(string.format("情境 %d 個、斷言 %d 項、失敗 %d", scenarios, assertions, failures))
if failures > 0 then os.exit(1) end
