-- MDAD_Driver.lua — M3 自駕核心（client-only：radial 開關＋每幀狀態機＋車輛控制）
--
-- 分層：MDAD_Follower.lua（shared，純數學、零 PZ API）算「該轉多少、該開多快」；
-- 本檔只負責 PZ 側——把 follower 的輸出翻成 setRegulator／addImpulse／setForceBrake，
-- 並看守所有失效停止條件。控制律不在這裡，PZ API 不在那裡。
--
-- 熱路徑鐵則（onPlayerUpdate 每幀、每個本機玩家都會進來）：
--   ① 沒有人在自駕＝一次整數比較就 return（sessionCount == 0），零 Java 呼叫。
--   ② 不配置 table／closure／Vector3f.new；轉向向量只走 BaseVehicle 的 thread-local
--      池（allocVector3f／releaseVector3f＝BaseVehicle.java:507-521），alloc 與 release
--      在同一段內成對，中間沒有 early return。
--   ③ 每幀最多一次 addImpulse。BaseVehicle.addImpulse 是**單槽**：同幀第二次呼叫且新
--      向量較長時會 `enable=false` 並把常駐的 impulseFromServer 推回池
--      （BaseVehicle.java:678-689）——結果是這幀完全不施力，還汙染下一幀。
--   ④ 路線／導航目標查詢 250ms 節流；限速剖面建構分幀攤平（每幀最多 128 點）。
--   ⑤ 診斷輸出（getDebug()）：跟線遙測每 1000ms 最多一行，旗標為假時連 string.format
--      都不呼叫。每幀一行會洗爆 console 也吃掉 FPS。
--
-- MP 權威分工：
--   車輛物理仍只在駕駛 client 控制（Bullet 車體不在 dedicated server 模擬），但資源
--   消耗由 server 決定。client 送 GPS `{active}` 與 Auto `{vehicleId,active}` 兩種
--   heartbeat；server 只採 OnClientCommand actor，重驗 onlineID、駕駛座、來源裝置、
--   引擎、電瓶與模組，15 秒 TTL 過期即停算。client 從不送座標、item、電量、油量、
--   倍率或 elapsed time。SP 走同一份 shared registry 直接登記。
--   原版 Vehicles.Update.Battery 照常讓發電機充電；GPS／自駕負載再由 server 相加補扣。

require "MDAD"
require "MDAD_Follower"
require "MDAD_Dynamics"
require "MDAD_VehicleProfile"
require "MDAD_Diagnostics"
require "Vehicles/ISUI/ISVehicleMenu"

MDAD = MDAD or {}

-- 雙載保險：client 目錄的檔案會被引擎自動載入，若別的檔案又 require 本檔，chunk 有機會
-- 執行兩次 → radial wrapper 包兩層（同一片加兩次）、OnPlayerUpdate 註冊兩次（每幀跑兩遍
-- ＝同幀兩次 addImpulse，正好踩中上面 ③ 的單槽陷阱）。整檔以命名空間存在與否守門。
if MDAD.Drive then return end

local Drive = {}
MDAD.Drive = Drive

-- 熱路徑（每幀）用到的庫函式在載入期取成 local upvalue：Kahlua 的庫函式都是
-- JavaFunction，寫 math.sqrt 等於每幀多一次 table 查詢。與 MDAD_Follower.lua
-- 同一條守則（該檔開頭「效能守則（Kahlua）」）。純量夾限／取絕對值一律用比較，
-- 不呼叫 math.abs／math.max／math.min。
local sqrt = math.sqrt
local sin, cos = math.sin, math.cos
local obbDistanceSq

--------------------------------------------------------------------------------
-- 調校常數
--------------------------------------------------------------------------------

-- Kahlua 的 function 上限是 60 upvalues（Lua 5.1 LUAI_MAXUPVALUES）。stepFollow 是
-- 單一每幀狀態機，把每個常數各自寫成 local 就等於各占一個 upvalue 槽——2026-08-31
-- 實機：新版 Driver 直接 `function at line 3207 has more than 60 upvalues` 編譯失敗，
-- 整個 MDAD.Drive 沒建起來，HUD 每幀吃 nil。非熱幀（掃描輪、blocked、recovery、
-- 診斷）的常數一律掛在這張表上：一個 upvalue 槽承載全部，槽數不再隨常數增長。
-- 每幀都讀的常數（SECONDS_PER_MULT／MULT_*／PROGRESS_*）維持獨立 local，省掉熱路徑
-- 的 table 查詢。載入後只讀不寫（慣例；scripts/verify_mod.py 的 Kahlua 閘門守槽數）。
local TUNE = {}

local ROUTE_REFRESH_MS = 250   -- 導航目標／路線刷新節流（毫秒）
local USAGE_HEARTBEAT_MS = 5000 -- server registry TTL=15s；start/stop 另有即時封包
local USAGE_FIRST_RETRY_MS = 1100 -- 初始封包被 server 1s flood gate 吃掉時快速自癒
-- 目標消失時的「抵達接管」半徑（世界格，平方比較）：主 MOD 在玩家距目標
-- NAV_ARRIVE_DIST（5 格）內會**自動清除**導航目標（小地圖的「走到旗子就收旗」，
-- MinidoracatMiniMap.lua navCheckArrival，每幀跑）；自駕的到達判定（follower
-- reached：沿線開完＋停妥）比它嚴——正常開到目的地時目標必先被主 MOD 收走，
-- 250ms 路線刷新讀到「沒目標」就誤報紅字「路線遺失」（2026-08-28 實機：到站
-- 閃紅字，玩家分不清是到達還是 bug）。半徑 12＝5（主 MOD 清除圈）＋250ms 內
-- 最高速位移（40km/h≈2.8 格）＋路線終點對目標的投影偏差餘裕。
local ARRIVE_CLEAR_SQ = 12 * 12
local BUILD_BUDGET = 128       -- 每幀限速剖面建構點數上限
local MAX_SESSIONS = 4         -- 分割畫面本機玩家槽上限（getSpecificPlayer 0-3）
local YIELD_RESUME_MS = 2000   -- 讓位後連續無輸入這麼久才恢復自駕（恢復時另有頭上提示）
-- 大誤差（>90°，調頭類）的速度閘：超過此速**主動煞停**（不只鬆油滑行），
-- 近停後才開始原地旋轉。帶動量旋轉＝漂移——實機兩代教訓：53 km/h 吃飽和側推
-- 整台車甩飛（2026-08-28 yield 恢復）；舊值 20 允許 12-20 km/h 帶動量開轉，
-- 原地轉＋動量把車甩出 22m 草地（st 88,113 遙測 lat 10→22.6）。
TUNE.ROTATE_SPIN_MAX_KMH = 5
TUNE.ROTATE_ERR_RAD = 1.5708   -- 90°
-- 調頭力矩縮放：耦力模式的力量乘這個值。跟線橫推的量級是為了對抗高速輪胎自回正
-- 標定的，原地調頭阻力小得多，全額力矩＝原地快速旋轉（實機回報「快速循轉」），
-- 收到 0.4 讓調頭變成緩慢平穩的迴轉。過慢調大、仍太快調小。
local ROTATE_FORCE_SCALE = 0.4
local OVERSPEED_BRAKE = 15     -- 現速超出目標速這麼多 km/h 就主動煞（regulator 只會鬆油門）
local STEER_INPUT_EPS = 0.01   -- getCurrentSteering 視為「玩家在轉」的門檻
local STEER_DEADZONE = 0.1     -- follower steer（±5）的死區：低於此值不施力（免無謂抖動）

-- getMultiplier() → 真實秒數。getThirtyFPSMultiplier()＝getMultiplier()/1.6 是
-- 「以 30fps 為基準的幀數」（GameTime.java:1032-1034），再除以 30 即為秒；
-- 1/(1.6*30) = 1/48。正常遊戲速度下這正好等於 getRealworldSecondsSinceLastUpdate()
-- （GameTime.java:192-193，fpsMultiplier = 60/fps＝FPSTracking.java:39），
-- 但走 multiplier 的好處是時間加速／慢動作也一致（dt 與施力用同一個係數）。
local SECONDS_PER_MULT = 1 / 48
local MULT_MIN, MULT_MAX = 0.5, 3.0 -- 掉幀尖峰／睡眠加速（getMultiplier 可到 200）時夾住

-- 轉向力模型（側向橫推）。addImpulse 會做兩件事：對質心施加 impulse 向量的中心力，
-- 再施加 relPos × impulse 的力矩（BaseVehicle.java:3311-3313）。
-- 令世界水平面 (X,Y) 對應 Bullet 的 (x,z)（setX←origin.x、setY←origin.z＝
-- BaseVehicle.java:3325-3326；forward 取 basis 第 2 欄後用 .x/.z＝
-- CarController.java:405-416 的原版讀法），f＝單位前向、p＝f 逆時針轉 90° 的側向：
--   relPos  = -REAR_ARM*f + q*LATERAL_JITTER*p   （q＝±1 的幀奇偶）
--   impulse = d*F*p                              （d＝sign(steer)*STEER_SIGN）
--   torque_y = relPos.z*imp.x - relPos.x*imp.z = d*F*REAR_ARM（q 項相消，與奇偶無關）
-- 語義：**橫推車尾**。中心力是純側向（與前向點積恆 0，不干擾 regulator 控速），
-- 且全幅存在、不做幀間抵消——車尾被持續往彎外推、車頭指進彎內，同時整車獲得的
-- 側向動量被輪胎橫向摩擦消化成偏航。這是 PZ 的 Bullet 輪胎模型下唯一夠力的轉法：
-- 2026-08-28 兩輪實機 telemetry 證明「縱向衝量×0.8m 側臂」的純力矩模型在飽和轉向下
-- 只換到每秒 5-9° 的偏航（輪胎自回正整個吃掉），過路口需要 ~60°/s，差一個數量級；
-- 幾何（2.2m 車尾臂＋側向衝量）與量級標定採 Derpy Autodrive 在整個 Workshop 用戶群
-- 驗證過的工程事實（Workshop 3775160975，map_nav.lua:7862-7905）：
--   F = |steer| * STEER_STRENGTH * base
--   base = (MASS_K * mass * min(|v|,SPEED_CAP)² + MASS_BASE * mass) * IMPULSE_SCALE
--          * mult / MULT_NORM
-- 實作（池向量、幀奇偶、正規化、防呆、每幀一次 addImpulse）全部自寫。
-- q*LATERAL_JITTER 讓施力點在車尾左右兩角交替（對力矩零貢獻——q 項在外積中相消；
-- 對中心力也零貢獻——它只動施力點），避免每幀對同一點施力的數值共振。
-- 繞 +y 軸的正向旋轉會讓 (x,z) 向量順時針轉（x'=x·cosθ+z·sinθ），即 heading 變小；
-- torque_y = d*F*REAR_ARM，要 heading 變大（follower 的 steer > 0）需 torque_y < 0
-- ⇒ d < 0 ⇒ STEER_SIGN 取 -1（p 已是 CCW 側向）。實機若左右相反，只改 STEER_SIGN。
local STEER_SIGN = -1
local REAR_ARM = 2.2           -- legacy fallback；adaptive session 改用 vehicleProfile.rearArm
local LATERAL_JITTER = 0.5     -- 施力點左右交替的擺幅（公尺）：防共振，不進力矩

-- 量級（Derpy 標定值照搬，STEER_STRENGTH=1.0 即原量級；telemetry 顯示轉不動才調大、
-- 甩尾才調小）。MASS_BASE 給 0 km/h 的基礎權威（原地掉頭靠它），MASS_K*v² 隨速度
-- 補償輪胎自回正的增強；速度先取絕對值再封頂（比較，不呼叫 math.min），倒車與
-- 超速都不會發散。MULT_NORM＝60fps 的 getMultiplier（0.8），把「每幀衝量」正規化
-- 成幀率無關；30 km/h／1200 kg／飽和轉向在 60fps 下 F ≈ 50,100（×2.2m 臂）。
local STEER_STRENGTH = 1.0     -- 主要調校旋鈕（過大＝甩尾、過小＝轉不動）
local MASS_K = 0.00015         -- 每 (km/h)² 的質量係數
local MASS_BASE = 0.7          -- 靜止基礎係數
local SPEED_CAP_KMH = 60       -- 量級採計的速度上限（km/h）
local IMPULSE_SCALE = 10       -- 質量→衝量的換算尺度（addImpulse 吃的是衝量不是力）
local MULT_NORM = 0.8          -- 60fps 的 getMultiplier 基準

-- 刻意不加 downforce：addImpulse 只有一組向量，impulse 若帶垂直分量，
-- relPos（水平）× impulse（垂直）會產生**翻滾／俯仰**力矩而不只是壓車，
-- 高速時等於自己把車掀翻。要壓車得另闢 API，不在 M3 範圍。

-- 單一進度監督取代舊的低速 stuck 與高速 push 雙 watchdog。需求成立後，
-- 世界位移／沿線進度／偏航任一達標就重臂；2.5 秒皆無才進 suspect。
local PROGRESS_MS = 2500
local PROGRESS_M_SQ = 1
local PROGRESS_S = 1
local PROGRESS_YAW = 0.17453292519943 -- 10°
TUNE.GEAR_RESET_MS = 150
TUNE.VERIFY_MS = 2000
local SETTLE_MS = 4000

-- M4 感知與繞行（Sensor 掃走廊 → Corridor 算縫隙 → follower.setOffset 疊側偏；
-- 三層相依見 MDAD_Sensor.lua 檔頭）。速度上限檔位：全部是「疊在剖面之上的 min」，
-- 不改剖面本身；殭屍／屍體檔位受三態沙盒政策×玩家偏好控制（refreshPolicies）。
local NEED_HALF = 1.4          -- legacy fallback；adaptive session 改用 profile.needHalf
local DODGE_CAP = 24           -- 繞行 entry／exit 基準速度；保持段另放寬到 28 km/h
TUNE.ZOMBIE_CAP_1 = 25         -- 走廊內 ≥1 隻殭屍
TUNE.ZOMBIE_CAP_4 = 15         -- ≥4 隻
TUNE.ZOMBIE_CAP_8 = 10         -- ≥8 隻
TUNE.MOVING_VEH_CAP = 15       -- 走廊內有行進中的別台車（跟車，不繞行）
TUNE.UNLOADED_CAP = 15         -- 走廊內有未載入 chunk（不知道前面有什麼，先慢）
local POLICY_DODGE = 1         -- 沙盒 ObstaclePolicy enum：1=繞行 2=停車

TUNE.BLOCK_STOP_DIST = 15      -- 距障礙群這麼近才煞停等待；更遠先滑行接近
TUNE.BLOCK_APPROACH_KMH = 12   -- blocked 接近段的速度上限（掃描逼近後縫隙判定更準）
TUNE.WAIT_TIMEOUT_MS = 20000   -- 停等（blocked/跟車 0）獨立超時：紅字請玩家接手
-- recovery 方向探測與 episode 重臂。rear 每 100ms 重查；成功倒退後 ban
-- 跨 sensor reset／same-target route cutover 保留，前進 10m 且兩輪 footprint clear 才清。
local REAR_PROBE_MS = 100
local REAR_TRAVEL_M = 4
local EPISODE_REARM_SQ = 100
TUNE.SCAN_WARM_CAP = 12        -- 感知空窗（首輪掃描未完成）的爬行上限
-- 堵死改道（nav API v3 requestDetour）：blocked 停等一段時間仍未解除，就帶
-- 堵點座標請主 MOD 重算避讓路線（A* 對經過堵點圈的路網邊加軟封鎖罰）。
local DETOUR_AFTER_MS = 4000   -- blocked 停等多久後嘗試改道（< WAIT_TIMEOUT 20s）
local DETOUR_AVOID_R = 12      -- 堵點避讓半徑（公尺）：蓋住路口級障礙群
local DETOUR_FAIL_LEN = 90000  -- detour 路線長 ≥ 此值＝吃了軟封鎖罰硬走原路（沒繞開）
-- 候選枚舉與爬行檔（codex 對抗審方案 6，2026-08-29 路口實測落地）：
-- 舊版 sweep 打槍只 retry 一次就 blocked，更遠的可行縫從沒被試過。改為
-- 單輪內 ban→重規劃→world sweep 枚舉；普通／彎道檔全敗後 plan 與 sweep
-- **對稱**縮到爬行檔重枚舉（契約一致，非單邊放寬）、速度壓 SQUEEZE_CAP。
local DODGE_CANDIDATES = 3     -- 每檔位最多枚舉幾條候選縫
local SQUEEZE_NEED = 1.2       -- legacy fallback；adaptive＝halfW+0.25
local SQUEEZE_CAP = 10         -- 爬行檔速度上限（km/h；2026-08-29 使用者裁定 6 過慢）
local SWEEP_BASE = 1.3         -- legacy fallback；adaptive＝needHalf-0.1
local SWEEP_PHYS_PAD = 0.05    -- baseline 段（a 之前＝路線本身）只驗物理必撞：車身
                               -- OBB 之外只留這麼多餘裕，不套規劃檔位的淨距
TUNE.SWEEP_QUANT_COMP = 0.1   -- 整格障礙圓近似比 1x1 方格角落多出的量化肥邊
-- 幾何投影誤差下限（2026-08-28 對抗審定案）；低於此縫寬必須拒絕而非減速掩蓋。
TUNE.DODGE_CLEARANCE_RESERVE = 0.4
TUNE.DODGE_OV_SPAN = 93       -- OV_MAX=96，保留起點／d+1／防呆三格
local CORNER_NEAR = 8          -- sweep 失敗點離折點多近算「折點衝突」（BLOCKED_CORNER 判定）
local CORNER_DETOUR_MS = 2500  -- BLOCKED_CORNER 的改道等待（近距重枚舉也失敗才走）
local CORNER_RETRY_DIST = 3    -- corner latch 撤銷距離：漸進接近讓車前進這麼多＝
                               -- 幾何已變、重新枚舉——實測「靠很近開導航就能繞」
                               -- ＝近距下折點幾何退化成直路障礙，把手動流程自動化
TUNE.CORNER_STOP_DIST = 8      -- corner 下的煞停線（普通 blocked 15m）：爬更近再停，
                               -- 給近距重枚舉創造與「近開導航」相同的幾何條件
local CURVE_LEAD = 8           -- 過渡段要在折點前多遠完成（公尺）：進彎前把側移
                               -- 做完、彎中全程保持目標線——過渡線切折角掃到彎
                               -- 外側障礙是 2026-08-29 路口七連殺的幾何根因
-- 路面對中（sensor 每輪產出 roadC＝路面帶中心相對 nav 線的橫向偏移）：
-- streets.xml 的 nav 線只有「世界地圖畫線」精度（實測偏 2-4m），行駛線＝
-- 沙盒靠右偏置＋EMA 平滑後的路面校正。無樣本（路口外／無路面）時衰減回 0。
TUNE.ROAD_EMA = 0.25           -- 每輪（250ms）向新樣本收斂的比例（時常數 ~1s）
TUNE.ROAD_DECAY = 0.85         -- 無樣本輪的衰減係數
TUNE.ROAD_CLAMP = 3            -- 單輪樣本與累積校正的限幅（公尺）
TUNE.BIAS_MAX = 3              -- 路面校正／RETURN laneTarget 的絕對限幅（公尺）
TUNE.SOFT_CAP = 20             -- 走廊內有可輾過的軟障礙（家具／雜物）時的速度上限
TUNE.CORPSE_CAP = 20           -- 走廊內有地面屍體（壓得過，但不減速輾過的體感就是撞擊）
-- RETURN 進入門檻由 v4 segWidth 與實際車寬推導；v2/v3 width unknown 使用
-- available=2m。physical isDoingOffroad 只作 paved/actual mismatch 輔證，永不單觸發。
TUNE.RETURN_CAP = 15           -- 已驗證回線軌跡的速度上限（km/h）
TUNE.RETURN_UNSAFE_CAP = 8     -- trajectory unsafe/unloaded：沿現 lane 平行前進
local RETURN_CLEAR_DEV = 0.75  -- 回到 target lane 的釋放偏差（m；快照連續兩輪）
-- 原地調頭的車周安全探測：adaptive probe=max(現有4m, profile.probeR)。
local ROTATE_PROBE_R = 4
local CLEAR_STREAK_N = 2       -- 繞行/堵住要連續這麼多輪 clear 才解除（掃描窗漂移防抖）
TUNE.ROTATE_PROBE_MS = 500
local MASS_REFRESH_MS = 1000   -- BaseVehicle.getMass cold refresh；熱幀只做時戳比較
local MASS_VALID_LO, MASS_VALID_HI = 200, 5000 -- getMass 可信區間（kg）
local MASS_FALLBACK = 1200     -- 區間外／讀取失敗時沿用的標定車質量（kg）
TUNE.ASSIST_MASS_MIN = 1300
TUNE.ASSIST_MAX_ERR_RAD = 20 * math.pi / 180
-- 高速誤差護欄：>70 的目標速度按航向誤差線性折返回 70（誤差 0＝滿速、
-- ≥10°＝70）。轉向標定 ≤70；沙盒 ≤70 時零作用。
local HS_BASE_KMH = 70
local HS_ERR_RAD = 0.1745      -- 10°

-- 感知閉環的標準／高速組態分界：標準掃描帶前伸 48m，一輪最慢約 200ms，
-- 再受 250ms 啟動節流影響；85 km/h 是既有標準組態的保守相容上限與高速檔
-- 啟用門檻，不宣稱是所有載具／路況的形式化煞停證明。沙盒上限超過 85 時，
-- session 會把掃描帶改成 110m、感知上限改成 120；兩者必須一起切換。
TUNE.PERCEPTION_CAP_KMH = 85
-- 高速檔（2026-08-29 使用者需求：瘋狂檔要能跑 120）：沙盒上限 > 85 時把掃描
-- 帶拉到 110m、感知上限放到 120——120 km/h 煞停 ~56m＋輪距反應 ~21m ≈ 77m
-- < 110 ✓。帶長只影響輪完成時間（分幀 budget 不變、fps 成本相同），障礙密集
-- 區速度自然壓低。由 session 依沙盒一次決定，不隨車速抖動。
local HISPEED_AHEAD_M = 110
local HISPEED_CAP_KMH = 120

-- 速度檔位（M5.5，特斯拉命名；per-player、存 player modData）。值＝直路巡航
-- 上限 km/h；-1＝瘋狂檔：直接吃載具極速 vehicle:getMaxSpeed()（BaseVehicle.java:
-- 8467-8470 回 this.maxSpeed、init 自 script maxSpeed :882；km/h 尺度用例
-- ISVehicleRegulator.lua:27 直接與 regulator 速度相加減）。有效上限＝
-- min(檔位, 沙盒 AutoDriveMaxSpeed)——瘋狂檔高於沙盒時由剖面本身壓住
-- （begin 用沙盒值建 maxSpeed），檔位 cap 只往下壓，不能抬高沙盒天花板。
-- 檔位不動安全機制：曲率／折點限速、誤差減速、繞行 cap、終點制動照常。
local GEAR_CAPS = { 30, 50, 70, -1 }
local GEAR_KEYS = {
    "UI_MinidoracatAutoDrive_GearChill",
    "UI_MinidoracatAutoDrive_GearStandard",
    "UI_MinidoracatAutoDrive_GearSport",
    "UI_MinidoracatAutoDrive_GearInsane",
}
local GEAR_DEFAULT = 3         -- 未設定→運動 70＝舊版固定上限，升級不無聲降速
local GEAR_MD_KEY = "MDADGear"
local PREF_ZOMBIE_MD = "MDADZombieSlow" -- player modData：false＝這位玩家不為殭屍減速
local PREF_CORPSE_MD = "MDADCorpseSlow" -- 同上，屍體
-- 彎道繞行（不禁止，算進去）：轉彎時車體掃掠比車寬寬（內輪差），pure pursuit
-- 追偏移前視點又會切內彎——障礙群落在累計轉角超過 CURVE_TIGHT_RAD 的彎道段時，
-- 縫隙判定改用放大的需求半寬重算（過不了自然 blocked；過得了＝真有寬縫，安全繞），
-- 且繞行速度壓到爬行（2026-08-28 實機：轉彎處繞行擦撞）。
local CURVE_TIGHT_RAD = 0.44   -- ≈25°：障礙群所在路段的累計轉角門檻
local CURVE_NEED_EXTRA = 0.6   -- 彎道繞行的需求半寬加碼（內輪差＋切內彎的一階補償）
local DODGE_TIGHT_CAP = 16     -- 彎道 a..b 上限；b..c 為 20，c..d 已過折點後回 24
-- 繞行線的世界空間掃掠複驗：沿剖面每 SWEEP_STEP 公尺取繞行線世界點，對每個硬
-- 障礙的**世界座標**驗最小淨距。弧座標 (s,l) 在路線折點附近的障礙表示會失真
-- （膨脹點沿弧線展開、世界位置偏離實體數米），縫隙判定「判得過但實際會撞」——
-- 2026-08-28 實機：路口左轉繞皮卡直接撞上。世界座標怎麼失真都騙不過這一驗；
-- 直路彎路統一驗，是 setOffset 前的最後防線。
local SWEEP_STEP = 2
-- 掃掠淨距為逐點計算：車半寬 0.9＋該點半徑（sen.hardR：樹幹 0、整格物 0.7）
-- ＋pursuit 誤差餘裕 0.4——見 sweepClear 內的 clr。
-- 倒車脫困（unstick）：卡死時 regulator 不會倒車（CarController 只向前供油），
-- 改用向後衝量直接推車（Derpy towing 同法：relPos=(0,0,0) 純中心力，
-- map_nav.lua:7847-7850 的工程事實）。退夠距離或超時就收手。
local UNSTICK_MS = 4000        -- 單次脫困的時間上限
local UNSTICK_DIST_SQ = 9      -- 退離卡點 3 公尺（平方比較省 sqrt）＝成功
local UNSTICK_PUSH = 1.2       -- 向後衝量 = PUSH * MASS_BASE * mass * IMPULSE_SCALE * mult/MULT_NORM
local UNSTICK_MAX = 3          -- 連續脫困次數上限：沒真正前進就不再試，直接紅字停車
local UNSTICK_PROGRESS = 10    -- 沿線前進超過這距離（公尺）就重置脫困計數

--------------------------------------------------------------------------------
-- 小工具
--------------------------------------------------------------------------------

local KEY_NEED_MODULE = "UI_MinidoracatAutoDrive_NeedModule"
local KEY_ROUTE = "UI_MinidoracatAutoDrive_RouteNotReady"
local KEY_LOST = "UI_MinidoracatAutoDrive_LostRoute"
local KEY_NOT_DRIVER = "UI_MinidoracatAutoDrive_NotDriver"
local KEY_ENGINE = "UI_MinidoracatAutoDrive_EngineOff"
local KEY_API = "UI_MinidoracatAutoDrive_NavApiMissing"
local KEY_UNSUPPORTED = "UI_MinidoracatAutoDrive_UnsupportedVehicle"
local KEY_STUCK = "UI_MinidoracatAutoDrive_StopStuck"
local KEY_BLOCKED = "UI_MinidoracatAutoDrive_Blocked"
local KEY_UNSTICK = "UI_MinidoracatAutoDrive_Unstick"
local KEY_DODGE = "UI_MinidoracatAutoDrive_Dodge"
local KEY_DETOUR = "UI_MinidoracatAutoDrive_Detour"

-- 診斷輸出（只在 getDebug() 為真時存在）。實機回報「按了關閉但車還在跑」時，唯一能
-- 分辨「session 沒關」與「只是慣性滑行」的證據就是這幾行；跟線那行必須節流，每幀
-- 一行會直接把 console 洗爆並吃掉 FPS。getDebug()＝Core 的除錯模式旗標，原版到處
-- 這樣守門；旗標為假時下面所有 string.format／print 連碰都不碰。
local LOG = "[MDAD Drive] "
TUNE.DEBUG_MS = 1000           -- 跟線診斷的最小間隔（毫秒）
TUNE.DEG_PER_RAD = 180 / 3.14159265358979

-- HaloTextHelper.addBadText／addGoodText 用例：ISVehiclePartMenu.lua:252、ISReadABook.lua:95
local function haloBad(playerObj, key)
    HaloTextHelper.addBadText(playerObj, getText(key))
end

local function haloGood(playerObj, key)
    HaloTextHelper.addGoodText(playerObj, getText(key))
end

local function maxSpeedKmh()
    local v = MDAD.sandbox("AutoDriveMaxSpeed", 70)
    if type(v) ~= "number" then v = 70 end
    if v < 5 then v = 5 end
    if v > 120 then v = 120 end
    return v
end

-- 主 MOD 的導航查詢面：v2 才有 getNavTarget（自駕核心的最低需求）。
-- 每次用前重查全域：主 MOD 可能根本沒裝，也可能版本太舊。
local function navApi()
    local api = MinidoracatMiniMapAPI
    if type(api) ~= "table" then return nil end
    local version = api.navApiVersion
    if type(version) ~= "number" or version * 0 ~= 0
            or version < 2 or version % 1 ~= 0 then return nil end
    if type(api.getNavTarget) ~= "function" or type(api.requestRoute) ~= "function" then return nil end
    return api
end

-- 回 (route, tx, ty)（route＝唯讀本體，主 MOD 的 cache；tx,ty＝本次查到的目標）。
-- 失敗：目標不存在回 (nil)；有目標但路線拿不到回 (nil, tx, ty)——呼叫端靠
-- 「tx 是否為 nil」區分兩類（抵達接管只認前者）。route 物件的 identity 就是
-- 版本號：主 MOD 重算路線時會產生新 table（ensureRoute→findRoute 新建，
-- MinidoracatMiniMap_NavRoute.lua:1181-1186），沿用時回同一顆。
local function fetchRoute(api, playerNum)
    local tx, ty = api.getNavTarget(playerNum)
    if not tx then return nil end
    local route, state = api.requestRoute(playerNum, tx, ty)
    if not route or state ~= "ok" then return nil, tx, ty end
    return route, tx, ty
end

-- 自駕先決條件（啟動與每幀共用同一份）。回 nil＝可以開／可以繼續，否則回翻譯鍵。
-- context 直接餵給 MDAD.navGate："draw" 走 1 秒快取（每幀呼叫用），nil 走即時查詢。
local function driveGate(playerObj, vehicle, playerNum, context)
    -- isDriver(chr) ⇔ getSeat(chr)==0（BaseVehicle.java:1853-1864；原版 Lua 閘門
    -- 用例 ISVehicleMenu.lua:87、ISVehicleRegulator.lua:16）
    if not vehicle or not vehicle:isDriver(playerObj) then return KEY_NOT_DRIVER end
    -- 熄火不自駕，也不代客發動（M3 不呼叫 tryStartEngine）。電瓶死掉一併走這條：
    -- 引擎運轉中本來就靠發電機供電，電瓶沒電＝電系已經不成立。
    -- isEngineRunning＝BaseVehicle.java:7639；getBatteryCharge＝VehicleParts.java:152-156
    if not vehicle:isEngineRunning() then return KEY_ENGINE end
    if not MDAD.isBatteryLive(vehicle) then return KEY_ENGINE end
    if MDAD.sandbox("NeedItemForAutoDrive", true) == true and not MDAD.isAutoInstalled(vehicle) then
        return KEY_NEED_MODULE
    end
    -- 導航道具閘門（M2 既有）：沙盒 NeedItemForNav 關閉時 O(1) 放行
    local allowed, reason = MDAD.navGate(playerNum, context)
    if not allowed then return reason or "UI_MinidoracatAutoDrive_NeedGPS" end
    return nil
end

-- HUD 停用態的唯讀原因：沿用啟動守門，context="draw" 讓 GPS 背包掃描吃
-- MDAD.navGate 的 1 秒快取；route 走主 MOD 的 requestRoute cache，只在
-- route/state 已真正可用時顯示「可以啟動」，不建立 follower profile。
function Drive.hudStartReason(playerNum)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return KEY_NOT_DRIVER end
    local reason = driveGate(playerObj, playerObj:getVehicle(), playerNum, "draw")
    if reason then return reason end
    local api = navApi()
    if not api then return KEY_API end
    local route = fetchRoute(api, playerNum)
    if not route then return KEY_ROUTE end
    return nil
