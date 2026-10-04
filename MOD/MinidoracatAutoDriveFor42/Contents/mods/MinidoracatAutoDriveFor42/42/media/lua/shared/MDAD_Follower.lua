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
-- MDADFollower.begin(route, maxSpeed, navVersion, vehicleProfile, style)
--     style    ＝ MDADFollower.STYLES 的一檔（brisk／comfort）；省略＝brisk（現行行為逐位元不變）。
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
-- * 幾何：折線＋累積弧長 s。投影以局部段窗搜尋，再由前幀位置／實際位移限制前向交接；
--   高速碎段依可達弧長擴窗。全域最近點只供首次補定位，避免回頭路／繞圈瞬移到另一臂。
-- * 前視（pure pursuit）：lookahead ＝ lookScale*(6 + |speed|*0.12)，夾在
--   [6*lookScale,18*lookScale]；非 adaptive profile 的 lookScale=1。急彎再
--   min(look, 0.75/κ)、下限 4.5m（2026-09-02：治切內又不放大增益到蛇行）。
-- * 曲率限速：v = sqrt(segLat / kappa)，kappa ＝頂點外接圓曲率
--   （circumcircleKappa；|Δθ| 只用於 TURN_* 折角帽）。
--   夾 [MIN_SPEED_KMH, maxSpeed]：下限避免路網近 180° 假折點把車永遠停住。
-- * 反向制動：v[i] <= sqrt(v[i+1]^2 + 2*segBrake[i]*L)。終點 v = 0，
--   所以「彎前先減速」與「終點前煞停」由同一式推出。
-- * 前向加速不設剖面天花板（2026-09-01 三模型對抗審定案）：regulator 供油是
--   二值全力（CarController.java:240-244 isGas；engineForce 不乘 throttle＝:755），
--   剖面掐加速目標只會讓 regulator 目標貼著現速斷續供油、重車永遠加不上去。
--   加速能力交還引擎；segAccel 保留為 ETA／遙測資料，不進控制。
-- * PID：P 抓誤差、I 補系統性偏置（車體不對稱、路面阻力）、D 抑制擺盪。
--   I 有 ±I_MAX 飽和 ＋ 條件積分（飽和且誤差同向就不累積）；D 先低通再進 PID，
--   因為折線朝向是階梯狀的，raw (err-prev)/dt 在換段瞬間會打出尖刺。
-- * 原地調頭（rotate）：|誤差| > 135° 進入、< 100° 離開（hysteresis；沒有遲滯的話
--   車頭在門檻附近會 PID／調頭兩種模式互相打架）。調頭時 PID 的線性假設不成立，
--   直接飽和轉向＋爬行速度，並凍結積分項。
--
-- 效能守則（Kahlua）：庫函式都是 JavaFunction，每次呼叫都跨 Lua↔Java 邊界。
-- 因此全部庫函式在載入期取成 local upvalue；夾限一律用純 Lua 比較。
-- math 函式只做純量運算；路線幾何留在建表期，control 的位移與曲率運算零 table 配置。

if not MDADDynamics then require "MDAD_Dynamics" end

MDADFollower = MDADFollower or {}

-- math.atan2 在遊戲的 Kahlua 裡存在（原版用例：client/Foraging/ISBaseIcon.lua:210、
-- client/PZAPI/ui/testUI.lua:79）。標準 Lua 5.3 起把它移除、改成 math.atan(y, x)
-- 兩參數形式——退回 math.atan 讓離線測試不必打任何 shim，語意完全相同。
local atan2 = math.atan2 or math.atan
local sqrt, cos, sin, tan = math.sqrt, math.cos, math.sin, math.tan
local PI = math.pi
local TWO_PI = PI * 2

local MS_PER_KMH = 1 / 3.6
local KMH_PER_MS = 3.6

local ACCEL_NOMINAL = 2.5     -- m/s²：segAccel 的名義預設。僅供 ETA／遙測與
                              -- capSegmentLimits 的欄位收緊；**不進任何控制路徑**
                              -- （前向加速無剖面天花板，見檔頭「前向加速」註解）
local BRAKE = 8.0             -- m/s²：減速上限基準。引擎煞停力無 SI 反編譯出處
                              -- （CarController brakingForce 的 10/15 是遊戲單位，
                              -- 非 m/s²），8.0 是標定包絡。雨天／爛胎由
                              -- VehicleProfile.priors 的 fSurface×fTire 另行縮放，
                              -- 基準不再預扣——舊值 6.0（「實煞的六成留雨天餘裕」）
                              -- 疊上 priors 天氣折＝晴天好胎被雙重保守，48m 感知帶
                              -- 只能證明 72 km/h（2026-09-01 調實：a=8 → 82 km/h）
local LAT_ACCEL = 9.0         -- m/s²：過彎橫向加速預算（2026-09-02 二次激進化
                              -- 8.0→9.0「過彎應該再快一點」；滑移是合法手段，
                              -- 輪胎/雨天縮放由 priors 另計）
local MIN_SPEED_KMH = 12      -- 曲率限速的下限（見上方說明）
local MAX_SPEED_CAP_KMH = 160 -- maxSpeed 的上界（防呆，不是遊戲設定）
local MIN_SPEED_MS = MIN_SPEED_KMH * MS_PER_KMH
local ARRIVE_M = 5            -- 抵達判定半徑（公尺）：沿線剩餘距離與終點直線距離共用
local ARRIVE_M_SQ = ARRIVE_M * ARRIVE_M
local COAST_STOP_M = ARRIVE_M - 1 -- 終點滑行包絡的停點：到站圈內 1m（理由見 stepBuild）

local LOOKAHEAD_BASE = 6
local LOOKAHEAD_PER_KMH = 0.12
local LOOKAHEAD_MIN = 6
local LOOKAHEAD_MAX = 18
-- 貼縫切線追蹤的預視距（state.trackTangent）。離線閉環（自行車＋一階 yaw 延遲，scripts/
-- exp_gap_tangent.lua）：1m 出口外甩大、3m 幾乎退回前視點的落後；1.5m 進入段峰值／到 b 的落後
-- 較現制降 40-60%、出口前切內 0.3-0.8→≤0.2。plant 反應慢一倍（tau 0.7）時外甩 ≤0.6，
-- 實機若見貼縫段左右擺就加大到 2。
local TANGENT_PREVIEW_M = 1.5
local TANGENT_MAX_TURN_RAD = 15 * PI / 180 -- 前視窗內路線轉角超過此值交回前視點
-- 常駐車道斜率（見 control 的弧段切線）取在車前 LEAD 秒：yaw 滯後 τ 0.25–0.35 s（E2E 遙測辨識），斜率照
-- 當下量＝車頭晚 τ 才跟上車道 ramp，ramp 結束時多衝出去。0928o 離線重播 11 個真彎×3 plant：0.2 s 讓 max|偏差|
-- 幾乎每彎下降（外漂總和 16.1→12.9、切內 7.2→8.9，最大外漂 1.88→1.68）；0.3 s 起切內回升、換邊而不是變好。
-- 0929a 前饋加上車道 ramp 曲率後重測仍以 0.2 最好（重播切內總和 0 s：10.9、0.2 s：10.2、0.35 s：12.0，外漂持平）。
local TANGENT_SLOPE_LEAD_S = 0.2
-- 弧段前饋（2026-09-08 s041/s045/s025/s034：同一個 R≈11 左彎四台車全撞外側路緣——切線
-- 追蹤把姿態誤差壓到 0.2 rad、cross-track 對 1m 外漂只給 0.18，純回饋要靠誤差累積才出力，
-- yaw 率一路只有需求的 75-80%、lat 從 1.0 漂到 2.0）。弧上的需求 yaw 率 v·κ 是已知量：
-- steer_ff = CURVE_FF_FRAC · v·κ / yawGain。yawGain（rad/s 每單位 steer）**線上估計**——
-- 十三場 telemetry 的 yaw率/(steer·v) 中位數：RaceCar／救護車 24 km/h 0.16-0.21、F350 23 km/h
-- 0.10-0.12、F350 39 km/h 0.03（隨車重、車長、速度差六倍，固定常數不可能對）；估計器＝
-- 上幀施出的 steer（Driver 回寫 appliedSteer，含 cross-track 與夾限）對本幀 yaw 率的比值
-- EWMA（τ 0.5s、只在 |steer| ≥ 0.3、v ≥ 8 km/h 更新、夾 [0.08, 3]）。FRAC 0.7 給七成、剩下回饋
-- 補；前饋偏大時切線／cross-track 反向抵銷。INIT 0.8 貼重車（F350 24 km/h 0.77；RaceCar 1.3
-- 只多付 0.5s 收斂的 0.1-0.2m 切內）。進弧前 LEAD 秒線性爬升（一階 yaw
-- 延遲 τ≈0.35：進弧那刻 yaw 率才從 0 起步＝前 3m 必外漂）。
-- 離線閉環（test_follower 情境 25 的 plant，KPS 0.05-0.3）：K0.10 外漂 1.57→0.44、K0.15
-- 0.67→0.23、K0.20 0.25→0.05（切內 0.10）；FRAC 0.8 在 K0.2 切內 0.21、1.0 在 K0.15 就 0.37。
-- 0929a 提為 0.75：前饋改照實際行駛線曲率（R∓l、車道 ramp 的 l''，見 arcFeedForward）後外側車道少給、內側多給，
-- 0.7 的七成缺口在外側車道低速彎反而外漂更多（情境 35 的 25 km/h R11 外側車道 0.39→0.63）；0.75 對 0928p：
-- 11 個真彎重播（三種 plant）外漂總和 12.9→8.1、切內 8.9→10.2，合成六彎 G0.85 切內 0.25→0.21、外漂 0.61→0.41。
local CURVE_FF_FRAC = 0.75
-- 高速前饋補足（0928m；rc10 0135 StepVan 25-43 km/h 左彎外漂 0.66m、rc12 0200 KST 72 km/h R≈65 外漂 0.34→0.96、
-- rc11 0177 F350 61 km/h 同型）：FRAC 0.7 的缺口由位置環（~1/v）補，高速時補不回來。但**不能拿低速學到的
-- yawGain 直接補足**：側推的 yaw 增益隨車速與車型變，E2E rc13 RaceCar34 79 km/h R81 實測約 1.15、估計 0.75，
-- 前饋照 1.0 補足＝多轉 50%、弧前就切內 1.2m、對線帽把 79 壓到 47。高速增益另外在弧上學（上幀前饋
-- ≥ FF_HI.minFF、實速 ≥ FF_HI.learnKmh；ESC 限幅讓 steer 逐幀跳動，yaw 與 steer 各自 EWMA 後相除，不用逐幀
-- 比值）；累計學滿 FF_HI.learnS 才在 fromKmh→fullKmh 之間改用高速增益、FRAC 補到 FF_HI.frac，之前照舊（0.7／低速增益）。
-- 離線閉環（test_follower 情境 35，plant 增益正確時）：72 km/h R65 外漂 1.24→0.8 級、45 km/h R30 0.98→0.5 級。
-- 只在弧上穩態學、steer 補一階延遲（1002u）：yaw 落後 steer 約 τ，前饋收尾／爬升時 steer 先降、yaw 還在＝比值灌高
-- （1001h E2E rc45arc 1006：連續小弧間前饋鋸齒，0.97→2.19，R60 彎前饋只剩四成外漂接觸）。學習改成①前饋整份
-- （ramp 1 且車在弧上，見 arcFeedForward 的 state.ffFull）連續 settleS 以上，②steer 那邊用 settleS 一階低通後的值
-- （yaw＝G·lag(u)，兩邊同步）。離線閉環（plant τ 0.25–0.5、G 0.6–1.0，同向／交錯小弧與大彎，70 km/h）學到的最大值
-- 最多 +20%（τ 0.25 交錯 18°），舊學法同場景最多 +32%（τ 0.5）、實機 +125%；只做①最多 +24%、只做②最多 +77%（plant 比假設快）。
-- 一張表（control 的 upvalue 已貼 60 上限）：fromKmh→fullKmh 補足區間、frac＝補足到的 FRAC、
-- learnKmh／minFF＝高速增益的學習條件（實速／上幀前饋量）、learnS＝學滿才補足、settleS＝假設的 yaw 延遲 τ
-- （穩態門檻與 steer 低通共用；前饋進弧爬升的 CURVE_FF_LEAD_S 是同一個量）。fbOppose＝回授正規化增益（yawGainFb）
-- 剔除的反相 yaw 率門檻（rad/s，見 control 的 yaw 增益估計段）；inM／inSpanM＝弧段前饋的彎內偏差退讓（見
-- arcFeedForward 尾段）；同表是為了不多占 control 的 upvalue。
local CURVE_FF_LEAD_S = 0.35
local FF_HI = { fromKmh = 30, fullKmh = 55, frac = 0.9, learnKmh = 40, minFF = 0.1, learnS = 0.5,
    settleS = CURVE_FF_LEAD_S, fbOppose = 0.5, inM = 0.3, inSpanM = 0.5 }
local CURVE_FF_MAX = 0.8 -- 小增益長車不能用倒數把前饋放大成整車橫推；回饋仍保留完整權威。
local YAW_GAIN_INIT = 0.8
local YAW_GAIN_TAU_S = 0.5
local YAW_GAIN_MIN_STEER = 0.3
local YAW_GAIN_MIN_KMH = 8
-- 下限 0.08（0929j；原 0.2）：KI5 Oshkosh 消防車真實增益 0.15–0.19、SemiTruckBox_mil 0.09–0.12，舊下限讓估計
-- 永遠停在 0.2 以上（玩家 session-012 撞物前整段 yg 0.20–0.21＝貼在下限），前饋與 Driver 的回授正規化
-- （TUNE.FB_NORM_*）都以為這台車比實際好轉。一般車估計值在 0.47–0.99，觀測很少低於 0.2，語料重放改下限後
-- 中位數變化 ≤0.01。
local YAW_GAIN_LO, YAW_GAIN_HI = 0.08, 3.0
local KINK_EXIT_ALIGN_RAD = 6 * PI / 180
local KINK_EXIT_LANE_M = 0.5
local LOOKAHEAD_WALK_MAX = 64 -- 前視推進的段數硬上限（碎段路線不得變成 O(n) 迴圈）
-- 髮夾折點（0907c；session-060 121° 路口撞內側圍籬柱）：90°<θ<150° 的非弧頂點（>90°＝geometryStep
-- 保留折點爬行的同一類；≥150° 交給調頭遲滯——鉗到頂點會讓折返／死路盡頭超跑 1.4m）。前視目標
-- 鉗在折點直到車距折點 rMin·tan(θ/2)（＝理想圓角在這一臂的切點距；121°／rMin 2.26 → 4.0m），
-- 夾 [HAIRPIN_APEX_MIN, MAX]。離線閉環（temp/exp_hairpin.lua，plant rMin 2.5）121° 4m→8m 路：
-- 不鉗＝折點前切內 1.8m、離路緣柱 0.2；鉗到 1m＝切內 0.05 但出彎臂外甩 4.0m（頂點滿舵 121° 的幾何
-- ＝1.5R）；鉗到切點距＝切內 0.8／外甩 1.6／離柱 1.14——人開窄路髮夾也是在圓角切點才打方向盤。
-- 切線追蹤在折點前 OV_BLEND 退回前視點（ov 線的混合區法向已在轉、跟它＝提前切內）。折點內側的
-- 路緣物由既有繞行處理（session-060 的 −0.75 承諾線離柱 1.5m 本來夠，是切內把它吃掉）；曾試在
-- laneRoom 把折點 ±6m 餘裕歸零——餘裕表逐段，60m 直臂會整條失去靠右，撤。
local HAIRPIN_RAD = PI * 0.5
local HAIRPIN_MAX_RAD = 150 * PI / 180
local HAIRPIN_APEX_MIN = 1.0
local HAIRPIN_APEX_MAX = 6.0
local HAIRPIN_RMIN_DEFAULT = 3.0 -- 無車輛幾何（v3 路線）時的圓角半徑假設

local SEARCH_BACK = 12        -- 投影搜尋窗口：往後 12 段
-- 折點角度限速下限（不除 ds，路網點距稀釋不掉；理由見 geometryStep 內註解）
local TURN_SOFT_RAD = 30 * PI / 180  -- 折角超過 30° 開始壓（激進化 25→30）
local TURN_HARD_RAD = 55 * PI / 180  -- 折角 55° 以上一律爬到 TURN_HARD_MS
local TURN_HARD_MS = 50 / 3.6        -- 急折點硬上限：50 km/h（激進化 40→50；
                                     -- 甩尾過彎合法，61.5 甩出教訓風險由使用者
                                     -- 明示接受）——0907f 起只剩上界，折點真正的
                                     -- 速度由下方幾何式（前視弦半徑／rMin）決定
