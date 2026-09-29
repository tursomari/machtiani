# Internal helpers shared by the Windows Quick start and its offline tests.
Set-StrictMode -Version Latest
function Assert-PlainDirectory([string]$Path) {
  for ($at = [IO.Path]::GetFullPath($Path); $at; $at = Split-Path -Parent $at) {
    if (Test-Path -LiteralPath $at) {
      $item = Get-Item -Force -LiteralPath $at
      if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Refusing redirected or non-directory path: $at" }
    }
  }
}
function New-PrivateDirectory([string]$Path) {
  Assert-PlainDirectory $Path
  if (Test-Path -LiteralPath $Path) { return }
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  $acl = Get-Acl -LiteralPath $Path
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleSpecific($rule) }
  foreach ($principal in @($sid, [Security.Principal.SecurityIdentifier]'S-1-5-18')) {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($principal,'FullControl','ContainerInherit, ObjectInherit','None','Allow')))
  }
  Set-Acl -LiteralPath $Path -AclObject $acl
}
function Get-VerifiedArchive($Entry, [string]$Cache, [scriptblock]$Download = {
  param($Url, $Output)
  # Use Windows 11's streaming downloader. Bound connection and idle waits so
  # an unresponsive transfer cannot leave Quick start spinning indefinitely.
  # Disable user curl configuration; dependency pins own the request options.
  $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
  & $curl -q --fail --location --proto '=https' --proto-redir '=https' `
    --connect-timeout 30 --max-time 1200 --speed-limit 1024 --speed-time 60 `
    --retry 2 --retry-delay 2 --retry-max-time 180 --silent --show-error `
    --output $Output --url $Url
  if ($LASTEXITCODE -ne 0) {
    throw 'Dependency download failed. Check your connection and run Quick start again; verified downloads will be reused.'
  }
}) {
  if ($Entry.sha256 -notmatch '^[a-f0-9]{64}$' -or ([uri]$Entry.url).Scheme -ne 'https') { throw 'Invalid dependency pin.' }
  $extension = switch ($Entry.format) { 'zip' { '.zip' } 'exe' { '.exe' } 'tgz' { '.tgz' } default { throw 'Unknown archive format.' } }
  $archive = Join-Path $Cache ($Entry.sha256 + $extension)
  if (Test-Path -LiteralPath $archive) {
    if ((Get-Item -Force -LiteralPath $archive).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Redirected dependency archive.' }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant() -eq $Entry.sha256) { return $archive }
    Remove-Item -LiteralPath $archive -Force
  }
  $partial = $archive + '.partial-' + [Guid]::NewGuid().ToString('N')
  try {
    & $Download $Entry.url $partial | Out-Null
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $partial).Hash.ToLowerInvariant() -ne $Entry.sha256) { throw 'Dependency checksum failed; nothing was executed.' }
    Move-Item -LiteralPath $partial -Destination $archive
  } finally { if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force } }
  return $archive
}
function Expand-VerifiedZip([string]$Archive, [string]$Destination) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $root = [IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
  $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
  try {
    # Validate the entire archive before writing any files.
    foreach ($entry in $zip.Entries) {
      $name = $entry.FullName.Replace('\', '/')
      $target = [IO.Path]::GetFullPath((Join-Path $Destination $name))
      if ($name.StartsWith('/') -or $name.Contains(':') -or $name.Split('/') -contains '..' -or
          !$target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
          (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Unsafe dependency archive entry.' }
    }
    [IO.Compression.ZipFile]::ExtractToDirectory($Archive, $Destination)
  } finally { $zip.Dispose() }
}
function Get-WindowsDependency([string]$Name, $Entry, [string]$Cache, [string]$NativeTar) {
  Write-Host "Prepare $Name"
  $archive = Get-VerifiedArchive $Entry $Cache
  $directory = Join-Path $Cache ($Name + '-' + $Entry.sha256.Substring(0,16))
  Assert-PlainDirectory $directory
  $marker = Join-Path $directory '.complete'
  if (Test-Path -LiteralPath $marker -PathType Leaf) {
    if ((Get-Content -Raw -LiteralPath $marker) -ne $Entry.sha256) { throw 'Dependency cache identity does not match its pin.' }
  } else {
    if (Test-Path -LiteralPath $directory) { throw "Incomplete dependency extraction: $directory. Remove that directory and retry." }
    $stage = $directory + '.extracting-' + [Guid]::NewGuid().ToString('N')
    switch ($Entry.format) {
      'zip' { Expand-VerifiedZip $archive $stage }
      'exe' {
        # PortableGit is a checksum-verified self-extracting 7-Zip archive.
        & $archive "-o$stage" '-y' | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Portable Git extraction failed.' }
      }
      'tgz' {
        New-Item -ItemType Directory -Path $stage | Out-Null
        # Windows' bsdtar understands drive paths and includes gzip support.
        & $NativeTar -xzf $archive -C $stage
        if ($LASTEXITCODE -ne 0) { throw 'pnpm extraction failed.' }
      }
    }
    [IO.File]::WriteAllText((Join-Path $stage '.complete'), $Entry.sha256)
    Move-Item -LiteralPath $stage -Destination $directory
  }
  return Join-Path $directory $Entry.directory
}
