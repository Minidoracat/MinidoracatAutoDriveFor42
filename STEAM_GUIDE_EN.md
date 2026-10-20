<!-- 指南網址：https://steamcommunity.com/sharedfiles/filedetails/?id=3817845953 -->
<!-- Steam guide source (English): the full reference for this mod; the Workshop description only summarizes. Format and sync: pz-family-docs/release.md「完整說明：Steam 指南」 -->
<!-- 標題：📖 AutoDrive Mod Guide: Devices, Trips, Driving Behavior & Road Requirements -->
<!-- 摘要：Illustrated guide to the Minidoracat AutoDrive mod: getting the GPS Navigator and Autopilot Module, loot spots and crafting parts, multi-target trips, the driver HUD and voice, driving behavior, power and fuel, and road requirements for mod maps, plus how to report problems. -->
=== 🚀 Quick start
[b]繁體中文版：[/b][url=https://steamcommunity.com/sharedfiles/filedetails/?id=3817845856]自動駕駛 AutoDrive MOD 完整說明[/url]

The mod on Steam Workshop:
https://steamcommunity.com/sharedfiles/filedetails/?id=3792675881
[olist]
[*] [b]Get the devices[/b]: a [b]GPS Navigator[/b] and an [b]Autopilot Module[/b] (loot, or craft with Electrical 3 / 6; see "Where to find them").
[*] [b]Install[/b]: beside the vehicle, via [b]right-click or Vehicle Mechanics[/b] (screwdriver, vehicle battery, Electrical 1). The GPS also works from your inventory with a battery.
[*] [b]Plan a route[/b]: open the world map and pick a destination.
[*] [b]Engage[/b]: in the driver's seat, press [b]Engage Autodrive[/b] on the panel above the dashboard.
[*] [b]Take over[/b]: touch the controls anytime.
[/olist]
{{img:01-autodrive-hud-voice.jpg}}
[list]
[*] [b]Personal settings[/b]: the "Minidoracat Autodrive" page in ESC → Options → Mods, or MiniMap gear → Autodrive (HUD theme, layout, scale and voice volume too).
[*] [b]Server rules[/b]: sandbox options.
[/list]
=== 🧰 Devices and recipes
{{img:05-autodrive-items-en.jpg}}
[h3]Devices[/h3]
[list]
[*] [b]In the vehicle[/b]: GPS and Autopilot occupy real part slots on supported vehicles.
[*] [b]Removal[/b]: keeps charge and data.
[*] [b]Handheld GPS[/b]: drains its own battery but still adds the GPS fuel cost.
[*] [b]Availability[/b]: loot or craft both (see "Where to find them").
[*] [b]Sandbox toggles[/b]: separate ones for crafting and loot spawns.
[/list]
[h3]GPS requirement[/h3]
[list]
[*] [b]Server option[/b]: servers can require a charged GPS to navigate.
[*] [b]Map Watch[/b]: with the [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3816991145]Map Watch[/url] mod installed, a worn, powered Map Watch fitted with a Positioning Module also counts.
[/list]
[h3]Learning the recipes (three ways)[/h3]
[list]
[*] [b]Read the manual[/b]: one Electronic Navigation Repair Manual teaches both.
[*] [b]Where manuals appear[/b]: only in unlooted electronic, computer-book, library and magazine containers.
[*] [b]Research[/b]: doesn't consume the item; levels below.
[*] [b]Auto-learn[/b]: levels below; multiplayer grants them on login.
[/list]
[table]
[tr][th]Method[/th][th]GPS Navigator[/th][th]Autopilot Module[/th][/tr]
[tr][td]Research[/td][td]Electrical 3: its own recipe[/td][td]Electrical 3: the GPS recipe; Electrical 6: its own recipe[/td][/tr]
[tr][td]Auto-learn[/td][td]Electrical 6[/td][td]Electrical 8[/td][/tr]
[tr][td]Crafting[/td][td]Electrical 3[/td][td]Electrical 6[/td][/tr]
[/table]
=== 🧰 Where to find them: loot and crafting parts
<!-- 本章對應戰利品表與配方：改了配方、搜刮生成或零件來源，要同步改這章（繁中稿同章） -->
[h3]Loot spots[/h3]
[table]
[tr][th]Item[/th][th]Where to loot[/th][/tr]
[tr][td]GPS Navigator[/td][td]Military electronics storage, electronics stores, engineer tool lockers, warehouse electronics crates[/td][/tr]
[tr][td]Autopilot Module (rarer)[/td][td]Military electronics storage, the radio factory, electronics store computer sections[/td][/tr]
[tr][td]Repair manual[/td][td]Military electronics storage, electronics stores, bookstore/library computer shelves, magazine racks[/td][/tr]
[/table]
If the server disables loot spawns, crafting is the only way.
[h3]Crafting parts[/h3]
Plus a screwdriver.
[table]
[tr][th]Item[/th][th]Parts[/th][/tr]
[tr][td]GPS Navigator[/td][td]Scrap Electronics ×4, Radio Receiver ×1, Electrical Wire ×1[/td][/tr]
[tr][td]Autopilot Module[/td][td]GPS Navigator ×1, Scrap Electronics ×6, Scanner Module ×1, Amplifier ×1, Electrical Wire ×2[/td][/tr]
[/table]
[h3]Where the parts come from[/h3]
[table]
[tr][th]Part[/th][th]How to get it[/th][/tr]
[tr][td]Scrap Electronics, Electrical Wire[/td][td]Dismantle electronics (radios, TVs, walkie-talkies…); wire is also common in tool containers[/td][/tr]
[tr][td]Radio Receiver[/td][td]Dismantle radios, walkie-talkies, manpack or ham radios (higher Electrical = better odds), or loot military electronics storage, the radio factory, engineer lockers, cyber cafés, school labs[/td][/tr]
[tr][td]Amplifier[/td][td]Always from dismantling a Speaker; sometimes from radios, walkie-talkies and TVs[/td][/tr]
[tr][td]Scanner Module[/td][td][b]Cannot be dismantled from anything; loot only[/b]: best in military electronics storage and the radio factory, then engineer lockers, cyber cafés, school labs; very rarely from foraging junk[/td][/tr]
[/table]
=== 🧰 Multi-target trips
[list]
[*] [b]Open a trip[/b]: from the MiniMap magnifier or [b];[/b].
[*] [b]Add targets[/b]: from search or map right-click: append, insert or go there first.
[*] [b]Limit[/b]: up to 16 targets; reorder and preview.
[/list]
[h3]Auto / Step[/h3]
[list]
[*] [b]Auto[/b] (default for new trips): ordinary targets continue after stopping.
[*] [b]Waits for you[/b]: stopovers and Step wait for [b]Continue autodrive[/b].
[*] [b]Switching[/b]: the HUD button and trip page share one setting; switching never starts, brakes or retargets.
[/list]
[h3]Arrival, no skipping[/h3]
[list]
[*] [b]Road ends short of the target[/b]: not arrival, and it never skips the target; you are told to walk there (or skip it in MiniMap).
[*] [b]Target on the road[/b]: stopping in the lane beside it counts as arrived.
[/list]
[h3]Editing and Go home[/h3]
[list]
[*] [b]Editing[/b]: stop autodrive and the vehicle before changing the current stop or adding a priority target; editing later targets is fine mid-drive.
[*] [b]Go home[/b]: swaps the trip for your MiniMap home.
[list]
[*] Single-target drive: drives there
[*] Parked: only retargets
[*] Multi-stop drive: stop first
[*] No home set: the button is dimmed; pressing it tells you how to set one
[/list]
[/list]
=== 🧰 Driver HUD and voice
[list]
[*] [b]Shows[/b]: status, targets, speed, cruise cap, drive time, time left, gear, slowdown reason, power/fuel.
[*] [b]Controls[/b]: direct controls on the HUD.
[*] [b]Looks[/b]: metal, glass, family and side-wing themes; compact and collapsed layouts.
[/list]
[b]Metal theme[/b]
{{img:07-hud-theme-metal-en.jpg}}
[b]Glass theme[/b]
{{img:08-hud-theme-glass-en.jpg}}
[b]Family theme[/b]
{{img:09-hud-theme-family-en.jpg}}
[b]Side-wing theme[/b]
{{img:02-hud-theme-wings-route.jpg}}
[h3]Stop reason[/h3]
[list]
[*] [b]When it shows[/b]: when autodrive is forced to stop and hand back control, the HUD status keeps showing why (e.g. "Stopped: stuck", "Stopped: animal", "Stopped: device") until the next start.
[*] [b]Causes[/b]: stuck, blocked by another player or an animal for too long, area not loading, route lost, too far off the road, trailer can't make a turn or went out of sync, engine off, GPS, Map Watch Positioning Module or Autopilot failure.
[*] [b]Details[/b]: hover the status or the start button for the full reason and how many minutes ago.
[*] [b]Not shown for[/b]: your own stop, manual takeover, leaving the vehicle or arrival.
[*] [b]Other vehicles[/b]: hidden in another vehicle, shown again back in the original one.
[/list]
[h3]Drive timer and time left[/h3]
[list]
[*] [b]Drive timer[/b]: real time, including waits and recovery.
[*] [b]Reset[/b]: kept until the next successful start; not saved.
[*] [b]Time left[/b]: while autodriving, about how many minutes are left to the destination (the next target on a trip), in real time; the last minute reads "< 1 min".
[*] [b]Distance left[/b]: hover it for the distance left along the route (in metres under 1 km).
[*] [b]Estimate[/b]: starts from the route's bends and your cruise limit and adjusts to how fast this trip actually goes; waits, detours and reroutes recalculate it.
[*] [b]Can run slower[/b]: stretches with many zombies to dodge.
[*] [b]Compact layout[/b]: the first column to give way when space runs out.
[/list]
[h3]Voice prompts[/h3]
[list]
[*] [b]What it says[/b]: private lines for driving events, next target, stopover and priority; arrival only at trip end.
[*] [b]Voices[/b]:
[list]
[*] Stacy (sweet, default) or Yui (gentle), in a sweet girlfriend tone
[*] The same two voices with short, casual lines like a friend
[*] Classic (the original voice)
[/list]
[*] [b]Languages[/b]: Chinese, English, Japanese, Korean, Russian, Spanish, Portuguese (Brazil), Turkish, French, Polish and German; follow the game language or pick one.
[*] [b]Classic[/b]: only speaks Chinese, English and Japanese, and uses English otherwise.
[*] [b]On the HUD[/b]: toggle and volume.
[/list]
[h3]Solo auto-pause[/h3]
[list]
[*] [b]Two options[/b]: after failed recovery, and at stopovers/trip end (default on).
[*] [b]When[/b]: pauses once stopped and the voice ends.
[*] [b]Road end[/b]: reaching a road end that leaves you to walk also pauses under the stopover option (no voice).
[*] [b]Never pauses[/b]: ordinary targets, multiplayer or split-screen.
[*] [b]After unpausing[/b]: driving never restarts on its own.
[/list]
=== 🧰 Speed, takeover and sensing
[h3]Speed gears and brisk MAX[/h3]
[list]
[*] [b]30 / 50 / 70 km/h[/b]: drive comfortably.
[*] [b]MAX[/b]: corners and dodges faster with later lift-off, capped by vehicle and sandbox limits.
[*] [b]Safety[/b]: safety checks are unchanged.
[/list]
[h3]Take over anytime[/h3]
[list]
[*] [b]Default[/b]: steering, throttle or brake stops autodrive; the trip is kept.
[*] [b]Auto-resume[/b]: "After manual input" can resume 2 / 3 / 5 / 10 s after letting go, with a HUD countdown.
[*] [b]Tip[/b]: on the default, if you restart to the same destination right after taking over, a one-time tip suggests auto-resume (at most once per game session).
[*] [b]No tip when[/b]: you took over right after the car was blocked, backed out of a jam or braked hard, or it was nearly at the destination.
[*] [b]Far off the route[/b]: if you have driven far off the route by then, autodrive simply ends (like a manual stop) and keeps the navigation target.
[/list]
[h3]U-turn style[/h3]
[list]
[*] [b]Gentle[/b] (default): slows before turning.
[*] [b]Fast[/b]: swings around with momentum.
[*] [b]Starting at an angle[/b]: if the car faces more than about 60° away from the route when autodrive starts, it turns in place first, then drives off (not when towing); if it ends up parallel to the road and still far from it, it heads back to the road on a diagonal.
[*] [b]No room to turn[/b]: if it is too tight to turn in place, it backs up a little first and keeps backing up in short steps if needed (up to three); only if it still can't make room does it make a slow wide turn. The status shows "Turning in place" or "Tight spot: slow turn" meanwhile.
[/list]
[h3]Sensing distance[/h3]
[list]
[*] [b]Base[/b]: 48 / 80 / 120 (default) / 160 / 200 m.
[*] [b]Extensions[/b]: capped by performance budget and the loaded world.
[*] [b]Real range[/b]: shown in the HUD slowdown tooltip.
[/list]
[h3]Future trajectory[/h3]
{{img:06-autodrive-route-intersection-en.jpg}}
[list]
[*] [b]Colors[/b]: blue for the route, yellow for committed dodges.
[*] [b]Settings[/b]: toggle it and pick Thin / Standard / Thick in MOD Options or MiniMap.
[/list]
=== 🧰 Dodging, recovery and avoidance
[h3]Keep right and dodge[/h3]
[list]
[*] [b]Keep right[/b]: so oncoming traffic separates (server-adjustable).
[*] [b]Far-away traffic[/b] (multiplayer): the server relays driven vehicles within about 300 tiles, so oncoming cars are seen beyond the game's sync range ("Share far-away traffic with auto-drive", on by default).
[*] [b]Obstacles[/b]: passes parked vehicles or obstacles through a gap, then returns to its lane; if its lane is blocked again right after and the dodge line ahead is clear, it stays on the dodge line until its lane is free.
[*] [b]Fences[/b]: broken fence planks, burnt fence debris and stumps that the game itself lets cars through are driven over; fences that actually stop a car are still avoided.
[/list]
[h3]Recovery and rerouting[/h3]
[list]
[*] [b]When stuck[/b]: tries another gap, or reverses after checking behind.
[*] [b]Whole road blocked, shoulders included[/b]: stops, scans wider and goes around across grass or open ground, driving straight over bushes.
[*] [b]When towing[/b]: avoids bushes and also checks the trailer's path.
[*] [b]Reversing with a trailer[/b]: steers while backing up to keep the trailer in line; it won't reverse once the trailer is already folded too far.
[*] [b]Automatic reroute[/b]: otherwise it asks navigation for a route around the blockage; later reroutes on the same trip also avoid earlier blockages ("Reroute automatically when blocked", on by default).
[*] [b]Manual reroute[/b]: the HUD [b]Reroute[/b] button works any time.
[*] [b]Hand back[/b]: only with no route.
[*] [b]Turns a trailer can't make[/b]: when towing, the same option makes it take a route around such a turn right at the start instead of stopping before it; with no alternative it still stops before the turn.
[/list]
[h3]Edge sideways when boxed in (experimental)[/h3]
[list]
[*] [b]Turn it on[/b]: off by default; in MOD Options or MiniMap settings.
[*] [b]What it does[/b]: when blocked both ahead and behind and unable to back up, it first eases sideways toward whichever side has room, then backs out.
[*] [b]No room[/b]: if neither side has room or the vehicle won't move, it holds, reroutes or hands back control as usual.
[*] [b]Not used[/b]: when towing or during a U-turn.
[/list]
[h3]Re-hitching a trailer that drops out of sync (multiplayer)[/h3]
[list]
[*] [b]What happens[/b]: in multiplayer the trailer sometimes vanishes from your screen because of a sync glitch, while on the server it is still there and still hitched.
[*] [b]Re-hitch[/b]: autodrive stops, waits for the trailer to reappear, backs up until it hitches again, then continues along the route; the status shows "Awaiting trailer: N s", "Trailer found", "Backing to trailer" and "Re-hitching" in turn, with a voice line. Towing another car works the same way.
[*] [b]When it hands back instead[/b]: semi-trailers, or when the trailer doesn't come back in time, the car can't line up, or something is behind it. The status shows "Trailer out of sync"; back up next to the trailer yourself and it hitches again once it reappears, then start autodrive again.
[/list]
[h3]Zombies, corpses and other players[/h3]
[list]
[*] [b]Slowdown[/b]: adapts to bends, traffic and unloaded areas.
[*] [b]Avoid zombies and corpses[/b] (default on): finds one shared safe gap; without one it keeps the route and slowdown settings. When going around an obstacle it also avoids the side where zombies are standing.
[*] [b]Other players[/b] (multiplayer): steers around players walking on the road; with no room it stops and waits for them to move.
[*] [b]If they stay[/b]: hands back control after too long; it never pushes through.
[/list]
[h3]Avoid animals (player option)[/h3]
[list]
[*] [b]Where[/b]: "Avoid animals" in MOD Options or MiniMap settings.
[*] [b]Levels[/b]: Off / Large animals (default) / All animals; selected animals are dodged at the current speed through a gap beside them.
[*] [b]HUD Animals button[/b]: switches between Off and the level you last used.
[*] [b]Large[/b]: deer, sheep, pigs, cows and the like, plus grown-up young.
[*] [b]Small[/b]: chickens, rabbits and turkeys.
[/list]
[h3]Animal slowdown (server)[/h3]
Sandbox option "Animal slowdown": Off / Large animals / All animals, default Large. Selected animals are protected:
[list]
[*] [b]Not covered by "Avoid animals"[/b]: slows down and steers around gently.
[*] [b]Road truly blocked[/b]: stops and waits.
[*] [b]Long wait[/b]: creeps past at walking speed (no vehicle damage, but the animal can still be hurt).
[*] [b]Animal never moves[/b]: hands back control.
[/list]
Animals selected by neither are ignored.
=== ⚙️ Settings, power & fuel, server diagnostics
[h3]Settings screens[/h3]
The "Autodrive" category in MiniMap's Map Display Settings:
{{img:04-minimap-autodrive-settings.jpg}}
The "Minidoracat AutoDrive" sandbox page:
{{img:03-autodrive-sandbox-settings-en.jpg}}
[h3]Power and fuel[/h3]
Separate 0–500% power and extra-fuel settings for GPS and autodrive (default 50%); they stack.
[table]
[tr][th]Device[/th][th]Extra fuel at the default 50%[/th][th]At 100%[/th][/tr]
[tr][td]GPS (navigating)[/td][td]2.5%[/td][td]5%[/td][/tr]
[tr][td]Autodrive[/td][td]12.5%[/td][td]25%[/td][/tr]
[tr][td]Both together[/td][td]15% total[/td][td]30% total[/td][/tr]
[/table]
[list]
[*] [b]Bends and detours cost no extra fuel[/b]: autodrive fuel is counted in the gear you would use at that speed, so slowing for bends or obstacles burns no more than driving yourself.
[*] [b]Engine running[/b]: still charges the battery on net.
[*] [b]Engine off[/b]: the GPS drains the battery.
[/list]
[h3]Server diagnostics[/h3]
[list]
[*] [b]Option[/b]: server option, off by default.
[*] [b]What is sent[/b]: on problems, a short driving-data clip and a per-drive summary go to the server to improve autodrive.
[*] [b]Storage[/b]: memory only, never written to players' disks.
[*] [b]Opt out[/b]: players can untick "Help improve auto-drive (share diagnostics with this server)".
[/list]
=== ⚠️ Mod maps and roads
[list]
[*] [b]Road network[/b]: AutoDrive follows MiniMap's navigation network; map images provide no routes.
[*] [b]Added or changed roads[/b]: need correct road data from the map or patch author.
[/list]
[h3]Wrong road data[/h3]
[list]
[*] AutoDrive cannot build roads from images or fix misplaced, missing or disconnected data.
[*] Offsets, gaps or bends across grass cause off-road routes, detours, refusal to start or driving problems.
[/list]
[h3]Test scope[/h3]
[list]
[*] [b]Multiplayer only[/b]: mod-map testing is multiplayer only; it is not singleplayer certification or a guarantee for every road.
[*] [b]LittleTownshipB42[/b]: a local multiplayer check showed routing and AutoDrive activation near Lt Saltamontes Blvd (about X=8279, Y=8503); limited evidence, not full-map or full-trip certification.
[*] [b]Testing a new map[/b]: test short routes within one map before bends and cross-map links.
[/list]
[h3]More[/h3]
[list]
[*] [b]Maps with author road data[/b]: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3817840392]MOD Maps supported map list[/url]
[*] [b]Road navigation and author requirements[/b]: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3817841972]MiniMap Guide: Features, Navigation & Road Data[/url]
[/list]
=== ❓ FAQ
[h3]Does stopping autodrive brake?[/h3]
[list]
[*] No. It only hands back the wheel.
[/list]
[h3]Why is it slow or uneven?[/h3]
[list]
[*] Click CRUISE LIMIT on the HUD to open Speed info; "Main reason" shows what is holding speed down.
[*] [b]Common causes[/b]:
[list]
[*] The car is already at its own top speed: "Main reason" says "already at the vehicle's top speed", and changing gear will not make it faster; use a faster vehicle
[*] 30/50/70 corner more gently than MAX; use MAX for speed
[*] It only drives as fast as it can stop within road it has already checked, so at very low FPS it checks less and the HUD shows "Low FPS: slower" (raise FPS)
[*] Towing corners slower: it slows early when the trailer is about to cut into something on the inside of a turn, and crawls past if the trailer touches it
[*] Turn off the HUD Zombies / Corpses buttons to stop slowing for them (it drives through if it can't dodge)
[/list]
[/list]
[h3]Refuses to start?[/h3]
[list]
[*] Sit in the driver's seat with the Autopilot installed and a route planned (charged GPS if required).
[*] Vehicles lacking reliable body-size data refuse with a notice.
[/list]
[h3]Motorcycles or bicycles?[/h3]
[list]
[*] The base game has neither.
[*] [b]Motorcycle mods[/b]: can autodrive (tested with the Autotsar Motor Club Harley and BMW); gap checks use the rider-plus-handlebar width.
[*] [b]Bicycles[/b]: no engine or battery, so they cannot autodrive.
[/list]
[h3]Tow-assist mods?[/h3]
[list]
[*] Compatible. Mods like Ultimate Towing and Effortless Towing keep pushing the car while it tows, but the game takes only one push per vehicle at a time, and AutoDrive steers with that push. With both pushing, AutoDrive can't steer; the car then swerves, surges and the trailer breaks loose.
[*] So while AutoDrive is driving, other mods' pushes on that vehicle are skipped; once you take over or stop AutoDrive, the tow assist works as usual.
[*] While AutoDrive tows, you don't get that extra push; AutoDrive's own acceleration assist takes over.
[*] [b]Limit[/b]: only mods that push from Lua can be blocked (both of the above currently do). If a mod ever moves its push into Java (for example through ZombieBuddy), AutoDrive can't block it and will again fail to steer while towing.
[*] If the steering doesn't respond under AutoDrive, report it with Telemetry (see "Feedback").
[/list]
[h3]One map mod fails?[/h3]
[list]
[*] Update all series mods and restart, then check road data with the map author.
[*] Still failing? Use the road report form under "Feedback".
[/list]
[h3]Not resumed after loading?[/h3]
[list]
[*] By design, re-entering a save never resumes autodrive.
[/list]
=== 💬 Feedback
[list]
[*] [b][url=https://github.com/Minidoracat/MinidoracatAutoDriveFor42/issues/new?template=road-data.yml]Road / route data[/url][/b]: off-road routes, gaps, detours.
[list]
[*] Attach [b]a route screenshot with coordinates + coordinates as text[/b]
[*] [b]No Telemetry[/b]
[/list]
[*] [b][url=https://github.com/Minidoracat/MinidoracatAutoDriveFor42/issues/new/choose]Vehicle control[/url][/b]: correct route but the car veers, sticks or slows oddly.
[list]
[*] Attach Telemetry (steps below)
[*] "Report a navigation problem (copy link)" in settings copies this link
[/list]
[*] [b][url=https://discord.gg/Gur2V67]Discord[/url][/b]
[/list]
[h3]Telemetry[/h3]
[olist]
[*] On the "Minidoracat Autodrive" page in ESC → Options → Mods (or MiniMap gear → Autodrive), enable "Export autodrive diagnostic log" (off by default; applies from the next drive)
[*] Reproduce the problem
[*] Press "Export diagnostics (one file)" on the same page: the file path is copied to your clipboard. Attach that .txt only; don't paste the path (it shows your PC account name)
[/olist]
[list]
[*] [b]Older drives[/b]: press "Copy log folder path" and zip the whole Telemetry folder instead.
[*] [b]Before a screenshot[/b]: turn on "Show diagnostic line" (off by default) on the same page to show the speed-limit reason, speeds and AutoDrive state above the HUD.
[*] [b]What logs hold[/b]: coordinates, timestamps and your mod list; no account, Steam ID or IP.
[*] [b]Public[/b]: attachments are public.
[*] [b]Over 25 MB[/b]: attach session-index.txt, latest.txt, manifest.txt and the last few session logs.
[/list]
