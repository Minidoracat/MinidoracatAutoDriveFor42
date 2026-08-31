-- MDAD_Follower.lua — 自駕的「路線跟隨核心」：純數學，不碰任何 PZ API。
--
-- 這個檔案裡沒有 getSpecificPlayer、沒有 vehicle、沒有 SandboxVars、沒有 Events、
-- 沒有 userdata、沒有翻譯鍵。輸入全是純量與扁平陣列，輸出全是純量。
-- 這樣做的兩個實際好處：
--   1. 離線可測：scripts/test_follower.lua 直接 loadfile 本檔就能跑完整模擬，
--      不需要任何假全域。控制律出錯在遊戲裡的表徵是「車撞牆」，靠肉眼回歸不了。
--   2. 熱路徑可稽核：control() 每幀跑一次，責任邊界清楚才有辦法保證它不配置記憶體。
--
-- ---------------------------------------------------------------------------
-- 介面契約（client/MDAD_Drive 依此接線，勿在此處加入 PZ 相依）
-- ---------------------------------------------------------------------------
-- MDADFollower.begin(route, maxSpeed, navVersion, vehicleProfile)
--     route    ＝ MiniMap nav API requestRoute 的唯讀 route。pts 為扁平 x,y。
--     navVersion >=4 時 segSurface/segWidth 必須各恰 n-1 且逐項合法，否則
--                fail-stop "badroute"；真正 v2/v3 明確複製為 unknown/width 0。
--     maxSpeed ＝ 巡航上限，km/h（沙盒值）。非數字／非有限／過小過大一律夾限。
--     回 profile（擁有 pts/metadata 複本）或 nil, "badroute"。
--     這是整個模組唯一配置 route profile table/array 的入口（每條路線一次）。
--
-- MDADFollower.stepBuild(profile, budget)
--     增量建表，每次呼叫最多做 budget 個「點運算」（硬上限 BUDGET_MAX）。
--     回 profile.ready（boolean）。相位：geometry → brake → accel → ready。
--     為什麼要增量：路網 A* 回的點數沒有上限，一次算完會在單一幀裡吃掉數千次
--     sqrt/atan2；玩家看到的是啟動自駕瞬間卡一下。
--
-- MDADFollower.control(profile, state, x, y, heading, speed, dt)
--     x, y     ＝ 車輛世界座標（tile；1 tile 視為 1 公尺，與 route.pts 同一空間）
--     heading  ＝ 弧度。定義：車頭前向 ＝ (cos(heading), sin(heading))，與 x,y 同空間。
--                （可用 MDADFollower.headingFromForward(fx, fy) 從前向向量轉出，
--                  兩邊共用同一份慣例才不會左右相反。）
--     speed    ＝ km/h，有號（前進正、倒車負）＝ getCurrentSpeedKmHour()。
--     dt       ＝ **真實秒數**。呼叫端用 getGameTime():getMultiplier() / 48
--                （getThirtyFPSMultiplier() ＝ getMultiplier() / 1.6 才是「30fps 幀數」，
--                  GameTime.java:1032-1034，再 / 30 才是秒；正常速度下等同
--                  getRealworldSecondsSinceLastUpdate()＝GameTime.java:192-193，
--                  60fps 約 0.0167）。非有限或超出 [DT_MIN, DT_MAX] 一律夾限，
--                不讓 PID 的 I／D 被爛 dt 炸掉。
--     回 steer, targetSpeed, remaining, reached, headingError, lateralSq
--       steer         ±STEER_MAX；正號＝往「heading 角度變大」的方向轉（(x,y) 平面 CCW）。
--                     steer / STEER_MAX 就是 -1..1 的正規化轉向強度。
--       targetSpeed   km/h（可直接餵 setRegulator）。唯一的下限：沿線 remaining 已經
--                     <= ARRIVE_M 但 reached 仍為 false（車橫向偏離終點）時抬到
--                     ROTATE_SPEED_KMH，否則制動剖面的 0 速會讓車永遠回不了終點。
--                     沙盒上限的夾限是呼叫端的責任（client/MDAD_Drive 的 applySpeed）。
--       remaining     沿路徑剩餘距離（公尺）。
--       reached       沿線 remaining <= ARRIVE_M **且**車身離最末點不到 ARRIVE_M。
--                     兩個條件都要，因為 remaining 只是「沿路徑的弧長差」：車被撞到
--                     路邊、或路線末段擦身而過時，投影點會滑到終點附近讓 remaining
--                     歸零，但車其實還在幾十公尺外——單看 remaining 會回報假抵達，
--                     呼叫端就在半路上煞停宣告到站。歐氏檢查用平方比較（省一次 sqrt）。
--                     這個判定同時是上面那條速度下限的觸發條件。
--       headingError  弧度，已 wrap 到 ±pi。
--     lateralSq     車到路線投影點的距離**平方**（公尺²；甩出路面判定用，
--                   平方省 sqrt——呼叫端用門檻平方比較）。防呆早退時回 0。
--     **不配置任何 table**：只讀 profile、只就地寫 state 的數值欄位。
--
-- state 由呼叫端持有（每個 session 一顆，重複使用）。空 table {} 直接可用：
-- 缺欄位一律當預設值並就地補寫。想乾淨可呼叫 newState() / resetState(state)——
-- 換 route 時務必重設，否則新路線的第一幀會吃到舊路線的誤差歷史（假的微分尖刺）。
--
-- ---------------------------------------------------------------------------
-- 控制律（為什麼是這些式子）
-- ---------------------------------------------------------------------------
-- * 幾何：折線＋累積弧長 s。投影只在 [idx-SEARCH_BACK, idx+SEARCH_FWD] 的窗口內找，
--   全域最近點搜尋在自我交叉的路線（回頭路、繞圈）上會把進度瞬移到另一段。
-- * 前視（pure pursuit）：lookahead ＝ lookScale*(6 + |speed|*0.12)，夾在
--   [6*lookScale,18*lookScale]；非 adaptive profile 的 lookScale=1。
-- * 曲率限速：v = sqrt(segLat / kappa)，kappa ＝ |Δθ| / ds。
--   夾 [MIN_SPEED_KMH, maxSpeed]：下限避免路網近 180° 假折點把車永遠停住。
-- * 反向制動：v[i] <= sqrt(v[i+1]^2 + 2*segBrake[i]*L)。終點 v = 0，
--   所以「彎前先減速」與「終點前煞停」由同一式推出。
-- * 前向加速：v[i+1] <= sqrt(v[i]^2 + 2*segAccel[i]*L)。runtime EWMA
--   lower bound 只能在 control 端再往下夾，不會抬高 getter-derived prior。
-- * PID：P 抓誤差、I 補系統性偏置（車體不對稱、路面阻力）、D 抑制擺盪。
--   I 有 ±I_MAX 飽和 ＋ 條件積分（飽和且誤差同向就不累積）；D 先低通再進 PID，
--   因為折線朝向是階梯狀的，raw (err-prev)/dt 在換段瞬間會打出尖刺。
-- * 原地調頭（rotate）：|誤差| > 135° 進入、< 100° 離開（hysteresis；沒有遲滯的話
--   車頭在門檻附近會 PID／調頭兩種模式互相打架）。調頭時 PID 的線性假設不成立，
--   直接飽和轉向＋爬行速度，並凍結積分項。
--
-- 效能守則（Kahlua）：庫函式都是 JavaFunction，每次呼叫都跨 Lua↔Java 邊界。
-- 因此全部庫函式在載入期取成 local upvalue；夾限一律用純 Lua 比較，不呼叫
-- math.max/min；control() 每幀只剩 cos/sin/atan2 三次跨界，sqrt 全在建表期。

if not MDADDynamics then require "MDAD_Dynamics" end

MDADFollower = MDADFollower or {}

-- math.atan2 在遊戲的 Kahlua 裡存在（原版用例：client/Foraging/ISBaseIcon.lua:210、
-- client/PZAPI/ui/testUI.lua:79）。標準 Lua 5.3 起把它移除、改成 math.atan(y, x)
-- 兩參數形式——退回 math.atan 讓離線測試不必打任何 shim，語意完全相同。
local atan2 = math.atan2 or math.atan
local sqrt, cos, sin = math.sqrt, math.cos, math.sin
local PI = math.pi
local TWO_PI = PI * 2

local MS_PER_KMH = 1 / 3.6
local KMH_PER_MS = 3.6

