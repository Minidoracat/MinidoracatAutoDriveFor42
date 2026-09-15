@echo off
:: 原生可點選啟動器；腳本為 UTF-8 BOM，Windows PowerShell 可直接讀取。
set "PROJECT_ROOT=%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0scripts\PZ_Test.ps1"
