@echo off
:: Steam Workshop 發布（互動選單；AI／自動化請直接呼叫 scripts\publish_workshop.py --mode ... --yes）
chcp 65001 >nul
set "PYTHONUTF8=1"
cd /d "%~dp0"
uv run --no-project python -B scripts\publish_workshop.py %*
echo.
pause
