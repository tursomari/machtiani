# Validate rollback after a release passes preflight but cannot start its client.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Bundle,[Parameter(Mandatory=$true)][string]$Destination,[Parameter(Mandatory=$true)][string]$FailingProduct,[Parameter(Mandatory=$true)][string]$Evidence)
$ErrorActionPreference='Stop'
if ($env:COMPUTERNAME -ne 'DM-WIN-TEST') { throw 'Disposable Windows VM required.' }
New-Item -ItemType Directory -Force $Evidence | Out-Null
$command=Join-Path $Destination 'bin\dearmachine.exe'
$product=Join-Path $Bundle 'runtime\products\dearmachine.exe'
$backup=$product+'.test-backup'
$before=(Get-Content -Raw -LiteralPath (Join-Path $Destination 'current.json') | ConvertFrom-Json).release
& $command up
if ($LASTEXITCODE -ne 0) { throw 'Baseline client failed to start.' }
try {
  Move-Item -LiteralPath $product -Destination $backup
  try {
    Copy-Item -LiteralPath $FailingProduct -Destination $product
    & $command update --bundle $Bundle
    if ($LASTEXITCODE -eq 0) { throw 'Broken activation was reported as successful.' }
  } finally {
    Remove-Item -LiteralPath $product -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $backup -Destination $product
  }
  $after=(Get-Content -Raw -LiteralPath (Join-Path $Destination 'current.json') | ConvertFrom-Json).release
  if ($before -ne $after) { throw 'Failed activation did not restore the original release.' }
  $status=& $command _update-control status
  if ($LASTEXITCODE -ne 0 -or !(($status | ConvertFrom-Json).running)) { throw 'Original client was not restored.' }
  & $command restart
  if ($LASTEXITCODE -ne 0) { throw 'Restored client could not restart.' }
  @{result='passed';original=$before;restored=$after;running=$true;restart=$true} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Evidence 'activation-recovery.json')
  Write-Output 'WINDOWS_ACTIVATION_RECOVERY_OK'
} finally { & $command down }
