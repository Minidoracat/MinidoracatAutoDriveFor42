-- MDAD_Corridor.lua — 繞行縫隙規劃與 current-pose 車身守門：純數學，不碰任何 PZ API。
--
-- 這個檔案裡沒有 getGridSquare、沒有 vehicle、沒有 SandboxVars、沒有 Events、
-- 沒有 userdata。輸入全是純量與扁平陣列，輸出也全是純量。
-- 理由與 shared/MDAD_Follower.lua 同一套：
--   1. 離線可測：scripts/test_corridor.lua 直接 loadfile 本檔就能跑完整情境，
--      不需要任何假全域。縫隙判定算錯在遊戲裡的表徵是「車擦著障礙開過去」，
--      那種回歸靠肉眼看不出是「膨脹半徑漏加車寬」還是「群聚合把遠障礙拉進來」。
--   2. 職責邊界清楚：感知（client/MDAD_Sensor）負責把世界掃成扁平點集，
--      本模組只做縫隙規劃與「目前車身是否已碰到點集」的純幾何判定。
--
-- ---------------------------------------------------------------------------
-- 介面契約（感知層與 driver 依此接線，勿在此處加入 PZ 相依）
-- ---------------------------------------------------------------------------
-- MDADCorridor.plan(hardS, hardL, hardN, needHalf, corridorHalf, preferL?, hardR?, baseL?, roadLo?, roadHi?, refineComfort?)
--     hardS, hardL ＝ 硬障礙點的扁平陣列（**兩條平行陣列**，第 i 點＝hardS[i], hardL[i]）。
--                    hardS[i] ＝ 該點投影到路線的弧長 s（公尺，與 follower 的 profile.s 同一空間）。
--                    hardL[i] ＝ 橫向偏移 l（公尺；PZ 世界 Y 向南，數學 CCW 法向＝行進方向右側，故正號＝右）。
--                    **本模組視兩條陣列為唯讀**，不寫、不排序、不複製。
--     hardN        ＝ 有效筆數。感知層的 buffer 會重用，所以筆數是參數而不是 #hardS。
--     needHalf     ＝ 車半寬 ＋ 安全 margin（典型 1.4）。非有限正數 → 預設 1.4。
--     corridorHalf ＝ 走廊半寬（典型 3.0，即 6 公尺道寬）。非有限正數 → 預設 3.0。
--     preferL       ＝ 候選搜尋中心（選填）；按實際橫移距離選最近可行 lane。
--                     非有限數 → 0；只改搜尋順序，不改候選集與淨空門檻。
--     hardR         ＝ 逐點障礙半徑平行陣列（選填）；壞值保守回落 OBS_HALF。
--     baseL         ＝ 實際行駛基準線（選填）；擋線判定以它為中心。
--     roadLo/roadHi ＝ 路面帶邊界（選填）；有帶內縫時不為 comfort 偏到帶外。
--     refineComfort ＝ 是否在 safe lane 同側找額外餘裕（選填，預設 true）。
--                     false 保留原 first-safe lane，供 ban 後重規劃（物理推撞 ban
--                     與 world-sweep 候選枚舉）使用，避免又走回剛否決的縫。
--     筆數防呆：hardN 非有限非負整數、hardS／hardL 不是 table、或 1..hardN 之間
--               **任一格缺項／非有限數** → 整批不信，fail-safe 回 "blocked"；
--               只有合法的 hardN == 0 才回 "clear"。缺項代表呼叫端 buffer 沒填滿
--               或掃描中途被打斷，此時前半段資料的「沒有障礙」也不可信，逐點跳過
--               只會生出一份看似完整、其實有洞的規劃。
--
--     回 mode, a, b, c, d, offL（六個純量，恆非 nil）
--       mode ＝ "clear"   沒有任何障礙擋住 baseL 行駛基準線。a..offL 全為 0。
--       mode ＝ "dodge"   找到縫隙。四個斷點是側偏剖面的 s 座標（絕對弧長）：
--                         a  開始離開呼叫端的 baseline（通常是 laneBias）
--                         b  側移到位（此後 offset 恆為 offL）
--                         c  開始回歸
--                         d  回歸完成（此後回到呼叫端 baseline）
--                         恆滿足 a < b <= c < d；offL ＝ 保持段的橫向偏移（正號＝右）。
--       mode ＝ "blocked" 走廊內沒有任何可行縫隙。此時
--                         a ＝ b ＝ 障礙群起點 sObs0（呼叫端據此算煞停距離），
--                         c ＝ d ＝ 障礙群終點 sObs1，offL ＝ 0。
--
--     **零 table 配置**：不建陣列、不建 closure、多回傳值走 Lua 堆疊。
--     "clear"／"dodge"／"blocked" 是 chunk 的常數字串，也不配置。
--
-- MDADCorridor.currentFootprintHit(
--     hardS, hardL, hardX, hardY, hardR, hardN,
--     bodyX, bodyY, vehicleH, halfW, halfL, expectedLane)
--     ＝ expected-path planner 之外的 current-body OR-gate；不改 plan() 的 baseline。
--       位置一律以世界座標 hardX／hardY 為權威（Sensor 永遠成對配置）；
--       陣列缺失、table 內有洞、或任一必要純量非有限時，保守回 blocked。
--     bodyX/bodyY ＝車身 OBB 中心；halfW/halfL ＝ script extents 的一半。
--       呼叫端應用 vehicle:getWorldPos(COM offset) 算中心；PZ 原生碰撞多邊形同樣以
--       COM transform 與 extents 建四角（zombie/vehicles/VehiclePoly.java:52-88）。
--     點視為半徑 hardR+0.15 的 disk；0.15m 與原生擴張 poly 的安全圈一致
--       （zombie/vehicles/BaseVehicle.java:4133-4168）。
--     回 blocked, actualClearance, plannedClearance, hitIndex, hitS, hitL, hitX, hitY,
--       poseOnly（九個純量，恆非 nil）。actualClearance 取全部點的最小
--       rectangle-vs-disk 淨空；plannedClearance 是同一點對 expectedLane 的橫向淨空。
--       blocked iff actualClearance <= 0；poseOnly iff blocked 且 plannedClearance > 0。
--       合法 hardN==0 回 false 與八個 0/false；壞 snapshot 回 true、hitIndex=0，
--       讓呼叫端能 fail-closed 又不把資料破損誤記成真實障礙。
--     **零 table 配置且唯讀**：不建陣列、不改任何輸入，只回多個純量。
--
-- ---------------------------------------------------------------------------
-- plan() 演算法（四步；為什麼是這四步）
-- ---------------------------------------------------------------------------
-- ① 擋行駛線篩選：把車半寬一次性膨脹進障礙，淨空門檻 clr ＝ 點半徑 + needHalf。
--    |l - baseL| < clr 才算擋線。全部沒有 → "clear"。
--    膨脹（Minkowski sum）做在這裡的好處：之後所有判定都退化成「點可行性」，
--    不必在縫隙寬度、車寬、障礙寬之間反覆換算——那正是這類程式最會寫錯的地方。
--
-- ② 最近障礙群：取擋線障礙中 s 最小者為錨，把 s 距離 GROUP_GAP（6 公尺）內的
--    擋線障礙逐一拉進群，群邊界可再擴張（鏈式）。得 [sObs0, sObs1]。
--    為什麼要「群」而不是逐一障礙：一排路障、一列拋錨車是**一個**障礙事件，
--    逐一繞行會生出 S 形的來回側移（進入-回歸-進入-回歸），實機表現是車在障礙
--    之間左右甩。群聚合把它們合成一段「持續側偏」。
--    不排序（Kahlua 的 table.sort 是遞迴 quicksort，已排序輸入會退化成 O(n) 深度、
--    數百筆就爆 coroutine 堆疊；AGENTS.md 鐵則），改用多輪線性掃描直到邊界不再
--    擴張，輪數上限 ROUNDS_MAX ＝ 8。輸入若是 s 遞增（感知層的自然輸出）一輪就收；
--    最壞排序下 8 輪只能串 8 節，群被截短的後果僅是「繞行段偏短」，而繞行是事件
--    驅動的——下一輪掃描會用新的錨再算一次。
--
-- ③ safe 縫隙搜尋：在群的 s 範圍（各向擴張 OBS_HALF）內，取**全部**硬障礙
--    （含不擋中心線的），因為決定縫隙邊界的正是那些側邊障礙。可行的 l 必須與
--    每個點都保持 clr 的橫向距離。在
--    [-(corridorHalf - needHalf), corridorHalf - needHalf] 內用固定步長
--    STEP＝0.25 的格點線性掃描；候選集錨在 l＝0，搜尋順序依與 preferL 的實際
--    距離由近而遠。完全等距時偏左。找到第一條 safe lane；找不到 → "blocked"。
--    格點錨在 0 讓左右候選集完全對稱；代價是走廊邊緣最後不到 0.25 公尺的縫隙
--    掃不到——那種縫吃不下感知誤差，不要也罷。
--
-- ④ comfort refinement：first-safe 的格點殘差只有 0.10..0.35m，若直接映射
--    sweep margin，正常寬縫也會被系統性壓到約 12..16 km/h。保留已選側別與
--    路面優先級，最多再往同側外推 3 格（0.75m），取第一條達
--    needHalf + COMFORT_EXTRA 的 lane；沒有就逐位元回傳原 safe lane。不是
--    max-margin 搜尋，不會一路跑到走廊／人行道邊緣；offL == preferL 無既有
--    側別時，refinement 固定往正側（右）嘗試。
--
-- 明確不做（規劃書 D6 §2.4）：同倫類枚舉、elastic band 迭代、動態障礙重規劃、
-- 倒車規劃。理由不是難寫，是**每幀全軌跡優化的成本吃掉整個 0.5ms 預算**，而
-- 「一次側偏繞開靜止障礙」已經涵蓋實機 95% 的情況；剩下的 5% 走保守 fallback
-- （減速停車請玩家接管）遠比一份算不完的最佳軌跡安全。
--
-- 已知殘留（誠實面對，別在此處偷偷擴大範圍）：
-- * 縫隙只在障礙群的 s 範圍內判定。落在 b..c 之外、a..b／c..d 這兩段 2 公尺
--   進退區間裡的**不擋線**障礙，不參與 offL 的可行性——它們在側移過程中理論上
--   可能被擦到。真正擋線的那些不受影響（GROUP_GAP ＝ 6 > GAP ＝ 2，早被拉進群）。
--   把窗口開到 [a, d] 會讓遠處的路肩障礙否決掉眼前這條真的過得去的縫。
-- * plan() 不知道車現在在哪（沒有 sNow）：s 一律當「路線絕對弧長」，只餵前方點
--   是呼叫端的責任。a 夾在 >= 0（路線起點）只是防呆，不是「車後方」的語意。
--
-- 效能守則（Kahlua）：庫函式都是 JavaFunction，每次呼叫都跨 Lua↔Java 邊界。
-- 因此 type／math.floor 在載入期取成 local upvalue；絕對值一律用 `if v < 0 then
-- v = -v end`、夾限一律用純 Lua 比較，全程不呼叫 math.abs／math.min／math.max。
-- 整個 plan() 只剩最多兩次 floor 跨界（筆數整數檢查、格點上限），其餘純算術。

