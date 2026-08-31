-- MDAD_Sensor.lua — M4 走廊掃描（client：整個自駕唯一會讀「世界格」的地方）
--
-- 分層：本檔只回答「路線前方 48 公尺（高速組態 110 公尺）的走廊裡，哪些位置是硬障礙」，不做任何決策。
-- 縫隙規劃是 shared/MDAD_Corridor.lua 的事（純數學、離線可測），把方向盤轉下去是
-- client/MDAD_Driver.lua 的事。感知／規劃／執行三層各自只有一種相依：
--   Sensor → PZ 世界（本檔）｜Corridor → 無｜Driver → Follower + Corridor + 本檔的結果欄位。
--
-- 為什麼 PZ 入口全部從參數進來（cell、vehicle）而不在檔內呼叫 getCell()：
-- 掃描是整個 M4 最容易寫錯又最難用肉眼回歸的部分（分幀續跑的游標、世界格去重的
-- generation、sprite 成本快取）。把 cell／vehicle 收斂成參數之後，離線 harness 只要
-- 餵一顆假 cell（實作 getGridSquare）與假 vehicle（getZ／isStopped）就能跑完整輪掃描，
-- 不需要任何假全域。檔內唯一直接碰的全域是 IsoFlagType／IsoObjectType／instanceof，
-- 而前兩者是延後綁定的（見 bindFlags），harness 可以在第一次 step 之前塞替身。
--
-- ---------------------------------------------------------------------------
-- 介面契約
-- ---------------------------------------------------------------------------
-- MDADSensor.newState() → state
--     整個模組**唯一**配置 table 的地方（每個自駕 session 一顆，重複使用）。
--
-- MDADSensor.reset(state)
--     重新啟動自駕時呼叫。就地清空，不重建任何 table。
--     **換路線不必自己呼叫**：step 認得 profile 參考變了，會自動走同一條失效路徑。
--
-- MDADSensor.step(state, profile, sNow, vehicle, now, cell) → boolean
--     每幀呼叫一次。回 true ＝「本輪掃描剛剛完成」，呼叫端此時（也只在此時）
--     需要重新規劃；回 false ＝ 沒事發生，繼續沿用上一輪的結果。
--     profile ＝ MDADFollower 的剖面（唯讀）：n / x[i] / y[i] / s[i] / segLen[i]
--               / segH[i] / length。sNow ＝ 車輛在路線上的目前弧長（公尺）。
--               now ＝ 毫秒時戳。cell ＝ IsoCell。vehicle ＝ 自己這台車（要排除自己）。
--
-- 結果欄位（呼叫端只讀這一組，任何時候都是「最後一輪完成」的完整快照）：
--     state.ready      boolean：reset 之後至少完成過一輪
--     state.hardN      硬障礙格數（0 ＝ 走廊淨空）
--     state.hardS[i]   第 i 個硬障礙的**路線絕對弧長**（公尺），i ∈ [1, hardN]
--     state.hardL[i]   第 i 個硬障礙的橫向偏移（公尺；數學 CCW 法向為正＝PZ 世界的行進方向右側）
--     state.softN      軟障礙格數（可推開的家具／路邊雜物：撞得過但該減速）
--     state.zombieN    走廊內殭屍數
--     state.corpseN    走廊內地面屍體數（壓得過：只供速度檔，不參與縫隙規劃）
--     state.movingVeh  走廊內有**行進中**的別台車（跟車情境，不是靜態障礙）
--     state.unloaded   走廊內有未載入 chunk（規劃要保守：不是淨空，是不知道）
--     state.sig        整數簽章：障礙布局有變才會變（呼叫端拿它省掉重複規劃）
--     state.scanS      本輪掃描起點弧長；state.scanEndS 終點弧長
--     state.stamp      本輪完成時的 now（判資料新鮮度）
--     state.rain       本輪 weather snapshot；nil＝API unknown（控制端視為 wet）
--     state.actualSurfaceId  車身當前 floor：unknown/paved/gravel/dirt numeric id
--     state.roundStartedAt   本輪開始時戳；與 stamp（完成）界定 immutable snapshot
--
-- ---------------------------------------------------------------------------
-- 效能守則（step 每幀跑，且每一格都是跨 Lua↔Java 邊界的呼叫）
-- ---------------------------------------------------------------------------
-- ① 節流：沒有進行中的掃描時，一次數字比較就 return（SCAN_INTERVAL_MS 250ms 一輪）。
-- ② 分幀：一輪 47 個縱向樣本 × 14 條橫向 ＝ 658 格，每幀最多 56 格，
--    12 幀（60fps 下 200ms）跑完，仍小於 250ms 的輪距，不會前後輪重疊。
-- ③ 零配置：step 內不建 table、不建 closure、不做字串串接。橫向偏移表與成本常數
--    都是載入期的 upvalue；硬障礙緩衝區重複使用（第一輪把陣列撐到定容後就不再成長）。
-- ④ 世界格去重：同一輪內相鄰步的橫向取樣會落在同一格（1 公尺步長 × 1 公尺格），
--    實測重疊約三成。用 visited[key] == generation 比對，不清表、不配置。
-- ⑤ sprite 成本快取：同一張 sprite 的分類結果永遠相同，快取後每格只剩
--    getObjects/getSpriteName 兩次跨界，省掉 getSprite/getProperties/has 一整串。
-- ⑥ 雙緩衝：一輪算完才整組換手（交換 table 參考，O(1) 零配置）。掃描進行中呼叫端
--    讀到的仍是上一輪的完整結果，不會看到半套資料。

MDADSensor = MDADSensor or {}

-- 熱路徑庫函式在載入期取 local upvalue（Kahlua 的庫函式是 JavaFunction，
-- 寫 math.sin 等於多一次 table 查詢）。與 shared/MDAD_Follower.lua 同一條守則。
-- 取整一律用 `n - n % 1`（純 Lua floor，負座標也正確），不呼叫 math.floor。
local sin, cos, abs = math.sin, math.cos, math.abs
local find = string.find

--------------------------------------------------------------------------------
-- 調校常數
--------------------------------------------------------------------------------

local SCAN_INTERVAL_MS = 250   -- 兩輪掃描的間隔（自輪次「開始」起算）
local SCAN_NEAR = 2            -- 掃描起點：車前 2 公尺（車身本體不算障礙）
local SCAN_AHEAD = 48          -- 掃描終點：車前 48 公尺（85km/h 約 2 秒反應＋更早定側減少繞行震盪）
local SCAN_STEP = 1            -- 沿路線的取樣步長（公尺，＝一格）
local SCAN_BUDGET = 56         -- 每幀最多實際查詢幾格世界格（±6.5×48m 帶 ~658 格/輪 → ~12 幀）
local HARD_MAX = 768           -- 硬障礙緩衝上限（掃描帶最多 658 個唯一格，保留 110 格防呆）
local VISITED_ROUNDS = 64      -- 每幾輪重建一次 visited 表
local SPRITE_CACHE_MAX = 4096  -- sprite 成本快取條目上限

