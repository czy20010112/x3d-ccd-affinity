# Install X3D CCD Affinity Guard as a logon task for the current user (no admin needed).
[CmdletBinding()]
param(
    [string]$TaskName = 'X3D CCD Affinity Guard',
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
$tool    = $PSScriptRoot
$script  = Join-Path $tool 'X3D-CCDAffinity.ps1'
$pwshExe = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
if (-not $pwshExe) { $pwshExe = (Get-Command powershell.exe).Source }

if (-not (Test-Path -LiteralPath $script)) { throw "main script missing: $script" }

$argLine = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $script

Write-Host "tool    : $tool"
Write-Host "shell   : $pwshExe"
Write-Host "args    : $argLine"

# remove any previous registration
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$action  = New-ScheduledTaskAction -Execute $pwshExe -Argument $argLine -WorkingDirectory $tool
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$level   = if ($Elevated) { 'Highest' } else { 'Limited' }
try {
    $principal = New-ScheduledTaskPrincipal -UserId ("{0}\{1}" -f $env:USERDOMAIN, $env:USERNAME) -LogonType Interactive -RunLevel $level
} catch {
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel $level
}
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew

$ok = $false
try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Pins configured game processes to the 3D V-Cache CCD (Ryzen 9950X3D).' | Out-Null
    $ok = $true
} catch {
    Write-Warning ("Register-ScheduledTask failed: {0}" -f $_.Exception.Message)
}

if (-not $ok) {
    Write-Host 'falling back to schtasks.exe ...'
    $rl = if ($Elevated) { 'HIGHEST' } else { 'LIMITED' }
    $tr = '"{0}" {1}' -f $pwshExe, $argLine
    & schtasks.exe /create /tn $TaskName /tr $tr /sc onlogon /rl $rl /f | Out-Host
    $ok = ($LASTEXITCODE -eq 0)
}

if (-not $ok) {
    Write-Warning 'scheduled task path failed; installing a Startup-folder launcher instead.'
    $startup = [Environment]::GetFolderPath('Startup')
    $vbs = Join-Path $startup 'X3D-CCDAffinity.vbs'
    $content = @"
Set sh = CreateObject("WScript.Shell")
sh.Run """$pwshExe"" $argLine", 0, False
"@
    Set-Content -LiteralPath $vbs -Value $content -Encoding ascii
    Write-Host ("startup launcher written: {0}" -f $vbs)
}

Write-Host ''
Write-Host 'starting the guard now ...'
Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($t) {
    $i = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host ("task    : {0} [{1}]" -f $t.TaskName, $t.State)
    Write-Host ("last run: {0}  result {1}" -f $i.LastRunTime, $i.LastTaskResult)
}
Get-Process pwsh -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -eq '' } |
    ForEach-Object { } # no-op, keeps output clean
Write-Host ''
Write-Host 'done.'
