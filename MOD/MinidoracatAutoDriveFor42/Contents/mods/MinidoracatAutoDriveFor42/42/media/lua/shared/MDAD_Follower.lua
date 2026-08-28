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
-- MDADFollower.begin(route, maxSpeed)
--     route    ＝ MiniMap nav API requestRoute 回的路線物件；只讀 route.pts
--                （扁平 x,y；第 i 點＝pts[i*2-1], pts[i*2]）。**本模組視 route 為唯讀**。
--     maxSpeed ＝ 巡航上限，km/h（沙盒值）。非數字／非有限／過小過大一律夾限。
--     回 profile（唯讀）或 nil, "badroute"。
--     這是整個模組唯一配置 table 的地方（每條路線一次）。
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
--     回 steer, targetSpeed, remaining, reached, headingError
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
-- * 前視（pure pursuit）：lookahead ＝ 6 + |speed| * 0.12，夾 [6, 18] 公尺。
--   低速要短前視才咬得住彎，高速要長前視才不會左右擺。
-- * 曲率限速：v = sqrt(a_lat / kappa)，kappa ＝ |Δθ| / ds（三點折線的離散曲率）。
--   夾 [MIN_SPEED_KMH, maxSpeed]：下限存在的理由是路網折線在交叉口會出現接近 180°
--   的假急彎，沒有下限車會停在原地永遠出不去。
-- * 反向制動（backward pass）：v[i] <= sqrt(v[i+1]^2 + 2*BRAKE*L)。終點 v = 0，
--   所以「彎前先減速」與「終點前煞停」是同一條式子推出來的，不是兩套特例。
-- * 前向加速（forward pass）：v[i+1] <= sqrt(v[i]^2 + 2*ACCEL*L)。因為
--   sqrt(v[i]^2 + 2aL) >= v[i]，這一遍只會壓低「爬升過快」的點、絕不會把
--   某點壓到比前一點低，因此不會破壞前一遍算出的制動可行性。
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

local ACCEL = 2.0             -- m/s²：前向加速上限
local BRAKE = 3.0             -- m/s²：減速上限
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
local SEARCH_FWD = 12         -- 往前 12 段
local REWIND_MAX = 1          -- 單幀最多允許倒退 1 段

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
    local pts = p.route.pts
    local x, y = pts[i * 2 - 1], pts[i * 2]
    local px, py = p.x, p.y
    px[i], py[i] = x, y
    p.v[i] = p.maxSpeedMs
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
        -- 沿用前一段朝向（第一段就重合時只能給 0，此時曲率本來也算不出東西）
        segH[i - 1] = (i >= 3 and segH[i - 2]) or 0
    end
    p.s[i] = p.s[i - 1] + len
    if i >= 3 then
        local m = i - 1
        local ds = (segLen[m - 1] + segLen[m]) * 0.5
        if ds > 0 then
            local dth = wrapPi(segH[m] - segH[m - 1])
            if dth < 0 then dth = -dth end
            if dth > 0 then
                -- kappa = dth / ds；v = sqrt(a_lat / kappa) = sqrt(a_lat * ds / dth)
                local lim = sqrt(LAT_ACCEL * ds / dth)
                if lim < MIN_SPEED_MS then lim = MIN_SPEED_MS end
                if lim > p.maxSpeedMs then lim = p.maxSpeedMs end
                if p.v[m] > lim then p.v[m] = lim end
            end
        end
    end
end

-- 驗 route 並配置 profile。**唯一**會建 table 的入口。
-- 拒絕條件（一律回 nil, "badroute"，呼叫端不必分辨細節，只需要「這條路不能跟」）：
--   route／route.pts 不是 table、pts 長度非偶數、點數 < 2、任一座標非有限數、
--   所有點重合（路徑長 0，投影／曲率／前視全部沒有意義）。
-- 點數 1（#pts == 2）是 nav 真的會回的情況（A* 起錨後續節點全與前一點重合），
-- 對應 production 的 `if np < 2 then` 早退，不是假想輸入。
function MDADFollower.begin(route, maxSpeed)
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

    local n = np / 2
    return {
        route = route,      -- 唯讀引用：呼叫端用它比對「route 換了沒」
        n = n,
        pointCount = n,
        maxSpeed = maxKmh,                    -- km/h
        maxSpeedMs = maxKmh * MS_PER_KMH,     -- m/s
        x = {}, y = {},     -- 抄一份座標：不依賴呼叫端之後有沒有動 route
        s = {},             -- 累積弧長（公尺）
        segLen = {},        -- 第 i 段長（點 i → i+1），i ∈ [1, n-1]
        segH = {},          -- 第 i 段朝向（弧度）
        v = {},             -- 每點速度上限（m/s，建完表才是最終值）
        length = 0,         -- ＝ s[n]，geometry 相位結束時填
        phase = "geometry", -- 診斷用可讀欄位
        cursor = 1,         -- 診斷用可讀欄位
        ready = false,
    }
