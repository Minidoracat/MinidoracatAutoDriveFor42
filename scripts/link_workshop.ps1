# Minidoracat PZ MOD 家族 — 開發同步管理（統一版，正本：D:/github/pz-family-docs/scripts/）
# 用途：把開發目錄「實體複製」到 Zomboid\Workshop 與 Zomboid\mods，方便本地測試和 Workshop 上傳
# PZ 對目錄連結的搜尋基準與遍歷路徑不一致，會誤記 MOD 來源；實體副本避免此缺陷。
# 同步與歸檔由 scripts/sync_mod.ps1 負責。
# 零設定：自動從 MOD/*/Contents/mods/*/42/mod.info 讀取 id 與 require=

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================
# 路徑偵測（支援 bat 啟動器和直接執行兩種模式）
# ============================================
if ($env:PROJECT_ROOT) {
    $ProjectRoot = $env:PROJECT_ROOT.TrimEnd('\\')
} elseif ($PSScriptRoot) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
} else {
    $ProjectRoot = (Get-Location).Path
}

# ============================================
# MOD 識別：自動偵測（唯一的 mod.info）
# ============================================
$modInfos = @(Get-ChildItem (Join-Path $ProjectRoot "MOD") -Recurse -Filter "mod.info" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\Contents\\mods\\[^\\]+\\42\\mod\.info$' })
if ($modInfos.Count -ne 1) {
    Write-Host ""
    Write-Host "[錯誤] 期望恰好一個 MOD/<f>/Contents/mods/<f>/42/mod.info，找到 $($modInfos.Count) 個" -ForegroundColor Red
    Write-Host "  搜尋根：$ProjectRoot\MOD" -ForegroundColor Red
    Read-Host "按 Enter 結束"
    exit 1
}
$ModContent = Split-Path -Parent $modInfos[0].DirectoryName          # …\Contents\mods\<f>
$ModSource  = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ModContent))   # …\MOD\<f>
$MOD_FOLDER = Split-Path -Leaf $ModSource
$modKv = @{}
foreach ($line in Get-Content $modInfos[0].FullName -Encoding UTF8) {
    if ($line -match '^\s*([A-Za-z_]+)\s*=(.*)$') { if (-not $modKv.ContainsKey($Matches[1])) { $modKv[$Matches[1]] = $Matches[2].Trim() } }
}
$MOD_ID = $modKv['id']
if (-not $MOD_ID) { Write-Host "[錯誤] mod.info 缺 id=" -ForegroundColor Red; Read-Host "按 Enter 結束"; exit 1 }
# require= 逗號分隔（ChooseGameInfo.java 只 split(",")）；寫入 Mods= 時依賴排在前面
$REQUIRED_MOD_IDS = @()
if ($modKv['require']) { $REQUIRED_MOD_IDS = @($modKv['require'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
# 家族依賴（同步引擎會從兄弟 repo 一併複製）vs 第三方依賴（Steam 訂閱，僅提醒、不複製）
$FamilyDeps = @($REQUIRED_MOD_IDS | Where-Object { $_ -like 'Minidoracat*' -or $_ -like 'Cat*For42' })
# 翻譯包永遠墊底（後載入者覆蓋先載入者）：只重排既有條目、不新增
$TranslationModsLast = @('CatModLangFor42', 'CatLangFor42')

# Zomboid 快取根（同步目的地與伺服器設定都由此推導）
$ZomboidDir = Join-Path $env:UserProfile "Zomboid"
# Workshop 副本（上傳暫存，也會優先被 Steam 模式掃描；目錄名 = 資料夾名）
$WorkshopDest = Join-Path (Join-Path $ZomboidDir "Workshop") $MOD_FOLDER
# mods 副本（no-Steam 測試也可讀取；目錄名 = mod id）
$ModsDir = Join-Path $ZomboidDir "mods"
$ModsDest = Join-Path $ModsDir $MOD_ID

# 非 Steam 伺服器設定檔（-nosteam 伺服器不掃 Workshop，需把 mod id 寫進 ini 的 Mods=）
$ServerIniDir = Join-Path $ZomboidDir "Server"
$ServerModIds = @($REQUIRED_MOD_IDS) + $MOD_ID   # 寫入 Mods= 的 id（依賴在前）
$ServerModIdsOwn = @($MOD_ID)                    # 移除時只動本 repo 擁有的 id

# 驗證 MOD 來源目錄（以 mod.info 為準；workshop.txt 由 Workshop 上傳流程才會產生）
if (-not (Test-Path (Join-Path $ModContent "42\mod.info"))) {
    Write-Host ""
    Write-Host "[錯誤] 找不到 MOD 來源目錄:" -ForegroundColor Red
    Write-Host "  $ModContent\42\mod.info" -ForegroundColor Red
    Write-Host ""
    Write-Host "請確認此腳本位於專案的 scripts/ 目錄下。"
    Read-Host "按 Enter 結束"
    exit 1
}
# 註：AI 工具狀態目錄（.omc/.claude/.gitnexus）不再就地刪除——同步引擎複製時直接排除，
#     來源保持原狀（開發中的 hook 狀態不該被掛載腳本清掉）。

# ============================================
# 同步引擎（sync_mod.ps1）：bat 以 ScriptBlock 執行時沒有 $PSScriptRoot，
# 所以先找專案 scripts/，再退回腳本自身同目錄。缺引擎＝fail-closed，絕不「沒同步照樣繼續」。
# ============================================
$enginePaths = @(Join-Path $ProjectRoot "scripts\sync_mod.ps1")
if ($PSScriptRoot) { $enginePaths += (Join-Path $PSScriptRoot "sync_mod.ps1") }
$SyncEngine = @($enginePaths | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)[0]
if (-not $SyncEngine) {
    Write-Host ""
    Write-Host "[錯誤] 找不到同步引擎 sync_mod.ps1，已中止（不會建立任何連結或副本）" -ForegroundColor Red
    foreach ($p in $enginePaths) { Write-Host "  找過：$p" -ForegroundColor DarkGray }
    Write-Host "  請從 D:/github/pz-family-docs/scripts 同步腳本到本 repo 的 scripts/。" -ForegroundColor Yellow
    Read-Host "按 Enter 結束"
    exit 1
}
. $SyncEngine
foreach ($fn in @('Invoke-PZModSync', 'Remove-PZModSync')) {
    if (-not (Get-Command $fn -CommandType Function -ErrorAction SilentlyContinue)) {
        Write-Host ""
        Write-Host "[錯誤] $SyncEngine 未提供 $fn，引擎版本不符，已中止" -ForegroundColor Red
        Read-Host "按 Enter 結束"
        exit 1
    }
}

# ============================================
# 功能函式
# ============================================

# 只接受引擎契約的單一布林成功值，避免雜訊輸出被 PowerShell 當作成功。
function Test-SyncResult {
    param($Result)
    return ($Result -is [bool] -and $Result)
}

# 唯讀：用於狀態顯示時辨識舊符號連結（本腳本不再建立任何連結）
function Test-IsSymlink {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $item = Get-Item $Path -Force -ErrorAction SilentlyContinue
    return ($null -ne $item.LinkType)
}

function Show-DestState {
    param([string]$Label, [string]$Path)
    Write-Host "  [$Label] " -NoNewline
    if (-not (Test-Path $Path)) {
        Write-Host "未同步" -ForegroundColor DarkGray
    } elseif (Test-IsSymlink $Path) {
        $target = (Get-Item $Path -Force).Target
        Write-Host "舊符號連結 -> $target（下次同步會先歸檔再改成實體副本）" -ForegroundColor Yellow
    } else {
        Write-Host "實體副本" -ForegroundColor Green
    }
}

function Show-Status {
    Write-Host ""
    Write-Host "=== MOD 來源 ===" -ForegroundColor Cyan
    Write-Host "路徑: $ModSource"

    $checks = @(
        @{ File = "workshop.txt"; Desc = "workshop.txt（Workshop 上傳後才有）" }
        @{ File = "preview.png";  Desc = "preview.png" }
        @{ File = "Contents";     Desc = "Contents/" }
    )
    foreach ($c in $checks) {
        $p = Join-Path $ModSource $c.File
        if (Test-Path $p) {
            Write-Host "  [OK] $($c.Desc)" -ForegroundColor Green
        } else {
            Write-Host "  [缺少] $($c.Desc)" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "=== 同步狀態 ===" -ForegroundColor Cyan
    Show-DestState -Label "Workshop" -Path $WorkshopDest
    Show-DestState -Label "mods    " -Path $ModsDest

    # 內容一致性（含家族依賴）交給引擎唯讀檢查：CheckOnly 不寫入任何東西
    Write-Host ""
    if (Test-SyncResult (Invoke-PZModSync -ProjectRoot $ProjectRoot -ZomboidDir $ZomboidDir -CheckOnly)) {
        Write-Host "[已同步] 副本與來源一致，可直接開遊戲測試。" -ForegroundColor Green
    } else {
        Write-Host "[需同步] 副本與來源不一致或尚未建立——請執行選單 [1]。" -ForegroundColor Yellow
    }
    Write-Host ""
}

# ============================================
# 非 Steam 伺服器設定檔（Mods=）
# ============================================

function Select-ServerIni {
    $inis = @(Get-ChildItem $ServerIniDir -Filter "*.ini" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq ".ini" })
    if ($inis.Count -eq 0) {
        Write-Host "  [伺服器] 找不到伺服器設定檔（$ServerIniDir\*.ini），跳過" -ForegroundColor Yellow
        return $null
    }
    if ($inis.Count -eq 1) { return $inis[0].FullName }
    Write-Host ""
    for ($i = 0; $i -lt $inis.Count; $i++) {
        Write-Host "  [$($i + 1)] $($inis[$i].Name)" -NoNewline
        if ($inis[$i].Name -eq "servertest.ini") {
            # 尚無專案偏好時的預設；啟動器之後會記住使用者選擇。
            Write-Host "   <- PZ_Test.bat 首次預設" -ForegroundColor Green -NoNewline
        }
        Write-Host ""
    }
    $sel = Read-Host "請選擇伺服器設定檔（Enter 取消）"
    $n = 0
    if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $inis.Count) {
        return $inis[$n - 1].FullName
    }
    return $null
}

function Update-ServerIniMods {
    param([string]$IniPath, [switch]$Remove)

    # 讀取失敗（檔案被伺服器程序鎖住等）必須中止：$null 流下去會變成破壞性改寫
    try {
        # 編碼偵測：有 BOM → UTF-8 BOM；可嚴格 UTF-8 解碼 → UTF-8 無 BOM；否則系統 ANSI
        $bytes = [IO.File]::ReadAllBytes($IniPath)
        if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {
            Write-Host "  [伺服器] 設定檔是 UTF-16/32 編碼，不支援，未變更" -ForegroundColor Red
            return
        }
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
            $enc = New-Object System.Text.UTF8Encoding($true)
        } else {
            try {
                [void](New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
                $enc = New-Object System.Text.UTF8Encoding($false)
            } catch {
                # 不用 [Text.Encoding]::Default：pwsh 7 下它是 UTF-8，會把 ANSI 中文毀成 U+FFFD
                $enc = [System.Text.Encoding]::GetEncoding(
                    [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage)
            }
        }
        $lines = [IO.File]::ReadAllLines($IniPath, $enc)
    } catch {
        Write-Host "  [伺服器] 讀取設定檔失敗，未變更: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*Mods\s*=') { $idx = $i; break }
    }
    $current = @()
    if ($idx -ge 0) {
        $current = @(($lines[$idx] -replace '^\s*Mods\s*=', '') -split ';' |
            ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    # B42 的 Mods= 條目帶 \ 前綴（如 \StarlitLibrary）：比對時去前綴，寫入時沿用檔內既有風格
    if ($Remove) {
        # 只移除本 repo 擁有的 id，不動共用/主 MOD；大小寫寬鬆以順便清掉手打錯大小寫的殘留
        $updated = @($current | Where-Object { $ServerModIdsOwn -notcontains $_.TrimStart('\') })
    } else {
        $prefix = '\'
        if ($current.Count -gt 0 -and @($current | Where-Object { $_.StartsWith('\') }).Count -eq 0) {
            $prefix = ''
        }
        # 先移除本次管理的所有 id（大小寫寬鬆，順便清掉手打錯大小寫的殘留），
        # 再依「依賴在前」固定順序整組追加——保證 Mods= 內主 MOD 永遠排在本 MOD 前（仿 Compat/Zones 源版）
        $updated = @($current | Where-Object { $ServerModIds -notcontains $_.TrimStart('\') })
        foreach ($id in $ServerModIds) { $updated += "$prefix$id" }
    }
    # 翻譯包墊底：CatModLangFor42 倒數第二、CatLangFor42 最後（只重排既有條目）
    $tail = @($TranslationModsLast | ForEach-Object { $t = $_; $updated | Where-Object { $_.TrimStart('\\') -ieq $t } | Select-Object -First 1 })
    if ($tail.Count -gt 0) { $updated = @($updated | Where-Object { $TranslationModsLast -notcontains $_.TrimStart('\\') }) + $tail }

    if (($updated -join ';') -eq ($current -join ';')) {
        Write-Host "  [伺服器] $(Split-Path -Leaf $IniPath) 的 Mods= 無需變更" -ForegroundColor DarkGray
        return
    }

    $newLine = "Mods=" + ($updated -join ';')
    if ($idx -ge 0) { $lines[$idx] = $newLine } else { $lines += $newLine }

    # ini 回寫（反編譯結論，見 pz-family-docs/production-server.md）：關機不回寫，但執行期任何選項變更會整檔覆蓋——同名伺服器在跑就拒絕；
    # 偵測失敗一律取消寫入（fail-closed），不能在「不知道伺服器是否在跑」時動 ini
    $serverName = [IO.Path]::GetFileNameWithoutExtension($IniPath)
    try {
        $namePattern = '-servername\s+' + [regex]::Escape($serverName) + '(\s|$)'
        $running = @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -match 'zombie\.network\.GameServer' -and
                ($_.CommandLine -match $namePattern -or
                 ($serverName -eq 'servertest' -and $_.CommandLine -notmatch '-servername\s')) })
    } catch {
        Write-Host "  [伺服器] 無法確認伺服器是否執行中（$($_.Exception.Message)），取消寫入" -ForegroundColor Red
        return
    }
    if ($running.Count -gt 0) {
        Write-Host "  [伺服器] $serverName 伺服器正在執行，執行期選項變更會整檔覆蓋——請先停止伺服器再寫入" -ForegroundColor Red
        return
    }

    # 備份失敗就不寫；寫入失敗要明講——不能讓紅字例外後面跟著綠色成功訊息
    try {
        Copy-Item $IniPath "$IniPath.bak" -Force -ErrorAction Stop
    } catch {
        Write-Host "  [伺服器] 備份失敗，取消寫入: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    try {
        [IO.File]::WriteAllLines($IniPath, $lines, $enc)
    } catch {
        Write-Host "  [伺服器] 寫入失敗: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "           原檔已備份為 .ini.bak，可還原" -ForegroundColor Yellow
        return
    }
    Write-Host "  [伺服器] 已更新 $(Split-Path -Leaf $IniPath)（原檔備份為 .ini.bak）" -ForegroundColor Green
    Write-Host "           $newLine" -ForegroundColor DarkGray
}

function Invoke-ServerIniPrompt {
    param([switch]$Remove)
    $question = if ($Remove) {
        "是否同時從非 Steam 伺服器設定檔的 Mods= 移除？(y/N)"
    } else {
        "是否同時把 mod id 寫入非 Steam 伺服器設定檔的 Mods=？(y/N)"
    }
    $ans = Read-Host $question
    if ($ans -notmatch '^[Yy]') { return }
    $ini = Select-ServerIni
    if ($ini) {
        Update-ServerIniMods -IniPath $ini -Remove:$Remove
    } else {
        Write-Host "  [伺服器] 已取消，設定檔未變更" -ForegroundColor DarkGray
    }
}

# ============================================
# 同步 / 卸載（實作全在 sync_mod.ps1）
# ============================================

function Sync-Workshop {
    Write-Host ""
    Write-Host "正在同步實體副本（Workshop + mods，含家族依賴）..." -ForegroundColor Cyan
    Write-Host ""

    $ok = Test-SyncResult (Invoke-PZModSync -ProjectRoot $ProjectRoot -ZomboidDir $ZomboidDir)

    Write-Host ""
    if (-not $ok) {
        # 失敗不得假成功：不寫 ini、不提示可以開遊戲
        Write-Host "[未完成] 同步失敗，請依上方訊息處理（遊戲或伺服器執行中請先關閉後重試）。" -ForegroundColor Red
        Write-Host "[提示] 同步未成功，略過伺服器 ini 寫入詢問" -ForegroundColor Yellow
        Write-Host ""
        return
    }

    $thirdParty = @($REQUIRED_MOD_IDS | Where-Object { $FamilyDeps -notcontains $_ })
    if ($thirdParty.Count -gt 0) {
        Write-Host "[提示] 第三方依賴（$($thirdParty -join '、')）不會被複製，請確認已在 Steam 訂閱；-nosteam 伺服器需其位於 Zomboid\mods" -ForegroundColor DarkGray
    }
    Write-Host "[全部完成] 現在可以在 PZ 遊戲中測試此 MOD。" -ForegroundColor Green
    Write-Host ""
    Invoke-ServerIniPrompt
    Write-Host ""
}

function Unsync-Workshop {
    Write-Host ""
    Write-Host "正在歸檔受管副本（只動本 repo 的 Workshop/mods 副本，依賴保留）..." -ForegroundColor Cyan
    Write-Host ""

    $ok = Test-SyncResult (Remove-PZModSync -ProjectRoot $ProjectRoot -ZomboidDir $ZomboidDir)

    Write-Host ""
    if (-not $ok) {
        Write-Host "[未完成] 卸載未完成，請檢查上方歸檔結果；略過伺服器 ini 移除詢問。" -ForegroundColor Red
        Write-Host ""
        return
    }
    Write-Host "[完成] 受管副本已歸檔。" -ForegroundColor Green
    Write-Host ""
    Invoke-ServerIniPrompt -Remove
    Write-Host ""
}

# ============================================
# 主選單
# ============================================
$Host.UI.RawUI.WindowTitle = "$MOD_FOLDER 開發同步管理"

while ($true) {
    Clear-Host
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  $MOD_FOLDER 開發同步管理" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Workshop: $WorkshopDest"
    Write-Host "  mods:     $ModsDest"
    Write-Host ""
    Write-Host "  [1] 同步 - 複製到 Workshop + mods（實體副本，含家族依賴）"
    Write-Host "  [2] 卸載 - 歸檔本 repo 的受管副本（依賴保留）"
    Write-Host "  [3] 查看目前狀態（唯讀檢查）"
    Write-Host ""
    Write-Host "  [Q] 離開"
    Write-Host ""
    $choice = Read-Host "請選擇"

    switch ($choice.ToUpper()) {
        "1" { Sync-Workshop; Read-Host "按 Enter 繼續" }
        "2" { Unsync-Workshop; Read-Host "按 Enter 繼續" }
        "3" { Show-Status; Read-Host "按 Enter 繼續" }
        "Q" { Write-Host ""; Write-Host "再見！"; exit 0 }
    }
}
