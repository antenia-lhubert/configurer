:: Version: 2
@echo off
setlocal EnableDelayedExpansion

:: ============================================================================
:: configurer.bat - Module-based machine provisioning via git
::
:: Manages addons defined by .configurer.yml files. Addons declare a name,
:: version, entrypoint command string, optional source URL, and dependencies.
::
:: Usage:
::   configurer install <target>
::   configurer run <target> [args...]
::   configurer update [name]
::   configurer ls
::   configurer uninstall <name>
::
:: Subcommands:
::   install     Install an addon and its dependencies. Target can be a git URL,
::               GitHub browse URL (with subpath), local path, or addon name
::               (resolved from the official repo).
::
::   run         Execute an addon's entrypoint. Same resolution as install.
::               Missing dependencies are auto-installed before execution.
::               All arguments after the target are passed to the entrypoint.
::
::   update      Re-fetch and reinstall an addon if a newer version is available.
::               Without a name, updates all installed addons.
::
::   ls          List all installed addons with their versions.
::
::   uninstall   Remove an installed addon by name.
::
:: .configurer.yml format:
::   apiVersion: 1
::   name: my-addon
::   version: 1.0.0
::   entrypoint: powershell -NoProfile -ExecutionPolicy Bypass -File main.ps1
::   source: https://github.com/org/addons/tree/main/my-addon
::   dependencies:
::     - core-utils
::     - network-tools@2.0.0
::
:: Resolution order (install/run/deps):
::   1. GitHub subpath URL (/tree/<branch>/<path> or abbreviated)
::   2. Regular git URL (contains :// or ends with .git)
::   3. Local directory path
::   4. Installed addon name (run only)
::   5. Official mono-repo fallback (clone repo, look for <name>/ at root)
::
:: Examples:
::   configurer install https://github.com/org/addons/tree/main/my-addon
::   configurer install my-addon
::   configurer run my-addon --verbose
::   configurer update
::   configurer update my-addon
::   configurer ls
::   configurer uninstall my-addon
:: ============================================================================

set "SCRIPT_URL=https://raw.githubusercontent.com/antenia-lhubert/env-configurer/main/configurer.bat"
set "OFFICIAL_REPO=PLACEHOLDER_OFFICIAL_REPO_URL"
set "INSTALL_DIR=%USERPROFILE%\.config\configurer\installed"
set "COMMANDS_DIR=%USERPROFILE%\.config\configurer\commands"
set "EXITCODE=0"
set "TMPDIR="
set "UPDATE_IN_PROGRESS=0"
set "VISITED_DEPS="

:: ---------------------------------------------------------------------------
:: Parse arguments using shift (preserves = signs in args)
:: ---------------------------------------------------------------------------
set "SELF_UPDATE=1"
set "SUBCMD="
set "TARGET="
set "PASSTHROUGH_ARGS="

:ParseArgs
if "%~1"=="" goto :DoneParsing
if /i "%~1"=="--no-update" (
    set "SELF_UPDATE=0"
    shift
    goto :ParseArgs
)
if not defined SUBCMD (
    set "SUBCMD=%~1"
    shift
    goto :ParseArgs
)
if not defined TARGET (
    set "TARGET=%~1"
    shift
    goto :ParseArgs
)
if defined PASSTHROUGH_ARGS (
    set "PASSTHROUGH_ARGS=!PASSTHROUGH_ARGS! %1"
) else (
    set "PASSTHROUGH_ARGS=%1"
)
shift
goto :ParseArgs
:DoneParsing

:: ---------------------------------------------------------------------------
:: Self-update check
:: ---------------------------------------------------------------------------
if "%SELF_UPDATE%"=="1" call :SelfUpdate
if "!UPDATE_IN_PROGRESS!"=="1" exit /b 0

:: ---------------------------------------------------------------------------
:: Validate and dispatch subcommand
:: ---------------------------------------------------------------------------
if not defined SUBCMD goto :ShowUsage
if /i "!SUBCMD!"=="ls" goto :CmdLs
if /i "!SUBCMD!"=="uninstall" goto :CmdUninstall
if /i "!SUBCMD!"=="install" goto :PreGit
if /i "!SUBCMD!"=="run" goto :PreGit
if /i "!SUBCMD!"=="update" goto :PreGit
goto :ShowUsage

:: ---------------------------------------------------------------------------
:: Ensure git is available
:: ---------------------------------------------------------------------------
:PreGit
echo [configurer] Checking git...
where git >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo [configurer]   git not found. Installing via winget...
    winget install Git.Git --accept-source-agreements --accept-package-agreements
    if !ERRORLEVEL! NEQ 0 (
        echo [configurer] ERROR: Failed to install git.
        exit /b 1
    )
    call :RefreshPath
    where git >nul 2>&1
    if !ERRORLEVEL! NEQ 0 (
        echo [configurer] ERROR: git installed but not found in PATH.
        exit /b 1
    )
)
echo [configurer]   git OK
echo.

if /i "!SUBCMD!"=="install" goto :CmdInstall
if /i "!SUBCMD!"=="run" goto :CmdRun
if /i "!SUBCMD!"=="update" goto :CmdUpdate

:: ===========================================================================
:: LS subcommand
:: ===========================================================================
:CmdLs
if not exist "%INSTALL_DIR%\." (
    echo No addons installed.
    exit /b 0
)
set "FOUND_ANY=0"
for /d %%d in ("%INSTALL_DIR%\*") do (
    set "FOUND_ANY=1"
    call :LsAddon "%%d"
)
if "!FOUND_ANY!"=="0" echo No addons installed.
exit /b 0

