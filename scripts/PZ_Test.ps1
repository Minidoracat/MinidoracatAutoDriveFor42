# Project Zomboid MOD 測試啟動器
# MinidoracatAutoDriveFor42 Minidoracat MiniMap - AutoDrive for B42

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================
# 設定區 - 請根據你的環境修改
# ============================================
$PZ_PATH = "D:\SteamLibrary\steamapps\common\ProjectZomboid"
$SERVER_NAME = "servertest"
$SERVER_MEMORY = "3072m"

# 驗證遊戲路徑
if (-not (Test-Path (Join-Path $PZ_PATH "ProjectZomboid64.exe"))) {
    Write-Host ""
    Write-Host "[錯誤] 找不到 Project Zomboid:" -ForegroundColor Red
    Write-Host "  $PZ_PATH" -ForegroundColor Red
    Write-Host ""
    Write-Host "請修改此腳本頂部的 `$PZ_PATH 變數。" -ForegroundColor Yellow
    Read-Host "按 Enter 結束"
    exit 1
}

# ============================================
# 功能函式
# ============================================

function Start-PZClient {
    param([switch]$Debug)
    $args_list = @("-nosteam")
    if ($Debug) { $args_list += "-debug" }
    $mode = if ($Debug) { "Debug 模式" } else { "一般模式" }

    Write-Host ""
    Write-Host "[客戶端] 啟動客戶端 ($mode)..." -ForegroundColor Cyan
    Start-Process -FilePath (Join-Path $PZ_PATH "ProjectZomboid64.exe") `
        -ArgumentList $args_list -WorkingDirectory $PZ_PATH
    Write-Host "[客戶端] 客戶端已啟動！" -ForegroundColor Green
    Write-Host ""
}

function Start-PZServer {
    Write-Host ""
    Write-Host "[伺服器] 啟動專用伺服器..." -ForegroundColor Cyan
    Write-Host "[伺服器] 名稱: $SERVER_NAME"
    Write-Host "[伺服器] 記憶體: $SERVER_MEMORY"
    Write-Host ""

    $javaPath = Join-Path $PZ_PATH "jre64\bin\java.exe"
    $javaArgs = @(
        "-XX:+UseZGC",
        "-XX:-CreateCoredumpOnCrash",
        "-XX:-OmitStackTraceInFastThrow",
        "-Xmx$SERVER_MEMORY",
        "-Djava.library.path=natives/;natives/win64/;./",
        "-cp", ".;projectzomboid.jar",
        "zombie.network.GameServer",
        "-servername", $SERVER_NAME
    )

    Start-Process -FilePath $javaPath -ArgumentList $javaArgs -WorkingDirectory $PZ_PATH
    Write-Host "[伺服器] 伺服器已在新視窗啟動！" -ForegroundColor Green
    Write-Host "[伺服器] 可在伺服器視窗輸入指令，例如: grantadmin Minidoracat" -ForegroundColor DarkGray
    Write-Host ""
}

function Stop-AllPZ {
    Write-Host ""
    Write-Host "[停止] 正在停止 PZ 相關進程..." -ForegroundColor Yellow
    $stopped = 0

    # 僅終止 command line 含 zomboid / ProjectZomboid 的 java 進程，避免誤殺其他 java 應用。
    Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'zomboid|ProjectZomboid' } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            $stopped++
        }
    # ProjectZomboid64.exe 本身即 PZ 專屬進程，可直接終止。
    Get-Process -Name "ProjectZomboid64" -ErrorAction SilentlyContinue | ForEach-Object {
        $_ | Stop-Process -Force
        $stopped++
    }

    if ($stopped -gt 0) {
        Write-Host "[停止] 已停止 $stopped 個進程。" -ForegroundColor Green
    } else {
        Write-Host "[停止] 沒有找到執行中的 PZ 進程。" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ============================================
# 主選單
# ============================================
$Host.UI.RawUI.WindowTitle = "PZ Mod Test Launcher - MinidoracatAutoDriveFor42"

while ($true) {
    Clear-Host
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Project Zomboid MOD 測試啟動器" -ForegroundColor Cyan
    Write-Host "  MinidoracatAutoDriveFor42 Minidoracat MiniMap - AutoDrive for B42" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] 啟動客戶端"
    Write-Host "  [2] 啟動客戶端 (Debug 模式)"
    Write-Host ""
    Write-Host "  [3] 啟動專用伺服器 (Dedicated Server)"
    Write-Host "  [4] 一鍵啟動：伺服器 + 1 個客戶端"
    Write-Host "  [5] 一鍵啟動：伺服器 + 2 個客戶端"
    Write-Host "  [6] 僅啟動兩個客戶端 (Host 模式用)"
    Write-Host ""
    Write-Host "  [0] 停止所有 PZ 進程"
    Write-Host "  [Q] 離開"
    Write-Host ""
    $choice = Read-Host "請選擇"

    switch ($choice.ToUpper()) {
        "1" {
            Start-PZClient
            Read-Host "按 Enter 繼續"
        }
        "2" {
            Start-PZClient -Debug
            Read-Host "按 Enter 繼續"
        }
        "3" {
            Start-PZServer
            Read-Host "按 Enter 繼續"
        }
        "4" {
            Start-PZServer
            Write-Host "[自動] 等待伺服器啟動 (15秒)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 15
            Start-PZClient -Debug
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "  全部啟動完成！" -ForegroundColor Green
            Write-Host "  伺服器: $SERVER_NAME"
            Write-Host "  連線位址: 127.0.0.1"
            Write-Host "========================================" -ForegroundColor Green
            Write-Host ""
            Read-Host "按 Enter 繼續"
        }
        "5" {
            Start-PZServer
            Write-Host "[自動] 等待伺服器啟動 (15秒)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 15
            Write-Host "[自動] 啟動第一個客戶端..." -ForegroundColor Cyan
            Start-PZClient -Debug
            Start-Sleep -Seconds 3
            Write-Host "[自動] 啟動第二個客戶端..." -ForegroundColor Cyan
            Start-PZClient -Debug
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "  全部啟動完成！" -ForegroundColor Green
            Write-Host "  伺服器: $SERVER_NAME"
            Write-Host "  連線位址: 127.0.0.1"
            Write-Host "  客戶端數: 2"
            Write-Host "========================================" -ForegroundColor Green
            Write-Host ""
            Read-Host "按 Enter 繼續"
        }
        "6" {
            Write-Host ""
            Write-Host "[Host模式] 啟動第一個客戶端 (作為 Host)..." -ForegroundColor Cyan
            Start-PZClient -Debug
            Write-Host "[Host模式] 等待 5 秒..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 5
            Write-Host "[Host模式] 啟動第二個客戶端..." -ForegroundColor Cyan
            Start-PZClient -Debug
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "  兩個客戶端已啟動！" -ForegroundColor Green
            Write-Host "  第一個視窗: 選擇 HOST 建立伺服器"
            Write-Host "  第二個視窗: 選擇 JOIN - LAN - 127.0.0.1"
            Write-Host "========================================" -ForegroundColor Green
            Write-Host ""
            Read-Host "按 Enter 繼續"
        }
        "0" {
            Stop-AllPZ
            Read-Host "按 Enter 繼續"
        }
        "Q" {
            Write-Host ""
            Write-Host "再見！"
            exit 0
        }
    }
}
