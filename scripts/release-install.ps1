# Dear Machine release installer for Windows x64, rendered for one GitHub
# release by render-release-installers.py. Do not publish it unrendered.
# Works when saved and run, or when piped to Invoke-Expression.
function Install-DearMachineRelease {
  $ErrorActionPreference = 'Stop'
  Set-StrictMode -Version Latest
  $repository = @REPOSITORY@
  $tag = @TAG@
  $sourceRef = @SOURCE_REF@
  $signerWorkflow = @SIGNER_WORKFLOW@
  $downloadUrl = @DOWNLOAD_URL@
  $target = 'windows-x64'
  $archive = "dearmachine-$tag-$target.zip"
  $destination = Join-Path $env:LOCALAPPDATA 'DearMachine'

  if ($env:OS -ne 'Windows_NT' -or ![Environment]::Is64BitProcess -or $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
    throw 'Dear Machine needs native x64 PowerShell on Windows 11 x64.'
  }
  # Keep extraction paths short; the runtime has deep dependency paths.
  $cache = Join-Path $env:LOCALAPPDATA 'DearMachineBuild'
  $work = Join-Path $cache ('r-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  try {
    # Signed-in gh downloads through the GitHub API, which also works while the
    # repository is private. Otherwise files come from the public release URL.
    $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue
    $ghProgram = if ($gh) { $gh.Source } else { $null }
    $source = 'web'
    $verify = $false
    if (!$gh) {
      if (!(Confirm-Unverified 'missing')) { return }
    } elseif (!(Get-GhVersion $gh.Source)) {
      if (!(Confirm-Unverified 'other')) { return }
    } elseif (!(Test-GhSupported $gh.Source)) {
      if (!(Confirm-Unverified 'outdated')) { return }
    } else {
      $verify = $true
      if ((Invoke-Native $gh.Source @('auth', 'status')).Status -eq 0) { $source = 'gh' }
    }

    Write-Host "Downloading the checksums for Dear Machine $tag..."
    $null = Get-ReleaseFile 'SHA256SUMS'
    $sums = Join-Path $work 'SHA256SUMS'
    if ($verify) {
      # The published bundle lets gh verify without signing in; it is signed,
      # so obtaining it from the release does not weaken the check.
      $bundleArguments = @()
      if (Get-ReleaseFile 'attestation.sigstore.json' -Optional) {
        $bundleArguments = @('--bundle', (Join-Path $work 'attestation.sigstore.json'))
      } elseif ($source -ne 'gh') {
        if (!(Confirm-Unverified 'signed-out')) { return }
        $verify = $false
      }
    }
    if ($verify) {
      Write-Host 'Checking that this release was built by the official release workflow...'
      $check = Invoke-Native $gh.Source (@('attestation', 'verify', $sums) + $bundleArguments + @('--repo', $repository,
        '--signer-workflow', $signerWorkflow, '--source-ref', $sourceRef, '--deny-self-hosted-runners'))
      if ($check.Status -ne 0) {
        $check.Output | Out-Host
        throw 'This release could not be verified, so nothing was installed. Please report this to the Dear Machine maintainers.'
      }
      Write-Host 'Release verified.'
    }
    $expected = $null
    foreach ($line in [IO.File]::ReadAllLines($sums)) {
      if ($line -match '^([0-9a-f]{64}) [ *](.+)$' -and $Matches[2] -eq $archive) { $expected = $Matches[1]; break }
    }
    if (!$expected) { throw "Release $tag has no download for $target yet. Nothing was installed." }

    Write-Host "Downloading Dear Machine $tag for $target..."
    $null = Get-ReleaseFile $archive
    $zip = Join-Path $work $archive
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant() -ne $expected) {
      throw "$archive does not match the release checksums, so nothing was installed."
    }

    $bundle = Join-Path $work 'b'
    Expand-ReleaseZip $zip $bundle
    Remove-Item -LiteralPath $zip -Force
    $installer = Join-Path $bundle 'source\scripts\install-windows.ps1'
    if (!(Test-Path -LiteralPath $installer -PathType Leaf)) { throw 'The release bundle is incomplete. Nothing was installed.' }
    $arguments = @{ Bundle = $bundle; Destination = $destination }
    if (Test-Path -LiteralPath (Join-Path $destination 'windows-installation.json') -PathType Leaf) { $arguments.Update = $true }
    & $installer @arguments
  } finally {
    Remove-ReleaseWork $work $cache
  }
}

# Clean up the extracted bundle after installation. PowerShell 5.1 cannot
# remove its long dependency paths, and Windows cannot remove a running exe.
function Remove-ReleaseWork([string]$Work, [string]$Cache) {
  $node = Join-Path $Work 'b\runtime\node\node.exe'
  $files = Join-Path $Work 'b\source\scripts\windows-files.cjs'
  if ((Test-Path -LiteralPath $node) -and (Test-Path -LiteralPath $files)) {
    $cleanupNode = Join-Path $Cache ('cleanup-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.exe')
    try {
      Copy-Item -LiteralPath $node -Destination $cleanupNode -ErrorAction Stop
      & $cleanupNode $files remove $Work
      if ($LASTEXITCODE -ne 0) { Write-Warning "Temporary files were left in $Work" }
    } catch {
      Write-Warning "Temporary files were left in $Work"
    } finally {
      Remove-Item -LiteralPath $cleanupNode -Force -ErrorAction SilentlyContinue
    }
  } elseif (Test-Path -LiteralPath $Work) {
    Remove-Item -LiteralPath $Work -Recurse -Force
  }
}