-- 橫向取樣：以路線中心線的數學 CCW 法向為正（PZ 世界 Y 向南，這個方向是實際的
-- 行進方向**右側**），涵蓋 ±6.5 公尺的走廊（路面＋兩側路肩＋緊鄰草地）。
-- 寬度不是拍腦袋：Corridor 的可行車道範圍＝corridorHalf - needHalf（1.4）。
-- ±5 走廊（可行帶 ±3.6）繞得過**一台**居中靜止車（膨脹佔 [-3.1,3.1]、兩側各剩
-- 0.5m），但**兩台並排**（實佔 l∈[-2,3]、膨脹後 [-4.1,5.1]）就整帶堵死——
-- 2026-08-28 實機：路口兩台並排車，左右明明有空間（在走廊外）卻 blocked 停死。
-- ±7 走廊（可行帶 ±5.6）讓並排車側邊的縫進得了候選集；代價是每輪掃描
-- 14×47=658 格（舊 ±5/36m 為 350 格），SCAN_BUDGET 32→56，仍是 12 幀。
-- 取樣點放在格心（±0.5 … ±6.5）而不是格界，避免 floor 之後兩條相鄰橫向落到
-- 同一格、白掃一次。
local LAT = { -6.5, -5.5, -4.5, -3.5, -2.5, -1.5, -0.5, 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5 }
local LAT_N = 14
local CORRIDOR_HALF = 7

-- 世界格去重的鍵：wx * 100000 + wy。PZ 的地圖座標是非負且遠小於 100000
-- （最大官方地圖 ~15000 格），所以這個線性組合在有效範圍內是單射，
-- 不會有兩格撞同一鍵。用 number 當鍵（不是字串）才不會每格配置一條字串。
local KEY_MUL = 100000

local COST_NONE, COST_SOFT, COST_HARD = 0, 1, 2
local COST_HARD_THIN = 3       -- 細桿硬障礙（樹幹）：擋不擋線用 0 半徑判（樹幹 ~0.3 格）
local SLOW_BAND_HALF = 3       -- 減速計數帶半寬（±3＝路面帶；hard 仍收全走廊 ±6.5）
local OBS_HALF_R = 0.7         -- 整格箱型硬障礙的半徑（＝Corridor 的 OBS_HALF；樹幹用 0）
local SURFACE_UNKNOWN, SURFACE_PAVED, SURFACE_GRAVEL, SURFACE_DIRT = 0, 1, 2, 3
-- 路面對中（2026-08-28 實機：163 號公路的 nav 線偏到路面東緣外 2-4m）：
-- 掃描順路統計地板 sprite 的橫向平均，輪末產出 roadC 給 driver 做 EMA。
-- 路面家族＝blends_street／floors_exterior_street／street_curbs（tileset 歸類
-- BrushToolChooseTileUI.lua:76-98；名稱判定慣例 ISShovelGroundCursor.lua:109-112）。
-- 但 blends_street 也鋪停車場：Rosewood 8262,11511 的 6m Butterfly St 與
-- 西側停車場連成 11 格寬，舊平均被拉 1.625m，再疊 RightLaneBias 把車送到
-- 石碑／鐵欄。可辨識街道最大接受 10m（格心 span 9）；更寬＝停車場／路口
-- 歧義，fail-safe 不校正、不提供 road band，退回 streets.xml nav 線。
local ROAD_PREFIX_1 = "blends_street"
local ROAD_PREFIX_2 = "floors_exterior_street"
local ROAD_PREFIX_3 = "street_curbs"
local ROAD_MIN_N = 24          -- 一輪至少這麼多路面格才給樣本（濾掉零星補丁）
local ROAD_MAX_SPAN = 9        -- 路面格心最大橫跨（＝10m 實際寬）；更寬視為歧義
local ROAD_EDGE_GAP = 0.25     -- 兩緣不得落最外圈取樣；LAT 間距 1m，0<gap<1 行為等價
local ROAD_CACHE_MAX = 256     -- 地板名 → 是否路面 的快取上限（防模組地圖無上限）

MDADSensor.SCAN_AHEAD = SCAN_AHEAD
MDADSensor.SCAN_NEAR = SCAN_NEAR
MDADSensor.CORRIDOR_HALF = CORRIDOR_HALF
MDADSensor.SLOW_BAND_HALF = SLOW_BAND_HALF

MDADSensor.SURFACE_UNKNOWN = SURFACE_UNKNOWN
MDADSensor.SURFACE_PAVED = SURFACE_PAVED
--------------------------------------------------------------------------------
-- 延後綁定的引擎枚舉
--------------------------------------------------------------------------------

-- IsoFlagType／IsoObjectType 是引擎曝露的全域（原版 Lua 遍布 IsoFlagType.solid
-- 等用例）。在載入期直接取 upvalue 會綁死載入順序，也讓離線 harness 沒有插手空間；
-- 改成第一輪掃描開始時綁一次，之後每輪只多一次 boolean 比較。
local F_water, F_doorN, F_doorW, T_moveable
local flagsBound = false

local function bindFlags()
    F_water = IsoFlagType.water
    F_doorN = IsoFlagType.doorN
    F_doorW = IsoFlagType.doorW
    T_moveable = IsoObjectType.isMoveAbleObject   -- 枚舉序 28（SpriteDetails/IsoObjectType.java:36）
    flagsBound = true
end

-- Runtime floor classification mirrors the offline road-surface source. Gravel,
-- sand/clay and dirt lists come from vanilla
-- ISShovelGroundCursor.GetDirtGravelSand (ISShovelGroundCursor.lua:108-130).
-- This is evidence only; unknown never decides a RETURN mismatch.
local function floorSurfaceId(name)
    if type(name) ~= "string" then return SURFACE_UNKNOWN end
    if name == "floors_exterior_natural_01_13"
            or name == "blends_street_01_48"
            or name == "blends_street_01_53"
            or name == "blends_street_01_54"
            or name == "blends_street_01_55"
            or find(name, "street_curbs_01_blend_gravel", 1, true) == 1 then
        return SURFACE_GRAVEL
    end
    if name == "blends_natural_01_0" or name == "blends_natural_01_5"
            or name == "blends_natural_01_6" or name == "blends_natural_01_7"
            or name == "floors_exterior_natural_01_24"
            or name == "blends_natural_01_96" or name == "blends_natural_01_101"
            or name == "blends_natural_01_102" or name == "blends_natural_01_103"
            or find(name, "carpentry_02", 1, true) == 1 then
        return SURFACE_UNKNOWN
    end
    if find(name, "street_curbs_01_blend_dirt", 1, true) == 1
            or find(name, "blends_natural_01_", 1, true) == 1
            or find(name, "floors_exterior_natural", 1, true) == 1 then
        return SURFACE_DIRT
    end
    if find(name, ROAD_PREFIX_1, 1, true) == 1
            or find(name, ROAD_PREFIX_2, 1, true) == 1
            or find(name, ROAD_PREFIX_3, 1, true) == 1 then
        return SURFACE_PAVED
    end
    return SURFACE_UNKNOWN
end

--------------------------------------------------------------------------------
-- sprite 分類（只在快取 miss 時跑）
--------------------------------------------------------------------------------

