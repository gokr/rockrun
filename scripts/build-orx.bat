@echo off
setlocal DisableDelayedExpansion
:: build-orx.bat - clone Norx and build orx.dll (debug/release) in the VM.
set BUILD_ROOT=C:\Users\vagrant
set SHARED=%~1
if "%SHARED%"=="" set SHARED=C:\Users\vagrant\shared

:: WinRM sessions do not inherit the interactive session PATH - add the
:: tools explicitly (installed by scripts/windows-setup.bat).
set "PATH=%PROGRAMFILES%\Git\cmd;%ALLUSERSPROFILE%\chocolatey\bin;%PROGRAMFILES%\Nim\bin;%PATH%"

echo === Building ORX (Windows) ===

:: Norx checkout
if not exist "%BUILD_ROOT%\norx\.git" (
    echo Cloning Norx...
    cd /d "%BUILD_ROOT%"
    git clone https://github.com/tankfeud/norx.git norx
    if %errorLevel% neq 0 (
        echo ERROR: failed to clone norx
        pause
        exit /b 1
    )
) else (
    cd /d "%BUILD_ROOT%\norx"
    git pull
)

:: ORX submodule
cd /d "%BUILD_ROOT%\norx"
if not exist "orx\.git" (
    echo Initializing ORX submodule...
    git submodule update --init --recursive
    if %errorLevel% neq 0 (
        echo ERROR: failed to init ORX submodule
        pause
        exit /b 1
    )
)

cd /d "%BUILD_ROOT%\norx\orx"

:: Generate gmake build files if missing
if not exist "code\build\windows\gmake\Makefile" (
    if exist "setup.bat" (
        echo Running ORX setup...
        :: setup.bat ends with a pause when run through cmd /c (which is
        :: how Vagrant invokes it) - pipe a newline to satisfy it.
        echo. | call setup.bat
    ) else (
        echo ERROR: setup.bat not found
        pause
        exit /b 1
    )
)

:: Build
cd /d "code\build\windows\gmake"
where mingw32-make >nul 2>&1
if %errorLevel% neq 0 (
    echo ERROR: mingw32-make not found - run scripts/windows-setup.bat first
    pause
    exit /b 1
)

mingw32-make config=release64
if %errorLevel% neq 0 (
    echo ERROR: ORX release64 build failed
    pause
    exit /b 1
)

echo Copying orx.dll to %SHARED%\build\orx\
mkdir "%SHARED%\build\orx" 2>nul
copy /y "%BUILD_ROOT%\norx\orx\code\bin\orx.dll" "%SHARED%\build\orx\" >nul
strip "%SHARED%\build\orx\orx.dll"

echo === ORX build done ===
endlocal
