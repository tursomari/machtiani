param([string]$Backend='claude',[string]$Label='file',[int]$TimeoutSeconds=240)
$ErrorActionPreference='Stop'
. "$env:USERPROFILE\windows-proof\backend-proof\common.ps1"
$workspace=Join-Path $env:USERPROFILE ('Documents\Backend proof '+[char]0x03A9+'\'+$Backend)
New-Item -ItemType Directory -Force $workspace | Out-Null
$inputPath=Join-Path $workspace 'expenses.csv'
if(-not (Test-Path $inputPath)){[IO.File]::WriteAllText($inputPath,"category,amount`ntravel,12.50`nfood,8.25`ntravel,7.50`nfood,4.75`n",[Text.UTF8Encoding]::new($false))}
$hash=(Get-FileHash $inputPath).Hash
$resultPath=Join-Path $workspace ($Label+' summary.txt')
$request=Join-Path $proof ($Backend+'-'+$Label+'-request.md')
$prompt="Read expenses.csv in the current directory. Calculate totals by category and the grand total. Write a file named exactly `"$Label summary.txt`" in this directory containing the totals with two decimal places. Do not change expenses.csv. Use your file or shell tools to actually perform the task. No delegation or subagents. Return a short final response confirming the output."
[IO.File]::WriteAllText($request,$prompt,[Text.UTF8Encoding]::new($false))
$id=(& $manager ticket send --backend $Backend --file $request --cwd $workspace | Out-String).Trim()
if($LASTEXITCODE -ne 0){throw 'ticket send failed'}
"ticket=$id backend=$Backend"
$metaPath=Join-Path $env:DEARMACHINE_HOME "agent-manager\tickets\$id\meta.json"
$deadline=(Get-Date).AddSeconds($TimeoutSeconds)
do {
 Start-Sleep -Seconds 2
 $meta=Get-Content $metaPath -Encoding UTF8 -Raw | ConvertFrom-Json
} while($meta.status -eq 'open' -and (Get-Date) -lt $deadline)
if($meta.status -eq 'open'){& $manager ticket cancel $id; throw "Timed out ticket $id"}
$meta | ConvertTo-Json -Depth 6
if($meta.status -ne 'closed'){throw "Ticket ended $($meta.status): $($meta.failure_reason)"}
if((Get-FileHash $inputPath).Hash -ne $hash){throw 'Input modified'}
$result=[IO.File]::ReadAllText($resultPath)
foreach($amount in @('20.00','13.00','33.00')){if(-not $result.Contains($amount)){throw "Missing total $amount"}}
$result
"PASS: $Backend $Label; input unchanged; output verified"
