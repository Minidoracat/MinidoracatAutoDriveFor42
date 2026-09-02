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
-- 開發版本戳（telemetry header 的 rev 欄；2026-09-02 使用者裁定）：每輪行為
-- 改動 bump 一次（日期＋字母序）。復盤時先對 header rev 再下判斷——兩次
-- 「實測跑到修前版」的教訓。發版時與 mod.info modversion 對齊語意由發版
-- 流程把關；此戳只服務開發期辨識。
Drive.REV = "0902x"

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
TUNE.ROTATE_SPIN_MAX_KMH = 15  -- 2026-09-01 使用者授權激進化：帶動量原地
                               -- 甩＝甩尾調頭合法（舊 5＝近停才轉；22m 甩出
                               -- 教訓由使用者明示接受風險）
TUNE.ROTATE_ARC_MAX_KMH = 25   -- 大弧前進轉的動量上限（激進化 13→25：帶速
                               -- 切進大弧，超過才煞停）
-- 調頭力矩縮放：耦力模式的力量乘這個值。跟線橫推的量級是為了對抗高速輪胎自回正
-- 標定的，原地調頭阻力小得多，全額力矩＝原地快速旋轉（實機回報「快速循轉」），
-- 收到 0.4 讓調頭變成緩慢平穩的迴轉。過慢調大、仍太快調小。
local ROTATE_FORCE_SCALE = 0.65 -- 激進化 0.4→0.65：調頭轉速加快（甩尾可接受）
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
-- 施力點（2026-09-02 前臂化）：巡線／繞行走**前臂**（relPos=+arm·f̂、力=-force·p̂
-- ＝前輪轉向等效：轉頭與側移同向）；耦力調頭（coupled）維持**後臂**（-arm）＋
-- 幀奇偶側向對消（原地旋轉、不橫滑）——兩套是獨立契約，不得統一臂向。
-- q*LATERAL_JITTER 讓施力點在該臂端左右兩角交替（對力矩零貢獻——q 項在外積中
-- 相消；對中心力也零貢獻——它只動施力點），避免每幀對同一點施力的數值共振。
-- 繞 +y 軸的正向旋轉會讓 (x,z) 向量順時針轉（x'=x·cosθ+z·sinθ），即 heading 變小；
-- 後臂 torque_y = d*F*arm，要 heading 變大（follower 的 steer > 0）需 torque_y < 0
-- ⇒ d < 0 ⇒ STEER_SIGN 取 -1（p 已是 CCW 側向）；前臂把 relPos 與力同時反號，
-- 力矩同號故 STEER_SIGN／PID 約定不變。實機若左右相反，只改 STEER_SIGN。
local STEER_SIGN = -1
local REAR_ARM = 2.2           -- legacy fallback；adaptive session 改用 vehicleProfile.rearArm
local LATERAL_JITTER = 0.5     -- 施力點左右交替的擺幅（公尺）：防共振，不進力矩

-- 量級（Derpy 標定值照搬，STEER_STRENGTH=1.0 即原量級；telemetry 顯示轉不動才調大、
-- 甩尾才調小）。MASS_BASE 給 0 km/h 的基礎權威（原地掉頭靠它），MASS_K*v² 隨速度
-- 補償輪胎自回正的增強；速度先取絕對值再封頂（比較，不呼叫 math.min），倒車與
-- 超速都不會發散。MULT_NORM＝60fps 的 getMultiplier（0.8），把「每幀衝量」正規化
-- 成幀率無關；30 km/h／1200 kg／飽和轉向在 60fps 下 F ≈ 50,100（×2.2m 臂）。
local STEER_STRENGTH = 1.8     -- 主要調校旋鈕（過大＝甩尾、過小＝轉不動）
                               -- 2026-09-02 2.0 實測回退 1.8：s016 定罪 latDev
                               -- p90 3.0m/max 4.0m、contact 60 幀——轉向過猛的
                               -- 甩尾超調讓跟線崩掉、整體反而更慢。1.8 是實測甜點。
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
local NEED_HALF = 1.2          -- legacy fallback；adaptive session 改用 profile.needHalf
TUNE.ZOMBIE_CAP_1 = 35         -- 走廊內 ≥1 隻殭屍（2026-09-01 使用者裁定去保守
TUNE.ZOMBIE_CAP_4 = 25         -- 二次調升；玩家另有 HUD 殭屍閘可自關）
TUNE.ZOMBIE_CAP_8 = 15         -- ≥8 隻
TUNE.MOVING_VEH_CAP = 20       -- 走廊內有行進中的別台車（跟車，不繞行）
TUNE.UNLOADED_CAP = 15         -- 走廊內有未載入 chunk（不知道前面有什麼，先慢）
local POLICY_DODGE = 1         -- 沙盒 ObstaclePolicy enum：1=繞行 2=停車

TUNE.BLOCK_STOP_DIST = 10      -- 距障礙群這麼近才煞停等待；更遠先滑行接近
TUNE.BLOCK_APPROACH_KMH = 20   -- blocked 接近段的速度上限（掃描逼近後縫隙判定更準）
TUNE.WAIT_TIMEOUT_MS = 15000   -- 停等總上限：紅字請玩家接手（2026-09-01 20s→15s）
TUNE.BLOCK_RETRY_MS = 5000     -- blocked 停等此時長仍無縫→主動倒退重掃換視角找路
                               -- （2026-09-01 使用者裁定：不乾等；rear clear 才退，
                               -- episode 3 次額度用盡才走紅字）
-- 改道（2026-09-02 使用者裁定「車陣策略照建議」：先做 HUD 鈕、自動模式為 ESC 選項）。
-- 舊自動改道 2026-09-01 拆掉的兩個實作問題在此收口：① 拿回 snap 退化的爛路線
-- → 驗收（仍穿避讓圈／起點太遠／長度超標一律拒）；② 同目標 cutover 清空繞行記憶
-- → 改道只由玩家或自動條件觸發一次，且 cutover 帶 why="detour"。
TUNE.SNAP_MAX_M = 20           -- 路線起點離車超過此距離＝要越野接線（s053：75m 穿樹林卡死），拒啟動
TUNE.DETOUR_AVOID_R = 40       -- 以堵點為圓心的軟封鎖半徑（主 MOD findRoute avoidR）
TUNE.DETOUR_LEN_RATIO = 1.5    -- 替代路線長 ≤ 剩餘 × ratio + slack 才接受
TUNE.DETOUR_LEN_SLACK = 200
TUNE.AUTO_DETOUR_MS = 10000    -- 自動改道：停等累計此時長才要替代路線（或倒車重掃過一次又再堵＝BLOCK_RETRY_MS 即問）
-- 車陣蛇行（2026-09-02）：plan/sweep 鏈全 blocked 時在 (s,l) 格點找斜率受限折線
-- 穿過錯落車陣（Corridor.thread），承諾為 exactLine（同 RETURN 機制）。爬行檔：
-- 餘裕 0 → MIN、餘裕 ≥1m → MAX；貼縫檔（squeezeNeed）固定 MIN。
TUNE.THREAD_CAP_MIN_KMH = 8
TUNE.THREAD_CAP_MAX_KMH = 18
TUNE.THREAD_RETRY_MS = 2000    -- 無路後的重試冷卻（DP 是冷路徑但非免費）
TUNE.THREAD_NODES_MAX = 64
-- recovery 方向探測與 episode 重臂。rear 每 100ms 重查；成功倒退後 ban
-- 跨 sensor reset／same-target route cutover 保留，前進 10m 且兩輪 footprint clear 才清。
local REAR_PROBE_MS = 100
local REAR_TRAVEL_M = 4
local EPISODE_REARM_SQ = 100
TUNE.SCAN_WARM_CAP = 15        -- 感知空窗（首輪掃描未完成）的爬行上限（與
                               -- UNLOADED_CAP 同級：語意都是「前方未知」）
-- 堵死改道（requestDetour）已於 2026-09-01 移除（使用者裁定）：telemetry s030/s033
-- 證實它會拿回 snap 退化的爛路線，且同目標反覆 cutover 把繞行枚舉進度/ban 全部
-- 清空重來——blocked 的出路只留本地感知繞行與 20s 紅字交還。
-- 候選枚舉與降檔（codex 對抗審方案 6，2026-08-29 路口實測落地）：
-- 舊版 sweep 打槍只 retry 一次就 blocked，更遠的可行縫從沒被試過。改為
-- 單輪內 ban→重規劃→world sweep 枚舉；普通／彎道檔全敗後 plan 與 sweep
-- **對稱**縮到 squeeze／physical 檔重枚舉（契約一致，非單邊放寬）。速度不再
-- 有離散爬行帽（2026-09-02 退役）：由 clearance/curve/space 連續縮放，
-- Dynamics.DODGE_CAP_FLOOR_KMH 夾底；DODGE_SQUEEZE_CAP 只剩設計速／可視地板用途。
local DODGE_CANDIDATES = 3     -- 每檔位最多枚舉幾條候選縫
local SQUEEZE_NEED = 1.15      -- legacy fallback；adaptive＝halfW+0.2（2026-09-01
                               -- telemetry s046：m=1.1 vs 舊 squeeze 1.15 差 0.05
                               -- 打槍——量化補償另計）
local SWEEP_BASE = 1.3         -- legacy fallback；adaptive＝needHalf-0.1
local SWEEP_PHYS_PAD = 0.05    -- baseline 段（a 之前＝路線本身）只驗物理必撞：車身
                               -- OBB 之外只留這麼多餘裕，不套規劃檔位的淨距
TUNE.SWEEP_QUANT_COMP = 0.1   -- 整格障礙圓近似比 1x1 方格角落多出的量化肥邊
-- 幾何投影誤差下限（2026-08-28 對抗審定案）；低於此縫寬必須拒絕而非減速掩蓋。
TUNE.DODGE_CLEARANCE_RESERVE = 0.15 -- 2026-09-01 三次去保守 0.3→0.15（使用者
                                   -- 裁定「確定可過就全油門」：reserve 是速度
                                   -- 縮放輸入，不是通行資格門檻；邊際縫的
                                   -- 速度由 clearanceCap 連續縮放即可）
TUNE.DODGE_OV_SPAN = 93       -- OV_MAX=96，保留起點／d+1／防呆三格
TUNE.APPROACH_BRAKE_FRAC = 0.7 -- 接近限速區用 safeBrake 的這個比例反推（同 laneCurveEnvelope
                               -- 的 decel 基準；2026-09-02 s064：舊制用 safeCoast 0.6 純滑行
                               -- ＝繞行縫還在 100m 外車就爬行）
local CORNER_NEAR = 8          -- sweep 失敗點離折點多近算「折點衝突」（BLOCKED_CORNER 判定）
local CORNER_RETRY_DIST = 3    -- corner latch 撤銷距離：漸進接近讓車前進這麼多＝
                               -- 幾何已變、重新枚舉——實測「靠很近開導航就能繞」
                               -- ＝近距下折點幾何退化成直路障礙，把手動流程自動化
TUNE.CORNER_STOP_DIST = 8      -- corner 下的煞停線（普通 blocked 10m）：爬更近再停，
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
TUNE.SOFT_CAP = 25             -- 走廊內有可輾過的軟障礙（家具／雜物）時的速度上限
TUNE.CORPSE_CAP = 30           -- 走廊內有地面屍體（壓得過，但不減速輾過的體感就是撞擊）
-- RETURN 進入門檻由 v4 segWidth 與實際車寬推導；v2/v3 width unknown 使用
TUNE.RETURN_MAX_DEV = 12       -- RETURN 進入的偏差上限（m）。錨定＝掃描帶幾何：
                               -- 回線 start 與 target 要同帶可驗（returnLineBandCovers
                               -- ／unsafe crawl 授權都吃 ±6.5m 帶），|Δ|>2×6.5-1
                               -- 結構性蓋不住＝returnHold 永久 0（telemetry s030：
                               -- snap 爛路線 lat=19 卡死 20s 紅字）。超上限交一般
                               -- pure pursuit 低速接線（ERR_SLOW＋alignmentCap）；
                               -- 7m 甩出（delta7 平行爬行）仍在 RETURN 服務內。
-- available=2m。physical isDoingOffroad 只作 paved/actual mismatch 輔證，永不單觸發。
TUNE.RETURN_CAP = 25           -- 20→25（2026-09-02 s008/s009 剖析：return 檔是
TUNE.RETURN_UNSAFE_CAP = 14    -- 10→14  「樹叢區個位數」主因之一；使用者裁定整體提速）
-- RETURN 是「車頭大致對路時的橫向回線」，不是轉向器（2026-09-02 s040：耦力調頭
-- 在 100° 出遲滯，同輪 RETURN 以 98° 誤差劫持，回線 guard 一失敗車就停在 33° 斜姿
-- 直到 15s 紅字）。偏頭超過此角交 pure pursuit 追線，RETURN 等頭擺正再進。
TUNE.RETURN_ENTER_MAX_RAD = 30 * math.pi / 180
-- hold 不是終態：回線驗不過（probe／sweep／band／unloaded）且車已靜止超過此時間
-- 就釋放 RETURN，交 pure pursuit 帶著一般安全體系（contact／sweep／dodge／可視）
-- 前進；釋放後冷卻期內不重入，避免「進→hold→釋放→又進」原地循環。
TUNE.RETURN_STALL_MS = 2000
TUNE.RETURN_STALL_BLOCK_MS = 6000
-- 未圓角的原始折點（fallback 角）±此距內不進 RETURN（2026-09-02 s046 Bank Road→
-- Garnettsville T 字左轉：窄路 band 1.2m 放不下 rMin 圓角，pure pursuit 本來就要切
-- 過折點，「對折線的橫向偏差」在折點兩側是幾何必然，不是甩出；舊制在彎中進
-- RETURN pending→WAIT 煞到 1 km/h 再起步＝使用者感到的頓挫）。
TUNE.RETURN_CORNER_M = 10
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

-- 感知閉環的標準／高速組態分界：標準掃描帶前伸 48m，一輪最慢約 200ms，
-- 再受 250ms 啟動節流影響；85 km/h 是既有標準組態的保守相容上限與高速檔
-- 啟用門檻，不宣稱是所有載具／路況的形式化煞停證明。沙盒上限超過 85 時，
-- session 會把掃描帶改成 100m、感知上限改成 120；兩者必須一起切換。
TUNE.PERCEPTION_CAP_KMH = 85
-- 高速檔（2026-08-29 使用者需求：瘋狂檔要能跑 120）：沙盒上限 > 85 時把掃描
-- 帶拉到 100m、感知上限放到 120——BRAKE=8 下 120 km/h 的煞停證明
-- D = v·τ + v²/(2a) + halfL + 2 ≈ 90m（τ=0.5 新鮮快照）；快照老化到 τ=1.0
-- 需 ~107m，屆時連續 visibilityCap 自然把巡航壓到 ~108，不再靠 gate 硬鎖
-- （2026-09-01 三模型對抗審：110→100，80 不可——老化下 120 檔失去證明）。
-- 帶長只影響輪完成時間（分幀 budget 不變、fps 成本相同），障礙密集
-- 區速度自然壓低。由 session 依沙盒一次決定，不隨車速抖動。
local HISPEED_AHEAD_M = 100
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
local KEY_ROUTE_FAR = "UI_MinidoracatAutoDrive_RouteTooFar"
local KEY_DETOUR = "UI_MinidoracatAutoDrive_Detour"
local KEY_THREAD = "UI_MinidoracatAutoDrive_Thread"
local KEY_NO_DETOUR = "UI_MinidoracatAutoDrive_NoDetour"

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

-- 語音提示（MDAD_Voice.lua）：缺席／拋錯都不得影響控制——pcall 包住、回值不看。
-- 六個事件：start／stop／blocked／unstick／handback／arrive；觸發點與 halo 同址。
local function voice(event, playerNum)
    local v = MDAD.Voice
    if type(v) ~= "table" or type(v.play) ~= "function" then return end
    pcall(v.play, event, playerNum)
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

-- 路線起點太遠（`route.snapDist`＝玩家到路線最近點的投影距離＝出發前必須越野走完的
-- 接線；MinidoracatMiniMap_NavRoute.lua:1386-1389、1827-1832）。判在啟動與換目標。
-- 2026-09-02 s052/s053：目標點在平行小路旁 4m，路線吸到 67m 外那條路，車嘗試
-- 穿 57m 樹林接線→卡死三輪倒車。**只信 nav API v5 起的 snapDist**：v4 沿用快取時
-- 刷新成「玩家→pts[1]」，沿線前進 100 格後停車再啟動會報 100（實機：車在路上卻被
-- 拒啟動「起點太遠」）；v4 以下與缺 snapDist 一律不擋，寧可放行也不鎖死玩家。
-- `finite` 在本檔較後面才定義（:1426），這三個 helper 用 MDADDynamics.finite。
local function routeTooFar(route)
    local d = route and route.snapDist
    return MDADDynamics.finite(d) and d > TUNE.SNAP_MAX_M
end

-- 快取路線的 snapDist 只有 v5 起才是投影距離；requestDetour 每次新算（不進快取），
-- 其 snapDist 在任何版本都是建圖當下到首點的距離＝可信，不經此閘。
local function cachedSnapTrusted(api)
    return api ~= nil and type(api.navApiVersion) == "number" and api.navApiVersion >= 5
end

