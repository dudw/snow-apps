@echo off
rem ===========================================================================
rem  Snow Shot Windows build / packaging entry point (cmd.exe).
rem
rem  Thin wrapper around:
rem    scripts\build-static-qt.ps1   - build the static Qt 6 kit
rem    scripts\build.ps1            - build the app for a CMake preset
rem    scripts\package-snow-shot.ps1 - release build + staging + zip/installer
rem    scripts\package-snow-shot-msix.ps1 - Store (MSIX) package
rem
rem  Usage:  build.cmd [action] [options]      (see "build.cmd help")
rem ===========================================================================
setlocal EnableExtensions EnableDelayedExpansion

set "REPO_ROOT=%~dp0"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"

rem ---------------------------------------------------------------------------
rem  Defaults
rem ---------------------------------------------------------------------------
set "ACTION="
set "PRESET="
set "ARCH=x64"
set "GENERATOR="
set "PARALLEL=%NUMBER_OF_PROCESSORS%"
set "TARGET="
set "WANT_QT=0"
set "FORCE_QT=0"
set "RECONFIGURE=0"
set "CLEAN=0"
set "SKIP_BUILD=0"
set "DRY_RUN=0"
set "PRESET_EXPLICIT=0"
set "QT_KIT="
set "START_TIME=%TIME%"

rem ---------------------------------------------------------------------------
rem  Argument parsing:  build.cmd [action] [options]
rem  The first non-switch argument selects the action.
rem ---------------------------------------------------------------------------
if "%~1"=="" goto :parse_done
set "FIRST=%~1"
if "%FIRST:~0,1%"=="-" goto :parse
if "%FIRST:~0,1%"=="/" goto :parse
set "ACTION=%FIRST%"
shift

:parse
if "%~1"=="" goto :parse_done
set "ARG=%~1"
set "VAL=%~2"
if /i "%ARG%"=="--help" goto :help
if /i "%ARG%"=="-h" goto :help
if /i "%ARG%"=="/?" goto :help
if /i "%ARG%"=="--preset" goto :opt_preset
if /i "%ARG%"=="--arch" goto :opt_arch
if /i "%ARG%"=="--generator" goto :opt_generator
if /i "%ARG%"=="--parallel" goto :opt_parallel
if /i "%ARG%"=="--target" goto :opt_target
if /i "%ARG%"=="--with-qt" goto :opt_with_qt
if /i "%ARG%"=="--force-qt" goto :opt_force_qt
if /i "%ARG%"=="--reconfigure" goto :opt_reconfigure
if /i "%ARG%"=="--clean" goto :opt_clean
if /i "%ARG%"=="--skip-build" goto :opt_skip_build
if /i "%ARG%"=="--dry-run" goto :opt_dry_run
echo [error] Unknown option: %ARG%
goto :fail_usage

:opt_preset
if "%VAL%"=="" goto :missing_value
set "PRESET=%VAL%"
set "PRESET_EXPLICIT=1"
shift
shift
goto :parse

:opt_arch
if "%VAL%"=="" goto :missing_value
if /i not "%VAL%"=="x64" if /i not "%VAL%"=="arm64" (
    echo [error] --arch accepts x64 or arm64, got: %VAL%
    goto :fail_usage
)
set "ARCH=%VAL%"
shift
shift
goto :parse

:opt_generator
if "%VAL%"=="" goto :missing_value
set "GENERATOR=%VAL%"
shift
shift
goto :parse

:opt_parallel
if "%VAL%"=="" goto :missing_value
set "PARALLEL=%VAL%"
shift
shift
goto :parse

:opt_target
if "%VAL%"=="" goto :missing_value
set "TARGET=%VAL%"
shift
shift
goto :parse

:opt_with_qt
set "WANT_QT=1"
shift
goto :parse

:opt_force_qt
set "WANT_QT=1"
set "FORCE_QT=1"
shift
goto :parse

:opt_reconfigure
set "RECONFIGURE=1"
shift
goto :parse

:opt_clean
set "CLEAN=1"
shift
goto :parse

:opt_skip_build
set "SKIP_BUILD=1"
shift
goto :parse