MDADCorridor = MDADCorridor or {}

-- type 刻意走全域（不取 `local type = type`）：plan 是事件驅動、每次呼叫 type 至多
-- 2n+4 次，跨界成本無感；而 self-init 寫法會被 check_lua_bindings 的前向引用掃描
-- 誤判（bytecode 看到 GETGLOBAL 撞同名 local）。floor 從 math 表取不受影響。
local floor = math.floor
local sqrt, cos, sin = math.sqrt, math.cos, math.sin

local OBS_HALF = 0.7              -- 障礙格半寬（公尺）：B42 一格 1 公尺，取略小於半格
local FOOTPRINT_PAD = 0.15        -- current body 對點障礙的固定安全圈（見介面契約來源）
local GROUP_GAP = 6               -- 群聚合的 s 間距上限（公尺）
local ROUNDS_MAX = 8              -- 群邊界擴張的輪數上限（見上方 ② 的說明）
local ENTRY = 8                   -- 進入段長度（公尺）：a = sObs0 - ENTRY
local EXIT = 8                    -- 回歸段長度（公尺）：d = sObs1 + EXIT
local GAP = 2                     -- 障礙前後的保持餘裕（公尺）：b = sObs0 - GAP、c = sObs1 + GAP
local MIN_SEG = 2                 -- 進入／回歸段的最小長度（障礙就在眼前時的下限）
local STEP = 0.25                 -- 橫向格點步長（公尺）
local COMFORT_EXTRA = 0.7         -- 淨空加碼；含 planner/sweep 的 0.1 差後，margin 可達 0.8
local NEED_HALF_DEFAULT = 1.4     -- needHalf 預設（車半寬 + margin）
local CORRIDOR_HALF_DEFAULT = 3.0 -- corridorHalf 預設（6 公尺道寬）

