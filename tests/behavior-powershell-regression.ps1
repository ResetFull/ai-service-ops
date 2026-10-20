#requires -Version 7
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/service-ops.ps1'
$PluginRoot = Split-Path -Parent $PSScriptRoot
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$null, [ref]$null)
foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    Invoke-Expression $function.Extent.Text
}
function Write-Die($message) { throw $message }
function Assert($condition, $message) { if (-not $condition) { throw $message } }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "service-ops-powershell-$([guid]::NewGuid().ToString('N'))"
$bash = if ($IsWindows) { Join-Path $env:ProgramFiles 'Git/bin/bash.exe' } else { (Get-Command bash).Source }
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $marker = Join-Path $testRoot 'injected'
    $pattern = "customer's `$(touch '$marker')"
    $quoted = ConvertTo-ShellLiteral $pattern
    $result = Invoke-Native $bash @('-c', "printf '%s' $quoted") 10
    Assert ($result.Stdout -eq $pattern) 'single quotes and command substitution must remain literal data'
    Assert (-not (Test-Path $marker)) 'query input executed a command'
    $result = Invoke-Native $bash @('-c', 'printf failure >&2; exit 17') 10
    Assert ($result.ExitCode -eq 17 -and $result.Stderr -match 'failure') 'native failure must preserve exit code and stderr'
    $result = Invoke-Native $bash @('-c', 'sleep 3') 1
    Assert $result.TimedOut 'native command deadline did not stop execution'
    if ($IsWindows) {
    $batch = Join-Path $testRoot 'native mock.cmd'
    [IO.File]::WriteAllText($batch, "@echo off`r`necho %~1`r`nexit /b 17`r`n")
    $result = Invoke-Native $batch @('argument with spaces') 10
    Assert ($result.ExitCode -eq 17 -and $result.Stdout.Trim() -eq 'argument with spaces') 'Windows batch execution must preserve arguments and exit code'
    $cwdBatch=Join-Path $testRoot 'cwd mock.cmd'
    [IO.File]::WriteAllText($cwdBatch, "@echo off`r`necho %CD%`r`n")
    Push-Location $testRoot
    try { $cwdResult=Invoke-Native $cwdBatch @() 10 } finally { Pop-Location }
    Assert ($cwdResult.Stdout.Trim() -eq $testRoot) 'native process must use current PowerShell working directory'
    } else {
        Push-Location $testRoot
        try { $cwdResult=Invoke-Native $bash @('-c', 'pwd') 10 } finally { Pop-Location }
        Assert ($cwdResult.ExitCode -eq 0 -and $cwdResult.Stdout.Trim() -eq $testRoot) 'native process must use current PowerShell working directory'
    }
    $protected = Protect-Output '{"password":"psecret","bankCard":"6222021234567890","authorization":"Bearer private-token"} Authorization: Bearer top-secret release_id=20260928120000-abcdef12'
    Assert ($protected -notmatch 'psecret|6222021234567890|private-token|top-secret') 'structured secrets or Bearer token leaked'
    Assert ($protected -match '20260928120000-abcdef12') 'release identity must remain readable'
    $logs = Join-Path $testRoot 'logs'
    New-Item -ItemType Directory -Path $logs | Out-Null
    [IO.File]::WriteAllText((Join-Path $logs 'app-20260927.log'), "[2026-09-27 23:59:59] customer''s problem`n")
    [IO.File]::WriteAllText((Join-Path $logs 'app-20260928.log'), "[2026-09-28 00:00:01] customer''s problem`n")
    $unixLogs = $logs.Replace('\', '/').Replace('C:', '/c')
    $program = Get-LogQueryProgram @{ mode='range'; logdir=$unixLogs; glob='*.log'; date=''; pattern="customer''s"; n='20'; context='0'; start='2026-09-27 23:00:00'; end='2026-09-28 01:00:00'; node='mock'; service='app' }
    $result = Invoke-Native $bash @('-c', $program) 10
    Assert ($result.ExitCode -eq 0) "range query failed: $($result.Stderr)"
    Assert ($result.Stdout -match '23:59:59' -and $result.Stdout -match '00:00:01') 'cross-day query must inspect both files'
    Assert ($result.Stdout -match 'RESULT OK' -and $result.Stdout -match 'files=2') 'query must report coverage and status'
    $program = Get-LogQueryProgram @{ mode='grep'; logdir=$unixLogs; glob='*.log'; date=''; pattern='['; n='20'; context='0'; start=''; end=''; node='mock'; service='app' }
    $result = Invoke-Native $bash @('-c', $program) 10
    Assert ($result.ExitCode -ne 0 -and ($result.Stdout+$result.Stderr) -match 'QUERY_FAILED') 'invalid regex must not become NO_MATCH'
    Write-Host 'PASS: PowerShell literal transport, native failure/deadline and cross-day query behavior'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notlike 'service-ops-powershell-*') { throw 'unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
