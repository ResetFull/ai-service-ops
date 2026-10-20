#requires -Version 7
# service-ops.ps1 — 多环境服务运维工具 (生产只读 / 测试受控变更)
# 用法: pwsh service-ops.ps1 <domestic|overseas>-<dev|test|prod> <target> <action> [args]
# 生产全部只读；开发/测试按当前任务授权执行受控变更。

$ErrorActionPreference = 'Stop'
if ($env:SERVICE_OPS_TASK_EVENTS -eq '1') { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) }
$PluginRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ConfDir = Join-Path $PluginRoot 'config'

# 工作区根 (test 环境发版用)
$WsDir = $env:SERVICE_OPS_WS
if (-not $WsDir) { $WsDir = $env:SERVER_OPS_WS }

# 颜色输出
function Write-Log($msg) { Write-Host ">> $(Protect-Output $msg)" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "!! $(Protect-Output $msg)" -ForegroundColor Yellow }
function Write-Die($msg) { throw "XX $(Protect-Output $msg)" }
function Write-Header($msg) { Write-Host (Protect-Output $msg) -ForegroundColor Cyan }

function Assert-TaskConfig {
    if (-not $env:SERVICE_OPS_CONFIG_FINGERPRINT) { return }
    & $env:SERVICE_OPS_PYTHON (Join-Path $PluginRoot 'scripts/task_runtime.py') check-config $env:SERVICE_OPS_TASK_SCOPE $env:SERVICE_OPS_CONFIG_FINGERPRINT
    if ($LASTEXITCODE -ne 0) { Write-Die 'RESULT CONFIG_CHANGED：任务目标配置已变化，停止执行' }
}

function Write-TaskEvent($phase, $status, $record) {
    if ($env:SERVICE_OPS_TASK_EVENTS -ne '1') { return }
    & $env:SERVICE_OPS_PYTHON (Join-Path $PluginRoot 'scripts/task_events.py') $phase $status ([string]$record.release_id) ([string]$record.artifact_sha256)
    if ($LASTEXITCODE -ne 0) {
        $script:RemoteWriteUnknown=$true
        Write-Die 'RESULT UNKNOWN reason=EVENT_CHANNEL_FAILED inspect_before_retry=true'
    }
}

function Get-OpsPython {
    if ($env:SERVICE_OPS_PYTHON) { return $env:SERVICE_OPS_PYTHON }
    foreach ($candidate in @('python','python3')) {
        if (Get-Command $candidate -ErrorAction SilentlyContinue) {
            & $candidate -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>$null
            if ($LASTEXITCODE -eq 0) { return $candidate }
        }
    }
    Write-Die 'PYTHON_3_10_REQUIRED'
}

function Get-OpsSettings {
    $python = Get-OpsPython
    $json = & $python (Join-Path $PluginRoot 'scripts/ops_config.py') settings --dir $ConfDir
    if ($LASTEXITCODE -ne 0) { Write-Die 'INVALID_SETTINGS' }
    return ($json | ConvertFrom-Json -AsHashtable)
}

function Resolve-Date($date) {
    if ($null -eq $date) { return $null }

    $dateText = ([string]$date).Trim()
    if (-not $dateText) { return $null }
    if ($dateText -notmatch '^\d{8}$') { Write-Die "日期必须是 YYYYMMDD: $dateText" }

    $parsedDate = [datetime]::MinValue
    $isValid = [datetime]::TryParseExact(
        $dateText,
        'yyyyMMdd',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None,
        [ref]$parsedDate
    )
    if (-not $isValid) { Write-Die "日期无效: $dateText" }

    return $dateText
}

# ---- 环境选择 ----
function Get-EnvConfig($envName) {
    if ($envName -cnotmatch '^(?:(domestic|overseas)-)?(dev|test|prod)$') { Write-Die 'INVALID_SCOPE：使用 domestic|overseas 与 dev|test|prod 分组' }
    $region = if ($Matches[1]) { $Matches[1] } else { 'domestic' }
    $stage = $Matches[2]
    $name = if ($region -eq 'domestic') { $stage } else { "overseas-$stage" }
    return @{
        Name = $name; Region = $region; Stage = $stage; Scope = "$region-$stage"
        ServersFile = "$ConfDir/servers-$name.conf"
        ServicesFile = "$ConfDir/services-$name.conf"
        IsReadOnly = ($stage -eq 'prod')
    }
}

function Get-ScopeStateName($scope) { return (Get-EnvConfig $scope).Name }

function Assert-ScopeAction($scope, $target, $action) {
    if (-not (Get-EnvConfig $scope).IsReadOnly) {
        if ($action -in @('build','upload','restart','rollback','all','exec') -and -not (Get-OpsSettings).write_enabled) {
            Write-Die 'WRITES_DISABLED：在本机 settings.json 显式开启后才允许非生产写入'
        }
        return
    }
    if ($target -in @('groups','list','servers','all-disk','all-ps','trace','nginx-stats')) { return }
    if ($target -eq 'doctor' -and $action -in @('','query')) { return }
    if ($target -ne 'doctor' -and $action -in @('','status','health','logs','grep','grepall','backupgrep','logsrange','count','logfiles','ps','disk','mem','top','services','net','jvm','nginx-config','image-layout')) { return }
    Write-Die 'PROD_READ_ONLY：国内、海外生产仅允许预定义只读查询'
}

function Assert-NotProductionTarget($server) {
    foreach ($file in Get-ChildItem -LiteralPath $ConfDir -Filter 'servers-*prod.conf' -File) {
        foreach ($line in Get-Config $file.FullName) {
            $parts = $line -split '\|'
            $addresses = @($parts[1], $parts[4]) | Where-Object { $_ }
            if ($server.Host -in $addresses -or ($server.Lan -and $server.Lan -in $addresses)) {
                Write-Die 'PROD_TARGET_READ_ONLY：目标地址已登记为生产节点，不能从其他分组写入'
            }
        }
    }
}

function Get-Config($file) {
    if (-not (Test-Path $file)) { Write-Die "配置文件不存在: $file" }
    Get-Content $file | Where-Object { $_ -and $_ -notmatch '^\s*#' }
}

function Load-Server($envName, $key) {
    Assert-Identifier $key 'server'
    $cfg = Get-EnvConfig $envName
    $line = (Get-Config $cfg.ServersFile) | Where-Object { ($_ -split '\|')[0] -ceq $key } | Select-Object -First 1
    if (-not $line) { Write-Die "server '$key' 未配置 ($($cfg.ServersFile))" }
    $parts = $line -split '\|'
    if (-not $parts[1]) { Write-Die "HOST_ADDRESS_PENDING：$key 尚未提供真实 IP/域名" }
    if (-not $parts[2] -or -not $parts[3]) { Write-Die "AUTHENTICATION_PENDING：$key 尚未登记认证信息" }
    $keyPath = $parts[3]
    # 展开 ~ 为 $HOME (跨平台: Windows PowerShell 和 macOS pwsh 都支持 $HOME)
    if ($keyPath -match '^~') { $keyPath = $keyPath -replace '^~', $HOME }
    return @{
        Name = $parts[0]; Host = $parts[1]; User = $parts[2]; Key = $keyPath; Lan = $parts[4]; Desc = $parts[5]
    }
}

function Load-Service($envName, $key) {
    Assert-Identifier $key 'service'
    $cfg = Get-EnvConfig $envName
    $line = (Get-Config $cfg.ServicesFile) | Where-Object { ($_ -split '\|')[0] -ceq $key } | Select-Object -First 1
    if (-not $line) { Write-Die "service '$key' 未配置 ($($cfg.ServicesFile))" }
    $parts = $line -split '\|'
    $svc = @{
        Name = $parts[0]; Servers = $parts[1]; LogDirTpl = $parts[2]; LogGlob = $parts[3]; Desc = $parts[4]
    }
    # test 环境额外字段 (发版用)
    if ((Get-EnvConfig $envName).Stage -eq 'test' -and $parts.Count -ge 10) {
        $svc.Repo = $parts[5]
        $svc.Module = $parts[6]
        $svc.Dir = $parts[7]
        $svc.Artifact = $parts[8]
        $svc.DeployMode = $parts[9]
        $svc.Kind = if ($parts.Count -ge 11 -and $parts[10]) { $parts[10] } else { 'jar' }
        $svc.VerifyUrl = if ($parts.Count -ge 12) { $parts[11] } else { '' }
        $svc.PackageManager = if ($parts.Count -ge 13) { $parts[12] } else { '' }
        # 保留旧字段别名，避免改变既有后端 JAR 发布逻辑。
        $svc.Jar = $svc.Artifact
        $svc.RestartMode = $svc.DeployMode
    }
    return $svc
}

