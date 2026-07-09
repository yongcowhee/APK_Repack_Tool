@echo off
setlocal enabledelayedexpansion

:REPACK_LOOP
cls
echo ===================================================
echo   🌼Android APK Repack Tool v3.0🌼
echo.
echo   [Released] 26. 07. 09
echo   [Developer] Sohee Yong ✌️
echo ===================================================
echo.
echo ❓How to Use
echo This tool asks for the values below one by one. Type the value and press Enter.
echo Optional fields can be skipped by pressing Enter alone; the Input APK's original value is kept.
echo.
echo.
echo [Required]
echo    [Input APK Path]  :  Path to the original APK you want to modify
echo                         ex) C:\Users\Documents\Binary\sample.apk
echo.
echo    [Output APK Path] :  Option 1) Full path and filename for the new APK (.apk extension is added automatically)
echo                         ex) C:\Users\repack_test
echo                         Option 2) Filename only ^-> saved in the same folder as the Input APK (.apk extension is added automatically)
echo                         ex) repack_test
echo.
echo [Optional]
echo    [New Package Name]  [Version Code]  [Version Name]  [Min SDK]  [Target SDK]  [Max SDK]
echo.
echo    [Note] Leaving an optional field empty keeps the Input APK's original value.
echo       ex) If the Input APK's Min/Target/Max are 33/33/null, entering the values below results in 33/33/35.
echo            ^> Min SDK     :
echo            ^> Target SDK  :
echo            ^> Max SDK     : 35
echo.
echo [Y/N Options]
echo    [Smali]    :  Whether to rewrite the internal package structure ^-> N is fine in most cases
echo    [Proceed]  :  Shows all entered values before running ^-> N cancels and lets you re-enter
echo ===================================================

:INPUT_APK
set "IN_APK="
set "IN_EXT="
set /p "IN_APK=- Input APK Path: "
if "%IN_APK%"=="" goto INPUT_APK
for %%A in ("%IN_APK%") do set "IN_APK=%%~A"
for %%A in ("%IN_APK%") do set "IN_EXT=%%~xA"

if /i not "%IN_EXT%"==".apk" (
    echo [ERROR] Only .apk files are allowed.
    goto INPUT_APK
)

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
for %%A in ("%OUT_APK%") do set "OUT_APK=%%~A"

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
powershell.exe -NoProfile -Command "if ('%V_CODE%' -notmatch '^[0-9]+$') { exit 1 }"
if errorlevel 1 (
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
powershell.exe -NoProfile -Command "if ('%MIN_SDK%' -notmatch '^[0-9]+$') { exit 1 }"
if errorlevel 1 (
    echo [ERROR] minSdkVersion must be a number.
    goto INPUT_MIN_SDK
)

:INPUT_TARGET_SDK
set "TARGET_SDK="
set /p "TARGET_SDK=- targetSdkVersion (Optional, 'null' to remove): "
if "%TARGET_SDK%"=="" goto INPUT_MAX_SDK
if /i "%TARGET_SDK%"=="null" goto INPUT_MAX_SDK
powershell.exe -NoProfile -Command "if ('%TARGET_SDK%' -notmatch '^[0-9]+$') { exit 1 }"
if errorlevel 1 (
    echo [ERROR] targetSdkVersion must be a number or 'null'.
    goto INPUT_TARGET_SDK
)

:INPUT_MAX_SDK
set "MAX_SDK="
set /p "MAX_SDK=- maxSdkVersion (Optional, 'null' to remove): "
if "%MAX_SDK%"=="" goto INPUT_SMALI
if /i "%MAX_SDK%"=="null" goto INPUT_SMALI
powershell.exe -NoProfile -Command "if ('%MAX_SDK%' -notmatch '^[0-9]+$') { exit 1 }"
if errorlevel 1 (
    echo [ERROR] maxSdkVersion must be a number or 'null'.
    goto INPUT_MAX_SDK
)

:INPUT_SMALI
set "DO_SMALI="
set "FULL_SMALI="
set "SMALI_TEXT=Skip"
set /p "DO_SMALI=- Full Smali Rename? (Y/N): "
if /i "%DO_SMALI%"=="Y" (
    set "FULL_SMALI=--fullSmali"
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
echo Launching Repack Tool...
echo ---------------------------------------------------

set "REPACK_JAR=%~dp0tools\repack\RepackApk.jar"
set "BUNDLED_JAVA=%~dp0tools\java\bin\java.exe"

if not exist "%REPACK_JAR%" (
    echo [ERROR] RepackApk.jar not found: %REPACK_JAR%
    pause
    exit /b 1
)

set "JAVA_EXE=java"
if exist "%BUNDLED_JAVA%" set "JAVA_EXE=%BUNDLED_JAVA%"

"%JAVA_EXE%" -jar "%REPACK_JAR%" --input "%IN_APK%" --output "%OUT_APK%" --package "%NEW_PKG%" --versionCode "%V_CODE%" --versionName "%V_NAME%" --minSdk "%MIN_SDK%" --targetSdk "%TARGET_SDK%" --maxSdk "%MAX_SDK%" --scriptRoot "%~dp0" %FULL_SMALI%

echo.
echo ---------------------------------------------------
echo Script execution finished.
pause
exit /b %ERRORLEVEL%
