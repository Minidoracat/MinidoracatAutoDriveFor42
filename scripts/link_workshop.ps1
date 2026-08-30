# MinidoracatAutoDriveFor42 Workshop 符號連結管理
# 用途：將開發目錄連結到 Zomboid Workshop 和 mods 目錄，方便本地測試和 Workshop 上傳

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================
# 設定區 - MOD 識別
# ============================================
$MOD_FOLDER = "MinidoracatAutoDriveFor42"          # MOD/<資料夾名>，也是 Workshop 連結名
$MOD_ID     = "MinidoracatAutoDriveFor42"              # mod.info 的 id，也是 mods 連結名（通常 = $MOD_FOLDER）
$REQUIRED_MOD_IDS = @("MinidoracatUIFor42", "MinidoracatMiniMapFor42")  # 依賴順序同 mod.info；寫入 Mods= 時排在 addon 前

# ============================================
# 路徑偵測（支援 bat 啟動器和直接執行兩種模式）
# ============================================
if ($env:PROJECT_ROOT) {
    # 從 bat 啟動器呼叫，使用傳入的專案根目錄
    $ProjectRoot = $env:PROJECT_ROOT.TrimEnd('\\')
} elseif ($PSScriptRoot) {
    # 直接執行 ps1，使用腳本所在目錄推算
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
} else {
    # Fallback：使用目前工作目錄
    $ProjectRoot = (Get-Location).Path
}
$ModSource = Join-Path $ProjectRoot "MOD\$MOD_FOLDER"
$ModContent = Join-Path $ModSource "Contents\mods\$MOD_FOLDER"

# Workshop 符號連結（用於上傳；連結名 = 資料夾名）
$WorkshopDir = Join-Path $env:UserProfile "Zomboid\Workshop"
$WorkshopLink = Join-Path $WorkshopDir $MOD_FOLDER

# Mods 符號連結（用於遊戲載入，PZ 優先從此處讀取；連結名 = mod id）
$ModsDir = Join-Path $env:UserProfile "Zomboid\mods"
$ModsLink = Join-Path $ModsDir $MOD_ID

# 非 Steam 伺服器設定檔（-nosteam 伺服器不掃 Workshop，需把 mod id 寫進 ini 的 Mods=）
$ServerIniDir = Join-Path $env:UserProfile "Zomboid\Server"
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

# 清理誤入 MOD 內容樹的 AI 工具狀態目錄（hook 會就地寫入；
# git 已忽略，但 Workshop 上傳是整包目錄，出貨包內必須不存在）
foreach ($junk in @(".omc", ".claude", ".gitnexus")) {
    Get-ChildItem -Path $ModSource -Recurse -Force -Directory -Filter $junk -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -Confirm:$false
}

# ============================================
# 功能函式
# ============================================

function Test-IsSymlink {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    $item = Get-Item $Path -Force -ErrorAction SilentlyContinue
    return ($null -ne $item.LinkType)
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
    Write-Host "=== 連結狀態 ===" -ForegroundColor Cyan

    # Workshop 連結
    Write-Host "  [Workshop] " -NoNewline
    if (-not (Test-Path $WorkshopLink)) {
        Write-Host "未掛載" -ForegroundColor DarkGray
    } elseif (Test-IsSymlink $WorkshopLink) {
        $target = (Get-Item $WorkshopLink -Force).Target
        Write-Host "已掛載 -> $target" -ForegroundColor Green
    } else {
        Write-Host "實體資料夾（非符號連結）" -ForegroundColor Yellow
    }

    # Mods 連結
    Write-Host "  [Mods]     " -NoNewline
    if (-not (Test-Path $ModsLink)) {
        Write-Host "未掛載" -ForegroundColor DarkGray
    } elseif (Test-IsSymlink $ModsLink) {
        $target = (Get-Item $ModsLink -Force).Target
        Write-Host "已掛載 -> $target" -ForegroundColor Green
    } else {
        Write-Host "實體資料夾（Steam 快取？）" -ForegroundColor Yellow
    }
    Write-Host ""
}

