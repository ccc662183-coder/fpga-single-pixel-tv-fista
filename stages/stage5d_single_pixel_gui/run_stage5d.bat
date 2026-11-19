@echo off
chcp 65001 >nul
cd /d "%~dp0"
python stage5d_gui.py
if errorlevel 1 (
    echo.
    echo GUI did not start. Try: python -m pip install -r requirements.txt
    pause
)