-- 回 (hard, thin)：hard＝這一格是不是硬障礙；thin＝硬障礙來源是細桿（樹幹）。
--
-- 有碰撞的 sprite 一律 HARD：shouldHaveCollision 只看 solid / solidtrans / WallN /
-- WallNW / WallW / collideN / collideW（IsoSprite.java:2083-2093，**不含 solidfloor**）
-- ——地板 sprite 根本進不了這個分支，所以不需要（也不能有）solidfloor 豁免；
-- 水面的攔截在 scanCell 的「格級地板檢查」（getFloor），不在這裡。
-- v1 刻意不做方向性半格阻擋（北牆只擋北半格）：牆的朝向要配合車的行進方向才有意義，
-- 判錯的代價是直接撞牆，先整格保守擋住。
--
-- 無碰撞的 sprite：門框（doorN/doorW）是開口，不能當障礙。`isMoveAbleObject`
-- 是引擎由 StopCar 設的 vehicle collision type（**不是** tile 的 IsMoveAble 屬性），
-- 仍算 SOFT。其後才處理 HitByCar：沒有 collision/StopCar 的
-- street_decoration／trashcontainers 小物可直接放行；實體郵筒、標誌等已在前兩關
-- 收編，不可因 prefix 被穿透。
local function classifySprite(obj, name)
    local sprite = obj:getSprite()                     -- 用例 ISWorldObjectContextMenu.lua:1347
    if sprite == nil then return COST_NONE end
    local props = sprite:getProperties()               -- IsoSprite.java:240
    if props == nil then return COST_NONE end

    -- 籬笆家族＝細桿硬障礙：鐵絲網／木柵欄實體 0.1-0.3m 薄片，整格肥半徑
    -- （0.7）讓路緣籬笆排把「路線本身過彎」都判成擦撞（2026-08-29 回程路口：
    -- bias 直行線離籬笆 1.33m 被 0.7+needBase 判死、原生導航天天照走）。
    -- r=0 後 needHalf/needBase 的 margin 仍保護實體薄片。
    if find(name, "fencing_", 1, true) == 1 then return COST_HARD_THIN end

    if sprite:shouldHaveCollision() then               -- IsoSprite.java:2083-2093
        return COST_HARD
    end

    -- 樹＝**細桿**硬障礙：樹的 sprite 不帶碰撞 flag（shouldHaveCollision 看不到；
    -- 車輛引擎對樹另有專屬碰撞），對上面的檢查完全隱形——實機 2026-08-28：
    -- 自駕全油撞樹、脫困後原路再撞同一棵，三次鬼打牆。IsoTree 住 getObjects
    -- （IsoTree.java:67 extends IsoObject）；instanceof 用例 ISDestroyCursor.lua:308；
    -- instanceof 只在 sprite 快取 miss 時跑一次（同名 sprite 恆同類，快取安全）。
    -- 半徑用 0（樹幹細）：整格肥半徑（0.7）曾把路緣樹排判成擋路、車長期貼
    -- 對側路緣不回中（2026-08-28 實機）。needHalf 的 0.5 margin 仍保護樹幹。
    if instanceof(obj, "IsoTree") then return COST_HARD_THIN end

    if props:has(F_doorN) then return COST_NONE end
    if props:has(F_doorW) then return COST_NONE end
    -- 原版通常會把 StopCar/Hoppable 合成 collision；顯式 guard 保護未合成或 MOD tile，
    -- 也避免緊接著的 isMoveAbleObject 分支把真正會停車的物件降成 SOFT。
    if props:has("StopCar") then return COST_HARD end
    if obj:getType() == T_moveable then return COST_SOFT end
    if props:has("HitByCar") then                      -- PropertyContainer.java:187（has(String) 過載）
        if find(name, "street_decoration", 1, true) == 1 then return COST_NONE end
        if find(name, "trashcontainers", 1, true) == 1 then return COST_NONE end
        return COST_SOFT
    end
    return COST_NONE
end

--------------------------------------------------------------------------------
-- 單格掃描
--------------------------------------------------------------------------------

-- name→cost 查快取；miss 時 classifySprite 並在上限內收錄。上限保護：模組化地圖
-- 的 sprite 名稱數量沒有上限，滿了就**停收新條目**（本格照樣用剛算出的 cost，
-- 只是不記憶）：整表重建會把幾千條熱條目一起丟掉、之後每格重算一整輪，
-- 抖動比失憶更貴。scanCell 與 probeSquareHard 共用。
local function spriteCostOf(state, obj, name)
    local cost = state.spriteCost[name]
    if cost == nil then
        cost = classifySprite(obj, name)
        if state.spriteN < SPRITE_CACHE_MAX then
            state.spriteCost[name] = cost
            state.spriteN = state.spriteN + 1
        end
    end
    return cost
end

