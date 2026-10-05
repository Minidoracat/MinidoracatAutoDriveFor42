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
Drive.REV = "1005k"

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
TUNE.BRAKE_SAMPLE_MS = 200 -- 以短窗淨減速觀測，避開逐幀速度量化與致動延遲。

local ROUTE_REFRESH_MS = 250   -- 導航目標／路線刷新節流（毫秒）
local USAGE_HEARTBEAT_MS = 5000 -- server registry TTL=15s；start/stop 另有即時封包
TUNE.USAGE_FIRST_RETRY_MS = 1100 -- 初始封包被 server 1s flood gate 吃掉時快速自癒
-- 目標消失時的「抵達接管」半徑（世界格，平方比較）：主 MOD 在玩家距目標
-- NAV_ARRIVE_DIST（5 格）內會**自動清除**導航目標（小地圖的「走到旗子就收旗」，
-- MinidoracatMiniMap.lua navCheckArrival，每幀跑）；自駕的到達判定（follower
-- reached：沿線開完＋停妥）比它嚴——正常開到目的地時目標必先被主 MOD 收走，
-- 250ms 路線刷新讀到「沒目標」就誤報紅字「路線遺失」（2026-08-28 實機：到站
-- 閃紅字，玩家分不清是到達還是 bug）。半徑 12＝5（主 MOD 清除圈）＋250ms 內
-- 最高速位移（40km/h≈2.8 格）＋路線終點對目標的投影偏差餘裕。
TUNE.ARRIVE_CLEAR_SQ = 12 * 12
local BUILD_BUDGET = 128       -- 每幀限速剖面建構點數上限（啟動／換路線：車靜止或已 HOLD）
-- 行駛中 dynamics 重建的每幀預算（2026-09-04 issue #1 定罪 E）：重建期間不控速、
-- 不轉向、Sensor 也停；399 點剖面 ≈2000 ops，128/幀＝16 幀，玩家機器 9-12 fps 時
-- 是 1.6 秒空白。1024/幀＝典型路線 1-2 幀、1024 點上限 ≤5 幀。啟動／換路線仍用
-- BUILD_BUDGET（車靜止或剛 HOLD，攤幀只影響起步延遲）。
TUNE.REBUILD_BUDGET = 1024
TUNE.MAX_SESSIONS = 4          -- 分割畫面本機玩家槽上限（getSpecificPlayer 0-3）
-- 讓位後恢復自駕的等待時間改由 ESC／MiniMap「手動介入後」選項決定（HUD.manualResumeMs；
-- 0＝介入即關閉，2026-09-06 使用者裁定預設不自動恢復）。恢復語音只在讓位持續夠久
-- 才播——老玩家勾了自動恢復後輕推方向盤微調，每 2 秒念一句「我接手了」會吵。
TUNE.YIELD_VOICE_MS = 5000
TUNE.PAUSE_VOICE_TIMEOUT_MS = 10000 -- 最長交還語音 6.3s；播放狀態失效時不永久等待
-- 調頭方式（2026-09-06 使用者裁定預設「溫和」；codex 交叉審：「被嚇到」對應**帶多少速度
-- 開始轉**，其次才是轉多快——力矩倍率只管原地旋轉，管不到 15-25 km/h 帶速大弧）。
-- 玩家在 ESC／MiniMap 選行為檔，Driver 管成套參數，不開單一物理旋鈕（配出互相打架的門檻）。
-- 每次調頭開始時讀一次（HUD.uturnMode；缺席＝溫和），同一次調頭參數不變＝下次調頭生效。
--   entry：新一次調頭的入場放行速度——超過先煞停不轉，降到以下才放行；**一次性**，放行後
--          不再因超過它重啟煞停（2026-09-01 s060：把入場門檻當常駐上限＝「煞停→探測→大弧
--          12→又煞停」振盪）。快速檔 entry＝arc＝現行行為逐位元不變。
--   spin ：原地耦力旋轉的速度上限；超過走大弧前進轉。舊值 20 曾把車甩出 22m 草地
--          （st 88,113 遙測 lat 10→22.6），15＝09-01 使用者授權「甩尾調頭合法」。
--   force：耦力力矩縮放（只影響原地旋轉）。跟線橫推量級是為對抗高速輪胎自回正標定的，
--          原地調頭阻力小得多，全額＝實機「快速循轉」；0.4＝緩慢平穩迴轉、0.65＝激進化。
--   arc  ：常駐煞停上限（大弧帶）；超過主動 forceBrake（53 km/h 吃飽和側推整台車甩飛，
--          2026-08-28 yield 恢復）。
--   crawl：車周探測淨空（可原地轉）時的速度目標；溫和檔要壓在 spin 之下，否則煞到 5 又朝
--          Follower 的 12 加速、切回大弧。大弧仍用 Follower 的 12（也是終點脫困地板，不動）。
TUNE.UTURN = {
    gentle = { name = "gentle", entry = 5,  spin = 5,  force = 0.4,  arc = 13, crawl = 4 },
    fast   = { name = "fast",   entry = 25, spin = 15, force = 0.65, arc = 25, crawl = 12 },
}
-- 調頭大弧卡住（Drive.rotateStall）：車周探測被擋（走大弧）又連續這麼久不動＝前方沒有大弧空間，倒車創造空間
TUNE.ROTATE_STALL_MS = 2500
-- 拖掛車的側推限制（2026-09-26 Workshop 回報「草地起步劇烈晃動、掛車脫開」，E2E trailer-grass-mp）：
-- 側推的 MASS_BASE 項與車速無關，低速照樣整台橫推——真車低速轉不動掛點，這裡卻把車頭橫甩、
-- 掛車原地不動（遙測首幀 spd 0、f −46k，折角 0→61° 只花 0.4 秒）。拖車時側推按車速線性放大到
-- TOW_STEER_FULL_KMH 才全額（只在 3 km/h 以上放行仍會在放行瞬間甩 60°）。前推輔助不動：
-- 關掉它牽引車在草地拉不動掛車，4.5 秒後進倒車脫困（E2E 同情境實測）。
TUNE.TOW_STEER_FULL_KMH = 15
-- 一般車同理（2026-09-27 正式服 14 段：起步 target 0／感知未就緒、ROTATE 探測否決原地轉後，
-- 非耦力 MASS_BASE 項把靜止車首幀推 5–30 萬，0.1 秒側滑 13–30 km/h → rotate／RETURN 硬煞或
-- contact）。低於 STEER_FULL_KMH 側推按車速縮、靜止＝零；耦力原地調頭（coupled）不受影響。
-- 取 4：貼縫爬行 5 km/h 與調頭大弧 12 仍是全額，只有近乎靜止時才收。
TUNE.STEER_FULL_KMH = 4
-- 縮放量的是車身前進速度（1004b，Drive.forwardKmh）：getCurrentSpeedKmHour 是速度向量長度、含側滑，側推一推出
-- 橫滑就把自己的縮放解鎖成全額（正式服 0.18.2 起步大弧調頭 8 段：0.2 秒內 1→13 km/h、橫向 >14 m/s²，接調頭煞停）。
-- |v| 低於 full＋此值才讀線速度（前進速度可能還在縮放區）；起步側滑的橫向分量實測 ≤11.5 km/h。
TUNE.STEER_SLIP_MARGIN_KMH = 12
-- 高速力臂延伸（1005）：非耦力側推的施力點沿車頭方向放到 arm×K、力除以 K——偏航力矩不變，質心側推只剩 1/K。
-- 引擎 addImpulse＝applyCentralForceToVehicle(F)＋applyTorqueToVehicle(relPos×F)（BaseVehicle.java:3351-3359），
-- relPos 不夾，所以力臂可以超出車身。前臂同號（2026-09-02 裁定）不變，只是側移量變小。語料 177 段（.omc/uploads/
-- 20261004）彎上（curveHardActive、|sff|≥0.1）≥35 km/h 樣本：控制 |sff|、車速、yr/v 後，側推量對車身往彎內滑的偏
-- 相關 vt 0.60、ld 0.41（n=356；23 段內 16 段同號）；15–35 km/h 0.03／−0.12（沒有關係）。K 在 FROM→FULL 由 1 線性爬到
-- ARM_EXT_K；拖車（掛車折角動態沒有離線模型）、貼縫爬行（s.dodgeCrawl）與殭屍軟縫側移（s.zombieLane）要的就是側移，
-- 固定 1（Drive.armExtK）。s.armExt 進遙測（arx）。
-- K 取 1.25（1005 實機矩陣：replay 案 B 四車型＋campaign 出彎外漂案 Mustang×2，每個 K 各 6 輪）：K 1.0／1.25／1.5 的
-- 彎上往內滑 vt_in 平均 +0.044／+0.006／−0.059 m/s，最大外偏 −0.75／−0.66／−0.73m，出彎外漂平均 0.54／0.46／0.54m，
-- 接觸 2／0／2——1.5 把內滑壓過頭、換成往外偏；1.25 兩邊都最小。
TUNE.ARM_EXT_FROM_KMH = 35
TUNE.ARM_EXT_FULL_KMH = 55
TUNE.ARM_EXT_K = 1.25
-- 車身 yaw 率限制（0928a，ESC 式；0.13.1 正式服片段 >3 rad/s 自轉 24 次，0.13.0 只有 2 次）：側推是施在
-- 車頭的外力、不受前輪轉角限制，目標點突然跳到 90° 外（Z 字短 jog 放行下一臂、窄出口繞行線、大弧調頭）
-- 時 steer 飽和，0.2 秒內自轉 6–9 rad/s（summer/clip-06 SmallCar 18 km/h、Thragg/clip-04 GTR 大弧調頭、
-- kenzo_L/clip-08 窄出口繞行）。量到的 yaw 率（≥ESC_WINDOW_MS 視窗：高幀率時物理 0.01s 子步讓單幀
-- heading 差分 0／倍數交錯）超過「運動學 v/rMin 與抓地 safeLat/v 的較小者 ×MARGIN＋FLOOR」時，同向
-- steer 依超出量線性收掉（兩倍上限歸零）；反向（修正自轉）不受限。耦力原地調頭不經此限。
TUNE.ESC_MARGIN = 1.3
TUNE.ESC_FLOOR_RADS = 0.3
TUNE.ESC_WINDOW_MS = 30
-- 回授依轉向增益正規化（0929j；玩家 KI5 Oshkosh 消防車撞樹／撞路邊物 2 次）：PID 與 cross-track 的增益是在
-- 一般車上調的（Follower 的 yawGain 估計 0.5–0.9），Oshkosh 真實增益只有 0.15–0.19、SemiTruckBox_mil 0.09–0.12，
-- 同一個誤差轉出的 yaw 少兩到四倍：session-012 繞行承諾後 steer −0.3～−0.44、2.2 秒往右漂 1.35m 撞上；R84 彎
-- 出彎外漂 0.7m 撞樹。回授部分（總 steer 扣掉弧段前饋）乘 k＝FB_NORM_REF／yawGain，夾 [1, FB_NORM_MAX]：
-- 估計 ≥ REF 的車（語料一般車 0.47–0.99）不變；前饋本來就除以 yawGain，不再乘。還沒學到（INIT 0.8）＝不動。
-- 過頭由 yawGovern（ESC）接手：正規化排在它之前，yaw 率超過物理上限照樣收。
TUNE.FB_NORM_REF = 0.5
TUNE.FB_NORM_MAX = 3
-- 放大後的回授最多到 FB_NORM_CLAMP（原本就更大的照原值）：正規化是給小修正補力，不放大暫態尖峰——E2E 0929j
-- Oshkosh 53 km/h 承諾繞行那一幀 D 項尖峰 2.2 ×3＝6.7，轉向打滿、車反而往外甩。
TUNE.FB_NORM_CLAMP = 1.5
-- 繞行承諾中未對正不加速（0929j；session-012 第二段繞行 commit 時車頭仍偏右 7–9°、偏線 0.2m，帽 28.6 讓車
-- 從 12.6 加到 29 km/h，低增益車在兩秒內修不回來）：|偏線| > DODGE_ALIGN_DEV_M 或車頭對承諾線切線 >
-- DODGE_ALIGN_RAD 時，繞行帽夾在「目前車速」（不減速、只是不加速），下限 DODGE_COMMIT_MIN_KMH 讓靜止時仍能起步。
-- 與 Drive.dodgeEnvelopeCap 的逐點提速資格共用同一個定義（Drive.dodgeAligned）。
TUNE.DODGE_ALIGN_DEV_M = 0.35
TUNE.DODGE_ALIGN_COS = math.cos(5 * math.pi / 180)
-- 偏線門檻隨車身處的逐點淨距放寬（1004e，使用者「確定沒問題，速度也應該提升上去而不是緩慢爬行」）：淨距表
-- （dodgeClr）新鮮、對得上這條線時，門檻取 max(DODGE_ALIGN_DEV_M, 車身前方各點淨距最小值×0.5)，上限此值。E2E
-- dixie9160：繞過最窄點後淨距 9m，追 13° 的出口線穩定落後 0.37m（>0.35），帽夾在 10 km/h 爬了 9 秒。
TUNE.DODGE_ALIGN_DEV_MAX_M = 1.0
-- 起步近物限速（0928a；0.13.1 起步 15 秒內接觸 13 趟，0.13.0 為 4）：起步時車常不在規劃車道上（路邊
-- 斜停、離線數公尺），規劃器以車道判斷的淨空與車身實際掃過的不同——前半車身旁的桿、欄杆只剩 0.2–3m
-- 時車已加到 16–28 km/h（seems/clip-14、C86/clip-06、Annilex/clip-05）。起步到「貼上車道並對正」持續
-- START_GUARD_HOLD_MS（或駛離起點 START_GUARD_MAX_M）之前，車頭前方帶內最近硬物淨距以滑行減速度套接近
-- 包絡；接觸閘照舊。倒車脫困開始時重新武裝（又是從障礙旁起步）。1004e：帽低於 MIN_EXEC 不再被抬回（見
-- Drive.startGuardApply），停住 START_NEAR_STALL_MS 就倒車；往常駐線斜切的路徑由 Drive.transitionHold 管。
TUNE.START_GUARD_LAT_M = 0.5
TUNE.START_GUARD_ALIGN_RAD = 10 * math.pi / 180
TUNE.START_GUARD_HOLD_MS = 1000
TUNE.START_GUARD_MAX_M = 40
TUNE.START_GUARD_MARGIN_M = 0.3
TUNE.START_NEAR_STALL_MS = 1000
TUNE.TRANSITION_RELEASE_M = 0.3 -- 斜切保持的放手遲滯：帶寬多留這麼多仍淨空才放回常駐線（邊緣點逐輪進出＝左右擺）
local STEER_INPUT_EPS = 0.01   -- getCurrentSteering 視為「玩家在轉」的門檻
local STEER_DEADZONE = 0.02    -- follower steer（±5）的死區：低於此值不施力（免無謂抖動）。
                               -- 0.1→0.02（2026-09-07 session-006 t=2.6-3.8 定罪：殭屍在車側 0.3m、
                               -- lane 要左移 0.8m，59 km/h 下 KP 2.2×err 0.03＋cross-track 0.77/v
                               -- 全落在 0.1 死區＝零施力、車 1.2 秒只橫移 0.15m，縱向配合帽於是
                               -- 從 47 崩到 12。高速下 0.1 死區＝2.6° 航向／2m 橫向誤差以內不修正）

-- getMultiplier() → 真實秒數。getThirtyFPSMultiplier()＝getMultiplier()/1.6 是
-- 「以 30fps 為基準的幀數」（GameTime.java:1032-1034），再除以 30 即為秒；
-- 1/(1.6*30) = 1/48。正常遊戲速度下這正好等於 getRealworldSecondsSinceLastUpdate()
-- （GameTime.java:192-193，fpsMultiplier = 60/fps＝FPSTracking.java:39），
-- 但走 multiplier 的好處是時間加速／慢動作也一致（dt 與施力用同一個係數）。
local SECONDS_PER_MULT = 1 / 48
local MULT_MIN, MULT_MAX = 0.1, 3.0 -- 掉幀尖峰／睡眠加速（getMultiplier 可到 200）時夾住。
                                    -- 下限 0.5→0.1（0907f；Codex lane：0.5＝24ms 幀，使用者機器 fdt p50 7ms
                                    -- ＝每幀衝量被當 24ms 算 → 每秒側推 1.5×（4ms 幀 2.4×）、jerk／cross-track
                                    -- dt 同樣被放大——轉向強度隨 FPS 變，快機器過彎更容易刮胎）

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
-- 改成「車尾臂（2.2m）＋側向衝量」的幾何，量級照質量與車速標定（實機調校）：
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

-- 量級（STEER_STRENGTH=1.0 即基準量級；telemetry 顯示轉不動才調大、
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
TUNE.CURVE_BREACH_RATIO = 1.5     -- 彎道 forceBrake 災難門檻＝cap×1.5（a_lat 2.25×；一般超速交給 regulator brake 15）
TUNE.ZOMBIE_APPROACH_LEAD_M = 8 -- 檔位速要在最近殭屍車頭前這麼遠就到位（0907b envelope；
                                -- 殭屍朝車走 1-2 m/s、掃描 4Hz 一輪最多再近 0.5m）
-- 會車／跟車（2026-09-24 雙客戶端 E2E 定罪：舊制「帶內有行進車＝壓 20、<10m 煞停」讓兩台自駕在
-- 對向 7m 外面對面停死，再當靜態障礙慢慢繞；人工車佔中線時只煞不閃，被迎面撞上）。
-- 現制逐車看 Sensor 的 trf*（車身 (s,l) 區間＋沿路線速度）：同向且擋在行駛線上＝跟車；
-- 對向且會壓到常駐線＝靠右錯開（速度配合側移時間），右邊沒空間才減速停等讓對方先過。
TUNE.TRAFFIC_ONCOMING_MPS = 1.0   -- 沿路線速度低於 −此值＝對向來車
TUNE.TRAFFIC_MARGIN_M = 0.5       -- 錯車時兩車車身希望留的淨距
TUNE.TRAFFIC_MARGIN_MIN_M = 0.25  -- 最少淨距；右邊連這個都留不出來＝停等讓車
TUNE.TRAFFIC_HORIZON_S = 6        -- 預計 6 秒內會車（或 30m 內）才處理
TUNE.TRAFFIC_LANE_RATE_MPS = 1.2  -- 為對向車側移的速率上限
TUNE.TRAFFIC_EDGE_KEEP_M = 0.1    -- 為對向車側移時離路面餘裕邊的保留（平常 Follower.LANE_BIAS_KEEP 0.6；1001b）
TUNE.TRAFFIC_LEAD_S = 0.6         -- 側移完成後到交會還要留的秒數（快照年齡＋對方擺動）
TUNE.TRAFFIC_SHIFT_DONE_M = 0.1   -- 車位離錯車 lane 這麼近＝側移已完成（只剩淨距限速，不再為側移時間減速）
TUNE.TRAFFIC_PASS_MIN_KMH = 15    -- 淨距只有最少值時的錯車速度；淨距 ≥ PASS_FREE_M 不限
TUNE.TRAFFIC_PASS_FREE_M = 1.0
TUNE.TRAFFIC_YIELD_BUFFER_M = 3   -- 讓車：在預計交會點前這麼遠停下
TUNE.ONCOMING_DESIGN_KMH = 25     -- 借對向車道繞行的過渡段設計速（見 shapeProfile）
TUNE.ONCOMING_INTRUDE_M = 0.5     -- 路寬未知時：車身左緣壓過路面中線超過這麼多才算借對向車道
TUNE.ONCOMING_PASS_M = 2.4        -- 對向車道被吃掉後剩不到這麼寬（一台車＋餘裕）＝借對向車道
TUNE.EXIT_EXTEND_MIN_M = 4        -- 承諾後出口加長：至少長這麼多才重建（Drive.extendDodgeExit）
TUNE.EXIT_EXTEND_RETRY_M = 5      -- 加長掃不過：車再前進這麼多才重試
-- 出口轉場塞不進緊接的小折點前（c 後 2m 內）時，偏移照樣通過這個折點、出口放到它之後（shapeProfile）。
-- 大折點（外側偏移繞急彎＝車追不上、切內）照舊拒收。
TUNE.EXIT_HOLD_KINK_RAD = 0.6
TUNE.TRAFFIC_WAIT_NOTICE_MS = 5000 -- 「等對向車」提示去重窗
-- 伺服器轉送的遠方行進車（1001i；server/MDAD_TrafficRelay.lua、Drive.mergeRelay）：原生同步只到約 64–88 格，
-- 轉送補到 300m 讓會車／跟車提早判讀；最後閃避仍以原生即時位置為準。
TUNE.RELAY_TTL_MS = 1500         -- 收到後這麼久沒再更新就不用（伺服器每 250ms 送一次）
TUNE.RELAY_LAG_MS = 250          -- 伺服器位置落後駕駛者客戶端的估計（網路＋轉送週期一半）；trafficScan 依年齡外推
TUNE.RELAY_BACK_M = 30           -- 投影到路線：只找 [車位－此值, 車位＋RELAY_AHEAD_M] 的路段
TUNE.RELAY_AHEAD_M = 320
TUNE.RELAY_LAT_MAX_M = 20        -- 離路線中心線超過這麼遠＝不在這條路上（平行道路、路口外）
TUNE.FOLLOW_STOP_M = 5            -- 跟車：車頭到前車車尾小於此值＝停等
TUNE.FOLLOW_MIN_M = 6             -- 跟車距離＝MIN＋前車速度×TIME
TUNE.FOLLOW_TIME_S = 1.0
TUNE.FOLLOW_LATERAL_M = 0.3       -- 前車車身離我方車身橫向這麼近以內才算擋在行駛線上
TUNE.KEEP_RIGHT_FALLBACK_M = 1.0  -- 靠右行駛：路寬未知（v2/v3 路線）時，沙盒比例 1.0 換算的公尺數
-- 靠右不貼路邊物（0929j；玩家 Camden County 15m 路、常駐 3.0，右側 l≈+5 一排路邊物離車身 0.76m；E2E 同路段 Oshkosh
-- 23 km/h 擦上 → 倒車兩次 → StopStuck）：靠右是路寬的比例，不知道路緣擺了什麼。前方 KEEP_RIGHT_LOOK_M 內、車身
-- 右緣外 KEEP_RIGHT_CLEAR_M 以內的硬物（形狀世界座標投影回路線，不用取樣點），把靠右目標往左收到留出這段
-- 距離，不過中線（下限 0）。車身右緣內側的硬物是繞行的事，這裡不管。
TUNE.KEEP_RIGHT_CLEAR_M = 0.6
TUNE.KEEP_RIGHT_LOOK_M = 50
TUNE.UNLOADED_CAP = 15         -- 走廊內有未載入 chunk（不知道前面有什麼，先慢）
-- 可視巡航用一般制動域；緊急紅線沿用forceBrake的既有先驗，不再依unloaded旗標切換。
-- 實測的煞車下界另以信心收緊，不能把已學到的弱煞車能力再乘2.5。
TUNE.EMERGENCY_BRAKE_GAIN = 2.5
TUNE.EMERGENCY_BRAKE_MAX = 12
-- 可視巡航帳的煞車倍率：介於舒適 prior 與緊急界限之間（見 visibilityCap 計算處）。
TUNE.CRUISE_VIS_BRAKE_GAIN = 1.5
-- 可視兩帳的時間模型（2026-09-27；計算與定罪理由見 Drive.visibilityCaps）：
TUNE.VIS_TAU = 0.5              -- 固定反應時間（秒）；不再加快照年齡
TUNE.VIS_ROUND_ALPHA = 0.3      -- 掃描輪時（快照完成間隔）EWMA
TUNE.VIS_ROUND_MAX_S = 1.5      -- 單次間隔上限（卡頓一次不把輪時估計推爆）
TUNE.VIS_FRONT_ADVANCE_M = 1.0  -- 可視前緣前進超過這麼多才算「前緣有動」，重設停滯計時
TUNE.VIS_HOLD_MULT = 1.25       -- 巡航帳假設前緣停住：輪時×MULT＋ADD 秒
TUNE.VIS_HOLD_ADD_S = 0.15
TUNE.VIS_UNLOADED_HOLD_S = 1.5  -- 前緣是未載入區塊時至少假設停這麼久（正式服串流停滯 p97）
TUNE.VIS_HOLD_MIN_S = 0.3       -- 停滯逾時後仍保留的最短保持（巡航帳留一點滑行餘裕）
-- 可視前緣就是路線終點時（1002l）：終點是建表就知道的定點，不是會突然冒出來的未知前緣，硬煞帳只算致動延遲；
-- 巡航帳不再另扣障礙緩衝與停滯保持（終點停車由剖面的 Follower.STOP_ASSIST 包絡負責，見 Drive.visibilityCaps）。
TUNE.VIS_TERMINAL_TAU = 0.25
TUNE.VIS_ASSIST_MIN_KMH = 25    -- 巡航減速輔助：低於此速滑行就夠
TUNE.VIS_ASSIST_TOL_KMH = 1     -- 實速超過巡航帽這麼多才開始補
TUNE.VIS_ASSIST_GAIN = 1.0      -- 每超 1 km/h 補 1 m/s²
TUNE.VIS_ASSIST_MAX = 4.0       -- 補的減速度上限（m/s²），疊在滑行之上
-- 彎前晚收油（Follower.STYLES.coastAssist，0928m）：剖面收油包絡已算進這份輔助，實速超過剖面就照
-- 超速量補（增益比可視帳高一倍，均衡時只超剖面約 2 km/h），上限 CURVE_ASSIST_MAX。
TUNE.CURVE_ASSIST_GAIN = 2.0
-- 1002d：4→5.5，剖面假設的輔助（Follower.STYLES.coastAssist）提到 3.5，前饋之外要留比例項的餘地。
TUNE.CURVE_ASSIST_MAX = 5.5
-- 剖面假設的輔助之上留給比例項的餘地（1002l：終點段假設 STOP_ASSIST 6，上限跟著到 8；彎前 3.5＋2＝原 5.5）。
TUNE.CURVE_ASSIST_HEADROOM = 2.0
-- 包絡「在收」的門檻（km/h／次呼叫；Drive.visAssistForce 前饋閘）：沿收油包絡每幀至少掉 a·dt（240 FPS、
-- 4 m/s² 仍有 0.06），弧內 latSafe EWMA 的漂移遠小於此。
TUNE.ASSIST_FALL_KMH = 0.02
-- 繞行超速的減速輔助上限（0928a；HOHOHO/clip-01：63 km/h 時已在縫口前 1m、只能承諾 cap 18 的線，
-- 繞行帽只夾 regulator＝滑行 3 m/s²，到縫仍 56 km/h、追線落後 1m 擦撞）。同一條中線外力、不鎖輪、
-- 轉向照常；只在實速超過繞行套用帽時放大到這個上限。
TUNE.DODGE_ASSIST_MAX = 7.0
-- 進度監督：受控煞停（自己的一秒硬煞閂鎖／引擎原生未載入 chunk 煞車）期間不算「不動」，
-- 但連續煞停超過這麼久仍當卡死（見 Drive.progressPauseMs）。
TUNE.PROGRESS_BRAKE_GRACE_MS = 4000
-- 前方區域未載入的原生煞車（0928a）：前方 1–2 個 chunk 未載入時 CarController 直接煞車（isInvalidChunkAhead，
-- CarController.java:208-216；BaseVehicle.java:3667-3723 看 ClientServerMap／PassengerMap），MP 伺服器忙時串流
-- 跟不上，45–65 km/h 一秒煞到 0（貓貓/clip-09、salomon/clip-13）。這不是卡住：不進停滯監督、不倒車（引擎照樣
-- 煞住倒車，salomon 倒 4 秒只動 0.18m），HUD 顯示等待載入；連續等這麼久才交還。
TUNE.AREA_WAIT_MAX_MS = 30000
-- 離線過遠（0928a；FuFu/clip-01：讓位期間玩家開到路線外 98m，恢復時仍追舊路線）：車離路線超過 SNAP_MAX_M
-- 持續這麼久（主 MOD 偏航重算冷卻 3s 之後）仍沒有新路線接上，以 RouteTooFar 交還，不越野追線。
TUNE.ROUTE_FAR_MS = 4000
-- RETURN 待命滑行核對的車身寬帶餘裕（同 Corridor FOOTPRINT_PAD＝原生 polyPlusRadius 0.15，
-- BaseVehicle.java:4146；見 Drive.returnCoastClear）
TUNE.RETURN_COAST_PAD = 0.15
-- RETURN 釋放：到位兩輪＋車頭對路線在這個角度內（見 updateReturnSnapshot 的 clear 判定）
TUNE.RETURN_CLEAR_HEAD_RAD = 6 * math.pi / 180
TUNE.RETURN_CLEAR_FORCE_ROUNDS = 6
TUNE.LANE_LAG_S = 0.6 -- 常駐線 ramp 的追線落後容忍（Drive.laneRampDev）：車身落在這麼久以前的期望線與現在之間不算偏
TUNE.PROGRESS_HITCH_MS = 500 -- 兩個跟線幀之間的牆鐘間隔超過這麼多＝遊戲卡頓（Drive.progressPauseMs 不算停滯）
TUNE.PROGRESS_HITCH_FRAME_MS = 80 -- 引擎幀時已頂到 fpsMultiplier 上限（1× 速度 83ms）＝卡頓（Drive.progressPauseMs ①）
local POLICY_DODGE = 1         -- 沙盒 ObstaclePolicy enum：1=繞行 2=停車

TUNE.BLOCK_STOP_DIST = 10      -- 距障礙群這麼近才煞停等待；更遠先滑行接近
TUNE.BLOCK_APPROACH_KMH = 20   -- blocked 接近段的速度上限（掃描逼近後縫隙判定更準）
TUNE.BLOCK_APPROACH_HARD_MARGIN = 10 -- blocked 接近包絡的一秒鎖輪只在實速超過 BLOCK_APPROACH_KMH＋此值時（停止線前低速段交給 blockedStop）
-- Knox Pass 大門（1005c，Sensor gateCell）：會替這台車開的關門，車心到門格 ≤ 停止線＋halfL＋車速×此秒數才當硬物
-- （退回關門處理）。更遠只當可視前緣（可視兩帳保證停得住）。這段時間涵蓋「門格被掃到→本輪完成→replan 判堵」的延遲
--（一般 1–2 輪）：判堵在車到停止線之前就成立，停點與寬帶武裝照舊落在停止線。下限（停住時）＝停止線＋halfL，
-- 遠於可視帽讓車停下的位置（前緣－halfL－2－爬行段 ≈ halfL＋6），車不會停在「門沒開、也沒判堵」的地方。
TUNE.GATE_NEAR_LEAD_S = 1.0
-- Knox Pass 會開的門一直不開的提示（1005e，Drive.gateShut）：車停在因這扇門判堵的停止線前，要等到一輪「停住此時長後
-- 才開始」的掃描仍看到門關著才提示。涵蓋伺服器開門延遲（Knox Pass 掃描 250ms、開不了 3 秒後重試）與停點寬帶輪
--（約 1.1 秒）；要短於 BLOCK_RETRY_MS 減一輪，提示才會在 blocked-retry 倒車前出來。
TUNE.GATE_SHUT_MS = 3000
TUNE.WAIT_TIMEOUT_MS = 15000   -- 停等總上限：紅字請玩家接手（2026-09-01 20s→15s）
TUNE.BLOCK_RETRY_MS = 5000     -- blocked 停等此時長仍無縫→主動倒退重掃換視角找路
TUNE.BLOCK_STEEP_RETRY_MS = 500 -- 全滅含大側移 steep（跑道不夠＝靜態幾何）：停穩即倒車，不等 5 秒
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
-- 交還前的最後一次改道（0928m 使用者裁定「遇大量障礙可改道」；Drive.stuckDetour）：每 session 最多 MAX 次，
-- 同一處（NEAR_M 內）不重問；錨點離車超過 ANCHOR_M 或在車後就改以路線切線往前推
TUNE.STUCK_DETOUR_MAX = 2
TUNE.STUCK_DETOUR_NEAR_M = 30
TUNE.STUCK_DETOUR_ANCHOR_M = 30
-- 交還前的替代路線可以繞多遠：剩餘×RATIO＋SLACK（使用者 2026-09-28「完全被堵住的橋，應該增加繞路距離」）——
-- 另一條就是交還，繞 10 km 也比停在路上好；比拖車調頭（×3＋2000）寬
TUNE.STUCK_DETOUR_LEN_RATIO = 4
TUNE.STUCK_DETOUR_LEN_SLACK = 10000
-- 拖車需要調頭時的繞行（Drive.towTurnaround）：避讓圈放車尾正後方、近緣離車心 GAP，往回走的路都得穿圈；
-- 繞一圈本來就長，長度上限放寬到剩餘×RATIO+SLACK；新路線沿起點走 LOOK 公尺的點要在車頭前半平面。
TUNE.TOW_TURN_AVOID_R = 12
TUNE.TOW_TURN_GAP_M = 1
TUNE.TOW_TURN_LEN_RATIO = 3
TUNE.TOW_TURN_LEN_SLACK = 2000
TUNE.TOW_TURN_LOOK_M = 8
TUNE.TOW_TURN_TRIES = 3        -- 每 session 上限（繞行線又要調頭＝再試，不能無限來回）
TUNE.TOW_TURN_WAIT_MS = 2000   -- 等 cutover 的上限；逾時照舊交還
-- 拖車路線上有過不去的轉角（MDADTrailer.shape 的 towBlocked）時的改道（Drive.towCornerDetour）：得知當下就要一條
-- 避開那些轉角的線；避讓圈半徑＝路口方塊半對角線＋PAD；長度上限同拖車調頭（TOW_TURN_LEN_*）；每 session（換目標重置）
-- 最多問 TRIES 次，等 cutover 的上限同 TOW_TURN_WAIT_MS。
TUNE.TOW_CORNER_AVOID_PAD = 2
TUNE.TOW_CORNER_TRIES = 2
-- 同一處反覆調頭（半徑 R 內第 MAX 次 uturn enter）＝路線把車困住，受困交還
TUNE.UTURN_LOOP_R = 30
TUNE.UTURN_LOOP_MAX = 4
-- recovery 方向探測與 episode 重臂。rear 每 100ms 重查；成功倒退後 ban
-- 跨 sensor reset／same-target route cutover 保留，前進 10m 且兩輪 footprint clear 才清。
local REAR_PROBE_MS = 100
local REAR_TRAVEL_M = 4
-- 階梯縮帶（2026-09-08 s026：小巷前 2m 硬物、後 4m 柵欄、側邊路線 3m——4m 帶命中就
-- 「一寸不退」，前後皆堵 15 秒 StopStuck；其實車尾到柵欄有 4m 可退）。4m 帶不清就試
-- 2m、再試 MIN+KEEP；帶長−KEEP＝本次退距，100ms 重探帶長＝剩餘退距＋KEEP。
TUNE.REAR_TRAVEL_SHORT_M = 2
TUNE.REAR_KEEP_M = 0.5
TUNE.EPISODE_REARM_SQ = 100
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
-- 繞行速度政策（2026-09-06 放寬；0924h 使用者裁定「所有檔位繞障礙都要絲滑、不要保守低速」
-- 起不再分風格，全部檔位同一張表，檔位只管上限速度）。表值只是「最終未受保護巡航候選」的速度
-- 政策：分類先用固定 reference（reserve 0.15、5／10 可執行地板）決定要不要貼縫保護；貼縫／彎道
-- 爬行檔與低帽升格當輪都不吃這張表。jerk 3 只用於 shiftSpaceSpeedCapKmh 速度驗算，shiftLength
-- 設計仍用 LATERAL_JERK_MAX 2。典型算例（dl 2m、進入段 20m、aLat 3.5）：clearance
-- 12.5／22.2／30.4 → 16.0／25.0／32.9；κ 尖角地板 15 → 18；短過渡 spaceCap 31.4 → 36。
-- commit 與守護輪共用 updateDodgeCaps 收口；理由與反例見 AGENTS 踩坑錄。
TUNE.DODGE_TUNE = { reserve = 0.10, floor = 18, jerkCap = 3 }
TUNE.DODGE_OV_SPAN = MDADFollower.OV_MAX - 3
TUNE.DODGE_HOLD_SH = 0.15    -- 繞行保持段（entry 已過、未到 c）clearance 帽的橫向速度佔比：車身平行、
                               -- 只剩追線抖動（實測 ld 0.1-0.3 收斂中）；餘裕 0.3 → 13 km/h、0.55 → 26、1.0 → 44
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
TUNE.RETURN_UNLOADED_MS = 4000 -- 回線視距不足（unloaded）持續爬行這麼久就交還一般追線
-- 平均幀時超過這個才算「低幀率」：掃描額度放大到上限（MDADDynamics.scanBudget，0929o）的點＝50ms、20 FPS。
-- 更快的幀率額度會放大到看得到 60 FPS 的距離，視距縮短不是幀率造成的，不提示。
TUNE.LOWFPS_FRAME_MS = MDADDynamics.SCAN_BUDGET_REF_FRAME_MS * MDADDynamics.SCAN_BUDGET_SCALE_MAX
TUNE.LOWFPS_ON_MS = 2000       -- 低幀率降速狀態：持續這麼久才顯示
TUNE.LOWFPS_OFF_MS = 3000      -- 恢復這麼久才消失
TUNE.LOWFPS_NOTICE_MS = 10000  -- 同一趟累計這麼久才跳一次通知
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
-- getMass 可信區間（kg）＝MDAD_VehicleProfile MASS_LO／HI。下限 50 收得進機車 MOD（AMC 130–180 kg＋零件）：
-- 區間外退 MASS_FALLBACK，而轉向／倒車／輔助衝量都乘質量，180 kg 的車當 1200 算＝外力放大 6.7 倍。
local MASS_VALID_LO, MASS_VALID_HI = 50, 5000
local MASS_FALLBACK = 1200     -- 區間外／讀取失敗時沿用的標定車質量（kg）
TUNE.ASSIST_MASS_MIN = 1300
-- 輕車抬到 ASSIST_MASS_MIN 時，等效質量最多是自身的這個倍數（＝原版最輕 800 kg 車本來就拿到的 1300/800）：
-- 機車 MOD（AMC 280–330 kg）照 1300 推＝外力 4–7 倍，E2E 1005k 路外窄縫爬行一幀被推約 1.6 km/h。原版車不受影響。
TUNE.ASSIST_LIGHT_MAX_X = 1300 / 800
TUNE.ASSIST_MAX_ERR_RAD = 20 * math.pi / 180
TUNE.ASSIST_TIRE_REF = 1.4   -- 輪胎抓地基準（廂型車 wheelFriction 1.4）；低於此值越野推力乘 REF/實際
TUNE.ASSIST_BOOST_KMH = 10   -- 越野推力遞增：實速低於此、目標高於此才累積
-- 真的在路外（physicalOffroad）時前推輔助的車速上限（0928m 使用者裁定「路外減速的因素用輔助推力補回」）：
-- 路面上仍是 Dynamics 的 25（引擎推得動），路外引擎推力乘 ≤0.6×越野效率、高檔位更低，一路補到目標
TUNE.ASSIST_OFFROAD_SPEED_MAX_KMH = 120
TUNE.ASSIST_BOOST_MAX = 3    -- 遞增倍率上限
TUNE.ASSIST_BOOST_RATE = 1.0 -- 每秒 +1.0 倍（2 秒到 3×）；退回用 2 倍速率
TUNE.ASSIST_TIRE_MAX = 1.6   -- 輪胎因子上限
-- 加速輔助（1001i；使用者「每台車大多時候維持最高速或檔位最高速」「自動駕駛不是親自操作，不用考慮手感」；
-- 見 Drive.accelAssistForce）：目標比實速高時沿車身中線補這麼多加速度（m/s²），疊在引擎上。E2E 自然加速度
-- 40–80 km/h：一般轎車 2.0–2.5、廂型／貨車 1.3–1.8；正式服載貨重車（M998、Silverado）60–80 km/h 只有 1.3–1.4。
-- 1002d：2.0→3.0。E2E rc47（MAX、24 案）速度損失的最大一塊是出彎加速（curve-coast 且目標高於實速 3 km/h 以上，
-- 佔全部損失 11.6%）；那段 85% 時間輔助已經在補、實得加速度中位數 4.1 m/s²＝引擎＋輔助一起，還是出彎慢。
TUNE.ACCEL_ASSIST_MPS2 = 3.0
TUNE.ACCEL_ASSIST_GAP_MIN = 1  -- 目標－實速（km/h）低於此不補（貼近目標不補＝不過衝）
TUNE.ACCEL_ASSIST_GAP_FULL = 6 -- 差距到此全額（同前推輔助的斜坡）
TUNE.ACCEL_ASSIST_LIMIT_MARGIN = 2 -- 伺服器速限（SpeedLimit<120）以下這麼多 km/h 就停補
TUNE.ACCEL_ASSIST_TOW_PHI = 10 * math.pi / 180 -- 拖車折角超過此值不補
-- 車身離期望線超過此值（m）不補：側向還在收斂時加速＝速度變高、位置回授變弱，越線更多（E2E acc-1001j h1003：
-- Silverado 出彎時離期望線 0.9m 開始補，1.2 秒 31→48 km/h、越過期望線 1m 撞路邊）。補的樣本裡只有 12% 超過 0.5m。
TUNE.ACCEL_ASSIST_LAT_M = 0.5
-- 車頭偏離路線超過此角也不補（1002a）：位置偏差還在 0.5m 內、但正以大角度斜穿期望線＝下一秒就越過去
-- （正式服 0.17.0 Silence/clip-04：出 19° 折點車頭偏 9°、ld −0.43 時開始補，1.5 秒 24→44 km/h 越線 0.56m
-- 擦路邊；E2E acc-1001j h1003 同型 11°）。補的樣本（正式服＋E2E 6031 筆）只有 3.6% 超過 8°。
TUNE.ACCEL_ASSIST_HEAD_RAD = 8 * math.pi / 180
-- 偏差預測（1002t；正式服 0.17.0 clip-17：88 km/h 過 18.9° 未圓角折點，出折點時車還以 1.1–1.4 m/s 橫越期望線，
-- 偏差 0.07／0.32 都在 0.5 內、車頭 6.6°／4.9° 也在 8° 內，加速輔助照補 40→51 km/h，外甩 0.52m 撞路邊物）：
-- 偏差＋橫向收斂速度×LEAD_S 超過 ACCEL_ASSIST_LAT_M 也不補（0.5 秒後就會越過）。
TUNE.ACCEL_ASSIST_LEAD_S = 0.5
-- 只在一般循線的限速下補（1002a）：剖面／彎道包絡、可視距離、檔位與感知上限。朝已知障礙接近（待承諾繞行、
-- 判堵、殭屍、會車、對線…）不補——那些帽本身就是「前面要煞」（正式服 0.17.0 Aho/clip-21：待承諾繞行時補到
-- 45 km/h，再從 39.5 一秒鎖輪煞到 0）。
TUNE.ACCEL_ASSIST_REASONS = { ["curve-coast"] = true, visibility = true, gear = true, perception = true }
-- 樹叢阻力抵消（1004d，使用者 2026-10-04「遇到樹叢也可以加大推力來幫助通過」；見 Drive.bushCancel）：路外／繞行／
-- 回線／倒車時每 BUSH_SCAN_MS 重抓一次車周樹叢（MDADSensor.bushNear，最多 BUSH_MAX_N 個），每幀只對候選算接觸。
TUNE.BUSH_SCAN_MS = 200
TUNE.BUSH_MAX_N = 64
-- 殭屍推撞（2026-09-04 使用者「被一群殭屍阻擋的時候可以增加推力脫困嗎」；s024
-- st148381-148398：帶內 5-10 隻、regulator 全力、speed 1.5-2.5 卡 17 秒，van 1118kg
-- 低於 ASSIST_MASS_MIN 拿不到 assist）：帶內有殭屍、實速低於 SPEED、目標高於
-- TARGET_MIN 持續 DELAY_MS 後，assist 免質量門檻（質量以門檻計）並乘 SCALE。
TUNE.ZOMBIE_PUSH_SPEED_KMH = 5     -- 進入：實速低於此
TUNE.ZOMBIE_PUSH_EXIT_KMH = 9      -- 退出遲滯：推到高於此才收（s031 實測：推到 5.2 就收、
                                   -- 再等 800ms 重推，占空比四成、殭屍群裡蠕動 8 秒）
TUNE.ZOMBIE_PUSH_TARGET_MIN = 10
TUNE.ZOMBIE_PUSH_DELAY_MS = 800
TUNE.ZOMBIE_PUSH_SCALE = 2.0       -- 1.5→2.0（2026-09-04 使用者「可以再增加一點點」）
-- 硬煞外力輔助（0925r 使用者裁定「一定速度之上加外力剎車」）：forceBrake 閂鎖期間實速高於 MIN 時，
-- 對質心加一道沿車頭反向的中心力（零力矩，不影響轉向）。比例與前推 assist 同尺度（ratio×mass×
-- IMPULSE_SCALE），MIN→FULL 之間線性爬到 RATIO。E2E meet park MAX：多人連線停車只在約 55m 內可見，
-- 賽車硬煞實測約 7 m/s²，95 km/h 停不住。
TUNE.EXIT_KEEP_DEV = 0.5 -- 繞行出口：車離常駐線超過此值、且出口還有窄點就沿承諾線走完（Drive.exitKeepsDodge）
TUNE.EXIT_KEEP_CLEAR = 0.5 -- 出口窄點：guard 收集的逐點淨距（已扣 pad）低於此值
TUNE.NEXT_HANDOFF_M = 0.3 -- 下一群滑行停點：離停點這麼近＝已經開到了（Drive.nextStopHandoff；帽趨近 0 時車會先停）
TUNE.BRAKE_ASSIST_MIN_KMH = 40
TUNE.BRAKE_ASSIST_FULL_KMH = 60
TUNE.BRAKE_ASSIST_RATIO = 0.4
TUNE.BRAKE_ASSIST_NEED = 4.5 -- 需要的減速度（m/s²）超過一般硬煞可靠能力才算緊急。0929g：E2E 67 次持續鎖輪
                              -- （起煞後 0.3–0.9s、≥20 km/h、未碰撞）實測 p10 4.35、p25 5.2、中位 7.9；
                              -- 煞車力小、輪胎沒鎖死的車（多半是貨車）中位只有 5.2。舊值 6 讓 PickUpTruck
                              -- 55 km/h、障礙 25m（需 4.6）只靠鎖輪（實得 4.0–4.3），18 km/h 撞上停著的車。
-- 拖車硬煞不鎖輪（0929p，使用者裁定；見 Drive.hardBrake）：這個速度以上改用兩節各自的中線外力
TUNE.TOW_NOLOCK_KMH = 10
TUNE.TOW_BRAKE_DECEL = 7.0 -- 兩節各自的外力減速度（m/s²，同 DODGE_ASSIST_MAX）；斷油的引擎煞車另外疊加
-- 回線待命／調頭前煞停／blocked 接近／待繞行接近在這個速度以上改不鎖輪（1001d／1001e）。1004b 起 25→10（使用者核准，
-- 與拖車／讓車／彎道同一個門檻）：不鎖輪（斷油＋中線外力）實測約 10 m/s²、鎖輪 6–8，而且照常轉向、輪胎保有側向
-- 抓地——正式服 0.18.2 Sixya clip-14：23 km/h 回線待命鎖輪，車頭帶 0.11 rad 往右滑 1.6m 撞樹。10 以下照舊鎖輪停住。
TUNE.RETURN_NOLOCK_KMH = 10
-- 堵住時放寬橫向掃描（0929p，使用者裁定「允許繞到道路之外」；見 Drive.wideScanWanted、MDADSensor 寬帶）
TUNE.WIDE_SCAN_KMH = 5
TUNE.WIDE_ARM_SAME_M = 6 -- 判堵錨離武裝時的錨超過這個距離＝換了一個堵點（Drive.blockedAtStop 解除武裝）
-- 寬帶逐級加大（1004c，使用者 2026-10-04「障礙多的地方不要太早判定繞遠路，逐漸掃描加大、找得到回到道路的路線就走，
-- 真的都不行才考慮繞道」）：停點寬帶判完仍堵（且不是跑道不夠）就升一級重掃（MDADSensor WIDE2，±19.5），最寬那級
-- 判完倒車／改道才能動；每次倒車後的新嘗試從第一級重來（Drive.wideJudge）。第二級的判堵候選鏈只搜外圈
-- （Corridor.plan 的 ringFrom＝sen.corridorInner）：內圈第一級已判過，再試一次只是把候選額度用在同樣掃不過的近縫。
-- 拖車維持第一級（路外繞行的使用者範圍：拖車以外）。
TUNE.WIDE_LEVEL_MAX = 2
TUNE.WIDE_JUDGE_GRACE_MS = 3000 -- 停等預算到期時等這次嘗試的寬帶判完的上限（Drive.wideJudgePending）
-- 殭屍軟縫（2026-09-06；殭屍當「軟縫」處理，只出一個橫向目標、不另拉軌跡）：
-- 每輪掃描完成、持有權 free（無 dodge／RETURN／停留／調頭）時，用 Sensor 的殭屍 (s,l) 點雲
-- 在常駐 lane ±DELTA 的可行帶找離殭屍區間最近的 lane（Corridor.softZombieLane），時間平滑
-- （τ、速率上限）後寫進 laneBias；硬物先裁出連通淨空帶，再逐硬物檢查當下有效車道間的
-- 橫移範圍（laneRoom 只管路寬不管牆／停車）。殭屍是可撞的：無縫＝維持原 lane、不 blocked，
-- 交給既有數量減速檔；點雲溢出（殭屍群）棄權。玩家可在 ESC「閃避殭屍」關閉。
TUNE.ZOMBIE_LANE_DELTA = 6.0      -- 離常駐 lane 的最大側移（m；防呆上限）；實際帶＝整個 laneRoom／感測路面帶。
                                  -- 必須 > 殭屍佔位半徑 halfW＋0.65（≈1.6）：1.5 時正壓車道的殭屍永遠「無縫」（實機 2026-09-06）
TUNE.ZOMBIE_LANE_LAMBDA = 1.0     -- 連續項權重：cost＝(u−base)²＋λ(u−prev)²
TUNE.ZOMBIE_LANE_TAU_MS = 300     -- 目標平滑時間常數（0925d 600→300：尾段收斂太慢，交錯殭屍換邊來不及）
TUNE.ZOMBIE_LANE_RATE_MPS = 1.0   -- lane 變化速率上限（10 m/s 下對前視點只多 6°；瞬跳 1m 會觸發 align 減速）
TUNE.ZOMBIE_LANE_RATE_PER_MPS = 0.25 -- 速率＝車速×此值（0925d 0.1→0.15；0925p 0.25：路夠寬時大幅快速閃避是允許的）；下限 RATE_MPS
TUNE.ZOMBIE_LANE_RATE_MAX = 6.0     -- 速率上限（m/s；0925d 2.5→3.5；0925p 6：MAX 檔 110 km/h 車身只橫移 1.4 m/s，擦邊 d 0.02）
-- 高速多留的餘裕（0925p E2E road MAX：11 次撞擊 9 次是 d≤0.04 的擦邊）：PREFER 從 SLOW_KMH 起線性加到
-- FAST_KMH 再多 EXTRA 公尺；段不夠寬仍退回貼 R（softZombieLane 既有行為）。
TUNE.ZOMBIE_PREFER_SLOW_KMH = 40
TUNE.ZOMBIE_PREFER_FAST_KMH = 110
TUNE.ZOMBIE_PREFER_EXTRA_M = 0.7
TUNE.ZOMBIE_CROSS_S = 2.5          -- 到最近威脅不足此秒數時，選縫先限車身這一側（不橫越牠的現位；0925 零散殭屍
                                   -- E2E 1.5：70 km/h 距 37m〔1.9s〕從左側翻到右側穿過 l 3.1 那隻）
TUNE.ZOMBIE_SWITCH_LAG_S = 0.5      -- 群與群之間換邊：先止住上一段側移再反向的落後（秒）
TUNE.ZOMBIE_PREDICT_S = 2.5         -- 殭屍橫向位置外推的最長秒數（朝車走的殭屍）
TUNE.ZOMBIE_CLUSTER_M = 1.0         -- 最近一群＝最近威脅點起「一個車長＋此值」內的軟避讓點
TUNE.ZOMBIE_LANE_SETTLE_M = 0.05  -- 回到常駐 lane 這麼近＝釋放
TUNE.SOFT_HARD_JITTER_M = 0.5     -- 軟縫可行帶離硬物擋線帶緣多讓的量（hardL 取樣柱在格內跳動，見 zombieLaneOf；1002t）
TUNE.ZOMBIE_LANE_LEAD_S = 0.3     -- 側移完成後還要留這麼多秒才到殭屍（車身追 laneBias 的落後；0925d 0.5→0.3）
TUNE.ZOMBIE_LANE_MIN_KMH = 12     -- 縱向配合帽下限（殭屍可撞：壓到爬行仍過不去就撞，不停等）
-- 動物與車外的其他玩家（1005 soft）：併入同一次軟縫選縫（Sensor zomKind）。動物的兩個名單（2026-10-05 使用者裁定）：
--   ESC AnimalDodge（閃避名單，1 關／2 大型／3 全部）＝可以照巡航速度閃的動物；
--   沙盒 AnimalSlowdown（減速名單，同分級）＝必須保護的動物：閃得過就閃，閃不過才停等。
-- 任一名單選到就參與選縫（Drive.softJoins）；只在減速名單、不在閃避名單的（gentle，Drive.softGentle）成為威脅時，先以
-- 接近包絡把車速降到 ANIMAL_GENTLE_KMH 再照軟縫繞過，車尾過了牠才解除（Drive.softGentleCap）。其他玩家永遠參與。
-- 碰撞模型同殭屍（引擎車撞動物也是 0.3 圓，IsoAnimal.java:466-476）。
TUNE.SOFT_COMFORT_M = 0.6          -- 大型動物與玩家另加的橫向舒適餘裕（佔位兩側各多這麼多；小型動物、殭屍、屍體不加）
-- gentle 動物的繞行速度：軟縫側移速率＝max(ZOMBIE_LANE_RATE_MPS, 車速×RATE_PER_MPS)，15 km/h 時 1.04 m/s＝每前進 1m
-- 側移 0.25m，跟高速時同一個比例（側移能力不因降速變差），一個車道（3m）約 12m 內做完；又高於 ZOMBIE_LANE_MIN_KMH
-- 與 MIN_EXEC（仍是 GO，不被當成停等），碰撞速度只有巡航的一小部分。
TUNE.ANIMAL_GENTLE_KMH = 15
-- 停等：沙盒 AnimalSlowdown 選到的動物與其他玩家（永遠）在選定的行駛線上、軟縫清不開（含側移來不及）時，
-- 以接近包絡停在它前方 SOFT_STOP_GAP_M（Drive.softStopCap）。動物停等另外計時、不吃共用停等預算 waitAccumMs：
-- 停住累計 ANIMAL_WAIT_MS 後以 ANIMAL_CRAWL_KMH 爬過（引擎 <5 km/h 車損為 0，BaseVehicle.java:5699-5705）；爬行
-- 累計 ANIMAL_CRAWL_MAX_MS 動物仍擋著（MP 動物被車推著走不一定會死）＝以 Drive.KEY_ANIMAL_STOP 交還。動物離開又回來
-- 而車沒真的前進（WAIT_PROGRESS_M）時兩個計時都不歸零（停→放→停 也有出口）。玩家一律停等，吃共用停等預算、
-- WAIT_TIMEOUT_MS 到期以 Drive.KEY_PLAYER_STOP 交還（不推人）。
TUNE.SOFT_STOP_GAP_M = 3.0         -- 停在目標前（車頭到目標）的距離
TUNE.ANIMAL_WAIT_MS = 6000         -- 動物擋線時停住多久才爬過
TUNE.ANIMAL_CRAWL_KMH = 4          -- 等待到期後的爬行速度（≤4：引擎 <5 km/h 不算車損）
TUNE.ANIMAL_CRAWL_MAX_MS = 15000   -- 爬行累計這麼久動物仍擋著＝交還（4 km/h 約 17m：推著牠走了一段還是沒讓開）
-- 越野旗標進 traction key 的去抖（FPS：s031 st149350-149356 彎道路緣一輪壓草一輪回鋪面，
-- physicalOffroad 每秒翻一次 → key 1↔33 每翻一次 `dyn rebuild` 8-16ms（292 點剖面）
-- ×8 次／6 秒＝可見 hitch）。旗標持續同值 ≥ 這麼久才進 key／priors；raw 值仍供
-- assist rough／mismatch 判定即時使用。
TUNE.OFFROAD_KEY_DEBOUNCE_MS = 1000
-- 同線物理複驗（2026-09-04 s037 vs s038 同位置重啟一次 blocked 一次過：巡航檔候選
-- offL 3.50 以 −0.06 打槍後，降檔重規劃給的是另一條 lane 3.25（需求變小、縫中心
-- 跟著移）以 −0.20 打槍，沒人用物理 pad 再掃 3.50 本身；guard 早就有「guard 失敗→
-- guard-probe 同線再掃」的兩段式，plan 鏈沒有）。巡航／重試候選以小於此淨距打槍
-- 時，同一條線先以物理 pad 複掃，過＝爬行承諾（同 probe 檔語意）。
TUNE.PHYS_RECHECK_M = 0.5
-- 同縫微調（2026-09-04 s044 vs s045 同位置：crawl 候選 +3.25 打槍 −0.07、ban 帶
-- ±(0.25+need) 把鄰格 +3.50 一起封掉；重啟後 corridor 先給 +3.50 → 物理 0.31 過、一次
-- 繞過兩台車）：(s,l) 線性化誤差 ±0.1-0.3m 而 lane 格 0.25，打槍淨距小於此值時把
-- 同一條線往「遠離命中點」側移一格再掃一次，過＝承諾。每個近失候選最多加一次掃掠。
TUNE.NUDGE_MAX_M = 0.3
TUNE.NUDGE_STEP_M = 0.25
-- 貼縫拓寬（2026-09-04 s057 圖 3「應該再偏右邊一點」：候選鏈停在**第一條**掃過的 lane，
-- 物理檔 0.05m 淨距貼著黑車過，右邊明明還有路）：掃掠過但淨距小於此值時，往「遠離最近
-- 點」側移一格再掃一次，淨距更大就換——同一個縫選較寬的位置，不換縫。
-- 0.15 → 0.35（2026-09-04 s018：+2.0 margin 0.26 承諾，5-10 km/h 進縫橫向落後 0.26 剛好吃光
-- 餘裕 → contact → 倒車 → 同線再 commit ×3 → StopStuck；貼縫追線的落後實測 0.25-0.4，餘裕
-- 低於這個量就該先試往寬處挪一格）
TUNE.NUDGE_WIDEN_M = 0.35
-- 換縫找更寬（1004f；E2E f1004e dixie9050w 改道線：爬行候選 +5.5 物理淨距 0.07 掃過就承諾，5 km/h 進縫落後 0.3 擦到
-- 車角；倒車後同一處改承諾另一側 −5.5 淨距 0.39、cap 5→10 順利通過）：重試／爬行檔採納的候選物理淨距（margin＋
-- sweep base−halfW）低於此值時先記下、ban 掉往下找，找到更寬的就換，找完沒有就用記下最寬的那條（Drive.thinNote）。
-- 拓寬（NUDGE_WIDEN_M）只在同一個縫裡挪一格；這裡換縫。不否決通行：只有更寬的也掃過才換。
TUNE.DODGE_THIN_M = 0.3
-- 窄縫進入段用滿跑道（1004g；E2E h1004f dixie9050w：唯一的縫物理淨距 0.16、彎上 11.45m 塞 6.3m 側移，最彎處半徑
-- 約 3.4m 接近這台車的最小迴轉半徑 3.03m，轉向延遲讓車落後 0.16–0.2m 擦到；車到 b 其實有 19.9m 跑道沒用）：掃過的
-- 候選物理淨距仍低於 DODGE_THIN_M、車到 b 的跑道比設計進入段長時，同一條 offL 以較長進入段（最多設計長的此倍數）重建
-- 再掃，淨距沒變窄就換（sweepWithFallbacks 的 stretch）。不降速：較長的進入段讓空間帽反而放寬。離線
-- scripts/exp_arc_commit.lua (E) 同型線（R17 弧、6.33m 側移）低增益 plant 落後 0.21–0.26 → 0.00–0.11（15／19.9m）。
TUNE.ENTRY_STRETCH_MAX = 2
-- 貼縫可執行下限（同 s057：commit cap 0.5／0.6／1.3／1.7 km/h＝淨距 0.05-0.08 的
-- clearanceCap；CRAWL intent 沒有 MIN_EXEC 地板，車以 1 km/h 爬、進度看門狗 6 秒判卡
-- → 倒車 → 再承諾同一條 0.5 km/h 的線 → 三次用盡 → attempt-limit 每 2.5 秒一次、CRAWL
-- 不計停等預算＝永不交還（s058/s059 兩檔 100 秒全是 attempt-limit）。regulator 是二值
-- 供油（CarController.java:240-244），5 km/h 以下的目標執行不出來，1 km/h 的轉向權威也
-- 比 5 差。地板而非否決：09-01 使用者裁定「物理可過就過」（3.0m 混材縫 11cm 淨距要過）
-- 維持，貼縫一律至少以此速度走，擦撞由 contact fail-closed 兜底（同 alignmentCap 12 地板
-- 的精神）。守護輪同地板。
TUNE.DODGE_COMMIT_MIN_KMH = 5
-- 貼縫第二檔（2026-09-04 s019@0904t 使用者「只用 5 km 通過太慢，確定無障礙後可以 10 以上嗎」）：
-- clearanceCap 用 sinHeading=1（承諾長 3.8m 對 2m 側移）把 0.16m 淨距壓成 1.6 → 地板 5；
-- 但守護輪實測淨距 0.16-0.25 一路穩定、車身已對線。淨距 ≥ MID_MARGIN 的貼縫地板抬到 10：
-- 這是「掃掠已證整條線至少留這麼多」的物理事實，不是猜測；<MID_MARGIN 仍 5。真擦撞由
-- contact fail-closed（pad 與掃掠同源）兜底。守護輪同檔。
TUNE.DODGE_CRAWL_MID_KMH = 10
TUNE.DODGE_CRAWL_MID_MARGIN_M = 0.15
-- 鏈式停留（2026-09-04 s046/s047 Quiet St 東向：B 車北側 lane −2.0 可過、回線段撞到
-- 12m 外北半 A 車 −0.08；A 只能貼北緣 −3.5 過——兩段不同 lane 的同側連續繞行，單一
-- 側偏剖面表達不了，使用者裁定「明明繞過那台車後面也能正確判斷」）：候選只在回線段
-- （p4）打槍時，改掃「到 c＋車身」的停留線（rs→b 換道、之後平行不回線），過＝承諾
-- 停留：commit 即把常駐 lane 換成 offL（laneChained），剖面走到 c 釋放，下一輪 replan
-- 從新 lane 規劃下一台（第二段是普通繞行、出口回停留 lane）；前方淨空時解鏈交回
-- 常駐偏置（RETURN／pure pursuit 帶回）。門檻：停留 lane 在路面餘裕內（laneBiasAt
-- 不夾）＋ corridor 從該 lane 對下一群仍找得到縫（整寬牆＝不停留，維持 09-02
-- 「貼縫不鑽死路」）。
TUNE.STAY_TAIL_M = 0.5
-- 鏈上「回家」候選（offL 在常駐線那一側、離常駐線 ≤ 此值）一律以停留承諾（無回線段），
-- 不建「回到鏈 lane」的全繞行：2026-09-04 s027 t=19→23 定罪——鏈在 −3.25 過 A，B 的縫在
-- +1.75，全繞行的回線段要把車再甩回 −3.25；guard 在回線段判死 → 從 −3.25 為基準再 commit
-- 一段 −3 crawl-stay，車已在 +1.5 → RETURN lateral → hold 2.5s 原地。停留＋下一輪 clear
-- 解鏈（1.75→1.5）才是「過了 A 回家」。對側非回家候選仍走 side 規則（防 s051 擺盪）。
TUNE.STAY_HOME_M = 1.0
-- 貼縫承諾速度閘（2026-09-04 s021/s030：21 km/h 當幀 commit cap 5、margin 0.06-0.11 的線，
-- 進入段起點在車前 1m；煞到 5 已吃掉整段進入段，橫向落後承諾線 0.27-0.40 > margin →
-- contact → 倒車；從靜止重 commit 同一條就過）：現速超過 cap 此值以上、且到進入段起點
-- 前煞不到 cap → 本輪不承諾，改套接近 envelope（dodgeDeferCap）先減速，下一輪再問。
TUNE.DODGE_SPEED_TOL = 3
-- 已經貼到縫口（車頭到 b 不足此值）就不延後——延後只會讓下一輪進入段消失、全滅 blocked
-- 停等倒車（2026-09-04 s@172615 路口最後一彎：18→14.6 km/h 連延兩輪後 b−rs<1 → blocked）；
-- 此時承諾＋接近帽減速是較小的惡。
TUNE.DODGE_SPEED_DEFER_MIN_M = 1.0
-- 停留承諾提早釋放（2026-09-04 s034/s036：停留 −2 過 A 到 c 才釋放，B 的縫在 c 後 3m——
-- 24.7 km/h 到縫前 3m 才開始規劃 B，速度閘／進入段都來不及 → blocked → 倒車）：車已在停留
-- lane 上（過 b＋1m、橫向誤差 ≤ STAY_SETTLED_M）且走廊從停留 lane 看前方是「有縫可繞」
-- （不是 clear／blocked）就釋放，讓下一段從現在規劃；進入段起點不得早於停留段終點 c
-- （stayHoldEndS），避免從 A 旁邊切出去。
TUNE.STAY_SETTLED_M = 0.35
TUNE.STAY_LOOK_STEPS = 4 -- 停留 lane 前瞻最多試幾次掃掠（每次 ~25ms Kahlua）
TUNE.DODGE_INPLACE_M = 0.6 -- 候選 lane 離車實際橫向 ≤ 此值＝視為已在該 lane，進入段可為零（群已在車旁）
TUNE.UNSTICK_STEEP_MAX_M = 8 -- steep 差額最多讓倒車多退幾公尺（4s 時限＋後方探測仍把關）
-- 車頭對路線超過這個角度就不加長倒車（見 Drive.unstickExtraM：斜著倒只會橫移出路外）
TUNE.UNSTICK_EXTRA_ALIGN_RAD = math.pi / 4
-- 倒車脫困的車速上限（km/h）：超過就不再施倒車衝量、讓車滑回上限以下。舊制每幀固定衝量、沒有速度
-- 上限，退得越遠越快——正式服 44 段有倒車的片段 7 段超過 15 km/h（最高 21），E2E startpush-sp 退 11m
-- 衝到 31 km/h、再花 2.5 秒煞 11m；後方探測帶只有 4m、每 100ms 探一次，這個速度煞不住。10 km/h
-- 煞停約 0.6m＋探測間隔 0.3m，仍在探測帶內；4 秒時限內仍可退約 9m（時限到且已退 1m 照常進 settle）。
TUNE.UNSTICK_REVERSE_KMH = 10
-- 越野接線（Drive.approachRoute）：車投影在路線起點之前超過這個距離才接；接線段的宣告寬度（路外沒有
-- streets 寬度，取一般單線道寬：常駐靠右在接線上幾乎收成 0，車從自己的位置出發）
TUNE.APPROACH_BEHIND_M = 1.5
TUNE.APPROACH_WIDTH_M = 4
-- 進入段陡坡拒收（2026-09-04 s051：stay 鏈把常駐 lane 拖到 −2.25 後，下一候選 +2.00＝
-- 4.25m 側移塞進 2.8m 進入段；運動學最小 8.8m（sqrt(6·dl/κ_crawl)），比例 3.1 → 承諾
-- 線掃掠過但車追不上、clearanceCap 被 sinHeading=1 壓到 2.3 km/h 爬 4 秒被 RETURN 殺）。
-- 09-01 s052 決定「entry 塞多少給多少」的案子是 dl 2.5／avail 2.8／最小 6.7＝比例 2.4，
-- 保留；比例超過此值＝任何速度都追不到的幾何，拒收候選讓鏈去找側移小的縫，或倒車
-- 重掃（人開也是先退再切）。exit 側不設（近目標截斷 s019 案照舊）。
-- 2026-09-04 曾對大側移（>1.5m）另設 1.6 的嚴閘，把 Quiet St 那條 5m 側移／6m 跑道的線全拒掉
-- （之前 ratio 3 曾一次過）；使用者裁定「不用太保守，轉彎角度可以修」→ 單一閘 3，陡切的代價由
-- clearanceCap／crawl 檔壓速承擔，不由拒收承擔。
TUNE.SHIFT_MIN_RATIO = 3
-- 倒車補跑道只記大側移（> 此值）的 steep 差額：小側移的 steep 多是「障礙就在車前」，標準倒車距離即可
TUNE.STEEP_DEFICIT_MIN_DL = 1.5
-- 繞行承諾中 RETURN 的進入門檻（m；理由見 stepFollow 的 RETURN 入口）
TUNE.RETURN_DODGE_DEV = 4
-- cross-track D 項的單幀橫向速度上限（m/s）：超過＝期望線台階（弧邊界 laneRoom 夾 bias、
-- 停留切 lane），不是車真的在橫移；理由見 stepFollow 的 cross-track 段（0907b）
TUNE.CROSS_TRACK_DLAT_MAX = 5
-- 倒車中途後方探到障礙時，已退超過此距離就當一次成功脫困進 settle（理由見 stepUnstick）
TUNE.UNSTICK_MIN_M = 1.0
-- debug 打槍行去重（FPS：blocked 停等時每輪 4Hz × 候選鏈 7-9 條 sweep fail 各印一行
-- ＝每秒 30 行 console I/O；2026-09-04 使用者問 FPS）：同 (tag, offL) 每秒最多一行。
-- 復盤仍拿得到每條候選的首次與每秒一次的判決；telemetry blocked 事件另有 detail。
TUNE.SWEEP_LOG_MS = 1000
-- replan 牆鐘遙測最多每 REPLAN_CLOCK_MS 量一次（前後各讀一次 getTimestampMs；毫秒時鐘只當現場分佈，歸因用 GameProfiler）
TUNE.REPLAN_CLOCK_MS = 250
-- sweepLine 整塊剔除的塊大小（連號硬點數；Drive.sweepScratch）：太小＝塊測試本身變貴，太大＝塊外框鬆、剔不掉
TUNE.SWEEP_BLOCK_N = 8

-- 速度域上限與世界感知距離分開：距離由偏好、速度與後續障礙／彎道需求決定。
TUNE.PERCEPTION_CAP_KMH = 85
-- 既有高速域維持120；可見性／路線與車況帽仍可往下限制。
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
-- 改用向後衝量直接推車（relPos=(0,0,0) 純中心力，不產生力矩）。退夠距離或超時就收手。
local UNSTICK_MS = 4000        -- 單次脫困的時間上限
local UNSTICK_DIST_SQ = 9      -- 退離卡點 3 公尺（平方比較省 sqrt）＝成功
-- 貼縫 contact 後的倒車距離加長（2026-09-04 s004@0904n：退 3m 後距黑車只剩 1.8m，
-- 再 commit 同一條 1.1m 側移＝比例 2.5 勉強過閘、車頭 30° 斜切仍追不上、前角再撞；
-- 每次退 3m 撞回同一點三次交還。貼縫 contact 就是「進入段不夠長」的直接證據，
-- 下一次要從更遠處起手）。每次同 episode 的倒車再多退此距離（同 4s 時限、rear probe 照驗）。
TUNE.UNSTICK_DODGE_EXTRA_M = 3
-- 貼縫承諾的起手姿態門檻（2026-09-04 s@166216：倒車後車頭偏路線 27°，當幀就 commit
-- −3.50 貼縫；掃掠驗的是「車身沿線」的 OBB，車實際帶 22-33° 偏頭切進去＝前角撞黑車
-- contact 三次交還。使用者「是不是沒有維持在線的中心」——是姿態不是位置）。貼縫
-- （crawl／physical）承諾只在車頭對路線切線 ≤ 此角才 commit，否則本輪延後讓 pure
-- pursuit 先擺正（cruise 檔餘裕大，不受此閘）。
TUNE.DODGE_CRAWL_ALIGN_RAD = 20 * math.pi / 180
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
-- 卡住交還時的診斷提示（0904i，使用者裁定「預設關＋StopStuck 時提示」）：診斷關著才提示、
-- 每次啟動每位玩家一次（真卡住才提示＝命中需要回報的人；常態零成本）。白字非紅字。
local KEY_TELEMETRY_HINT = "UI_MinidoracatAutoDrive_TelemetryHint"
local telemetryHinted = {}
local KEY_BLOCKED = "UI_MinidoracatAutoDrive_Blocked"
local KEY_UNSTICK = "UI_MinidoracatAutoDrive_Unstick"
local KEY_DODGE = "UI_MinidoracatAutoDrive_Dodge"
local KEY_ROUTE_FAR = "UI_MinidoracatAutoDrive_RouteTooFar"
local KEY_DETOUR = "UI_MinidoracatAutoDrive_Detour"
local KEY_NO_DETOUR = "UI_MinidoracatAutoDrive_NoDetour"
local KEY_TRAFFIC = { -- 會車提示（一張表：主 chunk local 槽已在上限邊緣）
    yield = "UI_MinidoracatAutoDrive_TrafficYield",
    pass = "UI_MinidoracatAutoDrive_TrafficPass",
    wait = "UI_MinidoracatAutoDrive_TrafficWait",
}
-- 前方區域遲遲未載入的交還理由（TUNE.AREA_WAIT_MAX_MS；掛在 Drive 表：主 chunk local 槽已滿）
Drive.KEY_AREA_STOP = "UI_MinidoracatAutoDrive_AreaLoadStop"
-- 其他玩家擋在行駛線上、停等預算 WAIT_TIMEOUT_MS 用完的交還理由（Drive.softStopCap；不推人、不改道）
Drive.KEY_PLAYER_STOP = "UI_MinidoracatAutoDrive_PlayerBlockStop"
-- 動物一直擋在行駛線上、爬行 ANIMAL_CRAWL_MAX_MS 仍沒讓開的交還理由（Drive.softStopCap）
Drive.KEY_ANIMAL_STOP = "UI_MinidoracatAutoDrive_AnimalBlockStop"

-- 診斷輸出（只在 getDebug() 為真時存在）。實機回報「按了關閉但車還在跑」時，唯一能
-- 分辨「session 沒關」與「只是慣性滑行」的證據就是這幾行；跟線那行必須節流，每幀
-- 一行會直接把 console 洗爆並吃掉 FPS。getDebug()＝Core 的除錯模式旗標，原版到處
-- 這樣守門；旗標為假時下面所有 string.format／print 連碰都不碰。
local LOG = "[MDAD Drive] "
TUNE.DEBUG_MS = 1000           -- 跟線診斷的最小間隔（毫秒）
TUNE.DEG_PER_RAD = 180 / 3.14159265358979

-- HaloTextHelper.addBadText／addGoodText 用例：ISVehiclePartMenu.lua:252、ISReadABook.lua:95
-- 每則頭上提示同步右上 Toast（MDADDiagnostics.toast；診斷模組缺席即只有 Halo）。arg＝翻譯 %1（選填）；回顯示的文字。
local function haloBad(playerObj, key, arg)
    local text = arg ~= nil and getText(key, arg) or getText(key)
    HaloTextHelper.addBadText(playerObj, text)
    if MDADDiagnostics and MDADDiagnostics.toast then MDADDiagnostics.toast(text, "bad") end
    return text
end

local function haloGood(playerObj, key)
    local text = getText(key)
    HaloTextHelper.addGoodText(playerObj, text)
    if MDADDiagnostics and MDADDiagnostics.toast then MDADDiagnostics.toast(text, "good") end
end
Drive.haloBad, Drive.haloGood = haloBad, haloGood -- HUD 回家鈕共用同一組提示

local function maxSpeedKmh()
    local v = MDAD.sandbox("AutoDriveMaxSpeed", 120)
    if type(v) ~= "number" then v = 120 end
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
    if not route or state ~= "ok" then return nil, tx, ty, state end
    return route, tx, ty, state
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

-- v6 多停靠點行程（docs/addon-api.md §6）。整組介面缺一不可；版本不足或少一個函式
-- 就整段降級走舊的單站路徑——沒有 claim 就沒有到站回報，Driver 不得自己模擬行程狀態。
-- 常數、翻譯鍵與冷路徑小函式全掛在這張表上：主 chunk 的 local 槽已經貼著 Kahlua 的
-- 190 上限（scripts/verify_mod.py 1b），每多一個 local 都是載入期編譯失敗的風險。
local TRIP = {}
-- 行程待辦計數（熱路徑守門用，必須是 local）＝準備意圖＋欠 MiniMap 的交還。
-- 兩者皆 0 且無 session 時，OnPlayerUpdate 仍是兩次整數比較就 return。
local prepCount = 0
-- 備路線／剖面的等待上限：逾時自行取消，不讓玩家對著沒反應的按鈕重複點。
TRIP.PREP_MS = 15000
-- 到站回報被拒（例如 MiniMap 還沒認定停妥）之後的有界重試視窗：期間維持 arrive、
-- 維持停妥、不清 session，也不假報抵達。
TRIP.REPORT_MS = 3000
-- 交還被拒之後的有界重試視窗：不能把仍有效的 claim 丟掉變成 orphan。
TRIP.RELEASE_MS = 5000
TRIP.BUSY = "UI_MinidoracatAutoDrive_TripBusy"
TRIP.STATE = "UI_MinidoracatAutoDrive_TripState"
TRIP.STALE = "UI_MinidoracatAutoDrive_TripStale"
TRIP.NOT_STOPPED = "UI_MinidoracatAutoDrive_TripNotStopped"
-- 道路終點：**不是**抵達。不可播成功語音，也不可宣稱到了最終目的地。
TRIP.ROAD_END = "UI_MinidoracatAutoDrive_TripRoadEnd"
TRIP.LOST = "UI_MinidoracatAutoDrive_TripLost"
-- v7 多站行程的四個提示鍵（HUD lane 供應）：中途續開／停靠等候／插入優先目標／
-- 整份行程完成。續開與優先只在**真的 commitSession**（車已在我們手上）時出現，
-- 停靠與完成只在真的停在站上時出現——這四個鍵都不是「大概到了」的猜測。
TRIP.CONTINUE = "UI_MinidoracatAutoDrive_ContinueTarget"
TRIP.STOPOVER = "UI_MinidoracatAutoDrive_StopoverReached"
TRIP.PRIORITY = "UI_MinidoracatAutoDrive_PriorityTarget"
TRIP.COMPLETED = "UI_MinidoracatAutoDrive_TripCompleted"
-- 主 MOD 的被動到站半徑（§6.3 的 5 格，平方比較）：v7 Core 在**沒有 claim**時，
-- 玩家停在這個半徑內就自己把站收掉。準備期間只用它判斷「不值得為不足 5m 的路線
-- 做剖面」，絕不用它自己宣告到站。
TRIP.ARRIVE_SQ = 25
-- start／claim／report／release 的失敗原因（§6.4 的原因集合）→ 玩家看得懂的翻譯鍵。
TRIP.REASON = {
    badargs = TRIP.STATE,
    noplayer = KEY_NOT_DRIVER,
    noitinerary = TRIP.STATE,
    state = TRIP.STATE,
    stale = TRIP.STALE,
    busy = TRIP.BUSY,
    notdriver = KEY_NOT_DRIVER,
    notstopped = TRIP.NOT_STOPPED,
    noroad = "UI_MinidoracatAutoDrive_TripNoRoad",
    failed = "UI_MinidoracatAutoDrive_TripFailed",
}
-- release 的 reason 只是 UI 原因、**不代表到了**；§6.4 只收這五個值，未列出的停止
-- 原因一律 unavailable，玩家主動關閉（reasonKey 為 nil）是 manual。
TRIP.RELEASE = {
    [KEY_LOST] = "noroad", [KEY_ROUTE] = "noroad", [KEY_ROUTE_FAR] = "noroad",
    [KEY_STUCK] = "failed", [KEY_UNSUPPORTED] = "failed", [Drive.KEY_AREA_STOP] = "failed",
    [Drive.KEY_PLAYER_STOP] = "failed", [Drive.KEY_ANIMAL_STOP] = "failed",
}
-- playerNum → 開始／備路意圖（token=nil 時尚未 acquire；claim 前對車零控制輸出）
TRIP.preps = {}
-- playerNum → 欠 MiniMap 的交還（release 被暫時拒絕；有界重試，不丟 claim）
TRIP.owed = {}

-- blocked 的第三回傳是既有 nav gate 的 reasonKey（§6.4）；其餘照表。未知原因退
-- TripState，絕不當成成功。
function TRIP.key(reason, gateKey)
    if reason == "blocked" then
        if type(gateKey) == "string" and gateKey ~= "" then return gateKey end
        return "UI_MinidoracatAutoDrive_NeedGPS"
    end
    return TRIP.REASON[reason] or TRIP.STATE
end

-- 行程介面守衛（§2 分欄位分級的作法，同 cachedSnapTrusted）：navApi() 之上再要求
-- navApiVersion >= 6 與六個函式全在。每次用前重查——主 MOD 可能根本沒裝或版本太舊。
function TRIP.api()
    local api = navApi()
    if not api or api.navApiVersion < 6 then return nil end
    if type(api.getNavLeg) ~= "function" or type(api.getNavItinerary) ~= "function"
            or type(api.startNavItinerary) ~= "function"
            or type(api.claimNavLeg) ~= "function"
            or type(api.reportNavArrival) ~= "function"
            or type(api.releaseNavLeg) ~= "function" then
        return nil
    end
    return api
end

-- v7 介面能力（便宜、無配置）：版本與新函式都在。這只說「介面在」。
function TRIP.v7(api)
    return api.navApiVersion >= 7 and type(api.setNavContinuation) == "function"
end

-- v7 行程快照（自動接續與被動到站採用的唯一資料來源）。真正決定行為的是資料面：
-- 只有 schemaVersion 2 的行程才有 autoContinue／activation 可讀；任一條不成立就回
-- nil＝照 v6 逐點手動——「讀不到」永遠不等於「可以自動」。
-- activation 只在快照裡（getNavLeg 仍是原本六個回傳）。已經讀過的快照可以傳進來，
-- 省一次 copyTrip。
function TRIP.snapshot(api, playerNum, trip)
    if not TRIP.v7(api) then return nil end
    if trip == nil then trip = api.getNavItinerary(playerNum) end
    if type(trip) ~= "table" or trip.schemaVersion ~= 2
            or type(trip.autoContinue) ~= "boolean" then
        return nil
    end
    return trip
end

-- 每個 Core API 回來先驗意圖與人車；只收自己的舊 prep，不碰回呼新建的意圖。
function TRIP.keepPrep(playerNum, prep)
    if TRIP.preps[playerNum] ~= prep then return false end
    local playerObj = prep.playerObj
    if getSpecificPlayer(playerNum) ~= playerObj or not playerObj:isLocalPlayer()
            or playerObj:isDead() or playerObj:getVehicle() ~= prep.vehicle
            or not prep.vehicle:isDriver(playerObj) then
        TRIP.cancel(playerNum, prep)
        return false
    end
    return true
end

-- 這個站在快照裡真的已經 arrived 嗎？被動到站採用的唯一證據：仍 pending、被 skip、
-- 或整個被移除都是 false（任何 token 變動都不足以證明「上一站到了」）。
function TRIP.arrived(trip, stopId)
    local stops = trip and trip.stops
    if type(stops) ~= "table" or stopId == nil then return false end
    for i = 1, #stops do
        if stops[i].id == stopId then return stops[i].status == "arrived" end
    end
    return false
end

-- 交還接管：呼叫端必須**先**停掉自己的控制輸出，這裡只解除記憶體 claim。
-- release 不要求設備／gate 仍可用，也不代表到站（§6.4）。
-- 回 true＝成功解除或已核對 token 撤銷；介面暫時缺席不代表解除。
-- false＝MiniMap 暫時拒絕，已排進有界重試，呼叫端不得當成已經交還。
function TRIP.release(playerNum, token, reason)
    local api = TRIP.api()
    local ok, why = false, "api"
    if api then
        ok, why = api.releaseNavLeg(playerNum, MDAD.MOD_ID, token, reason)
        if (ok == true and (why == "released" or why == "duplicate"))
            or api.getNavLeg(playerNum) ~= token then return true end
    end
    if not TRIP.owed[playerNum] then
        local now = getTimestampMs()
        TRIP.owed[playerNum] = { token = token, reason = reason,
            nextMs = now + ROUTE_REFRESH_MS, deadlineMs = now + TRIP.RELEASE_MS }
        prepCount = prepCount + 1
    end
    if getDebug() then
        print(LOG .. "trip release deferred pn=" .. playerNum .. " why=" .. tostring(why))
    end
    return false
end

-- 交還寫入重試有界；超時後保留收據，直到明確確認上游撤銷。
function TRIP.stepOwed(playerNum, now)
    local owed = TRIP.owed[playerNum]
    if not owed or now < owed.nextMs then return end
    owed.nextMs = now + ROUTE_REFRESH_MS
    local api = TRIP.api()
    if not api then return end
    local done = api.getNavLeg(playerNum) ~= owed.token
    if not done and now < owed.deadlineMs then
        local ok, why = api.releaseNavLeg(playerNum, MDAD.MOD_ID, owed.token, owed.reason)
        done = (ok == true and (why == "released" or why == "duplicate"))
            or api.getNavLeg(playerNum) ~= owed.token
    end
    -- 寫入重試有界；尚未解除時保留收據與啟動阻擋，等待玩家停止導航或上游撤銷。
    if not done then return end
    TRIP.owed[playerNum] = nil
    prepCount = prepCount - 1
end

-- 到站回報（§6.3 唯一出口：已進 arrive 且 vehicle:isStopped()）。必須在清 session
-- **之前**呼叫，且此時控制輸出已停（regulator 關、不再送指令）。
-- 回 (結果, consumed, disposition, revision)：結果＝"arrived"／"road_end"／
-- "duplicate"／翻譯鍵；consumed=false＝claim 仍在我們手上，呼叫端要在有界時間內
-- 重試，不得把它丟掉。
-- disposition／revision 只有 v7 Core 的成功回報會給（continue／stopover／
-- completed／road_end 與 commit 後的 revision）；v6 Core 回 nil，呼叫端因此維持
-- 逐點手動——多出來的欄位是能力宣告，不是預設值。duplicate 不帶處置：重送不是
-- 一次新的到站，不得據以續發下一段。
function TRIP.report(playerNum, token)
    local api = TRIP.api()
    if not api then return KEY_API, false end
    local ok, result, detail, revision = api.reportNavArrival(playerNum, MDAD.MOD_ID, token)
    if ok == true then
        if result == "arrived" or result == "road_end" then
            return result, true, detail, revision
        end
        if result == "duplicate" then return result, true end
        -- 未知回傳不能證明已消耗 claim；以目前 token 驗證，不假報成功。
        return TRIP.LOST, api.getNavLeg(playerNum) ~= token
    end
    if result == "stale" and api.getNavLeg(playerNum) ~= token then return TRIP.STALE, true end
    return TRIP.key(result, detail), false
end

-- 移除準備意圖（安靜；紅字由呼叫端決定）。回 true＝真的有一份意圖被收掉。
function TRIP.drop(playerNum)
    if not TRIP.preps[playerNum] then return false end
    TRIP.preps[playerNum] = nil
    prepCount = prepCount - 1
    return true
end

-- 同 TRIP.drop，但只在它仍是**同一份**意圖時才收：每次跨 API 呼叫回來（claim／
-- 路線查詢／快照）都可能已經被同步回呼停掉或換成新的一份，這時候 drop 會誤殺別人。
-- 回 true＝這份意圖是我們收掉的；false＝已經不是它了，呼叫端不得再出紅字。
function TRIP.cancel(playerNum, prep)
    if TRIP.preps[playerNum] ~= prep then return false end
    TRIP.preps[playerNum] = nil
    prepCount = prepCount - 1
    return true
end

-- 路線是否穿過避讓圈（任一段到圓心距 ≤ r）；冷路徑 O(n)，只在 cutover 用。
local function routeCrossesAvoid(route, ax, ay, r)
    local pts = route and route.pts
    if type(pts) ~= "table" or not MDADDynamics.finite(ax) or not MDADDynamics.finite(ay) then return false end
    local n = #pts / 2
    for i = 1, n - 1 do
        if MDADDynamics.distanceToSegmentSq(ax, ay, pts[i * 2 - 1], pts[i * 2],
                pts[i * 2 + 1], pts[i * 2 + 2]) <= r * r then return true end
    end
    return false
end

-- 向主 MOD 要「繞開 (ax,ay) 半徑 r」的替代路線並驗收。回 (route, nil) 或 (nil, 原因)。
-- 驗收：仍穿避讓圈（avoidPenalty>0＝沒有替代路，主 MOD 是軟封鎖照樣給原線）、
-- 起點太遠、長度 > lenMax（預設剩餘×ratio+slack）一律拒——這三條就是舊自動改道「拿回爛路線」的
-- 全部型態。成功時主 MOD 已覆寫路線快取，下一次 requestRoute 回的就是替代線。
-- r／lenMax 省略＝堵車改道（DETOUR_AVOID_R、DETOUR_LEN_*）；拖車繞開調頭另給（Drive.towTurnaround）。
-- refRoute＝目前的路線：替代線的終點要跟它同一個（DETOUR_END_M）。
-- more＝同一趟先前改道判死的避讓圈（Drive.avoidMore，扁平 { x, y, r, … }；nil＝沒有）：一併交給主 MOD（nav API v9
-- requestDetour 第 7 參；v8 以下會忽略），回來的線穿任一圈＝拒收 "again"——只避新堵點時 A* 會原路繞回舊堵點
-- （E2E e1004e dixie9050w：第二次交還前改道 1552m 原路回到第一處路障，detour 用完交還）。
TUNE.DETOUR_END_M = 3 -- 冷路徑常數收 TUNE（chunk local 190 槽已滿）
TUNE.DETOUR_HIST_MAX = 7 -- 記幾個先前的避讓圈（＋目前那圈＝主 MOD 一次最多 8 圈）
local function requestDetourRoute(api, playerNum, tx, ty, ax, ay, remaining, r, lenMax, refRoute, more)
    if type(api.requestDetour) ~= "function" then return nil, "api" end
    local route, state = api.requestDetour(playerNum, tx, ty, ax, ay, r or TUNE.DETOUR_AVOID_R, more)
    if not route or state ~= "ok" then return nil, state or "noroad" end
    -- 空線（1002h E2E rc50 0017：目標 46m 外判堵、主 MOD 回 ok 但 len 0）收下＝下一幀 cutover 建不出剖面、
    -- 直接 LostRoute 交還；當成沒有改道，照常走受困流程。
    if not MDADDynamics.finite(route.len) or route.len <= 0.5 or type(route.pts) ~= "table" or #route.pts < 4 then
        return nil, "empty", route
    end
    -- 終點不是原本的終點（1002k E2E rc53 0008：目標 46m 外判堵、交還前改道，主 MOD 回 ok 的 4.3m 短線，終點就在車旁；
    -- 收下後下一幀剩 4.3m＝判到站、清目標交還，車停在離目標 46m 處）。
    local ref = refRoute and refRoute.pts
    if type(ref) == "table" and #ref >= 4 then
        local pts = route.pts
        local ex, ey = pts[#pts - 1] - ref[#ref - 1], pts[#pts] - ref[#ref]
        if ex * ex + ey * ey > TUNE.DETOUR_END_M * TUNE.DETOUR_END_M then return nil, "end", route end
    end
    if MDADDynamics.finite(route.avoidPenalty) and route.avoidPenalty > 0 then return nil, "through", route end
    if Drive.crossesAnyAvoid(route, more) then return nil, "again", route end
    if routeTooFar(route) then return nil, "far", route end
    if lenMax == nil and MDADDynamics.finite(remaining) then
        lenMax = remaining * TUNE.DETOUR_LEN_RATIO + TUNE.DETOUR_LEN_SLACK
    end
    if MDADDynamics.finite(route.len) and MDADDynamics.finite(lenMax) and route.len > lenMax then
        return nil, "long", route
    end
    return route, nil
end

-- 同一趟（同目標）先前改道判死的避讓圈：s.avoidHist＝扁平 { x, y, r, … }，不含目前的 s.avoidX（拖車調頭圈不記）。
-- Drive.avoidMore 組本次要附給主 MOD 的圈：歷史＋（withCurrent）目前那圈；跳過三種——圈住車位或目標的（車已在圈內、
-- 目標在圈內＝任何路線都穿，避不了也驗不過）、圓心在本次主圈 (ax, ay) 圈內的（同一處堵點，主圈已經在避）。
-- 沒有回 nil。冷路徑（改道當下、cutover 換線時），配置一張小表。
function Drive.avoidMore(s, vx, vy, tx, ty, ax, ay, withCurrent)
    local fin = MDADDynamics.finite
    local h, out = s.avoidHist, nil
    local n = h and #h or 0
    for i = 1, n + 1, 3 do -- 最後一輪（i＝n＋1）是目前那圈
        local x, y, r
        if i <= n then
            x, y, r = h[i], h[i + 1], h[i + 2]
        elseif withCurrent and not s.avoidTow and fin(s.avoidX) and fin(s.avoidY) then
            x, y, r = s.avoidX, s.avoidY, s.avoidR or TUNE.DETOUR_AVOID_R
        end
        if x ~= nil and fin(vx) and fin(vy) and fin(tx) and fin(ty) and fin(ax) and fin(ay)
                and (vx - x) * (vx - x) + (vy - y) * (vy - y) > r * r
                and (tx - x) * (tx - x) + (ty - y) * (ty - y) > r * r
                and (ax - x) * (ax - x) + (ay - y) * (ay - y) > r * r then
            if out == nil then out = {} end
            out[#out + 1] = x
            out[#out + 1] = y
            out[#out + 1] = r
        end
    end
    return out
end

-- 接受新的改道前呼叫：把目前的避讓圈（若有、不是拖車調頭圈）推進歷史，超過 TUNE.DETOUR_HIST_MAX 圈丟最舊的。
function Drive.pushAvoidHist(s)
    if s.avoidTow or not MDADDynamics.finite(s.avoidX) or not MDADDynamics.finite(s.avoidY) then return end
    local h = s.avoidHist
    if h == nil then h = {}; s.avoidHist = h end
    h[#h + 1] = s.avoidX
    h[#h + 1] = s.avoidY
    h[#h + 1] = s.avoidR or TUNE.DETOUR_AVOID_R
    while #h > TUNE.DETOUR_HIST_MAX * 3 do table.remove(h, 1) end
end

-- 路線穿過 more（Drive.avoidMore 的扁平圈表）任一圈？
function Drive.crossesAnyAvoid(route, more)
    if more == nil then return false end
    for i = 1, #more - 2, 3 do
        if routeCrossesAvoid(route, more[i], more[i + 1], more[i + 2]) then return true end
    end
    return false
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
-- v6：draft／paused／waiting 的目前站還沒啟用，getNavTarget 本來就回 notarget
-- （§6.6），不能因此誤報「沒有路線」——那三個狀態只要資格夠就是「可以開始行程」。
-- 純查詢：不 start、不 claim、不啟用任何目標。
function Drive.hudStartReason(playerNum)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return KEY_NOT_DRIVER end
    local reason = driveGate(playerObj, playerObj:getVehicle(), playerNum, "draw")
    if reason then return reason end
    local api = navApi()
    if not api then return KEY_API end
    local trip = TRIP.api()
    if trip then
        local _, _, _, _, phase = trip.getNavLeg(playerNum)
        if phase == "draft" or phase == "paused" or phase == "waiting" then return nil end
        if phase == "approach" then return TRIP.ROAD_END end
        if phase == "completed" then return TRIP.STATE end
        -- navigating（與沒有行程的舊路徑）：照舊要求路線真的可用
    end
    local route = fetchRoute(api, playerNum)
    if not route then return KEY_ROUTE end
    return nil
end

-- 被迫停止的原因（1005h；使用者 10-05：被迫停下來時要有地方持續顯示原因，玩家暫離回來才知道為什麼停）：Drive.stop
-- 帶 reasonKey（系統交還）就記下原因鍵、那台車的 id 與時間，下一趟 session 真正接上（commitSession）才清。玩家自己
-- 停、手動接手、下車、抵達都不帶 reasonKey＝不記，也不清舊的。只在本機記憶體、依 playerNum 分槽，不寫磁碟。
Drive.lastStops = {}
function Drive.noteStop(playerNum, key, vehicle)
    Drive.lastStops[playerNum] = { key = key, vid = vehicle and vehicle:getId() or nil, ms = getTimestampMs() }
end

-- HUD 停用態讀（MDAD_HUD refresh）：回 (原因鍵, 停止至今毫秒)。沒有紀錄、或 vehicle 不是停下的那台＝nil（換開別台
-- 車不顯示，回到原車又出現）。
function Drive.hudStopReason(playerNum, vehicle)
    local rec = Drive.lastStops[playerNum]
    if not rec or not vehicle or rec.vid == nil or vehicle:getId() ~= rec.vid then return nil end
    return rec.key, getTimestampMs() - rec.ms
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
local lastDriveSeconds = {}
local sessionCount = 0

-- 開始／準備意圖也算「自駕已啟動」：HUD 的停止鈕
-- 與 radial 必須收得掉它，否則玩家只能對著沒反應的鈕等逾時。
function Drive.isActive(playerNum)
    return sessions[playerNum] ~= nil or TRIP.preps[playerNum] ~= nil
end

-- 語音通知只在受困交還／抵達收尾時可要求暫停；只在等語音時掛事件。
-- FMODSoundEmitter.isPlaying(ref) 含尚未開始播放的 toStart（:600-614），不能用固定延遲截句。
-- event 為 nil＝不播語音（Voice.play 不認得的事件回 false）、只照暫停選項處理（道路終點沒有語音，見到站收尾的 road_end）。
local cancelPendingPause
local function voice(event, playerNum, pauseOption)
    if cancelPendingPause then cancelPendingPause() end
    local v = MDAD.Voice
    local ok, played, ref
    if v then ok, played, ref = pcall(v.play, event, playerNum, pauseOption ~= nil) end
    if not pauseOption then return end
    local playerObj = getSpecificPlayer(playerNum)
    local vehicle = playerObj and playerObj:getVehicle()
    local function allowed()
        if isClient() or isServer() or getNumActivePlayers() ~= 1 or isGamePaused()
                or sessions[playerNum] or not playerObj or not vehicle
                or getSpecificPlayer(playerNum) ~= playerObj or playerObj:isDead()
                or playerObj:getVehicle() ~= vehicle or manualInput(vehicle) then return false end
        local on, hud = true, MDAD.HUD
        if type(hud) == "table" and type(hud[pauseOption]) == "function" then
            local readOk, value = pcall(hud[pauseOption])
            if readOk then on = value == true end
        end
        return on
    end
    if not allowed() then return end
    -- 語音關閉／缺席／失敗，或無法追蹤播放狀態時直接暫停，不留下無限等待。
    if not (ok and played == true and ref and type(v.isPlaying) == "function") then
        setGameSpeed(0)
        return
    end
    local deadline, nextCheck = getTimestampMs() + TUNE.PAUSE_VOICE_TIMEOUT_MS, 0
    local poll
    local function cancel()
        Events.OnTickEvenPaused.Remove(poll)
        cancelPendingPause = nil
    end
    poll = function()
        -- 自行暫停／接手／改選項不應在稍後又被舊通知暫停。
        if not allowed() then cancel(); return end
        local now = getTimestampMs()
        if now < nextCheck then return end
        nextCheck = now + 100
        local statusOk, playing = pcall(v.isPlaying, playerNum, ref)
        if statusOk and playing == nil then cancel(); return end -- 新句取代了原通知
        if statusOk and playing == true and now < deadline then return end
        cancel()
        setGameSpeed(0)
    end
    cancelPendingPause = cancel
    Events.OnTickEvenPaused.Add(poll)
end

function Drive.isPausePending()
    return cancelPendingPause ~= nil
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
    if s.dodging then return "AVOID" end
    return "TRACK"
end

function Drive.controlState(playerNum)
    return controlStateOf(sessions[playerNum])
end

-- 車道 proof（掃描輪產物）作廢：下一輪完成快照重建前 lane envelope 不參與裁決。
function Drive.clearLaneProof(s)
    s.verifyLineN = 0
    s.laneCurveEnvelope, s.laneCurveStamp,
        s.laneCurveS0, s.laneCurveEnd,
        s.envelopeBuildLat, s.envelopeBuildCoast,
        s.laneEnvelopeScale = 0, -1, 0, 0, -1, -1, 1
end

function Drive.invalidateCommandState(s, actualSpeedKmh, controlState)
    if type(s) ~= "table" then return end
    local v = actualSpeedKmh
    if not MDADDynamics.finite(v) then v = 0 elseif v < 0 then v = -v end
    s.cmdV, s.cmdA, s.cmdInitialized = v / 3.6, 0, true
    s.brakeSampleMs, s.coastSampleMs = 0, 0 -- 未完成的煞車／滑行觀測不跨讓位、恢復或重建。
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

-- 繞行承諾釋放：這五個旗標永遠一起回到「無承諾」狀態，dodgeNeed 回基準淨距。
-- 不含 clearOffset：剖面何時清由呼叫端時序決定（車還在動時清＝目標線瞬跳）。
-- 放棄既有承諾／持有權的完整重設；候選失敗的 blocked 出口須保留 handoffHold，不經此處。
local function releaseDodge(s)
    -- 守護看過布局不代表常駐線已規劃；持有權釋放後，靜態的下一台車也要重問。
    if s.dodging then
        s.planSig = -1
        Drive.armReleaseGuard(s)
    end
    s.dodging = false
    s.dodgeWide = false
    s.trafficLate = false -- 會車「來不及放棄」只屬於這次承諾
    s.dodgeHandoffHold = false
    s.dodgeNotified = false
    s.dodgeCrawl = false
    s.dodgeStay = false
    s.stayLanePending = nil
    s.stayNextB = nil
    s.dodgeGuardHardN = nil -- 承諾鎖定的點雲基準（守護 lazy init）
    s.dodgeMarginS = nil    -- commit／守護輪最緊點的弧長（過了就重掃一次放寬餘裕）
    s.dodgeDemoteS, s.dodgeDemoteM = nil, nil -- guardDemote 記下的回線段最緊點（[a,c] 掃掠看不到它）
    s.dodgeGuardFailed = false -- 物理重驗已判死（持平輪不得以「信任承諾」推翻）
    s.guardHitS, s.guardHitPhase = nil, nil -- 守護命中點及剖面階段；X/Y 隨 S 一起失效
    s.dodgeTier = nil -- 承諾來自哪一檔（telemetry dodge commit 事件）
    s.dodgeTight = false
    s.dodgeNeed = s.sweepBase
    s.dodgeKappa = 0
    s.dodgeClearance = 0
    s.dodgeCurveCap = 0
    s.dodgeClearanceCap = 0
    s.dodgeVisibilityCap = 0
    s.dodgeSpaceCap = 0
    s.dodgeSpeedCap = 0
    s.dodgeHoldCap = 0
    s.dodgeClrN, s.dodgeEnvN = 0, 0
    s.dodgeNextStopS = nil
    s.dodgeNextX, s.dodgeNextY, s.dodgeNextR = nil, nil, nil
    s.dodgeNextCap = -1
    s.dodgeApproachCap, s.dodgeAlignHold, s.dodgeAlignHoldKmh = 0, false, nil
    s.dodgeBaseCap = 0
    s.dodgeCapPending = false
    s.dodgeShiftLength = 0
    s.dodgeDesignSpeed = 0
    s.lastOvEndS, s.tmpOvEndS = 0, 0
    s.dodgeCommittedLength = 0
    s.dodgeSpaceBaseCap, s.dodgeSpaceLat, s.dodgeShapeDl = nil, nil, nil
    s.dodgeEntryLength, s.dodgeExitLength = nil, nil
    s.dodgeExitDl = nil
    s.dodgeEntryPassed = false
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

function Drive.getStyle(playerNum)
    return Drive.getGear(playerNum) == 4 and "brisk" or "comfort"
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

local zombieLaneOf

-- 政策快取進 session（250ms 路線刷新節流窗＋set* 即時重算）：殭屍／屍體分支
-- 每幀只讀 boolean，不跨界查 modData／沙盒表。
local function refreshPolicies(s, vehicle, playerNum)
    s.gearCap = gearCapKmh(playerNum, vehicle)
    s.pendingStyle = Drive.getStyle(playerNum)
    local zombieSlow = slowActive("ZombieAreaSlowdown", playerNum, PREF_ZOMBIE_MD)
    local corpseSlow = slowActive("CorpseSlowdown", playerNum, PREF_CORPSE_MD)
    -- 沙盒 AnimalSlowdown（1005 soft）：1 不為動物停等／2 大型動物（預設）／3 所有動物
    local animalSlow = MDAD.policy3("AnimalSlowdown", 2)
    local changed = zombieSlow ~= s.zombieSlow or corpseSlow ~= s.corpseSlow or animalSlow ~= s.animalSlow
    s.zombieSlow, s.corpseSlow, s.animalSlow = zombieSlow, corpseSlow, animalSlow
    if changed then
        s.zombieLaneCap = -1
        if s.sensor and s.sensor.ready and s.profile.ready and MDADDynamics.finite(s.lastLatSigned)
                and not s.dodging and not s.returnActive and not s.laneChained
                and not s.fstate.rotating then
            local now = getTimestampMs()
            local resident = s.residentBias or (s.sandBias + s.roadBias)
            -- 權限變了，側移預算也要以同一完整快照重算；不能只撤掉最近一類的帽。
            local nb = zombieLaneOf(s, resident, now, playerNum, vehicle:getCurrentSpeedKmHour())
            if nb ~= s.fstate.laneBias then
                s.fstate.laneKeep = Drive.laneKeepOf(s)
                MDADFollower.setLaneBias(s.fstate, nb)
                s.verifyLineN, s.laneCurveStamp = 0, -1
                s.softLaneRecheck, s.planSig = true, -1
            end
        end
    end
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

function Drive.perceptionDistance()
    local hud = MDAD.HUD
    if type(hud) == "table" and type(hud.perceptionDistance) == "function" then
        local ok, value = pcall(hud.perceptionDistance)
        if ok then
            for i = 1, #MDADDynamics.PERCEPTION_DISTANCES do
                if value == MDADDynamics.PERCEPTION_DISTANCES[i] then return value end
            end
        end
    end
    return MDADDynamics.PERCEPTION_DEFAULT_M
end

-- HUD顯示實際完成的感知範圍；尚未有快照時顯示選定基礎值，並非載入保證。
function Drive.slowdownInfo(playerNum)
    local sensor = type(MDADSensor) == "table" and MDADSensor or nil
    local nearM = sensor and sensor.SCAN_NEAR or 2
    local bandM = sensor and sensor.SLOW_BAND_HALF or 3
    local ahead = Drive.perceptionDistance()
    local s = sessions[playerNum]
    local sensorAhead = s and s.sensor and s.sensor.effectiveAheadM
    if type(sensorAhead) == "number" and sensorAhead > 0 then ahead = sensorAhead end
    return nearM, ahead, bandM,
        TUNE.ZOMBIE_CAP_1, TUNE.ZOMBIE_CAP_4, TUNE.ZOMBIE_CAP_8, TUNE.CORPSE_CAP
end

-- 伺服器速限（ServerOptions SpeedLimit）：MP 且 <120 時回 km/h，否則 nil（無放大效果）。
-- 引擎以 v×lerp(1, fake, (v/L)²) 對照車輛極速（CarController.java:138-145、655-665），
-- 故有速限時真實可達速度低於車輛極速；HUD 速度明細據此換算。
function Drive.serverSpeedLimit()
    local fn = BaseVehicle and BaseVehicle.getFakeSpeedModifier
    if type(fn) ~= "function" then return nil end
    local ok, fake = pcall(fn)
    if not ok or not MDADDynamics.finite(fake) or fake <= 1 then return nil end
    return 120 / fake
end

-- HUD 降速說明（巡航上限／降速狀態的滑鼠提示）：只回純量，250ms refresh 讀。
-- 回 vehicleMax, sandboxMax, gearCap, target, capReason, curveCap, visibilityCap, factorCap, factorReason；
-- gearCap 只在一般檔位（30/50/70）有值，MAX 檔沒有檔位上限（由車輛極速決定）回 nil。
-- factorCap/Reason＝本幀障礙／殭屍／屍體／來車／拖車等因素疊出的最低限速（沒有則 nil）。
-- 未在自駕時只回前三項（上限組成），其餘 nil。
function Drive.speedInfo(playerNum, vehicle)
    local s = sessions[playerNum]
    if not s then
        local vm = vehicle and vehicle.getMaxSpeed and vehicle:getMaxSpeed() or nil
        local gear = GEAR_CAPS[Drive.getGear(playerNum)]
        return vm, maxSpeedKmh(), gear and gear > 0 and gear or nil
    end
    local vmax = s.vehicle and s.vehicle.getMaxSpeed and s.vehicle:getMaxSpeed() or nil
    local g = GEAR_CAPS[Drive.getGear(playerNum)]
    local gear = g and g > 0 and s.gearCap and s.gearCap > 0 and s.gearCap or nil
    return vmax, s.maxSpeed, gear, s.desiredTarget, s.lastCapReason, s.curveCap, s.visibilityCap,
        s.lastSensorCap, s.lastSensorReason
end

-- HUD 唯讀狀態（M5.5b 面板的資料面）。回**多值純量**、不洩漏 session table
-- （session 是可變內部狀態，交出參考＝UI 能繞過所有入口改駕駛行為）：
--   statusKey, gearId, effectiveCapKmh, zombieSlowOn, corpseSlowOn, resumeIn, elapsedSeconds, arrivalReason
-- statusKey ∈ arrive/yield/unstick/blocked/dodging/build/lowfps/follow；nil＝無 session 且無準備意圖。
-- arrivalReason 是到站回報拒絕原因的翻譯鍵，沒有拒絕原因則為 nil。
-- 顯示優先序：arrive > yield > recovery（unstick/recover/settle）>
-- current/planned blocked > dodging > build > follow。
-- effectiveCap＝min(session 啟動時沙盒上限, 當前檔位)。AutoDriveMaxSpeed 要重開
-- session 才重建 profile；HUD 不得先讀新沙盒值而顯示車子尚未套用的上限。
function Drive.hudState(playerNum)
    local s = sessions[playerNum]
    if not s then
        local prep = TRIP.preps[playerNum]
        -- 準備 v6 路線／剖面：HUD 顯示 build（與剖面分幀建構同一個狀態），可取消；
        -- 這段期間對車輛零控制輸出。
        if prep then
            return "build", Drive.getGear(playerNum),
                Drive.effectiveCap(playerNum, prep.vehicle),
                Drive.getSlowPref(playerNum, "zombie"),
                Drive.getSlowPref(playerNum, "corpse"), nil,
                math.max(0, math.floor((getTimestampMs() - prep.startedMs) / 1000))
        end
        return nil, nil, nil, nil, nil, nil, lastDriveSeconds[playerNum]
    end
    local key
    if s.mode == "arrive" then key = "arrive"
    elseif s.mode == "yield" then key = "yield"
    elseif s.mode == "unstick" or s.mode == "settle"
            or s.recoverWhy ~= nil then
        key = "unstick"
    elseif s.currentBlocked or s.blocked then key = "blocked"
    elseif s.areaWaitActive then key = "areawait" -- 前方區域未載入、引擎煞住等待（Drive.areaWait）
    elseif s.dodging then key = "dodging"
    elseif s.mode == "build" then key = "build"
    elseif s.lowFps then key = "lowfps" -- 幀率壓低可視距離而降速（Drive.updateLowFps）
    else key = "follow" end
    local cap = s.maxSpeed
    if s.gearCap and s.gearCap > 0 and s.gearCap < cap then cap = s.gearCap end
    -- 第 6 值：讓位中已放手時「幾秒後恢復」（向上取整、最少 1），按著或非讓位＝nil。
    -- HUD 狀態列以此顯示倒數（2026-09-06 回饋「不知道放開會變回自動駕駛」）。
    local resumeIn = nil
    if key == "yield" and s.cleanSinceMs > 0 then
        local left = s.cleanSinceMs + s.yieldResumeMs - getTimestampMs() + 999
        resumeIn = (left - left % 1000) / 1000
        if resumeIn < 1 then resumeIn = 1 end
    end
    return key, Drive.getGear(playerNum), cap, s.zombieSlow, s.corpseSlow, resumeIn,
        math.max(0, math.floor((getTimestampMs() - s.startedMs) / 1000)), s.legReportWhy
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

-- 同車型轉向增益快取的鍵（MDADFollower.seedGains／storeGains）：車輛 script 名；拖掛另分鍵（牽引車>掛車），掛車讀不到
-- 名字就用 "?"（同牽引車拖不同掛車共用一格，比混進單車那格好）。量不到 script 名回 nil＝這台車不記。
function Drive.gainKey(vehicleProfile, tow)
    local name = type(vehicleProfile) == "table" and vehicleProfile.scriptName or nil
    if type(name) ~= "string" or name == "" then return nil end
    if type(tow) ~= "table" then return name end
    local ok, tn = pcall(function() return tow.trailer:getScriptName() end)
    return name .. ">" .. (ok and type(tn) == "string" and tn or "?")
end

local function clearSession(playerNum)
    local s = sessions[playerNum]
    if not s then return end
    lastDriveSeconds[playerNum] = math.max(0, math.floor((getTimestampMs() - s.startedMs) / 1000))
    reportAutoUsage(getSpecificPlayer(playerNum), s.vehicle, false, s.usageArgs, s.navUsageArgs)
    sessions[playerNum] = nil
    MDADFollower.storeGains(s.fstate, s.gainKey) -- 同車型轉向增益記給下一趟（記憶體、不存檔）
    sessionCount = sessionCount - 1
    -- 一般軌跡快取與 debug markers 都綁 session；停止／失效當下立即清。
    if type(MDADOverlay) == "table" then MDADOverlay.clear(playerNum) end
end

-- opt-in telemetry：本機紀錄或伺服器上傳都沒開時零 I/O。熱路徑只在 opt-in session 進
-- protected boundary；shouldSample／collection／sample 任一錯誤只終止診斷，
-- 絕不打斷駕駛。start／event／stop 同樣隔離。
-- 伺服器上傳（MDAD_Upload）開著時也算「有在紀錄」：卡住交還不再提示玩家去開本機紀錄。
local function diagEnabled()
    local up = MDADUpload
    if type(up) == "table" and type(up.enabled) == "function" then
        local okU, on = pcall(up.enabled)
        if okU and on == true then return true end
    end
    local hud = MDAD.HUD
    if type(hud) ~= "table" or type(hud.telemetryEnabled) ~= "function" then
        return false
    end
    local ok, en = pcall(hud.telemetryEnabled)
    return ok and en == true
end

-- 手動介入後恢復自駕的等待（ms）；0＝介入即關閉 session。值來自 ESC／MiniMap
-- 「手動介入後」下拉（HUD.manualResumeMs），HUD 缺席／getter 拋錯一律 0——預設就是
-- 「不自動恢復」，缺席時退到預設而不是退到舊制 2 秒。
local function manualResumeMs()
    local hud = MDAD.HUD
    if type(hud) ~= "table" or type(hud.manualResumeMs) ~= "function" then return 0 end
    local ok, ms = pcall(hud.manualResumeMs)
    if ok and type(ms) == "number" and ms > 0 then return ms end
    return 0
end

-- 調頭方式（TUNE.UTURN 的一檔）；來自 ESC／MiniMap「調頭方式」下拉（HUD.uturnMode 回
-- "gentle"／"fast"），HUD 缺席／非法值一律溫和（預設）。每次調頭開始讀一次。
local function uturnProfile()
    local hud = MDAD.HUD
    if type(hud) == "table" and type(hud.uturnMode) == "function" then
        local ok, mode = pcall(hud.uturnMode)
        if ok and TUNE.UTURN[mode] then return TUNE.UTURN[mode] end
    end
    return TUNE.UTURN.gentle
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
-- diagWhy 只影響診斷紀錄的結束原因（button／exit／dead；手動接手由 voiceEvent
-- "manual" 推導為 takeover），不改玩家看到的訊息或行程回報。
function Drive.stop(playerNum, reasonKey, voiceEvent, diagWhy)
    local s = sessions[playerNum]
    if not s then
        -- 準備中（尚未 claim、尚未碰車）：收掉意圖就結束，沒有 claim 要還。
        if not TRIP.drop(playerNum) then return false end
        if reasonKey then
            local playerObj = getSpecificPlayer(playerNum)
            if playerObj then haloBad(playerObj, reasonKey) end
            Drive.noteStop(playerNum, reasonKey, playerObj and playerObj:getVehicle())
        end
        if getDebug() then
            print(LOG .. "trip prep cancel pn=" .. playerNum
                .. " reason=" .. tostring(reasonKey))
        end
        return true
    end
    diagStop(s, playerNum, reasonKey or diagWhy
        or (voiceEvent == "manual" and "takeover") or "manual")
    clearSession(playerNum)
    if s.vehicle then s.vehicle:setRegulator(false) end
    -- 控制輸出已停（regulator 關、本幀起不再送指令）之後才交還接管。這**不是**到站
    -- 回報：一般 Drive.stop 只交還控制，站點仍是 pending（§6.1／§6.4）。
    if s.legToken then
        TRIP.release(playerNum, s.legToken, reasonKey == nil and "manual"
            or TRIP.RELEASE[reasonKey] or "unavailable")
        s.legToken = nil
    end
    -- 實機回報「按了關閉、感覺沒關」時這行就是分水嶺：印出來＝session 真的收掉、
    -- regulator 也關了，車還在動就是慣性（Stop 刻意不硬煞）；沒印出來才是真的沒關。
    if getDebug() then
        print(LOG .. "stop pn=" .. playerNum .. " reason=" .. (reasonKey or "manual")
            .. " regulator=off nobrake")
    end
    if reasonKey then
        Drive.noteStop(playerNum, reasonKey, s.vehicle)
        local playerObj = getSpecificPlayer(playerNum)
        if playerObj then
            haloBad(playerObj, reasonKey)
            if reasonKey == KEY_STUCK and not telemetryHinted[playerNum] and not diagEnabled() then
                telemetryHinted[playerNum] = true
                -- addText(player, text)＝白字（HaloTextHelper.java:147-149；原版 forageClient.lua:73）
                local hint = getText(KEY_TELEMETRY_HINT)
                HaloTextHelper.addText(playerObj, hint)
                if MDADDiagnostics and MDADDiagnostics.toast then MDADDiagnostics.toast(hint, "info") end
            end
        end
    end
    -- 停等預算耗盡的紅字交還說「無法通過，請手動駕駛」；玩家自己接手（voiceEvent＝
    -- "manual"）說「你來開吧，自駕關閉」；其餘（玩家關閉、引擎熄火…）一律
    -- 「已關閉，請接管方向盤」。
    voice(voiceEvent or (reasonKey == KEY_STUCK and "handback" or "stop"), playerNum,
        reasonKey == KEY_STUCK and "pauseOnStuck" or nil)
    return true
end

-- 把建好的 session 正式接上：**第一次碰玩家的車就在這裡**（先把 regulator 關掉一次；
-- 剖面要分幀建，這段期間 stepFollow 不會跑，玩家上車前自己設的定速就會原封不動繼續
-- 拉著車跑）。舊單站路徑由 startSession 直接呼叫；v6 行程路徑等剖面建完、claim 成功
-- 之後才呼叫，因此 claim 成功前對車零控制輸出。
local function commitSession(playerObj, playerNum, s)
    local vehicle = s.vehicle
    vehicle:setRegulator(false)
    sessions[playerNum] = s
    Drive.lastStops[playerNum] = nil -- 新的一趟真的接上：上次被迫停止的原因不再顯示（Drive.hudStopReason）
    -- 設定值在下一輪beginRound套用；不改route identity或正在執行的承諾。
    if s.sensor then s.sensor.aheadM = Drive.perceptionDistance() end
    sessionCount = sessionCount + 1
    refreshPolicies(s, vehicle, playerNum)
    reportAutoUsage(playerObj, vehicle, true, s.usageArgs, s.navUsageArgs)
    if not diagEnabled() then return end
    local dok, active = pcall(MDADDiagnostics.start, playerNum, vehicle, s.vehicleProfile)
    s.diag = dok and active == true
    if not dok then pcall(MDADDiagnostics.stop, playerNum, "error") end
    if not s.diag then return end
    local route, profile = s.route, s.profile
    diagEvent(s, playerNum, "start", s.gainSeeded and { seed = s.gainKey } or nil)
    diagEvent(s, playerNum, "target", {
        phase = "set", x = s.lastTx, y = s.lastTy, why = "user", tg = s.targetGen,
    })
    local pointN = type(route.pts) == "table" and #route.pts / 2 or 0
    local routeLen = type(route.len) == "number"
        and route.len * 0 == 0 and route.len or nil
    diagEvent(s, playerNum, "route", MDADDiagnostics.routeSource(route, {
        phase = "cutover", why = "initial", rg = s.routeGen,
        tg = s.targetGen, len = routeLen, pts = pointN,
        target = tostring(s.lastTx) .. "," .. tostring(s.lastTy),
        navVersion = s.navVersion,
        currentSurface = MDADFollower.surfaceName(profile.segSurface[1]),
        currentSegWidth = profile.segWidth[1] > 0 and profile.segWidth[1] or nil,
        cost = type(route.cost) == "number"
            and route.cost * 0 == 0 and route.cost or nil,
        avoidPenalty = type(route.avoidPenalty) == "number"
            and route.avoidPenalty * 0 == 0 and route.avoidPenalty or nil,
    }))
    -- 掛車幾何（0929p）：寬帶繞行掃掠、判堵停止線都吃這幾個量；復盤拖車繞不過／停得太遠時先看它
    local tw = s.tow
    if type(tw) == "table" then
        diagEvent(s, playerNum, "tow", {
            phase = "attach", L2 = tw.L2, trailLen = tw.trailLen, halfW = tw.halfW, mass = tw.mass,
            hitchZ = tw.hitchZ, boxBack = tw.boxBack, axisSign = tw.axisSign, d = Drive.blockStopDist(s),
        })
    end
end

-- 啟動的所有閘門，成功時就地把 session 寫進表裡。回 nil＝開起來了，否則回失敗的
-- 翻譯鍵；紅字與診斷統一由 Drive.start 收尾（七八條 early return 各印各的會讓
-- 診斷散得到處都是，而且每條都得記得包 getDebug()）。
-- stage（選填）＝v6 行程的準備意圖：帶著它就只「建好、寄放」，不碰車也不接上
-- （stage.session），由準備流程把剖面建到 ready、claim 成功之後才 commitSession。
-- 沒有 stage＝舊的單站自駕，建完就地接上，逐位元同以前。
local function startSession(playerObj, playerNum, stage)
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
    -- 拖掛車（MDAD_Trailer）：量不到掛車幾何、或掛在車頭前方就拒絕（attach 回翻譯鍵）；量得到＝質量併入、
    -- 彎道預算打折、轉角換成外拉大彎的車頭路線（Follower 只看到改寫後的線；cutover 仍以原 route identity 比對）。
    local tow = nil
    if type(MDADTrailer) == "table" then
        tow = MDADTrailer.attach(vehicle)
        if type(tow) == "string" then return tow end
    end
    if tow then
        vehicleProfile.towMass = tow.mass
        vehicleProfile.towLatScale = MDADTrailer.LAT_SCALE
    end
    -- 拖車時剖面建在改寫過的路線上（外拉轉角）；剖面的 segSource 索引指向這條，證明帶也要用它
    local profileRoute, approachM = Drive.profileRouteOf(route, tow, vehicleProfile,
        vehicle:getX(), vehicle:getY(), true)
    local profile = MDADFollower.begin(
        profileRoute,
        maxSpeed, api.navApiVersion, vehicleProfile,
        MDADFollower.STYLES[Drive.getStyle(playerNum)])
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
    -- follower 會從右車道平滑過渡到繞行線再回來。沙盒值是「右車道中心」的比例
    -- （1.0＝路寬／4，每輪依所在路段寬度換算，見 Drive.keepRightTarget）；0＝關（沿中心線）。
    -- 起步用路線第一段寬度換算（Drive.keepRightStartM），之後逐輪 EMA 跟隨所在路段。
    -- 符號：**l 正＝行進方向右側**——PZ 世界座標 Y 向南（地圖原點在西北角），
    -- 俯視下數學 CCW 法向 (-sin h, cos h) 實際指向右邊；2026-08-28 實機曾把它
    -- 標成「左」而給負號，整路靠左開（真踩過，語言標籤害死人）。
    local laneBias = MDAD.sandbox("RightLaneBias", 1.0)
    if type(laneBias) ~= "number" or laneBias ~= laneBias then laneBias = 1.0 end
    if laneBias < 0 then laneBias = 0 end
    if laneBias > 2 then laneBias = 2 end
    if tow then laneBias = 0 end -- 外拉路線已算好車頭位置，常駐靠右會把它再推一次
    MDADFollower.setLaneBias(fstate, laneBias * Drive.keepRightStartM(route))
    local startedAt = getTimestampMs()
    local sNew = {
        startedMs = startedAt, -- 含停等／讓位；換路線與重建不重設，清 session 時凍結末趟秒數
        -- 預計剩餘時間（Drive.etaTick）：累計實際行進秒／計畫行進秒，與計畫秒數表（重算時就地覆寫）
        etaElapsed = 0, etaPlanned = 0, etaPlan = { t = {}, s = {} },
        vehicle = vehicle,
        route = route,
        profileRoute = profileRoute, -- 剖面實際建構的路線（拖車＝改寫版）；證明帶的來源
        approachM = approachM, -- 剖面前接的越野接線長（Drive.approachRoute；0＝沒接）
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
        visibilityHardKmh = 0,
        visStamp = 0,                                        -- 上一個快照完成時戳（輪時 EWMA 用）
        visRoundS = MDADDynamics.PERCEPTION_ROUND_MS / 1000, -- 掃描輪時 EWMA（秒）
        visFrontSince = 0,                                   -- 可視前緣上次前進的時刻（visFrontRef＝當時前緣）
        visAssistPrev = 0,
        visAssistDecel = 0,                                  -- 本幀巡航減速輔助補的減速度（m/s²）
        towAssistDecel = 0,                                  -- 本幀施給掛車的減速度（Drive.towDecel）
        towBrakeWhy = nil,                                   -- 本幀拖車不鎖輪硬煞的理由（Drive.hardBrake；telemetry tbw）
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
        -- v6 活動段的 claim token（nil＝舊單站自駕）：由準備流程在 claim 成功、
        -- commitSession 之前寫入。每次控制輸出前以 getNavLeg 核對，到站回報與交還都認它。
        legToken = nil,
        -- 本段的站 id（v7 自動接續要驗「Core 現在等在的就是我剛回報的那一站」；
        -- nil＝v6 Core 或舊單站自駕，沒有自動接續）。
        legStopId = nil,
        legReportMs = 0,    -- 下一次到站回報的最早時間（被拒時的有界重試間隔）
        legReportUntil = 0, -- 到站回報的放棄時限（0＝尚未開始回報）
        legReportWhy = nil, -- 已經對玩家顯示過的回報拒絕原因（同一個原因不重複洗紅字）
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
        -- material 基準只留三個會進控制路徑的量（accel 不進剖面也不進控制，
        -- 2026-09-04 issue #1 定罪 C：拿它當重建條件＝白掛 N 十幾幀）
        dynamicsBrakeCap = aBrake, dynamicsLatCap = aLat, dynamicsCoastCap = aCoast,
        buildBudget = BUILD_BUDGET, -- stepBuild 每幀預算：啟動／換路線 128、行駛中重建 TUNE.REBUILD_BUDGET
        rebuildStartMs = 0,         -- 行駛中重建起點（0＝非重建 build；telemetry dyn ready 事件用）
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
        tractionOffroad = false, offroadFlipSince = 0, -- 去抖後進 traction key 的越野旗標
        surfaceMismatchRounds = 0,
        surfaceMismatch = false,
        tractionKey = -1,
        safeCoast = aCoast,
        priorAccel = aDrive, priorBrake = aBrake, priorLat = aLat, priorCoast = aCoast,
        safeAccel = aDrive, safeBrake = aBrake, safeLat = aLat,
        kinPrevMs = 0, kinPrevV = 0, kinPrevH = 0,
        accelMean = 0, accelDev = 0, accelTime = 0,
        accelConfidence = 0, accelLower = 0,
        coastMean = 0, coastDev = 0, coastTime = 0,
        coastConfidence = 0, coastLower = 0,
        brakeMean = 0, brakeDev = 0, brakeTime = 0,
        brakeConfidence = 0, brakeLower = 0,
        brakeSampleMs = 0, brakeSampleV = 0, coastSampleMs = 0, coastSampleV = 0,
        yawMean = 0, yawDev = 0, yawTime = 0,
        yawConfidence = 0, yawLower = 0,
        forceBrakeThis = false, lastAssistForce = 0,
        zombiePushSince = 0, zombiePushNotified = false, -- 殭屍推撞計時／事件去重
        zombieLane = nil,       -- 殭屍軟縫採納中的 lane（nil＝無；TUNE.ZOMBIE_LANE_*）
        zombieLaneMs = 0,       -- 上一次軟縫平滑的時戳
        zombieLaneCap = -1,     -- 縱向配合帽（km/h；−1＝無）：側移在到達殭屍前完不成就先降速
        trafficCapKmh = -1,     -- 會車／跟車帽（km/h；−1＝無）：Drive.visAssistForce 的 traffic 帳
        softStopCapKmh = -1,    -- 動物／玩家停等接近帽（km/h；−1＝無）：Drive.visAssistForce 的 soft-stop 帳
        followerTarget = 0, desiredTarget = 0, -- telemetry ftg／des（剖面原始目標／cap 後 jerk 前）
        forceBrakeWhy = nil, -- telemetry fbw：最後一次 commandForceBrake 的裁決者
        zombieLaneParked = nil, -- 讓位釋放時停放的 lane（重新接手的平滑起點；nil＝無）
        zomTmpLo = {}, zomTmpHi = {}, -- softZombieLane 的區間暫存（session 期配置一次）
        zomSlowS = {}, zomSlowL = {}, -- 混合政策時的授權子集合，重用既有選縫器／暫存。
        zomPredS = {}, zomPredL = {}, -- 殭屍現位＋預測位點雲（zombieLaneOf 每輪重填）
        forceBrakeUntil = 0,
        ewmaSuppressUntil = 0,
        lastLatDev = 0, lastHeadingError = 0,
        lastVehicleHeading = nil, -- 實際車頭；保持段升速對承諾線切線驗姿態
        forceBrakePrev = false, regulatorPrev = false,
        targetPrev = 0, steerPrev = 0,
        lastHardBrakeReason = nil,  -- 本幀 hard-brake 裁決者（telemetry hbr；nil＝無）
        frameMs = 0,                -- 引擎回報的本幀時長（telemetry fdt；正常遊戲速度＝真幀時）
        nextRouteMs = startedAt + ROUTE_REFRESH_MS,
        nextUsageMs = startedAt + TUNE.USAGE_FIRST_RETRY_MS,
        usageArgs = { vehicleId = vehicle:getId(), active = true },
        navUsageArgs = { active = true },
        nextDebugMs = 0,
        cleanSinceMs = 0,
        yieldResumeMs = 0,   -- 進入 yield 那幀讀的選項值（介入當下的策略，之後改選項不追溯）
        yieldSinceMs = 0,    -- 進入 yield 的時刻；恢復語音只在讓位 ≥ TUNE.YIELD_VOICE_MS 才播
        yieldVoiced = false, -- 讓位語音每 session 一次（教學句），頭上文字仍每次讓位提示
        parity = 1,
        yieldNotified = false,
        progressState = "disarmed",
        progressSince = 0,
        progressBrakedSince = 0, -- 停滯監督中連續受控煞停的起點（Drive.progressPauseMs）
        areaWaitActive = false, areaWaitSince = 0, -- 前方區域未載入等待（Drive.areaWait）
        escScale = 1, -- 車身 yaw 率限制（Drive.yawGovern；escH／escT／yawRate 首個視窗後才有）
        startGuard = true, startGuardOkMs = 0, -- 起步近物限速（Drive.startGuardApply）
        startGuardX = vehicle:getX(), startGuardY = vehicle:getY(),
        routeFarSince = 0, -- 離線過遠計時（Drive.routeFarWatch）
        rotateStallSince = 0, -- 調頭大弧卡住計時（Drive.rotateStall）
        startNearSince = 0, startNearCap = nil, -- 起步近物限速停住計時／本幀低於 MIN_EXEC 的帽（Drive.startNearStall）
        holdLaneL = nil, -- 斜切保持的 lane（Drive.transitionHold；nil＝沒保持）
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
        dodgeWide = false,  -- 本次承諾是寬帶（堵住時 ±14m）規劃出來的：走完前維持寬帶掃描
        wideArmed = false,  -- 這次判堵已開到停點：之後（含倒車補跑道）幾乎停住就要求寬帶（Drive.wideScanWanted）
        wideArmedS = nil,   -- 武裝點弧長：倒車退回它之後仍停著寬帶重判；開過它就解除（Drive.blockedAtStop）
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
        unstickTravelM = 0, -- 短帶倒車的本次退距上限（0＝標準帶）
        blockS = 0,
        lastTx = tx, lastTy = ty,
        targetGen = 1, routeGen = 1, pendingRouteWhy = nil,
        gearCap = 0,        -- 檔位巡航上限快取（refreshPolicies 維護；>0 才生效）
        zombieSlow = true,  -- 政策×偏好合成快取：這位玩家要不要為殭屍減速
        corpseSlow = true,  -- 同上，地面屍體
        animalSlow = 2,     -- 沙盒 AnimalSlowdown 快取（1 關／2 大型／3 全部）
        softStopS = nil, softStopL = nil, softStopKind = nil, -- 本輪選定行駛線上閃不開的最近停等目標（Drive.softStopScan）
        softHoldKind = nil, -- 停等中的目標種類（nil／"animal"／"player"；E2E 情境讀）
        softHoldMs = 0,     -- 本次停等累計 ms（停住才計）
        softHoldTick = 0, softHoldStarted = false,
        softCrawl = false,  -- 動物等待到期後的爬行中
        softCrawlMs = 0, softCrawlTick = 0, -- 動物爬行累計（牆鐘；ANIMAL_CRAWL_MAX_MS 交還）
        softAnimalAnchorS = nil, softAnimalCarryMs = 0, softCrawlCarry = false, -- 停→放→停 沒前進時接著算
        softAnimalHold = false, softGiveUp = false, -- 本幀只有動物停等（不計共用預算）／爬行到上限要交還
        softGentleS = nil, softGentleOn = false, softGentleCapKmh = -1, -- gentle 動物接近帽（Drive.softGentleCap）
        zombieKeep0 = false, -- 軟縫這次縫是貼路緣（keep 0）找到的（Drive.laneKeepOf）
        rotProbeMs = 0,     -- 下一次允許車周探測的時戳（0＝第一次調頭幀就探）
        rotProbeClear = false, -- 上次探測結果：車周淨空可原地旋轉
        uturn = nil,        -- 進行中的這一次調頭的參數檔（TUNE.UTURN.*）；nil＝沒在調頭
        uturnArmed = false, -- 入場減速已放行（速度降到 entry 以下過一次）
        returnActive = false,
        returnUnsafe = false,
        returnHold = false,
        returnCrawlExact = false,
        returnCapacityFault = false,
        returnStartS = 0, returnEndS = 0,
        returnLaneStart = 0, returnLaneTarget = 0,
        returnReason = nil, returnClearRounds = 0,
        returnHoldSince = 0,   -- hold 起算（sensor 快照時戳；0＝未在 hold）
        returnUnloadedSince = 0, -- 因 unloaded hold／爬行起算（0＝否）
        returnBlockUntil = 0,  -- stall 釋放後的 RETURN 重入冷卻截止
        returnX = {}, returnY = {},
        clearStreak = 0,    -- 連續 clear 輪數（堵住解除遲滯）
        followHold = false, -- 跟車分級把目標壓 0（停等豁免卡死偵測用）
        dodgeCommittedLength = 0,
        dodgeNextStopS = nil,
        dodgeNextX = nil, dodgeNextY = nil, dodgeNextR = nil,
        dodgeNextCap = -1,
        dodgeClr = {}, dodgeEnv = {}, dodgeClrN = 0, dodgeEnvN = 0, dodgeClrK0 = 1,
        dodgeSpaceBaseCap = nil, dodgeSpaceLat = nil, dodgeShapeDl = nil,
        dodgeEntryLength = nil, dodgeExitLength = nil, dodgeEntryPassed = false,
        dodgeExitDl = nil, -- 回線需求可能大於起步到繞行線的側移，commit 凍結
        dodgeCommitDl = 0,      -- commit 當下的側移量 |offL−baseL|（停留把 laneBias 換成 offL 後守護輪還要用）
        stayHoldEndS = nil,     -- 提早釋放的停留段終點 c（鏈上下一段進入起點下限）
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
        avoidHist = nil, detourAvoidN = nil, -- 同一趟先前的避讓圈（Drive.pushAvoidHist）／本次附給主 MOD 的圈數
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
        dodgeGuardFailed = false, -- 承諾線的物理重驗已判死（持平輪不得推翻；releaseDodge 清）
        dodgeHandoffHold = false, -- 舊線已交出、尚無可用新線；跨輪保持停止直到採納或真正淨空
        dodgeDemoteS = nil, dodgeDemoteM = nil, -- guardDemote 的回線段最緊點／淨距（後續守護輪保留到車過為止）
        guardHitS = nil, guardHitX = nil, guardHitY = nil, -- 守護判死命中點（guard-blocked 煞停錨）
        guardHitPhase = nil, -- 只有回線段 p4 的失敗可在舊群過清後行駛中交接
        dodgeApproachCap = 0, -- 接近段 envelope（telemetry：分辨「遠壓速」vs「縫本身的帽」）
        rejectedRoute = nil,  -- 本 MOD 拒收、但仍在主 MOD 快取裡的替代線 identity（cutover 跳過）
        laneChained = false,  -- 鏈式停留中：常駐 lane 暫時＝停留 offL（前方淨空解鏈）
        residentBias = fstate.laneBias, -- 常駐行駛線（sandBias＋roadBias 夾後；每輪路面對中更新）
        dodgeStay = false,    -- 本次承諾是停留承諾（線只到 c＋車身、無回線段）
        dodgeMargin = 1,    -- commit 時 a..c 最小餘裕（entry／hold 速度縮放輸入）
        dodgeKappa = 0,
        dodgeClearance = 0,
        dodgeCurveCap = 0,
        dodgeClearanceCap = 0,
        dodgeVisibilityCap = 0,
        dodgeSpaceCap = 0,
        dodgeSpeedCap = 0,
        dodgeHoldCap = 0,
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
        tmpOvX = {}, tmpOvY = {}, -- setOffset 直接採用工作表；舊承諾未釋放前不可寫入新候選
        tmpOv2X = {}, tmpOv2Y = {}, -- 出口加長的第二張工作表（掃過才與 tmpOv 交換）
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
        sandBias = fstate.laneBias, -- 每輪向 keepRightTarget 收斂
        laneRatio = laneBias, -- 沙盒靠右比例（1.0＝右車道中心）
        -- 會車／跟車（Drive.trafficScan 每輪寫、trafficCap 每幀讀；nil＝無）
        trfStamp = 0, trfLeadGap = nil, trfLeadV = nil,
        trfOnGap = nil, trfOnV = nil, trfOnWant = nil, trfOnSide = 1, trfOnYield = false, trfOnMargin = nil,
        trafficLane = nil, trafficLaneMs = 0, trafficHoldUntil = 0, trafficSide = 1,
        trafficPlan = nil, trafficPlanL = nil,
        roadBias = 0,
        vehicleProfile = vehicleProfile,
        tow = tow,          -- 拖掛車幾何（MDAD_Trailer.attach）；nil＝沒拖
        towNextMs = 0,      -- 行駛防線節流
        towCap = nil,       -- 防線給的速度上限（km/h）；nil＝不限
        bodyReach = vehicleProfile.halfL + vehicleProfile.halfW
            + math.abs(vehicleProfile.centerOfMassX) + math.abs(vehicleProfile.centerOfMassZ),
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
        lastRouteErr = 0,     -- 車頭對路線切線的絕對角（貼縫承諾姿態閘門用）
        dodgeDeferCap = -1,   -- 待承諾的本輪接近帽（<0＝無）；未證實繞行可用前仍須能在障礙前停下
        unstickExtraM = 0,    -- 本次倒車的額外距離（貼縫 contact 後加長，見 TUNE.UNSTICK_DODGE_EXTRA_M）
        steepDeficitM = -1,   -- 本輪 steep 拒收候選中「進入段還差多少才夠運動學長」的最小值（<0＝無）
        blockSteepM = -1,     -- 候選鏈全滅那輪的 steepDeficitM 快照（夾 UNSTICK_STEEP_MAX_M；<0＝無）
        stayLanePending = nil, -- 停留承諾的 lane，過 b 才寫進 laneBias（nil＝無待切）
        stayNextB = nil,      -- 停留承諾時已知「下一群塞不進」的群起點弧長（對它煞停；nil＝無）
        assistBoost = 1,      -- 越野推力遞增倍率（TUNE.ASSIST_BOOST_*）
        bushObj = {}, bushX = {}, bushY = {}, -- 車周樹叢候選（Drive.bushCancel；MDADSensor.bushNear 寫入）
        bushN = 0, bushScanMs = 0, bushContactN = 0, -- 候選數／下次重抓時刻／本幀抵消的叢數（telemetry bsh）
        bushOff = nil, bushOffLogged = false, -- 不抵消的原因 tow／api／call（寬帶照舊避開樹叢；Drive.bushCancel）
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
    if tow and sNew.sensor then sNew.sensor.selfTrailer = tow.trailer end -- 感測不把自己的掛車當障礙
    -- 抵消得了樹叢阻力（非拖車、引擎方法在）＝寬帶不把樹叢當障礙（Drive.bushCancel；MDADSensor COST_BUSH）
    sNew.bushOff = tow and "tow" or (not Drive.bushApi(vehicle) and "api") or nil
    if sNew.sensor then sNew.sensor.bushPassable = sNew.bushOff == nil end
    -- 同一場遊戲同車型學過的轉向增益當這趟的種子（MDADFollower.seedGains；session 結束在 clearSession 寫回）
    sNew.gainKey = Drive.gainKey(vehicleProfile, tow)
    sNew.gainSeeded = MDADFollower.seedGains(fstate, sNew.gainKey)
    if stage then
        -- 準備中：先寄放，claim 成功才接上（第一次碰車在 commitSession）
        stage.session = sNew
        return nil
    end
    commitSession(playerObj, playerNum, sNew)
    return nil
end

-- 啟動回饋（radial 與準備完成兩處共用；準備完成時玩家早就按過鈕，回饋要在真的
-- 開起來的那一刻才出現）。event＝這一段怎麼來的："leg_next"（接續下一站，自動
-- 或從停靠點明確續開）、"priority"（插入的優先目標）、其餘＝"start"。三者都只在
-- **真的 commitSession 之後**呼叫：車不在我們手上就沒有「出發」可以宣告。
function TRIP.announce(playerObj, playerNum, event)
    if event == "leg_next" then
        haloGood(playerObj, TRIP.CONTINUE)
    elseif event == "priority" then
        haloGood(playerObj, TRIP.PRIORITY)
    else
        event = "start"
        haloGood(playerObj, "UI_MinidoracatAutoDrive_Start")
    end
    voice(event, playerNum)
    if getDebug() then
        print(LOG .. "start pn=" .. playerNum .. " ok maxSpeed="
            .. sessions[playerNum].maxSpeed .. " rev=" .. tostring(Drive.REV))
    end
end

-- v7 車已到這一站時讓 Core 完成本站，再用 adopt 採用其接續結果；不自行宣告到站。
-- v6 沒有被動續行採用協定，保留原備路流程。「到了沒」直接問 Core（isNavLegReached：與它
-- 自己被動收站同一條規則，路面上的站點量路線終錨，1002y）；沒有這個函式的舊 Core 只量站點 5m。
function TRIP.atStop(api, vehicle, x, y, playerNum)
    if not TRIP.v7(api) or type(x) ~= "number" or type(y) ~= "number" then return false end
    if type(api.isNavLegReached) == "function" then return api.isNavLegReached(playerNum) == true end
    local dx, dy = vehicle:getX() - x, vehicle:getY() - y
    return dx * dx + dy * dy <= TRIP.ARRIVE_SQ
end

-- 準備期間的被動到站採用。Core 在**沒有 claim**時會自己收掉停在 5m 內的站並啟用
-- 下一段（activation=continue）——token 於是換了，但那不是「玩家改了行程」，而是
-- 本站真的到了。只有 prep 綁的那一站在快照裡確實 arrived 才處理，其餘任何 token
-- 變動都回 false 讓呼叫端照原路取消（不假播到站、不自己重新起步）。
-- 回 true＝這一幀已經處理完（轉到下一段，或收掉意圖並給了正確的停靠／完成提示）。
function TRIP.adopt(playerNum, prep, api, trip, now)
    local snap = TRIP.snapshot(api, playerNum, trip)
    if not snap or not TRIP.arrived(snap, prep.stopId) then return false end
    if TRIP.preps[playerNum] ~= prep then return true end
    local token, stopId, _, _, phase, revision = api.getNavLeg(playerNum)
    if TRIP.preps[playerNum] ~= prep then return true end
    local playerObj = getSpecificPlayer(playerNum)
    if playerObj ~= prep.playerObj or playerObj:isDead()
            or playerObj:getVehicle() ~= prep.vehicle then
        TRIP.cancel(playerNum, prep)
        return true
    end
    -- 快照資格不能與另一版的 token 拼在一起，終態提示也須仍屬同一版。
    if phase ~= snap.phase or revision ~= snap.revision then return false end
    if snap.phase == "navigating" and snap.activation == "continue"
            and snap.autoContinue == true then
        if type(token) ~= "string" or stopId ~= snap.currentStopId then return false end
        -- 沿用同一份意圖：丟掉舊剖面重建（route identity 也跟著重來），限期以新的
        -- 一段重新起算，對車的控制輸出仍然是零。
        prep.token, prep.stopId, prep.session = token, stopId, nil
        prep.nextMs, prep.deadlineMs = 0, now + TRIP.PREP_MS
        prep.event, prep.auto = "leg_next", true
        if getDebug() then
            print(LOG .. "trip prep adopt pn=" .. playerNum .. " stop=" .. tostring(stopId))
        end
        return true
    end
    -- 到了、但 Core 沒有（也不該）續發：停下來等玩家。停靠與完成都是事實，可以照
    -- 既有的抵達暫停設定；其他 phase／activation 不屬於這條路。
    if snap.phase ~= "waiting" and snap.phase ~= "completed" then return false end
    if not TRIP.cancel(playerNum, prep) then return true end
    if snap.phase == "completed" then
        haloGood(playerObj, "UI_MinidoracatAutoDrive_Arrived")
        haloGood(playerObj, TRIP.COMPLETED)
        voice("arrive", playerNum, "pauseOnArrival")
    else
        haloGood(playerObj, TRIP.STOPOVER)
        voice("stopover", playerNum, "pauseOnArrival")
    end
    return true
end

-- 準備意圖的一輪：acquire 段 → 查路線（250ms 節流）→ 分幀建剖面 → READY/claim。
-- 寄放的 session 未接上，只有 claim 成功並重驗後才 commitSession、開始碰車。
-- 每一幀都重驗玩家物件、車輛、設備 gate 與 token：撤銷、下車、換車、玩家自己操作
-- 或車子開始移動都立刻收手。路線沒好就繼續等，逾時才放棄——不是每次 idle 就假報
-- 遺失，也不要求玩家重複點擊。整段對車輛零控制輸出。
-- 回失敗的翻譯鍵；nil＝仍在準備或已經開起來了。
function TRIP.stepPrep(playerNum, now)
    local prep = TRIP.preps[playerNum]
    if not prep or not TRIP.keepPrep(playerNum, prep) then return nil end
    if now >= prep.deadlineMs then
        TRIP.cancel(playerNum, prep)
        return "UI_MinidoracatAutoDrive_TripTimeout"
    end
    local playerObj, vehicle = prep.playerObj, prep.vehicle
    if manualInput(vehicle) or not vehicle:isStopped() then
        TRIP.cancel(playerNum, prep)
        return nil
    end
    local reason = driveGate(playerObj, vehicle, playerNum, "draw")
    if not TRIP.keepPrep(playerNum, prep) then return nil end
    if reason then TRIP.cancel(playerNum, prep); return reason end
    local api = TRIP.api()
    if not api then TRIP.cancel(playerNum, prep); return KEY_API end
    local legToken, stopId, stopX, stopY, phase, revision = api.getNavLeg(playerNum)
    if not TRIP.keepPrep(playerNum, prep) then return nil end

    if not prep.token then
        -- 自動授權來自本段 report 的提交版本；版本沒變就仍是同一站、同一模式。
        if prep.auto and (phase ~= "waiting" or revision ~= prep.revision) then
            TRIP.cancel(playerNum, prep)
            return nil
        end
        if phase == "approach" then TRIP.cancel(playerNum, prep); return TRIP.ROAD_END end
        if phase == "navigating" then
            if not legToken then TRIP.cancel(playerNum, prep); return TRIP.STATE end
            local snapshot = TRIP.snapshot(api, playerNum)
            if not TRIP.keepPrep(playerNum, prep) then return nil end
            if snapshot then
                if snapshot.revision ~= revision then
                    TRIP.cancel(playerNum, prep)
                    return TRIP.STALE
                end
                if snapshot.activation == "priority" then prep.event = "priority"
                elseif snapshot.activation == "continue" then prep.event = "leg_next" end
            end
        elseif phase == "draft" or phase == "paused" or phase == "waiting" then
            if phase == "waiting" then prep.event = "leg_next" end
            local token, why, detail = api.startNavItinerary(playerNum, revision)
            if not TRIP.keepPrep(playerNum, prep) then return nil end
            if not token then TRIP.cancel(playerNum, prep); return TRIP.key(why, detail) end
            legToken, stopId, stopX, stopY, phase, revision = api.getNavLeg(playerNum)
            if not TRIP.keepPrep(playerNum, prep) then return nil end
            if legToken ~= token or phase ~= "navigating" then
                TRIP.cancel(playerNum, prep)
                return TRIP.STALE
            end
        else
            TRIP.cancel(playerNum, prep)
            return phase == nil and KEY_ROUTE or TRIP.STATE
        end
        prep.token, prep.stopId = legToken, stopId
        -- claim 前的模式授權只在版本變動時讀快照；首次 acquire 亦需驗 start wrapper。
        prep.revision = nil
    elseif legToken ~= prep.token then
        local trip = api.getNavItinerary(playerNum)
        if not TRIP.keepPrep(playerNum, prep) then return nil end
        if trip and TRIP.adopt(playerNum, prep, api, trip, now) then return nil end
        if not TRIP.cancel(playerNum, prep) then return nil end
        return trip and trip.phase == "paused" and TRIP.REASON[trip.reason] or TRIP.STALE
    end

    if revision ~= prep.revision then
        if prep.auto then
            local snapshot = TRIP.snapshot(api, playerNum)
            if not TRIP.keepPrep(playerNum, prep) then return nil end
            if not snapshot or not snapshot.autoContinue then
                TRIP.cancel(playerNum, prep)
                return nil
            end
            if snapshot.revision ~= revision then return nil end
        end
        prep.revision = revision
    end
    if prep.session then
        if not MDADFollower.stepBuild(prep.session.profile, BUILD_BUDGET) then return nil end
        local route, _, _, state = fetchRoute(api, playerNum)
        if not TRIP.keepPrep(playerNum, prep) then return nil end
        if state == "noroad" or state == "failed" then
            if TRIP.atStop(api, vehicle, stopX, stopY, playerNum) then return nil end
            TRIP.cancel(playerNum, prep)
            return TRIP.key(state)
        end
        if route ~= prep.session.route then
            prep.session, prep.nextMs = nil, now
            return nil
        end
        -- READY 查路亦可觸發回呼；新版本留到下一輪重新授權，不拿舊檢查 claim。
        local readyToken, _, _, _, readyPhase, readyRevision = api.getNavLeg(playerNum)
        if not TRIP.keepPrep(playerNum, prep) then return nil end
        if readyToken ~= prep.token or readyPhase ~= "navigating"
                or readyRevision ~= prep.revision then return nil end
        local claimed, why, detail = api.claimNavLeg(playerNum, MDAD.MOD_ID, prep.token)
        if not claimed then
            if not TRIP.keepPrep(playerNum, prep) then return nil end
            TRIP.cancel(playerNum, prep)
            return TRIP.key(why, detail)
        end
        if not TRIP.keepPrep(playerNum, prep) then
            TRIP.release(playerNum, claimed, "cancelled")
            return nil
        end
        -- claim 本身也換版本；auto 每段再讀一次模式，防 wrapper 在 claim 後關閉。
        local snapshot
        if prep.auto then snapshot = TRIP.snapshot(api, playerNum) end
        if not TRIP.keepPrep(playerNum, prep) then
            TRIP.release(playerNum, claimed, "cancelled")
            return nil
        end
        local currentToken, currentStop, _, _, currentPhase, currentRevision = api.getNavLeg(playerNum)
        if not TRIP.keepPrep(playerNum, prep) or currentToken ~= claimed
                or currentStop ~= prep.stopId or currentPhase ~= "navigating"
                or (prep.auto and (not snapshot or not snapshot.autoContinue
                    or snapshot.revision ~= currentRevision))
                or manualInput(vehicle) or not vehicle:isStopped() then
            TRIP.release(playerNum, claimed, "cancelled")
            TRIP.cancel(playerNum, prep)
            return nil
        end
        prep.session.legToken, prep.session.legStopId = claimed, prep.stopId
        TRIP.cancel(playerNum, prep)
        commitSession(playerObj, playerNum, prep.session)
        TRIP.announce(playerObj, playerNum, prep.event)
        return nil
    end
    if now < prep.nextMs then return nil end
    prep.nextMs = now + ROUTE_REFRESH_MS
    if TRIP.atStop(api, vehicle, stopX, stopY, playerNum) then return nil end
    local route, _, _, state = fetchRoute(api, playerNum)
    if not TRIP.keepPrep(playerNum, prep) then return nil end
    if state == "noroad" or state == "failed" then
        TRIP.cancel(playerNum, prep)
        return TRIP.key(state)
    end
    if not route then return nil end
    -- 取路之後 Core 才有這一站的終錨：再問一次，車已停在站旁就讓 Core 收站（零長度路線起不了段）
    if TRIP.atStop(api, vehicle, stopX, stopY, playerNum) then return nil end
    reason = startSession(playerObj, playerNum, prep)
    if not TRIP.keepPrep(playerNum, prep) then return nil end
    if reason then TRIP.cancel(playerNum, prep); return reason end
    return nil
end

-- 玩家明確開始／恢復的入口；先建立可取消的 prep，Core acquire 全在 stepPrep。
-- 自動接續僅由 report 的 arrived/continue 分支移交，不透過可外呼的 auto 參數。
function Drive.continueItinerary(playerNum)
    if sessions[playerNum] or TRIP.preps[playerNum] then return true end
    if TRIP.owed[playerNum] then return false, TRIP.LOST end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj or not playerObj:isLocalPlayer() then return false, KEY_NOT_DRIVER end
    if sessionCount >= TUNE.MAX_SESSIONS then return false, TRIP.STATE end
    if not TRIP.api() then return false, KEY_API end
    local vehicle = playerObj:getVehicle()
    local reason = driveGate(playerObj, vehicle, playerNum, nil)
    if reason then return false, reason end
    if not vehicle:isStopped() then return false, TRIP.NOT_STOPPED end
    local now = getTimestampMs()
    TRIP.preps[playerNum] = { playerObj = playerObj, vehicle = vehicle, event = "start",
        auto = false, startedMs = now, nextMs = 0, deadlineMs = now + TRIP.PREP_MS }
    prepCount = prepCount + 1
    if cancelPendingPause then cancelPendingPause() end
    reason = TRIP.stepPrep(playerNum, now)
    if reason then return false, reason end
    return true
end

function Drive.start(playerObj)
    if not playerObj or not playerObj:isLocalPlayer() then return false end
    local playerNum = playerObj:getPlayerNum()
    if sessions[playerNum] or TRIP.preps[playerNum] then return true end
    if sessionCount >= TUNE.MAX_SESSIONS then return false end
    -- 具備行程 API 就由同一個可取消 acquire 分類；radial 不在外層偷做首查。
    if TRIP.api() then
        local ok, why = Drive.continueItinerary(playerNum)
        if not ok then
            haloBad(playerObj, why)
            if getDebug() then
                print(LOG .. "start pn=" .. playerNum .. " trip blocked=" .. tostring(why))
            end
        end
        return ok
    end
    local reason = startSession(playerObj, playerNum)
    if reason then
        haloBad(playerObj, reason)
        if getDebug() then print(LOG .. "start pn=" .. playerNum .. " blocked=" .. reason) end
        return false
    end
    TRIP.announce(playerObj, playerNum)
    return true
end

function Drive.toggle(playerObj)
    if not playerObj then return end
    local playerNum = playerObj:getPlayerNum()
    if Drive.isActive(playerNum) then
        Drive.stop(playerNum, nil, nil, "button")
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
-- stuck＝交還前的最後一次改道（Drive.stuckDetour）：不要求 blocked、錨點要在車前附近、放寬繞遠上限。
-- src＝"auto"（停等自動改道）；HUD 按鈕不帶＝manual。每次請求（不論成敗）記一筆 detour 事件（1004b：舊制只有
-- 交還前那條有事件，自動／HUD 改道被拒的原因只在 Debug console；正式服 0.18.2 開著自動改道的 90 趟沒有任何 detour
-- 紀錄）。Upload 以 detour 事件觸發片段（phase＝skip 除外），事前窗看得到判堵、寬帶判定與倒車。
function Drive.requestDetour(playerNum, stuck, src)
    local s = sessions[playerNum]
    if not s then return false, "inactive" end
    s.detourAvoidN = nil -- 本次附給主 MOD 的舊避讓圈數（detourAttempt 寫；早退＝nil）
    local ok, why, len = Drive.detourAttempt(s, playerNum, stuck)
    local v = s.vehicle
    diagEvent(s, playerNum, "detour", { phase = stuck and "stuck" or (src or "manual"),
        why = ok and "ok" or tostring(why), x = v and v:getX() or nil, y = v and v:getY() or nil, s = s.lastSNow,
        hitX = s.blockHitX, hitY = s.blockHitY, ms = s.waitAccumMs, attempt = s.episodeAttempts,
        lvl = s.wideArmed and Drive.wideLevelOf(s) or nil, len = len, avoidN = s.detourAvoidN })
    return ok, why
end

function Drive.detourAttempt(s, playerNum, stuck)
    if not stuck and not s.blocked and not s.currentBlocked then return false, "not-blocked" end
    local api = navApi()
    if not api then return false, "api" end
    local playerObj = getSpecificPlayer(playerNum)
    local fin = MDADDynamics.finite -- 本檔的 local finite 定義在更後面（:1460+）
    if not playerObj or not fin(s.lastTx) or not fin(s.lastTy) then return false, "target" end
    local vx, vy = s.vehicle:getX(), s.vehicle:getY()
    local hx, hy = s.blockHitX, s.blockHitY
    if not fin(hx) or not fin(hy) then hx, hy = vx, vy end
    if stuck then
        -- 堵點錨可能是舊 episode 的（遠處／車後）：交還前改道只認車前附近的，否則沿路線切線往前推
        local h = s.profile and s.profile.segH[s.fstate.idx or 1] or nil
        local ex, ey = hx - vx, hy - vy
        if ex * ex + ey * ey > TUNE.STUCK_DETOUR_ANCHOR_M * TUNE.STUCK_DETOUR_ANCHOR_M
                or (fin(h) and ex * cos(h) + ey * sin(h) < 0) then
            hx, hy = vx, vy
        end
    end
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
    -- 同一趟先前判死的堵點一併避開（Drive.avoidMore；requestDetourRoute 拒收穿舊圈的線 "again"）
    local more = Drive.avoidMore(s, vx, vy, s.lastTx, s.lastTy, ax, ay, true)
    s.detourAvoidN = more and #more / 3 or nil
    local route, why, rejected = requestDetourRoute(api, playerNum, s.lastTx, s.lastTy, ax, ay, remaining, nil,
        stuck and fin(remaining) and remaining * TUNE.STUCK_DETOUR_LEN_RATIO + TUNE.STUCK_DETOUR_LEN_SLACK or nil, s.route,
        more)
    -- 拖車只收從車頭方向出發的線（0929p E2E semi-long-mp block：改道線先往車後 4m 再 90° 轉進支路，
    -- Follower 誤差 111° 未達調頭門檻、13 km/h 硬轉，掛車折 85° 脫開）；要調頭另走 Drive.towTurnaround。
    local vh = s.lastVehicleHeading
    if route and s.tow and fin(vh) and not Drive.routeLeavesForward(route, vx, vy, cos(vh), sin(vh)) then
        route, why, rejected = nil, "back", route
    end
    if getDebug() then
        print(LOG .. "detour pn=" .. playerNum .. " avoid=(" .. tostring(ax) .. "," .. tostring(ay)
            .. ") -> " .. (route and ("ok len=" .. tostring(route.len)) or ("rejected " .. tostring(why))))
    end
    if not route then
        -- 主 MOD 的 requestDetour 成功算出路線就已覆寫快取（含被本 MOD 拒收的
        -- far／long 線）；記住被拒的 identity，cutover 不得沿用（下一次 250ms 取
        -- 路仍會拿到同一個 table，直到主 MOD 冷卻後重算）。
        s.rejectedRoute = rejected
        haloBad(playerObj, KEY_NO_DETOUR)
        voice("nodetour", playerNum)
        return false, why
    end
    Drive.pushAvoidHist(s) -- 目前的避讓圈進歷史（之後的改道照樣避開它）
    s.avoidX, s.avoidY, s.avoidR, s.avoidTow, s.avoidLong = ax, ay, nil, nil, stuck == true
    s.pendingDetour = true
    s.pendingRouteWhy = "detour"
    s.nextRouteMs = 0
    haloGood(playerObj, KEY_DETOUR)
    voice("detour", playerNum)
    return true, nil, route.len
end

-- 新路線是不是從車頭方向出發：沿路線起點走 TOW_TURN_LOOK_M 的點落在車頭前半平面
-- （Follower 判原地調頭要 >135°，這裡取 90° 保守）；第一段夠長（≥1m）的線段本身也要朝前——
-- 先退幾公尺再斜向前的線 8m 點仍在車前，Follower 卻先投影在往後那段、判成調頭（0929v 審查）。
function Drive.routeLeavesForward(route, vx, vy, fx, fy)
    local pts = route and route.pts
    if type(pts) ~= "table" or #pts < 4 then return false end
    local left = TUNE.TOW_TURN_LOOK_M
    local px, py = pts[1], pts[2]
    local firstSeen = false
    for i = 3, #pts - 1, 2 do
        local dx, dy = pts[i] - px, pts[i + 1] - py
        local l = sqrt(dx * dx + dy * dy)
        if not firstSeen and l >= 1 then
            if dx * fx + dy * fy <= 0 then return false end
            firstSeen = true
        end
        if l >= left then
            px, py = px + dx * left / l, py + dy * left / l
            break
        end
        left = left - l
        px, py = pts[i], pts[i + 1]
    end
    return (px - vx) * fx + (py - vy) * fy > 0
end

-- 拖車要調頭（Follower 判 ROTATE）的出路（2026-09-28 使用者「拖一般車也要有彈性」；正式服 62 次
-- TrailerRotate、21 次在起步當下）：原地耦力調頭會把掛車甩斷，改向主 MOD 要一條不走回頭路的
-- 路線——避讓圈放在車尾正後方（近緣離車心 TOW_TURN_GAP_M），往回開都得穿圈，只剩往前繞一圈。
-- 驗收同堵車改道（穿圈／起點太遠拒）但長度放寬，另要從車頭方向出發。成功＝下一幀 cutover
-- （why=towturn），等待期間回 true 讓呼叫端停住（上限 TOW_TURN_WAIT_MS）；每 session 最多
-- TOW_TURN_TRIES 次。回 false＝沒有不用調頭的走法，呼叫端照舊交還。
function Drive.towTurnaround(s, playerNum, vehicle, now, fx, fy)
    if s.pendingRouteWhy == "towturn" then return now < (s.towTurnUntil or 0) end
    if (s.towTurnTries or 0) >= TUNE.TOW_TURN_TRIES then return false end
    s.towTurnTries = (s.towTurnTries or 0) + 1
    local api = navApi()
    local fin = MDADDynamics.finite -- 本檔的 local finite 定義在更後面
    if not api or not fin(s.lastTx) or not fin(s.lastTy) then return false end
    local vx, vy = vehicle:getX(), vehicle:getY()
    local back = TUNE.TOW_TURN_AVOID_R + TUNE.TOW_TURN_GAP_M
    local ax, ay = vx - fx * back, vy - fy * back
    local remaining = s.profile and (s.profile.length - s.lastSNow) or nil
    local route, why, rejected = requestDetourRoute(api, playerNum, s.lastTx, s.lastTy, ax, ay,
        remaining, TUNE.TOW_TURN_AVOID_R,
        fin(remaining) and remaining * TUNE.TOW_TURN_LEN_RATIO + TUNE.TOW_TURN_LEN_SLACK or nil, s.route)
    if route and not Drive.routeLeavesForward(route, vx, vy, fx, fy) then
        route, why, rejected = nil, "back", route
    end
    diagEvent(s, playerNum, "tow", {
        phase = "turn", why = why or "ok", x = ax, y = ay, attempt = s.towTurnTries,
        len = route and route.len or (rejected and rejected.len) or nil,
    })
    if getDebug() then
        print(LOG .. "pn=" .. playerNum .. " tow turnaround try=" .. s.towTurnTries .. " -> "
            .. (route and ("ok len=" .. tostring(route.len)) or ("rejected " .. tostring(why))))
    end
    if not route then
        s.rejectedRoute = rejected -- 主 MOD 快取已被覆寫成這條，交還前別讓 cutover 收下
        return false
    end
    Drive.pushAvoidHist(s) -- 先前的堵車避讓圈不因調頭圈蓋掉而遺失（調頭圈本身不進歷史）
    s.avoidX, s.avoidY, s.avoidR, s.avoidTow = ax, ay, TUNE.TOW_TURN_AVOID_R, true
    s.pendingDetour, s.pendingRouteWhy, s.nextRouteMs = true, "towturn", 0
    s.towTurnUntil = now + TUNE.TOW_TURN_WAIT_MS
    local playerObj = getSpecificPlayer(playerNum)
    if playerObj then haloGood(playerObj, MDADTrailer.KEY_TURN) end
    voice("detour", playerNum)
    return true
end

-- 拖車路線上有過不去的轉角（生效剖面 s.profileRoute.towBlocked 非空）：得知當下就向主 MOD 要一條避開那些轉角的線，
-- 不等開到轉角前才交還。主圈＝路線上第一個不可過轉角（最先開到的），圈心在轉角節點、半徑＝路口方塊半對角線
-- （towBlockedR）＋TOW_CORNER_AVOID_PAD；moreAvoid＝其餘不可過轉角＋本趟判死的舊圈（Drive.avoidMore），共最多 8 圈
-- （跳過圈住車位或目標的：任何路線都穿）。nav API <9 只給主圈，回來的線自己驗不穿其他圈（again）。
-- 驗收：requestDetourRoute 全套＋從車頭方向出發（back）＋新線走同一條剖面管線（Drive.profileRouteOf →
-- MDADTrailer.shape）後沒有不可過轉角（blocked）。拒收＝記 s.rejectedRoute（主 MOD 快取已被覆寫）、保留原線，
-- 行為照舊（guard 壓速、停在轉角前交還 TrailerCorner）。同一（route identity、轉角集合）只問一次；每 session
-- TOW_CORNER_TRIES 次；守「堵死時自動改道」選項（關著不問，同交還前改道 Drive.stuckDetour）。
-- 收下＝下一幀 cutover why=towcorner；這期間若已停在轉角前，呼叫端等 cutover（≤TOW_TURN_WAIT_MS）不交還。
-- 每幀呼叫：剖面沒換只比一次 identity，不配置。
function Drive.towCornerDetour(s, playerNum, vehicle, now, fx, fy)
    local pr = s.profileRoute
    local b = pr and pr.towBlocked
    if b == nil or #b == 0 or s.towCornerSeen == pr then return end
    s.towCornerSeen = pr
    local sig = ""
    for k = 1, #b do sig = sig .. string.format("%.1f,", b[k]) end
    if s.towCornerRoute == s.route and s.towCornerSig == sig then return end -- 重建同一條線（版本變、重接）
    s.towCornerRoute, s.towCornerSig = s.route, sig
    local fin, rr, pad = MDADDynamics.finite, pr.towBlockedR, TUNE.TOW_CORNER_AVOID_PAD
    local vx, vy, tx, ty = vehicle:getX(), vehicle:getY(), s.lastTx, s.lastTy
    local ax, ay = b[1], b[2]
    local r = (rr and fin(rr[1]) and rr[1] or 0) + pad
    local why, skip, route, rejected, left, more = nil, false, nil, nil, nil, nil
    local api = navApi()
    if not (type(MDAD.HUD) == "table" and type(MDAD.HUD.autoDetour) == "function" and MDAD.HUD.autoDetour() == true) then
        why, skip = "off", true
    elseif (s.towCornerTries or 0) >= TUNE.TOW_CORNER_TRIES then
        why, skip = "max", true
    elseif not api or type(api.requestDetour) ~= "function" then
        why = "api"
    elseif not fin(tx) or not fin(ty) or (tx - ax) * (tx - ax) + (ty - ay) * (ty - ay) <= r * r then
        why = "target"
    elseif (vx - ax) * (vx - ax) + (vy - ay) * (vy - ay) <= r * r then
        why = "inside"
    else
        s.towCornerTries = (s.towCornerTries or 0) + 1
        local j = 1
        for k = 3, #b - 1, 2 do
            j = j + 1
            local x, y = b[k], b[k + 1]
            local cr = (rr and fin(rr[j]) and rr[j] or 0) + pad
            if (more == nil or #more < 24) and (vx - x) * (vx - x) + (vy - y) * (vy - y) > cr * cr
                    and (tx - x) * (tx - x) + (ty - y) * (ty - y) > cr * cr then
                if more == nil then more = {} end
                more[#more + 1], more[#more + 2], more[#more + 3] = x, y, cr
            end
        end
        local hist = Drive.avoidMore(s, vx, vy, tx, ty, ax, ay, true)
        for k = 1, hist and #hist or 0 do
            if more == nil then more = {} end
            if #more >= 24 then break end
            more[#more + 1] = hist[k]
        end
        local v9 = fin(api.navApiVersion) and api.navApiVersion >= 9
        local remaining = s.profile and (s.profile.length - s.lastSNow) or nil
        route, why, rejected = requestDetourRoute(api, playerNum, tx, ty, ax, ay, remaining, r,
            fin(remaining) and remaining * TUNE.TOW_TURN_LEN_RATIO + TUNE.TOW_TURN_LEN_SLACK or nil, s.route,
            v9 and more or nil)
        if route and not v9 and Drive.crossesAnyAvoid(route, more) then route, why, rejected = nil, "again", route end
        if route and not Drive.routeLeavesForward(route, vx, vy, fx, fy) then route, why, rejected = nil, "back", route end
        if route then
            local shaped = Drive.profileRouteOf(route, s.tow, s.vehicleProfile, vx, vy)
            left = shaped.towBlocked and #shaped.towBlocked / 2 or 0
            if left > 0 then route, why, rejected = nil, "blocked", route end
        end
        -- 主 MOD 算出線就已覆寫快取（含被拒的）：記住 identity，cutover 不收；沒算出線＝快取沒動，舊的拒收紀錄保留
        if rejected ~= nil and not route then s.rejectedRoute = rejected end
    end
    diagEvent(s, playerNum, "detour", { phase = skip and "skip" or "towcorner", kind = "towcorner",
        why = why or "ok", x = vx, y = vy, s = s.lastSNow, hitX = ax, hitY = ay, avoidR = r,
        avoidN = more and #more / 3 or nil, towN = #b / 2, towLeft = left, attempt = s.towCornerTries,
        len = route and route.len or (rejected and rejected.len) or nil })
    if getDebug() then
        print(LOG .. "pn=" .. playerNum .. " tow corner detour corners=" .. #b / 2 .. " avoid=(" .. ax .. "," .. ay
            .. ") r=" .. r .. " more=" .. tostring(more and #more / 3) .. " -> "
            .. (route and ("ok len=" .. tostring(route.len)) or ("rejected " .. tostring(why))
                .. (left and left > 0 and (" left=" .. left) or "")))
    end
    if not route then return end
    s.pendingDetour, s.pendingRouteWhy, s.nextRouteMs = true, "towcorner", 0
    s.towCornerUntil = now + TUNE.TOW_TURN_WAIT_MS
    local playerObj = getSpecificPlayer(playerNum)
    if playerObj then haloGood(playerObj, KEY_DETOUR) end
    voice("detour", playerNum)
end

--------------------------------------------------------------------------------
-- 每幀控制
--------------------------------------------------------------------------------

-- 高速力臂延伸倍率 K（TUNE.ARM_EXT_*；理由見 TUNE）：kmh＝|車速|。拖車、貼縫爬行、殭屍軟縫側移中（s.zombieLane；
-- 0925p 高速側移本來就只有 1.4 m/s，要的就是側移）固定 1。
function Drive.armExtK(s, kmh)
    if s.tow or s.dodgeCrawl == true or s.zombieLane ~= nil or kmh <= TUNE.ARM_EXT_FROM_KMH then return 1 end
    local t = (kmh - TUNE.ARM_EXT_FROM_KMH) / (TUNE.ARM_EXT_FULL_KMH - TUNE.ARM_EXT_FROM_KMH)
    if t > 1 then t = 1 end
    return 1 + (TUNE.ARM_EXT_K - 1) * t
end

-- Compose lateral steering and bounded forward assist into the one BaseVehicle
-- impulse slot. A forward component uses the body centerline, so it adds no yaw.
local function applySteering(
        s, vehicle, fwd, fx, fy, steer, speedKmh, mult, coupled, assistForce)
    if steer > 5 then steer = 5 elseif steer < -5 then steer = -5 end
    if not coupled then
        -- 非耦力側推隨車身前進速度（TUNE.STEER_FULL_KMH／TOW_STEER_FULL_KMH）：靜止不橫推，側滑也不算車速
        -- （TUNE.STEER_SLIP_MARGIN_KMH）。讀不到線速度時退回 |v|。
        local full = s.tow and TUNE.TOW_STEER_FULL_KMH or TUNE.STEER_FULL_KMH
        local tv = speedKmh < 0 and -speedKmh or speedKmh
        if tv < full + TUNE.STEER_SLIP_MARGIN_KMH then
            local fwdKmh = Drive.forwardKmh(vehicle, fx, fy)
            if fwdKmh ~= nil and fwdKmh < tv then tv = fwdKmh end
        end
        if tv < full then steer = steer * tv / full end
    end
    if steer < STEER_DEADZONE and steer > -STEER_DEADZONE then steer = 0 end
    -- Follower 的 yaw 增益估計要拿「真的施出去」的 steer（含 cross-track 與夾限；耦力調頭
    -- 是力偶不是側推，不進估計）——0908a 弧段自適應前饋
    s.fstate.appliedSteer = (not coupled) and steer or nil
    s.fstate.escLimited = not coupled and s.escScale < 1 -- 側滑幀不進高速增益學習（Follower FF_HI）
    if s.brakeImpulseThis then return 0, 0 end -- 本幀已施硬煞外力（單槽 addImpulse）
    -- assistForce 可為負＝沿車身中線的減速分量（Drive.visAssistForce）；中線分量與前臂平行，不產生 yaw。
    if type(assistForce) ~= "number" or assistForce * 0 ~= 0 then assistForce = 0 end
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
    -- 高速力臂延伸（TUNE.ARM_EXT_*）：臂×ext、力÷ext，力矩不變
    local ext = coupled and 1 or Drive.armExtK(s, av)
    if ext ~= 1 then arm, force = arm * ext, force / ext end
    s.armExt = ext

    local parity = s.parity
    s.parity = -parity
    local impulse = BaseVehicle.allocVector3f()
    if coupled then
        local rf = force * (s.uturn and s.uturn.force or TUNE.UTURN.gentle.force)
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
        if assistForce ~= 0 then
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
local function longitudinalAssistForce(s, speedKmh, targetSpeed, mult, rough, zombiePush)
    local mass = s.runtimeMass
    if type(mass) ~= "number" or mass * 0 ~= 0 then return 0 end
    if mass < TUNE.ASSIST_MASS_MIN then
        -- 殭屍推撞與越野免質量門檻（輕車推得動路面阻力，推不動一群殭屍；草地上也
        -- 推不動——2026-09-04 s047：1118kg van 草地 3 km/h、regulator 20、assist 0，
        -- 使用者「碰到草地速度怎慢到個位數」）
        if not (zombiePush or rough) then return 0 end
        mass = mass * TUNE.ASSIST_LIGHT_MAX_X
        if mass > TUNE.ASSIST_MASS_MIN then mass = TUNE.ASSIST_MASS_MIN end
    end
    local scale = 1
    if rough then
        local vp = type(s.vehicleProfile) == "table" and s.vehicleProfile or nil
        scale = MDADDynamics.assistOffroadScale(vp and vp.offroadEfficiency or nil)
        -- 輪胎抓地（script wheelFriction，`VehicleScript.getWheelFriction`）低於基準的車再乘
        -- 基準/實際（上限 ASSIST_TIRE_MAX；使用者 2026-09-04「推力按車重、輪胎曲線增加」）
        local wf = vp and vp.wheelFriction or nil
        if MDADDynamics.finite(wf) and wf > 0 and wf < TUNE.ASSIST_TIRE_REF then
            scale = scale * math.min(TUNE.ASSIST_TIRE_MAX, TUNE.ASSIST_TIRE_REF / wf)
        end
    end
    if zombiePush and scale < TUNE.ZOMBIE_PUSH_SCALE then scale = TUNE.ZOMBIE_PUSH_SCALE end
    local ratio = MDADDynamics.longitudinalAssistRatio(
        speedKmh, targetSpeed, scale,
        s.physicalOffroad == true and TUNE.ASSIST_OFFROAD_SPEED_MAX_KMH or nil)
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

-- 硬煞外力輔助（TUNE.BRAKE_ASSIST_*）：只在距離確定的緊急煞車（障礙前、可視前緣前，見 emergencyBrakeDist）
-- 照一般硬煞停不住時才施（need＝v²／2d 超過 NEED）；彎道／回線等一般煞車不加，避免平常突然重煞。
-- 每幀最多一次 addImpulse，本幀已施則 applySteering 不再施力。
function Drive.brakeAssist(s, vehicle, dist)
    if s.brakeImpulseThis or not MDADDynamics.finite(dist) then return end
    local v = vehicle:getCurrentSpeedKmHour()
    if not MDADDynamics.finite(v) or v <= TUNE.BRAKE_ASSIST_MIN_KMH then return end
    local vm = v / 3.6
    if dist < 0.5 then dist = 0.5 end
    if vm * vm / (2 * dist) <= TUNE.BRAKE_ASSIST_NEED then return end
    local k = (v - TUNE.BRAKE_ASSIST_MIN_KMH) / (TUNE.BRAKE_ASSIST_FULL_KMH - TUNE.BRAKE_ASSIST_MIN_KMH)
    if k > 1 then k = 1 end
    local mass = s.runtimeMass
    if not MDADDynamics.finite(mass) or mass < 1 then mass = MASS_FALLBACK end
    local mult = getGameTime():getMultiplier()
    if mult < MULT_MIN then mult = MULT_MIN elseif mult > MULT_MAX then mult = MULT_MAX end
    local rel = BaseVehicle.allocVector3f()
    vehicle:getForwardVector(rel)
    local fx, fy = rel:x(), rel:z()
    local len = sqrt(fx * fx + fy * fy)
    if MDADDynamics.finite(len) and len > 1e-3 then
        local f = TUNE.BRAKE_ASSIST_RATIO * k * mass * IMPULSE_SCALE * (mult / MULT_NORM) / len
        local imp = BaseVehicle.allocVector3f()
        imp:set(-f * fx, 0, -f * fy)
        rel:set(0, 0, 0)
        vehicle:addImpulse(imp, rel)
        BaseVehicle.releaseVector3f(imp)
        s.brakeImpulseThis, s.brakeAssistForce = true, f * len
    end
    BaseVehicle.releaseVector3f(rel)
end

-- 緊急外力煞車的障礙距離：「等待繞行的障礙群」「已判定堵住的障礙」與「看得到的最遠處」有確定距離；
-- 彎道等其他煞車理由回 nil（不加外力）。可視距離的硬煞只在連緊急煞車都停不到前緣時才觸發
--（0911c／0927 分帳），那時就是「真的煞不住」——2026-09-28 使用者裁定不限速、煞不住用輔助力協助，
-- 同一條車頭反向中心力照樣只在 v²/2d 超過 BRAKE_ASSIST_NEED 時施。距離＝硬煞帳的前緣扣 halfL＋2
--（MDADDynamics.visibilityCapKmh 同一個緩衝）。
function Drive.emergencyBrakeDist(s, reason, blockedStop)
    local halfL = s.vehicleProfile and s.vehicleProfile.halfL or 2
    if reason == "dodge-defer" and MDADDynamics.finite(s.dodgeDeferS) then
        return s.dodgeDeferS - s.lastSNow - halfL
    end
    if (blockedStop or reason == "blocked-approach") and MDADDynamics.finite(s.blockS) and s.blockS > 0 then
        return s.blockS - s.lastSNow - halfL
    end
    if reason == "visibility" and MDADDynamics.finite(s.visHardAhead) then
        return s.visHardAhead - halfL - 2
    end
    return nil
end

local function commandForceBrake(s, vehicle, now, why)
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
    s.forceBrakeWhy = why or "?" -- telemetry fbw（閂鎖期間持續可見）；呼叫端明確給，不猜上一個 cap
    if type(now) ~= "number" or now * 0 ~= 0 then now = getTimestampMs() end
    local untilMs = now + 1000
    if untilMs > s.forceBrakeUntil then s.forceBrakeUntil = untilMs end
    return true
end

-- 硬煞執行（0929p，使用者裁定）。一般車＝一秒鎖輪（commandForceBrake）。拖車 ≥TOW_NOLOCK_KMH 改不鎖輪：
-- 牽引車鎖死時掛車（沒有煞車，CarController.updateTrailer:383-393）從後面推，E2E semi-long-mp（W900＋40 呎
-- 貨櫃）鎖輪中整組只減 2.0 m/s²（滑行 1.7–1.9），方向也跟著沒了；不鎖輪的分攤外力實測 5–5.5。改成斷油（呼叫端
-- 已關 regulator）＋兩節各自 TOW_BRAKE_DECEL 的中線外力（掛車照 towDecel），並照常轉向（同一個 impulse 槽由
-- applySteering 合成）。低速才鎖輪停住；dynamics-fault 仍鎖輪（外力換算用的質量／幀倍率本身不可信）。
-- 走不鎖輪時回本幀側推（telemetry f），鎖輪回 nil（呼叫端照舊補 brakeAssist）。
-- 會車／跟車停等（followHold，why＝moving）一般車同樣不鎖輪（1001a）：正式服 0.16.0 兩台 90 km/h 在 5m 路對撞，
-- 讓車判定出來時已經太近，隨即一秒鎖輪——鎖輪中方向盤沒用，只能直直撞上。不鎖輪的中線外力＋斷油減速度相近
-- （輕車 3.6＋7），而且還能照讓車線往右閃。接觸（currentBlocked）照舊鎖輪。
-- 回線待命（return-hold）在 RETURN_NOLOCK_KMH 以上同樣不鎖輪（1001d）：正式服 FuFu 閃完殭屍離常駐線 2.9m、
-- RETURN 一進就待命，52 km/h 一秒鎖輪直直滑出去；低速照舊鎖輪停住。
-- 調頭前煞停（why＝rotate）與 blocked 接近包絡（why＝blocked-approach）同樣門檻（1001e）：正式服 susu 81.8 km/h
-- 改目標到車後，一秒鎖輪連續 4.5 秒只從 82 減到 27；GTR 50 km/h、MR2 64 km/h 在 22–56m 外判 blocked 就一秒鎖到 0，
-- 下一輪就承諾了 18 km/h 的繞行。停止線的 blocked（blockedStop）照舊鎖輪兜底。
-- 彎道 ×1.5 災難超速（why＝curve，1002a）10 km/h 以上同樣不鎖輪：鎖輪＝同時失去縱向與側向抓地，正好在彎裡
-- 最需要轉向的時候（正式服 0.16.0 curve 鎖輪 0.69 次/h；片段入弧 18–45 km/h 一鎖就 sk 0.02–0.05、整台停住才轉）。
-- 中線外力＋斷油比鎖輪快一倍（1001e E2E）、照常轉向，超速一消失就交回 regulator 與彎前減速輔助。
-- 待承諾接近的硬煞（why＝dodge-defer）同 blocked 接近門檻（正式服 0.17.0 Aho/clip-21：39.5 km/h 一秒鎖到 0）。
-- steer 傳 nil＝本幀只減速、不轉向（調頭要先煞到近停才轉，鎖輪時本來就不施轉向）。
-- （`finite` 在本檔較後面才定義，這裡用 MDADDynamics.finite。）
function Drive.hardBrake(s, vehicle, now, why, speedKmh, mult, steer, heading, fwd, fx, fy)
    -- 只對「往前開」的車不鎖輪：外力沿車頭反向，倒退時施下去會加速倒退（0929p 審查）
    local nolock = s.tow or ((why == "moving" or why == "animal-stop" or why == "player-stop")
        and s.followHold and not s.currentBlocked)
    local minKmh = TUNE.TOW_NOLOCK_KMH
    if not nolock and not s.currentBlocked and (why == "rotate" or why == "blocked-approach" or why == "dodge-defer"
            or ((why == "return" or why == "return-hold") and s.returnHold)) then
        nolock, minKmh = true, TUNE.RETURN_NOLOCK_KMH
    elseif not nolock and not s.currentBlocked and why == "curve" then
        nolock = true
    end
    if not nolock or why == "dynamics-fault"
            or not (MDADDynamics.finite(speedKmh) and speedKmh >= minKmh) then
        commandForceBrake(s, vehicle, now, why)
        return nil
    end
    local mass = s.runtimeMass
    if not MDADDynamics.finite(mass) or mass < 1 then mass = MASS_FALLBACK end
    local a = TUNE.TOW_BRAKE_DECEL
    -- 記成本幀的輔助減速度（telemetry vad）：下一幀 visAssistPrev>0，滑行學習不收這一幀（外力不是車的能力；
    -- 不記的話斷油＋外力的 ~8 m/s² 會被當滑行學進 safeCoast）。沒有鎖輪閂鎖，煞車學習本來就不收。
    s.visAssistDecel, s.visAssistWhy = a, why
    s.towBrakeWhy = why or "?"
    Drive.towDecel(s, a, mult)
    local st = 0 -- steer nil＝不轉向（調頭前煞停）；照常轉向時才走回授正規化與 yaw 率限制
    if steer ~= nil then st = Drive.yawGovern(s, Drive.normalizeSteer(s, steer), heading, speedKmh, now) end
    local force, assist = applySteering(s, vehicle, fwd, fx, fy, st,
        speedKmh, mult, false, -a * mass * (mult / MULT_NORM) / (0.01 * 48 / MULT_NORM))
    s.lastAssistForce = assist
    return force
end

-- MP 假速度域（2026-09-02 s012 定罪：regulator 70、w=14 直路 30 秒貼死 51 km/h，
-- 手動同車可到 64）。CarController 拿 speedLimited = v·lerp(1, fake, (v/min(120,
-- SpeedLimit))²) 與 regulatorSpeed 比、達標就斷油（CarController.java:138-145、
-- 240-244）；fake = 120/min(SpeedLimit,120)（BaseVehicle.java:663-669，SP 恆 1）。
-- 伺服器 SpeedLimit 預設 70 → fake 1.714，真速 51 就被當 70。手動踩油門沒有這道
-- 比較，所以只有自駕跑不到。原版儀表同樣顯示真速×fake（ISVehicleDashboard.lua:256）。
-- 寫 regulator 前把目標映到同一域（單調；fake=1 恆等），HUD／遙測的 tgt 仍是真速。
-- （`finite` 在本檔較後面才定義，這裡用 MDADDynamics.finite。）
local function regulatorDomainKmh(kmh)
    local cls = BaseVehicle
    if cls == nil then return kmh end
    local fn = cls.getFakeSpeedModifier
    if type(fn) ~= "function" then return kmh end
    local ok, fake = pcall(fn)
    if not ok or not MDADDynamics.finite(fake) or fake <= 1 then return kmh end
    local d = kmh * fake / 120  -- = kmh / min(SpeedLimit, 120)
    return kmh * (1 + (fake - 1) * d * d)
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
    commandSpeed = math.floor(regulatorDomainKmh(commandSpeed) + 0.5)
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
-- 無折點回 nil）與該折角（rad）。過渡段提早完成用；事件驅動冷路徑。
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
    return bestS, best
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

-- 期望行駛線＝laneBias（過該段路面餘裕，與 follower 前視／線建同一張表）＋
-- （繞行中）smoothstep 側偏。抽出只為遙測 el／ld 與甩出判定共用，語意逐位元不變。
local function expectedLaneOf(s)
    local expL = MDADFollower.laneBiasAt(s.profile, laneBiasOf(s), s.fstate.idx, s.lastSNow, s.fstate.laneKeep)
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

-- 路外起步的越野接線（2026-09-27 E2E startpush-sp loc=c25＝正式服原位置）：主 MOD 路線只含路網
-- （NavRoute.lua:1530「len／cost 不含兩端 approach」），起點是路網上離車最近的點。車停在路外、
-- 而且路網在車「前面」才開始（死路端點／路的起點：車投影到第一段的縱向座標 < −APPROACH_BEHIND_M）
-- 時，剖面從 s=0 起算、車實際在起點之前的那幾公尺被夾掉——路線起點旁有硬物就排不出入口
-- （steep／sweep），倒車又垂直於路線、換不到跑道，三次後受困交還。把「車位→路線起點」這段地圖上
-- 本來就畫著的越野接線接在剖面前面：Sensor 沿它掃、corridor 沿它排、世界掃掠照驗，車從 s=0 的
-- 自己位置出發。這不是 0908e 禁止的「虛構前置道路」（那是沿路線反方向往車後憑空延伸、可能穿牆）：
-- 接線起點就是車本身、終點是路網，中間是車本來就得開過去的地面，否決權照舊在世界掃掠。
-- 車在路旁（投影落在第一段內）不接——那是 RETURN 的平滑併入；拖車不接（外拉轉角另有改寫）。
-- 只在起步接：行駛中主 MOD 重算的路線起點就是車的投影點；中途 cutover 仍用原路線（不改既有語意）。
-- 只接「整條路線離車最近的就是起點」且 ≤ SNAP_MAX_M（0928a）：主 MOD 同目標、偏航 ≤12 格一律回快取
-- 同一條線（NavRoute.lua ensureRoute），玩家開著導航走了一段再按自駕時，起點早在車後——0.13.1 正式服
-- 10 趟接出 164／7136m 的「回頭接線」（車離某段只有 0.4-6m），車被拉回起點重開一遍。
-- 離路太遠（0928b；E2E replay Annilex/clip-05：車在路旁 17m 草地，RETURN 只收 ≤RETURN_MAX_DEV 12m，超過就只剩
-- pure pursuit 斜切向前視點，中間的圍籬沒有任何規劃看得到，擦撞→倒車三次→交還）：離整條路線最近點超過
-- RETURN_MAX_DEV（≤ SNAP_MAX_M）時，同樣把「車位→最近點」接成剖面開頭、最近點之前的路線捨去，讓感知／繞行
-- 沿這段實際要開的地面規劃。
-- 回傳 (剖面用路線, 接線長)；不接時原樣回傳同一個 table（cutover 仍以原 route identity 比對）。
function Drive.approachRoute(route, vx, vy)
    local pts = route.pts
    if type(pts) ~= "table" or #pts < 4 or not finite(vx) or not finite(vy) then return route, 0 end
    local best, bk, bt, bx1, by1 = nil, 1, 0, pts[1], pts[2]
    for i = 1, #pts - 3, 2 do
        local ax, ay = pts[i], pts[i + 1]
        local ex, ey = pts[i + 2] - ax, pts[i + 3] - ay
        local qx, qy = vx - ax, vy - ay
        local l2 = ex * ex + ey * ey
        local t = 0
        if l2 > 1e-12 then
            t = (qx * ex + qy * ey) / l2
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
        end
        local px, py = ax + t * ex, ay + t * ey
        local dx, dy = vx - px, vy - py
        local d2 = dx * dx + dy * dy
        if best == nil or d2 < best then best, bk, bt, bx1, by1 = d2, i, t, px, py end
    end
    local snap2 = TUNE.SNAP_MAX_M * TUNE.SNAP_MAX_M
    if best == nil or not finite(best) or best > snap2 then return route, 0 end
    local x1, y1 = pts[1], pts[2]
    local ux, uy = pts[3] - x1, pts[4] - y1
    local sl = sqrt(ux * ux + uy * uy)
    if not finite(sl) or sl < 1e-6 then return route, 0 end
    local behind = bk == 1 and bt == 0
        and ((vx - x1) * ux + (vy - y1) * uy) / sl <= -TUNE.APPROACH_BEHIND_M
    local far = best > TUNE.RETURN_MAX_DEV * TUNE.RETURN_MAX_DEV
    if not behind and not far then return route, 0 end
    -- 最近點落在第 seg 段（pts 索引 bk）；該段的起點若就是最近點（t=0）就從它開始，否則從最近點開始、接該段終點
    local seg = (bk + 1) / 2
    local np = { vx, vy, bx1, by1 }
    local from = bk + 2
    if bt >= 1 then
        from = bk + 4
        if from > #pts then return route, 0 end -- 最近點就是終點：沒有後續路段可接
    end
    for i = from, #pts do np[#np + 1] = pts[i] end
    local out = {}
    for k, v in pairs(route) do out[k] = v end
    out.pts = np
    if type(route.segSurface) == "table" and type(route.segWidth) == "table" then
        -- 接線沿用接入段的宣告路面：宣告成 dirt 會讓起步那段的 traction key 與進路後不同、
        -- 多一次剖面重建；實際路外由 physicalOffroad（去抖）接手
        local first = bt >= 1 and seg + 1 or seg
        if first > #route.segSurface then first = #route.segSurface end
        local ss, sw = { route.segSurface[first] }, { TUNE.APPROACH_WIDTH_M }
        for i = first, #route.segSurface do ss[#ss + 1] = route.segSurface[i] end
        for i = first, #route.segWidth do sw[#sw + 1] = route.segWidth[i] end
        out.segSurface, out.segWidth = ss, sw
    end
    local gap = sqrt(best)
    if finite(route.len) then
        -- 捨去的前段長（起點到最近點）
        local cut = 0
        for i = 1, bk - 2, 2 do
            local dx, dy = pts[i + 2] - pts[i], pts[i + 3] - pts[i + 1]
            cut = cut + sqrt(dx * dx + dy * dy)
        end
        local dx, dy = bx1 - pts[bk], by1 - pts[bk + 1]
        cut = cut + sqrt(dx * dx + dy * dy)
        out.len = route.len - cut + gap
    end
    return out, gap
end

-- 剖面實際建構的路線（起步與 cutover 共用）：先清地圖資料的微反折（MDADFollower.despikeRoute），
-- 拖車再改寫外拉轉角並清改寫撤點殘留的折返；不拖車時 approach＝true 才接越野接線。
-- 回 (剖面路線, 接線長)；despiked 記兩次清掉的點數（route ready 事件 detail）。
function Drive.profileRouteOf(route, tow, vp, vx, vy, approach)
    local clean = MDADFollower.despikeRoute(route)
    if tow then
        local shaped = MDADFollower.despikeRoute(MDADTrailer.shape(clean, tow, vp.halfW, vp.halfL * 2))
        if (clean.despiked or 0) > 0 then shaped.despiked = (shaped.despiked or 0) + clean.despiked end
        return shaped, 0
    end
    if approach then return Drive.approachRoute(clean, vx, vy) end
    return clean, 0
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

-- 繞行線的可視帽（commit／guard 共用）：同一般跟線的「終點不是障礙」地板（0928k；rc9 0104／0109：
-- 路線終點前 4–9m 的繞行，可視帽把終點當未知前緣扣 halfL＋2 → 0，車停在終點前、帶著偏移永遠
-- 進不了到站圈，倒車三次交還）。可視帶已含路線終點、剩 ≤ ARRIVE_M+3 時地板到爬行檔。
function Drive.dodgeVisibilityCap(s, sen, minBrake)
    local visEnd = visibleEndS(sen, s.lastSNow)
    local cap = MDADDynamics.visibilityCapKmh(visEnd - s.lastSNow, 0.5, minBrake, s.vehicleProfile.halfL)
    local prof = s.profile
    if prof and visEnd >= prof.length - 0.5 and prof.length - s.lastSNow <= MDADFollower.ARRIVE_M + 3
            and cap < MDADDynamics.DODGE_SQUEEZE_CAP then
        cap = MDADDynamics.DODGE_SQUEEZE_CAP
    end
    return cap
end

-- 軟縫側移速率（m/s）：固定 1 m/s 在 60 km/h 要 3 秒、50m 才偏完 2m，常被縱向配合帽壓到十幾 km/h
-- （E2E zombie-sp 基準：單隻殭屍 70→35）。改依車速取「車頭偏約 6°」的橫向速度（0.1×v），
-- 下限原本的 1 m/s、上限 ZOMBIE_LANE_RATE_MAX。
function Drive.softLaneRate(speedKmh)
    local r = (finite(speedKmh) and speedKmh > 0 and speedKmh / 3.6 or 0) * TUNE.ZOMBIE_LANE_RATE_PER_MPS
    if r < TUNE.ZOMBIE_LANE_RATE_MPS then r = TUNE.ZOMBIE_LANE_RATE_MPS end
    if r > TUNE.ZOMBIE_LANE_RATE_MAX then r = TUNE.ZOMBIE_LANE_RATE_MAX end
    return r
end

-- 軟縫移動中：常駐線到目前軟縫 lane 之間都是預期位置——車追 laneBias 的落後不是「對不準」，
-- 不得觸發 align 減速（側移加快後落後 1–2m，舊判定會把 70 壓到 40 幾）。回傳到該區間的距離，
-- 不在軟縫中時原值不變。
function Drive.softAlignDev(s, absDev)
    local zl, rb, lat = s.zombieLane, s.residentBias, s.lastLatSigned
    if zl == nil or not finite(rb) or not finite(lat) then return absDev end
    local lo, hi = math.min(rb, zl), math.max(rb, zl)
    local d = lat < lo and lo - lat or (lat > hi and lat - hi or 0)
    return d < absDev and d or absDev
end

-- lane ramp 落後（0928c）：常駐線在彎／窄段前後沿弧長 ramp（Follower clampLane），車追 ramp 本來就落後
-- 約 LANE_LAG_S 秒——車身落在「LAG 秒前那一點的期望線」與「現在的期望線」之間＝還在跟上，不是對不準
-- （E2E rc1 十五趟 25 次：彎後加速時期望線 0→2m、車落後 1.1m，alignment 帽把 45 壓到 20–26）。
-- 繞行／RETURN 各有自己的線，斜切保持是不夾的常數 lane（Drive.laneKeepOf＝false），都不套——保持中拿夾過的 lane 當
-- 區間另一端，車從保持 lane 往路斜切的整段都讀成偏差 0。回傳到該區間的距離（不大於原偏差）。
function Drive.laneRampDev(s, absDev, speedKmh)
    if s.dodging or s.returnActive or finite(s.holdLaneL) then return absDev end
    local p, lat, el = s.profile, s.lastLatSigned, s.diagExpL
    if type(p) ~= "table" or p.laneRoomR == nil or not finite(lat) or not finite(el) then return absDev end
    local back = (finite(speedKmh) and speedKmh > 0 and speedKmh / 3.6 or 0) * TUNE.LANE_LAG_S
    if back < 1 then return absDev end
    local sb = s.lastSNow - back
    if sb < 0 then sb = 0 end
    local ep = MDADFollower.laneBiasAt(p, laneBiasOf(s), MDADFollower.segIndexAt(p, sb), sb)
    if not finite(ep) then return absDev end
    local lo, hi = ep, el
    if lo > hi then lo, hi = el, ep end
    local d = lat < lo and lo - lat or (lat > hi and lat - hi or 0)
    return d < absDev and d or absDev
end

-- 縱向配合帽：最高能用多快的車速在到殭屍前（room 公尺）做完 dl 側移＋留 LEAD 秒。速率隨車速變，
-- 可行集合是 [0, vmax] 的區間，二分求 vmax（冷路徑：每輪一次、24 次迭代）。下限 MIN_KMH（殭屍可撞）。
function Drive.softLaneCapKmh(room, dl)
    local lo, hi = 0, 60
    for _ = 1, 24 do
        local v = (lo + hi) * 0.5
        if room / v >= dl / Drive.softLaneRate(v * 3.6) + TUNE.ZOMBIE_LANE_LEAD_S then lo = v else hi = v end
    end
    local cap = lo * 3.6
    if cap < TUNE.ZOMBIE_LANE_MIN_KMH then cap = TUNE.ZOMBIE_LANE_MIN_KMH end
    return cap
end

-- 不准減速時，走 dist 公尺前 laneBias 最多能側移多遠（速率上限×可用時間，扣車身追線的落後 lag，
-- 預設 LEAD_S）
function Drive.softReach(dist, vms, speedKmh, lag)
    local t = dist / vms - (lag or TUNE.ZOMBIE_LANE_LEAD_S)
    if not finite(t) or t < 0 then return 0 end
    return Drive.softLaneRate(speedKmh) * t
end

-- 軟縫側移掃過的弧長終點（1004a）：laneBias 以 softLaneRate 走完 dl、再 3τ 指數收尾，車身再落後 LEAD_S；
-- 至少看到 SOFT_LOOKAHEAD_M（低速時與舊制同一個視窗）。回常駐線的硬物檢查只到這裡（zombieLaneOf）。
function Drive.softShiftEndS(s, dl, speedKmh)
    local v = finite(speedKmh) and speedKmh > 0 and speedKmh / 3.6 or 0
    local t = dl / Drive.softLaneRate(speedKmh) + 3 * TUNE.ZOMBIE_LANE_TAU_MS / 1000 + TUNE.ZOMBIE_LANE_LEAD_S
    local reach = s.vehicleProfile.halfL + v * t
    if reach < MDADDynamics.SOFT_LOOKAHEAD_M then reach = MDADDynamics.SOFT_LOOKAHEAD_M end
    return s.lastSNow + reach
end

-- 離殭屍區間邊多留的距離（softZombieLane 的 prefer）：低速 PREFER、高速多 EXTRA（車身追線誤差
-- 與殭屍撲擊隨車速放大；段不夠寬時 softZombieLane 自行退回貼 R）。
function Drive.softPrefer(speedKmh)
    local t = 0
    if finite(speedKmh) then
        t = (speedKmh - TUNE.ZOMBIE_PREFER_SLOW_KMH) / (TUNE.ZOMBIE_PREFER_FAST_KMH - TUNE.ZOMBIE_PREFER_SLOW_KMH)
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    return MDADCorridor.ZOMBIE_PREFER + TUNE.ZOMBIE_PREFER_EXTRA_M * t
end

-- u 到 [sFrom, sEnd] 內最近軟避讓點的橫向距離
function Drive.softClearAt(pS, pL, predN, sFrom, sEnd, u)
    local dmin = 1e9
    for i = 1, predN do
        local zs = pS[i]
        if zs >= sFrom and zs <= sEnd then
            local d = math.abs(pL[i] - u)
            if d < dmin then dmin = d end
        end
    end
    return dmin
end

-- 換邊遲滯（1005 soft E2E animal-sp cow：路緣硬物取樣柱在格內跳動，可行帶右緣每輪在 4.68–5.19 之間換，右縫只差
-- 0.1m 時一輪有一輪沒有，選縫左右每輪來回翻 2–5m，lane 永遠停在牛前方，最後 43 km/h 擦過）：同一個威脅（弧長 3m、
-- 橫向 0.5m 內、同 routeGen、軟縫持有中），上一輪選的那一側本輪若仍在可行帶（容許 SOFT_HARD_JITTER_M，正是帶緣
-- 讓出的取樣跳動量）內、而且整個視窗的軟避讓點（含舒適餘裕與預測位）都在 R 外，就留在那一側：本輪換到另一側的縫，
-- 或找不到縫（nogap／least／curve）時都一樣。回 (want, why)；why 為 gap 時記下這一側給下一輪。
function Drive.softKeepSide(s, pS, pL, predN, sFrom, sTo, want, why, threatS, threatL, aLo, aHi, R)
    local w = s.zombieSideW
    if finite(w) and s.zombieSideGen == s.routeGen and s.zombieLane ~= nil and finite(threatS)
            and math.abs(threatS - s.zombieSideS) < 3 and math.abs(threatL - s.zombieSideTL) < 0.5
            and ((why == "gap" and (want - threatL) * (w - threatL) < 0)
                or why == "nogap" or why == "least" or why == "curve")
            and w >= aLo - TUNE.SOFT_HARD_JITTER_M and w <= aHi + TUNE.SOFT_HARD_JITTER_M then
        local clear = true
        for i = 1, predN do
            local zs = pS[i]
            if zs >= sFrom and zs <= sTo then
                local lane = MDADFollower.laneBiasAt(s.profile, w, MDADFollower.segIndexAt(s.profile, zs), zs, s.softKeepTry)
                if math.abs(pL[i] - lane) < R - 1e-6 then clear = false; break end
            end
        end
        if clear then want, why = w, "gap" end
    end
    if why == "gap" then
        s.zombieSideW, s.zombieSideS, s.zombieSideTL, s.zombieSideGen = want, threatS, threatL, s.routeGen
    end
    return want, why
end

-- 無縫時的最不壞 lane（0925p E2E road MAX：路肩也有殭屍、整條帶無縫時舊制停在原 lane，
-- 車貼路緣 1.5 秒連撞兩隻）：候選＝帶兩端＋相鄰殭屍的中點，取離最近殭屍最遠者；同分取離 cur 近者。
-- 零配置，O(n²)（n＝最近一群的點數）。
function Drive.softBest(pS, pL, predN, sFrom, sEnd, lo, hi, cur)
    local bestU, bestD = lo, Drive.softClearAt(pS, pL, predN, sFrom, sEnd, lo)
    for k = 0, predN do
        local u
        if k == 0 then
            u = hi
        else
            local zs = pS[k]
            if zs >= sFrom and zs <= sEnd then
                local nb = nil -- 右側最近鄰
                for j = 1, predN do
                    local zj = pS[j]
                    if zj >= sFrom and zj <= sEnd and pL[j] > pL[k] and (nb == nil or pL[j] < nb) then nb = pL[j] end
                end
                if nb ~= nil then u = (pL[k] + nb) * 0.5 end
            end
        end
        if u ~= nil and u >= lo and u <= hi then
            local d = Drive.softClearAt(pS, pL, predN, sFrom, sEnd, u)
            if d > bestD + 1e-6 or (d > bestD - 1e-6 and math.abs(u - cur) < math.abs(bestU - cur)) then
                bestU, bestD = u, d
            end
        end
    end
    return bestU
end

-- 軟縫選 lane：在 [sFrom, sEnd] 內找離殭屍區間最近的 lane，並以逐點實際落點（laneBiasAt）複驗；
-- 彎內混合把提案夾回殭屍佔位時只再問另一側。回 (lane 或 nil, why＝gap／nogap／curve)。
-- prefer（選填）傳給 softZombieLane：離殭屍區間邊多留多少（nil＝預設 PREFER）。
function Drive.softPick(s, pS, pL, predN, sFrom, sEnd, halfW, resident, cur, aLo, aHi, R, prefer)
    local why = "nogap"
    for _ = 1, 2 do
        local u = MDADCorridor.softZombieLane(pS, pL, predN, sFrom, sEnd, halfW, resident, cur,
            aLo, aHi, TUNE.ZOMBIE_LANE_LAMBDA, s.zomTmpLo, s.zomTmpHi, prefer)
        if u == nil then return nil, "nogap" end
        local clear = true
        for i = 1, predN do
            local zs = pS[i]
            if zs >= sFrom and zs <= sEnd then
                -- s.softKeepTry：貼路緣重找（keep 0）時複驗也要用 control 會用的同一個 keep
                local lane = MDADFollower.laneBiasAt(s.profile, u, MDADFollower.segIndexAt(s.profile, zs), zs, s.softKeepTry)
                if math.abs(pL[i] - lane) < R - 1e-6 then clear = false; break end
            end
        end
        if clear then return u, "gap" end
        why = "curve"
        if u > 0 then aHi = math.min(aHi, 0)
        elseif u < 0 then aLo = math.max(aLo, 0)
        else break end
        if aLo > aHi then break end
    end
    return nil, why
end

-- 選定／保持的 lane 之後（弧長 > sAfter）第一隻會撞到的軟避讓點：回 (弧長, 至少還要側移多少)
function Drive.softNextConflict(s, pS, pL, predN, sAfter, sTo, lane, R)
    local nextS, need = nil, 0
    for i = 1, predN do
        local zs = pS[i]
        if zs > sAfter and zs <= sTo then
            local l = MDADFollower.laneBiasAt(s.profile, lane, MDADFollower.segIndexAt(s.profile, zs), zs, s.softKeepTry)
            local dd = math.abs(pL[i] - l)
            if dd < R and (nextS == nil or zs < nextS) then nextS, need = zs, R - dd end
        end
    end
    return nextS, need
end

-- 「閃避殭屍與屍體」選項（HUD getter；缺席＝開）
function Drive.zombieDodgeOn()
    local hud = MDAD.HUD
    if type(hud) == "table" and type(hud.zombieDodge) == "function" then
        local ok, v = pcall(hud.zombieDodge)
        if ok then return v == true end
    end
    return true
end

-- 「閃避動物」選項（HUD getter；1 關／2 大型／3 全部；缺席或非法＝2）
function Drive.animalDodgeLevel()
    local hud = MDAD.HUD
    if type(hud) == "table" and type(hud.animalDodge) == "function" then
        local ok, v = pcall(hud.animalDodge)
        if ok and (v == 1 or v == 2 or v == 3) then return v end
    end
    return 2
end

-- 軟避讓點（Sensor zomKind）在 level（1 關／2 大型／3 全部）下算不算數：選縫看 AnimalDodge、停等看
-- 沙盒 AnimalSlowdown，同一套分級。其他玩家永遠算；殭屍／屍體（含沒有 zomKind 的舊快照）看 zOn。
function Drive.softKindIn(kind, zOn, level)
    if kind == "player" then return true end
    if kind == "animal" then return level >= 2 end
    if kind == "small" then return level >= 3 end
    return zOn
end

-- 參與軟縫選縫：閃避名單（aLvl＝AnimalDodge）或減速名單（sLvl＝沙盒 AnimalSlowdown）任一選到的動物、永遠的玩家、
-- zOn 決定的殭屍／屍體。
function Drive.softJoins(kind, zOn, aLvl, sLvl)
    if Drive.softKindIn(kind, zOn, aLvl) then return true end
    return (kind == "animal" or kind == "small") and Drive.softKindIn(kind, false, sLvl)
end

-- gentle：只在減速名單、不在閃避名單的動物（不准照巡航速度閃，先降到 ANIMAL_GENTLE_KMH 再繞）
function Drive.softGentle(kind, aLvl, sLvl)
    return (kind == "animal" or kind == "small") and not Drive.softKindIn(kind, false, aLvl)
        and Drive.softKindIn(kind, false, sLvl)
end

-- 有沒有參與選縫的動物／玩家（ZombieDodge 關著時軟縫仍要為牠們作用）：本輪快照，或仍有效的盲區記憶
-- （同一 routeGen、在車前 SCAN_NEAR 內 Sensor 不再收、車尾還沒過、政策仍選到）——進盲區的行人不得在下一輪
-- 就被當成淨空、讓軟縫釋放回常駐線（車尾過了才回線，同殭屍的盲區保持）。
function Drive.softOthersJoin(s, sen, level)
    local sLvl = s.animalSlow or 2
    for i = 1, sen.zomN do
        local k = sen.zomKind and sen.zomKind[i]
        if k ~= nil and k ~= "zombie" and k ~= "corpse" and Drive.softJoins(k, false, level, sLvl) then return true end
    end
    local bS, bK = s.zomBlindS, s.zomBlindK
    if bS == nil or bK == nil or s.zomBlindGen ~= s.routeGen then return false end
    local tail, near0 = s.lastSNow - s.vehicleProfile.halfL, s.lastSNow + MDADSensor.SCAN_NEAR
    for j = 1, s.zomBlindN or 0 do
        local k, zs = bK[j], bS[j]
        if k ~= nil and k ~= "zombie" and k ~= "corpse" and Drive.softJoins(k, false, level, sLvl)
                and finite(zs) and zs >= tail and zs < near0 then return true end
    end
    return false
end

-- 軟縫可行帶（zombieLaneOf 用；1005 由原本的內嵌段抽出，主函式 local 槽已滿）：回 (aLo, aHi, 路面餘裕表是否可用)。
-- 可行帶＝Follower 對 laneBias 真的會照辦的帶（常駐 lane ±DELTA 只是防呆上限）：先問剖面的 laneRoom（adaptive
-- 才有），沒有就用感測路面帶 roadLo/roadHi（扣車半寬）。帶寬必須容得下一個 R（halfW＋0.65）以上的側移，否則正壓
-- 在車道上的殭屍永遠「無縫」。直接讀表再扣 keep（平常 LANE_BIAS_KEEP；貼路緣重找 0）：control／proof 線對任何
-- laneBias 都用同一個 clampLane（keep＝fstate.laneKeep），帶給到物理餘裕的提案會被靜默夾回 room−keep＝「有閃」的
-- log 但車沒動。
-- 硬物先縮小可搜尋帶，而非只否決已選中的那一側。保留與目前車身連通的區間，因此終點另一側雖然淨空，也不能
-- 穿越夾在中間的硬物。帶緣再讓出 SOFT_HARD_JITTER_M（1002t）：hardL 記的是命中那條取樣柱的 l，同一格牆隨取樣
-- 相位在一格內跳動（正式服 0.17.0 clip-02：−2.97／−2.54／−2.02），貼著帶緣選的 lane（只留 0.057m）下一輪就落進
-- 牆的擋線帶 → 硬規劃從車旁判堵、52 km/h 鎖輪。讓出的量不蓋過車身現在的位置（帶不因此收成空）。
function Drive.softBand(s, sen, resident, latNow, sFrom, sTo, keep)
    local aLo, aHi = resident - TUNE.ZOMBIE_LANE_DELTA, resident + TUNE.ZOMBIE_LANE_DELTA
    local idx = s.fstate.idx
    local roomR, roomL = s.profile.laneRoomR, s.profile.laneRoomL
    local rr, rl = 99, -99
    if type(roomR) == "table" and finite(idx) then
        local i = idx - idx % 1
        if finite(roomR[i]) then
            rr, rl = roomR[i] - keep, keep - roomL[i]
            if rr < 0 then rr = 0 end
            if rl > 0 then rl = 0 end
        end
    end
    if rr < 99 then
        if rr < aHi then aHi = rr end
        if rl > aLo then aLo = rl end
    elseif finite(sen.roadLo) and finite(sen.roadHi) then
        local halfW = s.vehicleProfile.halfW
        local lo, hi = sen.roadLo + halfW, sen.roadHi - halfW
        if lo > aLo then aLo = lo end
        if hi < aHi then aHi = hi end
    end
    local origin, jit = latNow, TUNE.SOFT_HARD_JITTER_M
    for i = 1, sen.hardN do
        local hs = sen.hardS[i]
        if hs >= sFrom and hs <= sTo then
            local r = sen.hardR and sen.hardR[i] or MDADCorridor.OBS_HALF
            if not finite(r) then r = MDADCorridor.OBS_HALF end
            local lo, hi = sen.hardL[i] - s.needHalf - r, sen.hardL[i] + s.needHalf + r
            if origin <= lo then
                local e = lo - jit
                if e < origin then e = origin end
                if e < aHi then aHi = e end
            elseif origin >= hi then
                local e = hi + jit
                if e > origin then e = origin end
                if e > aLo then aLo = e end
            else
                return 1, 0, rr < 99
            end
        end
    end
    return aLo, aHi, rr < 99
end

-- 大型動物與玩家佔位兩側另加的舒適餘裕（TUNE.SOFT_COMFORT_M）；其他種類 0
function Drive.softPad(kind)
    if kind == "animal" or kind == "player" then return TUNE.SOFT_COMFORT_M end
    return 0
end

-- 有效的離路緣保留（fstate.laneKeep 與規劃擋線基準同值）：斜切保持中＝false（不夾：保持 lane 是車位，車在路寬外
-- 起步時本來就在 laneRoom 外，夾回＝期望線落在圍籬另一側，正式服 1004g 路外 11m 起步 el 2.2 斜穿圍籬）；軟縫找不到
-- 縫、改在物理 laneRoom 內貼路緣閃（s.zombieKeep0，只在軟縫持有中）或鏈式停留＝0；會車側移＝TRAFFIC_EDGE_KEEP_M；
-- 其餘 nil（LANE_BIAS_KEEP）。
function Drive.laneKeepOf(s)
    if finite(s.holdLaneL) then return false end
    if (s.zombieKeep0 and s.zombieLane ~= nil) or s.laneChained then return 0 end
    if s.trafficLane ~= nil then return TUNE.TRAFFIC_EDGE_KEEP_M end
    return nil
end

-- 規劃擋線基準（fillHardBase／nearestLineBlocker）的 keep：保持（false）與鏈／貼路緣（0）照 laneKeepOf，
-- 會車側移的 TRAFFIC_EDGE_KEEP_M 不帶進基準（照舊 LANE_BIAS_KEEP）。
function Drive.baseKeepOf(s)
    local k = Drive.laneKeepOf(s)
    if k == false or k == 0 then return k end
    return nil
end

-- 回線途中有殭屍（1002c）：RETURN 的線從車身橫移到目標 lane，沿途不閃殭屍（RETURN 持有車道時軟縫讓位、
-- 連縱向配合帽都不算）。殭屍（不含屍體；現位到預測位的整段）落在「車身↔目標 lane」橫移帶 ±R 內、且在
-- 軟縫視窗內＝衝突：RETURN 不進場／讓位，交軟縫從車身位置接手（E2E zombie turn：路邊停車逼出長繞行，
-- 進彎前 RETURN 從 −0.1 回 3.5 的線穿過 l 1.9–2.8 的三隻，撞兩隻）。軟縫不作用的時候（選項關、點雲溢出、
-- 調頭、停留待切）照舊 RETURN——讓位給不作用的軟縫＝車直接切回常駐線。
function Drive.returnZombieConflict(s, latNow, target, speedKmh)
    local sen = s.sensor
    if not sen or not finite(sen.zomN) or sen.zomN <= 0 or not finite(latNow) or not finite(target) then return false end
    -- 選項只篩種類（Drive.softKindIn）：關「閃殭屍」不關掉對玩家／選到的動物的讓位
    if sen.zomOverflow or s.fstate.rotating or finite(s.stayLanePending) then
        return false
    end
    local vp, rs = s.vehicleProfile, s.lastSNow
    local sFrom, sTo = rs - vp.halfL, rs + MDADDynamics.softLookahead(speedKmh)
    if finite(sen.softEndS) and sen.softEndS < sTo then sTo = sen.softEndS end
    local R = vp.halfW + MDADCorridor.ZOMBIE_R + MDADCorridor.ZOMBIE_MARGIN
    local lo, hi = math.min(latNow, target) - R, math.max(latNow, target) + R
    local vms = finite(speedKmh) and speedKmh / 3.6 or 0
    if vms < 3 then vms = 3 end
    local aLvl, zOn = Drive.animalDodgeLevel(), Drive.zombieDodgeOn()
    for i = 1, sen.zomN do
        local zs, zl = sen.zomS[i], sen.zomL[i]
        -- 不參與選縫的種類（閃殭屍關掉的殭屍、兩個動物名單都沒選到的動物）不算：讓位給不閃牠的軟縫沒有意義
        if finite(zs) and finite(zl) and zs >= sFrom and zs <= sTo and sen.zomIsCorpse[i] ~= true
                and Drive.softJoins(sen.zomKind and sen.zomKind[i], zOn, aLvl, s.animalSlow or 2) then
            local zlp, vl = zl, sen.zomVl and sen.zomVl[i]
            if finite(vl) and (vl > 0.2 or vl < -0.2) then
                local t = (zs - rs - vp.halfL) / vms
                if t < 0 then t = 0 elseif t > TUNE.ZOMBIE_PREDICT_S then t = TUNE.ZOMBIE_PREDICT_S end
                zlp = zl + vl * t
            end
            if math.max(zl, zlp) > lo and math.min(zl, zlp) < hi then return true end
        end
    end
    return false
end

-- RETURN 讓位給殭屍軟縫：laneBias 停在車身、記成軟縫的停放點（zombieLaneOf 從這裡起算，不一幀拉回常駐線）
function Drive.parkForZombies(s, latSigned)
    MDADFollower.clearOffset(s.fstate)
    MDADFollower.setLaneBias(s.fstate, latSigned)
    s.zombieLaneParked = latSigned
    if s.sensor then s.sensor.scanBias = latSigned end
    s.planMode = "return-zombie"
end

-- RETURN 進場前的讓位（stepFollow 進場條件最後一關）：回線帶上有殭屍就不進，停在車身交軟縫；回 true＝已讓位。
-- 承諾繞行中照舊交 RETURN（偏離承諾線 RETURN_DODGE_DEV 以上＝真甩出，RETURN 進場會先放掉繞行）。
function Drive.returnYieldZombies(s, playerNum, latSigned, speedKmh)
    if s.dodging or not Drive.returnZombieConflict(s, latSigned, laneBiasOf(s), speedKmh) then return false end
    Drive.parkForZombies(s, latSigned)
    diagEvent(s, playerNum, "return", { phase = "yield", why = "zombie", l = latSigned, s = s.lastSNow })
    return true
end

-- 殭屍／屍體共用軟縫（TUNE.ZOMBIE_LANE_*）：回本輪 laneBias。resident＝常駐 lane
-- （sandBias＋roadBias）。只在持有權 free 時被呼叫（呼叫端已排除 dodge／RETURN／停留）；
-- 這裡再排除調頭、停留待切、選項關、點雲溢出——任一成立即釋放回 resident。
-- 先確認軟避讓點真的侵入車身／常駐線，再於硬物允許的連通車道區間內找縫。
-- 殭屍與屍體同一次選縫；硬物仍驗整個視窗，不能為閃避而穿牆／停車。
-- 動物與其他玩家（1005 soft）併入同一次選縫：zOn（ZombieDodge）只管殭屍／屍體，動物看 AnimalDodge 分級，
-- 玩家永遠參與；大型動物與玩家佔位兩側多 SOFT_COMFORT_M。
zombieLaneOf = function(s, resident, now, playerNum, speedKmh)
    local sen = s.sensor
    local cur = s.zombieLane
    s.zombieLaneCap = -1 -- 縱向配合帽每輪重算（見下）
    s.zombieWant = nil
    local zOn, aLvl = Drive.zombieDodgeOn(), Drive.animalDodgeLevel()
    local on = zOn or Drive.softOthersJoin(s, sen, aLvl)
    if not on or sen.zomOverflow or s.fstate.rotating or finite(s.stayLanePending)
            or type(MDADCorridor) ~= "table" or type(MDADCorridor.softZombieLane) ~= "function" then
        s.zombieAvoidUntilS, s.zomBlindN = nil, 0
        s.zombiePlanWhy, s.zombieWhy = nil, nil
        s.zombieKeep0 = false
        s.softGentleS = nil
        if cur ~= nil then
            s.zombieLane = nil
            diagEvent(s, playerNum, "zombie", { phase = "release", why = on and "owner" or "off", l = cur })
        end
        return resident
    end
    if cur == nil then s.zombieKeep0 = false end -- 貼路緣（keep 0）只跟著這一次軟縫持有
    -- 貼路緣重找（keep 0）期間的複驗 keep；已在 keep 0 持有中就沿用（control 正用 keep 0）
    s.softKeepTry = s.zombieKeep0 and 0 or nil
    -- 平滑起點：軟縫因讓位（dodge／RETURN／停留）而釋放時 laneBias 停在偏移處，重新接手若從
    -- resident 起算會一幀拉回＝台階（0906e harness (z3b) 抓到 0.77 → 0 瞬跳）；只在 laneBias 仍是
    -- 我們停放的值時從它起算，其他情況（換路線、解鏈交回）維持既有「首輪回常駐」契約。
    if cur == nil then
        cur = resident
        local parked = s.zombieLaneParked
        if finite(parked) then
            local lb = laneBiasOf(s)
            if (lb - parked) * (lb - parked) < 1e-6 then cur = parked end
            s.zombieLaneParked = nil
        end
    end
    local want = cur
    local rs = s.lastSNow
    local ahead = MDADDynamics.softLookahead(speedKmh)
    local sFrom, sTo = rs - s.vehicleProfile.halfL, rs + ahead
    if finite(sen.softEndS) and sen.softEndS < sTo then sTo = sen.softEndS end
    local aLo, aHi, why = 0, 0, "none"
    local latNow = finite(s.lastLatSigned) and s.lastLatSigned or cur
    local R = s.vehicleProfile.halfW + MDADCorridor.ZOMBIE_R + MDADCorridor.ZOMBIE_MARGIN
    local prefer = Drive.softPrefer(speedKmh)
    local threatS, threatL, shiftS, nextCap = nil, nil, nil, nil
    local hasAuth, hasUnauth, slowN = false, false, 0
    local slowLo, slowHi = 0, 0
    -- 預測交會位置：殭屍以 Sensor 量到的橫向速度朝車走，照「到牠那裡還要幾秒」外推（上限
    -- ZOMBIE_PREDICT_S）。現位、半途、預測位各一點進選縫（佔位＝整段移動範圍），威脅判定看整段。
    local vms = speedKmh and speedKmh / 3.6 or 0
    if vms < 3 then vms = 3 end
    local predN, pS, pL = 0, s.zomPredS, s.zomPredL
    -- 盲區記憶（0925p E2E road MAX：殭屍進到車前 2m 內 Sensor 不再收〔SCAN_NEAR〕，當輪「清空」
    -- 釋放軟縫、lane 拉回常駐線正好撞上 l 3.1 那隻）：上一輪記下即將進盲區的點，車尾過去前照樣進選縫。
    local near0 = rs + MDADSensor.SCAN_NEAR
    local blindN = s.zomBlindGen == s.routeGen and s.zomBlindN or 0
    local bS, bL, bC, bK = s.zomBlindS, s.zomBlindL, s.zomBlindC, s.zomBlindK
    local sLvl = s.animalSlow or 2 -- 沙盒 AnimalSlowdown（refreshPolicies 快取）
    s.softGentleS = nil -- 本輪最近的 gentle 威脅弧長（Drive.softGentleCap 每幀用）
    for i = 1, sen.zomN + blindN do
        local zs, zl, corpse, vl, kind
        if i <= sen.zomN then
            zs, zl, corpse = sen.zomS[i], sen.zomL[i], sen.zomIsCorpse[i] == true
            vl = sen.zomVl and sen.zomVl[i]
            kind = sen.zomKind and sen.zomKind[i]
        else
            local j = i - sen.zomN
            zs, zl, corpse, kind = bS[j], bL[j], bC[j], bK[j]
            if zs >= near0 then zs = nil end -- Sensor 又看得到：以快照為準
        end
        if finite(zs) and finite(zl) and zs >= sFrom and zs <= sTo and Drive.softJoins(kind, zOn, aLvl, sLvl) then
            local zlp = zl
            if not corpse and finite(vl) and (vl > 0.2 or vl < -0.2) then
                local t = (zs - rs - s.vehicleProfile.halfL) / vms
                if t < 0 then t = 0 elseif t > TUNE.ZOMBIE_PREDICT_S then t = TUNE.ZOMBIE_PREDICT_S end
                zlp = zl + vl * t
            end
            local zlo, zhi = math.min(zl, zlp), math.max(zl, zlp)
            -- 舒適餘裕：佔位兩端外再各放一點（點距 pad < 2R，聯集仍連續），選縫／複驗／下一群都自動看到
            local pad = Drive.softPad(kind)
            local Rk = R + pad
            for k = 0, (zlp == zl) and 0 or 2 do
                predN = predN + 1
                pS[predN], pL[predN] = zs, zl + (zlp - zl) * k * 0.5
            end
            if pad > 0 then
                pS[predN + 1], pL[predN + 1] = zs, zlo - pad
                pS[predN + 2], pL[predN + 2] = zs, zhi + pad
                predN = predN + 2
            end
            -- 誰可以用減速換側移時間：殭屍／屍體照各自政策；動物照沙盒 AnimalSlowdown；玩家永遠可以
            local allowed
            if kind == "player" then allowed = true
            elseif kind == "animal" or kind == "small" then allowed = Drive.softKindIn(kind, false, sLvl)
            else allowed = (corpse and s.corpseSlow) or (not corpse and s.zombieSlow) end
            if allowed then hasAuth = true else hasUnauth = true end
            if allowed then
                for k = 0, (zlp == zl) and 0 or 2 do
                    slowN = slowN + 1
                    s.zomSlowS[slowN], s.zomSlowL[slowN] = zs, zl + (zlp - zl) * k * 0.5
                end
                if pad > 0 then
                    s.zomSlowS[slowN + 1], s.zomSlowL[slowN + 1] = zs, zlo - pad
                    s.zomSlowS[slowN + 2], s.zomSlowL[slowN + 2] = zs, zhi + pad
                    slowN = slowN + 2
                end
            end
            local idx = MDADFollower.segIndexAt(s.profile, zs)
            local home = MDADFollower.laneBiasAt(s.profile, resident, idx, zs)
            local current = MDADFollower.laneBiasAt(s.profile, cur, idx, zs)
            -- 到區間 [zlo, zhi]（現位到預測位的整段）的距離
            local gN = latNow < zlo and zlo - latNow or (latNow > zhi and latNow - zhi or 0)
            local gC = current < zlo and zlo - current or (current > zhi and current - zhi or 0)
            -- 常駐線、目前 lane、車身三者之間整段都算（1002c）：離任一端都超過 R、卻正好在 laneBias 回程路上的
            -- 殭屍，舊制判 clear → lane 以軟縫速率掃回常駐線正好穿過牠（RETURN 讓位給軟縫後最常見：車在 −0.1、
            -- 常駐 3.5、殭屍 1.9）。gT ≤ 到三端的距離，涵蓋舊的常駐線／車身／目前 lane 判定。
            local tLo, tHi = math.min(home, current, latNow), math.max(home, current, latNow)
            local gT = zhi < tLo and tLo - zhi or (zlo > tHi and zlo - tHi or 0)
            local crossing = gN < Rk or gC < Rk
            if gT < Rk then
                if threatS == nil or zs < threatS then threatS, threatL = zs, zl end
                -- gentle 動物成為威脅（同一個啟動判定）：記最近一隻，繞過前先降速（車尾過了牠才出視窗）
                if Drive.softGentle(kind, aLvl, sLvl) and (s.softGentleS == nil or zs < s.softGentleS) then
                    s.softGentleS = zs
                end
            end
            if crossing and allowed and (shiftS == nil or zs < shiftS) then
                shiftS = zs
            end
        end
    end
    -- 下一輪的盲區記憶：舊記憶中車尾還沒過、仍在盲區的點＋本輪快照裡下一輪會進盲區的點
    -- （車前 NEAR..NEAR＋max(3m, 0.6s 行程)）。上限 16，就地壓縮、零配置。
    if bS == nil then
        bS, bL, bC, bK = {}, {}, {}, {}
        s.zomBlindS, s.zomBlindL, s.zomBlindC, s.zomBlindK = bS, bL, bC, bK
    end
    local nb = 0
    local tail = rs - s.vehicleProfile.halfL
    for j = 1, blindN do
        local zs = bS[j]
        if zs >= tail and zs < near0 and nb < 16 then
            nb = nb + 1
            bS[nb], bL[nb], bC[nb], bK[nb] = zs, bL[j], bC[j], bK[j]
        end
    end
    local reach = near0 + math.max(3, vms * 0.6)
    for i = 1, sen.zomN do
        local zs, zl = sen.zomS[i], sen.zomL[i]
        if finite(zs) and finite(zl) and zs >= near0 and zs < reach and nb < 16 then
            nb = nb + 1
            bS[nb], bL[nb], bC[nb], bK[nb] = zs, zl, sen.zomIsCorpse[i] == true, sen.zomKind and sen.zomKind[i]
        end
    end
    s.zomBlindN, s.zomBlindGen = nb, s.routeGen
    if s.zombieAvoidRouteGen == s.routeGen and finite(s.zombieAvoidUntilS)
            and finite(s.zombieAvoidS) and finite(s.zombieAvoidLane)
            and rs < s.zombieAvoidUntilS and s.zombieAvoidS < rs + MDADSensor.SCAN_NEAR then
        -- Sensor 不再收車前2m內的點；先讓車尾通過這一隻，新威脅不得把保持線切回它身上。
        want, why, threatS = s.zombieAvoidLane, "hold", s.zombieAvoidS
        -- 保持期間先看下一群：保持線會撞到的下一隻，側移時間不夠就先放慢（否則交錯的殭屍
        -- 在車尾過了第一隻才開始換邊，已經來不及；E2E zombie-sp stagger）
        if s.zombieSlow then
            local nextS, needDl = Drive.softNextConflict(s, pS, pL, predN, s.zombieAvoidS, sTo, want, R)
            if nextS ~= nil then
                -- 車尾過了這一隻（保持結束）才能換邊：可用距離從保持結束點算
                local room = nextS - math.max(rs, s.zombieAvoidUntilS) - s.vehicleProfile.halfL
                s.zombieLaneCap = Drive.softLaneCapKmh(math.max(0, room), needDl)
            end
        end
    elseif threatS ~= nil then
        local halfW = s.vehicleProfile.halfW
        -- 可行帶（路面餘裕、硬物收窄）見 Drive.softBand。兩次嘗試（1005 soft，舊 ponytail「貼路緣閃殭屍」）：
        -- ①路面餘裕扣 LANE_BIAS_KEEP；②①找不到縫時改用 keep 0 在物理 laneRoom 內重找（貼路緣閃）。②找到縫才採用
        -- 並設 s.zombieKeep0（Drive.laneKeepOf → fstate.laneKeep＝0：control／期望線／buildLaneLine／規劃擋線基準
        -- 同值）；找不到照①的結果。迴圈本體沿用原縮排。
        local w1, y1, n1, lo1, hi1, sl1, sh1
        for keepTry = 1, 2 do
        want, why, nextCap = cur, "none", nil
        local roomKnown
        aLo, aHi, roomKnown = Drive.softBand(s, sen, resident, latNow, sFrom, sTo,
            keepTry == 1 and MDADFollower.LANE_BIAS_KEEP or 0)
        if aLo > aHi then
            why = "hard"
        else
            slowLo, slowHi = aLo, aHi -- 只含道路／硬物約束，不帶全類型選縫的退側結果。
            -- 逐群規劃（0925d）：先只看最近一群（最近威脅起一個車長＋CLUSTER_M 內）。下一群從這條 lane
            -- 換得過去就照逐群閃；換不過去依序試 ①這一群貼向下一群縫的一側 ②一條 lane 同時閃過兩群
            -- ③仍貼向下一群縫（盡量閃，閃不過就撞）。不准減速時只考慮到最近威脅前側移得到的 lane：
            -- 來不及的縫＝沒縫（留在車身這一側盡量偏），也不會在貼近時改選對側而橫越牠
            -- （E2E stagger 在 35m 處從右改左，連撞兩隻）。
            local halfL2 = 2 * s.vehicleProfile.halfL
            local bLo, bHi = aLo, aHi
            local slowOk = hasAuth -- 視窗內有獲准用減速換時間的目標（殭屍／屍體照政策、動物照沙盒、玩家永遠）
            -- 從 laneBias（cur）量：它照速率移動、車身隨後跟上（落後已扣在 LEAD_S）。從車身量會在
            -- lane 已經走了一半時把原計畫判成搆不到而改選別縫（E2E crowd −2.17 → −0.75 再撞）。
            -- 0925p：減速開啟時也先在搆得到的帶內選——舊制直接用整條帶、靠減速換時間，實機
            -- slow=1 每輪在左右兩側之間跳 3m 以上（on70 65 輪 17 次），車身停在中間撞上；
            -- 搆得到的帶內沒有縫才放寬到整條帶並用縱向配合帽買時間。
            local r1 = Drive.softReach(threatS - rs - s.vehicleProfile.halfL, vms, speedKmh)
            if cur - r1 > bLo then bLo = cur - r1 end
            if cur + r1 < bHi then bHi = cur + r1 end
            local sEnd = threatS + halfL2 + TUNE.ZOMBIE_CLUSTER_M
            if sEnd > sTo then sEnd = sTo end
            local u = nil
            why = "nogap"
            -- 近威脅（到牠不足 CROSS_S 秒）不橫越牠的現位：每條帶都先只在車身這一側選（E2E p2-on：
            -- 85 km/h、距 20m 時 lane 從 2.87 翻到 0.48 穿過 l 1.2-1.4 的兩隻）；這一側沒縫才看整條帶。
            -- 帶依序＝搆得到的帶、（減速開啟時）整條帶。
            local near = (threatS - rs - s.vehicleProfile.halfL) / vms < TUNE.ZOMBIE_CROSS_S
            for pass = 1, 2 do
                if pass == 2 then
                    if u ~= nil or not slowOk then break end
                    bLo, bHi = aLo, aHi
                end
                if near and bLo <= bHi then
                    local lo, hi = bLo, bHi
                    if latNow >= threatL then lo = math.max(bLo, threatL) else hi = math.min(bHi, threatL) end
                    if lo <= hi then
                        u, why = Drive.softPick(s, pS, pL, predN, sFrom, sEnd, halfW, resident, cur, lo, hi, R, prefer)
                    end
                end
                if u == nil and bLo <= bHi then
                    u, why = Drive.softPick(s, pS, pL, predN, sFrom, sEnd, halfW, resident, cur, bLo, bHi, R, prefer)
                end
            end
            if u == nil and (bLo > aLo or bHi < aHi) then
                -- 完整閃開來不及：留在車身這一側盡量偏（擦邊比正撞好），但不越過牠換到對側
                local lo, hi = aLo, aHi
                if latNow >= threatL then lo = math.max(aLo, threatL) else hi = math.min(aHi, threatL) end
                if lo <= hi then
                    local ub = Drive.softPick(s, pS, pL, predN, sFrom, sEnd, halfW, resident, cur, lo, hi, R, prefer)
                    if ub ~= nil then want, why = ub, "gap" end
                end
            end
            if u == nil and why ~= "gap" and bLo <= bHi then
                -- 仍無縫：搆得到的帶內取離最近一群最遠的 lane（盡量擦邊不正撞）；不算「已處理」，
                -- 減速開啟時數量減速檔照套。近威脅同樣只在車身這一側取（1004a 正式服 0.18.2 kanazawa clip-08：
                -- 整條帶都搆得到時 least 從 −1.11 翻到 +1.15，橫越 0.6 秒後就到的那隻）。
                local lo, hi = bLo, bHi
                if near then
                    if latNow >= threatL then lo = math.max(bLo, threatL) else hi = math.min(bHi, threatL) end
                end
                if lo <= hi then
                    local ul = Drive.softBest(pS, pL, predN, sFrom, sEnd, lo, hi, cur)
                    if math.abs(ul - cur) > TUNE.ZOMBIE_LANE_SETTLE_M then want, why = ul, "least" end
                end
            end
            if u ~= nil then
                want = u
                for _ = 1, 3 do
                    local nextS, need = Drive.softNextConflict(s, pS, pL, predN, sEnd, sTo, want, R)
                    if nextS == nil then break end
                    local room = nextS - sEnd
                    -- 換邊要先止住上一段側移再反向：比單向側移多一段落後（SWITCH_LAG_S）
                    local r12 = Drive.softReach(room, vms, speedKmh, TUNE.ZOMBIE_SWITCH_LAG_S)
                    local sEnd2 = nextS + halfL2 + TUNE.ZOMBIE_CLUSTER_M
                    if sEnd2 > sTo then sEnd2 = sTo end
                    -- 下一群的理想 lane（含 PREFER 餘裕）換得過去才算相容；只看「縫邊碰得到」會貼著
                    -- 下一隻過（E2E stagger 擦到第三隻 d=0.04）
                    local vp = Drive.softPick(s, pS, pL, predN, nextS, sEnd2, halfW, want, want, aLo, aHi, R, prefer)
                    if vp ~= nil and math.abs(vp - want) <= r12 then break end
                    -- ① 這一群貼緣、選最靠近下一群縫的一側（prefer 0：多留的 PREFER 正是換邊來不及的那一截），
                    --    換邊量在 r12 內就採用（E2E stagger：3.85 過第一隻、再偏 0.2m 過第二排）
                    local v = Drive.softPick(s, pS, pL, predN, nextS, sEnd2, halfW, want, want, aLo, aHi, R, 0)
                    local u3 = v and Drive.softPick(s, pS, pL, predN, sFrom, sEnd, halfW, v, v,
                        math.max(bLo, v - r12), math.min(bHi, v + r12), R, 0)
                    if u3 ~= nil then want = u3; break end
                    -- ② 一條 lane 同時閃過兩群（不換邊最順；E2E crowd 一整群往同一邊閃掉）
                    local u2 = Drive.softPick(s, pS, pL, predN, sFrom, sEnd2, halfW, resident, cur, bLo, bHi, R, prefer)
                    if u2 == nil then
                        if s.zombieSlow then nextCap = Drive.softLaneCapKmh(math.max(0, room), need) end
                        -- ③ 都不行：這一群照樣貼向下一群的縫，縮短換邊量（下一群盡量閃、閃不過就撞）
                        u3 = v and Drive.softPick(s, pS, pL, predN, sFrom, sEnd, halfW, v, v, bLo, bHi, R, 0)
                        if u3 ~= nil then want = u3 end
                        break
                    end
                    want, sEnd = u2, sEnd2
                end
            end
        end
        if keepTry == 2 then
            if why == "gap" then
                s.zombieKeep0 = true
            else
                want, why, nextCap, aLo, aHi, slowLo, slowHi = w1, y1, n1, lo1, hi1, sl1, sh1
            end
        elseif why == "gap" or not roomKnown then
            break
        end
        w1, y1, n1, lo1, hi1, sl1, sh1 = want, why, nextCap, aLo, aHi, slowLo, slowHi
        s.softKeepTry = 0
        end -- for keepTry
        s.softKeepTry = s.zombieKeep0 and 0 or nil
        -- 同一個威脅不因帶緣取樣跳動換邊（Drive.softKeepSide）
        want, why = Drive.softKeepSide(s, pS, pL, predN, sFrom, sTo, want, why, threatS, threatL, aLo, aHi, R)
    else
        s.zombieAvoidUntilS = nil
        want, why = resident, "clear"
    end
    -- 不再對 want 套 laneBiasAt：可行帶已與該段路面餘裕取過交集；無殭屍時 want＝resident 必須是
    -- **未夾**的常駐值（夾限由 Follower 在使用當下逐段做）。0906e 首次實機：彎內側該段餘裕 0.09
    -- 把無殭屍的 want 夾成 0.09，lane 從 1.5 被拉到 0.1 再拉回＝無殭屍也在擺、align 減速到 12 km/h。
    -- 回到常駐線也要驗整段側移，不能因為已經閃完就穿過側邊新出現的硬物。
    -- 往遠離某個硬點的方向移不算穿越它（1002t；clip-02：lane 已在牆的擋線帶內，退出來的側移也判 hard、
    -- 只好留在帶內 → 從車旁判堵鎖輪）：to 比 from 與車身都離它更遠就略過，往其他硬點的側移照驗。
    -- 只驗側移真的會掃過的那段（1004a，Drive.softShiftEndS）：舊制看整個軟縫視窗（車速×4.5s，80 km/h
    -- 就 100m），常駐線附近遠處任何一根桿子都讓 lane 停在偏移處；正式服 clip-22 殭屍走了之後 80 km/h
    -- 停在離常駐線 2.1m 處、再停 0.15m 處 10 秒，玩家回報「繞過之後一直走路邊，要等轉彎或殭屍／屍體
    -- 讓車慢下來才回到路上」（車速降下來視窗縮短才放行）。更遠的擋線點不是這次側移會穿過的，交一般規劃。
    s.zombieHardS, s.zombieHardL = nil, nil
    if math.abs(want - cur) > TUNE.ZOMBIE_LANE_SETTLE_M then
        local sShift = Drive.softShiftEndS(s, math.abs(want - cur), speedKmh)
        for i = 1, sen.hardN do
            local hs = sen.hardS[i]
            if hs >= sFrom and hs <= sTo and hs <= sShift then
                local idx = MDADFollower.segIndexAt(s.profile, hs)
                local from = MDADFollower.laneBiasAt(s.profile, cur, idx, hs, s.fstate.laneKeep)
                local to = MDADFollower.laneBiasAt(s.profile, want, idx, hs, s.zombieKeep0 and 0 or nil)
                local hl = sen.hardL[i]
                local dt, df, dn = to - hl, from - hl, latNow - hl
                local away = dt * df > 0 and dt * dn > 0 and math.abs(dt) > math.abs(df) and math.abs(dt) > math.abs(dn)
                local lo, hi = math.min(latNow, from, to), math.max(latNow, from, to)
                local r = sen.hardR and sen.hardR[i] or MDADCorridor.OBS_HALF
                if not finite(r) then r = MDADCorridor.OBS_HALF end
                if not away and hl + s.needHalf + r > lo and hl - s.needHalf - r < hi then
                    want, why = cur, "hard"
                    s.zombieHardS, s.zombieHardL = hs, hl
                    break
                end
            end
        end
    end
    -- 閃避仍看全部軟目標，只有開啟對應減速政策的目標才允許用減速換側移時間。
    -- 關閉時能閃就閃，不能借另一類的開關替它減速；已閃開也不為殘餘追線誤差降速。
    if why == "gap" and threatS ~= nil then
        s.zombieAvoidS, s.zombieAvoidUntilS = threatS, threatS + s.vehicleProfile.halfL + 1
        s.zombieAvoidLane, s.zombieAvoidRouteGen = want, s.routeGen
    end
    if why == "gap" and shiftS ~= nil then
        local slowWant = want
        if hasUnauth then
            -- 關閉類型仍參與避讓，但不能擴大另一類獲准減速的側移量。
            -- 要量授權區間的聯集；逐點最短出口會漏掉左右交錯的多個目標。
            slowWant = MDADCorridor.softZombieLane(s.zomSlowS, s.zomSlowL, slowN,
                sFrom, sTo, s.vehicleProfile.halfW, latNow, latNow, slowLo, slowHi,
                TUNE.ZOMBIE_LANE_LAMBDA, s.zomTmpLo, s.zomTmpHi)
        end
        local dl = finite(slowWant) and math.abs(slowWant - latNow) or 0
        if dl > TUNE.ZOMBIE_LANE_SETTLE_M then
            local room = math.max(0, shiftS - rs - s.vehicleProfile.halfL)
            local cap = Drive.softLaneCapKmh(room, dl)
            s.zombieLaneCap = cap
        end
    end
    -- 下一群換邊來不及、又併不成一群：照原速到不了，縱向配合帽取較嚴者
    if nextCap ~= nil and (s.zombieLaneCap < 0 or nextCap < s.zombieLaneCap) then s.zombieLaneCap = nextCap end
    s.zombieWhy = why -- 每輪都寫（count 減速帽據此判斷軟縫是否已處理；zombiePlanWhy 只在診斷時更新）
    s.zombieWant = want -- 本輪選定的目標 lane（停等判讀 Drive.softStopScan 看「選定的線還撞不撞」）
    if s.diag and (s.zombiePlanWhy ~= why or not finite(s.zombiePlanLane)
            or math.abs(s.zombiePlanLane - want) >= 0.25) then
        s.zombiePlanWhy, s.zombiePlanLane = why, want
        -- 前四個軟避讓點「(距車 s, l, 橫向速度)」：玩家診斷紀錄要看得到殭屍在哪、往哪走（telemetry 自足）
        local pts = ""
        for i = 1, sen.zomN do
            if i > 4 then break end
            pts = pts .. string.format("(%.0f,%.1f,%.1f)", sen.zomS[i] - rs, sen.zomL[i],
                sen.zomVl and sen.zomVl[i] or 0)
        end
        -- hard＝側移會掃過的硬點（相對車位 s−rs, l）：1004a 前這裡沒記，只能從 near 猜是哪一根
        if why == "hard" and finite(s.zombieHardS) then
            pts = string.format("hard(%.0f,%.1f)", s.zombieHardS - rs, s.zombieHardL) .. pts
        end
        -- keep0＝這次縫是貼路緣重找（keep 0）找到的（fstate.laneKeep 跟著 0）
        if s.zombieKeep0 then pts = "keep0" .. pts end
        diagEvent(s, playerNum, "zombie", { phase = "plan", why = why,
            l = cur, offL = want, s = threatS, rs = rs, a = aLo, b = aHi, hn = sen.zomN, detail = pts })
    end
    if getDebug() and (sen.zomN > 0 or s.zombieLane ~= nil) then
        -- 前三個軟避讓點（殭屍一點、屍體兩端）相對車位的 (s−rs, l)；
        -- 沿用 zombie lane 日誌前綴與既有 telemetry 欄名。
        local zs = ""
        for i = 1, sen.zomN do
            if i > 3 then break end
            zs = zs .. string.format(" (%.0f,%.1f)", sen.zomS[i] - rs, sen.zomL[i])
        end
        print(string.format("%spn=%d zombie lane: n=%d win=[%.0f,%.0f] band=[%.2f,%.2f] base=%.2f cur=%.2f want=%.2f why=%s vcap=%.0f keep0=%s zom=%s",
            LOG, playerNum, sen.zomN, sFrom, sTo, aLo, aHi, resident, cur, want, why, s.zombieLaneCap,
            tostring(s.zombieKeep0 == true), zs))
    end
    -- 首次呼叫 dt＝0（不得拿 zombieLaneMs=0 算出 1 s 的步長：0906e 實機首輪 1.5→2.41 一跳 0.9m
    -- → 航向誤差 17-20° → align 減速）；之後 dt＝輪距（≈0.25-0.3 s），上限 1 s
    if s.zombieLaneMs == 0 then s.zombieLaneMs = now end
    local dt = (now - s.zombieLaneMs) / 1000
    if not finite(dt) or dt < 0 then dt = 0 elseif dt > 1 then dt = 1 end
    s.zombieLaneMs = now
    local step = (1 - 2.718281828 ^ (-dt * 1000 / TUNE.ZOMBIE_LANE_TAU_MS)) * (want - cur)
    local lim = Drive.softLaneRate(speedKmh) * dt
    if step > lim then step = lim elseif step < -lim then step = -lim end
    local nxt = cur + step
    local away = nxt - resident
    if away < 0 then away = -away end
    -- 只在目標本身回到常駐 lane 時才釋放：從左側換到右側途中剛好經過常駐 lane 不算（0925 零散殭屍
    -- E2E：0.26→4.41 途經 3.0 被當成「已回線」釋放，laneBias 一幀跳回 3.0 正對殭屍，撞 l 3.6）
    local wantAway = want - resident
    if away <= TUNE.ZOMBIE_LANE_SETTLE_M
            and wantAway <= TUNE.ZOMBIE_LANE_SETTLE_M and wantAway >= -TUNE.ZOMBIE_LANE_SETTLE_M then
        if s.zombieLane ~= nil then
            s.zombieLane = nil
            s.zombieKeep0 = false
            s.zombiePlanWhy = nil
            diagEvent(s, playerNum, "zombie", { phase = "release", why = "settled", l = nxt })
        end
        return resident
    end
    if s.zombieLane == nil then
        diagEvent(s, playerNum, "zombie", { phase = "lane", l = nxt, hn = sen.zomN })
    end
    s.zombieLane = nxt
    return nxt
end

-- 靠右行駛的常駐目標（公尺）：沙盒比例 × 右車道中心（路寬／4）。路寬取所在路段 streets.xml
-- 寬度，感測路面帶更窄時以感測為準；都沒有（v2/v3 路線、路口歧義）退 KEEP_RIGHT_FALLBACK_M。
-- 2026-09-24 E2E：舊制把沙盒值當公尺，預設 1.0 在 8m 雙向路＝車左緣離中線 0.1m、對向同樣
-- 靠右 1m 時兩車淨距 0.2m——玩家看到的「還是走在中線上」。窄路由 Follower 的 laneRoom 夾限收回。
function Drive.keepRightTarget(s)
    local ratio = s.laneRatio
    if not finite(ratio) or ratio <= 0 then return 0 end
    local w
    local p, idx = s.profile, s.fstate.idx
    if type(p) == "table" and type(p.segWidth) == "table" and finite(idx) then
        w = p.segWidth[idx - idx % 1]
    end
    local sen = s.sensor
    if sen and finite(sen.roadLo) and finite(sen.roadHi) then
        local sw = sen.roadHi - sen.roadLo
        if sw > 0 and (not finite(w) or sw < w) then w = sw end
    end
    if not finite(w) or w <= 0 then return Drive.keepRightShy(s, ratio * TUNE.KEEP_RIGHT_FALLBACK_M) end
    return Drive.keepRightShy(s, ratio * w * 0.25)
end

-- 靠右目標留路邊距（常數註解見 TUNE.KEEP_RIGHT_CLEAR_M）。實際行駛線＝靠右＋路面對中 roadBias，比較用它；
-- 硬物以形狀世界座標投影回所在路線段（hardS 只拿來找段）。每輪完成掃描一次（冷路徑）。
-- 以「目前」的靠右值（s.sandBias，EMA 還沒走到 target）判：已經壓進目前車身帶的硬物是繞行的事，這一輪不收
-- （同一台停車的遠側輪廓點會被誤當路邊物，打亂停留／回線的基準）；在目前車身右緣外、但往 target 移過去會
-- 靠到 CLEAR 以內的，都把 target 往左收——E2E 0929j：路寬 14 讓靠右一路往 3.5 走，路邊巨石在目前車身外，
-- 等常駐線走過去才變成擋線點，53 km/h 在縫口前 3m 才承諾繞行。
-- 車身位置用「這個弧長實際落點」：先夾 BIAS_MAX（常駐偏置上限），再經 laneBiasAt（窄處／彎內側被 laneRoom 夾）。
-- 0929k E2E W 段靠右值 3.75、實際被 BIAS_MAX 夾到 3.0，用裸值判車身帶會把右緣外 0.2m 的路邊樹當成「壓進車身」
-- 而不收，整排擦著過。
function Drive.keepRightShy(s, target)
    local sen, prof, vp = s.sensor, s.profile, s.vehicleProfile
    if not finite(target) or target <= 0 or type(sen) ~= "table" or not sen.ready
            or type(prof) ~= "table" or prof.ready ~= true or type(vp) ~= "table"
            or not finite(vp.halfW) or not finite(s.lastSNow) then return target end
    local rb = finite(s.roadBias) and s.roadBias or 0
    local cur = finite(s.sandBias) and s.sandBias or target
    local bm = TUNE.BIAS_MAX
    local rawNow, rawReach = cur + rb, (target > cur and target or cur) + rb
    if rawNow > bm then rawNow = bm elseif rawNow < -bm then rawNow = -bm end
    if rawReach > bm then rawReach = bm elseif rawReach < -bm then rawReach = -bm end
    local s0, s1 = s.lastSNow - (vp.halfL or 0), s.lastSNow + TUNE.KEEP_RIGHT_LOOK_M
    local best = target
    for i = 1, sen.hardN do
        local hs = sen.hardS[i]
        if finite(hs) and hs >= s0 and hs <= s1 then
            local j = MDADFollower.segIndexAt(prof, hs)
            local h, ds = prof.segH[j], hs - prof.s[j]
            if finite(h) and finite(ds) then
                local sh, ch = sin(h), cos(h)
                local bh = sen.hardB and sen.hardB[i] or 0
                local rad = (type(bh) == "number" and bh > 0) and bh * (math.abs(sh) + math.abs(ch))
                    or (sen.hardR[i] or 0) -- 方塊取它在路線橫向的半寬
                local l = (sen.hardX[i] - prof.x[j] - ds * ch) * -sh + (sen.hardY[i] - prof.y[j] - ds * sh) * ch
                local face = l - rad
                local edgeNow = MDADFollower.laneBiasAt(prof, rawNow, j, hs) + vp.halfW
                if face < edgeNow and l + rad > edgeNow - 2 * vp.halfW then return target end
                if face >= edgeNow and face < MDADFollower.laneBiasAt(prof, rawReach, j, hs)
                        + vp.halfW + TUNE.KEEP_RIGHT_CLEAR_M then
                    local want = face - TUNE.KEEP_RIGHT_CLEAR_M - vp.halfW - rb
                    if want < best then best = want end
                end
            end
        end
    end
    if best < 0 then best = 0 end
    return best
end

-- 承諾線（繞行 smoothstep／RETURN 目標）在弧長 sq 的 lane：會車判斷在 lane 被持有時用它
-- 取代常駐線（expectedLaneOf 的同一條曲線，只是查任意 s）。
function Drive.plannedLaneAt(s, sq)
    local p, fs = s.profile, s.fstate
    local lane = MDADFollower.laneBiasAt(p, laneBiasOf(s), MDADFollower.segIndexAt(p, sq), sq)
    local offL, oa, ob, oc, od = fs.offL, fs.offA, fs.offB, fs.offC, fs.offD
    if s.dodging and finite(offL) and finite(oa) and finite(od) and sq > oa and sq < od then
        local t = 1
        if sq < ob and ob > oa then t = (sq - oa) / (ob - oa)
        elseif sq > oc and od > oc then t = (od - sq) / (od - oc) end
        t = t * t * (3 - 2 * t)
        lane = lane + (offL - lane) * t
    end
    return lane
end

-- 繞行承諾前的會車檢查：對向車會在我方佔用繞行 lane（弧長 a..d）的期間出現在那段、且車身
-- 壓到繞行 lane ＝先別切出去（停在 a 前讓它過，下一輪再問）。真人開車繞停在路邊的車時也是
-- 先讓對向車過。時間各留 1 秒；我方以不低於 2 m/s 估佔用時間（慢速時佔得久＝更保守）。
-- 首次看到、還沒有速度的行進車若壓在繞行 lane 上（a 之後）也先等一輪——承諾後就只能讓車停在半路。
-- 對向車（與還沒有速度、可能是對向的車）的橫向取「現在的位置」與「它自己的常駐線（我方常駐線對路面
-- 中線的鏡像）」的聯集（1002s）：它正偏離自己的車道（繞它那側的東西）時，之後會回車道（E2E meet park
-- 1002r：對向車繞屍體偏到路邊 3.5m，我方判它不壓繞行 lane 就借道，1 秒後它回車道、正面相撞）。只用在
-- 承諾前：承諾後對向車往路邊讓是在讓我方，那時再假設它會回來就變成雙方互讓停死。
function Drive.trafficBlocksDodge(s, a, d, offL, speedKmh)
    local sen = s.sensor
    local n = sen.trfN or 0
    if n <= 0 or not finite(a) or not finite(d) or not finite(offL) then return false end
    local rs, halfW = s.lastSNow, s.vehicleProfile.halfW
    local v = (finite(speedKmh) and speedKmh > 0) and speedKmh / 3.6 or 0
    if v < 2 then v = 2 end
    local tA = (a - rs) / v
    if tA < 0 then tA = 0 end
    local tD = (d - rs) / v
    local M = TUNE.TRAFFIC_MARGIN_M
    local now = getTimestampMs()
    local home = (finite(s.roadBias) and s.roadBias or 0) - (finite(s.sandBias) and s.sandBias or 0)
    for i = 1, n do
        local vs = sen.trfVs[i]
        local l0, l1 = sen.trfL0[i], sen.trfL1[i]
        local known = finite(vs)
        if not known or vs < -TUNE.TRAFFIC_ONCOMING_MPS then
            local hw = (l1 - l0) * 0.5
            if home - hw < l0 then l0 = home - hw end
            if home + hw > l1 then l1 = home + hw end
        end
        if l0 < offL + halfW + M and l1 > offL - halfW - M then
            if not known then
                if sen.trfS1[i] >= a then return true end
            elseif vs < -TUNE.TRAFFIC_ONCOMING_MPS then
                local age = (now - (sen.trfT[i] or now)) / 1000
                if age < 0 then age = 0 elseif age > 1 then age = 1 end
                local s0, s1 = sen.trfS0[i] + vs * age, sen.trfS1[i] + vs * age
                if s1 >= a then
                    local t1 = s0 > d and (s0 - d) / -vs or 0
                    local t2 = (s1 - a) / -vs
                    if t1 < tD + 1 and t2 > tA - 1 then return true end
                end
            end
        end
    end
    return false
end

-- 起步換算（剖面還在分幀建表、沒有 fstate.idx）：沙盒比例 1.0 對應的公尺數＝路線第一段路寬／4。
function Drive.keepRightStartM(route)
    local w = type(route) == "table" and type(route.segWidth) == "table" and route.segWidth[1] or nil
    if not finite(w) or w <= 0 then return TUNE.KEEP_RIGHT_FALLBACK_M end
    return w * 0.25
end

-- 伺服器轉送的遠方行進車（server/MDAD_TrafficRelay.lua，MDAD.CMD_TRAFFIC）：id → 最近一次的狀態。
-- 收到就覆寫（表重用、不每次配置）；超過 RELAY_TTL_MS 沒更新的不用，10 秒沒更新的移除。
Drive.relay = {}
Drive.relayPruneMs = 0

function Drive.relayReceive(args)
    if type(args) ~= "table" then return end
    local n = args.n
    if not finite(n) or n < 1 then return end
    local F = MDAD.RELAY_FIELDS
    local now = getTimestampMs()
    local relay = Drive.relay
    for k = 0, n - 1 do
        local b = k * F
        local id = args[b + 1]
        if finite(id) then
            local e = relay[id]
            if e == nil then
                e = {}
                relay[id] = e
            end
            e.x, e.y, e.vx, e.vy = args[b + 2], args[b + 3], args[b + 4], args[b + 5]
            e.fx, e.fy, e.hw, e.hl = args[b + 6], args[b + 7], args[b + 8], args[b + 9]
            e.t = now
        end
    end
    if now < Drive.relayPruneMs then return end
    Drive.relayPruneMs = now + 10000
    local stale = nil
    for id, e in pairs(relay) do
        if now - e.t > 10000 then
            stale = stale or {}
            stale[#stale + 1] = id
        end
    end
    if stale then
        for k = 1, #stale do relay[stale[k]] = nil end
    end
end

if Events and Events.OnServerCommand then
    Events.OnServerCommand.Add(function(module, command, args)
        if module == MDAD.MOD_ID and command == MDAD.CMD_TRAFFIC then Drive.relayReceive(args) end
    end)
end

-- 伺服器轉送的遠方行進車接到本輪 trf 快照尾端（Sensor 已發布；下一次發布整組換掉，不留殘）。
-- 原生已看到的同一台（trfId）不重複；本機已同步到的車改用本機即時位置（速度／朝向照用轉送的）。轉送表是整個
-- 客戶端共用的：分割畫面時另一位本機玩家收到的轉送會帶到自己這台與自己的掛車，要排除。
-- 投影到路線 [rs－RELAY_BACK_M, rs＋RELAY_AHEAD_M] 的最近段，離中心線超過 RELAY_LAT_MAX_M 的不在這條路上；
-- trfT＝收到時刻－RELAY_LAG_MS（trafficScan 依年齡外推）。sen.trfNativeN 記原生筆數（事件分來源）。
-- 每輪掃描完成呼叫一次（冷路徑）；轉送最多 8 台、每台走一次路段。
function Drive.mergeRelay(s, now)
    local sen, p = s.sensor, s.profile
    sen.trfNativeN = sen.trfN or 0
    s.relayN = 0
    if type(p) ~= "table" or not p.ready or not finite(s.lastSNow) then return end
    local any = false
    for _ in pairs(Drive.relay) do
        any = true
        break
    end
    if not any then return end -- SP／沒收到轉送：一張空表，零成本
    local own = s.vehicle and s.vehicle:getId()
    local ownTrailer = s.tow and s.tow.trailer and s.tow.trailer:getId()
    local px, py, ps = p.x, p.y, p.s
    local i0 = MDADFollower.segIndexAt(p, s.lastSNow - TUNE.RELAY_BACK_M)
    local i1 = MDADFollower.segIndexAt(p, s.lastSNow + TUNE.RELAY_AHEAD_M)
    local latMax2 = TUNE.RELAY_LAT_MAX_M * TUNE.RELAY_LAT_MAX_M
    local native = type(getVehicleById) == "function"
    for id, e in pairs(Drive.relay) do
        local dup = id == own or id == ownTrailer or now - e.t > TUNE.RELAY_TTL_MS
            or not (finite(e.x) and finite(e.y) and finite(e.vx) and finite(e.vy) and finite(e.fx)
                and finite(e.fy) and finite(e.hw) and finite(e.hl))
        for k = 1, sen.trfNativeN do
            if dup then break end
            dup = sen.trfId[k] == id
        end
        if not dup then
            local x, y, t = e.x, e.y, e.t - TUNE.RELAY_LAG_MS
            local v = native and getVehicleById(id) or nil
            if v ~= nil then x, y, t = v:getX(), v:getY(), now end
            local best, bi, bu = nil, nil, nil
            for i = i0, i1 do
                local ax, ay = px[i], py[i]
                local ex, ey = px[i + 1] - ax, py[i + 1] - ay
                local l2 = ex * ex + ey * ey
                if l2 > 1e-9 then
                    local u = ((x - ax) * ex + (y - ay) * ey) / l2
                    if u < 0 then u = 0 elseif u > 1 then u = 1 end
                    local dx, dy = x - ax - u * ex, y - ay - u * ey
                    local d2 = dx * dx + dy * dy
                    if best == nil or d2 < best then best, bi, bu = d2, i, u end
                end
            end
            if best ~= nil and best <= latMax2 then
                local ax, ay = px[bi], py[bi]
                local ex, ey = px[bi + 1] - ax, py[bi + 1] - ay
                local len = sqrt(ex * ex + ey * ey)
                local tx, ty = ex / len, ey / len
                local qx, qy = ax + bu * ex, ay + bu * ey
                local sq = ps[bi] + bu * len
                local s0, s1, l0, l1
                for k = 1, 4 do
                    local sa = (k == 1 or k == 4) and e.hl or -e.hl
                    local sb = k <= 2 and e.hw or -e.hw
                    local dx = x + sa * e.fx - sb * e.fy - qx
                    local dy = y + sa * e.fy + sb * e.fx - qy
                    local cs, cl = sq + dx * tx + dy * ty, dy * tx - dx * ty
                    if s0 == nil or cs < s0 then s0 = cs end
                    if s1 == nil or cs > s1 then s1 = cs end
                    if l0 == nil or cl < l0 then l0 = cl end
                    if l1 == nil or cl > l1 then l1 = cl end
                end
                local k = sen.trfN + 1
                sen.trfN = k
                sen.trfS0[k], sen.trfS1[k], sen.trfL0[k], sen.trfL1[k] = s0, s1, l0, l1
                sen.trfVs[k], sen.trfVl[k] = e.vx * tx + e.vy * ty, e.vy * tx - e.vx * ty
                sen.trfT[k], sen.trfId[k] = t, id
                s.relayN = s.relayN + 1
            end
        end
    end
end

-- 會車／跟車判讀（每輪掃描完成呼叫一次；結果給 trafficLaneOf 與每幀的 trafficCap）。
-- 對向：對方車身會壓到**常駐線**（不是目前已經閃開的線——否則閃開後判定消失、在交會前
-- 就回線）才算衝突；預設靠右錯開，對方整台在我右側時才從左邊過。可用帶＝路面餘裕（同
-- 殭屍軟縫扣 LANE_BIAS_KEEP，control 對任何 laneBias 都用這個夾限）再被視窗內硬物縮小。
-- 同向／橫越／速度未知：擋在目前行駛線上的最近一台＝前車（跟車）。
function Drive.trafficScan(s, now, speedKmh)
    local sen, p, vp = s.sensor, s.profile, s.vehicleProfile
    s.trfStamp = now
    s.trfLeadGap, s.trfLeadV = nil, nil
    s.trfOnGap, s.trfOnV, s.trfOnWant, s.trfOnYield, s.trfOnMargin = nil, nil, nil, false, nil
    local n = sen.trfN or 0
    if n <= 0 or type(p) ~= "table" or not p.ready then return end
    local rs = s.lastSNow
    local halfW, halfL = vp.halfW, vp.halfL
    local vSelf = (finite(speedKmh) and speedKmh > 0) and speedKmh / 3.6 or 0
    local resident = finite(s.residentBias) and s.residentBias or (s.sandBias or 0)
    local current = laneBiasOf(s)
    local M = TUNE.TRAFFIC_MARGIN_M
    -- 繞行／RETURN／停留持有 lane 時不能再為對向車側移：衝突以承諾線在對方位置的 lane 判，
    -- 錯不開就只能讓車（trafficLaneOf 此時不會被呼叫）
    local owned = s.dodging or s.returnActive or s.laneChained
    local need, side, onGap, onV, onEnd, onHome, onQ, onIdx = nil, 1, nil, nil, nil, nil, nil, nil
    for i = 1, n do
        local s0, s1, l0, l1 = sen.trfS0[i], sen.trfS1[i], sen.trfL0[i], sen.trfL1[i]
        local vs = sen.trfVs[i]
        if not finite(vs) then vs = nil end
        local age = (now - (sen.trfT[i] or now)) / 1000
        if age < 0 then age = 0 elseif age > 1 then age = 1 end
        if vs then s0, s1 = s0 + vs * age, s1 + vs * age end
        if s1 >= rs - halfL then
            local at = s0 > rs and s0 or rs
            local idx = MDADFollower.segIndexAt(p, at)
            local gap = s0 - rs - halfL
            if vs and vs < -TUNE.TRAFFIC_ONCOMING_MPS then
                local closing = vSelf - vs
                -- 衝突看「交會前」我方會在的 lane，不是對方現在的位置：承諾線在對方現位處可能已回線、
                -- 交會時卻正好在全偏移段（E2E park400：對方 48m 外判不衝突，交會在停車旁才撞上）。
                -- 我方只會減速（交會點只會更早）→ 取 [rs, 交會點] 內承諾線最靠 offL 的 lane。
                local meet = rs + (gap > 0 and gap or 0) * vSelf / closing
                if meet > at then meet = at end
                local q, fs = meet, s.fstate
                if s.dodging and finite(fs.offB) and finite(fs.offC) then
                    if rs > fs.offC then q = rs
                    elseif meet > fs.offB then q = rs > fs.offB and rs or fs.offB end
                end
                local home = owned and Drive.plannedLaneAt(s, q)
                    or MDADFollower.laneBiasAt(p, resident, MDADFollower.segIndexAt(p, meet), meet)
                if l0 < home + halfW + M and l1 > home - halfW - M
                        and gap < math.max(30, closing * TUNE.TRAFFIC_HORIZON_S) then
                    -- 預設靠右錯開；對方整台在我常駐線右側才從左邊過（車心比較在 home≈0 時每輪亂翻）
                    local sd = l0 > home and -1 or 1
                    if need == nil or gap < onGap then
                        if sd ~= side then need = nil end -- 最近那台決定錯車方向，另一側的需求作廢
                        side = sd
                    end
                    if sd == side then
                        local u = sd > 0 and (l1 + M + halfW) or (l0 - M - halfW)
                        if need == nil or (sd > 0 and u > need) or (sd < 0 and u < need) then need = u end
                    end
                    if onGap == nil or gap < onGap then
                        onGap, onV, onHome, onQ, onIdx = gap, -vs, home, q, i
                    end
                    local e = gap + (s1 - s0) + 2 * halfL + 1
                    if onEnd == nil or e > onEnd then onEnd = e end
                end
            else
                -- 前車：承諾線持有 lane 時看承諾線（繞行線上的同向慢車也要跟）；橫向速度外推到我方
                -- 抵達它那一刻（路口橫越車還沒壓進行駛線就先算前車）
                local lane = owned and Drive.plannedLaneAt(s, at) or MDADFollower.laneBiasAt(p, current, idx, at)
                local fl = TUNE.FOLLOW_LATERAL_M
                local vl = sen.trfVl[i]
                if finite(vl) and gap > 0 then
                    local t = gap / (vSelf > 1 and vSelf or 1)
                    if t > TUNE.TRAFFIC_HORIZON_S then t = TUNE.TRAFFIC_HORIZON_S end
                    if vl < 0 then l0 = l0 + vl * t else l1 = l1 + vl * t end
                end
                if s0 > rs and l0 < lane + halfW + fl and l1 > lane - halfW - fl
                        and (s.trfLeadGap == nil or gap < s.trfLeadGap) then
                    s.trfLeadGap = gap
                    s.trfLeadV = (vs and vs > 0) and vs or 0
                end
            end
        end
    end
    if need == nil then
        s.trafficPlan = nil
        -- 提示去重保留到對方預計交會完（trafficHoldUntil）：判定單輪閃掉不算「新的一次會車」
        if now > (s.trafficHoldUntil or 0) then s.trafficNoticeKey = nil end
        if getDebug() and s.trfLeadGap ~= nil then
            print(string.format("%spn=%d traffic lead gap=%.1f v=%.1f n=%d",
                LOG, s.playerNum or 0, s.trfLeadGap, (s.trfLeadV or 0) * 3.6, n))
        end
        return
    end
    -- 可用帶：路面餘裕（扣 keep）→ 視窗內硬物（以目前車位為原點，只收閃避方向那一側）
    local hi, lo = 99, -99
    local roomR, roomL, idx = p.laneRoomR, p.laneRoomL, s.fstate.idx
    if type(roomR) == "table" and finite(idx) and finite(roomR[idx - idx % 1]) then
        -- 交會範圍（rs..rs+onEnd）內最窄那段：control 到會車段會照那段夾 lane
        local i0, i1 = idx - idx % 1, MDADFollower.segIndexAt(p, rs + onEnd)
        local rR, rL = roomR[i0], roomL[i0]
        for i = i0 + 1, i1 - i1 % 1 do
            if finite(roomR[i]) and roomR[i] < rR then rR = roomR[i] end
            if finite(roomL[i]) and roomL[i] < rL then rL = roomL[i] end
        end
        hi = rR - TUNE.TRAFFIC_EDGE_KEEP_M -- 會車可貼到路緣（control 同步用 fstate.laneKeep，見 onPlayerUpdate）
        lo = TUNE.TRAFFIC_EDGE_KEEP_M - rL
        if hi < 0 then hi = 0 end
        if lo > 0 then lo = 0 end
    elseif finite(sen.roadLo) and finite(sen.roadHi) then
        lo, hi = sen.roadLo + halfW, sen.roadHi - halfW
    end
    local latNow = finite(s.lastLatSigned) and s.lastLatSigned or current
    local sFrom, sTo = rs - halfL, rs + onEnd
    for i = 1, sen.hardN do
        local hs = sen.hardS[i]
        if hs >= sFrom and hs <= sTo then
            local r = sen.hardR and sen.hardR[i] or MDADCorridor.OBS_HALF
            if not finite(r) then r = MDADCorridor.OBS_HALF end
            local hl = sen.hardL[i]
            if side > 0 and hl - s.needHalf - r >= latNow then
                if hl - s.needHalf - r < hi then hi = hl - s.needHalf - r end
            elseif side < 0 and hl + s.needHalf + r <= latNow then
                if hl + s.needHalf + r > lo then lo = hl + s.needHalf + r end
            end
        end
    end
    -- reach＝可用帶內能到的最遠錯車位置（淨距以它算）；want＝lane 目標，不比常駐線更往回收。
    -- lane 被承諾線持有＝不能側移：reach 就是承諾線在對方位置的 lane。
    if owned then
        if side > 0 then hi = onHome else lo = onHome end
    end
    local reach, want
    if side > 0 then
        reach = need < hi and need or hi
        want = reach > resident and reach or resident
    else
        reach = need > lo and need or lo
        want = reach < resident and reach or resident
    end
    local short = side > 0 and (need - reach) or (reach - need)
    if short < 0 then short = 0 end
    s.trfOnShift = not owned
    s.trfOnGap, s.trfOnV = onGap, onV
    s.trfOnWant, s.trfOnSide, s.trfOnMargin = want, side, M - short
    s.trfOnYield = M - short < TUNE.TRAFFIC_MARGIN_MIN_M
    -- 繞行已承諾、還沒到障礙（offB 之前，仍在切出去的過渡段）卻出現錯不開的對向車：停在半路＝
    -- 停在對方車道上（E2E park 變體實測：長過渡段提早 50m 開始往左飄，對向車出現時已壓線 1m，
    -- 停等＝被迎面撞上）。放棄這次繞行、回常駐線重判；replan 的 trafficBlocksDodge 會讓車停在
    -- 障礙前等對向車過去再繞。
    -- 交會點在繞行起點 a 之前＝衝突跟繞行無關（對方壓的是常駐線）：照常讓車，不放棄繞行，
    -- 否則同輪 replan 會把同一條線重新承諾、下一輪再放棄，每輪震盪。
    -- 放棄只在「鬆油門就停得住在讓車停點前」時做——停點與 replan 的 defer why=traffic 同一條式子
    -- （Drive.trafficStopCap：b 前留爬行側移跑道、反應 0.5s、safeCoast）；來不及就得硬煞，一秒鎖輪
    -- 會沿車頭方向滑進對方車道（E2E park400）。來不及＝late：照承諾線做完、不為這台讓車停在半路
    -- （速度照繞行帽；對方若是自駕會讓車）。late 綁在這次承諾上（trafficLate，releaseDodge 才清）：
    -- 單輪判讀閃掉不得清掉它，否則減速後停止距離縮回可放棄範圍又放棄＝半路停等被撞（fix9-park400）。
    local fs = s.fstate
    if s.trfOnYield and s.dodging and not s.dodgeStay and not s.returnActive and not s.laneChained
            and finite(fs.offA) and onQ >= fs.offA then
        -- 或車身還沒越過路面中線（剛開始切出、繞行帽常把過渡段壓在 10 km/h：這時做完＝在對向車道
        -- 爬好幾秒，E2E k-suv-park／k-f350-park）：在自己半邊停下，就算硬煞也不會滑進對向車道。
        local lat = finite(s.lastLatSigned) and s.lastLatSigned or laneBiasOf(s)
        if not s.trafficLate and finite(fs.offB) and finite(fs.offL)
                and (lat - vp.halfW >= (s.roadBias or 0)
                    or Drive.trafficStopCap(s, fs.offB, fs.offL) >= speedKmh - TUNE.DODGE_SPEED_TOL) then
            diagEvent(s, s.playerNum, "traffic", { phase = "abort", why = "dodge", d = onGap,
                speed = onV * 3.6, offL = fs.offL, b = fs.offB, rs = rs })
            releaseDodge(s)
            MDADFollower.clearOffset(fs) -- 車還在過渡段：目標線直接回常駐線，追線把車拉回右側
            return Drive.trafficScan(s, now, speedKmh)
        end
        if not s.trafficLate then
            s.trafficLate = true
            diagEvent(s, s.playerNum, "traffic", { phase = "commit", why = "late", d = onGap,
                speed = onV * 3.6, offL = fs.offL, b = fs.offB, rs = rs })
        end
        s.trfOnGap, s.trfOnWant, s.trfOnYield = nil, nil, false
        return
    end
    local closing = vSelf + onV
    if closing < 1 then closing = 1 end
    s.trafficHoldUntil = now + 1000 * onEnd / closing + 400
    -- 決策改變才記（對方方向／是否讓車／目標 lane 移動 ≥0.25m）；console 同步一行（telemetry 自足原則）
    local why = s.trfOnYield and "yield" or "pass"
    if s.trafficPlan ~= why or not finite(s.trafficPlanL) or math.abs(s.trafficPlanL - want) >= 0.25 then
        s.trafficPlan, s.trafficPlanL = why, want
        diagEvent(s, s.playerNum, "traffic", { phase = "plan", why = why, d = onGap,
            speed = onV * 3.6, offL = want, l = need, m = M - short, a = lo, b = hi, rs = rs,
            kind = onIdx > (sen.trfNativeN or n) and "relay" or "near" })
    end
    -- 讓玩家知道為什麼停下或偏離車道：讓車／靠邊錯車各提示一次（同一台對向車過去前不重複）
    if s.trfOnYield then
        Drive.trafficNotice(s, KEY_TRAFFIC.yield)
    elseif math.abs(want - resident) > TUNE.TRAFFIC_SHIFT_DONE_M then
        Drive.trafficNotice(s, KEY_TRAFFIC.pass)
    end
    if getDebug() then
        print(string.format("%spn=%d traffic on gap=%.1f v=%.1f need=%.2f want=%.2f band=[%.2f,%.2f] m=%.2f %s lead=%s",
            LOG, s.playerNum or 0, onGap, onV * 3.6, need, want, lo, hi, M - short, why,
            s.trfLeadGap and string.format("%.1f", s.trfLeadGap) or "-"))
    end
end

-- 讓車停點的接近帽：停在 b 前留爬行側移跑道（b − √(6·dl／κ_crawl)，同 shapeProfile 的陡坡量）、
-- 反應 0.5s、減速度用鬆油門（safeCoast）。放棄判斷與 defer why=traffic 共用這一條，兩邊不得分岔。
function Drive.trafficStopCap(s, b, offL)
    local vp = s.vehicleProfile
    local k = MDADDynamics.steeringKappa(
        vp.wheelbase, vp.delta0Safe, vp.deltaVSafe, vp.maxSpeed, MDADDynamics.DODGE_SQUEEZE_CAP)
    local dl = math.abs(offL - laneBiasOf(s))
    local run = (k > 0 and dl > 0) and math.sqrt(6 * dl / k) or 0
    local coast = finite(s.safeCoast) and s.safeCoast > 0.5 and s.safeCoast or 0.5
    return MDADDynamics.approachCapKmh(b - run - s.lastSNow - vp.halfL, 0, 0.5, coast)
end

-- 借對向車道判定（shapeProfile 的短設計，TUNE.ONCOMING_DESIGN_KMH）：只在 MP——單機沒有別的駕駛、不會有對向
-- 來車；且繞行線讓對向車道剩下的寬度不夠一台車錯車（半路寬 − 壓過中線量 < ONCOMING_PASS_M）。路寬未知時
-- 壓過中線 ONCOMING_INTRUDE_M 即算。0928d E2E rc2：窄路上 0.25–0.75m 的小側偏也被當借道，設計 25 → 過渡段
-- 只剩兩個車長、清距帽 9–18，86m 外就規劃好的繞行也讓車從 34–60 掉到 10–18。
function Drive.borrowsOncoming(s, offL)
    if not isClient() or not finite(s.laneRatio) or s.laneRatio <= 0 then return false end
    local intrude = (s.roadBias or 0) - (offL - s.vehicleProfile.halfW)
    if not finite(intrude) or intrude <= 0 then return false end
    local w = s.currentSegWidth
    if finite(w) and w > 0 then return w * 0.5 - intrude < TUNE.ONCOMING_PASS_M end
    return intrude > TUNE.ONCOMING_INTRUDE_M
end

-- 對正延後的接近帽（0928b E2E rc1 0008：126° 折點一出彎，貼縫繞行因車頭還斜 >20° 延後，
-- 舊制延後只設 mode=clear、沒有接近帽，車以 12-16 km/h 直接開到縫口的桿）：以完整煞車能力
-- 在縫口 b 前降到承諾帽（同 speed 延後）；出口速不低於 MIN_EXEC——停下來 pure pursuit 就擺不正
--（帽 <MIN_EXEC 會歸 WAIT），延後永遠解不開。超過硬煞門檻才鎖輪。
function Drive.alignDeferCap(s, b, capK)
    local decel = s.safeBrake
    if not finite(decel) or decel <= 0 then decel = 2 end
    if not finite(capK) or capK < MDADDynamics.MIN_EXEC_KMH then capK = MDADDynamics.MIN_EXEC_KMH end
    return MDADDynamics.approachCapKmh(b - s.lastSNow - s.vehicleProfile.halfL, capK, 0.5, decel)
end

-- 會車提示：同一次會車（trafficNoticeKey 在對方交會完後清空）只往上升級一次——錯車→讓車會再提示，
-- 讓車／錯車判定逐輪來回時不重複跳
function Drive.trafficNotice(s, key)
    local cur = s.trafficNoticeKey
    if cur == key or (cur == KEY_TRAFFIC.yield and key == KEY_TRAFFIC.pass) then return end
    s.trafficNoticeKey = key
    local playerObj = getSpecificPlayer(s.playerNum)
    if playerObj then haloGood(playerObj, key) end
end

-- HUD「卡頓降速」tooltip 的數值：平均幀時、實際／設定感知距離、門檻幀時；無 session 回 nil。
function Drive.lowFpsInfo(playerNum)
    local s = sessions[playerNum]
    local sen = s and type(s.sensor) == "table" and s.sensor or nil
    if not sen or not finite(sen.frameEwmaMs) or sen.frameEwmaMs <= 0 then return nil end
    return sen.frameEwmaMs, sen.effectiveAheadM or 0, sen.requestedAheadM or 0, TUNE.LOWFPS_FRAME_MS
end

-- 低幀率降速提示：可視上限正在壓速、平均幀時超過 LOWFPS_FRAME_MS，而且視距真的是被幀率截短
-- （可負擔 < 請求；不是地圖未載入或路線到頭）。遲滯 ON 2s／OFF 3s 才切 s.lowFps（HUD 狀態「卡頓降速」）；
-- 同一趟累計 NOTICE_MS 後跳一次右上角通知。切換各記一筆 lowfps 事件。
function Drive.updateLowFps(s, now, bound)
    local sen = type(s.sensor) == "table" and s.sensor or nil -- sensor 缺席時 session 存 false
    -- 只算正常行駛（停等／脫困時可視帽綁住與幀率無關）
    local raw = bound and s.mode == "follow" and not s.blocked and not s.currentBlocked
        and sen ~= nil and finite(sen.affordableAheadM) and finite(sen.requestedAheadM)
        and finite(sen.effectiveAheadM) and finite(sen.frameEwmaMs)
        and sen.frameEwmaMs >= TUNE.LOWFPS_FRAME_MS
        and sen.affordableAheadM < sen.requestedAheadM - 1
        and sen.effectiveAheadM >= sen.affordableAheadM - 1
    raw = raw == true
    if raw ~= s.lowFpsRaw then s.lowFpsRaw, s.lowFpsSince = raw, now end
    local tick = s.lowFpsTick or now
    s.lowFpsTick = now
    if (s.lowFps == true) ~= raw
            and now - (s.lowFpsSince or now) >= (raw and TUNE.LOWFPS_ON_MS or TUNE.LOWFPS_OFF_MS) then
        s.lowFps = raw
        diagEvent(s, s.playerNum, "lowfps", { phase = raw and "on" or "off",
            d = sen and sen.effectiveAheadM, s = s.lastSNow })
    end
    if not s.lowFps then return end
    s.lowFpsMs = (s.lowFpsMs or 0) + now - tick
    if s.lowFpsNoticed or s.lowFpsMs < TUNE.LOWFPS_NOTICE_MS then return end
    s.lowFpsNoticed = true
    local playerObj = getSpecificPlayer(s.playerNum)
    if not playerObj then return end
    local text = getText("UI_MinidoracatAutoDrive_LowFpsNotice", string.format("%d", math.floor(sen.effectiveAheadM)))
    HaloTextHelper.addGoodText(playerObj, text)
    if MDADDiagnostics and MDADDiagnostics.toast then MDADDiagnostics.toast(text, "good") end
end

-- 為對向車側移：以速率上限平滑追 trfOnWant；對方離開掃描帶後保持到 trafficHoldUntil
-- （Sensor 從車頭前 2m 才開始掃，交會那一刻對方就不在快照裡了）再回常駐線。只往閃避
-- 方向覆寫（靠右錯開＝max），殭屍軟縫的結果仍可再往同方向多閃。
function Drive.trafficLaneOf(s, nb, now, playerNum)
    local target
    if s.trfOnWant ~= nil then
        s.trafficSide = s.trfOnSide
        target = s.trfOnWant
    elseif s.trafficLane ~= nil and now < s.trafficHoldUntil then
        target = s.trafficLane
    end
    local cur = s.trafficLane
    if target == nil and cur == nil then return nb end
    if cur == nil then cur, s.trafficLaneMs = nb, now end
    local dt = (now - s.trafficLaneMs) / 1000
    if not finite(dt) or dt < 0 then dt = 0 elseif dt > 1 then dt = 1 end
    s.trafficLaneMs = now
    local tgt = target or nb
    local lim = TUNE.TRAFFIC_LANE_RATE_MPS * dt
    local step = tgt - cur
    if step > lim then step = lim elseif step < -lim then step = -lim end
    cur = cur + step
    if target == nil and math.abs(cur - nb) <= TUNE.ZOMBIE_LANE_SETTLE_M then
        s.trafficLane = nil
        diagEvent(s, playerNum, "traffic", { phase = "release", l = nb })
        return nb
    end
    if s.trafficLane == nil then
        diagEvent(s, playerNum, "traffic", { phase = "lane", l = nb, offL = tgt })
    end
    s.trafficLane = cur
    if s.trafficSide < 0 then return cur < nb and cur or nb end
    return cur > nb and cur or nb
end

-- 每幀的會車／跟車速度帽（取代舊的「帶內有行進車＝20」）：回 cap（−1＝無）、理由、是否合法停等。
-- 快照年齡以相對速度外推距離。讓車／側移來不及才停等（followHold＝WAIT＋forceBrake，同舊跟車）。
function Drive.trafficCap(s, now, speedKmh)
    local age = (now - (s.trfStamp or now)) / 1000
    if not finite(age) or age < 0 then age = 0 elseif age > 1 then age = 1 end
    local vSelf = (finite(speedKmh) and speedKmh > 0) and speedKmh / 3.6 or 0
    local coast = finite(s.safeCoast) and math.max(0, s.safeCoast) or 0
    local brake = finite(s.safeBrake) and s.safeBrake > 0 and s.safeBrake * TUNE.APPROACH_BRAKE_FRAC or 0.6
    local cap, reason, hold = -1, nil, false
    if s.trfLeadGap ~= nil then
        local vL = s.trfLeadV or 0
        local gap = s.trfLeadGap - (vSelf - vL) * age
        if gap <= TUNE.FOLLOW_STOP_M then
            if vL < 1.5 then cap, hold = 0, true else cap = vL * 3.6 * 0.7 end
        else
            cap = MDADDynamics.approachCapKmh(gap - TUNE.FOLLOW_MIN_M - vL * TUNE.FOLLOW_TIME_S,
                vL * 3.6, 0.5, coast)
        end
        -- 低於最低執行速就停等：GO 意圖會把 0<target<MIN_EXEC 抬到 8，照 8 追慢車＝貼上去
        if cap < MDADDynamics.MIN_EXEC_KMH then cap, hold = 0, true end
        reason = "moving"
    end
    if s.trfOnGap ~= nil then
        local vO = s.trfOnV or 0
        local closing = vSelf + vO
        local gap = s.trfOnGap - closing * age
        local dSelf = closing > 0.1 and gap * vSelf / closing or gap
        local c
        if s.trfOnYield then
            c = MDADDynamics.approachCapKmh(dSelf - TUNE.TRAFFIC_YIELD_BUFFER_M, 0, 0.5, brake)
            if c < MDADDynamics.MIN_EXEC_KMH then c, hold = 0, true end
        else
            -- 側移要在交會前做完：交會時間＝gap／(vSelf＋vO) ≥ 剩餘側移時間＋LEAD。側移已完成
            -- （對 control 實際會落的 lane 差 ≤ TRAFFIC_SHIFT_DONE_M）或已經並排（gap≤0）就不再用
            -- 這條帽——否則 LEAD 秒數會在交會前一刻把已閃開的車煞停（2026-09-24 E2E fix1b 實測）。
            c = 999
            local latNow = finite(s.lastLatSigned) and s.lastLatSigned or laneBiasOf(s)
            local dl = math.abs(MDADFollower.laneBiasAt(s.profile, s.trfOnWant, s.fstate.idx, s.lastSNow,
                TUNE.TRAFFIC_EDGE_KEEP_M) - latNow)
            local shifting = s.trfOnShift and gap > 0 and dl > TUNE.TRAFFIC_SHIFT_DONE_M
            if shifting then
                c = (gap / (dl / TUNE.TRAFFIC_LANE_RATE_MPS + TUNE.TRAFFIC_LEAD_S) - vO) * 3.6
                if c < 0 then c = 0 end
                -- 側移來不及：邊減速邊繼續側移（停住就橫移不了），停在交會點前；真的來不及才停等
                if c < MDADDynamics.MIN_EXEC_KMH then
                    local yc = MDADDynamics.approachCapKmh(dSelf - TUNE.TRAFFIC_YIELD_BUFFER_M, 0, 0.5, brake)
                    if yc > c then c = yc end
                end
            end
            local m = s.trfOnMargin or TUNE.TRAFFIC_MARGIN_M
            if m < TUNE.TRAFFIC_PASS_FREE_M then
                local t = (m - TUNE.TRAFFIC_MARGIN_MIN_M)
                    / (TUNE.TRAFFIC_PASS_FREE_M - TUNE.TRAFFIC_MARGIN_MIN_M)
                if t < 0 then t = 0 elseif t > 1 then t = 1 end
                local pc = MDADDynamics.approachCapKmh(dSelf > 0 and dSelf or 0,
                    TUNE.TRAFFIC_PASS_MIN_KMH + t * 35, 0.5, coast)
                if pc < c then c = pc end
            end
            if shifting and c < MDADDynamics.MIN_EXEC_KMH then c, hold = 0, true end
        end
        if cap < 0 or c < cap then
            cap, reason = c, s.trfOnYield and "traffic-yield" or "traffic"
        end
    end
    return cap, reason, hold
end

-- 動物／其他玩家停等（1005 soft）：每個掃描輪在 laneBias 由所有持有者（軟縫、會車、斜切保持、繞行）仲裁定案後跑，
-- 看「車到目標那時候身在哪」：繞行承諾中＝承諾線；否則以仲裁後實際採用的 laneBias 判誰在主導——軟縫仍是最後輸出
-- 才用它選定的 want、會車主導用會車目標（trfOnWant）、其他（斜切保持等）用 laneBias 本身；車身從現在的橫向位置
-- 以該持有者的側移速率往終點走，扣車身落後 ZOMBIE_LANE_LEAD_S，算出到目標弧長時的橫向位置。落在佔位
-- ±(R＋舒適餘裕) 內＝閃不開或側移來不及：記最近一個給每幀的 Drive.softStopCap。目標讀 Sensor 另存的停等目標
-- （stopS…，不受殭屍點陣溢出影響）；停等目標本身也收不下（stopOverflow）時，收不下的那段起點之後證明不了淨空，
-- 照停等處理。動物照沙盒 AnimalSlowdown 分級、玩家永遠算；殭屍／屍體不在這裡（照既有裁定：閃不過就撞）。調頭中不判。
function Drive.softStopScan(s, speedKmh)
    s.softStopS, s.softStopL, s.softStopKind, s.softStopLane = nil, nil, nil, nil
    local sen = s.sensor
    if not sen or s.fstate.rotating then return end
    local n = finite(sen.stopN) and sen.stopN or 0
    if n <= 0 and sen.stopOverflow ~= true then return end
    local vp, p, rs = s.vehicleProfile, s.profile, s.lastSNow
    local lvl = s.animalSlow or 2
    local R = vp.halfW + MDADCorridor.ZOMBIE_R + MDADCorridor.ZOMBIE_MARGIN
    local sTo = rs + MDADDynamics.softLookahead(speedKmh)
    if finite(sen.softEndS) and sen.softEndS < sTo then sTo = sen.softEndS end
    local L = laneBiasOf(s)
    local dest, rate = L, Drive.softLaneRate(speedKmh)
    if s.zombieLane ~= nil and math.abs(L - s.zombieLane) < 1e-9 then
        if finite(s.zombieWant) then dest = s.zombieWant end
    elseif s.trafficLane ~= nil and math.abs(L - s.trafficLane) < 1e-9 then
        if finite(s.trfOnWant) then dest = s.trfOnWant end
        rate = TUNE.TRAFFIC_LANE_RATE_MPS
    end
    local latNow = finite(s.lastLatSigned) and s.lastLatSigned or L
    local vms = finite(speedKmh) and speedKmh / 3.6 or 0
    if vms < 3 then vms = 3 end
    for i = 1, n do
        local kind = sen.stopKind[i]
        local zs, zl = sen.stopS[i], sen.stopL[i]
        if (kind == "player" or Drive.softKindIn(kind, false, lvl))
                and finite(zs) and finite(zl) and zs > rs and zs <= sTo
                and (s.softStopS == nil or zs < s.softStopS) then
            local zlp, vl = zl, sen.stopVl[i]
            local tArr = (zs - rs - vp.halfL) / vms
            if finite(vl) and (vl > 0.2 or vl < -0.2) then
                local t = tArr
                if t < 0 then t = 0 elseif t > TUNE.ZOMBIE_PREDICT_S then t = TUNE.ZOMBIE_PREDICT_S end
                zlp = zl + vl * t
            end
            local lane
            if s.dodging then
                lane = Drive.plannedLaneAt(s, zs)
            else
                local idx = MDADFollower.segIndexAt(p, zs)
                lane = MDADFollower.laneBiasAt(p, dest, idx, zs, s.fstate.laneKeep)
                local reach = rate * (tArr - TUNE.ZOMBIE_LANE_LEAD_S)
                if not finite(reach) or reach < 0 then reach = 0 end
                local d = lane - latNow
                if d > reach then lane = latNow + reach elseif d < -reach then lane = latNow - reach end
            end
            local Rk = R + Drive.softPad(kind)
            if math.max(zl, zlp) > lane - Rk and math.min(zl, zlp) < lane + Rk then
                s.softStopS, s.softStopL, s.softStopLane = zs, zl, lane
                s.softStopKind = kind == "player" and "player" or "animal"
            end
        end
    end
    local oS, oK = sen.stopOverS, sen.stopOverKind
    if sen.stopOverflow == true and finite(oS) and oS > rs and oS <= sTo
            and (oK == "player" or Drive.softKindIn(oK, false, lvl))
            and (s.softStopS == nil or oS < s.softStopS) then
        s.softStopS, s.softStopL, s.softStopLane = oS, nil, nil
        s.softStopKind = oK == "player" and "player" or "animal"
    end
end

-- gentle 動物（只在減速名單、不在閃避名單；zombieLaneOf 記 s.softGentleS）成為威脅時的每幀接近帽：在車頭到牠前
-- ZOMBIE_APPROACH_LEAD_M 降到 ANIMAL_GENTLE_KMH，再照軟縫繞過；車尾過了牠（或軟縫不再把牠當威脅）才解除。與呼叫端
-- 目前的 sensor cap 取小後回 (cap, 理由)。減速度＝safeBrake×APPROACH_BRAKE_FRAC（Drive.visAssistForce 有 soft-gentle 帳）：
-- 斷油滑行在重車上只有約 1 m/s²，60 km/h 起要 130m 以上才滑得到 15，軟縫視窗內來不及。
function Drive.softGentleCap(s, playerNum, capIn, whyIn)
    s.softGentleCapKmh = -1
    local gs = s.softGentleS
    local on = finite(gs) and gs >= s.lastSNow - s.vehicleProfile.halfL
    if on ~= (s.softGentleOn == true) then
        s.softGentleOn = on
        diagEvent(s, playerNum, "soft", { phase = on and "gentle" or "gentle-end", why = "animal-gentle",
            kind = "animal", s = on and gs - s.lastSNow or nil, rs = s.lastSNow, cap = TUNE.ANIMAL_GENTLE_KMH })
        if getDebug() then
            print(string.format("%spn=%d soft gentle %s ds=%.1f rs=%.1f cap=%d", LOG, playerNum, on and "on" or "off",
                on and gs - s.lastSNow or -1, s.lastSNow, TUNE.ANIMAL_GENTLE_KMH))
        end
    end
    if not on then return capIn, whyIn end
    local brake = (finite(s.safeBrake) and s.safeBrake > 0) and s.safeBrake * TUNE.APPROACH_BRAKE_FRAC or 0.6
    local cap = MDADDynamics.approachCapKmh(gs - s.lastSNow - s.vehicleProfile.halfL - TUNE.ZOMBIE_APPROACH_LEAD_M,
        TUNE.ANIMAL_GENTLE_KMH, 0.5, brake)
    s.softGentleCapKmh = cap
    if capIn < 0 or cap < capIn then return cap, "animal-gentle" end
    return capIn, whyIn
end

-- 每幀的動物／玩家停等帽：與呼叫端目前的 sensor cap（capIn／whyIn）取小後回 (cap, 理由)；合法停等時設
-- s.followHold（stepFollow 主函式 local 槽已滿，合併在這裡做）。接近包絡停在目標前 SOFT_STOP_GAP_M
-- （同 trafficCap 讓車的單調式；減速度＝safeBrake×APPROACH_BRAKE_FRAC，Drive.visAssistForce 有 soft-stop 帳）。
-- 低於 MIN_EXEC 就停等（WAIT）。玩家：計共用停等預算，到期由 postAction wait 以 Drive.KEY_PLAYER_STOP 交還。
-- 動物：另外計時、不吃共用預算（s.softAnimalHold→Drive.animalOnlyWait）——停住累計 ANIMAL_WAIT_MS 仍在＝以
-- ANIMAL_CRAWL_KMH 爬過（CRAWL）；爬行累計 ANIMAL_CRAWL_MAX_MS 仍擋著＝s.softGiveUp（postAction animal 以
-- Drive.KEY_ANIMAL_STOP 交還）。動物離開行駛線＝立刻放行；但從這次停等起點（s.softAnimalAnchorS）車還沒前進
-- WAIT_PROGRESS_M 就又擋回來時，停住與爬行的累計都接著算（停→放→停 不會無限重來）。
-- 狀態給 E2E／遙測讀：s.softHoldKind（nil／"animal"／"player"）、s.softHoldMs、s.softCrawl、s.softCrawlMs。
function Drive.softStopCap(s, now, speedKmh, playerNum, capIn, whyIn)
    s.softStopCapKmh, s.softAnimalHold = -1, false
    local zs, kind = s.softStopS, s.softStopKind
    if s.softHoldKind ~= nil and s.softHoldKind ~= kind then
        local carry = s.softHoldKind == "animal" and finite(s.softAnimalAnchorS)
            and s.lastSNow - s.softAnimalAnchorS < MDADDynamics.WAIT_PROGRESS_M
        if s.softHoldStarted or s.softCrawl then
            diagEvent(s, playerNum, "soft", { phase = "end", why = kind == nil and "clear" or "kind",
                kind = s.softHoldKind, ms = s.softHoldMs, rs = s.lastSNow, detail = carry and "carry" or nil })
            if getDebug() then
                print(string.format("%spn=%d soft stop end kind=%s ms=%d crawlMs=%d carry=%s rs=%.1f", LOG, playerNum,
                    s.softHoldKind, s.softHoldMs, s.softCrawlMs, tostring(carry), s.lastSNow))
            end
        end
        if carry then
            s.softAnimalCarryMs, s.softCrawlCarry = s.softHoldMs, s.softCrawl
        else
            s.softAnimalCarryMs, s.softCrawlCarry, s.softCrawlMs, s.softAnimalAnchorS = 0, false, 0, nil
        end
        s.softHoldKind, s.softHoldMs, s.softHoldTick, s.softHoldStarted, s.softCrawl = nil, 0, 0, false, false
        s.softCrawlTick = 0
    end
    if not finite(zs) or kind == nil then return capIn, whyIn end
    if s.softHoldKind == nil and kind == "animal" then
        s.softHoldMs, s.softCrawl = s.softAnimalCarryMs, s.softCrawlCarry -- 同一處沒前進就接著算
    end
    s.softHoldKind = kind
    local reason, cap, hold = kind == "player" and "player-stop" or "animal-stop", nil, false
    if s.softCrawl then
        cap, reason = TUNE.ANIMAL_CRAWL_KMH, "animal-crawl"
    else
        local brake = (finite(s.safeBrake) and s.safeBrake > 0) and s.safeBrake * TUNE.APPROACH_BRAKE_FRAC or 0.6
        cap = MDADDynamics.approachCapKmh(zs - s.lastSNow - s.vehicleProfile.halfL - TUNE.SOFT_STOP_GAP_M, 0, 0.5, brake)
        if cap < MDADDynamics.MIN_EXEC_KMH then cap, hold = 0, true end
    end
    if hold then
        if not s.softHoldStarted then
            s.softHoldStarted = true
            if kind == "animal" and not finite(s.softAnimalAnchorS) then s.softAnimalAnchorS = s.lastSNow end
            -- offL＝判停用的「到目標時車身橫向」（nil＝停等目標收不下的溢出段）
            diagEvent(s, playerNum, "soft", { phase = "start", why = reason, kind = kind,
                s = zs - s.lastSNow, l = s.softStopL, offL = s.softStopLane, rs = s.lastSNow, speed = speedKmh,
                ms = s.softHoldMs })
            if getDebug() then
                print(string.format("%spn=%d soft stop start kind=%s ds=%.1f l=%.2f at=%.2f v=%.1f ms=%d", LOG, playerNum,
                    kind, zs - s.lastSNow, s.softStopL or 0, s.softStopLane or 0, speedKmh or 0, s.softHoldMs))
            end
        end
    end
    -- 停住才計（還在煞停中不算等待）。停住後（softHoldStarted）車沒在動就照牆鐘計，這一幀接近帽有沒有低於
    -- MIN_EXEC 不影響：1005e E2E animal-sp herd，停等目標位置一抖帽就在 MIN_EXEC 上下跳，每隔一幀計時起點被
    -- 歸零，6 秒的等待實際 12.6 秒才爬（smoke (soft-g8)）。爬行中不計（爬行另有 softCrawlMs）。
    if s.softHoldStarted and not s.softCrawl and finite(speedKmh) and speedKmh < 1 and speedKmh > -1 then
        if s.softHoldTick > 0 and now > s.softHoldTick then s.softHoldMs = s.softHoldMs + (now - s.softHoldTick) end
        s.softHoldTick = now
        if kind == "animal" and s.softHoldMs >= TUNE.ANIMAL_WAIT_MS then
            s.softCrawl = true
            cap, reason, hold = TUNE.ANIMAL_CRAWL_KMH, "animal-crawl", false
            diagEvent(s, playerNum, "soft", { phase = "crawl", why = reason, kind = kind,
                s = zs - s.lastSNow, l = s.softStopL, ms = s.softHoldMs, cap = cap })
            if getDebug() then
                print(string.format("%spn=%d soft stop crawl kind=%s ds=%.1f ms=%d cap=%d", LOG, playerNum,
                    kind, zs - s.lastSNow, s.softHoldMs, cap))
            end
        end
    else
        s.softHoldTick = 0
    end
    -- 爬行累計（牆鐘；動物一直擋著、被車推著走也算）：到上限＝交還，不無限爬
    if s.softCrawl and kind == "animal" then
        if s.softCrawlTick > 0 and now > s.softCrawlTick then s.softCrawlMs = s.softCrawlMs + (now - s.softCrawlTick) end
        s.softCrawlTick = now
        if s.softCrawlMs >= TUNE.ANIMAL_CRAWL_MAX_MS then s.softGiveUp = true end
    end
    s.softStopCapKmh = cap
    if hold then
        s.softAnimalHold = kind == "animal" and not s.followHold -- 只有動物停等（會車停等另計共用預算）
        s.followHold = true
    end
    if capIn < 0 or cap < capIn then return cap, reason end
    return capIn, whyIn
end

-- classifyIntent 的 blockedStop 參數（停止線、繞行延後、下一台接近、起步近物低於 MIN_EXEC）：stepFollow 與
-- Drive.animalOnlyWait 共用同一個定義。
function Drive.waitHoldArg(s, blockedStop)
    return blockedStop
        or (not s.dodging and finite(s.dodgeDeferCap) and s.dodgeDeferCap >= 0
            and s.dodgeDeferCap < MDADDynamics.MIN_EXEC_KMH)
        or (s.dodging and finite(s.dodgeNextCap) and s.dodgeNextCap >= 0
            and s.dodgeNextCap < MDADDynamics.MIN_EXEC_KMH)
        or (finite(s.startNearCap) and s.startNearCap < MDADDynamics.MIN_EXEC_KMH)
end

-- 這幀的 WAIT 只來自動物停等（沒有停止線／繞行延後／起步近物／回線待命／可視上限／會車停等）：
-- 動物停等另外計時，不計共用停等預算 waitAccumMs（玩家照舊計）。
function Drive.animalOnlyWait(s, blockedStop)
    return s.softAnimalHold == true and not Drive.waitHoldArg(s, blockedStop) and s.returnHold ~= true
        and not (finite(s.visibilityCap) and s.visibilityCap < MDADDynamics.MIN_EXEC_KMH)
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

-- 待承諾接近帽的鎖輪門檻（0928h；rc6 0068：coverage 延後的接近帽每輪才重算一次、以 safeBrake
-- 反推，斷油滑行跟不上，越過 cap+3 就一秒鎖輪——38 km/h 直接煞到 0，下一輪就承諾了 15 km/h 的
-- 繞行）。接近帽本身照舊（regulator 目標＋Drive.visAssistForce 的不鎖輪減速輔助去追它）；
-- 鎖輪只在連緊急煞車（0.3s 反應＋緊急界限，同 0925p 速度延後的緊急帳）都快停不到群起點時才用。
-- 群起點未知、感知未就緒、低於輔助啟用速度：退回接近帽本身（舊制）。拖掛同樣有輔助（0929o 起分攤到掛車）。
function Drive.deferHardKmh(s, actualSpeed)
    local soft = s.dodgeDeferCap
    if not finite(s.dodgeDeferS) or not (s.sensor and s.sensor.ready)
            or not finite(actualSpeed) or actualSpeed < TUNE.VIS_ASSIST_MIN_KMH then
        return soft
    end
    local decel = s.safeBrake
    if not finite(decel) or decel <= 0 then return soft end
    local aE = tightenLimit(math.min(decel * TUNE.EMERGENCY_BRAKE_GAIN, TUNE.EMERGENCY_BRAKE_MAX),
        s.brakeLower, s.brakeConfidence, TUNE.EMERGENCY_BRAKE_MAX)
    local hard = MDADDynamics.approachCapKmh(
        s.dodgeDeferS - s.lastSNow - s.vehicleProfile.halfL, 0, 0.3, aE)
    if not finite(hard) or hard < soft then return soft end
    return hard
end

-- 可視上限兩帳（2026-09-27 正式服 222 段 visibility 一秒鎖輪定罪，四種機制都不是真障礙：
-- 低幀率掃描輪逾期 77、區塊串流前緣停住 95、可負擔視距回縮 33、遊戲卡頓凍住 15）：
-- ① 反應時間固定 VIS_TAU：車逼近前緣已由真實車位反映，快照年齡不再二次疊進反應時間。
--    舊制 tau＝年齡＋0.25，硬煞帳每秒掉 2v 的距離當量——輪時逾期 0.4 秒就越線；遊戲卡住
--    1.5 秒（世界沒前進、牆鐘有）後第一幀也直接越線。停住不動的掃描仍安全：前緣距離隨車位
--    縮短，縮到緊急停距才硬煞，車照樣停在已知淨空範圍內。
-- ② 巡航帳再加「前緣停滯保持」：假設可視前緣從上次前進起再停 T 秒（輪時 EWMA×MULT＋ADD；
--    前緣是未載入區塊時至少 VIS_UNLOADED_HOLD_S），期間只能滑行，停滯結束時仍不越過硬煞帳
--   （MDADDynamics.visibilityHoldCapKmh）。串流前緣在 80 km/h 停 1.5 秒＝逼近 33m，舊巡航帳
--    只按當下距離算、滑行（約 3 m/s²）跟不上它每秒 7 m/s² 的下降。
-- 回 (巡航帽 km/h, 巡航煞車帳 m/s²)；硬煞帳寫 s.visibilityHardKmh。
function Drive.visibilityCaps(s, now, visibleEnd, minBrakeVisible)
    local sen, halfL = s.sensor, s.vehicleProfile.halfL
    local visBrake = math.min(minBrakeVisible * TUNE.EMERGENCY_BRAKE_GAIN, TUNE.EMERGENCY_BRAKE_MAX)
    visBrake = tightenLimit(visBrake, s.brakeLower, s.brakeConfidence, TUNE.EMERGENCY_BRAKE_MAX)
    -- 上限留在緊急界限的 3/4：兩帳分家才不會回到 0911c 的鋸齒硬煞（巡航帽貼著硬煞紅線）。
    local cruiseBrake = minBrakeVisible * TUNE.CRUISE_VIS_BRAKE_GAIN
    if cruiseBrake > visBrake * 0.75 then cruiseBrake = visBrake * 0.75 end
    if cruiseBrake < minBrakeVisible then cruiseBrake = minBrakeVisible end
    local ahead = visibleEnd - s.lastSNow
    local cap = MDADDynamics.visibilityCapKmh(ahead, TUNE.VIS_TAU, cruiseBrake, halfL)
    local st = sen.stamp
    if st ~= s.visStamp then
        if finite(s.visStamp) and s.visStamp > 0 and st > s.visStamp then
            local dt = (st - s.visStamp) / 1000
            if dt > TUNE.VIS_ROUND_MAX_S then dt = TUNE.VIS_ROUND_MAX_S end
            s.visRoundS = s.visRoundS + (dt - s.visRoundS) * TUNE.VIS_ROUND_ALPHA
        end
        s.visStamp = st
    end
    -- 前緣前進才重設停滯起點；回縮不算前進（停滯照算）
    if not finite(s.visFrontRef) or visibleEnd > s.visFrontRef + TUNE.VIS_FRONT_ADVANCE_M then
        s.visFrontRef, s.visFrontSince = visibleEnd, now
    elseif visibleEnd < s.visFrontRef then
        s.visFrontRef = visibleEnd
    end
    local hold = s.visRoundS * TUNE.VIS_HOLD_MULT + TUNE.VIS_HOLD_ADD_S
    if sen.unloaded and finite(sen.unloadedS) and sen.unloadedS <= sen.scanEndS + 0.5
            and hold < TUNE.VIS_UNLOADED_HOLD_S then
        hold = TUNE.VIS_UNLOADED_HOLD_S
    end
    hold = hold - (now - s.visFrontSince) / 1000
    if hold < TUNE.VIS_HOLD_MIN_S then hold = TUNE.VIS_HOLD_MIN_S end
    s.visHold = hold
    local coast = s.horizonStamp == st and s.horizonMinCoast or s.safeCoast
    if not finite(coast) or coast < 0 then coast = 0 end
    local holdCap = MDADDynamics.visibilityHoldCapKmh(ahead, TUNE.VIS_TAU, visBrake, halfL, coast, hold)
    if holdCap < cap then cap = holdCap end
    -- 硬煞帳的前緣若就是路線終點（可視已含終點、無未載入截斷），終點不是障礙：不扣
    -- halfL+2 的障礙緩衝（0924d E2E：MAX 檔 90 km/h 滑行到站，實速落後剖面 3-4 km/h，
    -- 終點前 7m 以 18 km/h 撞上硬煞紅線 14.8 一秒鎖輪；到站本身由剖面與 arrive 管）。
    -- 1002l：終點是建表就知道的定點，反應時間只算致動延遲（VIS_TERMINAL_TAU）；巡航帳＝硬煞帳，不再扣緩衝與
    -- 停滯保持——終點停車由剖面的終點包絡（斷油＋Follower.STOP_ASSIST）負責。舊巡航帳在終點前 15–28m 就把
    -- 目標壓在剖面下 5–7 km/h（E2E rc52：抵達的 20 趟最後一段全都被 visibility 綁過、16 趟以它為主）。
    local hardAhead = ahead
    if visibleEnd >= s.profile.length - 0.5 then
        hardAhead = hardAhead + halfL + 2
        -- 終點不是障礙、停車靠不經輪胎的中線外力：用車輛自己的緊急帳（safeBrake，不套風格的計畫制動），
        -- 與 Follower 終點包絡的 segStopBrake 同源（1002t：舒適檔終點包絡抬到車輛能力，舊帳 3.0×2.5＝7.5
        -- 會在終點前一路越線硬煞）
        local termBrake = visBrake
        if finite(s.safeBrake) and s.safeBrake > minBrakeVisible then
            termBrake = tightenLimit(math.min(s.safeBrake * TUNE.EMERGENCY_BRAKE_GAIN, TUNE.EMERGENCY_BRAKE_MAX),
                s.brakeLower, s.brakeConfidence, TUNE.EMERGENCY_BRAKE_MAX)
            if termBrake < visBrake then termBrake = visBrake end
        end
        s.visibilityHardKmh = MDADDynamics.approachCapKmh(ahead, 0, TUNE.VIS_TERMINAL_TAU, termBrake)
        cap, s.visHold = s.visibilityHardKmh, 0
    else
        s.visibilityHardKmh = MDADDynamics.visibilityCapKmh(hardAhead, TUNE.VIS_TAU, visBrake, halfL)
    end
    s.visHardAhead = hardAhead -- 可視硬煞觸發時的輔助煞車距離（Drive.emergencyBrakeDist）
    return cap, cruiseBrake
end

-- 進度監督的停滯計時暫停（2026-09-27 正式服 5 段，含 0926a）：自己的一秒硬煞閂鎖中、或引擎
-- 原生煞車壓著的低速幀，車根本沒有前進致動，不算「不動」（CarController.java:208-215：前方
-- 1–2 個 chunk 未載入時 isInvalidChunkAhead 直接煞車，優先於 regulator 供油 :240-254；這種煞車
-- fbl=0 但 isBraking 真）。舊制照算 2.5 秒就 suspect 倒車：visibility／串流煞停後前方其實淨空
-- 卻倒車、剛起步又被舊停滯窗判 recover。回本幀要往後推 progressSince 的毫秒數（＝暫停）；
-- 連續煞停超過 PROGRESS_BRAKE_GRACE_MS 就不再暫停，免得永遠不載入的前緣讓車乾等。
-- 接觸（currentBlocked）與 VERIFY 窗不經這裡，照舊計時。
function Drive.progressPauseMs(s, vehicle, now, speedKmh)
    local last = s.progressPauseAt
    s.progressPauseAt = now
    -- 遊戲卡頓：上一個跟線幀也在看門、兩幀之間牆鐘卻隔了 > PROGRESS_HITCH_MS，物理卻只前進了一小步，車幾乎
    -- 沒動。兩種證據任一：①引擎這幀的時間係數已頂到上限（FPSTracking.java:39-42 fpsMultiplier 夾 5＝1× 速度下
    -- 單幀物理最多 83ms；0928c E2E rc1 0007：47 km/h 卡住 3.6 秒只前進 1.4m → 誤判 suspect、在 47 km/h 下令空檔
    -- 脈衝）；②車在跑（|v|>3 km/h）、物理步長卻遠小於這段牆鐘（1004a 正式服 0.18.2 Qoo clip-16：整個客戶端凍住
    -- 5.8 秒、恢復首幀 fdt 只有 27ms，①漏判 → suspect → 24 km/h 鎖輪倒車）。整段不算停滯。
    if finite(last) and last == s.prevStepMs and now - last > TUNE.PROGRESS_HITCH_MS and finite(s.frameMs)
            and (s.frameMs >= TUNE.PROGRESS_HITCH_FRAME_MS
                or (s.frameMs < (now - last) * 0.5 and (speedKmh > 3 or speedKmh < -3))) then
        s.progressBrakedSince = 0
        return now - last
    end
    local gap = not finite(last) or now - last > 250 or now < last
    -- 中斷過（離開 watch／讓位／停等）＝新一次煞停，寬限重新起算（review：沿用舊起點會讓
    -- 「煞停→解除→再煞停」的新寬限立即過期）
    if gap then s.progressBrakedSince = 0 end
    -- 前方區域未載入（Drive.areaWait）：引擎自己煞住車，整段暫停、不吃 GRACE（有自己的 AREA_WAIT_MAX_MS）
    if s.areaWaitActive then
        if gap then return 0 end
        return now - last
    end
    local braked = now < s.forceBrakeUntil
        or (speedKmh < 3 and speedKmh > -3 and vehicle:isBraking() == true)
    if not braked then
        s.progressBrakedSince = 0
        return 0
    end
    if s.progressBrakedSince == 0 then s.progressBrakedSince = now end
    if now - s.progressBrakedSince >= TUNE.PROGRESS_BRAKE_GRACE_MS then return 0 end
    if gap then return 0 end
    return now - last
end

-- 巡航減速輔助（2026-09-27）：巡航帳假設能以 cruiseBrake 減速，但 regulator 斷油只有滑行
--（NoControl brake 15，約 2.5–4.5 m/s²）；可視距離縮得比滑行快時，舊制只能等越過硬煞紅線
-- 一秒鎖輪。實速超過巡航帽 TOL 以上就沿車身中線加反向外力補足，比例於超速量、上限
-- VIS_ASSIST_MAX；不鎖輪、轉向照常（與側推共用同一個 impulse 槽，中線分量不產生 yaw）。
-- 拖掛也加（0929o）：同一減速度依掛車質量另外施給掛車（Drive.towDecel）。掛車自己不煞車
--（CarController.updateTrailer:383-393：Trailer 煞車力 0、被拖的車 10），只減牽引車＝掛車從後面推、
-- 折角放大；兩節同減速度，掛點就不推。舊制拖車一律不加，重車只能滑行＝彎前很早收油，可視距離一縮
-- 就只剩一秒鎖輪（正式服 0.13.1 拖車 visibility 鎖輪 4.2 次/h，單車 0.62）。
-- 低於 MIN_KMH 滑行就夠（剖面已把輔助算進收油包絡的段除外，見下）；感知未就緒時舊制只滑行，不加。
-- 外力→減速度：BaseVehicle.update 每幀 applyCentralForce 一次（BaseVehicle.java:3307-3314），
-- WorldSimulation.updatePhysic 以固定 0.01s 子步 stepSimulation、每步後清力（WorldSimulation.java:
-- 80-100）→ 每幀 Δv＝F/m×0.01；F 乘 mult/MULT_NORM（mult＝48×幀秒）→ 每秒減速度
-- ＝F/(m·mult/MULT_NORM)×0.01×(48/MULT_NORM)，與幀率無關。
-- 回要施的外力大小（≥0）；s.visAssistDecel 記本幀補的減速度（telemetry vad），s.visAssistWhy 記追的是哪一本帳（vaw）。
function Drive.visAssistForce(s, speedKmh, mult)
    s.visAssistDecel, s.visAssistWhy = 0, nil
    if not (s.sensor and s.sensor.ready) or not finite(s.visibilityCap) or not finite(speedKmh) then
        return 0
    end
    -- 已承諾繞行且實速超過本幀套用的繞行帽（接近包絡／保持段／下一群停止包絡）：同一條中線外力，
    -- 上限放到 DODGE_ASSIST_MAX（HOHOHO/clip-01：縫口前 1m 以 63 km/h 承諾 cap 18，只靠滑行到縫仍 56）
    local cap, amax, gain = s.visibilityCap, TUNE.VIS_ASSIST_MAX, TUNE.VIS_ASSIST_GAIN
    local minKmh, why, ff = TUNE.VIS_ASSIST_MIN_KMH, "vis", 0
    -- 包絡在收（1002d）：剖面／車道包絡比上一次呼叫低 ASSIST_FALL_KMH 以上＝正在收向彎道。前饋只在這時補；
    -- 巡航（剖面＝上限）與弧內（平坦）一超過一點就前饋＝regulator 每次越過就脈衝減速。
    local pv = s.fstate and s.fstate.profileSpeedKmh
    local lce = s.laneCurveEnvelope
    local pvFalling = finite(pv) and finite(s.assistPvLast) and pv < s.assistPvLast - TUNE.ASSIST_FALL_KMH
    local lceFalling = finite(lce) and finite(s.assistLceLast) and lce < s.assistLceLast - TUNE.ASSIST_FALL_KMH
    s.assistPvLast, s.assistLceLast = pv, lce
    -- 彎前晚收油：剖面（fstate.profileSpeedKmh）已假設這份輔助（Follower.STYLES.coastAssist）
    if s.profile and (s.profile.coastAssist or 0) > 0 and finite(pv) and pv < cap then
        cap, amax, gain, why = pv, TUNE.CURVE_ASSIST_MAX, TUNE.CURVE_ASSIST_GAIN, "profile"
        -- 這段收油包絡建表時就算進輔助（coastAssistAt>0）：25 km/h 以下照補。
        -- 2026-10-01 正式服 0.14.0–0.16.0：MAX 急彎（彎帽 12）一秒鎖輪從每百公里 0.33 升到 1.2–1.8——
        -- 剖面最後 3–4m 從 25 收到 12 要 5–6 m/s²，舊制 25 以下整個不補、只剩斷油 2–3.6，抵達 18.5–20 km/h
        -- 剛好越過 1.5×彎帽（片段：超剖面時 25 以上 117/117 幀有補、25 以下 49/49 幀為 0）。
        local at, idx = s.profile.coastAssistAt, s.fstate.idx
        if at and idx and (at[idx] or 0) > 0 then
            minKmh = 0
            -- 前饋（1002c）：包絡在收時一超過剖面就先補建表假設的那一份，比例項只追殘差。
            -- 純比例要先落後 TOL＋輔助/增益（2.25 km/h）才補得到假設的量＝重車進彎前一路落後 2–4 km/h
            -- （E2E SemiTruckLite R≈7：剖面收到 15.3 時實速 16.5–19.4）。
            if pvFalling then ff = at[idx] end
            -- 終點段假設的輔助（Follower.STOP_ASSIST）比彎前大：上限跟著留同樣的比例項餘地（1002l）
            if at[idx] + TUNE.CURVE_ASSIST_HEADROOM > amax then amax = at[idx] + TUNE.CURVE_ASSIST_HEADROOM end
        end
    end
    -- 車道包絡（1002a）：目標實際由證明線的 lane curve envelope 裁決（煞車×0.7 反推；靠右車道在右轉彎內側＝
    -- 半徑更小），它常比剖面低 10–40 km/h，舊制輔助只追剖面＝目標寫著 30、車只靠滑行從 41 慢慢掉
    -- （正式服 0.17.0 kkbug/clip-03：SemiTruckLite 以 38 km/h 衝進 26 km/h 的 90° 折點、側滑撞上；近四次抓回的
    -- 216 個入弧有 59 個超過彎帽 1.15 倍，多數入弧前 lce 低於剖面 10 km/h 以上而 vad≈0）。lce 等於車輛極速
    -- （直路 κ＝0）時不是彎道帳，不追。上限用繞行的 DODGE_ASSIST_MAX：lce 以煞車×0.7 反推（重車約 4.2 m/s²），
    -- 剖面的 coastAssist 只假設 2.5——重車斷油 0.6＋CURVE_ASSIST_MAX 4 剛好等於包絡、追不回入口的超速
    --（E2E SemiTruckLite 同一個 90° 折點：上限 4 時整段飽和 1.2 秒、到折點仍超 lce 3–8 km/h）。
    -- 前饋（1002d）：車道包絡以 s.laneEnvDecel 反推（煞車×0.7 與「斷油＋剖面輔助」取大，見 buildSnapshotProof），
    -- 收的時候一超過就補「計畫減速度－斷油」，比例項只追殘差。
    local vmax = s.vehicleProfile and s.vehicleProfile.maxSpeed
    if s.laneCurveStamp == s.sensor.stamp and finite(lce) and lce >= 0 and lce < cap
            and (not finite(vmax) or lce < vmax - 1) then
        cap, amax, gain, minKmh, why = lce, TUNE.DODGE_ASSIST_MAX, TUNE.CURVE_ASSIST_GAIN, 0, "lane"
        ff = 0
        local plan = s.laneEnvDecel
        if lceFalling and finite(plan) then
            local coast = finite(s.safeCoast) and s.safeCoast > 0 and s.safeCoast or 0
            if plan > coast then ff = plan - coast end
        end
    end
    if s.dodging and finite(s.dodgeApproachCap) and s.dodgeApproachCap >= 0 and s.dodgeApproachCap < cap then
        cap, amax, gain, minKmh, why = s.dodgeApproachCap, TUNE.DODGE_ASSIST_MAX, TUNE.VIS_ASSIST_GAIN,
            TUNE.VIS_ASSIST_MIN_KMH, "dodge"
    end
    -- blocked 接近包絡（Drive.blockedApproachCap）：同一條中線外力、同一上限
    if finite(s.blockedApproachCap) and s.blockedApproachCap < cap then
        cap, amax, gain, minKmh, why = s.blockedApproachCap, TUNE.DODGE_ASSIST_MAX, TUNE.VIS_ASSIST_GAIN,
            TUNE.VIS_ASSIST_MIN_KMH, "blocked"
    end
    -- 證明線掃掠命中的接近包絡（Drive.proofSweepCap，1005）：同一條中線外力、同一上限
    if finite(s.proofSweepCap) and s.proofSweepCap < cap then
        cap, amax, gain, minKmh, why = s.proofSweepCap, TUNE.DODGE_ASSIST_MAX, TUNE.VIS_ASSIST_GAIN,
            TUNE.VIS_ASSIST_MIN_KMH, "proof"
    end
    -- 待承諾接近帽（dodge-defer）：同一條中線外力、同一上限；鎖輪門檻見 Drive.deferHardKmh
    if not s.dodging and finite(s.dodgeDeferCap) and s.dodgeDeferCap >= 0 and s.dodgeDeferCap < cap then
        cap, amax, gain, minKmh, why = s.dodgeDeferCap, TUNE.DODGE_ASSIST_MAX, TUNE.VIS_ASSIST_GAIN,
            TUNE.VIS_ASSIST_MIN_KMH, "defer"
    end
    -- 殭屍軟縫的縱向配合帽（zombieLaneCap，只對開了減速政策的類型算）：側移在到達前做不完就先降速（1002a）。
    -- 帽只夾 regulator＝斷油滑行，正式服 0.13.1–0.17.0 片段 40 段帽低於實速 8 km/h 以上、39 段 vad 0
    -- （0.17.0 Aho/clip-19：77 km/h 對帽 12 只滑到 70 就撞進殭屍群）。同一條中線外力、繞行的上限。
    if not s.dodging and finite(s.zombieLaneCap) and s.zombieLaneCap >= 0 and s.zombieLaneCap < cap then
        cap, amax, gain, minKmh, why = s.zombieLaneCap, TUNE.DODGE_ASSIST_MAX, TUNE.VIS_ASSIST_GAIN,
            TUNE.VIS_ASSIST_MIN_KMH, "zombie-lane"
    end
    -- 會車／跟車帽（Drive.trafficCap；1002q）：同型，帽只夾 regulator＝斷油滑行。正式服 0.17.0 pigpig/clip-02：
    -- 84 km/h 時前車約 35m 才出現、帽 43→25、vad 0，只滑到 61 就承諾繞行、20.6 km/h 擦上。同一條中線外力、繞行的上限。
    if finite(s.trafficCapKmh) and s.trafficCapKmh >= 0 and s.trafficCapKmh < cap then
        cap, amax, gain, minKmh, why = s.trafficCapKmh, TUNE.DODGE_ASSIST_MAX, TUNE.VIS_ASSIST_GAIN,
            TUNE.VIS_ASSIST_MIN_KMH, "traffic"
    end
    -- 動物／玩家停等接近帽（Drive.softStopCap；1005 soft）：以 safeBrake 反推、要停在目標前，同一條中線外力、繞行的上限。
    if finite(s.softStopCapKmh) and s.softStopCapKmh >= 0 and s.softStopCapKmh < cap then
        cap, amax, gain, minKmh, why = s.softStopCapKmh, TUNE.DODGE_ASSIST_MAX, TUNE.VIS_ASSIST_GAIN,
            TUNE.VIS_ASSIST_MIN_KMH, "soft-stop"
    end
    -- gentle 動物接近帽（Drive.softGentleCap）：以 safeBrake 反推、到牠前降到 ANIMAL_GENTLE_KMH，同一條中線外力。
    if finite(s.softGentleCapKmh) and s.softGentleCapKmh >= 0 and s.softGentleCapKmh < cap then
        cap, amax, gain, minKmh, why = s.softGentleCapKmh, TUNE.DODGE_ASSIST_MAX, TUNE.VIS_ASSIST_GAIN,
            TUNE.VIS_ASSIST_MIN_KMH, "soft-gentle"
    end
    if speedKmh < minKmh then return 0 end
    local over = speedKmh - cap - TUNE.VIS_ASSIST_TOL_KMH
    local a
    if (why == "profile" or why == "lane") and ff > 0 then
        if speedKmh <= cap then return 0 end
        a = ff + (over > 0 and over * gain or 0)
    else
        if over <= 0 then return 0 end
        a = over * gain
    end
    if a > amax then a = amax end
    local mass = s.runtimeMass
    if not finite(mass) or mass < 1 then mass = MASS_FALLBACK end
    s.visAssistDecel, s.visAssistWhy = a, why
    return a * mass * (mult / MULT_NORM) / (0.01 * 48 / MULT_NORM)
end

-- 加速輔助（TUNE.ACCEL_ASSIST_*）：目標比實速高時沿車身中線補一段加速度——不經輪胎、不吃側向抓地、
-- 不產生 yaw（與側推共用同一個 impulse 槽，中線分量與前臂平行）。目標已含彎道／可視／繞行／會車等全部
-- 限速，這裡只讓車更快到達它；差距 GAP_MIN→GAP_FULL 線性淡入，貼近目標不補（不過衝）。
-- MP 伺服器速限低於 120 時，引擎到速限就斷油（CarController.java:675、788）：補到速限前 LIMIT_MARGIN
-- 為止，不替伺服器速限開後門（速限 ≥120 時 getFakeSpeedModifier＝1，沙盒上限 120 本來就不會超過）。
-- 拖車：折角超過 TOW_PHI 不補；補的時候掛車由呼叫端依同一加速度分攤（Drive.towDecel 傳負值）。
-- 只在全速閘門打開（路線證明、走廊、車身框都淨空，循線追蹤中）且不在起步近物保護時補：閘門關著的
-- sweep／obb 限速、繞行、回線都表示附近有東西或位置還不確定（E2E acc-1001i h2005：證明線掃到障礙、
-- 限速 18 的起步多補 2 m/s²，1 秒內撞上 1.6m 外的東西）。車身離期望線超過 ACCEL_ASSIST_LAT_M、車頭偏離路線
-- 超過 ACCEL_ASSIST_HEAD_RAD、或本幀的限速理由不在 ACCEL_ASSIST_REASONS（朝已知障礙接近）也不補
-- （s.lastLatDev 是本幀 stepFollow 稍早算的原始偏差，不含軟縫／車道 ramp 的寬容）。
-- s.accelAssist 記本幀補的加速度（telemetry aca；0＝沒補）。
function Drive.accelAssistForce(s, speedKmh, targetSpeed, mult)
    s.accelAssist = 0
    if not s.fullGate or s.startGuard then return 0 end
    local dev = s.lastLatDev
    if not finite(dev) or dev > TUNE.ACCEL_ASSIST_LAT_M or dev < -TUNE.ACCEL_ASSIST_LAT_M then return 0 end
    if finite(s.crossDLat) then
        local p = dev + s.crossDLat * TUNE.ACCEL_ASSIST_LEAD_S
        if p > TUNE.ACCEL_ASSIST_LAT_M or p < -TUNE.ACCEL_ASSIST_LAT_M then return 0 end
    end
    if finite(s.lastRouteErr) and s.lastRouteErr > TUNE.ACCEL_ASSIST_HEAD_RAD then return 0 end
    -- 前視鉗在還沒放行的無弧折點上（fallback／髮夾，約剩 9–25m）：再幾公尺就要以 rMin 轉，補油只會讓車用更高的速度
    -- 進放行點（1002t；正式服 0.17.0 clip-09：起步 4.3m 接 90° fallback，加速輔助補滿、放行時 14 km/h 滿舵打滑繞圈）
    if s.fstate and s.fstate.kinkHeld ~= nil then return 0 end
    local why = s.lastCapReason
    if why ~= nil and not TUNE.ACCEL_ASSIST_REASONS[why] then return 0 end
    if not finite(speedKmh) or not finite(targetSpeed) or speedKmh < 0 then return 0 end
    local ceil = targetSpeed
    local limit = Drive.serverSpeedLimit()
    if limit and limit - TUNE.ACCEL_ASSIST_LIMIT_MARGIN < ceil then
        ceil = limit - TUNE.ACCEL_ASSIST_LIMIT_MARGIN
    end
    local gap = ceil - speedKmh - TUNE.ACCEL_ASSIST_GAP_MIN
    if gap <= 0 then return 0 end
    if s.tow and not (finite(s.towPhi) and math.abs(s.towPhi) <= TUNE.ACCEL_ASSIST_TOW_PHI) then return 0 end
    local k = gap / (TUNE.ACCEL_ASSIST_GAP_FULL - TUNE.ACCEL_ASSIST_GAP_MIN)
    if k > 1 then k = 1 end
    local a = TUNE.ACCEL_ASSIST_MPS2 * k
    local mass = s.runtimeMass
    if not finite(mass) or mass < 1 then mass = MASS_FALLBACK end
    s.accelAssist = a
    return a * mass * (mult / MULT_NORM) / (0.01 * 48 / MULT_NORM)
end

-- 掛車分攤（見 Drive.visAssistForce）：沿掛車自己的速度反向施 a×掛車質量的中線外力（relPos 0，不產生
-- yaw）。用速度而不是 forward：被倒著拖的車 forward 朝後。換算與牽引車同一條（每幀 Δv＝F/m×0.01）。
-- a 為負＝沿速度往前推（加速輔助的掛車分攤，Drive.accelAssistForce），掛鉤拉力不因輔助加大。
-- 掛車上只有這一處施力（BaseVehicle.addImpulse:681-692 同幀第二次較大的衝量會把整槽作廢）。
-- s.towAssistDecel 記本幀真的施給掛車的減速度（telemetry tda；0＝沒施，負＝往前推）。
function Drive.towDecel(s, a, mult)
    s.towAssistDecel = 0
    local tow = s.tow
    local mass = tow and tow.mass
    if not (tow and tow.trailer) or not finite(a) or a == 0 or not finite(mass) or mass <= 0 then return end
    local tr = tow.trailer
    local vel = BaseVehicle.allocVector3f()
    tr:getLinearVelocity(vel)
    local vx, vz = vel:x(), vel:z()
    local len = finite(vx) and finite(vz) and sqrt(vx * vx + vz * vz) or 0
    if len > 0.5 then
        local f = a * mass * (mult / MULT_NORM) / (0.01 * 48 / MULT_NORM) / len
        local imp = BaseVehicle.allocVector3f()
        imp:set(-f * vx, 0, -f * vz)
        vel:set(0, 0, 0)
        tr:addImpulse(imp, vel)
        BaseVehicle.releaseVector3f(imp)
        s.towAssistDecel = a
    end
    BaseVehicle.releaseVector3f(vel)
end

-- 樹叢阻力抵消用的引擎方法在不在（BaseVehicle.applyImpulseFromHitPlant，public，BaseVehicle.java:5556-5565）
function Drive.bushApi(vehicle)
    local ok, fn = pcall(jindex, vehicle, "applyImpulseFromHitPlant")
    return ok and type(fn) == "function"
end

-- 樹叢阻力抵消（1004d，使用者 2026-10-04「遇到樹叢也可以加大推力來幫助通過」）：引擎每幀對車身外 0.3m 內的每一叢
-- 施 −mul×質量×速度的衝量（checkCollisionWithPlant，BaseVehicle.java:3074-3116；側面接觸或 <10 km/h 時 mul 0.025、
-- 正面 ≥10 km/h 0.1），進 impulsesFromHitObjects、每個 10ms 物理步 ×30 施力（:3590-3616；WorldSimulation.java:80-110）：
-- 每叢每幀扣約 0.75% 車速、不乘 dt，幀率越高越黏（E2E 230 FPS：W900＋貨櫃在樹叢地只剩 1 km/h）。這裡對同一批樹叢呼叫
-- 同一個方法、mul 取負：同一個作用點、等量反向，力與偏航力矩一起抵消，車速與車頭都不再被拖。接觸照抄引擎：
-- >1 km/h（:3080-3081；引擎沒發動時 session 早在 driveGate 收掉）、離車心 max(半寬,半長)+1.3 內、車身框（以重心偏移為中心）外 0.3m 內
-- （testCollisionWithObject :5368-5451）；側面＝接觸點的本地橫向超過 0.98 倍半寬（isPositionOnLeftOrRight :1961-1971）。
-- 候選只在路外／繞行／回線／倒車時抓。方法呼叫失敗＝bushOff "call"：Sensor 寬帶改回避開樹叢，事件記一次原因。
function Drive.bushCancel(s, vehicle, now)
    s.bushContactN = 0
    local sen, vp = s.sensor, s.vehicleProfile
    if s.bushOff then
        if s.bushOff ~= "tow" and not s.bushOffLogged and s.diag then
            s.bushOffLogged = true
            diagEvent(s, s.playerNum, "bush", { phase = "off", why = s.bushOff })
        end
        return
    end
    if type(sen) ~= "table" or type(vp) ~= "table" then return end
    local spd = vehicle:getCurrentSpeedKmHour()
    if not finite(spd) then return end
    if spd < 0 then spd = -spd end
    if spd <= 1 or not (s.physicalOffroad == true or s.dodging == true or s.returnActive == true
            or s.mode == "unstick" or s.mode == "settle") then
        s.bushN, s.bushScanMs = 0, 0 -- 一動起來就重抓
        return
    end
    -- 照抄引擎就用引擎的車身框（script extents），不是規劃寬 halfW：機車 MOD 的 halfW 墊到 FOOTPRINT_W_MIN，
    -- 拿它判接觸會抵消引擎根本沒施的阻力＝淨前推、越快越推（E2E 1005k 哈雷樹叢地 0.8 秒 0→49 km/h）
    local hw, hl = vp.bodyW * 0.5, vp.halfL
    local reach = (hw > hl and hw or hl) + 1.3 -- 引擎的粗篩半徑（testCollisionWithObject selfRadius）
    local vx, vy = vehicle:getX(), vehicle:getY()
    if now >= s.bushScanMs then
        s.bushScanMs = now + TUNE.BUSH_SCAN_MS
        -- 下次重抓前車還會開 spd×間隔：候選半徑多留這段再加 1m
        local ok, n = pcall(MDADSensor.bushNear, sen, vehicle, getCell(), vx, vy,
            reach + 1 + spd / 3.6 * TUNE.BUSH_SCAN_MS * 0.001, s.bushObj, s.bushX, s.bushY, TUNE.BUSH_MAX_N)
        s.bushN = ok and finite(n) and n or 0
    end
    if s.bushN <= 0 then return end
    local fwd = BaseVehicle.allocVector3f()
    vehicle:getForwardVector(fwd)
    local fx, fy = fwd:x(), fwd:z()
    BaseVehicle.releaseVector3f(fwd)
    local fl = finite(fx) and finite(fy) and fx * fx + fy * fy or 0
    if fl < 1e-6 then return end
    fl = sqrt(fl)
    fx, fy = fx / fl, fy / fl
    local nx, ny = fy, -fx -- 車身本地 +x（同 getWorldPos／sweepLine 的重心換算）
    local comX, comZ = vp.centerOfMassX or 0, vp.centerOfMassZ or 0
    local cx, cy = vx + fx * comZ + nx * comX, vy + fy * comZ + ny * comX
    local sideLo, sideHi = (comX - hw) * 0.98, (comX + hw) * 0.98
    local reach2 = reach * reach
    local n = 0
    for i = 1, s.bushN do
        local bx, by = s.bushX[i], s.bushY[i]
        local ox, oy = bx - vx, by - vy
        if ox * ox + oy * oy <= reach2 then
            local dx, dy = bx - cx, by - cy
            local lat, lon = dx * nx + dy * ny, dx * fx + dy * fy
            local px = nil -- 接觸點的本地橫向（相對車身框中心）；nil＝沒碰到
            if lat > -hw and lat < hw and lon > -hl and lon < hl then
                -- 樹叢在車身框內：引擎把接觸點推到最近的那一面外 0.315（平手＝原點）
                local dw, de, dn, ds = lat + hw, hw - lat, lon + hl, hl - lon
                if dw < de and dw < dn and dw < ds then px = -hw - 0.315
                elseif de < dw and de < dn and de < ds then px = hw + 0.315
                elseif (dn < dw and dn < de and dn < ds) or (ds < dw and ds < de and ds < dn) then px = lat
                else px = -comX end
            else
                local qx = lat < -hw and -hw or (lat > hw and hw or lat)
                local qz = lon < -hl and -hl or (lon > hl and hl or lon)
                local ex, ez = lat - qx, lon - qz
                local d2 = ex * ex + ez * ez
                if d2 < 0.09 then
                    px = d2 > 0 and qx + ex / sqrt(d2) * 0.315 or hw + 1
                end
            end
            if px then
                local side = px + comX < sideLo or px + comX > sideHi
                local mul = (side or spd < 10) and 0.025 or 0.1
                local obj = s.bushObj[i]
                if pcall(vehicle.applyImpulseFromHitPlant, vehicle, obj, -mul) then
                    n = n + 1
                else
                    -- 候選抓到後才被砍掉、物件已回收（格是 nil，IsoObject reset）：引擎同樣不對它施力，下一幀重抓；
                    -- 還在格上卻失敗＝方法本身不能用
                    local okSq, sq = pcall(obj.getSquare, obj)
                    if okSq and sq ~= nil then
                        s.bushOff, s.bushN = "call", 0
                        sen.bushPassable = false
                        return
                    end
                    s.bushScanMs = 0
                end
            end
        end
    end
    s.bushContactN = n
end

-- 判堵停止線（blockedNear 判距；接近包絡、telemetry、stepFollow 同一個數）。拖車多留掛車跟上側移的跑道
-- （0929p）：掛車軸沿 tractrix 落後牽引車約 L2 的尺度，離線 L2 9.5／trailLen 14.5 的貨櫃要車心離群 ≥24m
-- 才掃得過寬帶繞行（E2E semi-long-mp block：停在 10m 線、倒車 7m 仍 steep → 改道 → 急彎折斷）；
-- 小掛車（trailLen 6.9）10m 就夠，多留的只是提早停。
function Drive.blockStopDist(s)
    local d = s.cornerLatch and TUNE.CORNER_STOP_DIST or TUNE.BLOCK_STOP_DIST
    local tw = s.tow
    if type(tw) == "table" and finite(tw.trailLen) and finite(tw.L2) then d = d + tw.trailLen + 0.5 * tw.L2 end
    return d
end

-- 判堵煞停（stepFollow blockedStop、telemetry capBlocked）：到停止線內，或這個堵點已在停止線武裝寬帶、車還沒開過
-- 武裝點（0929s E2E semi-long-mp block：blocked-retry 倒車 5m 退出停止線外，接近包絡 20 km/h 又開回停止線、跑道白退，
-- 起步前也來不及用寬帶重判 → 改道）。倒車退出來就停著等寬帶重判，下一次 blocked-retry 再退，跑道逐次累加。
-- 武裝範圍不用脫困 episode：blocked-retry 的倒車不開 episode（eid 0），episode 只在接觸／進度停滯時才有。
-- 只綁武裝時的堵點（判堵錨世界座標）：錨換到 TUNE.WIDE_ARM_SAME_M 外＝原障礙移走、改判遠處另一群，解除武裝照常接近
-- （0929v 審查：否則車永遠停在第一道的停止線前，離第二道數十公尺也不往前開）。錨暫缺時照舊停著。
function Drive.blockedAtStop(s, vx, vy)
    if s.wideArmed == true and finite(s.wideArmedS) and s.lastSNow <= s.wideArmedS + 1 then
        local ax, ay, bx, by = s.wideArmedX, s.wideArmedY, s.blockHitX, s.blockHitY
        if not (finite(ax) and finite(ay) and finite(bx) and finite(by))
                or (bx - ax) * (bx - ax) + (by - ay) * (by - ay) <= TUNE.WIDE_ARM_SAME_M * TUNE.WIDE_ARM_SAME_M then
            return true
        end
        Drive.disarmWide(s)
    end
    return MDADDynamics.blockedNear(s.blockS, s.lastSNow, Drive.blockStopDist(s), vx, vy, s.blockHitX, s.blockHitY)
end

-- 解除寬帶武裝（堵點已解：承諾繞行／判定淨空、開過武裝點、換目標、判堵換到別處）。
function Drive.disarmWide(s)
    s.wideArmed, s.wideArmedS, s.wideBlockedLogged, s.wideJudged = false, nil, nil, nil
    s.wideArmedX, s.wideArmedY, s.wideLevel, s.wideLevelAt = nil, nil, nil, nil
end

-- 本次脫困嘗試要求的寬帶級：每次嘗試（倒車退出新跑道）都從第一級開始（Drive.wideJudge 升級時記下嘗試編號）。
function Drive.wideLevelOf(s)
    return s.wideLevelAt == s.episodeAttempts and s.wideLevel or 1
end

-- 寬帶判過一輪：這次脫困嘗試的倒車／改道可以動了（autoDetourNow／blocked-retry 的閘是 wideJudged＝本次 attempt）。
-- 判完仍堵、這一級還不是最寬（TUNE.WIDE_LEVEL_MAX）：停著先升一級重掃，閘門等最寬那級判完才開（1004c）。
-- 跑道不夠（steep 差額，blockSteepM）不升級：更外側的縫側移更大、只會更陡，照舊先倒車補跑道（0.5s 出口不變）；
-- 倒車後的新嘗試從第一級重來——第二級的外圈若有未載入格會截短整輪可見距離，近處剛補出跑道的縫第一級就判得到。
function Drive.wideJudge(s, playerNum)
    local lvl = s.sensor.wideDoneLevel or 1
    if s.blocked and s.wideArmed and lvl < TUNE.WIDE_LEVEL_MAX and type(s.tow) ~= "table"
            and not (finite(s.blockSteepM) and s.blockSteepM > 0) then
        if Drive.wideLevelOf(s) <= lvl then
            s.wideLevel, s.wideLevelAt = lvl + 1, s.episodeAttempts
            if getDebug() then
                print(string.format("%spn=%d wide level %d blocked -> rescan at level %d", LOG, playerNum, lvl, lvl + 1))
            end
        end
        return
    end
    s.wideJudged = s.episodeAttempts
end

-- 判堵是「跑道不夠」（steep 差額）、倒車額度還在、這次停等的倒車沒被後方擋過：先倒車補跑道重判，不問替代路線
-- （1004c，使用者「真的都不行才考慮繞道」；E2E blockscan dixie9050w：寬帶第二級找到外側縫只差 1.3m 跑道，同一幀
-- 就去問改道）。額度用完或倒不了照舊改道。
function Drive.runwayRetryFirst(s)
    return finite(s.blockSteepM) and s.blockSteepM > 0 and s.episodeAttempts < UNSTICK_MAX and not s.blockRetryDone
end

-- 停等預算到期時，倒車退出的新跑道（episodeAttempts ≥1）還沒用寬帶判到最寬一級：最多再等 TUNE.WIDE_JUDGE_GRACE_MS
-- 讓它判完再交還／交還前改道（1004c；倒車本身也吃預算，E2E blockscan dixie9050w 第二次倒車補出跑道後 0.2 秒預算到期，
-- 寬帶一輪都沒判就改道繞 1.9 km）。第一次停等（attempt 0）停下約 1 秒就判完，到期還沒判＝別的問題，照常交還。
-- 出口：寬帶判完、解除武裝或超過寬限都照常。
function Drive.wideJudgePending(s)
    return s.wideArmed == true and s.episodeAttempts >= 1 and s.wideJudged ~= s.episodeAttempts
        and s.waitAccumMs < TUNE.WAIT_TIMEOUT_MS + TUNE.WIDE_JUDGE_GRACE_MS
end

-- blocked 接近包絡（0928b；E2E rc1 0005 StepVan：70 km/h 在 68m 外判 blocked，舊制只把目標壓到
-- BLOCK_APPROACH_KMH 滑行——重車斷油約 2.5 m/s²，到 10m 停止線仍 34 km/h，一秒鎖輪後仍以 26 km/h
-- 撞上前方停著的車）。以規劃煞車能力（safeBrake×APPROACH_BRAKE_FRAC，同 stay-hold／dodge-defer）
-- 反推「在停止線降到 BLOCK_APPROACH_KMH」的包絡：超過包絡由 Drive.visAssistForce 沿中線補減速，
-- 超過硬煞門檻才一秒鎖輪（hardBrakeReason blocked-approach）。停止線與 blockedNear 同一個判距。
function Drive.blockedApproachCap(s, vx, vy)
    local stopDist = Drive.blockStopDist(s)
    local _, wd = MDADDynamics.blockedNear(s.blockS, s.lastSNow, stopDist, vx, vy, s.blockHitX, s.blockHitY)
    if not finite(wd) then
        if not finite(s.blockS) or not finite(s.lastSNow) then return nil end
        wd = s.blockS - s.lastSNow
    end
    local decel = s.safeBrake
    if not finite(decel) or decel <= 0 then decel = 0.6 else decel = decel * TUNE.APPROACH_BRAKE_FRAC end
    return MDADDynamics.approachCapKmh(wd - stopDist, TUNE.BLOCK_APPROACH_KMH, 0.5, decel)
end

-- 證明線世界掃掠在煞停視界內命中（gate "sweep"）的接近包絡（1005）：舊制平壓近場警戒帽（ungatedCapKmh 18）只夾
-- regulator＝斷油滑行，41–53 km/h 時滑不到就撞上路口物件（open-issue「規劃與世界掃掠的硬點位置不一致」）。改成
-- 「車心開到掃掠命中的車身取樣點（s.proofHitS）時降到同一個警戒帽」的包絡，煞車基準同 blocked 接近包絡
-- （safeBrake×APPROACH_BRAKE_FRAC）；超過包絡由 Drive.visAssistForce 的 "proof" 帳沿中線補減速（誰去執行）。
-- ungated＝原本的警戒帽（終點速度），fullTarget 是上限。命中點不明（nil）照舊回 ungated。寫 s.proofSweepCap。
function Drive.proofSweepCap(s, ungated, fullTarget)
    local hit = s.proofHitS
    if not finite(hit) or not finite(s.lastSNow) or not finite(ungated) then
        s.proofSweepCap = nil
        return ungated
    end
    local decel = s.safeBrake
    if not finite(decel) or decel <= 0 then decel = 0.6 else decel = decel * TUNE.APPROACH_BRAKE_FRAC end
    local cap = MDADDynamics.approachCapKmh(hit - s.lastSNow, ungated, 0.5, decel)
    if finite(fullTarget) and cap > fullTarget then cap = fullTarget end
    s.proofSweepCap = cap
    return cap
end

-- 前方區域未載入的等待（TUNE.AREA_WAIT_MAX_MS）：只在要前進（GO／CRAWL 且目標 > 0）時問引擎。
-- s.areaWaitActive 供進度監督暫停、停等預算排除、HUD；回 true＝已連續等滿上限且車停著（呼叫端交還）。
function Drive.areaWait(s, vehicle, now, targetSpeed, speedKmh)
    local active = false
    if targetSpeed > 0 and (s.intentShadow == "GO" or s.intentShadow == "CRAWL") then
        local ok, inv = pcall(jget, vehicle, "isInvalidChunkAhead")
        active = ok and inv == true
    end
    if not active then
        if s.areaWaitSince > 0 then
            diagEvent(s, s.playerNum, "area", { phase = "end", ms = now - s.areaWaitSince })
            s.areaWaitSince = 0
        end
        s.areaWaitActive = false
        return false
    end
    if s.areaWaitSince == 0 then
        s.areaWaitSince = now
        diagEvent(s, s.playerNum, "area", { phase = "start", speed = speedKmh, s = s.lastSNow })
    end
    s.areaWaitActive = true
    return now - s.areaWaitSince >= TUNE.AREA_WAIT_MAX_MS and speedKmh < 1 and speedKmh > -1
end

-- 回授依轉向增益正規化（TUNE.FB_NORM_*）：弧段前饋（Follower ffSteer，已除以 yawGain）以外的部分乘 k。
-- 增益讀 Follower 的無偏估計 yawGainFb（1001h：舊制拿逐幀夾限後平均的 yawGain，低增益重車被估高 2–3 倍，
-- 正規化形同沒作用）；還沒學到時退 yawGain。拖車照舊用 yawGain（半聯結的無偏估計 0.18–0.25＝回授放大 2–2.7 倍，
-- 掛車的折角動態沒有離線模型可驗，維持 1001g 已通過拖掛 E2E 的行為）。s.fbNorm 進遙測。
-- 耦力原地調頭不經此路（呼叫端判）。
function Drive.normalizeSteer(s, steer)
    local g = not s.tow and s.fstate.yawGainFb or nil
    if not finite(g) then g = s.fstate.yawGain end
    local k = 1
    if finite(g) and g > 0 then
        k = TUNE.FB_NORM_REF / g
        if k < 1 then k = 1 elseif k > TUNE.FB_NORM_MAX then k = TUNE.FB_NORM_MAX end
    end
    s.fbNorm = k
    if k == 1 then return steer end
    local ff = s.fstate.ffSteer
    if not finite(ff) then ff = 0 end
    local fb = steer - ff
    local afb = fb < 0 and -fb or fb
    local lim = afb > TUNE.FB_NORM_CLAMP and afb or TUNE.FB_NORM_CLAMP -- 原本就更大的照原值，不縮
    local out = k * fb
    if out > lim then out = lim elseif out < -lim then out = -lim end
    return ff + out
end

-- 車身 yaw 率限制（TUNE.ESC_*）：回收掉同向部分後的 steer；s.yawRate／s.escScale 進遙測。
function Drive.yawGovern(s, steer, heading, speedKmh, now)
    local refT = s.escT
    if not finite(refT) or now < refT or now - refT > 250 then
        s.escH, s.escT, s.yawRate = heading, now, nil
    elseif now - refT >= TUNE.ESC_WINDOW_MS then
        local d = heading - s.escH
        if d > math.pi then d = d - 2 * math.pi elseif d < -math.pi then d = d + 2 * math.pi end
        s.yawRate = d * 1000 / (now - refT)
        s.escH, s.escT = heading, now
    end
    s.escScale = 1
    local r = s.yawRate
    if steer == 0 or not finite(r) or steer * r <= 0 then return steer end
    local v = (speedKmh < 0 and -speedKmh or speedKmh) / 3.6
    local rMin = s.vehicleProfile.rMin
    if not finite(rMin) or rMin < 0.5 then rMin = 5 end
    local allow = v / rMin
    local lat = s.safeLat
    if finite(lat) and lat > 0 and v > 0.1 and lat / v < allow then allow = lat / v end
    allow = allow * TUNE.ESC_MARGIN + TUNE.ESC_FLOOR_RADS
    local ar = r < 0 and -r or r
    if ar <= allow then return steer end
    local k = 2 - ar / allow
    if k < 0 then k = 0 end
    s.escScale = k
    return steer * k
end

-- 起步近物限速（TUNE.START_GUARD_*）：回套用後的目標速度。車頭前方帶內（MDADCorridor.FRONT_STRIP_PAD）最近硬物的
-- 淨距是掃描輪快照的值，逐幀扣掉之後開過的直線距離（保守：當成正朝它開）。帽低於 MIN_EXEC 時記在 s.startNearCap：
-- 意圖歸 WAIT、不被 MIN_EXEC 抬回（1004e；E2E dixie9050w 改道調頭後 start-near 收到 0、被抬回 8 km/h 撞上），停住不動
-- 由 Drive.startNearStall 倒車讓空間。
function Drive.startGuardApply(s, targetSpeed, now, vx, vy, latSigned, speedKmh)
    if not s.startGuard then return targetSpeed end
    local dx, dy = vx - s.startGuardX, vy - s.startGuardY
    local maxM = TUNE.START_GUARD_MAX_M
    if dx * dx + dy * dy >= maxM * maxM then
        s.startGuard = false
        return targetSpeed
    end
    local err = s.lastRouteErr
    local dev = finite(latSigned) and (latSigned - expectedLaneOf(s)) or 99
    if dev < 0 then dev = -dev end
    if finite(err) and err <= TUNE.START_GUARD_ALIGN_RAD and dev <= TUNE.START_GUARD_LAT_M then
        if s.startGuardOkMs == 0 then
            s.startGuardOkMs = now
        elseif now - s.startGuardOkMs >= TUNE.START_GUARD_HOLD_MS then
            s.startGuard = false
            return targetSpeed
        end
    else
        s.startGuardOkMs = 0
    end
    local fc = s.frontClearance
    if not finite(fc) or not finite(s.frontClearX) then return targetSpeed end
    local mx, my = vx - s.frontClearX, vy - s.frontClearY
    fc = fc - sqrt(mx * mx + my * my)
    local coast = s.safeCoast
    if not finite(coast) or coast < 0.5 then coast = 0.5 end
    local cap = MDADDynamics.approachCapKmh(fc - TUNE.START_GUARD_MARGIN_M, 0, 0.5, coast)
    -- 繞行釋放武裝的只擋加速、不另外減速：帽不低於釋放後第一幀的車速（Drive.armReleaseGuard）
    if s.startGuardRelease then
        if s.startGuardFloorKmh == nil and finite(speedKmh) then
            s.startGuardFloorKmh = speedKmh < 0 and -speedKmh or speedKmh
        end
        if finite(s.startGuardFloorKmh) and cap < s.startGuardFloorKmh then cap = s.startGuardFloorKmh end
    end
    if cap < targetSpeed then
        s.lastCapReason = "start-near"
        s.startNearCap = cap
        return cap
    end
    return targetSpeed
end

function Drive.armStartGuard(s, vx, vy)
    s.startGuard, s.startGuardOkMs = true, 0
    s.startGuardX, s.startGuardY = vx, vy
    s.startGuardRelease, s.startGuardFloorKmh = nil, nil
end

-- 起步近物限速把車停在物件前（s.startNearCap < MIN_EXEC）又連續 START_NEAR_STALL_MS 不動＝車頭正對著它：請求倒車
-- 讓出空間（後方探測照樣把關；倒車開始會重新武裝起步近物限速；倒不了照停等預算交還）。每幀呼叫以維持計時。
function Drive.startNearStall(s, now, avProgress)
    if not (finite(s.startNearCap) and s.startNearCap < MDADDynamics.MIN_EXEC_KMH) or avProgress >= 1 then
        s.startNearSince = 0
        return false
    end
    if s.startNearSince == 0 then s.startNearSince = now end
    return now - s.startNearSince >= TUNE.START_NEAR_STALL_MS
end

-- 斜切保持（1004e）：車不在常駐線上（> START_GUARD_LAT_M；起步、倒車後、繞行或回線放手後）時，跟線會從車位斜切回去，
-- 規劃器只問常駐線擋不擋，斜切掃過的地方沒人管（E2E dixie9050w 改道調頭後：車在 −3.17、常駐 +3，中間 +1.2 的物件被
-- 斜切撞上；正式服 0.18.2 GGGMAMEER clip-10 回線停等放手後同型）。斜切帶＝每個硬點所在弧長上「車位 → 常駐落點」之間、
-- 從車心往常駐線那一側量（d ≥ 0）：車位側的邊取最慢的收斂（純追跡、車頭沿路線時偏差剩 (1+kx)e^−kx，k＝√2／前視，
-- x 從車頭量），常駐側的邊取常駐落點，兩邊各加 needHalf＋點半徑。車心另一側的點不算：斜切是遠離它們（貼著車側另一邊的
-- 牆，保持反而沿牆擦過去），正前方的由起步近物限速管。帶內有硬點＝先沿車位直走（laneBias＝車位，規劃器與證明線改以
-- 這條線判擋；不經 clampLane——Drive.laneKeepOf 回 false，車在路寬外也照車位走，路外的證明線判 band、走 obb 近場帽），
-- 每個掃描輪重判，帶淨空（多留 TRANSITION_RELEASE_M）才放回常駐線。回本輪要寫的 laneBias。
function Drive.transitionHold(s, nb, playerNum, speedKmh)
    local sen, prof, lat = s.sensor, s.profile, s.lastLatSigned
    if s.fstate.rotating == true or not sen.ready or type(prof) ~= "table" or not finite(lat) then
        return Drive.transitionRelease(s, playerNum, "rotate", nb)
    end
    local look = MDADFollower.lookaheadM(speedKmh, prof.lookScale or 1)
    local k, rs, halfL = 1.4142 / look, s.lastSNow, s.vehicleProfile.halfL
    local far, pad = rs + halfL + 2 * look, finite(s.holdLaneL) and TUNE.TRANSITION_RELEASE_M or 0
    for i = 1, sen.hardN do
        local hs = sen.hardS[i]
        if hs >= rs - halfL and hs <= far then
            local target = MDADFollower.laneBiasAt(prof, nb, MDADFollower.segIndexAt(prof, hs), hs, s.fstate.laneKeep)
            local dl = target - lat
            if dl > TUNE.START_GUARD_LAT_M or dl < -TUNE.START_GUARD_LAT_M then
                local sg = dl > 0 and 1 or -1
                local kx = k * math.max(0, hs - rs - halfL)
                local edge = dl * sg * (1 - (1 + kx) * math.exp(-kx)) -- 車位側的邊（往常駐線方向量，0＝車心）
                local r = sen.hardR[i]
                local w = s.needHalf + (finite(r) and r >= 0 and r or MDADCorridor.OBS_HALF) + pad
                local d = (sen.hardL[i] - lat) * sg
                if d >= 0 and d > edge - w and d < dl * sg + w then
                    if not finite(s.holdLaneL) then
                        s.holdLaneL, s.planSig = lat, -1
                        diagEvent(s, playerNum, "lane", { phase = "hold", l = lat, offL = target, rs = rs,
                            hitS = hs, hitX = sen.hardX[i], hitY = sen.hardY[i] })
                    end
                    return s.holdLaneL
                end
            end
        end
    end
    return Drive.transitionRelease(s, playerNum, "clear", nb)
end

-- 結束斜切保持（有保持才記事件、重新規劃）；回 nb 方便呼叫端直接 return。keep 當場回一般值：recover／route 兩個
-- 站點不經掃描輪的 setLaneBias，不重設就讓下一輪之前的 laneBias 照舊不夾（Drive.laneKeepOf）。
function Drive.transitionRelease(s, playerNum, why, nb)
    if finite(s.holdLaneL) then
        diagEvent(s, playerNum, "lane", { phase = "release", why = why, l = s.lastLatSigned, offL = s.holdLaneL,
            rs = s.lastSNow })
        s.holdLaneL, s.planSig = nil, -1
        s.fstate.laneKeep = Drive.laneKeepOf(s)
    end
    return nb
end

-- 繞行釋放時車身不在接下來要跟的線上（1004a）：線尾釋放後期望線一幀跳回常駐線（承諾期間 laneBias 凍結、
-- 常駐線隨路面對中漂走），規劃只問常駐線，車身實際要掃過的是「車位→常駐線」那段——與起步同型，用同一個
-- 前半車身淨距限速，對正 START_GUARD_HOLD_MS 或開過 START_GUARD_MAX_M 自動解除。正式服 0.18.2 Sixya clip-11
-- 與 MI clip-01 同一點：舊出口線上距車鼻 1m 的物件，釋放後判 clear、5→17 km/h 撞上。
-- 只擋加速、不減速（帽不低於釋放時的車速）：起步包絡用滑行減速度、又把之後開過的距離當成正朝物件開，高速釋放時
-- 路邊任何東西都會把帽壓到十幾 km/h（E2E 1004a replay：45 km/h 繞完一放手就被壓到 12 km/h）；要擋的是低速
-- 放手後加速撞上，真的擋在線上的東西由判堵／接觸處理。
function Drive.armReleaseGuard(s)
    local lat, x, y = s.lastLatSigned, s.frontClearX, s.frontClearY
    if not finite(lat) or not finite(x) or not finite(y) then return end
    local home = s.laneChained and laneBiasOf(s) or s.residentBias
    if not finite(home) then home = laneBiasOf(s) end
    local dev = lat - home
    if dev > TUNE.START_GUARD_LAT_M or dev < -TUNE.START_GUARD_LAT_M then
        Drive.armStartGuard(s, x, y)
        s.startGuardRelease = true
    end
end

-- 鏈式停留時擋常駐線的那群夠遠（1004a）：回到常駐線、再為那群側移出去，兩段側移以目前車速的設計長
-- （MDADDynamics.shiftLength，同 shapeProfile）都塞得進車頭到那群偏到位點 b 之間＝現在解鏈回路上，那群照
-- 一般繞行處理；塞不進才續鏈（「貼北緣直到過了 A 再回來」）。舊制看整個感知窗（高速 100m 以上）：遠處還有
-- 任何擋常駐線的東西，車就一直沿停留 lane（常在路外）開，直到轉彎或殭屍／屍體減速把窗縮短（玩家回報）。
function Drive.chainBlockerFar(s, b, speedKmh)
    local aLat, vp = s.horizonMinLat, s.vehicleProfile
    if not finite(b) or not finite(aLat) or aLat <= 0 or not finite(speedKmh) then return false end
    local resident = s.residentBias or s.sandBias
    local dl = laneBiasOf(s) - (finite(resident) and resident or 0)
    if dl < 0 then dl = -dl end
    local v = speedKmh < 0 and -speedKmh or speedKmh
    local k = MDADDynamics.steeringKappa(vp.wheelbase, vp.delta0Safe, vp.deltaVSafe, vp.maxSpeed,
        v > MDADDynamics.DODGE_SQUEEZE_CAP and v or MDADDynamics.DODGE_SQUEEZE_CAP)
    if k <= 0 then k = 1 / 6 end
    local one = MDADDynamics.shiftLength(dl, v / 3.6, aLat, k, vp.halfL, MDADDynamics.LATERAL_JERK_MAX)
    return b - s.lastSNow - s.bodyReach > 2 * one
end

-- 離線過遠（TUNE.ROUTE_FAR_MS）：回 true＝持續過遠，呼叫端以 RouteTooFar 交還。第一次超過就
-- 讓下一幀重新向主 MOD 取路（主 MOD 偏航超過 12 格會自己重算）。
function Drive.routeFarWatch(s, now)
    local lat = s.lastLatSigned
    if not finite(lat) or (lat < TUNE.SNAP_MAX_M and lat > -TUNE.SNAP_MAX_M) then
        s.routeFarSince = 0
        return false
    end
    if s.routeFarSince == 0 then
        s.routeFarSince = now
        s.nextRouteMs = 0
        return false
    end
    return now - s.routeFarSince >= TUNE.ROUTE_FAR_MS
end

-- 調頭大弧卡住（0928b；E2E replay：車頭朝北、路線往南，車周探測被擋＝走大弧前進，但擋住車頭的東西在路線
-- 反方向、走廊掃不到——引擎 3000 轉、車 0 km/h 原地 15 秒後 StopStuck）。探測被擋、要前進又連續
-- ROTATE_STALL_MS 不動＝前方沒有大弧空間：請求倒車創造空間（後方探測照樣把關、額度照舊）。
-- 每幀都要呼叫以維持計時；原地耦力旋轉（探測淨空）與真的在動都不算。
function Drive.rotateStall(s, now, targetSpeed, avProgress)
    if s.intentShadow ~= "ROTATE" or s.rotProbeClear == true or not (targetSpeed > 0) or avProgress >= 1 then
        s.rotateStallSince = 0
        return false
    end
    if s.rotateStallSince == 0 then s.rotateStallSince = now end
    return now - s.rotateStallSince >= TUNE.ROTATE_STALL_MS
end

-- Traction-keyed online observation. Every field lives in the session table;
-- stable frames only mutate scalars and call no Java getter.
local function updateTraction(s, now, speedKmh, heading, headingError, latDev)
    local surface = s.currentSurfaceId
    if not finite(surface) then surface = 0 end
    local wet = s.rain ~= false
    local missing = s.vehicleProfile.isAnyTireMissing
    local tireKey = missing == true and 1 or (missing == false and 0 or 2)
    local rawOff = s.physicalOffroad == true
    if rawOff ~= s.tractionOffroad then
        if s.offroadFlipSince == 0 then s.offroadFlipSince = now end
        if now - s.offroadFlipSince >= TUNE.OFFROAD_KEY_DEBOUNCE_MS then
            s.tractionOffroad, s.offroadFlipSince = rawOff, 0
        end
    else
        s.offroadFlipSince = 0
    end
    local key = surface + (wet and 4 or 0) + tireKey * 8
        + (s.tractionOffroad and 32 or 0)
    local keyChanged = key ~= s.tractionKey
    if keyChanged then
        local oldKey = s.tractionKey
        s.tractionKey = key
        if oldKey ~= -1 then
            s.dynamicsDirty, s.dynamicsCapMaterial = true, false
            diagEvent(s, s.playerNum, "dyn", {
                phase = "dirty", why = "key", kind = tostring(oldKey) .. ">" .. tostring(key),
            })
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

    local aDrive, aBrake, aLat, _, _, aCoast = MDADVehicleProfile.priors(
        s.vehicleProfile, s.runtimeMass, surface, s.rain,
        s.tractionOffroad, s.adaptive)
    s.priorAccel, s.priorBrake, s.priorLat, s.priorCoast = aDrive, aBrake, aLat, aCoast

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
    local sampleBrake = stable and brakeWindow and speedKmh >= 8
    if not sampleBrake then s.brakeSampleMs = 0 end

    local coastQual = false
    if stable then
        local dv = (v - s.kinPrevV) / dt
        if brakeWindow or s.forceBrakePrev then
            if sampleBrake then
                if s.brakeSampleMs == 0 then
                    -- 指令後首幀只開窗，不把尚未作用的單幀差分當成能力。
                    s.brakeSampleMs, s.brakeSampleV = now, v
                elseif now - s.brakeSampleMs >= TUNE.BRAKE_SAMPLE_MS then
                    local sampleDt = (now - s.brakeSampleMs) / 1000
                    local obs = (s.brakeSampleV - v) / sampleDt
                    -- 只保留緊急先驗以內的能力，排除高峰對dev的膨脹；
                    -- 弱煞車與高速零減速仍是有效觀測，不加能力地板。
                    obs = math.max(0, math.min(obs,
                        aBrake * TUNE.EMERGENCY_BRAKE_GAIN, TUNE.EMERGENCY_BRAKE_MAX))
                    if s.brakeTime == 0 then s.brakeMean = obs end
                    s.brakeMean, s.brakeDev, s.brakeTime,
                        s.brakeConfidence, s.brakeLower = MDADVehicleProfile.updateEWMA(
                            s.brakeMean, s.brakeDev, s.brakeTime, obs, sampleDt)
                    s.brakeSampleMs, s.brakeSampleV = now, v
                end
            end
        elseif s.regulatorPrev and s.targetPrev > s.kinPrevV * 3.6 + 1 then
            local obs = dv
            if obs < 0 then obs = 0 end
            if s.accelTime == 0 then s.accelMean = obs end
            s.accelMean, s.accelDev, s.accelTime,
                s.accelConfidence, s.accelLower = MDADVehicleProfile.updateEWMA(
                    s.accelMean, s.accelDev, s.accelTime, obs, dt)
        elseif (not s.regulatorPrev
                or s.kinPrevV * 3.6 >= s.targetPrev + 1) and v >= 2.2
                and not (s.visAssistPrev > 0) then
            -- coast 資格＝「確定斷油」（2026-09-04 issue #1 定罪 D）：舊條件
            -- `targetPrev <= 實速+1` 把定速巡航（實速在目標 ±1 內）也當滑行學，
            -- 但引擎是 bang-bang（CarController.java:240-245：speedLimited <
            -- regulatorSpeed 才供油），那個區間一半的幀在供油、一半斷油，obs 是
            -- 0 與 0.6 的混合 → dev≈mean → lower→0 → safeCoast 0.67 秒內跨 material
            -- 門檻＝直路定速必觸發全剖面重建。實速 ≥ 目標+1（≥ 整數化 regulator
            -- 命令）時 isGas 必為 false，學到的才是真滑行；MP fake speed 只會更早
            -- 斷油，條件仍成立。目標 ±1 的曖昧帶不學（accel 分支同樣 +1 對稱）。
            -- 低速門檻（2026-09-01 telemetry 001 死亡螺旋定罪）：低速滑行阻力∝v²、
            -- 量測值天然趨 0——那是物理下限不是車輛能力，≥8 km/h（2.2 m/s）才學。
            -- 逐幀差分在高幀率下是 0／大值雙峰（物理固定 0.01s 子步，WorldSimulation.java:80-100；
            -- 250 FPS 時多數幀沒有子步、dv=0）——均值對、離散卻≈均值，lower＝均值−k·dev 一路收到
            -- 0，safeCoast 歸零＝剖面目標 0、min-exec 8 km/h 爬完全程（2026-09-27 E2E vis-sp：
            -- fdt 3-4ms、cl 7.9→0，68 秒起 8 km/h 爬 170 秒）。同煞車觀測（0911c）改用
            -- BRAKE_SAMPLE_MS 短窗淨減速；窗內出現加速＝那段其實在供油，整窗作廢不當 0 學。
            -- 巡航減速輔助（visAssistDecel）施力的幀不算滑行：它的減速不是車的能力。
            coastQual = true
            if s.coastSampleMs == 0 then
                s.coastSampleMs, s.coastSampleV = now, v
            elseif now - s.coastSampleMs >= TUNE.BRAKE_SAMPLE_MS then
                local sampleDt = (now - s.coastSampleMs) / 1000
                local obs = (s.coastSampleV - v) / sampleDt
                if obs >= 0 then
                    if s.coastTime == 0 then s.coastMean = obs end
                    s.coastMean, s.coastDev, s.coastTime,
                        s.coastConfidence, s.coastLower = MDADVehicleProfile.updateEWMA(
                            s.coastMean, s.coastDev, s.coastTime, obs, sampleDt)
                end
                s.coastSampleMs, s.coastSampleV = now, v
            end
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
    if not coastQual then s.coastSampleMs = 0 end
    s.kinPrevMs, s.kinPrevV, s.kinPrevH = now, v, heading

    local safeAccel = tightenLimit(aDrive, s.accelLower, s.accelConfidence,
        MDADVehicleProfile.ACCEL_CEIL)
    local safeBrake = tightenLimit(aBrake, s.brakeLower, s.brakeConfidence,
        MDADVehicleProfile.BRAKE_CEIL)
    local safeLat = tightenLimit(aLat, s.yawLower, s.yawConfidence,
        MDADVehicleProfile.LAT_CEIL)
    local safeCoast = tightenLimit(s.priorCoast, s.coastLower, s.coastConfidence,
        MDADVehicleProfile.COAST_CEIL)
    s.safeAccel, s.safeBrake, s.safeLat, s.safeCoast =
        safeAccel, safeBrake, safeLat, safeCoast
    MDADFollower.setRuntimeLimits(
        s.fstate, safeAccel, safeBrake, safeLat, safeCoast)
    if safeBrake <= 0.05 then s.dynamicsFault = true end
    -- material 重建判定（2026-09-04 issue #1 定罪 A/C）：線上估計從 prior 出發、
    -- 20 秒內單調滑向 lower（總行程 10-40%），舊門檻 2% 讓一次收斂就重建 5-20 次
    -- ——每次都是十幾幀掛 N。門檻改 20%（floor 照舊）：一次收斂最多 1-2 次；近端
    -- 安全不受影響（minBrakeVisible／horizonMin* 每幀 min(…, safe*)，Follower.control
    -- 的 stopLim／coastLim／curveCap 也讀 runtime limits），門檻只管烘進剖面的
    -- 遠端包絡刷新頻率。accel 不參與：segAccel 不進任何控制路徑（Follower 檔頭
    -- 「前向加速」），拿它重建＝白掛 N 換一份沒人讀的陣列（session-002 主觸發源）。
    if now >= s.nextDynamicsMs then
        local db = s.dynamicsBrakeCap - safeBrake
        local dl = s.dynamicsLatCap - safeLat
        local dc = s.dynamicsCoastCap - safeCoast
        if db < 0 then db = -db end
        if dl < 0 then dl = -dl end
        if dc < 0 then dc = -dc end
        local tb, tl, tc = s.dynamicsBrakeCap * 0.2,
            s.dynamicsLatCap * 0.2, s.dynamicsCoastCap * 0.2
        if tb < 0.05 then tb = 0.05 end
        if tl < 0.05 then tl = 0.05 end
        if tc < 0.02 then tc = 0.02 end
        local why = nil
        if db >= tb then why = "brake"
        elseif dl >= tl then why = "lat"
        elseif dc >= tc then why = "coast" end
        if why ~= nil then
            s.dynamicsDirty = true
            s.dynamicsCapMaterial = true
            s.nextDynamicsMs = now + 1000
            diagEvent(s, s.playerNum, "dyn", {
                phase = "dirty", why = why,
                cap = why == "brake" and s.dynamicsBrakeCap
                    or (why == "lat" and s.dynamicsLatCap or s.dynamicsCoastCap),
                safe = why == "brake" and safeBrake
                    or (why == "lat" and safeLat or safeCoast),
            })
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

-- 車身前進速度 |vLong|（km/h），給 applySteering 的低速側推縮放（TUNE.STEER_SLIP_MARGIN_KMH，1004b）。
-- 讀不到回 nil，呼叫端退回 |v|（＝1004a 以前的行為）。不共用 sampleVelocity：那條是診斷路徑、讀取錯誤要往上拋，
-- 控制路徑只能退回、不能中斷 session；pcall 直接帶參數，不配 closure。
function Drive.forwardKmh(vehicle, fx, fy)
    local okLookup, fn = pcall(jindex, vehicle, "getLinearVelocity")
    if not okLookup or type(fn) ~= "function" then return nil end
    local vel = BaseVehicle.allocVector3f()
    if vel == nil then return nil end
    local vLong = nil
    if pcall(fn, vehicle, vel) then
        local vx, vz = vel:x(), vel:z()
        if finite(vx) and finite(vz) then vLong = vx * fx + vz * fy end
    end
    pcall(BaseVehicle.releaseVector3f, vel)
    if vLong == nil then return nil end
    return (vLong < 0 and -vLong or vLong) * 3.6
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
    phys.residentBias, phys.zombieLane = s.residentBias, s.zombieLane
    -- 1005 soft：軟縫貼路緣（keep 0）、動物／玩家停等狀態（有才寫）
    phys.zombieKeep0 = (s.zombieKeep0 and s.zombieLane ~= nil) or nil
    phys.softHoldKind = s.softHoldKind
    phys.softHoldMs = s.softHoldKind ~= nil and s.softHoldMs or nil
    phys.softCrawl = s.softCrawl or nil
    -- 1005 soft4：gentle 動物接近帽（有才寫）、動物爬行累計 ms（爬行中才寫）
    phys.softGentleCap = (finite(s.softGentleCapKmh) and s.softGentleCapKmh >= 0) and s.softGentleCapKmh or nil
    phys.softCrawlMs = s.softCrawl and s.softCrawlMs or nil
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
    if finite(s.accelAssist) and s.accelAssist > 0 then phys.accelAssist = s.accelAssist end
    if finite(s.assistBoost) and s.assistBoost > 1 then phys.assistBoost = s.assistBoost end -- 1004e：越野推力遞增倍率（>1 才寫）
    if (s.relayN or 0) > 0 then phys.relayN = s.relayN end
    if (s.bushContactN or 0) > 0 then phys.bushContact = s.bushContactN end -- 1004d：本幀抵消的樹叢數（Drive.bushCancel）
    phys.priorAccel, phys.priorBrake, phys.priorLat =
        s.priorAccel, s.priorBrake, s.priorLat
    phys.priorCoast = s.priorCoast
    phys.followerTarget, phys.desiredTarget = s.followerTarget, s.desiredTarget
    -- forceBrake 一秒閂鎖的剩餘時間與最後觸發原因（Codex lane 2026-09-07：hbr／fbt 只記當幀，5-10Hz
    -- 取樣漏掉觸發幀 → 23 段「弧內停住」被誤判成輪胎飽和；`ib=true tn=0` 才是引擎在煞車）
    local fbLeft = s.forceBrakeUntil - getTimestampMs()
    phys.forceBrakeLeft = fbLeft > 0 and fbLeft or 0
    phys.forceBrakeWhy = s.forceBrakeWhy
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
    if finite(s.maxSpeed) and s.maxSpeed > 0 then phys.capMax = s.maxSpeed end -- 沙盒上限（上傳摘要的有效上限用；不進取樣）
    -- 1005i 預計剩餘：HUD 顯示的秒數（計畫剩餘×k）與修正倍率 k（遙測 eta／etk）
    if finite(s.etaSec) then
        phys.etaSec = math.floor(s.etaSec * 10 + 0.5) / 10
        phys.etaK = math.floor(s.etaK * 1000 + 0.5) / 1000
    end
    if s.returnActive then
        phys.capOffroad = s.returnUnsafe and TUNE.RETURN_UNSAFE_CAP or TUNE.RETURN_CAP
        phys.capReturn = phys.capOffroad
    end
    if s.blocked and not s.returnActive then
        if Drive.blockedAtStop(s, vehicle:getX(), vehicle:getY()) then
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
    -- 被 MIN_EXEC 抬前的理由只在 min-exec 幀送（console 狀態列 cap=min-exec(<from>) 的 telemetry 對應；
    -- 殘值不污染其他幀）
    if s.lastCapReason == "min-exec" and type(s.minExecFrom) == "string" then
        phys.minExecFrom = s.minExecFrom
    end
    phys.fullGate = s.fullGate
    phys.gateReason = s.gateReason
    phys.cmdV, phys.cmdA = s.cmdV, s.cmdA
    phys.jerkBypass = s.jerkBypassReason
    phys.curveKappa, phys.curveCap = s.curveKappa, s.curveCap
    phys.curveValid = s.curveValid
    phys.curveHardActive = s.curveHardActive
    phys.ffSteer = s.fstate.ffSteer
    phys.yawGain, phys.appliedSteer = s.fstate.yawGain, s.fstate.appliedSteer
    phys.yawGainHi, phys.yawGainFb = s.fstate.yawGainHi, s.fstate.yawGainFb
    if finite(s.fbNorm) and s.fbNorm > 1 then phys.fbNorm = s.fbNorm end
    if finite(s.armExt) and s.armExt > 1 then phys.armExt = s.armExt end
    if s.dodgeAlignHold == true then phys.dodgeAlignHold = true end
    phys.routeHeadingError, phys.kinkExitS = s.lastRouteErr, s.fstate.kinkExitS
    phys.visibilityCap = s.visibilityCap
    phys.visibilityHardKmh = s.visibilityHardKmh
    phys.visHold, phys.visRoundS, phys.visAssistDecel = s.visHold, s.visRoundS, s.visAssistDecel
    if finite(s.visAssistDecel) and s.visAssistDecel > 0 then phys.visAssistWhy = s.visAssistWhy end
    if s.tow then
        phys.towPhi, phys.towUp, phys.towDecel, phys.towBrake = s.towPhi, s.towUp, s.towAssistDecel, s.towBrakeWhy
    end
    phys.curveVerifiedUntilS = s.curveVerifiedUntilS
    phys.filletN = s.profile.filletN
    phys.filletFallbackN = s.profile.filletFallbackN
    phys.dodgeKappa = s.dodgeKappa
    phys.dodgeClearance = s.dodgeClearance
    phys.dodgeCurveCap = s.dodgeCurveCap
    phys.dodgeClearanceCap = s.dodgeClearanceCap
    phys.dodgeVisibilityCap = s.dodgeVisibilityCap
    phys.dodgeSpaceCap = s.dodgeSpaceCap
    phys.dodgeEntryPassed = s.dodgeEntryPassed == true
    phys.dodgeBaseCap, phys.dodgeCapPending =
        s.dodgeBaseCap, s.dodgeCapPending
    phys.dodgeApproachCap = s.dodgeApproachCap
    phys.zombieLaneCap = s.zombieLaneCap
    phys.dodgeDesignSpeed = s.dodgeDesignSpeed
    phys.dodgeSpeedCap = s.dodgeSpeedCap
    phys.dodgeHoldCap = s.dodgeHoldCap
    phys.dodgeNextStopS = s.dodgeNextStopS
    phys.dodgeNextCap = s.dodgeNextCap
    phys.dodgeNextX, phys.dodgeNextY, phys.dodgeNextR = s.dodgeNextX, s.dodgeNextY, s.dodgeNextR
    phys.dodgeEnvN = s.dodgeEnvN
    phys.dodgeClass = s.dodgeClass
    phys.verifyLineReason = s.verifyLineReason
    phys.proofHitS = s.proofHitS -- 1005：證明線掃掠命中的車身取樣弧長（gate sweep 接近包絡的終點）
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
    phys.laneChained = s.laneChained == true
    phys.dodgeTier = s.dodging and s.dodgeTier or nil
    phys.stateError, phys.invalid = s.stateError, s.invalid
    -- 2026-09-04 issue #1/#2 復盤缺口：兩份報告都數不出 forceBrake／build 次數、
    -- 量不到玩家 fps——只能從取樣間隔反推。三個純量補上。
    phys.hardBrakeReason = s.lastHardBrakeReason
    phys.forceBrakeThis = s.forceBrakeThis
    phys.brakeAssistForce = s.brakeAssistForce
    phys.frameMs = s.frameMs
    -- replan 牆鐘（現場分佈；Drive.replanElapsed）：每次量測只寫一筆
    if s.replanWallFresh then
        phys.replanMs, phys.replanSweeps, phys.replanHn = s.replanWallMs, s.replanSweeps, s.replanHn
        s.replanWallFresh = nil
    end
    -- 0928a：前方區域未載入等待／車身 yaw 率與限制比例／起步近物限速與前半車身淨距
    if s.areaWaitActive then phys.areaWait = true end
    phys.yawRate = s.yawRate
    if finite(s.escScale) and s.escScale < 1 then phys.escScale = s.escScale end
    if s.startGuard then phys.startGuard = true end
    phys.frontClearance = s.frontClearance
    -- 0929c：HUD「卡頓降速」狀態（Drive.updateLowFps 遲滯後的結果；事件只記切換，片段的事前事件會被預算裁掉）
    if s.lowFps then phys.lowFps = true end
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
    ["rotate-stall"] = 2,   -- 調頭走大弧卻原地不動（Drive.rotateStall）
    ["start-near"] = 2,     -- 起步近物限速停在物件前不動（Drive.startNearStall）
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

-- RETURN 待命只斷油前，核對滑行停得住（2026-09-27 正式服 M998 片段：RETURN hold 後 target 0
-- 只斷油，17 km/h 滑到 footprint 重疊才硬煞，撞上正前方硬物）。沿車頭方向、車身寬帶內找快照
-- 裡最近的硬點：滑行停止距離（反應 0.3s＋v²/2·safeCoast＋0.5）放得下才准只斷油，放不下走
-- 既有硬煞。側邊擋住回線但正前方淨空的，仍只滑行（不多一次一秒鎖輪）。out 會被 bodyCenter
-- 覆寫；fx/fy 是已正規化的車頭方向。冷路徑：只在 RETURN hold 滑行條件都成立時呼叫。
function Drive.returnCoastClear(s, vehicle, out, fx, fy, speedKmh)
    local sen = s.sensor
    if type(sen) ~= "table" or not sen.ready then return false end
    local bx, by = bodyCenter(s, vehicle, out)
    if bx == nil or not finite(fx) or not finite(fy) then return false end
    local vp = s.vehicleProfile
    local v = (speedKmh < 0 and -speedKmh or speedKmh) / 3.6
    local coast = finite(s.safeCoast) and s.safeCoast > 0.5 and s.safeCoast or 0.5
    local need = v * 0.3 + v * v / (2 * coast) + 0.5
    local hx, hy, hr = sen.hardX, sen.hardY, sen.hardR
    for i = 1, sen.hardN do
        local dx, dy = hx[i] - bx, hy[i] - by
        local u = dx * fx + dy * fy
        if u > 0 then
            local r = hr[i] or 0
            local w = dy * fx - dx * fy
            if w < 0 then w = -w end
            if w < vp.halfW + r + TUNE.RETURN_COAST_PAD and u - vp.halfL - r < need then return false end
        end
    end
    return true
end


-- 後方 swept-strip 探測的共用包裝（recovery 起手與 unstick 每 100ms 重查共用）：
-- bodyCenter 取不到、或 Sensor 缺席，都回 unloaded 而非 clear——呼叫端一律以
-- status ~= "clear" 判定不可倒車。out 會被 bodyCenter 覆寫成世界座標，呼叫端必須
-- 先取完 forward 分量；fx/fy 需已正規化。
local function rearProbe(s, vehicle, out, fx, fy, vx, vy, travelM)
    local bx, by = bodyCenter(s, vehicle, out)
    if bx == nil or type(MDADSensor) ~= "table"
            or type(MDADSensor.probeRear) ~= "function" then
        return "unloaded", vx, vy, "geometry", "body center or rear probe unavailable"
    end
    local halfW, halfL = s.vehicleProfile.halfW, s.vehicleProfile.halfL
    if s.tow then
        -- 拖車倒車：先撞到的是掛車尾，探測框改成掛車車身沿掛車航向往後
        local tx, ty, tfx, tfy, thw, thl = MDADTrailer.body(s.tow)
        if tx == nil then return "unloaded", vx, vy, "geometry", "trailer body unavailable" end
        bx, by, fx, fy, halfW, halfL = tx, ty, tfx, tfy, thw, thl
    end
    return MDADSensor.probeRear(s.sensor, vehicle, getCell(), bx, by, fx, fy, -fy, fx,
        halfW, halfL, travelM or REAR_TRAVEL_M)
end


local function noteProbeError(s, where, status, kind, detail)
    if s.probeErrorLogged or type(detail) ~= "string" or detail == "" then return end
    s.probeErrorLogged = true
    print(LOG .. where .. " probe fail-closed status=" .. tostring(status)
        .. " kind=" .. tostring(kind) .. " detail=" .. detail)
end

-- recovery 只 ban 真正卡住的車道；承諾 offL 可能仍在車前、尚未走到。
-- 真命中／近場非淨空與「本 episode 尚未 ban」由兩個呼叫端把關。
local function banRecoveryLane(s, latSigned, anchorS)
    local lane = latSigned
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

    local blocked, actual, planned, hitI, hitS, hitL, hitX, hitY, poseOnly, front
    local bx, by = bodyCenter(s, vehicle, out)
    local idx = s.fstate.idx or 1
    local routeH = s.profile.segH[idx]
    if bx == nil or not finite(routeH) then
        blocked, actual, planned, hitI, hitS, hitL, hitX, hitY, poseOnly =
            true, 0, 0, 0, 0, 0, 0, 0, false
    elseif type(MDADCorridor) == "table"
            and type(MDADCorridor.currentFootprintHit) == "function" then
        -- 貼縫承諾執行中 contact 圈與承諾同源（2026-09-04 s063/s064：offL 2.00 margin 0.05
        -- 物理檔承諾，5 km/h 走到一半 contact 就煞停、倒車、再 commit 同一條、三次交還——
        -- 「只差一點點」）：物理檔 sweepBase＝halfW−0.1 允許 10cm 名義重疊，contact 卻要
        -- 15cm 淨空，兩套標準必然衝突。dodging 且承諾檔低於巡航時 pad＝dodgeNeed−halfW
        -- （物理檔＝−0.1，與掃掠同一個名義重疊；0904r：pad 0 時 s@164855 兩次在 lat 1.4/1.6
        -- 「還沒撞到」就 contact——差的正是這 0.1）。Corridor 逐點夾 r+pad ≥ 0，車身內仍停。
        local pad = nil
        if s.dodging and finite(s.dodgeNeed) and s.dodgeNeed < s.sweepBase - 1e-6 then
            pad = s.dodgeNeed - s.vehicleProfile.halfW
        end
        -- 承諾線的 pre-a 段（a 之前＝路線本身）掃掠只以 SWEEP_PHYS_PAD 驗物理必撞（sweepLine
        -- pointPad）；執行 contact 若仍用預設 0.15，完美跟到已接受的線也會被判接觸（2026-09-27
        -- 正式服 SemiBox：pre-a sweep +0.029 淨空、contact −0.071 命中，真 Corridor 重現）。
        -- 車還在 a 之前時兩邊同一個數。
        if s.dodging and finite(s.fstate.offA) and s.lastSNow < s.fstate.offA
                and (pad == nil or pad > SWEEP_PHYS_PAD) then
            pad = SWEEP_PHYS_PAD
        end
        blocked, actual, planned, hitI, hitS, hitL, hitX, hitY, poseOnly, front =
            MDADCorridor.currentFootprintHit(
                sen.hardS, sen.hardL, sen.hardX, sen.hardY, sen.hardR, sen.hardN,
                bx, by, heading, s.vehicleProfile.halfW, s.vehicleProfile.halfL,
                expectedLaneOf(s), pad, sen.hardB)
    else
        -- Corridor 是選配；缺它不能做 OBB 判定，但仍須保留 M3 pure follower。
        blocked, actual, planned, hitI, hitS, hitL, hitX, hitY, poseOnly =
            false, 99, 99, 0, 0, 0, 0, 0, false
    end
    s.actualClearance, s.plannedClearance = actual, planned
    -- 前半車身最近硬物淨距＋量測時的車位（起步近物限速逐幀扣掉之後開過的距離；Drive.startGuardApply）
    s.frontClearance, s.frontClearX, s.frontClearY = front, vx, vy
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
        -- 擦過就算過：contact 沒倒車、車身已整個越過命中點＝那個障礙在車後，
        -- recovery ban（車前 9m 的虛擬障礙、r 0.6）不再有意義。留著＝下一次 replan
        -- 把它當前方擋線點 → 進入段太短全候選 steep → blocked 停在空路上 → 後方正是
        -- 剛擦過的桿 → 倒不了 → 15s StopStuck（2026-09-04 s025 st185,813-827，路口電線桿）。
        if s.pushBanL ~= nil and s.banFromRecovery and s.episodeAttempts == 0
                and finite(s.episodeHitS) and s.episodeHitS > 0
                and s.lastSNow > s.episodeHitS + s.vehicleProfile.halfL + 1 then
            s.pushBanL, s.pushBanS = nil, 0
            s.banFromRecovery = false
            diagEvent(s, playerNum, "progress", { phase = "ban-passed", eid = s.episodeId,
                s = s.lastSNow, hitS = s.episodeHitS })
            if getDebug() then
                print(string.format("%spn=%d recovery ban dropped: passed hit point (rs=%.1f hitS=%.1f)",
                    LOG, playerNum, s.lastSNow, s.episodeHitS))
            end
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
            rearmed = dx * dx + dy * dy >= TUNE.EPISODE_REARM_SQ
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

-- 本次倒車要比標準 3m 多退多少（公尺）。兩個來源：
-- ① 貼縫 contact（episodeReason contact 且承諾中）＝進入段太短：第 N 次多退 N×UNSTICK_DODGE_EXTRA_M；
-- ② 全滅含 steep 拒收＝跑道不夠：一次退到夠（見 shapeProfile 的 steepDeficitM；只在 blocked 停等到期的
--    倒車生效，contact／進度倒車不吃）。
-- 兩者都是「沿路線退出進入段跑道」；車身對路線斜著時，倒 d 公尺只換到 d·cos(誤差) 的跑道、其餘全是
-- 往路外橫移（2026-09-27 E2E startpush-sp＝正式服 c25 同位置：StepVan 垂直停在碎石路旁 5m，steep 把
-- 倒車加到 11m，實際沿線 s 一直是 0、車退到離路 27m 觸發 RouteTooFar）。車頭對路線超過
-- UNSTICK_EXTRA_ALIGN_RAD 就不加長，維持標準倒車。
function Drive.unstickExtraM(s)
    local extra = 0
    if s.episodeReason == "contact" and s.dodging and s.dodgeCrawl then
        extra = TUNE.UNSTICK_DODGE_EXTRA_M * s.episodeAttempts
    end
    if s.blocked and finite(s.blockSteepM) and s.blockSteepM > extra then extra = s.blockSteepM end
    if extra > 0 and finite(s.lastRouteErr) and s.lastRouteErr > TUNE.UNSTICK_EXTRA_ALIGN_RAD then extra = 0 end
    return extra
end

-- 交還前的最後一次改道（0928m 使用者裁定「遇大量障礙可改道」）：舊觸發只在「blocked 停等 WAIT」成立，
-- 實際堵死多半先走倒車鏈、額度用完才在停等預算／倒車逾時交還——E2E rc13 12 個固定堵點案開著自動改道
-- 仍 0 次改道。交還前若選項開著、本 session 額度未滿、不在上次問過的地方，就先要一條避開前方的替代
-- 路線（繞遠上限放寬到拖車調頭同一套）；拿到＝重置停等預算繼續開，拿不到＝照常交還。
function Drive.stuckDetour(s, playerNum)
    local vx, vy = s.vehicle:getX(), s.vehicle:getY()
    local px, py = s.stuckDetourX, s.stuckDetourY
    -- 沒問就交還的三種原因各記一筆（phase＝skip，不觸發片段）：舊制靜默 return，正式服 0.18.2 開著自動改道的受困交還
    -- 沒有任何改道紀錄，分不出是選項關、這趟額度用完，還是在上次問過的地方附近
    local skip = nil
    if not (type(MDAD.HUD) == "table" and type(MDAD.HUD.autoDetour) == "function"
            and MDAD.HUD.autoDetour() == true) then
        skip = "off"
    elseif (s.stuckDetourN or 0) >= TUNE.STUCK_DETOUR_MAX then
        skip = "max"
    elseif finite(px) and finite(py) and (vx - px) * (vx - px) + (vy - py) * (vy - py)
            < TUNE.STUCK_DETOUR_NEAR_M * TUNE.STUCK_DETOUR_NEAR_M then
        skip = "near"
    end
    if skip then
        diagEvent(s, playerNum, "detour", { phase = "skip", why = skip, x = vx, y = vy, s = s.lastSNow,
            ms = s.waitAccumMs, attempt = s.episodeAttempts })
        return false
    end
    s.stuckDetourN = (s.stuckDetourN or 0) + 1
    s.stuckDetourX, s.stuckDetourY = vx, vy
    local ok = Drive.requestDetour(playerNum, true) -- 事件由 requestDetour 記（phase＝stuck）
    if not ok then return false end
    s.mode, s.recoverWhy = "follow", nil
    s.progressState, s.progressSince = "disarmed", 0
    s.waitAccumMs, s.episodeAttempts, s.blockRetryDone, s.detourTried = 0, 0, false, true
    return true
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
        if Drive.stuckDetour(s, playerNum) then return end
        Drive.stop(playerNum, KEY_STUCK)
        return
    end

    local out = BaseVehicle.allocVector3f()
    vehicle:getForwardVector(out)
    local fx, fy = out:x(), out:z()
    local flen2 = fx * fx + fy * fy
    local status, hitX, hitY, kind, detail, travel = "unloaded", vx, vy, "geometry",
        "invalid forward vector", 0
    if flen2 > 1e-6 then
        local inv = 1 / sqrt(flen2)
        fx, fy = fx * inv, fy * inv
        -- 階梯縮帶：4m 帶清＝退標準距；命中硬物／車（非 unloaded）就縮帶再探，第一個
        -- 清的帶長決定本次退距（帶長−KEEP）。
        status, hitX, hitY, kind, detail = rearProbe(s, vehicle, out, fx, fy, vx, vy)
        travel = REAR_TRAVEL_M
        if status ~= "clear" and status ~= "unloaded" then
            local short = TUNE.REAR_TRAVEL_SHORT_M
            local s2, x2, y2, k2, d2 = rearProbe(s, vehicle, out, fx, fy, vx, vy, short)
            if s2 == "clear" then
                status, hitX, hitY, kind, detail, travel = s2, x2, y2, k2, d2, short
            else
                local least = TUNE.UNSTICK_MIN_M + TUNE.REAR_KEEP_M
                if least < short then
                    s2, x2, y2, k2, d2 = rearProbe(s, vehicle, out, fx, fy, vx, vy, least)
                end
                if s2 == "clear" then
                    status, hitX, hitY, kind, detail, travel = s2, x2, y2, k2, d2, least
                else
                    travel = 0
                end
            end
        end
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
        if Drive.stuckDetour(s, playerNum) then return end
        Drive.stop(playerNum, KEY_STUCK)
        return
    end

    s.episodeAttempts = s.episodeAttempts + 1
    s.unstickExtraM = Drive.unstickExtraM(s)
    -- 倒車＝把跑道退出來；停留段終點的進入段地板（stayHoldEndS）此後只會把退出來的跑道
    -- 再吃掉（2026-09-04 st174,596-616：退 3／7／11m 三次，entry 恆 5.6＝c 到縫口，唯一的
    -- +2.0 縫 ratio 1.7 永遠拒 → StopStuck）。從退後的位置重規劃，A 由掃掠把關。
    s.stayHoldEndS = nil
    Drive.transitionRelease(s, playerNum, "recover", nil) -- 倒車後從新位置重判斜切帶
    Drive.armStartGuard(s, vx, vy) -- 倒完又是從障礙旁起步（TUNE.START_GUARD_*）
    s.rotateStallSince = 0
    -- 短帶＝本次退距上限（帶長−KEEP）；標準帶維持 UNSTICK_DIST（含 extra 的加長由 100ms
    -- 重探沿途把關，與舊制相同）。
    s.unstickTravelM = travel < REAR_TRAVEL_M and (travel - TUNE.REAR_KEEP_M) or 0
    s.unstickX, s.unstickY = vx, vy
    s.unstickUntil = now + UNSTICK_MS
    s.unstickStartedAt = now
    s.nextRearProbeMs = now + REAR_PROBE_MS
    s.unstickDistance = 0
    s.reverseForce = 0
    s.mode = "unstick"
    s.dodgeHandoffHold, s.dodgeDeferCap = false, -1
    s.progressState = "recover"
    diagEvent(s, playerNum, "unstick", {
        phase = "start", eid = s.episodeId, attempt = s.episodeAttempts,
        x = vx, y = vy, s = s.lastSNow, d = 0, rear = status, len = travel,
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
    -- 與 Follower 即時弧帽同一下限（MIN_SPEED 12）：折點格 κ→∞ 的解析式回 0 是公式極限
    -- 假象（2026-09-08 s048：調頭完成後 verifyEnvelope[1..2]=0 → fullGate 路徑 target 0、
    -- 停 37 秒），「解析公式只壓速不否決」通則。
    local floorKmh = MDADFollower.MIN_SPEED_KMH
    for k = 1, n do
        local cap = MDADDynamics.curveSpeedCapKmh(
            kappas[k], lat, vp.wheelbase, vp.delta0Safe, vp.deltaVSafe, vp.maxSpeed)
        if cap < floorKmh then cap = floorKmh end
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
-- 設定距離／未出現nil都不是世界證明；只認完成快照，車身前伸也要在其中。
-- 真路線末端沿既有抵達／coverEnd契約鉗齊，不在路線外虛構延長段。
function Drive.candidateCovered(s, endS)
    if not s.sensor.ready or not finite(endS) or not finite(s.bodyReach)
            or not finite(s.profile.length) then return false end
    return math.min(endS + s.bodyReach, s.profile.length)
        <= visibleEndS(s.sensor, s.lastSNow) + 1e-6
end

-- sweepLine 的失敗回傳（牽引車與掛車共用；冷路徑）。body＝"trailer" 時是掛車車身撞到。
function Drive.sweepHit(s, sen, tag, a, b, c, offL, sk, wx, wy, i, ox, oy, clearance, body)
    local phase
    if sk < a then phase = 1
    elseif sk < b then phase = 2
    elseif sk <= c then phase = 3
    else phase = 4 end
    s.sweepHitBody = body or "tractor" -- blocked 事件 kind：候選是牽引車還是掛車撞到（復盤拖車繞不過）
    if getDebug() then
        local key = tostring(tag or "?") .. offL
        local at = s.sweepLogAt
        if at == nil then at = {}; s.sweepLogAt = at end
        local nowMs = getTimestampMs()
        if (at[key] or 0) + TUNE.SWEEP_LOG_MS <= nowMs then
            at[key] = nowMs
            print(string.format(
                "%ssweep OBB fail[%s%s] p%d offL=%.2f @s=%.1f at=(%.1f,%.1f) hit#%d hw=(%.1f,%.1f) clearance=%.2f",
                LOG, tostring(tag or "?"), body and ("/" .. body) or "", phase, offL, sk, wx, wy,
                i, ox, oy or 0, clearance))
        end
    end
    return false, -clearance, (sen.hardS and sen.hardS[i]) or sk, phase, sk, ox, oy or 0, i
end

-- sweepLine 的逐點常數（每次呼叫重填前 hardN 格、只長不縮，不每次配置）：兩種 pad 的掃掠半徑與整格方塊半邊。
-- 內迴圈是 取樣×點數，原本每一對都做 type／sweepRadius／math.abs（Kahlua 裡都是函式呼叫）。不以快照為鍵快取：
-- pad 隨 needBase 每次呼叫不同，離線 fixture 也會原地改點雲；重填是 O(點數)，相對 O(取樣×點數) 可忽略。
-- 索引塊（每 TUNE.SWEEP_BLOCK_N 個連號點一塊）：塊內點的世界外框、兩種 pad 的最大半徑、最大方塊半邊。Sensor 依掃描
-- 順序收點，連號點在世界上相鄰；整塊都在剔除距離外就跳過整塊。跳過的點逐點剔除本來也會剔掉（外框＋塊內最大
-- 半徑是逐點剔除距離的上界，餘裕取塊首當下的值、塊內只會變小），塊內仍照索引順序逐點驗——首次命中、minI、淨距表不變。
Drive.sweepScratch = { rrPhys = {}, rrPad = {}, bh = {},
    bx0 = {}, bx1 = {}, by0 = {}, by1 = {}, bPhys = {}, bPad = {}, bBh = {} }
local function sweepLine(s, lx, ly, ln, lS0, lS1,
        a, b, c, d, offL, tag, needBase, startK, requireLoaded, collectClearance)
    local sen = s.sensor
    local clr = collectClearance and s.dodgeClr or nil
    local clrKeepS = nil
    if clr then
        local sameLine = s.dodgeClrN == ln and s.dodgeClrS0 == lS0 and s.dodgeClrS1 == lS1
        s.dodgeClrN, s.dodgeEnvN = 0, 0
        -- 縮窗後的未掃尾段不能被收成新的高淨距速度證明；同一條線之前看全時量到的逐點淨距照留，
        -- 只重量還看得到的那一段（1002o；E2E rc52 0004：表被清空後只剩整線帽 64、不含出口窄點，
        -- 表回來時窄點已在 10m 內，帽一步 64→11.6→5、從 64 km/h 減到 27 擦上）。
        if not Drive.candidateCovered(s, lS1) then
            if sameLine then clrKeepS = visibleEndS(sen, s.lastSNow) - s.bodyReach else clr = nil end
        end
    end
    if not finite(ln) or ln < 2 or not finite(lS0) or not finite(lS1) then
        return false, 99, s.lastSNow, 1, s.lastSNow, 0, 0
    end
    local lastStart = lS0 + (ln - 2) * MDADFollower.OV_STEP
    if lS1 <= lastStart
            or lS1 > lastStart + MDADFollower.OV_STEP + 1e-6 then
        return false, 99, s.lastSNow, 1, s.lastSNow, 0, 0
    end
    -- 新候選逐條驗實際輸出的線尾，不能沿用主候選的預檢；既有承諾的guard不重設視界。
    if requireLoaded and not Drive.candidateCovered(s, lS1) then
        s.dodgeBuildReason = sen.unloaded and "unloaded" or "coverage"
        return false, 99, visibleEndS(sen, s.lastSNow), 4, lS1, 0, 0
    end
    local hn = sen.hardN
    if hn == 0 then return true, 9 end
    local hx, hy, hr, hb = sen.hardX, sen.hardY, sen.hardR, sen.hardB
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
    local minMargin, minI = 9, nil
    local lastFx, lastFy = 1, 0
    if not finite(startK) then startK = 1 else startK = startK - startK % 1 end
    if startK < 1 then startK = 1 end
    if startK > ln then return true, minMargin end
    s.sweepCount = (s.sweepCount or 0) + 1 -- replan 牆鐘遙測的掃掠數（stepFollow 在 replan 前歸零）
    -- 半徑一律 ≥ SWEEP_PHYS_PAD > 0（sweepGeom 夾底、sweepRadius 補償後不低於物理 pad），內迴圈不必取絕對值。
    local sc = Drive.sweepScratch
    local rrPhysT, rrPadT, bhT = sc.rrPhys, sc.rrPad, sc.bh
    local comp = TUNE.SWEEP_QUANT_COMP
    local bx0, bx1, by0, by1, bPhys, bPad, bBh = sc.bx0, sc.bx1, sc.by0, sc.by1, sc.bPhys, sc.bPad, sc.bBh
    local BN = TUNE.SWEEP_BLOCK_N
    local nBlk, inBlk = 0, BN
    for i = 1, hn do
        local bh = hb and hb[i] or 0
        if type(bh) == "number" and bh > 0 then
            bhT[i], rrPhysT[i], rrPadT[i] = bh, SWEEP_PHYS_PAD, pad
        else
            bhT[i] = 0
            rrPhysT[i] = MDADDynamics.sweepRadius(hr[i], SWEEP_PHYS_PAD, SWEEP_PHYS_PAD, comp)
            rrPadT[i] = MDADDynamics.sweepRadius(hr[i], pad, SWEEP_PHYS_PAD, comp)
        end
        local x, y = hx[i], hy[i]
        if inBlk == BN then
            nBlk, inBlk = nBlk + 1, 0
            bx0[nBlk], bx1[nBlk], by0[nBlk], by1[nBlk] = x, x, y, y
            bPhys[nBlk], bPad[nBlk], bBh[nBlk] = rrPhysT[i], rrPadT[i], bhT[i]
        else
            if x < bx0[nBlk] then bx0[nBlk] = x elseif x > bx1[nBlk] then bx1[nBlk] = x end
            if y < by0[nBlk] then by0[nBlk] = y elseif y > by1[nBlk] then by1[nBlk] = y end
            if rrPhysT[i] > bPhys[nBlk] then bPhys[nBlk] = rrPhysT[i] end
            if rrPadT[i] > bPad[nBlk] then bPad[nBlk] = rrPadT[i] end
            if bhT[i] > bBh[nBlk] then bBh[nBlk] = bhT[i] end
        end
        inBlk = inBlk + 1
    end
    local ovStep = MDADFollower.OV_STEP
    local comX, comZ = s.vehicleProfile.centerOfMassX, s.vehicleProfile.centerOfMassZ
    -- 拖車（0929p）：沿候選線以 tractrix 推掛車（掛點走牽引車線、掛車軸無側滑，同 MDADTrailer.simulate），
    -- 掛車車身同樣逐點驗硬點——只驗牽引車時，繞過障礙後掛車內切會掃到剛閃過的東西。從車目前位置起算
    -- （起始軸向讀實車），車後的取樣點不推掛車；attach 量不到掛點偏移（沒有 trailLen）＝只驗牽引車。
    -- 只在寬帶規劃／寬帶繞行驗（Drive.towChecks）。
    local tw = Drive.towChecks(s)
    local tdx, tdy, tax, tay = nil, nil, nil, nil
    if tw and tw.trailLen and tw.trailer then
        local tv = BaseVehicle.allocVector3f()
        local okF = pcall(tw.trailer.getForwardVector, tw.trailer, tv)
        local ux, uy = tv:x(), tv:z()
        BaseVehicle.releaseVector3f(tv)
        local ul = okF and finite(ux) and finite(uy) and sqrt(ux * ux + uy * uy) or 0
        -- 軸向＝實車 forward×axisSign（被倒著拖的車 forward 朝後；MDADTrailer.attach）
        local sg = tw.axisSign or 1
        if ul > 1e-6 then tdx, tdy = sg * ux / ul, sg * uy / ul end
    end
    for k = startK, ln do
        local sk = k == ln and lS1
            or (lS0 + (k - 1) * ovStep)
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
        local sampleMargin = 9
        local rrT = sk < a and rrPhysT or rrPadT -- a 之前只驗物理必撞（SWEEP_PHYS_PAD），之後用檔位 pad
        local bodyX = wx + fx * comZ + fy * comX
        local bodyY = wy + fy * comZ - fx * comX
        local afx, afy = fx < 0 and -fx or fx, fy < 0 and -fy or fy
        local extentX = afx * halfL + afy * halfW
        local extentY = afy * halfL + afx * halfW
        -- 整格方塊（sen.hardB，0929j）：以方塊在車身兩軸的外框加寬車身 OBB，只留 pad 當半徑；軸對齊時與引擎
        -- 方塊一致（圓近似在軸向多估 0.2），斜向略保守。圓點照舊 sweepRadius。
        local boxK = afx + afy
        local tbx, tby, tex, tey, tboxK = nil, nil, 0, 0, 0
        if tdx and sk >= s.lastSNow then
            local hxw = wx + fx * tw.hitchZ + fy * tw.hitchX
            local hyw = wy + fy * tw.hitchZ - fx * tw.hitchX
            if tax then
                local vx, vy = hxw - tax, hyw - tay
                local vl = sqrt(vx * vx + vy * vy)
                if vl > 1e-6 then tdx, tdy = vx / vl, vy / vl end
            end
            tax, tay = hxw - tdx * tw.L2, hyw - tdy * tw.L2
            tbx = hxw - tdx * tw.boxBack + tdy * tw.boxSide
            tby = hyw - tdy * tw.boxBack - tdx * tw.boxSide
            local atx, aty = tdx < 0 and -tdx or tdx, tdy < 0 and -tdy or tdy
            tex = atx * tw.halfL + aty * tw.halfW
            tey = aty * tw.halfL + atx * tw.halfW
            tboxK = atx + aty
        end
        local bRR = sk < a and bPhys or bPad
        local boxK2, tboxK2 = boxK * boxK, tboxK * tboxK
        local i0 = 1
        for blk = 1, nBlk do
            local i1 = i0 + BN - 1
            if i1 > hn then i1 = hn end
            -- 整塊剔除（Drive.sweepScratch）：+0.001 吸收浮點捨入，只會少剔；NaN 車位比較皆假＝照逐點驗
            local lim = bRR[blk] + (clr and sampleMargin or (inCap and minMargin or 0)) + 0.001
            local tl = lim + bBh[blk] * boxK2
            local far = bodyX - bx1[blk] > extentX + tl or bx0[blk] - bodyX > extentX + tl
                or bodyY - by1[blk] > extentY + tl or by0[blk] - bodyY > extentY + tl
            if far and tbx then
                tl = lim + bBh[blk] * tboxK2
                far = tbx - bx1[blk] > tex + tl or bx0[blk] - tbx > tex + tl
                    or tby - by1[blk] > tey + tl or by0[blk] - tby > tey + tl
            end
            if not far then
                for i = i0, i1 do
                    local ox, oy = hx[i], hy[i]
                    local bh, rr = bhT[i], rrT[i]
                    local grow = bh * boxK -- 非方塊 bh＝0 → grow＝0
                    -- 世界AABB只排除不可能碰撞、也不可能改善最小淨距的點；不拿近似hardS裁世界。
                    local reach = rr + grow * boxK + (clr and sampleMargin or (inCap and minMargin or 0)) + 1e-6
                    local dx, dy = ox - bodyX, oy - bodyY
                    if dx < 0 then dx = -dx end
                    if dy < 0 then dy = -dy end
                    if not (dx > extentX + reach or dy > extentY + reach) then
                        local d2 = obbDistanceSq(
                            bodyX, bodyY, fx, fy, halfW + grow, halfL + grow, ox, oy)
                        if d2 == nil or d2 <= rr * rr then
                            return Drive.sweepHit(s, sen, tag, a, b, c, offL, sk, wx, wy, i, ox, oy,
                                d2 and (sqrt(d2) - rr) or -99)
                        end
                        if inCap or clr then
                            local probe = rr + (clr and sampleMargin or minMargin)
                            if d2 < probe * probe then
                                local clearance = sqrt(d2) - rr
                                if clr and clearance < sampleMargin then sampleMargin = clearance end
                                if inCap and clearance < minMargin then minMargin, minI = clearance, i end
                            end
                        end
                    end
                    if tbx then
                        local tgrow = bh * tboxK
                        local treach = rr + tgrow * tboxK
                            + (clr and sampleMargin or (inCap and minMargin or 0)) + 1e-6
                        dx, dy = ox - tbx, oy - tby
                        if dx < 0 then dx = -dx end
                        if dy < 0 then dy = -dy end
                        if not (dx > tex + treach or dy > tey + treach) then
                            local d2 = obbDistanceSq(tbx, tby, tdx, tdy, tw.halfW + tgrow, tw.halfL + tgrow, ox, oy)
                            if d2 == nil or d2 <= rr * rr then
                                return Drive.sweepHit(s, sen, tag, a, b, c, offL, sk, wx, wy, i, ox, oy,
                                    d2 and (sqrt(d2) - rr) or -99, "trailer")
                            end
                            if inCap or clr then
                                local probe = rr + (clr and sampleMargin or minMargin)
                                if d2 < probe * probe then
                                    local clearance = sqrt(d2) - rr
                                    if clr and clearance < sampleMargin then sampleMargin = clearance end
                                    if inCap and clearance < minMargin then minMargin, minI = clearance, i end
                                end
                            end
                        end
                    end
                end
            end
            i0 = i0 + BN
        end
        if clr and (clrKeepS == nil or sk <= clrKeepS) then clr[k] = sampleMargin end
    end
    if clr then
        s.dodgeClrN, s.dodgeClrK0 = ln, startK
        s.dodgeClrS0, s.dodgeClrS1 = lS0, lS1
    end
    -- 成功時第 8 值＝最小淨距的點索引（失敗 tuple 同位置是命中點索引）：拓寬用
    return true, minMargin, nil, nil, nil, nil, nil, minI
end
-- 極小角度未圓角頂點（< MDADFollower.TURN_GEOM_MIN_RAD＝10° 的 LINE 折點）在證明線 1m 取樣上的等效曲率（1002t）：
-- 外接圓把 5° 的路網量化抖動量成 R≈11m（只剩約 35 km/h），1002b 起車道帳會用最多 7 m/s² 主動追它＝無故急煞。
-- 這一段 Follower geometryStep 本來就不算折（不給幾何帽），證明線改用同一個前視弦半徑 look(v)/(2 sin(θ/2))。
-- 10–20° 的未圓角頂點**不換**、照外接圓慢：E2E rc56b 0008（Silverado）以 72 km/h 過 18.4° 折點、出折點外漂 1.65m
-- 擦撞（同案 rc55 照外接圓 28–43 km/h 通過）；正式服 0.17.0 clip-17 在 18.9° 折點前 42 km/h 也撞（AGENTS 1002b）。
-- 1002u 起這類折點先試建小弧（MDADDynamics.FILLET_SMALL_*，弧上有前饋與切線追蹤），留在這裡的只剩建不出弧的。
-- 取樣 sk 離頂點 1.5m 內、頂點兩側都是 LINE 段才換；弧段不動。回 nil＝不換。look 用 Follower 在該頂點的弧帽速。
function Drive.smallKinkKappa(prof, si, sk)
    local kind, segH, ps = prof.segKind, prof.segH, prof.s
    if type(kind) ~= "table" or not finite(si) then return nil end
    for v = si, si + 1 do
        if v >= 2 and v <= prof.n - 1 and finite(ps[v]) and math.abs(sk - ps[v]) <= 1.5
                and kind[v - 1] == MDADDynamics.SEG_LINE and kind[v] == MDADDynamics.SEG_LINE then
            local th = segH[v] - segH[v - 1]
            if th > math.pi then th = th - 2 * math.pi elseif th < -math.pi then th = th + 2 * math.pi end
            if th < 0 then th = -th end
            if th < MDADFollower.TURN_GEOM_MIN_RAD then
                local cv = prof.curveV[v]
                if not finite(cv) or cv <= 0 then cv = prof.maxSpeedMs end
                return 2 * sin(th * 0.5) / MDADFollower.lookaheadM(cv * 3.6, prof.lookScale or 1)
            end
        end
    end
    return nil
end

-- Build one immutable proof object for loaded coverage, raw road-band, curvature
-- and long-vehicle OBB sweep. Keep the longest verified prefix, bounded by the
-- earliest failure; a farther failure cannot veto the current stopping horizon.
local function buildSnapshotProof(s, segI, proofEnd)
    s.verifyBand, s.verifySweep = false, false
    s.verifyLineReason, s.curveVerifiedUntilS = "state", 0
    s.proofKappa, s.proofCurveCap = 0, 0
    s.proofHitS = nil -- 證明線掃掠命中的車身取樣弧長（Drive.proofSweepCap 的包絡終點）
    if not s.adaptive or s.dodging or s.returnActive
            or s.blocked or s.currentBlocked then return end

    local prof, sen = s.profile, s.sensor
    local verifyX, verifyY, verifySeg = s.verifyX, s.verifyY, s.verifySeg
    local halfW = s.vehicleProfile.halfW
    local lane = laneBiasOf(s)
    local lineN, lineS0, lineReason, lastIdx = MDADFollower.buildLaneLine(
        prof, s.lastSNow, proofEnd, lane,
        verifyX, verifyY, segI, verifySeg, s.fstate.laneKeep)
    if lineReason ~= "ok" then
        s.verifyLineReason = lineReason
        return
    end
    if lineN < 2 then
        s.verifyLineReason = "capacity"
        return
    end

    local verifiedEnd, failReason = proofEnd, nil
    -- segSourceA/B 是剖面來源路線的索引：拖車時剖面建在改寫路線（點數不同），拿原始路線對＝
    -- 轉角後全線錯位、每幀 band → obb 18 km/h（2026-09-25 玩家拖露營車「過彎後一直 18」）。
    local src = s.profileRoute or s.route
    local rawPts, rawWidths = src.pts, src.segWidth
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
        if rangeN < 1 or rangeN > MDADDynamics.FILLET_OUTPUT_MAX then
            sourceValid, verifiedEnd, failReason =
                false, lineS0, "capacity"
        else
            -- Every driven chord is split at its midpoint. Each half must share
            -- one convex eroded source capsule; endpoints alone cannot prove a
            -- chord inside a non-convex source-band union.
            for si = segI, lastIdx do
                if prof.s[si] >= verifiedEnd then break end
                local h = prof.segH[si]
                -- 弦的 lane 要與 buildLaneLine 同一張 laneRoom 夾表（弧段內側餘裕＝
                -- 圓角吃剩；2026-09-04 弧半徑改按共線臂鏈後貼到帶緣，未夾的 +1 常駐
                -- 偏置在弧內側必出帶 → 每個彎 verifyLineReason=band → obb 18）
                local laneSi = MDADFollower.laneBiasAt(prof, lane, si)
                local x0 = prof.x[si] - sin(h) * laneSi
                local y0 = prof.y[si] + cos(h) * laneSi
                local x1 = prof.x[si + 1] - sin(h) * laneSi
                local y1 = prof.y[si + 1] + cos(h) * laneSi
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
                if localKappa > 0 then
                    local chord = Drive.smallKinkKappa(prof, verifySeg[k], lineS0 + (k - 1) * MDADFollower.OV_STEP)
                    if chord ~= nil and chord < localKappa then localKappa = chord end
                end
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
        -- 1002d：與剖面同一本帳——斷油＋剖面假設的中線輔助（Follower.STYLES.coastAssist）取大。舊制只取煞車×0.7
        -- 與純斷油的大者，剖面（輕車斷油 3＋輔助）收得比它晚＝車道包絡先綁、晚收油白給。實得靠 Drive.visAssistForce
        -- 車道帳的前饋（計畫減速度－斷油）。
        local envDecel = minBrake * 0.7
        local planned = minCoast + (s.profile and s.profile.coastAssist or 0)
        if envDecel < planned then envDecel = planned end
        s.laneEnvDecel = envDecel
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
                    s.proofHitS = finite(sweepAt) and sweepAt or nil
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
    local half = s.sensor.corridorHalf or MDADSensor.CORRIDOR_HALF
    local bandLo, bandHi = band - half, band + half
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

-- RETURN 期間掃描帶的**唯一**錨點（2026-09-02 session-006 定罪：commit／hold／
-- 守護通過三條路徑各自把帶心寫成目標 lane／現 lane／中點，相鄰兩輪的帶互相把對方
-- 的線判成 band／unloaded → commit↔hold 週期 3 輪震盪，每次 hold 把速度命令歸零，
-- 車 31 秒 0 km/h、路線畫面一直跳）。整段回線（起點 lane↔目標 lane＋車身＋pad）塞得進
-- 走廊就錨在中點——斜線兩端與平行爬行線同一個帶都看得到；塞不進（跨距 > ~10.8m，
-- RETURN_MAX_DEV 12 的極端）才退回舊制 streaming：帶跟現 lane、爬行等帶前伸。
local function returnScanBias(s, latSigned)
    local start, target = s.returnLaneStart, s.returnLaneTarget
    if not finite(start) then start = latSigned end
    if not finite(target) then target = laneBiasOf(s) end
    local span = target - start
    if span < 0 then span = -span end
    local pad = s.sweepBase - s.vehicleProfile.halfW
    if pad < SWEEP_PHYS_PAD then pad = SWEEP_PHYS_PAD end
    local corridorHalf = type(MDADSensor) == "table" and MDADSensor.CORRIDOR_HALF or 7
    if span * 0.5 + s.vehicleProfile.halfW + pad <= corridorHalf then
        return (start + target) * 0.5
    end
    return latSigned
end

-- RETURN 結束的共同歸零（stall 釋放／不可用／對齊完成／dodge 接手／route cutover）：
-- 五旗＋reason／rounds／holdSince。laneBias／scanBias／冷卻／event 由各站點自己決定。
local function endReturn(s)
    s.returnActive, s.returnUnsafe, s.returnHold = false, false, false
    s.returnCrawlExact, s.returnCapacityFault = false, false
    s.returnReason, s.returnClearRounds, s.returnHoldSince = nil, 0, 0
end

local function invalidateReturnControl(s)
    if not s.returnActive then return end
    MDADFollower.clearOffset(s.fstate)
    s.returnUnsafe, s.returnHold = true, true
    s.returnCrawlExact, s.returnCapacityFault = false, false
    if s.sensor and type(MDADSensor) == "table"
            and type(MDADSensor.reset) == "function" then
        MDADSensor.reset(s.sensor)
        s.sensor.scanBias = returnScanBias(s, s.lastLatSigned)
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
        s.profile, s0, s1, latSigned, latSigned, s.returnX, s.returnY, 1, 0) -- 沿現偏移：只夾物理餘裕
    if n < 2 then return end
    if not returnLineBandCovers(
            s, s.returnX, s.returnY, n, lineS0, lineS1, pad, 1) then return end
    local clear = sweepLine(s, s.returnX, s.returnY, n, lineS0, lineS1,
        s0, s1, s1, coverageEnd, latSigned, "return-crawl", s.sweepBase)
    if clear and MDADFollower.setExactLine(
            s.fstate, s.returnX, s.returnY, n, lineS0, lineS1) then
        s.returnHold = false
        if not s.returnCrawlExact then
            -- crawl-exact 承諾要留痕（s029 復盤：hold(sweep) 後靜默轉 crawl-exact，
            -- telemetry 看不出 RETURN 為何仍持有）
            diagEvent(s, s.playerNum, "return", { phase = "crawl", why = reason,
                l = latSigned, s = s.lastSNow, d = s1 })
        end
        s.returnCrawlExact = true
        s.returnStartS, s.returnEndS = s0, s1
        s.sensor.scanBias = returnScanBias(s, latSigned)
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
-- returnCrawlExact（回線走不了、退而沿現偏移直行爬行）也視同讓位：它只是
-- 「還沒撞到」的退路，掃掠驗過的 dodge 嚴格更好（2026-09-04 s029 st148611-148613：
-- 手動把車擺到線外 3.4-4.7m → RETURN 目標線每輪 sweep[return] 打槍 → crawl-exact
-- 直行「乾淨」保住持有權 → 五次 `sweep enumerate ok (crawl)` 全被
-- return-suppress 吃掉 → blocked corner → contact → 倒車 → StopStuck）。
local function profileOwner(s)
    if s.fstate.rotating == true then return "rotate" end
    if s.dodging then return "dodge" end
    if s.returnActive and not s.returnHold and not s.returnCrawlExact then return "return" end
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
    -- 未載入爬行期限：回線因視距不足（unloaded）一直 hold／crawl-exact 爬行，也在
    -- RETURN_UNLOADED_MS 後交還（同 stall 語意；0925 e-road 整趟 14 km/h）。
    if s.lastHoldReason == "unloaded" and (s.returnHold or s.returnCrawlExact) then
        if s.returnUnloadedSince == 0 then s.returnUnloadedSince = sen.stamp end
    else
        s.returnUnloadedSince = 0
    end
    local stalled = false
    if s.returnHold then
        if s.returnHoldSince == 0 then s.returnHoldSince = sen.stamp end
        local sp = vehicle:getCurrentSpeedKmHour()
        stalled = finite(sp) and sp > -1 and sp < 1
            and sen.stamp - s.returnHoldSince >= TUNE.RETURN_STALL_MS
    else
        s.returnHoldSince = 0
    end
    local unloadedLong = s.returnUnloadedSince > 0
        and sen.stamp - s.returnUnloadedSince >= TUNE.RETURN_UNLOADED_MS
    if stalled or unloadedLong then
        endReturn(s)
        s.returnUnloadedSince = 0
        s.returnBlockUntil = sen.stamp + TUNE.RETURN_STALL_BLOCK_MS
        MDADFollower.clearOffset(s.fstate)
        MDADFollower.setLaneBias(s.fstate, s.returnLaneTarget)
        s.sensor.scanBias = s.returnLaneTarget
        s.planMode = "return-stall"
        diagEvent(s, playerNum, "return", { phase = "release", why = stalled and "stall" or "unloaded",
            l = latSigned, s = s.lastSNow })
        return
    end
    -- 回線途中殭屍進到回線帶（1002c，Drive.returnZombieConflict）：結束 RETURN、停在車身交軟縫；冷卻期內
    -- 不重入（軟縫移動中車身落在常駐線與軟縫 lane 之間本來就不觸發 RETURN，見 Drive.softAlignDev）。
    if Drive.returnZombieConflict(s, latSigned, s.returnLaneTarget, vehicle:getCurrentSpeedKmHour()) then
        endReturn(s)
        s.returnUnloadedSince = 0
        s.returnBlockUntil = sen.stamp + TUNE.RETURN_STALL_BLOCK_MS
        Drive.parkForZombies(s, latSigned)
        diagEvent(s, playerNum, "return", { phase = "release", why = "zombie", l = latSigned, s = s.lastSNow })
        return
    end
    local returnPad = s.sweepBase - s.vehicleProfile.halfW
    if returnPad < SWEEP_PHYS_PAD then returnPad = SWEEP_PHYS_PAD end

    -- 完成判定對「當前段的有效目標」：RETURN 線逐段留 keep 收窄（buildOffsetLine targetKeep），
    -- 長窄段的線可能停在 0.3 而進入段 target 1.5，拿裸 target 比永遠 > CLEAR_DEV＝一路慢爬到
    -- stall 釋放（review lane 0906i）。與 control 落點同一張表（laneBiasAt）。
    local dev = latSigned - MDADFollower.laneBiasAt(s.profile, s.returnLaneTarget, s.fstate.idx, s.lastSNow)
    if dev < 0 then dev = -dev end
    if dev <= RETURN_CLEAR_DEV then
        s.returnClearRounds = s.returnClearRounds + 1
    else
        s.returnClearRounds = 0
    end
    if s.returnActive and not returnAvailable(s) then
        MDADFollower.clearOffset(s.fstate)
        endReturn(s)
        return
    end
    -- 位置剛進完成帶、車頭還斜著（仍在橫向滑動）就釋放＝下一刻巡航提速帶著橫移衝出目標線
    -- （2026-09-27 正式服 SemiBox：RETURN clear 時 err −0.18、lat 仍 1.1→1.5，提速後再進 RETURN
    -- 並接觸）。兩輪到位＋車頭對路線 ≤ RETURN_CLEAR_HEAD_RAD 才釋放；車頭一直收不正時到位
    -- RETURN_CLEAR_FORCE_ROUNDS 輪也釋放，不讓 RETURN 帽長期壓速。
    local rerr = s.lastRouteErr
    local headOk = not finite(rerr)
        or (rerr < TUNE.RETURN_CLEAR_HEAD_RAD and rerr > -TUNE.RETURN_CLEAR_HEAD_RAD)
    if (s.returnClearRounds >= 2 and headOk)
            or s.returnClearRounds >= TUNE.RETURN_CLEAR_FORCE_ROUNDS then
        endReturn(s)
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
            s.sensor.scanBias = returnScanBias(s, latSigned)
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
    local vNow = vehicle:getCurrentSpeedKmHour()
    local fastLength = Drive.returnLineFloor(s, delta, vNow)
    if length < fastLength then length = fastLength end
    local s0 = s.lastSNow
    local s1 = s0 + length
    if s1 > s.profile.length then s1 = s.profile.length end
    local lookScale = s.profile.lookScale
    if not finite(lookScale) or lookScale <= 0 then lookScale = 1 end
    local pad = returnPad
    s.sensor.scanBias = returnScanBias(s, laneStart)
    -- 線尾＝回線上限速度（RETURN_CAP）下的純追跡前視＋車身，或同速的煞停距離，取大者。
    -- 舊制固定 18m 前視（最高速的值）：整條要看到 40–50m，低幀率可負擔視距只有 25–35m →
    -- 永遠 unloaded、整趟 14 km/h 爬行（0925 E2E e-road，fe 45–65ms）。
    local tail = math.max(MDADFollower.lookaheadM(TUNE.RETURN_CAP, lookScale) + s.vehicleProfile.halfL,
        MDADDynamics.stoppingDistance(TUNE.RETURN_CAP / 3.6, 0.5, s.safeBrake, s.vehicleProfile.halfL)) + pad
    local coverageEnd = s1 + tail
    local tailSteps = (coverageEnd - s0) / MDADFollower.OV_STEP
    local wholeTail = tailSteps - tailSteps % 1
    if tailSteps > wholeTail then coverageEnd = s0 + (wholeTail + 1) * MDADFollower.OV_STEP end
    if coverageEnd > s.profile.length then coverageEnd = s.profile.length end
    local lineN, lineS0, buildReason, lineS1 = MDADFollower.buildReturnLine(
        s.profile, s0, s1, laneStart, laneTarget, s.returnX, s.returnY, tail)
    coverageEnd = lineS1
    if buildReason ~= "ok" then -- capacity／fold（線在彎內側摺疊，Follower.OV_MIN_ADVANCE）
        holdUnsafeReturn(s, vehicle, laneStart, buildReason)
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
        -- commit 後下一次 hold（守護打槍）要能再記一筆：hold 事件依理由去重（1004a：Sixya clip-14 23 km/h 守護打槍
        -- 鎖輪完全沒有事件，因為 commit 前已記過同理由的 hold）
        s.lastHoldReason = nil
        MDADFollower.setLaneBias(s.fstate, laneTarget)
        s.planMode = "return"
        diagEvent(s, playerNum, "return", {
            phase = "commit", why = s.returnReason, s = s0, d = s1, speed = vNow, len = s1 - s0,
        })
    else
        holdUnsafeReturn(s, vehicle, laneStart, safe and "line" or "sweep")
    end
end

-- RETURN 回線長的車速地板（1004a）：實速超過 RETURN_CAP 時，側移 delta 照 shapeProfile 同一式的運動學長
-- （MDADDynamics.shiftLength）——正式服 0.18.2 ImJustAtoms clip-02：62 km/h 承諾 11.7m 做 2.9m 的回線，轉向飽和、
-- 過衝 0.86m、62.8 km/h 撞樹。RETURN_CAP 以下照舊 max(4·delta, 8, 車長)。線變長看不到線尾＝照既有 hold(unloaded)。
function Drive.returnLineFloor(s, delta, speedKmh)
    if not finite(speedKmh) or not finite(delta) then return 0 end
    local v = speedKmh < 0 and -speedKmh or speedKmh
    local aLat = s.horizonMinLat
    if v <= TUNE.RETURN_CAP or not finite(aLat) or aLat <= 0 then return 0 end
    local vp = s.vehicleProfile
    local k = MDADDynamics.steeringKappa(vp.wheelbase, vp.delta0Safe, vp.deltaVSafe, vp.maxSpeed, v)
    if k <= 0 then k = 1 / 6 end
    return MDADDynamics.shiftLength(delta, v / 3.6, aLat, k, vp.halfL, MDADDynamics.LATERAL_JERK_MAX)
end

-- 調頭接手＝RETURN 結束（0928a；summer/clip-05：起步偏頭 123°、RETURN 進入後回線驗不過 hold，車在
-- hold 中被甩到 159° → Follower rotating 成立。updateReturnSnapshot 在 rotate 持有時早退、stall 釋放
-- 永遠跑不到，stepFollow 的 returnHold 煞停分支又排在調頭分支之前＝煞停不轉，14.5 秒後 StopStuck）。
-- 同 dodge takeover：laneBias＝目標、帶心同步、冷卻 RETURN_STALL_BLOCK_MS；調頭完成後偏差仍大自然重進。
function Drive.returnYieldRotate(s, playerNum, now)
    if not s.returnActive or s.fstate.rotating ~= true then return end
    endReturn(s)
    s.returnUnloadedSince = 0
    s.returnBlockUntil = now + TUNE.RETURN_STALL_BLOCK_MS
    MDADFollower.clearOffset(s.fstate)
    MDADFollower.setLaneBias(s.fstate, s.returnLaneTarget)
    if s.sensor then s.sensor.scanBias = s.returnLaneTarget end
    s.planMode = "return-rotate"
    diagEvent(s, playerNum, "return", { phase = "release", why = "rotate", s = s.lastSNow })
end

-- 過渡段提早完成（理由見 CURVE_LEAD 常數註解）：剖面 a..d 內有折點且過渡
-- 完成點 b 離折點不足 CURVE_LEAD 時，把 a/b 前移——側移在進彎前的直段做完、
-- 彎中保持段全程蓋住折點，掃掠線不再切角掃到彎外側障礙。只早不晚（更保守）；
-- a 不得早於車前 1m、b 不得晚於折點也不得超過 c。擠不下就沿用原剖面。
-- 剖面塑形：進入段（a..b）與收回段（c..d）都不得跨路線折點——offL 在折點
-- 兩側指向不同世界方向，跨折點的過渡線必然斜切彎角障礙（2026-08-29 回程皮卡
-- 兩役：進入段半途 lane 打槍→後移策略；收回段半途 lane 打槍→延後收回）。
-- crawlDesign＝true（squeeze／physical／降檔候選）：這些檔位本來就是貼縫爬行，
-- 過渡幾何按爬行速設計（短、緊貼障礙）——長過渡線在窄縫兩側會多掃到旁邊的
-- 樹／牆而被打回（harness「narrow tree gap」對照）。false＝巡航檔按巡航意圖設計。
-- 候選線的起始 lane＝車的實際橫向（缺 lastLatSigned 時退回 baseL）。dl／進入段設計／
-- 陡坡閘／buildOffsetLine 的 s0..a 段／停留線的 returnLaneStart 全部以此為準；候選鏈的 baseL
-- 是回線 lane（車「要去」的線，`Drive.dodgeHomeL`），corridor 擋線判定另用 laneBias。2026-09-06 s025 定罪：車在
-- 1.66、bias 夾成 0.13、候選 offL 1.25 → 舊制 dl 1.12（實際只差 0.41）且線從 0.13 起步，
-- cross-track 先往左拉 1.5m 再右切＝前右角撞路口內側桿。「寫 lane 前先問車在哪」第五次。
local function startLaneOf(s, baseL)
    local v = s.lastLatSigned
    if finite(v) then return v end
    return baseL
end

-- 繞行承諾線的回線 lane（出口段與線尾、dodgeBaseL、出口後擋線判定）：RETURN 持有中（hold／crawl-exact 讓位
-- 給繞行）＝回線目標 returnLaneTarget——commit 同幀結束 RETURN 並把 laneBias 寫成它；否則＝laneBias。
-- RETURN hold 的 laneBias 是車位（holdUnsafeReturn），舊制拿它當出口：線走完車停在 RETURN 要離開的那條
-- lane，線尾到常駐線的斜切沒被掃過（正式服 1004g：車在 −1.7、常駐 +3，82 km/h 走完線、11m 外撞硬物）。
function Drive.dodgeHomeL(s)
    if s.returnActive and finite(s.returnLaneTarget) then return s.returnLaneTarget end
    return laneBiasOf(s)
end

-- 掛車軌跡掃掠與保持段延長只用在寬帶繞行（規劃中的寬帶快照或已承諾的寬帶繞行）。0929p 第一版一般帶也驗掛車：
-- E2E semi-corner／cistern／hairpin-ct 在路邊小物前全判不過、StopStuck——一般帶的候選只照牽引車設計（寬度、
-- 進入段都不知道掛車會落後），只驗不產生＝卡在原本開得過的地方。一般帶維持只驗牽引車（0929o 以前的行為）。
function Drive.towChecks(s)
    local tw = s.tow
    if type(tw) ~= "table" then return nil end
    if s.dodgeWide or (type(s.sensor) == "table" and s.sensor.wideDone == true) then return tw end
    return nil
end

-- 拖車繞行保持段的延長量（0929p）：車位到掛車尾（MDADTrailer.attach 的 trailLen），牽引車回線前掛車要先過群；
-- 量不到掛點偏移或不是寬帶＝0。shapeProfile 加在 c／d 上；兩處承諾窗預檢要把它算進去，已形塑過的斷點再形塑前要扣掉。
function Drive.towHold(s)
    local tw = Drive.towChecks(s)
    local tl = tw and tw.trailLen
    return finite(tl) and tl > 0 and tl or 0
end

local function shapeProfile(s, profile, a, b, c, d, offL, baseL, crawlDesign)
    -- 拖車（0929p）：保持段延長到掛車尾也過了群（牽引車照原本的 c 回線時掛車還在障礙旁、內切掃到它）；
    -- 掛車實際走的軌跡另由 sweepLine 逐點驗。
    local tl = Drive.towHold(s)
    if tl > 0 then c, d = c + tl, d + tl end
    local sTurn = turnPeakS(profile, a, d + 6)
    local minA = s.lastSNow + 1
    if s.laneChained and finite(s.stayHoldEndS) and s.stayHoldEndS > minA then
        minA = s.stayHoldEndS -- 提早釋放的停留：進入段不早於停留段終點（TUNE.STAY_SETTLED_M）
    end
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

    local dl = offL - startLaneOf(s, baseL)
    if dl < 0 then dl = -dl end
    -- 幾何設計保留路線物理包絡，但不把啟動／調頭／出彎收正的暫時低速烘進承諾線。
    -- s.profileEnvelope 是 Follower 最終控制目標；profileSpeedKmh 尚未套用那些姿態帽。
    local intended = profile.maxSpeed
    local envelope = s.fstate.profileSpeedKmh
    if finite(envelope) and envelope >= 0 and envelope < intended then intended = envelope end
    if finite(s.gearCap) and s.gearCap > 0
            and s.gearCap < intended then intended = s.gearCap end
    local crawl = MDADDynamics.DODGE_SQUEEZE_CAP
    -- 借對向車道（靠右開著、全偏移時車身左緣越過中線）：過渡段按 ONCOMING_DESIGN_KMH 設計——
    -- 巡航設計的過渡長 50m，實際常被淨距帽壓到 10 km/h，在對向車道裡爬好幾秒（E2E park400／
    -- SUV park：對向車出現時已壓線、退不回也快不起來＝被撞）。短過渡＝到障礙前才切出去、
    -- 過了立刻切回，對向車出現時多半還在自己車道、可以停下讓車。
    -- 越過「路面中線」（導航線可偏離路中心 roadBias，不是 l=0）；判定見 Drive.borrowsOncoming。
    if Drive.borrowsOncoming(s, offL) and intended > TUNE.ONCOMING_DESIGN_KMH then
        intended = TUNE.ONCOMING_DESIGN_KMH
    end
    if crawlDesign or intended < crawl then intended = crawl end
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
    -- 「已經在那條 lane 上」＝不需要進入段（2026-09-04 st179,249／st179,154：停留／繞行剛結束、
    -- 車貼在 +2.0，corridor 對 +2.0 線旁的路緣物群回 b < rs+1 → entryAvail ≤ 0 → 全候選靜默
    -- 拒收 → blocked hit=nil → StopStuck；使用者「明明過了，為什麼停下來不再走了」）：
    -- 候選 lane 與車的實際橫向差 ≤ DODGE_INPLACE_M 時，把進入段當成已完成（a=rs−1、b=rs）。
    if b < minA and finite(s.lastLatSigned) then
        local dLat = offL - s.lastLatSigned
        if dLat < 0 then dLat = -dLat end
        if dLat <= TUNE.DODGE_INPLACE_M and c > minA then
            a, b = s.lastSNow - 1, s.lastSNow
            minA = a
            dl = 0 -- 沒有側移可言：進入段長度／陡坡閘全部以 0 側移計
            -- 唯一的過渡是回常駐線的出口：長度照出口側移的設計速度算（0929j E2E C 段：0.17m 的出口只拿到
            -- 車長地板 7m、出口帽 22.6，55 km/h 被減速輔助以 7 m/s² 急煞）
            required = MDADDynamics.shiftLength(
                math.abs(offL - baseL), intended / 3.6, aLat, kSteer, vp.halfL, MDADDynamics.LATERAL_JERK_MAX)
            minimum = MDADDynamics.shiftLength(
                0, 0, aLat, crawlK, vp.halfL, MDADDynamics.LATERAL_JERK_MAX)
        end
    end
    local entryAvail, exitAvail = b - minA, 1e9
    -- 空間延長不得把已避開折點的轉場再拉回跨越折點：entry 只能延到折點後
    -- 0.5m，exit 轉場整段停在下一折點前 2m（窗寬涵蓋整個可延長範圍，
    -- 也擋住原 a..d+6 窗外的新折點）。空間不足只壓速（entry/exit 皆無 minimum 門檻）。
    local entryPeak = turnPeakS(profile, minA, b)
    if entryPeak and b > entryPeak then
        local room = b - (entryPeak + 0.5)
        if room < entryAvail then entryAvail = room end
    end
    local exitPeak, exitTurn = turnPeakS(
        profile, c, s.lastSNow + TUNE.DODGE_OV_SPAN + 6)
    -- 0928i（rc6 0070 路口 jog：保持段已由上面延過 −75° 折點，2.8m 後又一個 19° 小折點落在 c 後 2m 內
    -- → 出口轉場塞不進 → 全部候選 exit-room → 倒車三次交還）：緊接的小折點一併在偏移上通過。
    for _ = 1, 3 do
        if not (exitPeak and exitPeak > c and exitPeak - 2 - c <= 0
                and exitTurn <= TUNE.EXIT_HOLD_KINK_RAD) then break end
        c = exitPeak + 1
        exitPeak, exitTurn = turnPeakS(profile, c, s.lastSNow + TUNE.DODGE_OV_SPAN + 6)
    end
    if exitPeak and exitPeak > c then
        local room = exitPeak - 2 - c
        if room < exitAvail then exitAvail = room end
    end
    s.dodgeShiftLength = required
    s.dodgeSpaceCap = profile.maxSpeed
    if required <= 0 or minimum <= 0 or entryAvail <= 0 or exitAvail <= 0 then
        s.dodgeSpaceCap = 0
        s.dodgeShapeReason = entryAvail <= 0 and "entry" or (exitAvail <= 0 and "exit-room" or "length")
        return a, b, c, d, false
    end
    if required < minimum then required = minimum end
    local exitGeom = exitAvail -- 折點給的出口上限；下面的可視範圍截短會隨車前進放寬，折點不會
    -- 已掃範圍能容納完整低速回線就按真長度收尾；未掃與未載入同樣不是淨空。
    -- 看得到路線終點時沿抵達契約，不把目標本身當成未知障礙。
    if s.sensor and s.sensor.ready then
        local covered = visibleEndS(s.sensor, s.lastSNow)
        if covered < profile.length then
            local room = covered - 1 - s.bodyReach - c
            if room >= 1 and room < exitAvail then exitAvail = room end
        end
    end
    local exitRoom = s.lastSNow + TUNE.DODGE_OV_SPAN - c
    -- entry 側 minimum 門檻退役（2026-09-01 s052 近障礙定罪，對稱 exit 側
    -- s019）：車距障礙群 5m、側移 2.5m 時，crawl 最小過渡長（max(2×halfL,
    -- lLat)≈5.8-7m）永遠塞不進 entryAvail 2.8m → 每輪「curve dodge ok →
    -- sweep 全滅（shape false 假扮 hold fail）」→ blocked 停死→倒退→route
    -- 重算又縮回 5m 的死循環。正解同 exit：塞多少給多少（下限 1m），過渡
    -- 變陡由 shiftSpaceSpeedCapKmh 按實長連續壓速、世界掃掠 OBB 終審幾何。
    local entryLen = required > entryAvail and entryAvail or required
    if entryLen < 1 then entryLen = 1 end
    -- 進入段用滿跑道（sweepWithFallbacks 的 stretch 設 s.entryStretch；理由見 TUNE.ENTRY_STRETCH_MAX）
    if s.entryStretch and entryAvail > entryLen then
        local cap = entryLen * TUNE.ENTRY_STRETCH_MAX
        entryLen = entryAvail < cap and entryAvail or cap
    end
    -- 陡坡閘門要用純運動學長度 sqrt(6·dl/κ)，不含 shiftLength 的 2×halfL 地板（2026-09-04
    -- s@167683 路口：路緣桿 l 3.0-6.4 在 2m 外、entryAvail 1.2m，連 dl=0.25 都被 min=4.2
    -- （＝車長地板）判 ratio 3.4 拒收 → 全滅 blocked 「明明沒有障礙擋到路線」）。
    local kinMin = 0
    if crawlK > 0 and dl > 0 then kinMin = math.sqrt(6 * dl / crawlK) end
    if entryLen * TUNE.SHIFT_MIN_RATIO < kinMin then
        -- 理由見 TUNE.SHIFT_MIN_RATIO；回 false＝候選失敗（phase 3），鏈續試
        s.dodgeSpaceCap = 0
        s.dodgeWindowShort = false
        s.dodgeShapeReason = "steep"
        -- 倒車該退多少才夠這個側移（ratio 1＝純運動學長；2026-09-04 st176,191：退 4.4m 後
        -- 5m 側移只有 8.8m 跑道（ratio 1.16）→ 承諾 → 39° 斜切撞 B）
        if dl > TUNE.STEEP_DEFICIT_MIN_DL then
            local deficit = kinMin - entryLen
            if s.steepDeficitM < 0 or deficit < s.steepDeficitM then s.steepDeficitM = deficit end
        end
        if getDebug() then
            print(string.format("%sshape steep: dl=%.2f entry=%.1f kin=%.1f ratio=%.1f offL=%.2f",
                LOG, dl, entryLen, kinMin, kinMin / entryLen, offL))
        end
        return a, b, c, d, false
    end
    s.dodgeShapeReason = nil
    -- exit 側不設 minimum 門檻（2026-09-01 s019 近目標定罪：目標在回線段
    -- 內時 minimum 塞不進殘長 → dodge-cap 345 幀全放棄）。接受截斷回線：
    -- 帶側偏抵達由歐氏 ARRIVE_M(5) 圈涵蓋；空間短由 shiftSpaceSpeedCapKmh
    -- 自動轉成低速 cap，回線幾何仍由 sweepLine 世界複驗把關。
    -- 出口用自己的側移量（0929j；玩家 session-012 KI5 Oshkosh：車在 −0.35 起步、offL 0.25＝進入 0.6m，
    -- 出口卻要回到常駐 1.76＝1.5m；舊制兩段共用進入側移算的長度，可視範圍又把出口截到 1.03m——一公尺
    -- 橫移 1.5m 的線，切線追蹤在出口前就把車頭甩 36°、車開到線右 0.8m，下一段繞行從歪掉的姿態起步撞上
    -- 路邊物）。回線落點同 buildOffsetLine（laneBiasAt 沿弧長連續），取 c 處與常駐值較大者。出口長度只補到
    -- 出口側移的低速最短過渡，不照巡航設計放長（長出口多掃的範圍會讓原本過得了的候選被打回、改走停留）。
    local exitDl = math.abs(offL - baseL)
    local laneC = MDADFollower.laneBiasAt(profile, baseL, MDADFollower.segIndexAt(profile, c), c)
    if finite(laneC) and math.abs(offL - laneC) > exitDl then exitDl = math.abs(offL - laneC) end
    local exitReq = required
    if exitDl > dl then
        local exitMin = MDADDynamics.shiftLength(
            exitDl, 0, aLat, crawlK, vp.halfL, MDADDynamics.LATERAL_JERK_MAX)
        if exitMin > exitReq then exitReq = exitMin end
    end
    local exitLen = exitReq > exitAvail and exitAvail or exitReq
    -- 承諾窗（rs+DODGE_OV_SPAN）截短出口（2026-09-04 st146014：群出口剛落在窗緣，
    -- exit 被截到 4.5m → sinHeading 0.73 → clearance 從 margin 0.95 崩到 7.4、space 0，
    -- 整段路口 8 km/h）：幾何要的比窗給的多、而且 entry 還吃得下「等窗前移那幾公尺」
    -- 時，標 dodgeWindowShort 讓 replan 延後 commit（下一輪 rs 前進、窗跟著前移）。
    -- entry 也吃不下（群長 >~90m）才照舊截短承諾。
    s.dodgeWindowShort = false
    if exitLen > exitRoom then
        if b - (s.lastSNow + (exitLen - exitRoom)) - 1 >= entryLen then
            s.dodgeWindowShort = true
        end
        exitLen = exitRoom
    end
    if exitLen < 1 then exitLen = 1 end
    -- 出口陡坡（同進入段的運動學比例 SHIFT_MIN_RATIO）：被可視範圍／承諾窗截短成陡坡、而車再往前開就放得下
    -- （折點給的長度夠）、進入段也等得起時延後承諾（replan 的 exit 延後）；等不起照舊承諾，不新增否決
    -- （0909b R2：近距離短出口只要世界掃掠過就收）。
    if exitDl > 0 and crawlK > 0 then
        local exitKin = math.sqrt(6 * exitDl / crawlK)
        local want = exitKin / TUNE.SHIFT_MIN_RATIO -- 不陡的最短出口；等到這麼長就好，不必等到巡航設計長
        if exitLen * TUNE.SHIFT_MIN_RATIO < exitKin and want <= exitGeom
                and b - (s.lastSNow + (want - exitLen)) - 1 >= entryLen then
            s.dodgeWindowShort = true
        end
    end
    -- shape 只記固定基準；最終 physical/stay 分類在 fallback 後才知道。
    -- 風格的 jerk 放寬移到 commit／guard 共用收口，不可提前烘進貼縫候選。
    local entryCap = MDADDynamics.shiftSpaceSpeedCapKmh(
        dl, entryLen, aLat, vp.wheelbase, vp.delta0Safe, vp.deltaVSafe,
        vp.maxSpeed, MDADDynamics.LATERAL_JERK_MAX)
    local exitCap = MDADDynamics.shiftSpaceSpeedCapKmh(
        exitDl > dl and exitDl or dl, exitLen, aLat, vp.wheelbase, vp.delta0Safe, vp.deltaVSafe,
        vp.maxSpeed, MDADDynamics.LATERAL_JERK_MAX)
    s.dodgeSpaceCap = entryCap
    if exitCap < s.dodgeSpaceCap then s.dodgeSpaceCap = exitCap end
    s.dodgeCommittedLength = entryLen
    if exitLen < s.dodgeCommittedLength then s.dodgeCommittedLength = exitLen end
    s.dodgeSpaceBaseCap = s.dodgeSpaceCap
    s.dodgeSpaceLat, s.dodgeShapeDl = aLat, dl
    s.dodgeEntryLength, s.dodgeExitLength = entryLen, exitLen
    s.dodgeExitWant = exitReq
    a, d = b - entryLen, c + exitLen
    return a, b, c, d, true
end

-- 只重算速度，不重造承諾線。shape 的基準快照不能被 guard 的輸出帽覆寫。
local function dodgeSpaceCapOf(s, protected, entryPassed)
    local base = s.dodgeSpaceBaseCap
    local jerk = MDADDynamics.LATERAL_JERK_MAX
    if not protected then jerk = TUNE.DODGE_TUNE.jerkCap end
    if entryPassed or jerk ~= MDADDynamics.LATERAL_JERK_MAX then
        local length, dl = s.dodgeCommittedLength, s.dodgeShapeDl
        if entryPassed then
            if not finite(s.dodgeExitLength) or not finite(s.dodgeExitDl) then return nil end
            length = s.dodgeExitLength
            dl = math.max(dl, s.dodgeExitDl)
        end
        if finite(length) and length > 0 and finite(s.dodgeSpaceLat) and finite(dl) then
            local vp = s.vehicleProfile
            return MDADDynamics.shiftSpaceSpeedCapKmh(dl, length,
                s.dodgeSpaceLat, vp.wheelbase, vp.delta0Safe, vp.deltaVSafe, vp.maxSpeed, jerk)
        end
    end
    return base
end

-- 承諾後出口加長（0928f；E2E rc2–rc4：40–70m 外就看到障礙、出口被當下的可視範圍截到 2–6m，
-- 空間帽 0 → 整段繞行最後降到 10 km/h；10/89 筆承諾是這型）。車還沒到出口時，可視範圍跟著車前進；
-- 前緣容得下更長的出口就用同一組 a/b/c/offL、同一個起始 lane 重建整條線（進入段與保持段
-- 取樣同一條曲線），世界掃掠過了才換（第二張工作表，成功才交換；失敗舊線原封不動）。
-- 停留（沒有出口）、脫困 episode、降級的線不做。同一位置失敗後前進 EXIT_EXTEND_RETRY_M 再試。
function Drive.extendDodgeExit(s, sen, playerNum)
    local fs = s.fstate
    if not s.dodging or s.dodgeStay or s.episodeActive or s.returnActive or s.dodgeGuardFailed
            or finite(s.dodgeDemoteS) or not finite(s.dodgeExitWant) or not finite(s.dodgeStartL)
            or not finite(s.dodgeBaseL) or not finite(fs.offA) or not finite(fs.offC)
            or not finite(fs.offD) or not finite(fs.offL) or type(s.tmpOv2X) ~= "table" then
        return false
    end
    local rs, c, prof = s.lastSNow, fs.offC, s.profile
    if rs > c - 2 or fs.offD >= prof.length - 1 then return false end
    if finite(s.dodgeExtendFailS) and rs < s.dodgeExtendFailS + TUNE.EXIT_EXTEND_RETRY_M then return false end
    local have = fs.offD - c
    local room = s.dodgeExitWant
    if have >= room - TUNE.EXIT_EXTEND_MIN_M then return false end
    local peak = turnPeakS(prof, c, rs + TUNE.DODGE_OV_SPAN + 6)
    if peak and peak > c and peak - 2 - c < room then room = peak - 2 - c end
    if rs + TUNE.DODGE_OV_SPAN - c < room then room = rs + TUNE.DODGE_OV_SPAN - c end
    local cov = visibleEndS(sen, rs) - 1 - s.bodyReach - c
    if cov < room then room = cov end
    if room < have + TUNE.EXIT_EXTEND_MIN_M then return false end
    local d2 = c + room
    local coverEnd = math.min(d2 + 1, prof.length)
    local n, s0, reason, covered = MDADFollower.buildOffsetLine(prof, rs, fs.offA, fs.offB, c, d2,
        fs.offL, s.dodgeBaseL, s.tmpOv2X, s.tmpOv2Y, nil, nil, nil, s.dodgeStartL)
    local ok, margin, mi = false, 0, nil
    if n >= 2 and reason == "ok" and covered >= coverEnd - 1e-6 then
        -- 不收表：表是現行承諾線的（同一個陣列），加長掃不過時舊線要原封不動。1002r 前這裡收表，
        -- 每次加長失敗都把現行線的逐點淨距清掉，而補掃每條線只有一次（E2E rc55 0001：33m 進入段、
        -- 出口 3.8m，下一群擋住加長、每 2m 試一次，表清空後整段吃整線帽 10 km/h 爬 80m）。
        local okS, mS, _, _, _, _, _, miS = sweepLine(s, s.tmpOv2X, s.tmpOv2Y, n, s0, covered,
            fs.offA, fs.offB, c, d2, fs.offL, "extend", s.dodgeNeed, 1, true, false)
        ok, margin, mi = okS, mS, miS
    end
    if not ok or not MDADFollower.setOffset(fs, fs.offA, fs.offB, c, d2, fs.offL,
            s.tmpOv2X, s.tmpOv2Y, n, s0, covered, coverEnd) then
        s.dodgeExtendFailS = rs
        return false
    end
    s.tmpOvX, s.tmpOv2X = s.tmpOv2X, s.tmpOvX
    s.tmpOvY, s.tmpOv2Y = s.tmpOv2Y, s.tmpOvY
    s.lastOvN, s.lastOvS0, s.lastOvEndS, s.tmpOvEndS = n, s0, covered, covered
    s.dodgeMargin, s.dodgeMarginS = margin, mi and sen.hardS and sen.hardS[mi] or 1e9
    s.dodgeGuardHardN = sen.hardN
    -- 新線從 rs 重建、點序位移，舊表對不上：清掉，下一個持平輪的補掃（新 ovS0）重收
    s.dodgeClrN, s.dodgeEnvN = 0, 0
    -- 出口側移量與空間帽照承諾時的算法重算（新出口段的連續落點、較長的過渡）
    local exitDl = math.abs(fs.offL - s.dodgeBaseL)
    local seg = MDADFollower.segIndexAt(prof, c)
    local sx = c
    while true do
        while seg < prof.n - 1 and prof.s[seg + 1] < sx do seg = seg + 1 end
        local dlx = math.abs(fs.offL - MDADFollower.laneBiasAt(prof, s.dodgeBaseL, seg, sx))
        if dlx > exitDl then exitDl = dlx end
        if sx >= d2 then break end
        sx = math.min(sx + MDADFollower.OV_STEP, d2)
    end
    s.dodgeExitDl, s.dodgeExitLength = exitDl, room
    s.dodgeCommittedLength = math.min(s.dodgeEntryLength or room, room)
    local vp = s.vehicleProfile
    local function spaceCap(len)
        return MDADDynamics.shiftSpaceSpeedCapKmh(s.dodgeShapeDl, len, s.dodgeSpaceLat, vp.wheelbase,
            vp.delta0Safe, vp.deltaVSafe, vp.maxSpeed, MDADDynamics.LATERAL_JERK_MAX)
    end
    if finite(s.dodgeShapeDl) and finite(s.dodgeSpaceLat) and finite(s.dodgeEntryLength) then
        s.dodgeSpaceBaseCap = math.min(spaceCap(s.dodgeEntryLength), spaceCap(room))
    end
    diagEvent(s, playerNum, "dodge", { phase = "extend", c = c, d = d2, len = room, m = margin, rs = rs })
    if getDebug() then
        print(string.format("%spn=%d dodge exit extended: c=%.1f d %.1f -> %.1f (exit %.1f -> %.1f) m=%.2f rs=%.1f",
            LOG, playerNum, c, c + have, d2, have, room, margin, rs))
    end
    return true
end

-- 繞行線的曲率只量「車前尚未走完的過渡段」：[a,b]、[c,d] 是線與路線不同的地方；
-- 其餘（車位→a 的起始段、保持段 [b,c]）只是路線平移——弧段（SEG_ARC）的內側偏移由
-- Follower.control 的 κ/(1−lt·κ) 硬帽管，量 ov 折線只會把取樣量化的尖角帶回來
-- （2026-09-06 session-055：彎道旁一根桿子的 tight 繞行把整條 20-50m 線壓在彎頂速度 15，
-- 過了彎還在爬；全程 55% 樣本在這種繞行）。線上**非弧的折點**（v3 原始折角／v4 fallback；
-- 折角 > 2°）沒有人管它偏移後的實線彎（法向在 OV_BLEND 內旋轉＝小半徑弧），只量它
-- ±(OV_BLEND+1) 鄰域，範圍＝整條尚未走完的線 [車尾, 線尾]（shapeProfile 的 entryPeak 會刻意
-- 把 a 放到折點之後＝折點常在起始段；review lane 反例：兩臂 30m 的 90° 原折點、offL 2，
-- 兩窗全在直段 κ≈0）。rearS＝車尾弧長，已過的折角不再限速。線外／缺參數退回整線（保守）。
-- 索引：頂點 k 在 s0+(k−1)·step；下界取 floor（該點折角已在車下）、上界取 ceil（含 b／d 本身）。
TUNE.DODGE_KAPPA_CORNER_RAD = 2 * math.pi / 180 -- 冷路徑常數收 TUNE（chunk local 190 槽已滿）
local function ovIndexFloor(s0, step, sk)
    local i = (sk - s0) / step
    return i - i % 1 + 1
end
local function ovIndexCeil(s0, step, sk)
    local i = (sk - s0) / step
    local w = i - i % 1
    if w < i then w = w + 1 end
    return w + 1
end
-- 窗 [lo, hi] 的 ov 折線 κ。直段 run 照量；落在弧段（SEG_ARC）上的頂點分兩種：窗只是**碰到**弧
-- （重疊 < 2 步＝OV_BLEND 混合區）就跳過——過渡窗尾端碰到弧起點（entryPeak 常把 b 放在弧前）會讓
-- 弧 κ 0.3 進到整條線的常駐帽＝從 a 前 20m 就壓 15（2026-09-07 T 字路口探針）；窗與弧**實質重疊**
-- （≥ 2 步）則量重疊段的 ov 合成曲率（基弧＋側移；Codex lane 2026-09-07：R 12 弧中 2m 側移合成 κ
-- 可到 0.2，Follower 的 κ/(1−lt·κ) 只對固定偏移成立、spaceCap 只算直路 S 彎，兩者的 min 漏這一段）。
-- 弧的固定偏移（保持段）仍由 control 硬帽在車進弧時管。無 profile 退整窗。
-- 弧 run [arcLo, arcHi]（已與窗相交）：重疊 ≥ 2 步才量 ov 合成曲率（只碰到＝混合區，跳過）
local function arcRunKappa(xs, ys, n, s0, step, arcLo, arcHi, kappa)
    if arcHi - arcLo < 2 * step then return kappa end
    local first, last = ovIndexCeil(s0, step, arcLo), ovIndexFloor(s0, step, arcHi)
    if last > first then
        local k = MDADDynamics.polylineKappaMax(xs, ys, n, first, last)
        if k > kappa then kappa = k end
    end
    return kappa
end
local function windowKappaNoArc(prof, xs, ys, n, s0, step, lo, hi)
    if lo >= hi then return 0 end
    if type(prof) ~= "table" or prof.ready ~= true or type(prof.segKind) ~= "table" then
        return MDADDynamics.polylineKappaMax(xs, ys, n,
            ovIndexFloor(s0, step, lo), ovIndexCeil(s0, step, hi))
    end
    local ss, segKind = prof.s, prof.segKind
    local kappa = 0
    local j = MDADFollower.segIndexAt(prof, lo)
    local runLo, arcLo = nil, nil
    while j <= prof.n - 1 and ss[j] < hi do
        local segLo = ss[j]
        if segLo < lo then segLo = lo end
        if segKind[j] ~= MDADDynamics.SEG_ARC then
            if arcLo ~= nil then
                kappa = arcRunKappa(xs, ys, n, s0, step, arcLo, segLo, kappa)
                arcLo = nil
            end
            if runLo == nil then runLo = segLo end
        else
            if arcLo == nil then arcLo = segLo end
            if runLo ~= nil then
                -- run 結束於弧起點 segLo：量 [runLo, segLo]，弧邊界退 OV_BLEND——buildOffsetLine 在
                -- 段端 2m 內混合鄰段法向，弧前 2m 的 ov 點已帶弧的曲率，再往前一個頂點的圓周 κ 用到
                -- 它當鄰點：弧起點側退 3 頂點（s=E−2 起不量）、弧尾側退 2（量測從 first+1 起）
                local first, last = ovIndexFloor(s0, step, runLo), ovIndexCeil(s0, step, segLo) - 3
                if runLo > lo then first = first + 2 end -- run 起點是弧尾
                if last > first then
                    local k = MDADDynamics.polylineKappaMax(xs, ys, n, first, last)
                    if k > kappa then kappa = k end
                end
                runLo = nil
            end
        end
        j = j + 1
    end
    if arcLo ~= nil then kappa = arcRunKappa(xs, ys, n, s0, step, arcLo, hi, kappa) end
    if runLo ~= nil then
        local first, last = ovIndexFloor(s0, step, runLo), ovIndexCeil(s0, step, hi)
        if runLo > lo then first = first + 2 end
        -- 迴圈在 ss[j] ≥ hi 停：下一段若是弧且起點離窗尾不到 OV_BLEND，混合區同樣退
        if j <= prof.n - 1 and segKind[j] == MDADDynamics.SEG_ARC and ss[j] - hi < 2 * step then
            local lastArc = ovIndexCeil(s0, step, ss[j]) - 3
            if lastArc < last then last = lastArc end
        end
        if last > first then
            local k = MDADDynamics.polylineKappaMax(xs, ys, n, first, last)
            if k > kappa then kappa = k end
        end
    end
    return kappa
end
local function dodgeLineKappa(prof, xs, ys, n, s0, rearS, a, b, c, d)
    if not (finite(s0) and finite(rearS) and finite(a) and finite(b) and finite(c) and finite(d)) then
        return MDADDynamics.polylineKappaMax(xs, ys, n)
    end
    local step = MDADFollower.OV_STEP
    local floor = s0
    if rearS > floor then floor = rearS end
    local lo = a
    if floor > lo then lo = floor end
    local kappa = windowKappaNoArc(prof, xs, ys, n, s0, step, lo, b)
    lo = c
    if floor > lo then lo = floor end
    local k2 = windowKappaNoArc(prof, xs, ys, n, s0, step, lo, d)
    if k2 > kappa then kappa = k2 end
    local lineEnd = s0 + (n - 1) * step
    if floor < lineEnd and type(prof) == "table" and prof.ready == true then
        local ss, segH, segKind = prof.s, prof.segH, prof.segKind
        local reach = 2 + 1 -- MDADFollower OV_BLEND(2) + 一格
        -- 候選頂點從車尾−reach 起找（車尾剛越過折點，鄰域後半仍在車前；from 再以車尾裁）
        local m = MDADFollower.segIndexAt(prof, floor - reach) + 1 -- 第一個 s[m] > 車尾−reach 的頂點
        while m <= prof.n - 1 and ss[m] <= lineEnd do
            if segKind[m - 1] ~= MDADDynamics.SEG_ARC and segKind[m] ~= MDADDynamics.SEG_ARC then
                local dth = segH[m] - segH[m - 1]
                if dth > math.pi then dth = dth - 2 * math.pi elseif dth < -math.pi then dth = dth + 2 * math.pi end
                if dth < 0 then dth = -dth end
                if dth > TUNE.DODGE_KAPPA_CORNER_RAD then
                    local from, to = ss[m] - reach, ss[m] + reach
                    if floor > from then from = floor end
                    if to > lineEnd then to = lineEnd end -- 越過線尾會讓 last>n 退成整條尾段
                    if from < to then
                        local k3 = MDADDynamics.polylineKappaMax(xs, ys, n,
                            ovIndexFloor(s0, step, from), ovIndexCeil(s0, step, to))
                        if k3 > kappa then kappa = k3 end
                    end
                end
            end
            m = m + 1
        end
    end
    return kappa
end

-- 各點只負擔所在地的轉場；遠處短出口用反向包絡接近，不綁死整個長入口。
-- 曲率直接量同一條已掃掠世界線，保持段的路線彎曲也不能漏掉。
function Drive.dodgePointCap(s, k, margin, lat, reserve, protected)
    local fs, vp = s.fstate, s.vehicleProfile
    local sk = k == fs.ovN and fs.ovEndS or fs.ovS0 + (k - 1) * MDADFollower.OV_STEP
    local dl, length = s.dodgeShapeDl, s.dodgeEntryLength
    local sh, space = TUNE.DODGE_HOLD_SH, s.gearCap
    if sk >= fs.offC then
        dl, length = s.dodgeStay and 0 or s.dodgeExitDl, s.dodgeExitLength
    elseif sk >= fs.offB or (sk < fs.offA and not s.dodgeStay) then
        dl = 0
    end
    if not finite(dl) or dl < 0 or not finite(length) or length <= 0 then return nil end
    local tune = TUNE.DODGE_TUNE
    local floorCurve = protected and MDADDynamics.DODGE_CAP_FLOOR_KMH or tune.floor
    if dl > 0 then
        sh = math.min(1, 1.2 * dl / length)
        space = MDADDynamics.shiftSpaceSpeedCapKmh(dl, length, lat,
            vp.wheelbase, vp.delta0Safe, vp.deltaVSafe, vp.maxSpeed,
            protected and MDADDynamics.LATERAL_JERK_MAX or tune.jerkCap)
    end
    local reach = math.ceil(s.bodyReach / MDADFollower.OV_STEP)
    local kappa = MDADDynamics.polylineKappaMax(fs.ovX, fs.ovY, fs.ovN,
        math.max(1, k - reach - 1), math.min(fs.ovN, k + reach + 1))
    local curve = MDADDynamics.curveSpeedCapKmh(kappa, lat,
        vp.wheelbase, vp.delta0Safe, vp.deltaVSafe, vp.maxSpeed)
    local motion = MDADDynamics.dodgeSpeedCapKmh(s.gearCap,
        math.min(s.profileEnvelope, math.max(space, floorCurve)),
        math.max(curve, floorCurve), s.gearCap, s.dodgeVisibilityCap, s.dodgeClass)
    local floor = MDADDynamics.crawlFloorKmh(margin, TUNE.DODGE_COMMIT_MIN_KMH,
        TUNE.DODGE_CRAWL_MID_KMH, TUNE.DODGE_CRAWL_MID_MARGIN_M)
    return math.min(motion, math.max(floor,
        MDADDynamics.clearanceCapKmh(margin, reserve, 0.3, lat, sh)))
end

-- 固定基準先決定追蹤保護，再套風格速限。commit 與 guard 共用，避免 reserve
-- 0.15→0.10 把原本的 crawl 變 GO；低帽升格當輪仍只抬 5/10，不立即豁免 reserve
-- 再算一次（m=0.25 原本 10，不可因分類提前而變 19.2）。
local function updateDodgeCaps(s, margin, kappa, minLat, visibilityCap, commit, entryPassed)
    local vp = s.vehicleProfile
    s.dodgeEnvN = 0
    if commit then s.dodgeEntryPassed = false end
    if not finite(s.gearCap) or not finite(s.profileEnvelope)
            or not finite(s.dodgeCommitDl) or s.dodgeCommitDl < 0 then
        s.dodgeSpeedCap, s.dodgeHoldCap = 0, 0
        return "dynamics-invalid"
    end
    if entryPassed and (not finite(s.dodgeExitLength) or s.dodgeExitLength <= 0
            or not finite(s.dodgeExitDl) or s.dodgeExitDl < 0) then
        s.dodgeSpeedCap, s.dodgeHoldCap = 0, 0
        return "dynamics-invalid"
    end
    local rawCurve = MDADDynamics.curveSpeedCapKmh(kappa, minLat,
        vp.wheelbase, vp.delta0Safe, vp.deltaVSafe, vp.maxSpeed)
    local sh = 0.05
    if finite(s.dodgeCommittedLength) and s.dodgeCommittedLength > 0 then
        sh = math.min(1, 1.2 * s.dodgeCommitDl / s.dodgeCommittedLength)
    end
    local protected = s.dodgeCrawl or s.dodgeTight
    local reserveUsed = protected and 0 or TUNE.DODGE_CLEARANCE_RESERVE
    local clearance = MDADDynamics.clearanceCapKmh(margin, reserveUsed, 0.3, minLat, sh)
    if commit and not protected and clearance <= 0 and finite(margin) and margin > 0 then
        s.dodgeCrawl = true
        reserveUsed = 0
        clearance = MDADDynamics.clearanceCapKmh(margin, 0, 0.3, minLat, sh)
    end
    local baseSpace = dodgeSpaceCapOf(s, true, false)
    if not finite(baseSpace) or baseSpace < 0 then
        s.dodgeSpeedCap, s.dodgeHoldCap = 0, 0
        return "dynamics-invalid"
    end
    local referenceCurve = math.max(rawCurve, MDADDynamics.DODGE_CAP_FLOOR_KMH)
    local referenceProfile = math.min(s.profileEnvelope,
        math.max(baseSpace, MDADDynamics.DODGE_CAP_FLOOR_KMH))
    local cap, _, reason = MDADDynamics.dodgeSpeedCapKmh(s.gearCap, referenceProfile,
        referenceCurve, clearance, visibilityCap, s.dodgeClass)
    local floor = MDADDynamics.crawlFloorKmh(margin, TUNE.DODGE_COMMIT_MIN_KMH,
        TUNE.DODGE_CRAWL_MID_KMH, TUNE.DODGE_CRAWL_MID_MARGIN_M)
    local lifted = cap > 0 and cap < floor
    if lifted then
        cap = floor
        s.dodgeCrawl = true
    end
    protected = s.dodgeCrawl or s.dodgeTight
    local curve, space = referenceCurve, baseSpace
    local holdCap = cap
    local tune = TUNE.DODGE_TUNE
    local curveFloor = protected and MDADDynamics.DODGE_CAP_FLOOR_KMH or tune.floor
    -- 入口已驗證通過後，不得再被舊入口的低帽升格短路鎖住保持段。
    if reason == nil and cap > 0 and (not lifted or entryPassed) then
        local reserve = protected and 0 or tune.reserve
        if entryPassed then
            -- 只忘掉已過的 entry；exit 原過渡長與側移需求仍完整保留。
            sh = math.min(1, 1.2 * math.max(s.dodgeCommitDl, s.dodgeExitDl) / s.dodgeExitLength)
        end
        if entryPassed or not protected then
            reserveUsed = reserve
            clearance = MDADDynamics.clearanceCapKmh(margin, reserve, 0.3, minLat, sh)
        end
        curve = math.max(rawCurve, curveFloor)
        space = dodgeSpaceCapOf(s, protected, entryPassed)
        if not finite(space) or space < 0 then
            cap, reason = 0, "dynamics-invalid"
        else
            local profileCap = math.min(s.profileEnvelope, math.max(space, curveFloor))
            cap, _, reason = MDADDynamics.dodgeSpeedCapKmh(s.gearCap, profileCap,
                curve, clearance, visibilityCap, s.dodgeClass)
            -- 保持段（entry 已過、還沒到 c）的帽（0907c；session-062 t=17-25 使用者「這裡還慢是
            -- 正常的嗎」：offL 0.25、餘裕 0.55、出口過渡被路口壓到 3.3m → sh 0.37 → clearance 10.6
            -- 綁死 32m 平行保持段）：clearance 的 sinHeading 是「側移中橫向速度佔比」，保持段車身
            -- 平行、橫向只剩追線抖動，用 DODGE_HOLD_SH；出口過渡的 space／curve 也不綁保持段（由
            -- stepFollow 對 offC 做 approach envelope 收到 dodgeSpeedCap）。不低於 cap。
            if entryPassed then
                local clearanceHold = MDADDynamics.clearanceCapKmh(margin, reserve, 0.3, minLat,
                    TUNE.DODGE_HOLD_SH)
                holdCap = MDADDynamics.dodgeSpeedCapKmh(s.gearCap, s.profileEnvelope,
                    s.gearCap, clearanceHold, visibilityCap, s.dodgeClass)
            else
                holdCap = cap
            end
        end
    end
    -- 同一脫困 episode 的貼縫再出發，不能剛承諾爬行就被下一個 guard 輪抬速。
    -- 完整通過縫口並對正（entryPassed）後仍沿原規則放行。
    if s.episodeActive and s.dodgeCrawl and not entryPassed and cap > floor then
        cap, holdCap = floor, floor
    end
    if cap > 0 and cap < floor then cap = floor end
    -- 每個位置都有自己的窄點帽，不能只把全域最小值搬到最遠那一點。
    -- 淨距借既有guard掃掠收集；每輪只做有界反向滑行包絡，不再查世界。
    local fs, n = s.fstate, s.dodgeClrN or 0
    if reason == nil and cap > 0 and not s.episodeActive
            and s.profile
            and fs and n >= 2 and n == fs.ovN
            and s.dodgeClrS0 == fs.ovS0 and s.dodgeClrS1 == fs.ovEndS
            and not finite(s.dodgeDemoteS) then
        local first, env = s.dodgeClrK0, s.dodgeEnv
        local coast = finite(s.safeCoast) and math.max(0, s.safeCoast) or 0
        s.dodgeVisibilityCap = visibilityCap
        local valid = true
        for k = n, first, -1 do
            local m = s.dodgeClr[k]
            if not finite(m) or m < 0 then valid = false; break end
            local v = Drive.dodgePointCap(s, k, m, minLat, reserveUsed, protected)
            if not finite(v) or v < 0 then valid = false; break end
            if k < n then
                local dx, dy = fs.ovX[k + 1] - fs.ovX[k], fs.ovY[k + 1] - fs.ovY[k]
                v = math.min(v, MDADDynamics.approachCapKmh(
                    sqrt(dx * dx + dy * dy), env[k + 1], 0, coast))
            end
            env[k] = v
        end
        if valid then
            s.dodgeEnvN, s.dodgeEnvCoast, s.dodgeEnvLat = n, coast, minLat
        end
    end
    if not finite(holdCap) or holdCap < cap then holdCap = cap end
    s.dodgeKappa, s.dodgeClearance = kappa, margin
    s.dodgeCurveCap, s.dodgeClearanceCap = curve, clearance
    s.dodgeVisibilityCap, s.dodgeSpaceCap = visibilityCap, space
    s.dodgeSpeedCap, s.dodgeHoldCap = cap, holdCap
    s.dodgeEntryPassed = entryPassed == true
    return reason
end

-- 繞行承諾中車身是否對上承諾線（TUNE.DODGE_ALIGN_*）：|偏線| ≤ 門檻（lastLatDev 在繞行中＝對承諾線的
-- lineLat；門檻隨車身前方逐點淨距放寬，見 TUNE.DODGE_ALIGN_DEV_MAX_M）且真車頭對 ov 線本格切線 ≤ 5°。缺資料＝未對正。
-- 逐點提速資格與未對正不加速共用這一份。
function Drive.dodgeAligned(s)
    local fs = s.fstate
    if not finite(s.lastVehicleHeading) or not finite(s.lastLatDev)
            or type(fs.ovX) ~= "table" or not finite(fs.ovS0) or not finite(fs.ovN) then return false end
    local k = ovIndexFloor(fs.ovS0, MDADFollower.OV_STEP, s.lastSNow)
    if k < 1 or k >= fs.ovN then return false end
    local tol = TUNE.DODGE_ALIGN_DEV_M
    if (s.dodgeClrN or 0) == fs.ovN and s.dodgeClrS0 == fs.ovS0 and s.dodgeClrS1 == fs.ovEndS
            and k >= (s.dodgeClrK0 or fs.ovN + 1) then
        local m = 1e9
        for j = k, math.min(fs.ovN, k + math.ceil(s.bodyReach / MDADFollower.OV_STEP)) do
            local mj = s.dodgeClr[j]
            if not finite(mj) then m = 0 break end
            if mj < m then m = mj end
        end
        if m * 0.5 > tol then tol = math.min(m * 0.5, TUNE.DODGE_ALIGN_DEV_MAX_M) end
    end
    if math.abs(s.lastLatDev) > tol then return false end
    local dx, dy = fs.ovX[k + 1] - fs.ovX[k], fs.ovY[k + 1] - fs.ovY[k]
    local len = sqrt(dx * dx + dy * dy)
    if not finite(len) or len <= 1e-6 then return false end
    return cos(s.lastVehicleHeading) * dx + sin(s.lastVehicleHeading) * dy >= len * TUNE.DODGE_ALIGN_COS
end

-- 未對正不加速（TUNE.DODGE_ALIGN_*）：帽夾在剛偏離時的車速（下限 DODGE_COMMIT_MIN_KMH），只擋加速、不另外減速。
-- 夾的值閂住（s.dodgeAlignHoldKmh），只跟著自己的帽往下：每幀改夾「當下車速」時，外力掉速（撞殭屍、被推）會被
-- 當成新上限一路棘輪往下（1004a 正式服 0.18.2 kanazawa clip-10：13.8→6 km/h 爬 1.5 秒，玩家接手）。
function Drive.dodgeAlignCap(s, applied, speedKmh)
    s.dodgeAlignHold = false
    if Drive.dodgeAligned(s) then
        s.dodgeAlignHoldKmh = nil
        return applied
    end
    local hold = s.dodgeAlignHoldKmh
    if not finite(hold) then hold = finite(speedKmh) and speedKmh or 0 end
    if applied < hold then hold = applied end
    if hold < TUNE.DODGE_COMMIT_MIN_KMH then hold = TUNE.DODGE_COMMIT_MIN_KMH end
    s.dodgeAlignHoldKmh = hold
    if hold >= applied then return applied end
    s.dodgeAlignHold = true
    return hold
end

-- Kahlua的stepFollow local槽接近上限，查表獨立；nil代表仍用原帽，絕非淨空。
-- 不再要求線尾在可視範圍內（1002o）：表裡每一點都是看得到時量的（縮窗時 sweepLine 只重量看得到的那段、
-- 其餘沿用同一條線舊值），逐點帽本身含 dodgeVisibilityCap（停在可視前緣前），未掃區的安全照舊由它管。
function Drive.dodgeEnvelopeCap(s, speedKmh, now)
    if s.episodeActive
            or s.dodgeGuardFailed or s.blocked
            or not s.sensor.ready or s.sensor.hardOverflow ~= false
            or not finite(s.dodgeEnvCoast) or not finite(s.dodgeEnvLat)
            or not finite(s.safeCoast) or not finite(s.safeLat)
            or s.safeCoast < s.dodgeEnvCoast or s.safeLat < s.dodgeEnvLat
            or not finite(now) or not finite(s.sensor.stamp)
            or now < s.sensor.stamp or now - s.sensor.stamp > MDADDynamics.SNAPSHOT_FRESH_MS
            or not finite(s.fstate.offB)
            or (s.dodgeEnvN or 0) < 2 then return nil end
    local fs = s.fstate
    local k = ovIndexFloor(fs.ovS0, MDADFollower.OV_STEP, s.lastSNow)
    if k < s.dodgeClrK0 or k >= s.dodgeEnvN then return nil end
    local allowed = s.dodgeEnv[k]
    local aligned = Drive.dodgeAligned(s)
    local look = math.max(math.abs(speedKmh), allowed) * 0.5 / 3.6
    -- 查當下車身與整個反應窗，不能跨過較早的短窄處只讀到後面的高帽。
    for j = k + 1, s.dodgeEnvN do
        allowed = math.min(allowed, s.dodgeEnv[j])
        -- 先包含目前格的下一點，再量反應窗；不低估格內已走的距離。
        if j > k + 1 then
            local dx, dy = fs.ovX[j] - fs.ovX[j - 1], fs.ovY[j] - fs.ovY[j - 1]
            look = look - sqrt(dx * dx + dy * dy)
        end
        if look <= 0 then break end
    end
    if not aligned then allowed = math.min(allowed, s.dodgeSpeedCap) end
    return allowed
end

-- entry 的過期限速只在積極保持段移除。真車頭對已掃線切線，不用 pursuit 誤差
-- 冒充姿態；COM 偏移計入車尾距離。缺少新鮮世界／幾何／追蹤證據一律維持整線帽。
local function dodgeEntryPassed(s, now)
    local fs, vp, sen = s.fstate, s.vehicleProfile, s.sensor
    if type(fs) ~= "table" or type(vp) ~= "table" or type(sen) ~= "table"
            or type(s.profile) ~= "table" or not finite(s.profile.length)
            or type(fs.ovX) ~= "table" or type(fs.ovY) ~= "table" then return false end
    if not s.dodging or s.dodgeStay
            or not sen.ready or sen.hardOverflow ~= false
            or not finite(sen.stamp) or sen.stamp <= 0 or not finite(now)
            or now < sen.stamp or now - sen.stamp > MDADDynamics.SNAPSHOT_FRESH_MS
            or not finite(fs.offB) or not finite(fs.offC) or not finite(fs.offD)
            or not Drive.candidateCovered(s, fs.ovEndS)
            or not finite(s.lastSNow) or not finite(vp.halfL)
            or not finite(vp.centerOfMassX) or not finite(vp.centerOfMassZ)
            or not finite(s.lastLatDev) or not finite(s.lastVehicleHeading)
            or not finite(s.dodgeMargin) or s.dodgeMargin <= 0
            or math.abs(s.lastLatDev) > math.min(0.15, s.dodgeMargin * 0.5)
            or not finite(s.dodgeEntryLength) or s.dodgeEntryLength <= 0
            or not finite(s.dodgeExitLength) or s.dodgeExitLength <= 0
            or not finite(s.dodgeExitDl) or s.dodgeExitDl < 0
            or not finite(s.dodgeSpaceLat) or s.dodgeSpaceLat <= 0
            or not finite(s.dodgeShapeDl) or s.dodgeShapeDl < 0
            or not finite(fs.ovS0) or not finite(fs.ovEndS)
            or not finite(fs.ovN) or fs.ovN < 3
            or fs.ovEndS < math.min(fs.offD, s.profile.length) then return false end
    local rear = vp.halfL + math.abs(vp.centerOfMassX) + math.abs(vp.centerOfMassZ) + 1
    if s.lastSNow <= fs.offB + rear or s.lastSNow >= fs.offC then return false end
    local i = math.floor((s.lastSNow - fs.ovS0) / MDADFollower.OV_STEP) + 1
    if i < 1 or i >= fs.ovN then return false end
    local x0, y0, x1, y1 = fs.ovX[i], fs.ovY[i], fs.ovX[i + 1], fs.ovY[i + 1]
    if not finite(x0) or not finite(y0) or not finite(x1) or not finite(y1) then return false end
    local dx, dy = x1 - x0, y1 - y0
    local length = sqrt(dx * dx + dy * dy)
    if length <= 1e-6 then return false end
    local dot = cos(s.lastVehicleHeading) * dx + sin(s.lastVehicleHeading) * dy
    return dot >= length * 0.996194698 -- cos(5°)
end

-- 「擋線點」判定（plan 檔語意、單一定義）：MDADCorridor.blocksLine，Corridor.plan 步驟①②同一支。
-- resolveBlockAnchor（lineOnly）、nearestLineBlocker（exit 釋放／貼縫死路）、updatePerception 共用；不得
-- 在 replan 內再手寫一份（190-local 閘門＋三份漂移風險）。橫向位置用引擎形狀（Sensor hardLc／hardW，與世界掃掠
-- 同一份幾何，1005）；呼叫端只問 i ≤ sen.hardN 的點（附加的虛擬 ban 沒有形狀位置）。
-- 逐點行駛基準線（Corridor.plan 第 12 參）：第 i 個硬點所在弧長的實際落點（clampLane 沿弧長
-- 連續版；弧內側與弧前後 12m 會被收緊）。表重用（s.hardBase），只在 replan 冷路徑填。
-- 正在走 exact line（RETURN 目標線／crawl-exact 直行）時那條線不經 clampLane＝常數 lane，基準線
-- 照舊常數（harness (R)：crawl lane 4.0 旁 l 5.5 的硬物，夾過的 2.3 會誤判不擋）。
local function fillHardBase(s, sen, planN, baseL)
    local prof, tbl = s.profile, s.hardBase
    if tbl == nil then tbl = {}; s.hardBase = tbl end
    s.hardBaseStamp = sen.stamp -- resolveBlockAnchor 只認同一快照填的逐點基準
    if type(prof) ~= "table" or prof.ready ~= true or prof.laneRoomR == nil
            or (s.fstate and s.fstate.exactLine == true) then
        for i = 1, planN do tbl[i] = baseL end
        return tbl
    end
    for i = 1, planN do
        local hs = sen.hardS[i]
        tbl[i] = MDADFollower.laneBiasAt(prof, baseL, MDADFollower.segIndexAt(prof, hs), hs, Drive.baseKeepOf(s))
    end
    return tbl
end
local function blocksLine(sen, i, bl, nh)
    return MDADCorridor.blocksLine(sen.hardL, sen.hardR, sen.hardLc, sen.hardW, i, bl, nh)
end

-- 預檢與正式規劃共用同一組群／候選，避免預檢普通縫、正式卻換成彎道加寬縫。
function Drive.planDodge(s, baseL, prefer)
    local sen, planN = s.sensor, s.sensor.hardN
    if s.pushBanL ~= nil then
        planN = planN + 1
        sen.hardS[planN], sen.hardL[planN] = s.pushBanS, s.pushBanL
        sen.hardX[planN], sen.hardY[planN], sen.hardR[planN] = 0, 0, 0.6
        sen.hardLc[planN], sen.hardW[planN] = nil, nil -- 虛擬 ban 沒有形狀位置：擋線判定退回 hardL／hardR
    end
    fillHardBase(s, sen, planN, baseL)
    local minS = s.lastSNow - s.vehicleProfile.halfL
    local need, tight = s.needHalf, false
    local mode, a, b, c, d, offL = MDADCorridor.plan(
        sen.hardS, sen.hardL, planN, need, sen.corridorHalf or MDADSensor.CORRIDOR_HALF,
        prefer, sen.hardR, baseL, sen.roadLo, sen.roadHi, s.pushBanL == nil, s.hardBase, minS, sen.corridorInner,
        sen.hardLc, sen.hardW)
    if mode ~= "dodge" and mode ~= "clear" then
        local m, aa, bb, cc, dd, ll = MDADCorridor.plan(
            sen.hardS, sen.hardL, planN, s.squeezeNeed, sen.corridorHalf or MDADSensor.CORRIDOR_HALF,
            prefer, sen.hardR, baseL, sen.roadLo, sen.roadHi, s.pushBanL == nil, s.hardBase, minS, sen.corridorInner,
            sen.hardLc, sen.hardW)
        if m == "dodge" then
            mode, a, b, c, d, offL, need = m, aa, bb, cc, dd, ll, s.squeezeNeed
        end
    end
    if mode == "dodge" and routeTurnWithin(s.profile, a, d) > CURVE_TIGHT_RAD then
        local m, aa, bb, cc, dd, ll = MDADCorridor.plan(
            sen.hardS, sen.hardL, planN, s.needHalf + CURVE_NEED_EXTRA,
            sen.corridorHalf or MDADSensor.CORRIDOR_HALF,
            prefer, sen.hardR, baseL, sen.roadLo, sen.roadHi, s.pushBanL == nil, s.hardBase, minS, sen.corridorInner,
            sen.hardLc, sen.hardW)
        tight = true
        if m == "dodge" then
            mode, a, b, c, d, offL, need = m, aa, bb, cc, dd, ll, s.needHalf + CURVE_NEED_EXTRA
        end
    end
    return mode, a, b, c, d, offL, need, tight, planN
end

-- 只預檢幾何能否進候選鏈，不改舊承諾；世界掃掠仍由正式候選鏈裁決。
-- shape 的輸出寫入重用 scratch，不能污染舊線的長度、側移或速度。
function Drive.handoffReady(s)
    local base = laneBiasOf(s)
    local mode, a, b, c, d, offL = Drive.planDodge(s, base, base)
    if mode ~= "dodge" then return true end
    if c + 1 + Drive.towHold(s) > s.lastSNow + TUNE.DODGE_OV_SPAN then return false end
    local p = s.dodgePreview
    if p == nil then p = {}; s.dodgePreview = p end
    p.lastSNow, p.lastLatSigned, p.fstate = s.lastSNow, s.lastLatSigned, s.fstate
    p.vehicleProfile, p.gearCap, p.safeLat = s.vehicleProfile, s.gearCap, s.safeLat
    p.laneChained, p.stayHoldEndS = s.laneChained, s.stayHoldEndS
    p.laneRatio, p.roadBias = s.laneRatio, s.roadBias -- 預覽要跟真承諾同一個短設計判定
    p.sensor, p.bodyReach, p.steepDeficitM = s.sensor, s.bodyReach, -1
    p.tow = s.tow -- 拖車保持段延長（Drive.towHold）要跟真候選同一個幾何
    local _, _, _, endS, ok = shapeProfile(p, s.profile, a, b, c, d, offL, base)
    -- 主候選連形都塑不出來（entry／steep：下一群就在車身旁、從真實橫向來不及切入）＝不交接（1002t）：
    -- 舊線活著就沿舊線，判死的舊線有自己較遠的守護停止線；下一完成輪再問。舊制 `not ok` 也算可交接＝
    -- 交出仍有效的舊線，正式鏈從常駐線把車旁那群當第一群、候選全滅，停止線落在車身處 34 km/h 鎖輪
    -- （正式服 0.17.0 兩段片段同一處；交接晚幾公尺就是正常的行駛中交接）。
    return ok and not p.dodgeWindowShort and Drive.candidateCovered(s, endS + 1)
end

-- 出口提前釋放會不會讓 RETURN 立刻接手（0928j；rc8 0086：offL −2.5、常駐 1.5，整車過 c 即放 →
-- 偏離 3.8m 進 RETURN，25 km/h 爬回 2.5 秒；承諾線出口 45m、那時套用中的繞行帽已是 60）：
-- 車離常駐線超過 RETURN 進入門檻就沿承諾線把出口走完。
-- 0929e 起低帽（貼縫爬行）也一樣：舊制讓爬行檔照舊提前放、以為 RETURN 25 比較快，但 RETURN 的線
-- 從車現在的偏移斜切回常駐線，常被剛繞過的那群打回（全部 E2E＋正式服：爬行繞行後 RETURN 進入
-- 190 次，hold 60 次、其中 stall 11 次、接觸 5 次；rc28 0009：hold(sweep) → 靜止釋放交 pure
-- pursuit → 6 km/h 頂上剛繞過的硬物）。承諾線出口是掃掠驗過的線，慢一點走完它。
-- 0929h 起離常駐線不到 RETURN 門檻（2–3m）時，只要還超過 EXIT_KEEP_DEV、且承諾線在車身以後還有窄點
-- （guard 收集的逐點淨距 < EXIT_KEEP_CLEAR）也沿線走完；表不在或對不上這條線＝沒有證據，照舊放。
-- rc33 0004：offL 4.25 的出口段，守護輪已因出口旁的物件把帽壓到爬行 5，車離常駐線 1.7m 即放手，對線帽
-- 40 讓車從 19 加速到 23.5，pure pursuit 從 3.9 斜切回 2.0 比承諾線慢收，頂上那個物件。出口淨空就照舊
-- 放：rc34 0030 出口段疊在 R≈6 的彎上，承諾線的前饋只算中心弧，留著反而切進彎內。
function Drive.exitKeepsDodge(s)
    local lat = s.lastLatSigned
    if not finite(lat) then return false end
    local resident = MDADFollower.laneBiasAt(s.profile, laneBiasOf(s), s.fstate.idx, s.lastSNow, s.fstate.laneKeep)
    local dev = math.abs(lat - resident)
    local available = 2
    if finite(s.currentSegWidth) and s.currentSegWidth > 0 then
        available = s.currentSegWidth * 0.5 - s.vehicleProfile.halfW - MDADDynamics.ROAD_EDGE_MARGIN
    end
    if available < 2 then available = 2 elseif available > 3 then available = 3 end
    if dev > available then return true end
    if dev <= TUNE.EXIT_KEEP_DEV then return false end
    local fs, n = s.fstate, s.dodgeClrN or 0
    if n < 2 or n ~= fs.ovN or s.dodgeClrS0 ~= fs.ovS0 or s.dodgeClrS1 ~= fs.ovEndS
            or not finite(fs.ovS0) then return false end
    local k0 = ovIndexFloor(fs.ovS0, MDADFollower.OV_STEP, s.lastSNow - s.vehicleProfile.halfL)
    if k0 < s.dodgeClrK0 then k0 = s.dodgeClrK0 end
    for k = k0, n do
        local m = s.dodgeClr[k]
        if not finite(m) or m < TUNE.EXIT_KEEP_CLEAR then return true end
    end
    return false
end

-- 前方（弧長 ≥ minS）最近的擋線點索引；nil＝淨空。O(hardN)、零配置；冷路徑用。
-- 兩個消費者：exit 提前釋放（只問有沒有）、貼縫檔死路判定（2026-09-02 使用者裁定
-- 「複雜的障礙人工處理」：繞行出口 d+1 之後仍有擋線點＝多重障礙＝不鑽，要點位）。
-- 基準＝回線 lane（`Drive.dodgeHomeL`）：RETURN hold 讓位規劃時出口之後走的是回線目標，不是車位。
local function nearestLineBlocker(s, sen, minS)
    local bl0, nh = Drive.dodgeHomeL(s), s.needHalf
    local prof = s.profile
    local bi = nil
    for i = 1, sen.hardN do
        local hs = sen.hardS[i]
        if hs >= minS and (bi == nil or hs < sen.hardS[bi]) then
            -- 擋線基準用該點所在段**夾過彎內側餘裕**的 lane（2026-09-04 st146254：
            -- 路口右轉內側角落物群以裸 +1.5 判「出口後仍擋線」拒掉全部貼縫候選，
            -- 實際轉彎時 lane 已被 laneRoom 夾回中線、角落物不在行駛線上）
            local bl = MDADFollower.laneBiasAt(prof, bl0, MDADFollower.segIndexAt(prof, hs), hs, Drive.baseKeepOf(s))
            if blocksLine(sen, i, bl, nh) then bi = i end
        end
    end
    return bi
end

-- 停穩交接退路：承諾線被下一群的滑行停點（dodgeNextCap）停住時，釋放舊線交給同一輪重規劃。
-- 平常要整車越過 c（c+bodyReach，理由見 exitReady 的 K5 註解）才放；但下一群的停點是圓盤距離
-- （中心距−bodyReach−r），斜前方的物件會把車停在 c+bodyReach 之前，車永遠到不了門檻＝停等到受困交還
-- （0929k E2E Oshkosh C 段：下一顆巨石在右前方 5.7m，車停在門檻前 0.13m，12 秒後交還）。進入段已走完（過 b）、
-- 而且已經開到停點（dodgeNextDist ≤ NEXT_HANDOFF_M）就交接；停點之前的零帽（滑行能力為 0）照舊停等。
-- 過 b 而非過 c（E2E m1004g dixie9050w：出口被截到 1.41m、下一台貼在 d 後，停點落在 c 前 1.5m＝車永遠到不了 c，
-- 停等 15 秒交還）：交接後同一輪重規劃從車實際橫向把舊群尾＋下一台當一群（原地承諾），規劃不出就照判堵階梯；
-- 交接 hold 維持零帽到新線採納，不會從偏移位置切回常駐線（K5）。
function Drive.nextStopHandoff(s, speedKmh)
    local fs = s.fstate
    if not finite(fs.offB) or not finite(fs.offC) or not finite(fs.offD) then return false end
    local past = s.lastSNow >= fs.offC + s.bodyReach
        or (s.lastSNow >= (s.dodgeStay and fs.offC or fs.offB) -- 停留照舊過 c（stayLanePending 過 b 才寫 laneBias）
            and finite(s.dodgeNextDist) and s.dodgeNextDist <= TUNE.NEXT_HANDOFF_M)
    if not past or not finite(s.dodgeNextCap) or s.dodgeNextCap < 0
            or s.dodgeNextCap >= MDADDynamics.MIN_EXEC_KMH
            or s.dodgeGuardFailed or s.currentBlocked or s.returnActive or fs.rotating
            or s.recoverWhy ~= nil or not finite(speedKmh) or speedKmh >= 1 or speedKmh <= -1 then
        return false
    end
    return nearestLineBlocker(s, s.sensor, fs.offD) ~= nil
end

-- 遠於承諾線的車流仍由跟車接近帽照管，不讓它把當前繞行／交接整體降級。
function Drive.movingWithin(s, endS)
    if not s.sensor.movingVeh then return false end
    return not finite(endS) or not finite(s.sensor.vehAheadS)
        or s.sensor.vehAheadS <= endS + s.bodyReach
end

-- 軟障礙只靠斷油滑行減速；感知距離變大不等於現在就要套遠處物件的平帽。
-- 靜止軟物也保留同樣的近端到位緩衝，不因來源從殭屍切成屍體／雜物而改變減速節奏。
function Drive.approachSoftCap(s, nearS, cap)
    if not finite(nearS) then return cap end
    return MDADDynamics.approachCapKmh(
        nearS - s.lastSNow - s.vehicleProfile.halfL - TUNE.ZOMBIE_APPROACH_LEAD_M,
        cap, 0.5, finite(s.safeCoast) and math.max(0, s.safeCoast) or 0)
end

-- 堵住時放寬橫向掃描（0929p，使用者裁定「允許繞到道路之外的地方繞路」）：一般帶只看目前車道 ±6.5m，14m 大路
-- 整條被擋（E2E semi-long-mp block：三台車連路肩擋死）就無縫可找，兩側草地根本不在點雲裡。這次判堵已經開到
-- 停點（s.wideArmed／wideArmedS，stepFollow 在 blockedStop 時武裝）且幾乎停住時要求寬帶（±14m，MDADSensor 每幀
-- 額度不變、前視自動縮短），Corridor 候選因此可到路外；照寬帶承諾的繞行走完前維持寬帶，守護輪才看得到承諾線兩側。
-- 行駛中、或群還在遠處（先開近、一般帶重判）維持一般帶。武裝撐過倒車：倒車成功會清 blocked，退出來的跑道要在
-- 起步前（還停著，Drive.blockedAtStop）就用寬帶重判；承諾繞行／判定淨空（replan）或開過武裝點才解除。
-- 停著判堵回 "stop"：Sensor 這一輪看 100m、輪時放寬（見 MDAD_Sensor WIDE_STOP_AHEAD_M）；繞行中回 true（一般寬帶）。
function Drive.wideScanWanted(s, speedKmh)
    if s.dodging and s.dodgeWide then return true end
    if s.wideArmed and not (finite(s.wideArmedS) and s.lastSNow <= s.wideArmedS + 1) then Drive.disarmWide(s) end
    if not s.blocked then return false end
    local v = finite(speedKmh) and (speedKmh < 0 and -speedKmh or speedKmh) or 99
    return s.wideArmed == true and v < TUNE.WIDE_SCAN_KMH and "stop" or false
end

-- 寬帶路外繞行承諾中，同目標的偏航重算新線先不收（1002t）：路外繞行偏離最遠約 12m，貼著主 MOD 偏航重算門檻
-- （12 格），收下＝releaseDodge 丟掉掃掠驗過的承諾線、新線起點吸在群旁重判（E2E rc43 0010：offL −12.5 承諾 7 秒
-- 後 cutover deviation → 從群旁重判、接觸 6 次）。繞完（dodging 解除）下一次取路照常 cutover；換目標、改道請求、
-- nav 版本變更照收；拖車維持現制（使用者 1002t 範圍：拖車以外的車輛）。
function Drive.holdWideReroute(s, sameTarget, sameVersion)
    return sameTarget and sameVersion and s.pendingRouteWhy == nil and not s.pendingDetour
        and s.dodging == true and s.dodgeWide == true and type(s.tow) ~= "table"
end

-- Knox Pass 大門（1005c，Sensor gateCell）的 telemetry：本輪快照有會替這台車開的關門時記 `gate` 事件——
-- phase far＝遠處、只當可視前緣；hard＝退回關門處理（why near＝車已接近、latch＝這扇門先前退回過）。
-- d＝車心到門格世界距離、speed＝車速、need＝本輪接近判距、x/y＝門格。同一扇門（8m 內）每個相位只記一次。
-- 1005e：本輪中央帶內有 Knox Pass 不會替這台車開的門（Sensor gateNoCell）＝提示玩家（Drive.gateWarn phase no）。
-- 在 replan 之後呼叫：同一幀的 blocked 語音先播、這句接著蓋掉它（比較具體）。
function Drive.gateNote(s, playerNum, vehicle, speedKmh)
    local sen = s.sensor
    if sen.gateNoX ~= nil then
        Drive.gateWarn(s, playerNum, vehicle, sen.gateNoX, sen.gateNoY, "no", sen.gateNoWhy, speedKmh)
    end
    local gx, gy = sen.gateX, sen.gateY
    if gx == nil then return end
    local phase = sen.gateHard and "hard" or "far"
    local lx, ly = s.gateLogX, s.gateLogY
    if lx ~= nil and (gx - lx) * (gx - lx) + (gy - ly) * (gy - ly) <= 64
            and (s.gateLogPhase == phase or s.gateLogPhase == "hard") then return end
    s.gateLogX, s.gateLogY, s.gateLogPhase = gx, gy, phase
    local dx, dy = gx - vehicle:getX(), gy - vehicle:getY()
    local d = math.sqrt(dx * dx + dy * dy)
    local why = sen.gateHard or nil
    diagEvent(s, playerNum, "gate", { phase = phase, why = why, d = d, speed = speedKmh, need = sen.gateNearM,
        x = gx, y = gy })
    if getDebug() then
        print(string.format("%spn=%d knox gate %s why=%s d=%.1f speed=%.1f need=%.1f at %.1f,%.1f",
            LOG, playerNum, phase, tostring(why), d, speedKmh or -1, sen.gateNearM or -1, gx, gy))
    end
end

-- Knox Pass 大門提示（1005e）：頭上提示＋右上 Toast＋語音 gate；同一 session 同一扇門（8m 內）只提示一次，兩種共用一格去重。
-- phase no＝不會替這台車開（文字帶 KnoxPassAPI.whyText(why)；VERSION<3、函式不在、出錯或回空時用通用句，detail 記
-- api／generic）；shut＝預告會開、車已因它停在門前而門仍關著（原因在伺服器端，不帶；detail＝觸發點 dwell／retry，見
-- Drive.gateShut／gateShutRetry）。記 `gate` 事件（why＝API 代碼，ms＝shut 的停住時長）。
-- E2E 讀 session 的 gateWarnPhase／gateWarnWhy／gateWarnText／gateWarnX／gateWarnY／gateWarnDetail。
function Drive.gateWarn(s, playerNum, vehicle, gx, gy, phase, why, speedKmh, ms, detail)
    local lx, ly = s.gateWarnX, s.gateWarnY
    if lx ~= nil and (gx - lx) * (gx - lx) + (gy - ly) * (gy - ly) <= 64 then return end
    local key, arg = "UI_MinidoracatAutoDrive_KnoxGateShut", nil
    if phase == "no" then
        local api = KnoxPassAPI
        if type(api) == "table" and type(api.VERSION) == "number" and api.VERSION >= 3
                and type(api.whyText) == "function" then
            local ok, text = pcall(api.whyText, why)
            if ok and type(text) == "string" and text ~= "" then arg = text end
        end
        key = arg and "UI_MinidoracatAutoDrive_KnoxGateNo" or "UI_MinidoracatAutoDrive_KnoxGateNoGeneric"
        detail = arg and "api" or "generic"
    end
    s.gateWarnX, s.gateWarnY, s.gateWarnPhase, s.gateWarnWhy, s.gateWarnDetail = gx, gy, phase, why, detail
    local playerObj = getSpecificPlayer(playerNum)
    s.gateWarnText = playerObj and haloBad(playerObj, key, arg) or nil
    voice("gate", playerNum)
    local dx, dy = gx - vehicle:getX(), gy - vehicle:getY()
    local d = math.sqrt(dx * dx + dy * dy)
    diagEvent(s, playerNum, "gate", { phase = phase, why = why, d = d, speed = speedKmh, ms = ms, detail = detail,
        x = gx, y = gy })
    if getDebug() then
        print(string.format("%spn=%d knox gate %s why=%s d=%.1f speed=%.1f ms=%s detail=%s at %.1f,%.1f text=%s",
            LOG, playerNum, phase, tostring(why), d, speedKmh or -1, tostring(ms), tostring(detail), gx, gy,
            tostring(s.gateWarnText)))
    end
end

-- 會開的門沒開（1005e／1005g）的共同條件：判堵中、本輪最近那扇會開的門已退回硬物（gateHard）且最新完整快照仍看得到它
-- （門開了 closedDoor 為假，Sensor 就不再回報）、判堵錨在那扇門 8m 內。成立回門格心，否則 nil。
function Drive.gateShutCell(s)
    local sen = s.sensor
    if s.blocked ~= true or type(sen) ~= "table" or not sen.gateHard then return nil end
    local gx, gy, bx, by = sen.gateX, sen.gateY, s.blockHitX, s.blockHitY
    if gx == nil or not (finite(bx) and finite(by)) or (bx - gx) * (bx - gx) + (by - gy) * (by - gy) > 64 then return nil end
    return gx, gy
end

-- 停住路徑（1005e，每幀）：stopped＝停在判堵停止線前（blockedStop）且幾乎不動；Drive.gateShutCell 成立時起算，之後要有
-- 一輪在停住 TUNE.GATE_SHUT_MS 後才開始的掃描仍看到門關著，才提示 shut（detail dwell）。門在接近途中或停下後打開＝條件
-- 斷掉、重新起算。跑道不足時停穩 BLOCK_STEEP_RETRY_MS 就倒車，停不滿——由 Drive.gateShutRetry 補。
function Drive.gateShut(s, playerNum, vehicle, now, speedKmh, stopped)
    local gx, gy = nil, nil
    if stopped then gx, gy = Drive.gateShutCell(s) end
    if gx == nil then
        s.gateShutSince = nil
        return
    end
    local since = s.gateShutSince
    if since == nil then
        s.gateShutSince = now
    elseif (s.sensor.roundStartedAt or 0) - since >= TUNE.GATE_SHUT_MS then
        Drive.gateWarn(s, playerNum, vehicle, gx, gy, "shut", nil, speedKmh, now - since, "dwell")
    end
end

-- 倒車重試路徑（1005g）：恢復 dispatch 剛執行 startRecoveryAttempt（blocked-retry 含跑道不足那條、倒得了或倒不了都算）
-- 之後呼叫。AutoDrive 自己決定「這個堵靠等不會好」的那一刻，Drive.gateShutCell 成立、而且門格現在仍是關著的門
-- （MDADSensor.gateClosedAt：停穩 BLOCK_STEEP_RETRY_MS 就倒車時，快照多半是停住前開始的那一輪，門可能剛開）＝提示 shut
--（detail retry）。預設讀頭範圍 8 格內伺服器就會開門，車停在停止線前門還關著就是沒開。排在倒車的 unstick 語音之後，
-- gate 接著蓋掉（同 gateNote 對 blocked）。ms＝停住路徑已計的停住時長（沒起算＝nil）。
function Drive.gateShutRetry(s, playerNum, vehicle, now)
    local gx, gy = Drive.gateShutCell(s)
    if gx == nil then return end
    local ok, closed = pcall(MDADSensor.gateClosedAt, s.sensor, vehicle, getCell(), gx, gy)
    if not (ok and closed == true) then return end
    local since = s.gateShutSince
    Drive.gateWarn(s, playerNum, vehicle, gx, gy, "shut", nil, vehicle:getCurrentSpeedKmHour(),
        since and now - since or nil, "retry")
end

-- 請求範圍只在輪首重算；同一群的許多點取最遠需求，不把每個點各加一次距離。
-- 畫面幀率的負擔控制在Sensor，這裡不把「想看更遠」誤當成「已經看見」。
function Drive.updatePerception(s, speedKmh)
    local sen, prof, vp = s.sensor, s.profile, s.vehicleProfile
    if not sen or not prof or not prof.ready then return end
    sen.softAheadM = MDADDynamics.softLookahead(speedKmh)
    -- Knox Pass 會開的門「接近」判距（Sensor gateCell、TUNE.GATE_NEAR_LEAD_S）：輪首寫、整輪用
    local vNear = finite(speedKmh) and (speedKmh < 0 and -speedKmh or speedKmh) / 3.6 or 0
    sen.gateNearM = Drive.blockStopDist(s) + vp.halfL + vNear * TUNE.GATE_NEAR_LEAD_S
    local rs = s.lastSNow
    local wanted = Drive.perceptionDistance()
    local maxM, extra = MDADDynamics.PERCEPTION_HARD_MAX_M, MDADDynamics.PERCEPTION_EXT_M
    if finite(speedKmh) and finite(s.safeBrake) and s.safeBrake > 0 then
        local v = speedKmh < 0 and -speedKmh or speedKmh
        local need = MDADDynamics.stoppingDistance(v / 3.6, 0.5, s.safeBrake, vp.halfL)
            + MDADDynamics.PERCEPTION_STOP_MARGIN_M
        if need > wanted then wanted = need end
    end
    if s.dodging and finite(s.fstate.ovEndS) then
        local active = s.fstate.ovEndS - rs + s.bodyReach
        if active > wanted then wanted = active end
    end
    local base = laneBiasOf(s)
    if sen.ready then
        for i = 1, sen.hardN do
            local hs = sen.hardS[i]
            if hs >= rs then
                local lane = MDADFollower.laneBiasAt(prof, base, MDADFollower.segIndexAt(prof, hs), hs)
                if blocksLine(sen, i, lane, s.needHalf) then
                    local need = hs - rs + extra
                    if need > wanted then wanted = need end
                end
            end
        end
    end
    if wanted > maxM then wanted = maxM end
    -- 已知剖面上的彎段可連鎖前瞻，不查Java世界，也不替未載入區提供碰撞保證。
    local i = MDADFollower.segIndexAt(prof, rs)
    while i < prof.n - 1 and prof.s[i + 1] <= rs + wanted do
        local turn = prof.segKind and prof.segKind[i] == MDADDynamics.SEG_ARC
        local dh = prof.segH[i + 1] - prof.segH[i]
        if dh > math.pi then dh = dh - 2 * math.pi elseif dh < -math.pi then dh = dh + 2 * math.pi end
        if dh < 0 then dh = -dh end
        if turn or dh >= MDADDynamics.FILLET_MIN_RAD then
            local need = prof.s[i + 1] - rs + extra
            if need > wanted then wanted = need end
            if wanted > maxM then wanted = maxM end
        end
        i = i + 1
    end
    sen.aheadM = wanted
end

-- 測試鉤（harness 鎖「擋線基準用夾過彎內側餘裕的 lane」）：回前方 minS 起最近擋線點的
-- 弧長，nil＝淨空。production 無呼叫者。
function Drive.debugLineBlocker(playerNum, minS)
    local s = sessions[playerNum]
    if not s or not s.sensor then return nil end
    local bi = nearestLineBlocker(s, s.sensor, minS or s.lastSNow)
    return bi and s.sensor.hardS[bi] or nil
end

-- dodge commit 事件的 pre-a 段（承諾線起點→a）最小物理淨距（1005 遙測；open-issue「pre-a 段物理檔窄縫沒有依
-- 淨距縮速」先定罪用）：候選掃掠只在 [a,c] 收淨距、逐點表要等守護輪才建，commit 當下沒有這段的數。以同一條承諾線
-- （fstate.ovX/Y）、物理檔 base 把 [ovS0, a] 當成淨距窗重掃一次，淨距＝sweepLine 餘裕＋SWEEP_PHYS_PAD（車身 OBB
-- 到形狀表面，與 pre-a 段掃掠同一個 pad）。冷路徑：每次 commit 一次；只讀不收表。nil＝pre-a 段不足兩個取樣點、
-- a 在線尾之外，或掃掠輸入無效。9 以上＝窗內沒有近物（sweepLine 的淨距上限）。
function Drive.preAClear(s)
    local fs, step = s.fstate, MDADFollower.OV_STEP
    if not finite(fs.ovN) or not finite(fs.ovS0) or not finite(fs.offA) then return nil end
    local k = math.floor((fs.offA - fs.ovS0) / step) + 1
    if k < 2 or k >= fs.ovN then return nil end
    local s1 = fs.ovS0 + (k - 1) * step
    -- 只量不留痕：sweepLine 命中會寫 blocked 事件的 kind（sweepHitBody）、每次呼叫累加 replan 掃掠數（sweepCount）
    local hitBody, nSweep = s.sweepHitBody, s.sweepCount
    local ok, m, _, _, _, _, _, hitI = sweepLine(s, fs.ovX, fs.ovY, k, fs.ovS0, s1, fs.ovS0, fs.ovS0, s1, s1,
        fs.offL, "pre-a", MDADVehicleProfile.sweepBase(s.vehicleProfile.halfW, "physical"), nil, false, false)
    s.sweepHitBody, s.sweepCount = hitBody, nSweep
    if ok then return m + SWEEP_PHYS_PAD end
    if hitI ~= nil then return SWEEP_PHYS_PAD - m end -- 命中：sweepHit 回 −淨距
    return nil
end

-- Candidate sweep and commitment consume the same complete preallocated line.
local function sweepCandidate(s, shapeOk, a, b, c, d, offL, baseL, tag, needBase)
    if not shapeOk then return 0, 0, false, 99, b, 3, b, 0, 0 end
    local ovN, ovS0, buildReason, lastCovered = MDADFollower.buildOffsetLine(
        s.profile, s.lastSNow, a, b, c, d, offL, baseL, s.tmpOvX, s.tmpOvY,
        nil, nil, nil, startLaneOf(s, baseL))
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
    local ok, margin, hardS, phase, sampleS, hitX, hitY, hitI = sweepLine(
        s, s.tmpOvX, s.tmpOvY, ovN, ovS0, lastCovered,
        a, b, c, d, offL, tag, needBase, nil, true)
    -- 貼縫檔（squeeze／physical）不得鑽進多重障礙（2026-09-02 s064／s001 兩輪定罪：
    -- 車陣第一台以 margin 0.09 的貼縫承諾、4 km/h 爬 20m，出口落在第二排車前——
    -- 就算擠過第一台也立刻再 blocked，代價是 40s＋接觸＋三次倒車 StopStuck；
    -- 使用者裁定「複雜的障礙人工處理」）。貼縫是單一障礙的最後手段：出口之後
    -- 路線仍有擋線點＝拒收→blocked→改道／交還階梯。cruise 檔不受影響（速度不掉、
    -- 下一段由下一輪 plan 處理）；單一縫（出口後淨空）照 2026-09-01「物理可過即過」。
    if ok and needBase < s.sweepBase - 1e-6 then
        local sen = s.sensor
        local bi = nearestLineBlocker(s, sen, d + 1)
        if bi then
            s.dodgeDeadendS = sen.hardS[bi] -- telemetry blocked 事件 blocker 欄
            if getDebug() then
                print(string.format(
                    "%ssweep deadend[%s] offL=%.2f d=%.1f next blocker s=%.1f: crawl refused",
                    LOG, tostring(tag or "?"), offL, d, sen.hardS[bi]))
            end
            return ovN, ovS0, false, 0, sen.hardS[bi], 4, d, sen.hardX[bi], sen.hardY[bi]
        end
    end
    return ovN, ovS0, ok, margin, hardS, phase, sampleS, hitX, hitY, hitI
end

-- 剖面在弧長 sk 的 lane（與 Follower.control／buildOffsetLine 同一條 smoothstep）：
-- nudge 判「命中點在線的哪一側」用。startL＝線的起始 lane（startLaneOf）。
local function profileLaneAt(a, b, c, d, l, bias, sk, startL)
    if sk <= a then return startL end
    if sk >= d then return bias end
    if sk < b then
        local t = (sk - a) / (b - a)
        t = t * t * (3 - 2 * t)
        return startL + (l - startL) * t
    elseif sk > c then
        local t = (d - sk) / (d - c)
        t = t * t * (3 - 2 * t)
        return bias + (l - bias) * t
    end
    return l
end

-- 停留線掃掠（TUNE.STAY_TAIL_M 註解）：rs→b 從 baseL 換到 offL、之後平行到 c＋車身，
-- 不回線。線用 buildOffsetLine 的 returnLane 覆寫模式建（RETURN 同款），覆蓋只到
-- dStay＝c＋halfL＋pad＋tail。回 ok, margin, ovN, ovS0, dStay, c；線留在 tmpOv 供 commit。
-- truncate：群長過可視距離（整排護欄、長車陣）——車開到群前、前緣跟著前進也驗不到停留線尾——
-- 時，保持段只到可視前緣容得下的地方。0928d E2E rc3 0030：F350 右側 80m 長的圍欄一路延伸到
-- 未載入區，主候選與停留線都驗不到出口，每輪延後、在群前停死到交還。收短的停留走完後常駐 lane
-- 已是 offL（鏈式），下一輪從停留 lane 規劃；常駐線仍被擋就不解鏈，等群尾看得到再回來。
-- 靠近就驗得到的群不收短：延後、到了再規劃完整繞行（停留是爬行檔，比有回線段的繞行慢）。
-- 寬帶停在停點（wideArmed）不會再往前開近：前緣不會跟著前進，照現在看得到的收短（0929v：拖車停點
-- 離群 trailLen+L2/2，完整繞行的出口常伸出已載入區）。拖車的保持段已延長到掛車過群（towHold），
-- 收短不得截到掛車還在群旁。
local function sweepStay(s, a, b, c, offL, baseL, tag, needBase, truncate)
    local prof, rs = s.profile, s.lastSNow
    local halfW, halfL, pad = sweepGeom(s, needBase)
    local tail = halfL + pad + TUNE.STAY_TAIL_M
    if truncate then
        local vis = visibleEndS(s.sensor, rs)
        if c + tail + s.bodyReach > vis + (s.wideArmed and 0 or (b - halfL - rs)) then
            local cMin = Drive.towHold(s) > 0 and c or (b + halfL)
            local cMax = vis - s.bodyReach - tail - 0.5
            if cMax < cMin then return false, 99, 0, 0, cMax + tail, c end
            if cMax < c then c = cMax end
        end
    end
    local dStay = c + tail
    if dStay > prof.length then dStay = prof.length end
    if dStay <= c + 0.5 or b <= rs + 0.5 then return false, 99, 0, 0, dStay, c end
    -- 停留線目標＝offL 是掃掠驗過的絕對 lane：targetKeep 0 只夾物理餘裕（留 keep 會把線從
    -- room 邊再拉 0.6，(kerb) 那道縫就被自己吃掉）
    local ovN, ovS0, reason, lastCovered = MDADFollower.buildOffsetLine(
        prof, rs, a, b, c, dStay - 1, offL, baseL, s.tmpOvX, s.tmpOvY,
        startLaneOf(s, baseL), offL, b, nil, 0)
    if ovN < 2 or reason ~= "ok" or lastCovered < dStay - 1e-6 then
        return false, 99, ovN, ovS0, dStay, c
    end
    s.tmpOvEndS = lastCovered
    local ok, margin = sweepLine(s, s.tmpOvX, s.tmpOvY, ovN, ovS0, lastCovered,
        a, b, c, dStay, offL, tag, needBase, nil, true)
    return ok, margin, ovN, ovS0, dStay, c
end

-- 停留門檻：lane 在路面餘裕內（laneBiasAt 不夾＝之後常駐得住）＋ corridor 從該 lane
-- 對下一群仍有縫（整寬牆不停留）。
local function stayAllowed(s, sen, planN, b, c, offL)
    local prof = s.profile
    -- 同側約束（2026-09-04 s051：stay −2.25 → +0.25 → −2.25 → +2.00 左右擺盪，每次
    -- commit 把常駐 lane 換到新側、搜尋中心跟著跑，最後一段 4.25m 側移塞進 2.8m）。
    -- 鏈上的 stay 只准在已鏈那一側再推；對側縫走普通繞行（有回線段）或 blocked。
    if s.laneChained then
        local resident = s.residentBias or s.sandBias
        local cur, want = laneBiasOf(s) - resident, offL - resident
        if cur * want < 0 then return false, "side" end
    end
    -- 路面餘裕不再否決停留（2026-09-04 s004@0904n Quiet St 東向定罪：黑車 B 斜跨到北緣，唯一
    -- 出路是北側路緣 lane 3.25——crawl 3.25 進入／保持段都過、只在回線段撞 B，stay 卻被
    -- `room`（road 8m 的餘裕 ≈2.9）拒絕，於是每輪只剩 2.00 那道實體極限縫）。停留線本身
    -- 已由 sweepStay 世界掃掠驗過；釋放後常駐 lane 由 clampLane 夾回路面餘裕、下一輪
    -- 從該 lane 重規劃，不需要停留 lane「常駐得住」。走廊外的 lane 由 corridor 本身擋。
    local probeNeed = MDADVehicleProfile.planNeed(s.vehicleProfile.halfW, "physical")
    local mode, _, b2, _, _, o2 = MDADCorridor.plan(sen.hardS, sen.hardL, planN, probeNeed,
        sen.corridorHalf or MDADSensor.CORRIDOR_HALF, offL, sen.hardR, offL, sen.roadLo, sen.roadHi, false,
        nil, s.lastSNow - s.vehicleProfile.halfL, nil, sen.hardLc, sen.hardW)
    if mode == "blocked" then return false, "wall" end
    return true, mode, b2, o2
end

-- 停留 lane 前瞻（2026-09-04 st176,185：A 北側 −3.25 停留、B 的縫在 +1.75，A 尾到 B 頭只有
-- 6m 而 5m 側移要 10m 跑道 → 每輪 steep → blocked → 倒車 → 43° 斜切撞 B；「為什麼沒有提前
-- 預估」）：停留 lane 不只要過得了 A，還要讓「A 尾→B 縫」的 S 彎塞得進跑道。從候選 offL
-- 往 B 縫那側每格 0.25 試，第一個「下一段側移塞得進」且停留線掃掠仍過的 lane 就是答案；
-- 都不行就維持原 offL（現行行為）。最多 STAY_LOOK_STEPS 次掃掠。
-- 「從 lane fromL 換到 toL、跑道 runway」塞不塞得進陡坡閘（與 shapeProfile 的 steep 判定同式：
-- 純運動學長 sqrt(6·dl/κ_crawl) ≤ runway × SHIFT_MIN_RATIO）。前瞻／鏈式共用。
local function shiftFits(s, fromL, toL, runway)
    local dl = math.abs(toL - fromL)
    if dl <= 0 then return true end
    local vp = s.vehicleProfile
    local crawlK = MDADDynamics.steeringKappa(
        vp.wheelbase, vp.delta0Safe, vp.deltaVSafe, vp.maxSpeed, MDADDynamics.DODGE_SQUEEZE_CAP)
    if crawlK <= 0 then crawlK = 1 / 6 end
    return math.max(runway, 1) * TUNE.SHIFT_MIN_RATIO >= math.sqrt(6 * dl / crawlK)
end

local function stayLaneForNext(s, planN, a, b, c, d, offL, baseL, nb, tag, crawlDesign, sc, b2, o2)
    if not (finite(b2) and finite(o2)) then return nil end
    -- corridor 從停留 lane 找到的「第一群」可能在 A 之前／之中（2026-09-04 st177,648：路口路緣
    -- 群 b2=125 < A 尾 154，runway 夾成 1 → 停留被推到 −4.5 貼路緣 → blocked corner → 倒車
    -- ×2 → StopStuck；使用者「本來有預估路線，靠近後卻消失、直接撞上」）：不是下一群就不前瞻
    if b2 <= sc then return nil end
    local runway = b2 - sc - 1
    if shiftFits(s, offL, o2, runway) then return nil end
    local step = (o2 > offL) and TUNE.NUDGE_STEP_M or -TUNE.NUDGE_STEP_M
    local tried = 0
    for i = 1, 40 do
        local L = offL + i * step
        if (L - o2) * step > 1e-9 then break end -- 走到 o2 本身也試（停在縫的 lane 上最省）
        if shiftFits(s, L, o2, runway) then
            local sa2, sb2, sc2, sd2, okS = shapeProfile(s, s.profile, a, b, c, d, L, baseL, crawlDesign)
            if okS then
                tried = tried + 1
                local ok, mg, ovN, ovS0, dStay = sweepStay(s, sa2, sb2, sc2, L, baseL, tag .. "-stay-look", nb)
                if ok then
                    if getDebug() then
                        print(string.format("%sstay look-ahead[%s]: next gap offL=%.2f at b=%.1f runway=%.1f; stay %.2f -> %.2f",
                            LOG, tostring(tag), o2, b2, runway, offL, L))
                    end
                    return L, sa2, sb2, sc2, dStay, mg, ovN, ovS0
                end
                if tried >= TUNE.STAY_LOOK_STEPS then break end
            end
        end
    end
    -- 復原原 offL 的 shape 暫存（widen／nudge 同款）
    shapeProfile(s, s.profile, a, b, c, d, offL, baseL, crawlDesign)
    return nil
end

-- 一般繞行（有回線段）承諾前的通用前瞻（2026-09-04 st179,820-843：近距離起步，corridor 把路口
-- 路緣群一路合成到 A 前，全繞行 +4.0 在 d=71 回線、A 的群在 74 要 −3.25 → 1m 跑道 5m 側移 →
-- blocked → 倒車 ×3 → StopStuck；遠距離起步同一段一次過——使用者「通用性要再加強」）：
-- 回線之後緊接下一群且「回線 lane → 下一群縫」的側移塞不進跑道時，把本次繞行改成停留
-- （不回線），停留 lane 再往下一群縫收（stayLaneForNext）。回 stay 結果或 nil（照常回線）。
local function chainAhead(s, planN, a, b, c, d, offL, baseL, nb, tag, crawlDesign, sa, sb, sc, sd)
    local sen = s.sensor
    local allowed, why, b2, o2 = stayAllowed(s, sen, planN, sb, sc, offL)
    if not allowed or why ~= "dodge" or not (finite(b2) and finite(o2)) or b2 <= sc then return nil end
    -- 回線後從 baseL 再切到 o2 塞得進＝照常回線
    if shiftFits(s, baseL, o2, b2 - sd - 1) then return nil end
    -- 停在 offL 就塞得進＝普通停留；否則往 o2 收
    if shiftFits(s, offL, o2, b2 - sc - 1) then
        local ok4, mg4, ovN4, ovS04, dStay = sweepStay(s, sa, sb, sc, offL, baseL, tag .. "-chain", nb)
        if ok4 then
            if getDebug() then
                print(string.format("%schain ahead[%s]: next gap offL=%.2f at b=%.1f; return skipped, stay %.2f",
                    LOG, tostring(tag), o2, b2, offL))
            end
            return true, sa, sb, sc, dStay, offL, mg4, ovN4, ovS04, nb, "stay"
        end
        return nil
    end
    local L, la, lb, lc, ld_, lmg, lovN, lovS0 = stayLaneForNext(
        s, planN, a, b, c, d, offL, baseL, nb, tag, crawlDesign, sc, b2, o2)
    if L ~= nil then return true, la, lb, lc, ld_, L, lmg, lovN, lovS0, nb, "stay-look" end
    return nil
end

-- 候選掃掠＋四層退路（plan／crawl 首候選／ban 迴圈／probe 四個呼叫點共用）：
-- ① 原檔掃掠（貼底成功時先往同縫較寬處試一格）；② 同線物理複驗；
-- ③ 同縫微調（TUNE.NUDGE_*）；④ 鏈式停留（TUNE.STAY_TAIL_M；只在回線段 p4
-- 打槍時）。回：
--   ok, a, b, c, d, offL, margin, ovN, ovS0, needUsed, variant("physical"/"nudge"/"stay"/nil)
--   失敗時只回 false，首次失敗的 (hitS, ph, hps, hx, hy) 與 shape 後的 a,b,c,d 寫進
--   s.fbFail（重用的小表；replan 的 190-local 閘門容不下十欄 tuple）。
-- a..d 傳原始（未 shape）值；crawlDesign 傳給 shapeProfile。
local function sweepWithFallbacks(s, planN, a, b, c, d, offL, baseL, tag, nb, physBase, crawlDesign)
    local sen = s.sensor
    local sa, sb, sc, sd, shapeOk = shapeProfile(s, s.profile, a, b, c, d, offL, baseL, crawlDesign)
    -- 貼縫拓寬（TUNE.NUDGE_WIDEN_M）：掃過但淨距貼底時往遠離最近點側移一格再掃，更寬就換
    local function widen(wa, wb, wc, wd, wo, wmg, wovN, wovS0, wnb, variant, wi)
        if wmg < TUNE.NUDGE_WIDEN_M and wi ~= nil and type(sen.hardL) == "table" then
            local sk = sen.hardS[wi] or wb
            local lineL = profileLaneAt(wa, wb, wc, wd, wo, baseL, sk, startLaneOf(s, baseL))
            local dir = (sen.hardL[wi] or lineL) > lineL and -1 or 1
            local offW = wo + dir * TUNE.NUDGE_STEP_M
            local xa, xb, xc, xd, shapeW = shapeProfile(s, s.profile, a, b, c, d, offW, baseL, crawlDesign)
            local ovNw, ovS0w, okW, mgW = sweepCandidate(
                s, shapeW, xa, xb, xc, xd, offW, baseL, tag .. "-widen", wnb)
            if okW and mgW > wmg then
                return true, xa, xb, xc, xd, offW, mgW, ovNw, ovS0w, wnb, variant and (variant .. "-widen") or "widen"
            end
            -- 沒換：shapeProfile 已把 cap／長度暫存改成拓寬線的值；以原始輸入重算
            -- 恢復暫存。tmpOv 只需重建原線；不再白跑一次 O(line×hardN) sweep。
            shapeProfile(s, s.profile, a, b, c, d, wo, baseL, crawlDesign)
            local _, _, _, covered = MDADFollower.buildOffsetLine(
                s.profile, s.lastSNow, wa, wb, wc, wd, wo, baseL, s.tmpOvX, s.tmpOvY,
                nil, nil, nil, startLaneOf(s, baseL))
            s.tmpOvEndS = covered
        end
        return true, wa, wb, wc, wd, wo, wmg, wovN, wovS0, wnb, variant
    end
    -- 窄縫進入段用滿跑道（TUNE.ENTRY_STRETCH_MAX）：接在掃過的候選（含拓寬後）之後。物理淨距已夠＝原樣回；否則同一條
    -- offL 以較長進入段重建再掃，淨距沒變窄（容差 2cm）才換、tier 加 "-stretch"；沒換就還原 shape 暫存與 tmpOv（同 widen）。
    local function stretch(ok, xa, xb, xc, xd, xo, xmg, xovN, xovS0, xnb, variant)
        if not ok or xmg + xnb - s.vehicleProfile.halfW >= TUNE.DODGE_THIN_M then
            return ok, xa, xb, xc, xd, xo, xmg, xovN, xovS0, xnb, variant
        end
        s.entryStretch = true
        local ya, yb, yc, yd, shapeY = shapeProfile(s, s.profile, a, b, c, d, xo, baseL, crawlDesign)
        s.entryStretch = false
        if shapeY and ya < xa - 1 then
            local ovNy, ovS0y, okY, mgY = sweepCandidate(s, shapeY, ya, yb, yc, yd, xo, baseL, tag .. "-stretch", xnb)
            if okY and mgY >= xmg - 0.02 then
                return true, ya, yb, yc, yd, xo, mgY, ovNy, ovS0y, xnb, variant and (variant .. "-stretch") or "stretch"
            end
        end
        shapeProfile(s, s.profile, a, b, c, d, xo, baseL, crawlDesign)
        local _, _, _, covered = MDADFollower.buildOffsetLine(
            s.profile, s.lastSNow, xa, xb, xc, xd, xo, baseL, s.tmpOvX, s.tmpOvY,
            nil, nil, nil, startLaneOf(s, baseL))
        s.tmpOvEndS = covered
        return true, xa, xb, xc, xd, xo, xmg, xovN, xovS0, xnb, variant
    end
    -- 鏈上回家候選 → 停留（理由見 TUNE.STAY_HOME_M）；停留線掃不過再走一般候選鏈。
    -- 主候選、同線物理複驗、微調三個入口都先問（s037 t=20：主候選 1.5 停留掃不過、
    -- 微調 1.75 才過——只在主候選問一次就漏成全繞行，回線段又把車拉回鏈 lane）。
    local function homeStay(ha, hb, hc, ho, hnb, htag)
        if not s.laneChained then return false end
        local resident = s.residentBias or s.sandBias
        local want = ho - resident
        if want < 0 then want = -want end
        if (baseL - resident) * (ho - resident) > 0 or want > TUNE.STAY_HOME_M then return false end
        local okH, mgH, ovNH, ovS0H, dStayH = sweepStay(s, ha, hb, hc, ho, baseL, htag .. "-home", hnb)
        if okH then return true, ha, hb, hc, dStayH, ho, mgH, ovNH, ovS0H, hnb, "stay" end
        return false
    end
    if shapeOk then
        local okH, ha, hb, hc, hd, ho, mgH, ovNH, ovS0H, hnb, hv = homeStay(sa, sb, sc, offL, nb, tag)
        if okH then return true, ha, hb, hc, hd, ho, mgH, ovNH, ovS0H, hnb, hv end
    end
    local ovN, ovS0, ok, mg, hitS, ph, hps, hx, hy, hi = sweepCandidate(
        s, shapeOk, sa, sb, sc, sd, offL, baseL, tag, nb)
    if ok then
        local okC, ca, cb, cc, cd, co, cmg, covN, covS0, cnb, cv = chainAhead(
            s, planN, a, b, c, d, offL, baseL, nb, tag, crawlDesign, sa, sb, sc, sd)
        if okC then return true, ca, cb, cc, cd, co, cmg, covN, covS0, cnb, cv end
        -- chainAhead 若跑過 shapeProfile／sweepStay 會改暫存與 tmpOv：重建原線
        shapeProfile(s, s.profile, a, b, c, d, offL, baseL, crawlDesign)
        local _, _, _, covered = MDADFollower.buildOffsetLine(
            s.profile, s.lastSNow, sa, sb, sc, sd, offL, baseL, s.tmpOvX, s.tmpOvY,
            nil, nil, nil, startLaneOf(s, baseL))
        s.tmpOvEndS = covered
        return stretch(widen(sa, sb, sc, sd, offL, mg, ovN, ovS0, nb, nil, hi))
    end
    local f = s.fbFail
    if f == nil then f = {}; s.fbFail = f end
    f.hitS, f.ph, f.hps, f.hx, f.hy, f.a, f.b, f.c, f.d = hitS, ph, hps, hx, hy, sa, sb, sc, sd
    f.body = shapeOk and s.sweepHitBody or nil
    if not shapeOk then return false end
    local used = nb
    if mg < TUNE.PHYS_RECHECK_M and nb > physBase + 1e-6 then
        do
            local okH, ha, hb, hc, hd, ho, mgH, ovNH, ovS0H, hnb, hv = homeStay(sa, sb, sc, offL, physBase, tag .. "-phys")
            if okH then return true, ha, hb, hc, hd, ho, mgH, ovNH, ovS0H, hnb, hv end
        end
        local ovN2, ovS02, ok2, mg2, hitS2, ph2, hps2, hx2, hy2, hi2 = sweepCandidate(
            s, shapeOk, sa, sb, sc, sd, offL, baseL, tag .. "-phys", physBase)
        if ok2 then return stretch(widen(sa, sb, sc, sd, offL, mg2, ovN2, ovS02, physBase, "physical", hi2)) end
        used = physBase
        mg, ph, hps, hi = mg2, ph2, hps2, hi2
        hitS, hx, hy = hitS2, hx2, hy2
    end
    -- 微調：非 baseline 相位、淨距差一點、且知道命中點在哪一側
    if ph ~= 1 and hi ~= nil and mg < TUNE.NUDGE_MAX_M and type(sen.hardL) == "table" then
        local lineL = profileLaneAt(sa, sb, sc, sd, offL, baseL, hps, startLaneOf(s, baseL))
        local dir = (sen.hardL[hi] or lineL) > lineL and -1 or 1
        local offN = offL + dir * TUNE.NUDGE_STEP_M
        local na, nb2, nc, nd, shapeN = shapeProfile(s, s.profile, a, b, c, d, offN, baseL, crawlDesign)
        if shapeN then
            local okH, ha, hb, hc, hd, ho, mgH, ovNH, ovS0H, hnb, hv = homeStay(na, nb2, nc, offN, used, tag .. "-nudge")
            if okH then return true, ha, hb, hc, hd, ho, mgH, ovNH, ovS0H, hnb, hv end
        end
        local ovN3, ovS03, ok3, mg3 = sweepCandidate(
            s, shapeN, na, nb2, nc, nd, offN, baseL, tag .. "-nudge", used)
        if ok3 then return stretch(true, na, nb2, nc, nd, offN, mg3, ovN3, ovS03, used, "nudge") end
        -- nudge 的 shapeProfile 同樣會改寫 spaceCap／designSpeed／shapeReason；失敗後
        -- 下一步 stay 採原 offL，必先復原原線暫存（widen 同款）。
        shapeProfile(s, s.profile, a, b, c, d, offL, baseL, crawlDesign)
    end
    -- 鏈式停留：只有回線段撞到（縫本身過得去）才有意義
    if ph == 4 then
        local allowed, why, b2, o2 = stayAllowed(s, sen, planN, sb, sc, offL)
        if allowed then
            s.stayNextB = nil
            if why == "dodge" then
                local L, la, lb, lc, ld_, lmg, lovN, lovS0 = stayLaneForNext(
                    s, planN, a, b, c, d, offL, baseL, used, tag, crawlDesign, sc, b2, o2)
                if L ~= nil then return true, la, lb, lc, ld_, L, lmg, lovN, lovS0, used, "stay-look" end
                -- 下一群塞不進、也沒有可收的 lane：停留照走，但速度要對下一群煞停（2026-09-04
                -- s015：停留 −1.75 cap 27.8 走到 c、B 在 4m 後要 +3.75 側移 → 27 km/h 撞進 blocked
                -- → 車旁是 A 倒不了 → StopStuck）。到了 c 再由 steep 差額倒車補跑道。
                if finite(b2) and b2 > sc and not shiftFits(s, offL, o2, b2 - sc - 1) then
                    s.stayNextB = b2
                end
            end
            local ok4, mg4, ovN4, ovS04, dStay, cStay = sweepStay(
                s, sa, sb, sc, offL, baseL, tag .. "-stay", used, true)
            if ok4 then return true, sa, sb, cStay, dStay, offL, mg4, ovN4, ovS04, used, "stay" end
            s.stayNextB = nil
        elseif getDebug() then
            print(string.format("%sstay refused[%s] offL=%.2f why=%s", LOG, tostring(tag), offL, tostring(why)))
        end
    end
    return false
end

-- 測試鉤：回 session 表本身（harness 直接讀 dodging／returnActive／fstate；production 無呼叫者）
function Drive.debugSession(playerNum)
    return sessions[playerNum]
end

-- 測試鉤：回 TUNE 表本身（harness 臨時改門檻做反面契約；production 無呼叫者）
function Drive.debugTune()
    return TUNE
end

function Drive.debugDodgeEntryPassed(s, now)
    return dodgeEntryPassed(s, now)
end

-- 本機回歸鉤：繞行曲率窗口（兩段過渡、從車尾起量）。production 無呼叫者。
function Drive.debugLineKappa(prof, xs, ys, n, s0, rearS, a, b, c, d)
    return dodgeLineKappa(prof, xs, ys, n, s0, rearS, a, b, c, d)
end
-- 本機回歸鉤：繞行帽合成（commit／守護同一函式；保持段帽 dodgeHoldCap）。production 無呼叫者。
function Drive.debugDodgeCaps(s, margin, kappa, minLat, visibilityCap, commit, entryPassed)
    return updateDodgeCaps(s, margin, kappa, minLat, visibilityCap, commit, entryPassed)
end

-- 測試鉤：停留 lane 前瞻的 predicate（production 無呼叫者）。回 (L 或 nil)。
function Drive.debugStayLook(playerNum, a, b, c, d, offL, sc, b2, o2)
    local s = sessions[playerNum]
    if not s or not s.sensor or not s.sensor.ready then return nil end
    return (stayLaneForNext(s, s.sensor.hardN, a, b, c, d, offL, laneBiasOf(s), s.sweepBase,
        "debug", false, sc, b2, o2))
end

-- 測試鉤（harness 鎖同縫微調的 predicate：方向＝遠離命中點、步距一格、只在近失時）：
-- 對當前 session 的點雲跑一次 sweepWithFallbacks，回 ok, offL, variant, margin, a, b, c, d。crawl＝爬行設計（窄縫的
-- 重試／爬行檔，短進入段）。production 無呼叫者。
function Drive.debugSweepFallbacks(playerNum, a, b, c, d, offL, tag, crawl)
    local s = sessions[playerNum]
    if not s or not s.sensor or not s.sensor.ready then return nil end
    local physBase = MDADVehicleProfile.sweepBase(s.vehicleProfile.halfW, "physical")
    local ok, ra, rb, rc, rd, ro, mg, _, _, _, variant = sweepWithFallbacks(
        s, s.sensor.hardN, a, b, c, d, offL, laneBiasOf(s), tag or "debug",
        s.sweepBase, physBase, crawl == true)
    if not ok then return false, s.dodgeShapeReason end
    return true, ro, variant, mg, ra, rb, rc, rd
end

-- 測試鉤（harness 鎖出口轉場遇緊接小折點的 shapeProfile predicate）：對當前 session 的剖面跑一次
-- shapeProfile，回 ok, a, b, c, d, reason。production 無呼叫者。
function Drive.debugShape(playerNum, a, b, c, d, offL)
    local s = sessions[playerNum]
    if not s or not s.profile then return nil end
    local ra, rb, rc, rd, ok = shapeProfile(s, s.profile, a, b, c, d, offL, laneBiasOf(s), false)
    return ok, ra, rb, rc, rd, s.dodgeShapeReason
end

-- 測試鉤（harness 鎖拖車掃掠：同一條候選線牽引車過得去、掛車內切撞到）：對當前 session 的點雲直接掃一條
-- 給定剖面的候選線（不經 shapeProfile 與拓寬／微調等退路），回 ok, phase, hitX, hitY。production 無呼叫者。
function Drive.debugSweepCandidate(playerNum, a, b, c, d, offL)
    local s = sessions[playerNum]
    if not s or not s.sensor or not s.sensor.ready then return nil end
    local _, _, ok, _, _, phase, _, hitX, hitY = sweepCandidate(s, true, a, b, c, d, offL, laneBiasOf(s),
        "debug", s.sweepBase)
    return ok, phase, hitX, hitY
end

-- blocked 座標錨解析（plan／guard 共用；Kahlua 190-local 閘門逼出的抽取）：
-- 把「世界距車最近」的合格點寫進 s.blockHitX/Y（blockedNear 判距權威——
-- 弧長跨快照不可比、取 s 最小會挑到橫向邊緣點判距虛遠，兩案都實測定罪）。
-- lineOnly＝只收擋線點（blocksLine）；guard 檔收 [minS, maxS] 弧長窗內的前方點
-- （窗＝守護判死命中點附近一個車身：2026-09-04 st144580 舊制無上界，88m 外判死
-- 卻錨到車旁 6m 路肩桿，車在障礙前 78m 兩秒煞死）。maxS nil＝無上界。
-- laneL＝擋線判定的基準 lane（nil＝plan 檔：用 Corridor.plan 同一組逐點基準 s.hardBase——
-- 0928b E2E rc1 0008：126° 折點出口的桿，Corridor 以彎道連續落點判它擋線、錨卻用原始
-- laneBias 判它不擋，改挑 51m 外的點；blockedNear 永遠不近、車以 12-16 km/h 撞上。
-- guard 檔傳承諾線 offL，路肩雜點不入選）。
-- 回傳合格點中的最小弧長（guard 的 blockS 用）。
local function resolveBlockAnchor(s, sen, vehicle, lineOnly, minS, maxS, laneL)
    local bestD2, bi, bs
    local vx, vy = vehicle:getX(), vehicle:getY()
    local bl, nh = laneL or laneBiasOf(s), s.needHalf
    local hb = laneL == nil and s.hardBaseStamp == sen.stamp and s.hardBase or nil
    for i = 1, sen.hardN do
        local hs = sen.hardS[i]
        local base = hb and hb[i] or bl
        if (minS == nil or hs >= minS) and (maxS == nil or hs <= maxS)
                and (not lineOnly or blocksLine(sen, i, base, nh)) then
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
Drive.debugResolveBlockAnchor = resolveBlockAnchor -- 測試鉤：錨與 Corridor.plan 的擋線基準是否同一組
Drive.debugAssistForce = longitudinalAssistForce -- 測試鉤：路外前推的車速上限（0928m）

-- 換縫找更寬（TUNE.DODGE_THIN_M）：重試／爬行檔剛採納的候選物理淨距 phys < 門檻時記下（只留目前最寬的那條：
-- 未 shape 的 a..d／offL、當時的 planN、檔名、sweep base），回 true＝呼叫端別定案、ban 掉它往下找；夠寬回 false。
-- s.thinRec 每輪候選鏈開頭清（on＝false），commit 事件的 thin 欄位＝記下那條的物理淨距。
function Drive.thinNote(s, phys, tier, tierName, a, b, c, d, offL, planN, nb, crawl)
    if phys >= TUNE.DODGE_THIN_M then return false end
    local r = s.thinRec
    if r == nil then r = {}; s.thinRec = r end
    if not r.on or phys > r.phys then
        r.on, r.phys, r.tier, r.tierName = true, phys, tier, tierName
        r.a, r.b, r.c, r.d, r.offL, r.planN, r.nb, r.crawl = a, b, c, d, offL, planN, nb, crawl
    end
    return true
end

-- 找完沒有更寬的：以記下的原始輸入重跑一次 sweepWithFallbacks（同幀同點雲＝同一條線，順便把 tmpOv 與 shape 暫存
-- 換回它——中間掃過的其他候選已覆寫）。adoptIf／sweep 由 replan 傳入（槽數閘）。沒有記錄回 false。
function Drive.thinAdopt(s, adoptIf, sweep, baseL, physBase)
    local r = s.thinRec
    if r == nil or not r.on then return false end
    return adoptIf(r.tier, sweep(s, r.planN, r.a, r.b, r.c, r.d, r.offL, baseL, r.tierName, r.nb, physBase, r.crawl))
end

-- 初判 blocked 的降檔複審（replan 抽出；190-local 閘門＋可獨立閱讀）：
-- squeeze plan＋sweep → physical plan＋sweep，第一個世界掃掠過的縫即 commit
-- 候選。回 ok, a, b, c, d, offL, sweepBase；ok=false 時不動任何 s 欄位。
-- refineComfort=true（2026-09-02 使用者「能走路面就別走草地」）：複審不是 ban
-- 重試，first-safe 後在同側找額外餘裕／偏回路面帶。降檔縫一律標 dodgeCrawl
-- （reserve 豁免＋intent CRAWL；速度仍由 clearance 連續縮放）。blockL＝擋線基準（laneBias），baseL＝回線 lane。
local function demotePlan(s, sen, planN, prefer, blockL, baseL, playerNum)
    for tier = 1, 2 do
        local nu = tier == 1 and s.squeezeNeed
            or MDADVehicleProfile.planNeed(s.vehicleProfile.halfW, "physical")
        local nb = tier == 1 and s.squeezeSweepBase
            or MDADVehicleProfile.sweepBase(s.vehicleProfile.halfW, "physical")
        local mq, aq, bq, cq, dq, oq = MDADCorridor.plan(
            sen.hardS, sen.hardL, planN, nu, sen.corridorHalf or MDADSensor.CORRIDOR_HALF,
            prefer, sen.hardR, blockL, sen.roadLo, sen.roadHi, true, s.hardBase,
            s.lastSNow - s.vehicleProfile.halfL, sen.corridorInner, sen.hardLc, sen.hardW)
        if mq == "dodge" and dq > s.lastSNow + 1 then
            local shapeQ
            aq, bq, cq, dq, shapeQ = shapeProfile(
                s, s.profile, aq, bq, cq, dq, oq, baseL, true)
            local ovN, ovS0, okQ, mgQ = sweepCandidate(
                s, shapeQ, aq, bq, cq, dq, oq, baseL,
                tier == 1 and "crawl" or "probe", nb)
            if okQ then
                s.dodgeMargin, s.dodgeMarginS = mgQ, nil
                s.dodgeClrN, s.dodgeEnvN = 0, 0
                s.dodgeCrawl = true
                s.dodgeTier = tier == 1 and "demote-crawl" or "demote-probe"
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

-- 掃描輪完成或障礙簽章變化時重規劃（事件驅動：布局沒變就一次都不算）。
-- 決策全在 MDADCorridor（純數學）；這裡只把結果翻成 follower 的側偏剖面與
-- blocked 旗標。政策=停車（ObstaclePolicy=2）時就算有縫隙也不繞，一律煞停等待。
-- 守護的物理複驗通過＝這條承諾線從此只剩物理餘裕，餘裕／最緊點／檔位都要換成物理的
-- （2026-09-07 session-008 t=53-61 定罪：巡航承諾 offL −0.5 margin 1.41，回線段 s=535.8
-- 串流載入一根物件 comfort −0.21 → [guard] 失敗 → guard-probe 物理過 → 舊制沿用 commit 餘裕
-- 1.41 → clearance 帽 184、40 km/h 到 d 釋放 → 1.8m 外的那根物件 blocked → forceBrake 33 →
-- contact）。降為物理承諾後：contact pad 同物理（0904r）、clearance 走 crawl 地板 5/10、
-- 0907d 的保持段 envelope 壓向最緊點——到 d 是爬行速，釋放後 blocked 停得住、重規劃繞它。
-- pm／mi＝物理掃掠的最小淨距與其點（只統計 [a,c]，sweepLine 的 inCap）；cOver／cHit＝帶餘裕掃掠
-- 的重疊量（−clearance）與命中點——回線段 p4 的命中不在 [a,c] 窗內，物理淨距要從帶餘裕的
-- 讀數換算：兩檔差的只有 pad（sweepGeom）與整格物的量化肥邊補償（D.sweepRadius）。
local function guardDemote(s, sen, pm, mi, cOver, cHit, playerNum)
    local physBase = MDADVehicleProfile.sweepBase(s.vehicleProfile.halfW, "physical")
    local _, _, padC = sweepGeom(s, s.dodgeNeed)
    local _, _, padP = sweepGeom(s, physBase)
    local margin, tightI = pm, mi
    s.dodgeDemoteS, s.dodgeDemoteM = nil, nil
    if finite(cOver) and cHit and sen.hardR and finite(sen.hardR[cHit]) then
        local r = sen.hardR[cHit]
        local box = sen.hardB and type(sen.hardB[cHit]) == "number" and sen.hardB[cHit] > 0
        local comp = (not box and r >= 0.5 and padC > padP + TUNE.SWEEP_QUANT_COMP)
            and TUNE.SWEEP_QUANT_COMP or 0 -- 方塊掃掠不走量化補償（sweepLine）
        local atHit = -cOver + (padC - padP) - comp
        if atHit < 0 then atHit = 0 end
        -- 命中點多半在回線段 p4＝sweepLine 的 [a,c] 餘裕窗之外：後續 worldGrew／guard-pass 成功輪
        -- 回填的 [a,c] 最小淨距看不到它，會把餘裕放回去（lane 反例）→ 一律另存（不論本輪是否比 [a,c]
        -- 更緊：[a,c] 的整格物可能過了車才輪到它綁——lane 第二反例），車過才丟；本輪餘裕取 min
        s.dodgeDemoteS, s.dodgeDemoteM = sen.hardS and sen.hardS[cHit] or nil, atHit
        if atHit < margin then margin, tightI = atHit, cHit end
    end
    if margin < 0 then margin = 0 end
    s.dodgeNeed = physBase
    s.dodgeMargin = margin
    s.dodgeMarginS = tightI and sen.hardS and sen.hardS[tightI] or 1e9
    s.dodgeCrawl = true
    if getDebug() then
        print(string.format("%spn=%d dodge guard demoted to physical: m=%.2f tightS=%.1f rs=%.1f",
            LOG, playerNum, margin, s.dodgeMarginS, s.lastSNow))
    end
    diagEvent(s, playerNum, "dodge", { phase = "demote", why = "guard",
        m = margin, s = s.dodgeMarginS, rs = s.lastSNow })
    return margin
end

-- 繞行延後（exit／coverage／unloaded）：這一輪不承諾，先按已知群起點 b 保留煞停距離（接近帽
-- 指向已知障礙，不是未載入前緣），點雲 sig 不變也要每輪重判。replan 兩個出口共用（主候選 exit
-- 立即延後；coverage／unloaded 在候選鏈全滅後才延後）。
function Drive.deferDodge(s, playerNum, why, b, c, dS)
    local sen = s.sensor
    s.planSig = -1
    s.dodgeDeferCap = MDADDynamics.approachCapKmh(
        b - s.lastSNow - s.vehicleProfile.halfL, 0, 0.5, s.safeBrake)
    s.dodgeDeferS = b
    diagEvent(s, playerNum, "dodge", { phase = "defer", why = why,
        b = b, c = c, d = dS, rs = s.lastSNow, span = TUNE.DODGE_OV_SPAN,
        s = sen.unloadedS, cap = s.dodgeDeferCap })
    if getDebug() then
        print(string.format(
            "%spn=%d dodge defer (%s): c=%.1f d=%.1f rs=%.1f unloadedS=%s",
            LOG, playerNum, why, c, dS or -1, s.lastSNow, tostring(sen.unloadedS)))
    end
end

-- replan 牆鐘遙測（事件用）：本次 replan 有量（stepFollow 讀了開始時戳）＝從 replan 開始到發事件的毫秒，
-- 候選鏈都在事件之前；沒量＝nil（節流，最多每 TUNE.REPLAN_CLOCK_MS 一次）。毫秒時鐘只當現場分佈，不拿來歸因。
function Drive.replanElapsed(s)
    return s.replanT0 and getTimestampMs() - s.replanT0 or nil
end

local function replan(s, vehicle, playerNum)
    s.dodgeDeferCap = s.dodgeHandoffHold and 0 or -1
    s.dodgeDeferS = nil
    s.steepDeficitM = -1
    local sen = s.sensor
    if not sen.ready then return end
    local handoff = false
    diagEvent(s, playerNum, "replan")
    -- 掃描摘要：只在布局變化（sig 變）才進 replan，一行不會洗版——實機分析
    -- 「感知有沒有看到那棵樹／那台車」全靠這行（2026-08-28 使用者授權加強診斷）
    if getDebug() then
        print(string.format("%spn=%d scan hardN=%d zombies=%d znear=%.0f corpses=%d soft=%d veh=%d roadN=%d unloaded=%s",
            LOG, playerNum, sen.hardN, sen.zombieN,
            finite(sen.zombieNearS) and (sen.zombieNearS - s.lastSNow) or -1,
            sen.corpseN, sen.softN, sen.vehN,
            sen.roadN or 0, tostring(sen.unloaded)))
    end
    -- ===== immutable DODGE（2026-08-28 雙模型對抗審共識）=====
    -- 入口與保持段承諾不可變：執行中只守護，不逐輪選縫／換邊。
    -- 整車越過舊群後才可交下一段；新線仍必須經完整候選鏈與世界掃掠。
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
        -- 對向車逼近中硬做完的繞行（trafficPlan＝late）不提前釋放：回線段是承諾時掃過的線，
        -- 提前交給 RETURN 會以當下偏移為基準停等＝停在對方車道上（E2E park400）。
        -- 車頭一過 c 就放＝車身還在舊群旁邊就把已掃過的回線段丟掉，改由 RETURN／pure pursuit
        -- 從偏移位置斜切回常駐線，切進剛繞過的障礙（2026-09-27 正式服 K5：offL 3.75、過 c 0.27m
        -- 即釋放，期望線 3.75→−0.5 一跳、st −1.23 直接 contact）。整車越過 c（bodyReach）才提前放。
        -- 擋線點從車尾起算（1004a，正式服 0.18.2 Qoo clip-15）：同輪 replan 的 Corridor.plan 與判堵錨都從
        -- rs−halfL 收點，這裡從車心找＝車身旁的擋常駐線點被略過 → 放手後同輪判堵、錨在車身旁 41 km/h 鎖輪。
        local exitReady = type(fs.offC) == "number" and s.lastSNow >= fs.offC + s.bodyReach
            and not s.trafficLate
            and nearestLineBlocker(s, sen, s.lastSNow - s.vehicleProfile.halfL) == nil
            and not Drive.exitKeepsDodge(s)
        -- 026/030：後載入的下一台擋住 p4，但第一群已通過；等 nextCap<8／停穩才交接
        -- 會錯過尚有跑道的行駛窗口。失敗必須真在 p4，不能由 hardS>c 猜（車頭會前伸）。
        if not exitReady and finite(fs.offC) and finite(fs.offD) and finite(fs.ovEndS)
                and (s.lastSNow >= fs.offC + s.bodyReach
                    or (s.dodgeGuardFailed and s.guardHitPhase == 2
                        and fs.offB > s.lastSNow + s.bodyReach))
                and not s.dodgeStay and not s.laneChained and not s.dodgeCapPending
                and not Drive.movingWithin(s, fs.ovEndS) and sen.hardOverflow == false
                and not s.currentBlocked and not s.returnActive and not fs.rotating
                and s.recoverWhy == nil and not s.recoverPulse and s.progressState ~= "gear-reset"
                and not s.invalid and not s.dynamicsFault
                and MDAD.sandbox("ObstaclePolicy", POLICY_DODGE) == POLICY_DODGE
                and (not s.dodgeGuardFailed or ((s.guardHitPhase == 2 or s.guardHitPhase == 4)
                    and finite(s.guardHitS) and s.guardHitS > s.lastSNow + s.bodyReach)) then
            local nextI = nearestLineBlocker(s, sen, math.max(s.lastSNow, fs.offC) + s.bodyReach)
            -- 遠於舊線車身覆蓋的下一群，先沿有效舊線前進；太早交出會卡在 window defer。
            handoff = ((s.dodgeGuardFailed and s.guardHitPhase == 2)
                or (nextI ~= nil and sen.hardS[nextI] <= fs.ovEndS + s.bodyReach))
                and Drive.handoffReady(s)
            exitReady = handoff
            if handoff then
                s.cornerLatch = false
                diagEvent(s, playerNum, "dodge", { phase = "release",
                    why = s.guardHitPhase == 2 and "guard-entry" or "next-group",
                    rs = s.lastSNow, c = fs.offC })
            end
        end
        -- 保留其他承諾型態既有的停穩交接退路（條件見 Drive.nextStopHandoff）。
        if not exitReady and Drive.nextStopHandoff(s, vehicle:getCurrentSpeedKmHour()) then
            -- 車身可能還在舊群旁：交接後跨輪維持停止（dodgeHandoffHold），直到新線採納或真正淨空，
            -- 不讓 RETURN／pure pursuit 在沒有新線時從偏移位置切回常駐線。
            exitReady, handoff = true, true
            diagEvent(s, playerNum, "dodge", { phase = "release",
                why = s.lastSNow < fs.offC and "next-stop-hold" or "next-stop",
                rs = s.lastSNow, c = fs.offC, d = s.dodgeNextDist })
        end
        -- 停留承諾沒有回線段：保持段走完（>=c）就釋放，下一輪從停留 lane 規劃下一台
        if s.dodgeStay and finite(s.stayLanePending) and type(fs.offB) == "number"
                and s.lastSNow >= fs.offB then
            MDADFollower.setLaneBias(fs, s.stayLanePending)
            s.stayLanePending = nil
        end
        local stayDone = s.dodgeStay and type(fs.offC) == "number" and s.lastSNow >= fs.offC
        -- 提早釋放（理由見 TUNE.STAY_SETTLED_M）
        if s.dodgeStay and not stayDone and type(fs.offB) == "number"
                and s.lastSNow >= fs.offB + 1 and finite(s.lastLatDev)
                and (s.lastLatDev < 0 and -s.lastLatDev or s.lastLatDev) <= TUNE.STAY_SETTLED_M then
            local lane = laneBiasOf(s)
            local pm, a2 = MDADCorridor.plan(sen.hardS, sen.hardL, sen.hardN, s.needHalf,
                sen.corridorHalf or MDADSensor.CORRIDOR_HALF, lane, sen.hardR, lane, sen.roadLo, sen.roadHi, false,
                nil, s.lastSNow - s.vehicleProfile.halfL, nil, sen.hardLc, sen.hardW)
            -- 「下一群」必須在停留段之後（2026-09-04 st178,085：停留 +2.0 正貼著 B 過（餘裕 0.22），
            -- corridor 用舒適需求看 B 說「要繞」→ 提早釋放把掃掠驗過的線丟掉 → 重規劃全滅 →
            -- blocked → 倒車 → 再承諾 → 再釋放……最後漂到 +3.5 卡路緣；使用者「位子又不對了」）
            if pm == "dodge" and finite(a2) and a2 > fs.offC then
                stayDone = true
                s.stayHoldEndS = fs.offC
                diagEvent(s, playerNum, "dodge", { phase = "release", why = "stay-early",
                    rs = s.lastSNow, c = fs.offC })
                if getDebug() then
                    print(string.format("%spn=%d stay released early: next group ahead (rs=%.1f c=%.1f)",
                        LOG, playerNum, s.lastSNow, fs.offC))
                end
            end
        end
        if curOffL == nil or type(fs.offD) ~= "number" or s.lastSNow >= fs.offD
                or exitReady or stayDone then
            -- 剖面走完（或已被外部清除／exit 段淨空）：釋放承諾，本輪 fall
            -- through 正常規劃
            MDADFollower.clearOffset(fs)
            -- 1004a：線尾／出口淨空的釋放也記事件（交接與停留各有自己的事件）——釋放後跳 lane 的復盤要看得到
            -- 釋放點與當下車身／常駐線（正式服 0.18.2 Sixya clip-11、MI clip-01、Qoo clip-15 只能從 dg 翻轉推）
            if not stayDone and not handoff then
                diagEvent(s, playerNum, "dodge", { phase = "release",
                    why = (curOffL == nil and "cleared") or (exitReady and "exit") or "end",
                    rs = s.lastSNow, l = s.lastLatSigned, offL = s.residentBias })
            end
            releaseDodge(s)
            -- releaseDodge 先清 hold，交接輪須在完整重設之後接續等待新線。
            s.dodgeHandoffHold = handoff
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
                -- 每個 OBB 本身已涵蓋車尾；從目前中心取樣，不再把車身往後重複放一個 halfL。
                local guardK = (s.lastSNow - fs.ovS0) / MDADFollower.OV_STEP + 1
                guardK = guardK - guardK % 1
                if guardK < 1 then guardK = 1 end
                if Drive.movingWithin(s, fs.ovEndS) or worldGrew then
                    s.dodgeGuardHardN = sen.hardN
                    local hitS, hitPh, hitSk, hitX, hitY, pm, mi
                    guardOk, guardMargin, hitS, hitPh, hitSk, hitX, hitY, mi = sweepLine(
                        s, fs.ovX, fs.ovY, fs.ovN, fs.ovS0, fs.ovEndS,
                        fs.offA, fs.offB, fs.offC, fs.offD,
                        curOffL, "guard", s.dodgeNeed, guardK, false, true)
                    if guardOk then
                        s.dodgeMargin = guardMargin
                        s.dodgeMarginS = mi and sen.hardS and sen.hardS[mi] or 1e9
                        -- 降級記下的回線段最緊點還在車前：餘裕維持它（[a,c] 窗看不到 p4）
                        if finite(s.dodgeDemoteS) and s.dodgeDemoteS > s.lastSNow - s.vehicleProfile.halfL
                                and s.dodgeDemoteM < guardMargin then
                            s.dodgeMargin, s.dodgeMarginS, guardMargin =
                                s.dodgeDemoteM, s.dodgeDemoteS, s.dodgeDemoteM
                        end
                    else
                        -- 帶餘裕守護失敗仍先做物理重驗：過＝續走，但從此是物理承諾
                        -- （guardDemote：餘裕／最緊點／檔位換成物理的；舊制沿用 commit
                        -- 餘裕＝session-008 撞擊）。門檻同樣走餘裕預算 authority 的
                        -- physical 檔（階段 2 主體 4），不再自己寫 halfW-0.1。
                        local cOver, cHit = guardMargin, mi -- 帶餘裕掃掠的重疊量與命中點
                        guardOk, pm, hitS, hitPh, hitSk, hitX, hitY, mi = sweepLine(
                            s, fs.ovX, fs.ovY, fs.ovN, fs.ovS0, fs.ovEndS,
                            fs.offA, fs.offB, fs.offC, fs.offD,
                            curOffL, "guard-probe", MDADVehicleProfile.sweepBase(
                                s.vehicleProfile.halfW, "physical"), guardK, false, true)
                        if guardOk then
                            guardMargin = guardDemote(s, sen, pm, mi, cOver, cHit, playerNum)
                        end
                    end
                    -- 判死的那一點就是煞停錨（2026-09-04 實機 st144580：guard 在 88m 外
                    -- hw=(8082.5,11470.5) 判死，舊制 resolveBlockAnchor(lineOnly=false)
                    -- 取「前方全部點中世界距最近」＝路肩 6m 外一根桿 bs=429.2 → 車在
                    -- 障礙前 78m 從 55 km/h 兩秒煞死）。
                    if not guardOk then
                        s.guardHitS, s.guardHitPhase, s.guardHitX, s.guardHitY = hitS, hitPh, hitX, hitY
                        s.guardHitClearance = pm ~= nil and -pm or nil
                    else
                        s.guardHitS, s.guardHitPhase = nil, nil
                    end
                    -- 物理重驗的判決是這條承諾線的已知事實，持平輪不得推翻
                    -- （2026-09-04 實機定罪：Rosewood 路口中央一台停車，承諾線
                    -- offL 4.25 在 hw=(8082.5,11470.5) 淨距 −0.43；點雲每輪 271↔287
                    -- 交替（帶緣一台車的 16 點輪廓進出），worldGrew 隔輪成立 →
                    -- 失敗→hold→下一輪「持平＝信任」→ blocked 清除→起步→再失敗，
                    -- 走走停停 30 秒、blocked 語音三次才進倒車鏈）。
                    s.dodgeGuardFailed = not guardOk
                else
                    -- 靜態且點雲持平：信任承諾，不重擲骰子——但物理重驗已判死的
                    -- 線維持死（釋放交給近停清承諾＋重規劃）
                    guardOk, guardMargin = not s.dodgeGuardFailed, s.dodgeMargin
                    -- 0905q：commit 餘裕是整條線的最小值，過了那一點就該用剩餘線的餘裕定速
                    -- （2026-09-04 s023 st184,096-115：margin 0.13 → 5 km/h 地板爬完整條 26m
                    -- 直線，最緊點在前 6m）。最緊點未知（剛 commit）或已過（車尾過它 1m）
                    -- 就從車身後緣起重掃一次；每過一個最緊點最多一次掃掠。
                    -- 逐點淨距表缺席（承諾後第一次 guard-pass 時線尾還在可視範圍外＝不收表）、現在線已看全：
                    -- 同一條線補掃一次（0928d E2E rc3 0039：53m 進入段、最緊點在盡頭，表一直沒建，全程 5 km/h
                    -- 爬 38 秒）。每條承諾線（ovS0）最多補一次，補掃掃不過就照舊信任承諾。
                    local wantTable = s.dodgeMarginS ~= nil and (s.dodgeClrN or 0) == 0
                        and s.dodgeClrRetryS0 ~= fs.ovS0 and Drive.candidateCovered(s, fs.ovEndS)
                    if wantTable then s.dodgeClrRetryS0 = fs.ovS0 end
                    if guardOk and (s.dodgeMarginS == nil or wantTable
                            or s.lastSNow > s.dodgeMarginS + s.vehicleProfile.halfL + 1) then
                        local ok2, mg2, _, _, _, _, _, mi2 = sweepLine(
                            s, fs.ovX, fs.ovY, fs.ovN, fs.ovS0, fs.ovEndS,
                            fs.offA, fs.offB, fs.offC, fs.offD,
                            curOffL, "guard-pass", s.dodgeNeed, guardK, false, true)
                        if ok2 then
                            s.dodgeMargin, guardMargin = mg2, mg2
                            s.dodgeMarginS = mi2 and sen.hardS and sen.hardS[mi2] or 1e9
                            if finite(s.dodgeDemoteS) and s.dodgeDemoteS > s.lastSNow - s.vehicleProfile.halfL
                                    and s.dodgeDemoteM < guardMargin then
                                s.dodgeMargin, s.dodgeMarginS, guardMargin =
                                    s.dodgeDemoteM, s.dodgeDemoteS, s.dodgeDemoteM
                            end
                        elseif s.dodgeCrawl then
                            s.dodgeMarginS = 1e9 -- 物理檔承諾本來就掃不過帶餘裕：不再重掃
                        else
                            -- 巡航承諾在持平輪掃不過帶餘裕＝有東西進了線（session-008 的
                            -- guard-pass 就是先於 worldGrew 一輪看到 −0.21）：同 worldGrew
                            -- 分支做物理複驗——過＝降物理承諾，不過＝判死（煞停錨＝命中點）
                            local ok3, pm3, hitS3, hitPh3, _, hitX3, hitY3, mi3 = sweepLine(
                                s, fs.ovX, fs.ovY, fs.ovN, fs.ovS0, fs.ovEndS,
                                fs.offA, fs.offB, fs.offC, fs.offD,
                                curOffL, "guard-probe", MDADVehicleProfile.sweepBase(
                                    s.vehicleProfile.halfW, "physical"), guardK, false, true)
                            if ok3 then
                                guardMargin = guardDemote(s, sen, pm3, mi3, mg2, mi2, playerNum)
                            else
                                guardOk = false
                                s.guardHitS, s.guardHitPhase, s.guardHitX, s.guardHitY = hitS3, hitPh3, hitX3, hitY3
                                s.guardHitClearance = pm3 ~= nil and -pm3 or nil
                                s.dodgeGuardFailed = true
                            end
                        end
                    end
                end
            end
            if guardOk and Drive.extendDodgeExit(s, sen, playerNum) then guardMargin = s.dodgeMargin end
            if guardOk then
                local minBrake, minLat = MDADFollower.minDynamics(
                    s.profile, fs.offA, fs.offD, s.fstate.idx)
                if finite(s.safeBrake) and s.safeBrake >= 0
                        and s.safeBrake < minBrake then minBrake = s.safeBrake end
                if finite(s.safeLat) and s.safeLat >= 0
                        and s.safeLat < minLat then minLat = s.safeLat end
                local passed = s.dodgeEntryPassed == true or dodgeEntryPassed(s, getTimestampMs())
                local kappa = dodgeLineKappa(s.profile, fs.ovX, fs.ovY, fs.ovN, fs.ovS0,
                    s.lastSNow - s.vehicleProfile.halfL, fs.offA, fs.offB, fs.offC, fs.offD)
                local visibilityCap = Drive.dodgeVisibilityCap(s, sen, minBrake)
                s.dodgeClass = Drive.movingWithin(s, fs.ovEndS)
                    and MDADDynamics.DODGE_VEHICLE or MDADDynamics.DODGE_STATIC
                local oldPassed = s.dodgeEntryPassed
                local capReason = updateDodgeCaps(s, guardMargin, kappa, minLat,
                    visibilityCap, false, passed)
                if s.dodgeEntryPassed ~= oldPassed then
                    diagEvent(s, playerNum, "dodge", { phase = "speed",
                        why = s.dodgeEntryPassed and "entry-passed" or "entry-hold",
                        cap = s.dodgeSpeedCap, space = s.dodgeSpaceCap, curve = s.dodgeCurveCap,
                        m = guardMargin, rs = s.lastSNow, b = fs.offB, c = fs.offC })
                end
                if s.dodgeEntryPassed ~= oldPassed and getDebug() then
                    print(string.format("%spn=%d dodge speed: %s cap=%.1f space=%.1f curve=%.1f rs=%.1f b=%.1f c=%.1f",
                        LOG, playerNum, s.dodgeEntryPassed and "entry-passed" or "entry-hold",
                        s.dodgeSpeedCap, s.dodgeSpaceCap, s.dodgeCurveCap, s.lastSNow, fs.offB, fs.offC))
                end
                if getDebug() then
                    -- 守護輪 cap 分解：commit 只印一次，之後 cap 掉到哪、誰綁的（2026-09-07 實機
                    -- commit 16 → 守護 9.1 爬 20m，console 只有狀態列的 cap=dodge 無從定罪）
                    local nowDbg = getTimestampMs()
                    local prev = s.guardCapDbg or -99
                    local diff = s.dodgeSpeedCap - prev
                    if diff < 0 then diff = -diff end
                    if diff >= 1 or nowDbg - (s.guardCapDbgMs or 0) >= 1000 then
                        s.guardCapDbg, s.guardCapDbgMs = s.dodgeSpeedCap, nowDbg
                        print(string.format("%spn=%d dodge guard cap=%.1f curve=%.1f k=%.3f clear=%.1f m=%.2f vis=%.1f space=%.1f env=%.1f gear=%.0f passed=%s crawl=%s rs=%.1f",
                            LOG, playerNum, s.dodgeSpeedCap, s.dodgeCurveCap or -1, s.dodgeKappa or -1,
                            s.dodgeClearanceCap or -1, guardMargin or -1, s.dodgeVisibilityCap or -1,
                            s.dodgeSpaceCap or -1, s.profileEnvelope or -1, s.gearCap or -1,
                            tostring(s.dodgeEntryPassed), tostring(s.dodgeCrawl), s.lastSNow))
                    end
                end
                -- 單向鎖移除（2026-09-02 s016 定罪：commit 時的 12.9 綁死全程、
                -- 世界變好也回不去——「直線才 11」主因之一）。cap 隨守護輪連續量
                -- 即時浮動；防 flap 由釋放條件獨立把守、目標抖動由 jerk limiter
                -- 平滑。dodgeBaseCap 只剩 telemetry 鏡像（schema 只加不改名）。
                s.dodgeBaseCap = s.dodgeSpeedCap
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
                -- 線瞬跳，近停後才清（stepFollow 收尾）。煞停基準＝守護判死的那一點
                -- （guardHitS／X／Y；blockedNear 保留漸進接近：>BLOCK_STOP_DIST 滑行、
                -- 內煞停）。cap 歸零類（無命中點）才退回前方點雲世界距最近者。繞行中
                -- 前方遠處變堵死就地急煞不合理（隊友後車追撞）；找不到前方障礙（政策
                -- 中途改掉）才就地停。
                if not s.blocked then
                    s.blocked = true
                    local hs = s.guardHitS
                    if finite(hs) and hs >= s.lastSNow then
                        -- 命中點附近一個車身窗內、擋承諾線（offL）的點中取世界距最近者
                        -- （群的近端，不是掃掠迭代順序碰到的第一點、也不是路肩雜點）；
                        -- 窗內無點才退回命中點本身
                        s.blockS = resolveBlockAnchor(s, sen, vehicle, true,
                            hs - 3, hs + 2 * s.vehicleProfile.halfL, curOffL)
                        if s.blockS == nil then
                            s.blockS = hs
                            s.blockHitX, s.blockHitY = s.guardHitX, s.guardHitY
                        end
                    else
                        s.blockS = resolveBlockAnchor(s, sen, vehicle, false, s.lastSNow)
                            or s.lastSNow
                    end
                    if not s.blockedNotified then
                        s.blockedNotified = true
                        local playerObj = getSpecificPlayer(playerNum)
                        if playerObj then haloBad(playerObj, KEY_BLOCKED) end
                        voice("blocked", playerNum)
                        diagEvent(s, playerNum, "blocked", {
                            s = s.blockS, m = s.dodgeMargin, need = s.dodgeNeed,
                            x = s.blockHitX, y = s.blockHitY, why = "guard",
                            corner = s.cornerLatch, hitS = s.guardHitS,
                            hitPhase = s.guardHitPhase,
                            hitX = s.guardHitX, hitY = s.guardHitY,
                            clearance = s.guardHitClearance, hn = sen.hardN,
                            wms = Drive.replanElapsed(s), sweeps = s.sweepCount })
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
    -- 寬帶是新資訊：一般帶鎖的 latch 讓第一輪寬帶照跑候選鏈（還是 corner 就以寬帶再鎖；0929v 審查：
    -- 否則彎道旁堵住時寬帶掃完卻從不規劃路外縫，倒車閘又當成判過）；寬帶升級同理，更寬一級照跑（1004c）。
    if s.blocked and s.cornerLatch and sen.hardN > 0 then
        if s.lastSNow - s.cornerS < CORNER_RETRY_DIST
                and (not sen.wideDone or (s.cornerLatchWide or 0) >= (sen.wideDoneLevel or 1)) then
            s.planMode = "corner-latched"
            return
        end
        s.cornerLatch = false
    end
    local mode, a, b, c, d, offL
    local clearHandoff = false
    local commitNb = nil -- 本輪 commit 的掃掠淨距檔位（setOffset 成功時寫進承諾守護）
    if sen.hardN == 0 and s.pushBanL == nil then
        mode = "clear"
        clearHandoff = true
    elseif type(MDADCorridor) ~= "table" or type(MDADCorridor.plan) ~= "function" then
        -- Corridor 是選配：模組不完整時回到既有 M3 pure follower，不阻擋啟動或 HOLD。
        mode = "clear"
    else
        -- 第六參數＝搜尋中心：繞行中沿用上輪側偏防翻側；首次用 laneBias，選
        -- 離目前行駛線橫移最小的安全縫。第八參數＝行駛基準線：擋線判定以
        -- 「車實際要走的線」為中心（以中心線判會漏掉不擋中線但擋行駛線的
        -- 路緣樹，車直接蹭上卡死——2026-08-28 實機 lat=1.2 卡死 ×3）。
        -- 完整契約見 MDADCorridor.plan。
        -- 搜尋中心＝擋線基準＝行駛基準線 laneBias（immutable DODGE 後 replan 只發生在無承諾時，
        -- 舊的 lastOffL 側別記憶已無讀者——側別穩定性由「承諾不可變」保證）；RETURN hold 時是車位。
        -- baseL＝候選線的回線 lane（`Drive.dodgeHomeL`）：RETURN hold 讓位時是回線目標，不是車位。
        local prefer = laneBiasOf(s)
        local baseL = Drive.dodgeHomeL(s)
        local needUsed, planN
        mode, a, b, c, d, offL, needUsed, s.dodgeTight, planN = Drive.planDodge(s, prefer, prefer)
        clearHandoff = mode == "clear"
        s.dodgeCrawl = false
        s.dodgeStay = false
        s.dodgeDeadendS = nil
        if s.dodgeTight and getDebug() then
            print(LOG .. "pn=" .. playerNum .. " curve dodge: "
                .. (needUsed > s.needHalf and "wider gap ok, crawl"
                    or "narrow gap, crawl (sweep-guarded)"))
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
        -- 障礙群出口落在承諾窗（DODGE_OV_SPAN）之外＝這一輪根本建不出線
        -- （2026-09-04 實機 st144579：55 km/h 掃描帶看到 88m 外路口停車，c+1−s0=97
        -- > OV_MAX → 全候選 `capacity` → 「blocked (all candidates)」語音＋halo；
        -- 下一輪車前進 5m 就能 commit）。延後不是淨空：先按已知群起點保留煞停距離，
        -- 不能只靠更遠的未載入前緣限速；進窗那一輪再規劃。
        if mode == "dodge" and c + 1 + Drive.towHold(s) > s.lastSNow + TUNE.DODGE_OV_SPAN then
            mode = "clear" -- 車一前進就進窗：deferDodge 讓點雲 sig 不變也每輪重判
            Drive.deferDodge(s, playerNum, "window", b, c, nil)
        end
        -- 同族兩刀（2026-09-04 st146014／st144580／st146015）：先用主候選的幾何做一次
        -- shape 預算（冷路徑、每輪一次，候選鏈會再算一次同值）——
        -- ① exit 被承諾窗截短而 entry 還吃得下等待 → 延後（dodgeWindowShort）；
        -- ② 承諾線覆蓋到未載入區（d+1 > unloadedS）→ 延後：兩次 guard 在下一輪
        --    cell 載入後立刻判死（黑車輪廓 commit 時根本不在點雲裡）。
        --    尚未有可用承諾線，接近帽必須指向已知障礙，不是未載入前緣。
        -- 未覆蓋（coverage／unloaded）只代表「主候選」的完整退出段伸出可視前綴；候選鏈裡的停留
        -- ／微調／降檔可能退出較短、整條都在已掃範圍內，而每條候選的 sweepLine 本來就驗
        -- candidateCovered（2026-09-27 正式服 8 段：主候選一超窗就延後＋硬煞，0.2–0.6 秒後另一條
        -- 短候選 commit——等於先白煞一次）。所以只把延後理由記下、照跑候選鏈，全滅才延後；
        -- exit（出口被承諾窗截短）維持原本立即延後。
        s.planDeferWhy = nil
        if mode == "dodge" then
            local _, _, _, dS, okS0 = shapeProfile(s, s.profile, a, b, c, d, offL, baseL)
            local why = nil
            if okS0 and s.dodgeWindowShort then
                why = "exit"
            elseif okS0 and not Drive.candidateCovered(s, dS + 1) then
                s.planDeferWhy, s.planDeferD = sen.unloaded and "unloaded" or "coverage", dS
                s.planDeferB, s.planDeferC = b, c
            end
            if why then
                Drive.deferDodge(s, playerNum, why, b, c, dS)
                mode = "clear"
            end
        end
        if mode == "dodge"
                and MDAD.sandbox("ObstaclePolicy", POLICY_DODGE) ~= POLICY_DODGE then
            mode = "blocked"
            s.planDeferWhy = nil -- 停車政策不跑候選鏈：已知擋線即停等，與已覆蓋的情形一致
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
            if s.thinRec then s.thinRec.on = false end -- 換縫找更寬的記錄每輪重來（Drive.thinNote）
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
            local physBase = MDADVehicleProfile.sweepBase(s.vehicleProfile.halfW, "physical")
            -- 採納候選（四個呼叫點共用）：variant＝sweepWithFallbacks 的退路名；crawl＝
            -- 貼縫檔（base 低於 cruise）或停留。
            local function adopt(pa, pb, pc, pd, po, mg, ovN, ovS0, nbUsed, variant, tier)
                a, b, c, d, offL = pa, pb, pc, pd, po
                committed = true
                s.dodgeBuildReason = "ok"
                commitNb = nbUsed
                s.dodgeMargin, s.dodgeMarginS = mg, nil
                s.dodgeClrN, s.dodgeEnvN = 0, 0
                s.dodgeStay = variant == "stay" or variant == "stay-look"
                -- 指派而非只設 true：換縫找更寬時同一輪可能先採納窄的（爬行）再換寬的（Drive.thinNote）
                s.dodgeCrawl = nbUsed < s.sweepBase - 1e-6 or s.dodgeStay
                s.dodgeTier = variant and (tier .. "-" .. variant) or tier
                s.lastOvN, s.lastOvS0, s.lastOvEndS = ovN, ovS0, s.tmpOvEndS
            end
            -- adoptIf(tier, ok, ...)：成功即採納回 true；失敗資訊在 s.fbFail
            local function adoptIf(tier, ok, pa, pb, pc, pd, po, mg, ovN, ovS0, nbUsed, variant)
                if ok then adopt(pa, pb, pc, pd, po, mg, ovN, ovS0, nbUsed, variant, tier) end
                return ok
            end
            if not adoptIf(s.dodgeTight and "curve" or "plan", sweepWithFallbacks(
                    s, planN, a, b, c, d, offL, baseL, "plan", needBase, physBase, false)) then
                local f = s.fbFail
                a, b, c, d = f.a, f.b, f.c, f.d -- shape 後的斷點（blocked 錨沿用舊語意）
                firstHit, firstHitX, firstHitY = f.hitS, f.hx, f.hy
                local abortAll = classify(f.ph, f.hps)
                if not abortAll then
                    for phase = 1, 2 do
                        if phase == 2 and not nonCornerFail then
                            -- 全部失敗都是 corner 類：爬行檔重試不會有新資訊
                            corner = true
                            break
                        end
                        local nu, nb = needUsed, needBase
                        local pa, pb, pc, pd, po = a, b, c, d, offL
                        local tierName = phase == 2 and "crawl" or "retry"
                        if phase == 2 then
                            nu = s.squeezeNeed
                            nb = s.squeezeSweepBase
                            local mq, aq, bq, cq, dq, oq = MDADCorridor.plan(
                                sen.hardS, sen.hardL, planN, nu, sen.corridorHalf or MDADSensor.CORRIDOR_HALF,
                                prefer, sen.hardR, prefer, sen.roadLo, sen.roadHi, false, s.hardBase,
                                s.lastSNow - s.vehicleProfile.halfL, sen.corridorInner, sen.hardLc, sen.hardW)
                            if mq ~= "dodge" then break end
                            pa, pb, pc, pd, po = aq, bq, cq, dq, oq
                            if adoptIf("crawl", sweepWithFallbacks(
                                    s, planN, pa, pb, pc, pd, po, baseL, "crawl", nb, physBase, true)) then
                                if not Drive.thinNote(s, s.dodgeMargin + commitNb - s.vehicleProfile.halfW, "crawl",
                                        "crawl", pa, pb, pc, pd, po, planN, nb, true) then
                                    break
                                end
                                committed = false -- 太窄：下面的 ban 迴圈先 ban 它、往下找更寬的
                            else
                                local f = s.fbFail
                                pa, pb, pc, pd = f.a, f.b, f.c, f.d
                                if f.hitS ~= nil and (firstHit == nil or f.hitS < firstHit) then
                                    firstHit, firstHitX, firstHitY = f.hitS, f.hx, f.hy
                                end
                                if classify(f.ph, f.hps) then break end
                            end
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
                            sen.hardLc[banN], sen.hardW[banN] = nil, nil -- 虛擬 ban：擋線判定退回 hardL／hardR
                            local mk, ak, bk, ck, dk, ok2 = MDADCorridor.plan(
                                sen.hardS, sen.hardL, banN, nu, sen.corridorHalf or MDADSensor.CORRIDOR_HALF,
                                prefer, sen.hardR, prefer, sen.roadLo, sen.roadHi, false,
                                fillHardBase(s, sen, banN, prefer), s.lastSNow - s.vehicleProfile.halfL, sen.corridorInner,
                                sen.hardLc, sen.hardW)
                            if mk ~= "dodge" then break end
                            pa, pb, pc, pd, po = ak, bk, ck, dk, ok2
                            if adoptIf(phase == 2 and "crawl-retry" or "retry", sweepWithFallbacks(
                                    s, banN, pa, pb, pc, pd, po, baseL, tierName, nb, physBase, phase == 2)) then
                                if not Drive.thinNote(s, s.dodgeMargin + commitNb - s.vehicleProfile.halfW,
                                        phase == 2 and "crawl-retry" or "retry", tierName,
                                        pa, pb, pc, pd, po, banN, nb, phase == 2) then
                                    break
                                end
                                committed = false
                            else
                                local f = s.fbFail
                                pa, pb, pc, pd = f.a, f.b, f.c, f.d
                                if f.hitS ~= nil and (firstHit == nil or f.hitS < firstHit) then
                                    firstHit, firstHitX, firstHitY = f.hitS, f.hx, f.hy
                                end
                                if classify(f.ph, f.hps) then aborted = true; break end
                            end
                        end
                        -- 找完沒有更寬的：採納記下最寬的那條（窄縫照過，09-01「物理可過就過」）
                        if not committed then Drive.thinAdopt(s, adoptIf, sweepWithFallbacks, baseL, physBase) end
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
                    local mp, pa2, pb2, pc2, pd2, po2 = MDADCorridor.plan(
                        sen.hardS, sen.hardL, planN, probeNeed,
                        sen.corridorHalf or MDADSensor.CORRIDOR_HALF, prefer, sen.hardR, prefer,
                        sen.roadLo, sen.roadHi, false, s.hardBase,
                        s.lastSNow - s.vehicleProfile.halfL, sen.corridorInner, sen.hardLc, sen.hardW)
                    if mp == "dodge" then
                        if adoptIf("probe", sweepWithFallbacks(
                                s, planN, pa2, pb2, pc2, pd2, po2, baseL, "probe", physBase, physBase, true)) then
                            if getDebug() then
                                print(LOG .. "pn=" .. playerNum
                                    .. " physical probe commit: squeeze-through at offL="
                                    .. string.format("%.2f", offL))
                            end
                        end
                    end
                    -- 0928i（rc8 0086：RETURN 剛收完，路緣 l=3.05 的兩點已在車身旁；0089：交接釋放當輪）：
                    -- 群貼在車旁／車前、舒適需求的候選全因 steep 拒收，舊制 blocked 一秒鎖輪從 20–29 km/h
                    -- 煞到 0，下一輪物件已在車後又照常走。車就沿現在的橫向直走（dl=0，不需要進入段），
                    -- 物理檔世界掃掠過了就當貼縫承諾；過不了才是真 blocked。
                    if not committed then
                        local shapeWhy = s.dodgeShapeReason
                        if adoptIf("probe-straight", sweepWithFallbacks(
                                -- a..d 已是形塑後的斷點（8346 沿用 blocked 錨語意）：拖車的保持段延長先扣掉再形塑
                                s, planN, a, b, c - Drive.towHold(s), d - Drive.towHold(s),
                                startLaneOf(s, baseL), baseL, "probe-straight",
                                physBase, physBase, true)) then
                            if getDebug() then
                                print(string.format("%spn=%d physical straight commit at offL=%.2f",
                                    LOG, playerNum, offL))
                            end
                        else
                            s.dodgeShapeReason = shapeWhy -- blocked 事件沿用候選鏈的拒收理由（steep 等）
                        end
                    end
                end
                if committed then
                    if getDebug() then
                        print(string.format("%spn=%d sweep enumerate: offL=%.2f ok%s",
                            LOG, playerNum, offL, s.dodgeCrawl and " (crawl)" or ""))
                    end
                elseif s.planDeferWhy and not (sen.wideDone and s.wideArmed) then
                    -- 主候選未覆蓋、鏈裡也沒有覆蓋得到的替代線：回到原本的延後（先按已知群起點煞停）。
                    -- 停在停點的寬帶判堵不延後：延後的接近帽會讓車往群前爬、吃掉進入段跑道，
                    -- 而且清掉判堵＝解除寬帶武裝，一般帶／寬帶來回判、永遠不倒車（0929v）。照判堵走倒車重判。
                    Drive.deferDodge(s, playerNum, s.planDeferWhy, s.planDeferB, s.planDeferC, s.planDeferD)
                    mode = "clear"
                else
                    mode = "blocked"
                    s.dodgeBlockReason = (corner or not nonCornerFail) and "corner" or "sweep"
                    -- 候選鏈全滅且含 steep 拒收＝跑道不夠：差額交給倒車（只在這條出口快照——
                    -- steepDeficitM 任何 replan 都可能寫，直接拿它當停等閘會誤觸其他 blocked）
                    s.blockSteepM = (finite(s.steepDeficitM) and s.steepDeficitM > 0)
                        and math.min(s.steepDeficitM, TUNE.UNSTICK_STEEP_MAX_M) or -1
                    if type(firstHit) == "number" then a = firstHit end
                    if corner or not nonCornerFail then
                        -- BLOCKED_CORNER：latch 到障礙清除／換路線為止——之後的
                        -- replan 輪不再重跑候選鏈（重試沒有新資訊、只是洗 log），
                        -- cornerLatchWide＝鎖住時的寬帶級（0＝一般帶）：更寬一級的快照是新資訊，照跑候選鏈
                        s.cornerLatch, s.cornerLatchWide = true, sen.wideDone and (sen.wideDoneLevel or 1) or 0
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
                s, sen, planN, prefer, prefer, baseL, playerNum)
            if okD then
                mode, a, b, c, d, offL, commitNb = "dodge", aD, bD, cD, dD, oD, nbD
            end
        end
        -- 沒跑候選鏈就判堵（初判無縫、降檔也沒縫）：steep 差額只算這一輪降檔候選的（steepDeficitM 每輪 replan 起頭歸 −1），
        -- 不沿用上一次判定的快照（1004c E2E blockscan dixie9350w：第二級的 steep 差額留到之後每次第一級無縫判堵，
        -- 寬帶不再升級、改道一直讓給倒車）。blocked 事件的 shape 欄同理。
        if mode == "blocked" and not sweptChain then
            s.blockSteepM = (finite(s.steepDeficitM) and s.steepDeficitM > 0)
                and math.min(s.steepDeficitM, TUNE.UNSTICK_STEEP_MAX_M) or -1
            if s.blockSteepM < 0 then s.dodgeShapeReason = nil end
        end
        if mode == "dodge" then
            local vp = s.vehicleProfile
            local minBrake, minLat = MDADFollower.minDynamics(
                s.profile, a, d, s.fstate.idx)
            if finite(s.safeBrake) and s.safeBrake >= 0
                    and s.safeBrake < minBrake then minBrake = s.safeBrake end
            if finite(s.safeLat) and s.safeLat >= 0
                    and s.safeLat < minLat then minLat = s.safeLat end
            local kappa = dodgeLineKappa(s.profile, s.tmpOvX, s.tmpOvY, s.lastOvN or 0, s.lastOvS0,
                s.lastSNow - vp.halfL, a, b, c, d)
            local visibilityCap = Drive.dodgeVisibilityCap(s, sen, minBrake)
            local dl = offL - startLaneOf(s, baseL)
            if dl < 0 then dl = -dl end
            s.dodgeCommitDl = dl
            -- 起始車位不等於常駐 lane 時，entryDl 不能冒充 exitDl；回線逐段夾過
            -- laneRoom 後可能要橫移更多。冷路徑凍結最大需求，升速不借用這份餘裕。
            -- 0907d：落點沿弧長連續（clampLane 帶 sAt）後，出口段內的落點會被窗外 12m 的窄段
            -- 收緊——逐段 raw 值看不到（Codex lane 反例：出口段所在段 room 1.6、6m 外一段 0.6，
            -- 逐段 exitDl=1、實線 1.5）。沿 [c,d] 以 OV_STEP 取樣連續值＝與 buildOffsetLine 同一條線。
            s.dodgeExitDl = math.abs(offL - baseL)
            local exitEnd = math.min(d, s.profile.length)
            local sx = c
            local exitSeg = MDADFollower.segIndexAt(s.profile, c)
            while true do
                while exitSeg < s.profile.n - 1 and s.profile.s[exitSeg + 1] < sx do exitSeg = exitSeg + 1 end
                local exitLane = MDADFollower.laneBiasAt(s.profile, baseL, exitSeg, sx)
                local exitDl = math.abs(offL - exitLane)
                if exitDl > s.dodgeExitDl then s.dodgeExitDl = exitDl end
                if sx >= exitEnd then break end
                sx = sx + MDADFollower.OV_STEP
                if sx > exitEnd then sx = exitEnd end
            end
            s.dodgeClass = Drive.movingWithin(s, s.lastOvEndS)
                and MDADDynamics.DODGE_VEHICLE or MDADDynamics.DODGE_STATIC
            local capReason = updateDodgeCaps(s, s.dodgeMargin, kappa, minLat,
                visibilityCap, true, false)
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
                        s.dodgeMargin or -1, s.dodgeCurveCap, s.dodgeClearanceCap, visibilityCap,
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
    if mode == "dodge" and s.dodgeCrawl and not s.dodging
            and finite(s.lastRouteErr) and s.lastRouteErr > TUNE.DODGE_CRAWL_ALIGN_RAD then
        -- 理由見 TUNE.DODGE_CRAWL_ALIGN_RAD：姿態沒擺正不承諾貼縫，下一輪再問；擺正前先按縫口降速
        mode = "clear"
        s.planSig = -1
        s.dodgeDeferCap, s.dodgeDeferS = Drive.alignDeferCap(s, b, s.dodgeSpeedCap), b
        diagEvent(s, playerNum, "dodge", { phase = "defer", why = "align",
            offL = offL, rs = s.lastSNow, m = s.dodgeMargin, cap = s.dodgeDeferCap })
        if getDebug() then
            print(string.format("%spn=%d dodge defer (align): routeErr=%.1fdeg offL=%.2f",
                LOG, playerNum, s.lastRouteErr * TUNE.DEG_PER_RAD, offL))
        end
    end
    if mode == "dodge" and not s.dodging
            and Drive.trafficBlocksDodge(s, a, d, offL, vehicle:getCurrentSpeedKmHour()) then
        -- 理由見 Drive.trafficBlocksDodge：對向車會進繞行段＝停在 a 前讓車，下一輪再問
        mode = "clear"
        s.planSig = -1
        -- 停點＝障礙前留一段爬行側移跑道（b − √(6·dl／κ_crawl)，同 shapeProfile 的陡坡量），不是
        -- 過渡起點 a——長過渡段的 a 可能已在車後，停在 a 前＝原地停住、連回右側的橫移都做不了；
        -- 也不是 b——貼著停車停下，對向車過了之後側移沒有跑道，只能倒車（E2E park 變體兩輪）。
        -- 減速度用鬆油門（safeCoast）：定速提早收油、不靠一秒鎖輪的硬煞（鎖輪時轉向無效）。
        s.dodgeDeferCap = Drive.trafficStopCap(s, b, offL)
        s.dodgeDeferS = b
        diagEvent(s, playerNum, "dodge", { phase = "defer", why = "traffic",
            offL = offL, a = a, b = b, d = d, rs = s.lastSNow, cap = s.dodgeDeferCap })
        -- 停在障礙前等對向車：提示一次（連續等待 5 秒內不重複；換一次等待會再提示）
        local nowW = getTimestampMs()
        if nowW - (s.trafficWaitMs or -1e9) > TUNE.TRAFFIC_WAIT_NOTICE_MS then
            local playerObj = getSpecificPlayer(playerNum)
            if playerObj then haloGood(playerObj, KEY_TRAFFIC.wait) end
        end
        s.trafficWaitMs = nowW
        if getDebug() then
            print(string.format("%spn=%d dodge defer (traffic): offL=%.2f a-rs=%.1f cap=%.1f",
                LOG, playerNum, offL, a - s.lastSNow, s.dodgeDeferCap))
        end
    end
    if mode == "dodge" and not s.dodging then
        -- 不看 crawl 分類：一般繞行也可能只允許低速，不能以現速硬承諾追不到的線。
        local v = vehicle:getCurrentSpeedKmHour()
        local capK = s.dodgeSpeedCap
        if finite(v) and finite(capK) and v > capK + TUNE.DODGE_SPEED_TOL then
            -- 門檻用縫起點 b 與完整 safeBrake（物理能不能在縫前減到 cap，不是舒適預算）
            local decel = s.safeBrake
            if not finite(decel) or decel <= 0 then decel = 2 end
            local vm, cm = v / 3.6, capK / 3.6
            local dist = b - s.lastSNow - s.vehicleProfile.halfL
            -- 0925p：連緊急煞停都停不住（硬煞當幀生效，留 0.3s 反應＋硬煞界限，同可視上限的緊急帳）時延後＝保證以
            -- 高速撞上障礙（E2E meet park、RaceCar MAX：B 過後 A 63 km/h 距停車 13m 仍延後、52 km/h
            -- 撞上）；掃掠驗過的線照承諾，帽由既有接近帽／硬煞邊做邊壓。對向車仍由上方
            -- trafficBlocksDodge 先擋。
            local aE = tightenLimit(math.min(decel * TUNE.EMERGENCY_BRAKE_GAIN, TUNE.EMERGENCY_BRAKE_MAX),
                s.brakeLower, s.brakeConfidence, TUNE.EMERGENCY_BRAKE_MAX)
            if dist >= TUNE.DODGE_SPEED_DEFER_MIN_M and dist < (vm * vm - cm * cm) / (2 * decel)
                    and (aE <= 0 or dist >= vm * 0.3 + vm * vm / (2 * aE)) then
                mode = "clear"
                s.planSig = -1
                s.dodgeDeferCap = MDADDynamics.approachCapKmh(dist, capK, 0.5, decel)
                s.dodgeDeferS = b
                diagEvent(s, playerNum, "dodge", { phase = "defer", why = "speed",
                    offL = offL, rs = s.lastSNow, cap = capK, speed = v, b = b })
                if getDebug() then
                    print(string.format("%spn=%d dodge defer (speed): spd=%.1f cap=%.1f b-rs=%.1f offL=%.2f",
                        LOG, playerNum, v, capK, b - s.lastSNow, offL))
                end
            end
        end
    end
    -- 候選與舊線共用工作表，失敗後不能沿用舊 prefix；defer 不是淨空。
    -- 停止約束跨輪存續，只有 setOffset 成功或真正 clear 的遲滯完成才解除。
    if s.dodgeHandoffHold then
        s.dodgeDeferCap = 0
        if mode == "clear" and not clearHandoff then mode = "blocked" end
    end
    if mode == "dodge" then
        -- setOffset 引數不合法回 false（不動 state）：此時寧可當 blocked 煞停，
        s.clearStreak = 0
        -- 也不能無側偏直直開進障礙
        -- 停留承諾的線只到 d＝c＋車身（沒有回線段可驗），覆蓋要求跟著鉗
        local coverEnd = s.dodgeStay and d or d + 1
        if coverEnd > s.profile.length then coverEnd = s.profile.length end
        if MDADFollower.setOffset(s.fstate, a, b, c, d, offL,
                s.tmpOvX, s.tmpOvY, s.lastOvN or 0, s.lastOvS0 or 0,
                s.lastOvEndS or 0, coverEnd) then
            s.dodging = true
            s.dodgeWide = (s.sensor.corridorHalf or MDADSensor.CORRIDOR_HALF) > MDADSensor.CORRIDOR_HALF
            s.dodgeWideLevel = s.dodgeWide and (s.sensor.wideDoneLevel or 1) or nil -- 守護輪沿用承諾那一級的帶寬
            Drive.disarmWide(s) -- 堵點已有承諾線（寬帶繞行本身由 dodgeWide 維持寬帶）
            if s.dodgeHandoffHold then
                s.dodgeHandoffHold, s.dodgeDeferCap = false, -1
            end
            s.blocked = false
            s.blockedNotified = false
            s.dodgeBaseCap = s.dodgeSpeedCap
            s.dodgeCapPending = false
            s.dodgeNeed = commitNb or s.sweepBase -- 承諾檔淨距（守護輪同契約）
            -- 出口加長（Drive.extendDodgeExit）重建同一條線要用的起始 lane 與回線 lane（與候選鏈同一個
            -- Drive.dodgeHomeL；RETURN 還沒在下方結束，接手時取到的是回線目標）
            s.dodgeBaseL, s.dodgeExtendFailS = Drive.dodgeHomeL(s), nil
            s.dodgeStartL = startLaneOf(s, s.dodgeBaseL)
            -- RETURN hold 讓位給 dodge 不能只讓剖面（2026-09-03 s017：起步就 hold(probe)
            -- → 「return line blocked: dodge takes over」→ 原地 15s 紅字）：
            -- controlStateOf 的 returnHold=HOLD 仍壓 intent WAIT，而 updateReturnSnapshot
            -- 在 dodge 持有時早退、stall 釋放永遠跑不到——dodge 有線不能走、RETURN 有
            -- hold 不能放。takeover＝RETURN 結束（線是掃掠驗過的），剖面走完 latDev
            -- 若仍大 RETURN 下一輪自然重進；冷卻與 stall 釋放同款。
            if s.returnActive then
                endReturn(s)
                s.returnBlockUntil = sen.stamp + TUNE.RETURN_STALL_BLOCK_MS
                MDADFollower.setLaneBias(s.fstate, s.returnLaneTarget)
                sen.scanBias = s.returnLaneTarget
                diagEvent(s, playerNum, "return", { phase = "release", why = "dodge",
                    s = s.lastSNow })
            end
            -- 鏈式停留（TUNE.STAY_TAIL_M）：常駐 lane 即刻換成 offL——線走完之後
            -- follower 的 smoothstep 以 bias＝offL 為底＝平行續行；laneChained 讓
            -- 每輪路面對中不把 lane 拉回常駐偏置，前方淨空時解鏈。
            if s.dodgeStay then
                -- laneBias 不在 commit 當下切成 offL（2026-09-04 s056 t=8.7：車在 +1.5、停留
                -- −2.5 一 commit 期望線跳 4m → RETURN_DODGE_DEV 觸發 RETURN 殺掉承諾，之後從
                -- 錯的基準重規劃、彎後 0.45m 誤差撞 A）。進入段由承諾線自己帶，過 b（車已在
                -- 停留 lane）再切；未到 b 就釋放＝車根本沒到那條 lane，不切。
                s.stayLanePending = offL
                sen.scanBias = offL
                s.laneChained, s.chainKeptLogged = true, nil
            end
            s.trafficLate = false
            -- 玩家可見的減速要有理由：繞行開始提示一次（持續繞行時 sig 每輪微變、
            -- replan 反覆進來，靠 dodgeNotified 防轟；clear/blocked 時重臂）
            if not s.dodgeNotified then
                s.dodgeNotified = true
                local playerObj = getSpecificPlayer(playerNum)
                if playerObj then haloGood(playerObj, KEY_DODGE) end
            end
            -- 每次 commit 一筆（含 cap 分解）：玩家 telemetry 必須自足（2026-09-04）
            diagEvent(s, playerNum, "dodge", {
                phase = "commit", a = a, b = b, c = c, d = d, offL = offL,
                cap = s.dodgeSpeedCap, m = s.dodgeMargin, curve = s.dodgeCurveCap,
                clear = s.dodgeClearanceCap, vis = s.dodgeVisibilityCap,
                space = s.dodgeSpaceCap, design = s.dodgeDesignSpeed,
                crawl = s.dodgeCrawl == true, tight = s.dodgeTight == true,
                tier = s.dodgeTier, need = s.dodgeNeed, rs = s.lastSNow,
                len = s.dodgeCommittedLength, hn = sen.hardN,
                wms = Drive.replanElapsed(s), sweeps = s.sweepCount,
                why = s.planDeferWhy, -- 主候選本會延後（window／coverage／unloaded）、由候選鏈的替代線承諾
                thin = s.thinRec and s.thinRec.on and s.thinRec.phys or nil, -- 換縫找更寬時記下最窄那條的物理淨距
                preA = s.diag and Drive.preAClear(s) or nil }) -- pre-a 段最小物理淨距（只在紀錄開著時量）
            if getDebug() then
                -- cap 分解一行印清楚（2026-09-04 實機三段 8／15／14 km/h 繞行，console
                -- 只有「cap zero」才印分解，正值慢吞吞完全無從復盤）
                print(string.format(
                    "%spn=%d dodge a=%.1f b=%.1f c=%.1f d=%.1f offL=%.2f cap=%.1f margin=%.2f curve=%.1f k=%.3f clear=%.1f vis=%.1f space=%.1f design=%.1f env=%.1f gear=%.0f crawl=%s tight=%s need=%.2f",
                    LOG, playerNum, a, b, c, d, offL, s.dodgeSpeedCap or -1,
                    s.dodgeMargin or -1, s.dodgeCurveCap or -1, s.dodgeKappa or -1, s.dodgeClearanceCap or -1,
                    s.dodgeVisibilityCap or -1, s.dodgeSpaceCap or -1, s.dodgeDesignSpeed or -1,
                    s.profileEnvelope or -1, s.gearCap or -1,
                    tostring(s.dodgeCrawl), tostring(s.dodgeTight), s.dodgeNeed or -1))
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
        if s.dodgeHandoffHold then
            s.dodgeHandoffHold, s.dodgeDeferCap = false, -1
        end
        s.blocked = false
        Drive.disarmWide(s)
        s.blockedNotified = false
        s.dodgeNotified = false
        if s.laneChained then
            -- 鏈式停留解鏈：停留 lane 前方淨空**且常駐線前方也淨空**才交回（常駐線還
            -- 被下一台擋著就繼續停留——「貼北緣直到過了 A 再回來」）；下一輪路面對中把
            -- lane 交回常駐偏置，橫向回歸由 RETURN／pure pursuit 帶（同「玩家把車擺在
            -- 線外」的既有路徑）。擋常駐線的那群夠遠也解鏈（Drive.chainBlockerFar，1004a）。
            local resident = s.residentBias or s.sandBias
            local rm, _, rb = MDADCorridor.plan(sen.hardS, sen.hardL, sen.hardN, s.needHalf,
                sen.corridorHalf or MDADSensor.CORRIDOR_HALF, resident, sen.hardR, resident,
                sen.roadLo, sen.roadHi, false, nil, s.lastSNow - s.vehicleProfile.halfL, nil, sen.hardLc, sen.hardW)
            local far = rm == "dodge" and Drive.chainBlockerFar(s, rb, vehicle:getCurrentSpeedKmHour())
            if rm == "clear" or far then
                s.laneChained = false
                s.stayHoldEndS = nil
                s.chainKeptLogged = nil
                diagEvent(s, playerNum, "dodge", { phase = "unchain", why = far and "far" or "clear",
                    offL = laneBiasOf(s), s = far and rb or nil, rs = s.lastSNow })
                if getDebug() then
                    print(string.format("%spn=%d lane unchained (%s): lane=%.2f -> resident %.2f",
                        LOG, playerNum, far and "far" or "clear", laneBiasOf(s), resident))
                end
            else
                -- 1004a：鏈因常駐線前方仍被擋而續留，記一次（每條鏈）擋住常駐線那群要偏到位的弧長 s（b）——
                -- 玩家回報「繞過之後一直走路邊」時分得出是鏈被擋線點留住，還是別的持有者
                if not s.chainKeptLogged then
                    s.chainKeptLogged = true
                    diagEvent(s, playerNum, "dodge", { phase = "kept", offL = laneBiasOf(s), l = resident,
                        s = rb, rs = s.lastSNow, detail = tostring(rm) })
                end
                if getDebug() then
                    print(string.format("%spn=%d lane chained %.2f kept: resident %.2f still %s",
                        LOG, playerNum, laneBiasOf(s), resident, tostring(rm)))
                end
            end
        end
        if not s.banFromRecovery then
            s.pushBanL, s.pushBanS = nil, 0
        end
        s.cornerLatch = false
        s.blockHitX, s.blockHitY = nil, nil
        s.planMode = s.currentBlocked and "current-blocked" or "clear"
        return
    end
    s.clearStreak = 0
    -- 鏈上搜尋中心偏一側，候選額度（DODGE_CANDIDATES）全花在同側＝對側的縫根本沒被問
    -- （2026-09-04 s@165140：停留 −3.25 後 −5.25／−4.25／−5.50 全滅 → blocked → 5s 停等
    -- ＋倒車後解鏈才找到 +2.00）。任何 blocked 出口若仍鏈著＝這一輪先解鏈回常駐線、
    -- 下一輪從中線重枚舉，不先停 5 秒；下一輪仍 blocked 才是真堵。
    -- 提早釋放的停留（TUNE.STAY_SETTLED_M）在 c 之前全滅：不解鏈、不停等——停留 lane 本身是
    -- 掃掠驗過的，沿它爬到 c 再重枚舉（2026-09-04 s@172558：釋放→全滅→解鏈→常駐線被 A 擋→
    -- blocked 停等→倒車第二次）。速度由 blocked 接近帽（下方 blockedStop 分支不進）照常態 cap。
    -- 只在「全滅的群起點在 c 之後」才 stay-hold（2026-09-04 st174,068：群就在車前 rs≈a，
    -- 煞停 envelope 算成 0 → 車停在 c 前 26 秒、不 blocked 不倒車，直到手動停）；群已在
    -- c 之前＝停留 lane 本身被擋，走一般 blocked 流程（停等／倒車）。
    if s.laneChained and finite(s.stayHoldEndS) and s.lastSNow < s.stayHoldEndS
            and finite(a) and a > s.stayHoldEndS then
        s.planSig = -1
        s.planMode = "stay-hold"
        -- 速度：對全滅群起點 a 的煞停 envelope（同 blocked 接近），c 之後照常態 blocked 流程
        local decel = s.safeBrake
        if not finite(decel) or decel <= 0 then decel = 0.6
        else decel = decel * TUNE.APPROACH_BRAKE_FRAC end
        local dist = (finite(a) and a or s.stayHoldEndS) - s.lastSNow - s.vehicleProfile.halfL
        s.dodgeDeferCap = MDADDynamics.approachCapKmh(dist, 0, 0.5, decel)
        s.dodgeDeferS = s.lastSNow + s.vehicleProfile.halfL + dist
        if getDebug() then
            print(string.format("%spn=%d stay-hold: chain candidates failed before c (rs=%.1f c=%.1f)",
                LOG, playerNum, s.lastSNow, s.stayHoldEndS))
        end
        return
    end
    -- 重錨只做一次：laneBias 已在車位（差 < 0.5m）仍全滅＝真堵，走 blocked 停等／倒車
    -- （2026-09-04 st174,053：每輪重錨 15 次、從不 blocked、車 18 km/h 直接撞進 B）
    local anchorLat = s.lastLatSigned
    local anchorDiff = finite(anchorLat) and (laneBiasOf(s) - anchorLat) or 0
    if anchorDiff < 0 then anchorDiff = -anchorDiff end
    if s.laneChained and not s.cornerLatch and anchorDiff > 0.5 then
        -- 重錨在車的實際橫向位置、鏈不放（2026-09-04 s@173404／173555：解鏈把 laneBias 設回
        -- 常駐 1.5、車卻在 −3.25 → 下一輪從 1.5 算 dl=0.5 過陡坡閘、線建在車 4.75m 外 →
        -- commit 即 guard 判死 → blocked 停等 → 倒車；使用者「這次反而沒那麼順」）。
        -- 從車位重枚舉一樣能找到對側縫（prefer＝車位＝離車最近的縫），dl 也是真的。
        local anchor = s.lastLatSigned
        if not finite(anchor) then anchor = laneBiasOf(s) end
        s.stayHoldEndS = nil
        s.planSig = -1
        MDADFollower.setLaneBias(s.fstate, anchor)
        sen.scanBias = anchor
        diagEvent(s, playerNum, "dodge", { phase = "unchain", why = "blocked",
            offL = anchor, rs = s.lastSNow })
        if getDebug() then
            print(string.format("%spn=%d lane re-anchored (blocked): chain lane -> car lat %.2f, re-enumerate next round",
                LOG, playerNum, anchor))
        end
        s.planMode = "unchain"
        return
    end
    -- blocked：清側偏、漸進接近後煞停等待（掃描持續，障礙消失自動恢復；玩家接手
    -- 走讓位）。停等判距以「車到群最近 hard 點的世界距離」為權威（blockedNear；
    -- 投影弧長在繞遠／橫偏時虛高——s045 弧長差 1m/世界 18m）：>BLOCK_STOP_DIST
    -- 先滑行接近，掃描逼近後的縫隙判定比 30 公尺外那輪準（覆蓋完整、量化誤差小）。
    MDADFollower.clearOffset(s.fstate)
    s.dodging = false
    s.dodgeNotified = false
    s.blocked = true
    -- a＝Corridor blocked 時的 sObs0；缺 Corridor 的保守分支沒有 a → 0＝立即煞停
    s.blockS = a or 0
    -- 群最近擋線點世界座標＝blockedNear 判距權威（s051 定罪：blockS 是判定輪
    -- 快照的弧長、hardS 是當前快照的弧長，車一動兩基準脫節）。每輪 blocked 都
    -- 重掃（車接近時錨跟著新快照走）；掃不到擋線點（保守分支）留 nil → 退弧長。
    -- 與 Corridor.plan 同一個 minS（車尾）：車後的擋線點不是這次 blocked 的原因
    resolveBlockAnchor(s, sen, vehicle, true, s.lastSNow - s.vehicleProfile.halfL)
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
            hn = s.sensor and s.sensor.hardN or 0, wms = Drive.replanElapsed(s), sweeps = s.sweepCount,
            corner = s.cornerLatch, detail = s.dodgeBlockReason,
            blocker = s.dodgeDeadendS, shape = s.dodgeShapeReason,
            -- 候選鏈最後記下的命中（sweep 全滅時才有意義）：相位、世界點、牽引車或掛車（0929p）
            hitPhase = s.dodgeBlockReason == "sweep" and s.fbFail and s.fbFail.ph or nil,
            hitX = s.dodgeBlockReason == "sweep" and s.fbFail and s.fbFail.hx or nil,
            hitY = s.dodgeBlockReason == "sweep" and s.fbFail and s.fbFail.hy or nil,
            kind = s.dodgeBlockReason == "sweep" and s.fbFail and s.fbFail.body or nil })
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
    -- 寬帶重判後仍判堵：每次脫困嘗試、每一級各記一筆（上面只在第一次判堵記，那時多半還是一般帶；路外繞不過的原因要看
    -- 寬帶這筆，0929r；lvl＝寬帶級，1004c）。wideBlockedLogged 在寬帶武裝解除時清。
    local wideKey = sen.wideDone and s.episodeAttempts * 10 + (sen.wideDoneLevel or 1) or nil
    if wideKey and s.wideBlockedLogged ~= wideKey then
        s.wideBlockedLogged = wideKey
        diagEvent(s, playerNum, "blocked", {
            why = "wide", s = s.blockS, x = s.blockHitX, y = s.blockHitY, hn = sen.hardN, lvl = sen.wideDoneLevel,
            wms = Drive.replanElapsed(s), sweeps = s.sweepCount,
            attempt = s.episodeAttempts, detail = s.dodgeBlockReason, shape = s.dodgeShapeReason,
            hitPhase = s.dodgeBlockReason == "sweep" and s.fbFail and s.fbFail.ph or nil,
            hitX = s.dodgeBlockReason == "sweep" and s.fbFail and s.fbFail.hx or nil,
            hitY = s.dodgeBlockReason == "sweep" and s.fbFail and s.fbFail.hy or nil,
            kind = s.dodgeBlockReason == "sweep" and s.fbFail and s.fbFail.body or nil })
    end
end

-- 倒車脫困：regulator 不會倒車（CarController 只向前供油），改用向後衝量直接推
-- （relPos 全零＝純中心力，不產生力矩）。
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
            if Drive.stuckDetour(s, playerNum) then return end
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
            if Drive.stuckDetour(s, playerNum) then return end
            Drive.stop(playerNum, KEY_STUCK)
            return
        end
        if av >= 1 then
            commandForceBrake(s, vehicle, now, "unstick-stop")
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
        -- 起步接了越野線、倒車又退到接線起點之後：舊剖面從舊車位起算，退出來的距離全被夾在 s=0，
        -- 進入段一寸也沒多（E2E startpush c25 起手偏 36°：三次倒車 entry 恆 1.0 → 受困交還）。
        -- 下一次取路從現在的車位重接（同一條 cutover；路網起點在車後的一般情況由主 MOD 近線重算處理）。
        if s.approachM > 0 and not s.tow then
            local _, am = Drive.approachRoute(s.route, vx, vy)
            if am > 0 then
                s.reapproach = true
                s.pendingRouteWhy = "approach"
                s.nextRouteMs = now
            end
        end
        return
    end

    local wantSq = UNSTICK_DIST_SQ
    -- 拖車倒車：掛車折角超過上限＝再倒就折死，當成「倒夠了」走 settle
    local towPhi = nil
    if s.tow then
        towPhi = MDADTrailer.state(vehicle, s.tow)
        if towPhi == nil or math.abs(towPhi) > MDADTrailer.REVERSE_HITCH_MAX then dist2 = 1e9 end
    end
    if s.unstickExtraM and s.unstickExtraM > 0 then
        local w = 3 + s.unstickExtraM
        wantSq = w * w
    end
    if s.unstickTravelM > 0 and s.unstickTravelM * s.unstickTravelM < wantSq then
        wantSq = s.unstickTravelM * s.unstickTravelM
    end
    -- 時限到但已退出 UNSTICK_MIN_M：同「倒到後方出現障礙」一樣當倒夠了進 settle 重掃
    -- （2026-09-26 E2E trailer-grass-mp：拖著掛車在草地倒車 4 秒只退 2.2m，舊制直接交還）
    if dist2 >= wantSq or (now >= s.unstickUntil and s.unstickDistance >= TUNE.UNSTICK_MIN_M) then
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
        commandForceBrake(s, vehicle, now, "unstick-settle")
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
        if Drive.stuckDetour(s, playerNum) then return end
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
            local band = nil
            if s.unstickTravelM > 0 then
                band = s.unstickTravelM - s.unstickDistance + TUNE.REAR_KEEP_M
                if band < TUNE.REAR_KEEP_M then band = TUNE.REAR_KEEP_M end
            end
            status, hitX, hitY, kind, detail = rearProbe(s, vehicle, fwd, fx, fy, vx, vy, band)
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
            -- 倒到後方出現障礙＝「倒夠了」不是「倒不了」（2026-09-04 s051/s052：後方
            -- 燒毀車 5m，倒 1.3-1.8 秒探到它就整個 session 交還，使用者「第二次也太早
            -- 停了」；起步前探不通走 softFail 回停等，中途探不通卻硬交還——兩條路徑
            -- 沒有理由不一致）。已退出一段就進 settle 重掃（同 UNSTICK_DIST 成功路徑）；
            -- 一寸未退＝與起步前同款回停等（15s 總上限另有紅字）。
            if s.unstickDistance >= TUNE.UNSTICK_MIN_M then
                s.mode = "settle"
                s.progressState = "settle"
                s.settleUntil = now + SETTLE_MS
                s.currentBlocked = false
                s.currentClearRounds = 0
                s.episodeClearRounds = 0
                commandForceBrake(s, vehicle, now, "contact-settle")
            else
                s.blockRetryDone = true
                s.mode = "follow"
                s.progressState = "disarmed"
                s.progressSince = 0
            end
            return
        end
    end

    if flen2 > 1e-6 then
        local force = UNSTICK_PUSH * MASS_BASE * mass * IMPULSE_SCALE * (mult / MULT_NORM)
        if speedKmh < -TUNE.UNSTICK_REVERSE_KMH then force = 0 end -- 倒車限速（理由見 TUNE）
        if force > 0 then
            local impulse = BaseVehicle.allocVector3f()
            impulse:set(-force * fx, 0, -force * fy)
            fwd:set(0, 0, 0)
            vehicle:addImpulse(impulse, fwd)
            BaseVehicle.releaseVector3f(impulse)
        end
        s.reverseForce = force
        if towPhi then
            -- 倒車時掛車不穩定（折角自己變大）：牽引車往掛車方向轉把折角拉回 0（MDADTrailer.reverseSteer）
            applySteering(s, vehicle, fwd, fx, fy, MDADTrailer.reverseSteer(towPhi),
                speedKmh, mult, false, 0)
        end
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
    s.prevStepMs, s.stepWallMs = s.stepWallMs, now -- 上一個跟線幀的牆鐘（Drive.progressPauseMs 判卡頓）
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
    s.frameMs = mult * SECONDS_PER_MULT * 1000 -- 未夾的引擎幀時（telemetry fdt）
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
    s.brakeImpulseThis, s.brakeAssistForce = false, 0
    -- 上一幀施的巡航減速輔助留給 updateTraction：本幀的 dv 是那一幀的物理結果（滑行學習要排除它）
    s.visAssistPrev, s.visAssistDecel, s.towAssistDecel, s.accelAssist = s.visAssistDecel, 0, 0, 0
    s.towBrakeWhy, s.visAssistWhy = nil, nil

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
        s.lastVehicleHeading = heading
        updateTraction(s, now, speedKmh, heading, s.lastHeadingError, s.lastLatDev)
        if s.dynamicsFault then postAction = "dynamics-fault" end
        -- 所有已掃掠繞行線都追切線；只有貼縫仍加倍位置環，普通繞行不放大增益。
        -- 已掃掠的 RETURN 回線同理（2026-09-27 正式服 Mini：8m 內橫移 2m 的回線，長前視點越過
        -- 大半進入段，姿態早早追平、位置落後擦到旁物）；crawl-exact 是沿現偏移的平行線，一併無妨。
        s.fstate.trackTangent = s.dodging == true
            or (s.returnActive == true and not s.returnHold)
        local steer, targetSpeed, remaining, done, headingError, lateralSq, latSigned, lineLat = MDADFollower.control(
            s.profile, s.fstate, vx, vy,
            heading, speedKmh, mult * SECONDS_PER_MULT)
        s.followerTarget = targetSpeed -- telemetry ftg：剖面原始目標（cap／jerk 之前；0907e 錨定 bug 只靠它定罪）
        -- 本幀「真的施出去的 steer」由 applySteering 回寫；煞停／不施力的幀維持 0，Follower 的
        -- yaw 增益估計就不會把滑行中的 yaw 算到一個沒施出去的 steer 頭上（0908a）
        s.fstate.appliedSteer = 0
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
        -- 期望線＝Follower 真正在追的線：繞行／RETURN 有 exact line 時取它在投影點的橫向
        -- lineLat（停留線換道從 commit 點就開始，a..b smoothstep 算的期望線與線本身差 1m
        -- 以上＝cross-track 反向拉；RETURN 線逐段留 keep 收窄時 target 與線也會分家，
        -- review lane 0906i）；RETURN 無線（hold）才用 target。完成判定（updateReturnSnapshot
        -- 的 dev）仍對 target，剛 commit 時 lineLat≈車位不會假完成。其餘走既有側偏剖面期望線。
        local expL = expectedLaneOf(s)
        if (s.dodging or s.returnActive) and finite(lineLat) then
            expL = lineLat
        elseif s.returnActive then
            expL = s.returnLaneTarget
        end
        local latDev = latSigned - expL
        s.diagExpL, s.diagLatDev = expL, latDev
        s.lastLatDev, s.lastHeadingError = latDev, headingError or 0
        s.lastLatSigned = latSigned
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
        -- 軟縫側移中，車身落在常駐線與閃避 lane 之間是「還在跟上」不是偏離：RETURN 進入與對線帽
        -- 共用同一個偏差（E2E crowd 0925h：lane 0.8s 內從 3.0 移到 −0.54、車身落後 2.8m →
        -- RETURN 接手、放掉閃避並把車速壓到 46，直接撞上下一隻）。
        absDev = Drive.laneRampDev(s, Drive.softAlignDev(s, absDev), speedKmh)
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
        s.lastRouteErr = routeErr
        -- 承諾中的 dodge 持有剖面（仲裁 DODGE(committed) > RETURN）：陡剖面的追蹤
        -- 誤差本身就會超過 available，RETURN 在此進入＝殺掉承諾→同輪 replan 全滅
        -- →blocked（2026-09-04 s051 st404.7：offL 2.00 爬 4 秒被 RETURN 釋放、5 秒後
        -- StopStuck）。繞行中門檻抬到 RETURN_DODGE_DEV：掃掠已驗承諾線兩側 need 淨空，
        -- 一個車道寬內的偏差是剖面還在收斂；超過＝真甩出（harness (b) 的 +6m 草地）
        -- 才放棄承諾交 RETURN。
        local enterDev = s.dodging and TUNE.RETURN_DODGE_DEV or available
        if not s.returnActive and absDev > enterDev
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
                    s.lastSNow + TUNE.RETURN_CORNER_M) == nil
                -- 回線帶上有殭屍（1002c）：不進 RETURN，讓位給軟縫從車身位置接手（Drive.returnYieldZombies）
                and not Drive.returnYieldZombies(s, playerNum, latSigned, speedKmh) then
            -- pending＝unsafe crawl（≤RETURN_UNSAFE_CAP、沿當下 lane 直行），不是 hold：
            -- 舊制進入即 hold→WAIT→forceBrake，等下一輪快照 commit 再起步，每次進
            -- RETURN 都付一次「煞到 1 km/h」（s046 彎中 14.5→0.6 km/h）。回線走不走
            -- 得了由快照決定（commit／holdUnsafeReturn），這 ≤300ms 窗由 contact
            -- 探測與一般體系照管。
            s.returnActive, s.returnUnsafe, s.returnHold = true, true, false
            s.returnStartS, s.returnEndS = s.lastSNow, s.lastSNow
            -- 目標 lane 過該段路面餘裕（弧內側吃不下 1.5 就回 0.36），否則回線
            -- 永遠到不了目標、只能靠 stall 釋放。
            s.returnLaneStart, s.returnLaneTarget = latSigned,
                MDADFollower.laneBiasAt(s.profile, laneBiasOf(s), segI, s.lastSNow)
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
        -- 調頭接手＝RETURN 結束（見 Drive.returnYieldRotate；hold 中被甩成調頭姿態的互鎖）
        if s.returnActive and s.fstate.rotating == true then Drive.returnYieldRotate(s, playerNum, now) end

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
            s.sensor.frameMs = s.frameMs
            s.sensor.wideReq = Drive.wideScanWanted(s, speedKmh)
            -- 寬帶級：承諾中的寬帶繞行沿用承諾那一級（守護輪要看得到整條承諾線），停點判堵用本次嘗試升到的級（Drive.wideJudge）
            s.sensor.wideLevelReq = (s.dodging and s.dodgeWide and s.dodgeWideLevel) or Drive.wideLevelOf(s)
            if not s.sensor.scanning and now >= s.sensor.nextMs then
                Drive.updatePerception(s, speedKmh)
            end
            if MDADSensor.step(s.sensor, s.profile, s.lastSNow, vehicle, now, cell) then
                -- 路面對中：每輪完成都校正（與 replan 無關的常態動作）。roadC＝
                -- 路面帶中心相對 nav 線的偏移，EMA 平滑（防單輪雜訊跳行駛線）；
                -- 無樣本（路口外／無路面）衰減回 0——nav 線是唯一剩下的參考。
                -- 合成行駛線走 setLaneBias 單一事實源：follower 前視、Corridor
                -- baseL/prefer、掃掠淨距全部自動吃到。
                -- 寬帶輪（堵住時 ±14m）的路面帶可能含平行道路／停車場：不拿來對中，沿用上一輪的 roadBias／sandBias。
                local rc = s.sensor.roadC
                if s.sensor.wideDone then
                    rc = nil
                elseif rc ~= nil then
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
                if not s.sensor.wideDone then
                    s.sandBias = s.sandBias + (Drive.keepRightTarget(s) - s.sandBias) * TUNE.ROAD_EMA
                end
                local nb = s.sandBias + s.roadBias
                if nb > TUNE.BIAS_MAX then nb = TUNE.BIAS_MAX
                elseif nb < -TUNE.BIAS_MAX then nb = -TUNE.BIAS_MAX end
                -- 枚舉的邊界判定跟著抖。承諾釋放後恢復跟隨。
                s.residentBias = nb -- 常駐行駛線（鏈式停留解鏈判定用）
                Drive.mergeRelay(s, now) -- 伺服器轉送的遠方行進車接到本輪快照尾端（MP）
                Drive.trafficScan(s, now, speedKmh) -- 會車／跟車：本輪快照判讀（速度帽每幀在下方套）
                if s.dodging or s.returnActive or s.laneChained then
                    nb = laneBiasOf(s)
                    s.zombieLaneCap = -1
                    s.zombieAvoidUntilS = nil
                    s.softGentleS = nil -- 繞行／RETURN／停留持有行駛線時不閃動物，也不套 gentle 帽（停等照判）
                    s.zombiePlanWhy, s.zombieWhy = nil, nil
                    if s.zombieLane ~= nil then
                        s.zombieLaneParked = s.zombieLane -- 重新接手時從這裡起算（zombieLaneOf）
                        s.zombieLane = nil -- 持有權讓給 dodge／RETURN／停留：軟縫釋放（laneBias 由持有者管）
                        diagEvent(s, playerNum, "zombie", { phase = "release", why = "owner", l = nb })
                    end
                    s.trafficLane = nil -- 為對向車的側移同樣讓出持有權（速度帽仍照套）
                    Drive.transitionRelease(s, playerNum, "owner", nb)
                else
                    nb = zombieLaneOf(s, nb, now, playerNum, speedKmh) -- 殭屍軟縫（TUNE.ZOMBIE_LANE_*）
                    nb = Drive.trafficLaneOf(s, nb, now, playerNum) -- 對向車靠右錯開（TUNE.TRAFFIC_*）
                    nb = Drive.transitionHold(s, nb, playerNum, speedKmh) -- 斜切帶有硬物先沿車位直走
                end
                -- 會車側移期間可貼到路緣（離路緣保留 TRAFFIC_EDGE_KEEP_M，平常 LANE_BIAS_KEEP 0.6）：
                -- 5m 路兩車各留 0.6 時中心只到 ±0.77，兩台轎車根本錯不開，只能讓車——而同步範圍只有
                -- ~70m，兩台 100 km/h 對開 1.2 秒內停不下來（E2E 窄路對撞）。硬物照舊由 trafficScan 收窄。
                -- 鏈上 lane 是停留承諾掃掠驗過的絕對 lane（承諾線本來就傳 keep 0）：常駐的 keep 0.6 會把它夾回障礙側，
                -- 車被拉回去、重錨一再觸發（1004a 正式服 0.18.2 dandankk clip-30，6m 路停留 2.25 → 期望線 1.12 → 停死交還）。
                -- 規劃端的擋線基準（fillHardBase／nearestLineBlocker）鏈著時同樣傳 keep 0。
                -- 軟縫貼路緣（s.zombieKeep0，1005 soft）同理 keep 0；會車同時設時取小（Drive.laneKeepOf）。
                s.fstate.laneKeep = Drive.laneKeepOf(s)
                MDADFollower.setLaneBias(s.fstate, nb)
                Drive.clearLaneProof(s)
                Drive.softStopScan(s, speedKmh) -- 動物／玩家停等：選定的行駛線上還有沒有閃不開的目標（每幀 Drive.softStopCap 用）
                -- RETURN 活躍時掃描帶錨在「現位置↔目標 lane」的中點，不得跟著 fstate
                -- 的 laneBias 走（2026-09-02 session-006 定罪：commit 把 laneBias 設成
                -- 目標 1.5 → 下一輪帶心 +1.5，回線起點 −4 落在帶外 → 守護判 band/
                -- unloaded → hold（帶心回 −1.25）→ 再 commit → 週期 3 輪的 commit↔hold
                -- 震盪，每次 hold 都把速度命令歸零，車 31 秒原地 0 km/h、路線畫面一直跳）。
                -- updateReturnSnapshot 的 commit／hold 分支各自寫的也是這個中點；
                -- 守護通過提早 return 的那條路徑沒寫，帶心就被這行的 nb 帶走。
                if s.returnActive then
                    s.sensor.scanBias = returnScanBias(s, latSigned)
                elseif finite(s.stayLanePending) then
                    s.sensor.scanBias = s.stayLanePending -- 停留進入段：帶心先跟停留 lane
                else
                    s.sensor.scanBias = nb -- 掃描帶跟隨行駛線（下一輪 beginRound 鎖定）
                end
                -- Current-body OBB is a safety OR-gate in front of the existing planner.
                -- It consumes this completed immutable snapshot even when sig is unchanged.
                footprintSnapshot(s, vehicle, playerNum, fwd, heading, vx, vy, latSigned)
                updateReturnSnapshot(s, vehicle, playerNum, latSigned)
                if s.sensor.sig ~= s.planSig or s.clearStreak > 0 or s.dodging then
                    s.planSig = s.sensor.sig
                    -- replan 牆鐘（現場分佈，歸因用 GameProfiler）：前後各讀一次時鐘，最多每 REPLAN_CLOCK_MS 量一次；
                    -- 掃掠數 sweepLine 自己累加。結果進樣本（collectPhys 的 replan*）與 replan 內的 blocked／dodge 事件。
                    s.sweepCount = 0
                    s.replanT0 = now - (s.replanClockAt or -1e12) >= TUNE.REPLAN_CLOCK_MS and getTimestampMs() or nil
                    replan(s, vehicle, playerNum)
                    if s.replanT0 then
                        s.replanClockAt = now
                        s.replanWallMs, s.replanSweeps, s.replanHn = getTimestampMs() - s.replanT0, s.sweepCount, s.sensor.hardN
                        s.replanWallFresh, s.replanT0 = true, nil
                    end
                    if s.currentBlocked then s.planMode = "current-blocked" end
                end
                -- 寬帶判過一輪：最寬那級判完（不論結果）這次脫困嘗試的倒車／改道才可以動；仍堵且還能加寬就先升級（Drive.wideJudge）
                if s.sensor.wideDone then Drive.wideJudge(s, playerNum) end
                Drive.gateNote(s, playerNum, vehicle, speedKmh) -- Knox Pass 大門：gate 事件與不會開的提示（Sensor gateCell／gateNoCell）
                -- 承諾只覆蓋到offD；已知下一台在窗外也要先留出停車與重新選縫的距離。
                s.dodgeNextStopS = nil
                s.dodgeNextX, s.dodgeNextY, s.dodgeNextR = nil, nil, nil
                if s.dodging and finite(s.fstate.offD) then
                    local nextBlock = nearestLineBlocker(s, s.sensor, s.fstate.offD)
                    if nextBlock then
                        s.dodgeNextStopS = s.sensor.hardS[nextBlock]
                        s.dodgeNextX, s.dodgeNextY, s.dodgeNextR =
                            s.sensor.hardX[nextBlock], s.sensor.hardY[nextBlock], s.sensor.hardR[nextBlock]
                    end
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
                s.softLaneRecheck = nil
                -- 一般玩家軌跡每輪更新常駐點列；debugOn 只控制紅／綠／橙 markers。
                -- LineDrawer 每 tick 畫連續線，幾何仍只在 250ms 輪完成時重算。
                if type(MDADOverlay) == "table" then
                    MDADOverlay.update(playerNum, s, vehicle, cell, s.overlayOn)
                end
            elseif s.softLaneRecheck and s.sensor.ready then
                -- 政策關閉當幀改了軟目標：以現有完整快照重驗新線，不沿用舊線證明。
                buildSnapshotProof(s, segI, math.min(s.profile.length, visibleEndS(s.sensor, s.lastSNow)))
                s.softLaneRecheck = nil
            end
            -- 速度檔位：全部是疊在剖面上的 min，cap<0＝本幀沒有任何檔位介入
            local cap = -1
            local capReason = nil
            s.dodgeNextCap, s.dodgeNextDist = -1, nil
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
                    diagEvent(s, playerNum, "dodge", { phase = "release", why = "done",
                        rs = s.lastSNow, l = s.lastLatSigned, offL = s.residentBias })
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
                    local decel = s.safeBrake
                    if not finite(decel) or decel <= 0 then decel = 0.6
                    else decel = decel * TUNE.APPROACH_BRAKE_FRAC end
                    if finite(fsA) and s.lastSNow < fsA then
                        applied = MDADDynamics.approachCapKmh(
                            fsA - s.lastSNow - s.vehicleProfile.halfL,
                            dcap, 0.5, decel)
                    end
                    local entryCap = Drive.dodgeEnvelopeCap(s, speedKmh, now)
                    if entryCap ~= nil then applied = entryCap end
                    -- 保持段（entry 已過、還沒到 c）：套 dodgeHoldCap（平行行駛的 clearance），
                    -- 出口過渡的 dcap 由對 offC 的單調 envelope 收到（0907d；理由見 updateDodgeCaps）。
                    -- 減速度用 safeCoast：繞行帽只夾 regulator（斷油滑行）、不進 forceBrake，用煞車
                    -- 減速度反推會在出口前 8.8m 才收油、到 c 仍 ~20 km/h（Codex lane；殭屍 envelope 同理）。
                    local fsC = s.fstate.offC
                    if entryCap == nil and s.dodgeEntryPassed and finite(fsC) and s.lastSNow < fsC
                            and finite(s.dodgeHoldCap) and s.dodgeHoldCap > dcap then
                        local coast = s.safeCoast
                        if not finite(coast) then coast = 0 end
                        local toExit = MDADDynamics.approachCapKmh(
                            fsC - s.lastSNow - s.vehicleProfile.halfL, dcap, 0.5, coast)
                        applied = s.dodgeHoldCap
                        if toExit < applied then applied = toExit end
                    end
                    -- 停留的不可行下一群與承諾線尾外的下一台，共用可實現的滑行煞停包絡。
                    local nextDistance = nil
                    if finite(s.dodgeNextStopS) then
                        nextDistance = 0
                        if finite(s.dodgeNextX) and finite(s.dodgeNextY) and finite(s.dodgeNextR) then
                            local dx, dy = s.dodgeNextX - vx, s.dodgeNextY - vy
                            nextDistance = sqrt(dx * dx + dy * dy) - s.bodyReach - s.dodgeNextR
                        end
                    end
                    if s.dodgeStay and finite(s.stayNextB) then
                        local distance = s.stayNextB - s.lastSNow - s.bodyReach
                        if nextDistance == nil or distance < nextDistance then nextDistance = distance end
                    end
                    if nextDistance ~= nil then
                        local coast = finite(s.safeCoast) and math.max(0, s.safeCoast) or 0
                        local capN = MDADDynamics.approachCapKmh(
                            nextDistance, 0, 0.5, coast)
                        s.dodgeNextCap, s.dodgeNextDist = capN, nextDistance
                        if capN < applied then applied = capN end
                    end
                    applied = Drive.dodgeAlignCap(s, applied, speedKmh) -- 未對正不加速（TUNE.DODGE_ALIGN_*）
                    s.dodgeApproachCap = applied
                    if cap < 0 or applied < cap then
                        cap = applied
                        capReason = "dodge"
                    end
                end
            end
            -- 調頭／回線有自己的行駛線與安全帽；丟棄一般路線候選留下的延後帽。
            if s.fstate.rotating or s.returnActive then
                s.dodgeHandoffHold, s.dodgeDeferCap = false, -1
            end
            if not s.dodging and finite(s.dodgeDeferCap) and s.dodgeDeferCap >= 0
                    and (cap < 0 or s.dodgeDeferCap < cap) then
                cap = s.dodgeDeferCap
                capReason = "dodge-defer"
            end
            -- 殭屍軟縫的縱向配合（zombieLaneOf 每輪算；持有權讓位即清）
            if not s.dodging and finite(s.zombieLaneCap) and s.zombieLaneCap >= 0
                    and (cap < 0 or s.zombieLaneCap < cap) then
                cap = s.zombieLaneCap
                capReason = "zombie-lane"
            end
            -- 殭屍／屍體減速：三態政策×玩家偏好已在 refreshPolicies 合成快取，
            -- 每幀只讀 boolean（250ms 刷新；切檔／切偏好即時重算）
            -- 0907b：檔位速對**最近一隻**做 approach envelope（同繞行縫的單調式）——舊制
            -- 帶內有殭屍即整帶平帽（48-110m 外一隻就把 60 壓到 35，session-057/058 使用者
            -- 「閃殭屍慢」）；現在遠時不壓、到牠車頭前 ZOMBIE_APPROACH_LEAD_M 才降到檔位速，
            -- 帶內平均分布的殭屍群自然退化成整帶平帽（最近的永遠在眼前）。
            -- 減速度用 s.safeCoast（斷油滑行；brisk prior 1.2、學習器只降不升、學到 0 就照 0＝
            -- approachCapKmh 退回檔位速平帽，不得補成假能力）——殭屍檔只夾 regulator、不進
            -- forceBrake（本段下方 hardBreach 只認 curve／visibility），用 safeBrake×0.7 反推會晚
            -- 收油、到殭屍前還剩 28 km/h（Codex lane 2026-09-07）；繞行縫的 offA envelope 仍用
            -- safeBrake×0.7（0902 s064 裁定，縫本身另有 contact 兜底）。
            local zn = s.sensor.zombieN
            -- 軟縫已處理（有縫閃過／正在貼著通過／牠們不在行駛線上）就不再為數量減速：閃得過就不減速
            -- （使用者裁定 2026-09-25；E2E zombie-sp 基準單隻殭屍 70→35 全來自這條）。軟縫找不到縫、
            -- 被硬物擋、閃避關閉或殭屍群溢出時照舊減速，推過去比硬閃安全。側移時間不夠另有 zombieLaneCap。
            local softHandled = s.zombieWhy == "gap" or s.zombieWhy == "hold" or s.zombieWhy == "clear"
            if zn and zn > 0 and s.zombieSlow and not softHandled then
                local zcap = TUNE.ZOMBIE_CAP_1
                if zn >= 8 then zcap = TUNE.ZOMBIE_CAP_8
                elseif zn >= 4 then zcap = TUNE.ZOMBIE_CAP_4 end
                zcap = Drive.approachSoftCap(s, s.sensor.zombieNearS, zcap)
                if cap < 0 or zcap < cap then
                    cap = zcap
                    capReason = "zombie"
                end
            end
            local cn = s.sensor.corpseN
            if cn and cn > 0 and s.corpseSlow and not softHandled then
                local ccap = Drive.approachSoftCap(s, s.sensor.corpseNearS, TUNE.CORPSE_CAP)
                if cap < 0 or ccap < cap then cap, capReason = ccap, "corpse" end
            end
            -- 會車／跟車（Drive.trafficScan／trafficCap）：前車照相對速度留距跟車、停著才停等；
            -- 對向車只在會壓到常駐線時配合側移減速，右邊讓不開才停等讓車。MP 半更新的假動靜止車
            -- 由 Sensor 的跨輪位移判定改成硬障礙，不再靠這裡的分級煞停兜底。
            s.followHold = false
            do
                local tcap, treason, thold = Drive.trafficCap(s, now, speedKmh)
                s.trafficCapKmh = tcap -- Drive.visAssistForce 的會車帳（−1＝無）
                if thold then s.followHold = true end -- 合法停等（卡死豁免＋獨立超時）
                if tcap >= 0 and (cap < 0 or tcap < cap) then
                    cap = tcap
                    capReason = treason
                end
            end
            -- 只在減速名單的動物（gentle）成為威脅：先降到 ANIMAL_GENTLE_KMH 再繞（Drive.softGentleCap）
            cap, capReason = Drive.softGentleCap(s, playerNum, cap, capReason)
            -- 動物／其他玩家擋在選定的行駛線上（Drive.softStopCap）：接近包絡停在前方、合法停等（followHold）；
            -- 動物等待到期後爬過、玩家等到停等預算交還
            cap, capReason = Drive.softStopCap(s, now, speedKmh, playerNum, cap, capReason)
            -- 軟障礙（可推家具／HitByCar 雜物）：輾得過但要先減速——不減速輾過的
            -- 體感就是「撞到東西」（2026-08-28 實機路口擦撞回報的嫌疑之一）
            local sn = s.sensor.softN
            if sn and sn > 0 then
                local scap = Drive.approachSoftCap(s, s.sensor.softNearS, TUNE.SOFT_CAP)
                if cap < 0 or scap < cap then cap, capReason = scap, "soft" end
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
                -- buildCoast 現為煞車系合成減速度（minBrake×0.7 與斷油＋剖面輔助取大，見 proof 端）：
                -- runtime 比對基準同一個式子——EWMA 煞車或斷油真的掉了才縮 envelope（1002d 起輔助進了
                -- 基準，只比 safeBrake×0.7 會把輕車的包絡無故縮兩成）。
                local runDecel = finite(s.safeBrake) and s.safeBrake * 0.7 or -1
                if runDecel >= 0 then
                    runDecel = math.max(runDecel, (finite(s.safeCoast) and s.safeCoast > 0 and s.safeCoast or 0)
                        + (s.profile and s.profile.coastAssist or 0))
                end
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
            if not (finite(currentS) and finite(lineS0) and finite(lineEnd)) then
                laneEnvelopeValid, fullValid = false, false
                s.invalid, s.stateError, s.dynamicsFault =
                    true, "lane-envelope", true
            elseif currentS > lineEnd + 1e-6 or lineEnd <= lineS0 or s.verifyLineN < 2 then
                -- 證明線已被越過或退化成一格（投影跳段／讓位後離線／未載入前緣貼臉）＝快照過期，不是
                -- 內部錯誤：丟掉證明、這幀走未證明上限，下一輪掃描重建（0928a FuFu/clip-01：讓位恢復時
                -- 離線 98m，下一幀判 lane-envelope 當成車輛不支援交還）。
                laneEnvelopeValid = false
                Drive.clearLaneProof(s)
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
        local stopEnd = s.lastSNow
        local visibilityCap = s.sensor and 0 or 15
        s.visibilityHardKmh = visibilityCap -- 尚未有快照時不得沿用上一幀的高門檻。
        if s.sensor and s.sensor.ready and finite(s.sensor.stamp) then
            sensorReady = true
            local age = now - s.sensor.stamp
            fresh = age >= 0 and age <= MDADDynamics.SNAPSHOT_FRESH_MS
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
            -- 同一可視前綴分兩個速度帳：巡航先收油（必要時中線外力補減速），緊急停距不足才
            -- 動用一秒硬煞。時間模型與定罪理由見 Drive.visibilityCaps。
            local cruiseBrake
            visibilityCap, cruiseBrake = Drive.visibilityCaps(s, now, visibleEnd, minBrakeVisible)
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
            -- 煞停視界按「實際准開的速度」算（fullTarget 已被 visibilityCap 夾過），同巡航煞車帳；
            -- 舊制拿未夾的 fullTarget＋舒適煞車算，可視一綁速 brakeLoaded 就恆假 → gate
            -- visibility → ungated 0.9×／80 上限疊在 visibility 上（0924b：MAX 檔被壓在 80 以下）。
            local stopKmh = fullTarget < visibilityCap and fullTarget or visibilityCap
            stopEnd = s.lastSNow + MDADDynamics.stoppingDistance(
                stopKmh / 3.6, TUNE.VIS_TAU, cruiseBrake, s.vehicleProfile.halfL)
            if stopEnd > s.profile.length then stopEnd = s.profile.length end
            brakeLoaded = finite(minBrakeVisible) and minBrakeVisible > 0
                and visibleEnd + 1e-6 >= stopEnd -- 可視帽本身就解到等號，留浮點容忍
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
                or s.dodging or s.returnActive) and not s.currentBlocked
        else
            s.visFrontRef = nil -- 快照重置（cutover／regime）後前緣停滯計時從新快照重來
        end
        if not finite(visibilityCap) or visibilityCap < 0 then
            visibilityCap = 0
            s.invalid, s.stateError, s.dynamicsFault = true, "visibility", true
        end
        s.visibilityCap = visibilityCap
        -- 繼承調頭／終點的合法爬行地板；壞值退一般界限，不留下失效的高紅線。
        if not finite(s.visibilityHardKmh) or s.visibilityHardKmh < visibilityCap then
            s.visibilityHardKmh = visibilityCap
        end
        Drive.updateLowFps(s, now, targetSpeed > visibilityCap + 0.5)
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
        absDev = Drive.laneRampDev(s, Drive.softAlignDev(s, absDev), speedKmh)
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
        -- 證明線在未載入前緣前一格（OV_STEP）就截斷（buildSnapshotProof loadedEnd），可視帽卻解到前緣
        -- 等號：可視帽一綁速，stopEnd 恰落在前緣、證明差 1–2m 永遠蓋不到 → nearUnknown → 18 km/h
        -- （2026-09-25 MAX 檔快車＋拖車 E2E：72m 載入前緣、可視帽 110 時全程 18；玩家回報「沒東西卻
        -- 一直 18」）。前緣後方本來就由可視帽管，證明只需蓋到前緣前的取樣格。
        local pathVerified = s.curveVerifiedUntilS
            + (s.verifyLineReason == "unloaded" and 2 * MDADFollower.OV_STEP or 0) >= stopEnd
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
            and not s.dodging and not s.returnActive and not s.blocked
        s.proofSweepCap = nil -- 本幀 gate 判 sweep 才由 Drive.proofSweepCap 寫（visAssistForce 的 "proof" 帳）
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
            -- fullTarget 由 lane envelope 裁決時 reason 留 curve-coast（2026-09-08 s048：
            -- 對準的那幀 fullGate 開、reason 被清成 nil → min-exec 的 curve-coast 分支
            -- 不認、GO 意圖 target 0 釘死 37 秒；telemetry capReason 空也定不了罪）。
            if targetSpeed >= fullTarget then
                targetSpeed = fullTarget
                s.lastCapReason = (laneEnvelopeValid and fullTarget == s.laneCurveEnvelope)
                    and "curve-coast" or nil
            end
        else
            local alignCap = MDADDynamics.alignmentCapKmh(
                fullTarget, headingError, absDev, latTol, aligned)
            local ungated, gateReason = MDADDynamics.ungatedCapKmh(
                fullTarget, s.gateReason, alignCap, s.profile.styleName == "brisk")
            if gateReason == "sweep" then ungated = Drive.proofSweepCap(s, ungated, fullTarget) end
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

        -- 起步近物限速（TUNE.START_GUARD_*；調頭／回線／繞行各有自己的淨距體系，不疊）
        s.startNearCap = nil
        if s.startGuard and s.fstate.rotating ~= true and not s.returnActive and not s.dodging then
            targetSpeed = Drive.startGuardApply(s, targetSpeed, now, vx, vy, latSigned, speedKmh)
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
            and Drive.blockedAtStop(s, vx, vy)
        if getDebug() and s.blocked and s.lastBlockedStopDbg ~= blockedStop then
            s.lastBlockedStopDbg = blockedStop -- 只印翻轉（每幀印會把 replan 鏈洗出捲軸）
            print(string.format(
                "%spn=%d blockedStop=%s bs=%.1f rs=%.1f hit=%s,%s v=%.1f,%.1f rot=%s ret=%s",
                LOG, playerNum, tostring(blockedStop), s.blockS or -1,
                s.lastSNow or -1, tostring(s.blockHitX), tostring(s.blockHitY),
                vx, vy, tostring(s.fstate.rotating), tostring(s.returnActive)))
        end
        if blockedStop then
            targetSpeed, s.lastCapReason = 0, "blocked"
        end
        -- 寬帶只在「開到判堵停點」之後才武裝（Drive.wideScanWanted）：起步時車速 0、群還在 28m 外也是
        -- 「blocked＋停著」，舊條件直接寬帶＝一般帶還沒靠近重判就從路外繞（E2E arrive 0929p：偏離後重算
        -- 成 600m 路線、逾時）。武裝點＝這裡的弧長：倒車退回它之後仍停著寬帶重判（Drive.blockedAtStop）。
        -- 承諾中的繞行被守護判死（guard-blocked）不武裝：線是固定的，寬帶只會改變守護輪的點雲。
        -- 交接停住也算開到停點（1004e）：舊線交出、下一群沒有候選時 dodgeHandoffHold 把車停在群前，可能還在停止線外
        -- （E2E dixie9350：停在 13.7m 外、永遠到不了 10m 停止線，寬帶沒武裝，乾等 10 秒改道繞 492m）；停住才武裝，
        -- 帶速武裝會在煞停途中開過武裝點被 Drive.wideScanWanted 解除。
        if (blockedStop or (s.dodgeHandoffHold and s.blocked and speedKmh < TUNE.WIDE_SCAN_KMH
                    and speedKmh > -TUNE.WIDE_SCAN_KMH))
                and not s.wideArmed and not s.dodging then
            s.wideArmed, s.wideArmedS = true, s.lastSNow
            s.wideArmedX, s.wideArmedY = s.blockHitX, s.blockHitY
        end
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
            s.fstate.rotating == true, Drive.waitHoldArg(s, blockedStop),
            s.followHold == true, s.returnHold == true,
            s.visibilityCap, s.dodgeCrawl == true or s.softCrawl == true
                or (s.dodging and (s.dodgeEnvN or 0) >= 2
                    and finite(s.dodgeApproachCap) and s.dodgeApproachCap < MDADDynamics.MIN_EXEC_KMH),
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
            s.minExecFrom = s.lastCapReason -- 被抬前的理由（狀態列 cap=min-exec(<from>)；否則定不了罪）
            targetSpeed = MDADDynamics.MIN_EXEC_KMH
            s.lastCapReason = "min-exec"
        elseif s.intentShadow == "GO" and targetSpeed == 0
                and not (finite(remaining)
                    and remaining <= MDADFollower.ARRIVE_M + 3) then
            -- s048 定罪（2026-09-01 教堂路口）：折點 verifyEnvelope 格＝0 是
            -- κ→∞ 的公式極限假象，GO 下 curve-coast 壓 0 ＝「cap 要速度才放寬
            -- （EWMA 資格 v≥2.2）、速度要 cap>0」的起步死鎖，99 幀 tgt=0 釘死。
            -- 到站減速（nearArrive）不抬；彎道真超速由 curve hard breach 煞車
            -- 紅線照常兜底——這是把不可執行的假 0 抬到可執行下限，非安全豁免。
            -- 不再限定 reason（2026-09-08 s048：同一個 0 走 fullGate 路徑 reason 是 nil）：
            -- GO 已保證無停等訴求／無接觸／非調頭非恢復／visibility ≥ MIN_EXEC，任何
            -- 0 都是軟 cap 疊出的假 0；progress 監督與停等預算都不看 GO+0，不抬＝永久掛著。
            s.minExecFrom = s.lastCapReason
            targetSpeed = MDADDynamics.MIN_EXEC_KMH
            s.lastCapReason = "min-exec"
        end

        local avProgress = speedKmh
        if avProgress < 0 then avProgress = -avProgress end
        Drive.gateShut(s, playerNum, vehicle, now, speedKmh, blockedStop and avProgress < 1) -- Knox Pass 會開的門一直不開
        if s.returnCapacityFault and s.returnHold and avProgress < 1 then
            postAction = "return-fault"
        end
        -- 前方區域未載入的引擎煞車（TUNE.AREA_WAIT_MAX_MS）：等待不是卡住；等滿上限才交還
        if Drive.areaWait(s, vehicle, now, targetSpeed, speedKmh) and postAction == nil then
            postAction = "area"
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
        -- 恢復額度用盡後的 CRAWL／STOP 也計預算（2026-09-04 s058/s059：attempt-limit
        -- 每 2.5 秒一次、車 0 km/h 100 秒不交還——576 CRAWL 與 152 contact STOP 分段交替；
        -- 只計 CRAWL 會被 STOP 幀反覆清 waitTick。CRAWL 暫停計時是給「真的在爬」用的，
        -- 三次倒車都沒解掉的 episode 再爬／再撞也不會有結果）。
        -- 審查補刀：以「未解決 episode」為準而非倒車次數——後方 hard 時 startRecovery
        -- 一律 soft-fail、attempts 永遠 0，只看次數同樣永久掛著。真進度（沿線 10m）
        -- 由 waitProgressed 歸零，正常爬行不受影響。
        -- 只計「爬不動」的幀（2026-09-04 s@164561 定罪：倒車後 6 km/h 貼縫承諾正常前進、
        -- lat 穩定、無 contact，卻因 blocked＋unstick 已累計 9s、10m 真進度還沒到就 15s
        -- 交還——「只嘗試一次就中途停」）。真的在爬（avProgress ≥ 1 km/h）不計時。
        -- ROTATE 也計（2026-09-08 s030：調頭＋blocked 額度用盡後 ROTATE 幀空轉 20 秒
        -- 不交還——只有 WAIT／RECOVER 計時，ROTATE 意圖永遠不進 15s 保險）；真的在轉
        -- 由 waitProgressed 的航向收斂（rotating 分支）歸零，原地空轉才累計。
        -- 倒車額度用盡後的 GO 也計（1001g，E2E rc44 0007：繞行承諾中 min-exec 8 km/h、車卡在路肩 0 km/h，
        -- attempt-limit softFail 每 3.5 秒回 follow 一次、5 分鐘不交還）；額度沒用完的 GO 是起步加速，不計。
        -- 最後一次後方探測不通的 GO 同樣計（1004g，E2E k1004g nightrain：路上 24 台車，改道後車被前後夾住、
        -- GO 8 km/h 不動，rear-blocked softFail 不扣額度＝次數永遠 0，3 分鐘不交還——同上面「審查補刀」）。
        -- 只有動物停等的 WAIT 不計（動物另外計時，Drive.softStopCap／Drive.animalOnlyWait；1005 使用者裁定）
        if (s.intentShadow == "WAIT" and not Drive.animalOnlyWait(s, blockedStop)) or s.intentShadow == "RECOVER"
                or (s.intentShadow == "ROTATE" and avProgress < 1)
                or (s.episodeActive and avProgress < 1 and not s.areaWaitActive
                    and (s.intentShadow == "CRAWL" or s.intentShadow == "STOP"
                        or (s.intentShadow == "GO" and (s.episodeAttempts >= UNSTICK_MAX
                            or s.rearStatus ~= "clear" and s.rearStatus ~= "unknown")))) then
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
        -- ROTATE 幀不清 blockRetryDone（2026-09-08 s030）：額度用盡的 softFail 靠它擋
        -- 重打，ROTATE 幀每幀清掉＝每幀 requestRecover→attempt-limit 事件洪水（4889 筆
        -- ／20 秒、2MiB 滿檔），車 0 km/h 掛到手動停。
        if s.intentShadow ~= "WAIT" and s.intentShadow ~= "ROTATE" then
            s.blockRetryDone = false
        end
        -- 調頭需求＋前方堵死的判準不能吊在 legalWait 上（階段 2 主體 3）：
        -- legalWait 併入意圖後 ROTATE 會被排除，而 err>90° 正是這條 branch 的
        -- 主場景。改讀「非執行前進的意圖」＝WAIT 或 ROTATE。
        -- 只在 blocked 錨點真的在旋轉空間內才倒車（2026-09-08 s030 定罪：目標在後、
        -- 路線前方 20m 有車群，blocked 錨在**車尾方向** 20m 外；舊制一律倒車＝朝障礙
        -- 退 3 次共 14m、離它 6m 才用盡額度，從沒真的調頭）。遠處的 blocked 是調頭
        -- 完成後才面對的事（blockedStop 對 rotating 早已豁免），旋轉安全由 probeAround
        -- 管；近距（車心到錨 ≤ probeR＋1＝旋轉掃掠圈）才需要退出空間。
        if s.blocked and not s.banFromRecovery and avProgress < 1
                and s.intentShadow == "ROTATE" and not s.blockRetryDone
                and MDADDynamics.blockedNear(s.blockS, s.lastSNow, s.probeR + 1,
                    vx, vy, s.blockHitX, s.blockHitY) then
            -- 調頭需求＋前方堵死（2026-09-01 實機圖 2：車頭反向、前方柵欄
            -- blocked→乾等 20s 紅字毫無意義——障礙在前、去向在後）。直接
            -- 走倒車脫困創造旋轉空間：rear swept-strip clear 才退（fail-
            -- closed 照舊），4m＋settle 重掃後 rotate probe 空間自然變大。
            requestRecover(s, "uturn-blocked")
        end
        if Drive.rotateStall(s, now, targetSpeed, avProgress) and not s.blockRetryDone then
            requestRecover(s, "rotate-stall")
        end
        if Drive.startNearStall(s, now, avProgress) and not s.blockRetryDone then
            requestRecover(s, "start-near")
        end
        -- 自動改道（ESC 選項，0928m 起預設開）：blocked-retry 之後仍在停等、累計超過
        -- AUTO_DETOUR_MS 才要替代路線；一個停等 episode 只試一次，失敗＝沒替代路，
        -- 剩下交給 WAIT_TIMEOUT 紅字。玩家按 HUD「改道」鈕走同一條 Drive.requestDetour。
        -- **排在 blocked-retry 之前**（2026-09-02 實機：自動改道勾了永遠不觸發）：
        -- 倒車脫困後車開回原地再被堵，非 WAIT 幀已把 blockRetryDone 清掉，同一幀
        -- 先判的 blocked-retry 又 requestRecover 設 recoverWhy → 改道的
        -- recoverWhy==nil 永遠假；unstick 三次直接 StopStuck。累計 ≥10s 時改道優先，
        -- 本幀不再倒車。harness (c5c) 第一版用後牆讓倒車 soft fail 才綠＝假綠。
        -- 觸發時機：累計 ≥ AUTO_DETOUR_MS，或「已倒車重掃過一次（episodeAttempts≥1）
        -- 又被同一處堵住」——倒車沒解掉的堵，第二次倒車也不會解，先問替代路線。
        -- 寬帶武裝時兩者都要等這次嘗試的寬帶重判（wideJudged＝本次 attempt）：倒車退出來的跑道
        -- 只有寬帶重判用得到；舊制等待額度早已累滿，倒車一結束下一幀就再倒（E2E 0929u 連倒三次、
        -- 中間一輪寬帶都沒跑就 StopStuck）。
        local autoDetourNow = s.blocked and not s.detourTried and s.recoverWhy == nil
            and postAction == nil and s.intentShadow == "WAIT"
            and (not s.wideArmed or s.wideJudged == s.episodeAttempts)
            and (s.waitAccumMs >= TUNE.AUTO_DETOUR_MS
                or (s.episodeAttempts >= 1 and s.waitAccumMs >= TUNE.BLOCK_RETRY_MS))
            and type(MDAD.HUD) == "table" and type(MDAD.HUD.autoDetour) == "function"
            and MDAD.HUD.autoDetour() == true
            and not Drive.runwayRetryFirst(s)
        if autoDetourNow then
            s.detourTried = true
            Drive.requestDetour(playerNum, false, "auto")
        elseif s.blocked and not s.banFromRecovery and s.recoverWhy == nil
                and postAction == nil
                and not s.blockRetryDone
                and s.intentShadow == "WAIT"
                and (not s.wideArmed or s.wideJudged == s.episodeAttempts)
                -- 跑道不夠（steep 差額）是靜態幾何，不會等 5 秒就變好：直接倒車
                -- （2026-09-04 st178,066「靠近又煞停、不必重複掃描」：A 尾到 B 縫差 4m 跑道，
                -- 乾等 5 秒才退）
                and (s.waitAccumMs >= TUNE.BLOCK_RETRY_MS
                    or (finite(s.blockSteepM) and s.blockSteepM > 0 and s.waitAccumMs >= TUNE.BLOCK_STEEP_RETRY_MS)) then
            -- 2026-09-01 使用者裁定：blocked 不乾等 15 秒——累計 5 秒仍無縫就
            -- 主動倒退 4m 重掃（換視角＝掃描帶錨移動、縫的量化相位改變，
            -- 常能解鎖）。rear swept-strip clear 才退（fail-closed 照舊）；
            -- 倒不了（soft fail）回到合法停等，只試一次防洗版。
            requestRecover(s, "blocked-retry")
        end
        if s.waitAccumMs >= TUNE.WAIT_TIMEOUT_MS and not Drive.wideJudgePending(s) then postAction = "wait" end
        if s.softGiveUp and postAction == nil then postAction = "animal" end -- 動物爬行到上限仍擋著

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
            elseif s.progressState == "disarmed"
                    -- 恢復需求沒經 dispatch 就被撤銷（episode 前進 10m 重臂／讓位清掉 recoverWhy）：suspect／recover
                    -- 不能留著——full gate 的 progress 條件會一直關（0928c E2E rc1 0007：卡頓誤判 suspect、車照開
                    -- 47 km/h，10m 後重臂清掉需求，suspect 掛了 57 秒）。從現在重新看門。
                    or s.progressState == "suspect" or s.progressState == "recover" then
                s.progressState = "watch"
                s.progressSince = now
                s.progressX, s.progressY = vx, vy
                s.progressS, s.progressH = s.lastSNow, heading
            elseif s.progressState == "watch" or s.progressState == "verify" then
                if s.progressState == "watch" and not s.currentBlocked then
                    s.progressSince = s.progressSince + Drive.progressPauseMs(s, vehicle, now, speedKmh)
                end
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

        s.blockedApproachCap = nil
        if s.blocked and not reached and not s.returnActive and not blockedStop then
            -- 接近判堵停止線只套包絡（1004e，使用者「遇到障礙不要停留太久」）：舊制另把目標平壓 BLOCK_APPROACH_KMH，
            -- 遠處判堵（E2E dixie9160：68m 外）就以 20 km/h 爬 11 秒才到停止線。包絡在停止線收到同一個值，減速由
            -- Drive.visAssistForce 的 blocked 帳補、越線照舊 blocked-approach 煞車；判堵時 fullGate 已關，加速輔助不推。
            -- 調頭中錨在車尾方向，不為它減速、照舊平壓。
            if s.fstate.rotating ~= true then s.blockedApproachCap = Drive.blockedApproachCap(s, vx, vy) end
            if targetSpeed > (s.blockedApproachCap or TUNE.BLOCK_APPROACH_KMH) then
                targetSpeed, s.lastCapReason = s.blockedApproachCap or TUNE.BLOCK_APPROACH_KMH, "blocked"
            end
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
            -- 動物／玩家停等（Drive.softStopCap）保留自己的理由（fbw／HUD 看得出是在等誰）；不鎖輪規則同會車停等
            hardCapV, hardClampReason, okHard = MDADDynamics.lowerHardCap(hardCapV, hardClampReason, 0,
                (s.lastSensorReason == "animal-stop" or s.lastSensorReason == "player-stop") and s.lastSensorReason
                    or "moving")
        end
        if s.dodging and s.dodgeClass == MDADDynamics.DODGE_VEHICLE then
            hardCapV, hardClampReason, okHard = MDADDynamics.lowerHardCap(
                hardCapV, hardClampReason, s.dodgeSpeedCap / 3.6, "moving")
        end
        if s.dodging and finite(s.dodgeNextCap) and s.dodgeNextCap >= 0 then
            hardCapV, hardClampReason, okHard = MDADDynamics.lowerHardCap(
                hardCapV, hardClampReason, s.dodgeNextCap / 3.6, "dodge-next")
        end
        if s.dodging and (s.dodgeEnvN or 0) >= 2 and finite(s.dodgeApproachCap) then
            hardCapV, hardClampReason, okHard = MDADDynamics.lowerHardCap(
                hardCapV, hardClampReason, s.dodgeApproachCap / 3.6, "dodge-entry")
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
        -- 剖面的彎前滑行包絡本身就是按滑行減速度排好的減速計畫；再把它送進 jerk 積分會多一層
        -- a²/(2j) 的穩態落後（2026-09-27 正式服兩段：彎前五秒命令一路比剖面高 4–5 km/h，到低速
        -- 急彎入口碰到 1.5×彎帽一秒鎖輪、整台停住）。命令上界直接吃純物理剖面（profileSpeedKmh，
        -- 不含起步／出彎收正等姿態帽），不新增任何硬煞理由；不低於 MIN_EXEC，免得到站爬行帶被夾死。
        do
            local pe = s.fstate.profileSpeedKmh
            if finite(pe) and pe >= 0 then
                if pe < MDADDynamics.MIN_EXEC_KMH then pe = MDADDynamics.MIN_EXEC_KMH end
                local okPe
                hardCapV, hardClampReason, okPe = MDADDynamics.lowerHardCap(
                    hardCapV, hardClampReason, pe / 3.6, "curve-coast")
                if not okPe then okHard = false end
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
        -- breach 門檻走 Dynamics.hardBreachKmh（cap + max(3, 6%)；2026-09-04 issue
        -- #2 定罪：舊 +0.5 低於 regulator 整數化＋bang-bang 漣漪＋進弧追蹤落後的
        -- 合計雜訊 ~2.2，彎道入口必觸發引擎 1 秒 ×13 煞車閂鎖＝鎖輪失側向抓地）。
        -- 門檻以下仍走下方 applySpeed：cmdV 已夾 hardCapV，regulator 目標 ≤ cap
        -- ＝斷油滑行（NoControl 只有 10-15 的 brakingForce、檔位保留）。
        -- 彎道 breach 不再走 cap+max(3,6%) 的門檻（0907f；2026-09-07 十三場 session 每個「整個停住才轉」
        -- 都是它：入弧 cap+1-3 km/h → forceBrake ×13 鎖輪一秒（telemetry `ib=true tn=0`，hbr 那一幀被
        -- 5-10Hz 取樣漏掉）→ sk 0.03、26→0 km/h。regulator 目標＝cap 本來就是 brake 15 連續減速
        -- 3.65 m/s² 不鎖輪；彎中鎖輪＝同時失去縱向與側向抓地。只留 ×CURVE_BREACH_RATIO 的離譜超速
        -- （剖面失效／cutover 瞬間）當災難兜底，1002a 起改不鎖輪的中線外力（Drive.hardBrake，照常轉向）；
        -- visibility／blocked／contact 的 forceBrake 不動。
        local curveBreached = hardCurveActive and finite(hardCurveCap)
            and hardCurveCap >= 0
            and actualSpeed > hardCurveCap * TUNE.CURVE_BREACH_RATIO
        local visibilityBreached = sensorReady and finite(s.visibilityHardKmh)
            and actualSpeed > MDADDynamics.hardBreachKmh(s.visibilityHardKmh)
        if curveBreached then hardBrakeReason = "curve" end
        if visibilityBreached
                and (not curveBreached or s.visibilityHardKmh <= hardCurveCap) then
            hardBrakeReason = "visibility"
        end
        -- 延後承諾仍有已知障礙：接近帽以 safeBrake 反推，必須有對應煞車、不能只斷油——先由
        -- Drive.visAssistForce 不鎖輪地追接近帽，連緊急煞車都快停不到群起點才一秒鎖輪（Drive.deferHardKmh）。
        if not s.dodging and finite(s.dodgeDeferCap) and s.dodgeDeferCap >= 0
                and actualSpeed > MDADDynamics.hardBreachKmh(Drive.deferHardKmh(s, actualSpeed))
                and (not curveBreached or s.dodgeDeferCap <= hardCurveCap)
                and (not visibilityBreached or s.dodgeDeferCap <= s.visibilityHardKmh) then
            hardBrakeReason = "dodge-defer"
        end
        -- blocked 接近包絡（Drive.blockedApproachCap）：減速輔助追不上、超過硬煞門檻才一秒鎖輪。停止線前
        -- 的低速段（≤ BLOCK_APPROACH_KMH＋BLOCK_APPROACH_HARD_MARGIN）不鎖輪：停止線的 blockedStop 本來就從
        -- 這個速度煞停（E2E rc2 0021：24 km/h 在停止線前 1.5m 先鎖輪停死、再爬到停止線又停一次）。
        if finite(s.blockedApproachCap)
                and actualSpeed > MDADDynamics.hardBreachKmh(s.blockedApproachCap)
                and actualSpeed > TUNE.BLOCK_APPROACH_KMH + TUNE.BLOCK_APPROACH_HARD_MARGIN
                and (not curveBreached or s.blockedApproachCap <= hardCurveCap)
                and (not visibilityBreached or s.blockedApproachCap <= s.visibilityHardKmh) then
            hardBrakeReason = "blocked-approach"
        end
        if s.progressState == "gear-reset" or s.recoverPulse then
            hardBrakeReason = nil
        end
        -- RETURN hold 只是「回線這一輪沒驗過」：前方障礙另由 contact／blocked／visibility 管。
        -- 已知幾何擋住回線（probe／sweep／band…）時，回線檔速度內斷油（NoControl brake 15，約
        -- 3.6 m/s²）停得住，不必一秒鎖輪（0924b 正式服 8 段急煞有 4 段是剛啟動、14-22 km/h 的
        -- 回線待命硬煞）。近場未知（unloaded／快照被重置）仍硬煞；其他硬煞理由不受影響。
        local returnHoldCoast = s.returnHold and actualSpeed <= TUNE.RETURN_CAP
            and s.lastHoldReason ~= nil and s.lastHoldReason ~= "unloaded"
            and sensorReady and fresh
            and not (s.followHold or s.currentBlocked
                or (s.recoverWhy ~= nil and not s.recoverPulse) or blockedStop or reached)
            and Drive.returnCoastClear(s, vehicle, fwd, fx, fy, actualSpeed)
        if (s.followHold or s.currentBlocked
                or (s.recoverWhy ~= nil and not s.recoverPulse)
                or s.returnHold or blockedStop or reached) and not returnHoldCoast then
            hardBrakeReason = hardClampReason
        end
        s.lastHardBrakeReason = hardBrakeReason -- telemetry hbr（本幀裁決者；nil＝無）
        -- 加速側直給（2026-09-01 三模型對抗審定案）：regulator 供油是二值全力
        -- （CarController.java:240-244 isGas；engineForce 不乘 throttle＝:755），
        -- jerk 積分目標貼著現速＝車一追平就斷油，加速度被人為封頂且斷續供油。
        -- 目標高於命令速度就一步跳到聚合 cap（引擎自然全力、達標自動斷油），
        -- 只夾 hardCapV。cmdV 先錨回實速（命令值不是真實狀態：上一幀直給的
        -- 高目標在 cap 下降瞬間從虛高值滑降會多供油半秒），錨定後 desired 與
        -- cmdV 相等（含起步/巡航穩態）一律走直給支，不得落進 jerk 積分。
        local desiredMs = targetSpeed / 3.6
        local actualMs = actualSpeed / 3.6
        s.desiredTarget = targetSpeed -- telemetry des：cap 鏈之後、jerk 之前的目標（與 tgt 差＝jerk／錨定）
        -- 錨定只收命令值，不清減速斜坡（2026-09-07 session-004 t=4-10 定罪：regulator
        -- bang-bang 讓實速每幀在命令值 ±0.3 抖，舊制 `cmdA=0` 每次錨定都把 jerk 積分
        -- 從零重來 → 6 秒只累到 −0.1～−0.4 m/s²、命令以 0.7 m/s² 下滑，coast 剖面
        -- 1.2 根本沒被執行 → R 9.9 彎 30 km/h 的入口以 44.6 撞進 hard breach →
        -- forceBrake ×13 鎖輪 → 側滑 6.5m 出線 → RETURN hold 再 forceBrake → 停 3 秒；
        -- 八場 session 每個 `hbr=curve` 都是同一條鏈）。正斜坡照清（錨定的本意：直給
        -- 的虛高命令在 cap 下降瞬間不得從高處滑降多供油半秒）。
        if s.cmdV > actualMs then
            s.cmdV = actualMs
            if s.cmdA > 0 then s.cmdA = 0 end
        end
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

        -- 停穩清失效線是狀態收尾，不可藏在下方 elseif blockedStop：
        -- hardBrakeReason 已先攔走 blocked 幀，放在那裡會永遠等到倒車才換線。
        if blockedStop and s.dodging and not s.dodgeCapPending
                and not s.currentBlocked and not s.returnHold and not s.dynamicsFault
                and s.recoverWhy == nil and not s.recoverPulse and s.progressState ~= "gear-reset"
                and speedKmh < 1 and speedKmh > -1 then
            MDADFollower.clearOffset(s.fstate)
            releaseDodge(s)
        end
        local regOn = false
        local force = 0
        if hardBrakeReason ~= nil then
            vehicle:setRegulator(false)
            -- stepFollow 貼 190 locals 上限：沿用 force（nil＝走了鎖輪，照舊補 brakeAssist）
            force = Drive.hardBrake(s, vehicle, now, hardBrakeReason, speedKmh, mult, steer, heading, fwd, fx, fy)
            if force == nil then
                force = 0
                Drive.brakeAssist(s, vehicle, Drive.emergencyBrakeDist(s, hardBrakeReason, blockedStop))
            end
            if hardCapV <= 0 then targetSpeed = 0 end
        elseif s.dynamicsFault then
            vehicle:setRegulator(false)
            commandForceBrake(s, vehicle, now, "dynamics-fault")
            targetSpeed = 0
        elseif s.progressState == "gear-reset" or s.recoverPulse then
            vehicle:setRegulator(false)
        elseif s.recoverWhy ~= nil or s.currentBlocked then
            vehicle:setRegulator(false)
            force = Drive.hardBrake(s, vehicle, now, s.currentBlocked and "contact" or "recover",
                speedKmh, mult, steer, heading, fwd, fx, fy) or 0
            targetSpeed = 0
        elseif s.returnHold then
            vehicle:setRegulator(false)
            if not returnHoldCoast then
                force = Drive.hardBrake(s, vehicle, now, "return-hold", speedKmh, mult, steer, heading, fwd, fx, fy) or 0
            end
            targetSpeed = 0
        -- RETURN outranks a planned block whose Frenet anchor is no longer meaningful.
        elseif blockedStop then
            -- 前方無縫隙且已逼近障礙群：主動煞停等待（不是 Drive.stop——session
            -- 活著，掃描持續，障礙消失由 replan 解除；玩家接手走讓位）。停死後
            -- 卡死偵測會接手升級成倒車脫困→紅字停車，整條鏈自然收斂。
            vehicle:setRegulator(false)
            force = Drive.hardBrake(s, vehicle, now, "blocked", speedKmh, mult, steer, heading, fwd, fx, fy)
            if force == nil then
                force = 0
                Drive.brakeAssist(s, vehicle, Drive.emergencyBrakeDist(s, "blocked", true))
            end
            targetSpeed = 0
            s.lastCapReason = "blocked"
        else
            -- 調頭生命週期（TUNE.UTURN；2026-09-06）：以航向誤差收尾（< ROTATE_EXIT），
            -- 不是 fstate.rotating——cutover／yield 的 resetState 會清 rotating，同一次
            -- 調頭不得因此重讀選項或重新入場煞停。參數檔在調頭開始讀一次。
            local rotating = s.fstate.rotating == true
            -- aerr 只剩前推輔助與調頭收尾在用（調頭判定已改讀 fstate.rotating）
            local aerr = headingError or 0
            if aerr < 0 then aerr = -aerr end
            if s.uturn and aerr < MDADFollower.ROTATE_EXIT_RAD then
                s.uturn, s.uturnArmed = nil, false
            end
            if s.tow then
                -- 拖掛車（MDAD_Trailer）：原地耦力調頭會把掛車甩斷（E2E semi-hairpin-mp），先要一條
                -- 不用調頭的繞行（Drive.towTurnaround，等 cutover 時停住），沒有才交還；
                -- 掛車脫落／前方不可過轉角停妥也交還；折角、傾斜、接近不可過轉角時壓速。
                if rotating then
                    vehicle:setRegulator(false)
                    BaseVehicle.releaseVector3f(fwd)
                    if not Drive.towTurnaround(s, playerNum, vehicle, now, fx, fy) then
                        Drive.stop(playerNum, MDADTrailer.KEY_ROTATE)
                    end
                    return
                end
                -- 路線上有過不去的轉角：得知當下先要一條避開的改道（Drive.towCornerDetour），沒有才照舊停在轉角前交還
                Drive.towCornerDetour(s, playerNum, vehicle, now, fx, fy)
                local towCap, towWhy = MDADTrailer.guard(s, vehicle, now, speedKmh)
                if towWhy == "corner" and s.pendingRouteWhy == "towcorner" and now < (s.towCornerUntil or 0) then
                    towCap, towWhy = 0, nil -- 已收下避開轉角的線、等下一幀 cutover：停住不交還
                end
                if towWhy then
                    vehicle:setRegulator(false)
                    BaseVehicle.releaseVector3f(fwd)
                    Drive.stop(playerNum, towWhy == "lost" and MDADTrailer.KEY_LOST or MDADTrailer.KEY_CORNER)
                    return
                end
                if towCap and targetSpeed > towCap then
                    targetSpeed = towCap
                    s.lastCapReason = "tow"
                end
            end
            if rotating and not s.uturn then
                s.uturn, s.uturnArmed = uturnProfile(), false
                diagEvent(s, playerNum, "uturn", {
                    phase = "enter", why = s.uturn.name, speed = speedKmh,
                })
                -- 同一處反覆調頭＝路線把車困在原地繞（0.13.1 正式服 (5180,11145) 反折點：投影釘死，
                -- 兩名玩家 16～204 次、繞到手動接手）。UTURN_LOOP_R 內第 UTURN_LOOP_MAX 次就受困交還，
                -- 留片段定罪，不讓車一直轉。
                if s.uturnLoopX ~= nil and (vx - s.uturnLoopX) * (vx - s.uturnLoopX)
                        + (vy - s.uturnLoopY) * (vy - s.uturnLoopY) <= TUNE.UTURN_LOOP_R * TUNE.UTURN_LOOP_R then
                    s.uturnLoopN = s.uturnLoopN + 1
                else
                    s.uturnLoopX, s.uturnLoopY, s.uturnLoopN = vx, vy, 1
                end
                if s.uturnLoopN >= TUNE.UTURN_LOOP_MAX then
                    vehicle:setRegulator(false)
                    BaseVehicle.releaseVector3f(fwd)
                    Drive.stop(playerNum, KEY_STUCK)
                    return
                end
            end
            -- 車周探測淨空（可原地轉）時目標壓到該檔 crawl：溫和檔 4 < spin 5，不會煞到 5
            -- 又朝 Follower 的 12 加速、切回大弧；快速檔 12＝Follower 值、等於不夾。
            if rotating and s.uturn and s.rotProbeClear
                    and targetSpeed > s.uturn.crawl then
                targetSpeed = s.uturn.crawl
            end
            regOn = applySpeed(s, vehicle, targetSpeed)
            if not reached then
                local av = speedKmh
                if av < 0 then av = -av end
                local ut = s.uturn
                local brakeCap = nil
                if rotating then
                    -- 入場減速（一次性）：新一次調頭先煞到 entry 以下才放行；放行後只剩
                    -- 常駐上限 arc，大弧爬行 12 不再觸發（s060 振盪的修法保留）。
                    if not s.uturnArmed and av <= ut.entry then
                        s.uturnArmed = true
                        diagEvent(s, playerNum, "uturn", {
                            phase = "go", why = ut.name, speed = speedKmh,
                        })
                    end
                    brakeCap = s.uturnArmed and ut.arc or ut.entry
                end
                if rotating and av > brakeCap then
                    -- 調頭需求但動量超過本階段上限：主動煞停，這幀不施轉向。
                    -- 2026-09-01 s060：舊閘用 SPIN_MAX(5) 當常駐上限，大弧爬行 12
                    -- 一加速就被煞回 5——「>5 煞停 → ≤5 才探測 → 探測擋 →
                    -- 大弧 12 → 又煞停」振盪，大弧路徑從未真正跑起來。常駐上限是
                    -- arc（爬行帶之上）；原地耦力自身仍要求近停（coupled 條件）。
                    -- 25 km/h 以上不鎖輪（1001e，見 Drive.hardBrake；steer nil＝只減速）。
                    vehicle:setRegulator(false)
                    Drive.hardBrake(s, vehicle, now, "rotate", speedKmh, mult, nil, heading, fwd, fx, fy)
                    regOn = false
                else
                    -- 誤差 > 90° 走耦力模式（coupled=true）：力矩恆定、側向中心力
                    -- 幀間抵消＝原地旋轉不橫滑（實機：橫推調頭會滑出路外撞東西）。
                    -- **原地旋轉前先探車周**（500ms 節流）：走廊沿路線掃，路線反向
                    -- 要調頭時車後方／側面全是走廊盲區——貼牆貼樹貼車旋轉＝車身
                    -- 掃掠直接撞。周邊不淨空（或未載入）就退回橫推大弧：爬行 12
                    -- 前進轉，空間不夠自然由卡死→脫困鏈接手。
                    local coupled = rotating and av <= ut.spin
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
                    s.crossDLat = nil -- 本幀橫向收斂速度（Drive.accelAssistForce 的預測偏差閘）；不算就不留舊值
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
                            -- 期望線台階（laneRoom 在弧邊界把常駐 bias 夾回 0、停留 commit 切
                            -- lane 等）＝latDev 單幀跳 1m＝差分 30 m/s 的假橫向速度；車做不到
                            -- 這種側速，直接視為不連續不進 D 項（弧段 ×2 後這一記會抽滿 1.5）。
                            if dLat > TUNE.CROSS_TRACK_DLAT_MAX or dLat < -TUNE.CROSS_TRACK_DLAT_MAX then
                                dLat = nil
                            end
                        end
                        s.prevCrossLat, s.prevCrossLatMs, s.crossDLat = latDev, now, dLat
                        -- 增益倍率選擇（貼縫／承諾線在弧上 ×DODGE、弧段／殭屍軟縫側移／回線精確線 ×ARC）的理由見
                        -- MDADDynamics.crossTrackGains（離線閉環 test_follower 用同一支）
                        local xg, xm = MDADDynamics.crossTrackGains(s.dodging, s.dodgeCrawl, s.curveHardActive,
                            s.fstate.kinkExitS ~= nil, s.zombieLane ~= nil or (s.returnActive and not s.returnHold))
                        steer = (steer or 0)
                            - MDADDynamics.crossTrackSteer(latDev, speedKmh, dLat, xg, xm)
                    else
                        s.prevCrossLat = nil
                    end
                    -- 前推輔助的姿態門檻（2026-09-01 使用者裁定「繞行與越野
                    -- 要能用推力幫忙通過」）：繞行／回線／物理越野時姿態誤差
                    -- 天然偏大（切縫、斜穿回線、草地打滑），舊的 20° 硬上限
                    -- 正好在最需要推力的場景把 assist 整個切斷＝卡住的來源。
                    -- 這三種情境把上限放寬到 2×，並讓 ratio 吃越野補償。
                    -- forceBrakeUntil 期間仍一律不 assist（安全紅線不動）。
                    local rough = s.dodging == true or s.returnActive == true
                        or s.physicalOffroad == true
                    local assistErrMax = TUNE.ASSIST_MAX_ERR_RAD
                    if rough then assistErrMax = assistErrMax * 2 end
                    -- 真的在草地上（physicalOffroad）姿態常歪到 40° 以上（2026-09-04 st179,012：
                    -- 出彎滑上草地、cap=align、thrust=0、9 km/h 爬 5 秒）：門檻再放到 3×
                    if s.physicalOffroad == true then assistErrMax = TUNE.ASSIST_MAX_ERR_RAD * 3 end
                    -- 殭屍推撞：帶內有殭屍且低速對高目標持續 DELAY 才啟動（一碰就推＝
                    -- 每次擦到殭屍都撞上去）；殭屍散了／速度上來就自然歸零。
                    -- 遲滯：推起來後速度爬到 EXIT_KMH 才收（進入門檻 5、退出 9），否則
                    -- 5.0↔4.9 每跨一次就重新等 800ms（s031 占空比四成）。
                    local zombiePush = false
                    local zNear = type(s.sensor) == "table" and (s.sensor.zombieN or 0) > 0
                    local zSpeedOk = speedKmh < TUNE.ZOMBIE_PUSH_SPEED_KMH
                        or (s.zombiePushNotified and speedKmh < TUNE.ZOMBIE_PUSH_EXIT_KMH)
                    if zNear and zSpeedOk and targetSpeed >= TUNE.ZOMBIE_PUSH_TARGET_MIN then
                        if s.zombiePushSince == 0 then s.zombiePushSince = now end
                        zombiePush = now - s.zombiePushSince >= TUNE.ZOMBIE_PUSH_DELAY_MS
                    else
                        s.zombiePushSince = 0
                    end
                    local assistForce = 0
                    if regOn and not coupled and speedKmh >= 0
                            and now >= s.forceBrakeUntil
                            and aerr <= assistErrMax then
                        assistForce = longitudinalAssistForce(
                            s, speedKmh, targetSpeed, mult, rough, zombiePush)
                    end
                    -- 越野推力遞增（使用者 2026-09-04「推力補到一定速度為止：先預估再遞增直到達速」）：
                    -- 草地上實速 < ASSIST_BOOST_KMH 而目標 ≥ 之，倍率每秒 +RATE 直到 MAX；達速／回路面
                    -- 以兩倍速率退回 1（推力是加在引擎上的，達速後若不退會過衝）
                    local rise = rough and assistForce > 0 and speedKmh < TUNE.ASSIST_BOOST_KMH
                        and targetSpeed >= TUNE.ASSIST_BOOST_KMH
                    s.assistBoost = math.max(1, math.min(TUNE.ASSIST_BOOST_MAX,
                        s.assistBoost + (rise and 1 or -2) * TUNE.ASSIST_BOOST_RATE * mult * SECONDS_PER_MULT))
                    if assistForce > 0 then assistForce = assistForce * s.assistBoost end
                    if zombiePush and assistForce > 0 and not s.zombiePushNotified then
                        s.zombiePushNotified = true
                        diagEvent(s, playerNum, "assist", { why = "zombie",
                            speed = speedKmh, target = targetSpeed, hn = s.sensor.zombieN })
                    elseif not zombiePush then
                        s.zombiePushNotified = false
                    end
                    -- 加速輔助（Drive.accelAssistForce）：條件同前推輔助、與它取大者（不疊加）；拖車由掛車分攤
                    if regOn and not coupled and speedKmh >= 0 and now >= s.forceBrakeUntil
                            and aerr <= assistErrMax then
                        local acc = Drive.accelAssistForce(s, speedKmh, targetSpeed, mult)
                        if acc > assistForce then
                            assistForce = acc
                            if s.tow then Drive.towDecel(s, -s.accelAssist, mult) end
                        else
                            s.accelAssist = 0
                        end
                    end
                    -- 巡航減速輔助：實速超過可視巡航帽時沿中線反向補減速（見 Drive.visAssistForce）
                    if assistForce == 0 and not coupled then
                        assistForce = -Drive.visAssistForce(s, speedKmh, mult)
                        if s.tow and s.visAssistDecel > 0 then Drive.towDecel(s, s.visAssistDecel, mult) end
                    end
                    -- 回授依轉向增益正規化（TUNE.FB_NORM_*）後，車身 yaw 率限制（TUNE.ESC_*）；耦力原地調頭兩者都不經
                    if not coupled then
                        steer = Drive.yawGovern(s, Drive.normalizeSteer(s, steer or 0), heading, speedKmh, now)
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
            -- 2026-09-04 起帶 cap 理由／越野／繞行／blocked 旗標：實機「target 12、
            -- speed 5、regulator=true 卻沒煞車」（Toadhop Road 彎）只有 off= 能分出
            -- 「油門不夠」與「輪子出路面被拖住」；「target 恆 8」只有 cap= 能點名兇手。
            local capStr = tostring(s.lastCapReason)
            if s.lastCapReason == "min-exec" then capStr = "min-exec(" .. tostring(s.minExecFrom) .. ")" end
            print(string.format(
                "%spn=%d mode=%s speed=%.1f target=%.1f cap=%s env=%.1f errDeg=%.1f steer=%.2f force=%.0f thrust=%.0f remaining=%.1f lat=%.1f road=%.2f gear=%d regulator=%s off=%s dg=%s bl=%s",
                LOG, playerNum, s.mode, speedKmh, targetSpeed or 0,
                capStr, s.profileEnvelope or -1,
                (headingError or 0) * TUNE.DEG_PER_RAD, steer or 0,
                force, s.lastAssistForce, remaining or 0,
                sqrt(lateralSq or 0), s.roadBias,
                Drive.getGear(playerNum), tostring(regOn),
                tostring(s.physicalOffroad), tostring(s.dodging), tostring(s.blocked)))
        end
        if s.diag then
            -- 新 Java getter 只在這一幀確定會 enqueue sample 時才跑；
            -- shouldSample 與 D.sample 共用同一 5/10Hz gate。
            local critFlag = s.blocked or s.currentBlocked or s.dodging or s.returnActive
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
    -- 停等總預算耗盡是最高優先的終局（紅字交還玩家），蓋過任何恢復需求。
    if postAction == "wait" then
        -- 其他玩家擋路：不推人、不改道，以專屬理由交還（1005 soft）
        if s.softHoldKind == "player" then
            diagEvent(s, playerNum, "soft", { phase = "handback", why = "player", kind = "player",
                ms = s.softHoldMs, rs = s.lastSNow })
            if getDebug() then
                print(string.format("%spn=%d soft stop handback kind=player ms=%d wait=%d", LOG, playerNum,
                    s.softHoldMs, s.waitAccumMs))
            end
            Drive.stop(playerNum, Drive.KEY_PLAYER_STOP, "handback")
            return
        end
        if Drive.stuckDetour(s, playerNum) then return end
        Drive.stop(playerNum, KEY_STUCK)
        return
    end
    -- 前方區域一直沒載入（TUNE.AREA_WAIT_MAX_MS）：專屬理由交還，玩家知道不是路被堵
    if postAction == "area" then
        Drive.stop(playerNum, Drive.KEY_AREA_STOP)
        return
    end
    -- 動物一直擋在行駛線上、爬行 ANIMAL_CRAWL_MAX_MS 仍沒讓開：專屬理由交還（不改道、不倒車）
    if postAction == "animal" then
        diagEvent(s, playerNum, "soft", { phase = "handback", why = "animal-crawl-timeout", kind = "animal",
            ms = s.softCrawlMs, rs = s.lastSNow })
        if getDebug() then
            print(string.format("%spn=%d soft stop handback kind=animal why=animal-crawl-timeout crawlMs=%d", LOG,
                playerNum, s.softCrawlMs))
        end
        Drive.stop(playerNum, Drive.KEY_ANIMAL_STOP, "handback")
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
        Drive.gateShutRetry(s, playerNum, vehicle, now) -- Knox Pass 會開的門到倒車那刻仍關著：提示 shut（unstick 語音之後）
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
            commandForceBrake(s, vehicle, now, "arrive")
        end
    end
end

-- 預計剩餘時間（1005i；Workshop 許願「預估要開幾分鐘」，使用者裁定只算現實時間、HUD 加第三欄）：
-- 剖面計畫秒數（MDADFollower.planTimes）× 本趟修正倍率 k＝(實際行進秒＋τ·k0)／(計畫行進秒＋τ)：開頭先信剖面，
-- 開越久越信這趟實際的快慢（可視距離、幀率、殭屍、繞行、停等、倒車都會算進 k）。計時每幀累加；計畫表與估計每
-- ETA_STEP_MS 更新一次（剖面讀取不進每幀）。換路線、重建（profile.epoch）、有效上限改變時整份重算計畫表，並在新位置
-- 重設基準，座標系跳動不算成前進；讓位（玩家自己開）與幀間隔超過 ETA_GAP_MS（單機暫停、選單）不計時。
-- 離線回測（campaign rc57–rc61 135 趟到站，以樣本 ftg 重建剖面）中位誤差約 10%、p90 約 25%。
TUNE.ETA_GAP_MS = 1000  -- 兩幀間隔超過這個值不計時（單機暫停、選單、長卡頓）
TUNE.ETA_STEP_MS = 250  -- 計畫表與估計的更新節奏（HUD 每 250ms 才讀一次）
TUNE.ETA_PRIOR_S = 60   -- 修正倍率的先驗權重（計畫秒數）
TUNE.ETA_PRIOR_K = 1.15 -- 先驗倍率：上限附近推力遞減等剖面沒算到的部分，回測平均比計畫慢約 13%
TUNE.ETA_K_MIN = 0.5
TUNE.ETA_K_MAX = 4
function Drive.etaTick(s, now)
    local last = s.etaWallMs
    s.etaWallMs = now
    if s.mode == "yield" then
        s.etaBaseT = nil -- 玩家自己開的那段不算進 k；恢復後在新位置重設基準
        return
    end
    if last and now > last and now - last <= TUNE.ETA_GAP_MS then
        s.etaElapsed = s.etaElapsed + (now - last) / 1000
    end
    if now < (s.etaNextMs or 0) then return end
    s.etaNextMs = now + TUNE.ETA_STEP_MS
    local profile = s.profile
    if not profile or profile.ready ~= true then return end
    -- 有效上限＝沙盒／檔位／感知／車輛極速取小（伺服器速限只在重算時讀）
    local cap = s.maxSpeed
    local v = s.gearCap
    if finite(v) and v > 0 and v < cap then cap = v end
    v = s.perceptionCap
    if finite(v) and v > 0 and v < cap then cap = v end
    v = s.vehicleProfile and s.vehicleProfile.maxSpeed
    if finite(v) and v > 0 and v < cap then cap = v end
    if profile ~= s.etaProfile or profile.epoch ~= s.etaEpoch or cap ~= s.etaCapKmh then
        local capEff = cap
        v = Drive.serverSpeedLimit()
        if finite(v) and v > 0 and v < capEff then capEff = v end
        local speed = s.vehicle:getCurrentSpeedKmHour()
        if not finite(speed) or speed < 0 then speed = 0 end
        local total = MDADFollower.planTimes(profile, capEff / 3.6, speed / 3.6, s.etaPlan)
        s.etaProfile, s.etaEpoch, s.etaCapKmh = profile, profile.epoch, cap
        s.etaEnd = total and MDADFollower.planTimeAt(s.etaPlan, profile.length - MDADFollower.ARRIVE_M)
        s.etaBaseT = nil
        if not s.etaEnd then s.etaSec, s.etaK, s.etaDistM = nil, nil, nil end
    end
    local sNow = s.fstate.projS
    if not s.etaEnd or not finite(sNow) then return end
    local tNow = MDADFollower.planTimeAt(s.etaPlan, sNow, s.fstate.idx)
    if not tNow then return end
    if s.etaBaseT then s.etaPlanned = s.etaPlanned + tNow - s.etaBaseT end -- 倒車＝負的前進
    s.etaBaseT = tNow
    local planned = s.etaPlanned
    if planned < 0 then planned = 0 end
    local k = (s.etaElapsed + TUNE.ETA_PRIOR_S * TUNE.ETA_PRIOR_K) / (planned + TUNE.ETA_PRIOR_S)
    if k < TUNE.ETA_K_MIN then k = TUNE.ETA_K_MIN elseif k > TUNE.ETA_K_MAX then k = TUNE.ETA_K_MAX end
    local left = s.etaEnd - tNow
    if left < 0 then left = 0 end
    local dist = profile.length - sNow
    if dist < 0 then dist = 0 end
    s.etaK, s.etaSec, s.etaDistM = k, left * k, dist
end

-- HUD 預計剩餘欄：本趟估計還要幾秒（現實時間）與沿路線還剩幾公尺（滑鼠提示，1005j）；沒有 session 或還沒有估計＝nil。
function Drive.etaSeconds(playerNum)
    local s = sessions[playerNum]
    if not s then return nil end
    return s.etaSec, s.etaDistM
end

-- OnPlayerUpdate 簽名：單一 IsoPlayer（IsoPlayer.java:2279 triggerEvent("OnPlayerUpdate", this)；
-- 原版用例 Steps.lua:1922、DebugDemoTime.lua:308）。伺服器端 isLocalPlayer 恆 false
-- （IsoPlayer.java:6493），遠端玩家也擋在這裡——自駕只在駕駛自己的 client 跑。
local function onPlayerUpdate(player)
    if sessionCount == 0 and prepCount == 0 then return end
    if not player or not player:isLocalPlayer() then return end
    local playerNum = player:getPlayerNum()
    local s = sessions[playerNum]
    if not s then
        -- 沒有 session 但有行程待辦：續辦準備（每幀推進剖面、250ms 查一次路線；對車
        -- 零控制輸出），以及欠 MiniMap 的交還重試。準備失敗才出紅字，等路線期間安靜
        -- （HUD 顯示 build）。
        if prepCount > 0 then
            local pending = getTimestampMs()
            TRIP.stepOwed(playerNum, pending)
            pending = TRIP.stepPrep(playerNum, pending)
            if pending then haloBad(player, pending) end
        end
        return
    end

    if player:isDead() then
        Drive.stop(playerNum, nil, nil, "dead")
        return
    end

    -- 非原車／不再是駕駛／已下車：靜默結束（不是錯誤，不用紅字轟人）
    local vehicle = player:getVehicle()
    if vehicle ~= s.vehicle or not vehicle:isDriver(player) then
        Drive.stop(playerNum, nil, nil, "exit")
        return
    end

    -- v6：**任何**控制輸出之前先核對 claim token，包含 arrive 的煞停收尾——玩家按了
    -- 「停止導航」之後不該還有人跟他搶煞車（§6.4「失效即交還控制」）。
    if s.legToken then
        local trip = TRIP.api()
        if not trip or trip.getNavLeg(playerNum) ~= s.legToken then
            -- 只有讀到不同 token 才確認已撤銷；介面缺席仍須保存待交還紀錄。
            if trip then s.legToken = nil end
            Drive.stop(playerNum, trip and TRIP.LOST or KEY_API)
            return
        end
    end

    local now = getTimestampMs()
    Drive.etaTick(s, now) -- 預計剩餘時間：每幀計時；換路線／重建後重算計畫表（arrive 收尾也照走）
    if s.brakeTerminalFault then
        Drive.stop(playerNum, KEY_UNSUPPORTED)
        return
    end
    if refreshMass(s, vehicle, now) then
        s.dynamicsDirty, s.dynamicsCapMaterial = true, false
        diagEvent(s, playerNum, "dyn", { phase = "dirty", why = "mass", cap = s.runtimeMass })
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
            haloGood(player, "UI_MinidoracatAutoDrive_ManualStop")
            Drive.stop(playerNum, nil, "manual")
            return
        end
        vehicle:setRegulator(false)
        if vehicle:isStopped() then
            -- v6／v7 到站：回報必須在清 session **之前**完成，且此刻控制輸出已停
            -- （regulator 已關、本幀不再送 forceBrake）。舊單站自駕沒有 claim，
            -- outcome 直接是 arrived、disposition 為 nil，行為逐位元同以前。
            local outcome, disposition, reportedRev = "arrived", nil, nil
            if s.legToken then
                if s.legReportUntil == 0 then s.legReportUntil = now + TRIP.REPORT_MS end
                -- 重試間隔內：維持 arrive、維持停妥，不清 session 也不假報抵達。
                if now < s.legReportMs then return end
                s.legReportMs = now + ROUTE_REFRESH_MS
                local why, consumed, disp, rev = TRIP.report(playerNum, s.legToken)
                -- 舊回報不能收掉回呼新建的意圖，也不能替它排停靠語音／暫停。
                if sessions[playerNum] ~= s then return end
                if consumed then
                    s.legToken = nil
                    outcome, disposition, reportedRev = why, disp, rev
                elseif now < s.legReportUntil then
                    -- 被拒但 claim 仍是我們的：明示原因（同一個原因只說一次）後重試。
                    if s.legReportWhy ~= why then
                        s.legReportWhy = why
                        haloBad(player, why)
                    end
                    return
                else
                    -- 有界重試用完：控制早已停，交還 claim 再收尾（交還被拒會自己排重試）。
                    TRIP.release(playerNum, s.legToken, "failed")
                    if sessions[playerNum] ~= s then return end
                    s.legToken = nil
                    outcome = why
                end
            end
            local nextPrep
            if outcome == "arrived" and disposition == "continue" and not TRIP.owed[playerNum] then
                nextPrep = { playerObj = player, vehicle = s.vehicle, auto = true,
                    event = "leg_next", revision = reportedRev, startedMs = now, nextMs = 0,
                    deadlineMs = now + TRIP.PREP_MS }
            end
            diagStop(s, playerNum, "arrive")
            clearSession(playerNum)
            if outcome == "arrived" then
                if nextPrep then
                    -- report 的版本授權在 acquire 重驗；第一個 Core API 之前已有可取消意圖。
                    TRIP.preps[playerNum] = nextPrep
                    prepCount = prepCount + 1
                    if cancelPendingPause then cancelPendingPause() end
                    local why = TRIP.stepPrep(playerNum, now)
                    if why then haloBad(player, why) end
                elseif disposition == "continue" then
                    haloBad(player, TRIP.LOST)
                elseif disposition == "stopover" then
                    -- 停靠點／逐點等候：停在這裡等玩家，可依既有的抵達暫停設定。
                    haloGood(player, TRIP.STOPOVER)
                    voice("stopover", playerNum, "pauseOnArrival")
                elseif disposition == "completed" then
                    haloGood(player, "UI_MinidoracatAutoDrive_Arrived")
                    haloGood(player, TRIP.COMPLETED)
                    voice("arrive", playerNum, "pauseOnArrival")
                else
                    -- v6 Core（沒有 disposition）與舊單站自駕：逐位元同以前。
                    haloGood(player, "UI_MinidoracatAutoDrive_Arrived")
                    voice("arrive", playerNum, "pauseOnArrival")
                end
            elseif outcome == "road_end" then
                -- 道路終點：本站仍是 pending，交給玩家徒步前往。不冒稱抵達、
                -- 不播成功語音、不自動開下一段。白字＝資訊不是失敗。
                -- 車已停妥、等玩家下車步行（HUD「手動前往」）：照抵達暫停設定直接暫停（Workshop nick）。
                local roadEnd = getText(TRIP.ROAD_END)
                HaloTextHelper.addText(player, roadEnd)
                if MDADDiagnostics and MDADDiagnostics.toast then MDADDiagnostics.toast(roadEnd, "info") end
                voice(nil, playerNum, "pauseOnArrival")
            elseif outcome ~= "duplicate" then
                -- 回報沒有成立：原因給玩家看，站點不動、不自動出發。
                haloBad(player, outcome)
            end
        else
            if not commandForceBrake(s, vehicle, now, "arrive") then
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
            if s.legToken then
                -- 有 claim 時 MiniMap 不會因距離清目標、也不會替我們完成站（§6.3），
                -- 所以這裡的「目標不見了」只代表本段不再有效——絕不能沿用 v5 的
                -- 「目標消失＝抵達」收旗啟發把它當成到站。
                Drive.stop(playerNum, tx == nil and TRIP.LOST or KEY_LOST)
                return
            end
            local arrived = false
            if tx == nil and s.lastTx then
                local ddx = s.lastTx - vehicle:getX()
                local ddy = s.lastTy - vehicle:getY()
                arrived = ddx * ddx + ddy * ddy <= TUNE.ARRIVE_CLEAR_SQ
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
                if not commandForceBrake(s, vehicle, now, "arrive") then
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
            s.avoidX, s.avoidY, s.avoidR, s.avoidTow, s.pendingDetour = nil, nil, nil, nil, false
            s.avoidHist = nil -- 新目標＝新的一趟，先前判死的堵點不再算
            s.avoidLong, s.stuckDetourN, s.stuckDetourX, s.stuckDetourY = nil, 0, nil, nil -- 新目標＝新的改道額度
            s.towTurnTries, s.uturnLoopX, s.uturnLoopY = 0, nil, nil -- 新目標＝新的一趟
            s.towCornerTries = 0 -- 新目標＝新的一趟
            s.rejectedRoute = nil
        end
        -- 被本 MOD 拒收的替代線（far／long／through）仍躺在主 MOD 快取裡（requestDetour
        -- 成功即覆寫），下一次取路會原樣拿回同一個 table——不得當成一般 cutover 收下
        -- （2026-09-02 s064：拒收 far 之後同一幀就以 "deviation" 名義跟著它開進樹林；
        -- 主 MOD 冷卻後重算會換新 identity，屆時照常 cutover）。**必須在距離閘之前**：拒收的
        -- far 線走到距離閘＝RouteTooFar 交還（0928m E2E rc15 0095：改道被拒 far，15 幀後交還）。
        if route ~= s.route and s.rejectedRoute ~= nil and route == s.rejectedRoute then
            route = s.route
        end
        if route ~= s.route and Drive.holdWideReroute(s, not targetChanged, api.navApiVersion == s.navVersion) then
            route = s.route
        end
        -- 距離閘是新路線的接收條件（含同目標偏航重算），不重新驗收同一顆快取。
        -- 換反向目標時，合法路線起點後的煞停過衝可能超過20m；旋轉與感知仍各自把關。
        if (route ~= s.route or targetChanged or api.navApiVersion ~= s.navVersion)
                and cachedSnapTrusted(api) and routeTooFar(route) then
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
        -- sticky 避讓：主 MOD 之後因偏航／冷卻自行重算（不帶 avoid）若又穿回堵點（目前這圈或同一趟先前判死的圈，
        -- Drive.avoidMore），立刻以同一圈再要一次替代線、舊圈一併附上，拿不到才照原線走（每次 cutover 最多一次）。
        -- 圈的半徑與長度上限跟當初要的同一套（堵車改道／拖車繞開調頭，s.avoidR／s.avoidTow）。
        if route ~= s.route and not targetChanged and not s.pendingDetour
                and finite(s.avoidX) and finite(s.avoidY) then
            local more = Drive.avoidMore(s, vehicle:getX(), vehicle:getY(), tx, ty, s.avoidX, s.avoidY, false)
            if routeCrossesAvoid(route, s.avoidX, s.avoidY, s.avoidR or TUNE.DETOUR_AVOID_R)
                    or Drive.crossesAnyAvoid(route, more) then
                local remaining = s.profile and (s.profile.length - s.lastSNow) or nil
                local detour, _, rejected = requestDetourRoute(api, playerNum, tx, ty, s.avoidX, s.avoidY,
                    remaining, s.avoidR, s.avoidLong and finite(remaining)
                        and remaining * TUNE.STUCK_DETOUR_LEN_RATIO + TUNE.STUCK_DETOUR_LEN_SLACK
                        or s.avoidTow and finite(remaining)
                        and remaining * TUNE.TOW_TURN_LEN_RATIO + TUNE.TOW_TURN_LEN_SLACK or nil, route, more)
                if detour then
                    route = detour
                    s.pendingRouteWhy = s.avoidTow and "towturn" or "detour"
                else
                    s.avoidX, s.avoidY, s.avoidR, s.avoidTow, s.avoidLong = nil, nil, nil, nil, nil
                    if rejected ~= nil then s.rejectedRoute = rejected end
                end
            end
        end
        if route ~= s.route or versionChanged or s.reapproach then
            local profileRoute, approachM = Drive.profileRouteOf(route, s.tow, s.vehicleProfile,
                vehicle:getX(), vehicle:getY(), s.reapproach)
            s.reapproach = nil
            local profile = MDADFollower.begin(
                profileRoute,
                s.maxSpeed, api.navApiVersion, s.vehicleProfile,
                MDADFollower.STYLES[Drive.getStyle(playerNum)])
            if not profile then
                Drive.stop(playerNum, KEY_LOST)
                return
            end
            MDADVehicleProfile.configureFollower(
                profile, s.vehicleProfile, s.runtimeMass, s.rain)
            -- 風格限制只屬於目標速度表；物理基準不可從已被 comfort 夾低的 seg* 反推。
            local aDrive, aBrake, aLat, _, _, aCoast = MDADVehicleProfile.priors(
                s.vehicleProfile, s.runtimeMass, profile.segSurface[1],
                s.rain, s.tractionOffroad, s.adaptive)
            s.safeAccel, s.safeBrake, s.safeLat, s.safeCoast = aDrive, aBrake, aLat, aCoast
            s.dynamicsBrakeCap, s.dynamicsLatCap, s.dynamicsCoastCap =
                s.safeBrake, s.safeLat, s.safeCoast
            MDADFollower.setRuntimeLimits(
                s.fstate, s.safeAccel, s.safeBrake, s.safeLat, s.safeCoast)
            local routeWhy = s.pendingRouteWhy
            if routeWhy == nil then routeWhy = targetChanged and "target" or "deviation" end
            s.pendingRouteWhy = nil
            s.pendingDetour = false
            s.routeGen = s.routeGen + 1
            Drive.disarmWide(s) -- 武裝點是舊路線的弧長
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
            s.profileRoute = profileRoute
            s.approachM = approachM -- 越野接線只在起步與倒車退到接線起點後接（見 Drive.approachRoute）
            s.profile = profile
            s.rejectedRoute = nil
            s.navVersion = api.navApiVersion
            Drive.invalidateCommandState(s, vehicle:getCurrentSpeedKmHour(), "HOLD")
            s.adaptive = profile.adaptive == true
            s.dynamicsDirty, s.dynamicsCapMaterial = false, false
            s.buildBudget, s.rebuildStartMs = BUILD_BUDGET, 0
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
            elseif oldMode == "yield" then
                -- 讓位中換路線（玩家掉頭最常觸發偏航重算）：保留 yield。舊制在這裡覆寫成
                -- build，下一幀 build→follow 就跳過放手等待與「恢復控制」提示＝0 秒接管
                -- （2026-09-06 回饋「放開會變回自動駕駛、突然回頭」的一條路徑）。新 profile
                -- 由恢復幀依 ready 決定先走 build。
            elseif resumePhase ~= nil or not preservingRecovery or oldMode == "follow" then
                -- 「保留恢復」只保留倒車／settle 本身；跟線模式等倒車開始（recoverWhy 待命）時換線，照樣
                -- 先 build——stepFollow 拿到 ready=false 的剖面＝curve-state 故障交還（0928m E2E rc15
                -- 0094／0118：改道 cutover 同幀 UnsupportedVehicle）。recoverWhy 保留，建好後照常倒車。
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
            s.laneChained, s.chainKeptLogged = false, nil
            s.trafficLane, s.trafficPlan = nil, nil -- 換弧長座標系：錯車側移從新路線常駐線重來
            s.trfLeadGap, s.trfOnGap, s.trfOnWant, s.trfOnYield = nil, nil, nil, false
            MDADFollower.setLaneBias(s.fstate, s.sandBias)
            Drive.transitionRelease(s, playerNum, "route", nil) -- 保持的 lane 是舊路線座標
            if s.sensor then s.sensor.scanBias = s.sandBias end
            if type(MDADOverlay) == "table"
                    and type(MDADOverlay.clearTrail) == "function" then
                MDADOverlay.clearTrail(playerNum)
            end
            releaseDodge(s)
            s.blocked = false
            s.blockedNotified = false
            endReturn(s)
            s.surfaceMismatch, s.surfaceMismatchRounds = false, 0
            s.physicalOffroad = false
            s.tractionOffroad, s.offroadFlipSince = false, 0
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
            s.softStopS, s.softStopKind = nil, nil -- 舊路線弧長；新路線首輪掃完再判
            s.softGentleS, s.softAnimalAnchorS = nil, nil -- 同上（弧長座標系換了）
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
    -- 2026-09-04 issue #1 定罪 B：舊制 material 重建把基準設成收緊值、卻把 EWMA／
    -- confidence／tractionKey 全清 → 下一次檢查 safe* 已彈回 prior、|cap − prior|
    -- 正是剛觸發的差值 → 必再重建一次（session-002 13/15 成對反彈）。material
    -- ＝同 regime 的線上證據收緊，觀測必須保留；只有 regime 換了（key／mass，
    -- priors 本身變）舊觀測才屬於舊世界、清空重學。regulator 也不再關：上一幀
    -- 命令仍有效，重建只有 1-2 幀（TUNE.REBUILD_BUDGET），掛 N 反而是 issue #1
    -- 「一直慢下來」的直接動作（control_NoControl:501-503 只在 !isRegulator 掛 N）。
    if s.mode == "follow" and (s.dynamicsDirty or s.profile.styleName ~= s.pendingStyle) then
        s.dodgeEnvN = 0 -- 速度預算改變即作廢；純幾何Clr由任何風格的guard保持更新。
        Drive.invalidateCommandState(s, vehicle:getCurrentSpeedKmHour(), "HOLD")
        local styleChanged = s.profile.styleName ~= s.pendingStyle
        local material = s.dynamicsCapMaterial == true or (styleChanged and not s.dynamicsDirty)
        if styleChanged then
            MDADFollower.setStyle(s.profile, MDADFollower.STYLES[s.pendingStyle])
            s.dodgeEntryPassed = false
        end
        MDADVehicleProfile.configureFollower(
            s.profile, s.vehicleProfile, s.runtimeMass, s.rain)
        s.horizonStamp = -1
        s.horizonMinBrake, s.horizonMinLat, s.horizonMinCoast = 0, 0, 0
        Drive.clearLaneProof(s)
        if material then
            MDADFollower.capSegmentLimits(
                s.profile, s.safeAccel, s.safeBrake, s.safeLat, s.safeCoast)
        else
            local idx = s.fstate.idx or 1
            idx = idx - idx % 1
            if idx < 1 then idx = 1 elseif idx >= s.profile.n then idx = s.profile.n - 1 end
            local aDrive, aBrake, aLat, _, _, aCoast = MDADVehicleProfile.priors(
                s.vehicleProfile, s.runtimeMass, s.profile.segSurface[idx],
                s.rain, s.tractionOffroad, s.adaptive)
            s.safeAccel, s.safeBrake, s.safeLat, s.safeCoast = aDrive, aBrake, aLat, aCoast
            MDADFollower.setRuntimeLimits(
                s.fstate, s.safeAccel, s.safeBrake, s.safeLat, s.safeCoast)
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
            s.targetPrev, s.steerPrev = 0, 0
        end
        MDADFollower.invalidateDynamics(s.profile)
        s.dynamicsBrakeCap, s.dynamicsLatCap, s.dynamicsCoastCap =
            s.safeBrake, s.safeLat, s.safeCoast
        if s.forceBrakeUntil > s.ewmaSuppressUntil then
            s.ewmaSuppressUntil = s.forceBrakeUntil
        end
        s.dynamicsDirty, s.dynamicsCapMaterial = false, false
        s.mode = "build"
        s.buildBudget, s.rebuildStartMs = TUNE.REBUILD_BUDGET, now
        diagEvent(s, playerNum, "dyn", {
            phase = "rebuild", why = styleChanged and "style" or (material and "material" or "regime"),
            pts = s.profile.n, kind = s.profile.styleName,
        })
    end

    -- （detour 塊已移除；理由見 DETOUR 註解＝telemetry s030/s033）

    -- 掛車脫開：每個模式都查（E2E semi-corner-mp：掛車斷開時車正在等待，guard 不跑，自駕停在原地不交還）
    if s.tow and MDADTrailer.lost(vehicle, s.tow) then
        vehicle:setRegulator(false)
        Drive.stop(playerNum, MDADTrailer.KEY_LOST)
        return
    end

    -- 限速剖面分幀建構：ready 之前不控速也不施力。
    if s.mode == "build" then
        if s.commandControlState ~= "HOLD" then
            Drive.invalidateCommandState(s, vehicle:getCurrentSpeedKmHour(), "HOLD")
        end
        -- 這幀不跑 control：yaw 增益估計的航向差分斷掉（跨幀航向變化除以單幀 dt＝假增益；
        -- Codex lane 0908a residual）
        s.fstate.prevHeading = nil
        if not MDADFollower.stepBuild(s.profile, s.buildBudget) then return end
        if s.rebuildStartMs > 0 then
            diagEvent(s, playerNum, "dyn", {
                phase = "ready", ms = now - s.rebuildStartMs, pts = s.profile.n,
            })
            s.rebuildStartMs = 0
        end
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
                approach = s.approachM > 0 and s.approachM or nil, -- 越野接線長（Drive.approachRoute）
                -- 清掉的微反折點數（Drive.profileRouteOf；地圖資料接點錯位／拖車改寫殘點）
                detail = s.profileRoute and s.profileRoute.despiked
                    and ("despike " .. tostring(s.profileRoute.despiked)) or nil,
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
    -- 「手動介入後」選項（2026-09-06 使用者裁定預設不自動恢復）：0＝介入即關閉 session、
    -- 放手不會自己接手（回饋「不知道放開會變回自動駕駛、突然回頭被嚇到」）；>0＝待命，
    -- 放手連續這麼久才恢復。值在進入 yield 那幀讀一次，之後改選項不追溯。
    if manualInput(vehicle) then
        if s.mode ~= "yield" then
            local resumeMs = manualResumeMs()
            if resumeMs <= 0 then
                haloGood(player, "UI_MinidoracatAutoDrive_ManualStop")
                Drive.stop(playerNum, nil, "manual")
                return
            end
            s.mode = "yield"
            s.yieldResumeMs = resumeMs
            s.yieldSinceMs = now
            diagEvent(s, playerNum, "takeover", { phase = "yield" })
            -- 玩家接手＝舊診斷作廢（舊制由 mode 被覆寫成 "yield" 自然丟掉
            -- recover 閂鎖；旗標化後必須顯式丟，否則恢復後立刻倒車）。
            s.recoverWhy, s.recoverPulse = nil, false
            vehicle:setRegulator(false)
            Drive.invalidateCommandState(s, vehicle:getCurrentSpeedKmHour(), "YIELD")
            if not s.yieldNotified then
                s.yieldNotified = true
                haloGood(player, "UI_MinidoracatAutoDrive_ManualOverride")
            end
            if not s.yieldVoiced then
                s.yieldVoiced = true
                voice("yield", playerNum)
            end
        end
        s.cleanSinceMs = 0
        return
    end
    if s.mode == "yield" then
        -- 恢復用「連續乾淨時間」而非幀數：舊制 10 幀（~0.17 秒）等於手一離開鍵盤
        -- 就立刻接管，玩家把車頭調到反向時會瞬間吃到飽和調頭側推、整台車甩出去
        -- （2026-08-28 實機回報「剛放手就誇張瞬間調頭」）。放手後緩衝＋恢復提示，
        -- HUD 狀態列同步倒數，玩家看得到「它要接手了」。
        if s.cleanSinceMs == 0 then
            s.cleanSinceMs = now
            return
        end
        if now - s.cleanSinceMs < s.yieldResumeMs then return end
        s.cleanSinceMs = 0
        s.yieldNotified = false -- 下次讓位再提示一次（讓位↔恢復是成對事件）
        -- 清控制歷史（保留投影游標）：yield 期間玩家可能大幅改變車頭朝向，
        -- 舊的 PID 積分／微分歷史對新姿態是雜訊
        if type(MDADFollower.resetControl) == "function" then
            MDADFollower.resetControl(s.fstate)
        end
        -- 讓位期間 Sensor 不跑，proof 停在讓位前那輪快照；玩家可能已開過證明線尾（0924a
        -- 正式服兩趟：恢復首幀 currentS > laneCurveEnd → lane-envelope → UnsupportedVehicle）。
        Drive.clearLaneProof(s)
        -- 讓位期間停等計時、判堵與感知也都停在讓位前：玩家可能已把車開走。2026-10-01 正式服 0.16.0：
        -- 渡鴉溪東入口判堵停住→玩家接手開走 57m→放手恢復，首個停等幀把讓位 17 秒一次補進停等預算
        -- （waitTickMs 停在讓位前，只有倒車恢復鏈該這樣補計）＝超過 15 秒→0.4 秒內 StopStuck；同一幀又用
        -- 讓位前的舊快照算可視硬煞，25 km/h 鎖輪。比照倒車成功：舊 episode／判堵／承諾作廢，感知從頭
        -- 掃一輪（未 ready 時目標 0＝斷油滑行、可視硬煞不參與裁決，約一輪 375ms 後照常）。
        clearEpisode(s)
        MDADFollower.clearOffset(s.fstate)
        releaseDodge(s)
        s.blocked, s.blockedNotified = false, false
        s.planSig, s.clearStreak = -1, 0
        if s.sensor and type(MDADSensor) == "table" and type(MDADSensor.reset) == "function" then
            MDADSensor.reset(s.sensor)
        end
        -- RETURN 的掃描帶錨在這裡重設（內含 Sensor reset 後寫 scanBias），須排在上面的感知重設之後
        invalidateReturnControl(s)
        Drive.invalidateCommandState(s, vehicle:getCurrentSpeedKmHour(), "TRACK")
        s.progressState = "disarmed"
        s.progressSince = 0
        s.resumeProgressPhase, s.resumeProgressUntil = nil, 0
        s.routeFarSince = 0 -- 讓位前的離線計時不帶過來（Drive.routeFarWatch）
        haloGood(player, "UI_MinidoracatAutoDrive_Resume")
        if now - s.yieldSinceMs >= TUNE.YIELD_VOICE_MS then voice("resume", playerNum) end
        -- 讓位期間換過路線（cutover 保留 yield）：新 profile 還沒 build 完就先走 build
        -- 幀，否則 stepFollow 會拿到 ready=false 的剖面；已 ready 的當幀直接跟線。
        if s.profile.ready ~= true then
            s.mode = "build"
            return
        end
        s.mode = "follow"
    end

    -- 樹叢阻力抵消（Drive.bushCancel）：跟線、繞行與倒車都要；讓位（玩家自己開）在上面就 return 了
    Drive.bushCancel(s, vehicle, now)

    -- Reverse recovery and its settle phase bypass normal follow control. Manual input
    -- already yielded above, so neither path can fight the player.
    if s.mode == "unstick" or s.mode == "settle" then
        stepUnstick(s, vehicle, playerNum, now)
        if s.brakeTerminalFault then Drive.stop(playerNum, KEY_UNSUPPORTED) end
        return
    end

    -- 離線過遠（TUNE.ROUTE_FAR_MS）：主 MOD 沒接上新路線就交還，不越野追線
    if Drive.routeFarWatch(s, now) then
        Drive.stop(playerNum, KEY_ROUTE_FAR)
        return
    end
    -- now 是這一幀早先取的 getTimestampMs()（路線節流共用）：遙測節流不再多打一次
    stepFollow(s, vehicle, playerNum, now)
end

Events.OnPlayerUpdate.Add(onPlayerUpdate)

-- 回主選單時 OnPlayerUpdate 已不可靠；主動收掉 drive state 與 telemetry writer。
-- Diagnostics 也有自己的同事件保險，兩邊 stop 都是冪等。
local function onMainMenuEnter()
    if cancelPendingPause then cancelPendingPause() end
    -- 準備意圖也一起收：角色／世界切換由 MiniMap 的生命週期清理撤銷 claim
    -- （此時 release 只會回 stale），這裡只丟掉本機意圖，不碰新角色。
    for playerNum = 0, 3 do
        TRIP.drop(playerNum)
        if TRIP.owed[playerNum] then
            TRIP.owed[playerNum] = nil
            prepCount = prepCount - 1
        end
    end
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
