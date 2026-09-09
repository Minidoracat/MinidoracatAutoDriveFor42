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
-- * 幾何：折線＋累積弧長 s。投影只在 [idx-SEARCH_BACK, idx+SEARCH_FWD] 的窗口內找，
--   全域最近點搜尋在自我交叉的路線（回頭路、繞圈）上會把進度瞬移到另一段。
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
-- 因此全部庫函式在載入期取成 local upvalue；夾限一律用純 Lua 比較，不呼叫
-- math.max/min；control() 每幀只剩 cos/sin/atan2 三次跨界，sqrt 全在建表期。

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
-- 弧段前饋（2026-09-08 s041/s045/s025/s034：同一個 R≈11 左彎四台車全撞外側路緣——切線
-- 追蹤把姿態誤差壓到 0.2 rad、cross-track 對 1m 外漂只給 0.18，純回饋要靠誤差累積才出力，
-- yaw 率一路只有需求的 75-80%、lat 從 1.0 漂到 2.0）。弧上的需求 yaw 率 v·κ 是已知量：
-- steer_ff = CURVE_FF_FRAC · v·κ / yawGain。yawGain（rad/s 每單位 steer）**線上估計**——
-- 十三場 telemetry 的 yaw率/(steer·v) 中位數：RaceCar／救護車 24 km/h 0.16-0.21、F350 23 km/h
-- 0.10-0.12、F350 39 km/h 0.03（隨車重、車長、速度差六倍，固定常數不可能對）；估計器＝
-- 上幀施出的 steer（Driver 回寫 appliedSteer，含 cross-track 與夾限）對本幀 yaw 率的比值
-- EWMA（τ 0.5s、只在 |steer| ≥ 0.3、v ≥ 8 km/h 更新、夾 [0.2, 3]）。FRAC 0.7 給七成、剩下回饋
-- 補；前饋偏大時切線／cross-track 反向抵銷。INIT 0.8 貼重車（F350 24 km/h 0.77；RaceCar 1.3
-- 只多付 0.5s 收斂的 0.1-0.2m 切內）。進弧前 LEAD 秒線性爬升（一階 yaw
-- 延遲 τ≈0.35：進弧那刻 yaw 率才從 0 起步＝前 3m 必外漂）。
-- 離線閉環（test_follower 情境 25 的 plant，KPS 0.05-0.3）：K0.10 外漂 1.57→0.44、K0.15
-- 0.67→0.23、K0.20 0.25→0.05（切內 0.10）；FRAC 0.8 在 K0.2 切內 0.21、1.0 在 K0.15 就 0.37。
local CURVE_FF_FRAC = 0.7
local CURVE_FF_LEAD_S = 0.35
local CURVE_FF_MAX = 0.8 -- 小增益長車不能用倒數把前饋放大成整車橫推；回饋仍保留完整權威。
local YAW_GAIN_INIT = 0.8
local YAW_GAIN_TAU_S = 0.5
local YAW_GAIN_MIN_STEER = 0.3
local YAW_GAIN_MIN_KMH = 8
local YAW_GAIN_LO, YAW_GAIN_HI = 0.2, 3.0
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
-- 切出路面由 contact／繞行兜底；MIN_SPEED 地板照舊。
local TURN_GEOM_MIN_RAD = 10 * PI / 180
local SEARCH_FWD = 12         -- 往前 12 段
local REWIND_MAX = 1          -- 單幀最多允許倒退 1 段
local OV_STEP = 1.0           -- M6 世界 offset 折線的取樣步距（公尺）
local OV_MAX = MDADDynamics.PERCEPTION_HARD_MAX_M + 16 -- 額外容納車身前伸、端點與短回线
local LANE_MAX = MDADDynamics.PERCEPTION_HARD_MAX_M + 2 -- 1m證明線；剖面弧段同為1m取樣
-- Driver 以 OV_STEP 反推掃掠弧長，兩者必須同源。
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
MDADFollower.STYLES = {
    brisk = { name = "brisk", lat = LAT_ACCEL, brake = BRAKE, coast = 3.0,
        turnSoft = TURN_SOFT_RAD, turnHard = TURN_HARD_RAD, turnHardMs = TURN_HARD_MS },
    comfort = { name = "comfort", lat = 2.5, brake = 3.0, coast = 0.45,
        turnSoft = 25 * PI / 180, turnHard = 50 * PI / 180, turnHardMs = 30 / 3.6 },
}

