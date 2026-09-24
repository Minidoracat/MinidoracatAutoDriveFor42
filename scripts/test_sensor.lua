--[[
MDADSensor 走廊掃描的離線測試：載入**真正的** production Lua，用最小假世界跑完整輪掃描。

    lua scripts/test_sensor.lua        （repo 根目錄或 scripts/ 執行皆可；標準 Lua 5.x）

為什麼需要（smoke_harness 與 test_corridor 都蓋不到這一層）：
- smoke_harness 從 Driver 整合面進場，掃描結果馬上被規劃層吃掉；「這一輪到底掃到幾
  公尺、花了幾次世界查詢」在那裡看不見。改壞了的表徵是實機偶發的「看不遠／早停」，
  肉眼分不出是請求被夾小、幀率能力算反、還是未載入前緣把範圍永久棘輪住
- test_corridor 只吃 (s, l) 點集，點集**怎麼來**（屍體長軸兩端、殭屍與屍體共用的
  64 點上限、未載入截短）正是本檔的責任
- 感知距離是玩家可調偏好：請求、幀率能力、硬上限三者互相夾限。任何一條寫反都會
  安靜地變成「宣稱淨空但其實沒掃到那裡」——這是唯一會直接撞車的錯誤類別
- 每幀查詢額度是固定的（低幀率縮**範圍**、不加重單幀負擔）。額度寫成隨幀率放大，
  離線看起來一樣綠，實機是低幀率時愈掃愈卡的正回饋

本檔載入的 production（真檔，無任何 source-text 斷言）：
    shared/MDAD_Dynamics.lua
    client/MDAD_Sensor.lua

假 PZ 面只補 MDADSensor.step 真的會碰的那幾個：cell:getGridSquare、square 的五個
getter、instanceof、IsoFlagType／IsoObjectType（延後綁定用）。假格子裡**沒有任何
IsoObject**——sprite 分類不在本檔範圍，也讓「屍體不進 hard」的斷言不被別的來源污染。

假路線是沿世界 +X 的直線（heading 0 → 法向 +Y），起點格心 (1000.5, 2000.5)：
橫向 14 條取樣（格心 ±0.5 … ±6.5）落在 14 個相異的 y 格、每個縱向步落在相異的 x 格，
所以「查了幾格」＝「掃了幾個取樣點」，去重不會把證據吃掉。

限制（必須誠實面對）：
- 只驗公開可觀察輸出（state 的完成輪欄位、世界查詢次數），不斷言 production 的
  原始碼字串，也不讀 w 前綴的 working 欄位
- 期望值全部由測試按檔頭契約手算（±0.65 長軸、±3 減速帶、±4.5 軟縫帶、64 點上限、
  每幀 56 格、硬上限 240、下限 24、名目輪時 375ms），刻意不重用 production 常數推導
- sprite 分類、車輛精確輪廓、probeNear／probeRear／probeAround 冷路徑不在本檔
  （各自另有 smoke_harness 情境）
- 這是標準 Lua 不是 Kahlua：本檔在 42/media 之外，可自由用標準函式庫
]]

-- 家族佈局固定，直接填死最省事
local MEDIA = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua"
local ROOTS = { "", "../" }

-- loadfile 對「檔案不存在」和「語法錯誤」都回 nil；先用 io.open 確認檔案在，
-- 再讓 loadfile 的錯誤訊息原樣浮上來（否則語法錯會被誤報成「找不到」）
local function loadProduction(rel)
    for _, root in ipairs(ROOTS) do
        local path = root .. MEDIA .. "/" .. rel
        local fh = io.open(path, "r")
        if fh then
            fh:close()
            local chunk, err = loadfile(path)
            if not chunk then error("載入失敗（語法錯誤？）：" .. tostring(err)) end
            chunk()
            return path
        end
    end
    error("找不到 " .. rel .. "（請從 repo 根目錄或 scripts/ 執行）")
end

-- =====================================================================
-- 假 PZ 全域（只補 step 真的會碰的；多一個都不加）
-- =====================================================================

-- rawget＝仿真 Kahlua 的 instanceof 語意：Java 端 isInstance 不走 Lua 索引路徑
function instanceof(obj, cls) return type(obj) == "table" and rawget(obj, "_class") == cls end

-- bindFlags 在第一輪掃描開始時讀這兩顆一次；值只被拿去當 props:has 的鍵比較
IsoFlagType = {
    water = "water", solidfloor = "solidfloor", doorN = "doorN", doorW = "doorW",
    solidtrans = "solidtrans", WallN = "WallN", WallW = "WallW", WallNW = "WallNW",
}
IsoObjectType = { isMoveAbleObject = "isMoveAbleObject" }
-- getClimateManager 故意不定義：契約說天氣 API 缺席時 rain 留 nil（下游視為濕）