end

-- 玩家有沒有在自己操作？有就讓位。
-- getCurrentSteering 由 CarController 每幀從 clientControls 寫入（CarController.java:321、
-- 用例 Vehicles.lua:731），手把的類比轉向也會進到這裡，是唯一跨鍵鼠／手把的轉向觀測點。
-- 油門／煞車沒有等價觀測（Kahlua 讀不到 clientControls 的 Java instance field，
-- 且 isGasPedalPressed 在 regulator 供油時本來就是 true，拿來判人為輸入會永遠成立），
-- 所以改看鍵位（CarController.java:938-942 用的就是這幾個綁定名）。
local function manualInput(vehicle)
    local steering = vehicle:getCurrentSteering()
    if steering > STEER_INPUT_EPS or steering < -STEER_INPUT_EPS then return true end
    if isKeyDown("Left") or isKeyDown("Right") then return true end
    if isKeyDown("Forward") or isKeyDown("Backward") or isKeyDown("Brake") then return true end
    return false
end

--------------------------------------------------------------------------------
-- session（只活在本機記憶體，不存檔、不上伺服器）
--------------------------------------------------------------------------------

local sessions = {}
local sessionCount = 0

function Drive.isActive(playerNum)
    return sessions[playerNum] ~= nil
end

-- Derived read-only control state. `mode` and the orthogonal safety flags remain
-- the only mutable sources; no second transition enum is maintained.
local function controlStateOf(s)
    if not s then return nil end
    local mode = s.mode
    if mode == "arrive" then return "ARRIVE" end
    if mode == "yield" then return "YIELD" end
    if mode == "gear-reset" or mode == "recover"
            or mode == "unstick" or mode == "settle" then return "RECOVER" end
    if s.currentBlocked then return "HOLD" end
    if s.returnHold then return "HOLD" end
    if s.returnActive then return "RETURN" end
    if s.blocked or s.followHold or mode == "build" then return "HOLD" end
    if s.dodging then return "AVOID" end
    return "TRACK"
end

function Drive.controlState(playerNum)
    return controlStateOf(sessions[playerNum])
end

function Drive.invalidateCommandState(s, actualSpeedKmh, controlState)
    if type(s) ~= "table" then return end
    local v = actualSpeedKmh
    if not MDADDynamics.finite(v) then v = 0 elseif v < 0 then v = -v end
    s.cmdV, s.cmdA, s.cmdInitialized = v / 3.6, 0, true
    s.fullGate, s.gateReason, s.alignSince = false, "state", 0
    s.curveVerifiedUntilS = 0
    s.verifyBand, s.verifySweep = false, false
    s.verifyLineReason = "state"
    s.commandControlState = controlState or controlStateOf(s)
    s.jerkBypassReason = nil
end

-- 繞行承諾釋放：這五個旗標永遠一起回到「無承諾」狀態，dodgeNeed 回基準淨距。
-- 不含 clearOffset：剖面何時清由呼叫端時序決定（車還在動時清＝目標線瞬跳）。
local function releaseDodge(s)
    s.dodging = false
    s.dodgeNotified = false
    s.dodgeCrawl = false
    s.dodgeTight = false
    s.dodgeNeed = s.sweepBase
    s.dodgeKappa = 0
    s.dodgeClearance = 0
    s.dodgeCurveCap = 0
    s.dodgeClearanceCap = 0
    s.dodgeVisibilityCap = 0
    s.dodgeSpaceCap = 0
    s.dodgeSpeedCap = 0
    s.dodgeBaseCap = 0
    s.dodgeCapPending = false
    s.dodgeShiftLength = 0
    s.dodgeDesignSpeed = 0
    s.lastOvEndS, s.tmpOvEndS = 0, 0
    s.dodgeCommittedLength = 0
    s.dodgeBuildReason = nil
    s.dodgeBlockReason = nil
    s.dodgeClass = MDADDynamics.DODGE_STATIC
end

--------------------------------------------------------------------------------
-- 速度檔位與減速偏好（per-player；M5.5）
--------------------------------------------------------------------------------

-- 檔位／減速偏好存 player modData，讓角色跨 session 保留 UI 選擇。這只作本機行為與
-- 持久資料；MP 任意 client 可偽造別人的 ObjectModData，資源 billing 一律改讀
-- server actor-bound NavUsage／Usage registry，不把本 table 當權威。
local function playerMd(playerNum)
    local p = getSpecificPlayer(playerNum)
    if not p then return nil end
    return p:getModData()
end

function Drive.getGear(playerNum)
    local md = playerMd(playerNum)
    local g = md and md[GEAR_MD_KEY]
    if g == 1 or g == 2 or g == 3 or g == 4 then return g end
    return GEAR_DEFAULT
end

-- 減速偏好（政策＝由玩家決定時才參與）：只有明確的 false 算關，其他值一律
-- 視為開——預設行為必須與三態化之前（會減速）一致。
local function prefOn(playerNum, mdKey)
    local md = playerMd(playerNum)
    if md and md[mdKey] == false then return false end
    return true
end

-- 這位玩家此刻實際要不要為 kind 減速（政策×偏好合成）
local function slowActive(policyName, playerNum, mdKey)
    local p = MDAD.policy3(policyName, MDAD.POLICY_PLAYER)
    if p == MDAD.POLICY_FORCE_ON then return true end
    if p == MDAD.POLICY_FORCE_OFF then return false end
    return prefOn(playerNum, mdKey)
end

-- 檔位的直路巡航上限（km/h）。瘋狂檔讀載具極速；讀不到（拖車等異常）退
-- 沙盒上限＝等同無檔位 cap，保守方向。
local function gearCapKmh(playerNum, vehicle)
    local cap = GEAR_CAPS[Drive.getGear(playerNum)]
    if cap and cap > 0 then return cap end
    local vm = vehicle and vehicle.getMaxSpeed and vehicle:getMaxSpeed()
    if type(vm) ~= "number" or vm ~= vm or vm <= 0 then return maxSpeedKmh() end
    return vm
end

-- 檔位×沙盒的有效巡航上限；HUD 在 session 尚未啟動時也要顯示同一真相。
function Drive.effectiveCap(playerNum, vehicle)
    local cap = maxSpeedKmh()
    local gearCap = gearCapKmh(playerNum, vehicle)
    if gearCap > 0 and gearCap < cap then cap = gearCap end
    return cap
end

-- 政策快取進 session（250ms 路線刷新節流窗＋set* 即時重算）：殭屍／屍體分支
-- 每幀只讀 boolean，不跨界查 modData／沙盒表。
local function refreshPolicies(s, vehicle, playerNum)
    s.gearCap = gearCapKmh(playerNum, vehicle)
    s.zombieSlow = slowActive("ZombieAreaSlowdown", playerNum, PREF_ZOMBIE_MD)
    s.corpseSlow = slowActive("CorpseSlowdown", playerNum, PREF_CORPSE_MD)
    s.overlayOn = MDAD.sandbox("DebugOverlay", false) == true
end

function Drive.setGear(playerNum, gear)
    if gear ~= 1 and gear ~= 2 and gear ~= 3 and gear ~= 4 then return false end
    local md = playerMd(playerNum)
    if not md then return false end
    md[GEAR_MD_KEY] = gear
    local s = sessions[playerNum]
    if s then refreshPolicies(s, s.vehicle, playerNum) end
    return true
end

-- 循環切檔（radial／HUD 共用入口）。回新檔位 id。
function Drive.cycleGear(playerNum)
    local g = Drive.getGear(playerNum) + 1
    if g > 4 then g = 1 end
    Drive.setGear(playerNum, g)
    return g
end

function Drive.getSlowPref(playerNum, kind)
    return prefOn(playerNum, kind == "corpse" and PREF_CORPSE_MD or PREF_ZOMBIE_MD)
end

function Drive.setSlowPref(playerNum, kind, on)
    local md = playerMd(playerNum)
    if not md then return false end
    md[kind == "corpse" and PREF_CORPSE_MD or PREF_ZOMBIE_MD] = on == true
    local s = sessions[playerNum]
    if s then refreshPolicies(s, s.vehicle, playerNum) end
    return true
end

-- HUD tooltip 的唯讀策略常數；速度 caps 直接回 Driver 使用值，掃描範圍優先讀
-- MDADSensor export。Sensor 尚未自動載入時只退回同值 2/48/3，不讓 HUD 因載入次序炸掉。
function Drive.slowdownInfo(playerNum)
    local sensor = type(MDADSensor) == "table" and MDADSensor or nil
    local nearM = sensor and sensor.SCAN_NEAR or 2
    local baseAhead = sensor and sensor.SCAN_AHEAD or 48
    local bandM = sensor and sensor.SLOW_BAND_HALF or 3
    local ahead = maxSpeedKmh() > TUNE.PERCEPTION_CAP_KMH and HISPEED_AHEAD_M or baseAhead
    local s = sessions[playerNum]
    local sensorAhead = s and s.sensor and s.sensor.aheadM
    if type(sensorAhead) == "number" and sensorAhead >= baseAhead then ahead = sensorAhead end
    return nearM, ahead, bandM,
        TUNE.ZOMBIE_CAP_1, TUNE.ZOMBIE_CAP_4, TUNE.ZOMBIE_CAP_8, TUNE.CORPSE_CAP
end

-- HUD 唯讀狀態（M5.5b 面板的資料面）。回**多值純量**、不洩漏 session table
-- （session 是可變內部狀態，交出參考＝UI 能繞過所有入口改駕駛行為）：
--   statusKey, gearId, effectiveCapKmh, zombieSlowOn, corpseSlowOn
-- statusKey ∈ arrive/yield/unstick/blocked/dodging/build/follow；nil＝無 session。
-- 顯示優先序：arrive > yield > recovery（unstick/recover/settle）>
-- current/planned blocked > dodging > build > follow。
-- effectiveCap＝min(session 啟動時沙盒上限, 當前檔位)。AutoDriveMaxSpeed 要重開
-- session 才重建 profile；HUD 不得先讀新沙盒值而顯示車子尚未套用的上限。
function Drive.hudState(playerNum)
    local s = sessions[playerNum]
    if not s then return nil end
    local key
    if s.mode == "arrive" then key = "arrive"
    elseif s.mode == "yield" then key = "yield"
    elseif s.mode == "unstick" or s.mode == "recover" or s.mode == "settle" then
        key = "unstick"
    elseif s.currentBlocked or s.blocked then key = "blocked"
    elseif s.dodging then key = "dodging"
    elseif s.mode == "build" then key = "build"
    else key = "follow" end
    local cap = s.maxSpeed
    if s.gearCap and s.gearCap > 0 and s.gearCap < cap then cap = s.gearCap end
    return key, Drive.getGear(playerNum), cap, s.zombieSlow, s.corpseSlow
end

local function reportAutoUsage(playerObj, vehicle, active, args, navArgs)
    if not playerObj or not vehicle then return end
    if isClient() then
        if not args then return end
        if active == true and navArgs then
            sendClientCommand(playerObj, MDAD.MOD_ID, MDAD.CMD_NAV_USAGE, navArgs)
        end
        args.active = active == true
        sendClientCommand(playerObj, MDAD.MOD_ID, MDAD.CMD_USAGE, args)
    elseif active == true then
        MDAD.setNavUsage(playerObj)
        MDAD.setAutoUsage(playerObj, vehicle)
    else
        MDAD.clearAutoUsage(playerObj, vehicle:getId())
    end
end

local function clearSession(playerNum)
    local s = sessions[playerNum]
    if not s then return end
    reportAutoUsage(getSpecificPlayer(playerNum), s.vehicle, false, s.usageArgs, s.navUsageArgs)
    sessions[playerNum] = nil
    sessionCount = sessionCount - 1
    -- 一般軌跡快取與 debug markers 都綁 session；停止／失效當下立即清。
    if type(MDADOverlay) == "table" then MDADOverlay.clear(playerNum) end
end

-- opt-in telemetry：HUD 缺席／關閉時零 I/O。熱路徑只在 opt-in session 進
-- protected boundary；shouldSample／collection／sample 任一錯誤只終止診斷，
-- 絕不打斷駕駛。start／event／stop 同樣隔離。
local function diagEnabled()
    local hud = MDAD.HUD
    if type(hud) ~= "table" or type(hud.telemetryEnabled) ~= "function" then
        return false
    end
    local ok, en = pcall(hud.telemetryEnabled)
    return ok and en == true
end

local diagFail

-- Driver 一律送具名 payload（Diagnostics 的 a-d 位置式舊介面只留給外部呼叫端）。
local function diagEvent(s, playerNum, name, payload)
    if not s or not s.diag then return end
    local ok, err = pcall(MDADDiagnostics.event, playerNum, name, payload)
    if not ok then diagFail(s, playerNum, "event " .. tostring(name) .. " failed", err) end
end

local function diagStop(s, playerNum, reason)
    if not s or not s.diag then return end
    pcall(MDADDiagnostics.stop, playerNum, reason)
end

diagFail = function(s, playerNum, stage, err)
    if not s or not s.diag then return end
    s.diag = false
    local detail = stage
    local okText, text = pcall(tostring, err)
    if okText and type(text) == "string" and text ~= "" then
        detail = stage .. ": " .. text
    end
    local fail = type(MDADDiagnostics) == "table" and MDADDiagnostics.fail
    local handled = false
    if type(fail) == "function" then handled = pcall(fail, playerNum, detail) end
    if not handled then pcall(MDADDiagnostics.stop, playerNum, "error") end
end


-- 停止＝只關 regulator，**不搶煞車**：停止的原因多半是玩家要自己接手（讓位逾時、下車、
-- 換車），這時候突然硬煞比放手更危險。到達停車的煞車是 arrive 分支自己做的。
-- regulator 是我們開的就由我們關：即使玩家已經不在車上（下車／換車），仍然關掉，
-- 否則那台車會留著一個沒人設過的定速，下一個上車的人莫名其妙就被拉速度。
function Drive.stop(playerNum, reasonKey)
    local s = sessions[playerNum]
    if not s then return false end
    diagStop(s, playerNum, reasonKey or "manual")
    clearSession(playerNum)
    if s.vehicle then s.vehicle:setRegulator(false) end
    -- 實機回報「按了關閉、感覺沒關」時這行就是分水嶺：印出來＝session 真的收掉、
    -- regulator 也關了，車還在動就是慣性（Stop 刻意不硬煞）；沒印出來才是真的沒關。
    if getDebug() then
        print(LOG .. "stop pn=" .. playerNum .. " reason=" .. (reasonKey or "manual")
            .. " regulator=off nobrake")
    end
    if reasonKey then
        local playerObj = getSpecificPlayer(playerNum)
        if playerObj then haloBad(playerObj, reasonKey) end
    end
    return true
end

-- 啟動的所有閘門，成功時就地把 session 寫進表裡。回 nil＝開起來了，否則回失敗的
-- 翻譯鍵；紅字與診斷統一由 Drive.start 收尾（七八條 early return 各印各的會讓
-- 診斷散得到處都是，而且每條都得記得包 getDebug()）。
local function startSession(playerObj, playerNum)
    -- 理論上 require 已經保證載入；真的缺了就是本 MOD 自己的檔案樹壞掉，
    -- 印一行診斷（同 MDAD_Client 的 registerNavGate 失敗慣例）再優雅退場，
    -- 不要讓 radial 回呼丟出 nil index 錯誤。這行不受 getDebug() 管：它是安裝壞掉，
    -- 不是調校用的遙測。
    if type(MDADFollower) ~= "table" then
        print("[" .. MDAD.MOD_ID .. "] autodrive disabled: MDAD_Follower not loaded")
        return KEY_ROUTE
    end
    local api = navApi()
    if not api then return KEY_API end
    local vehicle = playerObj:getVehicle()
    local reason = driveGate(playerObj, vehicle, playerNum, nil)
    if reason then return reason end
    local route, tx, ty = fetchRoute(api, playerNum)
    if not route then return KEY_ROUTE end
    local maxSpeed = maxSpeedKmh()
    -- One coherent profile is built before Follower. Geometry invalid is fatal
    -- because every current/swept OBB depends on it; other invalid domains fall
    -- back to legacy control constants instead of mixing patchwork fields.
    local vehicleProfile = nil
    if type(MDADVehicleProfile) == "table"
            and type(MDADVehicleProfile.build) == "function" then
        local pok, built = pcall(MDADVehicleProfile.build, vehicle)
        if pok and type(built) == "table" then vehicleProfile = built end
    end
    if not vehicleProfile then return KEY_ROUTE end
    if vehicleProfile.geometryValid ~= true
            or type(vehicleProfile.halfW) ~= "number"
            or vehicleProfile.halfW * 0 ~= 0 or vehicleProfile.halfW <= 0
            or type(vehicleProfile.halfL) ~= "number"
            or vehicleProfile.halfL * 0 ~= 0 or vehicleProfile.halfL <= 0 then
        return KEY_UNSUPPORTED
    end
    if type(vehicleProfile.brakingForce) == "number"
            and vehicleProfile.brakingForce * 0 == 0
            and vehicleProfile.brakingForce <= 0 then
        return KEY_UNSUPPORTED
    end
    local profile = MDADFollower.begin(route, maxSpeed, api.navApiVersion, vehicleProfile)
    if not profile then return KEY_ROUTE end
    local runtimeMass = vehicleProfile.mass
    if type(runtimeMass) ~= "number" or runtimeMass * 0 ~= 0
            or runtimeMass < MASS_VALID_LO or runtimeMass > MASS_VALID_HI then
        runtimeMass = MASS_FALLBACK
    end
    local adaptive = false
    if type(MDADVehicleProfile.configureFollower) == "function" then
        adaptive = MDADVehicleProfile.configureFollower(
            profile, vehicleProfile, runtimeMass, nil) == true
    end
    local fstate = nil
    if type(MDADFollower.newState) == "function" then fstate = MDADFollower.newState() end
    if type(fstate) ~= "table" then fstate = {} end
    local aDrive, aBrake, aLat, _, _, aCoast = MDADVehicleProfile.priors(
        vehicleProfile, runtimeMass, profile.segSurface[1], nil, false, adaptive)
    if type(MDADFollower.setRuntimeLimits) == "function" then
        MDADFollower.setRuntimeLimits(fstate, aDrive, aBrake, aLat, aCoast)
    end
    local rearArm = adaptive and vehicleProfile.rearArm or REAR_ARM
    local needHalf = adaptive and vehicleProfile.needHalf or NEED_HALF
    local squeezeNeed = adaptive and (vehicleProfile.halfW + 0.25) or SQUEEZE_NEED
    local probeR = adaptive and vehicleProfile.probeR or ROTATE_PROBE_R
    if probeR < ROTATE_PROBE_R then probeR = ROTATE_PROBE_R end
    -- 靠右行駛：常駐把前視點偏到右車道，會車時雙方自然錯開；繞行剖面作用時
    -- follower 會從右車道平滑過渡到繞行線再回來。沙盒 0＝關（沿中心線）。
    -- 符號：**l 正＝行進方向右側**——PZ 世界座標 Y 向南（地圖原點在西北角），
    -- 俯視下數學 CCW 法向 (-sin h, cos h) 實際指向右邊；2026-08-28 實機曾把它
    -- 標成「左」而給負號，整路靠左開（真踩過，語言標籤害死人）。
    local laneBias = MDAD.sandbox("RightLaneBias", 1.0)
    if type(laneBias) ~= "number" or laneBias ~= laneBias then laneBias = 1.0 end
    if laneBias < 0 then laneBias = 0 end
    if laneBias > 2 then laneBias = 2 end
    if type(MDADFollower.setLaneBias) == "function" then
        MDADFollower.setLaneBias(fstate, laneBias)
    end
    -- 所有閘門都過了才動玩家的車：先把 regulator 關掉一次。剖面要分幀建（長路線
    -- 七八幀），這段期間 stepFollow 根本不會跑，玩家上車前自己設的定速（或上一位
    -- 駕駛留下的）就會原封不動繼續拉著車跑——啟動自駕的下一秒車子照舊速衝出去。
    -- 失敗的啟動一律走上面的 early return，不會碰到這行，玩家的定速保持原狀。
    vehicle:setRegulator(false)
    local startedAt = getTimestampMs()
    sessions[playerNum] = {
        vehicle = vehicle,
        route = route,
        profile = profile,
        fstate = fstate,
        playerNum = playerNum,
        maxSpeed = maxSpeed,
        perceptionCap = maxSpeed > TUNE.PERCEPTION_CAP_KMH and HISPEED_CAP_KMH or TUNE.PERCEPTION_CAP_KMH,
        fullGate = false,
        gateReason = "sensor",
        alignSince = 0,
        cmdV = 0, cmdA = 0, cmdInitialized = false,
        commandControlState = "HOLD",
        jerkBypassReason = nil,
        curveValid = false,
        profileEnvelope = 0,
        curveKappa = 0,
        curveHardActive = false,
        curveCap = 0,
        proofKappa = 0,
        proofCurveCap = 0,
        visibilityCap = 0,
        curveVerifiedUntilS = 0,
        verifyBand = false,
        verifySweep = false,
        verifyLineReason = "sensor",
        verifyX = {}, verifyY = {}, verifySeg = {},
        verifyKappa = {}, verifyLocalCap = {}, verifyDist = {}, verifyEnvelope = {},
        verifyLineN = 0,
        laneCurveEnvelope = 0, laneCurveStamp = -1,
        envelopeBuildLat = -1, envelopeBuildCoast = -1, laneEnvelopeScale = 1,
        stateError = nil,
        invalid = false,
        mode = "build",  -- build → follow/gear-reset/recover/unstick/settle ⇄ yield → arrive
        navVersion = api.navApiVersion,
        adaptive = adaptive,
        runtimeMass = runtimeMass,
        nextMassMs = startedAt + MASS_REFRESH_MS,
        rearArm = rearArm,
        needHalf = needHalf,
        squeezeNeed = squeezeNeed,
        dynamicsCapMaterial = false,
        dynamicsFault = false,
        dynamicsDirty = false,
        nextDynamicsMs = startedAt + 1000,
        dynamicsAccelCap = aDrive, dynamicsBrakeCap = aBrake,
        dynamicsLatCap = aLat, dynamicsCoastCap = aCoast,
        horizonMinBrake = aBrake, horizonMinLat = aLat, horizonMinCoast = aCoast,
        horizonStamp = -1,
        sweepBase = needHalf - 0.1,
        squeezeSweepBase = squeezeNeed - 0.1,
        probeR = probeR,
        currentSurfaceId = profile.segSurface[1],
        currentSegWidth = profile.segWidth[1],
        rain = nil,
        physicalOffroad = false,
        surfaceMismatchRounds = 0,
        surfaceMismatch = false,
        tractionKey = -1,
        safeCoast = aCoast,
        priorAccel = aDrive, priorBrake = aBrake, priorLat = aLat, priorCoast = 0.6,
        safeAccel = aDrive, safeBrake = aBrake, safeLat = aLat,
        kinPrevMs = 0, kinPrevV = 0, kinPrevH = 0,
        accelMean = 0, accelDev = 0, accelTime = 0,
        accelConfidence = 0, accelLower = 0,
        coastMean = 0, coastDev = 0, coastTime = 0,
        coastConfidence = 0, coastLower = 0,
        brakeMean = 0, brakeDev = 0, brakeTime = 0,
        brakeConfidence = 0, brakeLower = 0,
        yawMean = 0, yawDev = 0, yawTime = 0,
        yawConfidence = 0, yawLower = 0,
        forceBrakeThis = false, lastAssistForce = 0,
        forceBrakeUntil = 0,
        ewmaSuppressUntil = 0,
        lastLatDev = 0, lastHeadingError = 0,
        forceBrakePrev = false, regulatorPrev = false,
        targetPrev = 0, steerPrev = 0,
        nextRouteMs = startedAt + ROUTE_REFRESH_MS,
        nextUsageMs = startedAt + USAGE_FIRST_RETRY_MS,
        usageArgs = { vehicleId = vehicle:getId(), active = true },
        navUsageArgs = { active = true },
        nextDebugMs = 0,
        cleanSinceMs = 0,
        parity = 1,
        yieldNotified = false,
        progressState = "disarmed",
        progressSince = 0,
        progressX = 0, progressY = 0, progressS = 0, progressH = 0,
        progressUntil = 0,
        resumeProgressPhase = nil,
        resumeProgressUntil = 0,
        verifyArmPending = false,
        verifyArmUntil = 0,
        routeReadyEventPending = true,
        routeReadyWhy = "initial",
        -- M4 感知與繞行。sensor 缺席（檔案樹壞）＝感知停用、退回 M3 純跟線，
        -- 不算錯誤：繞行是加值功能，跟線本體不依賴它。
        sensor = (type(MDADSensor) == "table" and type(MDADSensor.newState) == "function")
            and MDADSensor.newState() or false,
        planSig = -1,       -- -1 不可能是 sensor sig：首輪 clear 也必進一次 replan
        dodging = false,    -- 側偏剖面目前掛在 fstate 上
        dodgeTight = false, -- 本次繞行在彎道段（速度壓爬行；replan 每次重判）
        dodgeNotified = false, -- 繞行提示只出一次（clear/blocked/換路線時重臂）
        lastSNow = 0,
        blocked = false,
        blockedNotified = false,
        currentBlocked = false, -- current-body safety OR-gate；與前方 planned blocked 獨立
        currentClearRounds = 0,
        unstickX = 0, unstickY = 0, unstickUntil = 0,
        settleUntil = 0,
        unstickStartedAt = 0,
        nextRearProbeMs = 0,
        rearStatus = "unknown",
        reverseForce = 0,
        unstickDistance = 0,
        blockS = 0,
        lastTx = tx, lastTy = ty,
        targetGen = 1, routeGen = 1, pendingRouteWhy = nil,
        gearCap = 0,        -- 檔位巡航上限快取（refreshPolicies 維護；>0 才生效）
        zombieSlow = true,  -- 政策×偏好合成快取：這位玩家要不要為殭屍減速
        corpseSlow = true,  -- 同上，地面屍體
        rotProbeMs = 0,     -- 下一次允許車周探測的時戳（0＝第一次調頭幀就探）
        rotProbeClear = false, -- 上次探測結果：車周淨空可原地旋轉
        returnActive = false,
        returnUnsafe = false,
        returnHold = false,
        returnCrawlExact = false,
        returnCapacityFault = false,
        returnStartS = 0, returnEndS = 0,
        returnLaneStart = 0, returnLaneTarget = 0,
        returnSoftLimit = 2,
        returnReason = nil, returnClearRounds = 0,
        returnX = {}, returnY = {},
        clearStreak = 0,    -- 連續 clear 輪數（堵住解除遲滯）
        followHold = false, -- 跟車分級把目標壓 0（停等豁免卡死偵測用）
        dodgeCommittedLength = 0,
        dodgeBuildReason = nil,
        dodgeBlockReason = nil,
        waitSince = 0,      -- 合法 blocked/followHold 停等；只走既有 20s timeout
        detourTried = false,
        dodgeCrawl = false, -- 承諾剖面是 squeeze 檔（entry／hold／exit 全段上限 10）
        dodgeMargin = 1,    -- commit 時 a..c 最小餘裕（entry／hold 速度縮放輸入）
        dodgeKappa = 0,
        dodgeClearance = 0,
        dodgeCurveCap = 0,
        dodgeClearanceCap = 0,
        dodgeVisibilityCap = 0,
        dodgeSpaceCap = 0,
        dodgeSpeedCap = 0,
        dodgeBaseCap = 0,
        dodgeCapPending = false,
        dodgeShiftLength = 0,
        dodgeDesignSpeed = 0,
        dodgeClass = MDADDynamics.DODGE_STATIC,
        pushBanL = nil,     -- planner ban；recovery episode 可跨 clear/route 保留
        cornerLatch = false, -- BLOCKED_CORNER：障礙貼折點、軌跡契約不支援（快速改道）
        cornerS = 0,        -- corner latch 時的沿線弧長（前進 CORNER_RETRY_DIST 即撤銷重枚舉）
        lastOvEndS = 0,
        tmpOvEndS = 0,
        tmpOvX = {}, tmpOvY = {}, -- M6 候選折線工作表（buildOffsetLine 輸出、commit 時複製進 fstate）
        lastOvN = 0,        -- 最後成功候選的折線點數（setOffset 交表用）
        lastOvS0 = 0,
        blockHitX = nil,    -- sweep 真命中世界座標（detour 避讓圈直接用，不經弧長轉換）
        blockHitY = nil,
        pushBanS = 0,
        banFromRecovery = false,
        probeErrorLogged = false,
        dodgeNeed = needHalf - 0.1,
        sandBias = laneBias,
        roadBias = 0,
        vehicleProfile = vehicleProfile,
        -- Recovery episode 全為 scalar；route identity 改變只改映射，不清 attempts/ban。
        episodeSeq = 0,
        episodeId = 0,
        episodeActive = false,
        episodeAttempts = 0,
        episodeStartX = 0, episodeStartY = 0, episodeStartS = 0,
        episodeRouteGen = 1,
        episodeHitX = nil, episodeHitY = nil,
        episodeHitS = 0, episodeHitL = 0,
        episodeReason = nil,
        episodeGearResetTried = false,
        episodeClearRounds = 0,
        episodeMapPending = false,
        actualClearance = 0,
        plannedClearance = 0,
        footprintBlocked = false,
        footprintPoseOnly = false,
        footprintHitX = nil, footprintHitY = nil,
        footprintHitS = 0, footprintHitL = 0,
        diag = false,       -- telemetry session 是否啟動（熱路徑 boolean）
        -- 遙測用純觀測欄位（控制端不讀）：planMode＝最近一次 replan 離場分類；
        -- init＝尚未完成分類，其他值為 guard／guard-blocked／corner-latched／
        -- return-suppress／clear／clear-hold／dodge／blocked。lastCoupled＝這一幀
        -- applySteering 是否真的走耦力調頭（每幀先重設 false）。
        planMode = "init",
        lastCoupled = false,
    }
    do
        -- 高速檔：沙盒上限 > 85 → 掃描帶拉長（120 km/h 的煞停＋反應 ~77m < 110）
        local sNew = sessions[playerNum]
        if sNew.sensor then
            sNew.sensor.aheadM = maxSpeed > TUNE.PERCEPTION_CAP_KMH and HISPEED_AHEAD_M or 48
        end
    end
    sessionCount = sessionCount + 1
    refreshPolicies(sessions[playerNum], vehicle, playerNum)
    reportAutoUsage(playerObj, vehicle, true,
        sessions[playerNum].usageArgs, sessions[playerNum].navUsageArgs)
    do
        local sNew = sessions[playerNum]
        if diagEnabled() then
            local dok, active = pcall(MDADDiagnostics.start,
                playerNum, vehicle, sNew.vehicleProfile)
            sNew.diag = dok and active == true
            if not dok then pcall(MDADDiagnostics.stop, playerNum, "error") end
            if sNew.diag then
                diagEvent(sNew, playerNum, "start")
                diagEvent(sNew, playerNum, "target", {
                    phase = "set", x = tx, y = ty, why = "user", tg = sNew.targetGen,
                })
                local pointN = type(route.pts) == "table" and #route.pts / 2 or 0
                local routeLen = type(route.len) == "number"
                    and route.len * 0 == 0 and route.len or nil
                diagEvent(sNew, playerNum, "route", {
                    phase = "cutover", why = "initial", rg = sNew.routeGen,
                    tg = sNew.targetGen, len = routeLen, pts = pointN,
                    target = tostring(tx) .. "," .. tostring(ty),
                    navVersion = sNew.navVersion,
                    currentSurface = MDADFollower.surfaceName(profile.segSurface[1]),
                    currentSegWidth = profile.segWidth[1] > 0 and profile.segWidth[1] or nil,
                    cost = type(route.cost) == "number"
                        and route.cost * 0 == 0 and route.cost or nil,
                    avoidPenalty = type(route.avoidPenalty) == "number"
                        and route.avoidPenalty * 0 == 0 and route.avoidPenalty or nil,
                })
            end
        end
    end
    return nil
