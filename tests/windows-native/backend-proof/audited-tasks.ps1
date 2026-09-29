$ErrorActionPreference='Stop'
. "$env:USERPROFILE\windows-proof\backend-proof\common.ps1"
$proxy=Start-Process node.exe -ArgumentList "$proof\audit-proxy.mjs" -PassThru -RedirectStandardOutput "$proof\proxy-stdout.log" -RedirectStandardError "$proof\proxy-stderr.log"
$ompPath="$env:USERPROFILE\.omp\agent\models.yml"
$forgePath=Join-Path $env:FORGE_CONFIG 'provider.json'
$ompOriginal=[IO.File]::ReadAllText($ompPath)
$forgeOriginal=[IO.File]::ReadAllText($forgePath)
try {
 Start-Sleep -Seconds 2
 $env:PROOF_API_ORIGIN='http://127.0.0.1:18191'
 [IO.File]::WriteAllText($ompPath,$ompOriginal.Replace('https://api.deepinfra.com',$env:PROOF_API_ORIGIN),[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText($forgePath,$forgeOriginal.Replace('https://api.deepinfra.com',$env:PROOF_API_ORIGIN),[Text.UTF8Encoding]::new($false))
 foreach($backend in @('claude','omp','forge')){& "$proof\run-ticket.ps1" -Backend $backend -Label audited}
 $config=@'
model = "zai-org/GLM-5.3"
model_provider = "deepinfra"
model_reasoning_effort = "high"
[model_providers.deepinfra]
name = "DeepInfra protocol test"
base_url = "http://127.0.0.1:18191/v1/openai"
env_key = "DEEPINFRA_API_KEY"
wire_api = "responses"
request_max_retries = 0
stream_max_retries = 0
stream_idle_timeout_ms = 15000
'@
 [IO.File]::WriteAllText((Join-Path $env:CODEX_HOME 'config.toml'),$config,[Text.UTF8Encoding]::new($false))
 try {& "$proof\run-ticket.ps1" -Backend codex-yolo -Label protocol -TimeoutSeconds 45} catch {"Codex protocol test: $($_.Exception.Message)"}
 Get-Content "$proof\wire-metadata.jsonl" -Encoding UTF8
} finally {
 [IO.File]::WriteAllText($ompPath,$ompOriginal,[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText($forgePath,$forgeOriginal,[Text.UTF8Encoding]::new($false))
 $env:PROOF_API_ORIGIN=$null
 Stop-Process -Id $proxy.Id -ErrorAction SilentlyContinue
}