-- 回 boolean：這一格是不是硬障礙。軟障礙／殭屍／屍體／行進中車輛／未載入 chunk
-- 直接就地累加到 state 的 working 欄位（回傳只有一個值才不用配置）。
-- l＝本取樣點的橫向偏移（相對 nav 線）：**減速計數**（殭屍/屍體/軟障礙/跟車）
-- 只收行駛線 ±SLOW_BAND_HALF（±3＝路面帶；帶偏移見 step 的取樣註解）——
-- 路肩外 4-5m 的灌木/殭屍不該讓路面上的車減速。hard 不分帶（規劃用全寬）。
local function scanCell(state, vehicle, cell, wx, wy, l)
    local rel = l - state.bandBias
    local inBand = rel >= -SLOW_BAND_HALF and rel <= SLOW_BAND_HALF
    local square = cell:getGridSquare(wx, wy, state.z) -- 用例 ISDestroyCursor.lua:278（nil ＝ chunk 未載入）
    if square == nil then
        -- 未載入不等於淨空：記旗標讓規劃端保守處理，但不當障礙（否則車開到地圖邊緣
        -- 或剛讀檔時會被自己的無知擋死）。同一步的其他橫向照掃。
        state.wUnloaded = true
        if state.wUnloadedS == nil or state.curS < state.wUnloadedS then
            state.wUnloadedS = state.curS -- 最近未載入格弧長（動態煞停距判定用）
        end
        return false
    end

    -- 水面判定看**地板 sprite**而非格級聚合旗標：IsoGridSquare:has 讀的是該格全部
    -- sprite 旗標的聯集，跨河橋的橋面格若殘留水面 sprite 會被聯集誤判成硬障礙、
    -- 自駕永遠過不了橋。原版判「這格是水」的標準寫法就是地板檢查
    -- （ISWorldObjectContextMenu.lua:687-688 square:getFloor():hasProperty(water)）。
    local floorObj = square:getFloor()                 -- 用例 ISWorldObjectContextMenu.lua:687
    local hard = floorObj ~= nil and floorObj:hasProperty(F_water) == true -- 用例 :688

    -- 路面對中統計：地板名前綴 blends_street（floor 也是 IsoObject，
    -- getSpriteName 同 IsoObject.java:2235）。名→bool 快取；水面格不計。
    if floorObj ~= nil and not hard then
        local fname = floorObj:getSpriteName()
        if fname ~= nil then
            local isRoad = state.roadIs[fname]
            if isRoad == nil then
                isRoad = find(fname, ROAD_PREFIX_1, 1, true) == 1
                    or find(fname, ROAD_PREFIX_2, 1, true) == 1
                    or find(fname, ROAD_PREFIX_3, 1, true) == 1
                if state.roadIsN < ROAD_CACHE_MAX then
                    state.roadIs[fname] = isRoad
                    state.roadIsN = state.roadIsN + 1
                end
            end
            if isRoad then
                state.wRoadN = state.wRoadN + 1
                state.wRoadSumL = state.wRoadSumL + l
                if l < state.wRoadLo then state.wRoadLo = l end
                if l > state.wRoadHi then state.wRoadHi = l end
            end
        end
    end
    local soft = false
    local thin = false -- 硬障礙來源是細桿（樹幹）：push 時半徑 0

    if not hard then
        local objs = square:getObjects()               -- IsoGridSquare.java:9635（回 PZArrayList）
        local nObj = objs:size()                       -- 迭代慣例 ISButtonPrompt.lua:535-536
        for i = 1, nObj do
            local obj = objs:get(i - 1)
            local name = obj:getSpriteName()           -- IsoObject.java:2235
            if name ~= nil then
                local cost = spriteCostOf(state, obj, name)
                if cost == COST_HARD or cost == COST_HARD_THIN then
                    hard = true
                    if cost == COST_HARD_THIN then thin = true end
                    break
                elseif cost == COST_SOFT then
                    soft = true
                end
            end
        end
    end

    -- 車輛：**格子幾何查詢**——引擎通用碰撞真相在 Lua 曝露面的最佳代理。
    -- getVehicleContainer() 掃 3×3 chunk 的 chunk.vehicles（物理位置驅動）
    -- × isIntersectingSquare（車體多邊形 vs 格子，IsoGridSquare.java:10252-
    -- 10273；用例 DebugContextMenu.lua:145）。舊三路全有盲區、2026-08-29 實
    -- 測全漏：cell:getVehicles() 集合波動（veh=2→1→0）、movingObjects 註冊
    -- 不可靠（連續 9 輪零偵測）、isStopped 假動（軍車判「行進中」不進 hard
    -- 一路推上去）。isStopped 降級為純語意開關：停＝硬障礙要繞；「動」＝跟
    -- 車（假動也吃 vehAheadS 分級煞停，兩態都安全、不再有「消失」態）。
    -- 車體蓋到的每一格都命中 → hard 點天然連片，不需要舊的單點錨膨脹。
    local cv = square:getVehicleContainer()
    if cv ~= nil and cv ~= vehicle then
        -- 排除自己：SCAN_NEAR 只讓過車頭前 2 公尺，長車／拖車仍會佔到取樣格
        state.wVehN = state.wVehN + 1
        -- 跨輪位置比對（2026-08-29 路口實測定讞）：MP 半更新的靜止車 isStopped
        -- 恆回 false（「假動」）→ 不進 hard → plan 永遠不會規劃繞過它的縫，
        -- 跟車軌把車按在原地等一台永遠不動的「行進車」讓路（blocked 摘要
        -- l range [3.04, 8.04] 證明整台皮卡不在點雲）。位置才是不會說謊的觀測：
        -- 同一台車連兩輪掃描（~250ms）位移平方 < 0.09（0.3m ≈ 4.3 km/h 以下）
        -- ＝實質靜止，強制當硬障礙。真慢車（隊友蠕行）被繞掉也比跟死合理。
        -- 三平行陣列以 vehicleId 為鍵、gen 標過期（免清表零配置；id＝short，
        -- BaseVehicle.java:8402；Lua 用例 ISSpawnVehicleUI.lua:149）。
        local vid = cv:getId()
        local still = false
        local pg = state.vehPosGen[vid]
        if pg == state.gen then
            -- 同輪第 2+ 格命中同一台車：沿用本輪判定。位置已寫本輪、再比對
            -- 必回 false——一台車前格 hard 後格 moving 的「同輪雙態」會讓
            -- sig 隨掃描相位跳動（codex 對抗審抓到）
            still = state.vehStill[vid] == true
        else
            local vwx, vwy = cv:getX(), cv:getY()
            if pg == state.gen - 1 then
                local pdx = vwx - state.vehPosX[vid]
                local pdy = vwy - state.vehPosY[vid]
                still = pdx * pdx + pdy * pdy < 0.09
            end
            state.vehPosX[vid] = vwx
            state.vehPosY[vid] = vwy
            state.vehPosGen[vid] = state.gen
            state.vehStill[vid] = still
        end
        if still or cv:isStopped() then                -- BaseVehicle.java:4259-4260
            hard = true                                -- 停著的車＝實體障礙，要繞
        elseif inBand then                             -- 行進中＝跟車情境（帶內才減速）
            state.wMovingVeh = true
            if state.wVehAheadS == nil or state.curS < state.wVehAheadS then
                state.wVehAheadS = state.curS
            end
        end
    end

    -- 動態物件（殭屍）：就算靜態已判 hard，殭屍數仍是規劃端要看的獨立訊號。
    local movs = square:getMovingObjects()             -- IsoGridSquare.java:9605（回 ArrayList<IsoMovingObject>）
    local nMov = movs:size()                           -- 迭代慣例 DebugContextMenu.lua:535-537
    for i = 1, nMov do
        if inBand and instanceof(movs:get(i - 1), "IsoZombie") then -- 用例 DebugContextMenu.lua:537
            state.wZombieN = state.wZombieN + 1
        end
    end

    -- 地面屍體（IsoDeadBody）：引擎放在 staticMovingObjects，**不在** movingObjects
    -- 也不在 getObjects（入列 IsoDeadBody.java:279、容器宣告 IsoGridSquare.java:316；
    -- Lua 讀取用例 ISWorldObjectContextMenu.lua:307）。獨立訊號：屍體壓得過，
    -- 不進 hard/soft、不參與縫隙規劃與簽章，只供速度檔（CorpseSlowdown）。
    -- 屍體會被拖走／焚燒／腐爛消失，不做快取，每輪照掃；多數格 size()==0，
    -- 每格常態成本只多一次跨界呼叫。
    if inBand then
        local smovs = square:getStaticMovingObjects()
        local nSmov = smovs:size()
        for i = 1, nSmov do
            if instanceof(smovs:get(i - 1), "IsoDeadBody") then
                state.wCorpseN = state.wCorpseN + 1
            end
        end
    end

    -- softN 以「格」為單位計數（與 hardN 同一個尺度），一格裡兩張沙發不算兩次。
    if soft and not hard and inBand then
        state.wSoftN = state.wSoftN + 1
    end
    return hard, thin
end

--------------------------------------------------------------------------------
-- 路線幾何
--------------------------------------------------------------------------------

-- 由弧長 s 反查所在段索引。從上一次的位置開始走（前進或倒退都只走差量），
-- 不每步從頭二分／線性搜尋：一輪 35 步的前進總量就是 35 段以內。
local function seekSeg(p, idx, s)
    local ss = p.s
    local hi = p.n - 1
    if idx > hi then idx = hi end
    if idx < 1 then idx = 1 end
    while idx > 1 and ss[idx] > s do idx = idx - 1 end
    while idx < hi and ss[idx + 1] <= s do idx = idx + 1 end
    return idx
end

-- 算出弧長 s 處的中心點與橫向法向，就地寫進 state（不回 table）。
-- 法向：段朝向 h 的前向是 (cos h, sin h)，數學逆時針轉 90° 得 (-sin h, cos h)，
-- 與 MDADFollower 的 heading 慣例同一個平面定義；PZ 世界 Y 向南，此方向＝
-- 行進方向的**右側**（俯視下數學 CCW＝實際順時針），hardL 正號＝車的右邊。
local function centerAt(state, p, s)
    local idx = seekSeg(p, state.segIdx, s)
    state.segIdx = idx
    local t = 0
    local segLen = p.segLen[idx]
    if segLen > 0 then
        t = (s - p.s[idx]) / segLen
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
    end
    local ax, ay = p.x[idx], p.y[idx]
    state.cx = ax + (p.x[idx + 1] - ax) * t
    state.cy = ay + (p.y[idx + 1] - ay) * t
    local h = p.segH[idx]
    state.nx = -sin(h)
    state.ny = cos(h)
end

--------------------------------------------------------------------------------
-- 輪次生命週期
--------------------------------------------------------------------------------

