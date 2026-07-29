@echo off
setlocal EnableDelayedExpansion

:: ============================================================================
:: provision.bat - Bootstrap machine provisioning via mise + git
::
:: Ensures mise and git are available, fetches a remote repo (or uses a local
:: path), then executes .bat/.ps1 scripts from it on the current machine.
::
:: Usage:
::   provision.bat [repo_url_or_path] [script1.bat] [script2.ps1] ...
::
:: Arguments:
::   %1  - Git repo URL or local directory path (default: PLACEHOLDER_REPO_URL)
::   %2+ - Script file(s) relative to repo root (default: main.bat)
::
:: Examples:
::   provision.bat
::   provision.bat https://github.com/myorg/infra.git
::   provision.bat C:\projects\my-scripts setup.bat configure.ps1
::   provision.bat https://github.com/myorg/infra.git base.bat apps.ps1 dev.bat
:: ============================================================================

set "DEFAULT_REPO=PLACEHOLDER_REPO_URL"
set "DEFAULT_SCRIPT=main.bat"
set "EXITCODE=0"
set "TMPDIR="
set "REPO_PATH="

:: ---------------------------------------------------------------------------
:: Parse arguments
:: ---------------------------------------------------------------------------
set "SOURCE=%~1"
if "%SOURCE%"=="" set "SOURCE=%DEFAULT_REPO%"

:: Collect script arguments (shift past first arg)
set "SCRIPTS="
set "ARGIDX=0"
for %%a in (%*) do (
    if !ARGIDX! GEQ 1 (
        if defined SCRIPTS (
            set "SCRIPTS=!SCRIPTS! %%~a"
        ) else (
            set "SCRIPTS=%%~a"
        )
    )
    set /a ARGIDX+=1
)
if "%SCRIPTS%"=="" set "SCRIPTS=%DEFAULT_SCRIPT%"

echo [provision] Source:  %SOURCE%
echo [provision] Scripts: %SCRIPTS%
echo.

:: ---------------------------------------------------------------------------
:: Step 1: Ensure mise is installed
:: ---------------------------------------------------------------------------
echo [provision] Step 1/4: Checking mise...
where mise >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [provision]   Installing mise via winget...
    winget install jdx.mise --accept-source-agreements --accept-package-agreements
    if !ERRORLEVEL! NEQ 0 (
        echo [provision] ERROR: Failed to install mise via winget.
        exit /b 1
    )
    call :RefreshPath
    where mise >nul 2>&1
    if !ERRORLEVEL! NEQ 0 (
        echo [provision] ERROR: mise installed but not found in PATH.
        echo [provision]   Restart your terminal and re-run this script.
        exit /b 1
    )
)
echo [provision]   OK
echo.

:: ---------------------------------------------------------------------------
:: Step 2: Ensure git is available (via mise, fallback winget)
:: ---------------------------------------------------------------------------
echo [provision] Step 2/4: Checking git...
where git >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [provision]   git not found. Installing via winget...
    winget install Git.Git --accept-source-agreements --accept-package-agreements
    if !ERRORLEVEL! NEQ 0 (
        echo [provision] ERROR: Failed to install git.
        exit /b 1
    )
    call :RefreshPath
    where git >nul 2>&1
    if !ERRORLEVEL! NEQ 0 (
        echo [provision] ERROR: git installed but not found in PATH.
        exit /b 1
    )
)
echo [provision]   OK
echo.

:: ---------------------------------------------------------------------------
:: Step 3: Resolve source (local path or remote URL)
:: ---------------------------------------------------------------------------
echo [provision] Step 3/4: Resolving source...

:: Check if SOURCE is an existing local directory
if exist "%SOURCE%\." (
    echo [provision]   Using local directory: %SOURCE%
    set "REPO_PATH=%SOURCE%"
    goto :RunScripts
)

:: Otherwise treat as a git URL - clone to temp directory
echo [provision]   Cloning %SOURCE% ...
set "TMPDIR=%TEMP%\provision_%RANDOM%_%RANDOM%"

git clone --depth 1 "%SOURCE%" "%TMPDIR%"
if %ERRORLEVEL% NEQ 0 (
    echo [provision] ERROR: Failed to clone: %SOURCE%
    set "EXITCODE=1"
    goto :Cleanup
)
set "REPO_PATH=%TMPDIR%"
echo [provision]   Cloned to %TMPDIR%
echo.

:: ---------------------------------------------------------------------------
:: Step 4: Execute scripts
:: ---------------------------------------------------------------------------
:RunScripts
echo [provision] Step 4/4: Executing scripts...
echo.

for %%s in (%SCRIPTS%) do (
    call :ExecScript "%%s"
    if !EXITCODE! NEQ 0 goto :Cleanup
)

echo [provision] All scripts completed successfully.
goto :Cleanup

:: ---------------------------------------------------------------------------
:: Cleanup
:: ---------------------------------------------------------------------------
:Cleanup
if defined TMPDIR (
    if exist "%TMPDIR%\." (
        echo.
        echo [provision] Cleaning up temp directory...
        rmdir /s /q "%TMPDIR%" 2>nul
    )
)

if %EXITCODE% EQU 0 (
    echo.
    echo [provision] Provisioning completed successfully.
) else (
    echo.
    echo [provision] Provisioning FAILED (exit code %EXITCODE%).
)

exit /b %EXITCODE%

:: ============================================================================
:: Subroutines
:: ============================================================================

:RefreshPath
:: Rebuild PATH from registry (Machine + User) without restarting the shell
set "NEWPATH="
for /f "tokens=2*" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment" /v Path 2^>nul') do (
    set "NEWPATH=%%b"
)
for /f "tokens=2*" %%a in ('reg query "HKCU\Environment" /v Path 2^>nul') do (
    if defined NEWPATH (
        set "NEWPATH=!NEWPATH!;%%b"
    ) else (
        set "NEWPATH=%%b"
    )
)
if defined NEWPATH set "PATH=!NEWPATH!"
goto :eof

:ExecScript
:: Execute a single script file. Sets EXITCODE on failure.
:: %~1 = script filename relative to REPO_PATH
set "SCRIPT_NAME=%~1"
set "SCRIPT_FILE=%REPO_PATH%\%SCRIPT_NAME%"

if not exist "%SCRIPT_FILE%" (
    echo [provision] ERROR: Script not found: %SCRIPT_FILE%
    set "EXITCODE=1"
    goto :eof
)

echo [provision] --- %SCRIPT_NAME% ---

set "EXT=%~x1"
if /i "%EXT%"==".ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_FILE%"
) else if /i "%EXT%"==".bat" (
    call "%SCRIPT_FILE%"
) else if /i "%EXT%"==".cmd" (
    call "%SCRIPT_FILE%"
) else (
    echo [provision] WARNING: Unknown extension '%EXT%', attempting call...
    call "%SCRIPT_FILE%"
)

if %ERRORLEVEL% NEQ 0 (
    set "EXITCODE=%ERRORLEVEL%"
    echo [provision] ERROR: Script failed: %SCRIPT_NAME% [exit code %EXITCODE%]
    goto :eof
)
echo [provision] --- %SCRIPT_NAME% done ---
echo.
goto :eof
