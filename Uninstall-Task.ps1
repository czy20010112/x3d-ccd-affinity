# Remove the X3D CCD Affinity Guard scheduled task and release any pinned processes.
[CmdletBinding()]
param(
    [string]$TaskName = 'X3D CCD Affinity Guard',
    [switch]$ReleaseProcesses
)

$ErrorActionPreference = 'Continue'
$tool = $PSScriptRoot

Write-Host "stopping and unregistering task '$TaskName' ..."
try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch { }
try {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host 'scheduled task removed.'
} catch {
    Write-Warning ("failed to remove task: {0}" -f $_.Exception.Message)
}

# also drop the startup-folder fallback if it was used
$vbs = Join-Path ([Environment]::GetFolderPath('Startup')) 'X3D-CCDAffinity.vbs'
if (Test-Path -LiteralPath $vbs) {
    Remove-Item -LiteralPath $vbs -Force
    Write-Host ("removed startup launcher: {0}" -f $vbs)
}

# kill any leftover daemon
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'X3D-CCDAffinity\.ps1' } |
    ForEach-Object {
        try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Write-Host ("stopped daemon pid {0}" -f $_.ProcessId) } catch { }
    }

if ($ReleaseProcesses) {
    $main = Join-Path $tool 'X3D-CCDAffinity.ps1'
    if (Test-Path -LiteralPath $main) {
        & pwsh -NoProfile -File $main -Reset
    }
}

Write-Host 'done.'