local ACCEL = 2.5             -- m/s²：前向加速上限
local BRAKE = 6.0             -- m/s²：減速上限——引擎實煞 ~10，取六成留雨天餘裕。
                              -- 3.0 時代的煞停曲線過長（40km/h 提前 20m 收油、
                              -- 120km/h 提前 185m），終點與進彎都太早減速
                              --（2026-08-29 使用者裁定：按真實煞停距動態化）
local LAT_ACCEL = 3.5         -- m/s²：過彎橫向加速預算（決定曲率限速）
local MIN_SPEED_KMH = 12      -- 曲率限速的下限（見上方說明）
local MAX_SPEED_CAP_KMH = 160 -- maxSpeed 的上界（防呆，不是遊戲設定）
local MIN_SPEED_MS = MIN_SPEED_KMH * MS_PER_KMH
local ARRIVE_M = 5            -- 抵達判定半徑（公尺）：沿線剩餘距離與終點直線距離共用
local ARRIVE_M_SQ = ARRIVE_M * ARRIVE_M

local LOOKAHEAD_BASE = 6
local LOOKAHEAD_PER_KMH = 0.12
local LOOKAHEAD_MIN = 6
local LOOKAHEAD_MAX = 18
local LOOKAHEAD_WALK_MAX = 64 -- 前視推進的段數硬上限（碎段路線不得變成 O(n) 迴圈）

local SEARCH_BACK = 12        -- 投影搜尋窗口：往後 12 段
-- 折點角度限速下限（不除 ds，路網點距稀釋不掉；理由見 geometryStep 內註解）
local TURN_SOFT_RAD = 20 * PI / 180  -- 折角超過 20° 開始壓
local TURN_HARD_RAD = 40 * PI / 180  -- 折角 40° 以上一律爬到 TURN_HARD_MS
local TURN_HARD_MS = 18 / 3.6        -- 急折點的硬上限：18 km/h
local SEARCH_FWD = 12         -- 往前 12 段
local REWIND_MAX = 1          -- 單幀最多允許倒退 1 段
local OV_STEP = 1.0           -- M6 世界 offset 折線的取樣步距（公尺）
local OV_MAX = 96             -- 折線表槽數（預配置；車位→d+1 最長 ~80m）
local LANE_MAX = 128          -- 全速證明線槽數（110m 感知線＋端點）；步距沿用
                              -- OV_STEP——Driver 的 sweepLine 以 OV_STEP 反推弧長，
                              -- 兩者若不同一個常數，掃掠會對錯位置的障礙判定
local OV_BLEND = 2.0          -- 折點法向混合半徑：距段端這麼近時與鄰段做角度插值
local RANGE_INF = 1e30        -- segment-tree padding; finite for Kahlua portability
local RANGE_BLOCK = 32        -- bounded edge scan; block tree handles the interior

local KP, KI, KD = 2.2, 0.15, 0.35
local I_MAX = 0.5             -- 積分項飽和
local D_ALPHA = 0.3           -- 微分低通係數
local STEER_MAX = 5

local ROTATE_ENTER = 135 * PI / 180
local ROTATE_EXIT = 100 * PI / 180
local ROTATE_SPEED_KMH = 12   -- 爬行速度：原地調頭時的上限，也是「橫向偏離終點」的下限

-- 航向誤差減速：|誤差| 超過 START 開始線性收油，到 END 壓到爬行速度（與調頭同一檔）。
-- 速度剖面只看路徑幾何（曲率、制動），完全不知道車頭現在指哪。實機失效模式
-- （2026-08-28 telemetry）：直路加速到 35 km/h 進彎、轉向力矩追不上、errDeg 一路漲到
-- 40°+，而剖面認為「彎後是直路」繼續給油——誤差越大車越快的正反饋，最後衝出路面。
-- 同日 telemetry 也證明低速時力矩拉得回來（errDeg -46°→-3° 收斂），所以收油本身
-- 就足以讓誤差重新收斂，不必靠加大力矩去硬撐高速。
local ERR_SLOW_START = 10 * PI / 180
local ERR_SLOW_END = 50 * PI / 180
local ERR_SLOW_RANGE = ERR_SLOW_END - ERR_SLOW_START

local DT_MIN = 1 / 240
local DT_MAX = 0.25
local DT_FALLBACK = 1 / 30

local BUDGET_MAX = 4096       -- 每次 stepBuild 的硬上限（呼叫端給多大都不超過）
local BUDGET_DEFAULT = 64

MDADFollower.STEER_MAX = STEER_MAX
MDADFollower.ARRIVE_M = ARRIVE_M
MDADFollower.MIN_SPEED_KMH = MIN_SPEED_KMH
MDADFollower.BUDGET_MAX = BUDGET_MAX
MDADFollower.OV_STEP = OV_STEP
MDADFollower.LANE_MAX = LANE_MAX
MDADFollower.SURFACE_UNKNOWN = 0
MDADFollower.SURFACE_PAVED = 1
MDADFollower.SURFACE_GRAVEL = 2
MDADFollower.SURFACE_DIRT = 3

-- v4 segSurface 的合法字串就是這四個；查不到＝fail-stop badroute（不猜、不預設）。
local SURFACE_ID = {
    unknown = MDADFollower.SURFACE_UNKNOWN,
    paved = MDADFollower.SURFACE_PAVED,
    gravel = MDADFollower.SURFACE_GRAVEL,
    dirt = MDADFollower.SURFACE_DIRT,
}
local SURFACE_NAME = {
    [MDADFollower.SURFACE_UNKNOWN] = "unknown",
    [MDADFollower.SURFACE_PAVED] = "paved",
    [MDADFollower.SURFACE_GRAVEL] = "gravel",
    [MDADFollower.SURFACE_DIRT] = "dirt",
}

-- n * 0 == 0 一次擋掉 NaN 與 ±Inf（有限數乘 0 必為 0，這兩者乘 0 都是 NaN），
-- 不用 math.huge（Kahlua 未保證提供；shared/MDAD.lua 的 isFiniteInt 同一理由）
local function isFinite(n)
    if type(n) ~= "number" then return false end
    return n * 0 == 0
end

-- 只用在「兩個 atan2 輸出相減」上，差值必在 ±2pi 內，迴圈最多跑一次
local function wrapPi(a)
    while a > PI do a = a - TWO_PI end
    while a < -PI do a = a + TWO_PI end
    return a
end

-- 點 P 到線段 A→B 的最近點：回 (t, 距離平方)。t 夾在 [0, 1]。
-- 回純量不建 table——每幀最多跑 SEARCH_BACK+SEARCH_FWD+2 次。
local function projectT(px, py, ax, ay, bx, by, len)
    if len <= 0 then
        local dx, dy = px - ax, py - ay
        return 0, dx * dx + dy * dy
    end
    local ex, ey = bx - ax, by - ay
    local t = ((px - ax) * ex + (py - ay) * ey) / (len * len)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local dx, dy = px - (ax + ex * t), py - (ay + ey * t)
    return t, dx * dx + dy * dy
end

