# Native Windows check for scripts/credential-entry.ps1: replacing an existing
# private file (a status update, a repeated prepare, or a re-entered key) and the
# private ACL. Requires Windows PowerShell 5.1 on Windows; uses no real secrets.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$helper = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts\credential-entry.ps1'
$root = Join-Path $env:USERPROFILE ('credential-entry-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
function Fail([string]$Message) { throw "credential entry test failure: $Message" }
try {
  # Load the helper's private-file functions without running its command switch.
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($helper, [ref]$null, [ref]$null)
  foreach ($function in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([ScriptBlock]::Create($function.Extent.Text))
  }
  $target = Join-Path $root 'private.env'
  Write-PrivateText $target "TEST_KEY=first`n"
  Write-PrivateText $target "TEST_KEY=second`n"
  if ((Get-Content -Raw -LiteralPath $target) -ne "TEST_KEY=second`n") { Fail 'replacement did not write the new value' }
  if (Get-ChildItem -LiteralPath $root -Filter '.credential*' -Force) { Fail 'replacement left a temporary or backup copy' }
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  foreach ($rule in (Get-Acl -LiteralPath $target).Access) {
    $principal = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    if ($rule.AccessControlType -eq 'Allow' -and $principal -ne $sid -and $principal -ne 'S-1-5-18') { Fail "unexpected access for $principal" }
  }

  # A repeated prepare replaces the saved specification in an isolated state root.
  $saved = $env:LOCALAPPDATA
  $env:LOCALAPPDATA = Join-Path $root 'state'
  try {
    foreach ($attempt in 1, 2) {
      $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper prepare -Name enter-llm-key `
        -Destination (Join-Path $root 'model.env') -Format environment -Variable TEST_KEY 2>&1
      if ($LASTEXITCODE -ne 0 -or "$output".Trim() -ne 'prepared') { Fail "prepare attempt $attempt failed: $output" }
    }
    $status = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper status -Name enter-llm-key 2>&1
    if ("$status".Trim() -ne 'pending') { Fail "status after prepare was not pending: $status" }
  } finally { $env:LOCALAPPDATA = $saved }
  'credential entry Windows test passed'
} finally {
  Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}
