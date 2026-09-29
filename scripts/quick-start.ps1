# Build privately, install per-user, and continue directly into guided setup.
[CmdletBinding()]
param(
  [string]$SourceRoot,
  [string]$Cache = (Join-Path $env:LOCALAPPDATA 'DearMachineBuild'),
  [string]$Destination = (Join-Path $env:LOCALAPPDATA 'DearMachine')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
if ($env:OS -ne 'Windows_NT' -or ![Environment]::Is64BitProcess -or
    ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64')) { throw 'Quick start requires native x64 PowerShell on Windows 11 x64.' }
. (Join-Path $PSScriptRoot 'windows-bootstrap-lib.ps1')
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$Cache = [IO.Path]::GetFullPath($Cache)
$Destination = [IO.Path]::GetFullPath($Destination)
Assert-PlainDirectory $SourceRoot
Assert-PlainDirectory $Destination
# A repeated Quick start opens the existing installation without rebuilding or updating it.
if (Test-Path -LiteralPath $Destination) {
  $receiptPath = Join-Path $Destination 'windows-installation.json'
  if (!(Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw 'Destination already exists and is not a managed Windows installation.' }
  $receipt = Get-Content -Raw -LiteralPath $receiptPath | ConvertFrom-Json
  if ($receipt.version -ne 2 -or $receipt.platform -ne 'windows-x64' -or $receipt.destination -ne $Destination) { throw 'Invalid Windows installation receipt; inspect the existing installation.' }
  & (Join-Path $Destination 'bin\dearmachine.exe')
  exit $LASTEXITCODE
}
. (Join-Path $PSScriptRoot 'windows-activity.ps1')
Invoke-WindowsActivity -Label 'Preparing Dear Machine' -ScriptPath (Join-Path $PSScriptRoot 'prepare-windows.ps1') -Arguments @{
  SourceRoot=$SourceRoot; Cache=$Cache; Destination=$Destination
}
# The worker persists the user PATH; expose the new commands to this session too.
$env:PATH = "$(Join-Path $Destination 'bin');$env:PATH"
Write-Host 'Continue with guided setup'
& (Join-Path $Destination 'bin\dearmachine.exe')
exit $LASTEXITCODE
