@echo off
setlocal enabledelayedexpansion

REM =========================================================================
REM  Claude Code Development Environment - Windows Launch Script
REM =========================================================================

REM ---------------------------------------------------------------------------
REM  Determine directories
REM ---------------------------------------------------------------------------
set "SCRIPT_DIR=%~dp0"
REM Remove trailing backslash from SCRIPT_DIR
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "PROJECT_DIR=%CD%"

REM ---------------------------------------------------------------------------
REM  Parse CLI flags
REM ---------------------------------------------------------------------------
set "BUILD=0"
set "DETACH=0"
set "DOWN=0"
set "CUSTOM_CMD="
set "PROFILE_COUNT=0"

:parse_args
if "%~1"=="" goto :done_args

if /i "%~1"=="/build"   ( set "BUILD=1"   & shift & goto :parse_args )
if /i "%~1"=="-b"       ( set "BUILD=1"   & shift & goto :parse_args )
if /i "%~1"=="--build"  ( set "BUILD=1"   & shift & goto :parse_args )

if /i "%~1"=="/detach"  ( set "DETACH=1"  & shift & goto :parse_args )
if /i "%~1"=="-d"       ( set "DETACH=1"  & shift & goto :parse_args )
if /i "%~1"=="--detach" ( set "DETACH=1"  & shift & goto :parse_args )

if /i "%~1"=="/claude"  ( set "CUSTOM_CMD=claude" & shift & goto :parse_args )
if /i "%~1"=="-c"       ( set "CUSTOM_CMD=claude" & shift & goto :parse_args )
if /i "%~1"=="--claude" ( set "CUSTOM_CMD=claude" & shift & goto :parse_args )

if /i "%~1"=="/down"    ( set "DOWN=1"    & shift & goto :parse_args )
if /i "%~1"=="--down"   ( set "DOWN=1"    & shift & goto :parse_args )

if /i "%~1"=="/help"    ( goto :show_help )
if /i "%~1"=="-h"       ( goto :show_help )
if /i "%~1"=="--help"   ( goto :show_help )

if /i "%~1"=="/profile" (
    if "%~2"=="" (
        echo [ERROR] Option %~1 requires a profile name.
        exit /b 1
    )
    set /a PROFILE_COUNT+=1
    set "PROFILE_!PROFILE_COUNT!=%~2"
    shift & shift & goto :parse_args
)
if /i "%~1"=="-p" (
    if "%~2"=="" (
        echo [ERROR] Option %~1 requires a profile name.
        exit /b 1
    )
    set /a PROFILE_COUNT+=1
    set "PROFILE_!PROFILE_COUNT!=%~2"
    shift & shift & goto :parse_args
)
if /i "%~1"=="--profile" (
    if "%~2"=="" (
        echo [ERROR] Option %~1 requires a profile name.
        exit /b 1
    )
    set /a PROFILE_COUNT+=1
    set "PROFILE_!PROFILE_COUNT!=%~2"
    shift & shift & goto :parse_args
)

if /i "%~1"=="/shell" (
    if "%~2"=="" (
        echo [ERROR] Option %~1 requires a shell name.
        exit /b 1
    )
    set "CUSTOM_CMD=%~2"
    shift & shift & goto :parse_args
)
if /i "%~1"=="-s" (
    if "%~2"=="" (
        echo [ERROR] Option %~1 requires a shell name.
        exit /b 1
    )
    set "CUSTOM_CMD=%~2"
    shift & shift & goto :parse_args
)
if /i "%~1"=="--shell" (
    if "%~2"=="" (
        echo [ERROR] Option %~1 requires a shell name.
        exit /b 1
    )
    set "CUSTOM_CMD=%~2"
    shift & shift & goto :parse_args
)

echo [ERROR] Unknown option: %~1
goto :show_help

:done_args

REM ---------------------------------------------------------------------------
REM  Prerequisite checks
REM ---------------------------------------------------------------------------
echo [INFO]  Checking prerequisites...

where docker >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Docker is not installed or not in PATH.
    echo [ERROR] Install Docker Desktop: https://docs.docker.com/desktop/install/windows-install/
    exit /b 1
)

docker info >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Docker daemon is not running.
    echo [ERROR] Please start Docker Desktop and try again.
    exit /b 1
)

docker compose version >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Docker Compose plugin is not available.
    echo [ERROR] Install Docker Desktop which includes Compose: https://docs.docker.com/desktop/install/windows-install/
    exit /b 1
)

echo [OK]    Prerequisites satisfied.

REM ---------------------------------------------------------------------------
REM  Load .env file if present (from SCRIPT_DIR)
REM ---------------------------------------------------------------------------
set "ENV_FILE=%SCRIPT_DIR%\.env"
set "HAS_ENV=0"

if exist "%ENV_FILE%" (
    echo [INFO]  Loading environment from %ENV_FILE%
    set "HAS_ENV=1"
    for /f "usebackq tokens=1,* delims==" %%A in ("%ENV_FILE%") do (
        REM Skip blank lines and comments
        set "LINE=%%A"
        if defined LINE (
            if not "!LINE:~0,1!"=="#" (
                set "%%A=%%B"
            )
        )
    )
) else (
    echo [INFO]  No .env file found at %ENV_FILE% -- continuing with defaults.
)

