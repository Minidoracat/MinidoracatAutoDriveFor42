param(
    [ValidateSet('client', 'server', 'combo', 'cntrans', 'sync', 'stop')][string]$Action,
    [string]$ServerName = 'servertest',
    [ValidateRange(1, 2)][int]$Clients = 1,
    [switch]$NoSteam,
    [switch]$DebugClient,
    [switch]$ForceVerify,
    [switch]$LoadOnly
)

# Minidoracat PZ MOD 家族 — 測試啟動器（統一版，正本：D:/github/pz-family-docs/scripts/）
# 零設定：MOD 名稱自動偵測；遊戲路徑可用環境變數 PZ_PATH 覆寫；伺服器名可在選單切換。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================
# 設定（一般不需改；改用環境變數 PZ_PATH）
# ============================================
$PZ_PATH = if ($env:PZ_PATH) { $env:PZ_PATH } else { "D:\SteamLibrary\steamapps\common\ProjectZomboid" }
# .bat 以 & ScriptBlock 執行；初始化與選單寫入須同 scope，否則區域預設值會遮住選擇。
$script:SERVER_NAME = $ServerName
$script:PZForceVerify = [bool]$ForceVerify
$SERVER_MEMORY = "3072m"
$ZomboidDir = Join-Path $env:USERPROFILE "Zomboid"
$ServerIniDir = Join-Path $ZomboidDir "Server"