# ---- SSH/SCP 执行 ----
function Assert-Identifier($value, $label) {
    if ([string]$value -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { Write-Die "$label 标识无效" }
}

function ConvertTo-ShellLiteral([string]$value) {
    if ($value.Contains([char]0)) { Write-Die '参数不能包含 NUL' }
    $escapedQuote = "'" + '"' + "'" + '"' + "'"
    return "'" + $value.Replace("'", $escapedQuote) + "'"
}

function Protect-Output([string]$value) {
    $value = $value -replace '(?i)(authorization["\x27]?\s*[=:]\s*["\x27]?\s*Bearer\s+)[^\s,"\x27;]+', '$1[REDACTED]'
    $value = $value -replace '(?i)(["\x27](?:password|passwd|token|secret|api[_-]?key|authorization|cardNo|bankCard|accountNo)["\x27]\s*:\s*["\x27])[^"\x27]*', '$1[REDACTED]'
    $value = $value -replace '(?i)((?:cardNo|bankCard|accountNo)\s*[=:]\s*)([^\s,;]+)', '$1[REDACTED]'
    $value = $value -replace '(?i)((?:password|passwd|token|secret|api[_-]?key|authorization)\s*[=:]\s*)([^\s,;]+)', '$1[REDACTED]'
    $value = $value -replace '(?<!\d)1[3-9]\d{9}(?!\d)', '[PHONE]'
    $value = $value -replace '(?<!\d)\d{17}[\dXx](?!\d)', '[IDENTITY]'
    return ($value -replace '(https?://[^\s?]+)\?[^\s]+', '$1?[REDACTED]')
}

function Invoke-Native([string]$command, [string[]]$arguments, [int]$timeoutSeconds = 600, [hashtable]$environment = @{}) {
    $resolved = Get-Command $command -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $resolved.Source
    $info.WorkingDirectory = (Get-Location).ProviderPath
    if ($resolved.Source -match '\.(cmd|bat)$') {
        $payload = @{ Command=$resolved.Source; Arguments=@($arguments) } | ConvertTo-Json -Compress
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
        $launcher = '$data = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(' + "'$encoded'" + ')) | ConvertFrom-Json; & $data.Command @($data.Arguments); exit $LASTEXITCODE'
        $info.FileName = (Get-Command 'pwsh' -CommandType Application | Select-Object -First 1).Source
        $arguments = @('-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launcher)))
    }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($entry in $environment.GetEnumerator()) { $info.Environment[$entry.Key] = [string]$entry.Value }
    foreach ($argument in $arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $finished = $process.WaitForExit($timeoutSeconds * 1000)
        if (-not $finished) { $process.Kill($true); $process.WaitForExit() }
        return [PSCustomObject]@{ ExitCode = if ($finished) { $process.ExitCode } else { 124 }; Stdout = $stdout.GetAwaiter().GetResult(); Stderr = $stderr.GetAwaiter().GetResult(); TimedOut = -not $finished }
    } finally { $process.Dispose() }
}

function Get-QueryBudget($name, [int]$defaultValue, [int]$maximum) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if (-not $value) { return $defaultValue }
    if ($value -notmatch '^[1-9][0-9]*$' -or [long]$value -gt $maximum) { Write-Die "$name 必须为 1..$maximum" }
    return [int]$value
}

function Get-SshPassword($profile, $user) {
    if ($profile -cnotmatch '^[A-Z][A-Z0-9_]{0,63}$') { Write-Die 'INVALID_PASSWORD_PROFILE' }
    $password = [Environment]::GetEnvironmentVariable("SERVICE_OPS_PASSWORD_$profile")
    if ($password) { return $password }
    if ($IsWindows) {
        $file = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "ai-service-ops/credentials/$profile.xml"
        if (Test-Path -LiteralPath $file) {
            try { $credential = Import-Clixml -LiteralPath $file } catch { Write-Die "CREDENTIAL_UNAVAILABLE profile=$profile" }
            if ($credential -isnot [PSCredential] -or $credential.UserName -cne $user) { Write-Die "CREDENTIAL_USER_MISMATCH profile=$profile" }
            return $credential.GetNetworkCredential().Password
        }
    }
    Write-Die "CREDENTIAL_MISSING：设置 SERVICE_OPS_PASSWORD_$profile，或在 Windows 使用 save-credential.ps1"
}

function Get-AskpassProgram {
    $source = Join-Path $PluginRoot 'scripts/ssh-askpass.cs'
    $data = if ($IsWindows) { [Environment]::GetFolderPath('LocalApplicationData') } else { Join-Path $HOME '.local/share' }
    $directory = Join-Path $data 'ai-service-ops/askpass'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    if ($IsWindows) {
        $hash = (Get-FileHash -LiteralPath $source).Hash.Substring(0,16)
        $program = Join-Path $directory "askpass-$hash.exe"
        if (-not (Test-Path -LiteralPath $program)) {
            $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
            $temporary = Join-Path $directory ("askpass-$([guid]::NewGuid().ToString('N')).exe")
            $build = Invoke-Native $compiler @('/nologo','/target:winexe',"/out:$temporary",$source) 30
            if ($build.ExitCode -ne 0) { Write-Die 'ASKPASS_BUILD_FAILED' }
            try { [IO.File]::Move($temporary, $program, $false) }
            catch [IO.IOException] {
                if (-not (Test-Path -LiteralPath $program)) { throw }
                [IO.File]::Delete($temporary)
            }
        }
        return $program
    }
    $program = Join-Path $directory 'askpass.sh'
    [IO.File]::WriteAllText($program, '#!/bin/sh' + [char]10 + 'printf ''%s\n'' "$SERVICE_OPS_SSH_PASSWORD"' + [char]10)
    $permission = Invoke-Native chmod @('700',$directory,$program) 5
    if ($permission.ExitCode -ne 0) { Write-Die 'ASKPASS_PERMISSION_FAILED' }
    return $program
}

function Get-SshAuthentication($authentication, $user) {
    if ($authentication.StartsWith('password:', [StringComparison]::Ordinal)) {
        $profile = $authentication.Substring(9)
        if ($profile -cnotmatch '^[A-Z][A-Z0-9_]{0,63}$') { Write-Die 'INVALID_PASSWORD_PROFILE' }
        $password = Get-SshPassword $profile $user
        return @{
            Arguments = @('-o','BatchMode=no','-o','PreferredAuthentications=password','-o','PubkeyAuthentication=no','-o','KbdInteractiveAuthentication=no','-o','NumberOfPasswordPrompts=1')
            Environment = @{SSH_ASKPASS=(Get-AskpassProgram); SSH_ASKPASS_REQUIRE='force'; SERVICE_OPS_SSH_PASSWORD=$password}
        }
    }
    return @{Arguments=@('-o','BatchMode=yes','-i',$authentication); Environment=@{}}
}

function Invoke-SshClient($command, $arguments, $authentication, $user, $timeoutSeconds) {
    $auth = Get-SshAuthentication $authentication $user
    $options = @('-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=15') + $auth.Arguments
    return Invoke-Native $command ($options + $arguments) $timeoutSeconds $auth.Environment
}

function Ssh-Run($host_, $key, $user, $cmd, [int]$timeoutSeconds = 0, [switch]$Mutation) {
    Assert-TaskConfig
    if ($host_ -notmatch '^[A-Za-z0-9][A-Za-z0-9.:-]*$' -or $user -notmatch '^[A-Za-z_][A-Za-z0-9_-]*$') { Write-Die 'SSH 配置 host/user 无效' }
    $isQuery = $timeoutSeconds -eq 0
    if ($isQuery) { $timeoutSeconds = Get-QueryBudget 'SERVICE_OPS_QUERY_TIMEOUT_SECONDS' 20 120 }
    $cmd = $cmd.Replace("`r`n", "`n")
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($cmd))
    $remote = "printf '%s' '$b64' | base64 -d | timeout -k 2s ${timeoutSeconds}s bash"
    $result = Invoke-SshClient 'ssh' @("${user}@${host_}", $remote) $key $user ($timeoutSeconds + 17)
    if ($result.Stdout) { Write-Output (Protect-Output $result.Stdout.TrimEnd()) }
    if ($result.Stderr) { Write-Warn (Protect-Output $result.Stderr.TrimEnd()) }
    if ($result.ExitCode -ne 0) {
        if ($Mutation -and ($result.ExitCode -in @(124,137,255) -or $result.TimedOut)) {
            $script:RemoteWriteUnknown=$true
            Write-Die "RESULT UNKNOWN target=$host_ exit=$($result.ExitCode) inspect_before_retry=true"
        }
        $status = if ($result.ExitCode -eq 255) { 'SSH_FAILED' } elseif ($result.ExitCode -in @(124, 137) -or $result.TimedOut) { 'PARTIAL' } elseif ($result.ExitCode -eq 2 -and $result.Stdout -match 'RESULT (PARTIAL|NO_LOG)') { $Matches[1] } else { 'QUERY_FAILED' }
        Write-Die "RESULT $status target=$host_ exit=$($result.ExitCode)"
    }
}