-- 折點幾何限速（0907f；2026-09-07 F350 rMin 4.32 在 4m 路的 90° 折點塞不進圓角 → fallback 頂點
-- 只吃 TURN_HARD_MS＝50 km/h → 50.8 km/h 直衝路口牆、三場 StopStuck；RaceCar 同路口圓角成功走弧段
-- 才沒事）：無圓角的頂點由 pure pursuit 以前視弦切過，路徑半徑 R(v)＝look(v)/(2·sin(θ/2))，
-- look(v)＝(6＋0.12·v_kmh)·lookScale（control 的前視式），速度取 v²＝aLat·R(v) 的正根（前視隨速
-- 變長，弦半徑也變大——用最短前視會把 25° 折點壓到 40）；下限車輛 rMin 的圓。lat 9：90° → 27.7 km/h、
-- 60° → 34、25° → 59.5（≈全速）；10° 以下＝路網量化抖動不算折。adaptive 剖面的 fallback 頂點
--（角度合格卻建不出弧＝路面容不下 rMin 的圓）只給 sqrt(aLat·rMin)：F350 → 20（lat 7）、RaceCar 14，
-- 切出路面由 contact／繞行兜底；MIN_SPEED 地板照舊。1002u 起 adaptive 剖面的 10–20° 折點先試建小弧
--（MDADDynamics.FILLET_SMALL_RAD 同一條線），建不出來的仍走這裡的弦式。
local TURN_GEOM_MIN_RAD = MDADDynamics.FILLET_SMALL_RAD
MDADFollower.TURN_GEOM_MIN_RAD = TURN_GEOM_MIN_RAD -- Driver 證明線小折點等效曲率的同一條界線（Drive.smallKinkKappa）
local SEARCH_FWD = 12         -- 往前 12 段
local REWIND_MAX = 1          -- 單幀最多允許倒退 1 段
local OV_STEP = 1.0           -- M6 世界 offset 折線的取樣步距（公尺）
local OV_MAX = MDADDynamics.PERCEPTION_HARD_MAX_M + 16 -- 額外容納車身前伸、端點與短回线
local LANE_MAX = MDADDynamics.PERCEPTION_HARD_MAX_M + 2 -- 1m證明線；剖面弧段同為1m取樣
-- Driver 以 OV_STEP 反推掃掠弧長，兩者必須同源。
local OV_BLEND = 2.0          -- 折點法向混合半徑：距段端這麼近時與鄰段做角度插值
-- 偏移線在彎內側的前進量下限（0929d）：線上一點＝路線點＋lane·n̂(h)，彎內側每走 1m 路線，線只前進
-- 1−lane·κ（κ＝法向的轉動率；圓角弧＝1/R，未圓角折點＝OV_BLEND 內的混合轉速）。lane 超過轉彎半徑時
-- 這個比例 ≤0，線在彎心附近原地來回（E2E rc23 0016：12m 路口 jog 的 R5.4 圓角，繞行 offL −5.25 在內側，
-- 1m 取樣的線步長只剩 0.08m、相鄰轉角 150–165°），切線／前視點指向車後 → 繞行中誤進原地調頭，
-- 車頭轉進路邊停的車。全部 1558 筆繞行承諾離線重建：比例 ≤0 有 19 筆、(0,0.25) 6 筆，承諾後接觸各
-- 3、2 筆（另 3 筆原地調頭）；[0.25,0.6) 的 44 筆零接觸。control 的弧段硬帽同樣把 1−lane·κ 夾在 0.25。
-- 低於此比例的線整條不建（回 "fold"），候選鏈改試別的 lane。
local OV_MIN_ADVANCE = 0.25
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
local ERR_SLOW_START = 25 * PI / 180 -- 激進化 20→25（甩尾裁定）
local ERR_SLOW_END = 90 * PI / 180   -- 激進化 75→90：跟線姿態全域不再壓爬行
local ERR_SLOW_RANGE = ERR_SLOW_END - ERR_SLOW_START
local DT_MIN = 1 / 240
local DT_MAX = 0.25
local DT_FALLBACK = 1 / 30

local BUDGET_MAX = 4096       -- 每次 stepBuild 的硬上限（呼叫端給多大都不超過）
local BUDGET_DEFAULT = 64

MDADFollower.STEER_MAX = STEER_MAX
MDADFollower.ROTATE_EXIT_RAD = ROTATE_EXIT  -- Driver 以此收尾一次調頭（resetState 清 rotating 不算結束）
MDADFollower.ARRIVE_M = ARRIVE_M
MDADFollower.COAST_STOP_M = COAST_STOP_M
MDADFollower.MIN_SPEED_KMH = MIN_SPEED_KMH
MDADFollower.BUDGET_MAX = BUDGET_MAX
MDADFollower.OV_MAX = OV_MAX
-- 行車風格由檔位選擇：MAX＝brisk，其餘＝comfort；切換重建速度表，不更換路線幾何。
-- 只動建表期的剖面預算：橫向加速（過彎速）、計畫制動／滑行包絡（彎前多早開始收油）、
-- 折點帽。運行期安全包絡（state.*Safe、Driver 的 stopping／visibility 證明）不隨風格放寬，
-- 風格只會把目標壓得更低。競品 Derpy 的「順」＝約 15 km/h 過 90° 彎＋ 0.5 km/h/m 緩坡
-- （map_nav.lua:8108-8179）；舒適檔取 lat 2.5（乘客舒適上限）、計畫制動 3.0、折點 30。
-- brisk＝現行常數逐位元不變（style 省略時的預設）。前向加速仍不設天花板（檔頭定案不動）。
-- brisk coast＝天花板 3.0（2026-09-07；真值由 VehicleProfile.priors 的質量制動預算給：斷油＝
-- CarController NoControl 對 Bullet 下 brakingForce 15，減速度≈常數力／質量，RaceCar58 1041 kg 實測
-- 3.65 m/s²，2500 kg 約 1.2）。Driver 以 capSegmentLimits 把 priors 值取 min 進 segCoast，runtime
-- safeCoast 再由學習器只降不升；舊常數 1.2 對輕車＝彎前 100m 收油、直路永遠在滑行。
-- coastAssist（0928m；使用者裁定「流暢過彎包括不過度減速」）：彎前收油包絡加上 Driver 的中線減速輔助
-- （Drive.visAssistForce 追 fstate.profileSpeedKmh，上限 CURVE_ASSIST_MAX）——斷油只有 1.2–3.6 m/s²，
-- 舊包絡從彎前很遠就開始滑；加 2.5 後晚收油、到彎前再補煞。終點停車包絡不加（到站圈的停點另有取捨）；
-- 拖車同樣加（0929o；Driver 把同一減速度依質量也施給掛車，Drive.towDecel）。
-- 舒適檔放寬（1001h；使用者「每台車大多時候維持最高速或檔位最高速」；正式服 0.16.0 摘要：3 檔 4.6 小時
-- 平均 40.5 km/h、curve-coast 佔 27%）：側向 2.5→4.0、彎前收油 0.45→3.0＝天花板（真值由 priors 的斷油能力給）。
-- 舊 0.45 讓 70 km/h 的車在 R50 彎前 140m 就開始收油、一路慢慢降。
-- 1001i（使用者「自動駕駛不是親自操作，不用考慮手感」）：側向 4.0→6.0（R50 彎 51→62 km/h，積極檔 8＝72）、
-- 彎前收油同樣加中線減速輔助 2.5（晚收油）。計畫制動與折點帽不動。
-- 1002d：輔助 2.5→3.5。1002c 起 Driver 對收油段直接補足這一份（前饋），不再靠落後 2 km/h 才補得到，
-- 計畫的減速度就是實得的減速度；E2E rc47 彎前收油＋彎內循線佔速度損失約 9%。
MDADFollower.STYLES = {
    brisk = { name = "brisk", lat = LAT_ACCEL, brake = BRAKE, coast = 3.0, coastAssist = 3.5,
        turnSoft = TURN_SOFT_RAD, turnHard = TURN_HARD_RAD, turnHardMs = TURN_HARD_MS },
    comfort = { name = "comfort", lat = 6.0, brake = 3.0, coast = 3.0, coastAssist = 3.5,
        turnSoft = 25 * PI / 180, turnHard = 50 * PI / 180, turnHardMs = 30 / 3.6 },
}
-- 終點停車的中線減速輔助（1002l；使用者「快到目的地的通過時間再縮短」）：終點段收油包絡用「車輛斷油＋這一份」，
-- 合計不超過車輛煞車能力×STOP_BRAKE_RATIO（segStopBrake：configureFollower 填車輛物理值、不套風格天花板，
-- 學到的煞車照樣收緊）。1002t 起兩檔一樣（使用者：強力減速、緊急煞車都可以接受）；舊制用風格的計畫制動，
-- 舒適檔只到 3.0×1.5＝4.5。Driver 終點硬煞帳同樣改用車輛緊急帳（Drive.visibilityCaps），終點包絡才不會貼到它
-- （E2E 1002l 舒適檔第一版：合計 8.3 超過舒適計畫制動×2.5＝7.5 的硬煞帳，終點前 18m 一秒鎖輪）。
-- 中線外力不經輪胎：輕車合計約 8.3–9、2500 kg 7.2。Driver 終點硬煞帳另以 VIS_TERMINAL_TAU 計。
MDADFollower.STOP_ASSIST = 6.0
MDADFollower.STOP_BRAKE_RATIO = 1.5

-- 初始化與換檔共用；呼叫端隨後重填動力預算、重建速度表，保留承諾線與投影位置。
function MDADFollower.setStyle(profile, style)
    profile.styleName = style.name
    profile.styleLat, profile.styleBrake, profile.styleCoast =
        style.lat, style.brake, style.coast
    profile.coastAssist = style.coastAssist or 0
    profile.turnSoft, profile.turnHard, profile.turnHardMs =
        style.turnSoft, style.turnHard, style.turnHardMs
    return profile
end
MDADFollower.OV_STEP = OV_STEP
MDADFollower.TANGENT_PREVIEW_M = TANGENT_PREVIEW_M
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

-- 與 MDADDynamics.finite 同一實作（n*0==0 一次擋 NaN 與 ±Inf；shared 依字母序
-- Dynamics 先載入，載入期取值安全）。留 local alias 是熱路徑呼叫慣例。
local isFinite = MDADDynamics.finite

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

-- 車道偏置的路面餘裕（2026-09-02 s013 定罪：F350 右轉，圓角半徑已取到 band 上限、
-- 弧心線在彎中離兩臂中心線 1.7m，再疊 +1.5m 內側車道偏置＝車心出路面、車角切進
-- 路口內側圍籬）。每段記「往右／往左最多能偏幾公尺」：直段＝路寬半－halfW－邊界；
-- 弧段內側＝(帶寬－弧矢高)/cos(θ/2)（半徑吃滿 band 時＝0，整個彎沿弧心線走＝
-- 人開窄路右轉會先讓到路中間），外側＝兩臂較窄帶。θ／轉向由弧兩側直段的 segH
-- 取，所以只能在幾何相位完成後算一次；無路寬（v3 路線）或非 adaptive 不建表＝不夾。
-- 只夾常駐 laneBias（control 前視點、offset／lane／return 線的 bias 底），繞行 offL
-- 是掃掠驗過的絕對 lane，不經此表。
local function buildLaneRoom(p)
    local halfW = p.halfW
    if not isFinite(halfW) or halfW <= 0 then return end
    local n, kind, width, radius, segH = p.n, p.segKind, p.segWidth, p.filletRadius, p.segH
    local margin = MDADDynamics.ROAD_EDGE_MARGIN
    local roomR, roomL = {}, {}
    -- 只在 filletAdaptive（v4 路線）建表，begin 已把 width<1 判 badroute——寬度必為 1..64
    local function bandOf(w)
        local b = w * 0.5 - halfW - margin
        return b > 0 and b or 0
    end
    local i = 1
    while i <= n - 1 do
        local i1 = i
        if kind[i] == MDADDynamics.SEG_ARC then
            while i1 + 1 <= n - 1 and kind[i1 + 1] == MDADDynamics.SEG_ARC do i1 = i1 + 1 end
        end
        local r = radius[i]
        if i1 > i and i > 1 and i1 + 1 <= n - 1 and isFinite(r) and r > 0 then
            local bandA, bandB = bandOf(width[i - 1]), bandOf(width[i1 + 1])
            local wide, narrow = bandA, bandB
            if narrow > wide then wide, narrow = narrow, wide end
            local dh = wrapPi(segH[i1 + 1] - segH[i - 1])
            local theta = dh < 0 and -dh or dh
            local c = cos(theta * 0.5)
            local inside = 0
            if c > 1e-6 then
                -- 弧半徑貼滿 band 時（2026-09-04 起共線臂鏈可讓 r 逼近 band/(1-c)），
                -- 弧心線中點正落在帶緣；profile 是弦折線，弦中點比弧再往圓心凹一個
                -- 弦矢高（≤1m 弦：L²/8r）——不扣掉，proof 的弦檢查在每個彎都差幾毫米出帶。
                local chordSag = MDADDynamics.FILLET_SAMPLE_MAX_M
                chordSag = chordSag * chordSag / (8 * r) + 0.01
                inside = (wide - r * (1 - c) - chordSag) / c
                if inside < 0 then inside = 0 end
            end
            local rr, ll = inside, narrow
            if dh < 0 then rr, ll = narrow, inside end
            for k = i, i1 do roomR[k], roomL[k] = rr, ll end
        else
            for k = i, i1 do
                local band = bandOf(width[k])
                roomR[k], roomL[k] = band, band
            end
        end
        i = i1 + 1
    end
    -- 同餘裕 run 的端點表（clampLane 的連續化逐 run 走訪；逐段走訪在 0.25m 碎段路線會被走訪上限
    -- 截斷＝因子在某個段界突然出現／消失＝跳變，Codex lane 反例）
    local runStart, runEnd = {}, {}
    i = 1
    while i <= n - 1 do
        local e = i
        while e + 1 <= n - 1 and roomR[e + 1] == roomR[i] and roomL[e + 1] == roomL[i] do e = e + 1 end
        for k = i, e do runStart[k], runEnd[k] = i, e end
        i = e + 1
    end
    p.laneRoomR, p.laneRoomL = roomR, roomL
    p.laneRunStart, p.laneRunEnd = runStart, runEnd
end

-- 常駐 laneBias 在該段實際落點：夾進 laneRoom 再往內留 LANE_BIAS_KEEP。
-- 2026-09-06 session-055（w=4／w=5 住宅街、laneBias 1.5、車寬 1.31）：舊制夾到 room 邊
-- ＝車外緣離路緣只剩 0.4m，路邊每根桿子都擋線（55% 時間在繞行、彎道 15 km/h），
-- proof 線又正好壓在帶邊浮點翻車（26 秒 obb 18）。靠右的意義是讓對向能過，4-5m
-- 路本來就過不了兩台；留 0.6＝外緣離路緣 1m，路緣小物（r 0.35）巡航需求下不擋線。
-- laneRoomR/L 本身仍是物理餘裕（殭屍軟縫、停留 lane 直接讀表）。
-- keep（第 4 參）＝往內留多少：常駐 bias 留 LANE_BIAS_KEEP；承諾線的絕對 lane
-- （停留 offL／RETURN target，掃掠驗的是那條線本身）只夾物理餘裕、傳 0——
-- 否則 keep 會把停留線從 room 邊再往內拉 0.6，(kerb) 那道縫就被自己吃掉。
local LANE_BIAS_KEEP = 0.6
MDADFollower.LANE_BIAS_KEEP = LANE_BIAS_KEEP

-- 純追跡前視距（公尺）：control 與 Driver 的 RETURN 線尾長度共用同一條式子。
function MDADFollower.lookaheadM(speedKmh, lookScale)
    if speedKmh < 0 then speedKmh = -speedKmh end
    local look = (LOOKAHEAD_BASE + speedKmh * LOOKAHEAD_PER_KMH) * lookScale
    if look < LOOKAHEAD_MIN * lookScale then look = LOOKAHEAD_MIN * lookScale end
    if look > LOOKAHEAD_MAX * lookScale then look = LOOKAHEAD_MAX * lookScale end
    return look
end

local function clampLaneRaw(p, j, lane, keep)
    local roomR = p.laneRoomR
    local r = roomR[j] - keep
    if r < 0 then r = 0 end
    if lane > r then return r end
    local l = p.laneRoomL[j] - keep
    if l < 0 then l = 0 end
    if lane < -l then return -l end
    return lane
