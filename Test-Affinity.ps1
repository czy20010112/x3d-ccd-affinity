# Verify the affinity mechanism end-to-end without touching real games.
$ErrorActionPreference = 'Stop'
$tool = 'C:\Users\CZY098\Tools\X3D-CCDAffinity'
if ($PSVersionTable.PSVersion.Major -ge 6) { $psExe = 'pwsh.exe' } else { $psExe = 'powershell.exe' }

function Start-Stub {
    # a process that stays alive and is not hijacked by a packaged app
    return Start-Process -FilePath 'cmd.exe' -ArgumentList '/c','ping -n 120 127.0.0.1 > nul' -PassThru -WindowStyle Hidden
}

Write-Output '===== 1) raw API check ====="'
$p = Start-Stub
Start-Sleep -Milliseconds 600
$p.Refresh()
Write-Output ("  {0} pid {1} before : 0x{2:X}" -f $p.ProcessName, $p.Id, ([int64]$p.ProcessorAffinity))
$p.ProcessorAffinity = [IntPtr]([int64]0xFFFF)
Start-Sleep -Milliseconds 200
$p.Refresh()
$after = [int64]$p.ProcessorAffinity
Write-Output ("  {0} pid {1} after  : 0x{2:X}  (expected 0xFFFF)" -f $p.ProcessName, $p.Id, $after)
$fullMask = [int64](([int64]1 -shl [Environment]::ProcessorCount) - 1)
Write-Output ("  all-cpus mask      : 0x{0:X}" -f $fullMask)
$p.ProcessorAffinity = [IntPtr]$fullMask
$p.Refresh()
Write-Output ("  restore            : 0x{0:X}" -f ([int64]$p.ProcessorAffinity))
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue

Write-Output ''
Write-Output '===== 2) daemon -Once with a temporary config ====="'
$tmpCfg = Join-Path $env:TEMP 'x3d-test-config.json'
@'
{
  "pollSeconds": 2,
  "retryAttempts": 4,
  "retryDelayMs": 300,
  "logMaxKB": 2048,
  "groups": [
    { "name": "ccd0-cache", "mask": "0xFFFF", "priority": null, "enabled": true,
      "processes": [ "cmd.exe" ] }
  ]
}
'@ | Set-Content -LiteralPath $tmpCfg -Encoding utf8

$stub = Start-Stub
Start-Sleep -Milliseconds 700
$stub.Refresh()
Write-Output ("  stub pid {0} affinity before load: 0x{1:X}" -f $stub.Id, ([int64]$stub.ProcessorAffinity))
& pwsh -NoProfile -File (Join-Path $tool 'X3D-CCDAffinity.ps1') -ConfigPath $tmpCfg -Once
Start-Sleep -Milliseconds 400
$stub.Refresh()
$val = [int64]$stub.ProcessorAffinity
Write-Output ("  stub pid {0} affinity after  load: 0x{1:X}" -f $stub.Id, $val)
if ($val -eq 0xFFFF) { Write-Output '  RESULT: PASS' } else { Write-Output '  RESULT: FAIL' }
Stop-Process -Id $stub.Id -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $tmpCfg -Force

Write-Output ''
Write-Output '===== 3) log tail ====="'
$logDir = Join-Path $tool 'logs'
$latest = Get-ChildItem -LiteralPath $logDir -Filter 'x3d-affinity-*.log' -File -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($latest) { Get-Content -LiteralPath $latest.FullName -Tail 10 } else { Write-Output '(no daily log yet)' }

