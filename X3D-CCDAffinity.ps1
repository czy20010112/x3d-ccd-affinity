<#
.SYNOPSIS
    X3D CCD Affinity Guard - keeps chosen processes on the 3D V-Cache CCD.

.DESCRIPTION
    For AMD dual-CCD X3D CPUs (Ryzen 9 9950X3D / 7950X3D / 9900X3D ...) where only one
    CCD carries the stacked 3D V-Cache. Windows + AMD's 3D V-Cache Performance Optimizer
    normally steer games with the help of the Xbox Game Bar. That fails for titles Game
    Bar does not recognise (indie games, emulators, launchers, private servers).

    This daemon scans the process list on an interval and applies a fixed CPU affinity
    mask to every process named in config.json. It is independent of Game Bar, Game Mode
    and the power plan.

.PARAMETER ConfigPath
    Path to config.json. Defaults to the file next to this script.

.PARAMETER Once
    Scan once, apply, print a report and exit. Useful for testing or for a one-shot run.

.PARAMETER Status
    Print which configured processes are currently running and what affinity they have.

.PARAMETER Reset
    Remove the daemon's affinity rule from running processes by returning them to all CPUs.

.EXAMPLE
    pwsh -File .\X3D-CCDAffinity.ps1 -Status

.EXAMPLE
    pwsh -File .\X3D-CCDAffinity.ps1 -Once
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$Once,
    [switch]$Status,
    [switch]$Reset
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- helpers

$script:LogDir        = Join-Path $PSScriptRoot 'logs'
$script:LogPrefix     = 'x3d-affinity'
$script:LogRetainDays = 14
$script:LogPath       = $null
$script:LogDate       = $null

function Remove-OldLogs {
    param([string]$Prefix, [int]$KeepDays)
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) { return }
        $days = if ($KeepDays -gt 0) { $KeepDays } else { 14 }
        $cutoff = (Get-Date).Date.AddDays(-1 * $days)
        Get-ChildItem -LiteralPath $script:LogDir -Filter ("{0}-*.log" -f $Prefix) -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
}

# Switches the active file when the local date changes (long-running daemon-safe).
function Update-LogPath {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($script:LogDate -ne $today) {
        $script:LogDate = $today
        if (-not (Test-Path -LiteralPath $script:LogDir)) {
            New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        }
        $script:LogPath = Join-Path $script:LogDir ('{0}-{1}.log' -f $script:LogPrefix, $today)
        Remove-OldLogs -Prefix $script:LogPrefix -KeepDays $script:LogRetainDays
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Update-LogPath
    if ($script:LogPath) {
        try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8 } catch { }
    }
    if ($script:VerboseConsole) { Write-Host $line }
}

function Read-Config {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "config not found: $Path" }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    $cfg = $raw | ConvertFrom-Json
    $map = @{}   # lowercase exe name -> rule
    foreach ($g in $cfg.groups) {
        if (-not $g.enabled) { continue }
        $mask = Convert-Mask ([string]$g.mask)
        if ($mask -le 0) { continue }
        foreach ($p in $g.processes) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $key = $p.Trim().ToLowerInvariant()
            $map[$key] = [pscustomobject]@{
                Group    = $g.name
                Mask     = $mask
                Priority = $g.priority
                Pattern  = $key
            }
        }
    }
    return [pscustomobject]@{ Config = $cfg; Map = $map; Stamp = (Get-Item -LiteralPath $Path).LastWriteTimeUtc }
}

function Convert-Mask {
    param([string]$Text)
    if ($Text -match '^0x([0-9a-fA-F]+)$') { return [int64][Convert]::ToInt64($matches[1], 16) }
    if ($Text -match '^\d+$') { return [int64]$Text }
    return [int64]0
}

function Get-TargetProcesses {
    param([hashtable]$Map)
    $result = @()
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        $key = ($p.Name + '.exe').ToLowerInvariant()
        if ($Map.ContainsKey($key)) {
            $result += [pscustomobject]@{ Process = $p; Rule = $Map[$key] }
        }
    }
    return $result
}

