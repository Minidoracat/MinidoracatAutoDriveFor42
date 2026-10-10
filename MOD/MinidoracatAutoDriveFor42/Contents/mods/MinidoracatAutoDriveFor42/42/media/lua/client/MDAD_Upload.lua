-- MDAD_Upload.lua — 伺服器診斷上傳（2026-09-24 使用者裁定）。
--
-- 伺服器沙盒 DiagnosticsUpload 開啟、玩家沒在選項退出時，自駕期間在**記憶體**保留最近
-- 30 秒的診斷紀錄（與本機診斷同一份 JSONL 編碼，由 MDAD_Diagnostics 餵進來），只在出事
-- 時把前後片段、每趟一份摘要送到伺服器（server/MDAD_UploadServer.lua 收）。玩家硬碟零 I/O。
--
-- 片段自足（使用者要求「足夠判斷並修復」）：檔頭＋最近一次路線原始點列＋整趟非 replan
-- 事件＋事前 PRE_MS／事後到脫困結束（最長 POST_MAX_MS）的完整取樣。
--
-- 引擎限制（42.20.4）：
--   字串以有號 short 記長度（GameWindow.java:1266；ByteBufferReader.java:48-52），超過
--   32767 bytes 伺服器解析拋錯、整筆丟（GameServer.java:2256-2261）。Kahlua 的 # 算 UTF-16
--   字元，最壞 3 bytes／字元 → 每塊 ≤10000 字元。
--   ClientCommand 是 HIGH 優先級（PacketTypes.java:498），車輛物理同步是 MEDIUM
--   （VehiclePhysicsUnreliablePacket.java:7-10）：行駛中放慢節奏，停車／行程外才加快。
--   ClientCommand 每秒封包數全 MOD 共用，客戶端超量靜默丟包（PacketTypes.java:704-706、
--   ServerOptions.java:209 預設 300）：一次最多一包、間隔 ≥500ms。

if MDADUpload then return end

local U = {}
MDADUpload = U

local PRE_MS = 30000
local POST_MIN_MS = 5000
local QUIET_MS = 5000
local POST_MAX_MS = 60000
local STALL_MS = 3000
local ANOMALY_TAKEOVER_MS = 10000
local RING_N = 480
local EVLOG_N = 400
local CLIP_MAX = 900000
-- 樣本預算（CLIP_MAX）用完＝full 之後，窗內事件另給這麼多字元、照收到窗結束（樣本不再收）：正式服 rev≥1005 片段
-- 約 600 段有 62 段 full、觸發後中位只剩 3.9 秒，unstick 的 success／timeout 都被截掉。
local CLIP_EV_MAX = 100000
-- 片段整段（首行＋header＋route 點列＋窗前事件＋窗內樣本與事件＝送出的全文）上限；full 後事件實際只拿到
-- min(CLIP_EV_MAX, 這個上限扣掉其餘的剩額)。伺服器 MDAD_UploadServer CLIP_MAX 1000000 檢查第一塊宣告的整段長度，
-- 正式服 DoLuaChecksum=false：發版到伺服器重啟之間新客戶端會連上舊伺服器（同樣 1000000），超過就整段拒收、
-- 最重要的事故片段消失。新舊伺服器同一個上限，不要加大伺服器那邊。
local CLIP_TOTAL_MAX = 995000
-- 觸發後過了這麼久，上傳片段的樣本降到 5Hz（相鄰收進片段的樣本間隔 <THIN_GAP_MS 就跳過已編好的列；ring 與本機紀錄不動）。
local THIN_AFTER_MS = 5000
local THIN_GAP_MS = 200
-- 事前窗裡早於觸發這麼久的樣本同樣降到 5Hz（觸發前最後這段保留原頻率）：10Hz 段的事前 30 秒本來吃掉樣本預算約八成七，
-- full 片段觸發後只剩約 3 秒樣本（rc70–73 重播：只降觸發後中位 0.9 s，加這條 10 s）。
local PRE_THIN_BEFORE_MS = 10000
local CHUNK = 10000
local SUM_MAX = CHUNK
local CLIPS_PER_DRIVE = 6
local CLIPS_PER_HOUR = 8
local HOUR_MS = 3600000
local KIND_COOLDOWN_MS = 60000
local OUTBOX_MAX = 4000000
local SEND_IDLE_MS = 500
local SEND_DRIVING_MS = 2000
local DRIVING_KMH = 10
local INC_MAX = 8
-- 撞擊：相鄰兩筆取樣間減速度超過一秒鎖輪（×13 煞車力，實測 ≤12 m/s²）能給的，就是撞上東西
-- （0.16.0 兩車對撞 61→1.6 km/h／0.21s＝79 m/s²、69→49／0.21s＝26 m/s²，片段只標成「煞車」）。
local IMPACT_DECEL = 18
-- 鎖輪中（本筆或前一筆 fbl>0）的門檻：一秒鎖輪之外，本 MOD 的中線減速輔助（Drive.visAssistForce，上限
-- DODGE_ASSIST_MAX 7 m/s²）在閂鎖期間照施，合計量到 23 m/s²（1002y 正式服 clip-11：blocked 鎖輪
-- ＋繞行輔助，停在障礙前 1.7m、沒碰到卻記成撞擊）。兩車對撞的 26／79 m/s² 仍在門檻之上。
local IMPACT_DECEL_LOCKED = 25
local IMPACT_MIN_KMH = 5
local IMPACT_REARM_MS = 2000
-- 相鄰兩筆的原始間隔超過這麼久＝中間沒取樣（讓位接手、遊戲暫停）：速度差不是同一段減速，不比。
-- （1002y clip-29：讓位 5.7 秒、恢復時 0 km/h，dt 被夾成 1 秒算出 24.9 m/s²＝假撞擊）
local IMPACT_GAP_MAX_MS = 1000
-- 伺服器拉回（瞬移）：相鄰兩筆位移超過 max(前後速度)×原始間隔×TELEPORT_K＋TELEPORT_PAD_M＝座標被伺服器改寫，不是
-- 開過去的；同一筆的掉速也是拉回造成的，不算撞擊（1005j 正式服 41 km/h 時一筆跳 171m、另一次 49m，兩次都被記成
-- impact、帶內殭屍讓 impZ 也記 1；1005h 另一段跳 142m）。PAD 吃 MP 位置內插的抖動，K 吃速度取樣與實際的差。
local TELEPORT_K = 1.5
local TELEPORT_PAD_M = 5
-- impZ（帶內有殭屍的撞擊）：撞擊那筆或前一筆的帶內最近殭屍（Sensor zombieNearS，完成輪快照、最多舊一輪，
-- 所以兩筆取近者）離車心 ≤ 半車長＋IMPACT_ZOMBIE_M 才算。zombieN 是整條感知帶的數量（1002y
-- clip-01：最近一隻在 25m 外也記成 impZ）。車心弧長取樣本字串的 rs（Driver 的 lastSNow）。
local IMPACT_ZOMBIE_M = 4
local IMPACT_HALF_L = 2.5 -- profile 沒有 halfL 時的半車長：取偏大（窗寬，寧可多記不漏記）
-- 撞擊分類（1008，U.impactClass；Diagnostics 在上升緣算一次，整段連續撞擊沿用）。frozen 與 tow-sync 不算 impact、
-- 不觸發片段、不進 impZ，摘要另計 frz／tws；本機與上傳的 impact 事件帶 cls。
--   frozen＝MP 伺服器拉回前一筆的凍結樣本：車速與 vl／vt 三者精確為 0（真撞 200ms 內不會剛好三個 0；正式服 0.23.0
--     片段兩例：71→0、64.8→0，下一筆座標跳 56／6 m）。
--   tow-sync＝拖車時掛車被同步拉回、經約束拽住牽引車：沒煞車（ib、fbl）、沒 footprint、nb 方框內沒東西，且本筆往前
--     TOW_SYNC_MS 內掛車 tup 從高點掉了 ≥TOW_SYNC_TUP（正式服 0.23.0 SemiTruckLite＋SemiTrailerContainer 6 例掉
--     0.0033–0.0058；同批其他拖車真撞與接觸 ≤0.0004，其中 SemiTruck＋Cartrailer 的真撞撞前 tup 平穩、撞後才傾斜）。
local TOW_SYNC_MS = 450
local TOW_SYNC_TUP = 0.002
-- 偏離常駐線（摘要 offMs／offN／offMax、片段 offset；排除清單見 offsetKpi）：沒人持有行駛線時 |ld|（車身 − 期望線＝
-- 夾過路寬的常駐線）超過 OFF_LAT_M；鏈式停留（lc）改量車身 − 夾過的常駐線 rsl——鏈著時期望線就是停留 lane，
-- 「繞完一直走路邊」正是這段（玩家回報，事故之外完全沒被錄到）。連續 ≥OFF_MIN_MS 才算一段，單段達 OFF_CLIP_MS
-- 觸發 offset 片段（每段一次）。
local OFF_LAT_M = 1
local OFF_MIN_MS = 2000
local OFF_CLIP_MS = 8000