end

function Drive.start(playerObj)
    if not playerObj or not playerObj:isLocalPlayer() then return false end
    local playerNum = playerObj:getPlayerNum()
    if sessions[playerNum] then return true end
    if sessionCount >= MAX_SESSIONS then return false end
    local reason = startSession(playerObj, playerNum)
    if reason then
        haloBad(playerObj, reason)
        if getDebug() then print(LOG .. "start pn=" .. playerNum .. " blocked=" .. reason) end
        return false
    end
    haloGood(playerObj, "UI_MinidoracatAutoDrive_Start")
    if getDebug() then
        print(LOG .. "start pn=" .. playerNum .. " ok maxSpeed="
            .. sessions[playerNum].maxSpeed)
    end
    return true
end

function Drive.toggle(playerObj)
    if not playerObj then return end
    local playerNum = playerObj:getPlayerNum()
    if sessions[playerNum] then
        Drive.stop(playerNum, nil)
        haloGood(playerObj, "UI_MinidoracatAutoDrive_Stop")
        if getDebug() then print(LOG .. "toggle pn=" .. playerNum .. " off") end
        return
    end
    local ok = Drive.start(playerObj)
    if getDebug() then
        print(LOG .. "toggle pn=" .. playerNum .. " on ok=" .. tostring(ok))
    end
end

--------------------------------------------------------------------------------
-- 每幀控制
--------------------------------------------------------------------------------

-- Compose lateral steering and bounded forward assist into the one BaseVehicle
-- impulse slot. A forward component uses the body centerline, so it adds no yaw.
local function applySteering(
        s, vehicle, fwd, fx, fy, steer, speedKmh, mult, coupled, assistForce)
    if steer > 5 then steer = 5 elseif steer < -5 then steer = -5 end
    if steer < STEER_DEADZONE and steer > -STEER_DEADZONE then steer = 0 end
    if type(assistForce) ~= "number" or assistForce * 0 ~= 0
            or assistForce < 0 then assistForce = 0 end
    if coupled then assistForce = 0 end
    if steer == 0 and assistForce == 0 then return 0, 0 end

    local px, py = -fy, fx
    local av = speedKmh
    if av < 0 then av = -av end
    if av > SPEED_CAP_KMH then av = SPEED_CAP_KMH end
    local mass = s.runtimeMass
    if type(mass) ~= "number" or mass * 0 ~= 0 or mass < 1 then
        mass = MASS_FALLBACK
    end
    local arm = s.rearArm
    if type(arm) ~= "number" or arm * 0 ~= 0 or arm <= 0 then arm = REAR_ARM end
    local force = 0
    if steer ~= 0 then
        force = steer * STEER_SIGN * STEER_STRENGTH
            * (MASS_K * mass * av * av + MASS_BASE * mass)
            * IMPULSE_SCALE * (mult / MULT_NORM)
    end

    local parity = s.parity
    s.parity = -parity
    local impulse = BaseVehicle.allocVector3f()
    if coupled then
        local rf = force * ROTATE_FORCE_SCALE
        s.lastCoupled = true
        force = rf
        impulse:set(parity * rf * px, 0, parity * rf * py)
        fwd:set(parity * (-arm) * fx + LATERAL_JITTER * px, 0,
            parity * (-arm) * fy + LATERAL_JITTER * py)
    else
        impulse:set(force * px + assistForce * fx, 0,
            force * py + assistForce * fy)
        if assistForce > 0 then
            -- Forward impulse at the center when steering is idle; otherwise use
            -- the rear centerline so lateral force retains yaw without assist yaw.
            if force == 0 then
                fwd:set(0, 0, 0)
            else
                fwd:set(-arm * fx, 0, -arm * fy)
            end
        else
            fwd:set(-arm * fx + parity * LATERAL_JITTER * px, 0,
                -arm * fy + parity * LATERAL_JITTER * py)
        end
    end
    vehicle:addImpulse(impulse, fwd)
    BaseVehicle.releaseVector3f(impulse)
    return force, assistForce
end

local function longitudinalAssistForce(s, speedKmh, targetSpeed, mult)
    local mass = s.runtimeMass
    if type(mass) ~= "number" or mass * 0 ~= 0
            or mass < TUNE.ASSIST_MASS_MIN then return 0 end
    local ratio = MDADDynamics.longitudinalAssistRatio(speedKmh, targetSpeed)
    if ratio <= 0 then return 0 end
    return ratio * mass * IMPULSE_SCALE * (mult / MULT_NORM)
end

local function commandForceBrake(s, vehicle, now)
    local ok, err = pcall(vehicle.setForceBrake, vehicle)
    if not ok then
        pcall(vehicle.setRegulator, vehicle, false)
        s.dynamicsFault, s.invalid, s.stateError, s.brakeTerminalFault =
            true, true, "forceBrake", true
        if not s.forceBrakeErrorLogged then
            s.forceBrakeErrorLogged = true
            print(LOG .. "forceBrake failed: " .. tostring(err))
            local playerObj = getSpecificPlayer(s.playerNum)
            if playerObj then haloBad(playerObj, KEY_UNSUPPORTED) end
            diagEvent(s, s.playerNum, "state-error", { why = "forceBrake" })
        end
        return false
    end
    s.forceBrakeThis = true
    if type(now) ~= "number" or now * 0 ~= 0 then now = getTimestampMs() end
    local untilMs = now + 1000
    if untilMs > s.forceBrakeUntil then s.forceBrakeUntil = untilMs end
    return true
end

-- Regulator command only. Ordinary curves and straight-line overspeed coast through
-- the backward envelope and jerk state. forceBrake remains in the owning state paths:
-- HOLD/RECOVER/ARRIVE/contact/blocked, unsafe RETURN or dynamics, hard envelope breach,
-- and high-speed rotate preparation.
local function applySpeed(s, vehicle, targetSpeed)
    if type(targetSpeed) ~= "number" or targetSpeed < 0 then targetSpeed = 0 end
    if targetSpeed > s.maxSpeed then targetSpeed = s.maxSpeed end
    -- 原版儀表直接 `getRegulatorSpeed() .. ""`；物理判定完成後才整數化。
    local commandSpeed = math.floor(targetSpeed + 0.5)
    if commandSpeed > s.maxSpeed then commandSpeed = math.floor(s.maxSpeed) end
    vehicle:setRegulator(true)
    vehicle:setRegulatorSpeed(commandSpeed)
    return true
end

-- 路線在 [s0, s1] 內的累計轉角（弧度；折點朝向變化的絕對值總和）。
-- 事件驅動（replan 才呼叫），不在每幀熱路徑。
local function routeTurnWithin(profile, s0, s1)
    local total = 0
    local n = profile.n
    local ss, hh = profile.s, profile.segH
    for i = 1, n - 2 do
        local sa = ss[i + 1] -- 第 i／i+1 段的交界（折點）弧長
        if sa > s1 then break end
        if sa >= s0 then
            local dh = hh[i + 1] - hh[i]
            while dh > 3.14159265 do dh = dh - 6.2831853 end
            while dh < -3.14159265 do dh = dh + 6.2831853 end
            if dh < 0 then dh = -dh end
            total = total + dh
        end
    end
    return total
end

-- 路線在 [s0, s1] 內單一折點的峰值位置（最大單段轉角的弧長；< 0.15 rad 視為
-- 無折點回 nil）。過渡段提早完成用；事件驅動冷路徑。
local function turnPeakS(profile, s0, s1)
    local n = profile.n
    local ss, hh = profile.s, profile.segH
    local best, bestS = 0.15, nil
    for i = 1, n - 2 do
        local sa = ss[i + 1]
        if sa > s1 then break end
        if sa >= s0 then
            local dh = hh[i + 1] - hh[i]
            while dh > 3.14159265 do dh = dh - 6.2831853 end
            while dh < -3.14159265 do dh = dh + 6.2831853 end
            if dh < 0 then dh = -dh end
            if dh > best then
                best = dh
                bestS = sa
            end
        end
    end
    return bestS
end

-- 由弧長取路線上的世界點與法向（事件驅動輔助，線性走段；不在每幀熱路徑）
local function posAt(profile, sWant)
    local n = profile.n
    local ss = profile.s
    local i = 1
    while i < n - 1 and ss[i + 1] < sWant do i = i + 1 end
    local segLen = profile.segLen[i]
    local t = 0
    if segLen > 0 then
        t = (sWant - ss[i]) / segLen
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local ax, ay = profile.x[i], profile.y[i]
    local h = profile.segH[i]
    return ax + (profile.x[i + 1] - ax) * t,
        ay + (profile.y[i + 1] - ay) * t,
        -sin(h), cos(h)
end

-- 常駐車道偏置。舊版 follower 沒有 setLaneBias 時欄位缺席 → 0（沿中心線）。
-- NaN 必須在此收口：掃掠若吃到 NaN，距離比較會恆 false，直接 fail-open。
local function laneBiasOf(s)
    local lb = s.fstate.laneBias
    if type(lb) ~= "number" or lb ~= lb then return 0 end
    return lb
end

-- 期望行駛線＝laneBias＋（繞行中）smoothstep 側偏。與 follower 前視／sweepClear
-- 同一段；抽出只為遙測 el／ld 與甩出判定共用，語意逐位元不變。
local function expectedLaneOf(s)
    local expL = laneBiasOf(s)
    local offL = s.fstate.offL
    if s.dodging and type(offL) == "number" then
        local oa, ob, oc, od = s.fstate.offA, s.fstate.offB, s.fstate.offC, s.fstate.offD
        local sN = s.lastSNow
        if sN > oa and sN < od then
            local t
            if sN < ob then t = (sN - oa) / (ob - oa)
            elseif sN > oc then t = (od - sN) / (od - oc)
            else t = 1 end
            t = t * t * (3 - 2 * t)
            expL = expL + (offL - expL) * t
        end
    end
    return expL
end

-- NaN／非數值收口（與 MDAD_Diagnostics 的 finite 同語意；不用 math.huge）
local function finite(n)
    return type(n) == "number" and n * 0 == 0
end

-- 可見終點弧長：掃描終點與未載入格的近者。繞行 cap、全速證明與可視距離 cap
-- 三處必須同一定義，否則同一幀裡「看得到多遠」會彼此矛盾。
local function visibleEndS(sen, fallbackS)
    local endS = sen.scanEndS
    if not finite(endS) then return fallbackS end
    if sen.unloaded then
        if not finite(sen.unloadedS) then return fallbackS end
        if sen.unloadedS < endS then endS = sen.unloadedS end
    end
    return endS
end

local function jindex(obj, name)
    return obj[name]
end

local function jget(obj, name)
    if obj == nil then return nil end
    local okLookup, fn = pcall(jindex, obj, name)
    if not okLookup then error("getter lookup " .. name .. ": " .. tostring(fn)) end
    if type(fn) ~= "function" then return nil end
    return fn(obj)
end

local function refreshMass(s, vehicle, now)
    if now < s.nextMassMs then return false end
    s.nextMassMs = now + MASS_REFRESH_MS
    -- BaseVehicle.getMass() is BaseVehicle.java:8963-8970. This is the only
    -- runtime refresh: values inside the trusted window replace the session scalar.
    local ok, mass = pcall(jget, vehicle, "getMass")
    if not ok or not finite(mass)
            or mass < MASS_VALID_LO or mass > MASS_VALID_HI then
        return false
    end
    local delta = mass - s.runtimeMass
    if delta < 0 then delta = -delta end
    local threshold = s.runtimeMass * 0.005
    if threshold < 1 then threshold = 1 end
    -- Keep the old baseline on sub-threshold jitter so small changes accumulate.
    if delta < threshold then return false end
    s.runtimeMass = mass
    return true
end

-- 線上觀測只能收緊 prior；prior=0 必須保持 0。lower/confidence 先夾回
-- [0,prior]/[0,1]，任何壞值都不得把能力抬高。
local function tightenLimit(prior, lower, confidence, hi)
    if not finite(prior) or prior <= 0 then return 0 end
    if not finite(lower) or lower < 0 then lower = 0 end
    if lower > prior then lower = prior end
    if not finite(confidence) or confidence < 0 then confidence = 0
    elseif confidence > 1 then confidence = 1 end
    local v = prior + (lower - prior) * confidence
    if v > prior then v = prior end
    if v > hi then v = hi end
    if v < 0 then v = 0 end
    return v
end

-- Traction-keyed online observation. Every field lives in the session table;
-- stable frames only mutate scalars and call no Java getter.
local function updateTraction(s, now, speedKmh, heading, headingError, latDev)
    local surface = s.currentSurfaceId
    if not finite(surface) then surface = 0 end
    local wet = s.rain ~= false
    local missing = s.vehicleProfile.isAnyTireMissing
    local tireKey = missing == true and 1 or (missing == false and 0 or 2)
    local key = surface + (wet and 4 or 0) + tireKey * 8
        + (s.physicalOffroad and 32 or 0)
    local keyChanged = key ~= s.tractionKey
    if keyChanged then
        local oldKey = s.tractionKey
        s.tractionKey = key
        if oldKey ~= -1 then
            s.dynamicsDirty, s.dynamicsCapMaterial = true, false
        end
        s.accelMean, s.accelDev, s.accelTime = 0, 0, 0
        s.accelConfidence, s.accelLower = 0, 0
        s.coastMean, s.coastDev, s.coastTime = 0, 0, 0
        s.coastConfidence, s.coastLower = 0, 0
        s.brakeMean, s.brakeDev, s.brakeTime = 0, 0, 0
        s.brakeConfidence, s.brakeLower = 0, 0
        s.yawMean, s.yawDev, s.yawTime = 0, 0, 0
        s.yawConfidence, s.yawLower = 0, 0
        s.kinPrevMs = 0
    end

    local aDrive, aBrake, aLat = MDADVehicleProfile.priors(
        s.vehicleProfile, s.runtimeMass, surface, s.rain,
        s.physicalOffroad, s.adaptive)
    s.priorAccel, s.priorBrake, s.priorLat = aDrive, aBrake, aLat

    local brakeWindow = now < s.forceBrakeUntil
    local v = speedKmh
    if not finite(v) then v = 0 end
    if v < 0 then v = -v end
    v = v / 3.6
    local dt = (now - s.kinPrevMs) / 1000
    local actualSurface = s.sensor and s.sensor.actualSurfaceId
    local pavedKnownMismatch = s.navVersion >= 4
        and surface == MDADFollower.SURFACE_PAVED and s.physicalOffroad
        and actualSurface ~= nil and actualSurface ~= MDADSensor.SURFACE_UNKNOWN
        and actualSurface ~= MDADSensor.SURFACE_PAVED
    local stable = s.kinPrevMs > 0 and dt > 0 and dt <= 0.5
        and controlStateOf(s) == "TRACK"
        and not s.currentBlocked and not s.footprintBlocked
        and not pavedKnownMismatch
        and now >= s.ewmaSuppressUntil
    local ae = headingError
    if not finite(ae) then ae = 9 elseif ae < 0 then ae = -ae end
    local ld = latDev
    if not finite(ld) then ld = 9 elseif ld < 0 then ld = -ld end
    if ae > 0.087266462599716 or ld > 0.75 then stable = false end
    if s.sensor and (not s.sensor.ready or s.sensor.unloaded) then stable = false end

    if stable then
        local dv = (v - s.kinPrevV) / dt
        if brakeWindow or s.forceBrakePrev then
            local obs = -dv
            if obs < 0 then obs = 0 end
            if s.brakeTime == 0 then s.brakeMean = obs end
            s.brakeMean, s.brakeDev, s.brakeTime,
                s.brakeConfidence, s.brakeLower = MDADVehicleProfile.updateEWMA(
                    s.brakeMean, s.brakeDev, s.brakeTime, obs, dt)
        elseif s.regulatorPrev and s.targetPrev > s.kinPrevV * 3.6 + 1 then
            local obs = dv
            if obs < 0 then obs = 0 end
            if s.accelTime == 0 then s.accelMean = obs end
            s.accelMean, s.accelDev, s.accelTime,
                s.accelConfidence, s.accelLower = MDADVehicleProfile.updateEWMA(
                    s.accelMean, s.accelDev, s.accelTime, obs, dt)
        elseif not s.regulatorPrev
                or s.targetPrev <= s.kinPrevV * 3.6 + 1 then
            local obs = -dv
            if obs < 0 then obs = 0 end
            if s.coastTime == 0 then s.coastMean = obs end
            s.coastMean, s.coastDev, s.coastTime,
                s.coastConfidence, s.coastLower = MDADVehicleProfile.updateEWMA(
                    s.coastMean, s.coastDev, s.coastTime, obs, dt)
        end
        local steer = s.steerPrev
        if not brakeWindow and not s.forceBrakePrev and finite(steer)
                and (steer >= 0.5 or steer <= -0.5) then
            local dh = heading - s.kinPrevH
            if dh > 3.14159265358979 then dh = dh - 6.28318530717959
            elseif dh < -3.14159265358979 then dh = dh + 6.28318530717959 end
            if dh < 0 then dh = -dh end
            local obs = v * dh / dt
            if s.yawTime == 0 then s.yawMean = obs end
            s.yawMean, s.yawDev, s.yawTime,
                s.yawConfidence, s.yawLower = MDADVehicleProfile.updateEWMA(
                    s.yawMean, s.yawDev, s.yawTime, obs, dt)
        end
    end
    s.kinPrevMs, s.kinPrevV, s.kinPrevH = now, v, heading

    local safeAccel = tightenLimit(aDrive, s.accelLower, s.accelConfidence, 2.5)
    local safeBrake = tightenLimit(aBrake, s.brakeLower, s.brakeConfidence, 6)
    local safeLat = tightenLimit(aLat, s.yawLower, s.yawConfidence, 3.5)
    local safeCoast = tightenLimit(s.priorCoast, s.coastLower, s.coastConfidence, 0.6)
    s.safeAccel, s.safeBrake, s.safeLat, s.safeCoast =
        safeAccel, safeBrake, safeLat, safeCoast
    MDADFollower.setRuntimeLimits(
        s.fstate, safeAccel, safeBrake, safeLat, safeCoast)
    if safeBrake <= 0.05 then s.dynamicsFault = true end
    if now >= s.nextDynamicsMs then
        local da = s.dynamicsAccelCap - safeAccel
        local db = s.dynamicsBrakeCap - safeBrake
        local dl = s.dynamicsLatCap - safeLat
        local dc = s.dynamicsCoastCap - safeCoast
        if da < 0 then da = -da end
        if db < 0 then db = -db end
        if dl < 0 then dl = -dl end
        if dc < 0 then dc = -dc end
        local ta, tb, tl, tc = s.dynamicsAccelCap * 0.02,
            s.dynamicsBrakeCap * 0.02, s.dynamicsLatCap * 0.02,
            s.dynamicsCoastCap * 0.02
        if ta < 0.05 then ta = 0.05 end
        if tb < 0.05 then tb = 0.05 end
        if tl < 0.05 then tl = 0.05 end
        if tc < 0.02 then tc = 0.02 end
        if da >= ta or db >= tb or dl >= tl or dc >= tc then
            s.dynamicsDirty = true
            s.dynamicsCapMaterial = true
            s.nextDynamicsMs = now + 1000
        end
    end
end

-- 線性速度：世界 (X,Y)＝Bullet (x,z)。vLong＝前向分量、vLat＝CCW 側向。
-- 只在 opt-in 診斷呼叫；getter 缺席不取池，配置成功後任何讀取錯誤都先歸還。
local function sampleVelocity(vehicle, fx, fy)
    local okLookup, fn = pcall(jindex, vehicle, "getLinearVelocity")
    if not okLookup then
        error("getter lookup getLinearVelocity: " .. tostring(fn))
    end
    if type(fn) ~= "function" then return nil, nil end
    local vel = BaseVehicle.allocVector3f()
    if vel == nil then error("allocVector3f returned nil") end
    local okRead, vx, vz = pcall(function()
        fn(vehicle, vel)
        return vel:x(), vel:z()
    end)
    local okRelease, releaseErr = pcall(function()
        BaseVehicle.releaseVector3f(vel)
    end)
    if not okRead then error("getLinearVelocity failed: " .. tostring(vx)) end
    if not okRelease then error("releaseVector3f failed: " .. tostring(releaseErr)) end
    if not finite(vx) or not finite(vz) then return nil, nil end
    return vx * fx + vz * fy, -vx * fy + vz * fx
end

local function collectPhys(s, vehicle, fx, fy, expL, latDev)
    local phys = {}
    local po = jget(vehicle, "isDoingOffroad")
    if type(po) == "boolean" then phys.physicalOffroad = po end
    local ib = jget(vehicle, "isBraking")
    if type(ib) == "boolean" then phys.isBraking = ib end
    local sk = jget(vehicle, "getMinWheelSkid")
    if finite(sk) then phys.minWheelSkid = sk end
    local vLong, vLat = sampleVelocity(vehicle, fx, fy)
    if vLong ~= nil then phys.vLong = vLong end
    if vLat ~= nil then phys.vLat = vLat end
    local es = jget(vehicle, "getEngineSpeed")
    if finite(es) then phys.engineSpeed = es end
    local tn = jget(vehicle, "getTransmissionNumber")
    if finite(tn) then phys.transmissionNumber = tn end
    local rgs = jget(vehicle, "getRegulatorSpeed")
    if finite(rgs) then phys.regulatorSpeed = rgs end
    if finite(expL) then phys.expectedLane = expL end
    if finite(latDev) then phys.latDev = latDev end
    phys.navVersion = s.navVersion
    phys.currentSurfaceId = s.currentSurfaceId
    phys.currentSurface = MDADFollower.surfaceName(s.currentSurfaceId)
    if finite(s.currentSegWidth) and s.currentSegWidth > 0 then
        phys.currentSegWidth = s.currentSegWidth
    end
    phys.controlState = controlStateOf(s)
    phys.adaptive = s.adaptive
    phys.raining = s.rain
    phys.returnActive = s.returnActive
    phys.returnUnsafe = s.returnUnsafe
    phys.returnHold = s.returnHold
    phys.returnCapacityFault = s.returnCapacityFault
    phys.surfaceMismatch = s.surfaceMismatch
    phys.tractionKey = s.tractionKey
    phys.runtimeMass = s.runtimeMass
    phys.assistForce = s.lastAssistForce
    phys.priorAccel, phys.priorBrake, phys.priorLat =
        s.priorAccel, s.priorBrake, s.priorLat
    phys.priorCoast = s.priorCoast
    phys.safeAccel, phys.safeBrake, phys.safeLat =
        s.safeAccel, s.safeBrake, s.safeLat
    phys.accelConfidence, phys.accelLower =
        s.accelConfidence, s.accelLower
    phys.coastConfidence, phys.coastLower =
        s.coastConfidence, s.coastLower
    phys.brakeConfidence, phys.brakeLower =
        s.brakeConfidence, s.brakeLower
    phys.yawConfidence, phys.yawLower =
        s.yawConfidence, s.yawLower
    phys.steeringKappa = MDADVehicleProfile.steeringKappa(
        s.vehicleProfile, s.kinPrevV * 3.6)
    local sen = s.sensor
    if type(sen) == "table" then
        if finite(sen.roadLo) and finite(sen.roadHi) then
            phys.roadState = "band"
            phys.roadLo = sen.roadLo
            phys.roadHi = sen.roadHi
        else
            phys.roadState = "none"
        end
        if finite(sen.unloadedS) then
            phys.unloadedS = sen.unloadedS
        end
        if finite(s.lastSensorCap) then phys.capSensor = s.lastSensorCap end
        if sen.stamp == 0 then phys.capWarm = TUNE.SCAN_WARM_CAP end
    end
    if finite(s.gearCap) and s.gearCap > 0 then phys.capGear = s.gearCap end
    if finite(s.perceptionCap) then phys.capPerception = s.perceptionCap end
    if s.returnActive then
        phys.capOffroad = s.returnUnsafe and TUNE.RETURN_UNSAFE_CAP or TUNE.RETURN_CAP
        phys.capReturn = phys.capOffroad
    end
    if s.blocked and not s.returnActive then
        local stopDist = s.cornerLatch and TUNE.CORNER_STOP_DIST or TUNE.BLOCK_STOP_DIST
        if s.lastSNow >= s.blockS - stopDist then
            phys.capBlocked = 0
        else
            phys.capBlocked = TUNE.BLOCK_APPROACH_KMH
        end
    end
    if s.dodging and finite(s.lastDcap) then
        phys.capDodge = s.lastDcap
    end
    if finite(s.lastHeadingCap) then
        phys.capHeading = s.lastHeadingCap
    end
    if type(s.lastCapReason) == "string" then phys.activeCapReason = s.lastCapReason end
    phys.fullGate = s.fullGate
    phys.gateReason = s.gateReason
    phys.cmdV, phys.cmdA = s.cmdV, s.cmdA
    phys.jerkBypass = s.jerkBypassReason
    phys.curveKappa, phys.curveCap = s.curveKappa, s.curveCap
    phys.curveValid = s.curveValid
    phys.curveHardActive = s.curveHardActive
    phys.visibilityCap = s.visibilityCap
    phys.curveVerifiedUntilS = s.curveVerifiedUntilS
    phys.filletN = s.profile.filletN
    phys.filletFallbackN = s.profile.filletFallbackN
    phys.dodgeKappa = s.dodgeKappa
    phys.dodgeClearance = s.dodgeClearance
    phys.dodgeCurveCap = s.dodgeCurveCap
    phys.dodgeClearanceCap = s.dodgeClearanceCap
    phys.dodgeVisibilityCap = s.dodgeVisibilityCap
    phys.dodgeSpaceCap = s.dodgeSpaceCap
    phys.dodgeBaseCap, phys.dodgeCapPending =
        s.dodgeBaseCap, s.dodgeCapPending
    phys.dodgeDesignSpeed = s.dodgeDesignSpeed
    phys.dodgeSpeedCap = s.dodgeSpeedCap
    phys.dodgeClass = s.dodgeClass
    phys.verifyLineReason = s.verifyLineReason
    phys.laneCurveEnvelope, phys.envelopeBuildLat, phys.envelopeBuildCoast =
        s.laneCurveEnvelope, s.envelopeBuildLat, s.envelopeBuildCoast
    phys.proofKappa, phys.proofCurveCap = s.proofKappa, s.proofCurveCap
    phys.dodgeBuildReason, phys.dodgeBlockReason =
        s.dodgeBuildReason, s.dodgeBlockReason
    phys.dodgeCommittedLength = s.dodgeCommittedLength
    phys.stateError, phys.invalid = s.stateError, s.invalid
    return phys
end

-- Recovery episode survives sensor resets and same-target route identities. Only a true
-- target change/arrive/stop or the 10m+two-clear rearm path calls this reset.
local function clearEpisode(s)
    s.episodeActive = false
    s.episodeId = 0
    s.episodeAttempts = 0
    s.episodeStartX, s.episodeStartY, s.episodeStartS = 0, 0, 0
    s.episodeHitX, s.episodeHitY = nil, nil
    s.episodeHitS, s.episodeHitL = 0, 0
    s.episodeReason = nil
    s.episodeGearResetTried = false
    s.episodeClearRounds = 0
    s.episodeMapPending = false
    s.pushBanL, s.pushBanS = nil, 0
    s.banFromRecovery = false
end

local function beginEpisode(s, reason, x, y)
    if s.episodeActive then return end
    s.episodeSeq = s.episodeSeq + 1
    s.episodeId = s.episodeSeq
    s.episodeActive = true
    s.episodeAttempts = 0
    s.episodeStartX, s.episodeStartY, s.episodeStartS = x, y, s.lastSNow
    s.episodeRouteGen = s.routeGen
    s.episodeReason = reason
    s.episodeGearResetTried = false
    s.episodeClearRounds = 0
end

-- BaseVehicle.getWorldPos(float,float,float,out) transforms the script COM into PZ world
-- x/y (BaseVehicle.java:1871-1889). The caller owns/reuses the pooled vector.
local function bodyCenter(s, vehicle, out)
    local p = s.vehicleProfile
    if type(p) ~= "table" or p.geometryValid ~= true
            or not finite(p.centerOfMassX) or not finite(p.centerOfMassZ) then
        return nil, nil
    end
    local okLookup, fn = pcall(jindex, vehicle, "getWorldPos")
    if not okLookup or type(fn) ~= "function" then return nil, nil end
    local ok = pcall(fn, vehicle, p.centerOfMassX, 0, p.centerOfMassZ, out)
    if not ok then return nil, nil end
    local x, y = out:x(), out:y()
    if not finite(x) or not finite(y) then return nil, nil end
    return x, y
end


-- 後方 swept-strip 探測的共用包裝（recovery 起手與 unstick 每 100ms 重查共用）：
-- bodyCenter 取不到、或 Sensor 缺席，都回 unloaded 而非 clear——呼叫端一律以
-- status ~= "clear" 判定不可倒車。out 會被 bodyCenter 覆寫成世界座標，呼叫端必須
-- 先取完 forward 分量；fx/fy 需已正規化。
local function rearProbe(s, vehicle, out, fx, fy, vx, vy)
    local bx, by = bodyCenter(s, vehicle, out)
    if bx == nil or type(MDADSensor) ~= "table"
            or type(MDADSensor.probeRear) ~= "function" then
        return "unloaded", vx, vy, "geometry", "body center or rear probe unavailable"
    end
    return MDADSensor.probeRear(s.sensor, vehicle, getCell(), bx, by, fx, fy, -fy, fx,
        s.vehicleProfile.halfW, s.vehicleProfile.halfL, REAR_TRAVEL_M)
end

local function noteProbeError(s, where, status, kind, detail)
    if s.probeErrorLogged or type(detail) ~= "string" or detail == "" then return end
    s.probeErrorLogged = true
    print(LOG .. where .. " probe fail-closed status=" .. tostring(status)
        .. " kind=" .. tostring(kind) .. " detail=" .. detail)
end

-- recovery 的物理實證 ban：繞行已承諾側偏就 ban 那條縫，否則 ban 車目前的橫向
-- 位置。「本 episode 尚未 ban」的守門留在呼叫端（footprint 要求真命中、suspect
-- 要求近場非淨空），這裡只負責 lane 取值與寫入，兩條路徑共用同一套規則。
local function banRecoveryLane(s, latSigned, anchorS)
    local lane = latSigned
    if s.dodging and finite(s.fstate.offL) then lane = s.fstate.offL end
    if not finite(lane) then return end
    local minAnchor = s.lastSNow + 2 * s.vehicleProfile.halfL + 5
    if not finite(anchorS) or anchorS < minAnchor then anchorS = minAnchor end
    s.pushBanL, s.pushBanS = lane, anchorS
    s.banFromRecovery = true
end

-- Project a retained world hit directly onto a newly-built route. This does not depend
-- on the first sensor snapshot containing the old obstacle (streaming/unloaded safe).
local function remapEpisodeBan(s)
    local p = s.profile
    if not s.episodeMapPending or p.ready ~= true
            or not finite(s.episodeHitX) or not finite(s.episodeHitY) then return end
    local bestD2, bestS, bestL = nil, 0, 0
    for i = 1, p.n - 1 do
        local ax, ay = p.x[i], p.y[i]
        local dx, dy = p.x[i + 1] - ax, p.y[i + 1] - ay
        local len = p.segLen[i]
        if finite(len) and len > 0 then
            local t = ((s.episodeHitX - ax) * dx + (s.episodeHitY - ay) * dy)
                / (len * len)
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            local qx, qy = ax + dx * t, ay + dy * t
            local ex, ey = s.episodeHitX - qx, s.episodeHitY - qy
            local d2 = ex * ex + ey * ey
            if bestD2 == nil or d2 < bestD2 then
                local h = p.segH[i]
                bestD2 = d2
                bestS = p.s[i] + len * t
                bestL = ex * (-sin(h)) + ey * cos(h)
            end
        end
    end
    local corridorHalf = type(MDADSensor) == "table" and MDADSensor.CORRIDOR_HALF or 7
    if bestD2 ~= nil and bestD2 <= corridorHalf * corridorHalf then
        s.pushBanS, s.pushBanL = bestS, bestL
    else
        s.pushBanS, s.pushBanL = 0, nil
    end
    s.episodeMapPending = false