-- 建表期的單點運算：抄座標、算段長／段朝向／累積弧長，並在資料到齊時補算內點曲率。
-- 曲率需要三點，所以拿到第 i 點時算的是內點 i-1 的限速。
local function geometryStep(p, i)
    local pts = p.pts
    local x, y = pts[i * 2 - 1], pts[i * 2]
    local px, py = p.x, p.y
    px[i], py[i] = x, y
    p.v[i] = p.maxSpeedMs
    p.curveV[i] = p.maxSpeedMs
    p.kappa[i] = 0
    if i == 1 then
        p.s[1] = 0
        return
    end
    local segH, segLen = p.segH, p.segLen
    local dx, dy = x - px[i - 1], y - py[i - 1]
    local len = sqrt(dx * dx + dy * dy)
    segLen[i - 1] = len
    if len > 0 then
        segH[i - 1] = atan2(dy, dx)
    else
        -- 重合點：atan2(0, 0) 回 0＝假的「朝東」，會在直路上偽造一個急彎。
        segH[i - 1] = (i >= 3 and segH[i - 2]) or 0
    end
    p.s[i] = p.s[i - 1] + len
    if i >= 3 then
        local m = i - 1
        local dth = wrapPi(segH[m] - segH[m - 1])
        if dth < 0 then dth = -dth end
        local kappa = MDADDynamics.circumcircleKappa(
            px[m - 1], py[m - 1], px[m], py[m], px[m + 1], py[m + 1])
        p.kappa[m] = kappa
        local aLat = p.segLat[m - 1] or LAT_ACCEL
        local nextLat = p.segLat[m] or aLat
        if nextLat < aLat then aLat = nextLat end
        local lim = p.maxSpeedMs
        if kappa > 0 then
            lim = sqrt(aLat / kappa)
            if p.filletAdaptive then
                local cap = MDADDynamics.curveSpeedCapKmh(kappa, aLat,
                    p.wheelbase, p.delta0Safe, p.deltaVSafe, p.vehicleMaxSpeed)
                    * MS_PER_KMH
                if cap < lim then lim = cap end
            end
        end
        -- >90° and U-turns are outside the fillet contract: preserve the source
        -- vertex and use the explicit crawl fallback instead of inventing an arc.
        if dth > PI * 0.5 then
            lim = MIN_SPEED_MS
        elseif dth >= TURN_HARD_RAD then
            if lim > TURN_HARD_MS then lim = TURN_HARD_MS end
        elseif dth >= TURN_SOFT_RAD then
            local t = (dth - TURN_SOFT_RAD) / (TURN_HARD_RAD - TURN_SOFT_RAD)
            local cap = p.maxSpeedMs + (TURN_HARD_MS - p.maxSpeedMs) * t
            if lim > cap then lim = cap end
        end
        if lim < MIN_SPEED_MS then lim = MIN_SPEED_MS end
        if lim > p.maxSpeedMs then lim = p.maxSpeedMs end
        p.curveV[m] = lim
        if p.v[m] > lim then p.v[m] = lim end
    end
end

-- 驗 route 並配置 profile。**唯一**會建 table 的入口。
-- 拒絕條件（一律回 nil, "badroute"，呼叫端不必分辨細節，只需要「這條路不能跟」）：
--   route／route.pts 不是 table、pts 長度非偶數、點數 < 2、任一座標非有限數、
--   所有點重合（路徑長 0，投影／曲率／前視全部沒有意義）。
-- 點數 1（#pts == 2）是 nav 真的會回的情況（A* 起錨後續節點全與前一點重合），
-- 對應 production 的 `if np < 2 then` 早退，不是假想輸入。
function MDADFollower.begin(route, maxSpeed, navVersion, vehicleProfile)
    if type(route) ~= "table" then return nil, "badroute" end
    local pts = route.pts
    if type(pts) ~= "table" then return nil, "badroute" end
    local np = #pts
    if np < 4 or np % 2 ~= 0 then return nil, "badroute" end

    local prevX, prevY
    local span = false
    for k = 1, np, 2 do
        local x, y = pts[k], pts[k + 1]
        if not isFinite(x) or not isFinite(y) then return nil, "badroute" end
        if prevX ~= nil and (x ~= prevX or y ~= prevY) then span = true end
        prevX, prevY = x, y
    end
    if not span then return nil, "badroute" end

    local maxKmh = maxSpeed
    if not isFinite(maxKmh) or maxKmh < MIN_SPEED_KMH then maxKmh = MIN_SPEED_KMH end
    if maxKmh > MAX_SPEED_CAP_KMH then maxKmh = MAX_SPEED_CAP_KMH end

    if navVersion == nil then
        navVersion = 2
    elseif not isFinite(navVersion) or navVersion < 2 or navVersion % 1 ~= 0 then
        return nil, "badroute"
    end
    local sourceN = np / 2
    local sourceSurface, sourceWidth = {}, {}
    if navVersion >= 4 then
        local srcSurface, srcWidth = route.segSurface, route.segWidth
        if type(srcSurface) ~= "table" or type(srcWidth) ~= "table"
                or #srcSurface ~= sourceN - 1 or #srcWidth ~= sourceN - 1 then
            return nil, "badroute"
        end
        for i = 1, sourceN - 1 do
            local surface = srcSurface[i]
            local sid
            if type(surface) == "string" then sid = SURFACE_ID[surface] end
            if sid == nil then return nil, "badroute" end
            local width = srcWidth[i]
            if not isFinite(width) or width < 1 or width > 64 then return nil, "badroute" end
            sourceSurface[i], sourceWidth[i] = sid, width
        end
    else
        for i = 1, sourceN - 1 do
            sourceSurface[i], sourceWidth[i] = MDADFollower.SURFACE_UNKNOWN, 0
        end
    end

    -- Canonicalize consecutive duplicate points before any fillet math. The
    -- original route remains untouched and source-map entries retain raw segments.
    local buildPts, buildSurface, buildWidth = pts, sourceSurface, sourceWidth
    local rawSourceMap
    if sourceN <= MDADDynamics.FILLET_SOURCE_MAX then
        buildPts, buildSurface, buildWidth, rawSourceMap = {}, {}, {}, {}
        buildPts[1], buildPts[2] = pts[1], pts[2]
        local cn, lastX, lastY = 1, pts[1], pts[2]
        for i = 1, sourceN - 1 do
            local nx, ny = pts[i * 2 + 1], pts[i * 2 + 2]
            if nx ~= lastX or ny ~= lastY then
                buildSurface[cn], buildWidth[cn], rawSourceMap[cn] =
                    sourceSurface[i], sourceWidth[i], i
                cn = cn + 1
                buildPts[cn * 2 - 1], buildPts[cn * 2] = nx, ny
                lastX, lastY = nx, ny
            end
        end
    end
    local buildN = #buildPts / 2
    local pathPts, segSurface, segWidth = {}, {}, {}
    local segKind, segSourceA, segSourceB, filletRadius = {}, {}, {}, {}
    local n, filletN, filletFallbackN = 0, 0, 0
    local filletBandValid = navVersion >= 4
    local filletReason
    local filletAdaptive = navVersion >= 4 and type(vehicleProfile) == "table"
        and vehicleProfile.valid == true and vehicleProfile.geometryValid == true
        and isFinite(vehicleProfile.halfW) and vehicleProfile.halfW > 0
        and isFinite(vehicleProfile.rMin) and vehicleProfile.rMin > 0
        and isFinite(vehicleProfile.wheelbase) and vehicleProfile.wheelbase > 0
        and isFinite(vehicleProfile.delta0Safe) and isFinite(vehicleProfile.deltaVSafe)
        and isFinite(vehicleProfile.maxSpeed) and vehicleProfile.maxSpeed > 0
    if filletAdaptive and sourceN <= MDADDynamics.FILLET_SOURCE_MAX then
        n, filletN, filletFallbackN, filletBandValid, filletReason =
            MDADDynamics.buildFilletPath(
                buildPts, buildSurface, buildWidth, vehicleProfile.halfW, vehicleProfile.rMin,
                pathPts, segSurface, segWidth, segKind, segSourceA, segSourceB, filletRadius)
    end
    if n >= 2 and rawSourceMap then
        for i = 1, n - 1 do
            segSourceA[i] = rawSourceMap[segSourceA[i]] or segSourceA[i]
            segSourceB[i] = rawSourceMap[segSourceB[i]] or segSourceB[i]
        end
    end
    if n < 2 then
        n, filletN = buildN, 0
        if filletAdaptive and sourceN > MDADDynamics.FILLET_SOURCE_MAX then
            filletReason, filletFallbackN = "capacity", buildN - 2
        end
        for i = 1, #buildPts do pathPts[i] = buildPts[i] end
        for i = 1, buildN - 1 do
            segSurface[i], segWidth[i] = buildSurface[i], buildWidth[i]
            segSourceA[i] = rawSourceMap and rawSourceMap[i] or i
            segSourceB[i], filletRadius[i] = segSourceA[i], 0
            segKind[i] = filletReason and MDADDynamics.SEG_FALLBACK
                or MDADDynamics.SEG_LINE
        end
    end

    local segAccel, segBrake, segCoast, segLat = {}, {}, {}, {}
    for i = 1, n - 1 do
        segAccel[i], segBrake[i], segCoast[i], segLat[i] =
            ACCEL, BRAKE, 0.6, LAT_ACCEL
    end
    local rangeBlockCount = ((n - 2) - (n - 2) % RANGE_BLOCK) / RANGE_BLOCK + 1
    local rangeBase = 1
    while rangeBase < rangeBlockCount do rangeBase = rangeBase * 2 end

    return {
        pts = pathPts,
        navVersion = navVersion,
        n = n,
        maxSpeed = maxKmh,
        maxSpeedMs = maxKmh * MS_PER_KMH,
        lookScale = 1,
        adaptive = false,
        filletAdaptive = filletAdaptive,
        filletN = filletN,
        filletFallbackN = filletFallbackN,
        filletBandValid = filletBandValid == true,
        wheelbase = filletAdaptive and vehicleProfile.wheelbase or 0,
        delta0Safe = filletAdaptive and vehicleProfile.delta0Safe or 0,
        deltaVSafe = filletAdaptive and vehicleProfile.deltaVSafe or 0,
        vehicleMaxSpeed = filletAdaptive and vehicleProfile.maxSpeed or maxKmh,
        x = {}, y = {},
        s = {},
        segLen = {},
        segH = {},
        segSurface = segSurface,
        segWidth = segWidth,
        segKind = segKind,
        segSourceA = segSourceA,
        segSourceB = segSourceB,
        segAccel = segAccel,
        segBrake = segBrake,
        segLat = segLat,
        segCoast = segCoast,
        kappa = {},
        curveV = {},
        coastV = {},
        brakeV = {},
        v = {},
        rangeBase = rangeBase, rangeBlockCount = rangeBlockCount,
        rangeBrake = {}, rangeLat = {}, rangeCoast = {},
        rangeReady = false,
        length = 0,
        phase = "geometry",
        cursor = 1,
        ready = false,
    }