function New-SymlinkSafe {
    param([string]$LinkPath, [string]$Target, [string]$Label)

    if (Test-Path $LinkPath) {
        if (Test-IsSymlink $LinkPath) {
            $existing = (Get-Item $LinkPath -Force).Target
            Write-Host "  [$Label] 已掛載 -> $existing" -ForegroundColor Green
            return
        }
        # 實體資料夾（可能是 Steam 快取）—— 以時間戳備份改名，絕不刪除既有資料或舊備份
        $bakPath = "$LinkPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        try {
            Rename-Item $LinkPath $bakPath -Force -ErrorAction Stop
        } catch {
            Write-Host "  [$Label] 無法備份既有資料夾，中止此連結: $($_.Exception.Message)" -ForegroundColor Red
            return
        }
        Write-Host "  [$Label] 已將舊資料夾備份為 $(Split-Path -Leaf $bakPath)" -ForegroundColor Yellow
    }

    # 確保父目錄存在
    $parentDir = Split-Path -Parent $LinkPath
    if (-not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    # 嘗試建立符號連結
    try {
        New-Item -ItemType SymbolicLink -Path $LinkPath -Target $Target -ErrorAction Stop | Out-Null
        Write-Host "  [$Label] 建立成功" -ForegroundColor Green
        Write-Host "           $LinkPath" -ForegroundColor DarkGray
        Write-Host "           -> $Target" -ForegroundColor DarkGray
        return $true
    } catch {
        return $false
    }
}

function New-SymlinkElevated {
    param([string]$LinkPath, [string]$Target, [string]$Label)
    try {
        Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-Command",
            "New-Item -ItemType SymbolicLink -Path '$LinkPath' -Target '$Target' -ErrorAction Stop | Out-Null"
        )
        if (Test-IsSymlink $LinkPath) {
            Write-Host "  [$Label] 建立成功（UAC）" -ForegroundColor Green
            return $true
        }
    } catch {}
    Write-Host "  [$Label] 建立失敗" -ForegroundColor Red
    return $false
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
            # PZ_Test.ps1 的 $SERVER_NAME 固定 servertest，本機測試都走這份
            Write-Host "   <- PZ_Test.bat 主要測試伺服器" -ForegroundColor Green -NoNewline
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

    if (($updated -join ';') -eq ($current -join ';')) {
        Write-Host "  [伺服器] $(Split-Path -Leaf $IniPath) 的 Mods= 無需變更" -ForegroundColor DarkGray
        return
    }

    $newLine = "Mods=" + ($updated -join ';')
    if ($idx -ge 0) { $lines[$idx] = $newLine } else { $lines += $newLine }

    # 伺服器啟動/關閉時會整檔回寫 ini（AGENTS.md），執行中寫入必被覆蓋——同名伺服器在跑就拒絕；
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
        Write-Host "  [伺服器] $serverName 伺服器正在執行，關閉時會整檔回寫覆蓋——請先停止伺服器再寫入" -ForegroundColor Red
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