U.PRE_MS, U.CHUNK, U.CLIP_MAX, U.TOW_SYNC_MS = PRE_MS, CHUNK, CLIP_MAX, TOW_SYNC_MS
U.CLIP_EV_MAX, U.THIN_AFTER_MS, U.THIN_GAP_MS = CLIP_EV_MAX, THIN_AFTER_MS, THIN_GAP_MS
U.CLIP_TOTAL_MAX = CLIP_TOTAL_MAX
U.OFF_MIN_MS, U.OFF_CLIP_MS, U.PRE_THIN_BEFORE_MS = OFF_MIN_MS, OFF_CLIP_MS, PRE_THIN_BEFORE_MS

-- 片段優先級：數字越小越重要（伺服器每人 32 段滿了先覆蓋數字大的）。
-- detour（1004b）：自動／HUD 改道請求（不論成敗）——事前 PRE_MS 看得到判堵、寬帶判定與倒車，判斷是否太早改道。
-- offset：單段偏離常駐線達 OFF_CLIP_MS（不是事故，最先被覆蓋）。
local PRI = { stuck = 1, fault = 1, contact = 2, impact = 2, trailer = 2, takeover = 3, unstick = 3, route = 3,
    detour = 3, brake = 4, offset = 4 }
U.PRI = PRI
local STOP_KIND = {
    UI_MinidoracatAutoDrive_StopStuck = "stuck",
    UI_MinidoracatAutoDrive_UnsupportedVehicle = "fault",
    UI_MinidoracatAutoDrive_LostRoute = "route",
    UI_MinidoracatAutoDrive_RouteTooFar = "route",
    -- 行程模式的交還（1006）：行程中目標消失（單站同義是 LostRoute）、行程 API 失敗——同歸 route，伺服器 KINDS 不動
    UI_MinidoracatAutoDrive_TripLost = "route",
    -- 拖掛終局（2026-09-27：43 趟拖掛停止沒有一段片段，TrailerLost 無從定罪）
    UI_MinidoracatAutoDrive_TrailerLost = "trailer",
    UI_MinidoracatAutoDrive_TrailerRotate = "trailer",
    UI_MinidoracatAutoDrive_TrailerCorner = "trailer",
    -- 前方區域一直沒載入（0928a；Driver TUNE.AREA_WAIT_MAX_MS）
    UI_MinidoracatAutoDrive_AreaLoadStop = "stuck",
    -- 其他玩家擋路、停等預算用完（1005 soft；Driver Drive.KEY_PLAYER_STOP）
    UI_MinidoracatAutoDrive_PlayerBlockStop = "stuck",
    -- 動物一直擋著、爬行到上限仍沒讓開（1005 soft4；Driver Drive.KEY_ANIMAL_STOP）
    UI_MinidoracatAutoDrive_AnimalBlockStop = "stuck",
}

local outbox = {}      -- pn → { msgs..., n }
local hourly = {}      -- pn → clip 時戳（最近一小時）
local noticed = {}     -- pn → 本次遊戲已提示
local nextSendMs = 0
local msgSeq = 0
local lastSpeed = {}   -- pn → 最近一次取樣速度（節流用）

local function finite(n)
    return type(n) == "number" and n * 0 == 0
end

-- 瞬移（伺服器拉回）的單筆判定：前一筆 prevSpd → 本筆 spd（km/h、絕對值）、原始間隔 gap（ms）、兩筆之間的世界位移 moved（m）。
-- 間隔超過 IMPACT_GAP_MAX_MS 不判（中間沒取樣，車可能被玩家開走）。
function U.teleportLike(prevSpd, spd, gap, moved)
    if prevSpd == nil or not finite(spd) or not finite(gap) or not finite(moved) then return false end
    if gap <= 0 or gap > IMPACT_GAP_MAX_MS then return false end
    local v = prevSpd > spd and prevSpd or spd
    return moved > v / 3.6 * (gap / 1000) * TELEPORT_K + TELEPORT_PAD_M
end

-- 撞擊的單筆門檻（U.sample 與 Diagnostics 撞擊幀強制寫 near、本機 impact 事件共用）：前一筆 prevSpd → 本筆 spd（km/h、絕對值）、
-- 原始間隔 gap（ms）、locked＝本筆或前一筆在鎖輪、moved＝兩筆之間的世界位移（m；瞬移那筆不算撞擊）。不含 IMPACT_REARM_MS
-- （那是片段觸發的去重）。
function U.impactLike(prevSpd, spd, gap, locked, moved)
    return prevSpd ~= nil and finite(spd) and finite(gap) and gap >= 80 and gap <= IMPACT_GAP_MAX_MS
        and prevSpd - spd >= IMPACT_MIN_KMH
        and (prevSpd - spd) / 3.6 / (gap / 1000) >= (locked and IMPACT_DECEL_LOCKED or IMPACT_DECEL)
        and not U.teleportLike(prevSpd, spd, gap, moved)
end

