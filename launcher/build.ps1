<#
.SYNOPSIS
    Builds X3D-Tray-Admin.exe - a launcher that always starts the tray with
    administrator rights (the games that need pinning usually run elevated too).

.DESCRIPTION
    Compiles launcher/launcher.cs with the .NET Framework C# compiler that ships
    with Windows, embedding launcher/app.manifest so the exe requests elevation.

    No SDK required. Works on a clean Windows 10/11 install.

.PARAMETER OutFile
    Output path. Defaults to ..\X3D-Tray-Admin.exe (repo root, next to the tray script).
#>
[CmdletBinding()]
param(
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$launcherDir = $PSScriptRoot
$repoRoot    = Split-Path $launcherDir -Parent
if (-not $OutFile) { $OutFile = Join-Path $repoRoot 'X3D-Tray-Admin.exe' }

$csc = $null
foreach ($candidate in @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)) {
    if (Test-Path -LiteralPath $candidate) { $csc = $candidate; break }
}
if (-not $csc) {
    throw 'csc.exe not found. Install .NET Framework 4.x (included with Windows 10/11).'
}

Write-Host ("compiler : {0}" -f $csc)
Write-Host ("output   : {0}" -f $OutFile)

Push-Location $launcherDir
try {
    $args = @(
        '/nologo'
        '/target:winexe'
        '/platform:anycpu'
        '/optimize+'
        '/win32manifest:app.manifest'
        '/r:System.Windows.Forms.dll'
        '/r:System.Management.dll'
        "/out:$OutFile"
        'launcher.cs'
    )
    & $csc @args
    if ($LASTEXITCODE -ne 0) { throw ("csc failed with exit code {0}" -f $LASTEXITCODE) }
}
finally {
    Pop-Location
}

$fi = Get-Item -LiteralPath $OutFile
Write-Host ("built    : {0} ({1:N0} bytes)" -f $fi.Name, $fi.Length)

# sanity: the manifest must be embedded
$bytes = [System.IO.File]::ReadAllBytes($OutFile)
$text = [System.Text.Encoding]::UTF8.GetString($bytes)
if ($text -match 'requireAdministrator') {
    Write-Host 'manifest : requireAdministrator embedded OK' -ForegroundColor Green
} else {
    Write-Warning 'manifest does not contain requireAdministrator - elevation will not be requested'
}
