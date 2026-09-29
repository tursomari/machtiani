# Install a built Windows release zip the way install.ps1 does, then run it.
# Release CI runs this on a disposable Windows runner before drafting a release.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Zip,
  [Parameter(Mandatory=$true)][string]$Installer
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Load the rendered installer's own extraction function instead of a copy.
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $Installer).Path, [ref]$null, [ref]$errors)
if ($errors.Count -ne 0) { throw 'The rendered install.ps1 does not parse.' }
$function = $ast.Find({ param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Expand-ReleaseZip' }, $true)
if (!$function) { throw 'install.ps1 has no Expand-ReleaseZip function.' }
. ([scriptblock]::Create($function.Extent.Text))
$cleanup = $ast.Find({ param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Remove-ReleaseWork' }, $true)
if (!$cleanup) { throw 'install.ps1 has no Remove-ReleaseWork function.' }
. ([scriptblock]::Create($cleanup.Extent.Text))

# Match install.ps1's paths, whose length matters for the runtime's deep trees.
$work = Join-Path $env:LOCALAPPDATA 'DearMachineBuild\r-check001'
$bundle = Join-Path $work 'b'
$destination = Join-Path $env:LOCALAPPDATA 'DearMachine'
foreach ($path in @($work, $destination)) {
  if (Test-Path -LiteralPath $path) { throw "Expected a clean runner, but $path exists." }
}
New-Item -ItemType Directory -Force -Path $work | Out-Null
Expand-ReleaseZip $Zip $bundle
& (Join-Path $bundle 'source\scripts\install-windows.ps1') -Bundle $bundle -Destination $destination -NoPath -NoLaunchGuidance

# Capture native stderr as text instead of stopping on it.
$ErrorActionPreference = 'Continue'
foreach ($probe in @(@('dearmachine', '--help'), @('machtiani', '--version'), @('agent-manager', '--help'),
                     @('machtiani-installer', '--help'))) {
  $output = & (Join-Path $destination "bin\$($probe[0]).exe") $probe[1] 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) {
    Write-Host $output
    throw "Installed $($probe[0]) failed its $($probe[1]) probe."
  }
  Write-Host "Installed $($probe[0]) runs."
  if ($probe[0] -eq 'machtiani') {
    $harness = (Get-Content -Raw -LiteralPath (Join-Path $bundle 'source\bootstrap-source-revisions.json') | ConvertFrom-Json).'machtiani-harness'
    if (($output -split "`r?`n") -notcontains "commit: $harness") { throw "Installed machtiani does not report harness revision $harness." }
    Write-Host "Installed machtiani reports harness revision $harness."
  }
}

# Exercise the installer's own cleanup on the full extracted runtime. Running
# the copy under $work leaves its executable locked on Windows.
$cache = Split-Path -Parent $work
Remove-ReleaseWork $work $cache
if (Test-Path -LiteralPath $work) { throw "Release installer left temporary files in $work." }
if (@(Get-ChildItem -LiteralPath $cache -Filter 'cleanup-*.exe' -File).Count -ne 0) {
  throw "Release installer left a cleanup executable in $cache."
}
Write-Host 'Release installer removed its temporary files.'
