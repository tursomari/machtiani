# One-shot private credential entry for native Windows, matching
# credential-entry.sh: an agent prepares it, the human enters the key in their
# own PowerShell window, and the agent checks a non-secret status.
#
#   credential-entry.ps1 prepare -Name enter-llm-key -Destination PATH -Format environment -Variable NAME
#   credential-entry.ps1 prepare -Name enter-email-key -Destination PATH -Format raw
#   credential-entry.ps1 enter -Name NAME
#   credential-entry.ps1 status -Name NAME
#   credential-entry.ps1 protect -Path PATH
#
# Files receive the private ACL Dear Machine verifies: owned by the current
# user, inheritance disabled, and only the current user and SYSTEM allowed.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true, Position=0)][ValidateSet('prepare','enter','status','protect')][string]$Command,
  [ValidateSet('enter-llm-key','enter-email-key')][string]$Name,
  [string]$Destination,
  [ValidateSet('raw','environment')][string]$Format,
  [string]$Variable,
  [string]$Path
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Fail([string]$Message) { [Console]::Error.WriteLine("credential entry error: $Message"); exit 1 }

function Protect-Private([string]$Target) {
  $item = Get-Item -LiteralPath $Target -Force
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Fail 'reparse points are not allowed' }
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
  $acl = Get-Acl -LiteralPath $Target
  if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value) { Fail 'the current user must own the file' }
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleSpecific($rule) }
  $inherit = [Security.AccessControl.InheritanceFlags]::None
  if ($item.PSIsContainer) { $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' }
  foreach ($principal in @($sid, [Security.Principal.SecurityIdentifier]'S-1-5-18')) {
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($principal, 'FullControl', $inherit, 'None', 'Allow')))
  }
  $item.SetAccessControl($acl)
  foreach ($rule in (Get-Acl -LiteralPath $Target).Access) {
    if ($rule.AccessControlType -eq 'Allow') {
      $principal = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
      if ($principal -ne $sid.Value -and $principal -ne 'S-1-5-18') { Fail 'the private ACL could not be applied' }
    }
  }
}

function New-PrivateDirectory([string]$Directory) {
  if (!(Test-Path -LiteralPath $Directory)) {
    New-Item -ItemType Directory -Path $Directory | Out-Null
    Protect-Private $Directory
  }
}

function Assert-HomePath([string]$Candidate) {
  if (![IO.Path]::IsPathRooted($Candidate)) { Fail 'the destination must be an absolute path' }
  $full = [IO.Path]::GetFullPath($Candidate)
  $profileRoot = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\') + '\'
  if (!$full.StartsWith($profileRoot, [StringComparison]::OrdinalIgnoreCase)) { Fail 'the destination must be beneath USERPROFILE' }
  if ((Test-Path -LiteralPath $full) -and ((Get-Item -LiteralPath $full -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    Fail 'the destination must not be a link'
  }
  $full
}

function Write-PrivateText([string]$Target, [string]$Text) {
  $directory = Split-Path -Parent $Target
  New-PrivateDirectory $directory
  $temporary = Join-Path $directory ('.credential.' + [Guid]::NewGuid().ToString('N'))
  try {
    [IO.File]::WriteAllText($temporary, '')
    Protect-Private $temporary
    [IO.File]::WriteAllText($temporary, $Text, (New-Object Text.UTF8Encoding($false)))
    # PowerShell passes $null to a .NET string parameter as '', which Replace rejects
    # as an illegal backup path; [NullString]::Value is a real null (no backup copy).
    if (Test-Path -LiteralPath $Target) { [IO.File]::Replace($temporary, $Target, [NullString]::Value) } else { [IO.File]::Move($temporary, $Target) }
  } finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
  }
  Protect-Private $Target
}

$stateRoot = Join-Path $env:LOCALAPPDATA 'dearmachine\installation'
function Spec-Path { Join-Path $stateRoot "$Name.spec.json" }
function Status-Path { Join-Path $stateRoot "$Name.status" }
function Set-Status([string]$Value) { New-PrivateDirectory $stateRoot; Write-PrivateText (Status-Path) "$Value`n" }

switch ($Command) {
  'protect' {
    if (!$Path) { Fail 'protect requires -Path' }
    Protect-Private ([IO.Path]::GetFullPath($Path))
    'protected'
  }
  'prepare' {
    if (!$Name -or !$Destination -or !$Format) { Fail 'prepare requires -Name, -Destination and -Format' }
    if ($Format -eq 'environment' -and $Variable -notmatch '^[A-Z_][A-Z0-9_]*$') { Fail 'environment format requires a valid -Variable' }
    if ($Format -eq 'raw' -and $Variable) { Fail '-Variable is not valid with raw format' }
    $spec = @{ destination = (Assert-HomePath $Destination); format = $Format; variable = $(if ($Variable) { $Variable } else { '' }) }
    New-PrivateDirectory $stateRoot
    Write-PrivateText (Spec-Path) ($spec | ConvertTo-Json -Compress)
    if (Test-Path -LiteralPath (Status-Path)) { Remove-Item -LiteralPath (Status-Path) -Force }
    'prepared'
  }
  'enter' {
    if (!$Name) { Fail 'enter requires -Name' }
    if (!(Test-Path -LiteralPath (Spec-Path) -PathType Leaf)) { Fail "no prepared credential entry named $Name" }
    $spec = Get-Content -Raw -LiteralPath (Spec-Path) | ConvertFrom-Json
    $target = Assert-HomePath $spec.destination
    Set-Status 'started'
    $secure = Read-Host -AsSecureString 'Paste your key with Ctrl+V (or right-click), then press Enter. It will not be shown'
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer).Trim() }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer); $secure.Dispose() }
    if ($value -eq '' -or $value -match '\s') { Set-Status 'failed:input'; Fail 'enter exactly one key without spaces' }
    if ($spec.format -eq 'environment') { $text = "$($spec.variable)=$value`n" } else { $text = "$value`n" }
    Write-PrivateText $target $text
    Remove-Variable value, text
    Set-Status 'success'
    'Saved. You can close this window and tell your agent you are done.'
  }
  'status' {
    if (!$Name) { Fail 'status requires -Name' }
    if (!(Test-Path -LiteralPath (Spec-Path) -PathType Leaf)) { Fail "no prepared credential entry named $Name" }
    $status = ''
    if (Test-Path -LiteralPath (Status-Path)) { $status = (Get-Content -Raw -LiteralPath (Status-Path)).Trim() }
    if ($status -eq 'success') {
      Remove-Item -LiteralPath (Spec-Path), (Status-Path) -Force
      'ready'
    } elseif ($status -like 'failed:*') {
      Fail "credential entry did not complete ($($status.Substring(7)))"
    } else { 'pending' }
  }
}