end

-- 增量建表。每次呼叫最多做 budget 個 ops；相位切換本身不算運算。
-- 最後以每 32 段一葉的 block tree 建 range minima。
function MDADFollower.stepBuild(profile, budget)
    if type(profile) ~= "table" then return false end
    if profile.ready == true then return true end
    if not isFinite(budget) then budget = BUDGET_DEFAULT end
    budget = budget - budget % 1
    if budget < 1 then budget = 1 end
    if budget > BUDGET_MAX then budget = BUDGET_MAX end

    local n, segLen = profile.n, profile.segLen
    local v, coastV, brakeV = profile.v, profile.coastV, profile.brakeV
    local ops = 0
    while ops < budget do
        local phase, i = profile.phase, profile.cursor
        if phase == "geometry" then
            if i > n then
                profile.length = profile.s[n]
                coastV[n] = profile.curveV[n] or profile.maxSpeedMs
                profile.phase, profile.cursor = "coast", n - 1
            else
                geometryStep(profile, i)
                profile.cursor, ops = i + 1, ops + 1
            end
        elseif phase == "coast" then
            if i < 1 then
                brakeV[n] = 0
                profile.phase, profile.cursor = "brake", n - 1
            else
                local coast = profile.segCoast[i] or 0.6
                local lim = sqrt(coastV[i + 1] * coastV[i + 1]
                    + 2 * coast * segLen[i])
                local curve = profile.curveV[i] or profile.maxSpeedMs
                coastV[i] = curve < lim and curve or lim
                profile.cursor, ops = i - 1, ops + 1
            end
        elseif phase == "brake" then
            if i < 1 then
                profile.phase, profile.cursor = "merge", 1
            else
                local brake = profile.segBrake[i] or BRAKE
                local lim = sqrt(brakeV[i + 1] * brakeV[i + 1]
                    + 2 * brake * segLen[i])
                if lim > profile.maxSpeedMs then lim = profile.maxSpeedMs end
                brakeV[i] = lim
                profile.cursor, ops = i - 1, ops + 1
            end
        elseif phase == "merge" then
            if i > n then
                profile.phase, profile.cursor = "accel", 1
            else
                local cv, bv = coastV[i], brakeV[i]
                v[i] = cv < bv and cv or bv
                profile.cursor, ops = i + 1, ops + 1
            end
        elseif phase == "accel" then
            if i > n - 1 then
                profile.rangeReady = false
                profile.phase, profile.cursor = "range-pad", profile.rangeBlockCount + 1
            else
                local accel = profile.segAccel[i] or ACCEL
                local lim = sqrt(v[i] * v[i] + 2 * accel * segLen[i])
                if v[i + 1] > lim then v[i + 1] = lim end
                local z = i - 1
                local block = (z - z % RANGE_BLOCK) / RANGE_BLOCK + 1
                local node = profile.rangeBase + block - 1
                if z % RANGE_BLOCK == 0 then
                    profile.rangeBrake[node] = profile.segBrake[i]
                    profile.rangeLat[node] = profile.segLat[i]
                    profile.rangeCoast[node] = profile.segCoast[i]
                else
                    if profile.segBrake[i] < profile.rangeBrake[node] then
                        profile.rangeBrake[node] = profile.segBrake[i]
                    end
                    if profile.segLat[i] < profile.rangeLat[node] then
                        profile.rangeLat[node] = profile.segLat[i]
                    end
                    if profile.segCoast[i] < profile.rangeCoast[node] then
                        profile.rangeCoast[node] = profile.segCoast[i]
                    end
                end
                profile.cursor, ops = i + 1, ops + 1
            end
        elseif phase == "range-pad" then
            local base = profile.rangeBase
            if i > base then
                profile.phase, profile.cursor = "range-tree", base - 1
            else
                local node = base + i - 1
                profile.rangeBrake[node], profile.rangeLat[node],
                    profile.rangeCoast[node] = RANGE_INF, RANGE_INF, RANGE_INF
                profile.cursor, ops = i + 1, ops + 1
            end
        elseif phase == "range-tree" then
            if i < 1 then
                profile.rangeReady = true
                profile.phase, profile.cursor, profile.ready = "ready", n, true
                return true
            else
                local left, right = i * 2, i * 2 + 1
                local lb, rb = profile.rangeBrake[left], profile.rangeBrake[right]
                local ll, rl = profile.rangeLat[left], profile.rangeLat[right]
                local lc, rc = profile.rangeCoast[left], profile.rangeCoast[right]
                profile.rangeBrake[i] = lb < rb and lb or rb
                profile.rangeLat[i] = ll < rl and ll or rl
                profile.rangeCoast[i] = lc < rc and lc or rc
                profile.cursor, ops = i - 1, ops + 1
            end
        else
            profile.phase, profile.ready = "ready", true
            return true
        end
    end
    return profile.ready == true
end