MDADCorridor.OBS_HALF = OBS_HALF
MDADCorridor.GROUP_GAP = GROUP_GAP
MDADCorridor.ROUNDS_MAX = ROUNDS_MAX
MDADCorridor.ENTRY = ENTRY
MDADCorridor.EXIT = EXIT
MDADCorridor.GAP = GAP
MDADCorridor.MIN_SEG = MIN_SEG
MDADCorridor.STEP = STEP
MDADCorridor.COMFORT_EXTRA = COMFORT_EXTRA
MDADCorridor.NEED_HALF_DEFAULT = NEED_HALF_DEFAULT
MDADCorridor.CORRIDOR_HALF_DEFAULT = CORRIDOR_HALF_DEFAULT

-- n * 0 == 0 一次擋掉 NaN 與 ±Inf（有限數乘 0 必為 0，這兩者乘 0 都是 NaN），
-- 不用 math.huge（Kahlua 未保證提供；shared/MDAD.lua 的 isFiniteInt 同一理由）
local function isFinitePos(n)
    if type(n) ~= "number" then return false end
    if n * 0 ~= 0 then return false end
    return n > 0
end

-- currentFootprintHit 的 fail-closed 出口。九個回傳值只在這裡寫一次：把字面值
-- 複製到九個檢查點時，任何一處漏一個 0 就是把「資料破損」靜靜回成「淨空」，
-- 而這個函式正是安全 OR-gate，回錯方向不會有第二道關卡攔得住。
local function footprintFailClosed()
    return true, 0, 0, 0, 0, 0, 0, 0, false
end

-- Prepared hot-loop helper: caller supplies normalized F and the already
-- transformed COM centre. No type checks, normalization, COM work or sqrt.
function MDADCorridor.orientedDistanceSqUnchecked(cx, cy, fx, fy, halfW, halfL,
        pointX, pointY)
    local dx, dy = pointX - cx, pointY - cy
    local u = dx * fx + dy * fy
    local v = -dx * fy + dy * fx
    if u < 0 then u = -u end
    if v < 0 then v = -v end
    u, v = u - halfL, v - halfW
    if u < 0 then u = 0 end
    if v < 0 then v = 0 end
    return u * u + v * v
end

-- 目前車身的 oriented rectangle 對 Sensor 點 disk。位置一律用世界座標
-- hardX／hardY，整組缺失或有洞直接 fail-closed。此函式是 plan() 之外的安全
-- OR-gate，不能拿感知快照覆寫 planner baseline。
function MDADCorridor.currentFootprintHit(hardS, hardL, hardX, hardY, hardR, hardN,
        bodyX, bodyY, vehicleH, halfW, halfL, expectedLane)
    if type(hardS) ~= "table" or type(hardL) ~= "table" or type(hardR) ~= "table"
        or type(hardX) ~= "table" or type(hardY) ~= "table"
        or type(hardN) ~= "number" or hardN * 0 ~= 0
        or hardN < 0 or floor(hardN) ~= hardN then
        return footprintFailClosed()
    end

    if type(bodyX) ~= "number" or bodyX * 0 ~= 0
        or type(bodyY) ~= "number" or bodyY * 0 ~= 0
        or type(vehicleH) ~= "number" or vehicleH * 0 ~= 0
        or type(halfW) ~= "number" or halfW * 0 ~= 0 or halfW <= 0
        or type(halfL) ~= "number" or halfL * 0 ~= 0 or halfL <= 0
        or type(expectedLane) ~= "number" or expectedLane * 0 ~= 0 then
        return footprintFailClosed()
    end

    local cv, sv = cos(vehicleH), sin(vehicleH)
    if cv * 0 ~= 0 or sv * 0 ~= 0 then
        return footprintFailClosed()
    end

    local bestClear, bestPlanned = 0, 0
    local bestI, bestS, bestL, bestX, bestY = 0, 0, 0, 0, 0
    for i = 1, hardN do
        local hs, hl, r = hardS[i], hardL[i], hardR[i]
        if type(hs) ~= "number" or hs * 0 ~= 0
            or type(hl) ~= "number" or hl * 0 ~= 0
            or type(r) ~= "number" or r * 0 ~= 0 or r < 0 then
            return footprintFailClosed()
        end

        local hx, hy = hardX[i], hardY[i]
        if type(hx) ~= "number" or hx * 0 ~= 0
            or type(hy) ~= "number" or hy * 0 ~= 0 then
            return footprintFailClosed()
        end
        local dx, dy = hx - bodyX, hy - bodyY
        local u = dx * cv + dy * sv
        local v = -dx * sv + dy * cv

        local au, av = u, v
        if au < 0 then au = -au end
        if av < 0 then av = -av end
        local du, dv = au - halfL, av - halfW
        if du < 0 then du = 0 end
        if dv < 0 then dv = 0 end
        local actual = sqrt(du * du + dv * dv) - (r + FOOTPRINT_PAD)
        local planned = hl - expectedLane
        if planned < 0 then planned = -planned end
        planned = planned - (halfW + r + FOOTPRINT_PAD)
        if actual * 0 ~= 0 or planned * 0 ~= 0 then
            return footprintFailClosed()
        end

        if bestI == 0 or actual < bestClear then
            bestClear, bestPlanned = actual, planned
            bestI, bestS, bestL, bestX, bestY = i, hs, hl, hx, hy
        end
    end

    if bestI == 0 then return false, 0, 0, 0, 0, 0, 0, 0, false end
    local blocked = bestClear <= 0
    return blocked, bestClear, bestPlanned, bestI, bestS, bestL, bestX, bestY,
        blocked and bestPlanned > 0