end

-- 增量建表。每次呼叫最多做 budget 個點運算；相位切換本身不算運算，
-- 但相位是單向的（geometry → brake → accel → ready），所以不會空轉。
function MDADFollower.stepBuild(profile, budget)
    if type(profile) ~= "table" then return false end
    if profile.ready == true then return true end

    if not isFinite(budget) then budget = BUDGET_DEFAULT end
    budget = budget - budget % 1        -- 純 Lua floor（不跨界呼叫 math.floor）
    if budget < 1 then budget = 1 end
    if budget > BUDGET_MAX then budget = BUDGET_MAX end

    local n = profile.n
    local v, segLen = profile.v, profile.segLen
    local ops = 0
    while ops < budget do
        local phase = profile.phase
        if phase == "geometry" then
            local i = profile.cursor
            if i > n then
                v[n] = 0                    -- 終點必須停下；反向制動段由此展開
                profile.length = profile.s[n]
                profile.phase = "brake"
                profile.cursor = n - 1
            else
                geometryStep(profile, i)
                profile.cursor = i + 1
                ops = ops + 1
            end
        elseif phase == "brake" then
            local i = profile.cursor
            if i < 1 then
                profile.phase = "accel"
                profile.cursor = 1
            else
                local lim = sqrt(v[i + 1] * v[i + 1] + 2 * BRAKE * segLen[i])
                if v[i] > lim then v[i] = lim end
                profile.cursor = i - 1
                ops = ops + 1
            end
        elseif phase == "accel" then
            local i = profile.cursor
            if i > n - 1 then
                profile.phase = "ready"
                profile.cursor = n
                profile.ready = true
                return true
            else
                local lim = sqrt(v[i] * v[i] + 2 * ACCEL * segLen[i])
                if v[i + 1] > lim then v[i + 1] = lim end
                profile.cursor = i + 1
                ops = ops + 1
            end
        else
            -- 未知相位（profile 被外部改壞）：當成完成，別讓呼叫端每幀空轉
            profile.phase = "ready"
            profile.ready = true
            return true
        end
    end
    return profile.ready == true
end

-- 每幀控制。零配置：只讀 profile、只就地寫 state 的數值欄位。
function MDADFollower.control(profile, state, x, y, heading, speed, dt)
    if type(profile) ~= "table" or profile.ready ~= true or type(state) ~= "table" then
        return 0, 0, 0, false, 0
    end
    if not isFinite(x) or not isFinite(y) or not isFinite(heading) then
        -- 車輛座標壞掉（換載具／剛傳送）：不轉向、不給速度，把剩餘距離照實回報
        return 0, 0, profile.length, false, 0
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
    local look = LOOKAHEAD_BASE + aspeed * LOOKAHEAD_PER_KMH
    if look < LOOKAHEAD_MIN then look = LOOKAHEAD_MIN end
    if look > LOOKAHEAD_MAX then look = LOOKAHEAD_MAX end

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

    -- ---- 目標速度（段內線性插值；曲率／制動／加速都已經烘進 v）----
    local v = profile.v
    local targetSpeed = (v[bestI] + (v[bestI + 1] - v[bestI]) * bestT) * KMH_PER_MS

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

    return steer, targetSpeed, remaining, reached, err
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
    return state
end

function MDADFollower.newState()
    return MDADFollower.resetState({})
end

-- 前向向量 → heading（弧度）。呼叫端與本模組共用同一份慣例，避免左右相反。
function MDADFollower.headingFromForward(fx, fy)
    if not isFinite(fx) or not isFinite(fy) then return 0 end
    if fx == 0 and fy == 0 then return 0 end
    return atan2(fy, fx)
end
