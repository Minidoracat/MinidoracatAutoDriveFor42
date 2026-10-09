--[[
語音模組（client/MDAD_Voice.lua）離線測試：假 PZ 全域驅動真檔。

    lua scripts/test_voice.lua

契約：
- 語言：CH／CN → zh、JP → ja，KO RU ES(AR/ES_CL/ES_MX) PTBR(PT) TR FR PL DE 各有語音包，其餘 → en；
  聲音：HUD.voiceActor（stacy／yui／classic／stacy_brief／yui_brief，非法退 stacy）；classic 只有 zh／en／ja，其他語言播 en；
  sound 名 MDAD_Voice_<event>_<lang>_<actor>
- 開關／音量每次播放重讀 MDAD.HUD.voiceEnabled／voiceVolume（缺席退 on／0.7）
- 播放走 emitter:playSoundImpl(name, nil)（本機、不送封包）＋ setVolume(ref, v)
- 同玩家新句蓋舊句（isPlaying → stopSound）；ref 0（sound 未註冊）回 false 且只警告一次
- 未知事件／關閉／音量 0／無玩家／emitter 拋錯一律 false、不拋
]]

local MEDIA = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua"
local ROOTS = { "", "../" }

local failures, assertions = 0, 0
local realPrint = print
local function check(ok, label)
    assertions = assertions + 1
    if not ok then
        failures = failures + 1
        realPrint("  FAIL  " .. label)
    end
end
local function checkEq(actual, expected, label)
    check(actual == expected, label .. "（期望 " .. tostring(expected) .. "、實得 " .. tostring(actual) .. "）")
end

