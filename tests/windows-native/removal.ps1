# Keep the SSH test session alive until the detached product cleanup finishes.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Bundle,[Parameter(Mandatory=$true)][string]$Destination,[Parameter(Mandatory=$true)][string]$Evidence)
$ErrorActionPreference='Stop'
if ($env:COMPUTERNAME -ne 'DM-WIN-TEST') { throw 'Disposable Windows VM required.' }
New-Item -ItemType Directory -Force $Evidence | Out-Null
$current=(Get-Content -Raw -LiteralPath (Join-Path $Destination 'current.json') | ConvertFrom-Json).release
$release=Join-Path $Destination "releases\$current"
$external=Join-Path $env:USERPROFILE 'Documents\dearmachine-preservation-fixture.txt'
[IO.File]::WriteAllText($external,'External user file must survive uninstall.')
$state=Join-Path $env:USERPROFILE '.local\state\machtiani-installer'
$modules=Join-Path $state 'dsh\profiles\node_modules'
New-Item -ItemType Directory -Force $modules | Out-Null
$link=Join-Path $modules ('uninstall-preservation-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Junction -Path $link -Target (Split-Path -Parent $external) | Out-Null
# The generated profile contains junctions after actual installer use. Exercise
# cancellation with one present before authorizing asynchronous removal.
$node=Join-Path $Bundle 'runtime\node\node.exe'
$terminal=Join-Path $Bundle 'source\tests\windows-native\terminal.mjs'
& $node $terminal $release (Join-Path $Destination 'bin\dearmachine.exe') cancel-uninstall (Join-Path $Evidence 'uninstall-linked-cancel.txt')
if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $link)) { throw 'Linked-state uninstall cancellation failed.' }
& (Join-Path $Bundle 'runtime\node\node.exe') (Join-Path $Bundle 'source\tests\windows-native\terminal.mjs') $release (Join-Path $Destination 'bin\dearmachine.exe') uninstall (Join-Path $Evidence 'uninstall-terminal.txt')
if ($LASTEXITCODE -ne 0) { throw 'Terminal uninstall failed.' }
$deadline=(Get-Date).AddMinutes(5)
do {
  Start-Sleep -Seconds 2
  $result=Get-Content -Raw (Join-Path $env:LOCALAPPDATA 'DearMachine-uninstall.log')
  if ($result.StartsWith('Uninstall incomplete:')) { throw $result }
} while (!$result.StartsWith('DearMachine uninstalled.') -and (Get-Date) -lt $deadline)
if (!$result.StartsWith('DearMachine uninstalled.')) { throw 'Cleanup did not complete.' }
foreach ($path in @($Destination,(Join-Path $env:USERPROFILE '.dearmachine'),(Join-Path $env:USERPROFILE '.config\dearmachine'),$state,(Join-Path $env:USERPROFILE '.local\share\machtiani-installer'))) {
  if (Test-Path -LiteralPath $path) { throw "Owned path still present: $path" }
}
if ([IO.File]::ReadAllText($external) -ne 'External user file must survive uninstall.') { throw 'External file changed.' }
@{result='passed';softwareAbsent=$true;privateStateAbsent=$true;externalFilePreserved=$true;linkedStateCancelledAndRemoved=$true} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Evidence 'removal.json')
Write-Output 'WINDOWS_REMOVAL_OK'
