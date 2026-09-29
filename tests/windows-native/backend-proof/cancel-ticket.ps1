param([string]$Backend='claude')
$ErrorActionPreference='Stop'
. "$env:USERPROFILE\windows-proof\backend-proof\common.ps1"
$workspace=Join-Path $env:USERPROFILE ('Documents\Backend proof '+[char]0x03A9+'\'+$Backend)
$marker=Join-Path $workspace 'running.json'
Remove-Item $marker -Force -ErrorAction SilentlyContinue
$script=@'
const fs = require('fs');
fs.writeFileSync('running.json', JSON.stringify({pid:process.pid, parent:process.ppid}));
setInterval(() => fs.writeFileSync('heartbeat.txt', String(Date.now())), 500);
setTimeout(() => process.exit(0), 180000);
'@
[IO.File]::WriteAllText((Join-Path $workspace 'slow.cjs'),$script,[Text.UTF8Encoding]::new($false))
$request=Join-Path $proof ($Backend+'-cancel-request.md')
[IO.File]::WriteAllText($request,'This is a cancellation test. Use your shell tool to run node slow.cjs in the current directory. This script writes a PID marker and a heartbeat and waits three minutes. Let it run in the foreground. Do not change the script or run other commands. No delegation or subagents. The test controller will cancel your ticket.',[Text.UTF8Encoding]::new($false))
$id=(& $manager ticket send --backend $Backend --file $request --cwd $workspace | Out-String).Trim()
if($LASTEXITCODE -ne 0){throw 'ticket send failed'}
"cancel-ticket=$id backend=$Backend"
$metaPath=Join-Path $env:DEARMACHINE_HOME "agent-manager\tickets\$id\meta.json"
$deadline=(Get-Date).AddSeconds(150)
while(-not(Test-Path $marker) -and (Get-Date) -lt $deadline){Start-Sleep -Seconds 2}
if(-not(Test-Path $marker)){& $manager ticket cancel $id; throw 'Backend did not launch the cancellation child'}
$child=Get-Content $marker -Raw | ConvertFrom-Json
$meta=Get-Content $metaPath -Encoding UTF8 -Raw | ConvertFrom-Json
"workerPID=$($meta.pid) childPID=$($child.pid)"
if(-not (Get-Process -Id $child.pid -ErrorAction SilentlyContinue)){throw 'Child was not live before cancellation'}
& $manager ticket cancel $id
if($LASTEXITCODE -ne 0){throw 'Cancel command failed'}
$deadline=(Get-Date).AddSeconds(15)
do{Start-Sleep -Milliseconds 500;$running=Get-Process -Id $child.pid,$meta.pid -ErrorAction SilentlyContinue}while($running -and (Get-Date) -lt $deadline)
if($running){throw 'Cancelled process tree is still running'}
$meta=Get-Content $metaPath -Encoding UTF8 -Raw | ConvertFrom-Json
if($meta.status -ne 'cancelled'){throw "Unexpected cancellation status $($meta.status)"}
"PASS: $Backend cancellation; worker and native child exited; status cancelled"
$meta | ConvertTo-Json -Depth 6
