@echo off
setlocal EnableDelayedExpansion

:: -- CONFIGURATION ---------------------------------------------------------
set "scriptVer=1.2"
set "dryRun=0"
if /i "%~1"=="--dry-run" set "dryRun=1"
:: srcSCUT: WFBS folder bundled alongside this script (contains SCUT.exe + EndpointBasecamp.exe)
set "srcSCUT=%~dp0WFBS"
set "stageDir=C:\Windows\Temp\V1Deploy"
set "logDir=%stageDir%\Logs"
set "logFile=%logDir%\migration.log"
set "verbLog=%logDir%\migration_verbose.log"
set "scutExe=SCUT.exe"
set "rebootFlag=%stageDir%\reboot.flag"
set "dotnetFlag=%stageDir%\dotnet.flag"
set "retryFile=%stageDir%\retry.count"
set "maxRetries=3"

:: -- SELF-ELEVATE ----------------------------------------------------------
net session >nul 2>&1 || (
    echo [WARN] Not admin. Elevating...
    powershell -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    exit /b
)

if not exist "%logDir%" mkdir "%logDir%"
goto :main

:: -- SUBROUTINES -----------------------------------------------------------

:: :log [LEVEL] [MESSAGE]
:: Uses wmic for locale-independent timestamps (works in all Windows locales).
:log
    set "_dt="
    for /f "tokens=2 delims==" %%t in ('wmic os get localdatetime /value 2^>nul') do for /f %%s in ("%%t") do set "_dt=%%s"
    set "_e=[!_dt:~0,4!-!_dt:~4,2!-!_dt:~6,2! !_dt:~8,2!:!_dt:~10,2!:!_dt:~12,2!] [%~1] %~2"
    echo !_e!
    echo !_e!>>"%logFile%"
    echo !_e!>>"%verbLog%"
    goto :eof

:: :persist - register script for post-reboot resume via Scheduled Task (SYSTEM, fires at startup)
:persist
    if !dryRun! equ 1 (
        call :log "DRY-RUN" "Would create Scheduled Task 'V1Migration' (SYSTEM, ONSTART)"
        goto :eof
    )
    schtasks /create /tn "V1Migration" /tr "cmd.exe /c \"%~f0\"" /sc ONSTART /ru SYSTEM /rl HIGHEST /f >nul 2>&1
    call :log "INFO" "Scheduled Task 'V1Migration' set for post-reboot resume."
    goto :eof

:: :unpersist - remove the scheduled task when no longer needed
:unpersist
    if !dryRun! equ 1 (
        call :log "DRY-RUN" "Would delete Scheduled Task 'V1Migration'"
        goto :eof
    )
    schtasks /delete /tn "V1Migration" /f >nul 2>&1
    goto :eof

:: :status [STEP_NUM] [DESCRIPTION]
:: Shows a progress bar in the console and updates the window title.
:: 8-step model: 1=.NET 2=Stage 3=StopSvc 4=SCUT 5=VerifyRemoval 6=Registry 7=Deploy 8=Done
:status
    set "_sN=%~1"
    set "_sD=%~2"
    title V1 Migration [!_sN!/8] !_sD!
    if "!_sN!"=="1" set "_pb=##.................."
    if "!_sN!"=="2" set "_pb=#####..............."
    if "!_sN!"=="3" set "_pb=#######............."
    if "!_sN!"=="4" set "_pb=##########.........."
    if "!_sN!"=="5" set "_pb=############........"
    if "!_sN!"=="6" set "_pb=###############....."
    if "!_sN!"=="7" set "_pb=#################..."
    if "!_sN!"=="8" set "_pb=####################"
    echo.
    echo   [!_pb!] Step !_sN!/8: !_sD!
    echo.
    goto :eof


:main

call :log "INFO" "========================================================"
call :log "INFO" "V1 Migration v%scriptVer%  |  Host: %COMPUTERNAME%  |  User: %USERNAME%"
for /f "delims=" %%v in ('ver') do call :log "INFO" "OS: %%v"
if !dryRun! equ 1 call :log "INFO" "*** DRY-RUN MODE - no changes will be made ***"
call :log "INFO" "========================================================"

:: -- PRE-PHASE: .NET 3.5 --------------------------------------------------
call :status 1 "Verifying .NET 3.5 prerequisites"
call :log "INFO" "PRE-PHASE: Checking .NET 3.5 (NetFx3)..."

