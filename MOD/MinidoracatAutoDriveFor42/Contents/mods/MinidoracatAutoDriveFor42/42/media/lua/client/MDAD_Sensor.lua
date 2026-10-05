-- MDAD_Sensor.lua — M4 走廊掃描（client：整個自駕唯一會讀「世界格」的地方）
--
-- 分層：只回答可載入、可在時間預算內完成的前方走廊；請求距離與實際完成範圍分開。
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
--     state.hardL[i]   第 i 個硬障礙的橫向偏移（公尺；數學 CCW 法向為正＝PZ 世界的行進方向右側）：命中的取樣點
--     state.hardLc[i]  同一點引擎形狀位置（hardX/Y）的橫向偏移（同一局部框）；hardW[i]＝掃掠模型的橫向半寬
--                      （方塊＝半邊×(|nx|+|ny|)，圓＝半徑）——擋線判定用這一組，縫隙搜尋仍用 hardL／hardR
--     state.softN      軟障礙格數（可推開的家具／路邊雜物：撞得過但該減速）
--     state.zombieN    走廊內殭屍數（±SLOW_BAND_HALF 減速帶；速度檔用）
--     state.zomN       混合軟目標（s,l）筆數（±4.5 帶），座標語意同 hardS／hardL
--                      zomIsCorpse[i]：屍體端點 true／殭屍 false；zomOverflow 超過 ZOM_MAX 時軟縫棄權
--                      zomKind[i]：每個槽的種類字串 "zombie"／"corpse"／"animal"（大型動物）／"small"（小型動物）／
--                      "player"（車外的其他玩家）；每個槽都要寫（含殭屍、屍體），重用槽不得留上一輪的種類
--     state.corpseN    走廊內地面屍體數；另以長軸兩端點併入 zomS/zomL，同一次軟避讓
--     state.animalN／smallN／playerN  走廊內（±SLOW_BAND_HALF）大型動物／小型動物／其他玩家數；
--                      animalNearS／smallNearS／playerNearS 各類帶內最近弧長（同 zombieNearS；nil＝無）
--     state.stopN      停等目標（動物、車外玩家）另存筆數，上限 STOP_MAX：stopS/stopL/stopKind/stopVl 同 zom 座標語意，
--                      不受 zomOverflow 影響；stopOverflow＝收不下，stopOverS／stopOverKind＝第一個收不下的弧長與種類
--     state.movingVeh  走廊內有**行進中**的別台車（跟車情境，不是靜態障礙）
--     state.trfN       行進中車輛（會車／跟車）筆數，上限 TRF_MAX；逐車一筆：
--                      trfS0/trfS1 車身弧長區間、trfL0/trfL1 橫向區間（同 hardS／hardL 座標）、
--                      trfVs/trfVl 沿路線前向／右向速度（m/s；false＝首次看到、還沒有位移可算）、
--                      trfT 命中當下的時戳（呼叫端依年齡外推）、trfId 車輛 id（Driver 合併伺服器轉送時去重）；
--                      trfOverflow 超過上限。Driver 會在完成輪之後把伺服器轉送的遠方車接在尾端（Drive.mergeRelay）
--     state.unloaded   走廊內有未載入 chunk（規劃要保守：不是淨空，是不知道）
--     state.gateS/gateX/gateY  本輪最近一格「Knox Pass 會開的關門」的弧長與世界格心（nil＝沒有）；
--                      gateHard＝false（遠處：只截可視前緣）／"near"／"latch"（同格另當硬物，見 gateCell）。
--                      請求欄 state.gateNearM 由 Driver 每輪寫（Drive.updatePerception）
--     state.gateNoS/gateNoX/gateNoY/gateNoWhy  本輪中央帶內最近一格「Knox Pass 不會替這台車開的關門」（API 回
--                      false＋why）的弧長、世界格心與原因代碼（nil＝沒有）；那格照舊整格硬物，只供 Driver 提示（gateNoCell）
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
-- ② 分幀：每幀最多 MDADDynamics.scanBudget(平均幀時) 格（60 FPS 以上 56 格，更慢按幀時放大、最多 3 倍，
--    感知占幀時的比例固定）。可負擔視距按「名目 375ms 內掃得完」算；一輪跑完才開下一輪（最早在上一輪
--    開始後 250ms），不會重疊。
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
if not MDADDynamics then require "MDAD_Dynamics" end
local sin, cos, abs, sqrt = math.sin, math.cos, math.abs, math.sqrt
local find = string.find

--------------------------------------------------------------------------------
-- 調校常數
--------------------------------------------------------------------------------

local SCAN_INTERVAL_MS = 250   -- 兩輪掃描的間隔（自輪次「開始」起算）
local SCAN_NEAR = 2            -- 掃描起點：車前 2 公尺（車身本體不算障礙）
local SCAN_AHEAD = MDADDynamics.PERCEPTION_DEFAULT_M
local SCAN_STEP = 1            -- 沿路線的取樣步長（公尺，＝一格）
-- 每幀世界查詢額度：MDADDynamics.scanBudget(state.frameEwmaMs)（0929o 起隨幀時放大，見該處）
-- 可負擔視距每輪最多回縮這麼多（公尺）：幀時 EWMA 突然變長時前緣不一口氣拉近（2026-09-27
-- 正式服 33 段 eff-regress：一輪縮 9–33m 直接把硬煞帳壓破）。多掃的幾格只讓輪時略長。
local AFFORD_SHRINK_MAX = 4
local VISITED_ROUNDS = 64      -- 每幾輪重建一次 visited 表
local SPRITE_CACHE_MAX = 4096  -- sprite 成本快取條目上限

-- 橫向取樣：以路線中心線的數學 CCW 法向為正（PZ 世界 Y 向南，這個方向是實際的
-- 行進方向**右側**），涵蓋 ±6.5 公尺的走廊（路面＋兩側路肩＋緊鄰草地）。
-- 寬度不是拍腦袋：Corridor 的可行車道範圍＝corridorHalf - needHalf（1.4）。
-- ±5 走廊（可行帶 ±3.6）繞得過**一台**居中靜止車（膨脹佔 [-3.1,3.1]、兩側各剩
-- 0.5m），但**兩台並排**（實佔 l∈[-2,3]、膨脹後 [-4.1,5.1]）就整帶堵死——
-- 2026-08-28 實機：路口兩台並排車，左右明明有空間（在走廊外）卻 blocked 停死。
-- ±7 走廊（可行帶 ±5.6）讓並排車側邊的縫進得了候選集；代價是每輪掃描
-- 14×47=658 格（舊 ±5/36m 為 350 格），每幀基準額度 32→56，仍是 12 幀。
-- 取樣點放在格心（±0.5 … ±6.5）而不是格界，避免 floor 之後兩條相鄰橫向落到
-- 同一格、白掃一次。
local LAT = { -6.5, -5.5, -4.5, -3.5, -2.5, -1.5, -0.5, 0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5 }
local LAT_N = 14
-- 斜向／彎道步：1m×1m 取樣格一旋轉就會漏格（旋轉的單位點陣與世界格密度相同，有的格兩點、有的零點），
-- 漏哪格隨每輪起點相位變——E2E zombie-sp turn（0925）彎心殭屍每隔一兩輪就「消失」，軟縫在閃／不閃間
-- 來回跳。軸對齊步維持原取樣；非對齊步改 0.5m 橫向×0.5m 步長：點陣覆蓋半徑 0.35 < 格內切圓 0.5，
-- 任何旋轉都保證每格至少一點。多出的點絕大多數被 visited 去重擋掉（不扣預算），只有原本漏掉的格
-- 才真的查世界。
local LAT_FINE = {}
for i = 1, 27 do LAT_FINE[i] = -6.5 + (i - 1) * 0.5 end
local LAT_FINE_N = 27
local FINE_STEP = 0.5
local ALIGN_EPS = 1e-3 -- 法向分量小於此值＝軸對齊
local CORRIDOR_HALF = 7
-- 寬帶（0929p，使用者裁定「允許繞到道路之外的地方繞路」）：14m 大路整條擋死時一般帶全在路面內、無縫可找。
-- Driver 只在判堵停下（與照寬帶承諾的繞行期間）經 state.wideReq 要求，輪首鎖定（state.wideRound）；
-- 每幀查詢額度不變，perceptionEffective 以橫向條數分攤＝同一輪時前視自動縮短，請求再夾 WIDE_AHEAD_M
-- （28 條×58m ≈ 1624 格，遠低於 HARD_MAX）。完成的快照帶 corridorHalf／wideDone，Driver 的 Corridor 規劃讀它。
local LAT_W = {}
for i = 1, 28 do LAT_W[i] = -13.5 + (i - 1) end
local LAT_W_N = 28
local LAT_W_FINE = {}
for i = 1, 55 do LAT_W_FINE[i] = -13.5 + (i - 1) * 0.5 end
local LAT_W_FINE_N = 55
local CORRIDOR_HALF_W = 14
local WIDE_AHEAD_M = 60
-- 停著判堵的寬帶（Driver 要求 "stop"）：固定看 WIDE_STOP_AHEAD_M、輪時放寬 WIDE_STOP_ROUND_K 倍（每幀額度不變，
-- 只是這一輪多花幾幀）。車停著，多等 1 秒換得完整的繞行線：拖車的保持段要延長一個掛車長，停點又離群
-- trailLen+L2/2，60 FPS 的一般寬帶只看得到 ~47m（E2E 0929u：群在 27m，線尾要 ~75m 才驗得完，候選全數
-- coverage／出口被截短太陡而掛車內切）。起步後回到一般寬帶；已承諾的線守護輪不要求覆蓋（線尾看不到只是慢）。
local WIDE_STOP_AHEAD_M = 100
local WIDE_STOP_ROUND_K = 3
-- 寬帶第二級（1004c，使用者 2026-10-04「障礙多的地方逐漸掃描加大，找得到回到道路的路線就走，真的都不行才考慮
-- 繞道」）：±19.5（40 條）。停點第一級（±13.5）判完仍堵才要（Driver 經 state.wideLevelReq＝2），輪首鎖定
-- state.wideRoundLevel。規劃半寬 half＝19（掃描帶內縮 0.5：車身外緣 ≤ 19、車心偏離最遠 ~17.9，離 RouteTooFar 的
-- SNAP_MAX_M 20 還有 2m 追線誤差）。停點輪 40 條：60 FPS 每幀 4.2 步、仍看 ~96m；承諾後的守護輪 ~33m（線尾看不到只是慢）。
local WIDE2 = { lat = {}, n = 40, fine = {}, fineN = 79, half = 19 }
for i = 1, 40 do WIDE2.lat[i] = -19.5 + (i - 1) end
for i = 1, 79 do WIDE2.fine[i] = -19.5 + (i - 1) * 0.5 end
-- 點雲上限要高於掃描帶的數學上限（溢出＝快照不完整、消費端一律不信）：一般帶 14 條×238m，寬帶第二級停點輪 40 條×100m
local HARD_MAX = math.max(LAT_N * (MDADDynamics.PERCEPTION_HARD_MAX_M - SCAN_NEAR), WIDE2.n * WIDE_STOP_AHEAD_M) + 100

-- 世界格去重的鍵：wx * 100000 + wy。PZ 的地圖座標是非負且遠小於 100000
-- （最大官方地圖 ~15000 格），所以這個線性組合在有效範圍內是單射，
-- 不會有兩格撞同一鍵。用 number 當鍵（不是字串）才不會每格配置一條字串。
local KEY_MUL = 100000

