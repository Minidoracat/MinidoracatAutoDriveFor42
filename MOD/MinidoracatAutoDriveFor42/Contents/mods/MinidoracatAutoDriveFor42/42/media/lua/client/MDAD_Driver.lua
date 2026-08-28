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
-- MP 現實（M3 不做伺服器狀態，刻意的）：
--   物理只在非 dedicated server 端跑（Bullet.addVehicle 僅 !GameServer.server＝
--   CarController.java:86；impulse 套用同樣 !GameServer.server＝BaseVehicle.java:3308），
--   權威在**駕駛自己的 client**。因此自駕狀態只活在駕駛端記憶體：斷線／死亡／下車
--   由本檔的早退條件自然收斂，不需要（也沒有）伺服器端的玩家離線 Lua 事件
--   （GameServer.disconnectPlayer:2590 不 triggerEvent；Events.OnDisconnect 是本機
--   連線失敗，不是「某人離開伺服器」）。
--
-- 電力（M3 契約）：自駕只在引擎運轉中才能啟動，運轉中由發電機供電——與原版收音機
--   「引擎運轉不耗車電」同款處理（Vehicles.lua:683-686）。M3 因此**不呼叫**
--   MDAD.consumeVehiclePower、不建伺服器 AutoState 表，實際車電扣除留待後續里程碑；
--   但每幀仍檢查電瓶還活著（isBatteryLive），電瓶死了就交還控制權。

require "MDAD"
require "MDAD_Follower"
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

--------------------------------------------------------------------------------
-- 調校常數
--------------------------------------------------------------------------------

local ROUTE_REFRESH_MS = 250   -- 導航目標／路線刷新節流（毫秒）
local BUILD_BUDGET = 128       -- 每幀限速剖面建構點數上限
local MAX_SESSIONS = 4         -- 分割畫面本機玩家槽上限（getSpecificPlayer 0-3）
local CLEAN_FRAMES = 10        -- 讓位後要連續幾幀沒有玩家輸入才恢復跟線
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

-- 回 route（唯讀本體，主 MOD 的 cache）或 nil。route 物件的 identity 就是版本號：
-- 主 MOD 重算路線時會產生新 table（ensureRoute→findRoute 新建，
-- MinidoracatMiniMap_NavRoute.lua:1181-1186），沿用時回同一顆。
local function fetchRoute(api, playerNum)
    local tx, ty = api.getNavTarget(playerNum)
    if not tx then return nil end
    local route, state = api.requestRoute(playerNum, tx, ty)
    if not route or state ~= "ok" then return nil end
    return route
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

local function clearSession(playerNum)
    if sessions[playerNum] == nil then return end
    sessions[playerNum] = nil
    sessionCount = sessionCount - 1
end

-- 停止＝只關 regulator，**不搶煞車**：停止的原因多半是玩家要自己接手（讓位逾時、下車、
-- 換車），這時候突然硬煞比放手更危險。到達停車的煞車是 arrive 分支自己做的。
-- regulator 是我們開的就由我們關：即使玩家已經不在車上（下車／換車），仍然關掉，
-- 否則那台車會留著一個沒人設過的定速，下一個上車的人莫名其妙就被拉速度。
function Drive.stop(playerNum, reasonKey)
    local s = sessions[playerNum]
    if not s then return false end
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
    local route = fetchRoute(api, playerNum)
    if not route then return KEY_ROUTE end
    local maxSpeed = maxSpeedKmh()
    local profile = MDADFollower.begin(route, maxSpeed)
    if not profile then return KEY_ROUTE end
    local fstate = nil
    if type(MDADFollower.newState) == "function" then fstate = MDADFollower.newState() end
    if type(fstate) ~= "table" then fstate = {} end
    -- 所有閘門都過了才動玩家的車：先把 regulator 關掉一次。剖面要分幀建（長路線
    -- 七八幀），這段期間 stepFollow 根本不會跑，玩家上車前自己設的定速（或上一位
    -- 駕駛留下的）就會原封不動繼續拉著車跑——啟動自駕的下一秒車子照舊速衝出去。
    -- 失敗的啟動一律走上面的 early return，不會碰到這行，玩家的定速保持原狀。
    vehicle:setRegulator(false)
    sessions[playerNum] = {
        vehicle = vehicle,
        route = route,
        profile = profile,
        fstate = fstate,
        maxSpeed = maxSpeed,
        mode = "build",  -- build → follow ⇄ yield → arrive
        nextRouteMs = getTimestampMs() + ROUTE_REFRESH_MS,
        nextDebugMs = 0, -- 下一次允許印跟線遙測的時間戳（0＝第一幀就印）
        cleanFrames = 0,
        parity = 1,
        yieldNotified = false,
        stuckSince = 0,  -- 0＝目前不在「疑似卡死」狀態；非 0＝開始凍結的時間戳
        stuckErr = 0,    -- 疑似卡死起點的航向誤差（弧度）
        stuckRem = 0,    -- 疑似卡死起點的沿線剩餘距離（公尺）
    }
    sessionCount = sessionCount + 1
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
local function applySteering(s, vehicle, fwd, fx, fy, steer, speedKmh, mult)
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
    impulse:set(force * px, 0, force * py)
    fwd:set(-REAR_ARM * fx + parity * LATERAL_JITTER * px, 0,
        -REAR_ARM * fy + parity * LATERAL_JITTER * py)
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
    -- setRegulator／setRegulatorSpeed＝BaseVehicle.java:9821-9831；
    -- regulator 開著且現速低於設定速時 CarController 才供油（CarController.java:240-245）
    vehicle:setRegulator(true)
    vehicle:setRegulatorSpeed(targetSpeed)
    return true
