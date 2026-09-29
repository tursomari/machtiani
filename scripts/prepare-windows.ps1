# Internal noninteractive preparation worker; quick-start.ps1 owns the terminal.
# Release builds pass -BundleOutput instead of -Destination to keep the verified
# bundle for packaging without installing it.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$SourceRoot,
  [Parameter(Mandatory=$true)][string]$Cache,
  [string]$Destination,
  [string]$BundleOutput
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrEmpty($Destination) -eq [string]::IsNullOrEmpty($BundleOutput)) { throw 'Pass exactly one of -Destination or -BundleOutput.' }
if ($BundleOutput) {
  $BundleOutput = [IO.Path]::GetFullPath($BundleOutput)
  if (Test-Path -LiteralPath $BundleOutput) { throw "Bundle output already exists: $BundleOutput" }
}
. (Join-Path $PSScriptRoot 'windows-bootstrap-lib.ps1')
New-PrivateDirectory $Cache
$lock = [IO.File]::Open((Join-Path $Cache 'quick-start.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $pins = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'windows-dependencies.json') | ConvertFrom-Json
  $dependencies = @{}
  $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
  foreach ($name in @('node', 'git', 'ripgrep', 'go', 'zig', 'pnpm')) {
    $dependencies[$name] = Get-WindowsDependency $name $pins.$name $Cache $tar
  }
  $node = Join-Path $dependencies.node 'node.exe'
  $git = Join-Path $dependencies.git 'bin\git.exe'
  $source = Join-Path $Cache ('source-' + [Guid]::NewGuid().ToString('N'))
  Write-Host 'Prepare pinned source (tracked files only)'
  & $node (Join-Path $PSScriptRoot 'windows-source.cjs') $SourceRoot $source $git
  if ($LASTEXITCODE -ne 0) { throw 'Source preparation failed. Initialize pinned submodules and commit or restore tracked changes before retrying.' }
  $identity = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $source 'bootstrap-source-revisions.json')).Hash.ToLowerInvariant()
  $bundle = Join-Path $Cache ('bundle-' + $identity)
  Assert-PlainDirectory $bundle
  try {
    if (!(Test-Path -LiteralPath (Join-Path $bundle '.verified') -PathType Leaf)) {
      if (Test-Path -LiteralPath $bundle) { throw "Unverified bundle already exists: $bundle. Remove it before retrying." }
      Write-Host 'Build Dear Machine and its native runtime'
      # Build tools receive a private home and an allowlisted environment, never provider credentials.
      $savedEnvironment = @{}
      Get-ChildItem Env: | ForEach-Object { $savedEnvironment[$_.Name] = $_.Value }
      $buildHome = Join-Path $Cache 'build-home'
      New-PrivateDirectory $buildHome
      try {
        Get-ChildItem Env: | ForEach-Object { [Environment]::SetEnvironmentVariable($_.Name, $null, 'Process') }
        foreach ($name in @('SystemRoot','WINDIR','SystemDrive','COMSPEC','TEMP','TMP','OS','PATHEXT','PROCESSOR_ARCHITECTURE','NUMBER_OF_PROCESSORS','PSExecutionPolicyPreference')) {
          if ($savedEnvironment.ContainsKey($name)) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
        }
        $env:HOME = $buildHome; $env:USERPROFILE = $buildHome
        $env:LOCALAPPDATA = Join-Path $buildHome 'Local'; $env:APPDATA = Join-Path $buildHome 'Roaming'
        $env:GOTOOLCHAIN = 'local'; $env:GIT_CONFIG_NOSYSTEM = '1'; $env:GIT_CONFIG_GLOBAL = 'NUL'
        $env:PATH = (@($dependencies.node, (Join-Path $dependencies.git 'bin'), (Join-Path $dependencies.git 'usr\bin'),
          (Join-Path $dependencies.go 'bin'), $dependencies.zig, (Join-Path $env:SystemRoot 'System32')) -join ';')
        & (Join-Path $source 'scripts\build-windows.ps1') -SourceRoot $source -Output $bundle -NodeDirectory $dependencies.node -GitDirectory $dependencies.git -RipgrepDirectory $dependencies.ripgrep -PnpmDirectory $dependencies.pnpm
      } finally {
        Get-ChildItem Env: | ForEach-Object { [Environment]::SetEnvironmentVariable($_.Name, $null, 'Process') }
        foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
      }
      foreach ($probe in @(@('dearmachine','--help'), @('agent-manager','--help'), @('machtiani','--version'))) {
        & (Join-Path $bundle "bin\$($probe[0]).exe") $probe[1] | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Built software could not start; nothing was installed.' }
      }
      [IO.File]::WriteAllText((Join-Path $bundle '.verified'), $identity)
    } else { Write-Host 'Reuse the verified build' }
    if ($BundleOutput) {
      Move-Item -LiteralPath $bundle -Destination $BundleOutput
      Write-Host "Prepared release bundle: $BundleOutput"
    } else {
      Write-Host 'Install Dear Machine'
      & (Join-Path $bundle 'source\scripts\install-windows.ps1') -Bundle $bundle -Destination $Destination -NoLaunchGuidance
    }
  } finally {
    & $node (Join-Path $PSScriptRoot 'windows-files.cjs') remove $source
    if ($LASTEXITCODE -ne 0) { Write-Warning "Temporary source cleanup retained at $source" }
  }
} finally { $lock.Dispose() }
exit 0
