-- MDAD_Scene.lua — 自駕場景快照 v1（FSD 卡片的資料面，1024a）。
--
-- 資料流：Driver 每輪掃描完成 → MDADOverlay.update 把軌跡、路緣、軟目標、車輛寫成世界座標（MDADOverlay.trail）；
-- 沒有 session（手動開）時 HUD refresh 呼叫 MDADOverlay.updatePassive 寫導航線＋沿線路緣（路段寬度），卡片展開時
-- MDADFSD.update 每 0.25 秒呼叫 MDADOverlay.scanPassive 寫附近的殭屍／玩家／動物與車輛（1025a；沒有屍體）。
-- MDADScene.build 由 HUD update（約 10 Hz，只在 FSD 卡片顯示中）呼叫：讀一次自車位姿與 Drive 的純量，換成自車座標
-- 寫進每位玩家一份的快照（就地覆寫、零配置）。prerender 只讀快照，用 MDADScene.motion 依快照時戳外推自車位移。
--
-- 契約 v1（唯讀；呼叫端不得改欄位，下一次 build 會整份覆寫）：
--   MDADScene.get(playerNum) → snap；沒有快照或超過 FRESH_MS 沒更新＝nil
--   snap.version＝1、snap.seq（每次 build +1）、snap.t（build 當下 getTimestampMs，外推基準）
--   snap.kmh（自車有號車速，倒車為負）、snap.yaw（rad/s，往右轉為正）、snap.heading（世界航向 rad，同 Follower）
--   snap.state（Drive.hudState 狀態鍵；nil＝沒有 session）、snap.cap（上限 km/h 或 nil）、
--   snap.etaSec／snap.etaM（Drive.etaSeconds；nil＝沒有估計）、snap.label（目的地名稱或 nil）
--   座標一律自車座標、公尺：x＝右、y＝前（車頭向量 f、右向量 (−f.y, f.x)，同 Sensor 的法向慣例）
--   路徑   pathN（≤ 52 m／1.5 m 一點）、pathX/pathY、pathDodge（true＝承諾中的繞行段）
--   路緣   roadN、roadLX/roadLY（左緣）、roadRX/roadRY（右緣）；nil 帶（樣本不足）＝0 筆
--   軟目標 zomN（≤ 24）、zomX/zomY、zomKind（"zombie"／"corpse"／"animal"／"small"／"player"）、zomBand（在 ±3 m 減速帶內）
--   車輛   vehN（≤ 8）、vehX/vehY（車心）、vehDX/vehDY（車頭單位向量，自車座標）、vehHL/vehHW（半長／半寬）、vehMoving
-- MP：資料只有本機掃描得到的範圍（Sensor 走廊、被動掃描的本機已同步清單）。
require "MDAD"

MDADScene = MDADScene or {}
MDADScene.VERSION = 1

local sqrt, sin, cos = math.sqrt, math.sin, math.cos
local atan2 = math.atan2 or math.atan
local PI = math.pi
local FRESH_MS = 500
local MAX_DT_S = 0.25 -- 外推上限：快照停更（暫停、卡頓）時不把場景推飛
local snaps = {}
local fwd = nil

local function newSnap()
    return { version = MDADScene.VERSION, seq = 0, t = 0, kmh = 0, yaw = 0, heading = 0,
        state = nil, cap = nil, etaSec = nil, etaM = nil, label = nil,
        pathN = 0, pathX = {}, pathY = {}, pathDodge = {},
        roadN = 0, roadLX = {}, roadLY = {}, roadRX = {}, roadRY = {},
        zomN = 0, zomX = {}, zomY = {}, zomKind = {}, zomBand = {},
        vehN = 0, vehX = {}, vehY = {}, vehDX = {}, vehDY = {}, vehHL = {}, vehHW = {}, vehMoving = {} }
end

