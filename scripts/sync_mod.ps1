# ============================================================
# Minidoracat PZ MOD 家族 — MOD 實體同步引擎（正本：D:/github/pz-family-docs/scripts/sync_mod.ps1）
#
# PZ 對目錄連結的搜尋基準與遍歷路徑不一致，可能誤記 MOD 來源；實體副本避免此缺陷。
#
# 這個檔只定義函式：可安全 dot-source，載入時不寫入任何檔案、不 exit、不 Read-Host。
#
# 公開 API（唯一回傳值都是單一 [bool]，其餘訊息一律 Write-Host，失敗回 $false 不 throw）：
#   Invoke-PZModSync -ProjectRoot <repo> -ZomboidDir <profile> [-ServerIniPath <ini>] [-CheckOnly] [-ForceVerify]
#   Remove-PZModSync -ProjectRoot <repo> -ZomboidDir <profile>
#
# 同步目的地（只有這兩個，且只在 <ZomboidDir> 內）：
#   <ZomboidDir>\Workshop\<MOD_FOLDER>  <-  <repo>\MOD\<MOD_FOLDER>
#   <ZomboidDir>\mods\<MOD_ID>          <-  <repo>\MOD\<MOD_FOLDER>\Contents\mods\<MOD_FOLDER>
#
# 所有權與備份狀態（不進 MOD 樹、不在遊戲掃描區）：
#   <ZomboidDir>\MinidoracatDevSync\ownership.json   受管副本清單（dest -> source）
#   <ZomboidDir>\MinidoracatDevSync\sync.lock        獨佔鎖（FileShare::None）
#   <ZomboidDir>\MinidoracatDevSync\backups\<stamp>  舊 link／未受管實體的歸檔（只搬不刪）
#   <ZomboidDir>\MinidoracatDevSync\hashcache.json   雜湊快取（只省重算，不參與安全／刪除決策）
#
# 量測：每次 Invoke-PZModSync 印一行「量測：...」並把數字放進 $script:PZSyncLastMetrics（不進 pipeline）。
# ============================================================

# ------------------------------------------------------------
# 訊息（全部 Write-Host，不進 pipeline）
# ------------------------------------------------------------
function Write-PZSyncInfo { param([string]$Message) Write-Host "  [同步] $Message" -ForegroundColor DarkGray }
function Write-PZSyncNote { param([string]$Message) Write-Host "  [同步] $Message" -ForegroundColor Cyan }
function Write-PZSyncOk   { param([string]$Message) Write-Host "  [同步] $Message" -ForegroundColor Green }
function Write-PZSyncWarn { param([string]$Message) Write-Host "  [同步] $Message" -ForegroundColor Yellow }
function Write-PZSyncFail { param([string]$Message) Write-Host "  [同步] $Message" -ForegroundColor Red }

# 來源側排除：AI 工具狀態與 git 中繼資料絕不進副本（來源本身不動）
function Get-PZSyncExcludedNames { return @('.git', '.omc', '.claude', '.gitnexus') }

# 家族 id（可在本機以實體副本掛載）；其餘視為第三方，只提示不複製
function Test-PZSyncFamilyId {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    return ($Id -like 'Minidoracat*' -or $Id -like 'Cat*For42')
}

# ------------------------------------------------------------
# 路徑工具
# ------------------------------------------------------------
function Test-PZSyncPathExists {
    param([string]$Path)
    try { [void][IO.File]::GetAttributes($Path); return $true }
    catch [IO.FileNotFoundException] { return $false }
    catch [IO.DirectoryNotFoundException] { return $false }
}

