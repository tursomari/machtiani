# Internal handoff from the native, terminal-confirmed uninstall command.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Destination,
  [switch]$Check,
  [int]$ParentProcess,
  [int]$LauncherProcess,
  [int]$BootstrapProcess,
  [switch]$Cleanup
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Destination = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
$log = Join-Path $env:LOCALAPPDATA 'DearMachine-uninstall.log'
function Assert-PlainPath([string]$Path) {
  for ($at=$Path; $at; $at=Split-Path -Parent $at) {
    if ((Test-Path -LiteralPath $at) -and ((Get-Item -Force -LiteralPath $at).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refusing redirected removal path: $at" }
  }
}
function Assert-Tree([string]$Path) {
  Assert-PlainPath $Path
  if (!(Test-Path -LiteralPath $Path)) { return }
  $owner = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier])
  if ($owner.Value -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw "Removal path is not owned by this user: $Path" }
  & $nodeForRemoval (Join-Path $PSScriptRoot 'windows-files.cjs') check $Path
  if ($LASTEXITCODE -ne 0) { throw "Unsafe or unreadable removal tree: $Path" }
}
function Read-Installation {
  Assert-PlainPath $Destination
  $receipt = Get-Content -Raw -LiteralPath (Join-Path $Destination 'windows-installation.json') | ConvertFrom-Json
  if ($receipt.version -ne 2 -or $receipt.destination -ne $Destination -or $receipt.platform -ne 'windows-x64') { throw 'Not an owned managed Windows installation.' }
  $active = Get-Content -Raw -LiteralPath (Join-Path $Destination 'current.json') | ConvertFrom-Json
  if ($active.version -ne 1 -or $active.release -notmatch '^[a-f0-9]{32}$') { throw 'Invalid active release.' }
  return Join-Path $Destination "releases\$($active.release)\bin\dearmachine.exe"
}
$native = Read-Installation
$nodeForRemoval = if ($Cleanup) { Join-Path $PSScriptRoot 'node.exe' } else { Join-Path (Split-Path -Parent (Split-Path -Parent $native)) 'runtime\node\node.exe' }
$homeDirectory = [Environment]::GetFolderPath('UserProfile')
$paths = @($Destination)
foreach ($relative in @('.dearmachine','.config\dearmachine','.local\state\dearmachine','.local\state\machtiani-installer','.local\share\machtiani-installer','.cache\dearmachine','.cache\machtiani-installer')) { $paths += Join-Path $homeDirectory $relative }
foreach ($entry in @(@('XDG_CONFIG_HOME','dearmachine'),@('XDG_STATE_HOME','dearmachine'),@('XDG_STATE_HOME','machtiani-installer'),@('XDG_DATA_HOME','machtiani-installer'),@('XDG_CACHE_HOME','dearmachine'),@('XDG_CACHE_HOME','machtiani-installer'))) {
  $base = [Environment]::GetEnvironmentVariable($entry[0])
  if ($base) {
    if (![IO.Path]::IsPathRooted($base)) { throw "Relative $($entry[0]) is unsafe." }
    $paths += Join-Path $base $entry[1]
  }
}
# Only project stores referenced by product-owned workspaces belong to removal.
# An external Documents project and its independent Machtiani sessions remain.
$workspaces = @((Join-Path $homeDirectory '.dearmachine\entrypoint'),(Join-Path $homeDirectory '.local\share\machtiani-installer\workspace'))
if ($env:XDG_DATA_HOME) { $workspaces += Join-Path $env:XDG_DATA_HOME 'machtiani-installer\workspace' }
foreach ($workspace in ($workspaces | Select-Object -Unique)) {
  if (!(Test-Path -LiteralPath $workspace)) { continue }
  Assert-Tree $workspace
  foreach ($marker in Get-ChildItem -LiteralPath $workspace -Filter 'project.uuid' -File -Recurse -Force) {
    if ((Split-Path -Leaf $marker.DirectoryName) -ne '.machtiani') { continue }
    $identifier = [Guid]::Empty
    if (![Guid]::TryParse(([IO.File]::ReadAllText($marker.FullName).Trim()),[ref]$identifier) -or $identifier -eq [Guid]::Empty) { throw 'Invalid owned workspace project identity.' }
    $paths += Join-Path $homeDirectory ('.machtiani\'+$identifier.ToString())
  }
}
$paths = @($paths | Select-Object -Unique)
foreach ($path in $paths) { Assert-Tree $path }
if ($Check) {
  Write-Output 'Permanently remove DearMachine software, credentials, configuration, databases, memory, logs and caches:'
  foreach ($path in $paths) { if (Test-Path -LiteralPath $path) { Write-Output "  $path" } }
  exit 0
}
if ($Cleanup) {
  try {
    foreach ($processID in @($ParentProcess,$LauncherProcess,$BootstrapProcess)) {
      if ($processID -gt 0) {
        $process = Get-Process -Id $processID -ErrorAction SilentlyContinue
        if ($process -and !$process.WaitForExit(60000)) { throw 'Launcher has not exited; cleanup refused.' }
      }
    }
    $lock = [IO.File]::Open(($Destination+'.install.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
      # Revalidate after the handoff; never traverse a junction during removal.
      $null = Read-Installation
      foreach ($path in $paths) { Assert-Tree $path }
      $bin = Join-Path $Destination 'bin'
      $entries = @([Environment]::GetEnvironmentVariable('Path','User') -split ';' | Where-Object { $_ -and $_.TrimEnd('\') -ne $bin })
      [Environment]::SetEnvironmentVariable('Path',($entries -join ';'),'User')
      foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
          & $nodeForRemoval (Join-Path $PSScriptRoot 'windows-files.cjs') remove $path
          if ($LASTEXITCODE -ne 0) { throw "Removal failed: $path" }
        }
      }
      [IO.File]::WriteAllText($log,'DearMachine uninstalled. Owned software and private data removed. External projects and backend installations preserved.')
    } finally { $lock.Dispose() }
    Remove-Item -LiteralPath ($Destination+'.install.lock') -Force -ErrorAction SilentlyContinue
  } catch {
    [IO.File]::WriteAllText($log,('Uninstall incomplete: '+$_.Exception.Message))
    exit 1
  } finally {
    # PowerShell has read the helper; unlike an executable, it can remove itself.
    Remove-Item -LiteralPath $nodeForRemoval,(Join-Path $PSScriptRoot 'windows-files.cjs'),$PSCommandPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $PSScriptRoot -Force -ErrorAction SilentlyContinue
  }
  exit 0
}
$control = Join-Path (Split-Path -Parent (Split-Path -Parent $native)) 'runtime\products\dearmachine.exe'
& $control _update-control stop
if ($LASTEXITCODE -ne 0) { throw 'Client shutdown was not confirmed; uninstall refused.' }
& $control persistence off
if ($LASTEXITCODE -ne 0) { throw 'Startup removal failed; uninstall refused.' }
$helperDirectory = Join-Path $env:TEMP ('dearmachine-remove-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $helperDirectory | Out-Null
$acl = Get-Acl -LiteralPath $Destination
Set-Acl -LiteralPath $helperDirectory -AclObject $acl
$helper = Join-Path $helperDirectory 'remove.ps1'
Copy-Item -LiteralPath $PSCommandPath -Destination $helper
Copy-Item -LiteralPath $nodeForRemoval -Destination (Join-Path $helperDirectory 'node.exe')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'windows-files.cjs') -Destination $helperDirectory
# Encode data separately; apostrophes and Unicode in paths never become code.
$payload = @{helper=$helper;destination=$Destination;parent=$ParentProcess;launcher=$LauncherProcess;bootstrap=$BootstrapProcess} | ConvertTo-Json -Compress
$encodedPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
$command = '$p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("' + $encodedPayload + '")) | ConvertFrom-Json; & $p.helper -Destination $p.destination -ParentProcess $p.parent -LauncherProcess $p.launcher -BootstrapProcess $p.bootstrap -Cleanup'
$encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
[IO.File]::WriteAllText((Join-Path $Destination '.uninstalling'),'Removal pending')
[IO.File]::WriteAllText($log,'Removal is waiting for the launching command to exit.')
try {
  Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encodedCommand) -WindowStyle Hidden | Out-Null
} catch {
  Remove-Item -LiteralPath (Join-Path $Destination '.uninstalling') -Force
  throw
}
Write-Output "Removal will finish after this command exits. Result: $log"
