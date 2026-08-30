@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem Native-Windows adapter for Codex lifecycle hooks. Git for Windows may coexist
rem with WSL's C:\Windows\System32\bash.exe, so never invoke an unqualified bash.
rem Resolve bash.exe relative to each git.exe on PATH; this supports the standard
rem cmd\git.exe -> bin\bash.exe layout and custom distributions whose git.exe and
rem bash.exe share bin\, without assuming an installation root.
set "FORGEWARD_BASH="
for /f "delims=" %%G in ('where git.exe 2^>nul') do (
  call :probe_git "%%~fG"
  if defined FORGEWARD_BASH goto run
)

rem This lifecycle hook is fast feedback, not the enforcement boundary. If no
rem Git-Bash-compatible shell can be proved runnable, fail open instead of wedging
rem every Codex prompt and Bash tool call.
exit /b 0

:probe_git
for %%D in ("%~1") do set "FORGEWARD_GIT_DIR=%%~dpD"
call :probe_bash "%FORGEWARD_GIT_DIR%bash.exe"
if defined FORGEWARD_BASH exit /b 0
call :probe_bash "%FORGEWARD_GIT_DIR%..\bin\bash.exe"
if defined FORGEWARD_BASH exit /b 0
call :probe_bash "%FORGEWARD_GIT_DIR%..\usr\bin\bash.exe"
exit /b 0

:probe_bash
if not exist "%~1" exit /b 0
"%~1" --noprofile --norc -c "exit 0" >nul 2>&1
if errorlevel 1 exit /b 0
set "FORGEWARD_BASH=%~1"
exit /b 0

:run
"%FORGEWARD_BASH%" --noprofile --norc "%~dp0forgeward-gate-check.sh" "%~1"
exit /b %ERRORLEVEL%
