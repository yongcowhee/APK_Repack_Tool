@echo off
setlocal enabledelayedexpansion

:REPACK_LOOP
cls
echo ===================================================
echo   Android APK Repack Tool v3.0
echo.
echo   [Released] 26. 07. 09
echo   [Developer] Sohee Yong
echo ===================================================
echo.
echo ===================================================
echo How to Use
echo 사용자에게 입력할 인자를 요구하며, 해당 인자에 맞는 값을 입력합니다.
echo 선택 입력 값은 Enter를 입력해 Skip할 수 있으며, Input APK(원본 APK) 정보가 유지됩니다.
echo.
echo.
echo [필수] 필수 입력 값
echo    [Input APK Path]  :  변경하길 원하는 원본 APK가 존재하는 경로
echo                         ex) C:\Users\Documents\Binary\sample.apk
echo    [Output APK Path] :  선택 1) 변경된 APK가 저장되길 원하는 경로 및 파일명, (확장자는 .apk로 자동 생성)
echo                         ex) C:\Users\repack_test
echo                         선택 2) 파일명만 작성하는 경우, Input APK와 동일한 디렉토리에 생성됨 (확장자는 .apk로 자동 생성)
echo                         ex) repack_test
echo.
echo [선택] 선택 입력 값
echo    [New Package Name]  [Version Code]  [Version Name]  [Min SDK]  [Target SDK]  [Max SDK]
echo.
echo    [주의] 선택 입력 값 입력 X -> Input APK 값 유지
echo       ex) Input APK의 Min, Target, Max가 33 33 null일 때 아래와 같이 값을 입력하면 33 33 35로 생성됨
echo            > Min SDK     :
echo            > Target SDK  :
echo            > Max SDK     : 35
echo.
echo [선택] 선택(Y/N) 값
echo    [Smali]    :  APK 내부 구조 리팩토링 여부 선택 -> N 선택해도 무방함
echo    [Proceed]  :  사용자가 입력한 전체 인자 출력되며 최종 진행 여부 선택 -> N 선택하면 작업 취소되며, 리팩토링 진행되지 않음
echo ===================================================



:INPUT_APK
set "IN_APK="
set "IN_EXT="
set /p "IN_APK=- Input APK Path: "
if "%IN_APK%"=="" goto INPUT_APK
for %%A in ("%IN_APK%") do set "IN_APK=%%~A"
for %%A in ("%IN_APK%") do set "IN_EXT=%%~xA"

if /i not "%IN_EXT%"==".apk" (
    echo [ERROR] APK만 변경 가능합니다.
    goto INPUT_APK
)

if not exist "%IN_APK%" (
    echo [ERROR] 경로가 존재하지 않습니다.
    goto INPUT_APK
)
if exist "%IN_APK%\" (
    echo [ERROR] 폴더가 아닌 파일 경로를 입력해 주세요.
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
    echo [ERROR] 형식이 올바르지 않습니다. 패키지명에는 점(.)이 포함되어야 합니다 ^(예: com.example.app^).
    goto INPUT_NEW_PKG
)

:INPUT_VERSION_CODE
:INPUT_VCODE
set "V_CODE="
set /p "V_CODE=- Version Code (Optional): "
if "%V_CODE%"=="" goto INPUT_VNAME
powershell.exe -NoProfile -Command "if ('%V_CODE%' -notmatch '^[0-9]+$') { exit 1 }"
if errorlevel 1 (
    echo [ERROR] Version Code는 숫자여야 합니다.
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
    echo [ERROR] minSdkVersion은 숫자여야 합니다.
    goto INPUT_MIN_SDK
)

:INPUT_TARGET_SDK
set "TARGET_SDK="
set /p "TARGET_SDK=- targetSdkVersion (Optional, 'null' to remove): "
if "%TARGET_SDK%"=="" goto INPUT_MAX_SDK
if /i "%TARGET_SDK%"=="null" goto INPUT_MAX_SDK
powershell.exe -NoProfile -Command "if ('%TARGET_SDK%' -notmatch '^[0-9]+$') { exit 1 }"
if errorlevel 1 (
    echo [ERROR] targetSdkVersion은 숫자이거나 'null'이어야 합니다.
    goto INPUT_TARGET_SDK
)

:INPUT_MAX_SDK
set "MAX_SDK="
set /p "MAX_SDK=- maxSdkVersion (Optional, 'null' to remove): "
if "%MAX_SDK%"=="" goto INPUT_SMALI
if /i "%MAX_SDK%"=="null" goto INPUT_SMALI
powershell.exe -NoProfile -Command "if ('%MAX_SDK%' -notmatch '^[0-9]+$') { exit 1 }"
if errorlevel 1 (
    echo [ERROR] maxSdkVersion은 숫자이거나 'null'이어야 합니다.
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
    echo [ERROR] RepackApk.jar 파일을 찾을 수 없습니다: %REPACK_JAR%
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