loadProduction("shared/MDAD_Dynamics.lua")
loadProduction("client/MDAD_Sensor.lua")

-- =====================================================================
-- 測試工具（與 scripts/test_corridor.lua 同一套形狀）
-- =====================================================================

local failures, assertions, scenarios = 0, 0, 0
local scenarioBase, scenarioAsserts, scenarioTitle = 0, 0, nil

local function show(v)
    if type(v) == "string" then return '"' .. v .. '"' end
    if type(v) == "number" and v == v and v - v == 0 and v % 1 ~= 0 then
        return string.format("%.6f", v)
    end
    return tostring(v)
end

local function check(ok, label)
    assertions = assertions + 1
    if not ok then
        failures = failures + 1
        print("  FAIL  " .. label)
    end
    return ok
end

local function checkTrue(v, label)
    return check(v == true, label .. "（實得 " .. show(v) .. "）")
end

local function checkFalse(v, label)
    return check(v == false, label .. "（實得 " .. show(v) .. "）")
end

local function checkNil(v, label)
    return check(v == nil, label .. "（實得 " .. show(v) .. "）")
end

local function checkEq(actual, expected, label)
    return check(actual == expected,
        label .. "（期望 " .. show(expected) .. "、實得 " .. show(actual) .. "）")
end

local function checkNear(actual, expected, eps, label)
    local ok = type(actual) == "number" and actual == actual
        and math.abs(actual - expected) <= eps
    return check(ok, label .. "（期望 ~" .. show(expected) .. "、實得 " .. show(actual) .. "）")
end

local function closeScenario()
    if not scenarioTitle then return end
    if failures - scenarioBase == 0 then
        print("  ok（" .. (assertions - scenarioAsserts) .. " 項斷言全過）")
    end
end

local function scenario(title)
    closeScenario()
    scenarios = scenarios + 1
    scenarioTitle = title
    scenarioBase = failures
    scenarioAsserts = assertions
    print("情境" .. scenarios .. "：" .. title)
end

-- =====================================================================
-- 假世界
-- =====================================================================

local KEY_MUL = 100000
local function key(gx, gy) return gx * KEY_MUL + gy end