function Set-ProcessRule {
    param($Item, [int]$Attempts = 6, [int]$DelayMs = 400)
    $proc = $Item.Process
    $rule = $Item.Rule
    $target = [int64]$rule.Mask
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            if ($proc.HasExited) { return $false }
            $current = [int64]$proc.ProcessorAffinity
            if ($current -ne $target) {
                $proc.ProcessorAffinity = [IntPtr]$target
            }
            if ($rule.Priority) {
                $want = [System.Diagnostics.ProcessPriorityClass][Enum]::Parse([System.Diagnostics.ProcessPriorityClass], [string]$rule.Priority, $true)
                if ($proc.PriorityClass -ne $want) { $proc.PriorityClass = $want }
            }
            $now = [int64]$proc.ProcessorAffinity
            if ($now -eq $target) {
                Write-Log ("pinned {0} (pid {1}) to {2} [{3}]" -f $proc.Name, $proc.Id, $rule.Group, ('0x{0:X}' -f $target))
                return $true
            }
        } catch {
            # Access denied (anti-cheat / elevated process) or process vanished mid-way.
            if ($i -eq $Attempts) {
                Write-Log ("could not pin {0} (pid {1}): {2}" -f $proc.Name, $proc.Id, $_.Exception.Message) 'WARN'
                return $false
            }
        }
        Start-Sleep -Milliseconds $DelayMs
    }
    return $false
}

function Show-Status {
    param($CfgData)
    Write-Host ''
    Write-Host '=== X3D CCD Affinity Guard - status ===' -ForegroundColor Cyan
    Write-Host ("config : {0}" -f $ConfigPath)
    Write-Host ("groups : {0}" -f (($CfgData.Config.groups | ForEach-Object { "{0}({1} entries)" -f $_.name, @($_.processes).Count }) -join ', '))
    $targets = Get-TargetProcesses $CfgData.Map
    if (-not $targets -or $targets.Count -eq 0) {
        Write-Host 'running: no configured process is running right now.' -ForegroundColor Yellow
    } else {
        Write-Host 'running:'
        foreach ($t in $targets) {
            $aff = 'n/a'
            $readable = $true
            try {
                $rawAff = [int64]$t.Process.ProcessorAffinity
                if ($rawAff -le 0) { $readable = $false; $aff = '<no access>' }
                else { $aff = '0x{0:X}' -f $rawAff }
            } catch { $readable = $false; $aff = '<no access>' }
            $ok = if (-not $readable) { 'NOPERM  ' } elseif ($aff -eq ('0x{0:X}' -f [int64]$t.Rule.Mask)) { 'OK      ' } else { 'MISMATCH' }
            Write-Host ("  [{0,-8}] {1,-32} pid {2,-7} affinity {3,-12} group {4}" -f $ok, $t.Process.Name, $t.Process.Id, $aff, $t.Rule.Group)
        }
    }
    Write-Host ''
}

function Invoke-OnePass {
    param($CfgData)
    $targets = Get-TargetProcesses $CfgData.Map
    foreach ($t in $targets) { [void](Set-ProcessRule -Item $t -Attempts 3 -DelayMs 200) }
    return $targets.Count
}

function Clear-Rules {
    param($CfgData)
    $all = [int64]0
    foreach ($g in $CfgData.Config.groups) { $all = $all -bor (Convert-Mask ([string]$g.mask)) }
    $full = ([int64]1 -shl [Environment]::ProcessorCount) - 1
    $targets = Get-TargetProcesses $CfgData.Map
    foreach ($t in $targets) {
        try {
            $t.Process.ProcessorAffinity = [IntPtr]$full
            Write-Log ("released {0} (pid {1}) back to all CPUs" -f $t.Process.Name, $t.Process.Id)
        } catch {
            Write-Log ("could not release {0}: {1}" -f $t.Process.Name, $_.Exception.Message) 'WARN'
        }
    }
}