end

-- Runs once per completed sensor snapshot, before the expected-path planner. It updates
-- the current-body OR-gate, episode ban/rearm, and scalar telemetry without allocating.
local function footprintSnapshot(s, vehicle, playerNum, out, heading, vx, vy, latSigned)
    local sen = s.sensor

    remapEpisodeBan(s)

    local blocked, actual, planned, hitI, hitS, hitL, hitX, hitY, poseOnly
    local bx, by = bodyCenter(s, vehicle, out)
    local idx = s.fstate.idx or 1
    local routeH = s.profile.segH[idx]
    if bx == nil or not finite(routeH) then
        blocked, actual, planned, hitI, hitS, hitL, hitX, hitY, poseOnly =
            true, 0, 0, 0, 0, 0, 0, 0, false
    elseif type(MDADCorridor) == "table"
            and type(MDADCorridor.currentFootprintHit) == "function" then
        blocked, actual, planned, hitI, hitS, hitL, hitX, hitY, poseOnly =
            MDADCorridor.currentFootprintHit(
                sen.hardS, sen.hardL, sen.hardX, sen.hardY, sen.hardR, sen.hardN,
                bx, by, heading, s.vehicleProfile.halfW, s.vehicleProfile.halfL,
                s.lastSNow, latSigned, routeH, expectedLaneOf(s))
    else
        -- Corridor 是選配；缺它不能做 OBB 判定，但仍須保留 M3 pure follower。
        blocked, actual, planned, hitI, hitS, hitL, hitX, hitY, poseOnly =
            false, 99, 99, 0, 0, 0, 0, 0, false
    end
    s.actualClearance, s.plannedClearance = actual, planned
    s.footprintBlocked = blocked == true
    s.footprintPoseOnly = poseOnly == true
    if hitI and hitI > 0 then
        s.footprintHitS, s.footprintHitL = hitS, hitL
        s.footprintHitX, s.footprintHitY = hitX, hitY
    else
        s.footprintHitS, s.footprintHitL = 0, 0
        s.footprintHitX, s.footprintHitY = nil, nil
    end

    if blocked then
        s.currentBlocked = true
        s.currentClearRounds = 0
        s.episodeClearRounds = 0
        beginEpisode(s, hitI > 0 and "contact" or "unknown", vx, vy)
        if hitI > 0 and s.episodeHitX == nil then
            s.episodeHitX, s.episodeHitY = hitX, hitY
            s.episodeHitS, s.episodeHitL = hitS, hitL
        end
        if hitI > 0 and s.pushBanL == nil then
            banRecoveryLane(s, latSigned, hitS)
        end
        s.planMode = "current-blocked"
    else
        s.currentClearRounds = s.currentClearRounds + 1
        if s.currentBlocked and s.currentClearRounds >= CLEAR_STREAK_N then
            s.currentBlocked = false
        end
        if s.episodeActive then
            s.episodeClearRounds = s.episodeClearRounds + 1
        end
    end

    if s.episodeActive and s.episodeClearRounds >= CLEAR_STREAK_N then
        local rearmed = false
        if s.routeGen == s.episodeRouteGen then
            rearmed = s.lastSNow - s.episodeStartS >= UNSTICK_PROGRESS
        else
            local ax, ay = s.episodeHitX, s.episodeHitY
            if not finite(ax) or not finite(ay) then
                ax, ay = s.episodeStartX, s.episodeStartY
            end
            local dx, dy = vx - ax, vy - ay
            rearmed = dx * dx + dy * dy >= EPISODE_REARM_SQ
        end
        if rearmed then
            diagEvent(s, playerNum, "progress", {
                phase = "rearmed", eid = s.episodeId, s = s.lastSNow,
                d = UNSTICK_PROGRESS,
            })
            clearEpisode(s)
        end
    end
end

-- Called only after stepFollow released its hot-path vector. Rear unknown is fail-closed;
-- an attempt is consumed only after a clear 4m swept-strip check.
local function startRecoveryAttempt(s, vehicle, playerNum, now, vx, vy)
    if MDAD.sandbox("ObstaclePolicy", POLICY_DODGE) ~= POLICY_DODGE
            or s.episodeAttempts >= UNSTICK_MAX then
        diagEvent(s, playerNum, "unstick", {
            phase = "timeout", eid = s.episodeId, attempt = s.episodeAttempts,
            x = vx, y = vy, s = s.lastSNow, rear = "attempt-limit",
        })
        Drive.stop(playerNum, KEY_STUCK)
        return
    end

    local out = BaseVehicle.allocVector3f()
    vehicle:getForwardVector(out)
    local fx, fy = out:x(), out:z()
    local flen2 = fx * fx + fy * fy
    local status, hitX, hitY, kind, detail = "unloaded", vx, vy, "geometry",
        "invalid forward vector"
    if flen2 > 1e-6 then
        local inv = 1 / sqrt(flen2)
        fx, fy = fx * inv, fy * inv
        status, hitX, hitY, kind, detail = rearProbe(s, vehicle, out, fx, fy, vx, vy)
    end
    BaseVehicle.releaseVector3f(out)
    s.rearStatus = status
    if status ~= "clear" then
        noteProbeError(s, "rear-start", status, kind, detail)
        diagEvent(s, playerNum, "unstick", {
            phase = "rear-blocked", eid = s.episodeId,
            attempt = s.episodeAttempts, x = hitX, y = hitY,
            s = s.lastSNow, rear = status, kind = kind, detail = detail,
        })
        Drive.stop(playerNum, KEY_STUCK)
        return
    end

    s.episodeAttempts = s.episodeAttempts + 1
    s.unstickX, s.unstickY = vx, vy
    s.unstickUntil = now + UNSTICK_MS
    s.unstickStartedAt = now
    s.nextRearProbeMs = now + REAR_PROBE_MS
    s.unstickDistance = 0
    s.reverseForce = 0
    s.mode = "unstick"
    s.progressState = "recover"
    diagEvent(s, playerNum, "unstick", {
        phase = "start", eid = s.episodeId, attempt = s.episodeAttempts,
        x = vx, y = vy, s = s.lastSNow, d = 0, rear = status,
    })
    vehicle:setRegulator(false)
    local playerObj = getSpecificPlayer(playerNum)
    if playerObj then haloGood(playerObj, KEY_UNSTICK) end
end

-- Recovery modes bypass stepFollow, so they use the same Diagnostics gate explicitly.
-- Telemetry off returns before every new physics getter; no per-frame table is created.
local function sampleRecovery(s, vehicle, playerNum, now, x, y, speed, fx, fy, heading)
    if not s.diag then return end
    local okW, want = pcall(MDADDiagnostics.shouldSample,
        playerNum, now, s.mode, 0, true)
    if not okW then
        diagFail(s, playerNum, "shouldSample failed", want)
        return
    end
    if want ~= true then return end

    local vec, phys, gear
    local okPrep, prepErr = pcall(function()
        if not finite(fx) or not finite(fy) then
            vec = BaseVehicle.allocVector3f()
            if vec == nil then error("allocVector3f returned nil") end
            vehicle:getForwardVector(vec)
            fx, fy = vec:x(), vec:z()
            local flen2 = fx * fx + fy * fy
            if flen2 > 1e-6 then
                local inv = 1 / sqrt(flen2)
                fx, fy = fx * inv, fy * inv
                heading = MDADFollower.headingFromForward(fx, fy)
            else
                fx, fy, heading = 1, 0, 0
            end
        end
        phys = collectPhys(s, vehicle, fx, fy, nil, nil)
        gear = Drive.getGear(playerNum)
    end)
    if vec ~= nil then
        local okRelease, releaseErr = pcall(BaseVehicle.releaseVector3f, vec)
        if not okRelease and okPrep then
            okPrep, prepErr = false, releaseErr
        end
    end
    if not okPrep then
        diagFail(s, playerNum, "recovery physics collection failed", prepErr)
        return
    end

    local deadline = s.mode == "settle" and s.settleUntil or s.unstickUntil
    local remainingMs = deadline - now
    if remainingMs < 0 then remainingMs = 0 end
    local ok, live = pcall(MDADDiagnostics.sample, playerNum, now,
        x, y, heading or 0, speed, 0, 0, 0, 0, 0, s.reverseForce,
        s.mode, gear, false, s.sensor, true,
        s.planMode, s.lastSNow, s.blockS, s.dodgeMargin, s.dodgeNeed,
        s.roadBias, s.blockHitX, s.blockHitY, s.fstate.idx,
        s.blocked or s.currentBlocked, s.dodging, s.returnActive, s.cornerLatch, false, phys,
        s.targetGen, s.routeGen, s.episodeId, s.progressState, s.episodeAttempts,
        s.pushBanL ~= nil and s.pushBanL or false, s.unstickDistance,
        s.rearStatus, s.reverseForce, remainingMs,
        s.actualClearance, s.plannedClearance, s.footprintBlocked,
        s.footprintHitX, s.footprintHitY)
    if not ok then
        diagFail(s, playerNum, "sample failed", live)
    elseif live ~= true then
        s.diag = false
        pcall(MDADDiagnostics.stop, playerNum, "stopped")
    end
end

-- Builds the snapshot's soft future-curve coast envelope in caller-owned arrays.
-- Per-frame EWMA changes scale this cached envelope in O(1); they never rebuild it.
local function refreshLaneCurveEnvelope(s, coast, lat)
    local n = s.verifyLineN or 0
    if n < 2 or not finite(coast) or coast < 0
            or not finite(lat) or lat < 0 then
        s.laneCurveEnvelope, s.envelopeBuildLat, s.envelopeBuildCoast =
            0, lat, coast
        return false
    end
    local caps, kappas = s.verifyLocalCap, s.verifyKappa
    local vp, minCap = s.vehicleProfile, s.vehicleProfile.maxSpeed
    for k = 1, n do
        local cap = MDADDynamics.curveSpeedCapKmh(
            kappas[k], lat, vp.wheelbase, vp.delta0Safe, vp.deltaVSafe, vp.maxSpeed)
        caps[k] = cap
        if cap < minCap then minCap = cap end
    end
    s.proofCurveCap, s.envelopeBuildLat = minCap, lat
    local dist, envelope = s.verifyDist, s.verifyEnvelope
    local nextCap = caps[n]
    if not finite(nextCap) or nextCap < 0 then
        s.laneCurveEnvelope, s.envelopeBuildCoast = 0, coast
        return false
    end
    envelope[n] = nextCap
    for k = n - 1, 1, -1 do
        local localCap, d = caps[k], dist[k]
        if not finite(localCap) or localCap < 0 or not finite(d) or d < 0 then
            s.laneCurveEnvelope, s.envelopeBuildCoast = 0, coast
            return false
        end
        local nextMs = nextCap / 3.6
        local coastCap = sqrt(nextMs * nextMs + 2 * coast * d) * 3.6
        nextCap = localCap < coastCap and localCap or coastCap
        envelope[k] = nextCap
    end
    s.laneCurveEnvelope, s.envelopeBuildCoast = nextCap, coast
    return true
end
-- 掃掠幾何：車身 OBB 半尺寸，加上「規劃淨距扣掉物理半寬」後剩下的餘裕。
-- 弧線重算與世界折線掃掠共用這一份，同一檔位不會出現兩套門檻。
local function sweepGeom(s, needBase)
    local halfW, halfL = s.vehicleProfile.halfW, s.vehicleProfile.halfL
    local pad = (needBase or s.sweepBase or SWEEP_BASE) - halfW
    if pad < SWEEP_PHYS_PAD then pad = SWEEP_PHYS_PAD end
    return halfW, halfL, pad
end

-- 繞行線掃掠複驗（理由見 SWEEP_STEP 常數註解）。回 true＝全程淨空。
-- tag＝呼叫點標籤（guard/plan/retry）：失敗時印違規點細節——「plan 判可行、
-- sweep 打槍」循環卡死的復盤全靠這行（2026-08-29 路口實測：只有 failed 一行
-- 無從判斷是折角投影失真還是縫真的不夠寬）。
-- needBase（可省略＝SWEEP_BASE）：世界淨距基準。與規劃半寬保持「needBase＝
-- needHalf − 0.1」的固定關係（普通 1.4→1.3、彎道 2.0→1.9、爬行 1.2→1.1），
-- 檔位由提案端決定、掃掠與承諾期守護沿用同值（codex 對抗審：單邊放寬會用
-- 弱門檻掩蓋強檔位的安全語意）。
local function sweepClear(s, profile, a, b, c, d, offL, tag, needBase)
    local sen = s.sensor
    local hn = sen.hardN
    if hn == 0 then return true, 9 end
    local minMargin = 9
    local hx, hy, hr = sen.hardX, sen.hardY, sen.hardR
    if type(hx) ~= "table" or type(hy) ~= "table" or type(hr) ~= "table" then
        return false, 99, s.lastSNow, 1, s.lastSNow, 0, 0
    end
    for i = 1, hn do
        if not finite(hx[i]) or not finite(hy[i])
                or not finite(hr[i]) or hr[i] < 0 then
            return false, 99, s.lastSNow, 1, s.lastSNow, 0, 0
        end
    end
    if not obbDistanceSq then obbDistanceSq = MDADCorridor.orientedDistanceSqUnchecked end
    if type(obbDistanceSq) ~= "function" then
        return false, 99, s.lastSNow, 1, s.lastSNow, 0, 0
    end
    local bias = laneBiasOf(s)
    local halfW, halfL, pad = sweepGeom(s, needBase)
    local sPos = s.lastSNow
    if sPos >= a then sPos = a end
    while sPos <= d do
        local t
        if sPos < b then
            t = (sPos - a) / (b - a)
            if t < 0 then t = 0 end
        elseif sPos > c then
            t = (d - sPos) / (d - c)
        else
            t = 1
        end
        t = t * t * (3 - 2 * t)
        local lane = bias + (offL - bias) * t
        local px, py, nx, ny = posAt(profile, sPos)
        local wx, wy = px + nx * lane, py + ny * lane
        local inCap = sPos >= a and sPos <= c
        local pointPad = sPos < a and SWEEP_PHYS_PAD or pad
        local poseFx, poseFy = ny, -nx
        local comX, comZ = s.vehicleProfile.centerOfMassX, s.vehicleProfile.centerOfMassZ
        local bodyX = wx + poseFx * comZ + poseFy * comX
        local bodyY = wy + poseFy * comZ - poseFx * comX
        for i = 1, hn do
            local ox = hx[i]
            if ox then
                local r = hr[i]
                local d2 = obbDistanceSq(
                    bodyX, bodyY, poseFx, poseFy, halfW, halfL, ox, hy[i])
                local rr = MDADDynamics.sweepRadius(
                    r, pointPad, SWEEP_PHYS_PAD, TUNE.SWEEP_QUANT_COMP)
                if d2 == nil or d2 <= rr * rr then
                    local clearance = d2 and (sqrt(d2) - rr) or -99
                    local phase
                    if sPos < a then phase = 1
                    elseif sPos < b then phase = 2
                    elseif sPos <= c then phase = 3
                    else phase = 4 end
                    if getDebug() then
                        print(string.format(
                            "%ssweep OBB fail[%s] p%d offL=%.2f @s=%.1f lane=%.2f at=(%.1f,%.1f) hit#%d hw=(%.1f,%.1f) clearance=%.2f",
                            LOG, tostring(tag or "?"), phase, offL, sPos, lane,
                            wx, wy, i, ox, hy[i] or 0, clearance))
                    end
                    return false, -clearance,
                        (sen.hardS and sen.hardS[i]) or sPos,
                        phase, sPos, ox, hy[i] or 0
                end
                if inCap then
                    local probe = rr + minMargin
                    if d2 < probe * probe then
                        local clearance = sqrt(d2) - rr
                        if clearance < minMargin then minMargin = clearance end
                    end
                end
            end
        end
        sPos = sPos + SWEEP_STEP
    end
    return true, minMargin
end

-- M6 世界折線掃掠：驗的是 buildOffsetLine 烘好的**同一條**前視線（折點法向
-- 混合、連續）——「驗的線＝走的線」是 M6 軌跡契約的核心。回傳
-- ok, clearance, hardS, phase, sampleS, hitX, hitY；hardS 是障礙弧長，
-- sampleS 是失敗車身取樣弧長，proof prefix 必須使用後者。
local function sweepLine(s, lx, ly, ln, lS0, lS1,
        a, b, c, d, offL, tag, needBase, startK)
    local sen = s.sensor
    if not finite(ln) or ln < 2 or not finite(lS0) or not finite(lS1) then
        return false, 99, s.lastSNow, 1, s.lastSNow, 0, 0
    end
    local lastStart = lS0 + (ln - 2) * MDADFollower.OV_STEP
    if lS1 <= lastStart
            or lS1 > lastStart + MDADFollower.OV_STEP + 1e-6 then
        return false, 99, s.lastSNow, 1, s.lastSNow, 0, 0
    end
    local hn = sen.hardN
    if hn == 0 then return true, 9 end
    local hx, hy, hr = sen.hardX, sen.hardY, sen.hardR
    if type(hx) ~= "table" or type(hy) ~= "table" or type(hr) ~= "table" then
        return false, 99, s.lastSNow, 1, s.lastSNow, 0, 0
    end
    for i = 1, hn do
        if not finite(hx[i]) or not finite(hy[i])
                or not finite(hr[i]) or hr[i] < 0 then
            return false, 99, s.lastSNow, 1, s.lastSNow, 0, 0
        end
    end
    if not obbDistanceSq then obbDistanceSq = MDADCorridor.orientedDistanceSqUnchecked end
    if type(obbDistanceSq) ~= "function" then
        return false, 99, s.lastSNow, 1, s.lastSNow, 0, 0
    end
    local halfW, halfL, pad = sweepGeom(s, needBase)
    local minMargin = 9
    local lastFx, lastFy = 1, 0
    if not finite(startK) then startK = 1 else startK = startK - startK % 1 end
    if startK < 1 then startK = 1 end
    if startK > ln then return true, minMargin end
    for k = startK, ln do
        local sk = k == ln and lS1
            or (lS0 + (k - 1) * MDADFollower.OV_STEP)
        local wx, wy = lx[k], ly[k]
        local k0, k1 = k, k + 1
        if k1 > ln then k0, k1 = k - 1, k end
        local fx, fy = lx[k1] - lx[k0], ly[k1] - ly[k0]
        local fl2 = fx * fx + fy * fy
        if fl2 > 1e-8 then
            local inv = 1 / sqrt(fl2)
            fx, fy = fx * inv, fy * inv
            lastFx, lastFy = fx, fy
        else
            fx, fy = lastFx, lastFy
        end
        local inCap = sk >= a and sk <= c
        local pointPad = sk < a and SWEEP_PHYS_PAD or pad
        local comX, comZ = s.vehicleProfile.centerOfMassX, s.vehicleProfile.centerOfMassZ
        local bodyX = wx + fx * comZ + fy * comX
        local bodyY = wy + fy * comZ - fx * comX
        for i = 1, hn do
            local ox = hx[i]
            if ox then
                local r = hr[i]
                local d2 = obbDistanceSq(
                    bodyX, bodyY, fx, fy, halfW, halfL, ox, hy[i])
                local rr = MDADDynamics.sweepRadius(
                    r, pointPad, SWEEP_PHYS_PAD, TUNE.SWEEP_QUANT_COMP)
                if d2 == nil or d2 <= rr * rr then
                    local clearance = d2 and (sqrt(d2) - rr) or -99
                    local phase
                    if sk < a then phase = 1
                    elseif sk < b then phase = 2
                    elseif sk <= c then phase = 3
                    else phase = 4 end
                    if getDebug() then
                        print(string.format(
                            "%ssweep OBB fail[%s] p%d offL=%.2f @s=%.1f at=(%.1f,%.1f) hit#%d hw=(%.1f,%.1f) clearance=%.2f",
                            LOG, tostring(tag or "?"), phase, offL, sk, wx, wy,
                            i, ox, hy[i] or 0, clearance))
                    end
                    return false, -clearance,
                        (sen.hardS and sen.hardS[i]) or sk,
                        phase, sk, ox, hy[i] or 0
                end
                if inCap then
                    local probe = rr + minMargin
                    if d2 < probe * probe then
                        local clearance = sqrt(d2) - rr
                        if clearance < minMargin then minMargin = clearance end
                    end
                end
            end
        end
    end
    return true, minMargin
end
-- Build one immutable proof object for loaded coverage, raw road-band, curvature
-- and long-vehicle OBB sweep. Keep the longest verified prefix, bounded by the
-- earliest failure; a farther failure cannot veto the current stopping horizon.
local function buildSnapshotProof(s, segI, proofEnd)
    s.verifyBand, s.verifySweep = false, false
    s.verifyLineReason, s.curveVerifiedUntilS = "state", 0
    s.proofKappa, s.proofCurveCap = 0, 0
    if not s.adaptive or s.dodging or s.returnActive
            or s.blocked or s.currentBlocked then return end

    local prof, sen = s.profile, s.sensor
    local verifyX, verifyY, verifySeg = s.verifyX, s.verifyY, s.verifySeg
    local halfW = s.vehicleProfile.halfW
    local lane = laneBiasOf(s)
    local lineN, lineS0, lineReason, lastIdx = MDADFollower.buildLaneLine(
        prof, s.lastSNow, proofEnd, lane,
        verifyX, verifyY, segI, verifySeg)
    if lineReason ~= "ok" then
        s.verifyLineReason = lineReason
        return
    end
    if lineN < 2 then
        s.verifyLineReason = "capacity"
        return
    end

    local verifiedEnd, failReason = proofEnd, nil
    local rawPts, rawWidths = s.route.pts, s.route.segWidth
    local sourceValid = s.navVersion >= 4
        and prof.filletBandValid == true
        and type(rawPts) == "table" and type(rawWidths) == "table"
    if sourceValid then
        for k = 1, lineN do
            local si = verifySeg[k]
            if not finite(si) then
                sourceValid, verifiedEnd, failReason =
                    false, lineS0, "capacity"
                break
            end
            local sa, sb = prof.segSourceA[si], prof.segSourceB[si]
            local wx, wy = verifyX[k], verifyY[k]
            if not MDADDynamics.rawBandContains(
                    rawPts, rawWidths, sa, halfW, wx, wy)
                    and not MDADDynamics.rawBandContains(
                        rawPts, rawWidths, sb, halfW, wx, wy) then
                local failS = k == lineN and proofEnd
                    or lineS0 + (k - 1) * MDADFollower.OV_STEP
                failS = failS - MDADFollower.OV_STEP
                if failS < lineS0 then failS = lineS0 end
                if failS < verifiedEnd then
                    verifiedEnd, failReason = failS, "band"
                end
                break
            end
        end
        local rangeN = finite(lastIdx) and lastIdx - segI + 1 or 0
        if rangeN < 1 or rangeN > MDADFollower.LANE_MAX then
            sourceValid, verifiedEnd, failReason =
                false, lineS0, "capacity"
        else
            -- Every driven chord is split at its midpoint. Each half must share
            -- one convex eroded source capsule; endpoints alone cannot prove a
            -- chord inside a non-convex source-band union.
            for si = segI, lastIdx do
                if prof.s[si] >= verifiedEnd then break end
                local h = prof.segH[si]
                local x0 = prof.x[si] - sin(h) * lane
                local y0 = prof.y[si] + cos(h) * lane
                local x1 = prof.x[si + 1] - sin(h) * lane
                local y1 = prof.y[si + 1] + cos(h) * lane
                local sa, sb = prof.segSourceA[si], prof.segSourceB[si]
                if not MDADDynamics.chordCoveredByBand(
                        rawPts, rawWidths, sa, sb,
                        halfW, x0, y0, x1, y1) then
                    local failS = prof.s[si] - MDADFollower.OV_STEP
                    if failS < lineS0 then failS = lineS0 end
                    if failS < verifiedEnd then
                        verifiedEnd, failReason = failS, "band"
                    end
                    break
                end
            end
        end
    else
        verifiedEnd, failReason = lineS0, "band"
    end

    -- SEG_FALLBACK already contributes its conservative corner speed to
    -- profileEnvelope; the marker itself is never a proof veto.
    local minBrake, minLat, minCoast =
        s.horizonMinBrake, s.horizonMinLat, s.horizonMinCoast
    local kappa, envelopeOk = 0, false
    if finite(minBrake) and minBrake > 0
            and finite(minLat) and minLat >= 0
            and finite(minCoast) and minCoast >= 0 then
        s.verifyLineN = lineN
        for k = 1, lineN do
            local localKappa = 0
            if k > 1 and k < lineN then
                localKappa = MDADDynamics.circumcircleKappa(
                    verifyX[k - 1], verifyY[k - 1],
                    verifyX[k], verifyY[k],
                    verifyX[k + 1], verifyY[k + 1])
            end
            if localKappa > kappa then kappa = localKappa end
            s.verifyKappa[k] = localKappa
            if k < lineN then
                local dx = verifyX[k + 1] - verifyX[k]
                local dy = verifyY[k + 1] - verifyY[k]
                s.verifyDist[k] = sqrt(dx * dx + dy * dy)
            end
        end
        s.envelopeBuildLat, s.envelopeBuildCoast = -1, -1
        s.laneCurveS0, s.laneCurveEnd = lineS0, proofEnd
        envelopeOk = refreshLaneCurveEnvelope(s, minCoast, minLat)
        if envelopeOk then s.laneCurveStamp = sen.stamp end
    end
    s.proofKappa = kappa
    if not envelopeOk then
        verifiedEnd, failReason = lineS0, "dynamics"
    end

    local loadedEnd = proofEnd
    if not finite(sen.scanEndS) then
        loadedEnd = lineS0
    elseif sen.scanEndS < loadedEnd then
        loadedEnd = sen.scanEndS
    end
    if sen.unloaded then
        local unloadedEnd = sen.unloadedS
        if finite(unloadedEnd) then
            unloadedEnd = unloadedEnd - MDADFollower.OV_STEP
        else
            unloadedEnd = lineS0
        end
        if unloadedEnd < loadedEnd then loadedEnd = unloadedEnd end
    end
    if loadedEnd < lineS0 then loadedEnd = lineS0 end
    if loadedEnd < verifiedEnd then
        verifiedEnd, failReason = loadedEnd, "unloaded"
    end

    local sweepRan = false
    if sourceValid and envelopeOk and verifiedEnd > lineS0 then
        local sweepN, sweepEnd
        -- buildLaneLine clamps its final point to proofEnd; floor-snapping here
        -- would otherwise discard a final segment shorter than OV_STEP.
        if verifiedEnd >= proofEnd - 1e-6 then
            sweepN, sweepEnd = lineN, proofEnd
        else
            local span = (verifiedEnd - lineS0) / MDADFollower.OV_STEP
            local whole = span - span % 1
            sweepN = whole + 1
            sweepEnd = lineS0 + whole * MDADFollower.OV_STEP
        end
        if sweepN >= 2 then
            sweepRan = true
            if sweepEnd < verifiedEnd then verifiedEnd = sweepEnd end
            local sweepOk, _, _, _, sweepAt = sweepLine(
                s, s.verifyX, s.verifyY, sweepN, lineS0, sweepEnd,
                s.lastSNow, s.lastSNow, sweepEnd, sweepEnd,
                lane, "profile", s.sweepBase)
            if not sweepOk then
                local safeEnd = finite(sweepAt)
                    and sweepAt - MDADFollower.OV_STEP or lineS0
                if safeEnd < lineS0 then safeEnd = lineS0 end
                if safeEnd < verifiedEnd then
                    verifiedEnd, failReason = safeEnd, "sweep"
                end
            end
        end
    end

    s.verifyBand = sourceValid and verifiedEnd > lineS0
    s.verifySweep = sweepRan and verifiedEnd > lineS0
    s.curveVerifiedUntilS = verifiedEnd
    s.verifyLineReason = failReason or "ok"
end

local function returnAvailable(s)
    return s.sensor ~= false and type(s.sensor) == "table"
        and type(MDADSensor) == "table"
        and type(MDADSensor.step) == "function"
        and type(MDADSensor.reset) == "function"
        and type(MDADSensor.probeLateral) == "function"
        and finite(MDADSensor.CORRIDOR_HALF) and MDADSensor.CORRIDOR_HALF > 0
        and type(MDADCorridor) == "table"
        and type(MDADCorridor.orientedDistanceSqUnchecked) == "function"
        and finite(MDADCorridor.OBS_HALF) and MDADCorridor.OBS_HALF >= 0
        and type(MDADFollower.buildReturnLine) == "function"
        and type(MDADFollower.setExactLine) == "function"
        and finite(MDADFollower.OV_STEP) and MDADFollower.OV_STEP > 0
end

local function probeReturnLateral(s, vehicle, lateralM)
    if not s.sensor or type(MDADSensor.probeLateral) ~= "function" then return false end
    local vec = BaseVehicle.allocVector3f()
    vehicle:getForwardVector(vec)
    local fx, fy = vec:x(), vec:z()
    local f2 = fx * fx + fy * fy
    local clear = false
    if f2 > 1e-6 then
        local inv = 1 / sqrt(f2)
        fx, fy = fx * inv, fy * inv
        local bx, by = bodyCenter(s, vehicle, vec)
        if bx ~= nil then
            local status = MDADSensor.probeLateral(s.sensor, vehicle, getCell(),
                bx, by, fx, fy, -fy, fx, s.vehicleProfile.halfW,
                s.vehicleProfile.halfL, lateralM)
            clear = status == "clear"
        end
    end
    BaseVehicle.releaseVector3f(vec)
    return clear
end

local function returnLineBandCovers(s, lx, ly, ln, lineS0, lineS1, pad, startK)
    local band = s.sensor and s.sensor.completedBandBias
    if not finite(ln) or ln < 2 or not finite(lineS0)
            or not finite(lineS1) then return false end
    local lastStart = lineS0 + (ln - 2) * MDADFollower.OV_STEP
    if not finite(band) or lineS1 <= lastStart
            or lineS1 > lastStart + MDADFollower.OV_STEP + 1e-6
            or not finite(pad) or type(lx) ~= "table"
            or type(ly) ~= "table" then return false end
    if not finite(startK) then startK = 1 else startK = startK - startK % 1 end
    if startK < 1 then startK = 1 end
    local profile = s.profile
    local seg = s.fstate.idx
    if not finite(seg) then seg = 1 else seg = seg - seg % 1 end
    local segHi = profile.n - 1
    if seg < 1 then seg = 1 elseif seg > segHi then seg = segHi end
    while seg > 1 and profile.s[seg] > lineS0 do seg = seg - 1 end
    while seg < segHi and profile.s[seg + 1] < lineS0 do seg = seg + 1 end
    local lastFx, lastFy = 1, 0
    local bandLo, bandHi = band - MDADSensor.CORRIDOR_HALF,
        band + MDADSensor.CORRIDOR_HALF
    local obs = MDADCorridor.OBS_HALF or 0.7
    for k = startK, ln do
        local sk = k == ln and lineS1
            or (lineS0 + (k - 1) * MDADFollower.OV_STEP)
        while seg < profile.n - 1 and profile.s[seg + 1] < sk do seg = seg + 1 end
        local segLen = profile.segLen[seg]
        local t = segLen > 0 and (sk - profile.s[seg]) / segLen or 0
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        local rx = profile.x[seg] + (profile.x[seg + 1] - profile.x[seg]) * t
        local ry = profile.y[seg] + (profile.y[seg + 1] - profile.y[seg]) * t
        local h = profile.segH[seg]
        local nrX, nrY = -sin(h), cos(h)
        local k0, k1 = k, k + 1
        if k1 > ln then k0, k1 = k - 1, k end
        local fx, fy = lx[k1] - lx[k0], ly[k1] - ly[k0]
        local f2 = fx * fx + fy * fy
        if f2 > 1e-8 then
            local inv = 1 / sqrt(f2)
            fx, fy = fx * inv, fy * inv
            lastFx, lastFy = fx, fy
        else
            fx, fy = lastFx, lastFy
        end
        local xLeftX, xLeftY = fy, -fx
        local comX, comZ = s.vehicleProfile.centerOfMassX, s.vehicleProfile.centerOfMassZ
        local cx = lx[k] + fx * comZ + xLeftX * comX
        local cy = ly[k] + fy * comZ + xLeftY * comX
        local centerLat = (cx - rx) * nrX + (cy - ry) * nrY
        local fProj = fx * nrX + fy * nrY
        if fProj < 0 then fProj = -fProj end
        local xProj = xLeftX * nrX + xLeftY * nrY
        if xProj < 0 then xProj = -xProj end
        local half = s.vehicleProfile.halfL * fProj
            + s.vehicleProfile.halfW * xProj + obs + pad
        if centerLat - half < bandLo or centerLat + half > bandHi then return false end
    end
    return true
