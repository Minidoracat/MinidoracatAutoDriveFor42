@echo off
:: 啟動 PowerShell 視窗執行 MOD 同步管理腳本（實體副本同步，不再建符號連結）
:: 使用 start 開新視窗 → PowerShell 原生字體，中文顯示正常
set "PROJECT_ROOT=%~dp0"
start "Mod Sync Manager" powershell -ExecutionPolicy Bypass -NoProfile -Command ^
  "$env:PROJECT_ROOT='%PROJECT_ROOT%'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; & ([scriptblock]::Create((Get-Content -Raw -Encoding UTF8 '%~dp0scripts\link_workshop.ps1')))"