end

-- 候選 lane l 是否與 [sLo, sHi] 內每個硬障礙都保持「該點半徑＋needHalf」的
-- 橫向淨空。hardR＝逐點半徑（nil＝全部 OBS_HALF）：樹幹（r=0）與整格箱型物
-- （r=0.7）的危險帶差 0.7 公尺——統一肥半徑會把路緣樹排判成擋路、車長期
-- 貼對側路緣（2026-08-28 實機）。
-- 刻意「每個候選重掃一次輸入陣列」而不先把障礙收成區間表：建表就是配置，而
-- 繞行規劃是事件驅動（障礙集合變了才呼叫一次），(2*jMax+1) * hardN 次純算術
-- 比較（典型 13 * n，n 是感知 buffer 的筆數上限）比一次 table 配置便宜得多。
local function laneFree(hardS, hardL, hardR, hardN, sLo, sHi, l, needHalf)
    for i = 1, hardN do
        local s = hardS[i]
        if s >= sLo and s <= sHi then
            local d = l - hardL[i]
            if d < 0 then d = -d end
            local r = hardR and hardR[i] or OBS_HALF
            if type(r) ~= "number" or r ~= r or r < 0 then r = OBS_HALF end
            if d < r + needHalf then return false end
        end
    end
    return true
end

