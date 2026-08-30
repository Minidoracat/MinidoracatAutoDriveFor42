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

--------------------------------------------------------------------------------
-- 調校常數
--------------------------------------------------------------------------------

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
local ROTATE_SPIN_MAX_KMH = 5
local ROTATE_ERR_RAD = 1.5708  -- 90°
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
local REAR_ARM = 2.2           -- relPos 後移量（公尺）：偏航力臂，力矩＝F*REAR_ARM
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

-- 卡死偵測：M3 不避障，撞上障礙物時 regulator 會永遠推牆（實機 2026-08-28：
-- speed≈0、errDeg 卡在 76°、remaining 十秒不動，玩家只能自己按停）。三個條件
-- 缺一不可才算卡死——速度近零「且」沿線進度凍結「且」車頭也沒在轉；原地調頭
-- （速度近零但 errDeg 在動）與末段挪車（remaining 在動）都不會誤觸。
local STUCK_SPEED_KMH = 1.0    -- |速度| 低於此值才可能算卡死
local STUCK_ERR_EPS = 0.1      -- 弧度（≈6°）：航向變化超過就算「還在轉」，重置計時
local STUCK_REM_EPS = 1.0      -- 公尺：沿線進度變化超過就算「還在動」，重置計時
local STUCK_MS = 5000          -- 三者都凍結持續這麼久＝卡死，自動停車＋紅字

-- M4 感知與繞行（Sensor 掃走廊 → Corridor 算縫隙 → follower.setOffset 疊側偏；
-- 三層相依見 MDAD_Sensor.lua 檔頭）。速度上限檔位：全部是「疊在剖面之上的 min」，
-- 不改剖面本身；殭屍／屍體檔位受三態沙盒政策×玩家偏好控制（refreshPolicies）。
local NEED_HALF = 1.4          -- 車半寬＋margin（公尺）：縫隙可行性的車體投影
local DODGE_CAP = 24           -- 繞行 entry／exit 基準速度；保持段另放寬到 28 km/h
local ZOMBIE_CAP_1 = 25        -- 走廊內 ≥1 隻殭屍
local ZOMBIE_CAP_4 = 15        -- ≥4 隻
local ZOMBIE_CAP_8 = 10        -- ≥8 隻
local MOVING_VEH_CAP = 15      -- 走廊內有行進中的別台車（跟車，不繞行）
local UNLOADED_CAP = 15        -- 走廊內有未載入 chunk（不知道前面有什麼，先慢）
local POLICY_DODGE = 1         -- 沙盒 ObstaclePolicy enum：1=繞行 2=停車

local BLOCK_STOP_DIST = 15     -- 距障礙群這麼近才煞停等待；更遠先滑行接近
local BLOCK_APPROACH_KMH = 12  -- blocked 接近段的速度上限（掃描逼近後縫隙判定更準）
local WAIT_TIMEOUT_MS = 20000  -- 停等（blocked/跟車 0）獨立超時：紅字請玩家接手
-- 推撞偵測（幽靈車兜底）：輪速明明夠快、車體世界位移卻近零＝頂著看不見
-- 的實體空推（MP 車輛 streaming 抖動時感知可能全漏，但碰撞仍是 server 權威）。
-- 必須量世界位移，不量沿線 s：8106,11769 十字路口回線時，車以 15 km/h
-- 橫向移動 20→4m，remaining 暫時固定 603.6；舊算法把合法回線連判三次
-- push mismatch。直線 8 km/h 在 2.5 秒約走 5.5m；世界弦長連 3m
-- （理論直線位移的 55%）都不到才判失配。
local PUSH_MIN_KMH = 8         -- 輪速下限：低於此速交給既有卡死三凍結
local PUSH_MS = 2500           -- 失配持續窗
local PUSH_FREE_M = 3.0        -- 窗內車體世界位移達標線（達標＝重臂計時）
local PUSH_FREE_SQ = PUSH_FREE_M * PUSH_FREE_M -- 載入期算一次，熱路徑不重乘
local SCAN_WARM_CAP = 12       -- 感知空窗（首輪掃描未完成）的爬行上限
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
local SQUEEZE_NEED = 1.2       -- 爬行檔規劃半寬（物理半寬 0.9＋0.3；普通 1.4）
local SQUEEZE_CAP = 10         -- 爬行檔速度上限（km/h；2026-08-29 使用者裁定 6 過慢）
local SWEEP_BASE = 1.3         -- 世界掃掠基準淨距＝規劃半寬 − 0.1（三檔同一關係）
local CORNER_NEAR = 8          -- sweep 失敗點離折點多近算「折點衝突」（BLOCKED_CORNER 判定）
local CORNER_DETOUR_MS = 2500  -- BLOCKED_CORNER 的改道等待（近距重枚舉也失敗才走）
local CORNER_RETRY_DIST = 3    -- corner latch 撤銷距離：漸進接近讓車前進這麼多＝
                               -- 幾何已變、重新枚舉——實測「靠很近開導航就能繞」
                               -- ＝近距下折點幾何退化成直路障礙，把手動流程自動化
local CORNER_STOP_DIST = 8     -- corner 下的煞停線（普通 blocked 15m）：爬更近再停，
                               -- 給近距重枚舉創造與「近開導航」相同的幾何條件
local CURVE_LEAD = 8           -- 過渡段要在折點前多遠完成（公尺）：進彎前把側移
                               -- 做完、彎中全程保持目標線——過渡線切折角掃到彎
                               -- 外側障礙是 2026-08-29 路口七連殺的幾何根因
-- 路面對中（sensor 每輪產出 roadC＝路面帶中心相對 nav 線的橫向偏移）：
-- streets.xml 的 nav 線只有「世界地圖畫線」精度（實測偏 2-4m），行駛線＝
-- 沙盒靠右偏置＋EMA 平滑後的路面校正。無樣本（路口外／無路面）時衰減回 0。
local ROAD_EMA = 0.25          -- 每輪（250ms）向新樣本收斂的比例（時常數 ~1s）
local ROAD_DECAY = 0.85        -- 無樣本輪的衰減係數
local ROAD_CLAMP = 3           -- 單輪樣本與累積校正的限幅（公尺）
local BIAS_MAX = 3             -- 合成行駛線限幅（offroad 門檻 4m 內留 1m 裕度）
local SOFT_CAP = 20            -- 走廊內有可輾過的軟障礙（家具／雜物）時的速度上限
local CORPSE_CAP = 20          -- 走廊內有地面屍體（壓得過，但不減速輾過的體感就是撞擊）
-- 甩出判定：車實際橫向位置對期望線（laneBias＋側偏剖面）的偏差，平方比較省 sqrt。
-- 偏離 4m 代表跟線已失效（合法可行帶雖到 ±5.6，但正常繞行對期望線的偏差應接近 0），
-- 因此斜插回線一律爬行。
local OFFROAD_LAT_SQ = 16      -- 對期望線偏差 > 4 公尺（平方）
local OFFROAD_CAP = 15         -- 甩出後的回線爬行上限（km/h）
-- 原地調頭的車周安全探測：耦力旋轉的車身掃掠 ~2.5m，貼牆貼樹貼車旋轉會撞。
-- 半徑 4（車身掃掠對角 ~2.5＋樹幹偏格心＋餘裕；3 太貼邊——2026-08-28 實機
-- 樹旁調頭掃到樹）；500ms 節流（調頭歷時數秒，冷路徑）
local ROTATE_PROBE_R = 4
local OFFROAD_EXIT_SQ = 4      -- 回到橫偏 < 2 公尺（平方）才算回線（遲滯防抖）
local CLEAR_STREAK_N = 2       -- 繞行/堵住要連續這麼多輪 clear 才解除（掃描窗漂移防抖）
local ROTATE_PROBE_MS = 500
-- 高速誤差護欄：>70 的目標速度按航向誤差線性折返回 70（誤差 0＝滿速、
-- ≥10°＝70）。轉向標定 ≤70；沙盒 ≤70 時零作用。
local HS_BASE_KMH = 70
local HS_ERR_RAD = 0.1745      -- 10°

-- 感知閉環的標準／高速組態分界：標準掃描帶前伸 48m，一輪最慢約 200ms，
-- 再受 250ms 啟動節流影響；85 km/h 是既有標準組態的保守相容上限與高速檔
-- 啟用門檻，不宣稱是所有載具／路況的形式化煞停證明。沙盒上限超過 85 時，
-- session 會把掃描帶改成 110m、感知上限改成 120；兩者必須一起切換。
local PERCEPTION_CAP_KMH = 85
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
local DEBUG_MS = 1000          -- 跟線診斷的最小間隔（毫秒）
local DEG_PER_RAD = 180 / 3.14159265358979

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
    if type(api.navApiVersion) ~= "number" or api.navApiVersion < 2 then return nil end
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
    local ahead = maxSpeedKmh() > PERCEPTION_CAP_KMH and HISPEED_AHEAD_M or baseAhead
    local s = sessions[playerNum]
    local sensorAhead = s and s.sensor and s.sensor.aheadM
    if type(sensorAhead) == "number" and sensorAhead >= baseAhead then ahead = sensorAhead end
    return nearM, ahead, bandM,
        ZOMBIE_CAP_1, ZOMBIE_CAP_4, ZOMBIE_CAP_8, CORPSE_CAP
end