:LsAddon
set "ADDON_NAME="
set "ADDON_VERSION="
set "ADDON_SOURCE="
call :ParseYmlQuiet "%~1"
set "LS_DIR=%~nx1"
if defined ADDON_VERSION (
    if defined ADDON_SOURCE (
        echo   !LS_DIR!  v!ADDON_VERSION!  [!ADDON_SOURCE!]
    ) else (
        echo   !LS_DIR!  v!ADDON_VERSION!
    )
) else (
    echo   !LS_DIR!  [no valid manifest]
)
goto :eof

:: ===========================================================================
:: UNINSTALL subcommand
:: ===========================================================================
:CmdUninstall
if not defined TARGET (
    echo [configurer] ERROR: No addon name specified.
    echo Usage: configurer uninstall ^<name^>
    exit /b 1
)
if not exist "%INSTALL_DIR%\%TARGET%\." (
    echo [configurer] ERROR: Addon '%TARGET%' is not installed.
    if exist "%INSTALL_DIR%\." (
        echo [configurer] Installed addons:
        for /d %%d in ("%INSTALL_DIR%\*") do echo [configurer]   - %%~nxd
    )
    exit /b 1
)
rmdir /s /q "%INSTALL_DIR%\%TARGET%" 2>nul
if exist "%INSTALL_DIR%\%TARGET%\." (
    echo [configurer] ERROR: Failed to remove '%TARGET%'.
    exit /b 1
)
if exist "%COMMANDS_DIR%\%TARGET%.bat" del "%COMMANDS_DIR%\%TARGET%.bat" 2>nul
echo [configurer] Addon '%TARGET%' uninstalled.
exit /b 0

:: ===========================================================================
:: INSTALL subcommand
:: ===========================================================================
:CmdInstall
if not defined TARGET (
    echo [configurer] ERROR: No target specified.
    echo.
    goto :ShowUsage
)
echo [configurer] Installing addon: %TARGET%
echo.

set "RESOLVED_PATH="
set "RESOLVE_TMPDIR="
call :Resolve "%TARGET%" "install"
if !EXITCODE! NEQ 0 goto :Cleanup

echo [configurer] Validating .configurer.yml...
set "ADDON_NAME="
set "ADDON_VERSION="
set "ADDON_ENTRYPOINT="
set "ADDON_SOURCE="
set "ADDON_DEPS="
call :ParseYml "!RESOLVED_PATH!"
if !EXITCODE! NEQ 0 (
    call :CleanupResolve
    goto :Cleanup
)
if not defined ADDON_NAME (
    echo [configurer] ERROR: Failed to parse .configurer.yml
    set "EXITCODE=1"
    call :CleanupResolve
    goto :Cleanup
)

echo [configurer]   Name:       !ADDON_NAME!
echo [configurer]   Version:    !ADDON_VERSION!
echo [configurer]   Entrypoint: !ADDON_ENTRYPOINT!
if defined ADDON_SOURCE echo [configurer]   Source:     !ADDON_SOURCE!
if defined ADDON_DEPS echo [configurer]   Deps:       !ADDON_DEPS!
echo.

call :InstallAddon "!RESOLVED_PATH!" "!ADDON_NAME!"
call :CleanupResolve
if !EXITCODE! NEQ 0 goto :Cleanup

echo [configurer] Successfully installed '!ADDON_NAME!' v!ADDON_VERSION!
echo.

:: Create command shim and ensure PATH
call :CreateShim "!ADDON_NAME!"
call :EnsureCommandsInPath

if not defined ADDON_DEPS goto :CmdInstall_Done
echo [configurer] Resolving dependencies...
set "VISITED_DEPS=!ADDON_NAME!"
call :ResolveDeps "%INSTALL_DIR%\!ADDON_NAME!"
if !EXITCODE! NEQ 0 (
    echo [configurer] WARNING: Some dependencies could not be resolved.
) else (
    echo [configurer] All dependencies satisfied.
)
:CmdInstall_Done
goto :Cleanup

:: ===========================================================================
:: RUN subcommand
:: ===========================================================================
:CmdRun
if not defined TARGET (
    echo [configurer] ERROR: No target specified.
    echo.
    goto :ShowUsage
)
echo [configurer] Resolving addon: %TARGET%
echo.

set "RESOLVED_PATH="
set "RESOLVE_TMPDIR="
call :Resolve "%TARGET%" "run"
if !EXITCODE! NEQ 0 goto :Cleanup

set "RUN_PATH=!RESOLVED_PATH!"
if defined RESOLVE_TMPDIR set "TMPDIR=!RESOLVE_TMPDIR!"

echo [configurer] Reading .configurer.yml...
set "ADDON_NAME="
set "ADDON_VERSION="
set "ADDON_ENTRYPOINT="
set "ADDON_SOURCE="
set "ADDON_DEPS="
call :ParseYml "!RUN_PATH!"
if !EXITCODE! NEQ 0 goto :Cleanup

if not defined ADDON_ENTRYPOINT (
    echo [configurer] ERROR: Failed to parse .configurer.yml
    set "EXITCODE=1"
    goto :Cleanup
)