-- 路線是否穿過避讓圈（任一段到圓心距 ≤ r）；冷路徑 O(n)，只在 cutover 用。
local function routeCrossesAvoid(route, ax, ay, r)
    local pts = route and route.pts
    if type(pts) ~= "table" or not MDADDynamics.finite(ax) or not MDADDynamics.finite(ay) then return false end
    local n = #pts / 2
    for i = 1, n - 1 do
        local x1, y1, x2, y2 = pts[i * 2 - 1], pts[i * 2], pts[i * 2 + 1], pts[i * 2 + 2]
        local dx, dy = x2 - x1, y2 - y1
        local den = dx * dx + dy * dy
        local t = 0
        if den > 0 then
            t = ((ax - x1) * dx + (ay - y1) * dy) / den
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
        end
        local ex, ey = ax - x1 - dx * t, ay - y1 - dy * t
        if ex * ex + ey * ey <= r * r then return true end
    end
    return false
end

-- 向主 MOD 要「繞開 (ax,ay) 半徑 r」的替代路線並驗收。回 (route, nil) 或 (nil, 原因)。
-- 驗收：仍穿避讓圈（avoidPenalty>0＝沒有替代路，主 MOD 是軟封鎖照樣給原線）、
-- 起點太遠、長度 > 剩餘×ratio+slack 一律拒——這三條就是舊自動改道「拿回爛路線」的
-- 全部型態。成功時主 MOD 已覆寫路線快取，下一次 requestRoute 回的就是替代線。
local function requestDetourRoute(api, playerNum, tx, ty, ax, ay, remaining)
    if type(api.requestDetour) ~= "function" then return nil, "api" end
    local route, state = api.requestDetour(playerNum, tx, ty, ax, ay, TUNE.DETOUR_AVOID_R)
    if not route or state ~= "ok" then return nil, state or "noroad" end
    if MDADDynamics.finite(route.avoidPenalty) and route.avoidPenalty > 0 then return nil, "through", route end
    if routeTooFar(route) then return nil, "far", route end
    if MDADDynamics.finite(route.len) and MDADDynamics.finite(remaining)
            and route.len > remaining * TUNE.DETOUR_LEN_RATIO + TUNE.DETOUR_LEN_SLACK then
        return nil, "long", route
    end
    return route, nil
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
-- mode 契約值（階段 2 主體 5 收斂後）：build／follow／unstick／settle／yield／
-- arrive——只有「會繞過 stepFollow 或整段停控」的狀態才配得上 mode。恢復鏈的
-- 內部階段（gear-reset／recover／suspect／verify）一律在 progressState，
-- 「有恢復需求」則是 s.recoverWhy 旗標。
local function controlStateOf(s)
    if not s then return nil end
    local mode = s.mode
    if mode == "arrive" then return "ARRIVE" end
    if mode == "yield" then return "YIELD" end
    if mode == "unstick" or mode == "settle"
            or s.progressState == "gear-reset"
            or s.recoverWhy ~= nil then return "RECOVER" end
    if s.currentBlocked then return "HOLD" end
    if s.returnHold then return "HOLD" end
    if s.returnActive then return "RETURN" end
    if s.blocked or s.followHold or mode == "build" then return "HOLD" end
    if s.dodging or s.threading then return "AVOID" end
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
    -- 2026-09-01（telemetry s055：verifyLineReason=state 542 筆、obb 418 筆）：
    -- proof（verifyBand/Sweep/verifiedUntilS）是**感知快照的產物**，自有
    -- laneCurveStamp 時戳守鮮——隨 command 狀態切換清除會讓 TRACK↔HOLD 抖動
    -- 期間 proof 永遠活不過一輪掃描 → gate obb 常駐 15 → 壓速 → 更易 blocked
    -- 的正反饋＝「走走停停／巡航值閃爍」主因。此處只重錨 cmdV 與降 fullGate；
    -- proof 清除只留 route cutover／dynamics rebuild（那裡另行處理）。
    s.commandControlState = controlState or controlStateOf(s)
    s.jerkBypassReason = nil
end

-- 車陣蛇行承諾釋放（exactLine 何時清同樣由呼叫端決定）。
local function releaseThread(s)
    s.threading = false
    s.threadN = 0
    s.threadGuardHardN = nil
end

-- 繞行承諾釋放：這五個旗標永遠一起回到「無承諾」狀態，dodgeNeed 回基準淨距。
-- 不含 clearOffset：剖面何時清由呼叫端時序決定（車還在動時清＝目標線瞬跳）。
-- 同時釋放蛇行承諾：兩者同 owner 等級，所有「放棄承諾」的出口（blocked／
-- RETURN 進入／recover／cutover）都經這裡。
local function releaseDodge(s)
    releaseThread(s)
    s.dodging = false
    s.dodgeNotified = false
    s.dodgeCrawl = false
    s.dodgeGuardHardN = nil -- 承諾鎖定的點雲基準（守護 lazy init）
    s.dodgeTight = false
    s.dodgeNeed = s.sweepBase
    s.dodgeKappa = 0
    s.dodgeClearance = 0
    s.dodgeCurveCap = 0
    s.dodgeClearanceCap = 0
    s.dodgeVisibilityCap = 0
    s.dodgeSpaceCap = 0
    s.dodgeSpeedCap = 0
    s.dodgeApproachCap = 0
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
    elseif s.mode == "unstick" or s.mode == "settle"
            or s.recoverWhy ~= nil then
        key = "unstick"
    elseif s.currentBlocked or s.blocked then key = "blocked"
    elseif s.dodging or s.threading then key = "dodging"
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

-- Driver 一律送具名 payload。
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
    -- 停等預算耗盡的紅字交還說「無法通過，請手動駕駛」；其餘（玩家關閉、讓位、
    -- 引擎熄火…）一律「已關閉，請接管方向盤」。
    voice(reasonKey == KEY_STUCK and "handback" or "stop", playerNum)
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
    if cachedSnapTrusted(api) and routeTooFar(route) then return KEY_ROUTE_FAR end
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
    -- 餘裕預算單一 authority（2026-09-01 階段 2 主體 4）：plan need 與 sweep
    -- base 一律由 MDADVehicleProfile.planNeed／sweepBase 從同一張預算表導出，
    -- 這裡不得再出現 halfW+常數 或 need-常數 的私扣。非 adaptive session 沒有
    -- 可信車身幾何，只能沿用 legacy 標定常數。
    local needHalf = adaptive
        and MDADVehicleProfile.planNeed(vehicleProfile.halfW, "cruise")
        or NEED_HALF
    local squeezeNeed = adaptive
        and MDADVehicleProfile.planNeed(vehicleProfile.halfW, "squeeze")
        or SQUEEZE_NEED
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
    MDADFollower.setLaneBias(fstate, laneBias)
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
        mode = "build",  -- build → follow → unstick → settle ⇄ yield → arrive
                         -- （gear-reset／recover 已於階段 2 主體 5 移入 progressState）
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
        -- probe 預算（-0.1＝容許剮蹭）是唯一合法的第二次扣除，同樣走 authority
        sweepBase = adaptive
            and MDADVehicleProfile.sweepBase(vehicleProfile.halfW, "cruise")
            or needHalf + MDADVehicleProfile.clearanceBudget("probe"),
        squeezeSweepBase = adaptive
            and MDADVehicleProfile.sweepBase(vehicleProfile.halfW, "squeeze")
            or squeezeNeed + MDADVehicleProfile.clearanceBudget("probe"),
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
        dodgeTight = false, -- 本次繞行在彎道段（加嚴縫需求＋clearance reserve 豁免；replan 每次重判）
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
        returnReason = nil, returnClearRounds = 0,
        returnHoldSince = 0,   -- hold 起算（sensor 快照時戳；0＝未在 hold）
        returnBlockUntil = 0,  -- stall 釋放後的 RETURN 重入冷卻截止
        returnX = {}, returnY = {},
        -- 車陣蛇行承諾（exactLine；owner 與 dodge 同級）
        threading = false,
        threadN = 0,           -- 折線節點數（threadS/threadL）
        threadStartS = 0, threadEndS = 0, threadDoneS = 0,
        threadCap = 0, threadNeed = 0,
        threadNextMs = 0,      -- 無路後的重試冷卻
        threadGuardHardN = nil,
        threadX = {}, threadY = {}, -- 承諾線本體（setExactLine 持有 identity，不得與 tmpOv 共用）
        threadS = {}, threadL = {}, -- Corridor.thread 節點
        threadWork = {},           -- DP 工作表（一次配置、重用）
        clearStreak = 0,    -- 連續 clear 輪數（堵住解除遲滯）
        followHold = false, -- 跟車分級把目標壓 0（停等豁免卡死偵測用）
        dodgeCommittedLength = 0,
        dodgeBuildReason = nil,
        dodgeBlockReason = nil,
        -- 停等預算（階段 2 主體 1）：accum＝本 episode 已累計的 WAIT/RECOVER
        -- 毫秒（15s 總上限＋5s 主動倒退）；tick＝上一個累計幀時戳（0＝暫停）；
        -- anchor＝判定真進度的基準（沿線 s／|橫偏|／|角誤差|）。
        waitAccumMs = 0,
        waitTickMs = 0,
        waitAnchorS = 0, waitAnchorLat = 0, waitAnchorErr = 0,
        blockRetryDone = false, -- 本次停等的主動倒退嘗試只做一次（soft fail 防洗版）
        detourTried = false,    -- 自動改道每個停等 episode 只試一次（清除同 blockRetryDone）
        avoidX = nil, avoidY = nil, -- 已接受的改道避讓圈（sticky：之後主 MOD 重算若穿回去再要一次）
        pendingDetour = false,  -- requestDetour 已覆寫主 MOD 快取，等下一次 fetchRoute cutover
        -- RECOVER 單一進口（階段 2 主體 2）：why＝需求原因（nil＝無需求，
        -- 同時是舊 mode=="recover" 閂鎖的替代）；其餘三個是 suspect 探測留給
        -- dispatch 選動作用的純量，只有 why=="progress" 時有效。
        recoverWhy = nil,
        recoverPulse = false,
        recoverGear = 0,
        recoverHit = "unknown",
        recoverDetail = nil,
        dodgeCrawl = false, -- 承諾剖面是 squeeze／physical／降檔（reserve 豁免＋intent CRAWL；速度仍連續縮放）
        dodgeApproachCap = 0, -- 接近段 envelope（telemetry：分辨「遠壓速」vs「縫本身的帽」）
        rejectedRoute = nil,  -- 本 MOD 拒收、但仍在主 MOD 快取裡的替代線 identity（cutover 跳過）
        lastDetourRoute = nil,
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
        dodgeNeed = adaptive
            and MDADVehicleProfile.sweepBase(vehicleProfile.halfW, "cruise")
            or needHalf + MDADVehicleProfile.clearanceBudget("probe"),
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
                diagEvent(sNew, playerNum, "route", MDADDiagnostics.routeSource(route, {
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
                }))
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
    voice("start", playerNum)
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

-- 改道（HUD「改道」鈕與自動改道共用）：只在 blocked 停等時有意義。以堵點
-- （群最近擋線點 blockHitX/Y，缺則車位）為圓心向主 MOD 要替代路線並驗收
-- （requestDetourRoute）；成功＝主 MOD 快取已換線，這裡只記 sticky 避讓圈、
-- 把 nextRouteMs 歸零讓下一幀 fetchRoute 立刻 cutover（why="detour"）。
-- 回 (true) 或 (false, 原因)；原因供 HUD tooltip／console。
function Drive.requestDetour(playerNum)
    local s = sessions[playerNum]
    if not s then return false, "inactive" end
    if not s.blocked and not s.currentBlocked then return false, "not-blocked" end
    local api = navApi()
    if not api then return false, "api" end
    local playerObj = getSpecificPlayer(playerNum)
    local fin = MDADDynamics.finite -- 本檔的 local finite 定義在更後面（:1460+）
    if not playerObj or not fin(s.lastTx) or not fin(s.lastTy) then return false, "target" end
    local vx, vy = s.vehicle:getX(), s.vehicle:getY()
    local hx, hy = s.blockHitX, s.blockHitY
    if not fin(hx) or not fin(hy) then hx, hy = vx, vy end
    -- 避讓圈圓心＝堵點沿「車→堵點」方向再推 R（2026-09-02 s064 定罪：舊制以堵點
    -- 為圓心、R=40，車在圈內 9-13m → 任何從本路出發的替代線第一段就穿圈
    -- （avoidPenalty>0）→ 全部拒收 "through"，只剩起點在別條路的線又被 "far" 拒
    -- → 永遠 nodetour）。推 R 後：圈的近緣貼堵點、車必在圈外，圈覆蓋堵點後方
    -- 整段車陣（2R 深）。堵點與車重合（無錨）時沿路線切線推。
    local dx, dy = hx - vx, hy - vy
    local dn = sqrt(dx * dx + dy * dy)
    if dn < 0.5 then
        local h = s.profile and s.profile.segH[s.fstate.idx or 1] or nil
        if fin(h) then dx, dy, dn = cos(h), sin(h), 1 else dx, dy, dn = 0, 0, 0 end
    end
    local ax, ay = hx, hy
    if dn > 0 then
        ax = hx + dx / dn * TUNE.DETOUR_AVOID_R
        ay = hy + dy / dn * TUNE.DETOUR_AVOID_R
    end
    local remaining = s.profile and (s.profile.length - s.lastSNow) or nil
    local route, why, rejected = requestDetourRoute(api, playerNum, s.lastTx, s.lastTy, ax, ay, remaining)
    s.lastDetourRoute = rejected
    if getDebug() then
        print(LOG .. "detour pn=" .. playerNum .. " avoid=(" .. tostring(ax) .. "," .. tostring(ay)
            .. ") -> " .. (route and ("ok len=" .. tostring(route.len)) or ("rejected " .. tostring(why))))
    end
    if not route then
        -- 主 MOD 的 requestDetour 成功算出路線就已覆寫快取（含被本 MOD 拒收的
        -- far／long 線）；記住被拒的 identity，cutover 不得沿用（下一次 250ms 取
        -- 路仍會拿到同一個 table，直到主 MOD 冷卻後重算）。
        s.rejectedRoute = s.lastDetourRoute
        haloBad(playerObj, KEY_NO_DETOUR)
        voice("nodetour", playerNum)
        return false, why
    end
    s.avoidX, s.avoidY = ax, ay
    s.pendingDetour = true
    s.pendingRouteWhy = "detour"
    s.nextRouteMs = 0
    haloGood(playerObj, KEY_DETOUR)
    voice("detour", playerNum)
    return true
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
        -- 前臂轉向（2026-09-02 使用者裁定「只推車頭、模擬前輪轉向施力」）：
        -- 舊制後臂側推（力向左推車尾→車頭右轉）轉頭正確但質心向轉向反側
        -- 漂移——「轉頭右、車體左漂」正是貼線差與蛇行觀感的力學根源。
        -- 改：作用點車頭（+arm·f̂）、力方向翻轉（-force·p̂）——τ_z 同號
        -- （右轉照右轉、PID／STEER_SIGN 約定不變），側移改與轉向同向，
        -- 等效前輪轉向。assist 前向分量與臂平行＝零 yaw（性質不變）。
        impulse:set(-force * px + assistForce * fx, 0,
            -force * py + assistForce * fy)
        if assistForce > 0 then
            -- Forward impulse at the center when steering is idle; otherwise
            -- ride the front centerline so lateral force retains yaw
            -- without assist yaw.
            if force == 0 then
                fwd:set(0, 0, 0)
            else
                fwd:set(arm * fx, 0, arm * fy)
            end
        else
            fwd:set(arm * fx + parity * LATERAL_JITTER * px, 0,
                arm * fy + parity * LATERAL_JITTER * py)
        end
    end
    vehicle:addImpulse(impulse, fwd)
    BaseVehicle.releaseVector3f(impulse)
    return force, assistForce
end

-- 前推輔助（越野／繞行加成＝2026-09-01 使用者裁定）：非道路與繞行／回線時
-- 牽引力掉、姿態誤差也大，正是「卡在草地／擠不過縫」的現場。roughness 為真
-- 時把比例乘上越野補償（rough 保底 ASSIST_OFFROAD_BASE、低效車 1/eff、上限 MAX）
-- 再乘重車超線性 massScale（引擎推力非質量等比、assist 是唯一等比項）。
-- 質量門檻不放寬：輕車本來就推得動，補償只針對推不動的重車。
local function longitudinalAssistForce(s, speedKmh, targetSpeed, mult, rough)
    local mass = s.runtimeMass
    if type(mass) ~= "number" or mass * 0 ~= 0
            or mass < TUNE.ASSIST_MASS_MIN then return 0 end
    local scale = 1
    if rough then
        scale = MDADDynamics.assistOffroadScale(
            type(s.vehicleProfile) == "table"
                and s.vehicleProfile.offroadEfficiency or nil)
    end
    local ratio = MDADDynamics.longitudinalAssistRatio(
        speedKmh, targetSpeed, scale)
    if ratio <= 0 then return 0 end
    -- 超線性質量縮放（2026-09-02 使用者裁定「越重的車推力要更大」）：
    -- F=ratio×mass 只保證同加速度增益，但引擎推力非質量等比（固定馬力、
    -- 重車 a=P/mv 天生低）——重車再乘 mass/門檻 的超線性項補引擎差額，
    -- 上限 ×2（2×ASSIST_MASS_MIN≈2600kg 滿載）。輕車（≈門檻）維持 ×1。
    local massScale = mass / TUNE.ASSIST_MASS_MIN
    if massScale > 2 then massScale = 2 end
    if massScale < 1 then massScale = 1 end
    return ratio * mass * massScale * IMPULSE_SCALE * (mult / MULT_NORM)
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