:: FIX: was using PS7 ternary (?:) which fails on PS 5.1 (all Windows 10/11 inbox PS)
powershell -NoProfile -Command "if ((Get-WindowsOptionalFeature -Online -FeatureName NetFx3).State -eq 'Enabled') { exit 0 } else { exit 1 }"
if %errorlevel% equ 0 (
    call :log "INFO" ".NET 3.5 already enabled."
    goto :phase1
)

call :log "WARN" ".NET 3.5 not enabled - installing via DISM..."
if !dryRun! equ 1 (
    call :log "DRY-RUN" "Would run: dism.exe /Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart"
    call :log "DRY-RUN" "Would reboot if DISM returns 3010"
    goto :phase1
)
dism.exe /Online /Enable-Feature /FeatureName:NetFx3 /All /NoRestart >>"%verbLog%" 2>&1
set "_rc=%errorlevel%"

if %_rc% equ 0 (
    call :log "INFO" ".NET 3.5 installed."
    goto :phase1
)
if %_rc% equ 3010 (
    call :log "WARN" ".NET 3.5 installed - reboot required."
    echo dotnet35>"%dotnetFlag%"
    call :persist
    shutdown /r /t 30 /c "TrendAI migration: .NET 3.5 installed - rebooting."
    exit /b
)
call :log "ERROR" "FATAL: DISM failed (exit %_rc%). Aborting."
exit /b 1

:: -- PHASE 1: WFBS-SVC Removal --------------------------------------------
:phase1
call :log "INFO" "PHASE 1: Checking for WFBS-SVC (ntrtscan)..."

if exist "%rebootFlag%" (
    echo.
    echo   Resuming migration after reboot...
    echo.
    call :log "INFO" "Post-reboot resume - skipping Phase 1, proceeding to Phase 2."
    goto :phase2
)

sc query ntrtscan >nul 2>&1
if %errorlevel% neq 0 (
    call :log "INFO" "ntrtscan not present - no removal needed."
    goto :phase2
)

call :status 2 "Staging SCUT removal tool"
call :log "INFO" "ntrtscan detected. Starting WFBS-SVC removal..."

if !dryRun! equ 1 (
    call :log "DRY-RUN" "Would stage SCUT files to %stageDir%\SCUT\"
    call :status 3 "Stopping WFBS protection services"
    call :log "DRY-RUN" "Would stop services: TMiCRCScanService, TmPfw, TmPreFilter, VSApiNt, TmCCSF"
    call :status 4 "Running SCUT removal (20-35 min typical)"
    call :log "DRY-RUN" "Would run SCUT -noinstall with 60-min watchdog"
    call :status 5 "Verifying WFBS removal"
    call :log "DRY-RUN" "Would poll for WFBS service/directory removal (max 300s)"
    goto :scutDone
)

if not exist "%stageDir%" mkdir "%stageDir%"

xcopy /E /I /Y "%srcSCUT%" "%stageDir%\SCUT\" >>"%verbLog%" 2>&1
if %errorlevel% neq 0 (
    call :log "ERROR" "FATAL: Failed to copy WFBS folder (exit %errorlevel%)."
    exit /b 1
)

set "scutPath=%stageDir%\SCUT\%scutExe%"
if not exist "%scutPath%" (
    call :log "ERROR" "FATAL: %scutExe% not found at %scutPath%."
    exit /b 1
)

powershell -NoProfile -Command "Unblock-File '%scutPath%' -ErrorAction SilentlyContinue"

call :status 3 "Stopping WFBS protection services"
call :log "INFO" "Stopping Trend self-protection services..."
for %%s in (TMiCRCScanService TmPfw TmPreFilter VSApiNt TmCCSF) do (
    sc query %%s >nul 2>&1 && net stop %%s /y >>"%verbLog%" 2>&1
)

