@echo off
cd /d "%~dp0"
python run_stage6a_quality_sweep.py --phase lambda
if errorlevel 1 (
  echo [FAIL] Please install: python -m pip install -r requirements.txt
) else (
  echo [PASS] Open reports\summary.txt and reports\lambda_psnr.png
)
pause