-- 讀一次自車位姿＋Drive 純量，世界點列換成自車座標。回快照；位姿讀不到回 nil（快照不動）。
function MDADScene.build(playerNum, vehicle, now, label)
    if vehicle == nil then return nil end
    fwd = fwd or Vector3f.new()
    local f = vehicle:getForwardVector(fwd) -- 同 Drive.headingOf（x,z＝世界 x,y），只重用一顆向量
    local fx, fy = f:x(), f:z()
    local len = sqrt(fx * fx + fy * fy)
    if not (len > 1e-3) then return nil end
    fx, fy = fx / len, fy / len
    local rx, ry = -fy, fx
    local ox, oy = vehicle:getX(), vehicle:getY()
    local snap = snaps[playerNum]
    if not snap then
        snap = newSnap()
        snaps[playerNum] = snap
    end
    local heading = atan2(fy, fx)
    local dtMs = now - snap.t
    if snap.t > 0 and dtMs > 0 and dtMs < 1000 then
        local dh = heading - snap.heading
        if dh > PI then dh = dh - 2 * PI elseif dh < -PI then dh = dh + 2 * PI end
        snap.yaw = dh * 1000 / dtMs
    else
        snap.yaw = 0
    end
    snap.heading, snap.t, snap.seq = heading, now, snap.seq + 1
    snap.kmh = vehicle:getCurrentSpeedKmHour()
    local drive = MDAD.Drive
    local state, _, cap = drive.hudState(playerNum)
    snap.state, snap.cap = state, cap
    snap.etaSec, snap.etaM = drive.etaSeconds(playerNum)
    snap.label = label
    snap.pathN, snap.roadN, snap.zomN, snap.vehN = 0, 0, 0, 0
    local xs, ys, ds, n, w = nil, nil, nil, 0, nil
    if type(MDADOverlay) == "table" and type(MDADOverlay.trail) == "function" then
        xs, ys, ds, n, w = MDADOverlay.trail(playerNum)
    end
    if not w then return snap end
    for i = 1, n do
        local dx, dy = xs[i] - ox, ys[i] - oy
        snap.pathX[i], snap.pathY[i], snap.pathDodge[i] = dx * rx + dy * ry, dx * fx + dy * fy, ds[i] == true
    end
    snap.pathN = n
    for i = 1, w.rN do
        local lx, ly, qx, qy = w.rLX[i] - ox, w.rLY[i] - oy, w.rRX[i] - ox, w.rRY[i] - oy
        snap.roadLX[i], snap.roadLY[i] = lx * rx + ly * ry, lx * fx + ly * fy
        snap.roadRX[i], snap.roadRY[i] = qx * rx + qy * ry, qx * fx + qy * fy
    end
    snap.roadN = w.rN
    for i = 1, w.zN do
        local dx, dy = w.zX[i] - ox, w.zY[i] - oy
        snap.zomX[i], snap.zomY[i] = dx * rx + dy * ry, dx * fx + dy * fy
        snap.zomKind[i], snap.zomBand[i] = w.zK[i], w.zB[i] == true
    end
    snap.zomN = w.zN
    for i = 1, w.vN do
        local dx, dy, vfx, vfy = w.vX[i] - ox, w.vY[i] - oy, w.vFx[i], w.vFy[i]
        local vl = sqrt(vfx * vfx + vfy * vfy)
        if vl < 1e-6 then vl = 1 end
        snap.vehX[i], snap.vehY[i] = dx * rx + dy * ry, dx * fx + dy * fy
        snap.vehDX[i], snap.vehDY[i] = (vfx * rx + vfy * ry) / vl, (vfx * fx + vfy * fy) / vl
        snap.vehHL[i], snap.vehHW[i], snap.vehMoving[i] = w.vHL[i], w.vHW[i], w.vStill[i] ~= true
    end
    snap.vehN = w.vN
    return snap
end

function MDADScene.get(playerNum, now)
    local snap = snaps[playerNum]
    if not snap or snap.t <= 0 or (now or getTimestampMs()) - snap.t > FRESH_MS then return nil end
    return snap
end

-- 每幀外推（純量、零配置）：快照之後自車又往前開了多少、轉了多少。回 ca, sa, mx, my；快照座標 (x, y) 換成現在的自車座標：
--   X, Y = x − mx, y − my；x' = X·ca − Y·sa；y' = X·sa + Y·ca（往右轉 a，原本正前方的點會出現在左邊）
-- 位移取弧中點航向（a/2）近似。dt 夾 [0, MAX_DT_S]。
function MDADScene.motion(snap, now)
    local dt = (now - snap.t) / 1000
    if dt < 0 then dt = 0 elseif dt > MAX_DT_S then dt = MAX_DT_S end
    local a = snap.yaw * dt
    local d = snap.kmh / 3.6 * dt
    return cos(a), sin(a), d * sin(a * 0.5), d * cos(a * 0.5)
end