-- 每幀控制。零配置：只讀 profile、只就地寫 state 的數值欄位。
function MDADFollower.control(profile, state, x, y, heading, speed, dt)
    if type(state) == "table" then
        state.curveValid = false
        state.curveHardActive = false
        state.curveKappa = 0
        state.curveCapKmh = 0
    end
    if type(profile) ~= "table" or profile.ready ~= true or type(state) ~= "table" then
        return 0, 0, 0, false, 0, 0, 0
    end
    if not isFinite(x) or not isFinite(y) or not isFinite(heading) then
        -- 車輛座標壞掉（換載具／剛傳送）：不轉向、不給速度，把剩餘距離照實回報
        return 0, 0, profile.length, false, 0, 0, 0
    end
    if not isFinite(speed) then speed = 0 end
    if not isFinite(dt) then
        dt = DT_FALLBACK
    elseif dt < DT_MIN then
        dt = DT_MIN
    elseif dt > DT_MAX then
        dt = DT_MAX
    end

    local n = profile.n
    local px, py, s, segLen = profile.x, profile.y, profile.s, profile.segLen

    -- ---- 投影：窗口內找最近段 ----
    local idx = state.idx
    if not isFinite(idx) then
        idx = 1
    else
        idx = idx - idx % 1
    end
    if idx < 1 then idx = 1 end
    if idx > n - 1 then idx = n - 1 end

    local lo = idx - SEARCH_BACK
    if lo < 1 then lo = 1 end
    local hi = idx + SEARCH_FWD
    if hi > n - 1 then hi = n - 1 end

    -- 窗口一定至少含一段（lo <= idx <= hi，因為 idx 已夾在 [1, n-1]），所以直接用 lo
    -- 段當基準、從 lo+1 比起，不必在迴圈裡每次都測一遍「有沒有基準」。
    local bestI = lo
    local bestT, bestD = projectT(x, y, px[lo], py[lo], px[lo + 1], py[lo + 1], segLen[lo])
    for i = lo + 1, hi do
        local t, d2 = projectT(x, y, px[i], py[i], px[i + 1], py[i + 1], segLen[i])
        if d2 < bestD then
            bestI, bestT, bestD = i, t, d2
        end
    end
    -- 進度單幀最多倒退 REWIND_MAX 段：被撞開／倒車時允許逐幀往回收斂，但不准一次跳
    -- 回一大段——那會讓 remaining 暴增、targetSpeed 跳動，在自我交叉的路線上尤其明顯。
    local floorI = idx - REWIND_MAX
    if floorI < 1 then floorI = 1 end
    if bestI < floorI then
        bestI = floorI
        bestT = projectT(x, y, px[bestI], py[bestI], px[bestI + 1], py[bestI + 1], segLen[bestI])
    end
    state.idx = bestI

    -- 帶號橫偏（第 7 回傳值）：車相對投影點沿 CCW 法向的距離——正＝行進方向
    -- 右側，與 laneBias/offL 同一座標。呼叫端用它對「期望橫向位置」（laneBias
    -- ＋側偏剖面）做偏離判定：舊的 |到中心線距離| 判法會把合法的大側偏繞行
    -- （offL 4.5）誤判成甩出路面（2026-08-28 對抗審 BLOCKING）。兩次乘加、
    -- 零 sqrt、零配置；無號的 lateralSq（第 6 值）保留向後相容。
    local pjx = px[bestI] + (px[bestI + 1] - px[bestI]) * bestT
    local pjy = py[bestI] + (py[bestI + 1] - py[bestI]) * bestT
    local hProj = profile.segH[bestI]
    local latSigned = (x - pjx) * -sin(hProj) + (y - pjy) * cos(hProj)

    local sNow = s[bestI] + segLen[bestI] * bestT
    local remaining = profile.length - sNow
    if remaining < 0 then remaining = 0 end
    -- 假抵達防護：remaining 只證明「投影點到終點的弧長很短」，不證明車在終點附近。
    -- 平方比較，不開根號（sqrt 全留在建表期）。
    local exX, exY = px[n] - x, py[n] - y
    local reached = remaining <= ARRIVE_M and (exX * exX + exY * exY) <= ARRIVE_M_SQ

    -- ---- 前視點 ----
    local aspeed = speed
    if aspeed < 0 then aspeed = -aspeed end
    local lookScale = profile.lookScale
    if not isFinite(lookScale) or lookScale <= 0 then lookScale = 1 end
    local look = (LOOKAHEAD_BASE + aspeed * LOOKAHEAD_PER_KMH) * lookScale
    local lookMin, lookMax = LOOKAHEAD_MIN * lookScale, LOOKAHEAD_MAX * lookScale
    if look < lookMin then look = lookMin end
    if look > lookMax then look = lookMax end

    local sTarget = sNow + look
    local j = bestI
    local walked = 0
    while j < n - 1 and s[j + 1] < sTarget and walked < LOOKAHEAD_WALK_MAX do
        j = j + 1
        walked = walked + 1
    end
    local tj = 0
    local lj = segLen[j]
    if lj > 0 then
        tj = (sTarget - s[j]) / lj
        if tj < 0 then tj = 0 elseif tj > 1 then tj = 1 end
    end
    local tx = px[j] + (px[j + 1] - px[j]) * tj
    local ty = py[j] + (py[j + 1] - py[j]) * tj

    -- ---- 側偏疊加（車道偏置＋M4 繞行剖面）----
    -- 只動「前視點」：投影、remaining、reached 全部仍以中心線為準。
    -- laneBias＝常駐車道偏置（setLaneBias；靠右行駛＝正值）：路網折線在路中央，
    -- 沿中心線開會與對向車對頭——常駐偏到右車道，會車時雙方自然錯開。
    -- 繞行剖面（setOffset）作用時，橫向位置從 bias 平滑過渡到 offL（路線中心線
    -- 座標系的絕對 lane）再回到 bias：lane(s) = bias + (offL - bias) * t，
    -- t 是三段 smoothstep（端點斜率 0，切入點不吃階梯誤差）。進入段的斜率天然
    -- 抬高航向誤差 → 誤差減速自動收油，繞行段本來就該慢，兩機制同向。
    -- 法向取前視點所在段的數學 CCW 法向（l > 0＝PZ 世界的行進方向**右側**：
    -- 世界 Y 向南，俯視下數學 CCW＝實際順時針——別再標成「左」，真踩過）。
    local bias = state.laneBias
    if not isFinite(bias) then bias = 0 end
    local lt = bias
    local offL = state.offL
    local ovUsed = false
    local sEff = s[j] + lj * tj
    -- Both immutable dodge and RETURN can supply one exact prevalidated world line.
    -- RETURN borrows the caller's preallocated array; dodge uses state-owned storage.
    local ovN = state.ovN or 0
    local ovEndS = state.ovEndS
    if ovN >= 2 and isFinite(ovEndS)
            and sEff >= state.ovS0 and sEff <= ovEndS then
        local i0, ft
        local lastStart = state.ovS0 + (ovN - 2) * OV_STEP
        if sEff >= lastStart then
            i0 = ovN - 1
            local lastSpan = ovEndS - lastStart
            if lastSpan > 0 then ft = (sEff - lastStart) / lastSpan else ft = 1 end
        else
            local fi = (sEff - state.ovS0) / OV_STEP + 1
            i0 = fi - fi % 1
            ft = fi - i0
        end
        local ovX, ovY = state.ovX, state.ovY
        tx = ovX[i0] + (ovX[i0 + 1] - ovX[i0]) * ft
        ty = ovY[i0] + (ovY[i0 + 1] - ovY[i0]) * ft
        ovUsed = true
    end
    if not ovUsed and offL ~= nil and isFinite(offL) then
        local oa, ob, oc, od = state.offA, state.offB, state.offC, state.offD
        if sEff > oa and sEff < od then
            local t
            if sEff < ob then
                t = (sEff - oa) / (ob - oa)
            elseif sEff > oc then
                t = (od - sEff) / (od - oc)
            else
                t = 1
            end
            t = t * t * (3 - 2 * t)
            lt = bias + (offL - bias) * t
        end
    end
    if not ovUsed and lt ~= 0 then
        local h = profile.segH[j]
        tx = tx - sin(h) * lt
        ty = ty + cos(h) * lt
    end

    -- ---- 朝向誤差 ----
    local fx, fy = cos(heading), sin(heading)
    local vx, vy = tx - x, ty - y
    if vx * vx + vy * vy < 1e-8 then
        -- 前視點正好壓在車身上（終點附近）：atan2(0, 0) 會給出假的「零誤差」，
        -- 改用當前路段朝向當目標方向
        local h = profile.segH[bestI]
        vx, vy = cos(h), sin(h)
    end
    local err = atan2(fx * vy - fy * vx, fx * vx + fy * vy)

    -- ---- 原地調頭遲滯 ----
    local aerr = err
    if aerr < 0 then aerr = -aerr end
    local rotating = state.rotating == true
    if rotating then
        if aerr < ROTATE_EXIT then rotating = false end
    elseif aerr > ROTATE_ENTER then
        rotating = true
    end
    state.rotating = rotating

    -- ---- 目標速度（段內物理包絡；曲率／制動／加速已烘進端點 v）----
    -- 不能用線性插值：v 只在「點」上有值，長段內線性連 v[i]→v[i+1] 是物理錯誤。
    -- 2026-08-28 實機（163 號公路長直路）：nav 路網節點在路口，末段是 ~233m 的
    -- 單一線段，段尾 v[n]=0（終點）——線性插值把整段畫成 20→0 的長斜坡，車在
    -- 233m 外就以 target=0.087×remaining 龜速爬完全程（遙測 target 20.1→4.3 與
    -- remaining 嚴格成正比）。正確剖面是段內延拓 build pass 的同一組式子：
    --   加速曲線 sqrt(v[i]²  + 2·ACCEL·(s-s[i]))   —— 出折點後可以加速
    --   制動曲線 sqrt(v[i+1]² + 2·BRAKE·(s[i+1]-s)) —— 進折點／終點前才需要煞
    -- 取 min 再夾 maxSpeed：短段（點距 ≤ 4m）與舊行為幾乎重合且更保守（線性
    -- 在段中點本來就高於 sqrt 包絡＝該處煞不住），長段回到「巡航→晚煞車」。
    -- 端點極限：ds→0 收斂到 v[i]、ds→L 收斂到 v[i+1]，折點限速一樣被尊重。
    local v = profile.v
    local targetSpeed
    do
        local vA = v[bestI]
        local lenI = segLen[bestI]
        local dsA, remainI = lenI * bestT, lenI * (1 - bestT)
        local accel = profile.segAccel[bestI] or ACCEL
        local brake = profile.segBrake[bestI] or BRAKE
        local coast = profile.segCoast[bestI] or 0.6
        local runtimeAccel, runtimeBrake, runtimeCoast =
            state.accelSafe, state.brakeSafe, state.coastSafe
        if isFinite(runtimeAccel) and runtimeAccel >= 0 and runtimeAccel < accel then
            accel = runtimeAccel
        end
        if isFinite(runtimeBrake) and runtimeBrake >= 0 and runtimeBrake < brake then
            brake = runtimeBrake
        end
        if isFinite(runtimeCoast) and runtimeCoast >= 0 and runtimeCoast < coast then
            coast = runtimeCoast
        end
        local accLim = sqrt(vA * vA + 2 * accel * dsA)
        local coastNext = profile.coastV[bestI + 1] or profile.maxSpeedMs
        local brakeNext = profile.brakeV[bestI + 1] or 0
        local coastLim = sqrt(coastNext * coastNext + 2 * coast * remainI)
        local stopLim = sqrt(brakeNext * brakeNext + 2 * brake * remainI)
        targetSpeed = accLim
        if coastLim < targetSpeed then targetSpeed = coastLim end
        if stopLim < targetSpeed then targetSpeed = stopLim end
        if targetSpeed > profile.maxSpeedMs then targetSpeed = profile.maxSpeedMs end
        local curveHardActive = profile.segKind[bestI] == MDADDynamics.SEG_ARC
        local actualKappa = 0
        if curveHardActive then
            actualKappa = profile.kappa[bestI] or 0
            local nextKappa = profile.kappa[bestI + 1] or 0
            if nextKappa > actualKappa then actualKappa = nextKappa end
        end
        local curveCap = profile.maxSpeedMs
        local runtimeLat = state.latSafe
        if isFinite(runtimeLat) and runtimeLat >= 0 and actualKappa > 0 then
            curveCap = sqrt(runtimeLat / actualKappa)
            if curveCap < targetSpeed then targetSpeed = curveCap end
        end
        state.curveHardActive = curveHardActive
        state.curveKappa = actualKappa
        state.curveCapKmh = curveCap * KMH_PER_MS
        state.curveValid = true
        targetSpeed = targetSpeed * KMH_PER_MS
    end

    -- ---- 航向誤差減速 ----
    -- aerr 上面剛算好（調頭遲滯用的同一份）。t 從 1（誤差 ≤ START）線性降到
    -- 0（誤差 ≥ END）；cap = 爬行 + (target - 爬行) * t 只會往下壓、絕不抬速——
    -- target 已低於爬行（終點制動段）時 cap > target，直接不套用。與末段脫困地板、
    -- 調頭夾限收斂到同一個 ROTATE_SPEED_KMH，三個夾限互不打架。
    if aerr > ERR_SLOW_START then
        local t = (ERR_SLOW_END - aerr) / ERR_SLOW_RANGE
        if t < 0 then t = 0 end
        local cap = ROTATE_SPEED_KMH + (targetSpeed - ROTATE_SPEED_KMH) * t
        if cap < targetSpeed then targetSpeed = cap end
    end

    -- 末段脫困地板：投影點已經滑到終點（remaining <= ARRIVE_M）但歐氏條件不成立時，
    -- 制動剖面給出的目標速度已經是 0（v[n] = 0）——車停在終點旁 20m 的路邊，速度 0
    -- 就再也動不了，reached 永遠不會成立，session 卡死在原地。抵達判定的兩個條件本來
    -- 就要求車自己把身體開回終點，所以這裡把目標速度抬到爬行速度（與調頭同一檔）：
    -- 夠慢不會衝過頭，夠快能把車挪回去。
    -- 只在 remaining <= ARRIVE_M 這個窗口內作用：窗口外的低速是制動剖面在做「停在終點」
    -- 這件正事，抬速度等於不讓車煞停；窗口內、reached 又不成立，才是「速度 0 也不可能
    -- 再讓 reached 成立」的死結。reached 為真時同樣不介入（抵達要的就是 0 速）。
    -- 與調頭夾限方向相反但不衝突：調頭把速度壓到 ROTATE_SPEED_KMH 上限，這裡把它抬到
    -- 同一個值，兩者同時成立（橫向偏離終點且車頭反向）時就是剛好爬行速度。
    if not reached and remaining <= ARRIVE_M and targetSpeed < ROTATE_SPEED_KMH then
        targetSpeed = ROTATE_SPEED_KMH
    end

    -- ---- 轉向 ----
    local steer
    if rotating then
        -- 幾乎完全反向：PID 的線性假設不成立（±180° 附近誤差正負號會抖）。
        -- 直接飽和轉向把車頭甩回來、速度壓到爬行，並凍結 I／D 避免 windup。
        steer = (err >= 0) and STEER_MAX or -STEER_MAX
        if targetSpeed > ROTATE_SPEED_KMH then targetSpeed = ROTATE_SPEED_KMH end
        state.errPrev = err
    else
        local ePrev = state.errPrev
        if not isFinite(ePrev) then ePrev = err end
        local dFilt = state.dFilt
        if not isFinite(dFilt) then dFilt = 0 end
        local iTerm = state.iTerm
        if not isFinite(iTerm) then iTerm = 0 end
        -- Once the error changes side, the accumulated bias now pushes away from
        -- the path. Drop it immediately instead of spending seconds unwinding.
        if iTerm * err < 0 then iTerm = 0 end

        dFilt = dFilt + D_ALPHA * ((err - ePrev) / dt - dFilt)

        local iNext = iTerm + KI * err * dt
        if iNext > I_MAX then iNext = I_MAX elseif iNext < -I_MAX then iNext = -I_MAX end

        steer = KP * err + iNext + KD * dFilt
        if steer > STEER_MAX then
            steer = STEER_MAX
            if err > 0 then iNext = iTerm end   -- 已飽和且誤差還在同方向推：不累積
        elseif steer < -STEER_MAX then
            steer = -STEER_MAX
            if err < 0 then iNext = iTerm end
        end

        state.iTerm = iNext
        state.dFilt = dFilt
        state.errPrev = err
    end

    return steer, targetSpeed, remaining, reached, err, bestD, latSigned