end

local function invalidateReturnControl(s)
    if not s.returnActive then return end
    MDADFollower.clearOffset(s.fstate)
    s.returnUnsafe, s.returnHold = true, true
    s.returnCrawlExact, s.returnCapacityFault = false, false
    if s.sensor and type(MDADSensor) == "table"
            and type(MDADSensor.reset) == "function" then
        MDADSensor.reset(s.sensor)
        s.sensor.scanBias = (s.returnLaneStart + s.returnLaneTarget) * 0.5
    end
end

local function holdUnsafeReturn(s, vehicle, latSigned, reason)
    MDADFollower.clearOffset(s.fstate)
    MDADFollower.setLaneBias(s.fstate, latSigned)
    s.returnUnsafe, s.returnHold = true, true
    s.returnLaneStart = latSigned
    s.returnCapacityFault = reason == "capacity"
    s.planMode = reason == "unloaded" and "return-unloaded"
        or (s.returnCapacityFault and "return-capacity" or "return-unsafe")
    if s.returnCapacityFault or reason == "invalid" or reason == "band" then return end
    local pad = s.sweepBase - s.vehicleProfile.halfW
    if pad < SWEEP_PHYS_PAD then pad = SWEEP_PHYS_PAD end
    if not probeReturnLateral(s, vehicle, 0) then return end
    local brake = s.safeBrake
    if not finite(brake) or brake <= 0 then return end
    local speed = vehicle:getCurrentSpeedKmHour()
    if not finite(speed) then return end
    if speed < 0 then speed = -speed end
    local v = speed / 3.6
    local horizon = v * 0.5 + v * v / (2 * brake)
        + s.vehicleProfile.halfL + 2
    if horizon < 4 then horizon = 4 end
    local s0, s1 = s.lastSNow, s.lastSNow + horizon
    if s1 > s.profile.length then s1 = s.profile.length end
    local coverageEnd = s1 + s.vehicleProfile.halfL + pad
    if coverageEnd > s.profile.length then coverageEnd = s.profile.length end
    if s1 <= s0 or s.sensor.scanEndS < coverageEnd
            or (s.sensor.unloaded and finite(s.sensor.unloadedS)
                and s.sensor.unloadedS <= coverageEnd) then return end
    local n, lineS0, _, lineS1 = MDADFollower.buildReturnLine(
        s.profile, s0, s1, latSigned, latSigned, s.returnX, s.returnY, 1)
    if n < 2 then return end
    if not returnLineBandCovers(
            s, s.returnX, s.returnY, n, lineS0, lineS1, pad, 1) then return end
    local clear = sweepLine(s, s.returnX, s.returnY, n, lineS0, lineS1,
        s0, s1, s1, coverageEnd, latSigned, "return-crawl", s.sweepBase)
    if clear and MDADFollower.setExactLine(
            s.fstate, s.returnX, s.returnY, n, lineS0, lineS1) then
        s.returnHold = false
        s.returnCrawlExact = true
        s.returnStartS, s.returnEndS = s0, s1
        s.sensor.scanBias = latSigned
    end
end

-- Runs only on a completed immutable sensor snapshot. isDoingOffroad
-- (BaseVehicle.java:9029-9042) is auxiliary evidence: only v4 declared paved
-- plus a known non-paved floor can accumulate mismatch rounds.
local function updateReturnSnapshot(s, vehicle, playerNum, latSigned)
    local sen = s.sensor
    if s.rain ~= sen.rain then s.rain = sen.rain end
    local okOff, physical = pcall(jget, vehicle, "isDoingOffroad")
    s.physicalOffroad = okOff and physical == true
    local actual = sen.actualSurfaceId or 0
    local mismatch = s.navVersion >= 4
        and s.currentSurfaceId == MDADFollower.SURFACE_PAVED
        and actual ~= MDADSensor.SURFACE_UNKNOWN
        and actual ~= MDADSensor.SURFACE_PAVED
        and s.physicalOffroad
    if mismatch then
        s.surfaceMismatchRounds = s.surfaceMismatchRounds + 1
    else
        s.surfaceMismatchRounds = 0
    end
    s.surfaceMismatch = s.surfaceMismatchRounds >= 2
    if not s.returnActive or not finite(latSigned) then return end
    local returnPad = s.sweepBase - s.vehicleProfile.halfW
    if returnPad < SWEEP_PHYS_PAD then returnPad = SWEEP_PHYS_PAD end

    local dev = latSigned - s.returnLaneTarget
    if dev < 0 then dev = -dev end
    if dev <= RETURN_CLEAR_DEV then
        s.returnClearRounds = s.returnClearRounds + 1
    else
        s.returnClearRounds = 0
    end
    if s.returnActive and not returnAvailable(s) then
        MDADFollower.clearOffset(s.fstate)
        s.returnActive, s.returnUnsafe, s.returnHold = false, false, false
        s.returnCrawlExact, s.returnCapacityFault = false, false
        return
    end
    if s.returnClearRounds >= 2 then
        s.returnActive, s.returnUnsafe, s.returnHold = false, false, false
        s.returnCrawlExact, s.returnCapacityFault = false, false
        s.returnReason, s.returnClearRounds = nil, 0
        MDADFollower.clearOffset(s.fstate)
        MDADFollower.setLaneBias(s.fstate, s.returnLaneTarget)
        s.sensor.scanBias = s.returnLaneTarget
        s.planMode = "return-clear"
        diagEvent(s, playerNum, "return", { phase = "clear", why = "aligned" })
        return
    end
    if s.fstate.exactLine == true then
        local ovN, ovS0 = s.fstate.ovN, s.fstate.ovS0
        local startK = (s.lastSNow - ovS0) / MDADFollower.OV_STEP + 1
        startK = startK - startK % 1
        if startK < 1 then startK = 1 end
        local lineEnd = s.fstate.ovEndS
        local guardEnd = lineEnd
        local bandOk = returnLineBandCovers(
            s, s.fstate.ovX, s.fstate.ovY, ovN, ovS0, lineEnd,
            returnPad, startK)
        local guardUnloaded = not bandOk or sen.scanEndS < guardEnd
            or (sen.unloaded and finite(sen.unloadedS) and sen.unloadedS <= guardEnd)
        local guardOk = false
        local lateral = s.returnLaneTarget - latSigned
        if not guardUnloaded and startK <= ovN
                and probeReturnLateral(s, vehicle, lateral) then
            guardOk = sweepLine(
                s, s.fstate.ovX, s.fstate.ovY, ovN, ovS0, lineEnd,
                s.returnStartS, s.returnEndS, s.returnEndS, lineEnd,
                s.returnLaneTarget, "return-guard", s.sweepBase, startK)
        end
        if guardOk then
            if not s.returnCrawlExact then return end
            MDADFollower.clearOffset(s.fstate)
            s.returnCrawlExact = false
        else
            s.sensor.scanBias = s.returnCrawlExact
                and latSigned or ((latSigned + s.returnLaneTarget) * 0.5)
            holdUnsafeReturn(s, vehicle, latSigned,
                guardUnloaded and "unloaded" or "unsafe")
            return
        end
    end

    local laneStart, laneTarget = latSigned, s.returnLaneTarget
    local delta = laneTarget - laneStart
    if delta < 0 then delta = -delta end
    local length = 4 * delta
    local bodyLength = 2 * s.vehicleProfile.halfL
    if length < 8 then length = 8 end
    if length < bodyLength then length = bodyLength end
    local s0 = s.lastSNow
    local s1 = s0 + length
    if s1 > s.profile.length then s1 = s.profile.length end
    local lookScale = s.profile.lookScale
    if not finite(lookScale) or lookScale <= 0 then lookScale = 1 end
    local pad = returnPad
    s.sensor.scanBias = (laneStart + laneTarget) * 0.5
    local tail = 18 * lookScale + s.vehicleProfile.halfL + pad
    local coverageEnd = s1 + tail
    local tailSteps = (coverageEnd - s0) / MDADFollower.OV_STEP
    local wholeTail = tailSteps - tailSteps % 1
    if tailSteps > wholeTail then coverageEnd = s0 + (wholeTail + 1) * MDADFollower.OV_STEP end
    if coverageEnd > s.profile.length then coverageEnd = s.profile.length end
    local lineN, lineS0, buildReason, lineS1 = MDADFollower.buildReturnLine(
        s.profile, s0, s1, laneStart, laneTarget, s.returnX, s.returnY, tail)
    coverageEnd = lineS1
    if buildReason == "capacity" then
        holdUnsafeReturn(s, vehicle, laneStart, "capacity")
        return
    end
    if not returnLineBandCovers(
            s, s.returnX, s.returnY, lineN, lineS0, lineS1, pad, 1) then
        holdUnsafeReturn(s, vehicle, laneStart, "band")
        return
    end
    local unloaded = not sen.ready or sen.scanEndS < coverageEnd
        or (sen.unloaded and finite(sen.unloadedS) and sen.unloadedS <= coverageEnd)
    if unloaded then
        holdUnsafeReturn(s, vehicle, laneStart, "unloaded")
        return
    end
    if lineN < 2 or not probeReturnLateral(s, vehicle, laneTarget - laneStart) then
        holdUnsafeReturn(s, vehicle, laneStart, buildReason or "unsafe")
        return
    end
    local safe = false
    if lineN >= 2 then
        safe = sweepLine(s, s.returnX, s.returnY, lineN, lineS0, lineS1,
            s0, s1, s1, coverageEnd, laneTarget, "return", s.sweepBase)
    end
    if safe and MDADFollower.setExactLine(
            s.fstate, s.returnX, s.returnY, lineN, lineS0, lineS1) then
        s.returnUnsafe, s.returnHold, s.returnCapacityFault = false, false, false
        s.returnCrawlExact = false
        s.returnStartS, s.returnEndS = s0, s1
        s.returnLaneStart = laneStart
        MDADFollower.setLaneBias(s.fstate, laneTarget)
        s.planMode = "return"
        diagEvent(s, playerNum, "return", {
            phase = "commit", why = s.returnReason, s = s0, d = s1,
        })
    else
        holdUnsafeReturn(s, vehicle, laneStart, buildReason or "unsafe")
    end
end

-- 過渡段提早完成（理由見 CURVE_LEAD 常數註解）：剖面 a..d 內有折點且過渡
-- 完成點 b 離折點不足 CURVE_LEAD 時，把 a/b 前移——側移在進彎前的直段做完、
-- 彎中保持段全程蓋住折點，掃掠線不再切角掃到彎外側障礙。只早不晚（更保守）；
-- a 不得早於車前 1m、b 不得晚於折點也不得超過 c。擠不下就沿用原剖面。
-- 剖面塑形：進入段（a..b）與收回段（c..d）都不得跨路線折點——offL 在折點
-- 兩側指向不同世界方向，跨折點的過渡線必然斜切彎角障礙（2026-08-29 回程皮卡
-- 兩役：進入段半途 lane 打槍→後移策略；收回段半途 lane 打槍→延後收回）。
local function shapeProfile(s, profile, a, b, c, d, offL, baseL)
    local sTurn = turnPeakS(profile, a, d + 6)
    local minA = s.lastSNow + 1
    if sTurn then
        if b > sTurn - CURVE_LEAD and a < sTurn then
            local span = b - a
            local a2 = sTurn - CURVE_LEAD - span
            local placed = false
            if a2 >= minA then
                local b2 = a2 + span
                if b2 > sTurn then b2 = sTurn end
                if b2 > a2 and b2 <= c then
                    a, b = a2, b2
                    placed = true
                end
            end
            if not placed then
                local a3 = sTurn + 0.5
                if a3 < minA then a3 = minA end
                local sp3 = span
                if sp3 > 3 then sp3 = 3 end
                local b3 = a3 + sp3
                if b3 < c and a3 < b3 then a, b = a3, b3 end
            end
        end
        if sTurn > c - 2 and d < sTurn + 4 and sTurn >= b then
            local span2 = d - c
            if span2 > 4 then span2 = 4 end
            c = sTurn + 1
            d = c + span2
        end
    end

    local dl = offL - baseL
    if dl < 0 then dl = -dl end
    local intended = profile.maxSpeed
    if finite(s.profileEnvelope) and s.profileEnvelope >= 0
            and s.profileEnvelope < intended then intended = s.profileEnvelope end
    if finite(s.gearCap) and s.gearCap >= 0
            and s.gearCap < intended then intended = s.gearCap end
    if finite(s.visibilityCap) and s.visibilityCap >= 0
            and s.visibilityCap < intended then intended = s.visibilityCap end
    local crawl = MDADDynamics.DODGE_SQUEEZE_CAP
    if intended < crawl then intended = crawl end
    local vp = s.vehicleProfile
    local kSteer = MDADDynamics.steeringKappa(
        vp.wheelbase, vp.delta0Safe, vp.deltaVSafe, vp.maxSpeed, intended)
    if kSteer <= 0 then kSteer = 1 / 6 end
    local _, aLat = MDADFollower.minDynamics(
        profile, a, d, s.fstate.idx)
    if finite(s.safeLat) and s.safeLat >= 0 and s.safeLat < aLat then
        aLat = s.safeLat
    end
    if not finite(aLat) or aLat <= 0 then
        s.dodgeSpaceCap = 0
        return a, b, c, d, false
    end
    s.dodgeDesignSpeed = intended
    local required = MDADDynamics.shiftLength(
        dl, intended / 3.6, aLat, kSteer, vp.halfL, MDADDynamics.LATERAL_JERK_MAX)
    local crawlK = MDADDynamics.steeringKappa(
        vp.wheelbase, vp.delta0Safe, vp.deltaVSafe, vp.maxSpeed, crawl)
    if crawlK <= 0 then crawlK = 1 / 6 end
    local minimum = MDADDynamics.shiftLength(
        dl, 0, aLat, crawlK, vp.halfL, MDADDynamics.LATERAL_JERK_MAX)
    local entryAvail, exitAvail = b - minA, profile.length - c
    -- 空間延長不得把已避開折點的轉場再拉回跨越折點：entry 只能延到折點後
    -- 0.5m，exit 轉場整段停在下一折點前 2m（窗寬涵蓋整個可延長範圍，
    -- 也擋住原 a..d+6 窗外的新折點）。放不進 minimum 就維持 blocked。
    local entryPeak = turnPeakS(profile, minA, b)
    if entryPeak and b > entryPeak then
        local room = b - (entryPeak + 0.5)
        if room < entryAvail then entryAvail = room end
    end
    local exitPeak = turnPeakS(
        profile, c, s.lastSNow + TUNE.DODGE_OV_SPAN + 6)
    if exitPeak and exitPeak > c then
        local room = exitPeak - 2 - c
        if room < exitAvail then exitAvail = room end
    end
    s.dodgeShiftLength = required
    s.dodgeSpaceCap = profile.maxSpeed
    if required <= 0 or minimum <= 0 or entryAvail <= 0 or exitAvail <= 0 then
        s.dodgeSpaceCap = 0
        return a, b, c, d, false
    end
    if required < minimum then required = minimum end
    local exitRoom = s.lastSNow + TUNE.DODGE_OV_SPAN - c
    -- 最小（crawl 速）側移長度必須放得進實際空間，否則維持 blocked 停等；
    -- 只有「超出最小值的延長」允許被可用空間截短。
    if minimum > entryAvail or minimum > exitAvail or minimum > exitRoom then
        s.dodgeSpaceCap = 0
        return a, b, c, d, false
    end
    local entryLen = required > entryAvail and entryAvail or required
    local exitLen = required > exitAvail and exitAvail or required
    if exitLen > exitRoom then exitLen = exitRoom end
    local entryCap = MDADDynamics.shiftSpaceSpeedCapKmh(
        dl, entryLen, aLat, vp.wheelbase, vp.delta0Safe, vp.deltaVSafe,
        vp.maxSpeed, MDADDynamics.LATERAL_JERK_MAX)
    local exitCap = MDADDynamics.shiftSpaceSpeedCapKmh(
        dl, exitLen, aLat, vp.wheelbase, vp.delta0Safe, vp.deltaVSafe,
        vp.maxSpeed, MDADDynamics.LATERAL_JERK_MAX)
    s.dodgeSpaceCap = entryCap
    if exitCap < s.dodgeSpaceCap then s.dodgeSpaceCap = exitCap end
    s.dodgeCommittedLength = entryLen
    if exitLen < s.dodgeCommittedLength then s.dodgeCommittedLength = exitLen end
    a, d = b - entryLen, c + exitLen
    return a, b, c, d, true
end

-- Candidate sweep and commitment consume the same complete preallocated line.
local function sweepCandidate(s, shapeOk, a, b, c, d, offL, baseL, tag, needBase)
    if not shapeOk then return 0, 0, false, 99, b, 3, b, 0, 0 end
    local ovN, ovS0, buildReason, lastCovered = MDADFollower.buildOffsetLine(
        s.profile, s.lastSNow, a, b, c, d, offL, baseL, s.tmpOvX, s.tmpOvY)
    s.dodgeBuildReason = buildReason
    if ovN < 2 or buildReason ~= "ok" or lastCovered < d + 1 - 1e-6 then
        return 0, ovS0, false, 99, b, 3, b, 0, 0
    end
    s.tmpOvEndS = lastCovered
    return ovN, ovS0, sweepLine(
        s, s.tmpOvX, s.tmpOvY, ovN, ovS0, lastCovered,
        a, b, c, d, offL, tag, needBase)
end