end
-- 逐段夾的落點在段界是台階（弧內側餘裕 0 ↔ 直段 1.0）：proof 線（buildLaneLine）在台階
-- 處是 1m 內橫跳 1m 的折點 → verifyEnvelope 格＝0（κ→∞）→ curve-coast 0 → MIN_EXEC 8
-- ＝每個內側夾限的彎出口都煞到 8 km/h（2026-09-07 session-064 t=33-36：R 9.5 彎 curveCap
-- 24.9，出弧前 `laneCurveEnvelope` 24.9→20.9→14.8→10.4→0、`mef=curve-coast`）；Driver 的
-- latDev 差分同一台階（cross-track D 項 30 m/s 尖刺）。傳 sAt（第 5 參）時沿弧長連續：
-- L(s) = v_本段 × Π_k f_k(s)，f_k = (|v_k| + (|bias| − |v_k|)·smoothstep(dist_k/BLEND)) / |bias|，
-- k 走訪 sAt 前後 LANE_BLEND_M 內的段（dist_k＝到該段區間的距離）。每個較緊的鄰段是一個 ≤1 的
-- 衰減因子：進到鄰段 k 的邊界時 v_j·(v_k/bias) 與 k 側的 v_k·(v_j/bias) 相等＝連續（Codex lane
-- 反例：階梯餘裕 1.0/0.5/0 用「min 各段以本段 v 為基底的 ramp」會在段界從 0.5 跳到 0.25）；
-- 因子在 dist=BLEND 以零斜率退到 1、兩側都 ramp 的短段取乘積而非 min＝中點無折角（C1）；
-- 永遠 ≤ 本段夾值＝不出自己的餘裕。不傳 sAt＝舊逐段語意。
-- 12m：1m 換道的 smoothstep 峰值 κ≈6·dl/L²（8m＝0.094→aLat 5 下 26 km/h，會比弧本身（κ 0.07→30）
-- 還緊；12m＝0.042→39、16m＝0.023→53）。ramp 只在 proof 線與前視目標上；車實際走的是 pure pursuit 攤平版。
-- 混合長隨橫移量放大（0928c）：常駐靠右是路寬／4 的倍數（0924f），8m 路＝2m，出入每個彎／窄段都是 2m 的
-- ramp；固定 12m 時峰值 κ≈0.083（aLat 7 下 33 km/h），車在彎後加速時追不上 ramp、落後 1m 以上＝
-- alignment 帽把 45 壓到 20–26、lane 曲率帽再壓一次（E2E rc1 十五趟 25 次）。每個因子的混合長＝
-- 12m×max(1, dl)（dl＝本 bias 與該 run 夾值之差），峰值 κ＝0.042／dl：1m 以內與舊值相同。
local LANE_BLEND_M = 12
local LANE_BLEND_WALK_MAX = 32 -- 以 run 計（同餘裕的連續段＝一個 run；混合窗內超過 32 個不同餘裕的 run 才截斷）
local function clampLane(p, j, lane, keep, sAt)
    if p.laneRoomR == nil then return lane end
    if keep == nil then keep = LANE_BIAS_KEEP end
    local v = clampLaneRaw(p, j, lane, keep)
    if sAt == nil or v == 0 then return v end
    local ss, n = p.s, p.n
    local runStart, runEnd = p.laneRunStart, p.laneRunEnd
    local aLane = lane < 0 and -lane or lane
    local aOwn = v < 0 and -v or v
    local gain = 1
    local reach = LANE_BLEND_M * (aLane > 1 and aLane or 1) -- 最大混合長（ak≥0＝dl≤aLane）
    -- 因子以「同值 run」為單位（連續弧段全是 0＝一個 run，只算最近那一段的距離）：逐段各乘一次
    -- 會把 12 段 0 的弧乘成 0.5^12（第一版 ramp 中點只剩 0.02）。走訪逐 run 跳（buildLaneRoom 的
    -- 端點表；無表＝逐段），走訪上限也以 run 計——逐段計數在 0.25m 碎段會在混合窗內截斷，因子隨
    -- 車位突然出現＝段界跳變。同餘裕不同 run 若夾值相同仍只乘一次（runAk）。
    local k, walked, runAk = (runEnd and runEnd[j] or j) + 1, 0, aOwn
    while k <= n - 1 and walked < LANE_BLEND_WALK_MAX do
        local d = ss[k] - sAt
        if d >= reach then break end
        local vk = clampLaneRaw(p, k, lane, keep)
        local ak = vk < 0 and -vk or vk
        if ak ~= runAk then
            runAk = ak
            if ak < aLane then
                local dl = aLane - ak
                local t = d / (LANE_BLEND_M * (dl > 1 and dl or 1))
                if t < 0 then t = 0 elseif t > 1 then t = 1 end
                t = t * t * (3 - 2 * t)
                gain = gain * (ak + dl * t) / aLane
            end
        end
        k = (runEnd and runEnd[k] or k) + 1
        walked = walked + 1
    end
    k, walked, runAk = (runStart and runStart[j] or j) - 1, 0, aOwn
    while k >= 1 and walked < LANE_BLEND_WALK_MAX do
        local d = sAt - ss[k + 1]
        if d >= reach then break end
        local vk = clampLaneRaw(p, k, lane, keep)
        local ak = vk < 0 and -vk or vk
        if ak ~= runAk then
            runAk = ak
            if ak < aLane then
                local dl = aLane - ak
                local t = d / (LANE_BLEND_M * (dl > 1 and dl or 1))
                if t < 0 then t = 0 elseif t > 1 then t = 1 end
                t = t * t * (3 - 2 * t)
                gain = gain * (ak + dl * t) / aLane
            end
        end
        k = (runStart and runStart[k] or k) - 1
        walked = walked + 1
    end
    return v * gain
end

-- 弧長 sAt 落在哪一段（二分；profile 未 ready／非有限＝1）。冷路徑用（Driver 的
-- 貼縫死路判定逐點查 laneRoom）；熱路徑的投影游標另走 control 的增量搜尋。
function MDADFollower.segIndexAt(profile, sAt)
    if type(profile) ~= "table" or profile.ready ~= true or not isFinite(sAt) then return 1 end
    local ss, n = profile.s, profile.n
    if type(ss) ~= "table" or not isFinite(n) or n < 2 then return 1 end
    local lo, hi = 1, n - 1
    while lo < hi do
        local sum = lo + hi
        local mid = (sum - sum % 2) / 2
        if ss[mid + 1] <= sAt then lo = mid + 1 else hi = mid end
    end
    return lo
end

-- 段 segI 上常駐 laneBias 實際能落到的值（Driver 期望線／遙測 el 與 control 同一
-- 張表）。profile 未 ready 或無表＝原值。keep＝離路緣保留（nil＝LANE_BIAS_KEEP）；會車時
-- Driver 設 state.laneKeep＝0（貼到路緣錯車，1001b），control 與期望線必須傳同一個值。
function MDADFollower.laneBiasAt(profile, bias, segI, sAt, keep)
    if type(profile) ~= "table" or profile.laneRoomR == nil
            or not isFinite(bias) or not isFinite(segI) then return bias end
    segI = segI - segI % 1
    if segI < 1 then segI = 1 elseif segI > profile.n - 1 then segI = profile.n - 1 end
    if not isFinite(sAt) then sAt = nil end
    return clampLane(profile, segI, bias, keep, sAt)
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
        elseif dth >= p.turnHard then
            if lim > p.turnHardMs then lim = p.turnHardMs end
        elseif dth >= p.turnSoft then
            local t = (dth - p.turnSoft) / (p.turnHard - p.turnSoft)
            local cap = p.maxSpeedMs + (p.turnHardMs - p.maxSpeedMs) * t
            if lim > cap then lim = cap end
        end
        if dth >= TURN_GEOM_MIN_RAD and dth <= PI * 0.5 then
            local rMin = p.rMin
            if not isFinite(rMin) or rMin < 0 then rMin = 0 end
            local geom = sqrt(aLat * rMin)
            local segKind = p.segKind
            -- 0927 正式服 capacity 路線仍有真折點；容量未建弧不等於幾何可高速通行。
            local fallback = p.filletAdaptive
                and (segKind[m - 1] == MDADDynamics.SEG_FALLBACK
                    or segKind[m] == MDADDynamics.SEG_FALLBACK)
            if not fallback then
                local lookScale = p.lookScale
                if not isFinite(lookScale) or lookScale <= 0 then lookScale = 1 end
                local inv2s = lookScale / (2 * sin(dth * 0.5))
                local b = aLat * LOOKAHEAD_PER_KMH * KMH_PER_MS * inv2s
                local c = aLat * LOOKAHEAD_BASE * inv2s
                local pp = (b + sqrt(b * b + 4 * c)) * 0.5
                if pp > geom then geom = pp end
            end
            if geom < lim then lim = geom end
        end
        if lim < MIN_SPEED_MS then lim = MIN_SPEED_MS end
        if lim > p.maxSpeedMs then lim = p.maxSpeedMs end
        p.curveV[m] = lim
        if p.v[m] > lim then p.v[m] = lim end
    end
end

-- 地圖資料接點的微反折（2026-09-28 正式服 (5180,11145)：兩條道路折線端點錯位 0.7m、接續順序倒置，
-- 路線成了「前進→倒退 0.7m→前進」；0927 起投影不跨到車頭背向的相鄰段，投影釘死在反折點，
-- 車開過頭後前視點落到車後＝原地調頭，掉頭回來又跨不過＝兩名玩家同點繞圈調頭 16～204 次）。
-- 頂點折返超過 150° 且相鄰一臂短於 SPIKE_M＝開不出來的資料殘點：刪頂點、兩段合併（段屬性取
-- 較長那臂）。兩臂都長的真調頭不動。拖車改寫線撤點後殘留的折返（0.13.1 fold 前的路口 jog）同樣清掉。
-- 微錯位（0928n E2E rc16 0015，(12300,1655)→(12300,1656)）：兩段長路之間夾一段短橫移（左 90°＋右 90°
-- 的 Z 字），進出方向幾乎平行（<JOG_TURN），剖面把它當兩個真直角＝車開過頭、判原地調頭、繞圈 4 次交還。
-- 整段短橫移收成一個中點（橫移攤在兩臂上，車照直線開）；真轉角（進出方向差大）與太寬的橫移不動。
-- 橫移上限（0929b）：42.21 Flaherty Road 改線後路線在 (8106,11204.5)→(8104,11204.5) 多出 2.0m 的 Z 字
-- （接點經 15m 寬的橫街），舊門檻「合計 <2m」差一點收不到＝E2E rc23 2004 在該點投影卡住、原地調頭 4 次交還；
-- (2501,14011) 的 3.25m 錯位（8m→6m 路）投影在兩臂間來回跳 3.6m、繞行中擦撞（rc22 0023）。短段與合計放到
-- JOG_MAX_M，橫移量另以路寬把關：中點線離兩臂中心 lat/2，兩臂較窄者要容得下（lat ≤ 寬 − JOG_CLEAR_M，
-- 半寬 0.9 的車留 0.3）；兩臂至少 JOG_ARM_RATIO×lat 長（中點線對臂的折角 ≤ 7°）。無路寬資料照舊 <SPIKE_M。
-- JOG_MAX_M 是嚴格上界（l² ≥ 上界² 即當臂）：nav 座標在 0.5 格上，整 4.0m 的錯位（2nd St↔Oak St (12106→12110,6900)，
-- 兩臂 8m）在上界 4 時剛好被排除＝E2E rc53 0002 兩個 90° fallback 頂點留著、投影釘在來向臂、繞行中原地調頭 4 次交還
-- （1002m）。4.5＝收 ≤4.0、不收 4.5 以上；物理把關仍是路寬與臂長兩道閘。
-- 無變更回原表（Trailer.shape 以 identity 快取）；有變更回淺拷貝，despiked＝刪除點數。冷路徑。
MDADFollower.SPIKE_M = 2
MDADFollower.JOG_MAX_M = 4.5
local JOG_CLEAR_M = 2.4
local JOG_ARM_RATIO = 4
local JOG_TURN_COS2 = 0.75 -- cos²30°：進出方向夾角 <30° 才算橫移
-- 短段本身偏離進入方向 >10° 才算橫移（1002t；舊制與進出同用 30°）：街道接點常有 1m 內 0.5m 的錯位
-- （E2E 851 條路線有 54 處偏 10–30°，例 Salt River Road 西口 (12877.5,6900.5) 1.1m 偏 26.6°），兩個 ≥20° 折點
-- 塞不下圓角＝fallback 頂點，整條 2km 路線最慢 17.9 km/h 就在這裡；收成中點後最慢 49.7（在真彎道上）。
-- 共線（<10°）仍不動：沒有折點、不限速。
local JOG_DEV_COS2 = 0.9698
function MDADFollower.despikeRoute(route)
    local pts = type(route) == "table" and route.pts or nil
    if type(pts) ~= "table" or #pts < 6 or #pts % 2 ~= 0 then return route end
    for k = 1, #pts do
        if not isFinite(pts[k]) then return route end
    end
    local lim2 = MDADFollower.SPIKE_M * MDADFollower.SPIKE_M
    -- 頂點 i（前後各一點）是不是微反折；另回兩臂長平方供合併取屬性
    local function spikeAt(p, i)
        local ux, uy = p[i * 2 - 1] - p[i * 2 - 3], p[i * 2] - p[i * 2 - 2]
        local vx, vy = p[i * 2 + 1] - p[i * 2 - 1], p[i * 2 + 2] - p[i * 2]
        local lu, lv = ux * ux + uy * uy, vx * vx + vy * vy
        if lu < 1e-12 or lv < 1e-12 or (lu >= lim2 and lv >= lim2) then return false, lu, lv end
        local dot = ux * vx + uy * vy
        return dot < 0 and dot * dot > 0.75 * lu * lv, lu, lv -- 0.75＝cos²150°
    end
    -- 從頂點 i 起的短橫移：i..j 之間每段都短、合計 <JOG_MAX_M，進入段 (i-1→i) 與離開段 (j→j+1) 都長、方向
    -- 幾乎平行，短段偏離進入方向，橫移量在兩臂路寬內（w＝段寬表，可為 nil）。回 j（不成立回 nil）。
    local jogLim2 = MDADFollower.JOG_MAX_M * MDADFollower.JOG_MAX_M
    local function jogAt(p, np, i, w)
        if i < 2 or i >= np then return nil end
        local ax, ay = p[i * 2 - 1] - p[i * 2 - 3], p[i * 2] - p[i * 2 - 2]
        local la = ax * ax + ay * ay
        if la < lim2 then return nil end
        local run, j = 0, i
        while j < np do
            local dx, dy = p[j * 2 + 1] - p[j * 2 - 1], p[j * 2 + 2] - p[j * 2]
            local l = sqrt(dx * dx + dy * dy)
            if l * l >= jogLim2 then break end
            run = run + l
            if run * run >= jogLim2 then return nil end
            j = j + 1
        end
        if j == i or j >= np then return nil end
        local bx, by = p[j * 2 + 1] - p[j * 2 - 1], p[j * 2 + 2] - p[j * 2]
        local lb = bx * bx + by * by
        local ab = ax * bx + ay * by
        if ab <= 0 or ab * ab < JOG_TURN_COS2 * la * lb then return nil end
        local rx, ry = p[j * 2 - 1] - p[i * 2 - 1], p[j * 2] - p[i * 2]
        local lr = rx * rx + ry * ry
        if lr < 1e-12 then return nil end
        local ar = ax * rx + ay * ry
        if ar > 0 and ar * ar >= JOG_DEV_COS2 * la * lr then return nil end
        local lat = (ax * ry - ay * rx) / sqrt(la)
        if lat < 0 then lat = -lat end
        local armMin = JOG_ARM_RATIO * lat
        if la < armMin * armMin or lb < armMin * armMin then return nil end
        local wIn, wOut = w and w[i - 1], w and w[j]
        if isFinite(wIn) and isFinite(wOut) then
            if lat > (wIn < wOut and wIn or wOut) - JOG_CLEAR_M then return nil end
        elseif run * run >= lim2 then
            return nil
        end
        return j, lat
    end
    local n = #pts / 2
    local sw, ss = route.segWidth, route.segSurface
    if type(sw) ~= "table" then sw = nil end
    if type(ss) ~= "table" then ss = nil end
    local found = false
    for i = 2, n - 1 do
        if spikeAt(pts, i) or jogAt(pts, n, i, sw) then found = true break end
    end
    if not found then return route end
    local P, W, S = {}, sw and {} or nil, ss and {} or nil
    local np, removed = 0, 0
    for i = 1, n do
        np = np + 1
        P[np * 2 - 1], P[np * 2] = pts[i * 2 - 1], pts[i * 2]
        if np >= 2 then
            if W then W[np - 1] = sw[i - 1] end
            if S then S[np - 1] = ss[i - 1] end
        end
        -- 新點進來後回頭看上一個頂點；刪掉後新的上一個頂點可能又成反折（連續鋸齒）
        while np >= 3 do
            local spike, lu, lv = spikeAt(P, np - 1)
            if not spike then break end
            if lv > lu then
                if W then W[np - 2] = W[np - 1] end
                if S then S[np - 2] = S[np - 1] end
            end
            P[np * 2 - 3], P[np * 2 - 2] = P[np * 2 - 1], P[np * 2]
            P[np * 2 - 1], P[np * 2] = nil, nil
            if W then W[np - 1] = nil end
            if S then S[np - 1] = nil end
            np = np - 1
            removed = removed + 1
        end
    end
    -- 第二趟：短橫移收成中點（段屬性：進入段保留原值、離開段取原離開段）。中點兩側各在臂上 JOG_ARM_RATIO×lat 處
    -- 加錨點，斜線只在錨點與中點之間（折角 ≤7°），這兩段的段寬扣掉 lat（1002t：斜線在中點離兩臂中心 lat/2，照原寬
    -- 靠右＝車心貼到臂的路緣；8m 路 4m 錯位、靠右 2m 時車身出路緣約 0.9m）。扣過的寬度 ≥ JOG_CLEAR_M（jogAt 的
    -- 路寬閘），斜線兩側各 (w−lat)/2 的帶仍在兩臂的真路面內；錨點外的臂照原線原寬，靠右照舊。
    local Q, QW, QS, nq = {}, W and {} or nil, S and {} or nil, 0
    local function push(x, y, w, s) -- w／s＝從上一點到這點那段的屬性
        nq = nq + 1
        Q[nq * 2 - 1], Q[nq * 2] = x, y
        if nq >= 2 then
            if QW then QW[nq - 1] = w end
            if QS then QS[nq - 1] = s end
        end
    end
    push(P[1], P[2])
    local narrowNext, narrowW = false, nil
    local i = 2
    while i <= np do
        local j, lat = nil, nil
        if i < np then j, lat = jogAt(P, np, i, W) end
        if j then
            local wIn, wOut = W and W[i - 1], W and W[j]
            local sIn, sOut = S and S[i - 1], S and S[j]
            local ix, iy, jx, jy = P[i * 2 - 1], P[i * 2], P[j * 2 - 1], P[j * 2]
            local arm = JOG_ARM_RATIO * lat
            local ax, ay = ix - P[i * 2 - 3], iy - P[i * 2 - 2]
            local la = sqrt(ax * ax + ay * ay)
            if la > arm + 0.5 then push(ix - ax / la * arm, iy - ay / la * arm, wIn, sIn) end
            push((ix + jx) * 0.5, (iy + jy) * 0.5, wIn and wIn - lat, sIn)
            local bx, by = P[j * 2 + 1] - jx, P[j * 2 + 2] - jy
            local lb = sqrt(bx * bx + by * by)
            if lb > arm + 0.5 then
                push(jx + bx / lb * arm, jy + by / lb * arm, wOut and wOut - lat, sOut)
            else
                narrowNext, narrowW = true, wOut and wOut - lat -- 中點直連下一點：那段就是斜線
            end
            removed = removed + (j - i)
            i = j + 1
        else
            local w = W and W[i - 1]
            if narrowNext then w, narrowNext = narrowW, false end
            push(P[i * 2 - 1], P[i * 2], w, S and S[i - 1])
            i = i + 1
        end
    end
    P, W, S = Q, QW, QS
    local out = {}
    for k, v in pairs(route) do out[k] = v end
    out.pts, out.despiked = P, removed
    if W then out.segWidth = W end
    if S then out.segSurface = S end
    return out