if not defined ADDON_DEPS goto :CmdRun_Exec
echo [configurer] Checking dependencies...
set "VISITED_DEPS=!ADDON_NAME!"
set "SAVE_RUN_NAME=!ADDON_NAME!"
set "SAVE_RUN_VER=!ADDON_VERSION!"
set "SAVE_RUN_EP=!ADDON_ENTRYPOINT!"
call :ResolveDeps "!RUN_PATH!"
set "ADDON_NAME=!SAVE_RUN_NAME!"
set "ADDON_VERSION=!SAVE_RUN_VER!"
set "ADDON_ENTRYPOINT=!SAVE_RUN_EP!"
if !EXITCODE! NEQ 0 (
    echo [configurer] ERROR: Failed to resolve dependencies.
    goto :Cleanup
)
echo [configurer] Dependencies OK.
echo.

:CmdRun_Exec
echo [configurer] Running '!ADDON_NAME!' v!ADDON_VERSION!
echo [configurer] Entrypoint: !ADDON_ENTRYPOINT!
if defined PASSTHROUGH_ARGS echo [configurer] Args: !PASSTHROUGH_ARGS!
echo.

pushd "!RUN_PATH!"
cmd /c !ADDON_ENTRYPOINT! !PASSTHROUGH_ARGS!
set "EXITCODE=!ERRORLEVEL!"
popd

if !EXITCODE! NEQ 0 (
    echo.
    echo [configurer] ERROR: Addon '!ADDON_NAME!' exited with code !EXITCODE!
) else (
    echo.
    echo [configurer] Addon '!ADDON_NAME!' completed successfully.
)
goto :Cleanup

:: ===========================================================================
:: UPDATE subcommand
:: ===========================================================================
:CmdUpdate
if not exist "%INSTALL_DIR%\." (
    echo [configurer] No addons installed. Nothing to update.
    exit /b 0
)

if defined TARGET (
    if not exist "%INSTALL_DIR%\%TARGET%\." (
        echo [configurer] ERROR: Addon '%TARGET%' is not installed.
        exit /b 1
    )
    call :UpdateAddon "%TARGET%"
    goto :Cleanup
)

echo [configurer] Updating all installed addons...
echo.
set "UPD_COUNT=0"
set "UPD_SKIP=0"
set "UPD_FAIL=0"
for /d %%d in ("%INSTALL_DIR%\*") do (
    call :UpdateAddon "%%~nxd"
    if !EXITCODE! EQU 0 set /a UPD_COUNT+=1
    if !EXITCODE! EQU 2 set /a UPD_SKIP+=1
    set "EXITCODE=0"
)
echo.
echo [configurer] Done. !UPD_COUNT! updated, !UPD_SKIP! already current, !UPD_FAIL! failed.
set "EXITCODE=0"
goto :Cleanup

:: ---------------------------------------------------------------------------
:: Usage
:: ---------------------------------------------------------------------------
:ShowUsage
echo Usage:
echo   configurer install ^<target^>
echo   configurer run ^<target^> [args...]
echo   configurer update [name]
echo   configurer ls
echo   configurer uninstall ^<name^>
echo.
echo Subcommands:
echo   install     Install an addon and its dependencies.
echo   run         Run an addon. Args after target are passed to entrypoint.
echo   update      Update one or all installed addons.
echo   ls          List installed addons.
echo   uninstall   Remove an installed addon.
echo.
echo Target resolution:
echo   GitHub URL with subpath, git URL, local path, installed name,
echo   or addon name from the official repo.
echo.
echo Addon store: %INSTALL_DIR%
echo.
echo .configurer.yml format:
echo   apiVersion: 1
echo   name: my-addon
echo   version: 1.0.0
echo   entrypoint: powershell -File main.ps1
echo   source: https://github.com/org/addons/tree/main/my-addon
echo   dependencies:
echo     - core-utils
echo     - other-addon@1.2.0
set "EXITCODE=1"
goto :Cleanup

:: ---------------------------------------------------------------------------
:: Cleanup
:: ---------------------------------------------------------------------------
:Cleanup
if defined TMPDIR (
    if exist "!TMPDIR!\." (
        echo.
        echo [configurer] Cleaning up temp directory...
        rmdir /s /q "!TMPDIR!" 2>nul
    )
)
exit /b %EXITCODE%

:: ============================================================================
:: SUBROUTINES
:: ============================================================================

:: ---------------------------------------------------------------------------
:: :Resolve - Unified target resolution (flat structure, no nested blocks)
:: Sets RESOLVED_PATH and optionally RESOLVE_TMPDIR
:: %~1 = target, %~2 = context (install/run/dep)
:: ---------------------------------------------------------------------------
:Resolve
set "RESOLVE_INPUT=%~1"
set "RESOLVE_CTX=%~2"
set "RESOLVED_PATH="
set "RESOLVE_TMPDIR="
set "RESOLVE_REPO_URL="
set "RESOLVE_BRANCH="
set "RESOLVE_SUBPATH="

:: Step 1: Check GitHub URL with subpath
echo "!RESOLVE_INPUT!" | findstr /i "github.com" >nul 2>&1
if !ERRORLEVEL! NEQ 0 goto :Resolve_CheckUrl
call :ParseGitHubUrl "!RESOLVE_INPUT!"
if not defined RESOLVE_SUBPATH goto :Resolve_CheckUrl

