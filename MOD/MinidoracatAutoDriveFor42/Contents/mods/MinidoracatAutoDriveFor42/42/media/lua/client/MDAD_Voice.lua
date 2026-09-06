-- MDAD_Voice.lua
-- 自動駕駛語音提示（2026-09-02 使用者裁定）：啟動／關閉／受阻煞停／倒車脫困／
-- 無法通過交還／到站／改道／無路可繞，加上手動介入三句（讓位待命／恢復接手／介入即關閉，
-- 2026-09-06），依遊戲語言選國語（CH／CN）、日語（JP）或英語，ESC「語音語言」可改指定語音包。
-- 聲音檔與 sound script：42/media/sound/MinidoracatAutoDrive、scripts/sounds_autodrive.txt
-- （產生器與文本：repo scripts/voice_lines.json＋fish-audio-tts skill）。
--
-- 播放走玩家 emitter 的本機路徑：`getEmitter():playSoundImpl(name, nil)`
-- （FMODSoundEmitter.java:484-492；原版用例 ISAddItemInRecipe.lua:44）——與
-- `playSound(name)` 不同，**不送 PlaySound 封包**（:389-402），MP 其他玩家聽不到。
-- 逐次音量：`emitter:setVolume(ref, v)`（:284-298，對排隊中與播放中都生效）；
-- `getSoundManager():playUISound` 沒有逐次音量（SoundManager.java:193-227），
-- `GameSound.setUserVolume` 被 SystemDisabler 閘住（GameSound.java:39-41），都不可用。
-- 語言：`Translator.getLanguage():name()`（原版 ISLcdBar.lua:14）。
--
-- 契約：任何失敗只印一次診斷、絕不拋到呼叫端（Driver 用 pcall 包，這裡再自守一層）；
-- 同一玩家新句蓋舊句（stopSound 舊 ref）；開關／音量每次播放重讀 HUD option。

require "MDAD"

if MDAD.Voice then return end

local Voice = {}
local EVENTS = {
    start = true, stop = true, blocked = true,
    unstick = true, handback = true, arrive = true,
    detour = true, nodetour = true,
    yield = true, resume = true, manual = true,
}
local SOUND_PREFIX = "MDAD_Voice_"
local lastRef = {}       -- playerNum → emitter ref（long）
local lastEmitter = {}   -- playerNum → emitter
local lastEvent = {}     -- playerNum → 上一句事件名
local lastAt = {}        -- playerNum → 上一句送出時刻（ms）
local warned = {}
-- 同一事件重複觸發不連播（2026-09-02 實機：受阻煞停 7 秒內念了 6 次——blocked 隨
-- 每輪掃描翻轉，Driver 的 blockedNotified 每翻一次就重觸發）。同一玩家同一事件：
-- 上一句還在播就不插，播完也要隔 REPEAT_COOLDOWN_MS 才准再念；換了事件照舊蓋舊句。
Voice.REPEAT_COOLDOWN_MS = 8000

local function warnOnce(key, msg)
    if warned[key] then return end
    warned[key] = true
    print("[" .. MDAD.MOD_ID .. "] voice: " .. msg)
end

local function finite(n)
    return type(n) == "number" and n * 0 == 0
end

-- 語音包以「口說語言」分檔（zh 國語／en／ja），不以遊戲語系分：CH 與 CN 只差文字
-- 書寫，同一份國語音檔；遊戲語系→語音包對照只在這一張表。順序＝ESC／MiniMap
-- 「語音語言」下拉的順序（1=跟隨遊戲語言、2..=語音包），HUD 以 index 存選項。
Voice.PACKS = { "zh", "en", "ja" }
local LOCALE_PACK = { CH = "zh", CN = "zh", JP = "ja" }  -- 其餘語系 → en
local PACK_SET = {}
for i = 1, #Voice.PACKS do PACK_SET[Voice.PACKS[i]] = true end