:: Run SCUT in a helper process so this script can log progress and enforce a
:: hard timeout. SCUT typically takes 20-35 min; without a watchdog a hung SCUT
:: blocks the migration forever with zero feedback to the operator.
del /f /q "%stageDir%\scut.exit" 2>nul
:: SCUT output goes to its own file - sharing %verbLog% with the :log routine
:: causes "file in use" errors (append redirects do not share write access).
> "%stageDir%\scut_run.cmd" (
    echo @echo off
    echo "%scutPath%" -noinstall ^>^>"%logDir%\scut_output.log" 2^>^&1
    echo ^(echo %%errorlevel%%^)^>"%stageDir%\scut.exit"
)
call :status 4 "Running SCUT removal (20-35 min typical)"
call :log "INFO" "Running SCUT -noinstall (typical runtime 20-35 min - progress logged every 5 min)..."
start "SCUT" /min "%stageDir%\scut_run.cmd"

set "_scutMin=0"
:scutWatch
    if exist "%stageDir%\scut.exit" goto :scutExited
    ping -n 61 127.0.0.1 >nul
    set /a "_scutMin+=1"
    title V1 Migration [4/8] Running SCUT removal - !_scutMin! min elapsed
    set /a "_scutMod=_scutMin %% 5"
    if !_scutMod! equ 0 call :log "INFO" "SCUT still running (!_scutMin! min elapsed)..."
    if !_scutMin! geq 60 (
        call :log "ERROR" "FATAL: SCUT exceeded 60 min - killing process tree and aborting. Check %verbLog% and ComUnist.log."
        taskkill /f /im SCUT.exe /t >nul 2>&1
        exit /b 1
    )
    goto :scutWatch
:scutExited
set /p _scutExit=<"%stageDir%\scut.exit"
if not defined _scutExit set "_scutExit=-1"
call :log "INFO" "SCUT exited: !_scutExit! (after ~!_scutMin! min)"

:: FIX: previously ignored SCUT exit code and rebooted unconditionally
if !_scutExit! neq 0 (
    call :log "ERROR" "FATAL: SCUT failed (exit !_scutExit!). Aborting - not rebooting."
    exit /b 1
)

:: FIX: SCUT spawns background uninstall processes and exits 0 immediately.
:: Poll until WFBS service and directory are gone (max 300s) before rebooting.
:: Registry remnants are not polled (they never clear on their own) - they are
:: force-deleted after this loop completes.
call :status 5 "Verifying WFBS removal"
call :log "INFO" "Waiting for SCUT to fully remove WFBS (max 300s)..."
set "_waitCount=0"
:waitSCUT
    set "_wfbsClean=1"
    sc query ntrtscan >nul 2>&1
    if !errorlevel! equ 0 set "_wfbsClean=0"
    if exist "C:\Program Files (x86)\Trend Micro\Security Agent" set "_wfbsClean=0"
    if !_wfbsClean! equ 1 (
        call :log "INFO" "WFBS fully removed - service and directory gone."
        goto :scutDone
    )
    set /a "_waitCount+=1"
    rem Timeout fallback: if only the directory remains (SCUT often leaves temp
    rem logs behind), delete it directly. Only abort if that fails too.
    if !_waitCount! geq 60 (
        sc query ntrtscan >nul 2>&1
        if !errorlevel! equ 0 (
            call :log "ERROR" "FATAL: ntrtscan service still present after 300s. Aborting - do not reboot. Run SCUT manually and retry."
            exit /b 1
        )
        call :log "WARN" "Timeout - only Security Agent directory remains. Attempting direct delete..."
        rmdir /s /q "C:\Program Files (x86)\Trend Micro\Security Agent" >nul 2>&1
        if exist "C:\Program Files (x86)\Trend Micro\Security Agent" (
            call :log "ERROR" "FATAL: Could not delete Security Agent directory (locked files). Reboot, delete it manually, then re-run this script."
            exit /b 1
        )
        call :log "INFO" "Security Agent directory deleted - WFBS removal complete."
        goto :scutDone
    )
    ping -n 6 127.0.0.1 >nul
    goto :waitSCUT
:scutDone