-- 初始化與換檔共用；呼叫端隨後重填動力預算、重建速度表，保留承諾線與投影位置。
function MDADFollower.setStyle(profile, style)
    profile.styleName = style.name
    profile.styleLat, profile.styleBrake, profile.styleCoast =
        style.lat, style.brake, style.coast
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
local LANE_BLEND_M = 12
local LANE_BLEND_WALK_MAX = 32 -- 以 run 計（同餘裕的連續段＝一個 run；12m 內超過 32 個不同餘裕的 run 才截斷）
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
    -- 因子以「同值 run」為單位（連續弧段全是 0＝一個 run，只算最近那一段的距離）：逐段各乘一次
    -- 會把 12 段 0 的弧乘成 0.5^12（第一版 ramp 中點只剩 0.02）。走訪逐 run 跳（buildLaneRoom 的
    -- 端點表；無表＝逐段），走訪上限也以 run 計——逐段計數在 0.25m 碎段會在 12m 內截斷，因子隨
    -- 車位突然出現＝段界跳變。同餘裕不同 run 若夾值相同仍只乘一次（runAk）。
    local k, walked, runAk = (runEnd and runEnd[j] or j) + 1, 0, aOwn
    while k <= n - 1 and walked < LANE_BLEND_WALK_MAX do
        local d = ss[k] - sAt
        if d >= LANE_BLEND_M then break end
        local vk = clampLaneRaw(p, k, lane, keep)
        local ak = vk < 0 and -vk or vk
        if ak ~= runAk then
            runAk = ak
            if ak < aLane then
                local t = d / LANE_BLEND_M
                if t < 0 then t = 0 end
                t = t * t * (3 - 2 * t)
                gain = gain * (ak + (aLane - ak) * t) / aLane
            end
        end
        k = (runEnd and runEnd[k] or k) + 1
        walked = walked + 1
    end
    k, walked, runAk = (runStart and runStart[j] or j) - 1, 0, aOwn
    while k >= 1 and walked < LANE_BLEND_WALK_MAX do
        local d = sAt - ss[k + 1]
        if d >= LANE_BLEND_M then break end
        local vk = clampLaneRaw(p, k, lane, keep)
        local ak = vk < 0 and -vk or vk
        if ak ~= runAk then
            runAk = ak
            if ak < aLane then
                local t = d / LANE_BLEND_M
                if t < 0 then t = 0 end
                t = t * t * (3 - 2 * t)
                gain = gain * (ak + (aLane - ak) * t) / aLane
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
-- 張表）。profile 未 ready 或無表＝原值。
function MDADFollower.laneBiasAt(profile, bias, segI, sAt)
    if type(profile) ~= "table" or profile.laneRoomR == nil
            or not isFinite(bias) or not isFinite(segI) then return bias end
    segI = segI - segI % 1
    if segI < 1 then segI = 1 elseif segI > profile.n - 1 then segI = profile.n - 1 end
    if not isFinite(sAt) then sAt = nil end
    return clampLane(profile, segI, bias, nil, sAt)
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
            -- 只認「角度合格卻建不出弧」的 fallback；整條因 capacity 退回原始折線（filletReason）
            -- 時每段都標 FALLBACK 但幾何無事，走 pure pursuit 式即可
            local fallback = p.filletAdaptive and p.filletReason == nil
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

