# Run native test executables only inside a disposable Windows guest.
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Products,
  [Parameter(Mandatory=$true)][string]$GitDirectory
)
$ErrorActionPreference='Stop'
if ($env:OS -ne 'Windows_NT' -or $env:COMPUTERNAME -ne 'DM-WIN-TEST') { throw 'A disposable Windows guest is required.' }
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$principal=[Security.Principal.WindowsPrincipal]::new($identity)
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run the application proof as an ordinary user.' }
$env:HOME=$env:USERPROFILE
$env:PATH="$GitDirectory\bin;$GitDirectory\usr\bin;$env:PATH"
function Checked([string]$Name,[string[]]$Arguments) {
  & (Join-Path $Products $Name) @Arguments
  if($LASTEXITCODE -ne 0){throw "$Name failed with exit code $LASTEXITCODE"}
}
foreach($name in @('dearmachine','machtiani','agent-manager')) { Checked "$name.exe" @('--help') }
Checked 'hostos.test.exe' @('-test.v')
Checked 'entrypoint.test.exe' @('-test.v','-test.run','^TestInstallSeedCopiesEmbeddedFiles$')
Checked 'supervisor.test.exe' @('-test.v','-test.run','TestControlWaitsForSlowButValidStartup|TestWindows|TestControlLifecycle|TestBackoffBoundAndStop|TestReadinessAndStopDuringStartup|TestHealthyRunResetsFailures|TestStartupTimeoutFailsAndReaps|TestShutdownReleasesSupervisorForUpdate')
Checked 'shellenv.test.exe' @('-test.v')
Checked 'client.test.exe' @('-test.v','-test.run','TestGuestStoreScopeAndNoHistoricalMigration|TestPairStoresKeepProviderIDsAndAliasesIndependent|TestOpenPairStoreRejectsPairMetaMismatch|TestCreatePairCreatesFreshStoreWithMatchingMeta|TestSendmux|TestWindowsSendmux')
Checked 'client.test.exe' @('-test.run','^TestSendmuxJMAPConcurrentRecoverySubmitsOnce$','-test.count','50')
Write-Output 'WINDOWS_PRIMITIVES_OK: ordinary-user CLI, permissions, workspace seeds, locking, supervisor, shell, cancellation, SQLite, Sendmux recovery'
