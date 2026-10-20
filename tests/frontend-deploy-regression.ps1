#requires -Version 7
$ErrorActionPreference='Stop'
# Keep the historic entry point while asserting snapshot and marker behavior.
& (Join-Path $PSScriptRoot 'deploy-powershell-regression.ps1')
