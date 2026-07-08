@echo off
setlocal enabledelayedexpansion

:REPACK_LOOP
cls
echo ===================================================
echo   Android APK Repack Tool by Sohee Yong
echo ===================================================
echo.

:INPUT_APK
set "IN_APK="
set /p "IN_APK=- Input APK Path: "
if "%IN_APK%"=="" goto INPUT_APK
set "IN_APK=%IN_APK:"=%"

if not exist "%IN_APK%" (
    echo [ERROR] Path does not exist.
    goto INPUT_APK
)
if exist "%IN_APK%\" (
    echo [ERROR] You entered a folder. Please specify a file.
    goto INPUT_APK
)

:INPUT_OUT_APK
set "OUT_APK="
set /p "OUT_APK=- Output APK Path: "
if "%OUT_APK%"=="" goto INPUT_OUT_APK
set "OUT_APK=%OUT_APK:"=%"

:INPUT_NEW_PKG
set "NEW_PKG="
set /p "NEW_PKG=- New Package Name (Optional): "

if "%NEW_PKG%"=="" goto INPUT_VERSION_CODE
if "%NEW_PKG%"=="null" goto INPUT_VERSION_CODE

powershell.exe -NoProfile -Command "if ('%NEW_PKG%' -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') { exit 1 }"
if errorlevel 1 (
    echo [ERROR] Invalid format. Package name must contain a dot ^(e.g., com.example.app^).
    goto INPUT_NEW_PKG
)

:INPUT_VERSION_CODE
:INPUT_VCODE
set "V_CODE="
set /p "V_CODE=- Version Code (Optional): "
if "%V_CODE%"=="" goto INPUT_VNAME
set /a "TEST_NUM=V_CODE" 2>nul
if !TEST_NUM! equ 0 if not "!V_CODE!"=="0" (
    echo [ERROR] Version Code must be a number.
    goto INPUT_VCODE
)

:INPUT_VNAME
set "V_NAME="
set /p "V_NAME=- Version Name (Optional): "

:INPUT_MIN_SDK
set "MIN_SDK="
set /p "MIN_SDK=- minSdkVersion (Optional): "
if "%MIN_SDK%"=="" goto INPUT_TARGET_SDK
set /a "TEST_NUM=MIN_SDK" 2>nul
if !TEST_NUM! equ 0 if not "!MIN_SDK!"=="0" (
    echo [ERROR] minSdkVersion must be a number.
    goto INPUT_MIN_SDK
)

:INPUT_TARGET_SDK
set "TARGET_SDK="
set /p "TARGET_SDK=- targetSdkVersion (Optional): "
if "%TARGET_SDK%"=="" goto INPUT_MAX_SDK
set /a "TEST_NUM=TARGET_SDK" 2>nul
if !TEST_NUM! equ 0 if not "!TARGET_SDK!"=="0" (
    echo [ERROR] targetSdkVersion must be a number.
    goto INPUT_TARGET_SDK
)

:INPUT_MAX_SDK
set "MAX_SDK="
set /p "MAX_SDK=- maxSdkVersion (Optional, 'null' to remove): "
if "%MAX_SDK%"=="" goto INPUT_SMALI
if /i "%MAX_SDK%"=="null" goto INPUT_SMALI
set /a "TEST_NUM=MAX_SDK" 2>nul
if !TEST_NUM! equ 0 if not "!MAX_SDK!"=="0" (
    echo [ERROR] maxSdkVersion must be a number or 'null'.
    goto INPUT_MAX_SDK
)

:INPUT_SMALI
set "DO_SMALI="
set "FULL_SMALI="
set "SMALI_TEXT=Skip"
set /p "DO_SMALI=- Full Smali Rename? (Y/N): "
if /i "%DO_SMALI%"=="Y" (
    set "FULL_SMALI=-FullSmali"
    set "SMALI_TEXT=Run"
)

cls
echo ===================================================
echo   Confirm Settings
echo ===================================================
echo  Input  : %IN_APK%
echo  Output : %OUT_APK%
echo  Package: %NEW_PKG%
echo  VCode  : %V_CODE%
echo  VName  : %V_NAME%
echo  MinSdk : %MIN_SDK%
echo  TGSdk  : %TARGET_SDK%
echo  MXSdk  : %MAX_SDK%
echo  Smali  : %SMALI_TEXT%
echo ===================================================
echo.

:CONFIRM_CHOICE
set "CONFIRM="
set /p "CONFIRM=> Proceed? (Y/N): "
if /i "%CONFIRM%"=="N" goto REPACK_LOOP
if /i "%CONFIRM%"=="Y" goto START_EXECUTION
goto CONFIRM_CHOICE

:START_EXECUTION
echo.
echo Launching PowerShell Script...
echo ---------------------------------------------------

set "REPACK_SCRIPT=%~dp0repack_apk_standalone.ps1"

set "IN_APK=%IN_APK:"=%"
set "OUT_APK=%OUT_APK:"=%"

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p = @{}; if ('%IN_APK%' -ne '') { $p['InputApk'] = '%IN_APK%' }; if ('%OUT_APK%' -ne '') { $p['OutputApk'] = '%OUT_APK%' }; if ('%NEW_PKG%' -ne '') { $p['NewPackage'] = '%NEW_PKG%' }; if ('%V_CODE%' -ne '') { $p['VersionCode'] = '%V_CODE%' }; if ('%V_NAME%' -ne '') { $p['VersionName'] = '%V_NAME%' }; if ('%MIN_SDK%' -ne '') { $p['MinSdk'] = '%MIN_SDK%' }; if ('%TARGET_SDK%' -ne '') { $p['TargetSdk'] = '%TARGET_SDK%' }; if ('%MAX_SDK%' -ne '') { $p['MaxSdk'] = '%MAX_SDK%' }; if ('%FULL_SMALI%' -ne '') { $p['FullSmali'] = $true }; & '%REPACK_SCRIPT%' @p"

echo.
echo ---------------------------------------------------
echo Script execution finished.
pause
exit /b %ERRORLEVEL%