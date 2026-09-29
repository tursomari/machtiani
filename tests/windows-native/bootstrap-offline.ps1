# Offline archive and cache boundary tests. Also runs under PowerShell on Linux.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../../scripts/windows-bootstrap-lib.ps1')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$root = Join-Path ([IO.Path]::GetTempPath()) ('windows-bootstrap-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
function Require([bool]$Value, [string]$Message) { if (!$Value) { throw $Message } }
function Refuses([scriptblock]$Action, [string]$Message) {
  $failed = $false
  try { & $Action | Out-Null } catch { $failed = $true }
  Require $failed $Message
}
try {
  $fixture = Join-Path $root 'fixture'
  [IO.File]::WriteAllText($fixture, 'fixture dependency')
  $hash = (Get-FileHash -Algorithm SHA256 $fixture).Hash.ToLowerInvariant()
  $entry = @{url='https://fixture.invalid/archive';sha256=$hash;format='zip'}
  $script:downloads = 0
  $download = { param($url,$output); $script:downloads++; Copy-Item -LiteralPath $fixture -Destination $output }
  $archive = Get-VerifiedArchive $entry $root $download
  Require ($script:downloads -eq 1) 'Expected first download'
  [void](Get-VerifiedArchive $entry $root { throw 'Cache reuse must not download' })
  [IO.File]::WriteAllText($archive, 'corruption')
  [void](Get-VerifiedArchive $entry $root $download)
  Require ($script:downloads -eq 2) 'Corrupted cache was not reacquired'
  Remove-Item $archive
  Refuses { Get-VerifiedArchive $entry $root { param($url,$output); [IO.File]::WriteAllText($output,'wrong bytes') } } 'Checksum mismatch accepted'
  Require (!(Test-Path $archive)) 'Bad download was activated'
  Require (@(Get-ChildItem $root -Filter '*.partial-*').Count -eq 0) 'Partial download retained'
  Refuses { Get-VerifiedArchive @{url='http://fixture.invalid/archive';sha256=$hash;format='zip'} $root $download } 'HTTP pin accepted'
  Refuses { Get-VerifiedArchive $entry $root {
    param($url,$output)
    [IO.File]::WriteAllText($output, 'interrupted transfer')
    throw 'connection lost'
  } } 'Failed transport was accepted'
  Require (!(Test-Path $archive)) 'Failed transport activated an archive'
  Require (@(Get-ChildItem $root -Filter '*.partial-*').Count -eq 0) 'Failed transport retained partial bytes'
  Require ((Get-VerifiedArchive $entry $root $download) -eq $archive) 'Retry did not recover after a failed transport'
  foreach ($name in @('../escape', '/absolute', 'C:/outside', 'dir\..\escape')) {
    $zipPath = Join-Path $root ([Guid]::NewGuid().ToString('N') + '.zip')
    $zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
    [void]$zip.CreateEntry($name); $zip.Dispose()
    $output = Join-Path $root ([Guid]::NewGuid().ToString('N'))
    Refuses { Expand-VerifiedZip $zipPath $output } 'Traversal archive accepted'
    Require (!(Test-Path $output)) 'Unsafe archive wrote output'
  }
  $zipPath = Join-Path $root 'valid.zip'
  $zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
  $entry = $zip.CreateEntry('tool/bin/tool.txt')
  $writer = New-Object IO.StreamWriter($entry.Open()); $writer.Write('valid'); $writer.Dispose(); $zip.Dispose()
  $output = Join-Path $root 'valid'
  Expand-VerifiedZip $zipPath $output
  Require ([IO.File]::ReadAllText((Join-Path $output 'tool/bin/tool.txt')) -eq 'valid') 'Valid archive failed'
  $zipHash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLowerInvariant()
  Copy-Item $zipPath (Join-Path $root ($zipHash + '.zip'))
  $pin = @{url='https://fixture.invalid/tool.zip';sha256=$zipHash;format='zip';directory='tool'}
  $tool = Get-WindowsDependency 'fixture' $pin $root ''
  Require (Test-Path (Join-Path $tool 'bin/tool.txt')) 'Dependency extraction failed'
  Require ((Get-WindowsDependency 'fixture' $pin $root '') -eq $tool) 'Verified extraction was not reused'
  [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $tool) '.complete'), 'incorrect identity')
  Refuses { Get-WindowsDependency 'fixture' $pin $root '' } 'Incorrect cache identity accepted'
  if ($env:OS -eq 'Windows_NT') {
    # Exercise the real downloader's nonzero exit, not a scriptblock exception.
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $listener.Stop()
    $failure = $null
    $unreachable = @{url="https://127.0.0.1:$port/archive";sha256=('0' * 64);format='zip'}
    try { Get-VerifiedArchive $unreachable $root | Out-Null } catch { $failure = $_ }
    Require ($null -ne $failure) 'Downloader failure was ignored'
    Require ($failure.ToString() -match 'run Quick start again') 'Download failure omitted recovery guidance'
    Require (!(Test-Path (Join-Path $root (('0' * 64) + '.zip')))) 'Downloader failure activated an archive'
    Require (@(Get-ChildItem $root -Filter '*.partial-*').Count -eq 0) 'Downloader failure retained partial bytes'
    # The Unix tar shipped with Git fails here without ambient gzip and treats
    # the drive colon as a remote archive. Exercise the native tool on real paths.
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    $tgz = Join-Path $root 'fixture with spaces.tgz'
    & $tar -czf $tgz -C $output tool
    Require ($LASTEXITCODE -eq 0) 'Could not create the native tar fixture'
    $tgzHash = (Get-FileHash -Algorithm SHA256 $tgz).Hash.ToLowerInvariant()
    Copy-Item $tgz (Join-Path $root ($tgzHash + '.tgz'))
    $tarPin = @{url='https://fixture.invalid/tool.tgz';sha256=$tgzHash;format='tgz';directory='tool'}
    $extracted = Get-WindowsDependency 'tar-fixture' $tarPin $root $tar
    Require ([IO.File]::ReadAllText((Join-Path $extracted 'bin/tool.txt')) -eq 'valid') 'Native tar extraction failed'
  }
  Write-Output 'Windows bootstrap offline checks passed'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