local COST_NONE, COST_SOFT, COST_HARD = 0, 1, 2
local COST_HARD_THIN = 3       -- 細桿硬障礙：無碰撞旗標的籬笆 sprite，格心 0 半徑（引擎本身不給形狀，保守留著）
local COST_TREE = 4            -- 樹幹形狀（樹、室外路燈柱、PhysicsShape=Tree）：見 TRUNK_*
local COST_DOOR = 5            -- 門／柵門 sprite（doorN／doorW）：開關狀態在格級屬性，由 closedDoor(square) 判
local COST_WALL_N, COST_WALL_W, COST_WALL_NW = 6, 7, 8 -- 帶 collideN／collideW 的籬笆：格邊薄牆，見 WALL_*
-- 樹叢（0929t）：引擎 IsoObject.isBush＝f_bushes_1 tileset 或 Bush 屬性（IsoObject.java:6583-6585）。不擋車（原版沒有一個
-- 樹叢 tile 帶碰撞形狀或 HitByCar），但 checkCollisionWithPlant（BaseVehicle.java:3074-3116）對碰到的每叢每幀施
-- −0.025×動量（≥10 km/h 正面 0.1）的衝量（applyImpulseFromHitPlant :5556-5565），不乘 dt：幀越高越黏（E2E
-- semi-long-mp：W900＋貨櫃 230 FPS 路外繞進樹叢地 1 km/h 動不了）。一般帶照舊忽略；寬帶只在 state.bushPassable 不為
-- true 時當 0.3 圓避開——非拖車由 Driver 每幀抵消樹叢阻力（Drive.bushCancel，1004d），拖車或抵消不可用時照舊避開。
local COST_BUSH = 9
local BUSH_R = 0.3             -- 引擎測植物碰撞的半徑（testCollisionWithObject(object, 0.3F)）
local SLOW_BAND_HALF = 3       -- 減速計數帶半寬（±3＝路面帶；hard 仍收全走廊 ±6.5）
-- 硬障礙的點雲幾何對齊引擎的車輛靜態碰撞形狀（0929j；IsoChunk.calcPhysics:1987-2129 決定形狀，尺寸在
-- libPZBullet64：createSolid 半尺寸 (0.5,1,0.5) 置於格心、createTreeBody 半尺寸 (0.1,1,0.1) 置於格 +0.6/+0.6、
-- getWallNShape／getWallWShape 半厚 0.05 置於格的北緣／西緣）。舊制三處與引擎不符，玩家 KI5 Oshkosh 兩次事故
-- 都在這裡：solidtrans 非牆小物當 0.30 圓，引擎卻是 solidtrans＝整格 Solid 方塊（session-012 車身停在方塊面
-- 0–4cm、模型以為還有 0.2m）；樹幹放格心 0 半徑，真的樹幹偏東南 0.1、寬 0.2；籬笆放格心，真的在格邊（差 0.45）。
local OBS_HALF_R = 0.7         -- 整格方塊（solid／solidtrans／樓梯／StopCar／關門）：外接圓半徑（＝Corridor 的 OBS_HALF），規劃用
local BOX_HALF = 0.5           -- 同一方塊的真半邊長：掃掠與接觸以方塊算（圓在軸向多估 0.2，窄縫會被多判不可過）
local TRUNK_OFF = 0.6          -- 樹幹中心＝格 +0.6/+0.6
local TRUNK_R = 0.15           -- 0.2m 見方樹幹的外接圓（半對角 0.141）
local WALL_R = 0.26            -- 格邊薄牆（1×0.1）以兩顆圓覆蓋：中心在 1/4、3/4 處，半徑＝√(0.25²＋0.05²)
-- scanCell 回的形狀碼：BOX 單獨；其餘以 2/4/8/16 相加並存（Kahlua 無位元運算，解碼用 % 取位）
local SHAPE_BOX, SHAPE_WALL_N, SHAPE_WALL_W, SHAPE_TRUNK, SHAPE_THIN, SHAPE_BUSH = 1, 2, 4, 8, 16, 32
-- 車輛精確輪廓（2026-09-02 車陣實爆：格級佔位把 1.8m 寬的車體膨脹成 3 格＋0.7
-- 圓＝4.4m，兩台車之間 2.8m 的真縫被吃到 0.2m，plan 永遠 blocked）。發現
-- 車輛仍靠 getVehicleContainer 的格級幾何查詢（可靠），幾何改用該車的 OBB：四角
-- 走 getWorldPos(com.x±halfW, 0, com.z±halfL)——與引擎自己的碰撞多邊形同式
-- （VehiclePoly.java:52-88；isIntersectingSquare 用 radius 0 的 poly，BaseVehicle.java:
-- 4145、5704-5712）。周長每 VEH_OUTLINE_STEP 取一點、半徑 VEH_OUTLINE_R（相鄰圓相切
-- ＝邊線連續覆蓋；0.15＝引擎自己的 polyPlusRadius 安全圈，BaseVehicle.java:4146）；
-- 車體內部不取點——同尺寸車不可能整台鑽進另一台裡，中心點另補一顆保底。
-- 餘裕帳：真縫 2.8m（兩台 1.8m 車並排）＝車寬 1.8＋兩側各 (0.15 圓＋0.3 need 餘裕)
-- ＝2.7 → 過；r 取 0.3 會把同一縫算成不過（harness (c7) 定案）。
-- 任何 getter 失敗＝退回格級佔位（fail-safe）。
local VEH_OUTLINE_STEP = 0.3
local VEH_OUTLINE_R = 0.15
local VEH_OUTLINE_MAX = 64     -- 單台車輪廓點上限（含中心）：轎車 12.4m 周長／0.3＝41；
                               -- 更長的車（巴士 21m）把步距放大到剛好塞進 63 點——
                               -- **絕不截斷**（截斷＝車側破洞＝假縫）。點雲緩衝剩餘
                               -- 不足 64 時整台退回格級佔位，同理。
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
-- 殭屍位置點雲（2026-09-06 殭屍軟縫）：帶內 ±ZOM_BAND_HALF 的殭屍各記一筆 (s,l)，
-- 以**目前掃描步的局部框**線性化（同 pushVehicleOutline）；只供 Corridor.softZombieLane
-- 出橫向目標，不進 hard／sig／sweep。上限 ZOM_MAX：超過即 zomOverflow（＝殭屍群，
-- 軟縫棄權、交給既有數量減速檔）。zombieN（±SLOW_BAND_HALF 計數）語意不變。
local ZOM_BAND_HALF = 4.5
local ZOM_VL_MAX = 6 -- 殭屍橫向速度上限（m/s；撲擊／位置跳動不當真實走速）
local ZOM_MAX = 64
-- 停等目標（動物、車外的其他玩家）另存一份有界的座標（stopS/stopL/stopKind/stopVl，上限 STOP_MAX）：軟避讓點陣
-- 被殭屍／屍體佔滿（zomOverflow）時軟縫棄權，但 Driver 的停等判讀（Drive.softStopScan）仍要看得到行人與動物。
-- 掃描沿 s 遞增，先收到的是近的；超過上限記 stopOverflow、第一個收不下的弧長 stopOverS 與收不下的之中最重要的
-- 種類 stopOverKind（player > animal > small），
-- Driver 以「那裡之後證明不了淨空」處理。
MDADSensor.STOP_MAX = 16

-- 同一物件（物件為鍵）兩輪位置差／時差的橫向速度（右為正；首次看到＝0），夾 ZOM_VL_MAX。
function MDADSensor.lateralVl(state, mo, wx, wy)
    local px = state.zomPrevX[mo]
    if px == nil then return 0 end
    local dt = (state.nowMs - state.zomPrevT[mo]) / 1000
    if dt <= 0.05 or dt >= 2 then return 0 end
    local vl = ((wx - px) * state.nx + (wy - state.zomPrevY[mo]) * state.ny) / dt
    if vl > ZOM_VL_MAX then return ZOM_VL_MAX elseif vl < -ZOM_VL_MAX then return -ZOM_VL_MAX end
    return vl
end