end

-- 驗 route 並配置 profile。除冷路徑的 despikeRoute 外，**唯一**會建 table 的入口。
-- 拒絕條件（一律回 nil, "badroute"，呼叫端不必分辨細節，只需要「這條路不能跟」）：
--   route／route.pts 不是 table、pts 長度非偶數、點數 < 2、任一座標非有限數、
--   所有點重合（路徑長 0，投影／曲率／前視全部沒有意義）。
-- 點數 1（#pts == 2）是 nav 真的會回的情況（A* 起錨後續節點全與前一點重合），
-- 對應 production 的 `if np < 2 then` 早退，不是假想輸入。
function MDADFollower.begin(route, maxSpeed, navVersion, vehicleProfile, style)
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
    local buildPts, buildSurface, buildWidth, rawSourceMap = {}, {}, {}, {}
    do
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
    if filletAdaptive then
        n, filletN, filletFallbackN, filletBandValid, filletReason =
            MDADDynamics.buildFilletPath(
                buildPts, buildSurface, buildWidth, vehicleProfile.halfW, vehicleProfile.rMin,
                pathPts, segSurface, segWidth, segKind, segSourceA, segSourceB, filletRadius)
    end
    if n >= 2 then
        for i = 1, n - 1 do
            segSourceA[i] = rawSourceMap[segSourceA[i]] or segSourceA[i]
            segSourceB[i] = rawSourceMap[segSourceB[i]] or segSourceB[i]
        end
    end
    if n < 2 then
        -- 未啟用 adaptive fillet 時保留原折線；source-map 直對 raw 段，band 語意不變。
        n, filletN, filletBandValid = buildN, 0, navVersion >= 4
        for i = 1, #buildPts do pathPts[i] = buildPts[i] end
        for i = 1, buildN - 1 do
            segSurface[i], segWidth[i] = buildSurface[i], buildWidth[i]
            segSourceA[i] = rawSourceMap[i] or i
            segSourceB[i], filletRadius[i] = segSourceA[i], 0
            segKind[i] = filletReason and MDADDynamics.SEG_FALLBACK
                or MDADDynamics.SEG_LINE
        end
    end

    if type(style) ~= "table" or not isFinite(style.lat) then style = MDADFollower.STYLES.brisk end
    -- segStopCoast：終點停車包絡用的斷油減速度（VehicleProfile.configureFollower 填車輛物理值，
    -- 不套風格天花板）。2026-09-24 使用者「到終點前不要過早減速」：舒適檔 coast 0.45 讓 45 km/h
    -- 的車在終點前 170m 就開始收油；終點只是停車，不是彎道，照車輛真實斷油能力收即可。
    local segAccel, segBrake, segCoast, segLat, segStopCoast, segStopBrake = {}, {}, {}, {}, {}, {}
    for i = 1, n - 1 do
        segAccel[i], segBrake[i], segCoast[i], segLat[i] =
            ACCEL_NOMINAL, style.brake, style.coast, style.lat
        segStopCoast[i], segStopBrake[i] = style.coast, BRAKE
    end
    local rangeBlockCount = ((n - 2) - (n - 2) % RANGE_BLOCK) / RANGE_BLOCK + 1 -- kahlua-mod-ok: n >= 2
    local rangeBase = 1
    while rangeBase < rangeBlockCount do rangeBase = rangeBase * 2 end

    return MDADFollower.setStyle({
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
        filletReason = filletReason,
        filletBandValid = filletBandValid == true,
        wheelbase = filletAdaptive and vehicleProfile.wheelbase or 0,
        rMin = filletAdaptive and vehicleProfile.rMin or HAIRPIN_RMIN_DEFAULT,
        halfW = filletAdaptive and vehicleProfile.halfW or 0,
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
        filletRadius = filletRadius,
        segAccel = segAccel,
        segBrake = segBrake,
        segLat = segLat,
        segCoast = segCoast,
        segStopCoast = segStopCoast,
        segStopBrake = segStopBrake, -- 終點包絡上限用的車輛煞車能力（不套風格；configureFollower 填）
        coastRate = {}, -- 建表時每段實際用的滑行減速度（終點段＝segStopCoast，其餘＝segCoast＋coastAssist）；control 段內插值同源
        coastAssistAt = {}, -- 每段收油包絡含的中線減速輔助（終點段 0）；control 的線上滑行夾限要同樣加回
        coastFromEnd = false,
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
    }, style)
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
                -- 路線終點是停車點，滑行包絡也要收到 0（0924a）：舊制只有制動包絡收到 0，
                -- 但 Driver 只能斷油滑行、沒有比例煞車，終點前唯一的減速手段變成可視上限
                -- 越線的一秒鎖輪 forceBrake——本機＋玩家 47 趟抵達有 29 趟在終點前 7–36m、
                -- 18–64 km/h 被鎖輪（0915 消防車 13m／36.5 km/h，sk 0.07）。停點不能在終點：
                -- 輕車在 6m 仍越過緊急可視紅線（離線三車型模擬 +4.7 km/h）；也不能正好在到站圈
                -- 邊界：繞行爬行等不吃最低執行速度的意圖會把目標收到 0，車蹭到 5.0m 才勉強算到站
                -- （0924a PZ 實測 F350 最後 2m 花 4 秒、0.1 km/h）。圈內 1m：邊界處仍有正速度，
                -- 離線三車型距紅線 2.7–5.0 km/h。
                profile.coastStopS = profile.length - COAST_STOP_M
                coastV[n] = 0
                profile.coastFromEnd = true -- 從終點倒推、還沒被彎道帽接手的段用停車減速度
                buildLaneRoom(profile)
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
                -- 彎前與終點收油都加中線減速輔助。終點段（0924a）原本只用車輛真實斷油值：
                -- 當時 Driver 沒有比例減速，計畫的減速度一定要做得到；1001a 起不鎖輪的中線減速輔助一路補到停，
                -- 1002i 起終點同樣照「斷油＋輔助」收（rc49／rc50 跟線慢於上限的時間裡 38% 在終點前 120m 內）；
                -- 1002l 起終點段的輔助是 STOP_ASSIST（彎前仍是風格的 coastAssist），合計不超過計畫制動×STOP_BRAKE_RATIO。
                local assist = profile.coastAssist or 0
                if profile.coastFromEnd and profile.segStopCoast then
                    coast = profile.segStopCoast[i] or coast
                    local stop = coast + MDADFollower.STOP_ASSIST
                    local lim = ((profile.segStopBrake and profile.segStopBrake[i]) or profile.segBrake[i] or BRAKE)
                        * MDADFollower.STOP_BRAKE_RATIO
                    if stop > lim then stop = lim end
                    assist = stop > coast and stop - coast or 0
                end
                coast = coast + assist
                if profile.coastAssistAt then profile.coastAssistAt[i] = assist end
                local reach = profile.s[i + 1]
                if reach > profile.coastStopS then reach = profile.coastStopS end
                reach = reach - profile.s[i]
                if reach < 0 then reach = 0 end
                local lim = sqrt(coastV[i + 1] * coastV[i + 1] + 2 * coast * reach)
                local curve = profile.curveV[i] or profile.maxSpeedMs
                if profile.coastRate then profile.coastRate[i] = coast end
                if curve < lim then
                    coastV[i] = curve
                    profile.coastFromEnd = false -- 彎道／速限接手：再往前是一般（風格）收油包絡
                else
                    coastV[i] = lim
                end
                profile.cursor, ops = i - 1, ops + 1
            end
        elseif phase == "brake" then
            if i < 1 then
                profile.phase, profile.cursor = "merge", 1
            else
                -- 制動包絡沒有彎道帽、只管終點煞停：不比同段收油包絡（斷油＋輔助）更早綁（1002l）。終點停車由
                -- Driver 的中線外力執行、不經輪胎，學到的低鎖輪煞車不再限它（Driver 終點硬煞帳另吃學到的煞車）；
                -- 煞車 0 仍是 fail-safe 全線停車。
                local brake = profile.segBrake[i] or BRAKE
                local rate = profile.coastRate and profile.coastRate[i]
                if rate and brake > 0 and rate > brake then brake = rate end
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
            -- 本相位只建 range block minima（brake/lat/coast）。前向加速
            -- forward pass 已拆除（理由見檔頭「前向加速」註解）：v[i] 只由
            -- coast／brake 反向包絡與曲率決定，直路段＝maxSpeed 直給。
            if i > n - 1 then
                profile.rangeReady = false
                profile.phase, profile.cursor = "range-pad", profile.rangeBlockCount + 1
            else
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
-- ov 折線在弧長 q 的段索引與段內比例（等距 OV_STEP，末段可短）；呼叫端保證
-- q ∈ [ovS0, ovEndS]、ovN ≥ 2。模組層函式：control 每幀呼叫，不得配置 closure。
local function ovIndexAt(ovS0, ovN, ovEndS, q)
    local lastStart = ovS0 + (ovN - 2) * OV_STEP
    if q >= lastStart then
        local lastSpan = ovEndS - lastStart
        if lastSpan > 0 then return ovN - 1, (q - lastStart) / lastSpan end
        return ovN - 1, 1
    end
    local fi = (q - ovS0) / OV_STEP + 1
    local i0 = fi - fi % 1
    return i0, fi - i0
end

-- 弧段前饋：回傳要加進 steer 的量（0＝不加）。arcK＝前視窗內第一個弧段（control 的 onArc 同源）。
-- 弧的起點 k：進弧前 LEAD 秒線性爬升、出弧前同一個 LEAD 收尾（0908a 試收尾只差 0.02-0.05m，當時弦角預轉
-- 還在、切內另有來源，0928o 拿掉預轉後收尾才顯出效果）。切線預視本身在弧上就有 KP·κ·PREVIEW 的隱含前饋
-- （誤差＝車前 1.5m 切線與車頭夾角＝κ·1.5），顯式前饋扣掉它，否則兩份相加＝120% 切內（離線閉環 KPS 0.1
-- 實得 in 0.70）。
-- 曲率取車實際要走的線（0929a）：追車道線切線時（state.laneTangent），中心弧 1/R 換成偏移 l 後的 1/(R∓l)，
-- 彎前後車道收窄／放回的 clampLane ramp 本身也有曲率 l''（smoothstep 峰值 6·dl/L²，與 R20 弧同量級）。
-- 只給 1/R 時，窄路內側車道彎中被推著照中心弧轉＝留在內側（車道已往中線收）、出彎車道放回時又少轉＝外漂
-- （離線 6m 路 45 km/h 35°、慢 plant G 0.7／τ 0.35：0.86m→0.56；重播數字見 CURVE_FF_FRAC）；外側車道走 R+l，
-- 照 1/R 前饋＝轉過頭切內。l'' 以 LANE_FF_STEP_M 中心差分取在 lead 點；車道斜率切線同樣含隱含前饋
-- KP·l''·(1.5·PREVIEW + v·SLOPE_LEAD)（斜率取在 q+v·SLOPE_LEAD 起 1.5m 的中點），一併扣掉。
-- 追承諾線（ov）切線時那條線自己的側移已在切線裡，不另算車道項。
-- 彎內偏差退讓（1004b；正式服 0.18.2 Qoo clip-12／14／17、Loni clip-31、lista clip-02：半聯結與 F250 27–44 km/h
-- 內切 0.8–1.4m 擦內側樹）：車已在期望線「前饋推的那一側」超過 FF_HI.inM，前饋按超出量線性退讓、再多 inSpanM 退到 0
-- （2026-09-08 裁定：前饋寧可欠轉、由位置環補）。前饋是開環：yawGain 是逐幀 yaw/steer 比值，側推的 yaw 響應
-- 對 |steer| 是凸的（半聯結片段 |steer|<0.5 約 0.15–0.2、0.75–1 約 0.6–0.8；推論是 Bullet 輪側向摩擦的門檻），
-- 平常小修正學到的低增益讓急彎前饋過頭 2–3 倍（Qoo 學到 0.19、彎上實測 0.65–0.73）；車道 ramp 前段的小 steer
-- 又幾乎轉不動車頭，進弧時已偏內 0.5–0.85m。兩種誤差都是「前饋在車已偏內時照推」，cross-track 0.77·2/v 在
-- 40 km/h 只有 0.14/m 拉不回。只退讓、不反推：外側偏差照舊由回授處理，前饋不加碼。
local LANE_FF_STEP_M = 2
local function arcFeedForward(profile, state, arcK, bestI, sNow, aspeed, tangentOn, yawGain, ovDen,
        latSigned, lineLat)
    local kap = profile.kappa
    state.ffFull = false
    if not kap or arcK == nil or aspeed <= 0.5 then return 0 end
    local s, n, segKindW, segH = profile.s, profile.n, profile.segKind, profile.segH
    local v = aspeed * MS_PER_KMH
    local lead = v * CURVE_FF_LEAD_S
    local ramp = 1
    if arcK > bestI then
        local dist = s[arcK] - sNow
        if dist > 0 then ramp = lead > 0 and (1 - dist / lead) or 0 end
    end
    local k = arcK
    -- 弧的真曲率＝1/圓角半徑（kap[k] 是三點曲率：弧的第一個 chord 與前面的直臂
    -- 算出來只有 1/R 的百分之一，Codex lane 2026-09-08 抓的；即時弧帽同樣避開它）
    local kk = 0
    local fr = profile.filletRadius
    local r = fr and fr[k]
    if isFinite(r) and r > 0 then
        kk = 1 / r
    else
        kk = kap[k] or 0
        local k2 = kap[k + 1] or 0
        if k2 > kk then kk = k2 end
    end
    -- 轉向方向＝同一弧內相鄰 chord 的轉角（弧內 chord 間永遠同號）：k−1 也是弧
    -- 就用 prev，否則（第一個 chord）用 next。只看 next 會在最後一個 chord 吃到
    -- 出口切線殘差反號（近共線出口 −0.006 vs chord 間 0.035）；看「量級較大者」
    -- 會在第一個 chord 吃到入臂（微彎被視為共線臂吞點）的反號差——Codex lane
    -- 2026-09-08 兩個反例。
    local dth = 0
    if k >= 2 and segKindW[k - 1] == MDADDynamics.SEG_ARC then
        dth = wrapPi(segH[k] - segH[k - 1])
    elseif k + 1 <= n - 1 then
        dth = wrapPi(segH[k + 1] - segH[k])
    end
    if dth < 0 then kk = -kk end
    -- 出弧前同一個 LEAD 收尾（進弧有 lead 爬升、出弧原本一刀歸零）：車在弧上且同向弧段在 lead 內
    -- 結束 → 前饋線性收到 0，yaw 率在出口前就降下來。一刀歸零時 yaw 滯後讓車頭出口後多轉
    -- 0.1 rad、切進彎內 0.5m（0928o 離線閉環 G 1.0／τ 0.25；E2E rc16–rc18 出彎後 2 秒內切內
    -- p90 0.7–0.8m）。反向相鄰弧（S 彎）以轉向變號當收尾點。
    -- 弧間短直段（1002u）：小折角連續建弧時相鄰弧各吃共用段 45%，中間留 10% 直段；直段短於 lead 時 yaw
    -- 收不掉也建不回來（一階延遲），照收尾＝每個子弧之間一個前饋鋸齒（實機 rc45arc 1006 sff 在 −0.22／−0.06／
    -- −0.13 間跳）。收尾越過短直段接下一個同向弧。直段上下一弧的爬升照舊（1−距離/lead）：試過直段上保持 1，
    -- 直段接近 lead 長時多轉（離線同向 18°×6 每 20m、50 km/h 外漂 0.23→0.45），撤。
    -- 離線閉環（同向小弧 12–25°、50／70 km/h、plant G 0.6–1.0／τ 0.25–0.5）外漂最大值多數減半（G0.6 70 km/h
    -- 15°×8 每 15m：2.20→1.08）；直段接近 lead 的同向 18° 每 20m 略增（0.47→0.60），門檻減半反而重車更差，留 lead。
    if ramp > 0 and k == bestI and lead > 0 then
        local e = k
        while e < n - 1 and s[e + 1] < sNow + lead do
            local nx = e + 1
            if segKindW[nx] ~= MDADDynamics.SEG_ARC then
                while nx < n - 1 and segKindW[nx] ~= MDADDynamics.SEG_ARC and s[nx + 1] - s[e + 1] < lead do
                    nx = nx + 1
                end
                if segKindW[nx] ~= MDADDynamics.SEG_ARC or s[nx] - s[e + 1] >= lead then break end
            end
            local dn = wrapPi(segH[nx] - segH[nx - 1])
            if (nx > e + 1 and dn * dth <= 0) or (dn * dth < 0 and (dn > 1e-3 or dn < -1e-3)) then break end
            e = nx
        end
        local endS = s[e + 1]
        if endS < sNow + lead then ramp = ramp * (endS - sNow) / lead end
    end
    -- 前饋整份在推（不在爬升／收尾）：高速增益只學這種幀（FF_HI）
    state.ffFull = ramp >= 1 and k == bestI
    -- 高速：學到高速增益後才補足（FF_HI）
    local frac, g = CURVE_FF_FRAC, yawGain
    local gHi = state.yawGainHi
    if aspeed > FF_HI.fromKmh and isFinite(gHi) and (state.hiLearnT or 0) >= FF_HI.learnS then
        local t = (aspeed - FF_HI.fromKmh) / (FF_HI.fullKmh - FF_HI.fromKmh)
        if t > 1 then t = 1 end
        frac = CURVE_FF_FRAC + (FF_HI.frac - CURVE_FF_FRAC) * t
        g = yawGain + (gHi - yawGain) * t
    end
    local arcScale, ffLane = 1, 0
    local rb = state.laneBias
    if state.laneTangent == true and isFinite(rb) and rb ~= 0 then
        local h, sL, i = LANE_FF_STEP_M, sNow + lead, bestI
        while i < n - 1 and s[i + 1] < sL - h do i = i + 1 end
        local l0 = clampLane(profile, i, rb, state.laneKeep, sL - h)
        while i < n - 1 and s[i + 1] < sL do i = i + 1 end
        local l1 = clampLane(profile, i, rb, state.laneKeep, sL)
        while i < n - 1 and s[i + 1] < sL + h do i = i + 1 end
        local lk = (clampLane(profile, i, rb, state.laneKeep, sL + h) - 2 * l1 + l0) / (h * h)
        local den = 1 - l1 * kk -- lane>0 在 CCW 法向側：CCW 彎（kk>0）內側＝半徑 R−l
        if den < 0.5 then den = 0.5 end
        arcScale = 1 / den
        ffLane = frac * v * lk / g - KP * lk * (1.5 * TANGENT_PREVIEW_M + v * TANGENT_SLOPE_LEAD_S)
        if ffLane * lk < 0 then ffLane = 0 end
        if ffLane > CURVE_FF_MAX then ffLane = CURVE_FF_MAX
        elseif ffLane < -CURVE_FF_MAX then ffLane = -CURVE_FF_MAX end
    end
    local ff = 0
    if ramp > 0 then
        ff = frac * v * kk * arcScale / g
        if tangentOn then ff = ff - KP * kk * TANGENT_PREVIEW_M end
        if ff * kk < 0 then ff = 0 end
        ff = ff * ramp
        -- 承諾線在弧外側（1002f）：線的曲率 κ/(1−l·κ)、預視角同比例縮小，前饋整份乘同一個比例
        if ovDen ~= nil and not state.laneTangent then ff = ff / ovDen end
        if ff > CURVE_FF_MAX then ff = CURVE_FF_MAX
        elseif ff < -CURVE_FF_MAX then ff = -CURVE_FF_MAX end
    end
    ff = ff + ffLane
    -- 彎內偏差退讓（見檔頭）：期望線＝cross-track 追的那條（承諾線 lineLat，否則常駐車道連續落點）
    if ff ~= 0 and isFinite(latSigned) then
        local lane = lineLat
        if lane == nil then lane = clampLane(profile, bestI, isFinite(rb) and rb or 0, state.laneKeep, sNow) end
        local over = ((latSigned - lane) * (ff > 0 and 1 or -1) - FF_HI.inM) / FF_HI.inSpanM
        if over >= 1 then return 0 end
        if over > 0 then ff = ff * (1 - over) end
    end
    return ff
