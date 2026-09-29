# Destructive only to a fresh installation in the disposable test VM.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Bundle,[Parameter(Mandatory=$true)][string]$Destination,[Parameter(Mandatory=$true)][string]$Evidence)
$ErrorActionPreference='Stop'
if ($env:COMPUTERNAME -ne 'DM-WIN-TEST') { throw 'Disposable Windows VM required.' }
if (Test-Path -LiteralPath $Destination) { throw 'Lifecycle fixture needs a fresh destination.' }
New-Item -ItemType Directory -Force -Path $Evidence | Out-Null
function Active { (Get-Content -Raw -LiteralPath (Join-Path $Destination 'current.json') | ConvertFrom-Json).release }
function Run-Native([string[]]$Arguments) {
  & (Join-Path $Destination 'bin\dearmachine.exe') @Arguments
  if ($LASTEXITCODE -ne 0) { throw "Native command failed: $Arguments" }
}
& (Join-Path $Bundle 'source\scripts\install-windows.ps1') -Bundle $Bundle -Destination $Destination
$first = Active
Run-Native @('--help')
Run-Native @('update','--check')
Run-Native @('persistence','on')
$run = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' DearMachine
if ($run -ne ('"'+(Join-Path $Destination 'bin\dearmachine.exe')+'" up')) { throw 'Startup does not use the stable launcher.' }
Run-Native @('update','--bundle',$Bundle)
$second = Active
if ($first -eq $second) { throw 'Update did not activate a new release.' }
Run-Native @('--help')
Run-Native @('update','--recover')
if ((Active) -ne $first) { throw 'Rollback failed.' }
$bad = Join-Path $Evidence 'incomplete-bundle'
New-Item -ItemType Directory -Path $bad | Out-Null
& (Join-Path $Destination 'bin\dearmachine.exe') update --bundle $bad
if ($LASTEXITCODE -eq 0 -or (Active) -ne $first) { throw 'Incomplete bundle changed the active installation.' }
$release = Join-Path $Destination "releases\$first"
$node = Join-Path $release 'runtime\node\node.exe'
& $node (Join-Path $Bundle 'source\tests\windows-native\terminal.mjs') $release (Join-Path $Destination 'bin\dearmachine.exe') cancel-uninstall (Join-Path $Evidence 'uninstall-cancel.txt')
if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $Destination)) { throw 'Uninstall cancellation failed.' }
Run-Native @('persistence','off')
@{first=$first;second=$second;rollback=(Active);result='passed'} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Evidence 'lifecycle.json')
Write-Output 'WINDOWS_LIFECYCLE_OK'