local function beginRound(state, p, sNow, vehicle, now, len, cell)
    if not flagsBound then bindFlags() end

    state.scanning = true
    state.nextMs = now + SCAN_INTERVAL_MS
    state.gen = state.gen + 1          -- 去重代數往前推一格，等於「清空」visited 但零成本
    state.wRoundStartedAt = now
    state.wRain = nil
    state.wActualSurfaceId = SURFACE_UNKNOWN

    state.wHardN = 0
    state.wZombieN = 0
    state.wCorpseN = 0
    state.wSoftN = 0
    state.wMovingVeh = false
    state.wVehAheadS = nil
    state.wVehN = 0
    state.wUnloaded = false
    state.wUnloadedS = nil
    state.wSumS = 0
    state.wSumL = 0
    state.wRoadN = 0
    state.wRoadSumL = 0
    state.wRoadLo = 999
    state.wRoadHi = -999

    local s0 = sNow + SCAN_NEAR
    if s0 < 0 then s0 = 0 end
    local ahead = state.aheadM
    if type(ahead) ~= "number" or ahead ~= ahead or ahead < SCAN_AHEAD then ahead = SCAN_AHEAD end
    local s1 = sNow + ahead
    if s1 > len then s1 = len end
    state.wScanS = s0
    state.endS = s1
    -- 起點退一步、橫向游標設成越界，讓主迴圈的第一次「換步」正好落在 s0；
    -- 這同時處理了 s0 > s1（車已在路線末端）的情況：第一次換步就結束本輪。
    state.curS = s0 - SCAN_STEP
    state.curL = LAT_N + 1

    state.segIdx = seekSeg(p, state.baseIdx, s0)
    state.baseIdx = state.segIdx
    -- 帶偏移於輪首鎖定（輪中 driver 更新 scanBias 不影響進行中的輪）
    local sb = state.scanBias
    if type(sb) ~= "number" or sb ~= sb then sb = 0 end
    state.bandBias = sb

    local z = vehicle:getZ()                            -- IsoMovingObject 座標慣例（車在地面層）
    state.z = z - z % 1
    -- Lua global getClimateManager() is LuaManager.java:11469-11472;
    -- ClimateManager.isRaining is ClimateManager.java:588-590. Unknown stays
    -- nil (wet-conservative downstream) rather than silently treated as dry.
    if type(getClimateManager) == "function" then
        local climate = getClimateManager()
        if climate ~= nil and type(climate.isRaining) == "function" then
            state.wRain = climate:isRaining() == true
        end
    end
    -- Current-floor evidence is sampled once per round, not per frame:
    -- IsoCell.getGridSquare :3189, IsoGridSquare.getFloor :5025 and
    -- IsoObject.getSpriteName :2235 in the 42.20.4 decompiled source.
    local wx, wy = vehicle:getX(), vehicle:getY()
    wx, wy = wx - wx % 1, wy - wy % 1
    local square = cell:getGridSquare(wx, wy, state.z)
    if square ~= nil then
        local floorObj = square:getFloor()
        if floorObj ~= nil then
            state.wActualSurfaceId = floorSurfaceId(floorObj:getSpriteName())
        end
    end
end

local function finishRound(state, now)
    -- 雙緩衝換手：交換兩組陣列的**參考**（O(1)、零配置），比逐項搬移便宜，
    -- 也保證呼叫端在掃描進行中讀到的永遠是上一輪的完整快照。
    local ts, tl = state.hardS, state.hardL
    local txw, tyw = state.hardX, state.hardY
    local tr = state.hardR
    state.hardS = state.wHardS
    state.hardL = state.wHardL
    state.hardX = state.wHardX
    state.hardY = state.wHardY
    state.hardR = state.wHardR
    state.wHardS = ts
    state.wHardL = tl
    state.wHardX = txw
    state.wHardY = tyw
    state.wHardR = tr

    state.hardN = state.wHardN
    state.zombieN = state.wZombieN
    state.corpseN = state.wCorpseN
    state.softN = state.wSoftN
    state.movingVeh = state.wMovingVeh
    state.vehAheadS = state.wVehAheadS
    state.vehN = state.wVehN
    state.unloaded = state.wUnloaded
    state.unloadedS = state.wUnloadedS
    state.rain = state.wRain
    state.actualSurfaceId = state.wActualSurfaceId
    state.roundStartedAt = state.wRoundStartedAt
    state.completedBandBias = state.bandBias
    -- 簽章：障礙的「數量 + 縱向分布 + 橫向分布」三者任一有變就會變。純整數運算，
    -- 呼叫端只拿它做 ~= 比較（不是雜湊安全性），碰撞的代價只是少重規劃一次。
    state.sig = state.wHardN * 7919 + state.wSumS * 31 + state.wSumL
    -- 樣本不足、橫跨 >10m、或鋪面碰到掃描帶端點＝無路面／停車場／路口歧義。
    -- 端點截斷時觀測 span 只是寬度下界，不能拿「看見 10m」證明整體只有 10m。
    -- 歧義時 roadC 與 road band 一起撤銷，退回 nav 線，不硬掰。
    local roadSpan = state.wRoadHi - state.wRoadLo
    local roadEdgesVisible = state.wRoadLo > state.bandBias + LAT[1] + ROAD_EDGE_GAP
        and state.wRoadHi < state.bandBias + LAT[LAT_N] - ROAD_EDGE_GAP
    if state.wRoadN >= ROAD_MIN_N and roadSpan <= ROAD_MAX_SPAN and roadEdgesVisible then
        state.roadC = state.wRoadSumL / state.wRoadN
        -- 帶邊界：格心 ± 半格（格心 l=-4.5 的路面格實際覆蓋 [-5,-4]）
        state.roadLo = state.wRoadLo - 0.5
        state.roadHi = state.wRoadHi + 0.5
    else
        state.roadC = nil
        state.roadLo = nil
        state.roadHi = nil
    end
    state.roadN = state.wRoadN
    state.scanS = state.wScanS
    state.scanEndS = state.endS
    state.stamp = now
    state.ready = true
    state.scanning = false

    -- visited 的鍵只增不減（generation 比對不刪鍵），車一路開下去等於一條慢性洩漏。
    -- 每 VISITED_ROUNDS 輪整個丟掉重建一次——這是本模組**唯一**允許的週期性配置，
    -- 頻率 64 × 250ms ＝ 16 秒一次，且發生在輪次邊界而不是掃描中途。
    state.rounds = state.rounds + 1
    if state.rounds % VISITED_ROUNDS == 0 then
        state.visited = {}
    end
end

--------------------------------------------------------------------------------
-- 公開 API
--------------------------------------------------------------------------------

