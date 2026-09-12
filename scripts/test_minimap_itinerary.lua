-- 複用 AutoDrive 的引擎物件殼；再載入真 MiniMap 行程與尋路模組，不模擬六個 API。
-- 從 AutoDrive repo 根執行；MiniMap repo 必須在同層（與真依賴相同）。
-- 可選 arg[1] 指向待驗證的 NavRoute.lua；其餘模組仍載入實際相鄰 repo。
local function read(path)
    local file = assert(io.open(path, "rb"), "missing dependency: " .. path)
    local text = file:read("*a"); file:close(); return text
end
local integration = [[
do
    (function()
        clientFlag, serverFlag = false, false
        MDAD.Drive.stop(0)
        players[0], players[1], players[2], players[3] = dp, nil, nil, nil
        activePlayers = 1
        dp._vehicle, dp._dead, dp._local = dveh, false, true
        dp.getX = function() return dveh._x end
        dp.getY = function() return dveh._y end
        dp.transmitModData = function() end
        dp._modData = {}
        dveh._x, dveh._y, dveh._speed, dveh._steering, dveh._stopped = 0, 0, 0, 0, true
        dveh._engine, dveh._driver, dveh._regulator = true, dp, false
        dveh._part._item._uses = 0.8
        setHeading(dveh, 0)
        driveReset(dveh)
        setSandbox({ NeedItemForNav = false, NeedItemForAutoDrive = false,
            AutoDriveMaxSpeed = 30, RightLaneBias = 0 })
        MDAD.Voice = { play = function() return true end }
        MinidoracatMiniMapAPI = {}
        MinidoracatMiniMapCore = { ready = true,
            getBoolOption = function(_, default) return default end,
            navGateAllows = function(pn, context) return MDAD.navGate(pn, context) end,
        }
        local root = "../MinidoracatMiniMapFor42/MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/"
        local compile = loadstring or load
        local function module(name, suffix)
            local path = name == "MinidoracatMiniMap_NavRoute.lua" and arg[1] or root .. name
            local file = assert(io.open(path, "rb")); local source = file:read("*a"); file:close()
            return assert(compile(source .. (suffix or ""), name))()
        end
        module("MinidoracatMiniMap_Itinerary.lua")
        local engine = module("MinidoracatMiniMap_NavRoute.lua", "\nreturn engine")
        local core, api = MinidoracatMiniMapCore, MinidoracatMiniMapAPI
        local builder = core.NavRouteCore.newBuild({
            { name = "Trip Road", width = 10, surface = "paved", pts = { 0, 0, 100, 0, 200, 0, 300, 0 } },
        }, nil)
        local steps = 0
        while not core.NavRouteCore.step(builder, 900) do
            steps = steps + 1; assert(steps < 1000, "graph must finish")
        end
        engine.graph, engine.state, engine.patchState = builder.graph, "ready", "raw"
        assert(core.navLoadItinerary(0))
        assert(core.navEditItinerary(0, 0, "append", 100, 0, "A"))
        assert(core.navEditItinerary(0, api.getNavItinerary(0).revision, "append", 200, 0, "B"))
        -- SP 開世界地圖會暫停：只派發 EvenPaused，沒有 OnTick 或車輛更新。
        dveh._x = 97 -- 站在第一站的到站半徑內，若誤跑到站更新就會完成。
        assert(api.startNavItinerary(0, api.getNavItinerary(0).revision))
        local pausedRevision = api.getNavItinerary(0).revision
        for _ = 1, 20 do nowMs = nowMs + 100; fire("OnTickEvenPaused") end
        local previewState, previewDone, previewTotal = core.navPreviewState(0)
        assert(previewState == "ok" and previewDone == 2 and previewTotal == 2,
            "paused map computes both legs without an explicit preview toggle")
        local pausedTrip = api.getNavItinerary(0)
        assert(pausedTrip.revision == pausedRevision and pausedTrip.phase == "navigating"
            and pausedTrip.stops[1].status == "pending", "paused preview does not complete a stop")
        assert(not MDAD.Drive.isActive(0), "paused preview never starts vehicle control")
        assert(core.navPauseItinerary(0, "manual"))
        dveh._x = 0
        -- 逐點手動（v7 mode 關）：整段照「每站等玩家」的語意跑，證明新 Core 不會
        -- 自己發車。自動接續在本檔最後一段單獨驗。
        assert(api.setNavContinuation(0, api.getNavItinerary(0).revision, false),
            "v7 exposes the continuation switch")
        local modeOff = api.getNavItinerary(0)
        assert(modeOff.schemaVersion == 2 and modeOff.autoContinue == false,
            "mode off is visible in the real snapshot")
        assert(MDAD.Drive.continueItinerary(0), "real APIs accept explicit start")
        local function pump()
            nowMs = nowMs + 300
            fire("OnTickEvenPaused")
            driveTick(dp, dveh)
            fire("OnTick")
        end
        for _ = 1, 100 do
            if MDAD.Drive.debugSession(0) and MDAD.Drive.debugSession(0).legToken then break end
            pump()
        end
        local session = assert(MDAD.Drive.debugSession(0), "profile preparation creates session")
        assert(session.legToken == api.getNavLeg(0), "driver holds real claim token")
        local token = session.legToken
        assert(core.navEditItinerary(0, api.getNavItinerary(0).revision, "append", 100, 0, "A again"))
        assert(api.getNavLeg(0) == token, "future stop edit preserves executing leg")
        local routeBefore = assert(api.requestRoute(0, 100, 0))
        for _ = 1, 20 do fire("OnTickEvenPaused") end
        local _, previewDone, previewTotal = core.navPreviewState(0)
        assert(previewDone == 3 and previewTotal == 3, "future edit rebuilds the automatic preview")
        assert(api.requestRoute(0, 100, 0) == routeBefore, "real preview does not replace live route")
        dveh._x = 100
        session.mode = "arrive" -- vehicle physics is simulated; arrival/report/advance are real.
        pump()
        assert(not MDAD.Drive.isActive(0), "real arrival ends this drive")
        local it = api.getNavItinerary(0)
        assert(it.phase == "waiting" and it.stops[1].status == "arrived", "real stop completion waits")
        assert(it.stops[2].status == "pending" and api.getNavTarget(0) == nil, "no automatic next target")
        for _ = 1, 4 do pump() end
        assert(not MDAD.Drive.isActive(0), "waiting never auto-starts")
        assert(MDAD.Drive.continueItinerary(0))
        for _ = 1, 100 do
            if MDAD.Drive.debugSession(0) and MDAD.Drive.debugSession(0).legToken then break end
            pump()
        end
        session = assert(MDAD.Drive.debugSession(0))
        assert(session.legToken ~= token, "next stop requires a new claim")
        assert(api.getNavTarget(0) == 200, "explicit next uses station B")
        MDAD.Drive.stop(0)
        it = api.getNavItinerary(0)
        assert(it.phase == "paused" and it.stops[2].status == "pending", "stop releases real claim without arrival")
        assert(not it.claimed and api.getNavLeg(0) == nil, "no orphan claim")
        -- 失敗通知不能在 EvenPaused 搶先把「已到站」改成 paused。
        dveh._x = 197
        assert(api.startNavItinerary(0, it.revision))
        local failureRevision = api.getNavItinerary(0).revision
        engine.state = "failed"
        for _ = 1, 20 do fire("OnTickEvenPaused") end
        it = api.getNavItinerary(0)
        assert(it.revision == failureRevision and it.stops[2].status == "pending",
            "paused computation must not report active-leg failure before arrival")
        fire("OnTick")
        it = api.getNavItinerary(0)
        assert(it.phase == "waiting" and it.stops[2].status == "arrived",
            "normal tick retains arrival-before-route-failure priority")
        -- 自動接續（真 Core、真到站回報）：mode 打開之後，中途站的回報回
        -- disposition=continue，Driver 自己接下一段。沒有「看到 waiting 就發車」的
        -- watcher，只有這條路徑會自動出發。
        local voices = {}
        MDAD.Voice = { play = function(event) voices[#voices + 1] = event return true end }
        engine.state = "ready"
        if core.navInvalidateRoute then core.navInvalidateRoute(0) end
        drive.paused = false
        it = api.getNavItinerary(0)
        assert(api.setNavContinuation(0, it.revision, true), "continuation switch turns back on")
        assert(api.getNavItinerary(0).autoContinue == true, "mode on is visible in the snapshot")
        assert(core.navEditItinerary(0, api.getNavItinerary(0).revision, "append", 300, 0, "D"))
        dveh._x, dveh._speed, dveh._stopped = 197, 0, true
        assert(MDAD.Drive.continueItinerary(0), "explicit start for the automatic leg")
        for _ = 1, 100 do
            if MDAD.Drive.debugSession(0) and MDAD.Drive.debugSession(0).legToken then break end
            pump()
        end
        session = assert(MDAD.Drive.debugSession(0), "automatic leg takes real control")
        assert(api.getNavTarget(0) == 100, "third stop is the live target")
        local midStop = session.legStopId
        assert(midStop == api.getNavItinerary(0).currentStopId,
            "driver records the stop id it is driving to")
        voices = {}
        dveh._x = 100 -- 停在第三站上；到站／回報／續發全部是真的
        session.mode = "arrive"
        pump()
        it = api.getNavItinerary(0)
        assert(it.stops[3].status == "arrived", "mid stop really completed")
        assert(it.phase == "navigating" and api.getNavTarget(0) == 300,
            "continue disposition advances to the next stop with no player input")
        assert(MDAD.Drive.isActive(0), "driver keeps preparing the next leg by itself")
        local function voiceCount(event)
            local n = 0
            for i = 1, #voices do if voices[i] == event then n = n + 1 end end
            return n
        end
        assert(voiceCount("arrive") == 0, "a mid stop never plays the final arrival line")
        assert(not isGamePaused(), "a mid stop never pauses the game")
        for _ = 1, 100 do
            if MDAD.Drive.debugSession(0) and MDAD.Drive.debugSession(0).legToken then break end
            pump()
        end
        session = assert(MDAD.Drive.debugSession(0), "automatic continuation reaches control")
        assert(session.legStopId ~= midStop, "the automatic leg is the next stop, not the reported one")
        assert(voiceCount("leg_next") == 1, "commit plays the continue line exactly once")
        assert(not isGamePaused(), "preparing the next leg never leaves the game paused")
        dveh._x = 300 -- 最後一站：真的抵達才宣告完成
        session.mode = "arrive"
        pump()
        it = api.getNavItinerary(0)
        assert(it.phase == "completed" and it.stops[4].status == "arrived",
            "final stop completes the whole trip")
        assert(not MDAD.Drive.isActive(0), "completed trip stops driving")
        assert(voiceCount("arrive") == 1, "only the real final arrival plays the arrival line")
        -- 真 Core 的同步回呼：不用另一個行程模型證明取消與交接安全。
        local originals = {
            getNavItinerary = api.getNavItinerary, getNavLeg = api.getNavLeg,
            requestRoute = api.requestRoute, claimNavLeg = api.claimNavLeg,
            startNavItinerary = api.startNavItinerary,
        }
        local buildStep = MDADFollower.stepBuild
        local function resetTrip(hold)
            for name, fn in pairs(originals) do api[name] = fn end
            core.navTargetChanged = nil
            MDADFollower.stepBuild = buildStep
            MDAD.Drive.stop(0)
            dp._vehicle, dp._dead, dp._local = dveh, false, true
            dp.getX = function() return dp._vehicle:getX() end
            -- 故障案例留下 orphan 時，仍以真 release 隔離後續案例。
            local abandoned = originals.getNavLeg(0)
            if abandoned and originals.getNavItinerary(0).claimed then
                assert(api.releaseNavLeg(0, MDAD.MOD_ID, abandoned, "cancelled"))
            end
            dp.getY = function() return dp._vehicle:getY() end
            dveh._x, dveh._y, dveh._speed, dveh._stopped, dveh._driver = 0, 0, 0, true, dp
            driveReset(dveh)
            drive.paused = false
            assert(core.navSetTarget(0, 100, 0, "A"))
            assert(core.navEditItinerary(0, api.getNavItinerary(0).revision, "append", 200, 0, "B"))
            if hold then
                local trip = api.getNavItinerary(0)
                assert(core.navEditItinerary(0, trip.revision, "pause", trip.currentStopId, true))
            end
            voices = {}
        end
        local function takeControl()
            assert(MDAD.Drive.continueItinerary(0))
            for _ = 1, 100 do
                local current = MDAD.Drive.debugSession(0)
                if current and current.legToken then return current end
                pump()
            end
            error("real profile did not reach control")
        end
        local function arrive(current)
            dveh._x, dveh._speed, dveh._stopped = 100, 0, true
            current.mode = "arrive"
            nowMs = nowMs + 300
            driveTick(dp, dveh)
        end
        local rejected = 0
        local function scenario(name, fn)
            local ok, err = pcall(fn)
            if not ok then rejected = rejected + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
        end
        for _, entry in ipairs({ "continue", "start" }) do
            scenario("initial API lookup can cancel " .. entry, function()
                resetTrip(false)
                local armed = true
                api.getNavLeg = function(pn)
                    local token, stop, x, y, phase, revision = originals.getNavLeg(pn)
                    if armed then armed = false; MDAD.Drive.stop(0) end
                    return token, stop, x, y, phase, revision
                end
                if entry == "start" then MDAD.Drive.start(dp)
                else MDAD.Drive.continueItinerary(0) end
                assert(not armed, "the first API callback was exercised")
                assert(not MDAD.Drive.isActive(0) and not originals.getNavItinerary(0).claimed,
                    "cancellation during the first lookup must prevent later preparation")
            end)
        end
        scenario("report cannot overwrite a replacement prep", function()
            resetTrip(true)
            local current = takeControl()
            core.navTargetChanged = function()
                core.navTargetChanged = nil
                MDAD.Drive.stop(0)
                api.requestRoute = function() return nil, "pending" end
                assert(MDAD.Drive.continueItinerary(0))
            end
            voices = {}
            arrive(current)
            assert(MDAD.Drive.isActive(0) and not MDAD.Drive.debugSession(0),
                "the replacement prep remains live")
            assert(voiceCount("stopover") == 0 and not MDAD.Drive.isPausePending(),
                "obsolete arrival cannot speak or pause the new prep")
        end)
        scenario("report cannot clear a replacement claimed session", function()
            resetTrip(true)
            local current = takeControl()
            local replacement
            core.navTargetChanged = function()
                core.navTargetChanged = nil
                MDAD.Drive.stop(0)
                replacement = takeControl()
            end
            arrive(current)
            assert(replacement and MDAD.Drive.debugSession(0) == replacement
                and replacement.legToken == api.getNavLeg(0),
                "the new claim must retain its managing session")
        end)
        for _, change in ipairs({ "cancel", "vehicle" }) do
            scenario("automatic handoff acquisition " .. change, function()
                resetTrip(false)
                local current = takeControl()
                local armed = true
                api.getNavLeg = function(pn)
                    local token, stop, x, y, phase, revision = originals.getNavLeg(pn)
                    if armed and phase == "waiting" then
                        armed = false
                        if change == "cancel" then MDAD.Drive.stop(0)
                        else
                            local other = newVehicle({ battery = newItem("Base.CarBattery", { uses = 0.8 }),
                                engineRunning = true, mass = 1200, speed = 0 })
                            other._x, other._y, other._driver, other._stopped = 100, 0, dp, true
                            dp._vehicle = other
                        end
                    end
                    return token, stop, x, y, phase, revision
                end
                arrive(current)
                assert(not armed, "the automatic acquisition callback was exercised")
                assert(not MDAD.Drive.isActive(0) and not originals.getNavItinerary(0).claimed,
                    "the original car's automatic permission cannot survive cancellation or transfer")
            end)
        end
        for _, boundary in ipairs({ "route", "claim" }) do
            scenario("mode off during READY " .. boundary, function()
                resetTrip(false)
                local current = takeControl()
                MDADFollower.stepBuild = function() return false end
                arrive(current)
                MDADFollower.stepBuild = buildStep
                local claimed = 0
                api.claimNavLeg = function(...)
                    claimed = claimed + 1
                    local token, why, detail = originals.claimNavLeg(...)
                    if boundary == "claim" then
                        assert(api.setNavContinuation(0, originals.getNavItinerary(0).revision, false))
                    end
                    return token, why, detail
                end
                if boundary == "route" then
                    api.requestRoute = function(...)
                        local route, state = originals.requestRoute(...)
                        assert(api.setNavContinuation(0, originals.getNavItinerary(0).revision, false))
                        return route, state
                    end
                end
                for _ = 1, 20 do
                    nowMs = nowMs + 300; driveTick(dp, dveh)
                    if not MDAD.Drive.isActive(0) then break end
                end
                assert(not MDAD.Drive.isActive(0) and not originals.getNavItinerary(0).claimed,
                    "mode off before commit cannot leave control or an orphan claim")
                assert(boundary ~= "route" or claimed == 0, "cancelled READY must not claim")
            end)
        end
        scenario("adoption cannot combine a continue snapshot with a priority token", function()
            resetTrip(false)
            dveh._x = 100
            assert(MDAD.Drive.continueItinerary(0))
            fire("OnTick")
            local snapshot = originals.getNavItinerary(0)
            assert(snapshot.activation == "continue", "Core passively activated B")
            local reads = 0
            api.getNavLeg = function(pn)
                reads = reads + 1
                if reads == 2 then
                    assert(core.navEditItinerary(pn, originals.getNavItinerary(pn).revision,
                        "priority", 250, 0, "Priority"))
                end
                return originals.getNavLeg(pn)
            end
            nowMs = nowMs + 300; driveTick(dp, dveh)
            api.getNavLeg = originals.getNavLeg
            assert(not MDAD.Drive.isActive(0) and not originals.getNavItinerary(0).claimed,
                "priority navigation must not inherit the old prep's automatic authority")
        end)
        resetTrip(false)
        assert(rejected == 0, tostring(rejected) .. " real callback scenarios failed")
        -- 停靠／抵達暫停（真 Core＋真 Driver＋真 Voice）：逐點單人自駕停妥之後
        -- 必須把整句語音播完才暫停，而且暫停前後都不自己開下一段。
        -- 上面幾段用的是「不回 ref」的假 Voice，Driver 走的是「查不到播放狀態就
        -- 直接暫停」那條保險，量不到音尾；這裡換成真 Voice ＋ 真 emitter ref 的
        -- queued→playing→ended，才是使用者回報的那條界線。
        local savedVoice, savedLoaded = MDAD.Voice, loaded.MDAD_Voice
        local savedEmitter = dp.getEmitter
        local hud = MDAD.HUD
        local savedHud = { pauseOnArrival = hud.pauseOnArrival, voiceEnabled = hud.voiceEnabled,
            voiceVolume = hud.voiceVolume, voiceLanguage = hud.voiceLanguage }
        local savedPaused, savedPauseCalls, savedPauseVehicle =
            drive.paused, drive.pauseCalls, drive.pauseVehicle
        local savedClient, savedServer, savedActive = clientFlag, serverFlag, activePlayers
        local tickBaseline = #(eventHandlers.OnTickEvenPaused or {})
        assert(not MDAD.Drive.isPausePending(), "前面的案例沒有留下待暫停狀態")
        local emitter = { nextRef = 0, sounds = {} }
        function emitter:playSoundImpl(name)
            self.nextRef = self.nextRef + 1
            self.sounds[self.nextRef] = { name = name, state = "queued" }
            return self.nextRef
        end
        -- 原生 isPlaying 連還沒開始播的 toStart 都算在播，所以 queued 與 playing 同樣是「未播完」。
        function emitter:isPlaying(ref)
            local sound = self.sounds[ref]
            return sound ~= nil and (sound.state == "queued" or sound.state == "playing")
        end
        function emitter:stopSound(ref)
            local sound = self.sounds[ref]
            if sound then sound.state = nil end
        end
        function emitter:setVolume(ref, volume)
            local sound = self.sounds[ref]
            if sound then sound.volume = volume end
        end
        dp.getEmitter = function() return emitter end
        hud.pauseOnArrival = function() return true end -- 使用者本機的既有設定
        hud.voiceEnabled = function() return true end
        hud.voiceVolume = function() return 70 end
        hud.voiceLanguage = function() return "en" end
        MDAD.Voice, loaded.MDAD_Voice = nil, nil
        require "MDAD_Voice"
        local realVoice = MDAD.Voice
        assert(type(realVoice) == "table" and type(realVoice.isPlaying) == "function",
            "真 Voice 模組載入（Driver 只在追得到播放狀態時才等音尾）")
        local function voiceTick(ms)
            nowMs = nowMs + ms
            fire("OnTickEvenPaused")
        end
        local function lastSound()
            return emitter.sounds[emitter.nextRef]
        end
        resetTrip(false)
        assert(api.setNavContinuation(0, api.getNavItinerary(0).revision, false),
            "逐點模式：關掉自動接續")
        assert(api.getNavItinerary(0).autoContinue == false, "逐點模式在真快照裡")
        drive.paused, drive.pauseCalls, drive.pauseVehicle = false, 0, dveh
        local held = takeControl()
        assert(api.getNavTarget(0) == 100, "先開往第一站")
        arrive(held)
        it = api.getNavItinerary(0)
        assert(it.phase == "waiting" and it.stops[1].status == "arrived"
            and it.stops[2].status == "pending", "真到站收站後停在等候")
        assert(not MDAD.Drive.isActive(0) and not dveh._regulator and api.getNavTarget(0) == nil,
            "停妥就交還控制權，沒有下一段目標")
        local stopover = lastSound()
        assert(stopover and stopover.name == realVoice.soundName("stopover"),
            "真 Voice 已把停靠句排進 emitter")
        assert(MDAD.Drive.isPausePending() and drive.pauseCalls == 0 and not isGamePaused(),
            "停靠先等語音，這一刻不暫停")
        voiceTick(150)
        assert(not isGamePaused(), "native ref 還在排隊就暫停＝把語音切掉")
        stopover.state = "playing"
        for _ = 1, 4 do pump() end
        assert(not isGamePaused() and drive.pauseCalls == 0, "語音播放中仍不暫停")
        it = api.getNavItinerary(0)
        assert(not MDAD.Drive.isActive(0) and it.phase == "waiting" and api.getNavTarget(0) == nil,
            "等語音期間不自己開下一段")
        stopover.state = nil
        voiceTick(150)
        assert(isGamePaused() and drive.pauseCalls == 1, "整句播完才暫停，而且只暫停一次")
        assert(not drive.pauseHadSession and not drive.pauseHadRegulator,
            "暫停不復活 session 或定速")
        assert(not MDAD.Drive.isPausePending()
            and #eventHandlers.OnTickEvenPaused == tickBaseline, "播完卸除等待事件")
        it = api.getNavItinerary(0)
        assert(it.phase == "waiting" and it.stops[2].status == "pending"
            and not MDAD.Drive.isActive(0), "暫停之後仍等玩家，下一站不自啟")
        -- 最後一站：玩家自己解除暫停、自己按前往，抵達同樣播完才暫停
        drive.paused, drive.pauseCalls = false, 0
        local final = takeControl()
        assert(api.getNavTarget(0) == 200, "玩家按下前往才開最後一站")
        dveh._x, dveh._speed, dveh._stopped = 200, 0, true
        final.mode = "arrive"
        nowMs = nowMs + 300
        driveTick(dp, dveh)
        it = api.getNavItinerary(0)
        assert(it.phase == "completed" and it.stops[2].status == "arrived",
            "最後一站真的完成整份行程")
        local arriveSound = lastSound()
        assert(arriveSound ~= stopover and arriveSound.name == realVoice.soundName("arrive"),
            "最後一站另播抵達句")
        assert(MDAD.Drive.isPausePending() and drive.pauseCalls == 0 and not isGamePaused(),
            "最後一站同樣先等語音")
        arriveSound.state = "playing"
        voiceTick(200)
        assert(not isGamePaused(), "抵達句播放中不暫停")
        arriveSound.state = nil
        voiceTick(150)
        assert(isGamePaused() and drive.pauseCalls == 1, "抵達句播完才暫停")
        assert(not MDAD.Drive.isPausePending()
            and #eventHandlers.OnTickEvenPaused == tickBaseline, "收尾不留等待事件")
        -- 反面：MP／Host 與本機分割畫面的到站只播本機語音，絕不凍住整個世界
        for _, away in ipairs({ { label = "MP／Host", client = true },
                { label = "本機分割畫面", players = 2 } }) do
            resetTrip(false)
            assert(api.setNavContinuation(0, api.getNavItinerary(0).revision, false))
            drive.paused, drive.pauseCalls = false, 0
            local shared = takeControl()
            local before = emitter.nextRef
            clientFlag, activePlayers = away.client == true, away.players or 1
            arrive(shared)
            clientFlag, activePlayers = false, 1
            local trip = api.getNavItinerary(0)
            assert(trip.stops[1].status == "arrived" and trip.phase == "waiting",
                away.label .. "：到站照樣收站")
            local sound = lastSound()
            assert(emitter.nextRef ~= before and sound.name == realVoice.soundName("stopover"),
                away.label .. "：停靠語音照樣只在本機播")
            assert(not MDAD.Drive.isPausePending() and drive.pauseCalls == 0 and not isGamePaused(),
                away.label .. "：不暫停整個世界")
            assert(#eventHandlers.OnTickEvenPaused == tickBaseline,
                away.label .. "：連等語音的事件都不掛")
            voiceTick(11000)
            assert(drive.pauseCalls == 0 and not isGamePaused(),
                away.label .. "：語音播完也不補暫停")
        end
        -- 反面：純 MiniMap（完全沒有自駕）的到站由 Core 自己收站，沒有人動世界速度
        resetTrip(false)
        assert(api.setNavContinuation(0, api.getNavItinerary(0).revision, false))
        drive.paused, drive.pauseCalls = false, 0
        assert(api.getNavItinerary(0).phase == "navigating" and not api.getNavItinerary(0).claimed,
            "行程是活的，但沒有任何自駕接管")
        dveh._x = 100
        local quietRef = emitter.nextRef
        for _ = 1, 4 do nowMs = nowMs + 300; fire("OnTickEvenPaused"); fire("OnTick") end
        it = api.getNavItinerary(0)
        assert(it.stops[1].status == "arrived" and it.phase == "waiting",
            "沒有自駕時 Core 照樣自己收站")
        assert(not MDAD.Drive.isActive(0), "沒有自駕 session")
        assert(emitter.nextRef == quietRef, "沒有自駕的到站不播自駕語音")
        assert(drive.pauseCalls == 0 and not isGamePaused() and not MDAD.Drive.isPausePending(),
            "純 MiniMap 的到站不強制暫停")
        MDAD.Drive.stop(0)
        MDAD.Voice, loaded.MDAD_Voice = savedVoice, savedLoaded
        dp.getEmitter = savedEmitter
        hud.pauseOnArrival, hud.voiceEnabled = savedHud.pauseOnArrival, savedHud.voiceEnabled
        hud.voiceVolume, hud.voiceLanguage = savedHud.voiceVolume, savedHud.voiceLanguage
        clientFlag, serverFlag, activePlayers = savedClient, savedServer, savedActive
        drive.paused, drive.pauseCalls, drive.pauseVehicle =
            savedPaused, savedPauseCalls, savedPauseVehicle
        assert(not MDAD.Drive.isPausePending()
            and #eventHandlers.OnTickEvenPaused == tickBaseline, "收尾還原事件與待暫停狀態")
        resetTrip(false)
        -- 同目標沿道路移動仍會命中舊近線快取；切回道路必須重新起錨。
        local oldRoad = assert(api.requestRoute(0, 100, 0))
        assert(oldRoad.sx == 0 and oldRoad.sy == 0)
        assert(core.navGuideItinerary(0, api.getNavItinerary(0).revision, "approach"))
        dveh._x = 40
        assert(core.navGuideItinerary(0, api.getNavItinerary(0).revision, "navigating"))
        local freshRoad = assert(api.requestRoute(0, 100, 0))
        assert(math.abs(freshRoad.sx - 40) < 0.001 and freshRoad.sy == 0
            and math.abs(freshRoad.len - 60) < 0.001,
            "切回道路從目前位置重算，而非沿用原本零點起錨的路線")
        pump()
        assert(not MDAD.Drive.isActive(0) and not api.getNavItinerary(0).claimed
            and api.getNavTarget(0) == 100, "模式切換只規劃，不啟動自駕")
        resetTrip(false)
        print("test_minimap_itinerary: PASS (real itinerary, graph, preview, driver, manual stops, automatic continuation and real-voice arrival pause)")
    end)()
end
]]
assert((loadstring or load)(read("scripts/smoke_harness.lua") .. "\n" .. integration, "cross-mod-itinerary"))()
