@echo off
setlocal DisableDelayedExpansion
:: build-rockrun.bat - build rockrun.exe in the VM against the bundled
:: orx.dll. The repository is shared at c:/Users/vagrant/shared.
set BUILD_ROOT=C:\Users\vagrant
set SHARED=%~1
if "%SHARED%"=="" set SHARED=C:\Users\vagrant\shared

echo === Building Rockrun (Windows) ===

if not exist "%BUILD_ROOT%\norx" (
    echo ERROR: norx not found - run makeorxwindows.sh / build-orx first
    pause
    exit /b 1
)

cd /d "%SHARED%"

:: norx is a dependency for compile; the dll comes from the shared build dir
set NORX_DIR=%BUILD_ROOT%\norx
set "PATH=%PROGRAMFILES%\Nim\bin;%PATH%"

nimble install -d -y
nim c -d:release --passL:"%SHARED%\build\orx\orx.dll" -o:"%SHARED%\build\rockrun.exe" src\rockrun.nim
if %errorLevel% neq 0 (
    echo ERROR: rockrun build failed
    pause
    exit /b 1
)

strip "%SHARED%\build\rockrun.exe"
echo === Rockrun build done: %SHARED%\build\rockrun.exe ===
endlocal