end

-- 放掉 exact line 借用：setExactLine 會把 ovX/ovY 指向呼叫端的陣列，這裡指回
-- state 自有槽並清點數。三個「不再有前視折線」的入口共用同一份釋放語意。
local function releaseExactLine(state)
    state.ovN = 0
    state.ovEndS = nil
    state.exactLine = false
    if type(state.ownOvX) == "table" then
        state.ovX, state.ovY = state.ownOvX, state.ownOvY
    end
end

-- 就地重設（不配置）。換 route 時對同一顆 state 呼叫這個。
function MDADFollower.resetState(state)
    if type(state) ~= "table" then return state end
    state.idx = 1
    state.iTerm = 0
    state.dFilt = 0
    -- errPrev 刻意留空（不是 0）：control 對缺值會用「當幀誤差」當歷史，因此重設後的
    -- 第一幀微分項貢獻 0。若填 0，車頭原本偏 130° 時第一幀會吃到 (2.27-0)/dt 的假尖刺。
    state.errPrev = nil
    state.rotating = false
    state.curveValid = false
    state.curveKappa = 0
    state.curveHardActive = false
    state.curveCapKmh = 0
    state.offL = nil
    releaseExactLine(state)
    return state
end

-- 只清「控制歷史」（PID 積分／微分／誤差歷史／調頭旗標／側偏剖面），**保留投影
-- 游標 idx**。給「路線沒換、控制脈絡斷了」的情境用——倒車脫困成功就是典型：
-- 車還在同一條路線的同一段附近，若連 idx 一起歸 1（resetState），投影窗口
-- （±SEARCH_BACK/FWD 段）會從路線起點慢慢爬回來，這期間 remaining ≈ 全長、
-- 前視點在路線開頭，車會朝起點打滿方向（2026-08-28 M4 review 兩條 lane 同時
-- 抓到的 blocker）。脫困的小幅倒退由投影的 REWIND_MAX 自行收斂。
function MDADFollower.resetControl(state)
    if type(state) ~= "table" then return state end
    state.iTerm = 0
    state.dFilt = 0
    state.errPrev = nil -- 同 resetState：留空讓第一幀微分項為 0
    state.rotating = false
    state.curveValid = false
    state.curveHardActive = false
    state.curveKappa = 0
    state.curveCapKmh = 0
    state.offL = nil
    releaseExactLine(state)
    return state
