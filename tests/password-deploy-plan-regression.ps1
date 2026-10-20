#requires -Version 7
$ErrorActionPreference = 'Stop'
$PluginRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $PluginRoot 'scripts/service-ops.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    Invoke-Expression $function.Extent.Text
}

$WsDir = [IO.Path]::GetTempPath()
$script:authentication = 'password:LOCAL_LAN'
$script:credentialAvailable = $true
$script:credentialChecks = 0
function Get-DeployContext {
    return @{
        Service = @{Name='fixture';Repo='.';Module='';Kind='jar';Dir='/opt/fixture';Artifact='app.jar';DeployMode='script';VerifyUrl='http://127.0.0.1:18080/actuator/health'}
        Server = @{Name='fixture';Host='192.0.2.13';User='root';Key=$script:authentication}
    }
}
function Get-SourceIdentity { return @{Branch='fixture';Commit=('a'*40);Dirty='clean'} }
function Get-SshPassword($profile, $user) {
    if ($profile -ne 'LOCAL_LAN' -or $user -ne 'root') { throw 'wrong credential reference' }
    $script:credentialChecks++
    if (-not $script:credentialAvailable) { throw 'CREDENTIAL_MISSING' }
    return 'offline-fixture-secret'
}
function Get-Command { return $true }

Do-DeployPlan overseas-test fixture
if ($script:credentialChecks -ne 1) { throw 'Password reference was not validated exactly once' }
$script:credentialAvailable = $false
try {
    Do-DeployPlan overseas-test fixture
    throw 'Missing password was accepted'
} catch {
    if ($_.Exception.Message -notmatch '发版预检未通过') { throw }
}
$script:authentication = Join-Path $WsDir 'service-ops-nonexistent-private-key.pem'
try {
    Do-DeployPlan overseas-test fixture
    throw 'Missing private key was accepted'
} catch {
    if ($_.Exception.Message -notmatch '发版预检未通过') { throw }
}
Write-Host 'PASS: password deployment plan, missing credential and missing key'
