# Worry-Free → Vision One Standard Endpoint Protection Migration

Automated migration from Worry-Free Business Security Services (WFBS-SVC) to
Trend Vision One Endpoint Security with **Standard Endpoint Protection (SEP)**.
One launch, zero manual steps: removal, cleanup, reboot, and SEP deployment are
fully handled by the script.

## Package Contents

```
WF_migration\
├── V1_Migrate.bat      Main script - run this (as Administrator)
├── V1_Deploy.ps1       V1 deployment script (TENANT-SPECIFIC - see below)
├── WFBS\
│   ├── SCUT.exe        WFBS removal tool (SCUT) - EXPIRES MONTHLY
│   └── SCUT.exe.config
├── docs\               Deployment / test guides
└── archive\            Unused legacy files (safe to delete)
```

## IMPORTANT: SCUT.exe expires monthly

The bundled `WFBS\SCUT.exe` has a **monthly expiry**. An expired SCUT will
fail silently or return a non-zero exit code. Before each migration batch,
download a fresh copy from the
[Trend Micro Partner Portal](https://partner.trendmicro.com) and replace
`WFBS\SCUT.exe` in this folder. Keep `SCUT.exe.config` as-is.

## IMPORTANT: V1_Deploy.ps1 is tenant-specific

The bundled `V1_Deploy.ps1` contains the company ID and agent tokens of ONE
Vision One tenant. **For every customer tenant, generate a fresh script:**

1. Vision One console → **Endpoint Security > Endpoint Inventory > Agent Installer**
2. Select **Windows**, deployment script, with **Standard Endpoint Protection**
   included (agent must be tied to a Protection Manager)
3. Download and replace `V1_Deploy.ps1` in this folder
4. Recommended: extend the SEP wait in the downloaded script — change
   `$MAX_RETRY = 30` to `$MAX_RETRY = 120` in the "Check SEP is installed"
   section (SEP component download can take 10-20 min; the default 5 min
   wait reports failure prematurely)

## Usage

1. Copy the whole folder to the endpoint (keep the structure - the bat expects
   `V1_Deploy.ps1` and `WFBS\` beside it)
2. Open an elevated prompt and run:
   ```
   cd <folder>
   V1_Migrate.bat        (CMD)
   .\V1_Migrate.bat      (PowerShell)
   ```
3. Walk away. **The machine restarts automatically** — once after WFBS removal
   (30-second warning), and a second time only if .NET 3.5 had to be installed.
   The script resumes on its own (Scheduled Task `V1Migration`, SYSTEM, at startup).
   Schedule in a maintenance window; unsaved work on the endpoint will be lost.

## What it does

| Phase | Action |
|-------|--------|
| Pre   | Verifies/installs .NET 3.5 (reboots + resumes if DISM requires it) |
| 1     | Runs SCUT to remove WFBS (progress logged every 5 min, 60-min watchdog), waits until the WFBS service AND directory are gone, force-deletes leftovers, removes WFBS registry remnants, reboots |
| 2     | Pre-flight re-check (aborts if WFBS service present; re-cleans directory/registry leftovers), runs `V1_Deploy.ps1` which downloads the installer from Vision One, installs, and waits until SEP services are RUNNING |

**Success = the log ends with:**
`Standard Endpoint Protection installed - tmlisten and ntrtscan services running.`
Basecamp alone is NOT success - SEP services must be running.

## Logs

| Log | Path |
|-----|------|
| Migration summary | `C:\Windows\Temp\V1Deploy\Logs\migration.log` |
| Verbose (SCUT + installer output) | `C:\Windows\Temp\V1Deploy\Logs\migration_verbose.log` |
| Deployment script transcript | `%APPDATA%\Trend Micro\V1ES\v1es_install.log` (post-reboot phase runs as SYSTEM: `C:\Windows\System32\config\systemprofile\AppData\Roaming\Trend Micro\V1ES\v1es_install.log`) |
| Basecamp agent log | `C:\Program Files (x86)\Trend Micro\Endpoint Basecamp\log\EndpointBasecamp.log` |

Monitor a run live:
```powershell
Get-Content C:\Windows\Temp\V1Deploy\Logs\migration.log -Tail 5 -Wait
```

## Network requirements

Outbound HTTPS (443) only - no inbound rules needed. Key US-region FQDNs:
`api-us1.xbc.trendmicro.com`, `wsc-us1.xbc.trendmicro.com`,
`endpointpolicy-cdn-us1.xbc.trendmicro.com`, `release-us1.mgcp.trendmicro.com`,
`iaus.activeupdate.trendmicro.com`, `osce14-p.activeupdate.trendmicro.com`,
`licenseupdate.trendmicro.com`, `osce14.icrc.trendmicro.com`.
Full list: Vision One console > Firewall Exceptions, or docs.trendmicro.com
"United States - firewall exceptions". Verify DNS resolution works on the
endpoint (cloud VMs with VPC resolvers may need a public secondary DNS).

## Troubleshooting

- **SCUT fails or exits non-zero immediately** - SCUT.exe has likely expired.
  Download a fresh copy from the [Partner Portal](https://partner.trendmicro.com)
  and replace `WFBS\SCUT.exe`.
- **"FATAL: WFBS remnants detected / ntrtscan service present"** - SCUT did not
  finish. Re-run the bat; if it repeats, run `WFBS\SCUT.exe -noinstall`
  manually and check `ComUnist.log`.
- **Deployment script exit 1 after "agent is registered"** - SEP components
  still downloading; check the endpoint in the V1 console. If the console shows
  "Worry Free ... agent is detected", registry remnants exist - re-run the bat
  (Phase 2 pre-flight removes them).
- **Stale state before a re-test**: `schtasks /delete /tn "V1Migration" /f`
  and delete `C:\Windows\Temp\V1Deploy`.

---
*Maintained by: Manveer Singh (manveer_singh@trendmicro.com) | Last updated 2026-07-21*