end

local function stepFollow(s, vehicle, playerNum, now)
    local speedKmh = vehicle:getCurrentSpeedKmHour() -- 可負（倒車）＝BaseVehicle.java:4268
    local mult = getGameTime():getMultiplier()
    if mult < MULT_MIN then mult = MULT_MIN end
    if mult > MULT_MAX then mult = MULT_MAX end

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
        -- control 回 steer, targetSpeed, remaining, reached, headingError
        local steer, targetSpeed, remaining, done, headingError = MDADFollower.control(
            s.profile, s.fstate, vehicle:getX(), vehicle:getY(),
            MDADFollower.headingFromForward(fx, fy), speedKmh, mult * SECONDS_PER_MULT)
        reached = done == true
        local regOn = applySpeed(s, vehicle, targetSpeed, speedKmh)
        local force = 0
        if not reached then
            force = applySteering(s, vehicle, fwd, fx, fy, steer or 0, speedKmh, mult)
        end
        -- 跟線遙測：每秒最多一行。實機要判斷「轉不動」是誤差沒算出來、還是力太小，
        -- 只有同一行同時看到 errDeg 與 force 才分得開。旗標為假時整段完全不執行，
        -- 連字串都不會生成——這裡是每幀熱路徑。
        if getDebug() and now >= s.nextDebugMs then
            s.nextDebugMs = now + DEBUG_MS
            print(string.format(
                "%spn=%d mode=%s speed=%.1f target=%.1f errDeg=%.1f steer=%.2f force=%.0f remaining=%.1f regulator=%s",
                LOG, playerNum, s.mode, speedKmh, targetSpeed or 0,
                (headingError or 0) * DEG_PER_RAD, steer or 0, force, remaining or 0,
                tostring(regOn)))
        end
        -- ---- 卡死偵測 ----
        -- 三個觀測都凍結才累計：|速度| < STUCK_SPEED_KMH、沿線進度變化 < STUCK_REM_EPS、
        -- 航向變化 < STUCK_ERR_EPS。原地調頭時速度近零但航向在動、末段挪車時 remaining
        -- 在動、煞停途中 remaining 也在動，都會不斷重置計時；headingError 在 ±pi 跳變
        -- （調頭穿過正後方）時差值巨大，同樣走重置——誤差方向永遠是「不誤停」。
        local moving = speedKmh > STUCK_SPEED_KMH or speedKmh < -STUCK_SPEED_KMH
        if reached or moving then
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
    end
    BaseVehicle.releaseVector3f(fwd)

    -- 卡死＝自動停車＋紅字（池向量已歸還才走到這裡）。Drive.stop 只關 regulator、
    -- 不硬煞——卡死時車本來就不動，玩家倒車脫困時也不會被搶煞車。
    if stuck then
        Drive.stop(playerNum, KEY_STUCK)
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
    local now = getTimestampMs()
    if now >= s.nextRouteMs then
        s.nextRouteMs = now + ROUTE_REFRESH_MS
        local route = fetchRoute(api, playerNum)
        if not route then
            Drive.stop(playerNum, KEY_LOST)
            return
        end
        if route ~= s.route then
            local profile = MDADFollower.begin(route, s.maxSpeed)
            if not profile then
                Drive.stop(playerNum, KEY_LOST)
                return
            end
            s.route = route
            s.profile = profile
            s.mode = "build"
            if type(MDADFollower.resetState) == "function" then MDADFollower.resetState(s.fstate) end
            -- 重建期間沒有速度剖面可用，先鬆油門讓車滑行（不煞車：剖面通常一兩幀就好）
            vehicle:setRegulator(false)
        end
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
        s.cleanFrames = 0
        return
    end
    if s.mode == "yield" then
        s.cleanFrames = s.cleanFrames + 1
        if s.cleanFrames < CLEAN_FRAMES then return end
        s.cleanFrames = 0
        s.mode = "follow"
    end

    -- now 是這一幀早先取的 getTimestampMs()（路線節流共用）：遙測節流不再多打一次
    stepFollow(s, vehicle, playerNum, now)
end

Events.OnPlayerUpdate.Add(onPlayerUpdate)

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
end