end

-- 弧段即時帽（m/s）與折算後 κ：中心線 κ（j 與 j+1 取大）；行駛線往彎內側偏 latHere 時半徑＝R−lt
-- （κ/(1−lt·κ)，承諾線在保持段沿路平移時尤其如此；外側偏移半徑變大，不放寬）。右轉（y 向南的世界
-- dθ>0）內側＝右＝+lane。再取轉向域（adaptive：建表期只對中心線 κ 算過一次，內側折算後的 κ 這台車
-- 在該速度轉不轉得出來）——轉不出來（0）依「解析公式只壓速不否決」壓到曲率地板 MIN_SPEED，與建表期
-- 頂點帽同一下限（2026-09-07 實機 T 字路口：沒有地板時給 9.1 km/h 爬 20m）。κ≤0 或 runtimeLat 無效回 (nil, κ)。
-- control 的當下弧段與前看（arcLookaheadMs）共用這一份。
local function arcRuntimeCap(profile, j, latHere, runtimeLat)
    local kappa = profile.kappa[j] or 0
    local nextKappa = profile.kappa[j + 1] or 0
    if nextKappa > kappa then kappa = nextKappa end
    if kappa <= 0 then return nil, 0 end
    local dth = 0
    if j + 1 <= profile.n - 1 then
        dth = wrapPi(profile.segH[j + 1] - profile.segH[j])
    elseif j >= 2 then
        dth = wrapPi(profile.segH[j] - profile.segH[j - 1])
    end
    local inner = dth > 0 and latHere or -latHere
    if inner > 0 then
        local den = 1 - inner * kappa
        if den < 0.25 then den = 0.25 end
        kappa = kappa / den
    end
    if not isFinite(runtimeLat) or runtimeLat < 0 then return nil, kappa end
    local cap = sqrt(runtimeLat / kappa)
    if profile.filletAdaptive then
        local steer = MDADDynamics.steeringSpeedCapKmh(kappa, profile.wheelbase,
            profile.delta0Safe, profile.deltaVSafe, profile.vehicleMaxSpeed) * MS_PER_KMH
        if steer < cap then cap = steer end
    end
    if cap < MIN_SPEED_MS then cap = MIN_SPEED_MS end
    return cap, kappa
end

-- 非弧折點（段 ji→ji+1 的頂點）的放行距離 rel（rMin·tan(θ/2) 夾 HAIRPIN_APEX_MIN..MAX）與常駐車道的折角位移。
-- 髮夾（>90°）車走的是兩臂各偏 b 的車道線；兩線交點（車道折點）在入彎臂上是頂點前 b·tan(θ/2)、出彎臂上是
-- 頂點後同樣距離（143°、b 1.69 → ±5.05m）——中心線弧長這 2·b·tan(θ/2) 在車道上是同一點。鉗點／放行距離／
-- 出彎前視／跨臂交接都量到車道折點，彎內側的車就和 b＝0 的車走同一套幾何。量中心線時（舊制）彎內側車在
-- 車道折點前 0.95m 才放行、前視越過頂點又白拿 10m：33 km/h 放行 err 130–138° 誤進 ROTATE（E2E hairpin-sp
-- 1002r 2/5）；放行壓到 12 km/h 則目標先落在車道折點前的出彎臂延長線（−13°、朝外），2m 內掃到 154°（1002j）。
-- 只處理彎內側（shift<0）；外側車道折點在頂點後，放行時機照舊。承諾線／繞行剖面作用時不估（照舊）。
-- ≤90°（handover＝true 才估）用在跨臂交接與放行後的出彎前視：彎內側的車離中心線頂點永遠 ≥b·√2，舊交接圓（rel）
-- 進不去＝投影釘在入彎臂、前視點不前進、車繞著它轉（正式服 0.17.0 clip-09：4.3m 首段接 90°、常駐 2.5）；前視
-- 不補車道弧長＝目標落在車旁／車後誤進 ROTATE（正式服 1002y：2.94m 首段接 90°）。≤90° 的鉗點／放行仍量中心線
-- （提前 b 會把大車窄路的內切加深 0.1–0.4m，未經 campaign 證實前不動）——呼叫端只取 shift 補前視。
-- 回 rel, shift（入彎臂、負＝提前）, cornerOut（出彎臂上車道折點離頂點的弧長）, bIn（入彎臂車道偏移）。
local function kinkRelease(profile, state, ji, dth, handover)
    local rel = profile.rMin * tan(dth * 0.5)
    if rel < HAIRPIN_APEX_MIN then rel = HAIRPIN_APEX_MIN elseif rel > HAIRPIN_APEX_MAX then rel = HAIRPIN_APEX_MAX end
    local b = state.laneBias
    if dth < MDADDynamics.FILLET_MIN_RAD or (dth <= HAIRPIN_RAD and not handover)
            or not isFinite(b) or b == 0 or (state.ovN or 0) >= 2 or state.offL ~= nil then
        return rel, 0, 0
    end
    local sK, segH = profile.s[ji + 1], profile.segH
    local bIn = clampLane(profile, ji, b, state.laneKeep, sK)
    local bOut = clampLane(profile, ji + 1, b, state.laneKeep, sK)
    local th = wrapPi(segH[ji + 1] - segH[ji])
    local sn, cs = sin(th), cos(th)
    local shift = (bIn * cs - bOut) / sn
    if not (shift < 0) then return rel, 0, 0 end
    return rel, shift, (bIn - bOut * cs) / sn, bIn
end

-- 跨臂交接（投影從入彎臂 idx 跳到出彎臂 idx+1）：車在交接圓內（半徑 rel）且車頭朝出臂的前半平面。
-- 髮夾與 ≤90° 折點的彎內側都量到車道折點（kinkRelease handover＝true；鉗制／放行同一個基準）——中心線頂點
-- 對彎內側的車永遠 ≥b·√2，交接圓進不去＝投影釘在入彎臂（正式服 0.17.0 clip-09）。獨立成函式是為了 control
-- 的 local 槽數（Kahlua 190 上限）。投影每幀都問（control 的段尾延伸），遠離頂點時先粗篩、不估車道折點：
-- 圓半徑 ≤ HAIRPIN_APEX_MAX，圓心離頂點 ≤ |shift|＋|bIn| ≤ |b|·(1＋2/sinθ)（夾過的車道偏移不超過 |b|）。
local function kinkHandover(profile, state, idx, x, y, heading)
    local px, py, i = profile.x, profile.y, idx + 1
    local turn = wrapPi(profile.segH[i] - profile.segH[idx])
    if turn < 0 then turn = -turn end
    local sn, b = sin(turn), state.laneBias
    if sn > 0.1 then
        b = isFinite(b) and (b < 0 and -b or b) or 0
        local reach, dx0, dy0 = HAIRPIN_APEX_MAX + b * (1 + 2 / sn), x - px[i], y - py[i]
        if dx0 * dx0 + dy0 * dy0 > reach * reach then return false end
    end
    local join, shift, _, bIn = kinkRelease(profile, state, idx, turn, true)
    local cx, cy = px[i], py[i]
    if shift < 0 then
        local h = profile.segH[idx]
        cx = cx + cos(h) * shift - sin(h) * bIn
        cy = cy + sin(h) * shift + cos(h) * bIn
    end
    local dx, dy = x - cx, y - cy
    return dx * dx + dy * dy <= join * join
        and cos(heading) * (px[i + 1] - px[i]) + sin(heading) * (py[i + 1] - py[i]) > 0
end

-- 承諾線在非弧折點（fallback／髮夾、折角 ≥ FILLET_MIN_RAD）的**外側**：buildOffsetLine 在頂點 ±OV_BLEND 內旋轉法向，
-- 偏移 l 的線在這 2·OV_BLEND 的路線弧長裡實際繞一段半徑≈|l| 的外弧（143°、l −5.25 → 4m 弧長＝14.8m 線長）；車在
-- 外弧上時投影卡在頂點（兩臂的垂足都是頂點），路線弧長 sNow 停住十幾公尺。舊制：放行後前視點量路線弧長、跳到
-- 外弧繞完之後，且前視窗跨 143° 超過 TANGENT_MAX_TURN_RAD＝退回 pure pursuit，弦橫切頂點內側＝正好穿過被繞開的
-- 障礙（E2E hairpin-sp hp-t4：放行當幀 err 0.12→1.20、切進線內 5m 撞停車）；lineLat 也照卡住的 sNow 量。
-- 這段改以線本身為準：車在線上的投影與對線的帶號橫偏 dev（右正、同 latSigned）→ control 的 lineLat＝latSigned−dev、
-- 切線追蹤不受 15° 閘與鉗點閘、預視沿線長量。回 切線預視點 q（路線弧長參數）, dev；窗外回 nil（其餘路徑逐位元不變）。
local function ovOuterBend(profile, state, bestI, x, y, sNow, sTarget)
    local ovN, ovS0, ovEndS = state.ovN or 0, state.ovS0, state.ovEndS
    if ovN < 2 or not isFinite(ovEndS) or not isFinite(ovS0) or sNow < ovS0 or sNow >= ovEndS then return nil end
    local s, segH, segKind, SEG_ARC = profile.s, profile.segH, profile.segKind, MDADDynamics.SEG_ARC
    local ovX, ovY = state.ovX, state.ovY
    -- 頂點落在 (sNow−OV_BLEND, sTarget+OV_BLEND)＝線的混合區碰到前視窗（車在外弧上、sNow 停在頂點也算）
    local q, found = bestI > 1 and bestI - 1 or 1, false
    while q < profile.n - 1 and s[q + 1] < sTarget + OV_BLEND do
        local sV = s[q + 1]
        if sV > sNow - OV_BLEND and sV - OV_BLEND >= ovS0 and sV + OV_BLEND <= ovEndS
                and segKind[q] ~= SEG_ARC and segKind[q + 1] ~= SEG_ARC then
            local dth = wrapPi(segH[q + 1] - segH[q])
            if dth >= MDADDynamics.FILLET_MIN_RAD or dth <= -MDADDynamics.FILLET_MIN_RAD then
                local i, ft = ovIndexAt(ovS0, ovN, ovEndS, sV)
                local lat = (ovX[i] + (ovX[i + 1] - ovX[i]) * ft - profile.x[q + 1]) * -sin(segH[q])
                    + (ovY[i] + (ovY[i + 1] - ovY[i]) * ft - profile.y[q + 1]) * cos(segH[q])
                if lat * dth < 0 then found = true break end -- +l＝CCW 側；左轉（dth>0）的外側是 −l
            end
        end
        q = q + 1
    end
    if not found then return nil end
    -- 車在線上的投影：外弧整段在 [sV−OV_BLEND, sV+OV_BLEND]，車在弧上時 sNow＝sV，±(OV_BLEND+1) 蓋得住
    local kLo = ovIndexAt(ovS0, ovN, ovEndS, sNow - OV_BLEND - 1 > ovS0 and sNow - OV_BLEND - 1 or ovS0)
    local kHi = ovIndexAt(ovS0, ovN, ovEndS, sNow + OV_BLEND + 1 < ovEndS and sNow + OV_BLEND + 1 or ovEndS)
    local bestD, kB, tB, dev = 1e30, kLo, 0, 0
    for k = kLo, kHi do
        local ax, ay = ovX[k], ovY[k]
        local ex, ey = ovX[k + 1] - ax, ovY[k + 1] - ay
        local L2 = ex * ex + ey * ey
        if L2 > 1e-8 then
            local rx, ry = x - ax, y - ay
            local t = (rx * ex + ry * ey) / L2
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            local dx, dy = rx - ex * t, ry - ey * t
            local d2 = dx * dx + dy * dy
            if d2 < bestD then bestD, kB, tB, dev = d2, k, t, (ex * ry - ey * rx) / sqrt(L2) end
        end
    end
    -- 切線預視點：從投影點沿線走 TANGENT_PREVIEW_M（線長，不是路線弧長）。control 的切線＝q 處相鄰段按段內比例
    -- 混合＝q＋半格處的切線（弦向＝弦中點的切線）；平常半格＝0.5m 線長可忽略，混合區半格＝2m 以上＝提前轉入、
    -- 切進外弧內側（離線閉環 1.9m → 0.7m），回傳前退半格對齊。
    local sA = ovS0 + (kB - 1) * OV_STEP
    local sPrev = sA + ((kB + 1 == ovN and ovEndS or sA + OV_STEP) - sA) * tB
    local x0 = ovX[kB] + (ovX[kB + 1] - ovX[kB]) * tB
    local y0 = ovY[kB] + (ovY[kB + 1] - ovY[kB]) * tB
    local acc, i, q = 0, kB, ovEndS
    while i < ovN do
        i = i + 1
        local si = i == ovN and ovEndS or ovS0 + (i - 1) * OV_STEP
        local dx, dy = ovX[i] - x0, ovY[i] - y0
        local L = sqrt(dx * dx + dy * dy)
        if acc + L >= TANGENT_PREVIEW_M and L > 0 then
            q = sPrev + (si - sPrev) * (TANGENT_PREVIEW_M - acc) / L
            break
        end
        acc, sPrev, x0, y0 = acc + L, si, ovX[i], ovY[i]
    end
    return q - 0.5 * OV_STEP, dev
end