:opt_dry_run
set "DRY_RUN=1"
shift
goto :parse

:missing_value
echo [error] Option %ARG% needs a value.
goto :fail_usage

:parse_done
if not defined ACTION set "ACTION=package"

rem ---------------------------------------------------------------------------
rem  Pick the PowerShell host (the scripts need pwsh 7 for the Qt build).
rem ---------------------------------------------------------------------------
set "PWSH_EXE="
where pwsh.exe >nul 2>nul
if not errorlevel 1 set "PWSH_EXE=pwsh.exe"
if not defined PWSH_EXE (
    where powershell.exe >nul 2>nul
    if not errorlevel 1 set "PWSH_EXE=powershell.exe"
)
if not defined PWSH_EXE (
    echo [error] Neither pwsh.exe nor powershell.exe was found on PATH.
    echo         Install PowerShell 7: https://aka.ms/powershell
    exit /b 1
)
if /i not "%PWSH_EXE%"=="pwsh.exe" (
    echo [warn] pwsh 7 was not found; falling back to %PWSH_EXE%.
    echo [warn] Static Qt and MSIX builds need PowerShell 7.2 or newer.
)

if not exist "%REPO_ROOT%\scripts\build.ps1" (
    echo [error] %REPO_ROOT% does not look like the snow-apps repository.
    exit /b 1
)

rem ---------------------------------------------------------------------------
rem  Dependency download proxy.
rem  vcpkg, cargo and git all read HTTPS_PROXY/HTTP_PROXY. GitHub release
rem  assets, SourceForge mirrors and the Google CIPD endpoints time out on
rem  networks that cannot reach them directly, and vcpkg then fails the port.
rem  Override the endpoint with SNOW_BUILD_PROXY, or set it to "off" to use
rem  direct downloads. The proxy is only exported when it answers a TCP probe.
rem ---------------------------------------------------------------------------
set "SNOW_PROXY="
if defined HTTPS_PROXY (
    set "SNOW_PROXY=%HTTPS_PROXY%"
) else (
    for /f "usebackq delims=" %%P in (`%PWSH_EXE% -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\scripts\resolve-build-proxy.ps1"`) do set "SNOW_PROXY=%%P"
    if defined SNOW_PROXY (
        set "HTTPS_PROXY=!SNOW_PROXY!"
        set "HTTP_PROXY=!SNOW_PROXY!"
    )
)

rem ---------------------------------------------------------------------------
rem  Preset defaults per architecture.
rem ---------------------------------------------------------------------------
if not defined PRESET (
    if /i "%ARCH%"=="arm64" (
        set "PRESET=snow-shot-msvc-arm64-release"
    ) else (
        set "PRESET=snow-shot-msvc-release"
    )
)

call :detect_qt

echo.
echo ===========================================================================
echo  Snow Shot build
echo    repo      : %REPO_ROOT%
echo    action    : %ACTION%
echo    preset    : %PRESET%
echo    arch      : %ARCH%
if defined QT_KIT echo    static Qt : %QT_KIT%
if not defined QT_KIT echo    static Qt : NOT FOUND
echo    powershell: %PWSH_EXE%
if defined SNOW_PROXY echo    proxy     : %SNOW_PROXY%
if not defined SNOW_PROXY echo    proxy     : direct (SNOW_BUILD_PROXY=off or unavailable)
echo ===========================================================================
echo.

if /i "%ACTION%"=="qt" goto :run_qt
if /i "%ACTION%"=="build" goto :run_build
if /i "%ACTION%"=="package" goto :run_package
if /i "%ACTION%"=="all" goto :run_all
if /i "%ACTION%"=="msix" goto :run_msix
if /i "%ACTION%"=="clean" goto :run_clean
if /i "%ACTION%"=="help" goto :help
echo [error] Unknown action: %ACTION%
goto :fail_usage

rem ---------------------------------------------------------------------------
rem  qt - build the static Qt kit
rem ---------------------------------------------------------------------------
:run_qt
if /i not "%ARCH%"=="x64" (
    echo [error] This wrapper only builds the x64 static Qt kit.
    echo         For arm64 follow docs-windows-arm64-build.md.
    exit /b 2
)
call :build_qt
if errorlevel 1 exit /b 1
goto :done