function Assert-PZSyncPhysicalPath {
    param([string]$Path)
    $part = [IO.Path]::GetFullPath($Path)
    while ($part) {
        if ((Test-PZSyncPathExists $part) -and (Test-PZSyncReparsePoint $part)) {
            throw "目的地或狀態路徑經過目錄連結，拒絕寫入：$part"
        }
        $part = [IO.Path]::GetDirectoryName($part.TrimEnd('\'))
    }
}

function Get-PZSyncLinkTarget {
    param([string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not (Test-PZSyncReparsePoint $Path)) { return $null }
        $target = @($item.Target)[0]
        if ([string]::IsNullOrWhiteSpace($target)) { throw "無法解析連結目標：$Path" }
        if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path -Parent $Path) $target }
        return [IO.Path]::GetFullPath($target).TrimEnd('\')
    } catch { throw }
}

function Test-PZSyncReparsePoint {
    param([string]$Path)
    $attr = [IO.File]::GetAttributes($Path)
    return (($attr -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint)
}

# 逐層解析路徑上的 reparse point（祖先被重導也要看得出來）；解不開或成環回 $null
function Resolve-PZSyncFullPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $null }
    for ($hop = 0; $hop -lt 16; $hop++) {
        $root = [IO.Path]::GetPathRoot($full)
        if ([string]::IsNullOrWhiteSpace($root)) { return $null }
        $rest = $full.Substring($root.Length).Trim('\')
        $prefix = $root.TrimEnd('\')
        $redirected = $false
        if ($rest) {
            foreach ($seg in $rest.Split('\')) {
                $prefix = "$prefix\$seg"
                if (-not (Test-PZSyncPathExists $prefix)) { continue }
                $target = Get-PZSyncLinkTarget $prefix
                if ($target) {
                    if (-not [IO.Path]::IsPathRooted($target)) {
                        $target = [IO.Path]::Combine((Split-Path -Parent $prefix), $target)
                    }
                    $tail = $full.Substring($prefix.Length)
                    try { $full = [IO.Path]::GetFullPath(($target.TrimEnd('\') + $tail)).TrimEnd('\') } catch { return $null }
                    $redirected = $true
                    break
                }
            }
        }
        if (-not $redirected) { return $full }
    }
    return $null
}

function Test-PZSyncPathUnder {
    param([string]$Child, [string]$Parent)
    if ([string]::IsNullOrWhiteSpace($Child) -or [string]::IsNullOrWhiteSpace($Parent)) { return $false }
    $c = $Child.TrimEnd('\')
    $p = $Parent.TrimEnd('\')
    if ($c -ieq $p) { return $true }
    return $c.StartsWith(($p + '\'), [StringComparison]::OrdinalIgnoreCase)
}

# ------------------------------------------------------------
# MOD 識別（零設定：從 MOD\<f>\Contents\mods\<f>\42\mod.info 讀 id／require）
# ------------------------------------------------------------
function Get-PZSyncModInfoId {
    param([string]$InfoPath)
    try {
        foreach ($line in [IO.File]::ReadAllLines($InfoPath)) {
            if ($line -match '^\s*id\s*=(.*)$') {
                $id = $Matches[1].Trim()
                if ($id) { return $id }
            }
        }
    } catch { return $null }
    return $null
}

function Get-PZSyncRepoMod {
    param([string]$RepoRoot)
    try {
        if ([string]::IsNullOrWhiteSpace($RepoRoot)) { Write-PZSyncFail "repo 路徑為空"; return $null }
        $root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\')
        if (-not [IO.Directory]::Exists($root)) { Write-PZSyncFail "找不到 repo 目錄：$root"; return $null }
        $modRoot = Join-Path $root 'MOD'
        if (-not [IO.Directory]::Exists($modRoot)) { Write-PZSyncFail "找不到 MOD 目錄：$modRoot"; return $null }

        $infos = @(Get-ChildItem -Path (Join-Path $modRoot '*\Contents\mods\*\42\mod.info') -File -Force -ErrorAction SilentlyContinue)
        if ($infos.Count -ne 1) {
            Write-PZSyncFail "$root 下符合 MOD\<f>\Contents\mods\<f>\42\mod.info 的 mod.info 有 $($infos.Count) 個（需恰好 1 個），無法判定同步來源"
            return $null
        }

        $infoPath = $infos[0].FullName
        $modContent = Split-Path -Parent (Split-Path -Parent $infoPath)                                   # ...\Contents\mods\<f>
        $workshopSource = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $modContent))        # ...\MOD\<f>
        $folder = Split-Path -Leaf $workshopSource

        $kv = @{}
        foreach ($line in [IO.File]::ReadAllLines($infoPath)) {
            if ($line -match '^\s*([A-Za-z_]+)\s*=(.*)$') {
                if (-not $kv.ContainsKey($Matches[1])) { $kv[$Matches[1]] = $Matches[2].Trim() }
            }
        }
        $id = $kv['id']
        if ([string]::IsNullOrWhiteSpace($id)) { Write-PZSyncFail "$infoPath 缺 id="; return $null }
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]*$' -or $id.EndsWith('.') -or
            $id -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') {
            throw "mod.info 的 id 不是安全的單一目錄名稱：$id"
        }

        $require = @()
        if ($kv['require']) {
            $require = @($kv['require'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }

        return [pscustomobject]@{
            Repo           = $root
            Folder         = $folder
            Id             = $id
            Require        = $require
            InfoPath       = $infoPath
            WorkshopSource = $workshopSource
            ModsSource     = $modContent
        }
    } catch {
        Write-PZSyncFail "解析 repo $RepoRoot 失敗：$($_.Exception.Message)"
        return $null
    }
}

# 兄弟 repo 索引：id -> @(@{ Repo; Info }, ...)（只掃 ProjectRoot 的父目錄一層，不做無界遞迴）
function Get-PZSyncSiblingIndex {
    param([string]$SearchRoot)
    $index = @{}
    if (-not [IO.Directory]::Exists($SearchRoot)) { return $index }
    foreach ($dir in @(Get-ChildItem -LiteralPath $SearchRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        $hits = @(Get-ChildItem -Path (Join-Path $dir.FullName 'MOD\*\Contents\mods\*\42\mod.info') -File -Force -ErrorAction SilentlyContinue)
        foreach ($hit in $hits) {
            $id = Get-PZSyncModInfoId $hit.FullName
            if (-not $id) { continue }
            $entry = @{ Repo = $dir.FullName.TrimEnd('\'); Info = $hit.FullName }
            if ($index.ContainsKey($id)) { $index[$id] = @($index[$id]) + @($entry) }
            else { $index[$id] = @($entry) }
        }
    }
    return $index
}

function Resolve-PZSyncModById {
    param([hashtable]$Ctx, [string]$Id, [string]$Requester)
    $repos = @()
    if ($Ctx.Index.ContainsKey($Id)) {
        $repos = @(@($Ctx.Index[$Id]) | ForEach-Object { $_.Repo } | Select-Object -Unique)
    }
    if ($repos.Count -eq 0) {
        Write-PZSyncFail "找不到家族依賴 $Id 的來源 repo（搜尋範圍 $($Ctx.SearchRoot)，由 $Requester 的 require= 指定）"
        return $null
    }
    if ($repos.Count -gt 1) {
        Write-PZSyncFail "家族 id $Id 同時被多個 repo 宣稱：$($repos -join ' / ')；請先修正重複的 mod.info 再同步"
        return $null
    }
    return (Get-PZSyncRepoMod $repos[0])
}

# 後序加入（依賴排在前面），同時偵測循環
function Add-PZSyncModNode {
    param([hashtable]$Ctx, $Mod)
    $id = $Mod.Id
    if ($Ctx.State[$id] -eq 'done') { return $true }
    if ($Ctx.State[$id] -eq 'visiting') {
        Write-PZSyncFail "require= 形成循環依賴（$id），拒絕同步"
        return $false
    }
    $Ctx.State[$id] = 'visiting'
    foreach ($req in @($Mod.Require)) {
        if (-not (Test-PZSyncFamilyId $req)) {
            if (-not $Ctx.ThirdParty.Contains($req)) { [void]$Ctx.ThirdParty.Add($req) }
            continue
        }
        if ($Ctx.State[$req] -eq 'done') { continue }
        $depMod = Resolve-PZSyncModById -Ctx $Ctx -Id $req -Requester $id
        if (-not $depMod) { return $false }
        if (-not (Add-PZSyncModNode -Ctx $Ctx -Mod $depMod)) { return $false }
    }
    $Ctx.State[$id] = 'done'
    $Ctx.ById[$id] = $Mod
    [void]$Ctx.Ordered.Add($Mod)
    return $true
}

# 伺服器 ini 的 Mods=（只讀不寫）；回 $null = 讀取失敗（fail-closed）
function Get-PZSyncIniModIds {
    param([string]$IniPath)
    if ([string]::IsNullOrWhiteSpace($IniPath)) { return @{ Ids = @() } }
    if (-not (Test-Path -LiteralPath $IniPath)) {
        Write-PZSyncWarn "找不到伺服器設定檔 $IniPath，略過 ini 的 Mods= 追加"
        return @{ Ids = @() }
    }
    try { $lines = [IO.File]::ReadAllLines($IniPath) }
    catch {
        Write-PZSyncFail "讀取伺服器設定檔失敗（被鎖住？）：$($_.Exception.Message)"
        return $null
    }
    $ids = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        if ($line -match '^\s*Mods\s*=(.*)$') {
            foreach ($tok in ($Matches[1] -split ';')) {
                $t = $tok.Trim().TrimStart('\').Trim()
                if ($t -and -not $ids.Contains($t)) { [void]$ids.Add($t) }
            }
            break
        }
    }
    return @{ Ids = @($ids) }
}

# 解析完整同步集合：當前 repo + 遞迴 require 家族依賴 + （可選）ini 已設定的家族 MOD
function Resolve-PZSyncModSet {
    param([string]$ProjectRoot, [string]$ServerIniPath)

    $rootMod = Get-PZSyncRepoMod $ProjectRoot
    if (-not $rootMod) { return $null }

    $searchRoot = Split-Path -Parent $rootMod.Repo
    $ctx = @{
        Index      = (Get-PZSyncSiblingIndex $searchRoot)
        SearchRoot = $searchRoot
        Ordered    = (New-Object System.Collections.ArrayList)
        ById       = @{}
        State      = @{}
        ThirdParty = (New-Object System.Collections.ArrayList)
    }

    # 當前 repo 的 id 若也被別的 repo 宣稱，就是「來源互串」的成因，直接拒絕
    if ($ctx.Index.ContainsKey($rootMod.Id)) {
        $claim = @(@($ctx.Index[$rootMod.Id]) | ForEach-Object { $_.Repo } | Select-Object -Unique)
        $foreign = @($claim | Where-Object { -not ($_ -ieq $rootMod.Repo) })
        if ($foreign.Count -gt 0) {
            Write-PZSyncFail "id $($rootMod.Id) 同時被 $($rootMod.Repo) 與 $($foreign -join ' / ') 宣稱，拒絕同步"
            return $null
        }
    }

    if (-not (Add-PZSyncModNode -Ctx $ctx -Mod $rootMod)) { return $null }

    $iniResult = Get-PZSyncIniModIds $ServerIniPath
    if ($null -eq $iniResult) { return $null }
    $iniForeign = New-Object System.Collections.ArrayList
    foreach ($id in @($iniResult.Ids)) {
        if ($ctx.State[$id] -eq 'done') { continue }
        if (-not (Test-PZSyncFamilyId $id)) {
            if (-not $iniForeign.Contains($id)) { [void]$iniForeign.Add($id) }
            continue
        }
        if (-not $ctx.Index.ContainsKey($id)) {
            Write-PZSyncFail "ini 已啟用家族 MOD $id，但在 $searchRoot 找不到來源 repo；拒絕以舊副本啟動。"
            return $null
        }
        $extraMod = Resolve-PZSyncModById -Ctx $ctx -Id $id -Requester 'ini Mods='
        if (-not $extraMod) { return $null }
        if (-not (Add-PZSyncModNode -Ctx $ctx -Mod $extraMod)) { return $null }
    }
    if ($iniForeign.Count -gt 0) {
        Write-PZSyncInfo "ini 的非家族 MOD 不複製（Steam 訂閱或手動安裝）：$(@($iniForeign.ToArray()) -join '、')"
    }

    return @{
        Root       = $rootMod
        Mods       = @($ctx.Ordered.ToArray())
        ThirdParty = @($ctx.ThirdParty.ToArray())
    }
}

# ------------------------------------------------------------
# 雜湊快取與量測
#
# 檔案：<ZomboidDir>\MinidoracatDevSync\hashcache.json（狀態目錄內，不進 MOD 樹、不在遊戲掃描區）
#   { "version": 1, "updatedAt": "<o>", "files": [ { p, len, mtime, ctime, hash }, ... ] }
#   p = 檔案絕對路徑（原樣保存，查詢一律小寫）；mtime／ctime = UTC ticks；hash = SHA256 大寫十六進位
#
# 每次同步仍完整列舉來源與目的的檔案與目錄：新增、刪除、reparse point 一律靠列舉發現，
# 快取只在「絕對路徑 + 長度 + LastWriteTimeUtc + CreationTimeUtc 全部相同」時省掉重算雜湊，
# 不參與任何安全、所有權或刪除決策（快取不會授權刪除，也不會宣稱某個目的地已同步）。
#
# 已知上限：長度與兩個時間戳都沒變、內容卻被改寫（例如刻意還原 mtime）-> 會沿用舊雜湊而漏判；
#           用 -ForceVerify 忽略持久快取、本次每個實體檔案重算一次即可補救。
# 快取缺失／損壞／版本不符：明講原因後全量重建，絕不當成「全部已同步」。
# ------------------------------------------------------------
$script:PZSyncCacheVersion = 1
$script:PZSyncLastMetrics = $null

function New-PZSyncMetrics {
    return @{
        Pairs = 0; Files = 0; Dirs = 0
        Hashed = 0; HashedBytes = [long]0; CacheHits = 0; DupHits = 0
        Copied = 0; Deleted = 0
        Sw = [Diagnostics.Stopwatch]::StartNew()
    }
}

function Get-PZSyncMetricsLine {
    param([hashtable]$M)
    return ("量測：目的地 {0}、列舉 {1} 檔／{2} 夾、雜湊 {3} 檔（{4:N1} MB）、快取命中 {5}、同檔重用 {6}、複製 {7}、刪除 {8}、{9:N2} 秒" -f
        $M.Pairs, $M.Files, $M.Dirs, $M.Hashed, ($M.HashedBytes / 1MB), $M.CacheHits, $M.DupHits, $M.Copied, $M.Deleted, $M.Sw.Elapsed.TotalSeconds)
}

# Path = $null -> 只在本次執行內去重，不讀寫任何持久檔
function New-PZSyncCacheObject {
    param([string]$Path, [switch]$ForceVerify)
    return @{ Path = $Path; Entries = @{}; Session = @{}; ForceVerify = [bool]$ForceVerify; Dirty = $false }
}

function Read-PZSyncHashCache {
    param([string]$StateDir, [switch]$ForceVerify)
    $path = Join-Path $StateDir 'hashcache.json'
    Assert-PZSyncPhysicalPath $path
    $cache = New-PZSyncCacheObject -Path $path -ForceVerify:$ForceVerify
    if ($ForceVerify) {
        Write-PZSyncNote "-ForceVerify：忽略持久雜湊快取，本次每個實體檔案重新計算一次"
    }
    if (-not (Test-Path -LiteralPath $path)) {
        Write-PZSyncInfo "尚無雜湊快取（$path），本次全量計算後建立"
        return $cache
    }
    try {
        $doc = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        if ($null -eq $doc) { throw '快取內容為空' }
        if ($doc.version -ne $script:PZSyncCacheVersion) { throw "快取版本 $($doc.version) 與本版 $($script:PZSyncCacheVersion) 不符" }
        if ($null -eq $doc.files) { throw '快取缺 files' }
        foreach ($f in @($doc.files)) {
            if (-not $f -or [string]::IsNullOrWhiteSpace($f.p) -or [string]::IsNullOrWhiteSpace($f.hash) -or
                $null -eq $f.len -or $null -eq $f.mtime -or $null -eq $f.ctime) { throw '快取項目不完整' }
            if (-not [IO.Path]::IsPathRooted([string]$f.p) -or [string]$f.hash -notmatch '^[0-9A-Fa-f]{64}$' -or
                [long]$f.len -lt 0 -or [long]$f.mtime -lt 0 -or [long]$f.ctime -lt 0) { throw '快取項目格式不合法' }
            $cache.Entries[([string]$f.p).ToLowerInvariant()] = @{
                p = [string]$f.p; len = [long]$f.len; mtime = [long]$f.mtime; ctime = [long]$f.ctime; hash = [string]$f.hash
            }
        }
        Write-PZSyncInfo "已載入雜湊快取 $($cache.Entries.Count) 筆"
    } catch {
        Write-PZSyncWarn "雜湊快取不可用（$($_.Exception.Message)），本次全量重新計算並重建（同步判定不受影響）"
        $cache = New-PZSyncCacheObject -Path $path -ForceVerify:$ForceVerify
        $cache.Dirty = $true
    }
    return $cache
}

# 原子替換（ownership.json／hashcache.json 共用）：
# Windows 的暫時鎖定／替換拒絕（32／33／1175）要退讓重試；直接覆寫會截斷原檔。
function Move-PZSyncFileAtomic {
    param([string]$Temp, [string]$Target)
    Assert-PZSyncPhysicalPath $Target
    if (-not (Test-PZSyncPathExists $Target)) { [IO.File]::Move($Temp, $Target); return }
    for ($attempt = 0; ; $attempt++) {
        try {
            Assert-PZSyncPhysicalPath $Target
            [IO.File]::Replace($Temp, $Target, [NullString]::Value)
            return
        } catch {
            $cause = $_.Exception.GetBaseException()
            $code = $cause.HResult -band 0xffff
            if ($attempt -ge 3 -or $code -notin @(32, 33, 1175) -or
                -not [IO.File]::Exists($Temp) -or -not [IO.File]::Exists($Target)) { throw }
            [Threading.Thread]::Sleep(100)
        }
    }
}

function Save-PZSyncHashCache {
    param([hashtable]$Cache)
    if (-not $Cache -or [string]::IsNullOrWhiteSpace($Cache.Path) -or -not $Cache.Dirty) { return $true }
    $temp = $null
    try {
        Assert-PZSyncPhysicalPath $Cache.Path
        $dir = [IO.Path]::GetDirectoryName($Cache.Path)
        [void][IO.Directory]::CreateDirectory($dir)
        $doc = [pscustomobject]@{
            version   = $script:PZSyncCacheVersion
            updatedAt = (Get-Date).ToString('o')
            files     = @(@($Cache.Entries.Keys) | Sort-Object | ForEach-Object { $Cache.Entries[$_] })
        }
        $temp = Join-Path $dir ("hashcache-" + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($temp, ($doc | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
        Move-PZSyncFileAtomic -Temp $temp -Target $Cache.Path
        $Cache.Dirty = $false
        return $true
    } catch {
        Write-PZSyncFail "雜湊快取未能保存（$($_.Exception.Message)）；本次不啟動，請檢查狀態目錄的寫入權限後重試。"
        try { if ($temp -and [IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } } catch {}
        return $false
    }
}

# 同一個實體檔案（例如 Workshop 與 mods 共用的來源檔）本次最多讀一次
function Get-PZSyncCachedHash {
    param([hashtable]$Cache, [hashtable]$Metrics, [IO.FileInfo]$File, $Sha)
    $path = $File.FullName
    $key = $path.ToLowerInvariant()
    $len = $File.Length
    $mtime = $File.LastWriteTimeUtc.Ticks
    $ctime = $File.CreationTimeUtc.Ticks

    $hit = $Cache.Session[$key]
    if ($hit -and $hit.len -eq $len -and $hit.mtime -eq $mtime -and $hit.ctime -eq $ctime) {
        $Metrics.DupHits++
        return $hit.hash
    }
    if (-not $Cache.ForceVerify) {
        $hit = $Cache.Entries[$key]
        if ($hit -and $hit.len -eq $len -and $hit.mtime -eq $mtime -and $hit.ctime -eq $ctime) {
            $Metrics.CacheHits++
            $Cache.Session[$key] = $hit
            return $hit.hash
        }
    }

    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $hash = [BitConverter]::ToString($Sha.ComputeHash($fs)).Replace('-', '') }
    finally { $fs.Dispose() }
    $entry = @{ p = $path; len = $len; mtime = $mtime; ctime = $ctime; hash = $hash }
    $Cache.Session[$key] = $entry
    $Cache.Entries[$key] = $entry
    $Cache.Dirty = $true
    $Metrics.Hashed++
    $Metrics.HashedBytes += $len
    return $hash
}

# 指定相對路徑的目的端項目失效（複製／刪除實際會動到的那些）
function Clear-PZSyncCacheEntries {
    param([hashtable]$Cache, [string]$Dest, [string[]]$Rels)
    foreach ($rel in @($Rels)) {
        $key = (Join-Path $Dest $rel).TrimEnd('\').ToLowerInvariant()
        if ($Cache.Session.ContainsKey($key)) { [void]$Cache.Session.Remove($key) }
        if ($Cache.Entries.ContainsKey($key)) { [void]$Cache.Entries.Remove($key); $Cache.Dirty = $true }
    }
}

# 整棵目的地失效（歸檔／重建前用；同時清掉搬走後不再存在的路徑，避免快取無限長大）
function Clear-PZSyncCacheTree {
    param([hashtable]$Cache, [string]$Dest)
    $prefix = $Dest.TrimEnd('\').ToLowerInvariant() + '\'
    foreach ($key in @($Cache.Session.Keys)) {
        if ($key.StartsWith($prefix, [StringComparison]::Ordinal)) { [void]$Cache.Session.Remove($key) }
    }
    foreach ($key in @($Cache.Entries.Keys)) {
        if ($key.StartsWith($prefix, [StringComparison]::Ordinal)) { [void]$Cache.Entries.Remove($key); $Cache.Dirty = $true }
    }
}

# ------------------------------------------------------------
# 樹索引（內容雜湊比對：避免「同長度同 mtime 但內容不同」的誤判）
# 未變的檔案沿用快取雜湊，其餘一律重讀實體位元組。
# ------------------------------------------------------------
function Get-PZSyncTreeIndex {
    param([string]$Root, [switch]$IsSource, [hashtable]$Cache, [hashtable]$Metrics)
    if (-not $Metrics) { $Metrics = New-PZSyncMetrics }
    if (-not $Cache) { $Cache = New-PZSyncCacheObject }
    $excluded = Get-PZSyncExcludedNames
    $files = @{}
    $dirs = @{}
    $bytes = [long]0
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        $stack = New-Object System.Collections.Stack
        $stack.Push($rootFull)
        while ($stack.Count -gt 0) {
            $dir = [string]($stack.Pop())
            foreach ($entry in [IO.Directory]::GetFileSystemEntries($dir)) {
                $attr = [IO.File]::GetAttributes($entry)
                $rel = $entry.Substring($rootFull.Length + 1)
                if (($attr -band [IO.FileAttributes]::ReparsePoint) -eq [IO.FileAttributes]::ReparsePoint) {
                    Write-PZSyncFail "樹內含符號連結／junction，拒絕讀寫（避免跟著連結刪到來源）：$entry"
                    return $null
                }
                if (($attr -band [IO.FileAttributes]::Directory) -eq [IO.FileAttributes]::Directory) {
                    if ($IsSource -and ($excluded -contains ([IO.Path]::GetFileName($entry)))) { continue }
                    $dirs[$rel.ToLowerInvariant()] = $rel
                    $stack.Push($entry)
                    $Metrics.Dirs++
                    continue
                }
                $fi = New-Object IO.FileInfo($entry)
                $hash = Get-PZSyncCachedHash -Cache $Cache -Metrics $Metrics -File $fi -Sha $sha
                $files[$rel.ToLowerInvariant()] = @{ Rel = $rel; Len = $fi.Length; Hash = $hash }
                $bytes += $fi.Length
                $Metrics.Files++
            }
        }
        # 只淘汰本次已列舉根目錄下的失效項目，不丟掉其他 MOD 的暖快取。
        $prefix = $rootFull.ToLowerInvariant() + '\'
        foreach ($key in @($Cache.Entries.Keys)) {
            if ($key.StartsWith($prefix, [StringComparison]::Ordinal) -and
                -not $files.ContainsKey($key.Substring($prefix.Length))) {
                [void]$Cache.Entries.Remove($key)
                [void]$Cache.Session.Remove($key)
                $Cache.Dirty = $true
            }
        }
        return @{ Root = $rootFull; Files = $files; Dirs = $dirs; Bytes = $bytes }
    } catch {
        Write-PZSyncFail "掃描 $Root 失敗（fail-closed，不做任何寫入）：$($_.Exception.Message)"
        return $null
    } finally { $sha.Dispose() }
}

function Compare-PZSyncIndex {
    param([hashtable]$SrcIdx, [hashtable]$DstIdx)
    $copy = New-Object System.Collections.ArrayList
    $delFiles = New-Object System.Collections.ArrayList
    $mkDirs = New-Object System.Collections.ArrayList
    $delDirs = New-Object System.Collections.ArrayList
    foreach ($k in $SrcIdx.Dirs.Keys) { if (-not $DstIdx.Dirs.ContainsKey($k)) { [void]$mkDirs.Add($SrcIdx.Dirs[$k]) } }
    foreach ($k in $SrcIdx.Files.Keys) {
        $s = $SrcIdx.Files[$k]
        if (-not $DstIdx.Files.ContainsKey($k)) { [void]$copy.Add($s.Rel); continue }
        $d = $DstIdx.Files[$k]
        if ($d.Len -ne $s.Len -or $d.Hash -ne $s.Hash) { [void]$copy.Add($s.Rel) }
    }
    foreach ($k in $DstIdx.Files.Keys) { if (-not $SrcIdx.Files.ContainsKey($k)) { [void]$delFiles.Add($DstIdx.Files[$k].Rel) } }
    foreach ($k in $DstIdx.Dirs.Keys) { if (-not $SrcIdx.Dirs.ContainsKey($k)) { [void]$delDirs.Add($DstIdx.Dirs[$k]) } }
    return @{
        Copy        = @($copy.ToArray())
        DeleteFiles = @($delFiles.ToArray())
        CreateDirs  = @($mkDirs.ToArray() | Sort-Object -Property Length)          # 淺 -> 深
        DeleteDirs  = @($delDirs.ToArray() | Sort-Object -Property Length -Descending)  # 深 -> 淺
    }
}

function Test-PZSyncPlanEmpty {
    param([hashtable]$Plan)
    return (($Plan.Copy.Count + $Plan.DeleteFiles.Count + $Plan.CreateDirs.Count + $Plan.DeleteDirs.Count) -eq 0)
}

function Clear-PZSyncReadOnly {
    param([string]$Path)
    $fi = New-Object IO.FileInfo($Path)
    if ($fi.Exists -and (($fi.Attributes -band [IO.FileAttributes]::ReadOnly) -eq [IO.FileAttributes]::ReadOnly)) {
        $fi.Attributes = ($fi.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly))
    }
}

# 只在「已驗證的受管目的地」內做鏡像更新（含刪檔）
function Invoke-PZSyncApply {
    param([string]$Source, [string]$Dest, [hashtable]$Plan)
    try {
        foreach ($rel in $Plan.DeleteFiles) {
            $p = Join-Path $Dest $rel
            Assert-PZSyncPhysicalPath $p
            if ([IO.File]::Exists($p)) { Clear-PZSyncReadOnly $p; [IO.File]::Delete($p) }
        }
        foreach ($rel in $Plan.DeleteDirs) {
            $p = Join-Path $Dest $rel
            Assert-PZSyncPhysicalPath $p
            if ([IO.Directory]::Exists($p)) { [IO.Directory]::Delete($p, $false) }
        }
        foreach ($rel in $Plan.CreateDirs) {
            $path = Join-Path $Dest $rel
            Assert-PZSyncPhysicalPath $path
            [void][IO.Directory]::CreateDirectory($path)
        }
        foreach ($rel in $Plan.Copy) {
            $src = Join-Path $Source $rel
            $dst = Join-Path $Dest $rel
            Assert-PZSyncPhysicalPath $src
            Assert-PZSyncPhysicalPath $dst
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dst))
            Clear-PZSyncReadOnly $dst
            [IO.File]::Copy($src, $dst, $true)
        }
        return $true
    } catch {
        Write-PZSyncFail "寫入 $Dest 失敗：$($_.Exception.Message)"
        return $false
    }
}

# ------------------------------------------------------------
# 遊戲程序閘門（fail-closed：查不到＝當作在跑）
# ------------------------------------------------------------
# 程序實際用哪個使用者目錄（照 MainScreenState.java:157-158／GameServer.java:417-418／ZomboidFileSystem.setCacheDir：
# 每個 startsWith("-cachedir=") 的參數都覆寫、trim、/ 換 \，相對路徑依程序工作目錄解析）。
# 'managed'＝沒帶 -cachedir= 或解析後就是 $ZomboidDir；'other'＝確定是別的目錄（隔離 E2E 輪次）；
# 'unknown'＝命令列讀不到、相對路徑、解析失敗或可能是別名——呼叫端一律 fail-closed（算忙碌、不沿用、不殺）。
function Get-PZSyncProfileKind {
    param([string]$CommandLine, [string]$ZomboidDir)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return 'unknown' }
    $dir = $null
    # Windows 命令列切參數：相連的非空白字元與引號段落屬同一參數（"-cachedir=a b"、-cachedir="a b" 都認）
    foreach ($m in [regex]::Matches($CommandLine, '(?:[^\s"]+|"[^"]*"?)+')) {
        $arg = $m.Value.Replace('"', '')
        if ($arg.StartsWith('-cachedir=', [StringComparison]::Ordinal)) { $dir = $arg.Substring(10).Trim().Replace('/', '\') }
    }
    if ($null -eq $dir) { return 'managed' }
    if ($dir -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\])') { return 'unknown' }
    try {
        $a = Resolve-PZSyncFullPath $dir
        $b = Resolve-PZSyncFullPath $ZomboidDir
        if (-not $a -or -not $b) { return 'unknown' }
        if ($a -ieq $b) { return 'managed' }
        # 字串不同仍可能是同一目錄的別名（subst／網路磁碟、\\?\ 裝置路徑）。同一目錄從任何別名讀到的建立時間都相同，
        # 所以只有兩邊都存在且建立時間不同，才確定是別的目錄；其餘無法確認
        # ponytail: 不同目錄剛好建立時間相同時會判 unknown（算忙碌、不殺），擋住並行輪次；實際遇到再升級成
        # Windows handle／file identity（volume serial＋file index）比對
        if ([IO.Directory]::Exists($a) -and [IO.Directory]::Exists($b) -and
            [IO.Directory]::GetCreationTimeUtc($a) -ne [IO.Directory]::GetCreationTimeUtc($b)) { return 'other' }
    } catch { }
    return 'unknown'
}

function Test-PZSyncGameBusy {
    param([string]$ZomboidDir)
    $clients = @('ProjectZomboid64.exe', 'ProjectZomboid32.exe')
    $javas = @('java.exe', 'javaw.exe')
    # 一次查完四個名稱（原本一個名稱一次 CIM 查詢）；查不到＝當作在跑
    $filter = (@(@($clients) + @($javas) | ForEach-Object { "Name='$_'" }) -join ' OR ')
    try { $procs = @(Get-CimInstance Win32_Process -Filter $filter -ErrorAction Stop) }
    catch {
        Write-PZSyncWarn "無法查詢遊戲程序（$($_.Exception.Message)），fail-closed 視為遊戲執行中"
        return $true
    }
    # -cachedir= 確定指向別的使用者目錄＝隔離 E2E 輪次（pz_e2e.py），不讀這裡的 mods，不算忙碌；
    # 指向 $ZomboidDir 本身或解析不了的照樣算（讀不到命令列的 java 在下面 fail-closed）
    $procs = @(@($procs) | Where-Object { (Get-PZSyncProfileKind $_.CommandLine $ZomboidDir) -ne 'other' })
    $running = @(@($procs) | Where-Object { $clients -icontains $_.Name })
    if ($running.Count -gt 0) {
        Write-PZSyncWarn "$(@($running | ForEach-Object { $_.Name } | Select-Object -Unique) -join '／') 正在執行（PID $(@($running | ForEach-Object { $_.ProcessId }) -join ', ')）"
        return $true
    }
    foreach ($p in @($procs)) {
        if (-not ($javas -icontains $p.Name)) { continue }
        $cmd = $p.CommandLine
        if ([string]::IsNullOrEmpty($cmd)) {
            Write-PZSyncWarn "$($p.Name) (PID $($p.ProcessId)) 取不到命令列（權限不足？），無法排除是伺服器，fail-closed"
            return $true
        }
        if ($cmd -match 'zombie\.network\.GameServer|ProjectZomboid|zomboid') {
            Write-PZSyncWarn "PZ 伺服器／遊戲的 $($p.Name) 正在執行（PID $($p.ProcessId)）"
            return $true
        }
    }
    return $false
}

# ------------------------------------------------------------
# 狀態目錄：所有權清單、獨佔鎖、備份歸檔
# ------------------------------------------------------------
function Get-PZSyncStateDir {
    param([string]$ZomboidDir)
    return (Join-Path $ZomboidDir 'MinidoracatDevSync')
}

function Get-PZSyncOwnerKey {
    param([string]$Dest)
    return $Dest.TrimEnd('\').ToLowerInvariant()
}

# 回 hashtable（key = dest 小寫）；$null = 檔案壞了（fail-closed，不猜）
function Read-PZSyncOwnership {
    param([string]$StateDir)
    $file = Join-Path $StateDir 'ownership.json'
    if (-not (Test-Path -LiteralPath $file)) { return @{} }
    try {
        $raw = [IO.File]::ReadAllText($file)
        if ([string]::IsNullOrWhiteSpace($raw)) { throw '所有權清單為空，拒絕猜測副本歸屬。' }
        $obj = $raw | ConvertFrom-Json
        if ($obj.version -ne 1 -or $null -eq $obj.entries) { throw '不支援或不完整的所有權清單。' }
        $map = @{}
        foreach ($e in @($obj.entries)) {
            if (-not $e -or [string]::IsNullOrWhiteSpace($e.dest) -or [string]::IsNullOrWhiteSpace($e.source)) {
                throw '所有權項目缺少來源或目的地。'
            }
            $key = Get-PZSyncOwnerKey $e.dest
            if ($map.ContainsKey($key)) { throw "所有權清單包含重複目的地：$($e.dest)" }
            $map[$key] = $e
        }
        return $map
    } catch {
        Write-PZSyncFail "$file 解析失敗：$($_.Exception.Message)；請把它移走後重新同步"
        return $null
    }
}

function Write-PZSyncOwnership {
    param([string]$StateDir, [hashtable]$Map)
    try {
        [void][IO.Directory]::CreateDirectory($StateDir)
        $entries = @(@($Map.Keys) | Sort-Object | ForEach-Object { $Map[$_] })
        $doc = [pscustomobject]@{
            version   = 1
            updatedAt = (Get-Date).ToString('o')
            entries   = $entries
        }
        $json = $doc | ConvertTo-Json -Depth 6
        $file = Join-Path $StateDir 'ownership.json'
        Assert-PZSyncPhysicalPath $file
        $temp = Join-Path $StateDir ("ownership-" + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($temp, $json, (New-Object Text.UTF8Encoding($false)))
        Move-PZSyncFileAtomic -Temp $temp -Target $file
        return $true
    } catch {
        Write-PZSyncFail "寫入所有權清單失敗：$($_.Exception.Message)"
        return $false
    }
}

function New-PZSyncOwnerEntry {
    param([string]$Dest, [string]$Source, $Mod, [string]$Kind)
    return [pscustomobject]@{
        dest     = $Dest.TrimEnd('\')
        source   = $Source.TrimEnd('\')
        repo     = $Mod.Repo
        modId    = $Mod.Id
        folder   = $Mod.Folder
        kind     = $Kind
        syncedAt = (Get-Date).ToString('o')
    }
}

function Open-PZSyncLock {
    param([string]$StateDir, [int]$TimeoutSec = 30, [switch]$ReadOnly)
    $path = Join-Path $StateDir 'sync.lock'
    Assert-PZSyncPhysicalPath $path
    if ($ReadOnly -and -not (Test-PZSyncPathExists $path)) { return $null }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        try {
            $mode = if ($ReadOnly) { [IO.FileMode]::Open } else { [IO.FileMode]::OpenOrCreate }
            $access = if ($ReadOnly) { [IO.FileAccess]::Read } else { [IO.FileAccess]::ReadWrite }
            return [IO.File]::Open($path, $mode, $access, [IO.FileShare]::None)
        } catch {
            if ((Get-Date) -ge $deadline) {
                Write-PZSyncFail "另一個同步程序持有鎖（$path），$TimeoutSec 秒內未釋放"
                return $null
            }
            Start-Sleep -Milliseconds 250
        }
    }
}

# 只搬不刪：舊 link／未受管實體一律移進 backups\<stamp>（在遊戲掃描區外）
function Move-PZSyncToBackup {
    param([string]$Path, [string]$StateDir, [string]$Label)
    try {
        $backupRoot = Join-Path $StateDir 'backups'
        Assert-PZSyncPhysicalPath $backupRoot
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $slot = Join-Path $backupRoot "$stamp-$Label"
        $n = 1
        while (Test-PZSyncPathExists $slot) { $slot = Join-Path $backupRoot "$stamp-$Label-$n"; $n++ }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $slot))
        # 依「連結本身」的屬性判斷，破損連結也要搬得動（Directory.Exists 會跟著目標跑）
        $attr = [IO.File]::GetAttributes($Path)
        if (($attr -band [IO.FileAttributes]::Directory) -eq [IO.FileAttributes]::Directory) { [IO.Directory]::Move($Path, $slot) }
        else { [IO.File]::Move($Path, $slot) }
        Write-PZSyncInfo "已歸檔舊內容 -> $slot"
        return $slot
    } catch {
        Write-PZSyncFail "歸檔 $Path 失敗（不刪除、不繼續）：$($_.Exception.Message)"
        return $null
    }
}

# ------------------------------------------------------------
# 目的地安全檢查與分類
# ------------------------------------------------------------
function Test-PZSyncDestSafe {
    param([string]$Dest, [string]$Source, [string]$ZomboidResolved, [string]$StateDir, [string]$SourceResolved)
    Assert-PZSyncPhysicalPath (Split-Path -Parent $Dest)
    Assert-PZSyncPhysicalPath $StateDir
    # 只解析「父目錄」再接上葉名：目的地自己是舊 link 時仍要看得到它的邏輯位置（交給 Get-PZSyncDestAction 分類）
    $parentResolved = Resolve-PZSyncFullPath (Split-Path -Parent $Dest)
    $dr = if ($parentResolved) { (Join-Path $parentResolved (Split-Path -Leaf $Dest)).TrimEnd('\') } else { $null }
    $sr = if ($SourceResolved) { $SourceResolved } else { Resolve-PZSyncFullPath $Source }
    if (-not $dr -or -not $sr) { Write-PZSyncFail "路徑無法解析（連結成環？）：$Dest / $Source"; return $false }
    if (-not (Test-PZSyncPathUnder $dr $ZomboidResolved)) {
        Write-PZSyncFail "目的地解析後離開 Zomboid 目錄（$dr 不在 $ZomboidResolved 內），拒絕變更"
        return $false
    }
    $stateResolved = Resolve-PZSyncFullPath $StateDir
    if ($stateResolved -and (Test-PZSyncPathUnder $dr $stateResolved)) {
        Write-PZSyncFail "目的地落在狀態／備份目錄內（$dr），拒絕變更"
        return $false
    }
    if (Test-PZSyncPathUnder $dr $sr) { Write-PZSyncFail "目的地在來源內部（$dr in $sr），拒絕變更"; return $false }
    if (Test-PZSyncPathUnder $sr $dr) { Write-PZSyncFail "來源在目的地內部（$sr in $dr），拒絕變更"; return $false }
    return $true
}

# 'ready'（已是我們的實體副本）／'create'（不存在）／'migrate'（舊 link 或未受管實體，先歸檔）／'refuse'
function Get-PZSyncDestAction {
    param([string]$Dest, [string]$Source, $Owner)
    if (-not (Test-PZSyncPathExists $Dest)) { return 'create' }
    $link = Get-PZSyncLinkTarget $Dest
    if ($link) {
        $lr = Resolve-PZSyncFullPath $link
        $sr = Resolve-PZSyncFullPath $Source
        if ($lr -and $sr -and ($lr -ieq $sr)) {
            Write-PZSyncNote "$Dest 是指向本 repo 來源的舊符號連結，將歸檔後改建實體副本"
            return 'migrate'
        }
        Write-PZSyncFail "$Dest 是指向其他位置的連結（-> $link），來源不明，拒絕變更（請自行確認後移除）"
        return 'refuse'
    }
    if (-not [IO.Directory]::Exists($Dest)) {
        Write-PZSyncNote "$Dest 是檔案而非資料夾，將歸檔後改建實體副本"
        return 'migrate'
    }
    if ($Owner) {
        $or = Resolve-PZSyncFullPath $Owner.source
        $sr = Resolve-PZSyncFullPath $Source
        if ($or -and $sr -and ($or -ieq $sr)) { return 'ready' }
        Write-PZSyncFail "$Dest 已登記給另一個來源（$($Owner.source)），與本次來源 $Source 衝突，拒絕變更"
        return 'refuse'
    }
    Write-PZSyncNote "$Dest 是未受本工具管理的實體資料夾（Steam 快取？），第一次遷移：歸檔後改建實體副本"
    return 'migrate'
}

# ------------------------------------------------------------
# 公開 API
# ------------------------------------------------------------
# 同步與 launcher 共用可重入 mutex；鎖涵蓋同步完成到 Start-Process，避免兩個啟動器交錯換檔。
function Enter-PZSyncOperation {
    param([string]$ZomboidDir)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(
        [IO.Path]::GetFullPath($ZomboidDir).TrimEnd('\').ToLowerInvariant()))).Replace('-', '') }
    finally { $sha.Dispose() }
    $mutex = [Threading.Mutex]::new($false, "Local\PZDevSync-$key")
    try {
        try { $held = $mutex.WaitOne(30000) }
        catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw '其他同步或啟動操作尚未完成，請稍後重試。' }
        return $mutex
    } catch { $mutex.Dispose(); throw }
}

function Invoke-PZSyncLaunch {
    param([string]$ZomboidDir, [scriptblock]$Launch)
    $gate = $null
    try {
        $gate = Enter-PZSyncOperation $ZomboidDir
        return (& $Launch)
    } catch {
        Write-PZSyncFail "啟動中止：$($_.Exception.Message)"
        return $false
    } finally {
        if ($gate) { $gate.ReleaseMutex(); $gate.Dispose() }
    }
}

function Invoke-PZModSync {
    [CmdletBinding()]
    param(
        [string]$ProjectRoot,
        [string]$ZomboidDir,
        [string]$ServerIniPath,
        [switch]$CheckOnly,
        [switch]$ForceVerify   # 忽略持久雜湊快取：每個實體檔案本次重算一次
    )

    $ErrorActionPreference = 'Stop'
    $lock = $null
    $gate = $null
    $cache = $null
    $metrics = New-PZSyncMetrics
    try {
        if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { Write-PZSyncFail "缺少 -ProjectRoot"; return $false }
        if ([string]::IsNullOrWhiteSpace($ZomboidDir)) { Write-PZSyncFail "缺少 -ZomboidDir"; return $false }
        $gate = Enter-PZSyncOperation $ZomboidDir
        $zomboid = [IO.Path]::GetFullPath($ZomboidDir).TrimEnd('\')
        Assert-PZSyncPhysicalPath $zomboid
        if (-not [IO.Directory]::Exists($zomboid)) {
            Write-PZSyncFail "找不到 Zomboid 使用者目錄：$zomboid（先啟動過遊戲一次）"
            return $false
        }
        $zomboidResolved = Resolve-PZSyncFullPath $zomboid
        if (-not $zomboidResolved) { Write-PZSyncFail "無法解析 $zomboid"; return $false }

        $mode = if ($CheckOnly) { '檢查' } else { '同步' }
        Write-Host ""
        Write-Host "=== MOD 實體$mode（不使用符號連結）===" -ForegroundColor Cyan

        # ---- 1. 先把整個來源集合解析／驗證完，再談任何寫入 ----
        $set = Resolve-PZSyncModSet -ProjectRoot $ProjectRoot -ServerIniPath $ServerIniPath
        if (-not $set) { return $false }
        $mods = @($set.Mods)
        Write-PZSyncNote "同步集合（依賴在前）：$(@($mods | ForEach-Object { $_.Id }) -join ' -> ')"
        if (@($set.ThirdParty).Count -gt 0) {
            Write-PZSyncInfo "第三方依賴不複製（Steam 訂閱／手動安裝，既有內容保留）：$(@($set.ThirdParty) -join '、')"
        }

        $stateDir = Get-PZSyncStateDir $zomboid
        Assert-PZSyncPhysicalPath $stateDir
        Assert-PZSyncPhysicalPath (Join-Path $stateDir 'ownership.json')
        Assert-PZSyncPhysicalPath (Join-Path $stateDir 'backups')
        if ($CheckOnly -and -not [IO.Directory]::Exists($stateDir)) {
            Write-PZSyncWarn "尚未建立同步狀態（$stateDir 不存在）：請先執行一次同步"
            return $false
        }
        if (-not $CheckOnly -and -not [IO.Directory]::Exists($stateDir)) {
            if (Test-PZSyncGameBusy $zomboid) { Write-PZSyncFail '遊戲執行中，尚未建立同步副本；請先正常關閉。'; return $false }
            [void][IO.Directory]::CreateDirectory($stateDir)
        }

        $lock = Open-PZSyncLock -StateDir $stateDir -ReadOnly:$CheckOnly
        if (-not $lock) { return $false }

        $ownership = Read-PZSyncOwnership $stateDir
        if ($null -eq $ownership) { return $false }

        # 快取只省雜湊計算：列舉、所有權、目的分類、刪除決策一律照舊自己算
        $cache = Read-PZSyncHashCache -StateDir $stateDir -ForceVerify:$ForceVerify

        # ---- 2. 建立 pair 計畫：來源索引、目的分類、差異比對（全程唯讀）----
        $pairs = New-Object System.Collections.ArrayList
        foreach ($mod in $mods) {
            $pairDefs = @(
                @{ Kind = 'Workshop'; Source = $mod.WorkshopSource; Dest = (Join-Path (Join-Path $zomboid 'Workshop') $mod.Folder) },
                @{ Kind = 'mods';     Source = $mod.ModsSource;     Dest = (Join-Path (Join-Path $zomboid 'mods') $mod.Id) }
            )
            foreach ($def in $pairDefs) {
                $source = $def.Source.TrimEnd('\')
                $dest = $def.Dest.TrimEnd('\')
                $label = "$($mod.Id) [$($def.Kind)]"

                if (-not [IO.Directory]::Exists($source)) { Write-PZSyncFail "$label 來源不存在：$source"; return $false }
                if (Test-PZSyncReparsePoint $source) { Write-PZSyncFail "$label 來源本身是連結：$source，拒絕同步"; return $false }
                # 每個來源只做一次逐段連結解析，後面的交叉比對純字串（原本是每個 pair 重解析所有來源）
                $sourceResolved = Resolve-PZSyncFullPath $source
                if (-not $sourceResolved) { Write-PZSyncFail "$label 來源路徑無法解析（連結成環？）：$source"; return $false }
                if (-not (Test-PZSyncDestSafe -Dest $dest -Source $source -ZomboidResolved $zomboidResolved -StateDir $stateDir -SourceResolved $sourceResolved)) { return $false }

                $srcIdx = Get-PZSyncTreeIndex -Root $source -IsSource -Cache $cache -Metrics $metrics
                if (-not $srcIdx) { return $false }
                if ($srcIdx.Files.Count -eq 0) {
                    Write-PZSyncFail "$label 來源沒有任何檔案（$source），拒絕同步（避免把副本清空）"
                    return $false
                }
                if ($def.Kind -eq 'mods' -and -not [IO.File]::Exists((Join-Path $source '42\mod.info'))) {
                    Write-PZSyncFail "$label 來源缺 42\mod.info：$source"
                    return $false
                }

                $owner = $ownership[(Get-PZSyncOwnerKey $dest)]
                $action = Get-PZSyncDestAction -Dest $dest -Source $source -Owner $owner
                if ($action -eq 'refuse') { return $false }

                $plan = $null
                if ($action -eq 'ready') {
                    $dstIdx = Get-PZSyncTreeIndex -Root $dest -Cache $cache -Metrics $metrics
                    if (-not $dstIdx) { return $false }
                    $plan = Compare-PZSyncIndex -SrcIdx $srcIdx -DstIdx $dstIdx
                }

                [void]$pairs.Add(@{
                    Mod = $mod; Kind = $def.Kind; Label = $label
                    Source = $source; Dest = $dest; SourceResolved = $sourceResolved
                    SrcIdx = $srcIdx; Action = $action; Plan = $plan
                })
            }
        }
        $metrics.Pairs = $pairs.Count

        # 不同 MOD 不能共用或包含彼此的目的地，也不能覆蓋任何一個來源。
        for ($i = 0; $i -lt $pairs.Count; $i++) {
            $dest = [IO.Path]::GetFullPath($pairs[$i].Dest)
            for ($j = $i + 1; $j -lt $pairs.Count; $j++) {
                $other = [IO.Path]::GetFullPath($pairs[$j].Dest)
                if ((Test-PZSyncPathUnder $dest $other) -or (Test-PZSyncPathUnder $other $dest)) {
                    throw "同步目的地彼此衝突：$dest / $other"
                }
            }
            foreach ($pair in $pairs) {
                $source = $pair.SourceResolved
                if ((Test-PZSyncPathUnder $dest $source) -or (Test-PZSyncPathUnder $source $dest)) {
                    throw "同步目的地與來源重疊：$dest / $source"
                }
            }
        }

        $pending = @(@($pairs) | Where-Object { $_.Action -ne 'ready' -or -not (Test-PZSyncPlanEmpty $_.Plan) })

        # ---- 3. 唯讀檢查模式：完全一致且是實體副本才 true（零持久寫入，含快取）----
        if ($CheckOnly) {
            if ($pending.Count -eq 0) {
                Write-PZSyncOk "所有受管副本與來源完全一致（$($pairs.Count) 個目的地）"
                return $true
            }
            foreach ($p in $pending) {
                if ($p.Action -ne 'ready') { Write-PZSyncWarn "$($p.Label) 尚未建立實體副本（$($p.Action)）：$($p.Dest)" }
                else {
                    Write-PZSyncWarn ("$($p.Label) 有差異：新增／更新 {0}、刪除 {1}" -f $p.Plan.Copy.Count, ($p.Plan.DeleteFiles.Count + $p.Plan.DeleteDirs.Count))
                }
            }
            Write-PZSyncFail "副本與來源不一致，請先執行同步（本次未做任何寫入）"
            return $false
        }

        if ($pending.Count -eq 0) {
            Write-PZSyncOk "所有受管副本已與來源一致，無需變更（$($pairs.Count) 個目的地）"
            if (-not (Save-PZSyncHashCache -Cache $cache)) { return $false }
            return $true
        }

        # ---- 4. 需要寫入 -> 遊戲程序閘門（已一致的情況上面就回 true 了）----
        if (Test-PZSyncGameBusy $zomboid) {
            Write-PZSyncFail "遊戲／伺服器執行中且副本與來源不一致：請先關閉再同步（本次未做任何寫入）"
            return $false
        }

        # ---- 5. 逐個受管副本套用；任何一個失敗就整體失敗（不假成功）----
        $unchanged = 0
        foreach ($p in @($pairs)) {
            # 沒有變更的 pair 不寫入，也不必重查程序閘門或重新分類目的地
            if ($p.Action -eq 'ready' -and (Test-PZSyncPlanEmpty $p.Plan)) { $unchanged++; continue }

            if (Test-PZSyncGameBusy $zomboid) { Write-PZSyncFail '同步期間偵測到遊戲啟動，已停止更新。'; return $false }
            Assert-PZSyncPhysicalPath (Split-Path -Parent $p.Dest)
            $actionNow = Get-PZSyncDestAction -Dest $p.Dest -Source $p.Source -Owner $ownership[(Get-PZSyncOwnerKey $p.Dest)]
            if ($actionNow -ne $p.Action) { throw "同步期間目的地狀態改變：$($p.Dest)" }

            if ($p.Action -eq 'migrate') {
                $label = "$($p.Kind)-$($p.Mod.Id)"
                # 整棵目的地即將被搬走：先丟掉它底下的快取項目（含搬走後不再存在的路徑）
                Clear-PZSyncCacheTree -Cache $cache -Dest $p.Dest
                if (-not (Move-PZSyncToBackup -Path $p.Dest -StateDir $stateDir -Label $label)) { return $false }
            }

            if ($p.Action -ne 'ready') {
                try { [void][IO.Directory]::CreateDirectory($p.Dest) }
                catch { Write-PZSyncFail "$($p.Label) 建立目的資料夾失敗：$($_.Exception.Message)"; return $false }
                $dstIdx = Get-PZSyncTreeIndex -Root $p.Dest -Cache $cache -Metrics $metrics
                if (-not $dstIdx) { return $false }
                $p.Plan = Compare-PZSyncIndex -SrcIdx $p.SrcIdx -DstIdx $dstIdx
            }

            # 要被寫到／刪掉的目的端檔案先失效：驗證一定重讀目的地的實體位元組，
            # 不會沿用來源雜湊（File.Copy 會連同來源的 mtime 一起複製，光看 metadata 不夠）
            Clear-PZSyncCacheEntries -Cache $cache -Dest $p.Dest -Rels (@($p.Plan.Copy) + @($p.Plan.DeleteFiles))

            if (-not (Invoke-PZSyncApply -Source $p.Source -Dest $p.Dest -Plan $p.Plan)) { return $false }
            $metrics.Copied += $p.Plan.Copy.Count
            $metrics.Deleted += ($p.Plan.DeleteFiles.Count + $p.Plan.DeleteDirs.Count)

            # 寫完立刻重新以內容雜湊驗證，不信任複製結果
            $verify = Get-PZSyncTreeIndex -Root $p.Dest -Cache $cache -Metrics $metrics
            if (-not $verify) { return $false }
            $residual = Compare-PZSyncIndex -SrcIdx $p.SrcIdx -DstIdx $verify
            if (-not (Test-PZSyncPlanEmpty $residual)) {
                Write-PZSyncFail ("$($p.Label) 同步後仍有差異（複製 {0}、刪除 {1}），拒絕視為成功" -f $residual.Copy.Count, ($residual.DeleteFiles.Count + $residual.DeleteDirs.Count))
                return $false
            }

            $ownership[(Get-PZSyncOwnerKey $p.Dest)] = (New-PZSyncOwnerEntry -Dest $p.Dest -Source $p.Source -Mod $p.Mod -Kind $p.Kind)
            if (-not (Write-PZSyncOwnership -StateDir $stateDir -Map $ownership)) { return $false }
            Write-PZSyncOk ("$($p.Label) 已同步（複製 {0}、刪除 {1}、來源 {2:N1} MB）" -f $p.Plan.Copy.Count, ($p.Plan.DeleteFiles.Count + $p.Plan.DeleteDirs.Count), ($p.SrcIdx.Bytes / 1MB))
        }
        if ($unchanged -gt 0) { Write-PZSyncInfo "$unchanged 個受管副本本來就一致，未變更" }

        # 快取與副本都成功完成後才讓啟動器放行。
        if (-not (Save-PZSyncHashCache -Cache $cache)) { return $false }
        Write-PZSyncOk "全部 $($pairs.Count) 個受管副本與來源一致"
        return $true
    } catch {
        Write-PZSyncFail "同步中止：$($_.Exception.Message)"
        return $false
    } finally {
        if ($lock) { $lock.Dispose() }
        if ($gate) { $gate.ReleaseMutex(); $gate.Dispose() }
        $metrics.Sw.Stop()
        $script:PZSyncLastMetrics = $metrics
        Write-PZSyncInfo (Get-PZSyncMetricsLine $metrics)
    }
}

function Remove-PZModSync {
    [CmdletBinding()]
    param(
        [string]$ProjectRoot,
        [string]$ZomboidDir
    )

    $ErrorActionPreference = 'Stop'
    $lock = $null
    $gate = $null
    try {
        if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { Write-PZSyncFail "缺少 -ProjectRoot"; return $false }
        if ([string]::IsNullOrWhiteSpace($ZomboidDir)) { Write-PZSyncFail "缺少 -ZomboidDir"; return $false }
        $gate = Enter-PZSyncOperation $ZomboidDir
        $zomboid = [IO.Path]::GetFullPath($ZomboidDir).TrimEnd('\')
        Assert-PZSyncPhysicalPath $zomboid
        if (-not [IO.Directory]::Exists($zomboid)) { Write-PZSyncFail "找不到 Zomboid 使用者目錄：$zomboid"; return $false }
        $zomboidResolved = Resolve-PZSyncFullPath $zomboid
        if (-not $zomboidResolved) { Write-PZSyncFail "無法解析 $zomboid"; return $false }

        Write-Host ""
        Write-Host "=== 移除 MOD 實體副本（只動本 repo，依賴保留）===" -ForegroundColor Cyan

        # 只認當前 repo 的 MOD；依賴的副本一律不碰
        $mod = Get-PZSyncRepoMod $ProjectRoot
        if (-not $mod) { return $false }

        $stateDir = Get-PZSyncStateDir $zomboid
        Assert-PZSyncPhysicalPath $stateDir
        Assert-PZSyncPhysicalPath (Join-Path $stateDir 'ownership.json')
        Assert-PZSyncPhysicalPath (Join-Path $stateDir 'backups')
        $targets = @(
            @{ Kind = 'Workshop'; Source = $mod.WorkshopSource.TrimEnd('\'); Dest = (Join-Path (Join-Path $zomboid 'Workshop') $mod.Folder) },
            @{ Kind = 'mods';     Source = $mod.ModsSource.TrimEnd('\');     Dest = (Join-Path (Join-Path $zomboid 'mods') $mod.Id) }
        )

        $existing = @(@($targets) | Where-Object { Test-PZSyncPathExists $_.Dest })
        if ($existing.Count -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $stateDir 'ownership.json'))) {
            Write-PZSyncOk "本 repo 沒有受管副本，無需處理"
            return $true
        }

        if ($existing.Count -gt 0 -and (Test-PZSyncGameBusy $zomboid)) {
            Write-PZSyncFail "遊戲／伺服器執行中，拒絕變更副本：請先關閉再移除"
            return $false
        }

        [void][IO.Directory]::CreateDirectory($stateDir)
        $lock = Open-PZSyncLock -StateDir $stateDir
        if (-not $lock) { return $false }

        $ownership = Read-PZSyncOwnership $stateDir
        if ($null -eq $ownership) { return $false }

        $complete = $true
        foreach ($t in $targets) {
            $dest = $t.Dest.TrimEnd('\')
            $key = Get-PZSyncOwnerKey $dest
            $label = "$($mod.Id) [$($t.Kind)]"

            if (-not (Test-PZSyncPathExists $dest)) {
                if ($ownership.ContainsKey($key)) { $ownership.Remove($key) }
                Write-PZSyncInfo "$label 未掛載：$dest"
                continue
            }
            if (-not (Test-PZSyncDestSafe -Dest $dest -Source $t.Source -ZomboidResolved $zomboidResolved -StateDir $stateDir)) { return $false }

            $link = Get-PZSyncLinkTarget $dest
            if ($link) {
                $lr = Resolve-PZSyncFullPath $link
                $sr = Resolve-PZSyncFullPath $t.Source
                if (-not ($lr -and $sr -and ($lr -ieq $sr))) {
                    Write-PZSyncWarn "$label 是指向其他位置的連結（-> $link），不是本工具建立的，保留不動"
                    $complete = $false
                    continue
                }
            } else {
                $owner = $ownership[$key]
                if (-not $owner) {
                    Write-PZSyncWarn "$label 是未受本工具管理的實體資料夾，保留不動：$dest"
                    $complete = $false
                    continue
                }
                $or = Resolve-PZSyncFullPath $owner.source
                $sr = Resolve-PZSyncFullPath $t.Source
                if (-not ($or -and $sr -and ($or -ieq $sr))) {
                    Write-PZSyncWarn "$label 登記的來源是 $($owner.source)，與本 repo 不符，保留不動"
                    $complete = $false
                    continue
                }
            }

            if (-not (Move-PZSyncToBackup -Path $dest -StateDir $stateDir -Label "remove-$($t.Kind)-$($mod.Id)")) { return $false }
            if ($ownership.ContainsKey($key)) { $ownership.Remove($key) }
            Write-PZSyncOk "$label 已移除（內容留在備份區）"
        }

        if (-not (Write-PZSyncOwnership -StateDir $stateDir -Map $ownership)) { return $false }
        Write-PZSyncInfo "依賴 MOD 的副本未變更（如需移除請到該 repo 執行）"
        return $complete
    } catch {
        Write-PZSyncFail "移除中止：$($_.Exception.Message)"
        return $false
    } finally {
        if ($lock) { $lock.Dispose() }
        if ($gate) { $gate.ReleaseMutex(); $gate.Dispose() }
    }
}