-- 前看弧段即時帽（1002c）：剖面的滑行包絡用建表期的弧速（中心線 κ、建表當下的側向），即時帽另算內側
-- 偏移與轉向域，常比包絡低——車到弧口才一步掉下來、減速輔助追不上（E2E SemiTruckLite R≈7：包絡約 20、
-- 弧口 15.3，入弧 16.5–19.4）。沿滑行能影響的距離往前找弧，每段弧只看第一段（即時帽從那裡開始作用），
-- 以同一個 coast 反推 sqrt(cap² + 2·coast·距離)。行駛線取承諾線（蓋得到該點時）否則常駐 lane 在該處的
-- 落點（clampLane 連續版）。skipRun＝車已在弧上：同一段弧由當下帽管，從下一段弧起算。
-- 沒有弧的 fallback 頂點車從放行點（頂點前 rel−shift，與 control 的鉗點同一個數，kinkRelease）就開始以 rMin 轉，
-- 帽要在那裡達到（1002e：建表帽記在頂點＝放行時還快 5–6 m 的滑行量，E2E SemiTruckLite 90° 折點放行 34 對帽 23、
-- 側滑外甩 2.3m；十批 campaign 56 次放行 32 次 >20 km/h、50 次打滑）。≤90° 帽＝sqrt(latSafe·rMin)（geometryStep
-- 同式），>90° 髮夾＝MIN_SPEED（geometryStep 的 dth>π/2 同類；1002j 一度拿掉，真因是放行點量中心線、見 kinkRelease）。
-- 回新的目標（m/s）；最多走 ARC_LOOK_STEPS 段，零配置。
local ARC_LOOK_STEPS = 48
local function arcLookaheadMs(profile, state, from, sNow, target, coast, skipRun)
    local look = state.latSafe
    if not isFinite(look) or look < 0 or not isFinite(coast) or coast <= 0 then return target end
    local floor2 = MIN_SPEED_MS * MIN_SPEED_MS
    local reach = (target * target - floor2) / (2 * coast)
    if not (reach > 0) then return target end
    local n, s, segKind, SEG_ARC = profile.n, profile.s, profile.segKind, MDADDynamics.SEG_ARC
    local SEG_FALLBACK, segH = MDADDynamics.SEG_FALLBACK, profile.segH
    local rMin = profile.rMin
    if not isFinite(rMin) or rMin < 0 then rMin = 0 end
    local rawBias = state.laneBias
    if not isFinite(rawBias) then rawBias = 0 end
    local ovN, ovS0, ovEndS = state.ovN or 0, state.ovS0, state.ovEndS
    local j, steps = from, 0
    if skipRun then
        while j <= n - 1 and segKind[j] == SEG_ARC and steps < ARC_LOOK_STEPS do j, steps = j + 1, steps + 1 end
    end
    while j <= n - 1 and steps < ARC_LOOK_STEPS do
        local dist = s[j] - sNow
        -- 髮夾彎內側的放行點再提前 b·tan(θ/2)（θ<150° → ≤3.73·|b|，kinkRelease）
        if dist - HAIRPIN_APEX_MAX - 3.8 * (rawBias < 0 and -rawBias or rawBias) > reach then break end
        if segKind[j] == SEG_ARC then
            local sj, lat = s[j], nil
            if ovN >= 2 and isFinite(ovS0) and isFinite(ovEndS) and sj >= ovS0 and sj <= ovEndS then
                local i0, ft = ovIndexAt(ovS0, ovN, ovEndS, sj)
                local ovX, ovY, h = state.ovX, state.ovY, profile.segH[j]
                lat = (ovX[i0] + (ovX[i0 + 1] - ovX[i0]) * ft - profile.x[j]) * -sin(h)
                    + (ovY[i0] + (ovY[i0 + 1] - ovY[i0]) * ft - profile.y[j]) * cos(h)
            else
                lat = clampLane(profile, j, rawBias, state.laneKeep, sj)
            end
            local cap = arcRuntimeCap(profile, j, lat, look)
            if cap ~= nil then
                if dist < 0 then dist = 0 end
                local lim = sqrt(cap * cap + 2 * coast * dist)
                if lim < target then
                    target = lim
                    reach = (target * target - floor2) / (2 * coast)
                end
            end
            while j <= n - 1 and segKind[j] == SEG_ARC and steps < ARC_LOOK_STEPS do j, steps = j + 1, steps + 1 end
        else
            if j >= 2 and segKind[j - 1] ~= SEG_ARC then
                local dth = wrapPi(segH[j] - segH[j - 1])
                if dth < 0 then dth = -dth end
                if profile.filletAdaptive and dth >= MDADDynamics.FILLET_MIN_RAD and dth < HAIRPIN_MAX_RAD
                    and (segKind[j - 1] == SEG_FALLBACK or segKind[j] == SEG_FALLBACK) then
                    local rel, shift = kinkRelease(profile, state, j - 1, dth)
                    local cap = sqrt(look * rMin)
                    if dth > HAIRPIN_RAD or cap < MIN_SPEED_MS then cap = MIN_SPEED_MS end
                    local d = dist + shift - rel
                    if d < 0 then d = 0 end
                    local lim = sqrt(cap * cap + 2 * coast * d)
                    if lim < target then
                        target = lim
                        reach = (target * target - floor2) / (2 * coast)
                    end
                end
            end
            j, steps = j + 1, steps + 1
        end
    end
    return target
end