:build_qt
set "QT_FORCE_ARG="
if "%FORCE_QT%"=="1" set "QT_FORCE_ARG=-Force"
set "QT_GEN_ARG="
if defined GENERATOR set QT_GEN_ARG=-CmakeGenerator "%GENERATOR%"
set "QT_PREFIX=%REPO_ROOT%\.tools\qt\6.12.0\msvc2026_64-static"
echo [cmd] build-static-qt.ps1 -Configuration Release -Architecture x64 -InstallPrefix "%QT_PREFIX%" %QT_GEN_ARG% %QT_FORCE_ARG%
if "%DRY_RUN%"=="1" exit /b 0
"%PWSH_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\scripts\build-static-qt.ps1" -Configuration Release -Architecture x64 -InstallPrefix "%QT_PREFIX%" %QT_GEN_ARG% %QT_FORCE_ARG%
if errorlevel 1 (
    echo [error] Static Qt build failed.
    exit /b 1
)
call :detect_qt
if not defined QT_KIT (
    echo [error] The Qt build reported success but no Qt6Config.cmake was installed.
    exit /b 1
)
echo [ok] static Qt ready: %QT_KIT%
exit /b 0

rem ---------------------------------------------------------------------------
rem  build - build the app for a preset (no packaging)
rem ---------------------------------------------------------------------------
:run_build
set "BUILD_EXTRA="
if "%CLEAN%"=="1" set BUILD_EXTRA=%BUILD_EXTRA% -Clean
if "%RECONFIGURE%"=="1" set BUILD_EXTRA=%BUILD_EXTRA% -Reconfigure
if defined TARGET set BUILD_EXTRA=%BUILD_EXTRA% -Target %TARGET%
echo [cmd] build.ps1 -Preset %PRESET%%BUILD_EXTRA%
if "%DRY_RUN%"=="1" goto :done
call :require_qt
if errorlevel 1 exit /b 1
"%PWSH_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\scripts\build.ps1" -Preset "%PRESET%" %BUILD_EXTRA%
if errorlevel 1 (
    echo [error] Build failed for preset %PRESET%.
    exit /b 1
)
echo [ok] build finished: build\%PRESET%
goto :done

rem ---------------------------------------------------------------------------
rem  package - release build + staging + portable zip + installer
rem ---------------------------------------------------------------------------
:run_package
call :require_release_preset
if errorlevel 1 exit /b 1
set "PKG_SKIP_ARG="
if "%SKIP_BUILD%"=="1" set PKG_SKIP_ARG=-SkipBuild
set "PKG_BUILD_DIR="
if "%PRESET_EXPLICIT%"=="1" set PKG_BUILD_DIR=-BuildDirectory "build\%PRESET%"
echo [cmd] package-snow-shot.ps1 -Architecture %ARCH% -Parallelism %PARALLEL% %PKG_SKIP_ARG% %PKG_BUILD_DIR%
if "%DRY_RUN%"=="1" goto :done
call :require_qt
if errorlevel 1 exit /b 1
"%PWSH_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\scripts\package-snow-shot.ps1" -Architecture %ARCH% -Parallelism %PARALLEL% %PKG_SKIP_ARG% %PKG_BUILD_DIR%
if errorlevel 1 (
    echo [error] Packaging failed. See the log above for the failing stage.
    exit /b 1
)
goto :report_artifacts

rem ---------------------------------------------------------------------------
rem  all - static Qt (only if missing), then package
rem ---------------------------------------------------------------------------
:run_all
call :require_release_preset
if errorlevel 1 exit /b 1
echo [cmd] build-static-qt.ps1 (only when the kit is missing) then package-snow-shot.ps1 -Architecture %ARCH% -Parallelism %PARALLEL%
if "%DRY_RUN%"=="1" goto :done
if defined QT_KIT goto :run_all_package
call :build_qt
if errorlevel 1 exit /b 1