end

-- 設定繞行側偏剖面（M4）：a < b <= c < d 為弧長斷點（進入起、保持起、保持終、
-- 回歸終），l 為峰值側偏（公尺，> 0＝PZ 世界的行進方向右側）。引數不合法回 false 且不動 state——
-- 呼叫端（driver）必須檢查回傳，忽略等於「以為在繞、其實直直開進障礙」。
-- b == c 允許（保持段長 0＝越過點狀障礙）；**l == 0 是合法剖面**（借中心線
-- 超越路緣障礙——靠右行駛時最常見的繞行線就是中線；2026-08-28 codex 對抗審
-- BLOCKING：0 當 inactive sentinel 會讓「借中線」被拒收、車只停不繞）。
-- 無剖面＝offL 為 nil（clearOffset），不再用數值 0 當哨兵。
-- srcX/srcY/srcN/srcS0/srcS1＝Driver 已掃掠的同一條 M6 世界折線；srcS1 是
-- 最末點真正取樣的弧長（最後一格可短於 OV_STEP）。
function MDADFollower.setOffset(state, a, b, c, d, l,
        srcX, srcY, srcN, srcS0, srcS1)
    if type(state) ~= "table" then return false end
    if not (isFinite(a) and isFinite(b) and isFinite(c) and isFinite(d) and isFinite(l)) then
        return false
    end
    if not (a < b and b <= c and c < d) then return false end
    if type(srcX) ~= "table" or type(srcY) ~= "table"
            or not isFinite(srcN) or not isFinite(srcS0)
            or not isFinite(srcS1) then return false end
    srcN = srcN - srcN % 1
    local lastStart = srcS0 + (srcN - 2) * OV_STEP
    if srcN < 2 or srcN > OV_MAX or srcS1 < d + 1 - 1e-6
            or srcS1 <= lastStart or srcS1 > lastStart + OV_STEP + 1e-6 then
        return false
    end
    for i = 1, srcN do
        if not isFinite(srcX[i]) or not isFinite(srcY[i]) then return false end
    end
    state.offA, state.offB, state.offC, state.offD, state.offL = a, b, c, d, l
    state.ovX, state.ovY = srcX, srcY
    state.ovN, state.ovS0, state.ovEndS = srcN, srcS0, srcS1
    state.exactLine = false
    return true
end

-- RETURN commits the exact array that the Driver already swept. Unlike dodge,
-- no copy is allowed: identity/content equality is part of the safety contract.
function MDADFollower.setExactLine(state, srcX, srcY, srcN, srcS0, srcS1)
    if type(state) ~= "table" or type(srcX) ~= "table" or type(srcY) ~= "table"
            or not isFinite(srcN) or not isFinite(srcS0) or not isFinite(srcS1)
            or srcS1 <= srcS0 then
        return false
    end
    srcN = srcN - srcN % 1
    local lastStart = srcS0 + (srcN - 2) * OV_STEP
    if srcN < 2 or srcN > OV_MAX or srcS1 <= lastStart
            or srcS1 > lastStart + OV_STEP + 1e-6 then return false end
    for i = 1, srcN do
        if not isFinite(srcX[i]) or not isFinite(srcY[i]) then return false end
    end
    state.offL = nil
    state.ovX, state.ovY = srcX, srcY
    state.ovN, state.ovS0, state.ovEndS = srcN, srcS0, srcS1
    state.exactLine = true
    return true
end

function MDADFollower.clearOffset(state)
    if type(state) ~= "table" then return end
    state.offL = nil
    releaseExactLine(state)
end

-- M6：建世界 offset 折線。沿 route s∈[s0, d+1] 每 OV_STEP 取樣，每點＝
-- 路線點＋lane(s)·n̂(s)：lane 用與 control 相同的 smoothstep（bias→l→bias），
-- n̂ 在距段端 OV_BLEND 內與鄰段法向做**角度插值**——折點連續是 M6 的全部
-- 意義（舊逐段法向在折點跳 2|l|sin(θ/2)）。寫進呼叫端預配置陣列（零配置），
-- 回 (點數, s0)。s0＝呼叫端指定的掃掠起點（含車位前的 bias 段一併烘進表，
-- 掃掠與前視驗的、走的是同一條線）。
function MDADFollower.buildOffsetLine(profile, s0, a, b, c, d, l, bias, outX, outY,
        returnLaneStart, returnLaneTarget, returnLaneEnd)
    if type(profile) ~= "table" or profile.ready ~= true then return 0, 0, "invalid", 0 end
    if not (isFinite(s0) and isFinite(a) and isFinite(d) and isFinite(l)) then
        return 0, 0, "invalid", 0
    end
    if not isFinite(bias) then bias = 0 end
    local px, py = profile.x, profile.y
    local ss, segLen, segH = profile.s, profile.segLen, profile.segH
    local n = profile.n
    if s0 < 0 then s0 = 0 end
    local requiredEnd = d + 1
    if requiredEnd > profile.length then return 0, 0, "coverage", profile.length end
    local span = (requiredEnd - s0) / OV_STEP
    local whole = span - span % 1
    if whole < span then whole = whole + 1 end
    local count = whole + 1
    if count > OV_MAX then return 0, 0, "capacity", 0 end
    if count < 2 then return 0, 0, "invalid", 0 end
    local j = 1
    for k = 1, count do
        local sk = s0 + (k - 1) * OV_STEP
        if k == count then sk = requiredEnd end
        while j < n - 1 and ss[j + 1] < sk do j = j + 1 end
        local lenJ = segLen[j]
        local t = 0
        if lenJ > 0 then
            t = (sk - ss[j]) / lenJ
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
        end
        local bx = px[j] + (px[j + 1] - px[j]) * t
        local by = py[j] + (py[j + 1] - py[j]) * t
        local h = segH[j]
        local dEnd = ss[j + 1] - sk
        local dStart = sk - ss[j]
        if dEnd < OV_BLEND and j + 1 <= n - 1 then
            local dh = wrapPi(segH[j + 1] - h)
            h = h + dh * (1 - dEnd / OV_BLEND) * 0.5
        elseif dStart < OV_BLEND and j > 1 then
            local dh = wrapPi(segH[j - 1] - h)
            h = h + dh * (1 - dStart / OV_BLEND) * 0.5
        end
        local lane = bias
        if isFinite(returnLaneStart) and isFinite(returnLaneTarget) then
            local laneEnd = isFinite(returnLaneEnd) and returnLaneEnd or d
            local t2 = (sk - s0) / (laneEnd - s0)
            if t2 < 0 then t2 = 0 elseif t2 > 1 then t2 = 1 end
            t2 = t2 * t2 * (3 - 2 * t2)
            lane = returnLaneStart + (returnLaneTarget - returnLaneStart) * t2
        elseif sk > a and sk < d then
            local t2
            if sk < b then
                t2 = (sk - a) / (b - a)
            elseif sk > c then
                t2 = (d - sk) / (d - c)
            else
                t2 = 1
            end
            t2 = t2 * t2 * (3 - 2 * t2)
            lane = bias + (l - bias) * t2
        end
        outX[k] = bx - sin(h) * lane
        outY[k] = by + cos(h) * lane
    end
    return count, s0, "ok", requiredEnd
end