-- 動物大小門檻（公斤，AnimalData.getWeight，AnimalData.java:1581）：原版定義（media/lua/shared/Definitions/animal/*）
-- 小型成體上限：浣熊公 15、火雞公 12、雞 6、兔 7；大型成體下限：母羊 60、小牛 60、鹿 110、豬 115（實際體重再乘
-- maxWeight 基因 0.5–0.8，AnimalData.getMinWeight/getMaxWeight:1765-1791）。門檻落在兩群之間；幼體（小鹿、
-- 小豬、小羊）長到門檻以上就算大型。讀不到體重一律當大型。
MDADSensor.ANIMAL_BIG_KG = 20

-- 動態物件的軟避讓種類：IsoAnimal 繼承 IsoPlayer（IsoAnimal.java:123），要先判動物。
-- 回 "animal"／"small"／"player"，或 nil（不收：死亡、被抱著、在車上——含自己這台的駕駛與乘客）。
-- 不列舉 cell 的全域動物清單（IsoCell.getAnimals 每次掃整個 objectList 並新建 LinkedList，IsoCell.java:4578-4587），
-- 只看掃描格的 getMovingObjects。用例：instanceof(animal, "IsoAnimal")、animal:isHeld()、animal:getVehicle()
-- （原版 DebugContextMenu.lua:619、ISAnimalUI.lua:15）。
function MDADSensor.softKindOf(mo)
    if instanceof(mo, "IsoAnimal") then
        if mo:isDead() or mo:getVehicle() ~= nil then return nil end
        if mo.isHeld and mo:isHeld() then return nil end -- IsoAnimal.java:2884
        local d = mo.getData and mo:getData()             -- IsoAnimal.java:1260
        local w = d ~= nil and d.getWeight and d:getWeight()
        if type(w) == "number" and w == w and w < MDADSensor.ANIMAL_BIG_KG then return "small" end
        return "animal"
    end
    if instanceof(mo, "IsoPlayer") then
        if mo:isDead() or mo:getVehicle() ~= nil then return nil end
        return "player"
    end
    return nil
end

MDADSensor.SCAN_NEAR = SCAN_NEAR
MDADSensor.CORRIDOR_HALF = CORRIDOR_HALF
MDADSensor.CORRIDOR_HALF_W = CORRIDOR_HALF_W
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
local F_solid, F_solidtrans, F_collideN, F_collideW, F_solidfloor
local F_doorWallN, F_doorWallW, F_open
local flagsBound = false

local function bindFlags()
    F_water = IsoFlagType.water
    F_solidfloor = IsoFlagType.solidfloor
    F_doorN = IsoFlagType.doorN
    F_doorW = IsoFlagType.doorW
    F_solid = IsoFlagType.solid
    F_solidtrans = IsoFlagType.solidtrans
    F_collideN = IsoFlagType.collideN
    F_collideW = IsoFlagType.collideW
    F_doorWallN = IsoFlagType.DoorWallN
    F_doorWallW = IsoFlagType.DoorWallW
    F_open = IsoFlagType.open
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

-- 回 COST_*：硬障礙依引擎的車輛碰撞形狀分成整格方塊（HARD）、樹幹（TREE）、格邊薄牆（WALL_*）；
-- THIN 只剩無碰撞旗標的籬笆 sprite（格心 0 半徑，保守留著）。
--
-- 有碰撞的 sprite：shouldHaveCollision 只看 solid / solidtrans / WallN / WallNW / WallW / collideN /
-- collideW（IsoSprite.java:2083-2093，**不含 solidfloor**）——地板 sprite 根本進不了這個分支，所以不需要
-- （也不能有）solidfloor 豁免；水面的攔截在 scanCell 的「格級地板檢查」，不在這裡。
-- 非籬笆的牆（WallN/W 等）刻意不做方向性薄牆：牆的朝向要配合車的行進方向才有意義，整格保守擋住。
--
-- 無碰撞的 sprite：門框（doorN/doorW）是開口，不能當障礙。`isMoveAbleObject`
-- 是引擎由 StopCar 設的 vehicle collision type（**不是** tile 的 IsMoveAble 屬性），
-- 仍算 SOFT。其後才處理 HitByCar：沒有 collision/StopCar 的
-- street_decoration／trashcontainers 小物可直接放行；實體郵筒、標誌等已在前兩關
-- 收編，不可因 prefix 被穿透。
-- 「這格是水」＝有水面 sprite **且沒有非水的實地板蓋在上面**。橋面格是三層疊的
-- （水 blends_natural_02_x → 路面 blends_street → 橋板 industry_01_39），`getFloor()`
-- 回**第一個**帶 solidfloor 的物件（IsoGridSquare.java:5025-5034）＝載入順序最底層
-- 的水面 → 整排橋中線判成硬障礙、兩個方向都過不了橋（2026-09-04 使用者截圖，
-- (2275,8794) 物件序：street／natural_02_3／industry_01_39，方格 FloorMaterial=Water）。
-- 引擎自己的「水上有地板」也是看 sprite 逐一判（RecalcProperties
-- IsoGridSquare.java:7662-7671 的 nonWaterSolidFloor）。回 (isWater, dryFloorObj)：
-- dryFloorObj＝可通行的地板物件（路面對中統計用），nil＝沒有。
local function waterUnderfoot(square)
    local objs = square:getObjects()
    if objs == nil then return false, nil end
    local n = objs:size()
    local water, dry = false, nil
    for i = 1, n do
        local obj = objs:get(i - 1)
        local sp = obj:getSprite()
        local props = sp ~= nil and sp:getProperties() or nil
        if props ~= nil then
            if props:has(F_water) then
                water = true
            elseif dry == nil and props:has(F_solidfloor) then
                dry = obj
            end
        end
    end
    return water and dry == nil, dry
end

local function classifySprite(obj, name)
    local sprite = obj:getSprite()                     -- 用例 ISWorldObjectContextMenu.lua:1347
    if sprite == nil then return COST_NONE end
    local props = sprite:getProperties()               -- IsoSprite.java:240
    if props == nil then return COST_NONE end

    -- 水面 sprite 帶 solidtrans（blends_natural_02_7：solidfloor＋solidtrans＋water，實機
    -- 2026-09-04 (2274,8795)）→ shouldHaveCollision 為真 → 會被當成小型硬物。水的判定
    -- 只在 waterUnderfoot（有沒有實地板蓋著）；這裡一律不算物件。
    if props:has(F_water) then return COST_NONE end

    -- 籬笆照引擎旗標給形狀（IsoChunk.calcPhysics:2058-2095）：solid／solidtrans＝整格方塊，collideN／collideW
    -- ＝格的北緣／西緣 0.1m 薄牆（HoppableN／WallNTrans 等 tile 屬性載入時就轉成 collideN，IsoWorld.java:870-1017）。
    -- 舊制一律格心 0 半徑：籬笆在近側格邊時模型晚 0.45m 看到、遠側時多擋 0.45m。沒有任何碰撞旗標的籬笆
    -- sprite 引擎不給形狀，仍留格心 0 半徑（保守）。
    if find(name, "fencing_", 1, true) == 1 then
        if props:has(F_solid) or props:has(F_solidtrans) then return COST_HARD end
        local n, w = props:has(F_collideN), props:has(F_collideW)
        if n and w then return COST_WALL_NW end
        if n then return COST_WALL_N end
        if w then return COST_WALL_W end
        return COST_HARD_THIN
    end

    -- 樹先判：引擎在有樹的格只給 Tree 形狀，solid 分支是 else-if（calcPhysics:2048-2064）——大樹（JUMBO／XL，
    -- IsoTree 帶 solid＋StopCar）碰得到的只有樹幹。0929k E2E W 段：整排 JUMBO 樹被 solid 判成整格方塊，
    -- 靠右與繞行都按 1m 方塊算。樹的 sprite 多半不帶碰撞 flag（shouldHaveCollision 看不到），另給
    -- Tree 形狀——實機 2026-08-28：自駕全油撞樹、脫困後原路再撞同一棵。IsoTree 住 getObjects（IsoTree.java:67
    -- extends IsoObject）；instanceof 用例 ISDestroyCursor.lua:308；只在 sprite 快取 miss 時跑一次（同名 sprite
    -- 恆同類）。形狀是格 +0.6/+0.6 的 0.2m 見方樹幹（TRUNK_*）；整格肥半徑曾把路緣樹排判成擋路（2026-08-28）。
    if instanceof(obj, "IsoTree") then return COST_TREE end

    -- solidtrans 同 solid＝整格方塊（calcPhysics:2058-2063）。2026-09-01 曾把 solidtrans 非牆小物（郵筒／垃圾桶／
    -- 消防栓）縮成 0.30 圓（「整格會讓單物擋掉 4m 寬帶」），但車撞上的是引擎的整格方塊：玩家 session-012 Oshkosh
    -- 車身停在方塊面 0–4cm，模型以為還有 0.2m（0929j 使用者裁定改回整格）。
    if sprite:shouldHaveCollision() then return COST_HARD end -- IsoSprite.java:2083-2093

    -- 車輛的靜態碰撞形狀由 IsoChunk.calcPhysics 決定（IsoChunk.java:1984-2126），不只看碰撞旗標：
    -- 室外路燈 lighting_outdoor_* 在地面層一律是一根柱（:1995-2014）——原版 81 個路燈 sprite 有 76
    -- 個不帶任何碰撞旗標，Sensor 整排看不到。0928d E2E rc3 0027：路燈立在轉角，車以 17 km/h 撞上、
    -- 三次倒車都撞回同一根。帶 PhysicsShape 的路燈照 PhysicsShape 走（:2094-2111）。
    if find(name, "lighting_outdoor_", 1, true) and not props:has("PhysicsShape")
            and not (props:has("MoveType") and props:get("MoveType") == "WallObject") then
        return COST_TREE
    end

    if props:has(F_doorN) then return COST_DOOR end
    if props:has(F_doorW) then return COST_DOOR end
    -- 原版通常會把 StopCar/Hoppable 合成 collision；顯式 guard 保護未合成或 MOD tile，
    -- 也避免緊接著的 isMoveAbleObject 分支把真正會停車的物件降成 SOFT。
    if props:has("StopCar") then return COST_HARD end
    -- PhysicsShape 屬性直接給碰撞形狀（原版 50 個 sprite 都是 Tree；其中 3 個掛在桿上的招牌／
    -- 運動設施沒有 StopCar 也沒有碰撞旗標）
    if props:has("PhysicsShape") then
        local shape = props:get("PhysicsShape")
        if shape == "Tree" then return COST_TREE end
        if shape ~= "Floor" then return COST_HARD end
    end
    -- 樹叢（見 COST_BUSH）：同 IsoObject.isBush 的判定（tileset f_bushes_1＝sprite 名 f_bushes_1_N）
    if find(name, "f_bushes_1_", 1, true) == 1 or props:has("Bush") then return COST_BUSH end
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

-- 關著的門／柵門＝車輛碰撞牆（IsoChunk.calcPhysics:2068-2088：格級屬性 DoorWallW＋doorW 或 DoorWallN＋doorN，
-- 且沒有 open → WallW／WallN 物理形狀）。開關會換 sprite（IsoDoor／IsoThumpable 在 closedSprite／openSprite
-- 間切換，IsoDoor.java:1604-1607），但門框／門洞 sprite 本身也帶 doorN／doorW，所以只看 sprite 會把關著的門
-- 當開口——0928m E2E rc13 0190：車頂著關著的鐵絲網柵門 0 km/h、每輪掃描淨空、倒車 100 次到逾時。
-- 門類 sprite 快取成 COST_DOOR，碰到才讀一次格級屬性；整格保守擋住（同牆 COST_HARD）。
local function closedDoor(square)
    local sp = square:getProperties()                  -- 格級聚合屬性（IsoGridSquare.getProperties）
    if sp == nil or sp:has(F_open) then return false end
    return (sp:has(F_doorW) and sp:has(F_doorWallW)) or (sp:has(F_doorN) and sp:has(F_doorWallN))
end

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

-- Knox Pass 大門（1005c；介面契約 KnoxPassAPI.willOpenFor(vehicle, obj)，Minidoracat Knox Pass VERSION ≥ 2）：
-- 關著、但 Knox Pass 預告會替這台車打開的門。預告不是保證（伺服器載入那一帶才開得了，實測開門距離 53–61 格），
-- 所以中央帶（同未載入的定義）的門格不當硬物，而是把本輪可視前緣截在門前一步——門一直不開時，可視兩帳
-- （巡航帳＋中線減速輔助、硬煞帳＋一秒鎖輪）照舊保證車心停在前緣 halfL+2 之前；門在遠處就開了＝不減速、
-- 不判堵、不繞行。車心到門格的世界距離 ≤ state.gateNearM（Driver 每輪寫：判堵停止線＋halfL＋車速×
-- TUNE.GATE_NEAR_LEAD_S，見 Drive.updatePerception）時同一格另當硬物＝退回關門處理（blocked 停等、重試、交還）；
-- 退回一次就記下門的位置（gateLatchX/Y，session 期間不清、reset 也不清），GATE_LATCH_R 內的門格之後一律硬物——
-- 倒車脫困退到 gateNearM 外也不會變回「遠處」再開回來（沒有出口的來回）。帶外的門格照關門處理。
-- Knox Pass 不在、API 出錯或回 false：與舊制完全相同（整格硬物、不截前緣）。
local GATE_LATCH_R2 = 8 * 8 -- 退回門格的同門半徑平方（柵門最寬約 6 格）

-- 這格（關著的門）有沒有一片是 Knox Pass 會替這台車開的；只在 closedDoor 為真時呼叫，一格一次。
-- 契約：偵測 type 檢查、呼叫包 pcall、出錯或非 true 一律 false。API 每次呼叫會配置一條短字串與一張小表（契約載明），
-- 只發生在關門格。第二回傳＝API 說「這扇裝了讀頭的門不會替這台車開」的原因代碼（VERSION ≥ 3 的 `false, why`；
-- 常數字串、不配置；第一片給的為準），只供 gateNoCell 記錄提示用，不改這格的處理。
local function gateWillOpen(state, vehicle, objs, nObj)
    local api = KnoxPassAPI
    if type(api) ~= "table" or type(api.willOpenFor) ~= "function" then return false end
    local no = nil
    for i = 1, nObj do
        local obj = objs:get(i - 1)
        local name = obj:getSpriteName()
        if name ~= nil and spriteCostOf(state, obj, name) == COST_DOOR then
            local ok, yes, why = pcall(api.willOpenFor, vehicle, obj)
            if ok and yes == true then return true end
            if ok and no == nil and type(why) == "string" then no = why end
        end
    end
    return false, no
end

-- 不會替這台車開的 Knox Pass 門格（1005d；gateWillOpen 帶 why、中央帶內）：這格照舊整格硬物（關門處理不變），
-- 只記本輪最近一格的弧長／世界格心／原因，給 Driver 提示玩家（Drive.gateNote phase no）。
local function gateNoCell(state, wx, wy, why)
    if state.wGateNoS == nil or state.curS < state.wGateNoS then
        state.wGateNoS, state.wGateNoX, state.wGateNoY, state.wGateNoWhy = state.curS, wx + 0.5, wy + 0.5, why
    end
end

-- 會開的門格（scanCell 冷分支）：截可視前緣、記本輪最近的門；回 true＝這格同時當硬物（帶外、近、已退回）。
-- wGateHard：false＝遠處（當可視前緣）、"near"＝車已接近、"latch"＝這扇門先前退回過（每種失敗各自的名字）。
local function gateCell(state, vehicle, wx, wy, inBand)
    if not inBand then return true end
    local gx, gy = wx + 0.5, wy + 0.5
    local why = false
    local lx, ly = state.gateLatchX, state.gateLatchY
    if lx ~= nil and (gx - lx) * (gx - lx) + (gy - ly) * (gy - ly) <= GATE_LATCH_R2 then
        why = "latch"
    else
        local near = state.gateNearM
        local dx, dy = gx - vehicle:getX(), gy - vehicle:getY()
        if type(near) ~= "number" or near ~= near or dx * dx + dy * dy <= near * near then
            why = "near"
            state.gateLatchX, state.gateLatchY = gx, gy
        end
    end
    -- 前緣截在門格前一步：取樣點在門格內，門的碰撞牆在格緣，最多比取樣點近一步
    local cut = state.curS - SCAN_STEP
    if cut < state.endS then state.endS = cut end
    if state.wGateS == nil or state.curS < state.wGateS then
        state.wGateS, state.wGateX, state.wGateY, state.wGateHard = state.curS, gx, gy, why
    end
    return why ~= false
end

-- 旗標 wHardOverflow 讓本輪快照可被判定不完整。Driver 另在快照尾端附加
-- 最多 4 個虛擬 ban，不經 pushHard，也不占這個 sensor 上限。
-- b（選填）＝整格方塊的半邊長（世界軸對齊；0／nil＝圓）：掃掠與接觸以方塊算距離，規劃仍用 r。
-- wHardLc／wHardW：形狀位置在本步局部框的橫向偏移與掃掠模型橫向半寬（擋線判定與世界掃掠同一份幾何，見檔頭）。
local function pushHard(state, s, l, l4, wx, wy, r, b)
    local n = state.wHardN
    if n >= HARD_MAX then state.wHardOverflow = true return end
    n = n + 1
    state.wHardN = n
    state.wHardS[n] = s
    state.wHardL[n] = l
    state.wHardX[n] = wx
    state.wHardY[n] = wy
    state.wHardR[n] = r
    state.wHardB[n] = b or 0
    local nx, ny = state.nx, state.ny
    state.wHardLc[n] = (wx - state.cx) * nx + (wy - state.cy) * ny
    if b and b > 0 then
        state.wHardW[n] = b * ((nx < 0 and -nx or nx) + (ny < 0 and -ny or ny))
    else
        state.wHardW[n] = r
    end
    state.wSumS = state.wSumS + (s - s % 1)
    state.wSumL = state.wSumL + l4
end

-- 格邊薄牆的一顆覆蓋圓：(s,l) 以目前掃描步的局部框把世界點線性化（同 pushVehicleOutline）。薄牆在格緣，
-- 取樣點最遠會離它 1m，不能沿用取樣點。
local function pushEdge(state, px, py)
    local dx, dy = px - state.cx, py - state.cy
    local nx, ny = state.nx, state.ny
    local l = dx * nx + dy * ny
    local l4 = l * 4
    pushHard(state, state.curS + dx * ny - dy * nx, l, l4 - l4 % 1, px, py, WALL_R)
end

-- 依 scanCell 的形狀碼推點（常數註解見 OBS_HALF_R／TRUNK_*／WALL_*）。世界座標＝引擎形狀的位置，
-- 掃掠複驗用它。方塊與樹幹的 (s,l) 刻意記命中的取樣點（與格心差到 ±0.5m）：縫隙搜尋用它，
-- 世界掃掠與擋線判定用形狀位置（hardX/Y、hardLc／hardW，1005）。0929f 試過連縫隙搜尋一起改成格心，同一組
-- E2E 路線的繞行承諾淨距中位數 0.95→0.58、繞行中接觸 4/305→3/39：取樣點誤差只會讓縫隙高估，或讓掃掠打回
-- 改試下一條 lane，等於一份隱含的橫向餘裕，蓋住了彎道追線落後。縫隙搜尋要改成格心，得同時補一份明確的
-- 追線餘裕並重驗。
local function pushShape(state, l, wx, wy, shape)
    local l4 = l * 4
    l4 = l4 - l4 % 1
    if shape == SHAPE_BOX then
        pushHard(state, state.curS, l, l4, wx + 0.5, wy + 0.5, OBS_HALF_R, BOX_HALF)
        return
    end
    if shape % 4 >= SHAPE_WALL_N then
        pushEdge(state, wx + 0.25, wy + 0.05)
        pushEdge(state, wx + 0.75, wy + 0.05)
    end
    if shape % 8 >= SHAPE_WALL_W then
        pushEdge(state, wx + 0.05, wy + 0.25)
        pushEdge(state, wx + 0.05, wy + 0.75)
    end
    if shape % 16 >= SHAPE_TRUNK then
        pushHard(state, state.curS, l, l4, wx + TRUNK_OFF, wy + TRUNK_OFF, TRUNK_R)
    end
    if shape % 32 >= SHAPE_THIN then pushHard(state, state.curS, l, l4, wx + 0.5, wy + 0.5, 0) end
    if shape >= SHAPE_BUSH then pushHard(state, state.curS, l, l4, wx + 0.5, wy + 0.5, BUSH_R) end
end

local function dist(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return sqrt(dx * dx + dy * dy)
end

-- 車輛精確輪廓（常數註解見 VEH_OUTLINE_*）。回 true＝已把該車輪廓推進本輪點雲；
-- false＝任何 getter 失敗（呼叫端退回格級佔位）。(s,l) 以**目前掃描步的局部框**
-- 線性化（state.cx/cy 為路線點、nx/ny 法向、前向＝(ny,-nx)）：輪廓點離命中格
-- ≤ 5m，直路精確、彎道有曲率誤差——只影響 plan 的提案品質；安全判定
-- （sweep／footprint／blockedNear）全用世界座標 wHardX/Y，不受影響。
-- 零配置：一顆池向量四角各取一次，成對歸還（BaseVehicle.java:507-521）。
local function pushVehicleOutline(state, cv)
    -- 整台輪廓要嘛全進要嘛不進：緩衝剩餘不夠就退回格級（近車精確、遠車粗略、
    -- 再遠才被 HARD_MAX 丟——掃描由近而遠，這個退化順序是對的）。
    if HARD_MAX - state.wHardN < VEH_OUTLINE_MAX then return false end
    -- script／extents／COM 任一 nil 在 pcall 內索引即 error → 同樣退回格級
    local okV, halfW, halfL, comX, comZ = pcall(function()
        local script = cv:getScript()
        local ext, com = script:getExtents(), script:getCenterOfMassOffset()
        return ext:x() * 0.5, ext:z() * 0.5, com:x(), com:z()
    end)
    if not okV or type(halfW) ~= "number" or halfW * 0 ~= 0 or halfW <= 0.3 or halfW > 3
            or type(halfL) ~= "number" or halfL * 0 ~= 0 or halfL <= 0.5 or halfL > 8
            or type(comX) ~= "number" or comX * 0 ~= 0
            or type(comZ) ~= "number" or comZ * 0 ~= 0 then
        return false
    end
    if type(BaseVehicle) ~= "table" or type(BaseVehicle.allocVector3f) ~= "function" then
        return false
    end
    local out = BaseVehicle.allocVector3f()
    if out == nil then return false end
    -- 四角（VehiclePoly.java:69-76 同序：-W+L、+W+L、+W-L、-W-L；y 取 0＝俯視）
    local ok, x1, y1, x2, y2, x3, y3, x4, y4 = pcall(function()
        cv:getWorldPos(comX - halfW, 0, comZ + halfL, out)
        local ax, ay = out:x(), out:y()
        cv:getWorldPos(comX + halfW, 0, comZ + halfL, out)
        local bx, by = out:x(), out:y()
        cv:getWorldPos(comX + halfW, 0, comZ - halfL, out)
        local cx, cy = out:x(), out:y()
        cv:getWorldPos(comX - halfW, 0, comZ - halfL, out)
        return ax, ay, bx, by, cx, cy, out:x(), out:y()
    end)
    BaseVehicle.releaseVector3f(out)
    if not ok then return false end
    if type(x1) ~= "number" or x1 * 0 ~= 0 or type(y1) ~= "number" or y1 * 0 ~= 0
            or type(x2) ~= "number" or x2 * 0 ~= 0 or type(y2) ~= "number" or y2 * 0 ~= 0
            or type(x3) ~= "number" or x3 * 0 ~= 0 or type(y3) ~= "number" or y3 * 0 ~= 0
            or type(x4) ~= "number" or x4 * 0 ~= 0 or type(y4) ~= "number" or y4 * 0 ~= 0 then
        return false
    end
    -- 局部框：s＝curS＋前向分量、l＝法向分量（相對路線點）
    local cx0, cy0, nx, ny = state.cx, state.cy, state.nx, state.ny
    local fx, fy = ny, -nx
    local curS = state.curS
    -- 步距：周長／(MAX−1) 與 VEH_OUTLINE_STEP 取大者——長車放大步距而不是截斷
    local e1, e2, e3, e4 = dist(x1, y1, x2, y2), dist(x2, y2, x3, y3),
        dist(x3, y3, x4, y4), dist(x4, y4, x1, y1)
    local perim = e1 + e2 + e3 + e4
    local step = VEH_OUTLINE_STEP
    if perim / step > VEH_OUTLINE_MAX - 1 then step = perim / (VEH_OUTLINE_MAX - 1) end
    local pushed = 0
    local function emit(px, py)
        pushed = pushed + 1
        local dx, dy = px - cx0, py - cy0
        local s = curS + dx * fx + dy * fy
        local l = dx * nx + dy * ny
        local l4 = l * 4
        l4 = l4 - l4 % 1
        pushHard(state, s, l, l4, px, py, VEH_OUTLINE_R)
    end
    local function edge(ax, ay, bx, by, len)
        local n = len / step
        n = n - n % 1
        if n < 1 then n = 1 end
        local dx, dy = bx - ax, by - ay
        for k = 0, n - 1 do
            local t = k / n
            emit(ax + dx * t, ay + dy * t)
        end
    end
    edge(x1, y1, x2, y2, e1)
    edge(x2, y2, x3, y3, e2)
    edge(x3, y3, x4, y4, e3)
    edge(x4, y4, x1, y1, e4)
    emit((x1 + x3) * 0.5, (y1 + y3) * 0.5) -- 中心保底
    return pushed > 0
end

-- 行進中車輛（會車／跟車）：每台每輪一筆，記車身 OBB 在目前掃描步局部框的 (s,l) 區間與
-- 沿路線速度。四角同 pushVehicleOutline（getWorldPos，VehiclePoly.java:52-88）；取不到幾何
-- 退回「車心 ± 一般轎車半寬 0.9／半長 2.3、與路線同向」的保守框。vs/vl＝nil＝首輪沒位移可算。
local TRF_MAX = 8
local TRF_FALLBACK_HALF_W, TRF_FALLBACK_HALF_L = 0.9, 2.3
local VEL_KNOWN2 = 1 -- 線速度平方門檻（1 m/s）：低於它當「還沒同步／停著」，不採用
-- 速度上限平方（70 m/s＝252 km/h）：遠端車剛同步那一幀線速度／位移偶爾是跳位（1001f：E2E 讀到 832 km/h），
-- 超過就當速度未知（首輪照樣進 trf、不當停著的車）
local VEL_MAX2 = 4900
local DRIVEN_UNSYNC_MS = 1500 -- 有人駕駛的車首見後這段時間內讀到 0 速＝遠端插值還沒就緒，不當停著的車

-- 有人駕駛（或被有人駕駛的車拖著）：駕駛座是角色＝不是路邊停的車
local function drivenVehicle(cv)
    local ok, d = pcall(cv.getDriver, cv)
    if ok and d ~= nil then return true end
    local okT, t = pcall(cv.getVehicleTowedBy, cv)
    if okT and t ~= nil then
        local okD, td = pcall(t.getDriver, t)
        return okD and td ~= nil
    end
    return false
end

-- 車輛的物理線速度（世界 x,z）；池向量同段歸還。取不到回 nil。
local function vehVelocity(cv)
    local cls = BaseVehicle
    if cls == nil or type(cls.allocVector3f) ~= "function" then return nil end
    local out = cls.allocVector3f()
    local x, z
    if pcall(cv.getLinearVelocity, cv, out) then x, z = out:x(), out:z() end
    cls.releaseVector3f(out)
    if type(x) ~= "number" or x * 0 ~= 0 or type(z) ~= "number" or z * 0 ~= 0 then return nil end
    return x, z
end
local function pushTraffic(state, cv, vs, vl)
    local n = state.wTrfN
    if n >= TRF_MAX then
        state.wTrfOverflow = true
        return
    end
    local cx0, cy0, nx, ny = state.cx, state.cy, state.nx, state.ny
    local curS = state.curS
    local s0, s1, l0, l1
    local okG, halfW, halfL, comX, comZ = pcall(function()
        local script = cv:getScript()
        local ext, com = script:getExtents(), script:getCenterOfMassOffset()
        return ext:x() * 0.5, ext:z() * 0.5, com:x(), com:z()
    end)
    local out = okG and type(halfW) == "number" and halfW * 0 == 0 and halfW > 0.3 and halfW <= 3
        and type(halfL) == "number" and halfL * 0 == 0 and halfL > 0.5 and halfL <= 8
        and type(comX) == "number" and comX * 0 == 0 and type(comZ) == "number" and comZ * 0 == 0
        and type(BaseVehicle) == "table" and type(BaseVehicle.allocVector3f) == "function"
        and BaseVehicle.allocVector3f() or nil
    if out ~= nil then
        local ok = pcall(function()
            for k = 1, 4 do
                local sx = (k == 1 or k == 4) and -1 or 1
                local sz = k <= 2 and 1 or -1
                cv:getWorldPos(comX + sx * halfW, 0, comZ + sz * halfL, out)
                local dx, dy = out:x() - cx0, out:y() - cy0
                local s = curS + dx * ny - dy * nx
                local l = dx * nx + dy * ny
                if s0 == nil or s < s0 then s0 = s end
                if s1 == nil or s > s1 then s1 = s end
                if l0 == nil or l < l0 then l0 = l end
                if l1 == nil or l > l1 then l1 = l end
            end
        end)
        BaseVehicle.releaseVector3f(out)
        if not ok or s0 == nil or s0 * 0 ~= 0 or s1 * 0 ~= 0 or l0 * 0 ~= 0 or l1 * 0 ~= 0 then
            s0 = nil
        end
    end
    if s0 == nil then
        local dx, dy = cv:getX() - cx0, cv:getY() - cy0
        local s = curS + dx * ny - dy * nx
        local l = dx * nx + dy * ny
        s0, s1 = s - TRF_FALLBACK_HALF_L, s + TRF_FALLBACK_HALF_L
        l0, l1 = l - TRF_FALLBACK_HALF_W, l + TRF_FALLBACK_HALF_W
    end
    n = n + 1
    state.wTrfN = n
    state.wTrfS0[n], state.wTrfS1[n] = s0, s1
    state.wTrfL0[n], state.wTrfL1[n] = l0, l1
    state.wTrfVs[n], state.wTrfVl[n] = vs or false, vl or false -- false＝未知（陣列不留洞）
    state.wTrfT[n] = state.nowMs
    state.wTrfId[n] = cv:getId()
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
        -- 中央帶未知就結束本輪；外側缺格只保留未知旗標，不截掉前方已載入的中央帶。
        if inBand and state.curS < state.endS then state.endS = state.curS end
        return false
    end

    -- 水面判定看**地板 sprite**而非格級聚合旗標：IsoGridSquare:has 讀的是該格全部
    -- sprite 旗標的聯集，跨河橋的橋面格若殘留水面 sprite 會被聯集誤判成硬障礙、
    -- 自駕永遠過不了橋。原版判「這格是水」的標準寫法就是地板檢查
    -- （ISWorldObjectContextMenu.lua:687-688 square:getFloor():hasProperty(water)）。
    -- 舊制 getFloor():hasProperty(water)（用例 ISWorldObjectContextMenu.lua:687-688）在橋面
    -- 三層疊格會拿到最底層的水面（見 waterUnderfoot）
    local hard, floorObj = waterUnderfoot(square)

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
    -- 形狀旗標（pushShape 依此推點）：box＝整格方塊（水面、HARD、關門、車輛格級佔位），其餘可以並存
    -- （同格的籬笆與樹）。box 蓋過一切，看到就停。
    local box, wallN, wallW, trunk, thin, bush = hard, false, false, false, false, false

    if not hard then
        local objs = square:getObjects()               -- IsoGridSquare.java:9635（回 PZArrayList）
        local nObj = objs:size()                       -- 迭代慣例 ISButtonPrompt.lua:535-536
        local gate, gateNo = nil, nil                  -- Knox Pass 會開的門／不會開的原因（gateWillOpen；gate nil＝這格還沒問）
        for i = 1, nObj do
            local obj = objs:get(i - 1)
            local name = obj:getSpriteName()           -- IsoObject.java:2235
            if name ~= nil then
                local cost = spriteCostOf(state, obj, name)
                if cost == COST_DOOR then
                    if not closedDoor(square) then
                        cost = COST_NONE
                    else
                        if gate == nil then gate, gateNo = gateWillOpen(state, vehicle, objs, nObj) end
                        if gate then cost = COST_NONE else cost = COST_HARD end
                    end
                end
                if cost == COST_HARD then
                    box = true
                    break
                elseif cost == COST_WALL_N then wallN = true
                elseif cost == COST_WALL_W then wallW = true
                elseif cost == COST_WALL_NW then wallN, wallW = true, true
                elseif cost == COST_TREE then trunk = true
                elseif cost == COST_HARD_THIN then thin = true
                elseif cost == COST_SOFT then soft = true
                elseif cost == COST_BUSH then bush = state.wideRound == true and state.bushPassable ~= true -- 見 COST_BUSH
                end
            end
        end
        if gate and not box then box = gateCell(state, vehicle, wx, wy, inBand)
        elseif gateNo ~= nil and inBand then gateNoCell(state, wx, wy, gateNo) end
        hard = box or wallN or wallW or trunk or thin or bush
    end

    -- 車輛：**格子幾何查詢**——引擎通用碰撞真相在 Lua 曝露面的最佳代理。
    -- getVehicleContainer() 掃 3×3 chunk 的 chunk.vehicles（物理位置驅動）
    -- × isIntersectingSquare（車體多邊形 vs 格子，IsoGridSquare.java:9872-
    -- 9893；用例 DebugContextMenu.lua:145）。舊三路全有盲區、2026-08-29 實
    -- 測全漏：cell:getVehicles() 集合波動（veh=2→1→0）、movingObjects 註冊
    -- 不可靠（連續 9 輪零偵測）、isStopped 假動（軍車判「行進中」不進 hard
    -- 一路推上去）。isStopped 降級為純語意開關：停＝硬障礙要繞；「動」＝跟
    -- 車（假動也吃 vehAheadS 分級煞停，兩態都安全、不再有「消失」態）。
    -- 車體蓋到的每一格都命中 → hard 點天然連片，不需要舊的單點錨膨脹。
    local cv = square:getVehicleContainer()
    if cv ~= nil and cv ~= vehicle and cv ~= state.selfTrailer then
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
            local vs, vl = nil, nil
            if pg == state.gen - 1 then
                local pdx = vwx - state.vehPosX[vid]
                local pdy = vwy - state.vehPosY[vid]
                still = pdx * pdx + pdy * pdy < 0.09
                -- 沿路線速度：兩輪首次命中之間的位移／時間，投影到本步前向 (ny,−nx)／右向 (nx,ny)
                local dt = (state.nowMs - (state.vehPosT[vid] or 0)) / 1000
                if dt > 0.05 and dt < 2 and pdx * pdx + pdy * pdy <= VEL_MAX2 * dt * dt then
                    vs = (pdx * state.ny - pdy * state.nx) / dt
                    vl = (pdx * state.nx + pdy * state.ny) / dt
                end
            else
                state.vehFirstMs[vid] = state.nowMs -- 上一輪沒看到＝新的一次目擊
            end
            -- 車自己的線速度（世界 x,z＝世界 x,y，同 Driver sampleVelocity）優先於跨輪位移：MP 遠端車
            -- 插值就緒後就是真值，首見那一輪就能分對向／同向，不必等第二輪；位移估速在遠端插值剛就緒時
            -- 還會把追趕的位移算進去（2026-10-01 E2E 會車量測：真值 11 m/s 估成 31、29 估成 68）。
            local wvx, wvz = vehVelocity(cv)
            local synced = wvx ~= nil and wvx * wvx + wvz * wvz >= VEL_KNOWN2
                and wvx * wvx + wvz * wvz <= VEL_MAX2
            if synced and not still then
                vs = wvx * state.ny - wvz * state.nx
                vl = wvx * state.nx + wvz * state.ny
            end
            -- 有人駕駛的車剛進同步範圍：遠端插值還沒就緒時速度讀 0、位置不動（VehicleManager.updateVehiclePos
            -- 取不到插值即 setSpeedKmHour(0)），看起來就是停在路中間的車——E2E 窄路對撞（兩台 100 km/h）
            -- 首見 69–75m 卻被當成停著的車去繞／掃掠打槍，要到 27–37m 才變成行進車。首見後 DRIVEN_UNSYNC_MS
            -- 內速度仍≈0 的有人駕駛車當「行進中、速度未知」（Driver 在行駛線上就先當停著的前車減速，不繞）。
            if not synced and (still or cv:isStopped()) and state.nowMs - (state.vehFirstMs[vid] or 0) < DRIVEN_UNSYNC_MS
                    and drivenVehicle(cv) then
                still, vs, vl = false, nil, nil
            elseif cv:isStopped() and not synced then
                -- 線速度已同步（≥1 m/s）的車不看 isStopped：遠端車的 getCurrentSpeedKmHour 只在駕駛是遠端玩家時
                -- 回真值，別人拖著的掛車沒有駕駛＝恆讀 0＝isStopped 恆真（BaseVehicle.java:4303-4316）。1001i E2E
                -- 雙拖車會車：首見那輪把對方掛車當停車、承諾繞行佔住車道，會車只能以 20 km/h 貼 0.25m 錯過。
                still = true -- 本輪判定一次、同輪後續格沿用（isStopped 跨幀翻面會讓 sig 跳動）
            end
            state.vehPosX[vid] = vwx
            state.vehPosY[vid] = vwy
            state.vehPosT[vid] = state.nowMs
            state.vehPosGen[vid] = state.gen
            state.vehStill[vid] = still
            if not still then pushTraffic(state, cv, vs, vl) end
        end
        if still then                                  -- 兩輪沒動或 isStopped（BaseVehicle.java:4303-4304）
            -- 停著的車＝實體障礙，要繞。幾何走精確輪廓（每台每輪一次）；輪廓取不到
            -- 才退回「這一格＝0.7 圓」的格級佔位。同一台車後續命中的格只計數。
            local og = state.vehOutlineGen[vid]
            if og == state.gen then
                -- 已推過輪廓：這格不再當障礙點
            elseif og == -state.gen then
                hard, box = true, true                 -- 本輪輪廓失敗：格級佔位
            elseif pushVehicleOutline(state, cv) then
                state.vehOutlineGen[vid] = state.gen
            else
                state.vehOutlineGen[vid] = -state.gen
                hard, box = true, true
            end
        elseif inBand then                             -- 行進中＝跟車情境（帶內才減速）
            state.wMovingVeh = true
            if state.wVehAheadS == nil or state.curS < state.wVehAheadS then
                state.wVehAheadS = state.curS
            end
        end
    end

    -- 動態物件（殭屍、動物、車外的其他玩家）：就算靜態已判 hard，數量仍是規劃端要看的獨立訊號。
    -- 帶內 ±ZOM_BAND_HALF 另記每個的 (s,l)（軟縫）：以實際座標對目前掃描步的
    -- 局部框線性化（cx/cy 路線點、nx/ny 法向、前向＝(ny,−nx)）。多數格 size()==0，
    -- 常態成本只多一次跨界；帶外格連 instanceof 都不叫。動物與玩家併入同一組點陣（共用 ZOM_MAX），
    -- 以 zomKind 標種類，由 Driver 依選項決定誰參與選縫、誰要停等。
    local zomBand = rel >= -ZOM_BAND_HALF and rel <= ZOM_BAND_HALF
    if zomBand then
        local movs = square:getMovingObjects()         -- IsoGridSquare.java:9605（回 ArrayList<IsoMovingObject>）
        local nMov = movs:size()                       -- 迭代慣例 DebugContextMenu.lua:535-537
        for i = 1, nMov do
            local mo = movs:get(i - 1)
            local kind = nil
            if instanceof(mo, "IsoZombie") then        -- 用例 DebugContextMenu.lua:537
                kind = "zombie"
            else
                kind = MDADSensor.softKindOf(mo)
            end
            if kind ~= nil then
                if inBand then
                    -- 各類最近一個的弧長（0907b 殭屍檔縱向 envelope：對它煞到檔位速，不是整帶平帽；動物／玩家停等同理）
                    if kind == "zombie" then
                        state.wZombieN = state.wZombieN + 1
                        if state.wZombieNearS == nil or state.curS < state.wZombieNearS then
                            state.wZombieNearS = state.curS
                        end
                    elseif kind == "animal" then
                        state.wAnimalN = state.wAnimalN + 1
                        if state.wAnimalNearS == nil or state.curS < state.wAnimalNearS then
                            state.wAnimalNearS = state.curS
                        end
                    elseif kind == "small" then
                        state.wSmallN = state.wSmallN + 1
                        if state.wSmallNearS == nil or state.curS < state.wSmallNearS then
                            state.wSmallNearS = state.curS
                        end
                    else
                        state.wPlayerN = state.wPlayerN + 1
                        if state.wPlayerNearS == nil or state.curS < state.wPlayerNearS then
                            state.wPlayerNearS = state.curS
                        end
                    end
                end
                if state.curS <= state.wSoftEndS then
                    local zn = state.wZomN
                    if zn >= ZOM_MAX then
                        state.wZomOverflow = true
                    else
                        local wx, wy = mo:getX(), mo:getY()
                        local dx, dy = wx - state.cx, wy - state.cy
                        local nx, ny = state.nx, state.ny
                        zn = zn + 1
                        state.wZomN = zn
                        state.wZomS[zn] = state.curS + (dx * ny - dy * nx)
                        state.wZomL[zn] = dx * nx + dy * ny
                        state.wZomIsCorpse[zn] = false -- 重用槽也要覆寫，不能留上一輪屍體標記。
                        state.wZomKind[zn] = kind
                        -- 橫向速度（右為正）：同一個物件（物件為鍵）兩輪位置差／時差；首次看到＝0。
                        -- 殭屍／行人會朝車走過來，Driver 用它預測交會時的位置（walk 情境 E2E：路邊殭屍走進車道）。
                        local vl = 0
                        local px = state.zomPrevX[mo]
                        if px ~= nil then
                            local dt = (state.nowMs - state.zomPrevT[mo]) / 1000
                            if dt > 0.05 and dt < 2 then
                                vl = ((wx - px) * nx + (wy - state.zomPrevY[mo]) * ny) / dt
                                if vl > ZOM_VL_MAX then vl = ZOM_VL_MAX elseif vl < -ZOM_VL_MAX then vl = -ZOM_VL_MAX end
                            end
                        end
                        state.wZomVl[zn] = vl
                        state.wZomCurX[mo], state.wZomCurY[mo], state.wZomCurT[mo] = wx, wy, state.nowMs
                    end
                end
                -- 停等目標另存（不受軟避讓點陣溢出影響）
                if kind ~= "zombie" and state.curS <= state.wSoftEndS then
                    local sn = state.wStopN
                    if sn >= MDADSensor.STOP_MAX then
                        if not state.wStopOverflow then
                            state.wStopOverflow, state.wStopOverS, state.wStopOverKind = true, state.curS, kind
                        elseif kind == "player" or (kind == "animal" and state.wStopOverKind == "small") then
                            state.wStopOverKind = kind -- 收不下的之中最重要的種類（玩家 > 大型 > 小型）
                        end
                    else
                        local wx, wy = mo:getX(), mo:getY()
                        local dx, dy = wx - state.cx, wy - state.cy
                        sn = sn + 1
                        state.wStopN = sn
                        state.wStopS[sn] = state.curS + (dx * state.ny - dy * state.nx)
                        state.wStopL[sn] = dx * state.nx + dy * state.ny
                        state.wStopKind[sn] = kind
                        state.wStopVl[sn] = MDADSensor.lateralVl(state, mo, wx, wy)
                        state.wZomCurX[mo], state.wZomCurY[mo], state.wZomCurT[mo] = wx, wy, state.nowMs
                    end
                end
            end
        end
    end

    -- 屍體與殭屍共用軟縫，不進 hard，也不污染 zombieN／殭屍推撞。
    -- BaseVehicle.testCollisionWithCorpse(:5220-5247) 以 getAngle() 的中心±0.65m 長軸測輪胎；
    -- 兩端的橫向佔位區間相接，不能只收中心點而漏掉橫躺的頭／腳。
    if zomBand then
        local smovs = square:getStaticMovingObjects()
        local nSmov = smovs:size()
        for i = 1, nSmov do
            local body = smovs:get(i - 1)
            if instanceof(body, "IsoDeadBody") then
                if inBand then
                    state.wCorpseN = state.wCorpseN + 1
                    if state.wCorpseNearS == nil or state.curS < state.wCorpseNearS then
                        state.wCorpseNearS = state.curS
                    end
                end
                if state.curS <= state.wSoftEndS then
                    local zn = state.wZomN
                    if zn + 2 > ZOM_MAX then
                        state.wZomOverflow = true
                    else
                        local dx, dy = body:getX() - state.cx, body:getY() - state.cy
                        local angle = body:getAngle()
                        local ax, ay = cos(angle) * 0.65, sin(angle) * 0.65
                        local nx, ny = state.nx, state.ny
                        local zs, zl = state.curS + dx * ny - dy * nx, dx * nx + dy * ny
                        local ds, dl = ax * ny - ay * nx, ax * nx + ay * ny
                        state.wZomS[zn + 1], state.wZomL[zn + 1] = zs - ds, zl - dl
                        state.wZomS[zn + 2], state.wZomL[zn + 2] = zs + ds, zl + dl
                        state.wZomIsCorpse[zn + 1], state.wZomIsCorpse[zn + 2] = true, true
                        state.wZomKind[zn + 1], state.wZomKind[zn + 2] = "corpse", "corpse"
                        state.wZomVl[zn + 1], state.wZomVl[zn + 2] = 0, 0
                        state.wZomN = zn + 2
                    end
                end
            end
        end
    end

    -- softN 以「格」為單位計數（與 hardN 同一個尺度），一格裡兩張沙發不算兩次。
    if soft and not hard and inBand then
        state.wSoftN = state.wSoftN + 1
        if state.wSoftNearS == nil or state.curS < state.wSoftNearS then
            state.wSoftNearS = state.curS
        end
    end
    if box then return hard, SHAPE_BOX end
    return hard, (wallN and SHAPE_WALL_N or 0) + (wallW and SHAPE_WALL_W or 0)
        + (trunk and SHAPE_TRUNK or 0) + (thin and SHAPE_THIN or 0) + (bush and SHAPE_BUSH or 0)
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
    state.wHardOverflow = false
    state.wZombieN = 0
    state.wZombieNearS = nil
    state.wZomN = 0
    state.wZomOverflow = false
    state.wCorpseN = 0
    state.wAnimalN, state.wSmallN, state.wPlayerN = 0, 0, 0
    state.wStopN, state.wStopOverflow, state.wStopOverS, state.wStopOverKind = 0, false, nil, nil
    state.wAnimalNearS, state.wSmallNearS, state.wPlayerNearS = nil, nil, nil
    state.wSoftN = 0
    state.wCorpseNearS, state.wSoftNearS = nil, nil
    state.wMovingVeh = false
    state.wVehAheadS = nil
    state.wVehN = 0
    state.wTrfN = 0
    state.wTrfOverflow = false
    state.wUnloaded = false
    state.wUnloadedS = nil
    state.wGateS, state.wGateX, state.wGateY, state.wGateHard = nil, nil, nil, false
    state.wGateNoS, state.wGateNoX, state.wGateNoY, state.wGateNoWhy = nil, nil, nil, nil
    state.wSumS = 0
    state.wSumL = 0
    state.wRoadN = 0
    state.wRoadSumL = 0
    state.wRoadLo = 999
    state.wRoadHi = -999

    local s0 = sNow + SCAN_NEAR
    if s0 < 0 then s0 = 0 end
    local softAhead = state.softAheadM
    if not MDADDynamics.finite(softAhead) then softAhead = MDADDynamics.SOFT_LOOKAHEAD_M end
    state.wSoftEndS = sNow + math.min(MDADDynamics.PERCEPTION_HARD_MAX_M,
        math.max(MDADDynamics.SOFT_LOOKAHEAD_M, softAhead))
    -- 寬帶於輪首鎖定（見 LAT_W、WIDE2）；兩種帶（與寬帶兩級）的可負擔前視不互相當回縮地板（換帶那輪重算）
    local wide = state.wideReq == true or state.wideReq == "stop"
    local long = state.wideReq == "stop"
    local lvl = wide and (state.wideLevelReq == 2 and 2 or 1) or 0
    if wide ~= state.wideRound or long ~= state.wideLong or lvl ~= state.wideRoundLevel then
        state.lastAffordableM = nil
    end
    state.wideRound, state.wideLong, state.wideRoundLevel = wide, long, lvl
    local latN = lvl == 2 and WIDE2.n or (wide and LAT_W_N or LAT_N)
    state.latArr, state.latArrN = lvl == 2 and WIDE2.lat or (wide and LAT_W or LAT), latN
    state.latFine = lvl == 2 and WIDE2.fine or (wide and LAT_W_FINE or LAT_FINE)
    state.latFineN = lvl == 2 and WIDE2.fineN or (wide and LAT_W_FINE_N or LAT_FINE_N)
    local req = state.aheadM
    if long then req = WIDE_STOP_AHEAD_M
    elseif wide and MDADDynamics.finite(req) and req > WIDE_AHEAD_M then req = WIDE_AHEAD_M end
    local ahead, affordable = MDADDynamics.perceptionEffective(
        req, state.frameEwmaMs, MDADDynamics.scanBudget(state.frameEwmaMs) / latN * (long and WIDE_STOP_ROUND_K or 1),
        SCAN_NEAR,
        state.lastAffordableM and state.lastAffordableM - AFFORD_SHRINK_MAX or nil)
    state.lastAffordableM = affordable
    state.requestedAheadM = state.aheadM
    state.affordableAheadM = ahead
    local s1 = sNow + ahead
    if s1 > len then s1 = len end
    state.wScanS = s0
    state.endS = s1
    -- 起點退一步、橫向游標設成越界，讓主迴圈的第一次「換步」正好落在 s0；
    -- 這同時處理了 s0 > s1（車已在路線末端）的情況：第一次換步就結束本輪。
    state.curS = s0 - SCAN_STEP
    state.curL = latN + 1
    state.latN, state.fineStep = latN, false

    state.segIdx = seekSeg(p, state.baseIdx, s0)
    state.baseIdx = state.segIdx
    -- 帶偏移於輪首鎖定（輪中 driver 更新 scanBias 不影響進行中的輪）。寬帶輪以 nav 線為心（1004c）：Corridor.plan
    -- 的候選以 nav 線對稱 ±(corridorHalf−needHalf) 規劃，帶心跟常駐偏置（最多 ±3）走時，遠側有一條從沒掃過的
    -- 帶被當成淨空（寬帶候選本來就到路外，偏置那 3m 正是路外最可能有東西的地方）。
    local sb = state.scanBias
    if type(sb) ~= "number" or sb ~= sb or wide then sb = 0 end
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
    local tr, tb = state.hardR, state.hardB
    local tc, tw = state.hardLc, state.hardW
    state.hardS = state.wHardS
    state.hardL = state.wHardL
    state.hardX = state.wHardX
    state.hardY = state.wHardY
    state.hardR, state.hardB = state.wHardR, state.wHardB
    state.hardLc, state.hardW = state.wHardLc, state.wHardW
    state.wHardS = ts
    state.wHardL = tl
    state.wHardX = txw
    state.wHardY = tyw
    state.wHardR, state.wHardB = tr, tb
    state.wHardLc, state.wHardW = tc, tw

    state.hardN = state.wHardN
    state.hardOverflow = state.wHardOverflow == true
    state.zombieN = state.wZombieN
    state.zombieNearS = state.wZombieNearS
    local tzs, tzl = state.zomS, state.zomL
    state.zomS, state.zomL = state.wZomS, state.wZomL
    state.wZomS, state.wZomL = tzs, tzl
    state.zomIsCorpse, state.wZomIsCorpse = state.wZomIsCorpse, state.zomIsCorpse
    state.zomKind, state.wZomKind = state.wZomKind, state.zomKind
    state.stopS, state.wStopS = state.wStopS, state.stopS
    state.stopL, state.wStopL = state.wStopL, state.stopL
    state.stopKind, state.wStopKind = state.wStopKind, state.stopKind
    state.stopVl, state.wStopVl = state.wStopVl, state.stopVl
    state.stopN, state.stopOverflow = state.wStopN, state.wStopOverflow
    state.stopOverS, state.stopOverKind = state.wStopOverS, state.wStopOverKind
    state.zomVl, state.wZomVl = state.wZomVl, state.zomVl
    -- 位置記錄：本輪看到的變成「上一輪」，舊的上一輪清空重用（只含本輪收錄的殭屍，≤ZOM_MAX 筆）
    local px, py, pt = state.zomPrevX, state.zomPrevY, state.zomPrevT
    state.zomPrevX, state.zomPrevY, state.zomPrevT = state.wZomCurX, state.wZomCurY, state.wZomCurT
    for k in pairs(px) do px[k], py[k], pt[k] = nil, nil, nil end
    state.wZomCurX, state.wZomCurY, state.wZomCurT = px, py, pt
    state.zomN = state.wZomN
    state.zomOverflow = state.wZomOverflow
    state.corpseN = state.wCorpseN
    state.animalN, state.smallN, state.playerN = state.wAnimalN, state.wSmallN, state.wPlayerN
    state.animalNearS, state.smallNearS, state.playerNearS = state.wAnimalNearS, state.wSmallNearS, state.wPlayerNearS
    state.softN = state.wSoftN
    state.corpseNearS, state.softNearS = state.wCorpseNearS, state.wSoftNearS
    state.softEndS = state.wSoftEndS
    state.movingVeh = state.wMovingVeh
    state.vehAheadS = state.wVehAheadS
    -- 行進中車輛：同 hard 的雙緩衝，整組交換參考
    state.trfS0, state.wTrfS0 = state.wTrfS0, state.trfS0
    state.trfS1, state.wTrfS1 = state.wTrfS1, state.trfS1
    state.trfL0, state.wTrfL0 = state.wTrfL0, state.trfL0
    state.trfL1, state.wTrfL1 = state.wTrfL1, state.trfL1
    state.trfVs, state.wTrfVs = state.wTrfVs, state.trfVs
    state.trfVl, state.wTrfVl = state.wTrfVl, state.trfVl
    state.trfT, state.wTrfT = state.wTrfT, state.trfT
    state.trfId, state.wTrfId = state.wTrfId, state.trfId
    state.trfN = state.wTrfN
    state.trfOverflow = state.wTrfOverflow == true
    state.vehN = state.wVehN
    state.unloaded = state.wUnloaded
    state.unloadedS = state.wUnloadedS
    state.gateS, state.gateX, state.gateY, state.gateHard = state.wGateS, state.wGateX, state.wGateY, state.wGateHard
    state.gateNoS, state.gateNoX, state.gateNoY, state.gateNoWhy = state.wGateNoS, state.wGateNoX, state.wGateNoY, state.wGateNoWhy
    state.rain = state.wRain
    state.actualSurfaceId = state.wActualSurfaceId
    state.roundStartedAt = state.wRoundStartedAt
    state.completedBandBias = state.bandBias
    -- 本快照實際掃到的橫向半寬（寬帶第二級的規劃半寬內縮，見 WIDE2）；wideDoneLevel＝0 一般帶、1／2 寬帶級
    state.corridorHalf = (state.wideRoundLevel == 2 and WIDE2.half)
        or (state.wideRound and CORRIDOR_HALF_W) or CORRIDOR_HALF
    state.wideDone = state.wideRound == true
    state.wideDoneLevel = state.wideRoundLevel or 0
    -- 第二級停點判堵只多出外圈：判堵候選鏈的 Corridor.plan 以 corridorInner（上一級的走廊半寬）排除內圈（ringFrom）。
    -- 承諾後的守護輪（wideReq＝true、非停點）不分圈：途中釋放後重規劃要看得到回路面的近縫。
    state.corridorInner = (state.wideRoundLevel == 2 and state.wideLong) and CORRIDOR_HALF_W or nil
    -- 簽章：障礙的「數量 + 縱向分布 + 橫向分布」三者任一有變就會變。純整數運算，
    -- 呼叫端只拿它做 ~= 比較（不是雜湊安全性），碰撞的代價只是少重規劃一次。
    -- 寬帶輪另加一項：一般帶已整條擋死、兩側空地沒有新硬點時點雲簽章不變，不加這項 replan 就不會用寬帶重規劃
    -- （0929p 審查：牆全在 ±6.5 內即重現，車一直 blocked 到脫困流程重設簽章）；升到第二級同理（項乘上級數）。
    state.sig = state.wHardN * 7919 + state.wSumS * 31 + state.wSumL
        + (state.wideRound and 104729 * state.wideDoneLevel or 0)
    -- 樣本不足、橫跨 >10m、或鋪面碰到掃描帶端點＝無路面／停車場／路口歧義。
    -- 端點截斷時觀測 span 只是寬度下界，不能拿「看見 10m」證明整體只有 10m。
    -- 歧義時 roadC 與 road band 一起撤銷，退回 nav 線，不硬掰。
    local roadSpan = state.wRoadHi - state.wRoadLo
    local latArr, latArrN = state.latArr or LAT, state.latArrN or LAT_N
    local roadEdgesVisible = state.wRoadLo > state.bandBias + latArr[1] + ROAD_EDGE_GAP
        and state.wRoadHi < state.bandBias + latArr[latArrN] - ROAD_EDGE_GAP
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
    state.effectiveAheadM = state.endS - state.wScanS + SCAN_NEAR
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
        latN = LAT_N, fineStep = false, -- 目前這一步的橫向取樣數／是否細取樣（非軸對齊步）
        -- 本輪的橫向取樣組（一般帶或寬帶，beginRound 鎖定）＋Driver 的寬帶要求與完成快照的帶寬
        latArr = LAT, latArrN = LAT_N, latFine = LAT_FINE, latFineN = LAT_FINE_N,
        wideReq = false, wideRound = false, wideLong = false, wideDone = false, corridorHalf = CORRIDOR_HALF,
        wideLevelReq = 1, wideRoundLevel = 0, wideDoneLevel = 0, -- 寬帶級：Driver 要求／本輪鎖定／完成快照（WIDE2）
        bushPassable = false, -- Driver 能抵消樹叢阻力（Drive.bushCancel）＝寬帶不避樹叢（見 COST_BUSH）
        segIdx = 1,
        baseIdx = 1,
        cx = 0, cy = 0,
        nx = 0, ny = 1,
        z = 0,
        wHardS = {}, wHardL = {}, wHardX = {}, wHardY = {}, wHardR = {}, wHardB = {}, wHardLc = {}, wHardW = {},
        wHardN = 0,
        wHardOverflow = false,
        wZombieN = 0,
        wZombieNearS = nil, -- 帶內最近殭屍弧長（本輪 working；nil＝無）
        wZomS = {}, wZomL = {}, wZomN = 0, wZomOverflow = false, -- 混合軟避讓點；殭屍一點／屍體兩點
        wZomIsCorpse = {},
        wZomKind = {}, -- 每槽種類（"zombie"／"corpse"／"animal"／"small"／"player"）
        wStopS = {}, wStopL = {}, wStopKind = {}, wStopVl = {}, wStopN = 0, -- 停等目標（動物／玩家）working，上限 STOP_MAX
        wStopOverflow = false, wStopOverS = nil, wStopOverKind = nil,
        wZomVl = {}, -- 殭屍橫向速度（右為正 m/s；屍體 0）
        wZomCurX = {}, wZomCurY = {}, wZomCurT = {}, -- 本輪殭屍位置（物件為鍵）
        zomPrevX = {}, zomPrevY = {}, zomPrevT = {}, -- 上一輪殭屍位置（算橫向速度）
        wCorpseN = 0,
        wAnimalN = 0, wSmallN = 0, wPlayerN = 0,
        wAnimalNearS = nil, wSmallNearS = nil, wPlayerNearS = nil,
        wSoftN = 0,
        wCorpseNearS = nil, wSoftNearS = nil, wSoftEndS = 0,
        wMovingVeh = false,
        wVehAheadS = nil,  -- 最近「行進中」前車弧長（本輪 working）
        wTrfN = 0, wTrfOverflow = false, -- 行進中車輛（working；每台一筆，見 pushTraffic）
        wTrfS0 = {}, wTrfS1 = {}, wTrfL0 = {}, wTrfL1 = {}, wTrfVs = {}, wTrfVl = {}, wTrfT = {}, wTrfId = {},
        nowMs = 0,          -- 本幀時戳（step 寫入；scanCell 算車速用）
        wUnloaded = false,
        -- Knox Pass 會開的門（gateCell）：本輪最近一格的弧長／世界格心／是否當硬物（false／"near"／"latch"）；
        -- gateNearM＝Driver 每輪寫的「接近」判距；gateLatchX/Y＝退回過的門（session 期間不清，reset 也不清）
        wGateS = nil, wGateX = nil, wGateY = nil, wGateHard = false,
        gateS = nil, gateX = nil, gateY = nil, gateHard = false,
        gateNearM = nil, gateLatchX = nil, gateLatchY = nil,
        -- Knox Pass 不會替這台車開的門（gateNoCell，1005d）：本輪最近一格的弧長／世界格心／API 原因代碼
        wGateNoS = nil, wGateNoX = nil, wGateNoY = nil, wGateNoWhy = nil,
        gateNoS = nil, gateNoX = nil, gateNoY = nil, gateNoWhy = nil,
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
        hardS = {}, hardL = {}, hardX = {}, hardY = {}, hardR = {}, hardB = {}, -- hardX/Y＝世界座標（掃掠複驗）；hardR／hardB＝逐點半徑／方塊半邊（見 pushShape）
        hardLc = {}, hardW = {}, -- 形狀位置的橫向偏移／掃掠模型橫向半寬（擋線判定，見檔頭）
        hardN = 0,
        hardOverflow = false,
        zombieN = 0,
        zombieNearS = nil,  -- 帶內最近殭屍弧長（殭屍檔縱向 envelope；nil＝無）
        zomS = {}, zomL = {}, zomN = 0, zomOverflow = false, -- 完成輪軟避讓點雲；歷史欄名沿用 zom
        zomIsCorpse = {},
        zomKind = {},
        stopS = {}, stopL = {}, stopKind = {}, stopVl = {}, stopN = 0, -- 停等目標完成輪快照（不受 zomOverflow 影響）
        stopOverflow = false, stopOverS = nil, stopOverKind = nil,
        zomVl = {},
        corpseN = 0,
        animalN = 0, smallN = 0, playerN = 0,
        animalNearS = nil, smallNearS = nil, playerNearS = nil, -- 各類帶內最近弧長（nil＝無）
        softN = 0,
        corpseNearS = nil, softNearS = nil, softEndS = 0, softAheadM = nil,
        movingVeh = false,
        vehAheadS = nil,    -- 最近「行進中」前車弧長（跟車分級煞停用；nil＝無）
        trfN = 0, trfOverflow = false, -- 行進中車輛完成輪快照（會車／跟車；見檔頭介面契約）
        trfS0 = {}, trfS1 = {}, trfL0 = {}, trfL1 = {}, trfVs = {}, trfVl = {}, trfT = {}, trfId = {},
        unloaded = false,
        sig = 0,
        frameMs = 0, frameEwmaMs = 0,
        requestedAheadM = SCAN_AHEAD, affordableAheadM = 0, effectiveAheadM = 0,
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
        vehPosT = {},       -- vehicleId → 最後一次首輪命中的時戳（車速＝兩輪位移／時差）
        vehFirstMs = {},    -- vehicleId → 這一次連續目擊的首見時戳（有人駕駛車的插值暖機窗）
        vehOutlineGen = {}, -- vehicleId → gen：本輪已推過該車輪廓（格級命中只計數不再推點）
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
    state.latN, state.fineStep = LAT_N, false
    state.latArr, state.latArrN, state.latFine, state.latFineN = LAT, LAT_N, LAT_FINE, LAT_FINE_N
    state.wideRound, state.wideLong, state.wideDone, state.corridorHalf = false, false, false, CORRIDOR_HALF
    state.wideRoundLevel, state.wideDoneLevel, state.corridorInner = 0, 0, nil
    state.segIdx = 1
    state.baseIdx = 1
    state.wHardN = 0
    state.wHardOverflow = false
    state.wZombieN = 0
    state.wZombieNearS = nil
    state.wZomN = 0
    state.wZomOverflow = false
    state.wCorpseN = 0
    state.wAnimalN, state.wSmallN, state.wPlayerN = 0, 0, 0
    state.wStopN, state.wStopOverflow, state.wStopOverS, state.wStopOverKind = 0, false, nil, nil
    state.wAnimalNearS, state.wSmallNearS, state.wPlayerNearS = nil, nil, nil
    state.wSoftN = 0
    state.wCorpseNearS, state.wSoftNearS, state.wSoftEndS = nil, nil, 0
    state.wMovingVeh = false
    state.wVehAheadS = nil
    state.wUnloaded = false
    state.wGateS, state.wGateX, state.wGateY, state.wGateHard = nil, nil, nil, false
    state.wGateNoS, state.wGateNoX, state.wGateNoY, state.wGateNoWhy = nil, nil, nil, nil
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
    state.wTrfN, state.wTrfOverflow = 0, false
    state.trfN, state.trfOverflow = 0, false
    for k in pairs(state.vehOutlineGen) do state.vehOutlineGen[k] = 0 end

    state.hardN = 0
    state.hardOverflow = false
    state.zombieN = 0
    state.zombieNearS = nil
    state.zomN = 0
    for k in pairs(state.zomPrevX) do state.zomPrevX[k], state.zomPrevY[k], state.zomPrevT[k] = nil, nil, nil end
    for k in pairs(state.wZomCurX) do state.wZomCurX[k], state.wZomCurY[k], state.wZomCurT[k] = nil, nil, nil end
    state.zomOverflow = false
    state.corpseN = 0
    state.animalN, state.smallN, state.playerN = 0, 0, 0
    state.stopN, state.stopOverflow, state.stopOverS, state.stopOverKind = 0, false, nil, nil
    state.animalNearS, state.smallNearS, state.playerNearS = nil, nil, nil
    state.softN = 0
    state.corpseNearS, state.softNearS, state.softEndS = nil, nil, 0
    state.movingVeh = false
    state.vehAheadS = nil
    state.unloaded = false
    state.gateS, state.gateX, state.gateY, state.gateHard = nil, nil, nil, false
    state.gateNoS, state.gateNoX, state.gateNoY, state.gateNoWhy = nil, nil, nil, nil
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
    state.affordableAheadM, state.effectiveAheadM = 0, 0
end

-- working buffer 推一個硬點（含簽章累加；l4＝l*4 的整數版；r＝該點半徑——
-- 樹幹 0、整格箱型物 OBS_HALF，Corridor/sweep 逐點膨脹用）。HARD_MAX 已抬到
-- 掃描帶數學上限之上（不可達）；萬一未來帶寬改動造成溢出，不再靜默——
-- 每幀呼叫。回 true ＝ 本輪剛完成（呼叫端此時拿結果去規劃）。
function MDADSensor.step(state, profile, sNow, vehicle, now, cell)
    if type(state) ~= "table" then return false end
    if type(profile) ~= "table" then return false end
    if vehicle == nil or cell == nil then return false end
    if type(sNow) ~= "number" or type(now) ~= "number" then return false end
    local frame = state.frameMs
    if type(frame) == "number" and frame * 0 == 0 and frame > 0 then
        if frame > 250 then frame = 250 end
        local avg = state.frameEwmaMs or 0
        if avg <= 0 then avg = frame else avg = avg + (frame - avg) * frame / (1000 + frame) end
        state.frameEwmaMs = avg
    end

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

    state.nowMs = now
    if not state.scanning then
        if now < state.nextMs then return false end   -- ① 節流的 O(1) 早退
        beginRound(state, profile, sNow, vehicle, now, len, cell)
    end

    local visited = state.visited
    local gen = state.gen
    local budget = MDADDynamics.scanBudget(state.frameEwmaMs)
    local latArr, latFine = state.latArr, state.latFine

    while budget > 0 do
        local li = state.curL
        if li > state.latN then
            -- 換到下一步：算一次中心點與法向（一次 sin + 一次 cos，攤在 10 格上）
            local s = state.curS + (state.fineStep and FINE_STEP or SCAN_STEP)
            if s > state.endS then
                finishRound(state, now)
                return true
            end
            state.curS = s
            centerAt(state, profile, s)
            local nx, ny = state.nx, state.ny
            local fine = (nx > ALIGN_EPS or nx < -ALIGN_EPS) and (ny > ALIGN_EPS or ny < -ALIGN_EPS)
            state.fineStep = fine
            state.latN = fine and state.latFineN or state.latArrN
            li = 1
        end

        -- 橫向取樣以**行駛線**為中心（LAT ± 帶偏移）：掃描帶若釘死在 nav 線上，
        -- 線偏得越多、帶能看到的路面越少 → 路面對中樣本殘缺 → 校正收斂不足，
        -- 行駛線永遠停在路緣（2026-08-28 視覺化實證：藍點列壓在路緣、路面帶
        -- 綠點只有半邊）。bandBias 於輪首鎖定（beginRound），l 仍是「相對
        -- nav 線」的座標——下游 hardL／roadC／縫隙規劃語意全部不變。
        local l = (state.fineStep and latFine[li] or latArr[li]) + state.bandBias
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
            local hard, shape = scanCell(state, vehicle, cell, wx, wy, l)
            if hard then pushShape(state, l, wx, wy, shape) end -- 幾何與 (s,l) 取法見 pushShape
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
-- 關著的門一律硬物，不問 Knox Pass（gateCell）：探測只看車身周圍幾公尺，遠在 gateNearM（≥ 停止線＋halfL）之內，
-- 走廊掃描在這個距離同樣已把會開的門當硬物——倒車、調頭、起步探測不能因為「門等一下會開」就判淨空。
local function probeSquareHard(state, square)
    if waterUnderfoot(square) then
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
            if cost == COST_HARD or cost == COST_WALL_N or cost == COST_WALL_W or cost == COST_WALL_NW
                    or (cost == COST_DOOR and closedDoor(square)) then return true, "hard" end
            if cost == COST_HARD_THIN or cost == COST_TREE then return true, "hardThin" end
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
    -- IsoGridSquare.java:9872-9893（內部即呼叫 isIntersectingSquare）。
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
                if cv ~= nil and cv ~= vehicle and cv ~= state.selfTrailer then
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
        if other ~= nil and other ~= vehicle and other ~= state.selfTrailer then
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
                if v ~= nil and v ~= vehicle and v ~= state.selfTrailer then
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
                    if instanceof(mv, "BaseVehicle") and mv ~= vehicle and mv ~= state.selfTrailer then return true end
                end
                -- 格級幾何查詢（同 scanCell 的理由）：全域列舉／movingObjects
                -- 都可能漏掉 streaming 波動車，貼著看不見的車原地旋轉＝掃到
                local cv = square:getVehicleContainer()
                if cv ~= nil and cv ~= vehicle and cv ~= state.selfTrailer then return true end
            end
        end
    end
    return false
end

-- 車周樹叢物件（Driver Drive.bushCancel 的候選；冷路徑，Driver 節流呼叫）：(cx,cy) 周圍 r 內每一格的物件，sprite 成本
-- 是 COST_BUSH 的逐一收進 outObj／outX／outY（格心＝引擎 getObjectX/Y，BaseVehicle.java:5502-5508；一格可有多叢，引擎
-- 逐物件施力），最多 maxN 個，回個數。d_generic_1／d_plants_1 tileset 引擎只播聲音、不施衝量（BaseVehicle.java:3078），
-- 不收。只讀格、只更新既有 sprite 快取，不碰掃描 working buffer；未載入格跳過（引擎同樣不會對它施力）。
function MDADSensor.bushNear(state, vehicle, cell, cx, cy, r, outObj, outX, outY, maxN)
    if type(state) ~= "table" or type(state.spriteCost) ~= "table" or not vehicle or not cell
            or not finite(cx) or not finite(cy) or not finite(r) then return 0 end
    if not flagsBound then bindFlags() end
    local z = vehicle:getZ()
    if not finite(z) then return 0 end
    z = z - z % 1
    local x0, x1, y0, y1 = cx - r, cx + r, cy - r, cy + r
    x0, x1, y0, y1 = x0 - x0 % 1, x1 - x1 % 1, y0 - y0 % 1, y1 - y1 % 1
    local n = 0
    for gx = x0, x1 do
        for gy = y0, y1 do
            local square = cell:getGridSquare(gx, gy, z)
            local objs = square and square:getObjects()
            local nObj = objs and objs:size() or 0
            for i = 1, nObj do
                local obj = objs:get(i - 1)
                local name = obj:getSpriteName()
                if name ~= nil and spriteCostOf(state, obj, name) == COST_BUSH
                        and find(name, "d_generic_1_", 1, true) ~= 1 and find(name, "d_plants_1_", 1, true) ~= 1 then
                    if n >= maxN then return n end
                    n = n + 1
                    outObj[n], outX[n], outY[n] = obj, gx + 0.5, gy + 0.5
                end
            end
        end
    end
    return n
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