-- HUD 唯讀狀態（M5.5b 面板的資料面）。回**多值純量**、不洩漏 session table
-- （session 是可變內部狀態，交出參考＝UI 能繞過所有入口改駕駛行為）：
--   statusKey, gearId, effectiveCapKmh, zombieSlowOn, corpseSlowOn
-- statusKey ∈ arrive/yield/unstick/blocked/dodging/build/follow；nil＝無 session。
-- 顯示優先序（狀態是 mode＋正交旗標的混合，UI 不該自己拼）：
-- arrive > yield > unstick > blocked > dodging > build > follow。
-- effectiveCap＝min(session 啟動時沙盒上限, 當前檔位)。AutoDriveMaxSpeed 要重開
-- session 才重建 profile；HUD 不得先讀新沙盒值而顯示車子尚未套用的上限。
function Drive.hudState(playerNum)
    local s = sessions[playerNum]
    if not s then return nil end
    local key
    if s.mode == "arrive" then key = "arrive"
    elseif s.mode == "yield" then key = "yield"
    elseif s.mode == "unstick" then key = "unstick"
    elseif s.blocked then key = "blocked"
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
-- pcall；sample 回 false 或丟錯就關閉該 session 的診斷，絕不打斷駕駛。
-- start／event／stop 同樣隔離。
local function diagEnabled()
    local hud = MDAD.HUD
    if type(hud) ~= "table" or type(hud.telemetryEnabled) ~= "function" then
        return false
    end
    local ok, en = pcall(hud.telemetryEnabled)
    return ok and en == true
end

local function diagEvent(s, playerNum, name, a, b, c, d)
    if not s or not s.diag then return end
    pcall(MDADDiagnostics.event, playerNum, name, a, b, c, d)
end

local function diagStop(s, playerNum, reason)
    if not s or not s.diag then return end
    pcall(MDADDiagnostics.stop, playerNum, reason)
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
    local profile = MDADFollower.begin(route, maxSpeed)
    if not profile then return KEY_ROUTE end
    local fstate = nil
    if type(MDADFollower.newState) == "function" then fstate = MDADFollower.newState() end
    if type(fstate) ~= "table" then fstate = {} end
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
        maxSpeed = maxSpeed,
        perceptionCap = maxSpeed > PERCEPTION_CAP_KMH and HISPEED_CAP_KMH or PERCEPTION_CAP_KMH,
        mode = "build",  -- build → follow ⇄ yield → arrive
        nextRouteMs = startedAt + ROUTE_REFRESH_MS,
        nextUsageMs = startedAt + USAGE_FIRST_RETRY_MS,
        usageArgs = { vehicleId = vehicle:getId(), active = true },
        navUsageArgs = { active = true },
        nextDebugMs = 0, -- 下一次允許印跟線遙測的時間戳（0＝第一幀就印）
        cleanSinceMs = 0, -- yield 中「連續乾淨輸入」的起點時戳（0＝還沒開始計）
        parity = 1,
        yieldNotified = false,
        stuckSince = 0,  -- 0＝目前不在「疑似卡死」狀態；非 0＝開始凍結的時間戳
        stuckErr = 0,    -- 疑似卡死起點的航向誤差（弧度）
        stuckRem = 0,    -- 疑似卡死起點的沿線剩餘距離（公尺）
        -- M4 感知與繞行。sensor 缺席（檔案樹壞）＝感知停用、退回 M3 純跟線，
        -- 不算錯誤：繞行是加值功能，跟線本體不依賴它。
        sensor = (type(MDADSensor) == "table" and type(MDADSensor.newState) == "function")
            and MDADSensor.newState() or false,
        planSig = 0,        -- 上次餵給 Corridor 的障礙簽章（sig 沒變就不重規劃）
        dodging = false,    -- 側偏剖面目前掛在 fstate 上
        dodgeTight = false, -- 本次繞行在彎道段（速度壓爬行；replan 每次重判）
        dodgeNotified = false, -- 繞行提示只出一次（clear/blocked/換路線時重臂）
        lastSNow = 0,       -- 最近一幀的沿線弧長（脫困額度重臂＋進 unstick 時記錨）
        blocked = false,    -- 前方無縫隙：煞停等待（障礙消失或玩家接手）
        blockedNotified = false, -- blocked 紅字只提示一次（解除後重臂）
        unstickCount = 0,   -- 連續脫困次數（沿線前進 UNSTICK_PROGRESS 即歸零）
        unstickS = 0,       -- 進入 unstick 當下的沿線弧長（算前進量用）
        unstickX = 0, unstickY = 0, unstickUntil = 0, -- 脫困起點與時限
        blockS = 0,         -- blocked 障礙群起點弧長（漸進接近的距離錨；0＝立即煞停）
        lastTx = tx, lastTy = ty, -- 最後一次成功查到的導航目標（抵達接管判定用）
        gearCap = 0,        -- 檔位巡航上限快取（refreshPolicies 維護；>0 才生效）
        zombieSlow = true,  -- 政策×偏好合成快取：這位玩家要不要為殭屍減速
        corpseSlow = true,  -- 同上，地面屍體
        rotProbeMs = 0,     -- 下一次允許車周探測的時戳（0＝第一次調頭幀就探）
        rotProbeClear = false, -- 上次探測結果：車周淨空可原地旋轉
        offroad = false,    -- 對期望線偏差過大（遲滯 4m 進／2m 出）
        clearStreak = 0,    -- 連續 clear 輪數（堵住解除遲滯）
        followHold = false, -- 跟車分級把目標壓 0（停等豁免卡死偵測用）
        waitSince = 0,      -- 停等起點時戳（0＝非停等；獨立超時紅字）
        pushSince = 0,      -- 推撞失配計時起點（0＝未累計，此時 pushX/pushY 是廢值）
        detourTried = false, -- 本次 blocked episode 已試過改道（解除時重臂）
        dodgeCrawl = false, -- 承諾剖面是 squeeze 檔（entry／hold／exit 全段上限 10）
        dodgeMargin = 1,    -- commit 時 a..c 最小餘裕（entry／hold 速度縮放輸入）
        pushBanL = nil,     -- 推撞實證不可行的縫（本 episode 不再提案；nil＝無）
        cornerLatch = false, -- BLOCKED_CORNER：障礙貼折點、軌跡契約不支援（快速改道）
        cornerS = 0,        -- corner latch 時的沿線弧長（前進 CORNER_RETRY_DIST 即撤銷重枚舉）
        tmpOvX = {}, tmpOvY = {}, -- M6 候選折線工作表（buildOffsetLine 輸出、commit 時複製進 fstate）
        lastOvN = 0,        -- 最後成功候選的折線點數（setOffset 交表用）
        lastOvS0 = 0,
        blockHitX = nil,    -- sweep 真命中世界座標（detour 避讓圈直接用，不經弧長轉換）
        blockHitY = nil,
        pushBanS = 0,       -- 推撞發生位置（ban 虛擬點的縱向錨）
        dodgeNeed = 1.3,    -- 承諾剖面的世界掃掠淨距基準（守護輪沿用提案檔位）
        pushX = 0, pushY = 0, -- 推撞計時起點的車體世界座標（預建鍵免熱路徑 rehash）
        sandBias = laneBias, -- 沙盒靠右偏置（start 時夾限完的值；路面校正的基底）
        roadBias = 0,       -- 路面對中校正量（EMA；行駛線＝sandBias + roadBias）
        vehicleProfile = nil, -- Phase 1 diagnostic cache；與 follower 的 s.profile 分名，控制不讀
        diag = false,       -- telemetry session 是否啟動（熱路徑 boolean）
        -- 遙測用純觀測欄位（控制端不讀）：planMode＝最近一次 replan 離場分類；
        -- init＝尚未完成分類，其他值為 guard／guard-blocked／corner-latched／
        -- offroad-suppress／clear／clear-hold／dodge／blocked。lastCoupled＝這一幀
        -- applySteering 是否真的走耦力調頭（每幀先重設 false）。
        planMode = "init",
        lastCoupled = false,
    }
    do
        -- 高速檔：沙盒上限 > 85 → 掃描帶拉長（120 km/h 的煞停＋反應 ~77m < 110）
        local sNew = sessions[playerNum]
        if sNew.sensor then
            sNew.sensor.aheadM = maxSpeed > PERCEPTION_CAP_KMH and HISPEED_AHEAD_M or 48
        end
    end
    sessionCount = sessionCount + 1
    refreshPolicies(sessions[playerNum], vehicle, playerNum)
    reportAutoUsage(playerObj, vehicle, true,
        sessions[playerNum].usageArgs, sessions[playerNum].navUsageArgs)
    do
        local sNew = sessions[playerNum]
        local vehicleProfile = nil
        if type(MDADVehicleProfile) == "table" and type(MDADVehicleProfile.build) == "function" then
            local pok, built = pcall(MDADVehicleProfile.build, vehicle)
            if pok and type(built) == "table" then vehicleProfile = built end
        end
        sNew.vehicleProfile = vehicleProfile
        if diagEnabled() then
            local dok, active = pcall(MDADDiagnostics.start, playerNum, vehicle, vehicleProfile)
            sNew.diag = dok and active == true
            if not dok then pcall(MDADDiagnostics.stop, playerNum, "error") end
            if sNew.diag then pcall(MDADDiagnostics.event, playerNum, "start") end
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