-- Completed-snapshot proof line for the actual lane-biased smoothed profile.
function MDADFollower.buildLaneLine(profile, s0, s1, lane, outX, outY, startIdx, outSeg)
    if type(profile) ~= "table" or profile.ready ~= true
            or not isFinite(s0) or not isFinite(s1) or s1 <= s0
            or not isFinite(lane) or type(outX) ~= "table" or type(outY) ~= "table" then
        return 0, 0, "invalid", 0
    end
    if s0 < 0 then s0 = 0 end
    if s1 > profile.length then s1 = profile.length end
    if s1 <= s0 then return 0, 0, "invalid", 0 end
    local span = (s1 - s0) / OV_STEP
    local whole = span - span % 1
    local count = whole + 1
    if whole < span then count = count + 1 end
    if count > LANE_MAX then return 0, 0, "capacity", 0 end
    local px, py = profile.x, profile.y
    local ss, segLen, segH = profile.s, profile.segLen, profile.segH
    local n, j = profile.n, startIdx
    if not isFinite(j) then j = 1 else j = j - j % 1 end
    if j < 1 then j = 1 elseif j > n - 1 then j = n - 1 end
    local lo, hi = 1, n - 1
    if ss[j] <= s0 then lo = j else hi = j end
    while lo < hi do
        local sum = lo + hi
        local mid = (sum - sum % 2) / 2
        if ss[mid + 1] <= s0 then lo = mid + 1 else hi = mid end
    end
    j = lo
    for k = 1, count do
        local sk = s0 + (k - 1) * OV_STEP
        if sk > s1 then sk = s1 end
        if j < n - 1 and ss[j + 1] < sk then
            lo, hi = j + 1, n - 1
            while lo < hi do
                local sum = lo + hi
                local mid = (sum - sum % 2) / 2
                if ss[mid + 1] < sk then lo = mid + 1 else hi = mid end
            end
            j = lo
        end
        local t = 0
        if segLen[j] > 0 then
            t = (sk - ss[j]) / segLen[j]
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
        end
        local h = segH[j]
        outX[k] = px[j] + (px[j + 1] - px[j]) * t - sin(h) * lane
        if type(outSeg) == "table" then outSeg[k] = j end
        outY[k] = py[j] + (py[j + 1] - py[j]) * t + cos(h) * lane
    end
    return count, s0, "ok", j
end

function MDADFollower.buildReturnLine(profile, s0, s1, laneStart, laneTarget,
        outX, outY, tailM)
    if type(profile) ~= "table" or profile.ready ~= true
            or not isFinite(s0) or not isFinite(s1) or s1 <= s0
            or not isFinite(laneStart) or not isFinite(laneTarget) then
        return 0, 0, "invalid"
    end
    if not isFinite(tailM) then tailM = 1 end
    if tailM < 1 then tailM = 1 end
    local desiredEnd = s1 + tailM
    local steps = (desiredEnd - s0) / OV_STEP
    local whole = steps - steps % 1
    if steps > whole then whole = whole + 1 end
    local lineEnd = s0 + whole * OV_STEP
    if lineEnd > profile.length then lineEnd = profile.length end
    local required = (lineEnd - s0) / OV_STEP + 1
    required = required - required % 1
    -- RETURN must be exact. Unlike legacy dodge, never truncate and later jump
    -- to laneBias when the borrowed line runs out.
    if required > OV_MAX then return 0, 0, "capacity" end
    local d = lineEnd - 1
    return MDADFollower.buildOffsetLine(profile, s0, s0, s0, s1, d,
        laneTarget, laneTarget, outX, outY, laneStart, laneTarget, s1)
end

-- Build-time block tree query: at most 62 edge segments plus O(log blocks),
-- allocation-free and independent of total tiny-segment count.
local function rangeQuery(profile, first, last)
    local brake, lat, coast = RANGE_INF, RANGE_INF, RANGE_INF
    while first <= last and (first - 1) % RANGE_BLOCK ~= 0 do
        local b, l, c = profile.segBrake[first],
            profile.segLat[first], profile.segCoast[first]
        if b < brake then brake = b end
        if l < lat then lat = l end
        if c < coast then coast = c end
        first = first + 1
    end
    while first <= last and last % RANGE_BLOCK ~= 0 do
        local b, l, c = profile.segBrake[last],
            profile.segLat[last], profile.segCoast[last]
        if b < brake then brake = b end
        if l < lat then lat = l end
        if c < coast then coast = c end
        last = last - 1
    end
    if first <= last then
        local firstBlock = (first - 1) / RANGE_BLOCK + 1
        local lastBlock = last / RANGE_BLOCK
        local left = profile.rangeBase + firstBlock - 1
        local right = profile.rangeBase + lastBlock - 1
        while left <= right do
            if left % 2 == 1 then
                local b, l, c = profile.rangeBrake[left],
                    profile.rangeLat[left], profile.rangeCoast[left]
                if b < brake then brake = b end
                if l < lat then lat = l end
                if c < coast then coast = c end
                left = left + 1
            end
            if right % 2 == 0 then
                local b, l, c = profile.rangeBrake[right],
                    profile.rangeLat[right], profile.rangeCoast[right]
                if b < brake then brake = b end
                if l < lat then lat = l end
                if c < coast then coast = c end
                right = right - 1
            end
            left = (left - left % 2) / 2
            right = (right - right % 2) / 2
        end
    end
    return brake, lat, coast
end

-- Bounded future dynamics query. Segment indices are found by hint-bounded
-- binary search; minima come from the build-time tree rather than a tiny-segment scan.
function MDADFollower.minDynamics(profile, s0, s1, startIdx)
    if type(profile) ~= "table" or profile.ready ~= true
            or profile.rangeReady ~= true or not isFinite(s0)
            or not isFinite(s1) or s1 < s0 then return 0, 0, 0, 0 end
    local nseg = profile.n - 1
    local hint = startIdx
    if not isFinite(hint) then hint = 1 else hint = hint - hint % 1 end
    if hint < 1 then hint = 1 elseif hint > nseg then hint = nseg end
    local lo, hi = 1, nseg
    if profile.s[hint] <= s0 then lo = hint else hi = hint end
    while lo < hi do
        local sum = lo + hi
        local mid = (sum - sum % 2) / 2
        if profile.s[mid + 1] <= s0 then lo = mid + 1 else hi = mid end
    end
    local first = lo
    lo, hi = first, nseg
    while lo < hi do
        local sum = lo + hi + 1
        local mid = (sum - sum % 2) / 2
        if profile.s[mid] < s1 then lo = mid else hi = mid - 1 end
    end
    local last = lo
    local brake, lat, coast = rangeQuery(profile, first, last)
    return brake, lat, coast, last + 1
end

function MDADFollower.setRuntimeLimits(state, accel, brake, lat, coast)
    if type(state) ~= "table" then return false end
    if not isFinite(accel) or accel < 0 or not isFinite(brake) or brake < 0
            or not isFinite(lat) or lat < 0 or not isFinite(coast) or coast < 0 then
        return false
    end
    state.accelSafe, state.brakeSafe, state.latSafe, state.coastSafe =
        accel, brake, lat, coast
    return true
end

function MDADFollower.capSegmentLimits(profile, accel, brake, lat, coast)
    if type(profile) ~= "table" or not isFinite(accel) or accel < 0
            or not isFinite(brake) or brake < 0 or not isFinite(lat) or lat < 0
            or not isFinite(coast) or coast < 0 then return false end
    for i = 1, profile.n - 1 do
        if profile.segAccel[i] > accel then profile.segAccel[i] = accel end
        if profile.segBrake[i] > brake then profile.segBrake[i] = brake end
        if profile.segLat[i] > lat then profile.segLat[i] = lat end
        if profile.segCoast[i] > coast then profile.segCoast[i] = coast end
    end
    return true
end

function MDADFollower.invalidateDynamics(profile)
    if type(profile) ~= "table" then return false end
    profile.ready = false
    profile.phase = "geometry"
    profile.cursor = 1
    profile.length = 0
    profile.rangeReady = false
    return true
end

-- 數值 id → 遙測字串。未知／非法 id 一律 "unknown"（與 v2/v3 的明確未知同語意）。
function MDADFollower.surfaceName(id)
    return SURFACE_NAME[id] or "unknown"
end

-- 常駐車道偏置（公尺，> 0＝PZ 世界的行進方向**右**、< 0＝左；靠右行駛給正值）。與繞行剖面不同，
-- 這是「設定」不是「狀態」：resetState／resetControl 都**不清**它——換路線、
-- 脫困、讓位恢復後照樣靠右。非有限值當 0（關閉）。設定入口收在這裡，
-- 呼叫端不要直接寫 state.laneBias。
function MDADFollower.setLaneBias(state, bias)
    if type(state) ~= "table" then return false end
    if not isFinite(bias) then bias = 0 end
    state.laneBias = bias
    return true
end

-- ownOvX/ownOvY＝state 自有的前視折線槽；resetState 會把 ovX/ovY 指回它們。
function MDADFollower.newState()
    return MDADFollower.resetState({ ownOvX = {}, ownOvY = {} })
end

-- 前向向量 → heading（弧度）。呼叫端與本模組共用同一份慣例，避免左右相反。
function MDADFollower.headingFromForward(fx, fy)
    if not isFinite(fx) or not isFinite(fy) then return 0 end
    if fx == 0 and fy == 0 then return 0 end
    return atan2(fy, fx)
end