-- 期望行駛線＝laneBias＋（繞行中）smoothstep 側偏。與 follower 前視／sweepLine
-- 同一段；抽出只為遙測 el／ld 與甩出判定共用，語意逐位元不變。
local function expectedLaneOf(s)
    local expL = laneBiasOf(s)
    -- 蛇行中：期望線＝折線在當前弧長的 lane（節點間 smoothstep，與 buildThreadLine 同式）
    if s.threading and s.threadN >= 2 then
        local ts, tl, sN = s.threadS, s.threadL, s.lastSNow
        if sN <= ts[1] then return tl[1] end
        if sN >= ts[s.threadN] then return tl[s.threadN] end
        for k = 1, s.threadN - 1 do
            if sN <= ts[k + 1] then
                local t = (sN - ts[k]) / (ts[k + 1] - ts[k])
                if t < 0 then t = 0 elseif t > 1 then t = 1 end
                t = t * t * (3 - 2 * t)
                return tl[k] + (tl[k + 1] - tl[k]) * t
            end
        end
        return tl[s.threadN]
    end
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
        elseif (not s.regulatorPrev
                or s.targetPrev <= s.kinPrevV * 3.6 + 1) and v >= 2.2 then
            -- coast 資格門檻（2026-09-01 telemetry 001 死亡螺旋定罪）：
            -- 低速滑行阻力∝v²、量測值天然趨 0——那是物理下限不是車輛能力。
            -- 低速樣本灌進 EWMA → coastLower→0 → envelopeScale→0 → 包絡壓
            -- target→車更慢→量測更低的閉環正反饋（lce 6.8→5.6→3.9→0 實錄）。
            -- ≥8 km/h（2.2 m/s）才學；brake/accel 低速觀測是真訊號、不設限。
            local obs = -dv
            if obs < 0 then obs = 0 end
            if s.coastTime == 0 then s.coastMean = obs end
            s.coastMean, s.coastDev, s.coastTime,
                s.coastConfidence, s.coastLower = MDADVehicleProfile.updateEWMA(
                    s.coastMean, s.coastDev, s.coastTime, obs, dt)
        end
        local steer = s.steerPrev
        if not brakeWindow and not s.forceBrakePrev and finite(steer)
                and v >= 2.2 -- 同 coast：v*dh/dt 低速趨 0，學到假 lat 下限
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
    phys.steeringKappa = MDADDynamics.steeringKappa(
        s.vehicleProfile.wheelbase, s.vehicleProfile.delta0Safe,
        s.vehicleProfile.deltaVSafe, s.vehicleProfile.maxSpeed, s.kinPrevV * 3.6)
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
        if MDADDynamics.blockedNear(s.blockS, s.lastSNow, stopDist,
                vehicle:getX(), vehicle:getY(), s.blockHitX, s.blockHitY) then
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
    phys.dodgeApproachCap = s.dodgeApproachCap
    phys.dodgeDesignSpeed = s.dodgeDesignSpeed
    phys.dodgeSpeedCap = s.dodgeSpeedCap
    phys.dodgeClass = s.dodgeClass
    phys.verifyLineReason = s.verifyLineReason
    -- 本幀速度裁決者與 gate 狀態（2026-09-01 使用者指示補齊離線可判數據）
    phys.capReason = s.lastCapReason
    phys.sensorCapReason = s.lastSensorReason
    phys.gateReasonNow = s.gateReason
    phys.fullGateNow = s.fullGate == true
    phys.visCap = s.visibilityCap
    phys.holdReason = s.lastHoldReason
    phys.intent = s.intentShadow
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
    -- 停等預算與 episode 同生命週期（階段 2 主體 1）：換目標／到站／前進 10m
    -- 重臂才歸零；同目標 route cutover 刻意**不**呼叫這裡＝預算不被清空。
    s.waitAccumMs, s.waitTickMs = 0, 0
    s.waitAnchorS, s.waitAnchorLat, s.waitAnchorErr = 0, 0, 0
    s.blockRetryDone = false
    s.detourTried = false
    s.recoverWhy, s.recoverPulse = nil, false
end

-- RECOVER 單一進口（2026-09-01 階段 2 主體 2）：舊制五個需求方各自
-- 「設 mode／progressState／targetSpeed／postAction」再各自呼恢復，優先序靠
-- 賦值順序與 postAction==nil 隱式決定，動作選擇（neutral pulse vs 倒車）也
-- 埋在 suspect 分支裡。現在需求方只呼這裡設旗標＋原因，動作由 stepFollow
-- 尾端的單一 dispatch 每幀判定一次。
-- rank 顯式定序：數字大者為更具體的診斷。pulse＝這個需求夠格用「150ms 空檔
-- 脈衝」而非倒車（只有 "progress"＝suspect 近場探測真的跑過才可能夠格）；
-- 脈衝的語意是「regulator off、不煞車、不施力」，所以控制側凡是會煞車的分支
-- 都要排除 pulse——這是脈衝與倒車在同一旗標下唯一需要分流的地方。
TUNE.RECOVER_RANK = {
    ["blocked-retry"] = 1,  -- 停等累計 5s 無縫：換視角重掃
    ["uturn-blocked"] = 2,  -- 調頭需求＋前方堵死
    ["verify"] = 3,         -- VERIFY 窗內仍不動
    ["progress"] = 4,       -- 2.5s 監督 suspect（帶近場探測結果）
}
local function requestRecover(s, why, pulse)
    local rank = TUNE.RECOVER_RANK[why]
    if rank == nil then return end
    if s.recoverWhy ~= nil
            and (TUNE.RECOVER_RANK[s.recoverWhy] or 0) >= rank then
        return
    end
    s.recoverWhy = why
    s.recoverPulse = pulse == true
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
                expectedLaneOf(s))
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
local function startRecoveryAttempt(s, vehicle, playerNum, now, vx, vy, softFail)
    if MDAD.sandbox("ObstaclePolicy", POLICY_DODGE) ~= POLICY_DODGE
            or s.episodeAttempts >= UNSTICK_MAX then
        diagEvent(s, playerNum, "unstick", {
            phase = "timeout", eid = s.episodeId, attempt = s.episodeAttempts,
            x = vx, y = vy, s = s.lastSNow, rear = "attempt-limit",
        })
        if softFail then
            -- 額度用盡：回停等節奏（recover mode 每幀重打會空轉洗版）；
            -- 15s wait timeout 是最後保險。
            s.blockRetryDone = true
            s.mode = "follow"
            s.progressState = "disarmed"
            s.progressSince = 0
            return
        end
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
        if softFail then
            -- 倒不了就回去繼續合法停等（15s 總上限另有紅字），不因一次探測
            -- 失敗放棄 session；mode 拉回 follow 免 recover 每幀空轉。
            s.blockRetryDone = true
            s.mode = "follow"
            s.progressState = "disarmed"
            s.progressSince = 0
            return
        end
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
    -- 只在 episode 第一次倒退開口：同一堵局的第 2、3 次重試不再重複唸。
    if s.episodeAttempts <= 1 then voice("unstick", playerNum) end
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
        s.blocked or s.currentBlocked, s.dodging or s.threading, s.returnActive, s.cornerLatch, false, phys,
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

-- 前方彎道減速剖面（快照期建表、caller-owned 陣列）：由線尾反推每格的最高
-- 進入速 v[k] = min(localCap[k], √(v[k+1]² + 2·decel·d))。decel（2026-09-02）
-- ＝呼叫端傳入的 minBrake×0.7（煞車系合成減速度；舊制 coast 0.6 純滑行反推
-- 會在 290m 外就鬆油）。欄位名 envelopeBuildCoast 沿用（telemetry schema 只加
-- 不改名），語意＝建表時的 decel。每幀 EWMA 變化只 O(1) 縮放這份快取，不重建。
local function refreshLaneCurveEnvelope(s, decel, lat)
    local n = s.verifyLineN or 0
    if n < 2 or not finite(decel) or decel < 0
            or not finite(lat) or lat < 0 then
        s.laneCurveEnvelope, s.envelopeBuildLat, s.envelopeBuildCoast =
            0, lat, decel
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
        s.laneCurveEnvelope, s.envelopeBuildCoast = 0, decel
        return false
    end
    envelope[n] = nextCap
    for k = n - 1, 1, -1 do
        local localCap, d = caps[k], dist[k]
        if not finite(localCap) or localCap < 0 or not finite(d) or d < 0 then
            s.laneCurveEnvelope, s.envelopeBuildCoast = 0, decel
            return false
        end
        local nextMs = nextCap / 3.6
        local decelCap = sqrt(nextMs * nextMs + 2 * decel * d) * 3.6
        nextCap = localCap < decelCap and localCap or decelCap
        envelope[k] = nextCap
    end
    s.laneCurveEnvelope, s.envelopeBuildCoast = nextCap, decel
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
    if not s.adaptive or s.dodging or s.threading or s.returnActive
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
        -- 減速剖面改用煞車反推（2026-09-02 s027 定罪＋使用者裁定「真的非常
        -- 接近彎道才要減速」）：舊制以 coast 0.6 m/s² 純滑行反推——70→20 的
        -- 彎要在 290m 外就鬆油＝「離彎還很遠速度卻很慢」。改 minBrake×0.7
        -- （保留三成執行餘裕給 bang-bang regulator 斷油＋剎車鏈），同樣的彎
        -- ~33m 前才開始減；超速真發生由 curve hard breach 紅線煞車兜底。
        local envDecel = minBrake * 0.7
        if envDecel < minCoast then envDecel = minCoast end
        envelopeOk = refreshLaneCurveEnvelope(s, envDecel, minLat)
        if envelopeOk then
            s.laneCurveStamp = sen.stamp
            -- scale 是「輪內 EWMA 再掉」的即時反應；envelope 重建已用最新
            -- safeLat／safeBrake×0.7 當基準，舊 scale 對新基準無意義。不歸 1 的話
            -- 歷史最低值跨輪永久黏住（2026-09-01 telemetry 001：低速中毒後
            -- lce 卡 0 四十八秒，恢復行駛也回不來）。
            s.laneEnvelopeScale = 1
        end
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
    -- 診斷：hold 原因去重記錄（band/unloaded/capacity/unsafe）——s031/s032 的
    -- return-suppress/unsafe 卡死若無此欄位無法離線歸因（2026-09-01）。
    if s.lastHoldReason ~= reason then
        s.lastHoldReason = reason
        diagEvent(s, s.playerNum, "return", { phase = "hold", why = reason,
            l = latSigned, s = s.lastSNow })
    end
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
-- 控制剖面（fstate）持有權仲裁（2026-09-02 使用者裁定「每個系統都要有優先級，
-- 不要打結互相影響」——st462.29k RETURN↔dodge 搶 fstate、s019 ROTATE 下 dodge
-- commit 132 次、st459.07k RETURN 死鎖三連環的統一收口）。
-- 優先序：ROTATE > DODGE(committed) > RETURN > free。
-- 契約：高優先級活躍時，低優先級不得寫 fstate（commit／clearOffset／
-- setExactLine）；returnHold＝回線走不了＝讓位（視同不持有）。各系統的安全
-- 由各自體系承擔：rotate=probeAround＋contact、dodge=世界掃掠終審、
-- return=sweep[return]；contact fail-closed 凌駕一切（targetSpeed 層）。
local function profileOwner(s)
    if s.fstate.rotating == true then return "rotate" end
    if s.dodging or s.threading then return "dodge" end
    if s.returnActive and not s.returnHold then return "return" end
    return "free"
end

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
    -- 持有權仲裁：ROTATE／DODGE 活躍時 RETURN 不得寫 fstate（st462.29k 定罪：
    -- holdUnsafeReturn 開頭的 clearOffset 每輪清掉剛 commit 的 dodge 剖面 →
    -- 釋放 → 重 commit → 又被清的原地死循環；s019 同型：ROTATE 下 RETURN cap
    -- 325 幀壓著調頭）。剖面釋放後 latDev 若仍大，RETURN 下一輪自然接手。
    local owner = profileOwner(s)
    if owner == "rotate" or owner == "dodge" then return end
    -- hold 停滯釋放（2026-09-02 s040/s041：調頭後 33° 斜姿、車頭 2.7m 外一截圍籬
    -- 落進 probeLateral 的側移聯集框，回線每輪驗不過＝WAIT 到 15s 紅字；使用者
    -- 推一下車讓框脫離圍籬才動）。hold 只是「這條回線現在走不了」，不是「不准動」：
    -- 靜止超過 RETURN_STALL_MS 就把 RETURN 交還 pure pursuit（laneBias＝target，
    -- 一般 contact／sweep／dodge／可視體系照管），冷卻期內不重入。
    if s.returnHold then
        if s.returnHoldSince == 0 then s.returnHoldSince = sen.stamp end
        local sp = vehicle:getCurrentSpeedKmHour()
        if finite(sp) and sp > -1 and sp < 1
                and sen.stamp - s.returnHoldSince >= TUNE.RETURN_STALL_MS then
            s.returnActive, s.returnUnsafe, s.returnHold = false, false, false
            s.returnCrawlExact, s.returnCapacityFault = false, false
            s.returnReason, s.returnClearRounds, s.returnHoldSince = nil, 0, 0
            s.returnBlockUntil = sen.stamp + TUNE.RETURN_STALL_BLOCK_MS
            MDADFollower.clearOffset(s.fstate)
            MDADFollower.setLaneBias(s.fstate, s.returnLaneTarget)
            s.sensor.scanBias = s.returnLaneTarget
            s.planMode = "return-stall"
            diagEvent(s, playerNum, "return", { phase = "release", why = "stall",
                l = latSigned, s = s.lastSNow })
            return
        end
    else
        s.returnHoldSince = 0
    end
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
    -- hold 理由記真正打槍的那道關（舊版把 buildReturnLine 的 "ok" 當理由，
    -- s040 復盤時 probe／sweep／line 三種失敗全長一樣）
    if lineN < 2 then
        holdUnsafeReturn(s, vehicle, laneStart, "line")
        return
    end
    if not probeReturnLateral(s, vehicle, laneTarget - laneStart) then
        holdUnsafeReturn(s, vehicle, laneStart, "probe")
        return
    end
    local safe = sweepLine(s, s.returnX, s.returnY, lineN, lineS0, lineS1,
        s0, s1, s1, coverageEnd, laneTarget, "return", s.sweepBase)
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
        holdUnsafeReturn(s, vehicle, laneStart, safe and "line" or "sweep")
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
    -- 回線完成點 d 允許落在 route 終點外（2026-09-01 s019/s020 兩層定罪：
    -- 先是 d+1>length 整包 coverage 打回；截斷 exit 後又因 1-2m 甩回側偏
    -- 的陡折曲率把 dodge cap 壓 0）。正解：exit 段不受 route 殘長鉗制，
    -- 折線只建到終點＝回線只走緩坡前半，曲率正常；帶側偏抵達由歐氏
    -- ARRIVE_M(5) 圈涵蓋。exit 僅受折點（exitPeak）與掃描窗（exitRoom）鉗。
    local entryAvail, exitAvail = b - minA, 1e9
    -- 空間延長不得把已避開折點的轉場再拉回跨越折點：entry 只能延到折點後
    -- 0.5m，exit 轉場整段停在下一折點前 2m（窗寬涵蓋整個可延長範圍，
    -- 也擋住原 a..d+6 窗外的新折點）。空間不足只壓速（entry/exit 皆無 minimum 門檻）。
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
    -- entry 側 minimum 門檻退役（2026-09-01 s052 近障礙定罪，對稱 exit 側
    -- s019）：車距障礙群 5m、側移 2.5m 時，crawl 最小過渡長（max(2×halfL,
    -- lLat)≈5.8-7m）永遠塞不進 entryAvail 2.8m → 每輪「curve dodge ok →
    -- sweep 全滅（shape false 假扮 hold fail）」→ blocked 停死→倒退→route
    -- 重算又縮回 5m 的死循環。正解同 exit：塞多少給多少（下限 1m），過渡
    -- 變陡由 shiftSpaceSpeedCapKmh 按實長連續壓速、世界掃掠 OBB 終審幾何。
    local entryLen = required > entryAvail and entryAvail or required
    if entryLen < 1 then entryLen = 1 end
    -- exit 側不設 minimum 門檻（2026-09-01 s019 近目標定罪：目標在回線段
    -- 內時 minimum 塞不進殘長 → dodge-cap 345 幀全放棄）。接受截斷回線：
    -- 帶側偏抵達由歐氏 ARRIVE_M(5) 圈涵蓋；空間短由 shiftSpaceSpeedCapKmh
    -- 自動轉成低速 cap，回線幾何仍由 sweepLine 世界複驗把關。
    local exitLen = required > exitAvail and exitAvail or required
    if exitLen > exitRoom then exitLen = exitRoom end
    if exitLen < 1 then exitLen = 1 end
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

-- 「擋線點」判定（plan 檔語意、單一定義）：|l - bias| < r + needHalf。
-- resolveBlockAnchor（lineOnly）、lineBlockerAhead（exit 提前釋放）共用；不得
-- 在 replan 內再手寫一份（190-local 閘門＋三份漂移風險）。
local function blocksLine(sen, i, bl, nh)
    local dl = sen.hardL[i] - bl
    if dl < 0 then dl = -dl end
    local r = sen.hardR and sen.hardR[i] or 0
    if type(r) ~= "number" or r ~= r or r < 0 then r = 0 end
    return dl < r + nh
end

-- 前方（弧長 ≥ minS）是否還有擋線點。O(hardN)、零配置；冷路徑（replan）用。
local function lineBlockerAhead(s, sen, minS)
    local bl, nh = laneBiasOf(s), s.needHalf
    for i = 1, sen.hardN do
        if sen.hardS[i] >= minS and blocksLine(sen, i, bl, nh) then return true end
    end
    return false