:: Delete WFBS registry remnants. SCUT often leaves these ("agent REG has not
:: been removed completely") and the V1 agent compatibility check reads them,
:: blocking SEP install with "Worry Free Business Security Service detected".
:: Only WFBS-specific keys are removed - Basecamp/V1 keys (TMSecurityService,
:: cep, V1ES, Falcon, Kestrel, NetFilter, etc.) are untouched.
call :status 6 "Cleaning WFBS registry remnants"
if !dryRun! equ 1 (
    call :log "DRY-RUN" "Would delete registry keys: PC-cillinNTCorp, OfficeScan, OSCEUpdater, WFBSSUpdater"
    call :log "DRY-RUN" "Would reboot in 30s - continuing to Phase 2 instead"
    goto :phase2
)
call :log "INFO" "Removing WFBS registry remnants..."
for %%k in (PC-cillinNTCorp OfficeScan OSCEUpdater WFBSSUpdater) do (
    reg delete "HKLM\SOFTWARE\WOW6432Node\TrendMicro\%%k" /f >nul 2>&1
    reg delete "HKLM\SOFTWARE\TrendMicro\%%k" /f >nul 2>&1
)
call :log "INFO" "WFBS registry remnants removed."

echo reboot>"%rebootFlag%"
call :persist
title V1 Migration - Phase 1 complete, rebooting...
call :log "INFO" "PHASE 1 complete - rebooting in 30s..."
shutdown /r /t 30 /c "TrendAI migration: WFBS-SVC removed."
exit /b

:: -- PHASE 2: Vision One Installation -------------------------------------
:phase2
call :log "INFO" "PHASE 2: Checking for existing Vision One agent..."

:: Retry guard - abort after maxRetries consecutive failures to prevent loops
set "_retries=0"
if exist "%retryFile%" (
    set /p _retries=<"%retryFile%"
    if not defined _retries set "_retries=0"
)
if !_retries! geq %maxRetries% (
    call :log "ERROR" "FATAL: Phase 2 failed after %maxRetries% attempts. Manual intervention required."
    call :unpersist
    del /f /q "%rebootFlag%" "%dotnetFlag%" "%retryFile%" 2>nul
    exit /b 1
)

:: FIX: removed ntrtscan from this list - it is a WFBS-SVC service, not a V1 service.
:: If SCUT had failed silently, ntrtscan would have caused a false-positive skip of V1ES install.
for %%s in (tmlisten amsp ds_agent) do (
    sc query %%s 2>nul | findstr /i "RUNNING" >nul 2>&1
    if !errorlevel! equ 0 (
        call :log "INFO" "V1 service %%s already running - skipping install."
        goto :cleanup
    )
)

call :log "INFO" "No V1 agent found - deploying via V1 deployment script..."
if not exist "%stageDir%" mkdir "%stageDir%"

:: V1_Deploy.ps1 = deployment script from Vision One Endpoint Inventory.
:: Downloads the installer package live from XBC, installs with /is_full_package true,
:: waits for agent registration, then waits until SEP services (tmlisten + ntrtscan)
:: are RUNNING. Exit 0 = Standard Endpoint Protection fully installed and running.
set "deployPs1=%~dp0V1_Deploy.ps1"
if not exist "%deployPs1%" (
    call :log "ERROR" "FATAL: V1_Deploy.ps1 not found next to this script. Place the Endpoint Inventory deployment script alongside V1_Migrate.bat."
    exit /b 1
)
:: Validate V1_Deploy.ps1 is a real deployment script (not empty/corrupt)
findstr /i "Invoke-WebRequest XBC_FQDN" "%deployPs1%" >nul 2>&1
if %errorlevel% neq 0 (
    call :log "ERROR" "FATAL: V1_Deploy.ps1 does not appear to be a valid deployment script (missing expected content)."
    exit /b 1
)

:: Safety check: abort if WFBS service detected - would cause sensor-only install.
sc query ntrtscan >nul 2>&1
if !errorlevel! equ 0 (
    call :log "ERROR" "FATAL: ntrtscan service present. Installer would deploy sensor-only. Run SCUT to completion and retry."
    exit /b 1
)
if exist "C:\Program Files (x86)\Trend Micro\Security Agent" (
    if !dryRun! equ 1 (
        call :log "DRY-RUN" "Would delete leftover Security Agent directory"
    ) else (
        call :log "WARN" "Leftover Security Agent directory found - attempting delete..."
        rmdir /s /q "C:\Program Files (x86)\Trend Micro\Security Agent" >nul 2>&1
        if exist "C:\Program Files (x86)\Trend Micro\Security Agent" (
            call :log "ERROR" "FATAL: Could not delete Security Agent directory (locked files). Reboot, delete it manually, then re-run this script."
            exit /b 1
        )
        call :log "INFO" "Leftover directory deleted."
    )
)

:: Delete WFBS registry remnants (blocks "Worry Free agent detected" compatibility error).
:: Runs post-reboot too, so remnants are cleared even if Phase 1 ran before this fix.
if !dryRun! equ 1 (
    call :log "DRY-RUN" "Would delete WFBS registry remnants"
) else (
    for %%k in (PC-cillinNTCorp OfficeScan OSCEUpdater WFBSSUpdater) do (
        reg delete "HKLM\SOFTWARE\WOW6432Node\TrendMicro\%%k" /f >nul 2>&1
        reg delete "HKLM\SOFTWARE\TrendMicro\%%k" /f >nul 2>&1
    )
)

:: Post-reboot this runs at system startup - the network stack may not be up
:: yet. Wait until the deployment FQDN resolves (max 100s) before downloading.
set "_xbcFqdn=trendmicro.com"
:: FIX: match $XBC_FQDN with or without spaces around '=', then trim whitespace/quotes
for /f "tokens=2 delims==" %%a in ('findstr /b /c:"$XBC_FQDN" "%deployPs1%"') do (
    for /f "delims= " %%b in ("%%~a") do set "_xbcFqdn=%%~b"
)
call :status 7 "Deploying Vision One agent"
call :log "INFO" "Waiting for network (resolving !_xbcFqdn!)..."
set "_netWait=0"
:netWait
    powershell -NoProfile -Command "if (Resolve-DnsName '!_xbcFqdn!' -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }" >nul 2>&1
    if !errorlevel! equ 0 goto :netReady
    set /a "_netWait+=1"
    title V1 Migration [7/8] Waiting for network (!_netWait!/20)...
    if !_netWait! geq 20 (
        call :log "WARN" "Network not confirmed after 100s - proceeding anyway."
        goto :netReady
    )
    ping -n 6 127.0.0.1 >nul
    goto :netWait
:netReady

title V1 Migration [7/8] Installing SEP (this may take 10-20 min)...
call :log "INFO" "Running V1 deployment script (downloads installer, installs SEP, waits for services)..."
if !dryRun! equ 1 (
    call :log "DRY-RUN" "Would run: powershell -File V1_Deploy.ps1"
    call :log "DRY-RUN" "Simulating successful deployment (exit 0)"
    set "_installerExit=0"
    goto :deployDone
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%deployPs1%" >>"%verbLog%" 2>&1
set "_installerExit=%errorlevel%"
:deployDone
call :log "INFO" "Deployment script exited: %_installerExit%"

if %_installerExit% equ 0 (
    :: Detect which product was installed
    sc query ds_agent 2>nul | findstr /i "RUNNING" >nul 2>&1
    if !errorlevel! equ 0 (
        call :status 8 "Server and Workload Protection verified"
        call :log "INFO" "Server and Workload Protection agent installed - ds_agent service running."
    ) else (
        call :status 8 "Standard Endpoint Protection verified"
        call :log "INFO" "Standard Endpoint Protection installed - tmlisten and ntrtscan services running."
    )
) else (
    title V1 Migration - FAILED (exit %_installerExit%)
    set /a "_retries+=1"
    echo !_retries!>"%retryFile%"
    call :log "ERROR" "Deployment failed (exit %_installerExit%). Attempt !_retries! of %maxRetries%."
    call :log "ERROR" "See %verbLog% and %%appdata%%\Trend Micro\V1ES\v1es_install.log."
    call :log "WARN" "Scheduled task kept - will retry on next reboot."
    exit /b 1
)

:cleanup
call :unpersist
if !dryRun! equ 1 (
    call :log "DRY-RUN" "Would delete flag files and staged SCUT files"
) else (
    del /f /q "%rebootFlag%" "%dotnetFlag%" "%retryFile%" 2>nul
    :: Clean staged SCUT files (keep logs)
    if exist "%stageDir%\SCUT" rmdir /s /q "%stageDir%\SCUT" >nul 2>&1
    del /f /q "%stageDir%\scut_run.cmd" "%stageDir%\scut.exit" 2>nul
)

title V1 Migration - Complete
call :log "INFO" "========================================================"
call :log "INFO" "Migration complete  |  Host: %COMPUTERNAME%"
call :log "INFO" "Staged files: %stageDir%  |  Logs: %logDir%"
call :log "INFO" "========================================================"

endlocal
exit /b 0