# ---------------------------------------------------------------- main

$script:VerboseConsole = $true
if ($Once -or $Status -or $Reset) { $script:VerboseConsole = $true } else { $script:VerboseConsole = $false }

try {
    $cfgData = Read-Config -Path $ConfigPath
} catch {
    Write-Host ("failed to load config: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}

# retention comes from config.json when present
try {
    if ($cfgData.Config.PSObject.Properties.Name -contains 'logRetainDays') {
        $script:LogRetainDays = [int]$cfgData.Config.logRetainDays
    }
} catch { }
Update-LogPath

if ($Status) { Show-Status $cfgData; exit 0 }
if ($Reset)  { Clear-Rules $cfgData; Write-Host 'rules cleared'; exit 0 }
if ($Once) {
    $n = Invoke-OnePass $cfgData
    Write-Host ("one-shot pass done, {0} target process(es) seen" -f $n)
    exit 0
}

# ---- daemon mode -------------------------------------------------------
$mutexName = 'Global\X3DCCDAffinityGuard'
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    Write-Host 'another instance is already running; exiting.'
    exit 0
}

Write-Log 'daemon starting'
Write-Log ("config: {0} | groups: {1}" -f $ConfigPath, (($cfgData.Config.groups | ForEach-Object { $_.name }) -join ','))

$lastStamp = $cfgData.Stamp
$handled = @{}      # "pid:mask" -> last verify time
$script:DeniedPids = @{}   # pid -> retry-after, for elevated processes we cannot touch
$cfgGeneration = 0

try {
    while ($true) {
        # hot reload config when the file changes
        try {
            $stamp = (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc
            if ($stamp -ne $lastStamp) {
                $cfgData = Read-Config -Path $ConfigPath
                $lastStamp = $stamp
                $handled.Clear()
                $cfgGeneration++
                Write-Log ("config reloaded (generation {0})" -f $cfgGeneration)
            }
        } catch {
            Write-Log ("config reload failed, keeping previous: {0}" -f $_.Exception.Message) 'WARN'
        }

        $targets = @()
        try { $targets = Get-TargetProcesses $cfgData.Map } catch { Write-Log ("process scan failed: {0}" -f $_.Exception.Message) 'WARN' }

        $livePids = @{}
        foreach ($t in $targets) {
            $pid_ = $t.Process.Id
            $livePids[$pid_] = $true
            # skip processes we already failed on recently (elevated / anti-cheat protected)
            if ($script:DeniedPids.ContainsKey($pid_) -and (Get-Date) -lt $script:DeniedPids[$pid_]) { continue }
            $key = '{0}:{1}' -f $pid_, $t.Rule.Group
            $needSet = $true
            if ($handled.ContainsKey($key)) {
                # already handled: verify periodically in case the game reset it
                try {
                    if ([int64]$t.Process.ProcessorAffinity -eq [int64]$t.Rule.Mask) {
                        $needSet = $false
                        $handled[$key] = Get-Date
                    }
                } catch { $needSet = $false }
            }
            if ($needSet) {
                $ok = Set-ProcessRule -Item $t -Attempts 4 -DelayMs 300
                $handled[$key] = Get-Date
                if (-not $ok) { $script:DeniedPids[$pid_] = (Get-Date).AddSeconds(180) }
            }
        }

        # forget pids that went away
        foreach ($k in @($handled.Keys)) {
            $p = [int]($k -split ':')[0]
            if (-not $livePids.ContainsKey($p)) { $handled.Remove($k) }
        }

        Start-Sleep -Seconds ([int]$cfgData.Config.pollSeconds)
    }
}
finally {
    Write-Log 'daemon stopping'
    try { $mutex.ReleaseMutex() } catch { }
    try { $mutex.Dispose() } catch { }
}


