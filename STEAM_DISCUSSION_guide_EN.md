<!-- Steam discussion source (English); the description only summarizes — this thread is the full reference -->
<!-- 討論串網址：https://steamcommunity.com/workshop/filedetails/discussion/3792675881/586187095760051144/ -->
<!-- 標題：📖 AutoDrive Guide: Features, Road Requirements & Known Issues -->

[b]繁體中文版：[/b][url=https://steamcommunity.com/workshop/filedetails/discussion/3792675881/569297034317714529/]AutoDrive 完整說明：功能、道路需求與已知問題[/url]

[h2]🚀 Quick start[/h2]
[olist]
[*] Get a [b]GPS Navigator[/b] and an [b]Autopilot Module[/b] (loot, or craft with Electrical 3 / 6)
[*] Beside the vehicle, install via [b]right-click or Vehicle Mechanics[/b] (screwdriver, vehicle battery, Electrical 1). The GPS also works from your inventory with a battery
[*] Open the world map and pick a destination
[*] In the driver's seat, press [b]Engage Autodrive[/b] on the panel above the dashboard. Touch the controls anytime to take over
[/olist]
Settings: ESC → MOD Options or MiniMap gear → AutoDrive; server rules are sandbox options.

[h2]🧰 Features in detail[/h2]

[h3]Devices and recipes[/h3]
[list]
[*] [b]Devices[/b]: GPS and Autopilot occupy real part slots on supported vehicles; removal keeps charge and data. A handheld GPS drains its own battery but still adds the GPS fuel cost.
[*] [b]Availability[/b]: loot or craft both, with separate sandbox toggles for crafting and loot spawns. Servers can require a charged GPS to navigate.
[*] [b]Learn recipes three ways[/b]: read one Electronic Navigation Repair Manual (teaches both; found only in unlooted electronic, computer-book, library and magazine containers); research without consuming the item (GPS at Electrical 3 for itself; Autopilot at 3 for the GPS, at 6 for itself); or auto-learn (GPS at 6, Autopilot at 8; multiplayer grants them on login). Crafting needs Electrical 3 / 6.
[/list]

[h3]Where to find them: loot and crafting parts[/h3]
[list]
[*] [b]GPS Navigator[/b]: military electronics storage, electronics stores, engineer tool lockers, warehouse electronics crates
[*] [b]Autopilot Module[/b] (rarer): military electronics storage, the radio factory, electronics store computer sections
[*] [b]Repair manual[/b]: military electronics storage, electronics stores, bookstore/library computer shelves, magazine racks
[/list]
If the server disables loot spawns, crafting is the only way. Parts (plus a screwdriver):
[list]
[*] [b]GPS[/b]: Scrap Electronics ×4, Radio Receiver ×1, Electrical Wire ×1
[*] [b]Autopilot[/b]: GPS Navigator ×1, Scrap Electronics ×6, Scanner Module ×1, Amplifier ×1, Electrical Wire ×2
[*] [b]Scrap Electronics / Wire[/b]: dismantle electronics (radios, TVs, walkie-talkies…); wire is also common in tool containers
[*] [b]Radio Receiver[/b]: dismantle radios, walkie-talkies, manpack or ham radios (higher Electrical = better odds), or loot military electronics storage, the radio factory, engineer lockers, cyber cafés, school labs
[*] [b]Amplifier[/b]: always from dismantling a Speaker; sometimes from radios, walkie-talkies and TVs
[*] [b]Scanner Module[/b]: [b]cannot be dismantled from anything — loot only[/b]; best in military electronics storage and the radio factory, then engineer lockers, cyber cafés, school labs; very rarely from foraging junk
[/list]

[h3]Trips[/h3]
[list]
[*] [b]Multi-target trips[/b]: open from the MiniMap magnifier or [b];[/b]. From search or map right-click: append, insert or go there first. Up to 16 targets; reorder and preview.
[*] [b]Auto / Step[/b]: new trips default to Auto — ordinary targets continue after stopping; stopovers and Step wait for [b]Continue autodrive[/b]. HUD button and trip page share one setting; switching never starts, brakes or retargets.
[*] [b]No skipping[/b]: a road ending short of the target is not arrival and never skips it; you are told to walk there (or skip it in MiniMap).
[*] [b]Editing[/b]: stop autodrive and the vehicle before changing the current stop or adding a priority target; editing later targets is fine mid-drive.
[*] [b]Go home[/b]: swaps the trip for your MiniMap home — drives there on a single-target drive, only retargets while parked; stop first on multi-stop drives.
[/list]

[h3]HUD and voice[/h3]
[list]
[*] [b]Driver HUD[/b]: status, targets, speed, cruise cap, gear, slowdown reason, power/fuel, with direct controls. Metal, glass, family and side-wing themes; compact and collapsed layouts.
[*] [b]Drive timer[/b]: real time incl. waits and recovery; kept until the next successful start, not saved.
[*] [b]Voice prompts[/b]: private Chinese/English/Japanese lines for driving events, next target, stopover and priority; arrival only at trip end. Follow game language or pick a pack; HUD toggle and volume.
[*] [b]Solo auto-pause[/b]: separate options for failed recovery and stopovers/trip end (default on); pauses once stopped and the voice ends. Not for ordinary targets, multiplayer or split-screen; unpausing never restarts driving.
[/list]

[h3]Driving behavior[/h3]
[list]
[*] [b]Speed gears and brisk MAX[/b]: 30 / 50 / 70 km/h drive comfortably; MAX corners and dodges faster with later lift-off, capped by vehicle and sandbox limits; safety checks unchanged.
[*] [b]Take over anytime[/b]: steering, throttle or brake stops autodrive by default; the trip is kept. "After manual input" can resume 2 / 3 / 5 / 10 s after letting go, with a HUD countdown.
[*] [b]U-turn style[/b]: "Gentle" (default) slows before turning; "Fast" swings around with momentum.
[*] [b]Keep right and dodge[/b]: keeps right so oncoming traffic separates (server-adjustable); passes parked vehicles or obstacles through a gap, then returns to its lane.
[*] [b]Recovery and rerouting[/b]: when stuck, tries another gap or reverses after checking behind. On a fully blocked road it waits and the HUD offers [b]Reroute[/b] around the blockage (or enable "Reroute automatically when blocked"). Only with no route does it hand back control.
[*] [b]Slowdown and soft avoidance[/b]: adapts to bends, traffic and unloaded areas. "Avoid zombies and corpses" (default on) finds one shared safe gap; without one it keeps the route and slowdown settings.
[*] [b]Sensing distance[/b]: base 48 / 80 / 120 (default) / 160 / 200 m; extensions are capped by performance budget and loaded world. The HUD slowdown tooltip shows the real range.
[*] [b]Future trajectory[/b]: blue for the route, yellow for committed dodges; toggle and pick Thin / Standard / Thick in MOD Options or MiniMap.
[/list]

[h3]Power and fuel[/h3]
Separate 0–500% power and extra-fuel settings for GPS and autodrive, stacking. At 100%, GPS navigation adds 5% fuel use, autodrive 25%. A running engine still charges the battery on net; engine off, the GPS drains it.

[h3]Server diagnostics[/h3]
Server option, off by default. On problems, a short driving-data clip and a per-drive summary go to the server to improve autodrive; memory only, never written to players' disks. Players can opt out via "Help improve auto-drive".

[h2]🗺️ Mod maps and roads[/h2]
AutoDrive follows MiniMap's navigation network; map images provide no routes. Added or changed roads in a map mod need correct road data from the map or patch author.

[b]Wrong road data:[/b] AutoDrive cannot build roads from images or fix misplaced, missing or disconnected data. Offsets, gaps or bends across grass cause off-road routes, detours, refusal to start or driving problems.

[b]Test scope:[/b] mod-map testing is multiplayer only — not singleplayer certification or a guarantee for every road. On LittleTownshipB42, a local multiplayer check showed routing and AutoDrive activation near Lt Saltamontes Blvd (about X=8279, Y=8503): limited evidence, not full-map or full-trip certification. Test short routes within one map before bends and cross-map links.

[list]
[*] Maps with author road data: [url=https://steamcommunity.com/workshop/filedetails/discussion/3763914102/586187095760050601/]Map Requests & Supported Maps[/url]
[*] Road navigation and author requirements: [url=https://steamcommunity.com/workshop/filedetails/discussion/3763913359/586187095760051259/]MiniMap Guide: Features, Navigation & Road Data[/url]
[/list]

[h2]❓ FAQ[/h2]
[list]
[*] [b]Does stopping autodrive brake?[/b] No — it only hands back the wheel.
[*] [b]Refuses to start?[/b] Sit in the driver's seat with the Autopilot installed and a route planned (charged GPS if required). Vehicles lacking reliable body-size data refuse with a notice.
[*] [b]One map mod fails?[/b] Update all series mods and restart, then check road data with the map author.
[*] [b]Not resumed after loading?[/b] By design, re-entering a save never resumes autodrive.
[/list]

[h2]💬 How to report[/h2]
[list]
[*] [url=https://github.com/Minidoracat/MinidoracatAutoDriveFor42/issues/new?template=road-data.yml]Road / route data[/url]: off-road routes, gaps, detours. Attach [b]a route screenshot with coordinates + coordinates as text[/b]. [b]No Telemetry.[/b]
[*] [url=https://github.com/Minidoracat/MinidoracatAutoDriveFor42/issues/new/choose]Vehicle control[/url]: correct route but the car veers, sticks or slows oddly. Attach Telemetry; "Report a navigation problem (copy link)" in settings copies this link.
[*] [url=https://discord.gg/Gur2V67]Discord[/url]
[/list]
[b]Telemetry:[/b] enable "Export autodrive diagnostic log" (applies from the next drive), reproduce, press "Copy log folder path", zip the whole Telemetry folder and attach only the zip (the path shows your PC account name). Logs hold coordinates, timestamps and your mod list — no account, Steam ID or IP; attachments are public. Over 25 MB: attach session-index.txt, latest.txt, manifest.txt and the last few session logs.
