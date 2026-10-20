#requires -Version 7
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Z][A-Z0-9_]{0,63}$')][string]$Name,
    [string]$UserName = 'root',
    [Security.SecureString]$Password
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'DPAPI 凭证仅适用于当前 Windows 用户；其他系统使用密码环境变量' }
if ($Name -cnotmatch '^[A-Z][A-Z0-9_]{0,63}$') { throw 'INVALID_PASSWORD_PROFILE' }
if (-not $Password) { $Password = Read-Host 'SSH password' -AsSecureString }
if ($Password.Length -eq 0) { throw 'SSH password must not be empty' }
$directory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ai-service-ops/credentials'
New-Item -ItemType Directory -Path $directory -Force | Out-Null
$credential = [PSCredential]::new($UserName, $Password)
$file = Join-Path $directory "$Name.xml"
$temporary = Join-Path $directory "$Name.$([guid]::NewGuid().ToString('N')).tmp"
$credential | Export-Clixml -LiteralPath $temporary
[IO.File]::Move($temporary, $file, $true)
Write-Host "Credential saved with Windows DPAPI: profile=$Name user=$UserName"
