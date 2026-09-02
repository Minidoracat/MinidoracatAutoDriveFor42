--[[
語音模組（client/MDAD_Voice.lua）離線測試：假 PZ 全域驅動真檔。

    lua scripts/test_voice.lua

契約：
- 語言：CH／CN → zh，其餘 → en；sound 名 MDAD_Voice_<event>_<lang>
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
local registered = { MDAD_Voice_start_zh = true, MDAD_Voice_stop_en = true, MDAD_Voice_arrive_zh = true }
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
function require() return true end

MDAD = { MOD_ID = "MinidoracatAutoDriveFor42" }
local hud = { enabled = true, volume = 70, language = "auto" }
MDAD.HUD = {
    voiceEnabled = function() return hud.enabled end,
    voiceVolume = function() return hud.volume end,
    voiceLanguage = function() return hud.language end,
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
languageName = "KO"; checkEq(V.language(), "en", "無語音包的語系退 en")
Translator = nil
checkEq(V.language(), "en", "Translator 缺席退 en")
Translator = { getLanguage = function() return { name = function() return languageName end } end }
languageName = "CH"
-- 選項指定語音包優先；非法值／"auto" 退回跟隨遊戲語言
hud.language = "ja"; checkEq(V.language(), "ja", "選項指定 ja 蓋過 CH")
hud.language = "en"; checkEq(V.language(), "en", "選項指定 en")
hud.language = "fr"; checkEq(V.language(), "zh", "選項非法 pack 名退回跟隨（CH → zh）")
hud.language = 3;    checkEq(V.language(), "zh", "選項非字串退回跟隨")
hud.language = "auto"
checkEq(#V.PACKS, 3, "三個語音包 zh/en/ja")
check(V.PACKS[1] == "zh" and V.PACKS[2] == "en" and V.PACKS[3] == "ja", "PACKS 順序＝下拉順序")
checkEq(V.soundName("start"), "MDAD_Voice_start_zh", "sound 名 = 前綴＋事件＋語言")

-- 正常播放：playSoundImpl＋setVolume
checkEq(V.play("start", 0), true, "已註冊語音播放成功")
checkEq(emitterLog[1], "play:MDAD_Voice_start_zh", "走 playSoundImpl（本機）")
checkEq(emitterLog[2], "vol:101:0.70", "音量 70 → 0.7 套在同一 ref")

-- 新句蓋舊句
checkEq(V.play("arrive", 0), true, "第二句播放")
checkEq(emitterLog[3], "stop:101", "舊句還在播就先停")
checkEq(emitterLog[4], "play:MDAD_Voice_arrive_zh", "再播新句")
playing[102] = nil -- 舊句自然播完
local before = #emitterLog
V.play("start", 0)
check(emitterLog[before + 1] == "play:MDAD_Voice_start_zh", "舊句已結束就不呼叫 stopSound")

-- 未註冊 sound：回 false、只警告一次、不拋
printed = {}
languageName = "EN"
checkEq(V.play("start", 0), false, "未註冊 sound（start_en）回 false")
checkEq(V.play("start", 0), false, "再試仍 false")
checkEq(#printed, 1, "缺 sound 只警告一次")
check(printed[1]:find("MDAD_Voice_start_en", 1, true) ~= nil, "警告點名 sound 名")
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
V.play("start", 0)
check(emitterLog[#emitterLog] == "vol:" .. nextRef .. ":1.00", "音量超界夾到 1.0")
hud.volume = 70
MDAD.HUD = nil
V.play("start", 0)
check(emitterLog[#emitterLog] == "vol:" .. nextRef .. ":0.70", "HUD 缺席退預設 0.7／開啟")
MDAD.HUD = { voiceEnabled = function() return hud.enabled end, voiceVolume = function() return hud.volume end,
    voiceLanguage = function() return hud.language end }

-- 邊界：未知事件、無玩家、emitter 拋錯
checkEq(V.play("dance", 0), false, "未知事件 false")
checkEq(V.play("start", 3), false, "無玩家 false")
players[0].getEmitter = function() error("no emitter") end
printed = {}
checkEq(V.play("start", 0), false, "getEmitter 拋錯 → false 不拋")
checkEq(#printed, 1, "emitter 失敗警告一次")
players[0].getEmitter = function() return emitter end
emitter.playSoundImpl = function() error("fmod down") end
checkEq(V.play("start", 0), false, "playSoundImpl 拋錯 → false 不拋")

print = realPrint
print(string.format("test_voice: %d 項斷言、%d 項失敗", assertions, failures))
if failures > 0 then os.exit(1) end
print("全部通過")