end

-- 蛇行折線終點（tryThread／crawlDeadEnd 共用一份定義）：掃描帶內最遠擋線點＋EXIT，
-- 上限 THREAD_COL_MAX 欄，再鉗到已載入區（折線尾＝末節點最多比 sTo 多一欄＋tail，
-- 落在 scanEndS／unloadedS 之外整條線判 unloaded＝失敗）。回 sTo（可能 ≤ sFrom）。
local function threadHorizon(s, sen, sFrom, sObs0)
    local bl, nh = laneBiasOf(s), s.needHalf
    local farS = finite(sObs0) and sObs0 or sFrom
    for i = 1, sen.hardN do
        local hs = sen.hardS[i]
        if hs > farS and blocksLine(sen, i, bl, nh) then farS = hs end
    end
    local sTo = farS + MDADCorridor.EXIT
    local maxTo = sFrom + MDADCorridor.THREAD_COL_MAX * MDADCorridor.THREAD_DS
    if sTo > maxTo then sTo = maxTo end
    local tail = s.vehicleProfile.halfL + 1
    local loadedEnd = visibleEndS(sen, sFrom)
    if sTo > loadedEnd - tail - MDADCorridor.THREAD_DS then
        sTo = loadedEnd - tail - MDADCorridor.THREAD_DS
    end
    if sTo > s.profile.length then sTo = s.profile.length end
    return sTo
end

-- 貼縫檔死路判定（2026-09-02）：繞行出口 d 之後路線若仍被擋，用 thread DP 當
-- oracle 問「從 d 到可見盡頭有沒有任何折線可走」。回 (true, 第一個擋線點索引)＝
-- 死路（貼縫進去也立刻再 blocked）；(false)＝出口後淨空或整段可走。DP 失敗原因只有
-- band／start／nopath 算死路；badargs／capacity 不判（fail-open：舊行為是允許）。
-- 只在貼縫承諾點呼叫（冷路徑，一次 DP）；work 陣列與 tryThread 共用（純暫存）。
local function crawlDeadEnd(s, sen, d)
    local bl, nh = laneBiasOf(s), s.needHalf
    local bi = nil
    for i = 1, sen.hardN do
        if sen.hardS[i] >= d + 1 and blocksLine(sen, i, bl, nh) then
            if bi == nil or sen.hardS[i] < sen.hardS[bi] then bi = i end
        end
    end
    if bi == nil then return false end
    if type(MDADCorridor.thread) ~= "function" then return false end
    local sTo = threadHorizon(s, sen, d, sen.hardS[bi])
    if sTo - d < 4 then return false end
    local planN = sen.hardN
    if s.pushBanL ~= nil then planN = planN + 1 end
    local need = s.squeezeNeed + MDADVehicleProfile.clearanceBudget("probe")
    local n, why = MDADCorridor.thread(
        sen.hardS, sen.hardL, sen.hardR, planN, need, MDADSensor.CORRIDOR_HALF,
        d, bl, sTo, s.vehicleProfile.halfL, s.vehicleProfile.halfW, bl,
        sen.roadLo, sen.roadHi, s.threadWork, s.threadS, s.threadL, TUNE.THREAD_NODES_MAX)
    if n >= 2 then return false end
    if why == "band" or why == "start" or why == "nopath" then return true, bi end
    return false
end

-- Candidate sweep and commitment consume the same complete preallocated line.
local function sweepCandidate(s, shapeOk, a, b, c, d, offL, baseL, tag, needBase)
    if not shapeOk then return 0, 0, false, 99, b, 3, b, 0, 0 end
    local ovN, ovS0, buildReason, lastCovered = MDADFollower.buildOffsetLine(
        s.profile, s.lastSNow, a, b, c, d, offL, baseL, s.tmpOvX, s.tmpOvY)
    s.dodgeBuildReason = buildReason
    -- 掃掠覆蓋要求鉗到 route 終點：d 可超出終點（近目標帶偏抵達），
    -- route 外沒有路要驗（2026-09-01）。
    local wantEnd = d + 1
    if wantEnd > s.profile.length then wantEnd = s.profile.length end
    if ovN < 2 or buildReason ~= "ok" or lastCovered < wantEnd - 1e-6 then
        if getDebug() then
            -- 無 log 的 build/coverage 打槍害 s051/s052 兩輪誤判 OBB——fail 必留痕
            print(string.format(
                "%ssweep build fail[%s] ovN=%d reason=%s covered=%.1f want=%.1f a=%.1f d=%.1f s0=%.1f off=%.2f",
                LOG, tostring(tag or "?"), ovN or 0, tostring(buildReason),
                lastCovered or -1, wantEnd, a, d, s.lastSNow or -1, offL))
        end
        return 0, ovS0, false, 99, b, 3, b, 0, 0
    end
    s.tmpOvEndS = lastCovered
    local ok, margin, hardS, phase, sampleS, hitX, hitY = sweepLine(
        s, s.tmpOvX, s.tmpOvY, ovN, ovS0, lastCovered,
        a, b, c, d, offL, tag, needBase)
    -- 貼縫檔（squeeze／physical）不得鑽進死路（2026-09-02 s064／s001 兩輪定罪：
    -- 車陣第一台以 margin 0.09 的貼縫承諾、4 km/h 爬 20m，出口落在第二排車前，
    -- 整段車陣 DP nopath——就算擠過第一台也立刻再 blocked，代價是 40s＋接觸＋
    -- 三次倒車 StopStuck）。貼縫是單一障礙的最後手段；出口之後路線仍被擋時，
    -- 先問「可見車陣整段有沒有路」（thread DP 當 oracle），沒路＝拒收→blocked→
    -- 改道／交還階梯，不浪費 40s 鑽進去。cruise 檔不受影響（速度不掉、下一段
    -- 由下一輪 plan 處理）；單一縫（出口後淨空）照 2026-09-01 裁定「物理可過即過」。
    if ok and needBase < s.sweepBase - 1e-6 then
        local deadEnd, bi = crawlDeadEnd(s, s.sensor, d)
        if deadEnd then
            local sen = s.sensor
            if getDebug() then
                print(string.format(
                    "%ssweep deadend[%s] offL=%.2f d=%.1f next blocker s=%.1f: crawl refused",
                    LOG, tostring(tag or "?"), offL, d, bi and sen.hardS[bi] or -1))
            end
            return ovN, ovS0, false, 0, bi and sen.hardS[bi] or d + 1, 4, d,
                bi and sen.hardX[bi] or 0, bi and sen.hardY[bi] or 0
        end
    end
    return ovN, ovS0, ok, margin, hardS, phase, sampleS, hitX, hitY
end

-- blocked 座標錨解析（plan／guard 共用；Kahlua 190-local 閘門逼出的抽取）：
-- 把「世界距車最近」的合格點寫進 s.blockHitX/Y（blockedNear 判距權威——
-- 弧長跨快照不可比、取 s 最小會挑到橫向邊緣點判距虛遠，兩案都實測定罪）。
-- lineOnly＝只收擋線點（blocksLine）；guard 檔收全部 minS 之後的前方點。
-- 回傳合格點中的最小弧長（guard 的 blockS 用）。
local function resolveBlockAnchor(s, sen, vehicle, lineOnly, minS)
    local bestD2, bi, bs
    local vx, vy = vehicle:getX(), vehicle:getY()
    local bl, nh = laneBiasOf(s), s.needHalf
    for i = 1, sen.hardN do
        local hs = sen.hardS[i]
        if (minS == nil or hs >= minS)
                and (not lineOnly or blocksLine(sen, i, bl, nh)) then
            if bs == nil or hs < bs then bs = hs end
            local dx, dy = sen.hardX[i] - vx, sen.hardY[i] - vy
            local d2 = dx * dx + dy * dy
            if bestD2 == nil or d2 < bestD2 then bestD2, bi = d2, i end
        end
    end
    if bi ~= nil then
        s.blockHitX, s.blockHitY = sen.hardX[bi], sen.hardY[bi]
    end
    return bs
end

-- 初判 blocked 的降檔複審（replan 抽出；190-local 閘門＋可獨立閱讀）：
-- squeeze plan＋sweep → physical plan＋sweep，第一個世界掃掠過的縫即 commit
-- 候選。回 ok, a, b, c, d, offL, sweepBase；ok=false 時不動任何 s 欄位。
-- refineComfort=true（2026-09-02 使用者「能走路面就別走草地」）：複審不是 ban
-- 重試，first-safe 後在同側找額外餘裕／偏回路面帶。降檔縫一律標 dodgeCrawl
-- （reserve 豁免＋intent CRAWL；速度仍由 clearance 連續縮放）。
local function demotePlan(s, sen, planN, prefer, baseL, playerNum)
    for tier = 1, 2 do
        local nu = tier == 1 and s.squeezeNeed
            or MDADVehicleProfile.planNeed(s.vehicleProfile.halfW, "physical")
        local nb = tier == 1 and s.squeezeSweepBase
            or MDADVehicleProfile.sweepBase(s.vehicleProfile.halfW, "physical")
        local mq, aq, bq, cq, dq, oq = MDADCorridor.plan(
            sen.hardS, sen.hardL, planN, nu, MDADSensor.CORRIDOR_HALF,
            prefer, sen.hardR, baseL, sen.roadLo, sen.roadHi, true)
        if mq == "dodge" and dq > s.lastSNow + 1 then
            local shapeQ
            aq, bq, cq, dq, shapeQ = shapeProfile(
                s, s.profile, aq, bq, cq, dq, oq, baseL)
            local ovN, ovS0, okQ, mgQ = sweepCandidate(
                s, shapeQ, aq, bq, cq, dq, oq, baseL,
                tier == 1 and "crawl" or "probe", nb)
            if okQ then
                s.dodgeMargin = mgQ
                s.dodgeCrawl = true
                s.lastOvN = ovN
                s.lastOvS0 = ovS0
                s.lastOvEndS = s.tmpOvEndS
                if getDebug() then
                    print(LOG .. "pn=" .. playerNum
                        .. " plan-blocked demotion commit: tier="
                        .. tier .. " offL=" .. string.format("%.2f", oq))
                end
                return true, aq, bq, cq, dq, oq, nb
            end
        end
    end
    return false
end