-- ---- 假全域 ----
local printed = {}
print = function(msg) printed[#printed + 1] = msg end
function getDebug() return false end
local languageName = "CH"
Translator = { getLanguage = function() return { name = function() return languageName end } end }

local emitterLog = {}
local registered = { MDAD_Voice_start_zh_stacy = true, MDAD_Voice_stop_en_stacy = true, MDAD_Voice_arrive_zh_stacy = true }
local nextRef = 100
local playing = {}
local emitter = {}
function emitter:playSoundImpl(name, parent)
    emitterLog[#emitterLog + 1] = "play:" .. name
    if not registered[name] then return 0 end
    nextRef = nextRef + 1
    playing[nextRef] = true
    return nextRef
end
function emitter:setVolume(ref, volume) emitterLog[#emitterLog + 1] = "vol:" .. ref .. ":" .. string.format("%.2f", volume) end
function emitter:isPlaying(ref) return playing[ref] == true end
function emitter:stopSound(ref) playing[ref] = nil; emitterLog[#emitterLog + 1] = "stop:" .. ref end

local players = { [0] = { getEmitter = function() return emitter end } }
function getSpecificPlayer(pn) return players[pn] end
local clock = 0
function getTimestampMs() return clock end
-- 讓「同事件重播閘」放行：上一句播完＋超過冷卻
local function settle()
    for ref in pairs(playing) do playing[ref] = nil end
    clock = clock + 9000
end
function require() return true end

MDAD = { MOD_ID = "MinidoracatAutoDriveFor42" }
local hud = { enabled = true, volume = 70, language = "auto", actor = nil }
MDAD.HUD = {
    voiceEnabled = function() return hud.enabled end,
    voiceVolume = function() return hud.volume end,
    voiceLanguage = function() return hud.language end,
    voiceActor = function() return hud.actor end,
}

for _, root in ipairs(ROOTS) do
    local fh = io.open(root .. MEDIA .. "/client/MDAD_Voice.lua", "r")
    if fh then fh:close(); dofile(root .. MEDIA .. "/client/MDAD_Voice.lua"); break end
end
local V = MDAD.Voice
check(type(V) == "table" and type(V.play) == "function", "MDAD.Voice 發布")

-- 語言
checkEq(V.language(), "zh", "CH → zh")
languageName = "CN"; checkEq(V.language(), "zh", "CN → zh（同一份國語音檔）")
languageName = "EN"; checkEq(V.language(), "en", "EN → en")
languageName = "JP"; checkEq(V.language(), "ja", "JP → ja")
languageName = "KO"; checkEq(V.language(), "ko", "KO → ko")
languageName = "ES_MX"; checkEq(V.language(), "es", "ES_MX → es（西語變體共用中性西語）")
languageName = "AR"; checkEq(V.language(), "es", "AR → es")
languageName = "PT"; checkEq(V.language(), "pt", "PT → pt（共用巴西葡語）")
languageName = "DE"; checkEq(V.language(), "de", "DE → de")
languageName = "IT"; checkEq(V.language(), "en", "無語音包的語系退 en")
languageName = "UA"; checkEq(V.language(), "en", "UA 不借用 ru，退 en")
Translator = nil
checkEq(V.language(), "en", "Translator 缺席退 en")
Translator = { getLanguage = function() return { name = function() return languageName end } end }
languageName = "CH"
-- 選項指定語音包優先；非法值／"auto" 退回跟隨遊戲語言
hud.language = "ja"; checkEq(V.language(), "ja", "選項指定 ja 蓋過 CH")
hud.language = "en"; checkEq(V.language(), "en", "選項指定 en")
hud.language = "it"; checkEq(V.language(), "zh", "選項非法 pack 名退回跟隨（CH → zh）")
hud.language = 3;    checkEq(V.language(), "zh", "選項非字串退回跟隨")
hud.language = "auto"
checkEq(#V.PACKS, 11, "11 個語音包")
check(V.PACKS[1] == "zh" and V.PACKS[2] == "en" and V.PACKS[3] == "ja" and V.PACKS[4] == "ko"
    and V.PACKS[11] == "de", "PACKS 順序＝下拉順序（新語音包接在尾端，已存的 index 不變）")
checkEq(V.soundName("start"), "MDAD_Voice_start_zh_stacy", "sound 名 = 前綴＋事件＋語言＋聲音（預設 stacy）")
-- 聲音：選項指定優先；缺席／非法值退回第一個（stacy）
check(V.ACTORS[1] == "stacy" and V.ACTORS[2] == "yui" and V.ACTORS[3] == "classic"
    and V.ACTORS[4] == "stacy_brief" and V.ACTORS[5] == "yui_brief" and #V.ACTORS == 5,
    "ACTORS 順序＝下拉順序（新聲音接在尾端，已存的 index 不變）")
hud.actor = "classic"; checkEq(V.soundName("start"), "MDAD_Voice_start_zh_classic", "選經典（舊版語音）")
hud.actor = "yui_brief"; checkEq(V.soundName("detour"), "MDAD_Voice_detour_zh_yui_brief", "選 Yui（簡潔）")
hud.actor = "yui"; checkEq(V.soundName("start"), "MDAD_Voice_start_zh_yui", "選 yui")
hud.language = "ja"; checkEq(V.soundName("arrive"), "MDAD_Voice_arrive_ja_yui", "語言與聲音各自生效")
-- classic 只有 zh／en／ja：其他語言改播英文，其他聲音照選的語言
hud.language = "ko"; checkEq(V.soundName("arrive"), "MDAD_Voice_arrive_ko_yui", "Yui 有韓語")
hud.actor = "stacy_brief"; checkEq(V.soundName("gate"), "MDAD_Voice_gate_ko_stacy_brief", "簡潔聲音也有韓語")
hud.actor = "classic"; checkEq(V.soundName("arrive"), "MDAD_Voice_arrive_en_classic", "classic 沒有韓語，改播英語")
hud.language = "ja"; checkEq(V.soundName("arrive"), "MDAD_Voice_arrive_ja_classic", "classic 仍有日語")
hud.language = "auto"; languageName = "FR"
checkEq(V.soundName("start"), "MDAD_Voice_start_en_classic", "跟隨遊戲語言 FR＋classic → 英語")
hud.actor = "yui"; checkEq(V.soundName("start"), "MDAD_Voice_start_fr_yui", "跟隨遊戲語言 FR＋yui → 法語")
languageName = "CH"
hud.language = "auto"
hud.actor = "lulu"; checkEq(V.actor(), "stacy", "非法聲音名退回 stacy")
hud.actor = 2;      checkEq(V.actor(), "stacy", "非字串退回 stacy")
hud.actor = nil

-- 正常播放：保留 boolean 契約，第二回傳值可追蹤同一句直到自然播完。
do
    local ok, startRef = V.play("start", 0)
    checkEq(ok, true, "已註冊語音播放成功")
    checkEq(startRef, nextRef, "成功播放回傳 emitter 的同一句 ref")
    checkEq(emitterLog[1], "play:MDAD_Voice_start_zh_stacy", "走 playSoundImpl（本機）")
    checkEq(emitterLog[2], "vol:101:0.70", "音量 70 → 0.7 套在同一 ref")
    checkEq(V.isPlaying(0, startRef), true, "送出後同一句仍在播放")

    -- 新句蓋舊句：取代不等於自然結束，不能拿新句的結束當舊句完成。
    local arriveRef
    ok, arriveRef = V.play("arrive", 0)
    checkEq(ok, true, "第二句播放")
    checkEq(emitterLog[3], "stop:101", "舊句還在播就先停")
    checkEq(emitterLog[4], "play:MDAD_Voice_arrive_zh_stacy", "再播新句")
    checkEq(V.isPlaying(0, startRef), nil, "舊句被取代回 nil，不冒充自然結束")
    checkEq(V.isPlaying(0, arriveRef), true, "新句可用自己的 ref 追蹤播放")
    playing[arriveRef] = nil
    checkEq(V.isPlaying(0, arriveRef), false, "同一句自然播完回 false")
    checkEq(V.isPlaying(0, startRef), nil, "新句結束後舊 ref 仍是被取代")
end
local before = #emitterLog
V.play("start", 0)
check(emitterLog[before + 1] == "play:MDAD_Voice_start_zh_stacy", "舊句已結束就不呼叫 stopSound")

-- 同事件重播閘（2026-09-02：受阻煞停 7 秒念 6 次）：還在播不插、冷卻內不念、換事件照蓋
before = #emitterLog
checkEq(V.play("start", 0), false, "同事件、上一句還在播 → 不插播")
checkEq(#emitterLog, before, "被閘住時零 emitter 呼叫")
clock = clock + V.REPEAT_COOLDOWN_MS + 1
checkEq(V.play("start", 0), false, "超過冷卻但上一句仍在播 → 仍不插")
playing[nextRef] = nil
clock = clock + 1
checkEq(V.play("start", 0), true, "播完＋超過冷卻 → 可再念")
checkEq(V.play("start", 0), false, "剛念完同事件立刻再觸發 → 冷卻內不念")
playing[nextRef] = nil
clock = clock + V.REPEAT_COOLDOWN_MS - 1
checkEq(V.play("start", 0), false, "冷卻差 1ms → 仍不念")
checkEq(V.play("arrive", 0), true, "冷卻內換事件 → 照播")
-- 終局通知不得被先前試聽的同句／冷卻吞掉；普通呼叫仍保留上面的重播門檻。
checkEq(V.play("arrive", 0, true), true, "正式抵達通知重新播放，覆蓋尚未播完的試聽")
playing[nextRef] = nil
checkEq(V.play("arrive", 0, true), true, "試聽剛播完仍在冷卻，正式抵達通知照播")
settle()

-- 未註冊 sound：回 false、只警告一次、不拋
printed = {}
languageName = "EN"
settle()
checkEq(V.play("start", 0), false, "未註冊 sound（start_en_stacy）回 false")
checkEq(V.play("start", 0), false, "再試仍 false")
checkEq(#printed, 1, "缺 sound 只警告一次")
check(printed[1]:find("MDAD_Voice_start_en_stacy", 1, true) ~= nil, "警告點名 sound 名")
languageName = "CH"

-- 開關／音量閘門
hud.enabled = false
before = #emitterLog
checkEq(V.play("start", 0), false, "語音關閉不播")
checkEq(#emitterLog, before, "關閉時零 emitter 呼叫")
hud.enabled = true
hud.volume = 0
checkEq(V.play("start", 0), false, "音量 0 不播")
hud.volume = 250
settle()
V.play("start", 0)
check(emitterLog[#emitterLog] == "vol:" .. nextRef .. ":1.00", "音量超界夾到 1.0")
hud.volume = 70
MDAD.HUD = nil
settle()
V.play("start", 0)
check(emitterLog[#emitterLog] == "vol:" .. nextRef .. ":0.70", "HUD 缺席退預設 0.7／開啟")
MDAD.HUD = { voiceEnabled = function() return hud.enabled end, voiceVolume = function() return hud.volume end,
    voiceLanguage = function() return hud.language end, voiceActor = function() return hud.actor end }

-- 播放狀態查詢失敗不可炸掉等待語音的 Driver。
do
    settle()
    local ok, ref = V.play("arrive", 0)
    checkEq(ok, true, "查詢故障情境先成功送出語音")
    local originalIsPlaying = emitter.isPlaying
    emitter.isPlaying = function() error("fmod query failed") end
    local queried, status = pcall(V.isPlaying, 0, ref)
    emitter.isPlaying = originalIsPlaying
    checkEq(queried, true, "emitter 狀態查詢拋錯不外洩到 caller")
    checkEq(status, false, "emitter 狀態查詢失敗回 false")
end

-- 邊界：未知事件、無玩家、emitter 拋錯
checkEq(V.play("dance", 0), false, "未知事件 false")
checkEq(V.play("start", 3), false, "無玩家 false")
players[0].getEmitter = function() error("no emitter") end
printed = {}
checkEq(V.play("start", 0), false, "getEmitter 拋錯 → false 不拋")
checkEq(#printed, 1, "emitter 失敗警告一次")
players[0].getEmitter = function() return emitter end
emitter.playSoundImpl = function() error("fmod down") end
settle()
checkEq(V.play("start", 0), false, "playSoundImpl 拋錯 → false 不拋")

print = realPrint
print(string.format("test_voice: %d 項斷言、%d 項失敗", assertions, failures))
if failures > 0 then os.exit(1) end
print("全部通過")
