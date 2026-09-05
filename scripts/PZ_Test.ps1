# Minidoracat PZ MOD 家族 — 測試啟動器（統一版，正本：D:/github/pz-family-docs/scripts/）
# 零設定：MOD 名稱自動偵測；遊戲路徑可用環境變數 PZ_PATH 覆寫；伺服器名可在選單切換。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================
# 設定（一般不需改；改用環境變數 PZ_PATH）
# ============================================
$PZ_PATH = if ($env:PZ_PATH) { $env:PZ_PATH } else { "D:\SteamLibrary\steamapps\common\ProjectZomboid" }
$SERVER_NAME = "servertest"
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

if (-not (Test-Path (Join-Path $PZ_PATH "ProjectZomboid64.exe"))) {
    Write-Host ""
    Write-Host "[錯誤] 找不到 Project Zomboid: $PZ_PATH" -ForegroundColor Red
    Write-Host "設定環境變數 PZ_PATH 指向遊戲安裝目錄，或修改腳本頂部預設值。" -ForegroundColor Yellow
    Read-Host "按 Enter 結束"
    exit 1
}

# ============================================
# 功能函式
# ============================================

function Start-PZClient {
    param([switch]$Debug)
    $argList = @("-nosteam")
    if ($Debug) { $argList += "-debug" }
    $mode = if ($Debug) { "Debug 模式" } else { "一般模式" }
    Write-Host "[客戶端] 啟動客戶端 ($mode)..." -ForegroundColor Cyan
    Start-Process -FilePath (Join-Path $PZ_PATH "ProjectZomboid64.exe") -ArgumentList $argList -WorkingDirectory $PZ_PATH
    Write-Host "[客戶端] 已啟動。" -ForegroundColor Green
}

function Get-PZServerProcesses {
    param([string]$Name)
    $pattern = '-servername\s+' + [regex]::Escape($Name) + '(\s|$)'
    @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'zombie\.network\.GameServer' -and $_.CommandLine -match $pattern })
}

function Start-PZServer {
    if ((Get-PZServerProcesses -Name $SERVER_NAME).Count -gt 0) {
        Write-Host "[伺服器] $SERVER_NAME 已在執行，略過啟動。" -ForegroundColor Yellow
        return $true
    }
    Write-Host "[伺服器] 啟動專用伺服器 $SERVER_NAME（記憶體 $SERVER_MEMORY）..." -ForegroundColor Cyan
    $javaPath = Join-Path $PZ_PATH "jre64\bin\java.exe"
    $javaArgs = @(
        "-XX:+UseZGC", "-XX:-CreateCoredumpOnCrash", "-XX:-OmitStackTraceInFastThrow",
        "-Xmx$SERVER_MEMORY",
        "-Djava.library.path=natives/;natives/win64/;./",
        "-cp", ".;projectzomboid.jar",
        "zombie.network.GameServer", "-servername", $SERVER_NAME
    )
    Start-Process -FilePath $javaPath -ArgumentList $javaArgs -WorkingDirectory $PZ_PATH
    Write-Host "[伺服器] 已在新視窗啟動；可在該視窗輸入指令（例：grantadmin <玩家名>）。" -ForegroundColor Green
    return $false
}

function Start-ServerAndClients {
    param([int]$Clients)
    [void](Start-PZServer)
    for ($i = 1; $i -le $Clients; $i++) {
        if ($i -gt 1) { Start-Sleep -Seconds 3 }
        Write-Host "[自動] 啟動第 $i 個客戶端 (Debug)..." -ForegroundColor Cyan
        Start-PZClient -Debug
    }
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  伺服器: $SERVER_NAME   連線位址: 127.0.0.1   客戶端: $Clients (Debug)" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
}