-- 規劃入口。零配置：只讀入來的兩條陣列，只回純量。
-- preferL（選填）＝縫隙掃描的中心，「距 preferL 最近的可行 lane」優先（而不是
-- 「距中線最近」）。呼叫端的兩種用法：
--   繞行中傳上輪側偏——感知層的 l 記錄有 ±0.5 的量化跳動，同一顆障礙在連續
--   掃描輪之間可能換記錄側、讓可行縫隙整個翻面——沿用上輪側別就不左右震盪；
--   首次繞行傳當前 laneBias（靠右偏移）——「離現在實際行駛線橫移最小的縫」
--   才是最優縫；以中心線為基準會在障礙居中時左右對稱、tie-break 固定選左，
--   車得先橫跨整個 bias 才進縫（2026-08-28 實機：靠右行駛卻每次往左繞）。
-- 隱含前提：呼叫端傳入的 hardS/hardL 必須涵蓋 corridorHalf 的完整橫向帶
-- （Sensor 的掃描帶 ±4 公尺 ＝ CORRIDOR_HALF；把任一邊調大前先對齊另一邊，
-- 否則會規劃到從未掃描過的區域）。
-- hardR（選填）＝逐點半徑平行陣列：樹幹 0、整格箱型物 OBS_HALF。非 table 或
-- 缺項／壞值＝該點退 OBS_HALF（保守肥半徑），不整批拒收。
-- baseL（選填）＝**行駛基準線**（呼叫端的常駐 laneBias）。擋線與群聚合以它為
-- 中心判定：車實際走「中心線＋bias」，障礙擋不擋「那條線」才是要不要繞的
-- 判準——以中心線判會漏掉「不擋中線但擋行駛線」的路緣樹，車直接蹭上卡死
-- （2026-08-28 實機：lat=1.2 完美跟線、hardN=2 不擋線、speed=0 卡死 ×3）。
-- 縫隙搜尋的**可行域與順序不受 baseL 影響**（全寬掃、以 preferL 排序）。
-- 非有限數＝0（向後相容：舊呼叫以中心線判）。
-- roadLo／roadHi（選填）＝路面帶邊界（相對中心線；Sensor 的地板 sprite 統計）。
-- 縫隙搜尋改**兩遍**：第一遍只接受「車中心落在路面帶內」的候選，一個都沒有
-- 才放開第二遍全域——繞出路面（草地）是最後手段，不是與路面縫平權的選項
-- 壞值／反向邊界視為無帶資訊，直接走單遍全域；不讓壞資料把所有候選排除。
-- 2026-08-28 實機：右樹排曾把縫逼到左外 3.5m，帶內優先修正車繞上草地。
-- refineComfort=false 時停在 first-safe lane；driver 的 world-sweep ban 重試必用此模式。
function MDADCorridor.plan(hardS, hardL, hardN, needHalf, corridorHalf, preferL, hardR, baseL,
        roadLo, roadHi, refineComfort)
    if type(hardR) ~= "table" then hardR = nil end
    if type(baseL) ~= "number" or baseL * 0 ~= 0 then baseL = 0 end
    if not isFinitePos(needHalf) then needHalf = NEED_HALF_DEFAULT end
    if not isFinitePos(corridorHalf) then corridorHalf = CORRIDOR_HALF_DEFAULT end
    if type(preferL) ~= "number" or preferL * 0 ~= 0 then preferL = 0 end

    -- 筆數防呆：任何一項不對就整批回 blocked（fail-safe）。這裡曾經 fail-open
    -- 回 clear——「資料壞掉＝當作沒障礙」會讓已知存在的硬障礙被靜默降級成淨空，
    -- 呼叫端（driver）拿到 clear 會解除煞停直接開過去；壞資料該讓車停下來等
    -- 下一輪好資料，而不是賭它是空的（M4 review）。
    local n = 0
    local valid = false
    if type(hardS) == "table" and type(hardL) == "table"
        and type(hardN) == "number" and hardN * 0 == 0
        and hardN >= 0 and floor(hardN) == hardN then
        n = hardN
        valid = true
        for i = 1, n do
            local s, l = hardS[i], hardL[i]
            if type(s) ~= "number" or s * 0 ~= 0
                or type(l) ~= "number" or l * 0 ~= 0 then
                valid = false
                break
            end
        end
    end
    if not valid then return "blocked", 0, 0, 0, 0, 0 end
    if n == 0 then return "clear", 0, 0, 0, 0, 0 end

    -- 逐點把「該點半徑＋車半寬」膨脹進障礙：之後所有判定都是「點可行性」。
    -- 統一肥半徑（OBS_HALF）曾把路緣樹排判成擋路（樹幹實際 ~0.3 格）。
    -- 半徑判定 inline 展開（laneFree 同款）：plan 是零配置契約，不建 closure。

    -- ① 擋行駛線篩選 ＋ 取錨（擋線障礙中 s 最小者）：以 baseL（行駛基準線）
    -- 為中心——障礙擋不擋「車實際要走的那條線」才是要不要繞的判準
    local sObs0 = nil
    for i = 1, n do
        local l = hardL[i] - baseL
        if l < 0 then l = -l end
        local r = hardR and hardR[i] or OBS_HALF
        if type(r) ~= "number" or r ~= r or r < 0 then r = OBS_HALF end
        if l < r + needHalf then
            local s = hardS[i]
            if sObs0 == nil or s < sObs0 then sObs0 = s end
        end
    end
    if sObs0 == nil then return "clear", 0, 0, 0, 0, 0 end

    -- ② 最近障礙群：多輪線性掃描擴張 [sObs0, sObs1]，不排序
    local sObs1 = sObs0
    local grown = false
    for _ = 1, ROUNDS_MAX do
        grown = false
        -- 邊界即時生效（不在輪首快照）：s 遞增的輸入（感知層的自然輸出）一輪就收
        for i = 1, n do
            local l = hardL[i] - baseL
            if l < 0 then l = -l end
            local r = hardR and hardR[i] or OBS_HALF
            if type(r) ~= "number" or r ~= r or r < 0 then r = OBS_HALF end
            if l < r + needHalf then
                local s = hardS[i]
                if s >= sObs0 - GROUP_GAP and s <= sObs1 + GROUP_GAP then
                    if s < sObs0 then
                        sObs0 = s
                        grown = true
                    end
                    if s > sObs1 then
                        sObs1 = s
                        grown = true
                    end
                end
            end
        end
        if not grown then break end
    end
    -- 輪數用盡仍在成長＝群邊界沒收斂（極端亂序輸入），截短的群會漏掉群尾障礙、
    -- 算出擦撞剖面——fail-safe 回 blocked，等下一輪（感知層天然輸出遞增，一輪
    -- 就收斂；這條只防契約允許的最壞排序）
    if grown then return "blocked", sObs0, sObs0, sObs1, sObs1, 0 end

    -- ③ 縫隙搜尋：群的 s 範圍內取全部硬障礙。候選格點錨在 0、以 preferL 為
    -- 中心由近而遠掃。**符號慣例**：l 的數學正向（CCW 法向）在 PZ 世界（Y 向南）
    -- 是行進方向的**右側**。preferL=0 的同距 tie-break 先試**負側**＝實際左側
    -- ——1993 肯塔基右側通行，超車走左。
    local sLo, sHi = sObs0 - OBS_HALF, sObs1 + OBS_HALF
    local limit = corridorHalf - needHalf   -- lane 中心的可用半幅
    local offL = nil
    local foundPass = 0
    -- 路面帶有效性：任一邊壞值或帶寬非正＝無路面資訊，直接單遍全域。
    local roadOK = type(roadLo) == "number" and roadLo * 0 == 0
        and type(roadHi) == "number" and roadHi * 0 == 0 and roadLo < roadHi
    if limit >= 0 then
        local jMax = floor(limit / STEP)
        -- 取離 preferL 最近的格點；恰在兩格中點時取較小 l（實際左側）。
        -- 候選集不變，只有掃描順序改變。
        local scaled = preferL / STEP
        local pj = floor(scaled)
        if scaled - pj > 0.5 then pj = pj + 1 end
        if pj > jMax then pj = jMax end
        if pj < -jMax then pj = -jMax end
        -- preferL 若落在 pj 格點右側，同半徑先試右候選；落在左側或正好重合，
        -- 先試左候選。非 STEP 倍數按真實距離選最近縫，完全等距才偏左。
        local firstSign = -1
        if preferL > pj * STEP then firstSign = 1 end
        -- 兩遍掃描：pass 1 只收路面帶內的候選（無路面資訊直接從 pass 2 開始）；
        -- pass 1 落空才放開全域。帶內候選在 pass 2 會重驗一次 laneFree——事件
        -- 驅動的重複算術比記錄狀態便宜（零配置契約）。
        for pass = (roadOK and 1 or 2), 2 do
            for r = 0, 2 * jMax do
                local j = pj + firstSign * r
                if j >= -jMax and j <= jMax then
                    local cand = j * STEP
                    if (pass == 2 or (cand >= roadLo and cand <= roadHi))
                        and laneFree(hardS, hardL, hardR, n, sLo, sHi, cand, needHalf) then
                        offL = cand
                        foundPass = pass
                        break
                    end
                end
                if r > 0 then
                    j = pj - firstSign * r
                    if j >= -jMax and j <= jMax then
                        local cand = j * STEP
                        if (pass == 2 or (cand >= roadLo and cand <= roadHi))
                            and laneFree(hardS, hardL, hardR, n, sLo, sHi, cand, needHalf) then
                            offL = cand
                            foundPass = pass
                            break
                        end
                    end
                end
            end
            if offL ~= nil then break end
        end
    end
    -- first-feasible 只多出 0.10..0.35m 的格點殘差，若直接拿它映射速度，所有
    -- 正常繞行都只剩 12..16 km/h。保留最近 safe lane 的側別，最多外推 3 格
    -- （0.75m）找第一條 comfort lane；相等於 preferL 時固定往正側，找不到回原 lane。
    if offL ~= nil and refineComfort ~= false then
        local dir = offL < preferL and -1 or 1
        local safeL = offL
        for k = 1, 3 do
            local cand = safeL + dir * k * STEP
            if cand < -limit or cand > limit then break end
            if foundPass == 1 and (cand < roadLo or cand > roadHi) then break end
            if laneFree(hardS, hardL, hardR, n, sLo, sHi, cand,
                    needHalf + COMFORT_EXTRA) then
                offL = cand
                break
            end
        end
    end
    if offL == nil then
        -- 沒有縫隙：把群的 s 範圍回給呼叫端算煞停距離（保守 fallback）
        return "blocked", sObs0, sObs0, sObs1, sObs1, 0
    end

    -- ④ 側偏剖面的四個斷點。夾限順序保證 a < b <= c < d 恆成立（MIN_SEG > 0）：
    -- 障礙就在眼前（sObs0 < ENTRY）時進入段被壓到 MIN_SEG，b 甚至可能落在 sObs0
    -- 之後——那代表「來不及完全側移」，呼叫端該同時降速；規劃器不假裝辦得到。
    local a = sObs0 - ENTRY
    if a < 0 then a = 0 end
    local b = sObs0 - GAP
    if b < a + MIN_SEG then b = a + MIN_SEG end
    local c = sObs1 + GAP
    if c < b then c = b end
    local d = sObs1 + EXIT
    if d < c + MIN_SEG then d = c + MIN_SEG end
    return "dodge", a, b, c, d, offL
