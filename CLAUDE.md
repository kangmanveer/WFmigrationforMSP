# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Windows migration automation toolkit for transitioning enterprise endpoints from **Trend Micro Worry-Free Business Security Services (WFBS-SVC)** to **Trend Vision One Standard Endpoint Protection (SEP)**. This is a systems administration utility (batch + PowerShell), not a traditional software project — there is no build system, package manager, or test suite.

## Entry Point

`V1_Migrate.bat` — run as Administrator. The script is self-elevating (re-launches with `powershell -Verb RunAs` if needed).

## Three-Phase Migration Flow

1. **Pre-Phase (.NET 3.5):** Checks/installs .NET Framework 3.5 via DISM. Reboots and resumes via Scheduled Task if installation required (DISM exit 3010).
2. **Phase 1 (WFBS Removal):** Stages SCUT.exe, stops Trend services, runs SCUT with 60-min watchdog, polls for service/directory removal, force-deletes leftover registry keys, reboots.
3. **Phase 2 (V1 Installation):** Pre-flight checks for existing V1 services, validates DNS connectivity (100s timeout), executes tenant-specific `V1_Deploy.ps1`, waits for SEP services (tmlisten + ntrtscan) to reach RUNNING.

Post-reboot persistence uses Scheduled Task `V1Migration` running at SYSTEM privilege on startup.

## Key Files

- `V1_Migrate.bat` — Main orchestration script (~303 lines, batch)
- `V1_Deploy.ps1` — Tenant-specific deployment script (generated per-customer from Vision One console, **not committed with real tokens**)
- `WFBS/SCUT.exe` — Binary tool for WFBS removal (PE32 .NET assembly)
- `WFBS/SCUT.exe.config` — .NET runtime config (v2/v4 support)

## Customization Points

- **V1_Deploy.ps1** must be regenerated per customer tenant from the Vision One console (Endpoint Security > Agent Installer)
- In the downloaded V1_Deploy.ps1, change `$MAX_RETRY = 30` to `$MAX_RETRY = 120` in the "Check SEP is installed" section — default 5-min timeout is too short for SEP component downloads

## Code Patterns

- **Batch subroutines:** `:label` blocks called via `call :subroutine`
- **Delayed expansion:** `setlocal EnableDelayedExpansion` for variable expansion in loops
- **Logging:** Native timestamp format `[%date:~10,4%-%date:~4,2%-%date:~7,2% %time:~0,8%]`, dual output to summary and verbose log files
- **Error handling:** Explicit `%errorlevel%` checks, special DISM 3010 handling, 60-min SCUT watchdog with `taskkill`
- **PowerShell integration:** `Unblock-File`, `Get-WindowsOptionalFeature`, `Resolve-DnsName` — inbox cmdlets only, no module dependencies
- **PS 5.1 compatibility required:** No PowerShell 7+ syntax (ternary operators, etc.)

## Log Locations

| Log | Path |
|-----|------|
| Migration summary | `C:\Windows\Temp\V1Deploy\Logs\migration.log` |
| Verbose | `C:\Windows\Temp\V1Deploy\Logs\migration_verbose.log` |
| SCUT output | `C:\Windows\Temp\V1Deploy\Logs\scut_output.log` |
| Deployment transcript | `%APPDATA%\Trend Micro\V1ES\v1es_install.log` |

## Testing

No automated tests. Validate in a lab environment with a Worry-Free tenant and a Vision One tenant. Monitor live with:
```powershell
Get-Content C:\Windows\Temp\V1Deploy\Logs\migration.log -Tail 5 -Wait
```

Success = log ends with: `Standard Endpoint Protection installed - tmlisten and ntrtscan services running.`