:: GitHub subpath - clone and extract
echo [configurer]   GitHub subpath detected: !RESOLVE_SUBPATH!
set "RESOLVE_TMPDIR=%TEMP%\configurer_%RANDOM%_%RANDOM%"
if defined RESOLVE_BRANCH (
    git clone --depth 1 --branch "!RESOLVE_BRANCH!" "!RESOLVE_REPO_URL!" "!RESOLVE_TMPDIR!" >nul 2>&1
) else (
    git clone --depth 1 "!RESOLVE_REPO_URL!" "!RESOLVE_TMPDIR!" >nul 2>&1
)
if !ERRORLEVEL! NEQ 0 (
    echo [configurer] ERROR: Failed to clone: !RESOLVE_REPO_URL!
    set "RESOLVE_TMPDIR="
    set "EXITCODE=1"
    goto :eof
)
if not exist "!RESOLVE_TMPDIR!\!RESOLVE_SUBPATH!\." (
    echo [configurer] ERROR: Subpath '!RESOLVE_SUBPATH!' not found in repo.
    rmdir /s /q "!RESOLVE_TMPDIR!" 2>nul
    set "RESOLVE_TMPDIR="
    set "EXITCODE=1"
    goto :eof
)
set "RESOLVED_PATH=!RESOLVE_TMPDIR!\!RESOLVE_SUBPATH!"
goto :eof

:Resolve_CheckUrl
:: Step 2: Regular git URL
echo "!RESOLVE_INPUT!" | findstr /i "://" >nul 2>&1
if !ERRORLEVEL! EQU 0 goto :Resolve_Clone
echo "!RESOLVE_INPUT!" | findstr /i "\.git$" >nul 2>&1
if !ERRORLEVEL! EQU 0 goto :Resolve_Clone
goto :Resolve_Local

:Resolve_Clone
echo [configurer]   Cloning !RESOLVE_INPUT! ...
set "RESOLVE_TMPDIR=%TEMP%\configurer_%RANDOM%_%RANDOM%"
git clone --depth 1 "!RESOLVE_INPUT!" "!RESOLVE_TMPDIR!" >nul 2>&1
if !ERRORLEVEL! NEQ 0 (
    echo [configurer] ERROR: Failed to clone: !RESOLVE_INPUT!
    set "RESOLVE_TMPDIR="
    set "EXITCODE=1"
    goto :eof
)
set "RESOLVED_PATH=!RESOLVE_TMPDIR!"
echo [configurer]   Cloned to temporary directory.
goto :eof

:Resolve_Local
:: Step 3: Local directory
if exist "!RESOLVE_INPUT!\." (
    echo [configurer]   Using local directory: !RESOLVE_INPUT!
    set "RESOLVED_PATH=!RESOLVE_INPUT!"
    goto :eof
)

:: Step 4: Installed addon name (run/dep contexts)
if /i "!RESOLVE_CTX!"=="run" goto :Resolve_CheckInstalled
if /i "!RESOLVE_CTX!"=="dep" goto :Resolve_CheckInstalled
goto :Resolve_Official

:Resolve_CheckInstalled
if not exist "%INSTALL_DIR%\!RESOLVE_INPUT!\." goto :Resolve_Official
echo [configurer]   Using installed addon: !RESOLVE_INPUT!
set "RESOLVED_PATH=%INSTALL_DIR%\!RESOLVE_INPUT!"
goto :eof

:Resolve_Official
:: Step 5: Official mono-repo fallback
echo [configurer]   Trying official repo for '!RESOLVE_INPUT!'...
set "RESOLVE_TMPDIR=%TEMP%\configurer_%RANDOM%_%RANDOM%"
git clone --depth 1 "!OFFICIAL_REPO!" "!RESOLVE_TMPDIR!" >nul 2>&1
if !ERRORLEVEL! NEQ 0 (
    echo [configurer] ERROR: Failed to clone official repo.
    set "RESOLVE_TMPDIR="
    set "EXITCODE=1"
    goto :eof
)
if not exist "!RESOLVE_TMPDIR!\!RESOLVE_INPUT!\." (
    echo [configurer] ERROR: '!RESOLVE_INPUT!' not found in official repo.
    rmdir /s /q "!RESOLVE_TMPDIR!" 2>nul
    set "RESOLVE_TMPDIR="
    set "EXITCODE=1"
    goto :eof
)
set "RESOLVED_PATH=!RESOLVE_TMPDIR!\!RESOLVE_INPUT!"
echo [configurer]   Found '!RESOLVE_INPUT!' in official repo.
goto :eof

:: ---------------------------------------------------------------------------
:: :ParseGitHubUrl - Parse GitHub URL into repo, branch, subpath
:: Sets RESOLVE_REPO_URL, RESOLVE_BRANCH, RESOLVE_SUBPATH
:: %~1 = URL
:: ---------------------------------------------------------------------------
:ParseGitHubUrl
set "GH_URL=%~1"
set "RESOLVE_REPO_URL="
set "RESOLVE_BRANCH="
set "RESOLVE_SUBPATH="
set "GH_PS=%TEMP%\configurer_gh_%RANDOM%.ps1"
set "GH_OUT=%TEMP%\configurer_gh_%RANDOM%.txt"

> "!GH_PS!" echo $url = '!GH_URL!'
>> "!GH_PS!" echo $excluded = @('issues','pulls','actions','blob','releases','settings','wiki','commit','commits','tags','branches','pull','compare')
>> "!GH_PS!" echo if ($url -match '^^https?://github\.com/([^^/]+)/([^^/]+)/tree/([^^/]+)/(.+)$') {
>> "!GH_PS!" echo     $org = $Matches[1]; $repo = $Matches[2] -replace '\.git$',''
>> "!GH_PS!" echo     Write-Output "REPO=https://github.com/$org/$repo.git"
>> "!GH_PS!" echo     Write-Output "BRANCH=$($Matches[3])"
>> "!GH_PS!" echo     Write-Output "SUBPATH=$($Matches[4] -replace '/$','')"
>> "!GH_PS!" echo } elseif ($url -match '^^https?://github\.com/([^^/]+)/([^^/]+)/(.+)$') {
>> "!GH_PS!" echo     $org = $Matches[1]; $repo = $Matches[2] -replace '\.git$',''; $rest = $Matches[3] -replace '/$',''
>> "!GH_PS!" echo     $firstSeg = ($rest -split '/')[0]
>> "!GH_PS!" echo     if ($excluded -notcontains $firstSeg) {
>> "!GH_PS!" echo         Write-Output "REPO=https://github.com/$org/$repo.git"
>> "!GH_PS!" echo         Write-Output "SUBPATH=$rest"
>> "!GH_PS!" echo     }
>> "!GH_PS!" echo }

