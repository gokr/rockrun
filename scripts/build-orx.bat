@echo off
setlocal DisableDelayedExpansion
REM  build-orx.bat - clone Norx and build orx.dll (debug/release) in the VM.
REM
REM  ORX's own setup.bat runs a GUI-subsystem Rebol binary which cannot run
REM  in an automated WinRM session. This script replicates what setup.r does
REM  with console tools instead: fetch the extern zip into the official cache
REM  location, extract it, copy the Windows premake, generate the gmake
REM  build files, and run mingw32-make.
set BUILD_ROOT=C:\Users\vagrant
set SHARED=%~1
if "%SHARED%"=="" set SHARED=C:\Users\vagrant\shared

REM  WinRM sessions do not inherit the interactive session PATH - add the
REM  tools explicitly (installed by scripts/windows-setup.bat).
set "PATH=%PROGRAMFILES%\Git\cmd;%ALLUSERSPROFILE%\chocolatey\bin;%PROGRAMFILES%\Nim\bin;%PATH%"

echo === Building ORX (Windows) ===

REM  Norx checkout
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

REM  ORX submodule
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

REM  Extern version required by this ORX revision
for /f "delims=" %%v in (.extern) do set EXTERN_VER=%%v
if "%EXTERN_VER%"=="" (
    echo ERROR: could not read .extern version
    pause
    exit /b 1
)

REM  Generate the gmake files only when they are missing (previous
REM  half-finished attempts may leave a partial extern/ around).
if not exist "code\build\windows\gmake\Makefile" (
    echo Generating ORX gmake build files...

REM Fetch the extern zip into the cache setup r's own cache location 
REM The primary host orx-project org is currently down - use the
    REM  codeload fallback first, mirroring setup.r's host list.
    if not exist "cache\%EXTERN_VER%.zip" (
        echo Downloading ORX extern %EXTERN_VER%...
        mkdir cache 2>nul
        curl -f -L -o "cache\%EXTERN_VER%.zip" "https://codeload.github.com/orx/orx-extern/zip/%EXTERN_VER%"
        if %errorLevel% neq 0 (
            echo Retrying primary host...
            curl -f -L -o "cache\%EXTERN_VER%.zip" "https://orx-project.org/extern/%EXTERN_VER%.zip"
        )
        if %errorLevel% neq 0 (
            echo ERROR: failed to download ORX extern zip
            pause
            exit /b 1
        )
    ) else (
        echo ORX extern %EXTERN_VER% found in cache.
    )

    REM  Extract the extern dir; verify the premake we need actually made it.
    if not exist "extern\premake\bin\windows\premake4.exe" (
        echo Extracting ORX extern...
        if exist extern rd /s /q extern
        mkdir extern
        tar -xf "cache\%EXTERN_VER%.zip" -C extern --strip-components=1
        if not exist "extern\premake\bin\windows\premake4.exe" (
            echo ERROR: premake4.exe missing after extraction - bad zip?
            echo Deleting the cache zip so the next run re-downloads.
            del "cache\%EXTERN_VER%.zip" 2>nul
            pause
            exit /b 1
        )
    ) else (
        echo ORX extern already extracted.
    )

    REM  MinGW runtime: premake4.exe and mingw32-make are MinGW binaries
    REM  that need libwinpthread/libstdc++/libgcc DLLs. Self-heal in case
    REM  windows-setup.bat's mingw step did not run.
    where mingw32-make >nul 2>&1
    if %errorLevel% neq 0 (
        echo Installing MinGW via Chocolatey...
        choco install mingw -y --no-progress
        if %errorLevel% neq 0 (
            echo ERROR: failed to install MinGW
            pause
            exit /b 1
        )
    )
    set "PATH=%ALLUSERSPROFILE%\chocolatey\lib\mingw\tools\install\mingw64\bin;%PATH%"

    REM  Copy the Windows premake into code/build and generate
    copy /y "extern\premake\bin\windows\premake4.exe" "code\build\premake4.exe" >nul
    cd /d "code\build"
    premake4.exe gmake
    if %errorLevel% neq 0 (
        echo ERROR: premake failed to generate build files
        pause
        exit /b 1
    )
)

REM  Build
cd /d "code\build\windows\gmake"
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