-- 跟隨遊戲語言：`Translator.getLanguage():name()`（原版 ISLcdBar.lua:14）
function Voice.autoLanguage()
    local ok, name = pcall(function() return Translator.getLanguage():name() end)
    if ok and type(name) == "string" and LOCALE_PACK[name] then return LOCALE_PACK[name] end
    return "en"
end

-- HUD option 讀取（語言／開關／音量同款）：HUD 缺席、方法缺席或拋錯一律回 nil。
local function hudOpt(name)
    local hud = MDAD.HUD
    if type(hud) ~= "table" or type(hud[name]) ~= "function" then return nil end
    local ok, value = pcall(hud[name])
    if ok then return value end
    return nil
end

-- 玩家在選項指定的語音包（HUD.voiceLanguage 回 "auto" 或 pack 名）優先；缺席／
-- 非法值一律退回跟隨遊戲語言，永不讓播放端拿到沒有音檔的 pack 名。
function Voice.language()
    local value = hudOpt("voiceLanguage")
    if type(value) == "string" and PACK_SET[value] then return value end
    return Voice.autoLanguage()
end

local function voiceEnabled()
    local value = hudOpt("voiceEnabled")
    if type(value) == "boolean" then return value end
    return true
end

-- 0..1
local function voiceVolume()
    local value = hudOpt("voiceVolume")
    if not finite(value) then return 0.7 end
    if value < 0 then value = 0 elseif value > 100 then value = 100 end
    return value / 100
end

function Voice.soundName(event)
    return SOUND_PREFIX .. event .. "_" .. Voice.language()
end

local function stillPlaying(playerNum)
    local ref, emitter = lastRef[playerNum], lastEmitter[playerNum]
    if not ref or not emitter then return false end
    local ok, playing = pcall(emitter.isPlaying, emitter, ref)
    return ok and playing == true
end

local function stopPrevious(playerNum)
    if stillPlaying(playerNum) then
        local emitter = lastEmitter[playerNum]
        pcall(emitter.stopSound, emitter, lastRef[playerNum])
    end
    lastRef[playerNum], lastEmitter[playerNum] = nil, nil
end

-- 同事件重播閘：上一句同事件仍在播，或距上一句送出不到 REPEAT_COOLDOWN_MS。
local function repeatSuppressed(event, playerNum, now)
    if lastEvent[playerNum] ~= event then return false end
    if stillPlaying(playerNum) then return true end
    local at = lastAt[playerNum]
    return finite(at) and now - at < Voice.REPEAT_COOLDOWN_MS
end

-- 回 true＝真的送出播放。event 未知／關閉／音量 0／無玩家或 emitter 都回 false。
function Voice.play(event, playerNum)
    if not EVENTS[event] then return false end
    if not voiceEnabled() then return false end
    local volume = voiceVolume()
    if volume <= 0 then return false end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return false end
    local okEmitter, emitter = pcall(function() return playerObj:getEmitter() end)
    if not okEmitter or emitter == nil then
        warnOnce("emitter", "player emitter unavailable")
        return false
    end
    local now = getTimestampMs()
    if repeatSuppressed(event, playerNum, now) then return false end
    stopPrevious(playerNum)
    local name = Voice.soundName(event)
    local okPlay, ref = pcall(function() return emitter:playSoundImpl(name, nil) end)
    if not okPlay then
        warnOnce("play:" .. name, "playSoundImpl failed for " .. name .. ": " .. tostring(ref))
        return false
    end
    if not finite(ref) or ref == 0 then
        -- GameSounds 查無此名（sound script 沒載）＝回 0（FMODSoundEmitter.java:485-487）
        warnOnce("missing:" .. name, "sound not registered: " .. name)
        return false
    end
    pcall(function() emitter:setVolume(ref, volume) end)
    lastRef[playerNum], lastEmitter[playerNum] = ref, emitter
    lastEvent[playerNum], lastAt[playerNum] = event, now
    if getDebug() then
        print("[" .. MDAD.MOD_ID .. "] voice " .. name .. " vol=" .. tostring(volume))
    end
    return true
end

MDAD.Voice = Voice