-- 把 follower 的 steer 翻成一次 addImpulse，回傳實際施出去的力（死區＝0，給遙測用）。
-- fwd 進來時已經是取好的池向量（同時是 forward 的容器與等一下的 relPos 容器），
-- 本函式不 release——由呼叫端統一收尾。
--
-- coupled（調頭模式，呼叫端在 |誤差| > 90° 時給 true）：衝量與施力主臂**同步**乘上
-- 幀奇偶——分量展開後 q² 相消，偏航力矩恆定同向，但側向中心力逐幀反向抵消＝
-- 原地旋轉不橫滑。橫推模式（跟線）的恆定側推在調頭時是災難：0 km/h 飽和側推
-- 24.7k 衝量把整台車推橫滑 24 km/h、滑出路外撞東西（2026-08-28 實機 telemetry）。
-- 跟線的小誤差修正仍用橫推：持續側推正是 PZ 輪胎模型下唯一夠力的過彎來源。
local function applySteering(s, vehicle, fwd, fx, fy, steer, speedKmh, mult, coupled)
    -- follower 的 steer 已飽和在 ±5；防呆再夾一次，死區直接用原值（±0.1）
    if steer > 5 then steer = 5 end
    if steer < -5 then steer = -5 end
    if steer < STEER_DEADZONE and steer > -STEER_DEADZONE then return 0 end

    local px, py = -fy, fx -- 前向逆時針轉 90°（CCW 側向）
    -- 量級採計速度：取 |speedKmh| 並封頂，倒車（速度為負）與超速都不會發散
    local av = speedKmh
    if av < 0 then av = -av end
    if av > SPEED_CAP_KMH then av = SPEED_CAP_KMH end
    -- getMass 負值當 1（BaseVehicle.java:8963-8970）；再夾一次免除零／負值進乘法
    local mass = vehicle:getMass()
    if mass < 1 then mass = 1 end
    -- force 帶號：|steer| 進量級、sign(steer)*STEER_SIGN 進方向，合起來就是
    -- steer * STEER_SIGN * base（不必真的拆開算）
    local force = steer * STEER_SIGN * STEER_STRENGTH
        * (MASS_K * mass * av * av + MASS_BASE * mass) * IMPULSE_SCALE * (mult / MULT_NORM)

    local parity = s.parity
    s.parity = -parity

    local impulse = BaseVehicle.allocVector3f()
    if coupled then
        -- 調頭：impulse 與主臂同乘 parity（torque = relZ*impX - relX*impZ 的展開
        -- 只剩 q²＝1 的項 → 力矩恆定；中心力 q*F*p 幀間抵消）。jitter 項固定不翻，
        -- 它對力矩的貢獻本來就是零（與 impulse 平行）。力量另乘 ROTATE_FORCE_SCALE：
        -- 跟線量級是為對抗高速自回正標定的，原地調頭用全額＝快速旋轉。
        local rf = force * ROTATE_FORCE_SCALE
        -- 純觀測：這一幀真的走了耦力（呼叫端的 coupled 可能被車周探測否決成
        -- 橫推，遙測要記「實際施力模式」而不是「原本想用哪種」）
        s.lastCoupled = true
        force = rf -- 遙測回傳實際施出去的力
        impulse:set(parity * rf * px, 0, parity * rf * py)
        fwd:set(parity * (-REAR_ARM) * fx + LATERAL_JITTER * px, 0,
            parity * (-REAR_ARM) * fy + LATERAL_JITTER * py)
    else
        impulse:set(force * px, 0, force * py)
        fwd:set(-REAR_ARM * fx + parity * LATERAL_JITTER * px, 0,
            -REAR_ARM * fy + parity * LATERAL_JITTER * py)
    end
    vehicle:addImpulse(impulse, fwd)
    BaseVehicle.releaseVector3f(impulse)
    return force
end

-- 速度指令：regulator 只會「不再供油」，下坡或超速時它不會煞車，因此超出目標太多時
-- 改用 setForceBrake（寫 clientControls.forceBrake，效期 1 秒＝CarController.java:973-979；
-- 原版停車用例 ISStopVehicle.lua:15）。回傳這一幀 regulator 是開還是關（遙測用）。
local function applySpeed(s, vehicle, targetSpeed, speedKmh)
    if type(targetSpeed) ~= "number" or targetSpeed < 0 then targetSpeed = 0 end
    if targetSpeed > s.maxSpeed then targetSpeed = s.maxSpeed end
    if speedKmh - targetSpeed > OVERSPEED_BRAKE then
        vehicle:setRegulator(false)
        vehicle:setForceBrake()
        return false
    end
    -- 原版儀表直接 `getRegulatorSpeed() .. ""`（ISVehicleDashboard.lua:405-408），
    -- 不做格式化；把物理 target 原值送入會露出十多位小數。煞車判定已在上方用
    -- 精確 target 完成，寫進 regulator 時才四捨五入成整數 km/h（誤差 <=0.5）。
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
    local minMargin = 9 -- 成功時第二回傳：a..c 對點雲的最小餘裕（寬度→速度縮放）
    local hx, hy, hr = sen.hardX, sen.hardY, sen.hardR
    local bias = laneBiasOf(s)
    -- 掃掠起點提前到車位：過渡段後移（出彎後才側移）時，折點前的 bias
    -- 直行段也是車要走的路，必須一併驗證（t 負值 clamp 回 0＝bias 線）
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
        local wx = px + nx * lane
        local wy = py + ny * lane
        local inCap = sPos >= a and sPos <= c
        for i = 1, hn do
            local ox = hx[i]
            if ox then
                local dx = ox - wx
                local dy = hy[i] - wy
                -- 逐點淨距＝車半寬 0.9＋該點半徑＋餘裕 0.4（樹幹 1.3、整格物 2.0）
                local r = hr and hr[i]
                if type(r) ~= "number" or r ~= r or r < 0 then r = 0.7 end
                local clr = (needBase or SWEEP_BASE) + r
                -- a 之前＝路線本身（bias 直行段）：不是我們選的線、車本來就要
                -- 走，只驗物理必撞（車半寬 0.9＋0.05），不套規劃餘裕——路緣
                -- 籬笆貼彎的常態淨距 1.3m 在原生導航就是照走的
                if sPos < a then clr = 0.95 + r end
                local d2 = dx * dx + dy * dy
                if d2 < clr * clr then
                    local dist = sqrt(d2)
                    -- 失敗相位：baseline（a 前路線段）/entry（過渡）/hold（保持）
                    -- /exit（收回）——BLOCKED_CORNER 分類的核心輸入（codex 裁決：
                    -- hold 敗才是「lane 不可行」，entry/exit 近折點敗＝軌跡拓撲
                    -- 不受支援，換 lane 不會有新資訊）
                    local phase
                    if sPos < a then phase = 1      -- baseline
                    elseif sPos < b then phase = 2  -- entry
                    elseif sPos <= c then phase = 3 -- hold
                    else phase = 4 end              -- exit
                    if getDebug() then
                        -- at=掃掠線點世界座標、hw=命中點世界座標：弧表示（hs/hl）
                        -- 與世界表示脫鉤（斜路取樣混疊嫌疑）的一錘定音欄位
                        print(string.format(
                            "%ssweep fail[%s] p%d offL=%.2f @s=%.1f lane=%.2f at=(%.1f,%.1f) hit#%d hs=%.1f hl=%.2f hw=(%.1f,%.1f) dist=%.2f need=%.2f",
                            LOG, tostring(tag or "?"), phase,
                            offL, sPos, lane, wx, wy, i,
                            (sen.hardS and sen.hardS[i]) or -1,
                            (sen.hardL and sen.hardL[i]) or 99,
                            ox, hy[i] or 0,
                            dist, clr))
                    end
                    -- 回傳：margin、命中弧長（煞停錨）、失敗相位、掃掠位置、
                    -- 命中世界座標（detour 避讓圈直接用世界座標——hardS 在折點
                    -- 區與世界差 3-6m，經 posAt 轉回會錨錯）
                    return false, clr - dist, (sen.hardS and sen.hardS[i]) or sPos,
                        phase, sPos, ox, hy[i] or 0
                end
                -- 速度 margin 只量真正吃動態 cap 的 entry＋hold（a..c）。
                -- baseline 用不同物理門檻、exit 本來固定回 24，混進來單位不一致。
                if inCap then
                    local probe = clr + minMargin
                    if d2 < probe * probe then
                        local mg = sqrt(d2) - clr
                        if mg < minMargin then minMargin = mg end
                    end
                end
            end
        end
        sPos = sPos + SWEEP_STEP
    end
    return true, minMargin
end

-- M6 世界折線掃掠：驗的是 buildOffsetLine 烘好的**同一條**前視線（折點法向
-- 混合、連續）——「驗的線＝走的線」是 M6 軌跡契約的核心（舊 sweepClear 沿
-- 「逐段法向×offL」重算，折點處與實走軌跡分歧 3m 級）。回傳同 sweepClear。
local function sweepLine(s, lx, ly, ln, lS0, a, b, c, d, offL, tag, needBase)
    local sen = s.sensor
    local hn = sen.hardN
    if hn == 0 or ln < 2 then return true, 9 end
    local hx, hy, hr = sen.hardX, sen.hardY, sen.hardR
    local minMargin = 9
    for k = 1, ln do
        local sk = lS0 + (k - 1) * 1.0
        local wx = lx[k]
        local wy = ly[k]
        local inCap = sk >= a and sk <= c
        for i = 1, hn do
            local ox = hx[i]
            if ox then
                local dxx = ox - wx
                local dyy = hy[i] - wy
                local r = hr and hr[i]
                if type(r) ~= "number" or r ~= r or r < 0 then r = 0.7 end
                local clr = (needBase or SWEEP_BASE) + r
                if sk < a then clr = 0.95 + r end -- 路線本身段：物理下限
                local d2 = dxx * dxx + dyy * dyy
                if d2 < clr * clr then
                    local dist = sqrt(d2)
                    local phase
                    if sk < a then phase = 1
                    elseif sk < b then phase = 2
                    elseif sk <= c then phase = 3
                    else phase = 4 end
                    if getDebug() then
                        print(string.format(
                            "%ssweep fail[%s] p%d offL=%.2f @s=%.1f at=(%.1f,%.1f) hit#%d hs=%.1f hl=%.2f hw=(%.1f,%.1f) dist=%.2f need=%.2f",
                            LOG, tostring(tag or "?"), phase,
                            offL, sk, wx, wy, i,
                            (sen.hardS and sen.hardS[i]) or -1,
                            (sen.hardL and sen.hardL[i]) or 99,
                            ox, hy[i] or 0,
                            dist, clr))
                    end
                    return false, clr - dist, (sen.hardS and sen.hardS[i]) or sk,
                        phase, sk, ox, hy[i] or 0
                end
                if inCap then
                    local probe = clr + minMargin
                    if d2 < probe * probe then
                        local mg = sqrt(d2) - clr
                        if mg < minMargin then minMargin = mg end
                    end
                end
            end
        end
    end
    return true, minMargin
