-- 配方沙盒閘門。只放 craftRecipe 的 OnTest callback；runtime 命名空間 MDAD 不在這裡。
--
-- 引擎路徑：scripts 的 `OnTest = MDAD_Recipe.canCraftGPS` 由
-- CraftRecipe.OnTestItem(item, character) 觸發，字串經 LuaManager.getFunctionObject
-- 以 "表.函式" 解析全域環境。引擎對每個候選輸入物品都會問一次，全部回 false 就等於
-- 這個配方沒有任何可用材料、無法執行——這是 B42 唯一的官方配方閘門（B41 的
-- OnCanPerform 在 42.20.4 已不存在）。
MDAD_Recipe = MDAD_Recipe or {}

-- 沙盒未載入（主選單、載入中）時一律放行，避免配方在還沒讀到設定前就被誤鎖。
local function allowed(key)
    local sb = SandboxVars and SandboxVars.MinidoracatAutoDrive
    local v = sb and sb[key]
    if v == nil then return true end
    return v == true
end

function MDAD_Recipe.canCraftGPS()
    return allowed("AllowCraftGPS")
end

function MDAD_Recipe.canCraftAutopilot()
    return allowed("AllowCraftAutopilot")
end