powershell -NoProfile -ExecutionPolicy Bypass -File "!GH_PS!" > "!GH_OUT!" 2>nul

for /f "usebackq tokens=1,* delims==" %%A in ("!GH_OUT!") do (
    if /i "%%A"=="REPO" set "RESOLVE_REPO_URL=%%B"
    if /i "%%A"=="BRANCH" set "RESOLVE_BRANCH=%%B"
    if /i "%%A"=="SUBPATH" set "RESOLVE_SUBPATH=%%B"
)
del "!GH_PS!" 2>nul
del "!GH_OUT!" 2>nul
goto :eof

:: ---------------------------------------------------------------------------
:: :CleanupResolve - Clean RESOLVE_TMPDIR
:: ---------------------------------------------------------------------------
:CleanupResolve
if defined RESOLVE_TMPDIR (
    if exist "!RESOLVE_TMPDIR!\." rmdir /s /q "!RESOLVE_TMPDIR!" 2>nul
    set "RESOLVE_TMPDIR="
)
goto :eof

:: ---------------------------------------------------------------------------
:: :InstallAddon - Copy addon to install directory
:: %~1 = source path, %~2 = addon name
:: ---------------------------------------------------------------------------
:InstallAddon
set "IA_SRC=%~1"
set "IA_NAME=%~2"
set "IA_DEST=%INSTALL_DIR%\!IA_NAME!"

if exist "!IA_DEST!\." rmdir /s /q "!IA_DEST!" 2>nul
if not exist "%INSTALL_DIR%\." mkdir "%INSTALL_DIR%"
xcopy "!IA_SRC!\*" "!IA_DEST!\" /E /I /Q /Y >nul
if !ERRORLEVEL! NEQ 0 (
    echo [configurer] ERROR: Failed to copy addon files for '!IA_NAME!'.
    set "EXITCODE=1"
    goto :eof
)
if exist "!IA_DEST!\.git\." rmdir /s /q "!IA_DEST!\.git" 2>nul
goto :eof

:: ---------------------------------------------------------------------------
:: :UpdateAddon - Update a single installed addon
:: EXITCODE: 0=updated, 2=already current, 1=error
:: %~1 = addon name
:: ---------------------------------------------------------------------------
:UpdateAddon
set "UA_NAME=%~1"
set "UA_DIR=%INSTALL_DIR%\!UA_NAME!"
set "EXITCODE=0"
echo [configurer] Checking '!UA_NAME!'...

set "ADDON_NAME="
set "ADDON_VERSION="
set "ADDON_SOURCE="
set "ADDON_DEPS="
call :ParseYmlQuiet "!UA_DIR!"

if not defined ADDON_VERSION (
    echo [configurer]   WARNING: Cannot read version for '!UA_NAME!'. Skipping.
    set "EXITCODE=2"
    goto :eof
)
set "UA_INSTALLED_VER=!ADDON_VERSION!"
set "UA_FETCH=!ADDON_SOURCE!"
if not defined UA_FETCH set "UA_FETCH=!UA_NAME!"

:: Fetch remote
set "RESOLVED_PATH="
set "RESOLVE_TMPDIR="
call :Resolve "!UA_FETCH!" "install"
if !EXITCODE! NEQ 0 (
    echo [configurer]   ERROR: Failed to fetch update for '!UA_NAME!'.
    call :CleanupResolve
    set "EXITCODE=1"
    goto :eof
)

:: Read remote version
set "ADDON_VERSION="
call :ParseYmlQuiet "!RESOLVED_PATH!"
if not defined ADDON_VERSION (
    echo [configurer]   WARNING: Cannot read remote version for '!UA_NAME!'. Skipping.
    call :CleanupResolve
    set "EXITCODE=2"
    goto :eof
)
set "UA_REMOTE_VER=!ADDON_VERSION!"

:: Compare versions
set "VER_RESULT="
call :VersionGt "!UA_REMOTE_VER!" "!UA_INSTALLED_VER!"

if "!VER_RESULT!"=="no" (
    echo [configurer]   '!UA_NAME!' already up-to-date v!UA_INSTALLED_VER!
    call :CleanupResolve
    set "EXITCODE=2"
    goto :eof
)

echo [configurer]   Updating '!UA_NAME!' v!UA_INSTALLED_VER! -^> v!UA_REMOTE_VER!
call :InstallAddon "!RESOLVED_PATH!" "!UA_NAME!"
call :CleanupResolve
if !EXITCODE! NEQ 0 goto :eof

:: Check dep constraints after update
if not defined ADDON_DEPS goto :UpdateAddon_Done
set "VISITED_DEPS=!UA_NAME!"
call :ResolveDeps "%INSTALL_DIR%\!UA_NAME!"
:UpdateAddon_Done
call :CreateShim "!UA_NAME!"
echo [configurer]   '!UA_NAME!' updated to v!UA_REMOTE_VER!
set "EXITCODE=0"
goto :eof