-- 整個模組唯一配置 table 的地方。欄位一次到位，之後只就地改值。
function MDADSensor.newState()
    return {
        -- 節流／輪次
        nextMs = 0,
        scanning = false,
        rounds = 0,
        gen = 0,
        profile = nil,      -- 上一次 step 看到的剖面（換路線偵測，只做參考比較）

        -- 世界格去重與 sprite 成本快取
        visited = {},
        spriteCost = {},
        spriteN = 0,

        -- 進行中這一輪的游標與累加器（w 前綴 ＝ working，呼叫端不要讀）
        curS = 0,
        endS = 0,
        curL = LAT_N + 1,
        segIdx = 1,
        baseIdx = 1,
        cx = 0, cy = 0,
        nx = 0, ny = 1,
        z = 0,
        wHardS = {}, wHardL = {}, wHardX = {}, wHardY = {}, wHardR = {},
        wHardN = 0,
        wZombieN = 0,
        wCorpseN = 0,
        wSoftN = 0,
        wMovingVeh = false,
        wVehAheadS = nil,  -- 最近「行進中」前車弧長（本輪 working）
        wUnloaded = false,
        wSumS = 0,
        wSumL = 0,
        wRoadN = 0,
        wRoadSumL = 0,
        wRoadLo = 999,
        wRoadHi = -999,
        roadIs = {},        -- 地板名 → 是否路面（跨路線重用，同 spriteCost 理由）
        roadIsN = 0,
        scanBias = 0,       -- 行駛線相對 nav 線的偏移（driver 每輪同步；帶跟隨用）
        bandBias = 0,       -- 本輪鎖定的帶偏移（beginRound 快照 scanBias）
        wScanS = 0,
        wRain = nil,
        wActualSurfaceId = SURFACE_UNKNOWN,
        wRoundStartedAt = 0,

        -- 已完成的結果（呼叫端只讀這一組）
        hardS = {}, hardL = {}, hardX = {}, hardY = {}, hardR = {}, -- hardX/Y＝世界座標（掃掠複驗）；hardR＝逐點半徑（樹幹 0）
        hardN = 0,
        zombieN = 0,
        corpseN = 0,
        softN = 0,
        movingVeh = false,
        vehAheadS = nil,    -- 最近「行進中」前車弧長（跟車分級煞停用；nil＝無）
        unloaded = false,
        sig = 0,
        roadC = nil,        -- 路面帶中心相對 nav 線的橫向偏移（nil＝本輪無樣本）
        roadLo = nil,       -- 路面帶左緣／右緣（相對 nav 線；Corridor 縫隙帶內優先用）
        roadHi = nil,
        roadN = 0,          -- 上輪路面格樣本數（診斷：0＝地板 sprite 沒被認出）
        ready = false,
        vehN = 0,           -- 上輪掃描帶內車輛命中格數（格級幾何查詢；遙測與推撞 gate 用）
        wVehN = 0,
        -- 跨輪車輛位置快照（vehicleId 鍵、gen 過期標記——假動判定用；常駐
        -- 不清，鍵數＝見過的車輛數量級，值全為數字）
        vehPosX = {}, vehPosY = {}, vehPosGen = {}, vehStill = {},
        aheadM = SCAN_AHEAD, -- 掃描帶前伸長（高速檔由 driver 拉長：120km/h 需 ~110m 才煞得住）
        scanS = 0,
        scanEndS = 0,
        stamp = 0,
        rain = nil,            -- nil＝weather API unavailable; control treats as wet
        actualSurfaceId = SURFACE_UNKNOWN,
        roundStartedAt = 0,
        completedBandBias = 0,
    }
end

-- 重新啟動自駕時呼叫，step 偵測到換路線時也走這裡。就地清，不重建 table：visited 靠
-- generation 前推失效，兩組硬障礙緩衝只把長度歸零（陣列容量留著給下一條路線用）。
-- sprite 成本快取**刻意不清**——它與路線無關，跨路線重用才是它存在的理由。
function MDADSensor.reset(state)
    if type(state) ~= "table" then return end

    state.nextMs = 0
    state.scanning = false
    state.profile = nil
    state.gen = state.gen + 1

    state.curS = 0
    state.endS = 0
    state.curL = LAT_N + 1
    state.segIdx = 1
    state.baseIdx = 1
    state.wHardN = 0
    state.wZombieN = 0
    state.wCorpseN = 0
    state.wSoftN = 0
    state.wMovingVeh = false
    state.wVehAheadS = nil
    state.wUnloaded = false
    state.wSumS = 0
    state.wSumL = 0
    state.wRoadN = 0
    state.wRoadSumL = 0
    state.wRoadLo = 999
    state.wRoadHi = -999
    state.wScanS = 0
    state.wRain = nil
    state.wActualSurfaceId = SURFACE_UNKNOWN
    state.wRoundStartedAt = 0
    state.vehN = 0
    state.wVehN = 0

    state.hardN = 0
    state.zombieN = 0
    state.corpseN = 0
    state.softN = 0
    state.movingVeh = false
    state.vehAheadS = nil
    state.unloaded = false
    state.sig = 0
    state.roadC = nil
    state.roadLo = nil
    state.roadHi = nil
    state.roadN = 0
    state.bandBias = 0
    state.ready = false
    state.scanS = 0
    state.scanEndS = 0
    state.stamp = 0
    state.rain = nil
    state.actualSurfaceId = SURFACE_UNKNOWN
    state.roundStartedAt = 0
    state.completedBandBias = 0
end

-- working buffer 推一個硬點（含簽章累加；l4＝l*4 的整數版；r＝該點半徑——
-- 樹幹 0、整格箱型物 OBS_HALF，Corridor/sweep 逐點膨脹用）。滿了靜默丟棄；
-- HARD_MAX=768 對掃描帶最多 658 個唯一格留 110 格。Driver 另在快照尾端附加
-- 最多 4 個虛擬 ban，不經 pushHard，也不占這個 sensor 上限。
local function pushHard(state, s, l, l4, wx, wy, r)
    local n = state.wHardN
    if n >= HARD_MAX then return end
    n = n + 1
    state.wHardN = n
    state.wHardS[n] = s
    state.wHardL[n] = l
    state.wHardX[n] = wx
    state.wHardY[n] = wy
    state.wHardR[n] = r
    state.wSumS = state.wSumS + (s - s % 1)
    state.wSumL = state.wSumL + l4
end

-- 每幀呼叫。回 true ＝ 本輪剛完成（呼叫端此時拿結果去規劃）。
function MDADSensor.step(state, profile, sNow, vehicle, now, cell)
    if type(state) ~= "table" then return false end
    if type(profile) ~= "table" then return false end
    if vehicle == nil or cell == nil then return false end
    if type(sNow) ~= "number" or type(now) ~= "number" then return false end

    -- 換路線：舊結果的 hardS 是對舊幾何的弧長，套到新路線上是徹底錯的座標——
    -- 不能只作廢進行中的那一輪，已完成的快照也必須一起失效，否則呼叫端會拿舊障礙
    -- 規劃新路線最多 250ms。走 reset 是為了不把同一份失效邏輯抄兩遍；它只改數值
    -- 欄位、不重建 table，而且只在參考真的變了的那一幀跑（正常情況每條路線一次）。
    -- reset 把 nextMs 歸零，所以新路線的第一輪立刻開始，不等節流窗口。
    -- **排在剖面可掃檢查之前**：新剖面還在建表時就要先把舊快照作廢（ready=false），
    -- 否則建表那幾幀呼叫端仍會讀到舊路線的障礙座標。
    if state.profile ~= profile then
        MDADSensor.reset(state)
        state.profile = profile
    end

    -- 剖面還在建表（length 要等 geometry 相位跑完才填）時沒有幾何可掃。
    local len = profile.length
    if type(len) ~= "number" or len <= 0 then return false end
    if profile.n < 2 then return false end

    if not state.scanning then
        if now < state.nextMs then return false end   -- ① 節流的 O(1) 早退
        beginRound(state, profile, sNow, vehicle, now, len, cell)
    end

    local visited = state.visited
    local gen = state.gen
    local budget = SCAN_BUDGET

    while budget > 0 do
        local li = state.curL
        if li > LAT_N then
            -- 換到下一步：算一次中心點與法向（一次 sin + 一次 cos，攤在 10 格上）
            local s = state.curS + SCAN_STEP
            if s > state.endS then
                finishRound(state, now)
                return true
            end
            state.curS = s
            centerAt(state, profile, s)
            li = 1
        end

        -- 橫向取樣以**行駛線**為中心（LAT ± 帶偏移）：掃描帶若釘死在 nav 線上，
        -- 線偏得越多、帶能看到的路面越少 → 路面對中樣本殘缺 → 校正收斂不足，
        -- 行駛線永遠停在路緣（2026-08-28 視覺化實證：藍點列壓在路緣、路面帶
        -- 綠點只有半邊）。bandBias 於輪首鎖定（beginRound），l 仍是「相對
        -- nav 線」的座標——下游 hardL／roadC／縫隙規劃語意全部不變。
        local l = LAT[li] + state.bandBias
        local wx = state.cx + l * state.nx
        local wy = state.cy + l * state.ny
        -- 取整：Kahlua 的 % 是截斷式（KahluaThread.java:1060-1066 用 (int)(v1/v2)），
        -- n - n % 1 對**負數**是向 0 取整、不是 floor（標準 Lua 才是 floor）。
        -- 這裡安全的前提是 PZ 世界座標恆非負（官方地圖 cell 座標 0 起跳；KEY_MUL
        -- 的單射性也建立在同一前提上）——本檔所有取整只用於非負值。
        wx = wx - wx % 1
        wy = wy - wy % 1

        local key = wx * KEY_MUL + wy
        if visited[key] ~= gen then
            visited[key] = gen
            local hard, thin = scanCell(state, vehicle, cell, wx, wy, l)
            if hard then
                -- 世界座標記格心（掃掠複驗用真實幾何，不受弧座標折點失真影響）；
                -- 樹幹＝細桿半徑 0（整格肥半徑會把路緣樹排判成擋路）
                local pr = thin and 0 or OBS_HALF_R
                local l4 = l * 4
                l4 = l4 - l4 % 1
                pushHard(state, state.curS, l, l4, wx + 0.5, wy + 0.5, pr)
            end
            -- 只有真的查了世界格才扣預算；被去重擋掉的取樣點是純 Lua 的一次表查詢，
            -- 一輪最多 210 次，讓它們在同一幀裡跑完比多拖一幀便宜。
            budget = budget - 1
        end

        state.curL = li + 1
    end

    return false