function MDADFollower.control(profile, state, x, y, heading, speed, dt)
    if type(state) == "table" then
        state.curveValid = false
        state.curveHardActive = false
        state.curveKappa = 0
        state.curveCapKmh = 0
        state.profileSpeedKmh = nil
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

    -- 0927 正式服髮夾：側偏 2m 使反向臂較近，舊投影一幀跳 8.9m 並誤進 ROTATE。
    -- 候選弧長必須能由上幀車位走到：2×實際位移容納弧／弦差，0.5m 容納頂點交接。
    -- 限的是候選段＋投影點，不只 remaining；初次定位沒有歷史，維持原全域補定位。
    local maxS = profile.length
    if state.projS ~= nil and state.projX ~= nil and state.projY ~= nil then
        local dx, dy = x - state.projX, y - state.projY
        maxS = state.projS + 2 * sqrt(dx * dx + dy * dy) + 0.5
        -- 投影夾在本段終點、車已越過段尾（小折角短段＋側偏最常見）時，真實進度＝段尾弧長＋車沿
        -- 下一段方向的前進量；只從夾住的 projS 起算，下一段候選永遠「太遠」，投影釘死、側偏越長越大
        -- 直到誤進 ROTATE（2026-09-27 E2E replay：SemiBox 過 18°／3.1m 短段，1.8m 側偏）。車還沒到段尾
        -- （髮夾入彎臂的正式服案）不延伸，前跳防護照舊。車在折點交接圓內、車頭朝出臂（kinkHandover）也照此
        -- 延伸：彎內側車道上的車永遠到不了入彎臂段尾，頂點後又緊接短段時，只有 idx+1 能交接、它的端點卻比入彎臂
        -- 遠，投影就釘在入彎臂（E2E 1004a replay：4m 首段接 90°＋兩段 0.5m，起步轉進去後 s 停在 1.5、誤進
        -- ROTATE 三次交還）。
        if idx < n - 1 then
            local ex, ey = px[idx + 1], py[idx + 1]
            local rx, ry = x - ex, y - ey
            if rx * (ex - px[idx]) + ry * (ey - py[idx]) > 0 or kinkHandover(profile, state, idx, x, y, heading) then
                local along = (rx * (px[idx + 2] - ex) + ry * (py[idx + 2] - ey)) / segLen[idx + 1]
                if along > 0 and s[idx + 1] + along + 0.5 > maxS then maxS = s[idx + 1] + along + 0.5 end
            end
        end
        local reachI = MDADFollower.segIndexAt(profile, maxS)
        if reachI > hi then hi = reachI end -- 高速碎弧可一次跨多段，不能卡在固定 +12 段
    end

    -- 窗口一定至少含一段（lo <= idx <= hi，因為 idx 已夾在 [1, n-1]），所以直接用 lo
    -- 段當基準、從 lo+1 比起，不必在迴圈裡每次都測一遍「有沒有基準」。
    local bestI = lo
    local bestT, bestD = projectT(x, y, px[lo], py[lo], px[lo + 1], py[lo + 1], segLen[lo])
    for i = lo + 1, hi do
        local t, d2 = projectT(x, y, px[i], py[i], px[i + 1], py[i + 1], segLen[i])
        if d2 < bestD then
            local reachable = i <= idx or s[i] + segLen[i] * t <= maxS
            -- 真正轉彎會以有限半徑略過 raw 頂點，兩臂投影因此有不可避免的弧長差。
            -- 只在既有 rMin·tan(θ/2) 切點區內、且車頭已朝出臂的前半平面時交接相鄰臂。
            -- 位移方向會被靜止時 1cm 抖動騙過；車頭尚朝入臂的側偏車仍不能跳到反向臂。
            if not reachable and i == idx + 1 then
                reachable = kinkHandover(profile, state, idx, x, y, heading)
            end
            if reachable then bestI, bestT, bestD = i, t, d2 end
        end
    end
    -- 先保留能接上的原路段，避免右側合法lane較靠近平行反向臂時突然跳臂。
    -- 快取路線首段真的離車很遠，才在首次控制補一次全域定位。
    if state.needsProjection then
        state.needsProjection = false
        local width = profile.segWidth and profile.segWidth[bestI]
        local reach = LOOKAHEAD_MIN
        if isFinite(width) and width * 0.5 > reach then reach = width * 0.5 end
        if bestD > reach * reach then
            for i = 1, n - 1 do
                if i < lo or i > hi then
                    local t, d2 = projectT(x, y, px[i], py[i], px[i + 1], py[i + 1], segLen[i])
                    if d2 < bestD then bestI, bestT, bestD = i, t, d2 end
                end
            end
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
    state.projS, state.projX, state.projY = sNow, x, y
    local remaining = profile.length - sNow
    if remaining < 0 then remaining = 0 end
    -- 假抵達防護：remaining 只證明「投影點到終點的弧長很短」，不證明車在終點附近。
    -- 終點距離用平方比較，避免多做一次開根號。
    local exX, exY = px[n] - x, py[n] - y
    local reached = remaining <= ARRIVE_M and (exX * exX + exY * exY) <= ARRIVE_M_SQ

    -- ---- 前視點 ----
    local aspeed = speed
    if aspeed < 0 then aspeed = -aspeed end
    local lookScale = profile.lookScale
    if not isFinite(lookScale) or lookScale <= 0 then lookScale = 1 end
    local look = MDADFollower.lookaheadM(aspeed, lookScale)
    -- 急彎前視收縮（2026-09-02 s017 定罪切內、s021 定罪震盪的平衡點）：
    -- pure pursuit 轉向增益 ∝ 1/前視²——縮到 3m 治了切內（latDev max 2.86）
    -- 但增益放大近 7 倍→過彎蛇行（err 翻轉 0.6 次/s、43 次）。改縮到
    -- 0.75×彎半徑、下限 4.5m：增益放大收斂到 ~3 倍，貼線與穩定並存；
    -- 直路 κ≈0 完全不縮。
    -- 曲率取**整個前視窗**的最大值，不只車所在段（2026-09-03 s015 定罪：弧建好了，
    -- 車在弧前 10m、13 km/h 前視 11m 已伸進弧的後半，目標點落在右前方 → 直路上
    -- 就提前右打、切內 1.9m 撞同一根路口圍籬角；舊版只看 kap[bestI]，直路 κ=0
    -- 不縮，等車進弧才縮已經太晚）。先用原前視走一趟取窗內 κmax，縮了再走第二趟
    -- （第二趟更短；兩趟都受 LOOKAHEAD_WALK_MAX 上界）。
    -- 髮夾折點（90°<θ<150° 的非弧頂點；常數註解見 HAIRPIN_*）：前視目標**不得越過折點**——目標
    -- 一落到另一臂，車在折點前 6-8m 就朝它轉＝在內側切彎；121° 折點以 4.5m 前視切內 1.8m，4m 路
    -- 的路緣圍籬柱正好在那（2026-09-07 session-060 t=73-74：lat −0.6 → +1.6 撞柱、倒車兩次後
    -- StopStuck）。做法：走訪碰到髮夾就停在折點（目標＝頂點本身，誤差≈0 直開到折點），車距折點
    -- rMin·tan(θ/2)（理想圓角切點）才放行讓目標跳到另一臂。折點本身的速度由 geometryStep 的
    -- MIN_SPEED 與航向誤差減速管。
    local kap = profile.kappa
    local segKindW = profile.segKind
    local sTarget = sNow + look
    local j = bestI
    local walked = 0
    local kMax = 0
    local kinkS = nil
    if kap then
        kMax = kap[bestI] or 0
        local k2 = kap[bestI + 1] or 0
        if k2 > kMax then kMax = k2 end
    end
    local adaptiveW = profile.filletAdaptive == true -- capacity 退化折點也必須鉗到切點
    -- 彎內側（kinkRelease shift<0）以車道折點為基準：中心線弧長 [sV+shift, sV+cornerOut] 在車道上是同一點，
    -- 前視越過車道折點時加回 cornerOut−shift。髮夾（>90°）的鉗點與放行距離也量車道弧長；≤90° 的鉗點／放行仍量
    -- 中心線頂點（1002t 未經 campaign 不動），只有放行後的前視補車道弧長——不補時 90° 彎內側常駐 2.5 塌掉 5m，
    -- 前視下限 4.5m 的目標落在車身旁／車後，err 一幀 −1.8→+2.9 誤進 ROTATE；2.94m 首段起步時車再開回首段又被
    -- 鉗回身後頂點，四次調頭＝迴圈防護交還（正式服 1002y 起步片段）。shift＝0 與舊制逐位元相同。
    local laneCornerS, laneExtra = nil, 0
    while j < n - 1 and walked < LOOKAHEAD_WALK_MAX do
        local sV = s[j + 1]
        local cornerS = sV
        if segKindW[j] ~= MDADDynamics.SEG_ARC and segKindW[j + 1] ~= MDADDynamics.SEG_ARC then
            local dth = wrapPi(profile.segH[j + 1] - profile.segH[j])
            if dth < 0 then dth = -dth end
            -- 0907f：adaptive 剖面的 fallback 頂點（角度合格卻建不出弧＝路面容不下 rMin 的圓）同樣鉗到
            -- 切點才放行——F350 rMin 4.32 在 4m 路 90° 折點，前視目標一過折點就在 6-8m 前朝另一臂
            -- 切內（session-020 t=13-16：倒車復位後 12-16 km/h 仍切內撞住），鉗到 rMin·tan(45°)=4.3m
            -- 才轉＝走這台車做得到的最緊圓角（內側仍會壓過路緣 0.7m，contact 兜底）。
            local fallbackW = adaptiveW and dth >= MDADDynamics.FILLET_MIN_RAD
                and (segKindW[j] == MDADDynamics.SEG_FALLBACK
                    or segKindW[j + 1] == MDADDynamics.SEG_FALLBACK)
            if (dth > HAIRPIN_RAD or fallbackW) and dth < HAIRPIN_MAX_RAD then
                local rel, shift, cornerOut = kinkRelease(profile, state, j, dth, true)
                cornerS = sV + (dth > HAIRPIN_RAD and shift or 0)
                if cornerS < sTarget then
                    if cornerS > sNow + rel then kinkS = cornerS; break end
                    state.kinkExitS = sV
                    if shift < 0 then
                        laneCornerS, laneExtra = sV + shift, cornerOut - shift
                        sTarget = sTarget + laneExtra
                    end
                end
            end
        end
        if cornerS >= sTarget or sV >= sTarget then break end
        j = j + 1
        walked = walked + 1
        if kap then
            local k = kap[j + 1] or 0
            if k > kMax then kMax = k end
        end
    end
    if kMax > 1e-6 then
        local rShrink = 0.75 / kMax
        if rShrink < look then
            look = rShrink
            if look < 4.5 then look = 4.5 end
            sTarget = sNow + look
            if laneCornerS ~= nil and sTarget > laneCornerS then sTarget = sTarget + laneExtra end
            -- 往回退到與前進走法同一個不變式：s[j] < sTarget ≤ s[j+1]
            while j > bestI and s[j] >= sTarget do j = j - 1 end
        end
    end
    if kinkS ~= nil and sTarget > kinkS then
        sTarget = kinkS
        while j > bestI and s[j] >= sTarget do j = j - 1 end
    end
    -- 承諾線在非弧折點外側（ovOuterBend）：沿線的切線預視點與車對線橫偏，給下面的 lineLat 與切線追蹤；窗外 nil、逐位元照舊
    local ovQ, ovDev = ovOuterBend(profile, state, bestI, x, y, sNow, sTarget)
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
    -- 常駐偏置先過該段路面餘裕（buildLaneRoom）：彎內側吃不下的偏置就地歸零，
    -- 前視點跨進弧段時目標橫移由 pure pursuit 自然攤成 S 形（無另建 ramp）。
    local bias = state.laneBias
    if not isFinite(bias) then bias = 0 end
    local sEff = s[j] + lj * tj
    bias = clampLane(profile, j, bias, state.laneKeep, sEff)
    local lt = bias
    local offL = state.offL
    local ovUsed = false
    -- Both immutable dodge and RETURN can supply one exact prevalidated world line.
    -- RETURN borrows the caller's preallocated array; dodge uses state-owned storage.
    local ovN = state.ovN or 0
    local ovEndS = state.ovEndS
    local ovX, ovY = state.ovX, state.ovY
    if ovN >= 2 and isFinite(ovEndS)
            and sEff >= state.ovS0 and sEff <= ovEndS then
        local i0, ft = ovIndexAt(state.ovS0, ovN, ovEndS, sEff)
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
    -- 繞行承諾（state.trackTangent）：誤差改對「承諾線在車前
    -- TANGENT_PREVIEW_M 處的切線」而非前視點。前視點 6-7m 比進入段（4-6m）還長，pure
    -- pursuit 對目標點的弦只能給 dl/look 的橫向斜率、車頭一超過弦角就喊「轉回去」，與
    -- cross-track 互相抵消＝進入段落後 0.25-1.3m 撞障礙（2026-09-04 s006/s018/s021/s030）。
    -- 切線＋cross-track（Stanley 型）讓車照線本身的斜率走；離線閉環（scripts/exp_gap_tangent.lua）
    -- 進入段峰值／到 b 落後降 40-60%、出口前切內 0.3-0.8→≤0.2。只在 ov 線覆蓋範圍內生效，其餘照舊。
    -- 只在前視窗內路線本身近直（|Δ段向| ≤ TANGENT_MAX_TURN_RAD）才追切線：路口內側偏 3m 的
    -- ov 線在彎頂有折點，切線一幀跳 30° → D 項抽 −3.6 → 15 km/h 甩尾撞路口電話亭
    -- （2026-09-04 s022 st184,011.8）；彎中交回前視點（前視點本來就把折點平掉）。
    -- 弧段（v4 圓角，SEG_ARC）一律追切線（2026-09-07 session-058 t=14.6-17.8 定罪：R≈12 左彎
    -- 12-26 km/h，pure pursuit 對弧上前視點的弦角讓車一路切內，lat +1.1 → −1.7、cross-track
    -- 0.77/v 拉不回，撞路燈。離線閉環 temp/exp_arc_tracking.lua：R 8-18／15-35 km/h 切內
    -- 1.0-1.8m → 切線＋cross-track ×2 後 0.3-0.75m，plant 強弱三檔皆同向）。圓角切線逐頂點
    -- 只轉 ≤2°，不需要 ov 折點那道 15° 閘；ov 線覆蓋弧段時取 ov 切線（含過渡段斜率），
    -- 否則取剖面切線（lane 平行線的切線＝中心線切線）。
    -- 前視窗 [車所在段, 前視點所在段] 內的第一個弧段（弧段前饋同源）。弧長短於前視時前視點會越過整段弧：
    -- 只看兩端段＝車在弧前、前視點在彎後直路的那幾公尺切線追蹤關閉，改用 pure pursuit 弦角朝彎後的點提前
    -- 轉入（0928o E2E rc18 2005 51 km/h R24 27° 右彎：弧前 2m err 0.14–0.22、steer 0.8–1.2，進弧時車頭已多轉
    -- 0.1 rad → 切內 1.57m、對線帽把 48 壓到 23；rc16 0118 切內 1.5m 後 blocked 急停）。窗內有弧就追切線。
    local arcK = nil
    do
        local q = bestI
        while q <= j do
            if segKindW[q] == MDADDynamics.SEG_ARC then arcK = q break end
            q = q + 1
        end
    end
    -- ov 線在車投影點的橫向（對中心線、右正）：Driver 的 cross-track 期望線。停留線的
    -- 換道從 commit 點就開始（returnLane 模式），Driver 舊制用 a..b smoothstep 算期望線
    -- → 兩者相差 1m 以上，cross-track 把車往「線不在的地方」拉（2026-09-04 s023 t=24-29：
    -- 進縫前被拉離線 0.9m、進縫後又追不上，貼 B 車）。
    local lineLat = nil
    if ovN >= 2 and isFinite(ovEndS) and sNow >= state.ovS0 and sNow <= ovEndS then
        local i0, ft = ovIndexAt(state.ovS0, ovN, ovEndS, sNow)
        local lx = ovX[i0] + (ovX[i0 + 1] - ovX[i0]) * ft
        local ly = ovY[i0] + (ovY[i0 + 1] - ovY[i0]) * ft
        lineLat = (lx - pjx) * -sin(hProj) + (ly - pjy) * cos(hProj)
    end
    -- 外側折點窗內：投影卡在頂點時 lineLat 對中心線量不出線在哪；改成「車對線的帶號橫偏」，Driver 的
    -- latSigned − lineLat 就是車到線的距離（cross-track 不用改）
    if ovQ ~= nil then lineLat = latSigned - ovDev end
    -- 承諾線在弧的外側（1002f）：ov 線每 1m 路線弧長實際長 1−l·κ（>1）倍，轉角卻與中心線相同——路線弧長
    -- 1.5m 的切線預視＝線上預視角大 (1−l·κ) 倍、弧段前饋也照中心弧 1/R 給，車照中心弧的 yaw 率轉、切進線內
    -- （E2E rc48 0017：R 3.35 弧外側 3.75 的貼縫繞行線，yaw −0.9 rad/s＝中心弧的值、落後線 1.5m 撞上）。
    -- 預視改成線上 1.5m（路線弧長 1.5/(1−l·κ)），前饋乘 1/(1−l·κ)。內側（<1）照舊。
    local ovDen = nil
    if arcK ~= nil and lineLat ~= nil then
        local r = profile.filletRadius and profile.filletRadius[arcK]
        if isFinite(r) and r > 0 then
            local dth = 0
            if arcK >= 2 and segKindW[arcK - 1] == MDADDynamics.SEG_ARC then
                dth = wrapPi(profile.segH[arcK] - profile.segH[arcK - 1])
            elseif arcK + 1 <= profile.n - 1 then
                dth = wrapPi(profile.segH[arcK + 1] - profile.segH[arcK])
            end
            local den = 1 - lineLat * (dth < 0 and -1 / r or 1 / r)
            if den > 1 then ovDen = den end
        end
    end
    local tangentOn = false
    state.laneTangent = false -- 切線取自剖面＋車道斜率（弧段前饋的車道項只在這時算）
    local onArc = profile.filletAdaptive == true and arcK ~= nil
    if (state.trackTangent == true or onArc)
            and (kinkS == nil or ovQ ~= nil or sNow + TANGENT_PREVIEW_M < kinkS - OV_BLEND) then
        local q = ovQ or sNow + TANGENT_PREVIEW_M / (ovDen or 1)
        -- ov 線是否蓋住預視點：與 ovUsed（由長前視 sEff 決定）解耦——線尾最後 look 公尺
        -- sEff 已出線、q 仍在線上，弧段仍得追線的切線（出口過渡斜率），不可提前改讀中心線。
        -- 一般繞行也由 q 的覆蓋判斷，不能因長前視已出線而提前改回弦角；折角 >15° 仍退前視點。
        if ovUsed and q < state.ovS0 then q = state.ovS0 end
        local ovCover = ovN >= 2 and isFinite(ovEndS) and q >= state.ovS0 and q <= ovEndS
        local useOv = ovCover and (onArc or ovQ ~= nil)
        if ovCover and not useOv then
            local dh = wrapPi(profile.segH[j] - profile.segH[bestI])
            if dh < 0 then dh = -dh end
            useOv = dh <= TANGENT_MAX_TURN_RAD
        end
        if useOv then
            local i0, ft = ovIndexAt(state.ovS0, ovN, ovEndS, q)
            local dx, dy = ovX[i0 + 1] - ovX[i0], ovY[i0 + 1] - ovY[i0]
            if i0 + 2 <= ovN then
                -- 與下一段切線按段內比例混合：折線切線逐段跳變會讓 PID 的 D 項每公尺抽一記
                dx = dx * (1 - ft) + (ovX[i0 + 2] - ovX[i0 + 1]) * ft
                dy = dy * (1 - ft) + (ovY[i0 + 2] - ovY[i0 + 1]) * ft
            end
            if dx * dx + dy * dy > 1e-8 then vx, vy = dx, dy; tangentOn = true end
        end
        if not tangentOn and onArc then
            local qi = bestI
            while qi < profile.n - 1 and s[qi + 1] < q do qi = qi + 1 end
            local hq = profile.segH[qi]
            -- 常駐車道本身的橫向斜率（clampLane 的連續 ramp；彎前內側收窄最常見）一併轉進切線：只給中心線
            -- 方向時期望線在動、車頭不動，只剩 0.77/v 的 cross-track 追（0928o 離線重播 rc18 2005：彎前 25m
            -- 期望線 2.21→1.57、車停在 1.96＝進弧已偏內 0.4m）。lane>0 在數學 CCW 法向側，斜率正＝往 CCW 轉。
            -- 斜率取在預視點再往前 TANGENT_SLOPE_LEAD_S 秒（見常數註解）。
            local rb = state.laneBias
            if isFinite(rb) and rb ~= 0 then
                local q2 = q + aspeed * MS_PER_KMH * TANGENT_SLOPE_LEAD_S
                local qi2 = qi
                while qi2 < profile.n - 1 and s[qi2 + 1] < q2 do qi2 = qi2 + 1 end
                local l1 = clampLane(profile, qi2, rb, state.laneKeep, q2)
                q2 = q2 + TANGENT_PREVIEW_M
                while qi2 < profile.n - 1 and s[qi2 + 1] < q2 do qi2 = qi2 + 1 end
                hq = hq + atan2(clampLane(profile, qi2, rb, state.laneKeep, q2) - l1, TANGENT_PREVIEW_M)
            end
            vx, vy = cos(hq), sin(hq)
            tangentOn = true
            state.laneTangent = true
        end
    end
    local err = atan2(fx * vy - fy * vx, fx * vx + fy * vy)
    -- 承諾線（繞行／回線，state.trackTangent）在弧上：切線對「參考點的行進方向」而非車頭（1002n；E2E rc53 0005／0022：
    -- vehicle:getX/Y 不是無側滑點，穩態彎上行進方向比車頭偏彎內 β≈0.7·ω/v＝0.07–0.16 rad；車頭對準切線＝速度向量
    -- 多指彎內 β，車往線內漂到 cross-track 抵銷為止＝0.45m，超過貼縫餘裕 0.29–0.33 擦撞）。β＝最近 0.5m 位移的弦角
    -- 減兩端車頭平均（定曲率下精確、直路≈0），每走一弦更新一次；跳格（>2m）不量、夾 ±0.3。只在前視窗有弧時扣：
    -- 直路換道 β 隨 ω 換號，弦估計的滯後反而加大落後。一般跟線不扣（彎前收油與弧段前饋是在無側滑模型上調的）。
    do
        local sx, sy = state.slipX, state.slipY
        if sx ~= nil and speed >= 3 then
            local dx, dy = x - sx, y - sy
            local d2 = dx * dx + dy * dy
            if d2 >= 0.25 then
                local b = 0
                if d2 <= 4 then
                    local sh = state.slipH
                    b = wrapPi(atan2(dy, dx) - sh - wrapPi(heading - sh) * 0.5)
                    if b > 0.3 then b = 0.3 elseif b < -0.3 then b = -0.3 end
                end
                state.slip, state.slipX, state.slipY, state.slipH = b, x, y, heading
            end
        else
            state.slip, state.slipX, state.slipY, state.slipH = 0, x, y, heading
        end
        if state.trackTangent == true and tangentOn and arcK ~= nil then err = wrapPi(err - state.slip) end
    end
    -- 切線↔前視點切換那一幀誤差定義不同：清 D 項歷史，不讓切換本身抽一記
    if tangentOn ~= (state.tangentOn == true) then
        state.tangentOn = tangentOn
        state.errPrev = nil
        state.dFilt = 0
    end
    -- 折點鉗制（髮夾／fallback 頂點）放行那幀同樣是誤差定義切換：目標從頂點跳到另一臂，
    -- err 0→58° 一幀、D 項 dFilt 0→18 → steer 直接飽和 5 三幀（Codex lane 2026-09-07 真 Follower
    -- 重現：F350 lookScale 1.5、12 km/h、距頂點 4.35→4.29m）。進入鉗制那幀也清（跳回頂點）。
    -- 記頂點弧長而非 boolean：相鄰兩個 fallback 角 A→B，A 放行那幀直接鉗 B（held 仍 true）同樣是
    -- 目標跳變（Codex lane 靜態推導：4m 路 {60,0}→{60,6} 兩角，次幀 err 54°、steer 飽和）。
    if kinkS ~= state.kinkHeld then
        state.kinkHeld = kinkS
        state.errPrev = nil
        state.dFilt = 0
    end


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

    -- ---- 目標速度（段內物理包絡；曲率／制動已烘進端點 v）----
    -- 不能用線性插值：v 只在「點」上有值，長段內線性連 v[i]→v[i+1] 是物理錯誤。
    -- 2026-08-28 實機（163 號公路長直路）：nav 路網節點在路口，末段是 ~233m 的
    -- 單一線段，段尾 v[n]=0（終點）——線性插值把整段畫成 20→0 的長斜坡，車在
    -- 233m 外就以 target=0.087×remaining 龜速爬完全程（遙測 target 20.1→4.3 與
    -- remaining 嚴格成正比）。正確剖面是段內延拓 build pass 的同一組式子：
    --   制動曲線 sqrt(v[i+1]² + 2·BRAKE·(s[i+1]-s)) —— 進折點／終點前才需要煞
    --   滑行曲線 sqrt(coastV[i+1]² + 2·coast·(s[i+1]-s)) —— 彎前收油包絡
    -- 取 min 再夾 maxSpeed。加速側不設包絡（檔頭「前向加速」註解）：直路段
    -- 直給 maxSpeed，供油連續性交還 regulator 的二值 isGas。
    -- 端點極限：ds→L 收斂到 v[i+1]，折點限速一樣被尊重。
    local targetSpeed
    do
        local lenI = segLen[bestI]
        local remainI = lenI * (1 - bestT)
        local brake = profile.segBrake[bestI] or BRAKE
        local coast = profile.coastRate and profile.coastRate[bestI] or profile.segCoast[bestI] or 0.6
        local runtimeBrake, runtimeCoast =
            state.brakeSafe, state.coastSafe
        if isFinite(runtimeBrake) and runtimeBrake >= 0 and runtimeBrake < brake then
            brake = runtimeBrake
        end
        if isFinite(runtimeCoast) and runtimeCoast >= 0 then
            -- 線上學到的是純斷油；建表有加中線減速輔助的段，夾限同樣加回（不然輔助形同虛設）
            runtimeCoast = runtimeCoast + (profile.coastAssistAt and profile.coastAssistAt[bestI] or 0)
            if runtimeCoast < coast then coast = runtimeCoast end
        end
        -- 同建表（1002l）：制動包絡只管終點煞停，不比收油包絡（斷油＋輔助）更早綁；0 仍是 fail-safe
        if brake > 0 and brake < coast then brake = coast end
        local coastNext = profile.coastV[bestI + 1] or profile.maxSpeedMs
        local brakeNext = profile.brakeV[bestI + 1] or 0
        -- 滑行包絡的停點在終點前 COAST_STOP_M（與建表同一個 coastStopS），段內也要量到那裡
        local coastReach = remainI
        local stopS = profile.coastStopS
        if stopS and s[bestI + 1] > stopS then
            coastReach = stopS - sNow
            if coastReach < 0 then coastReach = 0 end
        end
        local coastLim = sqrt(coastNext * coastNext + 2 * coast * coastReach)
        local stopLim = sqrt(brakeNext * brakeNext + 2 * brake * remainI)
        targetSpeed = coastLim
        if stopLim < targetSpeed then targetSpeed = stopLim end
        if targetSpeed > profile.maxSpeedMs then targetSpeed = profile.maxSpeedMs end
        -- 當下弧段的即時帽（arcRuntimeCap：行駛線往彎內側的半徑折算、轉向域、MIN_SPEED 地板）
        local curveHardActive = profile.segKind[bestI] == MDADDynamics.SEG_ARC
        local actualKappa, curveCap = 0, profile.maxSpeedMs
        if curveHardActive then
            local latHere = lineLat
            if latHere == nil then latHere = clampLane(profile, bestI, bias, state.laneKeep, sNow) end
            local cap
            cap, actualKappa = arcRuntimeCap(profile, bestI, latHere, state.latSafe)
            if cap ~= nil then
                curveCap = cap
                if curveCap < targetSpeed then targetSpeed = curveCap end
            end
        end
        -- 前方弧段的即時帽改成滑行包絡提前減（arcLookaheadMs），不在弧口一步掉下來
        targetSpeed = arcLookaheadMs(profile, state, bestI + 1, sNow, targetSpeed, coast, curveHardActive)
        state.curveHardActive = curveHardActive
        state.curveKappa = actualKappa
        state.curveCapKmh = curveCap * KMH_PER_MS
        state.curveValid = true
        targetSpeed = targetSpeed * KMH_PER_MS
    end
    -- 幾何設計只讀路線物理包絡；後面的姿態／出彎收正帽只約束當下控制。
    state.profileSpeedKmh = targetSpeed

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

    -- 前視點對準不代表車身已收正。急折點放行後，先收掉殘餘姿態／橫偏再恢復巡航；
    -- 遠處繞行的 pre-a 仍在接近，不能取消近處出彎收正；進入段／精確線才正式接手。
    if ovUsed and (offL == nil or sNow >= state.offA) then
        state.kinkExitS = nil
    elseif state.kinkExitS ~= nil then
        local att = wrapPi(heading - hProj)
        local brisk = profile.styleName == "brisk"
        local lane = lineLat
        if lane == nil then
            lane = clampLane(profile, bestI,
                isFinite(state.laneBias) and state.laneBias or 0, state.laneKeep, sNow)
        end
        if sNow >= state.kinkExitS
                and math.abs(att) <= (brisk and MDADDynamics.ALIGN_HEADING_RAD or KINK_EXIT_ALIGN_RAD)
                and math.abs(latSigned - lane) <= (brisk and 1.0 or KINK_EXIT_LANE_M) then
            state.kinkExitS = nil
        elseif targetSpeed > ROTATE_SPEED_KMH then
            targetSpeed = ROTATE_SPEED_KMH
        end
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
        state.ffSteer, state.ffSteadyT, state.hiSteerLag = 0, 0, nil
        state.prevHeading = nil -- 調頭飽和轉向不進增益估計
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
        -- ---- yaw 增益線上估計（常數註解見 CURVE_FF_FRAC）----
        local yawGain = state.yawGain
        if not isFinite(yawGain) then yawGain = YAW_GAIN_INIT end
        local ph = state.prevHeading
        if isFinite(ph) and dt > 1e-4 and dt < 0.5 then
            local ap = state.appliedSteer
            if not isFinite(ap) then ap = state.steerOut end
            if isFinite(ap) and (ap >= YAW_GAIN_MIN_STEER or ap <= -YAW_GAIN_MIN_STEER)
                    and aspeed >= YAW_GAIN_MIN_KMH then
                local obs = wrapPi(heading - ph) / dt / ap
                if obs < YAW_GAIN_LO then obs = YAW_GAIN_LO elseif obs > YAW_GAIN_HI then obs = YAW_GAIN_HI end
                local alpha = dt / YAW_GAIN_TAU_S
                if alpha > 1 then alpha = 1 end
                yawGain = yawGain + (obs - yawGain) * alpha
                -- 回授正規化用的增益（Driver Drive.normalizeSteer）：轉向方向正規化後 yaw 與 steer 各自 EWMA 再相除，
                -- 同 FF_HI。上面的逐幀比值先夾 [LO,HI] 再平均，heading 逐幀噪聲讓夾限不對稱（下面只到 0.08、上面到 3），
                -- 低增益車被往上拉 2–3 倍（1001h 車隊：SemiTruckBox 實測 0.16、估 0.33–0.40；SemiTruckBox_mil 0.11–0.16、
                -- 估 0.44–0.53＝回授正規化完全沒作用）。前饋 FRAC 是照舊估計調的，前饋照舊用 yawGain。
                -- 撞擊／甩尾幀不學（正式服 1002y 片段）：yaw 與施加轉向反相時 yf 掉成負、gfb 夾到 0.08，Driver 回授被放大到
                -- FB_NORM_MAX、轉向極限環（st ±1.5、yr ±6.6）又餵更多反相資料，學不回來。上幀 steer 被 ESC 收掉的幀同 FF_HI
                -- 不學；反相只剔「明顯反向」（sg·yaw < −FF_HI.fbOppose），用 0 會把 heading 噪聲的負半邊整批丟掉、低增益重車
                -- 被估高（情境「1001h」230 FPS 噪聲）。
                local sg = ap > 0 and 1 or -1
                if state.escLimited ~= true and sg * wrapPi(heading - ph) / dt > -FF_HI.fbOppose then
                    local yf = state.fbYawF or yawGain * sg * ap
                    local sf = state.fbSteerF or sg * ap
                    yf = yf + (sg * wrapPi(heading - ph) / dt - yf) * alpha
                    sf = sf + (sg * ap - sf) * alpha
                    state.fbYawF, state.fbSteerF = yf, sf
                    local gfb = yf / sf
                    if gfb < YAW_GAIN_LO then gfb = YAW_GAIN_LO elseif gfb > YAW_GAIN_HI then gfb = YAW_GAIN_HI end
                    state.yawGainFb = gfb
                end
            end
        end
        -- 高速弧段增益（常數註解見 FF_HI）：轉向方向正規化後 yaw 與 steer 各自 EWMA
        -- 上幀 steer 被 Driver 的 yaw 率限制（ESC）收掉的幀不學：那是側滑（yaw 超過物理上限）、steer 被砍到 0，
        -- yaw／steer 一路衝到上限 3（0928o E2E rc20 1017：58 km/h 側滑一幀 1.06→3.00）；高估後前饋縮到門檻下、
        -- 之後的弧再也學不回來，整趟 45–55 km/h 的彎只剩三分之一前饋、外漂 0.8m。低速學習隨時會重學，不必擋。
        -- 1002u：只學前饋整份連續 settleS 以上的幀，steer 用 settleS 一階低通後的值（每幀都更新＝跟著真實施力歷史）。
        local pff = state.ffSteer
        local ul = state.hiSteerLag
        do
            local ap = state.appliedSteer
            if not isFinite(ap) then ap = state.steerOut end
            if isFinite(ap) and dt > 1e-4 and dt < 0.5 then
                if not isFinite(ul) then ul = ap end
                local a = dt / FF_HI.settleS
                if a > 1 then a = 1 end
                ul = ul + (ap - ul) * a
                state.hiSteerLag = ul
            end
        end
        if isFinite(ph) and dt > 1e-4 and dt < 0.5 and aspeed >= FF_HI.learnKmh and isFinite(pff)
                and (pff >= FF_HI.minFF or pff <= -FF_HI.minFF) and state.escLimited ~= true
                and (state.ffSteadyT or 0) >= FF_HI.settleS and isFinite(ul) then
            local sg = pff > 0 and 1 or -1
            local alpha = dt / YAW_GAIN_TAU_S
            if alpha > 1 then alpha = 1 end
            local yf, sf = state.hiYawF or 0, state.hiSteerF or 0
            yf = yf + (sg * wrapPi(heading - ph) / dt - yf) * alpha
            sf = sf + (sg * ul - sf) * alpha
            state.hiYawF, state.hiSteerF = yf, sf
            state.hiLearnT = (state.hiLearnT or 0) + dt
            if sf >= FF_HI.minFF and yf > 0 then
                local g = yf / sf
                if g < YAW_GAIN_LO then g = YAW_GAIN_LO elseif g > YAW_GAIN_HI then g = YAW_GAIN_HI end
                state.yawGainHi = g
            end
        end
        state.prevHeading = heading
        state.yawGain = yawGain
        -- ---- 弧段前饋（arcFeedForward）----
        local ff = arcFeedForward(profile, state, arcK, bestI, sNow, aspeed, tangentOn, yawGain,
            tangentOn and ovDen or nil, latSigned, lineLat)
        if ff ~= 0 then
            steer = steer + ff
            if steer > STEER_MAX then steer = STEER_MAX
            elseif steer < -STEER_MAX then steer = -STEER_MAX end
        end
        state.ffSteer = ff
        state.ffSteadyT = state.ffFull and (state.ffSteadyT or 0) + dt or 0
        state.steerOut = steer
    end

    return steer, targetSpeed, remaining, reached, err, bestD, latSigned, lineLat
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