function Scp-Put($host_, $key, $user, $localPath, $remotePath) {
    Assert-TaskConfig
    if ($remotePath -notmatch '^/[A-Za-z0-9_./-]+$') { Write-Die 'SCP 远端路径无效' }
    $result = Invoke-SshClient 'scp' @($localPath, "${user}@${host_}:$remotePath") $key $user 600
    if ($result.Stderr) { Write-Warn (Protect-Output $result.Stderr.TrimEnd()) }
    if ($result.ExitCode -in @(124,137,255) -or $result.TimedOut) {
        $script:RemoteWriteUnknown=$true
        Write-Die "RESULT UNKNOWN action=scp target=$host_ exit=$($result.ExitCode) inspect_before_retry=true"
    }
    if ($result.ExitCode -ne 0) { Write-Die "SCP_FAILED target=$host_ exit=$($result.ExitCode)" }
}

function Resolve-LogDir($tpl, $svc, $lan) {
    $tpl -replace '\{svc\}', $svc -replace '\{host\}', $lan
}

# ---- 列出 ----
function Do-List($envName) {
    $cfg = Get-EnvConfig $envName
    Write-Log "[$envName] 已配置服务:"
    Get-Config $cfg.ServicesFile | ForEach-Object { Write-Host (Protect-Output $_) }
}

function Do-Servers($envName) {
    $cfg = Get-EnvConfig $envName
    Write-Log "[$envName] 已配置服务器:"
    Get-Config $cfg.ServersFile | ForEach-Object { Write-Host (Protect-Output $_) }
}

function Do-Groups {
    foreach ($region in @('domestic','overseas')) {
        foreach ($stage in @('dev','test','prod')) {
            $group = Get-EnvConfig "$region-$stage"
            $rows = @(Get-Config $group.ServersFile)
            $configured = @($rows | Where-Object { $parts=$_ -split '\|'; $parts[1] -and $parts[2] -and $parts[3] }).Count
            $policy = if ($group.IsReadOnly) { 'read-only' } else { 'task-authorized' }
            Write-Host "$($group.Scope) policy=$policy registered=$($rows.Count) configured=$configured pending=$($rows.Count-$configured)"
        }
    }
}

# ---- 本地运行条件检查 ----
function Do-Doctor($envName, $mode) {
    if (-not $mode) { $mode = 'query' }
    if ($mode -notin @('query', 'deploy')) { Write-Die "doctor 模式必须是 query 或 deploy" }
    if ($mode -eq 'deploy' -and (Get-EnvConfig $envName).Stage -ne 'test') { Write-Die "deploy 预检只适用于 test" }

    $cfg = Get-EnvConfig $envName
    $serverLines = @(Get-Config $cfg.ServersFile)
    $serviceLines = @(Get-Config $cfg.ServicesFile)
    $serverNames = @($serverLines | ForEach-Object { ($_ -split '\|')[0] })
    $serviceNames = @($serviceLines | ForEach-Object { ($_ -split '\|')[0] })
    $failures = @()

    foreach ($tool in @('ssh')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $failures += "缺少命令: $tool" }
    }
    foreach ($duplicate in @($serverNames + $serviceNames | Group-Object | Where-Object Count -gt 1)) {
        $failures += "配置名称重复: $($duplicate.Name)"
    }
    foreach ($line in $serviceLines) {
        $parts = $line -split '\|'
        foreach ($serverRef in ($parts[1] -split ',')) {
            if ($serverRef -notin $serverNames) { $failures += "服务 $($parts[0]) 引用了未知服务器 $serverRef" }
        }
        if ($parts.Count -ge 11 -and $parts[10] -and $parts[10] -notin @('jar', 'frontend')) {
            $failures += "服务 $($parts[0]) 的 kind 无效: $($parts[10])"
        }
        if ($parts.Count -ge 11 -and $parts[10] -eq 'frontend') {
            $packageManager = if ($parts.Count -ge 13) { $parts[12] } else { '' }
            if (-not $packageManager) {
                $failures += "前端服务 $($parts[0]) 未配置 packageManager"
            } elseif ($packageManager -ne 'npm' -and $packageManager -notmatch '^pnpm@\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') {
                $failures += "前端服务 $($parts[0]) 的 packageManager 无效: $packageManager"
            }
        }
    }
    foreach ($line in $serverLines) {
        $parts = $line -split '\|'
        if (-not $parts[1] -or -not $parts[2] -or -not $parts[3]) { $failures += "HOST_CONFIGURATION_PENDING：$($parts[0])"; continue }
        $keyPath = $parts[3] -replace '^~', $HOME
        if ($keyPath.StartsWith('password:')) {
            try { Get-SshPassword $keyPath.Substring(9) $parts[2] | Out-Null } catch { $failures += $_.Exception.Message }
        } elseif (-not (Test-Path $keyPath)) { $failures += "私钥不存在: $keyPath" }
    }

    if ($mode -eq 'deploy') {
        $deployServices = @($serviceLines | ForEach-Object {
            $parts = $_ -split '\|'
            if ($parts.Count -ge 10 -and $parts[5]) {
                [PSCustomObject]@{
                    Kind = if ($parts.Count -ge 11 -and $parts[10]) { $parts[10] } else { 'jar' }
                    PackageManager = if ($parts.Count -ge 13) { $parts[12] } else { '' }
                }
            }
        })
        $requiredTools = @('scp')
        if ($deployServices.Kind -contains 'jar') { $requiredTools += @('mvn', 'java') }
        if ($deployServices.Kind -contains 'frontend') { $requiredTools += @('node', 'tar') }
        if ($deployServices.PackageManager -contains 'npm') { $requiredTools += 'npm' }
        if (@($deployServices.PackageManager | Where-Object { $_ -match '^pnpm@' }).Count -gt 0) { $requiredTools += 'corepack' }
        foreach ($tool in $requiredTools) {
            if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $failures += "缺少命令: $tool" }
        }
        if (-not $WsDir -or -not (Test-Path $WsDir)) { $failures += "未找到工作区，设置 SERVICE_OPS_WS（兼容 SERVER_OPS_WS）" }
    }

    Write-Log "[$envName] doctor/${mode}: servers=$($serverNames.Count), services=$($serviceNames.Count)"
    if ($failures.Count -gt 0) {
        $failures | Sort-Object -Unique | ForEach-Object { Write-Warn $_ }
        Write-Die "doctor 检查失败，共 $($failures.Count) 项"
    }
    Write-Log "doctor 检查通过"
}

