-- MDAD_Server.lua — 安裝／卸載的伺服器端權威入口（MP）。
--
-- 為什麼不能留在 TimedAction 的 complete()：B42 MP 的伺服器端跑的不是玩家那個 Lua
-- TimedAction 物件，而是 NetTimedAction 鏡像——鏡像的 perform() 唯一做的事就是呼叫
-- Lua 端的 complete()（NetTimedAction.java:132-139），而鏡像本身是用 client 送來的
-- new() 參數逐一反序列化重建的（送出端 NetTimedAction.set 依 new() 的參數名逐欄打包，
-- :36-55；伺服器端 parse 再照樣呼叫 <Type>.new(...)，:142-170）。也就是說連 character
-- 都由 client 指定，突變寫在 complete() 等於讓 client 宣告「誰、對哪台車、用哪件物品」。
-- 詳細的引擎行為與代價見 shared/TimedActions/ISAutoDriveDeviceAction.lua 檔頭。
--
-- 改法：TimedAction 只負責工時／動畫，突變一律走
--   client perform() → sendClientCommand → 本檔 OnClientCommand → MDAD.applyDeviceChange
-- actor 只採 OnClientCommand 的第三參數：它是伺服器用連線反查出來的
-- （GameServer.receiveClientCommand:2247-2300，player 由 getPlayerFromConnection 取得
-- ＝:2264），client 無法在 payload 裡指定別人。其餘（載具、零件、物品、電量、狀態）
-- 全部在伺服器端重新解析。
--
-- 本檔在專用伺服器與 SP 都會載入（`media/lua/server` 客戶端也會載入，故用
-- `isClient()` 早退，家族慣例同 MinidoracatCleaner_Commands.lua:1）。SP 不會走到這裡：
-- TimedAction 在非 client 端直接呼叫 shared apply，不發指令，因此不會重複執行。
if isClient() then return end

require "MDAD"

-- per-player 節流：偽造封包每次都會觸發一輪背包重解析＋可及性檢查，而 OnClientCommand
-- 是在伺服器主執行緒同步跑的。合法操作有 150 tick 工時，間隔遠大於此，不會誤傷。
local MIN_INTERVAL_MS = 250
local lastAt = {}

-- 失敗回報：伺服器不能畫 UI，回一則翻譯鍵給操作者，由 client 端 HaloTextHelper 顯示。
-- 只回傳伺服器自己選定的常數鍵，不回傳任何 client 送來的字串。
-- payload 帶 to（角色名）：sendServerCommand(player,...) 定位的是連線（同機分割畫面
-- 共用一條），client 端要靠 to 才知道提示要掛在哪個本機玩家身上。
-- sendServerCommand(player, module, command, args)＝LuaManager.java:8942
local function notifyFail(player, reason)
    sendServerCommand(player, MDAD.MOD_ID, MDAD.CMD_DEVICE_FAILED,
        { reason = reason, to = player:getUsername() })
end

-- args 只讀 vehicleId／kind／install／itemId 四個純量；其餘欄位（actor、partId、
-- navDelta、state）就算 client 塞了也不看。
-- vehicleId 要進 Java int，光檢查型別不夠（小數被截斷成別的 id、NaN／±Inf 變垃圾 id），
-- 用 shared 的 MDAD.isFiniteInt；itemId 同一份判定在 applyDeviceChange 的 ① schema 做。
local function onDevice(player, args)
    if type(args) ~= "table" then return end
    if not MDAD.isFiniteInt(args.vehicleId) then return end
    -- getVehicleById＝LuaManager.java:10247（原版伺服器端用例 VehicleCommands.lua:33）
    local vehicle = getVehicleById(args.vehicleId)
    if not vehicle then return end
    local ok, reason = MDAD.applyDeviceChange(player, vehicle, args.kind, args.install, args.itemId)
    if not ok and reason then
        notifyFail(player, reason)
    end
end

-- 只有認得的 command 才進節流表：若未知 command 也先寫入，任意偽造字串可讓 lastAt
-- 無界成長（記憶體 DoS）。table lookup 對非字串 command 也安全。
local HANDLERS = {}
HANDLERS[MDAD.CMD_DEVICE] = onDevice

-- OnClientCommand 簽名（module, command, player, args）＝ClientCommands.lua:1249-1260
local function onClientCommand(module, command, player, args)
    if module ~= MDAD.MOD_ID or not player then return end
    local handler = HANDLERS[command]
    if not handler then return end
    local key = player:getUsername()
    local now = getTimestampMs()
    local last = lastAt[key]
    if last and now - last < MIN_INTERVAL_MS then return end
    lastAt[key] = now
    handler(player, args)
end

Events.OnClientCommand.Add(onClientCommand)
