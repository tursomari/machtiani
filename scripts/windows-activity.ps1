# Keep the terminal responsive while a noninteractive PowerShell worker is busy.
function Invoke-WindowsActivity {
  param(
    [Parameter(Mandatory=$true)][string]$Label,
    [Parameter(Mandatory=$true)][string]$ScriptPath,
    [hashtable]$Arguments = @{}
  )
  function Literal([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }
  $call = '& ' + (Literal $ScriptPath)
  foreach ($name in $Arguments.Keys) {
    if ($name -notmatch '^[A-Za-z][A-Za-z0-9]*$') { throw 'Invalid worker parameter name.' }
    $call += ' -' + $name + ' ' + (Literal ([string]$Arguments[$name]))
  }
  $command = "`$ErrorActionPreference='Stop'; `$ProgressPreference='SilentlyContinue'; " +
    "`$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false); " +
    "if ([Console]::ReadLine() -ne 'start') { exit 1 }; `$global:LASTEXITCODE=0; try { $call; exit `$LASTEXITCODE } catch { [Console]::Error.WriteLine(`$_.ToString()); exit 1 }"
  $info = [Diagnostics.ProcessStartInfo]::new()
  $info.FileName = Join-Path $PSHOME 'powershell.exe'
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  # -EncodedCommand makes Windows PowerShell serialize information records as
  # CLIXML on stderr. Decode a literal base64 value via -Command instead.
  $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -Command "& ([scriptblock]::Create([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(' + "'$encoded'" + '))))"'
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.RedirectStandardInput = $true
  $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
  # Same braille frames and 100 ms cadence as InstallerTui's slow activity.
  # Code points keep this script readable by Windows PowerShell 5.1 without a BOM.
  $frames = @('2886,2870','288e,2860','288e,2841','288e,2811','280e,2831','280a,2871','2888,2871','2884,2871') |
    ForEach-Object { -join ($_.Split(',') | ForEach-Object { [char][Convert]::ToInt32($_,16) }) }
  $interactive = ![Console]::IsOutputRedirected -and $env:TERM -ne 'dumb'
  $clear = "`r"
  $consoleEncoding = [Console]::OutputEncoding
  $clock = [Diagnostics.Stopwatch]::StartNew()
  $process = [Diagnostics.Process]::new()
  $process.StartInfo = $info
  $started = $false
  $job = $null
  try {
    if ($interactive) { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) }
    Write-Host $Label
    if (!('DearMachine.WindowsPreparationJob' -as [type])) {
      Add-Type -Path (Join-Path $PSScriptRoot 'windows-activity-job.cs')
    }
    $job = [DearMachine.WindowsPreparationJob]::new()
    $started = $process.Start()
    $job.Assign($process)
    # The worker waits for this handshake before starting any build descendants.
    $process.StandardInput.WriteLine('start')
    $process.StandardInput.Close()
    $readers = @($process.StandardOutput, $process.StandardError)
    $pending = @($readers[0].ReadLineAsync(), $readers[1].ReadLineAsync())
    $workerFinished = $false
    while (!$process.HasExited -or $null -ne $pending[0] -or $null -ne $pending[1]) {
      if ($process.HasExited -and !$workerFinished) {
        # An exited worker must not leave descendants holding its output pipes.
        $job.Dispose()
        $workerFinished = $true
      }
      for ($i = 0; $i -lt 2; $i++) {
        # Bound each drain so a noisy build cannot starve animation or stderr.
        for ($count = 0; $count -lt 100 -and $null -ne $pending[$i] -and $pending[$i].IsCompleted; $count++) {
          $line = $pending[$i].GetAwaiter().GetResult()
          if ($null -eq $line) { $pending[$i] = $null; break }
          if ($interactive) { [Console]::Write($clear) }
          Write-Host $line
          $pending[$i] = $readers[$i].ReadLineAsync()
        }
      }
      if ($interactive) {
        $frame = $frames[[int][Math]::Floor($clock.ElapsedMilliseconds / 100) % $frames.Count]
        $elapsed = [int][Math]::Floor($clock.Elapsed.TotalSeconds)
        # Limit width so the activity row never wraps on a narrow console.
        $text = "$frame $Label ($($elapsed)s)"
        $width = [Math]::Max(1, [Console]::WindowWidth - 1)
        if ($text.Length -gt $width) { $text = $text.Substring(0,$width) }
        [Console]::Write($clear + $text)
        # Carriage return and spaces also work in the legacy console without VT.
        $clear = "`r" + (' ' * $text.Length) + "`r"
      }
      Start-Sleep -Milliseconds 100
    }
    if ($process.ExitCode -ne 0) { throw "$Label failed (exit $($process.ExitCode)). See the output above." }
  } finally {
    if ($interactive) { [Console]::Write($clear) }
    if ($interactive) { [Console]::OutputEncoding = $consoleEncoding }
    # The job owns descendants even if Ctrl+C has already ended their parent.
    # Direct .NET calls also work when PowerShell's pipeline has been cancelled.
    if ($null -ne $job) { $job.Dispose() }
    if ($started -and !$process.HasExited) {
      $process.Kill()
      $process.WaitForExit()
    }
    $process.Dispose()
  }
}