-- 掃描輪完成或障礙簽章變化時重規劃（事件驅動：布局沒變就一次都不算）。
-- 決策全在 MDADCorridor（純數學）；這裡只把結果翻成 follower 的側偏剖面與
-- blocked 旗標。政策=停車（ObstaclePolicy=2）時就算有縫隙也不繞，一律煞停等待。
local function replan(s, vehicle, playerNum)
    local sen = s.sensor
    if not sen.ready then return end
    diagEvent(s, playerNum, "replan")
    -- 掃描摘要：只在布局變化（sig 變）才進 replan，一行不會洗版——實機分析
    -- 「感知有沒有看到那棵樹／那台車」全靠這行（2026-08-28 使用者授權加強診斷）
    if getDebug() then
        print(string.format("%spn=%d scan hardN=%d zombies=%d corpses=%d soft=%d veh=%d roadN=%d unloaded=%s",
            LOG, playerNum, sen.hardN, sen.zombieN, sen.corpseN, sen.softN, sen.vehN,
            sen.roadN or 0, tostring(sen.unloaded)))
    end
    -- ===== immutable DODGE（2026-08-28 雙模型對抗審共識）=====
    -- 剖面一旦承諾就**不可變**：執行中每輪只做守護驗證（政策＋世界空間掃掠），
    -- 不重新選縫、不換邊、不因 clear 提前釋放（多繞幾公尺比換邊安全）。
    -- 「每輪重規劃可覆寫執行中的運動承諾」是實測 offL 逐輪翻面震盪的結構性
    -- 根因——路口折角區的幾何投影天然抖動、縫可行性逐輪翻轉，任何排序偏好
    -- 都鎮不住；唯一穩定解是承諾＋驗證＋失效降級停等。
    if s.dodging then
        local fs = s.fstate
        local curOffL = fs.offL
        if curOffL == nil or type(fs.offD) ~= "number" or s.lastSNow >= fs.offD then
            -- 剖面走完（或已被外部清除）：釋放承諾，本輪 fall through 正常規劃
            MDADFollower.clearOffset(fs)
            releaseDodge(s)
        else
            local guardOk, guardMargin = false, 0
            if MDAD.sandbox("ObstaclePolicy", POLICY_DODGE) == POLICY_DODGE
                    and (fs.ovN or 0) >= 2 then
                guardOk, guardMargin = sweepLine(
                    s, fs.ovX, fs.ovY, fs.ovN, fs.ovS0, fs.ovEndS,
                    fs.offA, fs.offB, fs.offC, fs.offD,
                    curOffL, "guard", s.dodgeNeed)
            end
            if guardOk then
                local minBrake, minLat = MDADFollower.minDynamics(
                    s.profile, fs.offA, fs.offD, s.fstate.idx)
                if finite(s.safeBrake) and s.safeBrake >= 0
                        and s.safeBrake < minBrake then minBrake = s.safeBrake end
                if finite(s.safeLat) and s.safeLat >= 0
                        and s.safeLat < minLat then minLat = s.safeLat end
                local kappa = MDADDynamics.polylineKappaMax(fs.ovX, fs.ovY, fs.ovN)
                local curveCap = MDADDynamics.curveSpeedCapKmh(kappa, minLat,
                    s.vehicleProfile.wheelbase, s.vehicleProfile.delta0Safe,
                    s.vehicleProfile.deltaVSafe, s.vehicleProfile.maxSpeed)
                local visibilityCap = MDADDynamics.visibilityCapKmh(
                    visibleEndS(sen, s.lastSNow) - s.lastSNow,
                    0.5, minBrake, s.vehicleProfile.halfL)
                local dl = curOffL - laneBiasOf(s)
                if dl < 0 then dl = -dl end
                local sh = 0.05
                if finite(s.dodgeCommittedLength) and s.dodgeCommittedLength > 0 then
                    sh = 1.5 * dl / s.dodgeCommittedLength
                    if sh > 1 then sh = 1 end
                end
                local clearanceCap = MDADDynamics.clearanceCapKmh(
                    guardMargin, TUNE.DODGE_CLEARANCE_RESERVE, 0.5, minLat, sh)
                local classId = sen.movingVeh
                    and MDADDynamics.DODGE_VEHICLE or MDADDynamics.DODGE_STATIC
                -- A recovery episode has not yet proved 10m of clean progress;
                -- recommitted dodges stay at crawl speed instead of re-hitting the site.
                local newCap, _, capReason = MDADDynamics.dodgeSpeedCapKmh(
                    s.gearCap, s.profileEnvelope, curveCap, clearanceCap,
                    visibilityCap, classId, s.dodgeCrawl or s.episodeActive)
                s.dodgeClearance, s.dodgeClass = guardMargin, classId
                s.dodgeCurveCap, s.dodgeClearanceCap = curveCap, clearanceCap
                s.dodgeVisibilityCap = visibilityCap
                local baseCap = s.dodgeBaseCap
                if not finite(baseCap) or baseCap < 0 then
                    s.dodgeSpeedCap = 0
                    s.invalid, s.stateError, s.dynamicsFault =
                        true, "dodge-base-cap", true
                else
                    s.dodgeSpeedCap = newCap < baseCap and newCap or baseCap
                end
                s.dodgeCapPending = s.dodgeSpeedCap <= 0
                if not s.dodgeCapPending then s.dodgeBlockReason = nil end
                if capReason == "dynamics-invalid" then
                    s.invalid, s.stateError, s.dynamicsFault =
                        true, "dodge-cap", true
                end
                if s.dodgeSpeedCap <= 0 then
                    guardOk = false
                    s.dodgeBlockReason = capReason or "dodge-cap"
                    s.planSig = -1
                end
            end
            if not guardOk then
                -- 守護驗證失敗：轉 blocked，剖面保留——車還在動時清剖面＝目標
                -- 線瞬跳，近停後才清（stepFollow 收尾）。煞停基準＝前方最近的
                -- 硬障礙弧長：保留漸進接近（>15m 爬行、15m 內煞停）。繞行中
                -- 前方遠處變堵死就地急煞不合理（隊友後車追撞）；找不到前方
                -- 障礙（政策中途改掉）才就地停。
                if not s.blocked then
                    s.blocked = true
                    local bs = nil
                    for i = 1, sen.hardN do
                        local hs = sen.hardS[i]
                        if hs >= s.lastSNow and (bs == nil or hs < bs) then bs = hs end
                    end
                    s.blockS = bs or s.lastSNow
                    if not s.blockedNotified then
                        s.blockedNotified = true
                        local playerObj = getSpecificPlayer(playerNum)
                        if playerObj then haloBad(playerObj, KEY_BLOCKED) end
                        diagEvent(s, playerNum, "blocked")
                    end
                    if getDebug() then
                        print(LOG .. "pn=" .. playerNum .. " dodge guard failed: hold & brake")
                    end
                end
            elseif s.blocked then
                -- 驗證恢復（單輪抖動自癒）：解除煞停、繼續執行剖面
                s.blocked = false
                s.blockedNotified = false
            end
            -- 純觀測分類（遙測用；不影響任何決策）：守護輪的兩種結局在 log 裡
            -- 必須分得開——同樣是 dodging，guard-blocked 那幀是煞停的起因。
            s.planMode = s.blocked and "guard-blocked" or "guard"
            return
        end
    end
    -- BLOCKED_CORNER latch：障礙仍在且**車沒移動**時不重跑候選鏈——原地
    -- 重試不產生新資訊（codex 裁決）。但漸進接近讓車前進＝幾何變了（實測
    -- 「靠很近開導航就能繞」：近距下路線折點退化、障礙變普通直路障礙），
    -- 前進 CORNER_RETRY_DIST 就撤銷 latch 重新枚舉——手動近開流程的自動化。
    if s.blocked and s.cornerLatch and sen.hardN > 0 then
        if s.lastSNow - s.cornerS < CORNER_RETRY_DIST then
            s.planMode = "corner-latched"
            return
        end
        s.cornerLatch = false
    end
    local mode, a, b, c, d, offL
    local commitNb = nil -- 本輪 commit 的掃掠淨距檔位（setOffset 成功時寫進承諾守護）
    if sen.hardN == 0 and s.pushBanL == nil then
        mode = "clear"
    elseif type(MDADCorridor) ~= "table" or type(MDADCorridor.plan) ~= "function" then
        -- Corridor 是選配：模組不完整時回到既有 M3 pure follower，不阻擋啟動或 HOLD。
        mode = "clear"
    else
        -- 第六參數＝搜尋中心：繞行中沿用上輪側偏防翻側；首次用 laneBias，選
        -- 離目前行駛線橫移最小的安全縫。第八參數＝行駛基準線：擋線判定以
        -- 「車實際要走的線」為中心（以中心線判會漏掉不擋中線但擋行駛線的
        -- 路緣樹，車直接蹭上卡死——2026-08-28 實機 lat=1.2 卡死 ×3）。
        -- 完整契約見 MDADCorridor.plan。
        local baseL = laneBiasOf(s)
        -- 搜尋中心＝行駛基準線（immutable DODGE 後 replan 只發生在無承諾時，
        -- 舊的 lastOffL 側別記憶已無讀者——側別穩定性由「承諾不可變」保證）
        local prefer = baseL
        -- 推撞 ban（物理回饋）：實體卡住過的縫塞虛擬障礙，整個 episode 不再提
        local planN = sen.hardN
        if s.pushBanL ~= nil then
            planN = planN + 1
            sen.hardS[planN] = s.pushBanS
            sen.hardL[planN] = s.pushBanL
            sen.hardX[planN] = 0
            sen.hardY[planN] = 0
            sen.hardR[planN] = 0.6 -- ban 帶 ±(0.6+needHalf)：蓋住鄰近格點
        end
        mode, a, b, c, d, offL = MDADCorridor.plan(
            sen.hardS, sen.hardL, planN, s.needHalf, MDADSensor.CORRIDOR_HALF,
            prefer, sen.hardR, baseL, sen.roadLo, sen.roadHi, s.pushBanL == nil)
        s.dodgeTight = false
        s.dodgeCrawl = false
        local needUsed = s.needHalf
        -- 彎道繞行：障礙群（b..c＝含保持餘裕的實體範圍）落在彎道段時，用放大的
        -- 需求半寬重算——內輪差與切內彎吃掉的餘裕先扣掉再判縫隙。判得過＝採
        -- 加嚴縫（位置更保守）；判不過＝**沿用普通縫降級爬行**，不直接 blocked
        -- ——內輪差的一階補償在爬行速度下大幅縮小，真擦撞由 sweepClear 世界
        -- 空間複驗把關（2026-08-28 實機：彎道兩台並排車，普通縫過得去卻被
        -- 加嚴判死 → blocked → 煞停 → 卡死脫困鬼打牆；使用者定案：有障礙時
        -- 允許離開道路繞行）。兩種 case 都壓爬行（dodgeTight）。
        if mode == "dodge" and routeTurnWithin(s.profile, a, d) > CURVE_TIGHT_RAD then
            local m2, a2, b2, c2, d2, o2 = MDADCorridor.plan(
                sen.hardS, sen.hardL, planN, s.needHalf + CURVE_NEED_EXTRA,
                MDADSensor.CORRIDOR_HALF, prefer, sen.hardR, baseL,
                sen.roadLo, sen.roadHi, s.pushBanL == nil)
            s.dodgeTight = true
            if m2 == "dodge" then
                mode, a, b, c, d, offL = m2, a2, b2, c2, d2, o2
                needUsed = s.needHalf + CURVE_NEED_EXTRA
            end
            if getDebug() then
                print(LOG .. "pn=" .. playerNum .. " curve dodge: "
                    .. (m2 == "dodge" and "wider gap ok, crawl"
                        or "narrow gap, crawl (sweep-guarded)"))
            end
        end
        if mode == "dodge" and d <= s.lastSNow + 1 then
            -- 剖面整段在車後（掃描帶起點在車後 2m，後方殘點讓 plan 提出
            -- d < lastSNow 的假剖面）：commit 會被每幀釋放檢查立即清掉，
            -- commit→release 循環讓速度帽 flap（2026-08-29 實測 31 target
            -- 撞進樹叢）。前方淨空＝走 clear 語意。
            mode = "clear"
        end
        if mode == "dodge"
                and MDAD.sandbox("ObstaclePolicy", POLICY_DODGE) ~= POLICY_DODGE then
            mode = "blocked"
        end
        -- 世界空間掃掠複驗：最後防線（弧座標失真、量化、膨脹近似全部在此收口）。
        -- 被否決的縫**當一顆虛擬障礙塞進快照尾格重試一次**：路口折角處弧座標
        -- 判可行、世界座標判擦撞的分歧是常態——沒有重試時 plan 每輪提案同一條
        -- 縫、sweep 每輪否決，dodge↔blocked 震盪走走停停（2026-08-28 實機：
        -- 路左明明有空間，plan 卻反覆撞在 0.25 這條線上）。虛擬點 r=0（ban 帶
        -- ±needHalf，不誤傷鄰縫）、世界座標 (0,0)（離掃掠線極遠＝重試的 sweep
        -- 自動忽略）；hardN 沒動，尾格是垃圾區、下輪快照換手自然覆蓋。
        -- 世界空間掃掠複驗＋單輪候選枚舉（codex 方案 6）：被否決的縫當虛擬
        -- 障礙塞快照尾格 ban 掉、重規劃下一條，第一條世界淨空的才 commit——
        -- 舊版只 retry 一次，更遠的可行縫從沒被試過（2026-08-29 路口實測：
        -- offL 0.25 與 -1.50 打槍後就 blocked，左側整片空間未試）。普通／彎道
        -- 檔全數打槍後降爬行檔（SQUEEZE_NEED）從頭重枚舉——phase 1 被 ban 的
        -- 縫在小需求下可能可行，所以 ban 清空重來。虛擬 ban 點 r=0.25、世界
        -- 座標 (0,0)（離掃掠線極遠＝sweep 自動忽略）；hardN 沒動、尾格垃圾區
        -- 下輪快照換手自然覆蓋。
        if mode == "dodge" then
            local needBase = needUsed - 0.1
            -- BLOCKED_CORNER 分類（codex sol max 架構裁決）：折點處逐段法向不
            -- 連續，「障礙貼折點」在現行 Frenet 軌跡契約下不可安全表達——
            -- baseline 失敗（路線本身撞）或全部候選的失敗都落在折點附近的
            -- entry/exit 相位＝換 lane 不會有新資訊，直接分類 corner、快速
            -- 改道；只有 hold 相位失敗才是「該 lane 真不可行」值得 ban 換縫。
            local sTurnG = turnPeakS(s.profile, s.lastSNow, d + 10)
            local corner = false
            local nonCornerFail = false
            local firstHit, firstHitX, firstHitY = nil, nil, nil
            local committed = false
            local function classify(ph, hps)
                if ph == 1 then
                    corner = true -- baseline：所有 offL 共用的路線段撞＝立即 corner
                    return true
                end
                if (ph == 2 or ph == 4) and sTurnG ~= nil then
                    local dts = hps - sTurnG
                    if dts < 0 then dts = -dts end
                    if dts < CORNER_NEAR then return false end -- corner 類：記錄續試
                end
                nonCornerFail = true
                return false
            end
            local shapeOk
            a, b, c, d, shapeOk = shapeProfile(
                s, s.profile, a, b, c, d, offL, baseL)
            local ovN, ovS0, okS, mgS, hitS, phS, hpsS, hxS, hyS = sweepCandidate(
                s, shapeOk, a, b, c, d, offL, baseL, "plan", needBase)
            if okS then
                commitNb = needBase
                s.dodgeMargin = mgS
                s.lastOvN = ovN
                s.lastOvS0 = ovS0
                s.lastOvEndS = s.tmpOvEndS
            else
                firstHit, firstHitX, firstHitY = hitS, hxS, hyS
                local abortAll = classify(phS, hpsS)
                if not abortAll then
                    for phase = 1, 2 do
                        if phase == 2 and not nonCornerFail then
                            -- 全部失敗都是 corner 類：爬行檔重試不會有新資訊
                            corner = true
                            break
                        end
                        local nu, nb = needUsed, needBase
                        local pa, pb, pc, pd, po = a, b, c, d, offL
                        if phase == 2 then
                            nu = s.squeezeNeed
                            nb = s.squeezeSweepBase
                            local mq, aq, bq, cq, dq, oq = MDADCorridor.plan(
                                sen.hardS, sen.hardL, planN, nu, MDADSensor.CORRIDOR_HALF,
                                prefer, sen.hardR, baseL, sen.roadLo, sen.roadHi, false)
                            if mq ~= "dodge" then break end
                            pa, pb, pc, pd, po = aq, bq, cq, dq, oq
                            local shapeQ
                            pa, pb, pc, pd, shapeQ = shapeProfile(
                                s, s.profile, pa, pb, pc, pd, po, baseL)
                            local okQ, mgQ, hQ, phQ, hpsQ, hxQ, hyQ
                            ovN, ovS0, okQ, mgQ, hQ, phQ, hpsQ, hxQ, hyQ =
                                sweepCandidate(s, shapeQ, pa, pb, pc, pd, po,
                                    baseL, "crawl", nb)
                            if okQ then
                                a, b, c, d, offL = pa, pb, pc, pd, po
                                committed = true
                                commitNb = nb
                                s.dodgeMargin = mgQ
                                s.dodgeCrawl = true
                                s.lastOvN = ovN
                                s.lastOvS0 = ovS0
                                s.lastOvEndS = s.tmpOvEndS
                                break
                            end
                            if hQ ~= nil and (firstHit == nil or hQ < firstHit) then
                                firstHit, firstHitX, firstHitY = hQ, hxQ, hyQ
                            end
                            if classify(phQ, hpsQ) then break end
                        end
                        local banN = planN
                        local aborted = false
                        for _ = 1, DODGE_CANDIDATES do
                            banN = banN + 1
                            sen.hardS[banN] = (pb + pc) * 0.5
                            sen.hardL[banN] = po
                            sen.hardX[banN] = 0
                            sen.hardY[banN] = 0
                            sen.hardR[banN] = 0.25
                            local mk, ak, bk, ck, dk, ok2 = MDADCorridor.plan(
                                sen.hardS, sen.hardL, banN, nu, MDADSensor.CORRIDOR_HALF,
                                prefer, sen.hardR, baseL, sen.roadLo, sen.roadHi, false)
                            if mk ~= "dodge" then break end
                            pa, pb, pc, pd, po = ak, bk, ck, dk, ok2
                            local shapeK
                            pa, pb, pc, pd, shapeK = shapeProfile(
                                s, s.profile, pa, pb, pc, pd, po, baseL)
                            local okK, mgK, hK, phK, hpsK, hxK, hyK
                            ovN, ovS0, okK, mgK, hK, phK, hpsK, hxK, hyK =
                                sweepCandidate(s, shapeK, pa, pb, pc, pd, po, baseL,
                                    phase == 2 and "crawl" or "retry", nb)
                            if okK then
                                a, b, c, d, offL = pa, pb, pc, pd, po
                                committed = true
                                commitNb = nb
                                s.dodgeMargin = mgK
                                if phase == 2 then s.dodgeCrawl = true end
                                s.lastOvN = ovN
                                s.lastOvS0 = ovS0
                                s.lastOvEndS = s.tmpOvEndS
                                break
                            end
                            if hK ~= nil and (firstHit == nil or hK < firstHit) then
                                firstHit, firstHitX, firstHitY = hK, hxK, hyK
                            end
                            if classify(phK, hpsK) then aborted = true; break end
                        end
                        if committed or aborted then break end
                    end
                end
                if committed then
                    if getDebug() then
                        print(string.format("%spn=%d sweep enumerate: offL=%.2f ok%s",
                            LOG, playerNum, offL, s.dodgeCrawl and " (crawl)" or ""))
                    end
                else
                    mode = "blocked"
                    if type(firstHit) == "number" then a = firstHit end
                    if corner or not nonCornerFail then
                        -- BLOCKED_CORNER：latch 到障礙清除／換路線為止——之後的
                        -- replan 輪不再重跑候選鏈（重試沒有新資訊、只是洗 log），
                        -- 改道等待縮短到 CORNER_DETOUR_MS
                        s.cornerLatch = true
                        s.cornerS = s.lastSNow
                        s.blockHitX = firstHitX
                        s.blockHitY = firstHitY
                        if getDebug() then
                            print(LOG .. "pn=" .. playerNum
                                .. " blocked corner: geometry unsupported, fast detour")
                        end
                    elseif getDebug() then
                        print(LOG .. "pn=" .. playerNum
                            .. " dodge failed sweep: blocked (all candidates)")
                    end
                end
            end
        end
        if mode == "dodge" then
            local vp = s.vehicleProfile
            local minBrake, minLat = MDADFollower.minDynamics(
                s.profile, a, d, s.fstate.idx)
            if finite(s.safeBrake) and s.safeBrake >= 0
                    and s.safeBrake < minBrake then minBrake = s.safeBrake end
            if finite(s.safeLat) and s.safeLat >= 0
                    and s.safeLat < minLat then minLat = s.safeLat end
            local kappa = MDADDynamics.polylineKappaMax(
                s.tmpOvX, s.tmpOvY, s.lastOvN or 0)
            local curveCap = MDADDynamics.curveSpeedCapKmh(
                kappa, minLat, vp.wheelbase, vp.delta0Safe, vp.deltaVSafe, vp.maxSpeed)
            local visible = visibleEndS(sen, s.lastSNow) - s.lastSNow
            local visibilityCap = MDADDynamics.visibilityCapKmh(
                visible, 0.5, minBrake, vp.halfL)
            local dl = offL - baseL
            if dl < 0 then dl = -dl end
            local sinHeading = 0.05
            if finite(s.dodgeCommittedLength) and s.dodgeCommittedLength > 0 then
                sinHeading = 1.5 * dl / s.dodgeCommittedLength
                if sinHeading > 1 then sinHeading = 1 end
            end
            local clearanceCap = MDADDynamics.clearanceCapKmh(
                s.dodgeMargin, TUNE.DODGE_CLEARANCE_RESERVE,
                0.5, minLat, sinHeading)
            local profileCap = s.profileEnvelope
            if finite(s.dodgeSpaceCap) and s.dodgeSpaceCap < profileCap then
                profileCap = s.dodgeSpaceCap
            end
            local classId = sen.movingVeh
                and MDADDynamics.DODGE_VEHICLE or MDADDynamics.DODGE_STATIC
            s.dodgeKappa, s.dodgeClearance = kappa, s.dodgeMargin
            s.dodgeCurveCap, s.dodgeClearanceCap = curveCap, clearanceCap
            s.dodgeVisibilityCap, s.dodgeClass = visibilityCap, classId
            local capReason
            -- Same unrearmed-episode crawl contract as the committed guard above.
            s.dodgeSpeedCap, _, capReason = MDADDynamics.dodgeSpeedCapKmh(
                s.gearCap, profileCap, curveCap, clearanceCap, visibilityCap,
                classId, s.dodgeCrawl or s.episodeActive)
            if capReason == "dynamics-invalid" then
                s.invalid, s.stateError, s.dynamicsFault =
                    true, "dodge-cap", true
            end
            if s.dodgeSpeedCap <= 0 then
                mode = "blocked"
                s.dodgeBlockReason = capReason or "dodge-cap"
                if not capReason then s.dodgeBlockReason = "dodge-cap" end
                s.planSig = -1
            end
        end
        -- 偏離道路中（使用者定案：優先回線）：不疊繞行側偏——車在走廊外時
        -- 弧座標表示失真、掃描窗隨投影漂移，dodge 在這種輸入下只會左右震盪。
        -- RETURN 期間 planned blocker 的 Frenet 錨不可信；不另疊 dodge，也不以
        -- blocked 煞停在路外。exact line 的同一組 OBB sweep 已先決定 commit 或
        -- 沿現 lane 8km/h 重試；真正 current-body contact 仍由 OR-gate 升 HOLD。
        if s.returnActive then
            releaseDodge(s)
            s.clearStreak = 0
            s.planMode = "return-suppress"
            return
        end
    end
    if mode == "dodge" then
        -- setOffset 引數不合法回 false（不動 state）：此時寧可當 blocked 煞停，
        s.clearStreak = 0
        -- 也不能無側偏直直開進障礙
        if MDADFollower.setOffset(s.fstate, a, b, c, d, offL,
                s.tmpOvX, s.tmpOvY, s.lastOvN or 0, s.lastOvS0 or 0,
                s.lastOvEndS or 0) then
            s.dodging = true
            s.blocked = false
            s.blockedNotified = false
            s.dodgeBaseCap = s.dodgeSpeedCap
            s.dodgeCapPending = false
            s.dodgeNeed = commitNb or s.sweepBase -- 承諾檔淨距（守護輪同契約）
            -- 玩家可見的減速要有理由：繞行開始提示一次（持續繞行時 sig 每輪微變、
            -- replan 反覆進來，靠 dodgeNotified 防轟；clear/blocked 時重臂）
            if not s.dodgeNotified then
                s.dodgeNotified = true
                local playerObj = getSpecificPlayer(playerNum)
                if playerObj then haloGood(playerObj, KEY_DODGE) end
                diagEvent(s, playerNum, "dodge")
            end
            if getDebug() then
                print(string.format("%spn=%d dodge a=%.1f b=%.1f c=%.1f d=%.1f offL=%.2f",
                    LOG, playerNum, a, b, c, d, offL))
            end
            s.planMode = "dodge"
            return
        end
        mode = "blocked"
    end
    if mode == "clear" then
        -- 解除遲滯：堵住要**連續 CLEAR_STREAK_N 輪** clear 才解除——車頭震盪時
        -- 掃描窗跟著投影漂移，hardN 會 10↔0 跳動（實機 st 88,127 遙測），單輪
        -- clear 就解除＝煞停/全速反覆切換。dodging 不會走到這裡（immutable 分支
        -- 在函式開頭 return），舊的 release 守門已被「剖面走完才釋放」取代。
        if s.blocked and s.clearStreak + 1 < CLEAR_STREAK_N then
            s.clearStreak = s.clearStreak + 1
            s.planMode = "clear-hold"
            return
        end
        s.clearStreak = 0
        s.blocked = false
        s.blockedNotified = false
        s.dodgeNotified = false
        if not s.banFromRecovery then
            s.pushBanL, s.pushBanS = nil, 0
        end
        s.cornerLatch = false
        s.blockHitX = nil
        s.planMode = s.currentBlocked and "current-blocked" or "clear"
        return
    end
    s.clearStreak = 0
    -- blocked：清側偏、漸進接近後煞停等待（掃描持續，障礙消失自動恢復；玩家接手
    -- 走讓位）。記障礙群起點弧長當距離錨：>BLOCK_STOP_DIST 時先滑行接近，掃描逼近
    -- 後的縫隙判定比 30 公尺外那輪準（近距離覆蓋完整、量化誤差小）。
    MDADFollower.clearOffset(s.fstate)
    s.dodging = false
    s.dodgeNotified = false
    s.blocked = true
    -- a＝Corridor blocked 時的 sObs0；缺 Corridor 的保守分支沒有 a → 0＝立即煞停
    s.blockS = a or 0
    s.planMode = "blocked"
    if not s.blockedNotified then
        s.blockedNotified = true
        local playerObj = getSpecificPlayer(playerNum)
        if playerObj then haloBad(playerObj, KEY_BLOCKED) end
        diagEvent(s, playerNum, "blocked")
        if getDebug() then
            -- 點雲摘要（冷路徑一次 O(hardN)）：判「無縫」合不合理的第一手資料
            local lMin, lMax = 99, -99
            for i = 1, sen.hardN do
                local hl = sen.hardL[i]
                if hl < lMin then lMin = hl end
                if hl > lMax then lMax = hl end
            end
            print(string.format("%spn=%d blocked sObs=%.1f hardN=%d l range [%.2f, %.2f]",
                LOG, playerNum, a or 0, sen.hardN, lMin, lMax))
        end
    end
end

-- 倒車脫困：regulator 不會倒車（CarController 只向前供油），改用向後衝量直接推
-- （Derpy towing 同法：relPos 全零＝純中心力，map_nav.lua:7847-7850 的工程事實）。
-- 「每幀最多一次 addImpulse」在此同樣成立——unstick 幀不跑 stepFollow，不會疊加。
-- 玩家接手（讓位）與失效閘門都在呼叫端先行，這裡只管推車與收手判定。
local function stepUnstick(s, vehicle, playerNum, now)
    local vx, vy = vehicle:getX(), vehicle:getY()
    local speedKmh = vehicle:getCurrentSpeedKmHour()
    if not finite(speedKmh) then
        vehicle:setRegulator(false)
        s.dynamicsFault, s.invalid, s.stateError = true, true, "speed"
        Drive.stop(playerNum, KEY_UNSUPPORTED)
        return
    end
    if s.commandControlState ~= "RECOVER" then
        Drive.invalidateCommandState(s, speedKmh, "RECOVER")
    end
    local dx, dy = vx - s.unstickX, vy - s.unstickY
    local dist2 = dx * dx + dy * dy
    s.unstickDistance = sqrt(dist2)
    s.reverseForce = 0
    vehicle:setRegulator(false)

    -- Success does not immediately hand reverse velocity back to forward control.
    if s.mode == "settle" then
        if not finite(speedKmh) then
            diagEvent(s, playerNum, "unstick", {
                phase = "timeout", eid = s.episodeId, attempt = s.episodeAttempts,
                x = vx, y = vy, s = s.lastSNow, d = s.unstickDistance,
                duration = now - s.unstickStartedAt, rear = "settle-speed",
            })
            Drive.stop(playerNum, KEY_STUCK)
            return
        end
        local av = speedKmh
        if av < 0 then av = -av end
        if av >= 1 and now >= s.settleUntil then
            diagEvent(s, playerNum, "unstick", {
                phase = "timeout", eid = s.episodeId, attempt = s.episodeAttempts,
                x = vx, y = vy, s = s.lastSNow, d = s.unstickDistance,
                duration = now - s.unstickStartedAt, rear = "settle-timeout",
            })
            sampleRecovery(s, vehicle, playerNum, now, vx, vy, speedKmh)
            Drive.stop(playerNum, KEY_STUCK)
            return
        end
        if av >= 1 then
            commandForceBrake(s, vehicle, now)
            sampleRecovery(s, vehicle, playerNum, now, vx, vy, speedKmh)
            return
        end

        diagEvent(s, playerNum, "unstick", {
            phase = "success", eid = s.episodeId, attempt = s.episodeAttempts,
            x = vx, y = vy, s = s.lastSNow, d = s.unstickDistance,
            duration = now - s.unstickStartedAt, rear = s.rearStatus,
            speed = speedKmh,
        })
        sampleRecovery(s, vehicle, playerNum, now, vx, vy, speedKmh)
        if type(MDADFollower.resetControl) == "function" then
            MDADFollower.resetControl(s.fstate)
        end
        invalidateReturnControl(s)
        MDADFollower.clearOffset(s.fstate)
        releaseDodge(s)
        s.blocked = false
        s.blockedNotified = false
        s.planSig = -1 -- sensor reset 後即使 hardN=0／sig=0 也必重套 episode ban
        s.clearStreak = 0
        s.detourTried = false
        s.progressState = "disarmed"
        if s.sensor and type(MDADSensor) == "table"
                and type(MDADSensor.reset) == "function" then MDADSensor.reset(s.sensor) end
        s.mode = s.profile.ready == true and "follow" or "build"
        return
    end

    if dist2 >= UNSTICK_DIST_SQ then
        s.mode = "settle"
        s.progressState = "settle"
        s.settleUntil = now + SETTLE_MS
        s.currentBlocked = false
        s.currentClearRounds = 0
        s.episodeClearRounds = 0
        diagEvent(s, playerNum, "unstick", {
            phase = "settle", eid = s.episodeId, attempt = s.episodeAttempts,
            x = vx, y = vy, s = s.lastSNow, d = s.unstickDistance,
            duration = now - s.unstickStartedAt, rear = s.rearStatus,
        })
        commandForceBrake(s, vehicle, now)
        sampleRecovery(s, vehicle, playerNum, now, vx, vy, speedKmh)
        return
    end

    if now >= s.unstickUntil then
        diagEvent(s, playerNum, "unstick", {
            phase = "timeout", eid = s.episodeId, attempt = s.episodeAttempts,
            x = vx, y = vy, s = s.lastSNow, d = s.unstickDistance,
            duration = now - s.unstickStartedAt, rear = s.rearStatus,
        })
        sampleRecovery(s, vehicle, playerNum, now, vx, vy, speedKmh)
        Drive.stop(playerNum, KEY_STUCK)
        return
    end

    local mult = getGameTime():getMultiplier()
    if mult < MULT_MIN then mult = MULT_MIN end
    if mult > MULT_MAX then mult = MULT_MAX end
    local mass = s.runtimeMass
    if not finite(mass) or mass < 1 then mass = MASS_FALLBACK end
    local fwd = BaseVehicle.allocVector3f()
    vehicle:getForwardVector(fwd)
    local fx, fy = fwd:x(), fwd:z()
    if not finite(fx) or not finite(fy) then
        BaseVehicle.releaseVector3f(fwd)
        s.dynamicsFault, s.invalid, s.stateError = true, true, "forward"
        Drive.stop(playerNum, KEY_UNSUPPORTED)
        return
    end
    local flen2 = fx * fx + fy * fy
    if flen2 <= 1e-6 then
        BaseVehicle.releaseVector3f(fwd)
        s.dynamicsFault, s.invalid, s.stateError = true, true, "forward-zero"
        Drive.stop(playerNum, KEY_UNSUPPORTED)
        return
    end
    local inv = 1 / sqrt(flen2)
    fx, fy = fx * inv, fy * inv
    local heading = MDADFollower.headingFromForward(fx, fy)

    -- Re-probe before the impulse on each 100ms boundary. Any non-clear result
    -- produces zero reverse impulse and a rear-blocked event for the active attempt.
    if now >= s.nextRearProbeMs then
        s.nextRearProbeMs = now + REAR_PROBE_MS
        local status, hitX, hitY, kind, detail = "unloaded", vx, vy, "geometry",
            "invalid forward vector"
        if flen2 > 1e-6 then
            status, hitX, hitY, kind, detail = rearProbe(s, vehicle, fwd, fx, fy, vx, vy)
        end
        s.rearStatus = status
        if status ~= "clear" then
            BaseVehicle.releaseVector3f(fwd)
            noteProbeError(s, "rear-unstick", status, kind, detail)
            diagEvent(s, playerNum, "unstick", {
                phase = "rear-blocked", eid = s.episodeId, attempt = s.episodeAttempts,
                x = hitX, y = hitY, s = s.lastSNow, d = s.unstickDistance,
                duration = now - s.unstickStartedAt,
                rear = status, kind = kind, detail = detail,
            })
            sampleRecovery(s, vehicle, playerNum, now, vx, vy, speedKmh, fx, fy, heading)
            Drive.stop(playerNum, KEY_STUCK)
            return
        end
    end

    if flen2 > 1e-6 then
        local force = UNSTICK_PUSH * MASS_BASE * mass * IMPULSE_SCALE * (mult / MULT_NORM)
        local impulse = BaseVehicle.allocVector3f()
        impulse:set(-force * fx, 0, -force * fy)
        fwd:set(0, 0, 0)
        vehicle:addImpulse(impulse, fwd)
        BaseVehicle.releaseVector3f(impulse)
        s.reverseForce = force
    end
    BaseVehicle.releaseVector3f(fwd)
    sampleRecovery(s, vehicle, playerNum, now, vx, vy, speedKmh, fx, fy, heading)
    if getDebug() and now >= s.nextDebugMs then
        s.nextDebugMs = now + TUNE.DEBUG_MS
        print(string.format("%spn=%d mode=unstick speed=%.1f attempt=%d rear=%s",
            LOG, playerNum, speedKmh, s.episodeAttempts, tostring(s.rearStatus)))
    end
end