-- 車陣蛇行提案（2026-09-02 使用者「這麼多車沒辦法掃出一個地方鑽嗎」）：plan／
-- sweep 候選鏈全 blocked 之後的第二層。Corridor.thread 在 (s,l) 格點找斜率受限
-- 折線（DP，冷路徑）→ Follower.buildThreadLine 建世界折線 → sweepLine 世界 OBB
-- 掃掠（唯一否決權）→ setExactLine 承諾（同 RETURN 機制；threadX/Y 持有 identity）。
-- 兩檔需求：巡航 needHalf → 貼縫 squeezeNeed，皆加 probe 預算與 sweep 同源。
-- 無路＝THREAD_RETRY_MS 冷卻（DP 每次 ~ms 級，不每輪重跑）。回 true＝已承諾。
local function tryThread(s, vehicle, playerNum, sObs0, sObs1, now)
    local sen, prof = s.sensor, s.profile
    if type(MDADCorridor.thread) ~= "function"
            or type(MDADFollower.buildThreadLine) ~= "function" then return false end
    if now < s.threadNextMs then return false end
    local halfL = s.vehicleProfile.halfL
    local sFrom = s.lastSNow
    local laneFrom = s.lastLatSigned
    if not finite(laneFrom) then laneFrom = laneBiasOf(s) end
    -- 折線終點＝掃描帶內最遠擋線點＋EXIT（threadHorizon；與 crawlDeadEnd 同一定義）。
    -- 第一版用第一群出口（sObs1＋EXIT）：終欄成本把折線拉回基準線、走到末節點
    -- 釋放後下一群再蛇一次；lone car 後面緊接車陣時終欄落在車陣裡。
    local sTo = threadHorizon(s, sen, sFrom, sObs0)
    if not finite(sObs0) or sObs0 <= sFrom + 1 or sTo - sFrom < 4 then return false end
    local planN = sen.hardN
    if s.pushBanL ~= nil then planN = planN + 1 end -- 推撞 ban 點已在尾格（replan 寫入）
    local probe = MDADVehicleProfile.clearanceBudget("probe")
    local baseL = laneBiasOf(s)
    local lastWhy, lastN = "none", 0
    for pass = 1, 2 do
        local need = (pass == 1 and s.needHalf or s.squeezeNeed) + probe
        local n, why, minExtra, maxSlope = MDADCorridor.thread(
            sen.hardS, sen.hardL, sen.hardR, planN, need, MDADSensor.CORRIDOR_HALF,
            sFrom, laneFrom, sTo, halfL, s.vehicleProfile.halfW, baseL, sen.roadLo, sen.roadHi,
            s.threadWork, s.threadS, s.threadL, TUNE.THREAD_NODES_MAX)
        lastWhy, lastN = why, n
        if n >= 2 then
            local ln, lS0, reason, lS1 = MDADFollower.buildThreadLine(
                prof, sFrom, s.threadS, s.threadL, n, s.threadX, s.threadY, tail)
            local unloaded = not sen.ready or sen.scanEndS < lS1
                or (sen.unloaded and finite(sen.unloadedS) and sen.unloadedS <= lS1)
            if reason == "ok" and ln >= 2 and not unloaded then
                local safe = sweepLine(s, s.threadX, s.threadY, ln, lS0, lS1,
                    sFrom, sFrom, lS1, lS1, 0, "thread", need)
                if safe and MDADFollower.setExactLine(
                        s.fstate, s.threadX, s.threadY, ln, lS0, lS1) then
                    local cap = TUNE.THREAD_CAP_MIN_KMH
                    if pass == 1 then
                        local t = minExtra
                        if t < 0 then t = 0 elseif t > 1 then t = 1 end
                        cap = cap + (TUNE.THREAD_CAP_MAX_KMH - TUNE.THREAD_CAP_MIN_KMH) * t
                    end
                    s.threading, s.threadN = true, n
                    s.threadStartS, s.threadEndS = sFrom, lS1
                    s.threadDoneS = s.threadS[n]
                    s.threadCap, s.threadNeed = cap, need
                    s.threadGuardHardN = nil
                    s.dodging = false
                    s.blocked, s.blockedNotified = false, false
                    s.clearStreak = 0
                    s.planMode = "thread"
                    local playerObj = getSpecificPlayer(playerNum)
                    if playerObj then haloGood(playerObj, KEY_THREAD) end
                    diagEvent(s, playerNum, "thread", {
                        phase = "commit", s = sFrom, d = lS1, nodes = n,
                        extra = minExtra, slope = maxSlope, cap = cap, need = need,
                        why = pass == 1 and "cruise" or "squeeze" })
                    if getDebug() then
                        print(string.format(
                            "%spn=%d thread commit pass=%d nodes=%d s=%.1f..%.1f extra=%.2f slope=%.2f cap=%.0f",
                            LOG, playerNum, pass, n, sFrom, lS1, minExtra, maxSlope, cap))
                    end
                    return true
                elseif getDebug() then
                    print(string.format("%spn=%d thread pass=%d nodes=%d sweep rejected",
                        LOG, playerNum, pass, n))
                end
            elseif getDebug() then
                print(string.format("%spn=%d thread pass=%d line %s unloaded=%s",
                    LOG, playerNum, pass, tostring(reason), tostring(unloaded)))
            end
        elseif getDebug() then
            print(string.format("%spn=%d thread pass=%d no path (%s)", LOG, playerNum, pass, tostring(why)))
        end
    end
    s.threadNextMs = now + TUNE.THREAD_RETRY_MS
    diagEvent(s, playerNum, "thread", {
        phase = "fail", s = sFrom, d = sTo, why = lastWhy, nodes = lastN })
    return false
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
        -- exit 段淨空提前釋放（2026-09-02 s012-s014 定罪：dg 174-267 幀掛滿全程
        -- ——縫在 c 已通過、剖面回線段還沒走完就不放，commit 時的低 cap 綁死
        -- 整條直線）。條件＝「已進回歸段（>=offC）且前方無擋線點」（s016 補課：
        -- hardN==0 在有樹的街道永不成立——路緣樹不擋線也算 hard；擋線語意走
        -- blocksLine 單一定義）。與「不因 clear 提前釋放」的防抖契約不衝突：那條
        -- 防的是縫中途（<c）的抖動；過了 c 縫的幾何意義已結束，回線交回巡線由
        -- laneBias 平滑收斂。
        local exitClear = type(fs.offC) == "number" and s.lastSNow >= fs.offC
            and not lineBlockerAhead(s, sen, s.lastSNow)
        if curOffL == nil or type(fs.offD) ~= "number" or s.lastSNow >= fs.offD
                or exitClear then
            -- 剖面走完（或已被外部清除／exit 段淨空）：釋放承諾，本輪 fall
            -- through 正常規劃
            MDADFollower.clearOffset(fs)
            releaseDodge(s)
        else
            -- 承諾鎖定（2026-09-01 使用者最終裁定「找到空間訂好路線就不要變、
            -- 確定可過就全油門」）：靜態世界的承諾一經 commit 時完整驗證
            -- （plan＋shape＋世界掃掠）即鎖定——桿、牆不會自己移動，每輪
            -- 幾何重驗只是讓掃描量化相位重擲骰子（±5cm 抖動 × 邊際縫＝
            -- 「遠距 commit、一靠近就釋放」的一犯再犯根因，s016-s022 七輪）。
            -- 守護重驗只留給動態世界（移動車輛可能開進承諾線）；真接觸由
            -- contact fail-closed（currentBlocked → 立即停）兜底。
            local guardOk, guardMargin = false, 0
            if MDAD.sandbox("ObstaclePolicy", POLICY_DODGE) == POLICY_DODGE
                    and (fs.ovN or 0) >= 2 then
                if s.dodgeGuardHardN == nil then
                    s.dodgeGuardHardN = sen.hardN
                end
                -- 重驗條件：動態世界（移動車）或點雲顯著成長（streaming 載入
                -- 新障礙、玩家蓋牆——世界真的變了）；數量持平＝量化相位抖動
                -- ＝信任承諾。
                local worldGrew = sen.hardN > s.dodgeGuardHardN + 2
                if sen.movingVeh or worldGrew then
                    s.dodgeGuardHardN = sen.hardN
                    guardOk, guardMargin = sweepLine(
                        s, fs.ovX, fs.ovY, fs.ovN, fs.ovS0, fs.ovEndS,
                        fs.offA, fs.offB, fs.offC, fs.offD,
                        curOffL, "guard", s.dodgeNeed)
                    if not guardOk then
                        -- 帶餘裕守護失敗仍先做物理重驗：過＝續走。門檻同樣走
                        -- 餘裕預算 authority 的 physical 檔（階段 2 主體 4），
                        -- 不再自己寫 halfW-0.1。
                        guardOk = sweepLine(
                            s, fs.ovX, fs.ovY, fs.ovN, fs.ovS0, fs.ovEndS,
                            fs.offA, fs.offB, fs.offC, fs.offD,
                            curOffL, "guard-probe", MDADVehicleProfile.sweepBase(
                                s.vehicleProfile.halfW, "physical"))
                        if guardOk then guardMargin = s.dodgeMargin end
                    end
                else
                    -- 靜態且點雲持平：信任承諾，不重擲骰子
                    guardOk, guardMargin = true, s.dodgeMargin
                end
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
                -- 折線量化尖角的 curveCap 假 0 只該限速不該否決通行（近目標
                -- exit 壓縮定罪，同 replan 段）；爬行下限、contact 兜底。
                if curveCap < MDADDynamics.DODGE_CAP_FLOOR_KMH then
                    curveCap = MDADDynamics.DODGE_CAP_FLOOR_KMH
                end
                local visibilityCap = MDADDynamics.visibilityCapKmh(
                    visibleEndS(sen, s.lastSNow) - s.lastSNow,
                    0.5, minBrake, s.vehicleProfile.halfL)
                local dl = curOffL - laneBiasOf(s)
                if dl < 0 then dl = -dl end
                local sh = 0.05
                if finite(s.dodgeCommittedLength) and s.dodgeCommittedLength > 0 then
                    sh = 1.2 * dl / s.dodgeCommittedLength
                    if sh > 1 then sh = 1 end
                end
                local clearanceCap = MDADDynamics.clearanceCapKmh(
                    guardMargin,
                    (s.dodgeCrawl or s.dodgeTight) and 0
                        or TUNE.DODGE_CLEARANCE_RESERVE,
                    0.3, minLat, sh)
                local classId = sen.movingVeh
                    and MDADDynamics.DODGE_VEHICLE or MDADDynamics.DODGE_STATIC
                -- 速度隨餘裕連續縮放（one-size 爬行帽退役）：episode 下同縫
                -- margin 本來就小，clearanceCap 自然壓低。
                local newCap, _, capReason = MDADDynamics.dodgeSpeedCapKmh(
                    s.gearCap, s.profileEnvelope, curveCap, clearanceCap,
                    visibilityCap, classId)
                s.dodgeClearance, s.dodgeClass = guardMargin, classId
                s.dodgeCurveCap, s.dodgeClearanceCap = curveCap, clearanceCap
                s.dodgeVisibilityCap = visibilityCap
                -- 單向鎖移除（2026-09-02 s016 定罪：commit 時的 12.9 綁死全程、
                -- 世界變好也回不去——「直線才 11」主因之一）。cap 隨守護輪連續量
                -- 即時浮動；防 flap 由釋放條件獨立把守、目標抖動由 jerk limiter
                -- 平滑。dodgeBaseCap 只剩 telemetry 鏡像（schema 只加不改名）。
                s.dodgeSpeedCap = newCap
                s.dodgeBaseCap = newCap
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
                -- 線瞬跳，近停後才清（stepFollow 收尾）。煞停基準＝前方點中世界距
                -- 最近者的座標錨（blockedNear）：保留漸進接近（>BLOCK_STOP_DIST
                -- 滑行、內煞停）。繞行中前方遠處變堵死就地急煞不合理（隊友後車
                -- 追撞）；找不到前方障礙（政策中途改掉）才就地停。
                if not s.blocked then
                    s.blocked = true
                    s.blockS = resolveBlockAnchor(s, sen, vehicle, false, s.lastSNow)
                        or s.lastSNow
                    if not s.blockedNotified then
                        s.blockedNotified = true
                        local playerObj = getSpecificPlayer(playerNum)
                        if playerObj then haloBad(playerObj, KEY_BLOCKED) end
                        voice("blocked", playerNum)
                        diagEvent(s, playerNum, "blocked", {
                            s = s.blockS, m = s.dodgeMargin, need = s.dodgeNeed,
                            x = s.blockHitX, y = s.blockHitY, why = "guard",
                            corner = s.cornerLatch })
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
    -- ===== 蛇行承諾（exactLine）：與 dodge 同樣不可變，只做守護 =====
    if s.threading then
        local fs = s.fstate
        if fs.exactLine ~= true or s.lastSNow >= s.threadDoneS then
            MDADFollower.clearOffset(fs)
            releaseThread(s)
            s.planMode = "thread-done"
            diagEvent(s, playerNum, "thread", { phase = "done", s = s.lastSNow })
            if getDebug() then print(LOG .. "pn=" .. playerNum .. " thread released (line done)") end
            -- fall through：本輪照常規劃
        else
            if s.threadGuardHardN == nil then s.threadGuardHardN = sen.hardN end
            local worldGrew = sen.hardN > s.threadGuardHardN + 2
            if sen.movingVeh or worldGrew then
                s.threadGuardHardN = sen.hardN
                local guardOk = sweepLine(s, fs.ovX, fs.ovY, fs.ovN, fs.ovS0, fs.ovEndS,
                    s.threadStartS, s.threadStartS, fs.ovEndS, fs.ovEndS, 0,
                    "thread-guard", s.threadNeed)
                if not guardOk then
                    guardOk = sweepLine(s, fs.ovX, fs.ovY, fs.ovN, fs.ovS0, fs.ovEndS,
                        s.threadStartS, s.threadStartS, fs.ovEndS, fs.ovEndS, 0,
                        "thread-guard-probe", MDADVehicleProfile.sweepBase(
                            s.vehicleProfile.halfW, "physical"))
                end
                if not guardOk then
                    -- 世界變了且物理檔也過不去：釋放承諾、交回本輪常規規劃
                    -- （多半 blocked 煞停；車還在動時 exactLine 由 blocked 分支近停後清）
                    releaseThread(s)
                    s.planMode = "thread-fail"
                    diagEvent(s, playerNum, "thread", { phase = "fail", s = s.lastSNow, why = "guard" })
                    if getDebug() then print(LOG .. "pn=" .. playerNum .. " thread guard failed") end
                else
                    s.planMode = "thread"
                    return
                end
            else
                s.planMode = "thread"
                return
            end
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
        -- 貼縫前置（2026-09-01 telemetry s018 定罪：blocked m=0.1 vs need=1.1
        -- ——縫全寬 2.4m、車寬 1.8m，正常玩家開得過；巡航需求判死後貼縫遍
        -- 根本沒上場就 blocked）。巡航縫無解時先用 squeezeNeed（halfW+0.10）
        -- 重試一遍：判得過＝貼縫提案（速度由 clearance/curve cap 自然裁決；
        -- 2026-09-01 使用者裁定「確定可過就全油門」，不固定壓爬行檔），
        -- 判不過才進 blocked 停等。
        if mode ~= "dodge" and mode ~= "clear" then
            local ms, as_, bs, cs, ds, os_ = MDADCorridor.plan(
                sen.hardS, sen.hardL, planN, s.squeezeNeed,
                MDADSensor.CORRIDOR_HALF, prefer, sen.hardR, baseL,
                sen.roadLo, sen.roadHi, s.pushBanL == nil)
            if ms == "dodge" then
                mode, a, b, c, d, offL = ms, as_, bs, cs, ds, os_
                needUsed = s.squeezeNeed
            end
        end
        -- 彎道繞行：障礙群（b..c＝含保持餘裕的實體範圍）落在彎道段時，用放大的
        -- 需求半寬重算——內輪差與切內彎吃掉的餘裕先扣掉再判縫隙。判得過＝採
        -- 加嚴縫（位置更保守）；判不過＝**沿用普通縫降級爬行**，不直接 blocked
        -- ——內輪差的一階補償在爬行速度下大幅縮小，真擦撞由 sweepLine 世界
        -- 空間複驗把關（2026-08-28 實機：彎道兩台並排車，普通縫過得去卻被
        -- 加嚴判死 → blocked → 煞停 → 卡死脫困鬼打牆；使用者定案：有障礙時
        -- 允許離開道路繞行）。兩種 case 都標 dodgeTight（reserve 豁免；速度連續縮放）。
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
            if getDebug() then
                print(LOG .. "pn=" .. playerNum
                    .. " dodge profile behind car: clear (d="
                    .. string.format("%.1f rs=%.1f", d, s.lastSNow))
            end
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
        local sweptChain = mode == "dodge" -- 初判 dodge＝進候選鏈（降檔含於鏈內）
        if mode == "dodge" then
            -- sweep base 與 plan need 同源（階段 2 主體 4）：needUsed 可能已含
            -- 彎道加碼 CURVE_NEED_EXTRA，probe 預算照樣只扣這一次。
            local needBase = needUsed + MDADVehicleProfile.clearanceBudget("probe")
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
                if not committed then
                    -- 物理終審（2026-09-01 使用者最終裁定「視覺上有空間就該過」；
                    -- s016-s020 五輪逐層定罪：2.4m 縫對 1.8m 車被各層 5-15cm 餘裕
                    -- 疊加判死）。規劃餘裕是舒適預算不是物理極限：全部帶餘裕候選
                    -- 被世界掃掠打回後，用「接受剮蹭」的物理半寬（halfW-0.1，
                    -- 名義重疊 10cm——桿類 sprite 實體小於佔格半徑）做最後一次
                    -- plan+掃掠。過＝貼縫爬行擠過去，低速真撞由 contact
                    -- fail-closed／unstick 鏈兜底（正常玩家同款：看著過得去就開，
                    -- 擦到就擦到）。不過＝真 blocked。
                    -- 餘裕預算單一 authority（階段 2 主體 4）：物理終審檔的
                    -- need＝純車身（predicate 0 舒適預算），base＝再加 probe
                    -- 剮蹭預算 -0.1。舊制這裡是 halfW+0.05／halfW-0.1 兩個各自
                    -- 挑的常數；base 值不變，need 少扣那 5cm 舒適餘裕（真正的
                    -- 物理裁決者是 base 的世界掃掠，need 只負責枚舉候選）。
                    local probeNeed =
                        MDADVehicleProfile.planNeed(s.vehicleProfile.halfW, "physical")
                    local probeBase =
                        MDADVehicleProfile.sweepBase(s.vehicleProfile.halfW, "physical")
                    local mp, pa2, pb2, pc2, pd2, po2 = MDADCorridor.plan(
                        sen.hardS, sen.hardL, planN, probeNeed,
                        MDADSensor.CORRIDOR_HALF, prefer, sen.hardR, baseL,
                        sen.roadLo, sen.roadHi, false)
                    if mp == "dodge" then
                        local shapeP
                        pa2, pb2, pc2, pd2, shapeP = shapeProfile(
                            s, s.profile, pa2, pb2, pc2, pd2, po2, baseL)
                        local okP, mgP
                        ovN, ovS0, okP, mgP = sweepCandidate(
                            s, shapeP, pa2, pb2, pc2, pd2, po2, baseL,
                            "probe", probeBase)
                        if okP then
                            a, b, c, d, offL = pa2, pb2, pc2, pd2, po2
                            committed = true
                            commitNb = probeBase
                            s.dodgeMargin = mgP
                            s.dodgeCrawl = true -- 物理檔＝貼縫爬行（margin < 舒適 reserve 是常態）
                            s.lastOvN = ovN
                            s.lastOvS0 = ovS0
                            s.lastOvEndS = s.tmpOvEndS
                            if getDebug() then
                                print(LOG .. "pn=" .. playerNum
                                    .. " physical probe commit: squeeze-through at offL="
                                    .. string.format("%.2f", offL))
                            end
                        end
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
        -- 初判無縫降檔複審（2026-09-01 s045 定罪）：cruise 檔 plan 直接回
        -- blocked 時（最佳縫 m < cruise need），squeeze／physical 檔從未被
        -- 問過——0.95m 縫對 need 1.1 判死，但 squeeze need 0.9 本可過。候選
        -- 鏈只在初判 dodge 時跑，這裡補同款降檔（demotePlan）。sandbox 禁繞行
        -- 時不複審；鏈內已降過檔的失敗不重試。
        if mode == "blocked" and not sweptChain
                and MDAD.sandbox("ObstaclePolicy", POLICY_DODGE) == POLICY_DODGE then
            local okD, aD, bD, cD, dD, oD, nbD = demotePlan(
                s, sen, planN, prefer, baseL, playerNum)
            if okD then
                mode, a, b, c, d, offL, commitNb = "dodge", aD, bD, cD, dD, oD, nbD
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
            -- 近目標定罪（2026-09-01 實測＋console `dodge cap zero: curve=0.0
            -- clear=20.6`）：終點近時繞行線 exit 段被壓縮（15m 內回線）→ 折角
            -- 量化尖角讓 polylineKappaMax 假爆 → curveCap=0 把「已過世界掃掠
            -- 的可行縫」整條否決成 blocked；目標移遠 exit 拉長就過＝幾何 artifact
            -- 非真危險。curveCap 的職責是限速不是否決通行——sweep 是通行終審，
            -- 此處抬到 DODGE_CAP_FLOOR_KMH（15；橫向力有限、contact fail-closed 兜底）。
            if curveCap < MDADDynamics.DODGE_CAP_FLOOR_KMH then
                curveCap = MDADDynamics.DODGE_CAP_FLOOR_KMH
            end
            local visible = visibleEndS(sen, s.lastSNow) - s.lastSNow
            local visibilityCap = MDADDynamics.visibilityCapKmh(
                visible, 0.5, minBrake, vp.halfL)
            local dl = offL - baseL
            if dl < 0 then dl = -dl end
            local sinHeading = 0.05
            if finite(s.dodgeCommittedLength) and s.dodgeCommittedLength > 0 then
                sinHeading = 1.2 * dl / s.dodgeCommittedLength
                if sinHeading > 1 then sinHeading = 1 end
            end
            -- 爬行／物理／彎道爬行檔（2026-09-01）：貼縫擠過的 margin 天生小於
            -- 舒適 reserve——再扣 reserve 必得 0 速、把已 commit 的可行縫打回
            -- blocked 卡死（降檔複審案 margin 0.05；s051 curve dodge 每輪 plan ok
            -- 卻永不 commit、無 log 死在這行）。爬行檔的誤差預算已由 sweep 的
            -- 量化補償吃掉，此處 reserve 歸零。dodgeTight＝彎道爬行，同豁免。
            local clearanceCap = MDADDynamics.clearanceCapKmh(
                s.dodgeMargin,
                (s.dodgeCrawl or s.dodgeTight) and 0 or TUNE.DODGE_CLEARANCE_RESERVE,
                0.3, minLat, sinHeading)
            local profileCap = s.profileEnvelope
            local spaceCap = s.dodgeSpaceCap
            -- 空間公式只壓速不否決（2026-09-01 s053 定罪：margin/curve/clear/vis
            -- 全 >0、cap 仍 0——兇手是 shiftSpaceSpeedCapKmh 的 vSteer 對陡切
            -- 解析出 κ=1.9 超轉向極限回 0。它是「單一 S 彎」解析假設；真實
            -- 折線曲率已由 polylineKappaMax→curveCap（含爬行下限）量測、幾何
            -- 由 sweep OBB 終審。同 curveCap 刀型：夾爬行下限。
            if finite(spaceCap) and spaceCap < MDADDynamics.DODGE_CAP_FLOOR_KMH then
                spaceCap = MDADDynamics.DODGE_CAP_FLOOR_KMH
            end
            if finite(spaceCap) and spaceCap < profileCap then
                profileCap = spaceCap
            end
            local classId = sen.movingVeh
                and MDADDynamics.DODGE_VEHICLE or MDADDynamics.DODGE_STATIC
            s.dodgeKappa, s.dodgeClearance = kappa, s.dodgeMargin
            s.dodgeCurveCap, s.dodgeClearanceCap = curveCap, clearanceCap
            s.dodgeVisibilityCap, s.dodgeClass = visibilityCap, classId
            local capReason
            -- 速度隨餘裕連續縮放（one-size 爬行帽退役；同守護輪契約）。
            s.dodgeSpeedCap, _, capReason = MDADDynamics.dodgeSpeedCapKmh(
                s.gearCap, profileCap, curveCap, clearanceCap, visibilityCap,
                classId)
            if capReason == "dynamics-invalid" then
                s.invalid, s.stateError, s.dynamicsFault =
                    true, "dodge-cap", true
            end
            if s.dodgeSpeedCap <= 0 then
                mode = "blocked"
                s.dodgeBlockReason = capReason or "dodge-cap"
                s.planSig = -1
                if getDebug() then
                    -- s051 教訓：這條降級原本零 log——「plan ok 卻永遠 blocked」
                    -- 追了一輪才鎖定。cap 分解一行印清楚。
                    print(string.format(
                        "%spn=%d dodge cap zero: %s margin=%.2f curve=%.1f clear=%.1f vis=%.1f space=%.1f gear=%.1f prof=%.1f",
                        LOG, playerNum, tostring(s.dodgeBlockReason),
                        s.dodgeMargin or -1, curveCap, clearanceCap, visibilityCap,
                        s.dodgeSpaceCap or -1, s.gearCap or -1, s.profileEnvelope or -1))
                end
            end
        end
        -- 持有權仲裁（統一收口，取代點狀互斥）：dodge commit 只在剖面自由
        -- （free）時允許——ROTATE 持有＝調頭姿態下走廊反向掃、剖面無意義
        -- （s019：commit 132 次搶 fstate）；RETURN 持有（active 且非 hold）＝
        -- 維持「優先回線」原契約；returnHold＝回線走不了＝讓位 dodge
        -- （st459.07k 死鎖修）。各系統安全由各自體系承擔（仲裁註解）。
        local owner = profileOwner(s)
        if owner == "rotate" and mode == "dodge" then
            mode = "blocked"
            s.planMode = "rotate-suppress"
            if getDebug() then
                print(LOG .. "pn=" .. playerNum .. " rotate-suppress eats dodge")
            end
        end
        if owner == "return" then
            if getDebug() and mode == "dodge" then
                print(LOG .. "pn=" .. playerNum
                    .. " return-suppress eats dodge (latDev return active)")
            end
            releaseDodge(s)
            s.clearStreak = 0
            s.planMode = "return-suppress"
            return
        elseif s.returnActive and mode == "dodge" and getDebug() then
            print(LOG .. "pn=" .. playerNum
                .. " return line blocked: dodge takes over")
        end
    end
    if mode == "dodge" then
        -- setOffset 引數不合法回 false（不動 state）：此時寧可當 blocked 煞停，
        s.clearStreak = 0
        -- 也不能無側偏直直開進障礙
        local coverEnd = d + 1
        if coverEnd > s.profile.length then coverEnd = s.profile.length end
        if MDADFollower.setOffset(s.fstate, a, b, c, d, offL,
                s.tmpOvX, s.tmpOvY, s.lastOvN or 0, s.lastOvS0 or 0,
                s.lastOvEndS or 0, coverEnd) then
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
        if getDebug() then
            print(string.format(
                "%spn=%d setOffset REJECTED a=%.1f b=%.1f c=%.1f d=%.1f offL=%.2f ovN=%s ovS0=%s ovEnd=%s",
                LOG, playerNum, a, b, c, d, offL,
                tostring(s.lastOvN), tostring(s.lastOvS0), tostring(s.lastOvEndS)))
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
        s.blockHitX, s.blockHitY = nil, nil
        s.planMode = s.currentBlocked and "current-blocked" or "clear"
        return
    end
    s.clearStreak = 0
    -- 車陣蛇行：候選鏈全 blocked、無承諾持有者、車身尚未接觸時，試一次折線穿越
    -- （無路走 THREAD_RETRY_MS 冷卻）。承諾成功＝本輪結束；失敗照常 blocked 停等。
    if mode == "blocked" and not s.currentBlocked and profileOwner(s) == "free"
            and MDAD.sandbox("ObstaclePolicy", POLICY_DODGE) == POLICY_DODGE then
        if tryThread(s, vehicle, playerNum, a, d, getTimestampMs()) then return end
    end
    -- blocked：清側偏、漸進接近後煞停等待（掃描持續，障礙消失自動恢復；玩家接手
    -- 走讓位）。停等判距以「車到群最近 hard 點的世界距離」為權威（blockedNear；
    -- 投影弧長在繞遠／橫偏時虛高——s045 弧長差 1m/世界 18m）：>BLOCK_STOP_DIST
    -- 先滑行接近，掃描逼近後的縫隙判定比 30 公尺外那輪準（覆蓋完整、量化誤差小）。
    MDADFollower.clearOffset(s.fstate)
    s.dodging = false
    s.dodgeNotified = false
    releaseThread(s)
    s.blocked = true
    -- a＝Corridor blocked 時的 sObs0；缺 Corridor 的保守分支沒有 a → 0＝立即煞停
    s.blockS = a or 0
    -- 群最近擋線點世界座標＝blockedNear 判距權威（s051 定罪：blockS 是判定輪
    -- 快照的弧長、hardS 是當前快照的弧長，車一動兩基準脫節）。每輪 blocked 都
    -- 重掃（車接近時錨跟著新快照走）；掃不到擋線點（保守分支）留 nil → 退弧長。
    resolveBlockAnchor(s, sen, vehicle, true, nil)
    s.planMode = "blocked"
    if not s.blockedNotified then
        s.blockedNotified = true
        local playerObj = getSpecificPlayer(playerNum)
        if playerObj then haloBad(playerObj, KEY_BLOCKED) end
        voice("blocked", playerNum)
        -- wd＝車到群最近擋線點世界距（blockedNear 第二回傳；退弧長時 nil）——
        -- 復盤「該滑行還是該停」一眼定生死
        local _, wd = MDADDynamics.blockedNear(
            s.blockS, s.lastSNow, TUNE.BLOCK_STOP_DIST,
            vehicle:getX(), vehicle:getY(), s.blockHitX, s.blockHitY)
        diagEvent(s, playerNum, "blocked", {
            s = s.blockS, m = s.dodgeMargin, need = s.dodgeNeed,
            x = s.blockHitX, y = s.blockHitY, why = "plan", wd = wd,
            hn = s.sensor and s.sensor.hardN or 0,
            corner = s.cornerLatch })
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
        s.lastLatSigned = latSigned -- replan（thread 起點 lane）用
        local available = 2
        if finite(s.currentSegWidth) and s.currentSegWidth > 0 then
            -- 路面邊緣餘裕與障礙淨距是不同概念（前者是「不要壓到路肩」），
            -- 用 Dynamics 的具名常數而非裸字面值，避免與餘裕預算混為一談。
            available = s.currentSegWidth * 0.5 - s.vehicleProfile.halfW
                - MDADDynamics.ROAD_EDGE_MARGIN
        end
        -- 地板 1→2（2026-09-01，telemetry s031）：v4 segWidth=5 的路口窄段讓
        -- 門檻縮到 1.2m，正常切彎 2.9m 偏差就進 RETURN 慢速爬——路口本來就會
        -- 偏離 nav 折線，2m 起跳才不過敏。
        if available < 2 then available = 2 elseif available > 3 then available = 3 end
        local absDev = latDev
        if absDev < 0 then absDev = -absDev end
        -- 兩道護欄（2026-09-01 telemetry 定案）：>RETURN_MAX_DEV 交 pure pursuit
        -- （s030 帶蓋不住）；車頭正在調頭時 RETURN 不得劫持——s032：target
        -- 反向後 lat=8.95 進 RETURN，rotate 永遠沒機會跑，unsafe hold 卡 0 到
        -- 紅字。調頭優先，回線等頭擺正再說。
        -- 階段 2 主體 6：調頭姿態的唯一權威是 Follower 的 fstate.rotating
        -- （135° 進／100° 出遲滯）。Driver 自己那條 90° 門檻已刪——兩套門檻在
        -- 90-135° 匯流區各說各話，是「Driver 認為在調頭、Follower 還在跟線」
        -- 這類互相打架的來源。
        -- 偏頭門檻量「車頭對路線切線」——不是 pursuit 誤差：大側偏時前視點方向
        -- 本來就斜（12m 偏差 ≈ 50°），拿它當門檻會把 RETURN 該服務的偏差全擋掉。
        local routeErr = heading - (s.profile.segH[segI] or heading)
        if routeErr > math.pi then routeErr = routeErr - 2 * math.pi
        elseif routeErr < -math.pi then routeErr = routeErr + 2 * math.pi end
        if routeErr < 0 then routeErr = -routeErr end
        if not s.returnActive and not s.threading and absDev > available
                and absDev <= TUNE.RETURN_MAX_DEV
                and s.fstate.rotating ~= true
                -- 脫困冷卻（2026-09-01 telemetry s046：pm=guard 230 筆——unstick
                -- 倒 4m 製造 2-4m 偏差→又進 RETURN 慢速爬→又停滯→又 unstick
                -- 的互相餵養循環）。settle 起算 ~10s 內交 pure pursuit 正常追線。
                and now >= s.settleUntil + 6000
                -- 偏頭門檻＋stall 冷卻（2026-09-02 s040，理由見 TUNE.RETURN_ENTER_MAX_RAD）
                and routeErr <= TUNE.RETURN_ENTER_MAX_RAD
                and now >= s.returnBlockUntil
                and returnAvailable(s)
                -- 原始折點 ±RETURN_CORNER_M 內不進（放最後：只有前面全過才掃折線）
                and turnPeakS(s.profile, s.lastSNow - TUNE.RETURN_CORNER_M,
                    s.lastSNow + TUNE.RETURN_CORNER_M) == nil then
            -- pending＝unsafe crawl（≤RETURN_UNSAFE_CAP、沿當下 lane 直行），不是 hold：
            -- 舊制進入即 hold→WAIT→forceBrake，等下一輪快照 commit 再起步，每次進
            -- RETURN 都付一次「煞到 1 km/h」（s046 彎中 14.5→0.6 km/h）。回線走不走
            -- 得了由快照決定（commit／holdUnsafeReturn），這 ≤300ms 窗由 contact
            -- 探測與一般體系照管。
            s.returnActive, s.returnUnsafe, s.returnHold = true, true, false
            s.returnStartS, s.returnEndS = s.lastSNow, s.lastSNow
            s.returnLaneStart, s.returnLaneTarget = latSigned, laneBiasOf(s)
            s.returnReason = s.surfaceMismatch and "lateral+mismatch" or "lateral"
            s.returnCapacityFault = false
            s.returnClearRounds = 0
            s.lastHoldReason = nil
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
                elseif (s.sensor.roadN or 0) >= 40 then
                    -- 路口／寬路（2026-09-01 圖 1/2 定罪「路線不沿路＋路口卡死
                    -- 總在同處爆」）：路面樣本充足但兩緣不可見＝無從對中——
                    -- 保持上一段的置中偏置穿越（路中心線連續）。舊行為衰減回 0
                    -- ＝nav 貼緣線裸奔，路緣家具（栓／桿／牌）全貼行駛線，
                    -- blocked 群機制性地在每個路口引爆。
                else
                    s.roadBias = s.roadBias * TUNE.ROAD_DECAY
                end
                local nb = s.sandBias + s.roadBias
                if nb > TUNE.BIAS_MAX then nb = TUNE.BIAS_MAX
                elseif nb < -TUNE.BIAS_MAX then nb = -TUNE.BIAS_MAX end
                -- 枚舉的邊界判定跟著抖。承諾釋放後恢復跟隨。
                if s.dodging or s.threading or s.returnActive then nb = laneBiasOf(s) end
                MDADFollower.setLaneBias(s.fstate, nb)
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
                if s.sensor.sig ~= s.planSig or s.clearStreak > 0 or s.dodging or s.threading then
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
            if s.threading then
                if s.lastSNow >= s.threadDoneS or s.fstate.exactLine ~= true then
                    MDADFollower.clearOffset(s.fstate)
                    releaseThread(s)
                    if getDebug() then
                        print(LOG .. "pn=" .. playerNum .. " thread released (line done)")
                    end
                else
                    local tcap = s.threadCap
                    if not finite(tcap) or tcap < 0 then tcap = 0 end
                    s.lastDcap = tcap
                    if cap < 0 or tcap < cap then
                        cap = tcap
                        capReason = "thread"
                    end
                end
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
                    -- 接近段用煞車減速度反推的**單調**envelope（2026-09-02 s064）：
                    -- 舊制以 safeCoast（0.6，純滑行）算 slowZone 再二值套帽——43 km/h
                    -- 下 slowZone≈118m，縫還在 20m 外就被壓到 4 km/h；且門檻二值＝
                    -- 減速→zone 縮→解帽→加速→套帽的自激震盪（telemetry tgt 43↔4.23
                    -- 逐幀交替）。改成「到 offA 之前要降到 dcap，現在最多多快」，
                    -- 縫遠不壓速、縫近連續收斂；縫本身的帽仍是 dcap。
                    local applied = dcap
                    local fsA = s.fstate.offA
                    if finite(fsA) and s.lastSNow < fsA then
                        local decel = s.safeBrake
                        if not finite(decel) or decel <= 0 then decel = 0.6
                        else decel = decel * TUNE.APPROACH_BRAKE_FRAC end
                        applied = MDADDynamics.approachCapKmh(
                            fsA - s.lastSNow - s.vehicleProfile.halfL,
                            dcap, 0.5, decel)
                    end
                    s.dodgeApproachCap = applied
                    if cap < 0 or applied < cap then
                        cap = applied
                        capReason = "dodge"
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
            if targetSpeed > returnCap then
                targetSpeed = returnCap
                s.lastCapReason = s.returnUnsafe and "return-unsafe" or "return"
            end
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
                    and finite(s.safeBrake) and s.safeBrake >= 0
                    and finite(buildLat) and buildLat >= 0
                    and finite(buildCoast) and buildCoast >= 0) then
                fullValid = false
            else
                if buildLat > 0 and s.safeLat < buildLat then
                    scaleCandidate = sqrt(s.safeLat / buildLat)
                end
                -- buildCoast 現為煞車系合成減速度（minBrake×0.7，見 proof 端）：
                -- runtime 比對基準同步用 safeBrake×0.7——EWMA 煞車掉了才縮
                -- envelope；safeCoast 與此基準無關（滑行不再是減速剖面主體）。
                local runDecel = finite(s.safeBrake) and s.safeBrake * 0.7 or -1
                if buildCoast > 0 and runDecel >= 0 and runDecel < buildCoast then
                    local decelScale = sqrt(runDecel / buildCoast)
                    if decelScale < scaleCandidate then scaleCandidate = decelScale end
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
            -- horizon 戳記不匹配（route/regime 剛換、快照未及重算 minima）時
            -- 用 safeBrake（真煞車能力 prior，只緊不鬆）而非 0——歸 0 會讓
            -- visibilityCap 崩 0、目標壓停，progress 監督再把停誤判成卡死
            -- → 無障礙也倒車脫困的 2.5s 循環（2026-09-01 telemetry s056：
            -- capReason visibility 342 筆、suspect hit=clear 全程）。
            local minBrakeVisible = s.horizonStamp == s.sensor.stamp
                and s.horizonMinBrake
                or (finite(s.safeBrake) and s.safeBrake >= 0 and s.safeBrake or 0)
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
            -- 終點不是障礙（2026-09-01 s058 定罪）：可視帶已含路線終點且終點前
            -- 無 unloaded 截斷時，把近終點 visibilityCap 地板到爬行檔（squeeze
            -- 同檔 12）。不地板的話 ARRIVE_M(5)~8m 環帶被壓到 3-5 km/h，而引擎
            -- regulator 是 bang-bang（throttle 固定 0.5、超速斷油掛 N，
            -- CarController.java:240-245、522），實際輸出僅 ~0.3m/s 蠕動 →
            -- 監督誤判卡死 → 倒車吐回 20m，永遠進不了 reached 圈。「停在終點」
            -- 由剖面制動與 reached 的 hardCap 0 負責；blocked／contact outrank。
            if not reached and finite(remaining)
                    and remaining <= MDADFollower.ARRIVE_M + 3
                    and visibleEnd >= s.profile.length - 0.5 then
                local crawl = MDADDynamics.DODGE_SQUEEZE_CAP
                if visibilityCap < crawl then visibilityCap = crawl end
            end
            -- 調頭豁免（2026-09-01 s060 定罪：err 118° 時 tgt 恆 0、僵死 15 秒
            -- 後紅字）：調頭姿態車頭朝路線反向，前向掃描帶可視弧長天然 ≈0，
            -- visibility 壓 0 不是「看不到路」是幾何必然。地板到爬行檔讓大弧
            -- 前進轉有速度可用；原地轉安全由 probeAround 管、前方障礙由
            -- contact／sweep 管。err 收斂回 90° 內即恢復正常 visibility 裁決。
            if s.fstate.rotating == true then
                local crawl = MDADDynamics.DODGE_SQUEEZE_CAP
                if visibilityCap < crawl then visibilityCap = crawl end
            end
            stopEnd = s.lastSNow + MDADDynamics.stoppingDistance(
                fullTarget / 3.6, tau, minBrakeVisible, s.vehicleProfile.halfL)
            if stopEnd > s.profile.length then stopEnd = s.profile.length end
            brakeLoaded = finite(minBrakeVisible) and minBrakeVisible > 0
                and visibleEnd >= stopEnd
            -- hardN spans the planner's full +/-7m search band, not the driven lane.
            -- verifySweep owns hard-obstacle safety; the sensor cap stack above owns
            -- moving vehicles, zombies, corpses and soft objects.
            -- dodging 不再打斷 corridor bit：繞行有自己的 dodgeSpeedCap／
            -- immutable line 掃掠證明，再疊 gate 15 是雙重懲罰（2026-09-01）。
            corridorClear = not s.blocked
            -- dodge／RETURN 期間 proof 早退、verifySweep 凍舊值——obb bit 若不
            -- 讓位，繞行全程被警戒帽 18 蓋在 dodge/return cap 上（2026-09-02
            -- s010/s011）。s027 補課：自由巡線的「遠處」sweep 命中也不該連坐
            -- ——第三子句＝驗證前綴已蓋住煞停視界（與下方 pathVerified 同一
            -- 判式）＝近場安全已證。整個 obbClear 是「verifySweep／非 adaptive／
            -- pathVerified／dodge／return 讓位」的 OR，不等於 pathVerified 本身
            -- （收成同式會吃掉 dodge/return 讓位）。
            obbClear = ((not s.adaptive or s.verifySweep
                    or s.curveVerifiedUntilS >= stopEnd)
                or s.dodging or s.threading or s.returnActive) and not s.currentBlocked
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
        elseif absHeading > MDADDynamics.ALIGN_BREAK_RAD
                or absDev > latTol * 1.25 then
            -- 非對稱遲滯（2026-09-01）：5°/latTol 進入、8°/1.25×latTol 才重置。
            -- 路網折線與轉向雜訊在 5-8° 之間抖動時不再歸零 250ms 計時器，
            -- full-speed 資格不因單幀雜訊反覆得而復失。
            s.alignSince = 0
        end
        local aligned = s.alignSince > 0
            and now - s.alignSince >= MDADDynamics.ALIGN_HOLD_MS
        -- 進度證明只排除「已確認卡住」的狀態：suspect（2.5s 無進度探測中）、
        -- recover、gear-reset。watch/verify/disarmed 都算健康——舊判定要求
        -- 「watch 且 1s 內剛確認過進度」，正常巡航每 1s 就掉一次 full gate
        -- （2026-09-01 三模型對抗審）。卡死升級鏈另有 PROGRESS_MS=2500 守。
        local progressHealthy = s.progressState ~= "suspect"
            and s.progressState ~= "recover"
            and s.progressState ~= "gear-reset"
        local pathVerified = s.curveVerifiedUntilS >= stopEnd
        -- 三個 proof bit 用 verifyLineReason 消歧（2026-09-01 三模型對抗審）：
        -- buildSnapshotProof 是 min-of-failures，band 層先截斷會讓 verifySweep
        -- 連坐 false——bit 全交給 gate 會把「證明品質不足」搶成 "sweep" 15。
        --   sweep bit＝近場未知（掃掠真命中／未載入）→ 15 地板；
        --   arc bit  ＝幾何 profile 有效性（非 adaptive）→ 85%；
        --   band bit ＝證明距離＋品質（band/dynamics/capacity）→ 85%。
        -- 舊 remap-obb（證明不足改名近場接觸硬鎖 15）已刪；Grok lane blocker：
        -- nav v<4 的 adaptive 會被永久鎖 15。
        local proofReason = s.verifyLineReason
        -- 近場未知＝掃掠真命中／未載入「且」證明距離短於煞停視界；far 命中
        -- （驗證前綴已蓋住 stopEnd）不進 15 地板，band bit 亦不受連坐。
        -- dodge／RETURN／blocked 期間 buildSnapshotProof 早退、verifyLineReason
        -- 凍在舊值——nearUnknown 若不排除這些狀態，繞行全程被 obb 15 壓著
        -- （2026-09-01 telemetry s053：capReason obb 263 筆＝走走停停主因）。
        -- 這些狀態各有自己的 cap 體系（dodgeSpeedCap／RETURN_CAP／blocked 0）。
        local nearUnknown = (proofReason == "sweep" or proofReason == "unloaded")
            and not pathVerified
            and not s.dodging and not s.threading and not s.returnActive and not s.blocked
        s.fullGate, s.gateReason = MDADDynamics.fullSpeedGate(
            sensorReady, fresh, brakeLoaded, corridorClear, obbClear,
            fullValid and controlStateOf(s) == "TRACK",
            not s.returnActive and not s.returnHold, aligned, progressHealthy,
            s.adaptive == true,
            pathVerified,
            not nearUnknown)
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
            -- 2026-09-01 外部審查（codex＋Grok 同抓）：reason 只由真正壓低
            -- target 的 binding cap 寫，否則 telemetry 的 capReason 統計會
            -- 定罪到非裁決者（八輪定罪法的可信度基礎）。gateReason 照記。
            if ungated < targetSpeed then
                targetSpeed, s.lastCapReason = ungated, gateReason
            end
            s.gateReason = gateReason
            if gateReason == "align" then s.lastHeadingCap = ungated end
            if gateReason == "dynamics-invalid" then
                s.invalid, s.stateError, s.dynamicsFault = true, "ungated", true
            end
        end

        -- Final target is known before the supervisor. Planned blocked/followHold at target
        -- zero are legal waits; current-body contact remains a recovery demand.
        -- RETURN outranks planned blocked; current-body contact still outranks RETURN.
        -- 調頭豁免（2026-09-01 圖 1「煞停等待」僵死）：調頭姿態下走廊沿路線
        -- 反向掃＝掃描帶在車尾方向，掃到的 hard 是「倒著撞的東西」不是調頭
        -- 路徑上的障礙；blockedStop 壓 0 會把 rotate 鏈整個鎖死（else 分支
        -- 進不去）。調頭安全由 probeAround（原地轉）＋contact/sweep（大弧）
        -- 管；err 收斂回 90° 內即恢復 blocked 停等語意。
        local blockedStop = s.blocked and not reached and not s.returnActive
            and s.fstate.rotating ~= true
            and MDADDynamics.blockedNear(s.blockS, s.lastSNow,
                s.cornerLatch and TUNE.CORNER_STOP_DIST or TUNE.BLOCK_STOP_DIST,
                vx, vy, s.blockHitX, s.blockHitY)
        if getDebug() and s.blocked and s.lastBlockedStopDbg ~= blockedStop then
            s.lastBlockedStopDbg = blockedStop -- 只印翻轉（每幀印會把 replan 鏈洗出捲軸）
            print(string.format(
                "%spn=%d blockedStop=%s bs=%.1f rs=%.1f hit=%s,%s v=%.1f,%.1f rot=%s ret=%s",
                LOG, playerNum, tostring(blockedStop), s.blockS or -1,
                s.lastSNow or -1, tostring(s.blockHitX), tostring(s.blockHitY),
                vx, vy, tostring(s.fstate.rotating), tostring(s.returnActive)))
        end
        if blockedStop then targetSpeed, s.lastCapReason = 0, "blocked" end
        if s.currentBlocked then
            targetSpeed = 0
            s.lastCapReason = "contact"
            s.planMode = "current-blocked"
        end

        -- 意圖分類（重構階段 1 shadow → 階段 2 首步）：分類全量進 telemetry
        -- （phys.intent），行為接管目前只有一條：GO 的 MIN_EXEC 地板（下方）。
        -- demand／wait-budget 的接管待 shadow 驗證累積後進行。
        s.intentShadow = MDADDynamics.classifyIntent(
            s.currentBlocked == true, reached, s.dynamicsFault == true,
            s.recoverWhy ~= nil or s.mode == "unstick"
                or s.mode == "settle" or s.progressState == "gear-reset",
            s.fstate.rotating == true, blockedStop,
            s.followHold == true, s.returnHold == true,
            s.visibilityCap, s.dodgeCrawl == true,
            type(s.sensor) == "table" and s.sensor.stamp == 0,
            s.returnUnsafe == true,
            type(s.sensor) == "table" and s.sensor.ready == true)
        -- MIN_EXEC 地板（2026-09-01 階段 2 首步；shadow s006 定罪：572 幀
        -- intent=GO 但 target<1——verifyLine 幾何炸出 envelope 0、align 連乘等
        -- 「軟 cap 疊出執行不出的目標」全族）。GO 已保證：無停等訴求、無接觸、
        -- 非調頭非恢復、visibilityCap ≥ MIN_EXEC（低於它歸 WAIT）——把 (0,8)
        -- 的殘目標抬到可執行下限是行為修正不是安全豁免；curve hard breach
        -- 煞車紅線照常兜底。
        if s.intentShadow == "GO" and targetSpeed > 0
                and targetSpeed < MDADDynamics.MIN_EXEC_KMH then
            targetSpeed = MDADDynamics.MIN_EXEC_KMH
            s.lastCapReason = "min-exec"
        elseif s.intentShadow == "GO" and targetSpeed == 0
                and s.lastCapReason == "curve-coast"
                and not (finite(remaining)
                    and remaining <= MDADFollower.ARRIVE_M + 3) then
            -- s048 定罪（2026-09-01 教堂路口）：折點 verifyEnvelope 格＝0 是
            -- κ→∞ 的公式極限假象，GO 下 curve-coast 壓 0 ＝「cap 要速度才放寬
            -- （EWMA 資格 v≥2.2）、速度要 cap>0」的起步死鎖，99 幀 tgt=0 釘死。
            -- 到站減速（nearArrive）不抬；彎道真超速由 curve hard breach 煞車
            -- 紅線照常兜底——這是把不可執行的假 0 抬到可執行下限，非安全豁免。
            targetSpeed = MDADDynamics.MIN_EXEC_KMH
            s.lastCapReason = "min-exec"
        end

        local avProgress = speedKmh
        if avProgress < 0 then avProgress = -avProgress end
        if s.returnCapacityFault and s.returnHold and avProgress < 1 then
            postAction = "return-fault"
        end
        -- legalWait 已由意圖接管（階段 2 主體 3）：intent == "WAIT" 就是合法停等，
        -- 不再用 targetSpeed<=0 當代理、也不再逐旗標各自為政。
        -- 停等預算（2026-09-01 階段 2 主體 1）：舊制 waitSince 每次「有一點動」
        -- 就歸零（avProgress≥1 一幀、route cutover、suspect→recover→retry 循環
        -- 各自重置）＝同一僵局實測續命 40s+。改為「同一未解決 episode 的累計
        -- 預算」：只累加 WAIT／RECOVER 意圖的幀時間（GO／CRAWL 幀暫停計時但
        -- 不歸零），唯一歸零條件是 MDADDynamics.waitProgressed 的真進度與
        -- clearEpisode（換目標／到站／前進 10m+兩輪 clear 重臂）。
        -- 恢復鏈期間 stepFollow 不跑，時間由回到 follow 的第一個 WAIT 幀一次
        -- 補計——恢復完成後直接走 GO 的路徑不補計（成功不受罰）。
        local waitErr = headingError or 0
        if waitErr < 0 then waitErr = -waitErr end
        local waitLat = latSigned or 0
        if waitLat < 0 then waitLat = -waitLat end
        if s.waitAccumMs > 0 and MDADDynamics.waitProgressed(
                s.intentShadow == "ROTATE", s.returnActive == true,
                s.lastSNow - s.waitAnchorS,
                s.waitAnchorLat - waitLat, s.waitAnchorErr - waitErr) then
            s.waitAccumMs, s.waitTickMs = 0, 0
            s.blockRetryDone = false
        end
        if s.intentShadow == "WAIT" or s.intentShadow == "RECOVER" then
            if s.waitTickMs == 0 then
                s.waitTickMs = now
                if s.waitAccumMs == 0 then
                    s.waitAnchorS = s.lastSNow
                    s.waitAnchorLat, s.waitAnchorErr = waitLat, waitErr
                end
            elseif now > s.waitTickMs then
                s.waitAccumMs = s.waitAccumMs + (now - s.waitTickMs)
                s.waitTickMs = now
            end
        else
            s.waitTickMs = 0
        end
        if s.intentShadow ~= "WAIT" then s.blockRetryDone = false end
        -- 調頭需求＋前方堵死的判準不能吊在 legalWait 上（階段 2 主體 3）：
        -- legalWait 併入意圖後 ROTATE 會被排除，而 err>90° 正是這條 branch 的
        -- 主場景。改讀「非執行前進的意圖」＝WAIT 或 ROTATE。
        if s.blocked and not s.banFromRecovery and avProgress < 1
                and s.intentShadow == "ROTATE" then
            -- 調頭需求＋前方堵死（2026-09-01 實機圖 2：車頭反向、前方柵欄
            -- blocked→乾等 20s 紅字毫無意義——障礙在前、去向在後）。直接
            -- 走倒車脫困創造旋轉空間：rear swept-strip clear 才退（fail-
            -- closed 照舊），4m＋settle 重掃後 rotate probe 空間自然變大。
            requestRecover(s, "uturn-blocked")
        end
        -- 自動改道（ESC 選項，預設關）：blocked-retry 之後仍在停等、累計超過
        -- AUTO_DETOUR_MS 才要替代路線；一個停等 episode 只試一次，失敗＝沒替代路，
        -- 剩下交給 WAIT_TIMEOUT 紅字。玩家按 HUD「改道」鈕走同一條 Drive.requestDetour。
        -- **排在 blocked-retry 之前**（2026-09-02 實機：自動改道勾了永遠不觸發）：
        -- 倒車脫困後車開回原地再被堵，非 WAIT 幀已把 blockRetryDone 清掉，同一幀
        -- 先判的 blocked-retry 又 requestRecover 設 recoverWhy → 改道的
        -- recoverWhy==nil 永遠假；unstick 三次直接 StopStuck。累計 ≥10s 時改道優先，
        -- 本幀不再倒車。harness (c5c) 第一版用後牆讓倒車 soft fail 才綠＝假綠。
        -- 觸發時機：累計 ≥ AUTO_DETOUR_MS，或「已倒車重掃過一次（episodeAttempts≥1）
        -- 又被同一處堵住」——倒車沒解掉的堵，第二次倒車也不會解，先問替代路線。
        local autoDetourNow = s.blocked and not s.detourTried and s.recoverWhy == nil
            and postAction == nil and s.intentShadow == "WAIT"
            and (s.waitAccumMs >= TUNE.AUTO_DETOUR_MS
                or (s.episodeAttempts >= 1 and s.waitAccumMs >= TUNE.BLOCK_RETRY_MS))
            and type(MDAD.HUD) == "table" and type(MDAD.HUD.autoDetour) == "function"
            and MDAD.HUD.autoDetour() == true
        if autoDetourNow then
            s.detourTried = true
            Drive.requestDetour(playerNum)
        elseif s.blocked and not s.banFromRecovery and s.recoverWhy == nil
                and postAction == nil
                and not s.blockRetryDone
                and s.intentShadow == "WAIT"
                and s.waitAccumMs >= TUNE.BLOCK_RETRY_MS then
            -- 2026-09-01 使用者裁定：blocked 不乾等 15 秒——累計 5 秒仍無縫就
            -- 主動倒退 4m 重掃（換視角＝掃描帶錨移動、縫的量化相位改變，
            -- 常能解鎖）。rear swept-strip clear 才退（fail-closed 照舊）；
            -- 倒不了（soft fail）回到合法停等，只試一次防洗版。
            requestRecover(s, "blocked-retry")
        end
        if s.waitAccumMs >= TUNE.WAIT_TIMEOUT_MS then postAction = "wait" end

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
        -- gear-reset 不再是 mode（階段 2 主體 5）：mode 只留會繞過 stepFollow 的
        -- build／follow／unstick／settle／yield／arrive；空檔脈衝是 RECOVER 子
        -- 狀態，狀態機值一律走 progressState。
        if s.progressState == "gear-reset" then
            if now < s.progressUntil then
                targetSpeed = 0
                s.lastCapReason = "gear-reset"
            else
                s.progressState = "verify"
                s.progressUntil = now + TUNE.VERIFY_MS
                s.progressSince = now
                s.progressX, s.progressY = vx, vy
                s.progressS, s.progressH = s.lastSNow, heading
            end
        end

        -- 進度監督在 RECOVER 需求成立期間停擺（舊制的 mode=="recover" 閂鎖，
        -- 現由 s.recoverWhy 單一旗標承載）。
        if s.recoverWhy == nil and s.progressState ~= "gear-reset" then
            -- demand 由意圖驅動（2026-09-01 階段 2 主體 3）：刪掉 targetSpeed>=1
            -- 代理與 profileEnvelope>=8 這兩層「拿速度數字反推語意」的堆疊。
            --   GO／CRAWL 才是「正在執行前進訴求」，不動就是卡死；WAIT／
            --     ROTATE／RECOVER 依構造被排除（「該停」不是「卡死」，壓停與
            --     脫困互相打架＝s056；真僵死由停等總預算兜底＝主體 1）。
            --   MIN_EXEC 保證 powered command 非 0 即 ≥8，所以 targetSpeed>0
            --     就是那個不變式的重述，取代舊的 >=1 代理與 profileEnvelope>=8
            --     ——target==0 的 GO 只可能是剖面自己在煞停（到站收尾）。
            -- 三條具名例外，每條都有實測／harness 契約，不得再擴充：
            --   ① 車身接觸（STOP）＝最典型的卡死，一律臂。
            --   ② VERIFY＝我們自己開的證明窗（已下 neutral pulse，2 秒內證明
            --      能動）。被一個瞬時 WAIT 幀取消 gear-reset 就成了無聲逃逸；
            --      它逃向的倒車本身仍是 soft＋rear-clear 把關。
            --   ③ blocked＋banFromRecovery＝本 episode 的恢復已把唯一可行縫
            --      ban 掉、規劃器沒有選項了。那不是合法停等而是卡死
            --      （harness (d2)「infeasible recovery-ban shift arms recovery,
            --      not a legal wait」），要用掉剩下的 episode 額度而非乾等紅字。
            -- nearArrive 保留（s058 實測：終點前 5.5m 反覆倒車 20m 永遠進不了
            -- 站）；contact 不受此限。
            local nearArrive = finite(remaining)
                and remaining <= MDADFollower.ARRIVE_M + 3
            local demand = not reached
                and (not nearArrive or s.currentBlocked)
                and (s.currentBlocked == true
                    or s.progressState == "verify"
                    or (s.blocked and s.banFromRecovery)
                    or ((s.intentShadow == "GO" or s.intentShadow == "CRAWL")
                        and targetSpeed > 0))
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
                    diagEvent(s, playerNum, "progress", {
                        phase = "recover", eid = s.episodeId,
                        dt = now - s.progressSince, wd = sqrt(wd2),
                        ds = ds, dyaw = ayaw, hit = s.rearStatus,
                    })
                    requestRecover(s, "verify")
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
                    -- 動作選擇不在這裡（階段 2 主體 2）：只把 dispatch 需要的
                    -- 判定結果留成純量。夠格用 150ms 空檔脈衝＝近場淨空、非
                    -- 物理越野、檔位已進 2 以上、本 episode 還沒試過。
                    s.recoverGear = (okGear and finite(transmission))
                        and transmission or 0
                    s.recoverHit = nearStatus
                    s.recoverDetail = nearDetail
                    requestRecover(s, "progress",
                        nearStatus == "clear" and not s.currentBlocked
                            and okOff and physicalOffroad == false
                            and s.recoverGear >= 2
                            and not s.episodeGearResetTried)
                end
            end
        end
        -- RECOVER 需求成立（含本幀新成立）：零速命令與 capReason 只在這裡寫
        -- 一次，取代舊制三處各自 targetSpeed=0／lastCapReason="recover"。
        if s.recoverWhy ~= nil then
            targetSpeed = 0
            s.lastCapReason = s.recoverPulse and "gear-reset" or "recover"
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
        -- 脈衝不吃 recover hard cap（空檔脈衝要的是「什麼都不做」）。
        if s.recoverWhy ~= nil and not s.recoverPulse then
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
        if s.progressState == "gear-reset" or s.recoverPulse then
            hardBrakeReason = nil
        end
        if s.followHold or s.currentBlocked
                or (s.recoverWhy ~= nil and not s.recoverPulse)
                or s.returnHold or blockedStop or reached then
            hardBrakeReason = hardClampReason
        end
        -- 加速側直給（2026-09-01 三模型對抗審定案）：regulator 供油是二值全力
        -- （CarController.java:240-244 isGas；engineForce 不乘 throttle＝:755），
        -- jerk 積分目標貼著現速＝車一追平就斷油，加速度被人為封頂且斷續供油。
        -- 目標高於命令速度就一步跳到聚合 cap（引擎自然全力、達標自動斷油），
        -- 只夾 hardCapV。cmdV 先錨回實速（命令值不是真實狀態：上一幀直給的
        -- 高目標在 cap 下降瞬間從虛高值滑降會多供油半秒），錨定後 desired 與
        -- cmdV 相等（含起步/巡航穩態）一律走直給支，不得落進 jerk 積分。
        local desiredMs = targetSpeed / 3.6
        local actualMs = actualSpeed / 3.6
        if s.cmdV > actualMs then s.cmdV, s.cmdA = actualMs, 0 end
        if desiredMs >= s.cmdV then
            s.cmdV, s.cmdA, s.jerkBypassReason = desiredMs, 0, nil
            if finite(hardCapV) and hardCapV >= 0 then
                if s.cmdV > hardCapV then
                    s.cmdV = hardCapV
                    s.jerkBypassReason = hardClampReason
                end
            else
                s.cmdV, s.cmdA, s.jerkBypassReason = 0, 0, "dynamics-invalid"
            end
        else
            s.cmdV, s.cmdA, s.jerkBypassReason = MDADDynamics.jerkCommand(
                s.cmdV, s.cmdA, desiredMs, mult * SECONDS_PER_MULT,
                s.safeAccel, s.safeBrake, MDADDynamics.JERK_MAX,
                hardCapV, hardClampReason)
        end
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
        elseif s.progressState == "gear-reset" or s.recoverPulse then
            vehicle:setRegulator(false)
        elseif s.recoverWhy ~= nil or s.currentBlocked then
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
            if ((s.dodging and not s.dodgeCapPending) or s.threading)
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
                local rotating = s.fstate.rotating == true
                -- aerr 只剩前推輔助在用（調頭判定已改讀 fstate.rotating）
                local aerr = headingError or 0
                if aerr < 0 then aerr = -aerr end
                local av = speedKmh
                if av < 0 then av = -av end
                if rotating and av > TUNE.ROTATE_ARC_MAX_KMH then
                    -- 調頭需求但動量超過大弧爬行帶：主動煞停，這幀不施轉向。
                    -- 2026-09-01 s060：舊閘用 SPIN_MAX(5) 當上限，大弧爬行 12
                    -- 一加速就被煞回 5——「>5 煞停 → ≤5 才探測 → 探測擋 →
                    -- 大弧 12 → 又煞停」振盪，大弧路徑從未真正跑起來。上限改
                    -- 爬行帶 13；原地耦力自身仍要求近停（coupled 條件）。
                    vehicle:setRegulator(false)
                    commandForceBrake(s, vehicle, now)
                    regOn = false
                elseif not rotating or av <= TUNE.ROTATE_ARC_MAX_KMH then
                    -- 誤差 > 90° 走耦力模式（coupled=true）：力矩恆定、側向中心力
                    -- 幀間抵消＝原地旋轉不橫滑（實機：橫推調頭會滑出路外撞東西）。
                    -- **原地旋轉前先探車周**（500ms 節流）：走廊沿路線掃，路線反向
                    -- 要調頭時車後方／側面全是走廊盲區——貼牆貼樹貼車旋轉＝車身
                    -- 掃掠直接撞。周邊不淨空（或未載入）就退回橫推大弧：爬行 12
                    -- 前進轉，空間不夠自然由卡死→脫困鏈接手。
                    local coupled = rotating
                        and av <= TUNE.ROTATE_SPIN_MAX_KMH
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
                        -- 橫向速度阻尼（前臂化補課）：latDev 差分近似橫向
                        -- 收斂速度，零額外 getter；dt 用本幀 mult 換算。
                        local dLat = nil
                        -- 只在連續幀之間差分（prevCrossLatMs 守鮮 250ms）：unstick／
                        -- settle／煞停早退／route cutover 等不經此段的幀之後，
                        -- 第一幀不得用舊 latDev 算 D 項（前臂＋PD 會抽一記）。
                        local dtSec = mult * SECONDS_PER_MULT
                        if finite(s.prevCrossLat) and dtSec > 1e-4
                                and now - (s.prevCrossLatMs or 0) <= 250 then
                            dLat = (latDev - s.prevCrossLat) / dtSec
                        end
                        s.prevCrossLat, s.prevCrossLatMs = latDev, now
                        steer = (steer or 0)
                            - MDADDynamics.crossTrackSteer(latDev, speedKmh, dLat)
                    else
                        s.prevCrossLat = nil
                    end
                    -- 前推輔助的姿態門檻（2026-09-01 使用者裁定「繞行與越野
                    -- 要能用推力幫忙通過」）：繞行／回線／物理越野時姿態誤差
                    -- 天然偏大（切縫、斜穿回線、草地打滑），舊的 20° 硬上限
                    -- 正好在最需要推力的場景把 assist 整個切斷＝卡住的來源。
                    -- 這三種情境把上限放寬到 2×，並讓 ratio 吃越野補償。
                    -- forceBrakeUntil 期間仍一律不 assist（安全紅線不動）。
                    local rough = s.dodging == true or s.threading == true or s.returnActive == true
                        or s.physicalOffroad == true
                    local assistErrMax = TUNE.ASSIST_MAX_ERR_RAD
                    if rough then assistErrMax = assistErrMax * 2 end
                    local assistForce = 0
                    if regOn and not coupled and speedKmh >= 0
                            and now >= s.forceBrakeUntil
                            and aerr <= assistErrMax then
                        assistForce = longitudinalAssistForce(
                            s, speedKmh, targetSpeed, mult, rough)
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
            local critFlag = s.blocked or s.currentBlocked or s.dodging or s.threading or s.returnActive
                or s.progressState == "gear-reset" or s.recoverWhy ~= nil
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
                    s.blocked or s.currentBlocked, s.dodging or s.threading, s.returnActive,
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
    -- 停等總預算耗盡是最高優先的終局（紅字交還玩家），蓋過任何恢復需求。
    if postAction == "wait" then
        Drive.stop(playerNum, KEY_STUCK)
        return
    end
    -- RECOVER 單一 dispatch（階段 2 主體 2）：五個需求方只設 s.recoverWhy＋原因，
    -- 動作選擇集中在這裡、每幀一次。車還在滑行（avProgress>=1）就留著旗標，
    -- 下一幀再判——恢復動作必須從靜止起手。
    -- 動作優先序：中檔空檔脈衝（最便宜、不動位置，只有 suspect 探測證明近場
    -- 淨空＋非越野＋檔位>=2＋本 episode 未試過才夠格）→ 倒車重掃。
    -- 倒車一律 soft（2026-09-01 使用者裁定）：rear 堵／額度用盡就回到停等繼續
    -- 掃描（15s 總預算是最後保險），不因單次探測失敗立即紅字放棄 session
    -- （s051/s052：啟動 3 秒就 STUCK 的根因）。
    -- speedKmh 可負（倒車＝BaseVehicle.java:4268）：|v|<1 才算停妥。此處刻意
    -- 用外層 speedKmh 而非內層 avProgress——那個 local 在 forward-vector 區塊內。
    if s.recoverWhy ~= nil and speedKmh < 1 and speedKmh > -1 then
        local why = s.recoverWhy
        local pulse = s.recoverPulse
        s.recoverWhy, s.recoverPulse = nil, false
        if pulse then
            s.episodeGearResetTried = true
            s.progressState = "gear-reset"
            s.progressUntil = now + TUNE.GEAR_RESET_MS
            diagEvent(s, playerNum, "progress", {
                phase = "gear-reset", eid = s.episodeId,
                gear = s.recoverGear, why = why,
            })
            return
        end
        s.progressState = "recover"
        diagEvent(s, playerNum, "progress", {
            phase = "recover", eid = s.episodeId, why = why,
            hit = why == "progress" and s.recoverHit or s.rearStatus,
            detail = why == "progress" and s.recoverDetail or nil,
        })
        startRecoveryAttempt(s, vehicle, playerNum, now, vx, vy, true)
        return
    end
    if postAction == "return-fault" then
        Drive.stop(playerNum, KEY_STUCK)
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
            voice("arrive", playerNum)
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
            s.avoidX, s.avoidY, s.pendingDetour = nil, nil, false
            s.rejectedRoute = nil
        end
        -- 起點太遠（要越野接線）＝與啟動同一道閘門：交還玩家。**每一次 cutover 都驗**
        -- （2026-09-02 s064 定罪：舊制只在啟動與換目標驗，偏航重算走的是同一個
        -- requestRoute → 主 MOD 把起點吸到 65m 外的平行道路，addon 照跟＝車直接
        -- 開進樹林，telemetry lat=63.5）。同目標的偏航重算沿線 snapDist 本來就小，
        -- 這道閘門只會攔真的「路線不在車所在的路上」。
        if cachedSnapTrusted(api) and routeTooFar(route) then
            Drive.stop(playerNum, KEY_ROUTE_FAR)
            return
        end
        s.lastTx, s.lastTy = tx, ty

        local versionChanged = api.navApiVersion ~= s.navVersion
        -- 同目標 route identity 防抖（2026-09-01，telemetry s033：主 MOD 對同一
        -- 目標每 250ms 回新 table identity，rg 1→9 反覆 cutover 把繞行枚舉進度、
        -- episode ban 與感知快照全部清空重來——blocked 永遠來不及解）。
        -- 等價判定＝len/cost/點數，再逐段比 segSurface/segWidth（O(n) 冷路徑、
        -- 250ms 一次）：同幾何但 metadata 更新（surface/width）必須照常 cutover，
        -- 否則剖面吃到舊路面權重。無 cost 的 v2/v3 route 不防抖。
        if route ~= s.route and not versionChanged and not targetChanged
                and s.route ~= nil and s.profile ~= nil
                and finite(route.len) and finite(s.route.len)
                and route.len > s.route.len - 0.5
                and route.len < s.route.len + 0.5
                and finite(route.cost) and finite(s.route.cost)
                and route.cost > s.route.cost - 0.5
                and route.cost < s.route.cost + 0.5
                and type(route.pts) == "table" and type(s.route.pts) == "table"
                and #route.pts == #s.route.pts
                and type(route.segSurface) == "table"
                and type(s.route.segSurface) == "table"
                and type(route.segWidth) == "table"
                and type(s.route.segWidth) == "table" then
            local same = true
            local oldSurface, oldWidth = s.route.segSurface, s.route.segWidth
            local newSurface, newWidth = route.segSurface, route.segWidth
            for i = 1, #route.pts / 2 - 1 do
                if newSurface[i] ~= oldSurface[i]
                        or newWidth[i] ~= oldWidth[i] then
                    same = false
                    break
                end
            end
            if same then s.route = route end
        end
        -- sticky 避讓：主 MOD 之後因偏航／冷卻自行重算（不帶 avoid）若又穿回堵點，
        -- 立刻以同一圈再要一次替代線，拿不到才照原線走（每次 cutover 最多一次）。
        if route ~= s.route and not targetChanged and not s.pendingDetour
                and finite(s.avoidX) and finite(s.avoidY)
                and routeCrossesAvoid(route, s.avoidX, s.avoidY, TUNE.DETOUR_AVOID_R) then
            local remaining = s.profile and (s.profile.length - s.lastSNow) or nil
            local detour, _, rejected = requestDetourRoute(api, playerNum, tx, ty, s.avoidX, s.avoidY, remaining)
            if detour then
                route = detour
                s.pendingRouteWhy = "detour"
            else
                s.avoidX, s.avoidY = nil, nil
                if rejected ~= nil then s.rejectedRoute = rejected end
            end
        end
        -- 被本 MOD 拒收的替代線（far／long／through）仍躺在主 MOD 快取裡（requestDetour
        -- 成功即覆寫），下一次取路會原樣拿回同一個 table——不得當成一般 cutover 收下
        -- （2026-09-02 s064：拒收 far 之後同一幀就以 "deviation" 名義跟著它開進樹林；
        -- 主 MOD 冷卻後重算會換新 identity，屆時照常 cutover）。
        if route ~= s.route and s.rejectedRoute ~= nil and route == s.rejectedRoute then
            route = s.route
        end
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
            s.pendingDetour = false
            s.routeGen = s.routeGen + 1
            local oldMode, oldProgress, oldUntil = s.mode, s.progressState, s.progressUntil
            local preservingRecovery = not targetChanged
                and (oldMode == "unstick" or oldMode == "settle"
                    or s.recoverWhy ~= nil)
            local targetSettling = targetChanged
                and (oldMode == "unstick" or oldMode == "settle")
            local resumePhase = nil
            if not targetChanged and oldProgress == "gear-reset" then
                resumePhase = "gear-reset"
            elseif not targetChanged and oldProgress == "verify" then
                resumePhase = "verify"
            end
            s.route = route
            s.profile = profile
            s.rejectedRoute = nil
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
            diagEvent(s, playerNum, "route", MDADDiagnostics.routeSource(route, {
                phase = "cutover", why = routeWhy, rg = s.routeGen,
                tg = s.targetGen, len = routeLen, pts = pointN,
                target = tostring(tx) .. "," .. tostring(ty),
                navVersion = s.navVersion,
                currentSurface = MDADFollower.surfaceName(profile.segSurface[1]),
                currentSegWidth = profile.segWidth[1] > 0 and profile.segWidth[1] or nil,
                cost = finite(route.cost) and route.cost or nil,
                avoidPenalty = finite(route.avoidPenalty) and route.avoidPenalty or nil,
            }))
            if type(MDADFollower.resetState) == "function" then
                MDADFollower.resetState(s.fstate)
            end
            s.roadBias = 0
            MDADFollower.setLaneBias(s.fstate, s.sandBias)
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
            -- 同目標 route cutover **不清停等預算**（階段 2 主體 1：這正是舊制
            -- 40s+ 續命的其中一條逃逸路徑）；但下面 lastSNow 歸零＝換了弧長
            -- 座標系，錨點必須跟著換算到新座標系（0），否則進度判定失效。
            s.waitAnchorS = 0
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

    -- （detour 塊已移除；理由見 DETOUR 註解＝telemetry s030/s033）

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
                -- fillet 建構結果（2026-09-02 玩家 telemetry 定罪缺口）：capacity
                -- 退化只有這裡看得到，每幀 sample 的 filletN/filletFallbackN 分不出
                -- 「沒彎」與「彎全退化」。
                filletN = s.profile.filletN,
                filletFallbackN = s.profile.filletFallbackN,
                filletBandValid = s.profile.filletBandValid,
                filletReason = s.profile.filletReason,
            })
        end
        s.mode = "follow"
        local resumePhase = s.resumeProgressPhase
        local resumeUntil = s.resumeProgressUntil
        s.resumeProgressPhase = nil
        s.resumeProgressUntil = 0
        if resumePhase == "gear-reset" and now < resumeUntil then
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
            -- 玩家接手＝舊診斷作廢（舊制由 mode 被覆寫成 "yield" 自然丟掉
            -- recover 閂鎖；旗標化後必須顯式丟，否則恢復後立刻倒車）。
            s.recoverWhy, s.recoverPulse = nil, false
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