:: ---------------------------------------------------------------------------
:: :ResolveDeps - Recursively resolve and install dependencies
:: %~1 = addon directory
:: ---------------------------------------------------------------------------
:ResolveDeps
set "RD_DIR=%~1"

set "ADDON_NAME="
set "ADDON_VERSION="
set "ADDON_DEPS="
call :ParseYmlQuiet "!RD_DIR!"
if not defined ADDON_DEPS goto :eof

:: Process each dependency by calling a sub-handler
for %%D in (!ADDON_DEPS!) do (
    call :ProcessOneDep "%%D"
    if !EXITCODE! NEQ 0 goto :eof
)
goto :eof

:: ---------------------------------------------------------------------------
:: :ProcessOneDep - Handle a single dependency entry
:: %~1 = dep spec (name or name@version)
:: ---------------------------------------------------------------------------
:ProcessOneDep
set "DEP_SPEC=%~1"
set "DEP_NAME="
set "DEP_MINVER="

:: Split name@version
for /f "tokens=1,2 delims=@" %%A in ("!DEP_SPEC!") do (
    set "DEP_NAME=%%A"
    set "DEP_MINVER=%%B"
)

:: Cycle detection
echo " !VISITED_DEPS! " | findstr /c:" !DEP_NAME! " >nul 2>&1
if !ERRORLEVEL! EQU 0 goto :eof
set "VISITED_DEPS=!VISITED_DEPS! !DEP_NAME!"

:: Check if installed
if not exist "%INSTALL_DIR%\!DEP_NAME!\." goto :ProcessOneDep_Install

:: Already installed - check version constraint
if not defined DEP_MINVER (
    echo [configurer]   Dependency '!DEP_NAME!' OK.
    goto :ProcessOneDep_Recurse
)

:: Read installed addon info
set "ADDON_NAME="
set "ADDON_VERSION="
set "ADDON_SOURCE="
call :ParseYmlQuiet "%INSTALL_DIR%\!DEP_NAME!"
set "DEP_INST_VER=!ADDON_VERSION!"

:: Compare versions
set "VER_RESULT="
call :VersionGe "!DEP_INST_VER!" "!DEP_MINVER!"
if "!VER_RESULT!"=="yes" (
    echo [configurer]   Dependency '!DEP_NAME!' v!DEP_INST_VER! OK.
    goto :ProcessOneDep_Recurse
)

:: Version too low - update
echo [configurer]   Dependency '!DEP_NAME!' v!DEP_INST_VER! below required v!DEP_MINVER!. Updating...
set "DEP_FETCH=!ADDON_SOURCE!"
if not defined DEP_FETCH set "DEP_FETCH=!DEP_NAME!"
goto :ProcessOneDep_DoInstall

:ProcessOneDep_Install
echo [configurer]   Installing dependency '!DEP_NAME!'...
set "DEP_FETCH=!DEP_NAME!"

:ProcessOneDep_DoInstall
set "RESOLVED_PATH="
set "RESOLVE_TMPDIR="
call :Resolve "!DEP_FETCH!" "install"
if !EXITCODE! NEQ 0 (
    echo [configurer]   ERROR: Failed to resolve dependency '!DEP_NAME!'.
    call :CleanupResolve
    goto :eof
)
call :InstallAddon "!RESOLVED_PATH!" "!DEP_NAME!"
call :CleanupResolve
if !EXITCODE! NEQ 0 goto :eof
echo [configurer]   Dependency '!DEP_NAME!' installed.

:ProcessOneDep_Recurse
:: Recurse into this dep's own dependencies
call :ResolveDeps "%INSTALL_DIR%\!DEP_NAME!"
goto :eof

:: ---------------------------------------------------------------------------
:: :ParseYml - Full parse with validation (errors printed)
:: Sets ADDON_NAME, ADDON_VERSION, ADDON_ENTRYPOINT, ADDON_SOURCE, ADDON_DEPS
:: %~1 = directory
:: ---------------------------------------------------------------------------
:ParseYml
set "YML_DIR=%~1"
set "PS_TEMP=%TEMP%\configurer_parse_%RANDOM%.ps1"
set "YML_OUT=%TEMP%\configurer_ymlout_%RANDOM%.txt"

call :WriteYmlParser "!PS_TEMP!" "!YML_DIR!" "validate"
powershell -NoProfile -ExecutionPolicy Bypass -File "!PS_TEMP!" > "!YML_OUT!" 2>&1

set "ADDON_NAME="
set "ADDON_VERSION="
set "ADDON_ENTRYPOINT="
set "ADDON_SOURCE="
set "ADDON_DEPS="
for /f "usebackq tokens=1,* delims==" %%A in ("!YML_OUT!") do (
    if /i "%%A"=="ERROR" (
        echo [configurer] ERROR: %%B
        set "EXITCODE=1"
    )
    if /i "%%A"=="NAME" set "ADDON_NAME=%%B"
    if /i "%%A"=="VERSION" set "ADDON_VERSION=%%B"
    if /i "%%A"=="ENTRYPOINT" set "ADDON_ENTRYPOINT=%%B"
    if /i "%%A"=="SOURCE" set "ADDON_SOURCE=%%B"
    if /i "%%A"=="DEPS" set "ADDON_DEPS=%%B"
)

del "!PS_TEMP!" 2>nul
del "!YML_OUT!" 2>nul
goto :eof

:: ---------------------------------------------------------------------------
:: :ParseYmlQuiet - Parse without validation errors
:: %~1 = directory
:: ---------------------------------------------------------------------------
:ParseYmlQuiet
set "YML_DIR=%~1"
set "PS_TEMP=%TEMP%\configurer_parse_%RANDOM%.ps1"
set "YML_OUT=%TEMP%\configurer_ymlout_%RANDOM%.txt"

