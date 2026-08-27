@echo off
:: 啟動 PowerShell 視窗執行 PZ 測試啟動器
:: 使用 start 開新視窗 → PowerShell 原生字體，中文顯示正常
set "PROJECT_ROOT=%~dp0"
start "PZ Test Launcher" powershell -ExecutionPolicy Bypass -NoProfile -Command ^
  "$env:PROJECT_ROOT='%PROJECT_ROOT%'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~dp0scripts\PZ_Test.ps1')))"
