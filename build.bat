@echo off
rem Build the Win64 CLI and GUI. Usage: build.bat [path\to\fpc.exe] [--test] [driver options]
setlocal EnableExtensions DisableDelayedExpansion
set "DRIVER=%~dp0tools\build_windows.py"
set "FIRST=%~1"
set "POSITIONAL="
if defined FIRST if not "%FIRST:~0,1%"=="-" (
  set "POSITIONAL=--fpc"
  set "FPC=%~1"
)

rem Inspect switches without rebuilding the caller's quoted argument list.
set "GUI_TEST="
:scan
if "%~1"=="" goto tools
if /i "%~1"=="--test" set "GUI_TEST=--gui-test"
if /i "%~1"=="--fpc" set "FPC=%~2"
shift
goto scan

:tools
if not defined FPC for %%I in (fpc.exe) do set "FPC=%%~$PATH:I"
if not defined LAZBUILD for %%I in (lazbuild.exe) do set "LAZBUILD=%%~$PATH:I"
for %%L in ("C:\lazarus" "%ProgramFiles%\Lazarus" "%ProgramFiles(x86)%\Lazarus" "%LOCALAPPDATA%\Lazarus") do (
  if not defined LAZBUILD if exist "%%~L\lazbuild.exe" set "LAZBUILD=%%~L\lazbuild.exe"
  if not defined FPC call :findcompiler "%%~L\fpc"
)
if not defined FPC call :findcompiler "C:\FPC"
if not defined FPC set "FPC=fpc"
if not defined LAZBUILD set "LAZBUILD=lazbuild"
if not defined FPCRES for %%I in ("%FPC%") do if exist "%%~dpIfpcres.exe" set "FPCRES=%%~dpIfpcres.exe"
if not defined FPCRES set "FPCRES=fpcres"
set "DLL_OPTION="
if defined SCU_DLL_DIRECTORY set DLL_OPTION=--dll-directory "%SCU_DLL_DIRECTORY%"

where py.exe >nul 2>nul
if errorlevel 1 goto python
py -3 "%DRIVER%" --gui %GUI_TEST% --fpc "%FPC%" --lazbuild "%LAZBUILD%" --fpcres "%FPCRES%" %DLL_OPTION% %POSITIONAL% %*
exit /b %errorlevel%

:python
where python.exe >nul 2>nul
if errorlevel 1 (
  echo Python 3.10 or newer is required to build SCU. 1>&2
  exit /b 1
)
python "%DRIVER%" --gui %GUI_TEST% --fpc "%FPC%" --lazbuild "%LAZBUILD%" --fpcres "%FPCRES%" %DLL_OPTION% %POSITIONAL% %*
exit /b %errorlevel%

:findcompiler
for /d %%V in ("%~1\*") do if not defined FPC if exist "%%~V\bin\x86_64-win64\fpc.exe" set "FPC=%%~V\bin\x86_64-win64\fpc.exe"
exit /b 0
