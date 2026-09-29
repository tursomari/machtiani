# Prepare the native Windows runtime. Run only inside the Windows test VM during development.
[CmdletBinding()]
param(
  [string]$SourceRoot,
  [Parameter(Mandatory=$true)][string]$Output,
  [Parameter(Mandatory=$true)][string]$NodeDirectory,
  [Parameter(Mandatory=$true)][string]$GitDirectory,
  [Parameter(Mandatory=$true)][string]$RipgrepDirectory,
  [string]$ProductDirectory,
  [string]$PnpmDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$SourceRoot) { $SourceRoot = Split-Path -Parent $PSScriptRoot }
if ($env:OS -ne 'Windows_NT') { throw 'Windows is required.' }
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$NodeDirectory = (Resolve-Path -LiteralPath $NodeDirectory).Path
$GitDirectory = (Resolve-Path -LiteralPath $GitDirectory).Path
$Output = [IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $Output) { throw 'The output directory must not exist.' }
$revisionsPath = Join-Path $SourceRoot 'bootstrap-source-revisions.json'
if (Test-Path -LiteralPath $revisionsPath) {
  $revisions = Get-Content -Raw -LiteralPath $revisionsPath | ConvertFrom-Json
  if ($revisions.'.' -notmatch '^[a-f0-9]{40,64}$') { throw 'Invalid source revision metadata.' }
} else {
  $revisions = @{}
  foreach ($component in @('.','dearmachine','machtiani-harness','dearmachine-concierge')) {
    $revision = & (Join-Path $GitDirectory 'bin\git.exe') -C (Join-Path $SourceRoot $component) rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $revision -notmatch '^[a-f0-9]{40,64}$') { throw 'A source archive requires bootstrap-source-revisions.json.' }
    $revisions[$component] = $revision.Trim()
  }
}
# Keep the staging leaf short. Appending a second identifier to the cache's
# content-addressed bundle name pushes native dependency executables past
# Windows' ordinary process-launch path limit, even when their files exist.
$stage = Join-Path (Split-Path -Parent $Output) ('.build-' + [Guid]::NewGuid().ToString('N'))
function Copy-Tree([string]$From,[string]$To) {
  & robocopy $From $To /E /R:0 /W:0 /NFL /NDL /NJH /NJS /NP /XD .git node_modules dist .cache /XF .git | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "Copy failed: $From" }
}
function Checked([string]$Program,[string[]]$Arguments) {
  & $Program @Arguments
  if ($LASTEXITCODE -ne 0) { throw "Build command failed: $Program" }
}
New-Item -ItemType Directory -Force $stage | Out-Null
try {
  $runtime = Join-Path $stage 'runtime'
  New-Item -ItemType Directory -Force (Join-Path $runtime 'products'),(Join-Path $stage 'bin') | Out-Null
  Copy-Tree $SourceRoot (Join-Path $stage 'source')
  [IO.File]::WriteAllText((Join-Path $stage 'source\bootstrap-source-revisions.json'),($revisions | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
  Copy-Tree $NodeDirectory (Join-Path $runtime 'node')
  Copy-Tree $RipgrepDirectory (Join-Path $runtime 'ripgrep')
  # Node's npm implementation lives in node_modules; retain the complete supplied runtime.
  # PowerShell 5.1 Copy-Item cannot traverse npm's long nested dependency paths.
  & robocopy (Join-Path $NodeDirectory 'node_modules') (Join-Path $runtime 'node\node_modules') /E /R:0 /W:0 /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw 'Node package-manager runtime copy failed.' }
  & robocopy $GitDirectory (Join-Path $runtime 'git') /E /R:0 /W:0 /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw 'Git runtime copy failed.' }
  $env:PATH = "$NodeDirectory;$(Join-Path $GitDirectory 'bin');$(Join-Path $GitDirectory 'usr\bin');$env:PATH"
  if ($ProductDirectory) {
    foreach ($name in @('dearmachine','machtiani','agent-manager')) { Copy-Item -LiteralPath (Join-Path $ProductDirectory "$name.exe") -Destination (Join-Path $runtime 'products') }
    $launcher = Join-Path $ProductDirectory 'windows-launcher.exe'
  } else {
    $env:GOOS='windows'; $env:GOARCH='amd64'; $env:CGO_ENABLED='1'; $env:CC='zig cc -target x86_64-windows-gnu'
    Push-Location (Join-Path $SourceRoot 'dearmachine\dearmachine')
    try { foreach ($name in @('dearmachine','agent-manager')) { Checked 'go' @('build','-o',(Join-Path $runtime "products\$name.exe"),"./cmd/$name") } } finally { Pop-Location }
    $env:CGO_ENABLED='0'
    # Stamp `machtiani --version` with the harness revision, as the Nix flake does.
    $harness = [string]$revisions.'machtiani-harness'
    if ($harness -notmatch '^[a-f0-9]{40,64}$') { throw 'Invalid machtiani-harness revision metadata.' }
    $stamp = "-X main.Version=dev-$($harness.Substring(0, 7)) -X main.Commit=$harness"
    Push-Location (Join-Path $SourceRoot 'machtiani-harness\agent')
    try { Checked 'go' @('build','-ldflags',$stamp,'-o',(Join-Path $runtime 'products\machtiani.exe'),'./cmd/machtiani') } finally { Pop-Location }
    $launcher = Join-Path $stage 'windows-launcher.exe'
    Checked 'go' @('build','-o',$launcher,(Join-Path $SourceRoot 'scripts\windows-launcher.go'))
  }
  foreach ($name in @('dearmachine','machtiani','agent-manager','machtiani-installer','machtiani-model-host')) { Copy-Item -LiteralPath $launcher -Destination (Join-Path $stage "bin\$name.exe") }
  $installer = Join-Path $runtime 'installer'
  Copy-Tree (Join-Path $SourceRoot 'dearmachine-concierge') $installer
  $workspace = Join-Path $installer 'pnpm-workspace.yaml'
  $settings = [IO.File]::ReadAllText($workspace)
  if ($settings -match '(?m)^nodeLinker:') { $settings = [regex]::Replace($settings,'(?m)^nodeLinker:.*$','nodeLinker: hoisted') }
  else { $settings += "`nnodeLinker: hoisted`n" }
  # Build the dependencies installed above without pnpm doing a second implicit install.
  if ($settings -match '(?m)^verifyDepsBeforeRun:') { $settings = [regex]::Replace($settings,'(?m)^verifyDepsBeforeRun:.*$','verifyDepsBeforeRun: false') }
  else { $settings += "`nverifyDepsBeforeRun: false`n" }
  [IO.File]::WriteAllText($workspace,$settings,[Text.UTF8Encoding]::new($false))
  $node = Join-Path $NodeDirectory 'node.exe'
  $tools = Join-Path $stage 'build-tools'
  if (!$PnpmDirectory) {
    Checked $node @((Join-Path $NodeDirectory 'node_modules\npm\bin\npm-cli.js'),'install','--prefix',$tools,'--ignore-scripts','pnpm@11.7.0')
    $PnpmDirectory = Join-Path $tools 'node_modules\pnpm'
  }
  $pnpm = Join-Path $PnpmDirectory 'bin\pnpm.cjs'
  if (!(Test-Path $pnpm)) { $pnpm = Join-Path $PnpmDirectory 'bin\pnpm.mjs' }
  Push-Location $installer
  try {
    $env:CI='true'
    Checked $node @($pnpm,'install','--frozen-lockfile','--node-linker=hoisted','--fetch-timeout','120000','--fetch-retries','2')
    Checked $node @($pnpm,'--recursive','run','build')
    Checked $node @((Join-Path $SourceRoot 'scripts\materialize-windows-workspaces.cjs'),$installer)
    # pnpm may omit an optional native download without failing installation.
    # Codex is required by both OpenAI subscription sign-in methods.
    Checked $node @((Join-Path $SourceRoot 'scripts\check-codex-runtime.cjs'),$installer)
  } finally { Pop-Location }
  $manifest = @{version=1;method='standard';sourceRoot='source';binaries=@{dearmachine='bin/dearmachine.exe';machtiani='bin/machtiani.exe';modelHost='bin/machtiani-model-host.exe';agentManager='bin/agent-manager.exe'}}
  [IO.File]::WriteAllText((Join-Path $stage 'distribution.json'),($manifest | ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
  Move-Item -LiteralPath $stage -Destination $Output
  Write-Output "Prepared Windows bundle: $Output"
} catch {
  Write-Error "Build failed; diagnostic files retained in $stage. $_"
  throw
}