function Resolve-QueryNumber($value, [int]$defaultValue, [int]$maximum, [string]$label) {
    if ($null -eq $value -or [string]$value -eq '') { return $defaultValue }
    if ([string]$value -notmatch '^[0-9]+$' -or [long]$value -gt $maximum) { Write-Die "$label 必须为 0..$maximum" }
    return [int]$value
}
function Resolve-Time($value, [switch]$End) {
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$value, [string[]]@('yyyy-MM-dd HH:mm:ss','yyyy-MM-dd HH:mm'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { Write-Die '时间必须为有效的 YYYY-MM-DD HH:mm[:ss]' }
    if ($End -and ([string]$value).Length -eq 16) { $parsed = $parsed.AddSeconds(59) }
    return $parsed.ToString('yyyy-MM-dd HH:mm:ss')
}
function Get-QueryServers($service, $server, [switch]$All) {
    $servers = @($service.Servers -split ',')
    if ($server) {
        Assert-Identifier $server 'server'
        if ($server -cnotin $servers) { Write-Die "$($service.Name) 未部署在 $server" }
        return @($server)
    }
    if ($All) { return $servers }
    return @($servers[0])
}
function Get-LogQueryProgram([hashtable]$parameters) {
    $bytes = Get-QueryBudget 'SERVICE_OPS_QUERY_MAX_BYTES' 16777216 268435456
    $files = Get-QueryBudget 'SERVICE_OPS_QUERY_MAX_FILES' 20 100
    $lines = Get-QueryBudget 'SERVICE_OPS_QUERY_MAX_LINES' 2000 10000
    $action = switch ($parameters.mode) { 'range' { 'logsrange' }; 'files' { 'logfiles' }; 'nginx' { 'nginx-stats' }; default { $parameters.mode } }
    $arguments = @($action, $parameters.service, $parameters.logdir, $parameters.glob, $parameters.date, $parameters.pattern, $parameters.n, $parameters.context, $parameters.start, $parameters.end, [string]$bytes, [string]$files, [string]$lines)
    $quoted = ($arguments | ForEach-Object { ConvertTo-ShellLiteral ([string]$_) }) -join ' '
    $queryScript = switch ($action) {
        'nginx-config' { 'scripts/remote-nginx.sh' }
        'image-layout' { 'scripts/remote-image-layout.sh' }
        default { 'scripts/remote-query.sh' }
    }
    if ($action -eq 'image-layout') {
        $arguments = @($action) + @((Get-OpsSettings).storage_roots)
        $quoted = ($arguments | ForEach-Object { ConvertTo-ShellLiteral ([string]$_) }) -join ' '
    }
    $program = [IO.File]::ReadAllText((Join-Path $PluginRoot $queryScript)).Replace([string][char]13, '')
    return 'set -- ' + $quoted + [char]10 + $program
}


function Invoke-LogQuery($envName, $svc, $mode, $pat, $n, $server, $date, $context, $start, $end, [switch]$All, [switch]$Backup) {
    $date = Resolve-Date $date
    $n = Resolve-QueryNumber $n 200 10000 '行数'
    if ($n -eq 0) { Write-Die '行数必须大于 0' }
    $context = Resolve-QueryNumber $context 0 100 '上下文'
    if ($mode -in @('grep','count','trace') -and -not $pat) { Write-Die "$mode 需要关键词" }
    if ($mode -eq 'range') {
        $start = Resolve-Time $start; $end = Resolve-Time $end -End
        if ($start -gt $end) { Write-Die 'start 必须不晚于 end' }
        if ($date -and ($start.Substring(0,10) -ne $end.Substring(0,10) -or $date -ne $start.Substring(0,10).Replace('-',''))) { Write-Die 'date 与时间窗口不一致；跨日窗口请省略 date' }
    }
    $s = Load-Service $envName $svc
    $failures = @()
    foreach ($srvName in (Get-QueryServers $s $server -All:$All)) {
        $srv = Load-Server $envName $srvName
        $logdir = if ($Backup) {
            $template = (Get-OpsSettings).backup_log_dir
            if (-not $template) { Write-Die 'BACKUP_DIRECTORY_REQUIRED' }
            Resolve-LogDir $template $s.Name $srv.Lan
        } else { Resolve-LogDir $s.LogDirTpl $s.Name $srv.Lan }
        $cmd = Get-LogQueryProgram @{ mode=$mode; logdir=$logdir; glob=$(if($Backup){'*.log'}else{$s.LogGlob}); date=$date; pattern=$pat; n=[string]$n; context=[string]$context; start=$start; end=$end; node=$srvName; service=$svc }
        Write-Header "[$envName $svc on $srvName $($srv.Host)]"
        try { Ssh-Run $srv.Host $srv.Key $srv.User $cmd } catch { $failures += $_.Exception.Message; Write-Warn $_.Exception.Message }
    }
    if ($failures.Count) { Write-Die "查询不完整：$($failures.Count) 个节点失败或达到预算；上方保留各节点状态" }
}
function Do-Status($envName, $svc, $serverFilter) {
    $s = Load-Service $envName $svc
    foreach ($srvName in (Get-QueryServers $s $serverFilter -All)) {
        $srv = Load-Server $envName $srvName
        Write-Header "[$envName $svc on $srvName]"
        $cmd = Get-LogQueryProgram @{mode='status';service=$s.Name;logdir='';glob='*.log';date='';pattern='';n='200';context='0';start='';end=''}
        Ssh-Run $srv.Host $srv.Key $srv.User $cmd
    }
}
function Do-Health($envName, $svc, $serverFilter, $date) {
    Invoke-LogQuery $envName $svc health '' 20 $serverFilter $date 0 '' '' -All
}
function Do-Logs($envName, $svc, $n, $server, $date) { Invoke-LogQuery $envName $svc logs '' $(if($null -eq $n){100}else{$n}) $server $date 0 '' '' }
function Do-Grep($envName, $svc, $pat, $n, $server, $date, $context) { Invoke-LogQuery $envName $svc grep $pat $n $server $date $context '' '' }
function Do-GrepAll($envName, $svc, $pat, $n, $date, $context) { Invoke-LogQuery $envName $svc grep $pat $n '' $date $context '' '' -All }
function Do-BackupGrep($envName, $svc, $pat, $date, $server, $context) { Invoke-LogQuery $envName $svc grep $pat 200 $server $date $context '' '' -Backup }
function Do-LogFiles($envName, $svc, $server, $date) { Invoke-LogQuery $envName $svc files '' 20 $server $date 0 '' '' }
function Do-LogsRange($envName, $svc, $start, $end, $pat, $server, $date) { Invoke-LogQuery $envName $svc range $pat 1000 $server $date 0 $start $end }
function Do-Count($envName, $svc, $pat, $server, $date) { Invoke-LogQuery $envName $svc count $pat 10000 $server $date 0 '' '' }
function Do-Trace($envName, $traceId, $svcList, $server) {
    if (-not $traceId) { Write-Die 'trace 需要 traceId' }
    $cfg = Get-EnvConfig $envName
    $configured = @(Get-Config $cfg.ServicesFile | ForEach-Object { ($_ -split '\|')[0] })
    $defaults = @((Get-OpsSettings).trace_services)
    $svcs = if ($svcList) { @($svcList -split ',' | ForEach-Object { $_.Trim() }) } else { @($defaults | Where-Object { $_ -cin $configured }) }
    if (-not $svcs.Count) { Write-Die '默认 trace 链路服务未配置，请明确服务列表' }
    foreach ($svc in $svcs) { Get-QueryServers (Load-Service $envName $svc) $server -All | Out-Null }
    $failures = @()
    foreach ($svc in $svcs) {
        try { Invoke-LogQuery $envName $svc.Trim() trace $traceId 200 $server '' 0 '' '' -All }
        catch { $failures += $_.Exception.Message; Write-Warn $_.Exception.Message }
    }
    if ($failures.Count) { Write-Die "trace 不完整：$($failures.Count) 个服务失败或达到预算" }
}
function Do-NginxStats($envName, $server, $date, $domain) {
    $date = Resolve-Date $date
    if ($domain -and $domain -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') { Write-Die 'domain 无效' }
    $srv = Load-Server $envName $server
    $cmd = Get-LogQueryProgram @{ mode='nginx'; logdir=(Get-OpsSettings).nginx_log_dir; glob="*$domain*access*.log"; date=$date; pattern=''; n='2000'; context='0'; start=''; end=''; node=$server; service='nginx' }
    Ssh-Run $srv.Host $srv.Key $srv.User $cmd
}


# ====== test 独有: 发版功能 ======
function Do-DeployPlan($envName, $svc) {
    $context = Get-DeployContext $envName $svc
    $s = $context.Service
    if (-not $s.Repo) { Write-Die "$svc 未配置发版信息 (repo/module/dir/artifact/deployMode)" }
    $srv = $context.Server
    $repoPath = if ($WsDir) { Join-Path $WsDir $s.Repo } else { '' }
    $localArtifact = if (-not $repoPath) { '' } elseif ($s.Kind -eq 'frontend') {
        Join-Path $repoPath $s.Artifact
    } else {
        Join-Path $repoPath "$($s.Module)/target/$($s.Artifact)"
    }
    $failures = @()

    $requiredTools = if ($s.Kind -eq 'frontend') {
        @('ssh', 'scp', 'node', 'tar') + $(if ($s.PackageManager -eq 'npm') { 'npm' } else { 'corepack' })
    } else {
        @('ssh', 'scp', 'mvn', 'java')
    }
    foreach ($tool in $requiredTools) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $failures += "缺少命令: $tool" }
    }
    if (-not $WsDir -or -not (Test-Path $WsDir)) { $failures += "未找到工作区，设置 SERVICE_OPS_WS（兼容 SERVER_OPS_WS）" }
    elseif (-not (Test-Path $repoPath)) { $failures += "仓库不存在: $repoPath" }
    if ($srv.Key.StartsWith('password:')) {
        try { Get-SshPassword $srv.Key.Substring(9) $srv.User | Out-Null }
        catch { $failures += $_.Exception.Message }
    } elseif (-not (Test-Path -LiteralPath $srv.Key -PathType Leaf)) {
        $failures += "私钥不存在: $($srv.Key)"
    }

    Write-Header "[test deploy plan] $($s.Name)"
    Write-Host "kind        : $($s.Kind)"
    Write-Host "repo/module : $($s.Repo)/$(if ($s.Module) { $s.Module } else { '-' })"
    Write-Host "target      : $($srv.Name) $($srv.Host):$($s.Dir)$(if ($s.Kind -eq 'frontend') { '' } else { "/$($s.Artifact)" })"
    Write-Host "deploy mode : $($s.DeployMode)"
    Write-Host "artifact    : $(if ($localArtifact) { $localArtifact } else { '(工作区未配置)' })"
    Write-Host "exists      : $([bool]($localArtifact -and (Test-Path $localArtifact)))"
    if ($s.PackageManager) { Write-Host "package mgr : $($s.PackageManager)" }
    if ($s.VerifyUrl) { Write-Host "verify url  : $(Protect-Output $s.VerifyUrl)" }
    else { Write-Warn 'verify url  : UNKNOWN；完整 all 在任何写操作之前停止' }
    if ($repoPath -and (Test-Path -LiteralPath $repoPath)) {
        try {
            $identity = Get-SourceIdentity $repoPath
            Write-Host "source      : branch=$($identity.Branch) commit=$($identity.Commit) dirty=$($identity.Dirty)"
        } catch { $failures += $_.Exception.Message }
    }
    if ($failures.Count -gt 0) {
        $failures | Sort-Object -Unique | ForEach-Object { Write-Warn $_ }
        Write-Die "发版预检未通过"
    }
    Write-Log "发版预检通过"
}