end

-- 過渡段提早完成（理由見 CURVE_LEAD 常數註解）：剖面 a..d 內有折點且過渡
-- 完成點 b 離折點不足 CURVE_LEAD 時，把 a/b 前移——側移在進彎前的直段做完、
-- 彎中保持段全程蓋住折點，掃掠線不再切角掃到彎外側障礙。只早不晚（更保守）；
-- a 不得早於車前 1m、b 不得晚於折點也不得超過 c。擠不下就沿用原剖面。
-- 剖面塑形：進入段（a..b）與收回段（c..d）都不得跨路線折點——offL 在折點
-- 兩側指向不同世界方向，跨折點的過渡線必然斜切彎角障礙（2026-08-29 回程皮卡
-- 兩役：進入段半途 lane 打槍→後移策略；收回段半途 lane 打槍→延後收回）。
local function shapeProfile(s, profile, a, b, c, d)
    local sTurn = turnPeakS(profile, a, d + 6)
    if not sTurn then return a, b, c, d end
    local minA = s.lastSNow + 1
    -- 進入段：折點前完成（前移）或折點後才開始（後移壓縮 3m）
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
    -- 收回段：折點落在 [c-2, d+4] → 延後收回（保持側偏過完彎、出彎再回線；
    -- 剖面變長只是多繞幾公尺，比斜切彎角安全）
    if sTurn > c - 2 and d < sTurn + 4 and sTurn >= b then
        local span2 = d - c
        if span2 > 4 then span2 = 4 end
        c = sTurn + 1
        d = c + span2
    end
    return a, b, c, d
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
            s.dodging = false
            s.dodgeNotified = false
            s.dodgeCrawl = false
            s.dodgeTight = false
            s.dodgeNeed = 1.3
        else
            local guardOk
            if MDAD.sandbox("ObstaclePolicy", POLICY_DODGE) ~= POLICY_DODGE then
                guardOk = false
            elseif (fs.ovN or 0) >= 2 then
                -- M6：守護驗的是 commit 時烘好的同一條世界折線
                guardOk = sweepLine(s, fs.ovX, fs.ovY, fs.ovN, fs.ovS0,
                    fs.offA, fs.offB, fs.offC, fs.offD, curOffL, "guard", s.dodgeNeed)
            else
                guardOk = sweepClear(s, s.profile, fs.offA, fs.offB, fs.offC, fs.offD,
                    curOffL, "guard", s.dodgeNeed)
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
    if sen.hardN == 0 then
        mode = "clear"
    elseif type(MDADCorridor) ~= "table" or type(MDADCorridor.plan) ~= "function" then
        -- 檔案樹缺 Corridor（require 沒帶到）：算不了縫隙，保守停車
        mode = "blocked"
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
            sen.hardS, sen.hardL, planN, NEED_HALF, MDADSensor.CORRIDOR_HALF,
            prefer, sen.hardR, baseL, sen.roadLo, sen.roadHi, s.pushBanL == nil)
        s.dodgeTight = false
        s.dodgeCrawl = false
        local needUsed = NEED_HALF
        -- 彎道繞行：障礙群（b..c＝含保持餘裕的實體範圍）落在彎道段時，用放大的
        -- 需求半寬重算——內輪差與切內彎吃掉的餘裕先扣掉再判縫隙。判得過＝採
        -- 加嚴縫（位置更保守）；判不過＝**沿用普通縫降級爬行**，不直接 blocked
        -- ——內輪差的一階補償在爬行速度下大幅縮小，真擦撞由 sweepClear 世界
        -- 空間複驗把關（2026-08-28 實機：彎道兩台並排車，普通縫過得去卻被
        -- 加嚴判死 → blocked → 煞停 → 卡死脫困鬼打牆；使用者定案：有障礙時
        -- 允許離開道路繞行）。兩種 case 都壓爬行（dodgeTight）。
        if mode == "dodge" and routeTurnWithin(s.profile, a, d) > CURVE_TIGHT_RAD then
            local m2, a2, b2, c2, d2, o2 = MDADCorridor.plan(
                sen.hardS, sen.hardL, planN, NEED_HALF + CURVE_NEED_EXTRA,
                MDADSensor.CORRIDOR_HALF, prefer, sen.hardR, baseL,
                sen.roadLo, sen.roadHi, s.pushBanL == nil)
            s.dodgeTight = true
            if m2 == "dodge" then
                mode, a, b, c, d, offL = m2, a2, b2, c2, d2, o2
                needUsed = NEED_HALF + CURVE_NEED_EXTRA
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
            a, b, c, d = shapeProfile(s, s.profile, a, b, c, d)
            -- M6：先烘世界折線（含車位→a 的路線段），掃掠與 commit 用同一條
            local ovN, ovS0 = MDADFollower.buildOffsetLine(s.profile,
                s.lastSNow, a, b, c, d, offL, baseL, s.tmpOvX, s.tmpOvY)
            local okS, mgS, hitS, phS, hpsS, hxS, hyS
            if ovN >= 2 then
                okS, mgS, hitS, phS, hpsS, hxS, hyS = sweepLine(s,
                    s.tmpOvX, s.tmpOvY, ovN, ovS0, a, b, c, d, offL, "plan", needBase)
            else
                okS, mgS, hitS, phS, hpsS, hxS, hyS =
                    sweepClear(s, s.profile, a, b, c, d, offL, "plan", needBase)
            end
            if okS then
                commitNb = needBase
                s.dodgeMargin = mgS
                s.lastOvN = ovN
                s.lastOvS0 = ovS0
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
                            nu = SQUEEZE_NEED
                            nb = SQUEEZE_NEED - 0.1
                            local mq, aq, bq, cq, dq, oq = MDADCorridor.plan(
                                sen.hardS, sen.hardL, planN, nu, MDADSensor.CORRIDOR_HALF,
                                prefer, sen.hardR, baseL, sen.roadLo, sen.roadHi, false)
                            if mq ~= "dodge" then break end
                            pa, pb, pc, pd, po = aq, bq, cq, dq, oq
                            pa, pb, pc, pd = shapeProfile(s, s.profile, pa, pb, pc, pd)
                            ovN, ovS0 = MDADFollower.buildOffsetLine(s.profile,
                                s.lastSNow, pa, pb, pc, pd, po, baseL, s.tmpOvX, s.tmpOvY)
                            local okQ, mgQ, hQ, phQ, hpsQ, hxQ, hyQ
                            if ovN >= 2 then
                                okQ, mgQ, hQ, phQ, hpsQ, hxQ, hyQ = sweepLine(s,
                                    s.tmpOvX, s.tmpOvY, ovN, ovS0, pa, pb, pc, pd, po, "crawl", nb)
                            else
                                okQ, mgQ, hQ, phQ, hpsQ, hxQ, hyQ =
                                    sweepClear(s, s.profile, pa, pb, pc, pd, po, "crawl", nb)
                            end
                            if okQ then
                                a, b, c, d, offL = pa, pb, pc, pd, po
                                committed = true
                                commitNb = nb
                                s.dodgeMargin = mgQ
                                s.dodgeCrawl = true
                                s.lastOvN = ovN
                                s.lastOvS0 = ovS0
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
                            pa, pb, pc, pd = shapeProfile(s, s.profile, pa, pb, pc, pd)
                            ovN, ovS0 = MDADFollower.buildOffsetLine(s.profile,
                                s.lastSNow, pa, pb, pc, pd, po, baseL, s.tmpOvX, s.tmpOvY)
                            local okK, mgK, hK, phK, hpsK, hxK, hyK
                            if ovN >= 2 then
                                okK, mgK, hK, phK, hpsK, hxK, hyK = sweepLine(s,
                                    s.tmpOvX, s.tmpOvY, ovN, ovS0, pa, pb, pc, pd, po,
                                    phase == 2 and "crawl" or "retry", nb)
                            else
                                okK, mgK, hK, phK, hpsK, hxK, hyK =
                                    sweepClear(s, s.profile, pa, pb, pc, pd, po,
                                        phase == 2 and "crawl" or "retry", nb)
                            end
                            if okK then
                                a, b, c, d, offL = pa, pb, pc, pd, po
                                committed = true
                                commitNb = nb
                                s.dodgeMargin = mgK
                                if phase == 2 then s.dodgeCrawl = true end
                                s.lastOvN = ovN
                                s.lastOvS0 = ovS0
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
        -- 偏離道路中（使用者定案：優先回線）：不疊繞行側偏——車在走廊外時
        -- 弧座標表示失真、掃描窗隨投影漂移，dodge 在這種輸入下只會左右震盪。
        -- **不降級 blocked**：blocked 的煞停錨會把車按死在路外（2026-08-28
        -- 實機：offroad→blocked→target=0 停死→卡死→倒車→離線更遠→紅字放棄
        -- 的死循環）。正辦＝清側偏、放掉繞行/堵住旗標，讓跟線以 OFFROAD_CAP
        -- 15 朝前視點爬回線（天然最近路徑）；回線途中頂到障礙由卡死→脫困兜底。
        if mode == "dodge" and s.offroad then
            MDADFollower.clearOffset(s.fstate)
            s.dodging = false
            s.blocked = false
            s.blockedNotified = false
            s.dodgeNotified = false
            s.dodgeCrawl = false
            s.dodgeNeed = 1.3
            s.clearStreak = 0
            if getDebug() then
                print(LOG .. "pn=" .. playerNum .. " offroad: dodge suppressed, return to route first")
            end
            s.planMode = "offroad-suppress"
            return
        end
    end
    if mode == "dodge" then
        -- setOffset 引數不合法回 false（不動 state）：此時寧可當 blocked 煞停，
        s.clearStreak = 0
        -- 也不能無側偏直直開進障礙
        if MDADFollower.setOffset(s.fstate, a, b, c, d, offL,
                s.tmpOvX, s.tmpOvY, s.lastOvN or 0, s.lastOvS0 or 0) then
            s.dodging = true
            s.blocked = false
            s.blockedNotified = false
            s.dodgeNeed = commitNb or SWEEP_BASE -- 承諾檔淨距（守護輪同契約）
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
        s.pushBanL = nil -- 走廊淨空＝episode 結束，物理 ban 一併解除
        s.cornerLatch = false
        s.blockHitX = nil
        s.planMode = "clear"
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
    -- 成功：退離卡點 3 公尺 → 回跟線，重掃重規劃
    local dx = vehicle:getX() - s.unstickX
    local dy = vehicle:getY() - s.unstickY
    if dx * dx + dy * dy >= UNSTICK_DIST_SQ then
        s.mode = "follow"
        s.stuckSince = 0
        -- 只清控制歷史（PID／調頭／側偏），**保留投影游標 idx**：路線沒換，
        -- 歸零 idx 會讓投影窗口從路線起點慢慢爬回來、車朝起點打滿方向
        -- （M4 review 兩條 lane 同時抓到的 blocker）。小幅倒退交給 REWIND_MAX。
        if type(MDADFollower.resetControl) == "function" then
            MDADFollower.resetControl(s.fstate)
        end
        s.dodging = false
        s.dodgeNotified = false
        s.blocked = false
        s.blockedNotified = false
        s.planSig = 0
        s.clearStreak = 0
        if s.sensor then MDADSensor.reset(s.sensor) end -- nextMs 歸零＝立即重掃
        if getDebug() then print(LOG .. "unstick pn=" .. playerNum .. " ok") end
        return
    end
    -- 失敗：時限內沒退出去（後方也頂死）→ 紅字停車
    if now >= s.unstickUntil then
        Drive.stop(playerNum, KEY_STUCK)
        return
    end
    vehicle:setRegulator(false)
    local mult = getGameTime():getMultiplier()
    if mult < MULT_MIN then mult = MULT_MIN end
    if mult > MULT_MAX then mult = MULT_MAX end
    -- getMass 負值當 1（BaseVehicle.java:8963-8970）
    local mass = vehicle:getMass()
    if mass < 1 then mass = 1 end
    local fwd = BaseVehicle.allocVector3f()
    vehicle:getForwardVector(fwd) -- basis 第 2 欄＝BaseVehicle.java:4242-4244
    local fx, fy = fwd:x(), fwd:z()
    local flen2 = fx * fx + fy * fy
    if flen2 > 1e-6 then
        local inv = 1 / sqrt(flen2)
        fx, fy = fx * inv, fy * inv
        local force = UNSTICK_PUSH * MASS_BASE * mass * IMPULSE_SCALE * (mult / MULT_NORM)
        local impulse = BaseVehicle.allocVector3f()
        impulse:set(-force * fx, 0, -force * fy)
        fwd:set(0, 0, 0)
        vehicle:addImpulse(impulse, fwd)
        BaseVehicle.releaseVector3f(impulse)
    end
    BaseVehicle.releaseVector3f(fwd)
    if getDebug() and now >= s.nextDebugMs then
        s.nextDebugMs = now + DEBUG_MS
        print(string.format("%spn=%d mode=unstick speed=%.1f n=%d",
            LOG, playerNum, vehicle:getCurrentSpeedKmHour(), s.unstickCount))
    end