:run_all_package
call :require_qt
if errorlevel 1 exit /b 1
set "PKG_SKIP_ARG="
if "%SKIP_BUILD%"=="1" set PKG_SKIP_ARG=-SkipBuild
"%PWSH_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\scripts\package-snow-shot.ps1" -Architecture %ARCH% -Parallelism %PARALLEL% %PKG_SKIP_ARG%
if errorlevel 1 (
    echo [error] Packaging failed. See the log above for the failing stage.
    exit /b 1
)
goto :report_artifacts

rem ---------------------------------------------------------------------------
rem  msix - Store package (x64 only)
rem ---------------------------------------------------------------------------
:run_msix
if /i not "%ARCH%"=="x64" (
    echo [error] The Store channel supports x64 only.
    exit /b 2
)
call :require_release_preset
if errorlevel 1 exit /b 1
echo [cmd] package-snow-shot-msix.ps1 -Architecture x64 -Parallelism %PARALLEL%
if "%DRY_RUN%"=="1" goto :done
call :require_qt
if errorlevel 1 exit /b 1
"%PWSH_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%REPO_ROOT%\scripts\package-snow-shot-msix.ps1" -Architecture x64 -Parallelism %PARALLEL%
if errorlevel 1 (
    echo [error] MSIX packaging failed.
    exit /b 1
)
goto :report_artifacts

rem ---------------------------------------------------------------------------
rem  clean - remove the build tree of the selected preset
rem ---------------------------------------------------------------------------
:run_clean
set "CLEAN_DIR=%REPO_ROOT%\build\%PRESET%"
if not exist "%CLEAN_DIR%\" (
    echo [info] Nothing to remove: %CLEAN_DIR%
    goto :done
)
if "%DRY_RUN%"=="1" (
    echo [cmd] rmdir /s /q "%CLEAN_DIR%"
    goto :done
)
echo [warn] This deletes the whole build tree of preset %PRESET%:
echo        %CLEAN_DIR%
choice /c YN /m "Continue"
if errorlevel 2 (
    echo [info] Cancelled.
    goto :done
)
rmdir /s /q "%CLEAN_DIR%"
if errorlevel 1 (
    echo [error] Could not remove %CLEAN_DIR%. Close Visual Studio / running apps and retry.
    exit /b 1
)
echo [ok] removed %CLEAN_DIR%
goto :done

rem ---------------------------------------------------------------------------
rem  Helpers
rem ---------------------------------------------------------------------------
:detect_qt
set "QT_KIT="
if defined SNOW_QT_STATIC_DIR if exist "%SNOW_QT_STATIC_DIR%\Qt6Config.cmake" set "QT_KIT=%SNOW_QT_STATIC_DIR%"
if not defined QT_KIT if defined Qt6_DIR if exist "%Qt6_DIR%\Qt6Config.cmake" set "QT_KIT=%Qt6_DIR%"
if not defined QT_KIT (
    rem Kit directories are named like msvc2026_64-static or
    rem msvc2026_arm64-static-system-codecs; keep the one that matches --arch.
    for /d %%V in ("%REPO_ROOT%\.tools\qt\*") do (
        for /d %%K in ("%%~fV\*") do (
            if not defined QT_KIT if exist "%%~fK\lib\cmake\Qt6\Qt6Config.cmake" (
                set "QT_CAND=%%~fK\lib\cmake\Qt6"
                set "QT_CAND_NAME=%%~nxK"
                set "QT_CAND_BARE=!QT_CAND_NAME:arm64=!"
                if /i "%ARCH%"=="arm64" (
                    if not "!QT_CAND_NAME!"=="!QT_CAND_BARE!" set "QT_KIT=!QT_CAND!"
                ) else (
                    if "!QT_CAND_NAME!"=="!QT_CAND_BARE!" set "QT_KIT=!QT_CAND!"
                )
            )
        )
    )
)
if defined QT_KIT set "QT_KIT=%QT_KIT:~0,-1%"
goto :eof

:require_release_preset
echo %PRESET%| findstr /i /e /c:"-release" >nul
if not errorlevel 1 exit /b 0
echo [error] Packaging needs a Release preset; %PRESET% is not one.
echo         Use snow-shot-msvc-release (x64), snow-shot-msvc-arm64-release,
echo         or snow-shot-msvc-store-release. Dev presets such as
echo         snow-shot-msvc-fast cannot be packaged.
exit /b 2