function Invoke-BuildCommand($command, [string[]]$arguments) {
    $result = Invoke-Native $command $arguments 600
    if ($result.Stdout) { Write-Host (Protect-Output $result.Stdout.TrimEnd()) }
    if ($result.Stderr) { Write-Warn (Protect-Output $result.Stderr.TrimEnd()) }
    return $result.ExitCode
}
function Do-Build($envName, $svc) {
    $context = Get-DeployContext $envName $svc
    if (-not $WsDir) { Write-Die '未配置工作区，设置 SERVICE_OPS_WS' }
    $repo = [IO.Path]::GetFullPath((Join-Path $WsDir $context.Service.Repo)).Replace('\', '/')
    if ($IsWindows) { $repo = $repo.ToLowerInvariant() }
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($repo))).ToLowerInvariant()
    $root = Split-Path -Parent (Split-Path -Parent (Get-StateRoot $svc $envName))
    $locks = Join-Path $root 'build-locks'
    New-Item -ItemType Directory -Path $locks -Force | Out-Null
    $path = Join-Path $locks "$key.lock"
    $token = [guid]::NewGuid().ToString('N')
    try { $handle = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
    catch { Write-Die "BUILD_LOCKED：同仓库构建正在运行或保留锁需要只读确认：$path" }
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($token + [char]10)
        $handle.Write($bytes, 0, $bytes.Length)
        $handle.Flush()
        Write-TaskEvent build started @{}
        $record = Invoke-BuildUnlocked $envName $svc
        Write-TaskEvent build completed $record
        return $record
    } finally {
        $handle.Dispose()
        if ((Get-Content -LiteralPath $path -TotalCount 1 -ErrorAction SilentlyContinue) -ceq $token) { Remove-Item -LiteralPath $path }
        else { Write-Warn "构建锁所有权异常，保留供只读确认：$path" }
    }
}
function Invoke-BuildUnlocked($envName, $svc) {
    $context = Get-DeployContext $envName $svc
    $s = $context.Service
    if (-not $s.Repo) { Write-Die "$svc 未配置发版信息 (repo/module/dir/artifact/deployMode)" }
    if (-not $WsDir) { Write-Die "未找到 workspace，设置 SERVICE_OPS_WS（兼容 SERVER_OPS_WS）" }
    $repoPath = "$WsDir/$($s.Repo)"
    if (-not (Test-Path $repoPath)) { Write-Die "仓库不存在: $repoPath" }
    $identity = Get-SourceIdentity $repoPath
    $current = Join-Path (Get-StateRoot $s.Name $envName) 'current.tsv'
    if (Test-Path -LiteralPath $current) { Remove-Item -LiteralPath $current }
    $expectedArtifact = if ($s.Kind -eq 'frontend') { Join-Path $repoPath $s.Artifact } else { Join-Path $repoPath "$($s.Module)/target/$($s.Artifact)" }
    if (Test-Path -LiteralPath $expectedArtifact) {
        $backup = Join-Path (Get-StateRoot $s.Name $envName) ('prebuild-backup/' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
        Move-Item -LiteralPath $expectedArtifact -Destination $backup
        Write-Log "旧构建产物已保留：$backup；本次必须重新生成产物"
    }

    if ($s.Kind -eq 'frontend') {
        if (-not $s.PackageManager) { Write-Die "$svc 未配置 packageManager" }
        $localArtifact = Join-Path $repoPath $s.Artifact
        $installDescription = if ($s.PackageManager -eq 'npm') { 'npm ci' } else { "$($s.PackageManager) install --frozen-lockfile" }
        Write-Log "[$envName] build: $($s.Repo) ($installDescription && build:test)"
        $oldHusky = $env:HUSKY
        $oldCi = $env:CI
        $installExitCode = 0
        $buildExitCode = 0
        Push-Location $repoPath
        try {
            $env:HUSKY = '0'
            $env:CI = '1'
            if ($s.PackageManager -eq 'npm') {
                $installExitCode = Invoke-BuildCommand 'npm' @('ci')
            } elseif ($s.PackageManager -match '^pnpm@\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?$') {
                $installExitCode = Invoke-BuildCommand 'corepack' @($s.PackageManager, 'install', '--frozen-lockfile')
            } else {
                Write-Die "$svc 的 packageManager 无效: $($s.PackageManager)"
            }
            if ($installExitCode -eq 0) {
                if ($s.PackageManager -eq 'npm') {
                    $buildExitCode = Invoke-BuildCommand 'npm' @('run', (Get-OpsSettings).frontend_build_script)
                } else {
                    $buildExitCode = Invoke-BuildCommand 'corepack' @($s.PackageManager, 'run', (Get-OpsSettings).frontend_build_script)
                }
            }
        } finally {
            Pop-Location
            if ($null -eq $oldHusky) { Remove-Item Env:HUSKY -ErrorAction SilentlyContinue } else { $env:HUSKY = $oldHusky }
            if ($null -eq $oldCi) { Remove-Item Env:CI -ErrorAction SilentlyContinue } else { $env:CI = $oldCi }
        }
        if ($installExitCode -ne 0) { Write-Die "$($s.PackageManager) install 失败" }
        if ($buildExitCode -ne 0) { Write-Die "$($s.PackageManager) build:test 失败" }
        if (-not (Test-Path (Join-Path $localArtifact 'index.html'))) { Write-Die "前端构建产物缺少 index.html: $localArtifact" }
        $fileCount = @(Get-ChildItem $localArtifact -File -Recurse).Count
        Write-Log "产物: $localArtifact ($fileCount files)"
        Assert-SourceIdentity $identity (Get-SourceIdentity $repoPath)
        return (Save-BuildRecord $context $localArtifact $identity)
    }

    $localJar = "$repoPath/$($s.Module)/target/$($s.Artifact)"
    Write-Log "[$envName] build: $($s.Repo)/$($s.Module) (mvn -Ptest)"
    $settings = Get-OpsSettings
    $buildArguments = @('-f', $repoPath, '-pl', $s.Module, '-am', 'clean', 'package', '-P', $settings.maven_profile)
    if (-not $settings.run_build_tests) { $buildArguments += '-DskipTests' }
    $buildExitCode = Invoke-BuildCommand 'mvn' $buildArguments
    if ($buildExitCode -ne 0) { Write-Die "mvn 构建失败：exit=$buildExitCode" }
    if (-not (Test-Path $localJar)) { Write-Die "构建产物不存在: $localJar" }
    $size = (Get-Item $localJar).Length / 1MB
    Write-Log "产物: $localJar ($([math]::Round($size,1))MB)"
    Assert-SourceIdentity $identity (Get-SourceIdentity $repoPath)
    return (Save-BuildRecord $context $localJar $identity)
}

function Get-DeployContext($envName, $svc, [switch]$RequireUrl) {
    if ((Get-EnvConfig $envName).Stage -ne 'test') { Write-Die '自动发布只在 test 环境可用；生产全部只读' }
    $scope = Get-ScopeStateName $envName
    $service = Load-Service $envName $svc
    $servers = @($service.Servers -split ',')
    if ($servers.Count -ne 1) { Write-Die 'MULTI_NODE_DEPLOY_UNSUPPORTED：写操作要求明确的单节点配置' }
    if (-not $service.Repo -or -not $service.Dir -or -not $service.Artifact) { Write-Die "$svc 未配置发版信息" }
    Assert-Identifier $service.Repo 'repo'
    if ($service.Module -and ($service.Module -notmatch '^[A-Za-z0-9][A-Za-z0-9_./-]*$' -or $service.Module -match '(^|/)\.\.?(/|$)')) { Write-Die 'module 相对路径无效' }
    if ($service.Dir -notmatch '^/[A-Za-z0-9_./-]+$' -or $service.Dir -eq '/' -or $service.Dir -match '/\.\.?(/|$)') { Write-Die '远端发布目录无效' }
    if ($service.Artifact -notmatch '^[A-Za-z0-9._-]+$' -or $service.Artifact -in @('.', '..')) { Write-Die '发布产物名称无效' }
    if ($RequireUrl -and -not $service.VerifyUrl) { Write-Die 'UNKNOWN：未配置 verifyUrl，发布验证不完整；在任何写操作之前停止' }
    if ($service.VerifyUrl -and $service.VerifyUrl -notmatch '^https?://[^\s]+$') { Write-Die 'verifyUrl 无效' }
    if ($WsDir) {
        $repoPath = [IO.Path]::GetFullPath((Join-Path $WsDir $service.Repo))
        $state = [IO.Path]::GetFullPath((Get-StateRoot $service.Name $scope))
        if ($state -eq $repoPath -or $state.StartsWith($repoPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { Write-Die 'SERVICE_OPS_STATE_DIR 必须位于业务仓库之外' }
    }
    $server = Load-Server $envName $servers[0]
    Assert-NotProductionTarget $server
    return @{ Service=$service; Server=$server; Scope=$scope }
}
function Get-StateRoot($service, $scope = 'test') {
    $stateRoot = $env:SERVICE_OPS_STATE_DIR
    if (-not $stateRoot) {
        $data = if ($IsWindows) { [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData) } elseif ($env:XDG_STATE_HOME) { $env:XDG_STATE_HOME } else { Join-Path $HOME '.local/state' }
        if (-not $data) { $data = Join-Path $HOME '.local/state' }
        $stateRoot = Join-Path $data 'ai-service-ops'
    }
    Assert-Identifier $service 'service'
    $scope = if ($scope) { Get-ScopeStateName $scope } else { 'test' }
    return Join-Path ([IO.Path]::GetFullPath($stateRoot)) "$scope/$service"
}
function Write-ReleaseManifest($path, [hashtable]$record) {
    $keys = @('format','env','service','kind','repo','branch','commit','dirty','profile','release_id','artifact_sha256','target','created_at','source_fingerprint')
    $lines = foreach ($key in $keys) {
        $value = [string]$record[$key]
        if ($value -match '[\r\n\t]') { Write-Die "manifest 字段 $key 含控制字符" }
        $key + [char]9 + $value
    }
    [IO.File]::WriteAllText($path, ($lines -join [char]10) + [char]10, [Text.UTF8Encoding]::new($false))
}
function Read-ReleaseManifest($path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Write-Die 'BUILD_RECORD_REQUIRED：先成功 build，禁止上传未记录产物' }
    $record = @{}
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        $entry = $line -split "\t", 2
        if ($entry.Count -ne 2 -or $record.ContainsKey($entry[0])) { Write-Die '发布记录无效' }
        $record[$entry[0]] = $entry[1]
    }
    if ($record['format'] -ne '1' -or $record['env'] -notin @('test','overseas-test') -or $record['release_id'] -cnotmatch '^[0-9]{14}-[a-f0-9]{8}$' -or $record['artifact_sha256'] -cnotmatch '^[a-f0-9]{64}$') { Write-Die '发布记录无效' }
    return $record
}
function Invoke-Git($repo, [string[]]$arguments) {
    $result = Invoke-Native 'git' (@('-c', 'core.quotePath=false', '-C', $repo) + $arguments) 30
    if ($result.ExitCode -ne 0) { Write-Die "Git 身份读取失败：$(Protect-Output $result.Stderr)" }
    return $result.Stdout.TrimEnd([char[]]@([char]13, [char]10))
}
function Get-SourceIdentity($repo) {
    $repo = [IO.Path]::GetFullPath($repo)
    $gitRoot = [IO.Path]::GetFullPath((Invoke-Git $repo @('rev-parse', '--show-toplevel')))
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    # monorepo 下 repo 可指向 Git 根内的子目录（如 example-plus），但不得跳出 Git 根
    $repoTrimmed = $repo.TrimEnd([IO.Path]::DirectorySeparatorChar)
    $rootTrimmed = $gitRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not ($repoTrimmed.Equals($rootTrimmed, $comparison) -or $repoTrimmed.StartsWith($rootTrimmed + [IO.Path]::DirectorySeparatorChar, $comparison))) { Write-Die '仓库配置必须位于 Git 根目录内' }
    $commit = Invoke-Git $repo @('rev-parse', 'HEAD')
    $branch = Invoke-Git $repo @('rev-parse', '--abbrev-ref', 'HEAD')
    if ($branch -ceq 'HEAD') { $branch = 'DETACHED' }
    $status = Invoke-Git $repo @('status', '--porcelain=v1', '--untracked-files=all')
    $diff = Invoke-Git $repo @('diff', '--binary', 'HEAD', '--')
    $untracked = Invoke-Git $repo @('ls-files', '--others', '--exclude-standard', '-z')
    $fileHashes = foreach ($relative in ($untracked -split [char]0 | Where-Object { $_ })) {
        $candidate = [IO.Path]::GetFullPath((Join-Path $repo $relative))
        if (-not $candidate.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { Write-Die 'Git 未跟踪文件超出仓库范围' }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { "$relative=$((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash)" }
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes($status + $diff + ($fileHashes -join '|'))
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    return @{ Repo=$gitRoot.Replace('\', '/'); Branch=$branch; Commit=$commit; Dirty=$(if($status){'dirty'}else{'clean'}); Fingerprint=$digest }
}
function Assert-SourceIdentity($before, $after) {
    if ($before.Repo -cne $after.Repo -or $before.Commit -cne $after.Commit -or $before.Branch -cne $after.Branch -or $before.Dirty -cne $after.Dirty -or $before.Fingerprint -cne $after.Fingerprint) { Write-Die 'SOURCE_CHANGED：源码身份在构建后发生变化，请重新 build' }
}
function Save-BuildRecord($context, $artifact, $identity) {
    $s = $context.Service; $srv = $context.Server
    $id = (Get-Date -Format 'yyyyMMddHHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0,8))
    $root = Get-StateRoot $s.Name $context.Scope
    $releaseDir = Join-Path $root "releases/$id"
    New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
    $snapshot = Join-Path $releaseDir $(if($s.Kind -eq 'frontend'){'artifact.tar.gz'}else{'artifact.jar'})
    if ($s.Kind -eq 'frontend') {
        $site = Join-Path $releaseDir 'site'
        Copy-Item -LiteralPath $artifact -Destination $site -Recurse
        [IO.File]::WriteAllText((Join-Path $site 'service-ops-release.txt'), $id + [char]10, [Text.UTF8Encoding]::new($false))
        $result = Invoke-Native 'tar' @('-czf', $snapshot, '-C', $site, '.') 120
        if ($result.ExitCode -ne 0) { Write-Die "产物打包失败：$(Protect-Output $result.Stderr)" }
        $resolved = [IO.Path]::GetFullPath($site)
        if (-not $resolved.StartsWith([IO.Path]::GetFullPath($releaseDir) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { Write-Die '安全检查：产物暂存路径越界' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    } else { Copy-Item -LiteralPath $artifact -Destination $snapshot }
    $record = @{
        format='1'; env=$(if($context.Scope){$context.Scope}else{'test'}); service=$s.Name; kind=$s.Kind; repo=$identity.Repo; branch=$identity.Branch; commit=$identity.Commit; dirty=$identity.Dirty; profile=$(if($s.Kind -eq 'frontend'){(Get-OpsSettings).frontend_build_script}else{(Get-OpsSettings).maven_profile});
        release_id=$id; artifact_sha256=(Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash.ToLowerInvariant();
        target="$($srv.Name):$($s.Dir)$(if($s.Kind -ne 'frontend'){"/$($s.Artifact)"})"; created_at=[DateTimeOffset]::UtcNow.ToString('o'); source_fingerprint=$identity.Fingerprint
    }
    $manifest = Join-Path $releaseDir 'manifest.tsv'
    Write-ReleaseManifest $manifest $record
    Set-CurrentRelease $s.Name $record
    Write-Log "release_id=$id commit=$($identity.Commit) sha256=$($record.artifact_sha256)"
    return $record
}
function Set-CurrentRelease($service, $record) {
    $root = Get-StateRoot $service $record.env
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $temporary = Join-Path $root ("current." + [guid]::NewGuid().ToString('N') + '.tmp')
    Write-ReleaseManifest $temporary $record
    [IO.File]::Move($temporary, (Join-Path $root 'current.tsv'), $true)
}
function Get-ReleaseRecord($context, $releaseId, [switch]$ValidateSource) {
    $s = $context.Service; $srv = $context.Server
    $root = Get-StateRoot $s.Name $context.Scope
    $manifest = if ($releaseId) {
        if ($releaseId -cnotmatch '^[0-9]{14}-[a-f0-9]{8}$') { Write-Die 'releaseId 格式无效' }
        Join-Path $root "releases/$releaseId/manifest.tsv"
    } else { Join-Path $root 'current.tsv' }
    $record = Read-ReleaseManifest $manifest
    $target = "$($srv.Name):$($s.Dir)$(if($s.Kind -ne 'frontend'){"/$($s.Artifact)"})"
    $expectedScope = if ($context.Scope) { $context.Scope } else { 'test' }
    if ($record.env -cne $expectedScope -or $record.service -cne $s.Name -or $record.kind -cne $s.Kind -or $record.target -cne $target) { Write-Die '发布记录与当前配置不一致' }
    $snapshot = Join-Path $root "releases/$($record.release_id)/$(if($s.Kind -eq 'frontend'){'artifact.tar.gz'}else{'artifact.jar'})"
    if (-not (Test-Path -LiteralPath $snapshot -PathType Leaf) -or (Get-FileHash -LiteralPath $snapshot -Algorithm SHA256).Hash.ToLowerInvariant() -cne $record.artifact_sha256) { Write-Die 'ARTIFACT_HASH_MISMATCH：不可变构建快照缺失或被修改' }
    if ($ValidateSource) {
        $now = Get-SourceIdentity (Join-Path $WsDir $s.Repo)
        $before = @{ Repo=$record.repo; Branch=$record.branch; Commit=$record.commit; Dirty=$record.dirty; Fingerprint=$record.source_fingerprint }
        Assert-SourceIdentity $before $now
    }
    $record['_snapshot'] = $snapshot
    return $record
}
function Invoke-RemoteRelease($context, $action, $record, $remoteUpload, $token) {
    $s = $context.Service; $srv = $context.Server
    $program = [IO.File]::ReadAllText((Join-Path $PluginRoot 'scripts/remote-release.sh')).Replace([string][char]13, '')
    $arguments = @($action, $s.Kind, $s.Dir, $s.Artifact, [string]$record.release_id, [string]$record.artifact_sha256, [string]$remoteUpload, $s.DeployMode, $s.VerifyUrl, [string]$token)
    $quoted = ($arguments | ForEach-Object { ConvertTo-ShellLiteral $_ }) -join ' '
    $cmd = 'set -- ' + $quoted + [char]10 + $program
    Write-TaskEvent $action started $record
    try {
        if ($action -in @('acquire','release','install','restart','rollback')) {
            Ssh-Run $srv.Host $srv.Key $srv.User $cmd 120 -Mutation
        } else { Ssh-Run $srv.Host $srv.Key $srv.User $cmd 120 }
        Write-TaskEvent $action completed $record
    } catch {
        Write-TaskEvent $action $(if($script:RemoteWriteUnknown){'unknown'}else{'failed'}) $record
        throw
    }
}
function Invoke-ReleaseLocked($context, $record, [scriptblock]$operation) {
    if ($script:ReleaseLockToken) { & $operation $script:ReleaseLockToken; return }
    $script:RemoteWriteUnknown=$false
    $token = [guid]::NewGuid().ToString('N')
    Invoke-RemoteRelease $context acquire $record '' $token
    $script:ReleaseLockToken = $token
    try { & $operation $token }
    finally {
        $script:ReleaseLockToken = $null
        if ($script:RemoteWriteUnknown) {
            Write-Warn 'RESULT UNKNOWN lock=retained inspect_before_retry=true；远端写入结果未确认，保留发布锁'
        } else {
            try { Invoke-RemoteRelease $context release $record '' $token }
            catch { Write-Warn "释放锁失败；保留锁供只读确认：$($_.Exception.Message)"; throw }
        }
    }
}
function Do-Upload($envName, $svc, $builtRecord) {
    $context = Get-DeployContext $envName $svc
    $record = Get-ReleaseRecord $context ([string]$builtRecord.release_id) -ValidateSource
    Invoke-RemoteRelease $context preflight $record '' ''
    Invoke-ReleaseLocked $context $record {
        param($token)
        $remote = "/tmp/service-ops-$($record.release_id)-$token"
        Write-TaskEvent transfer started $record
        try {
            Scp-Put $context.Server.Host $context.Server.Key $context.Server.User $record._snapshot $remote
            Write-TaskEvent transfer completed $record
        } catch {
            Write-TaskEvent transfer $(if($script:RemoteWriteUnknown){'unknown'}else{'failed'}) $record
            throw
        }
        Get-ReleaseRecord $context $record.release_id -ValidateSource | Out-Null
        Invoke-RemoteRelease $context install $record $remote $token
    }
}
function Do-Restart($envName, $svc) {
    $context = Get-DeployContext $envName $svc
    Invoke-RemoteRelease $context preflight @{} '' ''
    Invoke-ReleaseLocked $context @{} { param($token) Invoke-RemoteRelease $context restart @{} '' $token }
}
function Do-DeployVerify($envName, $svc, $builtRecord) {
    $context = Get-DeployContext $envName $svc -RequireUrl
    $record = Get-ReleaseRecord $context ([string]$builtRecord.release_id)
    Invoke-RemoteRelease $context verify $record '' ([string]$script:ReleaseLockToken)
    Write-Log "验证通过 release_id=$($record.release_id)；远端产物哈希、运行进程/入口与配置 URL 已核验"
}
function Do-All($envName, $svc) {
    $context = Get-DeployContext $envName $svc -RequireUrl
    Invoke-RemoteRelease $context preflight @{} '' ''
    Invoke-ReleaseLocked $context @{} {
        param($token)
        $builtRecord = Do-Build $envName $svc
        Do-Upload $envName $svc $builtRecord | Out-Host
        Do-Restart $envName $svc | Out-Host
        Do-DeployVerify $envName $svc $builtRecord | Out-Host
    }
}
function Do-Rollback($envName, $svc, $releaseId) {
    if (-not $releaseId) { Write-Die 'rollback 需要明确 releaseId；先确认真实运行版本再选择旧版本' }
    $context = Get-DeployContext $envName $svc -RequireUrl
    $record = Get-ReleaseRecord $context $releaseId
    Invoke-RemoteRelease $context preflight $record '' ''
    Invoke-ReleaseLocked $context $record {
        param($token)
        Invoke-RemoteRelease $context rollback $record '' $token
        Invoke-RemoteRelease $context restart $record '' $token
        Invoke-RemoteRelease $context verify $record '' $token
        Set-CurrentRelease $svc $record
    }
}
function Do-ReleaseStatus($envName, $svc) {
    $context = Get-DeployContext $envName $svc
    Invoke-RemoteRelease $context inspect @{} '' ''
}


function Invoke-ServerQuery($envName, $srvName, $action, $pattern) {
    $srv = Load-Server $envName $srvName
    Write-Header "[$envName $srvName $($srv.Host) $($srv.Lan)]"
    $cmd = Get-LogQueryProgram @{mode=$action;service='';logdir='';glob='*.log';date='';pattern=$pattern;n='200';context='0';start='';end=''}
    Ssh-Run $srv.Host $srv.Key $srv.User $cmd
}
function Do-Server-PS($envName, $srvName) { Invoke-ServerQuery $envName $srvName ps '' }
function Do-Server-Disk($envName, $srvName) { Invoke-ServerQuery $envName $srvName disk '' }
function Do-Server-Mem($envName, $srvName) { Invoke-ServerQuery $envName $srvName mem '' }
function Do-Server-Top($envName, $srvName) { Invoke-ServerQuery $envName $srvName top '' }
function Do-Server-Services($envName, $srvName) { Invoke-ServerQuery $envName $srvName services '' }
function Do-Server-Net($envName, $srvName) { Invoke-ServerQuery $envName $srvName net '' }
function Do-Server-Jvm($envName, $srvName, $filter) { Invoke-ServerQuery $envName $srvName jvm $filter }
function Do-Server-Exec($envName, $srvName, $cmd) {
    if ((Get-EnvConfig $envName).IsReadOnly) { Write-Die 'PROD_READ_ONLY：exec 已在生产禁用' }
    $srv = Load-Server $envName $srvName
    Assert-NotProductionTarget $srv
    Write-Header "[$envName $srvName $($srv.Host)]"
    Ssh-Run $srv.Host $srv.Key $srv.User $cmd 600 -Mutation
}
function Invoke-AllServerQuery($envName, $action) {
    $cfg = Get-EnvConfig $envName
    $failures = @()
    foreach ($line in (Get-Config $cfg.ServersFile)) {
        $srvName = ($line -split '\|')[0]
        try { Invoke-ServerQuery $envName $srvName $action '' }
        catch { $failures += $_.Exception.Message; Write-Warn $_.Exception.Message }
    }
    if ($failures.Count) { Write-Die "全局查询不完整：$($failures.Count) 个节点失败或达到预算" }
}
function Do-All-Disk($envName) { Invoke-AllServerQuery $envName disk }
function Do-All-PS($envName) { Invoke-AllServerQuery $envName ps }


# ====== Usage ======
function Show-Usage {
    @'
service-ops.ps1 — 多环境服务运维工具
用法: pwsh service-ops.ps1 <domestic|overseas>-<dev|test|prod> <target> <action> [args]
兼容 dev/test/prod，均指国内。所有生产分组只读；开发/测试操作须有当前任务授权。

通用 service 级:
  status [server]                 查服务进程
  logs [N] [server] [date]        最近 N 行日志 (默认100)
  grep <pat> [N] [server] [date] [ctx]  搜日志 (默认200条, ctx=上下文行)
  grepall <pat> [N] [date] [ctx]  搜日志(所有服务器)
  backupgrep <pat> [date] [server] [ctx]  搜历史备份(prod共享盘)
  logsrange <start> <end> [pat] [server] [date]  按时间范围搜
  count <pat> [server] [date]     统计关键词匹配行数（预算内）
  logfiles [server] [date]        列日志文件

全局:
  doctor [query|deploy]             本地依赖/配置/私钥或密码配置档预检
  trace <traceId> [服务列表] [server]  traceId追踪
  nginx-stats <server> [date] [domain]  Nginx统计
  groups | list | servers | all-disk | all-ps

test 独有 (发版):
  plan                            展示发版目标并检查本地条件
  build                           后端 Maven 构建 / 前端 pnpm build:test
  upload                          上传记录的构建快照；前端入口为软链接
  restart                         后端远程重启；静态前端无需重启
  verify                          核验记录的远端版本与配置就绪 URL
  release-status                  只读查询真实 active/previous 版本
  rollback <releaseId>            恢复指定历史版本并验证（需明确授权）
  all                             build→upload→restart(按类型)→verify

server 级（以对应分组清单为准）:
  ps | disk | mem | top | services | net | nginx-config | image-layout | jvm [filter]
  exec <cmd>                      仅开发/测试，须明确授权目标和命令

service 诊断:
  health [server] [date]          聚合进程、日志元数据和最近异常

示例:
  pwsh service-ops.ps1 prod example-core-server logs 20
  pwsh service-ops.ps1 prod example-biz-server grepall "Exception"
  pwsh service-ops.ps1 prod trace "cdea832f6c5e477b"
  pwsh service-ops.ps1 prod prod06 net
  pwsh service-ops.ps1 test example-biz-server all
  pwsh service-ops.ps1 test demo-web plan
  pwsh service-ops.ps1 test example-biz-server logs 200
  pwsh service-ops.ps1 test demo-node ps
  pwsh service-ops.ps1 overseas-test demo-node mem
  pwsh service-ops.ps1 overseas-dev servers
  pwsh service-ops.ps1 overseas-prod servers
'@ | Write-Host
}

# ====== main ======
$args_list = @($args)
$env:SERVICE_OPS_PYTHON = Get-OpsPython
if ($args_list.Count -gt 0 -and $args_list[0] -in @('config','demo')) {
    $commandFile = if ($args_list[0] -eq 'config') { 'ops_config.py' } else { 'demo.py' }
    $commandArguments = @($args_list | Select-Object -Skip 1)
    & $env:SERVICE_OPS_PYTHON (Join-Path $PluginRoot "scripts/$commandFile") @commandArguments
    exit $LASTEXITCODE
}
$ConfDir = & $env:SERVICE_OPS_PYTHON (Join-Path $PluginRoot 'scripts/ops_config.py') resolve --root $PluginRoot
if ($LASTEXITCODE -ne 0) { Write-Die 'CONFIG_DIRECTORY_UNAVAILABLE' }
$env:SERVICE_OPS_CONFIG_DIR = $ConfDir
if ($args_list.Count -gt 0 -and $args_list[0] -eq 'task') {
    $python = if ($env:SERVICE_OPS_PYTHON) { $env:SERVICE_OPS_PYTHON } else { 'python' }
    $taskArgs = @($args_list | Select-Object -Skip 1)
    & $python (Join-Path $PluginRoot 'scripts/task_runtime.py') --engine powershell @taskArgs
    exit $LASTEXITCODE
}
if ($args_list.Count -lt 1) { Show-Usage; exit 0 }

$EnvName = (Get-EnvConfig $args_list[0]).Name

if ($args_list.Count -lt 2) { Show-Usage; exit 1 }
$Arg2 = $args_list[1]
$Arg3 = if ($args_list.Count -ge 3) { $args_list[2] } else { '' }
$rest = if ($args_list.Count -ge 4) { $args_list[3..($args_list.Count-1)] } else { @() }
Assert-ScopeAction $EnvName $Arg2 $Arg3

# 全局动作
switch ($Arg2) {
    'groups'      { Do-Groups; exit 0 }
    'list'        { Do-List $EnvName; exit 0 }
    'servers'     { Do-Servers $EnvName; exit 0 }
    'doctor'      { Do-Doctor $EnvName $Arg3; exit 0 }
    'all-disk'    { Do-All-Disk $EnvName; exit 0 }
    'all-ps'      { Do-All-PS $EnvName; exit 0 }
    'trace'       { $r=@($rest); if (-not $Arg3) { Write-Die "trace 需要 traceId" }; Do-Trace $EnvName $Arg3 $r[0] $r[1]; exit 0 }
    'nginx-stats' { $r=@($rest); if (-not $Arg3) { Write-Die "nginx-stats 需要 server" }; Do-NginxStats $EnvName $Arg3 $r[0] $r[1]; exit 0 }
}

# 判断 server 级还是 service 级
$cfg = Get-EnvConfig $EnvName
Assert-Identifier $Arg2 'target'
$isServer = @((Get-Config $cfg.ServersFile) | Where-Object { ($_ -split '\|')[0] -ceq $Arg2 }).Count -gt 0
$isService = @((Get-Config $cfg.ServicesFile) | Where-Object { ($_ -split '\|')[0] -ceq $Arg2 }).Count -gt 0

if ($isServer) {
    if (-not $Arg3) { Show-Usage; exit 1 }
    switch ($Arg3) {
        'ps'       { Do-Server-PS $EnvName $Arg2 }
        'disk'     { Do-Server-Disk $EnvName $Arg2 }
        'mem'      { Do-Server-Mem $EnvName $Arg2 }
        'top'      { Do-Server-Top $EnvName $Arg2 }
        'services' { Do-Server-Services $EnvName $Arg2 }
        'net'      { Do-Server-Net $EnvName $Arg2 }
        'nginx-config' { Invoke-ServerQuery $EnvName $Arg2 nginx-config '' }
        'image-layout' { Invoke-ServerQuery $EnvName $Arg2 image-layout '' }
        'jvm'      { $r=@($rest); Do-Server-Jvm $EnvName $Arg2 $r[0] }
        'exec'     { $r=@($rest); if ($r.Count -lt 1) { Write-Die "exec 需要命令" }; Do-Server-Exec $EnvName $Arg2 ($r -join ' ') }
        default    { Show-Usage; Write-Die "server 级 action: ps|disk|mem|top|services|net|jvm|nginx-config|image-layout|exec(dev/test only)" }
    }
} elseif ($isService) {
    $act = if ($Arg3) { $Arg3 } else { 'status' }
    switch ($act) {
        'status'     { $r=@($rest); Do-Status $EnvName $Arg2 $r[0] }
        'health'     { $r=@($rest); Do-Health $EnvName $Arg2 $r[0] $r[1] }
        'logs'       { $r=@($rest); Do-Logs $EnvName $Arg2 $r[0] $r[1] $r[2] }
        'grep'       { $r=@($rest); Do-Grep $EnvName $Arg2 $r[0] $r[1] $r[2] $r[3] $r[4] }
        'grepall'    { $r=@($rest); Do-GrepAll $EnvName $Arg2 $r[0] $r[1] $r[2] $r[3] }
        'backupgrep' { $r=@($rest); Do-BackupGrep $EnvName $Arg2 $r[0] $r[1] $r[2] $r[3] }
        'logsrange'  { $r=@($rest); if (-not $r[0]) { Write-Die "logsrange 需要 start end" }; Do-LogsRange $EnvName $Arg2 $r[0] $r[1] $r[2] $r[3] $r[4] }
        'count'      { $r=@($rest); Do-Count $EnvName $Arg2 $r[0] $r[1] $r[2] }
        'logfiles'   { $r=@($rest); Do-LogFiles $EnvName $Arg2 $r[0] $r[1] }
        'plan'       { Do-DeployPlan $EnvName $Arg2 }
        'build'      { Do-Build $EnvName $Arg2 }
        'upload'     { Do-Upload $EnvName $Arg2 }
        'restart'    { Do-Restart $EnvName $Arg2 }
        'verify'     { $r=@($rest); Do-DeployVerify $EnvName $Arg2 @{release_id=[string]$r[0]} }
        'release-status' { Do-ReleaseStatus $EnvName $Arg2 }
        'rollback'   { $r=@($rest); Do-Rollback $EnvName $Arg2 $r[0] }
        'all'        { Do-All $EnvName $Arg2 }
        default      { Show-Usage; Write-Die "service 级 action: status|health|logs|grep|grepall|backupgrep|logsrange|count|logfiles|plan|build|upload|restart|verify|release-status|rollback|all" }
    }
} else {
    Write-Die "未知 service/server: '$Arg2' (list 查服务, servers 查服务器)"
}