local function stepFollow(s, vehicle, playerNum, now)
    local speedKmh = vehicle:getCurrentSpeedKmHour() -- 可負（倒車）＝BaseVehicle.java:4268
    if not finite(speedKmh) then
        vehicle:setRegulator(false)
        s.dynamicsFault, s.invalid, s.stateError = true, true, "speed"
        Drive.stop(playerNum, KEY_UNSUPPORTED)
        return
    end
    if not s.cmdInitialized then
        s.cmdV = speedKmh / 3.6
        if s.cmdV < 0 then s.cmdV = -s.cmdV end
        if not finite(s.cmdV) then s.cmdV = 0 end
        s.cmdA, s.cmdInitialized = 0, true
    end
    s.lastSpeedKmh = speedKmh
    s.jerkBypassReason = nil
    local vx, vy = vehicle:getX(), vehicle:getY()
    local mult = getGameTime():getMultiplier()
    if mult < MULT_MIN then mult = MULT_MIN end
    if mult > MULT_MAX then mult = MULT_MAX end
    -- 每幀先歸零，applySteering 真的走耦力時才寫 true（純觀測；一個 boolean 寫入）
    s.lastCoupled = false
    s.lastCapReason = nil
    s.lastHeadingCap = nil
    s.lastDcap = nil
    s.lastSensorCap, s.lastSensorReason = nil, nil
    s.diagExpL = nil
    s.diagLatDev = nil
    s.forceBrakeThis = false
    s.lastAssistForce = 0

    -- 池向量：一顆當 forward／relPos 共用，一顆在 applySteering 內當 impulse。
    -- 這段中間沒有 early return，release 一定會執行。
    local fwd = BaseVehicle.allocVector3f()
    vehicle:getForwardVector(fwd) -- basis 第 2 欄＝BaseVehicle.java:4242-4244
    -- Bullet 的 y 是上方向：世界 (X,Y) 對應 (x,z)（CarController.java:406,416 同讀法）
    local fx, fy = fwd:x(), fwd:z()
    local flen2 = fx * fx + fy * fy
    local reached = false
    local postAction = nil
    if not finite(fx) or not finite(fy) then
        s.dynamicsFault, s.invalid, s.stateError = true, true, "forward"
        postAction, flen2 = "dynamics-fault", 0
    elseif flen2 <= 1e-6 then
        vehicle:setRegulator(false)
        s.dynamicsFault, s.invalid, s.stateError = true, true, "forward-zero"
        postAction, flen2 = "dynamics-fault", 0
    end
    if flen2 > 1e-6 then
        local inv = 1 / sqrt(flen2)
        fx, fy = fx * inv, fy * inv
        -- control 回 steer, targetSpeed, remaining, reached, headingError, lateralSq
        local heading = MDADFollower.headingFromForward(fx, fy)
        updateTraction(s, now, speedKmh, heading, s.lastHeadingError, s.lastLatDev)
        if s.dynamicsFault then postAction = "dynamics-fault" end
        local steer, targetSpeed, remaining, done, headingError, lateralSq, latSigned = MDADFollower.control(
            s.profile, s.fstate, vx, vy,
            heading, speedKmh, mult * SECONDS_PER_MULT)
        local curveKappa, curveCap =
            s.fstate.curveKappa, s.fstate.curveCapKmh
        local curveHardActive = s.fstate.curveHardActive == true
        local curveValid = s.fstate.curveValid == true
            and finite(curveKappa) and curveKappa >= 0
            and finite(curveCap) and curveCap >= 0
            and (not curveHardActive or curveKappa > 0)
        if not finite(targetSpeed) or targetSpeed < 0 or not curveValid then
            targetSpeed, s.profileEnvelope = 0, 0
            s.curveValid, s.curveHardActive = false, false
            s.curveKappa, s.curveCap = 0, 0
            s.dynamicsFault, s.invalid, s.stateError =
                true, true, curveValid and "profile-target" or "curve-state"
            postAction = "dynamics-fault"
        else
            s.profileEnvelope = targetSpeed
            s.curveValid, s.curveHardActive =
                true, curveHardActive
            s.curveKappa, s.curveCap = curveKappa, curveCap
        end
        reached = done == true
        -- 目前沿線弧長：M4 感知與脫困額度重臂共用（sensor 缺席時脫困仍要用，
        -- 所以重臂判定放在 sensor 塊之外）
        s.lastSNow = s.profile.length - (remaining or 0)
        local segI = s.fstate.idx
        if not finite(segI) then segI = 1 end
        segI = segI - segI % 1
        if segI < 1 then segI = 1 elseif segI >= s.profile.n then segI = s.profile.n - 1 end
        s.currentSurfaceId = s.profile.segSurface[segI] or MDADFollower.SURFACE_UNKNOWN
        s.currentSegWidth = s.profile.segWidth[segI] or 0
        -- RETURN 期間期望線＝已承諾的 target lane；其餘走既有側偏剖面期望線。
        local expL = expectedLaneOf(s)
        if s.returnActive then expL = s.returnLaneTarget end
        local latDev = latSigned - expL
        s.diagExpL, s.diagLatDev = expL, latDev
        s.lastLatDev, s.lastHeadingError = latDev, headingError or 0
        local available = 2
        if finite(s.currentSegWidth) and s.currentSegWidth > 0 then
            available = s.currentSegWidth * 0.5 - s.vehicleProfile.halfW - 0.4
        end
        if available < 1 then available = 1 elseif available > 3 then available = 3 end
        s.returnSoftLimit = available
        local absDev = latDev
        if absDev < 0 then absDev = -absDev end
        if not s.returnActive and absDev > available and returnAvailable(s) then
            s.returnActive, s.returnUnsafe, s.returnHold = true, true, true
            s.returnStartS, s.returnEndS = s.lastSNow, s.lastSNow
            s.returnLaneStart, s.returnLaneTarget = latSigned, laneBiasOf(s)
            s.returnReason = s.surfaceMismatch and "lateral+mismatch" or "lateral"
            s.returnCapacityFault = false
            s.returnClearRounds = 0
            MDADFollower.clearOffset(s.fstate)
            MDADFollower.setLaneBias(s.fstate, latSigned)
            releaseDodge(s)
            s.planMode = "return-pending"
            diagEvent(s, playerNum, "return", {
                phase = "enter", why = s.returnReason,
                s = s.lastSNow, l = latSigned, d = available,
            })
        end

        -- ---- M4 感知（sensor 缺席＝退回 M3 純跟線）----
        -- 排在 applySpeed 之前：速度檔位要 min 進本幀的 targetSpeed 才有效。
        if s.sensor then
            -- getCell 用例：ISDestroyCursor.lua:278（getCell():getGridSquare 同型）
            -- 事件驅動：掃描輪剛完成「且」障礙簽章變了才重規劃；step 回 false
            -- （掃描進行中／節流中）時 and 短路，sig 連讀都不讀。
            -- 例外：clear 解除遲滯進行中（clearStreak > 0）——布局不變（sig 相同）
            -- 也要進 replan 做「連續第二輪 clear」的確認，否則確認永遠不會來、
            -- blocked/dodge 卡死不解除。遲滯結束（解除或重新出現障礙）就回到
            -- 純事件驅動。
            local cell = getCell()
            if MDADSensor.step(s.sensor, s.profile, s.lastSNow, vehicle, now, cell) then
                -- 路面對中：每輪完成都校正（與 replan 無關的常態動作）。roadC＝
                -- 路面帶中心相對 nav 線的偏移，EMA 平滑（防單輪雜訊跳行駛線）；
                -- 無樣本（路口外／無路面）衰減回 0——nav 線是唯一剩下的參考。
                -- 合成行駛線走 setLaneBias 單一事實源：follower 前視、Corridor
                -- baseL/prefer、掃掠淨距全部自動吃到。
                local rc = s.sensor.roadC
                if rc ~= nil then
                    if rc > TUNE.ROAD_CLAMP then rc = TUNE.ROAD_CLAMP
                    elseif rc < -TUNE.ROAD_CLAMP then rc = -TUNE.ROAD_CLAMP end
                    s.roadBias = s.roadBias + (rc - s.roadBias) * TUNE.ROAD_EMA
                else
                    s.roadBias = s.roadBias * TUNE.ROAD_DECAY
                end
                local nb = s.sandBias + s.roadBias
                if nb > TUNE.BIAS_MAX then nb = TUNE.BIAS_MAX
                elseif nb < -TUNE.BIAS_MAX then nb = -TUNE.BIAS_MAX end
                -- 枚舉的邊界判定跟著抖。承諾釋放後恢復跟隨。
                if s.dodging or s.returnActive then nb = laneBiasOf(s) end
                if type(MDADFollower.setLaneBias) == "function" then
                    MDADFollower.setLaneBias(s.fstate, nb)
                end
                s.verifyLineN = 0
                s.laneCurveEnvelope, s.laneCurveStamp,
                    s.laneCurveS0, s.laneCurveEnd,
                    s.envelopeBuildLat, s.envelopeBuildCoast,
                    s.laneEnvelopeScale = 0, -1, 0, 0, -1, -1, 1
                s.sensor.scanBias = nb -- 掃描帶跟隨行駛線（下一輪 beginRound 鎖定）
                -- Current-body OBB is a safety OR-gate in front of the existing planner.
                -- It consumes this completed immutable snapshot even when sig is unchanged.
                footprintSnapshot(s, vehicle, playerNum, fwd, heading, vx, vy, latSigned)
                updateReturnSnapshot(s, vehicle, playerNum, latSigned)
                if s.sensor.sig ~= s.planSig or s.clearStreak > 0 or s.dodging then
                    s.planSig = s.sensor.sig
                    replan(s, vehicle, playerNum)
                    if s.currentBlocked then s.planMode = "current-blocked" end
                end
                local horizonEnd = visibleEndS(s.sensor, s.lastSNow)
                if horizonEnd > s.profile.length then horizonEnd = s.profile.length end
                s.horizonMinBrake, s.horizonMinLat, s.horizonMinCoast =
                    MDADFollower.minDynamics(s.profile, s.lastSNow, horizonEnd, segI)
                if finite(s.safeBrake) and s.safeBrake >= 0
                        and s.safeBrake < s.horizonMinBrake then
                    s.horizonMinBrake = s.safeBrake
                end
                if finite(s.safeLat) and s.safeLat >= 0
                        and s.safeLat < s.horizonMinLat then
                    s.horizonMinLat = s.safeLat
                end
                if finite(s.safeCoast) and s.safeCoast >= 0
                        and s.safeCoast < s.horizonMinCoast then
                    s.horizonMinCoast = s.safeCoast
                end
                s.horizonStamp = s.sensor.stamp
                buildSnapshotProof(s, segI, horizonEnd)
                -- 一般玩家軌跡每輪更新常駐點列；debugOn 只控制紅／綠／橙 markers。
                -- LineDrawer 每 tick 畫連續線，幾何仍只在 250ms 輪完成時重算。
                if type(MDADOverlay) == "table" then
                    MDADOverlay.update(playerNum, s, vehicle, cell, s.overlayOn)
                end
            end
            -- 速度檔位：全部是疊在剖面上的 min，cap<0＝本幀沒有任何檔位介入
            local cap = -1
            local capReason = nil
            if not s.sensor.ready then
                -- 首輪掃描還沒完成（剛啟動／換路線／脫困後重掃）＝「不知道前面有
                -- 什麼」，與未載入同級保守：不加這條會在盲區全速衝 ~150ms，
                -- 剛脫困退開的 3 公尺一半就被吃回去（M4 review blocker）
                cap = TUNE.UNLOADED_CAP
                capReason = "sensor"
            end
            if s.dodging then
                -- Motion completion releases the immutable line; layout signatures do not.
                local fsD = s.fstate.offD
                if type(fsD) ~= "number" or s.lastSNow >= fsD then
                    MDADFollower.clearOffset(s.fstate)
                    releaseDodge(s)
                    if getDebug() then
                        print(LOG .. "pn=" .. playerNum .. " dodge released (profile done)")
                    end
                else
                    local dcap = s.dodgeSpeedCap
                    if not finite(dcap) or dcap < 0 then dcap = 0 end
                    s.lastDcap = dcap
                    local slowZone
                    if not finite(s.safeCoast) or s.safeCoast <= 0 then
                        slowZone = s.profile.length
                    else
                        slowZone = MDADDynamics.stoppingDistance(
                            speedKmh / 3.6, 0.5, s.safeCoast, s.vehicleProfile.halfL)
                    end
                    local fsA = s.fstate.offA
                    if not finite(fsA) or s.lastSNow >= fsA - slowZone then
                        if cap < 0 or dcap < cap then
                            cap = dcap
                            capReason = "dodge"
                        end
                    end
                end
            end
            -- 殭屍／屍體減速：三態政策×玩家偏好已在 refreshPolicies 合成快取，
            -- 每幀只讀 boolean（250ms 刷新；切檔／切偏好即時重算）
            local zn = s.sensor.zombieN
            if zn and zn > 0 and s.zombieSlow then
                local zcap = TUNE.ZOMBIE_CAP_1
                if zn >= 8 then zcap = TUNE.ZOMBIE_CAP_8
                elseif zn >= 4 then zcap = TUNE.ZOMBIE_CAP_4 end
                if cap < 0 or zcap < cap then
                    cap = zcap
                    capReason = "zombie"
                end
            end
            local cn = s.sensor.corpseN
            if cn and cn > 0 and s.corpseSlow
                    and (cap < 0 or TUNE.CORPSE_CAP < cap) then
                cap = TUNE.CORPSE_CAP
                capReason = "corpse"
            end
            -- 跟車分級（不能只 cap 15 一路跟到撞）：MP 半更新狀態的靜止車會被
            -- isStopped 誤判成「行進中」不進硬障礙（2026-08-28 實機：黑車不在
            -- 快照硬點裡、17 km/h 直接追尾）——按最近前車的弧長距離分級：
            -- <10m 目標 0（煞停等待）、<20m 爬行 8、更遠照 MOVING_VEH_CAP。
            s.followHold = false
            if s.sensor.movingVeh then
                local mcap = TUNE.MOVING_VEH_CAP
                local va = s.sensor.vehAheadS
                if va ~= nil then
                    local gap = va - s.lastSNow
                    if gap < 10 then
                        mcap = 0
                        s.followHold = true -- 合法停等（卡死豁免＋獨立超時）
                    elseif gap < 20 then mcap = 8 end
                end
                if cap < 0 or mcap < cap then
                    cap = mcap
                    capReason = "moving"
                end
            end
            -- 軟障礙（可推家具／HitByCar 雜物）：輾得過但要先減速——不減速輾過的
            -- 體感就是「撞到東西」（2026-08-28 實機路口擦撞回報的嫌疑之一）
            local sn = s.sensor.softN
            if sn and sn > 0 and (cap < 0 or TUNE.SOFT_CAP < cap) then
                cap = TUNE.SOFT_CAP
                capReason = "soft"
            end
            if cap >= 0 then
                s.lastSensorCap, s.lastSensorReason = cap, capReason
            end
            if cap >= 0 and targetSpeed > cap then
                targetSpeed = cap
                s.lastCapReason = capReason
            end
        end

        -- 速度檔位 cap：刻意放在 sensor 塊**之外**——感知模組缺席（檔案樹壞、
        -- 退回 M3 純跟線）時檔位照樣生效（codex M5.5 對抗審 BLOCKING）。
        -- 只往下壓：瘋狂檔（gearCap＝載具極速）高於剖面上限時由剖面壓住。
        if s.gearCap > 0 and targetSpeed > s.gearCap then
            targetSpeed = s.gearCap
            s.lastCapReason = "gear"
        end
        -- 感知閉環上限（理由見 PERCEPTION_CAP_KMH）：標準組態上限 85；
        -- 高速組態同時切到 110m 掃描帶與 120 上限。
        local pcap = s.perceptionCap or TUNE.PERCEPTION_CAP_KMH
        if targetSpeed > pcap then
            targetSpeed = pcap
            s.lastCapReason = "perception"
        end
        -- 感知空窗爬行（2026-08-29 實測）：改導航目標＝route cutover 會作廢
        -- 感知快照（sensor 認 profile identity 重置、stamp 歸零）＋清繞行旗標
        -- ——新路線首輪掃描完成前 plan 看到的「hardN=0」不是淨空而是**還不
        -- 知道**。實測改目標後調頭，車頭正對 4m 外剛才還有紅圈的車加速，
        -- 首輪掃完 blocked 才收到、物理已煞不住。首輪完成前壓爬行（250ms
        -- 節流＋~12 幀，體感 0.3-0.6 秒），事件驅動、不用固定等待計時；
        -- session 起步同理：先看再走。
        if s.sensor and s.sensor.stamp == 0 and targetSpeed > TUNE.SCAN_WARM_CAP then
            targetSpeed = TUNE.SCAN_WARM_CAP
            s.lastCapReason = "warm"
        end
        -- RETURN speed is a cap on the exact committed line. If the line could
        -- not be swept or loaded, stay road-parallel at <=8 and retry next snapshot.
        if s.returnHold then
            targetSpeed = 0
            s.lastCapReason = s.returnCapacityFault and "return-capacity" or "return-hold"
        elseif s.returnActive then
            local returnCap = s.returnUnsafe and TUNE.RETURN_UNSAFE_CAP or TUNE.RETURN_CAP
            if targetSpeed > returnCap then targetSpeed = returnCap end
            s.lastCapReason = s.returnUnsafe and "return-unsafe" or "return"
        end
        -- Strict cruise aggregation: one malformed cap collapses to a named invalid stop.
        local vehicleMax = s.vehicleProfile.maxSpeed
        local fullValid = finite(s.profileEnvelope) and s.profileEnvelope >= 0
            and finite(s.gearCap) and s.gearCap >= 0
            and finite(pcap) and pcap >= 0 and finite(vehicleMax) and vehicleMax >= 0
        local laneEnvelopeValid = s.sensor
            and s.laneCurveStamp == s.sensor.stamp
        local envelopeScale, scaleCandidate = s.laneEnvelopeScale, 1
        if laneEnvelopeValid then
            local buildLat, buildCoast =
                s.envelopeBuildLat, s.envelopeBuildCoast
            if not (finite(envelopeScale) and envelopeScale >= 0 and envelopeScale <= 1
                    and finite(s.safeLat) and s.safeLat >= 0
                    and finite(s.safeCoast) and s.safeCoast >= 0
                    and finite(buildLat) and buildLat >= 0
                    and finite(buildCoast) and buildCoast >= 0) then
                fullValid = false
            else
                if buildLat > 0 and s.safeLat < buildLat then
                    scaleCandidate = sqrt(s.safeLat / buildLat)
                end
                if buildCoast > 0 and s.safeCoast < buildCoast then
                    local coastScale = sqrt(s.safeCoast / buildCoast)
                    if coastScale < scaleCandidate then scaleCandidate = coastScale end
                end
                if scaleCandidate < envelopeScale then
                    envelopeScale = scaleCandidate
                    s.laneEnvelopeScale = scaleCandidate
                end
            end
        end
        if laneEnvelopeValid then
            local currentS, lineS0, lineEnd =
                s.lastSNow, s.laneCurveS0, s.laneCurveEnd
            if not (finite(currentS) and finite(lineS0) and finite(lineEnd))
                    or currentS > lineEnd + 1e-6 or lineEnd <= lineS0 then
                laneEnvelopeValid, fullValid = false, false
                s.invalid, s.stateError, s.dynamicsFault =
                    true, "lane-envelope", true
            else
                local offset = (currentS - lineS0) / MDADFollower.OV_STEP
                if offset < 0 then offset = 0 end
                local whole = offset - offset % 1
                local index = whole + 1
                if index >= s.verifyLineN then index = s.verifyLineN - 1 end
                if index < 1 then index = 1 end
                local currentCap = s.verifyEnvelope[index]
                local nextCap = s.verifyEnvelope[index + 1]
                if not finite(currentCap) or currentCap < 0
                        or not finite(nextCap) or nextCap < 0 then
                    laneEnvelopeValid, fullValid = false, false
                    s.invalid, s.stateError, s.dynamicsFault =
                        true, "lane-envelope", true
                else
                    local baseCap =
                        currentCap < nextCap and currentCap or nextCap
                    s.laneCurveEnvelope = baseCap * envelopeScale
                end
            end
        end
        local fullTarget = 0
        if fullValid then
            fullTarget = s.profileEnvelope
            if s.gearCap < fullTarget then fullTarget = s.gearCap end
            if pcap < fullTarget then fullTarget = pcap end
            if vehicleMax < fullTarget then fullTarget = vehicleMax end
            if laneEnvelopeValid then
                if not finite(s.laneCurveEnvelope) or s.laneCurveEnvelope < 0 then
                    fullValid = false
                else
                    if s.laneCurveEnvelope < fullTarget then
                        fullTarget = s.laneCurveEnvelope
                    end
                    if s.laneCurveEnvelope < targetSpeed then
                        targetSpeed = s.laneCurveEnvelope
                        s.lastCapReason = "curve-coast"
                    end
                end
            end
        else
            s.invalid, s.dynamicsFault = true, true
            if s.stateError == nil then s.stateError = "full-target" end
            targetSpeed = 0
        end
        if not fullValid then
            fullTarget, targetSpeed = 0, 0
            s.invalid, s.dynamicsFault = true, true
            if s.stateError == nil then s.stateError = "full-target" end
        end

        local sensorReady, fresh, brakeLoaded = false, false, false
        local corridorClear, obbClear = false, false
        local tau, stopEnd = 0.5, s.lastSNow
        local visibilityCap = s.sensor and 0 or 15
        if s.sensor and s.sensor.ready and finite(s.sensor.stamp) then
            sensorReady = true
            local age = now - s.sensor.stamp
            fresh = age >= 0 and age <= MDADDynamics.SNAPSHOT_FRESH_MS
            tau = age / 1000 + 0.25
            if tau < 0.5 then tau = 0.5 end
            local visibleEnd = visibleEndS(s.sensor, s.lastSNow)
            local minBrakeVisible = s.horizonStamp == s.sensor.stamp
                and s.horizonMinBrake or 0
            if finite(s.safeBrake) and s.safeBrake >= 0 then
                if s.safeBrake < minBrakeVisible then
                    minBrakeVisible = s.safeBrake
                    s.horizonMinBrake = s.safeBrake
                end
            else
                minBrakeVisible = 0
                s.invalid, s.stateError, s.dynamicsFault =
                    true, "brake-limit", true
            end
            if finite(s.safeLat) and s.safeLat >= 0
                    and s.safeLat < s.horizonMinLat then
                s.horizonMinLat = s.safeLat
            end
            if finite(s.safeCoast) and s.safeCoast >= 0
                    and s.safeCoast < s.horizonMinCoast then
                s.horizonMinCoast = s.safeCoast
            end
            visibilityCap = MDADDynamics.visibilityCapKmh(
                visibleEnd - s.lastSNow, tau, minBrakeVisible, s.vehicleProfile.halfL)
            stopEnd = s.lastSNow + MDADDynamics.stoppingDistance(
                fullTarget / 3.6, tau, minBrakeVisible, s.vehicleProfile.halfL)
            if stopEnd > s.profile.length then stopEnd = s.profile.length end
            brakeLoaded = finite(minBrakeVisible) and minBrakeVisible > 0
                and visibleEnd >= stopEnd
            -- hardN spans the planner's full +/-7m search band, not the driven lane.
            -- verifySweep owns hard-obstacle safety; the sensor cap stack above owns
            -- moving vehicles, zombies, corpses and soft objects.
            corridorClear = not s.blocked and not s.dodging
            obbClear = (not s.adaptive or s.verifySweep) and not s.currentBlocked
        end
        if not finite(visibilityCap) or visibilityCap < 0 then
            visibilityCap = 0
            s.invalid, s.stateError, s.dynamicsFault = true, "visibility", true
        end
        s.visibilityCap = visibilityCap
        if targetSpeed > visibilityCap then
            targetSpeed, s.lastCapReason = visibilityCap, "visibility"
        end

        local latTol = 0.5
        if finite(s.currentSegWidth) and s.currentSegWidth > 0 then
            latTol = 0.25 * (s.currentSegWidth - 2 * s.vehicleProfile.halfW)
            if latTol < 0.35 then latTol = 0.35 elseif latTol > 0.75 then latTol = 0.75 end
        end
        local absHeading = headingError or 0
        if absHeading < 0 then absHeading = -absHeading end
        local alignedNow = absDev <= latTol and absHeading <= MDADDynamics.ALIGN_HEADING_RAD
        if alignedNow then
            if s.alignSince == 0 then s.alignSince = now end
        else
            s.alignSince = 0
        end
        local aligned = alignedNow and now - s.alignSince >= MDADDynamics.ALIGN_HOLD_MS
        local progressHealthy = s.progressState == "watch"
            and s.progressSince > 0 and now - s.progressSince <= 1000
        local pathVerified = s.curveVerifiedUntilS >= stopEnd
        -- Reclassify an insufficient adaptive prefix as OBB uncertainty so the
        -- existing ungated policy applies the strict 15km/h cap, not the looser arc cap.
        if s.adaptive and not pathVerified then obbClear = false end
        s.fullGate, s.gateReason = MDADDynamics.fullSpeedGate(
            sensorReady, fresh, brakeLoaded, corridorClear, obbClear,
            fullValid and controlStateOf(s) == "TRACK",
            not s.returnActive and not s.returnHold, aligned, progressHealthy,
            s.adaptive and pathVerified,
            s.verifyBand and pathVerified, s.verifySweep and pathVerified)
        if s.fullGate then
            -- Keep an already stricter sensor-policy cap; full-path proof must not
            -- overwrite moving/zombie/corpse/soft limits selected above.
            if targetSpeed >= fullTarget then
                targetSpeed, s.lastCapReason = fullTarget, nil
            end
        else
            local alignCap = MDADDynamics.alignmentCapKmh(
                fullTarget, headingError, latDev, latTol, aligned)
            local ungated, gateReason = MDADDynamics.ungatedCapKmh(
                fullTarget, s.gateReason, alignCap)
            if ungated < targetSpeed then targetSpeed = ungated end
            s.lastCapReason, s.gateReason = gateReason, gateReason
            if gateReason == "align" then s.lastHeadingCap = ungated end
            if gateReason == "dynamics-invalid" then
                s.invalid, s.stateError, s.dynamicsFault = true, "ungated", true
            end
        end

        -- Final target is known before the supervisor. Planned blocked/followHold at target
        -- zero are legal waits; current-body contact remains a recovery demand.
        -- RETURN outranks planned blocked; current-body contact still outranks RETURN.
        local blockedStop = s.blocked and not reached and not s.returnActive
            and s.lastSNow >= s.blockS
                - (s.cornerLatch and TUNE.CORNER_STOP_DIST or TUNE.BLOCK_STOP_DIST)
        if blockedStop then targetSpeed = 0 end
        if s.currentBlocked then
            targetSpeed = 0
            s.lastCapReason = "contact"
            s.planMode = "current-blocked"
        end

        local avProgress = speedKmh
        if avProgress < 0 then avProgress = -avProgress end
        if s.returnCapacityFault and s.returnHold and avProgress < 1 then
            postAction = "return-fault"
        end
        local legalWait = not s.currentBlocked and not s.banFromRecovery
            and targetSpeed <= 0 and (s.blocked or s.followHold or s.returnHold)
        if legalWait and avProgress < 1 then
            if s.waitSince == 0 then
                s.waitSince = now
            elseif now - s.waitSince >= TUNE.WAIT_TIMEOUT_MS then
                postAction = "wait"
            end
        else
            s.waitSince = 0
        end

        local skipProgressCompare = false
        if s.verifyArmPending then
            s.verifyArmPending = false
            s.progressState = "verify"
            s.progressUntil = s.verifyArmUntil
            s.verifyArmUntil = 0
            s.progressSince = now
            s.progressX, s.progressY = vx, vy
            s.progressS, s.progressH = s.lastSNow, heading
            skipProgressCompare = true
        end

        -- 150ms neutral pulse: regulator off, no brake, no steering impulse. The next
        -- physics update selects N; after the pulse VERIFY grants two seconds to move.
        if s.mode == "gear-reset" then
            if now < s.progressUntil then
                targetSpeed = 0
                s.lastCapReason = "gear-reset"
            else
                s.mode = "follow"
                s.progressState = "verify"
                s.progressUntil = now + TUNE.VERIFY_MS
                s.progressSince = now
                s.progressX, s.progressY = vx, vy
                s.progressS, s.progressH = s.lastSNow, heading
            end
        end

        if s.mode == "recover" then
            targetSpeed = 0
            s.lastCapReason = "recover"
            if avProgress < 1 then postAction = "recover" end
        elseif s.mode ~= "gear-reset" then
            local demand = not reached and not legalWait
                and (s.profileEnvelope >= 8 or s.currentBlocked
                    or (s.blocked and s.banFromRecovery))
            if not demand then
                s.progressState = "disarmed"
                s.progressSince = 0
            elseif skipProgressCompare then
                -- Same coordinate frame as the next comparison; arming itself is not progress.
            elseif s.progressState == "disarmed" then
                s.progressState = "watch"
                s.progressSince = now
                s.progressX, s.progressY = vx, vy
                s.progressS, s.progressH = s.lastSNow, heading
            elseif s.progressState == "watch" or s.progressState == "verify" then
                local pdx, pdy = vx - s.progressX, vy - s.progressY
                local wd2 = pdx * pdx + pdy * pdy
                local ds = s.lastSNow - s.progressS
                local dyaw = heading - s.progressH
                if dyaw > 3.14159265358979 then dyaw = dyaw - 6.28318530717959
                elseif dyaw < -3.14159265358979 then dyaw = dyaw + 6.28318530717959 end
                local ayaw = dyaw
                if ayaw < 0 then ayaw = -ayaw end
                if wd2 >= PROGRESS_M_SQ or ds >= PROGRESS_S or ayaw >= PROGRESS_YAW then
                    if s.progressState == "verify" then
                        diagEvent(s, playerNum, "progress", {
                            phase = "verified", eid = s.episodeId,
                            dt = now - s.progressSince, wd = sqrt(wd2),
                            ds = ds, dyaw = ayaw,
                        })
                    end
                    s.progressState = "watch"
                    s.progressSince = now
                    s.progressX, s.progressY = vx, vy
                    s.progressS, s.progressH = s.lastSNow, heading
                elseif s.progressState == "verify" and now >= s.progressUntil then
                    s.progressState = "recover"
                    s.mode = "recover"
                    targetSpeed = 0
                    s.lastCapReason = "recover"
                    diagEvent(s, playerNum, "progress", {
                        phase = "recover", eid = s.episodeId,
                        dt = now - s.progressSince, wd = sqrt(wd2),
                        ds = ds, dyaw = ayaw, hit = s.rearStatus,
                    })
                    if avProgress < 1 then postAction = "recover" end
                elseif s.progressState == "watch"
                        and now - s.progressSince >= PROGRESS_MS then
                    beginEpisode(s, s.currentBlocked and "contact" or "progress", vx, vy)
                    s.progressState = "suspect"
                    local nearStatus, nearX, nearY, nearKind, nearDetail =
                        "unloaded", vx, vy, "geometry", "body center or near probe unavailable"
                    local bx, by = bodyCenter(s, vehicle, fwd)
                    if bx ~= nil and type(MDADSensor) == "table"
                            and type(MDADSensor.probeNear) == "function" then
                        nearStatus, nearX, nearY, nearKind, nearDetail = MDADSensor.probeNear(
                            s.sensor, vehicle, getCell(), bx, by, fx, fy, -fy, fx,
                            s.vehicleProfile.halfW, s.vehicleProfile.halfL)
                    end
                    if nearStatus ~= "clear" then
                        noteProbeError(s, "near", nearStatus, nearKind, nearDetail)
                    end
                    local okOff, physicalOffroad = pcall(jget, vehicle, "isDoingOffroad")
                    local okGear, transmission = pcall(jget, vehicle, "getTransmissionNumber")
                    diagEvent(s, playerNum, "progress", {
                        phase = "suspect", eid = s.episodeId,
                        dt = now - s.progressSince, wd = sqrt(wd2),
                        ds = ds, dyaw = ayaw, hit = nearStatus,
                        gear = okGear and transmission or nil, detail = nearDetail,
                    })
                    if (s.currentBlocked or nearStatus ~= "clear") and s.pushBanL == nil then
                        banRecoveryLane(s, latSigned, s.lastSNow + 4)
                        if finite(nearX) and finite(nearY) and s.episodeHitX == nil then
                            s.episodeHitX, s.episodeHitY = nearX, nearY
                            s.episodeHitS, s.episodeHitL = s.lastSNow, latSigned or 0
                        end
                    end
                    if nearStatus == "clear" and not s.currentBlocked
                            and okOff and physicalOffroad == false
                            and okGear and finite(transmission) and transmission >= 2
                            and not s.episodeGearResetTried then
                        s.episodeGearResetTried = true
                        s.mode = "gear-reset"
                        s.progressState = "gear-reset"
                        s.progressUntil = now + TUNE.GEAR_RESET_MS
                        targetSpeed = 0
                        s.lastCapReason = "gear-reset"
                        diagEvent(s, playerNum, "progress", {
                            phase = "gear-reset", eid = s.episodeId, gear = transmission,
                        })
                    else
                        s.mode = "recover"
                        s.progressState = "recover"
                        targetSpeed = 0
                        s.lastCapReason = "recover"
                        diagEvent(s, playerNum, "progress", {
                            phase = "recover", eid = s.episodeId,
                            hit = nearStatus, x = nearX, y = nearY, kind = nearKind,
                            detail = nearDetail,
                        })
                        if avProgress < 1 then postAction = "recover" end
                    end
                end
            end
        end

        if s.blocked and not reached and not s.returnActive and not blockedStop
                and targetSpeed > TUNE.BLOCK_APPROACH_KMH then
            targetSpeed, s.lastCapReason = TUNE.BLOCK_APPROACH_KMH, "blocked"
        end
        if s.dynamicsFault then postAction = "dynamics-fault" end
        local commandState = controlStateOf(s)
        if commandState ~= s.commandControlState then
            Drive.invalidateCommandState(s, speedKmh, commandState)
        end
        local hardCapV, hardClampReason = s.visibilityCap / 3.6, "visibility"
        if not finite(hardCapV) or hardCapV < 0 then
            hardCapV, hardClampReason = 0, "dynamics-invalid"
            s.invalid, s.stateError, s.dynamicsFault =
                true, "hard-cap", true
            postAction = "dynamics-fault"
        end
        local okHard = true
        if not s.fullGate then
            hardCapV, hardClampReason, okHard = MDADDynamics.lowerHardCap(
                hardCapV, hardClampReason, targetSpeed / 3.6, s.gateReason)
        elseif finite(s.lastSensorCap) then
            hardCapV, hardClampReason, okHard = MDADDynamics.lowerHardCap(
                hardCapV, hardClampReason,
                s.lastSensorCap / 3.6, s.lastSensorReason)
        end
        if s.followHold then
            hardCapV, hardClampReason, okHard =
                MDADDynamics.lowerHardCap(hardCapV, hardClampReason, 0, "moving")
        end
        if s.dodging and s.dodgeClass == MDADDynamics.DODGE_VEHICLE then
            hardCapV, hardClampReason, okHard = MDADDynamics.lowerHardCap(
                hardCapV, hardClampReason, s.dodgeSpeedCap / 3.6, "moving")
        end
        if s.currentBlocked then
            hardCapV, hardClampReason, okHard =
                MDADDynamics.lowerHardCap(hardCapV, hardClampReason, 0, "contact")
        end
        if s.mode == "recover" then
            hardCapV, hardClampReason, okHard =
                MDADDynamics.lowerHardCap(hardCapV, hardClampReason, 0, "recover")
        end
        if s.returnHold then
            hardCapV, hardClampReason, okHard =
                MDADDynamics.lowerHardCap(hardCapV, hardClampReason, 0, "return")
        elseif s.returnActive then
            hardCapV, hardClampReason, okHard = MDADDynamics.lowerHardCap(
                hardCapV, hardClampReason, targetSpeed / 3.6, "return")
        end
        if blockedStop then
            hardCapV, hardClampReason, okHard =
                MDADDynamics.lowerHardCap(hardCapV, hardClampReason, 0, "blocked")
        end
        if reached then
            hardCapV, hardClampReason, okHard =
                MDADDynamics.lowerHardCap(hardCapV, hardClampReason, 0, "arrive")
        end
        local curveKindActive = s.curveHardActive == true
        local hardCurveActive = curveKindActive
            and finite(s.curveKappa) and s.curveKappa > 0
        local hardCurveCap = s.curveCap
        if curveKindActive and not finite(s.curveKappa) then
            okHard = false
        elseif hardCurveActive then
            if finite(hardCurveCap) and hardCurveCap >= 0 then
                hardCapV, hardClampReason, okHard = MDADDynamics.lowerHardCap(
                    hardCapV, hardClampReason, hardCurveCap / 3.6, "curve")
            else
                okHard = false
            end
        end
        if not okHard then
            s.invalid, s.stateError, s.dynamicsFault =
                true, "hard-cap", true
            postAction = "dynamics-fault"
        end
        local actualSpeed = speedKmh
        if actualSpeed < 0 then actualSpeed = -actualSpeed end
        local hardBrakeReason
        local curveBreached = hardCurveActive and finite(hardCurveCap)
            and hardCurveCap >= 0 and actualSpeed > hardCurveCap + 0.5
        local visibilityBreached = sensorReady and finite(s.visibilityCap)
            and actualSpeed > s.visibilityCap + 0.5
        if curveBreached then hardBrakeReason = "curve" end
        if visibilityBreached
                and (not curveBreached or s.visibilityCap <= hardCurveCap) then
            hardBrakeReason = "visibility"
        end
        if s.mode == "gear-reset" then
            hardBrakeReason = nil
        end
        if s.followHold or s.currentBlocked or s.mode == "recover"
                or s.returnHold or blockedStop or reached then
            hardBrakeReason = hardClampReason
        end
        s.cmdV, s.cmdA, s.jerkBypassReason = MDADDynamics.jerkCommand(
            s.cmdV, s.cmdA, targetSpeed / 3.6, mult * SECONDS_PER_MULT,
            s.safeAccel, s.safeBrake, MDADDynamics.JERK_MAX,
            hardCapV, hardClampReason)
        if s.jerkBypassReason == "dynamics-invalid" then
            s.invalid, s.stateError, s.dynamicsFault =
                true, "command", true
            postAction = "dynamics-fault"
        end
        targetSpeed = s.cmdV * 3.6
        if hardBrakeReason then s.lastCapReason = hardBrakeReason end

        local regOn = false
        local force = 0
        if hardBrakeReason ~= nil then
            vehicle:setRegulator(false)
            commandForceBrake(s, vehicle, now)
            if hardCapV <= 0 then targetSpeed = 0 end
        elseif s.dynamicsFault then
            vehicle:setRegulator(false)
            commandForceBrake(s, vehicle, now)
            targetSpeed = 0
        elseif s.mode == "gear-reset" then
            vehicle:setRegulator(false)
        elseif s.mode == "recover" or s.currentBlocked then
            vehicle:setRegulator(false)
            commandForceBrake(s, vehicle, now)
            targetSpeed = 0
        elseif s.returnHold then
            vehicle:setRegulator(false)
            commandForceBrake(s, vehicle, now)
            targetSpeed = 0
        -- RETURN outranks a planned block whose Frenet anchor is no longer meaningful.
        elseif blockedStop then
            -- 前方無縫隙且已逼近障礙群：主動煞停等待（不是 Drive.stop——session
            -- 活著，掃描持續，障礙消失由 replan 解除；玩家接手走讓位）。停死後
            -- 卡死偵測會接手升級成倒車脫困→紅字停車，整條鏈自然收斂。
            vehicle:setRegulator(false)
            commandForceBrake(s, vehicle, now)
            targetSpeed = 0
            s.lastCapReason = "blocked"
            -- immutable DODGE 的守護驗證失敗會帶著剖面轉 blocked（車在動時清
            -- 剖面＝目標線瞬跳）：近停後才清承諾，之後停等重提案照常
            if s.dodging and not s.dodgeCapPending
                    and speedKmh < 1 and speedKmh > -1 then
                MDADFollower.clearOffset(s.fstate)
                releaseDodge(s)
            end
        elseif hardBrakeReason ~= nil then
            vehicle:setRegulator(false)
            commandForceBrake(s, vehicle, now)
        else
            regOn = applySpeed(s, vehicle, targetSpeed)
            if not reached then
                local aerr = headingError or 0
                if aerr < 0 then aerr = -aerr end
                local av = speedKmh
                if av < 0 then av = -av end
                if aerr > TUNE.ROTATE_ERR_RAD and av > TUNE.ROTATE_SPIN_MAX_KMH then
                    -- 調頭需求但還有動量：主動煞停到近停，這幀不施轉向。
                    -- （follower 的調頭爬行 target 12 只會讓 regulator 鬆油，
                    -- 滑行等速太久——期間路線反覆重算會把震盪放大）
                    vehicle:setRegulator(false)
                    commandForceBrake(s, vehicle, now)
                    regOn = false
                elseif aerr <= TUNE.ROTATE_ERR_RAD or av <= TUNE.ROTATE_SPIN_MAX_KMH then
                    -- 誤差 > 90° 走耦力模式（coupled=true）：力矩恆定、側向中心力
                    -- 幀間抵消＝原地旋轉不橫滑（實機：橫推調頭會滑出路外撞東西）。
                    -- **原地旋轉前先探車周**（500ms 節流）：走廊沿路線掃，路線反向
                    -- 要調頭時車後方／側面全是走廊盲區——貼牆貼樹貼車旋轉＝車身
                    -- 掃掠直接撞。周邊不淨空（或未載入）就退回橫推大弧：爬行 12
                    -- 前進轉，空間不夠自然由卡死→脫困鏈接手。
                    local coupled = aerr > TUNE.ROTATE_ERR_RAD
                    if coupled and s.sensor then
                        if now >= s.rotProbeMs then
                            s.rotProbeMs = now + TUNE.ROTATE_PROBE_MS
                            s.rotProbeClear = not MDADSensor.probeAround(
                                s.sensor, vehicle, getCell(), s.probeR)
                            if getDebug() then
                                print(LOG .. "pn=" .. playerNum .. " rotate probe: "
                                    .. (s.rotProbeClear and "clear (coupled spin)"
                                        or "obstructed (wide arc)"))
                            end
                        end
                        if not s.rotProbeClear then coupled = false end
                    end
                    if not coupled and targetSpeed > 0 and speedKmh >= 3
                            and finite(latDev) then
                        steer = (steer or 0)
                            - MDADDynamics.crossTrackSteer(latDev, speedKmh)
                    end
                    local assistForce = 0
                    if regOn and not coupled and speedKmh >= 0
                            and now >= s.forceBrakeUntil
                            and aerr <= TUNE.ASSIST_MAX_ERR_RAD then
                        assistForce = longitudinalAssistForce(
                            s, speedKmh, targetSpeed, mult)
                    end
                    force, s.lastAssistForce = applySteering(
                        s, vehicle, fwd, fx, fy, steer or 0,
                        speedKmh, mult, coupled, assistForce)
                end
            end
        end
        -- 跟線遙測：每秒最多一行。實機要判斷「轉不動」是誤差沒算出來、還是力太小，
        -- 只有同一行同時看到 errDeg 與 force 才分得開。旗標為假時整段完全不執行，
        -- 連字串都不會生成——這裡是每幀熱路徑。
        if getDebug() and now >= s.nextDebugMs then
            s.nextDebugMs = now + TUNE.DEBUG_MS
            print(string.format(
                "%spn=%d mode=%s speed=%.1f target=%.1f errDeg=%.1f steer=%.2f force=%.0f thrust=%.0f remaining=%.1f lat=%.1f road=%.2f gear=%d regulator=%s",
                LOG, playerNum, s.mode, speedKmh, targetSpeed or 0,
                (headingError or 0) * TUNE.DEG_PER_RAD, steer or 0,
                force, s.lastAssistForce, remaining or 0,
                sqrt(lateralSq or 0), s.roadBias,
                Drive.getGear(playerNum), tostring(regOn)))
        end
        if s.diag then
            -- 新 Java getter 只在這一幀確定會 enqueue sample 時才跑；
            -- shouldSample 與 D.sample 共用同一 5/10Hz gate。
            local critFlag = s.blocked or s.currentBlocked or s.dodging or s.returnActive
                or s.mode == "gear-reset" or s.mode == "recover"
            local want = true
            local failed = false
            if type(MDADDiagnostics.shouldSample) == "function" then
                local okW, w = pcall(MDADDiagnostics.shouldSample, playerNum, now,
                    s.mode, headingError, critFlag)
                if not okW then
                    diagFail(s, playerNum, "shouldSample failed", w)
                    failed = true
                else
                    want = w == true
                end
            end
            local phys
            if not failed and want then
                local okPhys, collected = pcall(collectPhys, s, vehicle, fx, fy,
                    s.diagExpL, s.diagLatDev)
                if not okPhys then
                    diagFail(s, playerNum, "physics collection failed", collected)
                    failed = true
                else
                    phys = collected
                end
            end
            if not failed then
                local recoveryMs = s.progressUntil - now
                if recoveryMs < 0 then recoveryMs = 0 end
                local ok, live = pcall(MDADDiagnostics.sample, playerNum, now,
                    vx, vy, heading, speedKmh, targetSpeed or 0, remaining or 0,
                    latSigned or 0, headingError or 0, steer or 0, force, s.mode,
                    Drive.getGear(playerNum), regOn, s.sensor, critFlag,
                    s.planMode, s.lastSNow, s.blockS, s.dodgeMargin, s.dodgeNeed,
                    s.roadBias, s.blockHitX, s.blockHitY, s.fstate.idx,
                    s.blocked or s.currentBlocked, s.dodging, s.returnActive,
                    s.cornerLatch, s.lastCoupled, phys,
                    s.targetGen, s.routeGen, s.episodeId, s.progressState,
                    s.episodeAttempts, s.pushBanL ~= nil and s.pushBanL or false,
                    s.unstickDistance, s.rearStatus, 0, recoveryMs,
                    s.actualClearance, s.plannedClearance, s.footprintBlocked,
                    s.footprintHitX, s.footprintHitY)
                if not ok then
                    diagFail(s, playerNum, "sample failed", live)
                elseif live ~= true then
                    s.diag = false
                    pcall(MDADDiagnostics.stop, playerNum, "stopped")
                end
            end
        end
        s.regulatorPrev = regOn
        s.forceBrakePrev = s.forceBrakeThis
        s.targetPrev = targetSpeed or 0
        s.steerPrev = steer or 0
    end
    BaseVehicle.releaseVector3f(fwd)
    if s.brakeTerminalFault then
        Drive.stop(playerNum, KEY_UNSUPPORTED)
        return
    end

    if postAction == "dynamics-fault" then
        vehicle:setRegulator(false)
        Drive.stop(playerNum, KEY_UNSUPPORTED)
        return
    end
    if postAction == "wait" or postAction == "return-fault" then
        Drive.stop(playerNum, KEY_STUCK)
        return
    elseif postAction == "recover" then
        startRecoveryAttempt(s, vehicle, playerNum, now, vx, vy)
        return
    end

    -- 抵達只認 follower 的 reached：它同時要求「沿線剩餘距離夠短」與「車真的在終點
    -- 附近」。這裡不得再加一條只看 remaining 的旁路——投影點滑到終點時 remaining 會
    -- 歸零，車卻可能還在幾十公尺外的路邊，那條旁路就是半路煞停宣告到站的來源。
    if reached and not s.currentBlocked then
        if s.lastTx then
            s.targetGen = s.targetGen + 1
            diagEvent(s, playerNum, "target", {
                phase = "clear", oldX = s.lastTx, oldY = s.lastTy,
                why = "arrive", tg = s.targetGen,
            })
            s.lastTx, s.lastTy = nil, nil
        end
        clearEpisode(s)
        s.mode = "arrive"
        if not s.forceBrakeThis then
            vehicle:setRegulator(false)
            commandForceBrake(s, vehicle, now)
        end
    end