-- 驗 route 並配置 profile。**唯一**會建 table 的入口。
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
        -- 原始折線退路：點全在 raw 中心線上、segSource 直接對應 raw 段，band
        -- 證明逐點真做仍成立（source 超限路徑本來就是 true；buildFilletPath 的
        -- false 回傳是「弧沒建」不是「帶無效」，兩條退路統一）。
        n, filletN, filletBandValid = buildN, 0, navVersion >= 4
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

    if type(style) ~= "table" or not isFinite(style.lat) then style = MDADFollower.STYLES.brisk end
    local segAccel, segBrake, segCoast, segLat = {}, {}, {}, {}
    for i = 1, n - 1 do
        segAccel[i], segBrake[i], segCoast[i], segLat[i] =
            ACCEL_NOMINAL, style.brake, style.coast, style.lat
    end
    local rangeBlockCount = ((n - 2) - (n - 2) % RANGE_BLOCK) / RANGE_BLOCK + 1
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
                coastV[n] = profile.curveV[n] or profile.maxSpeedMs
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
    local adaptiveW = profile.filletAdaptive == true and profile.filletReason == nil -- capacity 退路整條標 FALLBACK，不鉗
    while j < n - 1 and s[j + 1] < sTarget and walked < LOOKAHEAD_WALK_MAX do
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
                local rel = profile.rMin * tan(dth * 0.5)
                if rel < HAIRPIN_APEX_MIN then rel = HAIRPIN_APEX_MIN
                elseif rel > HAIRPIN_APEX_MAX then rel = HAIRPIN_APEX_MAX end
                if s[j + 1] > sNow + rel then kinkS = s[j + 1]; break end
                state.kinkExitS = s[j + 1]
            end
        end
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
            -- 往回退到與前進走法同一個不變式：s[j] < sTarget ≤ s[j+1]
            while j > bestI and s[j] >= sTarget do j = j - 1 end
        end
    end
    if kinkS ~= nil and sTarget > kinkS then sTarget = kinkS end
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
    bias = clampLane(profile, j, bias, nil, sEff)
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
    local tangentOn = false
    local onArc = profile.filletAdaptive == true
        and (segKindW[bestI] == MDADDynamics.SEG_ARC or segKindW[j] == MDADDynamics.SEG_ARC)
    if (state.trackTangent == true or onArc)
            and (kinkS == nil or sNow + TANGENT_PREVIEW_M < kinkS - OV_BLEND) then
        local q = sNow + TANGENT_PREVIEW_M
        -- ov 線是否蓋住預視點：與 ovUsed（由長前視 sEff 決定）解耦——線尾最後 look 公尺
        -- sEff 已出線、q 仍在線上，弧段仍得追線的切線（出口過渡斜率），不可提前改讀中心線。
        -- 一般繞行也由 q 的覆蓋判斷，不能因長前視已出線而提前改回弦角；折角 >15° 仍退前視點。
        if ovUsed and q < state.ovS0 then q = state.ovS0 end
        local ovCover = ovN >= 2 and isFinite(ovEndS) and q >= state.ovS0 and q <= ovEndS
        local useOv = ovCover and onArc
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
            vx, vy = cos(hq), sin(hq)
            tangentOn = true
        end
    end
    local err = atan2(fx * vy - fy * vx, fx * vx + fy * vy)
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
        local coast = profile.segCoast[bestI] or 0.6
        local runtimeBrake, runtimeCoast =
            state.brakeSafe, state.coastSafe
        if isFinite(runtimeBrake) and runtimeBrake >= 0 and runtimeBrake < brake then
            brake = runtimeBrake
        end
        if isFinite(runtimeCoast) and runtimeCoast >= 0 and runtimeCoast < coast then
            coast = runtimeCoast
        end
        local coastNext = profile.coastV[bestI + 1] or profile.maxSpeedMs
        local brakeNext = profile.brakeV[bestI + 1] or 0
        local coastLim = sqrt(coastNext * coastNext + 2 * coast * remainI)
        local stopLim = sqrt(brakeNext * brakeNext + 2 * brake * remainI)
        targetSpeed = coastLim
        if stopLim < targetSpeed then targetSpeed = stopLim end
        if targetSpeed > profile.maxSpeedMs then targetSpeed = profile.maxSpeedMs end
        local curveHardActive = profile.segKind[bestI] == MDADDynamics.SEG_ARC
        local actualKappa = 0
        if curveHardActive then
            actualKappa = profile.kappa[bestI] or 0
            local nextKappa = profile.kappa[bestI + 1] or 0
            if nextKappa > actualKappa then actualKappa = nextKappa end
            -- 行駛線不是中心線：往彎內側偏 lt 的線半徑＝R−lt（κ/(1−lt·κ)），承諾線在
            -- 保持段沿路平移時尤其如此（0906i 起繞行 κ 只量兩段過渡，弧內側的保持段由
            -- 這裡管）。外側偏移半徑變大，不放寬（中心線帽仍是下限）。右轉（y 向南的
            -- 世界 dθ>0）內側＝右＝+lane。
            if actualKappa > 0 then
                local latHere = lineLat
                if latHere == nil then latHere = clampLane(profile, bestI, bias, nil, sNow) end
                local dth = 0
                if bestI + 1 <= profile.n - 1 then
                    dth = wrapPi(profile.segH[bestI + 1] - profile.segH[bestI])
                elseif bestI >= 2 then
                    dth = wrapPi(profile.segH[bestI] - profile.segH[bestI - 1])
                end
                local inner = dth > 0 and latHere or -latHere
                if inner > 0 then
                    local den = 1 - inner * actualKappa
                    if den < 0.25 then den = 0.25 end
                    actualKappa = actualKappa / den
                end
            end
        end
        local curveCap = profile.maxSpeedMs
        local runtimeLat = state.latSafe
        if isFinite(runtimeLat) and runtimeLat >= 0 and actualKappa > 0 then
            curveCap = sqrt(runtimeLat / actualKappa)
            -- curveSpeedCapKmh 的另一半：內側折算後的 κ 這台車在該速度轉不轉得出來
            -- （建表期只對中心線 κ 算過一次）。轉不出來（0）依「解析公式只壓速不否決」
            -- 壓到曲率地板，不煞停在弧裡。
            if profile.filletAdaptive then
                local steer = MDADDynamics.steeringSpeedCapKmh(actualKappa, profile.wheelbase,
                    profile.delta0Safe, profile.deltaVSafe, profile.vehicleMaxSpeed) * MS_PER_KMH
                if steer < curveCap then curveCap = steer end
            end
            -- 與建表期頂點帽同一下限（geometryStep 的 MIN_SPEED）：即時帽沒有地板時，
            -- w=4 路 R≈3 的圓角＋內側偏移＋學到的 latSafe 會給 9 km/h（2026-09-07 實機
            -- T 字路口 9.1 爬 20m）——剖面自己都允許 12，即時帽不得更低。
            if curveCap < MIN_SPEED_MS then curveCap = MIN_SPEED_MS end
            if curveCap < targetSpeed then targetSpeed = curveCap end
        end
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
                isFinite(state.laneBias) and state.laneBias or 0, nil, sNow)
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
        state.ffSteer = 0
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
            end
        end
        state.prevHeading = heading
        state.yawGain = yawGain
        -- ---- 弧段前饋 ----
        -- 弧的起點 k：進弧前 LEAD 秒線性爬升（出弧前收尾試過，離線閉環差 0.02-0.05m，不做）。
        -- 切線預視本身在弧上就有 KP·κ·PREVIEW 的隱含前饋（誤差＝車前 1.5m 切線與車頭夾角＝
        -- κ·1.5），顯式前饋扣掉它，否則兩份相加＝120% 切內（離線閉環 KPS 0.1 實得 in 0.70）。
        local ff = 0
        if kap and aspeed > 0.5 then
            local k, dist = -1, 0
            if segKindW[bestI] == MDADDynamics.SEG_ARC then
                k = bestI
            else
                local q = bestI + 1
                while q <= j do
                    if segKindW[q] == MDADDynamics.SEG_ARC then
                        k, dist = q, s[q] - sNow
                        break
                    end
                    q = q + 1
                end
            end
            if k >= 1 then
                local v = aspeed * MS_PER_KMH
                local lead = v * CURVE_FF_LEAD_S
                local ramp = 1
                if dist > 0 then ramp = lead > 0 and (1 - dist / lead) or 0 end
                if ramp > 0 then
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
                        dth = wrapPi(profile.segH[k] - profile.segH[k - 1])
                    elseif k + 1 <= n - 1 then
                        dth = wrapPi(profile.segH[k + 1] - profile.segH[k])
                    end
                    if dth < 0 then kk = -kk end
                    ff = CURVE_FF_FRAC * v * kk / yawGain
                    if tangentOn then ff = ff - KP * kk * TANGENT_PREVIEW_M end
                    if ff * kk < 0 then ff = 0 end
                    ff = ff * ramp
                    if ff > CURVE_FF_MAX then ff = CURVE_FF_MAX
                    elseif ff < -CURVE_FF_MAX then ff = -CURVE_FF_MAX end
                    steer = steer + ff
                    if steer > STEER_MAX then steer = STEER_MAX
                    elseif steer < -STEER_MAX then steer = -STEER_MAX end
                end
            end
        end
        state.ffSteer = ff
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
function MDADFollower.resetControl(state)
    if type(state) ~= "table" then return state end
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
    state.ffSteer = 0
    state.prevHeading = nil -- yawGain 是車的性質，跨 cutover／脫困保留；只斷差分
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
        local laneJ = clampLane(profile, j, lane, nil, sk)
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