# Windows PowerShell turns redirected native stderr into terminating errors
# under ErrorActionPreference Stop; capture it as text instead.
function Invoke-Native([string]$Program, [string[]]$Arguments) {
  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $Program @Arguments 2>&1 | ForEach-Object { "$_" }
    return @{ Status = $LASTEXITCODE; Output = $output }
  } finally { $ErrorActionPreference = $previous }
}

# gh 2.68.0 is the oldest release with --source-ref that also reads the
# current Sigstore trusted root.
# Other programs can also install a gh command; GitHub's reports "gh version".
function Get-GhVersion([string]$Program) {
  $version = Invoke-Native $Program @('--version')
  if ($version.Status -ne 0 -or "$(@($version.Output)[0])" -notmatch '^gh version (\d+)\.(\d+)\.') { return $null }
  return @([int]$Matches[1], [int]$Matches[2])
}

function Test-GhSupported([string]$Program) {
  $version = Get-GhVersion $Program
  return ($version[0] -gt 2) -or ($version[0] -eq 2 -and $version[1] -ge 68)
}

# Download one release file into the caller's $work. With -Optional, report
# absence as $false instead of failing.
function Get-ReleaseFile([string]$Name, [switch]$Optional) {
  $output = Join-Path $work $Name
  if ($source -eq 'gh') {
    $result = Invoke-Native $ghProgram @('release', 'download', $tag, '--repo', $repository, '--pattern', $Name, '--dir', $work)
  } else {
    # Check the status explicitly: some curl releases exit 0 on an HTTP error
    # when --fail is combined with --retry.
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $result = Invoke-Native $curl @('-q', '--silent', '--location', '--proto-redir', '=https', '--connect-timeout', '30',
      '--write-out', '%{http_code}', '--output', $output, '--url', "$downloadUrl/$Name")
    if ($result.Status -eq 0 -and "$($result.Output)".Trim() -ne '200') { $result.Status = 22 }
  }
  if ($result.Status -eq 0) { return $true }
  if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
  if ($Optional) { return $false }
  throw "Could not download $Name. Check your connection and try again."
}

function Expand-ReleaseZip([string]$Archive, [string]$Destination) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\') + '\'
  $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
  try {
    # Validate every entry before anything is written.
    foreach ($entry in $zip.Entries) {
      $name = $entry.FullName.Replace('\', '/')
      if ($name.StartsWith('/') -or $name.Contains(':') -or ($name.Split('/') -contains '..') -or
          (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'The release archive contains an unsafe entry. Nothing was installed.' }
    }
  } finally { $zip.Dispose() }
  New-Item -ItemType Directory -Path $Destination | Out-Null
  # Windows' bsdtar handles the runtime's long dependency paths.
  & (Join-Path $env:SystemRoot 'System32\tar.exe') -xf $Archive -C $Destination
  if ($LASTEXITCODE -ne 0) { throw 'The release archive could not be extracted. Nothing was installed.' }
}

function Confirm-Unverified([string]$Reason) {
  if ($Reason -eq 'missing') {
    $why = "It uses GitHub's free gh tool for that check, and gh isn't installed on this computer."
    $steps = @(
      '  1. Install gh: winget install --id GitHub.cli',
      '     (or follow https://cli.github.com), then open a new PowerShell window',
      '  2. Run this installer again. If it asks you to sign in, run: gh auth login')
  } elseif ($Reason -eq 'other') {
    $why = "It uses GitHub's gh tool for that check, but the gh command on this computer is a different program with the same name."
    $steps = @(
      "  1. Install GitHub's gh: winget install --id GitHub.cli",
      '     (or follow https://cli.github.com), then open a new PowerShell window',
      '  2. Make sure typing gh runs it: gh --version should print "gh version ...".',
      '  3. Run this installer again. If it asks you to sign in, run: gh auth login')
  } elseif ($Reason -eq 'outdated') {
    $why = "It uses GitHub's gh tool for that check, and the gh on this computer is too old to do it. Version 2.68.0 or newer is needed."
    $steps = @(
      '  1. Update gh: winget upgrade --id GitHub.cli',
      '     (or follow https://cli.github.com), then open a new PowerShell window',
      '  2. Run this installer again. If it asks you to sign in, run: gh auth login')
  } else {
    $why = "It uses GitHub's gh tool for that check. gh is installed, but this release can only be checked while gh is signed in to GitHub."
    $steps = @('  1. Sign in with: gh auth login', '  2. Run this installer again.')
  }
  Write-Host ''
  Write-Host 'Before installing, this installer normally checks that Dear Machine really'
  Write-Host "came from its official release process and wasn't changed along the way."
  Write-Host $why
  Write-Host ''
  Write-Host 'The safest choice is to stop here and set up gh. It only takes a minute:'
  Write-Host ''
  $steps | ForEach-Object { Write-Host $_ }
  Write-Host ''
  Write-Host "If you'd rather continue now, the installer will still compare the download with"
  Write-Host "the release's published checksums. That catches a damaged download, but it"
  Write-Host "can't tell whether someone changed the files on purpose."
  Write-Host ''
  # Windows OpenSSH gives an interactive SSH_TTY a console, but the service's
  # window station makes UserInteractive false. Read-Host works in that case.
  if ([Console]::IsInputRedirected -or (![Environment]::UserInteractive -and !$env:SSH_TTY)) {
    throw 'There is no terminal to confirm with, so nothing was installed.'
  }
  $answer = Read-Host 'Type yes to continue without the check, or press Enter to stop'
  if ($answer -cne 'yes') {
    Write-Host 'Stopped. Nothing was installed.'
    return $false
  }
  Write-Host 'Continuing without the release check.'
  return $true
}

Install-DearMachineRelease
