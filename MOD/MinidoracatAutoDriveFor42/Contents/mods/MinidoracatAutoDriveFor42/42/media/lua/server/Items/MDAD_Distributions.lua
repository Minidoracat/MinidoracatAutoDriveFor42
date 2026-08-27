-- 把兩件自駕道具塞進原版既有的 procedural loot 表。
--
-- 掛 OnPostDistributionMerge：IsoWorld.init 依序觸發 OnPreDistributionMerge /
-- OnDistributionMerge / OnPostDistributionMerge，之後才 ItemPickerJava.Parse() 去讀
-- ProceduralDistributions.list，所以這是安全的最後一個改表時機。
-- 原版沒有給 procedural 表用的 InsertItemInDistribution（SuburbsDistributions.lua 的
-- Merge 只合 Distributions 房間表），只能直接往 items 陣列尾端補「型別字串, 權重」。
--
-- 只動既有表的 items，不新增表、不碰房間 procList。

local ENTRIES = {
    -- 中稀有：軍用電子倉、電器行雜貨、工程工具箱、電子板條箱
    ["MinidoracatAutoDrive.GPSNavigator"] = {
        { "ArmyStorageElectronics", 2 },
        { "ElectronicStoreMisc", 2 },
        { "EngineerTools", 1 },
        { "CrateElectronics", 1 },
    },
    -- 稀有：軍用電子倉、無線電工廠零件、電器行電腦區
    ["MinidoracatAutoDrive.AutopilotModule"] = {
        { "ArmyStorageElectronics", 0.5 },
        { "RadioFactoryComponents", 0.5 },
        { "ElectronicStoreComputers", 0.2 },
    },
}

-- 同一個行程內回主選單再載入另一個存檔會再觸發一次事件，而 ProceduralDistributions
-- 是 Lua 全域表、不保證重新初始化。先掃過一遍，已經有同型別就跳過，否則權重會越疊越高。
local function hasItem(items, fullType)
    for i = 1, #items, 2 do
        if items[i] == fullType then
            return true
        end
    end
    return false
end

local function injectLoot()
    local list = ProceduralDistributions and ProceduralDistributions.list
    if not list then
        return
    end
    for fullType, targets in pairs(ENTRIES) do
        for i = 1, #targets do
            local tbl = list[targets[i][1]]
            local items = tbl and tbl.items
            if items and not hasItem(items, fullType) then
                items[#items + 1] = fullType
                items[#items + 1] = targets[i][2]
            end
        end
    end
end

Events.OnPostDistributionMerge.Add(injectLoot)
