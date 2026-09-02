--[[
離線重現：路線 → 本 addon 的 MDADFollower.begin 剖面，印 fillet 建構結果。
玩家回報「某段路只能開 18」時的第一刀：18＝obb 警戒帽，常見根因是 fillet 整條
退化讓 band 證明零長（2026-09-02 玩家 telemetry s001-s010）。

    lua scripts/repro_route_profile.lua <session-NNN.log> [dump]
        讀 telemetry route cutover 事件的 src／srcW／srcS（0902m 起匯出）——
        與玩家實機完全同一條路線（含正式服主 MOD 的 road patch）。
    lua scripts/repro_route_profile.lua <sx> <sy> <tx> <ty> [dump]
        用本機 vanilla streets.xml＋主 MOD NavCore 找路（無 road patch、點數可能
        與正式服不同，只供舊 telemetry 或估算）。

車輛參數預設取 telemetry header 的 profile（session 模式），座標模式用 Volvo 244。
本檔在 42/media 之外，可用標準函式庫。
]]

local NAV = "D:/github/MinidoracatMiniMapFor42/MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_NavRoute.lua"
local XML = "D:/SteamLibrary/steamapps/common/ProjectZomboid/media/maps/Muldraugh, KY/streets.xml"
local MEDIA = "MOD/MinidoracatAutoDriveFor42/Contents/mods/MinidoracatAutoDriveFor42/42/media/lua"
local ROOTS = { "", "../" }

local function loadProduction(rel)
    for _, root in ipairs(ROOTS) do
        local path = root .. MEDIA .. "/" .. rel
        local fh = io.open(path, "r")
        if fh then
            fh:close()
            assert(loadfile(path))()
            return
        end
    end
    error("找不到 " .. rel .. "（請從 repo 根目錄或 scripts/ 執行）")
end
loadProduction("shared/MDAD_Dynamics.lua")
loadProduction("shared/MDAD_Follower.lua")

local VOLVO = {
    valid = true, geometryValid = true, halfW = 0.760004997253418, halfL = 2.2300198078155518,
    rMin = 2.7592047832470246, wheelbase = 2.4200098514556885,
    delta0Safe = 0.7199999809265137, deltaVSafe = 0.24000000953674316, maxSpeed = 80,
}

local function split(s, sep)
    local out = {}
    for piece in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = piece end
    return out
end

