@echo off
REM =============================================================
REM ArcLedger - Portfolio 5: start one extra replica-set member
REM Usage (in a normal Command Prompt or PowerShell window):
REM     start_member.bat 27018
REM     start_member.bat 27019      (in a SECOND window)
REM Leave each window open - the member runs while the window is open.
REM Press Ctrl+C in a window to stop that member (clean shutdown).
REM Data goes to C:\mongodb-rs\<port>, logs to C:\mongodb-rs\<port>\mongod.log
REM =============================================================

if "%~1"=="" (
    echo Usage: start_member.bat ^<port^>     e.g.  start_member.bat 27018
    exit /b 1
)
set PORT=%~1

REM Find mongod.exe of the newest installed MongoDB Server version
set MONGOD=
for /d %%V in ("C:\Program Files\MongoDB\Server\*") do set MONGOD=%%V\bin\mongod.exe
if not exist "%MONGOD%" (
    echo Could not find mongod.exe under C:\Program Files\MongoDB\Server
    echo Edit this file and set MONGOD to the full path of mongod.exe
    exit /b 1
)

set DATA=C:\mongodb-rs\%PORT%
if not exist "%DATA%" mkdir "%DATA%"

title MongoDB rs0 member - port %PORT%
echo Starting replica-set member rs0 on localhost:%PORT%
echo   mongod : %MONGOD%
echo   data   : %DATA%
echo   log    : %DATA%\mongod.log
echo Running... press Ctrl+C to stop this member.

"%MONGOD%" --replSet rs0 --port %PORT% --dbpath "%DATA%" --bind_ip 127.0.0.1 --logpath "%DATA%\mongod.log" --logappend
echo Member on port %PORT% has stopped.