-- 撞擊上升緣的分類（見 TOW_SYNC_MS 上方註解）：spd＝本筆車速（km/h）、phys＝本筆 phys、footprint＝本筆 footprint 命中、
-- near＝nb 掃描結果（true 有近物、false 掃了沒有、nil 沒掃成）、tupDrop＝往前 TOW_SYNC_MS 內 tup 的最大降幅（不拖車 nil）。
-- 回 "frozen"／"tow-sync"／"hit"；任何輸入缺席都落回 hit（寧可多記撞擊）。
function U.impactClass(spd, phys, footprint, near, tupDrop)
    if type(phys) ~= "table" then return "hit" end
    if spd == 0 and phys.vLong == 0 and phys.vLat == 0 then return "frozen" end
    local fbl = phys.forceBrakeLeft
    if near == false and footprint ~= true and phys.isBraking ~= true and not (finite(fbl) and fbl > 0)
            and finite(tupDrop) and tupDrop >= TOW_SYNC_TUP then
        return "tow-sync"
    end
    return "hit"
end

local function nowMs()
    if type(getTimestampMs) ~= "function" then return 0 end
    local ok, v = pcall(getTimestampMs)
    if ok and finite(v) then return v end
    return 0
end

local function jstr(s)
    return MDADDiagnostics.jstr(s)
end

local function jnum(n)
    if not finite(n) then return "0" end
    return tostring(n)
end

-- 四捨五入到 1/k；缺值寫 null（不寫 0：0 km/h、0 m 是真實值）
local function jround(n, k)
    if not finite(n) then return "null" end
    return tostring(math.floor(n * k + 0.5) / k)
end

local function sandboxOn()
    local sb = MDAD and MDAD.sandbox
    if type(sb) ~= "function" then return false end
    local ok, v = pcall(sb, "DiagnosticsUpload", false)
    return ok and v == true
end

-- 只在 MP 客戶端：單機沒有伺服器可收，本機診斷才是那條路。
function U.enabled()
    local okC, client = pcall(isClient)
    if not okC or client ~= true then return false end
    if not sandboxOn() then return false end
    local hud = MDAD and MDAD.HUD
    if type(hud) == "table" and type(hud.shareDiagnostics) == "function" then
        local ok, v = pcall(hud.shareDiagnostics)
        if ok and v == false then return false end
    end
    return true
end

local function notice(pn)
    if noticed[pn] then return end
    noticed[pn] = true
    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(pn) or nil
    if not player or type(HaloTextHelper) ~= "table" then return end
    local text = type(getText) == "function"
        and getText("UI_MinidoracatAutoDrive_UploadNotice")
        or "UI_MinidoracatAutoDrive_UploadNotice"
    -- addText＝白字（HaloTextHelper.java:147-149）：告知、不是警告。
    if type(HaloTextHelper.addText) == "function" then
        pcall(HaloTextHelper.addText, player, text)
    elseif type(HaloTextHelper.addGoodText) == "function" then
        pcall(HaloTextHelper.addGoodText, player, text)
    end
    if MDADDiagnostics and MDADDiagnostics.toast then MDADDiagnostics.toast(text, "info") end
end

function U.begin(pn, now, header, profile)
    local u = {
        pn = pn, active = true,
        -- 與本機 session 共用的取樣閘門欄位（MDAD_Diagnostics.sampleWouldEnqueue／encodeSensor）
        lastSample = nil, lastNow = now, lastStamp = nil,
        drive = now, startTs = now, header = header, routeLine = nil,
        ring = {}, ringTs = {}, ringHead = 0, ringN = 0,
        ev = {}, evTs = {}, evHead = 0, evN = 0,
        cap = nil, clips = 0, lastAnomaly = -1e18, stallSince = nil,
        cooldown = {}, prevFbOn = false, prevFb = false,
        lastTs = nil, lastX = nil, lastY = nil, x0 = nil, y0 = nil, lastRem = nil,
        dist = 0, maxLat = 0, stallMs = 0,
        fb = {}, contact = 0, evc = {}, modeMs = {}, capMs = {},
        fdt = { 0, 0, 0, 0, 0, 0, 0 }, inc = {}, incN = 0, impact = 0, impactAt = nil,
        -- 重跑用：目的地（最後一次 route 事件）與起步航向；片段檔頭用：最近一筆取樣的狀態
        target = nil, h0 = nil,
        sSpd = nil, sTgt = nil, sMode = nil, sLat = nil, sRem = nil, sCap = nil, sFbw = nil,
        -- 0928a：越野接線長、前方區域未載入等待（次數／毫秒）、自轉次數（|yaw|>3 rad/s 上升緣，
        -- <1.5 重新武裝）、有未載入前緣的毫秒
        apr = nil, awN = 0, awMs = 0, prevAw = false, spin = 0, spinArmed = true, unlMs = 0,
        -- 0929c：卡頓降速（Driver 遲滯後的 HUD 狀態）進入次數／毫秒
        lfN = 0, lfMs = 0, prevLf = false,
        -- 1002a 摘要 KPI（全部行程，不只出事的片段）：跟線毫秒、貼近有效上限（≥0.9）毫秒、有效上限×時間、
        -- 低於上限時依限速理由分攤的損失（km/h×ms）；彎道入弧次數、入弧超過彎帽 1.15 倍、弧內偏離期望線
        -- 超過 0.5m 的弧數；帶內有殭屍時的撞擊；加速／減速輔助作用毫秒。
        fm = 0, nm = 0, emSum = 0, loss = {},
        arcN = 0, arcOver = 0, arcDev = 0, prevArc = false, arcDevDone = false,
        impZ = 0, aaMs = 0, daMs = 0, prevZd = nil,
        -- 1006 伺服器拉回（瞬移）次數；prevImpX／Y＝前一筆座標（與 prevImpactSpd 成對）
        tp = 0, prevImpX = nil, prevImpY = nil,
        -- 1008 不算撞擊的兩類（U.impactClass）：凍結樣本、拖車同步拽動的次數；prevImpLike＝前一筆過了 impactLike（只數上升緣）
        frz = 0, tws = 0, prevImpLike = false,
        -- 1004e 越野推力：越野跟線毫秒；「想加速」相鄰兩筆同地表的對——越野／鋪面的毫秒與速度增量（m/s），
        -- 越野對加速度 <1.5 m/s² 的毫秒、越野對有前推輔助的毫秒、遞增倍率頂到 3 的毫秒。aSurf／aSpd＝前一筆狀態。
        oMs = 0, oaMs = 0, oaDv = 0, olMs = 0, oasMs = 0, obMs = 0, paMs = 0, paDv = 0, aSurf = nil, aSpd = nil,
        -- 偏離常駐線（offsetKpi）：累計 ms／段數／最長一段 ms；offSince／offLast＝本段第一筆／最近一筆，offClip＝本段已觸發片段
        offMs = 0, offN = 0, offMax = 0, offSince = nil, offLast = nil, offClip = false,
        halfL = type(profile) == "table" and finite(profile.halfL) and profile.halfL or IMPACT_HALF_L,
        vmax = type(profile) == "table" and profile.maxSpeed or nil,
        svLim = nil,
        rev = MDAD and MDAD.Drive and MDAD.Drive.REV or "",
        build = MDAD and MDAD.BUILD or "",
        veh = type(profile) == "table" and profile.scriptName or "",
        mass = type(profile) == "table" and profile.mass or nil,
        opts = type(header) == "string" and string.match(header, '"opts":"([^"]*)"') or nil,
    }
    local drv = MDAD and MDAD.Drive
    if type(drv) == "table" and type(drv.serverSpeedLimit) == "function" then
        local ok, lim = pcall(drv.serverSpeedLimit)
        if ok and finite(lim) and lim > 0 then u.svLim = lim end
    end
    notice(pn)
    return u