end

-- OnPlayerUpdate 簽名：單一 IsoPlayer（IsoPlayer.java:2279 triggerEvent("OnPlayerUpdate", this)；
-- 原版用例 Steps.lua:1922、DebugDemoTime.lua:308）。伺服器端 isLocalPlayer 恆 false
-- （IsoPlayer.java:6493），遠端玩家也擋在這裡——自駕只在駕駛自己的 client 跑。
local function onPlayerUpdate(player)
    if sessionCount == 0 then return end
    if not player or not player:isLocalPlayer() then return end
    local playerNum = player:getPlayerNum()
    local s = sessions[playerNum]
    if not s then return end

    if player:isDead() then
        Drive.stop(playerNum, nil)
        return
    end

    -- 非原車／不再是駕駛／已下車：靜默結束（不是錯誤，不用紅字轟人）
    local vehicle = player:getVehicle()
    if vehicle ~= s.vehicle or not vehicle:isDriver(player) then
        Drive.stop(playerNum, nil)
        return
    end

    local now = getTimestampMs()
    if s.brakeTerminalFault then
        Drive.stop(playerNum, KEY_UNSUPPORTED)
        return
    end
    if refreshMass(s, vehicle, now) then
        s.dynamicsDirty, s.dynamicsCapMaterial = true, false
    end
    if now >= s.nextUsageMs then
        s.nextUsageMs = now + USAGE_HEARTBEAT_MS
        reportAutoUsage(player, vehicle, true, s.usageArgs, s.navUsageArgs)
    end

    -- 到達停車：只煞到停妥為止。這段刻意排在其他閘門之前——煞車途中就算引擎熄火
    -- （沒油）也要把車停好，不能半路放手。isStopped＝|速度|<0.8 且沒踩油門
    -- （BaseVehicle.java:4259-4260；原版同門檻 ISStopVehicle.lua:12）
    if s.mode == "arrive" then
        -- 煞停途中玩家自己接手就立刻交還（已送出的 forceBrake 最多殘留 1 秒後自行失效，
        -- CarController.java:973-979）——不然玩家會覺得車子在跟他搶煞車
        if manualInput(vehicle) then
            Drive.stop(playerNum, nil)
            return
        end
        vehicle:setRegulator(false)
        if vehicle:isStopped() then
            diagStop(s, playerNum, "arrive")
            clearSession(playerNum)
            haloGood(player, "UI_MinidoracatAutoDrive_Arrived")
        else
            if not commandForceBrake(s, vehicle, now) then
                Drive.stop(playerNum, KEY_UNSUPPORTED)
            end
        end
        return
    end

    local reason = driveGate(player, vehicle, playerNum, "draw")
    if reason then
        Drive.stop(playerNum, reason)
        return
    end
    local api = navApi()
    if not api then
        Drive.stop(playerNum, KEY_API)
        return
    end

    -- Target and route generations are independent: any finite coordinate change advances
    -- tg exactly like MiniMap target identity; a new route identity advances rg.
    if now >= s.nextRouteMs then
        s.nextRouteMs = now + ROUTE_REFRESH_MS
        refreshPolicies(s, vehicle, playerNum)
        local route, tx, ty = fetchRoute(api, playerNum)
        if not route then
            local arrived = false
            if tx == nil and s.lastTx then
                local ddx = s.lastTx - vehicle:getX()
                local ddy = s.lastTy - vehicle:getY()
                arrived = ddx * ddx + ddy * ddy <= ARRIVE_CLEAR_SQ
                s.targetGen = s.targetGen + 1
                diagEvent(s, playerNum, "target", {
                    phase = "clear", oldX = s.lastTx, oldY = s.lastTy,
                    why = arrived and "arrive" or "lost", tg = s.targetGen,
                })
                clearEpisode(s)
                s.lastTx, s.lastTy = nil, nil
            end
            if arrived then
                s.mode = "arrive"
                vehicle:setRegulator(false)
                if not commandForceBrake(s, vehicle, now) then
                    Drive.stop(playerNum, KEY_UNSUPPORTED)
                end
                return
            end
            Drive.stop(playerNum, KEY_LOST)
            return
        end

        local targetChanged = finite(s.lastTx) and finite(s.lastTy)
            and finite(tx) and finite(ty)
            and (tx ~= s.lastTx or ty ~= s.lastTy)
        if targetChanged then
            local oldX, oldY = s.lastTx, s.lastTy
            s.targetGen = s.targetGen + 1
            diagEvent(s, playerNum, "target", {
                phase = "change", oldX = oldX, oldY = oldY,
                x = tx, y = ty, why = "user", tg = s.targetGen,
            })
            clearEpisode(s)
            s.verifyArmPending = false
            s.resumeProgressPhase = nil
            s.resumeProgressUntil = 0
            s.pendingRouteWhy = "target"
        end
        s.lastTx, s.lastTy = tx, ty

        local versionChanged = api.navApiVersion ~= s.navVersion
        if route ~= s.route or versionChanged then
            local profile = MDADFollower.begin(
                route, s.maxSpeed, api.navApiVersion, s.vehicleProfile)
            if not profile then
                Drive.stop(playerNum, KEY_LOST)
                return
            end
            MDADVehicleProfile.configureFollower(
                profile, s.vehicleProfile, s.runtimeMass, s.rain)
            s.safeAccel, s.safeBrake, s.safeLat, s.safeCoast =
                profile.segAccel[1], profile.segBrake[1],
                profile.segLat[1], profile.segCoast[1]
            s.dynamicsAccelCap, s.dynamicsBrakeCap, s.dynamicsLatCap,
                s.dynamicsCoastCap = s.safeAccel, s.safeBrake, s.safeLat, s.safeCoast
            MDADFollower.setRuntimeLimits(
                s.fstate, s.safeAccel, s.safeBrake, s.safeLat, s.safeCoast)
            local routeWhy = s.pendingRouteWhy
            if routeWhy == nil then routeWhy = targetChanged and "target" or "deviation" end
            s.pendingRouteWhy = nil
            s.routeGen = s.routeGen + 1
            local oldMode, oldProgress, oldUntil = s.mode, s.progressState, s.progressUntil
            local preservingRecovery = not targetChanged
                and (oldMode == "unstick" or oldMode == "settle" or oldMode == "recover")
            local targetSettling = targetChanged
                and (oldMode == "unstick" or oldMode == "settle")
            local resumePhase = nil
            if not targetChanged and oldMode == "gear-reset" then
                resumePhase = "gear-reset"
            elseif not targetChanged and oldProgress == "verify" then
                resumePhase = "verify"
            end
            s.route = route
            s.profile = profile
            s.navVersion = api.navApiVersion
            Drive.invalidateCommandState(s, vehicle:getCurrentSpeedKmHour(), "HOLD")
            s.adaptive = profile.adaptive == true
            s.dynamicsDirty, s.dynamicsCapMaterial = false, false
            if targetSettling then
                s.mode = "settle"
                s.progressState = "settle"
                s.reverseForce = 0
                if oldMode == "unstick" then
                    s.settleUntil = now + SETTLE_MS
                    diagEvent(s, playerNum, "unstick", {
                        phase = "settle", eid = 0, attempt = 0,
                        x = vehicle:getX(), y = vehicle:getY(), s = 0,
                        d = s.unstickDistance, rear = "target-change",
                    })
                end
            elseif resumePhase ~= nil or not preservingRecovery then
                s.mode = "build"
            end
            s.routeReadyEventPending = true
            s.routeReadyWhy = routeWhy
            local pointN = type(route.pts) == "table" and #route.pts / 2 or 0
            local routeLen = finite(route.len) and route.len or nil
            diagEvent(s, playerNum, "route", {
                phase = "cutover", why = routeWhy, rg = s.routeGen,
                tg = s.targetGen, len = routeLen, pts = pointN,
                target = tostring(tx) .. "," .. tostring(ty),
                navVersion = s.navVersion,
                currentSurface = MDADFollower.surfaceName(profile.segSurface[1]),
                currentSegWidth = profile.segWidth[1] > 0 and profile.segWidth[1] or nil,
                cost = finite(route.cost) and route.cost or nil,
                avoidPenalty = finite(route.avoidPenalty) and route.avoidPenalty or nil,
            })
            if type(MDADFollower.resetState) == "function" then
                MDADFollower.resetState(s.fstate)
            end
            s.roadBias = 0
            if type(MDADFollower.setLaneBias) == "function" then
                MDADFollower.setLaneBias(s.fstate, s.sandBias)
            end
            if s.sensor then s.sensor.scanBias = s.sandBias end
            if type(MDADOverlay) == "table"
                    and type(MDADOverlay.clearTrail) == "function" then
                MDADOverlay.clearTrail(playerNum)
            end
            releaseDodge(s)
            s.blocked = false
            s.blockedNotified = false
            s.returnActive, s.returnUnsafe, s.returnHold = false, false, false
            s.returnCrawlExact, s.returnCapacityFault = false, false
            s.returnReason, s.returnClearRounds = nil, 0
            s.surfaceMismatch, s.surfaceMismatchRounds = false, 0
            s.physicalOffroad = false
            s.currentSurfaceId = profile.segSurface[1]
            s.currentSegWidth = profile.segWidth[1]
            s.tractionKey, s.kinPrevMs = -1, 0
            s.nextDynamicsMs = now + 1000
            s.accelMean, s.accelDev, s.accelTime = 0, 0, 0
            s.accelConfidence, s.accelLower = 0, 0
            s.coastMean, s.coastDev, s.coastTime = 0, 0, 0
            s.coastConfidence, s.coastLower = 0, 0
            s.brakeMean, s.brakeDev, s.brakeTime = 0, 0, 0
            s.brakeConfidence, s.brakeLower = 0, 0
            s.yawMean, s.yawDev, s.yawTime = 0, 0, 0
            s.yawConfidence, s.yawLower = 0, 0
            s.forceBrakePrev, s.regulatorPrev = false, false
            if s.forceBrakeUntil > s.ewmaSuppressUntil then
                s.ewmaSuppressUntil = s.forceBrakeUntil
            end
            s.targetPrev, s.steerPrev = 0, 0
            s.clearStreak = 0
            s.followHold = false
            s.waitSince = 0
            s.detourTried = false
            s.cornerLatch = false
            s.blockHitX, s.blockHitY = nil, nil
            s.planSig = -1 -- route 首輪 clear 也必 replan，讓 remapped ban 進 planner
            s.lastSNow = 0
            s.fullGate, s.gateReason, s.alignSince = false, "sensor", 0
            s.curveVerifiedUntilS = 0
            s.verifyBand, s.verifySweep = false, false
            s.jerkBypassReason = nil
            if s.episodeActive and not targetChanged then
                s.episodeMapPending = s.banFromRecovery and finite(s.episodeHitX)
                    and finite(s.episodeHitY)
                s.pushBanL, s.pushBanS = nil, 0
            end
            if resumePhase ~= nil then
                s.resumeProgressPhase = resumePhase
                s.resumeProgressUntil = oldUntil
            elseif not preservingRecovery and not targetSettling then
                s.progressState = "disarmed"
                s.progressSince = 0
            end
            vehicle:setRegulator(false)
        end
    end

    -- Every dynamics rebuild changes the profile epoch, so no completed-snapshot
    -- minima or lane envelope may survive even for regime/mass/key changes.
    if s.dynamicsDirty and s.mode == "follow" then
        Drive.invalidateCommandState(s, vehicle:getCurrentSpeedKmHour(), "HOLD")
        local material = s.dynamicsCapMaterial == true
        MDADVehicleProfile.configureFollower(
            s.profile, s.vehicleProfile, s.runtimeMass, s.rain)
        s.horizonStamp = -1
        s.horizonMinBrake, s.horizonMinLat, s.horizonMinCoast = 0, 0, 0
        s.verifyLineN = 0
        s.laneCurveEnvelope, s.laneCurveStamp,
            s.laneCurveS0, s.laneCurveEnd,
            s.envelopeBuildLat, s.envelopeBuildCoast,
            s.laneEnvelopeScale = 0, -1, 0, 0, -1, -1, 1
        if material then
            MDADFollower.capSegmentLimits(
                s.profile, s.safeAccel, s.safeBrake, s.safeLat, s.safeCoast)
        else
            local idx = s.fstate.idx or 1
            idx = idx - idx % 1
            if idx < 1 then idx = 1 elseif idx >= s.profile.n then idx = s.profile.n - 1 end
            s.safeAccel, s.safeBrake, s.safeLat, s.safeCoast =
                s.profile.segAccel[idx], s.profile.segBrake[idx],
                s.profile.segLat[idx], s.profile.segCoast[idx]
            MDADFollower.setRuntimeLimits(
                s.fstate, s.safeAccel, s.safeBrake, s.safeLat, s.safeCoast)
        end
        MDADFollower.invalidateDynamics(s.profile)
        s.dynamicsAccelCap, s.dynamicsBrakeCap, s.dynamicsLatCap,
            s.dynamicsCoastCap = s.safeAccel, s.safeBrake, s.safeLat, s.safeCoast
        s.tractionKey, s.kinPrevMs = -1, 0
        s.accelMean, s.accelDev, s.accelTime = 0, 0, 0
        s.accelConfidence, s.accelLower = 0, 0
        s.coastMean, s.coastDev, s.coastTime = 0, 0, 0
        s.coastConfidence, s.coastLower = 0, 0
        s.brakeMean, s.brakeDev, s.brakeTime = 0, 0, 0
        s.brakeConfidence, s.brakeLower = 0, 0
        s.yawMean, s.yawDev, s.yawTime = 0, 0, 0
        s.yawConfidence, s.yawLower = 0, 0
        s.forceBrakePrev, s.regulatorPrev = false, false
        if s.forceBrakeUntil > s.ewmaSuppressUntil then
            s.ewmaSuppressUntil = s.forceBrakeUntil
        end
        s.targetPrev, s.steerPrev = 0, 0
        s.dynamicsDirty, s.dynamicsCapMaterial = false, false
        s.mode = "build"
        vehicle:setRegulator(false)
    end

    -- v4 detour acceptance uses finite numeric avoidPenalty==0; geometry len is
    -- never polluted by A* penalty. Genuine v2/v3 retain the legacy len sentinel.
    if s.blocked then
        local detourWait = s.cornerLatch and CORNER_DETOUR_MS or DETOUR_AFTER_MS
        if not s.detourTried and s.waitSince ~= 0
                and now - s.waitSince >= detourWait
                and type(api.requestDetour) == "function" and s.lastTx ~= nil then
            s.detourTried = true
            -- 避讓圈錨：優先 sweep 真命中的世界座標——hardS 在折點區與世界
            -- 差 3-6m，經 posAt 轉回會錨錯（codex 裁決）
            local bx, by
            if type(s.blockHitX) == "number" then
                bx, by = s.blockHitX, s.blockHitY
            else
                bx, by = posAt(s.profile, s.blockS or s.lastSNow)
            end
            if bx ~= nil then
                local droute = api.requestDetour(playerNum, s.lastTx, s.lastTy,
                    bx, by, DETOUR_AVOID_R)
                local detourClean = droute ~= nil and droute ~= s.route
                if detourClean then
                    if s.navVersion >= 4 then
                        detourClean = finite(droute.avoidPenalty)
                            and droute.avoidPenalty == 0
                    else
                        detourClean = finite(droute.len) and droute.len < DETOUR_FAIL_LEN
                    end
                end
                if detourClean then
                    s.pendingRouteWhy = "detour"
                    s.nextRouteMs = 0 -- 下一幀立刻走 route 刷新塊 cutover
                    local playerObj = getSpecificPlayer(playerNum)
                    if playerObj then haloGood(playerObj, KEY_DETOUR) end
                    if getDebug() then
                        print(LOG .. "pn=" .. playerNum .. " detour: rerouting around block")
                    end
                elseif getDebug() then
                    -- v4 positive/missing avoidPenalty is not a proven alternative;
                    -- v2/v3 keep the historical length sentinel.
                    if droute then
                        print(LOG .. "pn=" .. playerNum .. " detour rejected: no real alternative")
                    else
                        print(LOG .. "pn=" .. playerNum .. " detour: no route (noroad/engine)")
                    end
                end
            end
        end
    else
        s.detourTried = false
    end

    -- 限速剖面分幀建構：ready 之前不控速也不施力。
    if s.mode == "build" then
        if s.commandControlState ~= "HOLD" then
            Drive.invalidateCommandState(s, vehicle:getCurrentSpeedKmHour(), "HOLD")
        end
        if not MDADFollower.stepBuild(s.profile, BUILD_BUDGET) then return end
        if s.routeReadyEventPending then
            s.routeReadyEventPending = false
            diagEvent(s, playerNum, "route", {
                phase = "ready", why = s.routeReadyWhy, rg = s.routeGen,
                tg = s.targetGen, len = s.profile.length, pts = s.profile.n,
                target = s.lastTx and (tostring(s.lastTx) .. "," .. tostring(s.lastTy)) or nil,
                navVersion = s.navVersion,
                currentSurface = MDADFollower.surfaceName(s.currentSurfaceId),
                currentSegWidth = s.currentSegWidth > 0 and s.currentSegWidth or nil,
                cost = finite(s.route.cost) and s.route.cost or nil,
                avoidPenalty = finite(s.route.avoidPenalty)
                    and s.route.avoidPenalty or nil,
            })
        end
        s.mode = "follow"
        local resumePhase = s.resumeProgressPhase
        local resumeUntil = s.resumeProgressUntil
        s.resumeProgressPhase = nil
        s.resumeProgressUntil = 0
        if resumePhase == "gear-reset" and now < resumeUntil then
            s.mode = "gear-reset"
            s.progressState = "gear-reset"
            s.progressUntil = resumeUntil
        elseif resumePhase == "gear-reset" then
            s.verifyArmPending = true
            s.verifyArmUntil = now + TUNE.VERIFY_MS
        elseif resumePhase == "verify" then
            s.verifyArmPending = true
            s.verifyArmUntil = resumeUntil
        end
    end

    -- 讓位：玩家一碰方向盤／油門／煞車就交還控制權，關掉 regulator（等同原版踩煞車
    -- 或倒車時的處理，CarController.java:461-463），並且**本幀不施力**。
    if manualInput(vehicle) then
        if s.mode ~= "yield" then
            s.mode = "yield"
            vehicle:setRegulator(false)
            Drive.invalidateCommandState(s, vehicle:getCurrentSpeedKmHour(), "YIELD")
            if not s.yieldNotified then
                s.yieldNotified = true
                haloGood(player, "UI_MinidoracatAutoDrive_ManualOverride")
            end
        end
        s.cleanSinceMs = 0
        return
    end
    if s.mode == "yield" then
        -- 恢復用「連續乾淨時間」而非幀數：舊制 10 幀（~0.17 秒）等於手一離開鍵盤
        -- 就立刻接管，玩家把車頭調到反向時會瞬間吃到飽和調頭側推、整台車甩出去
        -- （2026-08-28 實機回報「剛放手就誇張瞬間調頭」）。改 2 秒緩衝＋恢復提示，
        -- 玩家看得到「它要接手了」。
        if s.cleanSinceMs == 0 then
            s.cleanSinceMs = now
            return
        end
        if now - s.cleanSinceMs < YIELD_RESUME_MS then return end
        s.cleanSinceMs = 0
        s.mode = "follow"
        s.yieldNotified = false -- 下次讓位再提示一次（讓位↔恢復是成對事件）
        -- 清控制歷史（保留投影游標）：yield 期間玩家可能大幅改變車頭朝向，
        -- 舊的 PID 積分／微分歷史對新姿態是雜訊
        if type(MDADFollower.resetControl) == "function" then
            MDADFollower.resetControl(s.fstate)
        end
        invalidateReturnControl(s)
        Drive.invalidateCommandState(s, vehicle:getCurrentSpeedKmHour(), "TRACK")
        s.progressState = "disarmed"
        s.progressSince = 0
        haloGood(player, "UI_MinidoracatAutoDrive_Resume")
    end

    -- Reverse recovery and its settle phase bypass normal follow control. Manual input
    -- already yielded above, so neither path can fight the player.
    if s.mode == "unstick" or s.mode == "settle" then
        stepUnstick(s, vehicle, playerNum, now)
        if s.brakeTerminalFault then Drive.stop(playerNum, KEY_UNSUPPORTED) end
        return
    end

    -- now 是這一幀早先取的 getTimestampMs()（路線節流共用）：遙測節流不再多打一次
    stepFollow(s, vehicle, playerNum, now)
end

Events.OnPlayerUpdate.Add(onPlayerUpdate)

-- 回主選單時 OnPlayerUpdate 已不可靠；主動收掉 drive state 與 telemetry writer。
-- Diagnostics 也有自己的同事件保險，兩邊 stop 都是冪等。
local function onMainMenuEnter()
    for playerNum = 0, 3 do
        local s = sessions[playerNum]
        if s then
            diagStop(s, playerNum, "menu")
            clearSession(playerNum)
            if s.vehicle then
                pcall(function() s.vehicle:setRegulator(false) end)
            end
        end
    end
end
Events.OnMainMenuEnter.Add(onMainMenuEnter)

--------------------------------------------------------------------------------
-- 車輛 radial 選單
--------------------------------------------------------------------------------

-- 自訂圖示：42/media/textures/Item_AutopilotModule.png。完整 media 相對路徑＋副檔名是
-- 原版慣例（ISVehicleMenu.lua:85 等）；物品貼圖另有無路徑寫法（ISHutchUI.lua:95），
-- 兩者都試一次。材質缺漏時 getTexture 回 nil，RadialMenu 會直接跳過繪圖
-- （RadialMenu.java:144-145 有 null 檢查），只是那片沒有圖，功能不受影響。
local sliceTexture = nil

local function autoDriveTexture()
    if sliceTexture == nil then
        sliceTexture = getTexture("media/textures/Item_AutopilotModule.png")
        if sliceTexture == nil then sliceTexture = getTexture("Item_AutopilotModule") end
    end
    return sliceTexture
end

-- 裝飾原版 showRadialMenu：原版自己會 clear()→建 slices→addToUIManager
-- （ISVehicleMenu.lua:57-230），所以只能**在它跑完之後**補片，在它之前寫會被 clear 掉。
-- 不能用「呼叫原版後 isReallyVisible()」判定是否開啟：addToUIManager 只呼叫
-- UIManager.AddUI（ISUIElement.lua:1365-1371），同一 call stack 不保證 Java 已回報
-- really-visible；實機 2026-08-28 因此開了 radial 卻漏掉本片。正確判定是：
-- 呼叫前已可見＝這次是 toggle-close；呼叫前不可見且未暫停＝這次是 open，原版完成後補片。
-- 車外 radial 走 showRadialMenuOutside（ISVehicleMenu.lua:63），vehicle 檢查自然排除。
-- 檔位片：循環切檔＋頭上綠字回饋新檔位。手把玩家的檔位操作等價路徑
-- （HUD 按鈕是滑鼠路徑；radial 手把原生）。
local function cycleGearSlice(playerObj)
    if not playerObj then return end
    local g = Drive.cycleGear(playerObj:getPlayerNum())
    haloGood(playerObj, GEAR_KEYS[g])
end

local originalShowRadialMenu = ISVehicleMenu.showRadialMenu

function ISVehicleMenu.showRadialMenu(playerObj)
    local menu = nil
    local wasVisible = false
    if playerObj then
        menu = getPlayerRadialMenu(playerObj:getPlayerNum())
        wasVisible = menu and menu:isReallyVisible() == true
    end
    local speedControls = UIManager.getSpeedControls()
    local isPaused = speedControls and speedControls:getCurrentGameSpeed() == 0
    originalShowRadialMenu(playerObj)
    if not playerObj or isPaused or wasVisible then return end
    local vehicle = playerObj:getVehicle()
    if not vehicle or not vehicle:isDriver(playerObj) then return end
    if not menu then menu = getPlayerRadialMenu(playerObj:getPlayerNum()) end
    if not menu then return end
    local labelKey = "UI_MinidoracatAutoDrive_Start"
    if Drive.isActive(playerObj:getPlayerNum()) then labelKey = "UI_MinidoracatAutoDrive_Stop" end
    -- addSlice(text, texture, command, arg1..arg6)＝ISRadialMenu.lua:44-52；
    -- instantiate 之後加的片仍會推進 javaObject（:50-51）
    menu:addSlice(getText(labelKey), autoDriveTexture(), Drive.toggle, playerObj)
    -- 檔位片（同一次 open 補在自駕片之後）：片文字帶當前檔位，點了循環到下一檔
    local g = Drive.getGear(playerObj:getPlayerNum())
    menu:addSlice(getText("UI_MinidoracatAutoDrive_GearSlice", getText(GEAR_KEYS[g])),
        autoDriveTexture(), cycleGearSlice, playerObj)
end
