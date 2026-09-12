[h1]🚗 Minidoracat MiniMap - AutoDrive for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]✨ What is this[/h2]
Item-driven vehicle navigation and autodrive: plan routes with a GPS Navigator, then let the Autopilot Module drive along the road network

[h2]Mod map support: read before use[/h2]
[b]Subscribing to a map mod does not guarantee navigation or autodrive support for every road.[/b]
[list]
[*] Added or changed roads need [b]streets.xml[/b], maintained by the map or compatibility-patch author in the current official format, matching the terrain and connecting roads within and beyond the map.
[*] Playability, map images or an existing streets.xml do not prove complete road data. This mod cannot generate roads from images or auto-fix missing, misplaced or disconnected roads.
[*] For map-specific failures, update both mods and check with the map author. Use the road-report link below with the map link, screenshots and text coordinates; no logs needed.
[/list]

[h2]🚀 Quick start[/h2]
[olist]
[*] Get a [b]GPS Navigator[/b] and an [b]Autopilot Module[/b] (loot, or craft with Electrical 3 / 6)
[*] Stand next to your vehicle, [b]right-click the vehicle[/b] → "Install Autopilot Module" (needs a screwdriver, a vehicle battery and Electrical 1). Installing the GPS is optional - it also works from your inventory with a battery
[*] Open the world map and pick a destination to plan a route
[*] Sit in the driver's seat and press [b]Engage Autodrive[/b] on the panel above the dashboard. Touch the controls at any time to take over
[/olist]

[h2]🧰 Features[/h2]
[list]
[*] [b]GPS Navigator[/b]: loot or craft one, then pick a destination on the world map to plan a route along the road network
[*] [b]Autopilot Module[/b]: install it into a vehicle to drive along the planned route automatically and stop on arrival
[*] [b]Multi-target trips[/b]: up to 16 targets; append, insert, prioritize, reorder/preview. New trips auto-continue after stopping; stopovers/step mode wait for Continue driving (old trips stay step-by-step). Road ends short of the target never count as arrival or skip it. Needs MiniMap 0.28.0+ and AutoDrive 0.8.0+; fully restart after updating
[*] [b]Driver HUD[/b]: status, current/next target, speed, cruise cap, gear, slowdown, power/fuel; driving, shared Auto/Step mode and voice controls. Metal/glass/family/side-wing themes; compact/collapsed layouts
[*] [b]Drive timer[/b]: real elapsed time, including waits and recovery. Keeps the last trip after stopping; only a successful new start resets it. Kept in memory for the current game run, not written to the save
[*] [b]Speed gears and brisk MAX mode[/b]: 30 / 50 / 70 km/h use comfort driving. MAX takes corners and clear obstacle gaps faster, with later lift-off; cruise speed remains limited by the vehicle and sandbox settings. Switch directly on the HUD, with no separate style option. Vehicle-condition and collision safety checks still apply
[*] [b]Take over anytime[/b]: steering, throttle or braking switches autodrive off by default; the trip is kept and can resume after stopping. "After manual input" offers 2 / 3 / 5 / 10 s automatic resume with a HUD countdown
[*] [b]U-turn style[/b]: when departing in the opposite direction, "Gentle" slows before turning; "Fast" is optional. Stop autodrive and the vehicle before changing the current stop
[*] [b]Keep right and dodge obstacles[/b]: drives on the right by default, naturally separates oncoming traffic, finds passable gaps around parked vehicles and returns to its lane
[*] [b]Blocked-road recovery and rerouting[/b]: tries another gap and reverses out when stuck; on a fully blocked road it waits and the HUD shows a Reroute button that asks navigation for an alternative route around the blockage (or enable "Reroute automatically when blocked" in the options); only when no route exists does it hand control back with a notice
[*] [b]Voice prompts[/b]: private Chinese/English/Japanese prompts for driving events, next target, stopover and priority; final arrival only at trip completion. Follow game language or pick a pack; HUD volume and on/off controls
[*] [b]Solo auto-pause[/b]: separate settings for failed recovery and stopovers/final arrival (on by default); ordinary auto-continued targets do not pause. After stopping, voice finishes before pause; muted/unavailable voice pauses immediately. New driving intent cancels pending pause. No temporary blockage, manual stop, multiplayer/Host or split-screen triggers. Unpausing never restarts driving; the world runs during voice
[*] [b]Slowdown and soft avoidance[/b]: speed adapts to bends, traffic and unloaded areas. Zombies and corpses share one safe-gap search; without a gap, keep the route and slowdown settings.
[*] [b]Base sensing distance[/b]: 48 / 80 / 120 (default) / 160 / 200 m. Speed, obstacles and corners can request extensions; the effective range is limited by the performance budget and loaded world.
[*] [b]Future trajectory[/b]: translucent blue for the normal route and yellow for committed dodges; toggle it and choose line width in MOD Options or the new MiniMap AutoDrive category
[*] [b]Item availability[/b]: both devices can be crafted or found in world loot, with separate crafting and spawn toggles for GPS and autodrive
[*] [b]Power and fuel costs[/b]: GPS and autodrive each have independent 0–500% power and extra-fuel settings that stack; at 100%, active GPS navigation adds 5% fuel use and autodrive adds 25%
[*] [b]Learn recipes three ways[/b]: read the Electronic Navigation Repair Manual; research a GPS at Electrical 3, or an Autopilot Module for GPS at 3 and itself at 6 (no item consumed); or auto-learn at 6/8. Crafting requires 3/6. Manuals spawn in unlooted electronic, computer-book, library and magazine containers, never backfilling existing loot
[/list]

[h2]⚠️ Requirements[/h2]
[list]
[*] Requires the base mod: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap for B42[/url]
[*] Requires the UI framework: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701]Minidoracat UI Library for B42[/url]
[*] Incompatible with Navigator (both use the area above the vehicle dashboard)
[/list]

[h2]🔗 Mod Series[/h2]
[list]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap for B42[/url] (base mod, required)
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Minidoracat MiniMap Zones[/url]
[/list]

[h2]📋 Mod Info[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatAutoDriveFor42
[*] [b]Workshop ID:[/b] 3792675881
[*] [b]Supported version:[/b] Build 42.20.4+
[*] [b]Singleplayer / Multiplayer:[/b] both supported
[/list]

[h2]💬 Feedback[/h2]
[list]
[*] [url=https://discord.gg/Gur2V67]Discord community[/url]
[*] [url=https://github.com/Minidoracat/MinidoracatAutoDriveFor42/issues/new?template=road-data.yml]Road / route data[/url]: misplaced routes, gaps or detours. Attach [b]a route screenshot showing coordinates + the coordinates as text[/b], and describe the problem. Endpoints, direction and map/version help. [b]No Telemetry required.[/b]
[*] [url=https://github.com/Minidoracat/MinidoracatAutoDriveFor42/issues/new/choose]Vehicle control[/url]: a correct route but the car veers off, gets stuck or slows unexpectedly. Enable diagnostic export; attach the whole Telemetry ZIP. The options' report button copies this link.
[/list]

[h2]☕ Support the author[/h2]
Always free; source on GitHub. Tips fund servers and mod development.
[url=https://ko-fi.com/minidoracat][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_kofi.png[/img][/url] [url=https://github.com/Minidoracat/MinidoracatAutoDriveFor42][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_github.png[/img][/url]

[b]#Minidoracat[/b]