-- Java 集合的最小面：Lua 端只用 size／get（0 起算）
local function newList()
    local l = { _v = {} }
    function l:size() return #self._v end
    function l:get(i) return self._v[i + 1] end
    function l:add(v) self._v[#self._v + 1] = v end
    return l
end

local function newSquare()
    local sq = { _objs = newList(), _mov = newList(), _smov = newList(), _floor = nil }
    function sq:getObjects() return self._objs end
    function sq:getMovingObjects() return self._mov end
    function sq:getStaticMovingObjects() return self._smov end
    function sq:getVehicleContainer() return nil end
    function sq:getFloor() return self._floor end
    return sq
end

-- loadedMaxX：x 大於它的格＝chunk 未載入（getGridSquare 回 nil）。queries／floorHits
-- 由 stepOnce 每幀歸零，是「每幀世界查詢額度」唯一的證據來源。
local W = { sq = {}, loadedMaxX = nil, queries = 0, floorHits = 0, vehKey = 0 }
W.empty = newSquare()
W.vehSquare = newSquare()
W.vehSquare._floor = { getSpriteName = function() return "blends_street_01_1" end }

W.cell = {}
function W.cell:getGridSquare(gx, gy, _)
    W.queries = W.queries + 1
    if gx * KEY_MUL + gy == W.vehKey then W.floorHits = W.floorHits + 1 end
    if W.loadedMaxX ~= nil and gx > W.loadedMaxX then return nil end
    return W.sq[gx * KEY_MUL + gy] or W.empty
end

-- 路線：沿 +X 的直線，起點格心。segH 0 → 法向 (0, 1)，橫向 l 正號＝世界 +Y。
local X0, Y0 = 1000.5, 2000.5
local ROUTE_LEN = 300
local PROFILE = {
    n = 2,
    x = { X0, X0 + ROUTE_LEN }, y = { Y0, Y0 },
    s = { 0, ROUTE_LEN }, segLen = { ROUTE_LEN, 0 }, segH = { 0, 0 },
    length = ROUTE_LEN,
}

-- 執行脈絡（幀時／弧長／查詢統計）。放一顆 table：主 chunk 的 local 槽要留給情境。
local R = { now = 5000000, sNow = 0, frameMs = 4,
    peak = 0, peakScan = 0, floorTotal = 0, cells = 0 }

local VEH = {}
function VEH:getX() return X0 + R.sNow end
function VEH:getY() return Y0 end
function VEH:getZ() return 0 end

local function resetWorld()
    W.sq = {}
    W.loadedMaxX = nil
end

-- 車身腳下那一格永遠在掃描帶起點（sNow + 2m）之前，不會被走廊掃描碰到——
-- floorHits 因此就是「輪首地板查詢」的乾淨計數。
local function newSensor(aheadM, frameMs, sNow)
    R.frameMs = frameMs
    R.sNow = sNow or 0
    W.vehKey = key(math.floor(X0 + R.sNow), math.floor(Y0))
    W.sq[W.vehKey] = W.vehSquare
    local st = MDADSensor.newState()
    st.aheadM = aheadM
    return st
end

local function squareAt(wx, wy)
    local k = key(math.floor(wx), math.floor(wy))
    local sq = W.sq[k]
    if sq == nil then
        sq = newSquare()
        W.sq[k] = sq
    end
    return sq
end

local function putZombie(wx, wy)
    squareAt(wx, wy)._mov:add({ _class = "IsoZombie",
        getX = function() return wx end, getY = function() return wy end })
end

local function putCorpse(wx, wy, angle)
    squareAt(wx, wy)._smov:add({ _class = "IsoDeadBody",
        getX = function() return wx end, getY = function() return wy end,
        getAngle = function() return angle end })
end

local function resetCounters()
    R.peak, R.peakScan, R.floorTotal, R.cells = 0, 0, 0, 0
end

-- production 由 Driver 每幀寫入 frameMs（MDAD_Driver.lua 的 s.sensor.frameMs = s.frameMs）
local function stepOnce(st)
    st.frameMs = R.frameMs
    W.queries, W.floorHits = 0, 0
    local done = MDADSensor.step(st, PROFILE, R.sNow, VEH, R.now, W.cell)
    R.now = R.now + R.frameMs
    local scanQ = W.queries - W.floorHits
    if W.queries > R.peak then R.peak = W.queries end
    if scanQ > R.peakScan then R.peakScan = scanQ end
    R.floorTotal = R.floorTotal + W.floorHits
    R.cells = R.cells + scanQ
    return done
end

-- 一路 step 到「本輪剛完成」（含輪距節流的空轉幀，那些幀查詢數為 0，不污染統計）
local function pumpRound(st)
    for _ = 1, 4000 do
        if stepOnce(st) then return true end
    end
    return false
end

local function runRound(st)
    resetCounters()
    return pumpRound(st)
end

-- 端點對的中點與跨距（順序無關：呼叫端只在乎屍體佔了哪一段）
local function pairSpan(st, i, j)
    local s1, l1 = st.zomS[i], st.zomL[i]
    local s2, l2 = st.zomS[j], st.zomL[j]
    return (s1 + s2) * 0.5, (l1 + l2) * 0.5, math.abs(s1 - s2), math.abs(l1 - l2)
end

-- 軟縫點雲是一整包給 Corridor.softZombieLane 掃的，順序不是契約：查存在性即可
local function hasPoint(st, s, l)
    for i = 1, st.zomN do
        if math.abs(st.zomS[i] - s) <= 1e-6 and math.abs(st.zomL[i] - l) <= 1e-6 then
            return true
        end
    end
    return false
end

local EPS = 1e-6
local LAT_ROWS = 14      -- 走廊 ±6.5 的格心取樣條數（契約：±7 走廊、1m 步距）
local BUDGET = 56        -- 每幀世界查詢額度（契約：固定，不隨幀率放大）

-- =====================================================================
-- 情境一：屍體長軸兩端（純屍體，不摻殭屍）
--
-- BaseVehicle.testCollisionWithCorpse 以 getAngle() 的中心 ±0.65m 長軸測輪胎：
-- 只收中心點會漏掉橫躺屍體的頭／腳，軟縫規劃就會從「其實壓得到」的縫穿過去。
-- 端點必須是**真的旋轉**（不是只在橫向鋪開，也不是只在縱向鋪開）。
-- =====================================================================
local function scenarioCorpseAxis()
    scenario("屍體軟避讓：中心 ±0.65 長軸兩端依 getAngle 旋轉入點雲，不進 hard、不算殭屍")

    -- 屍體擺在中心線上 s=10 的格心：兩端點中點必須回到屍體本身
    local function runCorpse(wx, wy, angle)
        resetWorld()
        putCorpse(wx, wy, angle)
        local st = newSensor(48, 4, 0)
        checkTrue(runRound(st), "完成一輪掃描")
        return st
    end

    local PI = math.pi
    local st = runCorpse(X0 + 10, Y0, 0)                 -- 沿路線橫躺
    checkEq(st.zomN, 2, "沿路線橫躺：長軸兩端各一點")
    local ms, ml, ss, sl = pairSpan(st, 1, 2)
    checkNear(ms, 10, EPS, "兩端中點回到屍體弧長")
    checkNear(ml, 0, EPS, "兩端中點回到屍體橫向位置")
    checkNear(ss, 1.3, EPS, "縱向跨距＝2×0.65")
    checkNear(sl, 0, EPS, "橫向跨距 0（長軸沿路線）")
    checkEq(st.corpseN, 1, "屍體計數")
    checkEq(st.zombieN, 0, "屍體不污染殭屍計數")
    checkEq(st.hardN, 0, "屍體不進 hard")
    checkEq(st.softN, 0, "屍體不算軟障礙格")
    checkEq(st.vehN, 0, "屍體不算車輛命中格（推撞閘門不受污染）")
    checkFalse(st.zomOverflow, "兩點遠不到上限")

    st = runCorpse(X0 + 10, Y0, PI * 0.5)                -- 橫躺跨越路線
    checkEq(st.zomN, 2, "跨越路線橫躺：長軸兩端各一點")
    ms, ml, ss, sl = pairSpan(st, 1, 2)
    checkNear(ss, 0, EPS, "縱向跨距 0")
    checkNear(sl, 1.3, EPS, "橫向跨距＝2×0.65（頭腳佔滿 1.3m 寬）")

    st = runCorpse(X0 + 10, Y0, PI * 0.25)               -- 斜躺：兩軸都不是 0
    checkEq(st.zomN, 2, "斜躺：長軸兩端各一點")
    ms, ml, ss, sl = pairSpan(st, 1, 2)
    checkNear(ss, 1.3 * math.cos(PI * 0.25), EPS, "縱向跨距＝1.3·cos45（真的在旋轉）")
    checkNear(sl, 1.3 * math.sin(PI * 0.25), EPS, "橫向跨距＝1.3·sin45")

    -- 端點用屍體實座標，不是取樣格心：軟縫要的是次格級精度
    st = runCorpse(X0 + 10.3, Y0 - 0.3, 0)
    ms, ml = pairSpan(st, 1, 2)
    checkNear(ms, 10.3, EPS, "格內偏移的屍體：弧長不被量化到取樣步")
    checkNear(ml, -0.3, EPS, "格內偏移的屍體：橫向不被量化到取樣格心")
end

-- =====================================================================
-- 情境二：帶語意與 64 點共用上限
--
-- corpseN 是**減速**訊號（只收行駛線 ±3 的路面帶），軟縫點雲是**幾何**訊號
-- （收到 ±4.5）。兩者混用會讓路肩外的屍體壓速度、或帶內的屍體規劃不到縫。
-- 上限是殭屍與屍體共用的 64 點：屍體要嘛兩端都進、要嘛整具不進——只推一端
-- 等於憑空生出一個「半具屍體」的假縫。
-- =====================================================================
local function scenarioCorpseBands()
    scenario("帶語意與共用上限：corpseN 只數 ±3 中帶、點雲收到 ±4.5、屍體不半推")

    -- (a) 中帶外、軟縫帶內（取樣 l=3.5）：不壓速度，但幾何仍要看得到
    resetWorld()
    putCorpse(X0 + 10, Y0 + 4, 0)
    local st = newSensor(48, 4, 0)
    checkTrue(runRound(st), "(a) 完成一輪")
    checkEq(st.corpseN, 0, "(a) 路肩屍體不進減速計數")
    checkEq(st.zomN, 2, "(a) 但長軸兩端仍進軟縫點雲")
    local _, ml = pairSpan(st, 1, 2)
    checkNear(ml, 4, EPS, "(a) 點雲用屍體實際橫向位置")

    -- (b) 軟縫帶外（取樣 l=5.5）：整具不收
    resetWorld()
    putCorpse(X0 + 10, Y0 + 6, 0)
    st = newSensor(48, 4, 0)
    checkTrue(runRound(st), "(b) 完成一輪")
    checkEq(st.corpseN, 0, "(b) 帶外屍體不計數")
    checkEq(st.zomN, 0, "(b) 帶外屍體不進點雲")

    -- (c) 同格殭屍＋屍體：三點共用同一份點雲，計數各走各的
    resetWorld()
    putZombie(X0 + 10.25, Y0 - 0.25)
    putCorpse(X0 + 10, Y0, math.pi * 0.5)
    st = newSensor(48, 4, 0)
    checkTrue(runRound(st), "(c) 完成一輪")
    checkEq(st.zombieN, 1, "(c) 殭屍計數只算殭屍")
    checkEq(st.corpseN, 1, "(c) 屍體計數只算屍體")
    checkEq(st.zomN, 3, "(c) 點雲＝殭屍 1 點＋屍體 2 點")
    checkTrue(hasPoint(st, 10.25, -0.25), "(c) 殭屍點在")
    checkTrue(hasPoint(st, 10, -0.65), "(c) 屍體端點一在")
    checkTrue(hasPoint(st, 10, 0.65), "(c) 屍體端點二在")

    -- (d) 屍堆 33 具：32 具剛好填滿 64 點，第 33 具溢出且不留半具
    resetWorld()
    for _ = 1, 33 do putCorpse(X0 + 10, Y0, 0) end
    st = newSensor(48, 4, 0)
    checkTrue(runRound(st), "(d) 完成一輪")
    checkEq(st.zomN, 64, "(d) 點雲停在 64 點上限")
    checkTrue(st.zomOverflow, "(d) 溢出旗標升起（軟縫應棄權）")
    checkEq(st.corpseN, 33, "(d) 計數不受點雲上限影響")
    checkTrue(st.ready, "(d) 溢出的輪照樣是完整快照")

    -- (e) 63 隻殭屍後只剩 1 格：屍體需要 2 格 → 整具不進，不生出半具屍體
    resetWorld()
    for i = 1, 63 do putZombie(X0 + 10 + i * 0.001, Y0) end
    putCorpse(X0 + 10, Y0, 0)
    st = newSensor(48, 4, 0)
    checkTrue(runRound(st), "(e) 完成一輪")
    checkEq(st.zombieN, 63, "(e) 殭屍全數計數")
    checkEq(st.zomN, 63, "(e) 屍體整具被拒（不是補一端湊 64）")
    checkTrue(st.zomOverflow, "(e) 溢出旗標升起")
    checkEq(st.corpseN, 1, "(e) 屍體仍計數（減速訊號不因點雲滿而消失）")
end

-- =====================================================================
-- 情境三：全載入、快幀、請求超過硬上限
--
-- 「掃到 240」必須是**真的掃完 240m 的每一條橫向**，不是端點欄位寫得漂亮。
-- 同時鎖每幀查詢額度：56 格＋輪首 1 格地板，地板是每輪一次不是每幀一次。
-- =====================================================================
local function scenarioFullRange()
    scenario("全載入快幀：請求 999 夾到硬上限 240、整帶掃滿、每幀 ≤56 格＋輪首 1 格地板")

    resetWorld()
    local st = newSensor(999, 4, 0)
    checkTrue(runRound(st), "完成一輪")
    checkNear(st.effectiveAheadM, 240, 1e-9, "有效範圍＝硬上限 240")
    checkNear(st.scanEndS, 240, 1e-9, "掃描終點弧長＝sNow+240")
    checkNear(st.scanS, 2, 1e-9, "掃描起點＝車前 2m")
    checkEq(st.aheadM, 999, "硬上限只夾有效範圍，不改寫呼叫端的請求欄位")
    checkFalse(st.unloaded, "全載入：沒有未知前緣")
    checkTrue(st.ready, "快照可用")
    checkEq(R.cells, LAT_ROWS * 239, "整帶掃滿：14 條橫向 × 239 個縱向步")
    checkTrue(R.peakScan <= BUDGET, "單幀掃描查詢 ≤ 56（實得 " .. R.peakScan .. "）")
    checkTrue(R.peak <= BUDGET + 1, "單幀總查詢 ≤ 56+1（實得 " .. R.peak .. "）")
    checkEq(R.floorTotal, 1, "地板查詢每輪一次，不是每幀一次")
    checkEq(st.actualSurfaceId, MDADSensor.SURFACE_PAVED, "那一次地板查詢真的用上了")

    -- 對照組：同樣快幀、請求 200 → 完整達成。證明 240 是硬上限而非幀能力上限
    resetWorld()
    st = newSensor(200, 4, 0)
    checkTrue(runRound(st), "對照組完成一輪")
    checkNear(st.effectiveAheadM, 200, 1e-9, "快幀下 200 請求完整達成（240 不是被幀率限住）")
    checkEq(R.cells, LAT_ROWS * 199, "對照組同樣整帶掃滿")
end

-- =====================================================================
-- 情境四：幀率適應
--
-- 契約：每幀額度固定，低幀率縮**有效範圍**。請求（玩家偏好）不因此改小，
-- 幀率回來就要看得回去。下限 24m：再怎麼卡也不能縮成 0 而回報「前方淨空」。
-- 名目輪時目標375ms、每幀56/14＝4步；低FPS的24m保底不等於輪時保證。
-- =====================================================================
local function scenarioFrameAdaptation()
    scenario("幀率適應：慢幀縮有效視界、不縮請求、每幀額度不變；卡頓仍保底 24m")

    -- 20ms/幀（50fps）：2 + 4×375/20 = 77m
    resetWorld()
    local st = newSensor(200, 20, 0)
    checkTrue(runRound(st), "50fps 完成一輪")
    checkNear(st.effectiveAheadM, 77, 1e-9, "50fps 有效範圍77m")
    checkEq(R.cells, LAT_ROWS * 76, "有效範圍內整帶掃滿")

    -- 100ms/幀（10fps）：預算不足，被下限拉回24m
    resetWorld()
    st = newSensor(200, 100, 0)
    checkTrue(runRound(st), "10fps 完成一輪")
    checkNear(st.effectiveAheadM, 24, 1e-9, "10fps 落到下限 24m")
    checkNear(st.requestedAheadM, 200, 1e-9, "請求仍是 200")
    checkEq(R.cells, LAT_ROWS * 23, "24m 帶整帶掃滿")
    checkTrue(R.peakScan <= BUDGET, "極慢幀仍不加重單幀負擔（實得 " .. R.peakScan .. "）")

    -- 5 秒的卡頓幀（EWMA 上限 250ms）：仍是 24m，不是 0、不是負值
    resetWorld()
    st = newSensor(200, 5000, 0)
    checkTrue(runRound(st), "卡頓幀完成一輪")
    checkNear(st.effectiveAheadM, 24, 1e-9, "卡頓幀保底 24m（絕不歸零）")
    checkTrue(st.scanEndS > st.scanS, "終點永遠在起點之前方")

    -- 幀率回來（新 session／新 state）：同一個請求看得回 200
    resetWorld()
    st = newSensor(200, 4, 0)
    checkTrue(runRound(st), "幀率回復後完成一輪")
    checkNear(st.effectiveAheadM, 200, 1e-9, "幀率回來就看得回完整請求")
end

-- =====================================================================
-- 情境五：未載入前緣
--
-- 未載入不是淨空、是不知道：本輪掃到未知前緣就截短（前緣之外沒有安全證明），
-- 但 unloaded／unloadedS 必須跟著完成輪一起交出去。關鍵是**不得棘輪**——
-- 截短只屬於這一輪，chunk 載入後同一個請求要能重新掃遠。
-- =====================================================================
local function scenarioUnloadedFrontier()
    scenario("未載入前緣：截短本輪但保留 unloaded/unloadedS、請求不被棘輪、載入後掃得回去")

    resetWorld()
    W.loadedMaxX = 1021              -- 車前 22m（含）以後未載入
    local st = newSensor(120, 8, 0)
    for round = 1, 2 do
        checkTrue(runRound(st), "第 " .. round .. " 輪完成")
        checkTrue(st.unloaded, "第 " .. round .. " 輪：走廊內有未載入 chunk")
        checkNear(st.unloadedS, 22, 1e-9, "第 " .. round .. " 輪：最近未知前緣弧長")
        checkNear(st.scanEndS, 22, 1e-9, "第 " .. round .. " 輪：本輪截短到未知前緣")
        checkNear(st.effectiveAheadM, 22, 1e-9, "第 " .. round .. " 輪：實掃範圍只到前緣")
        checkNear(st.requestedAheadM, 120, 1e-9, "第 " .. round .. " 輪：請求不被棘輪改小")
        checkEq(st.hardN, 0, "第 " .. round .. " 輪：未載入不當障礙")
        checkEq(R.cells, LAT_ROWS * 21, "第 " .. round .. " 輪：截短的那一列仍整列掃完")
    end

    W.loadedMaxX = nil               -- chunk 載入
    checkTrue(runRound(st), "載入後第 3 輪完成")
    checkFalse(st.unloaded, "載入後不再有未知前緣")
    checkNil(st.unloadedS, "unloadedS 隨之清掉")
    checkNear(st.effectiveAheadM, 120, 1e-9, "同一個請求重新掃到 120m（沒有永久棘輪）")
    checkEq(R.cells, LAT_ROWS * 119, "整帶重新掃滿")
end

-- =====================================================================
-- 情境六：輪內改請求
--
-- 感知距離可以在行進中被改（ESC 選項、速度域前伸）。進行中的那一輪已經用舊範圍
-- 掃了一半：中途改 endS 會生出「一半密一半疏」的快照，而 scanEndS 宣稱的範圍
-- 根本沒被走過。契約是輪首鎖定、下一輪才採用。
-- 同時鎖 scanS/scanEndS 是**絕對弧長**（sNow=30 起跑）。
-- =====================================================================
local function scenarioMidRoundRequest()
    scenario("輪內改感知距離：進行中的輪維持輪首鎖定範圍，下一輪才採用新請求")

    resetWorld()
    local st = newSensor(48, 4, 30)
    resetCounters()
    local done = false
    for _ = 1, 3 do                        -- 3 幀＝12 步，離 47 步還很遠
        if stepOnce(st) then done = true end
    end
    checkFalse(done, "3 幀還沒掃完 47 步的輪")

    st.aheadM = 200                        -- 輪中改請求
    checkTrue(pumpRound(st), "本輪照樣完成")
    checkNear(st.scanEndS, 78, 1e-9, "進行中的輪維持輪首範圍（30+48）")
    checkNear(st.effectiveAheadM, 48, 1e-9, "有效範圍不被輪中改動放大")
    checkNear(st.requestedAheadM, 48, 1e-9, "requestedAheadM 是輪首快照")
    checkNear(st.scanS, 32, 1e-9, "掃描起點是絕對弧長 sNow+2")
    checkEq(R.cells, LAT_ROWS * 47, "沒有因為改請求而多掃或少掃")

    checkTrue(runRound(st), "下一輪完成")
    checkNear(st.requestedAheadM, 200, 1e-9, "下一輪採用新請求")
    checkNear(st.scanEndS, 230, 1e-9, "下一輪終點＝30+200")
    checkEq(R.cells, LAT_ROWS * 199, "新範圍整帶掃滿")
end

-- =====================================================================
-- 情境七：遠處屍堆
--
-- 軟縫點雲只收軟窗（max(40m, 3s 行程)）內的點：遠處成堆的屍體既不能吃掉近端
-- 殭屍的 64 點額度、也不能把 zomOverflow 升起讓近端避讓整個棄權。
-- 減速用的 corpseN／corpseNearS 是另一條訊號，仍看得見整條掃描帶。
-- =====================================================================
local function scenarioDistantCorpses()
    scenario("遠處屍堆不占近端軟避讓額度，減速距離仍可觀察")
    resetWorld()
    putZombie(X0 + 10, Y0)
    for i = 1, 40 do putCorpse(X0 + 100 + i, Y0, 0) end
    local st = newSensor(200, 4, 0)
    checkTrue(runRound(st), "完成長帶掃描")
    checkEq(st.corpseN, 40, "仍看見遠處屍堆")
    checkEq(st.zomN, 1, "只收近端選縫真正會用到的殭屍")
    checkFalse(st.zomOverflow, "遠處屍堆不關掉近端避讓")
    checkTrue(st.corpseNearS > 90 and st.zombieNearS < 20, "遠近兩類保有各自的接近距離")
end

-- =====================================================================
-- 情境八：行進中車輛（會車／跟車）
--
-- 2026-09-24 雙客戶端 E2E：舊制只記「帶內有行進車＋最近弧長」，分不出對向車在自己車道
-- （該照速通過）還是壓到我方車道（該靠右錯開）。契約：每台行進車一筆，(s,l) 區間＝真 OBB
-- 四角在路線局部框的外包；沿路線速度＝兩輪位移／時差（對向負、同向正、首輪 false）；
-- 兩輪沒動（<0.3m）＝靜止＝硬障礙，不進 trf。
-- =====================================================================
local function scenarioTraffic()
    scenario("行進中車輛：OBB (s,l) 區間、沿路線速度正負、首輪無速度、靜止車不進 trf")
    resetWorld()
    -- 最小池向量（Sensor 只用 allocVector3f／releaseVector3f 與 x()/y()）
    BaseVehicle = {
        allocVector3f = function()
            local v = { _x = 0, _y = 0 }
            function v:set(x, y) self._x, self._y = x, y return self end
            function v:x() return self._x end
            function v:y() return self._y end
            return v
        end,
        releaseVector3f = function() end,
    }
    local vehSq = {}
    local function newCar(id, cx, cy, heading)
        local W, L = 1.8, 4.6
        local car = { _class = "BaseVehicle", _x = cx, _y = cy, _h = heading }
        local ext = { x = function() return W end, z = function() return L end }
        local com = { x = function() return 0 end, z = function() return 0 end }
        local script = { getExtents = function() return ext end,
            getCenterOfMassOffset = function() return com end }
        function car:getId() return id end
        function car:getX() return self._x end
        function car:getY() return self._y end
        function car:isStopped() return false end
        function car:getScript() return script end
        function car:getWorldPos(lx, _, lz, out)
            local fx, fy = math.cos(self._h), math.sin(self._h)
            return out:set(self._x + fx * lz - fy * lx, self._y + fy * lz + fx * lx)
        end
        return car
    end
    -- 車身蓋到的格登記 getVehicleContainer（粗判：格心落在 OBB 外擴半格內）
    local function place(car)
        for k, v in pairs(vehSq) do
            if v == car then W.sq[k]._veh, vehSq[k] = nil, nil end
        end
        for gx = math.floor(car._x - 4), math.floor(car._x + 4) do
            for gy = math.floor(car._y - 3), math.floor(car._y + 3) do
                local dx, dy = gx + 0.5 - car._x, gy + 0.5 - car._y
                local fx, fy = math.cos(car._h), math.sin(car._h)
                if math.abs(dx * fx + dy * fy) <= 2.8 and math.abs(-dx * fy + dy * fx) <= 1.4 then
                    local sq = squareAt(gx + 0.5, gy + 0.5)
                    sq._veh = car
                    function sq:getVehicleContainer() return self._veh end
                    vehSq[key(gx, gy)] = car
                end
            end
        end
    end
    -- 對向車（朝 −X）在右車道外側 l=−2、s=30；同向車（朝 +X）在 l=+2、s=20；靜止車 l=0、s=45
    local on = newCar(1, X0 + 30, Y0 - 2, math.pi)
    local lead = newCar(2, X0 + 20, Y0 + 2, 0)
    local parked = newCar(3, X0 + 45, Y0, 0)
    place(on); place(lead); place(parked)
    local st = newSensor(80, 4, 0)
    checkTrue(runRound(st), "第一輪完成")
    checkEq(st.trfN, 3, "三台首次看到都先當行進中（還沒有位移可判靜止）")
    local function entry(sMid)
        for i = 1, st.trfN do
            if math.abs((st.trfS0[i] + st.trfS1[i]) * 0.5 - sMid) < 1 then return i end
        end
    end
    local i = entry(30)
    checkTrue(i ~= nil and st.trfVs[i] == false, "首輪沒有速度（false，不是 0）")
    if i then
        checkNear(st.trfS0[i], 30 - 2.3, 1e-6, "對向車 s 區間＝車心 ± 半車長")
        checkNear(st.trfS1[i], 30 + 2.3, 1e-6, "對向車 s 區間上界")
        checkNear(st.trfL0[i], -2.9, 1e-6, "對向車 l 區間＝車心 ± 半車寬")
        checkNear(st.trfL1[i], -1.1, 1e-6, "對向車 l 區間上界")
    end
    -- 下一輪：對向車往 −X 走 3m、同向車往 +X 走 2m、停著的不動
    on._x, lead._x = on._x - 3, lead._x + 2
    place(on); place(lead)
    checkTrue(runRound(st), "第二輪完成")
    checkEq(st.trfN, 2, "靜止車（兩輪位移 <0.3m）改走硬障礙，不再是 trf")
    local io, il = entry(27), entry(22)
    checkTrue(io ~= nil and st.trfVs[io] < -5 and st.trfVs[io] > -20,
        "對向車沿路線速度為負（實得 " .. show(io and st.trfVs[io]) .. "）")
    checkTrue(io ~= nil and math.abs(st.trfVl[io]) < 1e-6, "對向車沒有橫向速度")
    checkTrue(il ~= nil and st.trfVs[il] > 3 and st.trfVs[il] < 15,
        "同向車沿路線速度為正（實得 " .. show(il and st.trfVs[il]) .. "）")
    checkTrue(st.hardN > 0, "靜止車進入硬障礙點雲")
    BaseVehicle = nil
end

-- =====================================================================
-- 情境九：斜向路線每輪都看得到每隻殭屍（0925 E2E zombie-sp turn：彎心殭屍每隔一兩輪消失，
-- 軟縫在閃／不閃間來回跳）。1m×1m 取樣點陣一旋轉就會漏格，漏哪格隨起點相位變；非軸對齊步
-- 改 0.5m 細取樣後，任何相位都要一隻不漏。違規證明：細取樣關掉（恆用 1m）即紅。
-- =====================================================================
local function scenarioDiagonalCoverage()
    scenario("斜向 45° 路線：各起點相位下帶內殭屍每輪都收得到")
    local h = math.pi / 4
    local c, sn = math.cos(h), math.sin(h)
    local keep = { x = PROFILE.x, y = PROFILE.y, segH = PROFILE.segH }
    PROFILE.x = { X0, X0 + ROUTE_LEN * c }
    PROFILE.y = { Y0, Y0 + ROUTE_LEN * sn }
    PROFILE.segH = { h, h }
    local N, missedRounds = 0, 0
    for _, phase in ipairs({ 0, 0.13, 0.29, 0.41, 0.57, 0.73, 0.88 }) do
        resetWorld()
        local st = newSensor(120, 4, phase)
        N = 0
        for i = 1, 24 do
            -- 固定的偽隨機 (s, l)：s 6..36、l −4..4（右側為正，法向 (−sin h, cos h)）
            local sAt = 6 + (i * 7.31) % 30
            local lAt = -4 + (i * 3.17) % 8
            putZombie(X0 + sAt * c - lAt * sn, Y0 + sAt * sn + lAt * c)
            N = N + 1
        end
        runRound(st)
        if st.zomN ~= N then missedRounds = missedRounds + 1 end
    end
    checkEq(missedRounds, 0, "七個起點相位都收到全部 24 隻（漏收的輪數）")
    PROFILE.x, PROFILE.y, PROFILE.segH = keep.x, keep.y, keep.segH
    resetWorld()
end

-- =====================================================================
scenarioCorpseAxis()
scenarioCorpseBands()
scenarioFullRange()
scenarioFrameAdaptation()
scenarioUnloadedFrontier()
scenarioMidRoundRequest()
scenarioDistantCorpses()
scenarioTraffic()
scenarioDiagonalCoverage()

closeScenario()
print()
print("情境 " .. scenarios .. " 個、斷言 " .. assertions .. " 項")
if failures > 0 then
    print(failures .. " 項失敗")
    if os and os.exit then os.exit(1) end
    error(failures .. " 項失敗")
end
print("全部通過")