end

local function stepFollow(s, vehicle, playerNum, now)
    local speedKmh = vehicle:getCurrentSpeedKmHour() -- 可負（倒車）＝BaseVehicle.java:4268
    local vx, vy = vehicle:getX(), vehicle:getY()
    local mult = getGameTime():getMultiplier()
    if mult < MULT_MIN then mult = MULT_MIN end
    if mult > MULT_MAX then mult = MULT_MAX end
    -- 每幀先歸零，applySteering 真的走耦力時才寫 true（純觀測；一個 boolean 寫入）
    s.lastCoupled = false

    -- 池向量：一顆當 forward／relPos 共用，一顆在 applySteering 內當 impulse。
    -- 這段中間沒有 early return，release 一定會執行。
    local fwd = BaseVehicle.allocVector3f()
    vehicle:getForwardVector(fwd) -- basis 第 2 欄＝BaseVehicle.java:4242-4244
    -- Bullet 的 y 是上方向：世界 (X,Y) 對應 (x,z)（CarController.java:406,416 同讀法）
    local fx, fy = fwd:x(), fwd:z()
    local flen2 = fx * fx + fy * fy
    local reached = false
    local stuck = false
    if flen2 > 1e-6 then
        local inv = 1 / sqrt(flen2)
        fx, fy = fx * inv, fy * inv
        -- control 回 steer, targetSpeed, remaining, reached, headingError, lateralSq
        local heading = MDADFollower.headingFromForward(fx, fy)
        local steer, targetSpeed, remaining, done, headingError, lateralSq, latSigned = MDADFollower.control(
            s.profile, s.fstate, vx, vy,
            heading, speedKmh, mult * SECONDS_PER_MULT)
        reached = done == true
        -- 目前沿線弧長：M4 感知與脫困額度重臂共用（sensor 缺席時脫困仍要用，
        -- 所以重臂判定放在 sensor 塊之外）
        s.lastSNow = s.profile.length - (remaining or 0)
        -- 沿線前進夠遠＝上次脫困真的有用，重臂脫困額度
        if s.unstickCount > 0 and s.lastSNow - s.unstickS > UNSTICK_PROGRESS then
            s.unstickCount = 0
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
                    if rc > ROAD_CLAMP then rc = ROAD_CLAMP
                    elseif rc < -ROAD_CLAMP then rc = -ROAD_CLAMP end
                    s.roadBias = s.roadBias + (rc - s.roadBias) * ROAD_EMA
                else
                    s.roadBias = s.roadBias * ROAD_DECAY
                end
                local nb = s.sandBias + s.roadBias
                if nb > BIAS_MAX then nb = BIAS_MAX
                elseif nb < -BIAS_MAX then nb = -BIAS_MAX end
                -- 承諾期凍結（oracle R7）：dodge 執行中 bias 不再更新——EMA 微調
                -- 會讓 hard 點 l 座標逐輪漂移（實測 hl 3.02↔3.12）、guard 與
                -- 枚舉的邊界判定跟著抖。承諾釋放後恢復跟隨。
                if s.dodging then nb = laneBiasOf(s) end
                if type(MDADFollower.setLaneBias) == "function" then
                    MDADFollower.setLaneBias(s.fstate, nb)
                end
                s.sensor.scanBias = nb -- 掃描帶跟隨行駛線（下一輪 beginRound 鎖定）
                if s.sensor.sig ~= s.planSig or s.clearStreak > 0 then
                    s.planSig = s.sensor.sig
                    replan(s, vehicle, playerNum)
                end
                -- 一般玩家軌跡每輪更新常駐點列；debugOn 只控制紅／綠／橙 markers。
                -- LineDrawer 每 tick 畫連續線，幾何仍只在 250ms 輪完成時重算。
                if type(MDADOverlay) == "table" then
                    MDADOverlay.update(playerNum, s, vehicle, cell, s.overlayOn)
                end
            end
            -- 速度檔位：全部是疊在剖面上的 min，cap<0＝本幀沒有任何檔位介入
            local cap = -1
            if not s.sensor.ready then
                -- 首輪掃描還沒完成（剛啟動／換路線／脫困後重掃）＝「不知道前面有
                -- 什麼」，與未載入同級保守：不加這條會在盲區全速衝 ~150ms，
                -- 剛脫困退開的 3 公尺一半就被吃回去（M4 review blocker）
                cap = UNLOADED_CAP
            end
            if s.dodging then
                -- 每幀釋放檢查（2026-08-29 圖 4 實測 bug）：replan 是「障礙簽章
                -- 變化」事件驅動——通過障礙後路面乾淨、sig 不再變、replan 裡的
                -- 釋放分支永遠沒人跑，爬行 cap 在開闊直路掛死。釋放屬於運動
                -- 進度事件，跟感知簽章無關，必須每幀查（一次數值比較，零成本）。
                local fsD = s.fstate.offD
                if type(fsD) ~= "number" or s.lastSNow >= fsD then
                    MDADFollower.clearOffset(s.fstate)
                    s.dodging = false
                    s.dodgeNotified = false
                    s.dodgeCrawl = false
                    s.dodgeTight = false
                    s.dodgeNeed = 1.3
                    if getDebug() then
                        print(LOG .. "pn=" .. playerNum .. " dodge released (profile done)")
                    end
                else
                    -- 分段限速：c..d 收回段已駛過障礙本體，回 DODGE_CAP 24。
                    -- a..c 依 commit 時 sweep 的 entry＋hold 最小餘裕連續縮放：
                    -- entry 的 margin 0 → 10 km/h、0.8+ → 24；hold 再加 6，
                    -- 上限 28。彎道 entry 上限 16、hold 20。baseline／exit
                    -- 仍完整做碰撞驗證，但不拿不同相位的餘裕污染 a..c 速度。
                    local dcap
                    local fsC = s.fstate.offC
                    local fsA2 = s.fstate.offA
                    local fsB2 = s.fstate.offB
                    -- 減速界隨速縮放：40 km/h 的煞停距 ~8m＋掃描/反應延遲，
                    -- 固定 12m 對瘋狂檔不夠（2026-08-29 實測高速輕擦後由推撞
                    -- ban 倒退解除——防線有效但不該走到那）
                    local slowZone = speedKmh * 0.5
                    if slowZone < 12 then slowZone = 12 end
                    if type(fsA2) == "number" and s.lastSNow < fsA2 - slowZone then
                        dcap = nil -- 剖面還在減速界外：接近段照常速
                    elseif type(fsC) == "number" and s.lastSNow >= fsC then
                        dcap = DODGE_CAP
                    else
                        local mg = s.dodgeMargin
                        if type(mg) ~= "number" then mg = 0 end
                        dcap = 10 + mg * 17.5 -- margin 0→10、0.8→24 全額
                        if type(fsB2) == "number" and s.lastSNow >= fsB2 then
                            -- 保持段（b..c）：轉向已完成、直線貼障礙行駛——比
                            -- 轉向中的過渡段快一檔（2026-08-29 使用者裁定）
                            dcap = dcap + 6
                            if dcap > 28 then dcap = 28 end
                        elseif dcap > DODGE_CAP then
                            dcap = DODGE_CAP
                        end
                        if s.dodgeTight then
                            local tcap = DODGE_TIGHT_CAP
                            if type(fsB2) == "number" and s.lastSNow >= fsB2 then
                                tcap = DODGE_TIGHT_CAP + 4 -- 彎中保持段同步放一檔
                            end
                            if dcap > tcap then dcap = tcap end
                        end
                    end
                    -- squeeze 檔只比車體多 0.3m；無論 entry/hold/exit 都維持平坦爬行上限。
                    if dcap ~= nil and s.dodgeCrawl and dcap > SQUEEZE_CAP then
                        dcap = SQUEEZE_CAP
                    end
                    if dcap ~= nil and (cap < 0 or dcap < cap) then cap = dcap end
                end
            end
            -- 殭屍／屍體減速：三態政策×玩家偏好已在 refreshPolicies 合成快取，
            -- 每幀只讀 boolean（250ms 刷新；切檔／切偏好即時重算）
            local zn = s.sensor.zombieN
            if zn and zn > 0 and s.zombieSlow then
                local zcap = ZOMBIE_CAP_1
                if zn >= 8 then zcap = ZOMBIE_CAP_8
                elseif zn >= 4 then zcap = ZOMBIE_CAP_4 end
                if cap < 0 or zcap < cap then cap = zcap end
            end
            local cn = s.sensor.corpseN
            if cn and cn > 0 and s.corpseSlow
                    and (cap < 0 or CORPSE_CAP < cap) then
                cap = CORPSE_CAP
            end
            -- 跟車分級（不能只 cap 15 一路跟到撞）：MP 半更新狀態的靜止車會被
            -- isStopped 誤判成「行進中」不進硬障礙（2026-08-28 實機：黑車不在
            -- 快照硬點裡、17 km/h 直接追尾）——按最近前車的弧長距離分級：
            -- <10m 目標 0（煞停等待）、<20m 爬行 8、更遠照 MOVING_VEH_CAP。
            s.followHold = false
            if s.sensor.movingVeh then
                local mcap = MOVING_VEH_CAP
                local va = s.sensor.vehAheadS
                if va ~= nil then
                    local gap = va - s.lastSNow
                    if gap < 10 then
                        mcap = 0
                        s.followHold = true -- 合法停等（卡死豁免＋獨立超時）
                    elseif gap < 20 then mcap = 8 end
                end
                if cap < 0 or mcap < cap then cap = mcap end
            end
            if s.sensor.unloaded then
                -- 動態煞停距（2026-08-29 使用者裁定）：未載入格在煞停距外＝
                -- 不減速（接近時 chunk 自然載入）；高速檔帶 110m 的帶尾恆超出
                -- streaming 半徑，一律壓 15 等於永遠 15。距內按「能在該距離
                -- 停住的速度」漸進壓（下限 UNLOADED_CAP）。
                local ugap = (s.sensor.unloadedS or 0) - s.lastSNow
                local safe = speedKmh * speedKmh / 166 + speedKmh * 0.19 + 6
                if ugap < safe then
                    local ucap = UNLOADED_CAP
                    local room = ugap - 6
                    if room > 0 then
                        local vsafe = sqrt(room * 166)
                        if vsafe > ucap then ucap = vsafe end
                    end
                    if cap < 0 or ucap < cap then cap = ucap end
                end
            end
            -- 軟障礙（可推家具／HitByCar 雜物）：輾得過但要先減速——不減速輾過的
            -- 體感就是「撞到東西」（2026-08-28 實機路口擦撞回報的嫌疑之一）
            local sn = s.sensor.softN
            if sn and sn > 0 and (cap < 0 or SOFT_CAP < cap) then cap = SOFT_CAP end
            if cap >= 0 and targetSpeed > cap then targetSpeed = cap end
        end

        -- 速度檔位 cap：刻意放在 sensor 塊**之外**——感知模組缺席（檔案樹壞、
        -- 退回 M3 純跟線）時檔位照樣生效（codex M5.5 對抗審 BLOCKING）。
        -- 只往下壓：瘋狂檔（gearCap＝載具極速）高於剖面上限時由剖面壓住。
        if s.gearCap > 0 and targetSpeed > s.gearCap then targetSpeed = s.gearCap end
        -- 感知閉環上限（理由見 PERCEPTION_CAP_KMH）：標準組態上限 85；
        -- 高速組態同時切到 110m 掃描帶與 120 上限。
        local pcap = s.perceptionCap or PERCEPTION_CAP_KMH
        if targetSpeed > pcap then targetSpeed = pcap end
        -- 感知空窗爬行（2026-08-29 實測）：改導航目標＝route cutover 會作廢
        -- 感知快照（sensor 認 profile identity 重置、stamp 歸零）＋清繞行旗標
        -- ——新路線首輪掃描完成前 plan 看到的「hardN=0」不是淨空而是**還不
        -- 知道**。實測改目標後調頭，車頭正對 4m 外剛才還有紅圈的車加速，
        -- 首輪掃完 blocked 才收到、物理已煞不住。首輪完成前壓爬行（250ms
        -- 節流＋~12 幀，體感 0.3-0.6 秒），事件驅動、不用固定等待計時；
        -- session 起步同理：先看再走。
        if s.sensor and s.sensor.stamp == 0 and targetSpeed > SCAN_WARM_CAP then
            targetSpeed = SCAN_WARM_CAP
        end
        -- 甩出判定（對抗審 BLOCKING R1 修正）：偏離量＝帶號橫偏對**期望橫向
        -- 位置**（laneBias＋側偏剖面 smoothstep）的差——舊判法量「到 nav 中心線
        -- 的距離」，合法的大側偏繞行（走廊擴到 ±7 後 offL 可到 ±5.5）會自己
        -- 觸發 offroad、清剖面、回線、再繞行的鋸齒循環，任何 |offL|>4 的縫
        -- 都執行不完。期望線公式與 follower 前視點/sweepClear 同一段 smoothstep。
        if latSigned then
            local expL = laneBiasOf(s)
            local offL2 = s.fstate.offL
            if s.dodging and offL2 ~= nil and type(offL2) == "number" then
                local oa, ob, oc, od = s.fstate.offA, s.fstate.offB, s.fstate.offC, s.fstate.offD
                local sN = s.lastSNow
                if sN > oa and sN < od then
                    local t
                    if sN < ob then t = (sN - oa) / (ob - oa)
                    elseif sN > oc then t = (od - sN) / (od - oc)
                    else t = 1 end
                    t = t * t * (3 - 2 * t)
                    expL = expL + (offL2 - expL) * t
                end
            end
            local dev = latSigned - expL
            local dev2 = dev * dev
            if s.offroad then
                if dev2 < OFFROAD_EXIT_SQ then s.offroad = false end
            elseif dev2 > OFFROAD_LAT_SQ then
                s.offroad = true
                diagEvent(s, playerNum, "offroad")
                if s.dodging then
                    MDADFollower.clearOffset(s.fstate)
                    s.dodging = false
                    s.dodgeNotified = false
                    s.dodgeCrawl = false
                    s.dodgeTight = false
                    s.dodgeNeed = 1.3
                end
                if getDebug() then
                    print(LOG .. "pn=" .. playerNum .. " offroad: returning to route (dev="
                        .. string.format("%.1f", dev) .. "m)")
                end
            end
        end
        if s.offroad and targetSpeed > OFFROAD_CAP then
            targetSpeed = OFFROAD_CAP
        end
        -- 高速誤差護欄：>70 km/h 的目標速度按航向誤差線性折返回 70——誤差 0 給
        -- 滿速、≥HS_ERR_RAD（10°）壓回 70。轉向與曲率限速都在 ≤70 標定；高速下
        -- 橫向漂移量隨速度平方放大，8-10° 的「小」誤差在 target=100 時就足以
        -- 甩出路面（2026-08-28 實機遙測：35 km/h 加速段 errDeg -8~-10 出界撞樹）。
        -- 沙盒 ≤70 時 targetSpeed 永遠不超 70，本護欄零作用。
        if targetSpeed > HS_BASE_KMH then
            local ae2 = headingError or 0
            if ae2 < 0 then ae2 = -ae2 end
            if ae2 >= HS_ERR_RAD then
                targetSpeed = HS_BASE_KMH
            else
                targetSpeed = HS_BASE_KMH + (targetSpeed - HS_BASE_KMH) * (1 - ae2 / HS_ERR_RAD)
            end
        end

        local regOn = false
        local force = 0
        -- offroad 豁免：blocked 的煞停錨是「沿線障礙群」的座標，車在路外時
        -- 這個錨無意義——按著煞車就是把車停死在草地上（回線優先，見 replan）
        if s.blocked and not reached and not s.offroad
                and s.lastSNow >= s.blockS
                    - (s.cornerLatch and CORNER_STOP_DIST or BLOCK_STOP_DIST) then
            -- 前方無縫隙且已逼近障礙群：主動煞停等待（不是 Drive.stop——session
            -- 活著，掃描持續，障礙消失由 replan 解除；玩家接手走讓位）。停死後
            -- 卡死偵測會接手升級成倒車脫困→紅字停車，整條鏈自然收斂。
            vehicle:setRegulator(false)
            vehicle:setForceBrake()
            targetSpeed = 0
            -- immutable DODGE 的守護驗證失敗會帶著剖面轉 blocked（車在動時清
            -- 剖面＝目標線瞬跳）：近停後才清承諾，之後停等重提案照常
            if s.dodging and speedKmh < 1 and speedKmh > -1 then
                MDADFollower.clearOffset(s.fstate)
                s.dodging = false
                s.dodgeNotified = false
                s.dodgeCrawl = false
                s.dodgeTight = false
                s.dodgeNeed = 1.3
            end
        else
            if s.blocked and not reached and not s.offroad then
                -- blocked 但障礙還在 BLOCK_STOP_DIST 之外：以爬行速度滑行接近，
                -- 不急煞——掃描逼近後的縫隙判定比 30 公尺外那輪準，很多「遠看
                -- 堵死」在近距離會變成可繞（量化誤差隨距離縮小）
                if targetSpeed > BLOCK_APPROACH_KMH then targetSpeed = BLOCK_APPROACH_KMH end
            end
            regOn = applySpeed(s, vehicle, targetSpeed, speedKmh)
            if not reached then
                local aerr = headingError or 0
                if aerr < 0 then aerr = -aerr end
                local av = speedKmh
                if av < 0 then av = -av end
                if aerr > ROTATE_ERR_RAD and av > ROTATE_SPIN_MAX_KMH then
                    -- 調頭需求但還有動量：主動煞停到近停，這幀不施轉向。
                    -- （follower 的調頭爬行 target 12 只會讓 regulator 鬆油，
                    -- 滑行等速太久——期間路線反覆重算會把震盪放大）
                    vehicle:setRegulator(false)
                    vehicle:setForceBrake()
                    regOn = false
                elseif aerr <= ROTATE_ERR_RAD or av <= ROTATE_SPIN_MAX_KMH then
                    -- 誤差 > 90° 走耦力模式（coupled=true）：力矩恆定、側向中心力
                    -- 幀間抵消＝原地旋轉不橫滑（實機：橫推調頭會滑出路外撞東西）。
                    -- **原地旋轉前先探車周**（500ms 節流）：走廊沿路線掃，路線反向
                    -- 要調頭時車後方／側面全是走廊盲區——貼牆貼樹貼車旋轉＝車身
                    -- 掃掠直接撞。周邊不淨空（或未載入）就退回橫推大弧：爬行 12
                    -- 前進轉，空間不夠自然由卡死→脫困鏈接手。
                    local coupled = aerr > ROTATE_ERR_RAD
                    if coupled and s.sensor then
                        if now >= s.rotProbeMs then
                            s.rotProbeMs = now + ROTATE_PROBE_MS
                            s.rotProbeClear = not MDADSensor.probeAround(
                                s.sensor, vehicle, getCell(), ROTATE_PROBE_R)
                            if getDebug() then
                                print(LOG .. "pn=" .. playerNum .. " rotate probe: "
                                    .. (s.rotProbeClear and "clear (coupled spin)"
                                        or "obstructed (wide arc)"))
                            end
                        end
                        if not s.rotProbeClear then coupled = false end
                    end
                    force = applySteering(s, vehicle, fwd, fx, fy, steer or 0,
                        speedKmh, mult, coupled)
                end
            end
        end
        -- 跟線遙測：每秒最多一行。實機要判斷「轉不動」是誤差沒算出來、還是力太小，
        -- 只有同一行同時看到 errDeg 與 force 才分得開。旗標為假時整段完全不執行，
        -- 連字串都不會生成——這裡是每幀熱路徑。
        if getDebug() and now >= s.nextDebugMs then
            s.nextDebugMs = now + DEBUG_MS
            print(string.format(
                "%spn=%d mode=%s speed=%.1f target=%.1f errDeg=%.1f steer=%.2f force=%.0f remaining=%.1f lat=%.1f road=%.2f gear=%d regulator=%s",
                LOG, playerNum, s.mode, speedKmh, targetSpeed or 0,
                (headingError or 0) * DEG_PER_RAD, steer or 0, force, remaining or 0,
                sqrt(lateralSq or 0), s.roadBias, Drive.getGear(playerNum), tostring(regOn)))
        end
        if s.diag then
            -- 全部是**讀既有狀態**：一個欄位都不新算、不改控制。實機碰撞分析要的
            -- 最小證據集（2026-08-31：截圖那一幀只看得到 spd/tgt/lat，判不出
            -- replan 走了哪條離場路徑、有沒有在耦力旋轉、煞停錨在哪）。
            local ok, live = pcall(MDADDiagnostics.sample, playerNum, now,
                vx, vy, heading, speedKmh, targetSpeed or 0, remaining or 0,
                latSigned or 0, headingError or 0, steer or 0, force, s.mode,
                Drive.getGear(playerNum), regOn, s.sensor,
                s.blocked or s.dodging or s.offroad or s.mode == "unstick",
                s.planMode, s.lastSNow, s.blockS, s.dodgeMargin, s.dodgeNeed,
                s.roadBias, s.blockHitX, s.blockHitY, s.fstate.idx,
                s.blocked, s.dodging, s.offroad, s.cornerLatch, s.lastCoupled)
            if not ok or live ~= true then
                s.diag = false
                pcall(MDADDiagnostics.stop, playerNum, not ok and "error" or "stopped")
            end
        end
        -- ---- 卡死偵測 ----
        -- 三個觀測都凍結才累計：|速度| < STUCK_SPEED_KMH、沿線進度變化 < STUCK_REM_EPS、
        -- 航向變化 < STUCK_ERR_EPS。原地調頭時速度近零但航向在動、末段挪車時 remaining
        -- 在動、煞停途中 remaining 也在動，都會不斷重置計時；headingError 在 ±pi 跳變
        -- （調頭穿過正後方）時差值巨大，同樣走重置——誤差方向永遠是「不誤停」。
        local moving = speedKmh > STUCK_SPEED_KMH or speedKmh < -STUCK_SPEED_KMH
        -- 停等豁免（對抗審 BLOCKING）：blocked 煞停與跟車目標 0 是**合法等待**
        -- ——前車臨停、隊友擋路、路口讓行都常超過 5 秒。對等待倒車既危險
        -- （車隊裡倒車）又必然放棄（停等不產生沿線前進，脫困額度永不重臂，
        -- 三次後紅字）。豁免期間卡死計時凍結；等待有自己的超時（紅字請玩家
        -- 接手），不會無限等。
        local waiting = (s.blocked or s.followHold) and not moving
        if waiting then
            s.stuckSince = 0
            if s.waitSince == 0 then
                s.waitSince = now
            elseif now - s.waitSince >= WAIT_TIMEOUT_MS then
                BaseVehicle.releaseVector3f(fwd)
                Drive.stop(playerNum, KEY_STUCK)
                return
            end
        else
            s.waitSince = 0
        end
        if reached or moving or waiting then
            s.stuckSince = 0
        elseif s.stuckSince == 0 then
            s.stuckSince = now
            s.stuckErr = headingError or 0
            s.stuckRem = remaining or 0
        else
            local dErr = (headingError or 0) - s.stuckErr
            if dErr < 0 then dErr = -dErr end
            local dRem = (remaining or 0) - s.stuckRem
            if dRem < 0 then dRem = -dRem end
            if dErr > STUCK_ERR_EPS or dRem > STUCK_REM_EPS then
                s.stuckSince = now
                s.stuckErr = headingError or 0
                s.stuckRem = remaining or 0
            elseif now - s.stuckSince >= STUCK_MS then
                stuck = true
            end
        end
        -- ---- 推撞偵測（理由見 PUSH_* 常數註解）----
        -- 輪速 ≥8 km/h 而車體世界位移連 3m/2.5s 都不到＝頂著看不見的實體
        -- 空推。沿線 s 不可當物理位移：回線／切換路段會橫向移動但 s 暫停。
        -- 只在感知非空時累計；全空的高速零位移交給既有卡死三凍結。
        local sen = s.sensor -- 缺席時是 false 非 nil，用 truthiness 判
        local pushEligible = sen and (sen.hardN > 0 or sen.vehN > 0 or sen.movingVeh)
        if not stuck and pushEligible
                and (speedKmh >= PUSH_MIN_KMH or speedKmh <= -PUSH_MIN_KMH) then
            if s.pushSince == 0 then
                s.pushSince = now
                s.pushX, s.pushY = vx, vy
            else
                local pdx, pdy = vx - s.pushX, vy - s.pushY
                if pdx * pdx + pdy * pdy >= PUSH_FREE_SQ then
                    s.pushSince = now
                    s.pushX, s.pushY = vx, vy
                elseif now - s.pushSince >= PUSH_MS then
                    if s.dodging and s.pushBanL == nil then
                        -- 繞行中第一次推撞＝物理實證此縫不可行（sweep 理論淨空
                        -- 但碰撞箱／跟線誤差／格心量化疊加後實體卡住：2026-08-29
                        -- 實測 offL=-1.50 貼皮卡反覆卡→倒車→同縫再 commit 循環）。
                        -- 先 ban 該縫強制重規劃換縫；倒車留給換縫也解不了的情況。
                        s.pushBanL = s.fstate.offL
                        s.pushBanS = s.lastSNow + 4
                        MDADFollower.clearOffset(s.fstate)
                        s.dodging = false
                        s.dodgeNotified = false
                        s.dodgeCrawl = false
                        s.dodgeTight = false
                        s.dodgeNeed = 1.3
                        s.planSig = 0 -- 障礙布局沒變也要強制重提案
                        s.pushSince = 0
                        if getDebug() then
                            print(string.format(
                                "%spn=%d push mismatch: ban lane %.2f, replanning",
                                LOG, playerNum, s.pushBanL or 0))
                        end
                    else
                        stuck = true
                        if getDebug() then
                            print(LOG .. "pn=" .. playerNum
                                .. " push mismatch: wheels moving, no progress (ghost obstacle?)")
                        end
                    end
                end
            end
        else
            s.pushSince = 0
        end
    end
    BaseVehicle.releaseVector3f(fwd)

    -- 卡死（池向量已歸還才走到這裡）：M3 只會紅字停車；M4 起先試倒車脫困。
    -- Drive.stop 只關 regulator、不硬煞——卡死時車本來就不動。
    if stuck then
        -- 政策允許且額度未用完 → 倒車脫困；否則紅字停車（M3 行為）。
        -- 額度綁「沿線前進」：原地反覆卡→試 UNSTICK_MAX 次就放棄，不無限鬼打牆。
        if MDAD.sandbox("ObstaclePolicy", POLICY_DODGE) == POLICY_DODGE
                and s.unstickCount < UNSTICK_MAX then
            s.unstickCount = s.unstickCount + 1
            s.unstickX, s.unstickY = vx, vy -- 本幀開頭已讀；同一 tick 內車體不動
            s.unstickS = s.lastSNow or 0
            s.unstickUntil = now + UNSTICK_MS
            s.mode = "unstick"
            diagEvent(s, playerNum, "unstick")
            s.pushSince = 0 -- mode 切換作廢推撞窗；不可把觸發前錨點帶回 follow
            s.stuckSince = 0
            vehicle:setRegulator(false)
            local playerObj = getSpecificPlayer(playerNum)
            if playerObj then haloGood(playerObj, KEY_UNSTICK) end
            if getDebug() then
                print(LOG .. "unstick pn=" .. playerNum .. " begin n=" .. s.unstickCount)
            end
        else
            Drive.stop(playerNum, KEY_STUCK)
        end
        return
    end

    -- 抵達只認 follower 的 reached：它同時要求「沿線剩餘距離夠短」與「車真的在終點
    -- 附近」。這裡不得再加一條只看 remaining 的旁路——投影點滑到終點時 remaining 會
    -- 歸零，車卻可能還在幾十公尺外的路邊，那條旁路就是半路煞停宣告到站的來源。
    if reached then
        s.mode = "arrive"
        vehicle:setRegulator(false)
        vehicle:setForceBrake()
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
            vehicle:setForceBrake()
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

    -- 目標／路線刷新（節流）。route 換了 identity＝主 MOD 重算過（改目標、偏航重算），
    -- 舊的限速剖面對不上新點集，整份重建。
    -- 本幀 now 已由 usage heartbeat 共用；不為 250ms route refresh 再跨一次 Java。
    if now >= s.nextRouteMs then
        s.nextRouteMs = now + ROUTE_REFRESH_MS
        -- 政策快取同窗刷新：管理員改沙盒、玩家在別的入口改偏好，最晚 250ms 生效
        refreshPolicies(s, vehicle, playerNum)
        local route, tx, ty = fetchRoute(api, playerNum)
        if not route then
            -- 目標消失（tx 為 nil）且車已在剛才目標的抵達圈附近＝主 MOD 的抵達
            -- 自動清除搶在 follower reached 之前收走目標——這是「到達」不是
            -- 「遺失」：轉入既有 arrive 流程（煞停→停妥→綠字已抵達）。
            -- 距離還遠的目標消失（玩家手動清除、分享方收回）照走紅字。
            if tx == nil and s.lastTx then
                local ddx = s.lastTx - vehicle:getX()
                local ddy = s.lastTy - vehicle:getY()
                if ddx * ddx + ddy * ddy <= ARRIVE_CLEAR_SQ then
                    s.mode = "arrive"
                    vehicle:setRegulator(false)
                    vehicle:setForceBrake()
                    return
                end
            end
            Drive.stop(playerNum, KEY_LOST)
            return
        end
        s.lastTx, s.lastTy = tx, ty
        if route ~= s.route then
            local profile = MDADFollower.begin(route, s.maxSpeed)
            if not profile then
                Drive.stop(playerNum, KEY_LOST)
                return
            end
            s.route = route
            s.profile = profile
            s.mode = "build"
            diagEvent(s, playerNum, "route")
            if type(MDADFollower.resetState) == "function" then MDADFollower.resetState(s.fstate) end
            -- roadBias 是「舊 route 法向」上的純量；路線轉向後保留等於把舊
            -- 東西偏移旋轉到新方向。實機 8262,11511：remaining 71→726 換線
            -- 仍帶 roadBias=1.85，首輪掃描直接偏向停車場／鐵欄。route cutover
            -- 必回沙盒基準，Sensor 新輪也從同一條線開始；後續 roadC 再重新收斂。
            s.roadBias = 0
            if type(MDADFollower.setLaneBias) == "function" then
                MDADFollower.setLaneBias(s.fstate, s.sandBias)
            end
            if s.sensor then s.sensor.scanBias = s.sandBias end
            if type(MDADOverlay) == "table"
                    and type(MDADOverlay.clearTrail) == "function" then
                MDADOverlay.clearTrail(playerNum)
            end
            -- M4 旗標一併作廢：舊障礙是對舊幾何的弧長，新路線要重掃重規劃
            -- （sensor 的快照失效由 step 認 profile 參考變化自理）
            s.dodging = false
            s.dodgeNotified = false
            s.blocked = false
            s.blockedNotified = false
            s.offroad = false
            s.clearStreak = 0
            s.followHold = false
            s.waitSince = 0
            s.pushSince = 0
            s.detourTried = false
            s.dodgeCrawl = false
            s.dodgeNeed = 1.3
            s.pushBanL = nil
            s.cornerLatch = false
            s.blockHitX = nil
            s.planSig = 0
            -- 卡死觀測與脫困額度綁舊 profile 的弧長空間，跨 identity 保留會拿
            -- 舊值比新值：計時直接歸零、額度重臂基準對齊新空間
            s.stuckSince = 0
            s.unstickCount = 0
            s.unstickS = 0
            s.lastSNow = 0
            -- 重建期間沒有速度剖面可用，先鬆油門讓車滑行（不煞車：剖面通常一兩幀就好）
            vehicle:setRegulator(false)
        end
    end

    -- 堵死改道：blocked 停等 DETOUR_AFTER_MS 仍未解除 → requestDetour（主 MOD
    -- 覆寫路線快取，identity 變化由上方 route 刷新塊自然 cutover 接手，含感知
    -- 空窗爬行保護）。detour 路線長 ≥ DETOUR_FAIL_LEN＝A* 吃罰硬走原路（無替代）
    -- → 不接受，本次 episode 不再試，繼續停等到 WAIT_TIMEOUT 紅字。waitSince
    -- 只在近停後起算：接近段（爬行逼近）先讓車停穩再談改道。
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
                if droute and droute ~= s.route
                        and type(droute.len) == "number" and droute.len < DETOUR_FAIL_LEN then
                    s.nextRouteMs = 0 -- 下一幀立刻走 route 刷新塊 cutover
                    local playerObj = getSpecificPlayer(playerNum)
                    if playerObj then haloGood(playerObj, KEY_DETOUR) end
                    if getDebug() then
                        print(string.format("%spn=%d detour: rerouting around block (len=%.0f)",
                            LOG, playerNum, droute.len))
                    end
                elseif getDebug() then
                    -- 拒收原因：len 超標＝A* 吃軟封鎖罰硬走原路（路網無替代）；
                    -- nil＝noroad／引擎未 ready。「觸發了沒改道」的判別全靠這行
                    if droute then
                        print(string.format("%spn=%d detour rejected: len=%.0f (no real alternative)",
                            LOG, playerNum, droute.len or -1))
                    else
                        print(LOG .. "pn=" .. playerNum .. " detour: no route (noroad/engine)")
                    end
                end
            end
        end
    else
        s.detourTried = false
    end

    -- 限速剖面分幀建構：ready 之前不控速也不施力
    if s.mode == "build" then
        if not MDADFollower.stepBuild(s.profile, BUILD_BUDGET) then return end
        s.mode = "follow"
    end

    -- 讓位：玩家一碰方向盤／油門／煞車就交還控制權，關掉 regulator（等同原版踩煞車
    -- 或倒車時的處理，CarController.java:461-463），並且**本幀不施力**。
    if manualInput(vehicle) then
        if s.mode ~= "yield" then
            s.mode = "yield"
            vehicle:setRegulator(false)
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
        s.stuckSince = 0
        s.pushSince = 0 -- yield 期間玩家亂開，推撞基準（世界座標／時戳）已失效
        haloGood(player, "UI_MinidoracatAutoDrive_Resume")
    end

    -- 倒車脫困：讓位與失效閘門都在上面先跑過（玩家碰輸入會走 yield 交還；引擎熄火
    -- 走紅字）。yield 打斷脫困後 mode 回 follow——還卡著的話卡死偵測會再觸發一次。
    if s.mode == "unstick" then
        stepUnstick(s, vehicle, playerNum, now)
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