function Select-ServerName {
    $inis = @(Get-ChildItem $ServerIniDir -Filter "*.ini" -File -ErrorAction SilentlyContinue)
    if ($inis.Count -eq 0) { Write-Host "[伺服器] $ServerIniDir 下沒有 ini（先跑一次伺服器會自動產生）" -ForegroundColor Yellow; return }
    for ($i = 0; $i -lt $inis.Count; $i++) {
        $mark = if ($inis[$i].BaseName -eq $SERVER_NAME) { "  <- 目前" } else { "" }
        Write-Host "  [$($i + 1)] $($inis[$i].BaseName)$mark"
    }
    $sel = Read-Host "選擇伺服器設定（Enter 取消）"
    $n = 0
    if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $inis.Count) {
        $script:SERVER_NAME = $inis[$n - 1].BaseName
        Write-Host "[伺服器] 已切換為 $SERVER_NAME" -ForegroundColor Green
    }
}

function Stop-AllPZ {
    Write-Host "[停止] 正在停止 PZ 相關進程..." -ForegroundColor Yellow
    $stopped = 0
    Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'zomboid|ProjectZomboid' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $stopped++ }
    Get-Process -Name "ProjectZomboid64" -ErrorAction SilentlyContinue | ForEach-Object { $_ | Stop-Process -Force; $stopped++ }
    if ($stopped -gt 0) { Write-Host "[停止] 已停止 $stopped 個進程。" -ForegroundColor Green }
    else { Write-Host "[停止] 沒有執行中的 PZ 進程。" -ForegroundColor DarkGray }
}

function Open-Logs {
    foreach ($f in @("console.txt", "server-console.txt")) {
        $p = Join-Path $ZomboidDir $f
        if (Test-Path $p) { Write-Host "  $p  ($([math]::Round((Get-Item $p).Length / 1KB)) KB)" } else { Write-Host "  $p  (不存在)" -ForegroundColor DarkGray }
    }
    Start-Process explorer.exe $ZomboidDir
}

# ============================================
# 主選單
# ============================================
$Host.UI.RawUI.WindowTitle = "PZ Test Launcher - $MOD_LABEL"

while ($true) {
    Clear-Host
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Project Zomboid MOD 測試啟動器" -ForegroundColor Cyan
    Write-Host "  $MOD_LABEL" -ForegroundColor Cyan
    Write-Host "  伺服器設定: $SERVER_NAME    PZ: $PZ_PATH" -ForegroundColor DarkGray
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] 啟動客戶端"
    Write-Host "  [2] 啟動客戶端 (Debug 模式)"
    Write-Host ""
    Write-Host "  [3] 啟動專用伺服器"
    Write-Host "  [4] 一鍵：伺服器 + Debug 客戶端"
    Write-Host "  [5] 一鍵：伺服器 + 2 個 Debug 客戶端"
    Write-Host "  [6] 兩個 Debug 客戶端（Host 模式：第一個 HOST、第二個 JOIN 127.0.0.1）"
    Write-Host ""
    Write-Host "  [S] 切換伺服器設定檔（Server\*.ini）"
    Write-Host "  [L] 開啟 Zomboid 目錄與 log 大小"
    Write-Host "  [0] 停止所有 PZ 進程"
    Write-Host "  [Q] 離開"
    Write-Host ""
    $choice = Read-Host "請選擇"

    switch ($choice.ToUpper()) {
        "1" { Start-PZClient; Read-Host "按 Enter 繼續" }
        "2" { Start-PZClient -Debug; Read-Host "按 Enter 繼續" }
        "3" { [void](Start-PZServer); Read-Host "按 Enter 繼續" }
        "4" { Start-ServerAndClients -Clients 1; Read-Host "按 Enter 繼續" }
        "5" { Start-ServerAndClients -Clients 2; Read-Host "按 Enter 繼續" }
        "6" {
            Start-PZClient -Debug
            Write-Host "[Host模式] 等待 5 秒後開第二個客戶端..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 5
            Start-PZClient -Debug
            Read-Host "按 Enter 繼續"
        }
        "S" { Select-ServerName; Read-Host "按 Enter 繼續" }
        "L" { Open-Logs; Read-Host "按 Enter 繼續" }
        "0" { Stop-AllPZ; Read-Host "按 Enter 繼續" }
        "Q" { exit 0 }
    }
}