-- 就地重設（不配置）。換 route 時對同一顆 state 呼叫這個：
-- 清全部控制歷史（resetControl），下一次control重新定位到車在新路線上的位置。
function MDADFollower.resetState(state)
    if type(state) ~= "table" then return state end
    state.idx = 1
    state.needsProjection = true
    return MDADFollower.resetControl(state)
end

-- 只清「控制歷史」（PID 積分／微分／誤差歷史／調頭旗標／側偏剖面），**保留投影
-- 游標 idx**。給「路線沒換、控制脈絡斷了」的情境用——倒車脫困成功就是典型：
-- 車還在同一條路線的同一段附近，保留游標就不必重做全線定位，也不會跳到自交路線的
-- 另一個分支。脫困的小幅倒退仍由局部窗口與REWIND_MAX自行收斂。
-- 投影可達歷史（projS/projX/projY）也清：它假設「上一幀 control 之後車只走了這段位移」，
-- 倒車脫困／讓位期間 control 沒跑，玩家可能沿折返路線開到隔 5m 的另一臂，舊歷史會把
-- 真實新段判成不可達、永遠黏在舊段（2026-09-27 review）。清掉後回到局部窗口定位。
function MDADFollower.resetControl(state)
    if type(state) ~= "table" then return state end
    state.projS, state.projX, state.projY = nil, nil, nil
    state.iTerm = 0
    state.dFilt = 0
    state.kinkHeld = nil -- 鉗制中的頂點弧長（nil＝未鉗）；切換／放行幀清 D
    state.kinkExitS = nil
    -- errPrev 刻意留空（不是 0）：control 對缺值會用「當幀誤差」當歷史，因此重設後的
    -- 第一幀微分項貢獻 0。若填 0，車頭原本偏 130° 時第一幀會吃到 (2.27-0)/dt 的假尖刺。
    state.errPrev = nil
    state.rotating = false
    state.curveValid = false
    state.curveHardActive = false
    state.curveKappa = 0
    state.curveCapKmh = 0
    state.profileSpeedKmh = nil
    state.offL = nil
    state.trackTangent = false
    state.tangentOn = false
    state.ffSteer, state.ffSteadyT, state.hiSteerLag = 0, 0, nil -- 低通／穩態計時跟施力歷史一起斷
    state.prevHeading = nil -- yawGain 是車的性質，跨 cutover／脫困保留；只斷差分
    state.slipX, state.slip = nil, 0 -- 側滑弦估計同樣斷差分（瞬移／脫困後重量）
    releaseExactLine(state)
    return state
end

-- setOffset／setExactLine 共用的 M6 折線驗證：srcX/srcY 型別、srcN/srcS0/srcS1
-- 有限、點數上限、srcS1 落在最末取樣段內（srcN>=2 時 lastStart>=srcS0，因此也
-- 涵蓋 srcS1<=srcS0 的退化輸入）、逐點有限。回 floor 後的 srcN；不合法回 nil。
local function validLine(srcX, srcY, srcN, srcS0, srcS1)
    if type(srcX) ~= "table" or type(srcY) ~= "table"
            or not isFinite(srcN) or not isFinite(srcS0)
            or not isFinite(srcS1) then return nil end
    srcN = srcN - srcN % 1
    local lastStart = srcS0 + (srcN - 2) * OV_STEP
    if srcN < 2 or srcN > OV_MAX or srcS1 <= lastStart
            or srcS1 > lastStart + OV_STEP + 1e-6 then return nil end
    for i = 1, srcN do
        if not isFinite(srcX[i]) or not isFinite(srcY[i]) then return nil end
    end
    return srcN
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
-- coverEnd（選填）＝呼叫端要求的線覆蓋終點（2026-09-02 s-458.7k console 定罪：
-- d 允許超出 route 終點後，折線只建到終點——覆蓋檢查若仍要求 d+1，commit
-- 永遠在門口被拒、車每輪「curve dodge ok → setOffset REJECTED」死循環）。
-- 上鉗 d+1（不得放寬超過原契約）；nil＝原契約 d+1。
function MDADFollower.setOffset(state, a, b, c, d, l,
        srcX, srcY, srcN, srcS0, srcS1, coverEnd)
    if type(state) ~= "table" then return false end
    if not (isFinite(a) and isFinite(b) and isFinite(c) and isFinite(d) and isFinite(l)) then
        return false
    end
    if not (a < b and b <= c and c < d) then return false end
    srcN = validLine(srcX, srcY, srcN, srcS0, srcS1)
    local want = isFinite(coverEnd) and coverEnd or (d + 1)
    if want > d + 1 then want = d + 1 end
    if not srcN or srcS1 < want - 1e-6 then return false end
    state.offA, state.offB, state.offC, state.offD, state.offL = a, b, c, d, l
    state.ovX, state.ovY = srcX, srcY
    state.ovN, state.ovS0, state.ovEndS = srcN, srcS0, srcS1
    state.exactLine = false
    return true
end

-- RETURN commits the exact array that the Driver already swept. Unlike dodge,
-- no copy is allowed: identity/content equality is part of the safety contract.
function MDADFollower.setExactLine(state, srcX, srcY, srcN, srcS0, srcS1)
    if type(state) ~= "table" then return false end
    srcN = validLine(srcX, srcY, srcN, srcS0, srcS1)
    if not srcN then return false end
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
-- 路線點＋lane(s)·n̂(s)：lane 用與 control 相同的 smoothstep（start→l→bias），
-- n̂ 在距段端 OV_BLEND 內與鄰段法向做**角度插值**——折點連續是 M6 的全部
-- 意義（舊逐段法向在折點跳 2|l|sin(θ/2)）。寫進呼叫端預配置陣列（零配置），
-- 回 (點數, s0)。s0＝呼叫端指定的掃掠起點（含車位前的起始段一併烘進表，
-- 掃掠與前視驗的、走的是同一條線）。
-- startLane（第 14 參，可省略）＝線在 s0..a 與進入段起點的 lane：Driver 傳車的
-- **實際橫向**（2026-09-06；s025 定罪：車在 1.66、bias 夾成 0.13，線從車不在的
-- 地方起步，cross-track 先把車往左拉 1.5m 再右切繞行＝前角撞路口內側桿）。
-- 回線段 c..d 仍回 bias（常駐 lane），線走完後 control 讀 state.laneBias 無台階。
-- targetKeep（第 15 參，可省略）＝returnLane 模式目標逐段夾時往內留多少：省略＝
-- LANE_BIAS_KEEP（RETURN 目標是常駐 lane 的落點，路途中收窄要與 control 落在同一格，
-- 否則 clear 釋放那一刻往內跳）；停留線傳 0（offL 是掃掠驗過的絕對 lane，只夾物理餘裕）。
function MDADFollower.buildOffsetLine(profile, s0, a, b, c, d, l, bias, outX, outY,
        returnLaneStart, returnLaneTarget, returnLaneEnd, startLane, targetKeep)
    if type(profile) ~= "table" or profile.ready ~= true then return 0, 0, "invalid", 0 end
    if not (isFinite(s0) and isFinite(a) and isFinite(d) and isFinite(l)) then
        return 0, 0, "invalid", 0
    end
    if not isFinite(bias) then bias = 0 end
    if not isFinite(startLane) then startLane = bias end
    if not isFinite(targetKeep) or targetKeep < 0 then targetKeep = LANE_BIAS_KEEP end
    local px, py = profile.x, profile.y
    local ss, segLen, segH = profile.s, profile.segLen, profile.segH
    local n = profile.n
    if s0 < 0 then s0 = 0 end
    local requiredEnd = d + 1
    -- d 允許超出 route 終點（近目標帶偏抵達，2026-09-01）：折線只建到終點，
    -- 回線 smoothstep 用原 d 當幾何參數＝只走緩坡前半、曲率自然平緩。
    if requiredEnd > profile.length then requiredEnd = profile.length end
    local span = (requiredEnd - s0) / OV_STEP
    local whole = span - span % 1
    if whole < span then whole = whole + 1 end
    local count = whole + 1
    if count > OV_MAX then return 0, 0, "capacity", 0 end
    if count < 2 then return 0, 0, "invalid", 0 end
    local j = 1
    local pbx, pby = 0, 0
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
        local laneB = clampLane(profile, j, bias, nil, sk)
        local laneS = startLane -- 車現在的橫向，不夾：夾了線就從車不在的地方起步（s025 同族）
        local lane = laneS
        if isFinite(returnLaneStart) and isFinite(returnLaneTarget) then
            local laneEnd = isFinite(returnLaneEnd) and returnLaneEnd or d
            local t2 = (sk - s0) / (laneEnd - s0)
            if t2 < 0 then t2 = 0 elseif t2 > 1 then t2 = 1 end
            t2 = t2 * t2 * (3 - 2 * t2)
            lane = returnLaneStart
                + (clampLane(profile, j, returnLaneTarget, targetKeep, sk) - returnLaneStart) * t2
        elseif sk > a and sk < d then
            local t2
            if sk < b then
                t2 = (sk - a) / (b - a)
                t2 = t2 * t2 * (3 - 2 * t2)
                lane = laneS + (l - laneS) * t2
            elseif sk > c then
                t2 = (d - sk) / (d - c)
                t2 = t2 * t2 * (3 - 2 * t2)
                lane = laneB + (l - laneB) * t2
            else
                lane = l
            end
        elseif sk >= d then
            lane = laneB
        end
        outX[k] = bx - sin(h) * lane
        outY[k] = by + cos(h) * lane
        -- 摺疊檢查（OV_MIN_ADVANCE）：線的位移投影到路線弦方向，除以路線弦長²＝前進比例；橫向換道
        -- 的位移與弦正交不計入。最後一格可能只有幾公分，太短的弦不量。
        if k > 1 then
            local ex, ey = bx - pbx, by - pby
            local e2 = ex * ex + ey * ey
            if e2 > 1e-4 and (outX[k] - outX[k - 1]) * ex + (outY[k] - outY[k - 1]) * ey
                    < OV_MIN_ADVANCE * e2 then
                return 0, 0, "fold", 0
            end
        end
        pbx, pby = bx, by
    end
    return count, s0, "ok", requiredEnd
end

-- Completed-snapshot proof line for the actual lane-biased smoothed profile.
-- keep＝同 control 的 state.laneKeep（nil＝LANE_BIAS_KEEP）：證明線必須是車真正在開的那條。
function MDADFollower.buildLaneLine(profile, s0, s1, lane, outX, outY, startIdx, outSeg, keep)
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
        local laneJ = clampLane(profile, j, lane, keep, sk)
        outX[k] = px[j] + (px[j + 1] - px[j]) * t - sin(h) * laneJ
        if type(outSeg) == "table" then outSeg[k] = j end
        outY[k] = py[j] + (py[j + 1] - py[j]) * t + cos(h) * laneJ
    end
    return count, s0, "ok", j
end

-- targetKeep（第 9 參）同 buildOffsetLine 第 15 參：RETURN 目標省略（留 keep，與 control
-- 同格）；crawl-exact（目標＝車現在的橫向、沿現偏移直行）傳 0，只夾物理餘裕。
function MDADFollower.buildReturnLine(profile, s0, s1, laneStart, laneTarget,
        outX, outY, tailM, targetKeep)
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
        laneTarget, laneTarget, outX, outY, laneStart, laneTarget, s1, nil, targetKeep)
end

-- Build-time block tree query: at most 62 edge segments plus O(log blocks),
-- allocation-free and independent of total tiny-segment count.
local function rangeQuery(profile, first, last)
    local brake, lat, coast = RANGE_INF, RANGE_INF, RANGE_INF
    while first <= last and (first - 1) % RANGE_BLOCK ~= 0 do -- kahlua-mod-ok: first >= 1
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
        if profile.segStopCoast and profile.segStopCoast[i] > coast then profile.segStopCoast[i] = coast end
        if profile.segStopBrake and profile.segStopBrake[i] > brake then profile.segStopBrake[i] = brake end
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