call :WriteYmlParser "!PS_TEMP!" "!YML_DIR!" "quiet"
powershell -NoProfile -ExecutionPolicy Bypass -File "!PS_TEMP!" > "!YML_OUT!" 2>&1

set "ADDON_NAME="
set "ADDON_VERSION="
set "ADDON_ENTRYPOINT="
set "ADDON_SOURCE="
set "ADDON_DEPS="
for /f "usebackq tokens=1,* delims==" %%A in ("!YML_OUT!") do (
    if /i "%%A"=="NAME" set "ADDON_NAME=%%B"
    if /i "%%A"=="VERSION" set "ADDON_VERSION=%%B"
    if /i "%%A"=="ENTRYPOINT" set "ADDON_ENTRYPOINT=%%B"
    if /i "%%A"=="SOURCE" set "ADDON_SOURCE=%%B"
    if /i "%%A"=="DEPS" set "ADDON_DEPS=%%B"
)

del "!PS_TEMP!" 2>nul
del "!YML_OUT!" 2>nul
goto :eof

:: ---------------------------------------------------------------------------
:: :WriteYmlParser - Write the PowerShell YAML parser script to a file
:: %~1 = output ps1 path, %~2 = yml directory, %~3 = mode (validate/quiet)
:: ---------------------------------------------------------------------------
:WriteYmlParser
set "WYP_FILE=%~1"
set "WYP_DIR=%~2"
set "WYP_MODE=%~3"

> "!WYP_FILE!" echo $ymlPath = '!WYP_DIR!\.configurer.yml'
>> "!WYP_FILE!" echo if (-not (Test-Path $ymlPath)) {
if /i "!WYP_MODE!"=="quiet" goto :WYP_Skip1
>> "!WYP_FILE!" echo     Write-Output 'ERROR=File .configurer.yml not found'
:WYP_Skip1
>> "!WYP_FILE!" echo     exit 1
>> "!WYP_FILE!" echo }
>> "!WYP_FILE!" echo $content = Get-Content $ymlPath -Raw
>> "!WYP_FILE!" echo $apiVersion = ''; $name = ''; $version = ''; $entrypoint = ''; $source = ''
>> "!WYP_FILE!" echo $deps = @()
>> "!WYP_FILE!" echo $inDeps = $false
>> "!WYP_FILE!" echo foreach ($line in ($content -split "`n")) {
>> "!WYP_FILE!" echo     $trimmed = $line.Trim()
>> "!WYP_FILE!" echo     if ($trimmed -match '^apiVersion:\s*(.+)$') { $apiVersion = $Matches[1].Trim(); $inDeps = $false }
>> "!WYP_FILE!" echo     elseif ($trimmed -match '^name:\s*(.+)$') { $name = $Matches[1].Trim(); $inDeps = $false }
>> "!WYP_FILE!" echo     elseif ($trimmed -match '^version:\s*(.+)$') { $version = $Matches[1].Trim(); $inDeps = $false }
>> "!WYP_FILE!" echo     elseif ($trimmed -match '^entrypoint:\s*(.+)$') { $entrypoint = $Matches[1].Trim(); $inDeps = $false }
>> "!WYP_FILE!" echo     elseif ($trimmed -match '^source:\s*(.+)$') { $source = $Matches[1].Trim(); $inDeps = $false }
>> "!WYP_FILE!" echo     elseif ($trimmed -match '^dependencies:\s*$') { $inDeps = $true }
>> "!WYP_FILE!" echo     elseif ($inDeps -and $trimmed -match '^\-\s*(.+)$') { $deps += $Matches[1].Trim() }
>> "!WYP_FILE!" echo     elseif ($trimmed -ne '' -and $trimmed -notmatch '^\#') { $inDeps = $false }
>> "!WYP_FILE!" echo }
if /i "!WYP_MODE!"=="quiet" goto :WYP_Skip2
>> "!WYP_FILE!" echo if (-not $apiVersion) { Write-Output 'ERROR=Missing required field: apiVersion'; exit 1 }
>> "!WYP_FILE!" echo if ($apiVersion -ne '1') { Write-Output "ERROR=Unsupported apiVersion: $apiVersion - expected 1"; exit 1 }
>> "!WYP_FILE!" echo if (-not $name) { Write-Output 'ERROR=Missing required field: name'; exit 1 }
>> "!WYP_FILE!" echo if (-not $version) { Write-Output 'ERROR=Missing required field: version'; exit 1 }
>> "!WYP_FILE!" echo if (-not $entrypoint) { Write-Output 'ERROR=Missing required field: entrypoint'; exit 1 }
:WYP_Skip2
>> "!WYP_FILE!" echo if ($name) { Write-Output "NAME=$name" }
>> "!WYP_FILE!" echo if ($version) { Write-Output "VERSION=$version" }
>> "!WYP_FILE!" echo if ($entrypoint) { Write-Output "ENTRYPOINT=$entrypoint" }
>> "!WYP_FILE!" echo if ($source) { Write-Output "SOURCE=$source" }
>> "!WYP_FILE!" echo if ($deps.Count -gt 0) { Write-Output "DEPS=$($deps -join ' ')" }
goto :eof