end

-- 冷路徑探測共用的單格硬分類；只讀 square、只更新既有 sprite 快取，
-- 不碰 wHardN／wUnloaded 等掃描 working buffer，也不配置 table。
-- 回 true,kind＝水／硬物；false＝淨空；nil,kind＝getter 無法提供分類，呼叫端 fail-closed。
local function probeSquareHard(state, square)
    local floorObj = square:getFloor()
    if floorObj ~= nil and floorObj:hasProperty(F_water) == true then
        return true, "water"
    end

    local cache = state.spriteCost
    if type(cache) ~= "table" or type(state.spriteN) ~= "number" then
        return nil, "cache"
    end
    local objs = square:getObjects()
    if objs == nil then return nil, "objects" end
    local nObj = objs:size()
    for i = 1, nObj do
        local obj = objs:get(i - 1)
        local name = obj:getSpriteName()
        if name ~= nil then
            local cost = spriteCostOf(state, obj, name)
            if cost == COST_HARD then return true, "hard" end
            if cost == COST_HARD_THIN then return true, "hardThin" end
        end
    end
    return false, nil
end

-- OBB（F/N 軸）對 1×1 世界格的完整 SAT：兩個 OBB 軸＋世界 X/Y 軸。
-- 只傳純量；不建 corner table。邊界相切也算命中，安全探測不得把接觸判成 clear。
local function orientedRectHitsSquare(cx, cy, fx, fy, nx, ny, halfF, halfN, gx, gy)
    local dx = gx + 0.5 - cx
    local dy = gy + 0.5 - cy
    if abs(dx * fx + dy * fy) >
            halfF + 0.5 * (abs(fx) + abs(fy)) then return false end
    if abs(dx * nx + dy * ny) >
            halfN + 0.5 * (abs(nx) + abs(ny)) then return false end
    if abs(dx) > halfF * abs(fx) + halfN * abs(nx) + 0.5 then return false end
    if abs(dy) > halfF * abs(fy) + halfN * abs(ny) + 0.5 then return false end
    return true
end

local function finite(n)
    return type(n) == "number" and n * 0 == 0
end

-- near/rear 共用實作。public API 用 pcall 包住本函式：任一 Java getter／pool
-- 失敗都回 unloaded，而不是把未知誤報成 clear。函式內只有純量 local。
local function probeDirectional(state, vehicle, cell, bodyX, bodyY,
        fx, fy, nx, ny, halfW, halfL, rear, travelM, lateralM)
    if type(state) ~= "table" or vehicle == nil or cell == nil
            or not finite(bodyX) or not finite(bodyY)
            or not finite(fx) or not finite(fy) or not finite(nx) or not finite(ny)
            or not finite(halfW) or halfW <= 0
            or not finite(halfL) or halfL <= 0 then
        return "unloaded", bodyX, bodyY, "geometry"
    end

    -- F/N 是呼叫端已正規化的車身平面基底；偏離單位正交基底就 fail-closed，
    -- 否則 SAT 的投影半徑不再代表公尺。
    local f2 = fx * fx + fy * fy
    local n2 = nx * nx + ny * ny
    if abs(f2 - 1) > 0.02 or abs(n2 - 1) > 0.02
            or abs(fx * nx + fy * ny) > 0.02 then
        return "unloaded", bodyX, bodyY, "geometry"
    end

    local rectX, rectY, halfF, halfN
    if finite(lateralM) then
        local lateralAbs = lateralM
        if lateralAbs < 0 then lateralAbs = -lateralAbs end
        -- Union of current body swept laterally laneStart→target, with the near
        -- longitudinal horizon [s0-halfL, s0+halfL+2].
        rectX = bodyX + fx + nx * lateralM * 0.5
        rectY = bodyY + fy + ny * lateralM * 0.5
        halfF = halfL + 1 + 0.15
        halfN = halfW + lateralAbs * 0.5 + 0.15
    elseif rear then
        local d = travelM
        if d == nil then d = 4 end
        if not finite(d) or d <= 0 then
            return "unloaded", bodyX, bodyY, "geometry"
        end
        -- 後保桿往後 d 公尺的直線 swept strip；前後／左右各加原生車體
        -- polyPlusRadius 的 0.15m 餘裕（BaseVehicle.java:4133-4168）。
        rectX = bodyX - (halfL + d * 0.5) * fx
        rectY = bodyY - (halfL + d * 0.5) * fy
        halfF = d * 0.5 + 0.15
        halfN = halfW + 0.15
    else
        -- current OBB 與車頭前方 1m 的聯集仍是一個 OBB。
        rectX = bodyX + 0.5 * fx
        rectY = bodyY + 0.5 * fy
        halfF = halfL + 0.5
        halfN = halfW
    end

    if not flagsBound then bindFlags() end
    local z = vehicle:getZ()
    if not finite(z) then return "unloaded", bodyX, bodyY, "geometry" end
    z = z - z % 1

    local reachX = halfF * abs(fx) + halfN * abs(nx)
    local reachY = halfF * abs(fy) + halfN * abs(ny)
    -- 左／上多列舉一格，讓「矩形邊界恰在格界」的相切格也進 SAT；SAT 會濾掉
    -- 其餘 AABB 外格，不會因多列舉而誤讀 nil chunk。
    local gx0 = rectX - reachX
    gx0 = gx0 - gx0 % 1 - 1
    local gx1 = rectX + reachX
    gx1 = gx1 - gx1 % 1
    local gy0 = rectY - reachY
    gy0 = gy0 - gy0 % 1 - 1
    local gy1 = rectY + reachY
    gy1 = gy1 - gy1 % 1

    -- getGridSquare 用例 ISDestroyCursor.lua:278；nil 代表 candidate 所在 chunk
    -- 未載入，定向安全探測必須回 unloaded。getVehicleContainer 的格級幾何來源為
    -- IsoGridSquare.java:10252-10273（內部即呼叫 isIntersectingSquare）。
    for gx = gx0, gx1 do
        for gy = gy0, gy1 do
            if orientedRectHitsSquare(rectX, rectY, fx, fy, nx, ny,
                    halfF, halfN, gx, gy) then
                local hitX, hitY = gx + 0.5, gy + 0.5
                local square = cell:getGridSquare(gx, gy, z)
                if square == nil then return "unloaded", hitX, hitY, "gridSquare" end
                local hard, kind = probeSquareHard(state, square)
                if hard == nil then return "unloaded", hitX, hitY, kind end
                if hard then return "hard", hitX, hitY, kind end

                local cv = square:getVehicleContainer()
                if cv ~= nil and cv ~= vehicle then
                    return "vehicle", hitX, hitY, "vehicle"
                end
            end
        end
    end

    -- MP 的格級 container 可能先回自己、遮住同格第二台車；再走 IsoCell 全域 Set
    -- （IsoCell.java:2731-2733），逐台以 BaseVehicle:isIntersectingSquare(gx,gy,z)
    -- 的真車體多邊形判定（BaseVehicle.java:5704-5713），不使用中心距圓形替代。
    local vehicles = cell:getVehicles()
    if vehicles == nil then return "unloaded", rectX, rectY, "vehiclePool" end
    local it = vehicles:iterator()
    if it == nil then return "unloaded", rectX, rectY, "vehiclePool" end
    while it:hasNext() do
        local other = it:next()
        if other ~= nil and other ~= vehicle then
            for gx = gx0, gx1 do
                for gy = gy0, gy1 do
                    if orientedRectHitsSquare(rectX, rectY, fx, fy, nx, ny,
                            halfF, halfN, gx, gy)
                            and other:isIntersectingSquare(gx, gy, z) then
                        return "vehicle", gx + 0.5, gy + 0.5, "vehicle"
                    end
                end
            end
        end
    end
    return "clear", nil, nil, nil