function Mount-Workshop {
    Write-Host ""
    Write-Host "正在建立符號連結..." -ForegroundColor Cyan
    Write-Host ""

    # 嘗試不需提權建立兩個連結
    $ws = New-SymlinkSafe -LinkPath $WorkshopLink -Target $ModSource -Label "Workshop"
    $md = New-SymlinkSafe -LinkPath $ModsLink -Target $ModContent -Label "Mods"

    # 如果任一個失敗，嘗試 UAC 提權
    $needElevate = @()
    if ($ws -eq $false) { $needElevate += @{ Link=$WorkshopLink; Target=$ModSource; Label="Workshop" } }
    if ($md -eq $false) { $needElevate += @{ Link=$ModsLink; Target=$ModContent; Label="Mods" } }

    if ($needElevate.Count -gt 0) {
        Write-Host ""
        Write-Host "[提示] 需要管理員權限，正在請求提升..." -ForegroundColor Yellow
        foreach ($item in $needElevate) {
            New-SymlinkElevated -LinkPath $item.Link -Target $item.Target -Label $item.Label
        }
    }

    Write-Host ""
    # 依賴可見性：Mods= 會連依賴 id 一起寫入，依賴未掛載（Zomboid\mods 下不可見）就寫進去，
    # -nosteam 開服必報缺 mod——所以「全部完成」與 ini 寫入都必須把依賴納入判斷
    $missingDeps = @($REQUIRED_MOD_IDS | Where-Object { -not (Test-Path (Join-Path $ModsDir $_)) })
    if ((Test-IsSymlink $WorkshopLink) -and (Test-IsSymlink $ModsLink) -and $missingDeps.Count -eq 0) {
        Write-Host "[全部完成] 現在可以在 PZ 遊戲中測試此 MOD。" -ForegroundColor Green
    } elseif ($missingDeps.Count -gt 0) {
        Write-Host "[部分完成] 依賴未掛載（$($missingDeps -join '、')）——請先到主 MOD repo 跑 link_workshop.bat。" -ForegroundColor Yellow
    } else {
        Write-Host "[部分完成] 請檢查上方狀態。" -ForegroundColor Yellow
        Write-Host "替代方案：啟用 Windows 開發人員模式後即可免管理員建立連結：" -ForegroundColor Yellow
        Write-Host "  設定 -> 系統 -> 開發人員專用 -> 開發人員模式" -ForegroundColor Yellow
    }

    Write-Host ""
    if ((Test-IsSymlink $ModsLink) -and $missingDeps.Count -eq 0) {
        Invoke-ServerIniPrompt
    } elseif ($missingDeps.Count -gt 0) {
        Write-Host "[提示] 依賴未掛載，略過伺服器 ini 寫入" -ForegroundColor Yellow
    } else {
        Write-Host "[提示] Mods 連結未建立，略過伺服器設定檔寫入詢問" -ForegroundColor Yellow
    }
    Write-Host ""
}

function Remove-SymlinkSafe {
    param([string]$LinkPath, [string]$Label)

    if (-not (Test-Path $LinkPath)) {
        Write-Host "  [$Label] 不存在，跳過" -ForegroundColor DarkGray
        return
    }

    if (-not (Test-IsSymlink $LinkPath)) {
        Write-Host "  [$Label] 是實體資料夾，跳過（請手動處理）" -ForegroundColor Yellow
        return
    }

    try {
        (Get-Item $LinkPath -Force).Delete()
        Write-Host "  [$Label] 已移除" -ForegroundColor Green
    } catch {
        Write-Host "  [$Label] 需要提權移除..." -ForegroundColor Yellow
        try {
            Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-Command",
                "(Get-Item '$LinkPath' -Force).Delete()"
            )
            if (-not (Test-Path $LinkPath)) {
                Write-Host "  [$Label] 已移除（UAC）" -ForegroundColor Green
            } else {
                Write-Host "  [$Label] 移除失敗" -ForegroundColor Red
            }
        } catch {
            Write-Host "  [$Label] 移除失敗: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Dismount-Workshop {
    Write-Host ""
    Write-Host "正在移除符號連結..." -ForegroundColor Cyan
    Write-Host ""
    Remove-SymlinkSafe -LinkPath $WorkshopLink -Label "Workshop"
    Remove-SymlinkSafe -LinkPath $ModsLink -Label "Mods"

    Write-Host ""
    Invoke-ServerIniPrompt -Remove
    Write-Host ""
}

# ============================================
# 主選單
# ============================================
$Host.UI.RawUI.WindowTitle = "$MOD_FOLDER Workshop 連結管理"

while ($true) {
    Clear-Host
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host "  $MOD_FOLDER 符號連結管理" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Workshop: $WorkshopLink"
    Write-Host "  Mods:     $ModsLink"
    Write-Host ""
    Write-Host "  [1] 掛載 - 建立符號連結（Workshop + Mods）"
    Write-Host "  [2] 卸載 - 移除符號連結（Workshop + Mods）"
    Write-Host "  [3] 查看目前狀態"
    Write-Host ""
    Write-Host "  [Q] 離開"
    Write-Host ""
    $choice = Read-Host "請選擇"

    switch ($choice.ToUpper()) {
        "1" { Mount-Workshop; Read-Host "按 Enter 繼續" }
        "2" { Dismount-Workshop; Read-Host "按 Enter 繼續" }
        "3" { Show-Status; Read-Host "按 Enter 繼續" }
        "Q" { Write-Host ""; Write-Host "再見！"; exit 0 }
    }
}
