-- 把兩件自駕道具塞進原版既有的 procedural loot 表。
--
-- OnPostDistributionMerge 是 ItemPickerJava.Parse() 前最後改表時機，但也早於
-- SandboxOptions.load()（IsoWorld.java:1872-1887），此處不能相信 Spawn* 值。
-- 因此兩種權重永遠註冊；真正生成後由 OnFillContainer 讀**已載入**沙盒值，在玩家
-- 看見容器前移除被關閉的類型。已生成容器與既有道具不受影響。
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
        -- merge 時 sandbox 尚未 load；兩件一律進 parser，生成時才做政策過濾。
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

local function filterOneContainer(container, allowGps, allowAuto)
    local items = container:getItems()
    if not items then return end
    for i = items:size() - 1, 0, -1 do
        local item = items:get(i)
        local fullType = item and item:getFullType()
        if (fullType == MDAD.TYPE_GPS and not allowGps)
            or (fullType == MDAD.TYPE_AUTO and not allowAuto) then
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
    if allowGps and allowAuto then return end

    -- 上述壞 event 無法給真正 bag container；正常外層 container 的 event 會在整次
    -- fill 後觸發，利用引擎 recurse API 一併清所有巢狀 InventoryContainer。
    local nested = nil
    if container.getAllEvalRecurse then
        nested = container:getAllEvalRecurse(isInventoryContainer)
    end
    filterOneContainer(container, allowGps, allowAuto)
    if nested then
        for i = 0, nested:size() - 1 do
            local bag = nested:get(i)
            local child = bag and bag:getInventory()
            if child then filterOneContainer(child, allowGps, allowAuto) end
        end
    end
end

Events.OnPostDistributionMerge.Add(injectLoot)
Events.OnFillContainer.Add(filterSpawnedLoot)
