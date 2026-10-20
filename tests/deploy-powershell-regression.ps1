#requires -Version 7
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/service-ops.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) { Invoke-Expression $function.Extent.Text }
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Expect-Failure([scriptblock]$operation, $pattern) {
    try { & $operation | Out-Null } catch { if ($_.Exception.Message -match $pattern) { return }; throw }
    throw "Expected failure matching $pattern"
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "service-ops-powershell-deploy-$([guid]::NewGuid().ToString('N'))"
$oldState = $env:SERVICE_OPS_STATE_DIR
$oldDirty = $env:SERVICE_OPS_ALLOW_DIRTY
$script:buildCalls = @()
$script:remoteCalls = @()
$script:scpFailed = $false
$script:nativeBuildFails = $false
function global:mvn {
    $script:buildCalls += 'mvn'
    Write-Output '[mock Maven] build output'
    if ($script:attemptConcurrentBuild) {
        Expect-Failure { Do-Build test front } 'BUILD_LOCKED'
        $script:concurrentBuildRejected=$true
    }
    if ($script:nativeBuildFails) { $global:LASTEXITCODE = 19; return }
    $target = Join-Path $WsDir 'repo/module/target'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $target 'app.jar'), 'new mock jar')
    $global:LASTEXITCODE = 0
}
function global:npm {
    $script:buildCalls += "npm $($args -join ' ')"
    if ($args[0] -eq 'run') {
        New-Item -ItemType Directory -Path 'dist' -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path (Get-Location) 'dist/index.html'), '<!doctype html><title>mock</title>')
    }
    $global:LASTEXITCODE = 0
}
function global:corepack {
    $script:buildCalls += "corepack $($args -join ' ')"
    if ($args[1] -eq 'run') {
        New-Item -ItemType Directory -Path 'dist' -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path (Get-Location) 'dist/index.html'), '<!doctype html><title>mock</title>')
    }
    $global:LASTEXITCODE = 0
}
function Invoke-BuildCommand($command, [string[]]$arguments) {
    & $command @arguments 2>&1 | ForEach-Object { Write-Host $_ }
    return $LASTEXITCODE
}
function Invoke-RemoteRelease($context, $action, $record, $remoteUpload, $token) {
    $script:remoteCalls += $action
    if ($action -eq $script:failRemoteAction) { throw "MOCK_$action`_FAILED" }
    if ($action -ne 'preflight' -and $action -ne 'verify') { Assert ($token -match '^[a-f0-9]{32}$') 'remote lock token must remain one scalar value' }
    Write-Output "RESULT OK action=$action"
    if ($action -eq 'install') { $script:installedRelease=$record.release_id }
    if ($action -eq 'verify') { $script:verifiedRelease=$record.release_id }
}
function Scp-Put($host_, $key, $user, $localPath, $remotePath) {
    $script:remoteCalls += 'scp'
    Assert (Test-Path -LiteralPath $localPath) 'SCP must use immutable snapshot'
    if ($script:scpFailed) { throw 'SCP_FAILED' }
}
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $env:SERVICE_OPS_STATE_DIR = Join-Path $testRoot 'state'
    $env:SERVICE_OPS_ALLOW_DIRTY = $null
    $WsDir = Join-Path $testRoot 'workspace'
    $ConfDir = Join-Path $testRoot 'config'
    $PluginRoot = Split-Path -Parent $PSScriptRoot
    $repo = Join-Path $WsDir 'repo'
    New-Item -ItemType Directory -Path $repo, $ConfDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $repo '.gitignore'), "target/`ndist/`n")
    [IO.File]::WriteAllText((Join-Path $repo 'source.txt'), 'source version one')
    foreach ($arguments in @(@('init','-q'), @('config','user.name','Offline Test'), @('config','user.email','offline@example.invalid'), @('add','.'), @('commit','-qm','initial'))) {
        $result = Invoke-Native 'git' (@('-C',$repo) + $arguments) 20
        Assert ($result.ExitCode -eq 0) "fixture Git failed: $($result.Stderr)"
    }
    [IO.File]::WriteAllText((Join-Path $ConfDir 'servers-test.conf'), "node|mock.invalid|mock|$testRoot/key|127.0.0.1|offline`nother|other.invalid|mock|$testRoot/key|127.0.0.2|offline`n")
    $configFile = Join-Path $ConfDir 'services-test.conf'
    [IO.File]::WriteAllText($configFile, "app|node|/tmp/mock|*.log|offline|repo|module|/tmp/service-ops-fixture|app.jar|script|jar|https://ready.invalid/health|`nfront|node|/tmp/mock|*.log|offline|repo||/tmp/service-ops-site|dist|static|frontend|https://site.invalid|npm`n")
    $script:attemptConcurrentBuild=$true
    Do-Build test app | Out-Null
    Assert $script:concurrentBuildRejected 'same-repository build for another service must be rejected while first build holds the lock'
    $script:attemptConcurrentBuild=$false
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $env:SERVICE_OPS_STATE_DIR 'build-locks') -File).Count -eq 0) 'successful build must release its local lock'
    $context = Get-DeployContext test app
    $record = Get-ReleaseRecord $context '' -ValidateSource
    Assert ($record.dirty -eq 'clean' -and $record.commit -match '^[a-f0-9]{40}$') 'build must record clean Git commit'
    Assert ((Get-FileHash -LiteralPath $record._snapshot).Hash.ToLowerInvariant() -eq $record.artifact_sha256) 'build snapshot hash mismatch'
    Assert ($record._snapshot.StartsWith($env:SERVICE_OPS_STATE_DIR)) 'state must live outside business repository'
    $script:remoteCalls = @(); $script:scpFailed = $true
    Expect-Failure { Do-Upload test app } 'SCP_FAILED'
    Assert ('install' -notin $script:remoteCalls -and 'restart' -notin $script:remoteCalls) 'SCP failure must stop install and restart'
    Assert ($script:remoteCalls[-1] -eq 'release') 'failed upload must release its owned lock'
    $script:scpFailed = $false
    $script:remoteCalls=@(); $script:failRemoteAction='restart'
    Expect-Failure { Do-All test app } 'MOCK_restart_FAILED'
    Assert ('verify' -notin $script:remoteCalls) 'restart failure must prevent verify'
    Assert ($script:remoteCalls[-1] -eq 'release') 'all failure must release cross-stage lock'
    $script:failRemoteAction=''
    $script:originalBuild=${function:Do-Build}
    function Do-Build($envName,$svc) {
        $first=& $script:originalBuild $envName $svc
        $second=& $script:originalBuild $envName $svc
        $script:expectedFirstRelease=$first.release_id
        $script:unexpectedSecondRelease=$second.release_id
        return $first
    }
    Do-All test app | Out-Null
    Assert ($script:installedRelease -eq $script:expectedFirstRelease -and $script:verifiedRelease -eq $script:expectedFirstRelease -and $script:installedRelease -ne $script:unexpectedSecondRelease) 'all must pin its build record when a second build changes current.tsv'
    Set-Item -LiteralPath Function:\Do-Build -Value $script:originalBuild
    [IO.File]::WriteAllText((Join-Path $repo 'source.txt'), 'source version two')
    $script:remoteCalls = @()
    Expect-Failure { Do-Upload test app } 'SOURCE_CHANGED'
    Assert ($script:remoteCalls.Count -eq 0) 'source mismatch must stop before SSH or SCP'
    Do-Build test app | Out-Null
    $dirtyRecord = Get-ReleaseRecord $context '' -ValidateSource
    Assert ($dirtyRecord.dirty -eq 'dirty') 'non-production build must record uncommitted source without an override'
    Do-Upload test app | Out-Null
    [IO.File]::WriteAllText((Join-Path $repo 'source.txt'), 'source version two changed after build')
    $script:remoteCalls = @()
    Expect-Failure { Do-Upload test app } 'SOURCE_CHANGED'
    Assert ($script:remoteCalls.Count -eq 0) 'dirty source changes must still stop before SSH or SCP'
    Invoke-Native 'git' @('-C',$repo,'add','.') 20 | Out-Null
    Invoke-Native 'git' @('-C',$repo,'commit','-qm','second') 20 | Out-Null
    Expect-Failure { Do-Upload test app } 'SOURCE_CHANGED'
    Do-Build test app | Out-Null
    $record = Get-ReleaseRecord $context ''
    [IO.File]::AppendAllText($record._snapshot, 'tampered')
    Expect-Failure { Do-Upload test app } 'ARTIFACT_HASH_MISMATCH'
    $script:nativeBuildFails = $true
    Expect-Failure { Do-Build test app } 'mvn 构建失败'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $env:SERVICE_OPS_STATE_DIR 'build-locks') -File).Count -eq 0) 'failed build must release its local lock'
    Expect-Failure { Do-Upload test app } 'BUILD_RECORD_REQUIRED'
    $script:nativeBuildFails = $false
    Do-Build test front | Out-Null
    $frontRecord = Get-ReleaseRecord (Get-DeployContext test front) '' -ValidateSource
    $archive = Invoke-Native 'tar' @('-xOf',$frontRecord._snapshot,'./service-ops-release.txt') 20
    Assert ($archive.ExitCode -eq 0 -and $archive.Stdout.Trim() -eq $frontRecord.release_id) 'frontend archive must bind HTTP marker to release'
    Assert (@($script:buildCalls | Where-Object { $_ -eq 'npm ci' }).Count -gt 0 -and @($script:buildCalls | Where-Object { $_ -eq 'npm run build:test' }).Count -gt 0) 'frontend must use npm ci and build:test'
    [IO.File]::WriteAllText($configFile, [IO.File]::ReadAllText($configFile).Replace('|https://site.invalid|npm', '|https://site.invalid|pnpm@11.9.0'))
    $script:buildCalls=@()
    Do-Build test front | Out-Null
    Assert ('corepack pnpm@11.9.0 install --frozen-lockfile' -in $script:buildCalls -and 'corepack pnpm@11.9.0 run build:test' -in $script:buildCalls) 'frontend must use pinned Corepack and frozen lockfile'
    foreach($alias in @('example-admin','example-h5','example-portal')) {
        [IO.File]::AppendAllText($configFile,"$alias|node|/tmp/mock|*.log|offline|repo||/tmp/site-$alias|dist|static|frontend|https://site.invalid|npm`n")
        $configured=Load-Service test $alias
        Assert ($configured.Kind -eq 'frontend' -and $configured.DeployMode -eq 'static' -and $configured.VerifyUrl -match '^https?://' -and ($configured.PackageManager -eq 'npm' -or $configured.PackageManager -match '^pnpm@\d+\.\d+\.\d+')) "frontend alias metadata is incomplete: $alias"
    }
    $noUrl = [IO.File]::ReadAllText($configFile).Replace('https://site.invalid','')
    [IO.File]::WriteAllText($configFile,$noUrl)
    $script:buildCalls=@(); $script:remoteCalls=@()
    Expect-Failure { Do-All test front } 'UNKNOWN'
    Assert ($script:buildCalls.Count -eq 0 -and $script:remoteCalls.Count -eq 0) 'missing URL must fail before any build or server action'
    Expect-Failure { Do-DeployVerify test front } 'UNKNOWN'
    Expect-Failure { Do-Rollback test app '' } '明确 releaseId'
    [IO.File]::WriteAllText($configFile,$noUrl.Replace('app|node|','app|node,other|'))
    Expect-Failure { Do-Restart test app } 'MULTI_NODE_DEPLOY_UNSUPPORTED'
    Expect-Failure { Get-QueryServers @{Name='app';Servers='node'} 'other' } '未部署'
    function Ssh-Run($host_, $key, $user, $cmd) { $script:queryHosts += $host_; Write-Output 'RESULT NO_MATCH' }
    $script:queryHosts=@()
    Do-Trace test 'literal trace' app '' | Out-Null
    Assert ($script:queryHosts.Count -eq 2 -and 'mock.invalid' -in $script:queryHosts -and 'other.invalid' -in $script:queryHosts) 'trace must query all configured nodes'
    $script:queryHosts=@()
    Expect-Failure { Do-Trace test 'literal trace' app nonexistent } '未部署'
    Assert ($script:queryHosts.Count -eq 0) 'invalid trace target must fail before any query'
    [IO.File]::AppendAllText($configFile,"example-core-server|node|/tmp/mock|*.log|offline`n")
    [IO.File]::WriteAllText((Join-Path $ConfDir 'settings.json'), '{"trace_services":["example-core-server"]}')
    $script:queryHosts=@()
    Do-Trace test 'literal trace' '' '' | Out-Null
    Assert ($script:queryHosts.Count -eq 1) 'default trace must preserve configured core-chain service scope'
    $nested=Join-Path $repo 'nested'
    New-Item -ItemType Directory -Path $nested | Out-Null
    Assert ((Get-SourceIdentity $nested).Repo -eq [IO.Path]::GetFullPath($repo).Replace('\','/')) 'monorepo subdirectory must resolve its owning Git root'
    $outside=Join-Path $testRoot 'outside-git'
    New-Item -ItemType Directory -Path $outside | Out-Null
    Expect-Failure { Get-SourceIdentity $outside } 'Git 身份读取失败'
    Invoke-Native 'git' @('-C',$repo,'checkout','--detach','-q') 20 | Out-Null
    Assert ((Get-SourceIdentity $repo).Branch -eq 'DETACHED') 'detached branch value must match Bash manifest protocol'
    Write-Host 'PASS: recorded snapshots, source/hash drift, SCP failure stop, failed-build invalidation, frontend identity, missing readiness URL and multi-node rejection'
} finally {
    if ($null -eq $oldState) { Remove-Item Env:SERVICE_OPS_STATE_DIR -ErrorAction SilentlyContinue } else { $env:SERVICE_OPS_STATE_DIR=$oldState }
    if ($null -eq $oldDirty) { Remove-Item Env:SERVICE_OPS_ALLOW_DIRTY -ErrorAction SilentlyContinue } else { $env:SERVICE_OPS_ALLOW_DIRTY=$oldDirty }
    foreach ($name in @('mvn','npm','corepack')) { Remove-Item -LiteralPath "Function:\global:$name" -ErrorAction SilentlyContinue }
    $resolved=[IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'service-ops-powershell-deploy-*') { throw 'unsafe cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