:: ---------------------------------------------------------------------------
:: :CreateShim - Create a command shim .bat for an addon
:: %~1 = addon name
:: ---------------------------------------------------------------------------
:CreateShim
set "SHIM_NAME=%~1"
if not defined SHIM_NAME goto :eof
if not exist "!COMMANDS_DIR!\." mkdir "!COMMANDS_DIR!"
> "!COMMANDS_DIR!\!SHIM_NAME!.bat" echo @echo off
>> "!COMMANDS_DIR!\!SHIM_NAME!.bat" echo configurer run !SHIM_NAME! %%*
goto :eof

:: ---------------------------------------------------------------------------
:: :EnsureCommandsInPath - Add COMMANDS_DIR to user PATH if not already present
:: ---------------------------------------------------------------------------
:EnsureCommandsInPath
set "ECP_PS=%TEMP%\configurer_path_%RANDOM%.ps1"
> "!ECP_PS!" echo $cmdsDir = '!COMMANDS_DIR!'
>> "!ECP_PS!" echo $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
>> "!ECP_PS!" echo if ($userPath -and $userPath.ToLower().Contains($cmdsDir.ToLower())) { Write-Output 'ALREADY' }
>> "!ECP_PS!" echo else {
>> "!ECP_PS!" echo     $newPath = if ($userPath) { "$userPath;$cmdsDir" } else { $cmdsDir }
>> "!ECP_PS!" echo     [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
>> "!ECP_PS!" echo     Write-Output 'ADDED'
>> "!ECP_PS!" echo }
set "ECP_RESULT="
for /f "usebackq" %%R in (`powershell -NoProfile -ExecutionPolicy Bypass -File "!ECP_PS!"`) do set "ECP_RESULT=%%R"
del "!ECP_PS!" 2>nul
if "!ECP_RESULT!"=="ADDED" (
    set "PATH=!PATH!;!COMMANDS_DIR!"
    echo [configurer] Added !COMMANDS_DIR! to PATH.
    echo [configurer] Restart your terminal for the change to take effect.
)
goto :eof

:: ---------------------------------------------------------------------------
:: :VersionGt - Check if version A > version B
:: Sets VER_RESULT=yes or VER_RESULT=no
:: %~1 = version A, %~2 = version B
:: ---------------------------------------------------------------------------
:VersionGt
set "VER_RESULT=no"
set "VC_PS=%TEMP%\configurer_vc_%RANDOM%.ps1"
> "!VC_PS!" echo if ([version]'%~1' -gt [version]'%~2') { Write-Output 'yes' } else { Write-Output 'no' }
for /f "usebackq" %%R in (`powershell -NoProfile -ExecutionPolicy Bypass -File "!VC_PS!"`) do set "VER_RESULT=%%R"
del "!VC_PS!" 2>nul
goto :eof

:: ---------------------------------------------------------------------------
:: :VersionGe - Check if version A >= version B
:: Sets VER_RESULT=yes or VER_RESULT=no
:: %~1 = version A, %~2 = version B
:: ---------------------------------------------------------------------------
:VersionGe
set "VER_RESULT=no"
set "VC_PS=%TEMP%\configurer_vc_%RANDOM%.ps1"
> "!VC_PS!" echo if ([version]'%~1' -ge [version]'%~2') { Write-Output 'yes' } else { Write-Output 'no' }
for /f "usebackq" %%R in (`powershell -NoProfile -ExecutionPolicy Bypass -File "!VC_PS!"`) do set "VER_RESULT=%%R"
del "!VC_PS!" 2>nul
goto :eof

:: ---------------------------------------------------------------------------
:: :SelfUpdate
:: ---------------------------------------------------------------------------
:SelfUpdate
set "TMPSCRIPT=%TEMP%\configurer_new_%RANDOM%.bat"
set "HELPER=%TEMP%\configurer_upd_%RANDOM%.bat"
set "LOCAL_VER="
set "REMOTE_VER="

echo [configurer] Checking for updates...
curl -fsSL "%SCRIPT_URL%" -o "%TMPSCRIPT%" 2>nul
if %ERRORLEVEL% NEQ 0 (
    echo [configurer] WARNING: Could not check for updates. Continuing.
    if exist "%TMPSCRIPT%" del "%TMPSCRIPT%" 2>nul
    goto :eof
)

for /f "tokens=3" %%v in ('findstr "Version:" "%TMPSCRIPT%" 2^>nul') do set "REMOTE_VER=%%v"
for /f "tokens=3" %%v in ('findstr "Version:" "%~f0"   2^>nul') do set "LOCAL_VER=%%v"

if not defined REMOTE_VER (
    echo [configurer] WARNING: Could not read remote version. Continuing.
    del "%TMPSCRIPT%" 2>nul
    goto :eof
)
if not defined LOCAL_VER set "LOCAL_VER=0"

if %REMOTE_VER% LEQ %LOCAL_VER% (
    del "%TMPSCRIPT%" 2>nul
    goto :eof
)

echo [configurer] New version available ^(%LOCAL_VER% -^> %REMOTE_VER%^). Updating...

set "RESTART_ARGS=!SUBCMD! !TARGET! !PASSTHROUGH_ARGS!"

(
    echo @echo off
    echo ping -n 3 127.0.0.1 ^>nul
    echo copy /y "%TMPSCRIPT%" "%~f0" ^>nul
    echo del "%TMPSCRIPT%" 2^>nul
    echo start "" "%~f0" --no-update !RESTART_ARGS!
    echo del "%%~f0"
) > "%HELPER%"

start "" /b cmd /c "%HELPER%"
set "UPDATE_IN_PROGRESS=1"
goto :eof

:: ---------------------------------------------------------------------------
:: :RefreshPath
:: ---------------------------------------------------------------------------
:RefreshPath
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