# 專案根與 MOD 名（只用於視窗標題）
if ($env:PROJECT_ROOT) { $ProjectRoot = $env:PROJECT_ROOT.TrimEnd('\') }
elseif ($PSScriptRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
else { $ProjectRoot = (Get-Location).Path }
$modInfo = @(Get-ChildItem (Join-Path $ProjectRoot "MOD") -Recurse -Filter "mod.info" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\Contents\\mods\\[^\\]+\\42\\mod\.info$' } | Select-Object -First 1)
$MOD_LABEL = if ($modInfo) {
    $n = (Get-Content $modInfo[0].FullName -Encoding UTF8 | Where-Object { $_ -match '^\s*name=' } | Select-Object -First 1) -replace '^\s*name=', ''
    $id = (Get-Content $modInfo[0].FullName -Encoding UTF8 | Where-Object { $_ -match '^\s*id=' } | Select-Object -First 1) -replace '^\s*id=', ''
    "$id  $n"
} else { Split-Path -Leaf $ProjectRoot }

if (-not $LoadOnly -and -not (Test-Path (Join-Path $PZ_PATH "ProjectZomboid64.exe"))) {
    $message = "找不到 Project Zomboid：$PZ_PATH。請設定 PZ_PATH 後重試。"
    if (-not $Action) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($message, 'PZ 測試啟動器')
    }
    Write-Error $message
    exit 1
}

# ============================================
# 功能函式
# ============================================

function Invoke-PZLaunch {
    param([scriptblock]$Launch)
    try {
        . (Join-Path $ProjectRoot 'scripts\sync_mod.ps1')
        return (Invoke-PZSyncLaunch -ZomboidDir $ZomboidDir -Launch $Launch)
    } catch {
        Write-Host "[啟動] 同步引擎未就緒：$($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Sync-PZBeforeLaunch {
    param([switch]$CheckOnly)
    try {
        $syncPath = Join-Path $ProjectRoot 'scripts\sync_mod.ps1'
        if (-not (Test-Path -LiteralPath $syncPath -PathType Leaf)) {
            throw "找不到同步引擎：$syncPath。請先更新家族工具。"
        }
        . $syncPath
        $result = Invoke-PZModSync -ProjectRoot $ProjectRoot -ZomboidDir $ZomboidDir `
            -ServerIniPath (Join-Path $ServerIniDir ($script:SERVER_NAME + '.ini')) -CheckOnly:$CheckOnly -ForceVerify:$script:PZForceVerify
        $success = $result -is [bool] -and $result
        if ($success) { $script:PZForceVerify = $false }
        return $success
    } catch {
        Write-Host "[同步] 已取消啟動：$($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Start-PZClient {
    param([switch]$Debug, [switch]$NoSteam, [switch]$CheckSyncOnly)
    return (Invoke-PZLaunch {
    if (-not (Sync-PZBeforeLaunch -CheckOnly:$CheckSyncOnly)) { return $false }
    $argList = @()
    if ($NoSteam) { $argList += "-nosteam" }
    if ($Debug) { $argList += "-debug" }
    $mode = if ($Debug) { "Debug 模式" } else { "一般模式" }
    $network = if ($NoSteam) { "no-Steam" } else { "Steam" }
    Write-Host "[客戶端] 啟動客戶端 ($network / $mode)..." -ForegroundColor Cyan
    $start = @{ FilePath = (Join-Path $PZ_PATH "ProjectZomboid64.exe"); WorkingDirectory = $PZ_PATH }
    if ($argList.Count -gt 0) { $start.ArgumentList = $argList }
    try { Start-Process @start -ErrorAction Stop }
    catch {
        Write-Host "[客戶端] 啟動失敗：$($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    Write-Host "[客戶端] 已啟動。" -ForegroundColor Green
    return $true
    })
}

function Get-PZServerProcesses {
    param([string]$Name)
    $pattern = '-servername\s+"?' + [regex]::Escape($Name) + '"?(\s|$)'
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction Stop)
    if (@($processes | Where-Object { [string]::IsNullOrWhiteSpace($_.CommandLine) }).Count -gt 0) {
        throw '無法讀取 Java 程序命令列，不能確認是否已有測試伺服器。'
    }
    # 隔離 E2E 輪次（-cachedir= 指向別的使用者目錄）可能用同一個 -servername，但它是另一台伺服器，不能當成「已在執行」沿用；
    # -cachedir= 指向 $ZomboidDir 本身仍是這台，解析不了就無法確認（sync_mod.ps1 已由 Invoke-PZLaunch 載入）
    @($processes | Where-Object { $_.CommandLine -match 'zombie\.network\.GameServer' -and $_.CommandLine -match $pattern } | Where-Object {
        $kind = Get-PZSyncProfileKind $_.CommandLine $ZomboidDir
        if ($kind -eq 'unknown') { throw "無法確認 PID $($_.ProcessId) 的 -cachedir= 使用者目錄，不能確認是否已有測試伺服器。" }
        $kind -eq 'managed' })
}

function Start-PZServer {
    param([switch]$NoSteam)
    return (Invoke-PZLaunch {
    $network = if ($NoSteam) { "no-Steam" } else { "Steam" }
    try { $running = @(Get-PZServerProcesses -Name $script:SERVER_NAME) }
    catch {
        Write-Host "[伺服器] 無法確認執行狀態，取消啟動：$($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    foreach ($process in $running) {
        $steam = $process.CommandLine -match '(?:^|\s)-Dzomboid\.steam=1(?:\s|$)' -and $process.CommandLine -notmatch '(?:^|\s)-nosteam(?:\s|$)'
        if ($steam -eq [bool]$NoSteam) {
            Write-Host "[伺服器] $script:SERVER_NAME 已在另一連線模式執行。請先於原伺服器輸入 quit 正常關服，再切換為 $network；本次不啟動。" -ForegroundColor Red
            return $false
        }
    }
    if (-not (Sync-PZBeforeLaunch -CheckOnly:($running.Count -gt 0))) { return $false }
    if ($running.Count -gt 0) {
        Write-Host "[伺服器] $script:SERVER_NAME ($network) 已在執行，沿用原程序。" -ForegroundColor Yellow
        return $true
    }
    Write-Host "[伺服器] 啟動專用伺服器 $script:SERVER_NAME（$network，記憶體 $SERVER_MEMORY）..." -ForegroundColor Cyan
    $steamFlag = if ($NoSteam) { "-Dzomboid.steam=0" } else { "-Dzomboid.steam=1" }
    $javaPath = Join-Path $PZ_PATH "jre64\bin\java.exe"
    $javaArgs = @(
        "-XX:+UseZGC", "-XX:-CreateCoredumpOnCrash", "-XX:-OmitStackTraceInFastThrow",
        "-Xmx$SERVER_MEMORY",
        $steamFlag,
        "-Djava.library.path=natives/;natives/win64/;./",
        "-cp", ".;projectzomboid.jar",
        "zombie.network.GameServer", "-servername", ('"' + $script:SERVER_NAME + '"')
    )
    try { Start-Process -FilePath $javaPath -ArgumentList $javaArgs -WorkingDirectory $PZ_PATH -ErrorAction Stop }
    catch {
        Write-Host "[伺服器] 啟動失敗：$($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    Write-Host "[伺服器] 已在新視窗啟動；可在該視窗輸入指令（例：grantadmin <玩家名>）。" -ForegroundColor Green
    return $true
    })
}

function Start-ServerAndClients {
    param([int]$Clients, [switch]$Debug, [switch]$NoSteam)
    $iniPath = Join-Path $ServerIniDir ($script:SERVER_NAME + ".ini")
    $serverPort = "16261"
    if (Test-Path -LiteralPath $iniPath) {
        $portLine = Get-Content -LiteralPath $iniPath -Encoding UTF8 -ErrorAction Stop |
            Where-Object { $_ -match '^\s*DefaultPort\s*=' } | Select-Object -First 1
        if ($portLine) { $serverPort = ($portLine -split '=', 2)[1].Trim() }
    }
    $savePath = Join-Path (Join-Path $ZomboidDir "Saves/Multiplayer") $script:SERVER_NAME
    if (-not (Start-PZServer -NoSteam:$NoSteam)) { return $false }
    $mode = if ($Debug) { "Debug" } else { "一般" }
    for ($i = 1; $i -le $Clients; $i++) {
        if ($i -gt 1) { Start-Sleep -Seconds 3 }
        Write-Host "[自動] 啟動第 $i 個客戶端 ($mode)..." -ForegroundColor Cyan
        if (-not (Start-PZClient -Debug:$Debug -NoSteam:$NoSteam -CheckSyncOnly)) { return $false }
    }
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  伺服器: $script:SERVER_NAME   連線位址: 127.0.0.1:$serverPort   客戶端: $Clients ($mode)" -ForegroundColor Green
    Write-Host "  設定檔: $iniPath" -ForegroundColor Green
    Write-Host "  伺服器存檔: $savePath" -ForegroundColor Green
    Write-Host "  請在遊戲選「加入」並使用上述位址與埠；本選項不會自動連線，勿沿用舊伺服器連線。" -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Green
    return $true
}


function Stop-AllPZ {
    # 只停用 $ZomboidDir 的 PZ：-cachedir= 指向別的目錄是隔離 E2E 輪次（pz_e2e.py），由它自己 stop；
    # 讀不到命令列（含 java／javaw）、-cachedir= 解析不了或可能是別名的不猜、不殺，回 $false 讓使用者自行處理
    . (Join-Path $ProjectRoot 'scripts\sync_mod.ps1')
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object { $_.Name -in @('ProjectZomboid64.exe', 'ProjectZomboid32.exe') -or
            ($_.Name -in @('java.exe', 'javaw.exe') -and ([string]::IsNullOrWhiteSpace($_.CommandLine) -or
                $_.CommandLine -match 'zombie\.(network\.GameServer|gameStates\.MainScreenState)')) })
    $stopped = 0
    $unknown = @()
    foreach ($process in $processes) {
        $kind = Get-PZSyncProfileKind $process.CommandLine $ZomboidDir
        if ($kind -eq 'managed') { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop; $stopped++ }
        elseif ($kind -eq 'unknown') { $unknown += $process.ProcessId }
    }
    Write-Host "[停止] 已停止 $stopped 個 PZ 程序（隔離 E2E 輪次不受影響）。" -ForegroundColor Yellow
    if ($unknown.Count -gt 0) {
        Write-Host "[停止] PID $($unknown -join ', ') 無法確認使用者目錄（命令列讀不到、-cachedir= 解析不了或可能是別名），未停止；請自行確認後關閉。" -ForegroundColor Red
        return $false
    }
    return $true
}

function Open-Logs {
    foreach ($f in @("console.txt", "server-console.txt")) {
        $p = Join-Path $ZomboidDir $f
        if (Test-Path $p) { Write-Host "  $p  ($([math]::Round((Get-Item $p).Length / 1KB)) KB)" } else { Write-Host "  $p  (不存在)" -ForegroundColor DarkGray }
    }
    Start-Process explorer.exe $ZomboidDir
}

function Invoke-PZLauncherAction {
    param(
        [ValidateSet('client', 'server', 'combo', 'cntrans', 'sync', 'stop')][string]$Action,
        [string]$ServerName = 'servertest',
        [ValidateRange(1, 2)][int]$Clients = 1,
        [switch]$NoSteam,
        [switch]$DebugClient,
        [switch]$ForceVerify
    )
    if ([string]::IsNullOrWhiteSpace($ServerName) -or $ServerName -in @('.', '..') -or
        $ServerName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $ServerName.EndsWith('.')) {
        Write-Host '[啟動] 伺服器設定名稱不合法。' -ForegroundColor Red
        return $false
    }
    $script:SERVER_NAME = $ServerName
    $script:PZForceVerify = [bool]$ForceVerify
    if (-not $NoSteam -and $Clients -gt 1) {
        Write-Host '[啟動] Steam 模式僅能啟動一個客戶端；多開請選 no-Steam。' -ForegroundColor Red
        return $false
    }
    switch ($Action) {
        'client' {
            for ($i = 0; $i -lt $Clients; $i++) {
                if ($i -gt 0) { Start-Sleep -Seconds 3 }
                if (-not (Start-PZClient -NoSteam:$NoSteam -Debug:$DebugClient -CheckSyncOnly:($i -gt 0))) { return $false }
            }
            return $true
        }
        'server' { return (Start-PZServer -NoSteam:$NoSteam) }
        'combo' { return (Start-ServerAndClients -Clients $Clients -NoSteam:$NoSteam -Debug:$DebugClient) }
        'sync' { return (Sync-PZBeforeLaunch) }
        'stop' { return (Stop-AllPZ) }
        'cntrans' { Write-Host '[啟動] 此專案沒有漢化對照模式。' -ForegroundColor Red; return $false }
    }
}

if ($LoadOnly) { return }
if ($Action) {
    $ErrorActionPreference = 'Stop'
    try {
        if (Invoke-PZLauncherAction -Action $Action -ServerName $ServerName -Clients $Clients `
            -NoSteam:$NoSteam -DebugClient:$DebugClient -ForceVerify:$ForceVerify) { exit 0 }
    } catch { Write-Host "[啟動] $($_.Exception.Message)" -ForegroundColor Red }
    exit 1
}

try {
    . (Join-Path $ProjectRoot 'scripts\PZ_Test_UI.ps1')
    Show-PZTestLauncher -ProjectRoot $ProjectRoot -LauncherPath (Join-Path $ProjectRoot 'scripts\PZ_Test.ps1') `
        -ZomboidDir $ZomboidDir -ModLabel $MOD_LABEL
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'PZ 啟動器無法開啟')
    exit 1
}
