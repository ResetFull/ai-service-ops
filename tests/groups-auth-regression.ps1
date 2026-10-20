#requires -Version 7
$ErrorActionPreference = 'Stop'
$PluginRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $PluginRoot 'scripts/service-ops.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    Invoke-Expression $function.Extent.Text
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Expect-Failure([scriptblock]$operation, $pattern) {
    try { & $operation | Out-Null } catch { if ($_.Exception.Message -match $pattern) { return }; throw }
    throw "Expected failure matching $pattern"
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('service-ops-groups-' + [guid]::NewGuid().ToString('N'))
$oldState = $env:SERVICE_OPS_STATE_DIR
try {
$ConfDir = Join-Path $testRoot 'config'
New-Item -ItemType Directory -Path $ConfDir -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $ConfDir 'servers-prod.conf'), 'prod-node|203.0.113.115|ops|key|192.0.2.115|Isolated production fixture')
foreach ($region in @('domestic','overseas')) {
    foreach ($stage in @('dev','test','prod')) {
        $config = Get-EnvConfig "$region-$stage"
        Assert ($config.Region -eq $region -and $config.Stage -eq $stage) 'group resolved incorrectly'
        Assert ($config.IsReadOnly -eq ($stage -eq 'prod')) 'production policy must not depend on region'
    }
}
Assert ((Get-EnvConfig test).Name -eq (Get-EnvConfig domestic-test).Name) 'legacy test alias changed'
Expect-Failure { Get-EnvConfig 'overseas-staging' } 'INVALID_SCOPE'
foreach ($scope in @('prod','domestic-prod','overseas-prod')) {
    foreach ($action in @('exec','build','upload','restart','rollback','all','unknown-write')) {
        Expect-Failure { Assert-ScopeAction $scope 'some-node' $action } 'PROD_READ_ONLY'
    }
    Expect-Failure { Assert-ScopeAction $scope doctor deploy } 'PROD_READ_ONLY'
    Assert-ScopeAction $scope doctor query
    Assert-ScopeAction $scope 'some-node' disk
}
$key = Get-SshAuthentication '~/.ssh/example.pem' root
Assert ($key.Arguments -contains 'BatchMode=yes' -and $key.Arguments -contains '-i') 'legacy key authentication changed'
function Get-SshPassword($profile, $user) { return 'offline-secret-do-not-log' }
function Get-AskpassProgram { return 'offline-askpass' }
$password = Get-SshAuthentication 'password:OVERSEAS_LOCAL' root
Assert ($password.Arguments -contains 'PreferredAuthentications=password') 'password authentication missing'
Assert ($password.Arguments -contains 'NumberOfPasswordPrompts=1') 'password retry must be bounded'
Assert ($password.Arguments -notcontains '-i') 'password authentication must not try unrelated private keys'
Assert (($password.Arguments -join ' ') -notmatch 'offline-secret') 'password leaked into command arguments'
Assert ($password.Environment.SERVICE_OPS_SSH_PASSWORD -eq 'offline-secret-do-not-log') 'password not passed to askpass environment'
Expect-Failure { Get-SshAuthentication 'password:bad;profile' root } 'INVALID_PASSWORD_PROFILE'
Assert-NotProductionTarget @{Host='203.0.113.16';Lan=''}
Expect-Failure { Assert-NotProductionTarget @{Host='203.0.113.115';Lan=''} } 'PROD_TARGET_READ_ONLY'
Assert ((Get-ScopeStateName test) -eq 'test') 'legacy release state path changed'
Assert ((Get-ScopeStateName overseas-test) -ne (Get-ScopeStateName test)) 'regional release states collide'
    $env:SERVICE_OPS_STATE_DIR = Join-Path $testRoot 'state'
    $artifact = Join-Path $testRoot 'app.jar'
    [IO.File]::WriteAllText($artifact,'isolated fixture')
    $context = @{Scope='overseas-test';Service=@{Name='fixture';Kind='jar';Dir='/opt/fixture';Artifact='app.jar'};Server=@{Name='node'}}
    $identity = @{Repo='fixture';Branch='fixture';Commit=('a'*40);Dirty='clean';Fingerprint=('b'*64)}
    $record = Save-BuildRecord $context $artifact $identity
    $loaded = Get-ReleaseRecord $context ''
    Assert ($loaded.env -eq 'overseas-test') 'overseas manifest did not round-trip'
    $domesticRoot = Get-StateRoot 'fixture' test
    New-Item -ItemType Directory -Path $domesticRoot -Force | Out-Null
    Write-ReleaseManifest (Join-Path $domesticRoot 'current.tsv') $record
    $domesticContext = @{Scope='test';Service=$context.Service;Server=$context.Server}
    Expect-Failure { Get-ReleaseRecord $domesticContext '' } '发布记录与当前配置不一致'
} finally {
    if ($null -eq $oldState) { Remove-Item Env:SERVICE_OPS_STATE_DIR -ErrorAction SilentlyContinue } else { $env:SERVICE_OPS_STATE_DIR=$oldState }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'service-ops-groups-*') { throw 'unsafe fixture cleanup' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host 'PASS: region/environment groups, production guards, key/password authentication and state isolation'
