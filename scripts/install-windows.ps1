# Per-user native Windows installation with immutable releases and reversible activation.
[CmdletBinding(DefaultParameterSetName='Install')]
param(
  [Parameter(Mandatory=$true,ParameterSetName='Install')][string]$Bundle,
  [string]$Destination = (Join-Path $env:LOCALAPPDATA 'DearMachine'),
  [Parameter(ParameterSetName='Install')][switch]$Update,
  [Parameter(Mandatory=$true,ParameterSetName='Rollback')][switch]$Rollback,
  [switch]$NoPath,
  [switch]$NoLaunchGuidance
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This installer requires Windows.' }
$Destination = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
function Assert-PlainPath([string]$Path) {
  for ($at = $Path; $at; $at = Split-Path -Parent $at) {
    if ((Test-Path -LiteralPath $at) -and ((Get-Item -Force -LiteralPath $at).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refusing redirected installation path: $at" }
  }
}
function Private-Directory([string]$Path) {
  New-Item -ItemType Directory -Path $Path | Out-Null
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl = Get-Acl -LiteralPath $Path
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleSpecific($rule) }
  foreach ($principal in @($sid, [Security.Principal.SecurityIdentifier]'S-1-5-18')) {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($principal,'FullControl','ContainerInherit, ObjectInherit','None','Allow')))
  }
  Set-Acl -LiteralPath $Path -AclObject $acl
}
function Read-Active {
  $receipt = Get-Content -Raw -LiteralPath (Join-Path $Destination 'windows-installation.json') | ConvertFrom-Json
  if ($receipt.version -ne 2 -or $receipt.platform -ne 'windows-x64' -or $receipt.destination -ne $Destination) { throw 'Destination is not a managed Windows installation.' }
  $active = Get-Content -Raw -LiteralPath (Join-Path $Destination 'current.json') | ConvertFrom-Json
  if ($active.version -ne 1 -or $active.release -notmatch '^[a-f0-9]{32}$' -or ($active.previous -and $active.previous -notmatch '^[a-f0-9]{32}$')) { throw 'Invalid Windows release pointer.' }
  Assert-PlainPath (Join-Path $Destination "releases\$($active.release)")
  return $active
}
function Copy-Bundle([string]$From,[string]$To) {
  & (Join-Path $From 'runtime\node\node.exe') (Join-Path $PSScriptRoot 'windows-files.cjs') space $From $To
  if ($LASTEXITCODE -ne 0) { throw 'Windows bundle space check failed; free space on the installation drive and retry.' }
  & robocopy $From $To /E /COPY:DAT /DCOPY:DAT /R:0 /W:0 /NFL /NDL /NJH /NJS /NP /XJ | Out-Null
  if ($LASTEXITCODE -ge 8) { throw 'Windows bundle copy failed.' }
}
function Write-Active([string]$Root,[string]$Release,[string]$Previous) {
  $target = Join-Path $Root 'current.json'
  $temp = Join-Path $Root ('.activate-' + [Guid]::NewGuid().ToString('N'))
  $backup = $temp + '.backup'
  try {
    [IO.File]::WriteAllText($temp,(@{version=1;release=$Release;previous=$Previous} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $target) { [IO.File]::Replace($temp,$target,$backup) }
    else { [IO.File]::Move($temp,$target) }
  } finally { foreach ($file in @($temp,$backup)) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } } }
}
Assert-PlainPath $Destination
$existing = $Update -or $Rollback
if (!$existing -and (Test-Path -LiteralPath $Destination)) { throw "Destination already exists: $Destination. Use -Update for a managed installation." }
if (!$Rollback) {
  $Bundle = (Resolve-Path -LiteralPath $Bundle).Path
  foreach ($relative in @('distribution.json','source\bootstrap-source-revisions.json','source\scripts\install-windows.ps1','source\scripts\uninstall-windows.ps1','source\scripts\windows-files.cjs','bin\agent-manager.exe','bin\machtiani.exe','bin\dearmachine.exe','bin\machtiani-installer.exe','bin\machtiani-model-host.exe','runtime\products\dearmachine.exe','runtime\products\machtiani.exe','runtime\products\agent-manager.exe','runtime\node\node.exe','runtime\git\bin\bash.exe','runtime\ripgrep\rg.exe','runtime\installer\packages\app\dist\bin.mjs','runtime\installer\packages\model-host\dist\bin.mjs')) {
    if (!(Test-Path -LiteralPath (Join-Path $Bundle $relative) -PathType Leaf)) { throw "Incomplete Windows bundle: $relative" }
  }
}
$parent = Split-Path -Parent $Destination
New-Item -ItemType Directory -Force -Path $parent | Out-Null
# An exclusive handle serializes install/update/rollback even across processes.
$lockPath = $Destination + '.install.lock'
Assert-PlainPath $lockPath
$lock = [IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
$stage = $null
$running = $false
$stopped = $false
try {
  if ($existing) {
    if (Test-Path -LiteralPath (Join-Path $Destination '.uninstalling')) { throw 'Uninstall is pending; update refused.' }
    $active = Read-Active
    $native = Join-Path $Destination "releases\$($active.release)\bin\dearmachine.exe"
    if ($Rollback) {
      if (!$active.previous) { throw 'No previous release is available.' }
      $release = $active.previous
      Assert-PlainPath (Join-Path $Destination "releases\$release")
      if (!(Test-Path -LiteralPath (Join-Path $Destination "releases\$release\bin\dearmachine.exe"))) { throw 'Previous release is missing.' }
    } else {
      $release = [Guid]::NewGuid().ToString('N')
      $stage = Join-Path $Destination "releases\$release"
      Private-Directory $stage
      Copy-Bundle $Bundle $stage
      & (Join-Path $stage 'bin\dearmachine.exe') --help | Out-Null
      if ($LASTEXITCODE -ne 0) { throw 'New release could not start; current release remains active.' }
    }
    $status = & $native _update-control status
    if ($LASTEXITCODE -ne 0) { throw 'Cannot establish client state; activation refused.' }
    $running = ($status | ConvertFrom-Json).running
    & $native _update-control stop
    if ($LASTEXITCODE -ne 0) { throw 'Client shutdown was not confirmed; activation refused.' }
    $stopped = $true
    Write-Active $Destination $release $active.release
    $stage = $null # Retain activated releases for rollback and running concierge sessions.
    Write-Output "Activated Windows release $release. Previous release: $($active.release)."
  } else {
    $stage = Join-Path $parent ('.dearmachine-install-' + [Guid]::NewGuid().ToString('N'))
    Private-Directory $stage
    $release = [Guid]::NewGuid().ToString('N')
    New-Item -ItemType Directory -Path (Join-Path $stage "releases\$release") -Force | Out-Null
    Copy-Bundle $Bundle (Join-Path $stage "releases\$release")
    Copy-Item -LiteralPath (Join-Path $Bundle 'bin') -Destination $stage -Recurse
    @{version=2;platform='windows-x64';destination=$Destination;installedAt=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $stage 'windows-installation.json')
    Write-Active $stage $release ''
    Move-Item -LiteralPath $stage -Destination $Destination
    $stage = $null
    Write-Output "Installed native Windows commands in $(Join-Path $Destination 'bin')"
  }
} finally {
  if ($stage -and (Test-Path -LiteralPath $stage)) {
    # PowerShell 5.1 cannot remove the runtime's long dependency paths.
    & (Join-Path $Bundle 'runtime\node\node.exe') (Join-Path $PSScriptRoot 'windows-files.cjs') remove $stage
    if ($LASTEXITCODE -ne 0) { Write-Warning "Incomplete staging cleanup retained at $stage" }
  }
  try {
    if ($stopped -and $running) {
      & (Join-Path $Destination 'bin\dearmachine.exe') up
      if ($LASTEXITCODE -ne 0) {
        Write-Active $Destination $active.release $active.previous
        & (Join-Path $Destination 'bin\dearmachine.exe') up
        if ($LASTEXITCODE -ne 0) { throw 'Activation failed. The old release was restored, but its client could not restart; inspect dearmachine status.' }
        throw 'Activation failed. The old release and running client were restored.'
      }
    }
  } finally { $lock.Dispose() }
}
$bin = Join-Path $Destination 'bin'
if (!$NoPath) {
  $previous = [Environment]::GetEnvironmentVariable('Path','User')
  $entries = @($previous -split ';' | Where-Object { $_ })
  if ($entries -notcontains $bin) { [Environment]::SetEnvironmentVariable('Path',(($entries + $bin) -join ';'),'User') }
  $env:Path = "$bin;$env:Path"
}
if (!$NoLaunchGuidance) { Write-Output 'Open a new terminal, then run dearmachine. To start automatically after signing in, run dearmachine persistence on.' }