end

-- ---------------------------------------------------------------------------
-- thread()：車陣蛇行（2026-09-02 使用者裁定「這麼多車沒辦法掃出一個地方鑽嗎」）
-- ---------------------------------------------------------------------------
-- plan() 只找「一條固定側偏、貫穿整個障礙群」的直線縫；一排錯落的拋錨車（6m 內
-- 串成一個 40m 群、hard 點橫跨整條 ±6.5m 掃描帶）沒有任何固定 lane 可行——實機
-- 表徵是 blocked→倒車重掃三次→StopStuck。thread 是 plan 判 blocked 之後的第二層：
-- 在 (s, l) 格點上找一條**斜率受限的折線**，第一台靠左過、第二台靠右過。
--
-- MDADCorridor.thread(hardS, hardL, hardR, hardN, needHalf, corridorHalf,
--     sFrom, laneFrom, sTo, halfL, halfW, baseL, roadLo, roadHi, work, outS, outL, maxNodes)
--   sFrom／laneFrom ＝ 車現在的弧長與橫向位置（折線從這裡起算，第一欄固定在 laneFrom）。
--   sTo             ＝ 折線終點弧長（呼叫端給 sObs1 + EXIT）。
--   halfL／halfW    ＝ 車半長／半寬（公尺）：每欄的可行性看「車身 s 窗」內的點，不是單點；
--                     s 窗＝halfL＋r＋(needHalf−halfW)，與 Driver sweepLine 的點半徑
--                     rr＝r＋pad（pad＝need−halfW）同源——窗少算 pad 就是「DP 說過得去、
--                     世界掃掠在群尾打槍」（harness (c6) 第一版）。halfW 缺＝pad 0。
--   baseL           ＝ 行駛基準線（終點偏好回到它；每欄離它越遠成本越高）。
--   roadLo／roadHi  ＝ 路面帶（選填）：帶外 lane 每欄加大額成本＝草地是最後手段
--                     （與 plan() 的兩遍語意同義，只是用成本表達）。
--   work            ＝ 呼叫端持有的工作表（一次配置、重用）：整數鍵 1.. 的扁平陣列，
--                     本函式只 rawset 數字，不建 table。需要 3×(欄數×lane 數) 格。
--   outS／outL      ＝ 輸出折線節點（呼叫端預配置），maxNodes＝容量。
--   回 nodeN, why, minExtra, maxSlope：
--     nodeN   ＝ 節點數（0＝無路，why 說明："band"／"start"／"nopath"／"badargs"／"capacity"）
--     minExtra＝ 折線每欄最小橫向淨空扣掉 needHalf 後的餘裕（公尺；速度帽用）
--     maxSlope＝ 折線最陡的 |Δl|/Δs
--
-- 演算法：欄距 THREAD_DS＝2m、lane 步 STEP＝0.25m。每欄每 lane 的可行性＝與「車身
-- s 窗 [s−halfL−r, s+halfL+r]」內每個點保持 r＋needHalf 的橫向淨空；斜行時車身
-- 橫向外露 ≈ halfL×斜率，故轉換邊按 |Δl| 分三檔加寬需求（直行 0／緩 ≤2 格／陡
-- ≤4 格），DP 走邊時用該檔的遮罩。遮罩用「逐點標記」建（每點只影響 ~3 欄 ×
-- ~14 lane），不做逐格對全點掃描——Kahlua 下 65 欄×47 lane×400 點是 120 萬次比較。
-- DP：cost(k,j)＝min over |j−j'|≤THREAD_SLOPE_J of cost(k−1,j')＋橫移成本＋離基準
-- 成本＋帶外成本；終欄再加「離基準」終端成本。回溯後把共線節點壓縮。
-- 世界空間 OBB 掃掠仍是唯一否決權（Driver sweepLine）：這裡只是提案。
local THREAD_DS = 2               -- 欄距（公尺）
local THREAD_COL_MAX = 64         -- 欄數上限（含起欄 65 欄＝128m）
local THREAD_SLOPE_J = 4          -- 相鄰欄最多換 4 格＝1m/2m（≈27°）
local THREAD_W_MOVE = 1.0         -- 每公尺橫移成本
local THREAD_W_BASE = 0.08        -- 每欄每公尺離基準成本
local THREAD_W_END = 2.0          -- 終欄每公尺離基準成本
local THREAD_W_OFFROAD = 20       -- 帶外 lane 每欄成本（草地＝最後手段）
local THREAD_INF = 1e9

