#requires -Version 7
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/service-ops.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
foreach ($node in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { Invoke-Expression $node.Extent.Text }
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Write-Die($message) { throw $message }
function Write-Warn($message) {}
function Invoke-SshClient($command, $arguments, $authentication, $user, $timeoutSeconds) {
    return [pscustomobject]@{ ExitCode=$script:fixtureExit; TimedOut=($script:fixtureExit -eq 124); Stdout=''; Stderr='' }
}
function Invoke-RemoteRelease($context, $action, $record, $remoteUpload, $token) { $script:events.Add($action) }
foreach ($code in @(124,137,255)) {
    $script:fixtureExit=$code; $script:RemoteWriteUnknown=$false; $script:ReleaseLockToken=$null
    $script:events=[Collections.Generic.List[string]]::new(); $message=''
    try { Invoke-ReleaseLocked @{} @{} { param($token) Ssh-Run 'fixture.invalid' 'fixture-key' 'fixture' 'fixture' 120 -Mutation } } catch { $message=$_.Exception.Message }
    Assert ($message -match 'RESULT UNKNOWN') "write exit $code must remain UNKNOWN: $message"
    Assert ('release' -notin $script:events) 'uncertain writes must retain the remote lock'
    $script:RemoteWriteUnknown=$false; $message=''
    try { Scp-Put 'fixture.invalid' 'fixture-key' 'fixture' 'fixture' '/tmp/fixture' } catch { $message=$_.Exception.Message }
    Assert ($message -match 'RESULT UNKNOWN' -and $script:RemoteWriteUnknown) 'uncertain transfers must retain UNKNOWN'
}
$script:fixtureExit=124; $script:RemoteWriteUnknown=$false; $message=''
try { Ssh-Run 'fixture.invalid' 'fixture-key' 'fixture' 'fixture' } catch { $message=$_.Exception.Message }
Assert ($message -match 'RESULT PARTIAL') 'query deadlines must retain PARTIAL semantics'
Assert (-not $script:RemoteWriteUnknown) 'query deadlines must not change write state'
$script:RemoteWriteUnknown=$false; $script:ReleaseLockToken=$null; $script:events=[Collections.Generic.List[string]]::new()
try { Invoke-ReleaseLocked @{} @{} { throw 'known completed failure' } } catch {}
Assert ('release' -in $script:events) 'known completed failures must release their owned lock'
function Invoke-RemoteRelease($context, $action, $record, $remoteUpload, $token) {
    if ($action -eq 'release') { throw 'FIXTURE_RELEASE_FAILED' }
}
$message=''
try { Invoke-ReleaseLocked @{} @{} {} } catch { $message=$_.Exception.Message }
Assert ($message -match 'FIXTURE_RELEASE_FAILED') 'lock release failure must prevent a successful task'
$PluginRoot = Split-Path -Parent $PSScriptRoot
$oldFingerprint=$env:SERVICE_OPS_CONFIG_FINGERPRINT; $oldPython=$env:SERVICE_OPS_PYTHON; $oldScope=$env:SERVICE_OPS_TASK_SCOPE
try {
    $env:SERVICE_OPS_CONFIG_FINGERPRINT='fixture-mismatch'; $env:SERVICE_OPS_PYTHON=(Get-Command python).Source; $env:SERVICE_OPS_TASK_SCOPE='test'
    $message=''
    try { Assert-TaskConfig | Out-Null } catch { $message=$_.Exception.Message }
    Assert ($message -match 'CONFIG_CHANGED') 'configuration drift must stop before SSH'
} finally { $env:SERVICE_OPS_CONFIG_FINGERPRINT=$oldFingerprint; $env:SERVICE_OPS_PYTHON=$oldPython; $env:SERVICE_OPS_TASK_SCOPE=$oldScope }
Write-Host 'PASS: unknown writes retain locks; queries and known failures preserve their behavior'
