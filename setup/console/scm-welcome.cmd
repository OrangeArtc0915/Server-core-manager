@echo off
rem ServerCoreManager: welcome note for interactive cmd (managed by ServerCoreManager)
rem --force: called by the "cls" doskey macro - always print, skip the guards below
if "%~1"=="--force" goto :show
rem guard: AutoRun runs for every new cmd instance - this flag makes sure it runs only once
if defined SCM_WELCOME_DONE exit /b 0
set SCM_WELCOME_DONE=1
rem stay silent for non-interactive calls (cmd /c ...) - no pipes, no external commands
set "SCM_CL=%CMDCMDLINE:"=%"
if not "%SCM_CL:/c=%"=="%SCM_CL%" exit /b 0
rem make "cls" print the note again: doskey macros are per-process, so register on every start
doskey cls=cls $T "%~f0" --force >nul 2>&1
:show
echo.
if exist "%SystemRoot%\System32\sconfig.cmd"  echo   [93mÊäÈë "Sconfig" ·µ»Ø·þÎñÆ÷²Ëµ¥[0m
if exist "%SystemRoot%\System32\scm.cmd"      echo   [93mÊäÈë "scm" ´ò¿ª GUI ¹¤¾ß[0m
echo.