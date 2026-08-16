@echo off
:: windows-setup.bat - one-time Windows build environment setup for Rockrun.
:: Run as Administrator inside the Vagrant VM (or on any Windows box).
setlocal

:: Check for admin privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo ERROR: Please run this script as Administrator!
    pause
    exit /b 1
)

set "NIM_VERSION=2.2.10"
set "TEMP_DIR=%TEMP%\rockrun-setup"

:: Install Chocolatey if not present
where choco >nul 2>&1
if %errorLevel% neq 0 (
    if exist "%ALLUSERSPROFILE%\chocolatey\bin\choco.exe" (
        set "PATH=%ALLUSERSPROFILE%\chocolatey\bin;%PATH%"
    ) else (
        echo Installing Chocolatey...
        powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.Net.ServicePointManager]::SecurityProtocol = 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
        if %errorLevel% neq 0 (
            echo ERROR: Failed to install Chocolatey
            pause
            exit /b 1
        )
        set "PATH=%ALLUSERSPROFILE%\chocolatey\bin;%PATH%"
    )
)

:: Git
where git >nul 2>&1
if %errorLevel% neq 0 (
    echo Installing Git...
    choco install git -y --no-progress
    set "GIT_PATH=%PROGRAMFILES%\Git\cmd"
) else (
    set "GIT_PATH=%PROGRAMFILES%\Git\cmd"
)

:: MinGW
where gcc >nul 2>&1
if %errorLevel% neq 0 (
    echo Installing MinGW...
    choco install mingw -y --no-progress
)

:: Nim
if not exist "%PROGRAMFILES%\Nim\bin\nim.exe" (
    echo Installing Nim %NIM_VERSION%...
    mkdir "%TEMP_DIR%" 2>nul
    powershell -Command "Invoke-WebRequest -Uri 'https://nim-lang.org/download/nim-%NIM_VERSION%_x64.zip' -OutFile '%TEMP_DIR%\nim.zip' -UseBasicParsing"
    powershell -Command "Expand-Archive -Path '%TEMP_DIR%\nim.zip' -DestinationPath '%PROGRAMFILES%' -Force"
    if exist "%PROGRAMFILES%\nim-%NIM_VERSION%" (
        move "%PROGRAMFILES%\nim-%NIM_VERSION%" "%PROGRAMFILES%\Nim" >nul 2>&1
    )
    "%PROGRAMFILES%\Nim\finish.exe"
) else (
    echo Nim already installed.
)

set "PATH=%PROGRAMFILES%\Nim\bin;%GIT_PATH%;%PATH%"
nim --version
git --version

echo.
echo === Setup complete. PATH set for this session only. ===
endlocal
exit /b 0