-- session 模式：最後一個 route cutover 事件的 src 三欄＋header profile
local function routeFromSession(path)
    local fh = assert(io.open(path, "rb"))
    local route, vp
    for line in fh:lines() do
        if line:find('"t":"h"', 1, true) then
            vp = {
                valid = true, geometryValid = true,
                halfW = tonumber(line:match('"halfW":([%d%.eE%-]+)')),
                halfL = tonumber(line:match('"halfL":([%d%.eE%-]+)')),
                rMin = tonumber(line:match('"rMin":([%d%.eE%-]+)')),
                wheelbase = tonumber(line:match('"wheelbase":([%d%.eE%-]+)')),
                delta0Safe = tonumber(line:match('"delta0Safe":([%d%.eE%-]+)')),
                deltaVSafe = tonumber(line:match('"deltaVSafe":([%d%.eE%-]+)')),
                maxSpeed = tonumber(line:match('"maxSpeed":([%d%.eE%-]+)')),
            }
        elseif line:find('"n":"route"', 1, true) and line:find('"src":"', 1, true) then
            local src = line:match('"src":"([^"]*)"')
            local srcW = line:match('"srcW":"([^"]*)"') or ""
            local srcS = line:match('"srcS":"([^"]*)"') or ""
            local pts, widths, surfaces = {}, {}, {}
            for _, p in ipairs(split(src, ";")) do
                local x, y = p:match("^([^,]+),([^,]+)$")
                pts[#pts + 1], pts[#pts + 2] = tonumber(x), tonumber(y)
            end
            for i, w in ipairs(split(srcW, ";")) do widths[i] = tonumber(w) or 8 end
            for i, sf in ipairs(split(srcS, ";")) do surfaces[i] = sf ~= "" and sf or "unknown" end
            route = { pts = pts, segWidth = widths, segSurface = surfaces, len = 0 }
            for i = 2, #pts / 2 do
                local dx, dy = pts[i * 2 - 1] - pts[i * 2 - 3], pts[i * 2] - pts[i * 2 - 2]
                route.len = route.len + math.sqrt(dx * dx + dy * dy)
            end
        end
    end
    fh:close()
    assert(route, "session 無 route cutover src 欄（需 0902m 起的 telemetry）")
    return route, vp or VOLVO
end

-- 座標模式：vanilla streets.xml → 主 MOD NavCore
local function routeFromNav(sx, sy, tx, ty)
    local f = assert(io.open(NAV, "rb"))
    local source = f:read("*a"):gsub("\r\n", "\n")
    f:close()
    local core = assert(source:match("%-%- test:navroute%-core:start\n(.-)\n%-%- test:navroute%-core:end"))
    local NavCore = assert((loadstring or load)(core .. "\nreturn NavCore", "navcore"))()
    local xf = assert(io.open(XML, "rb"))
    local xml = xf:read("*a")
    xf:close()
    local streets = {}
    for attrs, body in xml:gmatch('<street([^>]*)>(.-)</street>') do
        local pts = {}
        for x, y in body:gmatch('<point x="([%d%.%-]+)" y="([%d%.%-]+)"') do
            pts[#pts + 1], pts[#pts + 2] = tonumber(x), tonumber(y)
        end
        if #pts >= 4 then
            streets[#streets + 1] = {
                name = attrs:match('name="([^"]*)"'),
                width = tonumber(attrs:match('width="([%d%.]+)"')), pts = pts,
            }
        end
    end
    local b = NavCore.newBuild(streets, nil)
    while not NavCore.step(b, 100000) do end
    local route, err = NavCore.findRoute(b.graph, sx, sy, tx, ty)
    assert(route, "route NIL: " .. tostring(err))
    return route, VOLVO
end

local route, vp, dump
if tonumber(arg[1]) then
    route, vp = routeFromNav(tonumber(arg[1]), tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4]))
    dump = arg[5] == "dump"
else
    route, vp = routeFromSession(assert(arg[1], "用法見檔頭"))
    dump = arg[2] == "dump"
end
print(("route: len=%.1f pts=%d"):format(route.len, #route.pts / 2))

local prof, perr = MDADFollower.begin(route, vp.maxSpeed, 4, vp)
assert(prof, "begin failed: " .. tostring(perr))
while not MDADFollower.stepBuild(prof, 100000) do end
print(("profile: n=%d filletN=%d filletFallbackN=%d filletReason=%s filletBandValid=%s length=%.1f"):format(
    prof.n, prof.filletN, prof.filletFallbackN, tostring(prof.filletReason),
    tostring(prof.filletBandValid), prof.length))
local minV, minI = math.huge, 1
for i = 1, prof.n do
    if prof.s[i] < prof.length - 10 and prof.v[i] < minV then minV, minI = prof.v[i], i end
end
print(("profile min speed %.1f km/h at s=%.1f (%.1f,%.1f)"):format(
    minV * 3.6, prof.s[minI], prof.x[minI], prof.y[minI]))

if dump then
    local pts = route.pts
    for i = 1, #pts / 2 do
        local seg = ""
        if i > 1 then
            local d = math.sqrt((pts[i * 2 - 1] - pts[i * 2 - 3]) ^ 2 + (pts[i * 2] - pts[i * 2 - 2]) ^ 2)
            seg = string.format("  seg=%.1f w=%s %s", d,
                tostring(route.segWidth[i - 1]), tostring(route.segSurface[i - 1]))
        end
        print(string.format("%3d: %.1f, %.1f%s", i, pts[i * 2 - 1], pts[i * 2], seg))
    end
end