end

-- isEv＝事件列。片段擷取中：full（樣本預算 CLIP_MAX 用完）之前樣本與事件共用預算，觸發 THIN_AFTER_MS 後的樣本降到 5Hz；
-- full 之後樣本不收，事件改吃 CLIP_EV_MAX、照收到窗結束（fullN＝full 那刻的列數；整段上限在 finishClip 再裁）。
local function push(u, line, ts, isEv)
    local i = u.ringHead % RING_N + 1
    u.ringHead = i
    u.ring[i] = line
    u.ringTs[i] = ts
    if u.ringN < RING_N then u.ringN = u.ringN + 1 end
    local cap = u.cap
    if not cap then return end
    if not isEv and cap.lastS and ts - cap.t0 >= THIN_AFTER_MS and ts - cap.lastS < THIN_GAP_MS then return end
    local len = #line + 1
    if not cap.full and cap.chars + len > CLIP_MAX then cap.full, cap.fullN = true, cap.n end
    if not cap.full then
        if not isEv then cap.lastS = ts end
        cap.n = cap.n + 1
        cap.lines[cap.n] = line
        cap.chars = cap.chars + len
    elseif isEv and cap.evChars + len <= CLIP_EV_MAX then
        cap.n = cap.n + 1
        cap.lines[cap.n] = line
        cap.evChars, cap.evN = cap.evChars + len, cap.evN + 1
    end
end

local function incident(u, kind, ts)
    if u.incN >= INC_MAX then return end
    u.incN = u.incN + 1
    u.inc[u.incN] = { kind, ts, u.lastX, u.lastY }
end

local function hourlyOk(pn, now)
    local list = hourly[pn]
    if not list then list = {}; hourly[pn] = list end
    local keep, k = {}, 0
    local i = 1
    while i <= #list do
        if now - list[i] < HOUR_MS and now >= list[i] then
            k = k + 1
            keep[k] = list[i]
        end
        i = i + 1
    end
    hourly[pn] = keep
    return k < CLIPS_PER_HOUR
end

local finishClip -- 定義在下方（trigger 要先收掉 full 的片段）

