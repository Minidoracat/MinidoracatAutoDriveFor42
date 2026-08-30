-- 把三件自駕道具（GPS、自駕模組、配方手冊）塞進原版既有的 procedural loot 表。
--
-- OnPostDistributionMerge 是 ItemPickerJava.Parse() 前最後改表時機，但也早於
-- SandboxOptions.load()（IsoWorld.java:1872-1887），此處不能相信 Spawn* 值。
-- 因此三種權重永遠註冊；真正生成後由 OnFillContainer 讀**已載入**沙盒值，在玩家
-- 看見容器前移除被關閉的類型（手冊看的是 AllowCraft*，不是 Spawn*）。
-- 已生成容器與既有道具不受影響。
-- 原版沒有 procedural 表 Insert API，只能直接補「型別字串, 權重」pair。
-- 只動既有表的 items，不新增表、不碰房間 procList。

require "MDAD"

local ENTRIES = {
    {
        fullType = MDAD.TYPE_GPS,
        -- 中稀有：軍用電子倉、電器行雜貨、工程工具箱、電子板條箱
        targets = {
            { "ArmyStorageElectronics", 2 },
            { "ElectronicStoreMisc", 2 },
            { "EngineerTools", 1 },
            { "CrateElectronics", 1 },
        },
    },
    {
        fullType = MDAD.TYPE_AUTO,
        -- 稀有：軍用電子倉、無線電工廠零件、電器行電腦區
        targets = {
            { "ArmyStorageElectronics", 0.5 },
            { "RadioFactoryComponents", 0.5 },
            { "ElectronicStoreComputers", 0.2 },
        },
    },
    {
        fullType = MDAD.TYPE_MANUAL,
        -- 手冊：走「書」的通路——書店／圖書館電腦區、混合雜誌架，
        -- 外加兩處本來就會出電子零件的地方，讓找不到成品的玩家仍有學習管道。
        targets = {
            { "ArmyStorageElectronics", 1 },
            { "ElectronicStoreMisc", 2 },
            { "BookstoreComputer", 2 },
            { "LibraryComputer", 1 },
            { "MagazineRackMixed", 0.5 },
        },
    },
}

-- ProceduralDistributions 是 process-global：回主選單換存檔時不保證重建。每輪先刪
-- 自己的 type/weight pair 再重加，避免同一 process 反覆載入把權重越疊越高。
local function removeItem(items, fullType)
    local i = #items - 1
    while i >= 1 do
        if items[i] == fullType then
            table.remove(items, i + 1)
            table.remove(items, i)
        end
        i = i - 2
    end
end

local function injectLoot()
    local list = ProceduralDistributions and ProceduralDistributions.list
    if not list then return end
    for entryIndex = 1, #ENTRIES do
        local entry = ENTRIES[entryIndex]
        for targetIndex = 1, #entry.targets do
            local target = entry.targets[targetIndex]
            local tbl = list[target[1]]
            local items = tbl and tbl.items
            if items then
                removeItem(items, entry.fullType)
                items[#items + 1] = entry.fullType
                items[#items + 1] = target[2]
            end
        end
    end
end

local function isInventoryContainer(item)
    return instanceof(item, "InventoryContainer")
end

local function filterOneContainer(container, allowGps, allowAuto, allowManual)
    local items = container:getItems()
    if not items then return end
    for i = items:size() - 1, 0, -1 do
        local item = items:get(i)
        local fullType = item and item:getFullType()
        if (fullType == MDAD.TYPE_GPS and not allowGps)
            or (fullType == MDAD.TYPE_AUTO and not allowAuto)
            or (fullType == MDAD.TYPE_MANUAL and not allowManual) then
            -- OnFillContainer 尚在生成 call stack 內，直接移除即可；容器稍後才做正常同步。
            container:DoRemoveItem(item)
        end
    end
end

local function filterSpawnedLoot(_, _, container)
    if isClient() or not container then return end
    -- 42.20.4 的 Zombie Bag 一條 vanilla 路徑誤把 ItemPickerContainer 當第三參數
    -- （ItemPickerJava.java:628-633）；method 缺席要安全跳過，不能炸斷整次 loot fill。
    if not container.getItems or not container.DoRemoveItem then return end
    local allowGps = MDAD.sandbox("SpawnGPS", true) == true
    local allowAuto = MDAD.sandbox("SpawnAutopilot", true) == true
    -- 手冊刻意不給自己的沙盒開關：它唯一的價值就是教那兩張配方，兩個製作開關
    -- 都關掉時它是純垃圾，所以任一為 true 就保留。與 Spawn* 分開判斷——
    -- 關掉成品生成不代表要連學習管道一起沒收。
    local allowManual = MDAD.sandbox("AllowCraftGPS", true) == true
        or MDAD.sandbox("AllowCraftAutopilot", true) == true
    if allowGps and allowAuto and allowManual then return end

    -- 上述壞 event 無法給真正 bag container；正常外層 container 的 event 會在整次
    -- fill 後觸發，利用引擎 recurse API 一併清所有巢狀 InventoryContainer。
    local nested = nil
    if container.getAllEvalRecurse then
        nested = container:getAllEvalRecurse(isInventoryContainer)
    end
    filterOneContainer(container, allowGps, allowAuto, allowManual)
    if nested then
        for i = 0, nested:size() - 1 do
            local bag = nested:get(i)
            local child = bag and bag:getInventory()
            if child then filterOneContainer(child, allowGps, allowAuto, allowManual) end
        end
    end
end

Events.OnPostDistributionMerge.Add(injectLoot)
Events.OnFillContainer.Add(filterSpawnedLoot)