MDADCorridor.THREAD_DS = THREAD_DS
MDADCorridor.THREAD_COL_MAX = THREAD_COL_MAX
MDADCorridor.THREAD_SLOPE_J = THREAD_SLOPE_J

-- 遮罩層數：0＝直行、1＝|dj|≤2、2＝|dj|≤4；各層的需求加寬＝halfL×斜率
local function threadLevelOf(dj)
    if dj < 0 then dj = -dj end
    if dj == 0 then return 0 end
    if dj <= 2 then return 1 end
    return 2
end

function MDADCorridor.thread(hardS, hardL, hardR, hardN, needHalf, corridorHalf,
        sFrom, laneFrom, sTo, halfL, halfW, baseL, roadLo, roadHi, work, outS, outL, maxNodes)
    if type(hardR) ~= "table" then hardR = nil end
    if not isFinitePos(needHalf) then needHalf = NEED_HALF_DEFAULT end
    if not isFinitePos(corridorHalf) then corridorHalf = CORRIDOR_HALF_DEFAULT end
    if not isFinitePos(halfL) then halfL = 2.2 end
    local pad = 0
    if isFinitePos(halfW) and needHalf > halfW then pad = needHalf - halfW end
    if type(baseL) ~= "number" or baseL * 0 ~= 0 then baseL = 0 end
    if type(laneFrom) ~= "number" or laneFrom * 0 ~= 0 then laneFrom = baseL end
    if type(work) ~= "table" or type(outS) ~= "table" or type(outL) ~= "table"
            or type(sFrom) ~= "number" or sFrom * 0 ~= 0
            or type(sTo) ~= "number" or sTo * 0 ~= 0 or sTo <= sFrom
            or type(maxNodes) ~= "number" or maxNodes < 2 then
        return 0, "badargs", 0, 0
    end
    local n = 0
    if type(hardS) == "table" and type(hardL) == "table"
        and type(hardN) == "number" and hardN * 0 == 0
        and hardN >= 0 and floor(hardN) == hardN then
        n = hardN
        for i = 1, n do
            local s, l = hardS[i], hardL[i]
            if type(s) ~= "number" or s * 0 ~= 0
                or type(l) ~= "number" or l * 0 ~= 0 then
                return 0, "badargs", 0, 0
            end
        end
    else
        return 0, "badargs", 0, 0
    end
    local limit = corridorHalf - needHalf
    -- 三種失敗分開命名（2026-09-02 s064：console 三種都印 "blocked"，復盤分不出
    -- 「車當下那格就不可行」與「真的沒路」，等於沒有診斷）：
    --   band   走廊寬度扣掉需求後放不下一格 lane
    --   start  起欄（車現在的 lane）被直行遮罩擋＝車已貼著障礙
    --   nopath DP 走遍終欄都不可達
    if limit < STEP then return 0, "band", 0, 0 end
    local jMax = floor(limit / STEP)
    local J = 2 * jMax + 1
    local span = (sTo - sFrom) / THREAD_DS
    local K = floor(span)
    if K < span then K = K + 1 end
    if K < 1 then K = 1 end
    if K > THREAD_COL_MAX then return 0, "capacity", 0, 0 end
    local cells = (K + 1) * J
    local roadOK = type(roadLo) == "number" and roadLo * 0 == 0
        and type(roadHi) == "number" and roadHi * 0 == 0 and roadLo < roadHi

    -- work 佈局：[1..cells]＝遮罩（位元：1 直行擋、2 緩擋、4 陡擋）、
    -- [cells+1..2cells]＝cost、[2cells+1..3cells]＝prev（前一欄的 j 索引，0＝無）
    local maskBase, costBase, prevBase = 0, cells, 2 * cells
    for idx = 1, cells do
        work[idx] = 0
        work[costBase + idx] = THREAD_INF
        work[prevBase + idx] = 0
    end
    -- 三層需求加寬：斜率 = dj×STEP / DS
    local extra1 = halfL * (2 * STEP / THREAD_DS)
    local extra2 = halfL * (THREAD_SLOPE_J * STEP / THREAD_DS)
    -- 逐點標記遮罩：點 i 影響 s 窗 [s−halfL−r, s+halfL+r] 覆蓋的欄；每欄把
    -- |l_j − l_i| < r + need 的 lane 標成擋（三層各自的 need）。
    for i = 1, n do
        local s, l = hardS[i], hardL[i]
        local r = hardR and hardR[i] or OBS_HALF
        if type(r) ~= "number" or r ~= r or r < 0 then r = OBS_HALF end
        local reach = halfL + r + pad
        -- 影響欄：|s_k − s| ≤ reach ⇔ k ∈ [ceil((s−reach−sFrom)/DS), floor((s+reach−sFrom)/DS)]
        local k0 = (s - reach - sFrom) / THREAD_DS
        local k1 = (s + reach - sFrom) / THREAD_DS
        local f0 = floor(k0)
        if f0 < k0 then f0 = f0 + 1 end
        k0 = f0
        if k0 < 0 then k0 = 0 end
        k1 = floor(k1)
        if k1 > K then k1 = K end
        if k0 <= k1 then
            for level = 0, 2 do
                local need = needHalf
                if level == 1 then need = needHalf + extra1
                elseif level == 2 then need = needHalf + extra2 end
                local clr = r + need
                local jLo = floor((l - clr) / STEP) + 1
                local jHi = floor((l + clr) / STEP)
                -- 邊界：|l_j − l| < clr 嚴格；格點恰在 clr 上算可行（與 laneFree 同）
                if (jHi * STEP) - l >= clr then jHi = jHi - 1 end
                if jLo < -jMax then jLo = -jMax end
                if jHi > jMax then jHi = jMax end
                if jLo <= jHi then
                    local bit = 1
                    if level == 1 then bit = 2 elseif level == 2 then bit = 4 end
                    for k = k0, k1 do
                        local rowBase = maskBase + k * J + jMax + 1
                        for j = jLo, jHi do
                            local idx = rowBase + j
                            local m = work[idx]
                            if m % (bit * 2) < bit then work[idx] = m + bit end
                        end
                    end
                end
            end
        end
    end

    -- DP。起欄：只有離 laneFrom 最近的格點成本 0（車就在那裡；直行遮罩必須可行）。
    local jStart = floor(laneFrom / STEP + 0.5)
    if jStart > jMax then jStart = jMax elseif jStart < -jMax then jStart = -jMax end
    local startIdx = jMax + 1 + jStart
    if work[maskBase + startIdx] % 2 == 1 then return 0, "start", 0, 0 end
    work[costBase + startIdx] = 0
    for k = 1, K do
        local row = k * J + jMax + 1
        local prow = (k - 1) * J + jMax + 1
        for j = -jMax, jMax do
            local idx = row + j
            local m = work[maskBase + idx]
            -- 直行擋＝這格連停都不能停，任何檔位都不可行
            if m % 2 == 0 then
                local lj = j * STEP
                local dBase = lj - baseL
                if dBase < 0 then dBase = -dBase end
                local stay = dBase * THREAD_W_BASE
                if roadOK and (lj < roadLo or lj > roadHi) then stay = stay + THREAD_W_OFFROAD end
                local best, bestJ = THREAD_INF, 0
                local dLo, dHi = -THREAD_SLOPE_J, THREAD_SLOPE_J
                if j + dLo < -jMax then dLo = -jMax - j end
                if j + dHi > jMax then dHi = jMax - j end
                for dj = dLo, dHi do
                    local pc = work[costBase + prow + j + dj]
                    if pc < THREAD_INF then
                        local level = threadLevelOf(dj)
                        local ok = true
                        if level == 1 then ok = m % 4 < 2
                        elseif level == 2 then ok = m % 8 < 4 end
                        if ok then
                            local move = dj
                            if move < 0 then move = -move end
                            local c = pc + move * STEP * THREAD_W_MOVE
                            if c < best then best, bestJ = c, j + dj end
                        end
                    end
                end
                if best < THREAD_INF then
                    work[costBase + idx] = best + stay
                    work[prevBase + idx] = bestJ
                end
            end
        end
    end
    -- 終欄：加離基準的終端成本，取最小
    local endRow = K * J + jMax + 1
    local bestEnd, bestEndJ = THREAD_INF, 0
    for j = -jMax, jMax do
        local c = work[costBase + endRow + j]
        if c < THREAD_INF then
            local d = j * STEP - baseL
            if d < 0 then d = -d end
            c = c + d * THREAD_W_END
            if c < bestEnd then bestEnd, bestEndJ = c, j end
        end
    end
    if bestEnd >= THREAD_INF then return 0, "nopath", 0, 0 end

    -- 回溯：先把每欄的 j 暫存進 prev 區之後的空位（重用 cost 區：已用完）
    local j = bestEndJ
    local maxSlope = 0
    for k = K, 0, -1 do
        work[costBase + k + 1] = j   -- cost 區前 K+1 格改存路徑 j（DP 已結束）
        if k > 0 then
            local pj = work[prevBase + k * J + jMax + 1 + j]
            local dj = j - pj
            if dj < 0 then dj = -dj end
            local slope = dj * STEP / THREAD_DS
            if slope > maxSlope then maxSlope = slope end
            j = pj
        end
    end
    -- 壓縮共線：首末欄必留，中間只留「進出斜率不同」的欄（折點）。終欄 s 可略
    -- 超過 sTo（欄距取整），呼叫端以 outS[count] 為折線終點。
    local count = 0
    for k = 0, K do
        local cj = work[costBase + k + 1]
        local keep = (k == 0) or (k == K)
        if not keep then
            local dIn = cj - work[costBase + k]
            local dOut = work[costBase + k + 2] - cj
            keep = dIn ~= dOut
        end
        if keep then
            count = count + 1
            if count > maxNodes then return 0, "capacity", 0, 0 end
            outS[count] = sFrom + k * THREAD_DS
            outL[count] = cj * STEP
        end
    end
    -- 折線的最小橫向餘裕（超出 needHalf 的部分）：沿路徑逐欄對全點量一次
    local minExtra = corridorHalf
    for k = 0, K do
        local cj = work[costBase + k + 1]
        local lj = cj * STEP
        local sk = sFrom + k * THREAD_DS
        for i = 1, n do
            local r = hardR and hardR[i] or OBS_HALF
            if type(r) ~= "number" or r ~= r or r < 0 then r = OBS_HALF end
            local ds = hardS[i] - sk
            if ds < 0 then ds = -ds end
            if ds <= halfL + r + pad then
                local d = hardL[i] - lj
                if d < 0 then d = -d end
                local extra = d - r - needHalf
                if extra < minExtra then minExtra = extra end
            end
        end
    end
    return count, "ok", minExtra, maxSlope
end