-- 出事：已在擷取就併入（升級優先級、延長事後窗）；否則從 ring 取事前 PRE_MS 開新片段。full 的片段只剩事件在收：
-- 配額允許開新片段時先收掉它、新片段照常帶事前窗與樣本（舊制 full 當場收窗，下一個事故本來就有自己的片段）。
local function trigger(u, now, kind)
    u.lastAnomaly = now
    incident(u, kind, now)
    local pri = PRI[kind] or 4
    local cap = u.cap
    if cap and not cap.full then
        if pri < cap.pri then cap.pri, cap.kind = pri, kind end
        return
    end
    local last = u.cooldown[kind]
    if u.clips >= CLIPS_PER_DRIVE or (last and now >= last and now - last < KIND_COOLDOWN_MS)
            or not hourlyOk(u.pn, now) then
        if cap and pri < cap.pri then cap.pri, cap.kind = pri, kind end
        return
    end
    if cap then finishClip(u, now) end
    u.cooldown[kind] = now
    cap = { kind = kind, pri = pri, t0 = now, x = u.lastX, y = u.lastY,
        spd = u.sSpd, tgt = u.sTgt, mode = u.sMode, lat = u.sLat, rem = u.sRem, cr = u.sCap, fbw = u.sFbw,
        lines = {}, n = 0, chars = 0, full = false, lastS = nil, evChars = 0, evN = 0 }
    -- ring 由舊到新排：從最新往回找事前窗的起點（ts ≥ t0-PRE_MS）。早於 t0-PRE_THIN_BEFORE_MS 的樣本與上一筆收進的樣本
    -- （較新那筆）間隔 <THIN_GAP_MS 就跳過（5Hz；事件全收）。10Hz 大樣本讓事前窗本身仍超過 CLIP_MAX 時捨最舊的
    -- （片段總長才有上限，整段另由 finishClip 夾在 CLIP_TOTAL_MAX）。wStart＝實際收進的第一列時間：更早的事件改走 finishClip 的窗前事件。
    -- Kahlua 的 % 是截斷式（KahluaThread.java:1060-1066）：ring 繞回後 idx 為負，(idx+k-1)%N 會得負數
    -- 索引、讀到 nil——舊制 PZ 內只收到繞回點之後的樣本（事前窗平均少一半；標準 Lua 的測試照綠）。
    -- 先加 N 讓被除數恆非負（idx ≥ -N）。
    local from, thinBefore = now - PRE_MS, now - PRE_THIN_BEFORE_MS
    local idx = u.ringHead - u.ringN
    local first, chars, ws, keptS, keep = u.ringN + 1, 0, from, nil, {}
    local k = u.ringN
    while k >= 1 do
        local j = (idx + k - 1 + RING_N) % RING_N + 1
        local ts = u.ringTs[j]
        if not ts or ts < from then break end
        local line = u.ring[j]
        local isS = string.sub(line, 1, 8) == '{"t":"s"'
        if not (isS and ts < thinBefore and keptS and keptS - ts < THIN_GAP_MS) then
            local len = #line + 1
            if chars + len > CLIP_MAX then cap.full = true; break end
            chars, ws, keep[k] = chars + len, ts, true
            if isS then keptS = ts end
        end
        first = k
        k = k - 1
    end
    k = first
    while k <= u.ringN do
        if keep[k] then
            cap.n = cap.n + 1
            cap.lines[cap.n] = u.ring[(idx + k - 1 + RING_N) % RING_N + 1]
        end
        k = k + 1
    end
    cap.chars = chars
    cap.wStart = ws
    if cap.full then cap.fullN = cap.n end
    u.cap = cap
    u.clips = u.clips + 1
    local list = hourly[u.pn]
    list[#list + 1] = now
end
U.trigger = trigger

local function enqueueMsg(pn, msg)
    local box = outbox[pn]
    if not box then box = { n = 0, chars = 0 }; outbox[pn] = box end
    -- 超過上限：丟掉最不重要、尚未開始送的一筆（進行中的不動），直到放得下。
    while box.chars + #msg.text > OUTBOX_MAX and box.n > 0 do
        local victim, vi = nil, nil
        local i = 1
        while i <= box.n do
            local m = box[i]
            if m.off == 0 and (not victim or m.pri > victim.pri) then victim, vi = m, i end
            i = i + 1
        end
        if not victim or victim.pri < msg.pri then return false end
        box.chars = box.chars - #victim.text
        table.remove(box, vi)
        box.n = box.n - 1
    end
    msgSeq = msgSeq + 1
    msg.id = msgSeq
    msg.off = 0
    msg.q = 0
    msg.total = math.floor((#msg.text + CHUNK - 1) / CHUNK)
    box.n = box.n + 1
    box[box.n] = msg
    box.chars = box.chars + #msg.text
    return true
end

finishClip = function(u, now)
    local cap = u.cap
    if not cap then return end
    u.cap = nil
    -- 出事當下的狀態放在第一行：片段被截斷（只收到前幾塊）時仍看得到當時車速與限速原因。
    local at = ""
    if finite(cap.spd) then
        at = ',"at":{"spd":' .. jround(cap.spd, 10) .. ',"tgt":' .. jround(cap.tgt, 10)
            .. ',"mode":' .. jstr(cap.mode or "") .. ',"lat":' .. jround(cap.lat, 100)
            .. ',"rem":' .. jround(cap.rem, 1)
            .. ',"cap":' .. jstr(cap.cr or "") .. ',"fbw":' .. jstr(cap.fbw or "") .. '}'
    end
    local function headOf(evx)
        return '{"t":"clip","v":1,"kind":' .. jstr(cap.kind) .. ',"pri":' .. cap.pri
            .. ',"trig":' .. jnum(cap.t0) .. ',"end":' .. jnum(now)
            .. ',"drive":' .. jnum(u.drive) .. ',"pre":' .. PRE_MS
            .. ',"x":' .. jnum(cap.x) .. ',"y":' .. jnum(cap.y) .. at
            .. ',"full":' .. (cap.full and "true" or "false") .. ',"evx":' .. evx .. '}'
    end
    local header = type(u.header) == "string" and u.header or nil
    -- 路線點列與整趟事件只補事前窗之前的（窗內的已在取樣序列裡）。
    local route = u.routeLine and (u.routeTs or 0) < cap.wStart and u.routeLine or nil
    -- 整段 ≤ CLIP_TOTAL_MAX（舊伺服器上限，見常數註解）：固定列（首行以 full 後事件全收的 evx 估，最終只會更短）＋
    -- 窗內列。固定列異常長（樣本已滿）時捨最舊的窗內列；full 後的事件依序能放就放（先到先收，大的放不下不擋後面小的）。
    local fixed = #headOf(cap.evN) + 1 + (header and #header + 1 or 0) + (route and #route + 1 or 0)
    local fullN = cap.fullN or cap.n
    local lo, chars = 1, cap.chars
    while lo <= fullN and fixed + chars > CLIP_TOTAL_MAX do
        chars = chars - #cap.lines[lo] - 1
        lo = lo + 1
    end
    local room = CLIP_TOTAL_MAX - fixed - chars
    local keep, evx, evChars = {}, 0, 0
    local i = fullN + 1
    while i <= cap.n do
        local len = #cap.lines[i] + 1
        if evChars + len <= room then keep[i], evx, evChars = true, evx + 1, evChars + len end
        i = i + 1
    end
    local head = headOf(evx)
    local parts, n = { head }, 1
    local used = #head + 1
    if header then
        n = n + 1; parts[n] = header; used = used + #header + 1
    end
    if route then
        n = n + 1; parts[n] = route; used = used + #route + 1
    end
    local budget = CLIP_MAX - chars - used
    local left = CLIP_TOTAL_MAX - chars - used - evChars
    if left < budget then budget = left end
    local startK = 1
    local evBytes = 0
    local k = u.evN
    while k >= 1 do
        local j = (u.evHead - u.evN + k - 1 + EVLOG_N) % EVLOG_N + 1 -- 同上：負索引＝nil 比較直接拋錯、整段上傳被丟
        if u.evTs[j] < cap.wStart then
            local len = #u.ev[j] + 1
            if evBytes + len > budget then startK = k + 1; break end
            evBytes = evBytes + len
        end
        k = k - 1
    end
    k = startK
    while k <= u.evN do
        local j = (u.evHead - u.evN + k - 1 + EVLOG_N) % EVLOG_N + 1
        if u.evTs[j] < cap.wStart and u.ev[j] ~= u.routeLine then
            n = n + 1; parts[n] = u.ev[j]
        end
        k = k + 1
    end
    i = lo
    while i <= cap.n do
        if i <= fullN or keep[i] then
            n = n + 1; parts[n] = cap.lines[i]
        end
        i = i + 1
    end
    enqueueMsg(u.pn, {
        k = "clip", kind = cap.kind, pri = cap.pri, trig = cap.t0, x = cap.x, y = cap.y,
        drive = u.drive, rev = u.rev, veh = u.veh,
        text = table.concat(parts, "\n", 1, n) .. "\n",
    })
end

local function captureTick(u, now)
    local cap = u.cap
    if not cap then return end
    local age = now - cap.t0
    -- full 不收窗：之後的事件（脫困結果、release）照收到窗結束（push 的 CLIP_EV_MAX）
    if age >= POST_MAX_MS
            or (age >= POST_MIN_MS and now - u.lastAnomaly >= QUIET_MS) then
        finishClip(u, now)
    end
end

-- 1002a 摘要 KPI（欄位見 U.begin）：只算跟線中（mode follow）的取樣。有效上限＝檔位／感知／沙盒／車輛極速／
-- 伺服器速限取小；「貼近上限」＝實速 ≥0.9×有效上限（引擎推力在極速附近遞減，多數車只到極速的九成多）。
-- 舊摘要只有限速理由的時間：車在直路已經跑到車輛極速時也記成 curve-coast（車道包絡在直路＝車輛極速），
-- 量不到「多少時間在最高速」與「慢在哪」。
local function speedKpi(u, phys, spd, target, mode, dt, capReason)
    if dt <= 0 or mode ~= "follow" or type(phys) ~= "table" then return end
    local em = u.vmax
    if not finite(em) or em <= 0 then em = nil end
    local v = phys.capGear
    if finite(v) and v > 0 and (em == nil or v < em) then em = v end
    v = phys.capPerception
    if finite(v) and v > 0 and (em == nil or v < em) then em = v end
    v = phys.capMax
    if finite(v) and v > 0 and (em == nil or v < em) then em = v end
    v = u.svLim
    if finite(v) and v > 0 and (em == nil or v < em) then em = v end
    if em == nil then return end
    u.fm = u.fm + dt
    u.emSum = u.emSum + em * dt
    if spd >= 0.9 * em then
        u.nm = u.nm + dt
    else
        local r = capReason
        if type(r) ~= "string" then r = (finite(target) and target >= 0.9 * em) and "accel" or "none" end
        u.loss[r] = (u.loss[r] or 0) + (em - spd) * dt
    end
    -- 彎道：入弧（curveHardActive 上升緣）次數、入弧速超過彎帽 1.15 倍、弧內離期望線超過 0.5m 的弧數
    local arc = phys.curveHardActive == true
    if arc and not u.prevArc then
        u.arcN, u.arcDevDone = u.arcN + 1, false
        local cc = phys.curveCap
        if finite(cc) and cc > 0 and spd > 1.15 * cc then u.arcOver = u.arcOver + 1 end
    end
    if arc and not u.arcDevDone then
        local ld = phys.latDev
        if finite(ld) and (ld > 0.5 or ld < -0.5) then u.arcDev, u.arcDevDone = u.arcDev + 1, true end
    end
    u.prevArc = arc
    if finite(phys.accelAssist) and phys.accelAssist > 0 then u.aaMs = u.aaMs + dt end
    if finite(phys.visAssistDecel) and phys.visAssistDecel > 0 then u.daMs = u.daMs + dt end
end

-- 1004e 越野推力 KPI（欄位見 U.begin）：跟線中「想加速」＝目標−實速 ≥6 km/h、前進、沒強制煞車。相鄰兩筆都想加速
-- 且同地表（physicalOffroad）才算一對；平均加速度＝Dv/Ms×1000 離線算。原始間隔 >1s（中間沒取樣）不比；
-- 輔助／倍率看這一對的後一筆。推力夠不夠要看自己的紀錄，不靠玩家片段。
local function accelKpi(u, phys, speed, target, mode, gap)
    local prev, v0 = u.aSurf, u.aSpd
    u.aSurf = nil
    if mode ~= "follow" or type(phys) ~= "table" or not finite(speed) then return end
    local off = phys.physicalOffroad == true
    if off then u.oMs = u.oMs + (gap > 1000 and 1000 or gap) end
    local fbl = phys.forceBrakeLeft
    if not finite(target) or target - speed < 6 or speed < 0 or (finite(fbl) and fbl > 0) then return end
    local surf = off and "o" or "p"
    u.aSurf, u.aSpd = surf, speed
    if prev ~= surf or gap <= 0 or gap > 1000 then return end
    local dv = (speed - v0) / 3.6
    if not off then
        u.paMs, u.paDv = u.paMs + gap, u.paDv + dv
        return
    end
    u.oaMs, u.oaDv = u.oaMs + gap, u.oaDv + dv
    if dv / gap * 1000 < 1.5 then u.olMs = u.olMs + gap end
    local af, aca, asb = phys.assistForce, phys.accelAssist, phys.assistBoost
    if (finite(af) and af > 0) or (finite(aca) and aca > 0) then u.oasMs = u.oasMs + gap end
    if finite(asb) and asb >= 3 - 1e-6 then u.obMs = u.obMs + gap end
end

-- 偏離常駐線 KPI（常數註解見 OFF_LAT_M）。座標：lat／el／rsd／rsl 都是相對路線剖面中心線的橫向（同號同軸）；ld＝lat−el。
-- rsd 是沒夾路寬的常駐 bias（彎內側、窄段會差 1m 以上），所以平常量 ld（沒人持有時 el＝夾過的常駐線）、鏈著時量
-- lat−rsl（Driver 只在 lc 時寫的夾過常駐線；缺就不算）。有主的偏移不算：繞行（AVOID）、RETURN、判堵／停等（HOLD）、
-- 脫困（RECOVER）都不是 controlState TRACK；殭屍軟縫（zln）；斜切保持與會車側移的期望線就是持有的 lane（ld 小）；
-- 調頭＝車頭背向路線（|att| ≥ π/2）；起步與繞行放手後的接回保護（sg，START_GUARD_MAX_M 內）；起步越野接線＝rs < apr。
-- 原始間隔超過 IMPACT_GAP_MAX_MS（中間沒取樣）重新起算一段。
local function offsetKpi(u, phys, lat, mode, line, now, gap)
    local dev = nil
    if mode == "follow" and type(phys) == "table" and phys.controlState == "TRACK" and phys.zombieLane == nil
            and phys.startGuard ~= true then
        dev = phys.latDev
        if phys.laneChained == true then
            local rsl = phys.residentLane
            dev = (finite(lat) and finite(rsl)) and lat - rsl or nil
        end
        local att = phys.routeHeadingError
        if not finite(dev) or (dev <= OFF_LAT_M and dev >= -OFF_LAT_M)
                or (finite(att) and (att >= 1.5708 or att <= -1.5708)) then
            dev = nil
        elseif finite(u.apr) and u.apr > 0 then
            local rs = tonumber(string.match(line, '"rs":([%-%d%.eE%+]+)'))
            if finite(rs) and rs < u.apr then dev = nil end
        end
    end
    if dev == nil then
        u.offSince = nil
        return
    end
    if u.offSince == nil or gap > IMPACT_GAP_MAX_MS then
        u.offSince, u.offLast, u.offClip = now, now, false
        return
    end
    local dur = now - u.offSince
    if dur >= OFF_MIN_MS then
        if dur - (now - u.offLast) < OFF_MIN_MS then
            u.offN, u.offMs = u.offN + 1, u.offMs + dur -- 本筆剛過門檻：整段到此的時間一次算進去
        else
            u.offMs = u.offMs + (now - u.offLast)
        end
        if dur > u.offMax then u.offMax = dur end
        if dur >= OFF_CLIP_MS and not u.offClip then
            u.offClip = true
            trigger(u, now, "offset")
        end
    end
    u.offLast = now
end

-- 取樣：line 已由 MDAD_Diagnostics 編好（與本機紀錄同一字串，不重複編碼）。cls＝這筆若在撞擊段內，
-- Diagnostics 在上升緣算的分類（U.impactClass；整段沿用，不在撞擊段＝nil）。
function U.sample(u, line, now, x, y, speed, target, mode, remaining, lat,
        blocked, footprintBlocked, phys, heading, sensor, cls)
    push(u, line, now)
    if finite(x) and finite(y) then
        if not u.x0 then u.x0, u.y0 = x, y end
        u.lastX, u.lastY = x, y
    end
    if not u.h0 and finite(heading) then u.h0 = heading end
    if finite(remaining) then u.lastRem = remaining end
    -- 1005i 預計剩餘：第一個估計與它離出發幾 ms（摘要 eta0／eta0t；對照 dur 校準修正倍率）
    if u.eta0 == nil and type(phys) == "table" and finite(phys.etaSec) then
        u.eta0, u.eta0t = phys.etaSec, now - u.startTs
    end
    if finite(speed) then lastSpeed[u.pn] = speed < 0 and -speed or speed end
    -- 片段檔頭的出事當下狀態（trigger 取這幾格；本幀觸發的就是本幀值）
    u.sSpd, u.sTgt, u.sMode, u.sLat, u.sRem = speed, target, mode, lat, remaining
    u.sCap = type(phys) == "table" and phys.capReason or nil
    local fbl0 = type(phys) == "table" and phys.forceBrakeLeft or nil
    u.sFbw = finite(fbl0) and fbl0 > 0 and phys.forceBrakeWhy or nil
    local dt, gap = 0, 0
    if u.lastTs and now > u.lastTs then
        gap = now - u.lastTs -- 原始間隔（撞擊判斷用）；dt 夾 1 秒，只供時間累計
        dt = gap > 1000 and 1000 or gap
    end
    u.lastTs = now
    local spd = finite(speed) and (speed < 0 and -speed or speed) or 0
    u.dist = u.dist + spd / 3.6 * dt / 1000
    if finite(lat) then
        local a = lat < 0 and -lat or lat
        if a > u.maxLat then u.maxLat = a end
    end
    if type(mode) == "string" then u.modeMs[mode] = (u.modeMs[mode] or 0) + dt end
    local fbl, fbw, capReason, fdt
    if type(phys) == "table" then
        fbl, fbw, capReason, fdt = phys.forceBrakeLeft, phys.forceBrakeWhy, phys.capReason, phys.frameMs
        if phys.areaWait == true then
            if not u.prevAw then u.awN = u.awN + 1 end
            u.awMs = u.awMs + dt
            u.prevAw = true
        else
            u.prevAw = false
        end
        local yr = phys.yawRate
        if finite(yr) then
            if yr < 0 then yr = -yr end
            if yr > 3 then
                if u.spinArmed then u.spin, u.spinArmed = u.spin + 1, false end
            elseif yr < 1.5 then
                u.spinArmed = true
            end
        end
        if finite(phys.unloadedS) then u.unlMs = u.unlMs + dt end
        local lf = phys.lowFps == true
        if lf then
            if not u.prevLf then u.lfN = u.lfN + 1 end
            u.lfMs = u.lfMs + dt
        end
        u.prevLf = lf
    end
    if type(capReason) == "string" then u.capMs[capReason] = (u.capMs[capReason] or 0) + dt end
    speedKpi(u, phys, spd, target, mode, dt, capReason)
    accelKpi(u, phys, speed, target, mode, gap)
    offsetKpi(u, phys, lat, mode, line, now, gap)
    if finite(fdt) then
        local b = fdt < 10 and 1 or fdt < 17 and 2 or fdt < 25 and 3 or fdt < 34 and 4
            or fdt < 50 and 5 or fdt < 100 and 6 or 7
        u.fdt[b] = u.fdt[b] + 1
    end
    -- 停滯：要走（目標 ≥10）卻幾乎不動，持續 STALL_MS 算異常（接手判定用）。
    if finite(target) and target >= 10 and spd < 3 then
        if not u.stallSince then u.stallSince = now end
        u.stallMs = u.stallMs + dt
        if now - u.stallSince >= STALL_MS then u.lastAnomaly = now end
    else
        u.stallSince = nil
    end
    if blocked == true or mode == "unstick" or mode == "recover" then u.lastAnomaly = now end
    local fbNow = finite(fbl) and fbl > 0
    local fbWas = u.prevFbOn == true
    if fbNow and not u.prevFbOn then
        local why = type(fbw) == "string" and fbw or "?"
        u.fb[why] = (u.fb[why] or 0) + 1
        -- 預期中的煞車（到站、脫困流程）與幾乎靜止時的煞車不算事故
        if why ~= "arrive" and string.sub(why, 1, 7) ~= "unstick" and why ~= "contact"
                and spd >= 3 then
            trigger(u, now, "brake")
        end
    end
    u.prevFbOn = fbNow
    local fbHit = footprintBlocked == true
    if fbHit and not u.prevFb then
        u.contact = u.contact + 1
        trigger(u, now, "contact")
    end
    u.prevFb = fbHit
    -- 撞擊（含鎖輪中撞上）；同一次撞擊的連續幾筆只算一次。本筆或前一筆在鎖輪＝門檻 IMPACT_DECEL_LOCKED；
    -- 原始間隔超過 IMPACT_GAP_MAX_MS（中間沒取樣）不比。
    local prevSpd = u.prevImpactSpd
    -- 帶內最近殭屍離車心的距離（絕對值；快照最多舊一輪，殭屍可能已在車心後）。只在帶內有殭屍時解析 rs。
    local zd = nil
    if type(sensor) == "table" and finite(sensor.zombieN) and sensor.zombieN > 0 and finite(sensor.zombieNearS) then
        local rs = tonumber(string.match(line, '"rs":([%-%d%.eE%+]+)'))
        if finite(rs) then
            zd = sensor.zombieNearS - rs
            if zd < 0 then zd = -zd end
        end
    end
    -- 前一筆→本筆的世界位移（瞬移判定；任一筆沒有座標＝nil，不判）
    local moved = nil
    local px, py = u.prevImpX, u.prevImpY
    if px and finite(x) and finite(y) then moved = math.sqrt((x - px) * (x - px) + (y - py) * (y - py)) end
    if finite(speed) and U.teleportLike(prevSpd, spd, gap, moved) then u.tp = u.tp + 1 end
    local imp = finite(speed) and U.impactLike(prevSpd, spd, gap, fbNow or fbWas, moved)
    if imp and (cls == "frozen" or cls == "tow-sync") then
        -- 1008 不是撞擊：同一段只在上升緣數一次，不觸發片段、不進 impact／impZ
        if not u.prevImpLike then
            if cls == "frozen" then u.frz = u.frz + 1 else u.tws = u.tws + 1 end
        end
    elseif imp and not (u.impactAt and now >= u.impactAt and now - u.impactAt < IMPACT_REARM_MS) then
        u.impact, u.impactAt = u.impact + 1, now
        -- 撞擊那筆或前一筆有殭屍在車身附近（多半是撞進殭屍群；也可能是殭屍旁的別的東西）
        local zw, pz = u.halfL + IMPACT_ZOMBIE_M, u.prevZd
        if (zd and zd <= zw) or (pz and pz <= zw) then u.impZ = u.impZ + 1 end
        trigger(u, now, "impact")
    end
    u.prevImpLike = imp == true
    u.prevImpactSpd = finite(speed) and spd or nil
    if finite(x) and finite(y) then u.prevImpX, u.prevImpY = x, y else u.prevImpX, u.prevImpY = nil, nil end
    u.prevZd = zd
    captureTick(u, now)
end

function U.event(u, line, now, name, a)
    push(u, line, now, true)
    name = tostring(name or "")
    u.evc[name] = (u.evc[name] or 0) + 1
    if name ~= "replan" then
        local i = u.evHead % EVLOG_N + 1
        u.evHead = i
        u.ev[i] = line
        u.evTs[i] = now
        if u.evN < EVLOG_N then u.evN = u.evN + 1 end
    end
    if string.find(line, '"src":"', 1, true) then
        u.routeLine, u.routeTs = line, now
    end
    local phase = type(a) == "table" and a.phase or nil
    if name == "route" and phase == "ready" and u.apr == nil and finite(a.approach) then
        u.apr = a.approach -- 起步越野接線長（Driver 只在起步的 ready 帶）
    end
    if name == "route" and type(a) == "table" and type(a.target) == "string" then
        u.target = a.target -- 最後一個目的地（行程換站時跟著換）
    end
    if name == "unstick" and phase == "start" then
        trigger(u, now, "unstick")
    elseif name == "detour" and phase ~= "skip" then
        trigger(u, now, "detour")
    elseif name == "blocked" or name == "unstick" or name == "progress" then
        u.lastAnomaly = now
    elseif name == "takeover" and phase == "yield" and now - u.lastAnomaly <= ANOMALY_TAKEOVER_MS then -- resume（1008）不是接手
        trigger(u, now, "takeover")
    end
    captureTick(u, now)
end

local function mapJson(t)
    local parts, n = {}, 0
    for k, v in pairs(t) do
        n = n + 1
        parts[n] = jstr(k) .. ":" .. jnum(v)
    end
    return "{" .. table.concat(parts, ",", 1, n) .. "}"
end

-- 損失（km/h×ms）以 km/h×秒、四捨五入整數輸出
local function lossJson(t)
    local parts, n = {}, 0
    for k, v in pairs(t) do
        n = n + 1
        parts[n] = jstr(k) .. ":" .. tostring(math.floor(v / 1000 + 0.5))
    end
    return "{" .. table.concat(parts, ",", 1, n) .. "}"
end

local function summaryText(u, now, reason, withMaps)
    local inc, n = {}, 0
    local i = 1
    while i <= u.incN do
        local e = u.inc[i]
        n = n + 1
        inc[n] = "[" .. jstr(e[1]) .. "," .. jnum(e[2]) .. "," .. jnum(e[3]) .. "," .. jnum(e[4]) .. "]"
        i = i + 1
    end
    local text = '{"t":"sum","v":1,"drive":' .. jnum(u.drive) .. ',"end":' .. jnum(now)
        .. ',"dur":' .. jnum(now - u.startTs) .. ',"reason":' .. jstr(reason)
        .. ',"rev":' .. jstr(u.rev) .. ',"build":' .. jstr(u.build)
        .. ',"veh":' .. jstr(u.veh) .. ',"mass":' .. jnum(u.mass)
        .. (u.opts and (',"opts":' .. jstr(u.opts)) or "")
        .. ',"dist":' .. jnum(math.floor(u.dist * 10 + 0.5) / 10)
        .. ',"maxLat":' .. jnum(math.floor(u.maxLat * 100 + 0.5) / 100)
        .. ',"stallMs":' .. jnum(u.stallMs)
        .. ',"x0":' .. jnum(u.x0) .. ',"y0":' .. jnum(u.y0)
        .. ',"x1":' .. jnum(u.lastX) .. ',"y1":' .. jnum(u.lastY)
        .. ',"rem":' .. jnum(u.lastRem) .. ',"clips":' .. u.clips
        .. (u.target and (',"target":' .. jstr(u.target)) or "")
        .. ',"h0":' .. jround(u.h0, 100) .. ',"impact":' .. u.impact
        .. ',"contact":' .. u.contact .. ',"fb":' .. mapJson(u.fb)
        .. ',"fdt":[' .. table.concat(u.fdt, ",") .. ']'
        .. ',"inc":[' .. table.concat(inc, ",", 1, n) .. ']'
        .. (u.apr and (',"apr":' .. jnum(math.floor(u.apr * 10 + 0.5) / 10)) or "")
        .. ',"aw":' .. u.awN .. ',"awMs":' .. jnum(u.awMs)
        .. ',"spin":' .. u.spin .. ',"unlMs":' .. jnum(u.unlMs)
        .. ',"lf":' .. u.lfN .. ',"lfMs":' .. jnum(u.lfMs)
        .. ',"vmax":' .. jround(u.vmax, 1)
        .. ',"fm":' .. jnum(u.fm) .. ',"nm":' .. jnum(u.nm)
        .. ',"em":' .. jround(u.fm > 0 and u.emSum / u.fm or nil, 10)
        .. ',"arc":' .. u.arcN .. ',"arcOver":' .. u.arcOver .. ',"arcDev":' .. u.arcDev
        .. ',"impZ":' .. u.impZ .. ',"tp":' .. u.tp .. ',"frz":' .. u.frz .. ',"tws":' .. u.tws
        .. ',"aaMs":' .. jnum(u.aaMs) .. ',"daMs":' .. jnum(u.daMs)
        .. ',"oMs":' .. jnum(u.oMs) .. ',"oaMs":' .. jnum(u.oaMs) .. ',"oaDv":' .. jround(u.oaDv, 100)
        .. ',"olMs":' .. jnum(u.olMs) .. ',"oasMs":' .. jnum(u.oasMs) .. ',"obMs":' .. jnum(u.obMs)
        .. ',"paMs":' .. jnum(u.paMs) .. ',"paDv":' .. jround(u.paDv, 100)
        .. ',"eta0":' .. jround(u.eta0, 10) .. ',"eta0t":' .. jround(u.eta0t, 1)
        .. ',"offMs":' .. jnum(u.offMs) .. ',"offN":' .. u.offN .. ',"offMax":' .. jnum(u.offMax)
    if withMaps then
        text = text .. ',"ev":' .. mapJson(u.evc) .. ',"mode":' .. mapJson(u.modeMs)
            .. ',"cap":' .. mapJson(u.capMs) .. ',"loss":' .. lossJson(u.loss)
    end
    return text .. "}"
end

-- 行程結束：終局原因本身也可能是事故（卡住交還、車輛不支援、路線遺失、接手前有異常）。
function U.finish(u, now, reason)
    if not u or not u.active then return end
    u.active = false
    reason = tostring(reason or "stop")
    local kind = STOP_KIND[reason]
    if kind then
        trigger(u, now, kind)
    elseif reason == "takeover" and now - u.lastAnomaly <= ANOMALY_TAKEOVER_MS then
        trigger(u, now, "takeover")
    end
    finishClip(u, now)
    if reason == "menu" then return end
    local text = summaryText(u, now, reason, true)
    if #text > SUM_MAX then text = summaryText(u, now, reason, false) end
    if #text > SUM_MAX then return end
    enqueueMsg(u.pn, { k = "sum", pri = 0, drive = u.drive, rev = u.rev, veh = u.veh, text = text })
end

local function sendChunk(pn, args)
    local player = type(getSpecificPlayer) == "function" and getSpecificPlayer(pn) or nil
    if not player then return false end
    sendClientCommand(player, MDAD.MOD_ID, MDAD.CMD_DIAG_UPLOAD, args)
    return true
end

-- 每幀只做一次時間比較；到期才送一塊（全部本機玩家共用節奏）。
function U.tick()
    local now = nowMs()
    if now < nextSendMs then return end
    local pn, box = nil, nil
    local p = 0
    while p <= 3 do
        local b = outbox[p]
        if b and b.n > 0 then pn, box = p, b; break end
        p = p + 1
    end
    if not box then return end
    local m = box[1]
    local q = m.q + 1
    local data = string.sub(m.text, m.off + 1, m.off + CHUNK)
    local args = { id = m.id, q = q, n = m.total, k = m.k, data = data }
    if q == 1 then
        args.len = #m.text
        args.kind = m.kind
        args.pri = m.pri
        args.trig = m.trig
        args.drive = m.drive
        args.rev = m.rev
        args.veh = m.veh
        args.x = m.x
        args.y = m.y
    end
    local ok, sent = pcall(sendChunk, pn, args)
    if not ok or not sent then
        -- 玩家不在（分割畫面離開）：這位玩家的待送全部作廢，不改掛到別人名下。
        outbox[pn] = nil
        return
    end
    m.q = q
    m.off = m.off + #data
    if m.off >= #m.text then
        box.chars = box.chars - #m.text
        table.remove(box, 1)
        box.n = box.n - 1
    end
    local driving = MDAD and MDAD.Drive and type(MDAD.Drive.isActive) == "function"
        and MDAD.Drive.isActive(pn) and (lastSpeed[pn] or 0) >= DRIVING_KMH
    nextSendMs = now + (driving and SEND_DRIVING_MS or SEND_IDLE_MS)
end

function U.pending(pn)
    local box = outbox[pn]
    return box and box.n or 0
end

-- 回主選單：連線已斷，待送全部作廢（下次進遊戲重新提示）。
function U.reset()
    outbox = {}
    noticed = {}
    lastSpeed = {}
    nextSendMs = 0
end

if Events and Events.OnTick and Events.OnTick.Add then
    Events.OnTick.Add(function() U.tick() end)
end
if Events and Events.OnMainMenuEnter and Events.OnMainMenuEnter.Add then
    Events.OnMainMenuEnter.Add(function() U.reset() end)
end