end

-- 車輛周邊環形探測（調頭安全檢查；事件驅動冷路徑，driver 節流呼叫、非每幀）。
-- 回 true＝半徑內有硬障礙（牆／樹／水面／別台車）或未載入格（不知道就別原地轉，
-- fail-safe）。走廊掃描沿**路線**掃——路線反向要調頭時，車後方與側面全是走廊
-- 盲區，原地耦力旋轉的車身掃掠 ~2.5m 貼牆貼車就撞（2026-08-28 使用者需求：
-- 調頭前檢查左右）。與走廊掃描共用 sprite 成本快取；**不碰 working 欄位**，
-- 掃描輪進行中呼叫也安全。r=3 → 最多 37 格，一次性成本。
function MDADSensor.probeAround(state, vehicle, cell, radius)
    if type(state) ~= "table" or not vehicle or not cell then return true end
    if not flagsBound then bindFlags() end
    local cx, cy = vehicle:getX(), vehicle:getY()
    local z = vehicle:getZ()
    z = z - z % 1
    local r = radius or 3
    local r2 = r * r
    local gx0 = cx - r
    gx0 = gx0 - gx0 % 1
    local gy0 = cy - r
    gy0 = gy0 - gy0 % 1

    -- 車輛：**全域列舉**（cell:getVehicles() 回 Set，42.20.4 無 get(int)，用
    -- iterator——出處同 beginRound 的車輛快照註解）。不依賴逐格 movingObjects：
    -- MP 靜止車的 movingSquare 註冊不可靠，走廊掃描的同一個盲區在這裡的代價
    -- 是「探測回 clear、原地旋轉直接撞上旁邊的救護車」（2026-08-28 實機）。
    -- 中心距 < r + 2.5（車身半長 ~2.3 ＋餘裕）就算擋。逐格分支保留當雙保險。
    if type(cell.getVehicles) == "function" then
        local set = cell:getVehicles()
        if set ~= nil then
            local vr = r + 2.5
            local vr2 = vr * vr
            local it = set:iterator()
            while it:hasNext() do
                local v = it:next()
                if v ~= nil and v ~= vehicle then
                    local dvx = v:getX() - cx
                    local dvy = v:getY() - cy
                    if dvx * dvx + dvy * dvy <= vr2 then return true end
                end
            end
        end
    end
    for gx = gx0, cx + r do
        for gy = gy0, cy + r do
            local dx = gx + 0.5 - cx
            local dy = gy + 0.5 - cy
            if dx * dx + dy * dy <= r2 then
                local square = cell:getGridSquare(gx, gy, z)
                if square == nil then return true end
                -- 只有明確的 false（分類完成且淨空）才放行；nil＝sprite 快取或
                -- getObjects 取不到分類，不知道就別原地轉（與 square == nil 同調）
                local hard = probeSquareHard(state, square)
                if hard ~= false then return true end
                local movs = square:getMovingObjects()
                local nMov = movs:size()
                for i = 1, nMov do
                    local mv = movs:get(i - 1)
                    if instanceof(mv, "BaseVehicle") and mv ~= vehicle then return true end
                end
                -- 格級幾何查詢（同 scanCell 的理由）：全域列舉／movingObjects
                -- 都可能漏掉 streaming 波動車，貼著看不見的車原地旋轉＝掃到
                local cv = square:getVehicleContainer()
                if cv ~= nil and cv ~= vehicle then return true end
            end
        end
    end
    return false
end

-- 事件驅動 near 探測：current OBB＋車頭前方 1m。
-- bodyX/bodyY 與 F/N 由 Driver 冷路徑算好；本函式刻意不呼叫需要 caller 提供
-- output vector 的 vehicle:getForwardVector（BaseVehicle.java:4242-4244），避免在
-- Sensor 內取得／遺失 pooled Vector3f。回 status,hitX,hitY,kind,detail：
-- clear|hard|vehicle|unloaded；只有 protected getter throw 時 detail 帶原始錯誤。
function MDADSensor.probeNear(state, vehicle, cell, bodyX, bodyY,
        fx, fy, nx, ny, halfW, halfL)
    local ok, status, hitX, hitY, kind = pcall(probeDirectional,
        state, vehicle, cell, bodyX, bodyY, fx, fy, nx, ny,
        halfW, halfL, false, 0)
    if not ok then return "unloaded", bodyX, bodyY, "getter", tostring(status) end
    return status, hitX, hitY, kind, nil
end

function MDADSensor.probeLateral(state, vehicle, cell, bodyX, bodyY,
        fx, fy, nx, ny, halfW, halfL, lateralM)
    local ok, status, hitX, hitY, kind = pcall(probeDirectional,
        state, vehicle, cell, bodyX, bodyY, fx, fy, nx, ny,
        halfW, halfL, false, 0, lateralM)
    if not ok then return "unloaded", bodyX, bodyY, "getter", tostring(status) end
    return status, hitX, hitY, kind, nil
end

-- 事件驅動 rear 探測：後保桿往後 travelM（預設 4m）的定向直線 strip。
-- 禁止改用 probeAround 的圓形／中心距判定：前方 blocker 或側車不在倒車 sweep 內。
function MDADSensor.probeRear(state, vehicle, cell, bodyX, bodyY,
        fx, fy, nx, ny, halfW, halfL, travelM)
    local ok, status, hitX, hitY, kind = pcall(probeDirectional,
        state, vehicle, cell, bodyX, bodyY, fx, fy, nx, ny,
        halfW, halfL, true, travelM)
    if not ok then return "unloaded", bodyX, bodyY, "getter", tostring(status) end
    return status, hitX, hitY, kind, nil
end