:require_qt
if defined QT_KIT exit /b 0
echo [warn] No static Qt 6.12.0 kit was found.
if "%WANT_QT%"=="1" (
    echo [info] Building it now because --with-qt was given.
    call :build_qt
    if errorlevel 1 exit /b 1
    exit /b 0
)
if "%DRY_RUN%"=="1" exit /b 0
echo [error] A static Qt 6.12.0 kit is required for the Release presets.
echo         Build it once:                 build.cmd qt
echo         Or let this run build it:      build.cmd %ACTION% --with-qt
echo         Or point at an existing kit:   set SNOW_QT_STATIC_DIR=^<prefix^>\lib\cmake\Qt6
exit /b 2

:report_artifacts
echo.
echo [info] Recent artifacts:
set "ART_COUNT=0"
if exist "%REPO_ROOT%\artifacts" (
    for /f "delims=" %%F in ('dir /b /o-d /a-d "%REPO_ROOT%\artifacts" 2^>nul') do (
        set /a ART_COUNT+=1
        if !ART_COUNT! LEQ 8 echo        artifacts\%%F
    )
)
if exist "%REPO_ROOT%\build\%PRESET%\*.zip" (
    for /f "delims=" %%F in ('dir /b /o-d /a-d "%REPO_ROOT%\build\%PRESET%\*.zip" 2^>nul') do (
        set /a ART_COUNT+=1
        if !ART_COUNT! LEQ 8 echo        build\%PRESET%\%%F
    )
)
if "%ART_COUNT%"=="0" echo        (none yet)
goto :done

rem ---------------------------------------------------------------------------
rem  Exit paths
rem ---------------------------------------------------------------------------
:done
echo.
echo [done] %ACTION% started %START_TIME% / finished %TIME%
endlocal
exit /b 0

:fail_usage
echo.
echo Run "build.cmd help" for the available actions and options.
exit /b 2

:help
echo.
echo Snow Shot build / packaging wrapper
echo.
echo Usage:
echo   build.cmd [action] [options]
echo.
echo Actions:
echo   package   Release build + staging + portable zip + installer  (default)
echo   build     Build the app for a preset, no packaging
echo   qt        Build the static Qt 6.12.0 x64 kit (40-80 min, one time)
echo   all       Static Qt when missing, then package
echo   msix      Microsoft Store (MSIX) package, x64 only
echo   clean     Delete the build tree of the selected preset
echo   help      This text
echo.
echo Options:
echo   --preset ^<name^>      CMake preset (default: snow-shot-msvc-release,
echo                         snow-shot-msvc-arm64-release for --arch arm64)
echo   --arch ^<x64^|arm64^>   Target architecture (default: x64)
echo   --target ^<name^>      Only build this CMake target (build action)
echo   --parallel ^<n^>       Parallel jobs for packaging (default: %%NUMBER_OF_PROCESSORS%%)
echo   --with-qt            Build the static Qt kit automatically when missing
echo   --force-qt           Rebuild the static Qt kit from scratch
echo   --generator ^<name^>   CMake generator for the Qt build, for example
echo                         "Visual Studio 18 2026" or "Ninja"
echo   --reconfigure        Force a CMake configure before building
echo   --clean              Clean the build tree before building
echo   --skip-build         Package the existing build output as-is
echo   --dry-run            Print the commands without running them
echo.
echo Environment:
echo   SNOW_BUILD_PROXY     Proxy for dependency downloads (vcpkg, cargo, git).
echo                        Default: socks5h://127.0.0.1:1080 when the local proxy
echo                        is running; "off" forces direct downloads.
echo.
echo Examples:
echo   build.cmd                                  full release package
echo   build.cmd build --preset snow-shot-msvc-fast
echo   build.cmd qt --generator "Visual Studio 18 2026"
echo   build.cmd package --skip-build --parallel 8
echo   build.cmd all --with-qt
echo   build.cmd clean --preset snow-shot-msvc-release
echo.
echo Output:
echo   artifacts\                installer, OCR runtime cache, manifests
echo   build\^<preset^>\*.zip      portable archive for the release preset
echo.
endlocal
exit /b 0
