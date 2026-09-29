# Prove a confirmed uninstall can return to fresh setup beside independent data.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Bundle,[Parameter(Mandatory=$true)][string]$Destination,[Parameter(Mandatory=$true)][string]$Evidence)
$ErrorActionPreference='Stop'
if ($env:COMPUTERNAME -ne 'DM-WIN-TEST') { throw 'Disposable Windows VM required.' }
New-Item -ItemType Directory -Force $Evidence | Out-Null
$independent=Join-Path $env:USERPROFILE ('.machtiani\uninstall-preservation-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $independent | Out-Null
$sentinel=Join-Path $independent 'keep.txt'
[IO.File]::WriteAllText($sentinel,'Independent Machtiani project data.')
$removal=Join-Path $Bundle 'source\tests\windows-native\removal.ps1'
& $removal -Bundle $Bundle -Destination $Destination -Evidence (Join-Path $Evidence 'first-removal')
if ([IO.File]::ReadAllText($sentinel) -ne 'Independent Machtiani project data.') { throw 'Independent project changed during uninstall.' }
& (Join-Path $Bundle 'source\scripts\install-windows.ps1') -Bundle $Bundle -Destination $Destination
$current=(Get-Content -Raw -LiteralPath (Join-Path $Destination 'current.json') | ConvertFrom-Json).release
$release=Join-Path $Destination "releases\$current"
& (Join-Path $Bundle 'runtime\node\node.exe') (Join-Path $Bundle 'source\tests\windows-native\terminal.mjs') $release (Join-Path $Destination 'bin\dearmachine.exe') decline (Join-Path $Evidence 'fresh-consent.txt')
if ($LASTEXITCODE -ne 0) { throw 'Reinstall did not reach fresh setup consent.' }
& $removal -Bundle $Bundle -Destination $Destination -Evidence (Join-Path $Evidence 'second-removal')
if ([IO.File]::ReadAllText($sentinel) -ne 'Independent Machtiani project data.') { throw 'Independent project changed during reinstall.' }
Remove-Item -LiteralPath $sentinel
Remove-Item -LiteralPath $independent
@{result='passed';freshSetupConsent=$true;independentProjectPreserved=$true;finalRemovalCompleted=$true} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Evidence 'reinstall.json')
Write-Output 'WINDOWS_REINSTALL_OK'