REM ---------------------------------------------------------------------------
REM  SSH agent note for Windows
REM ---------------------------------------------------------------------------
echo [INFO]  SSH agent forwarding on Windows uses named pipes via Docker Desktop.
echo [INFO]  Ensure your SSH keys are loaded with ssh-add in PowerShell if needed.

REM ---------------------------------------------------------------------------
REM  Set key variables
REM ---------------------------------------------------------------------------
set "PROJECT_DIR=%CD%"

if not defined CLAUDE_HOME (
    set "CLAUDE_HOME=%USERPROFILE%\.claude"
)

REM ---------------------------------------------------------------------------
REM  Ensure Claude home directory exists
REM ---------------------------------------------------------------------------
if not exist "!CLAUDE_HOME!" (
    echo [INFO]  Creating Claude home directory: !CLAUDE_HOME!
    mkdir "!CLAUDE_HOME!"
)

REM ---------------------------------------------------------------------------
REM  Build the compose command
REM ---------------------------------------------------------------------------
set "COMPOSE_CMD=docker compose -f "%SCRIPT_DIR%\docker-compose.yml""

if "!HAS_ENV!"=="1" (
    set "COMPOSE_CMD=!COMPOSE_CMD! --env-file "%ENV_FILE%""
)

REM Add profiles
if !PROFILE_COUNT! gtr 0 (
    for /l %%i in (1,1,!PROFILE_COUNT!) do (
        set "COMPOSE_CMD=!COMPOSE_CMD! --profile "!PROFILE_%%i!""
    )
)

REM Handle --down
if "!DOWN!"=="1" (
    echo [INFO]  Stopping and removing containers...
    !COMPOSE_CMD! down --remove-orphans
    if errorlevel 1 (
        echo [ERROR] Failed to stop containers.
        exit /b 1
    )
    echo [OK]    Environment stopped.
    exit /b 0
)

REM Build flag
if "!BUILD!"=="1" (
    set "COMPOSE_CMD=!COMPOSE_CMD! --build"
)

REM Run mode
if "!DETACH!"=="1" (
    set "COMPOSE_CMD=!COMPOSE_CMD! up -d"
) else (
    set "COMPOSE_CMD=!COMPOSE_CMD! run --rm --service-ports dev"

    REM Custom command override
    if defined CUSTOM_CMD (
        set "COMPOSE_CMD=!COMPOSE_CMD! !CUSTOM_CMD!"
    )
)

REM ---------------------------------------------------------------------------
REM  Print banner
REM ---------------------------------------------------------------------------
echo.
echo ================================================================
echo          Claude Code Development Environment
echo ================================================================
echo.
echo [INFO]  Project directory : %PROJECT_DIR%
echo [INFO]  Script directory  : %SCRIPT_DIR%
echo [INFO]  Claude home       : !CLAUDE_HOME!

if !PROFILE_COUNT! gtr 0 (
    set "PROFILE_LIST="
    for /l %%i in (1,1,!PROFILE_COUNT!) do (
        set "PROFILE_LIST=!PROFILE_LIST! !PROFILE_%%i!"
    )
    echo [INFO]  Profiles enabled  :!PROFILE_LIST!
)

if defined CUSTOM_CMD (
    echo [INFO]  Command override  : !CUSTOM_CMD!
)

if "!DETACH!"=="1" (
    echo [INFO]  Mode              : detached ^(background^)
) else (
    echo [INFO]  Mode              : interactive
)

echo.
echo [INFO]  Starting environment...
echo.

REM ---------------------------------------------------------------------------
REM  Execute
REM ---------------------------------------------------------------------------
!COMPOSE_CMD!
set "EXIT_CODE=!errorlevel!"

if !EXIT_CODE! neq 0 (
    echo.
    echo [WARN]  Container exited with code !EXIT_CODE!.
)

exit /b !EXIT_CODE!

REM ---------------------------------------------------------------------------
REM  Help
REM ---------------------------------------------------------------------------
:show_help
echo.
echo Usage: start.bat [OPTIONS]
echo.
echo Launch the Claude Code development environment.
echo.
echo Options:
echo   /build, -b, --build          Force rebuild the Docker image
echo   /claude, -c, --claude        Start Claude Code directly (instead of bash)
echo   /detach, -d, --detach        Run in detached/background mode
echo   /profile, -p, --profile NAME Enable a compose profile (e.g., database)
echo   /shell, -s, --shell SHELL    Use a different shell (default: bash)
echo   /down, --down                Stop and remove the environment
echo   /help, -h, --help            Show this help message
echo.
echo Examples:
echo   start.bat                       Start bash in the dev environment
echo   start.bat /claude               Start Claude Code directly
echo   start.bat /build /claude        Rebuild image and start Claude Code
echo   start.bat /profile database     Start with database services
echo   start.bat /down                 Stop the environment
echo.
echo Notes:
echo   - SSH agent forwarding on Windows uses Docker Desktop's built-in
echo     named pipe relay. Ensure your SSH keys are loaded via ssh-add
echo     in a PowerShell or cmd session before starting the container.
echo   - Environment variables are loaded from .env in the script directory.
echo.
exit /b 0
