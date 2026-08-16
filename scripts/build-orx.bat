@echo off
setlocal DisableDelayedExpansion
:: build-orx.bat - clone Norx and build orx.dll (debug/release) in the VM.
::
:: ORX's own setup.bat runs a GUI-subsystem Rebol binary which cannot run
:: in an automated WinRM session. This script replicates what setup.r does
:: with console tools instead: fetch the extern zip into the official cache
:: location, extract it, copy the Windows premake, generate the gmake
:: build files, and run mingw32-make.
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

:: Extern version required by this ORX revision
for /f "delims=" %%v in (.extern) do set EXTERN_VER=%%v
if "%EXTERN_VER%"=="" (
    echo ERROR: could not read .extern version
    pause
    exit /b 1
)

:: Fetch the extern zip into the cache (setup.r's own cache location).
:: The primary host (orx-project.org) is currently down - use the
:: codeload fallback first, mirroring setup.r's host list.
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

:: Extract the extern dir (premake and friends)
if not exist "extern" (
    echo Extracting ORX extern...
    mkdir extern
    tar -xf "cache\%EXTERN_VER%.zip" -C extern --strip-components=1
    if %errorLevel% neq 0 (
        echo ERROR: failed to extract ORX extern
        pause
        exit /b 1
    )
) else (
    echo ORX extern already extracted.
)

:: Copy the Windows premake into code/build
copy /y "extern\premake\bin\windows\premake4.exe" "code\build\premake4.exe" >nul

:: MinGW runtime: premake4.exe and mingw32-make are MinGW binaries that
:: need libwinpthread/libstdc++/libgcc DLLs. Ensure MinGW is installed
:: (self-healing, in case windows-setup.bat's mingw step did not run).
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

:: Generate the gmake build files
echo Generating ORX gmake build files...
cd /d "code\build"
premake4.exe gmake
if %errorLevel% neq 0 (
    echo ERROR: premake failed to generate build files
    pause
    exit /b 1
)

:: Build
cd /d "windows\gmake"
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
